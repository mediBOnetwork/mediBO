-- CHANGE #704 — Agency-level dispatch.
--
-- Until now every assignment path (delivery_suggest_partner, delivery_assign,
-- delivery_wave_plan) could only ever name an INDIVIDUAL rider. An agency row
-- existed in delivery_partner_registrations (partner_type='agency') and could
-- add riders and read agency_team(), but mediBO could never hand an order to
-- the AGENCY and let it choose. This migration makes the assignment target a
-- rider OR an agency, gives the agency owner a dispatch board, and puts a
-- backend-owned response deadline behind it so an agency that sits on a stop
-- loses it back to mediBO automatically.
--
-- Everything here is idempotent: a resumed worker re-runs the file as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SCHEMA
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.deliveries add column if not exists agency_id uuid;
alter table public.deliveries add column if not exists agency_assigned_at timestamptz;
alter table public.deliveries add column if not exists agency_due_at timestamptz;
alter table public.deliveries add column if not exists agency_dispatched_at timestamptz;
alter table public.deliveries add column if not exists agency_timeout_at timestamptz;

-- 'agency_pending' is a REAL delivery state: the stop is ours to chase, but no
-- rider owns it yet. Widening the check (never narrowing it) keeps every
-- existing row valid.
alter table public.deliveries drop constraint if exists deliveries_status_chk;
alter table public.deliveries add constraint deliveries_status_chk
  check (status = any (array['unassigned','assigned','out_for_delivery',
                             'delivered','failed','rto','cancelled',
                             'agency_pending']));

create index if not exists deliveries_agency_pending_idx
  on public.deliveries (agency_id, agency_due_at)
  where status = 'agency_pending';

create index if not exists deliveries_agency_idx
  on public.deliveries (agency_id) where agency_id is not null;

-- The response deadline: a global default plus a per-zone override, exactly the
-- shape every other delivery knob already uses (delivery_config + zone override
-- merged by _dcfg).
alter table public.delivery_config
  add column if not exists agency_sla_min integer not null default 10;
alter table public.zone_delivery_config
  add column if not exists agency_sla_min integer;

-- The dispatch audit trail: who inside the agency took the decision, and when.
create table if not exists public.agency_dispatch_log (
  id           bigserial primary key,
  agency_id    uuid not null,
  delivery_id  uuid,
  order_id     uuid,
  partner_id   uuid,
  event        text not null,
  note         text,
  actor        text,
  created_at   timestamptz not null default now()
);
create index if not exists agency_dispatch_log_agency_idx
  on public.agency_dispatch_log (agency_id, created_at desc);

alter table public.agency_dispatch_log enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='agency_dispatch_log'
                    and policyname='agency_dispatch_log_no_direct') then
    -- No direct client access: every read and write goes through the
    -- SECURITY DEFINER RPCs below, which decide who is asking.
    create policy agency_dispatch_log_no_direct on public.agency_dispatch_log
      for select using (false);
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. BACKEND COPY (every string the app prints lives here)
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.ui_copy(key, value) values
  ('agency.dispatch_title',    to_jsonb('Agency dispatch'::text)),
  ('agency.dispatch_note',     to_jsonb('Stops mediBO handed to you. Give each one to a rider before the timer runs out.'::text)),
  ('agency.open_board',        to_jsonb('Open dispatch board'::text)),
  ('agency.waiting_heading',   to_jsonb('Waiting for a rider'::text)),
  ('agency.running_heading',   to_jsonb('With your riders'::text)),
  ('agency.empty',             to_jsonb('Nothing waiting. New stops appear here the moment mediBO sends them.'::text)),
  ('agency.empty_running',     to_jsonb('None of your riders is carrying a mediBO stop right now.'::text)),
  ('agency.pick_rider',        to_jsonb('Pick a rider'::text)),
  ('agency.change_rider',      to_jsonb('Change rider'::text)),
  ('agency.sheet_title',       to_jsonb('Give this stop to'::text)),
  ('agency.no_riders',         to_jsonb('No rider on your team has spare capacity right now.'::text)),
  ('agency.sla_left',          to_jsonb('{m} min left'::text)),
  ('agency.sla_soon',          to_jsonb('Under a minute left'::text)),
  ('agency.sla_over',          to_jsonb('Overdue — mediBO may take this back'::text)),
  ('agency.sla_lost',          to_jsonb('Taken back by mediBO'::text)),
  ('agency.bags_one',          to_jsonb('{n} bag'::text)),
  ('agency.bags_many',         to_jsonb('{n} bags'::text)),
  ('agency.km',                to_jsonb('{km} km away'::text)),
  ('agency.window_prefix',     to_jsonb('Promised {window}'::text)),
  ('agency.window_none',       to_jsonb('No promised window'::text)),
  ('agency.assigned_toast',    to_jsonb('Sent to {name}'::text)),
  ('agency.reassigned_toast',  to_jsonb('Moved to {name}'::text)),
  ('agency.not_an_agency',     to_jsonb('This login is not an agency account.'::text)),
  ('agency.not_your_stop',     to_jsonb('That stop was not given to your agency.'::text)),
  ('agency.rider_not_yours',   to_jsonb('That rider is not on your team.'::text)),
  ('agency.stop_closed',       to_jsonb('That stop is already finished.'::text)),
  ('agency.chain_pending',     to_jsonb('{agency} → picking a rider'::text)),
  ('agency.chain_rider',       to_jsonb('{agency} → {rider}'::text)),
  ('agency.reason_rider',      to_jsonb('Lightest load in this zone'::text)),
  ('agency.reason_rider_shift',to_jsonb('On shift now, lightest load in this zone'::text)),
  ('agency.reason_agency',     to_jsonb('Agency with the most spare riders in this zone'::text)),
  ('agency.reason_none',       to_jsonb('No active partner with spare capacity in this zone'::text)),
  ('agency.status_pending',    to_jsonb('With the agency'::text)),
  ('agency.track_pending',     to_jsonb('Agency assigned — a rider is being picked'::text)),
  ('agency.timeout_note',      to_jsonb('The agency did not pick a rider in time — mediBO reassigned this stop.'::text)),
  ('agency.timeout_held',      to_jsonb('The agency did not pick a rider in time and no mediBO rider is free.'::text)),
  ('agency.assign_title',      to_jsonb('Sent to {name}'::text)),
  ('agency.spare_label',       to_jsonb('{n} free'::text)),
  ('agency.pending_label',     to_jsonb('{n} waiting'::text)),
  ('exc.reason.agency_timeout',to_jsonb('Agency did not respond'::text)),
  ('exc.action.agency_timeout',to_jsonb('Open the run'::text))
on conflict (key) do nothing;

-- The exceptions console reason (#690). severity 3 sits with the other
-- delivery-side breaches; sla_hours 0 means it is over SLA the moment it lands.
insert into public.exception_reason(reason_code, source_key, severity, sla_hours,
                                    owner_kind, action_kind, action_route, sort_rank, enabled)
values ('agency_timeout','deliveries',3,0,'zone','route','delivery_run',53,true)
on conflict (reason_code) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. CONFIG — the deadline joins the one config payload everything reads
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._dcfg(p_zone smallint default null)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
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
    -- CHANGE #704 — how long an agency has to name one of its riders.
    'agency_sla_min',            coalesce(z.agency_sla_min,         d.agency_sla_min),
    'zone_id',                   p_zone)
  from public.delivery_config d
  left join public.zone_delivery_config z on z.zone_id = p_zone
  where d.id = 1;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE CANDIDATE POOL — a target is a rider OR an agency
-- ─────────────────────────────────────────────────────────────────────────────
--
-- One helper answers "who could take this stop", and both the single-order
-- suggestion and the wave planner read it, so the two can never disagree about
-- who is available. An AGENCY's capacity is the sum of its active riders'
-- spare capacity (spec 1); its LOAD is what its lightest free rider is already
-- carrying plus the stops it has not dispatched yet — that is what the stop
-- would actually land on, so an agency competes with an individual on the same
-- scale instead of being punished for having a team.
--
-- A rider who belongs to an agency is reachable THROUGH the agency and is not
-- offered as a mediBO-direct candidate: otherwise the same person would be
-- counted twice in one pool. Manual admin assignment is untouched — the admin
-- partner list still contains every active partner.

drop function if exists public._delivery_targets(smallint, uuid);
create or replace function public._delivery_targets(
  p_zone smallint, p_order_id uuid default null, p_shift_source text default 'roster')
 returns table(target_id uuid, kind text, name text, load int, spare int,
               capacity int, open_stops int, on_shift boolean, reason text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with cfg as (
    select coalesce((public._dcfg(p_zone)->>'reject_cooldown_min')::int, 240) as cool
  ),
  -- Everyone active in the zone, with the load and the on-shift answer this
  -- caller asked for: 'roster' is the planned shift (what the single-stop
  -- suggestion has always used), 'open' is a shift actually punched in (what
  -- wave planning has always used).
  base as (
    select p.id, p.partner_type, p.parent_agency_id, coalesce(p.full_name,'') as nm,
           p.max_stops,
           (select count(*)::int from public.deliveries d
             where d.partner_id = p.id
               and d.status in ('assigned','out_for_delivery')) as open_n,
           case when p_shift_source = 'open'
                then exists (select 1 from public.delivery_partner_shifts s
                              where s.partner_id = p.id and s.ended_at is null)
                else exists (select 1 from public.delivery_planned_shift ps
                              where ps.partner_id = p.id
                                and ps.shift_date = (now() at time zone 'Asia/Kolkata')::date
                                and (now() at time zone 'Asia/Kolkata')::time
                                    between ps.start_time and ps.end_time) end as shift_ok,
           coalesce((public.delivery_doc_state(p.id) ->> 'blocks_assignment')::boolean, false)
             as doc_blocked
      from public.delivery_partner_registrations p
     where p.is_active and coalesce(p.is_deleted,false) = false
       and coalesce(p.zone_id, p_zone) = p_zone
  ),
  riders as (
    select b.* from base b
     where coalesce(b.partner_type,'boy') <> 'agency'
       and b.parent_agency_id is null
       and b.doc_blocked = false
  ),
  agency_riders as (
    select b.*, b.parent_agency_id as ag from base b
     where coalesce(b.partner_type,'boy') <> 'agency'
       and b.parent_agency_id is not null
       and b.doc_blocked = false
  )
  select r.id, 'rider'::text, r.nm,
         r.open_n,
         case when r.max_stops is null then 999 else r.max_stops - r.open_n end,
         r.max_stops, r.open_n, r.shift_ok,
         case when r.shift_ok then public._c('agency.reason_rider_shift')
              else public._c('agency.reason_rider') end
    from riders r, cfg
   where (r.max_stops is null or r.open_n < r.max_stops)
     and (p_order_id is null or not exists (
           select 1 from public.delivery_events e
            where e.order_id = p_order_id and e.partner_id = r.id
              and e.event = 'rejected' and cfg.cool > 0
              and e.created_at >= now() - make_interval(mins => cfg.cool)))

  union all

  select a.id, 'agency'::text, a.nm,
         g.min_load + g.queued,
         g.spare - g.queued,
         g.capacity, g.open_stops + g.queued, (g.on_riders > 0),
         public._c('agency.reason_agency')
    from base a
    cross join lateral (
      select count(*) filter (where t.shift_ok)::int as on_riders,
             coalesce(sum(case when t.shift_ok
                          then greatest(coalesce(t.max_stops, 999) - t.open_n, 0)
                          else 0 end), 0)::int as spare,
             coalesce(min(case when t.shift_ok
                          and (t.max_stops is null or t.open_n < t.max_stops)
                          then t.open_n end), 0)::int as min_load,
             coalesce(sum(t.max_stops), 0)::int as capacity,
             coalesce(sum(t.open_n), 0)::int as open_stops,
             (select count(*)::int from public.deliveries d
               where d.agency_id = a.id and d.status = 'agency_pending') as queued
        from agency_riders t where t.ag = a.id) g,
    cfg
   where a.partner_type = 'agency'
     and g.spare > g.queued
     and (p_order_id is null or not exists (
           select 1 from public.delivery_events e
            where e.order_id = p_order_id and e.partner_id = a.id
              and e.event = 'rejected' and cfg.cool > 0
              and e.created_at >= now() - make_interval(mins => cfg.cool)));
$function$;

-- The single-stop suggestion. Same payload keys as before (partner_id, name,
-- open_stops, capacity, zone_id, on_shift, reason) so every existing caller
-- keeps working; `kind`, `type_label` and `spare` are additive.
create or replace function public.delivery_suggest_partner(p_order_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_zone smallint; v_best jsonb;
begin
  select coalesce(o.zone_id, pp.zone_id) into v_zone
  from orders o left join pharmacy_profiles pp on pp.id=o.customer_id where o.id=p_order_id;

  select jsonb_build_object('partner_id', t.target_id, 'name', t.name,
           'kind', t.kind,
           'type_label', case when t.kind='agency'
                              then public._c('agency.dispatch_title') else '' end,
           'open_stops', t.open_stops, 'capacity', t.capacity,
           'spare', t.spare, 'zone_id', v_zone,
           'on_shift', t.on_shift, 'reason', t.reason)
    into v_best
  from public._delivery_targets(v_zone, p_order_id, 'roster') t
  order by t.on_shift desc, t.load, t.name
  limit 1;

  return coalesce(v_best, jsonb_build_object('partner_id', null, 'kind', 'none',
    'reason', public._c('agency.reason_none')));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. ASSIGNMENT — delivery_assign(p_order_ids, p_partner_id) accepts an agency
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._agency_notify_dispatch(p_delivery_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare a delivery_partner_registrations%rowtype; d deliveries%rowtype; v_code text;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.agency_id is null then return; end if;
  select * into a from public.delivery_partner_registrations where id = d.agency_id;
  if a.user_id is null then return; end if;
  select coalesce(order_code,'') into v_code from public.orders where id = d.order_id;
  perform public._delivery_inbox(a.user_id, coalesce(a.email, a.phone),
    'agency_stop_assigned',
    public._c('agency.dispatch_title'),
    public._cf('agency.dispatch_note', '{}'::jsonb),
    '/delivery');
end $function$;

create or replace function public._delivery_assign_core(
  p_order_ids uuid[], p_partner_id uuid,
  p_actor text default 'engine'::text, p_wave_id uuid default null::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  r record; v_ok int := 0; v_blocked jsonb := '[]'::jsonb; v_elig jsonb;
  v_partner delivery_partner_registrations%rowtype; v_run uuid; v_did uuid;
  v_ozone smallint; v_docs jsonb; v_train jsonb; v_existing text;
  v_is_agency boolean; v_sla int; v_due timestamptz;
begin
  select * into v_partner from delivery_partner_registrations
   where id = p_partner_id and is_active and coalesce(is_deleted,false)=false;
  if v_partner.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message','That delivery partner is not active.');
  end if;

  v_is_agency := (v_partner.partner_type = 'agency');

  -- CHANGE #704: the document and training gates belong to the PERSON who will
  -- carry the parcel. An agency carries nothing — its rider is gated at the
  -- moment the agency names them (agency_dispatch_assign), which is the only
  -- door into a run, so the rule keeps exactly one place to hold.
  if not v_is_agency then
    v_docs := public.delivery_doc_state(p_partner_id);
    if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
      return jsonb_build_object('ok',false,'error','docs_expired',
        'title', v_docs->>'block_title', 'message', v_docs->>'block_message',
        'docs', v_docs->'docs');
    end if;

    v_train := public.delivery_training_state(p_partner_id);
    if coalesce((v_train->>'blocks_assignment')::boolean, false) then
      return jsonb_build_object('ok',false,'error','training_pending',
        'title', v_train->>'block_title', 'message', v_train->>'block_message',
        'modules', v_train->'modules');
    end if;

    select id into v_run from delivery_runs
     where partner_id = p_partner_id
       and run_date = (now() at time zone 'Asia/Kolkata')::date
       and status in ('planned','started')
     order by created_at desc limit 1;
    if v_run is null then
      insert into delivery_runs(partner_id, zone_id) values (p_partner_id, v_partner.zone_id)
      returning id into v_run;
    end if;
  else
    -- The clock starts the moment the stop lands on the agency, not when the
    -- agency next opens the app.
    v_sla := greatest(coalesce((public._dcfg(v_partner.zone_id)->>'agency_sla_min')::int, 10), 1);
    v_due := now() + make_interval(mins => v_sla);
  end if;

  for r in select unnest(p_order_ids) as oid loop
    select status into v_existing from deliveries where order_id = r.oid;
    if v_existing in ('delivered','rto') then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason', public.uic('delivery.assign_terminal_reason',
                                          'Already completed — use Re-deliver'));
      continue;
    end if;

    select coalesce(o.zone_id, pp.zone_id) into v_ozone
    from orders o left join pharmacy_profiles pp on pp.id=o.customer_id where o.id = r.oid;

    if v_partner.zone_id is not null and v_ozone is not null
       and v_partner.zone_id <> v_ozone then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason','Different zone — this partner works another zone');
      continue;
    end if;

    v_elig := public.delivery_eligibility(r.oid);
    if coalesce((v_elig->>'can_assign')::boolean,false) is not true then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason', v_elig->>'blocked_label');
      continue;
    end if;

    if v_is_agency then
      insert into deliveries(order_id, run_id, partner_id, agency_id,
                             agency_assigned_at, agency_due_at,
                             assigned_by, assigned_at,
                             accept_status, status, qr_token, lat, lng, zone_id, wave_id)
      select r.oid, null, null, p_partner_id, now(), v_due,
             auth.uid(), now(), 'pending', 'agency_pending',
             encode(extensions.gen_random_bytes(9),'hex'), pp.latitude, pp.longitude, v_ozone,
             p_wave_id
      from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
      where o.id = r.oid
      on conflict (order_id) do update
        set run_id = null, partner_id = null, agency_id = excluded.agency_id,
            agency_assigned_at = now(), agency_due_at = excluded.agency_due_at,
            agency_dispatched_at = null, agency_timeout_at = null,
            assigned_by = excluded.assigned_by, assigned_at = now(),
            accept_status = 'pending', status = 'agency_pending',
            rejected_at = null, reject_reason = null,
            qr_token = coalesce(deliveries.qr_token, excluded.qr_token),
            lat = excluded.lat, lng = excluded.lng, zone_id = excluded.zone_id,
            wave_id = coalesce(excluded.wave_id, deliveries.wave_id)
      returning id into v_did;

      insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
      values (v_did, r.oid, p_partner_id, 'agency_assigned', p_actor);

      insert into agency_dispatch_log(agency_id, delivery_id, order_id, event, note, actor)
      values (p_partner_id, v_did, r.oid, 'agency_assigned',
              public._c('agency.dispatch_note'), p_actor);

      perform public._agency_notify_dispatch(v_did);
    else
      insert into deliveries(order_id, run_id, partner_id, assigned_by, assigned_at,
                             accept_status, status, qr_token, lat, lng, zone_id, wave_id)
      select r.oid, v_run, p_partner_id, auth.uid(), now(), 'pending', 'assigned',
             encode(extensions.gen_random_bytes(9),'hex'), pp.latitude, pp.longitude, v_ozone,
             p_wave_id
      from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
      where o.id = r.oid
      on conflict (order_id) do update
        set run_id = excluded.run_id, partner_id = excluded.partner_id,
            assigned_by = excluded.assigned_by, assigned_at = now(),
            accept_status = 'pending', status = 'assigned',
            rejected_at = null, reject_reason = null,
            qr_token = coalesce(deliveries.qr_token, excluded.qr_token),
            lat = excluded.lat, lng = excluded.lng, zone_id = excluded.zone_id,
            wave_id = coalesce(excluded.wave_id, deliveries.wave_id)
        returning id into v_did;

      insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
      values (v_did, r.oid, p_partner_id, 'assigned', p_actor);

      perform public._delivery_notify_assigned(v_did);
    end if;
    v_ok := v_ok + 1;
  end loop;

  if v_run is not null then
    update delivery_runs set total_stops =
      (select count(distinct coalesce(stop_group, 0)) from deliveries where run_id = v_run)
     where id = v_run;
  end if;

  return jsonb_build_object('ok', true, 'assigned', v_ok, 'run_id', v_run,
    'delivery_id', v_did,
    'kind', case when v_is_agency then 'agency' else 'rider' end,
    'partner_name', coalesce(v_partner.full_name,''),
    'blocked', v_blocked,
    'title', case when v_is_agency
                  then public._cf('agency.assign_title',
                         jsonb_build_object('name', coalesce(v_partner.full_name,'')))
                  else 'Assigned ' || v_ok || case when v_ok = 1 then ' order' else ' orders' end
             end);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE AGENCY DISPATCHER — its own board, its own riders, no mediBO in the way
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._agency_for_caller(p_agency_id uuid default null)
 returns uuid
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select case
    when public.get_my_role() in ('admin','super_admin') and p_agency_id is not null
      then p_agency_id
    else (select r.id from public.delivery_partner_registrations r
           where r.user_id = auth.uid() and r.partner_type = 'agency'
             and r.is_active and coalesce(r.is_deleted,false) = false
           limit 1)
  end;
$function$;

-- Every rider on an agency's team, with the ONE answer to "can this rider take
-- another stop" — computed here, in SQL, so no surface repeats the comparison.
create or replace function public._agency_riders(p_agency_id uuid)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id', x.id, 'name', x.nm, 'phone', x.ph, 'vehicle', x.veh,
      'on_shift', x.on_shift, 'pending', x.pending, 'capacity', x.cap,
      'spare', x.spare,
      'spare_label', public._cf('agency.spare_label',
                       jsonb_build_object('n', x.spare::text)),
      'can_take', (x.spare > 0 and not x.blocked),
      'blocked', x.blocked,
      'block_message', case when x.blocked then x.block_msg else '' end,
      'status_label', case when x.pending > 0 then public.uic('delivery.rider_on_road','On the road')
                           when x.on_shift then public.uic('delivery.rider_idle','Idle')
                           else public.uic('delivery.rider_off','Off shift') end,
      'status_tone',  case when x.blocked then 'bad'
                           when x.pending > 0 then 'info'
                           when x.on_shift then 'good' else 'warn' end)
    order by x.blocked, x.spare desc, x.nm), '[]'::jsonb)
  from (
    select r.id, coalesce(r.full_name,'') nm, coalesce(r.phone,'') ph,
           coalesce(r.vehicle_type,'') veh,
           exists (select 1 from public.delivery_partner_shifts s
                    where s.partner_id = r.id and s.ended_at is null) on_shift,
           (select count(*)::int from public.deliveries d
             where d.partner_id = r.id
               and d.status in ('assigned','out_for_delivery')) pending,
           r.max_stops cap,
           greatest(coalesce(r.max_stops, 999)
                    - (select count(*)::int from public.deliveries d2
                        where d2.partner_id = r.id
                          and d2.status in ('assigned','out_for_delivery')), 0) spare,
           coalesce((public.delivery_doc_state(r.id) ->> 'blocks_assignment')::boolean, false) blocked,
           coalesce(public.delivery_doc_state(r.id) ->> 'block_message', '') block_msg
      from public.delivery_partner_registrations r
     where r.parent_agency_id = p_agency_id
       and r.is_active and coalesce(r.is_deleted,false) = false) x;
$function$;

create or replace function public.agency_dispatch_board(p_agency_id uuid default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare a delivery_partner_registrations%rowtype; v_id uuid;
        v_loc delivery_partner_locations%rowtype;
        v_waiting jsonb; v_running jsonb;
begin
  v_id := public._agency_for_caller(p_agency_id);
  if v_id is null then
    return jsonb_build_object('ok', false, 'allowed', false, 'is_agency', false,
      'title', public._c('agency.dispatch_title'),
      'message', public._c('agency.not_an_agency'),
      'waiting', '[]'::jsonb, 'running', '[]'::jsonb, 'riders', '[]'::jsonb);
  end if;
  select * into a from public.delivery_partner_registrations where id = v_id;
  select * into v_loc from public.delivery_partner_locations where partner_id = v_id;

  with stops as (
    select d.*, o.order_code, o.pharmacy_name, pp.address, pp.latitude, pp.longitude,
           (select count(distinct oi.bag_no)::int from public.order_items oi
             where oi.order_id = d.order_id and oi.bag_no is not null
               and coalesce(oi.unfulfillable,false) = false) as bags,
           coalesce(rp.full_name,'') as rider_name,
           greatest(0, floor(extract(epoch from (d.agency_due_at - now())))::int) as sec_left,
           (d.agency_due_at is not null and d.agency_due_at <= now()) as overdue
      from public.deliveries d
      join public.orders o on o.id = d.order_id
      left join public.pharmacy_profiles pp on pp.id = o.customer_id
      left join public.delivery_partner_registrations rp on rp.id = d.partner_id
     where d.agency_id = v_id
       and d.status in ('agency_pending','assigned','out_for_delivery')
  ), shaped as (
    select s.*, jsonb_build_object(
      'delivery_id', s.id, 'order_id', s.order_id,
      'order_code', coalesce(s.order_code,''),
      'pharmacy_name', coalesce(s.pharmacy_name,''),
      'address', coalesce(s.address,''),
      'status', s.status,
      'status_label', case s.status
          when 'agency_pending' then public._c('agency.status_pending')
          when 'out_for_delivery' then public.uic('delivery.out_chip','Out for delivery')
          else public.uic('delivery.assigned_chip','Assigned') end,
      'status_tone', case s.status when 'agency_pending' then 'warn'
                                   when 'out_for_delivery' then 'info' else 'good' end,
      'window_label', case when s.promised_at is null
          then public._c('agency.window_none')
          else public._cf('agency.window_prefix', jsonb_build_object('window',
                 to_char(s.promised_at at time zone 'Asia/Kolkata', 'HH12:MI AM'))) end,
      'has_distance', (v_loc.lat is not null and s.latitude is not null),
      'distance_label', case when v_loc.lat is not null and s.latitude is not null
          then public._cf('agency.km', jsonb_build_object('km',
                 to_char(public._km(v_loc.lat::double precision, v_loc.lng::double precision,
                                    s.latitude::double precision, s.longitude::double precision),
                         'FM990.0')))
          else '' end,
      'has_bags', (s.bags > 0),
      'bags_label', case when s.bags = 1 then public._cf('agency.bags_one', jsonb_build_object('n','1'))
                         when s.bags > 1 then public._cf('agency.bags_many', jsonb_build_object('n', s.bags::text))
                         else '' end,
      'rider_name', s.rider_name,
      'chain_label', case when s.rider_name = ''
          then public._cf('agency.chain_pending', jsonb_build_object('agency', coalesce(a.full_name,'')))
          else public._cf('agency.chain_rider', jsonb_build_object(
                 'agency', coalesce(a.full_name,''), 'rider', s.rider_name)) end,
      'sec_left', s.sec_left,
      'sla_label', case
          when s.agency_timeout_at is not null then public._c('agency.sla_lost')
          when s.status <> 'agency_pending' then ''
          when s.overdue then public._c('agency.sla_over')
          when s.sec_left < 60 then public._c('agency.sla_soon')
          else public._cf('agency.sla_left',
                 jsonb_build_object('m', ceil(s.sec_left / 60.0)::int::text)) end,
      'sla_tone', case
          when s.agency_timeout_at is not null or s.overdue then 'bad'
          when s.status <> 'agency_pending' then 'good'
          when s.sec_left <= 120 then 'warn' else 'good' end,
      'action', case when s.status = 'agency_pending'
          then jsonb_build_object('has', true, 'key', 'assign',
                 'label', public._c('agency.pick_rider'))
          when s.status in ('assigned','out_for_delivery')
          then jsonb_build_object('has', true, 'key', 'reassign',
                 'label', public._c('agency.change_rider'))
          else jsonb_build_object('has', false, 'key', '', 'label', '') end) as j
      from stops s
  )
  select coalesce(jsonb_agg(j order by sec_left, order_code)
                    filter (where status = 'agency_pending'), '[]'::jsonb),
         coalesce(jsonb_agg(j order by order_code)
                    filter (where status <> 'agency_pending'), '[]'::jsonb)
    into v_waiting, v_running
  from shaped;

  return jsonb_build_object(
    'ok', true, 'allowed', true, 'is_agency', true,
    'agency_id', v_id, 'agency_name', coalesce(a.full_name,''),
    'title', public._c('agency.dispatch_title'),
    'note',  public._c('agency.dispatch_note'),
    'open_label', public._c('agency.open_board'),
    'waiting_heading', public._c('agency.waiting_heading'),
    'running_heading', public._c('agency.running_heading'),
    'empty', public._c('agency.empty'),
    'empty_running', public._c('agency.empty_running'),
    'sheet_title', public._c('agency.sheet_title'),
    'no_riders', public._c('agency.no_riders'),
    'waiting', v_waiting, 'running', v_running,
    'waiting_count', jsonb_array_length(v_waiting),
    'running_count', jsonb_array_length(v_running),
    'riders', public._agency_riders(v_id));
end $function$;

-- One write for both "pick a rider" and "change rider": the agency reassigns
-- inside its own team without mediBO, and the rider then follows the ordinary
-- accept -> run -> track flow.
create or replace function public.agency_dispatch_assign(
  p_delivery_id uuid, p_partner_id uuid, p_agency_id uuid default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_ag uuid; d deliveries%rowtype; rp delivery_partner_registrations%rowtype;
        v_run uuid; v_docs jsonb; v_train jsonb; v_was uuid; v_msg text;
begin
  v_ag := public._agency_for_caller(p_agency_id);
  if v_ag is null then
    return jsonb_build_object('ok',false,'error','not_an_agency',
      'message', public._c('agency.not_an_agency'));
  end if;

  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null or d.agency_id is distinct from v_ag then
    return jsonb_build_object('ok',false,'error','not_your_stop',
      'message', public._c('agency.not_your_stop'));
  end if;
  if d.status in ('delivered','rto','failed','cancelled') then
    return jsonb_build_object('ok',false,'error','stop_closed',
      'message', public._c('agency.stop_closed'));
  end if;

  select * into rp from public.delivery_partner_registrations
   where id = p_partner_id and parent_agency_id = v_ag
     and is_active and coalesce(is_deleted,false) = false;
  if rp.id is null then
    return jsonb_build_object('ok',false,'error','rider_not_yours',
      'message', public._c('agency.rider_not_yours'));
  end if;

  -- The gate the agency branch of _delivery_assign_core deliberately deferred:
  -- it lands HERE, on the person who will actually carry the parcel.
  v_docs := public.delivery_doc_state(p_partner_id);
  if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','docs_expired',
      'title', v_docs->>'block_title', 'message', v_docs->>'block_message',
      'docs', v_docs->'docs');
  end if;
  v_train := public.delivery_training_state(p_partner_id);
  if coalesce((v_train->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','training_pending',
      'title', v_train->>'block_title', 'message', v_train->>'block_message',
      'modules', v_train->'modules');
  end if;

  select id into v_run from public.delivery_runs
   where partner_id = p_partner_id
     and run_date = (now() at time zone 'Asia/Kolkata')::date
     and status in ('planned','started')
   order by created_at desc limit 1;
  if v_run is null then
    insert into public.delivery_runs(partner_id, zone_id)
    values (p_partner_id, rp.zone_id) returning id into v_run;
  end if;

  v_was := d.partner_id;

  update public.deliveries
     set partner_id = p_partner_id, run_id = v_run,
         status = 'assigned', accept_status = 'pending',
         agency_dispatched_at = coalesce(agency_dispatched_at, now()),
         seq = null, accepted_at = null, rejected_at = null, reject_reason = null,
         -- Custody is personal (CHANGE #309): a new rider scans for themselves.
         handover_at = null, handover_by = null, handover_to = null,
         handover_by_name = null, handover_to_name = null, handover_method = null
   where id = p_delivery_id;

  update public.delivery_runs set total_stops =
    (select count(distinct coalesce(stop_group,0)) from public.deliveries where run_id = v_run)
   where id = v_run;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
  values (p_delivery_id, d.order_id, p_partner_id,
          case when v_was is null then 'agency_dispatched' else 'agency_reassigned' end,
          case when v_was is null then null else 'from '||v_was::text end,
          coalesce(auth.jwt()->>'email','agency'));

  insert into public.agency_dispatch_log(agency_id, delivery_id, order_id, partner_id,
                                         event, note, actor)
  values (v_ag, p_delivery_id, d.order_id, p_partner_id,
          case when v_was is null then 'agency_dispatched' else 'agency_reassigned' end,
          coalesce(rp.full_name,''), coalesce(auth.jwt()->>'email','agency'));

  perform public._delivery_notify_assigned(p_delivery_id);

  v_msg := case when v_was is null
                then public._cf('agency.assigned_toast',
                       jsonb_build_object('name', coalesce(rp.full_name,'')))
                else public._cf('agency.reassigned_toast',
                       jsonb_build_object('name', coalesce(rp.full_name,''))) end;

  return jsonb_build_object('ok', true, 'run_id', v_run,
    'partner_id', p_partner_id, 'partner_name', coalesce(rp.full_name,''),
    'was_reassign', (v_was is not null), 'message', v_msg);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE SLA — an agency that sits on a stop loses it back to mediBO
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The deadline is the backend's (delivery_config.agency_sla_min, per-zone
-- override). Past it the stop falls back to mediBO's own best INDIVIDUAL rider
-- — never to another of the agency's riders, which would hand it straight back
-- to the team that ignored it. The timeout is recorded as a delivery event, an
-- agency dispatch-log line, an exceptions-console row (#690) and a scorecard
-- input against the agency.

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

  union all
  -- CHANGE #704. The agency was given the stop and did not name a rider inside
  -- its response deadline, so mediBO took it back. The row stands while the
  -- stop is still open and disappears by itself when it completes — nobody
  -- closes it by hand.
  select 'agency_timeout', d.id::text, d.zone_id,
         coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
         coalesce(nullif(ag.full_name,''), '-'),
         d.agency_timeout_at,
         null,
         d.order_id::text
    from public.deliveries d
    left join public.orders o on o.id = d.order_id
    left join public.delivery_partner_registrations ag on ag.id = d.agency_id
   where d.agency_timeout_at is not null
     and d.status not in ('delivered','rto','cancelled')
$function$;

create or replace function public.delivery_agency_sla_tick()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare r record; v_rider uuid; v_name text; v_sev int; v_moved int := 0; v_held int := 0;
begin
  select severity into v_sev from public.exception_reason where reason_code = 'agency_timeout';

  for r in
    select d.id, d.order_id, d.agency_id, d.zone_id
      from public.deliveries d
     where d.status = 'agency_pending'
       and d.agency_timeout_at is null
       and d.agency_due_at is not null
       and d.agency_due_at <= now()
     order by d.agency_due_at
     limit 200
  loop
    -- Stamp FIRST: a tick that overlaps itself must never time the same stop
    -- out twice, and the stamp is what every downstream surface reads.
    update public.deliveries set agency_timeout_at = now() where id = r.id;

    insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    values (r.id, r.order_id, r.agency_id, 'agency_timeout',
            public._c('agency.timeout_note'), 'engine');

    insert into public.agency_dispatch_log(agency_id, delivery_id, order_id, event, note, actor)
    values (r.agency_id, r.id, r.order_id, 'agency_timeout',
            public._c('agency.timeout_note'), 'engine');

    -- The agency's scorecard: the same input table every closed exception feeds.
    insert into public.exception_scorecard_input(subject_kind, subject_key, reason_code,
             outcome_code, weight, exception_id, zone_id, closed_at, closed_by)
    values ('agency', r.agency_id::text, 'agency_timeout', 'agency_timeout',
            coalesce(v_sev, 3), 'agency_timeout:' || r.id::text, r.zone_id, now(), 'engine');

    v_rider := null;
    select t.target_id, t.name into v_rider, v_name
      from public._delivery_targets(r.zone_id, r.order_id, 'roster') t
     where t.kind = 'rider'
     order by t.on_shift desc, t.load, t.name
     limit 1;

    if v_rider is not null then
      perform public._delivery_assign_core(array[r.order_id], v_rider, 'agency_timeout', null);
      v_moved := v_moved + 1;
    else
      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
      values (r.id, r.order_id, null, 'agency_timeout_held',
              public._c('agency.timeout_held'), 'engine');
      v_held := v_held + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'moved', v_moved, 'held', v_held);
end $function$;

-- The dispatcher runs it: no bare */N schedule, one row in cron_task.
insert into public.cron_task(name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                             enabled, note, base_interval_s, max_interval_s, dml)
values ('delivery_agency_sla', 948, 'poll',
        'select exists (select 1 from public.deliveries where status = ''agency_pending'' and agency_timeout_at is null and agency_due_at <= now())',
        'select public.delivery_agency_sla_tick()',
        20000, true,
        'CHANGE #704 — an agency that has not named a rider by its deadline loses the stop back to mediBO''s own suggestion.',
        60, 600, true)
on conflict (name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. WAVE PLANNING — an agency can be in the pool
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Same shape as _wave_riders (which admin_delivery_waves still reads), plus the
-- kind. Wave dispatch already routes delivery_wave_stop.partner_id through
-- _delivery_assign_core, so an agency picked here becomes an agency_pending
-- stop with no further change to the dispatch path.

create or replace function public._wave_targets(p_zone_id smallint)
 returns table(partner_id uuid, name text, open_stops integer, capacity integer, kind text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select t.target_id, t.name, t.load,
         coalesce(nullif(t.capacity, 0),
                  (select c.max_per_rider from public.delivery_wave_zone_config c
                    where c.zone_id = p_zone_id)),
         t.kind
    from public._delivery_targets(p_zone_id, null, 'open') t
   where t.on_shift
   order by 3, 2;
$function$;

-- delivery_wave_plan now plans over _wave_targets, so an agency competes for
-- a wave stop on the same terms as an individual rider.
CREATE OR REPLACE FUNCTION public.delivery_wave_plan(p_wave_id uuid, p_actor text DEFAULT 'engine'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  w delivery_wave%rowtype; s record; v_pick uuid; v_name text; v_load int;
  v_cap int; v_riders int; v_planned int := 0; v_unassigned int := 0;
  v_load_map jsonb := '{}'::jsonb;
begin
  select * into w from delivery_wave where id = p_wave_id;
  if w.id is null then
    return jsonb_build_object('ok',false,'error','wave_not_found');
  end if;
  if w.status in ('dispatched','closed','cancelled') then
    return jsonb_build_object('ok',false,'error','wave_closed',
      'message','That wave is already out with the riders.');
  end if;

  -- Seed the running load from what each rider is carrying right now.
  select count(*)::int into v_riders from public._wave_targets(w.zone_id);
  select coalesce(jsonb_object_agg(partner_id::text, open_stops), '{}'::jsonb)
    into v_load_map from public._wave_targets(w.zone_id);

  if v_riders = 0 then
    update delivery_wave set status = 'planned', rider_count = 0 where id = w.id;
    perform public._wave_log(w.id, null, null, null, null, 'no_riders',
      'No rider is on shift in this zone — the wave is holding its stops.',
      '{}'::jsonb, p_actor);
    return public.delivery_wave_detail(w.id);
  end if;

  for s in
    select * from delivery_wave_stop
     where wave_id = w.id and status = 'planned'
     order by created_at
  loop
    v_pick := null;
    select r.partner_id, r.name, coalesce((v_load_map->>r.partner_id::text)::int, r.open_stops),
           r.capacity
      into v_pick, v_name, v_load, v_cap
      from public._wave_targets(w.zone_id) r
     where not (r.partner_id = any (s.rejected_by))
       and (r.capacity is null
            or coalesce((v_load_map->>r.partner_id::text)::int, r.open_stops) < r.capacity)
     order by coalesce((v_load_map->>r.partner_id::text)::int, r.open_stops), r.name
     limit 1;

    if v_pick is null then
      v_unassigned := v_unassigned + 1;
      update delivery_wave_stop
         set partner_id = null, status = 'held',
             reason = case when array_length(s.rejected_by,1) is not null
                           then 'Every rider on shift has passed on this stop or is full'
                           else 'No rider on shift has spare capacity in this zone' end
       where id = s.id;
      perform public._wave_log(w.id, s.id, s.order_id, null, null, 'stop_held',
        case when array_length(s.rejected_by,1) is not null
             then 'Every rider on shift has passed on this stop or is full'
             else 'No rider on shift has spare capacity in this zone' end,
        '{}'::jsonb, p_actor);
      continue;
    end if;

    update delivery_wave_stop
       set partner_id = v_pick, status = 'planned',
           reason = 'Lightest load in this zone — ' || v_load ||
                    case when v_load = 1 then ' stop' else ' stops' end || ' in hand'
     where id = s.id;
    v_load_map := jsonb_set(v_load_map, array[v_pick::text], to_jsonb(v_load + 1));
    v_planned := v_planned + 1;

    perform public._wave_log(w.id, s.id, s.order_id, v_pick, null, 'stop_planned',
      'Given to ' || v_name || ' — lightest load in this zone (' || v_load ||
      case when v_load = 1 then ' stop' else ' stops' end || ' in hand).',
      jsonb_build_object('load_before', v_load, 'capacity', v_cap), p_actor);
  end loop;

  update delivery_wave
     set rider_count = (select count(distinct partner_id) from delivery_wave_stop
                         where wave_id = w.id and partner_id is not null
                           and status in ('planned','assigned')),
         stop_count = (select count(*) from delivery_wave_stop
                        where wave_id = w.id and status in ('planned','assigned','held')),
         status = case when w.status = 'dispatched' then w.status
                       when w.mode = 'auto' then 'approved'
                       else 'proposed' end
   where id = w.id;

  -- AUTO dispatches itself. SUGGEST stops here with the plan on screen, which
  -- is the whole point of the default mode.
  if w.mode = 'auto' and v_planned > 0 then
    perform public._wave_log(w.id, null, null, null, null, 'wave_auto_approved',
      'Zone is on auto — the plan was dispatched without waiting for an admin.',
      jsonb_build_object('stops', v_planned), p_actor);
    return public.delivery_wave_dispatch(w.id, p_actor);
  end if;

  if w.mode = 'suggest' then
    perform public._wave_log(w.id, null, null, null, null, 'wave_proposed',
      'Plan ready for ' || v_planned ||
      case when v_planned = 1 then ' stop' else ' stops' end ||
      ' — waiting for an admin to approve.',
      jsonb_build_object('stops', v_planned, 'held', v_unassigned), p_actor);
  end if;

  return public.delivery_wave_detail(w.id);
end $function$

;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE ADMIN QUEUE AND THE BUYER'S TRACKER SEE THE CHAIN
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_delivery_queue(p_date date DEFAULT NULL::date, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_date date; v_zone smallint; v_rows jsonb; v_partners jsonb; v_zname text;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false, 'orders', '[]'::jsonb);
  end if;
  v_date := public.scope_date(p_date);
  v_zone := public.scope_zone(p_zone);
  select name into v_zname from zones where id = v_zone;

  select coalesce(jsonb_agg(x order by x->>'pharmacy_name'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'order_id', o.id, 'order_code', coalesce(o.order_code,''),
      'pharmacy_name', coalesce(o.pharmacy_name, pp.pharmacy_name, ''),
      'address', coalesce(pp.address,''),
      'phone', coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''), ''),
      'lat', pp.latitude, 'lng', pp.longitude,
      'has_location', (pp.latitude is not null and pp.longitude is not null),
      'total_display', public.inr_money(coalesce(o.total_amount,0)),
      'item_count', (select count(*) from order_items oi
                      where oi.order_id = o.id and coalesce(oi.unfulfillable,false) = false),
      'eligibility', public.delivery_eligibility(o.id),
      'delivery', case when d.id is null then null else jsonb_build_object(
          'delivery_id', d.id, 'status', d.status, 'accept_status', d.accept_status,
          'partner_id', d.partner_id, 'partner_name', coalesce(dp.full_name,''),
          -- CHANGE #704: the agency -> rider chain, so the queue shows WHO the
          -- stop sits with and admin can override either link.
          'agency_id', d.agency_id,
          'agency_name', coalesce(ag.full_name,''),
          'is_agency', (d.agency_id is not null),
          'chain_label', case when d.agency_id is null then coalesce(dp.full_name,'')
               when d.partner_id is null then public._cf('agency.chain_pending',
                 jsonb_build_object('agency', coalesce(ag.full_name,'')))
               else public._cf('agency.chain_rider', jsonb_build_object(
                 'agency', coalesce(ag.full_name,''), 'rider', coalesce(dp.full_name,''))) end,
          'agency_timed_out', (d.agency_timeout_at is not null),
          'assigned_at', d.assigned_at, 'delivered_at', d.delivered_at,
          'fail_reason', d.fail_reason,
          'status_label', case d.status
             when 'agency_pending' then public._c('agency.status_pending')
             when 'assigned' then (case d.accept_status
                 when 'pending' then 'Awaiting acceptance'
                 when 'rejected' then 'Rejected'
                 when 'expired' then public.uic('delivery.accept_expired_chip','Not accepted — released')
                 else 'Accepted' end)
             when 'out_for_delivery' then 'Out for delivery'
             when 'delivered' then 'Delivered'
             when 'failed' then 'Failed' when 'rto' then 'Returned'
             when 'unassigned' then (case when d.accept_status='expired'
                 then public.uic('delivery.accept_expired_chip','Not accepted — released')
                 else 'Unassigned' end)
             else 'Unassigned' end,
          -- CMD #454: the row's buttons are the BACKEND's list, so a state this
          -- build has never heard of simply offers nothing rather than guessing.
          'actions', (
            select coalesce(jsonb_agg(a order by ord), '[]'::jsonb)
              from (
                select 1 as ord, jsonb_build_object('key','reassign',
                         'label', public.uic('delivery.act_reassign','Reassign'),
                         'tone','neutral') as a
                 where d.status not in ('delivered','rto')
                union all
                select 2, jsonb_build_object('key','rto_receive',
                         'label', public.uic('delivery.act_rto_receive','Check back in'),
                         'tone','warning')
                 where d.status in ('failed','rto') and d.rto_received_at is null
                union all
                select 3, jsonb_build_object('key','redeliver',
                         'label', public.uic('delivery.act_redeliver','Re-deliver'),
                         'tone','neutral')
                 where d.status in ('delivered','rto')
                union all
                select 4, jsonb_build_object('key','track',
                         'label', public.uic('delivery.act_track','Route taken'),
                         'tone','neutral', 'run_id', d.run_id)
                 where d.run_id is not null
              ) z),
          'status_colors', case
             when d.status='delivered' then jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
             when d.status='failed' or d.accept_status='rejected'
                                    then jsonb_build_object('bg','#FBE9E7','fg','#B42318')
             when d.status='out_for_delivery' then jsonb_build_object('bg','#E6F1FB','fg','#0C447C')
             else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end) end
    ) as x
    from orders o
    left join pharmacy_profiles pp on pp.id = o.customer_id
    left join deliveries d on d.order_id = o.id
    left join delivery_partner_registrations dp on dp.id = d.partner_id
    left join delivery_partner_registrations ag on ag.id = d.agency_id
    where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
      and coalesce(o.status,'') <> 'cancelled'
      and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)
  ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'partner_id', p.id, 'name', coalesce(p.full_name,''),
           'partner_type', p.partner_type,
           'type_label', case when p.partner_type='agency' then 'Agency' else 'Delivery boy' end,
           'phone', coalesce(p.phone,''), 'vehicle', coalesce(p.vehicle_type,''),
           'zone_id', p.zone_id,
           'open_stops', (select count(*) from deliveries d2
                           where d2.partner_id = p.id
                             and d2.status in ('assigned','out_for_delivery'))
         ) order by p.partner_type desc, p.full_name), '[]'::jsonb)
    into v_partners
  from delivery_partner_registrations p
  where p.is_active and coalesce(p.is_deleted,false) = false
    and public.scope_zone_ok(p.zone_id, v_zone);

  return jsonb_build_object(
    'allowed', true, 'the_date', v_date,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'),
    'orders', v_rows, 'partners', v_partners,
    'ready_count', (select count(*) from jsonb_array_elements(v_rows) r
                     where (r->'eligibility'->>'can_assign')::boolean and r->'delivery' is null));
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
        v_eta jsonb; v_proof jsonb; v_arrival jsonb; v_cold jsonb; v_is_buyer boolean;
begin
  select (
      public._is_admin()
      or exists (select 1 from orders o join pharmacy_profiles pp on pp.id = o.customer_id
                  where o.id = p_order_id and pp.user_id = auth.uid())
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations p on p.id = dd.partner_id
                 where dd.order_id = p_order_id and p.user_id = auth.uid())
      -- CHANGE #704: the agency holding the stop can read its own tracking too.
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations ap on ap.id = dd.agency_id
                 where dd.order_id = p_order_id and ap.user_id = auth.uid())
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
        -- CHANGE #704: before the agency names a rider there IS no rider to
        -- show, and the buyer is told exactly that rather than nothing.
        when 'agency_pending' then public._c('agency.track_pending')
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'partner_name', coalesce(v_name,''),
    'assigned_to', jsonb_build_object(
        'has',  (d.agency_id is not null or d.partner_id is not null),
        'kind', case when d.partner_id is not null then 'rider'
                     when d.agency_id is not null then 'agency' else 'none' end,
        'name', case when d.partner_id is not null then coalesce(v_name,'')
                     else coalesce((select ag.full_name
                                      from delivery_partner_registrations ag
                                     where ag.id = d.agency_id), '') end,
        'label', case when d.partner_id is not null then coalesce(v_name,'')
                      when d.agency_id is not null then public._c('agency.track_pending')
                      else '' end),
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
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. ADMIN OVERRIDE — reassigning TO an agency is the same one button
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.delivery_reassign(p_delivery_id uuid, p_partner_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare d deliveries%rowtype; v_run uuid; v_docs jsonb;
        v_target delivery_partner_registrations%rowtype; v_sla int;
begin
  if public.partner_scope_delivery(p_delivery_id, 'partner.assign_delivery', 'write') not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into d from deliveries where id=p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if d.status='delivered' then
    return jsonb_build_object('ok',false,'error','already_delivered','message','Already delivered.');
  end if;

  select * into v_target from delivery_partner_registrations
   where id = p_partner_id and is_active and coalesce(is_deleted,false)=false;
  if v_target.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message','That delivery partner is not active.');
  end if;

  -- CHANGE #704: the admin's one Reassign button can hand the stop to an
  -- AGENCY as easily as to a rider. Handing it to an agency puts it back in
  -- the agency's court with a fresh response deadline; no rider owns it.
  if v_target.partner_type = 'agency' then
    v_sla := greatest(coalesce((public._dcfg(coalesce(v_target.zone_id, d.zone_id))
                                ->>'agency_sla_min')::int, 10), 1);
    update deliveries
       set agency_id = p_partner_id, partner_id = null, run_id = null,
           status = 'agency_pending', accept_status = 'pending',
           agency_assigned_at = now(), agency_due_at = now() + make_interval(mins => v_sla),
           agency_dispatched_at = null, agency_timeout_at = null,
           seq = null, accepted_at = null, rejected_at = null, reject_reason = null,
           handover_at=null, handover_by=null, handover_to=null,
           handover_by_name=null, handover_to_name=null, handover_method=null
     where id = p_delivery_id;

    insert into delivery_events(delivery_id,order_id,partner_id,event,note,actor)
    values (p_delivery_id, d.order_id, p_partner_id, 'agency_assigned',
            'from '||coalesce(d.partner_id::text,'-'), coalesce(auth.jwt()->>'email','admin'));
    insert into agency_dispatch_log(agency_id, delivery_id, order_id, event, note, actor)
    values (p_partner_id, p_delivery_id, d.order_id, 'agency_assigned',
            public._c('agency.dispatch_note'), coalesce(auth.jwt()->>'email','admin'));
    perform public._agency_notify_dispatch(p_delivery_id);

    return jsonb_build_object('ok',true,'kind','agency','run_id',null,
      'message', public._cf('agency.assign_title',
                   jsonb_build_object('name', coalesce(v_target.full_name,''))));
  end if;

  -- CHANGE #309 (6): the same document gate as delivery_assign. Reassignment is
  -- the other door into a rider's run, and a rule with one door open is not a
  -- rule. A reassignment that also CLEARS custody resets handover_at below, so
  -- the new rider must scan the parcel for themselves.
  v_docs := public.delivery_doc_state(p_partner_id);
  if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','docs_expired',
      'title',   v_docs->>'block_title',
      'message', v_docs->>'block_message',
      'docs',    v_docs->'docs');
  end if;

  select id into v_run from delivery_runs
   where partner_id=p_partner_id and run_date=(now() at time zone 'Asia/Kolkata')::date
     and status in ('planned','started') order by created_at desc limit 1;
  if v_run is null then
    insert into delivery_runs(partner_id) values (p_partner_id) returning id into v_run;
  end if;

  update deliveries set partner_id=p_partner_id, run_id=v_run, accept_status='pending',
         status='assigned', seq=null, accepted_at=null, rejected_at=null, reject_reason=null,
         -- CHANGE #309 (1): custody is personal. Handing the stop to a different
         -- rider clears the handover, so the parcel is scanned again by whoever
         -- actually takes it — otherwise rider B inherits rider A's alibi.
         handover_at=null, handover_by=null, handover_to=null,
         handover_by_name=null, handover_to_name=null, handover_method=null
   where id=p_delivery_id;
  insert into delivery_events(delivery_id,order_id,partner_id,event,note,actor)
  values (p_delivery_id,d.order_id,p_partner_id,'reassigned',
          'from '||coalesce(d.partner_id::text,'-'),coalesce(auth.jwt()->>'email','admin'));
  return jsonb_build_object('ok',true,'kind','rider','run_id',v_run,'message','Reassigned');
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. agency_team() — its own stops are now the agency_pending queue
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Before #704 an agency's "my stops" were rows carrying partner_id = the agency
-- itself, which only existed because assignment had no other way to name an
-- agency. They are agency_id + status 'agency_pending' now, and the section
-- links to the full dispatch board.

create or replace function public.agency_team(p_date date default null::date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare a delivery_partner_registrations%rowtype; v_date date; v_riders jsonb; v_unassigned jsonb;
begin
  select * into a from delivery_partner_registrations
   where user_id = auth.uid() and partner_type='agency' and is_active
     and coalesce(is_deleted,false)=false limit 1;
  if a.id is null then
    return jsonb_build_object('allowed',false,'is_agency',false,
      'empty_title', public._c('agency.not_an_agency'));
  end if;
  v_date := coalesce(p_date,(now() at time zone 'Asia/Kolkata')::date);

  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id',c.id,'name',coalesce(c.full_name,''),'phone',coalesce(c.phone,''),
      'vehicle',coalesce(c.vehicle_type,''),
      'on_shift', exists(select 1 from delivery_partner_shifts s
                          where s.partner_id=c.id and s.ended_at is null),
      'assigned',  st.assigned, 'delivered', st.delivered, 'failed', st.failed,
      'pending',   st.pending,
      'status_label', case when st.pending > 0 then 'On the road'
                           when st.delivered > 0 then 'Finished'
                           else 'Idle' end,
      'status_colors', case when st.pending > 0 then jsonb_build_object('bg','#E6F1FB','fg','#0C447C')
                            when st.delivered > 0 then jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                            else jsonb_build_object('bg','#EFEEE9','fg','#5A5A57') end,
      'lat', l.lat, 'lng', l.lng, 'last_seen', l.updated_at,
      'capacity', c.max_stops,
      'at_capacity', (c.max_stops is not null and st.pending >= c.max_stops)
    ) order by st.pending desc, c.full_name), '[]'::jsonb)
    into v_riders
  from delivery_partner_registrations c
  left join delivery_partner_locations l on l.partner_id = c.id
  cross join lateral (
    select count(*) filter (where d.status='assigned')::int assigned,
           count(*) filter (where d.status='delivered')::int delivered,
           count(*) filter (where d.status='failed')::int failed,
           count(*) filter (where d.status in ('assigned','out_for_delivery'))::int pending
    from deliveries d join delivery_runs r on r.id=d.run_id
    where d.partner_id=c.id and r.run_date = v_date) st
  where c.parent_agency_id = a.id and coalesce(c.is_deleted,false)=false and c.is_active;

  -- CHANGE #704: stops mediBO gave the AGENCY that no rider owns yet.
  select coalesce(jsonb_agg(jsonb_build_object(
      'delivery_id',d.id,'order_code',coalesce(o.order_code,''),
      'pharmacy_name',coalesce(o.pharmacy_name,''),
      'address',coalesce(pp.address,''),
      'status',d.status,'accept_status',d.accept_status) order by d.agency_due_at), '[]'::jsonb)
    into v_unassigned
  from deliveries d
  join orders o on o.id = d.order_id
  left join pharmacy_profiles pp on pp.id = o.customer_id
  where d.agency_id = a.id and d.status = 'agency_pending';

  return jsonb_build_object(
    'allowed', true, 'is_agency', true,
    'agency_id', a.id, 'agency_name', coalesce(a.full_name,''),
    'the_date', v_date,
    'riders', v_riders, 'rider_count', jsonb_array_length(v_riders),
    'my_stops', v_unassigned, 'my_stop_count', jsonb_array_length(v_unassigned),
    'title','My riders',
    'note','Add riders, then hand any of your stops to one of them.',
    'board_label', public._c('agency.open_board'),
    'board_title', public._c('agency.dispatch_title'),
    'can_add_rider', true);
end $function$;

grant execute on function public.agency_dispatch_board(uuid) to authenticated;
grant execute on function public.agency_dispatch_assign(uuid, uuid, uuid) to authenticated;
grant execute on function public.delivery_agency_sla_tick() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. BEHAVIOUR PROOFS (rg_behavior_tests) — the QA journeys of spec 6, as
--     re-runnable SQL. Each builds its own fixture and rolls the whole thing
--     back, so they can be run against production at any time:
--       select public.rg_run_behavior('c704_agency_assign_dispatch_deliver');
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._c704_fixture()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $fn$
declare v_ag uuid; v_r1 uuid; v_r2 uuid; v_solo uuid; v_oid uuid;
        v_pid bigint; v_uid uuid; v_cust uuid; v_ph text;
begin
  select id into v_uid from auth.users where email = 'test.sup1@medibo.in' limit 1;
  select id into v_cust from pharmacy_profiles
   where is_synthetic and approved and coalesce(is_deleted,false)=false limit 1;
  select mp.product_id into v_pid from medicine_pricing mp where mp.ptr is not null limit 1;
  -- A phone is a unique login identity (_login_identities_sync), so the
  -- fixture must never reuse one a PERMANENT row already holds — including
  -- the seeded test agency. Four numbers off one random stem, inside a
  -- transaction that is rolled back either way.
  v_ph := '9' || lpad((floor(random() * 100000000))::bigint::text, 8, '0');
  if v_cust is null or v_pid is null then
    raise exception 'RG_FAIL: no synthetic pharmacy / priced product fixture — CHANGE #704 proofs cannot run';
  end if;

  insert into delivery_partner_registrations(full_name, phone, partner_type, zone_id, is_active,
      status, is_synthetic, user_id, training_override_at, submitted_at)
  values ('C704 Agency', left(v_ph,9)||'0', 'agency', 99, true, 'approved', true, v_uid, now(), now())
  returning id into v_ag;

  insert into delivery_partner_registrations(full_name, phone, partner_type, parent_agency_id,
      zone_id, is_active, status, is_synthetic, max_stops, training_override_at, submitted_at)
  values ('C704 Agency Rider One', left(v_ph,9)||'1', 'boy', v_ag, 99, true, 'approved', true, 5, now(), now())
  returning id into v_r1;

  insert into delivery_partner_registrations(full_name, phone, partner_type, parent_agency_id,
      zone_id, is_active, status, is_synthetic, max_stops, training_override_at, submitted_at)
  values ('C704 Agency Rider Two', left(v_ph,9)||'2', 'boy', v_ag, 99, true, 'approved', true, 5, now(), now())
  returning id into v_r2;

  insert into delivery_partner_registrations(full_name, phone, partner_type, zone_id, is_active,
      status, is_synthetic, max_stops, training_override_at, submitted_at)
  values ('C704 Solo Rider', left(v_ph,9)||'3', 'boy', 99, true, 'approved', true, 5, now(), now())
  returning id into v_solo;

  -- Both agency riders are punched in, so the agency has pooled spare capacity.
  insert into delivery_partner_shifts(partner_id, shift_date, started_at)
  values (v_r1, (now() at time zone 'Asia/Kolkata')::date, now()),
         (v_r2, (now() at time zone 'Asia/Kolkata')::date, now());

  insert into orders(customer_id, order_code, status, dispatch_ready, cust_bill_path,
                     zone_id, is_synthetic, placed_by_admin)
  values (v_cust, 'C704FIXTURE', 'confirmed', true, 'test/bill.pdf', 99, true, true)
  returning id into v_oid;
  insert into order_items(order_id, product_id, product_name, quantity, mrp,
                          assigned_supplier, fulfillment_state, zone_id, bag_no)
  values (v_oid, v_pid, 'C704 fixture line', 1, 10, 'C704 SUPPLIER', 'pending', 99, 1);
  insert into payment_claims(order_id, amount, status) values (v_oid, 100000, 'verified');

  return jsonb_build_object('agency', v_ag, 'rider1', v_r1, 'rider2', v_r2,
                            'solo', v_solo, 'order_id', v_oid, 'agency_user', v_uid);
end $fn$;

insert into public.rg_behavior_tests(name, body, enabled, note) values
('c704_agency_assign_dispatch_deliver', $body704a$
do $rg$
declare f jsonb; v_res jsonb; d deliveries%rowtype; v_did uuid; v_run uuid;
begin
  f := public._c704_fixture();

  -- 1. mediBO assigns the ORDER to the AGENCY.
  v_res := public._delivery_assign_core(array[(f->>'order_id')::uuid],
                                        (f->>'agency')::uuid, 'rg', null);
  if coalesce((v_res->>'ok')::boolean,false) is not true or (v_res->>'assigned')::int <> 1 then
    raise exception 'RG_FAIL: delivery_assign refused an AGENCY target (%) — spec 1 says an agency id is a legal assignment target (CHANGE #704)', v_res::text;
  end if;
  select * into d from deliveries where order_id = (f->>'order_id')::uuid;
  if d.status <> 'agency_pending' or d.partner_id is not null
     or d.agency_id is distinct from (f->>'agency')::uuid then
    raise exception 'RG_FAIL: an agency assignment must land as agency_id set / partner_id NULL / status agency_pending, got status=% partner=% agency=% (CHANGE #704 spec 1)',
      d.status, coalesce(d.partner_id::text,'null'), coalesce(d.agency_id::text,'null');
  end if;
  if d.agency_due_at is null or d.agency_due_at <= now() then
    raise exception 'RG_FAIL: no response deadline was stamped on the agency stop — the SLA tick would never fire (CHANGE #704 spec 3)';
  end if;
  v_did := d.id;

  -- 2. The agency dispatcher, signed in as itself, picks one of ITS riders.
  perform set_config('request.jwt.claims',
    json_build_object('sub', f->>'agency_user', 'role','authenticated')::text, true);
  v_res := public.agency_dispatch_assign(v_did, (f->>'rider1')::uuid, null);
  if coalesce((v_res->>'ok')::boolean,false) is not true then
    raise exception 'RG_FAIL: the agency could not give its own stop to its own rider: % (CHANGE #704 spec 2)', v_res::text;
  end if;
  select * into d from deliveries where id = v_did;
  if d.status <> 'assigned' or d.partner_id is distinct from (f->>'rider1')::uuid
     or d.run_id is null or d.accept_status <> 'pending' then
    raise exception 'RG_FAIL: after the agency picked a rider the stop must be an ORDINARY assigned stop on that rider''s run (status=% partner=% run=% accept=%) — the rider then follows the unchanged accept/run/track flow (CHANGE #704 spec 2)',
      d.status, coalesce(d.partner_id::text,'null'), coalesce(d.run_id::text,'null'), d.accept_status;
  end if;
  v_run := d.run_id;

  -- 3. A rider outside the agency is refused, so an agency cannot dispatch
  --    work to somebody else's rider.
  v_res := public.agency_dispatch_assign(v_did, (f->>'solo')::uuid, null);
  if coalesce((v_res->>'ok')::boolean,true) is not false
     or v_res->>'error' <> 'rider_not_yours' then
    raise exception 'RG_FAIL: an agency was allowed to dispatch to a rider that is not on its team (%) (CHANGE #704 spec 2)', v_res::text;
  end if;

  -- 4. Reassign mid-way, inside the agency, with no mediBO involvement. Custody
  --    is personal, so the handover must be cleared for the new rider.
  update deliveries set status='out_for_delivery', accept_status='accepted',
         handover_at = now(), handover_to = (f->>'rider1')::uuid,
         handover_by_name = 'C704' where id = v_did;
  v_res := public.agency_dispatch_assign(v_did, (f->>'rider2')::uuid, null);
  select * into d from deliveries where id = v_did;
  if coalesce((v_res->>'ok')::boolean,false) is not true
     or d.partner_id is distinct from (f->>'rider2')::uuid then
    raise exception 'RG_FAIL: the agency could not move a running stop to another of its riders (% / partner=%) (CHANGE #704 spec 2)',
      v_res::text, coalesce(d.partner_id::text,'null');
  end if;
  if d.handover_at is not null or d.handover_to is not null then
    raise exception 'RG_FAIL: an agency reassignment left the previous rider''s handover in place — rider B would inherit rider A''s custody alibi (CHANGE #309 / #704 spec 2)';
  end if;
  if d.run_id = v_run then
    raise exception 'RG_FAIL: the reassigned stop stayed on the FIRST rider''s run (CHANGE #704 spec 2)';
  end if;
  if not exists (select 1 from delivery_events e
                  where e.delivery_id = v_did and e.event = 'agency_reassigned') then
    raise exception 'RG_FAIL: an agency reassignment was not recorded as an event, so the chain has no history (CHANGE #704 spec 2)';
  end if;

  -- 5. Delivered: the earning stamps on the RIDER, exactly as before, and the
  --    agency link is still there for the invoice roll-up (spec 4).
  update delivery_partner_registrations set per_drop_rate = 25 where id = (f->>'rider2')::uuid;
  update deliveries set status = 'delivered', delivered_at = now() where id = v_did;
  select * into d from deliveries where id = v_did;
  if coalesce(d.earning,0) <= 0 then
    raise exception 'RG_FAIL: a delivery completed through an agency did not stamp the rider''s earning — the agency invoice rolls up from rider earnings (CHANGE #704 spec 4)';
  end if;
  if d.partner_id is distinct from (f->>'rider2')::uuid or d.agency_id is null then
    raise exception 'RG_FAIL: the delivered stop lost its agency -> rider chain (partner=% agency=%) (CHANGE #704 spec 4/5)',
      coalesce(d.partner_id::text,'null'), coalesce(d.agency_id::text,'null');
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body704a$, true,
 'CHANGE #704 spec 2 + 4: assign to an agency, the agency dispatcher picks its own rider, reassigns mid-run, delivers, and the earning still stamps on the rider.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

insert into public.rg_behavior_tests(name, body, enabled, note) values
('c704_agency_timeout_falls_back', $body704b$
do $rg$
declare f jsonb; v_res jsonb; d deliveries%rowtype; v_did uuid; v_n int;
begin
  f := public._c704_fixture();
  perform public._delivery_assign_core(array[(f->>'order_id')::uuid],
                                       (f->>'agency')::uuid, 'rg', null);
  select * into d from deliveries where order_id = (f->>'order_id')::uuid;
  v_did := d.id;

  -- The deadline passes with the agency having named nobody.
  update deliveries set agency_due_at = now() - interval '1 minute' where id = v_did;
  v_res := public.delivery_agency_sla_tick();

  select * into d from deliveries where id = v_did;
  if d.agency_timeout_at is null then
    raise exception 'RG_FAIL: the agency response deadline passed and nothing was recorded — agency_timeout_at is still NULL (CHANGE #704 spec 3)';
  end if;
  if d.partner_id is null or d.status <> 'assigned' then
    raise exception 'RG_FAIL: an agency that missed its deadline kept the stop (status=% partner=%) — it must fall back to mediBO''s own suggestion (CHANGE #704 spec 3)',
      d.status, coalesce(d.partner_id::text,'null');
  end if;
  if exists (select 1 from delivery_partner_registrations r
              where r.id = d.partner_id and r.parent_agency_id = (f->>'agency')::uuid) then
    raise exception 'RG_FAIL: the timeout handed the stop straight back to a rider of the SAME agency — the fallback is mediBO''s best INDIVIDUAL rider (CHANGE #704 spec 3)';
  end if;
  if d.agency_id is distinct from (f->>'agency')::uuid then
    raise exception 'RG_FAIL: the fallback erased the agency link, so the timeout can no longer be attributed to anyone (CHANGE #704 spec 3)';
  end if;

  if not exists (select 1 from delivery_events e
                  where e.delivery_id = v_did and e.event = 'agency_timeout') then
    raise exception 'RG_FAIL: no agency_timeout event was logged (CHANGE #704 spec 3)';
  end if;

  -- The agency's scorecard.
  select count(*) into v_n from exception_scorecard_input i
   where i.subject_kind = 'agency' and i.subject_key = (f->>'agency')
     and i.reason_code = 'agency_timeout';
  if v_n <> 1 then
    raise exception 'RG_FAIL: the timeout did not feed the agency scorecard (% rows) (CHANGE #704 spec 3)', v_n;
  end if;

  -- The exceptions console (#690).
  select count(*) into v_n from public._exception_rows() r
   where r.reason_code = 'agency_timeout' and r.ref_id = v_did::text;
  if v_n <> 1 then
    raise exception 'RG_FAIL: the timed-out stop is not on the exceptions console (% rows) (CHANGE #704 spec 3 / #690)', v_n;
  end if;

  -- ...and it clears itself the moment the stop completes: nobody closes it by hand.
  update deliveries set status = 'delivered', delivered_at = now() where id = v_did;
  select count(*) into v_n from public._exception_rows() r
   where r.reason_code = 'agency_timeout' and r.ref_id = v_did::text;
  if v_n <> 0 then
    raise exception 'RG_FAIL: a delivered stop is still sitting on the exceptions console as an agency timeout (CHANGE #704 spec 3)';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body704b$, true,
 'CHANGE #704 spec 3: an agency past its response deadline loses the stop to mediBO''s best individual rider, and the miss lands on the scorecard and the exceptions console.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

insert into public.rg_behavior_tests(name, body, enabled, note) values
('c704_agency_is_a_candidate', $body704c$
do $rg$
declare f jsonb; v_kind text; v_spare int; v_n int; v_sug jsonb;
begin
  f := public._c704_fixture();

  -- The agency is in the pool, and its pooled spare is the SUM of its riders'
  -- spare capacity (two riders, max_stops 5, nothing in hand = 10).
  select t.kind, t.spare into v_kind, v_spare
    from public._delivery_targets(99::smallint, null, 'open') t
   where t.target_id = (f->>'agency')::uuid;
  if v_kind is distinct from 'agency' then
    raise exception 'RG_FAIL: an agency with free riders is not offered as an assignment target at all (CHANGE #704 spec 1)';
  end if;
  if v_spare <> 10 then
    raise exception 'RG_FAIL: agency capacity must be the sum of its on-shift riders'' spare capacity — expected 10, got % (CHANGE #704 spec 1)', v_spare;
  end if;

  -- Its riders are reachable THROUGH it, never as a second mediBO-direct
  -- candidate, so the same person is never counted twice in one pool.
  select count(*) into v_n from public._delivery_targets(99::smallint, null, 'open') t
   where t.target_id in ((f->>'rider1')::uuid, (f->>'rider2')::uuid);
  if v_n <> 0 then
    raise exception 'RG_FAIL: an agency''s riders appear as mediBO-direct candidates as well as inside their agency — the zone''s capacity is double counted (% rows) (CHANGE #704 spec 1)', v_n;
  end if;

  -- Wave planning reads the same pool, so an agency can win a wave stop.
  select count(*) into v_n from public._wave_targets(99::smallint) w
   where w.partner_id = (f->>'agency')::uuid and w.kind = 'agency';
  if v_n <> 1 then
    raise exception 'RG_FAIL: wave planning cannot see the agency (% rows) — spec 1 says wave planning may return an agency (CHANGE #704)', v_n;
  end if;

  -- The single-stop suggestion says which KIND it picked, verbatim.
  v_sug := public.delivery_suggest_partner((f->>'order_id')::uuid);
  if coalesce(v_sug->>'kind','') not in ('rider','agency') then
    raise exception 'RG_FAIL: delivery_suggest_partner no longer says whether it picked a rider or an agency (%) (CHANGE #704 spec 1)', v_sug::text;
  end if;

  -- Fill both riders to capacity: the agency leaves the pool, because a zone
  -- rule that offers a full team is how a stop gets stranded.
  insert into delivery_runs(partner_id, run_date, status)
  values ((f->>'rider1')::uuid, (now() at time zone 'Asia/Kolkata')::date, 'started');
  update delivery_partner_registrations set max_stops = 0
   where parent_agency_id = (f->>'agency')::uuid;
  select count(*) into v_n from public._delivery_targets(99::smallint, null, 'open') t
   where t.target_id = (f->>'agency')::uuid;
  if v_n <> 0 then
    raise exception 'RG_FAIL: an agency whose riders have no spare capacity is still being offered work (CHANGE #704 spec 1)';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body704c$, true,
 'CHANGE #704 spec 1: an agency is an assignment target whose capacity is its riders'' pooled spare, its riders are not double-counted, and wave planning sees it too.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

insert into public.rg_behavior_tests(name, body, enabled, note) values
('c704_agency_chain_is_visible', $body704d$
do $rg$
declare f jsonb; v_did uuid; v_admin uuid; v_track jsonb; v_q jsonb; v_row jsonb;
begin
  f := public._c704_fixture();
  perform public._delivery_assign_core(array[(f->>'order_id')::uuid],
                                       (f->>'agency')::uuid, 'rg', null);
  select id into v_did from deliveries where order_id = (f->>'order_id')::uuid;
  select u.id into v_admin from auth.users u join admins a
    on lower(btrim(a.email)) = lower(btrim(u.email)) where coalesce(a.is_super,false) limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role','authenticated')::text, true);

  -- Before a rider is picked the buyer is told exactly that — never a blank.
  v_track := public.customer_track_order((f->>'order_id')::uuid);
  if coalesce(v_track->'assigned_to'->>'kind','') <> 'agency' then
    raise exception 'RG_FAIL: while the agency is still choosing, the buyer''s tracker does not say the order is with an agency (%) (CHANGE #704 spec 5)',
      coalesce(v_track->'assigned_to'->>'kind','<absent>');
  end if;
  if coalesce(v_track->>'status_label','') <> public._c('agency.track_pending') then
    raise exception 'RG_FAIL: the tracker''s agency wording is not the backend''s own copy (got %) (CHANGE #704 spec 5)',
      coalesce(v_track->>'status_label','<empty>');
  end if;

  -- The admin queue shows the chain and still offers the override button.
  v_q := public.admin_delivery_queue(
           (now() at time zone 'Asia/Kolkata')::date, 99::smallint);
  select e into v_row from jsonb_array_elements(v_q->'orders') e
   where e->>'order_id' = (f->>'order_id');
  if v_row is null or coalesce(v_row->'delivery'->>'is_agency','') <> 'true' then
    raise exception 'RG_FAIL: the admin delivery queue does not show that this stop sits with an agency (CHANGE #704 spec 5)';
  end if;
  if position('C704 Agency' in coalesce(v_row->'delivery'->>'chain_label','')) = 0 then
    raise exception 'RG_FAIL: the admin queue''s chain label does not name the agency (got %) (CHANGE #704 spec 5)',
      coalesce(v_row->'delivery'->>'chain_label','<empty>');
  end if;
  if not exists (select 1 from jsonb_array_elements(v_row->'delivery'->'actions') a
                  where a->>'key' = 'reassign') then
    raise exception 'RG_FAIL: an admin cannot override an agency stop — the Reassign action is absent (CHANGE #704 spec 5)';
  end if;

  -- Once a rider is picked the tracker names the RIDER.
  perform public.agency_dispatch_assign(v_did, (f->>'rider1')::uuid, (f->>'agency')::uuid);
  v_track := public.customer_track_order((f->>'order_id')::uuid);
  if coalesce(v_track->'assigned_to'->>'kind','') <> 'rider'
     or coalesce(v_track->'assigned_to'->>'name','') <> 'C704 Agency Rider One' then
    raise exception 'RG_FAIL: after the agency picked a rider the buyer still does not see the rider (%) (CHANGE #704 spec 5)',
      coalesce(v_track->'assigned_to'::text,'<absent>');
  end if;

  -- The dispatch board renders the same chain for the agency itself.
  v_q := public.agency_dispatch_board((f->>'agency')::uuid);
  if coalesce((v_q->>'ok')::boolean,false) is not true
     or jsonb_array_length(v_q->'running') <> 1 then
    raise exception 'RG_FAIL: the agency dispatch board does not show the stop it just dispatched (%) (CHANGE #704 spec 2)', v_q::text;
  end if;
  if jsonb_array_length(v_q->'riders') <> 2 then
    raise exception 'RG_FAIL: the dispatch board must offer the agency''s own riders (% found) (CHANGE #704 spec 2)',
      jsonb_array_length(v_q->'riders');
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body704d$, true,
 'CHANGE #704 spec 5: the buyer sees "agency assigned" then the rider, and the admin queue shows the agency -> rider chain with the override still available.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

insert into public.rg_behavior_tests(name, body, enabled, note) values
('c704_wave_can_pick_an_agency', $body704e$
do $rg$
declare f jsonb; v_w uuid; v_pick uuid; v_kind text; d deliveries%rowtype;
begin
  f := public._c704_fixture();

  insert into delivery_wave(zone_id, window_key, wave_date, status, mode)
  values (99, 'c704_rg', (now() at time zone 'Asia/Kolkata')::date, 'planned', 'manual')
  returning id into v_w;
  insert into delivery_wave_stop(wave_id, order_id, status)
  values (v_w, (f->>'order_id')::uuid, 'planned');

  perform public.delivery_wave_plan(v_w, 'rg');
  select partner_id into v_pick from delivery_wave_stop where wave_id = v_w;
  if v_pick is null then
    raise exception 'RG_FAIL: wave planning held the stop although an agency with free riders was on shift in this zone (CHANGE #704 spec 1 / spec 6)';
  end if;
  select partner_type into v_kind from delivery_partner_registrations where id = v_pick;
  if v_kind is distinct from 'agency' then
    raise exception 'RG_FAIL: wave planning picked % instead of the agency, which is the only target in this zone with spare capacity (CHANGE #704 spec 1)', coalesce(v_kind,'nobody');
  end if;

  -- Dispatch is unchanged: it hands delivery_wave_stop.partner_id to
  -- _delivery_assign_core, which recognises an agency and produces an
  -- agency_pending stop the dispatcher can act on.
  perform public.delivery_wave_dispatch(v_w, 'rg');
  select * into d from deliveries where order_id = (f->>'order_id')::uuid;
  if d.status <> 'agency_pending' or d.agency_id is distinct from v_pick
     or d.partner_id is not null then
    raise exception 'RG_FAIL: a wave stop given to an agency did not land as an agency stop (status=% agency=% partner=%) (CHANGE #704 spec 1 / spec 6)',
      coalesce(d.status,'<none>'), coalesce(d.agency_id::text,'null'), coalesce(d.partner_id::text,'null');
  end if;
  if d.agency_due_at is null then
    raise exception 'RG_FAIL: a wave-dispatched agency stop carries no response deadline, so the SLA tick would never reclaim it (CHANGE #704 spec 3)';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body704e$, true,
 'CHANGE #704 spec 1 + spec 6: wave planning can give a stop to an agency, and wave dispatch turns that into an agency_pending stop with a response deadline.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;
