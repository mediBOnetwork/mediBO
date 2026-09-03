-- CHANGE #745 — the customer profile menu stops being a dumping ground.
--
-- Om, live on My Profile (3 Sep): the dropdown carried My Wishlist, Rewards and
-- "Deliver with mediBO" next to Edit my details, Delivery addresses, Staff
-- logins and Logout. Three of those are not account settings — a wishlist is
-- shopping, rewards are purchases, and a pharmacy buying trade stock is not a
-- rider applicant. All three were hardcoded `if (...) _EntryCard()` lines in
-- lib/screens/profile_screen.dart, so WHERE a customer feature lives was a Dart
-- decision, which is exactly the thing max-backend forbids.
--
-- This is the #653 arrangement applied to the customer's own chrome: the
-- registry says which features a customer has, a PLACEMENT table says which
-- customer surface offers each one, and Flutter renders the answer verbatim.
-- Moving Rewards from Profile to Orders tomorrow is one UPDATE, not a deploy.
--
-- Idempotent throughout (#233): a resumed worker re-applies this as a no-op.

begin;

-- ── 1. the heart glyph ──────────────────────────────────────────────────────
-- nav_icon_audit()/rg_check demand every registry icon_key exist here AND in
-- kNavIcons; the wishlist entry is the first customer row that wants a heart.
insert into public.ui_icon (icon_key, label)
values ('favorite', 'Heart / wishlist')
on conflict (icon_key) do nothing;

-- ── 2. the two customer groups ──────────────────────────────────────────────
insert into public.nav_category (category_key, label, icon_key, sort_order, is_active)
values ('cust_account',  'Account',  'person',   1050, true),
       ('cust_shopping', 'Shopping', 'bag',      1060, true)
on conflict (category_key) do update
  set label = excluded.label,
      icon_key = excluded.icon_key,
      sort_order = excluded.sort_order,
      is_active = true;

-- ── 3. a surface for the customer's own chrome ──────────────────────────────
-- 'profile' is pinned by feature_registry_surface_ck to the two identity rows
-- that give EVERY role a View Profile and a Logout (surface_map_audit R3
-- depends on that), so the customer's menu gets its own surface rather than
-- widening one every role shares.
alter table public.feature_registry
  drop constraint if exists feature_registry_surface_ck;
alter table public.feature_registry
  add constraint feature_registry_surface_ck check (
    surface = any (array['dashboard','profile','both','dev_tools','fulfill_tab',
                         'customer_shop','customer_tab','supplier_tab','customer_menu'])
    and (surface <> 'profile'
         or (category = 'identity'
             and feature_key = any (array['identity.view_profile','identity.logout'])))
  );

insert into public.surface_audience (surface, label, audience, resolver)
values ('customer_menu', 'Pharmacy customer menu',
        array['customer','super_admin'], 'customer_surfaces()')
on conflict (surface) do update
  set label = excluded.label,
      audience = excluded.audience,
      resolver = excluded.resolver,
      updated_at = now();

-- ── 4. the customer's features ──────────────────────────────────────────────
-- label/description ARE the display strings (the same arrangement
-- customer_shop_home() ships), so a rename is an UPDATE.
insert into public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key, sort_order,
   surface, category, roles_allowed, owner, default_access, is_active)
values
  ('cust.profile_edit',    'Edit my details',        'Name, contact and business details',
     'Account',  'person',        'cust_profile_edit',  10, 'customer_menu', 'cust_account',
     array['customer','super_admin'], 'medibo', 'none', true),
  ('cust.address_book',    'Delivery addresses',     'Where your orders are delivered',
     'Account',  'map',           'cust_addresses',     20, 'customer_menu', 'cust_account',
     array['customer','super_admin'], 'medibo', 'none', true),
  ('cust.staff_logins',    'Staff logins',           'Extra logins for your counter staff',
     'Account',  'badge',         'cust_staff_logins',  30, 'customer_menu', 'cust_account',
     array['customer','super_admin'], 'medibo', 'none', true),
  ('cust.logout',          'Logout',                 'Sign out of this device',
     'Account',  'logout',        'cust_logout',        80, 'customer_menu', 'cust_account',
     array['customer','super_admin'], 'medibo', 'none', true),
  ('cust.delete_account',  'Delete account or data', 'Remove your data or close the account',
     'Account',  'person_remove', 'cust_delete_account',90, 'customer_menu', 'cust_account',
     array['customer','super_admin'], 'medibo', 'none', true),
  ('cust.wishlist',        'My Wishlist',            'Products you saved to order later',
     'Shopping', 'favorite',      'cust_wishlist',      10, 'customer_menu', 'cust_shopping',
     array['customer','super_admin'], 'medibo', 'none', true),
  ('cust.rewards',         'Rewards',                'Points, slab and your referral code',
     'Shopping', 'stars',         'cust_rewards',       20, 'customer_menu', 'cust_shopping',
     array['customer','super_admin'], 'medibo', 'none', true)
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
      is_active = excluded.is_active;

-- Every live tile needs a declared door or surface_map_audit R1 calls it drift.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values
  ('cust_profile_edit',   'cust.profile_edit',   'feature', 'customer_menu', 'ProfileEditScreen',  true),
  ('cust_addresses',      'cust.address_book',   'feature', 'customer_menu', 'AddressBookScreen',  true),
  ('cust_staff_logins',   'cust.staff_logins',   'feature', 'customer_menu', 'CustomerStaffScreen',true),
  ('cust_logout',         'cust.logout',         'feature', 'customer_menu', 'sign out action',    true),
  ('cust_delete_account', 'cust.delete_account', 'feature', 'customer_menu', 'DeleteAccountSection', true),
  ('cust_wishlist',       'cust.wishlist',       'feature', 'customer_menu', 'WishlistScreen',     true),
  ('cust_rewards',        'cust.rewards',        'feature', 'customer_menu', 'RewardsScreen',      true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind,
      handled_by = excluded.handled_by,
      note = excluded.note,
      is_active = true,
      updated_at = now();

-- "Deliver with mediBO" is NOT registered on this surface and is not registered
-- anywhere else either: rider signup keeps its own door at /delivery-register
-- (main.dart) for the public site and the delivery app, and a pharmacy buying
-- trade stock is never offered it. Removing it is the absence of a row.

-- ── 5. WHERE each feature is offered ────────────────────────────────────────
create table if not exists public.customer_feature_placement (
  placement    text not null,
  feature_key  text not null references public.feature_registry(feature_key) on delete cascade,
  sort_order   int  not null default 100,
  render_kind  text not null default 'row',
  is_active    boolean not null default true,
  updated_at   timestamptz not null default now(),
  primary key (placement, feature_key)
);

alter table public.customer_feature_placement
  drop constraint if exists customer_feature_placement_placement_ck;
alter table public.customer_feature_placement
  add constraint customer_feature_placement_placement_ck check (
    placement = any (array['profile_account','catalogue_appbar','home_chip',
                           'orders_section','home_badge']));

alter table public.customer_feature_placement
  drop constraint if exists customer_feature_placement_render_ck;
alter table public.customer_feature_placement
  add constraint customer_feature_placement_render_ck check (
    render_kind = any (array['row','action','danger_zone','icon','chip','section','badge']));

alter table public.customer_feature_placement enable row level security;
drop policy if exists customer_feature_placement_read on public.customer_feature_placement;
create policy customer_feature_placement_read
  on public.customer_feature_placement for select using (true);

insert into public.customer_feature_placement (placement, feature_key, sort_order, render_kind)
values
  ('profile_account',  'cust.profile_edit',   10, 'row'),
  ('profile_account',  'cust.address_book',   20, 'row'),
  ('profile_account',  'cust.staff_logins',   30, 'row'),
  ('profile_account',  'cust.logout',         80, 'action'),
  ('profile_account',  'cust.delete_account', 90, 'danger_zone'),
  ('catalogue_appbar', 'cust.wishlist',       10, 'icon'),
  ('home_chip',        'cust.wishlist',       10, 'chip'),
  ('orders_section',   'cust.rewards',        10, 'section'),
  ('home_badge',       'cust.rewards',        10, 'badge')
on conflict (placement, feature_key) do update
  set sort_order = excluded.sort_order,
      render_kind = excluded.render_kind,
      is_active = true,
      updated_at = now();

-- Wishlist and Rewards are gone from the profile: deleting the placement is how
-- a move is expressed. Re-running this is a no-op.
delete from public.customer_feature_placement
 where placement = 'profile_account'
   and feature_key in ('cust.wishlist','cust.rewards');

commit;
