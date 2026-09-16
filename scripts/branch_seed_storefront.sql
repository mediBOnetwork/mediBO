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
