-- CMD #2093 (b) — the two switches, the header, and an accepted credit that
-- announces itself. Every string below is ui_copy; Dart renders, never words.

-- ── 0. Copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('pay_alert.apps_title',    to_jsonb('Which apps to listen to'::text)),
  ('pay_alert.apps_hint',     to_jsonb('Off means this phone never even reads that app. Business apps hear real shop payments; the consumer apps also announce ads and chats.'::text)),
  ('pay_alert.apps_empty',    to_jsonb('No payment apps configured yet.'::text)),
  ('pay_alert.apps_count_tpl',to_jsonb('{on} of {n} apps on'::text)),
  ('pay_alert.kind.business', to_jsonb('Business apps'::text)),
  ('pay_alert.kind.bank',     to_jsonb('Bank apps'::text)),
  ('pay_alert.kind.consumer', to_jsonb('Personal apps'::text)),
  ('pay_alert.kind.any',      to_jsonb('Every other app'::text)),
  ('pay_alert.app_on',        to_jsonb('On'::text)),
  ('pay_alert.app_off',       to_jsonb('Off'::text)),
  ('pay_alert.apps_denied',   to_jsonb('Only an admin can change which apps are listened to.'::text)),
  ('pay_alert.utr_title',     to_jsonb('Look for UTR'::text)),
  ('pay_alert.utr_hint_on',   to_jsonb('On: a notification without a UTR, Ref or RRN is dropped and never shown.'::text)),
  ('pay_alert.utr_hint_off',  to_jsonb('Off: every credit that is read is shown, with or without a reference.'::text)),
  ('pay_alert.utr_saved',     to_jsonb('Saved.'::text)),
  ('pay_alert.ignored.no_utr',to_jsonb('No reference number in the notification.'::text)),
  ('pay_alert.ignored.no_rule',to_jsonb('No rule listens to this app.'::text)),
  ('pay_alert.header_title',  to_jsonb('How money is collected'::text)),
  ('pay_alert.header_upi',    to_jsonb('UPI ID'::text)),
  ('pay_alert.header_upi_none', to_jsonb('No UPI ID is active'::text)),
  ('pay_alert.notify_tpl',    to_jsonb('You received {amount} from {sender}'::text)),
  ('pay_alert.notify_tpl_nosender', to_jsonb('You received {amount}'::text)),
  ('pay_alert.notify_title',  to_jsonb('Payment received'::text))
on conflict (key) do nothing;

-- ── 1. Why an alert was dropped, as a machine word ──────────────────────────
alter table public.payment_alerts
  add column if not exists ignore_reason text;

-- The notification line travels with the spoken one.
alter table public.payment_alert_speak
  add column if not exists notify_title text,
  add column if not exists notify_body  text;

-- ── 2. Speak on EVERY accepted credit, not only a matched one ───────────────
-- Until today _pa_speak only ran from payment_alert_match's success branch, so
-- a real ₹500 that found no open claim was silent — and that is most of them.
-- It is now called for every credit the rules accept, it refuses to say the
-- same alert twice, and it carries the notification wording with it.
create or replace function public._pa_speak(p_alert_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; v_msg text; v_sender text; v_pid bigint;
  v_title text; v_body text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null or a.parsed_amount is null then return; end if;
  -- One announcement per alert: match runs after ingest already spoke.
  if exists (select 1 from public.payment_alert_speak s where s.alert_id = a.id) then
    return;
  end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_sender
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  v_sender := coalesce(nullif(v_sender,''), nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''));

  if nullif(v_sender,'') is null then
    v_msg := replace(public.uic('pay_alert.speak_tpl_nosender','{amount} received'),
                     '{amount}', public.inr_money_compact(a.parsed_amount));
    v_body := replace(public.uic('pay_alert.notify_tpl_nosender','You received {amount}'),
                     '{amount}', public.inr_money_compact(a.parsed_amount));
  else
    v_msg := replace(replace(
               public.uic('pay_alert.speak_tpl','{amount} received from {sender}'),
               '{amount}', public.inr_money_compact(a.parsed_amount)),
               '{sender}', v_sender);
    v_body := replace(replace(
               public.uic('pay_alert.notify_tpl','You received {amount} from {sender}'),
               '{amount}', public.inr_money_compact(a.parsed_amount)),
               '{sender}', v_sender);
  end if;
  v_title := public.uic('pay_alert.notify_title','Payment received');

  select p.id into v_pid from public.region_partners p
   where p.zone_id = a.zone_id order by p.id limit 1;

  insert into public.payment_alert_speak
    (alert_id, claim_id, order_id, customer_id, zone_id, partner_id, message, amount,
     notify_title, notify_body)
  values (a.id, a.matched_claim_id, a.matched_order_id, a.matched_customer_id,
          a.zone_id, v_pid, v_msg, a.parsed_amount, v_title, v_body);
end $$;

-- ── 3. The pull hands the notification down too ─────────────────────────────
create or replace function public.payment_alert_speak_pull(p_limit integer DEFAULT 5,
                                                           p_device text DEFAULT NULL)
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
           -- The phone notification, worded here. A phone that cannot speak
           -- (silent, no TTS) still sees the money arrive.
           'notify_title', coalesce(nullif(s.notify_title,''),
                                    public.uic('pay_alert.notify_title','Payment received')),
           'notify_body',  coalesce(nullif(s.notify_body,''), s.message),
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

-- ── 4. Ingest: the UTR gate, and announcing every accepted credit ───────────
create or replace function public._pa_ingest_core(p_device text, p_package text,
  p_title text, p_text text, p_posted_at timestamptz, p_zone smallint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id uuid; v_md5 text; v_posted timestamptz; v_parse jsonb;
  v_utr_on boolean; v_utr text;
begin
  if coalesce(btrim(p_device),'') = '' or coalesce(btrim(p_package),'') = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_alert.bad_request','A device id and a package name are required.'));
  end if;

  v_posted := coalesce(p_posted_at, now());
  v_md5    := md5(coalesce(p_text,''));

  insert into public.payment_alerts
    (device_id, package_name, raw_title, raw_text, posted_at, text_md5, zone_id, business_date, status)
  values
    (btrim(p_device), btrim(p_package), nullif(btrim(coalesce(p_title,'')),''),
     p_text, v_posted, v_md5, p_zone,
     (v_posted at time zone 'Asia/Kolkata')::date, 'new')
  on conflict (device_id, package_name, posted_at, text_md5) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.payment_alerts
     where device_id = btrim(p_device) and package_name = btrim(p_package)
       and posted_at = v_posted and text_md5 = v_md5;
    return public.payment_alert_state(v_id) || jsonb_build_object('duplicate', true);
  end if;

  v_parse := public.payment_alert_parse_rules(btrim(p_package), p_title, p_text);

  if (v_parse->>'ok')::boolean then
    v_utr := nullif(v_parse->>'utr','');
    select coalesce(c.look_for_utr, true) into v_utr_on
      from public.payment_listener_config c where c.id;
    v_utr_on := coalesce(v_utr_on, true);

    -- The switch that killed the ₹50,000 ad: money with no reference number
    -- is not a payment anyone can find later, so it never reaches the queue.
    if v_utr_on and v_utr is null then
      update public.payment_alerts
         set status = 'ignored', parse_source = 'rule',
             parsed_amount = nullif(v_parse->>'amount','')::numeric,
             parsed_vpa    = nullif(v_parse->>'vpa',''),
             parsed_sender = nullif(v_parse->>'sender',''),
             parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
             parse_note    = public.uic('pay_alert.ignored.no_utr',
                                        'No reference number in the notification.'),
             ignore_reason = 'no_utr',
             updated_at    = now()
       where id = v_id;
      return public.payment_alert_state(v_id);
    end if;

    update public.payment_alerts
       set parsed_amount = nullif(v_parse->>'amount','')::numeric,
           parsed_utr    = v_utr,
           parsed_vpa    = nullif(v_parse->>'vpa',''),
           parsed_sender = nullif(v_parse->>'sender',''),
           parse_source  = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note    = nullif(v_parse->>'rule_label',''),
           updated_at    = now()
     where id = v_id;
    -- Announce it BEFORE matching: a real ₹500 that finds no open claim is
    -- still money that arrived, and the phone stayed silent for all of them.
    perform public._pa_speak(v_id);
    perform public.payment_alert_match(v_id);

  elsif (v_parse->>'reason') in ('not_credit','no_rule_matched') then
    -- An app with no rule of its own is no longer guessed at by AI.
    update public.payment_alerts
       set status = 'ignored', parse_source = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note = case when (v_parse->>'reason') = 'not_credit'
                             then public.uic('pay_alert.ignored.not_credit','Not money coming in.')
                             else public.uic('pay_alert.ignored.no_rule','No rule listens to this app.') end,
           ignore_reason = v_parse->>'reason',
           updated_at = now()
     where id = v_id;

  else
    update public.payment_alerts
       set parse_note = v_parse->>'reason', updated_at = now()
     where id = v_id;
    perform public._pa_ai_enqueue(v_id);
  end if;

  return public.payment_alert_state(v_id);
end $$;
