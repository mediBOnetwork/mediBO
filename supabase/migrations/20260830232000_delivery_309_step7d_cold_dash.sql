-- CHANGE #309 step 7d — cold-chain photo gate, cold-chain sequencing, dashboard rollup.

CREATE OR REPLACE FUNCTION public._delivery_complete(p_delivery_id uuid, p_method text, p_lat numeric, p_lng numeric, p_receiver text DEFAULT NULL::text, p_photo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- CHANGE #309 (10): a temperature-sensitive parcel needs a photo at the door.
  -- Enforced here, at the same choke point as the custody gate, so it covers
  -- QR, OTP, signature, partial and the offline replay path alike. A QR or OTP
  -- proof carries no photo, so for a cold-chain stop the rider must use the
  -- photo method — that is the point: the picture is the cold-chain record.
  if d.is_cold_chain
     and coalesce((public._dcfg(d.zone_id)->>'cold_chain_photo_required')::boolean, true)
     and nullif(btrim(coalesce(p_photo,'')),'') is null
     and nullif(btrim(coalesce(d.proof_photo_path,'')),'') is null then
    return jsonb_build_object('ok',false,'error','cold_chain_photo_required',
      'title',   public._c('delivery.cold_chain_badge'),
      'message', public._c('delivery.cold_chain_photo_required'));
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
end $function$

;

CREATE OR REPLACE FUNCTION public.delivery_optimize_run(p_run_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_seq int := 0; v_grp int := 0; r record; v_cur_lat numeric; v_cur_lng numeric; v_partner uuid;
begin
  select partner_id into v_partner from delivery_runs where id = p_run_id;
  if v_partner is null then return jsonb_build_object('ok',false,'error','run_not_found'); end if;

  select lat, lng into v_cur_lat, v_cur_lng
    from delivery_partner_locations where partner_id = v_partner;

  -- reset BOTH, or a re-optimise is a no-op
  update deliveries set stop_group = null, seq = null
   where run_id = p_run_id and status not in ('delivered','cancelled');

  for r in
    select id, lat, lng from deliveries
     where run_id = p_run_id and status not in ('delivered','cancelled')
     order by lat nulls last, lng
  loop
    if (select stop_group from deliveries where id = r.id) is not null then continue; end if;
    v_grp := v_grp + 1;
    update deliveries set stop_group = v_grp
     where run_id = p_run_id and stop_group is null
       and status not in ('delivered','cancelled')
       and (id = r.id
            or (r.lat is not null and lat is not null
                and public._geo_m(r.lat, r.lng, lat, lng) <= 150));
  end loop;

  if v_cur_lat is null then
    select lat, lng into v_cur_lat, v_cur_lng from deliveries
     where run_id = p_run_id and lat is not null limit 1;
  end if;

  loop
    select d.stop_group AS stop_group, min(d.lat) AS lat, min(d.lng) AS lng into r
    from deliveries d
    where d.run_id = p_run_id and d.seq is null and d.stop_group is not null
      and d.status not in ('delivered','cancelled')
    group by d.stop_group
    order by coalesce(public._geo_m(v_cur_lat, v_cur_lng, min(d.lat), min(d.lng)), 1e12), d.stop_group
    limit 1;
    exit when r.stop_group is null;
    v_seq := v_seq + 1;
    update deliveries set seq = v_seq where run_id = p_run_id and stop_group = r.stop_group;
    v_cur_lat := r.lat; v_cur_lng := r.lng;
  end loop;

  -- CHANGE #309 (10): a temperature-sensitive parcel is delivered before an
  -- ambient one. Applied as a RE-RANK over the finished route rather than as a
  -- constraint inside the nearest-neighbour loop, so the cold stops keep the
  -- optimised order among themselves and so do the rest — three cold parcels
  -- across town are still routed sensibly, they just all go first.
  with ranked as (
    select d.stop_group,
           bool_or(d.is_cold_chain) cold,
           min(d.seq) cur_seq
      from deliveries d
     where d.run_id = p_run_id and d.seq is not null
       and d.status not in ('delivered','cancelled')
     group by d.stop_group),
  renum as (
    select stop_group,
           row_number() over (order by cold desc, cur_seq) new_seq
      from ranked)
  update deliveries d
     set seq = r.new_seq
    from renum r
   where d.run_id = p_run_id and d.stop_group = r.stop_group
     and d.status not in ('delivered','cancelled');

  update delivery_runs
     set optimized_at = now(),
         total_stops = (select count(distinct stop_group) from deliveries where run_id = p_run_id)
   where id = p_run_id;

  return jsonb_build_object('ok',true,'run_id',p_run_id,'stops',v_seq,'method','nearest_neighbour');
end $function$

;

-- CHANGE #309 — admin_delivery_dashboard grows the four numbers the ten new
-- features exist to produce: on-time vs late (2), delivery margin (3), the
-- rider's customer rating (7), and how many parcels are still uncollected (1).
--
-- Rebuilt from the live definition with additions only: every existing key
-- (tiles, riders[], success_rate, fail_reasons) is still emitted with the same
-- name and the same meaning, so the current admin screen keeps working while
-- the new screen reads the new keys.
create or replace function public.admin_delivery_dashboard(
  p_date date default null, p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_date date; v_zone smallint; v_tiles jsonb; v_riders jsonb; v_zname text;
        v_sla jsonb; v_money jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed',false);
  end if;
  v_date := public.scope_date(p_date);
  v_zone := public.scope_zone(p_zone);
  select name into v_zname from zones where id = v_zone;

  select jsonb_build_object(
    'assigned',   count(*) filter (where d.status='assigned'),
    'out',        count(*) filter (where d.status='out_for_delivery'),
    'delivered',  count(*) filter (where d.status='delivered'),
    'failed',     count(*) filter (where d.status='failed'),
    'rto',        count(*) filter (where d.status='rto'),
    'unaccepted', count(*) filter (where d.accept_status='pending' and d.status='assigned'),
    -- CHANGE #309 (1): parcels a rider has accepted but not physically taken.
    'uncollected', count(*) filter (where d.handover_at is null
                                      and d.status in ('assigned','out_for_delivery')),
    'total',      count(*))
    into v_tiles
  from deliveries d join orders o on o.id=d.order_id
  where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
    and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone);

  -- CHANGE #309 (2): on-time performance, from the promise recorded at
  -- assignment. A stop with no promise is counted nowhere rather than counted
  -- as on time — scoring ourselves on stops we never made a promise about is
  -- how an SLA dashboard becomes a decoration.
  select jsonb_build_object(
    'on_time',      count(*) filter (where s.state = 'on_time'),
    'breached',     count(*) filter (where s.state = 'breached'),
    'in_flight',    count(*) filter (where s.state in ('pending','due_soon')),
    'measured',     count(*) filter (where s.state in ('on_time','breached')),
    'on_time_pct',  case when count(*) filter (where s.state in ('on_time','breached')) = 0 then null
                         else round(100.0 * count(*) filter (where s.state='on_time')
                              / count(*) filter (where s.state in ('on_time','breached'))) end,
    'on_time_label',case when count(*) filter (where s.state in ('on_time','breached')) = 0 then '—'
                         else round(100.0 * count(*) filter (where s.state='on_time')
                              / count(*) filter (where s.state in ('on_time','breached')))::text || '%' end,
    'title',        public._c('admin.delivery.sla_title'),
    'on_time_caption',  public._c('admin.delivery.sla_ontime'),
    'breached_caption', public._c('admin.delivery.sla_breached'),
    'pending_caption',  public._c('admin.delivery.sla_pending'))
    into v_sla
  from deliveries d
  join orders o on o.id = d.order_id
  cross join lateral (select public._sla_block(d) b) x
  cross join lateral (select (x.b->>'state') state) s
  where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
    and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone);

  -- CHANGE #309 (3): what delivery earned versus what it cost. Charge comes
  -- from the ORDER (what the customer paid), cost from the DELIVERY (what the
  -- drop cost us), so the margin is a real difference, not a re-quote.
  select jsonb_build_object(
    'charged',       coalesce(sum(coalesce(o.delivery_charge,0)),0),
    'charged_label', public.inr_money(coalesce(sum(coalesce(o.delivery_charge,0)),0)),
    'cost',          coalesce(sum(coalesce(d.cost_amount,0)),0),
    'cost_label',    public.inr_money(coalesce(sum(coalesce(d.cost_amount,0)),0)),
    'margin',        coalesce(sum(coalesce(o.delivery_charge,0) - coalesce(d.cost_amount,0)),0),
    'margin_label',  public.inr_money(coalesce(sum(coalesce(o.delivery_charge,0) - coalesce(d.cost_amount,0)),0)))
    into v_money
  from deliveries d join orders o on o.id=d.order_id
  where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
    and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone);

  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id',p.id,'name',p.full_name,'phone',coalesce(p.phone,''),
      'type_label', case when p.partner_type='agency' then 'Agency' else 'Delivery boy' end,
      'assigned',s.assigned,'delivered',s.delivered,'failed',s.failed,'pending',s.pending,
      'success_rate', case when (s.delivered+s.failed)=0 then null
                           else round(100.0*s.delivered/(s.delivered+s.failed)) end,
      'success_label', case when (s.delivered+s.failed)=0 then '—'
                            else round(100.0*s.delivered/(s.delivered+s.failed))::text||'%' end,
      'avg_minutes', s.avg_min,
      -- CHANGE #309 (7): the customer's own verdict, beside the success rate.
      'rating_label_caption', public._c('admin.delivery.rating_col'),
      'rating_avg',   rt.avg_stars,
      'rating_label', case when rt.n = 0 then public._c('admin.delivery.rating_none')
                           else to_char(rt.avg_stars,'FM90.0') || ' ★ (' || rt.n || ')' end,
      'rating_count', rt.n,
      -- CHANGE #309 (6): papers in order?
      'docs', public.delivery_doc_state(p.id),
      'last_seen', l.updated_at, 'lat', l.lat, 'lng', l.lng
    ) order by s.delivered desc, p.full_name), '[]'::jsonb)
    into v_riders
  from delivery_partner_registrations p
  left join delivery_partner_locations l on l.partner_id=p.id
  cross join lateral (
    select count(*) filter (where d.status='assigned')::int assigned,
           count(*) filter (where d.status='delivered')::int delivered,
           count(*) filter (where d.status='failed')::int failed,
           count(*) filter (where d.status in ('assigned','out_for_delivery'))::int pending,
           round(avg(extract(epoch from (d.delivered_at - d.started_at))/60)
                 filter (where d.delivered_at is not null and d.started_at is not null))::int avg_min
    from deliveries d join orders o on o.id=d.order_id
    where d.partner_id=p.id and (o.created_at at time zone 'Asia/Kolkata')::date=v_date) s
  cross join lateral (
    -- Ratings are a REPUTATION, not a daily figure: scored over the trailing 90
    -- days so one bad Tuesday does not read as a bad rider.
    select count(*)::int n, round(avg(stars)::numeric,1) avg_stars
      from delivery_ratings dr
     where dr.partner_id = p.id and dr.created_at > now() - interval '90 days') rt
  where p.is_active and coalesce(p.is_deleted,false)=false
    and public.scope_zone_ok(p.zone_id, v_zone);

  return jsonb_build_object('allowed',true,'the_date',v_date,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'),
    'tiles',v_tiles,'riders',v_riders,
    'sla', v_sla,
    'delivery_money', v_money,
    'fail_reasons', public.delivery_fail_reason_list());
end $function$;
