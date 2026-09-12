-- CHANGE #474 — QA round 1 finding, fixed.
--
-- THE HOLE. `_ops_admin()` (and `_test_guard()`, which it was modelled on)
-- admitted a caller whose `current_user` was postgres / supabase_admin /
-- service_role. Both functions are SECURITY DEFINER and owned by postgres, so
-- inside them `current_user` is ALWAYS 'postgres' — the owner — no matter who
-- called. The check was therefore true for everybody, and the `is_admin()`
-- fallback below it was unreachable.
--
-- Proved on the live build before this migration: a session for
-- test.cust1@medibo.in (a customer, in no admin table) called
-- ops_runbooks_home() through PostgREST and got the full runbook payload back
-- instead of the refusal.
--
-- THE FIX. `session_user` is the role the client actually authenticated as and
-- SECURITY DEFINER does not change it:
--   * PostgREST (any JWT, any role)  -> session_user = 'authenticator'
--   * psql / pg_cron / the dispatcher -> session_user = 'postgres'
-- So a service caller is recognised by its JWT ROLE CLAIM, a direct database
-- session by session_user, and everybody else falls through to is_admin() the
-- way the function always intended.
--
-- `_test_guard()` carries the identical defect and gates test_session_start /
-- test_session_end / test_session_purge — an authenticated customer could start
-- a test session and purge its data. Same fix, same reason. Tightening a guard
-- that admitted everyone is not an auth change that needs asking about; it is
-- the guard finally doing what it says.
--
-- Idempotent: create or replace, no state.

create or replace function public._ops_admin()
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
     or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '')
        = 'service_role'
     or session_user in ('postgres', 'supabase_admin', 'service_role') then
    return true;
  end if;
  return public.is_admin();
exception when others then
  return public.is_admin();
end $$;

create or replace function public._test_guard()
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true), '') = 'service_role'
     or coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '')
        = 'service_role'
     or session_user in ('postgres', 'supabase_admin', 'service_role') then
    return true;
  end if;
  return public.is_admin();
exception when others then
  return public.is_admin();
end $$;
