-- CMD #2050 — Payment alerts made usable: the DEVICE registry doors.
--
-- #1931 built payment_alert_device and the per-phone card, but the only way a
-- row could ever appear was payment_listener_report() — a call the Money-home
-- card makes and nothing else. Live had ZERO device rows. This migration gives
-- the registry its own three doors, named the way the feature is spoken about:
--
--   payment_alert_device_register(p_device, p_label, p_zone_id)
--   payment_alert_device_list(p_device, p_platform)
--   payment_alert_device_set(p_device, listener_enabled, speak_enabled, volume)
--
-- Every word, tone, chip and empty state below is a ui_copy key: the Devices
-- section on the Payment alerts screen prints what these return and computes
-- nothing. Zone- and date-scoped throughout: the list reads partner_zone_id()
-- then admin_active_zone(), and "heard today" counts alerts on
-- admin_active_date(). Read-only on web is a BACKEND fact (can_edit), decided
-- from the platform the caller reports, not from a Dart branch.
--
-- Idempotent: the direct deploy replays this file on live once.
begin;

-- ── copy ────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('pay_dev.section_title',   to_jsonb('Devices'::text)),
  ('pay_dev.section_sub',     to_jsonb('The phones that listen for payments in this zone.'::text)),
  ('pay_dev.count_one',       to_jsonb('1 phone paired'::text)),
  ('pay_dev.count_many',      to_jsonb('{n} phones paired'::text)),
  ('pay_dev.count_none',      to_jsonb('No phone paired yet'::text)),
  ('pay_dev.empty_label',     to_jsonb('No phone is listening yet'::text)),
  ('pay_dev.empty_hint',      to_jsonb('Open mediBO on the shop phone and turn on notification access — it pairs itself.'::text)),
  ('pay_dev.paired_title',    to_jsonb('This phone'::text)),
  ('pay_dev.paired_yes',      to_jsonb('Paired'::text)),
  ('pay_dev.paired_no',       to_jsonb('Not paired'::text)),
  ('pay_dev.paired_yes_sub',  to_jsonb('This phone is registered and listening for payments.'::text)),
  ('pay_dev.paired_no_sub',   to_jsonb('Turn on notification access to pair this phone.'::text)),
  ('pay_dev.pair_cta',        to_jsonb('Turn on notification access'::text)),
  ('pay_dev.manage_cta',      to_jsonb('Manage notification access'::text)),
  ('pay_dev.web_note',        to_jsonb('Pairing happens on the mediBO Android app. On the web this list is read-only.'::text)),
  ('pay_dev.listener_label',  to_jsonb('Listening'::text)),
  ('pay_dev.listener_on',     to_jsonb('On'::text)),
  ('pay_dev.listener_off',    to_jsonb('Off'::text)),
  ('pay_dev.speak_label',     to_jsonb('Speak the amount'::text)),
  ('pay_dev.speak_on',        to_jsonb('On'::text)),
  ('pay_dev.speak_off',       to_jsonb('Muted'::text)),
  ('pay_dev.volume_label',    to_jsonb('Volume'::text)),
  ('pay_dev.last_seen_fmt',   to_jsonb('Last seen {when}'::text)),
  ('pay_dev.last_seen_never', to_jsonb('Never seen'::text)),
  ('pay_dev.last_alert_fmt',  to_jsonb('Last payment {when}'::text)),
  ('pay_dev.last_alert_none', to_jsonb('No payment heard yet'::text)),
  ('pay_dev.today_fmt',       to_jsonb('{n} heard on {date}'::text)),
  ('pay_dev.today_none',      to_jsonb('Nothing heard on {date}'::text)),
  ('pay_dev.this_device',     to_jsonb('This phone'::text)),
  ('pay_dev.unnamed',         to_jsonb('Unnamed phone'::text)),
  ('pay_dev.version_fmt',     to_jsonb('App {v}'::text)),
  ('pay_dev.registered',      to_jsonb('This phone is paired.'::text)),
  ('pay_dev.saved',           to_jsonb('Saved.'::text)),
  ('pay_dev.bad_request',     to_jsonb('A device id is required.'::text)),
  ('pay_dev.not_found',       to_jsonb('That phone is not paired.'::text)),
  ('pay_dev.not_authorized',  to_jsonb('Only a partner or an admin can manage payment devices.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── who may open these doors ────────────────────────────────────────────────
create or replace function public._pay_dev_allowed()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select auth.uid() is not null
     and (coalesce(public.is_partner(), false)
          or coalesce(public.get_my_role(), '') in ('admin','super_admin'));
$$;

-- ── one device row, rendered ────────────────────────────────────────────────
create or replace function public._pay_dev_row(
  d public.payment_alert_device, p_device text, p_date date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_today int; v_datelbl text;
begin
  select count(*) into v_today
    from public.payment_alerts a
   where a.device_id = d.device_id
     and a.business_date = p_date;

  v_datelbl := to_char(p_date, 'DD Mon');

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
    'speak_label',    public.uic('pay_dev.speak_label','Speak the amount'),
    'speak_on',       coalesce(d.speak_enabled,true),
    'speak_state',    case when coalesce(d.speak_enabled,true)
                        then public.uic('pay_dev.speak_on','On')
                        else public.uic('pay_dev.speak_off','Muted') end,
    'volume',         coalesce(d.volume,100),
    'volume_label',   public.uic('pay_dev.volume_label','Volume'),
    'last_seen',      case when d.last_seen_at is null
                        then public.uic('pay_dev.last_seen_never','Never seen')
                        else replace(public.uic('pay_dev.last_seen_fmt','Last seen {when}'), '{when}',
                             to_char(d.last_seen_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am')) end,
    'last_alert',     case when d.last_alert_at is null
                        then public.uic('pay_dev.last_alert_none','No payment heard yet')
                        else replace(public.uic('pay_dev.last_alert_fmt','Last payment {when}'), '{when}',
                             to_char(d.last_alert_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am')) end,
    'today_label',    case when v_today > 0
                        then replace(replace(public.uic('pay_dev.today_fmt','{n} heard on {date}'),
                                             '{n}', v_today::text), '{date}', v_datelbl)
                        else replace(public.uic('pay_dev.today_none','Nothing heard on {date}'),
                                     '{date}', v_datelbl) end,
    'today_count',    v_today,
    'version_label',  case when coalesce(btrim(coalesce(d.app_version,'')),'') = '' then ''
                        else replace(public.uic('pay_dev.version_fmt','App {v}'), '{v}', d.app_version) end,
    'zone_id',        d.zone_id
  );
end $$;

-- ── the list ────────────────────────────────────────────────────────────────
create or replace function public.payment_alert_device_list(
  p_device text default null, p_platform text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_zone smallint; v_date date; v_plat text := lower(btrim(coalesce(p_platform,'')));
  v_rows jsonb; v_n int; v_me text := btrim(coalesce(p_device,''));
  v_paired boolean; v_edit boolean;
begin
  if not public._pay_dev_allowed() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_dev.not_authorized',''));
  end if;

  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());
  v_date := coalesce(public.admin_active_date(), (now() at time zone 'Asia/Kolkata')::date);
  -- Web cannot pair or change a phone's own switches: that is decided here.
  v_edit := (v_plat = 'android');

  select coalesce(jsonb_agg(public._pay_dev_row(d, v_me, v_date)
                            order by (d.device_id = v_me) desc, d.last_seen_at desc nulls last),
                  '[]'::jsonb),
         count(*)
    into v_rows, v_n
  from public.payment_alert_device d
  where (v_zone is null or d.zone_id = v_zone);

  v_paired := v_me <> '' and exists (
    select 1 from public.payment_alert_device d where d.device_id = v_me);

  return jsonb_build_object(
    'ok', true,
    'title',       public.uic('pay_dev.section_title','Devices'),
    'subtitle',    public.uic('pay_dev.section_sub',''),
    'count_label', case when v_n = 0 then public.uic('pay_dev.count_none','No phone paired yet')
                        when v_n = 1 then public.uic('pay_dev.count_one','1 phone paired')
                        else replace(public.uic('pay_dev.count_many','{n} phones paired'),
                                     '{n}', v_n::text) end,
    'count',       v_n,
    'can_edit',    v_edit,
    'note',        case when v_edit then '' else public.uic('pay_dev.web_note','') end,
    'empty_label', public.uic('pay_dev.empty_label',''),
    'empty_hint',  public.uic('pay_dev.empty_hint',''),
    'pairing', jsonb_build_object(
      'title',        public.uic('pay_dev.paired_title','This phone'),
      'paired',       coalesce(v_paired,false),
      'status_label', case when coalesce(v_paired,false)
                        then public.uic('pay_dev.paired_yes','Paired')
                        else public.uic('pay_dev.paired_no','Not paired') end,
      'status_tone',  case when coalesce(v_paired,false) then 'success' else 'warning' end,
      'status_sub',   case when coalesce(v_paired,false)
                        then public.uic('pay_dev.paired_yes_sub','')
                        else public.uic('pay_dev.paired_no_sub','') end,
      'cta_label',    case when not v_edit then ''
                        when coalesce(v_paired,false)
                          then public.uic('pay_dev.manage_cta','Manage notification access')
                        else public.uic('pay_dev.pair_cta','Turn on notification access') end,
      'can_open_settings', v_edit),
    'rows',        coalesce(v_rows,'[]'::jsonb),
    'zone_id',     v_zone,
    'date',        v_date
  );
end $$;

-- ── register ────────────────────────────────────────────────────────────────
-- The phone's FIRST call, made on launch. It creates the row that #1931's
-- report/card/speak chain has always assumed and never created.
create or replace function public.payment_alert_device_register(
  p_device text, p_label text default null, p_zone_id integer default null)
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
    (device_id, label, zone_id, user_id, last_seen_at, updated_at)
  values (v_dev, nullif(btrim(coalesce(p_label,'')),''), v_zone, auth.uid(), now(), now())
  on conflict (device_id) do update set
    label        = coalesce(nullif(btrim(coalesce(p_label,'')),''), public.payment_alert_device.label),
    zone_id      = coalesce(excluded.zone_id, public.payment_alert_device.zone_id),
    user_id      = coalesce(excluded.user_id, public.payment_alert_device.user_id),
    last_seen_at = now(),
    updated_at   = now();

  return jsonb_build_object('ok', true, 'device_id', v_dev, 'zone_id', v_zone,
                            'toast', public.uic('pay_dev.registered','This phone is paired.'));
end $$;

-- ── set ─────────────────────────────────────────────────────────────────────
create or replace function public.payment_alert_device_set(
  p_device text,
  p_listener_enabled boolean default null,
  p_speak_enabled boolean default null,
  p_volume integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_dev text := btrim(coalesce(p_device,'')); v_hit int;
begin
  if not public._pay_dev_allowed() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_dev.not_authorized',''));
  end if;
  if v_dev = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_dev.bad_request','A device id is required.'));
  end if;

  update public.payment_alert_device d set
    listener_enabled = coalesce(p_listener_enabled, d.listener_enabled),
    speak_enabled    = coalesce(p_speak_enabled, d.speak_enabled),
    volume           = least(greatest(coalesce(p_volume, d.volume), 0), 100)::smallint,
    updated_at       = now()
  where d.device_id = v_dev;
  get diagnostics v_hit = row_count;

  if v_hit = 0 then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_dev.not_found','That phone is not paired.'));
  end if;

  return jsonb_build_object('ok', true, 'device_id', v_dev,
                            'toast', public.uic('pay_dev.saved','Saved.'));
end $$;

-- ── grants: authenticated only, never anon ─────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'payment_alert_device_list(text, text)',
    'payment_alert_device_register(text, text, integer)',
    'payment_alert_device_set(text, boolean, boolean, integer)'
  ] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
  execute 'revoke all on function public._pay_dev_allowed() from public, anon, authenticated';
  execute 'revoke all on function public._pay_dev_row(public.payment_alert_device, text, date) from public, anon, authenticated';
end $$;

commit;
