-- CMD #2166 — the no-photo placeholder icon comes from the backend.
--
-- app_settings 'card.placeholder_icons' maps every kind card_placeholder_kind()
-- can return to a public SVG in the app-assets bucket. _product_card() already
-- reads it (placeholder.icon_url); this row is the map that was empty.
--
-- Changing a URL here changes the card on the next reload, with no deploy.
-- Idempotent: the row is replaced, never appended to.
insert into public.app_settings (key, value)
values ('card.placeholder_icons', jsonb_build_object(
  'strip',   'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/strip.svg',
  'bottle',  'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/bottle.svg',
  'vial',    'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/vial.svg',
  'jar',     'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/jar.svg',
  'drop',    'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/drop.svg',
  'carton',  'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/carton.svg',
  'syringe', 'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/syringe.svg',
  'sachet',  'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/sachet.svg',
  'tube',    'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/tube.svg',
  'inhaler', 'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/inhaler.svg'))
on conflict (key) do update set value = excluded.value, updated_at = now();
