-- CHANGE #294 (part F) — ONE dispatcher, not two.
--
-- CHANGE #295 (in flight alongside this one) generalised #294's customer
-- dispatcher into wa_notify_event(), audience-aware, on top of #294's own
-- wa_window_open / _wa_log_attempt / wa_send_event_or_fallback. It is a strict
-- superset, so wa_notify_customer_event now DELEGATES to it rather than keeping
-- a second copy of the same rules that could drift.
--
-- The delegation is guarded: if wa_notify_event is ever missing or changes shape,
-- this falls back to the template-or-legacy path directly, because the one thing
-- this change exists to prevent is a customer notification silently not going out.

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
declare v jsonb; v_ph text; v_reason text;
begin
  begin
    return public.wa_notify_event(p_event_key, null, coalesce(p_tokens,'{}'::jsonb),
                                  p_phone, p_order_id, p_legacy_url, p_legacy_body);
  exception when undefined_function or invalid_parameter_value then
    null;   -- fall through to the direct path below
  end;

  v_ph := right(coalesce(
            nullif(regexp_replace(coalesce(p_phone,''),'\D','','g'),''),
            case when p_order_id is not null then public._order_customer_phone(p_order_id) end,
            ''), 10);
  if length(v_ph) <> 10 then
    perform public._wa_log_attempt(p_event_key, p_order_id, null, 'skipped', false, 'no_phone');
    return jsonb_build_object('ok', false, 'reason', 'no_phone');
  end if;
  if not public.notif_should_send('customer', p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false, 'notification_off');
    return jsonb_build_object('ok', false, 'reason', 'notification_off');
  end if;

  if not public.wa_window_open(v_ph) then
    v := public.wa_send_event_or_fallback(p_event_key, null, coalesce(p_tokens,'{}'::jsonb),
                                          v_ph, p_order_id);
    if coalesce((v->>'ok')::boolean, false) then
      perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'template', true,
                                     coalesce(v->>'used_event', p_event_key), v);
      return jsonb_build_object('ok', true, 'path', 'template', 'detail', v);
    end if;
    v_reason := coalesce(v->>'reason','template_failed');
  end if;

  if p_legacy_url is null then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false,
                                   coalesce(v_reason,'no_legacy_sender'), v);
    return jsonb_build_object('ok', false, 'reason', coalesce(v_reason,'no_legacy_sender'));
  end if;

  perform net.http_post(
    url     := p_legacy_url,
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027'),
    body    := coalesce(p_legacy_body,'{}'::jsonb),
    timeout_milliseconds := 20000);
  perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'freeform',
                                 v_reason is null,
                                 coalesce('window_closed_no_template: ' || v_reason, 'window_open'), v);
  return jsonb_build_object('ok', v_reason is null, 'path', 'freeform',
                            'reason', coalesce(v_reason,'window_open'));
end $$;
