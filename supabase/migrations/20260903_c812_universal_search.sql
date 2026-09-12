-- CHANGE #812 — universal_search(p_q).
--
-- nav_search() is the ADMIN command palette: it leads with screens and Dev
-- Queue tools, and it refuses anyone who is not admin/super_admin. The
-- dashboard needs the other half of that idea — one box that finds the THING
-- you are holding: an order code, a phone number, a pharmacy, a supplier, a
-- product — and works for a region partner too, inside its own zone.
--
-- Typed results, each carrying its own deep link. Nothing is worded in Dart.

insert into public.ui_copy (key, value) values
  ('usearch.hint',          to_jsonb('Type at least two characters.'::text)),
  ('usearch.empty',         to_jsonb('Nothing matched.'::text)),
  ('usearch.placeholder',   to_jsonb('Search an order, phone, pharmacy, supplier or product'::text)),
  ('usearch.not_authorized',to_jsonb('You do not have access to search.'::text)),
  ('usearch.g_orders',      to_jsonb('Orders'::text)),
  ('usearch.g_customers',   to_jsonb('Pharmacies'::text)),
  ('usearch.g_suppliers',   to_jsonb('Suppliers'::text)),
  ('usearch.g_products',    to_jsonb('Products'::text)),
  ('usearch.pending_badge', to_jsonb('pending approval'::text))
on conflict (key) do nothing;

create or replace function public.universal_search(p_q text, p_limit integer default 6)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_partner bigint  := public.my_partner_id();
  v_admin   boolean := (coalesce(public.role_for_medibo_only(), 'none') in ('admin','super_admin'));
  v_zone    smallint;
  v_q       text    := btrim(coalesce(p_q, ''));
  v_like    text;
  v_digits  text;
  v_lim     int     := least(greatest(coalesce(p_limit, 6), 1), 20);
  v_groups  jsonb   := '[]'::jsonb;
  v_part    jsonb;
  v_can_360  boolean := false;
  v_can_cust boolean := false;
  v_can_supp boolean := false;
  v_can_ord  boolean := false;
begin
  if v_partner is null and not v_admin then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'query', v_q, 'groups', '[]'::jsonb,
      'message', public._c('usearch.not_authorized'),
      'placeholder', public._c('usearch.placeholder'),
      'empty_label', public._c('usearch.empty'));
  end if;

  if length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'query', v_q, 'groups', '[]'::jsonb,
      'hint', public._c('usearch.hint'),
      'placeholder', public._c('usearch.placeholder'),
      'empty_label', public._c('usearch.hint'));
  end if;

  -- A partner searches ITS zone and only its zone; zones are separate shops.
  v_zone   := case when v_partner is not null then public.partner_zone_id() end;
  v_like   := '%' || lower(v_q) || '%';
  v_digits := nullif(regexp_replace(v_q, '[^0-9]', '', 'g'), '');

  -- The doors, resolved once. A row is a DOOR onto a feature, so it only
  -- carries a deep link the caller is actually allowed through.
  if v_partner is not null then
    v_can_ord  := coalesce(public.partner_access('partner.customer_orders', v_partner), 'none') <> 'none';
    v_can_supp := coalesce(public.partner_access('partner.supplier_orders', v_partner), 'none') <> 'none';
  else
    v_can_360  := coalesce(public.admin_access('admin.customer_360'), 'none') <> 'none';
    v_can_cust := coalesce(public.admin_access('admin.customers'), 'none') <> 'none';
    v_can_supp := coalesce(public.admin_access('admin.suppliers'), 'none') <> 'none';
    v_can_ord  := coalesce(public.admin_access('fulfill.customer_order'), 'none') <> 'none';
  end if;

  -- ORDERS — by order code, by pharmacy name, and by the phone on the order.
  select jsonb_agg(x order by created_at desc) into v_part from (
    select o.created_at, jsonb_build_object(
             'kind',     'order',
             'title',    coalesce(nullif(o.order_code, ''), 'Order ' || left(o.id::text, 8)),
             'subtitle', concat_ws(' · ', nullif(coalesce(pp.pharmacy_name, o.pharmacy_name), ''),
                                          nullif(o.status, '')),
             'icon_key', 'receipt', 'icon_letter', 'O',
             'route_key', case when pp.id is not null and v_can_360 then 'customer_360'
                               when v_can_ord then 'customer_orders' end,
             'deep_link', case when pp.id is not null and v_can_360
                               then '/admin/go/customer_360/' || pp.id::text
                               when v_can_ord then '/admin/go/fulfillment' end,
             'seed', coalesce(pp.id::text, o.order_code, ''),
             'ref_id', o.id::text) as x
      from public.orders o
      left join public.pharmacy_profiles pp on pp.id = o.customer_id
     where not coalesce(o.is_synthetic, false)
       and (v_zone is null or coalesce(o.zone_id, pp.zone_id) = v_zone)
       and (lower(coalesce(o.order_code, '')) like v_like
            or lower(coalesce(o.pharmacy_name, '')) like v_like
            or (v_digits is not null and coalesce(o.phone, '') like '%' || v_digits || '%'))
     order by o.created_at desc
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(jsonb_build_object(
      'key', 'orders', 'label', public._c('usearch.g_orders'), 'items', v_part));
  end if;

  -- PHARMACIES — by name, code, owner and phone.
  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind',     'pharmacy',
             'title',    coalesce(nullif(btrim(p.pharmacy_name), ''), p.customer_name, 'Pharmacy'),
             'subtitle', concat_ws(' · ', nullif(p.city, ''), nullif(p.phone, ''),
                           case when coalesce(p.approved, false) then null
                                else public._c('usearch.pending_badge') end),
             'icon_key', 'people', 'icon_letter', 'C',
             'route_key', case when v_can_360 then 'customer_360'
                               when v_can_cust then 'customers' end,
             'deep_link', case when v_can_360 then '/admin/go/customer_360/' || p.id::text
                               when v_can_cust then '/admin/go/customers' end,
             'seed', p.id::text,
             'ref_id', p.id::text) as x
      from public.pharmacy_profiles p
     where coalesce(p.is_deleted, false) = false
       and not coalesce(p.is_synthetic, false)
       and (v_zone is null or p.zone_id = v_zone)
       and (lower(coalesce(p.pharmacy_name, '')) like v_like
            or lower(coalesce(p.customer_name, '')) like v_like
            or lower(coalesce(p.customer_code, '')) like v_like
            or (v_digits is not null and coalesce(p.phone, '') like '%' || v_digits || '%'))
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(jsonb_build_object(
      'key', 'customers', 'label', public._c('usearch.g_customers'), 'items', v_part));
  end if;

  -- SUPPLIERS — by name, code and phone.
  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind',     'supplier',
             'title',    s.supplier_name,
             'subtitle', concat_ws(' · ', nullif(s.city, ''), nullif(s.phone, '')),
             'icon_key', 'inventory', 'icon_letter', 'S',
             'route_key', case when v_can_supp and v_partner is not null then 'supplier_orders'
                               when v_can_supp then 'suppliers' end,
             'deep_link', case when v_can_supp and v_partner is null then '/admin/go/suppliers' end,
             'seed', s.supplier_name,
             'ref_id', s.id::text) as x
      from public.supplier_profiles s
     where coalesce(s.is_deleted, false) = false
       and (lower(coalesce(s.supplier_name, '')) like v_like
            or lower(coalesce(s.supplier_code, '')) like v_like
            or (v_digits is not null and coalesce(s.phone, '') like '%' || v_digits || '%'))
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(jsonb_build_object(
      'key', 'suppliers', 'label', public._c('usearch.g_suppliers'), 'items', v_part));
  end if;

  -- PRODUCTS — the catalogue, ranked the way the storefront ranks it.
  select jsonb_agg(x order by ord) into v_part from (
    select coalesce(m.sales_count, 0) * -1 as ord, jsonb_build_object(
             'kind',     'product',
             'title',    m.product_name,
             'subtitle', coalesce(m.marketer_canonical, ''),
             'icon_key', 'medication', 'icon_letter', 'M',
             'route_key', 'search',
             'deep_link', '/product/' || m.id::text,
             'seed', m.product_name,
             'ref_id', m.id::text) as x
      from public."MEDICINE" m
     where m.product_name ilike v_like
     order by m.sales_count desc nulls last
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(jsonb_build_object(
      'key', 'products', 'label', public._c('usearch.g_products'), 'items', v_part));
  end if;

  return jsonb_build_object(
    'ok', true, 'query', v_q,
    'is_partner', (v_partner is not null),
    'zone_id', v_zone,
    'groups', v_groups,
    'has_any', jsonb_array_length(v_groups) > 0,
    'placeholder', public._c('usearch.placeholder'),
    'empty_label', public._c('usearch.empty'));
end $fn$;

revoke all on function public.universal_search(text, integer) from public, anon;
grant execute on function public.universal_search(text, integer) to authenticated;
