-- CHANGE #294 (part D) — the dispatcher must be able to carry values the token
-- registry cannot derive.
--
-- Caught on the first live payment test: wa_token_value('amount') resolves to the
-- ORDER TOTAL (Rs 4,212.33), but the payment message is about the ADVANCE DUE
-- (Rs 1,263.70). Telling a pharmacy the wrong number is worse than telling them
-- nothing, so the caller now passes the amount it actually means.

drop function if exists public.wa_notify_customer_event(text, uuid, text, text, jsonb);

create or replace function public.wa_notify_customer_event(
  p_event_key   text,
  p_order_id    uuid    default null,
  p_phone       text    default null,
  p_legacy_url  text    default null,
  p_legacy_body jsonb   default null,
  p_tokens      jsonb   default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public', 'net'
as $$
declare v_ph text; v_open boolean; v jsonb; v_reason text;
begin
  v_ph := coalesce(
            nullif(regexp_replace(coalesce(p_phone,''),'\D','','g'),''),
            case when p_order_id is not null then public._order_customer_phone(p_order_id) end);
  v_ph := right(coalesce(v_ph,''), 10);

  if length(v_ph) <> 10 then
    perform public._wa_log_attempt(p_event_key, p_order_id, null, 'skipped', false, 'no_phone');
    return jsonb_build_object('ok', false, 'reason', 'no_phone');
  end if;

  if not public.notif_should_send('customer', p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false, 'notification_off');
    return jsonb_build_object('ok', false, 'reason', 'notification_off');
  end if;

  v_open := public.wa_window_open(v_ph);

  if v_open and p_legacy_url is not null then
    perform net.http_post(
      url     := p_legacy_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(p_legacy_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'freeform', true, 'window_open');
    return jsonb_build_object('ok', true, 'path', 'freeform', 'reason', 'window_open');
  end if;

  v := public.wa_send_event_or_fallback(p_event_key, null, coalesce(p_tokens,'{}'::jsonb),
                                        v_ph, p_order_id);
  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    return jsonb_build_object('ok', true, 'path', 'template', 'detail', v);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  if p_legacy_url is not null then
    perform net.http_post(
      url     := p_legacy_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(p_legacy_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'freeform', false,
                                   'window_closed_no_template: ' || v_reason, v);
    return jsonb_build_object('ok', false, 'path', 'freeform', 'reason', v_reason);
  end if;

  perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false, v_reason, v);
  return jsonb_build_object('ok', false, 'reason', v_reason);
end $$;

comment on function public.wa_notify_customer_event(text,uuid,text,text,jsonb,jsonb) is
  'CHANGE #294 — THE door for every customer-facing WhatsApp notification. '
  'Window open => free-form; window shut => approved template; always logged.';

-- The payment path now states the amount it is actually asking for, formatted by
-- the same backend formatter every other money token uses.
create or replace function public._send_payment_qr_wa_auto(
  p_order_id uuid, p_phone text, p_amount numeric, p_kind text default 'remaining')
returns jsonb
language plpgsql security definer set search_path to 'public', 'net'
as $$
declare v_ph10 text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10);
begin
  if length(v_ph10) <> 10 then return jsonb_build_object('ok',false,'error','bad_phone'); end if;
  if coalesce(p_amount,0) <= 0 then return jsonb_build_object('ok',false,'error','nothing_due'); end if;

  return public.wa_notify_customer_event(
    'payment_qr', p_order_id, v_ph10,
    'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/send-payment-qr',
    jsonb_build_object('order_id', p_order_id, 'phone', v_ph10,
                       'amount', round(p_amount), 'kind', lower(coalesce(p_kind,'remaining'))),
    jsonb_build_object('amount', public._wa_token_format(p_amount::text, 'money')));
end $$;
