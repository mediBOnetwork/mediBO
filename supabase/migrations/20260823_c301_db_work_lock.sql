-- CHANGE #301 — db_work_lock: the DB coordination lane.
--
-- The 1 GB Micro instance does not fall over because one query is slow; it
-- falls over when several agents run HEAVY database work at the same moment.
-- This is the deploy lane's idea applied to the database itself: the rare
-- exclusive operations queue, and NOTHING else does. Coding, flutter tests,
-- web builds and ordinary small queries never touch this table.
--
-- Two kinds:
--   exclusive  (1 slot)  — DDL migrations, bulk write over ~20k rows, VACUUM,
--                          index build. Excludes every other kind.
--   heavy_read (2 slots) — a scan/audit over a big table (whatsapp_messages
--                          history, "MEDICINE"). Two may run together.
-- Every lock auto-expires (default 10 min) so a crashed agent never wedges the
-- lane — the same reason deploy_lock has a TTL.

create table if not exists public.db_work_lock (
  token       uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('exclusive','heavy_read')),
  holder      text not null,
  title       text,
  command_id  bigint,
  acquired_at timestamptz not null default now(),
  expires_at  timestamptz not null
);
create index if not exists db_work_lock_expires_idx on public.db_work_lock (expires_at);

create table if not exists public.db_work_lock_config (
  id                  boolean primary key default true check (id),
  exclusive_slots     int not null default 1,
  heavy_read_slots    int not null default 2,
  ttl_minutes         int not null default 10,
  retry_after_seconds int not null default 45
);
insert into public.db_work_lock_config (id) values (true) on conflict (id) do nothing;

-- A lock that expired without a release means the agent holding it died. That
-- is exactly the event the watchdog exists to make visible, so reaping it is
-- never silent.
create or replace function public._db_lock_reap()
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; n int := 0;
begin
  for r in delete from public.db_work_lock where expires_at <= now() returning * loop
    n := n + 1;
    insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('db_lock_expired|' || r.holder || '|' || to_char(r.acquired_at, 'YYYY-MM-DD HH24')),
            'warn', 'db_lock_expired', r.holder,
            jsonb_build_object('kind', r.kind, 'title', r.title,
                               'command_id', r.command_id,
                               'held_minutes', round(extract(epoch from (r.expires_at - r.acquired_at)) / 60)::int))
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = public.rg_alerts.seen_count + 1;
  end loop;
  return n;
end $$;

create or replace function public.db_lock_try(
  p_agent      text,
  p_kind       text,
  p_title      text default null,
  p_ttl_minutes int default null,
  p_command_id bigint default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  cfg    public.db_work_lock_config%rowtype;
  v_kind text := lower(btrim(coalesce(p_kind, '')));
  v_token uuid := gen_random_uuid();
  v_ttl  int;
  v_ex   int;
  v_hr   int;
  v_exp  timestamptz;
begin
  perform public._db_guard();

  if v_kind in ('exclusive','ddl','migration','write','vacuum') then
    v_kind := 'exclusive';
  elsif v_kind in ('heavy_read','heavy-read','heavy','read','scan','audit') then
    v_kind := 'heavy_read';
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind',
      'instruction', 'kind must be exclusive (DDL migration, bulk write over ~20k rows, VACUUM, index build) or heavy_read (a scan or audit over a big table). Ordinary reads and small writes need NO lock — take none and stay parallel.');
  end if;

  -- One writer at a time decides; the transaction lock is released at commit.
  perform pg_advisory_xact_lock(7401, 1);
  select * into cfg from public.db_work_lock_config where id;
  perform public._db_lock_reap();

  v_ttl := greatest(least(coalesce(p_ttl_minutes, cfg.ttl_minutes), 30), 1);
  select count(*) filter (where kind = 'exclusive'),
         count(*) filter (where kind = 'heavy_read')
    into v_ex, v_hr
    from public.db_work_lock;

  if (v_kind = 'exclusive'  and v_ex + v_hr >= cfg.exclusive_slots)
  or (v_kind = 'heavy_read' and (v_ex > 0 or v_hr >= cfg.heavy_read_slots)) then
    return jsonb_build_object('ok', false, 'reason', 'busy', 'kind', v_kind,
      'retry_after_seconds', cfg.retry_after_seconds,
      'frees_in_seconds', coalesce((select greatest(round(extract(epoch from (min(expires_at) - now())))::int, 0)
                                      from public.db_work_lock), 0),
      'held_by', coalesce((select jsonb_agg(jsonb_build_object(
                              'kind', l.kind, 'holder', l.holder, 'title', l.title,
                              'held_for_seconds', round(extract(epoch from (now() - l.acquired_at)))::int)
                            order by l.acquired_at)
                           from public.db_work_lock l), '[]'::jsonb),
      'instruction', format('The %s DB lane is full. Wait %s s and retry db_lock_try — keep coding, testing and building meanwhile; only this one database step waits.',
                            v_kind, cfg.retry_after_seconds));
  end if;

  v_exp := now() + make_interval(mins => v_ttl);
  insert into public.db_work_lock (token, kind, holder, title, command_id, expires_at)
  values (v_token, v_kind, coalesce(p_agent, 'agent'), p_title, p_command_id, v_exp);

  return jsonb_build_object('ok', true, 'token', v_token, 'kind', v_kind,
    'expires_at', v_exp, 'ttl_minutes', v_ttl,
    'next_step', format('Run ONLY the heavy step now, then call db_lock_release(token) immediately. The lock self-expires in %s min, so never hold it across a flutter build, a deploy or a think.', v_ttl));
end $$;

create or replace function public.db_lock_release(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare l public.db_work_lock%rowtype;
begin
  perform public._db_guard();
  delete from public.db_work_lock where token = p_token returning * into l;
  if l.token is null then
    return jsonb_build_object('ok', false, 'error', 'not_lock_holder',
      'instruction', 'That token holds no DB lane lock — it was already released, or it expired and was reaped. Nothing to do.');
  end if;
  return jsonb_build_object('ok', true, 'released', true, 'kind', l.kind,
    'held_seconds', round(extract(epoch from (now() - l.acquired_at)))::int);
end $$;

create or replace function public.db_lock_status()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare cfg public.db_work_lock_config%rowtype; v_ex int; v_hr int;
begin
  perform public._db_guard();
  perform public._db_lock_reap();
  select * into cfg from public.db_work_lock_config where id;
  select count(*) filter (where kind = 'exclusive'),
         count(*) filter (where kind = 'heavy_read')
    into v_ex, v_hr from public.db_work_lock;

  return jsonb_build_object('ok', true,
    'exclusive_held', v_ex, 'exclusive_slots', cfg.exclusive_slots,
    'heavy_read_held', v_hr, 'heavy_read_slots', cfg.heavy_read_slots,
    'exclusive_free', greatest(cfg.exclusive_slots - v_ex - v_hr, 0),
    'heavy_read_free', case when v_ex > 0 then 0 else greatest(cfg.heavy_read_slots - v_hr, 0) end,
    'ttl_minutes', cfg.ttl_minutes,
    'retry_after_seconds', cfg.retry_after_seconds,
    'held', coalesce((select jsonb_agg(jsonb_build_object(
              'token', l.token, 'kind', l.kind, 'holder', l.holder, 'title', l.title,
              'command_id', l.command_id,
              'held_for_seconds', round(extract(epoch from (now() - l.acquired_at)))::int,
              'expires_in_seconds', greatest(round(extract(epoch from (l.expires_at - now())))::int, 0))
            order by l.acquired_at) from public.db_work_lock l), '[]'::jsonb));
end $$;

revoke all on function public._db_lock_reap() from public;
revoke all on function public.db_lock_try(text, text, text, int, bigint) from public;
revoke all on function public.db_lock_release(uuid) from public;
revoke all on function public.db_lock_status() from public;
grant execute on function public.db_lock_try(text, text, text, int, bigint) to authenticated, service_role;
grant execute on function public.db_lock_release(uuid) to authenticated, service_role;
grant execute on function public.db_lock_status() to authenticated, service_role;

alter table public.db_work_lock enable row level security;
alter table public.db_work_lock_config enable row level security;
