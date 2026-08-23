-- CHANGE #301 — the DB watchdog.
--
-- The choke on 2026-08-23 (12:53-13:43 UTC) was invisible until customers felt
-- it: 40 statement timeouts, cron reporting "job startup timeout", trivial SETs
-- taking 15 s. Nothing in the database recorded any of it. This makes the next
-- one visible a minute after it starts.
--
-- It runs INSIDE the existing one-per-minute dispatcher (CHANGE #273), never as
-- a new `* * * * *` cron job — fifteen of those are what took the site down on
-- 2026-08-18, and adding a sixteenth to watch for overload would be comic.

create table if not exists public.db_watchdog_config (
  id                 boolean primary key default true check (id),
  conn_warn          int not null default 45,
  conn_max           int not null default 60,
  long_txn_seconds   int not null default 120,
  timeouts_5min_warn int not null default 10,
  retain_days        int not null default 7
);
insert into public.db_watchdog_config (id) values (true) on conflict (id) do nothing;

create table if not exists public.db_health_sample (
  at               timestamptz primary key default now(),
  conns            int not null,
  active           int not null,
  idle_in_txn      int not null,
  waiting          int not null,
  max_conns        int not null,
  longest_txn_s    int not null,
  longest_query_s  int not null,
  timeouts_5min    int not null,
  exclusive_held   int not null,
  heavy_read_held  int not null,
  detail           jsonb
);

-- Statement timeouts are not recorded anywhere in SQL — they live in the log
-- stream. Two things write here instead: pg_cron failures (read below) and any
-- agent/runner that catches SQLSTATE 57014 and reports it.
create table if not exists public.db_timeout_event (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  agent  text,
  detail jsonb
);
create index if not exists db_timeout_event_at_idx on public.db_timeout_event (at desc);

create or replace function public.db_timeout_report(p_agent text, p_detail jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public._db_guard();
  insert into public.db_timeout_event (agent, detail) values (coalesce(p_agent, 'agent'), p_detail);
  delete from public.db_timeout_event where at < now() - interval '7 days';
  return jsonb_build_object('ok', true, 'recorded', true);
end $$;

create or replace function public.db_watchdog_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $$
declare
  cfg     public.db_watchdog_config%rowtype;
  v_conns int; v_active int; v_idle_txn int; v_waiting int; v_max int;
  v_txn_s int; v_qry_s int; v_to int; v_cron_to int; v_ex int; v_hr int;
  v_bucket text := to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24');
  v_alerts int := 0;

begin
  select * into cfg from public.db_watchdog_config where id;

  select count(*),
         count(*) filter (where state = 'active'),
         count(*) filter (where state = 'idle in transaction'),
         count(*) filter (where wait_event_type = 'Lock'),
         coalesce(max(extract(epoch from (now() - xact_start)))::int, 0),
         coalesce(max(extract(epoch from (now() - query_start)) ) filter (where state = 'active')::int, 0)
    into v_conns, v_active, v_idle_txn, v_waiting, v_txn_s, v_qry_s
    from pg_stat_activity
   where datname = current_database();

  v_max := coalesce(nullif(current_setting('max_connections', true), '')::int, cfg.conn_max);

  select count(*) into v_to
    from public.db_timeout_event where at > now() - interval '5 minutes';
  select count(*) into v_cron_to
    from cron.job_run_details
   where start_time > now() - interval '5 minutes'
     and status is distinct from 'succeeded'
     and coalesce(return_message, '') ilike '%timeout%';
  v_to := v_to + v_cron_to;

  perform public._db_lock_reap();
  select count(*) filter (where kind = 'exclusive'), count(*) filter (where kind = 'heavy_read')
    into v_ex, v_hr from public.db_work_lock;

  insert into public.db_health_sample (at, conns, active, idle_in_txn, waiting, max_conns,
                                       longest_txn_s, longest_query_s, timeouts_5min,
                                       exclusive_held, heavy_read_held, detail)
  values (date_trunc('second', now()), v_conns, v_active, v_idle_txn, v_waiting, v_max,
          v_txn_s, v_qry_s, v_to, v_ex, v_hr,
          jsonb_build_object('cron_timeouts_5min', v_cron_to))
  on conflict (at) do nothing;

  delete from public.db_health_sample where at < now() - make_interval(days => cfg.retain_days);

  -- One alert row per condition per hour: a sustained choke dedupes into one
  -- row with a rising seen_count, while a fresh episode tomorrow is its own row.
  if v_conns > cfg.conn_warn then
    insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('db_watch|conns|' || v_bucket),
            case when v_conns > cfg.conn_max - 5 then 'critical' else 'warn' end,
            'db_connections', format('%s of %s connections in use', v_conns, v_max),
            jsonb_build_object('conns', v_conns, 'max', v_max, 'active', v_active,
                               'idle_in_txn', v_idle_txn, 'waiting', v_waiting))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = public.rg_alerts.seen_count + 1,
                                            detail = excluded.detail;
    v_alerts := v_alerts + 1;
  end if;

  if v_txn_s > cfg.long_txn_seconds then
    insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('db_watch|long_txn|' || v_bucket), 'warn', 'db_long_transaction',
            format('a transaction has been open %s s', v_txn_s),
            jsonb_build_object('seconds', v_txn_s, 'idle_in_txn', v_idle_txn,
                               'holders', coalesce((select jsonb_agg(jsonb_build_object(
                                   'pid', a.pid, 'user', a.usename, 'state', a.state,
                                   'seconds', round(extract(epoch from (now() - a.xact_start)))::int,
                                   'query', left(a.query, 200)))
                                 from pg_stat_activity a
                                where a.datname = current_database()
                                  and a.xact_start < now() - make_interval(secs => cfg.long_txn_seconds)),
                                 '[]'::jsonb)))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = public.rg_alerts.seen_count + 1,
                                            detail = excluded.detail;
    v_alerts := v_alerts + 1;
  end if;

  if v_to > cfg.timeouts_5min_warn then
    insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('db_watch|timeouts|' || v_bucket), 'critical', 'db_statement_timeouts',
            format('%s statement timeouts in 5 minutes', v_to),
            jsonb_build_object('count', v_to, 'from_cron', v_cron_to, 'conns', v_conns))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = public.rg_alerts.seen_count + 1,
                                            detail = excluded.detail;
    v_alerts := v_alerts + 1;
  end if;

  return jsonb_build_object('ok', true, 'conns', v_conns, 'longest_txn_s', v_txn_s,
                            'timeouts_5min', v_to, 'alerts', v_alerts);
end $$;

revoke all on function public.db_watchdog_tick() from public;
revoke all on function public.db_timeout_report(text, jsonb) from public;
grant execute on function public.db_watchdog_tick() to service_role;
grant execute on function public.db_timeout_report(text, jsonb) to authenticated, service_role;

alter table public.db_watchdog_config enable row level security;
alter table public.db_health_sample  enable row level security;
alter table public.db_timeout_event  enable row level security;

-- One minute cadence, zero new backends: the dispatcher already wakes once a
-- minute, and this is the cheapest task on it.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note)
values ('db_watchdog', 5, 'poll', 'select true', 'select public.db_watchdog_tick()', 5000, true,
        'CHANGE #301 — samples connections, longest transaction and statement timeouts every minute and raises rg_alerts before the instance chokes.')
on conflict (name) do update
  set ord = excluded.ord, mode = excluded.mode, gate_sql = excluded.gate_sql,
      work_sql = excluded.work_sql, step_timeout_ms = excluded.step_timeout_ms,
      enabled = true, note = excluded.note;
