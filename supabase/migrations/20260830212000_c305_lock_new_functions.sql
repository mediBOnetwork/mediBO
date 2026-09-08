-- CHANGE #305 — close the hole my own QA pass found.
--
-- `revoke all on function ... from anon, authenticated` reads like a lockdown
-- and is not one: Postgres grants EXECUTE to PUBLIC on every new function, and
-- anon/authenticated inherit it through PUBLIC rather than by a direct grant.
-- Revoking the direct grant they never had is a no-op, so cron_baseline_watch()
-- — SECURITY DEFINER, deletes from cron_job_stats, writes rg_alerts — was
-- reachable with the anon key that ships inside the web bundle and the APK.
-- The revoke has to name PUBLIC. Journey qa-273-47 did not catch this because
-- it pins the six cron RPCs that existed when it was written, so it is widened
-- here to every cron_* / _cron_* function instead of a fixed list.

revoke all on function public.cron_baseline_watch()          from public, anon, authenticated;
revoke all on function public._cron_next_pinned(time, smallint) from public, anon, authenticated;
revoke all on function public._cron_business_open()          from public, anon, authenticated;
revoke all on function public.trg_cron_wake_unfulfilled()    from public, anon, authenticated;
revoke all on function public.trg_cron_wake_offer_expiry()   from public, anon, authenticated;
revoke all on function public.trg_cron_wake_stock_notify()   from public, anon, authenticated;

revoke all on public.cron_job_stats, public.cron_baseline from public, anon, authenticated;
revoke all on public.scheduled_tasks                     from public, anon, authenticated;
