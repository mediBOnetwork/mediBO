-- CHANGE #325 — the command palette, plus the copy rows the nav renders from.

-- The 12 nav labels live in ui_copy like every other display string, so
-- changing the wording is an UPDATE and never a deploy.
insert into ui_copy (key, value) values
  ('nav.action_required', to_jsonb('Action Required'::text)),
  ('nav.pinned',          to_jsonb('Pinned'::text)),
  ('nav.all_features',    to_jsonb('All Features'::text)),
  ('nav.search_hint',     to_jsonb('Search screens, orders, customers, suppliers, medicines…'::text)),
  ('nav.search_title',    to_jsonb('Jump to…'::text)),
  ('nav.search_button',   to_jsonb('Search anything'::text)),
  ('nav.unused_report',   to_jsonb('Features nobody opened'::text)),
  ('nav.empty_actions',   to_jsonb('Nothing needs your attention right now.'::text)),
  ('nav.empty_search',    to_jsonb('Nothing matched. Try an order code, a customer name, or a screen.'::text)),
  ('nav.pin_added',       to_jsonb('Pinned to the top of your dashboard.'::text)),
  ('nav.pin_removed',     to_jsonb('Unpinned.'::text)),
  ('nav.pin_hint',        to_jsonb('Long-press a tile to pin it'::text))
on conflict (key) do update set value = excluded.value;

-- CHANGE #325 fix 8a — "WhatsApp Ops" was the label of BOTH wa_ops and
-- wa_segments, which is why Om counted it twice in the dropdown.
update ui_copy set value = to_jsonb('WhatsApp Segments'::text)
 where key = 'admin_nav.overflow_segments';
-- while here: this one had been left as the raw route key, not a label.
update ui_copy set value = to_jsonb('WhatsApp Templates'::text)
 where key = 'admin_nav.overflow_wa_templates';
-- CHANGE #325 fix 8b — the Order Hours card printed a raw Dart interpolation
-- because the COPY ROW held one. cf() substitutes {message}.
update ui_copy set value = to_jsonb('Closed message: {message}'::text)
 where key = 'order_hours.closed_message_summary';

-- ONE search that jumps to any screen, order, customer, supplier or medicine.
create or replace function public.nav_search(p_q text, p_limit int default 6)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
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

  -- Screens (the registry itself)
  select jsonb_agg(x order by rank, sort_order) into v_part from (
    select f.sort_order,
           case when lower(f.label) = lower(v_q) then 0
                when lower(f.label) like lower(v_q) || '%' then 1 else 2 end as rank,
           jsonb_build_object(
             'kind','screen', 'title', f.label, 'subtitle', c.label,
             'icon_key', f.icon_key, 'route_key', f.route_key,
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

  -- Orders (by code or the pharmacy that placed it)
  select jsonb_agg(x order by created_at desc) into v_part from (
    select o.created_at, jsonb_build_object(
             'kind','order', 'title', coalesce(o.order_code, 'Order #' || o.id),
             'subtitle', coalesce(o.pharmacy_name,'') || ' · ' || coalesce(o.status,''),
             'icon_key','receipt', 'route_key','customers',
             'deep_link', '/admin/go/customers', 'feature_key','admin.customers',
             'seed', coalesce(o.order_code, o.pharmacy_name)) as x
      from orders o
     where lower(coalesce(o.order_code,'')) like v_like
        or lower(coalesce(o.pharmacy_name,'')) like v_like
     order by o.created_at desc limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','orders','label','Orders','items', v_part));
  end if;

  -- Customers — a customer name jumps to their orders screen
  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','customer',
             'title', coalesce(nullif(btrim(p.pharmacy_name),''), p.customer_name, 'Customer'),
             'subtitle', coalesce(p.city,'') ||
                         case when coalesce(p.approved,false) then '' else ' · pending approval' end,
             'icon_key','people', 'route_key','customers',
             'deep_link', '/admin/go/customers', 'feature_key','admin.customers',
             'seed', coalesce(nullif(btrim(p.pharmacy_name),''), p.customer_name)) as x
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

  -- Suppliers
  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','supplier', 'title', s.supplier_name,
             'subtitle', coalesce(s.city,''),
             'icon_key','inventory', 'route_key','suppliers',
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

  -- Medicines — trigram index on product_name, never a scan of the 563k rows
  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','medicine', 'title', m.product_name,
             'subtitle', coalesce(m.marketer_canonical, ''),
             'icon_key','medication', 'route_key','search',
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
end $$;

grant execute on function public.nav_search(text,int) to authenticated;
