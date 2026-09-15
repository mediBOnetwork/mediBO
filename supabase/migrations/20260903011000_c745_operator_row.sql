-- CHANGE #745 (part 3) — the last Dart role branch on the customer profile.
--
-- Spec item 5: "anything else currently in the customer profile that is
-- admin/partner/supplier-only (audit the registry) → hide for role customer".
--
-- The audit found exactly two operator surfaces on that screen, both already
-- invisible to a pharmacy — but invisible because Dart asked
-- `session?.isSuperAdmin`, which is a second source of truth next to the
-- registry. The Loyalty control panel becomes a registry row whose audience is
-- the backend's (`roles_allowed = {super_admin}`), so a customer's payload
-- simply does not contain it and there is no bool in Dart to get wrong.
--
-- The View As card stays in Dart on purpose: it is gated by the compile-time
-- `kEnableViewAs` flag as well as the role, it is a dialog rather than a
-- screen, and a dev tool that ships disabled is not a nav entry.
--
-- Idempotent (#233).

begin;

insert into public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key, sort_order,
   surface, category, roles_allowed, owner, default_access, is_active, deep_link)
values
  ('cust.loyalty_admin', 'Loyalty control panel', 'Tiers, points and referral programmes',
     'Account', 'stars', 'cust_loyalty_admin', 70, 'customer_menu', 'cust_account',
     array['super_admin'], 'medibo', 'none', true, null)
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
      is_active = excluded.is_active;

insert into public.surface_route (route_key, feature_key, kind, handled_by, note, is_active)
values ('cust_loyalty_admin', 'cust.loyalty_admin', 'feature', 'customer_menu',
        'LoyaltyAdminScreen', true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind, handled_by = excluded.handled_by,
      note = excluded.note, is_active = true, updated_at = now();

insert into public.customer_feature_placement (placement, feature_key, sort_order, render_kind)
values ('profile_account', 'cust.loyalty_admin', 70, 'row')
on conflict (placement, feature_key) do update
  set sort_order = excluded.sort_order, render_kind = excluded.render_kind,
      is_active = true, updated_at = now();

commit;
