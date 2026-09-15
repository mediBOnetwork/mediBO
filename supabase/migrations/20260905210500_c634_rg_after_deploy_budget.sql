-- CHANGE #634 — un-park rg_after_deploy, the guard every command completes on.
--
-- #1361 measured rg_watch() at 53.5 s and widened this task 120 s -> 600 s
-- rather than exempting it, on the stated principle that exempting a task
-- hides the very signal the budget guard exists to give. That principle still
-- holds; the measurement no longer does. At 19:14 UTC today the same task ran
-- for 206,265 ms — 34.4% of its 600 s interval, over the 20% budget — and the
-- dispatcher parked it. Parked, NOTHING re-runs the guard after a deploy:
-- rg_watch_2h is the only other caller, so for up to two hours every
-- dev_cmd_complete reads a verdict older than its own deploy. #634 hit exactly
-- that.
--
-- rg_check IS a catalogue-wide scan and the catalogue keeps growing, so it is
-- widened again rather than exempted: 206 s of 1800 s is 11.5%, which leaves
-- room for the scan to grow by half again before the guard fires. The task is
-- gated on `a deploy landed since the last rg run`, so a wider interval costs
-- nothing on a quiet lane — it only means the post-deploy verdict lands within
-- thirty minutes instead of ten.
update public.cron_task
   set base_interval_s    = 1800,
       current_interval_s = 1800,
       enabled            = true,
       parked_reason      = null,
       parked_at          = null,
       parked_ms          = null,
       note = coalesce(note,'') || ' #634: interval 600s->1800s — it measured '
              '206.3 s, 34.4% of its old interval, and the dispatcher parked it, '
              'which left every completion reading a pre-deploy verdict.'
 where name = 'rg_after_deploy';
