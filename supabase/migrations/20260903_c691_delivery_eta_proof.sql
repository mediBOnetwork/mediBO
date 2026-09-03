-- CHANGE #691 — register feature_gaps #122 (ETA is written once and never
-- rebased) and #126 (delivery proof is captured and then shown to nobody).
--
-- #122's evidence: deliveries.eta_min was stamped exactly once, by
-- delivery_apply_google, as MINUTES FROM RUN START. delivery_recompute_eta()
-- existed with zero callers — and could not have been called safely anyway: it
-- read eta_min as if it were a PER-LEG duration and wrote the running total
-- back into the same column, so a second call would have compounded every
-- stop's estimate. The fix is a per-leg column (leg_min) that recompute reads
-- and never writes, an absolute eta_at that the customer's clock can be
-- compared against, and three triggers that call it on the three events that
-- actually change the answer: a stop closing, the run starting, and the rider
-- moving.
--
-- #126's evidence: _delivery_complete() stores proof_method, proof_photo_path,
-- receiver_name, delivered_lat/lng, signature_path and handover_at, and every
-- customer-facing payload dropped all of it. One block, _delivery_proof_block,
-- now renders it — in the tracker, on the order, on the timeline every role
-- reads, and inside the bill.
--
-- Idempotent throughout: a resumed worker re-applies this file as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SCHEMA
-- ─────────────────────────────────────────────────────────────────────────────

-- leg_min is the TRAVEL time of the leg that ends at this stop, in minutes.
-- It is written by the optimiser and read by the rebase; the rebase never
-- writes it. That separation is the whole reason a rebase is now repeatable.
alter table public.deliveries
  add column if not exists leg_min integer;

-- The absolute answer. eta_min stays (a wa_token reads it) but now means
-- "minutes from the last rebase", which is the only reading a countdown can use.
alter table public.deliveries
  add column if not exists eta_at timestamptz;

-- The throttle's memory. A rider location update lands every few seconds; a
-- rebase per update would rewrite every open stop in the run each time.
alter table public.delivery_runs
  add column if not exists eta_rebased_at timestamptz;

comment on column public.deliveries.leg_min is
  'CHANGE #691 — travel minutes for the leg ENDING at this stop. Written by the optimiser, read (never written) by delivery_recompute_eta.';
comment on column public.deliveries.eta_at is
  'CHANGE #691 — absolute expected arrival, rebased on every stop completion, run start and rider location update.';
comment on column public.delivery_runs.eta_rebased_at is
  'CHANGE #691 — when the run last rebased. Throttles the rider-location trigger.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. SETTINGS — every number in the ETA is data, not a literal in a function
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.app_settings(key, value) values
  ('delivery_dwell_minutes',           to_jsonb(4)),
  ('delivery_eta_window_minutes',      to_jsonb(20)),
  ('delivery_eta_rebase_min_seconds',  to_jsonb(60)),
  ('delivery_eta_rider_speed_kmh',     to_jsonb(22)),
  ('delivery_eta_fallback_min_per_km', to_jsonb(3))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. COPY — every string the customer reads about an ETA or a proof
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('delivery.eta_heading',          to_jsonb('Expected arrival'::text)),
  ('delivery.eta_prefix',           to_jsonb('Arriving'::text)),
  ('delivery.eta_now',              to_jsonb('Arriving now'::text)),
  ('delivery.eta_unknown',          to_jsonb('Arrival time updates once the rider starts'::text)),
  ('delivery.eta_countdown_one',    to_jsonb('in about a minute'::text)),
  ('delivery.eta_countdown_many',   to_jsonb('in about {n} min'::text)),
  ('delivery.eta_delivered',        to_jsonb('Delivered'::text)),
  ('delivery.eta_rebased_note',     to_jsonb('Updated as the rider moves'::text)),
  ('delivery.proof_heading',        to_jsonb('Proof of delivery'::text)),
  ('delivery.proof_receiver_label', to_jsonb('Received by'::text)),
  ('delivery.proof_time_label',     to_jsonb('Handed over at'::text)),
  ('delivery.proof_method_label',   to_jsonb('Confirmed by'::text)),
  ('delivery.proof_photo_label',    to_jsonb('Delivery photo'::text)),
  ('delivery.proof_sign_label',     to_jsonb('Signature'::text)),
  ('delivery.proof_map_label',      to_jsonb('Delivered at this location'::text)),
  ('delivery.proof_method_otp',       to_jsonb('OTP verified at the door'::text)),
  ('delivery.proof_method_qr',        to_jsonb('QR scanned at the door'::text)),
  ('delivery.proof_method_photo',     to_jsonb('Photo at handover'::text)),
  ('delivery.proof_method_signature', to_jsonb('Signature at handover'::text)),
  ('delivery.proof_method_manual',    to_jsonb('Marked delivered by the rider'::text)),
  ('delivery.proof_method_handover',  to_jsonb('Handed to another rider'::text)),
  ('delivery.proof_none',           to_jsonb('No proof was captured for this delivery'::text)),
  ('bill.proof_heading',            to_jsonb('Proof of delivery'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. BACKFILL leg_min from the cumulative eta_min the optimiser used to write
--    (per run, in seq order: this leg = my cumulative minus the one before me).
-- ─────────────────────────────────────────────────────────────────────────────
with legs as (
  select d.id,
         greatest(coalesce(d.eta_min,0)
                  - coalesce(lag(d.eta_min) over (partition by d.run_id order by d.seq nulls last), 0),
                  0) as lm
    from public.deliveries d
   where d.eta_min is not null and d.leg_min is null and d.run_id is not null
)
update public.deliveries d set leg_min = legs.lm
  from legs where legs.id = d.id and legs.lm > 0;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE OPTIMISER now records the per-leg time as well as the cumulative one.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_apply_google(
  p_run_id uuid, p_optimised_delivery_ids uuid[], p_polyline text default null,
  p_leg_meters integer[] default null, p_leg_seconds integer[] default null,
  p_origin_lat numeric default null, p_origin_lng numeric default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_open int; v_n int; i int; v_seq int := 0; v_cum_m numeric := 0;
  v_leg_m numeric; v_leg_s numeric; v_t numeric := 0; v_partner uuid; v_groups int;
begin
  select partner_id into v_partner from delivery_runs where id = p_run_id;
  if v_partner is null then return jsonb_build_object('ok',false,'error','run_not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = v_partner and user_id = auth.uid())
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_n := coalesce(array_length(p_optimised_delivery_ids,1),0);
  select count(*) into v_open from deliveries
   where run_id = p_run_id and status not in ('delivered','cancelled');
  -- same guard the Route tab uses: the returned list must match the open stops
  if v_n <> v_open then
    return jsonb_build_object('ok',false,'error','stop_count_mismatch',
      'expected', v_open, 'got', v_n,
      'message','The optimised list does not match this run''s stops.');
  end if;

  for i in 1..v_n loop
    v_seq := v_seq + 1;
    v_leg_m := case when p_leg_meters  is not null and i <= array_length(p_leg_meters,1)
                    then p_leg_meters[i] end;
    v_leg_s := case when p_leg_seconds is not null and i <= array_length(p_leg_seconds,1)
                    then p_leg_seconds[i] end;
    v_cum_m := v_cum_m + coalesce(v_leg_m,0);
    v_t := v_t + coalesce(v_leg_s,0);

    update deliveries
       set seq = v_seq,
           leg_km  = case when v_leg_m is not null then round(v_leg_m/1000.0,2) end,
           cum_km  = round(v_cum_m/1000.0,2),
           -- CHANGE #691: the PER-LEG minute, which is the only figure a rebase
           -- can safely read. eta_min stays cumulative for this one write and is
           -- then owned by delivery_recompute_eta.
           leg_min = case when v_leg_s is not null then ceil(v_leg_s/60.0)::int end,
           eta_min = case when p_leg_seconds is not null then ceil(v_t/60.0)::int end
     where id = p_optimised_delivery_ids[i] and run_id = p_run_id;
  end loop;

  -- CHANGE #462 (gap 107): the comment used to say co-located stops stay
  -- together while the loop handed every stop its own group, erasing the 150 m
  -- grouping the optimiser had just built. Re-derive it by the SAME rule, in
  -- the new Google order, from the one function that owns that rule.
  v_groups := public._delivery_regroup_run(p_run_id);

  update delivery_runs
     set road_polyline = coalesce(p_polyline, road_polyline),
         google_optimized = true,
         optimized_at = now(),
         total_km = round(v_cum_m/1000.0,2),
         total_min = case when p_leg_seconds is not null then ceil(v_t/60.0)::int end
   where id = p_run_id;

  -- ...and total_stops means the same thing here as everywhere else.
  perform public._delivery_run_recount(p_run_id);

  -- CHANGE #691: a fresh route is a new answer — rebase immediately.
  perform public.delivery_recompute_eta(p_run_id, true);

  return jsonb_build_object('ok',true,'run_id',p_run_id,'stops',v_seq,
    'stop_groups', v_groups,
    'total_km', round(v_cum_m/1000.0,2),
    'total_min', case when p_leg_seconds is not null then ceil(v_t/60.0)::int end,
    'optimized', true, 'has_polyline', (p_polyline is not null),
    'method','google');
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE REBASE ITSELF — repeatable, because it never reads its own output.
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.delivery_recompute_eta(uuid);

create or replace function public.delivery_recompute_eta(p_run_id uuid, p_force boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  r record;
  v_acc numeric := 0; v_n int := 0; v_first boolean := true;
  v_dwell numeric; v_speed numeric; v_fallback numeric; v_gap numeric;
  v_anchor timestamptz := now();
  v_rlat numeric; v_rlng numeric; v_leg numeric; v_last timestamptz;
begin
  if p_run_id is null then
    return jsonb_build_object('ok',false,'error','no_run');
  end if;

  select eta_rebased_at into v_last from delivery_runs where id = p_run_id;
  if not found then
    return jsonb_build_object('ok',false,'error','run_not_found');
  end if;

  v_dwell    := coalesce((select (value #>> '{}')::numeric from app_settings
                           where key='delivery_dwell_minutes'), 4);
  v_speed    := greatest(coalesce((select (value #>> '{}')::numeric from app_settings
                           where key='delivery_eta_rider_speed_kmh'), 22), 1);
  v_fallback := coalesce((select (value #>> '{}')::numeric from app_settings
                           where key='delivery_eta_fallback_min_per_km'), 3);
  v_gap      := coalesce((select (value #>> '{}')::numeric from app_settings
                           where key='delivery_eta_rebase_min_seconds'), 60);

  -- The rider's location fires this many times a minute. Honour the throttle
  -- unless the caller is one of the two events that genuinely changed the plan.
  if not coalesce(p_force,true)
     and v_last is not null
     and extract(epoch from (v_anchor - v_last)) < v_gap then
    return jsonb_build_object('ok',true,'run_id',p_run_id,'stops_rebased',0,
                              'throttled',true,'next_in_s',
                              ceil(v_gap - extract(epoch from (v_anchor - v_last))));
  end if;

  -- Where the rider actually is, so the FIRST leg is measured from the van and
  -- not from the stop it already left.
  select l.lat, l.lng into v_rlat, v_rlng
    from delivery_partner_locations l
    join delivery_runs run on run.partner_id = l.partner_id
   where run.id = p_run_id;

  for r in
    select d.id, d.leg_km, d.leg_min, d.seq, d.lat, d.lng
      from deliveries d
     where d.run_id = p_run_id
       and d.status in ('assigned','out_for_delivery')
     order by d.seq nulls last, d.created_at
  loop
    if v_first and v_rlat is not null and v_rlng is not null
       and r.lat is not null and r.lng is not null then
      -- straight line at the configured average speed: an honest floor, and the
      -- only figure that changes when the rider moves.
      v_leg := ceil(public._km(v_rlat::double precision, v_rlng::double precision,
                               r.lat::double precision,  r.lng::double precision)
                    * 60.0 / v_speed);
    else
      v_leg := coalesce(nullif(r.leg_min,0), ceil(coalesce(r.leg_km,1) * v_fallback));
    end if;

    v_acc := v_acc + greatest(coalesce(v_leg,0), 0);
    update deliveries
       set eta_min = ceil(v_acc)::int,
           eta_at  = v_anchor + make_interval(mins => ceil(v_acc)::int)
     where id = r.id;

    -- dwell is time spent AT a stop, so it delays every stop after it — never
    -- the one the rider is driving to right now.
    v_acc := v_acc + v_dwell;
    v_first := false;
    v_n := v_n + 1;
  end loop;

  update delivery_runs set eta_rebased_at = v_anchor where id = p_run_id;

  return jsonb_build_object('ok',true,'run_id',p_run_id,'stops_rebased',v_n,
    'dwell_minutes',v_dwell,'anchor',v_anchor,'throttled',false,
    'from_rider_gps',(v_rlat is not null and v_rlng is not null));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE THREE CALLERS. #122 was "zero callers"; this is the whole fix.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_rebase_eta_trg()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_run uuid;
begin
  if tg_table_name = 'deliveries' then
    -- a stop closing (or opening) changes what is left of the run
    v_run := coalesce(new.run_id, old.run_id);
    perform public.delivery_recompute_eta(v_run, true);

  elsif tg_table_name = 'delivery_runs' then
    perform public.delivery_recompute_eta(new.id, true);

  elsif tg_table_name = 'delivery_partner_locations' then
    -- every live run this rider is on, throttled
    for v_run in
      select id from delivery_runs
       where partner_id = new.partner_id and status = 'started'
    loop
      perform public.delivery_recompute_eta(v_run, false);
    end loop;
  end if;
  return null;
exception when others then
  -- an ETA is never worth failing a delivery write for
  return null;
end $function$;

drop trigger if exists trg_delivery_rebase_eta on public.deliveries;
create trigger trg_delivery_rebase_eta
  after update of status on public.deliveries
  for each row
  when (old.status is distinct from new.status and new.run_id is not null)
  execute function public._delivery_rebase_eta_trg();

drop trigger if exists trg_delivery_run_rebase_eta on public.delivery_runs;
create trigger trg_delivery_run_rebase_eta
  after update of status on public.delivery_runs
  for each row
  when (old.status is distinct from new.status and new.status = 'started')
  execute function public._delivery_rebase_eta_trg();

drop trigger if exists trg_delivery_loc_rebase_eta on public.delivery_partner_locations;
create trigger trg_delivery_loc_rebase_eta
  after insert or update of lat, lng on public.delivery_partner_locations
  for each row
  execute function public._delivery_rebase_eta_trg();

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE ARRIVAL WINDOW — one block, worded here, rendered verbatim everywhere.
--    "3 stops before you" was the whole answer a customer got; a stop count is
--    not a time, and it is the only thing this platform could say because
--    nothing ever produced a time to say.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_eta_block(p_delivery_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  d public.deliveries%rowtype;
  v_win int; v_ahead int; v_mins int;
  v_lo timestamptz; v_hi timestamptz;
  v_lo_t text; v_hi_t text; v_lo_m text; v_hi_m text; v_window text;
  v_ahead_label text;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then
    return jsonb_build_object('has', false, 'state', 'none', 'label', '',
      'window_label','','countdown_label','','stops_ahead',0,'stops_ahead_label','');
  end if;

  select count(*) into v_ahead from public.deliveries x
   where x.run_id = d.run_id and x.status in ('assigned','out_for_delivery')
     and coalesce(x.seq, 999999) < coalesce(d.seq, 999999);

  -- the stop-count sentence keeps its exact old wording; it is now the SECOND
  -- line under a time, not the only line there was.
  v_ahead_label := case
      when d.status not in ('assigned','out_for_delivery') then ''
      when coalesce(v_ahead,0) = 0 then 'You are next'
      when v_ahead = 1 then '1 stop before you'
      else v_ahead::text || ' stops before you' end;

  if d.status = 'delivered' then
    return jsonb_build_object(
      'has', false, 'state', 'delivered',
      'heading', public._c('delivery.eta_heading'),
      'label',   public._c('delivery.eta_delivered'),
      'window_label','', 'countdown_label','', 'eta_at', null, 'eta_min', null,
      'stops_ahead', 0, 'stops_ahead_label', '', 'note','');
  end if;

  if d.status not in ('assigned','out_for_delivery') or d.eta_at is null then
    return jsonb_build_object(
      'has', false,
      'state', case when d.status in ('assigned','out_for_delivery') then 'unknown' else 'none' end,
      'heading', public._c('delivery.eta_heading'),
      'label', case when d.status in ('assigned','out_for_delivery')
                    then public._c('delivery.eta_unknown') else '' end,
      'window_label','', 'countdown_label','', 'eta_at', null, 'eta_min', null,
      'stops_ahead', coalesce(v_ahead,0), 'stops_ahead_label', v_ahead_label, 'note','');
  end if;

  v_win := coalesce((select (value #>> '{}')::int from public.app_settings
                      where key='delivery_eta_window_minutes'), 20);
  v_lo := d.eta_at;
  v_hi := d.eta_at + make_interval(mins => v_win);

  v_lo_t := to_char(v_lo at time zone 'Asia/Kolkata','FMHH12:MI');
  v_hi_t := to_char(v_hi at time zone 'Asia/Kolkata','FMHH12:MI');
  v_lo_m := lower(to_char(v_lo at time zone 'Asia/Kolkata','AM'));
  v_hi_m := lower(to_char(v_hi at time zone 'Asia/Kolkata','AM'));

  v_window := case when v_lo_m = v_hi_m
                   then v_lo_t || '–' || v_hi_t || ' ' || v_hi_m
                   else v_lo_t || ' ' || v_lo_m || '–' || v_hi_t || ' ' || v_hi_m end;

  v_mins := ceil(extract(epoch from (d.eta_at - now())) / 60.0)::int;

  return jsonb_build_object(
    'has',   true,
    'state', 'eta',
    'heading', public._c('delivery.eta_heading'),
    -- "Arriving 4:10–4:30 pm"
    'label',  btrim(public._c('delivery.eta_prefix') || ' ' || v_window),
    'window_label', v_window,
    'countdown_label', case
        when v_mins <= 0 then public._c('delivery.eta_now')
        when v_mins = 1  then public._c('delivery.eta_countdown_one')
        else public._cf('delivery.eta_countdown_many', jsonb_build_object('n', v_mins)) end,
    'eta_at',  d.eta_at,
    'eta_min', greatest(v_mins, 0),
    'window_minutes', v_win,
    'stops_ahead', coalesce(v_ahead,0),
    'stops_ahead_label', v_ahead_label,
    'note', public._c('delivery.eta_rebased_note'));
end $function$;

create or replace function public._delivery_eta_for_order(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(
    (select public._delivery_eta_block(d.id) from public.deliveries d
      where d.order_id = p_order_id order by d.created_at desc limit 1),
    jsonb_build_object('has', false, 'state','none','label','','window_label','',
                       'countdown_label','','stops_ahead',0,'stops_ahead_label',''));
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE PROOF BLOCK — #126. Everything _delivery_complete() already stored,
--    said out loud once, in one shape, for every reader.
--    The photo travels as bucket+path (delivery-proofs is private); the client
--    signs it, exactly the way _rider_photo_block already works.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_proof_block(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  d public.deliveries%rowtype;
  v_at timestamptz; v_method text; v_method_label text; v_pt text;
begin
  select * into d from public.deliveries
   where order_id = p_order_id and status = 'delivered'
   order by delivered_at desc nulls last, created_at desc limit 1;

  if d.id is null then
    return jsonb_build_object('has', false, 'heading', public._c('delivery.proof_heading'));
  end if;

  v_at     := coalesce(d.handover_at, d.delivered_at);
  v_method := lower(btrim(coalesce(nullif(d.proof_method,''), 'manual')));
  v_method_label := public.uic('delivery.proof_method_' || v_method, initcap(v_method));

  v_pt := case when d.delivered_lat is null or d.delivered_lng is null then null else
    replace(replace(
      coalesce((select point_deeplink from public.map_config where id = 1),
               'https://www.google.com/maps/search/?api=1&query={lat},{lng}'),
      '{lat}', d.delivered_lat::text), '{lng}', d.delivered_lng::text) end;

  return jsonb_build_object(
    'has',            true,
    'heading',        public._c('delivery.proof_heading'),
    'delivery_id',    d.id,

    'method_key',     v_method,
    'method_label',   v_method_label,
    'method_caption', public._c('delivery.proof_method_label'),

    'has_receiver',   (nullif(btrim(coalesce(d.receiver_name,'')),'') is not null),
    'receiver_caption', public._c('delivery.proof_receiver_label'),
    'receiver_name',  coalesce(nullif(btrim(coalesce(d.receiver_name,'')),''), ''),

    'has_time',       (v_at is not null),
    'time_caption',   public._c('delivery.proof_time_label'),
    'time_label',     public._ist_stamp(v_at),
    'handover_at',    v_at,

    'photo', case when nullif(btrim(coalesce(d.proof_photo_path,'')),'') is not null
                  then jsonb_build_object('has', true, 'bucket','delivery-proofs',
                         'path', d.proof_photo_path,
                         'label', public._c('delivery.proof_photo_label'))
                  else jsonb_build_object('has', false) end,

    'signature', case when nullif(btrim(coalesce(d.signature_path,'')),'') is not null
                  then jsonb_build_object('has', true, 'bucket','delivery-proofs',
                         'path', d.signature_path,
                         'label', public._c('delivery.proof_sign_label'))
                  else jsonb_build_object('has', false) end,

    'map', case when v_pt is not null
                then jsonb_build_object('has', true,
                       'lat', d.delivered_lat, 'lng', d.delivered_lng,
                       'label', public._c('delivery.proof_map_label'), 'url', v_pt)
                else jsonb_build_object('has', false) end);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. THE CUSTOMER'S TRACKER — a time, then the stop count under it, then the
--     proof once it is over.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.customer_track_order(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
        v_last record; v_snapped boolean; v_animate int; v_live jsonb;
        v_eta jsonb; v_proof jsonb;
begin
  select (
      public._is_admin()
      or exists (select 1 from orders o join pharmacy_profiles pp on pp.id = o.customer_id
                  where o.id = p_order_id and pp.user_id = auth.uid())
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations p on p.id = dd.partner_id
                 where dd.order_id = p_order_id and p.user_id = auth.uid())
    ) into v_allowed;
  if not coalesce(v_allowed,false) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_tl := public.order_timeline(p_order_id);

  select * into d from deliveries where order_id = p_order_id;
  if d.id is null then
    return jsonb_build_object('ok',true,'tracking',false,'status','preparing',
      'status_label','Preparing your order', 'timeline', v_tl,
      'has_channel', false,
      'eta', public._delivery_eta_for_order(p_order_id),
      'proof', jsonb_build_object('has', false, 'heading', public._c('delivery.proof_heading')),
      'live', public._delivery_live_block(null));
  end if;
  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(live_animate_ms, 1200) into v_animate from delivery_config where id = 1;

  select snap_lat, snap_lng, snapped, speed_kmh into v_last
    from delivery_run_trail where run_id = d.run_id order by ts desc limit 1;
  v_snapped := coalesce(v_last.snapped,false)
               and v_last.snap_lat is not null and v_last.snap_lng is not null;

  -- CHANGE #691: the stop count and the arrival window now come from ONE block,
  -- so the tracker, the public page and the Orders card cannot disagree.
  v_eta   := public._delivery_eta_block(d.id);
  v_proof := public._delivery_proof_block(p_order_id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

  -- CHANGE #462 (gap 104)
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

  -- The staleness sentence is only meaningful while a rider is supposed to be
  -- moving. On a delivered or failed stop the map is history, not a live feed,
  -- so no "Rider offline" is ever shown for an order that already arrived.
  v_live := case when d.status in ('assigned','out_for_delivery')
                 then public._delivery_live_block(v_loc.updated_at)
                 else public._delivery_live_block(null) end;

  return jsonb_build_object(
    'ok', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', d.status,
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'partner_name', coalesce(v_name,''),
    -- CHANGE #463 (register row 117's deferred half, unblocked by row 121):
    -- the rider's verified face, for the buyer at whose door they are standing.
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    -- CHANGE #691 (gap 122 / 126)
    'eta',   v_eta,
    'proof', v_proof,
    'stops_ahead', v_ahead,
    'stops_ahead_label', nullif(v_eta->>'stops_ahead_label',''),
    'rider_lat', case when d.status in ('assigned','out_for_delivery') then v_loc.lat end,
    'rider_lng', case when d.status in ('assigned','out_for_delivery') then v_loc.lng end,
    -- CHANGE #700: the road-snapped twin, and the one pair a map should plot.
    'rider_snap_lat', case when d.status in ('assigned','out_for_delivery') and v_snapped
                           then v_last.snap_lat end,
    'rider_snap_lng', case when d.status in ('assigned','out_for_delivery') and v_snapped
                           then v_last.snap_lng end,
    'rider_snapped', (d.status in ('assigned','out_for_delivery')) and v_snapped,
    'map_lat', case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lat else v_loc.lat end end,
    'map_lng', case when d.status in ('assigned','out_for_delivery')
                    then case when v_snapped then v_last.snap_lng else v_loc.lng end end,
    'speed_kmh', case when d.status in ('assigned','out_for_delivery') then v_last.speed_kmh end,
    'animate_ms', coalesce(v_animate, 1200),
    'note', case when d.status in ('assigned','out_for_delivery') and not v_snapped
                 then public._c('delivery.live_raw_note') else '' end,
    'live', v_live,
    -- CHANGE #700: the run-scoped broadcast this customer may listen to. The
    -- old view subscribed to postgres_changes on a table that is not in the
    -- publication, so it never received one event.
    'has_channel', (d.run_id is not null and d.status in ('assigned','out_for_delivery')),
    'channel', case when d.run_id is not null and d.status in ('assigned','out_for_delivery')
                    then 'run:' || d.run_id::text end,
    'location_updated_at', v_loc.updated_at,
    'destination_lat', d.lat, 'destination_lng', d.lng,
    'rider_arrived', (d.arrived_at is not null),
    'qr_token', case when v_show_qr then d.qr_token end,
    'delivered_at', d.delivered_at, 'proof_method', d.proof_method,
    'call_action', public._call_action_block('customer','delivery', d.order_id),
    'timeline', v_tl);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. THE PUBLIC LINK — same two blocks, same strings, no login.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_track_public(p_token text)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  d deliveries%rowtype; v_loc delivery_partner_locations%rowtype;
  v_ahead int; v_name text; v_code text; v_show_qr boolean;
  v_eta jsonb; v_proof jsonb;
begin
  select * into d from deliveries where qr_token = btrim(coalesce(p_token,''));
  if d.id is null then
    return jsonb_build_object(
      'ok', false, 'found', false, 'tracking', false,
      'title', 'Tracking link not found',
      'message', 'This tracking link is not valid any more.',
      'status', '', 'status_label', '', 'partner_name', '',
      'stops_ahead', 0, 'stops_ahead_label', '', 'has_stops_ahead', false,
      'eta', jsonb_build_object('has', false, 'state','none','label','',
                                'window_label','','countdown_label',''),
      'proof', jsonb_build_object('has', false),
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
      'order_code', '', 'delivered_at', '', 'qr_token', '');
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(order_code,'') into v_code from orders where id = d.order_id;

  v_eta   := public._delivery_eta_block(d.id);
  v_proof := public._delivery_proof_block(d.order_id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

  -- CHANGE #462 (gap 104): same rule as customer_track_order.
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or not coalesce((public._dcfg(d.zone_id)->>'customer_scan_requires_arrival')::boolean, true));

  return jsonb_build_object(
    'ok', true, 'found', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', coalesce(d.status,''),
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'title', 'Track your order',
    'message', '',
    'partner_name', coalesce(v_name,''),
    'order_code', v_code,
    -- CHANGE #691 (gap 122 / 126)
    'eta',   v_eta,
    'proof', v_proof,
    'stops_ahead', v_ahead,
    'has_stops_ahead', (d.status in ('assigned','out_for_delivery')),
    'stops_ahead_label', coalesce(v_eta->>'stops_ahead_label',''),
    'rider_lat', coalesce(case when d.status in ('assigned','out_for_delivery')
                               then v_loc.lat end, 0),
    'rider_lng', coalesce(case when d.status in ('assigned','out_for_delivery')
                               then v_loc.lng end, 0),
    'has_rider_location', (d.status in ('assigned','out_for_delivery')
                           and v_loc.lat is not null and v_loc.lng is not null),
    'location_updated_at', coalesce(v_loc.updated_at::text,''),
    'destination_lat', coalesce(d.lat, 0),
    'destination_lng', coalesce(d.lng, 0),
    'has_destination', (d.lat is not null and d.lng is not null),
    'rider_arrived', (d.arrived_at is not null),
    -- CHANGE #462: the confirm code is released when the rider is at the door,
    -- so a link holder can no longer close the stop from anywhere.
    'qr_token', case when v_show_qr then coalesce(d.qr_token,'') else '' end,
    'delivered_at', coalesce(d.delivered_at::text,''));
end $function$;

-- 12. ADMIN / PARTNER ORDER TIMELINE (#75) — the same proof, verbatim.
CREATE OR REPLACE FUNCTION public.ops_order_detail(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text   := coalesce(public.get_my_role(), 'none');
  v_partner bigint := public.my_partner_id();
  v_access  text   := 'none';
  v_o       record;
  v_cur     record;
  v_steps   jsonb  := '[]'::jsonb;
begin
  if v_partner is not null then
    v_access := coalesce(public.partner_access('partner.ops_board', v_partner), 'none');
  elsif v_role in ('admin', 'super_admin') then
    v_access := coalesce(public.admin_access('fulfill.ops_board'), 'none');
  end if;
  if v_access = 'none' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.not_authorized', ''));
  end if;

  select o.id, coalesce(o.order_code, '') as order_code, o.total_amount, o.created_at,
         coalesce(o.zone_id, pp.zone_id)::smallint as zone_id,
         coalesce(nullif(btrim(pp.pharmacy_name), ''), nullif(btrim(o.pharmacy_name), ''), '') as customer,
         o.status
    into v_o
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
   where o.id = p_order_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found',
      'title', public.uic('ops_board.detail_not_found_title', 'Order not found'),
      'message', public.uic('ops_board.detail_not_found_message', ''));
  end if;

  if v_partner is not null and v_o.zone_id is distinct from public.partner_zone_id() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('ops_board.not_authorized', ''));
  end if;

  select * into v_cur from public._ops_order_stage(null) s where s.order_id = p_order_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'stage_key',   st.stage_key,
           'label',       st.label,
           'owner_label', st.owner_label,
           'next_action', st.next_action,
           'is_current',  (h.left_at is null and h.entered_at is not null),
           'reached',     (h.entered_at is not null),
           'entered_label', case when h.entered_at is null then ''
                                 else public.ist_fmt(h.entered_at, 'datetime') end,
           'spent_label', case
              when h.entered_at is null then ''
              when h.left_at is not null then public.ops_dur_label(extract(epoch from (h.left_at - h.entered_at)))
              else public.ops_dur_label(extract(epoch from (now() - h.entered_at))) end,
           'sla_label',   case when cfg.sla_minutes is null then ''
                              else replace(public.uic('ops_board.sla_label', 'SLA {d}'), '{d}',
                                           public.ops_dur_label(cfg.sla_minutes * 60)) end,
           'tone', case
              when h.entered_at is null then 'neutral'
              when cfg.sla_minutes is null then 'neutral'
              when coalesce(h.left_at, now()) - h.entered_at
                   >= make_interval(mins => cfg.sla_minutes) then 'red'
              when coalesce(h.left_at, now()) - h.entered_at
                   >= make_interval(secs => cfg.sla_minutes * 60 * cfg.amber_pct / 100.0) then 'amber'
              else 'green' end)
           order by st.sort_order), '[]'::jsonb)
    into v_steps
    from sla_stage st
    left join order_stage_history h on h.order_id = p_order_id and h.stage_key = st.stage_key
    left join lateral (
      select f.sla_minutes, f.amber_pct from sla_config f
       where f.stage_key = st.stage_key and f.is_active
         and (f.zone_id = v_o.zone_id or f.zone_id is null)
       order by (f.zone_id is null) limit 1) cfg on true
   where st.is_active;

  return jsonb_build_object(
    'ok', true,
    'order_id', v_o.id::text,
    'order_code', v_o.order_code,
    'customer', v_o.customer,
    'amount_display', public.inr_money(coalesce(v_o.total_amount, 0)),
    'zone_label', coalesce((select z.name from zones z where z.id = v_o.zone_id), ''),
    'placed_label', replace(public.uic('ops_board.placed_label', 'Placed {t}'), '{t}',
                            public.ist_fmt(v_o.created_at, 'datetime')),
    'status_label', coalesce((select l.label from order_status_label l where l.status = v_o.status), v_o.status),
    'current_stage', coalesce(v_cur.stage_key, ''),
    'next_action', coalesce((select st.next_action from sla_stage st where st.stage_key = v_cur.stage_key), ''),
    -- CHANGE #691 (gap 126): the same proof block the customer sees.
    'proof', public._delivery_proof_block(p_order_id),
    'timeline_title', public.uic('ops_board.timeline_title', 'Stage timeline'),
    'steps', v_steps);
end $function$;


-- 13. THE SHARED STAGE TIMELINE — proof + arrival window ride along.
CREATE OR REPLACE FUNCTION public.order_timeline(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype; d public.deliveries%rowtype;
  cfg jsonb := coalesce((select value from public.app_settings where key='order_timeline_config'), '{}'::jsonb);
  ts jsonb; steps jsonb := '[]'::jsonb; st jsonb; k text;
  v_current text; v_eta text; v_eta_ts timestamptz; v_state text;
  v_hit boolean := false;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found');
  end if;
  select * into d from public.deliveries where order_id = p_order_id
   order by created_at desc limit 1;

  -- When each step actually happened. NULL = it has not happened.
  ts := jsonb_build_object(
    'placed',     o.created_at,
    'sourcing',   case when coalesce(o.status,'') in ('accepted','packed','shipped','delivered','completed')
                         or coalesce(o.fulfillment_status,'') <> 'open'
                       then coalesce(o.order_date::timestamptz, o.created_at) end,
    'packed',     case when coalesce(o.dispatch_ready,false) then coalesce(o.dispatch_ready_at, o.shipped_at) end,
    'dispatched', case when d.id is not null and coalesce(d.status,'') in ('out_for_delivery','delivered','rto')
                       then coalesce(d.started_at, d.assigned_at, o.shipped_at) end,
    'delivered',  d.delivered_at);

  -- The furthest step that has happened is 'current'; everything after is
  -- pending. Walking the list backwards keeps that a single pass.
  for i in reverse jsonb_array_length(coalesce(cfg->'steps','[]'::jsonb))-1 .. 0 loop
    k := (cfg->'steps'->i)->>'key';
    if not v_hit and nullif(ts->>k,'') is not null then
      v_hit := true; v_current := k;
    end if;
  end loop;
  if v_current is null then v_current := 'placed'; end if;

  v_hit := false;
  for i in 0 .. jsonb_array_length(coalesce(cfg->'steps','[]'::jsonb))-1 loop
    st := cfg->'steps'->i;
    k  := st->>'key';
    if v_hit then
      v_state := 'pending';
    elsif k = v_current then
      v_state := case when k = 'delivered' then 'done' else 'current' end;
      v_hit := true;
    else
      v_state := 'done';
    end if;
    steps := steps || jsonb_build_array(jsonb_build_object(
      'key',       k,
      'label',     st->>'label',
      'state',     v_state,
      'done',      (v_state = 'done'),
      'current',   (v_state = 'current'),
      'ts_label',  public._ist_stamp(nullif(ts->>k,'')::timestamptz),
      'has_ts',    (nullif(ts->>k,'') is not null),
      'note',      case when v_state = 'pending' then coalesce(st->>'pending_note','') else '' end));
  end loop;

  -- Expected delivery: the rider's promise when there is one, otherwise the
  -- configured window from the day the order was placed, otherwise say so.
  v_eta_ts := coalesce(d.promised_at, d.next_attempt_on::timestamptz);
  if d.delivered_at is not null then
    v_eta := public._ist_stamp(d.delivered_at);
  elsif v_eta_ts is not null then
    v_eta := public._ist_stamp(v_eta_ts);
  elsif coalesce(o.status,'') = 'cancelled' then
    v_eta := '';
  else
    v_eta := '';
  end if;

  return jsonb_build_object(
    'ok', true,
    'heading',      coalesce(cfg->>'heading','Order progress'),
    'current',      v_current,
    'steps',        steps,
    'eta_label',    coalesce(cfg->>'eta_label','Expected delivery'),
    'eta_display',  coalesce(nullif(v_eta,''), coalesce(cfg->>'eta_unknown','')),
    'has_eta',      (nullif(v_eta,'') is not null),
    -- CHANGE #691 (gap 126)
    'proof', public._delivery_proof_block(p_order_id),
    'eta',   public._delivery_eta_for_order(p_order_id),
    'placed_label', coalesce(cfg->>'placed_label','Placed'),
    'placed_at_label', public._ist_stamp(o.created_at));
end $function$;


-- 14. THE ORDERS CARD — an arrival window, not just a stage word.
CREATE OR REPLACE FUNCTION public._order_customer_card(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype;
  st jsonb; v_n int; v_amount numeric; v_amount_label text; v_billed boolean;
  v_paid boolean; v_awaiting boolean; v_act text; v_sit text;
  v_map jsonb := coalesce((select value from app_settings where key='orders_card_action_map'),
                          '{}'::jsonb);
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;
  st := public._order_customer_stage(p_order_id);

  select count(distinct oi.product_id) into v_n
    from public.order_items oi where oi.order_id = p_order_id;

  v_amount := coalesce(o.total_amount, 0);
  v_billed := (nullif(btrim(coalesce(o.invoice_no,'')),'') is not null)
              or (nullif(btrim(coalesce(o.cust_bill_path,'')),'') is not null);

  -- ₹0.00 was rendering as a price and reading like a bug. Zero is never a
  -- price here: on a live order it means the rate is not fixed yet, and on a
  -- finished one it means no bill was raised. Two facts, two sentences.
  if v_amount > 0 then
    v_amount_label := public.inr_money(v_amount);
  elsif coalesce((st->>'is_active')::boolean,false) and not v_billed then
    v_amount_label := public._c('orders.rate_on_confirmation');
  else
    v_amount_label := public._c('orders.not_billed');
  end if;

  select exists (select 1 from public.payment_claims c
                  where c.order_id = p_order_id
                    and lower(coalesce(c.status,'')) in ('verified','received'))
    into v_paid;
  v_awaiting := (v_amount > 0) and (not v_paid)
                and (v_billed or coalesce(o.dispatch_ready,false)
                     or coalesce((st->>'is_delivered')::boolean,false));

  -- WHICH action a card offers is DATA. The card works out the SITUATION —
  -- five facts, not five labels — and app_settings.orders_card_action_map says
  -- what each situation is worth tapping. Om changed this once already (a
  -- pre-inquiry Pending order offers the change window, not a tracker), and
  -- that change must never again be a deploy.
  if coalesce((st->>'is_cancelled')::boolean,false) then
    v_sit := 'cancelled';
  elsif v_awaiting then
    v_sit := 'awaiting_payment';
  elsif coalesce((st->>'is_active')::boolean,false) then
    v_sit := case when coalesce((public._order_change_gate(p_order_id)->>'open')::boolean,false)
                  then 'change_window_open' else 'active' end;
  else
    v_sit := 'finished';
  end if;
  v_act := coalesce(nullif(v_map->>v_sit,''), 'track');

  return jsonb_build_object(
    'id',              coalesce(o.id::text,''),
    'order_code',      coalesce(o.order_code,''),
    'placed_at',       coalesce(o.created_at::text,''),
    'date_label',      public._ist_stamp(o.created_at),
    'header_label',    coalesce(nullif(o.order_code,''), '') ,
    'item_count',      coalesce(v_n,0),
    'item_count_label',
      replace(case when coalesce(v_n,0) = 1 then public._c('orders.item_count_one')
                   else public._c('orders.item_count_many') end,
              '{n}', coalesce(v_n,0)::text),
    'amount',          v_amount,
    'amount_label',    v_amount_label,
    'amount_is_money', (v_amount > 0),
    'stage_key',       st->>'key',
    'stage_label',     st->>'label',
    'progress',        jsonb_build_object(
                          'show',  (st->>'show_progress')::boolean,
                          'index', (st->>'index')::int,
                          'steps', st->'steps'),
    'placed_by_admin', coalesce(o.placed_by_admin,false),
    'placed_by_admin_label', case when coalesce(o.placed_by_admin,false)
                                  then public._c('orders.placed_by_admin') else '' end,
    'unfulfilled_count', coalesce(o.unfulfilled_count,0),
    'primary_action',  jsonb_build_object(
                          'key',   v_act,
                          'label', public._c('orders.action_' || v_act),
                          'tone',  coalesce(nullif(v_map->'_tones'->>v_act,''),
                                            case v_act when 'reorder' then 'outline'
                                                       else 'brand' end)),
    -- CHANGE #691 (gap 122/126): the countdown on the card, and the proof
    -- once the order is closed. Both are finished strings.
    'eta',             public._delivery_eta_for_order(p_order_id),
    'proof',           public._delivery_proof_block(p_order_id),
    'situation',       v_sit);
end $function$;


-- 15. THE CUSTOMER'S ORDER PAGE.
CREATE OR REPLACE FUNCTION public.customer_order_detail(p_order_id uuid, p_view_as_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype;
  v_cust uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_gate jsonb; v_actions jsonb := '[]'::jsonb; v_open_tickets int;
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public._c('order_change.reason_not_found'));
  end if;

  if p_view_as_user is not null and v_admin then
    v_cust := coalesce(public.customer_id_for_user(p_view_as_user), p_view_as_user);
  else
    v_cust := public.my_customer_id();
  end if;
  if not (o.customer_id is not distinct from v_cust or v_admin) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._c('order_change.reason_not_authorized'));
  end if;

  v_gate := public._order_change_gate(p_order_id);

  -- The two doors. Present ONLY while the window is open; there is no
  -- disabled state to tap and be refused by.
  if coalesce((v_gate->>'can_edit')::boolean,false) then
    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
      'key','edit', 'label', coalesce(v_gate->>'edit_label', public.ui_text('order_edit.button')),
      'tone','outline', 'enabled', true, 'badge', '', 'note', ''));
  end if;
  if coalesce((v_gate->>'can_cancel')::boolean,false) then
    v_actions := v_actions || jsonb_build_array(jsonb_build_object(
      'key','cancel', 'label', coalesce(v_gate->>'cancel_label', public._c('cancel.cust_action_label')),
      'tone','danger', 'enabled', true, 'badge', '', 'note', ''));
  end if;

  -- Everything else the buyer may do on this order (returns #131, help #132)
  -- still comes from _order_customer_actions. Cancel is DROPPED from that list
  -- here: the gate above owns that door now, and two sources for one button is
  -- exactly the disagreement Part B collapses.
  v_actions := v_actions || coalesce((
    select jsonb_agg(a order by ord)
      from (select a, ordinality as ord
              from jsonb_array_elements(
                     coalesce(public._order_customer_actions(p_order_id), '[]'::jsonb))
                   with ordinality as t(a, ordinality)
             where coalesce(a->>'key','') <> 'cancel') q), '[]'::jsonb);

  select count(*) into v_open_tickets from public.support_ticket
   where order_id = p_order_id and status <> 'closed';

  return jsonb_build_object(
    'ok',    true,
    'title', public._c('orders.detail_title'),
    'order', public._order_customer_row(p_order_id),
    'card',  public._order_customer_card(p_order_id),
    'stage', public._order_customer_stage(p_order_id),
    'tabs',  jsonb_build_array(
       jsonb_build_object('key','items',   'label', public._c('orders.tab_items')),
       jsonb_build_object('key','payment', 'label', public._c('orders.tab_payment')),
       jsonb_build_object('key','bill',    'label', public._c('orders.tab_bill')),
       jsonb_build_object('key','help',    'label', public._c('orders.tab_help'))),
    'change_window', v_gate,
    'actions', v_actions,
    'window_note', case when coalesce((v_gate->>'open')::boolean,false)
                        then '' else coalesce(v_gate->>'reason','') end,
    -- CHANGE #691 (gap 126)
    'proof', public._delivery_proof_block(p_order_id),
    'eta',   public._delivery_eta_for_order(p_order_id),
    'help', jsonb_build_object(
       'title', public._c('orders.help_title'),
       'open_count', coalesce(v_open_tickets,0),
       'label', public._c('support.order_action_label')));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 16. THE BILL CARRIES THE PROOF.
--     The renderer (supabase/functions/bill-render) draws customer_bill()
--     verbatim, so the block is attached to the composed document rather than
--     wired through _bill_compose's signature — every other caller of that
--     composer (POS, sample, agency) is untouched.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.customer_bill(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  cfg public.billing_config%rowtype;
  o   public.orders%rowtype;
  ph  public.pharmacy_profiles%rowtype;
  v_ready jsonb; v_raw jsonb; v_paid numeric; v_adv numeric;
  v_base numeric; v_slab jsonb; v_taxable numeric; v_del jsonb; v_credits jsonb;
  v_supplied boolean; v_doc jsonb; v_number text; v_proof jsonb;
begin
  perform public._assert_can_see_order(p_order_id);
  select * into cfg from public.billing_config where id = 1;
  select * into o   from public.orders where id = p_order_id;
  select * into ph  from public.pharmacy_profiles where user_id = o.user_id limit 1;

  v_ready := public._bill_ready(p_order_id);
  if not (v_ready->>'ready')::boolean then
    return jsonb_build_object('ready', false,
      'status_label', public.uic('bill.not_ready_title','Invoice not ready'),
      'unbilled_items', (v_ready->>'uncovered')::int,
      'items_without_supplier', (v_ready->>'items_without_supplier')::int,
      'unrated_lines', v_ready->'unrated_lines',
      'message', (v_ready->>'uncovered') || ' item(s) on this order do not have a rate yet'
                 || case when (v_ready->>'items_without_supplier')::int > 0
                         then ' (' || (v_ready->>'items_without_supplier')
                              || ' still awaiting a supplier).'
                         else '.' end);
  end if;

  v_raw    := public._bill_lines_for_order(p_order_id);
  v_paid   := public._order_paid_net(p_order_id);
  v_supplied := public._order_is_supplied(p_order_id);

  -- The number is drawn from the statutory series ONLY for a real supply, and
  -- only once. A proforma stays unnumbered.
  if v_supplied then
    perform public.customer_invoice_issue(p_order_id);
    select invoice_no into v_number from orders where id = p_order_id;
    perform public.order_slab_snapshot(p_order_id);
  end if;

  select round(coalesce(sum(oi.quantity*oi.mrp),0) * coalesce(cfg.advance_pct,30)/100, 2)
    into v_adv from public.order_items oi where oi.order_id = p_order_id;

  select coalesce(sum(round(qty*ptr,2)),0) into v_base
    from (select coalesce((e->>'qty')::numeric,0) qty, coalesce((e->>'ptr')::numeric,0) ptr
            from jsonb_array_elements(coalesce(v_raw,'[]'::jsonb)) e) t;

  v_slab := public._order_slab_for_bill(p_order_id, v_base);
  v_taxable := round(v_base * (100 - coalesce((v_slab->>'discount_pct')::numeric,0)) / 100, 2);
  v_del := public._order_delivery_charge(p_order_id, v_taxable);
  v_credits := public._order_credit_notes(p_order_id);

  v_doc := public._bill_compose(
    v_raw,
    jsonb_build_object(
      'number', coalesce(v_number,
                         coalesce(cfg.invoice_prefix,'MB') || '-' || coalesce(o.order_code,'')),
      'date',   to_char(coalesce(o.invoice_issued_at, now()) at time zone 'Asia/Kolkata','DD/MM/YYYY'),
      'slab',   v_slab,
      'buyer',  jsonb_build_object(
        'name',    coalesce(ph.pharmacy_name, o.pharmacy_name),
        'gstin',   coalesce(ph.gstin, ph.gst_no),
        'dl',      coalesce(ph.drug_license, ph.dl_20b),
        'address', coalesce(ph.address, o.address),
        'state',   ph.state,
        'phone',   coalesce(ph.phone, o.phone))),
    v_paid, v_adv, false, null, v_del, v_credits);

  -- Proforma vs tax invoice is the BACKEND's word, and it is the only thing
  -- that overrides _bill_compose's own titling.
  if not v_supplied then
    v_doc := v_doc
      || jsonb_build_object(
           'title',           public.uic('bill.proforma_title','PROFORMA INVOICE'),
           'proforma',        true,
           'proforma_banner', public.uic('bill.proforma_banner',''),
           'proforma_reason', public.uic('bill.proforma_reason',
                                         'A tax invoice is raised when the order is dispatched.'));
    v_doc := jsonb_set(v_doc, '{invoice,number}', to_jsonb(''::text));
    v_doc := jsonb_set(v_doc, '{invoice,number_pending}',
                       to_jsonb(public.uic('bill.proforma_reason','')));
  else
    v_doc := v_doc || jsonb_build_object('proforma', false, 'invoice_no', v_number);
  end if;

  -- CHANGE #691 (gap 126): who took it, when, and the photo of the handover —
  -- on the document the buyer files. `has:false` means the renderer prints
  -- nothing at all, never an empty "Proof of delivery" heading.
  v_proof := public._delivery_proof_block(p_order_id);

  return v_doc || jsonb_build_object('is_supplied', v_supplied,
                                     'delivery_proof', v_proof);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 17. WHATSAPP — the window travels with the "out for delivery" message.
--     wa_token_sources is data: a new token is an INSERT, and every template
--     Om edits in the app can now pick "Arrival window" off the token list.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.wa_token_sources(key, label, description, sql_expr,
                                    needs_order, needs_customer, enabled, is_system)
values
  ('delivery_eta_window', 'Arrival window',
   'The formatted arrival window for the order''s delivery, e.g. 4:10-4:30 pm.',
   $$select nullif(public._delivery_eta_for_order($2)->>'window_label','')$$,
   true, false, true, true),
  ('delivery_eta_label', 'Arrival window sentence',
   'The full arrival sentence, e.g. "Arriving 4:10-4:30 pm".',
   $$select nullif(public._delivery_eta_for_order($2)->>'label','')$$,
   true, false, true, true),
  ('delivery_receiver_name', 'Who received the order',
   'The name captured at handover.',
   $$select nullif(public._delivery_proof_block($2)->>'receiver_name','')$$,
   true, false, true, true),
  ('delivery_proof_time', 'Handover time',
   'When the order was handed over, in IST.',
   $$select nullif(public._delivery_proof_block($2)->>'time_label','')$$,
   true, false, true, true)
on conflict (key) do update
  set sql_expr = excluded.sql_expr,
      label    = excluded.label,
      enabled  = true;

insert into public.wa_tokens(key, label, group_label, source_kind, source_ref,
                             format, fallback, example, enabled, is_system, sort_order)
values
  ('delivery_eta_window', 'Arrival window', 'Delivery', 'computed',
   'delivery_eta_window', 'plain', 'shortly', '4:10-4:30 pm', true, true, 83),
  ('delivery_eta_label', 'Arrival sentence', 'Delivery', 'computed',
   'delivery_eta_label', 'plain', 'Arriving shortly', 'Arriving 4:10-4:30 pm', true, true, 84),
  ('delivery_receiver_name', 'Received by', 'Delivery', 'computed',
   'delivery_receiver_name', 'title_case', '-', 'Ramesh Kumar', true, true, 87),
  ('delivery_proof_time', 'Handover time', 'Delivery', 'computed',
   'delivery_proof_time', 'plain', '-', '03 Sep 2026, 04:18 PM', true, true, 88)
on conflict (key) do nothing;

-- The free-text "out for delivery" message is what actually reaches a customer
-- while the 24h window is open. It is an app_settings string with placeholders,
-- so the window costs no Meta review. Idempotent: the {eta} line is added once.
update public.app_settings
   set value = to_jsonb(replace(value #>> '{}', 'Live track:',
                                'Expected: {eta}' || chr(10) || 'Live track:'))
 where key = 'delivery_out_message'
   and (value #>> '{}') not like '%{eta}%'
   and (value #>> '{}') like '%Live track:%';

-- ...and if Om has since reworded it past that anchor, append the line rather
-- than lose it.
update public.app_settings
   set value = to_jsonb((value #>> '{}') || chr(10) || 'Expected: {eta}')
 where key = 'delivery_out_message'
   and (value #>> '{}') not like '%{eta}%';

insert into public.app_settings(key, value)
values ('delivery_out_message', to_jsonb(
  (chr(128658) || ' *Out for delivery*' || chr(10) || chr(10) ||
   '{pharmacy}, aapka order {code} raaste mein hai.' || chr(10) ||
   'Delivery partner: {rider}' || chr(10) || chr(10) ||
   'Expected: {eta}' || chr(10) ||
   'Live track: {link}')::text))
on conflict (key) do nothing;

-- 18. THE INVOICE CARD carries the proof too — same block, same words.
CREATE OR REPLACE FUNCTION public.customer_invoice(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o orders%rowtype; v_doc jsonb; v_file jsonb;
begin
  perform public._assert_can_see_order(p_order_id);
  select * into o from orders where id = p_order_id;
  v_doc := public.customer_bill(p_order_id);

  v_file := case when o.cust_bill_path is not null
    then jsonb_build_object('has', true, 'bucket', o.cust_bill_bucket,
           'path', o.cust_bill_path, 'name', o.cust_bill_name,
           'uploaded_at', o.cust_bill_uploaded_at, 'uploaded_by', o.cust_bill_uploaded_by)
    else jsonb_build_object('has', false) end;

  return jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'order_code', coalesce(o.order_code,''),
    'ready',      coalesce((v_doc->>'ready')::boolean, false),
    -- the document's own title: TAX INVOICE once dispatched, PROFORMA before
    'title',      coalesce(v_doc->>'title', public.uic('bill.not_ready_title','Invoice not ready')),
    'proforma',   coalesce((v_doc->>'proforma')::boolean, false),
    'invoice_no', coalesce(o.invoice_no, ''),
    'issued_label', case when o.invoice_issued_at is not null
                         then public.ist_fmt(o.invoice_issued_at, 'date') else '' end,
    'not_ready_message', case when coalesce((v_doc->>'ready')::boolean,false)
                              then '' else coalesce(v_doc->>'message','') end,
    'unrated_lines', coalesce(v_doc->'unrated_lines', '[]'::jsonb),
    -- CHANGE #691 (register row 126): the proof rides with the invoice,
    -- so the document the buyer files and the card they read agree.
    'delivery_proof', public._delivery_proof_block(p_order_id),
    'open_label',   public.uic('bill.open_label','View invoice'),
    'file',       v_file,
    'document',   case when coalesce((v_doc->>'ready')::boolean,false) then v_doc else null end);
end $function$;
