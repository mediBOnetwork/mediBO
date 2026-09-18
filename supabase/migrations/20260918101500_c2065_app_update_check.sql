-- CMD #2065 — ONE truthful update bar for web, PWA and Android.
--
-- THE LIE THIS ENDS
-- `app_update_bar()` decided Android from `app_published_release('android')`:
-- a row in OUR database. The moment a web deploy (or a Play upload still in
-- review) moved that row ahead of what Play actually serves, every Android
-- customer got "App update available" and a button that could do nothing —
-- Play has nothing to install, so the in-app flow returns immediately and the
-- bar just sits there. A bar that cannot be acted on is worse than no bar.
--
-- THE RULE
-- Android's truth is PLAY'S, and only Play knows it: the client asks the In-App
-- Update API on launch and on resume and reports the verdict here. This
-- function NEVER compares an Android install against the web build, and never
-- against app_releases, to decide `show`. app_releases is still read — but only
-- to NAME the target version and to pick the flow once Play has already said
-- there is an update.
--
-- Web is version.json (the tab's build vs the build the CDN serves now), PWA is
-- the service worker (a new worker sitting in `waiting`). Three platforms, three
-- questions, ONE payload and ONE bar.
--
-- Idempotent: safe to replay on live.

begin;

-- ── 1. The bar's words. Every string the bar prints is a row here. ─────────
insert into public.ui_copy (key, value) values
  ('app_update_bar.label',      '"App update available"'::jsonb),
  ('app_update_bar.button',     '"Update Now"'::jsonb),
  ('app_update_bar.updating',   '"Updating…"'::jsonb),
  ('app_update_bar.downloaded', '"Restarting mediBO…"'::jsonb),
  ('app_update_bar.dismiss',    '"Later"'::jsonb)
on conflict (key) do nothing;

-- ── 2. Config. dismiss_hours and force_update are new; the rest already
--       existed and are left exactly as an admin set them. ─────────────────
insert into public.app_settings (key, value)
values ('app_update_bar', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings
   set value = value
             || jsonb_build_object(
                  'dismiss_hours', coalesce(value->'dismiss_hours', to_jsonb(24)),
                  'force_update',  coalesce(value->'force_update',  to_jsonb(false)),
                  'pwa_enabled',   coalesce(value->'pwa_enabled',   to_jsonb(true)))
 where key = 'app_update_bar';

-- ── 3. The old check goes. It answered a different question (which APK to
--       download, from which install source) for the #282 dialog that this
--       command deletes, and leaving it behind would make every call by name
--       ambiguous the moment the new one lands. ─────────────────────────────
drop function if exists public.app_update_check(text, integer, text);

-- ── 4. The one check. ──────────────────────────────────────────────────────
create or replace function public.app_update_check(
  p_platform           text        default 'web',
  p_installed_version  text        default null,
  p_live_version       text        default null,
  p_platform_state     text        default null,
  p_platform_version   text        default null,
  p_dismissed_at       timestamptz default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_cfg     jsonb := coalesce((select value from app_settings where key = 'app_update_bar'), '{}'::jsonb);
  v_chan    jsonb := coalesce((select value from app_settings where key = 'app_update_channel'), '{}'::jsonb);
  v_plat    text  := lower(coalesce(nullif(btrim(coalesce(p_platform, '')), ''), 'web'));
  v_state   text  := lower(coalesce(nullif(btrim(coalesce(p_platform_state, '')), ''), 'unknown'));
  v_on      bool  := coalesce((v_cfg->>'enabled')::boolean, true);
  v_poll    int   := greatest(30, coalesce((v_cfg->>'poll_seconds')::int, 300));
  v_min     int   := coalesce((v_cfg->>'min_version_code')::int, 0);
  v_hours   int   := greatest(0, coalesce((v_cfg->>'dismiss_hours')::int, 24));
  v_show    bool  := false;
  v_forced  bool  := coalesce((v_cfg->>'force_update')::boolean, false);
  v_action  text  := 'none';
  v_flow    text  := 'reload';
  v_reason  text  := 'no_update';
  v_target  text  := null;
  v_url     text  := null;
  v_code    int   := nullif(regexp_replace(coalesce(p_installed_version, ''), '\D', '', 'g'), '')::int;
  v_boot    text  := nullif(btrim(coalesce(p_installed_version, '')), '');
  v_live    text  := nullif(btrim(coalesce(p_live_version, '')), '');
  r         app_releases%rowtype;
begin
  if v_plat not in ('android', 'web', 'pwa') then
    v_plat := 'web';
  end if;

  if not v_on then
    v_reason := 'disabled';
  elsif v_plat = 'android' then
    v_action := 'play_in_app_update';
    if not coalesce((v_cfg->>'android_enabled')::boolean, true) then
      v_reason := 'disabled';
    -- THE WHOLE POINT OF THIS COMMAND. Play said so, or there is no bar.
    -- 'unknown' (the API could not be reached, a sideloaded build, no Play
    -- Store) is NOT an update: silence beats a button that does nothing.
    elsif v_state <> 'update_available' then
      v_reason := case v_state
                    when 'in_progress' then 'play_update_in_progress'
                    when 'none'        then 'play_says_up_to_date'
                    else 'play_unknown'
                  end;
    else
      v_show   := true;
      v_reason := 'play_update_available';
      -- app_releases NAMES the build; it never decides that there is one.
      r := public.app_published_release('android');
      v_target := coalesce(
        nullif(btrim(coalesce(p_platform_version, '')), ''),
        r.version_name);
      v_url := coalesce(nullif(btrim(coalesce(v_chan->>'play_url', '')), ''),
                        nullif(btrim(coalesce(r.apk_url, '')), ''));
      -- Too old to keep taking orders → Play's blocking flow, and no way out.
      if v_min > 0 and coalesce(v_code, 0) > 0 and v_code < v_min then
        v_forced := true;
      end if;
      v_flow := case when v_forced then 'immediate' else 'flexible' end;
    end if;
  elsif v_plat = 'pwa' then
    v_action := 'sw_skip_waiting';
    v_flow   := 'sw_skip_waiting';
    if not coalesce((v_cfg->>'pwa_enabled')::boolean, true) then
      v_reason := 'disabled';
    elsif v_state <> 'waiting' then
      v_reason := 'no_waiting_worker';
    else
      v_show   := true;
      v_reason := 'waiting_worker';
      v_target := v_live;
    end if;
  else
    v_action := 'reload';
    v_flow   := 'reload';
    if not coalesce((v_cfg->>'web_enabled')::boolean, true) then
      v_reason := 'disabled';
    -- Both strings must be real. A failed fetch is not a new build.
    elsif v_boot is null or v_live is null
       or v_boot = 'unknown' or v_live = 'unknown' then
      v_reason := 'unknown_build';
    elsif v_boot = v_live then
      v_reason := 'same_build';
    else
      v_show   := true;
      v_reason := 'newer_web_build';
      v_target := v_live;
    end if;
  end if;

  -- ── Dismissal. Per platform, because the device stores it per platform and
  --    sends it back; a forced update ignores it entirely. ─────────────────
  if v_show and not v_forced and v_hours > 0
     and p_dismissed_at is not null
     and p_dismissed_at > now() - make_interval(hours => v_hours) then
    v_show   := false;
    v_reason := 'dismissed';
  end if;

  return jsonb_build_object(
    'show',             v_show,
    'platform',         v_plat,
    'reason',           v_reason,
    'title',            _c('app_update_bar.label'),
    'cta',              _c('app_update_bar.button'),
    'action',           case when v_show then v_action else 'none' end,
    'updating_label',   _c('app_update_bar.updating'),
    'downloaded_label', _c('app_update_bar.downloaded'),
    'dismiss_label',    case when v_forced then null else _c('app_update_bar.dismiss') end,
    'dismissible',      (v_show and not v_forced),
    'forced',           v_forced,
    'dismiss_hours',    v_hours,
    'flow',             v_flow,
    'poll_seconds',     v_poll,
    'min_version_code', v_min,
    'installed_version', v_boot,
    'target_version',   v_target,
    'action_url',       v_url
  );
end $function$;

grant execute on function public.app_update_check(text, text, text, text, text, timestamptz)
  to anon, authenticated, service_role;

-- ── 5. app_update_bar() stays, as a thin alias. Every bundle already in a
--       customer's browser calls it by that name and will keep calling it
--       until it reloads; it must answer with the SAME truth, not the old one.
create or replace function public.app_update_bar(
  p_platform      text    default 'web',
  p_version_code  integer default 0,
  p_build         text    default null,
  p_live_build    text    default null
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- An old bundle cannot report Play's verdict (it never asked), so Android
  -- gets 'unknown' here — which is exactly the answer that keeps the bar off
  -- a phone Play has nothing for. The web half is unchanged.
  select public.app_update_check(
           p_platform,
           case when lower(coalesce(p_platform, 'web')) = 'android'
                then nullif(coalesce(p_version_code, 0), 0)::text
                else p_build end,
           p_live_build,
           null, null, null)
      || jsonb_build_object(
           'label',        _c('app_update_bar.label'),
           'button_label', _c('app_update_bar.button'),
           'bottom_gap',   coalesce((select (value->>'bottom_gap')::numeric
                                       from app_settings where key = 'app_update_bar'), 128));
$function$;

grant execute on function public.app_update_bar(text, integer, text, text)
  to anon, authenticated, service_role;

commit;
