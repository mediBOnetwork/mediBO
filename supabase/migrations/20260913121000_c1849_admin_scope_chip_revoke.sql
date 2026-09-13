-- ===========================================================================
-- CMD #1849 — repair: admin_scope_chip() is executable by anon on production.
--
-- The regression guard's privileged_rpcs_are_not_anon behaviour went red on:
--   "anon can EXECUTE admin_scope_chip() — the anon key ships inside the web
--    bundle and the APK, so that is a PUBLIC endpoint on an admin surface."
--
-- The build branch already carries the right ACL (postgres, authenticated),
-- so this is production drifting back to Postgres's default GRANT TO PUBLIC —
-- which every function picks up the moment it is dropped and recreated rather
-- than replaced. Stating the revoke in a migration file is what makes it
-- survive the next recreation: the replay runs it again.
--
-- Idempotent, and a no-op wherever the function does not exist.
-- ===========================================================================
do $acl$
declare r record;
begin
  for r in select p.oid::regprocedure::text as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'admin_scope_chip'
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end $acl$;
