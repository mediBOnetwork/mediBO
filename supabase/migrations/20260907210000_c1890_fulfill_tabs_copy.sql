-- CHANGE #1890 — Fulfill tabs: readiness layout, one Automation strip, a map
-- card that never blocks the scroll.
--
-- Frontend-shaped change, but every word it prints is a row here. The strip
-- under the tab bar renders `{label} · {state}`; the state words, the settings
-- sheet copy and the map card's hints are all ui_copy keys so the wording is
-- an UPDATE, never a deploy.
--
-- `do nothing` on conflict: admin_supplier.autoflow / .bundle already exist on
-- live with Om's wording. This migration adds keys, it never rewrites copy.

insert into public.ui_copy (key, value) values
  -- the strip itself
  ('admin_supplier.automation_title',      to_jsonb('Automation'::text)),
  ('admin_supplier.automation_pill',       to_jsonb('{label} · {state}'::text)),
  ('admin_supplier.automation_on',         to_jsonb('ON'::text)),
  ('admin_supplier.automation_off',        to_jsonb('OFF'::text)),
  ('admin_supplier.automation_hint',       to_jsonb('Tap to toggle · long-press for settings'::text)),
  ('admin_supplier.autoflow',              to_jsonb('AutoFlow'::text)),
  ('admin_supplier.bundle',                to_jsonb('Bundle'::text)),
  -- the long-press settings sheet
  ('admin_supplier.autoflow_settings',     to_jsonb('AutoFlow settings'::text)),
  ('admin_supplier.autoflow_settings_body',to_jsonb('When AutoFlow is on, inquiries and orders are sent to suppliers automatically as soon as they are ready. Turn it off to send every message by hand.'::text)),
  ('admin_supplier.bundle_settings',       to_jsonb('Bundle settings'::text)),
  ('admin_supplier.bundle_settings_body',  to_jsonb('Bundling asks the fewest suppliers that can cover the day''s items. Turn it off to ask every matching supplier.'::text)),
  ('admin_supplier.settings_close',        to_jsonb('Close'::text)),
  ('admin_supplier.re_optimize_bundles',   to_jsonb('Re-optimise bundles'::text)),
  -- the collapsed map card
  ('supplier_map_groups.expand_hint',      to_jsonb('Tap the map to expand'::text)),
  ('supplier_map_groups.collapse_hint',    to_jsonb('Tap the map to shrink it'::text))
on conflict (key) do nothing;
