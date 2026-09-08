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

alter table public.pending_bills
  add column if not exists settled_at        timestamptz,
  add column if not exists settled_order_id  uuid;

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

-- ─────────────────────────────────────────────────────────────────────────
-- 6. Executors. These are the ONLY writers of a final state. They are called
--    from triggers and from the tick — never from a screen.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.order_try_close(
  p_order_id uuid,
  p_mode     text default 'auto',
  p_actor    text default null,
  p_reason   text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare st jsonb; o orders%rowtype;
begin
  select * into o from orders where id = p_order_id;
  if not found then return jsonb_build_object('ok',false,'error','order_not_found'); end if;
  if o.closed_at is not null then
    return public._order_close_state(p_order_id) || jsonb_build_object('already', true);
  end if;
  if coalesce(o.status,'') in ('cancelled','rejected')
     or coalesce(o.fulfillment_status,'') = 'cancelled' then
    return jsonb_build_object('ok',true,'closed',false,'skipped','cancelled');
  end if;

  st := public._order_close_state(p_order_id);
  if coalesce((st->>'ok')::boolean,false) is not true then return st; end if;

  -- Never force-close on missing data. A blocked order stays open, with its
  -- reasons on the record, unless a human overrides it WITH a reason.
  if p_mode <> 'override' and coalesce((st->>'can_close')::boolean,false) is not true then
    return st;
  end if;

  -- Re-entry guard: the writes below fire order_items / orders triggers that
  -- would otherwise call straight back into this function.
  perform set_config('medibo.closing', '1', true);

  update orders
     set status            = 'delivered',
         fulfillment_status= case when coalesce(fulfillment_status,'') = 'cancelled'
                                  then fulfillment_status else 'shipped' end,
         shipped_at        = coalesce(shipped_at, now()),
         closed_at         = now(),
         closed_by         = coalesce(p_actor, 'system'),
         closed_reason     = p_reason,
         close_mode        = case when p_mode = 'override' then 'override' else 'auto' end
   where id = p_order_id;

  -- orders_status_to_order_items_trg already carries status='delivered' down
  -- to every line; this is the fulfilment side of the same finality.
  update order_items
     set fulfillment_state = 'shipped'
   where order_id = p_order_id
     and coalesce(fulfillment_state,'') not in ('cancelled','shipped');

  insert into order_closure_log(kind, order_id, event, mode, actor, reason, blockers)
  values ('order', p_order_id, 'closed',
          case when p_mode = 'override' then 'override' else 'auto' end,
          coalesce(p_actor,'system'), p_reason, coalesce(st->'blockers','[]'::jsonb));

  perform set_config('medibo.closing', '', true);
  return public._order_close_state(p_order_id) || jsonb_build_object('just_closed', true);
end $fn$;

create or replace function public.supplier_order_try_settle(
  p_supplier_order_id uuid,
  p_mode   text default 'auto',
  p_actor  text default null,
  p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare st jsonb; so supplier_orders%rowtype; v_day date; v_sid uuid;
begin
  select * into so from supplier_orders where id = p_supplier_order_id;
  if not found then return jsonb_build_object('ok',false,'error','supplier_order_not_found'); end if;
  if so.settled_at is not null then
    return public._supplier_settle_state(p_supplier_order_id) || jsonb_build_object('already', true);
  end if;
  if coalesce(so.status,'') = 'cancelled' then
    return jsonb_build_object('ok',true,'closed',false,'skipped','cancelled');
  end if;

  st := public._supplier_settle_state(p_supplier_order_id);
  if coalesce((st->>'ok')::boolean,false) is not true then return st; end if;
  if p_mode <> 'override' and coalesce((st->>'can_close')::boolean,false) is not true then
    return st;
  end if;

  perform set_config('medibo.closing', '1', true);
  v_day := coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date);
  v_sid := coalesce(so.supplier_id,
             (select id from supplier_profiles where lower(supplier_name)=lower(so.supplier_name) limit 1));

  update supplier_orders
     set status         = 'closed',
         settled_at     = now(),
         settled_by     = coalesce(p_actor,'system'),
         settled_reason = p_reason,
         settle_mode    = case when p_mode = 'override' then 'override' else 'auto' end
   where id = p_supplier_order_id;

  -- The bill itself is stamped settled — same supplier, same IST day, which is
  -- the exact pairing sup_order_bill_panel() totals the money from. A NEW
  -- column, not a new pending_bills.status: every reader detects an imported
  -- bill as `imported_at is not null OR lower(status)='imported'`, so
  -- overwriting status would un-import the bill the moment it was paid.
  update pending_bills pb
     set settled_at = now(), settled_order_id = p_supplier_order_id
   where pb.settled_at is null
     and lower(coalesce(pb.verdict,'')) <> 'fake'
     and (pb.imported_at is not null or lower(coalesce(pb.status,'')) = 'imported')
     and (pb.received_at at time zone 'Asia/Kolkata')::date = v_day
     and ((v_sid is not null and pb.supplier_id = v_sid::text)
       or (pb.supplier_id is null and pb.supplier_name is not null
           and lower(pb.supplier_name) = lower(so.supplier_name)));

  -- 'shipped' IS the removal from the supplier open-order scope: it is the
  -- filter bill_lines_from_scan() matches against, and the one every open
  -- supplier surface uses.
  update order_items oi
     set fulfillment_state = 'shipped'
    from orders o
   where o.id = oi.order_id
     and oi.assigned_supplier = so.supplier_name
     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
     and coalesce(oi.fulfillment_state,'') not in ('cancelled','shipped');

  insert into order_closure_log(kind, supplier_order_id, event, mode, actor, reason, blockers)
  values ('supplier_order', p_supplier_order_id, 'settled',
          case when p_mode = 'override' then 'override' else 'auto' end,
          coalesce(p_actor,'system'), p_reason, coalesce(st->'blockers','[]'::jsonb));

  perform set_config('medibo.closing', '', true);
  return public._supplier_settle_state(p_supplier_order_id) || jsonb_build_object('just_closed', true);
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. A closed order's fulfilment status is final — recompute must not undo it.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.recompute_order_fulfillment(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $fn$
DECLARE
  n_total int; n_pending int; n_in_transit int; n_problem int;
  n_shipped int; n_cancelled int;
  v_status text; v_closed timestamptz;
BEGIN
  -- CHANGE #229: a closed order keeps the status it closed with. Without this
  -- guard any later item write would recompute a delivered order back open.
  SELECT closed_at, fulfillment_status INTO v_closed, v_status FROM orders WHERE id = p_order_id;
  IF v_closed IS NOT NULL THEN RETURN v_status; END IF;

  SELECT
    count(*),
    count(*) FILTER (WHERE fulfillment_state = 'pending'),
    count(*) FILTER (WHERE fulfillment_state IN ('received','short') AND at_warehouse = false),
    count(*) FILTER (WHERE fulfillment_state IN ('wrong','not_coming')),
    count(*) FILTER (WHERE fulfillment_state = 'shipped'),
    count(*) FILTER (WHERE fulfillment_state = 'cancelled')
  INTO n_total, n_pending, n_in_transit, n_problem, n_shipped, n_cancelled
  FROM order_items WHERE order_id = p_order_id;

  IF n_total = 0 THEN
    v_status := 'open';
  ELSIF n_shipped = n_total THEN
    v_status := 'shipped';
  ELSIF n_shipped > 0 THEN
    v_status := 'partially_shipped';
  ELSIF n_cancelled = n_total THEN
    v_status := 'cancelled';
  ELSIF n_pending > 0 THEN
    IF n_pending = n_total THEN v_status := 'open'; ELSE v_status := 'collecting'; END IF;
  ELSIF n_in_transit > 0 THEN
    v_status := 'in_transit';
  ELSE
    IF n_problem > 0 THEN v_status := 'partial_ready'; ELSE v_status := 'ready'; END IF;
  END IF;

  UPDATE orders SET fulfillment_status = v_status WHERE id = p_order_id;
  RETURN v_status;
END;
$fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. Event triggers. Every real closure event pokes the engine; the engine
--    decides. None of these can close anything on their own.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._closure_busy()
returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('medibo.closing', true), ''), '0') = '1';
$$;

create or replace function public._trg_close_on_delivery()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if public._closure_busy() then return NEW; end if;
  if NEW.status = 'delivered' and NEW.order_id is not null then
    begin perform public.order_try_close(NEW.order_id, 'auto', 'trigger:delivery');
    exception when others then null; end;
  end if;
  return NEW;
end $fn$;

drop trigger if exists trg_close_on_delivery on public.deliveries;
create trigger trg_close_on_delivery
  after insert or update of status on public.deliveries
  for each row execute function public._trg_close_on_delivery();

create or replace function public._trg_close_on_payment()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if public._closure_busy() then return NEW; end if;
  if NEW.status = 'verified' and NEW.order_id is not null then
    begin perform public.order_try_close(NEW.order_id, 'auto', 'trigger:payment');
    exception when others then null; end;
  end if;
  return NEW;
end $fn$;

-- Both columns: a claim is very often VERIFIED before
-- payment_claim_autolink() attaches it to an order, and that later write
-- touches order_id, not status.
drop trigger if exists trg_close_on_payment on public.payment_claims;
create trigger trg_close_on_payment
  after insert or update of status, order_id on public.payment_claims
  for each row execute function public._trg_close_on_payment();

create or replace function public._trg_close_on_bill_sent()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if public._closure_busy() then return NEW; end if;
  if NEW.wa_bill_sent_at is not null
     and OLD.wa_bill_sent_at is distinct from NEW.wa_bill_sent_at
     and NEW.order_id is not null then
    begin perform public.order_try_close(NEW.order_id, 'auto', 'trigger:bill_sent');
    exception when others then null; end;
  end if;
  return NEW;
end $fn$;

drop trigger if exists trg_close_on_bill_sent on public.bill_jobs;
create trigger trg_close_on_bill_sent
  after update of wa_bill_sent_at on public.bill_jobs
  for each row execute function public._trg_close_on_bill_sent();

create or replace function public._trg_close_on_packed()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if public._closure_busy() then return NEW; end if;
  -- Only when THIS line was the last unpacked one. Packing is a per-row write
  -- over a whole order; without this check every line would run the (costly)
  -- customer_bill() gate and only the last of them could ever win.
  if coalesce(NEW.packed,false)
     and coalesce(OLD.packed,false) is distinct from coalesce(NEW.packed,false)
     and not exists (select 1 from order_items oi
                      where oi.order_id = NEW.order_id
                        and coalesce(oi.fulfillment_state,'') not in ('cancelled','unfillable')
                        and coalesce(oi.unfulfillable,false) = false
                        and coalesce(oi.packed,false) = false) then
    begin perform public.order_try_close(NEW.order_id, 'auto', 'trigger:packed');
    exception when others then null; end;
  end if;
  return NEW;
end $fn$;

drop trigger if exists trg_close_on_packed on public.order_items;
create trigger trg_close_on_packed
  after update of packed on public.order_items
  for each row execute function public._trg_close_on_packed();

create or replace function public._trg_settle_on_supplier_event()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_id uuid;
begin
  if public._closure_busy() then return NEW; end if;
  if TG_TABLE_NAME = 'supplier_payments' then
    v_id := NEW.supplier_order_id;
  else
    -- a dispute: settle the supplier order its line belongs to
    select so.id into v_id
      from supplier_disputes d
      join order_items oi on oi.id = d.order_item_id
      join orders o on o.id = oi.order_id
      join supplier_orders so
        on so.supplier_name = oi.assigned_supplier
       and so.order_date = (o.created_at at time zone 'Asia/Kolkata')::date
     where d.id = NEW.id
     order by so.created_at limit 1;
  end if;
  if v_id is not null then
    begin perform public.supplier_order_try_settle(v_id, 'auto', 'trigger:' || TG_TABLE_NAME);
    exception when others then null; end;
  end if;
  return NEW;
end $fn$;

drop trigger if exists trg_settle_on_supplier_payment on public.supplier_payments;
create trigger trg_settle_on_supplier_payment
  after insert on public.supplier_payments
  for each row execute function public._trg_settle_on_supplier_event();

drop trigger if exists trg_settle_on_dispute_resolved on public.supplier_disputes;
create trigger trg_settle_on_dispute_resolved
  after update of status on public.supplier_disputes
  for each row when (NEW.status in ('resolved','cancelled'))
  execute function public._trg_settle_on_supplier_event();

-- ─────────────────────────────────────────────────────────────────────────
-- 9. The sweep. Triggers catch the event that happens to be last; this
--    catches everything else (a bill imported by an edge function, a counted
--    line, a dispute adjusted straight in SQL).
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.order_lifecycle_tick(p_max int default 100)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare r record; v_o int := 0; v_s int := 0; v_seen_o int := 0; v_seen_s int := 0;
begin
  -- Customer orders: pre-filter on the two CHEAP gates (delivered + packed)
  -- before touching customer_bill(), which is the expensive one. The DB has
  -- ~1 GB of RAM; a sweep that bills every open order every 10 minutes is how
  -- you take it down.
  for r in
    select o.id
      from orders o
     where o.closed_at is null
       and coalesce(o.status,'') not in ('cancelled','rejected')
       and coalesce(o.fulfillment_status,'') <> 'cancelled'
       and exists (select 1 from deliveries d
                    where d.order_id = o.id and d.status = 'delivered')
       and not exists (select 1 from deliveries d
                        where d.order_id = o.id
                          and coalesce(d.status,'') not in ('delivered','failed','rto','cancelled'))
       and not exists (select 1 from order_items oi
                        where oi.order_id = o.id
                          and coalesce(oi.fulfillment_state,'') not in ('cancelled','unfillable')
                          and coalesce(oi.unfulfillable,false) = false
                          and coalesce(oi.packed,false) = false)
     order by o.created_at
     limit p_max
  loop
    v_seen_o := v_seen_o + 1;
    if coalesce((public.order_try_close(r.id, 'auto', 'tick')->>'just_closed')::boolean,false) then
      v_o := v_o + 1;
    end if;
  end loop;

  -- Supplier orders: pre-filter on counted-in lines and no open dispute.
  for r in
    select so.id
      from supplier_orders so
     where so.settled_at is null
       and coalesce(so.status,'') not in ('closed','shipped','cancelled')
       and not exists (
         select 1 from order_items oi join orders o on o.id = oi.order_id
          where oi.assigned_supplier = so.supplier_name
            and (o.created_at at time zone 'Asia/Kolkata')::date =
                coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date)
            and coalesce(oi.fulfillment_state,'') not in ('cancelled','unfillable')
            and coalesce(oi.unfulfillable,false) = false
            and (coalesce(oi.fulfillment_state,'') not in ('received','shipped')
                 or coalesce(oi.received_locked,false) = false))
     order by so.order_date
     limit p_max
  loop
    v_seen_s := v_seen_s + 1;
    if coalesce((public.supplier_order_try_settle(r.id, 'auto', 'tick')->>'just_closed')::boolean,false) then
      v_s := v_s + 1;
    end if;
  end loop;

  return jsonb_build_object('ok',true,
    'orders_examined', v_seen_o, 'orders_closed', v_o,
    'supplier_orders_examined', v_seen_s, 'supplier_orders_settled', v_s);
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 10. Admin override — a reason is MANDATORY and is logged with the exact
--     blockers that were live at the moment of the override.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.admin_order_force_close(p_order_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_actor text;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if length(btrim(coalesce(p_reason,''))) < 10 then
    return jsonb_build_object('ok',false,'error','reason_required',
      'toast', public._ocl('override.required'));
  end if;
  v_actor := coalesce(auth.jwt()->>'email','admin');
  return public.order_try_close(p_order_id, 'override', v_actor, btrim(p_reason))
         || jsonb_build_object('toast', public._ocl('override.done'));
end $fn$;

create or replace function public.admin_supplier_order_force_settle(p_supplier_order_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_actor text;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if length(btrim(coalesce(p_reason,''))) < 10 then
    return jsonb_build_object('ok',false,'error','reason_required',
      'toast', public._ocl('override.required'));
  end if;
  v_actor := coalesce(auth.jwt()->>'email','admin');
  return public.supplier_order_try_settle(p_supplier_order_id, 'override', v_actor, btrim(p_reason))
         || jsonb_build_object('toast', public._ocl('override.done_sup'));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 11. Backfill REPORT. Writes nothing, ever — it only counts what today's
--     rules would close if the sweep were pointed at history.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.order_closure_backfill_report()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_o int := 0; v_s int := 0; v_open_o int := 0; v_open_s int := 0; r record;
begin
  select count(*) into v_open_o from orders
   where closed_at is null and coalesce(status,'') not in ('cancelled','rejected');
  select count(*) into v_open_s from supplier_orders
   where settled_at is null and coalesce(status,'') not in ('closed','shipped','cancelled');

  for r in
    select o.id from orders o
     where o.closed_at is null
       and coalesce(o.status,'') not in ('cancelled','rejected')
       and exists (select 1 from deliveries d where d.order_id = o.id and d.status = 'delivered')
     order by o.created_at limit 500
  loop
    if coalesce((public._order_close_state(r.id)->>'can_close')::boolean,false) then v_o := v_o + 1; end if;
  end loop;

  for r in
    select so.id from supplier_orders so
     where so.settled_at is null
       and coalesce(so.status,'') not in ('closed','shipped','cancelled')
     order by so.order_date desc limit 500
  loop
    if coalesce((public._supplier_settle_state(r.id)->>'can_close')::boolean,false) then v_s := v_s + 1; end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'label', public._ocl('backfill.label'),
    'note',  public._ocl('backfill.note'),
    'orders_qualify', v_o,
    'orders_open', v_open_o,
    'orders_label', v_o::text || ' / ' || v_open_o::text || ' ' || public._ocl('backfill.orders'),
    'supplier_orders_qualify', v_s,
    'supplier_orders_open', v_open_s,
    'suppliers_label', v_s::text || ' / ' || v_open_s::text || ' ' || public._ocl('backfill.suppliers'));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 12. The admin surface. One list RPC, one detail RPC — both render-ready.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.admin_order_closure_list(p_filter text default 'blocked', p_limit int default 60)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_rows jsonb := '[]'::jsonb; r record; v_f text := coalesce(nullif(p_filter,''),'blocked');
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  if v_f = 'blocked' then
    for r in select o.id from orders o
              where o.closed_at is null
                and coalesce(o.status,'') not in ('cancelled','rejected')
              order by o.created_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._order_close_state(r.id));
    end loop;
  elsif v_f = 'closed' then
    for r in select o.id from orders o where o.closed_at is not null
              order by o.closed_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._order_close_state(r.id));
    end loop;
  elsif v_f = 'sup_open' then
    for r in select so.id from supplier_orders so
              where so.settled_at is null
                and coalesce(so.status,'') not in ('closed','shipped','cancelled')
              order by so.order_date desc nulls last, so.created_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._supplier_settle_state(r.id));
    end loop;
  else
    for r in select so.id from supplier_orders so where so.settled_at is not null
              order by so.settled_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._supplier_settle_state(r.id));
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',    public._ocl('screen.title'),
    'subtitle', public._ocl('screen.subtitle'),
    'auto_note',public._ocl('auto.note'),
    'filter',   v_f,
    'tabs', jsonb_build_array(
      jsonb_build_object('key','blocked',     'label', public._ocl('tab.blocked')),
      jsonb_build_object('key','closed',      'label', public._ocl('tab.closed')),
      jsonb_build_object('key','sup_open',    'label', public._ocl('tab.sup_open')),
      jsonb_build_object('key','sup_settled', 'label', public._ocl('tab.sup_settled'))),
    'empty_label', case v_f when 'blocked'  then public._ocl('empty.blocked')
                            when 'closed'   then public._ocl('empty.closed')
                            when 'sup_open' then public._ocl('empty.sup_open')
                            else public._ocl('empty.sup_settled') end,
    'retry_label', public._ocl('retry'),
    'backfill', public.order_closure_backfill_report(),
    'rows', v_rows,
    'count', jsonb_array_length(v_rows));
end $fn$;

create or replace function public.admin_order_closure_detail(p_kind text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare st jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  st := case when p_kind = 'supplier_order'
             then public._supplier_settle_state(p_id)
             else public._order_close_state(p_id) end;
  if coalesce((st->>'ok')::boolean,false) is not true then return st; end if;

  return st || jsonb_build_object(
    'override', case when (st->>'closed')::boolean then null else jsonb_build_object(
      'action_label', case when p_kind = 'supplier_order'
                          then public._ocl('override.action_sup') else public._ocl('override.action') end,
      'hint',         public._ocl('override.hint'),
      'confirm_label',case when p_kind = 'supplier_order'
                          then public._ocl('override.confirm_sup') else public._ocl('override.confirm') end,
      'cancel_label', public._ocl('override.cancel'),
      'required_label', public._ocl('override.required'),
      'rpc', case when p_kind = 'supplier_order'
                  then 'admin_supplier_order_force_settle' else 'admin_order_force_close' end) end);
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────
-- 13. Customer-facing final status. my_orders_screen() reads its chip from
--     app_settings.order_status_config, so this one row IS the closed state
--     the customer sees — no deploy needed to reword it.
-- ─────────────────────────────────────────────────────────────────────────
update app_settings
   set value = value || jsonb_build_object(
         'delivered', jsonb_build_object('label','Delivered · Closed','color','#0F6E56'))
 where key = 'order_status_config';

update app_settings
   set value = jsonb_set(value, '{fulfillment,delivered}',
         jsonb_build_object('bg','#E1F5EE','fg','#0F6E56','label','Delivered','border','#1B7A43'), true)
 where key = 'order_status_chips';

-- ─────────────────────────────────────────────────────────────────────────
-- 14. Cron. OFFSET schedule, never a bare */N — 35 jobs sharing minute 0 is
--     what starved the 60 connection slots on 18 Aug 2026.
-- ─────────────────────────────────────────────────────────────────────────
select cron.unschedule('order-lifecycle-tick')
 where exists (select 1 from cron.job where jobname = 'order-lifecycle-tick');
select cron.schedule('order-lifecycle-tick', '16-59/10 * * * *',
  $$select public.order_lifecycle_tick(100);$$);

grant execute on function public.admin_order_closure_list(text,int)          to authenticated;
grant execute on function public.admin_order_closure_detail(text,uuid)       to authenticated;
grant execute on function public.admin_order_force_close(uuid,text)          to authenticated;
grant execute on function public.admin_supplier_order_force_settle(uuid,text) to authenticated;
grant execute on function public.order_closure_backfill_report()             to authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 15. The rg guards. Both build a real fixture, assert the closure, and
--     roll every write back. Red here turns rg_check red, which blocks
--     every dev_cmd_complete until closure works again.
-- ─────────────────────────────────────────────────────────────────────────
insert into rg_behavior_tests(name, enabled, note, body) values
  ('order_closure_customer', true, 'CHANGE #229 — a paid, delivered, fully packed, billed-and-sent order DOES close: closed_at stamped, status delivered, every line out of the supplier matching scope, the closure logged, and an override with a stub reason refused. All rolled back.',
$body$
do $rg$
declare
  v_oid uuid; v_pb uuid; v_bl uuid; li record; v_net numeric; v_st jsonb;
begin
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(a.email)=lower(u.email) limit 1), true);

  select o.id into v_oid from orders o
   where o.closed_at is null and coalesce(o.status,'') not in ('cancelled','rejected')
     and exists (select 1 from order_items x where x.order_id=o.id and x.product_id is not null
                   and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable','shipped')
                   and coalesce(x.unfulfillable,false)=false)
   order by o.created_at desc limit 1;
  if v_oid is null then raise exception 'RG_ROLLBACK'; end if;

  update order_items set packed = true
   where order_id = v_oid and coalesce(fulfillment_state,'') not in ('cancelled','unfillable')
     and coalesce(unfulfillable,false)=false;

  insert into deliveries(order_id, status, delivered_at, proof_method, proof_photo_path, receiver_name)
  values (v_oid,'delivered', now(), 'photo', 'rg/proof.jpg', 'RG');

  update orders set cust_bill_path='rg/bill.pdf', cust_bill_bucket='customer-bills',
                    cust_bill_name='rg.pdf', cust_bill_uploaded_at=now() where id=v_oid;
  insert into bill_jobs(order_id, idem_key, status, wa_bill_sent_at)
  values (v_oid, 'rg-'||v_oid::text, 'done', now());

  insert into pending_bills(file_path,file_name,supplier_name,status,received_at)
  values ('rg/x.pdf','rg.pdf','RG SUPPLIER','imported', now()) returning id into v_pb;

  for li in select x.id, x.product_id, x.product_name,
                   greatest(coalesce(x.quantity,1),1) qty,
                   greatest(coalesce(x.price, x.mrp, 1),1) rate
              from order_items x where x.order_id=v_oid
               and coalesce(x.fulfillment_state,'') not in ('shipped','cancelled')
               and coalesce(x.unfulfillable,false)=false
  loop
    insert into bill_lines(pending_bill_id, supplier_name, raw_name, product_id, qty, ptr, mrp,
                           gst_pct, batch_no, expiry, line_amount, verified, auto_verified)
    values (v_pb,'RG SUPPLIER', li.product_name, li.product_id, li.qty, li.rate, li.rate, 0,
            'RGBATCH', '2028-12', li.qty*li.rate, true, false) returning id into v_bl;
    insert into bill_line_allocations(bill_line_id, order_id, order_item_id, product_id, qty)
    values (v_bl, v_oid, li.id, li.product_id, li.qty);
  end loop;

  if coalesce((public.customer_bill(v_oid)->>'ready')::boolean,false) is not true then
    raise exception 'RG_FAIL: fixture bill not ready: %', public.customer_bill(v_oid); end if;
  v_net := (public.customer_bill(v_oid)->'totals'->>'net_payable')::numeric;

  v_st := public._order_close_state(v_oid);
  if (v_st->>'can_close')::boolean then raise exception 'RG_FAIL: closable while unpaid'; end if;
  if not exists (select 1 from jsonb_array_elements(v_st->'blockers') b where b->>'key'='pay') then
    raise exception 'RG_FAIL: unpaid order does not name the payment blocker: %', v_st->'blockers'; end if;

  insert into payment_claims(order_id, amount, status, sender_type, received_at)
  values (v_oid, v_net, 'verified', 'customer', now());

  v_st := public._order_close_state(v_oid);
  if (v_st->>'closed')::boolean is not true then
    raise exception 'RG_FAIL: paid+delivered+packed+billed order did NOT close: %', v_st; end if;
  if (select closed_at from orders where id=v_oid) is null then
    raise exception 'RG_FAIL: closed_at not stamped'; end if;
  if (select status from orders where id=v_oid) <> 'delivered' then
    raise exception 'RG_FAIL: closed order status is %', (select status from orders where id=v_oid); end if;
  if exists (select 1 from order_items where order_id=v_oid
              and coalesce(fulfillment_state,'') not in ('shipped','cancelled')) then
    raise exception 'RG_FAIL: closed order still has a line in the supplier matching scope'; end if;
  if not exists (select 1 from order_closure_log where order_id=v_oid and event='closed' and mode='auto') then
    raise exception 'RG_FAIL: closure not logged'; end if;
  if coalesce(public.admin_order_force_close(v_oid,'too short')->>'error','') <> 'reason_required' then
    raise exception 'RG_FAIL: override accepted a stub reason'; end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = excluded.enabled;

insert into rg_behavior_tests(name, enabled, note, body) values
  ('order_closure_supplier', true, 'CHANGE #229 — a supplier order whose lines are all received+counted, whose disputes are resolved and whose imported bill is paid in full DOES settle: status closed, settled_at stamped, its lines marked shipped (which is what removes them from bill_lines_from_scan matching), and the settlement logged. All rolled back.',
$body$
do $rg$
declare v_soid uuid; v_sname text; v_day date; v_ss jsonb; v_amt numeric; v_panel jsonb;
begin
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(a.email)=lower(u.email) limit 1), true);

  select so.id, so.supplier_name, coalesce(so.order_date,(so.created_at at time zone 'Asia/Kolkata')::date)
    into v_soid, v_sname, v_day
    from supplier_orders so
   where so.settled_at is null and coalesce(so.status,'') not in ('closed','shipped','cancelled')
     and exists (select 1 from order_items x join orders o on o.id=x.order_id
                  where x.assigned_supplier = so.supplier_name
                    and (o.created_at at time zone 'Asia/Kolkata')::date =
                        coalesce(so.order_date,(so.created_at at time zone 'Asia/Kolkata')::date)
                    and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable','shipped'))
   order by so.created_at desc limit 1;
  if v_soid is null then raise exception 'RG_ROLLBACK'; end if;

  insert into supplier_count_mode(assigned_supplier) values (v_sname) on conflict do nothing;

  update order_items x set fulfillment_state='received', received_locked=true
    from orders o
   where o.id = x.order_id and x.assigned_supplier = v_sname
     and (o.created_at at time zone 'Asia/Kolkata')::date = v_day
     and coalesce(x.fulfillment_state,'') not in ('cancelled','unfillable');

  update supplier_disputes set status='resolved', resolved_at=now()
   where coalesce(status,'') not in ('resolved','cancelled')
     and order_item_id in (select x.id from order_items x join orders o on o.id=x.order_id
                            where x.assigned_supplier=v_sname
                              and (o.created_at at time zone 'Asia/Kolkata')::date = v_day);

  v_amt := 1234.00;
  insert into pending_bills(file_path,file_name,supplier_name,status,imported_at,received_at,scan_result,scan_status)
  values ('rg/sup.pdf','rgsup.pdf', v_sname, 'imported', now(),
          ((v_day::text || ' 12:00')::timestamp at time zone 'Asia/Kolkata'),
          jsonb_build_object('total', v_amt::text), 'done');

  v_panel := public.sup_order_bill_panel(v_soid);
  if coalesce((v_panel->>'any_bill_imported')::boolean,false) is not true then
    raise exception 'RG_FAIL: fixture bill not attached: %', v_panel; end if;

  v_ss := public._supplier_settle_state(v_soid);
  if (v_ss->>'can_close')::boolean then raise exception 'RG_FAIL: settleable while the bill is unpaid: %', v_ss; end if;

  insert into supplier_payments(supplier_order_id, supplier_name, amount, mode, kind, created_by)
  values (v_soid, v_sname,
          coalesce((v_panel->>'bills_amount_total')::numeric,0) + coalesce((v_panel->>'adjustments_total')::numeric,0)
            - coalesce((v_panel->>'total_paid')::numeric,0),
          'online','balance','rg');

  v_ss := public._supplier_settle_state(v_soid);
  if (v_ss->>'closed')::boolean is not true then
    raise exception 'RG_FAIL: received+undisputed+paid supplier order did NOT settle: %', v_ss; end if;
  if (select status from supplier_orders where id=v_soid) <> 'closed' then
    raise exception 'RG_FAIL: settled supplier order status is %', (select status from supplier_orders where id=v_soid); end if;
  if (select settled_at from supplier_orders where id=v_soid) is null then
    raise exception 'RG_FAIL: settled_at not stamped'; end if;
  if exists (select 1 from order_items x join orders o on o.id=x.order_id
              where x.assigned_supplier=v_sname
                and (o.created_at at time zone 'Asia/Kolkata')::date=v_day
                and coalesce(x.fulfillment_state,'') not in ('shipped','cancelled')) then
    raise exception 'RG_FAIL: settled supplier lines still sit in the bill-matching scope'; end if;
  if not exists (select 1 from order_closure_log where supplier_order_id=v_soid and event='settled') then
    raise exception 'RG_FAIL: settlement not logged'; end if;
  if not exists (select 1 from pending_bills where settled_order_id = v_soid and settled_at is not null) then
    raise exception 'RG_FAIL: the supplier bill itself was not stamped settled'; end if;
  if not exists (select 1 from pending_bills where settled_order_id = v_soid
                   and (imported_at is not null or lower(coalesce(status,''))='imported')) then
    raise exception 'RG_FAIL: settling un-imported the bill'; end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = excluded.enabled;
