-- CHANGE #282 — the in-app update prompt: right destination, plain words.
--
-- Two live faults this fixes.
--
-- 1. WRONG DESTINATION. The prompt's only action was `apk_url` — a Supabase
--    storage APK. mediBO is now on Google Play, so a Play-installed pharmacy
--    tapping it got Chrome's "this file might be harmful", then a signature
--    clash (Play re-signs with its own app-signing key, the storage APK carries
--    the upload key) that BLOCKS the install outright. Android already tells us
--    where the app came from — `getInstallSourceInfo().installingPackageName`,
--    surfaced on the in.medibo.app/signin_diag channel since #279. The client
--    now sends it, and THE BACKEND decides the destination: a Play install gets
--    the Play listing and `apk_url` is not even present in the payload; only a
--    genuine sideload is offered the APK.
--
-- 2. RAW DEVELOPER WORDING. `app_releases.notes` is the internal changelog and
--    it was rendered straight into the prompt — Om saw a pharmacy being told
--    about "the exact signing certificate this build carries and the client id
--    it sent". `notes` stays internal; the prompt reads `public_notes`, and
--    when that is empty it falls back to backend copy, never to `notes`. So the
--    dev sentence cannot leak again regardless of what a publisher types.
--
-- Every string and both URLs are rows, so rewording or repointing the prompt is
-- an UPDATE, not a deploy.

-- ── 1. plain, customer-facing notes live beside the internal ones ───────────
alter table public.app_releases add column if not exists public_notes text;

comment on column public.app_releases.notes is
  'INTERNAL changelog. Never rendered to a user — app_update_check reads public_notes.';
comment on column public.app_releases.public_notes is
  'Plain-language summary shown in the in-app update prompt. NULL => backend fallback copy.';

-- ── 2. install source -> channel, as data ──────────────────────────────────
create table if not exists public.app_install_source (
  source     text primary key,
  channel    text not null check (channel in ('play','direct')),
  label      text,
  updated_at timestamptz not null default now()
);

insert into public.app_install_source(source, channel, label) values
  ('com.android.vending',           'play',   'Google Play Store'),
  ('com.google.android.feedback',   'play',   'Google Play (legacy installer)'),
  ('com.android.packageinstaller',  'direct', 'Sideload — system package installer'),
  ('com.google.android.packageinstaller', 'direct', 'Sideload — system package installer'),
  ('sideload',                      'direct', 'Sideload — no installer named'),
  ('adb',                           'direct', 'Sideload — adb install')
on conflict (source) do nothing;

-- ── 3. destination config (one row, editable without a deploy) ─────────────
insert into public.app_settings(key, value) values (
  'app_update_channel',
  jsonb_build_object(
    'play_url',   'https://play.google.com/store/apps/details?id=in.medibo.app',
    'store_name', 'Google Play',
    -- Unknown installer => treat as Play. A Play user offered an APK is BROKEN
    -- (blocked install); a sideloader sent to Play merely sees a listing and can
    -- still install from there. The safe default is the one that never blocks.
    'unknown_is_play', true
  )
) on conflict (key) do nothing;

-- ── 4. copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('app_update.eyebrow',           to_jsonb('App update available'::text)),
  ('app_update.title',             to_jsonb('A new version of mediBO is ready'::text)),
  ('app_update.title_mandatory',   to_jsonb('Please update mediBO to continue'::text)),
  ('app_update.message_default',   to_jsonb('This update brings speed and stability improvements across the app.'::text)),
  ('app_update.message_mandatory', to_jsonb('This version is required to keep ordering. It only takes a moment.'::text)),
  ('app_update.version_label',     to_jsonb('Version %s'::text)),
  ('app_update.action_play',       to_jsonb('Update on Google Play'::text)),
  ('app_update.action_apk',        to_jsonb('Download update'::text)),
  ('app_update.dismiss',           to_jsonb('Not now'::text)),
  ('version_watcher.new_version_title', to_jsonb('App update available'::text))
on conflict (key) do update set value = excluded.value;

-- The web strip's sub-line, reworded to match the sheet. It already existed, so
-- this is a deliberate overwrite rather than an insert.
update public.ui_copy
   set value = to_jsonb('A newer version is loading — this takes a second.'::text)
 where key = 'version_watcher.new_version_banner';

-- ── 5. plain notes for the releases that already exist ─────────────────────
update public.app_releases set public_notes =
  'Google sign-in now works reliably, plus speed and stability fixes.'
 where platform = 'android' and version_code in (22, 23, 24) and public_notes is null;

update public.app_releases set public_notes =
  'Refreshed design, faster screens, and small fixes.'
 where platform = 'android' and version_code = 20 and public_notes is null;

-- ── 6. the check itself ────────────────────────────────────────────────────
-- The 2-arg form must GO, not sit alongside: PostgREST resolves by named
-- arguments, and an old client posting {p_platform, p_version_code} would match
-- both the 2-arg function and the 3-arg one whose third argument defaults —
-- "function is not unique". Dropping it keeps exactly one candidate, and old
-- builds in the field keep working because the new third argument defaults.
drop function if exists public.app_update_check(text, integer);

create or replace function public.app_update_check(
  p_platform       text    default 'android',
  p_version_code   integer default 0,
  p_install_source text    default null
) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $function$
declare
  r          app_releases%rowtype;
  v_cfg      jsonb;
  v_channel  text;
  v_url      text;
  v_action   text;
  v_title    text;
  v_message  text;
  v_src      text := nullif(btrim(coalesce(p_install_source, '')), '');
begin
  select * into r from app_releases
   where platform = coalesce(p_platform, 'android')
   order by version_code desc limit 1;

  if r.id is null or coalesce(p_version_code, 0) >= r.version_code then
    -- No update. 'current' and 'message' stay present so the payload shape never
    -- changes between branches, and dismiss_key is null so the client drops any
    -- dismissal it was holding — this is the moment right after an install.
    return jsonb_build_object(
      'update_available', false,
      'current', coalesce(r.version_name, ''),
      'message', '',
      'dismiss_key', null);
  end if;

  v_cfg := coalesce((select value from app_settings where key = 'app_update_channel'), '{}'::jsonb);

  -- Where did this copy of the app come from? A known installer decides; an
  -- unknown or missing one follows the configured default (Play), because
  -- offering an APK to a Play install is the failure we are fixing.
  select s.channel into v_channel from app_install_source s where s.source = v_src;
  if v_channel is null then
    v_channel := case
      when v_src is null then case when coalesce((v_cfg->>'unknown_is_play')::boolean, true)
                                   then 'play' else 'direct' end
      when coalesce((v_cfg->>'unknown_is_play')::boolean, true) then 'play'
      else 'direct' end;
  end if;

  -- A Play channel with no listing URL configured, or a direct channel with no
  -- APK published, would leave the button pointing nowhere. Fall back to the
  -- other destination rather than render a dead action.
  v_url := case when v_channel = 'play' then nullif(btrim(coalesce(v_cfg->>'play_url','')), '') end;
  if v_url is null and v_channel = 'play' then
    v_url := nullif(btrim(coalesce(r.apk_url, '')), '');
    if v_url is not null then v_channel := 'direct'; end if;
  end if;
  if v_channel = 'direct' then
    v_url := nullif(btrim(coalesce(r.apk_url, '')), '');
    if v_url is null then
      v_url := nullif(btrim(coalesce(v_cfg->>'play_url','')), '');
      if v_url is not null then v_channel := 'play'; end if;
    end if;
  end if;

  -- Nothing to send the user to => there is no actionable update.
  if v_url is null then
    return jsonb_build_object('update_available', false, 'current', '',
                              'message', '', 'dismiss_key', null);
  end if;

  v_action  := case when v_channel = 'play' then _c('app_update.action_play')
                    else _c('app_update.action_apk') end;
  v_title   := case when r.is_mandatory then _c('app_update.title_mandatory')
                    else _c('app_update.title') end;
  -- public_notes only. `notes` is the internal changelog and is deliberately
  -- unreachable from here (see the header) — the fallback is backend copy.
  v_message := coalesce(
    nullif(btrim(coalesce(r.public_notes, '')), ''),
    nullif(case when r.is_mandatory then _c('app_update.message_mandatory')
                else _c('app_update.message_default') end, ''),
    '');

  return jsonb_build_object(
    'update_available', true,
    'current',       coalesce(r.version_name, ''),
    'version_name',  r.version_name,
    'version_code',  r.version_code,
    'version_label', case when coalesce(_c('app_update.version_label'), '') = '' then ''
                          else format(_c('app_update.version_label'), r.version_name) end,
    'channel',       v_channel,
    'store_name',    coalesce(nullif(btrim(coalesce(v_cfg->>'store_name','')), ''), ''),
    'install_source', coalesce(v_src, ''),
    'action_url',    v_url,
    -- apk_url is present ONLY on the direct channel. A Play install must never
    -- even receive the string — that is the whole point of this change.
    'apk_url',       case when v_channel = 'direct' then v_url end,
    'mandatory',     r.is_mandatory,
    'eyebrow',       _c('app_update.eyebrow'),
    'title',         v_title,
    'message',       v_message,
    'action_label',  v_action,
    -- dismiss_label stays NULL on a mandatory release ON PURPOSE: the client
    -- documents "dismiss_label == null -> no dismiss control".
    'dismiss_label', case when r.is_mandatory then null else _c('app_update.dismiss') end,
    -- The identity of THIS prompt. The client remembers the key it dismissed and
    -- stays quiet while the backend keeps sending the same one; a new release
    -- sends a new key and the prompt returns by itself.
    'dismiss_key',   case when r.is_mandatory then null
                          else 'app_update:' || coalesce(p_platform,'android') || ':' || r.version_code end
  );
end $function$;

grant execute on function public.app_update_check(text, integer, text) to anon, authenticated, service_role;
