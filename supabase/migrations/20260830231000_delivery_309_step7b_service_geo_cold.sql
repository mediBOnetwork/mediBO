-- CHANGE #309 step 7b — SERVICEABILITY (5), GEOFENCE ARRIVAL (9), COLD CHAIN (10).
--
-- (5) SERVICEABILITY. The check has to happen BEFORE the order exists, which is
-- why it hangs off checkout_action() and not off the order. Three answers, not
-- two: serviceable / warn / blocked. "Warn" exists because mediBO's customers
-- are licensed businesses, not walk-ins — refusing a pharmacy outright because
-- its pincode is not on a list yet loses a real customer, so the default for an
-- UNKNOWN pincode is to warn and let the order through.
--
-- (9) GEOFENCE. The rider app already heartbeats its position. That heartbeat
-- now also answers "am I there yet", so arrived_at is stamped and the customer's
-- "arriving now" message fires without the rider having to remember to tap
-- anything while parking a bike.
--
-- (10) COLD CHAIN. A temperature-sensitive line makes the whole parcel cold
-- chain: you cannot half-refrigerate a bag. So the flag is computed from the
-- ORDER's items and cached on the delivery, then it pulls the stop forward in
-- the run and forces a photo at the door.

-- ── (10) the product flag ───────────────────────────────────────────────────
alter table public."MEDICINE"
  add column if not exists cold_chain boolean not null default false;

alter table public.orders
  add column if not exists is_cold_chain boolean;

alter table public.deliveries
  add column if not exists is_cold_chain boolean not null default false;

create index if not exists idx_medicine_cold_chain on public."MEDICINE"(id) where cold_chain;

-- Does this order contain anything temperature-sensitive?
create or replace function public._order_is_cold_chain(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.order_items oi
      join public."MEDICINE" m on m.id = oi.product_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable,false) = false
       and m.cold_chain);
$$;

-- Stamped when the stop is created, and used for sequencing. A cold-chain stop
-- is pulled forward by cold_chain_priority_boost places rather than pinned to
-- position 1: three cold parcels still get an optimised route between them.
create or replace function public.trg_delivery_stamp_cold()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.order_id is not null then
    new.is_cold_chain := coalesce(public._order_is_cold_chain(new.order_id), false);
  end if;
  return new;
end $function$;

drop trigger if exists trg_delivery_stamp_cold on public.deliveries;
create trigger trg_delivery_stamp_cold
  before insert on public.deliveries
  for each row execute function public.trg_delivery_stamp_cold();

-- The render-ready badge, in one place so pack and delivery print the same one.
create or replace function public._cold_chain_block(p_is_cold boolean)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select case when coalesce(p_is_cold,false) then jsonb_build_object(
    'is_cold_chain', true,
    'badge',  public._c('delivery.cold_chain_badge'),
    'note',   public._c('delivery.cold_chain_note'),
    'colors', jsonb_build_object('bg','#EFF6FF','fg','#1E40AF'),
    'photo_required', coalesce((public._dcfg(null)->>'cold_chain_photo_required')::boolean, true))
  else jsonb_build_object('is_cold_chain', false) end;
$$;

-- ── (5) serviceability ──────────────────────────────────────────────────────
create or replace function public.delivery_serviceability_check(p_pincode text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  s public.delivery_serviceability%rowtype;
  v_pin text := nullif(btrim(coalesce(p_pincode,'')),'');
  v_mode text; v_note text; v_zone smallint;
begin
  if v_pin is null then
    return jsonb_build_object(
      'checked', false, 'mode','serviceable', 'can_order', true,
      'title','', 'message', public._c('checkout.serviceable_no_pincode'),
      'tone', jsonb_build_object('bg','#EFF6FF','fg','#1E40AF'));
  end if;

  select * into s from public.delivery_serviceability
   where pincode = v_pin and is_active;

  if s.pincode is null then
    -- Unlisted. The platform default decides, and it defaults to 'warn'.
    v_mode := coalesce(public._dcfg(null)->>'unknown_pincode_mode', 'warn');
    v_zone := null;
  else
    v_mode := s.mode; v_note := s.note; v_zone := s.zone_id;
    -- A pincode inside a zone that has been switched off is not serviceable,
    -- however the pincode row itself is marked.
    if v_mode = 'serviceable'
       and not coalesce((public._dcfg(s.zone_id)->>'zone_serviceable')::boolean, true) then
      v_mode := 'blocked';
    end if;
  end if;

  return jsonb_build_object(
    'checked',  true,
    'pincode',  v_pin,
    'zone_id',  v_zone,
    'mode',     v_mode,
    'can_order', (v_mode <> 'blocked'),
    'is_warning', (v_mode = 'warn'),
    'title', case v_mode
               when 'warn'    then public._c('checkout.serviceable_warn_title')
               when 'blocked' then public._c('checkout.serviceable_blocked_title')
               else '' end,
    'message', coalesce(nullif(v_note,''), case v_mode
               when 'warn'    then public._cf('checkout.serviceable_warn_msg',
                                     jsonb_build_object('pincode', v_pin))
               when 'blocked' then public._cf('checkout.serviceable_blocked_msg',
                                     jsonb_build_object('pincode', v_pin))
               else public._c('checkout.serviceable_ok') end),
    'tone', case v_mode
              when 'warn'    then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
              when 'blocked' then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
              else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end);
end $function$;

create or replace function public.admin_serviceability_set(
  p_pincode text, p_mode text, p_zone smallint default null,
  p_note text default null, p_active boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if coalesce(p_mode,'') not in ('serviceable','warn','blocked') then
    return jsonb_build_object('ok',false,'error','bad_mode');
  end if;
  insert into public.delivery_serviceability(pincode, zone_id, mode, note, is_active, updated_by, updated_at)
  values (btrim(p_pincode), p_zone, p_mode, nullif(btrim(coalesce(p_note,'')),''),
          coalesce(p_active,true), coalesce(auth.jwt()->>'email','admin'), now())
  on conflict (pincode) do update
    set zone_id = excluded.zone_id, mode = excluded.mode, note = excluded.note,
        is_active = excluded.is_active, updated_by = excluded.updated_by, updated_at = now();
  return jsonb_build_object('ok',true,'pincode',btrim(p_pincode),'mode',p_mode);
end $function$;

-- ── checkout_action learns to answer the serviceability question ────────────
-- Extended rather than replaced: the cart already calls it, so the answer
-- arrives with no second round trip on a slow connection.
create or replace function public.checkout_action()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_mode text  := public.payment_collection_mode();
  v_act  uuid  := public.my_acting_as();
  v_role text  := coalesce(public.get_my_role(),'none');
  v_staff boolean := v_role in ('admin','super_admin','worker');
  v_pay  boolean;
  v_pin  text; v_srv jsonb;
begin
  v_pay := (v_mode = 'gateway') and v_act is null and not v_staff;

  -- CHANGE #309 (5): the delivery address is the customer's profile pincode.
  -- When an admin is acting as a customer, it is that CUSTOMER's pincode that
  -- matters, not the admin's own.
  select pp.pincode into v_pin
    from public.pharmacy_profiles pp
   where pp.user_id = coalesce(v_act, auth.uid())
      or pp.id = v_act
   limit 1;

  v_srv := public.delivery_serviceability_check(v_pin);

  return jsonb_build_object(
    'ok', true,
    'collection_mode', v_mode,
    'provider',        case when v_mode = 'gateway' then 'razorpay_qr' else 'upi_manual' end,
    'acting_as',       (v_act is not null),
    'placed_by_admin', (v_act is not null),
    'pay_now',         v_pay,
    'button_label',    case when v_pay then public._rzp_copy('checkout_btn_pay')
                            else public._rzp_copy('checkout_btn_place') end,
    'pay_title',       public._rzp_copy('checkout_pay_title'),
    'actingas_note',   case when v_act is not null and v_mode = 'gateway'
                            then public._rzp_copy('checkout_actingas_note') else '' end,
    'paid_toast',      public._rzp_copy('checkout_paid_toast'),
    'done_label',      public._rzp_copy('checkout_done_label'),
    -- CHANGE #309: serviceability. can_order false is the ONLY thing that
    -- disables the button; a warning is shown and the order still goes through.
    'serviceability',  v_srv,
    'can_order',       coalesce((v_srv->>'can_order')::boolean, true));
end $function$;

-- ── (9) geofence arrival, riding the existing heartbeat ─────────────────────
-- Distance uses the EXISTING public._geo_m() that delivery_optimize_run
-- already uses for stop grouping. A second haversine would be a second answer
-- to the same question, and they would drift.
create or replace function public.delivery_update_location(
  p_lat numeric, p_lng numeric, p_heading numeric default null, p_accuracy numeric default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_partner uuid; cfg jsonb; v_radius numeric; v_min_acc numeric;
  r record; v_arrived jsonb := '[]'::jsonb;
begin
  select id into v_partner from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null then return jsonb_build_object('ok',false,'error','not_a_partner'); end if;

  insert into public.delivery_partner_locations(partner_id, lat, lng, heading, accuracy, updated_at)
  values (v_partner, p_lat, p_lng, p_heading, p_accuracy, now())
  on conflict (partner_id) do update
    set lat=excluded.lat, lng=excluded.lng, heading=excluded.heading,
        accuracy=excluded.accuracy, updated_at=now();

  -- CHANGE #309 (9): arrival detection.
  cfg := public._dcfg(null);
  v_radius  := coalesce((cfg->>'geofence_radius_m')::numeric, 150);
  v_min_acc := coalesce((cfg->>'geofence_min_accuracy_m')::numeric, 250);

  -- A fix this vague would "arrive" the rider three streets away, so a low
  -- accuracy reading updates the position and stamps nothing.
  if p_accuracy is not null and p_accuracy > v_min_acc then
    return jsonb_build_object('ok',true,'arrived',v_arrived,'skipped_accuracy',true);
  end if;

  for r in
    select d.id, d.order_id, d.lat, d.lng
      from public.deliveries d
     where d.partner_id = v_partner
       and d.status = 'out_for_delivery'
       and d.arrived_at is null
       and d.lat is not null and d.lng is not null
  loop
    if public._geo_m(p_lat, p_lng, r.lat, r.lng) <= v_radius then
      update public.deliveries
         set arrived_at = now(), arrived_lat = p_lat, arrived_lng = p_lng
       where id = r.id and arrived_at is null;

      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
      values (r.id, r.order_id, v_partner, 'arrived', 'geofence', p_lat, p_lng, 'system');

      -- Fire "arriving now" exactly once per stop. Wrapped, because a WhatsApp
      -- outage must never stop a rider's location from updating.
      begin
        perform public.wa_notify_event(
          'delivery_arriving', null, '{}'::jsonb, null, r.order_id,
          'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
          jsonb_build_object('event','arriving','delivery_id',r.id));
        update public.deliveries set arrival_notified_at = now() where id = r.id;
      exception when others then
        perform public._wa_log_attempt('delivery_arriving', r.order_id, null, 'skipped', false,
                                       'caller_error: ' || sqlerrm);
      end;

      v_arrived := v_arrived || jsonb_build_object('delivery_id', r.id,
                     'chip', public._c('delivery.arrived_chip'));
    end if;
  end loop;

  return jsonb_build_object('ok',true,'arrived',v_arrived);
end $function$;

grant execute on function public.delivery_serviceability_check(text) to authenticated;
grant execute on function public.admin_serviceability_set(text,text,smallint,text,boolean) to authenticated;
