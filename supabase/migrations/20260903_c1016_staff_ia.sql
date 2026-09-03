-- CHANGE #1016 — Staff app information architecture.
--
-- Five verbs + More. One home per feature. The registry is the map; every
-- resolver below reads it, and nothing in Dart decides where a feature lives.
--
--   Dashboard (see) · Customers (manage) · Suppliers (manage) · Fulfill (do)
--   · Money (settle) · More (grid: catalogue, communication, marketing,
--   support, users & access, system & dev tools)
--
-- Idempotent throughout: a resumed worker re-applies this file and every
-- statement is a no-op the second time.

-- ─────────────────────────────────────────────────────────────────────────────
-- PART 1 · the model
-- ─────────────────────────────────────────────────────────────────────────────

-- 1a. a category knows which tab is its home.
alter table public.nav_category add column if not exists home_tab text;

-- 1b. a registry row can be an ALIAS: it stays active for access resolution
--     (grants key on it, _feature_canon resolves through it) but no nav
--     resolver draws it. merged_into names the ONE tile that is its home now.
alter table public.feature_registry add column if not exists merged_into text;
alter table public.feature_registry drop constraint if exists feature_registry_surface_ck;
alter table public.feature_registry add constraint feature_registry_surface_ck check (
  surface = any (array['dashboard','profile','both','dev_tools','fulfill_tab',
                       'customer_shop','customer_tab','supplier_tab','customer_menu','alias'])
  and (surface <> 'profile'
       or (category = 'identity'
           and feature_key = any (array['identity.view_profile','identity.logout']))));

insert into public.surface_audience(surface, label, resolver, audience)
values ('alias', 'Alias (access identity only, never a tile)', 'access_effective()',
        array['admin','super_admin','partner','worker'])
on conflict (surface) do update set audience = excluded.audience;

-- 1c. the tab bar every staff login shares. Same shape as customer_nav_slot.
create table if not exists public.staff_nav_tab (
  tab_key     text primary key,
  label_key   text not null,
  icon_key    text not null references public.ui_icon(icon_key) on update cascade,
  route_key   text not null,
  anchor_feature text,              -- the feature whose View toggle opens the tab itself
  sort_order  int  not null default 100,
  is_active   boolean not null default true,
  updated_at  timestamptz not null default now()
);

-- 1d. an old route key that must land on a new home.
create table if not exists public.nav_redirect (
  from_route  text primary key,
  to_route    text not null,
  only_role   text,                 -- null = every role; 'partner' = partner logins only
  when_no_seed boolean not null default false,
  note        text
);

-- 1e. the parity baseline: every feature the registry held BEFORE this change,
--     frozen once. The gate proves each one still has exactly one home.
create table if not exists public.nav_parity_baseline (
  feature_key   text primary key,
  label         text,
  surface       text,
  group_label   text,
  route_key     text,
  deep_link     text,
  roles_allowed text[],
  canonical_key text,
  is_active     boolean,
  snapped_at    timestamptz not null default now()
);
insert into public.nav_parity_baseline(feature_key, label, surface, group_label, route_key,
                                       deep_link, roles_allowed, canonical_key, is_active)
select f.feature_key, f.label, f.surface, f.group_label, f.route_key, f.deep_link,
       f.roles_allowed, f.canonical_key, f.is_active
  from public.feature_registry f
 where f.surface in ('dashboard','both','dev_tools','fulfill_tab','customer_tab','supplier_tab','profile')
   and f.is_active
   and not exists (select 1 from public.nav_parity_baseline)
on conflict (feature_key) do nothing;

-- 1f. icons the tab bar needs that the catalogue did not hold.
insert into public.ui_icon(icon_key, label) values ('apps', 'More (grid)') on conflict (icon_key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- PART 2 · homes (categories), the tab bar, and every row's new place
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.nav_category(category_key, label, icon_key, sort_order, is_active, home_tab) values
  ('home_dashboard', 'Dashboard',            'dashboard',  10, true, 'dashboard'),
  ('home_customers', 'Customers',            'people',     20, true, 'customers'),
  ('home_suppliers', 'Suppliers',            'inventory',  30, true, 'suppliers'),
  ('home_fulfill',   'Fulfill',              'truck',      40, true, 'fulfill'),
  ('home_money',     'Money',                'rupee',      50, true, 'money'),
  ('more_catalogue', 'Catalogue & pricing',  'book',       61, true, 'more'),
  ('more_comms',     'Communication',        'forum',      62, true, 'more'),
  ('more_marketing', 'Marketing',            'campaign',   63, true, 'more'),
  ('more_support',   'Support & feedback',   'support_agent', 64, true, 'more'),
  ('more_users',     'Users & access',       'admin_panel', 65, true, 'more'),
  ('more_system',    'System & Dev tools',   'settings',   66, true, 'more')
on conflict (category_key) do update
   set label = excluded.label, icon_key = excluded.icon_key,
       sort_order = excluded.sort_order, is_active = true, home_tab = excluded.home_tab;

insert into public.staff_nav_tab(tab_key, label_key, icon_key, route_key, anchor_feature, sort_order) values
  ('dashboard', 'staff_nav.tab_dashboard', 'dashboard', 'dashboard',   'admin.dashboard',   10),
  ('customers', 'staff_nav.tab_customers', 'people',    'customers',   'admin.customers',   20),
  ('suppliers', 'staff_nav.tab_suppliers', 'inventory', 'suppliers',   'admin.suppliers',   30),
  ('fulfill',   'staff_nav.tab_fulfill',   'truck',     'fulfillment', 'admin.fulfillment', 40),
  ('money',     'staff_nav.tab_money',     'rupee',     'money_home',  null,                50),
  ('more',      'staff_nav.tab_more',      'apps',      'more',        null,                60)
on conflict (tab_key) do update
   set label_key = excluded.label_key, icon_key = excluded.icon_key,
       route_key = excluded.route_key, anchor_feature = excluded.anchor_feature,
       sort_order = excluded.sort_order, is_active = true, updated_at = now();

-- 2a. the words. Shopkeeper words, no jargon.
insert into public.ui_copy(key, value) values
  ('staff_nav.tab_dashboard', to_jsonb('Dashboard'::text)),
  ('staff_nav.tab_customers', to_jsonb('Customers'::text)),
  ('staff_nav.tab_suppliers', to_jsonb('Suppliers'::text)),
  ('staff_nav.tab_fulfill',   to_jsonb('Fulfill'::text)),
  ('staff_nav.tab_money',     to_jsonb('Money'::text)),
  ('staff_nav.tab_more',      to_jsonb('More'::text)),
  ('staff_home.money_title',  to_jsonb('Money'::text)),
  ('staff_home.money_subtitle', to_jsonb('Bills, payments, settlements and the books.'::text)),
  ('staff_home.more_title',   to_jsonb('More'::text)),
  ('staff_home.more_subtitle', to_jsonb('Everything else, in one place.'::text)),
  ('staff_home.search_hint',  to_jsonb('Find a screen…'::text)),
  ('staff_home.recents_label', to_jsonb('Recent'::text)),
  ('staff_home.empty_label',  to_jsonb('Nothing here for your login yet.'::text)),
  ('staff_home.search_empty', to_jsonb('No screen matches that.'::text)),
  ('staff_home.strip_label',  to_jsonb('Also here'::text)),
  ('staff_home.stats_label',  to_jsonb('Right now'::text)),
  ('staff_home.unused_report', to_jsonb('Screens nobody opened'::text)),
  ('staff_home.pending_bills', to_jsonb('Supplier bills to check'::text)),
  ('nav.legacy_layout_note',  to_jsonb('Old layout (staff_layout_v1) — switches off automatically.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- renames: the jargon Om named goes, everywhere it was printed.
update public.ui_copy set value = to_jsonb('Items to review ({count})'::text), updated_at = now()
 where key = 'admin_supplier.tab_staging';
update public.ui_copy set value = to_jsonb('Supplier items to review'::text), updated_at = now()
 where key = 'admin_supplier.staging_title';
update public.ui_copy set value = to_jsonb('0 items waiting for review'::text), updated_at = now()
 where key = 'admin_supplier.empty_staging';
update public.ui_copy set value = to_jsonb('Screen audit'::text), updated_at = now()
 where key = 'surface_map.title';
update public.ui_copy set value = to_jsonb('Only a super admin can read the screen audit.'::text), updated_at = now()
 where key = 'surface_map.denied';
update public.ui_copy set value = to_jsonb('The screen audit could not be loaded.'::text), updated_at = now()
 where key = 'surface_map.load_failed';
update public.ui_copy set value = to_jsonb('Stuck work'::text), updated_at = now()
 where key in ('ops.title', 'admin_nav.overflow_ops_queues');

-- 2b. every staff row's home. category = the home; group_label = the section
--     inside it. Labels change only where the old word was jargon.
create or replace function public._c1016_place(p_key text, p_category text, p_group text,
                                               p_label text default null, p_sort int default null)
returns void language plpgsql as $$
begin
  update public.feature_registry
     set category    = p_category,
         group_label = p_group,
         label       = coalesce(p_label, label),
         sort_order  = coalesce(p_sort, sort_order)
   where feature_key = p_key;
end $$;

-- Dashboard: the tab itself and nothing else.
select public._c1016_place('admin.dashboard', 'home_dashboard', 'Home', null, 5);

-- Customers (manage)
select public._c1016_place('admin.customers',          'home_customers', 'Customers', null, 10);
select public._c1016_place('admin.cust_tab.customers', 'home_customers', 'Customers');
select public._c1016_place('admin.cust_tab.cart',      'home_customers', 'Customers');
select public._c1016_place('admin.cust_tab.pending',   'home_customers', 'Customers');
select public._c1016_place('admin.cust_tab.leads',     'home_customers', 'Customers');
select public._c1016_place('admin.cust_tab.s_leads',   'home_customers', 'Customers');
select public._c1016_place('admin.cust_tab.routes',    'home_customers', 'Customers');
select public._c1016_place('partner.kyc_review',       'home_customers', 'Customers', 'KYC review', 20);
select public._c1016_place('admin.add_customer',       'home_customers', 'Customers', 'Add customer', 30);
select public._c1016_place('admin.deletion_requests',  'home_customers', 'Customers', 'Deletion requests', 40);
select public._c1016_place('admin.reorder',            'home_customers', 'Customers', 'Reorders & auto-reorders', 50);
select public._c1016_place('admin.customer_360',       'home_customers', 'Customers', 'Customer page', 60);

-- Suppliers (manage)
select public._c1016_place('admin.suppliers',          'home_suppliers', 'Suppliers', null, 10);
select public._c1016_place('admin.sup_tab.suppliers',  'home_suppliers', 'Suppliers');
select public._c1016_place('admin.sup_tab.pending',    'home_suppliers', 'Suppliers');
select public._c1016_place('admin.sup_tab.leads',      'home_suppliers', 'Suppliers');
select public._c1016_place('admin.sup_tab.staging',    'home_suppliers', 'Suppliers', 'Items to review');
select public._c1016_place('admin.add_supplier',       'home_suppliers', 'Suppliers', 'Add supplier', 20);
select public._c1016_place('admin.unmapped_companies', 'home_suppliers', 'Companies', 'Unmapped companies', 30);
select public._c1016_place('admin.mr',                 'home_suppliers', 'Companies', 'MR registrations', 40);
select public._c1016_place('admin.companies',          'home_suppliers', 'Companies', 'Company registrations', 50);
select public._c1016_place('admin.supplier_accounts',  'home_suppliers', 'Suppliers', 'Supplier accounts', 60);
select public._c1016_place('partner.documents',        'home_suppliers', 'Partner', 'My documents', 70);

-- Fulfill (do)
select public._c1016_place('admin.fulfillment',        'home_fulfill', 'Pipeline', null, 5);
select public._c1016_place('fulfill.ops_board',        'home_fulfill', 'Pipeline');
select public._c1016_place('fulfill.customer_order',   'home_fulfill', 'Pipeline', 'Orders');
select public._c1016_place('fulfill.supplier_inquiry', 'home_fulfill', 'Pipeline', 'Inquiry');
select public._c1016_place('fulfill.supplier_order',   'home_fulfill', 'Pipeline', 'Supplier orders');
select public._c1016_place('fulfill.supplier_shop',    'home_fulfill', 'Pipeline');
select public._c1016_place('fulfill.warehouse',        'home_fulfill', 'Pipeline', 'Warehouse');
select public._c1016_place('fulfill.bag',              'home_fulfill', 'Pipeline');
select public._c1016_place('fulfill.pack',             'home_fulfill', 'Pipeline');
select public._c1016_place('fulfill.delivery',         'home_fulfill', 'Pipeline');
select public._c1016_place('fulfill.dispute',          'home_fulfill', 'Pipeline', 'Disputes');
select public._c1016_place('fulfill.exceptions',       'home_fulfill', 'Pipeline');
select public._c1016_place('fulfill.order_timeline',   'home_fulfill', 'Orders', 'Where is this order', 10);
select public._c1016_place('admin.order_alerts',       'home_fulfill', 'Orders', 'New-order alerts', 20);
select public._c1016_place('admin.order_closure',      'home_fulfill', 'Orders', 'Order closure', 30);
select public._c1016_place('admin.bags',               'home_fulfill', 'Orders', 'Bags', 40);
select public._c1016_place('admin.delivery_partners',  'home_fulfill', 'Delivery', 'Delivery partners', 110);
select public._c1016_place('admin.delivery_waves',     'home_fulfill', 'Delivery', 'Delivery waves', 120);
select public._c1016_place('admin.delivery_ops',       'home_fulfill', 'Delivery', 'Delivery operations', 130);
select public._c1016_place('admin.delivery_extras',    'home_fulfill', 'Delivery', 'Delivery programme', 140);
select public._c1016_place('partner.damage_report',    'home_fulfill', 'Returns & damage', 'Damage report', 210);
select public._c1016_place('admin.returns_refunds',    'home_fulfill', 'Returns & damage', 'Customer returns & refunds', 220);
select public._c1016_place('partner.supplier_returns', 'home_fulfill', 'Returns & damage', 'Returns to supplier', 230);
select public._c1016_place('admin.ops_queues',         'home_fulfill', 'Returns & damage', 'Stuck work', 240);
select public._c1016_place('partner.fulfil_tasks',     'home_fulfill', 'Team', 'Task board', 310);
select public._c1016_place('worker.my_tasks',          'home_fulfill', 'Team', 'My tasks', 320);
select public._c1016_place('partner.workers',          'home_fulfill', 'Team', 'Workers', 330);
select public._c1016_place('partner.staff',            'home_fulfill', 'Team', 'My staff', 340);

-- Money (settle)
select public._c1016_place('admin.bill_pipeline',       'home_money', 'Bills & payments', 'Bills', 10);
select public._c1016_place('partner.supplier_payment',  'home_money', 'Bills & payments', 'Supplier payments', 20);
select public._c1016_place('admin.money',               'home_money', 'Bills & payments', 'Customer collections', 30);
select public._c1016_place('admin.payment_upi',         'home_money', 'Bills & payments', 'Payment and Partner', 40);
select public._c1016_place('admin.settlement',          'home_money', 'Settlement', 'Partner settlement', 110);
select public._c1016_place('partner.settlement',        'home_money', 'Settlement', 'My settlement', 120);
select public._c1016_place('partner.settlement_invoices','home_money', 'Settlement', 'Tax invoices', 130);
select public._c1016_place('partner.expenses',          'home_money', 'Settlement', 'Expenses', 140);
select public._c1016_place('admin.pnl',                 'home_money', 'Books', 'Profit & loss', 210);
select public._c1016_place('admin.zone_pnl',            'home_money', 'Books', 'Zone P&L', 220);
select public._c1016_place('admin.gst',                 'home_money', 'Books', 'GST', 230);
select public._c1016_place('admin.stock_on_hand',       'home_money', 'Books', 'Stock on hand', 240);

-- More · Catalogue & pricing
select public._c1016_place('admin.add_medicine',     'more_catalogue', 'Catalogue & pricing', 'Add medicine', 10);
select public._c1016_place('admin.catalogue_health', 'more_catalogue', 'Catalogue & pricing', 'Catalogue health', 20);
select public._c1016_place('admin.search_synonyms',  'more_catalogue', 'Catalogue & pricing', 'Search synonyms', 30);
select public._c1016_place('admin.pricing_backfill', 'more_catalogue', 'Catalogue & pricing', 'Product pricing', 40);
select public._c1016_place('admin.pricing_coverage', 'more_catalogue', 'Catalogue & pricing', 'Trade price coverage', 50);
select public._c1016_place('admin.discount_slabs',   'more_catalogue', 'Catalogue & pricing', 'Discount slabs', 60);

-- More · Communication
select public._c1016_place('admin.whatsapp',      'more_comms', 'Communication', 'WhatsApp', 10);
select public._c1016_place('admin.wa_templates',  'more_comms', 'Communication', 'WhatsApp templates', 20);
select public._c1016_place('admin.wa_campaigns',  'more_comms', 'Communication', 'WhatsApp campaigns', 30);
select public._c1016_place('admin.wa_segments',   'more_comms', 'Communication', 'WhatsApp segments', 40);
select public._c1016_place('admin.wa_drips',      'more_comms', 'Communication', 'Sequences', 50);
select public._c1016_place('admin.wa_ops',        'more_comms', 'Communication', 'WhatsApp ops', 60);
select public._c1016_place('admin.wa_diagnosis',  'more_comms', 'Communication', 'WhatsApp delivery diagnosis', 70);
select public._c1016_place('admin.notify_center', 'more_comms', 'Communication', 'Notification centre', 80);
select public._c1016_place('admin.admin_push',    'more_comms', 'Communication', 'Push notifications', 90);
select public._c1016_place('admin.notify_cost',   'more_comms', 'Communication', 'Notification cost', 100);
select public._c1016_place('admin.wa_assistant',  'more_comms', 'Communication', 'WhatsApp assistant', 110);

-- More · Marketing
select public._c1016_place('admin.loyalty',        'more_marketing', 'Marketing', 'Loyalty', 10);
select public._c1016_place('admin.demand_engine',  'more_marketing', 'Marketing', 'Demand engine', 20);

-- More · Support & feedback
select public._c1016_place('admin.support_inbox',   'more_support', 'Support & feedback', 'Support inbox', 10);
select public._c1016_place('partner.order_threads', 'more_support', 'Support & feedback', 'Customer messages', 20);
select public._c1016_place('admin.feedback',        'more_support', 'Support & feedback', 'Feedback', 30);
select public._c1016_place('admin.reviews',         'more_support', 'Support & feedback', 'Reviews & Q&A', 40);
select public._c1016_place('admin.partner_issues',  'more_support', 'Support & feedback', 'Partner issues', 50);

-- More · Users & access
select public._c1016_place('admin.manage_admins', 'more_users', 'Users & access', 'Manage admins', 10);
select public._c1016_place('admin.users_access',  'more_users', 'Users & access', 'Users & access', 20);

-- More · System & Dev tools
select public._c1016_place('admin.dev_queue',    'more_system', 'System', 'Dev Queue', 10);
select public._c1016_place('admin.audit_log',    'more_system', 'System', 'Audit trail', 20);
select public._c1016_place('admin.scope_audit',  'more_system', 'System', 'Scope audit', 30);
select public._c1016_place('admin.feature_gaps', 'more_system', 'System', 'Feature gaps', 40);
select public._c1016_place('admin.surface_map',  'more_system', 'System', 'Screen audit', 50);
select public._c1016_place('admin.bulk_actions', 'more_system', 'System', 'Bulk actions', 60);
select public._c1016_place('admin.exports',      'more_system', 'System', 'Exports', 70);
update public.feature_registry set category = 'more_system'
 where surface = 'dev_tools' and category <> 'more_system';

-- 2c. the duplicates. One tile per feature; the other row becomes an ALIAS
--     (access identity only) or goes inactive when it never had a door.
create or replace function public._c1016_alias(p_key text, p_into text)
returns void language plpgsql as $$
begin
  update public.feature_registry
     set surface = 'alias', merged_into = p_into
   where feature_key = p_key;
end $$;
create or replace function public._c1016_retire(p_key text, p_into text)
returns void language plpgsql as $$
begin
  update public.feature_registry
     set is_active = false, merged_into = p_into
   where feature_key = p_key;
end $$;

-- Ops board / Exceptions / the fulfil stages: the partner.* row is the access
-- key the fulfill.* stage resolves through (canonical_key), so it stays active
-- as an alias; the stage is the one tile.
select public._c1016_alias('partner.ops_board',       'fulfill.ops_board');
select public._c1016_alias('partner.exceptions',      'fulfill.exceptions');
select public._c1016_alias('partner.customer_orders', 'fulfill.customer_order');
select public._c1016_alias('partner.inquiry',         'fulfill.supplier_inquiry');
select public._c1016_alias('partner.supplier_orders', 'fulfill.supplier_order');
select public._c1016_alias('partner.collect',         'fulfill.supplier_shop');
select public._c1016_alias('partner.count',           'fulfill.warehouse');
select public._c1016_alias('partner.bag_mapping',     'fulfill.bag');
select public._c1016_alias('partner.pack',            'fulfill.pack');
select public._c1016_alias('partner.disputes',        'fulfill.dispute');
select public._c1016_alias('partner.assign_delivery', 'fulfill.delivery');
-- Order timeline ×2: the routeless partner row never had a door.
select public._c1016_retire('partner.order_timeline', 'fulfill.order_timeline');
-- Zone P&L ×2: one tile (admin.zone_pnl), resolved through the partner grant
-- so a partner keeps exactly the access it holds today.
select public._c1016_alias('partner.zone_pnl', 'admin.zone_pnl');
update public.feature_registry
   set canonical_key = 'partner.zone_pnl',
       partner_eligible = true,
       roles_allowed = (select array_agg(distinct r) from unnest(roles_allowed || array['partner']) r)
 where feature_key = 'admin.zone_pnl';
-- Cron health / Test mode ×2: the Dev Queue tool is the one row.
select public._c1016_alias('admin.cron_health', 'devtool.cron_health');
select public._c1016_alias('admin.test_mode',   'devtool.test_mode');
-- The routeless "mediBO only" placeholders — each a duplicate of a real screen.
select public._c1016_retire('medibo.marketing',            'admin.loyalty');
select public._c1016_retire('medibo.customer_acquisition', 'admin.cust_tab.leads');
select public._c1016_retire('medibo.catalogue',            'admin.catalogue_health');
select public._c1016_retire('medibo.pricing',              'admin.pricing_coverage');
select public._c1016_retire('medibo.customer_payment',     'admin.money');
select public._c1016_retire('medibo.partner_settlement',   'admin.settlement');
-- Customer 360 merged into the customer page (#810): the deep link with an id
-- still opens the 360 view; the tile is the Customers list.
select public._c1016_alias('admin.customer_360', 'admin.customers');

-- 2d. the partner's own settlement statement gets its own door. Since #653 the
--     shared route 'settlement' opened the OFFICE screen for a partner.
update public.feature_registry
   set route_key = 'partner_settlement', deep_link = '/admin/go/partner_settlement'
 where feature_key = 'partner.settlement';

-- 2e. every staff tile has a deep link of the one shape the shell parks.
update public.feature_registry
   set deep_link = '/admin/go/' || route_key
 where surface in ('dashboard','both') and coalesce(route_key,'') <> ''
   and coalesce(deep_link,'') = '';

-- 2f. old categories retire once nothing points at them.
update public.nav_category set is_active = false
 where category_key in ('orders','parties','catalogue','delivery','comms','money','system')
   and not exists (select 1 from public.feature_registry f
                    where f.category = nav_category.category_key and f.is_active
                      and f.surface <> 'alias');

-- 2g. redirects: an old route key lands on its new home.
insert into public.nav_redirect(from_route, to_route, only_role, when_no_seed, note) values
  ('customer_360',     'customers',          null,      true,  'Customer 360 merged into the customer page (#810); a link with an id still opens it'),
  ('settlement',       'partner_settlement', 'partner', false, 'a partner''s settlement is the statement screen, not the office console'),
  ('partner_zone_pnl', 'zone_pnl',           null,      false, 'one Zone P&L screen; zone_pnl() clamps a partner to its zone'),
  ('collect',          'supplier_shop',      null,      false, 'fulfil stage'),
  ('count',            'warehouse',          null,      false, 'fulfil stage'),
  ('bag_mapping',      'bag',                null,      false, 'fulfil stage'),
  ('assign_delivery',  'delivery',           null,      false, 'fulfil stage'),
  ('disputes',         'dispute',            null,      false, 'fulfil stage'),
  ('customer_orders',  'customer_order',     null,      false, 'fulfil stage'),
  ('inquiry',          'supplier_inquiry',   null,      false, 'fulfil stage'),
  ('supplier_orders',  'supplier_order',     null,      false, 'fulfil stage'),
  ('whatsapp_home',    'whatsapp',           null,      false, 'the old bottom tab'),
  ('money_tab',        'money_home',         null,      false, 'the Money tab')
on conflict (from_route) do update
   set to_route = excluded.to_route, only_role = excluded.only_role,
       when_no_seed = excluded.when_no_seed, note = excluded.note;

-- 2h. doors. The partner-only screens are opened by the shared shell now
--     (lib/screens/shell/shell_staff_routes.dart); the retired partner resolver
--     is no longer a handler for them.
update public.surface_route set handled_by = 'home_shell', is_active = true,
       note = 'CHANGE #1016 — opened by shellStaffRouteScreen() in lib/screens/shell/shell_staff_routes.dart', updated_at = now()
 where route_key in ('partner_staff','partner_workers','partner_expenses','supplier_payment',
                     'supplier_returns','partner_documents')
   and feature_key in ('partner.staff','partner.workers','partner.expenses','partner.supplier_payment',
                       'partner.supplier_returns','partner.documents');
insert into public.surface_route(route_key, feature_key, kind, handled_by, note, is_active) values
  ('partner_settlement', 'partner.settlement', 'feature', 'home_shell',
   'CHANGE #1016 — the partner statement; opened by shellStaffRouteScreen()', true),
  ('money_home', '', 'chrome', 'home_shell', 'CHANGE #1016 — the Money tab (staff_home(''money''))', true),
  ('more',       '', 'chrome', 'home_shell', 'CHANGE #1016 — the More tab (staff_home(''more''))', true)
on conflict (route_key, feature_key) do update
   set handled_by = excluded.handled_by, note = excluded.note, is_active = true, updated_at = now();
-- the partner row's OLD door onto the office screen is retired with the route
update public.surface_route set is_active = false, updated_at = now()
 where route_key = 'settlement' and feature_key = 'partner.settlement';

-- 2i. the old layout, behind a flag, for seven days.
insert into public.app_settings(key, value)
values ('staff_layout_v1', jsonb_build_object(
          'enabled', false,
          'expires_at', '2026-09-10T00:00:00+05:30',
          'note', 'Set enabled=true to draw the pre-#1016 staff layout (five old tabs + the full dashboard). Ignored after expires_at.'))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- PART 3 · the resolvers
-- ─────────────────────────────────────────────────────────────────────────────

-- 3a. ONE visibility predicate for every staff surface. nav_registry,
--     nav_search and staff_home all read it, so they can never disagree.
create or replace function public._staff_visible()
returns table (feature_key text, label text, group_label text, icon_key text, route_key text,
               sort_order int, category text, surface text, badge_source text, badge_noun text,
               deep_link text, description text, search_terms text, home_tab text, cat_sort int,
               cat_label text)
language sql stable security definer set search_path = public as $$
  with me as (
    select coalesce(public.get_my_role(),'none') as role, public.my_partner_id() as partner
  )
  select f.feature_key, f.label, f.group_label, f.icon_key, f.route_key, f.sort_order,
         f.category, f.surface, f.badge_source, f.badge_noun, f.deep_link, f.description,
         f.search_terms, c.home_tab, c.sort_order, c.label
    from public.feature_registry f
    join public.nav_category c on c.category_key = f.category and c.is_active
    cross join me
   where f.is_active
     and f.surface in ('dashboard','both','dev_tools')
     and coalesce(f.route_key,'') <> ''
     -- A partner login is the MATRIX's business: partner_eligible says the
     -- feature may be granted to a partner at all, partner_access() says it
     -- was. roles_allowed on partner-owned rows still reads {admin,
     -- super_admin} from the days partners had their own surface, and reading
     -- it here is exactly what left a partner's dashboard empty after #653.
     and case when me.partner is not null
              then f.partner_eligible
                   and coalesce(public.partner_access(f.feature_key, me.partner),'none') <> 'none'
              when f.surface = 'dev_tools' then me.role = 'super_admin' and me.role = any (f.roles_allowed)
              else me.role = any (f.roles_allowed)
                   and coalesce(public.admin_access(f.feature_key),'none') <> 'none' end
$$;

-- 3b. the tab bar + the redirect map + the layout flag, one call at boot.
create or replace function public.staff_nav()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_flag    jsonb := coalesce((select value from public.app_settings where key = 'staff_layout_v1'), '{}'::jsonb);
  v_layout  text := 'v2';
  v_tabs    jsonb;
  v_redirects jsonb;
begin
  if auth.uid() is null or v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'layout', 'v2',
      'tabs', '[]'::jsonb, 'redirects', '{}'::jsonb);
  end if;

  if coalesce((v_flag->>'enabled')::boolean, false)
     and now() < coalesce((v_flag->>'expires_at')::timestamptz, now()) then
    v_layout := 'v1';
  end if;

  with vis as (select * from public._staff_visible())
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',       t.tab_key,
           'label',     public._c(t.label_key),
           'icon_key',  t.icon_key,
           'route_key', t.route_key,
           'badge_key', case when t.tab_key = 'fulfill' then 'order_alerts' else '' end,
           'visible',   t.visible)
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from (
      select s.*,
             -- a tab is on the bar when the login may open it: the anchor
             -- feature's own View toggle (the rule the old five tabs used), or
             -- any feature homed under it.
             (case when s.anchor_feature is not null
                   then (case when v_partner is not null
                              then coalesce(public.partner_access(s.anchor_feature, v_partner),'none') <> 'none'
                              else coalesce(public.admin_access(s.anchor_feature),'none') <> 'none' end)
                   else false end
              or exists (select 1 from vis v where v.home_tab = s.tab_key)) as visible
        from public.staff_nav_tab s where s.is_active
    ) t;

  select coalesce(jsonb_object_agg(r.from_route, jsonb_build_object(
           'to', r.to_route, 'when_no_seed', r.when_no_seed)), '{}'::jsonb)
    into v_redirects
    from public.nav_redirect r
   where r.only_role is null or r.only_role = v_role;

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'layout', v_layout,
    'layout_note', case when v_layout = 'v1' then public._c('nav.legacy_layout_note') else '' end,
    'tabs', v_tabs,
    'redirects', v_redirects);
end $$;

-- 3c. one home, rendered. Sections = the home's categories × group_label, in
--     registry order; items carry the same tile shape nav_registry ships so
--     the SAME tap handler opens them. `strip` is the compact form the
--     Customers / Suppliers / Fulfill pages draw above their own tab rows.
create or replace function public.staff_home(p_tab text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_role    text := coalesce(public.get_my_role(),'none');
  v_tab     record;
  v_counts  jsonb := '{}'::jsonb;
  v_sections jsonb;
  v_recents jsonb := '[]'::jsonb;
  v_stats   jsonb := '[]'::jsonb;
  v_n       int := 0;
  v_dash    jsonb;
begin
  if v_uid is null or v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'sections', '[]'::jsonb,
      'items_count', 0, 'empty_label', public._c('staff_home.empty_label'));
  end if;
  select * into v_tab from public.staff_nav_tab where tab_key = p_tab and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown_tab', 'sections', '[]'::jsonb,
      'items_count', 0, 'empty_label', public._c('staff_home.empty_label'));
  end if;
  begin
    v_counts := public.nav_badge_counts();
  exception when others then v_counts := '{}'::jsonb;
  end;

  with vis as (
    select v.*, (v_counts ->> v.badge_source)::bigint as badge_count,
           coalesce(u.opens, 0) as opens, u.last_at
      from public._staff_visible() v
      left join (select feature_key, count(*) as opens, max(opened_at) as last_at
                   from public.nav_usage
                  where user_id = v_uid and opened_at > now() - interval '30 days'
                  group by 1) u on u.feature_key = v.feature_key
     where v.home_tab = p_tab
       -- the tab's own page is not a tile inside itself
       and v.route_key <> v_tab.route_key
  ), tile as (
    select v.cat_sort, v.category, v.cat_label, v.group_label, v.sort_order, v.opens, v.last_at,
           jsonb_build_object(
             'feature_key', v.feature_key, 'label', v.label, 'icon_key', v.icon_key,
             'icon_letter', upper(left(v.label,1)),
             'route_key', v.route_key, 'deep_link', v.deep_link,
             'tool_key', case when v.surface = 'dev_tools' then v.route_key else null end,
             'description', coalesce(v.description,''),
             'badge_count', coalesce(v.badge_count,0),
             'badge_label', case when coalesce(v.badge_count,0) > 0
                                 then v.badge_count::text || ' ' || coalesce(v.badge_noun, lower(v.label))
                                 else null end,
             'opens', v.opens) as js
      from vis v
  )
  select coalesce((select jsonb_agg(sec order by cat_sort, grp_sort) from (
           select t.cat_sort, min(t.sort_order) as grp_sort,
                  jsonb_build_object(
                    'key',   t.category || ':' || t.grp,
                    'label', case when p_tab = 'more' then t.cat_label else coalesce(nullif(t.grp,''), t.cat_label) end,
                    'sublabel', '',
                    'items', jsonb_agg(t.js order by t.group_label, t.sort_order)) as sec
             -- More: one section per category (the sub-groups order the items);
             -- every other home: one section per group_label.
             from (select *, case when p_tab = 'more' then '' else coalesce(group_label,'') end as grp from tile) t
            group by t.cat_sort, t.category, t.cat_label, t.grp) s), '[]'::jsonb),
         (select count(*)::int from tile),
         -- recents: the tiles this login actually opened, newest first.
         coalesce((select jsonb_agg(r.js order by r.last_at desc) from (
           select * from tile where opens > 0 order by last_at desc limit 6) r), '[]'::jsonb)
    into v_sections, v_n, v_recents;

  -- Money's "right now" line: the counts the old dashboard overview carried,
  -- worded here so the app prints them verbatim.
  if p_tab = 'money' and v_role in ('admin','super_admin') then
    begin
      v_dash := public.admin_dashboard_counts();
      v_stats := jsonb_build_array(
        jsonb_build_object('key','pending_bills',
          'label', public._c('staff_home.pending_bills'),
          'value_label', coalesce(v_dash->>'pending_bills','0'),
          'tone', case when coalesce((v_dash->>'pending_bills')::int,0) > 0 then 'warn' else 'good' end,
          'route_key', 'bill_pipeline'));
      if coalesce((v_dash->>'unresolved_bills')::int,0) > 0 then
        v_stats := v_stats || jsonb_build_object('key','unresolved_bills',
          'label', coalesce(v_dash->>'unresolved_bills_label',''),
          'value_label', v_dash->>'unresolved_bills',
          'tone', 'warn', 'route_key', 'bill_pipeline');
      end if;
    exception when others then v_stats := '[]'::jsonb;
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'tab_key', p_tab,
    'title', coalesce(nullif(public._c('staff_home.' || p_tab || '_title'),''), public._c(v_tab.label_key)),
    'subtitle', public._c('staff_home.' || p_tab || '_subtitle'),
    'search_hint', public._c('staff_home.search_hint'),
    'search_empty', public._c('staff_home.search_empty'),
    'recents_label', public._c('staff_home.recents_label'),
    'strip_label', public._c('staff_home.strip_label'),
    'stats_label', public._c('staff_home.stats_label'),
    'empty_label', public._c('staff_home.empty_label'),
    'unused_report_label', case when v_role = 'super_admin' then public._c('staff_home.unused_report') else '' end,
    'sections', v_sections,
    'items_count', v_n,
    'recents', v_recents,
    'stats', v_stats);
end $$;

-- 3d. nav_registry: the same predicate, alias rows never drawn. Kept for the
--     v1 layout flag and the palette; the payload shape is unchanged.
create or replace function public.nav_registry()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_uid     uuid := auth.uid();
  v_counts  jsonb := public.nav_badge_counts();
  v_tiles   jsonb; v_actions jsonb; v_pinned jsonb; v_profile jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', 'Sign in to see your dashboard.');
  end if;

  with visible as (
    select f.*, (v_counts ->> f.badge_source)::bigint as badge_count,
           (p.feature_key is not null) as pinned, coalesce(u.opens, 0) as opens
      from public._staff_visible() f
      left join nav_pin p on p.feature_key = f.feature_key and p.user_id = v_uid
      left join (select feature_key, count(*) as opens from nav_usage
                  where user_id = v_uid and opened_at > now() - interval '30 days'
                  group by 1) u on u.feature_key = f.feature_key
     where f.surface in ('dashboard','both')
  ), tile as (
    select v.category, v.feature_key, v.sort_order, v.pinned, v.opens,
           jsonb_build_object(
             'feature_key', v.feature_key, 'label', v.label,
             'icon_key', v.icon_key,
             'icon_letter', upper(left(v.label,1)),
             'route_key', v.route_key,
             'deep_link', v.deep_link, 'badge_count', v.badge_count,
             'badge_label', case when coalesce(v.badge_count,0) > 0
                                 then v.badge_count::text || ' ' || coalesce(v.badge_noun, lower(v.label))
                                 else null end,
             'pinned', v.pinned, 'opens', v.opens) as js
      from visible v
  )
  select
    coalesce((select jsonb_agg(sec order by sec_sort) from (
        select c.sort_order as sec_sort,
               jsonb_build_object('category_key', c.category_key, 'label', c.label,
                 'icon_key', c.icon_key, 'icon_letter', upper(left(c.label,1)),
                 'items', jsonb_agg(t.js order by t.pinned desc, t.opens desc, t.sort_order)) as sec
          from nav_category c join tile t on t.category = c.category_key
         where c.is_active
         group by c.category_key, c.label, c.icon_key, c.sort_order) s), '[]'::jsonb),
    coalesce((select jsonb_agg(t.js order by (t.js->>'badge_count')::bigint desc, t.sort_order)
                from tile t where coalesce((t.js->>'badge_count')::bigint,0) > 0), '[]'::jsonb),
    coalesce((select jsonb_agg(t.js order by t.sort_order) from tile t where t.pinned), '[]'::jsonb)
  into v_tiles, v_actions, v_pinned;

  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key, 'label', f.label, 'icon_key', f.icon_key,
           'icon_letter', upper(left(f.label,1)),
           'route_key', f.route_key, 'deep_link', f.deep_link,
           'tone', case when f.feature_key = 'identity.logout' then 'danger' else 'neutral' end
         ) order by f.sort_order), '[]'::jsonb)
    into v_profile from feature_registry f
   where f.is_active and f.surface in ('profile','both') and v_role = any (f.roles_allowed);

  return jsonb_build_object('ok', true, 'role', v_role, 'sections', v_tiles,
    'action_tiles', v_actions, 'pinned', v_pinned, 'profile_menu', v_profile,
    'labels', (select coalesce(jsonb_object_agg(
                 replace(k.key, 'nav.', ''), k.value #>> '{}'), '{}'::jsonb)
                 from ui_copy k where k.key like 'nav.%'));
end $$;

-- 3f. the palette's screen group reads the same predicate.
CREATE OR REPLACE FUNCTION public.nav_search(p_q text, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_q       text := btrim(coalesce(p_q,''));
  v_like    text;
  v_groups  jsonb := '[]'::jsonb;
  v_part    jsonb;
  v_lim     int  := least(greatest(coalesce(p_limit,6),1), 20);
  -- CHANGE #570 QA round 2 — the entity groups' doors, resolved once. The
  -- `screens` group below is gated row by row; these three groups list ORDERS,
  -- CUSTOMERS and SUPPLIERS, and every one of their rows opens the same three
  -- features, so the answer is fetched once rather than per row.
  v_can_360  boolean;
  v_can_cust boolean;
  v_can_supp boolean;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'message', 'Admins only.', 'groups', '[]'::jsonb);
  end if;
  if length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'query', v_q, 'groups', '[]'::jsonb,
      'hint', 'Type at least two characters.',
      'empty_label', 'Type at least two characters.');
  end if;
  v_like := '%' || lower(v_q) || '%';

  v_can_360  := coalesce(public.admin_access('admin.customer_360'),'none') <> 'none';
  v_can_cust := coalesce(public.admin_access('admin.customers'),'none') <> 'none';
  v_can_supp := coalesce(public.admin_access('admin.suppliers'),'none') <> 'none';

  select jsonb_agg(x order by rank, sort_order) into v_part from (
    select f.sort_order,
           case when lower(f.label) = lower(v_q) then 0
                when lower(f.label) like lower(v_q) || '%' then 1 else 2 end as rank,
           jsonb_build_object(
             'kind','screen', 'title', f.label, 'subtitle', c.label,
             'icon_key', f.icon_key, 'icon_letter', upper(left(f.label,1)),
             'route_key', f.route_key,
             'deep_link', f.deep_link, 'feature_key', f.feature_key,
             'seed', null) as x
      -- CHANGE #1016 — ONE visibility predicate (_staff_visible) shared with
      -- nav_registry() and staff_home(); alias rows are never offered.
      from public._staff_visible() f
      join nav_category c on c.category_key = f.category
     where f.surface in ('dashboard','both')
       and (lower(f.label) like v_like or lower(coalesce(f.search_terms,'')) like v_like
            or lower(c.label) like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','screens','label','Screens','items', v_part));
  end if;

  select jsonb_agg(x order by rank, sort_order) into v_part from (
    select f.sort_order,
           case when lower(f.label) = lower(v_q) then 0
                when lower(f.label) like lower(v_q) || '%' then 1 else 2 end as rank,
           jsonb_build_object(
             'kind','dev_tool', 'title', f.label,
             'subtitle', coalesce(nullif(f.description,''), f.group_label),
             'icon_key', f.icon_key, 'icon_letter', upper(left(f.label,1)),
             'route_key', f.route_key, 'tool_key', f.route_key,
             'deep_link', null, 'feature_key', f.feature_key,
             'seed', null) as x
      from feature_registry f
     where f.is_active and f.surface = 'dev_tools'
       and v_role = any (f.roles_allowed)
       and (lower(f.label) like v_like or lower(coalesce(f.search_terms,'')) like v_like
            or lower(coalesce(f.description,'')) like v_like
            or lower(coalesce(f.group_label,'')) like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','dev_tools','label','Dev Queue tools','items', v_part));
  end if;

  -- An order now carries its pharmacy's id, so picking an order from the
  -- palette opens that pharmacy's 360 view — "reachable from any order".
  select jsonb_agg(x order by created_at desc) into v_part from (
    select o.created_at, jsonb_build_object(
             'kind','order', 'title', coalesce(o.order_code, 'Order #' || o.id),
             'subtitle', coalesce(o.pharmacy_name,'') || ' · ' || coalesce(o.status,''),
             'icon_key','receipt', 'icon_letter','O',
             -- CHANGE #570 QA round 2 — an entity row is a DOOR onto a
             -- feature, so it carries the caller's access to that feature, not
             -- just the row's existence. A reader denied admin.customer_360
             -- lands on admin.customers; denied both, the row carries no door
             -- at all rather than a deep link into a screen that will refuse.
             'route_key', case when pp.id is not null and v_can_360 then 'customer_360'
                               when v_can_cust then 'customers' end,
             'deep_link', case when pp.id is not null and v_can_360
                               then '/admin/go/customer_360/' || pp.id::text
                               when v_can_cust then '/admin/go/customers' end,
             'feature_key', case when pp.id is not null and v_can_360 then 'admin.customer_360'
                                 when v_can_cust then 'admin.customers' end,
             'seed', coalesce(pp.id::text, o.order_code, o.pharmacy_name)) as x
      from orders o
      left join lateral (
        select p.id from pharmacy_profiles p
         where (o.customer_id is not null and p.id = o.customer_id)
            or (o.customer_id is null and p.user_id = o.user_id)
         limit 1) pp on true
     where lower(coalesce(o.order_code,'')) like v_like
        or lower(coalesce(o.pharmacy_name,'')) like v_like
     order by o.created_at desc limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','orders','label','Orders','items', v_part));
  end if;

  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','customer',
             'title', coalesce(nullif(btrim(p.pharmacy_name),''), p.customer_name, 'Customer'),
             'subtitle', coalesce(p.city,'') ||
                         case when coalesce(p.approved,false) then '' else ' · pending approval' end,
             'icon_key','people', 'icon_letter','C',
             'route_key', case when v_can_360 then 'customer_360' end,
             'deep_link', case when v_can_360
                               then '/admin/go/customer_360/' || p.id::text end,
             'feature_key', case when v_can_360 then 'admin.customer_360' end,
             'seed', p.id::text) as x
      from pharmacy_profiles p
     where coalesce(p.is_deleted,false) = false
       and (lower(coalesce(p.pharmacy_name,'')) like v_like
            or lower(coalesce(p.customer_name,'')) like v_like
            or lower(coalesce(p.customer_code,'')) like v_like
            or coalesce(p.phone,'') like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','customers','label','Customers','items', v_part));
  end if;

  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','supplier', 'title', s.supplier_name,
             'subtitle', coalesce(s.city,''),
             'icon_key','inventory', 'icon_letter','S',
             'route_key', case when v_can_supp then 'suppliers' end,
             'deep_link', case when v_can_supp then '/admin/go/suppliers' end,
             'feature_key', case when v_can_supp then 'admin.suppliers' end,
             'seed', s.supplier_name) as x
      from supplier_profiles s
     where coalesce(s.is_deleted,false) = false
       and (lower(coalesce(s.supplier_name,'')) like v_like
            or lower(coalesce(s.supplier_code,'')) like v_like
            or coalesce(s.phone,'') like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','suppliers','label','Suppliers','items', v_part));
  end if;

  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','medicine', 'title', m.product_name,
             'subtitle', coalesce(m.marketer_canonical, ''),
             'icon_key','medication', 'icon_letter','M', 'route_key','search',
             'deep_link', null, 'feature_key', null,
             'seed', m.product_name) as x
      from "MEDICINE" m
     where m.product_name ilike v_like
     order by m.sales_count desc nulls last limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','medicines','label','Medicines','items', v_part));
  end if;

  return jsonb_build_object('ok', true, 'query', v_q, 'groups', v_groups,
    'empty_label', coalesce(
      (select value #>> '{}' from ui_copy where key = 'nav.empty_search'),
      'Nothing matched.'));
end $function$;

-- 3e. the parity report: every baseline feature → its one home today.
create or replace function public.nav_parity_report()
returns jsonb
language sql stable security definer set search_path = public as $$
  with resolved as (
    select b.feature_key as old_key, b.label as old_label, b.surface as old_surface,
           b.group_label as old_group, b.route_key as old_route,
           -- the row itself if it is still a tile, else the row it merged into
           case when f.is_active and f.surface <> 'alias' then f.feature_key
                else coalesce(f.merged_into, '') end as new_key
      from public.nav_parity_baseline b
      left join public.feature_registry f on f.feature_key = b.feature_key
  )
  select jsonb_build_object(
    'ok', true,
    'total', count(*),
    'unresolved', count(*) filter (where h.home_tab is null),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
      'old_key', r.old_key, 'old_label', r.old_label, 'old_surface', r.old_surface,
      'old_group', coalesce(r.old_group,''), 'old_route', coalesce(r.old_route,''),
      'new_key', r.new_key, 'new_label', coalesce(n.label,''),
      'new_route', coalesce(n.route_key,''), 'new_home', coalesce(h.home_tab,''),
      'new_section', coalesce(n.group_label,''),
      'kind', case when r.new_key = r.old_key then 'kept'
                   when r.new_key = '' then 'UNRESOLVED' else 'merged' end,
      'ok', h.home_tab is not null)
      order by coalesce(h.home_tab,'~'), n.sort_order, r.old_key), '[]'::jsonb))
    from resolved r
    left join public.feature_registry n on n.feature_key = r.new_key and n.is_active and n.surface <> 'alias'
    left join public.nav_category h on h.category_key = n.category and h.is_active
   where r.old_key not like 'identity.%'  -- the profile menu is not a home
$$;

grant execute on function public.staff_nav() to authenticated;
grant execute on function public.staff_home(text) to authenticated;
grant execute on function public.nav_parity_report() to authenticated;
revoke execute on function public._staff_visible() from anon, public;

-- ─────────────────────────────────────────────────────────────────────────────
-- PART 4 · the guards
-- ─────────────────────────────────────────────────────────────────────────────

-- 4a. ONE HOME PER FEATURE. Red on: a tile with no home, two tiles sharing a
--     route_key or deep_link, an alias whose merged_into is not a live tile.
insert into public.rg_behavior_tests(name, body, enabled, note) values
('c1016_one_home_per_feature', $rg$
do $x$
declare v_bad text;
begin
  select string_agg(f.feature_key, ', ') into v_bad
    from public.feature_registry f
    left join public.nav_category c on c.category_key = f.category and c.is_active
   where f.is_active and f.surface in ('dashboard','both','dev_tools','fulfill_tab','customer_tab','supplier_tab')
     and coalesce(f.route_key,'') <> '' and c.home_tab is null;
  if v_bad is not null then
    raise exception 'RG_FAIL: staff tiles with no home tab (category.home_tab null): %', v_bad;
  end if;

  select string_agg(d.route_key || ' (' || d.keys || ')', ', ') into v_bad
    from (select f.route_key, string_agg(f.feature_key, '+') as keys
            from public.feature_registry f
           where f.is_active and f.surface in ('dashboard','both','dev_tools')
             and coalesce(f.route_key,'') <> ''
           group by f.route_key having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'RG_FAIL: two tiles share one route_key: %', v_bad;
  end if;

  select string_agg(d.deep_link || ' (' || d.keys || ')', ', ') into v_bad
    from (select f.deep_link, string_agg(f.feature_key, '+') as keys
            from public.feature_registry f
           where f.is_active and f.surface in ('dashboard','both','dev_tools','fulfill_tab')
             and coalesce(f.deep_link,'') <> ''
           group by f.deep_link having count(*) > 1) d;
  if v_bad is not null then
    raise exception 'RG_FAIL: two tiles share one deep_link: %', v_bad;
  end if;

  select string_agg(f.feature_key || '->' || coalesce(f.merged_into,'(null)'), ', ') into v_bad
    from public.feature_registry f
   where (f.surface = 'alias' or (not f.is_active and f.merged_into is not null))
     and not exists (select 1 from public.feature_registry t
                      join public.nav_category c on c.category_key = t.category and c.is_active
                     where t.feature_key = f.merged_into and t.is_active and t.surface <> 'alias'
                       and c.home_tab is not null);
  if v_bad is not null then
    raise exception 'RG_FAIL: an alias/retired row does not merge into a live tile with a home: %', v_bad;
  end if;

  if not exists (select 1 from public.staff_nav_tab where is_active and tab_key = 'more') then
    raise exception 'RG_FAIL: the More tab is missing from staff_nav_tab';
  end if;
  raise exception 'RG_ROLLBACK';
end $x$;
$rg$, true, 'CHANGE #1016 — one home per feature: every staff tile is homed under exactly one tab; no two tiles share a route_key or deep_link; every alias/retired row names a live tile.'),
('c1016_parity_gate', $rg$
do $x$
declare v jsonb; v_bad text;
begin
  v := public.nav_parity_report();
  if coalesce((v->>'unresolved')::int, 1) > 0 then
    select string_agg(r->>'old_key', ', ') into v_bad
      from jsonb_array_elements(v->'rows') r where (r->>'ok')::boolean = false;
    raise exception 'RG_FAIL: % pre-#1016 feature(s) map to no home: %', v->>'unresolved', v_bad;
  end if;
  if coalesce((v->>'total')::int, 0) < 100 then
    raise exception 'RG_FAIL: the parity baseline shrank to % rows — it must never be edited', v->>'total';
  end if;
  -- every baseline route key still resolves to a door: itself, a redirect, or a fulfil stage.
  -- A row younger than surface_map_grace_min is a build in progress (the
  -- surface map's own rule), reported by that audit and not counted here.
  select string_agg(b.route_key, ', ') into v_bad
    from public.nav_parity_baseline b
    join public.feature_registry f on f.feature_key = b.feature_key
   where b.is_active and coalesce(b.route_key,'') <> ''
     and f.created_at < now() - make_interval(mins => coalesce(
           (select (value #>> '{}')::int from public.app_settings where key = 'surface_map_grace_min'), 90))
     and not exists (select 1 from public.surface_route r where r.route_key = b.route_key and r.is_active)
     and not exists (select 1 from public.nav_redirect d where d.from_route = b.route_key);
  if v_bad is not null then
    raise exception 'RG_FAIL: baseline route(s) with no door and no redirect: %', v_bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $x$;
$rg$, true, 'CHANGE #1016 — zero capability loss: every feature_key the registry held before the re-categorisation maps to exactly one live home, and every old route still has a door or a redirect.')
on conflict (name) do update set body = excluded.body, enabled = true, note = excluded.note;

-- 4b. c570's "never offer a partner-owned feature to an admin console" check
--     assumed the shared shell had no door for partner.* routes. #1016 gives it
--     those doors (shell_staff_routes.dart) and makes the matrix the only
--     visibility rule, so that sub-check is retired; the deny-gate check stays.
update public.rg_behavior_tests
   set body = replace(body,
$old$    -- and it may never offer a partner-owned feature to an admin console that
    -- has no case for its route.
    if exists (
      select 1 from jsonb_array_elements(public.nav_search('supplier')->'groups') g,
                   jsonb_array_elements(g->'items') i
       where g->>'key' = 'screens' and i->>'feature_key' like 'partner.%') then
      raise exception 'nav_search offered a partner-owned feature to an admin console';
    end if;
$old$, $new$    -- CHANGE #1016 — the partner-owned screens have doors in the shared shell
    -- now (shell_staff_routes.dart); the matrix is the only visibility rule.
$new$)
 where name = 'c570_surface_map';

-- 4c. the journey: a bug class, retired for good.
create or replace function public._journey_c1016_staff_ia()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_fail text[] := array[]::text[]; v jsonb; v_n int; v_super uuid;
begin
  v := public.nav_parity_report();
  if coalesce((v->>'unresolved')::int,1) > 0 then
    v_fail := v_fail || ('parity: ' || (v->>'unresolved') || ' unresolved');
  end if;
  select count(*) into v_n from public.staff_nav_tab where is_active;
  if v_n <> 6 then v_fail := v_fail || ('staff_nav_tab holds ' || v_n || ' tabs, expected 6'); end if;
  -- the super admin sees six tabs and a populated More grid
  select u.id into v_super from auth.users u join public.admins a
      on lower(btrim(a.email)) = lower(btrim(u.email)) where coalesce(a.is_super,false) limit 1;
  if v_super is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_super, 'role', 'authenticated')::text, true);
    v := public.staff_nav();
    if (v->>'ok') <> 'true' then v_fail := v_fail || 'staff_nav refused the super admin'; end if;
    select count(*) into v_n from jsonb_array_elements(v->'tabs') t where (t->>'visible')::boolean;
    if v_n <> 6 then v_fail := v_fail || ('super admin sees ' || v_n || ' tabs'); end if;
    v := public.staff_home('more');
    if coalesce((v->>'items_count')::int,0) < 20 then
      v_fail := v_fail || ('More grid has only ' || coalesce(v->>'items_count','0') || ' items for the super admin');
    end if;
    v := public.staff_home('dashboard');
    if coalesce((v->>'items_count')::int,0) <> 0 then
      v_fail := v_fail || ('Dashboard still homes ' || (v->>'items_count') || ' tiles');
    end if;
  end if;
  return jsonb_build_object(
    'status', case when cardinality(v_fail) = 0 then 'passed' else 'failed' end,
    'ok', cardinality(v_fail) = 0,
    'evidence', jsonb_build_object('failures', to_jsonb(v_fail), 'parity', public.nav_parity_report() - 'rows'),
    'failures', to_jsonb(v_fail));
end $$;

insert into public.dev_journeys(name, area, kind, steps, assertions, source_bug, required, enabled)
select 'c1016-staff-ia', 'admin', 'api',
       '["Every pre-#1016 staff feature resolves to one home","The super admin sees six tabs","More holds the long tail; Dashboard homes no tiles"]'::jsonb,
       '["nav_parity_report().unresolved = 0","staff_nav().tabs visible = 6","staff_home(more).items_count >= 20 and staff_home(dashboard).items_count = 0"]'::jsonb,
       null, false, true
 where not exists (select 1 from public.dev_journeys where name = 'c1016-staff-ia');

drop function if exists public._c1016_place(text, text, text, text, int);
drop function if exists public._c1016_alias(text, text);
drop function if exists public._c1016_retire(text, text);

-- ─────────────────────────────────────────────────────────────────────────────
-- PART 5 · forward compatibility — a row another command registers tomorrow
-- ─────────────────────────────────────────────────────────────────────────────
-- feature_register() defaults p_category to 'system' and older commands still
-- name the pre-#1016 categories. Those categories stay ACTIVE and each one
-- knows its home, so a late registration is never a tile with no home (the
-- rg rule above would go red on the next deploy, but the tile would be
-- invisible until then). #471 registered admin.recon minutes after the
-- baseline was frozen; it lands in Money by this rule.
update public.nav_category set is_active = true, home_tab = v.home
  from (values ('orders','fulfill'), ('parties','customers'), ('catalogue','more'),
               ('delivery','fulfill'), ('comms','more'), ('money','money'), ('system','more')) v(k, home)
 where nav_category.category_key = v.k;
update public.feature_registry set category = 'home_money', group_label = 'Books'
 where feature_key = 'admin.recon' and category <> 'home_money';
