-- CHANGE #405 (B) — the engine. Waves, balanced auto-assignment, rejection
-- reallocation. Every rule delivery_assign() already enforces is REUSED here,
-- not re-implemented: the file's first act is to split delivery_assign() into
-- an authorisation shell and a rules core, so there is exactly ONE body of
-- assignment rules on this platform and the engine calls it.

-- ── 0. One body of rules, two doors ─────────────────────────────────────────
-- The core is everything delivery_assign() used to do BELOW its role check:
-- the active-partner test, the document-expiry block (#309), the zone boundary,
-- delivery_eligibility(), the deliveries upsert that resets accept_status to
-- 'pending' (the accept/reject flow), the delivery_events row and the run stop
-- count. The engine runs inside the cron dispatcher where auth.uid() is null,
-- so it cannot pass through an admin role check — but it must not be allowed to
-- skip a single rule either. Splitting the function is how both stay true.
create or replace function public._delivery_assign_core(
  p_order_ids uuid[], p_partner_id uuid, p_actor text default 'engine',
  p_wave_id uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  r record; v_ok int := 0; v_blocked jsonb := '[]'::jsonb; v_elig jsonb;
  v_partner delivery_partner_registrations%rowtype; v_run uuid; v_did uuid;
  v_ozone smallint; v_docs jsonb;
begin
  select * into v_partner from delivery_partner_registrations
   where id = p_partner_id and is_active and coalesce(is_deleted,false)=false;
  if v_partner.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message','That delivery partner is not active.');
  end if;

  -- CHANGE #309 (6): an expired licence, insurance or RC blocks assignment.
  v_docs := public.delivery_doc_state(p_partner_id);
  if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','docs_expired',
      'title',   v_docs->>'block_title',
      'message', v_docs->>'block_message',
      'docs',    v_docs->'docs');
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

  for r in select unnest(p_order_ids) as oid loop
    select coalesce(o.zone_id, pp.zone_id) into v_ozone
    from orders o left join pharmacy_profiles pp on pp.id=o.customer_id where o.id = r.oid;

    -- a delivery may never cross a zone boundary
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

    insert into deliveries(order_id, run_id, partner_id, assigned_by, assigned_at,
                           accept_status, status, qr_token, lat, lng, zone_id, wave_id)
    select r.oid, v_run, p_partner_id, auth.uid(), now(), 'pending', 'assigned',
           encode(gen_random_bytes(9),'hex'), pp.latitude, pp.longitude, v_ozone,
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
    v_ok := v_ok + 1;
  end loop;

  update delivery_runs set total_stops =
    (select count(distinct coalesce(stop_group, 0)) from deliveries where run_id = v_run)
   where id = v_run;

  return jsonb_build_object('ok', true, 'assigned', v_ok, 'run_id', v_run,
    'delivery_id', v_did,
    'partner_name', coalesce(v_partner.full_name,''),
    'blocked', v_blocked,
    'title', 'Assigned ' || v_ok || case when v_ok = 1 then ' order' else ' orders' end);
end $function$;

-- The public door keeps its exact signature and its exact behaviour: the role
-- check, then the same rules. Nothing that calls delivery_assign() today can
-- tell that the body moved.
create or replace function public.delivery_assign(p_order_ids uuid[], p_partner_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if public.partner_scope_orders(p_order_ids, 'partner.assign_delivery', 'write')
     not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  return public._delivery_assign_core(p_order_ids, p_partner_id,
           coalesce(auth.jwt() ->> 'email','admin'), null);
end $function$;

-- ── 1. Who can take a stop in this zone, right now ──────────────────────────
-- On-shift is an OPEN row in delivery_partner_shifts. A rider whose documents
-- have expired is not offered work at all — the core would refuse the stop a
-- moment later, and planning around a rider who cannot be assigned is how a
-- balanced-looking plan turns into an empty run.
create or replace function public._wave_riders(p_zone_id smallint)
returns table(partner_id uuid, name text, open_stops integer, capacity integer)
language sql stable security definer set search_path to 'public'
as $$
  select p.id, coalesce(p.full_name,''),
         (select count(*)::int from deliveries d
           where d.partner_id = p.id
             and d.status in ('assigned','out_for_delivery')),
         coalesce(p.max_stops, (select c.max_per_rider
                                  from delivery_wave_zone_config c
                                 where c.zone_id = p_zone_id))
    from delivery_partner_registrations p
   where p.is_active
     and coalesce(p.is_deleted,false) = false
     and coalesce(p.zone_id, p_zone_id) = p_zone_id
     and exists (select 1 from delivery_partner_shifts s
                  where s.partner_id = p.id and s.ended_at is null)
     and coalesce((public.delivery_doc_state(p.id) ->> 'blocks_assignment')::boolean, false)
         = false
   order by 3, 2;
$$;

-- ── 2. Log one decision ─────────────────────────────────────────────────────
create or replace function public._wave_log(
  p_wave uuid, p_stop uuid, p_order uuid, p_partner uuid, p_delivery uuid,
  p_decision text, p_reason text, p_meta jsonb default '{}'::jsonb,
  p_actor text default 'engine')
returns void
language sql security definer set search_path to 'public'
as $$
  insert into delivery_wave_decision(wave_id, stop_id, order_id, partner_id,
    delivery_id, decision, reason, meta, actor)
  values (p_wave, p_stop, p_order, p_partner, p_delivery, p_decision,
          coalesce(p_reason,''), coalesce(p_meta,'{}'::jsonb), coalesce(p_actor,'engine'));
$$;

-- ── 3. Cut a wave (spec 1) ──────────────────────────────────────────────────
-- Collects the packed, eligible orders of one zone into one wave. An order that
-- is packed but NOT eligible is still recorded, as a blocked stop carrying
-- delivery_eligibility()'s own blocked_label — a block that is invisible is a
-- block nobody fixes.
create or replace function public.delivery_wave_cut(
  p_zone_id smallint, p_window_key text default 'manual',
  p_date date default null, p_actor text default 'engine')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_cfg delivery_wave_zone_config%rowtype;
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  v_wave uuid; v_label text; v_win jsonb; v_mode text;
  o record; v_elig jsonb; v_stop uuid; v_n int := 0; v_blocked int := 0;
begin
  select * into v_cfg from delivery_wave_zone_config where zone_id = p_zone_id;
  if v_cfg.zone_id is null then
    return jsonb_build_object('ok',false,'error','zone_not_configured',
      'message','This zone has no wave configuration yet.');
  end if;
  if not v_cfg.enabled then
    return jsonb_build_object('ok',false,'error','waves_disabled',
      'message','Wave planning is switched off for this zone.');
  end if;

  v_mode := v_cfg.mode;
  -- MANUAL is today's behaviour: the admin assigns from the queue and the
  -- engine stays out of the way. It is recorded, not silently skipped.
  if v_mode = 'manual' then
    perform public._wave_log(null, null, null, null, null, 'mode_manual_skip',
      'Zone is on manual — no wave was cut. Assignment stays with the admin queue.',
      jsonb_build_object('zone_id', p_zone_id, 'window', p_window_key), p_actor);
    return jsonb_build_object('ok',true,'skipped',true,'mode','manual',
      'message','This zone is on manual — no wave was cut.');
  end if;

  select w into v_win from jsonb_array_elements(v_cfg.windows) w
   where w->>'key' = p_window_key limit 1;
  v_label := coalesce(v_win->>'label',
                      case when p_window_key = 'manual' then 'Manual wave'
                           else p_window_key end);

  insert into delivery_wave(zone_id, wave_date, window_key, window_label,
                            cutoff_at, status, mode, cut_reason, created_by)
  values (p_zone_id, v_date, p_window_key, v_label, now(), 'planned', v_mode,
          case when p_actor = 'engine'
               then 'Cut automatically at the ' || v_label || ' cut-off'
               else 'Cut by hand' end,
          p_actor)
  on conflict (zone_id, wave_date, window_key) do nothing
  returning id into v_wave;

  if v_wave is null then
    select id into v_wave from delivery_wave
     where zone_id = p_zone_id and wave_date = v_date and window_key = p_window_key;
    -- A wave already cut for this slot is topped up, never duplicated.
    if (select status from delivery_wave where id = v_wave)
       in ('dispatched','closed','cancelled') then
      return jsonb_build_object('ok',true,'wave_id',v_wave,'already',true,
        'message','That wave is already out with the riders.');
    end if;
  else
    perform public._wave_log(v_wave, null, null, null, null, 'wave_cut',
      'Wave cut for ' || v_label || ' — collecting packed orders in this zone.',
      jsonb_build_object('zone_id', p_zone_id, 'mode', v_mode), p_actor);
  end if;

  -- Packed orders of this zone that are not already out with a rider.
  for o in
    select o2.id as oid
      from orders o2
      left join pharmacy_profiles pp on pp.id = o2.customer_id
     where coalesce(o2.dispatch_ready,false) = true
       and coalesce(o2.zone_id, pp.zone_id) = p_zone_id
       and not exists (select 1 from deliveries d
                        where d.order_id = o2.id
                          and d.status in ('assigned','out_for_delivery','delivered'))
       and not exists (select 1 from delivery_wave_stop s
                        join delivery_wave w on w.id = s.wave_id
                       where s.order_id = o2.id
                         and s.status in ('planned','assigned','held')
                         and w.status <> 'cancelled')
     order by o2.created_at
  loop
    v_elig := public.delivery_eligibility(o.oid);
    insert into delivery_wave_stop(wave_id, order_id, status, reason)
    values (v_wave, o.oid,
            case when coalesce((v_elig->>'can_assign')::boolean,false)
                 then 'planned' else 'blocked' end,
            coalesce(v_elig->>'blocked_label',''))
    on conflict (wave_id, order_id) do nothing
    returning id into v_stop;

    if v_stop is null then continue; end if;

    if coalesce((v_elig->>'can_assign')::boolean,false) then
      v_n := v_n + 1;
    else
      v_blocked := v_blocked + 1;
      perform public._wave_log(v_wave, v_stop, o.oid, null, null, 'stop_blocked',
        v_elig->>'blocked_label',
        jsonb_build_object('blockers', v_elig->'blockers'), p_actor);
    end if;
  end loop;

  update delivery_wave
     set stop_count = (select count(*) from delivery_wave_stop
                        where wave_id = v_wave and status in ('planned','assigned')),
         blocked_count = (select count(*) from delivery_wave_stop
                           where wave_id = v_wave and status = 'blocked')
   where id = v_wave;

  return public.delivery_wave_plan(v_wave, p_actor);
end $function$;

-- ── 4. Plan the wave — balanced distribution (spec 2) ───────────────────────
-- Round-robin by CURRENT LOAD: each stop goes to the rider with the fewest
-- open stops, counting what this same plan has already given them. Capacity and
-- the rider's own rejection history are honoured, and a stop nobody can take is
-- left in the wave with the reason written down rather than dropped.
create or replace function public.delivery_wave_plan(
  p_wave_id uuid, p_actor text default 'engine')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
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
  select count(*)::int into v_riders from public._wave_riders(w.zone_id);
  select coalesce(jsonb_object_agg(partner_id::text, open_stops), '{}'::jsonb)
    into v_load_map from public._wave_riders(w.zone_id);

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
      from public._wave_riders(w.zone_id) r
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
end $function$;

-- ── 5. Dispatch — the plan becomes real deliveries ──────────────────────────
-- Every stop goes through _delivery_assign_core(), so the doc block, the zone
-- boundary, eligibility and the pending accept_status all apply exactly as they
-- do when an admin taps Assign. A stop the core refuses is recorded as blocked
-- WITH THE CORE'S OWN SENTENCE and stays in the wave.
create or replace function public.delivery_wave_dispatch(
  p_wave_id uuid, p_actor text default 'engine')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  w delivery_wave%rowtype; s record; res jsonb; v_did uuid; v_ok int := 0; v_bad int := 0;
  v_reason text;
begin
  select * into w from delivery_wave where id = p_wave_id;
  if w.id is null then return jsonb_build_object('ok',false,'error','wave_not_found'); end if;
  if w.status in ('dispatched','closed','cancelled') then
    return jsonb_build_object('ok',false,'error','wave_closed',
      'message','That wave is already out with the riders.');
  end if;

  for s in
    select * from delivery_wave_stop
     where wave_id = w.id and status = 'planned' and partner_id is not null
     order by created_at
  loop
    res := public._delivery_assign_core(array[s.order_id], s.partner_id, p_actor, w.id);

    if coalesce((res->>'assigned')::int, 0) > 0 then
      select id into v_did from deliveries where order_id = s.order_id;
      update delivery_wave_stop
         set status = 'assigned', delivery_id = v_did, assigned_at = now()
       where id = s.id;
      v_ok := v_ok + 1;
      perform public._wave_log(w.id, s.id, s.order_id, s.partner_id, v_did,
        'stop_assigned',
        'Assigned to ' || coalesce(res->>'partner_name','the rider') ||
        ' — waiting for them to accept.', '{}'::jsonb, p_actor);
    else
      v_reason := coalesce(res->'blocked'->0->>'reason', res->>'message',
                           res->>'error', 'Assignment refused');
      update delivery_wave_stop
         set status = 'blocked', reason = v_reason, partner_id = null
       where id = s.id;
      v_bad := v_bad + 1;
      perform public._wave_log(w.id, s.id, s.order_id, s.partner_id, null,
        'stop_blocked', v_reason, res, p_actor);
    end if;
  end loop;

  update delivery_wave
     set status = 'dispatched', dispatched_at = now(),
         stop_count = (select count(*) from delivery_wave_stop
                        where wave_id = w.id and status in ('assigned','planned','held')),
         blocked_count = (select count(*) from delivery_wave_stop
                           where wave_id = w.id and status = 'blocked'),
         rider_count = (select count(distinct partner_id) from delivery_wave_stop
                         where wave_id = w.id and status = 'assigned')
   where id = w.id;

  perform public._wave_log(w.id, null, null, null, null, 'wave_dispatched',
    v_ok || case when v_ok = 1 then ' stop' else ' stops' end || ' sent to riders' ||
    case when v_bad > 0 then ', ' || v_bad || ' held back' else '' end || '.',
    jsonb_build_object('assigned', v_ok, 'blocked', v_bad), p_actor);

  return public.delivery_wave_detail(w.id);
end $function$;

-- ── 6. A rejection returns the stop to the wave (spec 2) ────────────────────
-- delivery_respond() already flips the delivery to unassigned. This adds the
-- second half the spec asks for: the stop goes BACK into its wave, the rider
-- who refused is remembered so they are never offered it again, and the wave is
-- re-planned so somebody else picks it up.
create or replace function public.delivery_wave_reallocate(
  p_delivery_id uuid, p_partner_id uuid default null, p_reason text default null,
  p_actor text default 'engine')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare s delivery_wave_stop%rowtype; w delivery_wave%rowtype;
begin
  select * into s from delivery_wave_stop where delivery_id = p_delivery_id
   order by created_at desc limit 1;
  if s.id is null then
    return jsonb_build_object('ok',true,'wave',false,
      'message','That delivery did not come from a wave.');
  end if;
  select * into w from delivery_wave where id = s.wave_id;

  update delivery_wave_stop
     set status = 'planned',
         rejected_by = (select array_agg(distinct x) from unnest(
                          s.rejected_by || coalesce(p_partner_id, s.partner_id)) x
                        where x is not null),
         partner_id = null, delivery_id = null, released_at = now(),
         attempt_no = s.attempt_no + 1,
         reason = coalesce(nullif(btrim(coalesce(p_reason,'')),''),
                           'Rider passed — back in the wave for reallocation')
   where id = s.id;

  perform public._wave_log(w.id, s.id, s.order_id,
    coalesce(p_partner_id, s.partner_id), p_delivery_id, 'stop_rejected',
    'Rider passed' ||
    case when nullif(btrim(coalesce(p_reason,'')),'') is not null
         then ' — ' || p_reason else '' end ||
    '. Back in the wave for another rider.',
    jsonb_build_object('attempt', s.attempt_no + 1), p_actor);

  -- Re-plan so the stop is picked up now, not at the next cut-off. A wave that
  -- had already gone out re-opens just far enough to place this one stop.
  if w.status = 'dispatched' then
    update delivery_wave set status = 'approved' where id = w.id;
  end if;
  perform public.delivery_wave_plan(w.id, p_actor);

  if w.mode = 'auto' then
    perform public.delivery_wave_dispatch(w.id, p_actor);
  else
    update delivery_wave set status = 'proposed' where id = w.id
      and status not in ('dispatched','closed','cancelled');
  end if;

  return public.delivery_wave_detail(w.id);
end $function$;

-- The accept/reject flow itself is UNCHANGED — this only adds the wave hook to
-- the reject branch, after the update the flow already did.
create or replace function public.delivery_respond(
  p_delivery_id uuid, p_action text, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare d deliveries%rowtype; v_me uuid := auth.uid(); v_partner uuid; v_wave jsonb;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  select id into v_partner from delivery_partner_registrations
   where id = d.partner_id
     and (user_id = v_me
          or parent_agency_id in (select id from delivery_partner_registrations where user_id = v_me));
  if v_partner is null and get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  if lower(coalesce(p_action,'')) = 'accept' then
    update deliveries set accept_status='accepted', accepted_at=now(), status='assigned'
     where id = p_delivery_id;
    insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'accepted', coalesce(auth.jwt()->>'email','partner'));
    if d.wave_id is not null then
      perform public._wave_log(d.wave_id, null, d.order_id, d.partner_id, d.id,
        'stop_accepted', 'Rider accepted the stop.', '{}'::jsonb,
        coalesce(auth.jwt()->>'email','partner'));
    end if;
    return jsonb_build_object('ok',true,'accept_status','accepted','message','Delivery accepted');
  elsif lower(coalesce(p_action,'')) = 'reject' then
    update deliveries set accept_status='rejected', rejected_at=now(),
           reject_reason=nullif(btrim(coalesce(p_reason,'')),''),
           status='unassigned', partner_id=null, run_id=null
     where id = p_delivery_id;
    insert into delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'rejected', p_reason,
            coalesce(auth.jwt()->>'email','partner'));

    -- CHANGE #405 — a wave stop returns to its wave and is reallocated.
    if d.wave_id is not null then
      v_wave := public.delivery_wave_reallocate(p_delivery_id, d.partner_id, p_reason,
                  coalesce(auth.jwt()->>'email','partner'));
      return jsonb_build_object('ok',true,'accept_status','rejected',
        'message','Delivery rejected — back in the wave for another rider.',
        'wave', v_wave);
    end if;

    return jsonb_build_object('ok',true,'accept_status','rejected',
      'message','Delivery rejected — back in the admin queue');
  end if;
  return jsonb_build_object('ok',false,'error','bad_action');
end $function$;
