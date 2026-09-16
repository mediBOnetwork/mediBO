-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2063 — give the Customers door a home again.
--
-- The nav-orphan gate (scripts/check_nav_orphans.sh, CMD #1893) aborted the
-- deploy before a change number was burned:
--
--   1 feature(s) lost their only door when the "Also here" strip was removed.
--     - admin.customers (Customers) — home_tab=customers surface=dashboard
--
-- It is right: the strip is gone, admin.customers is ACTIVE and homed on the
-- customers tab, and it carries no dashboard_section — so the tile's tap lands
-- in the shell's default branch and the customer list has no door at all.
-- Every deploy on this box fails the gate until it has one, which is why this
-- lands here rather than in whichever command happens to notice.
--
-- 'onboarding' is where it belongs: that section already holds Add customer,
-- Customer documents and Supplier accounts — the account group. field_growth
-- is leads/routes/staff, needs_now is the work queue; a customer LIST is
-- neither.
--
-- Data only, idempotent, and it does not overwrite a section someone else set.
-- ═══════════════════════════════════════════════════════════════════════════

update public.feature_registry
   set dashboard_section = 'onboarding'
 where feature_key = 'admin.customers'
   and coalesce(dashboard_section, '') = '';
