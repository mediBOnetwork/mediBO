-- CHANGE #1890 — Fulfill tabs: the SEND-ALL READINESS layout, ONE Automation
-- strip, and a map card that never blocks the scroll.
--
-- The change is frontend-shaped, but every word it prints is a row here. The
-- strip under the tab bar renders `{label} · {state}` from the chip payload
-- supplier_toggle_chips() already sends; the wrapper word, the join, the
-- long-press hint, the settings sheet and the map card's hints are ui_copy, so
-- re-wording any of them is an UPDATE and never a deploy.
--
-- The settings sheet keys are addressed by the CHIP'S OWN backend key
-- (`admin_supplier.settings_<chip.key>_title` / `_body`), so Dart looks the
-- copy up mechanically instead of branching on which toggle it is. A new
-- toggle is two INSERTs here and no Dart at all.
--
-- `on conflict do nothing`: admin_supplier.autoflow / .bundle /
-- .re_optimize_bundles already carry Om's wording on live. This migration adds
-- keys, it never rewrites copy.

insert into public.ui_copy (key, value) values
  -- the strip itself
  ('admin_supplier.automation_title', to_jsonb('Automation'::text)),
  ('admin_supplier.automation_pill',  to_jsonb('{label} · {state}'::text)),
  ('admin_supplier.automation_hint',  to_jsonb('Tap to switch · hold for settings'::text)),
  -- the long-press settings sheet, one pair per chip key
  ('admin_supplier.settings_auto_meta_title', to_jsonb('AutoFlow · Supplier inquiry'::text)),
  ('admin_supplier.settings_auto_meta_body',
     to_jsonb('On: the day''s inquiry goes out to every ready supplier by itself, as soon as the readiness checks pass. Off: nothing leaves until you send it.'::text)),
  ('admin_supplier.settings_order_auto_meta_title', to_jsonb('AutoFlow · Supplier orders'::text)),
  ('admin_supplier.settings_order_auto_meta_body',
     to_jsonb('On: a confirmed supplier order is sent to the supplier automatically. Off: every order waits for you to press Send.'::text)),
  ('admin_supplier.settings_bundle_title', to_jsonb('Bundle'::text)),
  ('admin_supplier.settings_bundle_body',
     to_jsonb('On: the day''s items are asked from the fewest suppliers that can cover them. Off: every matching supplier is asked for every item.'::text)),
  ('admin_supplier.settings_close', to_jsonb('Close'::text)),
  -- the collapsed / expanded map card
  ('supplier_map_groups.expand_hint',   to_jsonb('Tap the map to open it'::text)),
  ('supplier_map_groups.collapse_hint', to_jsonb('Tap the arrow to shrink the map'::text))
on conflict (key) do nothing;
