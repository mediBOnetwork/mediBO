-- CHANGE #319 — implement the journey behind QA blockers 156/157.
--
-- Both findings are the same defect: version.json at the preview origin
-- answered with the SPA HTML shell, so the version check could not read a
-- commit at all. qa_report() minted qa-319-156 / qa-319-157 for them with
-- steps=['TODO implement …'] and no branch in dev_journey_probe, so they could
-- only ever answer 'skipped' — and dev_cmd_complete blocks on
-- `j.source_bug = p_id`, which is NOT relaxed by #321's required=false repair.
-- (#321 fixed the area-wide deadlock; the originating command still had none.)
-- The rule (CLAUDE.md §14.4) is that a bug becomes a permanent journey, so the
-- fix is to IMPLEMENT the assertion, never to waive it.
--
-- The class retired: a post-deploy verification run must never be recorded
-- green unless it actually parsed a commit out of version.json. HTML in
-- version.json cannot produce a 7–40 char hex commit_hash.
--
-- Idempotent: CREATE OR REPLACE + a splice guarded on the branch's absence.

CREATE OR REPLACE FUNCTION public._journey_qa319_version()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_total int; v_bad int; v_green int; v_last record; v_ok boolean;
BEGIN
  SELECT count(*) INTO v_total
    FROM verify_run_log WHERE at > now() - interval '24 hours';

  -- The finding itself: a run whose version.json was not JSON leaves a
  -- commit_hash that is null or is not a git hash.
  SELECT count(*) INTO v_bad
    FROM verify_run_log
   WHERE at > now() - interval '24 hours'
     AND (commit_hash IS NULL OR commit_hash !~ '^[0-9a-f]{7,40}$');

  SELECT count(*) INTO v_green
    FROM verify_run_log
   WHERE at > now() - interval '24 hours'
     AND build_match AND exit_code = 0;

  SELECT * INTO v_last FROM verify_run_log ORDER BY at DESC LIMIT 1;

  v_ok := (v_total > 0 AND v_bad = 0 AND v_green > 0);

  RETURN jsonb_build_object(
    'status', CASE WHEN v_ok THEN 'passed' ELSE 'failed' END,
    'evidence', jsonb_build_object(
      'db_proof',
        'verify_run_log last 24h: runs=' || v_total ||
        ' green=' || v_green ||
        ' unparseable_version_json=' || v_bad ||
        ' | latest commit=' || coalesce(v_last.commit_hash, 'null') ||
        ' build_match=' || coalesce(v_last.build_match::text, 'null') ||
        ' exit_code=' || coalesce(v_last.exit_code::text, 'null'),
      'asserts', jsonb_build_object(
        'version_json_parsed_on_every_run', v_bad = 0,
        'at_least_one_green_verification', v_green > 0,
        'evidence_is_fresh', v_total > 0)));
END
$fn$;

-- Splice the delegating branch into the dispatcher without rewriting its body.
DO $splice$
DECLARE v_src text; v_anchor constant text := 'perform public._dev_guard();';
        v_branch constant text :=
          E'\n\n  -- CHANGE #319 — QA blockers 156/157 (version.json served HTML).\n'
          '  if p_name in (''qa-319-156'',''qa-319-157'') then\n'
          '    return public._journey_qa319_version();\n'
          '  end if;';
BEGIN
  SELECT prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'dev_journey_probe';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'dev_journey_probe not found';
  END IF;

  IF position('qa-319-156' in v_src) > 0 THEN
    RAISE NOTICE 'c319 probe branch already present — no-op';
    RETURN;
  END IF;

  IF position(v_anchor in v_src) = 0 THEN
    RAISE EXCEPTION 'c319: anchor % not found in dev_journey_probe', v_anchor;
  END IF;

  v_src := overlay(v_src
                   placing v_anchor || v_branch
                   from position(v_anchor in v_src)
                   for length(v_anchor));

  EXECUTE 'CREATE OR REPLACE FUNCTION public.dev_journey_probe(p_name text) '
       || 'RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER '
       || 'SET search_path TO ''public'' AS $c319body$' || v_src || '$c319body$';
END
$splice$;

-- The journeys are no longer TODO: give them the real assertion text.
UPDATE dev_journeys
   SET steps = jsonb_build_array(
         'Read the most recent post-deploy verification runs (verify_run_log, 24h).',
         'Assert every run parsed a real commit out of version.json (7-40 hex chars) — HTML cannot.',
         'Assert at least one run is green (build_match AND exit_code=0).')
 WHERE name IN ('qa-319-156','qa-319-157')
   AND steps::text LIKE '%TODO implement%';
