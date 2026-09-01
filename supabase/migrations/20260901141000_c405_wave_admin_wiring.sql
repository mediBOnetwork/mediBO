-- CHANGE #405 (C) — the surfaces: the wave payload, the admin actions, the
-- run-map decision trail, and the ONE dispatcher row that cuts waves on time.
-- No new pg_cron job: #305 left exactly one dispatcher and this rides it.

-- ── 1. One wave, rendered ───────────────────────────────────────────────────
-- Every word here is written in SQL. The screen prints status_label, tone,
-- every chip, every rider line and every decision sentence verbatim.
create or replace function public.delivery_wave_detail(p_wave_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare w delivery_wave%rowtype; v_stops jsonb; v_riders jsonb; v_dec jsonb;
        v_status_label text; v_tone text; v_actions jsonb;
begin
  select * into w from delivery_wave where id = p_wave_id;
  if w.id is null then return jsonb_build_object('ok',false,'error','wave_not_found'); end if;

  v_status_label := case w.status
    when 'planned'    then 'Collecting'
    when 'proposed'   then 'Waiting for approval'
    when 'approved'   then 'Approved'
    when 'dispatched' then 'Out with riders'
    when 'closed'     then 'Closed'
    else 'Cancelled' end;
  v_tone := case w.status
    when 'proposed' then 'warning'
    when 'dispatched' then 'success'
    when 'cancelled' then 'danger'
    else 'info' end;

  select coalesce(jsonb_agg(jsonb_build_object(
           'stop_id', s.id, 'order_id', s.order_id,
           'label', coalesce(pp.pharmacy_name, 'Order'),
           'sub_label', coalesce(pp.city,''),
           'rider_label', coalesce(p.full_name, 'Not allocated'),
           'status_label', case s.status
              when 'planned'  then 'Planned'
              when 'assigned' then 'With rider'
              when 'blocked'  then 'Blocked'
              when 'held'     then 'Waiting for a rider'
              when 'removed'  then 'Pulled off'
              else 'Rejected' end,
           'status_tone', case s.status
              when 'assigned' then 'success'
              when 'blocked'  then 'danger'
              when 'held'     then 'warning'
              when 'removed'  then 'neutral'
              else 'info' end,
           'reason', s.reason,
           'attempt_label', case when s.attempt_no > 1
                                 then 'Attempt ' || s.attempt_no else null end,
           'can_pull', (s.status in ('planned','assigned')),
           'pull_label', 'Pull off the run')
         order by s.created_at), '[]'::jsonb)
    into v_stops
  from delivery_wave_stop s
  left join delivery_partner_registrations p on p.id = s.partner_id
  left join orders o on o.id = s.order_id
  left join pharmacy_profiles pp on pp.id = o.customer_id
  where s.wave_id = w.id;

  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_riders
  from (
    select jsonb_build_object(
      'partner_id', p.id, 'name', coalesce(p.full_name,''),
      'stop_count', count(*),
      'count_label', count(*) || case when count(*) = 1 then ' stop' else ' stops' end) x
    from delivery_wave_stop s join delivery_partner_registrations p on p.id = s.partner_id
    where s.wave_id = w.id and s.status in ('planned','assigned')
    group by p.id, p.full_name
  ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', d.reason,
           'decision', d.decision,
           'at_label', to_char(d.created_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
           'actor', d.actor)
         order by d.created_at desc), '[]'::jsonb)
    into v_dec
  from (select * from delivery_wave_decision
         where wave_id = w.id order by created_at desc limit 60) d;

  v_actions := '[]'::jsonb;
  if w.status in ('planned','proposed','approved') then
    v_actions := v_actions || jsonb_build_object('key','replan','label','Re-plan','tone','neutral');
  end if;
  if w.status in ('proposed','approved') then
    v_actions := v_actions || jsonb_build_object('key','approve',
      'label', case when w.mode = 'suggest' then 'Approve and send' else 'Send to riders' end,
      'tone','brand');
  end if;
  if w.status in ('planned','proposed','approved') then
    v_actions := v_actions || jsonb_build_object('key','cancel','label','Cancel wave','tone','danger');
  end if;

  return jsonb_build_object(
    'ok', true, 'wave_id', w.id, 'zone_id', w.zone_id,
    'title', w.window_label,
    'subtitle', to_char(w.wave_date,'DD Mon') || ' • ' || w.cut_reason,
    'status', w.status, 'status_label', v_status_label, 'status_tone', v_tone,
    'mode', w.mode,
    'chips', jsonb_build_array(
      jsonb_build_object('label', w.stop_count || case when w.stop_count = 1
                            then ' stop' else ' stops' end, 'tone','info'),
      jsonb_build_object('label', w.rider_count || case when w.rider_count = 1
                            then ' rider' else ' riders' end, 'tone','neutral'),
      jsonb_build_object('label', w.blocked_count || ' blocked',
                         'tone', case when w.blocked_count > 0 then 'danger' else 'neutral' end)),
    'riders', v_riders, 'stops', v_stops, 'decisions', v_dec,
    'actions', v_actions,
    'decisions_heading', 'Why the engine chose this',
    'stops_heading', 'Stops',
    'riders_heading', 'Load per rider');
end $function$;

-- ── 2. The admin screen's ONE payload ───────────────────────────────────────
create or replace function public.admin_delivery_waves(
  p_date date default null, p_zone smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_zone smallint; v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  cfg delivery_wave_zone_config%rowtype; v_waves jsonb; v_windows jsonb;
  v_zone_label text; v_riders int;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'allowed',false,
      'message','Wave planning is for platform admins.');
  end if;

  v_zone := coalesce(p_zone, public.admin_active_zone(), public.zone_default_id());
  select coalesce(name, code, '') into v_zone_label from zones where id = v_zone;
  select * into cfg from delivery_wave_zone_config where zone_id = v_zone;

  if cfg.zone_id is null then
    insert into delivery_wave_zone_config(zone_id, updated_by)
    values (v_zone, 'auto_seed') on conflict (zone_id) do nothing;
    select * into cfg from delivery_wave_zone_config where zone_id = v_zone;
  end if;

  select count(*)::int into v_riders from public._wave_riders(v_zone);

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', w->>'key', 'label', w->>'label',
           'cutoff_label', 'Cut-off ' || (w->>'cutoff_ist') || ' IST',
           'action_label', 'Cut now')), '[]'::jsonb)
    into v_windows from jsonb_array_elements(cfg.windows) w;

  select coalesce(jsonb_agg(public.delivery_wave_detail(id) order by created_at desc), '[]'::jsonb)
    into v_waves
  from delivery_wave where zone_id = v_zone and wave_date = v_date;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'title', 'Delivery waves',
    'subtitle', v_zone_label || ' • ' || to_char(v_date,'DD Mon YYYY'),
    'zone_id', v_zone, 'zone_label', v_zone_label, 'date', v_date,
    'mode_card', jsonb_build_object(
      'heading','Assignment mode',
      'value', cfg.mode,
      'value_label', case cfg.mode
        when 'auto'    then 'Auto — the engine assigns'
        when 'suggest' then 'Suggest — you approve the plan'
        else 'Manual — assignment stays in the queue' end,
      'help', 'Set per zone. Suggest is the default so the plan is seen before it is trusted.',
      'options', jsonb_build_array(
        jsonb_build_object('key','auto','label','Auto',
          'hint','Cut, plan and send to riders without a tap.'),
        jsonb_build_object('key','suggest','label','Suggest',
          'hint','Prepare the wave and wait for your approval.'),
        jsonb_build_object('key','manual','label','Manual',
          'hint','No waves — assign from the delivery queue as today.'))),
    'riders_line', v_riders || case when v_riders = 1 then ' rider on shift'
                                    else ' riders on shift' end || ' in this zone',
    'windows_heading', 'Cut-off windows',
    'windows', v_windows,
    'waves_heading', 'Waves today',
    'waves', v_waves,
    'empty_hint', case when v_riders = 0
      then 'No rider is on shift in this zone yet — a wave will hold its stops until one starts a shift.'
      else 'No wave cut yet today. Cut one from a window above, or wait for its cut-off.' end);
end $function$;

-- ── 3. Admin actions ────────────────────────────────────────────────────────
create or replace function public.delivery_wave_mode_set(
  p_zone_id smallint, p_mode text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if p_mode not in ('auto','suggest','manual') then
    return jsonb_build_object('ok',false,'error','bad_mode');
  end if;
  insert into delivery_wave_zone_config(zone_id, mode, updated_at, updated_by)
  values (p_zone_id, p_mode, now(), coalesce(auth.jwt()->>'email','admin'))
  on conflict (zone_id) do update
    set mode = excluded.mode, updated_at = now(), updated_by = excluded.updated_by;
  perform public._wave_log(null, null, null, null, null, 'mode_changed',
    'Zone switched to ' || p_mode || ' assignment.',
    jsonb_build_object('zone_id', p_zone_id), coalesce(auth.jwt()->>'email','admin'));
  return jsonb_build_object('ok',true,'mode',p_mode,
    'message','Assignment mode is now ' || p_mode || ' for this zone.');
end $function$;

create or replace function public.delivery_wave_action(
  p_wave_id uuid, p_action text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_actor text := coalesce(auth.jwt()->>'email','admin');
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if p_action = 'replan'  then return public.delivery_wave_plan(p_wave_id, v_actor); end if;
  if p_action = 'approve' then
    update delivery_wave set approved_at = now(), approved_by = v_actor,
           status = 'approved'
     where id = p_wave_id and status in ('planned','proposed','approved');
    perform public._wave_log(p_wave_id, null, null, null, null, 'wave_approved',
      'Approved by ' || v_actor || ' — sending the plan to the riders.',
      '{}'::jsonb, v_actor);
    return public.delivery_wave_dispatch(p_wave_id, v_actor);
  end if;
  if p_action = 'cancel' then
    update delivery_wave set status = 'cancelled', closed_at = now() where id = p_wave_id;
    update delivery_wave_stop set status = 'removed',
           reason = 'Wave cancelled by ' || v_actor
     where wave_id = p_wave_id and status in ('planned','held');
    perform public._wave_log(p_wave_id, null, null, null, null, 'wave_cancelled',
      'Cancelled by ' || v_actor || '.', '{}'::jsonb, v_actor);
    return public.delivery_wave_detail(p_wave_id);
  end if;
  return jsonb_build_object('ok',false,'error','bad_action');
end $function$;

-- Cut a wave by hand (spec 1: "admin can also cut a wave manually").
create or replace function public.delivery_wave_cut_now(
  p_zone_id smallint, p_window_key text default 'manual')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  return public.delivery_wave_cut(p_zone_id, p_window_key, null,
           coalesce(auth.jwt()->>'email','admin'));
end $function$;

-- Pull a stop off a run before it starts — exactly as an admin can today.
create or replace function public.delivery_wave_stop_pull(
  p_stop_id uuid, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare s delivery_wave_stop%rowtype; v_actor text := coalesce(auth.jwt()->>'email','admin');
        v_started timestamptz;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into s from delivery_wave_stop where id = p_stop_id;
  if s.id is null then return jsonb_build_object('ok',false,'error','stop_not_found'); end if;

  if s.delivery_id is not null then
    select r.started_at into v_started
      from deliveries d join delivery_runs r on r.id = d.run_id where d.id = s.delivery_id;
    if v_started is not null then
      return jsonb_build_object('ok',false,'error','run_started',
        'message','That run has already started — reassign the stop instead.');
    end if;
    update deliveries set status='unassigned', partner_id=null, run_id=null,
           accept_status='pending', wave_id=null
     where id = s.delivery_id;
    insert into delivery_events(delivery_id, order_id, partner_id, event, note, actor)
    values (s.delivery_id, s.order_id, s.partner_id, 'unassigned', p_reason, v_actor);
  end if;

  update delivery_wave_stop set status='removed', partner_id=null, delivery_id=null,
         released_at = now(),
         reason = coalesce(nullif(btrim(coalesce(p_reason,'')),''), 'Pulled off by ' || v_actor)
   where id = p_stop_id;

  perform public._wave_log(s.wave_id, s.id, s.order_id, s.partner_id, s.delivery_id,
    'stop_pulled', 'Pulled off the run by ' || v_actor ||
    case when nullif(btrim(coalesce(p_reason,'')),'') is not null
         then ' — ' || p_reason else '' end || '.', '{}'::jsonb, v_actor);

  return public.delivery_wave_detail(s.wave_id);
end $function$;

-- ── 4. The dispatcher tick (spec 1: from the #305 dispatcher, not a new cron) ─
-- A window is DUE when its IST cut-off has passed today and no wave exists for
-- that slot. A manual zone is skipped without a wave, which is what "manual =
-- today's behaviour" means.
create or replace function public.delivery_wave_due()
returns table(zone_id smallint, window_key text, label text)
language sql stable security definer set search_path to 'public'
as $$
  select c.zone_id, w->>'key', w->>'label'
    from delivery_wave_zone_config c
    cross join lateral jsonb_array_elements(c.windows) w
   where c.enabled
     and c.mode <> 'manual'
     and (w->>'cutoff_ist')::time <= (now() at time zone 'Asia/Kolkata')::time
     and not exists (
       select 1 from delivery_wave dw
        where dw.zone_id = c.zone_id
          and dw.wave_date = (now() at time zone 'Asia/Kolkata')::date
          and dw.window_key = w->>'key');
$$;

create or replace function public.delivery_wave_tick()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare d record; v_n int := 0;
begin
  for d in select * from public.delivery_wave_due() loop
    perform public.delivery_wave_cut(d.zone_id, d.window_key, null, 'engine');
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'waves_cut', v_n);
end $function$;

insert into public.cron_task(name, mode, ord, gate_sql, work_sql, base_interval_s,
                             enabled, dml, note)
values ('delivery_wave_cut', 'poll', 215,
        'select exists (select 1 from public.delivery_wave_due())',
        'select public.delivery_wave_tick()',
        300, true, true,
        'CHANGE #405 — cuts an area-wise delivery wave when its IST cut-off passes. Gated on delivery_wave_due(), so it costs nothing between windows and nothing at all in a manual zone.')
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      base_interval_s = excluded.base_interval_s, enabled = excluded.enabled,
      dml = excluded.dml, note = excluded.note;

-- ── 5. The decision trail on the run map (spec 4) ───────────────────────────
-- The run map keeps its exact shape and gains two things: each waypoint carries
-- the sentence that explains why this rider has this stop, and the run carries
-- the wave it came from. A rider or an admin reading the map can see the reason
-- without opening another screen.
create or replace function public.delivery_run_map(p_run_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_run delivery_runs%rowtype; v_partner uuid; v_loc delivery_partner_locations%rowtype;
  v_pts jsonb; v_wave jsonb; v_wave_id uuid;
begin
  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and is_active and coalesce(is_deleted,false)=false limit 1;

  -- The default run is picked by scope_date(), NOT by now() — the flow scope
  -- contract (stage 15, "Runs") requires it, and for a rider (who is not an
  -- admin) scope_date() returns today anyway.
  if p_run_id is not null then
    select * into v_run from delivery_runs where id = p_run_id;
  else
    select * into v_run from delivery_runs
     where partner_id = v_partner
       and run_date = public.scope_date(null::date)
     order by created_at desc limit 1;
  end if;
  if v_run.id is null then return jsonb_build_object('ok',true,'has_run',false); end if;

  if not (v_partner is not null and v_run.partner_id = v_partner)
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = v_run.partner_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'delivery_id', d.id, 'seq', d.seq, 'lat', d.lat, 'lng', d.lng,
           'label', coalesce(o.pharmacy_name,''),
           'status', d.status,
           'pin_color', case d.status when 'delivered' then '#1B7A43'
                                      when 'failed' then '#B42318'
                                      when 'rto' then '#B42318' else '#F59E0B' end,
           'wave_reason', s.reason,
           -- The pin's tooltip, composed HERE so the run map can show WHY this
           -- rider has this stop without the panel concatenating anything.
           'map_title', coalesce(o.pharmacy_name,'') ||
             case when coalesce(s.reason,'') = '' then ''
                  else ' — ' || s.reason end,
           'leg_km', d.leg_km, 'cum_km', d.cum_km, 'eta_min', d.eta_min)
         order by d.seq nulls last), '[]'::jsonb)
    into v_pts
  from deliveries d
  join orders o on o.id = d.order_id
  left join delivery_wave_stop s on s.delivery_id = d.id
  where d.run_id = v_run.id and d.status not in ('cancelled')
    and d.lat is not null and d.lng is not null;

  select d.wave_id into v_wave_id from deliveries d
   where d.run_id = v_run.id and d.wave_id is not null limit 1;

  if v_wave_id is not null then
    select jsonb_build_object(
             'heading','Why these stops',
             'label', w.window_label || ' • ' || to_char(w.wave_date,'DD Mon'),
             'mode_label', case w.mode when 'auto' then 'Assigned automatically'
                                       when 'suggest' then 'Planned by the engine, approved by an admin'
                                       else 'Assigned by an admin' end,
             'decisions', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'label', x.reason,
                        'at_label', to_char(x.created_at at time zone 'Asia/Kolkata','HH24:MI'))
                      order by x.created_at desc)
                 from (select * from delivery_wave_decision
                        where wave_id = w.id order by created_at desc limit 12) x), '[]'::jsonb))
      into v_wave from delivery_wave w where w.id = v_wave_id;
  end if;

  return jsonb_build_object(
    'ok', true, 'has_run', true, 'run_id', v_run.id,
    'run_status', v_run.status,
    'google_optimized', v_run.google_optimized,
    'road_polyline', v_run.road_polyline,
    'total_km', v_run.total_km, 'total_min', v_run.total_min,
    'total_label', case when v_run.total_km is null then null
                        else v_run.total_km::text || ' km' ||
                             coalesce(' • ' || v_run.total_min::text || ' min','') end,
    'origin_lat', v_loc.lat, 'origin_lng', v_loc.lng,
    'wave', v_wave,
    'waypoints', v_pts);
end $function$;

-- ── 6. Grants and the reachable admin tile ──────────────────────────────────
-- Postgres grants EXECUTE to PUBLIC by default, and the anon key ships inside
-- the web bundle and the APK — so every one of these is revoked from anon
-- BEFORE it is granted to a signed-in user. The RPCs do their own role check on
-- top; this is the outer door.
revoke execute on function public.admin_delivery_waves(date, smallint) from public, anon;
revoke execute on function public.delivery_wave_detail(uuid) from public, anon;
revoke execute on function public.delivery_wave_mode_set(smallint, text) from public, anon;
revoke execute on function public.delivery_wave_action(uuid, text) from public, anon;
revoke execute on function public.delivery_wave_cut_now(smallint, text) from public, anon;
revoke execute on function public.delivery_wave_stop_pull(uuid, text) from public, anon;
revoke execute on function public.delivery_wave_cut(smallint, text, date, text) from public, anon, authenticated;
revoke execute on function public.delivery_wave_plan(uuid, text) from public, anon, authenticated;
revoke execute on function public.delivery_wave_dispatch(uuid, text) from public, anon, authenticated;
revoke execute on function public.delivery_wave_reallocate(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.delivery_wave_tick() from public, anon, authenticated;
revoke execute on function public.delivery_wave_due() from public, anon, authenticated;
revoke execute on function public._wave_riders(smallint) from public, anon, authenticated;
revoke execute on function public._wave_log(uuid, uuid, uuid, uuid, uuid, text, text, jsonb, text) from public, anon, authenticated;
revoke execute on function public._delivery_assign_core(uuid[], uuid, text, uuid) from public, anon, authenticated;

grant execute on function public.admin_delivery_waves(date, smallint) to authenticated;
grant execute on function public.delivery_wave_detail(uuid) to authenticated;
grant execute on function public.delivery_wave_mode_set(smallint, text) to authenticated;
grant execute on function public.delivery_wave_action(uuid, text) to authenticated;
grant execute on function public.delivery_wave_cut_now(smallint, text) to authenticated;
grant execute on function public.delivery_wave_stop_pull(uuid, text) to authenticated;

-- CHANGE #395 made this a pure INSERT: a registry row whose deep_link is a real
-- named route is pushed straight onto the navigator, so a new screen no longer
-- needs an edit in home_shell.dart to become tappable.
insert into public.feature_registry(feature_key, label, group_label, icon_key,
  route_key, sort_order, owner, category, surface, roles_allowed, deep_link,
  search_terms, description, default_access, partner_eligible, is_active)
values ('admin.delivery_waves', 'Delivery waves', 'Delivery', 'route',
        'delivery_waves', 615, 'medibo', 'delivery', 'dashboard',
        '{admin,super_admin}', '/admin/delivery-waves',
        'wave auto assign rider dispatch planning',
        'Area-wise waves of packed orders, auto-assigned across the riders on shift.',
        'none', false, true)
on conflict (feature_key) do update
  set label = excluded.label, deep_link = excluded.deep_link,
      route_key = excluded.route_key, search_terms = excluded.search_terms,
      description = excluded.description, is_active = true;

insert into public.ui_copy(key, value) values
  ('admin.delivery.waves_entry', to_jsonb('Delivery waves'::text)),
  ('admin.delivery.waves_subtitle',
     to_jsonb('Auto-assign packed orders across riders on shift'::text)),
  -- The failure copy has to live in ui_copy rather than in the payload: when
  -- admin_delivery_waves() is the thing that failed there IS no payload to read
  -- a message out of, and an error card with no words in it is not a state.
  ('admin.delivery.waves_load_failed',
     to_jsonb('Could not load the wave plan. Check the connection and try again.'::text)),
  ('admin.delivery.waves_retry', to_jsonb('Retry'::text)),
  ('admin.delivery.waves_denied',
     to_jsonb('Wave planning is for platform admins.'::text))
on conflict (key) do update set value = excluded.value;
