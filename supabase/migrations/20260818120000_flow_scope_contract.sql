-- CHANGE #227 — ONE date scope, ONE zone scope, across the whole
-- customer-order → delivered flow.
--
-- Two root causes were making counts wrong and rows disappear:
--
--   1. zone_effective() falls back to the DEFAULT zone when the super-admin has
--      selected "All zones" (admin_active_zone() = NULL). Every screen built on
--      it therefore showed ONE zone while claiming to show all of them:
--      admin_dashboard_counts, admin_delivery_queue, admin_delivery_dashboard,
--      admin_delivery_partners.
--      zone_effective() itself is CORRECT for supplier/customer surfaces (they
--      must resolve to a concrete zone), so it is left alone — the admin
--      DISPLAY surfaces move to scope_zone() instead.
--
--   2. A second date source — a literal (now() AT TIME ZONE 'Asia/Kolkata')::date
--      instead of admin_active_date() — in the dashboard, delivery, inquiry and
--      WhatsApp-intake RPCs. Browsing to yesterday changed some screens and not
--      others.
--
-- SCOPE IS DISPLAY ONLY. Coverage checks, allocation, billing, payment matching,
-- dispute resolution and delivery keep seeing the full order across every date
-- and zone — an order placed yesterday still completes today. Every per-entity
-- RPC (…(p_order_id), …(p_bill_id), …(p_supplier_order_id)) is deliberately
-- unscoped and is recorded as such in scope_contract below.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE CANONICAL SCOPE HELPERS — the only two doors.
-- ─────────────────────────────────────────────────────────────────────────────

-- The single date source. Never now() in a display RPC again.
CREATE OR REPLACE FUNCTION public.scope_date(p_date date DEFAULT NULL)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(p_date, public.admin_active_date());
$$;

-- The single zone source. NULL is meaningful: it means ALL zones, and must be
-- preserved — that is the exact bug zone_effective() hides.
CREATE OR REPLACE FUNCTION public.scope_zone(p_zone smallint DEFAULT NULL)
RETURNS smallint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(p_zone, public.admin_active_zone());
$$;

-- Row-level zone predicate. A row whose zone is UNKNOWN is always visible:
-- an unzoned payment or bill must never silently vanish from the queue.
CREATE OR REPLACE FUNCTION public.scope_zone_ok(p_row_zone smallint, p_scope smallint)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path TO 'public' AS $$
  SELECT p_scope IS NULL OR p_row_zone IS NULL OR p_row_zone = p_scope;
$$;

COMMENT ON FUNCTION public.scope_date(date)  IS 'CHANGE #227 — the ONE admin date scope. coalesce(arg, admin_active_date()).';
COMMENT ON FUNCTION public.scope_zone(smallint) IS 'CHANGE #227 — the ONE admin zone scope. NULL = all zones (never collapse to default).';
COMMENT ON FUNCTION public.scope_zone_ok(smallint,smallint) IS 'CHANGE #227 — row visible when scope is all-zones, row zone unknown, or they match.';

GRANT EXECUTE ON FUNCTION public.scope_date(date)            TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scope_zone(smallint)        TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.scope_zone_ok(smallint,smallint) TO anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE WRITTEN AUDIT TABLE — the contract, in the backend, rendered verbatim.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.scope_contract (
  rpc_name      text PRIMARY KEY,
  stage_no      int      NOT NULL,
  stage         text     NOT NULL,
  surface       text     NOT NULL DEFAULT '',
  needs_date    boolean  NOT NULL DEFAULT true,
  needs_zone    boolean  NOT NULL DEFAULT true,
  date_mode     text     NOT NULL DEFAULT 'day',   -- day | asof | label | exempt
  before_status text     NOT NULL DEFAULT '',
  after_status  text     NOT NULL DEFAULT '',
  note          text     NOT NULL DEFAULT '',
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.scope_contract ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.scope_contract IS
  'CHANGE #227 — every RPC in the order→delivery flow and the date/zone scope it owes. rg guard flow_scope_contract fails if a listed RPC loses its scope.';

TRUNCATE public.scope_contract;
INSERT INTO public.scope_contract
  (stage_no, stage, rpc_name, surface, needs_date, needs_zone, date_mode, before_status, after_status, note) VALUES
-- 1 · WhatsApp item-list intake
 (1,'WhatsApp intake','wa_admin_order_groups','Customer → WhatsApp orders',true,false,'label','No scope — "today" was now() IST','Scoped — today follows admin_active_date()','Groups every day; the date only moves which day is highlighted. Never hides an image.'),
 (1,'WhatsApp intake','wa_conversations','WhatsApp inbox',false,true,'exempt','Zone collapsed to default','Zone honours All zones','A chat thread is continuous; only the zone is scoped.'),
-- 2 · Website / storefront ordering
 (2,'Storefront','storefront_page','Customer storefront',false,false,'exempt','n/a','Exempt — customer surface','A customer sees their own catalogue, never the admin date/zone scope.'),
 (2,'Storefront','cart_state','Customer cart',false,false,'exempt','n/a','Exempt — customer surface','Cart is per-user live state.'),
-- 3 · Order approval
 (3,'Order approval','admin_customer_screen_data','Admin → Customers',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (3,'Order approval','admin_customer_orders','Admin → Customer orders',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (3,'Order approval','admin_dashboard_counts','Admin → Dashboard tiles',true,true,'day','Date was now() IST; zone collapsed to default','Scoped','Both scopes fixed.'),
 (3,'Order approval','admin_pending_orders_for_user','Per-customer pending orders',false,false,'exempt','n/a','Exempt — per-entity','Takes p_user_id; must show every open order regardless of date.'),
-- 4 · Inquiry waterfall
 (4,'Inquiry waterfall','inquiry_day','Admin → Inquiry day',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (4,'Inquiry waterfall','inquiry_buckets_today','Inquiry buckets / counts',true,true,'day','No scope — hardcoded today, no zone','Scoped','Counts were wrong for every zone but the default.'),
 (4,'Inquiry waterfall','inquiry_dates','Inquiry date strip',true,false,'label','Today anchored to now() IST','Anchored to admin_active_date()','inquiry_day_log has no zone column; the strip lists every cycle date by design.'),
 (4,'Inquiry waterfall','admin_supplier_orders','Admin → Supplier orders',true,true,'day','Date default was now() IST','Default is admin_active_date()','Zone was already correct.'),
 (4,'Inquiry waterfall','admin_demand_preview','Demand preview',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (4,'Inquiry waterfall','inquiry_log_today','Inquiry day-log writer',false,false,'exempt','n/a','Exempt — writer','Writes inquiry_day_log for the real calendar day. Scoping a writer would corrupt history.'),
-- 5 · Supplier inquiry replies
 (5,'Supplier replies','supplier_inquiry_screen','Supplier → Inquiries',false,false,'exempt','n/a','Exempt — supplier surface','A supplier sees their own open inquiries, not the admin scope.'),
 (5,'Supplier replies','admin_preview_supplier_inquiries','Admin preview of a supplier',false,false,'exempt','n/a','Exempt — per-entity','Takes p_supplier_id.'),
-- 6 · Collect and Arrivals
 (6,'Collect / Arrivals','fw_list_arrivals','Admin → Arrivals',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (6,'Collect / Arrivals','fw_shop_suppliers','Collect supplier picker',true,true,'day','Date scoped, NO zone','Scoped','Suppliers from other zones were listed in the picker.'),
 (6,'Collect / Arrivals','fw_get_state','Supplier shop state',true,false,'day','Date scoped','Date scoped (unchanged)','Per-supplier; the supplier itself is the zone key.'),
-- 7 · Counting (voice + barcode)
 (7,'Counting','voice_count_targets','Voice count targets',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (7,'Counting','barcode_submit_scan','Barcode scan write',false,false,'exempt','n/a','Exempt — write path','A scan must land on the order it belongs to, whatever date is being browsed.'),
 (7,'Counting','voice_usage_today','Voice quota meter',false,false,'exempt','n/a','Exempt — quota','The daily quota is a real calendar day, not a browsed date.'),
-- 8 · Disputes and recounts
 (8,'Disputes','fw_get_disputes','Admin → Disputes',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (8,'Disputes','fw_resolve_dispute','Dispute resolution',false,false,'exempt','n/a','Exempt — logic','Resolution must see the whole order.'),
-- 9 · Warehouse and Bag
 (9,'Warehouse / Bag','fw_list_bags','Admin → Bags',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (9,'Warehouse / Bag','fw_get_bag_items','Bag contents',true,false,'day','Date scoped','Date scoped (unchanged)','Per-bag.'),
 (9,'Warehouse / Bag','bag_session_get','Bag session',false,false,'exempt','n/a','Exempt — per-supplier session','Session state, not a list.'),
-- 10 · Pack
 (10,'Pack','fw_pack_orders','Admin → Pack (fulfilment)',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (10,'Pack','pack_list_orders','Pack order list',true,true,'day','Scoped','Scoped (unchanged)','Already on the contract.'),
 (10,'Pack','pack_get_queue','Pack queue for one order',false,false,'exempt','n/a','Exempt — per-entity','Takes p_order_id.'),
-- 11 · Supplier bill import and bill lines
 (11,'Supplier bills','admin_pending_bills_count','Pending-bills badge',true,true,'asof','No scope at all','Scoped as-of the active date','As-of, not one day: an unimported bill from last week must stay in the badge.'),
 (11,'Supplier bills','bill_lines_panel','Bill lines',false,false,'exempt','n/a','Exempt — per-entity','Takes p_bill_id.'),
 (11,'Supplier bills','sup_order_bill_panel_v2','Supplier order bill panel',false,false,'exempt','n/a','Exempt — per-entity','Takes p_supplier_order_id.'),
-- 12 · Customer bill
 (12,'Customer bill','admin_bill_pipeline_list','Admin → Bill pipeline',true,true,'asof','No scope at all','Scoped as-of the active date','A bill still owed from an older order must not disappear.'),
 (12,'Customer bill','customer_bill','One customer bill',false,false,'exempt','n/a','Exempt — per-entity','Takes p_order_id.'),
-- 13 · Payments and QR
 (13,'Payments / QR','admin_payment_claims','Admin → Payment claims',true,true,'asof','No scope at all','Scoped as-of the active date','Claim rows scoped; the ORDER candidates inside each row stay unscoped so matching still works across dates.'),
 (13,'Payments / QR','admin_unmatched_payments','Admin → Unmatched payments',true,true,'asof','No scope at all','Scoped as-of the active date','Same rule — money is never hidden, only ordered by the active date.'),
 (13,'Payments / QR','payment_claim_autolink','Payment matching',false,false,'exempt','n/a','Exempt — logic','Must match across every date and zone.'),
 (13,'Payments / QR','admin_order_payment_view_v2','Order payment view',false,false,'exempt','n/a','Exempt — per-entity','Takes p_order_id.'),
-- 14 · Delivery assignment
 (14,'Delivery assign','admin_delivery_queue','Admin → Delivery queue',true,true,'day','Date was now() IST; zone collapsed to default','Scoped','Both scopes fixed.'),
 (14,'Delivery assign','admin_delivery_dashboard','Admin → Delivery dashboard',true,true,'day','Date was now() IST; zone collapsed to default','Scoped','Both scopes fixed.'),
 (14,'Delivery assign','admin_delivery_partners','Admin → Delivery partners',false,true,'exempt','Zone collapsed to default','Zone honours All zones','A partner roster has no date.'),
 (14,'Delivery assign','delivery_eligibility','Can this order be assigned',false,false,'exempt','n/a','Exempt — logic','Must see the whole order.'),
-- 15 · Runs
 (15,'Runs','delivery_run_map','Rider run map',true,false,'day','Default run picked by now() IST','Default run picked by scope_date()','Rider is not an admin, so scope_date() returns today for them.'),
-- 16 · Proof of delivery / delivered
 (16,'Delivered','delivery_mark_delivered','Mark delivered',false,false,'exempt','n/a','Exempt — logic','Completion must work on any date.'),
 (16,'Delivered','delivery_verify_otp','POD OTP',false,false,'exempt','n/a','Exempt — logic','Proof of delivery is never date-scoped.');

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE FIXES
-- ─────────────────────────────────────────────────────────────────────────────

-- 3.1 admin_dashboard_counts — one date source + All zones honoured.
CREATE OR REPLACE FUNCTION public.admin_dashboard_counts(p_date date DEFAULT NULL::date, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_zone smallint; v_date date; v_zname text;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false,
      'medicines',0,'pending_bills',0,'flagged_bills',0,
      'pending_orders',0,'contact_inquiries',0,'pending_customers',0);
  end if;
  v_zone := public.scope_zone(p_zone);          -- NULL = all zones
  v_date := public.scope_date(p_date);          -- the ONE date source
  select name into v_zname from zones where id = v_zone;

  return jsonb_build_object('allowed', true,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'), 'the_date', v_date,
    'medicines', (select count(*) from "MEDICINE"),
    'pending_bills', (select count(*) from pending_bills pb
                      where pb.status='pending'
                        and public.scope_zone_ok((select sp.zone_id from supplier_profiles sp
                                       where btrim(lower(sp.supplier_name)) = btrim(lower(pb.supplier_name))
                                       limit 1), v_zone)),
    'flagged_bills', (select count(*) from pending_bills pb
                      where pb.verdict in ('needs_approval','fake')
                        and public.scope_zone_ok((select sp.zone_id from supplier_profiles sp
                                       where btrim(lower(sp.supplier_name)) = btrim(lower(pb.supplier_name))
                                       limit 1), v_zone)),
    'pending_orders', (select count(*) from orders o
                        left join pharmacy_profiles pp on pp.id = o.customer_id
                       where o.status='pending'
                         and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)),
    'orders_today', (select count(*) from orders o
                      left join pharmacy_profiles pp on pp.id = o.customer_id
                     where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
                       and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)),
    'contact_inquiries', (select count(*) from contact_inquiries),
    'pending_customers', (select count(*) from pharmacy_profiles pp
                           where coalesce(pp.approved,false) = false
                             and public.scope_zone_ok(pp.zone_id, v_zone)),
    'deliveries_today', (select count(*) from deliveries d
                          join orders o on o.id = d.order_id
                         where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
                           and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone)));
end $function$;

-- 3.2 admin_delivery_dashboard
CREATE OR REPLACE FUNCTION public.admin_delivery_dashboard(p_date date DEFAULT NULL::date, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_date date; v_zone smallint; v_tiles jsonb; v_riders jsonb; v_zname text;
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
    'total',      count(*))
    into v_tiles
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
  where p.is_active and coalesce(p.is_deleted,false)=false
    and public.scope_zone_ok(p.zone_id, v_zone);

  return jsonb_build_object('allowed',true,'the_date',v_date,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'),
    'tiles',v_tiles,'riders',v_riders,
    'fail_reasons', public.delivery_fail_reason_list());
end $function$;

-- 3.3 admin_delivery_partners — roster has no date; the zone must honour All zones.
CREATE OR REPLACE FUNCTION public.admin_delivery_partners(p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_zone smallint; v_zname text; v_pending jsonb; v_active jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false);
  end if;
  v_zone := public.scope_zone(p_zone);
  select name into v_zname from zones where id = v_zone;

  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id',p.id,'full_name',coalesce(p.full_name,''),'phone',coalesce(p.phone,''),
      'vehicle_type',coalesce(p.vehicle_type,''),'city',coalesce(p.city,''),
      'id_doc_type',coalesce(p.id_doc_type,''),'id_doc_number',coalesce(p.id_doc_number,''),
      'id_doc_path',coalesce(p.id_doc_path,''),'ocr_payload',p.ocr_payload,
      'submitted_at',p.submitted_at,'has_login',(p.user_id is not null)
    ) order by p.submitted_at desc), '[]'::jsonb)
    into v_pending
  from delivery_partner_registrations p
  where coalesce(p.is_deleted,false)=false and p.is_active = false
    and coalesce(p.status,'pending') <> 'rejected';

  select coalesce(jsonb_agg(jsonb_build_object(
      'partner_id',p.id,'full_name',coalesce(p.full_name,''),'phone',coalesce(p.phone,''),
      'partner_type',p.partner_type,
      'type_label', case when p.partner_type='agency' then 'Agency' else 'Delivery boy' end,
      'type_colors', case when p.partner_type='agency'
                          then jsonb_build_object('bg','#E6F1FB','fg','#0C447C')
                          else jsonb_build_object('bg','#E1F5EE','fg','#0F6E56') end,
      'zone_id',p.zone_id,
      'zone_label', coalesce((select z.name from zones z where z.id = p.zone_id),'Not set'),
      'parent_agency_id',p.parent_agency_id,
      'parent_agency_name', coalesce((select a.full_name from delivery_partner_registrations a
                                       where a.id = p.parent_agency_id),''),
      'max_stops',p.max_stops,'per_drop_rate',p.per_drop_rate,
      'rider_count', (select count(*) from delivery_partner_registrations c
                       where c.parent_agency_id = p.id and coalesce(c.is_deleted,false)=false),
      'open_stops', (select count(*) from deliveries d where d.partner_id = p.id
                      and d.status in ('assigned','out_for_delivery')),
      'on_shift', exists(select 1 from delivery_partner_shifts s
                          where s.partner_id = p.id and s.ended_at is null),
      'has_login',(p.user_id is not null)
    ) order by p.partner_type desc, p.full_name), '[]'::jsonb)
    into v_active
  from delivery_partner_registrations p
  where coalesce(p.is_deleted,false)=false and p.is_active
    and public.scope_zone_ok(p.zone_id, v_zone);

  return jsonb_build_object(
    'allowed', true, 'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'),
    'pending', v_pending, 'pending_count', jsonb_array_length(v_pending),
    'partners', v_active, 'partner_count', jsonb_array_length(v_active),
    'type_options', jsonb_build_array(
        jsonb_build_object('value','boy','label','Delivery boy',
          'note','Delivers assigned orders. Sees only their own stops.'),
        jsonb_build_object('value','agency','label','Delivery agency',
          'note','Can add its own riders and hand stops to them.')),
    'pending_title','Awaiting approval',
    'pending_note','Approve a registration, choose whether they are a delivery boy or an agency, and set their zone.');
end $function$;

-- 3.4 admin_delivery_queue
CREATE OR REPLACE FUNCTION public.admin_delivery_queue(p_date date DEFAULT NULL::date, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
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
                 when 'rejected' then 'Rejected' else 'Accepted' end)
             when 'out_for_delivery' then 'Out for delivery'
             when 'delivered' then 'Delivered'
             when 'failed' then 'Failed' when 'rto' then 'Returned' else 'Unassigned' end,
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
end $function$;

-- 3.5 fw_shop_suppliers — the Collect picker was listing every zone's suppliers.
CREATE OR REPLACE FUNCTION public.fw_shop_suppliers(p_date date DEFAULT admin_active_date())
 RETURNS TABLE(supplier_name text) LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_date date := public.scope_date(p_date);
        v_zone smallint := public.scope_zone();
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RETURN; END IF;
  RETURN QUERY
    SELECT DISTINCT so.supplier_name
    FROM supplier_orders so
    WHERE (so.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_date
      AND public.scope_zone_ok(so.zone_id, v_zone)
    ORDER BY so.supplier_name;
END $function$;

-- 3.6 inquiry_buckets_today — had neither scope.
CREATE OR REPLACE FUNCTION public.inquiry_buckets_today()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_row inquiry%ROWTYPE; v_i int; v_ps text; v_has_ps boolean; v_today boolean;
  v_no_supplier jsonb := '[]'::jsonb; v_oos jsonb := '[]'::jsonb; v_cust text;
  v_date date := public.scope_date();
  v_zone smallint := public.scope_zone();
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  FOR v_row IN
    SELECT * FROM inquiry i
     WHERE (i.current_supplier IS NULL OR btrim(i.current_supplier)='')
       AND public.scope_zone_ok(i.zone_id, v_zone)
  LOOP
    SELECT EXISTS (
      SELECT 1 FROM order_items oi JOIN orders o ON o.id = oi.order_id
      WHERE oi.product_id = v_row.product_id
        AND o.status = 'accepted'
        AND o.fulfillment_status NOT IN ('shipped','cancelled')
        AND COALESCE(oi.received_qty,0) = 0
        AND NOT COALESCE(oi.received_locked,false)
        AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_date
        AND public.scope_zone_ok(coalesce(oi.zone_id, o.zone_id), v_zone)
    ) INTO v_today;
    IF NOT v_today THEN CONTINUE; END IF;
    v_has_ps := false;
    FOR v_i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I','PS'||v_i) INTO v_ps USING v_row;
      IF v_ps IS NOT NULL AND btrim(v_ps) <> '' THEN v_has_ps := true; EXIT; END IF;
    END LOOP;
    v_cust := (SELECT string_agg(DISTINCT oi.pharmacy_name, ', ' ORDER BY oi.pharmacy_name)
               FROM order_items oi WHERE oi.product_id = v_row.product_id
                 AND oi.pharmacy_name IS NOT NULL AND btrim(oi.pharmacy_name) <> '');
    IF v_has_ps THEN
      v_oos := v_oos || jsonb_build_object('inquiry_id',v_row.id,'product_id',v_row.product_id,'product',v_row.product_name,'qty',v_row.quantity,'customers',v_cust);
    ELSE
      v_no_supplier := v_no_supplier || jsonb_build_object('inquiry_id',v_row.id,'product_id',v_row.product_id,'product',v_row.product_name,'qty',v_row.quantity,'customers',v_cust);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('no_supplier_available',v_no_supplier,'no_supplier_count',jsonb_array_length(v_no_supplier),
                            'all_out_of_stock',v_oos,'all_out_of_stock_count',jsonb_array_length(v_oos),
                            'the_date', v_date, 'zone_id', v_zone);
END;
$function$;

-- 3.7 inquiry_dates — Today/Yesterday anchored to the ONE date source.
CREATE OR REPLACE FUNCTION public.inquiry_dates(p_limit integer DEFAULT 60)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE d date := public.scope_date();
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'date', q.cycle_date,
      'label', CASE WHEN q.cycle_date = d THEN 'Today'
                    WHEN q.cycle_date = d - 1 THEN 'Yesterday'
                    ELSE to_char(q.cycle_date,'DD/MM/YYYY') END,
      'is_today', (q.cycle_date = d),
      'items', q.items,
      'suppliers', q.suppliers,
      'answered', q.answered,
      'no_response', q.no_response,
      'pending', q.pending,
      'summary', q.items || ' items · ' || q.suppliers || ' suppliers'
                 || CASE WHEN q.no_response > 0
                         THEN ' · ' || q.no_response || ' no reply' ELSE '' END)
      ORDER BY q.cycle_date DESC)
    FROM (
      SELECT cycle_date,
             count(*)                                        AS items,
             count(DISTINCT supplier_name)                   AS suppliers,
             count(*) FILTER (WHERE outcome = 'answered')    AS answered,
             count(*) FILTER (WHERE outcome = 'no_response') AS no_response,
             count(*) FILTER (WHERE outcome = 'pending')     AS pending
      FROM inquiry_day_log
      GROUP BY cycle_date
      ORDER BY cycle_date DESC
      LIMIT p_limit) q), '[]'::jsonb);
END;
$function$;

-- 3.8 admin_pending_bills_count — badge follows zone, and the date AS-OF.
CREATE OR REPLACE FUNCTION public.admin_pending_bills_count()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_role text := coalesce(public.get_my_role(),'none'); v_n int;
        v_date date := public.scope_date();
        v_zone smallint := public.scope_zone();
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false, 'count', 0, 'badge', '');
  end if;
  -- AS-OF, not one day: a bill that arrived last week and is still unimported
  -- must stay in the badge. Browsing back in time reconstructs that day's queue.
  select count(*) into v_n from pending_bills pb
   where pb.status = 'pending'
     and (pb.received_at at time zone 'Asia/Kolkata')::date <= v_date
     and public.scope_zone_ok((select sp.zone_id from supplier_profiles sp
                                where btrim(lower(sp.supplier_name)) = btrim(lower(pb.supplier_name))
                                limit 1), v_zone);
  return jsonb_build_object('allowed', true, 'count', coalesce(v_n,0), 'badge',
    case when coalesce(v_n,0) > 0 then v_n::text else '' end,
    'the_date', v_date, 'zone_id', v_zone);
end $function$;

-- 3.9 wa_admin_order_groups — "today" is the admin's active date, and nothing is hidden.
CREATE OR REPLACE FUNCTION public.wa_admin_order_groups(p_user_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v jsonb; v_prof record; v_today date := public.scope_date();
begin
  if get_my_role() <> 'super_admin' then raise exception 'forbidden: super_admin required'; end if;
  select user_id, coalesce(pharmacy_name,customer_name,owner_name) nm, customer_code,
         coalesce(phone,whatsapp_no,other_contact_no) phone
    into v_prof from pharmacy_profiles where user_id = p_user_id limit 1;

  with imgs as (
    select id, file_path, file_name, caption, received_at, coalesce(status,'pending') status,
           converted_order_code, convert_clicked_at,
           (received_at at time zone 'Asia/Kolkata')::date as ist_day
    from pending_orders where user_id = p_user_id
  ),
  numbered as (
    select *, row_number() over (partition by ist_day order by received_at asc) as img_no from imgs
  ),
  grp as (
    select ist_day,
           jsonb_agg(jsonb_build_object(
             'id',id,'file_path',file_path,'bucket','whatsapp-media','caption',caption,
             'received_at',received_at,'status',status,'converted_order_code',converted_order_code,
             'convert_clicked_at',convert_clicked_at,'img_no',img_no
           ) order by received_at asc) imgs,
           count(*) image_count, count(*) filter (where status='done') done_count, max(received_at) last_at
    from numbered group by ist_day
  ),
  ranked as (select row_number() over (order by ist_day desc) order_no, * from grp)
  select jsonb_build_object(
    'found', (v_prof.user_id is not null) or exists(select 1 from imgs),
    'today', v_today,
    'customer', jsonb_build_object('user_id',p_user_id,'name',v_prof.nm,'customer_code',v_prof.customer_code,'phone',v_prof.phone),
    'images_total',   (select count(*) from imgs),
    'images_pending', (select count(*) from imgs where status <> 'done'),
    'images_done',    (select count(*) from imgs where status = 'done'),
    'today_total',    (select count(*) from imgs where ist_day = v_today),
    'today_done',     (select count(*) from imgs where ist_day = v_today and status = 'done'),
    'today_pending',  (select count(*) from imgs where ist_day = v_today and status <> 'done'),
    'groups', coalesce((select jsonb_agg(jsonb_build_object(
        'order_no', order_no, 'day', ist_day, 'is_today', (ist_day = v_today), 'last_at', last_at,
        'image_count', image_count, 'done_count', done_count,
        'status', case when done_count=image_count then 'done' when done_count>0 then 'partial' else 'pending' end,
        'images', imgs
      ) order by order_no) from ranked), '[]'::jsonb)
  ) into v;
  return v;
end; $function$;

-- 3.10 delivery_run_map — the default run is picked on the ONE date source.
--      A rider is not an admin, so scope_date() returns IST today for them.
CREATE OR REPLACE FUNCTION public.delivery_run_map(p_run_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
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
  if v_run.partner_id <> coalesce(v_partner, v_run.partner_id) and not public._is_admin() then
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

-- 3.11 admin_supplier_orders — the DEFAULT was a second date source. Surgical:
--      only the parameter default moves; the (already correct) zone logic and
--      the whole body are left byte-for-byte alone.
DO $surgery$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.proname='admin_supplier_orders';
  IF v_src IS NULL THEN RAISE EXCEPTION 'admin_supplier_orders not found'; END IF;

  v_new := replace(v_src,
    'p_date date DEFAULT ((now() AT TIME ZONE ''Asia/Kolkata''::text))::date',
    'p_date date DEFAULT public.admin_active_date()');

  IF v_new = v_src THEN
    -- already fixed (re-run) — only shout if the contract is genuinely absent
    IF v_src NOT ILIKE '%admin_active_date%' THEN
      RAISE EXCEPTION 'admin_supplier_orders: expected now()-IST default not found and no admin_active_date present';
    END IF;
  ELSE
    EXECUTE v_new;
  END IF;
END $surgery$;

-- 3.12 admin_bill_pipeline_list — had NO scope at all.
--      AS-OF date + zone on the ORDER rows. The coverage/readiness logic inside
--      (_bill_ready, bill_lines, payment_claims sums) stays unscoped by design.
CREATE OR REPLACE FUNCTION public.admin_bill_pipeline_list(p_filter text DEFAULT 'active'::text, p_limit integer DEFAULT 50)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare cfg public.bill_auto_config%rowtype; v_rows jsonb; v_f text := lower(coalesce(p_filter,'active'));
        v_date date := public.scope_date();
        v_zone smallint := public.scope_zone();
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select * into cfg from public.bill_auto_config where id = 1;

  with base as (
    select o.id, o.order_code, o.pharmacy_name, o.created_at, o.cust_bill_path,
           coalesce(pp.pharmacy_name, o.pharmacy_name) as buyer,
           public._bill_ready(o.id) as ready,
           (select count(*) from bill_lines b
             where b.supplier_name in (select distinct oi2.assigned_supplier from order_items oi2
                                        where oi2.order_id = o.id and oi2.assigned_supplier is not null)
               and not b.verified) as unverified_sup,
           (select coalesce(sum(pc.amount),0) from payment_claims pc
             where pc.order_id = o.id and pc.status not in ('rejected','duplicate','need_details')) as paid,
           (select to_jsonb(bj) from bill_jobs bj where bj.order_id = o.id
             order by bj.created_at desc limit 1) as job,
           -- only a chase that ACTUALLY went out earns the chip
           (select max(cl.sent_at) from bill_chase_log cl
             where cl.order_id = o.id and coalesce(cl.result->>'ok','false') = 'true') as chased_at
    from orders o
    left join pharmacy_profiles pp on pp.user_id = o.user_id
    where o.status not in ('cancelled','rejected')
      -- SCOPE (display only): as-of the active date, in the active zone.
      and (o.created_at at time zone 'Asia/Kolkata')::date <= v_date
      and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)
      and exists (select 1 from order_items oi where oi.order_id = o.id
                    and oi.fulfillment_state not in ('shipped','cancelled')
                    and coalesce(oi.unfulfillable,false) = false)
    order by o.created_at desc
    limit 200
  ), shaped as (
    select b.*,
           (b.ready->>'uncovered')::int as uncovered,
           (b.job->>'status') as job_status,
           case
             when (b.job->>'status') = 'dead' then 'stuck'
             when b.cust_bill_path is not null then 'done'
             else 'active'
           end as bucket
    from base b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'order_id',      s.id,
    'order_code',    coalesce(s.order_code,''),
    'buyer_label',   coalesce(s.buyer,''),
    'placed_label',  to_char(s.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
    'stage_label',   case
                       when s.cust_bill_path is not null and s.paid > 0 then public._bpl('step.pay.label')
                       when s.cust_bill_path is not null then public._bpl('step.bill.done')
                       when s.job_status = 'dead' then public._bpl('step.bill.failed')
                       when s.job_status in ('queued','running','rendered') then public._bpl('step.bill.running')
                       when s.uncovered > 0 then public._bpl('step.items.pending')
                       else public._bpl('step.lines.pending')
                     end,
    'stage_tone',    case
                       when s.cust_bill_path is not null then 'success'
                       when s.job_status = 'dead' then 'danger'
                       when s.job_status is not null then 'info'
                       else 'warning'
                     end,
    'chips', (
      select coalesce(jsonb_agg(x.chip order by x.ord), '[]'::jsonb) from (
        select 1 as ord, jsonb_build_object(
                 'label', public._bpl('chip.waiting') || ' ' ||
                          array_to_string(array(select jsonb_array_elements_text(s.ready->'waiting_suppliers')), ', '),
                 'tone','warning') as chip
         where jsonb_array_length(s.ready->'waiting_suppliers') > 0 and s.uncovered > 0
        union all
        select 2, jsonb_build_object('label', public._bpl('chip.no_supplier'), 'tone','danger')
         where (s.ready->>'items_without_supplier')::int > 0
        union all
        select 3, jsonb_build_object('label', public._bpl('chip.chased'), 'tone','info')
         where s.chased_at is not null and s.cust_bill_path is null
        union all
        select 4, jsonb_build_object(
                 'label', public._bpl('step.lines.pending') || ' · ' || s.unverified_sup::text, 'tone','warning')
         where s.unverified_sup > 0
      ) x),
    'uncovered', s.uncovered,
    'unverified', s.unverified_sup,
    'has_bill', s.cust_bill_path is not null
  ) order by s.created_at desc), '[]'::jsonb)
    into v_rows
  from shaped s
  where (v_f = 'all') or (s.bucket = v_f);

  return jsonb_build_object(
    'ok', true,
    'title',    public._bpl('screen.title'),
    'subtitle', public._bpl('screen.subtitle'),
    'empty_label', public._bpl('screen.empty'),
    'retry_label', public._bpl('screen.retry'),
    'the_date', v_date, 'zone_id', v_zone,
    'tabs', jsonb_build_array(
      jsonb_build_object('key','active','label', public._bpl('tab.active')),
      jsonb_build_object('key','stuck', 'label', public._bpl('tab.stuck')),
      jsonb_build_object('key','done',  'label', public._bpl('tab.done'))),
    'selected_tab', v_f,
    'rows', (select coalesce(jsonb_agg(e), '[]'::jsonb)
               from (select e from jsonb_array_elements(v_rows) e limit greatest(coalesce(p_limit,50),1)) t),
    'count_label', jsonb_array_length(v_rows)::text
  );
end $function$;

-- 3.13 admin_payment_claims — claim ROWS scoped as-of + zone.
--      The candidate ORDERS inside each row stay UNSCOPED: payment matching must
--      keep seeing every order across dates and zones (spec's critical exception).
CREATE OR REPLACE FUNCTION public.admin_payment_claims(p_limit integer DEFAULT 50)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  result jsonb;
  v_before integer;
  v_after  integer;
  v_date date := public.scope_date();
  v_zone smallint := public.scope_zone();
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(pay_link_hours_before,12), coalesce(pay_link_days_after,7)
    into v_before, v_after from billing_config where id = 1;
  v_before := coalesce(v_before,12);
  v_after  := coalesce(v_after,7);

  select coalesce(jsonb_agg(c order by rec desc), '[]'::jsonb) into result
  from (
    select
      jsonb_build_object(
        'claim_id',        pc.id,
        'sender_phone',    pc.sender_phone,
        'amount',          pc.amount,
        'utr',             pc.utr,
        'txn_id',          pc.txn_id,
        'app',             pc.app,
        'paid_at',         pc.paid_at,
        'paid_ts',         pc.paid_ts,
        'payee_name',      pc.payee_name,
        'payee_vpa',       pc.payee_vpa,
        'file_path',       pc.file_path, 'bucket', CASE WHEN pc.file_path LIKE 'whatsapp/%' OR pc.file_path LIKE 'cash_payments/%' THEN 'whatsapp-media' ELSE 'payment-proofs' END,
        'status',          pc.status,
        'verify_reason',   pc.verify_reason,
        'linked_order_id', pc.order_id,
        'received_at',     pc.received_at,
        'customer_name',   cust.cname,
        'note',            pc.autolink_note,
        -- only orders that satisfy factors 4 vs 5 are offered
        'orders',          coalesce(cust.orders, '[]'::jsonb)
      ) as c,
      pc.received_at as rec
    from payment_claims pc
    left join lateral (
      select
        pp.pharmacy_name as cname,
        pp.zone_id       as czone,
        coalesce(jsonb_agg(
          jsonb_build_object(
            'order_id',   o.id,
            'po',         coalesce(nullif(btrim(o.order_code),''),
                            'PO-'||to_char(o.created_at at time zone 'Asia/Kolkata','YYMMDD')
                            ||'-'||upper(right(replace(o.id::text,'-',''),4))),
            'created_at', o.created_at,
            'status',     o.status,
            'days_gap',   round(extract(epoch from (pc.paid_ts - o.created_at))/86400.0, 2),
            'item_count', adv.item_count,
            'mrp_total',  adv.mrp_total,
            'advance',    adv.advance
          ) order by o.created_at desc
        ) filter (where o.id is not null), '[]'::jsonb) as orders
      from pharmacy_profiles pp
      left join orders o
        on o.user_id = pp.user_id
       and o.status = 'pending'
       and pc.paid_ts is not null
       and pc.paid_ts >= o.created_at - make_interval(hours => v_before)
       and pc.paid_ts <= o.created_at + make_interval(days  => v_after)
      left join lateral (
        select
          count(*)::int as item_count,
          sum((it->>'mrp')::numeric * (it->>'quantity')::numeric) as mrp_total,
          round(coalesce(sum((it->>'mrp')::numeric * (it->>'quantity')::numeric),0) * 0.30) as advance
        from jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) it
      ) adv on true
      -- factor 2 = factor 3
      where right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone, ''),'\D','','g'),10)
          = right(regexp_replace(coalesce(pc.sender_phone,''),'\D','','g'),10)
        and coalesce(pp.is_deleted,false) = false
      group by pp.pharmacy_name, pp.zone_id
      limit 1
    ) cust on true
    -- SCOPE (display only): as-of the active date, in the active zone. A claim
    -- whose customer is unknown has no zone and is ALWAYS shown — money must
    -- never silently vanish from the queue.
    where (pc.received_at at time zone 'Asia/Kolkata')::date <= v_date
      and public.scope_zone_ok(
            coalesce((select o2.zone_id from orders o2 where o2.id = pc.order_id), cust.czone),
            v_zone)
    order by pc.received_at desc
    limit greatest(1, coalesce(p_limit,50))
  ) sub;

  return result;
end $function$;

-- 3.14 admin_unmatched_payments — same rule; candidates stay unscoped.
CREATE OR REPLACE FUNCTION public.admin_unmatched_payments()
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare result jsonb;
        v_date date := public.scope_date();
        v_zone smallint := public.scope_zone();
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_agg(x order by x->>'paid_ts' desc), '[]'::jsonb) into result
  from (
    select jsonb_build_object(
      'claim_id', pc.id,
      'amount', pc.amount,
      'amount_label', '₹' || to_char(pc.amount, 'FM99,99,99,990'),
      'utr', pc.utr, 'txn_id', pc.txn_id, 'app', pc.app,
      'payee_name', pc.payee_name,
      'file_path', pc.file_path, 'bucket', 'payment-proofs',
      'status', pc.status,
      'sender_phone', pc.sender_phone,
      'customer_name', pp.pharmacy_name,
      'paid_ts', pc.paid_ts,
      'paid_label', coalesce(nullif(btrim(pc.paid_at), ''),
                     to_char(pc.received_at at time zone 'Asia/Kolkata','FMHH12:MI am "on" DD Mon')),
      'note', coalesce(pc.autolink_note, 'No matching order.'),
      -- orders this claim COULD legally attach to, under the date window.
      -- UNSCOPED on purpose: matching must see every date and zone.
      'candidates', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'order_id', o.id, 'order_code', o.order_code,
                 'placed_label', to_char(o.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI am'),
                 'days_gap', round(extract(epoch from (pc.paid_ts - o.created_at))/86400.0, 2))
               order by o.created_at desc)
        from orders o
        where o.user_id = pp.user_id
          and coalesce(o.fulfillment_status,'open') <> 'cancelled'
          and coalesce(o.status,'pending') <> 'rejected'
          and pc.paid_ts between o.created_at
                              - make_interval(hours => coalesce((select pay_link_hours_before from billing_config where id=1),12))
                            and o.created_at
                              + make_interval(days => coalesce((select pay_link_days_after from billing_config where id=1),7))
      ), '[]'::jsonb)
    ) as x
    from payment_claims pc
    left join pharmacy_profiles pp
      on right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
       = right(regexp_replace(coalesce(pc.sender_phone,''),'\D','','g'),10)
     and coalesce(pp.is_deleted,false) = false
    where pc.order_id is null
      and pc.status = 'claimed'
      -- SCOPE (display only)
      and (pc.received_at at time zone 'Asia/Kolkata')::date <= v_date
      and public.scope_zone_ok(pp.zone_id, v_zone)
  ) q;

  return jsonb_build_object('count', jsonb_array_length(result), 'claims', result,
                            'the_date', v_date, 'zone_id', v_zone);
end $function$;

-- 3.15 wa_conversations — All zones must mean all zones.
CREATE OR REPLACE FUNCTION public.wa_conversations(p_type text DEFAULT NULL::text, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_all jsonb; v_zone smallint;
begin
  if get_my_role() not in ('admin','super_admin') then return '[]'::jsonb; end if;
  v_zone := public.scope_zone(p_zone);
  v_all := public._wa_conversations_core(p_type);
  if v_all is null or jsonb_typeof(v_all) <> 'array' then return coalesce(v_all,'[]'::jsonb); end if;
  if v_zone is null then return v_all; end if;   -- All zones

  return coalesce((
    select jsonb_agg(c)
    from jsonb_array_elements(v_all) c
    where public.wa_zone_visible(c->>'sender_phone', v_zone)
  ), '[]'::jsonb);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE LIVE AUDIT — scope_contract checked against the LIVE function source,
--    so the screen shows what is true right now, not what was true at deploy.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.scope_contract_status()
RETURNS TABLE(
  rpc_name text, stage_no int, stage text, surface text,
  needs_date boolean, needs_zone boolean, date_mode text,
  before_status text, after_status text, note text,
  exists_now boolean, has_date boolean, has_zone boolean, ok boolean
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_catalog' AS $$
  WITH src AS (
    SELECT c.*,
           (SELECT string_agg(pg_get_functiondef(p.oid), E'\n')
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname='public' AND p.proname = c.rpc_name) AS def
    FROM scope_contract c
  )
  SELECT s.rpc_name, s.stage_no, s.stage, s.surface,
         s.needs_date, s.needs_zone, s.date_mode,
         s.before_status, s.after_status, s.note,
         (s.def IS NOT NULL)                                              AS exists_now,
         COALESCE(s.def ~* '(scope_date|admin_active_date)', false)       AS has_date,
         COALESCE(s.def ~* '(scope_zone|admin_active_zone)', false)       AS has_zone,
         (s.def IS NOT NULL)
           AND (NOT s.needs_date OR COALESCE(s.def ~* '(scope_date|admin_active_date)', false))
           AND (NOT s.needs_zone OR COALESCE(s.def ~* '(scope_zone|admin_active_zone)', false)) AS ok
  FROM src s;
$$;
COMMENT ON FUNCTION public.scope_contract_status() IS
  'CHANGE #227 — live check: does every contracted flow RPC still carry the date/zone scope it owes?';

-- Backend copy door for this screen (same shape as _bpl / _offer_copy).
CREATE OR REPLACE FUNCTION public._scl(p_key text, p_vars jsonb DEFAULT '{}'::jsonb)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
declare v text; k text;
begin
  select value #>> '{}' into v from ui_copy where key = p_key;   -- ui_copy.value is jsonb
  if v is null then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars,'{}'::jsonb)) loop
    v := replace(v, '{'||k||'}', coalesce(p_vars->>k,''));
  end loop;
  return v;
end $$;
GRANT EXECUTE ON FUNCTION public._scl(text, jsonb) TO authenticated, service_role;

-- The screen. One RPC, every string server-side, rendered verbatim.
CREATE OR REPLACE FUNCTION public.admin_scope_audit()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_rows jsonb; v_total int; v_ok int; v_ex int; v_bad int; v_scope jsonb;
BEGIN
  IF public.get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error','not_authorized',
      'error_label', public._scl('scope_audit.not_authorized'));
  END IF;

  SELECT count(*)::int,
         count(*) FILTER (WHERE s.ok)::int,
         count(*) FILTER (WHERE NOT s.needs_date AND NOT s.needs_zone)::int,
         count(*) FILTER (WHERE NOT s.ok)::int
    INTO v_total, v_ok, v_ex, v_bad
    FROM public.scope_contract_status() s;

  SELECT coalesce(jsonb_agg(g ORDER BY (g->>'stage_no')::int), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT jsonb_build_object(
             'stage_no', s.stage_no,
             'stage', s.stage,
             'count_label', count(*)::text,
             'rows', jsonb_agg(jsonb_build_object(
                'rpc', s.rpc_name,
                'surface', s.surface,
                'date_label', CASE WHEN NOT s.needs_date THEN public._scl('scope_audit.chip.date_na')
                                   WHEN s.date_mode='asof' THEN public._scl('scope_audit.chip.date_asof')
                                   WHEN s.date_mode='label' THEN public._scl('scope_audit.chip.date_label')
                                   ELSE public._scl('scope_audit.chip.date_day') END,
                'date_tone',  CASE WHEN NOT s.needs_date THEN 'neutral'
                                   WHEN s.has_date THEN 'success' ELSE 'danger' END,
                'zone_label', CASE WHEN NOT s.needs_zone THEN public._scl('scope_audit.chip.zone_na')
                                   ELSE public._scl('scope_audit.chip.zone_on') END,
                'zone_tone',  CASE WHEN NOT s.needs_zone THEN 'neutral'
                                   WHEN s.has_zone THEN 'success' ELSE 'danger' END,
                'before_label', s.before_status,
                'after_label',  s.after_status,
                'note', s.note,
                'status_label', CASE WHEN NOT s.exists_now THEN public._scl('scope_audit.status.missing')
                                     WHEN s.ok AND NOT s.needs_date AND NOT s.needs_zone
                                       THEN public._scl('scope_audit.status.exempt')
                                     WHEN s.ok THEN public._scl('scope_audit.status.scoped')
                                     ELSE public._scl('scope_audit.status.broken') END,
                'status_tone',  CASE WHEN NOT s.exists_now THEN 'danger'
                                     WHEN NOT s.ok THEN 'danger'
                                     WHEN NOT s.needs_date AND NOT s.needs_zone THEN 'neutral'
                                     ELSE 'success' END)
              ORDER BY s.rpc_name)) AS g
    FROM public.scope_contract_status() s
    GROUP BY s.stage_no, s.stage
  ) t;

  v_scope := public.admin_date_scope_state();

  RETURN jsonb_build_object(
    'ok', true,
    'title',    public._scl('scope_audit.title'),
    'subtitle', public._scl('scope_audit.subtitle'),
    'scope_line', public._scl('scope_audit.scope_line', jsonb_build_object(
                    'date', coalesce(v_scope->>'long_label',''),
                    'zone', coalesce(v_scope->>'zone_label',''))),
    'rule_title', public._scl('scope_audit.rule.title'),
    'rule_body',  public._scl('scope_audit.rule.body'),
    'summary', jsonb_build_array(
      jsonb_build_object('label', public._scl('scope_audit.sum.total'),  'value', v_total::text, 'tone','neutral'),
      jsonb_build_object('label', public._scl('scope_audit.sum.scoped'), 'value', (v_ok - v_ex)::text, 'tone','success'),
      jsonb_build_object('label', public._scl('scope_audit.sum.exempt'), 'value', v_ex::text,    'tone','info'),
      jsonb_build_object('label', public._scl('scope_audit.sum.broken'), 'value', v_bad::text,
                         'tone', CASE WHEN v_bad > 0 THEN 'danger' ELSE 'success' END)),
    'all_green', (v_bad = 0),
    'banner_label', CASE WHEN v_bad = 0 THEN public._scl('scope_audit.banner.green')
                         ELSE public._scl('scope_audit.banner.red', jsonb_build_object('n', v_bad::text)) END,
    'banner_tone',  CASE WHEN v_bad = 0 THEN 'success' ELSE 'danger' END,
    'col_rpc',     public._scl('scope_audit.col.rpc'),
    'col_before',  public._scl('scope_audit.col.before'),
    'col_after',   public._scl('scope_audit.col.after'),
    'empty_label', public._scl('scope_audit.empty'),
    'retry_label', public._scl('scope_audit.retry'),
    'stages', v_rows);
END $$;

GRANT EXECUTE ON FUNCTION public.scope_contract_status() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_scope_audit()     TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. BACKEND COPY — every string above lives in ui_copy, none in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.ui_copy(key, value)
SELECT k, to_jsonb(v) FROM (VALUES
 ('scope_audit.title',            'Scope audit'),
 ('scope_audit.subtitle',         'Date and zone scope across the order → delivered flow'),
 ('scope_audit.scope_line',       'Showing {date} · {zone}'),
 ('scope_audit.rule.title',       'The rule'),
 ('scope_audit.rule.body',        'Scope controls what is DISPLAYED. Coverage, allocation, billing, payment matching, disputes and delivery always see the whole order, on every date and in every zone — an order placed yesterday still completes today.'),
 ('scope_audit.sum.total',        'RPCs audited'),
 ('scope_audit.sum.scoped',       'Scoped'),
 ('scope_audit.sum.exempt',       'Exempt by design'),
 ('scope_audit.sum.broken',       'Scope missing'),
 ('scope_audit.banner.green',     'Every screen in the flow is on the same date and zone scope.'),
 ('scope_audit.banner.red',       '{n} RPC(s) have lost their date or zone scope.'),
 ('scope_audit.chip.date_day',    'Date · active day'),
 ('scope_audit.chip.date_asof',   'Date · as of active day'),
 ('scope_audit.chip.date_label',  'Date · labels only'),
 ('scope_audit.chip.date_na',     'Date · not applicable'),
 ('scope_audit.chip.zone_on',     'Zone · active zone'),
 ('scope_audit.chip.zone_na',     'Zone · not applicable'),
 ('scope_audit.status.scoped',    'Scoped'),
 ('scope_audit.status.exempt',    'Exempt'),
 ('scope_audit.status.broken',    'Scope missing'),
 ('scope_audit.status.missing',   'RPC not found'),
 ('scope_audit.col.rpc',          'RPC'),
 ('scope_audit.col.before',       'Before'),
 ('scope_audit.col.after',        'After'),
 ('scope_audit.empty',            'No RPCs on the contract yet.'),
 ('scope_audit.retry',            'Retry'),
 ('scope_audit.not_authorized',   'Admins only.'),
 ('scope_audit.nav',              'Scope audit')
) AS t(k, v)
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE GUARD — a future change cannot drop date or zone scope from any of them.
--    Red here turns rg_check red, which blocks every dev_cmd_complete.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.rg_behavior_tests(name, enabled, note, body) VALUES (
 'flow_scope_contract', true,
 'CHANGE #227 — every RPC in the customer-order→delivered flow keeps the date and zone scope it owes (scope_contract). Fails if an RPC loses admin_active_date()/scope_date(), loses admin_active_zone()/scope_zone(), reintroduces zone_effective() on an admin display surface, or disappears entirely.',
$rg$
do $x$
declare v_bad text; v_n int;
begin
  -- 6a. the contract itself must exist and be populated
  select count(*) into v_n from scope_contract;
  if v_n < 30 then
    raise exception 'RG_FAIL: scope_contract has only % rows — the flow audit was gutted', v_n;
  end if;

  -- 6b. every contracted RPC still exists and still carries its scope
  select string_agg(s.rpc_name || ' (' || s.stage || ': ' ||
           case when not s.exists_now then 'RPC MISSING'
                when s.needs_date and not s.has_date and s.needs_zone and not s.has_zone then 'no date, no zone'
                when s.needs_date and not s.has_date then 'no date scope'
                else 'no zone scope' end || ')', '; ' order by s.rpc_name)
    into v_bad
    from public.scope_contract_status() s
   where not s.ok;
  if v_bad is not null then
    raise exception 'RG_FAIL: flow scope contract broken -> %', v_bad;
  end if;

  -- 6c. zone_effective() collapses "All zones" to the default zone. It is fine
  --     for supplier/customer surfaces, and NEVER fine on an admin display RPC
  --     that is on the contract.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join scope_contract c on c.rpc_name = p.proname
   where n.nspname = 'public'
     and c.needs_zone
     and pg_get_functiondef(p.oid) ilike '%zone_effective%';
  if v_bad is not null then
    raise exception 'RG_FAIL: zone_effective() is back on a contracted admin display RPC (All zones would collapse to the default zone) -> %', v_bad;
  end if;

  -- 6d. the two scope doors must keep their meaning: scope_zone() NULL = all zones.
  if public.scope_zone(null::smallint) is distinct from public.admin_active_zone() then
    raise exception 'RG_FAIL: scope_zone() no longer mirrors admin_active_zone()';
  end if;
  if public.scope_date(null::date) is distinct from public.admin_active_date() then
    raise exception 'RG_FAIL: scope_date() no longer mirrors admin_active_date()';
  end if;
  if public.scope_zone_ok(3::smallint, null::smallint) is not true then
    raise exception 'RG_FAIL: scope_zone_ok() hides rows when the scope is All zones';
  end if;
  if public.scope_zone_ok(null::smallint, 3::smallint) is not true then
    raise exception 'RG_FAIL: scope_zone_ok() hides rows whose zone is unknown';
  end if;
  if public.scope_zone_ok(4::smallint, 3::smallint) is not false then
    raise exception 'RG_FAIL: scope_zone_ok() leaks another zone''s rows';
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$rg$)
ON CONFLICT (name) DO UPDATE SET body = excluded.body, note = excluded.note, enabled = true;
