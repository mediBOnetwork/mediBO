-- replay-target: production
-- CHANGE #1823 — the pipeline smoke retries ONCE on a transient lock timeout.
-- Run 35 (the first real smoke after the kill switch came back on, 6 Sep)
-- failed 0/9 on 55P03 "canceling statement due to lock timeout": a co-running
-- migration held a lock past the authenticator role's 8 s lock_timeout. The
-- words and the wait are the backend's (run.js reads test_config.pipeline).
-- Idempotent: the merge worker replays this file on live once.
update public.test_config
   set value = coalesce(value, '{}'::jsonb) || jsonb_build_object(
         'retry_match',   'lock timeout',
         'retry_wait_ms', 3000,
         'retry_note',    'the database refused the pipeline on a lock timeout — another statement held the table, not the feature')
 where key = 'pipeline';
