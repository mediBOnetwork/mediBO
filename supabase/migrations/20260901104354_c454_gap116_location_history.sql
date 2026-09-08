-- CMD #454 — feature_gaps #116
-- "There is no location history — only one current point per rider."
--
-- delivery_partner_locations is keyed on partner_id and delivery_update_location
-- upserted "on conflict (partner_id) do update", so every fix overwrote the last
-- one. No breadcrumb for a dispute, no proof of route, no distance for payout,
-- and the customer's map could only ever show a dot.
--
-- The hot row stays exactly where it is (every reader keeps working); the trail
-- is appended beside it, with a retention window so a 25-second ping does not
-- grow without bound.

create table if not exists public.delivery_partner_location_history (
  id          bigserial primary key,
  partner_id  uuid not null,
  run_id      uuid,
  ts          timestamptz not null default now(),
  lat         numeric not null,
  lng         numeric not null,
  heading     numeric,
  accuracy    numeric,
  moved_m     numeric
);

create index if not exists dplh_partner_ts_idx
  on public.delivery_partner_location_history (partner_id, ts desc);
create index if not exists dplh_run_ts_idx
  on public.delivery_partner_location_history (run_id, ts)
  where run_id is not null;

alter table public.delivery_partner_location_history enable row level security;
drop policy if exists dplh_no_direct on public.delivery_partner_location_history;
create policy dplh_no_direct on public.delivery_partner_location_history
  for select to authenticated using (false);

alter table public.delivery_config
  add column if not exists location_retain_days integer,
  add column if not exists location_min_move_m  integer;
update public.delivery_config
   set location_retain_days = coalesce(location_retain_days, 30),
       location_min_move_m  = coalesce(location_min_move_m, 25)
 where id = 1;

-- Append the trail, then do everything delivery_update_location already did.
create or replace function public.delivery_update_location(
  p_lat numeric, p_lng numeric, p_heading numeric default null, p_accuracy numeric default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_partner uuid; cfg jsonb; v_radius numeric; v_min_acc numeric;
  r record; v_arrived jsonb := '[]'::jsonb;
  v_prev record; v_moved numeric; v_min_move numeric; v_run uuid;
begin
  select id into v_partner from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null then return jsonb_build_object('ok',false,'error','not_a_partner'); end if;

  -- gap #116: the breadcrumb, written BEFORE the hot row is overwritten so the
  -- distance is measured against the fix it actually replaces.
  select lat, lng into v_prev from public.delivery_partner_locations where partner_id = v_partner;
  v_moved := case when v_prev.lat is null then null
                  else public._geo_m(v_prev.lat, v_prev.lng, p_lat, p_lng) end;
  select coalesce(location_min_move_m, 25) into v_min_move from public.delivery_config where id = 1;
  select id into v_run from public.delivery_runs
   where partner_id = v_partner and status = 'started'
   order by created_at desc limit 1;

  if v_moved is null or v_moved >= coalesce(v_min_move, 25) then
    insert into public.delivery_partner_location_history(partner_id, run_id, ts, lat, lng, heading, accuracy, moved_m)
    values (v_partner, v_run, now(), p_lat, p_lng, p_heading, p_accuracy, v_moved);
  end if;

  insert into public.delivery_partner_locations(partner_id, lat, lng, heading, accuracy, updated_at)
  values (v_partner, p_lat, p_lng, p_heading, p_accuracy, now())
  on conflict (partner_id) do update
    set lat=excluded.lat, lng=excluded.lng, heading=excluded.heading,
        accuracy=excluded.accuracy, updated_at=now();

  cfg := public._dcfg(null);
  v_radius  := coalesce((cfg->>'geofence_radius_m')::numeric, 150);
  v_min_acc := coalesce((cfg->>'geofence_min_accuracy_m')::numeric, 250);

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

-- The trail, and the distance derived from it, for a run.
create or replace function public.delivery_run_track(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_pts jsonb; v_km numeric; v_partner uuid;
begin
  select partner_id into v_partner from public.delivery_runs where id = p_run_id;
  if v_partner is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not public._is_admin() and not public._delivery_run_owned(p_run_id) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('lat',lat,'lng',lng,'ts',ts) order by ts), '[]'::jsonb),
         round(coalesce(sum(moved_m),0)/1000.0, 2)
    into v_pts, v_km
    from public.delivery_partner_location_history
   where run_id = p_run_id;

  return jsonb_build_object('ok', true, 'run_id', p_run_id,
    'points', v_pts, 'point_count', jsonb_array_length(v_pts),
    'distance_km', v_km,
    'distance_label', public._cf('delivery.track_distance',
        jsonb_build_object('km', trim_scale(v_km)::text)));
end $function$;

insert into public.ui_copy(key, value) values
  ('delivery.track_distance', to_jsonb('{km} km on this trip'::text))
on conflict (key) do nothing;

grant execute on function public.delivery_run_track(uuid) to authenticated;

create or replace function public.delivery_location_purge_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_days int; v_n int := 0;
begin
  select coalesce(location_retain_days, 30) into v_days from public.delivery_config where id = 1;
  delete from public.delivery_partner_location_history
   where ts < now() - make_interval(days => v_days);
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'deleted', v_n, 'retain_days', v_days);
end $function$;

insert into public.cron_task(name, ord, mode, work_sql, enabled, note, run_at_ist)
values ('delivery_location_purge', 943, 'poll',
        'select public.delivery_location_purge_tick()', true,
        'CMD #454 gap#116 — trims the rider breadcrumb trail past delivery_config.location_retain_days.',
        '01:35:00')
on conflict (name) do update
  set work_sql = excluded.work_sql, mode = excluded.mode, note = excluded.note,
      run_at_ist = excluded.run_at_ist, enabled = true;
