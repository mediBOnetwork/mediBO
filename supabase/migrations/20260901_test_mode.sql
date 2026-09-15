-- CHANGE #573 — TEST MODE: one synthetic lane the whole platform understands.
--
-- This file is the git mirror of the migrations applied in order on
-- 2026-09-01. Every statement is idempotent (create-or-replace, add-column-if-
-- not-exists, on-conflict-do-nothing), so re-running the whole file is a no-op.
--
-- What it builds, in order:
--   1. is_synthetic on 4 root entities + ~40 children, a data-driven
--      inheritance registry (synthetic_inherit_rule) and ONE generic trigger.
--   2. The party invariant: a synthetic row may only ever name a synthetic
--      supplier/customer/rider, and vice versa — the waterfall physically
--      cannot ask a live distributor about a test order.
--   3. Suppression at the queue tables: a synthetic message is dropped unless
--      it is addressed to test_mode_config.test_phone. Razorpay refuses a
--      synthetic write while LIVE keys are configured.
--   4. The books never receive a synthetic row (write-blocking triggers) and
--      never see one (schema `books` + search_path flip on 27 report functions).
--      A synthetic invoice draws on its own TEST-<fy> series.
--   5. The permanent cast (test pharmacy / supplier / rider / zone) and its own
--      zone, so a test inquiry can never collide with a real one.
--   6. Simulation hooks that walk the pipeline's OWN builders, the purge, the
--      kill switch, the admin screen payload and c573_proof().

-- ── 20260901210225  c573_test_mode_core_flag ──
-- CHANGE #573 — TEST MODE, part 1: the flag, the switch, and inheritance.
-- Everything here is idempotent: a resumed worker may re-apply it.

------------------------------------------------------------------ the switch
create table if not exists public.test_mode_config (
  id            int primary key default 1,
  enabled       boolean not null default true,
  allow_outbound boolean not null default true,
  test_phone    text,
  label         text not null default 'TEST',
  updated_at    timestamptz not null default now(),
  updated_by    text,
  constraint test_mode_config_singleton check (id = 1)
);
insert into public.test_mode_config (id, enabled, allow_outbound, test_phone)
values (1, true, true, null)
on conflict (id) do nothing;

------------------------------------------------------------------ the ledger of runs
create table if not exists public.test_run (
  id          bigserial primary key,
  label       text not null,
  kind        text not null default 'manual',
  status      text not null default 'running',
  order_id    uuid,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  steps       jsonb not null default '[]'::jsonb,
  note        text
);
create index if not exists test_run_started_idx on public.test_run (started_at desc);

create table if not exists public.test_event (
  id         bigserial primary key,
  run_id     bigint references public.test_run(id) on delete cascade,
  kind       text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists test_event_run_idx on public.test_event (run_id, created_at);

------------------------------------------------------------------ the flag
do $$
declare t text;
  tables text[] := array[
    'pharmacy_profiles','supplier_profiles','delivery_partner_registrations','orders',
    'order_items','inquiry','supplier_orders','bags','bag_allocations','bag_sessions',
    'deliveries','delivery_runs','delivery_events','delivery_claims',
    'pending_bills','bill_lines','payment_claims','supplier_disputes','supplier_payments',
    'order_costs','receiving_log','stock_movement','pharmacy_stock','pharmacy_stock_move',
    'loyalty_ledger','razorpay_qr','rzp_payment_attempt','refunds','order_alert',
    'order_fulfilment_snapshot','gst_ledger','pharmacy_gst_ledger','partner_settlements',
    'notification_log','notification_retry_queue','wa_campaign_recipients','whatsapp_messages',
    'pending_orders','supplier_count_sessions','pharmacy_count_session','customer_invoice_series'
  ];
begin
  foreach t in array tables loop
    if exists (select 1 from information_schema.tables
                where table_schema='public' and table_name=t) then
      execute format(
        'alter table public.%I add column if not exists is_synthetic boolean not null default false', t);
    end if;
  end loop;
end $$;

-- The indexes that matter: the surfaces that filter by the flag every call.
create index if not exists orders_synthetic_idx on public.orders (is_synthetic) where is_synthetic;
create index if not exists order_items_synthetic_idx on public.order_items (is_synthetic) where is_synthetic;
create index if not exists supplier_orders_synthetic_idx on public.supplier_orders (is_synthetic) where is_synthetic;
create index if not exists inquiry_synthetic_idx on public.inquiry (is_synthetic) where is_synthetic;

------------------------------------------------------------------ inheritance, as DATA
create table if not exists public.synthetic_inherit_rule (
  child_table  text not null,
  child_col    text not null,
  parent_table text not null,
  parent_col   text not null default 'id',
  parent_type  text not null default 'uuid',
  primary key (child_table, child_col)
);

comment on table public.synthetic_inherit_rule is
  'CHANGE #573 — a child row inherits is_synthetic from its parent. One row per '
  'link. The generic trigger _synthetic_inherit() reads this; adding a table is '
  'one call to synthetic_rule_add(), never a new trigger function.';

create or replace function public._synthetic_inherit()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_key text; v_hit boolean;
begin
  -- Once synthetic, always synthetic: only the purge removes these rows.
  if tg_op = 'UPDATE' and coalesce(old.is_synthetic,false) then
    new.is_synthetic := true;
    return new;
  end if;
  if coalesce(new.is_synthetic,false) then return new; end if;

  -- An explicit run context stamps everything written inside it.
  if coalesce(current_setting('medibo.synthetic', true),'') = 'on' then
    new.is_synthetic := true;
    return new;
  end if;

  for r in select * from public.synthetic_inherit_rule
            where child_table = tg_table_name loop
    v_key := to_jsonb(new) ->> r.child_col;
    continue when v_key is null;
    execute format(
      'select exists (select 1 from public.%I p where p.%I = $1::%s and p.is_synthetic)',
      r.parent_table, r.parent_col, r.parent_type)
      into v_hit using v_key;
    if v_hit then
      new.is_synthetic := true;
      return new;
    end if;
  end loop;
  return new;
end $fn$;

-- Register a link AND attach the trigger in one call.
create or replace function public.synthetic_rule_add(
  p_child_table text, p_child_col text, p_parent_table text, p_parent_col text default 'id')
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare v_type text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name=p_child_table
                    and column_name=p_child_col) then
    return;
  end if;
  select data_type into v_type from information_schema.columns
   where table_schema='public' and table_name=p_parent_table and column_name=p_parent_col;
  if v_type is null then return; end if;
  v_type := case v_type
              when 'uuid' then 'uuid'
              when 'bigint' then 'bigint'
              when 'integer' then 'integer'
              when 'smallint' then 'smallint'
              else 'text' end;

  insert into public.synthetic_inherit_rule (child_table, child_col, parent_table, parent_col, parent_type)
  values (p_child_table, p_child_col, p_parent_table, p_parent_col, v_type)
  on conflict (child_table, child_col) do update
    set parent_table = excluded.parent_table,
        parent_col   = excluded.parent_col,
        parent_type  = excluded.parent_type;

  execute format('drop trigger if exists z_synthetic_inherit on public.%I', p_child_table);
  execute format(
    'create trigger z_synthetic_inherit before insert or update on public.%I '
    'for each row execute function public._synthetic_inherit()', p_child_table);
end $fn$;

-- Root entities carry the flag but inherit nothing; they still need the
-- "once synthetic, always synthetic" half of the trigger.
do $$
declare t text;
begin
  foreach t in array array['pharmacy_profiles','supplier_profiles','delivery_partner_registrations'] loop
    execute format('drop trigger if exists z_synthetic_inherit on public.%I', t);
    execute format(
      'create trigger z_synthetic_inherit before insert or update on public.%I '
      'for each row execute function public._synthetic_inherit()', t);
  end loop;
end $$;

select public.synthetic_rule_add('orders','customer_id','pharmacy_profiles','id');
select public.synthetic_rule_add('orders','user_id','pharmacy_profiles','user_id');
select public.synthetic_rule_add('order_items','order_id','orders','id');
select public.synthetic_rule_add('supplier_orders','order_id','orders','id');
select public.synthetic_rule_add('inquiry','supplier_order_id','supplier_orders','id');
select public.synthetic_rule_add('bag_allocations','order_id','orders','id');
select public.synthetic_rule_add('deliveries','order_id','orders','id');
select public.synthetic_rule_add('delivery_runs','partner_id','delivery_partner_registrations','id');
select public.synthetic_rule_add('delivery_events','order_id','orders','id');
select public.synthetic_rule_add('delivery_claims','order_id','orders','id');
select public.synthetic_rule_add('pending_bills','settled_order_id','orders','id');
select public.synthetic_rule_add('bill_lines','supplier_order_id','supplier_orders','id');
select public.synthetic_rule_add('payment_claims','order_id','orders','id');
select public.synthetic_rule_add('supplier_disputes','order_item_id','order_items','id');
select public.synthetic_rule_add('supplier_payments','supplier_order_id','supplier_orders','id');
select public.synthetic_rule_add('order_costs','order_id','orders','id');
select public.synthetic_rule_add('receiving_log','order_id','orders','id');
select public.synthetic_rule_add('stock_movement','order_id','orders','id');
select public.synthetic_rule_add('loyalty_ledger','order_id','orders','id');
select public.synthetic_rule_add('razorpay_qr','order_id','orders','id');
select public.synthetic_rule_add('rzp_payment_attempt','order_id','orders','id');
select public.synthetic_rule_add('refunds','order_id','orders','id');
select public.synthetic_rule_add('order_alert','order_id','orders','id');
select public.synthetic_rule_add('order_fulfilment_snapshot','order_id','orders','id');
select public.synthetic_rule_add('gst_ledger','order_id','orders','id');
select public.synthetic_rule_add('partner_settlements','order_id','orders','id');
select public.synthetic_rule_add('notification_log','order_id','orders','id');
select public.synthetic_rule_add('wa_campaign_recipients','order_id','orders','id');
select public.synthetic_rule_add('pharmacy_stock','pharmacy_id','pharmacy_profiles','id');
select public.synthetic_rule_add('pharmacy_stock_move','pharmacy_id','pharmacy_profiles','id');
select public.synthetic_rule_add('pharmacy_gst_ledger','pharmacy_id','pharmacy_profiles','id');
select public.synthetic_rule_add('pharmacy_count_session','pharmacy_id','pharmacy_profiles','id');
select public.synthetic_rule_add('pending_orders','user_id','pharmacy_profiles','user_id');
select public.synthetic_rule_add('supplier_count_sessions','assigned_supplier','supplier_profiles','supplier_name');
select public.synthetic_rule_add('bag_sessions','assigned_supplier','supplier_profiles','supplier_name');
;

-- ── 20260901210303  c573_test_mode_guards_and_reverse_inherit ──
-- CHANGE #573 — part 2: the links the FK graph does not give us, and the
-- invariant that keeps a real party out of a synthetic row (and back).

select public.synthetic_rule_add('notification_log','customer_id','pharmacy_profiles','id');
select public.synthetic_rule_add('wa_campaign_recipients','customer_id','pharmacy_profiles','id');
select public.synthetic_rule_add('bill_lines','pending_bill_id','pending_bills','id');

-------------------------------------------------------------- reverse links
-- `inquiry` has no order_id: the order item points AT the inquiry. So the
-- item stamps the inquiry, not the other way round.
create or replace function public._synthetic_stamp_inquiry()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(new.is_synthetic,false) and new.inquiry_id is not null then
    update public.inquiry set is_synthetic = true
     where id = new.inquiry_id and not coalesce(is_synthetic,false);
  end if;
  return null;
end $fn$;
drop trigger if exists z_synthetic_stamp_inquiry on public.order_items;
create trigger z_synthetic_stamp_inquiry after insert or update of inquiry_id, is_synthetic
  on public.order_items for each row execute function public._synthetic_stamp_inquiry();

-- `bags` is keyed by bag_no and has no parent column either; the allocation
-- that lands in it is what makes it synthetic.
create or replace function public._synthetic_stamp_bag()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(new.is_synthetic,false) and new.bag_no is not null then
    update public.bags set is_synthetic = true
     where bag_no = new.bag_no and not coalesce(is_synthetic,false);
  end if;
  return null;
end $fn$;
drop trigger if exists z_synthetic_stamp_bag on public.bag_allocations;
create trigger z_synthetic_stamp_bag after insert or update of bag_no, is_synthetic
  on public.bag_allocations for each row execute function public._synthetic_stamp_bag();

---------------------------------------------------------- the party invariant
-- This is what makes "no real supplier or customer ever sees a synthetic row"
-- structural instead of a filter someone has to remember. A synthetic row may
-- only ever name a synthetic party, and a real row may only ever name a real
-- one. Enforced where the link is written, so the waterfall physically cannot
-- ask a live distributor about a test order.
create or replace function public.synthetic_supplier_is(p_name text, p_id uuid default null)
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select coalesce((
    select s.is_synthetic from public.supplier_profiles s
     where (p_id is not null and s.id = p_id)
        or (p_id is null and p_name is not null
            and lower(btrim(s.supplier_name)) = lower(btrim(p_name)))
     order by coalesce(s.is_deleted,false) limit 1), false);
$fn$;

create or replace function public.synthetic_supplier_known(p_name text, p_id uuid default null)
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select exists (
    select 1 from public.supplier_profiles s
     where (p_id is not null and s.id = p_id)
        or (p_id is null and p_name is not null
            and lower(btrim(s.supplier_name)) = lower(btrim(p_name))));
$fn$;

create or replace function public._synthetic_party_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_row boolean := coalesce(new.is_synthetic,false); v_name text; v_id uuid;
begin
  if tg_table_name = 'supplier_orders' then
    v_name := new.supplier_name; v_id := new.supplier_id;
  elsif tg_table_name = 'inquiry' then
    v_name := coalesce(new.manual_supplier, new.current_supplier);
  elsif tg_table_name = 'order_items' then
    v_name := new.assigned_supplier;
  end if;

  if v_name is not null or v_id is not null then
    if public.synthetic_supplier_known(v_name, v_id)
       and public.synthetic_supplier_is(v_name, v_id) <> v_row then
      raise exception
        'synthetic_party_mismatch: % row (is_synthetic=%) cannot name supplier %',
        tg_table_name, v_row, coalesce(v_name, v_id::text)
        using errcode = '23514';
    end if;
  end if;
  return new;
end $fn$;

drop trigger if exists z_synthetic_party_guard on public.supplier_orders;
create trigger z_synthetic_party_guard before insert or update
  on public.supplier_orders for each row execute function public._synthetic_party_guard();
drop trigger if exists z_synthetic_party_guard on public.inquiry;
create trigger z_synthetic_party_guard before insert or update
  on public.inquiry for each row execute function public._synthetic_party_guard();
drop trigger if exists z_synthetic_party_guard on public.order_items;
create trigger z_synthetic_party_guard before insert or update
  on public.order_items for each row execute function public._synthetic_party_guard();

-- The rider half of the same invariant.
create or replace function public._synthetic_rider_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_rider boolean;
begin
  if new.partner_id is null then return new; end if;
  select is_synthetic into v_rider from public.delivery_partner_registrations where id = new.partner_id;
  if v_rider is not null and v_rider <> coalesce(new.is_synthetic,false) then
    raise exception 'synthetic_party_mismatch: delivery (is_synthetic=%) cannot be assigned to rider %',
      coalesce(new.is_synthetic,false), new.partner_id using errcode = '23514';
  end if;
  return new;
end $fn$;
drop trigger if exists z_synthetic_rider_guard on public.deliveries;
create trigger z_synthetic_rider_guard before insert or update
  on public.deliveries for each row execute function public._synthetic_rider_guard();
;

-- ── 20260901210355  c573_test_mode_suppression_and_books ──
-- CHANGE #573 — part 3: nothing leaves the building, and nothing lands in the
-- books. Both at the DATA layer, so no caller has to remember either one.

alter table public.order_pnl_slab       add column if not exists is_synthetic boolean not null default false;
alter table public.incentive_earnings   add column if not exists is_synthetic boolean not null default false;
alter table public.delivery_payout_lines add column if not exists is_synthetic boolean not null default false;

select public.synthetic_rule_add('order_pnl_slab','order_id','orders','id');
select public.synthetic_rule_add('delivery_payout_lines','order_id','orders','id');
select public.synthetic_rule_add('notification_retry_queue','order_id','orders','id');
select public.synthetic_rule_add('notification_retry_queue','customer_id','pharmacy_profiles','id');

----------------------------------------------------------- the outbound gate
create or replace function public.test_mode_state()
returns public.test_mode_config language sql stable security definer
set search_path to 'public' as $fn$
  select * from public.test_mode_config where id = 1;
$fn$;

create or replace function public.synthetic_phone10(p_phone text)
returns text language sql immutable as $fn$
  select nullif(right(regexp_replace(coalesce(p_phone,''), '[^0-9]', '', 'g'), 10), '');
$fn$;

-- The ONLY recipient a synthetic row may reach. Everything else is dropped
-- here, in the queue table, before any sender ever sees it.
create or replace function public.synthetic_outbound_allowed(p_recipient text)
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select coalesce((
    select c.enabled and c.allow_outbound
           and public.synthetic_phone10(c.test_phone) is not null
           and public.synthetic_phone10(c.test_phone) = public.synthetic_phone10(p_recipient)
      from public.test_mode_config c where c.id = 1), false);
$fn$;

create or replace function public._synthetic_outbound_gate()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
declare v_to text;
begin
  if not coalesce(new.is_synthetic,false) then return new; end if;

  v_to := case tg_table_name
            when 'wa_campaign_recipients'    then new.phone
            when 'notification_retry_queue'  then new.recipient
            when 'whatsapp_messages'         then new.sender_phone
          end;

  if public.synthetic_outbound_allowed(v_to) then
    return new;                              -- Om's own test number, on purpose
  end if;

  if tg_table_name = 'wa_campaign_recipients' then
    new.status      := 'skipped';
    new.skip_reason := 'synthetic_suppressed';
    return new;                              -- kept as evidence, never sent
  end if;

  if tg_table_name = 'whatsapp_messages' then
    if coalesce(new.direction,'') <> 'out' then return new; end if;
    new.wa_status      := 'suppressed';
    new.wa_fail_reason := 'synthetic_suppressed';
    return new;
  end if;

  return null;                               -- retry queue: never enqueued
end $fn$;

drop trigger if exists z_synthetic_outbound_gate on public.wa_campaign_recipients;
create trigger z_synthetic_outbound_gate before insert on public.wa_campaign_recipients
  for each row execute function public._synthetic_outbound_gate();
drop trigger if exists z_synthetic_outbound_gate on public.notification_retry_queue;
create trigger z_synthetic_outbound_gate before insert on public.notification_retry_queue
  for each row execute function public._synthetic_outbound_gate();
drop trigger if exists z_synthetic_outbound_gate on public.whatsapp_messages;
create trigger z_synthetic_outbound_gate before insert on public.whatsapp_messages
  for each row execute function public._synthetic_outbound_gate();

------------------------------------------------------------- Razorpay: test keys or nothing
create or replace function public.synthetic_rzp_is_test()
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select coalesce((
    select coalesce(nullif(btrim(p.rzp_key_id),''),'') = ''
        or lower(btrim(p.rzp_key_id)) like 'rzp\_test%'
      from public.payment_config p order by p.id limit 1), true);
$fn$;

create or replace function public._synthetic_rzp_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if coalesce(new.is_synthetic,false) and not public.synthetic_rzp_is_test() then
    raise exception
      'synthetic_live_razorpay_blocked: a test order cannot touch Razorpay while LIVE keys are configured'
      using errcode = '23514';
  end if;
  return new;
end $fn$;
drop trigger if exists z_synthetic_rzp_guard on public.rzp_payment_attempt;
create trigger z_synthetic_rzp_guard before insert or update on public.rzp_payment_attempt
  for each row execute function public._synthetic_rzp_guard();
drop trigger if exists z_synthetic_rzp_guard on public.razorpay_qr;
create trigger z_synthetic_rzp_guard before insert or update on public.razorpay_qr
  for each row execute function public._synthetic_rzp_guard();

------------------------------------------------------------ the books never receive it
create table if not exists public.synthetic_blocked_write (
  id         bigserial primary key,
  table_name text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists synthetic_blocked_write_idx
  on public.synthetic_blocked_write (created_at desc);

create or replace function public._synthetic_books_block()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if not coalesce(new.is_synthetic,false) then return new; end if;
  insert into public.synthetic_blocked_write (table_name, detail)
  values (tg_table_name, to_jsonb(new));
  return null;                               -- silently not a book entry
end $fn$;

do $$
declare t text;
begin
  foreach t in array array[
    'gst_ledger','pharmacy_gst_ledger','partner_settlements','loyalty_ledger',
    'order_pnl_slab','incentive_earnings','delivery_payout_lines'] loop
    execute format('drop trigger if exists zz_synthetic_books_block on public.%I', t);
    execute format(
      'create trigger zz_synthetic_books_block before insert on public.%I '
      'for each row execute function public._synthetic_books_block()', t);
  end loop;
end $$;
;

-- ── 20260901210435  c573_test_mode_books_views_and_series ──
-- CHANGE #573 — part 4: the books read a FILTERED world, and a synthetic
-- invoice never consumes a real number.
--
-- The mechanism is one line per reporting function instead of a rewrite of
-- each: schema `books` holds security_invoker views that are the same tables
-- minus the synthetic rows, and each books/report function's search_path is
-- flipped to 'books, public'. Unqualified `orders` inside pnl_dashboard() now
-- resolves to books.orders; every other name it uses still resolves to public.
-- The views are simple and therefore auto-updatable, so a function that writes
-- through one keeps working — and physically cannot touch a synthetic row.

create schema if not exists books;

do $$
declare t text;
begin
  foreach t in array array[
    'orders','order_items','supplier_orders','inquiry','deliveries','delivery_runs',
    'delivery_events','bag_allocations','order_costs','payment_claims','pending_bills',
    'bill_lines','supplier_payments','supplier_disputes','receiving_log','refunds',
    'loyalty_ledger','pharmacy_profiles','supplier_profiles','delivery_partner_registrations'] loop
    execute format(
      'create or replace view books.%I with (security_invoker = true) as '
      'select * from public.%I where not coalesce(is_synthetic, false)', t, t);
  end loop;
end $$;

comment on schema books is
  'CHANGE #573 — the books'' view of the world: every table minus its synthetic '
  'rows. A reporting function opts in by setting search_path to books, public.';

do $$
declare r record;
  targets text[] := array[
    'admin_dashboard_counts','admin_delivery_dashboard','admin_demand_engine','admin_demand_preview',
    'admin_receivables','admin_receivables_chase','admin_receivables_orders','cust_number_ranking',
    'inquiry_demand_qty','purchase_register_export','pnl_breakdown','pnl_dashboard','pnl_order',
    'pnl_slab_simulate','settlement_build','settlement_cost_lines_build','settlement_dashboard',
    'settlement_recalculate','settlement_statement','recompute_ordered_medicine_points',
    'refresh_ordered_medicine_points','network_demand_refresh','pharmacy_demand_refresh',
    'pharmacy_bench_refresh','pharmacy_benchmark','sup_number_ranking','_loy_metric'];
begin
  for r in
    select p.oid::regprocedure sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = any(targets)
  loop
    execute format('alter function %s set search_path to ''books'', ''public''', r.sig);
  end loop;
end $$;

------------------------------------------------------- a series of its own
-- customer_invoice_series is keyed by financial year; a synthetic run books
-- against 'TEST-<fy>' with its own prefix, so the real MB/<fy>/#### sequence
-- is never advanced by a test.
create or replace function public._next_customer_invoice_no(p_synthetic boolean default false)
returns text language plpgsql security definer set search_path to 'public' as $fn$
declare v_fy text := public._fy_ist(); v_prefix text; v_no int;
begin
  select coalesce(invoice_prefix,'MB') into v_prefix from public.billing_config where id = 1;
  v_prefix := coalesce(v_prefix,'MB');

  if p_synthetic then
    v_fy := 'TEST-' || v_fy;
    v_prefix := 'TEST';
  end if;

  insert into public.customer_invoice_series (fy, prefix, next_no, is_synthetic)
  values (v_fy, v_prefix, 1, p_synthetic)
  on conflict (fy) do nothing;

  update public.customer_invoice_series
     set next_no = next_no + 1, updated_at = now()
   where fy = v_fy
  returning next_no - 1 into v_no;

  return v_prefix || '/' || v_fy || '/' || to_char(v_no, 'FM0000');
end $fn$;

create or replace function public.customer_invoice_issue(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_no text; v_supplied boolean; v_syn boolean;
begin
  select invoice_no, coalesce(is_synthetic,false) into v_no, v_syn
    from orders where id = p_order_id;
  if v_no is not null then
    return jsonb_build_object('ok', true, 'already', true, 'invoice_no', v_no);
  end if;

  v_supplied := public._order_is_supplied(p_order_id);
  if not v_supplied then
    return jsonb_build_object('ok', false, 'reason','not_supplied',
      'message', public.uic('bill.proforma_reason',
                            'A tax invoice is raised when the order is dispatched.'));
  end if;

  v_no := public._next_customer_invoice_no(coalesce(v_syn,false));
  update orders set invoice_no = v_no, invoice_issued_at = now()
   where id = p_order_id and invoice_no is null;

  select invoice_no into v_no from orders where id = p_order_id;
  return jsonb_build_object('ok', true, 'already', false, 'invoice_no', v_no);
end $fn$;
;

-- ── 20260901210733  c573_test_mode_fixtures_full ──
-- CHANGE #573 — part 5: the permanent, obviously-fake cast.

create table if not exists public.test_fixture (
  key        text primary key,
  kind       text not null,
  entity_id  uuid,
  label      text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public._test_guard()
returns boolean language plpgsql stable security definer set search_path to 'public' as $fn$
begin
  if coalesce(current_setting('request.jwt.claim.role', true),'') = 'service_role'
     or current_user in ('postgres','supabase_admin','service_role') then
    return true;
  end if;
  return public.is_admin();
exception when others then
  return public.is_admin();
end $fn$;

create or replace function public._test_zone()
returns smallint language sql stable security definer set search_path to 'public' as $fn$
  select id from public.zones
   order by (coalesce(is_default,false)) desc, coalesce(is_active,false) desc, id
   limit 1;
$fn$;

create or replace function public.test_fixtures_ensure()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_zone smallint := public._test_zone();
  v_ph uuid; v_sup uuid; v_rider uuid;
  v_pharm_name text := 'TST TEST PHARMACY - SYNTHETIC (DO NOT USE)';
  v_sup_name   text := 'TST TEST SUPPLIER - SYNTHETIC (DO NOT USE)';
  v_rider_name text := 'TST TEST RIDER - SYNTHETIC (DO NOT USE)';
begin
  if not public._test_guard() then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  select entity_id into v_ph from public.test_fixture where key = 'pharmacy';
  if v_ph is null or not exists (select 1 from public.pharmacy_profiles where id = v_ph) then
    select id into v_ph from public.pharmacy_profiles
      where is_synthetic and pharmacy_name = v_pharm_name limit 1;
  end if;
  if v_ph is null then
    insert into public.pharmacy_profiles
      (user_id, pharmacy_name, customer_name, owner_name, phone, whatsapp_no, email,
       address, city, state, pincode, customer_code, approved, status, zone_id, is_synthetic)
    values
      ('00000000-0000-0000-0000-000000000573'::uuid, v_pharm_name, v_pharm_name,
       'TEST OWNER (SYNTHETIC)', '9000000573', '9000000573', 'test.synthetic@medibo.in',
       'Synthetic Test Lane', 'Raipur', 'Chhattisgarh', '492001', 'TST900',
       true, 'approved', v_zone, true)
    returning id into v_ph;
  end if;
  insert into public.test_fixture (key, kind, entity_id, label, detail)
  values ('pharmacy','customer', v_ph, v_pharm_name, jsonb_build_object('zone_id', v_zone))
  on conflict (key) do update set entity_id = excluded.entity_id, label = excluded.label;

  select entity_id into v_sup from public.test_fixture where key = 'supplier';
  if v_sup is null or not exists (select 1 from public.supplier_profiles where id = v_sup) then
    select id into v_sup from public.supplier_profiles
      where is_synthetic and supplier_name = v_sup_name limit 1;
  end if;
  if v_sup is null then
    insert into public.supplier_profiles
      (supplier_name, contact_name, phone, whatsapp_no, contact_no, email, city, state,
       address, pincode, approved, status, zone_id, is_synthetic)
    values
      (v_sup_name, 'TEST CONTACT (SYNTHETIC)', '9000000574', '9000000574', '9000000574',
       'test.synthetic.sup@medibo.in', 'Raipur', 'Chhattisgarh',
       'Synthetic Test Lane', '492001', true, 'approved', v_zone, true)
    returning id into v_sup;
  end if;
  insert into public.test_fixture (key, kind, entity_id, label, detail)
  values ('supplier','supplier', v_sup, v_sup_name, jsonb_build_object('zone_id', v_zone))
  on conflict (key) do update set entity_id = excluded.entity_id, label = excluded.label;

  select entity_id into v_rider from public.test_fixture where key = 'rider';
  if v_rider is null or not exists (select 1 from public.delivery_partner_registrations where id = v_rider) then
    select id into v_rider from public.delivery_partner_registrations
      where is_synthetic and full_name = v_rider_name limit 1;
  end if;
  if v_rider is null then
    insert into public.delivery_partner_registrations
      (full_name, phone, email, status, partner_type, vehicle_type, city, state,
       address, zone_id, is_active, is_synthetic)
    values
      (v_rider_name, '9000000575', 'test.synthetic.rider@medibo.in', 'approved', 'boy',
       'bike', 'Raipur', 'Chhattisgarh', 'Synthetic Test Lane', v_zone, true, true)
    returning id into v_rider;
  end if;
  insert into public.test_fixture (key, kind, entity_id, label, detail)
  values ('rider','delivery', v_rider, v_rider_name, jsonb_build_object('zone_id', v_zone))
  on conflict (key) do update set entity_id = excluded.entity_id, label = excluded.label;

  insert into public.test_fixture (key, kind, entity_id, label, detail)
  values ('zone','zone', null,
          coalesce((select 'Zone ' || coalesce(code, name, id::text) from public.zones where id = v_zone),
                   'Zone (none)'),
          jsonb_build_object('zone_id', v_zone,
            'note','the synthetic cast is pinned to one zone so a test order never routes elsewhere'))
  on conflict (key) do update set label = excluded.label, detail = excluded.detail;

  return jsonb_build_object('ok', true, 'pharmacy_id', v_ph, 'supplier_id', v_sup,
                            'rider_id', v_rider, 'zone_id', v_zone);
end $fn$;

select public.test_fixtures_ensure();
;

-- ── 20260901210848  c573_test_mode_simulation_hooks ──
-- CHANGE #573 — part 6: the simulation hooks. Each writes exactly the rows the
-- real path writes; the ONLY difference is that nothing leaves the building,
-- and that is enforced by part 3's triggers, not by these functions.

create or replace function public.test_mode_on()
returns boolean language sql stable security definer set search_path to 'public' as $fn$
  select coalesce((select enabled from public.test_mode_config where id = 1), false);
$fn$;

create or replace function public.test_run_open(p_label text, p_kind text default 'manual')
returns bigint language plpgsql security definer set search_path to 'public' as $fn$
declare v_id bigint;
begin
  insert into public.test_run (label, kind) values (coalesce(p_label,'test run'), coalesce(p_kind,'manual'))
  returning id into v_id;
  return v_id;
end $fn$;

create or replace function public.test_event_add(p_run bigint, p_kind text, p_detail jsonb default '{}'::jsonb)
returns void language sql security definer set search_path to 'public' as $fn$
  insert into public.test_event (run_id, kind, detail) values (p_run, p_kind, coalesce(p_detail,'{}'::jsonb));
$fn$;

------------------------------------------------------------------ 1. the order
create or replace function public.test_order_create(p_lines int default 2, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_ph uuid; v_zone smallint; v_order uuid; v_name text; r record;
        v_total numeric := 0; v_items jsonb := '[]'::jsonb; v_qty numeric := 2;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;
  perform public.test_fixtures_ensure();

  select entity_id, (detail->>'zone_id')::smallint into v_ph, v_zone
    from public.test_fixture where key = 'pharmacy';
  select label into v_name from public.test_fixture where key = 'pharmacy';

  insert into public.orders (customer_id, user_id, pharmacy_name, phone, address, status,
                             fulfillment_status, source, zone_id, order_date, total_amount,
                             items, placed_by_admin, is_synthetic)
  values (v_ph, null, v_name, '9000000573', 'Synthetic Test Lane', 'accepted',
          'open', 'website', v_zone, (now() at time zone 'Asia/Kolkata')::date, 0,
          '[]'::jsonb, true, true)
  returning id into v_order;

  for r in
    select m.id, m.product_name,
           coalesce(nullif(regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g'),'')::numeric, 100) mrp,
           coalesce(m.gst_percent, 12) gst
      from public."MEDICINE" m
     where coalesce(m.buyable,false) and m.product_name is not null
     order by m.id
     limit greatest(coalesce(p_lines,2), 1)
  loop
    insert into public.order_items (order_id, product_id, product_name, quantity, mrp, price,
                                    gst_percent, line_total, pharmacy_name, status, order_date, zone_id)
    values (v_order, r.id, r.product_name, v_qty, r.mrp, round(r.mrp * 0.80, 2), r.gst,
            round(r.mrp * 0.80 * v_qty, 2), v_name, 'pending',
            (now() at time zone 'Asia/Kolkata')::date, v_zone);
    v_total := v_total + round(r.mrp * 0.80 * v_qty, 2);
    v_items := v_items || jsonb_build_object('product_id', r.id, 'name', r.product_name,
                                             'qty', v_qty, 'price', round(r.mrp * 0.80, 2));
  end loop;

  update public.orders set total_amount = v_total, items = v_items where id = v_order;
  if p_run is not null then
    perform public.test_event_add(p_run, 'order_created', jsonb_build_object('order_id', v_order));
    update public.test_run set order_id = v_order where id = p_run and order_id is null;
  end if;

  return jsonb_build_object('ok', true, 'order_id', v_order,
                            'order_code', (select order_code from public.orders where id = v_order),
                            'lines', (select count(*) from public.order_items where order_id = v_order),
                            'total_amount', v_total);
end $fn$;

--------------------------------------------------- 2. the supplier answers
create or replace function public.test_sim_supplier_answer(
  p_order_id uuid, p_available boolean default true, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_sup uuid; v_sup_name text; v_so uuid; r record; v_inq bigint;
        v_total numeric := 0; v_items jsonb := '[]'::jsonb; v_n int := 0; v_zone smallint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id, label into v_sup, v_sup_name from public.test_fixture where key='supplier';
  select zone_id into v_zone from public.orders where id = p_order_id;

  insert into public.supplier_orders (supplier_id, supplier_name, order_id, status, items,
                                      total_amount, order_date, zone_id, is_synthetic)
  values (v_sup, v_sup_name, p_order_id, 'sent', '[]'::jsonb, 0,
          (now() at time zone 'Asia/Kolkata')::date, v_zone, true)
  returning id into v_so;

  for r in select * from public.order_items where order_id = p_order_id order by created_at loop
    insert into public.inquiry (product_name, quantity, mrp, gst_percent, product_id,
                                current_supplier, "PS1", "AS1", available, out_of_stock,
                                response, current_status, inquiry_phase, supplier_order_id,
                                asked_at, zone_id, is_synthetic)
    values (r.product_name, r.quantity, r.mrp, r.gst_percent, r.product_id,
            v_sup_name, v_sup_name, case when p_available then 'Available' else 'Out of stock' end,
            p_available, not p_available,
            case when p_available then 'Available' else 'Out of stock' end,
            case when p_available then 'answered' else 'unfulfilled' end,
            'answered', v_so, now(), v_zone, true)
    returning id into v_inq;

    update public.order_items
       set inquiry_id = v_inq,
           assigned_supplier = case when p_available then v_sup_name else assigned_supplier end,
           fulfillment_state = case when p_available then 'assigned' else 'unfulfilled' end,
           unfulfillable = not p_available
     where id = r.id;

    if p_available then
      v_total := v_total + coalesce(r.line_total, 0);
      v_items := v_items || jsonb_build_object('product_id', r.product_id, 'name', r.product_name,
                                               'qty', r.quantity, 'rate', r.price);
      v_n := v_n + 1;
    end if;
  end loop;

  update public.supplier_orders set items = v_items, total_amount = v_total, trade_total = v_total
   where id = v_so;
  update public.orders set fulfillment_status = 'collecting' where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'supplier_answered',
      jsonb_build_object('supplier_order_id', v_so, 'lines', v_n, 'available', p_available));
  end if;

  return jsonb_build_object('ok', true, 'supplier_order_id', v_so, 'supplier', v_sup_name,
                            'lines_available', v_n, 'total_amount', v_total);
end $fn$;

--------------------------------------------------- 3. the payment is captured
create or replace function public.test_sim_payment_capture(
  p_order_id uuid, p_amount numeric default null, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_amt numeric; v_claim uuid; v_att uuid; v_utr text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  if not public.synthetic_rzp_is_test() then
    return jsonb_build_object('ok', false, 'error','live_keys',
      'message', public.uic('test_mode.live_keys',
        'Razorpay is configured with LIVE keys — a test payment is refused.'));
  end if;

  select coalesce(p_amount, total_amount, 0) into v_amt from public.orders where id = p_order_id;
  v_utr := 'TEST' || to_char(now(),'YYYYMMDDHH24MISS');

  insert into public.payment_claims (order_id, sender_phone, sender_type, amount, utr, app,
                                     status, payment_method, received_at, paid_ts, is_synthetic)
  values (p_order_id, '9000000573', 'customer', v_amt, v_utr, 'TEST', 'verified', 'upi',
          now(), now(), true)
  returning id into v_claim;

  insert into public.rzp_payment_attempt (order_id, kind, mode, amount, status,
                                          rzp_payment_id, reference_id, attempted_at, paid_at, is_synthetic)
  values (p_order_id, 'checkout', 'test', v_amt, 'paid',
          'pay_TEST' || to_char(now(),'YYYYMMDDHH24MISS'), v_utr, now(), now(), true)
  returning id into v_att;

  update public.orders set payment_id = v_utr where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'payment_captured',
      jsonb_build_object('claim_id', v_claim, 'attempt_id', v_att, 'amount', v_amt));
  end if;

  return jsonb_build_object('ok', true, 'claim_id', v_claim, 'attempt_id', v_att, 'amount', v_amt);
end $fn$;

--------------------------------------------------- 4. the delivery completes
create or replace function public.test_sim_delivery_complete(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_rider uuid; v_run uuid; v_del uuid; v_zone smallint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id into v_rider from public.test_fixture where key='rider';
  select zone_id into v_zone from public.orders where id = p_order_id;

  select id into v_run from public.delivery_runs
   where partner_id = v_rider and run_date = (now() at time zone 'Asia/Kolkata')::date limit 1;
  if v_run is null then
    insert into public.delivery_runs (partner_id, run_date, status, started_at, zone_id, is_synthetic)
    values (v_rider, (now() at time zone 'Asia/Kolkata')::date, 'running', now(), v_zone, true)
    returning id into v_run;
  end if;

  insert into public.deliveries (order_id, run_id, partner_id, assigned_at, accept_status, accepted_at,
                                 status, proof_method, receiver_name, delivered_at, attempt_no,
                                 zone_id, is_synthetic)
  values (p_order_id, v_run, v_rider, now(), 'accepted', now(), 'delivered', 'otp',
          'TEST RECEIVER (SYNTHETIC)', now(), 1, v_zone, true)
  returning id into v_del;

  insert into public.delivery_events (delivery_id, order_id, partner_id, event, note, actor)
  values (v_del, p_order_id, v_rider, 'delivered', 'simulated by test mode', 'test_mode');

  update public.orders set fulfillment_status = 'shipped', shipped_at = now() where id = p_order_id;
  update public.delivery_runs set status = 'completed', completed_at = now() where id = v_run;

  if p_run is not null then
    perform public.test_event_add(p_run, 'delivery_completed',
      jsonb_build_object('delivery_id', v_del, 'run_id', v_run));
  end if;

  return jsonb_build_object('ok', true, 'delivery_id', v_del, 'run_id', v_run);
end $fn$;
;

-- ── 20260901210935  c573_test_mode_run_purge_screen ──
-- CHANGE #573 — part 7: the whole lap, the purge, and the admin surface.

create or replace function public.synthetic_badge(p_is boolean)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select case when coalesce(p_is,false)
    then jsonb_build_object(
           'label', public.uic('test_mode.badge','TEST'),
           'tone',  'danger',
           'hint',  public.uic('test_mode.badge_hint','Synthetic row — test mode only'))
  end;
$fn$;

-- Everything that counts as "went out of the building" while a run was open.
create or replace function public._test_outbound_count(p_since timestamptz)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'wa_queued',    (select count(*) from public.wa_campaign_recipients
                      where created_at >= p_since and is_synthetic
                        and coalesce(status,'') <> 'skipped'),
    'wa_suppressed',(select count(*) from public.wa_campaign_recipients
                      where created_at >= p_since and is_synthetic
                        and coalesce(status,'') = 'skipped'),
    'wa_out',       (select count(*) from public.whatsapp_messages
                      where created_at >= p_since and is_synthetic
                        and coalesce(direction,'') = 'out'
                        and coalesce(wa_status,'') <> 'suppressed'),
    'retry_queued', (select count(*) from public.notification_retry_queue
                      where created_at >= p_since and is_synthetic));
$fn$;

create or replace function public._test_books_touch()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'gst_ledger',          (select count(*) from public.gst_ledger where is_synthetic),
    'pharmacy_gst_ledger', (select count(*) from public.pharmacy_gst_ledger where is_synthetic),
    'partner_settlements', (select count(*) from public.partner_settlements where is_synthetic),
    'loyalty_ledger',      (select count(*) from public.loyalty_ledger where is_synthetic),
    'order_pnl_slab',      (select count(*) from public.order_pnl_slab where is_synthetic),
    'blocked_writes',      (select count(*) from public.synthetic_blocked_write));
$fn$;

------------------------------------------------------------------ the whole lap
create or replace function public.test_run_full(p_label text default null, p_kind text default 'manual')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_run bigint; v_t timestamptz := now(); v_order uuid;
        v_o jsonb; v_s jsonb; v_p jsonb; v_d jsonb; v_inv jsonb;
        v_out jsonb; v_books jsonb; v_ok boolean;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  v_run := public.test_run_open(coalesce(p_label, 'synthetic order end-to-end'), coalesce(p_kind,'manual'));

  v_o := public.test_order_create(2, v_run);
  if not coalesce((v_o->>'ok')::boolean,false) then
    update public.test_run set status='failed', ended_at=now(), note = v_o::text where id = v_run;
    return jsonb_build_object('ok', false, 'run_id', v_run, 'stage','order', 'detail', v_o);
  end if;
  v_order := (v_o->>'order_id')::uuid;

  v_s := public.test_sim_supplier_answer(v_order, true, v_run);
  v_p := public.test_sim_payment_capture(v_order, null, v_run);
  v_d := public.test_sim_delivery_complete(v_order, v_run);
  v_inv := public.customer_invoice_issue(v_order);

  v_out   := public._test_outbound_count(v_t);
  v_books := public._test_books_touch();

  v_ok := coalesce((v_s->>'ok')::boolean,false)
      and coalesce((v_d->>'ok')::boolean,false)
      and (v_out->>'wa_queued')::int = 0
      and (v_out->>'wa_out')::int = 0
      and (v_out->>'retry_queued')::int = 0
      and (v_books->>'gst_ledger')::int = 0
      and (v_books->>'partner_settlements')::int = 0
      and (v_books->>'loyalty_ledger')::int = 0;

  update public.test_run
     set status = case when v_ok then 'passed' else 'failed' end,
         ended_at = now(), order_id = v_order,
         steps = jsonb_build_array(v_o, v_s, v_p, v_d, v_inv)
   where id = v_run;

  return jsonb_build_object('ok', v_ok, 'run_id', v_run, 'order_id', v_order,
    'order_code', v_o->>'order_code', 'supplier', v_s, 'payment', v_p, 'delivery', v_d,
    'invoice', v_inv, 'outbound', v_out, 'books', v_books);
end $fn$;

------------------------------------------------------------------ the purge
create or replace function public.test_purge(p_include_fixtures boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare t text; n bigint; v_out jsonb := '{}'::jsonb; v_total bigint := 0;
  ordered text[] := array[
    'delivery_events','delivery_claims','delivery_payout_lines','deliveries','delivery_runs',
    'bag_allocations','bags','receiving_log','stock_movement',
    'bill_lines','pending_bills','supplier_payments','supplier_disputes',
    'payment_claims','rzp_payment_attempt','razorpay_qr','refunds','order_costs',
    'order_alert','order_fulfilment_snapshot','order_pnl_slab',
    'notification_log','notification_retry_queue','wa_campaign_recipients','whatsapp_messages',
    'loyalty_ledger','pharmacy_stock_move','pharmacy_stock','pharmacy_gst_ledger',
    'pharmacy_count_session','gst_ledger','partner_settlements','incentive_earnings',
    'order_items','inquiry','supplier_orders','orders','pending_orders',
    'supplier_count_sessions','bag_sessions','customer_invoice_series'];
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  foreach t in array ordered loop
    execute format('delete from public.%I where is_synthetic', t);
    get diagnostics n = row_count;
    if n > 0 then v_out := v_out || jsonb_build_object(t, n); v_total := v_total + n; end if;
  end loop;

  delete from public.synthetic_blocked_write; get diagnostics n = row_count;
  if n > 0 then v_out := v_out || jsonb_build_object('synthetic_blocked_write', n); v_total := v_total + n; end if;
  delete from public.test_event; delete from public.test_run;

  if coalesce(p_include_fixtures,false) then
    delete from public.test_fixture;
    delete from public.delivery_partner_registrations where is_synthetic;
    delete from public.supplier_profiles where is_synthetic;
    delete from public.pharmacy_profiles where is_synthetic;
    v_out := v_out || jsonb_build_object('fixtures', 'removed');
  end if;

  return jsonb_build_object('ok', true, 'deleted', v_out, 'total', v_total,
    'message', public.uic('test_mode.purged','Synthetic artifacts purged.'));
end $fn$;

------------------------------------------------------------------ the switch
create or replace function public.test_mode_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  update public.test_mode_config
     set enabled        = coalesce((p_patch->>'enabled')::boolean, enabled),
         allow_outbound = coalesce((p_patch->>'allow_outbound')::boolean, allow_outbound),
         test_phone     = coalesce(nullif(btrim(p_patch->>'test_phone'),''), test_phone),
         updated_at     = now(),
         updated_by     = coalesce(nullif(btrim(p_patch->>'by'),''), updated_by)
   where id = 1;
  if coalesce(p_patch->>'test_phone','') = '' and (p_patch ? 'test_phone') then
    update public.test_mode_config set test_phone = null where id = 1;
  end if;
  return public.test_mode_screen();
end $fn$;
;

-- ── 20260901211025  c573_test_mode_screen_rpc ──
-- CHANGE #573 — part 8: the admin surface. Every string here, not in Dart.

insert into public.ui_copy (key, value) values
  ('test_mode.title',            to_jsonb('Test mode'::text)),
  ('test_mode.subtitle',         to_jsonb('One synthetic lane the whole platform ignores. Nothing here reaches a real customer, supplier, rider or ledger.'::text)),
  ('test_mode.badge',            to_jsonb('TEST'::text)),
  ('test_mode.badge_hint',       to_jsonb('Synthetic row — test mode only'::text)),
  ('test_mode.off',              to_jsonb('Test mode is switched off.'::text)),
  ('test_mode.not_synthetic',    to_jsonb('That order is not a test order.'::text)),
  ('test_mode.live_keys',        to_jsonb('Razorpay is configured with LIVE keys — a test payment is refused.'::text)),
  ('test_mode.purged',           to_jsonb('Synthetic artifacts purged.'::text)),
  ('test_mode.switch_title',     to_jsonb('Kill switch'::text)),
  ('test_mode.enabled_on',       to_jsonb('Test mode is ON'::text)),
  ('test_mode.enabled_off',      to_jsonb('Test mode is OFF'::text)),
  ('test_mode.enabled_hint',     to_jsonb('Off means no synthetic order can be created at all.'::text)),
  ('test_mode.outbound_on',      to_jsonb('Messages to the test number: allowed'::text)),
  ('test_mode.outbound_off',     to_jsonb('Messages to the test number: blocked'::text)),
  ('test_mode.phone_label',      to_jsonb('Test number'::text)),
  ('test_mode.phone_hint',       to_jsonb('The only number a synthetic row may ever reach. Empty means nothing goes out at all.'::text)),
  ('test_mode.phone_none',       to_jsonb('Not set — every synthetic message is suppressed'::text)),
  ('test_mode.rzp_test',         to_jsonb('Razorpay: test keys (safe)'::text)),
  ('test_mode.rzp_live',         to_jsonb('Razorpay: LIVE keys — test payments refused'::text)),
  ('test_mode.fixtures_title',   to_jsonb('The synthetic cast'::text)),
  ('test_mode.counts_title',     to_jsonb('Synthetic rows right now'::text)),
  ('test_mode.runs_title',       to_jsonb('Recent runs'::text)),
  ('test_mode.proof_title',      to_jsonb('Proof'::text)),
  ('test_mode.proof_outbound',   to_jsonb('Messages that left the building'::text)),
  ('test_mode.proof_books',      to_jsonb('Rows that reached the books'::text)),
  ('test_mode.proof_clean',      to_jsonb('Clean — nothing sent, nothing booked'::text)),
  ('test_mode.proof_dirty',      to_jsonb('Not clean — investigate before the next run'::text)),
  ('test_mode.action_run',       to_jsonb('Run a full synthetic order'::text)),
  ('test_mode.action_purge',     to_jsonb('Purge synthetic artifacts'::text)),
  ('test_mode.action_purge_all', to_jsonb('Purge artifacts AND the cast'::text)),
  ('test_mode.confirm_purge',    to_jsonb('Delete every synthetic row? The permanent test cast is kept.'::text)),
  ('test_mode.confirm_purge_all',to_jsonb('Delete every synthetic row AND the test pharmacy, supplier and rider?'::text)),
  ('test_mode.empty_runs',       to_jsonb('No runs yet. Tap "Run a full synthetic order" to walk the pipeline end to end.'::text)),
  ('test_mode.empty_counts',     to_jsonb('No synthetic rows in the database.'::text)),
  ('test_mode.run_passed',       to_jsonb('Passed'::text)),
  ('test_mode.run_failed',       to_jsonb('Failed'::text)),
  ('test_mode.run_running',      to_jsonb('Running'::text))
on conflict (key) do update set value = excluded.value;

create or replace function public.test_mode_screen()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare c public.test_mode_config%rowtype; v_counts jsonb; v_rzp boolean;
        v_out jsonb; v_books jsonb; v_clean boolean; t text; n bigint;
begin
  if not public._test_guard() then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  perform public.test_fixtures_ensure();
  select * into c from public.test_mode_config where id = 1;
  v_rzp := public.synthetic_rzp_is_test();

  v_counts := '[]'::jsonb;
  foreach t in array array[
    'orders','order_items','inquiry','supplier_orders','deliveries','payment_claims',
    'supplier_disputes','bill_lines','pharmacy_stock','notification_log','wa_campaign_recipients']
  loop
    execute format('select count(*) from public.%I where is_synthetic', t) into n;
    if n > 0 then
      v_counts := v_counts || jsonb_build_array(jsonb_build_object(
        'key', t, 'label', t, 'count', n, 'count_label', n::text));
    end if;
  end loop;

  v_out   := public._test_outbound_count(now() - interval '7 days');
  v_books := public._test_books_touch();
  v_clean := (v_out->>'wa_queued')::int = 0
         and (v_out->>'wa_out')::int = 0
         and (v_out->>'retry_queued')::int = 0
         and (v_books->>'gst_ledger')::int = 0
         and (v_books->>'partner_settlements')::int = 0
         and (v_books->>'loyalty_ledger')::int = 0;

  return jsonb_build_object(
    'ok', true,
    'title',    public.uic('test_mode.title','Test mode'),
    'subtitle', public.uic('test_mode.subtitle',''),
    'badge',    public.synthetic_badge(true),
    'switch', jsonb_build_object(
      'title',           public.uic('test_mode.switch_title','Kill switch'),
      'enabled',         c.enabled,
      'enabled_label',   case when c.enabled then public.uic('test_mode.enabled_on','Test mode is ON')
                                             else public.uic('test_mode.enabled_off','Test mode is OFF') end,
      'enabled_tone',    case when c.enabled then 'success' else 'neutral' end,
      'enabled_hint',    public.uic('test_mode.enabled_hint',''),
      'allow_outbound',  c.allow_outbound,
      'outbound_label',  case when c.allow_outbound then public.uic('test_mode.outbound_on','')
                                                    else public.uic('test_mode.outbound_off','') end,
      'phone_label',     public.uic('test_mode.phone_label','Test number'),
      'phone_hint',      public.uic('test_mode.phone_hint',''),
      'test_phone',      c.test_phone,
      'phone_display',   coalesce(nullif(btrim(c.test_phone),''),
                                  public.uic('test_mode.phone_none','')),
      'phone_tone',      case when nullif(btrim(coalesce(c.test_phone,'')),'') is null
                              then 'neutral' else 'info' end),
    'razorpay', jsonb_build_object(
      'is_test', v_rzp,
      'label',   case when v_rzp then public.uic('test_mode.rzp_test','')
                                 else public.uic('test_mode.rzp_live','') end,
      'tone',    case when v_rzp then 'success' else 'danger' end),
    'fixtures', jsonb_build_object(
      'title', public.uic('test_mode.fixtures_title','The synthetic cast'),
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                 'key', f.key, 'kind', f.kind, 'label', f.label,
                 'id_label', coalesce(f.entity_id::text, f.detail->>'zone_id', ''),
                 'badge', public.synthetic_badge(true))
                 order by f.key) from public.test_fixture f), '[]'::jsonb)),
    'counts', jsonb_build_object(
      'title', public.uic('test_mode.counts_title','Synthetic rows right now'),
      'rows',  v_counts,
      'empty_label', public.uic('test_mode.empty_counts','')),
    'runs', jsonb_build_object(
      'title', public.uic('test_mode.runs_title','Recent runs'),
      'rows', coalesce((select jsonb_agg(x.row order by x.started desc) from (
                 select r.started_at started, jsonb_build_object(
                   'id', r.id, 'label', r.label,
                   'status', r.status,
                   'status_label', case r.status
                        when 'passed' then public.uic('test_mode.run_passed','Passed')
                        when 'failed' then public.uic('test_mode.run_failed','Failed')
                        else public.uic('test_mode.run_running','Running') end,
                   'tone', case r.status when 'passed' then 'success'
                                         when 'failed' then 'danger' else 'warning' end,
                   'started_label', to_char(r.started_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
                   'ended_label', case when r.ended_at is null then ''
                        else to_char(r.ended_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM') end,
                   'order_code', coalesce((select o.order_code from public.orders o where o.id = r.order_id), ''),
                   'badge', public.synthetic_badge(true)) row
                 from public.test_run r order by r.started_at desc limit 20) x), '[]'::jsonb),
      'empty_label', public.uic('test_mode.empty_runs','')),
    'proof', jsonb_build_object(
      'title', public.uic('test_mode.proof_title','Proof'),
      'outbound_label', public.uic('test_mode.proof_outbound',''),
      'outbound', v_out,
      'books_label', public.uic('test_mode.proof_books',''),
      'books', v_books,
      'clean', v_clean,
      'verdict', case when v_clean then public.uic('test_mode.proof_clean','')
                                   else public.uic('test_mode.proof_dirty','') end,
      'tone', case when v_clean then 'success' else 'danger' end),
    'actions', jsonb_build_array(
      jsonb_build_object('key','run_full','label', public.uic('test_mode.action_run',''),
                         'tone','brand','confirm', null),
      jsonb_build_object('key','purge','label', public.uic('test_mode.action_purge',''),
                         'tone','danger','confirm', public.uic('test_mode.confirm_purge','')),
      jsonb_build_object('key','purge_all','label', public.uic('test_mode.action_purge_all',''),
                         'tone','danger','confirm', public.uic('test_mode.confirm_purge_all',''))));
end $fn$;

grant execute on function public.test_mode_screen() to authenticated;
grant execute on function public.test_mode_set(jsonb) to authenticated;
grant execute on function public.test_run_full(text, text) to authenticated;
grant execute on function public.test_purge(boolean) to authenticated;
grant execute on function public.test_fixtures_ensure() to authenticated;
grant execute on function public.synthetic_badge(boolean) to authenticated, anon;
;

-- ── 20260901211051  c573_order_approval_allows_synthetic_customer ──
-- CHANGE #573 — the approval gate keys off orders.user_id, and a synthetic
-- order has none (orders.user_id is FK'd to auth.users and the test pharmacy is
-- deliberately not a real login). A synthetic order is admitted on its
-- customer_id instead — same approval test, same table, one row narrower.
create or replace function public.enforce_order_approval()
returns trigger language plpgsql security definer as $function$
begin
  if get_my_role() = 'super_admin' then
    return new;
  end if;

  if coalesce(new.is_synthetic, false) then
    if exists (
      select 1 from public.pharmacy_profiles
       where id = new.customer_id
         and is_synthetic
         and approved = true
         and (status is null or status not in ('suspended'))
         and (is_deleted is null or is_deleted = false)
    ) then
      return new;
    end if;
    raise exception 'account_pending_approval';
  end if;

  if not exists (
    select 1 from public.pharmacy_profiles
     where user_id = new.user_id
       and approved = true
       and (status is null or status not in ('suspended'))
       and (is_deleted is null or is_deleted = false)
  ) then
    raise exception 'account_pending_approval';
  end if;
  return new;
end;
$function$;;

-- ── 20260901211153  c573_inherit_first_and_synthetic_ladder ──
-- CHANGE #573 — two corrections the first end-to-end run found, and they are
-- the whole point of running it.
--
-- 1. The inheritance trigger was named z_synthetic_inherit, so it fired AFTER
--    every business trigger on the table. On `inquiry` that meant the supplier
--    ladder was computed while is_synthetic was still false. Inheritance must
--    be the FIRST thing that happens to a row, not the last.
-- 2. inquiry_ps_lookup ranked REAL distributors for a synthetic inquiry, and
--    compute_current_supplier_fx duly picked one — the party guard caught it.
--    A synthetic inquiry's ladder is exactly one name: the test supplier.

create or replace function public.synthetic_rule_add(
  p_child_table text, p_child_col text, p_parent_table text, p_parent_col text default 'id')
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare v_type text;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name=p_child_table
                    and column_name=p_child_col) then
    return;
  end if;
  select data_type into v_type from information_schema.columns
   where table_schema='public' and table_name=p_parent_table and column_name=p_parent_col;
  if v_type is null then return; end if;
  v_type := case v_type
              when 'uuid' then 'uuid' when 'bigint' then 'bigint'
              when 'integer' then 'integer' when 'smallint' then 'smallint'
              else 'text' end;

  insert into public.synthetic_inherit_rule (child_table, child_col, parent_table, parent_col, parent_type)
  values (p_child_table, p_child_col, p_parent_table, p_parent_col, v_type)
  on conflict (child_table, child_col) do update
    set parent_table = excluded.parent_table, parent_col = excluded.parent_col,
        parent_type  = excluded.parent_type;

  execute format('drop trigger if exists z_synthetic_inherit on public.%I', p_child_table);
  execute format('drop trigger if exists a0_synthetic_inherit on public.%I', p_child_table);
  execute format(
    'create trigger a0_synthetic_inherit before insert or update on public.%I '
    'for each row execute function public._synthetic_inherit()', p_child_table);
end $fn$;

-- Re-attach every registered child, plus the three roots, under the new name.
do $$
declare r record; t text;
begin
  for r in select distinct child_table, child_col, parent_table, parent_col
             from public.synthetic_inherit_rule loop
    perform public.synthetic_rule_add(r.child_table, r.child_col, r.parent_table, r.parent_col);
  end loop;
  foreach t in array array['pharmacy_profiles','supplier_profiles','delivery_partner_registrations'] loop
    execute format('drop trigger if exists z_synthetic_inherit on public.%I', t);
    execute format('drop trigger if exists a0_synthetic_inherit on public.%I', t);
    execute format(
      'create trigger a0_synthetic_inherit before insert or update on public.%I '
      'for each row execute function public._synthetic_inherit()', t);
  end loop;
end $$;

-- The synthetic ladder: one rung, and it is the test supplier.
create or replace function public.inquiry_ps_lookup()
returns trigger language plpgsql as $function$
DECLARE
  i int; k int := 0; j jsonb := to_jsonb(NEW);
  ps text; excluded text[] := '{}'; v_ranked jsonb; v_zone smallint; v_test text;
BEGIN
  FOR i IN 1..30 LOOP
    j := jsonb_set(j, ARRAY['PS'||i], 'null'::jsonb);
  END LOOP;

  -- CHANGE #573 — a synthetic inquiry is never offered to a real distributor.
  IF coalesce(NEW.is_synthetic, false) THEN
    SELECT label INTO v_test FROM public.test_fixture WHERE key = 'supplier';
    IF v_test IS NOT NULL THEN
      j := jsonb_set(j, ARRAY['PS1'], to_jsonb(v_test));
    END IF;
    NEW := jsonb_populate_record(NEW, j);
    NEW.zone_id := coalesce(NEW.zone_id, public.zone_default_id());
    RETURN NEW;
  END IF;

  IF NEW.product_id IS NOT NULL THEN
    v_zone := coalesce(NEW.zone_id, public.zone_default_id());
    NEW.zone_id := v_zone;

    SELECT COALESCE(array_agg(supplier_name), '{}') INTO excluded
    FROM supplier_item_memory
    WHERE product_id = NEW.product_id
      AND last_answer = 'We don''t stock this product';

    SELECT excluded || COALESCE(array_agg(g.supplier_name), '{}') INTO excluded
    FROM supplier_group_exclusion g
    JOIN "MEDICINE" m ON m.id = NEW.product_id
    WHERE (g.company  IS NULL
           OR lower(btrim(g.company))  = lower(btrim(COALESCE(m.marketer,''))))
      AND (g.category IS NULL
           OR lower(btrim(g.category)) = lower(btrim(COALESCE(m.therapeutic_class,''))));

    v_ranked := public.oi_zone_ps_payload(NEW.product_id, v_zone)->'ranked';

    FOR i IN 0..coalesce(jsonb_array_length(v_ranked),0)-1 LOOP
      ps := v_ranked->>i;
      IF ps IS NOT NULL AND btrim(ps) <> '' AND NOT (ps = ANY(excluded)) THEN
        k := k + 1;
        EXIT WHEN k > 30;
        j := jsonb_set(j, ARRAY['PS'||k], to_jsonb(ps));
      END IF;
    END LOOP;
  END IF;

  NEW := jsonb_populate_record(NEW, j);
  RETURN NEW;
END; $function$;

-- compute_current_supplier_fx only considers a supplier whose status is
-- 'active'; the fixture is created approved, so give it the status the
-- waterfall actually reads.
update public.supplier_profiles set status = 'active'
 where is_synthetic and coalesce(status,'') <> 'active';
;

-- ── 20260901211223  c573_sim_supplier_answer_states ──
create or replace function public.test_sim_supplier_answer(
  p_order_id uuid, p_available boolean default true, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_sup uuid; v_sup_name text; v_so uuid; r record; v_inq bigint;
        v_total numeric := 0; v_items jsonb := '[]'::jsonb; v_n int := 0; v_zone smallint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id, label into v_sup, v_sup_name from public.test_fixture where key='supplier';
  select zone_id into v_zone from public.orders where id = p_order_id;

  insert into public.supplier_orders (supplier_id, supplier_name, order_id, status, items,
                                      total_amount, order_date, zone_id, is_synthetic)
  values (v_sup, v_sup_name, p_order_id, 'sent', '[]'::jsonb, 0,
          (now() at time zone 'Asia/Kolkata')::date, v_zone, true)
  returning id into v_so;

  for r in select * from public.order_items where order_id = p_order_id order by created_at loop
    insert into public.inquiry (product_name, quantity, mrp, gst_percent, product_id,
                                current_supplier, "PS1", "AS1", available, out_of_stock,
                                response, current_status, inquiry_phase, supplier_order_id,
                                asked_at, zone_id, is_synthetic)
    values (r.product_name, r.quantity, r.mrp, r.gst_percent, r.product_id,
            v_sup_name, v_sup_name, case when p_available then 'Available' else 'Out of stock' end,
            p_available, not p_available,
            case when p_available then 'Available' else 'Out of stock' end,
            case when p_available then 'answered' else 'unfulfilled' end,
            'answered', v_so, now(), v_zone, true)
    returning id into v_inq;

    update public.order_items
       set inquiry_id = v_inq,
           assigned_supplier = case when p_available then v_sup_name else assigned_supplier end,
           fulfillment_state = case when p_available then 'received' else 'unfillable' end,
           received_qty      = case when p_available then r.quantity else received_qty end,
           received_at       = case when p_available then now() else received_at end,
           received_by       = case when p_available then 'test_mode' else received_by end,
           at_warehouse      = p_available,
           unfulfillable     = not p_available
     where id = r.id;

    if p_available then
      v_total := v_total + coalesce(r.line_total, 0);
      v_items := v_items || jsonb_build_object('product_id', r.product_id, 'name', r.product_name,
                                               'qty', r.quantity, 'rate', r.price);
      v_n := v_n + 1;
    end if;
  end loop;

  update public.supplier_orders set items = v_items, total_amount = v_total, trade_total = v_total
   where id = v_so;
  update public.orders set fulfillment_status = 'collecting' where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'supplier_answered',
      jsonb_build_object('supplier_order_id', v_so, 'lines', v_n, 'available', p_available));
  end if;

  return jsonb_build_object('ok', true, 'supplier_order_id', v_so, 'supplier', v_sup_name,
                            'lines_available', v_n, 'total_amount', v_total);
end $fn$;;

-- ── 20260901211252  c573_sim_supplier_answer_v3 ──
-- The supplier ANSWERING is not the warehouse RECEIVING: the real pipeline
-- refuses a receive that never went through Supplier Shop submit
-- (_enforce_receive_requires_forward). The simulation walks the same path, so
-- this hook stops exactly where a real supplier answer stops.
create or replace function public.test_sim_supplier_answer(
  p_order_id uuid, p_available boolean default true, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_sup uuid; v_sup_name text; v_so uuid; r record; v_inq bigint;
        v_total numeric := 0; v_items jsonb := '[]'::jsonb; v_n int := 0; v_zone smallint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id, label into v_sup, v_sup_name from public.test_fixture where key='supplier';
  select zone_id into v_zone from public.orders where id = p_order_id;

  insert into public.supplier_orders (supplier_id, supplier_name, order_id, status, items,
                                      total_amount, order_date, zone_id, is_synthetic)
  values (v_sup, v_sup_name, p_order_id, 'sent', '[]'::jsonb, 0,
          (now() at time zone 'Asia/Kolkata')::date, v_zone, true)
  returning id into v_so;

  for r in select * from public.order_items where order_id = p_order_id order by created_at loop
    insert into public.inquiry (product_name, quantity, mrp, gst_percent, product_id,
                                current_supplier, "PS1", "AS1", available, out_of_stock,
                                response, current_status, inquiry_phase, supplier_order_id,
                                asked_at, zone_id, is_synthetic)
    values (r.product_name, r.quantity, r.mrp, r.gst_percent, r.product_id,
            v_sup_name, v_sup_name, case when p_available then 'Available' else 'Out of stock' end,
            p_available, not p_available,
            case when p_available then 'Available' else 'Out of stock' end,
            case when p_available then 'answered' else 'unfulfilled' end,
            'answered', v_so, now(), v_zone, true)
    returning id into v_inq;

    update public.order_items
       set inquiry_id        = v_inq,
           assigned_supplier = case when p_available then v_sup_name else assigned_supplier end,
           fulfillment_state = case when p_available then 'pending' else 'unfillable' end,
           unfulfillable     = not p_available,
           unfulfillable_at  = case when p_available then null else now() end
     where id = r.id;

    if p_available then
      v_total := v_total + coalesce(r.line_total, 0);
      v_items := v_items || jsonb_build_object('product_id', r.product_id, 'name', r.product_name,
                                               'qty', r.quantity, 'rate', r.price);
      v_n := v_n + 1;
    end if;
  end loop;

  update public.supplier_orders set items = v_items, total_amount = v_total, trade_total = v_total
   where id = v_so;
  update public.orders set fulfillment_status = 'collecting' where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'supplier_answered',
      jsonb_build_object('supplier_order_id', v_so, 'lines', v_n, 'available', p_available));
  end if;

  return jsonb_build_object('ok', true, 'supplier_order_id', v_so, 'supplier', v_sup_name,
                            'lines_available', v_n, 'total_amount', v_total);
end $fn$;;

-- ── 20260901211349  c573_sim_uses_real_rebuild_path ──
-- CHANGE #573 — the simulation stops writing supplier_orders by hand.
--
-- The real path does not create that row either: inserting the ANSWERED
-- inquiry fires trg_inq_rebuild_spo, and rebuild_all_supplier_orders() builds
-- (or deletes) the supplier order for that supplier and date. A hand-written
-- row was deleted by the very next rebuild, which is exactly the bug a
-- simulation that "writes the same rows the real path writes" must not have.
--
-- Those rebuilt rows carry no order_id, so they cannot inherit the flag from
-- the order. They inherit it from the SUPPLIER instead: a purchase order to
-- the test supplier is synthetic by definition, and the test supplier is the
-- only name a synthetic inquiry ladder ever contains.
select public.synthetic_rule_add('supplier_orders','supplier_id','supplier_profiles','id');
select public.synthetic_rule_add('supplier_orders','supplier_name','supplier_profiles','supplier_name');

create or replace function public.test_sim_supplier_answer(
  p_order_id uuid, p_available boolean default true, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_sup uuid; v_sup_name text; v_so uuid; r record; v_inq bigint;
        v_n int := 0; v_zone smallint; v_date date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id, label into v_sup, v_sup_name from public.test_fixture where key='supplier';
  select zone_id into v_zone from public.orders where id = p_order_id;

  for r in select * from public.order_items where order_id = p_order_id order by created_at loop
    insert into public.inquiry (product_name, quantity, mrp, gst_percent, product_id,
                                "PS1", "AS1", asked_at, zone_id, is_synthetic)
    values (r.product_name, r.quantity, r.mrp, r.gst_percent, r.product_id,
            v_sup_name, case when p_available then 'Available' else 'Out of stock' end,
            now(), v_zone, true)
    returning id into v_inq;

    update public.order_items
       set inquiry_id        = v_inq,
           assigned_supplier = case when p_available then v_sup_name else assigned_supplier end,
           fulfillment_state = case when p_available then 'pending' else 'unfillable' end,
           unfulfillable     = not p_available,
           unfulfillable_at  = case when p_available then null else now() end
     where id = r.id;

    if p_available then v_n := v_n + 1; end if;
  end loop;

  -- built by the pipeline, not by us
  select id into v_so from public.supplier_orders
   where supplier_name = v_sup_name and order_date = v_date
   order by created_at desc limit 1;

  update public.orders set fulfillment_status = 'collecting' where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'supplier_answered',
      jsonb_build_object('supplier_order_id', v_so, 'lines', v_n, 'available', p_available));
  end if;

  return jsonb_build_object('ok', true, 'supplier_order_id', v_so, 'supplier', v_sup_name,
    'lines_available', v_n,
    'supplier_order_is_synthetic',
      coalesce((select is_synthetic from public.supplier_orders where id = v_so), false),
    'total_amount', coalesce((select total_amount from public.supplier_orders where id = v_so), 0));
end $fn$;;

-- ── 20260901211415  c573_sim_delivery_states ──
create or replace function public.test_sim_delivery_complete(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_rider uuid; v_run uuid; v_del uuid; v_zone smallint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id into v_rider from public.test_fixture where key='rider';
  select zone_id into v_zone from public.orders where id = p_order_id;

  select id into v_run from public.delivery_runs
   where partner_id = v_rider and run_date = (now() at time zone 'Asia/Kolkata')::date
   order by created_at desc limit 1;
  if v_run is null then
    insert into public.delivery_runs (partner_id, run_date, status, started_at, zone_id, is_synthetic)
    values (v_rider, (now() at time zone 'Asia/Kolkata')::date, 'started', now(), v_zone, true)
    returning id into v_run;
  end if;

  insert into public.deliveries (order_id, run_id, partner_id, assigned_at, accept_status, accepted_at,
                                 status, proof_method, receiver_name, delivered_at, attempt_no,
                                 zone_id, is_synthetic)
  values (p_order_id, v_run, v_rider, now(), 'accepted', now(), 'delivered', 'otp',
          'TEST RECEIVER (SYNTHETIC)', now(), 1, v_zone, true)
  returning id into v_del;

  insert into public.delivery_events (delivery_id, order_id, partner_id, event, note, actor)
  values (v_del, p_order_id, v_rider, 'delivered', 'simulated by test mode', 'test_mode');

  update public.orders set fulfillment_status = 'shipped', shipped_at = now() where id = p_order_id;
  update public.delivery_runs set status = 'completed', completed_at = now() where id = v_run;

  if p_run is not null then
    perform public.test_event_add(p_run, 'delivery_completed',
      jsonb_build_object('delivery_id', v_del, 'run_id', v_run));
  end if;

  return jsonb_build_object('ok', true, 'delivery_id', v_del, 'run_id', v_run);
end $fn$;;

-- ── 20260901211555  c573_sim_faithful_pipeline ──
-- CHANGE #573 — the simulation now goes through the pipeline's OWN builder.

create or replace function public.test_sim_supplier_answer(
  p_order_id uuid, p_available boolean default true, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_sup uuid; v_sup_name text; v_so uuid; r record; v_inq bigint;
        v_n int := 0; v_zone smallint; v_date date;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id, label into v_sup, v_sup_name from public.test_fixture where key='supplier';
  select zone_id, (created_at at time zone 'Asia/Kolkata')::date
    into v_zone, v_date from public.orders where id = p_order_id;

  for r in select * from public.order_items where order_id = p_order_id order by created_at loop
    insert into public.inquiry (product_name, quantity, mrp, gst_percent, product_id,
                                "PS1", "AS1", asked_at, zone_id, batch_date, is_synthetic)
    values (r.product_name, r.quantity, r.mrp, r.gst_percent, r.product_id,
            v_sup_name, case when p_available then 'Available' else 'Out of stock' end,
            now(), v_zone, coalesce(r.order_date, v_date), true)
    returning id into v_inq;

    update public.order_items
       set inquiry_id        = v_inq,
           assigned_supplier = case when p_available then v_sup_name else assigned_supplier end,
           fulfillment_state = case when p_available then 'pending' else 'unfillable' end,
           unfulfillable     = not p_available,
           unfulfillable_at  = case when p_available then null else now() end
     where id = r.id;

    if p_available then v_n := v_n + 1; end if;
  end loop;

  -- the pipeline's own builder, on the order's own IST date
  perform public.rebuild_all_supplier_orders(v_date);

  select id into v_so from public.supplier_orders
   where supplier_name = v_sup_name and order_date = v_date
   order by created_at desc limit 1;

  update public.inquiry set supplier_order_id = v_so
   where is_synthetic and supplier_order_id is null and v_so is not null
     and current_supplier = v_sup_name and batch_date = v_date;

  update public.orders set fulfillment_status = 'collecting' where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'supplier_answered',
      jsonb_build_object('supplier_order_id', v_so, 'lines', v_n, 'available', p_available));
  end if;

  return jsonb_build_object('ok', true, 'supplier_order_id', v_so, 'supplier', v_sup_name,
    'lines_available', v_n,
    'supplier_order_is_synthetic',
      coalesce((select is_synthetic from public.supplier_orders where id = v_so), false),
    'total_amount', coalesce((select total_amount from public.supplier_orders where id = v_so), 0));
end $fn$;

-- The UPI claim is always simulated; only the RAZORPAY leg is refused when
-- live keys are configured, and it says so instead of failing the run.
create or replace function public.test_sim_payment_capture(
  p_order_id uuid, p_amount numeric default null, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_amt numeric; v_claim uuid; v_att uuid; v_utr text; v_test boolean; v_rzp text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;

  select coalesce(p_amount, total_amount, 0) into v_amt from public.orders where id = p_order_id;
  v_utr  := 'TEST' || to_char(now(),'YYYYMMDDHH24MISS');
  v_test := public.synthetic_rzp_is_test();

  insert into public.payment_claims (order_id, sender_phone, sender_type, amount, utr, app,
                                     status, payment_method, received_at, paid_ts, is_synthetic)
  values (p_order_id, '9000000573', 'customer', v_amt, v_utr, 'TEST', 'verified', 'upi',
          now(), now(), true)
  returning id into v_claim;

  if v_test then
    insert into public.rzp_payment_attempt (order_id, kind, mode, amount, status,
                                            rzp_payment_id, reference_id, attempted_at, paid_at, is_synthetic)
    values (p_order_id, 'checkout', 'test', v_amt, 'paid',
            'pay_TEST' || to_char(now(),'YYYYMMDDHH24MISS'), v_utr, now(), now(), true)
    returning id into v_att;
    v_rzp := 'simulated';
  else
    v_rzp := 'refused_live_keys';
  end if;

  update public.orders set payment_id = v_utr where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'payment_captured',
      jsonb_build_object('claim_id', v_claim, 'attempt_id', v_att, 'amount', v_amt, 'razorpay', v_rzp));
  end if;

  return jsonb_build_object('ok', true, 'claim_id', v_claim, 'attempt_id', v_att, 'amount', v_amt,
    'razorpay', v_rzp, 'razorpay_test_keys', v_test,
    'razorpay_message', case when v_test then public.uic('test_mode.rzp_test','')
                                         else public.uic('test_mode.live_keys','') end);
end $fn$;

-- Delivery closes the line the way the real one does, so the invoice step has
-- something to bill.
create or replace function public.test_sim_delivery_complete(p_order_id uuid, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_rider uuid; v_run uuid; v_del uuid; v_zone smallint;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id into v_rider from public.test_fixture where key='rider';
  select zone_id into v_zone from public.orders where id = p_order_id;

  select id into v_run from public.delivery_runs
   where partner_id = v_rider and run_date = (now() at time zone 'Asia/Kolkata')::date
   order by created_at desc limit 1;
  if v_run is null then
    insert into public.delivery_runs (partner_id, run_date, status, started_at, zone_id, is_synthetic)
    values (v_rider, (now() at time zone 'Asia/Kolkata')::date, 'started', now(), v_zone, true)
    returning id into v_run;
  end if;

  insert into public.deliveries (order_id, run_id, partner_id, assigned_at, accept_status, accepted_at,
                                 status, proof_method, receiver_name, delivered_at, attempt_no,
                                 zone_id, is_synthetic)
  values (p_order_id, v_run, v_rider, now(), 'accepted', now(), 'delivered', 'otp',
          'TEST RECEIVER (SYNTHETIC)', now(), 1, v_zone, true)
  returning id into v_del;

  insert into public.delivery_events (delivery_id, order_id, partner_id, event, note, actor)
  values (v_del, p_order_id, v_rider, 'delivered', 'simulated by test mode', 'test_mode');

  update public.order_items set fulfillment_state = 'shipped'
   where order_id = p_order_id and coalesce(unfulfillable,false) = false;
  update public.orders set fulfillment_status = 'shipped', shipped_at = now()
   where id = p_order_id;
  update public.delivery_runs set status = 'completed', completed_at = now() where id = v_run;

  if p_run is not null then
    perform public.test_event_add(p_run, 'delivery_completed',
      jsonb_build_object('delivery_id', v_del, 'run_id', v_run));
  end if;

  return jsonb_build_object('ok', true, 'delivery_id', v_del, 'run_id', v_run);
end $fn$;;

-- ── 20260901211615  c573_run_full_verdict ──
create or replace function public.test_run_full(p_label text default null, p_kind text default 'manual')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_run bigint; v_t timestamptz := now(); v_order uuid;
        v_o jsonb; v_s jsonb; v_p jsonb; v_d jsonb; v_inv jsonb;
        v_out jsonb; v_books jsonb; v_ok boolean;
        v_fy text := public._fy_ist(); v_before int; v_after int; v_series jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  v_run := public.test_run_open(coalesce(p_label,'synthetic order end-to-end'), coalesce(p_kind,'manual'));
  select next_no into v_before from public.customer_invoice_series where fy = v_fy;

  v_o := public.test_order_create(2, v_run);
  if not coalesce((v_o->>'ok')::boolean,false) then
    update public.test_run set status='failed', ended_at=now(), note = v_o::text where id = v_run;
    return jsonb_build_object('ok', false, 'run_id', v_run, 'stage','order', 'detail', v_o);
  end if;
  v_order := (v_o->>'order_id')::uuid;

  v_s := public.test_sim_supplier_answer(v_order, true, v_run);
  v_p := public.test_sim_payment_capture(v_order, null, v_run);
  v_d := public.test_sim_delivery_complete(v_order, v_run);
  v_inv := public.customer_invoice_issue(v_order);

  select next_no into v_after from public.customer_invoice_series where fy = v_fy;
  v_series := jsonb_build_object(
    'synthetic_invoice_no', v_inv->>'invoice_no',
    'real_series_fy', v_fy,
    'real_series_next_before', v_before,
    'real_series_next_after',  v_after,
    'real_series_untouched', coalesce(v_before, 0) = coalesce(v_after, 0),
    'synthetic_series_next',
      (select next_no from public.customer_invoice_series where fy = 'TEST-' || v_fy));

  v_out   := public._test_outbound_count(v_t);
  v_books := public._test_books_touch();

  v_ok := coalesce((v_s->>'ok')::boolean,false)
      and coalesce((v_p->>'ok')::boolean,false)
      and coalesce((v_d->>'ok')::boolean,false)
      and coalesce((v_s->>'supplier_order_is_synthetic')::boolean,false)
      and coalesce((v_series->>'real_series_untouched')::boolean,false)
      and (v_out->>'wa_queued')::int = 0
      and (v_out->>'wa_out')::int = 0
      and (v_out->>'retry_queued')::int = 0
      and (v_books->>'gst_ledger')::int = 0
      and (v_books->>'partner_settlements')::int = 0
      and (v_books->>'loyalty_ledger')::int = 0;

  update public.test_run
     set status = case when v_ok then 'passed' else 'failed' end,
         ended_at = now(), order_id = v_order,
         steps = jsonb_build_array(v_o, v_s, v_p, v_d, v_inv)
   where id = v_run;

  return jsonb_build_object('ok', v_ok, 'run_id', v_run, 'order_id', v_order,
    'order_code', v_o->>'order_code', 'supplier', v_s, 'payment', v_p, 'delivery', v_d,
    'invoice', v_inv, 'invoice_series', v_series, 'outbound', v_out, 'books', v_books);
end $fn$;;

-- ── 20260901211700  c573_dedicated_test_zone ──
-- CHANGE #573 — the synthetic lane gets a zone of its own.
--
-- `inquiry` is unique on (product_id, batch_date, zone_id): one ask per
-- product per day per zone. Sharing a live zone means a test order either
-- collides with a real ask for the same medicine or, worse, overwrites it.
-- A zone the synthetic cast alone lives in removes the collision entirely and
-- is what "a test zone assignment" in the spec means. It is is_active=false, so
-- no live zone picker, route plan or zone-scoped list offers it.

insert into public.zones (id, code, name, is_active, is_default)
values (99, 'tst', 'TEST ZONE - SYNTHETIC (DO NOT USE)', false, false)
on conflict (id) do update set code = excluded.code, name = excluded.name,
                               is_active = false, is_default = false;

create or replace function public._test_zone()
returns smallint language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(
    (select id from public.zones where code = 'tst'),
    (select id from public.zones order by coalesce(is_default,false) desc, id limit 1));
$fn$;

update public.pharmacy_profiles              set zone_id = public._test_zone() where is_synthetic;
update public.supplier_profiles              set zone_id = public._test_zone() where is_synthetic;
update public.delivery_partner_registrations set zone_id = public._test_zone() where is_synthetic;
update public.test_fixture
   set detail = detail || jsonb_build_object('zone_id', public._test_zone());
update public.test_fixture
   set label = coalesce((select 'Zone ' || coalesce(z.code, z.name, z.id::text)
                           from public.zones z where z.id = public._test_zone()), label)
 where key = 'zone';

-- Anything already written on a live zone by an earlier rehearsal moves too.
update public.orders      set zone_id = public._test_zone() where is_synthetic;
update public.order_items set zone_id = public._test_zone() where is_synthetic;
update public.inquiry     set zone_id = public._test_zone() where is_synthetic;;

-- ── 20260901211827  c573_zone_is_the_root_flag ──
-- CHANGE #573 — the zone is a root entity too, and that closes the last hole.
--
-- Inserting order_items auto-creates the inquiry row (the pipeline's own
-- broadcast), and that row has no order link at all — so it was created
-- is_synthetic = FALSE from a synthetic order. Every such orphan lives in the
-- test ZONE, and the test zone is synthetic by definition, so the zone is the
-- parent that was missing. Anything born in zone 'tst' is synthetic, full stop.

alter table public.zones add column if not exists is_synthetic boolean not null default false;
update public.zones set is_synthetic = (code = 'tst');

drop trigger if exists a0_synthetic_inherit on public.zones;
create trigger a0_synthetic_inherit before insert or update on public.zones
  for each row execute function public._synthetic_inherit();

select public.synthetic_rule_add('inquiry','zone_id','zones','id');
select public.synthetic_rule_add('orders','zone_id','zones','id');
select public.synthetic_rule_add('order_items','zone_id','zones','id');
select public.synthetic_rule_add('supplier_orders','zone_id','zones','id');
select public.synthetic_rule_add('deliveries','zone_id','zones','id');
select public.synthetic_rule_add('delivery_runs','zone_id','zones','id');
select public.synthetic_rule_add('payment_claims','zone_id','zones','id');
select public.synthetic_rule_add('order_alert','zone_id','zones','id');
select public.synthetic_rule_add('pharmacy_profiles','zone_id','zones','id');
select public.synthetic_rule_add('supplier_profiles','zone_id','zones','id');
select public.synthetic_rule_add('delivery_partner_registrations','zone_id','zones','id');

-- The supplier answer now UPDATES the inquiry the pipeline already created —
-- which is what a real supplier answer does — and only inserts when there is
-- none.
create or replace function public.test_sim_supplier_answer(
  p_order_id uuid, p_available boolean default true, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_sup uuid; v_sup_name text; v_so uuid; r record; v_inq bigint;
        v_n int := 0; v_zone smallint; v_date date; v_ans text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;
  perform public.test_fixtures_ensure();
  select entity_id, label into v_sup, v_sup_name from public.test_fixture where key='supplier';
  select zone_id, (created_at at time zone 'Asia/Kolkata')::date
    into v_zone, v_date from public.orders where id = p_order_id;
  v_ans := case when p_available then 'Available' else 'Out of stock' end;

  for r in select * from public.order_items where order_id = p_order_id order by created_at loop
    select id into v_inq from public.inquiry
     where product_id = r.product_id
       and batch_date = coalesce(r.order_date, v_date)
       and zone_id = v_zone
     limit 1;

    if v_inq is null then
      insert into public.inquiry (product_name, quantity, mrp, gst_percent, product_id,
                                  "PS1", "AS1", asked_at, zone_id, batch_date, is_synthetic)
      values (r.product_name, r.quantity, r.mrp, r.gst_percent, r.product_id,
              v_sup_name, v_ans, now(), v_zone, coalesce(r.order_date, v_date), true)
      returning id into v_inq;
    else
      update public.inquiry
         set "PS1" = v_sup_name, "AS1" = v_ans, asked_at = now(),
             quantity = r.quantity, mrp = coalesce(mrp, r.mrp)
       where id = v_inq;
    end if;

    update public.order_items
       set inquiry_id        = v_inq,
           assigned_supplier = case when p_available then v_sup_name else assigned_supplier end,
           fulfillment_state = case when p_available then 'pending' else 'unfillable' end,
           unfulfillable     = not p_available,
           unfulfillable_at  = case when p_available then null else now() end
     where id = r.id;

    if p_available then v_n := v_n + 1; end if;
  end loop;

  perform public.rebuild_all_supplier_orders(v_date);

  select id into v_so from public.supplier_orders
   where supplier_name = v_sup_name and order_date = v_date
   order by created_at desc limit 1;

  update public.inquiry set supplier_order_id = v_so
   where is_synthetic and supplier_order_id is null and v_so is not null
     and current_supplier = v_sup_name and batch_date = v_date;

  update public.orders set fulfillment_status = 'collecting' where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'supplier_answered',
      jsonb_build_object('supplier_order_id', v_so, 'lines', v_n, 'available', p_available));
  end if;

  return jsonb_build_object('ok', true, 'supplier_order_id', v_so, 'supplier', v_sup_name,
    'lines_available', v_n,
    'supplier_order_is_synthetic',
      coalesce((select is_synthetic from public.supplier_orders where id = v_so), false),
    'total_amount', coalesce((select total_amount from public.supplier_orders where id = v_so), 0));
end $fn$;;

-- ── 20260901211857  c573_sim_payment_method ──
create or replace function public.test_sim_payment_capture(
  p_order_id uuid, p_amount numeric default null, p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_amt numeric; v_claim uuid; v_att uuid; v_utr text; v_test boolean; v_rzp text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if not exists (select 1 from public.orders where id = p_order_id and is_synthetic) then
    return jsonb_build_object('ok', false, 'error','not_synthetic',
      'message', public.uic('test_mode.not_synthetic','That order is not a test order.'));
  end if;

  select coalesce(p_amount, total_amount, 0) into v_amt from public.orders where id = p_order_id;
  v_utr  := 'TEST' || to_char(now(),'YYYYMMDDHH24MISS');
  v_test := public.synthetic_rzp_is_test();

  insert into public.payment_claims (order_id, sender_phone, sender_type, amount, utr, app,
                                     status, payment_method, received_at, paid_ts, is_synthetic)
  values (p_order_id, '9000000573', 'customer', v_amt, v_utr, 'TEST', 'verified', 'online',
          now(), now(), true)
  returning id into v_claim;

  if v_test then
    insert into public.rzp_payment_attempt (order_id, kind, mode, amount, status,
                                            rzp_payment_id, reference_id, attempted_at, paid_at, is_synthetic)
    values (p_order_id, 'checkout', 'test', v_amt, 'paid',
            'pay_TEST' || to_char(now(),'YYYYMMDDHH24MISS'), v_utr, now(), now(), true)
    returning id into v_att;
    v_rzp := 'simulated';
  else
    v_rzp := 'refused_live_keys';
  end if;

  update public.orders set payment_id = v_utr where id = p_order_id;

  if p_run is not null then
    perform public.test_event_add(p_run, 'payment_captured',
      jsonb_build_object('claim_id', v_claim, 'attempt_id', v_att, 'amount', v_amt, 'razorpay', v_rzp));
  end if;

  return jsonb_build_object('ok', true, 'claim_id', v_claim, 'attempt_id', v_att, 'amount', v_amt,
    'razorpay', v_rzp, 'razorpay_test_keys', v_test,
    'razorpay_message', case when v_test then public.uic('test_mode.rzp_test','')
                                         else public.uic('test_mode.live_keys','') end);
end $fn$;;

-- ── 20260901212005  c573_proof_function ──
-- CHANGE #573 — the permanent proof. Every claim the spec makes, asserted.
create or replace function public.c573_proof()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v jsonb := '[]'::jsonb; v_ok boolean := true; v_run jsonb; v_order uuid;
        n int; m int; v_err text; v_sup_real text; v_zone smallint := public._test_zone();
        v_purge jsonb; v_phone_before text;

  procedure_note text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  -- 0. clean slate
  perform public.test_purge(false);

  -- 1. a full synthetic order, end to end
  v_run := public.test_run_full('c573_proof — full lap','proof');
  v_order := (v_run->>'order_id')::uuid;
  v := v || jsonb_build_array(jsonb_build_object('check','full lap runs end to end',
        'pass', coalesce((v_run->>'ok')::boolean,false), 'detail', v_run->'order_code'));

  -- 2. every child of that order inherited the flag, by trigger
  select count(*) into n from public.order_items where order_id = v_order and not is_synthetic;
  select count(*) into m from public.inquiry i
    join public.order_items oi on oi.inquiry_id = i.id
   where oi.order_id = v_order and not i.is_synthetic;
  v := v || jsonb_build_array(jsonb_build_object('check','children inherit is_synthetic',
        'pass', n = 0 and m = 0, 'detail', jsonb_build_object('unflagged_items', n, 'unflagged_inquiries', m)));

  -- 3. NOTHING went out
  select count(*) into n from public.wa_campaign_recipients
   where is_synthetic and coalesce(status,'') <> 'skipped';
  select count(*) into m from public.whatsapp_messages
   where is_synthetic and coalesce(direction,'') = 'out' and coalesce(wa_status,'') <> 'suppressed';
  v := v || jsonb_build_array(jsonb_build_object('check','zero outbound messages',
        'pass', n = 0 and m = 0, 'detail', jsonb_build_object('wa_queued', n, 'wa_out', m)));

  -- 4. NOTHING reached the books
  select (select count(*) from public.gst_ledger where is_synthetic)
       + (select count(*) from public.pharmacy_gst_ledger where is_synthetic)
       + (select count(*) from public.partner_settlements where is_synthetic)
       + (select count(*) from public.loyalty_ledger where is_synthetic)
       + (select count(*) from public.order_pnl_slab where is_synthetic) into n;
  v := v || jsonb_build_array(jsonb_build_object('check','zero rows in the books',
        'pass', n = 0, 'detail', jsonb_build_object('book_rows', n,
          'blocked_and_logged', (select count(*) from public.synthetic_blocked_write))));

  -- 5. the books' own view cannot see it
  select count(*) into n from books.orders where id = v_order;
  select count(*) into m from books.order_items where order_id = v_order;
  v := v || jsonb_build_array(jsonb_build_object('check','books views exclude the synthetic order',
        'pass', n = 0 and m = 0, 'detail', jsonb_build_object('books_orders', n, 'books_items', m)));

  -- 6. no real party is named anywhere on a synthetic row
  select count(*) into n from public.supplier_orders
   where is_synthetic and not public.synthetic_supplier_is(supplier_name, supplier_id);
  select count(*) into m from public.orders o
   where o.is_synthetic and not exists (
     select 1 from public.pharmacy_profiles p where p.id = o.customer_id and p.is_synthetic);
  v := v || jsonb_build_array(jsonb_build_object('check','only synthetic parties on synthetic rows',
        'pass', n = 0 and m = 0, 'detail', jsonb_build_object('real_suppliers', n, 'real_customers', m)));

  -- 7. the invariant REFUSES the cross-over (a real supplier on a test order)
  select supplier_name into v_sup_real from public.supplier_profiles
   where not is_synthetic and coalesce(is_deleted,false) = false limit 1;
  begin
    insert into public.supplier_orders (supplier_name, order_id, order_date, is_synthetic)
    values (v_sup_real, v_order, (now() at time zone 'Asia/Kolkata')::date, true);
    v_err := 'NOT REFUSED';
  exception when others then v_err := sqlerrm;
  end;
  v := v || jsonb_build_array(jsonb_build_object('check','a real supplier cannot be put on a test order',
        'pass', v_err like 'synthetic_party_mismatch%', 'detail', left(v_err, 120)));

  -- 8. GO-LIVE SAFE: the protection is the FLAG, not the 9000000xxx number.
  select phone into v_phone_before from public.supplier_profiles
   where id = (select entity_id from public.test_fixture where key='supplier');
  update public.supplier_profiles set phone = '9827012345', whatsapp_no = '9827012345'
   where id = (select entity_id from public.test_fixture where key='supplier');
  insert into public.wa_campaign_recipients (campaign_id, phone, is_event, is_synthetic)
  select id, '9827012345', true, true from public.wa_campaigns limit 1;
  select count(*) into n from public.wa_campaign_recipients
   where is_synthetic and phone = '9827012345' and coalesce(status,'') <> 'skipped';
  update public.supplier_profiles set phone = v_phone_before, whatsapp_no = v_phone_before
   where id = (select entity_id from public.test_fixture where key='supplier');
  v := v || jsonb_build_array(jsonb_build_object(
        'check','still suppressed with a REAL-looking number (post supplier_number restore)',
        'pass', n = 0, 'detail', jsonb_build_object('leaked', n)));

  -- 9. the kill switch actually stops a run
  update public.test_mode_config set enabled = false where id = 1;
  v_err := (public.test_order_create(1, null))->>'error';
  update public.test_mode_config set enabled = true where id = 1;
  v := v || jsonb_build_array(jsonb_build_object('check','kill switch blocks new synthetic orders',
        'pass', v_err = 'test_mode_off', 'detail', v_err));

  -- 10. purge leaves nothing behind
  v_purge := public.test_purge(false);
  select (select count(*) from public.orders where is_synthetic)
       + (select count(*) from public.order_items where is_synthetic)
       + (select count(*) from public.inquiry where is_synthetic)
       + (select count(*) from public.supplier_orders where is_synthetic)
       + (select count(*) from public.deliveries where is_synthetic)
       + (select count(*) from public.payment_claims where is_synthetic) into n;
  select count(*) into m from public.test_fixture;
  v := v || jsonb_build_array(jsonb_build_object('check','purge removes artifacts and keeps the cast',
        'pass', n = 0 and m = 4, 'detail', jsonb_build_object('left_over', n, 'fixtures', m,
          'deleted', v_purge->'total')));

  select bool_and((x->>'pass')::boolean) into v_ok from jsonb_array_elements(v) x;
  return jsonb_build_object('ok', v_ok, 'checks', v,
    'passed', (select count(*) from jsonb_array_elements(v) x where (x->>'pass')::boolean),
    'total', jsonb_array_length(v));
end $fn$;;

-- ── 20260901212148  c573_rls_synthetic_hidden_a2 ──
drop policy if exists c573_synthetic_hidden on public.supplier_orders;
create policy c573_synthetic_hidden on public.supplier_orders as restrictive for select
  to authenticated, anon using (not coalesce(is_synthetic,false) or public.is_admin());;

-- ── 20260901212158  c573_rls_synthetic_hidden_b ──
drop policy if exists c573_synthetic_hidden on public.inquiry;
create policy c573_synthetic_hidden on public.inquiry as restrictive for select
  to authenticated, anon using (not coalesce(is_synthetic,false) or public.is_admin());
drop policy if exists c573_synthetic_hidden on public.deliveries;
create policy c573_synthetic_hidden on public.deliveries as restrictive for select
  to authenticated, anon using (not coalesce(is_synthetic,false) or public.is_admin());
drop policy if exists c573_synthetic_hidden on public.order_items;
create policy c573_synthetic_hidden on public.order_items as restrictive for select
  to authenticated, anon using (not coalesce(is_synthetic,false) or public.is_admin());;

-- ── 20260901212251  c573_rls_synthetic_hidden_orders ──
drop policy if exists c573_synthetic_hidden on public.orders;
create policy c573_synthetic_hidden on public.orders as restrictive for select
  to authenticated, anon using (not coalesce(is_synthetic,false) or public.is_admin());;

-- ── 20260901212300  c573_rls_synthetic_hidden_profiles ──
drop policy if exists c573_synthetic_hidden on public.supplier_profiles;
create policy c573_synthetic_hidden on public.supplier_profiles as restrictive for select
  to authenticated, anon using (not coalesce(is_synthetic,false) or public.is_admin());
drop policy if exists c573_synthetic_hidden on public.pharmacy_profiles;
create policy c573_synthetic_hidden on public.pharmacy_profiles as restrictive for select
  to authenticated, anon using (not coalesce(is_synthetic,false) or public.is_admin());;

-- ── 20260901212609  c573_feature_registry_test_mode ──
-- CHANGE #573 — the entry point. Two rows, the same shape Cron health uses:
-- one on the Admin & System dashboard, one in Dev tools. Super-admin only —
-- this screen can delete data and flip a platform switch.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, deep_link, search_terms, description)
values
  ('admin.test_mode', 'Test mode', 'Admin & System', 'science', 'test_mode', 955,
   'medibo', false, 'none', true, 'system', 'dashboard',
   array['super_admin'], '/admin/test-mode',
   'test mode synthetic fixtures purge kill switch dry run',
   'The synthetic lane: test fixtures, a full simulated order, and the purge'),
  ('devtool.test_mode', 'Test mode', 'Runtime & health', 'science', 'test_mode', 45,
   'medibo', false, 'none', true, 'system', 'dev_tools',
   array['super_admin'], null,
   'test mode synthetic fixtures purge kill switch dry run heartbeat',
   'The synthetic lane: test fixtures, a full simulated order, and the purge')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      sort_order = excluded.sort_order, is_active = true,
      category = excluded.category, surface = excluded.surface,
      roles_allowed = excluded.roles_allowed, deep_link = excluded.deep_link,
      search_terms = excluded.search_terms, description = excluded.description;;

-- ── 20260901213046  c573_migration_mirror_reader ──
-- CHANGE #573 — lets the runner mirror applied migrations back into git
-- without a round trip through an agent's context. Service-role only.
create or replace function public.dev_migration_sql(p_prefix text, p_from text default '0')
returns text language plpgsql security definer set search_path to 'public' as $fn$
declare v text;
begin
  if not public._dev_guard() then raise exception 'not_authorized'; end if;
  select string_agg(
           '-- ── ' || m.version || '  ' || m.name || E' ──\n'
           || array_to_string(m.statements, E';\n') || E';\n',
           E'\n' order by m.version)
    into v
    from supabase_migrations.schema_migrations m
   where m.name like p_prefix || '%' and m.version >= p_from;
  return coalesce(v, '');
end $fn$;;

-- ── 20260901213122  c573_migration_mirror_reader_v2 ──
create or replace function public.dev_migration_sql(p_prefix text, p_from text default '0')
returns text language plpgsql security definer set search_path to 'public' as $fn$
declare v text;
begin
  perform public._dev_guard();   -- raises unless service_role / super_admin
  select string_agg(
           '-- ── ' || m.version || '  ' || m.name || E' ──' || E'\n'
           || array_to_string(m.statements, E';\n') || E';\n',
           E'\n' order by m.version)
    into v
    from supabase_migrations.schema_migrations m
   where m.name like p_prefix || '%' and m.version >= p_from;
  return coalesce(v, '');
end $fn$;;

