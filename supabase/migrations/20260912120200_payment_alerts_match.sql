-- CMD #1929 (4/9) — matching, and ONE verify path shared with manual verify.
--
-- The whole point of this command: a manual UPI payment verifies itself.
-- So the auto path must not be a second, nearly-identical verify — it must be
-- the SAME code manual verification runs, or the two will drift.
-- mark_payment_received() keeps its admin guard and its signature and now
-- calls the core below; the alert matcher calls the same core.

-- ─── the ONE verify core ────────────────────────────────────────────────────
-- Everything manual verification did — claim → verified, order → accepted,
-- the customer WhatsApp/notification event — lives here now and nowhere else.
create or replace function public._payment_claim_verify_core(
  p_claim_id uuid, p_order_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_amt numeric; v_utr text; v_app text; v_paid text; v jsonb;
begin
  update public.payment_claims
     set order_id = p_order_id, status = 'verified', verify_reason = p_reason
   where id = p_claim_id
  returning amount, utr, app, paid_at into v_amt, v_utr, v_app, v_paid;

  if not found then
    return jsonb_build_object('ok', false, 'error','not_found');
  end if;

  -- Manual verify accepted the order too (verify_and_accept_payment); the
  -- auto path must land in the same state.
  update public.orders set status = 'accepted'
   where id = p_order_id and status <> 'accepted';

  begin
    v := public.notify('payment_received_online', public._order_customer_phone(p_order_id),
           jsonb_build_object(
             'order_id',    p_order_id,
             'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
             'legacy_body', jsonb_build_object('order_id', p_order_id::text, 'event','payment_received',
                              'amount', coalesce(v_amt,0), 'utr', coalesce(v_utr,''),
                              'app', coalesce(v_app,''), 'paid_at', coalesce(v_paid,''))));
  exception when others then
    perform public._wa_log_attempt('payment_received_online', p_order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm, null);
  end;

  return jsonb_build_object('ok', true, 'claim_id', p_claim_id, 'order_id', p_order_id,
                            'amount', v_amt, 'notify', v);
end $$;

-- Manual verification: same guard, same check, same signature, same result —
-- the body is now the shared core.
create or replace function public.mark_payment_received(p_claim_id uuid, p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_chk jsonb;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;
  v_chk := public.payment_claim_match_check(p_claim_id, p_order_id);
  if (v_chk->>'blocked')::boolean
     and not exists (select 1 from public.payment_claims
                      where id = p_claim_id and order_id = p_order_id) then
    raise exception '%', coalesce(v_chk->>'message', v_chk->>'reason');
  end if;
  return public._payment_claim_verify_core(p_claim_id, p_order_id, 'manual_received');
end $$;

-- ─── what the app renders for one alert ─────────────────────────────────────
-- Every label, tone and money string is built here. Dart prints it.
create or replace function public.payment_alert_state(p_alert_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; v_rule text; v_cust text; v_code text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_alert.not_found','That payment alert is gone.'));
  end if;

  select coalesce(label, package_name) into v_rule
    from public.payment_alert_rules where id = a.parse_rule_id;
  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_cust
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  select coalesce(nullif(btrim(o.order_code),''),
                  'PO-'||upper(right(replace(o.id::text,'-',''),4)))
    into v_code from public.orders o where o.id = a.matched_order_id;

  return jsonb_build_object(
    'ok', true,
    'alert_id',      a.id,
    'status',        a.status,
    'status_label',  public.uic('pay_alert.status.'||a.status, initcap(a.status)),
    'status_tone',   case a.status when 'matched' then 'success'
                                   when 'unmatched' then 'warning'
                                   when 'ignored' then 'muted'
                                   else 'info' end,
    'source',        a.parse_source,
    'source_label',  public.uic('pay_alert.source.'||a.parse_source, a.parse_source),
    'rule_label',    coalesce(v_rule, ''),
    'app_label',     coalesce(v_rule, a.package_name),
    'amount',        a.parsed_amount,
    'amount_label',  case when a.parsed_amount is null
                          then public.uic('pay_alert.no_amount','No amount read')
                          else public.inr_money(a.parsed_amount) end,
    'utr_label',     coalesce(nullif(a.parsed_utr,''),
                              public.uic('pay_alert.no_utr','No UTR in the notification')),
    'has_utr',       nullif(a.parsed_utr,'') is not null,
    'sender_label',  coalesce(nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''),
                              public.uic('pay_alert.no_sender','Sender not named')),
    'vpa',           coalesce(a.parsed_vpa,''),
    'raw_title',     coalesce(a.raw_title,''),
    'raw_text',      coalesce(a.raw_text,''),
    'posted_label',  to_char(a.posted_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am'),
    'match_reason',  coalesce(a.match_reason, a.parse_note, ''),
    -- Both buttons on the card. Absent on a matched row, because a verified
    -- payment is not re-matched or ignored from this screen.
    'retry_match_label', case when a.status = 'matched' then ''
                              else public.uic('pay_alert.retry_match','Match again') end,
    'ignore_label',      case when a.status = 'matched' then ''
                              else public.uic('pay_alert.ignore','Ignore') end,
    'claim_id',      a.matched_claim_id,
    'order_id',      a.matched_order_id,
    'order_code',    coalesce(v_code,''),
    'customer_id',   a.matched_customer_id,
    'customer_label',coalesce(nullif(v_cust,''), ''),
    'zone_id',       a.zone_id,
    'business_date', a.business_date);
end $$;

-- ─── candidate pool ─────────────────────────────────────────────────────────
-- A claim is matchable when it is still waiting for a verdict and it is
-- attached to an order. 'claimed' is the default status the customer's own
-- submission lands in; 'pending' is the spec's word for the same thing, so
-- both are accepted rather than guessing which one the row will carry.
create or replace function public._pa_open_claims()
returns setof public.payment_claims language sql stable security definer set search_path to 'public' as $$
  select * from public.payment_claims
   where coalesce(status,'claimed') in ('pending','claimed','submitted','unverified')
     and order_id is not null;
$$;

-- ─── the matcher ────────────────────────────────────────────────────────────
create or replace function public.payment_alert_match(p_alert_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype;
  v_utr_d text; v_suffix text; v_n int;
  v_claim public.payment_claims%rowtype;
  v_reason_key text; v_verify jsonb; v_learn jsonb;
begin
  select * into a from public.payment_alerts where id = p_alert_id for update;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if a.status <> 'new' then
    return public.payment_alert_state(a.id) || jsonb_build_object('skipped','already_decided');
  end if;

  if a.parsed_amount is null or a.parsed_amount <= 0 then
    update public.payment_alerts
       set status = 'unmatched', updated_at = now(),
           match_reason = public.uic('pay_alert.unmatched.no_amount',
                                     'The notification carried no amount.')
     where id = a.id;
    return public.payment_alert_state(a.id);
  end if;

  v_utr_d := public._pa_digits(a.parsed_utr);

  -- 1. FULL UTR. The reference is unique; nothing else needs to agree.
  if v_utr_d is not null and length(v_utr_d) >= 9 then
    select c.* into v_claim from public._pa_open_claims() c
     where public._pa_digits(c.utr) = v_utr_d
        or public._pa_digits(c.txn_id) = v_utr_d
     limit 1;
    if v_claim.id is not null then v_reason_key := 'pay_alert.match.utr_full'; end if;
  end if;

  -- 2. TRUNCATED UTR. Notifications print "…789012": a suffix of at least six
  --    digits plus an exact amount is one payment, or it is nobody's.
  if v_claim.id is null and v_utr_d is not null and length(v_utr_d) >= 6 then
    v_suffix := right(v_utr_d, greatest(6, least(length(v_utr_d), 12)));
    select count(*)::int into v_n from public._pa_open_claims() c
     where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
       and (public._pa_digits(c.utr)    like '%'||v_suffix
         or public._pa_digits(c.txn_id) like '%'||v_suffix);
    if v_n = 1 then
      select c.* into v_claim from public._pa_open_claims() c
       where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
         and (public._pa_digits(c.utr)    like '%'||v_suffix
           or public._pa_digits(c.txn_id) like '%'||v_suffix)
       limit 1;
      v_reason_key := 'pay_alert.match.utr_suffix';
    elsif v_n > 1 then
      update public.payment_alerts
         set status = 'unmatched', updated_at = now(),
             match_reason = public.uic('pay_alert.unmatched.ambiguous',
                                       'More than one payment could be this one.')
       where id = a.id;
      return public.payment_alert_state(a.id);
    end if;
  end if;

  -- 3. NO UTR AT ALL. Amount + the paying VPA, inside ±15 minutes, and ONLY
  --    when exactly one claim fits. Two candidates is not a match.
  if v_claim.id is null and v_utr_d is null and nullif(a.parsed_vpa,'') is not null then
    select count(*)::int into v_n from public._pa_open_claims() c
     where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
       and lower(btrim(coalesce(c.payee_vpa,''))) = lower(btrim(a.parsed_vpa))
       and coalesce(c.paid_ts, c.received_at, c.created_at)
             between a.posted_at - interval '15 minutes' and a.posted_at + interval '15 minutes';
    if v_n = 1 then
      select c.* into v_claim from public._pa_open_claims() c
       where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
         and lower(btrim(coalesce(c.payee_vpa,''))) = lower(btrim(a.parsed_vpa))
         and coalesce(c.paid_ts, c.received_at, c.created_at)
               between a.posted_at - interval '15 minutes' and a.posted_at + interval '15 minutes'
       limit 1;
      v_reason_key := 'pay_alert.match.amount_vpa';
    elsif v_n > 1 then
      update public.payment_alerts
         set status = 'unmatched', updated_at = now(),
             match_reason = public.uic('pay_alert.unmatched.ambiguous',
                                       'More than one payment could be this one.')
       where id = a.id;
      return public.payment_alert_state(a.id);
    end if;
  end if;

  -- A claim was found: verify it through the SAME path manual verify uses.
  if v_claim.id is not null then
    v_verify := public._payment_claim_verify_core(v_claim.id, v_claim.order_id,
                  'auto_payment_alert');
    if not coalesce((v_verify->>'ok')::boolean, false) then
      update public.payment_alerts
         set status = 'unmatched', updated_at = now(),
             match_reason = public.uic('pay_alert.unmatched.none',
                                       'Nothing pending looks like this payment.')
       where id = a.id;
      return public.payment_alert_state(a.id);
    end if;

    update public.payment_alerts
       set status = 'matched', matched_claim_id = v_claim.id,
           matched_order_id = v_claim.order_id,
           matched_customer_id = public._pa_customer_of_order(v_claim.order_id),
           match_reason = public.uic(v_reason_key, v_reason_key),
           updated_at = now()
     where id = a.id;

    -- Learn who paid, so the NEXT payment from them needs no UTR (4b).
    perform public._pa_learn_sender(a.id, v_claim.id);
    -- Say it out loud on the partner phone (5).
    perform public._pa_speak(a.id);

    return public.payment_alert_state(a.id);
  end if;

  -- No claim fits. Sender learning gets its turn before we give up (4b).
  return public._pa_match_by_sender(a.id);
end $$;

-- The customer (pharmacy_profiles.id) behind an order.
create or replace function public._pa_customer_of_order(p_order_id uuid)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select pp.id from public.orders o
    join public.pharmacy_profiles pp on pp.user_id = o.user_id
   where o.id = p_order_id
     and coalesce(pp.is_deleted,false) = false
   limit 1;
$$;

revoke all on function public.payment_alert_match(uuid) from anon, authenticated;
revoke all on function public._payment_claim_verify_core(uuid, uuid, text) from anon, authenticated;
revoke all on function public._pa_open_claims() from anon, authenticated;
grant execute on function public.payment_alert_state(uuid) to authenticated;
