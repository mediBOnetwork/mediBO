-- CMD #2125 — customer chrome cleanup: the Profile tab.
--
-- The mobile app bar loses the avatar and the cart icon (logo only), My Shop
-- stops being a bottom tab and becomes the first card inside a new Profile
-- tab, and the floating "View cart" pill becomes the cart's only door on
-- every customer tab.
--
-- Everything the Profile tab draws is data:
--   * its rows are `customer_feature_placement` rows on the new placement
--     'profile_tab', joined to `feature_registry` like every other customer
--     surface (customer_surfaces()), grouped by the placement's `section`;
--   * titles and captions are ui_copy keys carried on the placement row
--     (`label_key` / `caption_key`), falling back to the registry's own label;
--   * the header (initial, pharmacy name, phone · code, approval chip) is
--     composed here, never in Dart.
-- The bottom bar is `customer_nav_slot`: my_shop goes inactive, a 'profile'
-- slot opens shell page 15, and cart_pill is on for every slot.
--
-- Idempotent throughout: add-column-if-not-exists, constraint re-create,
-- ON CONFLICT upserts and CREATE OR REPLACE.

-- ── 1. Placement: a section, and ui_copy keys for the words ─────────────────
alter table public.customer_feature_placement
  add column if not exists section     text,
  add column if not exists label_key   text,
  add column if not exists caption_key text;

comment on column public.customer_feature_placement.section is
  'CMD #2125 — profile_tab only: which card the row sits in (tiles, my_shop, info, money, prefs, other).';

alter table public.customer_feature_placement
  drop constraint if exists customer_feature_placement_placement_ck;
alter table public.customer_feature_placement
  add constraint customer_feature_placement_placement_ck
  check (placement = any (array['profile_account','catalogue_appbar','home_chip',
                                'orders_section','home_badge','profile_dropdown',
                                'profile_tab']));

alter table public.customer_feature_placement
  drop constraint if exists customer_feature_placement_render_ck;
alter table public.customer_feature_placement
  add constraint customer_feature_placement_render_ck
  check (render_kind = any (array['row','action','danger_zone','icon','chip',
                                  'section','badge','tile','hero']));

-- ── 2. Registry doors the tab needs that had no row yet ─────────────────────
-- Each one opens a screen that already exists and is reachable elsewhere
-- (My Account's tabs, the documents page, the legal pages, the cart panel),
-- so nothing becomes reachable only from the Profile tab.
-- 'system' is live's category for cust.my_account; a thin branch may lack it.
insert into public.nav_category (category_key, label, icon_key)
select 'system', 'System', 'settings'
 where not exists (select 1 from public.nav_category where category_key = 'system');

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, tab_screen, sort_order,
   category, surface, roles_allowed, description,
   test_automatable, test_skip_reason)
values
  ('cust.my_shop',    'My Shop',          'Account', 'store',          'my_shop',        null,         400, 'system', 'customer_menu', array['customer','super_admin'], 'Billing · stock · khata · expiry', false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.ledger',     'Ledger',           'Money',   'book',           'cust_account',   'statement',  401, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.payments',   'Payments',         'Money',   'payments',       'cust_account',   'billing',    402, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.advance',    'Advance & credit', 'Money',   'wallet',         'cust_account',   'billing',    403, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.statements', 'Statements',       'Money',   'description',    'cust_account',   'statement',  404, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.gst_licence','GST & licence',    'Account', 'account_balance','cust_documents', null,         405, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.cart',       'Your cart',        'Account', 'bag',            'cust_cart',      null,         406, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.appearance', 'Appearance',       'Prefs',   'settings',       'cust_account',   'preferences',407, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.language',   'Language',         'Prefs',   'settings_suggest','cust_account',  'preferences',408, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.share_app',  'Share the app',    'Other',   'people',         'cust_share',     null,         409, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.about',      'About mediBO',     'Other',   'business',       'cust_about',     null,         410, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.privacy',    'Privacy',          'Other',   'key',            'cust_privacy',   null,         411, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.'),
  ('cust.terms',      'Terms',            'Other',   'rule',           'cust_terms',     null,         412, 'system', 'customer_menu', array['customer','super_admin'], null, false, 'CMD #2125 door row on the Profile tab; covered by feat-2125.')
on conflict (feature_key) do update
  set route_key  = excluded.route_key,
      tab_screen = excluded.tab_screen,
      is_active  = true;

-- ── 3. The words ────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('home_shell.nav_profile',       to_jsonb('Profile'::text)),
  ('profile_tab.section_info',     to_jsonb('Your information'::text)),
  ('profile_tab.section_money',    to_jsonb('Money'::text)),
  ('profile_tab.section_prefs',    to_jsonb('Preferences'::text)),
  ('profile_tab.section_other',    to_jsonb('Other'::text)),
  ('profile_tab.tile_orders',      to_jsonb('Your orders'::text)),
  ('profile_tab.tile_ledger',      to_jsonb('Ledger'::text)),
  ('profile_tab.tile_help',        to_jsonb('Need help?'::text)),
  ('profile_tab.my_shop',          to_jsonb('My Shop'::text)),
  ('profile_tab.my_shop_caption',  to_jsonb('Billing · stock · khata · expiry'::text)),
  ('profile_tab.row_kyc',          to_jsonb('Profile & KYC'::text)),
  ('profile_tab.row_addresses',    to_jsonb('Delivery addresses'::text)),
  ('profile_tab.row_wishlist',     to_jsonb('Wishlist'::text)),
  ('profile_tab.row_saved_lists',  to_jsonb('Saved lists'::text)),
  ('profile_tab.row_gst',          to_jsonb('GST & licence details'::text)),
  ('profile_tab.row_staff',        to_jsonb('Staff logins'::text)),
  ('profile_tab.row_cart',         to_jsonb('Your cart'::text)),
  ('profile_tab.row_payments',     to_jsonb('Payments'::text)),
  ('profile_tab.row_advance',      to_jsonb('Advance & credit'::text)),
  ('profile_tab.row_statements',   to_jsonb('Statements'::text)),
  ('profile_tab.row_rewards',      to_jsonb('Rewards'::text)),
  ('profile_tab.row_notifications',to_jsonb('Notifications'::text)),
  ('profile_tab.row_appearance',   to_jsonb('Appearance'::text)),
  ('profile_tab.row_language',     to_jsonb('Language'::text)),
  ('profile_tab.row_share',        to_jsonb('Share the app'::text)),
  ('profile_tab.row_about',        to_jsonb('About mediBO'::text)),
  ('profile_tab.row_privacy',      to_jsonb('Privacy'::text)),
  ('profile_tab.row_terms',        to_jsonb('Terms'::text)),
  ('profile_tab.row_logout',       to_jsonb('Log out'::text)),
  ('profile_tab.share_text',       to_jsonb('Order every brand for your pharmacy in one place on mediBO — https://medibo.in'::text)),
  ('profile_tab.share_copied',     to_jsonb('Link copied — paste it anywhere to share'::text)),
  ('profile_tab.signed_out_title', to_jsonb('Your pharmacy account'::text)),
  ('profile_tab.signed_out_caption', to_jsonb('Sign in to see your orders, ledger and shop tools.'::text)),
  ('profile_tab.signed_out_button',to_jsonb('Sign in'::text)),
  ('profile_tab.error',            to_jsonb('Could not load your profile.'::text)),
  ('profile_tab.retry',            to_jsonb('Retry'::text))
on conflict (key) do nothing;

-- ── 4. The rows, section by section, in the approved order ─────────────────
insert into public.customer_feature_placement
  (placement, feature_key, sort_order, render_kind, is_active, needs_account,
   section, label_key, caption_key)
values
  ('profile_tab', 'cust.orders',        110, 'tile',   true, true,  'tiles', 'profile_tab.tile_orders',  null),
  ('profile_tab', 'cust.ledger',        120, 'tile',   true, true,  'tiles', 'profile_tab.tile_ledger',  null),
  ('profile_tab', 'cust.help_requests', 130, 'tile',   true, true,  'tiles', 'profile_tab.tile_help',    null),
  ('profile_tab', 'cust.my_shop',       210, 'hero',   true, true,  'my_shop','profile_tab.my_shop',     'profile_tab.my_shop_caption'),
  ('profile_tab', 'cust.my_account',    310, 'row',    true, true,  'info',  'profile_tab.row_kyc',      null),
  ('profile_tab', 'cust.address_book',  320, 'row',    true, true,  'info',  'profile_tab.row_addresses',null),
  ('profile_tab', 'cust.wishlist',      330, 'row',    true, true,  'info',  'profile_tab.row_wishlist', null),
  ('profile_tab', 'cust.saved_lists',   340, 'row',    true, true,  'info',  'profile_tab.row_saved_lists', null),
  ('profile_tab', 'cust.gst_licence',   350, 'row',    true, true,  'info',  'profile_tab.row_gst',      null),
  ('profile_tab', 'cust.staff_logins',  360, 'row',    true, true,  'info',  'profile_tab.row_staff',    null),
  ('profile_tab', 'cust.cart',          370, 'row',    true, false, 'info',  'profile_tab.row_cart',     null),
  ('profile_tab', 'cust.payments',      410, 'row',    true, true,  'money', 'profile_tab.row_payments', null),
  ('profile_tab', 'cust.advance',       420, 'row',    true, true,  'money', 'profile_tab.row_advance',  null),
  ('profile_tab', 'cust.statements',    430, 'row',    true, true,  'money', 'profile_tab.row_statements', null),
  ('profile_tab', 'cust.rewards',       440, 'row',    true, true,  'money', 'profile_tab.row_rewards',  null),
  ('profile_tab', 'cust.notifications', 510, 'row',    true, false, 'prefs', 'profile_tab.row_notifications', null),
  ('profile_tab', 'cust.appearance',    520, 'row',    true, true,  'prefs', 'profile_tab.row_appearance', null),
  ('profile_tab', 'cust.language',      530, 'row',    true, true,  'prefs', 'profile_tab.row_language', null),
  ('profile_tab', 'cust.share_app',     610, 'action', true, false, 'other', 'profile_tab.row_share',    null),
  ('profile_tab', 'cust.about',         620, 'row',    true, false, 'other', 'profile_tab.row_about',    null),
  ('profile_tab', 'cust.privacy',       630, 'row',    true, false, 'other', 'profile_tab.row_privacy',  null),
  ('profile_tab', 'cust.terms',         640, 'row',    true, false, 'other', 'profile_tab.row_terms',    null),
  ('profile_tab', 'cust.logout',        690, 'action', true, false, 'other', 'profile_tab.row_logout',   null)
on conflict (placement, feature_key) do update
  set sort_order  = excluded.sort_order,
      render_kind = excluded.render_kind,
      section     = excluded.section,
      label_key   = excluded.label_key,
      caption_key = excluded.caption_key,
      updated_at  = now();

-- ── 5. The Profile tab payload ──────────────────────────────────────────────
create or replace function public.customer_profile_tab()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role  text := coalesce(public.get_my_role(), 'none');
  v_cust  uuid := public.my_customer_id();
  v_has   boolean := (auth.uid() is not null and v_cust is not null);
  pp      record;
  v_name  text := '';
  v_sub   text := '';
  v_chip  jsonb := '{}'::jsonb;
  v_wish  text := '';
  v_rbadge text := '';
  v_rw    jsonb;
  v_notif jsonb := '{}'::jsonb;
  v_nlabel text := '';
  v_sections jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'signed_out');
  end if;

  if v_has then
    select * into pp from public.pharmacy_profiles where id = v_cust;
    v_name := coalesce(nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                       nullif(btrim(coalesce(pp.customer_name,'')),''),
                       nullif(btrim(coalesce(pp.owner_name,'')),''), '');
    v_sub := array_to_string(array_remove(array[
               nullif(btrim(coalesce(pp.phone,'')),''),
               nullif(btrim(coalesce(pp.customer_code,'')),'')], null), ' · ');
    v_chip := case
      when coalesce(pp.approved,false) and coalesce(pp.status,'') = 'suspended'
        then jsonb_build_object('label', public._c('profile.badge_suspended'), 'tone', 'danger')
      when coalesce(pp.approved,false)
        then jsonb_build_object('label', public._c('profile.badge_approved'), 'tone', 'success')
      else jsonb_build_object('label', public._c('profile.badge_pending'), 'tone', 'warning')
    end;
    select case when count(*) > 0 then count(*)::text else '' end into v_wish
      from public.wishlist_items w where w.account_id = v_cust;
    begin
      v_rw := public.loyalty_my_rewards();
      if coalesce((v_rw->'points'->>'on')::boolean, false) then
        v_rbadge := coalesce(v_rw->'points'->>'balance_label', '');
      end if;
    exception when others then v_rbadge := '';
    end;
  else
    v_name := coalesce(nullif(btrim(coalesce(
                (select raw_user_meta_data->>'full_name' from auth.users where id = auth.uid()),'')),''), '');
    v_chip := jsonb_build_object('label', public._c('profile.badge_not_registered'), 'tone', 'neutral');
  end if;

  begin
    v_notif := coalesce(public.notif_inbox_unread(), '{}'::jsonb);
  exception when others then v_notif := '{}'::jsonb;
  end;
  if coalesce((v_notif->>'show')::boolean, false) then
    v_nlabel := coalesce(v_notif->>'label', '');
  end if;

  with rows as (
    select cp.section,
           min(cp.sort_order) over (partition by cp.section) as section_sort,
           cp.sort_order,
           jsonb_build_object(
             'feature_key', f.feature_key,
             'label',  coalesce(nullif(public._c(cp.label_key),''), f.label),
             'caption', coalesce(nullif(public._c(cp.caption_key),''), ''),
             'icon_key', f.icon_key,
             'route_key', f.route_key,
             'tab', coalesce(f.tab_screen, ''),
             'render_kind', cp.render_kind,
             'tone', case when f.route_key in ('cust_logout','logout') then 'danger' else 'default' end,
             'badge', case f.feature_key
                        when 'cust.wishlist'      then v_wish
                        when 'cust.rewards'       then v_rbadge
                        when 'cust.notifications' then v_nlabel
                        else '' end) as item
      from public.customer_feature_placement cp
      join public.feature_registry f on f.feature_key = cp.feature_key
     where cp.placement = 'profile_tab'
       and cp.is_active and f.is_active
       and v_role = any (f.roles_allowed)
       and (v_has or not cp.needs_account)
  ), grouped as (
    select section, min(section_sort) as s_sort,
           jsonb_agg(item order by sort_order) as items
      from rows group by section
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   g.section,
           'kind',  case g.section when 'tiles' then 'tiles'
                                   when 'my_shop' then 'hero'
                                   else 'rows' end,
           'title', public._c('profile_tab.section_' || g.section),
           'items', g.items) order by g.s_sort), '[]'::jsonb)
    into v_sections
    from grouped g;

  return jsonb_build_object(
    'ok', true,
    'has_account', v_has,
    'header', jsonb_build_object(
      'avatar_label', upper(left(coalesce(nullif(v_name,''), '·'), 1)),
      'title',    v_name,
      'subtitle', v_sub,
      'chip',     v_chip),
    'sections', v_sections,
    'share_text',   public._c('profile_tab.share_text'),
    'share_copied', public._c('profile_tab.share_copied'));
end $function$;

revoke all on function public.customer_profile_tab() from public, anon;
grant execute on function public.customer_profile_tab() to authenticated, service_role;

-- ── 6. The bottom bar: My Shop out, Profile in, the pill everywhere ─────────
insert into public.customer_nav_slot
  (slot_key, label_key, icon_key, page_index, sort_order, is_active,
   visibility, badge_key, roles_allowed, cart_pill)
values
  ('profile', 'home_shell.nav_profile', 'avatar', 15,
   coalesce((select sort_order from public.customer_nav_slot where slot_key = 'my_shop'), 50),
   true, 'always', 'shop', null, true)
on conflict (slot_key) do update
  set label_key  = excluded.label_key,
      icon_key   = excluded.icon_key,
      page_index = excluded.page_index,
      is_active  = true,
      badge_key  = excluded.badge_key,
      roles_allowed = null,
      cart_pill  = true,
      updated_at = now();

update public.customer_nav_slot
   set is_active = false, updated_at = now()
 where slot_key = 'my_shop' and is_active;

update public.customer_nav_slot
   set cart_pill = true, updated_at = now()
 where cart_pill is distinct from true;

-- customer_nav(), verbatim from live with one key added: the avatar slot's
-- initial, so the tab can wear the pharmacy's letter without Dart slicing it.
create or replace function public.customer_nav()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- CHANGE #570 — the audience of a slot is the slot's own roles_allowed, not
  -- "not an admin". get_my_role() is the one role answer the whole app uses.
  with me as (select coalesce(public.get_my_role(),'none') as role),
  av as (
    select upper(left(coalesce(
             nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
             nullif(btrim(coalesce(pp.customer_name,'')),''),
             nullif(btrim(coalesce(pp.owner_name,'')),''), ''), 1)) as letter
      from (select 1) one
      left join public.pharmacy_profiles pp on pp.id = public.my_customer_id()
  )
  select jsonb_build_object(
    'ok', true,
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key',        s.slot_key,
               'label',      public._c(s.label_key),
               'icon_key',   s.icon_key,
               'page_index', s.page_index,
               'badge_key',  s.badge_key,
               -- CMD #2043 — does this page float the cart pill?
               'cart_pill',  s.cart_pill,
               -- CMD #2125 — the letter an 'avatar' glyph wears ('' = person icon).
               'avatar_label', case when s.icon_key = 'avatar' then coalesce(av.letter,'') else '' end)
             order by s.sort_order, s.slot_key)
        from public.customer_nav_slot s, me, av
       where s.is_active
         and (s.roles_allowed is null
              or me.role = any (s.roles_allowed))), '[]'::jsonb));
$function$;
