-- CHANGE #325 — the nav RPCs. Every label, category, icon key, count phrase and
-- empty state below is produced HERE; Dart renders the payload verbatim.

-- Live counts in one place, so a badge_source is a data value not a branch.
create or replace function public.nav_badge_counts()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'pending_orders',     (select count(*) from orders where status = 'pending'),
    'flagged_bills',      (select count(*) from pending_bills where verdict in ('needs_approval','fake')),
    'pending_customers',  (select count(*) from pharmacy_profiles where coalesce(approved,false) = false),
    'deletion_requests',  (select count(*) from account_deletion_requests where status = 'pending'),
    'order_alerts',       (select count(*) from order_alert where actioned_at is null),
    'disputes',           (select count(*) from supplier_disputes where coalesce(status,'open') = 'open'),
    'contact_inquiries',  (select count(*) from contact_inquiries)
  );
$$;

-- The whole dashboard nav, role-composed, in ONE call.
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
                -- partner staff: only the zone-eligible slice they were granted
                then f.partner_eligible
                     and coalesce(public.partner_access(f.feature_key, v_partner),'none') <> 'none'
                -- everyone else: the admin namespace, whose routes are the ones
                -- _handleAdminNav actually opens
                else f.feature_key like 'admin.%' end
  ), tile as (
    select v.category, v.feature_key, v.sort_order, v.pinned, v.opens,
           jsonb_build_object(
             'feature_key', v.feature_key, 'label', v.label,
             'icon_key', v.icon_key, 'route_key', v.route_key,
             'deep_link', v.deep_link, 'badge_count', v.badge_count,
             'badge_label', case when coalesce(v.badge_count,0) > 0
                                 then v.badge_count::text || ' ' || coalesce(v.badge_noun, lower(v.label))
                                 else null end,
             'pinned', v.pinned, 'opens', v.opens) as js
      from visible v
  )
  select
    -- sections in category order; inside one, pinned first, then what this
    -- admin actually opens, then the registry's own order.
    coalesce((select jsonb_agg(sec order by sec_sort) from (
        select c.sort_order as sec_sort,
               jsonb_build_object('category_key', c.category_key, 'label', c.label,
                 'icon_key', c.icon_key,
                 'items', jsonb_agg(t.js order by t.pinned desc, t.opens desc, t.sort_order)) as sec
          from nav_category c join tile t on t.category = c.category_key
         where c.is_active
         group by c.category_key, c.label, c.icon_key, c.sort_order) s), '[]'::jsonb),
    -- action-first tiles: only features with a live count to answer.
    coalesce((select jsonb_agg(t.js order by (t.js->>'badge_count')::bigint desc, t.sort_order)
                from tile t where coalesce((t.js->>'badge_count')::bigint,0) > 0), '[]'::jsonb),
    coalesce((select jsonb_agg(t.js order by t.sort_order) from tile t where t.pinned), '[]'::jsonb)
  into v_tiles, v_actions, v_pinned;

  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key, 'label', f.label, 'icon_key', f.icon_key,
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

-- Usage log: one row per screen open, ranked back in nav_registry. Also the
-- hard gate at the door — a screen not in the registry cannot be opened
-- through it.
create or replace function public.nav_open(p_feature_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_row feature_registry;
begin
  if v_uid is null then return jsonb_build_object('ok', false); end if;
  select * into v_row from feature_registry where feature_key = p_feature_key and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_registered',
      'message', 'That screen is not in the feature registry.');
  end if;
  insert into nav_usage (user_id, feature_key) values (v_uid, p_feature_key);
  return jsonb_build_object('ok', true, 'route_key', v_row.route_key,
    'deep_link', v_row.deep_link);
end $$;

create or replace function public.nav_pin_toggle(p_feature_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_uid uuid := auth.uid(); v_was boolean;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'message', 'Sign in first.');
  end if;
  if not exists (select 1 from feature_registry where feature_key = p_feature_key and is_active) then
    return jsonb_build_object('ok', false, 'message', 'That feature is not in the registry.');
  end if;
  select true into v_was from nav_pin where user_id = v_uid and feature_key = p_feature_key;
  if v_was then
    delete from nav_pin where user_id = v_uid and feature_key = p_feature_key;
    return jsonb_build_object('ok', true, 'pinned', false, 'message', 'Unpinned.');
  end if;
  insert into nav_pin (user_id, feature_key) values (v_uid, p_feature_key)
    on conflict do nothing;
  return jsonb_build_object('ok', true, 'pinned', true,
    'message', 'Pinned to the top of your dashboard.');
end $$;

-- "A monthly report of features nobody opened" (spec 5).
create or replace function public.nav_unused_report(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_role text := coalesce(public.get_my_role(),'none');
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'message', 'Admins only.');
  end if;
  return jsonb_build_object(
    'ok', true,
    'title', 'Features nobody opened',
    'window_label', 'Last ' || p_days || ' days',
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'feature_key', f.feature_key, 'label', f.label,
               'category', c.label, 'opens', coalesce(u.opens,0),
               'note', case when coalesce(u.opens,0) = 0
                            then 'Never opened' else coalesce(u.opens,0) || ' opens' end)
             order by coalesce(u.opens,0), f.sort_order)
        from feature_registry f
        join nav_category c on c.category_key = f.category
        left join (select feature_key, count(*) opens from nav_usage
                    where opened_at > now() - make_interval(days => p_days)
                    group by 1) u on u.feature_key = f.feature_key
       where f.is_active and f.route_key <> '' and f.surface = 'dashboard'
         and coalesce(u.opens,0) = 0
    ), '[]'::jsonb),
    'empty_label', 'Every registered feature was opened at least once.'
  );
end $$;

grant execute on function public.nav_registry()            to authenticated;
grant execute on function public.nav_badge_counts()        to authenticated;
grant execute on function public.nav_pin_toggle(text)      to authenticated;
grant execute on function public.nav_open(text)            to authenticated;
grant execute on function public.nav_unused_report(int)    to authenticated;
