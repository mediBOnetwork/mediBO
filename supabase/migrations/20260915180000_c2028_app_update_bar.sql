-- CMD #2028 — the persistent app-update pill (Android + web).
--
-- One RPC answers the whole bar for both platforms, so the phone and the
-- browser render the SAME decision from the SAME place:
--   • Android — the running versionCode vs the release Play has actually
--     published and rolled out (app_published_release). Below the configured
--     minimum the flow is 'immediate' (Play's blocking flow), otherwise
--     'flexible'.
--   • Web — the build the tab booted on vs the build version.json serves now.
--     The browser cannot be asked from here (version.json lives on the CDN),
--     so the tab REPORTS both strings and the backend decides; the comparison
--     is never a client-side rule.
--
-- Every string, the poll interval and the minimum version come from
-- ui_copy / app_settings, so wording and thresholds change with an UPDATE.

-- ── strings ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('app_update_bar.label',    '"App update available"'::jsonb),
  ('app_update_bar.button',   '"Update Now"'::jsonb),
  ('app_update_bar.updating', '"Updating…"'::jsonb),
  ('app_update_bar.downloaded','"Restarting…"'::jsonb)
on conflict (key) do nothing;

-- CMD #2028 rewords the bar: the #286 copy said "New update available" /
-- "Update". The spec's wording is the one Om approved, and it is an UPDATE.
update public.ui_copy set value = '"App update available"'::jsonb, updated_at = now()
  where key = 'update_bar.title'  and value #>> '{}' = 'New update available';
update public.ui_copy set value = '"Update Now"'::jsonb, updated_at = now()
  where key = 'update_bar.action' and value #>> '{}' = 'Update';

-- ── config ─────────────────────────────────────────────────────────────────
-- min_version_code: a build below this is too old to keep running, so Android
-- gets Play's IMMEDIATE (blocking) flow instead of the flexible download.
insert into public.app_settings (key, value) values
  ('app_update_bar', jsonb_build_object(
     'enabled',          true,
     'android_enabled',  true,
     'web_enabled',      true,
     'poll_seconds',     300,
     'min_version_code', 0,
     -- How far off the bottom of the screen the pill floats: clear of the
     -- bottom nav AND of the floating cart pill. A number, not a layout rule,
     -- so a nav-height change is an UPDATE.
     'bottom_gap',       128,
     'icon',             'settings'))
on conflict (key) do nothing;

-- Idempotent merge: a row that already exists gains any key added later
-- WITHOUT losing what an admin has tuned.
update public.app_settings s
   set value = jsonb_build_object(
         'enabled', true, 'android_enabled', true, 'web_enabled', true,
         'poll_seconds', 300, 'min_version_code', 0,
         'bottom_gap', 128, 'icon', 'settings') || s.value,
       updated_at = now()
 where s.key = 'app_update_bar';

-- ── the bar ────────────────────────────────────────────────────────────────
create or replace function public.app_update_bar(
  p_platform     text    default 'web',
  p_version_code integer default 0,
  p_build        text    default null,
  p_live_build   text    default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_cfg    jsonb := coalesce((select value from app_settings where key = 'app_update_bar'), '{}'::jsonb);
  v_plat   text  := lower(coalesce(nullif(btrim(coalesce(p_platform,'')), ''), 'web'));
  v_poll   int   := greatest(30, coalesce((v_cfg->>'poll_seconds')::int, 300));
  v_min    int   := coalesce((v_cfg->>'min_version_code')::int, 0);
  v_on     bool  := coalesce((v_cfg->>'enabled')::boolean, true);
  v_show   bool  := false;
  v_flow   text  := 'reload';
  r        app_releases%rowtype;
  v_chan   jsonb := coalesce((select value from app_settings where key = 'app_update_channel'), '{}'::jsonb);
  v_url    text;
  v_boot   text  := nullif(btrim(coalesce(p_build, '')), '');
  v_live   text  := nullif(btrim(coalesce(p_live_build, '')), '');
  v_target text  := null;
  v_code   int   := null;
begin
  if v_plat not in ('android', 'web') then
    v_plat := 'web';
  end if;

  if v_on then
    if v_plat = 'android' and coalesce((v_cfg->>'android_enabled')::boolean, true) then
      r := public.app_published_release('android');
      if r.id is not null and coalesce(p_version_code, 0) < r.version_code then
        v_show   := true;
        v_code   := r.version_code;
        v_target := r.version_name;
        -- Too old to keep running → Play's blocking flow.
        v_flow   := case when coalesce(p_version_code, 0) < v_min
                         then 'immediate' else 'flexible' end;
        -- Fallback destination when Play cannot run the in-app flow
        -- (sideloaded build, no Play Store, Play outage).
        v_url    := coalesce(nullif(btrim(coalesce(v_chan->>'play_url','')), ''),
                             nullif(btrim(coalesce(r.apk_url,'')), ''));
      end if;
    elsif v_plat = 'web' and coalesce((v_cfg->>'web_enabled')::boolean, true) then
      -- Both strings must be real; a failed fetch is NOT a new build.
      if v_boot is not null and v_live is not null
         and v_boot <> 'unknown' and v_live <> 'unknown'
         and v_boot <> v_live then
        v_show   := true;
        v_flow   := 'reload';
        v_target := v_live;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'show',             v_show,
    'platform',         v_plat,
    'label',            _c('app_update_bar.label'),
    'button_label',     _c('app_update_bar.button'),
    'updating_label',   _c('app_update_bar.updating'),
    'downloaded_label', _c('app_update_bar.downloaded'),
    'bottom_gap',       coalesce((v_cfg->>'bottom_gap')::numeric, 128),
    'icon',             coalesce(nullif(btrim(coalesce(v_cfg->>'icon','')), ''), 'settings'),
    'flow',             v_flow,
    'poll_seconds',     v_poll,
    'min_version_code', v_min,
    'installed_code',   coalesce(p_version_code, 0),
    'target_code',      v_code,
    'target_build',     v_target,
    'action_url',       v_url
  );
end $function$;

revoke all on function public.app_update_bar(text, integer, text, text) from public;
grant execute on function public.app_update_bar(text, integer, text, text)
  to anon, authenticated, service_role;

comment on function public.app_update_bar(text, integer, text, text) is
  'CMD #2028 — the floating update pill. Decides show/flow and supplies every string for Android (Play in-app updates) and web (version.json).';
