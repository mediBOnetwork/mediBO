-- CHANGE #639 — the Triage tool's registry row.
--
-- This one lives on the CONTROL PLANE (medibo-dev), not in supabase/migrations/,
-- because `dev_tools()` — the payload the tools sheet renders — reads
-- feature_registry THERE. A row added to production's copy would never appear.
-- Applied with the service role; idempotent, so re-running is safe.
INSERT INTO public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key,
   sort_order, owner, partner_eligible, default_access, is_active, category,
   surface, roles_allowed, deep_link, search_terms, badge_source, badge_noun)
VALUES
  ('devtool.triage', 'Triage',
   'Approve what the bots found — fixes generate themselves',
   'Proof & QA', 'fact_check', 'triage',
   15, 'medibo', false, 'none', true, 'more_system', 'dev_tools',
   array['super_admin'], null,
   'triage inbox findings approve reject bot fix reopen trend coverage', null, null)
ON CONFLICT (feature_key) DO UPDATE
  SET label        = EXCLUDED.label,
      description  = EXCLUDED.description,
      group_label  = EXCLUDED.group_label,
      icon_key     = EXCLUDED.icon_key,
      route_key    = EXCLUDED.route_key,
      sort_order   = EXCLUDED.sort_order,
      surface      = EXCLUDED.surface,
      is_active    = true,
      roles_allowed= EXCLUDED.roles_allowed,
      search_terms = EXCLUDED.search_terms;
