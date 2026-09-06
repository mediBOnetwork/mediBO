-- replay-target: production
-- CHANGE #1823 — the one transient-refusal retry now covers EVERY rpc of a
-- smoke run (api.js), not only test_pipeline_run: batch 615 (6 Sep) was sunk by
-- devtool.order_pipeline's test_assert_pipeline answering 55P03 "canceling
-- statement due to lock timeout" while the pipeline block passed 9/9 moments
-- later. The sentence run.js prints is the backend's and no longer names the
-- pipeline. Idempotent: one UPDATE, no DDL.
update public.test_config
   set value = coalesce(value, '{}'::jsonb) || jsonb_build_object(
         'retry_note', 'the database refused this call on a lock timeout — another statement held the table, not the feature')
 where key = 'pipeline';
