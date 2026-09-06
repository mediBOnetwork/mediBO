-- CHANGE #1823 (part 3) — a pipeline that cannot START is blocked, not red.
--
-- The critical-path smoke's `devtool.order_pipeline` journey calls
-- test_pipeline_run(). When Om's incognito switch (test_mode_config.enabled)
-- is off, that function returned {ok:false, error:'test_mode_off'} with no
-- `blocked` flag and no `detail`, so run.js graded it FAILED with an empty
-- reason and the deploy-lane card said "failed 1" about a product that was
-- fine. run.js already grades `blocked:true` as BLOCKED (never a pass, never
-- a silent skip); the backend just never said it. Idempotent: CREATE OR
-- REPLACE of one function, body otherwise unchanged.
CREATE OR REPLACE FUNCTION public.test_pipeline_run(p_run_id bigint DEFAULT NULL::bigint, p_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v jsonb; v_order uuid := p_order_id; v_stages jsonb := '[]'::jsonb;
        v_ok boolean := true; v_failed text := ''; v_legacy bigint; v_blocked boolean := false;
begin
  perform public._dev_guard();
  if not public.test_mode_on() then
    -- CHANGE #1823: a pipeline the ENVIRONMENT would not start is BLOCKED, in
    -- the backend's own sentence — never a red with an empty detail. Run 33
    -- (batch 609) reported "FAILED order pipeline — 0/9 stages —" with nothing
    -- after the dash because this branch returned ok:false and no `blocked`,
    -- and the assertion only forwards `detail`. Blocked is not a pass: the
    -- smoke verdict on the deploy lane card counts it and says why.
    return jsonb_build_object('ok', false, 'blocked', true, 'error','test_mode_off',
      'detail', public.uic('test_mode.off','Test mode is switched off.'),
      'message', public.uic('test_mode.off','Test mode is switched off.'),
      'stages', '[]'::jsonb, 'stages_total',
      (select count(*) from public.test_pipeline_stage where is_active),
      'stages_passed', 0, 'failed_stage', 'placed',
      'order_id', null, 'run_id', p_run_id, 'legacy_run_id', null);
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
    -- CHANGE #1823: the lines and the inquiry rows carry the same stamp as the
    -- order, so the purge (replica mode, no cascade) removes the whole order.
    update public.order_items oi
       set test_session_id = coalesce(oi.test_session_id,
             (select test_session_id from public.test_runs where id = p_run_id))
     where oi.order_id = v_order;
    update public.inquiry i
       set test_session_id = coalesce(i.test_session_id,
             (select test_session_id from public.test_runs where id = p_run_id))
     where i.id in (select oi.inquiry_id from public.order_items oi where oi.order_id = v_order and oi.inquiry_id is not null);
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
