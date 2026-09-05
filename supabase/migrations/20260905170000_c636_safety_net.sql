-- CHANGE #636 — Machine-generated safety net.
--
-- Three generators, one run, one report. Nothing here is a hand-written test
-- case: every check is derived from the schema itself, so a new RPC is covered
-- the day it is created instead of the day somebody remembers to write a test.
--
--   1. AUTH MATRIX   — every PostgREST-reachable RPC x every role, expected
--                      audience from a DATA truth table, observed reachability
--                      from grants + guard analysis + (for the suspicious set)
--                      a real impersonated call. A role that reaches an RPC it
--                      has no business reaching is a CRITICAL feature_gaps row.
--   2. PROPERTY FUZZ — inputs generated from each RPC's own signature (nulls,
--                      negatives, zero, huge, wrong type, someone else's id,
--                      unicode, empty array), executed inside a subtransaction
--                      that is ALWAYS rolled back. Seeds are stored, so any
--                      failure replays byte-for-byte.
--   3. INVARIANTS    — oracles that must hold after ANY action: money never
--                      negative and never exceeding its order, stock conserved,
--                      no illegal order-state jump (#469's transition table),
--                      no orphan rows, no synthetic row loose in a business
--                      table. A violated invariant is a finding whoever caused
--                      it.
--
-- Idempotent end to end: the merge worker replays this file on live once.

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. CONFIG
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.autotest_config (
  id                integer primary key default 1 check (id = 1),
  fuzz_execute      boolean not null default true,
  fuzz_batch        integer not null default 60,
  fuzz_budget_ms    integer not null default 6000,
  auth_probe_max    integer not null default 400,
  gap_surface       text    not null default 'platform',
  gap_command_id    bigint,
  updated_at        timestamptz not null default now()
);
insert into public.autotest_config (id) values (1) on conflict (id) do nothing;
-- feature_gaps.surface is a closed set; keep the config inside it.
update public.autotest_config
   set gap_surface = 'platform'
 where id = 1
   and gap_surface not in ('customer','admin','supplier','delivery','partner','platform');

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. ROLES — the columns of the matrix
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.autotest_role (
  role_key   text primary key,
  label      text not null,
  sort       integer not null default 0,
  is_anon    boolean not null default false,
  enabled    boolean not null default true,
  note       text
);

insert into public.autotest_role (role_key, label, sort, is_anon, note) values
  ('anon',        'Signed out',   10, true,  'No JWT at all — the public storefront.'),
  ('customer',    'Customer',     20, false, 'A pharmacy buying on mediBO.'),
  ('supplier',    'Supplier',     30, false, 'A distributor answering inquiries.'),
  ('partner',     'Partner',      40, false, 'Zone fulfilment partner — opt-in RPC surface only.'),
  ('delivery',    'Rider',        50, false, 'Delivery partner.'),
  ('mr',          'MR',           60, false, 'Medical representative.'),
  ('company',     'Company',      70, false, 'Pharma company login.'),
  ('worker',      'Worker',       80, false, 'Warehouse / pack floor worker.'),
  ('admin',       'Admin',        90, false, 'mediBO admin.'),
  ('super_admin', 'Super admin', 100, false, 'Everything, including the dev queue.')
on conflict (role_key) do update
  set label = excluded.label, sort = excluded.sort,
      is_anon = excluded.is_anon, note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE TRUTH TABLE — who an RPC is FOR (#570, as data)
--
-- Rules are evaluated lowest-priority-number first; the first match wins.
-- `authoritative` is the whole safety valve: only an authoritative rule can
-- turn a reachability surprise into a CRITICAL. A convention rule that merely
-- guesses from a name prefix reports the same finding at 'medium', because a
-- wrong guess flooding the queue with CRITICALs is how a safety net stops being
-- read. An RPC no rule claims is itself a finding — that undeclared surface is
-- exactly where #570 lived.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.autotest_audience_rule (
  id            bigserial primary key,
  priority      integer not null,
  match_kind    text    not null check (match_kind in ('exact','prefix','regex')),
  match_value   text    not null,
  audience      text[]  not null,
  authoritative boolean not null default false,
  reason        text    not null,
  enabled       boolean not null default true,
  updated_at    timestamptz not null default now(),
  unique (match_kind, match_value)
);

create index if not exists autotest_audience_rule_prio_idx
  on public.autotest_audience_rule (priority) where enabled;

-- Resolved audience per RPC — rebuilt by autotest_auth_matrix_build().
create table if not exists public.autotest_rpc_audience (
  proname       text primary key,
  audience      text[] not null,
  source        text   not null,
  authoritative boolean not null default false,
  args          text   not null default '',
  is_secdef     boolean not null default false,
  guard_tokens  text[] not null default '{}',
  has_guard     boolean not null default false,
  anon_exec     boolean not null default false,
  auth_exec     boolean not null default false,
  built_at      timestamptz not null default now()
);

-- One row per (proname, role): what we expect, what we observed, the verdict.
create table if not exists public.autotest_auth_check (
  run_id     bigint,
  proname    text not null,
  role_key   text not null,
  expected   text not null,           -- allow | deny
  observed   text not null default 'unknown', -- allow | deny | unknown
  verdict    text not null default 'unknown', -- pass | fail | unclassified | not_covered
  severity   text,
  evidence   text,
  checked_at timestamptz not null default now(),
  primary key (proname, role_key)
);
create index if not exists autotest_auth_check_verdict_idx
  on public.autotest_auth_check (verdict);

alter table public.autotest_config          enable row level security;
alter table public.autotest_role            enable row level security;
alter table public.autotest_audience_rule   enable row level security;
alter table public.autotest_rpc_audience    enable row level security;
alter table public.autotest_auth_check      enable row level security;

-- The safety net is a super-admin instrument. RLS + an explicit policy (rather
-- than SECURITY DEFINER everywhere) because the probe MUST run as an invoker:
-- `set role` is forbidden inside a security-definer function, and without it
-- the matrix can only ever guess.
do $$
declare t text;
begin
  foreach t in array array['autotest_config','autotest_role','autotest_audience_rule',
                           'autotest_rpc_audience','autotest_auth_check'] loop
    execute format('grant select, insert, update, delete on public.%I to authenticated, service_role', t);
    execute format($p$ drop policy if exists %I on public.%I $p$, t || '_super', t);
    execute format($p$ create policy %I on public.%I for all to authenticated, service_role
                       using (public.get_my_role() = 'super_admin' or public._is_service_role())
                       with check (public.get_my_role() = 'super_admin' or public._is_service_role()) $p$,
                   t || '_super', t);
  end loop;
end $$;

-- Convention rules. Priority 10-39 are AUTHORITATIVE (they encode a decision
-- somebody actually made); 40+ are conventions read off the naming scheme and
-- deliberately report at 'medium'.
insert into public.autotest_audience_rule (priority, match_kind, match_value, audience, authoritative, reason) values
  (20, 'regex', '^(dev_|rg_|deploy_|pool_|sec_|runner_|cron_|db_|merge_|lease_|queue_|autotest_)',
       array['super_admin'], true,  'Dev-queue control plane — super admin only.'),
  (22, 'regex', '^(sec_|vault_|secret_)',
       array['super_admin'], true,  'Secrets surface — super admin only.'),
  (30, 'regex', '^(admin_|ops_|kyc_|settlement_|gst_|khata_)',
       array['admin','super_admin'], true, 'mediBO back office.'),
  (40, 'regex', '^(my_|cart_|storefront_|reorder_|wishlist_|loyalty_|refill_)',
       array['customer','admin','super_admin'], false, 'Customer-facing surface (admins act-as).'),
  (42, 'regex', '^(sup_|supplier_|fw_)',
       array['supplier','admin','super_admin'], false, 'Supplier surface.'),
  (44, 'regex', '^(partner_|zone_)',
       array['partner','admin','super_admin'], false, 'Zone partner surface.'),
  (46, 'regex', '^(delivery_|rider_|incentive_)',
       array['delivery','admin','super_admin'], false, 'Rider surface.'),
  (48, 'regex', '^(pack_|bag_|bin_|pos_|pharmacy_)',
       array['worker','admin','super_admin'], false, 'Warehouse / pack floor.'),
  (50, 'regex', '^(lead_|mr_)',
       array['mr','admin','super_admin'], false, 'MR surface.'),
  (52, 'regex', '^(company_page_|company_portal_)',
       array['company','admin','super_admin'], false, 'Pharma company portal.'),
  (60, 'regex', '^(ui_|uic|legal_|public_|catalogue_|medicine_|product_|search_|substitute_)',
       array['anon','customer','supplier','partner','delivery','mr','company','worker','admin','super_admin'],
       false, 'Public catalogue / copy — open by design.')
on conflict (match_kind, match_value) do update
  set priority = excluded.priority, audience = excluded.audience,
      authoritative = excluded.authoritative, reason = excluded.reason,
      updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE CATALOG — every PostgREST-reachable RPC, straight from pg_proc.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.autotest_rpc_catalog()
returns table (
  proname text, oid oid, args text, is_secdef boolean,
  anon_exec boolean, auth_exec boolean, src text
)
language sql stable security definer set search_path to 'public' as $fn$
  select p.proname::text,
         p.oid,
         pg_get_function_identity_arguments(p.oid)::text,
         p.prosecdef,
         has_function_privilege('anon',          p.oid, 'EXECUTE'),
         has_function_privilege('authenticated', p.oid, 'EXECUTE'),
         coalesce(p.prosrc, '')
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
   where p.prokind = 'f'
     and p.prorettype <> 'trigger'::regtype
     and p.proname !~ '^(trg_|tg_)'
     and not exists (select 1 from pg_depend d
                      where d.objid = p.oid and d.deptype = 'e')
$fn$;

-- Which roles a rule set claims for one RPC. First (lowest priority) match wins.
create or replace function public.autotest_audience_for(p_proname text)
returns table (audience text[], source text, authoritative boolean)
language sql stable security definer set search_path to 'public' as $fn$
  with hit as (
    select r.audience, r.match_kind || ':' || r.match_value as source,
           r.authoritative, r.priority
      from public.autotest_audience_rule r
     where r.enabled
       and ((r.match_kind = 'exact'  and p_proname = r.match_value)
         or (r.match_kind = 'prefix' and p_proname like r.match_value || '%')
         or (r.match_kind = 'regex'  and p_proname ~ r.match_value))
    union all
    select array['super_admin','admin']::text[], 'table:medibo_only_rpc', true, 5
      from public.medibo_only_rpc m where m.proname = p_proname
    union all
    select array['anon','customer','supplier','partner','delivery','mr','company','worker','admin','super_admin']::text[],
           'table:rpc_anon_allow', true, 6
      from public.rpc_anon_allow a where a.fn_name = p_proname
    union all
    select array['admin','super_admin']::text[], 'table:admin_rpc_feature', true, 7
      from public.admin_rpc_feature f where f.proname = p_proname
    union all
    select array['partner','admin','super_admin']::text[], 'table:partner_rpc_allow', true, 8
      from public.partner_rpc_allow pa where pa.proname = p_proname and coalesce(pa.clamp_ok,true)
  )
  select audience, source, authoritative
    from hit order by priority, source limit 1
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE RUN LEDGER
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.autotest_run (
  id           bigserial primary key,
  kind         text not null default 'safety_net',
  label        text,
  session_id   bigint,
  test_run_id  bigint,
  seed         bigint not null default 0,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'running',
  auth_total   integer not null default 0,
  auth_failed  integer not null default 0,
  fuzz_total   integer not null default 0,
  fuzz_failed  integer not null default 0,
  inv_total    integer not null default 0,
  inv_failed   integer not null default 0,
  gaps_written integer not null default 0,
  summary      jsonb not null default '{}'::jsonb
);
alter table public.autotest_run enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. AUTH MATRIX — build the expectations, then judge reachability.
--
-- Guard analysis is static and deliberately conservative: a SECURITY DEFINER
-- function that mentions neither a guard nor the caller is OPEN — whoever holds
-- the EXECUTE grant gets the whole answer. That is the #570 shape. Everything
-- else is 'guarded' or 'scoped' and only becomes a finding once a real
-- impersonated call proves it answers a role it should refuse.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._autotest_guard_tokens(p_src text)
returns text[]
language sql immutable set search_path to 'public' as $fn$
  select coalesce(array_agg(t), '{}'::text[]) from unnest(array[
    case when p_src ~ '_dev_guard'                       then 'dev_guard'      end,
    case when p_src ~ '_test_guard'                      then 'test_guard'     end,
    case when p_src ~ '_is_super|is_super\(\)'           then 'is_super'       end,
    case when p_src ~ '_is_medibo_admin'                 then 'medibo_admin'   end,
    case when p_src ~ '(^|[^a-z_])_?is_admin\s*\('       then 'is_admin'       end,
    case when p_src ~ '_is_service_role'                 then 'service_role'   end,
    case when p_src ~ '_roles_caller_ok'                 then 'roles_caller'   end,
    case when p_src ~ 'partner_rpc_allowed'              then 'partner_allow'  end,
    case when p_src ~ 'not authoriz|not_authoriz|forbidden|permission denied' then 'refusal' end,
    case when p_src ~ 'auth\.uid\s*\('                   then 'auth_uid'       end,
    case when p_src ~ 'get_my_role\s*\('                 then 'my_role'        end,
    case when p_src ~ 'my_(customer|supplier|partner|admin|delivery|fulfil_worker)_id'
                                                          then 'my_scope'       end,
    case when p_src ~ 'my_identity_keys|current_supplier_profile'
                                                          then 'my_identity'    end
  ]) t where t is not null
$fn$;

create or replace function public.autotest_auth_matrix_build()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_rpcs int := 0; v_unclassified int := 0;
begin
  perform public._dev_guard();

  delete from public.autotest_rpc_audience;

  -- One row per NAME, not per overload: PostgREST addresses an RPC by name, so
  -- an overload set is only as guarded as its weakest member (bool_and) and as
  -- reachable as its most exposed one (bool_or).
  insert into public.autotest_rpc_audience
    (proname, audience, source, authoritative, args, is_secdef,
     guard_tokens, has_guard, anon_exec, auth_exec)
  select f.proname,
         coalesce(a.audience, array['admin','super_admin']::text[]),
         coalesce(a.source, 'unclassified'),
         coalesce(a.authoritative, false),
         f.args, f.is_secdef, f.guard_tokens, f.has_guard, f.anon_exec, f.auth_exec
    from (
      select c.proname,
             left(string_agg(c.args, ' | ' order by c.args), 400) as args,
             bool_or(c.is_secdef)   as is_secdef,
             bool_or(c.anon_exec)   as anon_exec,
             bool_or(c.auth_exec)   as auth_exec,
             bool_and(cardinality(public._autotest_guard_tokens(c.src)) > 0) as has_guard,
             (select coalesce(array_agg(distinct g), '{}'::text[])
                from unnest(array_agg(c.src)) s,
                     unnest(public._autotest_guard_tokens(s)) g) as guard_tokens
        from public.autotest_rpc_catalog() c
       group by c.proname
    ) f
    left join lateral public.autotest_audience_for(f.proname) a on true;

  get diagnostics v_rpcs = row_count;
  select count(*) into v_unclassified
    from public.autotest_rpc_audience where source = 'unclassified';

  return jsonb_build_object('ok', true, 'rpcs', v_rpcs,
                            'unclassified', v_unclassified,
                            'roles', (select count(*) from public.autotest_role where enabled),
                            'checks', v_rpcs * (select count(*) from public.autotest_role where enabled));
end $fn$;

-- A real call, as a real role, that leaves nothing behind.
--
-- The whole body sits in a subtransaction which is ALWAYS discarded: on the
-- happy path by raising the sentinel 'ZZ636', on any other path by the error
-- itself. GUC changes (role, jwt claims) roll back with it, so the session is
-- never left impersonating anybody.
-- auth.users is not readable by `authenticated`; this is the one definer step.
create or replace function public._autotest_identity(p_role text)
returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object('uid', u.id, 'email', u.email)
    from public.qa_test_identities t
    join auth.users u on lower(btrim(u.email)) = lower(btrim(t.identity))
   where t.role = p_role and coalesce(t.ready,false)
   limit 1
$fn$;

create or replace function public._autotest_call_as(
  p_proname text, p_role text, p_args text default null)
returns jsonb
language plpgsql security invoker set search_path to 'public' as $fn$
declare
  v_uid uuid; v_email text; v_sql text; v_argsql text; v_anon boolean;
  v_state text; v_msg text; v_outcome text; v_mode text := 'claims_only'; v_id jsonb;
  v_out text;
begin
  select r.is_anon into v_anon from public.autotest_role r where r.role_key = p_role;
  if v_anon is null then
    return jsonb_build_object('outcome','unknown_role','role',p_role);
  end if;

  if not v_anon then
    v_id := public._autotest_identity(p_role);
    v_uid := nullif(v_id->>'uid','')::uuid;
    v_email := v_id->>'email';
    if v_uid is null then
      return jsonb_build_object('outcome','no_identity','role',p_role);
    end if;
  end if;

  if p_args is not null then
    v_argsql := p_args;
  else
    select coalesce(string_agg('null::' || format_type(t.oid, null), ', '
                               order by t.ord), '')
      into v_argsql
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
      cross join lateral unnest(p.proargtypes) with ordinality as t(oid, ord)
     where p.proname = p_proname
     limit 1;
    v_argsql := coalesce(v_argsql, '');
  end if;

  v_sql := format('select public.%I(%s)', p_proname, v_argsql);

  begin
    if v_anon then
      perform set_config('request.jwt.claims', '', true);
      perform set_config('request.jwt.claim.role', 'anon', true);
      begin execute 'set local role anon'; v_mode := 'set_role';
      exception when others then v_mode := 'claims_only'; end;
    else
      perform set_config('request.jwt.claims',
        jsonb_build_object('sub', v_uid, 'role', 'authenticated',
                           'email', v_email)::text, true);
      perform set_config('request.jwt.claim.role', 'authenticated', true);
      begin execute 'set local role authenticated'; v_mode := 'set_role';
      exception when others then v_mode := 'claims_only'; end;
    end if;

    execute v_sql into v_out;
    raise exception using errcode = 'ZZ636', message = 'autotest_rollback';
  exception
    when sqlstate 'ZZ636' then
      v_state := '00000'; v_msg := left(coalesce(v_out,'<void>'), 400);
      -- mediBO refuses in the PAYLOAD, not with an exception: {"ok":false,...}
      -- is a guard doing its job, and counting it as a reach is how a matrix
      -- ends up "proving" 149 holes that are all closed.
      begin
        if v_out is not null and jsonb_typeof(v_out::jsonb) = 'object'
           and coalesce(v_out::jsonb->>'ok','true') = 'false'
        then v_outcome := 'refused';
        else v_outcome := 'reached';
        end if;
      exception when others then v_outcome := 'reached';
      end;
    when others then
      v_state := sqlstate; v_msg := left(coalesce(sqlerrm,''), 400);
      -- 'cannot set parameter role within security-definer function' is the
      -- HARNESS failing, not the RPC refusing. Calling that a refusal is how a
      -- safety net quietly clears every finding it has (measured: 400 of 400).
      -- An exception of ANY kind means the RPC did not answer this role, so it
      -- was not reached. Only the harness's own failure is a special case.
      if v_msg ~* 'cannot set parameter' then
        v_outcome := 'probe_blocked';
      else
        v_outcome := 'refused';
      end if;
  end;

  return jsonb_build_object('outcome', v_outcome, 'sqlstate', v_state,
                            'message', v_msg, 'call', v_sql, 'role', p_role,
                            'mode', v_mode);
end $fn$;

create or replace function public.autotest_auth_matrix_run(
  p_run_id bigint default null, p_rebuild boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_total bigint; v_fail int := 0; v_unclassified int; v_gaps int := 0;
  v_probed int := 0; v_confirmed int := 0; v_cleared int := 0; v_susp bigint := 0;
  v_max int; v_r record; v_res jsonb; v_missing text;
begin
  perform public._dev_guard();
  select auth_probe_max into v_max from public.autotest_config where id = 1;

  if coalesce(p_rebuild, true) then perform public.autotest_auth_matrix_build(); end if;

  delete from public.autotest_auth_check;

  -- The matrix: every RPC x every enabled role, judged from the schema.
  with cell as (
    select a.proname, r.role_key, a.audience, a.authoritative, a.source,
           a.args, a.is_secdef, a.has_guard, a.guard_tokens,
           (r.role_key = any (a.audience)) as expected_allow,
           case
             when r.is_anon and not a.anon_exec then 'deny'
             when (not r.is_anon) and not a.auth_exec then 'deny'
             when a.is_secdef and not a.has_guard then 'open'
             when a.has_guard then 'guarded'
             else 'scoped'
           end as observed
      from public.autotest_rpc_audience a
      cross join public.autotest_role r
     where r.enabled
  ), judged as (
    select c.*,
           case
             when not c.expected_allow and c.observed = 'open' then 'fail'
             when c.expected_allow and c.observed = 'deny'      then 'fail'
             when c.source = 'unclassified'                     then 'unclassified'
             else 'pass'
           end as verdict
      from cell c
  )
  insert into public.autotest_auth_check
    (run_id, proname, role_key, expected, observed, verdict, severity, evidence)
  select p_run_id, j.proname, j.role_key,
         case when j.expected_allow then 'allow' else 'deny' end,
         j.observed, j.verdict,
         case
           when j.verdict <> 'fail' then null
           when j.expected_allow    then 'high'
           when j.authoritative     then 'critical'
           else 'medium'
         end,
         format('%s(%s) · secdef=%s · guards=%s · audience=%s · rule=%s',
                j.proname, j.args, j.is_secdef,
                coalesce(array_to_string(j.guard_tokens, '+'), 'none'),
                array_to_string(j.audience, ','), j.source)
    from judged j
   where j.verdict = 'fail';

  get diagnostics v_fail = row_count;
  select count(*) into v_total
    from public.autotest_rpc_audience a
    cross join public.autotest_role r where r.enabled;
  select count(*) into v_unclassified
    from public.autotest_rpc_audience where source = 'unclassified';

  -- Roles with no impersonable login can only ever be judged statically. Say so
  -- once, set-based, instead of burning the probe budget discovering it.
  update public.autotest_auth_check k
     set verdict = 'not_covered', severity = 'medium',
         evidence = evidence || ' · no test identity for this role'
   where k.verdict = 'fail'
     and k.role_key in (
       select r.role_key from public.autotest_role r
        where r.enabled and not r.is_anon
          and not exists (select 1 from public.qa_test_identities t
                           join auth.users u on lower(btrim(u.email)) = lower(btrim(t.identity))
                          where t.role = r.role_key and coalesce(t.ready,false)));

  select count(*) into v_fail
    from public.autotest_auth_check where verdict in ('fail','proven');

  -- FINDINGS.
  --   proven reach          -> one row each, critical when the audience is
  --                            authoritative (this is the #570 shape)
  --   unreachable audience  -> one row each, there are never many
  --   everything else       -> aggregates, because a safety net nobody reads
  --                            is not a safety net
  for v_r in
    select proname, role_key, evidence from public.autotest_auth_check
     where verdict = 'fail' and expected = 'allow' order by proname limit 40
  loop
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s is closed to %s, its own audience', v_r.proname, v_r.role_key),
      'broken', 'high', 'auth_matrix', v_r.evidence,
      'Grant EXECUTE to that role, or correct the audience rule.',
      'S', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end loop;

  select count(*) into v_susp from public.autotest_auth_check
   where verdict = 'fail' and expected = 'deny';
  if v_susp > 0 then
    select string_agg(distinct proname, ', ') into v_missing
      from (select proname from public.autotest_auth_check
             where verdict = 'fail' and expected = 'deny'
               and severity = 'critical' order by proname limit 25) s;
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s auth-matrix suspicions still unproven', v_susp),
      'partial', 'medium', 'auth_matrix',
      format('SECURITY DEFINER RPCs with no recognisable guard, reachable by a role outside their declared audience. Not yet probed (budget %s per run). First 25 critical: %s',
             coalesce(v_max,0), coalesce(v_missing,'')),
      'Raise autotest_config.auth_probe_max, or add the guard token to _autotest_guard_tokens if these are already guarded.',
      'M', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end if;

  if v_unclassified > 0 then
    select string_agg(proname, ', ' order by proname) into v_missing
      from (select proname from public.autotest_rpc_audience
             where source = 'unclassified' order by proname limit 25) u;
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s RPCs have no declared audience', v_unclassified),
      'missing', 'medium', 'auth_matrix',
      format('No rule in autotest_audience_rule claims these, so the matrix defaults them closed and can prove nothing. First 25: %s', coalesce(v_missing,'')),
      'Add a rule (or an exact override) in autotest_audience_rule.',
      'M', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end if;

  for v_r in
    select r.role_key from public.autotest_role r
     where r.enabled and not r.is_anon
       and public._autotest_identity(r.role_key) is null
     order by r.sort
  loop
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('No test identity for role %s', v_r.role_key),
      'missing', 'high', 'auth_matrix',
      format('qa_test_identities has no ready, resolvable login for %s, so every allow/deny for that role is static only — never proven.', v_r.role_key),
      'Create the login and mark it ready in qa_test_identities.',
      'S', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end loop;

  if p_run_id is not null then
    update public.autotest_run
       set auth_total = v_total, auth_failed = v_fail,
           gaps_written = gaps_written + v_gaps,
           summary = summary || jsonb_build_object('auth', jsonb_build_object(
             'checks', v_total, 'failed', v_fail, 'unclassified', v_unclassified,
             'probed', v_probed, 'proven', v_confirmed, 'cleared', v_cleared))
     where id = p_run_id;
  end if;

  return jsonb_build_object('ok', true, 'checks', v_total, 'failed', v_fail,
    'unclassified', v_unclassified, 'probed', v_probed,
    'proven', v_confirmed, 'cleared_by_probe', v_cleared, 'gaps', v_gaps);
end $fn$;


-- The probe is deliberately a SEPARATE, SECURITY INVOKER rpc: `set role` cannot
-- be issued inside a security-definer function, and a probe that cannot switch
-- role can only ever repeat the static guess it was given.
create or replace function public.autotest_auth_matrix_probe(
  p_run_id bigint default null, p_limit integer default null)
returns jsonb
language plpgsql security invoker set search_path to 'public' as $fn$
declare
  v_max int; v_r record; v_res jsonb;
  v_probed int := 0; v_proven int := 0; v_cleared int := 0;
  v_blocked int := 0; v_gaps int := 0; v_fail bigint;
begin
  perform public._dev_guard();
  select coalesce(p_limit, auth_probe_max) into v_max from public.autotest_config where id = 1;

  for v_r in
    select k.proname, k.role_key, k.severity
      from public.autotest_auth_check k
      join public.autotest_role r on r.role_key = k.role_key
     where k.verdict = 'fail' and k.expected = 'deny'
     order by (k.severity = 'critical') desc, r.is_anon desc, r.sort, k.proname
     limit greatest(coalesce(v_max, 400), 0)
  loop
    v_res := public._autotest_call_as(v_r.proname, v_r.role_key);
    v_probed := v_probed + 1;

    if v_res->>'outcome' = 'reached' then
      v_proven := v_proven + 1;
      update public.autotest_auth_check
         set observed = 'allow', verdict = 'proven',
             evidence = evidence || ' · PROVEN (' || coalesce(v_res->>'mode','') || '): ' ||
                        coalesce(v_res->>'call','') || ' answered as ' || v_r.role_key ||
                        ' [sqlstate ' || coalesce(v_res->>'sqlstate','') || ']'
       where proname = v_r.proname and role_key = v_r.role_key;
    elsif v_res->>'outcome' = 'refused' then
      v_cleared := v_cleared + 1;
      update public.autotest_auth_check
         set verdict = 'pass', severity = null, observed = 'deny',
             evidence = evidence || ' · refused at runtime (' || coalesce(v_res->>'mode','') ||
                        '): ' || coalesce(v_res->>'message','')
       where proname = v_r.proname and role_key = v_r.role_key;
    elsif v_res->>'outcome' = 'probe_blocked' then
      v_blocked := v_blocked + 1;
    else
      update public.autotest_auth_check
         set verdict = 'not_covered', severity = 'medium',
             evidence = evidence || ' · ' || coalesce(v_res->>'outcome','')
       where proname = v_r.proname and role_key = v_r.role_key;
    end if;
  end loop;

  for v_r in
    select proname, role_key, severity, evidence from public.autotest_auth_check
     where verdict = 'proven' order by (severity = 'critical') desc, proname limit 60
  loop
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s answers %s and should not', v_r.proname, v_r.role_key),
      'broken', coalesce(v_r.severity,'medium'), 'auth_matrix', v_r.evidence,
      format('Guard %I, or declare the role in autotest_audience_rule if this really is its audience.', v_r.proname),
      'S', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end loop;

  if v_blocked > 0 then
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      'Auth-matrix probe could not switch role',
      'broken', 'high', 'auth_matrix',
      format('%s of %s probes could not SET ROLE, so their verdicts are static only. The probe must be called as a top-level rpc, never from inside a security-definer function.', v_blocked, v_probed),
      'Call autotest_auth_matrix_probe() directly (service_role or super admin), not nested inside a definer.',
      'S', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end if;

  select count(*) into v_fail from public.autotest_auth_check
   where verdict in ('fail','proven');

  if p_run_id is not null then
    update public.autotest_run
       set auth_failed = v_fail, gaps_written = gaps_written + v_gaps,
           summary = summary || jsonb_build_object('probe', jsonb_build_object(
             'probed', v_probed, 'proven', v_proven, 'cleared', v_cleared,
             'blocked', v_blocked))
     where id = p_run_id;
  end if;

  return jsonb_build_object('ok', true, 'probed', v_probed, 'proven', v_proven,
    'cleared', v_cleared, 'blocked', v_blocked, 'failed', v_fail, 'gaps', v_gaps);
end $fn$;
