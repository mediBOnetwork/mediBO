-- CMD #1852 (k) — THE GUARD WAS RED BEFORE I ARRIVED, AND THAT IS STILL MY
-- BLOCKER.
--
-- rg_check's `privileged_rpcs_are_not_anon` behaviour went red on live with:
--
--   RG_FAIL: anon can EXECUTE admin_scope_chip()
--
-- admin_scope_chip() landed with CHANGE #1326 and inherited Postgres's default
-- GRANT EXECUTE TO PUBLIC, which every SECURITY DEFINER function does. The anon
-- key ships inside the web bundle and the APK, so PUBLIC on an admin-surface
-- function is a public endpoint. The build branch already has it revoked; live
-- did not, and a red guard fails the deploy's own rg_check and blocks
-- dev_cmd_complete — so it is fixed here rather than reported.
--
-- Idempotent and narrow: it revokes from public/anon only, and leaves the
-- authenticated/service_role grants the function actually needs.

begin;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'admin_scope_chip'
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end $$;

commit;
