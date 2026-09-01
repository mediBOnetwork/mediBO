-- CHANGE #428 (4/4) — the claim gate stops re-implementing the old rules.
--
-- Fixing dev_cmd_autochain was only half of it: dev_cmd_claim carries its OWN
-- copy of the collision test, and it was the permissive one —
--   dev_paths_overlap(dev_cmd_footprint(b.id), c.predicted_files)
-- against every BUILDING row. dev_paths_overlap() matches globs, and
-- dev_cmd_footprint() falls back to the PREDICTION for a command that has not
-- leased anything yet. So a single building command with a broad prediction
-- ('lib/screens/supplier/%', or cust_pay_panel.dart pulled in by the word
-- "bill") could make the entire pending queue unclaimable — the same
-- serialisation this change exists to end, one layer further down, and
-- invisible because a refused claim just looks like an idle runner. Two of the
-- five runners were idle against a 28-command queue when this landed.
--
-- It now asks the same question the chainer asks: dev_paths_conflict() against
-- the blocker's ACTUAL leases — two exact, non-shared, equal paths. The empty
-- reply's sentence stops asserting a chain that may not exist, and comes from
-- ui_copy, so re-wording it is an UPDATE rather than a deploy.
--
-- Idempotent: create or replace / on conflict do nothing.
insert into ui_copy (key, value) values
  ('dev_queue.claim_blocked', to_jsonb('Every pending command is held behind a file another build is holding right now.'::text)),
  ('dev_queue.claim_empty',   to_jsonb('Queue empty.'::text))
on conflict (key) do nothing;

create or replace function public.dev_cmd_claim(p_agent text, p_routes text[] default null, p_prefer_area text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v jsonb; v_res jsonb; v_blocked int; v_adm jsonb; v_scope jsonb;
        v_fact boolean; v_msg text;
BEGIN
  PERFORM _dev_guard();
  IF (_sec_cfg()->>'frozen')::boolean THEN RETURN jsonb_build_object('empty',true,'frozen',true); END IF;
  IF (sec_check_budget()->>'over')::boolean THEN RETURN jsonb_build_object('empty',true,'budget_paused',true); END IF;

  -- CMD #368 — admission control. Refuse BEFORE the runner boots a context, so
  -- an overloaded instance costs a 45 s sleep instead of an hour of crawling.
  v_adm := db_admission_check(p_agent);
  IF coalesce((v_adm->>'admit')::boolean, true) = false THEN
    RETURN jsonb_build_object('empty', true, 'db_busy', true,
      'retry_after_seconds', coalesce((v_adm->>'retry_after_seconds')::int, 45),
      'reason', v_adm->>'label', 'admission', v_adm);
  END IF;

  SELECT coalesce((value->'chain'->>'require_lease')::boolean, true) INTO v_fact
    FROM dev_runner_config WHERE key='worker_pool';
  v_fact := coalesce(v_fact, true);

  UPDATE dev_commands dc SET status='building', claimed_by=p_agent, started_at=now(), heartbeat_at=now(),
         resume_count = resume_count + CASE WHEN dc.steps_done > 0 THEN 1 ELSE 0 END
  WHERE dc.id = (
    SELECT c.id FROM dev_commands c
    WHERE c.status='pending'
      AND (p_routes IS NULL OR c.route = ANY(p_routes))
      AND NOT EXISTS (SELECT 1 FROM dev_commands d WHERE d.id = ANY(c.depends_on) AND d.status <> 'completed')
      -- CHANGE #428 — a REAL conflict only: two exact, non-shared, equal paths,
      -- and (by default) against what the other build actually HOLDS, not what
      -- it was guessed to touch. Anything looser and one broad prediction
      -- freezes the whole queue.
      AND NOT EXISTS (
        SELECT 1 FROM dev_commands b
        WHERE b.status = 'building' AND b.id <> c.id
          AND coalesce(array_length(
                dev_paths_conflict(
                  CASE WHEN v_fact THEN dev_cmd_leased_footprint(b.id)
                       ELSE dev_cmd_footprint(b.id) END,
                  c.predicted_files), 1), 0) > 0)
    ORDER BY c.urgent DESC,
             (p_prefer_area IS NOT NULL AND c.area IS NOT DISTINCT FROM p_prefer_area) DESC,
             c.priority, c.id
    FOR UPDATE OF c SKIP LOCKED LIMIT 1
  )
  RETURNING to_jsonb(dc) INTO v;
  IF v IS NULL THEN
    SELECT count(*) INTO v_blocked FROM dev_commands c
     WHERE c.status='pending' AND (p_routes IS NULL OR c.route = ANY(p_routes));
    SELECT value#>>'{}' INTO v_msg FROM ui_copy
     WHERE key = CASE WHEN v_blocked > 0 THEN 'dev_queue.claim_blocked' ELSE 'dev_queue.claim_empty' END;
    RETURN jsonb_build_object('empty', true, 'pending_blocked', v_blocked,
      'reason', coalesce(v_msg, CASE WHEN v_blocked > 0
        THEN 'Every pending command is held behind a file another build is holding right now.'
        ELSE 'Queue empty.' END));
  END IF;
  v_res := _dev_resume_block(v);
  -- CMD #368 — grade the QA depth from real scope the moment the row is owned,
  -- and hand the runner the guardrails its session is already running under.
  v_scope := dev_qa_scope((v->>'id')::bigint);
  RETURN v || jsonb_build_object('resume', v_res,
                                 'is_resume', coalesce((v_res->>'is_resume')::boolean, false),
                                 'qa_scope', v_scope,
                                 'session_guard', db_guard_check());
END $function$;

-- The admission cap was the LAST thing holding runners idle once the chains
-- were gone: db_admission_check refused at max_concurrent_builds=3 while the
-- pool runs 5 slots, with measured pressure at 19/60 connections (32%), zero
-- statement timeouts and no long transaction — nowhere near the 75% / 3 / 120 s
-- ceilings, which stay authoritative and refuse on their own. Raised to match
-- the live slot count; reversible with one admission_set and no deploy.
update public.dev_admission_config
   set max_concurrent_builds = greatest(max_concurrent_builds, 5),
       updated_at = now(), updated_by = 'change-428'
 where id and max_concurrent_builds < 5;
