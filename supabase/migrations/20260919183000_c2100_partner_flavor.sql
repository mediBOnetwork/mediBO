-- CMD #2100 — Two apps, one codebase: the 'partner' flavor (in.medibo.partner).
--
-- Every RPC now carries the app flavor as a request header (x-medibo-flavor:
-- customer | partner; web sends 'web'). Nothing in Dart branches on it — the
-- backend reads it here and answers accordingly:
--   * app_flavor()            — the header, normalised. Absent → 'web'.
--   * app_release_platform()  — 'android' becomes 'android_partner' for the
--                               partner flavor, so app_releases keeps ONE
--                               schema and every existing release function
--                               (next_version, publish, play_sync, update
--                               state) is per-app by its platform key.
--   * app_home()              — the role home after login. A customer on the
--                               partner app gets 'blocked' + the backend's
--                               "Use the mediBO app" screen (copy in ui_copy).
--   * app_update_check()      — the partner app's bar names the partner
--                               release and the partner Play URL.
--   * push_config_get()/set() — the partner Firebase app id + package, so FCM
--                               on the partner app registers against its own
--                               Firebase Android app once Om registers it.
--   * secret_set_runner()     — the Vault WRITER production never had: the
--                               partner upload keystore is stored through it
--                               (service_role only, audited, never logged).
-- Idempotent: safe to replay.

-- ── 1. the flavor header ────────────────────────────────────────────────────
create or replace function public.app_flavor()
returns text language plpgsql stable
set search_path to 'public' as $function$
declare v_h text;
begin
  begin
    v_h := lower(coalesce(
      nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-medibo-flavor', ''));
  exception when others then
    v_h := '';
  end;
  return case v_h when 'partner' then 'partner' when 'customer' then 'customer' else 'web' end;
end $function$;
revoke all on function public.app_flavor() from public;
grant execute on function public.app_flavor() to anon, authenticated, service_role;

create or replace function public.app_release_platform(p_platform text default 'android')
returns text language sql stable
set search_path to 'public' as $function$
  select case
           when coalesce(p_platform, 'android') = 'android' and public.app_flavor() = 'partner'
             then 'android_partner'
           else coalesce(p_platform, 'android')
         end;
$function$;
revoke all on function public.app_release_platform(text) from public;
grant execute on function public.app_release_platform(text) to anon, authenticated, service_role;

-- ── 2. the role home ────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('partner_app.block_title', to_jsonb('Use the mediBO app'::text)),
  ('partner_app.block_body', to_jsonb('This app is for mediBO partners, suppliers, delivery and staff. Your account is a customer account — orders, catalogue and khata live in the mediBO app.'::text)),
  ('partner_app.block_cta', to_jsonb('Get mediBO on Google Play'::text)),
  ('partner_app.customer_play_url', to_jsonb('https://play.google.com/store/apps/details?id=in.medibo.app'::text)),
  ('partner_app.block_signout', to_jsonb('Sign out and use another account'::text)),
  ('partner_app.block_hint', to_jsonb('Signed in as {email}'::text))
on conflict (key) do nothing;

create or replace function public.app_home()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_flavor text := public.app_flavor();
  v_role   text;
  v_home   text;
  v_block  jsonb := null;
  v_email  text := null;
begin
  if auth.uid() is null then
    v_role := 'none';
  else
    v_role := coalesce(public.get_my_role(), 'none');
    v_email := coalesce(auth.jwt() ->> 'email', '');
  end if;

  v_home := case v_role
              when 'none'        then 'signed_out'
              when 'super_admin' then 'admin'
              when 'admin'       then 'admin'
              when 'partner'     then 'admin'
              when 'supplier'    then 'supplier'
              when 'delivery'    then 'delivery'
              when 'customer'    then 'customer'
              else 'staff'
            end;

  -- The partner app serves every role except the customer. A customer who
  -- signs in there is sent to the customer app, in the backend's words.
  if v_flavor = 'partner' and v_home = 'customer' then
    v_home := 'blocked';
    v_block := jsonb_build_object(
      'title',         public.uic('partner_app.block_title', to_jsonb('Use the mediBO app'::text)),
      'body',          public.uic('partner_app.block_body', to_jsonb(''::text)),
      'hint',          replace(public.uic('partner_app.block_hint', to_jsonb(''::text)), '{email}', v_email),
      'cta_label',     public.uic('partner_app.block_cta', to_jsonb('Get mediBO on Google Play'::text)),
      'cta_url',       public.uic('partner_app.customer_play_url', to_jsonb('https://play.google.com/store/apps/details?id=in.medibo.app'::text)),
      'signout_label', public.uic('partner_app.block_signout', to_jsonb('Sign out'::text)));
  end if;

  return jsonb_build_object(
    'ok', true, 'flavor', v_flavor, 'role', v_role, 'home', v_home,
    'blocked', v_home = 'blocked', 'block', v_block);
end $function$;
revoke all on function public.app_home() from public, anon;
grant execute on function public.app_home() to authenticated, service_role;

-- ── 3. the update bar names the partner release on the partner app ──────────
CREATE OR REPLACE FUNCTION public.app_update_check(p_platform text DEFAULT 'web'::text, p_installed_version text DEFAULT NULL::text, p_live_version text DEFAULT NULL::text, p_platform_state text DEFAULT NULL::text, p_platform_version text DEFAULT NULL::text, p_dismissed_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- CMD #2100 — the partner flavor has its own release row (platform 'android_partner').
      r := public.app_published_release(public.app_release_platform('android'));
      v_target := coalesce(
        nullif(btrim(coalesce(p_platform_version, '')), ''),
        r.version_name);
      v_url := coalesce(nullif(btrim(coalesce(v_chan->>(case when public.app_flavor() = 'partner' then 'partner_play_url' else 'play_url' end), '')), ''),
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


-- ── 4. FCM: the partner Firebase app ────────────────────────────────────────
alter table public.push_config add column if not exists partner_app_id  text;
alter table public.push_config add column if not exists partner_package text;
update public.push_config set partner_package = 'in.medibo.partner'
 where id = 'singleton' and coalesce(partner_package, '') = '';

create or replace function public.push_config_get()
returns jsonb language sql stable security definer
set search_path to 'public' as $function$
  select jsonb_build_object(
    'ok', true,
    'enabled', c.enabled and coalesce(nullif(btrim(c.sender_id),''),'') <> '',
    'project_id', c.project_id,
    'api_key', c.api_key,
    -- CMD #2100 — the partner flavor registers against ITS Firebase Android app.
    'app_id', case when public.app_flavor() = 'partner' then c.partner_app_id else c.app_id end,
    'sender_id', c.sender_id,
    'web_api_key', c.web_api_key,
    'web_app_id', c.web_app_id,
    'vapid_key', c.vapid_key,
    'web_ready', (coalesce(nullif(btrim(c.web_api_key),''),'') <> ''
              and coalesce(nullif(btrim(c.web_app_id),''),'')  <> ''),
    'android_ready', (coalesce(nullif(btrim(c.api_key),''),'') <> ''
                  and coalesce(nullif(btrim(case when public.app_flavor() = 'partner'
                                                 then c.partner_app_id else c.app_id end),''),'') <> ''),
    'android_package', case when public.app_flavor() = 'partner' then c.partner_package else c.android_package end,
    'flavor', public.app_flavor(),
    'partner_app_id', c.partner_app_id,
    'partner_package', c.partner_package,
    'setup_note', c.setup_note)
  from push_config c where c.id = 'singleton';
$function$;

CREATE OR REPLACE FUNCTION public.push_config_set(p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    partner_app_id  = coalesce(nullif(p_patch->>'partner_app_id',''),  partner_app_id),
    partner_package = coalesce(nullif(p_patch->>'partner_package',''), partner_package),
    setup_note  = coalesce(p_patch->>'setup_note', setup_note),
    updated_at  = now()
  where id = 'singleton';
  return public.push_config_get();
end $function$;


-- ── 5. the Vault writer ─────────────────────────────────────────────────────
create or replace function public.secret_set_runner(p_name text, p_value text)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_id uuid;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'secret: runner only';
  end if;
  if coalesce(btrim(p_name), '') = '' or p_value is null then
    raise exception 'secret: name and value required';
  end if;
  select id into v_id from vault.secrets where name = p_name limit 1;
  if v_id is null then
    v_id := vault.create_secret(p_value, p_name);
  else
    perform vault.update_secret(v_id, p_value);
  end if;
  perform _audit('runner', 'secret_write', p_name, '{}');
  return jsonb_build_object('ok', true, 'name', p_name,
                            'masked', '••••' || right(p_value, 4));
end $function$;
revoke all on function public.secret_set_runner(text, text) from public, anon, authenticated;
grant execute on function public.secret_set_runner(text, text) to service_role;
