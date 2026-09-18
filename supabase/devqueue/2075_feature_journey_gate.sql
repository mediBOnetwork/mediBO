-- CMD #2075 — FEATURE JOURNEY GATE, part 2 (control plane: dev-queue project only).
-- Apply AFTER 2075_feature_journey.sql:
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/devqueue/2075_feature_journey_gate.sql
-- Three existing functions, each re-created from its live body plus ONE block:
--   dev_cmd_finish_state — the condition 'feature_journey' (Feature journey green on live)
--   dev_cmd_complete     — refuses a needed, enforced, non-green feature journey
--   dev_cmd_qa_detail    — carries the feature_journey card the command detail renders
begin;

CREATE OR REPLACE FUNCTION public.dev_cmd_finish_state(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v jsonb := '[]'::jsonb; v_block text[] := '{}';
        v_android text;
        v_gate boolean; v_proofs jsonb; v_mobile jsonb; v_missing text; v_change int;
        v_cfg jsonb; v_on boolean; v_grace int; v_selftest boolean;
        v_ready boolean; v_journeys int; v_spec text; v_spec_open int;
        v_fj jsonb; v_fj_on boolean;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  select coalesce(value->'finish_gate', '{}'::jsonb) into v_cfg
    from dev_runner_config where key = 'worker_pool';
  v_on    := coalesce((v_cfg->>'enabled')::boolean, true);
  v_grace := coalesce((v_cfg->>'grace_s')::int, 120);

  v_gate := (coalesce(r.kind,'dev') = 'dev' and coalesce(r.route,'') <> 'fast' and coalesce(r.qa_required,false));

  if r.status <> 'building' then v_block := array_append(v_block, (('not building (' || r.status || ')'))::text); end if;
  if coalesce(r.needs_input_question,'') <> '' then v_block := array_append(v_block, ('an unanswered question is open')::text); end if;
  -- CHANGE #571 (2) — a parked row is WAITING, not finished. It must never be
  -- auto-completed while its blocker is still being waited on.
  if r.wait_state = 'parked' then
    v_block := array_append(v_block, ('parked: ' || coalesce(r.wait_reason,'waiting'))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','building','label','Row is building',
        'applies', true, 'ok', r.status = 'building' and coalesce(r.needs_input_question,'') = ''
                                and r.wait_state is distinct from 'parked',
        'detail', case when r.wait_state = 'parked' then 'parked' else r.status end));

  v := v || jsonb_build_array(jsonb_build_object('key','steps','label','Every step marked done',
        'applies', true,
        'ok', coalesce(r.steps_total,0) > 0 and coalesce(r.steps_done,0) >= r.steps_total,
        'detail', coalesce(r.steps_done,0)::text || '/' || coalesce(r.steps_total,0)::text));
  if coalesce(r.steps_total,0) = 0 then
    v_block := array_append(v_block, ('no step plan published')::text);
  elsif coalesce(r.steps_done,0) < r.steps_total then
    v_block := array_append(v_block, (('steps ' || coalesce(r.steps_done,0) || '/' || r.steps_total))::text);
  end if;

  -- CHANGE #571 (3) — the command's OWN spec checklist, on the same footing
  -- as the step plan. #536 finished with My Shop nav and Profile cleanup
  -- unbuilt because nothing ever compared the result against the spec.
  select count(*) into v_spec_open from dev_command_spec_item
   where command_id = p_id and status = 'open';
  v_spec := _dev_spec_gate(p_id);
  if v_spec is not null then v_block := array_append(v_block, v_spec::text); end if;
  v := v || jsonb_build_array(jsonb_build_object('key','spec','label','Every spec item built',
        'applies', exists (select 1 from dev_command_spec_item where command_id = p_id),
        'ok', coalesce(v_spec_open,0) = 0,
        'detail', ((select count(*) from dev_command_spec_item
                     where command_id = p_id and status <> 'open')::text || '/' ||
                   (select count(*) from dev_command_spec_item where command_id = p_id)::text)));

  if v_gate and coalesce(r.qa_status,'pending') not in ('passed','waived') then
    v_block := array_append(v_block, (('QA is ' || coalesce(r.qa_status,'pending')))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','qa','label','QA passed',
        'applies', v_gate, 'ok', (not v_gate) or coalesce(r.qa_status,'') in ('passed','waived'),
        'detail', coalesce(r.qa_status,'')));

  if v_gate then
    if exists (select 1 from dev_journey_runs jr
                where jr.command_id = p_id and jr.status = 'failed'
                  and not exists (select 1 from dev_journey_runs jr2
                                   where jr2.command_id = p_id and jr2.journey_id = jr.journey_id
                                     and jr2.status = 'passed' and jr2.id > jr.id))
    then v_block := array_append(v_block, ('a journey run failed without a later pass')::text); end if;
    select string_agg(j.name, ', ') into v_missing
      from dev_journeys j
     where j.enabled
       and ((j.required and (j.area is null or j.area is not distinct from r.area)) or j.source_bug = p_id)
       and not exists (select 1 from dev_journey_runs jr
                        where jr.command_id = p_id and jr.journey_id = j.id and jr.status = 'passed');
    if v_missing is not null then v_block := array_append(v_block, (('journeys not passed: ' || v_missing))::text); end if;
  end if;
  select count(*) into v_journeys from dev_journey_runs jr
   where jr.command_id = p_id and jr.status = 'passed';
  v := v || jsonb_build_array(jsonb_build_object('key','journeys','label','Required journeys green',
        'applies', v_gate, 'ok', (not v_gate) or v_missing is null, 'detail', v_journeys::text || ' passed'));

  v_proofs := case when jsonb_array_length(coalesce(r.screenshots,'[]'::jsonb)) > 0
                   then r.screenshots else _dev_finish_proofs(p_id) end;
  if v_gate and jsonb_array_length(v_proofs) = 0 then
    v_block := array_append(v_block, ('no screenshot evidence in dev-cmd-proofs')::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','proof','label','Screenshot proof stored',
        'applies', v_gate, 'ok', (not v_gate) or jsonb_array_length(v_proofs) > 0,
        'detail', jsonb_array_length(v_proofs)::text));

  -- CMD #1950 — MOBILE PROOF. 99% of mediBO users are on phones, so a UI
  -- command is not finished until the changed screen has been captured at
  -- 360px AND 412px, and captured BEFORE any desktop shot. The rule text and
  -- the widths live in dev_runner_config.build_rules.mobile_first.
  v_mobile := _dev_mobile_proof(p_id);
  if v_gate and coalesce(r.targets_web, false)
     and not coalesce((v_mobile->>'ok')::boolean, false) then
    v_block := array_append(v_block, ('mobile proof: ' || (v_mobile->>'detail'))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','mobile','label','Mobile proof (360px + 412px)',
        'applies', v_gate and coalesce(r.targets_web,false),
        'ok', (not (v_gate and coalesce(r.targets_web,false)))
              or coalesce((v_mobile->>'ok')::boolean,false),
        'detail', (v_mobile->>'detail')));

  -- CMD #2075 — FEATURE JOURNEY GREEN ON LIVE. A command that changes a screen
  -- ships its own browser journey (feat-<id>), and the LIVE run of it — after
  -- verify_live.sh, at 360px and 412px, in a purging TEST MODE session — must
  -- be green for the change number that is live. Reused, cached, skipped or
  -- unknown journeys never count. The one truth is _dev_feature_journey_state().
  v_fj := _dev_feature_journey_state(p_id);
  v_fj_on := v_gate and coalesce(r.targets_web, false)
             and coalesce((v_fj->>'needed')::boolean, false)
             and coalesce((v_fj->>'enforced')::boolean, false);
  if v_fj_on and not coalesce((v_fj->>'green')::boolean, false) then
    v_block := array_append(v_block, ('feature journey: ' || (v_fj->>'detail'))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','feature_journey',
        'label', coalesce(nullif(c_ui('dev_queue.gate_feature_journey'),''), 'Feature journey green on live'),
        'applies', v_fj_on,
        'ok', (not v_fj_on) or coalesce((v_fj->>'green')::boolean, false),
        'detail', (v_fj->>'detail')));

  select coalesce(r.web_deploy_no,
           (select q.change_no from deploy_queue q
             where q.command_id = p_id and q.status = 'deployed' and q.change_no is not null
             order by q.id desc limit 1)) into v_change;
  select exists (select 1 from dev_selftest_log s where s.ok and s.at > now() - interval '6 hours')
    into v_selftest;
  if v_gate and coalesce(r.targets_web,false) then
    if v_change is null then v_block := array_append(v_block, ('no deployed change number yet')::text); end if;
    if coalesce(r.preview_status,'') <> 'promoted' then
      v_block := array_append(v_block, (('preview_status=' || coalesce(r.preview_status,'null')))::text);
    end if;
    if v_change is not null and not v_selftest then
      v_block := array_append(v_block, ('no green self-test in the last 6h')::text);
    end if;
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','deploy','label','Change deployed and promoted',
        'applies', v_gate and coalesce(r.targets_web,false),
        'ok', (not (v_gate and coalesce(r.targets_web,false)))
              or (v_change is not null and coalesce(r.preview_status,'') = 'promoted' and v_selftest),
        'detail', coalesce('CHANGE #' || v_change::text, 'none')));

  -- CHANGE #1802 — the ANDROID condition, on the same footing as the web
  -- deploy above. #1801 closed 8/8 green with targets_android true and every
  -- Android column at its default, because nothing here ever looked.
  v_android := _dev_android_gate(p_id);
  if v_android is not null then v_block := array_append(v_block, v_android::text); end if;
  v := v || jsonb_build_array(jsonb_build_object('key','android','label','Android release recorded',
        'applies', coalesce(r.targets_android,false),
        'ok', v_android is null,
        'detail', coalesce(r.android_status,'not_requested')));

  v_ready := (array_length(v_block,1) is null) and v_on;
  if not v_on then v_block := array_append(v_block, ('finish gate disabled in worker_pool.finish_gate')::text); end if;

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'status', r.status,
    'enabled', v_on, 'grace_s', v_grace,
    'ready', v_ready,
    'gate_applies', v_gate,
    'conditions', v,
    'blockers', to_jsonb(coalesce(v_block, '{}'::text[])),
    'blocker_text', coalesce(array_to_string(v_block, ' · '), ''),
    'change_no', v_change,
    'screenshots', v_proofs,
    'mobile_proof', v_mobile,
    'feature_journey', v_fj,
    'spec_open', coalesce(v_spec_open,0),
    'waiting', r.wait_state = 'parked',
    'wait_reason', coalesce(r.wait_reason,''),
    'ready_at', r.finish_ready_at,
    'auto_finished', coalesce(r.auto_finished,false),
    'auto_finish_source', coalesce(r.auto_finish_source,''));
end $function$;

CREATE OR REPLACE FUNCTION public.dev_cmd_complete(p_id bigint, p_result text, p_deploy_no integer DEFAULT NULL::integer, p_screenshots jsonb DEFAULT '[]'::jsonb, p_plain_summary text DEFAULT NULL::text, p_result_actions jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
DECLARE v_rg jsonb; v_row record; v_enforce boolean; v_missing text; v_block text := NULL;
        v_android text;
        v_selftest record; v_spec text;
BEGIN
  PERFORM _dev_guard();

  -- CHANGE #641 — rg_check(true,true) used to run HERE, inside a 180 s
  -- statement, on the caller's connection. It is now cron-only; this is a read.
  SELECT jsonb_build_object('ok', c.ok, 'at', c.at,
           'age_s', round(extract(epoch from now() - c.at))::int)
    INTO v_rg FROM rg_check_cache c ORDER BY c.at DESC LIMIT 1;

  SELECT * INTO v_row FROM dev_commands WHERE id=p_id;
  SELECT coalesce((value->'bugloop'->>'enforce')::boolean,false) INTO v_enforce FROM dev_runner_config WHERE key='worker_pool';

  v_spec := _dev_spec_gate(p_id);
  IF v_spec IS NOT NULL THEN
    RAISE EXCEPTION 'dev_cmd_complete blocked (spec gate): %', v_spec;
  END IF;

  -- CHANGE #1802 — the Android gate raises like the spec gate and NOT behind
  -- worker_pool.bugloop.enforce. That flag is false, which is precisely how
  -- #1801 reported "nothing to deploy" on a row whose only job was a Play
  -- release: a warning nobody reads is not a gate.
  v_android := _dev_android_gate(p_id);
  IF v_android IS NOT NULL THEN
    RAISE EXCEPTION 'dev_cmd_complete blocked (android gate): %', v_android;
  END IF;

  IF v_row.kind='dev' AND v_row.route <> 'fast' AND v_row.qa_required THEN
    IF v_row.qa_status NOT IN ('passed','waived') THEN
      v_block := 'QA verdict is '||v_row.qa_status||' — qa_report(passed) or qa_waive(PIN) required';
    END IF;
    IF v_block IS NULL AND EXISTS (
      SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.status='failed'
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr2 WHERE jr2.command_id=p_id AND jr2.journey_id=jr.journey_id AND jr2.status='passed' AND jr2.id>jr.id)
    ) THEN v_block := 'a journey run failed without a later pass'; END IF;
    IF v_block IS NULL THEN
      SELECT string_agg(j.name, ', ') INTO v_missing
      FROM dev_journeys j
      WHERE j.enabled
        AND (
              (j.required AND (j.area IS NULL OR j.area IS NOT DISTINCT FROM v_row.area))
              OR j.source_bug = p_id
            )
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.journey_id=j.id AND jr.status='passed');
      IF v_missing IS NOT NULL THEN v_block := 'required journeys not passed: '||v_missing; END IF;
    END IF;
    IF v_block IS NULL AND jsonb_array_length(coalesce(p_screenshots,'[]')) = 0 THEN
      v_block := 'no screenshot evidence attached';
    END IF;

    -- CMD #1950 — MOBILE PROOF. A web/UI command completes only with a 360px
    -- and a 412px capture in dev-cmd-proofs, taken before any desktop shot.
    -- Gated on worker_pool.mobile_first.enforce (pool_set flips it, no deploy)
    -- and on effective_at, so a command already in flight when the rule landed
    -- is never ambushed by it.
    IF v_block IS NULL AND coalesce(v_row.targets_web,false)
       AND coalesce((SELECT (value->'mobile_first'->>'enforce')::boolean
                       FROM dev_runner_config WHERE key='worker_pool'), false)
       AND v_row.started_at >= coalesce((SELECT (value->'mobile_first'->>'effective_at')::timestamptz
                       FROM dev_runner_config WHERE key='worker_pool'), now())
       AND NOT coalesce((_dev_mobile_proof(p_id)->>'ok')::boolean, false) THEN
      v_block := 'mobile proof: ' || (_dev_mobile_proof(p_id)->>'detail');
    END IF;

    -- CMD #2075 — FEATURE JOURNEY. The command's own browser journey must be
    -- green on medibo.in for the change that is live. Gated on
    -- worker_pool.feature_journey.enforce + effective_at (the 'enforced' flag),
    -- so a row already in flight when the rule landed is never ambushed.
    IF v_block IS NULL AND coalesce(v_row.targets_web,false) THEN
      DECLARE v_fj jsonb := _dev_feature_journey_state(p_id);
      BEGIN
        IF coalesce((v_fj->>'needed')::boolean,false) AND coalesce((v_fj->>'enforced')::boolean,false)
           AND NOT coalesce((v_fj->>'green')::boolean,false) THEN
          v_block := 'feature journey: ' || (v_fj->>'detail');
        END IF;
      END;
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL THEN
      SELECT * INTO v_selftest FROM dev_selftest_log
       WHERE ok AND at > now() - interval '6 hours'
       ORDER BY at DESC LIMIT 1;
      IF NOT FOUND THEN
        v_block := 'no green self-test on record in the last 6h — scripts/selftest.sh '
                || '(protected suite + focused test) must pass before a web deploy';
      END IF;
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL AND v_row.targets_web
       AND coalesce(v_row.preview_status,'') <> 'promoted' THEN
      v_block := 'web deploy without preview→promote (preview_status='||coalesce(v_row.preview_status,'null')||')';
    END IF;

    IF v_block IS NOT NULL THEN
      IF v_enforce THEN
        RAISE EXCEPTION 'dev_cmd_complete blocked (bug-loop gate): %', v_block;
      ELSE
        PERFORM _audit('system','bugloop_warn', p_id::text, jsonb_build_object('would_block', v_block));
      END IF;
    END IF;
  END IF;

  UPDATE dev_commands SET
    status='completed', finished_at=now(),
    title = _dev_title(title, build_log),
    result_summary = p_result,
    plain_summary = coalesce(p_plain_summary, plain_summary),
    result_actions = coalesce(p_result_actions, '[]'::jsonb),
    web_deploy_no = coalesce(p_deploy_no, web_deploy_no),
    web_deployed_at = CASE WHEN p_deploy_no IS NOT NULL THEN now() ELSE web_deployed_at END,
    screenshots = coalesce(p_screenshots, '[]'),
    wait_state = NULL, wait_kind = NULL, wait_until = NULL
  WHERE id = p_id AND status='building';
  IF NOT FOUND THEN RAISE EXCEPTION 'dev_cmd_complete: row % not in building', p_id; END IF;
  IF coalesce(p_result,'') <> '' OR coalesce(p_plain_summary,'') <> '' THEN
    INSERT INTO dev_command_messages (command_id, sender, body, images, attachments)
    VALUES (p_id, 'agent',
      coalesce(nullif(p_plain_summary,''), p_result) ||
        CASE WHEN p_deploy_no IS NOT NULL THEN E'\n\n✅ CHANGE #'||p_deploy_no||' deployed' ELSE '' END,
      '[]', '[]');
  END IF;
  PERFORM _lease_release_internal(p_id);
  RETURN jsonb_build_object('ok', true, 'rg_last', v_rg, 'bugloop_warn', v_block);
END $function$;

CREATE OR REPLACE FUNCTION public.dev_cmd_qa_detail(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; v_findings jsonb; v_runs jsonb; v_qa text; v_prev text; v_jpc int; v_req boolean;
        v_scope jsonb; v_rounds int;
begin
  perform _dev_guard();
  select qa_status, preview_status, journey_pass_count, qa_required, qa_rounds
    into v_qa, v_prev, v_jpc, v_req, v_rounds
    from dev_commands where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'not_found', true);
  end if;
  v_scope := dev_qa_scope(p_id);

  select coalesce(jsonb_agg(to_jsonb(f) order by f.ord, f.id), '[]') into v_findings from (
    select qf.id,
           coalesce(qf.severity,'info') as severity,
           case coalesce(qf.severity,'info')
             when 'critical' then 'Critical' when 'high' then 'High'
             when 'medium' then 'Medium' when 'low' then 'Low' else 'Info' end as severity_label,
           case coalesce(qf.severity,'info')
             when 'critical' then 'error' when 'high' then 'error'
             when 'medium' then 'warning' when 'low' then 'info' else 'neutral' end as severity_tone,
           case coalesce(qf.severity,'info')
             when 'critical' then 0 when 'high' then 1 when 'medium' then 2 when 'low' then 3 else 4 end as ord,
           coalesce(qf.title,'') as title,
           coalesce(qf.detail,'') as detail,
           coalesce(qf.status,'open') as status,
           case coalesce(qf.status,'open')
             when 'open' then 'Open' when 'fixed' then 'Fixed'
             when 'waived' then 'Waived' else initcap(coalesce(qf.status,'open')) end as status_label,
           case coalesce(qf.status,'open')
             when 'fixed' then 'success' when 'waived' then 'neutral' else 'error' end as status_tone,
           qf.fix_command
    from qa_findings qf where qf.command_id = p_id
  ) f;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.at desc), '[]') into v_runs from (
    select jr.id, jr.journey_id,
           coalesce(j.name, 'journey #'||jr.journey_id) as name,
           coalesce(j.area,'global') as area,
           coalesce(jr.status,'') as status,
           case coalesce(jr.status,'')
             when 'passed' then '✅ Passed' when 'failed' then '❌ Failed'
             when 'skipped' then '⏭ Skipped' when 'running' then '🔍 Running'
             else coalesce(jr.status,'') end as status_label,
           case coalesce(jr.status,'')
             when 'passed' then 'success' when 'failed' then 'error'
             when 'skipped' then 'neutral' else 'info' end as status_tone,
           coalesce(jr.evidence,'{}'::jsonb) as evidence,
           case when jr.duration_ms is null then ''
                else (round(jr.duration_ms/1000.0,1)::text||'s') end as duration_display,
           to_char((jr.at at time zone 'Asia/Kolkata'),'DD Mon, HH24:MI') as at_display,
           jr.at
    from dev_journey_runs jr
    left join dev_journeys j on j.id = jr.journey_id
    where jr.command_id = p_id
  ) r;

  v := jsonb_build_object(
    'ok', true,
    'command_id', p_id,
    'qa_status', coalesce(v_qa,'pending'),
    'qa_required', coalesce(v_req,false),
    'qa_status_label', case coalesce(v_qa,'pending')
        when 'pending' then 'QA pending' when 'running' then 'QA testing'
        when 'passed' then 'QA passed' when 'failed' then 'QA failed'
        when 'waived' then 'QA waived' else coalesce(v_qa,'pending') end,
    'qa_status_tone', case coalesce(v_qa,'pending')
        when 'passed' then 'success' when 'failed' then 'error'
        when 'running' then 'info' when 'waived' then 'neutral' else 'neutral' end,
    'can_waive', (coalesce(v_qa,'') = 'failed'),
    'scope', v_scope,
    'scope_label', coalesce(v_scope->>'label',''),
    'scope_tone', coalesce(v_scope->>'tone','neutral'),
    'scope_why', coalesce(v_scope->>'why',''),
    'rounds_label', format('%s of %s round(s) used', coalesce(v_rounds,0),
                           coalesce((v_scope->>'rounds_max')::int, 1)),
    'preview_status', coalesce(v_prev,''),
    'preview_label', case coalesce(v_prev,'')
        when 'deployed' then 'On preview' when 'promoted' then 'Promoted to production' else '' end,
    'journey_pass_count', coalesce(v_jpc,0),
    'feature_journey', _dev_feature_journey_card(p_id),
    'findings', v_findings,
    'findings_empty', c_ui('dev_queue.qa_no_findings'),
    'runs', v_runs,
    'runs_empty', c_ui('dev_queue.qa_no_runs')
  );
  return v;
end $function$;

commit;
