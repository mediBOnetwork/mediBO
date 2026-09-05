-- replay-target: production
-- (staff_nav_tab is on the control plane too, but its icon_key foreign key points
--  at ui_icon, which is not — so these rows belong to the app database only.)
-- CHANGE #637 — the staff IA journey stops reporting an empty lookup table as
-- a broken navigation.
--
-- `c1016-staff-ia` is required for every admin-area command and was skipped on
-- the build branch with needs_cast, saying "staff_nav_tab holds 0 tabs,
-- expected 6 · super admin sees 0 tabs · More grid has only 0 items". The
-- catalogue it judges is NOT missing: the branch carries 172 feature_registry
-- rows and 26 nav_category rows. What is missing is two small lookup tables
-- that a `pg_dump --schema-only` clone cannot inherit and that no NEW migration
-- has re-seeded — ui_icon (3 rows, all added since the branch was cut) and
-- staff_nav_tab (0). staff_nav_tab.icon_key is a foreign key into ui_icon, so
-- the empty icon table is what actually keeps the tabs out, and with no tabs
-- staff_home() returns unknown_tab for every one of them.
--
-- Both are seeded on production by 20260903_c1016_staff_ia.sql with exactly
-- these values. Asserted again here, idempotently, so a database built from
-- migrations has them: `do nothing` makes this a no-op on production and on
-- any database that already carries a row.

begin;

-- The six icon keys the tabs name. Labels are the words already used for these
-- icons elsewhere in ui_icon.
insert into public.ui_icon (icon_key, label) values
  ('dashboard', 'Dashboard'),
  ('people',    'People'),
  ('inventory', 'Inventory'),
  ('truck',     'Truck'),
  ('rupee',     'Rupee'),
  ('apps',      'Apps')
on conflict (icon_key) do nothing;

insert into public.staff_nav_tab
  (tab_key, label_key, icon_key, route_key, anchor_feature, sort_order)
values
  ('dashboard', 'staff_nav.tab_dashboard', 'dashboard', 'dashboard',   'admin.dashboard',   10),
  ('customers', 'staff_nav.tab_customers', 'people',    'customers',   'admin.customers',   20),
  ('suppliers', 'staff_nav.tab_suppliers', 'inventory', 'suppliers',   'admin.suppliers',   30),
  ('fulfill',   'staff_nav.tab_fulfill',   'truck',     'fulfillment', 'admin.fulfillment', 40),
  ('money',     'staff_nav.tab_money',     'rupee',     'money_home',  null,                50),
  ('more',      'staff_nav.tab_more',      'apps',      'more',        null,                60)
on conflict (tab_key) do nothing;

commit;
