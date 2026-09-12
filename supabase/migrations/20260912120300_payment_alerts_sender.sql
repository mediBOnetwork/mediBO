-- CMD #1929 (5-6/9) — sender learning, the no-claim path, the ask, the voice.
--
-- A regular customer pays the same way every month from the same handle. Once
-- one UTR-verified payment has tied that handle to that customer, the NEXT
-- payment does not need a UTR at all — which is the whole reason a partner
-- ever had to chase one.

-- ─── open bills ─────────────────────────────────────────────────────────────
-- "Open bill" is defined exactly as admin_receivables_orders defines it, so
-- the auto-match can never disagree with the receivables screen.
create or replace function public._pa_open_bills(p_customer_id uuid)
returns table(order_id uuid, order_code text, total numeric, paid numeric, remaining numeric)
language sql stable security definer set search_path to 'public' as $$
  select o.id,
         coalesce(nullif(btrim(o.order_code),''),
                  'PO-'||upper(right(replace(o.id::text,'-',''),4))),
         round(coalesce(o.total_amount,0),2),
         round(public.order_paid_amount(o.id),2),
         round(coalesce(o.total_amount,0) - public.order_paid_amount(o.id),2)
    from public.orders o
    join public.pharmacy_profiles pp on pp.user_id = o.user_id
   where pp.id = p_customer_id
     and coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - public.order_paid_amount(o.id),2) > 0
   order by o.created_at;
$$;

-- ─── learning ───────────────────────────────────────────────────────────────
-- Every UTR-verified claim teaches us one sender identity.
create or replace function public._pa_learn_sender(p_alert_id uuid, p_claim_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_cust uuid; v_order uuid; v_prefix text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return; end if;
  if nullif(a.parsed_vpa,'') is null and nullif(a.parsed_sender,'') is null then return; end if;

  select order_id into v_order from public.payment_claims where id = p_claim_id;
  v_cust := public._pa_customer_of_order(coalesce(v_order, a.matched_order_id));
  if v_cust is null then return; end if;

  -- A bank prints a stable prefix on every transfer from the same account
  -- ("UPI/412345…"); the first six digits are the useful part of it.
  v_prefix := left(coalesce(public._pa_digits(a.parsed_utr),''), 6);

  insert into public.customer_payment_senders
    (customer_id, vpa, sender_name, bank_ref_prefix, learned_from_claim_id, confirmed_at)
  values (v_cust, nullif(a.parsed_vpa,''), nullif(a.parsed_sender,''),
          nullif(v_prefix,''), p_claim_id, now())
  on conflict (customer_id, coalesce(lower(vpa),''), coalesce(lower(sender_name),''))
  do update set hit_count = public.customer_payment_senders.hit_count + 1,
                bank_ref_prefix = coalesce(excluded.bank_ref_prefix,
                                           public.customer_payment_senders.bank_ref_prefix),
                learned_from_claim_id = excluded.learned_from_claim_id,
                confirmed_at = now(),
                updated_at = now();
end $$;

-- Who does this alert's sender belong to? Exactly one customer or nobody —
-- a handle two customers both used teaches us nothing.
create or replace function public._pa_sender_customer(p_alert_id uuid)
returns uuid language plpgsql stable security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_ids uuid[];
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return null; end if;

  if nullif(a.parsed_vpa,'') is not null then
    select array_agg(distinct customer_id) into v_ids
      from public.customer_payment_senders
     where lower(btrim(vpa)) = lower(btrim(a.parsed_vpa));
    if coalesce(array_length(v_ids,1),0) = 1 then return v_ids[1]; end if;
    if coalesce(array_length(v_ids,1),0) > 1 then return null; end if;
  end if;

  if nullif(a.parsed_sender,'') is not null then
    select array_agg(distinct customer_id) into v_ids
      from public.customer_payment_senders
     where lower(btrim(sender_name)) = lower(btrim(a.parsed_sender));
    if coalesce(array_length(v_ids,1),0) = 1 then return v_ids[1]; end if;
  end if;

  return null;
end $$;

-- ─── the no-claim path ──────────────────────────────────────────────────────
-- Money arrived and no claim explains it. If we know the sender and they have
-- exactly ONE open bill that the amount fits, the payment books itself.
-- Anything else asks the customer, in their own WhatsApp thread.
create or replace function public._pa_match_by_sender(p_alert_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; v_cust uuid; v_n int;
  b record; v_claim uuid; v_verify jsonb;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;

  v_cust := public._pa_sender_customer(p_alert_id);
  if v_cust is null then
    update public.payment_alerts
       set status = 'unmatched', updated_at = now(),
           match_reason = public.uic('pay_alert.unmatched.none',
                                     'Nothing pending looks like this payment.')
     where id = a.id;
    return public.payment_alert_state(a.id);
  end if;

  update public.payment_alerts set matched_customer_id = v_cust, updated_at = now()
   where id = a.id;

  select count(*)::int into v_n from public._pa_open_bills(v_cust);

  -- Exactly one open bill, and the amount is either the whole of it or a
  -- clean partial of it: that is not a guess, it is arithmetic.
  if v_n = 1 then
    select * into b from public._pa_open_bills(v_cust) limit 1;
    if round(a.parsed_amount,2) <= b.remaining then
      -- A claim row is how a payment exists in this system; write one and
      -- verify it through the same core manual verification uses.
      insert into public.payment_claims
        (sender_type, amount, payee_vpa, payee_name, utr, app, order_id,
         received_at, paid_ts, status, payment_method, zone_id, business_date,
         autolink_note, raw_ocr)
      values ('payment_alert', round(a.parsed_amount,2), nullif(a.parsed_vpa,''),
              nullif(a.parsed_sender,''), nullif(a.parsed_utr,''), a.package_name,
              b.order_id, a.posted_at, a.posted_at, 'claimed', 'online',
              a.zone_id, a.business_date,
              'payment_alert:'||a.id::text,
              jsonb_build_object('source','payment_alert','alert_id',a.id,
                                 'package',a.package_name,'parse_source',a.parse_source))
      returning id into v_claim;

      v_verify := public._payment_claim_verify_core(v_claim, b.order_id, 'auto_payment_alert_sender');
      if coalesce((v_verify->>'ok')::boolean, false) then
        update public.payment_alerts
           set status = 'matched', matched_claim_id = v_claim, matched_order_id = b.order_id,
               match_reason = public.uic('pay_alert.match.sender_bill',
                 'Matched from a known sender to their only open bill'),
               updated_at = now()
         where id = a.id;
        perform public._pa_learn_sender(a.id, v_claim);
        perform public._pa_speak(a.id);
        return public.payment_alert_state(a.id);
      end if;
    end if;
  end if;

  -- We know who paid but not what for. Ask them.
  return public._pa_ask_customer(a.id, v_cust);
end $$;

-- ─── the ask ────────────────────────────────────────────────────────────────
-- "We received ₹X — which order is it for?", with the options resolved here.
create or replace function public._pa_ask_customer(p_alert_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; b record; v_opts jsonb := '[]'::jsonb;
  v_n int := 0; v_body text; v_phone text; v_qid bigint;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;

  for b in select * from public._pa_open_bills(p_customer_id) loop
    v_n := v_n + 1;
    exit when v_n > 5;                    -- a WhatsApp list nobody reads is no list
    v_opts := v_opts || jsonb_build_object(
      'n', v_n, 'order_id', b.order_id, 'order_code', b.order_code,
      'open_amount', b.remaining, 'open_label', public.inr_money_compact(b.remaining),
      'label', replace(replace(replace(
                 public.uic('pay_alert.ask_option_tpl','{n}. {order_code} — {open_label} open'),
                 '{n}', v_n::text), '{order_code}', b.order_code),
                 '{open_label}', public.inr_money_compact(b.remaining)));
  end loop;

  if jsonb_array_length(v_opts) = 0 then
    update public.payment_alerts
       set status = 'unmatched', updated_at = now(),
           match_reason = public.uic('pay_alert.unmatched.none',
                                     'Nothing pending looks like this payment.')
     where id = a.id;
    return public.payment_alert_state(a.id);
  end if;

  select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),
                              '\D','','g'), 10)
    into v_phone from public.pharmacy_profiles pp where pp.id = p_customer_id;

  v_body := replace(public.uic('pay_alert.ask_tpl','We received {amount}. Which order is it for?'),
                    '{amount}', public.inr_money_compact(a.parsed_amount))
          || E'\n' || (select string_agg(o->>'label', E'\n' order by (o->>'n')::int)
                         from jsonb_array_elements(v_opts) o)
          || E'\n' || public.uic('pay_alert.ask_footer','Reply with the number.');

  insert into public.payment_alert_question
    (alert_id, customer_id, phone, amount, options, status)
  values (a.id, p_customer_id, nullif(v_phone,''), a.parsed_amount, v_opts, 'open')
  on conflict (alert_id) where status = 'open' do nothing
  returning id into v_qid;

  update public.payment_alerts
     set status = 'unmatched', updated_at = now(),
         match_reason = public.uic('pay_alert.unmatched.asked',
                                   'Asked the customer which order this is for.')
   where id = a.id;

  if v_qid is not null and nullif(v_phone,'') is not null then
    begin
      perform public.notify('payment_alert_which_order', v_phone,
        jsonb_build_object('customer_id', p_customer_id,
                           'amount', public.inr_money_compact(a.parsed_amount),
                           'options', (select string_agg(o->>'label', E'\n' order by (o->>'n')::int)
                                         from jsonb_array_elements(v_opts) o),
                           'body', v_body,
                           'legacy_url','https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
                           'legacy_body', jsonb_build_object('event','payment_alert_which_order',
                                            'phone', v_phone, 'text', v_body)));
    exception when others then
      perform public._wa_log_attempt('payment_alert_which_order', null, v_phone, 'skipped', false,
                                     'caller_error: ' || sqlerrm, null);
    end;
  end if;

  return public.payment_alert_state(a.id)
    || jsonb_build_object('asked', v_qid is not null, 'options', v_opts, 'ask_body', v_body);
end $$;

-- ─── the reply resolves the match ───────────────────────────────────────────
-- Called from the inbound WhatsApp path BEFORE the assistant classifies, the
-- same way wa_assistant_intent.defer_to hands a question to its owner.
-- Returns ok:false untouched when this feature has no open question, so the
-- assistant carries on exactly as before.
create or replace function public.payment_alert_answer_try(p_phone text, p_text text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  q public.payment_alert_question%rowtype; a public.payment_alerts%rowtype;
  v_ph text; v_pick int; v_opt jsonb; v_claim uuid; v_verify jsonb; v_reply text;
begin
  v_ph := right(regexp_replace(coalesce(p_phone,''), '\D','','g'), 10);
  if coalesce(length(v_ph),0) <> 10 then
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;

  select * into q from public.payment_alert_question
   where phone = v_ph and status = 'open'
     and asked_at > now() - interval '3 days'
   order by asked_at desc limit 1;
  if q.id is null then return jsonb_build_object('ok', false, 'reason','no_open_question'); end if;

  -- The reply is a number from the list, or an order code from it.
  v_pick := nullif(regexp_replace(coalesce(p_text,''), '\D','','g'), '')::int;
  if v_pick is not null then
    select o into v_opt from jsonb_array_elements(q.options) o
     where (o->>'n')::int = v_pick limit 1;
  end if;
  if v_opt is null then
    select o into v_opt from jsonb_array_elements(q.options) o
     where coalesce(p_text,'') ilike '%'||(o->>'order_code')||'%' limit 1;
  end if;

  if v_opt is null then
    return jsonb_build_object('ok', false, 'reason','not_an_option',
      'handled', true, 'question_id', q.id,
      'reply', public.uic('pay_alert.ask_badnumber',
        'That number is not on the list. Please reply with one of the numbers above.'));
  end if;

  select * into a from public.payment_alerts where id = q.alert_id;
  if a.id is null then
    update public.payment_alert_question set status='cancelled' where id = q.id;
    return jsonb_build_object('ok', false, 'reason','alert_gone');
  end if;

  insert into public.payment_claims
    (sender_type, amount, payee_vpa, payee_name, utr, app, order_id,
     received_at, paid_ts, status, payment_method, zone_id, business_date,
     autolink_note, raw_ocr)
  values ('payment_alert', round(coalesce(a.parsed_amount, q.amount),2), nullif(a.parsed_vpa,''),
          nullif(a.parsed_sender,''), nullif(a.parsed_utr,''), a.package_name,
          (v_opt->>'order_id')::uuid, a.posted_at, a.posted_at, 'claimed', 'online',
          a.zone_id, a.business_date, 'payment_alert:'||a.id::text,
          jsonb_build_object('source','payment_alert_reply','alert_id',a.id,
                             'question_id',q.id,'package',a.package_name))
  returning id into v_claim;

  v_verify := public._payment_claim_verify_core(v_claim, (v_opt->>'order_id')::uuid,
                'auto_payment_alert_reply');
  if not coalesce((v_verify->>'ok')::boolean, false) then
    delete from public.payment_claims where id = v_claim;
    return jsonb_build_object('ok', false, 'reason','verify_failed', 'handled', true,
      'question_id', q.id,
      'reply', public.uic('pay_alert.ask_badnumber',
        'That number is not on the list. Please reply with one of the numbers above.'));
  end if;

  update public.payment_alert_question
     set status='answered', answered_at = now(), answer_text = left(coalesce(p_text,''),200),
         chosen_order_id = (v_opt->>'order_id')::uuid
   where id = q.id;

  update public.payment_alerts
     set status = 'matched', matched_claim_id = v_claim,
         matched_order_id = (v_opt->>'order_id')::uuid,
         matched_customer_id = coalesce(q.customer_id, matched_customer_id),
         match_reason = public.uic('pay_alert.match.customer_reply',
                                   'Matched by the customer''s own reply'),
         updated_at = now()
   where id = a.id;

  perform public._pa_learn_sender(a.id, v_claim);
  perform public._pa_speak(a.id);

  v_reply := replace(replace(
    public.uic('pay_alert.ask_thanks_tpl','Thank you — {amount} is now recorded against {order_code}.'),
    '{amount}', public.inr_money_compact(coalesce(a.parsed_amount, q.amount))),
    '{order_code}', coalesce(v_opt->>'order_code',''));

  return jsonb_build_object('ok', true, 'handled', true, 'question_id', q.id,
    'alert_id', a.id, 'claim_id', v_claim, 'order_id', (v_opt->>'order_id')::uuid,
    'reply', v_reply);
end $$;

-- ─── the voice ──────────────────────────────────────────────────────────────
-- The sentence the partner phone speaks is built HERE. Dart plays a string.
-- inr_money_compact, not inr_money: a voice saying "five hundred rupees and
-- zero zero paise" is worse than one saying "five hundred rupees", and the
-- spec's own example is "₹500 received from Pooja Medical".
create or replace function public._pa_speak(p_alert_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; v_msg text; v_sender text; v_pid bigint;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null or a.parsed_amount is null then return; end if;

  -- The customer's own name beats the handle the bank printed.
  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_sender
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  v_sender := coalesce(nullif(v_sender,''), nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''));

  if nullif(v_sender,'') is null then
    v_msg := replace(public.uic('pay_alert.speak_tpl_nosender','{amount} received'),
                     '{amount}', public.inr_money_compact(a.parsed_amount));
  else
    v_msg := replace(replace(
               public.uic('pay_alert.speak_tpl','{amount} received from {sender}'),
               '{amount}', public.inr_money_compact(a.parsed_amount)),
               '{sender}', v_sender);
  end if;

  select p.id into v_pid from public.region_partners p
   where p.zone_id = a.zone_id order by p.id limit 1;

  insert into public.payment_alert_speak
    (alert_id, claim_id, order_id, customer_id, zone_id, partner_id, message, amount)
  values (a.id, a.matched_claim_id, a.matched_order_id, a.matched_customer_id,
          a.zone_id, v_pid, v_msg, a.parsed_amount);
end $$;

-- What the partner app pulls (or receives over realtime) and speaks.
create or replace function public.payment_alert_speak_pull(p_limit int default 5)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_zone smallint; v_rows jsonb; v_ids bigint[];
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false) or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());

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
  end if;

  return jsonb_build_object('ok', true, 'rows', coalesce(v_rows,'[]'::jsonb),
                            'count', coalesce(array_length(v_ids,1),0));
end $$;

-- The WhatsApp route for the ask. Disabled-by-default routes are how every
-- other event ships; the copy lives in ui_copy either way.
insert into public.wa_event_routes (event_key, label, description, audience, enabled)
values ('payment_alert_which_order',
        'Payment received — which order?',
        'Sent when money arrives from a known sender and more than one of their bills could be it.',
        'customer', true)
on conflict (event_key) do update set
  label = excluded.label, description = excluded.description,
  audience = excluded.audience, updated_at = now();

revoke all on function public.payment_alert_answer_try(text, text) from anon, authenticated;
revoke all on function public._pa_match_by_sender(uuid) from anon, authenticated;
revoke all on function public._pa_ask_customer(uuid, uuid) from anon, authenticated;
grant execute on function public.payment_alert_speak_pull(int) to authenticated;
