-- CMD #2056 — Routes leaves the Customers chip row and arrives on the
-- Dashboard as THREE doors in FIELD & GROWTH: Route builder, Assign route,
-- Today's visits.
--
-- Nothing about the Routes screen itself changes. The three tiles open the
-- SAME sub-tab that the chip opened; what they add is WHICH SECTION of it the
-- screen lands on, carried in `tab_screen` as `routes:<section>`. The section
-- keys are the ones `routes_today().links[]` already speaks (`today`,
-- `all_plans`, `my_route`) plus `past_plans`, the collapsible the assignment
-- flow lives in — so moving a door, or adding a fourth, stays an UPDATE.
--
-- The old `admin.cust_tab.routes` row is NOT deleted: it is the canonical
-- feature that grants the sub-tab (partner_screen_tab.customer/routes points
-- at it, and the three new rows inherit it through `canonical_key`). It only
-- stops being a TILE — `dashboard_section` is cleared.
--
-- Tile wording comes from ui_copy (`feature_registry.label_key`), so renaming
-- a door is an UPDATE to one row of copy and no deploy. `label` keeps the same
-- text as a fallback for the surfaces that read the registry directly
-- (palette, search, the access map).

-- ── 1. A registry row may now name its copy key ─────────────────────────────
alter table public.feature_registry
  add column if not exists label_key text not null default '';

comment on column public.feature_registry.label_key is
  'ui_copy key for this door''s label. Empty = use dashboard_label/label.';

-- ── 2. The copy ─────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('dashboard_field.route_builder',  '"Route builder"'::jsonb),
  ('dashboard_field.assign_route',   '"Assign route"'::jsonb),
  ('dashboard_field.todays_visits',  '"Today''s visits"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 3. The three doors ──────────────────────────────────────────────────────
insert into public.feature_registry
  (feature_key, label, label_key, dashboard_label, group_label, icon_key,
   route_key, sort_order, category, surface, tab_screen, canonical_key,
   roles_allowed, partner_eligible, default_access, dashboard_section,
   badge_tone, deep_link, description, search_terms, test_entry, test_roles,
   is_active)
values
  ('admin.cust_tab.routes_builder', 'Route builder', 'dashboard_field.route_builder',
   '', 'Customers', 'build', 'cust_routes_builder', 170, 'home_customers',
   'customer_tab', 'routes:all_plans', 'admin.cust_tab.routes',
   array['admin','super_admin'], true, 'none', 'field_growth', 'info', '', '',
   'routes route builder build plan', '/admin/go/cust_routes', array['admin','super_admin'], true),
  ('admin.cust_tab.routes_assign', 'Assign route', 'dashboard_field.assign_route',
   '', 'Customers', 'person_add', 'cust_routes_assign', 171, 'home_customers',
   'customer_tab', 'routes:past_plans', 'admin.cust_tab.routes',
   array['admin','super_admin'], true, 'none', 'field_growth', 'info', '', '',
   'routes assign worker plan', '/admin/go/cust_routes', array['admin','super_admin'], true),
  ('admin.cust_tab.routes_today', 'Today''s visits', 'dashboard_field.todays_visits',
   '', 'Customers', 'map', 'cust_routes_today', 172, 'home_customers',
   'customer_tab', 'routes:today', 'admin.cust_tab.routes',
   array['admin','super_admin'], true, 'none', 'field_growth', 'info', '', '',
   'routes today visits live on the road', '/admin/go/cust_routes', array['admin','super_admin'], true)
on conflict (feature_key) do update set
  label             = excluded.label,
  label_key         = excluded.label_key,
  dashboard_label   = excluded.dashboard_label,
  group_label       = excluded.group_label,
  icon_key          = excluded.icon_key,
  route_key         = excluded.route_key,
  sort_order        = excluded.sort_order,
  category          = excluded.category,
  surface           = excluded.surface,
  tab_screen        = excluded.tab_screen,
  canonical_key     = excluded.canonical_key,
  roles_allowed     = excluded.roles_allowed,
  partner_eligible  = excluded.partner_eligible,
  dashboard_section = excluded.dashboard_section,
  search_terms      = excluded.search_terms,
  test_entry        = excluded.test_entry,
  test_roles        = excluded.test_roles,
  is_active         = true;

-- ── 4. The old single tile stops being a tile (the feature itself stays) ─────
update public.feature_registry
   set dashboard_section = null
 where feature_key = 'admin.cust_tab.routes';

-- ── 5. A tile's label may come from ui_copy ─────────────────────────────────
create or replace function public._dashboard_tiles(p_all boolean default false)
 returns table(feature_key text, label text, icon_key text, route_key text,
               sort_order integer, category text, surface text,
               badge_source text, badge_noun text, badge_tone text,
               deep_link text, description text, dashboard_section text,
               tab_screen text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with me as (
    select coalesce(public.get_my_role(),'none') as role,
           public.my_partner_id() as partner,
           exists (select 1 from public.admins a
                    where a.id::text = public.my_admin_id()::text
                      and coalesce(a.is_super,false)) as is_super
  ), acc as (select * from public._staff_access())
  select f.feature_key,
         -- CMD #2056 — copy first: a door renamed in ui_copy renames itself.
         coalesce(nullif(public._c(f.label_key),''),
                  nullif(f.dashboard_label,''), f.label) as label,
         f.icon_key, f.route_key, f.sort_order,
         f.category, f.surface, f.badge_source, f.badge_noun, f.badge_tone,
         f.deep_link, f.description, f.dashboard_section, f.tab_screen
    from public.feature_registry f
    cross join me
    left join acc on acc.feature_key = coalesce(nullif(f.canonical_key,''), f.feature_key)
   where f.is_active
     and (p_all or coalesce(f.dashboard_section,'') <> '')
     and coalesce(f.route_key,'') <> ''
     and case when me.partner is not null
              then f.partner_eligible and coalesce(acc.level,'none') <> 'none'
              when f.surface = 'dev_tools' then me.role = 'super_admin' and me.role = any (f.roles_allowed)
              else me.role = any (f.roles_allowed)
                   and (me.is_super or coalesce(acc.level,'none') <> 'none') end
$function$;
