-- CHANGE #1023 — the row owns its model and its effort. The runner may not.
--
-- #1016 was added as claude-fable-5-1 / extra. It failed once, dev_cmd_fail's
-- retry branch ran `effort='high'` unconditionally, and the card has read
-- "Fable 5 · High effort · retry escalated to high effort" ever since. #656
-- made model/effort authoritative AT CLAIM; every path that runs AFTER the
-- claim (retry, escalate, auto-heal) still overwrote them.
--
-- Three locks, in order of how early they catch it:
--   1. the ladder itself can only ever go UP  (_dev_effort_escalate)
--   2. dev_cmd_fail uses the ladder instead of a literal
--   3. a trigger refuses any runner-made UPDATE that lowers effort or swaps
--      the model, whatever wrote it
-- Every statement here is idempotent — a resumed worker re-applies it silently.

-- ── 1. the ladder ──────────────────────────────────────────────────────────
-- Post-#656 only two efforts exist; 'standard' is the historical name for the
-- floor and normalises to 'high'. Rank is what makes "never lowers" checkable.
CREATE OR REPLACE FUNCTION public._dev_effort_rank(p_effort text)
 RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE public._dev_effort_norm(p_effort)
           WHEN 'extra' THEN 2
           WHEN 'high'  THEN 1
           ELSE 0
         END;
$$;

-- standard → high → extra, and extra is the ceiling.
CREATE OR REPLACE FUNCTION public._dev_effort_escalate(p_current text)
 RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN public._dev_effort_rank(p_current) >= 1 THEN 'extra' ELSE 'high' END;
$$;

-- max(a, b) over the ladder — the shape every writer must use.
CREATE OR REPLACE FUNCTION public._dev_effort_max(p_a text, p_b text)
 RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN public._dev_effort_rank(p_a) >= public._dev_effort_rank(p_b)
              THEN coalesce(public._dev_effort_norm(p_a), public._dev_effort_norm(p_b), 'high')
              ELSE coalesce(public._dev_effort_norm(p_b), 'high') END;
$$;

-- ── 2. the one writer that lowered it ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.dev_cmd_fail(p_id bigint, p_error text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_retry int; v_cls jsonb; v_gate boolean; v_max int; v_row record;
        v_was text; v_now text; v_note text;
BEGIN
  PERFORM _dev_guard();
  SELECT * INTO v_row FROM dev_commands WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'no such command'); END IF;
  v_retry := coalesce(v_row.retry_count, 0);

  -- CHANGE #571 — contention is a WAIT, never a failure.
  SELECT coalesce((value->'wait_gate'->>'enabled')::boolean, true),
         coalesce((value->'wait_gate'->>'max_parks')::int, 6)
    INTO v_gate, v_max FROM dev_runner_config WHERE key = 'worker_pool';
  v_cls := _dev_fail_classify(coalesce(p_error, ''));

  IF coalesce(v_gate, true)
     AND v_cls->>'verdict' = 'wait'
     AND v_row.status = 'building'
     AND coalesce(v_row.wait_count, 0) < coalesce(v_max, 6) THEN
    RETURN dev_cmd_park(p_id, v_cls->>'kind', v_cls->>'label',
             jsonb_build_object('error', left(coalesce(p_error,''), 1000),
                                'classified', v_cls),
             (v_cls->>'retry_after_s')::int)
           || jsonb_build_object('classified', v_cls, 'failed', false);
  END IF;

  IF v_retry = 0 THEN
    -- CHANGE #1023: the ladder, never a literal. max(current, escalated) means
    -- an `extra` command comes back as `extra` — a retry may raise the effort
    -- Om paid for, it may never spend less than he asked.
    v_was := _dev_effort_norm(v_row.effort);
    v_now := _dev_effort_max(v_was, _dev_effort_escalate(v_was));
    v_note := CASE WHEN v_now IS DISTINCT FROM v_was
                   THEN ' · retry escalated to '||_dev_effort_label(v_now)
                   ELSE ' · retry kept '||_dev_effort_label(v_now) END;
    UPDATE dev_commands SET status='pending', retry_count=1, claimed_by=NULL,
      effort = v_now,
      wait_state=NULL, wait_kind=NULL, wait_until=NULL,
      route_reason = coalesce(route_reason,'')||v_note,
      error_log = coalesce(error_log||E'\n---\n','')||'RETRY 1 after: '||p_error
    WHERE id=p_id AND status='building';
  ELSE
    UPDATE dev_commands SET status='failed', finished_at=now(), claimed_by=NULL,
      wait_state=NULL, wait_kind=NULL, wait_until=NULL,
      error_log = coalesce(error_log||E'\n---\n','')||p_error
    WHERE id=p_id AND status='building';
    IF FOUND THEN
      PERFORM wa_send_event('dev_cmd_failed', NULL, jsonb_build_object('command_id', p_id::text, 'error', left(p_error,300)), NULL, NULL);
    END IF;
  END IF;
  PERFORM _lease_release_internal(p_id);
  RETURN jsonb_build_object('ok', true, 'retried', v_retry = 0, 'failed', true,
                            'effort', coalesce(v_now, _dev_effort_norm(v_row.effort)),
                            'classified', v_cls);
END $function$;

-- ── 3. the backstop: whatever writes it, the runner cannot lower it ────────
-- _actor() already knows the difference: a service_role JWT (every devcmd.sh
-- call, and every SECURITY DEFINER function reached through one) is 'runner';
-- an admin in the app carries a user JWT, and a DBA psql session carries none.
-- Only the runner is refused, so this can never lock Om out of his own card.
CREATE OR REPLACE FUNCTION public._dev_model_effort_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_runner boolean; v_why text;
BEGIN
  IF NEW.model IS NOT DISTINCT FROM OLD.model
     AND NEW.effort IS NOT DISTINCT FROM OLD.effort THEN
    RETURN NEW;
  END IF;
  v_runner := coalesce(auth.jwt()->>'role','') = 'service_role';
  IF NOT v_runner THEN RETURN NEW; END IF;   -- admin / DBA: their call

  IF NEW.model IS DISTINCT FROM OLD.model AND OLD.model IS NOT NULL THEN
    v_why := format('model %s → %s', OLD.model, NEW.model);
  ELSIF _dev_effort_rank(NEW.effort) < _dev_effort_rank(OLD.effort) THEN
    v_why := format('effort %s → %s', OLD.effort, NEW.effort);
  END IF;

  IF v_why IS NOT NULL THEN
    PERFORM _audit('runner','cmd_model_effort_blocked', NEW.id::text,
                   jsonb_build_object('attempt', v_why));
    RAISE EXCEPTION 'CHANGE #1023 — the runner may not change a command''s model or lower its effort (#%: %). Om owns model/effort; the escalation ladder may only raise it.',
      NEW.id, v_why;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_dev_model_effort_guard ON public.dev_commands;
CREATE TRIGGER trg_dev_model_effort_guard
  BEFORE UPDATE OF model, effort ON public.dev_commands
  FOR EACH ROW EXECUTE FUNCTION public._dev_model_effort_guard();

-- ── 4. the card must show the drift, not hide it ──────────────────────────
-- The chip preferred actual_effort with no "asked" note, so a session launched
-- at the wrong effort printed as if that were what Om ordered. Effort now
-- drifts as loudly as the model does.
CREATE OR REPLACE FUNCTION public._dev_model_chip(p_model text, p_effort text, p_mode text, p_actual_model text DEFAULT NULL::text, p_actual_effort text DEFAULT NULL::text)
 RETURNS text LANGUAGE sql STABLE AS $function$
  WITH v AS (
    SELECT coalesce(nullif(p_actual_model,''),  nullif(p_model,''),  'claude-opus-5') AS m,
           coalesce(nullif(p_actual_effort,''), nullif(p_effort,''), 'high')          AS e,
           nullif(p_actual_model,'') IS NOT NULL
             AND nullif(p_model,'') IS NOT NULL
             AND nullif(p_actual_model,'') <> nullif(p_model,'')                      AS drift,
           nullif(p_actual_effort,'') IS NOT NULL
             AND nullif(p_effort,'') IS NOT NULL
             AND public._dev_effort_norm(p_actual_effort)
                 IS DISTINCT FROM public._dev_effort_norm(p_effort)                   AS edrift
  )
  SELECT _dev_model_label(v.m)
         || ' · ' || _dev_effort_label(v.e)
         || coalesce(' · ' || nullif(p_mode,''), '')
         || CASE WHEN v.drift THEN ' · asked ' || _dev_model_label(p_model) ELSE '' END
         || CASE WHEN v.edrift THEN ' · asked ' || _dev_effort_label(p_effort) ELSE '' END
    FROM v;
$function$;

CREATE OR REPLACE FUNCTION public._dev_model_chip_m(p_models jsonb, p_efforts jsonb, p_model text, p_effort text, p_mode text, p_actual_model text DEFAULT NULL::text, p_actual_effort text DEFAULT NULL::text)
 RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  with v as (
    select coalesce(nullif(p_actual_model,''),  nullif(p_model,''),  'claude-opus-5') as m,
           coalesce(nullif(p_actual_effort,''), nullif(p_effort,''), 'high')          as e,
           nullif(p_actual_model,'') is not null
             and nullif(p_model,'') is not null
             and nullif(p_actual_model,'') <> nullif(p_model,'')                      as drift,
           nullif(p_actual_effort,'') is not null
             and nullif(p_effort,'') is not null
             and public._dev_effort_norm(p_actual_effort)
                 is distinct from public._dev_effort_norm(p_effort)                   as edrift
  )
  select public._dev_model_label_m(p_models, v.m)
         || ' · ' || public._dev_effort_label_m(p_efforts, v.e)
         || coalesce(' · ' || nullif(p_mode,''), '')
         || case when v.drift then ' · asked ' || public._dev_model_label_m(p_models, p_model)
                 else '' end
         || case when v.edrift then ' · asked ' || public._dev_effort_label_m(p_efforts, p_effort)
                 else '' end
    from v;
$function$;

-- ── 5. the runner writes what it STARTED with, into the thread ────────────
-- Spec item 3: every invocation (first run, retry, resume after /clear,
-- auto-heal) records the exact flags it used, so a drifted session is a fact in
-- the thread rather than an inference off a chip. Wording lives in ui_copy.
INSERT INTO ui_copy (key, value) VALUES
  ('dev_queue.started_flags', to_jsonb('▶ started: {model} / {effort} ({source})'::text)),
  ('dev_queue.effort_drift',  to_jsonb('Session effort {actual} does not match the command''s {asked}'::text))
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.dev_cmd_note_flags(p_id bigint, p_model text, p_effort text, p_source text DEFAULT 'run')
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_t text; v_body text; v_prev text;
BEGIN
  PERFORM _dev_guard();
  IF NOT EXISTS (SELECT 1 FROM dev_commands WHERE id=p_id) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no such command');
  END IF;
  SELECT value#>>'{}' INTO v_t FROM ui_copy WHERE key='dev_queue.started_flags';
  v_body := replace(replace(replace(coalesce(v_t,'▶ started: {model} / {effort} ({source})'),
              '{model}',  coalesce(nullif(p_model,''),'?')),
              '{effort}', coalesce(nullif(p_effort,''),'?')),
              '{source}', coalesce(nullif(p_source,''),'run'));
  -- One line per START, not one per heartbeat: an unchanged relaunch is silent.
  SELECT body INTO v_prev FROM dev_command_messages
   WHERE command_id=p_id AND sender='system' AND body LIKE '▶ started:%'
   ORDER BY id DESC LIMIT 1;
  IF v_prev IS DISTINCT FROM v_body THEN
    INSERT INTO dev_command_messages (command_id, sender, body) VALUES (p_id,'system',v_body);
  END IF;
  UPDATE dev_commands SET started_flags = v_body WHERE id=p_id;
  RETURN jsonb_build_object('ok', true, 'body', v_body, 'logged', v_prev IS DISTINCT FROM v_body);
END $function$;

ALTER TABLE public.dev_commands ADD COLUMN IF NOT EXISTS started_flags text;

-- ── 6. the sweep Om asked for: any live row whose card differs from the row ─
CREATE OR REPLACE FUNCTION public.dev_cmd_effort_drift(p_fix boolean DEFAULT false)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_rows jsonb; v_fixed int := 0;
BEGIN
  PERFORM _dev_guard();
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'status', status, 'claimed_by', claimed_by,
           'model', model, 'effort', effort,
           'actual_model', actual_model, 'actual_effort', actual_effort,
           'chip', _dev_model_chip(model, effort, price_mode, actual_model, actual_effort),
           'asked_rank', _dev_effort_rank(effort),
           'ran_rank',   _dev_effort_rank(actual_effort)) ORDER BY id), '[]'::jsonb)
    INTO v_rows
    FROM dev_commands
   WHERE status IN ('building','pending')
     AND actual_effort IS NOT NULL
     AND _dev_effort_norm(actual_effort) IS DISTINCT FROM _dev_effort_norm(effort);

  IF p_fix THEN
    -- The OBSERVATION is what is wrong, never the request: clearing actual_*
    -- makes the card tell the truth again and the next beat re-reports it.
    UPDATE dev_commands SET actual_effort = NULL
     WHERE status IN ('building','pending')
       AND actual_effort IS NOT NULL
       AND _dev_effort_norm(actual_effort) IS DISTINCT FROM _dev_effort_norm(effort);
    GET DIAGNOSTICS v_fixed = ROW_COUNT;
  END IF;
  RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(v_rows),
                            'cleared', v_fixed, 'rows', v_rows);
END $function$;

GRANT EXECUTE ON FUNCTION public.dev_cmd_note_flags(bigint,text,text,text) TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.dev_cmd_effort_drift(boolean) TO service_role, authenticated;
