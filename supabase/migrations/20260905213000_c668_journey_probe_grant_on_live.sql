-- CHANGE #668 — give dev_journey_probe back its service_role grant on LIVE.
--
-- The proof chain (CLAUDE.md §14) runs journeys through
--   devcmd.sh journeys_run -> dev_journeys_plan (control plane)
--                          -> dev_journey_probe (PRODUCTION, by _PROD_FN_RE)
-- and a probe RPC that errors is recorded as `skipped`, never as failed. So
-- when production's copy of dev_journey_probe(text) came back from a replay
-- with acl `postgres=X/postgres` and nothing for service_role, every journey in
-- every area started reporting skipped — 24 of 24 on this command — and the
-- finish gate reads that as "journeys not passed" with no error anywhere. A
-- silent, fleet-wide gate failure that looks like a slow command.
--
-- The control plane still carries the grant (service_role=X/postgres), which is
-- what makes the drift visible: same function, same signature, one database
-- missing one GRANT. This restores it wherever the function exists, so the file
-- is correct on production, on the control plane and on a build branch alike.
--
-- Idempotent, and deliberately service_role only: _dev_guard() inside the
-- function still admits nothing else, and granting to `authenticated` would put
-- a probe that writes into reach of every logged-in account.

do $c668grant$
begin
  if to_regprocedure('public.dev_journey_probe(text)') is not null then
    execute 'grant execute on function public.dev_journey_probe(text) to service_role';
  end if;
end
$c668grant$;

-- The guard: if the function is here, the grant must be too.
do $c668grantguard$
declare v_acl text;
begin
  if to_regprocedure('public.dev_journey_probe(text)') is null then
    raise notice 'c668: dev_journey_probe is not on this database — nothing to grant';
    return;
  end if;
  select coalesce(array_to_string(p.proacl, '|'), '') into v_acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';
  if position('service_role=X' in v_acl) = 0 then
    raise exception 'c668: dev_journey_probe still has no service_role execute grant (acl=%)', v_acl;
  end if;
end
$c668grantguard$;
