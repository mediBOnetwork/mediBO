-- CHANGE #354 — register row 89, the countdown sentence.
--
-- delivery_verify_otp now returns attempts_left on a wrong code. The rider must
-- SEE that a lockout is coming, and the proof sheet renders res['message']
-- verbatim (delivery_proof_sheet.dart _showError) — so the countdown belongs in
-- the message the backend sends, not in a Dart string built from the number.
insert into public.ui_copy(key, value) values
  ('delivery.otp_wrong_left', to_jsonb('Incorrect OTP. {left} attempt(s) left before the code locks.'::text))
on conflict (key) do nothing;

create or replace function public.delivery_verify_otp(p_delivery_id uuid, p_code text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_receiver text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d deliveries%rowtype; o public.delivery_otp%rowtype;
  v_max int; v_lock int; v_ttl int; v_left int; v_res jsonb;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid())
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce((public._dcfg(d.zone_id)->>'otp_max_attempts')::int, 5),
         coalesce((public._dcfg(d.zone_id)->>'otp_lock_minutes')::int, 15),
         coalesce((public._dcfg(d.zone_id)->>'otp_ttl_minutes')::int, 30)
    into v_max, v_lock, v_ttl;

  select * into o from public.delivery_otp where delivery_id = p_delivery_id for update;
  if o.delivery_id is null or coalesce(o.code,'') = '' then
    return jsonb_build_object('ok',false,'error','no_otp','message', public._c('delivery.otp_none'));
  end if;

  -- CHANGE #354 (register row 89): the lockout. Without it a 6-digit code is one
  -- loop away, and no failed attempt was recorded anywhere.
  if o.locked_until is not null and o.locked_until > now() then
    return jsonb_build_object('ok',false,'error','locked',
      'message', public._c('delivery.otp_locked'), 'locked_until', o.locked_until);
  end if;

  if o.sent_at < now() - make_interval(mins => v_ttl) then
    return jsonb_build_object('ok',false,'error','expired','message', public._c('delivery.otp_expired'));
  end if;

  if btrim(coalesce(p_code,'')) <> o.code then
    update public.delivery_otp
       set attempts = attempts + 1,
           locked_until = case when attempts + 1 >= v_max
                               then now() + make_interval(mins => v_lock) end
     where delivery_id = p_delivery_id
     returning attempts, locked_until into o.attempts, o.locked_until;

    insert into delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'otp_failed',
            'attempt ' || o.attempts || ' of ' || v_max, p_lat, p_lng,
            coalesce(auth.jwt()->>'email','rider'));

    if o.locked_until is not null then
      return jsonb_build_object('ok',false,'error','locked',
        'message', public._c('delivery.otp_locked'), 'locked_until', o.locked_until);
    end if;
    v_left := greatest(v_max - o.attempts, 0);
    return jsonb_build_object('ok',false,'error','wrong_otp',
      'message', public._cf('delivery.otp_wrong_left', jsonb_build_object('left', v_left)),
      'attempts_left', v_left);
  end if;

  update deliveries set otp_verified_at = now() where id = p_delivery_id;
  v_res := public._delivery_complete(p_delivery_id,'otp',p_lat,p_lng,p_receiver,null);

  -- A used OTP stops existing — but only once the completion actually succeeded:
  -- a cold-chain or handover refusal must leave the code usable for the retry.
  if coalesce((v_res->>'ok')::boolean, false) then
    delete from public.delivery_otp where delivery_id = p_delivery_id;
  end if;
  return v_res;
end $function$;
