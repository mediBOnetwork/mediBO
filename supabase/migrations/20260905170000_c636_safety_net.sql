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

-- ═════════════════════════════════════════════════════════════════════════════
-- PART 2 — PROPERTY FUZZING
--
-- Inputs are generated from each RPC's own signature, so a new argument is
-- fuzzed the day it is added. Every case is a pure function of
-- (seed, proname, variant, argument position), which is what makes a failure
-- replayable: the stored args_sql IS the reproduction.
-- ═════════════════════════════════════════════════════════════════════════════
create table if not exists public.autotest_fuzz_value (
  id         bigserial primary key,
  type_class text not null,          -- text | int | numeric | bool | uuid | date | ts | jsonb | array | other
  label      text not null,          -- what makes it hostile, in words
  literal    text not null,          -- the SQL that produces it, cast included
  hostility  text not null default 'edge'
             check (hostility in ('null','edge','wrong_type','foreign_id','unicode','huge')),
  enabled    boolean not null default true,
  unique (type_class, label)
);

create table if not exists public.autotest_fuzz_exempt (
  pattern    text primary key,
  reason     text not null,
  added_at   timestamptz not null default now()
);

create table if not exists public.autotest_fuzz_case (
  id         bigserial primary key,
  run_id     bigint,
  seed       bigint not null,
  variant    integer not null,
  proname    text not null,
  role_key   text not null,
  args_sql   text not null default '',
  args_label text not null default '',
  hostility  text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (run_id, proname, role_key, variant)
);

create table if not exists public.autotest_fuzz_result (
  case_id    bigint primary key references public.autotest_fuzz_case(id) on delete cascade,
  run_id     bigint,
  outcome    text not null,   -- answered | refused | input_rejected | probe_blocked | crash
  sqlstate   text,
  message    text,
  verdict    text not null,   -- pass | fail
  severity   text,
  assertion  text,
  ran_at     timestamptz not null default now()
);
create index if not exists autotest_fuzz_result_verdict_idx
  on public.autotest_fuzz_result (verdict, severity);

alter table public.autotest_fuzz_value  enable row level security;
alter table public.autotest_fuzz_exempt enable row level security;
alter table public.autotest_fuzz_case   enable row level security;
alter table public.autotest_fuzz_result enable row level security;

do $$
declare t text;
begin
  foreach t in array array['autotest_fuzz_value','autotest_fuzz_exempt',
                           'autotest_fuzz_case','autotest_fuzz_result','autotest_run'] loop
    execute format('grant select, insert, update, delete on public.%I to authenticated, service_role', t);
    execute format($p$ drop policy if exists %I on public.%I $p$, t || '_super', t);
    execute format($p$ create policy %I on public.%I for all to authenticated, service_role
                       using (public.get_my_role() = 'super_admin' or public._is_service_role())
                       with check (public.get_my_role() = 'super_admin' or public._is_service_role()) $p$,
                   t || '_super', t);
  end loop;
end $$;
grant usage, select on sequence public.autotest_fuzz_case_id_seq to authenticated, service_role;
grant usage, select on sequence public.autotest_run_id_seq       to authenticated, service_role;

-- Literals are stored WITHOUT their cast. The generator appends the argument's
-- REAL type, because a corpus that hardcodes `::integer` calls a bigint
-- function with an integer and gets '42883 function does not exist' — a
-- harness bug the fuzzer then files as a product bug. Measured: 8 of 8 first
-- findings were this.
insert into public.autotest_fuzz_value (type_class, label, literal, hostility) values
  ('text','null',              'null',                                  'null'),
  ('text','empty',             '''''',                                  'edge'),
  ('text','blank',             '''   ''',                               'edge'),
  ('text','unicode',           '''ਪੈਰਾਸਿਟਾਮੋਲ 💊 ₹ ﷽''',                 'unicode'),
  ('text','quote_and_backslash','''o''''brien \ %''',                  'edge'),
  ('text','huge',              'repeat(''x'', 100000)',                 'huge'),
  ('text','sql_shaped',        ''''' or 1=1 --''',                      'wrong_type'),
  ('text','uuid_shaped',       '''00000000-0000-0000-0000-000000000000''','foreign_id'),
  ('int','null',               'null',                                  'null'),
  ('int','zero',               '0',                                     'edge'),
  ('int','negative',           '(-1)',                                  'edge'),
  ('int','min',                '(-2147483648)',                         'huge'),
  ('int','max',                '2147483647',                            'huge'),
  ('numeric','null',           'null',                                  'null'),
  ('numeric','zero',           '0',                                     'edge'),
  ('numeric','negative_money', '(-999999.99)',                          'edge'),
  ('numeric','huge',           '1e18',                                  'huge'),
  ('numeric','fraction',       '0.000001',                              'edge'),
  ('bool','null',              'null',                                  'null'),
  ('bool','true',              'true',                                  'edge'),
  ('bool','false',             'false',                                 'edge'),
  ('uuid','null',              'null',                                  'null'),
  ('uuid','nil',               '''00000000-0000-0000-0000-000000000000''','foreign_id'),
  ('uuid','stranger',          '''ffffffff-ffff-4fff-8fff-ffffffffffff''','foreign_id'),
  ('date','null',              'null',                                  'null'),
  ('date','epoch',             '''1970-01-01''',                        'edge'),
  ('date','far_future',        '''9999-12-31''',                        'huge'),
  ('ts','null',                'null',                                  'null'),
  ('ts','epoch',               '''1970-01-01''',                        'edge'),
  ('ts','far_future',          '''9999-12-31''',                        'huge'),
  ('jsonb','null',             'null',                                  'null'),
  ('jsonb','empty_object',     '''{}''',                                'edge'),
  ('jsonb','empty_array',      '''[]''',                                'edge'),
  ('jsonb','wrong_shape',      '''{"__unexpected__": [1,2,3]}''',       'wrong_type'),
  ('jsonb','unicode',          '''{"note":"ਪੈਰਾ 💊"}''',                 'unicode'),
  ('array','null',             'null',                                  'null'),
  ('array','empty',            '''{}''',                                'edge'),
  ('other','null',             'null',                                  'null')
on conflict (type_class, label) do update
  set literal = excluded.literal, hostility = excluded.hostility;

insert into public.autotest_fuzz_exempt (pattern, reason) values
  ('sleep',            'Would stall the batch inside one transaction.'),
  ('dblink',           'Escapes the subtransaction — a rollback cannot undo it.'),
  ('^pg_',             'Server builtin, not a mediBO surface.'),
  ('_autotest_|^autotest_', 'The harness never fuzzes itself.'),
  ('^rg_baseline',     'Re-baselining the regression guard would bless a regression.')
on conflict (pattern) do update set reason = excluded.reason;

-- The argument list for one (rpc, seed, variant). Pure: the same three inputs
-- always produce the same SQL, which is what "seeds recorded so any failure is
-- replayable exactly" actually means.
create or replace function public._autotest_fuzz_args(
  p_proname text, p_seed bigint, p_variant integer)
returns jsonb
language sql stable security definer set search_path to 'public' as $fn$
  with t as (
    select format_type(a.oid, null) as tname, a.ord
      from (select p.proargtypes
              from pg_proc p
              join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
             where p.proname = p_proname and p.prokind = 'f'
             order by p.oid limit 1) pr
      cross join lateral unnest(pr.proargtypes) with ordinality as a(oid, ord)
  ), cls as (
    select ord, tname,
           case
             when tname like '%[]'                              then 'array'
             when tname in ('text','character varying','character','name','citext') then 'text'
             when tname in ('smallint','integer','bigint')       then 'int'
             when tname in ('numeric','real','double precision') then 'numeric'
             when tname = 'boolean'                              then 'bool'
             when tname = 'uuid'                                 then 'uuid'
             when tname = 'date'                                 then 'date'
             when tname like 'timestamp%' or tname like 'time%'  then 'ts'
             when tname in ('jsonb','json')                      then 'jsonb'
             else 'other'
           end as type_class
      from t
  ), pick as (
    select c.ord, c.tname, c.type_class, v.literal, v.label, v.hostility,
           row_number() over (
             partition by c.ord
             order by hashtextextended(
               p_proname || ':' || p_seed || ':' || p_variant || ':' || c.ord || ':' || v.id, 0)
           ) as rn
      from cls c
      join public.autotest_fuzz_value v
        on v.type_class = c.type_class and v.enabled
  ), one as (select * from pick where rn = 1)
  select jsonb_build_object(
    'sql', coalesce(string_agg('(' || literal || ')::' || tname, ', ' order by ord), ''),
    'label', coalesce(string_agg(tname || '=' || label, ', ' order by ord), 'no arguments'),
    'hostility', coalesce(to_jsonb(array_agg(distinct hostility)), '[]'::jsonb))
    from one
$fn$;

create or replace function public.autotest_fuzz_plan(
  p_run_id bigint default null, p_seed bigint default null,
  p_rpcs integer default 120, p_variants integer default 3,
  p_roles text[] default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare v_seed bigint; v_roles text[]; v_n int := 0;
begin
  perform public._dev_guard();
  v_seed := coalesce(p_seed, (extract(epoch from clock_timestamp()) * 1000)::bigint);

  v_roles := coalesce(p_roles, array(
    select r.role_key from public.autotest_role r
     where r.enabled and (r.is_anon or public._autotest_identity(r.role_key) is not null)
     order by r.sort));
  if v_roles is null or cardinality(v_roles) = 0 then
    v_roles := array['anon'];
  end if;

  insert into public.autotest_fuzz_case
    (run_id, seed, variant, proname, role_key, args_sql, args_label, hostility)
  select p_run_id, v_seed, g.variant, c.proname, rk.role_key,
         a.j->>'sql', a.j->>'label',
         coalesce(array(select jsonb_array_elements_text(a.j->'hostility')), '{}'::text[])
    from (
      select ra.proname
        from public.autotest_rpc_audience ra
       where not exists (select 1 from public.autotest_fuzz_exempt e
                          where ra.proname ~ e.pattern)
       order by hashtextextended(ra.proname, v_seed)
       limit greatest(coalesce(p_rpcs, 120), 0)
    ) c
    cross join generate_series(1, greatest(coalesce(p_variants, 3), 1)) g(variant)
    cross join unnest(v_roles) rk(role_key)
    cross join lateral (select public._autotest_fuzz_args(c.proname, v_seed, g.variant) as j) a
  on conflict (run_id, proname, role_key, variant) do nothing;

  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'seed', v_seed, 'cases', v_n,
                            'roles', to_jsonb(v_roles));
end $fn$;

-- Negative money / stock ANYWHERE in a returned payload. The oracle is the key
-- name, not the position, so a new field is covered the day it is added.
create or replace function public._autotest_negative_money(p_text text)
returns jsonb
language plpgsql immutable set search_path to 'public' as $fn$
declare v jsonb; v_hits jsonb;
begin
  begin v := p_text::jsonb; exception when others then return null; end;
  if v is null or jsonb_typeof(v) not in ('object','array') then return null; end if;
  select jsonb_agg(kv) into v_hits
    from jsonb_path_query(v, '$.**.keyvalue()') kv
   where kv->>'key' ~* '(amount|total|price|qty|quantity|stock|balance|due|paid|payable|mrp|rate|count)'
     and jsonb_typeof(kv->'value') = 'number'
     and (kv->>'value')::numeric < 0;
  return v_hits;
exception when others then return null;
end $fn$;

create or replace function public.autotest_fuzz_exec(
  p_run_id bigint default null, p_limit integer default null)
returns jsonb
language plpgsql security invoker set search_path to 'public' as $fn$
declare
  v_max int; v_budget int; v_deadline timestamptz; v_c record; v_res jsonb;
  v_state text; v_msg text; v_class text; v_outcome text; v_verdict text;
  v_sev text; v_assert text; v_neg jsonb;
  v_ran int := 0; v_fail int := 0; v_gaps int := 0; v_partial boolean := false;
begin
  perform public._dev_guard();
  select coalesce(p_limit, fuzz_batch), fuzz_budget_ms
    into v_max, v_budget from public.autotest_config where id = 1;
  v_deadline := clock_timestamp() + make_interval(secs => greatest(coalesce(v_budget,6000),1000) / 1000.0);

  for v_c in
    select c.* from public.autotest_fuzz_case c
     where (p_run_id is null or c.run_id is not distinct from p_run_id)
       and not exists (select 1 from public.autotest_fuzz_result r where r.case_id = c.id)
     order by c.id
     limit greatest(coalesce(v_max, 60), 0)
  loop
    if clock_timestamp() > v_deadline then v_partial := true; exit; end if;

    v_res     := public._autotest_call_as(v_c.proname, v_c.role_key, nullif(v_c.args_sql, ''));
    v_state   := coalesce(v_res->>'sqlstate', '');
    v_msg     := coalesce(v_res->>'message', '');
    v_class   := left(v_state, 2);
    v_verdict := 'pass'; v_sev := null; v_assert := null;

    if v_res->>'outcome' = 'probe_blocked' then
      v_outcome := 'probe_blocked';
    elsif v_res->>'outcome' = 'reached' or v_state = '00000' then
      v_outcome := 'answered';
      -- A3 — no negative money or stock in an answer.
      v_neg := public._autotest_negative_money(v_msg);
      if v_neg is not null then
        v_verdict := 'fail'; v_sev := 'critical'; v_assert := 'no_negative_money_or_stock';
        v_msg := v_msg || ' :: NEGATIVE ' || v_neg::text;
      -- A4 — a foreign id must not hand a non-admin an ok:true answer.
      elsif 'foreign_id' = any (v_c.hostility)
            and v_c.role_key not in ('admin','super_admin')
            and v_msg ~ '"ok"\s*:\s*true' and length(v_msg) > 120 then
        v_verdict := 'fail'; v_sev := 'high'; v_assert := 'no_cross_tenant_leak';
      end if;
    elsif v_state = 'P0001' then
      v_outcome := 'refused';                       -- a deliberate RAISE: correct
    elsif v_class = 'XX' then
      v_outcome := 'crash'; v_verdict := 'fail'; v_sev := 'critical';
      v_assert := 'no_500s';                        -- A1
    elsif v_state = '57014' then
      v_outcome := 'timeout'; v_verdict := 'fail'; v_sev := 'high';
      v_assert := 'no_500s';
    elsif v_state in ('42P01','42883','42501','42704','3F000','42P02') then
      -- The impersonated role cannot SEE the object (schema cron, an internal
      -- table). That is the guard working, not the RPC crashing: filing it as
      -- an unhandled input is how a fuzzer teaches people to ignore it.
      v_outcome := 'not_visible';
    elsif v_class in ('22','23','2F','39','40','21') then
      if 'wrong_type' = any (v_c.hostility) and v_class = '22' then
        v_outcome := 'input_rejected';              -- the boundary refused: correct
      else
        v_outcome := 'crash'; v_verdict := 'fail'; v_sev := 'high';
        v_assert := 'no_unhandled_input';           -- A2
      end if;
    else
      v_outcome := 'refused';
    end if;

    insert into public.autotest_fuzz_result
      (case_id, run_id, outcome, sqlstate, message, verdict, severity, assertion)
    values (v_c.id, v_c.run_id, v_outcome, nullif(v_state,''), left(v_msg, 1000),
            v_verdict, v_sev, v_assert)
    on conflict (case_id) do update
      set outcome = excluded.outcome, sqlstate = excluded.sqlstate,
          message = excluded.message, verdict = excluded.verdict,
          severity = excluded.severity, assertion = excluded.assertion,
          ran_at = now();

    v_ran := v_ran + 1;
    if v_verdict = 'fail' then v_fail := v_fail + 1; end if;
  end loop;

  -- Findings carry the seed and the exact call, so a fix can be re-run byte for
  -- byte: select public._autotest_call_as('<rpc>','<role>','<args_sql>').
  for v_c in
    select c.proname, c.role_key, c.seed, c.variant, c.args_sql, c.args_label,
           r.sqlstate, r.message, r.severity, r.assertion
      from public.autotest_fuzz_result r
      join public.autotest_fuzz_case c on c.id = r.case_id
     where r.verdict = 'fail'
       and (p_run_id is null or r.run_id is not distinct from p_run_id)
     order by (r.severity = 'critical') desc, c.proname
     limit 60
  loop
    perform public.feature_gap_add(
      (select gap_surface from public.autotest_config where id = 1),
      format('%s breaks on %s', v_c.proname, v_c.assertion),
      'broken', coalesce(v_c.severity, 'medium'), 'fuzz',
      format('as %s · seed %s variant %s · args %s · sqlstate %s · %s',
             v_c.role_key, v_c.seed, v_c.variant, v_c.args_label,
             coalesce(v_c.sqlstate,'-'), left(coalesce(v_c.message,''), 400)),
      format('Replay: select public._autotest_call_as(%L, %L, %L);',
             v_c.proname, v_c.role_key, v_c.args_sql),
      'S', null, (select gap_command_id from public.autotest_config where id = 1));
    v_gaps := v_gaps + 1;
  end loop;

  if p_run_id is not null then
    update public.autotest_run
       set fuzz_total = (select count(*) from public.autotest_fuzz_result
                          where run_id is not distinct from p_run_id),
           fuzz_failed = (select count(*) from public.autotest_fuzz_result
                           where run_id is not distinct from p_run_id and verdict = 'fail'),
           gaps_written = gaps_written + v_gaps,
           summary = summary || jsonb_build_object('fuzz', jsonb_build_object(
             'ran', v_ran, 'failed', v_fail, 'partial', v_partial))
     where id = p_run_id;
  end if;

  return jsonb_build_object('ok', true, 'ran', v_ran, 'failed', v_fail,
    'gaps', v_gaps, 'partial', v_partial);
end $fn$;

-- ═════════════════════════════════════════════════════════════════════════════
-- PART 3 — INVARIANT ORACLES
--
-- Things that must be true after ANY action, whoever took it. They run after
-- every bot action and after every fuzz batch, so a violation is attributed to
-- the action that broke it rather than found weeks later by a human.
--
-- `mode` is the difference between a safety net and an alarm nobody reads:
--   enforce — the check is EXACT (a negative price is never right). Violation
--             is CRITICAL.
--   observe — the check is a RECONCILIATION with legitimate rounding and
--             timing gaps. Violation is reported at its own severity and can be
--             promoted to enforce once it has been quiet on live.
-- A new oracle is one INSERT, never a deploy.
-- ═════════════════════════════════════════════════════════════════════════════
create table if not exists public.autotest_invariant (
  key         text primary key,
  family      text not null,           -- money | stock | state | orphan | synthetic
  title       text not null,
  detail      text not null default '',
  check_sql   text not null,           -- must return: n bigint, sample text
  severity    text not null default 'critical'
              check (severity in ('critical','high','medium','low')),
  mode        text not null default 'enforce' check (mode in ('enforce','observe')),
  enabled     boolean not null default true,
  sort        integer not null default 0,
  updated_at  timestamptz not null default now()
);

create table if not exists public.autotest_invariant_result (
  id          bigserial primary key,
  run_id      bigint,
  key         text not null,
  phase       text not null default 'run',   -- baseline | after_fuzz | after_action | run
  violations  bigint not null default 0,
  sample      text,
  verdict     text not null default 'pass',
  severity    text,
  ms          integer not null default 0,
  error       text,
  ran_at      timestamptz not null default now()
);
create index if not exists autotest_invariant_result_run_idx
  on public.autotest_invariant_result (run_id, key);

alter table public.autotest_invariant        enable row level security;
alter table public.autotest_invariant_result enable row level security;

do $$
declare t text;
begin
  foreach t in array array['autotest_invariant','autotest_invariant_result'] loop
    execute format('grant select, insert, update, delete on public.%I to authenticated, service_role', t);
    execute format($p$ drop policy if exists %I on public.%I $p$, t || '_super', t);
    execute format($p$ create policy %I on public.%I for all to authenticated, service_role
                       using (public.get_my_role() = 'super_admin' or public._is_service_role())
                       with check (public.get_my_role() = 'super_admin' or public._is_service_role()) $p$,
                   t || '_super', t);
  end loop;
end $$;
grant usage, select on sequence public.autotest_invariant_result_id_seq to authenticated, service_role;

-- Synthetic residue, discovered rather than listed: every business table that
-- HAS an is_synthetic column is checked, so a table that grows one tomorrow is
-- covered without editing this file.
create or replace function public._autotest_synthetic_residue()
returns table (n bigint, sample text)
language plpgsql stable security definer set search_path to 'public' as $fn$
declare r record; c bigint; total bigint := 0; hits text[] := '{}';
begin
  for r in
    select c1.table_name
      from information_schema.columns c1
     where c1.table_schema = 'public' and c1.column_name = 'is_synthetic'
       and exists (select 1 from information_schema.columns c2
                    where c2.table_schema = 'public' and c2.table_name = c1.table_name
                      and c2.column_name = 'test_session_id')
       and c1.table_name not like 'autotest%'
     order by c1.table_name
  loop
    begin
      execute format($q$
        select count(*) from public.%I t
         where t.is_synthetic
           and (t.test_session_id is null
                or not exists (select 1 from public.test_sessions s
                                where s.id = t.test_session_id and s.status = 'live'))
      $q$, r.table_name) into c;
    exception when others then c := 0;
    end;
    if coalesce(c,0) > 0 then
      total := total + c;
      hits := hits || (r.table_name || '=' || c);
    end if;
  end loop;
  n := total;
  sample := coalesce(array_to_string(hits[1:12], ', '), '');
  return next;
end $fn$;

-- Orphans in the relationships nobody declared a foreign key for. The pairs are
-- inferred from naming (<parent>_id), so this too is generated, not written.
create or replace function public._autotest_orphan_scan(
  p_max_pairs integer default 25, p_budget_ms integer default 3000)
returns table (n bigint, sample text)
language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  r record; c bigint; total bigint := 0; hits text[] := '{}'; pairs int := 0;
  v_deadline timestamptz := clock_timestamp()
                            + make_interval(secs => greatest(coalesce(p_budget_ms,3000),500)/1000.0);
begin
  -- Hard bounds, not politeness: this runs on a 1 GB instance shared by five
  -- builders. An unbounded version of this scan took the connection down.
  -- pg_catalog, never information_schema: those views are joins over every
  -- object in the database and on this schema the discovery query alone ran
  -- longer than the whole safety net is allowed to take.
  for r in
    with child as (
      select c.oid as reloid, c.relname as child, a.attname as col,
             a.atttypid as coltype, c.reltuples,
             left(a.attname, length(a.attname) - 3) || 's' as parent
        from pg_class c
        join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
       where c.relnamespace = 'public'::regnamespace
         and c.relkind = 'r'
         and c.relname not like 'autotest%'
         and c.reltuples between 1 and 50000
         and a.attname like '%\_id'
         and a.attname not in ('test_session_id','user_id','auth_user_id',
                               'client_action_id','run_id','case_id','command_id')
    )
    select ch.child, ch.col, ch.parent
      from child ch
      join pg_class p on p.relname = ch.parent
                     and p.relnamespace = 'public'::regnamespace
                     and p.relkind = 'r'
      join pg_attribute pa on pa.attrelid = p.oid and pa.attname = 'id'
                          and pa.atttypid = ch.coltype and not pa.attisdropped
     where not exists (
             select 1 from pg_constraint fk
              where fk.conrelid = ch.reloid and fk.contype = 'f'
                and ch.col = any (select att.attname from pg_attribute att
                                   where att.attrelid = fk.conrelid
                                     and att.attnum = any (fk.conkey)))
     order by ch.reltuples, ch.child, ch.col
  loop
    exit when pairs >= greatest(coalesce(p_max_pairs, 25), 1);
    exit when clock_timestamp() > v_deadline;
    pairs := pairs + 1;
    begin
      execute format($q$
        select count(*) from (
          select c.%I as v from public.%I c where c.%I is not null limit 5000
        ) s
        where not exists (select 1 from public.%I p where p.id = s.v)
      $q$, r.col, r.child, r.col, r.parent) into c;
    exception when others then c := 0;
    end;
    if coalesce(c,0) > 0 then
      total := total + c;
      hits := hits || (r.child || '.' || r.col || '=' || c);
    end if;
  end loop;
  n := total;
  sample := coalesce(array_to_string(hits[1:12], ', '), '') ||
            case when pairs = 0 then 'no undeclared pairs in range' else '' end;
  return next;
end $fn$;

insert into public.autotest_invariant (key, family, title, detail, check_sql, severity, mode, sort) values
 ('money.no_negative_order_total','money','An order total is never negative',
  'orders.total_amount below zero.',
  $s$select count(*)::bigint as n, coalesce(string_agg(id::text, ', '), '') as sample
       from (select id from public.orders where total_amount < 0 limit 20) s$s$,
  'critical','enforce',10),

 ('money.no_negative_line','money','An order line is never negative',
  'order_items.line_total or price below zero.',
  $s$select count(*)::bigint as n, coalesce(string_agg(id::text, ', '), '') as sample
       from (select id from public.order_items where line_total < 0 or price < 0 limit 20) s$s$,
  'critical','enforce',11),

 ('money.no_negative_payment','money','A payment is never negative',
  'payment_claims.amount below zero.',
  $s$select count(*)::bigint as n, coalesce(string_agg(id::text, ', '), '') as sample
       from (select id from public.payment_claims where amount < 0 limit 20) s$s$,
  'critical','enforce',12),

 ('money.no_negative_bill_line','money','A bill line is never negative',
  'bill_lines.line_amount or qty below zero.',
  $s$select count(*)::bigint as n, coalesce(string_agg(id::text, ', '), '') as sample
       from (select id from public.bill_lines where line_amount < 0 or qty < 0 limit 20) s$s$,
  'critical','enforce',13),

 ('money.payments_within_order','money','Payments never exceed the order they settle',
  'Sum of verified payment_claims for an order, against that order total plus delivery.',
  $s$with p as (
       select pc.order_id, sum(pc.amount) as paid
         from public.payment_claims pc
        where pc.order_id is not null and coalesce(pc.status,'') in ('verified','matched','linked')
        group by pc.order_id)
     select count(*)::bigint as n,
            coalesce(string_agg(format('%s paid %s vs %s', o.id, p.paid, o.total_amount), ', '), '') as sample
       from p join public.orders o on o.id = p.order_id
      where p.paid > coalesce(o.total_amount,0)
                     + coalesce(o.delivery_charge,0) + coalesce(o.delivery_charge_gst,0) + 1$s$,
  'high','observe',14),

 ('money.order_total_matches_items','money','An order total equals its lines',
  'orders.total_amount against sum(order_items.line_total) plus the delivery charge, +/- 1.',
  $s$with t as (
       select oi.order_id, sum(coalesce(oi.line_total,0)) as lines
         from public.order_items oi group by oi.order_id)
     select count(*)::bigint as n,
            coalesce(string_agg(format('%s total %s vs lines %s', o.id, o.total_amount, t.lines), ', '), '') as sample
       from t join public.orders o on o.id = t.order_id
      where coalesce(o.status,'') not in ('cancelled','closed','draft')
        and abs(coalesce(o.total_amount,0)
                - (t.lines + coalesce(o.delivery_charge,0) + coalesce(o.delivery_charge_gst,0))) > 1$s$,
  'high','observe',15),

 ('stock.no_negative_quantity','stock','A quantity is never negative',
  'order_items.quantity / received_qty / packed_qty below zero.',
  $s$select count(*)::bigint as n, coalesce(string_agg(id::text, ', '), '') as sample
       from (select id from public.order_items
              where coalesce(quantity,0) < 0 or coalesce(received_qty,0) < 0
                 or coalesce(packed_qty,0) < 0 limit 20) s$s$,
  'critical','enforce',20),

 ('stock.lot_balance_not_negative','stock','A stock lot never goes below zero',
  'Sum of stock_movement.qty per lot.',
  $s$select count(*)::bigint as n, coalesce(string_agg(lot::text || '=' || bal::text, ', '), '') as sample
       from (select lot_id as lot, sum(qty) as bal from public.stock_movement
              where lot_id is not null group by lot_id having sum(qty) < 0 limit 20) s$s$,
  'critical','enforce',21),

 ('stock.allocated_within_received','stock','Allocated never exceeds received',
  'bag_allocations.qty per order item against order_items.received_qty.',
  $s$with a as (select order_item_id, sum(coalesce(qty,0)) as alloc
                from public.bag_allocations where order_item_id is not null
               group by order_item_id)
     select count(*)::bigint as n,
            coalesce(string_agg(format('%s alloc %s vs recd %s', oi.id, a.alloc, oi.received_qty), ', '), '') as sample
       from a join public.order_items oi on oi.id = a.order_item_id
      where a.alloc > coalesce(oi.received_qty, 0)$s$,
  'high','observe',22),

 ('state.no_illegal_jump','state','No illegal order-state jump',
  'order_state_event rows the transition table has already judged illegal.',
  $s$select count(*)::bigint as n,
            coalesce(string_agg(format('%s %s->%s by %s', entity_kind, from_state, to_state, actor_role), ', '), '') as sample
       from (select entity_kind, from_state, to_state, actor_role
               from public.order_state_event where legal is false
              order by at desc limit 20) s$s$,
  'critical','enforce',30),

 ('state.transition_declared','state','Every transition taken is a declared one',
  'order_state_event against order_state_transitions (#469).',
  $s$select count(*)::bigint as n,
            coalesce(string_agg(format('%s %s->%s by %s', e.entity_kind, e.from_state, e.to_state, e.actor_role), ', '), '') as sample
       from (select distinct entity_kind, from_state, to_state, actor_role
               from public.order_state_event
              where at > now() - interval '30 days' limit 200) e
      where not exists (
        select 1 from public.order_state_transitions t
         where t.entity_kind = e.entity_kind and t.from_state = e.from_state
           and t.to_state = e.to_state and coalesce(t.is_active, true)
           and (t.actor_role is null or t.actor_role = e.actor_role))$s$,
  'high','observe',31),

 ('orphan.undeclared_parents','orphan','No orphan rows in undeclared relationships',
  'Columns named <parent>_id with no foreign key, scanned for values their parent does not have.',
  $s$select n, sample from public._autotest_orphan_scan(25, 3000)$s$,
  'high','observe',40),

 ('synthetic.no_residue','synthetic','No synthetic row loose in a business table',
  'is_synthetic rows with no live test session behind them.',
  $s$select n, sample from public._autotest_synthetic_residue()$s$,
  'critical','enforce',50)
on conflict (key) do update
  set family = excluded.family, title = excluded.title, detail = excluded.detail,
      check_sql = excluded.check_sql, severity = excluded.severity,
      mode = excluded.mode, sort = excluded.sort, updated_at = now();

create or replace function public.autotest_invariant_run(
  p_run_id bigint default null, p_phase text default 'run', p_family text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_i record; v_n bigint; v_sample text; v_t0 timestamptz; v_ms int;
  v_total int := 0; v_fail int := 0; v_gaps int := 0; v_err text;
  v_worst text := null;
begin
  perform public._dev_guard();

  for v_i in
    select * from public.autotest_invariant
     where enabled and (p_family is null or family = p_family)
     order by sort, key
  loop
    v_t0 := clock_timestamp(); v_n := 0; v_sample := null; v_err := null;
    begin
      execute v_i.check_sql into v_n, v_sample;
    exception when others then
      v_err := left(sqlstate || ' ' || coalesce(sqlerrm,''), 400); v_n := -1;
    end;
    v_ms := (extract(epoch from clock_timestamp() - v_t0) * 1000)::int;
    v_total := v_total + 1;

    insert into public.autotest_invariant_result
      (run_id, key, phase, violations, sample, verdict, severity, ms, error)
    values (p_run_id, v_i.key, coalesce(p_phase,'run'), greatest(coalesce(v_n,0),0),
            left(coalesce(v_sample,''), 800),
            case when v_err is not null then 'error'
                 when coalesce(v_n,0) > 0 then 'fail' else 'pass' end,
            case when coalesce(v_n,0) > 0 then v_i.severity else null end,
            v_ms, v_err);

    if v_err is not null then
      v_fail := v_fail + 1;
      perform public.feature_gap_add(
        (select gap_surface from public.autotest_config where id = 1),
        format('Invariant %s cannot run', v_i.key),
        'broken', 'high', 'invariant',
        format('%s · %s', v_i.title, v_err),
        'Fix the oracle SQL in autotest_invariant, or the schema it reads.',
        'S', null, (select gap_command_id from public.autotest_config where id = 1));
      v_gaps := v_gaps + 1;
    elsif coalesce(v_n,0) > 0 then
      v_fail := v_fail + 1;
      if v_worst is null or v_i.severity = 'critical' then v_worst := v_i.key; end if;
      perform public.feature_gap_add(
        (select gap_surface from public.autotest_config where id = 1),
        format('Invariant broken — %s', v_i.title),
        'broken',
        -- An exact oracle is CRITICAL whatever tripped it; a reconciliation
        -- keeps its own severity until it has been quiet on live.
        case when v_i.mode = 'enforce' then 'critical' else v_i.severity end,
        'invariant',
        format('%s · %s violation(s) at phase %s · %s',
               v_i.key, v_n, coalesce(p_phase,'run'), coalesce(v_sample,'')),
        format('Replay: %s', left(v_i.check_sql, 300)),
        'M', null, (select gap_command_id from public.autotest_config where id = 1));
      v_gaps := v_gaps + 1;
    end if;
  end loop;

  if p_run_id is not null then
    update public.autotest_run
       set inv_total = v_total, inv_failed = v_fail,
           gaps_written = gaps_written + v_gaps,
           summary = summary || jsonb_build_object('invariants_' || coalesce(p_phase,'run'),
             jsonb_build_object('checked', v_total, 'broken', v_fail))
     where id = p_run_id;
  end if;

  return jsonb_build_object('ok', true, 'checked', v_total, 'broken', v_fail,
                            'gaps', v_gaps, 'phase', coalesce(p_phase,'run'),
                            'worst', v_worst);
end $fn$;

-- ═════════════════════════════════════════════════════════════════════════════
-- THE RUN — one call, three generators, a test session, then a purge.
--
-- SECURITY INVOKER on purpose (see the probe): a definer wrapper here would
-- silently strip the whole run of its ability to impersonate, and every verdict
-- would quietly become a guess.
-- ═════════════════════════════════════════════════════════════════════════════
create or replace function public.autotest_safety_net_run(
  p_label text default null, p_seed bigint default null,
  p_fuzz_rpcs integer default 80, p_variants integer default 2)
returns jsonb
language plpgsql security invoker set search_path to 'public' as $fn$
declare
  v_run bigint; v_seed bigint; v_session bigint; v_sess jsonb;
  v_auth jsonb; v_probe jsonb; v_plan jsonb; v_fuzz jsonb;
  v_inv0 jsonb; v_inv1 jsonb; v_purge jsonb; v_gaps int;
begin
  perform public._dev_guard();
  v_seed := coalesce(p_seed, (extract(epoch from clock_timestamp()) * 1000)::bigint);

  insert into public.autotest_run (kind, label, seed)
  values ('safety_net',
          coalesce(nullif(btrim(p_label),''),
                   to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' safety net'),
          v_seed)
  returning id into v_run;

  -- A test session when test mode allows one. The sandbox already guarantees
  -- nothing survives a case, so a closed test mode postpones nothing.
  begin
    v_sess := public.test_session_start(format('safety net run %s', v_run), 1);
    if coalesce((v_sess->>'ok')::boolean, false) then
      v_session := nullif(v_sess->>'session_id','')::bigint;
      update public.autotest_run set session_id = v_session where id = v_run;
    end if;
  exception when others then v_sess := jsonb_build_object('ok', false, 'error', sqlstate);
  end;

  v_inv0  := public.autotest_invariant_run(v_run, 'baseline');
  v_auth  := public.autotest_auth_matrix_run(v_run, true);
  v_probe := public.autotest_auth_matrix_probe(v_run, null);
  v_plan  := public.autotest_fuzz_plan(v_run, v_seed, p_fuzz_rpcs, p_variants, null);
  v_fuzz  := public.autotest_fuzz_exec(v_run, null);
  v_inv1  := public.autotest_invariant_run(v_run, 'after_fuzz');

  if v_session is not null then
    begin
      v_purge := public.test_purge(false);
      perform public.test_session_end(v_session);
    exception when others then v_purge := jsonb_build_object('ok', false, 'error', sqlstate);
    end;
  end if;

  select gaps_written into v_gaps from public.autotest_run where id = v_run;

  update public.autotest_run
     set finished_at = now(),
         status = case when coalesce((v_auth->>'failed')::bigint,0) > 0
                        or coalesce((v_fuzz->>'failed')::int,0) > 0
                        or coalesce((v_inv1->>'broken')::int,0) > 0
                       then 'findings' else 'clean' end,
         summary = summary || jsonb_build_object(
           'session', coalesce(v_sess,'{}'::jsonb), 'purge', coalesce(v_purge,'{}'::jsonb),
           'plan', coalesce(v_plan,'{}'::jsonb))
   where id = v_run;

  return jsonb_build_object('ok', true, 'run_id', v_run, 'seed', v_seed,
    'auth', v_auth, 'probe', v_probe, 'fuzz', v_fuzz,
    'invariants_baseline', v_inv0, 'invariants_after_fuzz', v_inv1,
    'gaps', v_gaps);
end $fn$;

-- Nightly, on the ONE dispatcher (#273). cron_dispatch is SECURITY INVOKER and
-- runs as postgres, so the probe keeps its role-switching fidelity here.
insert into public.cron_task (name, ord, mode, work_sql, enabled, base_interval_s, note)
values ('c636_safety_net_nightly', 940, 'poll',
        $w$select public.autotest_safety_net_run('nightly safety net', null, 150, 2)$w$,
        true, 86400,
        'CHANGE #636 — auth matrix + property fuzz + invariant oracles, once a night.')
on conflict (name) do update
  set work_sql = excluded.work_sql, note = excluded.note, mode = excluded.mode,
      base_interval_s = excluded.base_interval_s;

-- ─────────────────────────────────────────────────────────────────────────────
-- THE SCREEN'S ONE RPC. Every word below is a string, not a number the client
-- formats: the panel is a printer.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('safety_net.title',        to_jsonb('Safety net'::text)),
  ('safety_net.subtitle',     to_jsonb('Tests the system generates for itself — nobody writes these cases.'::text)),
  ('safety_net.run_label',    to_jsonb('Run the safety net'::text)),
  ('safety_net.running_label',to_jsonb('Running…'::text)),
  ('safety_net.never_label',  to_jsonb('Never run yet'::text)),
  ('safety_net.never_sub',    to_jsonb('Run it once to generate the matrix, the fuzz corpus and the oracle baseline.'::text)),
  ('safety_net.auth_title',   to_jsonb('Auth matrix'::text)),
  ('safety_net.fuzz_title',   to_jsonb('Property fuzzing'::text)),
  ('safety_net.inv_title',    to_jsonb('Invariant oracles'::text)),
  ('safety_net.empty_row',    to_jsonb('Nothing to answer for.'::text)),
  ('safety_net.footnote',     to_jsonb('Every case is a pure function of its seed, so a failure replays byte for byte. Nothing a case does survives it — each call runs in a subtransaction that is always rolled back.'::text))
on conflict (key) do update set value = excluded.value;

create or replace function public.autotest_safety_net_home()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_run public.autotest_run; v_tiles jsonb; v_sections jsonb;
begin
  perform public._dev_guard();
  select * into v_run from public.autotest_run order by id desc limit 1;

  if v_run.id is null then
    return jsonb_build_object(
      'has', true, 'has_run', false,
      'title',    public.uic('safety_net.title','Safety net'),
      'subtitle', public.uic('safety_net.subtitle',''),
      'empty_title', public.uic('safety_net.never_label','Never run yet'),
      'empty_sub',   public.uic('safety_net.never_sub',''),
      'tiles', '[]'::jsonb, 'sections', '[]'::jsonb,
      'run_label', public.uic('safety_net.run_label','Run the safety net'),
      'running_label', public.uic('safety_net.running_label','Running…'),
      'footnote', public.uic('safety_net.footnote',''));
  end if;

  v_tiles := jsonb_build_array(
    jsonb_build_object('key','auth',
      'label', public.uic('safety_net.auth_title','Auth matrix'),
      'value', to_char(v_run.auth_total, 'FM999,999,999') || ' checks',
      'sub',   v_run.auth_failed || ' open',
      'tone',  case when v_run.auth_failed > 0 then 'danger' else 'success' end),
    jsonb_build_object('key','fuzz',
      'label', public.uic('safety_net.fuzz_title','Property fuzzing'),
      'value', v_run.fuzz_total || ' cases',
      'sub',   v_run.fuzz_failed || ' broke',
      'tone',  case when v_run.fuzz_failed > 0 then 'danger' else 'success' end),
    jsonb_build_object('key','invariants',
      'label', public.uic('safety_net.inv_title','Invariant oracles'),
      'value', v_run.inv_total || ' oracles',
      'sub',   v_run.inv_failed || ' broken',
      'tone',  case when v_run.inv_failed > 0 then 'danger' else 'success' end),
    jsonb_build_object('key','gaps',
      'label', 'Findings filed',
      'value', v_run.gaps_written || ' gaps',
      'sub',   'seed ' || v_run.seed,
      'tone',  case when v_run.gaps_written > 0 then 'warning' else 'success' end));

  v_sections := jsonb_build_array(
    jsonb_build_object('key','auth',
      'title', public.uic('safety_net.auth_title','Auth matrix'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'title', k.proname || ' answers ' || k.role_key,
                 'sub',   left(k.evidence, 220),
                 'badge', case k.verdict when 'proven' then 'PROVEN' else upper(k.verdict) end,
                 'tone',  case when k.severity = 'critical' then 'danger'
                               when k.severity = 'high'     then 'warning'
                               else 'info' end) order by (k.severity='critical') desc, k.proname)
          from (select * from public.autotest_auth_check
                 where verdict in ('proven','fail')
                 order by (severity='critical') desc, (verdict='proven') desc, proname
                 limit 25) k), '[]'::jsonb)),
    jsonb_build_object('key','fuzz',
      'title', public.uic('safety_net.fuzz_title','Property fuzzing'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'title', x.proname || ' · ' || coalesce(x.assertion,'-'),
                 'sub',   'as ' || x.role_key || ' · seed ' || x.seed || ' v' || x.variant
                          || ' · ' || x.args_label || ' · ' || coalesce(x.sqlstate,'-')
                          || ' ' || left(coalesce(x.message,''), 140),
                 'badge', upper(x.outcome),
                 'tone',  case when x.severity = 'critical' then 'danger'
                               when x.severity = 'high'     then 'warning' else 'info' end)
                 order by (x.severity='critical') desc, x.proname)
          from (select c.proname, c.role_key, c.seed, c.variant, c.args_label,
                       r.sqlstate, r.message, r.outcome, r.severity, r.assertion
                  from public.autotest_fuzz_result r
                  join public.autotest_fuzz_case c on c.id = r.case_id
                 where r.verdict = 'fail'
                 order by (r.severity='critical') desc, c.proname limit 25) x), '[]'::jsonb)),
    jsonb_build_object('key','invariants',
      'title', public.uic('safety_net.inv_title','Invariant oracles'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'title', i.title,
                 'sub',   r.key || ' · ' || r.violations || ' violation(s) at ' || r.phase
                          || case when coalesce(r.sample,'') = '' then ''
                                  else ' · ' || left(r.sample, 200) end,
                 'badge', upper(r.verdict),
                 'tone',  case when r.verdict = 'pass' then 'success'
                               when i.mode = 'enforce' then 'danger' else 'warning' end)
                 order by (r.verdict <> 'pass') desc, i.sort)
          from public.autotest_invariant_result r
          join public.autotest_invariant i on i.key = r.key
         where r.run_id = v_run.id and r.phase = 'after_fuzz'), '[]'::jsonb)));

  return jsonb_build_object(
    'has', true, 'has_run', true,
    'title',    public.uic('safety_net.title','Safety net'),
    'subtitle', public.uic('safety_net.subtitle',''),
    'run_label',     public.uic('safety_net.run_label','Run the safety net'),
    'running_label', public.uic('safety_net.running_label','Running…'),
    'empty_row',     public.uic('safety_net.empty_row','Nothing to answer for.'),
    'footnote',      public.uic('safety_net.footnote',''),
    'run', jsonb_build_object(
      'label', coalesce(v_run.label,''),
      'when_label', to_char(v_run.started_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH24:MI') || ' IST',
      'status_label', case v_run.status when 'clean' then 'All clear'
                                        when 'findings' then 'Findings filed'
                                        else 'Running' end,
      'status_tone', case v_run.status when 'clean' then 'success'
                                       when 'findings' then 'danger' else 'info' end,
      'seed_label', 'seed ' || v_run.seed),
    'tiles', v_tiles, 'sections', v_sections);
end $fn$;
