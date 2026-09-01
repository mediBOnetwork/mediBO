
-- ── 8. reachability ────────────────────────────────────────────────────────
-- A feature Om cannot tap does not exist. Two doors, both additive:
-- the pharmacy's own tile strip (owner-only, beside the expiry radar and the
-- stock check), and the admin dashboard's feature registry.

create or replace function public.pharmacy_shield_entry()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $$
declare v_shop uuid := public._c413_shop(); v_owner boolean;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false, 'tiles', '[]'::jsonb); end if;
  v_owner := public._c413_is_owner(v_shop);
  return jsonb_build_object(
    'ok', true, 'show', true, 'is_owner', v_owner,
    'tiles', jsonb_build_array(
      jsonb_build_object(
        'route_key', 'pharmacy_expiry', 'icon_key', 'schedule',
        'label',     public.ui_text('phx.nav_label'),
        'sub_label', public.ui_text('phx.subtitle'))) ||
      case when v_owner then jsonb_build_array(
        jsonb_build_object(
          'route_key', 'pharmacy_variance', 'icon_key', 'fact_check',
          'label',     public.ui_text('phv.nav_label'),
          'sub_label', public.ui_text('phv.subtitle'),
          'note',      public.ui_text('phv.owner_only_note')),
        jsonb_build_object(
          'route_key', 'near_listing', 'icon_key', 'store',
          'label',     public.ui_text('near.own_nav_label'),
          'sub_label', public.ui_text('near.own_subtitle')))
           else '[]'::jsonb end);
end $$;

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   category, surface, roles_allowed, is_active, description)
values ('pharmacy.near_listing', 'Nearby listing', 'Pharmacy tools', 'store',
        'near_listing', 640, 'medibo', 'parties', 'dashboard',
        array['admin','super_admin'], true,
        'CMD #426 - the pharmacy''s opt-in listing on the public consumer search at /near')
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key,
      roles_allowed = excluded.roles_allowed, is_active = true,
      description = excluded.description;

-- ── 9. a hole the guard caught while this command was landing ──────────────
-- Not #426's function, but #426 could not complete past a red rg_check and the
-- guard named the fix itself: every SECURITY DEFINER function inherits
-- Postgres's default GRANT TO PUBLIC, and the anon key ships inside the web
-- bundle and the APK — so this admin/warehouse RPC was a public endpoint.
-- Idempotent, and safe for its own screen, which calls it with an admin JWT.
do $$
begin
  execute 'revoke execute on function public.admin_demand_engine(integer, date) from public, anon';
exception when undefined_function then null;
end $$;
