-- CMD #1852 (h) — GRANT REVIEW.
--
-- Every function this command added or re-issued, reduced to the smallest role
-- that has to reach it. Two of them were reachable by ANON and neither should
-- have been:
--   * test_journal_attach_all() CREATES TRIGGERS — it inherited the schema's
--     default execute grant simply by being created in public;
--   * test_session_purge() carried #573's grants forward through
--     `create or replace`, so anon could call the wipe. It refuses inside
--     _test_guard(), but a guard is the second lock, not the first.
--
-- Everything that only ever runs INSIDE another SECURITY DEFINER function
-- (the outcome renderer, the health probe, the pk helpers, the reversal) is
-- service_role only: a definer function executes as its owner, so narrowing
-- the caller grant costs the app nothing.

begin;

revoke all on function public.test_journal_attach_all() from public, anon, authenticated;
grant execute on function public.test_journal_attach_all() to service_role;

revoke all on function public._test_session_journal() from public, anon, authenticated;
grant execute on function public._test_session_journal() to service_role;

revoke all on function public.test_session_purge(bigint, int) from public, anon;
grant execute on function public.test_session_purge(bigint, int) to authenticated, service_role;

revoke all on function public.test_session_outcome(bigint) from public, anon, authenticated;
grant execute on function public.test_session_outcome(bigint) to service_role;

revoke all on function public.test_session_purge_health() from public, anon, authenticated;
grant execute on function public.test_session_purge_health() to service_role;

commit;

-- Both of these were re-issued by this command and both carried anon forward.
-- The list is admin-only by its guard; the sweep now PURGES, so anon being
-- able to fire it at all is a wipe an unauthenticated request could schedule.
begin;
revoke all on function public.test_session_list(int) from public, anon;
grant execute on function public.test_session_list(int) to authenticated, service_role;

revoke all on function public.test_session_expire_sweep() from public, anon, authenticated;
grant execute on function public.test_session_expire_sweep() to service_role;
commit;
