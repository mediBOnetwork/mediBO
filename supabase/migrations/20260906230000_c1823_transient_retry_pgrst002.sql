-- replay-target: production
-- CHANGE #1823 — batch 620 (6 Sep, 17:12 IST) was FAILED by the critical-path
-- smoke crashing on PostgREST 503 PGRST002 "Could not query the database for the
-- schema cache. Retrying." from test_result_report — the box reloading its schema
-- cache right after the batch's own migrate phase, not the feature (the same
-- refusal recurs and clears within seconds in play_publish.log). The smoke's
-- transient-retry config is now a LIST of refusals, each with its own sentence,
-- with an attempt count — all read by scripts/autotest/api.js and printed
-- verbatim. Idempotent: one UPDATE, no DDL.
update public.test_config
   set value = coalesce(value, '{}'::jsonb) || jsonb_build_object(
         'retry_match',    jsonb_build_array('lock timeout', 'PGRST002'),
         'retry_attempts', 3,
         'retry_wait_ms',  4000,
         'retry_note',     'the database refused this call on a transient error — the box mid-deploy, not the feature',
         'retry_notes',    jsonb_build_object(
            'lock timeout', 'the database refused this call on a lock timeout — another statement held the table, not the feature',
            'PGRST002',     'PostgREST was reloading its schema cache (PGRST002) — the box mid-deploy, not the feature'))
 where key = 'pipeline';
