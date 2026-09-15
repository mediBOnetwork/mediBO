-- CHANGE #349 — every nav payload now carries `icon_letter`, and the command
-- palette can find a Dev Queue tool by name.
--
-- icon_letter is the deterministic fallback the dashboard needed: when a glyph
-- cannot be drawn the tile shows the feature's own initial instead of an empty
-- pale square. It is composed in SQL, like every other display string.
--
-- The palette searched `surface = 'dashboard'` only, so the nine tools that
-- just became registry rows would have been invisible to it — "make the
-- command palette find these tools by name" is the same one-line predicate.

alter table public.feature_registry validate constraint feature_registry_icon_fk;
alter table public.nav_category      validate constraint nav_category_icon_fk;

create or replace function public.nav_registry()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_uid     uuid := auth.uid();
  v_partner bigint := public.my_partner_id();
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
      from feature_registry f
      left join nav_pin p on p.feature_key = f.feature_key and p.user_id = v_uid
      left join (select feature_key, count(*) as opens from nav_usage
                  where user_id = v_uid and opened_at > now() - interval '30 days'
                  group by 1) u on u.feature_key = f.feature_key
     where f.is_active and f.route_key <> '' and f.surface = 'dashboard'
       and v_role = any (f.roles_allowed)
       and case when v_partner is not null
                then f.partner_eligible
                     and coalesce(public.partner_access(f.feature_key, v_partner),'none') <> 'none'
                else f.feature_key like 'admin.%' end
  ), tile as (
    select v.category, v.feature_key, v.sort_order, v.pinned, v.opens,
           jsonb_build_object(
             'feature_key', v.feature_key, 'label', v.label,
             'icon_key', v.icon_key,
             -- CHANGE #349 — the fallback initial, backend-composed.
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

grant execute on function public.nav_registry() to authenticated;
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

  -- CHANGE #349 — Dev Queue tools. They are registry rows now, so the palette
  -- finds them by name exactly the way it finds a screen; `tool_key` is what
  -- the app opens, and a row that is not here cannot be opened at all.
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

  -- Orders (by code or the pharmacy that placed it)
  select jsonb_agg(x order by created_at desc) into v_part from (
    select o.created_at, jsonb_build_object(
             'kind','order', 'title', coalesce(o.order_code, 'Order #' || o.id),
             'subtitle', coalesce(o.pharmacy_name,'') || ' · ' || coalesce(o.status,''),
             'icon_key','receipt', 'icon_letter','O', 'route_key','customers',
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
             'icon_key','people', 'icon_letter','C', 'route_key','customers',
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

  -- Medicines — trigram index on product_name, never a scan of the 563k rows
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
end $$;

grant execute on function public.nav_search(text,int) to authenticated;
