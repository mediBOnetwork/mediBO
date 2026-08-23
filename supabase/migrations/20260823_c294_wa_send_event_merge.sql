-- CHANGE #294 (part E4) — RE-APPLIED on top of CHANGE #295.
--
-- #295 landed its own `create or replace` of wa_send_event while #294 was in
-- flight and, being a whole-function replace, dropped #294's media-header block.
-- This file is #295's live definition with the header block merged back in, so
-- BOTH changes survive: #295's "an empty ARRAY token_map is authoritative", and
-- #294's "a media-header template is never sent without its media".
-- Two workers replacing the same function is the hazard here — merge, never clobber.

CREATE OR REPLACE FUNCTION public.wa_send_event(p_event_key text, p_customer_id uuid DEFAULT NULL::uuid, p_tokens jsonb DEFAULT '{}'::jsonb, p_phone text DEFAULT NULL::text, p_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_lang text; v_tid uuid; v_ph text; v_cid uuid; v_rid uuid;
        v_tname text; v_tlang text; v_cat text; v_code text; v_status text;
        v_varmap jsonb;
        v_tok jsonb; v_key text; v_val text; v_missing text[] := '{}';
        v_cust uuid := p_customer_id;
        v_hdr_fmt text; v_hdr jsonb;   -- CHANGE #294
begin
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then return jsonb_build_object('ok', false, 'reason','unknown_event'); end if;
  if not r.enabled or r.template_id is null then
    return jsonb_build_object('ok', false, 'reason','route_disabled');
  end if;

  if v_cust is null and p_order_id is not null then
    select customer_id into v_cust from orders where id = p_order_id;
  end if;

  v_ph := coalesce(public.wa_normalize_phone(p_phone),
                   (select public.wa_normalize_phone(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone))
                      from pharmacy_profiles pp where pp.id = v_cust),
                   case when r.audience = 'admin' then
                     public.wa_normalize_phone(
                       nullif(btrim((select value #>> '{}' from app_settings where key='admin_wa_phone')),''))
                   end);
  if v_ph is null then return jsonb_build_object('ok', false, 'reason','no_phone'); end if;

  if not public.notif_is_enabled(r.audience, p_event_key)
     and not exists (select 1 from notification_allowlist a
                      where a.audience = r.audience and a.phone10 = right(v_ph, 10)) then
    return jsonb_build_object('ok', false, 'reason','notification_off',
      'message', r.label || ' is switched off in Notifications');
  end if;

  if coalesce(array_length(r.legacy_routed_to,1),0) > 0 and exists (
       select 1 from whatsapp_messages m
        where m.direction = 'out' and m.sender_phone = v_ph
          and m.routed_to = any(r.legacy_routed_to)
          and m.received_at > now() - make_interval(mins => r.dedupe_minutes)
          and coalesce(m.wa_status,'') in ('sent','delivered','read'))
  then
    return jsonb_build_object('ok', false, 'reason','legacy_already_delivered');
  end if;

  v_lang := public.wa_customer_language(v_cust);
  v_tid  := public._wa_pick_language_template(r.template_id, v_lang);
  select name, language, category, status into v_tname, v_tlang, v_cat, v_status
    from wa_templates where id = v_tid;

  if upper(coalesce(v_status,'')) <> 'APPROVED' then
    return jsonb_build_object('ok', false, 'reason','template_not_approved', 'template', v_tname);
  end if;

  if upper(coalesce(v_cat,'')) = 'MARKETING'
     and exists (select 1 from wa_suppression s where s.phone = v_ph) then
    return jsonb_build_object('ok', false, 'reason','suppressed');
  end if;

  -- CHANGE #294 — a media HEADER must be filled per message, or Meta rejects the
  -- call. Returning here lets wa_send_event_or_fallback reach the fallback route
  -- instead of sending a header-less template.
  v_hdr_fmt := public.wa_template_needs_header_media(v_tid);
  if v_hdr_fmt is not null then
    v_hdr := public.wa_event_header_media(p_event_key, p_order_id);
    if v_hdr is null
       or (coalesce(v_hdr->>'link','') = '' and coalesce(v_hdr->>'path','') = '') then
      return jsonb_build_object('ok', false, 'reason','missing_header_media',
        'template', v_tname, 'header_format', v_hdr_fmt,
        'message','Cannot send "' || r.label || '" — its template needs a '
                  || v_hdr_fmt || ' header and there is none for this order');
    end if;
    v_hdr := v_hdr || jsonb_build_object('type', v_hdr_fmt);
  end if;

  -- CHANGE #295: an ARRAY token_map is authoritative even when it is empty.
  -- Only a NULL/none-array token_map may fall back to the route's variable_map,
  -- and that fallback itself must be an array.
  select case
           when jsonb_typeof(tt.token_map) = 'array'
             then coalesce((select jsonb_agg('{{'||k||'}}')
                              from jsonb_array_elements_text(tt.token_map) k), '[]'::jsonb)
           when jsonb_typeof(r.variable_map) = 'array' then r.variable_map
           else '[]'::jsonb
         end
    into v_varmap
  from wa_templates tt where tt.id = v_tid;

  v_tok := coalesce(p_tokens, '{}'::jsonb);
  for v_key in
    select (regexp_matches(el, '^\{\{([a-z0-9_]+)\}\}$'))[1]
    from jsonb_array_elements_text(coalesce(v_varmap,'[]'::jsonb)) el
  loop
    if v_key is not null and not (v_tok ? v_key) then
      v_val := public.wa_token_value(v_key, v_cust, p_order_id);
      if v_val is null then
        v_missing := v_missing || v_key;
      else
        v_tok := v_tok || jsonb_build_object(v_key, v_val);
      end if;
    end if;
  end loop;

  if coalesce(array_length(v_missing,1),0) > 0 then
    return jsonb_build_object('ok', false, 'reason','missing_values',
      'missing', to_jsonb(v_missing),
      'message','Cannot send "' || r.label || '" — no value for: ' || array_to_string(v_missing, ', '));
  end if;

  select id into v_cid from wa_campaigns
   where audience_kind = 'event_route'
     and audience_params->>'event_key' = p_event_key
     and audience_params->>'template_id' = v_tid::text
   limit 1;

  if v_cid is null then
    insert into wa_campaigns(name, template_id, template_name, language, category,
           audience_kind, audience_params, variable_map, throttle_per_min, status)
    values (r.label || ' — ' || coalesce(v_tlang,'en'), v_tid, v_tname, v_tlang, coalesce(v_cat,'UTILITY'),
           'event_route', jsonb_build_object('event_key', p_event_key, 'template_id', v_tid),
           v_varmap, 60, 'running')
    returning id into v_cid;
    update wa_event_routes set campaign_id = v_cid where event_key = p_event_key and campaign_id is null;
  end if;

  v_code := public._wa_link_code();
  insert into wa_campaign_recipients(campaign_id, customer_id, phone, variables, link_code, is_event, header_media)
  values (v_cid, v_cust, v_ph, public.wa_render_vars(v_varmap, v_tok), v_code, true, v_hdr)
  returning id into v_rid;

  return jsonb_build_object('ok', true, 'recipient_id', v_rid, 'campaign_id', v_cid,
                            'template', v_tname, 'language', v_tlang, 'queued_for', v_ph,
                            'header_media', v_hdr,
                            'values', public.wa_render_vars(v_varmap, v_tok));
end $function$

;
