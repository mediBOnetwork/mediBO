-- CHANGE #309 step 2 — WAREHOUSE -> RIDER HANDOVER SCAN.
--
-- The audit found no handover column anywhere: a parcel went from "packed" to
-- "delivered" with nothing in between, so a parcel lost between the warehouse
-- shelf and the customer's door had no evidence trail at all — no timestamp, no
-- name, nobody who could be shown to have had it.
--
-- This step records custody: WHO handed over, WHO received, WHEN, and where.
-- The same qr_token the doorstep proof already uses is reused, exactly as the
-- spec asks, so nothing new has to be printed on the parcel.
--
-- The one subtlety worth writing down: the SAME token now means two different
-- things at two different moments. A scan before custody is a HANDOVER; a scan
-- at the door is the DELIVERY PROOF. Rather than make the scanner choose (they
-- would choose wrong, in a hurry, in the rain), the backend decides from the
-- delivery's own state and tells the app what just happened. delivery_scan_qr
-- therefore keeps its existing doorstep meaning and simply routes to the
-- handover when the parcel has not been picked up yet.


-- ── A server-side {token} formatter for ui_copy ─────────────────────────────
-- The Dart side already has cf(key, vars); the backend had only the plain
-- reader, so every message with a name or a time in it was being concatenated
-- in SQL. This is the same contract as cf(): unknown key -> empty string, and
-- an unsupplied token is left alone rather than printed as the literal word
-- "null".
create or replace function public._cf(p_key text, p_vars jsonb default '{}'::jsonb)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v text := public._c(p_key); k text;
begin
  if v is null or v = '' then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars,'{}'::jsonb)) loop
    v := replace(v, '{'||k||'}', coalesce(p_vars->>k,''));
  end loop;
  return v;
end $function$;

alter table public.deliveries
  add column if not exists handover_at        timestamptz,
  add column if not exists handover_by        uuid,          -- warehouse side
  add column if not exists handover_to        uuid,          -- rider side
  add column if not exists handover_by_name   text,
  add column if not exists handover_to_name   text,
  add column if not exists handover_lat       numeric,
  add column if not exists handover_lng       numeric,
  add column if not exists handover_method    text;          -- 'qr' | 'manual'

create index if not exists idx_deliveries_handover_pending
  on public.deliveries(partner_id)
  where handover_at is null and status = 'assigned';

-- ── Is this delivery allowed to move without a handover scan? ───────────────
-- True for every parcel created BEFORE the feature shipped. Without this a
-- migration deployed at 22:00 would strand every parcel already on a bike.
create or replace function public._handover_exempt(d public.deliveries)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select not coalesce((public._dcfg(d.zone_id)->>'handover_required')::boolean, true)
      or d.created_at < (public._dcfg(d.zone_id)->>'handover_enforced_from')::timestamptz;
$$;

-- ── The scan itself ─────────────────────────────────────────────────────────
-- Accepts the parcel's qr_token. Resolves the scanner:
--   * the assigned RIDER scanning       -> they are taking custody
--   * an ADMIN/WORKER scanning          -> they are giving custody to the
--                                          rider the stop is already assigned to
-- Either way both sides are named on the row, because "the rider says he never
-- got it" is exactly the dispute this table has to settle.
create or replace function public.delivery_handover_scan(
  p_token text,
  p_lat   numeric default null,
  p_lng   numeric default null,
  p_method text  default 'qr')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.deliveries%rowtype;
  v_me uuid := auth.uid();
  v_role text := coalesce(public.get_my_role(),'none');
  v_is_rider boolean;
  v_staff boolean := v_role in ('admin','super_admin','worker');
  v_rider_user uuid; v_rider_name text;
  v_staff_name text;
  v_by uuid; v_to uuid; v_by_name text; v_to_name text;
begin
  select * into d from public.deliveries
   where qr_token = btrim(coalesce(p_token,''));

  if d.id is null then
    return jsonb_build_object('ok',false,'error','bad_qr',
      'title', public._c('delivery.handover_bad_qr_title'),
      'message', public._c('delivery.handover_bad_qr_msg'));
  end if;

  select p.user_id, p.full_name into v_rider_user, v_rider_name
    from public.delivery_partner_registrations p where p.id = d.partner_id;

  v_is_rider := (v_rider_user is not null and v_rider_user = v_me);

  if not (v_is_rider or v_staff) then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'title', public._c('delivery.handover_denied_title'),
      'message', public._c('delivery.handover_denied_msg'));
  end if;

  -- A parcel the rider has not accepted yet cannot change hands.
  if d.accept_status <> 'accepted' then
    return jsonb_build_object('ok',false,'error','not_accepted',
      'title', public._c('delivery.handover_not_accepted_title'),
      'message', public._c('delivery.handover_not_accepted_msg'));
  end if;

  -- Idempotent: a second scan of the same parcel reports the FIRST handover
  -- rather than overwriting it. Overwriting would destroy the evidence this
  -- whole step exists to create.
  if d.handover_at is not null then
    return jsonb_build_object('ok',true,'already',true,
      'delivery_id', d.id,
      'handover_at', d.handover_at,
      'handed_over_by', coalesce(d.handover_by_name,''),
      'received_by', coalesce(d.handover_to_name,''),
      'title', public._c('delivery.handover_already_title'),
      'message', public._cf('delivery.handover_already_msg',
                   jsonb_build_object('when',
                     to_char(d.handover_at at time zone 'Asia/Kolkata','DD Mon, hh12:MI am'))));
  end if;

  select coalesce(nullif(btrim(p2.full_name),''), au.email, 'staff')
    into v_staff_name
    from auth.users au
    left join public.delivery_partner_registrations p2 on p2.user_id = au.id
   where au.id = v_me;

  if v_is_rider then
    -- The rider scanned: they are the receiver. The giver is whoever marked the
    -- order dispatch-ready, which is the warehouse action that put it on the
    -- shelf; null when that is unknown rather than a guessed name.
    v_to := v_me;  v_to_name := coalesce(v_rider_name, v_staff_name);
    v_by := null;  v_by_name := coalesce((
      select nullif(btrim(e.actor),'') from public.delivery_events e
       where e.order_id = d.order_id and e.event in ('packed','ready','assigned')
       order by e.created_at desc limit 1), '');
  else
    -- Staff scanned: they are the giver, custody passes to the assigned rider.
    v_by := v_me;        v_by_name := v_staff_name;
    v_to := v_rider_user; v_to_name := coalesce(v_rider_name,'');
  end if;

  update public.deliveries
     set handover_at   = now(),
         handover_by   = v_by,
         handover_to   = v_to,
         handover_by_name = nullif(v_by_name,''),
         handover_to_name = nullif(v_to_name,''),
         handover_lat  = p_lat,
         handover_lng  = p_lng,
         handover_method = coalesce(nullif(btrim(p_method),''),'qr'),
         -- This is the gate the spec asks for: the stop becomes
         -- out_for_delivery HERE and nowhere else.
         status = case when status = 'assigned' then 'out_for_delivery' else status end,
         started_at = coalesce(started_at, now())
   where id = d.id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
  values (d.id, d.order_id, d.partner_id, 'handover',
          coalesce(v_by_name,'—') || ' -> ' || coalesce(v_to_name,'—'),
          p_lat, p_lng, coalesce(auth.jwt()->>'email', v_staff_name, 'system'));

  return jsonb_build_object('ok',true,
    'delivery_id', d.id,
    'order_id', d.order_id,
    'status','out_for_delivery',
    'handover_at', now(),
    'handed_over_by', coalesce(v_by_name,''),
    'received_by', coalesce(v_to_name,''),
    'title', public._c('delivery.handover_ok_title'),
    'message', public._cf('delivery.handover_ok_msg',
                 jsonb_build_object('who', coalesce(nullif(v_to_name,''), '—'))));
end $function$;

-- ── The gate: no completion without custody ─────────────────────────────────
-- _delivery_complete is the single choke point every proof method already goes
-- through (QR, OTP, photo, signature, partial, offline replay), so the rule is
-- installed once, here, and cannot be walked around by adding a new proof.
create or replace function public._delivery_complete(
  p_delivery_id uuid, p_method text, p_lat numeric, p_lng numeric,
  p_receiver text default null, p_photo text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.deliveries%rowtype; v_actor text := coalesce(auth.jwt()->>'email','system');
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if d.status = 'delivered' then
    return jsonb_build_object('ok',true,'already',true,'message','Already delivered',
      'delivered_at', d.delivered_at);
  end if;

  -- CHANGE #309 (1): custody must be on record before a delivery can be closed.
  if d.handover_at is null and not public._handover_exempt(d) then
    return jsonb_build_object('ok',false,'error','handover_required',
      'title',   public._c('delivery.handover_required_title'),
      'message', public._c('delivery.handover_required_msg'));
  end if;

  update public.deliveries
     set status='delivered', delivered_at=now(), proof_method=p_method,
         delivered_lat=p_lat, delivered_lng=p_lng,
         receiver_name=coalesce(nullif(btrim(coalesce(p_receiver,'')),''), receiver_name),
         proof_photo_path=coalesce(p_photo, proof_photo_path)
   where id = p_delivery_id;

  update public.orders set shipped_at = coalesce(shipped_at, now()) where id = d.order_id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'delivered', p_method, p_lat, p_lng, v_actor);

  -- CHANGE #295: window-gated. Free-form only while the window is open.
  begin
    perform public.wa_notify_event(
      'delivery_delivered', null, '{}'::jsonb, null, d.order_id,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
      jsonb_build_object('event','delivered','delivery_id',p_delivery_id));
  exception when others then
    perform public._wa_log_attempt('delivery_delivered', d.order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  return jsonb_build_object('ok',true,'status','delivered','method',p_method,
    'message','Delivered', 'delivered_at', now());
end $function$;

-- ── The doorstep scanner learns the second meaning ──────────────────────────
-- Unchanged behaviour at the door. The only addition: a scan of a parcel that
-- has not been picked up yet performs the HANDOVER instead of failing with the
-- new "handover required" refusal, which would be a dead end for the one person
-- holding the parcel and the phone.
create or replace function public.delivery_scan_qr(
  p_token text, p_lat numeric default null, p_lng numeric default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.deliveries%rowtype; v_me uuid := auth.uid(); v_is_rider boolean; v_is_cust boolean;
begin
  select * into d from public.deliveries where qr_token = btrim(coalesce(p_token,''));
  if d.id is null then
    return jsonb_build_object('ok',false,'error','bad_qr','title','Unknown code',
      'message','This QR does not match any delivery.');
  end if;
  if d.accept_status <> 'accepted' then
    return jsonb_build_object('ok',false,'error','not_accepted',
      'title','Not accepted yet','message','The delivery partner has not accepted this yet.');
  end if;

  select exists(select 1 from public.delivery_partner_registrations
                 where id = d.partner_id and user_id = v_me) into v_is_rider;
  select exists(select 1 from public.orders o
                  join public.pharmacy_profiles pp on pp.id = o.customer_id
                 where o.id = d.order_id and pp.user_id = v_me) into v_is_cust;

  if not (v_is_rider or v_is_cust or public.get_my_role() in ('admin','super_admin','worker')) then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'title','Not allowed','message','Only the assigned rider or the customer can scan this.');
  end if;

  -- CHANGE #309 (1): the same token, read in the state the parcel is actually
  -- in. Custody first; the door second. A customer can never take custody.
  if d.handover_at is null and not public._handover_exempt(d) and not v_is_cust then
    return public.delivery_handover_scan(p_token, p_lat, p_lng, 'qr')
           || jsonb_build_object('phase','handover');
  end if;

  return public._delivery_complete(d.id,
           case when v_is_cust then 'qr_customer' else 'qr_agent' end, p_lat, p_lng, null, null)
         || jsonb_build_object('phase','delivered');
end $function$;

grant execute on function public.delivery_handover_scan(text,numeric,numeric,text) to authenticated;
