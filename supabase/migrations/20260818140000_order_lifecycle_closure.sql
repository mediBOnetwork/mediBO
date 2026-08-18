-- CHANGE #229 — close the order lifecycle.
--
-- Live data proved closure did not exist: 0 delivered orders, 0 delivery rows,
-- 0 supplier payments, order_items only ever pending/received, orders only
-- pending/accepted. Nothing ever reached a final state, so the supplier
-- matching scope never shrank and every old order stayed open forever.
--
-- What this migration adds, in one place:
--   * the two gate engines (_order_close_state / _supplier_settle_state) —
--     ONE source of truth for "is this closable" and "what is still blocking";
--   * the two executors (order_try_close / supplier_order_try_settle), which
--     only ever run from a trigger or the tick, never from a screen;
--   * order_lifecycle_tick(), on cron at an OFFSET schedule (never a bare
--     */N — minute-0 pile-ups took the DB's 60 connections down on 18 Aug);
--   * an admin override that REQUIRES a reason and logs it;
--   * a backfill REPORT that writes nothing;
--   * every display string, in order_closure_label — none in Dart.
--
-- Two deliberate state choices, both about not regressing existing scopes:
--
--   1. A closed customer order keeps fulfillment_status = 'shipped'. Twelve
--      RPCs scope open work with `fulfillment_status NOT IN ('shipped',
--      'cancelled')`; adding a thirteenth value would have silently re-opened
--      a delivered order inside rebuild_all_supplier_orders and
--      inquiry_buckets_today. Closure is expressed by orders.closed_at and by
--      orders.status = 'delivered', which order_status_chips.customer_status
--      already renders as a green "Delivered".
--
--   2. A settled supplier order takes status = 'closed', because
--      rebuild_all_supplier_orders and inquiry_to_supplier_orders already
--      exclude ('shipped','closed','cancelled') — so settling removes it from
--      the rebuild AND from the nightly delete sweep with no edits elsewhere.
--      settled_at carries the stamp.
--
-- And the supplier-side scope shrink the spec asked for is not a new filter:
-- bill_lines_from_scan() matches a scanned bill line against
-- `order_items ... fulfillment_state NOT IN ('shipped','cancelled')`. Marking
-- a settled supplier order's items 'shipped' is exactly what removes them
-- from bill matching.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Columns
-- ─────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists closed_at     timestamptz,
  add column if not exists closed_by     text,
  add column if not exists closed_reason text,
  add column if not exists close_mode    text;

alter table public.supplier_orders
  add column if not exists settled_at     timestamptz,
  add column if not exists settled_by     text,
  add column if not exists settled_reason text,
  add column if not exists settle_mode    text;

create index if not exists idx_orders_open_closure
  on public.orders (created_at desc) where closed_at is null;
create index if not exists idx_supplier_orders_open_settle
  on public.supplier_orders (order_date desc) where settled_at is null;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. Copy table — every string this feature renders
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.order_closure_label (
  key   text primary key,
  label text not null
);
alter table public.order_closure_label enable row level security;
drop policy if exists ocl_read on public.order_closure_label;
create policy ocl_read on public.order_closure_label for select using (true);

insert into public.order_closure_label(key,label) values
  ('screen.title',        'Order closure'),
  ('screen.subtitle',     'Orders and supplier orders close automatically. This is what each one is still waiting for.'),
  ('tab.blocked',         'Open orders'),
  ('tab.closed',          'Closed'),
  ('tab.sup_open',        'Open supplier orders'),
  ('tab.sup_settled',     'Settled'),
  ('empty.blocked',       'No open customer orders.'),
  ('empty.closed',        'No order has closed yet.'),
  ('empty.sup_open',      'No open supplier orders.'),
  ('empty.sup_settled',   'No supplier order has settled yet.'),
  ('retry',               'Try again'),
  ('gate.bill.label',     'Bill generated and sent'),
  ('gate.bill.done',      'Sent on WhatsApp'),
  ('gate.bill.pending',   'Bill not sent yet'),
  ('gate.pay.label',      'Payment received and verified'),
  ('gate.pay.done',       'Paid in full'),
  ('gate.pay.pending',    'Balance still due'),
  ('gate.pay.no_bill',    'Waiting for the bill'),
  ('gate.pack.label',     'Every item packed'),
  ('gate.pack.done',      'All items packed'),
  ('gate.pack.pending',   'Items still to pack'),
  ('gate.pack.no_items',  'No packable item on this order'),
  ('gate.deliver.label',  'Delivered with proof'),
  ('gate.deliver.done',   'Delivered'),
  ('gate.deliver.pending','Not delivered yet'),
  ('gate.deliver.none',   'No delivery raised yet'),
  ('gate.deliver.noproof','Delivered without proof captured'),
  ('gate.recv.label',     'Every billed item received and counted'),
  ('gate.recv.done',      'All items counted in'),
  ('gate.recv.pending',   'Items not counted in'),
  ('gate.recv.no_items',  'No item on this supplier order'),
  ('gate.disp.label',     'Disputes resolved'),
  ('gate.disp.done',      'No open dispute'),
  ('gate.disp.pending',   'Open disputes'),
  ('gate.supbill.label',  'Supplier bill fully paid'),
  ('gate.supbill.done',   'Settled in full'),
  ('gate.supbill.pending','Balance still due'),
  ('gate.supbill.nobill', 'No supplier bill imported yet'),
  ('status.closed',       'Closed'),
  ('status.settled',      'Settled'),
  ('status.blocked',      'Waiting'),
  ('status.ready',        'Ready to close'),
  ('status.ready_sup',    'Ready to settle'),
  ('closed.at',           'Closed'),
  ('settled.at',          'Settled'),
  ('blockers.one',        '1 thing still blocking'),
  ('blockers.many',       'things still blocking'),
  ('override.action',     'Close with a reason'),
  ('override.action_sup', 'Settle with a reason'),
  ('override.hint',       'Why is this being closed while something is still blocking? This is logged.'),
  ('override.required',   'A reason is required — at least 10 characters.'),
  ('override.confirm',    'Close order'),
  ('override.confirm_sup','Settle supplier order'),
  ('override.cancel',     'Cancel'),
  ('override.done',       'Closed with an override. Reason logged.'),
  ('override.done_sup',   'Settled with an override. Reason logged.'),
  ('override.badge',      'Override'),
  ('backfill.label',      'Would close today'),
  ('backfill.note',       'Nothing is backfilled automatically. This is a count only.'),
  ('backfill.orders',     'customer orders qualify'),
  ('backfill.suppliers',  'supplier orders qualify'),
  ('auto.note',           'Closure runs itself — from delivery, payment, packing and bill events, plus a sweep every 10 minutes.')
on conflict (key) do update set label = excluded.label;

create or replace function public._ocl(p_key text)
returns text language sql stable as $$
  select coalesce((select label from public.order_closure_label where key = p_key), p_key);
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Audit log — every close, every settle, every override, with its reason
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.order_closure_log (
  id                uuid primary key default gen_random_uuid(),
  at                timestamptz not null default now(),
  kind              text not null check (kind in ('order','supplier_order')),
  order_id          uuid,
  supplier_order_id uuid,
  event             text not null check (event in ('closed','settled')),
  mode              text not null check (mode in ('auto','override')),
  actor             text,
  reason            text,
  blockers          jsonb not null default '[]'::jsonb
);
create index if not exists idx_ocl_at on public.order_closure_log (at desc);
alter table public.order_closure_log enable row level security;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. Gate engine — customer order
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._order_close_state(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  o orders%rowtype;
  v_bill jsonb; v_net numeric := 0; v_paid numeric := 0;
  v_wa timestamptz;
  n_pack_total int := 0; n_pack_done int := 0;
  n_del_done int := 0; n_del_open int := 0; n_del_proof int := 0;
  g_bill boolean; g_pay boolean; g_pack boolean; g_del boolean;
  v_gates jsonb; v_block jsonb; n_block int;
begin
  select * into o from orders where id = p_order_id;
  if not found then return jsonb_build_object('ok',false,'error','order_not_found'); end if;

  -- 1. bill generated AND sent on WhatsApp
  select max(wa_bill_sent_at) into v_wa from bill_jobs where order_id = p_order_id;
  g_bill := (o.cust_bill_path is not null) and (v_wa is not null);

  -- 2. full payment received and VERIFIED, nothing remaining
  v_bill := public.customer_bill(p_order_id);
  v_net  := coalesce((v_bill->'totals'->>'net_payable')::numeric, 0);
  select coalesce(sum(amount),0) into v_paid
    from payment_claims where order_id = p_order_id and status = 'verified';
  g_pay := coalesce((v_bill->>'ready')::boolean,false) and v_paid >= v_net;

  -- 3. every item packed (cancelled / unfulfillable lines are not packable)
  select count(*), count(*) filter (where coalesce(packed,false))
    into n_pack_total, n_pack_done
    from order_items
   where order_id = p_order_id
     and coalesce(fulfillment_state,'') not in ('cancelled','unfillable')
     and coalesce(unfulfillable,false) = false;
  g_pack := n_pack_total > 0 and n_pack_done = n_pack_total;

  -- 4. delivered, with proof, and nothing still out
  select count(*) filter (where d.status = 'delivered'),
         count(*) filter (where coalesce(d.status,'') not in ('delivered','failed','rto','cancelled')),
         count(*) filter (where d.status = 'delivered'
                            and (d.otp_verified_at is not null
                              or coalesce(d.proof_photo_path,'') <> ''
                              or coalesce(d.signature_path,'')   <> ''
                              or coalesce(d.proof_method,'')     <> ''))
    into n_del_done, n_del_open, n_del_proof
    from deliveries d where d.order_id = p_order_id;
  g_del := n_del_done > 0 and n_del_open = 0 and n_del_proof > 0;

  v_gates := jsonb_build_array(
    jsonb_build_object('key','bill','label', public._ocl('gate.bill.label'),
      'done', g_bill, 'tone', case when g_bill then 'success' else 'warning' end,
      'status_label', case when g_bill then public._ocl('gate.bill.done')
                           else public._ocl('gate.bill.pending') end,
      'detail', case when v_wa is not null
                     then to_char(v_wa at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM') end),
    jsonb_build_object('key','pay','label', public._ocl('gate.pay.label'),
      'done', g_pay, 'tone', case when g_pay then 'success' else 'warning' end,
      'status_label', case when g_pay then public._ocl('gate.pay.done')
                           when not coalesce((v_bill->>'ready')::boolean,false)
                             then public._ocl('gate.pay.no_bill')
                           else public._ocl('gate.pay.pending') end,
      'detail', case when coalesce((v_bill->>'ready')::boolean,false)
                     then public.inr_money(v_paid) || ' / ' || public.inr_money(v_net) end),
    jsonb_build_object('key','pack','label', public._ocl('gate.pack.label'),
      'done', g_pack, 'tone', case when g_pack then 'success' else 'warning' end,
      'status_label', case when g_pack then public._ocl('gate.pack.done')
                           when n_pack_total = 0 then public._ocl('gate.pack.no_items')
                           else public._ocl('gate.pack.pending') end,
      'detail', n_pack_done::text || ' / ' || n_pack_total::text),
    jsonb_build_object('key','deliver','label', public._ocl('gate.deliver.label'),
      'done', g_del, 'tone', case when g_del then 'success' else 'warning' end,
      'status_label', case when g_del then public._ocl('gate.deliver.done')
                           when n_del_done + n_del_open = 0 then public._ocl('gate.deliver.none')
                           when n_del_done > 0 and n_del_proof = 0 then public._ocl('gate.deliver.noproof')
                           else public._ocl('gate.deliver.pending') end,
      'detail', case when n_del_open > 0 then n_del_open::text end));

  select coalesce(jsonb_agg(g), '[]'::jsonb) into v_block
    from jsonb_array_elements(v_gates) g where (g->>'done')::boolean is not true;
  n_block := jsonb_array_length(v_block);

  return jsonb_build_object(
    'ok', true,
    'kind', 'order',
    'id', p_order_id,
    'order_code', coalesce(o.order_code,''),
    'buyer_label', coalesce(o.pharmacy_name,''),
    'placed_label', to_char(o.created_at at time zone 'Asia/Kolkata','DD Mon yyyy, HH12:MI AM'),
    'closed', (o.closed_at is not null),
    'closed_at', o.closed_at,
    'closed_label', case when o.closed_at is not null
      then public._ocl('closed.at') || ' ' ||
           to_char(o.closed_at at time zone 'Asia/Kolkata','DD Mon yyyy, HH12:MI AM') end,
    'closed_reason', o.closed_reason,
    'override', (coalesce(o.close_mode,'') = 'override'),
    'override_badge', case when coalesce(o.close_mode,'') = 'override'
                           then public._ocl('override.badge') end,
    'can_close', (n_block = 0),
    'blocker_count', n_block,
    'status_label', case when o.closed_at is not null then public._ocl('status.closed')
                         when n_block = 0 then public._ocl('status.ready')
                         else public._ocl('status.blocked') end,
    'status_tone', case when o.closed_at is not null then 'success'
                        when n_block = 0 then 'info' else 'warning' end,
    'blockers_label', case when n_block = 1 then public._ocl('blockers.one')
                           when n_block > 1 then n_block::text || ' ' || public._ocl('blockers.many') end,
    'gates', v_gates,
    'blockers', v_block);
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Gate engine — supplier order
--
-- A supplier order's lines are order_items of the SAME supplier on the SAME
-- IST day — the exact pairing rebuild_all_supplier_orders() builds them from.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._supplier_settle_state(p_supplier_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  so supplier_orders%rowtype;
  v_day date;
  n_items int := 0; n_counted int := 0; n_disp int := 0;
  v_panel jsonb; v_rem numeric; v_anybill boolean;
  g_recv boolean; g_disp boolean; g_bill boolean;
  v_gates jsonb; v_block jsonb; n_block int;
begin
  select * into so from supplier_orders where id = p_supplier_order_id;
  if not found then return jsonb_build_object('ok',false,'error','supplier_order_not_found'); end if;
  v_day := coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date);

  -- 1. every billed item physically received AND counted (received_locked)
  select count(*),
         count(*) filter (where coalesce(oi.fulfillment_state,'') in ('received','shipped')
                            and coalesce(oi.received_locked,false))
    into n_items, n_counted
    from order_items oi
    join orders o on o.id = oi.order_id
   where oi.assigned_supplier = so.supplier_name
     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
     and coalesce(oi.fulfillment_state,'') not in ('cancelled','unfillable')
     and coalesce(oi.unfulfillable,false) = false;
  g_recv := n_items > 0 and n_counted = n_items;

  -- 2. every dispute resolved / recounted / adjusted
  select count(*) into n_disp
    from supplier_disputes d
   where coalesce(d.status,'') not in ('resolved','cancelled')
     and d.order_item_id in (
       select oi.id from order_items oi join orders o on o.id = oi.order_id
        where oi.assigned_supplier = so.supplier_name
          and (o.created_at at time zone 'Asia/Kolkata')::date = v_day);
  g_disp := (n_disp = 0);

  -- 3. supplier bill imported AND paid off (bill total + adjustments − payments)
  v_panel   := public.sup_order_bill_panel(p_supplier_order_id);
  v_anybill := coalesce((v_panel->>'any_bill_imported')::boolean, false);
  v_rem     := nullif(v_panel->>'remaining_due','')::numeric;
  g_bill    := v_anybill and coalesce(v_rem, 1) <= 0;

  v_gates := jsonb_build_array(
    jsonb_build_object('key','recv','label', public._ocl('gate.recv.label'),
      'done', g_recv, 'tone', case when g_recv then 'success' else 'warning' end,
      'status_label', case when g_recv then public._ocl('gate.recv.done')
                           when n_items = 0 then public._ocl('gate.recv.no_items')
                           else public._ocl('gate.recv.pending') end,
      'detail', n_counted::text || ' / ' || n_items::text),
    jsonb_build_object('key','disputes','label', public._ocl('gate.disp.label'),
      'done', g_disp, 'tone', case when g_disp then 'success' else 'danger' end,
      'status_label', case when g_disp then public._ocl('gate.disp.done')
                           else public._ocl('gate.disp.pending') end,
      'detail', case when n_disp > 0 then n_disp::text end),
    jsonb_build_object('key','supbill','label', public._ocl('gate.supbill.label'),
      'done', g_bill, 'tone', case when g_bill then 'success' else 'warning' end,
      'status_label', case when g_bill then public._ocl('gate.supbill.done')
                           when not v_anybill then public._ocl('gate.supbill.nobill')
                           else public._ocl('gate.supbill.pending') end,
      'detail', case when v_rem is not null then public.inr_money(v_rem) end));

  select coalesce(jsonb_agg(g), '[]'::jsonb) into v_block
    from jsonb_array_elements(v_gates) g where (g->>'done')::boolean is not true;
  n_block := jsonb_array_length(v_block);

  return jsonb_build_object(
    'ok', true,
    'kind', 'supplier_order',
    'id', p_supplier_order_id,
    'order_code', coalesce(so.order_code,''),
    'buyer_label', coalesce(so.supplier_name,''),
    'placed_label', to_char(coalesce(so.created_at, now()) at time zone 'Asia/Kolkata','DD Mon yyyy, HH12:MI AM'),
    'closed', (so.settled_at is not null),
    'closed_at', so.settled_at,
    'closed_label', case when so.settled_at is not null
      then public._ocl('settled.at') || ' ' ||
           to_char(so.settled_at at time zone 'Asia/Kolkata','DD Mon yyyy, HH12:MI AM') end,
    'closed_reason', so.settled_reason,
    'override', (coalesce(so.settle_mode,'') = 'override'),
    'override_badge', case when coalesce(so.settle_mode,'') = 'override'
                           then public._ocl('override.badge') end,
    'can_close', (n_block = 0),
    'blocker_count', n_block,
    'status_label', case when so.settled_at is not null then public._ocl('status.settled')
                         when n_block = 0 then public._ocl('status.ready_sup')
                         else public._ocl('status.blocked') end,
    'status_tone', case when so.settled_at is not null then 'success'
                        when n_block = 0 then 'info' else 'warning' end,
    'blockers_label', case when n_block = 1 then public._ocl('blockers.one')
                           when n_block > 1 then n_block::text || ' ' || public._ocl('blockers.many') end,
    'gates', v_gates,
    'blockers', v_block);
end $fn$;
