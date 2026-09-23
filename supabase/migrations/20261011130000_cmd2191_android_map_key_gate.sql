-- CMD #2191 (Om, live on Android) — "the map is OpenStreetMap, and then the app
-- closes on the location screen".
--
-- WHAT ACTUALLY HAPPENED. `map_config.native_key_android` was filled in on live
-- at 09:42 today, so map_config_get('android') started answering
-- uses_google_js: true and the app built the NATIVE GoogleMap. The published
-- app (versionCode 54) has no `com.google.android.geo.API_KEY` in its
-- manifest — the key was only added to the tree afterwards (CMD #2185, never
-- released) — so the platform view threw
--   java.lang.IllegalStateException: API key not found
-- and took the process with it. crash_event 11931-11935 are those kills,
-- 17:52-18:03 IST, role delivery, platform android.
--
-- THE RULE. A key on the CONFIG is not a key in the APP. Only a build that
-- carries the manifest key may be sent down the native Google path, so the
-- config now names the first build that does, and the caller says which build
-- it is. An Android caller that cannot say (every app already installed) gets
-- the tile path: a map that is not Google is a disappointment, a map that kills
-- the process is a bug.
--
-- Once 55 is on Play and installed, that phone reports 55, clears the gate and
-- gets Google Maps — with no deploy and no further change here.
--
-- Idempotent: additive column, guarded update, one replaceable function.

alter table public.map_config
  add column if not exists native_key_android_min_build int;

comment on column public.map_config.native_key_android_min_build is
  'The first Android versionCode whose AndroidManifest carries com.google.android.geo.API_KEY. A caller below it (or one that does not report its build) is answered with the tile path, because the native Google map is a process kill without the manifest key. CMD #2191.';

-- CMD #2185 added the key to the manifest; the first build that can actually
-- ship it is the next one Play accepts, 55.
update public.map_config
   set native_key_android_min_build = 55
 where id = 1
   and native_key_android_min_build is distinct from 55;

drop function if exists public.map_config_get(text);

create or replace function public.map_config_get(
  p_platform  text default 'web',
  p_app_build int  default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  c        map_config%rowtype;
  v_plat   text := lower(coalesce(nullif(trim(p_platform), ''), 'web'));
  v_keyed  boolean;
  v_google boolean;
  v_min    int;
  v_gate   text := 'n/a';
begin
  select * into c from map_config where id = 1;

  -- Does THIS platform have a Google key at all? A platform with no key can
  -- never be sent down the Google path — on Android that is a process kill,
  -- not a broken map.
  v_keyed := case v_plat
               when 'web'     then coalesce(c.browser_key, '')        <> ''
               when 'android' then coalesce(c.native_key_android, '') <> ''
               when 'ios'     then coalesce(c.native_key_ios, '')     <> ''
               else false
             end;

  -- CMD #2191 — and does THIS BUILD carry the manifest key? A build that does
  -- not say which build it is is treated as an old one, always.
  if v_plat = 'android' and v_keyed then
    v_min := c.native_key_android_min_build;
    if v_min is not null then
      if p_app_build is null then
        v_keyed := false; v_gate := 'build_unknown';
      elsif p_app_build < v_min then
        v_keyed := false; v_gate := 'build_too_old';
      else
        v_gate := 'build_ok';
      end if;
    end if;
  end if;

  v_google := (coalesce(c.provider, '') = 'google') and v_keyed;

  return jsonb_build_object(
    'provider',        coalesce(c.provider, ''),
    'platform',        v_plat,
    'uses_google_js',  v_google,
    'browser_key',     case when v_google and v_plat = 'web' then coalesce(c.browser_key, '') else '' end,
    -- What the gate decided, so a phone on tiles can be SEEN to be on tiles
    -- because of its build rather than because the key went missing again.
    'key_gate',        v_gate,
    'app_build',       p_app_build,
    'min_build',       c.native_key_android_min_build,
    'tile_url',        coalesce(c.tile_url, ''),
    'tile_url_retina', coalesce(c.tile_url_retina, ''),
    -- Attribution follows the path actually rendered. Printing "© Google" over
    -- OpenStreetMap tiles is both wrong and a licence breach.
    'attribution',     case when v_google then coalesce(c.attribution, '')
                            else coalesce(c.tile_attribution, '') end,
    'max_zoom',        coalesce(c.max_zoom, 19),
    'default_center',  jsonb_build_object(
                         'lat', coalesce(c.default_lat, 0),
                         'lng', coalesce(c.default_lng, 0)),
    'default_zoom',    coalesce(c.default_zoom, 12),
    'empty_label',     coalesce(c.empty_label, ''),
    -- navigation always deep-links to the Google Maps APP, which needs no key
    -- and no billing; that is why it keeps working when tiles fail
    'nav_deeplink_template',   coalesce(c.nav_deeplink, ''),
    'point_deeplink_template', coalesce(c.point_deeplink, ''),
    'updated_at',      c.updated_at);
end $function$;

grant execute on function public.map_config_get(text, int) to anon, authenticated, service_role;
