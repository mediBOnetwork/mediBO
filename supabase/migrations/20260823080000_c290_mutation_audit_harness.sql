-- CHANGE #290 — Weekly mutation audit: a REAL harness.
--
-- Why this exists
-- ---------------
-- `mutation_audit.sh` used to "audit" the journey suite by declaring most
-- journeys a "safe-skip" and then reporting caught=true for them anyway
-- (mutation_audits rows 10 and 11 are exactly that). An audit that reports a
-- pass for a test it never ran is worse than no audit: it certifies the suite
-- has teeth while proving nothing. This migration replaces the theatre with a
-- harness that actually breaks the target and actually reads the verdict.
--
-- Three pieces:
--   _mut_src(fn, pattern, repl)  — mutate a function's SOURCE, and RAISE if the
--                                  pattern matched nothing (a mutation that
--                                  silently no-ops would fake an "escaped").
--   _mutation_recipe(journey)    — the per-journey break, hardcoded. Callers
--                                  cannot pass SQL in; there is no arbitrary-SQL
--                                  door in this file.
--   mutation_trial(journey)      — baseline probe -> apply the break -> probe
--                                  again -> ROLL THE WHOLE THING BACK.
--
-- The revert is not a compensating UPDATE that could itself fail: the break and
-- the probe run inside a plpgsql exception block (a real subtransaction) and the
-- block is always exited by RAISE, so Postgres rolls the mutation back for us.
-- Nothing can leave residue, including a probe that dies half way. plpgsql
-- variables are not transactional, so the verdict still escapes the rollback.
--
-- Hardening shipped with it: dev_journey_probe was EXECUTE-able by PUBLIC/anon
-- and is SECURITY DEFINER with no guard, while two of its branches (bug-191,
-- bug-197) do DDL, rewrite rg_payload_targets and run rg_check + rg_baseline_all.
-- An anonymous caller could therefore make the database do that, repeatedly.
-- Both journey entry points are now guarded and revoked.

-- ── 1. source mutation helper ────────────────────────────────────────────────
create or replace function public._mut_src(p_fn regprocedure, p_pattern text, p_repl text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef(p_fn);
  v_new := regexp_replace(v_def, p_pattern, p_repl, 'g');
  if v_new = v_def then
    -- A mutation that changed nothing would make the journey look robust when
    -- it was never actually challenged. Fail loudly instead.
    raise exception '_mut_src: pattern % matched nothing in %', p_pattern, p_fn;
  end if;
  execute v_new;
end $$;
revoke execute on function public._mut_src(regprocedure, text, text) from public, anon, authenticated;

-- ── 2. probe entry points: guarded, and not reachable by anon ────────────────
revoke execute on function public.dev_journey_probe(text) from public, anon, authenticated;
revoke execute on function public.dev_journeys_run(bigint, text) from public, anon, authenticated;

do $guard$
begin
  -- idempotent: inject the guard only once, and RAISE if the anchor moved
  -- (a silent no-op here would leave the anon door open while looking applied).
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='dev_journey_probe'
                    and p.prosrc like '%_dev_guard()%') then
    perform public._mut_src(
      'public.dev_journey_probe(text)'::regprocedure,
      'c_target constant text := ''my_orders_chandra_slice'';\s*\nbegin\n',
      E'c_target constant text := ''my_orders_chandra_slice'';\nbegin\n  perform public._dev_guard();\n');
  end if;
end $guard$;

-- ── 3. the recipe book ───────────────────────────────────────────────────────
-- Returns {mutation, sql, kind}. kind='dml' means "must affect >0 rows or the
-- trial is void"; kind='ddl' means the statement raises by itself if it no-ops.
create or replace function public._mutation_recipe(p_journey text)
returns jsonb
language sql
immutable
as $$
select case p_journey

  when 'android-apk-produces-file' then jsonb_build_object(
    'kind','dml','mutation','blank android_artifact_url on every built row',
    'sql', $q$update dev_commands set android_artifact_url='' where android_status='built'$q$)

  when 'add-media-survives' then jsonb_build_object(
    'kind','dml','mutation','blank every image path on the newest media-carrying message',
    'sql', $q$update dev_command_messages set images='[""]'::jsonb where id =
              (select id from dev_command_messages
                where jsonb_array_length(coalesce(images,'[]'::jsonb)) > 0
                order by id desc limit 1)$q$)

  when 'reply-media-live' then jsonb_build_object(
    'kind','dml','mutation','blank every image path on the newest Om reply that carried photos',
    'sql', $q$update dev_command_messages set images='[""]'::jsonb where id =
              (select id from dev_command_messages
                where coalesce(sender,'')='om'
                  and jsonb_array_length(coalesce(images,'[]'::jsonb)) > 0
                order by id desc limit 1)$q$)

  when 'devqueue-buttons-change-db' then jsonb_build_object(
    'kind','ddl','mutation','make the Pause button a no-op (dev_cmd_pause stops writing status=paused)',
    'sql', $q$select public._mut_src('public.dev_cmd_pause(bigint)'::regprocedure,
                                     'status=''paused''', 'status=''pending''')$q$)

  when 'menu-reachability' then jsonb_build_object(
    'kind','dml','mutation','delete every externally-reported pass (the browser runner''s proof)',
    'sql', $q$delete from dev_journey_runs
               where journey_id = (select id from dev_journeys where name='menu-reachability')
                 and status='passed' and not (evidence ? 'db_proof')$q$)

  when 'fast-lane-writes' then jsonb_build_object(
    'kind','dml','mutation','overwrite ui_copy journey.test with a wrong value',
    'sql', $q$update ui_copy set value='MUTATED_NOT_OK' where key='journey.test'$q$)

  when 'gcp-taps-enqueue' then jsonb_build_object(
    'kind','dml','mutation','reclassify every gcp command row as kind=dev',
    'sql', $q$update dev_commands set kind='dev' where kind='gcp'$q$)

  when 'pool-settings-save' then jsonb_build_object(
    'kind','dml','mutation','delete the worker_pool config row',
    'sql', $q$delete from dev_runner_config where key='worker_pool'$q$)

  when 'worker-grid-loads' then jsonb_build_object(
    'kind','dml','mutation','empty the worker grid snapshot (workers=[], no lane labels)',
    'sql', $q$update dev_runner_config
                 set value = jsonb_set(jsonb_set(value,'{workers}','[]'::jsonb),
                                       '{active_workers}','0'::jsonb)
               where key='pool_state'$q$)

  when 'rollback-creates-command' then jsonb_build_object(
    'kind','dml','mutation','clear the urgent flag on every Rollback command',
    'sql', $q$update dev_commands set urgent=false where title like 'Rollback #%'$q$)

  when 'eta-honest' then jsonb_build_object(
    'kind','dml','mutation','inflate a building row to eta_left_s > eta_total_s with no eta_note',
    'sql', $q$update dev_commands set eta_left_s=99999, eta_total_s=10, eta_note=''
               where status='building'$q$)

  when 'backup-lands' then jsonb_build_object(
    'kind','dml','mutation','mark every backup in the last 26h as failed',
    'sql', $q$update backup_log set ok=false where at > now() - interval '26 hours'$q$)

  when 'bug-191' then jsonb_build_object(
    'kind','ddl','mutation','strip the statement_timeout off rg_collect_payloads',
    'sql', $q$alter function public.rg_collect_payloads() reset statement_timeout$q$)

  when 'bug-192' then jsonb_build_object(
    'kind','dml','mutation','make a clean render_verify run report a non-zero exit code',
    'sql', $q$update verify_run_log set exit_code=1
               where at > now() - interval '7 days' and keys_ok and build_match
                 and coalesce(array_length(phases_failed,1),0)=0$q$)

  when 'bug-197' then jsonb_build_object(
    'kind','ddl','mutation','delete the unconfirmable-drift rule from rg_check''s source',
    'sql', $q$select public._mut_src('public.rg_check(boolean,boolean)'::regprocedure,
                                     'confirm re-read failed', 'confirm re-read ok')$q$)

  when 'bug-240' then jsonb_build_object(
    'kind','ddl','mutation','disable the inquiry->PO date guard trigger',
    'sql', $q$alter table public.inquiry disable trigger trg_inquiry_po_date_guard$q$)

  when 'qa-273-47' then jsonb_build_object(
    'kind','ddl','mutation','open the anon door: grant EXECUTE on cron_wake to anon',
    'sql', $q$grant execute on function public.cron_wake(text) to anon$q$)

  when 'qa-274-54' then jsonb_build_object(
    'kind','dml','mutation','delete every externally-reported pass (the widget runner''s proof)',
    'sql', $q$delete from dev_journey_runs
               where journey_id = (select id from dev_journeys where name='qa-274-54')
                 and status='passed' and not (evidence ? 'db_proof')$q$)

  when 'qa-274-57' then jsonb_build_object(
    'kind','ddl','mutation','leak PTR to an unentitled viewer (card_price.has_ptr true on the MRP-only branch)',
    'sql', $q$select public._mut_src('public._pricing_block(numeric,medicine_pricing,numeric)'::regprocedure,
                                     '''has_ptr'',      false', '''has_ptr'',      true')$q$)

  else null end;
$$;

-- ── 4. one trial: break it, probe it, roll it back ───────────────────────────
create or replace function public.mutation_trial(p_journey text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '300000'
as $$
declare
  v_recipe jsonb; v_before text; v_after text := null; v_rows bigint := 0;
  v_err text := null; v_verdict text; v_caught boolean := null; v_probe jsonb;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'mutation_trial: runner only';
  end if;
  if not exists (select 1 from dev_journeys where name = p_journey and enabled) then
    return jsonb_build_object('journey', p_journey, 'verdict', 'unknown_journey');
  end if;

  v_recipe := _mutation_recipe(p_journey);
  if v_recipe is null then
    return jsonb_build_object('journey', p_journey, 'verdict', 'no_recipe');
  end if;

  -- Baseline. A journey that is not green before the mutation cannot be said to
  -- have missed it, so the trial stops here and says so.
  v_before := (dev_journey_probe(p_journey))->>'status';
  if v_before <> 'passed' then
    return jsonb_build_object('journey', p_journey, 'mutation', v_recipe->>'mutation',
      'baseline', v_before, 'verdict', 'baseline_not_passed');
  end if;

  begin
    execute (v_recipe->>'sql');
    get diagnostics v_rows = row_count;
    if (v_recipe->>'kind') = 'dml' and v_rows = 0 then
      raise exception using errcode = 'MUT00', message = 'mutation affected 0 rows';
    end if;
    v_probe := dev_journey_probe(p_journey);
    v_after := v_probe->>'status';
    -- Always leave by the exception door: that is what reverts the mutation.
    raise exception using errcode = 'MUT01', message = 'planned rollback';
  exception
    when sqlstate 'MUT01' then null;                       -- clean rollback
    when sqlstate 'MUT00' then v_err := 'mutation affected 0 rows';
    when others then v_err := sqlerrm;                     -- also rolled back
  end;

  if v_err is not null then
    v_verdict := 'not_applied';
  else
    -- "Caught" = the suite stopped certifying the broken target. A flip to
    -- failed OR to skipped both mean the green light went out, and only a
    -- passed run satisfies the completion gate.
    v_caught := (v_after is distinct from 'passed');
    v_verdict := case when v_caught then 'caught' else 'escaped' end;
  end if;

  return jsonb_build_object(
    'journey',  p_journey,
    'mutation', v_recipe->>'mutation',
    'baseline', v_before,
    'after',    v_after,
    'rows',     v_rows,
    'caught',   v_caught,
    'error',    v_err,
    'verdict',  v_verdict,
    'reverted', true);
end $$;
revoke execute on function public.mutation_trial(text) from public, anon, authenticated;

-- ── 5. the weekly sweep ──────────────────────────────────────────────────────
-- p_journeys null  => every enabled journey that has a recipe.
-- p_report  true   => file each decided trial through mutation_report().
create or replace function public.mutation_audit_run(p_journeys text[] default null,
                                                     p_report boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '600000'
as $$
declare
  j record; v jsonb; v_out jsonb := '[]'; v_caught int := 0; v_escaped int := 0;
  v_undecided int := 0;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'mutation_audit_run: runner only';
  end if;

  for j in
    select name from dev_journeys
     where enabled and (p_journeys is null or name = any(p_journeys))
     order by id
  loop
    v := mutation_trial(j.name);
    v_out := v_out || v;
    if v->>'verdict' = 'caught' then
      v_caught := v_caught + 1;
    elsif v->>'verdict' = 'escaped' then
      v_escaped := v_escaped + 1;
    else
      v_undecided := v_undecided + 1;
    end if;

    if p_report and v->>'verdict' in ('caught','escaped') then
      perform mutation_report(j.name, v->>'mutation', (v->>'caught')::boolean,
        'baseline=' || coalesce(v->>'baseline','?') ||
        ' after=' || coalesce(v->>'after','?') ||
        ' rows=' || coalesce(v->>'rows','0') ||
        ' | mutation applied and rolled back inside one subtransaction');
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'caught', v_caught, 'escaped', v_escaped,
    'undecided', v_undecided, 'trials', v_out);
end $$;
revoke execute on function public.mutation_audit_run(text[], boolean) from public, anon, authenticated;
