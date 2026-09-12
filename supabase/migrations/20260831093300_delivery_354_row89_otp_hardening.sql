-- CHANGE #354 — feature_gaps row 89 (surface delivery / step "completion", critical)
--
-- The delivery OTP exists so the CUSTOMER proves receipt. Two things made it prove
-- nothing:
--   (a) it was stored as plain text in deliveries.otp_code, and RLS policy
--       deliveries_read grants the ASSIGNED RIDER the whole row. The rider could
--       select the code over PostgREST and then hand it straight back to
--       delivery_verify_otp — signing for the customer, from the rider's phone;
--   (b) delivery_verify_otp returned 'wrong_otp' with no attempt counter, no
--       lockout, no delay and no event row, so a 6-digit code was brute-forceable
--       in a loop, and otp_code was never cleared after a successful verify.
--
-- Fix:
--   1. the code moves to delivery_otp — a side table with RLS on and NO policies,
--      and every grant revoked, so no signed-in role can read it at all. Only
--      SECURITY DEFINER functions and the service role (the WhatsApp sender) see
--      it. deliveries.otp_code is left permanently NULL and a CHECK constraint
--      keeps it that way, so the plaintext can never drift back onto the row the
--      rider can read.
--   2. attempts are counted on that side table and a lockout closes the door;
--      every failed attempt writes a delivery_events row, so a brute force is
--      visible instead of silent.
--   3. the secret is DELETED on success — a used OTP stops existing.
-- Limits are config, not literals: delivery_config.otp_* via _dcfg().
-- Copy is backend copy: ui_copy delivery.otp_*.
-- Proof: rg behaviour test `delivery_otp_secret_and_lockout`.

-- 1 ─── the side table the rider's RLS cannot reach ──────────────────────────
create table if not exists public.delivery_otp (
  delivery_id  uuid primary key references public.deliveries(id) on delete cascade,
  code         text        not null,
  sent_at      timestamptz not null default now(),
  attempts     int         not null default 0,
  locked_until timestamptz,
  verified_at  timestamptz
);
alter table public.delivery_otp enable row level security;
-- deliberately NO policies: RLS with no policy denies every non-superuser role.
revoke all on public.delivery_otp from public;
revoke all on public.delivery_otp from anon;
revoke all on public.delivery_otp from authenticated;
grant all on public.delivery_otp to service_role;

comment on table public.delivery_otp is
  'CHANGE #354 (register row 89): the delivery OTP lives here, never on deliveries. '
  'RLS is on with no policies on purpose — the assigned rider can read the whole '
  'deliveries row, and the code must not be on it. Read only from SECURITY DEFINER '
  'functions or the service role.';

-- the plaintext must never come back to the rider-readable row
update public.deliveries set otp_code = null where otp_code is not null;
alter table public.deliveries drop constraint if exists deliveries_otp_code_stays_null;
alter table public.deliveries add constraint deliveries_otp_code_stays_null
  check (otp_code is null);

-- 2 ─── limits are config ────────────────────────────────────────────────────
alter table public.delivery_config add column if not exists otp_max_attempts int not null default 5;
alter table public.delivery_config add column if not exists otp_lock_minutes int not null default 15;
alter table public.delivery_config add column if not exists otp_ttl_minutes  int not null default 30;

create or replace function public._dcfg(p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'promise_window_min',        coalesce(z.promise_window_min,        d.promise_window_min),
    'on_time_grace_min',         coalesce(z.on_time_grace_min,         d.on_time_grace_min),
    'charge_amount',             coalesce(z.charge_amount,             d.charge_amount),
    'free_above_amount',         coalesce(z.free_above_amount,         d.free_above_amount),
    'charge_gst_pct',            coalesce(z.charge_gst_pct,            d.charge_gst_pct),
    'cost_per_drop',             coalesce(z.cost_per_drop,             d.default_cost_per_drop),
    'geofence_radius_m',         coalesce(z.geofence_radius_m,         d.geofence_radius_m),
    'geofence_min_accuracy_m',   d.geofence_min_accuracy_m,
    'doc_expiry_remind_days',    d.doc_expiry_remind_days,
    'doc_expiry_blocks',         d.doc_expiry_blocks,
    'cold_chain_priority_boost', d.cold_chain_priority_boost,
    'cold_chain_photo_required', d.cold_chain_photo_required,
    'handover_required',         d.handover_required,
    'handover_enforced_from',    d.handover_enforced_from,
    'payout_period_days',        d.payout_period_days,
    'rating_poor_at_or_below',   d.rating_poor_at_or_below,
    'unknown_pincode_mode',      d.unknown_pincode_mode,
    'otp_max_attempts',          d.otp_max_attempts,
    'otp_lock_minutes',          d.otp_lock_minutes,
    'otp_ttl_minutes',           d.otp_ttl_minutes,
    'zone_serviceable',          coalesce(z.is_serviceable, true),
    'zone_id',                   p_zone)
  from public.delivery_config d
  left join public.zone_delivery_config z on z.zone_id = p_zone
  where d.id = 1;
$function$;

-- 3 ─── backend copy ─────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('delivery.otp_none',    to_jsonb('Send the OTP first.'::text)),
  ('delivery.otp_expired', to_jsonb('OTP expired — send a new one.'::text)),
  ('delivery.otp_wrong',   to_jsonb('Incorrect OTP.'::text)),
  ('delivery.otp_locked',  to_jsonb('Too many wrong OTP attempts. Send a new OTP to try again.'::text)),
  ('delivery.otp_sent',    to_jsonb('OTP sent to the customer'::text))
on conflict (key) do nothing;

-- 4 ─── send: write the secret to the side table, never to deliveries ────────
create or replace function public.delivery_send_otp(p_delivery_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_code text;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid())
     and get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_code := lpad((floor(random()*1000000))::int::text, 6, '0');

  -- CHANGE #354 (row 89): the code goes to delivery_otp. deliveries.otp_code is
  -- CHECK-constrained to stay NULL — the assigned rider can read that row.
  insert into public.delivery_otp(delivery_id, code, sent_at, attempts, locked_until, verified_at)
  values (p_delivery_id, v_code, now(), 0, null, null)
  on conflict (delivery_id) do update
    set code = excluded.code, sent_at = now(),
        attempts = 0, locked_until = null, verified_at = null;

  update deliveries set otp_sent_at = now(), otp_verified_at = null
   where id = p_delivery_id;

  -- CHANGE #295: window-gated, and the attempt is logged either way.
  begin
    perform public.wa_notify_event(
      'delivery_otp', null, '{}'::jsonb, null, d.order_id,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
      jsonb_build_object('event','otp','delivery_id',p_delivery_id));
  exception when others then
    perform public._wa_log_attempt('delivery_otp', d.order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'otp_sent', coalesce(auth.jwt()->>'email','rider'));

  return jsonb_build_object('ok',true,'message', public._c('delivery.otp_sent'));
end $function$;

-- 5 ─── verify: counted, locked out, logged, and the code dies on success ────
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

  -- CHANGE #354 (row 89): the lockout. Without it a 6-digit code is a loop away.
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

    -- a failed attempt is now on the record, so a brute force is visible
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
      'message', public._c('delivery.otp_wrong'), 'attempts_left', v_left);
  end if;

  update deliveries set otp_verified_at = now() where id = p_delivery_id;
  v_res := public._delivery_complete(p_delivery_id,'otp',p_lat,p_lng,p_receiver,null);

  -- a used OTP stops existing. Only once the completion actually succeeded —
  -- a cold-chain or handover refusal must leave the code usable for the retry.
  if coalesce((v_res->>'ok')::boolean, false) then
    delete from public.delivery_otp where delivery_id = p_delivery_id;
  end if;
  return v_res;
end $function$;
