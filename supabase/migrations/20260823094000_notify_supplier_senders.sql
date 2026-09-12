-- CHANGE — #297 part 1, step 3c: the supplier senders join the same door.
--
-- These four are the last raw net.http_post callers. None of their event keys
-- has a row in wa_event_routes, so notify() takes its legacy-passthrough
-- branch: the SAME url, the SAME body, the SAME x-notify-secret header, the
-- same 20s ceiling. The only difference is a notification_log row. Nothing is
-- sent to any supplier by this migration — it changes code, not data.
--
-- notify() now hands the pg_net request id back so the two admin-facing
-- functions can keep returning `request_id` exactly as their callers expect.

begin;

create or replace function public.notify(
  p_event_key text,
  p_recipient text default null,
  p_vars jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public', 'net' as $$
declare
  r            record;
  v            jsonb;
  v_vars       jsonb := coalesce(p_vars, '{}'::jsonb);
  v_channel    text  := coalesce(nullif(v_vars->>'channel',''), 'whatsapp');
  v_order      uuid  := nullif(v_vars->>'order_id','')::uuid;
  v_cust       uuid  := nullif(v_vars->>'customer_id','')::uuid;
  v_url        text  := nullif(v_vars->>'legacy_url','');
  v_body       jsonb := case when v_vars ? 'legacy_body' then v_vars->'legacy_body' end;
  v_force_tpl  boolean := coalesce((v_vars->>'force_template')::boolean, false);
  v_retry      bigint := nullif(v_vars->>'_retry_id','')::bigint;
  v_req        bigint;
  v_tokens     jsonb;
  v_ph         text;
  v_aud        text;
  v_win        jsonb;
  v_open       boolean;
  v_reason     text;
begin
  if coalesce(btrim(p_event_key),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_event_key');
  end if;

  select * into r from public.wa_event_routes where event_key = p_event_key;
  v_aud := coalesce(r.audience, 'customer');

  v_tokens := v_vars - 'order_id' - 'customer_id' - 'legacy_url' - 'legacy_body'
                     - 'channel' - 'force_template' - '_retry_id';

  v_ph := nullif(right(regexp_replace(coalesce(p_recipient,''),'\D','','g'),10),'');
  if coalesce(length(v_ph),0) <> 10 and v_order is not null then
    v_ph := right(regexp_replace(coalesce(public._order_customer_phone(v_order),''),'\D','','g'),10);
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_cust is not null then
    select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),'\D','','g'),10)
      into v_ph from public.pharmacy_profiles pp where pp.id = v_cust;
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_aud = 'admin' then
    v_ph := right(regexp_replace(
              coalesce((select value #>> '{}' from public.app_settings where key='admin_wa_phone'),''),
              '\D','','g'), 10);
  end if;

  -- No route at all → legacy passthrough, byte-for-byte what the caller used
  -- to post on its own, plus a ledger row.
  if r.event_key is null then
    if v_url is null then
      perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
        null, 'unknown_event', null, v_order, v_cust, v_vars);
      return jsonb_build_object('ok', false, 'reason','unknown_event');
    end if;
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'legacy',
      v_req::text, null, null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', true, 'path','legacy', 'reason','no_route',
                              'request_id', v_req);
  end if;

  if coalesce(length(v_ph),0) <> 10 then
    perform public._wa_log_attempt(p_event_key, v_order, null, 'skipped', false, 'no_phone');
    perform public.notify_log(p_event_key, null, v_channel, 'skipped', 'none',
      null, 'no_phone', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;

  if not public.notif_should_send(v_aud, p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'notification_off');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'notification_off', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','notification_off');
  end if;

  v_win  := public.notify_window(v_ph);
  v_open := coalesce((v_win->>'open')::boolean, false);

  -- 1. TEMPLATE FIRST. Always. This is the order_placed fix.
  begin
    v := public.wa_send_event_or_fallback(p_event_key, v_cust, v_tokens, v_ph, v_order);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason','exception', 'message', sqlerrm);
  end;

  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'template',
      v->>'recipient_id', null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','template', 'window_open', v_open, 'detail', v);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  -- 2. FREE-FORM, and only inside the tracked window.
  if v_url is not null and v_open and not v_force_tpl then
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'freeform', true,
                                   'window_open_no_template: ' || v_reason, v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'freeform',
      v_req::text, null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','freeform', 'window_open', true,
                              'reason', v_reason, 'request_id', v_req);
  end if;

  -- 3. Nothing legal to send right now → QUEUE it. Never a silent drop.
  perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, v_reason, v);
  perform public.notify_log(p_event_key, v_ph, v_channel, 'queued', 'none',
    null, v_reason, null, v_order, v_cust, v_vars, v);

  if v_retry is not null then
    update public.notification_retry_queue
       set attempts = attempts + 1, last_reason = v_reason,
           next_attempt_at = now() + public.notify_backoff(attempts + 1),
           status = case when attempts + 1 >= max_attempts then 'dead' else 'pending' end,
           updated_at = now()
     where id = v_retry;
  else
    perform public.notify_enqueue_retry(p_event_key, v_ph, v_vars, v_reason,
                                        v_order, v_cust, v_channel, v_force_tpl);
  end if;

  return jsonb_build_object('ok', false, 'path','queued', 'window_open', v_open,
                            'reason', v_reason);
end $$;

-- ── the four supplier senders ────────────────────────────────────────────────
create or replace function public.send_supplier_inquiry_wa(p_supplier text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_phone text;
begin
  if p_supplier is null or btrim(p_supplier) = '' then return; end if;
  v_phone := public.sup_pick_send_phone(p_supplier);
  perform public.notify('supplier_inquiry', v_phone,
    jsonb_build_object(
      'supplier_name', p_supplier,
      'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/inquiry-notify',
      'legacy_body', jsonb_build_object('supplier_name', p_supplier)
                     || case when v_phone is not null
                             then jsonb_build_object('to_phone', v_phone) else '{}'::jsonb end));
end $$;

create or replace function public.send_supplier_order_wa(p_supplier text, p_order_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_phone text;
begin
  if p_supplier is null or btrim(p_supplier) = '' then return; end if;
  v_phone := public.sup_pick_send_phone(p_supplier);
  perform public.notify('supplier_order', v_phone,
    jsonb_build_object(
      'supplier_name', p_supplier,
      'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/supplier-order-notify',
      'legacy_body', jsonb_build_object('supplier_name', p_supplier, 'order_id', p_order_id)
                     || case when v_phone is not null
                             then jsonb_build_object('to_phone', v_phone) else '{}'::jsonb end));
end $$;

create or replace function public.send_supplier_inquiry_wa(p_supplier text, p_phone text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_digits text; v_n jsonb; v_token text; v_status text; v_expires timestamptz;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  if p_supplier is null or btrim(p_supplier) = '' then
    return jsonb_build_object('ok', false, 'error', 'no_supplier');
  end if;

  v_digits := right(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), 10);
  if length(v_digits) <> 10 then
    return jsonb_build_object('ok', false, 'error', 'bad_phone');
  end if;

  select s.token, s.status, s.expires_at
    into v_token, v_status, v_expires
  from public.start_inquiry_for_suppliers(array[p_supplier], false) s
  limit 1;

  v_n := public.notify('supplier_inquiry', v_digits,
    jsonb_build_object(
      'supplier_name', p_supplier,
      'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/inquiry-notify',
      'legacy_body', jsonb_build_object('supplier_name', p_supplier, 'to_phone', v_digits)));

  return jsonb_build_object(
    'ok', true, 'supplier', p_supplier, 'phone', v_digits,
    'status', v_status, 'expires_at', v_expires, 'token', v_token,
    'request_id', nullif(v_n->>'request_id','')::bigint);
end $$;

create or replace function public.send_supplier_order_wa(p_supplier text, p_order_id uuid, p_phone text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_digits text; v_n jsonb; v_code text;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  if p_supplier is null or btrim(p_supplier) = '' then
    return jsonb_build_object('ok', false, 'error', 'no_supplier');
  end if;

  v_digits := right(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), 10);
  if length(v_digits) <> 10 then
    return jsonb_build_object('ok', false, 'error', 'bad_phone');
  end if;

  select so.order_code into v_code from supplier_orders so where so.id = p_order_id;
  if v_code is null then
    return jsonb_build_object('ok', false, 'error', 'no_order');
  end if;

  v_n := public.notify('supplier_order', v_digits,
    jsonb_build_object(
      'supplier_name', p_supplier,
      'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/supplier-order-notify',
      'legacy_body', jsonb_build_object('supplier_name', p_supplier, 'order_id', p_order_id,
                                        'to_phone', v_digits)));

  update supplier_orders set auto_order_sent_at = coalesce(auto_order_sent_at, now())
   where id = p_order_id;

  return jsonb_build_object('ok', true, 'supplier', p_supplier, 'order_code', v_code,
                            'phone', v_digits,
                            'request_id', nullif(v_n->>'request_id','')::bigint,
                            'send_button', jsonb_build_object('state','sent','label','Sent','tone','yellow'));
end $$;

commit;
