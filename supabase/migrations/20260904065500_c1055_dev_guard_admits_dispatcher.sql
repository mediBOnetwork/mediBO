-- CHANGE #1055 (follow-on) — teach _dev_guard() about the ONE caller that has
-- no token because it is not a request.
--
-- Patching the sweeps one function at a time does not converge. The chain is
-- dev_cmd_autofinish_sweep -> dev_cmd_autofinish -> dev_cmd_finish_state ->
-- ... and every link calls _dev_guard() for itself, so each fix just moved the
-- 'dev_queue: not authorized' one frame deeper:
--
--   PL/pgSQL function dev_cmd_finish_state(bigint) line 7 at PERFORM
--   PL/pgSQL function dev_cmd_autofinish(bigint,text) line 6 at assignment
--   PL/pgSQL function dev_cmd_autofinish_sweep() line 11 at assignment
--
-- The guard is the right place, because the thing it is missing is a CONCEPT,
-- not a special case: _dev_guard() models "who is asking" as either a
-- service_role JWT or a signed-in super_admin, and pg_cron is neither. It is
-- the database's own scheduler, running as `postgres` with no request context
-- at all. That is why CHANGE #571's park-resume sweep (2099 consecutive
-- failures) and CHANGE #369's autofinish backstop (719) have never once run.
--
-- WHY THIS IS NOT A WEAKENING. The new branch requires session_user to be
-- postgres/supabase_admin AND no JWT claims of any kind to be present:
--
--   * PostgREST — the only path the anon key and a user JWT can travel —
--     connects as `authenticator` and SET ROLEs to anon/authenticated. SET ROLE
--     changes current_user, never session_user, so no API request can reach
--     this branch however it is shaped, with or without a token.
--   * Edge functions reach the database through that same PostgREST path.
--   * What is left is a direct libpq connection as postgres, which requires the
--     chmod-600 admin credential in ~/.medibo/dburl. A holder of that already
--     has unrestricted rights and could execute any of these bodies directly.
--
-- So the branch grants no capability to any principal that did not already
-- have it; it lets the scheduler through a door built only for HTTP callers.
-- Deliberately NOT gated on is_superuser: on Supabase `postgres` has
-- rolsuper = f and current_setting('is_superuser') = 'off', so such a test
-- would be permanently false and would leave both sweeps as dead as they are.
--
-- Idempotent: create or replace.

begin;

create or replace function public._dev_guard()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
BEGIN
  -- CHANGE #1055 — the local scheduler, which carries no request context.
  IF coalesce(current_setting('request.jwt.claims', true), '') = ''
     AND coalesce(current_setting('request.jwt.claim',  true), '') = ''
     AND session_user IN ('postgres', 'supabase_admin')
  THEN
    RETURN;
  END IF;

  IF NOT (coalesce(auth.jwt()->>'role','') = 'service_role' OR get_my_role() = 'super_admin') THEN
    RAISE EXCEPTION 'dev_queue: not authorized';
  END IF;
END $function$;

commit;
