-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2063 — the branch seed that lets the STOREFRONT journeys actually run.
--
-- Why this file exists
-- -------------------
-- A build branch is production's SCHEMA with no data (branch_lifecycle.sh).
-- branch_seed.sql brings the synthetic cast and branch_seed_journeys.sql the
-- reference copy — and three required storefront journeys still could not run,
-- so qa-274-57, qa-698-substitute and qa-1812-standby-only were reported RED
-- against whatever command happened to be building (#2059 among them). None of
-- them was ever a regression. What was missing:
--
--   1. THE DERIVED STOREFRONT TABLES WERE NEVER BUILT. 1,500 MEDICINE rows
--      were loaded but storefront_feed / storefront_feed_z / medicine_company
--      stayed at 0, so the anonymous home feed carried two empty grids and no
--      product cards at all. qa-274-57 walks anon cards for a PTR leak; with
--      zero cards walked it can only fail ("anon cards walked=0").
--
--   2. catalogue_zone_avail WAS EMPTY, so zone_available() (#2023's one
--      availability truth) was false for every pack in every zone.
--
--   3. THE JOURNEY CUSTOMER COULD NOT BUY ANYTHING. "TST JOURNEY PHARMACY —
--      REAL-MODE" is the non-synthetic approved pharmacy the probes fall back
--      to, and it was seeded into zone 99 (tst) — the one zone that is
--      is_active=false AND is_synthetic=true, which zone_avail_backfill()
--      excludes by design. No zone availability can ever exist there, so
--      qa-698-substitute reported "no live customer or no zone-stocked
--      substitutable product to test with" forever. Its user_id did not exist
--      in auth.users either, so the probe's own order insert would have died
--      on orders_user_id_fkey (lesson 302 part 5). The SYNTHETIC cast stays in
--      zone 99 — that pinning is deliberate and is not touched here.
--
--   4. mode_scoped_table WAS EMPTY, so mode_views_refresh() created zero
--      views and anything reading mode.order_items raised
--      'relation "mode.order_items" does not exist' mid-chain.
--
-- Branch-only. Nothing here is a production migration and nothing here runs
-- against live. Idempotent: safe to re-apply to the same branch.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. The mode registry, so mode.* views exist ────────────────────────────
insert into public.mode_scoped_table (table_name)
select t from unnest(array[
  'bag_allocations','bag_sessions','bags','bill_lines','deliveries',
  'delivery_claims','delivery_events','delivery_leg_history',
  'delivery_payout_lines','delivery_runs','fulfil_task','gst_ledger',
  'handling_damage','incentive_earnings','inquiry','khata_account',
  'khata_entry','khata_statement','loyalty_ledger','order_alert','order_costs',
  'order_fulfilment_snapshot','order_items','order_pnl_slab',
  'order_substitute_ask','orders','partner_settlements','payment_claims',
  'pending_bills','pending_orders','pharmacy_gst_ledger',
  'pharmacy_purchase_bill','pharmacy_stock','pos_sale_lines','pos_sales',
  'razorpay_qr','receiving_log','refunds','settlement_invoice',
  'stock_movement','supplier_disputes','supplier_orders','supplier_payments',
  'supplier_return']) t
on conflict do nothing;

select public.mode_views_refresh();

-- ── 2. The journey customer is a REAL customer in a REAL zone ──────────────
-- An auth user the FK can point at. The branch is throwaway and this account
-- has no password grant: it exists so a probe's rolled-back order can name it.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin)
select '00000000-0000-0000-0000-000000000000', pp.user_id,
       'authenticated', 'authenticated',
       'tst.journey+' || left(pp.user_id::text, 8) || '@medibo.in', '',
       now(), now(), now(),
       '{"provider":"email","providers":["email"]}'::jsonb,
       '{"full_name":"TST Journey Pharmacy"}'::jsonb, false
  from public.pharmacy_profiles pp
 where pp.approved
   and coalesce(pp.is_synthetic, false) = false
   and coalesce(pp.is_deleted, false) = false
   and pp.user_id is not null
   and not exists (select 1 from auth.users u where u.id = pp.user_id)
on conflict (id) do nothing;

-- …and it is moved out of the synthetic test zone into the default real zone,
-- which is the only place catalogue_zone_avail is ever populated.
update public.pharmacy_profiles pp
   set zone_id = public.zone_default_id()
 where pp.approved
   and coalesce(pp.is_synthetic, false) = false
   and coalesce(pp.is_deleted, false) = false
   and exists (select 1 from public.zones z
                where z.id = pp.zone_id
                  and (z.is_active is not true
                       or coalesce(z.is_synthetic, false) is true));

-- ── 3. The derived storefront tables, built from the MEDICINE slice ────────
select public.refresh_medicine_companies();
select public.refresh_storefront_feed();
select public.zone_avail_backfill();

-- A home payload built before any of the above is a cache of an empty shop.
delete from public.storefront_home_cache;

-- ── 4. The two config tables the substitute chain asserts on ──────────────
-- qa-698-substitute reads cron_task.enabled for its own tick and counts the
-- three WhatsApp routes CHANGE #698 ships. Both are EMPTY on a fresh branch
-- (lesson 302 part 3: "cron_task 4 vs 158"), so the probe read production
-- contract as OFF. Only the rows the chain names are seeded, and their enabled
-- flags are live's own — copying all 163 cron rows would hand a build branch
-- production's work_sql to run.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql,
                              step_timeout_ms, enabled, note,
                              base_interval_s, max_interval_s,
                              current_interval_s, dml)
values ('substitute_ask_tick', 22, 'poll',
        'select false', 'select public.substitute_ask_tick(50)', 8000, true,
        'CHANGE #698 — opens substitute asks, expires the 10-minute timer, applies the first Available, notifies the outcome. Branch seed: the gate is false so a build branch never runs it.',
        60, 3600, 3600, true)
on conflict (name) do update set enabled = excluded.enabled;

insert into public.wa_event_routes (event_key, label, description,
                                    template_name, language, enabled, audience)
values
  ('order_substitute_ask', 'Substitute offer — ask the customer',
   'CHANGE #698 — a line could not be sourced. Offers up to three equal substitutes and a 10-minute link.',
   'order_substitute_ask', 'en', true, 'customer'),
  ('order_substitute_applied', 'Substitute confirmed',
   'CHANGE #698 — a distributor confirmed one of the substitutes the customer accepted.',
   'order_substitute_applied', 'en', true, 'customer'),
  ('order_substitute_none', 'No substitute available',
   'CHANGE #698 — the offer closed with nothing to supply; the order ships without the line.',
   'order_substitute_none', 'en', true, 'customer')
on conflict (event_key) do update set enabled = excluded.enabled;

-- ── 5. dashboard_section, so feature_registry's FK can be satisfied ────────
-- Empty on a fresh branch, which makes every UPDATE that assigns a feature to
-- a dashboard section fail the FK on the branch while passing on live — a
-- migration that is correct reads as broken. These eight are live's own.
insert into public.dashboard_section (section_key, label_key, sort_order,
                                      badged_only, show_when_empty, is_active)
values
  ('needs_now',      'dashboard_home.section_needs_now',      10, true,  false, true),
  ('onboarding',     'dashboard_home.section_onboarding',     20, false, false, true),
  ('field_growth',   'dashboard_home.section_field_growth',   30, false, false, true),
  ('orders',         'dashboard_home.section_orders',         35, false, false, true),
  ('delivery',       'dashboard_home.section_delivery',       40, false, false, true),
  ('money_partners', 'dashboard_home.section_money_partners', 45, false, false, true),
  ('returns_issues', 'dashboard_home.section_returns_issues', 50, false, false, true),
  ('my_work',        'dashboard_home.section_my_work',        60, false, false, true)
on conflict (section_key) do nothing;

-- ── 6. surface_route, so the nav-orphan gate can see the doors ────────────
-- The deploy-time gate (scripts/check_nav_orphans.sh) runs against the BUILD
-- BRANCH, not live — MEDIBO_DBURL_FILE points at ~/.medibo/build_dburl. The
-- branch carried 3 of live's 190 routes, so admin.customers read as a feature
-- that "lost its only door" and the gate aborted a deploy whose branch had not
-- touched navigation at all. Live's own 190 rows, copied verbatim.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active) values ('add_customer', 'admin.add_customer', 'feature', 'home_shell', '', true),
  ('add_medicine', 'admin.add_medicine', 'feature', 'home_shell', '', true),
  ('add_supplier', 'admin.add_supplier', 'feature', 'home_shell', '', true),
  ('admin_conditions', 'admin.conditions', 'feature', 'home_shell', 'CMD #1910 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.', true),
  ('admin_push', 'admin.admin_push', 'feature', 'home_shell', '', true),
  ('admin_roles', '', 'subscreen', 'home_shell', 'reached from Manage admins, not a nav tile', true),
  ('advance_slabs', 'advance_slabs', 'feature', 'home_shell', 'CMD #1933 — Advance slabs, More ▸ Catalogue & pricing, opened from shell/shell_extra_routes.dart', true),
  ('agreement_versions', 'admin.agreement_versions', 'feature', 'home_shell', 'CMD #1985 — Admin › Partner agreement, opened from shell/shell_extra_routes.dart', true),
  ('assign_delivery', 'partner.assign_delivery', 'feature', 'partner_home_screen', '', true),
  ('audit_log', 'admin.audit_log', 'feature', 'home_shell', '', true),
  ('bag', 'fulfill.bag', 'feature', 'admin_fulfillment_screen', '', true),
  ('bag_mapping', 'partner.bag_mapping', 'feature', 'partner_home_screen', '', true),
  ('bags', 'admin.bags', 'feature', 'home_shell', '', true),
  ('bill_pipeline', 'admin.bill_pipeline', 'feature', 'home_shell', '', true),
  ('bug_report', 'devtool.bug_report', 'feature', 'dev_queue_screen', '', true),
  ('build_intelligence', 'devtool.build_intelligence', 'feature', 'dev_queue_screen', 'CMD #1824 tile. kDevToolKeys carries the key; openDevTool() pushes BuildIntelligenceScreen.', true),
  ('bulk_actions', 'admin.bulk_actions', 'feature', 'home_shell', '', true),
  ('cart_bill', 'admin.cart_bill', 'feature', 'shell_extra_routes', 'CMD #2014 — AdminCartBillScreen', true),
  ('catalogue_health', 'admin.catalogue_health', 'feature', 'home_shell', '', true),
  ('chaos_lab', 'devtool.chaos', 'feature', 'dev_queue_screen', 'CMD #1810 — openDevTool() -> ChaosLabScreen; /admin/go/chaos_lab resolves through kDevToolKeys.', true),
  ('collect', 'partner.collect', 'feature', 'partner_home_screen', '', true),
  ('companies', 'admin.companies', 'feature', 'home_shell', '', true),
  ('count', 'partner.count', 'feature', 'partner_home_screen', '', true),
  ('cron_health', 'admin.cron_health', 'feature', 'home_shell', '', true),
  ('cron_health', 'devtool.cron_health', 'feature', 'dev_queue_screen', '', true),
  ('cust_account', 'cust.my_account', 'feature', 'customer_menu', 'CHANGE #978 — opened by profile_account_menu.dart''s ''cust_account'' arm.', true),
  ('cust_addresses', 'cust.address_book', 'feature', 'customer_menu', 'AddressBookScreen', true),
  ('cust_cart', 'admin.cust_tab.cart', 'feature', 'admin_customer_screen', '', true),
  ('cust_customers', 'admin.cust_tab.customers', 'feature', 'admin_customer_screen', '', true),
  ('cust_delete_account', 'cust.delete_account', 'feature', 'customer_menu', 'DeleteAccountSection', true),
  ('cust_help_requests', 'cust.help_requests', 'feature', 'home_shell', '', true),
  ('cust_leads', 'admin.cust_tab.leads', 'feature', 'admin_customer_screen', '', true),
  ('cust_logout', 'cust.logout', 'feature', 'customer_menu', 'sign out action', true),
  ('cust_loyalty_admin', 'cust.loyalty_admin', 'feature', 'customer_menu', 'LoyaltyAdminScreen', true),
  ('cust_notifications', 'cust.notifications', 'feature', 'customer_menu', 'NotificationsInboxScreen', true),
  ('cust_orders', 'cust.orders', 'feature', 'customer_menu', 'CHANGE #978 — opened by profile_account_menu.dart''s ''cust_orders'' arm.', true),
  ('cust_pending', 'admin.cust_tab.pending', 'feature', 'admin_customer_screen', '', true),
  ('cust_profile_edit', 'cust.profile_edit', 'feature', 'customer_menu', 'ProfileEditScreen', true),
  ('cust_profile_home', 'cust.profile_home', 'feature', 'customer_menu', 'ProfileScreen', true),
  ('cust_reorder_due', 'cust.reorder_due', 'feature', 'home_shell', '', true),
  ('cust_rewards', 'cust.rewards', 'feature', 'customer_menu', 'RewardsScreen', true),
  ('cust_routes', 'admin.cust_tab.routes', 'feature', 'admin_customer_screen', '', true),
  ('cust_routes_assign', 'admin.cust_tab.routes_assign', 'feature', 'customer_tab', 'CMD #2056 tile; opened as tab_screen routes:past_plans via kRoutesSectionModes.', true),
  ('cust_routes_builder', 'admin.cust_tab.routes_builder', 'feature', 'customer_tab', 'CMD #2056 tile; opened as tab_screen routes:all_plans via kRoutesSectionModes.', true),
  ('cust_routes_today', 'admin.cust_tab.routes_today', 'feature', 'customer_tab', 'CMD #2056 tile; opened as tab_screen routes:today via kRoutesSectionModes.', true),
  ('cust_s_leads', 'admin.cust_tab.s_leads', 'feature', 'admin_customer_screen', '', true),
  ('cust_saved_lists', 'cust.saved_lists', 'feature', 'home_shell', '', true),
  ('cust_staff_logins', 'cust.staff_logins', 'feature', 'customer_menu', 'CustomerStaffScreen', true),
  ('cust_wishlist', 'cust.wishlist', 'feature', 'customer_menu', 'WishlistScreen', true),
  ('customer_360', 'admin.customer_360', 'feature', 'admin_dashboard_screen', '', true),
  ('customer_doc_types', 'admin.customer_doc_types', 'feature', 'home_shell', 'CMD #1935 — Admin › Customer documents, opened from shell/shell_extra_routes.dart', true),
  ('customer_order', 'fulfill.customer_order', 'feature', 'admin_fulfillment_screen', '', true),
  ('customer_orders', 'partner.customer_orders', 'feature', 'partner_home_screen', '', true),
  ('customers', 'admin.customers', 'feature', 'home_shell', '', true),
  ('damage_report', 'partner.damage_report', 'feature', 'home_shell', 'CHANGE #709 — the damage report; opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.', true),
  ('dashboard', 'admin.dashboard', 'feature', 'home_shell', '', true),
  ('deletion_requests', 'admin.deletion_requests', 'feature', 'home_shell', '', true),
  ('delivery', 'fulfill.delivery', 'feature', 'admin_fulfillment_screen', '', true),
  ('delivery_extras', 'admin.delivery_extras', 'feature', 'home_shell', '', true),
  ('delivery_ops', 'admin.delivery_ops', 'feature', 'home_shell', '', true),
  ('delivery_partners', 'admin.delivery_partners', 'feature', 'home_shell', '', true),
  ('delivery_waves', 'admin.delivery_waves', 'feature', 'home_shell', '', true),
  ('demand_engine', 'admin.demand_engine', 'feature', 'home_shell', '', true),
  ('dev_queue', 'admin.dev_queue', 'feature', 'home_shell', '', true),
  ('discount_slabs', 'admin.discount_slabs', 'feature', 'home_shell', '', true),
  ('dispute', 'fulfill.dispute', 'feature', 'admin_fulfillment_screen', '', true),
  ('disputes', 'partner.disputes', 'feature', 'partner_home_screen', '', true),
  ('drafts_inbox', 'devtool.drafts', 'feature', 'dev_queue_screen', '', true),
  ('exceptions', 'fulfill.exceptions', 'feature', 'home_shell', 'CHANGE #690 — home_shell opens the fulfilment screen and asks it for the stage; AdminFulfillmentScreen.openStage selects it', true),
  ('exceptions', 'partner.exceptions', 'feature', 'admin_fulfillment_screen', 'CHANGE #690 — the same stage under the partner feature key', true),
  ('exports', 'admin.exports', 'feature', 'home_shell', '', true),
  ('feature_gaps', 'admin.feature_gaps', 'feature', 'home_shell', '', true),
  ('feedback', 'admin.feedback', 'feature', 'home_shell', 'CHANGE #697 — the screen is opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart, which home_shell reaches through its one `case _ when shellExtraRouteScreen(route) != null` lookup. Declared #810, note corrected #821.', true),
  ('fulfil_tasks', 'partner.fulfil_tasks', 'feature', 'home_shell', 'CHANGE #707 — the fulfilment task board (who owns each stage). Opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart. fulfil_task_board() answers a caller who is neither office nor partner with can_write:false and its own refusal, so the door is not the guard.', true),
  ('fulfillment', 'admin.fulfillment', 'feature', 'home_shell', '', true),
  ('gcp_control', 'devtool.gcp', 'feature', 'dev_queue_screen', '', true),
  ('gst', 'admin.gst', 'feature', 'home_shell', '', true),
  ('heartbeat', 'devtool.heartbeat', 'feature', 'dev_queue_screen', 'CHANGE #468 — openDevTool() pushes AdminHeartbeatScreen.', true),
  ('home', '', 'chrome', 'home_shell', 'storefront home tab', true),
  ('inquiry', 'partner.inquiry', 'feature', 'partner_home_screen', '', true),
  ('journey_bot', 'devtool.journey_bot', 'feature', 'dev_queue_screen', 'Dev Queue -> Tools -> Journey bot (openDevTool case journey_bot)', true),
  ('journey_bot', 'devtool.order_pipeline', 'feature', 'dev_queue_screen', 'alias of devtool.journey_bot — same door, kept routed so R1 sees it', true),
  ('journey_library', 'devtool.journeys', 'feature', 'dev_queue_screen', '', true),
  ('khata', 'admin.khata', 'feature', 'admin_dashboard_screen', '', true),
  ('kyc_review', 'partner.kyc_review', 'feature', 'home_shell', 'CHANGE #705 — the KYC review console; opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart, which home_shell reaches through its one shellExtraRouteScreen(route) lookup.', true),
  ('logout', 'identity.logout', 'feature', 'home_shell', '', true),
  ('loyalty', 'admin.loyalty', 'feature', 'home_shell', '', true),
  ('manage_admins', 'admin.manage_admins', 'feature', 'home_shell', '', true),
  ('memory', 'devtool.memory', 'feature', 'dev_queue_screen', '', true),
  ('money', 'admin.money', 'feature', 'home_shell', '', true),
  ('money_home', '', 'chrome', 'home_shell', 'CHANGE #1016 — the Money tab (staff_home(''money''))', true),
  ('more', '', 'chrome', 'home_shell', 'CHANGE #1016 — the More tab (staff_home(''more''))', true),
  ('mr', 'admin.mr', 'feature', 'home_shell', '', true),
  ('my_shop', '', 'chrome', 'home_shell', 'the customer My Shop tab itself (customer_nav slot)', true),
  ('my_tasks', 'worker.my_tasks', 'feature', 'home_shell', 'CHANGE #707 — the worker''s own list for today, in promised order. Opened by shellExtraRouteScreen(); fulfil_my_tasks() refuses anyone who is not a worker, so the door being open to a role decides nothing.', true),
  ('near_listing', 'pharmacy.near_listing', 'feature', 'admin_dashboard_screen', '', true),
  ('notif_trail', 'admin.notif_trail', 'feature', 'home_shell', 'CMD #1987 — Admin › Message trail, opened from shell/shell_extra_routes.dart', true),
  ('notify_center', 'admin.notify_center', 'feature', 'home_shell', '', true),
  ('notify_cost', 'admin.notify_cost', 'feature', 'home_shell', '', true),
  ('onboarding_notices', 'admin.onboarding_notices', 'feature', 'home_shell', 'CMD #1936 — opened by shell_extra_routes.dart, not the shell''s own switch: home_shell.dart sits at 1,998 of a hard 2,000-line guard.', true),
  ('ops_board', 'fulfill.ops_board', 'feature', 'home_shell', 'CHANGE #756 — home_shell takes /admin/go/ops_board and shellOpenFulfillStage() opens Fulfill on the ops_board stage (the #754 pairing)', true),
  ('ops_board', 'partner.ops_board', 'feature', 'admin_fulfillment_screen', 'CHANGE #756 — the same stage under the partner feature key', true),
  ('ops_queues', 'admin.ops_queues', 'feature', 'home_shell', '', true),
  ('order_alerts', 'admin.order_alerts', 'feature', 'home_shell', '', true),
  ('order_closure', 'admin.order_closure', 'feature', 'home_shell', '', true),
  ('order_cutoff', 'admin.order_cutoff', 'feature', 'home_shell', 'Order cut-off — opened by shellExtraRouteScreen in shell/shell_extra_routes.dart (CMD #1934).', true),
  ('order_threads', 'partner.order_threads', 'feature', 'home_shell', 'CHANGE #713 — customer messages waiting on an answer, plus the calls somebody owes a customer. Opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart. thread_inbox() answers a partner with their own zone and the office with all of them and refuses anyone who is neither, so the door is not the guard.', true),
  ('order_timeline', 'fulfill.order_timeline', 'feature', 'home_shell', 'CHANGE #689 — case ''order_timeline'' in _handleAdminNav calls shellOpenOrderTimeline(); declared here by CHANGE #821', true),
  ('pack', 'fulfill.pack', 'feature', 'admin_fulfillment_screen', '', true),
  ('pack', 'partner.pack', 'feature', 'partner_home_screen', '', true),
  ('paper_sale', 'admin.paper_sale', 'feature', 'home_shell', '', true),
  ('partner_documents', 'partner.documents', 'feature', 'home_shell', 'CHANGE #1016 — opened by shellStaffRouteScreen() in lib/screens/shell/shell_staff_routes.dart', true),
  ('partner_expenses', 'partner.expenses', 'feature', 'home_shell', 'CHANGE #1016 — opened by shellStaffRouteScreen() in lib/screens/shell/shell_staff_routes.dart', true),
  ('partner_issues', 'admin.partner_issues', 'feature', 'home_shell', 'CHANGE #696 - the mediBO <-> partner escalation channel. Opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart. partner_ticket_list() answers a partner with their OWN issues and the office with every zone, and refuses anyone who is neither, so the door is not the guard.', true),
  ('partner_scorecard', 'partner.scorecard', 'feature', 'home_shell', 'CHANGE #693 — same lookup; the partner sees its own card, admin sees the ranked list.', true),
  ('partner_scorecards', 'admin.partner_scorecards', 'feature', 'home_shell', 'CHANGE #693 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart, which home_shell reaches through its one `case _ when shellExtraRouteScreen(route) != null` lookup.', true),
  ('partner_settlement', 'partner.settlement', 'feature', 'home_shell', 'CHANGE #1016 — the partner statement; opened by shellStaffRouteScreen()', true),
  ('partner_staff', 'partner.staff', 'feature', 'home_shell', 'CHANGE #1016 — opened by shellStaffRouteScreen() in lib/screens/shell/shell_staff_routes.dart', true),
  ('partner_workers', 'partner.workers', 'feature', 'home_shell', 'CHANGE #1016 — opened by shellStaffRouteScreen() in lib/screens/shell/shell_staff_routes.dart', true),
  ('partner_zone_pnl', 'partner.zone_pnl', 'feature', 'home_shell', 'CHANGE #694 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart. Was declared onto partnerDestination(), which has had no caller since #653, so the partner tile drew and its tap fell through.', true),
  ('payment_alerts', 'admin.payment_alerts', 'feature', 'home_shell', 'Payment alerts — opened by shellExtraRouteScreen in shell/shell_extra_routes.dart (CMD #1929).', true),
  ('payment_upi', 'admin.payment_upi', 'feature', 'home_shell', '', true),
  ('pharmacy_audit', 'shop.pharmacy_audit', 'feature', 'home_shell', '', true),
  ('pharmacy_expiry', 'admin.pharmacy_expiry', 'feature', 'admin_dashboard_screen', '', true),
  ('pharmacy_gst', 'shop.pharmacy_gst', 'feature', 'home_shell', '', true),
  ('pharmacy_owner', 'shop.pharmacy_owner', 'feature', 'home_shell', '', true),
  ('pharmacy_parcel', 'admin.parcel_count', 'feature', 'admin_dashboard_screen', '', true),
  ('pharmacy_radar', 'shop.pharmacy_radar', 'feature', 'home_shell', '', true),
  ('pharmacy_reorder', 'shop.pharmacy_reorder', 'feature', 'home_shell', '', true),
  ('pharmacy_stock', 'shop.pharmacy_stock', 'feature', 'home_shell', '', true),
  ('pharmacy_variance', 'admin.pharmacy_variance', 'feature', 'admin_dashboard_screen', '', true),
  ('pharmacy_vault', 'admin.pharmacy_vault', 'feature', 'home_shell', '', true),
  ('play_store', 'devtool.play_store', 'feature', 'dev_queue_screen', '', true),
  ('pnl', 'admin.pnl', 'feature', 'home_shell', '', true),
  ('pos', 'shop.pos', 'feature', 'home_shell', '', true),
  ('pos_upi', 'shop.pos_upi', 'feature', 'home_shell', '', true),
  ('price_check', 'shop.price_check', 'feature', 'home_shell', '', true),
  ('pricing', 'admin.pricing_coverage', 'feature', 'home_shell', '', true),
  ('pricing_backfill', 'admin.pricing_backfill', 'feature', 'home_shell', '', true),
  ('profile', 'identity.view_profile', 'feature', 'home_shell', '', true),
  ('purchases', 'shop.purchases', 'feature', 'home_shell', '', true),
  ('px_exchange', 'admin.px_exchange', 'feature', 'admin_dashboard_screen', '', true),
  ('recon', 'admin.recon', 'feature', 'home_shell', 'CHANGE #471 — Money > Reconciliation. Arm in shell/shell_extra_routes.dart; home_shell is at its 2,000-line guard.', true),
  ('refill', 'admin.refill', 'feature', 'admin_dashboard_screen', '', true),
  ('reorder', 'admin.reorder', 'feature', 'home_shell', '', true),
  ('returns_refunds', 'admin.returns_refunds', 'feature', 'home_shell', '', true),
  ('reviews', 'admin.reviews', 'feature', 'home_shell', '', true),
  ('runbooks', 'devtool.runbooks', 'feature', 'dev_queue_screen', 'openDevTool() — CHANGE #474', true),
  ('rx_scan', 'admin.rx_scan', 'feature', 'admin_dashboard_screen', '', true),
  ('scope_audit', 'admin.scope_audit', 'feature', 'home_shell', '', true),
  ('search', '', 'chrome', 'home_shell', 'catalogue search tab', true),
  ('search_synonyms', 'admin.search_synonyms', 'feature', 'home_shell', 'CHANGE #790 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.', true),
  ('settlement', 'admin.settlement', 'feature', 'home_shell', '', true),
  ('settlement', 'partner.settlement', 'feature', 'partner_home_screen', '', false),
  ('settlement_invoices', 'partner.settlement_invoices', 'feature', 'home_shell', 'CHANGE #695 — the GST tax invoice on every settled period, plus credit notes and the monthly GSTR-1 register. Opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart, which home_shell reaches through its one `case _ when shellExtraRouteScreen(route) != null` lookup. Authorisation is not the door: settlement_invoices() clamps a partner to their own id and refuses anyone who is neither office nor partner.', true),
  ('signin_diag', 'devtool.signin_diag', 'feature', 'dev_queue_screen', '', true),
  ('stock_on_hand', 'admin.stock_on_hand', 'feature', 'admin_dashboard_screen', '', true),
  ('sup_leads', 'admin.sup_tab.leads', 'feature', 'admin_supplier_screen', '', true),
  ('sup_pending', 'admin.sup_tab.pending', 'feature', 'admin_supplier_screen', '', true),
  ('sup_staging', 'admin.sup_tab.staging', 'feature', 'admin_supplier_screen', '', true),
  ('sup_suppliers', 'admin.sup_tab.suppliers', 'feature', 'admin_supplier_screen', '', true),
  ('supplier_accounts', 'admin.supplier_accounts', 'feature', 'home_shell', '', true),
  ('supplier_inquiry', 'fulfill.supplier_inquiry', 'feature', 'admin_fulfillment_screen', '', true),
  ('supplier_order', 'fulfill.supplier_order', 'feature', 'admin_fulfillment_screen', '', true),
  ('supplier_orders', 'partner.supplier_orders', 'feature', 'partner_home_screen', '', true),
  ('supplier_payment', 'partner.supplier_payment', 'feature', 'home_shell', 'CHANGE #1016 — opened by shellStaffRouteScreen() in lib/screens/shell/shell_staff_routes.dart', true),
  ('supplier_returns', 'partner.supplier_returns', 'feature', 'home_shell', 'CHANGE #710 — send wrong, damaged, short or near-expiry stock back to a supplier and raise the debit note that reduces their bill. Opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart, which home_shell reaches through its one `case _ when shellExtraRouteScreen(route) != null` lookup. Authorisation is not the door: partner_return_console() zone-clamps a partner and refuses anyone who is neither office nor partner with its own sentence.', true),
  ('supplier_shop', 'fulfill.supplier_shop', 'feature', 'admin_fulfillment_screen', '', true),
  ('suppliers', 'admin.suppliers', 'feature', 'home_shell', '', true),
  ('support_inbox', 'admin.support_inbox', 'feature', 'admin_dashboard_screen', '', true),
  ('surface_map', 'admin.surface_map', 'feature', 'home_shell', 'CHANGE #570 — this audit', true),
  ('test_coverage', 'devtool.test_coverage', 'feature', 'dev_queue_screen', 'Dev Queue -> Tools -> Test coverage (openDevTool case test_coverage)', true),
  ('test_mode', 'admin.test_mode', 'feature', 'home_shell', '', true),
  ('test_mode', 'devtool.test_mode', 'feature', 'dev_queue_screen', '', true),
  ('threads', 'devtool.threads', 'feature', 'dev_queue_screen', '', true),
  ('token_dashboard', 'devtool.token_dashboard', 'feature', 'dev_queue_screen', 'CMD #1820 tile. kDevToolKeys carries the key; openDevTool() pushes TokenDashboardScreen.', true),
  ('triage', 'devtool.triage', 'feature', 'home_shell', 'CHANGE #639 — the triage inbox: approve what the bots found and the fix generates itself. The arm lives in shell/shell_extra_routes.dart because home_shell.dart is at its 2,000-line ceiling. Re-declared by CMD #1818: #639''s own INSERT was appended to a migration file the replay ledger already held, so it never reached production and c570_surface_map read the tile as a door onto nothing.', true),
  ('unmapped_companies', 'admin.unmapped_companies', 'feature', 'home_shell', '', true),
  ('users_access', 'admin.users_access', 'feature', 'home_shell', '', true),
  ('visual_baselines', 'devtool.visual_baselines', 'feature', 'dev_queue_screen', 'CMD #1810 — openDevTool() -> VisualBaselinesScreen; /admin/go/visual_baselines resolves through kDevToolKeys.', true),
  ('wa_assistant', 'admin.wa_assistant', 'feature', 'home_shell', 'CHANGE #714 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.', true),
  ('wa_campaigns', 'admin.wa_campaigns', 'feature', 'home_shell', '', true),
  ('wa_diagnosis', 'admin.wa_diagnosis', 'feature', 'home_shell', '', true),
  ('wa_drips', 'admin.wa_drips', 'feature', 'home_shell', '', true),
  ('wa_ops', 'admin.wa_ops', 'feature', 'home_shell', '', true),
  ('wa_segments', 'admin.wa_segments', 'feature', 'home_shell', '', true),
  ('wa_templates', 'admin.wa_templates', 'feature', 'home_shell', '', true),
  ('warehouse', 'fulfill.warehouse', 'feature', 'admin_fulfillment_screen', '', true),
  ('whatsapp', 'admin.whatsapp', 'feature', 'home_shell', '', true),
  ('zone_pnl', 'admin.zone_pnl', 'feature', 'home_shell', 'CHANGE #694 — opened by shellExtraRouteScreen() in lib/screens/shell/shell_extra_routes.dart.', true)
on conflict (route_key, feature_key) do nothing;



-- ── 7. ui_icon, the FK every nav row points at ────────────────────────────
-- 5 of live's 64 on a fresh branch, so seeding the nav tabs below fails on
-- staff_nav_tab_icon_key_fkey before it can fix anything.
insert into public.ui_icon (icon_key, label) values ('account_balance', 'Bank'), ('add_business', 'Add business'), ('admin_panel', 'Admin panel'), ('alert', 'Alert bell'), ('apps', 'More (grid)'), ('autorenew', 'Auto renew'), ('badge', 'Badge'), ('bag', 'Shopping bag'), ('book', 'Book'), ('bug', 'Bug'), ('build', 'Spanner'), ('business', 'Business'), ('campaign', 'Campaign'), ('cloud', 'Cloud'), ('dashboard', 'Dashboard grid'), ('description', 'Document'), ('drafts', 'Drafts'), ('fact_check', 'Fact check'), ('favorite', 'Heart / wishlist'), ('filter', 'Filter'), ('forum', 'Forum'), ('handshake', 'Handshake'), ('history', 'History'), ('image', 'Picture'), ('inventory', 'Inventory box'), ('key', 'Key'), ('link_off', 'Broken link'), ('logout', 'Logout'), ('map', 'Map'), ('medication', 'Medication'), ('memory', 'Memory chip'), ('moped', 'Moped'), ('notifications', 'Bell'), ('package', 'Parcel'), ('payments', 'Payments'), ('people', 'People'), ('percent', 'Percent'), ('person', 'Person'), ('person_add', 'Add person'), ('person_remove', 'Remove person'), ('phonelink_ring', 'Phone ring'), ('photo', 'Photo'), ('qr', 'QR code'), ('receipt', 'Receipt'), ('route', 'Route'), ('rule', 'Rule'), ('rule_folder', 'Rule folder'), ('rupee', 'Rupee'), ('schedule', 'Clock'), ('science', 'Lab flask'), ('search', 'Search'), ('settings', 'Settings'), ('settings_suggest', 'Settings suggest'), ('shop', 'Play store bag'), ('stars', 'Stars'), ('store', 'Shop front'), ('support_agent', 'Support agent'), ('task', 'Task tick'), ('terminal', 'Terminal'), ('timeline', 'Timeline'), ('tools', 'Toolbox'), ('trending_up', 'Trending up'), ('truck', 'Lorry'), ('wallet', 'Wallet') on conflict (icon_key) do nothing;

-- ── 8. staff_nav_tab, the doors the orphan check actually looks for ───────
-- nav_dashboard_orphan_check() clears a feature whose route_key is an ACTIVE
-- staff nav tab. The branch had zero of live's six, so admin.customers — whose
-- door IS the Customers tab — read as door-less and aborted the deploy.
insert into public.staff_nav_tab (tab_key, label_key, icon_key, route_key, anchor_feature, sort_order, is_active) values ('dashboard', 'staff_nav.tab_dashboard', 'dashboard', 'dashboard', 'admin.dashboard', 10, true),
  ('customers', 'staff_nav.tab_customers', 'people', 'customers', 'admin.customers', 20, true),
  ('suppliers', 'staff_nav.tab_suppliers', 'inventory', 'suppliers', 'admin.suppliers', 30, true),
  ('fulfill', 'staff_nav.tab_fulfill', 'truck', 'fulfillment', 'admin.fulfillment', 40, true),
  ('money', 'staff_nav.tab_money', 'rupee', 'money_home', null, 50, true),
  ('more', 'staff_nav.tab_more', 'apps', 'more', null, 60, true)
on conflict (tab_key) do nothing;

