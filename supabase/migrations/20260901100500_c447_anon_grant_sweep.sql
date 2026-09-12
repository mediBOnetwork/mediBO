-- CMD #447 — the anon-grant lockdown, applied as a SWEEP rather than one name.
--
-- rg_check went red mid-command with
--   RG_FAIL: anon can EXECUTE admin_claim_queue(p_limit integer)
-- and, once that was revoked, immediately with admin_bill_queue(p_limit integer).
-- Every SECURITY DEFINER function inherits Postgres's default GRANT TO PUBLIC,
-- so an admin RPC is anon-callable the moment it is created unless the author
-- remembers the revoke — and the anon key ships inside the web bundle and the
-- APK, so "anon can execute" means a public endpoint on an admin surface.
-- That is the #436 failure, and it is the same shape as #25/#353/#395/#422.
--
-- The guard names ONE offender per run, so fixing them one at a time is a queue
-- of red builds. This sweeps every function rpc_anon_rule considers privileged
-- and rpc_anon_allow has not excused, which is exactly the guard's own
-- predicate — so a new admin_* RPC created after this migration is locked by
-- re-running it rather than by remembering a line.
--
-- Idempotent by construction: REVOKE of a grant that is already gone and GRANT
-- of one already held are both no-ops, and the loop reads the live catalog, so
-- a resumed worker re-applying this is silent. It also never names a function,
-- so it cannot fail on a fresh rebuild where the migration ordering puts it
-- before the RPC it would have named.
do $$
declare f record; n int := 0;
begin
  for f in
    select p.oid,
           p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as sig
      from pg_proc p
      join pg_namespace nsp on nsp.oid = p.pronamespace
     where nsp.nspname = 'public'
       and p.prokind = 'f'
       and exists (select 1 from public.rpc_anon_rule r where p.proname like r.prefix)
       and not exists (select 1 from public.rpc_anon_allow a where a.fn_name = p.proname)
  loop
    -- The outer lock only. Every one of these keeps its own body-level role
    -- check (is_admin() / get_my_role()); #436 exists because one had only the
    -- outer lock, so this migration must never be read as a substitute for it.
    execute format('revoke execute on function public.%s from public, anon', f.sig);
    execute format('grant  execute on function public.%s to authenticated, service_role', f.sig);
    n := n + 1;
  end loop;
  raise notice 'c447: anon-grant sweep locked % privileged RPC(s)', n;
end $$;
