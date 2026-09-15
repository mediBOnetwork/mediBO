-- CHANGE #294 (part G) — do not tell the same pharmacy the same thing twice.
--
-- wa_send_event's existing dedupe only looks at LEGACY free-form messages
-- (legacy_routed_to). Now that the template path is the normal path, two runs of
-- the sweep — or a sweep plus a manual Resend — would send the same approved
-- template again. Caught live: CPO230826CHAO1 got order_placed three times while
-- this change was being built.
--
-- The attempt ledger is the right memory for this, and the route's own
-- dedupe_minutes is the right window. A dedupe reports ok:true — the customer HAS
-- been told — so the caller never falls through to a free-form "retry" either.

create or replace function public.wa_send_event_or_fallback(
  p_event_key text, p_customer_id uuid default null, p_tokens jsonb default '{}'::jsonb,
  p_phone text default null, p_order_id uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v jsonb; v_fb text; v2 jsonb; v_mins int; v_ph10 text;
begin
  select coalesce(dedupe_minutes, 45) into v_mins
    from wa_event_routes where event_key = p_event_key;

  v_ph10 := right(regexp_replace(coalesce(p_phone,''),'\D','','g'), 10);
  if v_mins is not null and length(v_ph10) = 10 and exists (
       select 1 from wa_send_attempts a
        where a.event_key = p_event_key
          and right(regexp_replace(coalesce(a.phone,''),'\D','','g'),10) = v_ph10
          and a.ok
          and a.path in ('template','template_retry')
          and a.created_at > now() - make_interval(mins => v_mins))
  then
    return jsonb_build_object('ok', true, 'reason','already_delivered_recently',
                              'deduped', true, 'used_event', p_event_key);
  end if;

  begin
    v := public.wa_send_event_now(p_event_key, p_customer_id, p_tokens, p_phone, p_order_id);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason', 'exception', 'message', sqlerrm);
  end;

  if coalesce((v->>'ok')::boolean, false) then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  -- Only a MISSING/unapproved template justifies the fallback. A deliberate
  -- "notification_off" / "suppressed" / "legacy_already_delivered" stays a no-send.
  if coalesce(v->>'reason','') not in
     ('route_disabled','template_not_approved','unknown_event','missing_values',
      'missing_header_media','exception')
  then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  select nullif(btrim(coalesce(fallback_event_key,'')),'') into v_fb
    from wa_event_routes where event_key = p_event_key;
  if v_fb is null then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  begin
    v2 := public.wa_send_event_now(v_fb, p_customer_id, p_tokens, p_phone, p_order_id);
  exception when others then
    v2 := jsonb_build_object('ok', false, 'reason', 'exception', 'message', sqlerrm);
  end;

  return v2 || jsonb_build_object('used_event', v_fb,
                                  'primary_event', p_event_key,
                                  'primary_reason', v->>'reason');
end $$;
