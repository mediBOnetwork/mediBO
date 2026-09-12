-- CHANGE #460 / gap 161 — the way IN.
-- A metric nobody can open is not a metric (§11). This registers Catalogue
-- health beside Trade price coverage in the Catalogue & Pricing group, so it
-- arrives on the dashboard through nav_registry() like every other feature.
insert into public.ui_icon (icon_key, label) values ('image', 'Picture')
on conflict (icon_key) do nothing;

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed, description)
values
  ('admin.catalogue_health', 'Catalogue health', 'Catalogue & Pricing', 'image',
   'catalogue_health', 526, 'medibo', false, 'none', true, 'catalogue', 'dashboard',
   array['admin','super_admin'],
   'CHANGE #460 / feature_gaps 161 - image and classification coverage, and the queue mirroring hotlinked 1mg CDN images into our own bucket')
on conflict (feature_key) do nothing;
