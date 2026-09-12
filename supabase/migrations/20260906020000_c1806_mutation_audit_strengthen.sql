-- CHANGE #1806 — Weekly mutation audit: the one mutation that escaped.
--
-- The audit ran mutation_trial_suite() on the build branch against every
-- enabled journey that carries a recipe. Nineteen recipes, five journeys green
-- enough to be trialled, four caught. One escaped:
--
--   worker-grid-loads | "empty the worker grid snapshot (workers=[], no lane
--                        labels)" | after=passed
--
-- The probe held two no-counterexample assertions — every command building for
-- over two minutes has a chip, and no chip it DOES show is missing id/lane/
-- status. Both are satisfied VACUOUSLY by an empty array: with no chips there
-- is no chip to be blank, and (on any box whose command rows are quiet) no
-- command to be missing. So the journey whose one sentence reads "the grid
-- shows >=1 worker chip with lane labels" certified a grid showing nothing.
--
-- Two assertions are added, both phrased so a genuinely idle box stays green:
--   a3  the grid may not be EMPTY while work is live — no command may be
--       building with a heartbeat inside the last 10 minutes. Deliberately a
--       statement about the empty grid and not about per-command coverage: the
--       supervisor republishes every 20s, so demanding a chip for each command
--       individually would go red every time a claim landed between two
--       publishes. (The 2-minute rule in a1 keys off started_at, which a
--       claimed row can carry as NULL — that is the hole a3 closes.)
--   a4  an EMPTY grid must carry its own reason — shrink_reason is what the
--       supervisor writes whenever it scales the pool down (quota, cpu), so a
--       deliberate scale-to-zero is still green and an unexplained empty grid,
--       which is exactly what this journey exists to catch, is red.
--
-- Idempotent and safe to replay on live:
--   * The probe is patched BY TEXT SURGERY on its own live definition, so this
--     file cannot revert whatever else dev_journey_probe has grown, and it
--     silently does nothing where the function is the #1761 production refusal
--     stub ("journeys must run on the build branch, never on production").
--   * _mutation_recipe is shipped whole. Live carried 7 recipes while the build
--     branch carried 19: every recipe written by an earlier weekly audit lived
--     only on the branch, so the next branch cut from live would have lost 12 of
--     them. A branch is cut from LIVE, so the audit's coverage has to live here.

-- ── 1. The probe: two more assertions on the worker grid ──────────────────────
do $mig$
declare v_def text; v_new text; v_old text; v_rep text;
begin
  if to_regprocedure('public.dev_journey_probe(text)') is null then
    return;                                   -- nothing to patch
  end if;
  v_def := pg_get_functiondef('public.dev_journey_probe(text)'::regprocedure);

  if position('c1806-strengthen' in v_def) > 0 then
    return;                                   -- already applied
  end if;
  if position('no chip missing id/lane/status=' in v_def) = 0 then
    return;                                   -- production refusal stub (#1761)
  end if;

  v_old := $old$    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'chips='||jsonb_array_length(v_chk->'workers')::text||
        ' | every settled building command has a chip='||coalesce(v_a1,false)::text||
        ' | no chip missing id/lane/status='||coalesce(v_a2,false)::text));$old$;

  v_rep := $new$    -- c1806-strengthen. An empty array satisfied a1 and a2 vacuously,
    -- so the weekly mutation audit emptied the grid and the journey still said
    -- passed. Both of these make "no chips at all" an answer the snapshot has
    -- to justify: a3 against the live rows, a4 against the snapshot itself.
    v_a3 := true;
    v_a4 := true;
    if coalesce(jsonb_array_length(v_chk->'workers'), 0) = 0 then
      select not exists (
        select 1 from dev_commands d
         where d.status = 'building'
           and d.id > 0
           and d.heartbeat_at > now() - interval '10 minutes') into v_a3;
      v_a4 := coalesce(trim(v_chk->>'shrink_reason'), '') <> '';
    end if;
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
            and coalesce(v_a3,false) and coalesce(v_a4,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'chips='||jsonb_array_length(v_chk->'workers')::text||
        ' | every settled building command has a chip='||coalesce(v_a1,false)::text||
        ' | no chip missing id/lane/status='||coalesce(v_a2,false)::text||
        ' | no live worker while the grid is empty='||coalesce(v_a3,false)::text||
        ' | an empty grid carries a reason='||coalesce(v_a4,false)::text));$new$;

  v_new := replace(v_def, v_old, v_rep);
  if v_new = v_def then
    raise exception 'c1806: the worker-grid-loads assertion block moved — patch it by hand';
  end if;
  execute v_new;
end $mig$;

-- ── 2. The recipe book, shipped to live so the next branch keeps it ─────────
-- Live carried 7 of these 19. A branch is cut from live, so every recipe an
-- earlier audit wrote on the branch was one branch away from being lost.
CREATE OR REPLACE FUNCTION public._mutation_recipe(p_journey text)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
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
    'sql', $q$update ui_copy set value='"MUTATED_NOT_OK"'::jsonb where key='journey.test'$q$)

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
$function$

;
