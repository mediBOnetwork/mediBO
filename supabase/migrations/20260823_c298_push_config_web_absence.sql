-- CHANGE #298 — an unregistered platform is an ABSENCE, not a fallback.
--
-- push_config_get() returned coalesce(web_api_key, api_key) and
-- coalesce(web_app_id, app_id). Firebase project medibo-23aee has an ANDROID
-- app registered and no web app, so that fallback did two harmful things:
--
--   1. it handed the web Firebase SDK an ANDROID application id, so
--      Firebase.initializeApp() on web would fail deep inside the SDK rather
--      than the app simply knowing browser push is not set up; and
--   2. it made Admin > Push notifications print a fully-populated web app that
--      does not exist — the screenshot proof for this command is what caught
--      it, because both web fields rendered with the Android values.
--
-- The payload now says absent when it is absent, and carries web_ready /
-- android_ready so neither the app nor the screen has to infer which platforms
-- can actually receive a push. Backend decides; the frontend renders.
--
-- Idempotent: create or replace, safe to re-apply.
create or replace function public.push_config_get()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'ok', true,
    'enabled', c.enabled and coalesce(nullif(btrim(c.sender_id),''),'') <> '',
    'project_id', c.project_id,
    'api_key', c.api_key,
    'app_id', c.app_id,
    'sender_id', c.sender_id,
    'web_api_key', c.web_api_key,
    'web_app_id', c.web_app_id,
    'vapid_key', c.vapid_key,
    'web_ready', (coalesce(nullif(btrim(c.web_api_key),''),'') <> ''
              and coalesce(nullif(btrim(c.web_app_id),''),'')  <> ''),
    'android_ready', (coalesce(nullif(btrim(c.api_key),''),'') <> ''
                  and coalesce(nullif(btrim(c.app_id),''),'')  <> ''),
    'android_package', c.android_package,
    'setup_note', c.setup_note)
  from push_config c where c.id = 'singleton';
$function$;

-- CHANGE #298 — push_config_set() called public.c(), which does not exist in
-- this schema (the copy helper is uic(key, fallback)). Every refused call
-- raised 42883 instead of returning the backend's not_authorized answer, and
-- refusal is the FIRST path a non-super-admin hits, so the admin screen would
-- have thrown rather than rendered its refusal.
create or replace function public.push_config_set(p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.get_my_role() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('push.not_authorized',
                            'Only a super admin can change the push settings.'));
  end if;
  update push_config set
    enabled     = coalesce((p_patch->>'enabled')::boolean, enabled),
    project_id  = coalesce(nullif(p_patch->>'project_id',''),  project_id),
    api_key     = coalesce(nullif(p_patch->>'api_key',''),     api_key),
    app_id      = coalesce(nullif(p_patch->>'app_id',''),      app_id),
    sender_id   = coalesce(nullif(p_patch->>'sender_id',''),   sender_id),
    web_api_key = coalesce(nullif(p_patch->>'web_api_key',''), web_api_key),
    web_app_id  = coalesce(nullif(p_patch->>'web_app_id',''),  web_app_id),
    vapid_key   = coalesce(nullif(p_patch->>'vapid_key',''),   vapid_key),
    android_package = coalesce(nullif(p_patch->>'android_package',''), android_package),
    setup_note  = coalesce(p_patch->>'setup_note', setup_note),
    updated_at  = now()
  where id = 'singleton';
  return public.push_config_get();
end $function$;

-- The strings the newly-wired surfaces print. Idempotent.
insert into ui_copy (key, value) values
  ('admin_nav.overflow_push', to_jsonb('Push notifications'::text)),
  ('notif_inbox.bell_tooltip', to_jsonb('Notifications'::text))
on conflict (key) do nothing;
