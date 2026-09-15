-- CHANGE #468 (follow-up) -- the canary proves its own cleanliness.
--
-- heartbeat_run_once opened its test session with no before_fp, so
-- test_session_purge could only ever report business_unchanged=false: that flag
-- reads "before_fp is not null and before_fp = after". Every green run carried a
-- false negative on the exact claim the canary exists to make ("no business row
-- moved"). Idempotent: a plain CREATE OR REPLACE of the same function.

CREATE OR REPLACE FUNCTION public.heartbeat_run_once(p_kind text DEFAULT 'daily'::text, p_break_stage text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg public.heartbeat_config%rowtype;
  st record; v_run bigint; v_sess bigint; v_ctx jsonb; v_res jsonb;
  v_ok boolean; v_err text; v_t0 timestamptz; v_ms int; v_started timestamptz := clock_timestamp();
  v_total int; v_passed int := 0; v_fail_key text; v_fail_label text;
  v_order uuid; v_code text; v_secs numeric; v_line text; v_tpl text;
  v_clean jsonb; v_break text := nullif(btrim(coalesce(p_break_stage,'')),'');
  v_try int;
begin
  if not public._test_guard() then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select * into cfg from public.heartbeat_config where id = 1;
  if not coalesce(cfg.enabled, true) and coalesce(p_kind,'daily') = 'daily' then
    return jsonb_build_object('ok', true, 'skipped','disabled',
      'summary_line', public.notif_render(public.uic('heartbeat.summary_skipped',''),
                        jsonb_build_object('reason', public.uic('heartbeat.disabled',''))));
  end if;
  -- Om's own test session stamps every insert on the platform. The canary
  -- never runs underneath one: it would adopt his rows and he would be
  -- debugging against a database that moves on its own.
  if public.test_session_live_id() is not null then
    return jsonb_build_object('ok', true, 'skipped','test_mode_live',
      'summary_line', public.notif_render(public.uic('heartbeat.summary_skipped',''),
                        jsonb_build_object('reason', public.uic('heartbeat.busy',''))));
  end if;

  -- status 'canary', never 'live': test_sessions_one_live is a unique index on
  -- (true) where status='live', so a canary claiming it would lock Om out of
  -- his own test mode and serialise every run behind that one index tuple.
  -- CHANGE #468 (follow-up): stamp the BEFORE fingerprint on the session, the
  -- way test_session_open already does. Without it test_session_purge's
  -- business_unchanged flag -- "before_fp is not null and before_fp = after" --
  -- is structurally FALSE for every canary run, so the one claim the canary
  -- exists to make could only be asserted, never proven. test_fingerprint()
  -- costs ~220 ms and the purge already pays for it once at the other end.
  insert into public.test_sessions (label, scope, status, started_by_label, expires_at, before_fp)
  values ('heartbeat ' || to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
          'canary', 'canary', 'heartbeat', now() + interval '2 hours',
          public.test_fingerprint())
  returning id into v_sess;

  select count(*) into v_total from public.heartbeat_stage where enabled;
  insert into public.heartbeat_run (kind, status, test_session_id, break_stage, stages_total)
  values (coalesce(p_kind,'daily'), 'running', v_sess, v_break, v_total)
  returning id into v_run;

  -- everything created from here to the reset below is the canary's own
  perform set_config('medibo.synthetic', 'on', true);
  perform public._hb_impersonate();

  v_ctx := jsonb_build_object('since', v_started::text,
                              'order_date', (now() at time zone 'Asia/Kolkata')::date::text);

  for st in select * from public.heartbeat_stage where enabled order by ord loop
    v_t0 := clock_timestamp();
    insert into public.heartbeat_stage_run (run_id, ord, stage_key, label, status, timeout_ms)
    values (v_run, st.ord, st.stage_key, st.label, 'running',
            coalesce(st.timeout_ms, cfg.default_timeout_ms));
    v_try := 0;
    <<attempt>>
    loop
      v_try := v_try + 1;
      begin
        perform set_config('statement_timeout',
                           coalesce(st.timeout_ms, cfg.default_timeout_ms)::text, true);
        -- the session default is 5 s, which a busy warehouse refresh can exceed
        -- without anything being wrong; bound the wait by THIS stage's budget.
        perform set_config('lock_timeout',
                           least(coalesce(st.timeout_ms, cfg.default_timeout_ms), 15000)::text, true);
        if v_break is not null and st.stage_key = v_break then
          raise exception 'deliberate drill break at stage %', st.stage_key using errcode = 'P0001';
        end if;
        v_res := public._hb_stage(st.stage_key, v_run, v_ctx);
        v_ok  := coalesce((v_res->>'ok')::boolean, false);
        v_err := nullif(v_res->>'error','');
        if v_ok then v_ctx := v_ctx || coalesce(v_res->'ctx','{}'::jsonb); end if;
      exception
        when lock_not_available or serialization_failure or deadlock_detected then
          v_ok := false;
          v_err := sqlstate || ': ' || sqlerrm;
          v_res := jsonb_build_object('ok', false, 'error', v_err, 'contention', true, 'attempt', v_try);
        when query_canceled then
          v_ok := false;
          v_err := 'timed out after ' || coalesce(st.timeout_ms, cfg.default_timeout_ms)::text || ' ms';
          v_res := jsonb_build_object('ok', false, 'error', v_err, 'timeout', true);
        when others then
          v_ok := false;
          v_err := sqlstate || ': ' || sqlerrm;
          v_res := jsonb_build_object('ok', false, 'error', v_err);
      end;
      exit attempt when v_ok
                     or v_try >= 3
                     or not coalesce((v_res->>'contention')::boolean, false);
      perform pg_sleep(2);            -- two honest retries, then it is a failure
    end loop;
    perform set_config('statement_timeout', '0', true);
    perform set_config('lock_timeout', '5s', true);
    v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;

    update public.heartbeat_stage_run
       set status = case when v_ok then 'passed' else 'failed' end,
           ended_at = now(), ms = v_ms, detail = v_res, error = v_err
     where run_id = v_run and stage_key = st.stage_key;

    if not v_ok then
      v_fail_key := st.stage_key; v_fail_label := st.label;
      exit;                                    -- FIRST failure stops the run
    end if;
    v_passed := v_passed + 1;
  end loop;

  -- Anything still pending never ran; say so rather than leaving it blank.
  insert into public.heartbeat_stage_run (run_id, ord, stage_key, label, status, timeout_ms, ended_at)
  select v_run, s.ord, s.stage_key, s.label, 'skipped', s.timeout_ms, now()
    from public.heartbeat_stage s
   where s.enabled
     and not exists (select 1 from public.heartbeat_stage_run r
                      where r.run_id = v_run and r.stage_key = s.stage_key);

  -- the alert is a REAL message: stop stamping before it is written
  perform set_config('medibo.synthetic', 'off', true);

  v_order := nullif(v_ctx->>'order_id','')::uuid;
  v_code  := nullif(v_ctx->>'order_code','');
  v_secs  := round(extract(epoch from (clock_timestamp() - v_started))::numeric, 1);

  update public.heartbeat_run
     set status = case when v_fail_key is null then 'passed' else 'failed' end,
         ended_at = now(),
         ms = (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int,
         order_id = v_order, order_code = v_code,
         stages_passed = v_passed, failed_stage = v_fail_key, failed_label = v_fail_label,
         error = (select error from public.heartbeat_stage_run
                   where run_id = v_run and stage_key = v_fail_key),
         exclusions = v_ctx->'audit'
   where id = v_run;

  v_clean := public.heartbeat_cleanup(v_run);

  if v_fail_key is null then
    v_tpl := public.uic('heartbeat.summary_ok','');
    v_line := public.notif_render(v_tpl, jsonb_build_object(
      'passed', v_passed::text, 'total', v_total::text,
      'secs', v_secs::text, 'order', coalesce(v_code,'—')));
  else
    v_tpl := public.uic('heartbeat.summary_fail','');
    v_line := public.notif_render(v_tpl, jsonb_build_object(
      'stage', coalesce(v_fail_label, v_fail_key),
      'error', coalesce((select error from public.heartbeat_stage_run
                          where run_id = v_run and stage_key = v_fail_key), ''),
      'order', coalesce(v_code,'—')));
  end if;
  update public.heartbeat_run set summary_line = v_line where id = v_run;

  if v_fail_key is not null then
    perform public.heartbeat_alert(v_run);
  end if;

  return jsonb_build_object(
    'ok', v_fail_key is null, 'run_id', v_run, 'kind', coalesce(p_kind,'daily'),
    'order_id', v_order, 'order_code', v_code,
    'stages_passed', v_passed, 'stages_total', v_total,
    'failed_stage', v_fail_key, 'failed_label', v_fail_label,
    'summary_line', v_line, 'cleanup', v_clean,
    'clean', coalesce((select clean from public.heartbeat_run where id = v_run), false));
end $function$


