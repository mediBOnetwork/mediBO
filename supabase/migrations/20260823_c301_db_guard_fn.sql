-- CHANGE #301 — who may drive the DB lane.
--
-- _dev_guard() answers "service_role JWT or super_admin", which is the right
-- question for an app-facing RPC. But the heaviest agent DB work arrives on a
-- DIRECT postgres session (psql / the Supabase management SQL endpoint) where
-- there is no JWT at all — and that is exactly the session that must be able to
-- take a lock and cap itself. session_user is untouched by SECURITY DEFINER, so
-- this stays an honest test of who actually connected.
create or replace function public._db_guard()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if session_user in ('postgres', 'supabase_admin') then
    return;
  end if;
  perform public._dev_guard();
end $$;

revoke all on function public._db_guard() from public;
grant execute on function public._db_guard() to authenticated, service_role;
