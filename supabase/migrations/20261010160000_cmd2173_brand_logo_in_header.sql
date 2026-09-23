-- CMD #2173 — Header logo + wordmark come from the backend, not an app asset.
--
-- The header already reads ONE payload: ui_boot().design.header (-> Ds.header).
-- This migration hangs the brand lock-up off that same block as
-- design.header.logo, read live from app_settings 'brand.logo', so changing a
-- URL, a colour, a letter or a word in app_settings changes the header on the
-- next reload with NO deploy.
--
-- Idempotent: safe to replay on live.

-- 1. The row itself — created only if it is missing (never clobbers live).
insert into public.app_settings (key, value)
values ('brand.logo', jsonb_build_object(
  'tile_url', '', 'wordmark_url', '', 'letter', 'm',
  'tile_bg', '#1B8A3E', 'tile_fg', '#FFFFFF',
  'word_1', 'medi', 'word_1_fg', '#1B7A43',
  'word_2', 'BO',   'word_2_fg', '#2FA24F'))
on conflict (key) do nothing;

-- 2. Every key the header needs exists, whatever the row already held.
update public.app_settings
   set value = jsonb_build_object(
                 'tile_url', '', 'wordmark_url', '', 'letter', 'm',
                 'tile_bg', '#1B8A3E', 'tile_fg', '#FFFFFF',
                 'word_1', 'medi', 'word_1_fg', '#1B7A43',
                 'word_2', 'BO',   'word_2_fg', '#2FA24F') || value,
       updated_at = now()
 where key = 'brand.logo';

-- 3. The official logo file, uploaded to the public app-assets bucket.
--    Only filled in when it is still blank — an admin's own URL always wins.
update public.app_settings
   set value = jsonb_set(value, '{tile_url}', to_jsonb(
         'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/brand/medibo-logo-512.png'::text)),
       updated_at = now()
 where key = 'brand.logo'
   and coalesce(value->>'tile_url', '') = '';

-- 4. ui_design_get() — the SAME payload, with the lock-up merged into header.
--    Read at call time, so an app_settings UPDATE is live on the next boot.
create or replace function public.ui_design_get()
returns jsonb
language sql
security definer
set search_path to 'public'
as $$
  select jsonb_set(
           d,
           '{header}',
           coalesce(d->'header', '{}'::jsonb)
             || jsonb_build_object('logo', l),
           true)
  from (
    select coalesce((select value from dev_runner_config where key = 'ui_design'), '{}'::jsonb) as d,
           coalesce((select value from app_settings     where key = 'brand.logo'), '{}'::jsonb) as l
  ) s
$$;

grant execute on function public.ui_design_get() to anon, authenticated, service_role;
