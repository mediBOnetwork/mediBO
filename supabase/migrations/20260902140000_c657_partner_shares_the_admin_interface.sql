-- CHANGE #657 — ONE interface means the SAME nav, not a stripped one.
--
-- #653 collapsed super admin, admin and partner into one shell. #657 deleted the
-- last client-side partner branch, and the first partner login to reach the
-- shared shell arrived with a bottom bar holding exactly one tab: Dashboard.
--
-- Why: the five containers are gated on admin.dashboard / admin.whatsapp /
-- admin.customers / admin.suppliers / admin.fulfillment, and the partner role
-- default granted only the first. Every grant a partner actually holds is named
-- partner.pack, partner.inquiry, partner.collect, partner.supplier_orders… —
-- tabs INSIDE those containers. So the matrix hid every door to the work she has
-- full write access to, and deleting the old Partner page would have left her
-- with nothing to do.
--
-- Two changes, and neither weakens a gate:
--   1. The partner role default carries VIEW on the five containers. Write is
--      NOT granted here — what a partner may CHANGE is still the per-feature
--      matrix's answer, and every tab inside each container is still gated on
--      its own feature.
--   2. A container route is also viewable when any TAB inside it is viewable
--      (feature_registry.tab_screen -> partner_screen_tab.screen). That keeps
--      the rule true for the NEXT partner without another data edit: grant
--      someone partner.pack and the Fulfil door opens by itself.
--
-- Idempotent throughout: a resumed worker re-applying this is a no-op.

-- ── 1. The five containers, for the partner role ────────────────────────────
insert into public.access_role_default (role, feature_key, can_view, can_write)
values ('partner', 'admin.dashboard',   true, false),
       ('partner', 'admin.whatsapp',    true, false),
       ('partner', 'admin.customers',   true, false),
       ('partner', 'admin.suppliers',   true, false),
       ('partner', 'admin.fulfillment', true, false)
on conflict (role, feature_key) do update set can_view = true, updated_at = now();

-- ── 2. Which tab screen a container route opens ─────────────────────────────
alter table public.feature_registry add column if not exists tab_screen text;

comment on column public.feature_registry.tab_screen is
  'CHANGE #657 — the partner_screen_tab.screen this route opens. When set, the '
  'route is viewable if its own feature grants View OR any tab of that screen '
  'does, so a grant on a tab can never leave its container hidden.';

update public.feature_registry set tab_screen = 'fulfillment'
 where route_key = 'fulfillment' and tab_screen is distinct from 'fulfillment';
update public.feature_registry set tab_screen = 'customer'
 where route_key = 'customers'   and tab_screen is distinct from 'customer';
update public.feature_registry set tab_screen = 'supplier'
 where route_key = 'suppliers'   and tab_screen is distinct from 'supplier';

-- ── 3. access_boot(): tab index in the payload + the container-OR rule ──────
create or replace function public.access_boot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare s jsonb; v_feat jsonb; v_routes jsonb; v_tabs jsonb; v_zone text;
begin
  s := public.access_subject();
  if not (s->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'role','none', 'features','{}'::jsonb,
      'routes','{}'::jsonb, 'tabs','{}'::jsonb,
      'denied_view_message', public._c('access.denied_view'),
      'denied_write_message', public._c('access.denied_write'),
      'readonly_badge', public._c('access.readonly_badge'));
  end if;

  select coalesce(jsonb_object_agg(e.feature_key,
           jsonb_build_object('v', e.can_view, 'w', e.can_write)), '{}'::jsonb)
    into v_feat from public.access_effective(s->>'kind', s->>'id') e;

  -- Alias keys answer too, so a caller may ask with either name.
  select v_feat || coalesce(jsonb_object_agg(fr.feature_key, v_feat -> fr.canonical_key), '{}'::jsonb)
    into v_feat
    from public.feature_registry fr
   where fr.is_active and fr.canonical_key is not null
     and fr.canonical_key <> fr.feature_key
     and v_feat ? fr.canonical_key;

  -- CHANGE #657 — a container route is viewable when its own feature grants
  -- View OR when any tab of the screen it opens does. Without this, a partner
  -- holding write on all six fulfilment stages saw no Fulfil tab at all,
  -- because the stages are partner.* and the door is admin.fulfillment.
  -- The OR only ever OPENS a container; it never grants what is inside it,
  -- which each tab's own flag still answers for.
  select coalesce(jsonb_object_agg(fr.route_key, jsonb_build_object(
           'feature', coalesce(fr.canonical_key, fr.feature_key),
           'label',   fr.label,
           'v', coalesce((v_feat -> coalesce(fr.canonical_key, fr.feature_key) ->> 'v')::boolean, false)
                or coalesce(tv.any_tab_view, false),
           'w', coalesce((v_feat -> coalesce(fr.canonical_key, fr.feature_key) ->> 'w')::boolean, false))),
         '{}'::jsonb)
    into v_routes
    from public.feature_registry fr
    left join lateral (
      select bool_or(coalesce((v_feat -> public._feature_canon(st.feature_key) ->> 'v')::boolean, false))
               as any_tab_view
        from public.partner_screen_tab st
       where st.screen = fr.tab_screen
    ) tv on fr.tab_screen is not null
   where fr.is_active and coalesce(fr.route_key,'') <> '';

  -- CHANGE #657 — `index` is partner_screen_tab.tab_index. AdminFulfillmentScreen
  -- is addressed by tab NUMBER, and the number must travel with the grant: a
  -- client that inferred it from list position would silently re-map every
  -- grant the day a tab moved.
  select coalesce(jsonb_object_agg(t.screen, t.items), '{}'::jsonb) into v_tabs from (
    select st.screen, jsonb_agg(jsonb_build_object(
             'tab_key', st.tab_key, 'label', st.label, 'feature', st.feature_key,
             'index', st.tab_index,
             'v', coalesce((v_feat -> public._feature_canon(st.feature_key) ->> 'v')::boolean, false),
             'w', coalesce((v_feat -> public._feature_canon(st.feature_key) ->> 'w')::boolean, false))
           order by st.sort_order, st.tab_index) items
      from public.partner_screen_tab st group by st.screen) t;

  select z.name into v_zone from public.zones z where z.id = (s->>'zone_id')::smallint;

  return jsonb_build_object(
    'ok', true,
    'role',            s->>'role',
    'is_super',        (s->>'is_super')::boolean,
    'zone_locked',     (s->>'zone_locked')::boolean,
    'zone_id',         s->'zone_id',
    'zone_label',      coalesce(v_zone,''),
    'features',        v_feat,
    'routes',          v_routes,
    'tabs',            v_tabs,
    'denied_view_message',  public._c('access.denied_view'),
    'denied_write_message', public._c('access.denied_write'),
    'readonly_badge',       public._c('access.readonly_badge'));
end
$fn$;
