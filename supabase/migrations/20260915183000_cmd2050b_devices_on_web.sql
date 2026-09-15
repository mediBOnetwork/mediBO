-- CMD #2050b — the Devices section is a WEB surface too.
--
-- The first cut of payment_alert_device_list() answered can_edit=false for any
-- caller that was not the Android app, which made the whole section read-only
-- on the web. That is wrong, and it is wrong in the BACKEND, which is where it
-- is fixed: only the LISTENER itself is device-local — it is an Android grant,
-- and no screen anywhere can switch it on for a phone that is not the phone in
-- your hand. Everything else about a paired device is a server-side setting the
-- phone obeys, so an admin on a laptop edits it exactly like an admin on a
-- phone.
--
-- So editability is now decided PER FIELD, per row, and shipped as flags:
--   speak_editable / volume_editable  — true for any authorised caller
--   listener_editable                 — only from that device, on Android
--   listener_note                     — why, worded here, when it is not
--   pairing.can_open_settings         — Android only; the web card explains it
-- Idempotent; replayed once on live by the direct deploy.
begin;

insert into public.ui_copy (key, value) values
  ('pay_dev.listener_note',  to_jsonb('Only this phone can switch listening on — it is an Android permission.'::text)),
  ('pay_dev.web_note',       to_jsonb('Listening is switched on from the phone itself. Everything else here can be changed from any device.'::text)),
  ('pay_dev.web_pair_sub',   to_jsonb('Open mediBO on the shop phone to pair it and turn on notification access.'::text)),
  ('pay_dev.web_pair_title', to_jsonb('Pairing a phone'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function public._pay_dev_row(
  d public.payment_alert_device, p_device text, p_date date)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_today int; v_datelbl text; v_me boolean;
begin
  select count(*) into v_today
    from public.payment_alerts a
   where a.device_id = d.device_id
     and a.business_date = p_date;

  v_datelbl := to_char(p_date, 'DD Mon');
  v_me := coalesce(btrim(coalesce(p_device,'')),'') <> ''
          and d.device_id = btrim(coalesce(p_device,''));

  return jsonb_build_object(
    'device_id',      d.device_id,
    'is_this_device', v_me,
    'label',          coalesce(nullif(btrim(coalesce(d.label,'')),''),
                               public.uic('pay_dev.unnamed','Unnamed phone')),
    'this_label',     public.uic('pay_dev.this_device','This phone'),
    'status_label',   case when coalesce(d.listener_enabled,false)
                        then public.uic('pay_dev.listener_on','On')
                        else public.uic('pay_dev.listener_off','Off') end,
    'status_tone',    case when coalesce(d.listener_enabled,false) then 'success' else 'warning' end,
    'listener_label', public.uic('pay_dev.listener_label','Listening'),
    'listener_on',    coalesce(d.listener_enabled,false),
    -- The one device-local switch in the feature. Everything else travels.
    'listener_editable', v_me,
    'listener_note',  case when v_me then ''
                        else public.uic('pay_dev.listener_note','') end,
    'speak_label',    public.uic('pay_dev.speak_label','Speak the amount'),
    'speak_on',       coalesce(d.speak_enabled,true),
    'speak_state',    case when coalesce(d.speak_enabled,true)
                        then public.uic('pay_dev.speak_on','On')
                        else public.uic('pay_dev.speak_off','Muted') end,
    'speak_editable', true,
    'volume',         coalesce(d.volume,100),
    'volume_label',   public.uic('pay_dev.volume_label','Volume'),
    'volume_editable', true,
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

create or replace function public.payment_alert_device_list(
  p_device text default null, p_platform text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_zone smallint; v_date date; v_plat text := lower(btrim(coalesce(p_platform,'')));
  v_rows jsonb; v_n int; v_me text := btrim(coalesce(p_device,''));
  v_paired boolean; v_native boolean;
begin
  if not public._pay_dev_allowed() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_dev.not_authorized',''));
  end if;

  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());
  v_date := coalesce(public.admin_active_date(), (now() at time zone 'Asia/Kolkata')::date);
  -- "Native" = this caller can host the listener and open Android's settings.
  -- It is NOT what decides whether the section is editable: see _pay_dev_row.
  v_native := (v_plat = 'android');

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
    -- The section itself is editable for every authorised caller, on every
    -- platform. Per-field flags on each row say what travels and what does not.
    'can_edit',    true,
    'is_native',   v_native,
    'note',        case when v_native then '' else public.uic('pay_dev.web_note','') end,
    'empty_label', public.uic('pay_dev.empty_label',''),
    'empty_hint',  public.uic('pay_dev.empty_hint',''),
    'pairing', jsonb_build_object(
      'title',        case when v_native then public.uic('pay_dev.paired_title','This phone')
                        else public.uic('pay_dev.web_pair_title','Pairing a phone') end,
      'paired',       coalesce(v_paired,false),
      'status_label', case when not v_native then ''
                        when coalesce(v_paired,false)
                          then public.uic('pay_dev.paired_yes','Paired')
                        else public.uic('pay_dev.paired_no','Not paired') end,
      'status_tone',  case when coalesce(v_paired,false) then 'success' else 'warning' end,
      'status_sub',   case when not v_native then public.uic('pay_dev.web_pair_sub','')
                        when coalesce(v_paired,false)
                          then public.uic('pay_dev.paired_yes_sub','')
                        else public.uic('pay_dev.paired_no_sub','') end,
      'cta_label',    case when not v_native then ''
                        when coalesce(v_paired,false)
                          then public.uic('pay_dev.manage_cta','Manage notification access')
                        else public.uic('pay_dev.pair_cta','Turn on notification access') end,
      'can_open_settings', v_native),
    'rows',        coalesce(v_rows,'[]'::jsonb),
    'zone_id',     v_zone,
    'date',        v_date
  );
end $$;

do $$
begin
  execute 'revoke all on function public.payment_alert_device_list(text, text) from public, anon';
  execute 'grant execute on function public.payment_alert_device_list(text, text) to authenticated, service_role';
  execute 'revoke all on function public._pay_dev_row(public.payment_alert_device, text, date) from public, anon, authenticated';
end $$;

commit;
