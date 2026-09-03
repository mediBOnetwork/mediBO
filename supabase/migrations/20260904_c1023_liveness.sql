-- CHANGE #1023 (part 2) — "disconnected but building" must be impossible.
--
-- #1016 on runner-9: the Remote Control session dropped, the checklist sat at
-- 0/5 for 32 minutes and tokens stayed flat at 44K — and the card said
-- `building` the whole time. Nothing was lying on purpose. The runner's
-- heartbeat loop is a bash subshell that OUTLIVES the Claude session it was
-- started for, so `heartbeat_at` stayed fresh while nothing was building. Every
-- existing guard reads that column:
--   · watchdog "heartbeat lost"      — 15 min, never fired (the beat was fresh)
--   · watchdog "no ETA, no tokens"   — stall_window_min * 2 = 40 min
-- A fresh heartbeat is proof the RUNNER is alive. It has never been proof the
-- AGENT is. So the beat now carries the agent's own liveness, and the sweep
-- that acts on it runs every minute.
--
-- What counts as "the agent is alive": the rc-<agent> tmux pane exists, its
-- claude process is not dead, and the pane's rendered content has changed since
-- the last beat. A live Claude session repaints its status line every second; a
-- disconnected or exited one is frozen. That signal is per-slot and cannot be
-- confused with another worker's — deliberately NOT the transcript's newest
-- assistant turn, because all nine slots share one project transcript
-- directory and `ls -t` there returns whichever slot wrote last (the same
-- cross-slot bug that made session_meta.json report worker 3's effort on
-- worker 2's card).
-- Idempotent throughout.

ALTER TABLE public.dev_commands
  ADD COLUMN IF NOT EXISTS agent_alive_at        timestamptz,
  ADD COLUMN IF NOT EXISTS agent_pane_alive      boolean,
  ADD COLUMN IF NOT EXISTS agent_rc_session      text,
  ADD COLUMN IF NOT EXISTS agent_silent_flagged  boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS agent_silent_at       timestamptz,
  ADD COLUMN IF NOT EXISTS session_lost_count    int     NOT NULL DEFAULT 0;

-- Knobs, so Om retunes with pool_set() and no deploy.
UPDATE dev_runner_config
   SET value = jsonb_set(value, '{liveness}',
         coalesce(value->'liveness','{}'::jsonb) ||
         jsonb_build_object('enabled', true, 'warn_min', 6,
                            'dead_after_min', 5, 'disconnect_grace_min', 1,
                            'max_lost', 3), true)
 WHERE key = 'worker_pool';

INSERT INTO ui_copy (key, value) VALUES
  ('dev_queue.agent_silent_chip', to_jsonb('⚠ agent silent {age} — session may be lost'::text)),
  ('dev_queue.agent_gone_chip',   to_jsonb('⚠ Remote Control session disconnected {age} ago'::text)),
  ('dev_queue.session_lost_msg',  to_jsonb('↻ Re-queued: the Claude session for this build is gone ({why}). The branch work is untouched — the next worker resumes at the first unfinished step.'::text)),
  ('dev_queue.session_lost_stop', to_jsonb('This build has lost its Claude session {n} times. Reply yes to hand it out again, or split the spec.'::text))
ON CONFLICT (key) DO NOTHING;

-- ── the heartbeat carries the proof ────────────────────────────────────────
-- Three new trailing parameters, all defaulted: an older caller (runner.sh's
-- own 60s loop) still resolves to this function and simply reports no liveness,
-- and a row that has never been given liveness is never judged on it.
DROP FUNCTION IF EXISTS public.dev_cmd_heartbeat(bigint,text,bigint,bigint,text,text,text,integer,integer,text);
CREATE OR REPLACE FUNCTION public.dev_cmd_heartbeat(
  p_id bigint, p_log_tail text DEFAULT NULL, p_tokens_in bigint DEFAULT 0,
  p_tokens_out bigint DEFAULT 0, p_model text DEFAULT NULL, p_effort text DEFAULT NULL,
  p_mode text DEFAULT NULL, p_eta_total_s integer DEFAULT NULL,
  p_eta_left_s integer DEFAULT NULL, p_eta_note text DEFAULT NULL,
  p_agent_turn_at timestamptz DEFAULT NULL, p_pane_alive boolean DEFAULT NULL,
  p_rc_session text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_cfg jsonb; v_rates jsonb; v_model text; v_mode text; v_in_usd numeric; v_out_usd numeric; v_fx numeric;
        v_budget bigint; v_extra bigint; v_tokens bigint; v_class text;
BEGIN
  PERFORM _dev_guard();
  SELECT value INTO v_cfg FROM dev_runner_config WHERE key='model_rates';
  UPDATE dev_commands SET
    heartbeat_at = now(),
    build_log = right(build_log || coalesce(E'\n'||p_log_tail,''), 200000),
    cost_input_tokens = cost_input_tokens + p_tokens_in,
    cost_output_tokens = cost_output_tokens + p_tokens_out,
    -- CHANGE #656: the REQUEST is never overwritten; the observation lands in actual_*.
    actual_model  = coalesce(CASE WHEN p_model LIKE 'claude-%' THEN p_model END, actual_model),
    actual_effort = coalesce(CASE WHEN p_effort IN ('low','medium','high','xhigh','max','extra') THEN p_effort END, actual_effort),
    price_mode = coalesce(p_mode, price_mode, 'standard'),
    eta_total_s = coalesce(p_eta_total_s, eta_total_s),
    eta_left_s = coalesce(p_eta_left_s, eta_left_s),
    eta_note = coalesce(p_eta_note, eta_note),
    -- CHANGE #1023 — liveness of the AGENT, not of the bash loop reporting it.
    agent_alive_at   = coalesce(p_agent_turn_at, agent_alive_at),
    agent_pane_alive = coalesce(p_pane_alive, agent_pane_alive),
    agent_rc_session = coalesce(nullif(p_rc_session,''), agent_rc_session),
    -- any fresh agent turn clears the amber chip immediately
    agent_silent_flagged = CASE WHEN p_agent_turn_at IS NOT NULL THEN false ELSE agent_silent_flagged END,
    agent_silent_at      = CASE WHEN p_agent_turn_at IS NOT NULL THEN NULL  ELSE agent_silent_at END
  WHERE id = p_id AND status='building';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'kill', true, 'reason','row not building'); END IF;

  SELECT coalesce(nullif(actual_model,''), model), price_mode, cost_input_tokens+cost_output_tokens, token_budget_extra, size_class
    INTO v_model, v_mode, v_tokens, v_extra, v_class FROM dev_commands WHERE id=p_id;
  v_rates := coalesce(v_cfg->'models'->v_model, v_cfg->'models'->'claude-opus-5', v_cfg->'models'->'claude-opus-4-8');
  v_fx := coalesce((v_cfg->>'usd_inr')::numeric, 88);
  IF v_mode='fast' AND v_rates ? 'fast_in' THEN v_in_usd:=(v_rates->>'fast_in')::numeric; v_out_usd:=(v_rates->>'fast_out')::numeric;
  ELSE v_in_usd:=(v_rates->>'in')::numeric; v_out_usd:=(v_rates->>'out')::numeric; END IF;
  UPDATE dev_commands SET cost_inr = round((cost_input_tokens*v_in_usd + cost_output_tokens*v_out_usd) * v_fx / 1000000.0, 2) WHERE id=p_id;

  v_budget := coalesce((SELECT (value->'token_budget_by_class'->>coalesce(v_class,'normal'))::bigint FROM dev_runner_config WHERE key='worker_pool'), 1500000)
              + coalesce(v_extra,0);
  IF v_tokens > v_budget THEN
    UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
      needs_input_question='Token budget for a '||coalesce(v_class,'normal')||' build hit ('||v_tokens||' > '||v_budget||'). Reply yes for one more window, or refine/split the spec.'
    WHERE id=p_id AND status='building';
    INSERT INTO dev_command_messages (command_id, sender, body) VALUES (p_id,'system','⛔ Auto-stopped: '||coalesce(v_class,'normal')||' token budget '||v_budget||' exceeded ('||v_tokens||').');
    PERFORM _lease_release_internal(p_id);
    PERFORM wa_send_event('sec_zombie_killed', NULL, jsonb_build_object('command_id',p_id::text,'reason','token budget ('||coalesce(v_class,'normal')||')','tokens',v_tokens::text), NULL, NULL);
    RETURN jsonb_build_object('ok', true, 'kill', true, 'reason','token_budget');
  END IF;
  RETURN jsonb_build_object('ok', true, 'model', v_model, 'mode', coalesce(v_mode,'standard'));
END $function$;

GRANT EXECUTE ON FUNCTION public.dev_cmd_heartbeat(bigint,text,bigint,bigint,text,text,text,integer,integer,text,timestamptz,boolean,text) TO service_role, authenticated;

-- ── the sweep: one minute, not forty ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_cmd_liveness_sweep()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE cfg jsonb; v_on boolean; v_warn int; v_grace int; v_maxlost int;
        r record; v_why text; v_msg text; v_q text; v_silent numeric;
        n_warn int := 0; n_lost int := 0; n_stop int := 0;
BEGIN
  -- No _dev_guard() on purpose: this rides the cron dispatcher, which carries
  -- no JWT — the same reason dev_cmd_watchdog() has none. Reachability is
  -- controlled by the GRANTs below instead.
  SELECT coalesce(value->'liveness','{}'::jsonb) INTO cfg FROM dev_runner_config WHERE key='worker_pool';
  v_on      := coalesce((cfg->>'enabled')::boolean, true);
  v_warn    := coalesce((cfg->>'warn_min')::int, 6);
  v_grace   := coalesce((cfg->>'disconnect_grace_min')::int, 1);
  v_maxlost := coalesce((cfg->>'max_lost')::int, 3);
  IF NOT v_on THEN RETURN jsonb_build_object('ok', true, 'enabled', false); END IF;

  SELECT value#>>'{}' INTO v_msg FROM ui_copy WHERE key='dev_queue.session_lost_msg';
  SELECT value#>>'{}' INTO v_q   FROM ui_copy WHERE key='dev_queue.session_lost_stop';

  FOR r IN SELECT id, agent_alive_at, agent_pane_alive, agent_rc_session,
                  agent_silent_flagged, session_lost_count, claimed_by
             FROM dev_commands
            WHERE status='building'
              AND wait_state IS DISTINCT FROM 'parked'
              -- judged only on liveness it has actually reported: a row from a
              -- runner that never sends it degrades to the old guards, never to
              -- "assume dead".
              AND agent_alive_at IS NOT NULL
  LOOP
    v_silent := extract(epoch from now() - r.agent_alive_at) / 60.0;
    v_why := NULL;

    -- ── THE ONLY THING THAT RE-QUEUES A ROW IS BEING UNREACHABLE ───────────
    -- agent_pane_alive is the runner's composite "Om can still open this":
    -- the tmux session is up, the CLI process is up, and the CLI registry
    -- holds a bridgeSessionId for the slot. Silence alone is NOT death — #692
    -- sat 4m20s at its prompt with four background shells while it waited for
    -- the merge worker, and re-queuing that would have thrown away a finished
    -- build. The grace minute is there so a momentary registry blip during
    -- active work (which keeps agent_alive_at fresh) cannot kill a live build.
    IF r.agent_pane_alive IS FALSE AND v_silent >= v_grace THEN
      v_why := 'the Remote Control session is not reachable and the agent has been quiet for '
               || _fmt_dur(v_silent * 60);
    END IF;

    IF v_why IS NULL THEN
      -- Amber, not action. Raised immediately while unreachable (even inside
      -- the grace minute), and after warn_min of silence while still connected.
      IF r.agent_pane_alive IS FALSE OR v_silent >= v_warn THEN
        IF NOT coalesce(r.agent_silent_flagged,false) THEN
          UPDATE dev_commands SET agent_silent_flagged=true,
                 agent_silent_at=coalesce(agent_silent_at, r.agent_alive_at) WHERE id=r.id;
          n_warn := n_warn + 1;
        END IF;
      ELSIF coalesce(r.agent_silent_flagged,false) THEN
        UPDATE dev_commands SET agent_silent_flagged=false, agent_silent_at=NULL WHERE id=r.id;
      END IF;
      CONTINUE;
    END IF;

    IF coalesce(r.session_lost_count,0) + 1 >= v_maxlost THEN
      UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
             session_lost_count = coalesce(session_lost_count,0)+1,
             agent_silent_flagged=false, agent_silent_at=NULL,
             needs_input_question = replace(coalesce(v_q,'This build has lost its Claude session {n} times. Reply yes to hand it out again, or split the spec.'),
                                            '{n}', (coalesce(r.session_lost_count,0)+1)::text)
       WHERE id=r.id AND status='building';
      n_stop := n_stop + 1;
    ELSE
      -- STATUS ONLY. Nothing here touches model, effort or the branch: the work
      -- on disk is exactly where the next worker resumes from.
      UPDATE dev_commands SET status='pending', claimed_by=NULL,
             session_lost_count = coalesce(session_lost_count,0)+1,
             agent_silent_flagged=false, agent_silent_at=NULL,
             agent_pane_alive=false,
             error_log = coalesce(error_log||E'\n---\n','')||'LIVENESS: '||v_why||' — re-queued'
       WHERE id=r.id AND status='building';
      n_lost := n_lost + 1;
    END IF;

    INSERT INTO dev_command_messages (command_id, sender, body)
    VALUES (r.id, 'system', replace(coalesce(v_msg,'↻ Re-queued: the Claude session for this build is gone ({why}).'), '{why}', v_why));
    PERFORM _lease_release_internal(r.id);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'warned', n_warn, 'requeued', n_lost,
                            'stopped', n_stop, 'warn_min', v_warn,
                            'disconnect_grace_min', v_grace);
END $function$;

REVOKE ALL ON FUNCTION public.dev_cmd_liveness_sweep() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.dev_cmd_liveness_sweep() TO service_role;

-- Every 60s, and it must NOT back off: the whole point is a 5-minute ceiling.
INSERT INTO cron_task (name, ord, mode, work_sql, base_interval_s, max_interval_s,
                       step_timeout_ms, enabled, note)
VALUES ('dev-agent-liveness', 46, 'poll', 'select public.dev_cmd_liveness_sweep()',
        60, 60, 15000, true,
        'CHANGE #1023 — re-queues a building row whose Claude session died, within 5 min instead of 40.')
ON CONFLICT (name) DO UPDATE
  SET work_sql = excluded.work_sql, base_interval_s = 60, max_interval_s = 60,
      enabled = true, note = excluded.note;

-- ── the card says it before the sweep acts ────────────────────────────────
DROP FUNCTION IF EXISTS public.dev_cmd_agent_chip(text, boolean, timestamptz);
CREATE OR REPLACE FUNCTION public.dev_cmd_agent_chip(p_status text, p_flagged boolean, p_since timestamptz, p_reachable boolean DEFAULT NULL)
 RETURNS text LANGUAGE sql STABLE AS $function$
  -- Two sentences, because they mean different things to Om: "silent" is a
  -- session he can still open, "disconnected" is one he cannot.
  SELECT CASE WHEN p_status='building' AND coalesce(p_flagged,false) AND p_since IS NOT NULL
              THEN replace(
                     CASE WHEN p_reachable IS FALSE
                          THEN _c_or('dev_queue.agent_gone_chip','⚠ Remote Control session disconnected {age} ago')
                          ELSE _c_or('dev_queue.agent_silent_chip','⚠ agent silent {age} — session may be lost') END,
                     '{age}', _fmt_dur(coalesce(extract(epoch from now()-p_since), 0)))
              ELSE '' END;
$function$;

CREATE OR REPLACE FUNCTION public._dev_card_keys()
 RETURNS text[] LANGUAGE sql IMMUTABLE AS $function$
  select array[
    'id','title','status','kind','area','area_label','batch_label','priority',
    'urgent','is_danger','effort','route','route_label','route_tone',
    'claimed_by','model','model_chip','model_label','effort_label','retry_count',
    'created_at','started_at','finished_at','heartbeat_at','eta_at',
    'age_display','elapsed_display','remaining_display','tat_display',
    'ttt_display','speed_display','tokens_display','cost_display','cost_note',
    'has_eta','has_tokens','is_live','is_waiting','is_overrun','msg_count',
    'steps_done','steps_total','steps_chip','steps_stale_chip','steps_stale_hint',
    'spec_chip','spec_tone','spec_open','spec_total',
    'qa_chip','qa_tone','qa_status','qa_required','qa_open_findings',
    'journey_chip','preview_chip','preview_tone','preview_status',
    'chain_chip','chain_tone','finish_chip','finish_tone',
    'wait_chip','wait_tone','wait_kind','wait_reason','wait_hint','wait_state',
    'live_chip','stall_chip','resume_chip','debug_status','debug_requested',
    'auto_finished','auto_finish_source','rolled_back',
    -- CHANGE #1023 — agent liveness, next to the worker liveness it is not
    'agent_chip','agent_tone','agent_rc_session','session_lost_count','started_flags',
    'web_deploy_no','android_status','ios_status',
    'targets_web','targets_android','targets_ios'
  ]::text[];
$function$;

-- ── the card payload gains the agent chip ─────────────────────────────────
CREATE OR REPLACE FUNCTION public._dev_cmd_rows(p_status text, p_search text, p_batch text, p_limit integer, p_slim boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rows jsonb; v_tat numeric; v_stale numeric;
  v_models jsonb; v_efforts jsonb;
  t_steps text; t_live text; t_stall text; t_resume text; t_ssteps text; t_shint text;
  t_fready text; t_fauto text; t_wait text; t_whint text; t_spec text;
begin
  v_tat := _dev_cmd_base_tat();
  -- one config read for the whole page, not four or five per row
  v_models  := _dev_label_map('models');
  v_efforts := _dev_label_map('efforts');
  select coalesce((value->>'eta_stale_s')::numeric, 180) into v_stale
    from dev_runner_config where key='worker_pool';
  v_stale := coalesce(v_stale, 180);
  select value#>>'{}' into t_steps  from ui_copy where key='dev_queue.steps_chip';
  select value#>>'{}' into t_live   from ui_copy where key='dev_queue.live_stale';
  select value#>>'{}' into t_stall  from ui_copy where key='dev_queue.stall_chip';
  select value#>>'{}' into t_resume from ui_copy where key='dev_queue.resume_chip';
  select value#>>'{}' into t_ssteps from ui_copy where key='dev_queue.steps_stale_chip';
  select value#>>'{}' into t_shint  from ui_copy where key='dev_queue.steps_stale_hint';
  t_fready := _c_or('dev_queue.finish_ready_chip', '✅ All conditions met — closing automatically');
  t_fauto  := _c_or('dev_queue.finish_auto_chip',  '🤖 Auto-completed by the harness · {drift} after the last step');
  t_wait   := _c_or('dev_queue.wait_chip',  '⏸ {reason} · waiting {age}');
  t_whint  := _c_or('dev_queue.wait_hint',  'Not a failure — the work is committed and resumes automatically when the blocker clears.');
  t_spec   := _c_or('dev_queue.spec_chip',  'Spec {done}/{total}');

  with pick as (
    -- THE CEILING. One index-ordered walk, p_limit rows, nothing else touched.
    select dc.id
      from dev_commands dc
     where (p_status is null or dc.status = p_status)
       and (p_batch  is null or dc.batch_label = p_batch)
       and (p_search is null
            or dc.title ilike '%'||p_search||'%'
            or dc.spec  ilike '%'||p_search||'%'
            or coalesce(dc.result_summary,'') ilike '%'||p_search||'%')
     order by dc.created_at desc, dc.id desc
     limit greatest(coalesce(p_limit, 120), 1)
  ),
  spec_agg as (
    select si.command_id,
           count(*)::int                                     as total,
           count(*) filter (where si.status = 'open')::int    as open_n
      from dev_command_spec_item si
      join pick p on p.id = si.command_id
     group by si.command_id
  ),
  qa_agg as (
    select qf.command_id,
           count(*) filter (where qf.status = 'open')::int    as open_n
      from qa_findings qf
      join pick p on p.id = qf.command_id
     group by qf.command_id
  ),
  msg_agg as (
    select m.command_id, count(*)::int as n
      from dev_command_messages m
      join pick p on p.id = m.command_id
     group by m.command_id
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id desc), '[]')
    into v_rows
  from (
    select dc.id,
           -- #887: materialised on write. Was a regexp over the whole build_log.
           coalesce(dc.title_display, dc.title) as title,
           dc.status, dc.priority, dc.urgent, dc.depends_on, dc.batch_label,
           dc.route, dc.area,
           _route_label(dc.route) as route_label, _route_tone(dc.route) as route_tone,
           _area_label(dc.area) as area_label,
           (dc.enriched_spec is not null and length(coalesce(dc.enriched_spec,'')) > 0) as has_enriched,
           case when dc.route='fast' and dc.status='completed' then 'Instant · 0 tokens' else '' end as speed_display,
           coalesce(dc.kind,'dev') as kind, coalesce(dc.is_danger,false) as is_danger,
           case when p_slim then left(coalesce(dc.plain_summary,''), 200)
                else coalesce(dc.plain_summary,'') end as plain_summary,
           dc.targets_web, dc.targets_android, dc.targets_ios,
           dc.web_deploy_no, dc.web_deployed_at, dc.android_status, dc.android_artifact_url,
           dc.android_built_at, dc.ios_status,
           dc.android_build_type, dc.debug_requested, dc.debug_status,
           -- #887: the cards view drops every one of these in _dev_card_strip,
           -- so the slim build never reads them off disk in the first place.
           case when p_slim then null::text  else dc.result_summary end as result_summary,
           case when p_slim then null::jsonb else dc.decisions      end as decisions,
           case when p_slim then null::jsonb else dc.screenshots    end as screenshots,
           case when p_slim then null::text  else dc.error_log      end as error_log,
           dc.retry_count,
           dc.cost_input_tokens, dc.cost_output_tokens, dc.cost_inr, dc.claimed_by, dc.heartbeat_at,
           coalesce(dc.model,'') as model, coalesce(dc.effort,'') as effort,
           coalesce(dc.price_mode,'') as price_mode,
           _dev_model_chip_m(v_models, v_efforts, dc.model, dc.effort, dc.price_mode,
                             dc.actual_model, dc.actual_effort) as model_chip,
           coalesce(dc.actual_model,'') as actual_model,
           coalesce(dc.actual_effort,'') as actual_effort,
           _dev_model_label_m(v_models, dc.model)   as model_label,
           _dev_effort_label_m(v_efforts, dc.effort) as effort_label,
           case when (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0)
                then ('₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990')) || ' — API-equivalent (included in your Max plan · ₹0 extra)'
                else '' end as cost_note,
           (dc.cost_input_tokens + dc.cost_output_tokens) as tokens_total,
           _fmt_tokens(dc.cost_input_tokens + dc.cost_output_tokens) as tokens_display,
           '₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990') as cost_display,
           (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0) as has_tokens,
           _ist_age(coalesce(dc.finished_at, dc.started_at, dc.created_at)) as age_display,
           dc.needs_input_question, dc.rolled_back, dc.created_at, dc.started_at, dc.finished_at,
           case when p_slim then null::text else left(dc.build_log, 4000) end as build_log_tail,
           tm.tat_seconds, tm.tat_display, tm.eta_at, tm.elapsed_seconds, tm.elapsed_display,
           tm.remaining_seconds, tm.remaining_display, tm.is_overrun, tm.has_eta, tm.eta_note,
           dc.eta_total_s, dc.eta_left_s,
           case when dc.status in ('completed','failed') then tm.ttt_display else '' end as ttt_display,
           case when p_slim then null::jsonb else coalesce(dc.steps, '[]'::jsonb) end as steps,
           dc.steps_done, dc.steps_total, dc.resume_count,
           coalesce(dc.resume_branch,'') as resume_branch,
           coalesce(dc.release_reason,'') as release_reason,
           case when coalesce(dc.steps_total,0) > 0
                then replace(replace(coalesce(t_steps,'Step {done} of {total}'),
                       '{done}', coalesce(dc.steps_done,0)::text), '{total}', dc.steps_total::text)
                else '' end as steps_chip,
           (dc.status='building' and dc.heartbeat_at is not null
              and dc.heartbeat_at > now() - (v_stale || ' seconds')::interval) as is_live,
           case when dc.status='building'
                 and (dc.heartbeat_at is null
                      or dc.heartbeat_at <= now() - (v_stale || ' seconds')::interval)
                then replace(coalesce(t_live,'Worker offline — no heartbeat for {age}'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.heartbeat_at), 0)))
                else '' end as live_chip,
           -- ── CHANGE #1023 — the AGENT's liveness, not the runner's ──────────
           -- live_chip above says the heartbeat stopped. This says the beat is
           -- fine and the Claude session behind it is not — the exact state
           -- #1016 sat in for 32 minutes with nothing on the card to show it.
           dev_cmd_agent_chip(dc.status, dc.agent_silent_flagged, dc.agent_silent_at, dc.agent_pane_alive) as agent_chip,
           case when dc.status='building' and coalesce(dc.agent_silent_flagged,false)
                then case when dc.agent_pane_alive is false then 'error' else 'warning' end
                else 'neutral' end as agent_tone,
           coalesce(dc.agent_rc_session,'') as agent_rc_session,
           coalesce(dc.session_lost_count,0) as session_lost_count,
           coalesce(dc.started_flags,'') as started_flags,
           case when dc.status='building' and coalesce(dc.token_stall_flagged,false)
                then replace(coalesce(t_stall,'Tokens frozen {age} — build may be stuck'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.token_stall_at), 0)))
                else '' end as stall_chip,
           case when dc.status='building' and coalesce(dc.steps_stale_flagged,false)
                then replace(coalesce(t_ssteps,'Steps not being reported — checklist may be stale ({age})'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.steps_stale_at), 0)))
                else '' end as steps_stale_chip,
           case when dc.status='building' and coalesce(dc.steps_stale_flagged,false)
                then coalesce(t_shint,'') else '' end as steps_stale_hint,
           coalesce(dc.steps_auto_count,0) as steps_auto_count,
           coalesce(dc.steps_nudge_count,0) as steps_nudge_count,
           case when coalesce(dc.resume_count,0) > 0
                then replace(coalesce(t_resume,'Resumed {n}×'), '{n}', dc.resume_count::text)
                else '' end as resume_chip,
           -- ── CHANGE #571: WAITING IS NOT FAILING, and the card says which ──
           coalesce(dc.wait_state,'')  as wait_state,
           coalesce(dc.wait_kind,'')   as wait_kind,
           coalesce(dc.wait_reason,'') as wait_reason,
           case when p_slim then null::jsonb
                else coalesce(dc.wait_blocker,'{}'::jsonb) end as wait_blocker,
           dc.wait_since, coalesce(dc.wait_count,0) as wait_count,
           (dc.wait_state = 'parked') as is_waiting,
           case when dc.wait_state = 'parked'
                then replace(replace(t_wait, '{reason}', coalesce(dc.wait_reason,'')),
                       '{age}', _fmt_dur(coalesce(extract(epoch from now()-dc.wait_since), 0)))
                else '' end as wait_chip,
           case when dc.wait_state = 'parked' then 'warning' else 'neutral' end as wait_tone,
           case when dc.wait_state = 'parked' then t_whint else '' end as wait_hint,
           -- ── CHANGE #571 spec checklist — #887: set-based, was 8 subqueries ──
           coalesce(sa.total, 0)  as spec_total,
           coalesce(sa.open_n, 0) as spec_open,
           case when coalesce(sa.total,0) = 0 then ''
                else replace(replace(t_spec,
                       '{done}', (coalesce(sa.total,0) - coalesce(sa.open_n,0))::text),
                       '{total}', coalesce(sa.total,0)::text) end as spec_chip,
           case when dc.status = 'building' and coalesce(sa.open_n,0) > 0 then 'warning'
                when coalesce(sa.total,0) > 0 and coalesce(sa.open_n,0) = 0 then 'success'
                else 'neutral' end as spec_tone,
           -- ── CHANGE #369: the finish gate, on the card ────────────────────
           case when dc.status='completed' and coalesce(dc.auto_finished,false)
                then replace(t_fauto, '{drift}',
                       _fmt_dur(greatest(coalesce(extract(epoch from dc.finished_at - dc.steps_snap_at), 0), 0)))
                when dc.status='building' and dc.finish_ready_at is not null then t_fready
                else '' end as finish_chip,
           case when dc.status='completed' and dc.steps_snap_at is not null
                then round(extract(epoch from dc.finished_at - dc.steps_snap_at))::int
                else null end as finish_drift_s,
           case when dc.status='completed' and dc.steps_snap_tokens is not null
                then greatest((dc.cost_input_tokens + dc.cost_output_tokens) - dc.steps_snap_tokens, 0)
                else null end as finish_tokens_after,
           case when dc.status='completed' and coalesce(dc.auto_finished,false) then 'success'
                when dc.status='building' and dc.finish_ready_at is not null then 'info'
                else 'neutral' end as finish_tone,
           coalesce(dc.auto_finished,false) as auto_finished,
           coalesce(dc.auto_finish_source,'') as auto_finish_source,
           case when p_slim then null::jsonb
                else coalesce(dc.finish_blockers,'[]'::jsonb) end as finish_blockers,
           dc.finish_ready_at,
           dc.qa_status, dc.qa_required, dc.preview_status, dc.journey_pass_count,
           coalesce(qa.open_n, 0) as qa_open_findings,
           case when not dc.qa_required or dc.qa_status='waived' then ''
                when dc.qa_status='pending' then ''
                when dc.qa_status='running' then '🔍 QA testing'
                when dc.qa_status='passed' then '✅ QA passed'
                when dc.qa_status='failed' then '❌ QA: '||coalesce(qa.open_n,0)||' finding(s)'
                else '' end as qa_chip,
           case when dc.qa_status='waived' then 'neutral'
                when dc.qa_status='running' then 'info'
                when dc.qa_status='passed' then 'success'
                when dc.qa_status='failed' then 'error' else 'neutral' end as qa_tone,
           case coalesce(dc.preview_status,'')
                when 'deployed' then '🔎 On preview'
                when 'promoted' then '🚀 Promoted' else '' end as preview_chip,
           case coalesce(dc.preview_status,'')
                when 'deployed' then 'info' when 'promoted' then 'success' else 'neutral' end as preview_tone,
           _dev_chain_chip(dc.status, dc.chain_reason) as chain_chip,
           'info'::text as chain_tone,
           case when p_slim then null::text[] else coalesce(dc.predicted_files,'{}') end as predicted_files,
           case when dc.journey_pass_count > 0
                then '🧭 '||dc.journey_pass_count||' journey'||case when dc.journey_pass_count=1 then '' else 's' end||' green'
                else '' end as journey_chip,
           coalesce(ma.n, 0) as msg_count
      from pick pk
      join dev_commands dc on dc.id = pk.id
      left join spec_agg sa on sa.command_id = dc.id
      left join qa_agg   qa on qa.command_id = dc.id
      left join msg_agg  ma on ma.command_id = dc.id,
      lateral _dev_cmd_timing(dc.started_at, dc.finished_at, dc.status, v_tat,
                              dc.eta_total_s, dc.eta_left_s, dc.heartbeat_at, dc.eta_note) tm
  ) t;

  return coalesce(v_rows, '[]'::jsonb);
end
$function$;
