-- CHANGE #536 — the pharmacy suite belongs to the PHARMACY account.
--
-- Every one of these features was registered onto surface='dashboard' with
-- roles_allowed = {admin,super_admin}. That put them on the ADMIN dashboard,
-- where the screen behind each tile resolves the caller's OWN pharmacy and so
-- answers an admin with "... is available on a pharmacy account" — a tile that
-- can only ever dead-end. Meanwhile the customer who owns the shop reached the
-- counter through a single row in the account dropdown and everything else by
-- chaining app-bar buttons off it.
--
-- This is a registry DATA fix (#325's rule: a feature on the wrong surface is
-- data, not new UI). The features move to a new surface, 'customer_shop', which
-- customer_shop_home() renders as the My Shop tab. The three genuinely ADMIN
-- views that were switched off in the first pass — the admin GST screen, the
-- admin reorder desk and the demand engine — go back on the dashboard where
-- they belong.
--
-- Idempotent throughout: re-applying it is a no-op.

-- ── 1. The new surface ──────────────────────────────────────────────────────
-- The old CHECK allowed only dashboard/profile/both/dev_tools. The profile
-- clause is carried over verbatim: 'profile' stays reserved for View Profile
-- and Logout, which is what keeps My Profile profile-only.
alter table feature_registry drop constraint if exists feature_registry_surface_ck;
alter table feature_registry add constraint feature_registry_surface_ck check (
  -- 'fulfill_tab' is CHANGE #537's surface, landed by another runner while this
  -- migration was being written. A CHECK cannot be extended, only replaced, so
  -- its value is carried here verbatim: dropping it would un-register nine
  -- fulfilment tabs.
  surface = any (array['dashboard','profile','both','dev_tools','fulfill_tab','customer_shop'])
  and (surface <> 'profile'
       or (category = 'identity'
           and feature_key = any (array['identity.view_profile','identity.logout'])))
);

-- ── 2. The four My Shop sections ────────────────────────────────────────────
-- nav_category already IS the section table (feature_registry.category is an FK
-- to it), so a fifth section tomorrow is one INSERT and never a deploy. These
-- keys carry no dashboard tiles, so nav_registry() never renders them.
insert into nav_category (category_key, label, icon_key, sort_order, is_active) values
  ('cshop_billing', 'Billing', 'receipt',     1010, true),
  ('cshop_stock',   'Stock',   'inventory',   1020, true),
  ('cshop_money',   'Money',   'rupee',       1030, true),
  ('cshop_grow',    'Grow',    'trending_up', 1040, true)
on conflict (category_key) do update set
  label      = excluded.label,
  icon_key   = excluded.icon_key,
  sort_order = excluded.sort_order,
  is_active  = excluded.is_active;

-- ── 3. Every pharmacy feature, on the customer surface ──────────────────────
-- route_key is the key HomeShell._handleAdminNav already switches on, so each
-- tile opens the screen that is already built rather than a new address.
-- roles_allowed carries super_admin as well as customer purely so the surface
-- can be reviewed; every screen behind it still resolves the caller's OWN
-- pharmacy and prints the backend's refusal, so this grants a door, never a
-- permission.
insert into feature_registry (
  feature_key, label, description, group_label, icon_key, route_key, sort_order,
  owner, partner_eligible, default_access, is_active, category, surface, roles_allowed
) values
  -- Billing
  ('shop.pos',              'Counter POS',          'Ring up a walk-in sale',              'Billing', 'shop',            'pos',               10, 'medibo', false, 'read', true, 'cshop_billing', 'customer_shop', array['customer','super_admin']),
  ('shop.pos_upi',          'UPI QR',               'Your counter QR and UPI ID',          'Billing', 'qr',              'pos_upi',           20, 'medibo', false, 'read', true, 'cshop_billing', 'customer_shop', array['customer','super_admin']),
  ('admin.rx_scan',         'Prescription scan',    'Read a prescription at the counter',  'Billing', 'description',     'rx_scan',           30, 'medibo', false, 'read', true, 'cshop_billing', 'customer_shop', array['customer','super_admin']),
  ('admin.paper_sale',      'Paper sales',          'Photograph a handwritten sale sheet', 'Billing', 'receipt',         'paper_sale',        40, 'medibo', false, 'read', true, 'cshop_billing', 'customer_shop', array['customer','super_admin']),
  ('admin.pharmacy_vault',  'Bill vault',           'Every purchase bill in one place',    'Billing', 'wallet',          'pharmacy_vault',    50, 'medibo', false, 'read', true, 'cshop_billing', 'customer_shop', array['customer','super_admin']),
  -- Stock
  ('shop.pharmacy_stock',   'Shelf stock',          'What is on your shelves right now',   'Stock',   'inventory',       'pharmacy_stock',    10, 'medibo', false, 'read', true, 'cshop_stock',   'customer_shop', array['customer','super_admin']),
  ('admin.pharmacy_expiry', 'Expiry watch',         'Batches going short-dated',           'Stock',   'schedule',        'pharmacy_expiry',   20, 'medibo', false, 'read', true, 'cshop_stock',   'customer_shop', array['customer','super_admin']),
  ('shop.pharmacy_audit',   'Stock audit',          'Count a shelf and settle it',         'Stock',   'fact_check',      'pharmacy_audit',    30, 'medibo', false, 'read', true, 'cshop_stock',   'customer_shop', array['customer','super_admin']),
  ('admin.pharmacy_variance','Stock check',         'Where the count and the book differ', 'Stock',   'rule',            'pharmacy_variance', 40, 'medibo', false, 'read', true, 'cshop_stock',   'customer_shop', array['customer','super_admin']),
  ('admin.parcel_count',    'Count outside parcel', 'Check a parcel in as it arrives',     'Stock',   'package',         'pharmacy_parcel',   50, 'medibo', false, 'read', true, 'cshop_stock',   'customer_shop', array['customer','super_admin']),
  ('shop.pharmacy_reorder', 'Reorder',              'What to buy back, and how much',      'Stock',   'autorenew',       'pharmacy_reorder',  60, 'medibo', false, 'read', true, 'cshop_stock',   'customer_shop', array['customer','super_admin']),
  -- Money
  ('admin.khata',           'Khata book',           'Who owes the counter, and since when','Money',   'book',            'khata',             10, 'medibo', false, 'read', true, 'cshop_money',   'customer_shop', array['customer','super_admin']),
  ('shop.pharmacy_gst',     'GST pack',             'Your month, ready for the return',    'Money',   'account_balance', 'pharmacy_gst',      20, 'medibo', false, 'read', true, 'cshop_money',   'customer_shop', array['customer','super_admin']),
  ('shop.price_check',      'Price check',          'Where you paid over the going rate',  'Money',   'rupee',           'price_check',       30, 'medibo', false, 'read', true, 'cshop_money',   'customer_shop', array['customer','super_admin']),
  -- Grow
  ('admin.refill',          'Refills & counter',    'Bring the same patient back',         'Grow',    'phonelink_ring',  'refill',            10, 'medibo', false, 'read', true, 'cshop_grow',    'customer_shop', array['customer','super_admin']),
  ('admin.px_exchange',     'Exchange & borrow',    'Borrow a strip from a nearby shop',   'Grow',    'handshake',       'px_exchange',       20, 'medibo', false, 'read', true, 'cshop_grow',    'customer_shop', array['customer','super_admin']),
  ('shop.pharmacy_owner',   'Shop dashboard',       'Your day, and how you compare',       'Grow',    'dashboard',       'pharmacy_owner',    30, 'medibo', false, 'read', true, 'cshop_grow',    'customer_shop', array['customer','super_admin']),
  ('shop.pharmacy_radar',   'Demand radar',         'What your area is asking for',        'Grow',    'trending_up',     'pharmacy_radar',    40, 'medibo', false, 'read', true, 'cshop_grow',    'customer_shop', array['customer','super_admin']),
  ('pharmacy.near_listing', 'Nearby listing',       'How buyers nearby find your shop',    'Grow',    'store',           'near_listing',      50, 'medibo', false, 'read', true, 'cshop_grow',    'customer_shop', array['customer','super_admin'])
on conflict (feature_key) do update set
  label            = excluded.label,
  description      = excluded.description,
  group_label      = excluded.group_label,
  icon_key         = excluded.icon_key,
  route_key        = excluded.route_key,
  sort_order       = excluded.sort_order,
  partner_eligible = excluded.partner_eligible,
  is_active        = excluded.is_active,
  category         = excluded.category,
  surface          = excluded.surface,
  roles_allowed    = excluded.roles_allowed;

-- ── 4. The admin views go back on the admin dashboard ───────────────────────
-- The first pass switched these three off along with the pharmacy tiles. They
-- are not pharmacy screens: 'gst' opens AdminGstScreen, 'reorder' opens
-- ReorderAdminScreen and admin_demand_engine() checks is_admin() for itself.
update feature_registry set is_active = true, surface = 'dashboard',
       roles_allowed = array['admin','super_admin'],
       group_label = case feature_key
                       when 'admin.gst'           then 'Money'
                       when 'admin.reorder'       then 'Orders & Fulfilment'
                       else 'Customers & Suppliers' end
 where feature_key in ('admin.gst', 'admin.reorder', 'admin.demand_engine');

-- ── 5. The copy the My Shop tab renders ─────────────────────────────────────
insert into ui_copy (key, value) values
  ('cshop.title',            '"My Shop"'::jsonb),
  ('cshop.subtitle',         '"Everything you run your counter with."'::jsonb),
  ('cshop.empty',            '"Your shop tools will appear here once your pharmacy is approved."'::jsonb),
  ('cshop.err_signed_out',   '"Sign in to open your shop."'::jsonb),
  ('cshop.err_not_pharmacy', '"My Shop is for a pharmacy account."'::jsonb),
  ('cshop.retry',            '"Try again"'::jsonb),
  ('home_shell.my_shop',     '"My Shop"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 6. The one RPC the tab renders verbatim ─────────────────────────────────
-- Labels, captions, section names, section order and tile order are all rows.
-- Dart chooses none of them and computes nothing.
create or replace function public.customer_shop_home()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role     text  := coalesce(public.get_my_role(), 'none');
  v_uid      uuid  := auth.uid();
  v_sections jsonb;
  v_txt      jsonb;
begin
  select coalesce(jsonb_object_agg(replace(k.key, 'cshop.', ''), k.value #>> '{}'), '{}'::jsonb)
    into v_txt from ui_copy k where k.key like 'cshop.%';

  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', coalesce(v_txt ->> 'err_signed_out', ''));
  end if;

  if not (v_role = any (array['customer', 'super_admin'])) then
    return jsonb_build_object('ok', false, 'error', 'not_pharmacy',
      'message', coalesce(v_txt ->> 'err_not_pharmacy', ''));
  end if;

  select coalesce(jsonb_agg(s.sec order by s.sec_sort), '[]'::jsonb)
    into v_sections
    from (
      select nc.sort_order as sec_sort,
             jsonb_build_object(
               'key',      nc.category_key,
               'label',    nc.label,
               'icon_key', nc.icon_key,
               'items',    jsonb_agg(
                 jsonb_build_object(
                   'feature_key',  f.feature_key,
                   'label',        f.label,
                   'caption',      coalesce(f.description, ''),
                   'icon_key',     f.icon_key,
                   'icon_letter',  upper(left(f.label, 1)),
                   'nav_key',      f.route_key
                 ) order by f.sort_order)
             ) as sec
        from nav_category nc
        join feature_registry f on f.category = nc.category_key
       where nc.is_active
         and f.is_active
         and f.surface = 'customer_shop'
         and f.route_key <> ''
         and v_role = any (f.roles_allowed)
       group by nc.category_key, nc.label, nc.icon_key, nc.sort_order
    ) s;

  return jsonb_build_object(
    'ok',            true,
    'role',          v_role,
    'title',         coalesce(v_txt ->> 'title', ''),
    'subtitle',      coalesce(v_txt ->> 'subtitle', ''),
    'empty_message', coalesce(v_txt ->> 'empty', ''),
    'retry_label',   coalesce(v_txt ->> 'retry', ''),
    'sections',      v_sections);
end
$function$;

-- `create or replace function` leaves Postgres' default EXECUTE grant to PUBLIC
-- in place, which would hand anon a callable entry point. The function already
-- refuses a caller with no auth.uid(), but a signed-out role must not hold
-- EXECUTE on an authed surface at all. Idempotent: revoking a grant that is
-- already gone is a no-op.
revoke all on function public.customer_shop_home() from public;
revoke all on function public.customer_shop_home() from anon;
grant execute on function public.customer_shop_home() to authenticated;

-- The first pass shipped a customer_shop_features() that hardcoded a list of
-- feature keys in SQL and answered anon. The surface column replaces it.
drop function if exists public.customer_shop_features();
