-- CHANGE #703 — Geofence arrival flow.
--
-- Every statement below was applied live in the order it appears, and every one
-- of them is idempotent: `add column if not exists`, `create or replace`,
-- `on conflict do update`. A resumed worker re-running this file is a no-op.
--
-- 1. schema      — two rings + an exit radius + the anomaly thresholds, per zone
-- 2. copy/routes — every sentence, and the notify() routes that carry them
-- 3. geofence    — _c703_geofence_eval: 500 m alert once, 50 m auto-arrival +
--                  dwell timer, exit radius -> missed handover (and its undo)
-- 4. anomalies   — off-route (segment distance to the run polyline), speeding,
--                  stationary, GPS-silent; one open row per kind per run
-- 5. ticks       — the two rules an ABSENT fix proves, plus cold chain
-- 6. wiring      — delivery_update_location, customer_track_order,
--                  delivery_track_public, my_delivery_run, _exception_rows
-- 7. proof       — c703_geofence_proof(): 28 assertions over a simulated run

-- CHANGE #703 part 1 — geofence arrival flow: schema, config, copy, routes.
-- Idempotent: a resumed worker re-applies this as a no-op.

-- ── 1. Two rings, an exit radius and the anomaly thresholds ────────────────
alter table public.delivery_config
  add column if not exists approach_radius_m       integer  not null default 500,
  add column if not exists arrival_radius_m        integer  not null default 50,
  add column if not exists handover_exit_m         integer  not null default 800,
  add column if not exists approach_eta_min        integer  not null default 3,
  add column if not exists cold_chain_window_min   integer  not null default 120,
  add column if not exists anomaly_enabled         boolean  not null default true,
  add column if not exists anomaly_offroute_m      integer  not null default 400,
  add column if not exists anomaly_offroute_min    integer  not null default 3,
  add column if not exists anomaly_stationary_min  integer  not null default 10,
  add column if not exists anomaly_speed_kmh       integer  not null default 80,
  add column if not exists anomaly_gps_silent_min  integer  not null default 5;

-- Per zone: the spec's "config per zone". NULL means "use the platform default",
-- exactly like every other column on this table.
alter table public.zone_delivery_config
  add column if not exists approach_radius_m       integer,
  add column if not exists arrival_radius_m        integer,
  add column if not exists handover_exit_m         integer,
  add column if not exists cold_chain_window_min   integer,
  add column if not exists anomaly_enabled         boolean,
  add column if not exists anomaly_offroute_m      integer,
  add column if not exists anomaly_offroute_min    integer,
  add column if not exists anomaly_stationary_min  integer,
  add column if not exists anomaly_speed_kmh       integer,
  add column if not exists anomaly_gps_silent_min  integer;

-- ── 2. The stop's own arrival state ────────────────────────────────────────
alter table public.deliveries
  add column if not exists approach_notified_at   timestamptz,
  add column if not exists approach_lat           numeric,
  add column if not exists approach_lng           numeric,
  add column if not exists dwell_started_at       timestamptz,
  add column if not exists arrival_confirmed_at   timestamptz,
  add column if not exists missed_handover_at     timestamptz,
  add column if not exists missed_handover_count  integer not null default 0,
  add column if not exists cold_breach_at         timestamptz;

create index if not exists idx_deliveries_live_geofence
  on public.deliveries (partner_id, status)
  where status = 'out_for_delivery';

-- ── 3. Anomalies, one open row per kind per run ────────────────────────────
create table if not exists public.delivery_anomaly (
  id           bigserial primary key,
  run_id       uuid,
  partner_id   uuid,
  delivery_id  uuid,
  zone_id      smallint,
  kind         text        not null,
  detail       jsonb       not null default '{}'::jsonb,
  opened_at    timestamptz not null default now(),
  cleared_at   timestamptz,
  notified_at  timestamptz,
  nudged_at    timestamptz,
  rebased_at   timestamptz,
  created_at   timestamptz not null default now()
);

create unique index if not exists uq_delivery_anomaly_open
  on public.delivery_anomaly (run_id, kind) where cleared_at is null;
create index if not exists idx_delivery_anomaly_open
  on public.delivery_anomaly (opened_at desc) where cleared_at is null;

alter table public.delivery_anomaly enable row level security;
-- No policy: reads go through SECURITY DEFINER RPCs only, exactly like
-- delivery_run_trail. A bare client select returns nothing.

-- ── 4. Anomaly kinds are DATA, so a new rule is an INSERT, not a deploy ────
create table if not exists public.delivery_anomaly_kind (
  kind        text primary key,
  label       text not null,
  severity    smallint not null default 3,
  sort_rank   smallint not null default 50,
  nudges_rider boolean not null default true,
  rebases_eta boolean not null default false,
  enabled     boolean not null default true
);

insert into public.delivery_anomaly_kind (kind,label,severity,sort_rank,nudges_rider,rebases_eta,enabled) values
  ('off_route',   'Off route',              3, 10, true,  true,  true),
  ('stationary',  'Stopped mid-run',        3, 20, true,  true,  true),
  ('overspeed',   'Speeding',               2, 30, true,  false, true),
  ('gps_silent',  'No GPS signal',          3, 40, false, false, true)
on conflict (kind) do nothing;

-- ── 5. Exceptions console: three new reason codes (registry data) ──────────
insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind, action_route, sort_rank, enabled)
values
  ('rider_anomaly',      'delivery_anomaly', 3, 0, 'zone', 'route', 'delivery_run', 50, true),
  ('missed_handover',    'deliveries',       3, 0, 'zone', 'route', 'delivery_run', 52, true),
  ('cold_chain_breach',  'deliveries',       2, 0, 'zone', 'route', 'delivery_run', 48, true)
on conflict (reason_code) do update
  set source_key = excluded.source_key, severity = excluded.severity,
      owner_kind = excluded.owner_kind, action_kind = excluded.action_kind,
      action_route = excluded.action_route, sort_rank = excluded.sort_rank,
      enabled = excluded.enabled;
-- CHANGE #703 part 2 — every sentence this feature can print, and the routes
-- that carry it. Wording changes are an UPDATE here, never a deploy.

insert into public.ui_copy (key, value) values
  ('delivery.approach_heading',      '"Rider is close"'),
  ('delivery.approach_body',         '"{{rider}} is about {{mins}} minutes away. Keep the QR or OTP ready."'),
  ('delivery.here_heading',          '"Rider is here"'),
  ('delivery.here_body',             '"{{rider}} is at your door. Show the QR code or read out the OTP to complete the handover."'),
  ('delivery.here_waiting_one',      '"Waiting 1 minute"'),
  ('delivery.here_waiting_many',     '"Waiting {{n}} minutes"'),
  ('delivery.here_waiting_now',      '"Just arrived"'),
  ('delivery.handover_qr_label',     '"Handover QR"'),
  ('delivery.handover_otp_label',    '"Handover OTP"'),
  ('delivery.handover_otp_hint',     '"Read this out to the rider"'),
  ('delivery.approach_chip',         '"Arriving"'),
  ('delivery.here_chip',             '"At your door"'),
  ('delivery.missed_handover_title', '"Handover missed"'),
  ('delivery.missed_handover_body',  '"The rider left {{order}} without completing the handover."'),
  ('delivery.cold_heading',          '"Cold chain"'),
  ('delivery.cold_elapsed_one',      '"1 minute out of the cold box"'),
  ('delivery.cold_elapsed_many',     '"{{n}} minutes out of the cold box"'),
  ('delivery.cold_window_label',     '"Allowed {{n}} minutes"'),
  ('delivery.cold_left_one',         '"1 minute left"'),
  ('delivery.cold_left_many',        '"{{n}} minutes left"'),
  ('delivery.cold_breach_label',     '"Cold chain window exceeded"'),
  ('delivery.cold_breach_body',      '"{{order}} has been out of the cold box for {{n}} minutes. The allowed window is {{win}} minutes."'),
  ('delivery.confirm_arrival_label', '"I have arrived"'),
  ('delivery.arrival_confirmed_label','"Arrival confirmed"'),
  ('delivery.nudge_heading',         '"Check your run"'),
  ('delivery.anomaly.off_route',     '"You are off the planned route. Rejoin it or call ops."'),
  ('delivery.anomaly.stationary',    '"You have not moved for a while. Tap SOS if you need help."'),
  ('delivery.anomaly.overspeed',     '"Please slow down — your speed was above the safe limit."'),
  ('delivery.anomaly.gps_silent',    '"We lost your location. Open the app and keep it running."'),
  ('exc.reason.rider_anomaly',       '"Rider anomaly"'),
  ('exc.reason.missed_handover',     '"Handover missed"'),
  ('exc.reason.cold_chain_breach',   '"Cold chain breach"')
on conflict (key) do update set value = excluded.value;

-- Routes. A route row is what makes notify() willing to send at all: the
-- 500 m alert goes to the customer (push preferred, WhatsApp fallback — the
-- #298 design) and the three ops alerts go to the partner.
insert into public.wa_event_routes
  (event_key, label, description, audience, enabled, push_enabled, push_title, push_body, deep_link_kind)
values
  ('delivery_arriving', 'Rider arriving', 'Fired once when the rider crosses the approach ring.',
   'customer', true, true, 'Rider is close', '{{rider}} is about {{mins}} minutes away. Keep the QR or OTP ready.', 'order'),
  ('delivery_missed_handover', 'Handover missed', 'Rider left the door without completing the stop.',
   'partner', true, true, 'Handover missed', 'The rider left {{order}} without completing the handover.', '/partner'),
  ('rider_anomaly', 'Rider anomaly', 'Off-route, stationary, speeding or GPS-silent rider.',
   'partner', true, true, 'Rider needs a look', '{{rider}} · {{kind}}', '/partner'),
  ('delivery_cold_breach', 'Cold chain breach', 'A cold-chain stop passed its allowed window.',
   'partner', true, true, 'Cold chain breach', '{{order}} has been out of the cold box for {{n}} minutes.', '/partner')
on conflict (event_key) do update
  set audience = excluded.audience, enabled = excluded.enabled,
      push_enabled = excluded.push_enabled, push_title = excluded.push_title,
      push_body = excluded.push_body, deep_link_kind = excluded.deep_link_kind,
      label = excluded.label, description = excluded.description;

-- _dcfg gains the new keys, zone override first exactly like every other one.
create or replace function public._dcfg(p_zone smallint default null)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
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
    'customer_scan_requires_arrival', d.customer_scan_requires_arrival,
    'completion_geofence_action',     d.completion_geofence_action,
    'reject_cooldown_min',            d.reject_cooldown_min,
    'reject_cap_per_day',             d.reject_cap_per_day,
    'zone_serviceable',          coalesce(z.is_serviceable, true),
    -- CHANGE #703 — the two rings, the exit radius and the anomaly thresholds.
    'approach_radius_m',         coalesce(z.approach_radius_m,      d.approach_radius_m),
    'arrival_radius_m',          coalesce(z.arrival_radius_m,       d.arrival_radius_m),
    'handover_exit_m',           coalesce(z.handover_exit_m,        d.handover_exit_m),
    'approach_eta_min',          d.approach_eta_min,
    'cold_chain_window_min',     coalesce(z.cold_chain_window_min,  d.cold_chain_window_min),
    'anomaly_enabled',           coalesce(z.anomaly_enabled,        d.anomaly_enabled),
    'anomaly_offroute_m',        coalesce(z.anomaly_offroute_m,     d.anomaly_offroute_m),
    'anomaly_offroute_min',      coalesce(z.anomaly_offroute_min,   d.anomaly_offroute_min),
    'anomaly_stationary_min',    coalesce(z.anomaly_stationary_min, d.anomaly_stationary_min),
    'anomaly_speed_kmh',         coalesce(z.anomaly_speed_kmh,      d.anomaly_speed_kmh),
    'anomaly_gps_silent_min',    coalesce(z.anomaly_gps_silent_min, d.anomaly_gps_silent_min),
    'zone_id',                   p_zone)
  from public.delivery_config d
  left join public.zone_delivery_config z on z.zone_id = p_zone
  where d.id = 1;
$function$;
-- CHANGE #703 part 3 — the geofence evaluator.
--
-- One function owns every ring, so the rider app, the customer tracker and the
-- ops board can never disagree about where a rider is. It is called from
-- delivery_update_location on every fix and is idempotent: crossing the same
-- ring twice fires nothing the second time, because the RING IS A STAMP on the
-- row, not a comparison the caller had to remember to make.

create or replace function public._c703_geofence_eval(
  p_partner uuid, p_lat numeric, p_lng numeric)
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  r record; cfg jsonb;
  v_d numeric; v_approach numeric; v_arrive numeric; v_exit numeric;
  v_mins int; v_name text; v_events jsonb := '[]'::jsonb;
  v_now timestamptz := now();
begin
  select coalesce(nullif(full_name,''), '') into v_name
    from public.delivery_partner_registrations where id = p_partner;

  for r in
    select d.id, d.order_id, d.zone_id, d.lat, d.lng, d.status,
           d.approach_notified_at, d.arrived_at, d.dwell_started_at,
           d.missed_handover_at, o.order_code
      from public.deliveries d
      left join public.orders o on o.id = d.order_id
     where d.partner_id = p_partner
       and d.status = 'out_for_delivery'
       and d.lat is not null and d.lng is not null
  loop
    cfg := public._dcfg(r.zone_id);
    v_approach := coalesce((cfg->>'approach_radius_m')::numeric, 500);
    v_arrive   := coalesce((cfg->>'arrival_radius_m')::numeric, 50);
    v_exit     := coalesce((cfg->>'handover_exit_m')::numeric, 800);
    v_mins     := coalesce((cfg->>'approach_eta_min')::int, 3);

    v_d := public._geo_m(p_lat, p_lng, r.lat, r.lng);

    -- RING 1 (500 m) — tell the buyer, once, and open the handover card.
    if v_d <= v_approach and r.approach_notified_at is null then
      update public.deliveries
         set approach_notified_at = v_now, approach_lat = p_lat, approach_lng = p_lng
       where id = r.id and approach_notified_at is null;

      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
      values (r.id, r.order_id, p_partner, 'approaching',
              'geofence ' || round(v_d)::text || 'm', p_lat, p_lng, 'system');

      -- notify() picks push first and falls back to WhatsApp, so this is ONE
      -- alert on whichever channel the buyer actually has.
      begin
        perform public.notify('delivery_arriving', null,
          jsonb_build_object('order_id', r.order_id, 'rider', v_name,
                             'mins', v_mins,
                             'order', coalesce(nullif(r.order_code,''), '')));
      exception when others then
        perform public._wa_log_attempt('delivery_arriving', r.order_id, null, 'skipped',
                                       false, 'caller_error: ' || sqlerrm);
      end;

      v_events := v_events || jsonb_build_object(
        'delivery_id', r.id, 'ring', 'approach',
        'chip', public._c('delivery.approach_chip'));
    end if;

    -- RING 2 (50 m) — the stop is arrived at and the dwell clock starts.
    if v_d <= v_arrive and r.arrived_at is null then
      update public.deliveries
         set arrived_at = v_now, arrived_lat = p_lat, arrived_lng = p_lng,
             dwell_started_at = coalesce(dwell_started_at, v_now),
             -- an approach that was never separately observed (a rider who
             -- appeared inside 50 m) still counts as notified, so the buyer is
             -- never told "arriving" after the rider is already at the door.
             approach_notified_at = coalesce(approach_notified_at, v_now)
       where id = r.id and arrived_at is null;

      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
      values (r.id, r.order_id, p_partner, 'arrived',
              'geofence ' || round(v_d)::text || 'm', p_lat, p_lng, 'system');

      v_events := v_events || jsonb_build_object(
        'delivery_id', r.id, 'ring', 'arrived',
        'chip', public._c('delivery.arrived_chip'));

    -- RING 3 (exit) — arrived, still not completed, and now far away again.
    elsif r.arrived_at is not null and v_d > v_exit and r.missed_handover_at is null then
      update public.deliveries
         set missed_handover_at   = v_now,
             missed_handover_count = coalesce(missed_handover_count,0) + 1
       where id = r.id and missed_handover_at is null;

      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
      values (r.id, r.order_id, p_partner, 'missed_handover',
              round(v_d)::text || 'm from the door', p_lat, p_lng, 'system');

      begin
        perform public.notify_partner('delivery_missed_handover',
          jsonb_build_object('order_id', r.order_id, 'rider', v_name,
                             'order', coalesce(nullif(r.order_code,''), 'this stop')));
      exception when others then null;
      end;

      v_events := v_events || jsonb_build_object(
        'delivery_id', r.id, 'ring', 'missed_handover',
        'chip', public._c('delivery.missed_handover_title'));
    end if;

    -- Coming BACK inside the door radius after a miss re-opens the handover:
    -- the flag is a state, not a permanent black mark on the rider.
    if r.missed_handover_at is not null and v_d <= v_arrive then
      update public.deliveries
         set missed_handover_at = null,
             dwell_started_at = coalesce(dwell_started_at, v_now)
       where id = r.id;
    end if;
  end loop;

  return v_events;
end $function$;
-- CHANGE #703 part 4 — anomalies.
--
-- Two entry points, because the four rules split cleanly in two: speeding and
-- off-route are visible IN a location fix, while "stationary" and "GPS silent"
-- are visible only in the ABSENCE of one — and an absent fix can never call a
-- function. So the first pair runs inline on every update and the second pair
-- rides the cron dispatcher.
--
-- Opening and clearing are both idempotent. `uq_delivery_anomaly_open` is a
-- partial unique index on (run_id, kind) where cleared_at is null, so the same
-- rule cannot raise twice for one run — the ops inbox shows an anomaly, never a
-- stream of them.

-- Distance from a point to the run's planned polyline, in metres. Segment
-- distance, not vertex distance: a highway leg can be two vertices a kilometre
-- apart, and a rider dead-centre on it is 0 m off route, not 500 m.
create or replace function public._c703_route_offset_m(
  p_polyline text, p_lat numeric, p_lng numeric)
returns numeric
language plpgsql immutable as $function$
declare
  v_best double precision := null;
  v_lat0 double precision := p_lat::double precision;
  v_mx double precision := cos(radians(p_lat::double precision)) * 111320.0;
  v_my double precision := 110540.0;
  px double precision; py double precision;
  a_x double precision; a_y double precision; b_x double precision; b_y double precision;
  dx double precision; dy double precision; t double precision; d double precision;
  prev record; cur record; v_n int := 0;
begin
  if coalesce(p_polyline,'') = '' then return null; end if;
  px := p_lng::double precision * v_mx; py := v_lat0 * v_my;

  prev := null;
  for cur in select * from public._c701_poly_decode(p_polyline) order by ord loop
    v_n := v_n + 1;
    if prev is not null then
      a_x := prev.lng * v_mx; a_y := prev.lat * v_my;
      b_x := cur.lng  * v_mx; b_y := cur.lat  * v_my;
      dx := b_x - a_x; dy := b_y - a_y;
      if dx = 0 and dy = 0 then
        d := sqrt((px-a_x)^2 + (py-a_y)^2);
      else
        t := ((px-a_x)*dx + (py-a_y)*dy) / (dx*dx + dy*dy);
        t := greatest(0.0, least(1.0, t));
        d := sqrt((px - (a_x + t*dx))^2 + (py - (a_y + t*dy))^2);
      end if;
      if v_best is null or d < v_best then v_best := d; end if;
    end if;
    prev := cur;
  end loop;

  -- A one-point polyline has no segment; fall back to that single vertex.
  if v_best is null and v_n = 1 then
    for cur in select * from public._c701_poly_decode(p_polyline) limit 1 loop
      v_best := sqrt((px - cur.lng*v_mx)^2 + (py - cur.lat*v_my)^2);
    end loop;
  end if;

  return case when v_best is null then null else round(v_best::numeric, 1) end;
end $function$;

-- Raise one anomaly, or leave the open one exactly as it is.
create or replace function public._c703_anomaly_open(
  p_run uuid, p_partner uuid, p_delivery uuid, p_zone smallint,
  p_kind text, p_detail jsonb)
returns bigint
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_id bigint; k record; v_name text; v_order uuid; v_rebased boolean := false;
begin
  select * into k from public.delivery_anomaly_kind where kind = p_kind and enabled;
  if not found then return null; end if;

  insert into public.delivery_anomaly (run_id, partner_id, delivery_id, zone_id, kind, detail)
  values (p_run, p_partner, p_delivery, p_zone, p_kind, coalesce(p_detail,'{}'::jsonb))
  on conflict (run_id, kind) where cleared_at is null do nothing
  returning id into v_id;

  if v_id is null then return null; end if;  -- already open: say nothing twice.

  select coalesce(nullif(full_name,''),'') into v_name
    from public.delivery_partner_registrations where id = p_partner;
  select order_id into v_order from public.deliveries where id = p_delivery;

  -- Ops gets it on the surface they already watch (the exceptions console reads
  -- delivery_anomaly through _exception_rows), and the partner gets a message.
  begin
    perform public.notify_partner('rider_anomaly',
      jsonb_build_object('rider', v_name, 'kind', k.label,
                         'order_id', v_order, 'run_id', p_run));
    update public.delivery_anomaly set notified_at = now() where id = v_id;
  exception when others then null;
  end;

  -- The customer's arrival window is now wrong: rebase it from the truth.
  if k.rebases_eta and p_run is not null then
    begin
      perform public.delivery_recompute_eta(p_run, true);
      v_rebased := true;
    exception when others then null;
    end;
    if v_rebased then
      update public.delivery_anomaly set rebased_at = now() where id = v_id;
    end if;
  end if;

  if k.nudges_rider then
    update public.delivery_anomaly set nudged_at = now() where id = v_id;
  end if;

  return v_id;
end $function$;

create or replace function public._c703_anomaly_clear(p_run uuid, p_kind text)
returns integer
language sql security definer set search_path to 'public' as $function$
  with u as (
    update public.delivery_anomaly set cleared_at = now()
     where run_id = p_run and kind = p_kind and cleared_at is null
     returning 1)
  select count(*)::int from u;
$function$;

-- Inline: everything a single fix can prove.
create or replace function public._c703_anomaly_on_fix(
  p_partner uuid, p_run uuid, p_lat numeric, p_lng numeric, p_speed numeric)
returns void
language plpgsql security definer set search_path to 'public' as $function$
declare
  cfg jsonb; v_zone smallint; v_poly text; v_off numeric; v_limit numeric;
  v_off_lim numeric; v_off_min int; v_since timestamptz; v_stop uuid;
begin
  if p_run is null then return; end if;

  select zone_id, road_polyline into v_zone, v_poly
    from public.delivery_runs where id = p_run;
  cfg := public._dcfg(v_zone);
  if not coalesce((cfg->>'anomaly_enabled')::boolean, true) then return; end if;

  select id into v_stop from public.deliveries
   where run_id = p_run and status = 'out_for_delivery'
   order by coalesce(seq, 999999) limit 1;

  -- A fix at all means the rider is neither silent nor parked.
  perform public._c703_anomaly_clear(p_run, 'gps_silent');
  perform public._c703_anomaly_clear(p_run, 'stationary');

  -- Speeding: instantaneous and self-evident, so it opens on the fix itself.
  v_limit := coalesce((cfg->>'anomaly_speed_kmh')::numeric, 80);
  if p_speed is not null and p_speed > v_limit then
    perform public._c703_anomaly_open(p_run, p_partner, v_stop, v_zone, 'overspeed',
      jsonb_build_object('speed_kmh', p_speed, 'limit_kmh', v_limit));
  else
    perform public._c703_anomaly_clear(p_run, 'overspeed');
  end if;

  -- Off route: it must PERSIST past the configured minutes before it is real,
  -- so one bad fix or a legitimate detour around a closed road raises nothing.
  v_off_lim := coalesce((cfg->>'anomaly_offroute_m')::numeric, 400);
  v_off_min := coalesce((cfg->>'anomaly_offroute_min')::int, 3);
  v_off := public._c703_route_offset_m(v_poly, p_lat, p_lng);

  if v_off is not null and v_off > v_off_lim then
    select min(ts) into v_since
      from public.delivery_run_trail
     where run_id = p_run
       and ts >= now() - make_interval(mins => v_off_min * 3)
       and public._c703_route_offset_m(v_poly, lat, lng) > v_off_lim;

    if v_since is not null and v_since <= now() - make_interval(mins => v_off_min) then
      perform public._c703_anomaly_open(p_run, p_partner, v_stop, v_zone, 'off_route',
        jsonb_build_object('offset_m', v_off, 'limit_m', v_off_lim,
                           'since', v_since, 'minutes', v_off_min));
    end if;
  else
    perform public._c703_anomaly_clear(p_run, 'off_route');
  end if;
end $function$;
-- CHANGE #703 part 5 — the tick, and the cold chain.
--
-- "Stationary" and "GPS silent" are the two rules that can only be seen from
-- outside a location update, because their evidence is that no update arrived.
-- Cold chain is the same shape: nothing happens at the moment a window is
-- exceeded, so something has to look.

create or replace function public.delivery_anomaly_tick()
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  r record; cfg jsonb; v_silent int; v_still int;
  v_last timestamptz; v_moved_at timestamptz; v_stop uuid;
  v_opened int := 0; v_cleared int := 0; v_checked int := 0;
begin
  for r in
    select run.id as run_id, run.partner_id, run.zone_id
      from public.delivery_runs run
     where run.status = 'started'
       and exists (select 1 from public.deliveries d
                    where d.run_id = run.id and d.status = 'out_for_delivery')
  loop
    v_checked := v_checked + 1;
    cfg := public._dcfg(r.zone_id);
    if not coalesce((cfg->>'anomaly_enabled')::boolean, true) then continue; end if;

    v_silent := coalesce((cfg->>'anomaly_gps_silent_min')::int, 5);
    v_still  := coalesce((cfg->>'anomaly_stationary_min')::int, 10);

    select id into v_stop from public.deliveries
     where run_id = r.run_id and status = 'out_for_delivery'
     order by coalesce(seq, 999999) limit 1;

    select updated_at into v_last
      from public.delivery_partner_locations where partner_id = r.partner_id;

    -- GPS silent: no fix at all for longer than the zone allows.
    if v_last is null or v_last < now() - make_interval(mins => v_silent) then
      if public._c703_anomaly_open(r.run_id, r.partner_id, v_stop, r.zone_id, 'gps_silent',
           jsonb_build_object('last_fix_at', v_last, 'minutes', v_silent)) is not null then
        v_opened := v_opened + 1;
      end if;
      continue;  -- a silent rider cannot also be proven stationary.
    end if;

    -- Stationary: fixes ARE arriving, and every one of them says the same
    -- place. The trail's own moved_m is the evidence — no distance is
    -- recomputed here.
    select max(ts) into v_moved_at
      from public.delivery_run_trail
     where run_id = r.run_id
       and coalesce(moved_m, 0) >= coalesce((select location_min_move_m from public.delivery_config where id=1), 25);

    if v_moved_at is not null and v_moved_at < now() - make_interval(mins => v_still) then
      if public._c703_anomaly_open(r.run_id, r.partner_id, v_stop, r.zone_id, 'stationary',
           jsonb_build_object('since', v_moved_at, 'minutes', v_still)) is not null then
        v_opened := v_opened + 1;
      end if;
    else
      v_cleared := v_cleared + public._c703_anomaly_clear(r.run_id, 'stationary');
    end if;
  end loop;

  -- A finished run holds nothing open.
  update public.delivery_anomaly a set cleared_at = now()
   where a.cleared_at is null
     and not exists (select 1 from public.delivery_runs run
                      where run.id = a.run_id and run.status = 'started');

  return jsonb_build_object('ok', true, 'runs', v_checked,
                            'opened', v_opened, 'cleared', v_cleared);
end $function$;

-- ── Cold chain ─────────────────────────────────────────────────────────────
-- Elapsed since the box left the warehouse, against the window the zone allows.
-- Both numbers and every word are decided here; the rider run and the customer
-- card print what comes back.
create or replace function public._c703_cold_block(p_delivery_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $function$
declare
  d public.deliveries%rowtype; r public.delivery_runs%rowtype;
  v_from timestamptz; v_win int; v_elapsed int; v_left int; v_breach boolean;
  o record;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null or not coalesce(d.is_cold_chain,false) then
    return jsonb_build_object('has', false, 'is_cold_chain', false);
  end if;

  select * into r from public.delivery_runs where id = d.run_id;
  v_from := coalesce(d.started_at, r.started_at);
  v_win  := coalesce((public._dcfg(d.zone_id)->>'cold_chain_window_min')::int, 120);

  if v_from is null then
    -- Cold chain, but not dispatched yet: say what it IS, not a clock.
    return public._cold_chain_block(true) || jsonb_build_object(
      'has', true, 'started', false,
      'heading', public._c('delivery.cold_heading'),
      'elapsed_label', '', 'window_label',
        public._cf('delivery.cold_window_label', jsonb_build_object('n', v_win)),
      'left_label', '', 'breach', false,
      'breach_label', '', 'elapsed_min', 0, 'window_min', v_win);
  end if;

  v_elapsed := floor(extract(epoch from (now() - v_from)) / 60.0)::int;
  v_left    := v_win - v_elapsed;
  v_breach  := (v_left < 0) or (d.cold_breach_at is not null);

  return public._cold_chain_block(true) || jsonb_build_object(
    'has', true, 'started', true,
    'heading', public._c('delivery.cold_heading'),
    'elapsed_min', greatest(v_elapsed, 0),
    'window_min',  v_win,
    'elapsed_label', case when v_elapsed = 1
        then public._c('delivery.cold_elapsed_one')
        else public._cf('delivery.cold_elapsed_many', jsonb_build_object('n', greatest(v_elapsed,0))) end,
    'window_label', public._cf('delivery.cold_window_label', jsonb_build_object('n', v_win)),
    'left_label', case when v_breach then ''
        when v_left = 1 then public._c('delivery.cold_left_one')
        else public._cf('delivery.cold_left_many', jsonb_build_object('n', greatest(v_left,0))) end,
    'breach', v_breach,
    'breach_at', d.cold_breach_at,
    'breach_label', case when v_breach then public._c('delivery.cold_breach_label') else '' end,
    'tone', case when v_breach then 'danger' when v_left <= 15 then 'warning' else 'info' end);
end $function$;

create or replace function public.delivery_cold_chain_tick()
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare r record; v_win int; v_elapsed int; v_flagged int := 0;
begin
  for r in
    select d.id, d.order_id, d.zone_id, d.partner_id,
           coalesce(d.started_at, run.started_at) as from_at,
           o.order_code
      from public.deliveries d
      left join public.delivery_runs run on run.id = d.run_id
      left join public.orders o on o.id = d.order_id
     where coalesce(d.is_cold_chain,false)
       and d.status = 'out_for_delivery'
       and d.cold_breach_at is null
       and coalesce(d.started_at, run.started_at) is not null
  loop
    v_win := coalesce((public._dcfg(r.zone_id)->>'cold_chain_window_min')::int, 120);
    v_elapsed := floor(extract(epoch from (now() - r.from_at)) / 60.0)::int;
    if v_elapsed > v_win then
      update public.deliveries set cold_breach_at = now()
       where id = r.id and cold_breach_at is null;

      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
      values (r.id, r.order_id, r.partner_id, 'cold_breach',
              v_elapsed::text || 'm of ' || v_win::text || 'm', 'system');

      begin
        perform public.notify_partner('delivery_cold_breach',
          jsonb_build_object('order_id', r.order_id, 'n', v_elapsed, 'win', v_win,
                             'order', coalesce(nullif(r.order_code,''), 'a cold-chain stop')));
      exception when others then null;
      end;
      v_flagged := v_flagged + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'flagged', v_flagged);
end $function$;

-- One dispatcher, one row each. Never a bare */N cron entry.
insert into public.cron_task (name, ord, mode, work_sql, base_interval_s, enabled, note, dml)
values
  ('delivery_anomaly',   946, 'poll', 'select public.delivery_anomaly_tick()',    120, true,
   'CHANGE #703 — stationary and GPS-silent riders; the two rules an absent fix proves.', true),
  ('delivery_cold_chain',947, 'poll', 'select public.delivery_cold_chain_tick()', 300, true,
   'CHANGE #703 — cold-chain stops past their allowed window.', true)
on conflict (name) do update
  set work_sql = excluded.work_sql, base_interval_s = excluded.base_interval_s,
      enabled = excluded.enabled, note = excluded.note, dml = excluded.dml;
CREATE OR REPLACE FUNCTION public.delivery_update_location(p_lat numeric, p_lng numeric, p_heading numeric DEFAULT NULL::numeric, p_accuracy numeric DEFAULT NULL::numeric, p_snap_lat numeric DEFAULT NULL::numeric, p_snap_lng numeric DEFAULT NULL::numeric, p_snap_dist_m numeric DEFAULT NULL::numeric, p_battery integer DEFAULT NULL::integer, p_source text DEFAULT 'app'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_partner uuid; cfg jsonb; v_min_acc numeric;
  r record; v_arrived jsonb := '[]'::jsonb;
  v_prev record; v_moved numeric; v_min_move numeric; v_run uuid;
  v_snapped boolean; v_map_lat numeric; v_map_lng numeric;
  v_dt numeric; v_speed numeric; v_last_trail timestamptz;
  v_animate int; v_live jsonb; v_now timestamptz := now();
begin
  select id into v_partner from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null then return jsonb_build_object('ok',false,'error','not_a_partner'); end if;

  -- gap #116: the breadcrumb, written BEFORE the hot row is overwritten so the
  -- distance is measured against the fix it actually replaces.
  select lat, lng, updated_at into v_prev
    from public.delivery_partner_locations where partner_id = v_partner;
  v_moved := case when v_prev.lat is null then null
                  else public._geo_m(v_prev.lat, v_prev.lng, p_lat, p_lng) end;
  select coalesce(location_min_move_m, 25), coalesce(live_animate_ms, 1200)
    into v_min_move, v_animate from public.delivery_config where id = 1;
  select id into v_run from public.delivery_runs
   where partner_id = v_partner and status = 'started'
   order by created_at desc limit 1;

  -- Speed is derived here, once, so no map ever computes it.
  v_dt := case when v_prev.updated_at is null then null
               else extract(epoch from (v_now - v_prev.updated_at)) end;
  v_speed := case when v_dt is null or v_dt <= 0 or v_moved is null then null
                  else round((v_moved / v_dt) * 3.6, 1) end;

  v_snapped := (p_snap_lat is not null and p_snap_lng is not null);
  v_map_lat := case when v_snapped then p_snap_lat else p_lat end;
  v_map_lng := case when v_snapped then p_snap_lng else p_lng end;

  if v_moved is null or v_moved >= coalesce(v_min_move, 25) then
    insert into public.delivery_partner_location_history(partner_id, run_id, ts, lat, lng, heading, accuracy, moved_m)
    values (v_partner, v_run, v_now, p_lat, p_lng, p_heading, p_accuracy, v_moved);
  end if;

  -- The run trail: every meaningful move, plus a heartbeat row once a minute
  -- while stationary. A dispute needs to be able to prove the rider was PARKED
  -- outside the shop, which a move-only trail can never show.
  if v_run is not null then
    select max(ts) into v_last_trail from public.delivery_run_trail where run_id = v_run;
    if v_moved is null or v_moved >= coalesce(v_min_move, 25)
       or v_last_trail is null or v_last_trail < v_now - interval '60 seconds' then
      insert into public.delivery_run_trail(
        run_id, partner_id, ts, lat, lng, snap_lat, snap_lng, snapped,
        heading, accuracy, moved_m, speed_kmh, battery, source)
      values (v_run, v_partner, v_now, p_lat, p_lng,
              p_snap_lat, p_snap_lng, v_snapped,
              p_heading, p_accuracy, v_moved, v_speed, p_battery,
              coalesce(nullif(p_source,''), 'app'));
    end if;
  end if;

  insert into public.delivery_partner_locations(partner_id, lat, lng, heading, accuracy, updated_at)
  values (v_partner, p_lat, p_lng, p_heading, p_accuracy, v_now)
  on conflict (partner_id) do update
    set lat=excluded.lat, lng=excluded.lng, heading=excluded.heading,
        accuracy=excluded.accuracy, updated_at=v_now;

  -- BROADCAST, not postgres_changes. delivery_partner_locations is not in the
  -- supabase_realtime publication and must not be added to it — the publication
  -- holds 8 tables and that is the budget. A run-scoped broadcast also means a
  -- customer's socket carries only the rider bringing THEIR order, instead of
  -- every rider's position in the fleet.
  if v_run is not null then
    v_live := public._delivery_live_block(v_now);
    begin
      perform realtime.send(
        jsonb_build_object(
          'run_id',     v_run,
          'ts',         v_now,
          'lat',        p_lat,        'lng',        p_lng,
          'snap_lat',   p_snap_lat,   'snap_lng',   p_snap_lng,
          'snapped',    v_snapped,
          'snap_dist_m', p_snap_dist_m,
          'map_lat',    v_map_lat,    'map_lng',    v_map_lng,
          'heading',    p_heading,    'accuracy',   p_accuracy,
          'speed_kmh',  v_speed,      'battery',    p_battery,
          'moved_m',    v_moved,
          'animate_ms', coalesce(v_animate, 1200),
          'source',     coalesce(nullif(p_source,''), 'app'),
          'note',       case when v_snapped then '' else public._c('delivery.live_raw_note') end,
          'live',       v_live),
        'rider', 'run:' || v_run::text, true);
    exception when others then
      -- A realtime hiccup must never cost the rider their position write.
      null;
    end;
  end if;

  -- CHANGE #703 — the fix is now judged twice: once for the run (speeding and
  -- off-route are visible in this single fix) and once for every live stop
  -- (the 500 m, 50 m and exit rings). Both are idempotent, so a rider whose
  -- app posts the same position ten times fires exactly one alert.
  begin
    perform public._c703_anomaly_on_fix(v_partner, v_run, p_lat, p_lng, v_speed);
  exception when others then
    null;  -- an anomaly rule must never cost the rider their position write.
  end;

  cfg := public._dcfg(null);
  v_min_acc := coalesce((cfg->>'geofence_min_accuracy_m')::numeric, 250);

  if p_accuracy is not null and p_accuracy > v_min_acc then
    return jsonb_build_object('ok',true,'arrived',v_arrived,'skipped_accuracy',true,
                              'run_id',v_run,'snapped',v_snapped);
  end if;

  -- One evaluator owns every ring. `arrived` stays the key the rider app has
  -- always read; it now also carries the approach and the missed handover, each
  -- with the ring that produced it.
  v_arrived := public._c703_geofence_eval(v_partner, p_lat, p_lng);

  return jsonb_build_object('ok',true,'arrived',v_arrived,
                            'run_id',v_run,'snapped',v_snapped,
                            'channel', case when v_run is not null
                                            then 'run:' || v_run::text end);
end $function$
;
CREATE OR REPLACE FUNCTION public._exception_rows()
 RETURNS TABLE(reason_code text, ref_id text, zone_id smallint, title text, subtitle text, since timestamp with time zone, supplier_key text, action_ref text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- 1. Disputes nobody resolved.
  select 'dispute_open'::text, d.id::text, oi.zone_id,
         coalesce(nullif(d.product_name,''), '—'),
         coalesce(nullif(d.assigned_supplier,''), '—'),
         d.created_at,
         nullif(d.assigned_supplier,''),
         d.id::text
    from public.supplier_disputes d
    left join public.order_items oi on oi.id = d.order_item_id
   where d.resolved_at is null

  union all
  -- 2. Items no supplier could fill.
  select 'item_unfulfillable', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.unfulfillable_reason,''), '—'),
         coalesce(oi.unfulfillable_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.order_id::text
    from public.order_items oi
   where oi.unfulfillable is true

  union all
  -- 3. Shop count and warehouse recount disagree.
  select 'count_variance', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.assigned_supplier,''), '—'),
         coalesce(oi.received_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.id::text
    from public.order_items oi
   where oi.count_diff is not null
     and oi.count_diff <> 0
     and coalesce(oi.unfulfillable, false) = false

  union all
  -- CHANGE #702. The predicted promise breach, on the surface the partner
  -- already reads. It is a PREDICTION, so it appears the moment the model
  -- says the stop will be late — not after the promise has already passed.
  select 'eta_promise_breach', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         coalesce(d.eta_breach_at, d.promised_at),
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.status in ('assigned','out_for_delivery')
     and d.promised_at is not null
     and d.eta_at is not null
     and d.eta_at > d.promised_at

  union all
  -- 4. WhatsApp sends the provider is refusing — the same blocking-fault
  --    filter the ops board already uses, so the two surfaces cannot disagree.
  select 'wa_send_failed', a.id::text,
         (select o.zone_id from public.orders o where o.id = a.order_id),
         coalesce(nullif(a.reason,''), '—'),
         coalesce(nullif(a.event_key,''), '—'),
         a.created_at,
         null,
         a.id::text
    from public.wa_send_attempts a
   where a.ok = false
     and a.created_at >= now() - interval '7 days'
     and coalesce(a.phone,'') not like '9000000%'
     and exists (select 1 from public.wa_send_fault_rule f
                  where f.enabled and f.is_blocking
                    and ((f.match_kind = 'exact' and a.reason = f.match_text)
                      or (f.match_kind = 'ilike' and a.reason ilike f.match_text)))

  union all
  -- 5. Stock follow-ups past their due date and still unanswered.
  select 'stock_followup_overdue', q.id::text, q.zone_id,
         coalesce(nullif(m.product_name,''), 'Product ' || q.product_id::text),
         coalesce(nullif(q.supplier_name,''), '—'),
         q.due_at,
         nullif(q.supplier_name,''),
         q.id::text
    from public.stock_update_queue q
    left join public."MEDICINE" m on m.id = q.product_id
   where q.resolved_at is null
     and q.due_at < now()

  union all
  -- 6. Payment claims nobody verified, once they are past the reason's SLA.
  select 'payment_claim_stuck', pc.id::text, pc.zone_id,
         coalesce(nullif(pc.utr,''), 'Claim ' || left(pc.id::text, 8)),
         coalesce(nullif(pc.payee_name,''), nullif(pc.sender_phone,''), '—'),
         coalesce(pc.paid_ts, pc.received_at, pc.created_at),
         null,
         pc.id::text
    from public.payment_claims pc
   where coalesce(pc.status,'') not in ('verified','rejected')
     and coalesce(pc.paid_ts, pc.received_at, pc.created_at)
         < now() - make_interval(hours =>
             (select r.sla_hours::int from public.exception_reason r
               where r.reason_code = 'payment_claim_stuck'))

  union all
  -- CHANGE #703. A rider anomaly is an ops item, so it belongs on the surface
  -- ops already reads. The row is the OPEN anomaly itself — it disappears from
  -- the console the moment the rule clears, without anyone closing it by hand.
  select 'rider_anomaly', a.id::text, a.zone_id,
         coalesce(nullif(r.full_name,''), 'Rider ' || left(coalesce(a.partner_id::text,'-'),8)),
         coalesce(nullif(k.label,''), a.kind),
         a.opened_at,
         null,
         coalesce(a.delivery_id::text, a.run_id::text)
    from public.delivery_anomaly a
    left join public.delivery_anomaly_kind k on k.kind = a.kind
    left join public.delivery_partner_registrations r on r.id = a.partner_id
   where a.cleared_at is null

  union all
  -- CHANGE #703. The rider reached the door and left again without completing.
  select 'missed_handover', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         d.missed_handover_at,
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.missed_handover_at is not null
     and d.status = 'out_for_delivery'

  union all
  -- CHANGE #703. A cold-chain stop past its allowed window, until it completes.
  select 'cold_chain_breach', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(r.full_name,''), '—'),
         d.cold_breach_at,
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations r on r.id = d.partner_id
   where d.cold_breach_at is not null
     and d.status in ('assigned','out_for_delivery')

  union all
  -- 7. Everything else on the ops board that is past its OWN class deadline.
  select 'sla_breach', b.class_key || '/' || b.item_id, b.zone_id,
         b.item_label,
         c.title || ' · ' || b.item_sub,
         b.since,
         null,
         b.class_key
    from (
      select 'orders_open'::text class_key, o.id::text item_id, o.zone_id,
             coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)) item_label,
             coalesce(nullif(o.pharmacy_name,''), '—') item_sub, o.created_at since
        from public.orders o where o.closed_at is null
      union all
      select 'supplier_unsettled', so.id::text, so.zone_id,
             coalesce(nullif(so.order_code,''), 'SO ' || left(so.id::text,8)),
             coalesce(nullif(so.supplier_name,''), '—'), so.created_at
        from public.supplier_orders so where so.settled_at is null
      union all
      select 'inquiry_pending', i.id::text, i.zone_id,
             coalesce(nullif(i.product_name,''), 'Inquiry ' || i.id::text),
             coalesce(nullif(i.current_status,''), '—'),
             coalesce(i.asked_at, i.created_at)
        from public.inquiry i where i.current_status = 'Confirmation Pending'
      union all
      select 'bills_pending', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Bill ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.status = 'pending'
      union all
      select 'bill_scan_error', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Scan ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.scan_status = 'error'
      union all
      select 'catalog_barcode_gap', bm.barcode_norm, null::smallint,
             coalesce(nullif(bm.sample_raw,''), bm.barcode_norm),
             bm.miss_count || case when bm.miss_count = 1 then ' scan' else ' scans' end
               || ', no product',
             bm.first_seen
        from public.catalog_barcode_miss bm
       where not exists (
               select 1 from public."MEDICINE" m
                where m.barcode is not null and btrim(m.barcode) <> ''
                  and public._norm_barcode(m.barcode) = bm.barcode_norm)
         and not exists (
               select 1 from public.product_barcode pb2
                where public._norm_barcode(pb2.barcode) = bm.barcode_norm)
    ) b
    join public.ops_board_class c
      on c.key = b.class_key and c.enabled
   where b.since < now() - make_interval(hours => c.sla_hours::int)
$function$

;
-- CHANGE #703 part 6 — the customer's doorbell.
--
-- One block that says which of the three arrival states a stop is in, and
-- carries everything the card draws: the rider's face and name, the call
-- button, the handover QR and OTP, and how long they have been waiting. The
-- widget makes NO decision — not even "should the QR show", which used to be a
-- boolean the tracker recomputed for itself.

create or replace function public._c703_arrival_block(p_delivery_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $function$
declare
  d public.deliveries%rowtype; v_name text; v_wait int; v_state text;
  v_show boolean; v_otp text;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('has', false, 'state','none'); end if;

  -- Completion clears the doorbell, whatever the geofence last thought.
  if d.status not in ('assigned','out_for_delivery') then
    return jsonb_build_object('has', false, 'state', 'done');
  end if;

  v_state := case
    when d.arrived_at is not null            then 'here'
    when d.approach_notified_at is not null  then 'approaching'
    else 'enroute' end;

  if v_state = 'enroute' then
    return jsonb_build_object('has', false, 'state', 'enroute');
  end if;

  select coalesce(nullif(full_name,''),'') into v_name
    from public.delivery_partner_registrations where id = d.partner_id;

  -- The handover credentials open at the approach ring, which is the whole
  -- point of the ring: the buyer has three minutes to find the phone, not
  -- three seconds while the rider stands there.
  v_show := true;
  v_otp  := case when coalesce(d.otp_verified_at, null) is null then nullif(d.otp_code,'') end;

  v_wait := case when d.dwell_started_at is null then null
                 else floor(extract(epoch from (now() - d.dwell_started_at)) / 60.0)::int end;

  return jsonb_build_object(
    'has', true,
    'state', v_state,
    'chip', case when v_state = 'here' then public._c('delivery.here_chip')
                 else public._c('delivery.approach_chip') end,
    'heading', case when v_state = 'here' then public._c('delivery.here_heading')
                    else public._c('delivery.approach_heading') end,
    'body', case when v_state = 'here'
        then public._cf('delivery.here_body', jsonb_build_object('rider', v_name))
        else public._cf('delivery.approach_body',
               jsonb_build_object('rider', v_name,
                 'mins', coalesce((public._dcfg(d.zone_id)->>'approach_eta_min')::int, 3))) end,
    'partner_name', v_name,
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    'call_action', public._call_action_block('customer','delivery', d.order_id),
    'waiting_label', case
        when v_state <> 'here' or v_wait is null then ''
        when v_wait <= 0 then public._c('delivery.here_waiting_now')
        when v_wait = 1  then public._c('delivery.here_waiting_one')
        else public._cf('delivery.here_waiting_many', jsonb_build_object('n', v_wait)) end,
    'waiting_min', coalesce(v_wait, 0),
    'handover', jsonb_build_object(
      'has',       v_show,
      'qr_label',  public._c('delivery.handover_qr_label'),
      'qr_token',  case when v_show then nullif(d.qr_token,'') end,
      'otp_label', public._c('delivery.handover_otp_label'),
      'otp_hint',  public._c('delivery.handover_otp_hint'),
      'otp',       case when v_show then v_otp end),
    'tone', case when v_state = 'here' then 'success' else 'info' end,
    'arrived_at', d.arrived_at,
    'dwell_started_at', d.dwell_started_at);
end $function$;

-- The rider's own side of the same stop: the nudge an open anomaly earns, and
-- the confirmation the spec asks the rider to give after an auto-stamp.
create or replace function public._c703_rider_nudge_block(p_run uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $function$
declare v_items jsonb := '[]'::jsonb; r record;
begin
  if p_run is null then return jsonb_build_object('has', false, 'items', v_items); end if;
  for r in
    select a.kind, coalesce(nullif(k.label,''), a.kind) as label, a.opened_at, k.sort_rank
      from public.delivery_anomaly a
      left join public.delivery_anomaly_kind k on k.kind = a.kind
     where a.run_id = p_run and a.cleared_at is null and a.nudged_at is not null
     order by coalesce(k.sort_rank, 50), a.opened_at
  loop
    v_items := v_items || jsonb_build_object(
      'kind', r.kind, 'label', r.label,
      'body', public._c('delivery.anomaly.' || r.kind),
      'since', r.opened_at, 'tone', 'warning');
  end loop;
  return jsonb_build_object(
    'has', jsonb_array_length(v_items) > 0,
    'heading', public._c('delivery.nudge_heading'),
    'items', v_items);
end $function$;

-- The rider confirming the arrival the geofence stamped for them. It is a
-- confirmation, not a second arrival: it never moves arrived_at.
create or replace function public.delivery_confirm_arrival(p_delivery_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare v_partner uuid; d public.deliveries%rowtype;
begin
  select id into v_partner from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null then
    return jsonb_build_object('ok',false,'error','not_a_partner');
  end if;

  select * into d from public.deliveries where id = p_delivery_id and partner_id = v_partner;
  if d.id is null then
    return jsonb_build_object('ok',false,'error','not_found');
  end if;

  update public.deliveries
     set arrival_confirmed_at = coalesce(arrival_confirmed_at, now()),
         arrived_at           = coalesce(arrived_at, now()),
         dwell_started_at     = coalesce(dwell_started_at, now())
   where id = p_delivery_id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
  values (p_delivery_id, d.order_id, v_partner, 'arrival_confirmed', 'rider', 'partner');

  return jsonb_build_object('ok', true,
    'label', public._c('delivery.arrival_confirmed_label'));
end $function$;

grant execute on function public.delivery_confirm_arrival(uuid) to authenticated;
-- The 1-arg form below is REPLACED by a 2-arg one, and `create or replace`
-- cannot do that: it would leave both live and rg_check flags a critical
-- overload (two functions one call could resolve to). Drop it first.
drop function if exists public._c703_arrival_block(uuid);

-- CHANGE #703 — the doorbell must not hand the rider the customer's OTP.
--
-- CHANGE #354 CHECK-constrained deliveries.otp_code to stay NULL for exactly
-- one reason: the assigned rider can read the whole deliveries row. The real
-- code lives in delivery_otp. customer_track_order admits the rider as well as
-- the buyer, so the block only carries the OTP when the CALLER is the buyer
-- (or an admin) — the rider gets the same card with the OTP absent, and
-- absence is `has:false`, not an empty string the widget had to test.

create or replace function public._c703_arrival_block(
  p_delivery_id uuid, p_show_otp boolean default false)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $function$
declare
  d public.deliveries%rowtype; v_name text; v_wait int; v_state text; v_otp text;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('has', false, 'state','none'); end if;

  if d.status not in ('assigned','out_for_delivery') then
    return jsonb_build_object('has', false, 'state', 'done');
  end if;

  v_state := case
    when d.arrived_at is not null            then 'here'
    when d.approach_notified_at is not null  then 'approaching'
    else 'enroute' end;

  if v_state = 'enroute' then
    return jsonb_build_object('has', false, 'state', 'enroute');
  end if;

  select coalesce(nullif(full_name,''),'') into v_name
    from public.delivery_partner_registrations where id = d.partner_id;

  if coalesce(p_show_otp,false) then
    select nullif(o.code,'') into v_otp from public.delivery_otp o
     where o.delivery_id = d.id and o.verified_at is null;
  end if;

  v_wait := case when d.dwell_started_at is null then null
                 else floor(extract(epoch from (now() - d.dwell_started_at)) / 60.0)::int end;

  return jsonb_build_object(
    'has', true,
    'state', v_state,
    'chip', case when v_state = 'here' then public._c('delivery.here_chip')
                 else public._c('delivery.approach_chip') end,
    'heading', case when v_state = 'here' then public._c('delivery.here_heading')
                    else public._c('delivery.approach_heading') end,
    'body', case when v_state = 'here'
        then public._cf('delivery.here_body', jsonb_build_object('rider', v_name))
        else public._cf('delivery.approach_body',
               jsonb_build_object('rider', v_name,
                 'mins', coalesce((public._dcfg(d.zone_id)->>'approach_eta_min')::int, 3))) end,
    'partner_name', v_name,
    'rider_photo', public._rider_photo_block(d.partner_id, d.status),
    'call_action', public._call_action_block('customer','delivery', d.order_id),
    'waiting_label', case
        when v_state <> 'here' or v_wait is null then ''
        when v_wait <= 0 then public._c('delivery.here_waiting_now')
        when v_wait = 1  then public._c('delivery.here_waiting_one')
        else public._cf('delivery.here_waiting_many', jsonb_build_object('n', v_wait)) end,
    'waiting_min', coalesce(v_wait, 0),
    -- The handover credentials open at the APPROACH ring, which is the whole
    -- point of the ring: the buyer gets three minutes to find their phone.
    'handover', jsonb_build_object(
      'has',       true,
      'qr_label',  public._c('delivery.handover_qr_label'),
      'qr_token',  nullif(d.qr_token,''),
      'has_otp',   (v_otp is not null),
      'otp_label', public._c('delivery.handover_otp_label'),
      'otp_hint',  public._c('delivery.handover_otp_hint'),
      'otp',       v_otp),
    'tone', case when v_state = 'here' then 'success' else 'info' end,
    'arrived_at', d.arrived_at,
    'dwell_started_at', d.dwell_started_at);
end $function$;
CREATE OR REPLACE FUNCTION public.customer_track_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
        v_last record; v_snapped boolean; v_animate int; v_live jsonb;
        v_eta jsonb; v_proof jsonb; v_arrival jsonb; v_cold jsonb;
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
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
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
  -- CHANGE #703: the doorbell and the cold box. Both are whole payloads —
  -- the tracker prints them and decides nothing, not even whether the QR shows.
  v_arrival := public._c703_arrival_block(d.id);
  v_cold    := public._c703_cold_block(d.id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

  -- CHANGE #462 (gap 104)
  -- CHANGE #703: the approach ring is what opens the handover, so the buyer has
  -- the three minutes the alert promised them rather than three seconds at the
  -- door. Arrival still opens it for a rider who appeared inside 50 m.
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or d.approach_notified_at is not null
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
    -- CHANGE #703 (spec 1, 3 and 4)
    'arrival', v_arrival,
    'cold_chain', v_cold,
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
    -- CHANGE #701 — the route to THIS door and nothing else: the segment from
    -- where the rider is to this stop, the road distance along it, and the
    -- stops in front named by postal area only. The rest of the run passes
    -- other pharmacies' doors and is cut in _c701_route_segment.
    'route', public._c701_route_block(d.id),
    -- CHANGE #701 — "share live link with staff". The BACKEND decides who is
    -- offered it (a live stop with a token), so the public /track page — which
    -- has no identity to authorise a send — simply never receives the block.
    'share', jsonb_build_object(
      'has',   (d.status in ('assigned','out_for_delivery')
                and coalesce(d.track_token,'') <> ''),
      'label', public._c('delivery.share_staff'),
      'rpc',   'delivery_share_track_link',
      'order_id', d.order_id::text),
    'track_token', case when d.status in ('assigned','out_for_delivery')
                        then d.track_token end,
    'timeline', v_tl);
end $function$

;
CREATE OR REPLACE FUNCTION public.customer_track_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb; v_show_qr boolean;
        v_last record; v_snapped boolean; v_animate int; v_live jsonb;
        v_eta jsonb; v_proof jsonb; v_arrival jsonb; v_cold jsonb; v_is_buyer boolean;
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
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
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
  -- CHANGE #703: the doorbell and the cold box. Both are whole payloads —
  -- the tracker prints them and decides nothing, not even whether the QR shows.
  -- CHANGE #703 / #354: this RPC admits the RIDER as well as the buyer, and
  -- the handover OTP is the one thing the rider must never be handed. Who is
  -- asking is decided here, once, and the block obeys it.
  select (public._is_admin()
          or exists (select 1 from orders o2 join pharmacy_profiles pp2 on pp2.id = o2.customer_id
                      where o2.id = p_order_id and pp2.user_id = auth.uid()))
    into v_is_buyer;
  v_arrival := public._c703_arrival_block(d.id, coalesce(v_is_buyer,false));
  v_cold    := public._c703_cold_block(d.id);
  v_ahead := coalesce((v_eta->>'stops_ahead')::int, 0);

  -- CHANGE #462 (gap 104)
  -- CHANGE #703: the approach ring is what opens the handover, so the buyer has
  -- the three minutes the alert promised them rather than three seconds at the
  -- door. Arrival still opens it for a rider who appeared inside 50 m.
  v_show_qr := d.status in ('assigned','out_for_delivery')
               and (d.arrived_at is not null
                    or d.approach_notified_at is not null
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
    -- CHANGE #703 (spec 1, 3 and 4)
    'arrival', v_arrival,
    'cold_chain', v_cold,
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
    -- CHANGE #701 — the route to THIS door and nothing else: the segment from
    -- where the rider is to this stop, the road distance along it, and the
    -- stops in front named by postal area only. The rest of the run passes
    -- other pharmacies' doors and is cut in _c701_route_segment.
    'route', public._c701_route_block(d.id),
    -- CHANGE #701 — "share live link with staff". The BACKEND decides who is
    -- offered it (a live stop with a token), so the public /track page — which
    -- has no identity to authorise a send — simply never receives the block.
    'share', jsonb_build_object(
      'has',   (d.status in ('assigned','out_for_delivery')
                and coalesce(d.track_token,'') <> ''),
      'label', public._c('delivery.share_staff'),
      'rpc',   'delivery_share_track_link',
      'order_id', d.order_id::text),
    'track_token', case when d.status in ('assigned','out_for_delivery')
                        then d.track_token end,
    'timeline', v_tl);
end $function$

;
CREATE OR REPLACE FUNCTION public.delivery_track_public(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d deliveries%rowtype; v_loc delivery_partner_locations%rowtype;
  v_ahead int; v_name text; v_code text; v_show_qr boolean;
  v_eta jsonb; v_proof jsonb; v_arrival jsonb; v_cold jsonb;
begin
  -- CHANGE #701 — the public link is `track_token`, never `qr_token`. The QR
  -- token proves DELIVERY; using it as the tracking link meant one forwarded
  -- WhatsApp message carried the proof secret too, and never went stale.
  select * into d from deliveries where track_token = btrim(coalesce(p_token,''));

  -- Expired is its own answer, in the backend's own words — not "not found",
  -- which would tell a customer their order had vanished.
  if d.id is not null and d.track_token_expires_at is not null
     and d.track_token_expires_at <= now() then
    return jsonb_build_object(
      'ok', false, 'found', false, 'expired', true, 'tracking', false,
      'title', public._c('delivery.link_expired_title'),
      'message', public._c('delivery.link_expired'),
      'status', '', 'status_label', '', 'partner_name', '',
      'stops_ahead', 0, 'stops_ahead_label', '', 'has_stops_ahead', false,
      'eta', jsonb_build_object('has', false, 'state','none','label','',
                                'window_label','','countdown_label',''),
      'proof', jsonb_build_object('has', false),
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
      'route', jsonb_build_object('has', false, 'polyline','', 'km_label',''),
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
      'order_code', '', 'delivered_at', '', 'qr_token', '');
  end if;
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
      'arrival', jsonb_build_object('has', false, 'state','none'),
      'cold_chain', jsonb_build_object('has', false, 'is_cold_chain', false),
      'route', jsonb_build_object('has', false, 'polyline','', 'km_label',''),
      'rider_lat', 0, 'rider_lng', 0, 'has_rider_location', false,
      'destination_lat', 0, 'destination_lng', 0, 'has_destination', false,
      'order_code', '', 'delivered_at', '', 'qr_token', '');
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;
  select coalesce(order_code,'') into v_code from orders where id = d.order_id;

  v_eta   := public._delivery_eta_block(d.id);
  v_proof := public._delivery_proof_block(d.order_id);
  -- CHANGE #703: the same two blocks the in-app tracker draws, so the link a
  -- buyer forwards to their counter staff shows the identical doorbell.
  v_arrival := public._c703_arrival_block(d.id);
  v_cold    := public._c703_cold_block(d.id);
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
    'arrival', v_arrival,
    'cold_chain', v_cold,
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
    -- CHANGE #701 — same block the signed-in tracker prints, so the two pages
    -- cannot disagree about the route, the distance or who is ahead.
    'route', public._c701_route_block(d.id),
    'delivered_at', coalesce(d.delivered_at::text,''));
end $function$

;
CREATE OR REPLACE FUNCTION public.my_delivery_run(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me uuid := auth.uid(); v_partner delivery_partner_registrations%rowtype;
  v_date date; v_run delivery_runs%rowtype; v_stops jsonb; v_n int; v_batches jsonb;
begin
  select * into v_partner from delivery_partner_registrations
   where user_id = v_me and is_active and coalesce(is_deleted,false)=false limit 1;
  if v_partner.id is null then
    return jsonb_build_object('allowed', false, 'is_partner', false,
      'empty_title','Not a delivery account',
      'empty_note','This login is not registered as a delivery partner.');
  end if;
  v_date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);

  select * into v_run from delivery_runs
   where partner_id = v_partner.id and run_date = v_date
   order by created_at desc limit 1;

  select coalesce(jsonb_agg(x order by (x->>'seq')::int nulls last, x->>'pharmacy_name'), '[]'::jsonb),
         count(*)
    into v_stops, v_n
  from (
    select jsonb_build_object(
      'delivery_id', d.id, 'order_id', o.id, 'order_code', coalesce(o.order_code,''),
      'seq', d.seq, 'stop_group', d.stop_group,
      'pharmacy_name', coalesce(o.pharmacy_name, pp.pharmacy_name,''),
      'address', coalesce(pp.address,''),
      'delivery_instruction', coalesce((select ca.delivery_instruction
                                          from customer_addresses ca
                                         where ca.customer_id = pp.id
                                           and not ca.is_deleted
                                         order by ca.is_default desc, ca.created_at
                                         limit 1), ''),
      'phone', coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''),''),
      'lat', d.lat, 'lng', d.lng,
      'image_url', (select m.image_url_1 from order_items oi join "MEDICINE" m on m.id=oi.product_id
                     where oi.order_id=o.id and coalesce(oi.unfulfillable,false)=false
                       and m.image_url_1 is not null limit 1),
      'item_count', (select count(*) from order_items oi
                      where oi.order_id=o.id and coalesce(oi.unfulfillable,false)=false),
      'total_display', public.inr_money(coalesce(o.total_amount,0)),
      'status', d.status, 'accept_status', d.accept_status,
      'needs_response', (d.accept_status = 'pending'),
      'status_label', case d.status
          when 'delivered' then 'Delivered' when 'failed' then 'Failed'
          when 'out_for_delivery' then 'Out for delivery'
          when 'rto' then 'Returned' else 'Pending' end,
      -- Om's pin/stop colours: delivered green, not delivered yellow, failed red
      'pin_color', case d.status when 'delivered' then '#1B7A43'
                                 when 'failed' then '#B42318'
                                 when 'rto' then '#B42318' else '#F59E0B' end,
      'status_colors', case d.status
          when 'delivered' then jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
          when 'failed' then jsonb_build_object('bg','#FBE9E7','fg','#B42318')
          when 'rto' then jsonb_build_object('bg','#FBE9E7','fg','#B42318')
          else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end,
      -- CHANGE #309 (1): a parcel that has not been collected cannot be
      -- delivered. can_deliver is the BACKEND's answer, so the rider's Deliver
      -- button and the server's own gate can never disagree.
      'can_deliver', (d.status in ('assigned','out_for_delivery')
                      and d.accept_status='accepted'
                      and (d.handover_at is not null or public._handover_exempt(d))),
      'needs_handover', (d.accept_status='accepted'
                         and d.status in ('assigned','out_for_delivery')
                         and d.handover_at is null
                         and not public._handover_exempt(d)),
      'handover', jsonb_build_object(
         'done', (d.handover_at is not null),
         'at', d.handover_at,
         'chip', case when d.handover_at is not null
                      then public._c('delivery.handover_done_chip')
                      else public._c('delivery.handover_pending_chip') end,
         'colors', case when d.handover_at is not null
                        then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
                        else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end,
         'button_label', public._c('delivery.handover_button'),
         'received_by', coalesce(d.handover_to_name,''),
         'handed_over_by', coalesce(d.handover_by_name,'')),
      -- CHANGE #309 (2) and (10): the promise and the cold-chain badge, both
      -- rendered verbatim by the stop card.
      'sla', public._sla_block(d),
      -- CHANGE #703: the badge becomes a clock. _c703_cold_block adds elapsed
      -- vs allowed and its own tone; a stop that is not cold chain still gets
      -- the same `is_cold_chain:false` the card has always tested.
      'cold_chain', public._c703_cold_block(d.id),
      'arrived_at', d.arrived_at,
      'arrival_confirmed_at', d.arrival_confirmed_at,
      -- The auto-stamp asks the rider to confirm; it never asks twice.
      'confirm_arrival', jsonb_build_object(
        'has',   (d.arrived_at is not null and d.arrival_confirmed_at is null
                  and d.status = 'out_for_delivery'),
        'label', public._c('delivery.confirm_arrival_label'),
        'done_label', public._c('delivery.arrival_confirmed_label'),
        'rpc',   'delivery_confirm_arrival'),
      'missed_handover', jsonb_build_object(
        'has',   (d.missed_handover_at is not null),
        'label', public._c('delivery.missed_handover_title')),

      'arrived_chip', case when d.arrived_at is not null
                           then public._c('delivery.arrived_chip') else '' end,
      'qr_token', d.qr_token,
      'otp_sent', (d.otp_sent_at is not null),
      'delivered_at', d.delivered_at, 'fail_reason', d.fail_reason,
      'actions', jsonb_build_object(
         'call_number', '', 'call_action', public._call_action_block('delivery','customer', o.id),
         'whatsapp_number', coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''),''),
         'directions_url', case when d.lat is not null then
             'https://www.google.com/maps/dir/?api=1&destination=' || d.lat || ',' || d.lng end)
    ) as x
    from deliveries d
    join orders o on o.id = d.order_id
    left join pharmacy_profiles pp on pp.id = o.customer_id
    where d.partner_id = v_partner.id
      and (v_run.id is null or d.run_id = v_run.id)
      and d.status not in ('cancelled')
  ) s;

  -- batch chips: 1-10 | 11-20 | 21-30
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', g, 'label', ((g-1)*10+1)::text || '-' || (g*10)::text,
           'from', (g-1)*10+1, 'to', g*10) order by g), '[]'::jsonb)
    into v_batches
  from generate_series(1, greatest(ceil(coalesce(v_n,0)/10.0)::int,1)) g
  where coalesce(v_n,0) > 0;

  return jsonb_build_object(
    'allowed', true, 'is_partner', true,
    'partner_id', v_partner.id,
    'partner_name', coalesce(v_partner.full_name,''),
    'partner_type', v_partner.partner_type,
    'is_agency', (v_partner.partner_type = 'agency'),
    'the_date', v_date,
    'run_id', v_run.id, 'run_status', coalesce(v_run.status,'none'),
    -- CHANGE #703: an open anomaly, in the rider's own language, on the run
    -- screen they already have open. has:false when the run is clean.
    'nudge', public._c703_rider_nudge_block(v_run.id),
    'stop_count', coalesce(v_n,0),
    'delivered_count', (select count(*) from deliveries where partner_id=v_partner.id
                          and (v_run.id is null or run_id=v_run.id) and status='delivered'),
    'pending_count', (select count(*) from deliveries where partner_id=v_partner.id
                        and (v_run.id is null or run_id=v_run.id)
                        and status in ('assigned','out_for_delivery')),
    'can_start', (coalesce(v_run.status,'none') = 'planned'
                 and exists (select 1 from deliveries d2 where d2.run_id = v_run.id
                              and d2.accept_status = 'accepted' and d2.status = 'assigned')),
    'can_finish', (coalesce(v_run.status,'none') = 'started'),
    'trip_action', case
        when coalesce(v_run.status,'none') = 'started' then 'finish'
        when coalesce(v_run.status,'none') = 'planned'
             and exists (select 1 from deliveries d3 where d3.run_id = v_run.id
                          and d3.accept_status = 'accepted' and d3.status = 'assigned') then 'start'
        else 'none' end,
    'trip_button_label', case
        when coalesce(v_run.status,'none') = 'started' then 'Finish trip'
        when coalesce(v_run.status,'none') = 'planned'
             and exists (select 1 from deliveries d4 where d4.run_id = v_run.id
                          and d4.accept_status = 'accepted' and d4.status = 'assigned') then 'Start trip'
        when coalesce(v_run.status,'none') = 'completed' then 'Trip completed'
        else 'Nothing to deliver' end,
    'trip_button_enabled', (
        coalesce(v_run.status,'none') = 'started'
        or (coalesce(v_run.status,'none') = 'planned'
            and exists (select 1 from deliveries d5 where d5.run_id = v_run.id
                         and d5.accept_status = 'accepted' and d5.status = 'assigned'))),
    'batches', v_batches,
    'stops', v_stops,
    'empty_title','No deliveries assigned',
    'empty_note','Assigned deliveries will appear here.');
end $function$

;
-- CHANGE #703 — two helpers the acceptance proof needs.

-- The inverse of _c701_poly_decode. It exists so the proof can BUILD a route
-- and then stand off it: asserting "off route" against a polyline nobody
-- encoded would be asserting against a constant.
create or replace function public._c703_poly_encode(p_points jsonb)
returns text
language plpgsql immutable as $function$
declare
  v_out text := ''; p jsonb; v_lat int; v_lng int; v_plat int := 0; v_plng int := 0;

begin
  for p in select * from jsonb_array_elements(coalesce(p_points,'[]'::jsonb)) loop
    v_lat := round((p->>0)::numeric * 1e5)::int;
    v_lng := round((p->>1)::numeric * 1e5)::int;
    v_out := v_out || public._c703_poly_chunk(v_lat - v_plat)
                   || public._c703_poly_chunk(v_lng - v_plng);
    v_plat := v_lat; v_plng := v_lng;
  end loop;
  return v_out;
end $function$;

create or replace function public._c703_poly_chunk(p_v int)
returns text
language plpgsql immutable as $function$
declare v int; v_out text := '';
begin
  v := case when p_v < 0 then ~(p_v << 1) else (p_v << 1) end;
  while v >= 32 loop
    v_out := v_out || chr(((32 | (v & 31)) + 63));
    v := v >> 5;
  end loop;
  return v_out || chr(v + 63);
end $function$;

-- A straight leg ending at the destination: five vertices, ~5 km long.
create or replace function public._c703_test_polyline(p_lat numeric, p_lng numeric)
returns text
language sql immutable as $function$
  select public._c703_poly_encode(jsonb_build_array(
    jsonb_build_array(p_lat + 0.0450, p_lng),
    jsonb_build_array(p_lat + 0.0300, p_lng),
    jsonb_build_array(p_lat + 0.0150, p_lng),
    jsonb_build_array(p_lat + 0.0050, p_lng),
    jsonb_build_array(p_lat,          p_lng)));
$function$;

create or replace function public._c703_assert(p_name text, p_ok boolean)
returns jsonb
language sql immutable as $function$
  select jsonb_build_array(jsonb_build_object('name', p_name, 'ok', coalesce(p_ok,false)));
$function$;
-- CHANGE #703 part 7 — the acceptance proof (spec item 5).
--
-- Simulates a run as a sequence of location fixes and asserts what the spec
-- promised: each alert fires ONCE, the arrival auto-stamps, an anomaly is
-- raised and then cleared, a missed handover is flagged and cleared by coming
-- back, and a cold-chain stop past its window is flagged and reaches the
-- exceptions console. Everything it creates is is_synthetic, so the outbound
-- gates suppress every message, and it removes its own fixtures at the end.

create or replace function public.c703_geofence_proof()
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_partner uuid; v_order uuid; v_run uuid; v_del uuid; v_cust uuid;
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  -- Raipur, and a destination ~5 km away. The polyline is the straight leg
  -- between them, so "off route" has something real to be off.
  v_dlat numeric := 21.2514; v_dlng numeric := 81.6296;
  d public.deliveries%rowtype; v_n int; v_open int; v_ev int;


begin
  select id into v_partner from public.delivery_partner_registrations
   where coalesce(is_synthetic,false) order by created_at limit 1;
  if v_partner is null then
    return jsonb_build_object('ok', false, 'error', 'no_synthetic_rider',
      'note', 'seed a synthetic delivery partner before running this proof');
  end if;

  -- enforce_order_approval admits a synthetic order only against an approved
  -- synthetic pharmacy, which is the guard doing exactly its job.
  select id into v_cust from public.pharmacy_profiles
   where is_synthetic and approved and coalesce(is_deleted,false) = false limit 1;
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'no_synthetic_customer',
      'note', 'seed an approved synthetic pharmacy before running this proof');
  end if;

  -- ── fixtures ─────────────────────────────────────────────────────────────
  -- placed_by_admin: the order-hours gate is a CUSTOMER gate, and this row is
  -- placed by a proof, not by a pharmacy at 11 pm. Nothing else is bypassed.
  insert into public.orders (id, customer_id, fulfillment_status, dispatch_ready, source,
                             unfulfilled_count, is_synthetic, placed_by_admin, order_code)
  values (gen_random_uuid(), v_cust, 'shipped', false, 'website', 0, true, true, 'C703-PROOF')
  returning id into v_order;

  insert into public.delivery_runs (id, partner_id, run_date, status, started_at,
                                    zone_id, is_synthetic, road_polyline)
  values (gen_random_uuid(), v_partner, current_date, 'started', now() - interval '30 minutes',
          null, true, public._c703_test_polyline(v_dlat, v_dlng))
  returning id into v_run;

  insert into public.deliveries (id, order_id, run_id, partner_id, status, accept_status,
                                 attempt_no, seq, lat, lng, zone_id, is_synthetic,
                                 qr_token, started_at)
  values (gen_random_uuid(), v_order, v_run, v_partner, 'out_for_delivery', 'accepted',
          1, 1, v_dlat, v_dlng, null, true, 'c703proof', now() - interval '30 minutes')
  returning id into v_del;

  -- CHANGE #354: the code lives here, never on the deliveries row the rider reads.
  insert into public.delivery_otp (delivery_id, code, sent_at, attempts)
  values (v_del, '4321', now(), 0)
  on conflict (delivery_id) do update set code = excluded.code, verified_at = null;

  -- ── 1. far away: nothing fires ───────────────────────────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.030, v_dlng);  -- ~3.3 km
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('3 km out: no approach alert',
                d.approach_notified_at is null);

  -- ── 2. cross the 500 m ring: the buyer is told, once ─────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0030, v_dlng);  -- ~333 m
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('inside 500 m: approach stamped',
                d.approach_notified_at is not null);
  v_checks := v_checks || public._c703_assert('inside 500 m: not arrived yet',
                d.arrived_at is null);

  select count(*) into v_ev from public.delivery_events
   where delivery_id = v_del and event = 'approaching';
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0029, v_dlng);
  select count(*) into v_n from public.delivery_events
   where delivery_id = v_del and event = 'approaching';
  v_checks := v_checks || public._c703_assert('approach fires exactly once', v_n = v_ev and v_n = 1);

  -- the handover opens at the approach ring
  v_checks := v_checks || public._c703_assert('handover QR offered at approach',
                (public._c703_arrival_block(v_del, true) -> 'handover' ->> 'qr_token') = 'c703proof');
  v_checks := v_checks || public._c703_assert('arrival block state = approaching',
                (public._c703_arrival_block(v_del, true) ->> 'state') = 'approaching');

  -- ── 3. cross the 50 m ring: arrival auto-stamped, dwell started ──────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0003, v_dlng);  -- ~33 m
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('inside 50 m: arrived_at stamped',
                d.arrived_at is not null);
  v_checks := v_checks || public._c703_assert('inside 50 m: dwell timer started',
                d.dwell_started_at is not null);
  v_checks := v_checks || public._c703_assert('arrival block state = here',
                (public._c703_arrival_block(v_del, true) ->> 'state') = 'here');
  v_checks := v_checks || public._c703_assert('the buyer is given the OTP',
                (public._c703_arrival_block(v_del, true) -> 'handover' ->> 'otp') = '4321');
  -- CHANGE #354's line, held down here: the same block, asked for by the rider.
  v_checks := v_checks || public._c703_assert('the rider is NOT given the OTP',
                (public._c703_arrival_block(v_del, false) -> 'handover' ->> 'otp') is null
                and not ((public._c703_arrival_block(v_del, false) -> 'handover' ->> 'has_otp')::boolean));
  v_checks := v_checks || public._c703_assert('the rider still gets the QR they must scan',
                (public._c703_arrival_block(v_del, false) -> 'handover' ->> 'qr_token') = 'c703proof');
  v_checks := v_checks || public._c703_assert('doorbell heading is backend copy',
                coalesce(public._c703_arrival_block(v_del, true) ->> 'heading','') <> '');

  -- ── 4. leave without completing: missed handover ─────────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0150, v_dlng);  -- ~1.6 km
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('left the door: missed handover flagged',
                d.missed_handover_at is not null);
  select count(*) into v_n from public._exception_rows()
   where reason_code = 'missed_handover' and ref_id = v_del::text;
  v_checks := v_checks || public._c703_assert('missed handover reaches the exceptions console', v_n = 1);

  -- ── 5. come back: the flag clears itself ─────────────────────────────────
  perform public._c703_geofence_eval(v_partner, v_dlat + 0.0002, v_dlng);
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('returned to the door: flag cleared',
                d.missed_handover_at is null);

  -- ── 6. anomalies: raised once, then cleared ──────────────────────────────
  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat, v_dlng, 95);
  select count(*) into v_open from public.delivery_anomaly
   where run_id = v_run and kind = 'overspeed' and cleared_at is null;
  v_checks := v_checks || public._c703_assert('95 km/h raises overspeed', v_open = 1);

  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat, v_dlng, 97);
  select count(*) into v_open from public.delivery_anomaly
   where run_id = v_run and kind = 'overspeed' and cleared_at is null;
  v_checks := v_checks || public._c703_assert('a second speeding fix does not raise a second row', v_open = 1);

  select count(*) into v_n from public._exception_rows() where reason_code = 'rider_anomaly';
  v_checks := v_checks || public._c703_assert('the anomaly reaches the exceptions console', v_n >= 1);

  v_checks := v_checks || public._c703_assert('the rider is nudged in their own words',
                (public._c703_rider_nudge_block(v_run) ->> 'has')::boolean
                and coalesce(public._c703_rider_nudge_block(v_run) -> 'items' -> 0 ->> 'body','') <> '');

  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat, v_dlng, 40);
  select count(*) into v_open from public.delivery_anomaly
   where run_id = v_run and kind = 'overspeed' and cleared_at is null;
  v_checks := v_checks || public._c703_assert('slowing down clears the anomaly', v_open = 0);

  -- off route: 3 km from a polyline that runs straight to the door
  perform public._c703_anomaly_on_fix(v_partner, v_run, v_dlat + 0.0300, v_dlng + 0.0300, 30);
  v_checks := v_checks || public._c703_assert('off-route distance is measured against the polyline',
                public._c703_route_offset_m(
                  (select road_polyline from public.delivery_runs where id = v_run),
                  v_dlat + 0.0300, v_dlng + 0.0300) > 400);
  v_checks := v_checks || public._c703_assert('a point ON the route is not off route',
                public._c703_route_offset_m(
                  (select road_polyline from public.delivery_runs where id = v_run),
                  v_dlat, v_dlng) < 50);

  -- ── 7. cold chain: elapsed vs window, then the breach ────────────────────
  update public.deliveries
     set is_cold_chain = true, started_at = now() - interval '30 minutes',
         missed_handover_at = null
   where id = v_del;
  v_checks := v_checks || public._c703_assert('cold-chain card shows elapsed, not breached',
                (public._c703_cold_block(v_del) ->> 'has')::boolean
                and not (public._c703_cold_block(v_del) ->> 'breach')::boolean);

  update public.deliveries set started_at = now() - interval '400 minutes' where id = v_del;
  perform public.delivery_cold_chain_tick();
  select * into d from public.deliveries where id = v_del;
  v_checks := v_checks || public._c703_assert('past the window: delivery flagged',
                d.cold_breach_at is not null);
  v_checks := v_checks || public._c703_assert('cold-chain card says breach in the backend''s words',
                (public._c703_cold_block(v_del) ->> 'breach')::boolean
                and coalesce(public._c703_cold_block(v_del) ->> 'breach_label','') <> '');
  select count(*) into v_n from public._exception_rows()
   where reason_code = 'cold_chain_breach' and ref_id = v_del::text;
  v_checks := v_checks || public._c703_assert('cold breach reaches the exceptions console', v_n = 1);

  -- ── 8. completion clears the doorbell ────────────────────────────────────
  update public.deliveries set status = 'delivered', delivered_at = now() where id = v_del;
  v_checks := v_checks || public._c703_assert('delivered: the doorbell is gone',
                not (public._c703_arrival_block(v_del, true) ->> 'has')::boolean);

  -- ── cleanup ──────────────────────────────────────────────────────────────
  delete from public.delivery_otp where delivery_id = v_del;
  delete from public.delivery_anomaly where run_id = v_run;
  delete from public.delivery_events where delivery_id = v_del;
  delete from public.deliveries where id = v_del;
  delete from public.delivery_runs where id = v_run;
  delete from public.orders where id = v_order;

  select count(*) filter (where (x->>'ok')::boolean),
         count(*) filter (where not (x->>'ok')::boolean)
    into v_pass, v_fail
    from jsonb_array_elements(v_checks) x;

  return jsonb_build_object('ok', v_fail = 0, 'passed', v_pass, 'failed', v_fail,
                            'checks', v_checks);
end $function$;
