-- CMD #1914 (Om's live steer) — the mobile header carried four things on its
-- right edge (wishlist heart, inbox bell, cart) against one avatar on its left,
-- so the mediBO logo in the "centre" was never centred: it sat wherever the
-- leftover space put it. Om asked for the logo actually centred and for the
-- wishlist and the notification icon to move into the profile dropdown.
--
-- WHERE a customer feature is offered is already backend data (#745), so this
-- move is placement rows, not a Dart edit:
--   * a new placement surface, 'profile_dropdown'
--   * cust.wishlist LEAVES 'catalogue_appbar' and joins it
--   * a new feature, cust.notifications, joins it (the inbox the bell opened)
--   * cust.profile_home joins it, because the avatar's own tap used to BE the
--     way to My Profile and the sheet must not swallow that door
-- Every label, caption, badge and the sheet's own title come from here.
begin;

-- ── 1. the placement surface ────────────────────────────────────────────────
alter table public.customer_feature_placement
  drop constraint if exists customer_feature_placement_placement_ck;
alter table public.customer_feature_placement
  add constraint customer_feature_placement_placement_ck check (
    placement = any (array['profile_account','catalogue_appbar','home_chip',
                           'orders_section','home_badge','profile_dropdown']));

-- ── 2. the two features the dropdown gains ──────────────────────────────────
insert into public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key, sort_order,
   surface, category, roles_allowed, owner, default_access, is_active, deep_link)
values
  ('cust.profile_home',   'My profile',    'Your account, KYC and settings',
     'Account',  'person',        'cust_profile_home',  5,  'customer_menu', 'cust_account',
     array['customer','super_admin'], 'medibo', 'none', true, '/profile'),
  ('cust.notifications',  'Notifications', 'Order updates and messages from mediBO',
     'Account',  'notifications', 'cust_notifications', 15, 'customer_menu', 'cust_account',
     array['customer','super_admin'], 'medibo', 'none', true, '/notifications')
on conflict (feature_key) do update
  set label = excluded.label,
      description = excluded.description,
      group_label = excluded.group_label,
      icon_key = excluded.icon_key,
      route_key = excluded.route_key,
      sort_order = excluded.sort_order,
      surface = excluded.surface,
      category = excluded.category,
      roles_allowed = excluded.roles_allowed,
      deep_link = excluded.deep_link,
      is_active = true;

-- Every live tile needs a declared door or surface_map_audit calls it drift.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('cust_profile_home',  'cust.profile_home',  'feature', 'customer_menu', 'ProfileScreen', true),
  ('cust_notifications', 'cust.notifications', 'feature', 'customer_menu', 'NotificationsInboxScreen', true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind,
      handled_by = excluded.handled_by,
      note = excluded.note,
      is_active = true,
      updated_at = now();

-- ── 3. the move itself ──────────────────────────────────────────────────────
insert into public.customer_feature_placement (placement, feature_key, sort_order, render_kind)
values
  ('profile_dropdown', 'cust.profile_home',  10, 'row'),
  ('profile_dropdown', 'cust.wishlist',      20, 'row'),
  ('profile_dropdown', 'cust.notifications', 30, 'row')
on conflict (placement, feature_key) do update
  set sort_order = excluded.sort_order,
      render_kind = excluded.render_kind,
      is_active = true,
      updated_at = now();

-- The heart leaves the app bar. Deleting the placement is how a move is
-- expressed (#745's own words); re-running this is a no-op.
delete from public.customer_feature_placement
 where placement = 'catalogue_appbar'
   and feature_key = 'cust.wishlist';

-- ── 4. the sheet's own words ────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('cust_menu.dropdown_title',   to_jsonb('My account'::text)),
  ('cust_menu.dropdown_caption', to_jsonb('Wishlist, notifications and your profile'::text)),
  ('cust_menu.notif_none',       to_jsonb('No new notifications'::text))
on conflict (key) do nothing;

-- ── 5. customer_surfaces() serves the new placement ─────────────────────────
-- Rebuilt whole (the #745 QA-round-2 body plus 'profile_dropdown'): the loop
-- gains the surface, the badge case gains the inbox's own unread label, and the
-- payload gains the sheet's title and caption. Nothing is worded in Dart.
create or replace function public.customer_surfaces()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role   text := coalesce(public.get_my_role(), 'none');
  v_cust   uuid := public.my_customer_id();
  v_prof   record;
  v_term   text;
  v_code   text;
  v_absent text := coalesce(public._c('cust_menu.value_absent'), '');
  v_place  jsonb := '{}'::jsonb;
  v_items  jsonb;
  v_wish   int := 0;
  v_wlabel text := '';
  v_rw     jsonb;
  v_rbadge text := '';
  v_rlines jsonb := '[]'::jsonb;
  v_notif  jsonb := '{}'::jsonb;
  v_nlabel text := '';
  v_has    boolean := (auth.uid() is not null and v_cust is not null);
  p        text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', true, 'role', v_role, 'has_account', false,
                              'placements', '{}'::jsonb);
  end if;

  -- The inbox belongs to a signed-in IDENTITY, not to a pharmacy row, so the
  -- unread label is read before the account gate below.
  begin
    v_notif := coalesce(public.notif_inbox_unread(), '{}'::jsonb);
  exception when others then
    v_notif := '{}'::jsonb;
  end;
  if coalesce((v_notif->>'show')::boolean, false) then
    v_nlabel := coalesce(v_notif->>'label', '');
  end if;

  if v_has then
    select pp.* into v_prof from public.pharmacy_profiles pp where pp.id = v_cust;

    select count(*)::int into v_wish
      from public.wishlist_items w where w.account_id = v_cust;
    v_wlabel := case when v_wish > 0 then v_wish::text else '' end;

    v_rw := public.loyalty_my_rewards();
    if coalesce((v_rw->'points'->>'on')::boolean, false) then
      v_rbadge := coalesce(v_rw->'points'->>'balance_label', '');
    else
      v_rbadge := coalesce(v_rw->'tier'->>'current_label', '');
    end if;

    if coalesce((v_rw->>'any_on')::boolean, false) then
      select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_rlines from (
        select 1 as ord, v_rw->'points'->>'balance_label' as x
         where coalesce((v_rw->'points'->>'on')::boolean, false)
        union all
        select 2, v_rw->'tier'->>'current_label'
         where coalesce((v_rw->'tier'->>'on')::boolean, false)
        union all
        select 3, btrim(coalesce(v_rw->'referral'->>'code_label','') || ' '
                        || coalesce(v_rw->'referral'->>'code',''))
         where coalesce((v_rw->'referral'->>'on')::boolean, false)
      ) s where coalesce(x, '') <> '';
    else
      v_rlines := jsonb_build_array(coalesce(public._c('cust_menu.rewards_off'), ''));
      v_rlines := (select coalesce(jsonb_agg(e), '[]'::jsonb)
                     from jsonb_array_elements_text(v_rlines) e where e <> '');
    end if;
  end if;

  foreach p in array array['profile_account','catalogue_appbar','orders_section',
                           'home_strip','profile_dropdown']
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'feature_key', f.feature_key,
             'label',       f.label,
             'caption',     coalesce(f.description, ''),
             'icon_key',    f.icon_key,
             'icon_letter', upper(left(f.label, 1)),
             'route_key',   f.route_key,
             'render_kind', cp.render_kind,
             'badge', case f.feature_key
                        when 'cust.wishlist'      then v_wlabel
                        when 'cust.rewards'       then v_rbadge
                        when 'cust.notifications' then v_nlabel
                        else '' end,
             'lines', case f.feature_key
                        when 'cust.rewards' then v_rlines
                        else '[]'::jsonb end)
           order by cp.sort_order, cp.placement, f.sort_order), '[]'::jsonb)
      into v_items
      from public.customer_feature_placement cp
      join public.feature_registry f on f.feature_key = cp.feature_key
     where cp.placement = any (case when p = 'home_strip'
                                    then array['home_chip','home_badge']
                                    else array[p] end)
       and cp.is_active
       and f.is_active
       and v_role = any (f.roles_allowed)
       and (v_has or not cp.needs_account);
    v_place := v_place || jsonb_build_object(p, v_items);
  end loop;

  if not v_has then
    return jsonb_build_object(
      'ok', true, 'role', v_role, 'has_account', false,
      'placements', v_place,
      'notif', jsonb_build_object('label', v_nlabel,
                                  'empty_note', coalesce(public._c('cust_menu.notif_none'), '')),
      'dropdown_title',   coalesce(public._c('cust_menu.dropdown_title'), ''),
      'dropdown_caption', coalesce(public._c('cust_menu.dropdown_caption'), ''),
      'account_title', coalesce(public._c('cust_menu.account_title'), ''));
  end if;

  v_term := nullif(btrim(coalesce(v_prof.payment_term, '')), '');
  if v_term is null then
    v_term := nullif(btrim(coalesce(
      (select value #>> '{}' from public.app_settings
        where key = 'customer_default_payment_term'), '')), '');
  end if;
  v_code := nullif(btrim(coalesce(v_prof.customer_code, '')), '');

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'has_account', true,
    'placements', v_place,
    'offline_note', coalesce(public._c('cust_menu.offline_note'), ''),
    'account_setup', jsonb_build_object(
      'title', coalesce(public._c('cust_menu.setup_title'), ''),
      'rows', jsonb_build_array(
        jsonb_build_object(
          'key',      'payment_term',
          'label',    coalesce(public._c('cust_menu.row_payment_term'), ''),
          'value',    coalesce(v_term, v_absent),
          'has',      v_term is not null,
          'icon_key', 'payments'),
        jsonb_build_object(
          'key',      'customer_code',
          'label',    coalesce(public._c('cust_menu.row_customer_code'), ''),
          'value',    coalesce(v_code, v_absent),
          'has',      v_code is not null,
          'icon_key', 'rule'))),
    'account_title', coalesce(public._c('cust_menu.account_title'), ''),
    -- CMD #1914 — the profile dropdown's own heading and its one-line caption.
    'dropdown_title',   coalesce(public._c('cust_menu.dropdown_title'), ''),
    'dropdown_caption', coalesce(public._c('cust_menu.dropdown_caption'), ''),
    'notif', jsonb_build_object(
      'label',      v_nlabel,
      'count',      coalesce((v_notif->>'count')::int, 0),
      'tooltip',    coalesce(v_notif->>'tooltip', ''),
      'empty_note', coalesce(public._c('cust_menu.notif_none'), '')),
    'wishlist', jsonb_build_object(
      'has',   v_wish > 0,
      'count', v_wish,
      'count_label', v_wlabel,
      'tooltip', coalesce(public._c('cust_menu.wishlist_tooltip'), '')),
    'rewards', jsonb_build_object(
      'has',        coalesce((v_rw->>'any_on')::boolean, false),
      'title',      coalesce(v_rw->>'title', ''),
      'open_label', coalesce(public._c('cust_menu.rewards_open'), ''),
      'off_note',   coalesce(public._c('cust_menu.rewards_off'), ''),
      'badge_label', v_rbadge,
      'lines',      v_rlines));
end $fn$;

grant execute on function public.customer_surfaces() to anon, authenticated, service_role;

commit;
