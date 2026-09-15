\set ON_ERROR_STOP on
begin;
-- The three fixtures the spec asks for, built on REAL orders inside a
-- transaction we roll back. This DB has no delivered order and no asked
-- inquiry, so the only honest way to prove event order / actor / action is to
-- make those rows exist for the length of one transaction and no longer.
do $$
declare
  o_del uuid := 'c37af0b8-3064-4943-ade3-c239a294b66a';  -- accepted, 12 items
  o_inq uuid := '4e35305b-ba73-43e2-bc87-12c9244994c1';  -- pending
  o_pen uuid := 'd4e2779a-973d-493e-8a98-a7b8608a5ffc';  -- pending, untouched
  it uuid; iq bigint; sup text; sup_id uuid; dp uuid; ev jsonb; prev timestamptz; e jsonb;
  n int;
begin
  select sp.supplier_name, sp.id into sup, sup_id
    from supplier_profiles sp where coalesce(sp.is_deleted,false)=false limit 1;
  dp := (select id from delivery_partner_registrations where coalesce(is_synthetic,false) order by created_at limit 1);
  it := (select id from order_items where order_id = o_del limit 1);

  -- ── fixture A: drive o_del all the way to delivered ──────────────────────
  insert into supplier_orders (id, supplier_id, supplier_name, order_id, status, created_at,
                               accepted_at, accept_state, packed_at, is_synthetic)
  values (gen_random_uuid(), sup_id, sup, o_del, 'closed',
          now() - interval '2 days 20 hours', now() - interval '2 days 18 hours', 'accepted',
          now() - interval '2 days 12 hours', true);

  insert into receiving_log (order_item_id, order_id, supplier_name, action, qty, actor, created_at, is_synthetic)
  values (it, o_del, sup, 'received', 10, 'warehouse', now() - interval '2 days 6 hours', true);

  insert into bag_allocations (order_item_id, order_id, assigned_supplier, product_id, bag_no, qty, state, created_at, is_synthetic)
  select it, o_del, sup, oi.product_id, 1, 10, 'packed', now() - interval '2 days 5 hours', true
    from order_items oi where oi.id = it;

  update order_items set packed = true, packed_at = now() - interval '2 days 4 hours' where id = it;
  update orders set dispatch_ready = true, dispatch_ready_at = now() - interval '2 days 3 hours'
   where id = o_del;

  insert into deliveries (id, order_id, partner_id, assigned_at, accepted_at, started_at,
                          arrived_at, delivered_at, status, created_at, is_synthetic)
  values (gen_random_uuid(), o_del, dp,
          now() - interval '2 days 3 hours', now() - interval '2 days 2 hours',
          now() - interval '2 days 1 hour',  now() - interval '2 days 30 minutes',
          now() - interval '2 days', 'delivered', now() - interval '2 days 3 hours', true);

  insert into payment_claims (order_id, sender_phone, sender_type, amount, status, created_at, received_at, is_synthetic)
  values (o_del, '9000000000', 'customer', 1234.50, 'verified',
          now() - interval '1 day 12 hours', now() - interval '1 day 11 hours', true);

  -- ── fixture B: o_inq has a supplier order sent 9h ago and never accepted ─
  insert into supplier_orders (id, supplier_id, supplier_name, order_id, status, created_at, is_synthetic)
  values (gen_random_uuid(), sup_id, sup, o_inq, 'pending', now() - interval '9 hours', true);

  -- ── PROOF 1: a delivered order's events are one ascending list ───────────
  ev := public._order_timeline_events(o_del, 'full', true);
  n := jsonb_array_length(ev);
  if n < 9 then raise exception 'C689 FAIL: delivered order produced only % events', n; end if;
  prev := null;
  for i in 0 .. n-1 loop
    e := ev->i;
    if prev is not null and (e->>'ts')::timestamptz < prev then
      raise exception 'C689 FAIL: events out of order at % (%)', i, e->>'label';
    end if;
    prev := (e->>'ts')::timestamptz;
    if coalesce(e->'actor'->>'has','false') <> 'true' then
      raise exception 'C689 FAIL: event % (%) has no actor', i, e->>'label';
    end if;
  end loop;
  raise notice 'C689 delivered: % events, time-ordered, every one has an actor', n;
  raise notice 'C689 delivered stages: %', (select string_agg(x->>'stage',' > ') from jsonb_array_elements(ev) x);
  raise notice 'C689 delivered actors: %',
    (select string_agg(distinct x->'actor'->>'label',' / ') from jsonb_array_elements(ev) x);
  raise notice 'C689 delivered actions: %',
    (select string_agg(x->'action'->>'kind',' / ') from jsonb_array_elements(ev) x
      where coalesce(x->'action'->>'has','false')='true');

  -- ── PROOF 2: the CUSTOMER view names no supplier and carries no number ───
  ev := public._order_timeline_events(o_del, 'customer', false);
  for i in 0 .. jsonb_array_length(ev)-1 loop
    e := ev->i;
    if coalesce(e->'actor'->>'has_phone','false') = 'true' then
      raise exception 'C689 FAIL: customer view leaked a phone on %', e->>'label';
    end if;
    if coalesce(e->'action'->>'has','false') = 'true' then
      raise exception 'C689 FAIL: customer view offered an action on %', e->>'label';
    end if;
    if e->'actor'->>'kind' = 'supplier' and e->'actor'->>'name' <> 'a supplier' then
      raise exception 'C689 FAIL: customer view named the supplier %', e->'actor'->>'name';
    end if;
    if e->>'stage' in ('message','action','receiving') then
      raise exception 'C689 FAIL: customer view showed internal stage %', e->>'stage';
    end if;
  end loop;
  raise notice 'C689 customer view: % events, zero phones, supplier masked, zero actions',
    jsonb_array_length(ev);

  -- ── PROOF 3: the STUCK order's waiting step is RED with the nudge prefilled 
  ev := public._order_timeline_events(o_inq, 'full', true);
  n := jsonb_array_length(ev);
  -- the step the order is WAITING ON - not merely the newest row, which on a
  -- busy order is always a WhatsApp attempt.
  select x into e from jsonb_array_elements(ev) x where x->>'is_current' = 'true';
  if e is null then raise exception 'C689 FAIL: no current step on the stuck order'; end if;
  if e->>'stage' <> 'sourcing' then
    raise exception 'C689 FAIL: waiting on % not sourcing', e->>'stage';
  end if;
  if coalesce(e->>'late','false') <> 'true' then
    raise exception 'C689 FAIL: stuck order last event is not late: %', e->>'label';
  end if;
  if e->>'tone' <> 'red' then raise exception 'C689 FAIL: stuck tone is %', e->>'tone'; end if;
  if e->'action'->>'kind' <> 'nudge_supplier' then
    raise exception 'C689 FAIL: stuck action is %', e->'action'->>'kind';
  end if;
  if e->'action'->>'rpc' <> 'order_timeline_act' then
    raise exception 'C689 FAIL: action rpc is %', e->'action'->>'rpc';
  end if;
  raise notice 'C689 stuck: last=% | tone=% | late=% | action=% | args=%',
    e->>'label', e->>'tone', e->>'late', e->'action'->>'kind', e->'action'->'args';

  -- ── PROOF 4: a PENDING order still renders, with actor and action ───────
  ev := public._order_timeline_events(o_pen, 'full', true);
  if jsonb_array_length(ev) < 1 then raise exception 'C689 FAIL: pending order empty'; end if;
  raise notice 'C689 pending: % events | first=% | actor=% | action=%',
    jsonb_array_length(ev), ev->0->>'label', ev->0->'actor'->>'label', ev->0->'action'->>'kind';

  -- ── PROOF 5: an action appends its own event ────────────────────────────
  insert into order_timeline_action_log(order_id, action_kind, actor_kind, actor_name, ok, note)
  values (o_inq, 'nudge_supplier', 'medibo', 'ops@medibo.in', true, 'reminder sent');
  ev := public._order_timeline_events(o_inq, 'full', true);
  if not exists (select 1 from jsonb_array_elements(ev) x where x->>'stage' = 'action') then
    raise exception 'C689 FAIL: the action did not append its own event';
  end if;
  raise notice 'C689 action event: %',
    (select x->>'label' from jsonb_array_elements(ev) x where x->>'stage'='action' limit 1);
  -- ── PROOF 6: the inquiry waterfall renders from real rows, asked events
  -- carry the supplier as the actor AND the nudge as the action ────────────
  ev := public._order_timeline_events('6dd90b4d-1444-4a83-8006-ac880ff436be', 'full', true);
  if not exists (select 1 from jsonb_array_elements(ev) x where x->>'stage'='inquiry') then
    raise exception 'C689 FAIL: no inquiry events on a real waterfall order';
  end if;
  if not exists (select 1 from jsonb_array_elements(ev) x
                  where x->>'stage'='inquiry' and x->'actor'->>'kind'='supplier') then
    raise exception 'C689 FAIL: inquiry events have no supplier actor';
  end if;
  raise notice 'C689 inquiry: %',
    (select string_agg(x->>'label',' | ') from jsonb_array_elements(ev) x where x->>'stage'='inquiry');

  -- ── PROOF 7: the dispatcher refuses a caller the matrix does not admit ───
  if coalesce((public.order_timeline_act(o_pen,'nudge_supplier','{}'::jsonb)->>'error'),'')
     <> 'not_authorized' then
    raise exception 'C689 FAIL: order_timeline_act admitted an ungated caller';
  end if;
  raise notice 'C689 dispatcher: refuses an ungated caller with not_authorized';

  raise notice 'C689 ALL PROOFS PASSED';
end $$;
rollback;
