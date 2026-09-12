-- CHANGE #1758 — Slow call: dev_cmd_heartbeat — bound it.
--
-- The runner breaker tripped on 21 DB timeouts in 5 minutes and named this call
-- as the worst offender: 7 CANCELLED dev_cmd_heartbeat calls, and an EMPTY
-- `slowest` list. Those two facts together are the whole diagnosis. Measured on
-- the build branch, one beat costs 0.125 ms and touches one row, which is why
-- pg_stat_statements had nothing over 250 ms to report. What it did instead was
-- WAIT: with the same episode showing transactions open 134 s and 801 s, a
-- single beat was measured parking a pooled connection for 22.96 s on a row
-- lock, and under the runner role's 55 s statement_timeout it parks for the
-- full 55 s and then dies as 57014. Five workers beating every 60 s into a
-- 60-connection instance is then self-amplifying: the beat is not the slow
-- query, it is the thing that turns someone else's slow query into an outage.
--
-- So the ceiling this call was missing is a ceiling on the WAIT, plus a ceiling
-- on the ROWS. Three bounded changes, no behaviour change on the happy path:
--
-- 1. lock_timeout = 2s in the function's own definition. Proved on the branch:
--    a function-level SET lock_timeout fires (0.61 s against a locked row),
--    while a function-level SET statement_timeout is INERT for its own call
--    (pg_sleep(3) under a 1 s setting slept 3.12 s) because the statement timer
--    is armed by the top-level statement before the function is entered. Every
--    heavyweight wait this function can take — the row lock, and the relation
--    lock a migration's ALTER TABLE holds — is bounded by it.
--
-- 2. The row is taken FOR NO KEY UPDATE in the one read the function already
--    does, and lock_not_available is answered with ok:true + busy:true instead
--    of an error. A missed beat is a number that does not advance for 60 s
--    against a 15-minute watchdog; a 55-second connection is an outage.
--
-- 3. The write is now a primary-key update. It read
--      WHERE dc.id = p_id AND dc.status = 'building'
--    and EXPLAIN showed the planner choosing
--      Index Scan using dev_commands_status_idx  Index Cond: (status='building')
--      Filter: (id = 703)
--    — a scan whose row count grows with the number of building commands, on
--    the hottest index in the table. The status check now happens against the
--    value read under the row lock (which is race-free, where the old predicate
--    was not), and the UPDATE locates its row by dev_commands_pkey alone.
--
-- Also hardened: v_rates comes from dev_runner_config.key='model_rates'. On a
-- database where that key is absent the rate is NULL, cost_inr is NULL, and the
-- NOT NULL constraint made EVERY heartbeat in the fleet raise — reproduced on
-- the build branch, which ships without that row. coalesce(...,0) turns a
-- config gap into a zero cost instead of a dead runner pool.

CREATE OR REPLACE FUNCTION public.dev_cmd_heartbeat(
  p_id bigint,
  p_log_tail text DEFAULT NULL::text,
  p_tokens_in bigint DEFAULT 0,
  p_tokens_out bigint DEFAULT 0,
  p_model text DEFAULT NULL::text,
  p_effort text DEFAULT NULL::text,
  p_mode text DEFAULT NULL::text,
  p_eta_total_s integer DEFAULT NULL::integer,
  p_eta_left_s integer DEFAULT NULL::integer,
  p_eta_note text DEFAULT NULL::text,
  p_agent_turn_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_pane_alive boolean DEFAULT NULL::boolean,
  p_rc_session text DEFAULT NULL::text,
  p_session_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 -- CHANGE #1758 — the ceiling. Armed at every heavyweight lock wait this
 -- function can take, so a beat can never hold a pooled connection for the
 -- session's 55 s statement_timeout waiting on somebody else's transaction.
 SET lock_timeout TO '2s'
AS $function$
DECLARE
  v_claim_sess text; v_owner text; v_status text;
  v_cfg jsonb; v_pool jsonb; v_rates jsonb;
  v_model text; v_mode text; v_in_usd numeric; v_out_usd numeric; v_fx numeric;
  v_budget bigint; v_extra bigint; v_tokens bigint; v_class text;
  v_cap int; v_head int; v_tailmax int; v_tail text;
  v_found boolean := false;
  v_mark constant text := E'\n... [log trimmed] ...\n';
BEGIN
  PERFORM _dev_guard();

  -- ONE narrow read of the row. build_log is deliberately NOT selected, so
  -- nothing here detoasts it: this is a heap+index touch of a few hundred
  -- bytes, not of the 100 kB the column used to carry.
  -- It answers every question the rest of the function used to re-ask the row
  -- for AFTER writing it: who owns the claim, which model prices this beat,
  -- how many tokens are already spent, and which budget class applies.
  --
  -- CHANGE #1758 — and it now takes the row lock the UPDATE was going to take
  -- anyway, under this function's own lock_timeout, so the whole beat either
  -- owns the row within 2 s or gives up cheaply. FOR NO KEY UPDATE: it blocks
  -- other writers of this row, never a reader and never a foreign key.
  BEGIN
    SELECT dc.claim_session_id, dc.claimed_by, dc.status,
           -- CHANGE #656 kept intact: the REQUEST is never overwritten, and the
           -- rate is read from what this beat is about to make actual_model.
           coalesce(CASE WHEN p_model LIKE 'claude-%' THEN p_model END,
                    nullif(dc.actual_model,''), dc.model),
           coalesce(p_mode, dc.price_mode, 'standard'),
           dc.cost_input_tokens + dc.cost_output_tokens + coalesce(p_tokens_in,0) + coalesce(p_tokens_out,0),
           dc.token_budget_extra, dc.size_class
      INTO v_claim_sess, v_owner, v_status, v_model, v_mode, v_tokens, v_extra, v_class
      FROM dev_commands dc WHERE dc.id = p_id
      FOR NO KEY UPDATE;
    v_found := FOUND;
  EXCEPTION WHEN lock_not_available THEN
    -- Somebody else is writing this row right now (a complete, a watchdog, a
    -- migration holding the table). Skipping one beat costs 60 seconds of a
    -- 15-minute liveness budget. Waiting costs a connection out of 60.
    RETURN jsonb_build_object('ok', true, 'busy', true, 'command_id', p_id,
      'label', 'beat skipped — #' || p_id || ' is locked by another writer');
  END;

  -- CHANGE #1268 — a beat may only come from the session that CLAIMED the row.
  IF p_session_id IS NOT NULL AND v_claim_sess IS NOT NULL AND v_claim_sess <> p_session_id THEN
    PERFORM dev_agent_incident_log('heartbeat_wrong_session', v_owner, p_session_id, p_id,
      'beat from ' || p_session_id || ' but #' || p_id || ' was claimed by session ' || v_claim_sess);
    RETURN jsonb_build_object('ok', false, 'wrong_session', true, 'command_id', p_id,
      'expected_session', v_claim_sess, 'got_session', p_session_id,
      'label', 'This session does not own #' || p_id);
  END IF;

  -- Same contract the post-UPDATE `IF NOT FOUND` used to give the caller, moved
  -- in front of the write now that the status is read under the row lock.
  IF NOT v_found OR v_status IS DISTINCT FROM 'building' THEN
    RETURN jsonb_build_object('ok', false, 'kill', true, 'reason','row not building');
  END IF;

  -- Both config rows in one round trip (dev_runner_config is a 1-row-per-key
  -- primary-key lookup); the old shape read model_rates here and worker_pool
  -- again further down.
  SELECT (SELECT value FROM dev_runner_config WHERE key='model_rates'),
         (SELECT value FROM dev_runner_config WHERE key='worker_pool')
    INTO v_cfg, v_pool;

  v_cfg   := coalesce(v_cfg, '{}'::jsonb);
  v_rates := coalesce(v_cfg->'models'->v_model,
                      v_cfg->'models'->'claude-opus-5',
                      v_cfg->'models'->'claude-opus-4-8',
                      '{}'::jsonb);
  v_fx := coalesce((v_cfg->>'usd_inr')::numeric, 88);
  IF v_mode='fast' AND v_rates ? 'fast_in' THEN
    v_in_usd := (v_rates->>'fast_in')::numeric;  v_out_usd := (v_rates->>'fast_out')::numeric;
  ELSE
    v_in_usd := (v_rates->>'in')::numeric;       v_out_usd := (v_rates->>'out')::numeric;
  END IF;
  -- CHANGE #1758 — a missing model_rates row must not make cost_inr NULL and
  -- take every heartbeat in the fleet down on a NOT NULL violation.
  v_in_usd  := coalesce(v_in_usd, 0);
  v_out_usd := coalesce(v_out_usd, 0);

  -- The ceiling. greatest() so a bad config value can never turn the bound off.
  v_cap     := greatest(coalesce((v_pool->'heartbeat'->>'log_cap_chars')::int,  24000), 12000);
  v_head    := greatest(least(coalesce((v_pool->'heartbeat'->>'log_head_chars')::int, 4000), v_cap/3), 0);
  v_tailmax := greatest(coalesce((v_pool->'heartbeat'->>'tail_max_chars')::int,  4000),   500);
  -- One beat may never write more than tail_max_chars, however long a tail the
  -- caller hands us.
  v_tail    := nullif(left(coalesce(p_log_tail,''), v_tailmax), '');

  -- CHANGE #1758 — located by dev_commands_pkey and nothing else. The old
  -- `AND dc.status='building'` predicate let the planner reach this row through
  -- dev_commands_status_idx, walking every building command to find one id.
  -- The status was already checked above, against a value read under the lock
  -- this transaction still holds, so it cannot have changed since.
  UPDATE dev_commands dc SET
    heartbeat_at = now(),
    -- Nothing to append => the same datum is assigned back, so Postgres keeps
    -- the existing TOAST pointer and writes no new chain at all.
    build_log = CASE
      WHEN v_tail IS NULL THEN dc.build_log
      WHEN length(coalesce(dc.build_log,'')) + length(v_tail) + 1 <= v_cap
        THEN coalesce(dc.build_log,'') || E'\n' || v_tail
      ELSE left(coalesce(dc.build_log,''), v_head) || v_mark
           || right(coalesce(dc.build_log,'') || E'\n' || v_tail,
                    v_cap - v_head - length(v_mark))
    END,
    cost_input_tokens  = dc.cost_input_tokens  + p_tokens_in,
    cost_output_tokens = dc.cost_output_tokens + p_tokens_out,
    actual_model  = coalesce(CASE WHEN p_model LIKE 'claude-%' THEN p_model END, dc.actual_model),
    actual_effort = coalesce(CASE WHEN p_effort IN ('low','medium','high','xhigh','max','extra') THEN p_effort END, dc.actual_effort),
    price_mode    = coalesce(p_mode, dc.price_mode, 'standard'),
    eta_total_s   = coalesce(p_eta_total_s, dc.eta_total_s),
    eta_left_s    = coalesce(p_eta_left_s,  dc.eta_left_s),
    eta_note      = coalesce(p_eta_note,    dc.eta_note),
    -- CHANGE #1023 — liveness of the AGENT, not of the bash loop reporting it.
    agent_alive_at   = coalesce(p_agent_turn_at, dc.agent_alive_at),
    agent_pane_alive = coalesce(p_pane_alive,    dc.agent_pane_alive),
    agent_rc_session = coalesce(nullif(p_rc_session,''), dc.agent_rc_session),
    agent_silent_flagged = CASE WHEN p_agent_turn_at IS NOT NULL THEN false ELSE dc.agent_silent_flagged END,
    agent_silent_at      = CASE WHEN p_agent_turn_at IS NOT NULL THEN NULL  ELSE dc.agent_silent_at END,
    -- The second UPDATE, folded in. It used to rewrite the whole tuple a second
    -- time - and make trg_dev_title_sync detoast build_log again to prove it
    -- had not changed.
    cost_inr = round(((dc.cost_input_tokens  + p_tokens_in)  * v_in_usd
                    + (dc.cost_output_tokens + p_tokens_out) * v_out_usd) * v_fx / 1000000.0, 2)
  WHERE dc.id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'kill', true, 'reason','row not building'); END IF;

  v_budget := coalesce((v_pool->'token_budget_by_class'->>coalesce(v_class,'normal'))::bigint, 1500000)
              + coalesce(v_extra,0);
  IF v_tokens > v_budget THEN
    -- Same row, same transaction, lock already held: by primary key.
    UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
      needs_input_question='Token budget for a '||coalesce(v_class,'normal')||' build hit ('||v_tokens||' > '||v_budget||'). Reply yes for one more window, or refine/split the spec.'
    WHERE id=p_id;
    INSERT INTO dev_command_messages (command_id, sender, body)
      VALUES (p_id,'system','⛔ Auto-stopped: '||coalesce(v_class,'normal')||' token budget '||v_budget||' exceeded ('||v_tokens||').');
    PERFORM _lease_release_internal(p_id);
    PERFORM wa_send_event('sec_zombie_killed', NULL,
      jsonb_build_object('command_id',p_id::text,'reason','token budget ('||coalesce(v_class,'normal')||')','tokens',v_tokens::text), NULL, NULL);
    RETURN jsonb_build_object('ok', true, 'kill', true, 'reason','token_budget');
  END IF;

  RETURN jsonb_build_object('ok', true, 'model', v_model, 'mode', coalesce(v_mode,'standard'));
END $function$;
