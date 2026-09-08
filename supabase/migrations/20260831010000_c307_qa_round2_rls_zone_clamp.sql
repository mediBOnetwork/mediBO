-- CHANGE #307 — QA round 2 fix: the RLS zone clamp.
--
-- FINDING (high, found by c307_partner_guard_proof check
-- "write grant + wrong zone: refused" returning ALLOWED):
-- zone scoping was enforced in the RPC layer (_assert_can_see_order refuses
-- cross-zone correctly) but NOT in RLS. Partner staff deliberately keep
-- get_my_role() = 'admin' so they can reuse the fulfilment screens, which means
-- they also satisfy is_admin() — and every fulfilment write policy was a bare
-- is_admin(). A partner holding a legitimate 'write' grant could therefore
-- UPDATE another zone's order rows by calling PostgREST directly, bypassing
-- the RPCs entirely. Spec rule 4 requires the clamp in RLS *and* in the RPCs.
--
-- The two helpers below are a strict NO-OP for anyone who is not a partner
-- (admin, super_admin, supplier, customer, service_role all short-circuit to
-- true), so bolting them onto the existing policies cannot change any
-- non-partner behaviour. For a partner they require the row to carry a zone
-- and for that zone to be the partner's own. Deny-by-default: a row with a
-- NULL zone is invisible/unwritable to a partner.
--
-- Idempotent: create-or-replace helpers, drop-if-exists then recreate policies.

-- ---------------------------------------------------------------------------
-- 1. The two clamp helpers
-- ---------------------------------------------------------------------------
create or replace function public.partner_zone_ok(p_zone int)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select case
    when not public.is_partner() then true
    else p_zone is not null and p_zone = public.partner_zone_id()::int
  end
$$;
comment on function public.partner_zone_ok(int) is
  'CHANGE #307 RLS zone clamp. TRUE for every non-partner caller (strict no-op); '
  'for a partner, TRUE only when the row zone equals region_partners.zone_id. '
  'A NULL row zone is refused for partners (deny by default).';

create or replace function public.partner_order_zone_ok(p_order_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select case
    when not public.is_partner() then true
    else exists (select 1 from public.orders o
                  where o.id = p_order_id
                    and o.zone_id is not null
                    and o.zone_id = public.partner_zone_id())
  end
$$;
comment on function public.partner_order_zone_ok(uuid) is
  'CHANGE #307 RLS zone clamp for order-child rows. TRUE for every non-partner '
  'caller; for a partner, TRUE only when the parent order sits in the partner zone.';

grant execute on function public.partner_zone_ok(int)        to authenticated, service_role;
grant execute on function public.partner_order_zone_ok(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Order-child write surface — clamped by the PARENT ORDER's zone
-- ---------------------------------------------------------------------------
drop policy if exists order_items_admin_update on public.order_items;
create policy order_items_admin_update on public.order_items
  for update to authenticated
  using       (is_admin() and public.partner_order_zone_ok(order_id))
  with check  (is_admin() and public.partner_order_zone_ok(order_id));

drop policy if exists order_items_insert_own on public.order_items;
create policy order_items_insert_own on public.order_items
  for insert to authenticated
  with check ((order_id in (select orders.id from public.orders where orders.user_id = auth.uid()))
              or (is_admin() and public.partner_order_zone_ok(order_id)));

drop policy if exists receiving_log_admin_all on public.receiving_log;
create policy receiving_log_admin_all on public.receiving_log
  for all to authenticated
  using      (is_admin() and public.partner_order_zone_ok(order_id))
  with check (is_admin() and public.partner_order_zone_ok(order_id));

drop policy if exists admin_all_supplier_orders on public.supplier_orders;
create policy admin_all_supplier_orders on public.supplier_orders
  for all to authenticated
  using      (is_admin() and public.partner_order_zone_ok(order_id))
  with check (is_admin() and public.partner_order_zone_ok(order_id));

-- ---------------------------------------------------------------------------
-- 3. Zone-carrying write surface — clamped by the ROW's own zone
-- ---------------------------------------------------------------------------
drop policy if exists "Admins can update orders" on public.orders;
create policy "Admins can update orders" on public.orders
  for update
  using      (is_admin() and public.partner_zone_ok(zone_id))
  with check (is_admin() and public.partner_zone_ok(zone_id));

drop policy if exists inquiry_admin_all on public.inquiry;
create policy inquiry_admin_all on public.inquiry
  for all to authenticated
  using      (is_admin() and public.partner_zone_ok(zone_id))
  with check (is_admin() and public.partner_zone_ok(zone_id));

drop policy if exists admin_all_supplier_profiles on public.supplier_profiles;
create policy admin_all_supplier_profiles on public.supplier_profiles
  for all to authenticated
  using      (is_admin() and public.partner_zone_ok(zone_id))
  with check (is_admin() and public.partner_zone_ok(zone_id));

drop policy if exists "Admins can update any pharmacy_profile" on public.pharmacy_profiles;
create policy "Admins can update any pharmacy_profile" on public.pharmacy_profiles
  for update
  using      (is_admin() and public.partner_zone_ok(zone_id))
  with check (is_admin() and public.partner_zone_ok(zone_id));

drop policy if exists "Admins can insert pharmacy_profiles" on public.pharmacy_profiles;
create policy "Admins can insert pharmacy_profiles" on public.pharmacy_profiles
  for insert
  with check ((is_admin() and public.partner_zone_ok(zone_id)) or (auth.uid() = user_id));

drop policy if exists "Admin full dp_reg" on public.delivery_partner_registrations;
create policy "Admin full dp_reg" on public.delivery_partner_registrations
  for all to authenticated
  using      (is_admin() and public.partner_zone_ok(zone_id))
  with check (is_admin() and public.partner_zone_ok(zone_id));

drop policy if exists admin_all on public.delivery_partner_registrations;
create policy admin_all on public.delivery_partner_registrations
  for all to authenticated
  using      (is_admin() and public.partner_zone_ok(zone_id))
  with check (is_admin() and public.partner_zone_ok(zone_id));
