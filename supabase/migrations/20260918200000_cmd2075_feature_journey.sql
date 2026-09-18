-- CMD #2075 — FEATURE JOURNEY GATE, the production half.
--
-- The gate itself lives on the control plane (supabase/devqueue/2075_*.sql).
-- Production owns three things the browser journeys need:
--   1. qa_test_identities READY for all 8 roles, so a logged-in journey can be
--      driven as any role. The 4 roles that had no account (company, delivery,
--      mr, worker) get a dedicated test-only account each: qa.<role>@medibo.test,
--      flagged synthetic on its registration row and on the auth user's own
--      metadata, and the admin company list excludes synthetic rows. The
--      PASSWORD is never in this file: the build VM sets it through the GoTrue
--      admin API and keeps it in ~/.medibo/autotest.env (chmod 600), exactly
--      like the four logins that already existed.
--   2. test_journey_sql_assert() — the "expected DB effect asserted by SQL"
--      step, run as service_role against the app schema, read-only, bounded.
--   3. an rg behaviour test that turns rg_check red if the rule leaves
--      build_rules or the runner stops proving the gate is wired.
-- Idempotent: re-running it changes nothing.

begin;

-- ── 1. test-only flags where the role tables had none ───────────────────────
alter table public.company_profiles add column if not exists is_synthetic boolean not null default false;
alter table public.mr_registrations  add column if not exists is_synthetic boolean not null default false;

-- ── 2. the eight roles exist as rows, always ─────────────────────────────────
insert into public.qa_test_identities (role, note) values
  ('super_admin', 'seed a test-only super_admin account, set account_id + ready'),
  ('admin',       'seed a test-only admin account, set account_id + ready'),
  ('supplier',    'seed a test-only supplier account, set account_id + ready'),
  ('customer',    'seed a test-only customer account, set account_id + ready'),
  ('company',     'seed a test-only company account, set account_id + ready'),
  ('delivery',    'seed a test-only delivery account, set account_id + ready'),
  ('mr',          'seed a test-only mr account, set account_id + ready'),
  ('worker',      'seed a test-only worker account, set account_id + ready')
on conflict (role) do nothing;

-- ── 3. who is a test identity (the flag every report can read) ──────────────
create or replace function public.qa_test_identity_ids()
returns setof uuid language sql stable security definer set search_path = public as $fn$
  select t.account_id from public.qa_test_identities t where t.account_id is not null
  union
  select u.id from auth.users u where coalesce((u.raw_user_meta_data->>'test_only')::boolean, false);
$fn$;
revoke all on function public.qa_test_identity_ids() from public, anon;
grant execute on function public.qa_test_identity_ids() to authenticated, service_role;

create or replace function public.is_qa_test_identity(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $fn$
  select p_user is not null and exists (select 1 from public.qa_test_identity_ids() i where i = p_user);
$fn$;
revoke all on function public.is_qa_test_identity(uuid) from public, anon;
grant execute on function public.is_qa_test_identity(uuid) to authenticated, service_role;

-- ── 4. the seeder: one call per role, idempotent, never a password ──────────
create or replace function public.qa_seed_test_identity(p_role text, p_email text, p_phone10 text, p_label text)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid; v_owner text; v_email text := lower(btrim(p_email)); v_id uuid; v_bigid bigint;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role'
     and not (coalesce(current_setting('request.jwt.claims', true), '') = ''
              and session_user in ('postgres', 'supabase_admin')) then
    raise exception 'qa_seed_test_identity: runner only';
  end if;
  if p_role not in ('super_admin','admin','supplier','customer','company','delivery','mr','worker') then
    return jsonb_build_object('ok', false, 'error', 'unknown role ' || coalesce(p_role,'?'));
  end if;

  -- the auth user: created with an UNUSABLE random password; the VM sets the real one
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null then
    v_uid := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values (v_uid, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated', v_email,
            extensions.crypt(gen_random_uuid()::text, extensions.gen_salt('bf')), now(),
            jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
            jsonb_build_object('test_only', true, 'seeded_by', 'cmd2075', 'role', p_role, 'phone', p_phone10),
            now(), now(), '', '', '', '');
  end if;
  update auth.users
     set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
           || jsonb_build_object('test_only', true, 'role', p_role, 'phone', p_phone10),
         email_confirmed_at = coalesce(email_confirmed_at, now())
   where id = v_uid;
  if not exists (select 1 from auth.identities i where i.user_id = v_uid and i.provider = 'email') then
    insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid::text, v_uid,
            jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
            'email', now(), now(), now());
  end if;

  -- the role row, flagged synthetic wherever the table carries the flag
  if p_role = 'delivery' then
    select id::text into v_owner from public.delivery_partner_registrations
     where user_id = v_uid or lower(coalesce(email,'')) = v_email order by submitted_at limit 1;
    if v_owner is null then
      insert into public.delivery_partner_registrations
        (user_id, status, full_name, phone, email, vehicle_type, delivery_zone, address, city, state,
         id_proof_type, partner_type, zone_id, is_active, is_synthetic, submitted_at, reviewed_at)
      values (v_uid, 'approved', p_label, p_phone10, v_email, 'bike', 'Zone tst', 'synthetic — do not use', 'Test', 'TS',
              'none', 'boy', 99, true, true, now(), now())
      returning id::text into v_owner;
    else
      update public.delivery_partner_registrations
         set user_id = v_uid, status = 'approved', is_synthetic = true, is_active = true,
             email = v_email, phone = p_phone10, is_deleted = false
       where id::text = v_owner;
    end if;
  elsif p_role = 'company' then
    select id::text into v_owner from public.company_profiles
     where user_id = v_uid or lower(coalesce(email,'')) = v_email order by submitted_at limit 1;
    if v_owner is null then
      insert into public.company_profiles
        (user_id, status, company_name, contact_person, phone, email, registered_address, city, state,
         is_synthetic, submitted_at, reviewed_at)
      values (v_uid, 'approved', p_label, 'QA bot', p_phone10, v_email, 'synthetic — do not use', 'Test', 'TS',
              true, now(), now())
      returning id::text into v_owner;
    else
      update public.company_profiles
         set user_id = v_uid, status = 'approved', is_synthetic = true, email = v_email, phone = p_phone10, is_deleted = false
       where id::text = v_owner;
    end if;
  elsif p_role = 'mr' then
    select id::text into v_owner from public.mr_registrations
     where user_id = v_uid or lower(coalesce(email,'')) = v_email order by submitted_at limit 1;
    if v_owner is null then
      insert into public.mr_registrations
        (user_id, status, full_name, phone, email, company_represented, territory_zone, city, state,
         is_synthetic, submitted_at, reviewed_at)
      values (v_uid, 'approved', p_label, p_phone10, v_email, 'TST QA Company - SYNTHETIC', 'Zone tst', 'Test', 'TS',
              true, now(), now())
      returning id::text into v_owner;
    else
      update public.mr_registrations
         set user_id = v_uid, status = 'approved', is_synthetic = true, email = v_email, phone = p_phone10, is_deleted = false
       where id::text = v_owner;
    end if;
  elsif p_role = 'worker' then
    select id::text into v_owner from public.lead_workers where user_id = v_uid limit 1;
    if v_owner is null then
      insert into public.lead_workers (user_id, name, phone, active)
      values (v_uid, p_label, p_phone10, true)
      returning id::text into v_owner;
    else
      update public.lead_workers set name = p_label, phone = p_phone10, active = true where id::text = v_owner;
    end if;
  else
    -- admin / super_admin / supplier / customer: the published test logins already
    -- carry their role rows; only the ledger row below is touched.
    v_owner := null;
  end if;

  -- login identities, so get_my_role() resolves the role and a
  -- login_identities_rebuild() (which re-derives from the role rows) keeps them
  if v_owner is not null then
    insert into public.login_identities (identity, kind, owner_type, owner_id)
    select public.identity_norm(v_email), 'email', p_role, v_owner
     where not exists (select 1 from public.login_identities li where li.identity = public.identity_norm(v_email));
    if p_phone10 is not null then
      insert into public.login_identities (identity, kind, owner_type, owner_id)
      select public.identity_norm(p_phone10), 'phone', p_role, v_owner
       where not exists (select 1 from public.login_identities li where li.identity = public.identity_norm(p_phone10));
    end if;
  end if;

  update public.qa_test_identities
     set identity = v_email, account_id = v_uid, ready = true,
         note = 'test-only account (synthetic, excluded from reports) — password lives in ~/.medibo/autotest.env on the build VM'
   where role = p_role;

  return jsonb_build_object('ok', true, 'role', p_role, 'identity', v_email, 'account_id', v_uid, 'owner_id', v_owner);
end $fn$;
revoke all on function public.qa_seed_test_identity(text, text, text, text) from public, anon, authenticated;
grant execute on function public.qa_seed_test_identity(text, text, text, text) to service_role;

-- the four roles that had no account
select public.qa_seed_test_identity('company',  'qa.company@medibo.test',  '9000020751', 'TST QA COMPANY - SYNTHETIC (DO NOT USE)');
select public.qa_seed_test_identity('delivery', 'qa.delivery@medibo.test', '9000020752', 'TST QA RIDER - SYNTHETIC (DO NOT USE)');
select public.qa_seed_test_identity('mr',       'qa.mr@medibo.test',       '9000020753', 'TST QA MR - SYNTHETIC (DO NOT USE)');
select public.qa_seed_test_identity('worker',   'qa.worker@medibo.test',   '9000020754', 'TST QA WORKER - SYNTHETIC (DO NOT USE)');

-- the four that existed: bind the account id and flag the auth user test-only
update public.qa_test_identities t
   set account_id = u.id, ready = true
  from auth.users u
 where lower(u.email) = lower(coalesce(t.identity, ''))
   and t.role in ('super_admin', 'admin', 'supplier', 'customer');
update auth.users u
   set raw_user_meta_data = coalesce(u.raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('test_only', true)
 where u.id in (select account_id from public.qa_test_identities where account_id is not null)
   and coalesce((u.raw_user_meta_data->>'test_only')::boolean, false) = false;

-- ── 5. reports: the company list never shows a synthetic company ────────────
create or replace function public.admin_list_companies(p_search text DEFAULT ''::text)
 RETURNS TABLE(id uuid, company_name text, email text, city text)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  IF get_my_role() <> 'super_admin' THEN RETURN; END IF;
  RETURN QUERY
  SELECT cp.id, cp.company_name, cp.email, cp.city
  FROM company_profiles cp
  WHERE (cp.is_deleted IS NULL OR cp.is_deleted = false)
    AND NOT coalesce(cp.is_synthetic, false)          -- CMD #2075: test-only rows never report
    AND (p_search = ''
         OR cp.company_name ILIKE '%' || p_search || '%'
         OR cp.email ILIKE '%' || p_search || '%')
  ORDER BY cp.company_name LIMIT 100;
END;$function$;

-- ── 6. the SQL-assert step, on the app schema ────────────────────────────────
-- One read-only SELECT returning a boolean, run as the service role with a 5 s
-- cap; {run} and {session} are the current test run / test session so an
-- assertion can scope itself to what the journey just wrote. Never a write.
create or replace function public.test_journey_sql_assert(p_sql text, p_run_id bigint default null, p_session_id bigint default null)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_sql text; v_ok boolean; v_err text; v_sid bigint := p_session_id;
begin
  perform public._dev_guard();
  v_sql := coalesce(btrim(p_sql), '');
  if v_sql !~* '^\s*select\M' or position(';' in v_sql) > 0
     or v_sql ~* '\m(insert|update|delete|drop|alter|create|grant|revoke|truncate|copy|pg_sleep|set_config)\M' then
    return jsonb_build_object('ok', false, 'value', null, 'error', 'assert_sql may only be one read-only SELECT');
  end if;
  if v_sid is null and p_run_id is not null then
    select test_session_id into v_sid from public.test_runs where id = p_run_id;
  end if;
  v_sql := replace(replace(v_sql, '{run}', coalesce(p_run_id::text, 'null')),
                   '{session}', coalesce(v_sid::text, 'null'));
  begin
    perform set_config('statement_timeout', '5000', true);
    execute 'select coalesce((' || v_sql || ')::boolean, false)' into v_ok;
  exception when others then
    v_err := sqlerrm;
  end;
  if v_err is not null then return jsonb_build_object('ok', false, 'value', null, 'error', left(v_err, 300)); end if;
  return jsonb_build_object('ok', coalesce(v_ok, false), 'value', v_ok, 'error', null, 'session_id', v_sid);
end $fn$;
revoke all on function public.test_journey_sql_assert(text, bigint, bigint) from public, anon, authenticated;
grant execute on function public.test_journey_sql_assert(text, bigint, bigint) to service_role;

-- ── 7. rg: the rule cannot quietly disappear, and the gate must be proven wired ─
insert into rg_behavior_tests (name, enabled, note, body) values (
 'feature_journey_rule_present', true,
 'CMD #2075 — every screen-changing command ships its own browser journey and cannot complete until it is green on medibo.in: build_rules.feature_journey must exist with its rule text, gate name and both phone widths, all 8 qa_test_identities must be ready, and the runner must keep proving the gate is wired (verdict feature_journey_gate, written by scripts/feature_journey_check.sh after every deploy).',
 $t$do $b$
declare v jsonb; v_verdict jsonb; v_max_age int; v_ready int;
begin
  -- production has no dev_runner_config; the rule text is checked on the control
  -- plane by the runner and reported through the verdict below.
  if to_regclass('public.dev_runner_config') is not null then
    select value->'feature_journey' into v from dev_runner_config where key='build_rules';
    if v is not null then
      if coalesce(v->>'rule','') = '' then
        raise exception 'RG_FAIL: build_rules.feature_journey has no rule text (CMD #2075)';
      end if;
      if coalesce(v->>'gate','') <> 'c_feature_journey' then
        raise exception 'RG_FAIL: build_rules.feature_journey.gate is %, expected c_feature_journey', coalesce(v->>'gate','(null)');
      end if;
      if not (v->'widths' @> '360'::jsonb and v->'widths' @> '412'::jsonb) then
        raise exception 'RG_FAIL: build_rules.feature_journey.widths must contain 360 and 412';
      end if;
    end if;
  end if;
  select count(*) into v_ready from public.qa_test_identities where ready and coalesce(identity,'') <> '';
  if v_ready < 8 then
    raise exception 'RG_FAIL: only % of 8 qa_test_identities are ready — logged-in feature journeys cannot run for every role (CMD #2075)', v_ready;
  end if;
  select to_jsonb(r) into v_verdict from rg_runner_verdict r where r.name='feature_journey_gate';
  v_max_age := 72;
  if to_regclass('public.dev_runner_config') is not null then
    select coalesce((value->'mobile_first'->>'verdict_max_age_h')::int, 72)
      into v_max_age from dev_runner_config where key='worker_pool';
  end if;
  if v_verdict is not null then
    if not coalesce((v_verdict->>'ok')::boolean,false) then
      raise exception 'RG_FAIL: the feature-journey gate is no longer wired — %', coalesce(v_verdict->>'detail','(no detail)');
    end if;
    if (v_verdict->>'at')::timestamptz < now() - make_interval(hours => coalesce(v_max_age,72)) then
      raise exception 'RG_FAIL: the feature_journey_gate verdict is stale (last written %) — scripts/feature_journey_check.sh has not run since', (v_verdict->>'at');
    end if;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;$t$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

commit;
