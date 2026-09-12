-- CHANGE #1761 — medibo-dev (brorshtqrkyqqdhmhclw): the dev-queue control plane's own project.
-- Applied ON medibo-dev after the filtered pg_restore of the control-plane schema + rows.
-- Idempotent: every statement is CREATE OR REPLACE / IF NOT EXISTS / upsert.
--
-- What lives here and why (see dev_commands #1761 decisions):
--   * console-token auth: the app's Dev Queue screen calls medibo-dev with the anon key and an
--     x-dev-console header minted by production's dev_console_token() (HMAC, shared vault secret).
--   * stubs for production-only helpers the moved RPCs call (get_my_role, admin_active_zone/date).
--   * forwarders: wa_send_event / notify / ui_design_set / ui_copy edits go BACK to production
--     over pg_net, because the app and Om's phone read those on production.
--   * journeys split: the registry + runs live here, the _journey_* probes stay on production;
--     devcmd.sh journeys_run plans here, probes there, records here.
--   * proof ledger: storage stays on production, so the finish gate counts proofs from a ledger
--     that upload_proof.sh writes.
--   * cron: this project's own dispatcher runs only the dev/runner tasks.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Console token
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._dev_console_email()
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  h jsonb; t text; v_exp bigint; v_email text; v_sig text; v_secret text; v_calc text;
begin
  begin
    h := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  exception when others then
    return null;
  end;
  t := h->>'x-dev-console';
  if t is null or split_part(t, '.', 1) <> 'v1' then return null; end if;
  v_exp := nullif(split_part(t, '.', 2), '')::bigint;
  if v_exp is null or v_exp < extract(epoch from now())::bigint then return null; end if;
  v_email := convert_from(decode(split_part(t, '.', 3), 'base64'), 'utf8');
  v_sig   := split_part(t, '.', 4);
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'DEV_CONSOLE_SECRET';
  if v_secret is null then return null; end if;
  v_calc := encode(extensions.hmac(convert_to(v_email || '|' || v_exp, 'utf8'),
                                   convert_to(v_secret, 'utf8'), 'sha256'), 'hex');
  if v_calc <> v_sig then return null; end if;
  return v_email;
exception when others then
  return null;
end $$;
revoke execute on function public._dev_console_email() from public, anon, authenticated;

-- Give the rest of the request a real identity so auth.uid()/auth.jwt() attribute correctly.
create or replace function public._dev_console_claims(p_email text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if p_email is null then return; end if;
  perform set_config('request.jwt.claims',
    jsonb_build_object('role', 'authenticated', 'email', p_email,
                       'sub', md5('dev-console:' || p_email)::uuid::text,
                       'dev_console', true)::text, true);
end $$;
revoke execute on function public._dev_console_claims(text) from public, anon, authenticated;

create or replace function public.dev_console_verify()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_email text;
begin
  v_email := public._dev_console_email();
  if v_email is null then
    return jsonb_build_object('ok', false, 'reason', 'no valid x-dev-console token');
  end if;
  return jsonb_build_object('ok', true, 'email', v_email, 'project', 'medibo-dev');
end $$;
grant execute on function public.dev_console_verify() to anon, authenticated, service_role;

create or replace function public._dev_guard()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_email text;
begin
  -- the local scheduler (pg_cron) carries no request context
  if coalesce(current_setting('request.jwt.claims', true), '') = ''
     and coalesce(current_setting('request.jwt.claim',  true), '') = ''
     and session_user in ('postgres', 'supabase_admin')
  then
    return;
  end if;
  if coalesce(auth.jwt()->>'role', '') = 'service_role' then return; end if;
  if coalesce(auth.jwt()->>'dev_console', '') = 'true' then return; end if;
  v_email := public._dev_console_email();
  if v_email is not null then
    perform public._dev_console_claims(v_email);
    return;
  end if;
  raise exception 'dev_queue: not authorized';
end $$;

create or replace function public.get_my_role()
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_email text;
begin
  if coalesce(auth.jwt()->>'role', '') = 'service_role' then return 'super_admin'; end if;
  if coalesce(auth.jwt()->>'dev_console', '') = 'true' then return 'super_admin'; end if;
  if coalesce(current_setting('request.jwt.claims', true), '') = ''
     and session_user in ('postgres', 'supabase_admin') then
    return 'super_admin';
  end if;
  v_email := public._dev_console_email();
  if v_email is not null then
    perform public._dev_console_claims(v_email);
    return 'super_admin';
  end if;
  return 'none';
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Stubs for production-only helpers (no zone/date scoping in the control plane)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_active_zone()
returns smallint
language sql
stable
security definer
set search_path to 'public'
as $$ select null::smallint $$;

create or replace function public.admin_active_date()
returns date
language sql
stable
security definer
set search_path to 'public'
as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Forwarders back to production (fire-and-forget over pg_net)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._prod_rpc(p_fn text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_url text; v_key text; v_id bigint;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'PROD_SUPABASE_URL';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'PROD_SERVICE_ROLE_KEY';
  if v_url is null or v_key is null then return null; end if;
  select net.http_post(
    url := v_url || '/rest/v1/rpc/' || p_fn,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', v_key, 'Authorization', 'Bearer ' || v_key),
    body := coalesce(p_body, '{}'::jsonb),
    timeout_milliseconds := 8000) into v_id;
  return v_id;
exception when others then
  return null;
end $$;
revoke execute on function public._prod_rpc(text, jsonb) from public, anon, authenticated;

create or replace function public.wa_send_event(p_event_key text, p_customer_id uuid default null,
                                                p_tokens jsonb default '{}'::jsonb,
                                                p_phone text default null, p_order_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_id bigint;
begin
  v_id := public._prod_rpc('wa_send_event', jsonb_build_object(
            'p_event_key', p_event_key, 'p_customer_id', p_customer_id,
            'p_tokens', coalesce(p_tokens, '{}'::jsonb), 'p_phone', p_phone, 'p_order_id', p_order_id));
  return jsonb_build_object('ok', v_id is not null, 'forwarded', true, 'request_id', v_id);
end $$;
revoke execute on function public.wa_send_event(text, uuid, jsonb, text, uuid) from public, anon, authenticated;

create or replace function public.notify(p_event_key text, p_recipient text default null,
                                         p_vars jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_id bigint;
begin
  v_id := public._prod_rpc('notify', jsonb_build_object(
            'p_event_key', p_event_key, 'p_recipient', p_recipient, 'p_vars', coalesce(p_vars, '{}'::jsonb)));
  return jsonb_build_object('ok', v_id is not null, 'forwarded', true, 'request_id', v_id);
end $$;
revoke execute on function public.notify(text, text, jsonb) from public, anon, authenticated;

-- Design tokens are read by ui_boot() on PRODUCTION: apply locally (so the dev copy tracks) and forward.
create or replace function public.ui_design_set(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v jsonb; k text; v_id bigint;
begin
  perform _dev_guard();
  select value into v from dev_runner_config where key = 'ui_design';
  v := coalesce(v, '{}'::jsonb);
  for k in select jsonb_object_keys(p_patch) loop
    if jsonb_typeof(v->k) = 'object' and jsonb_typeof(p_patch->k) = 'object' then
      v := jsonb_set(v, array[k], (v->k) || (p_patch->k));
    else
      v := jsonb_set(v, array[k], p_patch->k);
    end if;
  end loop;
  v := jsonb_set(v, '{version}', to_jsonb(coalesce((v->>'version')::int, 1) + 1));
  insert into dev_runner_config(key, value) values ('ui_design', v)
    on conflict (key) do update set value = excluded.value;
  v_id := public._prod_rpc('ui_design_set', jsonb_build_object('p_patch', p_patch));
  perform _audit(_actor(), 'ui_design_set', null, p_patch || jsonb_build_object('forwarded_request', v_id));
  return jsonb_build_object('ok', true, 'version', v->>'version', 'forwarded', v_id is not null);
end $$;

-- ui_copy edits made here (fast lane, dev tooling) must reach the app: mirror each row to production.
create or replace function public._ui_copy_forward_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_url text; v_key text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'PROD_SUPABASE_URL';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'PROD_SERVICE_ROLE_KEY';
  if v_url is null or v_key is null then return new; end if;
  perform net.http_post(
    url := v_url || '/rest/v1/ui_copy?on_conflict=key',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key,
                                  'Authorization', 'Bearer ' || v_key,
                                  'Prefer', 'resolution=merge-duplicates,return=minimal'),
    body := jsonb_build_array(jsonb_build_object('key', new.key, 'value', new.value)),
    timeout_milliseconds := 8000);
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists ui_copy_forward_to_prod on public.ui_copy;
create trigger ui_copy_forward_to_prod
  after insert or update of value on public.ui_copy
  for each row execute function public._ui_copy_forward_trg();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Journeys split: plan here → probe on production → record here
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.dev_journey_probe(p_name text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object('status', 'skipped',
    'evidence', jsonb_build_object('reason',
      'journey probes run on production (_journey_* read app tables); use devcmd.sh journeys_run',
      'journey', p_name))
$$;

create or replace function public.dev_journeys_run(p_command_id bigint, p_area text,
                                                   p_after_id bigint default null, p_limit integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  raise exception 'dev_journeys_run moved: call dev_journeys_plan + dev_journey_probe (production) + dev_journeys_record — devcmd.sh journeys_run does this';
end $$;

create or replace function public.dev_journeys_plan(p_command_id bigint, p_area text,
                                                    p_after_id bigint default null, p_limit integer default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j record; v_cfg jsonb; v_limit int; v_reuse_min int; v_commit text; v_files text[]; v_prev timestamptz;
  v_cursor bigint := coalesce(p_after_id, 0); v_last bigint := coalesce(p_after_id, 0);
  v_scanned int := 0; reused int := 0; v_more boolean;
  runs jsonb := '[]'; probe jsonb := '[]';
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'dev_journeys_plan: runner only';
  end if;
  select coalesce(value->'journeys', '{}'::jsonb) into v_cfg from dev_runner_config where key = 'worker_pool';
  v_cfg := coalesce(v_cfg, '{}'::jsonb);
  v_limit := greatest(1, least(coalesce(p_limit, nullif(v_cfg->>'max_per_run', '')::int, 8), 40));
  select coalesce((value->'qa'->>'journey_reuse_min')::int, 60) into v_reuse_min
    from dev_runner_config where key = 'worker_pool';
  v_reuse_min := greatest(coalesce(v_reuse_min, 60), 0);
  select nullif(btrim(coalesce(resume_commit, '')), '') into v_commit from dev_commands where id = p_command_id;
  v_files := coalesce(public.dev_cmd_footprint(p_command_id), '{}');

  for j in
    select dj.id, dj.name, dj.required, dj.files
      from dev_journeys dj
     where dj.enabled
       and (dj.area is null or dj.area = p_area)
       and dj.id > v_cursor
       and (dj.area is null or dj.files is null
            or coalesce(array_length(dj.files, 1), 0) = 0
            or coalesce(array_length(public.dev_paths_conflict(dj.files, v_files), 1), 0) > 0)
     order by dj.id
     limit v_limit
  loop
    v_scanned := v_scanned + 1; v_last := j.id; v_prev := null;
    if v_commit is not null and v_reuse_min > 0 then
      select r.at into v_prev from dev_journey_runs r
       where r.journey_id = j.id and r.status = 'passed' and r.commit_sha = v_commit
         and r.at > now() - make_interval(mins => v_reuse_min)
       order by r.at desc limit 1;
    end if;
    if v_prev is not null then
      reused := reused + 1;
      insert into dev_journey_runs(command_id, journey_id, status, evidence, duration_ms, commit_sha)
      values (p_command_id, j.id, 'passed',
              jsonb_build_object('reused', true, 'reused_from', v_prev, 'commit', v_commit, 'window_min', v_reuse_min),
              0, v_commit);
      runs := runs || jsonb_build_object('journey', j.name, 'status', 'passed', 'reused', true,
                'evidence', jsonb_build_object('reused_from', v_prev), 'duration_ms', 0);
      continue;
    end if;
    probe := probe || jsonb_build_object('journey_id', j.id, 'name', j.name, 'required', j.required);
  end loop;

  if reused > 0 then
    update dev_commands set journey_pass_count = journey_pass_count + reused where id = p_command_id;
  end if;
  select exists (select 1 from dev_journeys where enabled and (area is null or area = p_area) and id > v_last)
    into v_more;
  return jsonb_build_object('ok', true, 'area', p_area, 'commit', coalesce(v_commit, ''),
    'to_probe', probe, 'reused', reused, 'reused_runs', runs, 'reuse_window_min', v_reuse_min,
    'scanned', v_scanned, 'row_ceiling', v_limit,
    'has_more', coalesce(v_more, false), 'next_after_id', v_last);
end $$;
revoke execute on function public.dev_journeys_plan(bigint, text, bigint, integer) from public, anon, authenticated;

create or replace function public.dev_journeys_record(p_command_id bigint, p_area text, p_results jsonb,
                                                      p_commit text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  r jsonb; st text; v_ev jsonb; v_ms int; v_jid bigint; v_req boolean;
  passed int := 0; failed int := 0; skipped int := 0;
  v_passed_ids bigint[] := '{}'; promoted text[] := '{}'; runs jsonb := '[]'; v_commit text;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'dev_journeys_record: runner only';
  end if;
  v_commit := nullif(btrim(coalesce(p_commit, '')), '');
  if v_commit is null then
    select nullif(btrim(coalesce(resume_commit, '')), '') into v_commit from dev_commands where id = p_command_id;
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    v_jid := (r->>'journey_id')::bigint;
    if v_jid is null then continue; end if;
    select required into v_req from dev_journeys where id = v_jid;
    st := coalesce(r->>'status', 'skipped');
    if st not in ('passed', 'failed', 'skipped') then st := 'skipped'; end if;
    v_ms := coalesce((r->>'duration_ms')::int, 0);
    insert into dev_journey_runs(command_id, journey_id, status, evidence, duration_ms, commit_sha)
    values (p_command_id, v_jid, st, coalesce(r->'evidence', '{}'::jsonb), v_ms, v_commit)
    returning status, evidence into st, v_ev;
    if st = 'passed' then
      passed := passed + 1;
      if not coalesce(v_req, false) then v_passed_ids := v_passed_ids || v_jid; end if;
    elsif st = 'failed' then failed := failed + 1;
    else skipped := skipped + 1;
    end if;
    runs := runs || jsonb_build_object('journey', r->>'name', 'status', st, 'evidence', v_ev, 'duration_ms', v_ms);
  end loop;

  if array_length(v_passed_ids, 1) > 0 then
    with promo as (
      update dev_journeys dj set required = true
       where dj.id = any(v_passed_ids) and not dj.required
         and (select count(*) from (
                select 1 from dev_journey_runs r
                 where r.journey_id = dj.id and r.status = 'passed'
                   and coalesce(r.evidence->>'reused', '') <> 'true'
                 limit 2) z) >= 2
      returning dj.name)
    select coalesce(array_agg(name), '{}'::text[]) into promoted from promo;
  end if;
  if passed > 0 then
    update dev_commands set journey_pass_count = journey_pass_count + passed where id = p_command_id;
  end if;
  return jsonb_build_object('ok', true, 'area', p_area, 'passed', passed, 'failed', failed,
    'skipped', skipped, 'promoted_to_required', promoted, 'runs', runs, 'commit', coalesce(v_commit, ''));
end $$;
revoke execute on function public.dev_journeys_record(bigint, text, jsonb, text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Proof ledger (screenshots stay in production storage)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.dev_proof_ledger (
  name        text primary key,
  command_id  bigint,
  at          timestamptz not null default now()
);
create index if not exists dev_proof_ledger_cmd_idx on public.dev_proof_ledger(command_id);
alter table public.dev_proof_ledger enable row level security;

create or replace function public.dev_proof_note(p_name text, p_command_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_cmd bigint;
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'dev_proof_note: runner only';
  end if;
  v_cmd := coalesce(p_command_id,
             nullif((regexp_match(p_name, '^(?:cmd[-_]?)?(\d+)/'))[1], '')::bigint);
  insert into dev_proof_ledger(name, command_id) values (p_name, v_cmd)
    on conflict (name) do update set command_id = coalesce(excluded.command_id, dev_proof_ledger.command_id), at = now();
  return jsonb_build_object('ok', true, 'name', p_name, 'command_id', v_cmd);
end $$;
revoke execute on function public.dev_proof_note(text, bigint) from public, anon, authenticated;

create or replace function public._dev_finish_proofs(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(name order by name), '[]'::jsonb)
    from (select l.name from dev_proof_ledger l
           where l.command_id = p_id
              or l.name ~ ('^(cmd[-_]?)?' || p_id::text || '/')
           limit 12) s
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Regression-guard verdict mirror: devcmd.sh rgcheck copies production's latest
--    rg_check_cache row here so dev_cmd_complete's gate keeps reading the same shape.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.rg_check_mirror(p_ok boolean, p_result jsonb, p_at timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(auth.jwt()->>'role', '') <> 'service_role' then
    raise exception 'rg_check_mirror: runner only';
  end if;
  insert into rg_check_cache(ok, result, at) values (p_ok, coalesce(p_result, '{}'::jsonb), coalesce(p_at, now()));
  delete from rg_check_cache where at < now() - interval '30 days';
  return jsonb_build_object('ok', true, 'mirrored', p_ok, 'at', coalesce(p_at, now()));
end $$;
revoke execute on function public.rg_check_mirror(boolean, jsonb, timestamptz) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Cron: only the dev/runner tasks run here; production keeps the app tasks.
-- ─────────────────────────────────────────────────────────────────────────────
delete from public.cron_task
 where name not in (
  'autochain_sweep','chain_watchdog','dev-chain-idle-watchdog','deploy_lane_sweep',
  'dev_auto_heal','dev_auto_resolve','dev_cmd_wait_sweep','dev-agent-liveness',
  'dev-cmd-autofinish','dev-cmd-daily-digest','dev-cmd-watchdog','dev-cmd-weekly-changelog',
  'dev-runner-liveness','gcp-disk-check','gcp-schedule-scan','gcp-uptime-check','lease-sweep',
  'mutation-audit-weekly','play-reap-stale','runner_health_probe','runner_ops_tick',
  'sec-daily-checks','version_watch_5min','vm_snapshot_weekly','cron_history_purge');
update public.cron_task set last_error = null, fail_count = 0, parked_reason = null, parked_at = null
 where parked_reason is not null or fail_count > 0;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'cron-dispatch') then
    perform cron.schedule('cron-dispatch', '* * * * *',
      $job$set statement_timeout = '120s'; select public.cron_run('cron-dispatch', 'select public.cron_dispatch()')$job$);
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Grants: the app reaches this project with the anon key + console token.
--    Only the RPCs the Dev Queue screens call are opened to anon; every one of them
--    runs _dev_guard() (or is a read that guards itself) as SECURITY DEFINER.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = any (array['bug_report','conversation_search','dev_areas_get','dev_cmd_approve','dev_cmd_bulk_add','dev_cmd_cancel','dev_cmd_delete','dev_cmd_delete_cancelled','dev_cmd_finish_state','dev_cmd_get','dev_cmd_list','dev_cmd_pause','dev_cmd_qa_detail','dev_cmd_reject','dev_cmd_reorder','dev_cmd_reply','dev_cmd_request_android','dev_cmd_request_debug','dev_cmd_resume','dev_cmd_rollback','dev_cmd_session_usage','dev_cmd_spec','dev_cmd_template_list','dev_cmd_template_save','dev_cmd_update','dev_console_verify','dev_ctl_get','dev_ctl_set','dev_gcp_action','dev_gcp_get','dev_rates_get','dev_request_usage_refresh','draft_cancel','draft_create','draft_get','draft_submit','drafts_inbox','gcp_schedule_delete','gcp_schedule_save','journeys_get','lease_list','memory_delete','memory_list','memory_put','pool_get','pool_set','qa_waive','sec_audit_list','sec_budget_cap_set','sec_freeze','sec_pin_set','sec_unfreeze','secret_list','secret_set','thread_list','thread_mark_resume','thread_open'])
  loop
    execute format('grant execute on function %s to anon, authenticated, service_role', r.sig);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Bookkeeping: which project this is, so a runner or a human can tell at a glance.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.dev_runner_config(key, value)
values ('project_identity', jsonb_build_object('project', 'medibo-dev', 'ref', 'brorshtqrkyqqdhmhclw',
        'role', 'dev-queue control plane', 'production_ref', 'swojhmarmaijkshsbeih',
        'since', now()::text, 'change', 1761))
on conflict (key) do update set value = excluded.value;
