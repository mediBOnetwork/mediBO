-- CHANGE #470 — the proof. Seeds five stall types, asserts each surfaces with
-- the right owner and a link that names a real screen, then MOVES one of them
-- and asserts it resolves itself. Every seeded row is removed again, pass or
-- fail.
--
-- It runs under the super-admin's own claims because the state machine (#469)
-- is actor-aware: a stop reaches 'failed' only through transitions an admin or
-- a rider is allowed to make, and a proof that had to be let through the guard
-- would not be proving anything. The failed stop is seeded in a zone with NO
-- active partner, so the failure notification resolves to nobody instead of
-- WhatsApping a real partner every time this runs.

create or replace function public._c470_assert(p_label text, p_ok boolean)
returns jsonb language sql immutable as $function$
  select jsonb_build_object('check', p_label, 'ok', coalesce(p_ok, false));
$function$;

create or replace function public.c470_exceptions_proof()
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_checks  jsonb := '[]'::jsonb;
  v_zone    smallint;
  v_nozone  smallint;
  v_uid     uuid;
  v_cust    uuid;
  v_order   uuid;
  v_order2  uuid;
  v_bill    uuid;
  v_del     uuid;
  v_period  bigint;
  v_item    uuid;
  v_prod    bigint;
  v_partner bigint;
  v_n       int;
  v_route   text;
  v_owner   text;
  v_sweep   jsonb;
  v_auto    jsonb;
begin
  select u.id into v_uid from admins a
    join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   where a.is_super order by u.id limit 1;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'no_super_admin');
  end if;
  perform set_config('request.jwt.claims',
            json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  select r.zone_id, r.id into v_zone, v_partner
    from region_partners r
   where coalesce(r.is_active, true) and r.zone_id is not null
   order by r.id limit 1;
  if v_zone is null then
    return jsonb_build_object('ok', false, 'error', 'no_zone_partner');
  end if;

  select p.id, p.zone_id into v_cust, v_nozone
    from pharmacy_profiles p
   where p.is_synthetic and p.approved
     and coalesce(p.is_deleted, false) = false
     and coalesce(p.status,'') <> 'suspended'
   order by p.id limit 1;
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'no_synthetic_customer');
  end if;
  -- The failed stop must land where notify_partner finds nobody.
  if exists (select 1 from region_partners r
              where r.zone_id = v_nozone and coalesce(r.is_active, true)) then
    select z.id into v_nozone from zones z
     where not exists (select 1 from region_partners r
                        where r.zone_id = z.id and coalesce(r.is_active, true))
     order by z.id limit 1;
  end if;

  select m.id into v_prod from public."MEDICINE" m order by m.id limit 1;

  -- ── seed 1. an order that stopped moving at 'accept' (SLA 30 min) ─────────
  -- placed_by_admin: the order-hours gate is a CUSTOMER rule, and this row is
  -- the proof placing it, not a pharmacy ordering at midnight.
  insert into orders (order_code, status, zone_id, customer_id, pharmacy_name,
                      created_at, is_synthetic, placed_by_admin)
  values ('C470-PROOF', 'pending', v_zone, v_cust, 'C470 proof pharmacy',
          now() - interval '6 hours', true, true)
  returning id into v_order;

  -- ── seed 2. a bill the renderer never produced ────────────────────────────
  insert into bill_jobs (order_id, idem_key, status, created_at, started_at)
  values (v_order, 'c470-proof-' || v_order::text, 'queued',
          now() - interval '9 hours', now() - interval '9 hours')
  returning id into v_bill;

  -- ── seed 3. a failed stop waiting on a reattempt, on its own order in a
  --    partnerless zone. Every hop is a transition the machine allows an
  --    admin to make.
  insert into orders (order_code, status, zone_id, customer_id, pharmacy_name,
                      created_at, is_synthetic, placed_by_admin)
  values ('C470-PROOF-D', 'accepted', v_nozone, v_cust, 'C470 proof pharmacy',
          now() - interval '2 days', true, true)
  returning id into v_order2;

  insert into deliveries (order_id, status, zone_id, created_at, is_synthetic)
  values (v_order2, 'assigned', v_nozone, now() - interval '2 days', true)
  returning id into v_del;
  update deliveries set status = 'out_for_delivery' where id = v_del;
  update deliveries set status = 'delivered'         where id = v_del;
  update deliveries set status = 'failed',
                        fail_reason = 'Shop closed',
                        next_attempt_on = (now() at time zone 'Asia/Kolkata')::date - 1
   where id = v_del;

  -- ── seed 4. a settlement period nobody acknowledged ───────────────────────
  insert into partner_settlement_periods
    (partner_id, zone_id, period_start, period_end, cadence, due_on, status,
     closed_at, computed_at, split_pct)
  values (v_partner, v_zone, (current_date - 37), (current_date - 30),
          'weekly', (current_date - 23), 'due',
          now() - interval '9 days', now() - interval '9 days', 0)
  returning id into v_period;

  -- ── seed 5. an impossible state: a line in a bag with no count ────────────
  insert into order_items (order_id, product_name, product_id, zone_id,
                           assigned_supplier, collect_locked, created_at)
  values (v_order, 'C470 PROOF ITEM', v_prod, v_zone, 'C470 PROOF SUPPLIER',
          true, now() - interval '6 hours')
  returning id into v_item;
  insert into bag_allocations (order_item_id, order_id, product_id,
                               assigned_supplier, bag_no, qty)
  values (v_item, v_order, v_prod, 'C470 PROOF SUPPLIER', 470, 1);

  v_sweep := public.ops_state_machine_sweep(500);

  -- ── every seeded stall surfaces ───────────────────────────────────────────
  select count(*) into v_n from public._exception_rows()
   where reason_code = 'order_stage_stalled' and ref_id = v_order::text || ':accept';
  v_checks := v_checks || public._c470_assert(
    'a stalled order surfaces at the stage its per-stage SLA names', v_n = 1);

  select count(*) into v_n from public._exception_rows()
   where reason_code = 'bill_unrendered' and ref_id = v_bill::text;
  v_checks := v_checks || public._c470_assert(
    'an unrendered bill surfaces', v_n = 1);

  select count(*) into v_n from public._exception_rows()
   where reason_code = 'delivery_reattempt_due' and ref_id = v_del::text;
  v_checks := v_checks || public._c470_assert(
    'a failed stop awaiting reattempt surfaces', v_n = 1);

  select count(*) into v_n from public._exception_rows()
   where reason_code = 'settlement_unacked' and ref_id = v_period::text;
  v_checks := v_checks || public._c470_assert(
    'an unacknowledged settlement surfaces', v_n = 1);

  select count(*) into v_n
    from public._exception_rows() r
    join ops_state_finding f on f.id::text = r.ref_id
   where r.reason_code = 'impossible_state'
     and f.rule_key = 'bagged_uncounted' and f.entity_id = v_item::text;
  v_checks := v_checks || public._c470_assert(
    'the state machine writes its finding into the same queue', v_n = 1);

  -- ── owner: a zone reason belongs to that zone's partner, an admin reason to
  --    the office. Never the other way round. ───────────────────────────────
  select case when x.owner_kind = 'admin' or r.zone_id is null then 'admin'
              else coalesce((select rp.partner_name from region_partners rp
                              where rp.zone_id = r.zone_id
                                and coalesce(rp.is_active, true)
                              order by rp.id limit 1), 'admin') end
    into v_owner
    from public._exception_rows() r
    join exception_reason x on x.reason_code = r.reason_code
   where r.reason_code = 'order_stage_stalled'
     and r.ref_id = v_order::text || ':accept';
  v_checks := v_checks || public._c470_assert(
    'the stalled order is owned by its zone partner, by name',
    v_owner = (select rp.partner_name from region_partners rp where rp.id = v_partner));

  select case when x.owner_kind = 'admin' then 'admin' else 'partner' end
    into v_owner
    from public._exception_rows() r
    join exception_reason x on x.reason_code = r.reason_code
   where r.reason_code = 'bill_unrendered' and r.ref_id = v_bill::text;
  v_checks := v_checks || public._c470_assert(
    'an unrendered bill is the office''s, not a zone''s', v_owner = 'admin');

  -- ── link: every seeded stall names a screen ───────────────────────────────
  select coalesce(nullif(x.action_route,''),
           (select m.route from exception_route_map m where m.class_key = r.action_ref),
           (select c.action_route from ops_board_class c where c.key = r.action_ref), '')
    into v_route
    from public._exception_rows() r
    join exception_reason x on x.reason_code = r.reason_code
   where r.reason_code = 'order_stage_stalled'
     and r.ref_id = v_order::text || ':accept';
  v_checks := v_checks || public._c470_assert(
    'the stalled order links to the screen that accepts it',
    v_route = 'customer_order');

  select count(*) into v_n
    from public._exception_rows() r
    join exception_reason x on x.reason_code = r.reason_code
   where r.ref_id in (v_bill::text, v_del::text, v_period::text)
     and coalesce(nullif(x.action_route,''),
           (select m.route from exception_route_map m where m.class_key = r.action_ref),
           '') <> '';
  v_checks := v_checks || public._c470_assert(
    'the bill, the stop and the settlement each link to a screen', v_n = 3);

  select count(*) into v_n
    from public._exception_rows() r
    join ops_state_finding f on f.id::text = r.ref_id
   where r.reason_code = 'impossible_state'
     and f.entity_id = v_item::text
     and exists (select 1 from exception_route_map m where m.class_key = r.action_ref);
  v_checks := v_checks || public._c470_assert(
    'the impossible state links to the surface that owns it', v_n = 1);

  -- Every route a reason can hand the shell is a route the shell knows.
  select count(*) into v_n from exception_route_map m
   where m.route <> ''
     and not exists (select 1 from feature_registry f
                      where f.route_key = m.route and f.is_active);
  v_checks := v_checks || public._c470_assert(
    'no exception points at a screen that does not exist', v_n = 0);

  -- ── auto-resolve: the bill renders, and the exception closes itself ───────
  insert into exception_state (id, reason_code, ref_id, status, zone_id)
  values ('bill_unrendered:' || v_bill::text, 'bill_unrendered', v_bill::text,
          'working', v_zone)
  on conflict (id) do update set status = 'working';

  update bill_jobs set rendered_at = now(), status = 'done',
                       bill_path = 'c470/proof.pdf'
   where id = v_bill;

  select count(*) into v_n from public._exception_rows()
   where reason_code = 'bill_unrendered' and ref_id = v_bill::text;
  v_checks := v_checks || public._c470_assert(
    'the rendered bill leaves the queue by itself', v_n = 0);

  v_auto := public.exceptions_autoresolve_sweep();

  select count(*) into v_n from exception_state
   where ref_id = v_bill::text and status = 'closed'
     and outcome_code = 'auto_resolved';
  v_checks := v_checks || public._c470_assert(
    'its worked row is recorded resolved by itself, not left open', v_n = 1);

  -- ── clean up ─────────────────────────────────────────────────────────────
  delete from exception_state
   where ref_id in (v_bill::text, v_del::text, v_period::text, v_item::text)
      or ref_id like v_order::text || '%';
  delete from ops_state_finding
   where entity_id in (v_item::text, v_del::text, v_order::text, v_order2::text);
  delete from bag_allocations where order_item_id = v_item;
  delete from order_items where id = v_item;
  delete from partner_settlement_periods where id = v_period;
  delete from deliveries where id = v_del;
  delete from bill_jobs where id = v_bill;
  delete from order_alert where order_id in (v_order, v_order2);
  delete from orders where id in (v_order, v_order2);

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_checks) c
                       where (c->>'ok')::boolean is not true),
    'checks', v_checks,
    'passed', (select count(*) from jsonb_array_elements(v_checks) c
                where (c->>'ok')::boolean),
    'total',  jsonb_array_length(v_checks),
    'sweep',  v_sweep,
    'autoresolve', v_auto);
end $function$;
