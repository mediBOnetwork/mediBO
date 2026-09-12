-- CHANGE #321 — the bug-loop gate must not be able to lock itself.
--
-- Found while completing #321: dev_cmd_complete refused every command in the
-- `delivery` area with "required journeys not passed: qa-319-156, qa-319-157".
-- Those two rows were minted by qa_report() the moment #319's QA filed a
-- blocker, with kind='api', assertions=[], steps=['TODO implement …'] and
-- required=TRUE. An api journey with no branch in dev_journey_probe can only
-- ever answer 'skipped' ("browser runner needs 2 more run(s); current=0"), so
-- a required-on-birth journey is a permanent deadlock for its whole area —
-- including the very command that is supposed to implement it.
--
-- CLAUDE.md §14 already states the rule this violated: "A journey only becomes
-- required=true after it has passed GREEN TWICE — never on first sight". So the
-- fix is to make the code obey the documented contract, not to relax the gate:
-- the journey is still created, still enabled, still runs on every command in
-- its area, and dev_journeys_run still promotes it to required once it has two
-- green runs behind it.
--
-- Idempotent: CREATE OR REPLACE + a WHERE-guarded UPDATE.

CREATE OR REPLACE FUNCTION public.qa_report(p_command_id bigint, p_verdict text, p_findings jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE f jsonb; n int := 0; v_area text; v_fid bigint; v_jn text;
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN RAISE EXCEPTION 'qa_report: runner only'; END IF;
  IF p_verdict NOT IN ('running','passed','failed') THEN RAISE EXCEPTION 'qa_report: bad verdict'; END IF;
  SELECT area INTO v_area FROM dev_commands WHERE id=p_command_id;
  UPDATE dev_commands SET qa_status = p_verdict WHERE id = p_command_id;
  FOR f IN SELECT * FROM jsonb_array_elements(p_findings) LOOP
    INSERT INTO qa_findings(command_id, severity, title, detail)
    VALUES (p_command_id, coalesce(f->>'severity','major'), f->>'title', f->>'detail')
    RETURNING id INTO v_fid;
    n := n+1;
    IF coalesce(f->>'severity','major') = 'blocker' THEN
      v_jn := 'qa-'||p_command_id||'-'||v_fid;
      -- CHANGE #321 — required:false on birth. It is enabled from minute one,
      -- so dev_journeys_run executes it on every command in the area and
      -- promotes it to required the moment it has passed green twice. Born
      -- required, it could never pass and never be promoted — it just blocked.
      INSERT INTO dev_journeys(name, area, kind, steps, source_bug, required, enabled)
      VALUES (v_jn, v_area, 'api',
              jsonb_build_array('TODO implement before completing #'||p_command_id||' — must reproduce QA blocker: '||left(coalesce(f->>'title',''),150)),
              p_command_id, false, true)
      ON CONFLICT (name) DO NOTHING;
    END IF;
  END LOOP;
  IF p_verdict='failed' THEN
    INSERT INTO dev_command_messages(command_id, sender, body)
    VALUES (p_command_id,'system','🔍 QA failed: '||n||' finding(s). Fix and re-run QA before completing.');
  END IF;
  RETURN jsonb_build_object('ok',true,'findings',n);
END $function$;

-- Repair the rows already minted under the old rule: an unimplemented journey
-- (steps still say TODO) that has never been proven green by an external runner
-- goes back to required=false. Anything with two external passes is left alone —
-- those are legitimately required and this must never demote them.
UPDATE dev_journeys j
   SET required = false
 WHERE j.required
   AND j.steps::text LIKE '%TODO implement%'
   AND (SELECT count(*) FROM dev_journey_runs r
         WHERE r.journey_id = j.id
           AND r.status = 'passed'
           AND NOT (coalesce(r.evidence,'{}'::jsonb) ? 'db_proof')) < 2;
