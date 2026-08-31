-- CHANGE #396 part 3 — both screens become reachable, from the registry that
-- already IS the nav truth (#325). A screen that is not in feature_registry
-- does not exist to the dashboard or the command palette.

insert into public.feature_registry
  (feature_key, label, category, route_key, deep_link, icon_key, roles_allowed,
   search_terms, sort_order, surface, is_active, description)
values
  ('admin.stock_on_hand', 'Stock on hand', 'orders', 'stock_on_hand',
   '/admin/go/stock_on_hand', 'inventory', array['admin','super_admin'],
   'stock inventory on hand unallocated warehouse ageing expiry batch residue',
   455, 'dashboard', true,
   'Goods in the warehouse that no live order has claimed'),
  ('admin.customer_360', 'Customer 360', 'parties', 'customer_360',
   '/admin/go/customer_360', 'people', array['admin','super_admin'],
   'customer 360 pharmacy profile outstanding ledger history whole view',
   415, 'dashboard', true,
   'One pharmacy whole — orders, money, disputes, margin, delivery, WhatsApp')
on conflict (feature_key) do update
  set label = excluded.label, category = excluded.category,
      route_key = excluded.route_key, deep_link = excluded.deep_link,
      icon_key = excluded.icon_key, roles_allowed = excluded.roles_allowed,
      search_terms = excluded.search_terms, sort_order = excluded.sort_order,
      surface = excluded.surface, is_active = true,
      description = excluded.description;

-- The palette's Customers group now points at the 360 view and carries the
-- customer id, so searching a pharmacy name opens that pharmacy whole rather
-- than the customer LIST it used to land on.
create or replace function public.nav_search(p_q text, p_limit integer default 6)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  v_role   text := coalesce(public.get_my_role(),'none');
  v_q      text := btrim(coalesce(p_q,''));
  v_like   text;
  v_groups jsonb := '[]'::jsonb;
  v_part   jsonb;
  v_lim    int  := least(greatest(coalesce(p_limit,6),1), 20);
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
end $fn$;

-- "Reachable from any order": one lookup the order screens call to jump.
create or replace function public.customer_360_for_order(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_role text := coalesce(public.get_my_role(),'none'); v_id uuid; v_name text;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'message', public._c360('admins_only'));
  end if;
  select p.id, coalesce(nullif(btrim(p.pharmacy_name),''), p.customer_name)
    into v_id, v_name
    from orders o
    left join pharmacy_profiles p
      on (o.customer_id is not null and p.id = o.customer_id)
      or (o.customer_id is null and p.user_id = o.user_id)
   where o.id = p_order_id
   limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'message', public._c360('not_found'));
  end if;
  return jsonb_build_object('ok', true, 'customer_id', v_id,
    'label', public._c360('title'), 'name', coalesce(v_name,''));
end $fn$;

grant execute on function public.customer_360_for_order(uuid) to authenticated;

insert into public.ui_copy (key, value) values
  ('c360.open_from_order', to_jsonb('Customer 360'::text))
on conflict (key) do nothing;
