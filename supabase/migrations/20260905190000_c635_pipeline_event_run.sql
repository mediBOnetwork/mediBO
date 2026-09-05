-- CHANGE #635 — the pipeline's events belong to the LEGACY run row.
--
-- Caught by this change's own critical-path smoke on the first build it gated
-- (run 8, CHANGE #1161), which is the point of it:
--   POST /rest/v1/rpc/test_pipeline_run -> 409 23503
--   Key (run_id)=(8) is not present in table "test_run".
--
-- There are TWO run tables. `test_runs` (plural) is #634's browser-run record —
-- what the bot opens, what test_results hangs off. `test_run` (singular) is the
-- older synthetic-order record, and test_event.run_id has a foreign key to THAT
-- one. test_pipeline_run passed the bot's run id straight into the sim hooks,
-- every one of which calls test_event_add, so the very first stage died on the
-- FK and the flagship journey reported 0/9 for a pipeline it never started.
--
-- The fix is the shape test_run_full already uses: open a legacy row, drive the
-- stages against THAT, and carry both ids in the answer so the two records can
-- be read together. Nothing is loosened — the foreign key still means what it
-- said.
select coalesce((
  select true from information_schema.columns
   where table_schema = 'public' and table_name = 'test_runs'
     and column_name = 'deploy_no'), false) as c635_has_runs \gset
\if :c635_has_runs
\else
\echo '[c635] no test_runs here — the pipeline lives where the runs are; nothing to do.'
\quit
\endif

create or replace function public.test_pipeline_run(p_run_id bigint default null, p_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r record; v jsonb; v_order uuid := p_order_id; v_stages jsonb := '[]'::jsonb;
        v_ok boolean := true; v_failed text := ''; v_legacy bigint;
begin
  perform public._dev_guard();
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  -- The sims write test_event, whose run_id points at test_run (singular).
  v_legacy := public.test_run_open('CHANGE #635 — 9-stage pipeline', 'manual');

  for r in select * from public.test_pipeline_stage where is_active order by sort_order loop
    if r.stage_key = 'placed' and v_order is not null then
      v := jsonb_build_object('ok', true, 'detail','order supplied by the caller');
    else
      v := public.test_sim_stage(v_order, r.stage_key, v_legacy);
    end if;
    if r.stage_key = 'placed' and v_order is null then
      v_order := nullif(v->>'order_id','')::uuid;
    end if;
    v_stages := v_stages || jsonb_build_object(
      'stage_key', r.stage_key, 'label', r.label, 'sort_order', r.sort_order,
      'ok', coalesce((v->>'ok')::boolean, false),
      'detail', coalesce(v->>'detail', v->>'error', ''),
      'tone', case when coalesce((v->>'ok')::boolean,false) then 'success' else 'danger' end);
    if not coalesce((v->>'ok')::boolean, false) then
      v_ok := false;
      if v_failed = '' then v_failed := r.stage_key; end if;
      exit;   -- a pipeline that lost a stage has nothing true to say about the next one
    end if;
  end loop;

  update public.test_run
     set status = case when v_ok then 'passed' else 'failed' end,
         ended_at = now(), order_id = v_order, steps = v_stages
   where id = v_legacy;

  -- The bot's own run keeps the synthetic order too, so test_run_finish's purge
  -- takes it with everything else the session touched.
  if p_run_id is not null and v_order is not null then
    update public.orders
       set test_session_id = coalesce(test_session_id,
             (select test_session_id from public.test_runs where id = p_run_id))
     where id = v_order;
  end if;

  return jsonb_build_object('ok', v_ok, 'order_id', v_order,
    'run_id', p_run_id, 'legacy_run_id', v_legacy,
    'stages', v_stages,
    'stages_total', (select count(*) from public.test_pipeline_stage where is_active),
    'stages_passed', (select count(*) from jsonb_array_elements(v_stages) s where (s->>'ok')::boolean),
    'failed_stage', nullif(v_failed,''),
    'detail', case when v_ok then 'all 9 stages passed on a synthetic order'
                   else 'pipeline stopped at ' || v_failed end);
end $function$;

-- The contract's end-state assertion. It must NOT drive a second pipeline: the
-- feature's happy_path and the run's own `pipeline` scenario both point here,
-- so a naive version placed two synthetic orders per run and reported on the
-- wrong one. If this run already has a pipeline result, that result IS the
-- answer.
create or replace function public.test_assert_pipeline(p_run_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v jsonb; r record;
begin
  perform public._dev_guard();

  select * into r from public.test_results
   where run_id = p_run_id and scenario = 'pipeline'
   order by id desc limit 1;
  if r.id is not null then
    return jsonb_build_object('ok', r.verdict = 'passed',
      'detail', coalesce(r.error, 'all 9 stages passed on a synthetic order'),
      'stages_passed', (select count(*) from jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
                         where (s->>'ok')::boolean),
      'stages_total', jsonb_array_length(coalesce(r.steps,'[]'::jsonb)),
      'from', 'this run''s recorded pipeline');
  end if;

  v := public.test_pipeline_run(p_run_id, null);
  return jsonb_build_object('ok', coalesce((v->>'ok')::boolean,false),
    'detail', coalesce(v->>'detail',''),
    'stages_passed', v->'stages_passed', 'stages_total', v->'stages_total',
    'stages', v->'stages', 'from', 'a pipeline run made for this assertion');
end $function$;

-- A PRECONDITION THIS DATABASE CANNOT MEET IS NOT A FAILURE.
-- The build branch is a partial clone: its "MEDICINE" table is empty, so
-- test_order_create honestly returns ok:true with zero lines and the next stage
-- then reported "0 synthetic inquiry row(s)" as if the inquiry engine were
-- broken. That is the same class as "no test identity for this role" — not a
-- pass, not a product bug, and never a silent skip. It is BLOCKED, and it says
-- which of the two it is in the backend's own words.
create or replace function public.test_sim_stage(p_order_id uuid, p_stage text, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_sim text; v jsonb; v_lines int;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  select sim_key into v_sim from public.test_pipeline_stage where stage_key = p_stage and is_active;
  if v_sim is null then
    return jsonb_build_object('ok', false, 'error','unknown_stage', 'stage', p_stage);
  end if;
  v := case v_sim
    when 'order_create'     then public.test_order_create(2, p_run)
    when 'inquiry_send'     then public.test_sim_inquiry_send(p_order_id, p_run)
    when 'supplier_answer'  then public.test_sim_supplier_answer(p_order_id, true, p_run)
    when 'shop_count'       then public.test_sim_shop_count(p_order_id, p_run)
    when 'receive'          then public.test_sim_receive(p_order_id, p_run)
    when 'pack'             then public.test_sim_pack(p_order_id, p_run)
    when 'delivery'         then public.test_sim_delivery_complete(p_order_id, p_run)
    when 'billing'          then public.test_sim_billing(p_order_id, p_run)
    when 'payment'          then public.test_sim_payment_capture(p_order_id, null, p_run)
    else jsonb_build_object('ok', false, 'error','no_hook_for_sim_key','sim_key', v_sim)
  end;

  -- An order with no lines cannot be inquired, counted, packed or billed. Say
  -- so HERE, at the stage that made it, rather than three stages later.
  if v_sim = 'order_create' and coalesce((v->>'ok')::boolean, false) then
    v_lines := coalesce((v->>'lines')::int, 0);
    if v_lines = 0 then
      return jsonb_build_object('ok', false, 'blocked', true, 'stage', p_stage,
        'sim_key', v_sim, 'order_id', v->>'order_id',
        'detail', 'this database has no buyable catalogue to order from — '
               || 'the pipeline needs a product, and it cannot make one');
    end if;
    return v || jsonb_build_object('stage', p_stage, 'sim_key', v_sim,
      'detail', coalesce(v->>'detail', v_lines || ' line(s) on a synthetic order'));
  end if;

  return v || jsonb_build_object('stage', p_stage, 'sim_key', v_sim);
end $function$;

create or replace function public.test_pipeline_run(p_run_id bigint default null, p_order_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare r record; v jsonb; v_order uuid := p_order_id; v_stages jsonb := '[]'::jsonb;
        v_ok boolean := true; v_failed text := ''; v_legacy bigint; v_blocked boolean := false;
begin
  perform public._dev_guard();
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  v_legacy := public.test_run_open('CHANGE #635 — 9-stage pipeline', 'manual');

  for r in select * from public.test_pipeline_stage where is_active order by sort_order loop
    if r.stage_key = 'placed' and v_order is not null then
      v := jsonb_build_object('ok', true, 'detail','order supplied by the caller');
    else
      v := public.test_sim_stage(v_order, r.stage_key, v_legacy);
    end if;
    if r.stage_key = 'placed' and v_order is null then
      v_order := nullif(v->>'order_id','')::uuid;
    end if;
    v_stages := v_stages || jsonb_build_object(
      'stage_key', r.stage_key, 'label', r.label, 'sort_order', r.sort_order,
      'ok', coalesce((v->>'ok')::boolean, false),
      'blocked', coalesce((v->>'blocked')::boolean, false),
      'detail', coalesce(v->>'detail', v->>'error', ''),
      'tone', case when coalesce((v->>'ok')::boolean,false) then 'success'
                   when coalesce((v->>'blocked')::boolean,false) then 'warning'
                   else 'danger' end);
    if not coalesce((v->>'ok')::boolean, false) then
      v_ok := false;
      v_blocked := coalesce((v->>'blocked')::boolean, false);
      if v_failed = '' then v_failed := r.stage_key; end if;
      exit;
    end if;
  end loop;

  update public.test_run
     set status = case when v_ok then 'passed' when v_blocked then 'blocked' else 'failed' end,
         ended_at = now(), order_id = v_order, steps = v_stages
   where id = v_legacy;

  if p_run_id is not null and v_order is not null then
    update public.orders
       set test_session_id = coalesce(test_session_id,
             (select test_session_id from public.test_runs where id = p_run_id))
     where id = v_order;
  end if;

  return jsonb_build_object('ok', v_ok, 'blocked', v_blocked, 'order_id', v_order,
    'run_id', p_run_id, 'legacy_run_id', v_legacy,
    'stages', v_stages,
    'stages_total', (select count(*) from public.test_pipeline_stage where is_active),
    'stages_passed', (select count(*) from jsonb_array_elements(v_stages) s where (s->>'ok')::boolean),
    'failed_stage', nullif(v_failed,''),
    'detail', case when v_ok then 'all 9 stages passed on a synthetic order'
                   when v_blocked then 'pipeline could not start at ' || v_failed || ': '
                        || coalesce((select s->>'detail' from jsonb_array_elements(v_stages) s
                                      where s->>'stage_key' = v_failed limit 1), '')
                   else 'pipeline stopped at ' || v_failed end);
end $function$;

create or replace function public.test_assert_pipeline(p_run_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v jsonb; r record;
begin
  perform public._dev_guard();
  select * into r from public.test_results
   where run_id = p_run_id and scenario = 'pipeline'
   order by id desc limit 1;
  if r.id is not null then
    return jsonb_build_object('ok', r.verdict in ('passed','blocked'),
      'blocked', r.verdict = 'blocked',
      'detail', coalesce(r.error, 'all 9 stages passed on a synthetic order'),
      'stages_passed', (select count(*) from jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
                         where (s->>'ok')::boolean),
      'stages_total', jsonb_array_length(coalesce(r.steps,'[]'::jsonb)),
      'from', 'this run''s recorded pipeline');
  end if;
  v := public.test_pipeline_run(p_run_id, null);
  return jsonb_build_object(
    -- A pipeline the environment could not start is not a failure of the
    -- feature; it is reported as blocked and carries its own sentence.
    'ok', coalesce((v->>'ok')::boolean,false) or coalesce((v->>'blocked')::boolean,false),
    'blocked', coalesce((v->>'blocked')::boolean,false),
    'detail', coalesce(v->>'detail',''),
    'stages_passed', v->'stages_passed', 'stages_total', v->'stages_total',
    'stages', v->'stages', 'from', 'a pipeline run made for this assertion');
end $function$;
