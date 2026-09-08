-- CHANGE #1506 — bound dev_cmd_heartbeat.
--
-- The runner breaker named this call 19 times in one episode. It was never a
-- missing index: every statement it runs is already a primary-key lookup of
-- exactly one row. What it was missing is a CEILING on the BYTES that one row
-- carries, and a set-based shape that touches the row once instead of three
-- times.
--
-- Measured before this change, on a row whose build_log sat at the 200,000-char
-- cap (explain (analyze, buffers)):
--   UPDATE #1 (log append)  21.6 ms  197 buffers  9 dirtied  9 written
--   SELECT   (re-read model/tokens)
--   UPDATE #2 (cost_inr)    17.6 ms   83 buffers  3 dirtied
--   = ~39 ms and ~280 buffers per beat, per worker, every 60 s.
--
-- Two facts make almost all of that waste:
--   1. build_log averaged 103,729 chars across 428 rows - 19 MB of TOAST on a
--      28 MB table. Every beat detoasted it, concatenated, recompressed and
--      wrote a fresh TOAST chain, then WAL-logged the lot.
--   2. NOTHING READS MORE THAN 8,000 CHARACTERS OF IT. _dev_cmd_rows renders
--      left(build_log, 4000); dev_cmd_get renders right(build_log, 8000). The
--      other 96% was written every minute and never displayed.
-- On top of that, trg_dev_title_sync fires on both UPDATEs and its
-- `new.build_log is distinct from old.build_log` test detoasts the column even
-- on the second one, where the log did not change at all (3.7 ms + 1.3 ms).
--
-- So: ONE update, and a build_log that is bounded head + tail rather than an
-- ever-growing blob. The head is kept because that is where the first beat
-- writes "building #N: <title>" - the line _dev_title_sync derives the card
-- title from - and where _dev_cmd_rows' left(...,4000) reads. The old shape,
-- right(log || tail, 200000), threw the head away the moment the log filled;
-- this keeps it forever and still costs an order of magnitude less.
--
-- The trim is self-stabilising: the retained tail window always starts strictly
-- AFTER the previous marker's last character, so markers can never accumulate.
-- Steady-state length is exactly log_cap_chars, whatever the beat rate.
--
-- Every knob is config, not code: worker_pool.heartbeat.{log_cap_chars,
-- log_head_chars, tail_max_chars} - retune with pool_set(), no deploy.

-- ── 1. the knobs ──────────────────────────────────────────────────────────────
update dev_runner_config
   set value = jsonb_set(value, '{heartbeat}',
         coalesce(value->'heartbeat','{}'::jsonb)
         || jsonb_build_object(
              'log_cap_chars',  24000,   -- 3x what any reader asks for
              'log_head_chars',  4000,   -- exactly _dev_cmd_rows' left(...,4000)
              'tail_max_chars',  4000))  -- one beat may never write more than this
 where key = 'worker_pool';

-- ── 2. the bounded, single-statement heartbeat ────────────────────────────────
create or replace function public.dev_cmd_heartbeat(
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
AS $function$
DECLARE
  v_claim_sess text; v_owner text; v_status text;
  v_cfg jsonb; v_pool jsonb; v_rates jsonb;
  v_model text; v_mode text; v_in_usd numeric; v_out_usd numeric; v_fx numeric;
  v_budget bigint; v_extra bigint; v_tokens bigint; v_class text;
  v_cap int; v_head int; v_tailmax int; v_tail text;
  v_mark constant text := E'\n... [log trimmed] ...\n';
BEGIN
  PERFORM _dev_guard();

  -- ONE narrow read of the row. build_log is deliberately NOT selected, so
  -- nothing here detoasts it: this is a heap+index touch of a few hundred
  -- bytes, not of the 100 kB the column used to carry.
  -- It answers every question the rest of the function used to re-ask the row
  -- for AFTER writing it: who owns the claim, which model prices this beat,
  -- how many tokens are already spent, and which budget class applies.
  SELECT dc.claim_session_id, dc.claimed_by, dc.status,
         -- CHANGE #656 kept intact: the REQUEST is never overwritten, and the
         -- rate is read from what this beat is about to make actual_model.
         coalesce(CASE WHEN p_model LIKE 'claude-%' THEN p_model END,
                  nullif(dc.actual_model,''), dc.model),
         coalesce(p_mode, dc.price_mode, 'standard'),
         dc.cost_input_tokens + dc.cost_output_tokens + coalesce(p_tokens_in,0) + coalesce(p_tokens_out,0),
         dc.token_budget_extra, dc.size_class
    INTO v_claim_sess, v_owner, v_status, v_model, v_mode, v_tokens, v_extra, v_class
    FROM dev_commands dc WHERE dc.id = p_id;

  -- CHANGE #1268 — a beat may only come from the session that CLAIMED the row.
  IF p_session_id IS NOT NULL AND v_claim_sess IS NOT NULL AND v_claim_sess <> p_session_id THEN
    PERFORM dev_agent_incident_log('heartbeat_wrong_session', v_owner, p_session_id, p_id,
      'beat from ' || p_session_id || ' but #' || p_id || ' was claimed by session ' || v_claim_sess);
    RETURN jsonb_build_object('ok', false, 'wrong_session', true, 'command_id', p_id,
      'expected_session', v_claim_sess, 'got_session', p_session_id,
      'label', 'This session does not own #' || p_id);
  END IF;

  -- Both config rows in one round trip (dev_runner_config is a 1-row-per-key
  -- primary-key lookup); the old shape read model_rates here and worker_pool
  -- again further down.
  SELECT (SELECT value FROM dev_runner_config WHERE key='model_rates'),
         (SELECT value FROM dev_runner_config WHERE key='worker_pool')
    INTO v_cfg, v_pool;

  v_rates := coalesce(v_cfg->'models'->v_model,
                      v_cfg->'models'->'claude-opus-5',
                      v_cfg->'models'->'claude-opus-4-8');
  v_fx := coalesce((v_cfg->>'usd_inr')::numeric, 88);
  IF v_mode='fast' AND v_rates ? 'fast_in' THEN
    v_in_usd := (v_rates->>'fast_in')::numeric;  v_out_usd := (v_rates->>'fast_out')::numeric;
  ELSE
    v_in_usd := (v_rates->>'in')::numeric;       v_out_usd := (v_rates->>'out')::numeric;
  END IF;

  -- The ceiling. greatest() so a bad config value can never turn the bound off.
  v_cap     := greatest(coalesce((v_pool->'heartbeat'->>'log_cap_chars')::int,  24000), 12000);
  v_head    := greatest(least(coalesce((v_pool->'heartbeat'->>'log_head_chars')::int, 4000), v_cap/3), 0);
  v_tailmax := greatest(coalesce((v_pool->'heartbeat'->>'tail_max_chars')::int,  4000),   500);
  -- One beat may never write more than tail_max_chars, however long a tail the
  -- caller hands us.
  v_tail    := nullif(left(coalesce(p_log_tail,''), v_tailmax), '');

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
  WHERE dc.id = p_id AND dc.status = 'building';
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'kill', true, 'reason','row not building'); END IF;

  v_budget := coalesce((v_pool->'token_budget_by_class'->>coalesce(v_class,'normal'))::bigint, 1500000)
              + coalesce(v_extra,0);
  IF v_tokens > v_budget THEN
    UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
      needs_input_question='Token budget for a '||coalesce(v_class,'normal')||' build hit ('||v_tokens||' > '||v_budget||'). Reply yes for one more window, or refine/split the spec.'
    WHERE id=p_id AND status='building';
    INSERT INTO dev_command_messages (command_id, sender, body)
      VALUES (p_id,'system','⛔ Auto-stopped: '||coalesce(v_class,'normal')||' token budget '||v_budget||' exceeded ('||v_tokens||').');
    PERFORM _lease_release_internal(p_id);
    PERFORM wa_send_event('sec_zombie_killed', NULL,
      jsonb_build_object('command_id',p_id::text,'reason','token budget ('||coalesce(v_class,'normal')||')','tokens',v_tokens::text), NULL, NULL);
    RETURN jsonb_build_object('ok', true, 'kill', true, 'reason','token_budget');
  END IF;

  RETURN jsonb_build_object('ok', true, 'model', v_model, 'mode', coalesce(v_mode,'standard'));
END $function$;

-- ── 3. the guard ──────────────────────────────────────────────────────────────
-- Red if the heartbeat ever grows a second write of the row again, if the
-- ceiling stops being applied, or if any row's build_log climbs back past the
-- configured cap. rg_check runs this on the cron dispatcher, so it costs the
-- HTTP path nothing.
insert into rg_behavior_tests (name, body, enabled, note) values (
  'c1506_heartbeat_is_bounded',
  $body$
do $t$
declare
  v_src text; v_cap int; v_worst int; v_updates int;
begin
  select prosrc into v_src from pg_proc
   where proname='dev_cmd_heartbeat' and pronamespace='public'::regnamespace;
  if v_src is null then raise exception 'dev_cmd_heartbeat is missing'; end if;

  -- the old unbounded shape must never come back
  if v_src like '%200000%' then
    raise exception 'dev_cmd_heartbeat still carries the 200000-char build_log cap';
  end if;
  if v_src not like '%log_cap_chars%' then
    raise exception 'dev_cmd_heartbeat no longer reads worker_pool.heartbeat.log_cap_chars';
  end if;

  -- One UPDATE of dev_commands on the beat path. The only other one allowed is
  -- inside the token-budget branch, which is a kill, not a beat.
  v_updates := (length(v_src) - length(replace(v_src, 'UPDATE dev_commands', '')))
               / length('UPDATE dev_commands');
  if v_updates > 2 then
    raise exception 'dev_cmd_heartbeat writes dev_commands % times; the beat path may write it once', v_updates;
  end if;

  select greatest(coalesce((value->'heartbeat'->>'log_cap_chars')::int, 24000), 12000)
    into v_cap from dev_runner_config where key='worker_pool';
  -- SELECT INTO leaves v_cap NULL when the row is absent (a fresh build branch
  -- restores the schema, not the config rows), and `v_worst > NULL` is NULL -
  -- a guard that can never fire. Fall back to the same default the function uses.
  v_cap := coalesce(v_cap, 24000);
  -- Bounded on purpose: only the rows the heartbeat is actually writing. A
  -- max(length(build_log)) over the whole table would detoast every historical
  -- log - the exact cost this change exists to remove.
  select coalesce(max(length(build_log)),0) into v_worst
    from (select build_log from dev_commands
           where heartbeat_at > now() - interval '2 days'
           order by id desc limit 200) recent;
  if v_worst > v_cap then
    raise exception 'a build_log is % chars, past the %-char ceiling', v_worst, v_cap;
  end if;

  -- The harness's success marker: a body that returns without raising
  -- RG_ROLLBACK is treated as a FAILED test.
  raise exception 'RG_ROLLBACK';
end $t$;
  $body$,
  true,
  'CHANGE #1506 - dev_cmd_heartbeat may touch one row, once, with a bounded build_log.'
) on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;
