-- CMD #2067 — pairing that actually pairs, and a listener that is actually bound.
--
-- The real phone test (mediBO 1.3.28, 17 Sep): notification access was granted,
-- Android said ON, the Devices card still said "Not paired", and two ₹1 UPI
-- credits were never heard. Nothing was wrong with the parser: the Devices
-- SECTION never started the listener service at all, so
--   * payment_alert_device_register() was never called  -> no device row, and
--   * payment_listener_boot().packages was never written to the phone -> the
--     Android allow-list was EMPTY, so every notification was dropped before
--     it was looked at.
--
-- The Dart/Kotlin half of that is fixed in the app. This file gives the backend
-- the three things the fix needs:
--   1. register() may carry what Android just said — the grant, whether the
--      listener service actually BOUND (onListenerConnected), and the app
--      version — so one call after the grant both pairs the phone and lights
--      the card.
--   2. the pairing card gets its own wording for "paired AND listening",
--      because "Paired" alone is what made a phone that could hear nothing
--      look healthy.
--   3. the QA fixture row proof-2050-phone is removed, so the list is real
--      phones only.
--
-- Zone- and date-scoped exactly as before: partner_zone_id() then
-- admin_active_zone(), counts on admin_active_date(). Idempotent: the direct
-- deploy replays this file on live once.
begin;

-- ── 1. what the phone can now tell us ───────────────────────────────────────
-- listener_bound_at is the ONLY honest answer to "is the service running?".
-- The grant (listener_enabled) is a permission; binding is what Android
-- actually did with it, and on ColorOS/MIUI the two come apart.
alter table public.payment_alert_device
  add column if not exists listener_bound_at timestamptz;

-- ── 2. copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('pay_dev.paired_listening',     to_jsonb('Paired · Listening on'::text)),
  ('pay_dev.paired_not_listening', to_jsonb('Paired · Listening off'::text)),
  ('pay_dev.paired_listening_sub',
     to_jsonb('This phone is paired and its notification listener is running. Payments you receive are forwarded to mediBO.'::text)),
  ('pay_dev.paired_no_bind_sub',
     to_jsonb('Notification access is on but the listener has not started yet. Open this screen again, or turn the access off and on once.'::text)),
  ('pay_dev.bound_label',   to_jsonb('Listener'::text)),
  ('pay_dev.bound_yes',     to_jsonb('Running'::text)),
  ('pay_dev.bound_no',      to_jsonb('Not running'::text)),
  ('pay_dev.rebind_cta',    to_jsonb('Restart the listener'::text)),
  ('pay_dev.rebound',       to_jsonb('Listener restarted.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 3. register, carrying what Android just said ────────────────────────────
-- The old three-argument signature is DROPPED before the new one is created:
-- two overloads that differ only by defaulted arguments make every named-arg
-- call from PostgREST ambiguous.
drop function if exists public.payment_alert_device_register(text, text, integer);

create or replace function public.payment_alert_device_register(
  p_device text,
  p_label text default null,
  p_zone_id integer default null,
  p_listener_enabled boolean default null,
  p_bound boolean default null,
  p_app_version text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_zone smallint; v_dev text := btrim(coalesce(p_device,''));
begin
  if not public._pay_dev_allowed() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_dev.not_authorized',''));
  end if;
  if v_dev = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_dev.bad_request','A device id is required.'));
  end if;

  v_zone := coalesce(p_zone_id::smallint, public.partner_zone_id(),
                     public.admin_active_zone(), public.zone_default_id());

  insert into public.payment_alert_device
    (device_id, label, zone_id, user_id, listener_enabled, app_version,
     listener_bound_at, last_seen_at, updated_at)
  values (v_dev, nullif(btrim(coalesce(p_label,'')),''), v_zone, auth.uid(),
          coalesce(p_listener_enabled, false),
          nullif(btrim(coalesce(p_app_version,'')),''),
          case when p_bound then now() else null end,
          now(), now())
  on conflict (device_id) do update set
    label             = coalesce(nullif(btrim(coalesce(p_label,'')),''), public.payment_alert_device.label),
    zone_id           = coalesce(excluded.zone_id, public.payment_alert_device.zone_id),
    user_id           = coalesce(excluded.user_id, public.payment_alert_device.user_id),
    listener_enabled  = coalesce(p_listener_enabled, public.payment_alert_device.listener_enabled),
    app_version       = coalesce(excluded.app_version, public.payment_alert_device.app_version),
    listener_bound_at = case when p_bound then now()
                             else public.payment_alert_device.listener_bound_at end,
    last_seen_at      = now(),
    updated_at        = now();

  return jsonb_build_object(
    'ok', true, 'device_id', v_dev, 'zone_id', v_zone,
    'listener_on', coalesce(p_listener_enabled, false),
    'bound',       coalesce(p_bound, false),
    'toast', public.uic('pay_dev.registered','This phone is paired.'));
end $$;

-- ── 4. one device row: say whether the listener is RUNNING, not just allowed ─
create or replace function public._pay_dev_row(
  d public.payment_alert_device, p_device text, p_date date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_today int; v_datelbl text; v_bound boolean;
begin
  select count(*) into v_today
    from public.payment_alerts a
   where a.device_id = d.device_id
     and a.business_date = p_date;

  v_datelbl := to_char(p_date, 'DD Mon');
  -- A bind older than a day is not a running listener, it is a memory.
  v_bound := d.listener_bound_at is not null
             and d.listener_bound_at > now() - interval '24 hours';

  return jsonb_build_object(
    'device_id',      d.device_id,
    'is_this_device', d.device_id = btrim(coalesce(p_device,'')) and coalesce(btrim(coalesce(p_device,'')),'') <> '',
    'label',          coalesce(nullif(btrim(coalesce(d.label,'')),''),
                               public.uic('pay_dev.unnamed','Unnamed phone')),
    'this_label',     public.uic('pay_dev.this_device','This phone'),
    'status_label',   case when coalesce(d.listener_enabled,false)
                        then public.uic('pay_dev.listener_on','On')
                        else public.uic('pay_dev.listener_off','Off') end,
    'status_tone',    case when coalesce(d.listener_enabled,false) then 'success' else 'warning' end,
    'listener_label', public.uic('pay_dev.listener_label','Listening'),
    'listener_on',    coalesce(d.listener_enabled,false),
    'bound_label',    public.uic('pay_dev.bound_label','Listener'),
    'bound',          v_bound,
    'bound_state',    case when v_bound then public.uic('pay_dev.bound_yes','Running')
                           else public.uic('pay_dev.bound_no','Not running') end,
    'bound_tone',     case when v_bound then 'success' else 'warning' end,
    'speak_label',    public.uic('pay_dev.speak_label','Speak the amount'),
    'speak_on',       coalesce(d.speak_enabled,true),
    'speak_state',    case when coalesce(d.speak_enabled,true)
                        then public.uic('pay_dev.speak_on','On')
                        else public.uic('pay_dev.speak_off','Muted') end,
    'volume',         coalesce(d.volume,100),
    'volume_label',   public.uic('pay_dev.volume_label','Volume'),
    'listener_editable', d.device_id = btrim(coalesce(p_device,''))
                         and coalesce(btrim(coalesce(p_device,'')),'') <> '',
    'listener_note',  case when d.device_id = btrim(coalesce(p_device,''))
                             and coalesce(btrim(coalesce(p_device,'')),'') <> ''
                        then '' else public.uic('pay_dev.web_note','') end,
    'last_seen',      case when d.last_seen_at is null
                        then public.uic('pay_dev.last_seen_never','Never seen')
                        else replace(public.uic('pay_dev.last_seen_fmt','Last seen {when}'),
                                     '{when}', to_char(d.last_seen_at at time zone 'Asia/Kolkata', 'DD Mon HH12:MI AM')) end,
    'last_alert',     case when d.last_alert_at is null
                        then public.uic('pay_dev.last_alert_none','No payment heard yet')
                        else replace(public.uic('pay_dev.last_alert_fmt','Last payment {when}'),
                                     '{when}', to_char(d.last_alert_at at time zone 'Asia/Kolkata', 'DD Mon HH12:MI AM')) end,
    'today_label',    case when v_today = 0
                        then replace(public.uic('pay_dev.today_none','Nothing heard on {date}'), '{date}', v_datelbl)
                        else replace(replace(public.uic('pay_dev.today_fmt','{n} heard on {date}'),
                                             '{n}', v_today::text), '{date}', v_datelbl) end,
    'version_label',  case when coalesce(btrim(coalesce(d.app_version,'')),'') = '' then ''
                        else replace(public.uic('pay_dev.version_fmt','App {v}'), '{v}', d.app_version) end,
    'zone_id',        d.zone_id
  );
end $$;

-- ── 5. the pairing card: "Paired" alone was a lie a deaf phone could tell ───
create or replace function public.payment_alert_device_list(
  p_device text default null, p_platform text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_zone smallint; v_date date; v_plat text := lower(btrim(coalesce(p_platform,'')));
  v_rows jsonb; v_n int; v_me text := btrim(coalesce(p_device,''));
  v_paired boolean; v_native boolean; v_listening boolean; v_bound boolean;
begin
  if not public._pay_dev_allowed() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_dev.not_authorized',''));
  end if;

  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());
  v_date := coalesce(public.admin_active_date(), (now() at time zone 'Asia/Kolkata')::date);
  v_native := (v_plat = 'android');

  select coalesce(jsonb_agg(public._pay_dev_row(d, v_me, v_date)
                            order by (d.device_id = v_me) desc, d.last_seen_at desc nulls last),
                  '[]'::jsonb),
         count(*)
    into v_rows, v_n
  from public.payment_alert_device d
  where (v_zone is null or d.zone_id = v_zone);

  select true,
         coalesce(d.listener_enabled,false),
         d.listener_bound_at is not null and d.listener_bound_at > now() - interval '24 hours'
    into v_paired, v_listening, v_bound
  from public.payment_alert_device d
  where v_me <> '' and d.device_id = v_me;

  return jsonb_build_object(
    'ok', true,
    'title',       public.uic('pay_dev.section_title','Devices'),
    'subtitle',    public.uic('pay_dev.section_sub',''),
    'count_label', case when v_n = 0 then public.uic('pay_dev.count_none','No phone paired yet')
                        when v_n = 1 then public.uic('pay_dev.count_one','1 phone paired')
                        else replace(public.uic('pay_dev.count_many','{n} phones paired'),
                                     '{n}', v_n::text) end,
    'count',       v_n,
    'can_edit',    true,
    'is_native',   v_native,
    'note',        case when v_native then '' else public.uic('pay_dev.web_note','') end,
    'empty_label', public.uic('pay_dev.empty_label',''),
    'empty_hint',  public.uic('pay_dev.empty_hint',''),
    'pairing', jsonb_build_object(
      'title',        case when v_native then public.uic('pay_dev.paired_title','This phone')
                        else public.uic('pay_dev.web_pair_title','Pairing a phone') end,
      'paired',       coalesce(v_paired,false),
      'listening',    coalesce(v_listening,false),
      'bound',        coalesce(v_bound,false),
      'status_label', case
                        when not v_native then ''
                        when coalesce(v_paired,false) and coalesce(v_listening,false)
                          then public.uic('pay_dev.paired_listening','Paired · Listening on')
                        when coalesce(v_paired,false)
                          then public.uic('pay_dev.paired_not_listening','Paired · Listening off')
                        else public.uic('pay_dev.paired_no','Not paired') end,
      'status_tone',  case when coalesce(v_paired,false) and coalesce(v_listening,false)
                             then 'success'
                           else 'warning' end,
      'status_sub',   case
                        when not v_native then public.uic('pay_dev.web_pair_sub','')
                        when coalesce(v_paired,false) and coalesce(v_listening,false)
                             and coalesce(v_bound,false)
                          then public.uic('pay_dev.paired_listening_sub','')
                        when coalesce(v_paired,false) and coalesce(v_listening,false)
                          then public.uic('pay_dev.paired_no_bind_sub','')
                        when coalesce(v_paired,false)
                          then public.uic('pay_dev.paired_yes_sub','')
                        else public.uic('pay_dev.paired_no_sub','') end,
      'cta_label',    case when not v_native then ''
                        when coalesce(v_paired,false)
                          then public.uic('pay_dev.manage_cta','Manage notification access')
                        else public.uic('pay_dev.pair_cta','Turn on notification access') end,
      -- Shown only when the grant is on but Android never bound the service —
      -- the ColorOS/MIUI case the phone can force from its own side.
      'rebind_label', case when v_native and coalesce(v_listening,false) and not coalesce(v_bound,false)
                        then public.uic('pay_dev.rebind_cta','Restart the listener') else '' end,
      'can_open_settings', v_native),
    'rows',        coalesce(v_rows,'[]'::jsonb),
    'zone_id',     v_zone,
    'date',        v_date
  );
end $$;

-- ── 6. grants: authenticated only, never anon ──────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'payment_alert_device_list(text, text)',
    'payment_alert_device_register(text, text, integer, boolean, boolean, text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  execute 'revoke all on function public._pay_dev_row(public.payment_alert_device, text, date) from public, anon, authenticated';
end $$;

-- ── 7. the QA fixture goes ─────────────────────────────────────────────────
-- proof-2050-phone was a screenshot prop. It made an empty registry look
-- populated, which is exactly how a phone that hears nothing went unnoticed.
delete from public.payment_alerts      where device_id = 'proof-2050-phone';
delete from public.payment_alert_device where device_id = 'proof-2050-phone';

commit;
