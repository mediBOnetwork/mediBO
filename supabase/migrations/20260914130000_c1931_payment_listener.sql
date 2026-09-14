-- CMD #1931 — Payment alerts on Android: the notification listener's backend.
--
-- #1929 built the ingest/parse/match/speak chain. This migration builds the
-- three things the PHONE needs and #1929 deliberately left out:
--
--   1. payment_alert_device      — one row per phone: is the listener on, does
--                                  this phone speak, how loud. Settings live
--                                  here, never in the app's own storage.
--   2. payment_listener_config   — the package ALLOW-LIST, assembled from the
--                                  rules table plus an editable extra list, and
--                                  the queue/retry knobs. Changing which apps a
--                                  phone listens to is an UPDATE, not a release.
--   3. payment_listener_card()   — every word of the Money-tab onboarding card,
--                                  the status chip and the speak toggle.
--
-- Idempotent throughout: the direct deploy replays this file on live once.
begin;

-- ── 1. the device registry ──────────────────────────────────────────────────
create table if not exists public.payment_alert_device (
  device_id        text primary key,
  label            text,
  zone_id          smallint,
  partner_id       bigint,
  user_id          uuid,
  listener_enabled boolean     not null default false,
  speak_enabled    boolean     not null default true,
  volume           smallint    not null default 100,
  app_version      text,
  queued_count     integer     not null default 0,
  last_seen_at     timestamptz,
  last_alert_at    timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.payment_alert_device
  add column if not exists queued_count integer not null default 0;

create index if not exists payment_alert_device_zone_idx
  on public.payment_alert_device (zone_id, last_seen_at desc);

alter table public.payment_alert_device enable row level security;
-- RPCs only, exactly like payment_alerts: no anon/authenticated policy.

-- ── 2. the allow-list + the queue knobs ─────────────────────────────────────
create table if not exists public.payment_listener_config (
  id               boolean     primary key default true check (id),
  extra_packages   text[]      not null default '{}',
  ignore_packages  text[]      not null default '{}',
  queue_max        integer     not null default 500,
  retry_seconds    integer     not null default 30,
  drain_batch      integer     not null default 25,
  heartbeat_min    integer     not null default 15,
  updated_at       timestamptz not null default now()
);

-- The UPI and messaging apps a credit actually arrives in. This is a SEED, not
-- a hardcode: the row is editable and the app reads whatever it says.
insert into public.payment_listener_config (id, extra_packages, ignore_packages)
values (true, array[
    'com.google.android.apps.nbu.paisa.user',  -- Google Pay (India)
    'com.phonepe.app',
    'net.one97.paytm',
    'in.org.npci.upiapp',                      -- BHIM
    'in.amazon.mShop.android.shopping',        -- Amazon Pay UPI
    'com.whatsapp',                            -- WhatsApp Pay credit lines
    'com.google.android.apps.messaging',       -- bank SMS, default Messages
    'com.samsung.android.messaging',
    'com.android.mms',
    'com.truecaller'                           -- SMS on many Indian phones
  ], array[
    'in.medibo.app'                            -- never listen to ourselves
  ])
on conflict (id) do nothing;

comment on table public.payment_listener_config is
  'CMD #1931 — which packages the Android notification listener forwards, and how it queues. Edit the row; no release needed.';

-- ── 3. copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('pay_listen.card_title', to_jsonb('Hear every payment'::text)),
  ('pay_listen.card_body', to_jsonb('mediBO can read the payment notifications your UPI and bank apps show, match them to an open bill, and say the amount out loud. Nothing else on this phone is read, and nothing leaves it except a payment line.'::text)),
  ('pay_listen.bullet_1', to_jsonb('Only the apps mediBO lists are read — one tap turns it off.'::text)),
  ('pay_listen.bullet_2', to_jsonb('A payment line is sent to mediBO; message text from any other app is dropped on the phone.'::text)),
  ('pay_listen.bullet_3', to_jsonb('Turn it off any time from Android Settings, or with the switch here.'::text)),
  ('pay_listen.cta_enable', to_jsonb('Turn on notification access'::text)),
  ('pay_listen.cta_manage', to_jsonb('Manage notification access'::text)),
  ('pay_listen.status_on', to_jsonb('Enabled'::text)),
  ('pay_listen.status_off', to_jsonb('Disabled'::text)),
  ('pay_listen.status_on_sub', to_jsonb('This phone is listening for payments.'::text)),
  ('pay_listen.status_off_sub', to_jsonb('Payments will not be heard until you turn this on.'::text)),
  ('pay_listen.speak_label', to_jsonb('Speak the amount out loud'::text)),
  ('pay_listen.speak_on', to_jsonb('On'::text)),
  ('pay_listen.speak_off', to_jsonb('Muted'::text)),
  ('pay_listen.volume_label', to_jsonb('Volume'::text)),
  ('pay_listen.privacy_label', to_jsonb('How we use this — Privacy Policy'::text)),
  ('pay_listen.last_alert_none', to_jsonb('No payment heard on this phone yet.'::text)),
  ('pay_listen.last_alert_fmt', to_jsonb('Last payment heard {when}.'::text)),
  ('pay_listen.queued_fmt', to_jsonb('{n} waiting to send.'::text)),
  ('pay_listen.not_android', to_jsonb('Payment listening works on the mediBO Android app.'::text)),
  ('pay_listen.not_authorized', to_jsonb('Only a partner or an admin phone can listen for payments.'::text)),
  ('pay_listen.saved', to_jsonb('Saved.'::text)),
  ('pay_listen.disclosure_title', to_jsonb('Before you turn this on'::text)),
  ('pay_listen.disclosure_body', to_jsonb('mediBO reads notifications ONLY from the payment and messaging apps listed above, and only to match money you receive to an open bill. The text is parsed on your phone and only the amount, sender and reference are sent to mediBO. Notifications from every other app are ignored and never stored, read by a person, or shared with anyone.'::text)),
  ('pay_listen.disclosure_ok', to_jsonb('I understand — open Settings'::text)),
  ('pay_listen.disclosure_no', to_jsonb('Not now'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 4. the allow-list door ──────────────────────────────────────────────────
-- Every package the phone may forward, plus the queue knobs. The app caches
-- this and re-reads it on every boot; it NEVER carries a package list of its own.
create or replace function public.payment_listener_boot()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c public.payment_listener_config%rowtype; v_pkgs text[];
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false)
             or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_listen.not_authorized',
                            'Only a partner or an admin phone can listen for payments.'));
  end if;

  select * into c from public.payment_listener_config where id;
  if c.id is null then
    c.extra_packages := '{}'; c.ignore_packages := '{}';
    c.queue_max := 500; c.retry_seconds := 30; c.drain_batch := 25; c.heartbeat_min := 15;
  end if;

  select coalesce(array_agg(distinct p), '{}')
    into v_pkgs
  from (
    select unnest(c.extra_packages) as p
    union
    select r.package_name from public.payment_alert_rules r
     where r.enabled and coalesce(btrim(r.package_name),'') <> ''
  ) s
  where s.p is not null
    and btrim(s.p) <> ''
    and not (s.p = any (coalesce(c.ignore_packages, '{}')));

  return jsonb_build_object(
    'ok', true,
    'packages',      to_jsonb(coalesce(v_pkgs,'{}')),
    'queue_max',     c.queue_max,
    'retry_seconds', c.retry_seconds,
    'drain_batch',   c.drain_batch,
    'heartbeat_min', c.heartbeat_min
  );
end $$;

revoke all on function public.payment_listener_boot() from anon, authenticated;
grant execute on function public.payment_listener_boot() to authenticated;

-- ── 5. the card ─────────────────────────────────────────────────────────────
create or replace function public._pay_listen_card(p_device text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d public.payment_alert_device%rowtype; v_when text; v_last text; v_zone smallint;
begin
  if coalesce(btrim(p_device),'') <> '' then
    select * into d from public.payment_alert_device where device_id = btrim(p_device);
  end if;
  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());

  if d.last_alert_at is null then
    v_last := public.uic('pay_listen.last_alert_none','No payment heard on this phone yet.');
  else
    v_when := to_char(d.last_alert_at at time zone 'Asia/Kolkata', 'DD Mon, hh12:mi am');
    v_last := replace(public.uic('pay_listen.last_alert_fmt','Last payment heard {when}.'),
                      '{when}', v_when);
  end if;

  return jsonb_build_object(
    'ok', true,
    'device_id',  coalesce(d.device_id, btrim(coalesce(p_device,''))),
    'title',      public.uic('pay_listen.card_title','Hear every payment'),
    'body',       public.uic('pay_listen.card_body',''),
    'bullets',    jsonb_build_array(
                    public.uic('pay_listen.bullet_1',''),
                    public.uic('pay_listen.bullet_2',''),
                    public.uic('pay_listen.bullet_3','')),
    'enabled',    coalesce(d.listener_enabled, false),
    'status_label', case when coalesce(d.listener_enabled,false)
                      then public.uic('pay_listen.status_on','Enabled')
                      else public.uic('pay_listen.status_off','Disabled') end,
    'status_sub',   case when coalesce(d.listener_enabled,false)
                      then public.uic('pay_listen.status_on_sub','')
                      else public.uic('pay_listen.status_off_sub','') end,
    'status_tone',  case when coalesce(d.listener_enabled,false) then 'success' else 'warning' end,
    'cta_label',    case when coalesce(d.listener_enabled,false)
                      then public.uic('pay_listen.cta_manage','Manage notification access')
                      else public.uic('pay_listen.cta_enable','Turn on notification access') end,
    'speak_label',  public.uic('pay_listen.speak_label','Speak the amount out loud'),
    'speak_on',     coalesce(d.speak_enabled, true),
    'speak_state',  case when coalesce(d.speak_enabled,true)
                      then public.uic('pay_listen.speak_on','On')
                      else public.uic('pay_listen.speak_off','Muted') end,
    'volume',       coalesce(d.volume, 100),
    'volume_label', public.uic('pay_listen.volume_label','Volume'),
    'privacy_label',public.uic('pay_listen.privacy_label','How we use this — Privacy Policy'),
    'privacy_slug', 'privacy',
    'last_alert',   v_last,
    'queued_label', case when coalesce(d.queued_count,0) > 0
                      then replace(public.uic('pay_listen.queued_fmt','{n} waiting to send.'),
                                   '{n}', d.queued_count::text)
                      else '' end,
    'disclosure',   jsonb_build_object(
                      'title', public.uic('pay_listen.disclosure_title','Before you turn this on'),
                      'body',  public.uic('pay_listen.disclosure_body',''),
                      'ok',    public.uic('pay_listen.disclosure_ok','I understand — open Settings'),
                      'cancel',public.uic('pay_listen.disclosure_no','Not now')),
    'zone_id',      v_zone
  );
end $$;
revoke all on function public._pay_listen_card(text) from anon, authenticated;

-- The phone reports what Android told it, and gets the whole card back.
create or replace function public.payment_listener_report(
  p_device text, p_enabled boolean,
  p_app_version text default null, p_queued integer default null,
  p_label text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_zone smallint;
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false)
             or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_listen.not_authorized',''));
  end if;
  if coalesce(btrim(p_device),'') = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_alert.bad_request','A device id and a package name are required.'));
  end if;
  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone(), public.zone_default_id());

  insert into public.payment_alert_device
    (device_id, label, zone_id, user_id, listener_enabled, app_version,
     queued_count, last_seen_at, updated_at)
  values (btrim(p_device), nullif(btrim(coalesce(p_label,'')),''), v_zone, auth.uid(),
          coalesce(p_enabled,false), nullif(btrim(coalesce(p_app_version,'')),''),
          greatest(coalesce(p_queued,0),0), now(), now())
  on conflict (device_id) do update set
    listener_enabled = coalesce(excluded.listener_enabled, public.payment_alert_device.listener_enabled),
    app_version      = coalesce(excluded.app_version, public.payment_alert_device.app_version),
    label            = coalesce(excluded.label, public.payment_alert_device.label),
    zone_id          = coalesce(excluded.zone_id, public.payment_alert_device.zone_id),
    user_id          = coalesce(excluded.user_id, public.payment_alert_device.user_id),
    queued_count     = coalesce(excluded.queued_count, public.payment_alert_device.queued_count),
    last_seen_at     = now(),
    updated_at       = now();

  return public._pay_listen_card(btrim(p_device));
end $$;
revoke all on function public.payment_listener_report(text, boolean, text, integer, text) from anon, authenticated;
grant execute on function public.payment_listener_report(text, boolean, text, integer, text) to authenticated;

-- The speak switch and its volume, stored per device in the BACKEND.
create or replace function public.payment_listener_set_speak(
  p_device text, p_speak boolean, p_volume integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false)
             or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_listen.not_authorized',''));
  end if;
  if coalesce(btrim(p_device),'') = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_alert.bad_request',''));
  end if;

  insert into public.payment_alert_device (device_id, speak_enabled, volume, last_seen_at, updated_at)
  values (btrim(p_device), coalesce(p_speak,true),
          least(greatest(coalesce(p_volume,100),0),100)::smallint, now(), now())
  on conflict (device_id) do update set
    speak_enabled = coalesce(p_speak, public.payment_alert_device.speak_enabled),
    volume        = least(greatest(coalesce(p_volume, public.payment_alert_device.volume),0),100)::smallint,
    last_seen_at  = now(),
    updated_at    = now();

  return public._pay_listen_card(btrim(p_device))
         || jsonb_build_object('toast', public.uic('pay_listen.saved','Saved.'));
end $$;
revoke all on function public.payment_listener_set_speak(text, boolean, integer) from anon, authenticated;
grant execute on function public.payment_listener_set_speak(text, boolean, integer) to authenticated;

-- The card on its own, for a plain read.
create or replace function public.payment_listener_card(p_device text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false)
             or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_listen.not_authorized',''));
  end if;
  return public._pay_listen_card(p_device);
end $$;
revoke all on function public.payment_listener_card(text) from anon, authenticated;
grant execute on function public.payment_listener_card(text) to authenticated;

-- ── 6. the speak pull answers this device's own mute switch ─────────────────
-- #1929's payment_listener-free version spoke on every phone in the zone. A
-- muted phone must stay silent, and that switch lives in the backend, so the
-- pull itself has to know which phone is asking.
drop function if exists public.payment_alert_speak_pull(int);
create or replace function public.payment_alert_speak_pull(p_limit int default 5, p_device text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_zone smallint; v_rows jsonb; v_ids bigint[]; v_speak boolean := true; v_vol smallint := 100;
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false) or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());

  if coalesce(btrim(coalesce(p_device,'')),'') <> '' then
    select d.speak_enabled, d.volume into v_speak, v_vol
      from public.payment_alert_device d where d.device_id = btrim(p_device);
    v_speak := coalesce(v_speak, true);
    v_vol   := coalesce(v_vol, 100);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'message', s.message,
           'amount_label', public.inr_money(s.amount),
           'alert_id', s.alert_id, 'order_id', s.order_id,
           'at_label', to_char(s.created_at at time zone 'Asia/Kolkata','hh12:mi am')
         ) order by s.created_at), '[]'::jsonb),
       array_agg(s.id)
    into v_rows, v_ids
  from (select * from public.payment_alert_speak
         where spoken_at is null
           and (v_zone is null or zone_id = v_zone)
           and created_at > now() - interval '6 hours'
         order by created_at limit greatest(coalesce(p_limit,5),1)) s;

  if coalesce(array_length(v_ids,1),0) > 0 then
    update public.payment_alert_speak set spoken_at = now() where id = any(v_ids);
    if coalesce(btrim(coalesce(p_device,'')),'') <> '' then
      update public.payment_alert_device
         set last_alert_at = now(), updated_at = now()
       where device_id = btrim(p_device);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'rows', coalesce(v_rows,'[]'::jsonb),
                            'count', coalesce(array_length(v_ids,1),0),
                            'speak', v_speak, 'volume', v_vol);
end $$;
revoke all on function public.payment_alert_speak_pull(int, text) from anon, authenticated;
grant execute on function public.payment_alert_speak_pull(int, text) to authenticated;

-- ── 7. the card is a tile on the Money home ────────────────────────────────
-- staff_home('money') carries it as a NATIVE card: the phone draws the widget,
-- every word in it comes from payment_listener_card().
create table if not exists public.staff_home_native_card (
  id         bigserial primary key,
  tab_key    text    not null,
  kind       text    not null,
  platform   text    not null default 'android',
  sort_order integer not null default 0,
  enabled    boolean not null default true,
  unique (tab_key, kind)
);

insert into public.staff_home_native_card (tab_key, kind, platform, sort_order, enabled)
values ('money', 'payment_listener', 'android', 10, true)
on conflict (tab_key, kind) do update set
  platform = excluded.platform, sort_order = excluded.sort_order, enabled = excluded.enabled;


-- ── 8. the Money tab asks ONE question: "draw anything here?" ───────────────
-- The card is Android-only, and that is a BACKEND fact: the phone sends the
-- platform it is running on and the backend answers show:true/false off
-- staff_home_native_card. Turning the card off on every phone in the country
-- is one UPDATE.
drop function if exists public.payment_listener_card(text);
create or replace function public.payment_listener_card(
  p_device text default null, p_platform text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_show boolean; v_plat text := lower(btrim(coalesce(p_platform,'')));
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false)
             or coalesce(public.get_my_role(),'') in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'show', false, 'error','not_authorized',
      'message', public.uic('pay_listen.not_authorized',
                            'Only a partner or an admin phone can listen for payments.'));
  end if;

  select n.enabled and (v_plat = '' or n.platform = 'all' or n.platform = v_plat)
    into v_show
    from public.staff_home_native_card n
   where n.tab_key = 'money' and n.kind = 'payment_listener';

  if not coalesce(v_show, false) then
    return jsonb_build_object('ok', true, 'show', false,
      'message', public.uic('pay_listen.not_android',
                            'Payment listening works on the mediBO Android app.'));
  end if;

  return public._pay_listen_card(p_device) || jsonb_build_object('show', true);
end $$;
revoke all on function public.payment_listener_card(text, text) from anon, authenticated;
grant execute on function public.payment_listener_card(text, text) to authenticated;


-- ── 9. the privacy policy says what the listener reads ─────────────────────
-- Play's notification-access declaration is checked against the policy the
-- store listing points at, so the section has to be IN the policy, not in a
-- release note. Appended once; re-running this file changes nothing.
insert into public.legal_pages (slug, title, sections)
values ('privacy', 'Privacy Policy', '[]'::jsonb)
on conflict (slug) do nothing;

update public.legal_pages
   set sections = sections || jsonb_build_array(
         jsonb_build_object('heading', 'Payment notification access (Android)', 'body', 'The mediBO Android app can read notifications posted by your phone''s payment and messaging apps, and only those apps. Which apps are read is a list mediBO holds and shows you on the Money screen; a notification from any app not on that list is discarded on your phone and is never sent, stored or seen by anyone. This access is optional, it is off until you turn it on yourself in Android Settings, and you can withdraw it at any time from the same screen or from the switch in the app. What we do with it: when a payment notification arrives, the amount, the sender name shown on it, the reference or UTR and the time are sent to mediBO so the payment can be matched to an open bill on your account and read out loud to you. The notification''s full text is kept with that record only so a wrong match can be corrected. Nothing from this access is used for advertising, profiling or any purpose other than matching money you receive to your own bills, and it is never sold or shared with a third party. Payment records are retained for as long as your account''s accounting records are retained under Indian tax law. To have them deleted, or to ask what is held, write to support@medibo.in.')),
       updated_at = now()
 where slug = 'privacy'
   and not exists (
     select 1 from jsonb_array_elements(sections) s
      where s->>'heading' = 'Payment notification access (Android)');


-- ── 10. shut the anon door at the GRANT, not only inside the function ───────
-- Postgres grants EXECUTE to PUBLIC on every new function, so `revoke from
-- anon` alone leaves has_function_privilege('anon', …) true — the guard clause
-- inside each body was the ONLY thing between an unauthenticated caller and
-- payment_alert_ingest. Both doors are shut now: PUBLIC loses execute, and
-- only `authenticated` and `service_role` get it back.
do $$
declare f text;
begin
  foreach f in array array[
    'payment_listener_boot()',
    'payment_listener_card(text, text)',
    'payment_listener_report(text, boolean, text, integer, text)',
    'payment_listener_set_speak(text, boolean, integer)',
    'payment_alert_speak_pull(integer, text)',
    'payment_alert_ingest(text, text, text, text, timestamptz)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  -- Internal helper: nobody calls it directly.
  execute 'revoke all on function public._pay_listen_card(text) from public, anon, authenticated';
end $$;


-- ── 11. the speak feed is a REGISTERED live table ───────────────────────────
-- #1929 put payment_alert_speak into supabase_realtime but never told
-- realtime_table_registry, which is what LiveFeed asks and what the rg
-- behaviour c646_registry_matches_publication compares the publication
-- against. Without this row the phone would have silently POLLED for a
-- payment it is supposed to hear the instant it lands.
insert into public.realtime_table_registry
  (table_name, live, filter_required, poll_seconds, surface, reason)
values ('payment_alert_speak', true, false, 30, 'money',
        'CMD #1931 — the phone speaks a matched payment the moment it is written.')
on conflict (table_name) do update set
  live = true, filter_required = false, updated_at = now();

commit;
