-- CMD #2193 — ONE MARK, AND NOTHING BEFORE IT.
--
-- Om, on the 1.3.35 APK: "the splash shows an old logo for about a second,
-- then swaps to the real one", and "the header logo changed shape between
-- loading and loaded".
--
-- Both are the same bug wearing two coats: the app drew a mark of its OWN
-- while the real one was still in flight. The Android launch screen drew the
-- bundled @mipmap/ic_launcher, the web splash drew a typed "mediBO", and the
-- header drew a green rounded square with a letter in it at 40 dp until
-- shell_style() landed and moved it to 49. Three different marks before the
-- one real mark.
--
-- brand.logo already says so in its own words (tile_note, live since #2173):
--   "ONE logo only: tile_url is the single source. Never add a letter/drawn
--    fallback — it renders a different mark."
-- This migration gives that row the last two numbers it was missing — the
-- tile's SIZE and its RADIUS — so the placeholder box and the loaded image are
-- the same box, and adds brand_boot(), the one anon-callable read the HTML
-- splash makes before it draws anything at all.
--
-- Idempotent: safe to replay on live.

-- ── 1. brand.logo carries the geometry, not just the artwork ────────────────
-- 49 = 32 dp of visible green (the PNG is 65.2% artwork), 11 is the corner the
-- header has used since #2187. Seeded only where the key is absent, so an
-- admin's own tuning always wins.
insert into public.app_settings (key, value)
values ('brand.logo', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings
   set value = jsonb_build_object(
                 'size',      49,
                 'radius',    11,
                 'splash_bg', '#F5F6F8',
                 'geom_note', 'size + radius are the ONE box the mark lives in: '
                              || 'the empty placeholder and the loaded image are '
                              || 'drawn at exactly these, so nothing changes shape.')
               || value,
       updated_at = now()
 where key = 'brand.logo';

-- The header row's old copies point at the row that now owns them. #2187 tuned
-- the logo through shell.style; since #2193 the lock-up reads brand.logo, so
-- these two keys are left in place for an old client and marked as mirrors.
update public.app_settings
   set value = value || jsonb_build_object(
                 'header',
                 coalesce(value->'header', '{}'::jsonb)
                   || jsonb_build_object(
                        'logo_size',   coalesce((select (value->>'size')::numeric
                                                   from public.app_settings where key='brand.logo'), 49),
                        'logo_radius', coalesce((select (value->>'radius')::numeric
                                                   from public.app_settings where key='brand.logo'), 11),
                        'logo_owner',  'brand.logo (CMD #2193) — edit size/radius THERE')),
       updated_at = now()
 where key = 'shell.style';

-- ── 2. brand_boot() — what the splash asks before it draws anything ─────────
-- The HTML splash paints NOTHING until this answers and the image it names has
-- decoded. No typed wordmark, no bundled icon, no drawn fallback: one mark, or
-- an empty screen on the backend's own background colour.
create or replace function public.brand_boot()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
           'tile_url', coalesce(l->>'tile_url', ''),
           'size',     coalesce((l->>'size')::numeric, 49),
           'radius',   coalesce((l->>'radius')::numeric, 11),
           'bg',       coalesce(l->>'splash_bg', '#F5F6F8'),
           'alt',      coalesce(l->>'word_1', '') || coalesce(l->>'word_2', ''))
  from (select coalesce((select value from public.app_settings where key = 'brand.logo'),
                        '{}'::jsonb) as l) s
$$;

grant execute on function public.brand_boot() to anon, authenticated, service_role;

comment on function public.brand_boot() is
  'CMD #2193 — the splash''s one read. Returns the single mark plus the box it '
  'is drawn in. Anon-callable because it runs before any session exists.';

-- ── 3. A branch that never ran #2173 still has the one mark ────────────────
-- Same guard #2173 used: only ever filled in when it is still blank, so an
-- admin's own upload is never clobbered. On live this is already set and this
-- statement touches nothing; on a fresh build branch it is what makes the
-- preview render the real logo instead of an empty box.
update public.app_settings
   set value = value
             || jsonb_build_object(
                  'tile_url', 'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/brand/medibo-logo-512.png',
                  'letter',   'm',
                  'tile_bg',  '#1B8A3E',
                  'tile_fg',  '#FFFFFF',
                  'word_1',   'medi', 'word_1_fg', '#1B7A43',
                  'word_2',   'BO',   'word_2_fg', '#2FA24F'),
       updated_at = now()
 where key = 'brand.logo'
   and coalesce(value->>'tile_url', '') = '';
