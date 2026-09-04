-- CHANGE #1055 — zone_pnl_warm() lost the signed-in role and never got it back.
--
-- The regression guard's privileged_rpcs_are_not_anon behaviour went red with:
--
--   RG_FAIL: authenticated cannot EXECUTE zone_pnl_warm() — the lockdown
--   revoked PUBLIC without re-granting the signed-in role, which locks the
--   admin screens out of their own RPC (#436)
--
-- A behaviour failure is never rebaselined, so this is fixed rather than
-- blessed. It is a genuine miss from the zone_pnl work: the function was
-- created, PUBLIC was revoked under rpc_anon_rule's `zone\_%` prefix, and the
-- matching `grant ... to authenticated` was not written.
--
-- The house convention is unambiguous — every other cron-only function under
-- these prefixes is anon:false / authenticated:true, all fourteen of them,
-- including zone_pnl_warm's own two siblings:
--
--   zone_pnl              anon:f auth:t     refresh_storefront_feed      anon:f auth:t
--   zone_pnl_scan         anon:f auth:t     refresh_therapeutic_...      anon:f auth:t
--   zone_avail_counts_tick anon:f auth:t    storefront_home_warm_tick    anon:f auth:t
--   zone_backfill_tick    anon:f auth:t     refresh_medicine_*           anon:f auth:t
--   zone_pnl_warm         anon:f auth:F  <- the only outlier
--
-- anon stays revoked: the prefix rule exists because these are unbounded
-- recompute jobs and the anon key ships inside the web bundle and the APK.
--
-- Idempotent: revoke/grant are declarative.

begin;

revoke all    on function public.zone_pnl_warm() from public, anon;
grant  execute on function public.zone_pnl_warm() to authenticated;

commit;
