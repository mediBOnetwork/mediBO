-- CHANGE #354 — feature_gaps row 86 (surface delivery / step "live tracking", critical)
--
-- delivery_run_map() guarded itself with:
--     if v_run.partner_id <> coalesce(v_partner, v_run.partner_id) and not _is_admin()
--
-- v_partner is the caller's delivery_partner_registrations.id. For ANY caller who
-- is not a delivery partner — an anonymous visitor, a customer, a supplier — that
-- lookup returns NULL, so coalesce() handed the test the run's OWN partner_id and
-- the comparison collapsed to `partner_id <> partner_id` = FALSE. The guard passed.
-- The function is SECURITY DEFINER with EXECUTE granted to anon and authenticated,
-- so anyone holding (or guessing) a run uuid read every stop on that run:
-- pharmacy_name, lat/lng, status, plus the rider's live origin_lat/origin_lng.
--
-- The fix is an explicit membership test — you are the run's partner, or you are
-- an admin, and there is no third way in. The NULL that used to disable the guard
-- now fails it. Proof: rg behaviour test `delivery_run_map_authz`.
create or replace function public.delivery_run_map(p_run_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_run delivery_runs%rowtype; v_partner uuid; v_pts jsonb; v_loc delivery_partner_locations%rowtype;
begin
  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;

  select * into v_run from delivery_runs
   where id = coalesce(p_run_id,
       (select id from delivery_runs where partner_id = v_partner
          and run_date = public.scope_date()
          and status in ('planned','started') order by created_at desc limit 1));
  if v_run.id is null then
    return jsonb_build_object('ok',true,'has_run',false,'waypoints','[]'::jsonb);
  end if;

  -- CHANGE #354 (row 86): membership, not a coalesce that a NULL can switch off.
  -- Do NOT reintroduce `coalesce(v_partner, v_run.partner_id)` here — that made a
  -- non-partner caller compare the run against itself and always pass.
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
           'leg_km', d.leg_km, 'cum_km', d.cum_km, 'eta_min', d.eta_min)
         order by d.seq nulls last), '[]'::jsonb)
    into v_pts
  from deliveries d join orders o on o.id = d.order_id
  where d.run_id = v_run.id and d.status not in ('cancelled')
    and d.lat is not null and d.lng is not null;

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
    'waypoints', v_pts);
end $function$;

-- The rider app and the admin route optimiser are the only callers, and both are
-- signed in. Anonymous execution was never needed and is what made the leak
-- reachable without a login at all.
revoke execute on function public.delivery_run_map(uuid) from anon;
