-- CHANGE #570 — Surface-mapping audit: every feature visible to exactly the
-- right user types, and a guard so it stays that way.
--
-- The complaint this closes: features built for user type X showing up on
-- other user types' surfaces, and features built for X missing from X.
-- Measured, not assumed — every number below came from calling the real
-- resolver RPCs under each role's own JWT (psql, request.jwt.claims set to a
-- live account, `set local role authenticated`):
--
--   LEAK 1  nav_search() filtered on roles_allowed ONLY, while nav_registry()
--           also requires admin_access() <> 'none' (or partner_access for a
--           partner). So the plain admin's command palette offered
--           admin.supplier_accounts and admin.ops_queues — two features that
--           same admin is DENIED on the dashboard — plus every partner.*
--           feature, whose route the shell has no case for.
--   LEAK 2  partner_screen_tabs() filtered only "if the caller is a partner",
--           so every OTHER signed-in role fell through the else branch and got
--           the whole admin tab list: a supplier, a customer and a delivery
--           rider each read 7 customer tabs, 6 supplier tabs, 6 fulfilment
--           tabs, labels and feature keys included.
--   LEAK 3  customer_nav() read visibility='customer_only' as "signed in and
--           not an admin", so the pharmacy's My Shop tab sat in the bottom bar
--           of the supplier, the partner and the rider.
--   GAP 1   identity.view_profile / identity.logout are partner_eligible, but
--           'partner' was missing from roles_allowed — a partner login had NO
--           profile menu at all, and therefore no way to log out.
--   GAP 2   admin.delivery_extras, admin.delivery_waves and
--           admin.returns_refunds are live dashboard tiles whose route_key had
--           no case anywhere in the app. The screens exist; the doors did not.
--
-- The regression-proofing is the point: surface_route below is the DECLARED
-- door list, surface_map_audit() diffs declaration against registry against
-- what each role really resolves, and rg behaviour test c570_surface_map holds
-- the three leaks shut. A feature registered to the wrong surface now fails
-- rg_check instead of reaching Om's phone.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. THE DECLARED DOOR LIST
-- ─────────────────────────────────────────────────────────────────────────
-- A route_key is NOT unique on its own: `pack` is both fulfill.pack (a tab on
-- the fulfilment screen) and partner.pack (a tile on the partner console), and
-- `cron_health` is both an admin tile and a Dev Queue tool. The door is the
-- pair, so the key is the pair — which also makes the "every routed feature
-- has a door" rule exact per feature instead of per route.
drop table if exists public.surface_route cascade;
create table public.surface_route (
  route_key   text not null,
  feature_key text not null default '',
  kind        text not null default 'feature',
  handled_by  text not null default 'home_shell',
  note        text not null default '',
  is_active   boolean not null default true,
  updated_at  timestamptz not null default now(),
  primary key (route_key, feature_key),
  constraint surface_route_kind_ck check (kind in ('feature','chrome','subscreen')),
  constraint surface_route_feature_ck check (kind <> 'feature' or feature_key <> '')
);

comment on table public.surface_route is
  'CHANGE #570 — every route_key the app can dispatch and the feature whose '
  'door it is. kind=feature must name an active feature_registry row; chrome '
  'is shell furniture (home/search/the My Shop tab itself); subscreen is '
  'reached from inside another screen rather than from a nav tile.';

alter table public.surface_route enable row level security;
do $$ begin
  create policy surface_route_read on public.surface_route
    for select using (true);
exception when duplicate_object then null; end $$;

insert into public.surface_route (route_key, kind, feature_key, handled_by, note) values
  ('add_customer', 'feature', 'admin.add_customer', 'home_shell', ''),
  ('add_medicine', 'feature', 'admin.add_medicine', 'home_shell', ''),
  ('add_supplier', 'feature', 'admin.add_supplier', 'home_shell', ''),
  ('admin_push', 'feature', 'admin.admin_push', 'home_shell', ''),
  ('assign_delivery', 'feature', 'partner.assign_delivery', 'partner_home_screen', ''),
  ('audit_log', 'feature', 'admin.audit_log', 'home_shell', ''),
  ('bag', 'feature', 'fulfill.bag', 'admin_fulfillment_screen', ''),
  ('bag_mapping', 'feature', 'partner.bag_mapping', 'partner_home_screen', ''),
  ('bags', 'feature', 'admin.bags', 'home_shell', ''),
  ('bill_pipeline', 'feature', 'admin.bill_pipeline', 'home_shell', ''),
  ('bug_report', 'feature', 'devtool.bug_report', 'dev_queue_screen', ''),
  ('bulk_actions', 'feature', 'admin.bulk_actions', 'home_shell', ''),
  ('catalogue_health', 'feature', 'admin.catalogue_health', 'home_shell', ''),
  ('collect', 'feature', 'partner.collect', 'partner_home_screen', ''),
  ('companies', 'feature', 'admin.companies', 'home_shell', ''),
  ('count', 'feature', 'partner.count', 'partner_home_screen', ''),
  ('cron_health', 'feature', 'admin.cron_health', 'home_shell', ''),
  ('cron_health', 'feature', 'devtool.cron_health', 'dev_queue_screen', ''),
  ('cust_cart', 'feature', 'admin.cust_tab.cart', 'admin_customer_screen', ''),
  ('cust_customers', 'feature', 'admin.cust_tab.customers', 'admin_customer_screen', ''),
  ('cust_help_requests', 'feature', 'cust.help_requests', 'home_shell', ''),
  ('cust_leads', 'feature', 'admin.cust_tab.leads', 'admin_customer_screen', ''),
  ('cust_pending', 'feature', 'admin.cust_tab.pending', 'admin_customer_screen', ''),
  ('cust_reorder_due', 'feature', 'cust.reorder_due', 'home_shell', ''),
  ('cust_routes', 'feature', 'admin.cust_tab.routes', 'admin_customer_screen', ''),
  ('cust_s_leads', 'feature', 'admin.cust_tab.s_leads', 'admin_customer_screen', ''),
  ('cust_saved_lists', 'feature', 'cust.saved_lists', 'home_shell', ''),
  ('customer_360', 'feature', 'admin.customer_360', 'admin_dashboard_screen', ''),
  ('customer_order', 'feature', 'fulfill.customer_order', 'admin_fulfillment_screen', ''),
  ('customer_orders', 'feature', 'partner.customer_orders', 'partner_home_screen', ''),
  ('customers', 'feature', 'admin.customers', 'home_shell', ''),
  ('dashboard', 'feature', 'admin.dashboard', 'home_shell', ''),
  ('deletion_requests', 'feature', 'admin.deletion_requests', 'home_shell', ''),
  ('delivery', 'feature', 'fulfill.delivery', 'admin_fulfillment_screen', ''),
  ('delivery_extras', 'feature', 'admin.delivery_extras', 'home_shell', ''),
  ('delivery_ops', 'feature', 'admin.delivery_ops', 'home_shell', ''),
  ('delivery_partners', 'feature', 'admin.delivery_partners', 'home_shell', ''),
  ('delivery_waves', 'feature', 'admin.delivery_waves', 'home_shell', ''),
  ('demand_engine', 'feature', 'admin.demand_engine', 'home_shell', ''),
  ('dev_queue', 'feature', 'admin.dev_queue', 'home_shell', ''),
  ('discount_slabs', 'feature', 'admin.discount_slabs', 'home_shell', ''),
  ('dispute', 'feature', 'fulfill.dispute', 'admin_fulfillment_screen', ''),
  ('disputes', 'feature', 'partner.disputes', 'partner_home_screen', ''),
  ('drafts_inbox', 'feature', 'devtool.drafts', 'dev_queue_screen', ''),
  ('exports', 'feature', 'admin.exports', 'home_shell', ''),
  ('feature_gaps', 'feature', 'admin.feature_gaps', 'home_shell', ''),
  ('fulfillment', 'feature', 'admin.fulfillment', 'home_shell', ''),
  ('gcp_control', 'feature', 'devtool.gcp', 'dev_queue_screen', ''),
  ('gst', 'feature', 'admin.gst', 'home_shell', ''),
  ('inquiry', 'feature', 'partner.inquiry', 'partner_home_screen', ''),
  ('journey_library', 'feature', 'devtool.journeys', 'dev_queue_screen', ''),
  ('khata', 'feature', 'admin.khata', 'admin_dashboard_screen', ''),
  ('logout', 'feature', 'identity.logout', 'home_shell', ''),
  ('loyalty', 'feature', 'admin.loyalty', 'home_shell', ''),
  ('manage_admins', 'feature', 'admin.manage_admins', 'home_shell', ''),
  ('memory', 'feature', 'devtool.memory', 'dev_queue_screen', ''),
  ('money', 'feature', 'admin.money', 'home_shell', ''),
  ('mr', 'feature', 'admin.mr', 'home_shell', ''),
  ('near_listing', 'feature', 'pharmacy.near_listing', 'admin_dashboard_screen', ''),
  ('notify_center', 'feature', 'admin.notify_center', 'home_shell', ''),
  ('notify_cost', 'feature', 'admin.notify_cost', 'home_shell', ''),
  ('ops_queues', 'feature', 'admin.ops_queues', 'home_shell', ''),
  ('order_alerts', 'feature', 'admin.order_alerts', 'home_shell', ''),
  ('order_closure', 'feature', 'admin.order_closure', 'home_shell', ''),
  ('pack', 'feature', 'fulfill.pack', 'admin_fulfillment_screen', ''),
  ('pack', 'feature', 'partner.pack', 'partner_home_screen', ''),
  ('paper_sale', 'feature', 'admin.paper_sale', 'home_shell', ''),
  ('partner_expenses', 'feature', 'partner.expenses', 'partner_home_screen', ''),
  ('partner_staff', 'feature', 'partner.staff', 'partner_home_screen', ''),
  ('partner_workers', 'feature', 'partner.workers', 'partner_home_screen', ''),
  ('payment_upi', 'feature', 'admin.payment_upi', 'home_shell', ''),
  ('pharmacy_audit', 'feature', 'shop.pharmacy_audit', 'home_shell', ''),
  ('pharmacy_expiry', 'feature', 'admin.pharmacy_expiry', 'admin_dashboard_screen', ''),
  ('pharmacy_gst', 'feature', 'shop.pharmacy_gst', 'home_shell', ''),
  ('pharmacy_owner', 'feature', 'shop.pharmacy_owner', 'home_shell', ''),
  ('pharmacy_parcel', 'feature', 'admin.parcel_count', 'admin_dashboard_screen', ''),
  ('pharmacy_radar', 'feature', 'shop.pharmacy_radar', 'home_shell', ''),
  ('pharmacy_reorder', 'feature', 'shop.pharmacy_reorder', 'home_shell', ''),
  ('pharmacy_stock', 'feature', 'shop.pharmacy_stock', 'home_shell', ''),
  ('pharmacy_variance', 'feature', 'admin.pharmacy_variance', 'admin_dashboard_screen', ''),
  ('pharmacy_vault', 'feature', 'admin.pharmacy_vault', 'home_shell', ''),
  ('play_store', 'feature', 'devtool.play_store', 'dev_queue_screen', ''),
  ('pnl', 'feature', 'admin.pnl', 'home_shell', ''),
  ('pos', 'feature', 'shop.pos', 'home_shell', ''),
  ('pos_upi', 'feature', 'shop.pos_upi', 'home_shell', ''),
  ('price_check', 'feature', 'shop.price_check', 'home_shell', ''),
  ('pricing', 'feature', 'admin.pricing_coverage', 'home_shell', ''),
  ('pricing_backfill', 'feature', 'admin.pricing_backfill', 'home_shell', ''),
  ('profile', 'feature', 'identity.view_profile', 'home_shell', ''),
  ('purchases', 'feature', 'shop.purchases', 'home_shell', ''),
  ('px_exchange', 'feature', 'admin.px_exchange', 'admin_dashboard_screen', ''),
  ('refill', 'feature', 'admin.refill', 'admin_dashboard_screen', ''),
  ('reorder', 'feature', 'admin.reorder', 'home_shell', ''),
  ('returns_refunds', 'feature', 'admin.returns_refunds', 'home_shell', ''),
  ('reviews', 'feature', 'admin.reviews', 'home_shell', ''),
  ('rx_scan', 'feature', 'admin.rx_scan', 'admin_dashboard_screen', ''),
  ('scope_audit', 'feature', 'admin.scope_audit', 'home_shell', ''),
  ('settlement', 'feature', 'partner.settlement', 'partner_home_screen', ''),
  ('settlement', 'feature', 'admin.settlement', 'home_shell', ''),
  ('signin_diag', 'feature', 'devtool.signin_diag', 'dev_queue_screen', ''),
  ('stock_on_hand', 'feature', 'admin.stock_on_hand', 'admin_dashboard_screen', ''),
  ('sup_leads', 'feature', 'admin.sup_tab.leads', 'admin_supplier_screen', ''),
  ('sup_pending', 'feature', 'admin.sup_tab.pending', 'admin_supplier_screen', ''),
  ('sup_staging', 'feature', 'admin.sup_tab.staging', 'admin_supplier_screen', ''),
  ('sup_suppliers', 'feature', 'admin.sup_tab.suppliers', 'admin_supplier_screen', ''),
  ('supplier_accounts', 'feature', 'admin.supplier_accounts', 'home_shell', ''),
  ('supplier_inquiry', 'feature', 'fulfill.supplier_inquiry', 'admin_fulfillment_screen', ''),
  ('supplier_order', 'feature', 'fulfill.supplier_order', 'admin_fulfillment_screen', ''),
  ('supplier_orders', 'feature', 'partner.supplier_orders', 'partner_home_screen', ''),
  ('supplier_payment', 'feature', 'partner.supplier_payment', 'partner_home_screen', ''),
  ('supplier_shop', 'feature', 'fulfill.supplier_shop', 'admin_fulfillment_screen', ''),
  ('suppliers', 'feature', 'admin.suppliers', 'home_shell', ''),
  ('support_inbox', 'feature', 'admin.support_inbox', 'admin_dashboard_screen', ''),
  ('test_mode', 'feature', 'admin.test_mode', 'home_shell', ''),
  ('test_mode', 'feature', 'devtool.test_mode', 'dev_queue_screen', ''),
  ('threads', 'feature', 'devtool.threads', 'dev_queue_screen', ''),
  ('unmapped_companies', 'feature', 'admin.unmapped_companies', 'home_shell', ''),
  ('users_access', 'feature', 'admin.users_access', 'home_shell', ''),
  ('wa_campaigns', 'feature', 'admin.wa_campaigns', 'home_shell', ''),
  ('wa_diagnosis', 'feature', 'admin.wa_diagnosis', 'home_shell', ''),
  ('wa_drips', 'feature', 'admin.wa_drips', 'home_shell', ''),
  ('wa_ops', 'feature', 'admin.wa_ops', 'home_shell', ''),
  ('wa_segments', 'feature', 'admin.wa_segments', 'home_shell', ''),
  ('wa_templates', 'feature', 'admin.wa_templates', 'home_shell', ''),
  ('warehouse', 'feature', 'fulfill.warehouse', 'admin_fulfillment_screen', ''),
  ('whatsapp', 'feature', 'admin.whatsapp', 'home_shell', ''),
  ('home',        'chrome',    '', 'home_shell', 'storefront home tab'),
  ('search',      'chrome',    '', 'home_shell', 'catalogue search tab'),
  ('my_shop',     'chrome',    '', 'home_shell', 'the customer My Shop tab itself (customer_nav slot)'),
  ('surface_map', 'feature',   'admin.surface_map', 'home_shell', 'CHANGE #570 — this audit'),
  ('admin_roles', 'subscreen', '', 'home_shell', 'reached from Manage admins, not a nav tile')
on conflict (route_key, feature_key) do update
  set kind = excluded.kind, handled_by = excluded.handled_by,
      note = excluded.note, is_active = true, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────
-- 1b. THE DECLARED AUDIENCE OF EACH SURFACE
--     A surface is a place features are drawn. Its audience is DATA here, in
--     one row, rather than a predicate repeated inside three resolvers — which
--     is how nav_search() and nav_registry() came to disagree in the first
--     place. A new surface is one INSERT, and until it has one the audit says
--     so out loud (drift rule R6) instead of passing it in silence.
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.surface_audience (
  surface    text primary key,
  label      text not null,
  audience   text[] not null,
  resolver   text not null default '',
  updated_at timestamptz not null default now()
);

alter table public.surface_audience enable row level security;
do $$ begin
  create policy surface_audience_read on public.surface_audience
    for select using (true);
exception when duplicate_object then null; end $$;

insert into public.surface_audience (surface, label, audience, resolver) values
  ('dashboard',    'Admin dashboard',   array['admin','super_admin','partner'], 'nav_registry()'),
  ('dev_tools',    'Dev Queue tools',   array['super_admin'],                   'dev_tools()'),
  ('customer_shop','Pharmacy My Shop',  array['customer','super_admin'],        'customer_shop_home()'),
  ('customer_tab', 'Customers screen',  array['admin','super_admin','partner'], 'partner_screen_tabs(''customer'')'),
  ('supplier_tab', 'Suppliers screen',  array['admin','super_admin','partner'], 'partner_screen_tabs(''supplier'')'),
  ('fulfill_tab',  'Fulfilment screen', array['admin','super_admin','partner'], 'fulfill_tabs()'),
  ('profile',      'Profile menu',      array['admin','super_admin','partner','supplier','customer','delivery','worker','mr','company'], 'nav_registry().profile_menu'),
  ('both',         'Profile menu',      array['admin','super_admin','partner','supplier','customer','delivery','worker','mr','company'], 'nav_registry().profile_menu')
on conflict (surface) do update
  set label = excluded.label, audience = excluded.audience,
      resolver = excluded.resolver, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────
-- 2. GAP 1 — the partner had no profile menu, and therefore no logout.
--    nav_registry() builds profile_menu from roles_allowed alone. Both
--    identity rows are already partner_eligible; the role list simply never
--    got 'partner' when the partner role was introduced.
-- ─────────────────────────────────────────────────────────────────────────
update public.feature_registry
   set roles_allowed = roles_allowed || array['partner']
 where feature_key in ('identity.view_profile','identity.logout')
   and not ('partner' = any (roles_allowed));

-- ─────────────────────────────────────────────────────────────────────────
-- 3. GAP 2 — the audit's own tile. A super-admin-only dashboard entry so the
--    report below is reachable, not an orphan RPC (§11).
-- ─────────────────────────────────────────────────────────────────────────
insert into public.ui_icon (icon_key, label) values ('rule_folder', 'Rule folder')
  on conflict (icon_key) do nothing;

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, category, surface, roles_allowed,
   search_terms, description)
values
  ('admin.surface_map', 'Surface map', 'Admin & System', 'rule_folder',
   'surface_map', 815, 'medibo', false, 'none', 'system', 'dashboard',
   array['super_admin'],
   'surface map audit role visibility feature registry drift who sees what',
   'Every feature, the audience it was built for, and the audience that can actually reach it.')
on conflict (feature_key) do update
  set label = excluded.label, icon_key = excluded.icon_key,
      route_key = excluded.route_key, category = excluded.category,
      surface = excluded.surface, roles_allowed = excluded.roles_allowed,
      search_terms = excluded.search_terms, description = excluded.description,
      is_active = true;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. LEAK 3 — the bottom bar. 'customer_only' was implemented as "signed in
--    and not an admin", which is every role that is not an admin. The audience
--    is now DATA: the same array the surface's own registry rows carry, so the
--    audit can assert entry-point audience == surface audience mechanically.
-- ─────────────────────────────────────────────────────────────────────────
alter table public.customer_nav_slot
  add column if not exists roles_allowed text[];

comment on column public.customer_nav_slot.roles_allowed is
  'CHANGE #570 — NULL means every visitor, signed in or not (the storefront '
  'slots). A non-empty array is matched against get_my_role(), so a slot that '
  'opens a customer surface cannot appear on a supplier or a rider bottom bar.';

-- `visibility` stays as it is: it is now a LABEL of intent, and roles_allowed
-- is the enforced audience. The check constraint that pins it to
-- always/customer_only is left untouched on purpose — nothing reads it any
-- more, and dropping a constraint that guards live rows is not this command's
-- to make.
update public.customer_nav_slot
   set roles_allowed = array['customer','super_admin']
 where slot_key = 'my_shop';

update public.customer_nav_slot
   set roles_allowed = null
 where slot_key in ('home','catalogue','bulk','orders');

create or replace function public.customer_nav()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  -- CHANGE #570 — the audience of a slot is the slot's own roles_allowed, not
  -- "not an admin". get_my_role() is the one role answer the whole app uses.
  with me as (select coalesce(public.get_my_role(),'none') as role)
  select jsonb_build_object(
    'ok', true,
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key',        s.slot_key,
               'label',      public._c(s.label_key),
               'icon_key',   s.icon_key,
               'page_index', s.page_index,
               'badge_key',  s.badge_key)
             order by s.sort_order, s.slot_key)
        from public.customer_nav_slot s, me
       where s.is_active
         and (s.roles_allowed is null
              or me.role = any (s.roles_allowed))), '[]'::jsonb));
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. LEAK 1 — the command palette. nav_search() and nav_registry() are two
--    doors onto the SAME dashboard surface, so they must answer the same
--    question. The predicate below is nav_registry()'s, word for word: a
--    partner is bounded by partner_eligible + partner_access, an admin by the
--    admin.% ownership rule + admin_access. Only the `where` changed.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.nav_search(p_q text, p_limit integer default 6)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_q       text := btrim(coalesce(p_q,''));
  v_like    text;
  v_groups  jsonb := '[]'::jsonb;
  v_part    jsonb;
  v_lim     int  := least(greatest(coalesce(p_limit,6),1), 20);
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
      from feature_registry f
      join nav_category c on c.category_key = f.category
     where f.is_active and f.route_key <> '' and f.surface = 'dashboard'
       and v_role = any (f.roles_allowed)
       -- CHANGE #570 — the access gate nav_registry() has always applied.
       and case when v_partner is not null
                then f.partner_eligible
                     and coalesce(public.partner_access(f.feature_key, v_partner),'none') <> 'none'
                else f.feature_key like 'admin.%'
                     and coalesce(public.admin_access(f.feature_key),'none') <> 'none' end
       and (lower(f.label) like v_like or lower(f.search_terms) like v_like
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
             'route_key', case when pp.id is not null then 'customer_360' else 'customers' end,
             'deep_link', case when pp.id is not null
                               then '/admin/go/customer_360/' || pp.id::text
                               else '/admin/go/customers' end,
             'feature_key', case when pp.id is not null then 'admin.customer_360'
                                 else 'admin.customers' end,
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
             'icon_key','people', 'icon_letter','C', 'route_key','customer_360',
             'deep_link', '/admin/go/customer_360/' || p.id::text,
             'feature_key','admin.customer_360',
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
             'icon_key','inventory', 'icon_letter','S', 'route_key','suppliers',
             'deep_link', '/admin/go/suppliers', 'feature_key','admin.suppliers',
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
end $function$

;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. LEAK 2 — screen tabs. The old body filtered "if the caller is a partner"
--    and let everyone else through the else branch, on the assumption that
--    everyone else is an admin. A supplier, a customer and a rider are not.
--    Three audiences now, named: admin/super_admin see the screen unbounded,
--    a partner sees what partner_access grants, anybody else sees nothing.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.partner_screen_tabs(p_screen text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_rows      jsonb;
  v_is_partner boolean := public.is_partner();
  v_role      text := coalesce(public.get_my_role(),'none');
  v_admin     boolean := v_role in ('admin','super_admin') and not v_is_partner;
begin
  -- CHANGE #570 — these tabs are the ADMIN console's furniture. A caller who
  -- is neither an admin nor a partner has no console to draw them in, so the
  -- payload does not carry them. Refusal copy is the backend's own.
  if not (v_admin or v_is_partner) then
    return jsonb_build_object(
      'ok', false, 'screen', p_screen, 'bounded', true, 'tabs', '[]'::jsonb,
      'zone_id', null,
      'message', coalesce(nullif(public._c('partner_tabs.not_yours'), ''),
                          'This screen is not part of your account.'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'index', t.tab_index, 'key', t.tab_key,
           'label', t.label, 'feature_key', t.feature_key,
           'access', coalesce(public.partner_access(t.feature_key),'none')
         ) order by t.sort_order), '[]'::jsonb)
    into v_rows
    from public.partner_screen_tab t
   where t.screen = p_screen
     and (not v_is_partner
          or coalesce(public.partner_access(t.feature_key),'none') <> 'none');

  return jsonb_build_object(
    'ok', true, 'screen', p_screen,
    'bounded', v_is_partner,
    'tabs', v_rows,
    'zone_id', case when v_is_partner then public.partner_zone_id() end);
end $function$;

insert into public.ui_copy (key, value) values
  ('partner_tabs.not_yours', '"This screen is not part of your account."')
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. THE TRUTH TABLE ITSELF
--    One RPC, one screen: every feature on every surface, the audience it was
--    registered for, the audience that can actually reach it, and every place
--    those two disagree. The Dart side prints this and computes nothing.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.surface_map_audit()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_role   text := coalesce(public.get_my_role(),'none');
  v_rows   jsonb;
  v_drift  jsonb := '[]'::jsonb;
  v_part   jsonb;
  v_sections jsonb := '[]'::jsonb;
  v_admins int;
begin
  if v_role <> 'super_admin' then
    return jsonb_build_object('ok', false,
      'title', 'Surface map',
      'message', coalesce(nullif(public._c('surface_map.denied'),''),
                          'Only a super admin can read the surface map.'));
  end if;

  select count(*) into v_admins from public.admins a
   where not coalesce(a.is_super,false);

  -- ── ROW 1: the feature registry, one line per feature.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key,
           'label', f.label,
           'registry_label', 'feature_registry',
           'surface_label', coalesce(s.label, f.surface),
           'resolver_label', coalesce(s.resolver, '—'),
           'intended_label', array_to_string(f.roles_allowed, ', ')
                             || case when f.partner_eligible then ' + partner' else '' end,
           'actual_label',
             case
               when f.surface in ('profile','both') then array_to_string(f.roles_allowed, ', ')
               when f.surface = 'dashboard' and f.feature_key not like 'admin.%'
                    and not f.partner_eligible then 'nobody — no admin.% key, not partner-eligible'
               when f.surface = 'dashboard' then
                 array_to_string(array_remove(f.roles_allowed, 'partner'), ', ')
                 || case when f.partner_eligible then ' + partner (by grant)' else '' end
               else array_to_string(f.roles_allowed, ', ')
             end,
           'route_label', case when f.route_key = '' then 'no route — section header'
                               else coalesce(r.handled_by, 'NO DOOR') || ' · ' || f.route_key end,
           'tone', case when f.route_key <> '' and r.route_key is null then 'danger'
                        when f.surface not in (select surface from public.surface_audience) then 'warning'
                        when exists (select 1 from unnest(f.roles_allowed) x
                                      where not (x = any (s.audience))) then 'warning'
                        else 'success' end)
         order by f.surface, f.category, f.sort_order), '[]'::jsonb)
    into v_rows
    from public.feature_registry f
    left join public.surface_audience s on s.surface = f.surface
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active;

  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'heading', 'Feature registry — ' || (select count(*)::text from public.feature_registry where is_active) || ' active features',
    'empty_hint', 'The registry is empty.',
    'rows', v_rows));

  -- ── ROW 2: the supplier's own registry. A separate table on purpose: a
  --    supplier is not an admin subject and never appears in access_effective.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', sf.feature_key,
           'label', public._c(sf.copy_key),
           'registry_label', 'supplier_feature',
           'surface_label', 'Supplier portal',
           'resolver_label', 'supplier_session()',
           'intended_label', 'supplier, supplier staff (clamped)',
           'actual_label', 'supplier, supplier staff (clamped)',
           'route_label', 'supplier_shell · ' || sf.feature_key,
           'tone', case when sf.is_active then 'success' else 'neutral' end)
         order by sf.sort_order), '[]'::jsonb)
    into v_part from public.supplier_feature sf;

  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'heading', 'Supplier portal — ' || (select count(*)::text from public.supplier_feature where is_active) || ' features',
    'empty_hint', 'No supplier feature is registered.',
    'rows', v_part));

  -- ── ROW 3: the bottom bar every signed-in visitor shares.
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', s.slot_key,
           'label', public._c(s.label_key),
           'registry_label', 'customer_nav_slot',
           'surface_label', 'Bottom bar',
           'resolver_label', 'customer_nav()',
           'intended_label', coalesce(array_to_string(s.roles_allowed, ', '), 'everyone, signed in or not'),
           'actual_label', coalesce(array_to_string(s.roles_allowed, ', '), 'everyone, signed in or not'),
           'route_label', 'home_shell · page ' || s.page_index::text,
           'tone', 'success')
         order by s.sort_order), '[]'::jsonb)
    into v_part from public.customer_nav_slot s where s.is_active;

  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'heading', 'Bottom bar — ' || (select count(*)::text from public.customer_nav_slot where is_active) || ' slots',
    'empty_hint', 'No slot is registered.',
    'rows', v_part));

  -- ── DRIFT. Six mechanical rules. Every one of them caught a real defect on
  --    the day it was written; they are here so the next one is caught by CI.

  -- R1 · a live tile whose route no dispatcher declares — a door that opens
  --      onto nothing. (admin.delivery_extras / delivery_waves /
  --      returns_refunds were exactly this.)
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','unrouted_feature', 'tone','danger',
           'label', f.label || ' has no door',
           'feature_key', f.feature_key,
           'detail', 'route_key "' || f.route_key || '" is not declared in surface_route, '
                     || 'so tapping the tile lands in the shell''s default branch.')
         ), '[]'::jsonb) into v_part
    from public.feature_registry f
    left join public.surface_route r
      on r.route_key = f.route_key and r.feature_key = f.feature_key and r.is_active
   where f.is_active and f.route_key <> '' and r.route_key is null;
  v_drift := v_drift || v_part;

  -- R2 · a declared feature door naming a feature that is gone or switched off.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','orphan_route', 'tone','warning',
           'label', 'Route ' || r.route_key || ' points at nothing',
           'feature_key', coalesce(r.feature_key,''),
           'detail', 'surface_route says kind=feature, but no ACTIVE feature_registry row carries that key.')
         ), '[]'::jsonb) into v_part
    from public.surface_route r
   where r.is_active and r.kind = 'feature'
     and not exists (select 1 from public.feature_registry f
                      where f.is_active and f.feature_key = r.feature_key);
  v_drift := v_drift || v_part;

  -- R3 · a role that can sign in but is not on the profile menu — no View
  --      Profile and, worse, no Logout. (The partner was in this state.)
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','role_cannot_sign_out', 'tone','danger',
           'label', u.role_key || ' has no profile menu',
           'feature_key','identity.logout',
           'detail', u.role_key || ' accounts can sign in, but the role is missing from '
                     || 'identity.* roles_allowed, so nav_registry() returns them an empty '
                     || 'profile_menu — including no way to log out.')
         ), '[]'::jsonb) into v_part
    from (select unnest(array['admin','super_admin','partner','supplier','customer',
                              'delivery','worker','mr','company']) as role_key) u
   where not exists (
     select 1 from public.feature_registry f
      where f.feature_key = 'identity.logout' and f.is_active
        and u.role_key = any (f.roles_allowed));
  v_drift := v_drift || v_part;

  -- R4 · an entry point whose audience is not its destination's audience.
  --      The My Shop tab sat on the supplier's, the partner's and the rider's
  --      bottom bar while the surface behind it admits only a pharmacy.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','entry_audience_mismatch', 'tone','danger',
           'label', 'My Shop tab audience ≠ My Shop surface audience',
           'feature_key','my_shop',
           'detail', 'bottom-bar slot admits [' || coalesce(array_to_string(s.roles_allowed,', '),'everyone')
                     || '] while the customer_shop features admit ['
                     || (select string_agg(distinct x, ', ' order by x)
                           from public.feature_registry f, unnest(f.roles_allowed) x
                          where f.is_active and f.surface = 'customer_shop') || '].')
         ), '[]'::jsonb) into v_part
    from public.customer_nav_slot s
   where s.slot_key = 'my_shop' and s.is_active
     and coalesce(
           (select array_agg(distinct x order by x)
              from public.feature_registry f, unnest(f.roles_allowed) x
             where f.is_active and f.surface = 'customer_shop'),
           array[]::text[])
         is distinct from
         (select array_agg(distinct y order by y) from unnest(coalesce(s.roles_allowed, array[]::text[])) y);
  v_drift := v_drift || v_part;

  -- R5 · a feature registered onto a surface its own role list contradicts —
  --      a pharmacy tile wearing admin roles, an admin tool wearing customer.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','wrong_surface', 'tone','danger',
           'label', f.label || ' is on the wrong surface',
           'feature_key', f.feature_key,
           'detail', 'surface ' || f.surface || ' serves [' || array_to_string(sc.audience, ', ')
                     || '] but the row admits [' || array_to_string(f.roles_allowed, ', ') || '].')
         ), '[]'::jsonb) into v_part
    from public.feature_registry f
    join public.surface_audience sc on sc.surface = f.surface
   where f.is_active
     and exists (select 1 from unnest(f.roles_allowed) x where not (x = any (sc.audience)));
  v_drift := v_drift || v_part;

  -- R6 · a surface nothing in this audit knows about. Forward compatibility:
  --      a new surface must be declared here, or its audience is unchecked.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code','undeclared_surface', 'tone','warning',
           'label', 'Surface "' || f.surface || '" has no declared audience',
           'feature_key', f.surface,
           'detail', 'Add it to the surface table inside surface_map_audit() so its rows are audited.')
         ), '[]'::jsonb) into v_part
    from (select distinct surface from public.feature_registry where is_active) f
   where not exists (select 1 from public.surface_audience s where s.surface = f.surface);
  v_drift := v_drift || v_part;

  return jsonb_build_object(
    'ok', true,
    'title', coalesce(nullif(public._c('surface_map.title'),''), 'Surface map'),
    'subtitle', coalesce(nullif(public._c('surface_map.subtitle'),''),
                'Every feature, the audience it was registered for, and the audience that can reach it.'),
    'drift', v_drift,
    'drift_count', jsonb_array_length(v_drift),
    -- the four row captions the screen prints. Renaming one is an UPDATE.
    'labels', jsonb_build_object(
      'intended', coalesce(nullif(public._c('surface_map.built_for'),''), 'Built for'),
      'actual',   coalesce(nullif(public._c('surface_map.reaches'),''),   'Reaches'),
      'surface',  coalesce(nullif(public._c('surface_map.surface'),''),   'Surface'),
      'route',    coalesce(nullif(public._c('surface_map.door'),''),      'Door')),
    'clean_label', coalesce(nullif(public._c('surface_map.clean'),''),
                            'No mapping drift — every feature reaches exactly its own audience.'),
    'drift_heading', case when jsonb_array_length(v_drift) = 1
                          then '1 mapping problem'
                          else jsonb_array_length(v_drift)::text || ' mapping problems' end,
    'summary', jsonb_build_array(
      jsonb_build_object('label','Features', 'value_label',
        (select count(*)::text from public.feature_registry where is_active), 'tone','neutral'),
      jsonb_build_object('label','Doors declared', 'value_label',
        (select count(*)::text from public.surface_route where is_active), 'tone','neutral'),
      jsonb_build_object('label','Surfaces', 'value_label',
        (select count(*)::text from (select distinct surface from public.feature_registry where is_active) q), 'tone','neutral'),
      jsonb_build_object('label','Admins bound by grants', 'value_label', v_admins::text, 'tone','neutral'),
      jsonb_build_object('label','Drift', 'value_label', jsonb_array_length(v_drift)::text,
        'tone', case when jsonb_array_length(v_drift) = 0 then 'success' else 'danger' end)),
    'sections', v_sections);
end $function$;

revoke all on function public.surface_map_audit() from public, anon;
grant execute on function public.surface_map_audit() to authenticated, service_role;

insert into public.ui_copy (key, value) values
  ('surface_map.title',    '"Surface map"'),
  ('surface_map.subtitle', '"Every feature, the audience it was registered for, and the audience that can reach it."'),
  ('surface_map.clean',    '"No mapping drift — every feature reaches exactly its own audience."'),
  ('surface_map.denied',   '"Only a super admin can read the surface map."'),
  ('surface_map.built_for','"Built for"'),
  ('surface_map.reaches',  '"Reaches"'),
  ('surface_map.surface',  '"Surface"'),
  ('surface_map.door',     '"Door"'),
  ('surface_map.load_failed','"The surface map could not be loaded."'),
  ('surface_map.retry',    '"Retry"')
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. THE GUARD. rg_check() runs this on every deploy: a feature registered to
--    the wrong surface, a door that leads nowhere, a role that cannot log out,
--    or any of the three leaks re-opening now fails CI instead of reaching
--    Om's phone. Each assertion names the account it impersonated.
-- ─────────────────────────────────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c570_surface_map', $rg$
do $x$
declare
  v jsonb; v_super uuid; v_admin uuid; v_sup uuid; v_cust uuid; v_denied text;
begin
  select u.id into v_super from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where not coalesce(a.is_super,false) limit 1;
  select u.id into v_sup  from auth.users u where lower(u.email) = 'test.sup1@medibo.in';
  select u.id into v_cust from auth.users u where lower(u.email) = 'test.cust1@medibo.in';
  if v_super is null then raise exception 'RG_ROLLBACK'; end if;

  -- 1. the audit itself is clean, and it is super-admin only.
  perform set_config('request.jwt.claims',
    (select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text
       from auth.users u where u.id = v_super), true);
  v := public.surface_map_audit();
  if (v->>'ok') <> 'true' then raise exception 'surface_map_audit refused a super admin: %', v; end if;
  if (v->>'drift_count')::int <> 0 then
    raise exception 'surface mapping drift: % · %', v->>'drift_count', v->'drift';
  end if;

  -- 2. LEAK 1 — the palette may never offer a feature the dashboard denies.
  if v_admin is not null then
    perform set_config('request.jwt.claims',
      (select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text
         from auth.users u where u.id = v_admin), true);
    select f.feature_key into v_denied
      from feature_registry f
     where f.is_active and f.surface = 'dashboard' and f.route_key <> ''
       and 'admin' = any (f.roles_allowed)
       and coalesce(public.admin_access(f.feature_key),'none') = 'none'
     limit 1;
    if v_denied is not null then
      if exists (
        select 1 from jsonb_array_elements(public.nav_search(
                        (select lower(label) from feature_registry where feature_key = v_denied)
                      )->'groups') g,
                     jsonb_array_elements(g->'items') i
         where i->>'feature_key' = v_denied) then
        raise exception 'nav_search offered % to an admin the dashboard denies', v_denied;
      end if;
    end if;
    -- and it may never offer a partner-owned feature to an admin console that
    -- has no case for its route.
    if exists (
      select 1 from jsonb_array_elements(public.nav_search('supplier')->'groups') g,
                   jsonb_array_elements(g->'items') i
       where g->>'key' = 'screens' and i->>'feature_key' like 'partner.%') then
      raise exception 'nav_search offered a partner.% feature to an admin';
    end if;
  end if;

  -- 3. LEAK 2 — screen tabs are admin/partner furniture. Nobody else.
  if v_sup is not null then
    perform set_config('request.jwt.claims',
      (select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text
         from auth.users u where u.id = v_sup), true);
    v := public.partner_screen_tabs('customer');
    if (v->>'ok') <> 'false' or jsonb_array_length(v->'tabs') <> 0 then
      raise exception 'partner_screen_tabs leaked the customer console to a supplier: %', v;
    end if;
    -- 4. LEAK 3 — and the pharmacy My Shop tab is not on his bottom bar.
    if exists (select 1 from jsonb_array_elements(public.customer_nav()->'slots') s
                where s->>'key' = 'my_shop') then
      raise exception 'my_shop slot leaked onto a supplier bottom bar';
    end if;
  end if;

  -- 5. and the pharmacy still HAS it — a fence that closes the shop is a bug.
  if v_cust is not null then
    perform set_config('request.jwt.claims',
      (select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text
         from auth.users u where u.id = v_cust), true);
    if not exists (select 1 from jsonb_array_elements(public.customer_nav()->'slots') s
                    where s->>'key' = 'my_shop') then
      raise exception 'my_shop slot vanished from the pharmacy bottom bar';
    end if;
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$rg$, true,
 'CHANGE #570 — the surface map: no drift, and the three leaks (palette past admin_access, screen tabs to non-admins, My Shop on a non-pharmacy bottom bar) stay shut.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;
