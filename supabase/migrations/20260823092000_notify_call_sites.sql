-- CHANGE — #297 part 1, step 3: every WhatsApp send now goes through notify().
--
-- Two shapes of replacement:
--
--  A. The two existing fan-in functions (wa_notify_event / wa_notify_customer_event)
--     become THIN WRAPPERS over notify(). That re-points ~15 call sites — the
--     order triggers, the order_placed sweep, the delivery events, the bill
--     chain, the unfulfilled sweep, the customer registration/approval trigger
--     and wa_send_retry — without rewriting any of their business logic, and
--     it is what actually flips those sends from free-form-first to
--     template-first.
--
--  B. The senders that still held a raw net.http_post of their own now call
--     notify() directly: the three payment verdicts, the non-customer profile
--     events, and the supplier stock-update request.
--
-- SUPPLIER SAFETY: no supplier is messaged by this migration. The supplier
-- sender is re-pointed at notify(), which for an unrouted event is a byte-for-
-- byte passthrough of the same POST it made before — same URL, same body, same
-- header — with a ledger row added.

begin;

-- ── A. the fan-in wrappers ───────────────────────────────────────────────────
create or replace function public.wa_notify_event(
  p_event_key text, p_customer_id uuid default null, p_tokens jsonb default '{}'::jsonb,
  p_phone text default null, p_order_id uuid default null,
  p_legacy_url text default null, p_legacy_body jsonb default null)
returns jsonb language sql security definer set search_path to 'public' as $$
  select public.notify(
    p_event_key,
    p_phone,
    coalesce(p_tokens,'{}'::jsonb)
      || case when p_customer_id is not null then jsonb_build_object('customer_id', p_customer_id) else '{}'::jsonb end
      || case when p_order_id    is not null then jsonb_build_object('order_id',    p_order_id)    else '{}'::jsonb end
      || case when p_legacy_url  is not null then jsonb_build_object('legacy_url',  p_legacy_url)  else '{}'::jsonb end
      || case when p_legacy_body is not null then jsonb_build_object('legacy_body', p_legacy_body) else '{}'::jsonb end);
$$;

create or replace function public.wa_notify_customer_event(
  p_event_key text, p_order_id uuid default null, p_phone text default null,
  p_legacy_url text default null, p_legacy_body jsonb default null,
  p_tokens jsonb default '{}'::jsonb)
returns jsonb language sql security definer set search_path to 'public' as $$
  select public.wa_notify_event(p_event_key, null, coalesce(p_tokens,'{}'::jsonb),
                                p_phone, p_order_id, p_legacy_url, p_legacy_body);
$$;

-- ── B1. payment verdicts — the raw http_post fallbacks are gone ──────────────
create or replace function public.mark_payment_received(p_claim_id uuid, p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_amt numeric; v_utr text; v_app text; v_paid text; v_chk jsonb; v jsonb;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;
  v_chk := public.payment_claim_match_check(p_claim_id, p_order_id);
  if (v_chk->>'blocked')::boolean
     and not exists (select 1 from payment_claims where id = p_claim_id and order_id = p_order_id) then
    raise exception '%', coalesce(v_chk->>'message', v_chk->>'reason');
  end if;

  update payment_claims set order_id = p_order_id, status = 'verified', verify_reason = 'manual_received'
   where id = p_claim_id returning amount, utr, app, paid_at into v_amt, v_utr, v_app, v_paid;

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
                                   'caller_error: ' || sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'claim_id', p_claim_id, 'order_id', p_order_id,
                            'amount', v_amt, 'notify', v);
end $$;

create or replace function public.reject_payment_claim(p_claim_id uuid, p_order_id uuid, p_reason text default 'rejected')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_phone text; v_amount numeric; v_utr text; v_app text; v_paid text; v_ph10 text; v jsonb;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;
  update payment_claims
     set status = 'rejected',
         verify_reason = coalesce(nullif(btrim(p_reason),''),'rejected'),
         order_id = coalesce(order_id, p_order_id)
   where id = p_claim_id
   returning sender_phone, amount, utr, app, paid_at into v_phone, v_amount, v_utr, v_app, v_paid;

  v_ph10 := right(regexp_replace(coalesce(v_phone,''),'[^0-9]','','g'), 10);
  if length(v_ph10) = 10 then
    begin
      v := public.notify('payment_rejected', v_ph10,
             jsonb_build_object(
               'order_id',    p_order_id,
               'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
               'legacy_body', jsonb_build_object('event','payment_rejected','phone', v_ph10,
                                'amount', coalesce(v_amount,0), 'utr', coalesce(v_utr,''),
                                'app', coalesce(v_app,''), 'paid_at', coalesce(v_paid,''))));
    exception when others then
      perform public._wa_log_attempt('payment_rejected', p_order_id, v_ph10, 'skipped', false,
                                     'caller_error: ' || sqlerrm);
    end;
  end if;

  return jsonb_build_object('ok', true, 'claim_id', p_claim_id, 'order_id', p_order_id,
                            'notified', (length(v_ph10) = 10), 'notify', v);
end $$;

create or replace function public.admin_record_cash_payment(
  p_order_id uuid, p_amount numeric, p_collected_by text, p_file_path text,
  p_lat double precision default null, p_lng double precision default null,
  p_location_address text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_user uuid; v_phone10 text; v_claim_id uuid; v_addr text; v jsonb;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;
  select user_id into v_user from orders where id = p_order_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  select right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone, ''),'[^0-9]','','g'),10)
    into v_phone10
    from pharmacy_profiles pp
   where pp.user_id = v_user and coalesce(pp.is_deleted,false) = false
   limit 1;

  v_addr := nullif(btrim(coalesce(p_location_address,'')),'');

  insert into payment_claims (order_id, sender_phone, sender_type, amount, app, payment_method,
                              collected_by, file_path, location_lat, location_lng, location_address,
                              status, verify_reason, received_at, created_at)
  values (p_order_id, coalesce(v_phone10,'unknown'), 'customer', p_amount, 'Cash', 'cash',
          p_collected_by, p_file_path, p_lat, p_lng, v_addr, 'received', 'admin_cash_entry', now(), now())
  returning id into v_claim_id;

  begin
    v := public.notify('payment_received_cash', v_phone10,
           jsonb_build_object(
             'order_id',    p_order_id,
             'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
             'legacy_body', jsonb_build_object('event','cash_received','order_id',p_order_id,
                              'amount',p_amount,'collected_by',p_collected_by,
                              'location_lat',p_lat,'location_lng',p_lng,'location_address',v_addr)));
  exception when others then
    perform public._wa_log_attempt('payment_received_cash', p_order_id, v_phone10, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'claim_id', v_claim_id, 'via', coalesce(v->>'path','none'));
end $$;

-- ── B2. profile registration / approval — every audience, one door ───────────
create or replace function public.tg_notify_profile_event()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare ev text; ptype text := TG_ARGV[0];
        new_appr boolean; old_appr boolean; v_phone text; v_name text;
begin
  if coalesce(current_setting('medibo.suppress_notify', true), '') = '1' then return NEW; end if;
  if coalesce(NEW.is_deleted, false) then return NEW; end if;

  new_appr := coalesce(NEW.approved, false) or lower(coalesce(NEW.status, '')) in ('approved','active');
  if TG_OP = 'INSERT' then
    ev := case when new_appr then 'approved' else 'registration' end;
  else
    old_appr := coalesce(OLD.approved, false) or lower(coalesce(OLD.status, '')) in ('approved','active');
    if new_appr and not old_appr then ev := 'approved'; else return NEW; end if;
  end if;

  v_phone := public._phone10(coalesce(NEW.whatsapp_no, NEW.phone, ''));
  if not notif_should_send(ptype, ptype || '_' || ev, v_phone) then return NEW; end if;

  if ptype = 'customer' then
    begin
      v_name := coalesce(nullif(btrim(NEW.customer_name),''),
                         nullif(btrim(NEW.owner_name),''), NEW.pharmacy_name, 'there');
    exception when others then v_name := 'there';
    end;
  end if;

  begin
    perform public.notify(ptype || '_' || ev, v_phone,
      jsonb_build_object(
        'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/user-notify',
        'legacy_body', jsonb_build_object('event', ev, 'ptype', ptype, 'profile_id', NEW.id))
      || case when ptype = 'customer'
              then jsonb_build_object('customer_id', NEW.id, 'customer_name', v_name)
              else '{}'::jsonb end);
  exception when others then
    perform public._wa_log_attempt(ptype || '_' || ev, null, v_phone, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;
  return NEW;
end $$;

-- ── B3. supplier stock-update request ────────────────────────────────────────
create or replace function public.send_stock_update_wa(p_token text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_phone text; v_supplier text;
begin
  if p_token is null or btrim(p_token) = '' then return; end if;

  select f.supplier_name into v_supplier
    from public.stock_update_forms f where f.token = p_token;
  if v_supplier is null or btrim(v_supplier) = '' then return; end if;

  v_phone := public.sup_pick_send_phone(v_supplier);

  perform public.notify('supplier_stock_update', v_phone,
    jsonb_build_object(
      'supplier_name', v_supplier,
      'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/stock-notify',
      'legacy_body', jsonb_build_object('supplier_name', v_supplier, 'token', p_token)
                     || case when v_phone is not null
                             then jsonb_build_object('to_phone', v_phone)
                             else '{}'::jsonb end));
end $$;

-- ── C. "Re-engagement message" recovery, now on the ledger and the queue ─────
--
-- Meta refusing a free-form send is PROOF the window is shut, whatever we
-- believed a moment ago — so the tracked window is closed on the spot and the
-- send is retried as its template equivalent. If the template retry ALSO
-- fails, the send is queued rather than only alerted: nothing is dropped.
create or replace function public.trg_wa_out_failed()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_event text; v_order uuid; v_code text; v jsonb; v_is_campaign boolean;
begin
  if NEW.direction <> 'out'
     or NEW.wa_status <> 'failed'
     or coalesce(OLD.wa_status,'') = 'failed'
     or coalesce(NEW.routed_to,'') in ('bot_reply','admin_reply','bot_send_error','send_error')
  then
    return null;
  end if;

  v_is_campaign := coalesce(NEW.routed_to,'') = 'campaign';
  if v_is_campaign and coalesce(NEW.text_body,'') like '%wa_send_failed%' then
    return null;
  end if;

  v_event := public.wa_event_key_for_routed(NEW.routed_to);

  v_code := nullif(btrim(split_part(replace(coalesce(NEW.file_name,''),'mediBO-',''), '.', 1)),'');
  if v_code is not null then
    select o.id into v_order from orders o where o.order_code = v_code limit 1;
  end if;
  if v_order is null then
    select o.id into v_order
      from orders o
      join pharmacy_profiles pp on pp.user_id = o.user_id
     where right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
         = right(regexp_replace(NEW.sender_phone,'\D','','g'),10)
     order by o.created_at desc limit 1;
  end if;

  if not v_is_campaign and coalesce(NEW.wa_fail_reason,'') ilike '%re-engagement%' then
    -- The window is provably shut. Say so, so the next send does not guess.
    update public.wa_service_window
       set window_until = now() - interval '1 second',
           closed_reason = 're_engagement_refused', updated_at = now()
     where phone10 = right(regexp_replace(coalesce(NEW.sender_phone,''),'\D','','g'),10);

    if v_event is not null then
      v := public.notify(v_event,
                         right(regexp_replace(coalesce(NEW.sender_phone,''),'\D','','g'),10),
                         jsonb_build_object('force_template', true)
                         || case when v_order is not null
                                 then jsonb_build_object('order_id', v_order) else '{}'::jsonb end);
      perform public._wa_log_attempt(v_event, v_order, NEW.sender_phone, 'template_retry',
                                     coalesce((v->>'ok')::boolean,false),
                                     coalesce(v->>'reason','retried_as_template'), v);
      if coalesce((v->>'ok')::boolean,false) then
        return null;   -- recovered: the customer got the approved template.
      end if;
    else
      perform public._wa_log_attempt(coalesce(NEW.routed_to,'unknown'), v_order, NEW.sender_phone,
                                     'skipped', false,
                                     'no_event_route_for_' || coalesce(NEW.routed_to,'null'));
    end if;
  end if;

  perform public.notify_log(coalesce(v_event, NEW.routed_to, 'unknown'),
    right(regexp_replace(coalesce(NEW.sender_phone,''),'\D','','g'),10),
    'whatsapp', 'failed', 'provider', NEW.wa_message_id,
    coalesce(NEW.wa_fail_reason,'send_failed'), null, v_order, null, '{}'::jsonb, v);

  perform public.wa_send_failed_alert(
    coalesce(v_event, case when v_is_campaign then 'template_send' end, NEW.routed_to, 'unknown'),
    NEW.sender_phone, v_order, coalesce(NEW.wa_fail_reason,'send_failed'), v);
  return null;
end $$;

commit;
