-- dev-queue #308 — REMOVE THE OFFERS MARKETPLACE ENTIRELY.
--
-- The supplier-self-list Offers marketplace (#177/#178/#179/#223) never sold
-- anything and its machinery had grown into the core purchase flow. All six
-- listing tables were empty and cart_items/order_items.offer_listing_id had
-- zero non-null values, so nothing live depended on it.
--
-- Everything this migration removes is archived, verbatim and reversible, at
--   backup/offers-removal-308/offer_tables_schema_and_data.sql   (schema + data)
--   backup/offers-removal-308/offer_functions_dropped.sql        (32 defs)
--   backup/offers-removal-308/offer_rows_removed.sql             (copy rows)
--   backup/offers-removal-308/core_functions_before.sql          (pre-edit core)
--
-- Idempotent throughout: every statement is IF EXISTS / IF NOT EXISTS.

begin;
set local lock_timeout = '20s';

-- ── 1. triggers that hang off core tables ───────────────────────────────────
-- _vcm_short_dated_check sat on voice_clip_mentions, i.e. on the voice counting
-- path; trg_c305_offer_expiry_wake woke a cron task for a table with no rows.
drop trigger if exists vcm_short_dated_check on public.voice_clip_mentions;
drop trigger if exists trg_c305_offer_expiry_wake on public.supplier_offer_listings;
drop trigger if exists sdo_updated_at on public.short_dated_offers;

-- ── 2. the scheduled work (cron_task dispatcher rows, CHANGE #273) ──────────
delete from public.cron_signal
 where task in ('offer-reservation-sweep','offer-expiry-cron','offer-waitlist-notify');
delete from public.cron_task
 where name in ('offer-reservation-sweep','offer-expiry-cron','offer-waitlist-notify');

-- ── 3. every offers function (31 named + the short_dated_offers touch trigger)
drop function if exists public._offer_confirm_qty(p_listing_id bigint, p_qty numeric) cascade;
drop function if exists public._offer_copy(p_key text, p_vars jsonb) cascade;
drop function if exists public._offer_display_block(p_row supplier_offer_listings, p_customer uuid, p_matched boolean) cascade;
drop function if exists public._offer_expiry_cron() cascade;
drop function if exists public._offer_held_qty(p_listing_id bigint, p_exclude_customer uuid) cascade;
drop function if exists public._offer_hold_minutes() cascade;
drop function if exists public._offer_reservation_sweep() cascade;
drop function if exists public._offer_waitlist_notify_cron() cascade;
drop function if exists public._sdo_set_updated_at() cascade;
drop function if exists public._vcm_short_dated_check() cascade;
drop function if exists public.admin_offer_margin_set(p_margin_pct numeric) cascade;
drop function if exists public.admin_offer_moderate(p_listing_id bigint, p_action text, p_note text, p_margin_pct numeric) cascade;
drop function if exists public.admin_offers_list(p_status text, p_offset integer, p_limit integer) cascade;
drop function if exists public.offer_add_to_cart(p_listing_id bigint, p_qty numeric, p_disclosure_seen boolean) cascade;
drop function if exists public.offer_match_customers(p_listing_id bigint) cascade;
drop function if exists public.offer_push_matched(p_listing_id bigint) cascade;
drop function if exists public.offer_waitlist_join(p_listing_id bigint) cascade;
drop function if exists public.offers_feed(p_zone_id smallint, p_offset integer, p_limit integer) cascade;
drop function if exists public.short_dated_add_to_cart(p_offer_id uuid, p_qty numeric, p_disclosure_seen boolean) cascade;
drop function if exists public.short_dated_config_get() cascade;
drop function if exists public.short_dated_config_save(p_bands jsonb) cascade;
drop function if exists public.short_dated_feed(p_zone_id integer) cascade;
drop function if exists public.short_dated_offer_confirm(p_id uuid, p_discount_pct numeric, p_bulk_clear_extra_pct numeric, p_bulk_clear_min_qty numeric, p_admin_notes text) cascade;
drop function if exists public.short_dated_offer_disable(p_id uuid) cascade;
drop function if exists public.short_dated_offer_edit(p_id uuid, p_available_qty numeric, p_discount_pct numeric, p_bulk_clear_extra_pct numeric, p_bulk_clear_min_qty numeric, p_admin_notes text, p_zone_ids integer[]) cascade;
drop function if exists public.short_dated_offer_list(p_status text, p_limit integer, p_offset integer) cascade;
drop function if exists public.short_dated_push_wa(p_id uuid) cascade;
drop function if exists public.short_dated_sweep() cascade;
drop function if exists public.supplier_offer_create(p_product_id bigint, p_listing_type text, p_available_qty numeric, p_offer_ptr numeric, p_discount_pct numeric, p_net_price numeric, p_scheme_buy_qty numeric, p_scheme_free_qty numeric, p_batch_expiry_date date, p_min_order_qty numeric, p_end_date date) cascade;
drop function if exists public.supplier_offer_update(p_id bigint, p_available_qty numeric, p_offer_ptr numeric, p_discount_pct numeric, p_net_price numeric, p_min_order_qty numeric, p_end_date date, p_status text) cascade;
drop function if exists public.supplier_offers_mine(p_status text, p_offset integer, p_limit integer) cascade;
drop function if exists public.trg_cron_wake_offer_expiry() cascade;

-- ── 4. the offer columns on the core cart/order tables (both all-NULL) ──────
alter table public.cart_items  drop column if exists offer_listing_id;
alter table public.order_items drop column if exists offer_listing_id;

-- ── 5. the tables ───────────────────────────────────────────────────────────
drop table if exists public.offer_near_expiry_disclosures cascade;
drop table if exists public.offer_push_log                cascade;
drop table if exists public.offer_reservations            cascade;
drop table if exists public.offer_waitlist                cascade;
drop table if exists public.short_dated_offers            cascade;
drop table if exists public.supplier_offer_listings       cascade;
-- short_dated_config held only the three seeded discount bands of the removed
-- feature (no business data); its only readers were short_dated_config_get/save.
drop table if exists public.short_dated_config            cascade;

-- ── 6. the home-feed section the marketplace fed (already inactive) ─────────
delete from public.storefront_home_section where id = 'short_dated_deals';

-- ── 7. the copy. offer_chip_label is KEPT on purpose: it names the generic
--      "Scheme available" badge that _sf_cards still emits from MEDICINE
--      .has_scheme, which has nothing to do with the marketplace.
delete from public.ui_copy
 where (key ~* 'offer|short_dated') and key <> 'offer_chip_label';
delete from public.storefront_ui_label
 where (key ~* 'offer|short_dated') and key <> 'offer_chip_label';

commit;
