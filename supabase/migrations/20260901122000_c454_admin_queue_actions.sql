-- CMD #454 — the admin delivery row's buttons come from the payload.
--
-- Two of this command's fixes are only reachable through an admin action
-- (#100's Re-deliver, #116's route trail), and a third produced a state the
-- chip could not name (#115's accept_status='expired' rendered as 'Unassigned').
-- Rather than teach Dart three new rules, the row now carries its own
-- `actions[]` and the screen prints them verbatim.
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
          'assigned_at', d.assigned_at, 'delivered_at', d.delivered_at,
          'fail_reason', d.fail_reason,
          'status_label', case d.status
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
end $function$

;
