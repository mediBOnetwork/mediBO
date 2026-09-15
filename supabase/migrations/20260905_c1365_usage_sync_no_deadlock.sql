-- CHANGE #1365 — Usage sync can never deadlock the runner.
--
-- Root cause (5 Sep 2026): claude_usage is written ONLY by the VM fetcher
-- (dev_set_usage). The VM idled 4 Sep 16:29 UTC; after boot push_usage.sh
-- printed "no token" and exited 0 — silently — because the on-disk OAuth
-- token is refreshed by a Claude Code SESSION, and no session existed. The
-- weekly 100% from before the window reset stayed on the card, the supervisor
-- read it, shrank the pool to one, nothing claimed, no session started, so the
-- token was never refreshed and the fetch never ran. A closed loop.
--
-- dev_usage_effective() already breaks half of it (an expired window counts as
-- 0%, a snapshot older than worker_pool.usage_stale_ignore_s is "unknown").
-- This migration closes the rest:
--   1. dev_usage_fetch_failed(reason) — every failed fetch is RECORDED, so the
--      card can say "sync failing: no oauth token on disk" instead of the
--      silent lie "synced 15h ago".
--   2. dev_set_usage() clears that error on the first success.
--   3. dev_usage_effective() carries the fetch_error block.
--   4. dev_cmd_session_usage() surfaces it, and — max-backend — makes the POOL
--      DECISION itself (quota_shrink) instead of the supervisor re-deriving it
--      from limit labels in jq, which silently broke twice (#656).
--   5. dev_usage_poll_state() hands the fetcher its own cadence
--      (worker_pool.usage_fetch_min, default 10) so the interval is config,
--      not a number baked into a shell script.

-- ── 1. record a failed fetch ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_usage_fetch_failed(
  p_reason text, p_detail jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_prev jsonb; v_n int; v_reason text;
BEGIN
  PERFORM _dev_guard();
  v_reason := left(coalesce(nullif(btrim(p_reason),''), 'unknown error'), 200);
  SELECT value INTO v_prev FROM dev_runner_config WHERE key='usage_fetch_error';
  v_n := CASE WHEN v_prev IS NULL OR coalesce(v_prev->>'reason','') <> v_reason
              THEN 1 ELSE coalesce((v_prev->>'count')::int,0) + 1 END;
  INSERT INTO dev_runner_config(key, value)
  VALUES ('usage_fetch_error', jsonb_build_object(
            'reason', v_reason,
            'detail', p_detail,
            'at', to_jsonb(now()),
            'first_at', coalesce(v_prev->'first_at', to_jsonb(now())),
            'count', v_n))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  RETURN jsonb_build_object('ok', true, 'reason', v_reason, 'count', v_n);
END $$;
GRANT EXECUTE ON FUNCTION public.dev_usage_fetch_failed(text, jsonb) TO anon, authenticated, service_role;

-- ── 2. a success clears the error ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_set_usage(p_usage jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  PERFORM _dev_guard();
  IF p_usage IS NULL
     OR jsonb_typeof(p_usage->'limits') <> 'array'
     OR jsonb_array_length(p_usage->'limits') = 0 THEN
    -- Reject empties: keep the last good value untouched.
    RETURN jsonb_build_object('ok', false, 'reason', 'empty_limits_ignored');
  END IF;
  INSERT INTO dev_runner_config(key, value)
  VALUES ('claude_usage', jsonb_set(p_usage, '{fetched_at}', to_jsonb(now())))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  -- CHANGE #1365: a good fetch retires the failure banner in the same call, so
  -- the card can never keep saying "sync failing" once sync is working again.
  DELETE FROM dev_runner_config WHERE key='usage_fetch_error';
  RETURN jsonb_build_object('ok', true);
END $$;

-- ── 3. effective usage carries the failure ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_usage_effective()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb; v_fetched timestamptz; v_lim jsonb; v_out jsonb := '[]';
        v_pct numeric; v_reset timestamptz; v_exp boolean; v_max numeric := 0;
        v_wk numeric := 0; v_sess numeric := 0; v_grp text;
        v_age numeric; v_ignore_s numeric; v_unknown boolean;
        v_err jsonb; v_err_at timestamptz; v_err_active boolean := false;
BEGIN
  SELECT value INTO v_err FROM dev_runner_config WHERE key='usage_fetch_error';
  v_err_at := CASE WHEN v_err IS NULL THEN NULL ELSE (v_err->>'at')::timestamptz END;

  SELECT value INTO v FROM dev_runner_config WHERE key='claude_usage';
  v_fetched := CASE WHEN v IS NULL THEN NULL ELSE (v->>'fetched_at')::timestamptz END;
  -- The banner is live while the newest thing that happened to the fetcher is a
  -- FAILURE. A later success writes fetched_at and deletes the row anyway, so
  -- this comparison is belt-and-braces for an out-of-order write.
  v_err_active := (v_err_at IS NOT NULL AND (v_fetched IS NULL OR v_err_at > v_fetched));

  IF v IS NULL THEN
    RETURN jsonb_build_object('has_usage', false, 'unknown', true, 'limits', '[]'::jsonb,
                              'effective_max_pct', 0, 'weekly_pct', 0, 'session_pct', 0,
                              'age_s', NULL, 'stale_ignored', false,
                              'fetch_error', v_err, 'fetch_failing', v_err_active);
  END IF;
  v_age := CASE WHEN v_fetched IS NULL THEN NULL ELSE extract(epoch FROM now()-v_fetched) END;
  SELECT coalesce((value->>'usage_stale_ignore_s')::numeric, 21600) INTO v_ignore_s
    FROM dev_runner_config WHERE key='worker_pool';
  v_ignore_s := coalesce(v_ignore_s, 21600);
  v_unknown := (v_age IS NULL OR v_age > v_ignore_s);

  FOR v_lim IN SELECT * FROM jsonb_array_elements(coalesce(v->'limits','[]'::jsonb)) LOOP
    v_pct := coalesce((v_lim->>'percent')::numeric, 0);
    BEGIN v_reset := (v_lim->>'resets_at')::timestamptz; EXCEPTION WHEN others THEN v_reset := NULL; END;
    v_exp := (v_reset IS NOT NULL AND v_reset <= now());
    IF v_exp THEN
      v_lim := v_lim || jsonb_build_object('percent', 0, 'severity', 'normal', 'is_active', false,
                                           'expired', true, 'raw_percent', v_pct);
      v_pct := 0;
    ELSE
      v_lim := v_lim || jsonb_build_object('expired', false, 'raw_percent', v_pct);
    END IF;
    IF v_unknown THEN
      v_lim := v_lim || jsonb_build_object('percent', 0, 'severity', 'normal', 'is_active', false,
                                           'stale_ignored', true);
      v_pct := 0;
    END IF;
    -- CHANGE #1365: the weekly / 5h split is decided HERE, on `kind`/`group`
    -- straight off Anthropic's payload. The supervisor used to re-derive it in
    -- jq from the rendered `label`, which no limit carried — the peaks read 0
    -- for weeks and the quota guard could never fire (#656).
    v_grp := lower(coalesce(v_lim->>'group','') || ' ' || coalesce(v_lim->>'kind',''));
    IF v_grp LIKE '%weekly%' THEN v_wk := greatest(v_wk, v_pct); END IF;
    IF v_grp LIKE '%session%' OR v_grp LIKE '%5h%' THEN v_sess := greatest(v_sess, v_pct); END IF;
    v_max := greatest(v_max, v_pct);
    v_out := v_out || v_lim;
  END LOOP;

  RETURN v || jsonb_build_object(
    'has_usage', jsonb_array_length(v_out) > 0,
    'limits', v_out,
    'effective_max_pct', round(v_max),
    'weekly_pct', round(v_wk),
    'session_pct', round(v_sess),
    'age_s', CASE WHEN v_age IS NULL THEN NULL ELSE round(v_age) END,
    'unknown', v_unknown,
    'stale_ignored', v_unknown,
    'stale_ignore_s', v_ignore_s,
    'fetch_error', v_err,
    'fetch_failing', v_err_active);
END $$;

-- ── 4. the card + the pool decision ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_cmd_session_usage()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE
  v jsonb; v_fetched timestamptz; v_lim jsonb; v_out jsonb := '[]';
  v_secs numeric; v_reset text; v_pct numeric; v_sev text; v_tone text; v_label text; v_kind text;
  w_in numeric; w_out numeric; w_inr numeric; t_in numeric; t_out numeric; t_inr numeric; t_cmds int;
  v_since timestamptz; v_age numeric; v_utone text; v_stale boolean; v_exp boolean; v_ign boolean;
  v_unknown boolean; v_wk numeric; v_sess numeric; v_qpct numeric;
  v_failing boolean; v_err_reason text; v_updated text;
  v_shrink boolean := false; v_shrink_at numeric; v_sess_at numeric; v_billing text;
BEGIN
  PERFORM _dev_guard();
  v := public.dev_usage_effective();
  v_fetched := (v->>'fetched_at')::timestamptz;
  v_unknown := coalesce((v->>'unknown')::boolean, false);
  v_wk      := coalesce((v->>'weekly_pct')::numeric, 0);
  v_sess    := coalesce((v->>'session_pct')::numeric, 0);
  v_qpct    := coalesce((v->>'effective_max_pct')::numeric, 0);
  v_failing := coalesce((v->>'fetch_failing')::boolean, false);
  v_err_reason := v#>>'{fetch_error,reason}';

  FOR v_lim IN SELECT * FROM jsonb_array_elements(coalesce(v->'limits','[]'::jsonb)) LOOP
    v_kind := v_lim->>'kind';
    v_pct := coalesce((v_lim->>'percent')::numeric, 0);
    v_sev := coalesce(v_lim->>'severity','normal');
    v_exp := coalesce((v_lim->>'expired')::boolean, false);
    v_ign := coalesce((v_lim->>'stale_ignored')::boolean, false);
    v_tone := CASE WHEN v_pct >= 90 OR v_sev='critical' OR v_sev='exceeded' THEN 'failed'
                   WHEN v_pct >= 70 OR v_sev='warning' THEN 'awaiting_approval'
                   ELSE 'completed' END;
    v_label := CASE v_kind
                 WHEN 'session' THEN 'Current session · 5h'
                 WHEN 'weekly_all' THEN 'Weekly · all models'
                 WHEN 'weekly_scoped' THEN 'Weekly · ' || coalesce(v_lim#>>'{scope,model,display_name}','scoped')
                 ELSE initcap(replace(v_kind,'_',' ')) END;
    IF v_exp THEN
      v_reset := 'window reset — counted as 0% until the next sync';
    ELSIF v_ign THEN
      v_reset := 'sync too old — not used for pool decisions';
    ELSIF (v_lim->>'resets_at') IS NOT NULL THEN
      v_secs := extract(epoch FROM (v_lim->>'resets_at')::timestamptz - now());
      IF v_secs < 3600 THEN v_reset := 'Resets in ' || greatest((v_secs/60)::int,1) || 'm';
      ELSIF v_secs < 86400 THEN v_reset := 'Resets in ' || (v_secs/3600)::int || 'h ' || ((v_secs::int%3600)/60) || 'm';
      ELSE v_reset := 'Resets ' || to_char((v_lim->>'resets_at')::timestamptz AT TIME ZONE 'Asia/Kolkata','Dy DD Mon');
      END IF;
    ELSE v_reset := ''; END IF;
    v_out := v_out || jsonb_build_object(
      'label', v_label, 'percent', round(v_pct), 'pct_display', round(v_pct)::text || '%',
      'tone', v_tone, 'resets_display', v_reset,
      'active', coalesce((v_lim->>'is_active')::boolean,false),
      'expired', v_exp, 'stale_ignored', v_ign,
      'raw_percent', coalesce((v_lim->>'raw_percent')::numeric, v_pct));
  END LOOP;

  v_since := now() - interval '5 hours';
  SELECT coalesce(sum(cost_input_tokens),0), coalesce(sum(cost_output_tokens),0), coalesce(sum(cost_inr),0)
    INTO w_in, w_out, w_inr FROM dev_commands
   WHERE coalesce(finished_at,heartbeat_at,started_at) >= v_since AND (cost_input_tokens>0 OR cost_output_tokens>0);
  SELECT coalesce(sum(cost_input_tokens),0), coalesce(sum(cost_output_tokens),0), coalesce(sum(cost_inr),0), count(*)
    INTO t_in, t_out, t_inr, t_cmds FROM dev_commands
   WHERE (coalesce(finished_at,heartbeat_at,started_at) AT TIME ZONE 'Asia/Kolkata')::date = (now() AT TIME ZONE 'Asia/Kolkata')::date
     AND (cost_input_tokens>0 OR cost_output_tokens>0);

  v_age := CASE WHEN v_fetched IS NULL THEN NULL ELSE extract(epoch FROM now()-v_fetched) END;
  v_stale := (v_fetched IS NULL OR v_age > 240);

  -- CHANGE #1365: a fetcher that is FAILING says so. "synced 15h ago" while
  -- every fetch since boot has died is the lie that hid this bug for a day.
  IF v_failing THEN
    v_updated := 'sync failing: ' || coalesce(v_err_reason, 'unknown error');
    v_utone   := 'failed';
    v_stale   := true;
  ELSE
    v_updated := CASE WHEN v_fetched IS NULL THEN 'not synced yet'
                      ELSE 'synced ' || _ist_age(v_fetched) END;
    v_utone := CASE WHEN v_fetched IS NULL THEN 'failed'
                    WHEN v_age < 90 THEN 'completed'
                    WHEN v_age < 240 THEN 'awaiting_approval'
                    ELSE 'failed' END;
  END IF;

  -- CHANGE #1365: the POOL DECISION lives here, not in supervisor jq. An
  -- unknown reading (never fetched, or older than usage_stale_ignore_s) and an
  -- expired window both count as 0% and can NEVER shrink the pool — that is
  -- exactly the state a cold-booted VM is in, and shrinking there is what
  -- deadlocked the queue.
  SELECT coalesce((value->>'quota_shrink_pct')::numeric, 85),
         coalesce((value->>'quota_shrink_session_pct')::numeric, 90),
         coalesce(value->>'billing_mode', 'max_subscription')
    INTO v_shrink_at, v_sess_at, v_billing
    FROM dev_runner_config WHERE key='worker_pool';
  v_shrink_at := coalesce(v_shrink_at, 85);
  v_sess_at   := coalesce(v_sess_at, 90);
  v_billing   := coalesce(v_billing, 'max_subscription');
  IF NOT v_unknown AND v_billing = 'max_subscription'
     AND (v_wk >= v_shrink_at OR v_sess >= v_sess_at) THEN
    v_shrink := true;
  END IF;

  RETURN jsonb_build_object(
    'has_usage', coalesce((v->>'has_usage')::boolean, false),
    'limits', v_out,
    'quota_pct', v_qpct,
    'quota_unknown', v_unknown,
    'quota_weekly_pct', v_wk,
    'quota_session_pct', v_sess,
    'quota_shrink', v_shrink,
    'quota_shrink_display', CASE
      WHEN v_unknown THEN 'usage unknown — parallel building stays on'
      WHEN v_shrink THEN 'parallel paused: usage ' || round(v_qpct)::text || '%'
      ELSE '' END,
    'fetch_failing', v_failing,
    'fetch_error_reason', v_err_reason,
    'updated_display', v_updated,
    'updated_tone', v_utone,
    'stale', v_stale,
    'spend_display', _fmt_tokens(w_in+w_out) || ' · ₹' || to_char(round(w_inr),'FM9,99,99,990') || ' (5h)',
    'today_display', 'Today: ' || _fmt_tokens(t_in+t_out) || ' · ₹' || to_char(round(t_inr),'FM9,99,99,990') || ' · ' || t_cmds || ' cmds'
  );
END $$;

-- ── 5. the fetcher gets its cadence from config ─────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_usage_poll_state()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_fetch timestamptz; v_req timestamptz; v_min numeric; v_err jsonb; v_wf text;
BEGIN
  PERFORM _dev_guard();
  SELECT (value->>'fetched_at')::timestamptz INTO v_fetch FROM dev_runner_config WHERE key='claude_usage';
  SELECT (value->>'at')::timestamptz INTO v_req FROM dev_runner_config WHERE key='usage_refresh_req';
  SELECT coalesce((value->>'usage_fetch_min')::numeric, 10) INTO v_min
    FROM dev_runner_config WHERE key='worker_pool';
  v_min := coalesce(v_min, 10);
  SELECT value INTO v_err FROM dev_runner_config WHERE key='usage_fetch_error';
  SELECT coalesce(value->>'workflow','off') INTO v_wf FROM dev_runner_config WHERE key='desired_state';
  RETURN jsonb_build_object(
    'now', now(),
    'fetched_at', v_fetch,
    'requested_at', v_req,
    'fetched_age_secs', CASE WHEN v_fetch IS NULL THEN NULL ELSE round(extract(epoch FROM now()-v_fetch)) END,
    'pending', (v_req IS NOT NULL AND (v_fetch IS NULL OR v_req > v_fetch)),
    -- CHANGE #1365: cadence is CONFIG. worker_pool.usage_fetch_min (minutes)
    -- is the floor between background fetches; the fetcher must not bake it in.
    'fetch_min', v_min,
    'fetch_interval_s', round(v_min * 60),
    -- The background cadence runs only while the workflow switch is on; an
    -- explicit refresh request (a tap on the card) always fetches.
    'workflow', coalesce(v_wf,'off'),
    'fetch_error', v_err);
END $$;
