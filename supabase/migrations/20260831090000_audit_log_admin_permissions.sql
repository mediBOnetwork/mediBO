-- CHANGE #394 — PART 1 of 3: the audit trail.
--
-- Before this migration there was NO audit_log table anywhere in mediBO:
-- partners were audited (partner_audit_log) while mediBO staff were not, and
-- three admins shared full power over a money system with nothing recording
-- who changed what.
--
-- The write path is deliberately NOT "every RPC remembers to call a logger".
-- A logger an RPC has to remember is a logger that can be bypassed by calling
-- PostgREST directly against the table. So the spine here is a generic ROW
-- trigger driven by a config table (audit_table_config): the row change itself
-- is what writes the audit entry, with before/after captured by Postgres, so a
-- direct table write is audited exactly like an RPC call. audit_write() sits
-- alongside it for ACTION-shaped events where a row diff does not tell the
-- story (a payment verified, an order cancelled, a preset applied).
--
-- Immutable by construction: no UPDATE, no DELETE, ever — enforced by a
-- trigger AND by revoked grants. RLS read is super-admin only.

-- ── the log ────────────────────────────────────────────────────────────────
create table if not exists public.audit_log (
  id            bigserial primary key,
  at            timestamptz not null default now(),
  actor_user_id uuid,
  actor_email   text,
  actor_role    text,
  action        text not null,
  entity_type   text not null,
  entity_id     text,
  before        jsonb,
  after         jsonb,
  changed_keys  text[],
  zone_id       smallint,
  source        text,
  ip            text
);

create index if not exists audit_log_at_idx      on public.audit_log (at desc);
create index if not exists audit_log_entity_idx  on public.audit_log (entity_type, entity_id, at desc);
create index if not exists audit_log_actor_idx   on public.audit_log (actor_user_id, at desc);
create index if not exists audit_log_action_idx  on public.audit_log (action, at desc);

-- ── immutability ───────────────────────────────────────────────────────────
create or replace function public.audit_log_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_log is append-only: % is not permitted', tg_op;
end $$;

drop trigger if exists audit_log_no_update on public.audit_log;
create trigger audit_log_no_update
  before update or delete on public.audit_log
  for each row execute function public.audit_log_immutable();

alter table public.audit_log enable row level security;

drop policy if exists audit_log_super_read on public.audit_log;
create policy audit_log_super_read on public.audit_log
  for select using (public._is_super());

revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;

-- ── the actor, resolved once ───────────────────────────────────────────────
-- Everything the log needs about "who did this", read from the session rather
-- than passed in by the caller: a caller that can name its own actor is not an
-- audit trail.
create or replace function public.audit_actor()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'auth'
as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'email',   public.my_login_email(),
    'role',    coalesce(public.get_my_role(), 'none'),
    'zone_id', (select a.zone_id from public.admins a
                 where a.id = auth.uid()
                    or lower(btrim(a.email)) = public.my_login_email()
                 limit 1),
    'source',  coalesce(nullif(auth.jwt() ->> 'role', ''), 'anon'),
    'ip',      nullif(btrim(split_part(
                 coalesce((current_setting('request.headers', true)::jsonb ->> 'x-forwarded-for'), ''),
                 ',', 1)), '')
  )
$$;

-- ── the explicit writer, for ACTION-shaped events ──────────────────────────
create or replace function public.audit_write(
  p_action      text,
  p_entity_type text,
  p_entity_id   text default null,
  p_before      jsonb default null,
  p_after       jsonb default null
) returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_a jsonb := public.audit_actor(); v_id bigint;
begin
  insert into public.audit_log(
    actor_user_id, actor_email, actor_role, action, entity_type, entity_id,
    before, after, changed_keys, zone_id, source, ip)
  values (
    (v_a->>'user_id')::uuid, v_a->>'email', v_a->>'role',
    p_action, p_entity_type, p_entity_id, p_before, p_after,
    case when p_before is not null and p_after is not null then
      (select coalesce(array_agg(k order by k), '{}')
         from (select jsonb_object_keys(p_after) as k) s
        where (p_after->s.k) is distinct from (p_before->s.k))
    end,
    nullif(v_a->>'zone_id','')::smallint, v_a->>'source', v_a->>'ip')
  returning id into v_id;
  return v_id;
end $$;

-- ── the config that decides which tables are audited ───────────────────────
-- A new audited table is one INSERT here plus one CREATE TRIGGER — never a
-- code change to the trigger function.
create table if not exists public.audit_table_config (
  table_name   text primary key,
  entity_type  text not null,
  pk_col       text not null default 'id',
  label        text not null,
  skip_cols    text[] not null default '{}',
  is_active    boolean not null default true
);

insert into public.audit_table_config(table_name, entity_type, pk_col, label, skip_cols) values
  ('admins',                      'admin',              'id',         'Admin',              '{}'),
  ('admin_permissions',           'admin_permission',   'admin_id',   'Admin permission',   '{updated_at}'),
  ('discount_slabs',              'discount_slab',      'id',         'Discount slab',      '{}'),
  ('payment_claims',              'payment_claim',      'id',         'Payment claim',      '{}'),
  ('partner_settlement_payments', 'partner_payment',    'id',         'Partner payment',    '{}'),
  ('partner_permissions',         'partner_permission', 'partner_id', 'Partner permission', '{updated_at}'),
  ('app_settings',                'config',             'key',        'Configuration',      '{}'),
  ('billing_config',              'config',             'id',         'Billing config',     '{}'),
  ('orders',                      'order',              'id',         'Order',              '{}')
on conflict (table_name) do update
  set entity_type = excluded.entity_type,
      pk_col      = excluded.pk_col,
      label       = excluded.label,
      skip_cols   = excluded.skip_cols,
      is_active   = true;

-- ── the generic row trigger ────────────────────────────────────────────────
-- Fires on the ROW, so a direct PostgREST write against the table is audited
-- exactly like an RPC. An UPDATE that changes nothing outside skip_cols writes
-- nothing — the log records changes, not touches.
create or replace function public.audit_row_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  cfg      public.audit_table_config;
  v_before jsonb;
  v_after  jsonb;
  v_keys   text[];
  v_id     text;
  v_a      jsonb;
begin
  select * into cfg from public.audit_table_config
   where table_name = tg_table_name and is_active;
  if cfg.table_name is null then return null; end if;

  if tg_op <> 'INSERT' then v_before := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_after  := to_jsonb(new); end if;

  select coalesce(array_agg(k order by k), '{}') into v_keys
    from (select jsonb_object_keys(coalesce(v_after, v_before)) as k) s
   where not (s.k = any (cfg.skip_cols))
     and (v_after -> s.k) is distinct from (v_before -> s.k);

  if tg_op = 'UPDATE' and cardinality(v_keys) = 0 then return null; end if;

  v_id := coalesce(v_after ->> cfg.pk_col, v_before ->> cfg.pk_col);
  v_a  := public.audit_actor();

  insert into public.audit_log(
    actor_user_id, actor_email, actor_role, action, entity_type, entity_id,
    before, after, changed_keys, zone_id, source, ip)
  values (
    (v_a->>'user_id')::uuid, v_a->>'email', v_a->>'role',
    cfg.entity_type || '.' || lower(tg_op), cfg.entity_type, v_id,
    v_before, v_after, v_keys,
    nullif(v_a->>'zone_id','')::smallint, v_a->>'source', v_a->>'ip');
  return null;
end $$;

-- ── attach it ──────────────────────────────────────────────────────────────
-- Every audited table gets the same statement; `orders` is narrowed by a WHEN
-- clause because it is the one table here a customer writes to on a normal
-- day, and an audit log full of routine order inserts hides the cancellations
-- it exists to show.
do $$
declare t text;
begin
  foreach t in array array[
    'admins','admin_permissions','discount_slabs','payment_claims',
    'partner_settlement_payments','partner_permissions','app_settings','billing_config']
  loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists zz_audit_row on public.%I', t);
      execute format(
        'create trigger zz_audit_row after insert or update or delete on public.%I
           for each row execute function public.audit_row_trg()', t);
    end if;
  end loop;
end $$;

drop trigger if exists zz_audit_row on public.orders;
create trigger zz_audit_row
  after update on public.orders
  for each row
  when (old.status is distinct from new.status)
  execute function public.audit_row_trg();

comment on table public.audit_log is
  'CHANGE #394 — append-only record of every consequential change. Written by '
  'audit_row_trg() (row triggers, un-bypassable) and audit_write() (action '
  'events). No UPDATE, no DELETE. RLS read: super-admin only.';
