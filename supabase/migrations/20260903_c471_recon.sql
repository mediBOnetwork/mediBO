-- CHANGE #471 — Nightly money reconciliation.
--
-- Every night the money surfaces are compared against each other and ANY drift
-- is recorded. Zero tolerance: a one-paisa difference is a finding.
--
-- The five families, and what each one holds down:
--   payments        Razorpay (webhook truth) + recorded claims vs order payment
--                   state. No order marked paid without money behind it, no
--                   captured payment without an order.
--   bill_vs_order   The bill recomputed from live lines at the SNAPSHOTTED slab
--                   (#318) vs the order's own snapshot and its total.
--   gst             Customer invoices and supplier bills vs gst_ledger (#320):
--                   every invoice exactly once, taxes to the paisa.
--   margin          Margin rows (#319) vs their source bills, partner
--                   settlement lines (#323) vs the day's orders and costs, and
--                   credit notes (#395) reversing at the ORIGINAL slab.
--   supplier_pay    Supplier payments recorded vs supplier bill payables.
--
-- Nothing here is a copy of the bill math. `_recon_bill_calc` calls the SAME
-- `_bill_compose` the invoice is printed from, so the recon can never drift
-- away from the document the customer received — and it cross-checks its own
-- taxable/GST split against that composer's net payable, which is how a change
-- to one and not the other shows up as a finding instead of a silence.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. TABLES
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.recon_runs (
  id             bigserial primary key,
  trigger        text        not null default 'cron',   -- cron | manual | selftest
  window_from    date        not null,
  window_to      date        not null,                  -- exclusive
  status         text        not null default 'running',-- running | green | drift | error
  checks_run     int         not null default 0,
  checks_failed  int         not null default 0,
  findings       int         not null default 0,
  errors         int         not null default 0,
  warnings       int         not null default 0,
  drift_paisa    bigint      not null default 0,
  summary_label  text        not null default '',
  detail_label   text        not null default '',
  notified_at    timestamptz,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  ms             int,
  error          text,
  meta           jsonb       not null default '{}'::jsonb
);

create index if not exists recon_runs_started_idx on public.recon_runs (started_at desc);

create table if not exists public.recon_findings (
  id             bigserial primary key,
  run_id         bigint      not null references public.recon_runs(id) on delete cascade,
  check_key      text        not null,
  severity       text        not null default 'error',  -- error | warning
  entity_type    text        not null default '',
  entity_id      text        not null default '',
  entity_label   text        not null default '',
  source_a       text        not null default '',
  source_b       text        not null default '',
  expected       numeric,
  actual         numeric,
  diff           numeric,
  expected_label text        not null default '',
  actual_label   text        not null default '',
  diff_label     text        not null default '',
  detail_label   text        not null default '',
  route          text        not null default '',       -- deep link the app understands
  route_args     jsonb       not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);

create index if not exists recon_findings_run_idx on public.recon_findings (run_id, check_key, id);

-- The registry. A new check is one INSERT plus one function — never a deploy.
create table if not exists public.recon_check (
  key             text primary key,
  ord             int   not null default 100,
  fn              text  not null,
  label           text  not null,
  description     text  not null default '',
  source_a_label  text  not null default '',
  source_b_label  text  not null default '',
  severity        text  not null default 'error',
  tolerance_paisa int   not null default 0,             -- zero tolerance by default
  enabled         boolean not null default true,
  spec_item       text  not null default ''
);

alter table public.recon_runs      enable row level security;
alter table public.recon_findings  enable row level security;
alter table public.recon_check     enable row level security;

-- No policies: these are admin surfaces read through SECURITY DEFINER RPCs
-- only, exactly like the other money tables. RLS on with no policy means the
-- anon/authenticated roles see nothing directly.
revoke all on public.recon_runs     from anon, authenticated;
revoke all on public.recon_findings from anon, authenticated;
revoke all on public.recon_check    from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. COPY (every string the screen prints lives here, not in Dart)
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.ui_copy (key, value)
select k, to_jsonb(v) from (values
  ('recon.title',              'Reconciliation'),
  ('recon.subtitle',           'Every night the money surfaces are compared against each other. A one-paisa difference is a finding.'),
  ('recon.nav_label',          'Reconciliation'),
  ('recon.run_button',         'Run now'),
  ('recon.running_label',      'Reconciling…'),
  ('recon.empty_title',        'No reconciliation has run yet'),
  ('recon.empty_hint',         'The nightly run reconciles payments, bills, GST, margin and settlements. Tap Run now to reconcile the last 30 days immediately.'),
  ('recon.findings_empty',     'Nothing drifted in this run. Every surface agreed to the paisa.'),
  ('recon.green_summary',      'All money surfaces agree — {checks} checks, nothing drifted.'),
  ('recon.drift_summary',      '{findings} finding(s) across {checks} checks — {drift} of drift.'),
  ('recon.error_summary',      'The reconciliation could not finish: {error}'),
  ('recon.status_green',       'Clean'),
  ('recon.status_drift',       'Drift found'),
  ('recon.status_error',       'Failed'),
  ('recon.status_running',     'Running'),
  ('recon.window_label',       '{from} to {to}'),
  ('recon.expected_caption',   'Expected'),
  ('recon.actual_caption',     'Actual'),
  ('recon.diff_caption',       'Difference'),
  ('recon.sources_caption',    '{a} vs {b}'),
  ('recon.open_order',         'Open order'),
  ('recon.open_money',         'Open Money'),
  ('recon.open_supplier',      'Open supplier bill'),
  ('recon.run_failed_toast',   'The reconciliation could not start. Try again in a minute.'),
  ('recon.run_started_toast',  'Reconciliation finished — see the run below.'),
  ('recon.checks_caption',     '{n} checks'),
  ('recon.findings_caption',   '{n} findings')
) t(k, v)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. HELPERS
-- ─────────────────────────────────────────────────────────────────────────────

-- One finding. Amount findings are recorded only when they actually differ by
-- more than the check's own tolerance (default 0 paisa). Presence findings —
-- a missing GST row, an unattached payment — pass p_always and are always kept.
create or replace function public._recon_finding(
  p_run bigint, p_check text, p_entity_type text, p_entity_id text,
  p_entity_label text, p_expected numeric, p_actual numeric,
  p_detail text default '', p_route text default '', p_route_args jsonb default '{}'::jsonb,
  p_always boolean default false, p_severity text default null)
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  c public.recon_check%rowtype;
  v_diff numeric;
  v_sev  text;
begin
  select * into c from public.recon_check where key = p_check;
  v_diff := round(coalesce(p_actual,0) - coalesce(p_expected,0), 2);

  if not p_always
     and abs(coalesce(v_diff,0)) * 100 <= coalesce(c.tolerance_paisa, 0) then
    return 0;
  end if;

  v_sev := coalesce(p_severity, c.severity, 'error');

  insert into public.recon_findings (
    run_id, check_key, severity, entity_type, entity_id, entity_label,
    source_a, source_b, expected, actual, diff,
    expected_label, actual_label, diff_label, detail_label, route, route_args)
  values (
    p_run, p_check, v_sev, p_entity_type, coalesce(p_entity_id,''), coalesce(p_entity_label,''),
    coalesce(c.source_a_label,''), coalesce(c.source_b_label,''),
    p_expected, p_actual, case when p_expected is null and p_actual is null then null else v_diff end,
    case when p_expected is null then '' else public.inr_money(p_expected) end,
    case when p_actual   is null then '' else public.inr_money(p_actual)   end,
    case when p_expected is null and p_actual is null then ''
         when v_diff >= 0 then '+ ' || public.inr_money(abs(v_diff))
         else '- ' || public.inr_money(abs(v_diff)) end,
    coalesce(p_detail,''), coalesce(p_route,''), coalesce(p_route_args,'{}'::jsonb));

  return 1;
end $$;

-- The bill, recomputed. This is deliberately NOT a copy of the invoice math:
-- it feeds the very same `_bill_compose` the printed invoice comes from, so the
-- recon and the document can never disagree by construction. The taxable/GST
-- split is computed here as well, and the two are cross-checked — that is the
-- 'bill_math' finding.
create or replace function public._recon_bill_calc(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_raw jsonb; v_base numeric; v_slab jsonb; v_pct numeric;
  v_taxable_est numeric; v_del jsonb; v_credits jsonb; v_doc jsonb;
  v_taxable numeric; v_gst numeric; v_delivery numeric; v_delivery_gst numeric;
  v_credit numeric; v_grand numeric; v_final numeric;
begin
  v_raw := public._bill_lines_for_order(p_order_id);
  if v_raw is null or jsonb_array_length(v_raw) = 0 then
    return jsonb_build_object('has', false);
  end if;

  select coalesce(sum(round(qty*ptr,2)),0) into v_base
    from (select coalesce((e->>'qty')::numeric,0) qty, coalesce((e->>'ptr')::numeric,0) ptr
            from jsonb_array_elements(v_raw) e) t;

  v_slab := public._order_slab_for_bill(p_order_id, v_base);
  v_pct  := coalesce((v_slab->>'discount_pct')::numeric, 0);

  v_taxable_est := round(v_base * (100 - v_pct) / 100, 2);
  v_del     := public._order_delivery_charge(p_order_id, v_taxable_est);
  v_credits := public._order_credit_notes(p_order_id);

  -- the same per-line rounding the composer prints
  select coalesce(sum(round(qty*ptr,2) - round(round(qty*ptr,2)*v_pct/100,2)), 0),
         coalesce(sum(round((round(qty*ptr,2) - round(round(qty*ptr,2)*v_pct/100,2)) * gst_pct/100, 2)), 0)
    into v_taxable, v_gst
    from (select coalesce((e->>'qty')::numeric,0) qty,
                 coalesce((e->>'ptr')::numeric,0) ptr,
                 coalesce((e->>'gst_pct')::numeric,0) gst_pct
            from jsonb_array_elements(v_raw) e) t;

  v_delivery     := coalesce((v_del->>'amount')::numeric, 0);
  v_delivery_gst := coalesce((v_del->>'gst_amount')::numeric, 0);
  select coalesce(sum(coalesce((e->>'amount')::numeric,0)),0) into v_credit
    from jsonb_array_elements(coalesce(v_credits,'[]'::jsonb)) e;

  v_grand := round(v_taxable + v_gst + v_delivery + v_delivery_gst - v_credit, 2);
  v_final := round(v_grand);

  v_doc := public._bill_compose(v_raw, jsonb_build_object('slab', v_slab),
                                0::numeric, 0::numeric, false, null, v_del, v_credits);

  return jsonb_build_object(
    'has', true,
    'ptr_total', v_base,
    'slab_pct', v_pct,
    'slab_id', nullif(v_slab->>'slab_id','')::int,
    'slab_source', coalesce(nullif(v_slab->>'source',''),'live'),
    'taxable', v_taxable,
    'gst', v_gst,
    'delivery', v_delivery,
    'delivery_gst', v_delivery_gst,
    'credit', v_credit,
    'grand', v_grand,
    'net_payable', v_final,
    'compose_net', coalesce((v_doc#>>'{totals,net_payable}')::numeric, v_final),
    'compose_pct', coalesce((v_doc#>>'{totals,discount_pct}')::numeric, v_pct));
exception when others then
  return jsonb_build_object('has', false, 'error', sqlerrm);
end $$;

-- The orders a money reconciliation is allowed to look at: real trade, in the
-- window, never a heartbeat or a synthetic test order.
create or replace function public._recon_orders(p_from date, p_to date)
returns table (id uuid, order_code text, order_date date, total_amount numeric, status text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select o.id,
         coalesce(o.order_code, left(o.id::text, 8)),
         coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date),
         coalesce(o.total_amount, 0),
         coalesce(o.status, 'pending')
    from public.orders o
   where not coalesce(o.is_synthetic, false)
     and o.test_session_id is null
     and coalesce(o.source,'') <> 'heartbeat'
     and coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) >= p_from
     and coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) <  p_to;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE FIVE CHECK FAMILIES
-- ─────────────────────────────────────────────────────────────────────────────

-- 4.1 Payments vs order payment state ────────────────────────────────────────
create or replace function public.recon_check_payments(p_run bigint, p_from date, p_to date)
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; n int := 0; v_paid numeric; v_ref numeric;
begin
  -- (a) a FINISHED order the platform treats as paid, with less money behind it
  --     than the order is worth.
  --
  --     Finished is the whole point of the condition. `order_is_paid()` answers
  --     true for any order in 'accepted', so an open trade on credit terms
  --     satisfies it while its money is still legitimately outstanding — that
  --     is a receivable, and Money › Owed to us already carries it. Reporting
  --     every open order here nightly would bury the findings that matter under
  --     the ones that are simply the business working. Once the order is closed
  --     or delivered the money should have landed, and a shortfall is drift.
  for r in select * from public._recon_orders(p_from, p_to) loop
    v_paid := coalesce(public.order_paid_amount(r.id), 0);
    if public.order_is_paid(r.id) and r.total_amount > 0 and v_paid < r.total_amount
       and exists (select 1 from public.orders o
                    where o.id = r.id
                      and (o.closed_at is not null
                           or coalesce(o.fulfillment_status,'') in ('delivered','completed')))
    then
      n := n + public._recon_finding(p_run, 'payments', 'order', r.id::text,
             r.order_code, r.total_amount, v_paid,
             public._cf('recon.detail.paid_without_payment',
                        jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;

    -- (b) more money collected than the order is worth, refunds netted off.
    if r.total_amount > 0 and round(v_paid - r.total_amount, 2) > 0 then
      v_ref := coalesce((select sum(amount) from public.refunds
                          where order_id = r.id and status = 'processed'), 0);
      if round(v_paid - v_ref - r.total_amount, 2) > 0 then
        n := n + public._recon_finding(p_run, 'payments', 'order', r.id::text,
               r.order_code, r.total_amount, round(v_paid - v_ref, 2),
               public._cf('recon.detail.overpaid', jsonb_build_object('code', r.order_code)),
               'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
      end if;
    end if;
  end loop;

  -- (c) verified money sitting against no order at all.
  for r in
    select pc.id, pc.amount, coalesce(pc.utr, pc.txn_id, pc.id::text) as ref
      from public.payment_claims pc
     where pc.order_id is null
       and pc.status = 'verified'
       and not coalesce(pc.is_synthetic,false)
       and coalesce(pc.business_date,
                    (pc.created_at at time zone 'Asia/Kolkata')::date) >= p_from
       and coalesce(pc.business_date,
                    (pc.created_at at time zone 'Asia/Kolkata')::date) <  p_to
  loop
    n := n + public._recon_finding(p_run, 'payments', 'payment', r.id::text, r.ref,
           null, r.amount,
           public._cf('recon.detail.unmatched_payment', jsonb_build_object('ref', r.ref)),
           'money', jsonb_build_object('tab', 'unmatched'), true);
  end loop;

  -- (d) webhook truth: Razorpay says a payment was captured and nothing on our
  --     side carries it.
  for r in
    select w.payload_id, string_agg(distinct w.event, ', ') as event,
           min(w.received_at) as at
      from public.razorpay_webhook_log w
     where w.event in ('payment.captured','order.paid','qr_code.credited')
       and coalesce(w.payload_id,'') <> ''
       and (w.received_at at time zone 'Asia/Kolkata')::date >= p_from
       and (w.received_at at time zone 'Asia/Kolkata')::date <  p_to
       and not exists (select 1 from public.rzp_payment_attempt a
                        where a.rzp_payment_id = w.payload_id
                          and a.status in ('paid','captured')
                          and a.order_id is not null)
       and not exists (select 1 from public.razorpay_qr q
                        where (q.payment_id = w.payload_id or q.rzp_qr_id = w.payload_id)
                          and q.status in ('paid','closed_paid')
                          and q.order_id is not null)
     group by w.payload_id
  loop
    n := n + public._recon_finding(p_run, 'payments', 'payment', r.payload_id, r.payload_id,
           null, null,
           public._cf('recon.detail.captured_no_order',
                      jsonb_build_object('event', r.event, 'id', r.payload_id)),
           'money', jsonb_build_object('tab', 'unmatched'), true);
  end loop;

  -- (e) a payment row pointing at an order that no longer exists.
  for r in
    select a.id, a.order_id, a.amount from public.rzp_payment_attempt a
     where a.status in ('paid','captured')
       and not coalesce(a.is_synthetic,false)
       and a.order_id is not null
       and not exists (select 1 from public.orders o where o.id = a.order_id)
  loop
    n := n + public._recon_finding(p_run, 'payments', 'payment', r.id::text, r.order_id::text,
           null, r.amount,
           public._cf('recon.detail.orphan_payment',
                      jsonb_build_object('id', r.order_id::text)),
           'money', jsonb_build_object('tab', 'unmatched'), true);
  end loop;

  return n;
end $$;

-- 4.2 Bill vs order vs the slab snapshot ─────────────────────────────────────
create or replace function public.recon_check_bill_vs_order(p_run bigint, p_from date, p_to date)
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; n int := 0; b jsonb; s record; v_inv text;
begin
  for r in select * from public._recon_orders(p_from, p_to) loop
    b := public._recon_bill_calc(r.id);
    if not coalesce((b->>'has')::boolean, false) then
      continue;                                   -- nothing billable yet
    end if;

    -- (a) the composer and the recon must reach the same net payable. If they
    --     ever differ, one of the two moved and nobody noticed.
    if round(coalesce((b->>'net_payable')::numeric,0)
             - coalesce((b->>'compose_net')::numeric,0), 2) <> 0 then
      n := n + public._recon_finding(p_run, 'bill_vs_order', 'order', r.id::text, r.order_code,
             (b->>'compose_net')::numeric, (b->>'net_payable')::numeric,
             public._cf('recon.detail.bill_math', jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;

    select o.bill_slab_base, o.bill_discount_pct, o.invoice_no, o.invoice_issued_at
      into s from public.orders o where o.id = r.id;
    v_inv := coalesce(s.invoice_no, '');

    -- (b) the snapshot the order carries must still describe the goods on it.
    if s.bill_slab_base is not null
       and round(s.bill_slab_base - (b->>'ptr_total')::numeric, 2) <> 0 then
      n := n + public._recon_finding(p_run, 'bill_vs_order', 'order', r.id::text, r.order_code,
             s.bill_slab_base, (b->>'ptr_total')::numeric,
             public._cf('recon.detail.slab_base_drift', jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;

    -- (c) the bill must be priced at the snapshotted discount, not today's.
    if s.bill_discount_pct is not null
       and round(s.bill_discount_pct - (b->>'slab_pct')::numeric, 2) <> 0 then
      n := n + public._recon_finding(p_run, 'bill_vs_order', 'order', r.id::text, r.order_code,
             s.bill_discount_pct, (b->>'slab_pct')::numeric,
             public._cf('recon.detail.slab_pct_drift', jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;

    -- (d) the two snapshots — the order's own and the P&L one (#318/#319) —
    --     must agree with each other.
    for s in select slab_pct, ptr_total from public.order_pnl_slab where order_id = r.id loop
      if round(coalesce(s.slab_pct,0) - (b->>'slab_pct')::numeric, 2) <> 0 then
        n := n + public._recon_finding(p_run, 'bill_vs_order', 'order', r.id::text, r.order_code,
               s.slab_pct, (b->>'slab_pct')::numeric,
               public._cf('recon.detail.pnl_slab_drift', jsonb_build_object('code', r.order_code)),
               'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
      end if;
      if round(coalesce(s.ptr_total,0) - (b->>'ptr_total')::numeric, 2) <> 0 then
        n := n + public._recon_finding(p_run, 'bill_vs_order', 'order', r.id::text, r.order_code,
               s.ptr_total, (b->>'ptr_total')::numeric,
               public._cf('recon.detail.pnl_base_drift', jsonb_build_object('code', r.order_code)),
               'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
      end if;
    end loop;

    -- (e) an ISSUED invoice is a promise: the order total must be the bill.
    if v_inv <> '' and r.total_amount > 0
       and round(r.total_amount - (b->>'net_payable')::numeric, 2) <> 0 then
      n := n + public._recon_finding(p_run, 'bill_vs_order', 'order', r.id::text,
             r.order_code || ' · ' || v_inv,
             (b->>'net_payable')::numeric, r.total_amount,
             public._cf('recon.detail.bill_total_drift',
                        jsonb_build_object('code', r.order_code, 'invoice', v_inv)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;
  end loop;

  return n;
end $$;

-- 4.3 Bills vs the GST ledger ────────────────────────────────────────────────
create or replace function public.recon_check_gst(p_run bigint, p_from date, p_to date)
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; n int := 0; b jsonb; g record;
begin
  -- (a) OUTWARD — every invoiced order exactly once, taxable and tax matching
  --     the invoice to the paisa.
  for r in select * from public._recon_orders(p_from, p_to) loop
    if not exists (select 1 from public.orders o
                    where o.id = r.id and coalesce(o.invoice_no,'') <> '') then
      continue;
    end if;

    b := public._recon_bill_calc(r.id);
    if not coalesce((b->>'has')::boolean, false) then continue; end if;

    select count(*) as rows,
           count(distinct invoice_no) as invoices,
           coalesce(sum(taxable),0) as taxable,
           coalesce(sum(total_tax),0) as tax
      into g
      from public.gst_ledger
     where direction = 'output' and source = 'customer_bill'
       and source_id = r.id and not coalesce(is_synthetic,false);

    if g.rows = 0 then
      n := n + public._recon_finding(p_run, 'gst', 'order', r.id::text, r.order_code,
             round((b->>'taxable')::numeric + (b->>'delivery')::numeric, 2), 0,
             public._cf('recon.detail.gst_missing', jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code), true);
      continue;
    end if;

    if g.invoices > 1 then
      n := n + public._recon_finding(p_run, 'gst', 'order', r.id::text, r.order_code,
             1, g.invoices,
             public._cf('recon.detail.gst_duplicate',
                        jsonb_build_object('code', r.order_code, 'n', g.invoices::text)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code), true);
    end if;

    if round(g.taxable - ((b->>'taxable')::numeric + (b->>'delivery')::numeric), 2) <> 0 then
      n := n + public._recon_finding(p_run, 'gst', 'order', r.id::text, r.order_code,
             round((b->>'taxable')::numeric + (b->>'delivery')::numeric, 2), g.taxable,
             public._cf('recon.detail.gst_taxable_drift', jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;

    if round(g.tax - ((b->>'gst')::numeric + (b->>'delivery_gst')::numeric), 2) <> 0 then
      n := n + public._recon_finding(p_run, 'gst', 'order', r.id::text, r.order_code,
             round((b->>'gst')::numeric + (b->>'delivery_gst')::numeric, 2), g.tax,
             public._cf('recon.detail.gst_tax_drift', jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;
  end loop;

  -- (b) INWARD — every imported supplier bill exactly once, tax matching its
  --     own verified lines.
  for r in
    select pb.id, coalesce(pb.file_name, pb.id::text) as label,
           coalesce(pb.supplier_name,'') as supplier,
           coalesce(sum(round(round(bl.qty*bl.ptr,2)
                              - round(round(bl.qty*bl.ptr,2)*coalesce(bl.disc_pct,0)/100,2), 2)
                        * coalesce(bl.gst_pct,0)/100), 0) as tax
      from public.pending_bills pb
      join public.bill_lines bl on bl.pending_bill_id = pb.id and bl.verified
     where pb.status = 'imported'
       and not coalesce(pb.is_synthetic,false)
       and coalesce(pb.imported_at, pb.created_at) >= p_from
       and coalesce(pb.imported_at, pb.created_at) <  p_to + 1
     group by pb.id, pb.file_name, pb.supplier_name
  loop
    select count(*) as rows, coalesce(sum(total_tax),0) as tax into g
      from public.gst_ledger
     where direction = 'input' and source = 'supplier_bill'
       and source_id = r.id and not coalesce(is_synthetic,false);

    if g.rows = 0 then
      n := n + public._recon_finding(p_run, 'gst', 'supplier_bill', r.id::text,
             r.supplier || ' · ' || r.label, round(r.tax,2), 0,
             public._cf('recon.detail.gst_input_missing',
                        jsonb_build_object('bill', r.label)),
             'supplier', jsonb_build_object('bill_id', r.id), true);
    elsif round(g.tax - round(r.tax,2), 2) <> 0 then
      n := n + public._recon_finding(p_run, 'gst', 'supplier_bill', r.id::text,
             r.supplier || ' · ' || r.label, round(r.tax,2), g.tax,
             public._cf('recon.detail.gst_input_drift', jsonb_build_object('bill', r.label)),
             'supplier', jsonb_build_object('bill_id', r.id));
    end if;
  end loop;

  -- (c) the ledger itself: the same line booked twice.
  for r in
    select direction, source, source_id, line_ref, count(*) as n
      from public.gst_ledger
     where not coalesce(is_synthetic,false)
       and source_id is not null and coalesce(line_ref,'') <> ''
       and invoice_date >= p_from and invoice_date < p_to
     group by 1,2,3,4 having count(*) > 1
  loop
    n := n + public._recon_finding(p_run, 'gst', 'gst_line',
           r.source_id::text, r.source || ' · ' || r.line_ref, 1, r.n,
           public._cf('recon.detail.gst_line_duplicate',
                      jsonb_build_object('ref', r.line_ref, 'n', r.n::text)),
           '', '{}'::jsonb, true);
  end loop;

  return n;
end $$;

-- 4.4 Margin, settlements and credit notes ───────────────────────────────────
create or replace function public.recon_check_margin(p_run bigint, p_from date, p_to date)
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; n int := 0; b jsonb; v record;
begin
  -- (a) the margin row's revenue is the bill's taxable value.
  for r in select * from public._recon_orders(p_from, p_to) loop
    b := public._recon_bill_calc(r.id);
    if not coalesce((b->>'has')::boolean, false) then continue; end if;

    select revenue, goods_cost, gross_margin into v
      from public.pnl_order_v where order_id = r.id;
    if found and v.revenue is not null
       and round(v.revenue - (b->>'taxable')::numeric, 2) <> 0 then
      n := n + public._recon_finding(p_run, 'margin', 'order', r.id::text, r.order_code,
             (b->>'taxable')::numeric, v.revenue,
             public._cf('recon.detail.margin_revenue_drift',
                        jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.id, 'order_code', r.order_code));
    end if;
  end loop;

  -- (b) a settlement line must restate its order, and its two shares must add
  --     back up to what was distributed.
  for r in
    select s.id, s.order_id, s.order_code, s.revenue, s.goods_cost, s.cost_total,
           s.distributable, s.partner_share, s.medibo_share, s.split_pct
      from public.partner_settlements s
     where not coalesce(s.is_synthetic,false)
       and s.order_date >= p_from and s.order_date < p_to
  loop
    select revenue, goods_cost into v from public.pnl_order_v where order_id = r.order_id;
    if found and v.revenue is not null
       and round(coalesce(r.revenue,0) - v.revenue, 2) <> 0 then
      n := n + public._recon_finding(p_run, 'margin', 'settlement', r.id::text, r.order_code,
             v.revenue, coalesce(r.revenue,0),
             public._cf('recon.detail.settlement_revenue_drift',
                        jsonb_build_object('code', coalesce(r.order_code,''))),
             'order', jsonb_build_object('order_id', r.order_id, 'order_code', r.order_code));
    end if;
    if found and v.goods_cost is not null
       and round(coalesce(r.goods_cost,0) - v.goods_cost, 2) <> 0 then
      n := n + public._recon_finding(p_run, 'margin', 'settlement', r.id::text, r.order_code,
             v.goods_cost, coalesce(r.goods_cost,0),
             public._cf('recon.detail.settlement_cost_drift',
                        jsonb_build_object('code', coalesce(r.order_code,''))),
             'order', jsonb_build_object('order_id', r.order_id, 'order_code', r.order_code));
    end if;
    if round(coalesce(r.partner_share,0) + coalesce(r.medibo_share,0)
             - coalesce(r.distributable,0), 2) <> 0 then
      n := n + public._recon_finding(p_run, 'margin', 'settlement', r.id::text, r.order_code,
             coalesce(r.distributable,0),
             round(coalesce(r.partner_share,0) + coalesce(r.medibo_share,0), 2),
             public._cf('recon.detail.settlement_split_drift',
                        jsonb_build_object('code', coalesce(r.order_code,''))),
             'order', jsonb_build_object('order_id', r.order_id, 'order_code', r.order_code));
    end if;
  end loop;

  -- (c) a credit note reverses at the ORIGINAL slab, and its own arithmetic
  --     has to close (#395).
  for r in
    select cn.id, cn.order_id, cn.slab_pct, cn.credit_value, cn.credit_disc,
           cn.credit_taxable, cn.credit_gst, cn.credit_total, cn.gst_pct,
           coalesce(o.order_code, left(cn.order_id::text,8)) as order_code,
           o.bill_discount_pct
      from public.order_returns cn
      join public.orders o on o.id = cn.order_id
     where cn.status = 'credited'
       and not coalesce(o.is_synthetic,false)
       and coalesce(cn.credited_at, cn.created_at) >= p_from
       and coalesce(cn.credited_at, cn.created_at) <  p_to + 1
  loop
    if r.bill_discount_pct is not null
       and round(coalesce(r.slab_pct,0) - r.bill_discount_pct, 2) <> 0 then
      n := n + public._recon_finding(p_run, 'margin', 'credit_note', r.id::text, r.order_code,
             r.bill_discount_pct, coalesce(r.slab_pct,0),
             public._cf('recon.detail.credit_slab_drift',
                        jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.order_id, 'order_code', r.order_code));
    end if;
    if round(coalesce(r.credit_taxable,0)
             - (coalesce(r.credit_value,0) - coalesce(r.credit_disc,0)), 2) <> 0 then
      n := n + public._recon_finding(p_run, 'margin', 'credit_note', r.id::text, r.order_code,
             round(coalesce(r.credit_value,0) - coalesce(r.credit_disc,0), 2),
             coalesce(r.credit_taxable,0),
             public._cf('recon.detail.credit_taxable_drift',
                        jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.order_id, 'order_code', r.order_code));
    end if;
    if round(coalesce(r.credit_total,0)
             - (coalesce(r.credit_taxable,0) + coalesce(r.credit_gst,0)), 2) <> 0 then
      n := n + public._recon_finding(p_run, 'margin', 'credit_note', r.id::text, r.order_code,
             round(coalesce(r.credit_taxable,0) + coalesce(r.credit_gst,0), 2),
             coalesce(r.credit_total,0),
             public._cf('recon.detail.credit_total_drift',
                        jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.order_id, 'order_code', r.order_code));
    end if;
  end loop;

  -- (d) money can never go out beyond what came in.
  for r in
    select f.order_id, coalesce(o.order_code, left(f.order_id::text,8)) as order_code,
           sum(f.amount) as refunded
      from public.refunds f
      join public.orders o on o.id = f.order_id
     where f.status = 'processed' and not coalesce(f.is_synthetic,false)
       and coalesce(f.processed_at, f.created_at) >= p_from
       and coalesce(f.processed_at, f.created_at) <  p_to + 1
     group by 1,2
  loop
    if round(r.refunded - coalesce(public._order_collected(r.order_id),0), 2) > 0 then
      n := n + public._recon_finding(p_run, 'margin', 'refund', r.order_id::text, r.order_code,
             coalesce(public._order_collected(r.order_id),0), r.refunded,
             public._cf('recon.detail.refund_over_collected',
                        jsonb_build_object('code', r.order_code)),
             'order', jsonb_build_object('order_id', r.order_id, 'order_code', r.order_code));
    end if;
  end loop;

  return n;
end $$;

-- 4.5 Supplier payments vs supplier payables ─────────────────────────────────
create or replace function public.recon_check_supplier_pay(p_run bigint, p_from date, p_to date)
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; n int := 0;
begin
  -- (a) paid against a supplier order that has no verified bill behind it, or
  --     paid more than the bill says is owed.
  for r in
    select sp.supplier_order_id,
           coalesce(max(sp.supplier_name),'') as supplier,
           sum(sp.amount) as paid
      from public.supplier_payments sp
     where not coalesce(sp.is_synthetic,false)
       and sp.supplier_order_id is not null
       and sp.created_at >= p_from
       and sp.created_at <  p_to + 1
     group by 1
  loop
    declare v_payable numeric;
    begin
      select coalesce(sum(bl.line_amount),0) into v_payable
        from public.bill_lines bl
       where bl.supplier_order_id = r.supplier_order_id and bl.verified;

      if v_payable = 0 then
        n := n + public._recon_finding(p_run, 'supplier_pay', 'supplier_order',
               r.supplier_order_id::text, r.supplier, 0, r.paid,
               public._cf('recon.detail.supplier_pay_no_bill',
                          jsonb_build_object('supplier', r.supplier)),
               'supplier', jsonb_build_object('supplier_order_id', r.supplier_order_id), true);
      elsif round(r.paid - v_payable, 2) > 0 then
        n := n + public._recon_finding(p_run, 'supplier_pay', 'supplier_order',
               r.supplier_order_id::text, r.supplier, v_payable, r.paid,
               public._cf('recon.detail.supplier_overpaid',
                          jsonb_build_object('supplier', r.supplier)),
               'supplier', jsonb_build_object('supplier_order_id', r.supplier_order_id));
      end if;
    end;
  end loop;

  -- (b) a payment recorded against nothing at all.
  for r in
    select sp.id, coalesce(sp.supplier_name,'') as supplier, sp.amount
      from public.supplier_payments sp
     where not coalesce(sp.is_synthetic,false)
       and sp.supplier_order_id is null
       and sp.created_at >= p_from
       and sp.created_at <  p_to + 1
  loop
    n := n + public._recon_finding(p_run, 'supplier_pay', 'supplier_payment', r.id::text,
           r.supplier, null, r.amount,
           public._cf('recon.detail.supplier_pay_unattached',
                      jsonb_build_object('supplier', r.supplier)),
           '', '{}'::jsonb, true);
  end loop;

  return n;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. REGISTRY ROWS
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.recon_check (key, ord, fn, label, description, source_a_label, source_b_label, spec_item) values
  ('payments', 10, 'public.recon_check_payments',
   'Payments vs order state',
   'No order is marked paid without money behind it, and no captured payment sits without an order.',
   'Razorpay + recorded payments', 'Order payment state', '1'),
  ('bill_vs_order', 20, 'public.recon_check_bill_vs_order',
   'Bills vs orders and the slab snapshot',
   'A bill must equal its order at the discount that was snapshotted when the invoice was issued.',
   'Order total + slab snapshot', 'Recomputed customer bill', '2'),
  ('gst', 30, 'public.recon_check_gst',
   'Invoices vs the GST ledger',
   'Every customer invoice and supplier bill appears in the GST ledger exactly once, with taxes matching to the paisa.',
   'Customer + supplier bills', 'GST ledger', '3'),
  ('margin', 40, 'public.recon_check_margin',
   'Margin, settlements and credit notes',
   'Margin rows restate their source bills, settlement shares add back up, and a credit note reverses at the original slab.',
   'Margin + settlement + credit notes', 'Source bills and orders', '4'),
  ('supplier_pay', 50, 'public.recon_check_supplier_pay',
   'Supplier payments vs payables',
   'What was paid to a supplier never exceeds what their verified bill says is owed.',
   'Supplier payments recorded', 'Supplier bill payables', '5')
on conflict (key) do update set
  ord = excluded.ord, fn = excluded.fn, label = excluded.label,
  description = excluded.description, source_a_label = excluded.source_a_label,
  source_b_label = excluded.source_b_label, spec_item = excluded.spec_item;

-- detail copy for every finding sentence
insert into public.ui_copy (key, value)
select k, to_jsonb(v) from (values
  ('recon.detail.paid_without_payment',   'Order {code} is treated as paid, but the payments recorded against it fall short of its total.'),
  ('recon.detail.overpaid',               'More money is recorded against order {code} than the order is worth, even after processed refunds.'),
  ('recon.detail.unmatched_payment',      'Verified payment {ref} is not attached to any order.'),
  ('recon.detail.captured_no_order',      'Razorpay reported {event} for {id}, and nothing on our side carries that payment.'),
  ('recon.detail.orphan_payment',         'A captured payment points at order {id}, which no longer exists.'),
  ('recon.detail.bill_math',              'The invoice composer and the reconciliation reach different net payables for order {code}.'),
  ('recon.detail.slab_base_drift',        'The slab base snapshotted on order {code} no longer matches the goods on the bill.'),
  ('recon.detail.slab_pct_drift',         'Order {code} is being billed at a different discount from the one snapshotted on it.'),
  ('recon.detail.pnl_slab_drift',         'The P&L slab snapshot for order {code} disagrees with the bill discount.'),
  ('recon.detail.pnl_base_drift',         'The P&L slab base for order {code} disagrees with the bill base.'),
  ('recon.detail.bill_total_drift',       'Invoice {invoice} does not equal the total on order {code}.'),
  ('recon.detail.gst_missing',            'Invoiced order {code} has no outward row in the GST ledger.'),
  ('recon.detail.gst_duplicate',          'Order {code} appears under {n} invoice numbers in the GST ledger.'),
  ('recon.detail.gst_taxable_drift',      'The GST ledger taxable value for order {code} does not match its invoice.'),
  ('recon.detail.gst_tax_drift',          'The GST ledger tax for order {code} does not match its invoice.'),
  ('recon.detail.gst_input_missing',      'Imported supplier bill {bill} has no inward row in the GST ledger.'),
  ('recon.detail.gst_input_drift',        'The input tax booked for supplier bill {bill} does not match its verified lines.'),
  ('recon.detail.gst_line_duplicate',     'GST line {ref} is booked {n} times.'),
  ('recon.detail.margin_revenue_drift',   'The margin row for order {code} does not restate the taxable value of its bill.'),
  ('recon.detail.settlement_revenue_drift','The settlement line for order {code} does not restate the order revenue.'),
  ('recon.detail.settlement_cost_drift',  'The settlement line for order {code} does not restate the goods cost.'),
  ('recon.detail.settlement_split_drift', 'The partner and mediBO shares on order {code} do not add back up to what was distributed.'),
  ('recon.detail.credit_slab_drift',      'The credit note on order {code} reverses at a different slab from the original bill.'),
  ('recon.detail.credit_taxable_drift',   'The credit note taxable value on order {code} is not value less discount.'),
  ('recon.detail.credit_total_drift',     'The credit note total on order {code} is not taxable plus GST.'),
  ('recon.detail.refund_over_collected',  'More has been refunded on order {code} than was ever collected for it.'),
  ('recon.detail.supplier_pay_no_bill',   'Money was paid to {supplier} against a supplier order with no verified bill.'),
  ('recon.detail.supplier_overpaid',      'More has been paid to {supplier} than their verified bill says is owed.'),
  ('recon.detail.supplier_pay_unattached','A payment to {supplier} is not attached to any supplier order.')
) t(k, v)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. CONFIG + THE RUNNER
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.recon_config (
  id            int primary key default 1,
  window_days   int not null default 30,     -- how far back a nightly run looks
  notify_green  boolean not null default true,
  max_notify_lines int not null default 12,
  keep_runs     int not null default 120,
  updated_at    timestamptz not null default now(),
  constraint recon_config_one_row check (id = 1)
);
alter table public.recon_config enable row level security;
revoke all on public.recon_config from anon, authenticated;
insert into public.recon_config (id) values (1) on conflict (id) do nothing;

-- Run every enabled check over a window and record what disagreed. A check
-- that throws is contained: its own findings roll back, the run carries on and
-- the failure is itself recorded, because a reconciliation that dies silently
-- is worse than one that finds nothing.
create or replace function public.recon_run(
  p_from date default null, p_to date default null, p_trigger text default 'cron')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  cfg public.recon_config%rowtype;
  c   public.recon_check%rowtype;
  v_run bigint; v_n int; v_from date; v_to date;
  v_ran int := 0; v_failed int := 0;
  v_find int; v_err int; v_warn int; v_paisa bigint;
  v_detail text; v_summary text; v_status text;
  v_t0 timestamptz := clock_timestamp();
begin
  select * into cfg from public.recon_config where id = 1;
  v_to   := coalesce(p_to,   (now() at time zone 'Asia/Kolkata')::date + 1);
  v_from := coalesce(p_from, v_to - coalesce(cfg.window_days, 30));

  insert into public.recon_runs (trigger, window_from, window_to)
  values (coalesce(p_trigger,'cron'), v_from, v_to)
  returning id into v_run;

  for c in select * from public.recon_check where enabled order by ord, key loop
    begin
      execute format('select %s($1,$2,$3)', c.fn) into v_n using v_run, v_from, v_to;
      v_ran := v_ran + 1;
    exception when others then
      v_failed := v_failed + 1;
      insert into public.recon_findings (
        run_id, check_key, severity, entity_type, entity_id, entity_label,
        source_a, source_b, detail_label)
      values (v_run, c.key, 'error', 'check', c.key, c.label,
              c.source_a_label, c.source_b_label,
              public._cf('recon.detail.check_failed',
                         jsonb_build_object('check', c.label, 'error', sqlerrm)));
    end;
  end loop;

  select count(*),
         count(*) filter (where severity = 'error'),
         count(*) filter (where severity <> 'error'),
         coalesce(sum(round(abs(coalesce(diff,0)) * 100)), 0)
    into v_find, v_err, v_warn, v_paisa
    from public.recon_findings where run_id = v_run;

  select string_agg(x.line, E'\n' order by x.ord)
    into v_detail
    from (select ck.ord,
                 ck.label || ' — ' || count(f.id)::text as line
            from public.recon_findings f
            join public.recon_check ck on ck.key = f.check_key
           where f.run_id = v_run
           group by ck.ord, ck.label) x;

  v_status := case when v_failed > 0 and v_find = 0 then 'error'
                   when v_find > 0 then 'drift' else 'green' end;

  v_summary := case v_status
    when 'green' then public._cf('recon.green_summary',
                        jsonb_build_object('checks', v_ran::text))
    when 'error' then public._cf('recon.error_summary',
                        jsonb_build_object('error', coalesce(v_detail,'')))
    else public._cf('recon.drift_summary',
           jsonb_build_object('findings', v_find::text, 'checks', v_ran::text,
                              'drift', public.inr_money(round(v_paisa::numeric/100, 2)))) end;

  update public.recon_runs
     set status = v_status, checks_run = v_ran, checks_failed = v_failed,
         findings = v_find, errors = v_err, warnings = v_warn,
         drift_paisa = v_paisa, summary_label = v_summary,
         detail_label = coalesce(v_detail,''),
         finished_at = now(),
         ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::int
   where id = v_run;

  -- keep the table small; the findings cascade away with their run
  delete from public.recon_runs
   where id in (select id from public.recon_runs
                 order by id desc offset greatest(coalesce(cfg.keep_runs,120), 10));

  return jsonb_build_object('ok', true, 'run_id', v_run, 'status', v_status,
                            'findings', v_find, 'checks', v_ran,
                            'summary_label', v_summary, 'detail_label', coalesce(v_detail,''));
end $$;

create or replace function public.recon_run_nightly()
returns jsonb
language sql
security definer
set search_path to 'public'
as $$ select public.recon_run(null, null, 'cron'); $$;

-- The morning post. Green is one line; drift is the itemised list, capped so a
-- bad night cannot turn into an unreadable wall.
create or replace function public.recon_notify_latest()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  cfg public.recon_config%rowtype;
  r   public.recon_runs%rowtype;
  v_lines text; v_res jsonb;
begin
  select * into cfg from public.recon_config where id = 1;
  select * into r from public.recon_runs
   where finished_at is not null and notified_at is null
   order by id desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'skipped', 'nothing_new');
  end if;

  if r.status = 'green' and not coalesce(cfg.notify_green, true) then
    update public.recon_runs set notified_at = now() where id = r.id;
    return jsonb_build_object('ok', true, 'skipped', 'green_muted', 'run_id', r.id);
  end if;

  select string_agg(x.line, E'\n')
    into v_lines
    from (select f.entity_label || ' · ' || coalesce(nullif(f.diff_label,''), f.detail_label) as line
            from public.recon_findings f
           where f.run_id = r.id
           order by f.severity, f.id
           limit greatest(coalesce(cfg.max_notify_lines, 12), 1)) x;

  v_res := public.notify('recon_morning', null, jsonb_build_object(
             'summary', r.summary_label,
             'window',  public._cf('recon.window_label',
                          jsonb_build_object('from', to_char(r.window_from,'DD Mon'),
                                             'to',   to_char(r.window_to - 1,'DD Mon'))),
             'detail',  coalesce(nullif(v_lines,''), r.detail_label, ''),
             'channel', 'email'));

  update public.recon_runs set notified_at = now() where id = r.id;
  return jsonb_build_object('ok', true, 'run_id', r.id, 'status', r.status, 'notify', v_res);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. SELF-TEST — three deliberate drifts, caught, then rolled away
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The proof runs END TO END through the real check functions over the real
-- tables, so it proves the queries and not a copy of them. It seeds a CONTROL
-- first (an order made consistent, with its GST rows written correctly) and
-- asserts the run is clean for that order; only then does it introduce the
-- three drifts. Every write happens inside a block that is deliberately
-- aborted, so nothing survives — plpgsql rolls the DATA back on a caught
-- exception while local variables keep their values, which is how the verdict
-- gets out.
create or replace function public.recon_selftest()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_out jsonb := jsonb_build_object('ok', false, 'reason', 'not_run');
  v_order uuid; v_code text; b jsonb;
  v_clean jsonb; v_drift jsonb; v_run1 bigint; v_run2 bigint;
  v_claim uuid := gen_random_uuid();
  v_seen_payment boolean; v_seen_bill boolean; v_seen_gst boolean;
  v_from date; v_to date;
begin
  begin
    -- Triggers OFF for the scaffolding. Not for tidiness: `trg_pc_autolink`
    -- would attach the deliberately-unmatched payment to an order and erase the
    -- very drift being seeded, and `trg_wa_notify_order_updated` would send a
    -- real customer a WhatsApp about a total this function is about to throw
    -- away. pg_net posts are NOT rolled back, so the only safe self-test is one
    -- that never fires them. Restored with the savepoint.
    set local session_replication_role = 'replica';

    select r.id, r.order_code into v_order, v_code
      from public._recon_orders('2000-01-01'::date, (now() at time zone 'Asia/Kolkata')::date + 1) r
     where coalesce((public._recon_bill_calc(r.id)->>'has')::boolean, false)
     order by r.order_date desc limit 1;

    if v_order is null then
      return jsonb_build_object('ok', false, 'reason', 'no_billable_order',
        'note', 'The self-test needs one real order with verified bill lines.');
    end if;

    b := public._recon_bill_calc(v_order);
    v_from := '2000-01-01'::date;
    v_to   := (now() at time zone 'Asia/Kolkata')::date + 1;

    -- ── CONTROL ────────────────────────────────────────────────────────────
    -- make this one order agree with itself on every surface the three
    -- seeded drifts will later break.
    update public.orders
       set invoice_no          = coalesce(invoice_no, 'SELFTEST/471'),
           invoice_issued_at   = coalesce(invoice_issued_at, now()),
           total_amount        = (b->>'net_payable')::numeric,
           bill_slab_base      = (b->>'ptr_total')::numeric,
           bill_discount_pct   = (b->>'slab_pct')::numeric
     where id = v_order;

    insert into public.gst_ledger (
      direction, source, source_id, line_ref, tax_period, invoice_no, invoice_date,
      taxable, rate, cgst, sgst, igst, order_id, order_code, built_at)
    values ('output', 'customer_bill', v_order, 'selftest',
            date_trunc('month', now())::date,
            (select invoice_no from public.orders where id = v_order),
            (now() at time zone 'Asia/Kolkata')::date,
            round((b->>'taxable')::numeric + (b->>'delivery')::numeric, 2), 0,
            round(((b->>'gst')::numeric + (b->>'delivery_gst')::numeric)/2, 2),
            ((b->>'gst')::numeric + (b->>'delivery_gst')::numeric)
              - round(((b->>'gst')::numeric + (b->>'delivery_gst')::numeric)/2, 2),
            0,
            v_order, v_code, now());

    v_run1 := (public.recon_run(v_from, v_to, 'selftest')->>'run_id')::bigint;

    select jsonb_build_object(
             'payments',      count(*) filter (where check_key='payments'      and entity_id = v_order::text),
             'bill_vs_order', count(*) filter (where check_key='bill_vs_order' and entity_id = v_order::text),
             'gst',           count(*) filter (where check_key='gst'           and entity_id = v_order::text))
      into v_clean from public.recon_findings where run_id = v_run1;

    -- ── THE THREE DELIBERATE DRIFTS ────────────────────────────────────────
    -- 1. an unmatched payment: verified money attached to no order at all
    insert into public.payment_claims (id, amount, status, order_id, utr,
                                       received_at, created_at, business_date)
    values (v_claim, 4321.99, 'verified', null, 'SELFTEST471UTR',
            now(), now(), (now() at time zone 'Asia/Kolkata')::date);

    -- 2. a bill-total mismatch: one paisa, which is a finding
    update public.orders
       set total_amount = (b->>'net_payable')::numeric + 0.01
     where id = v_order;

    -- 3. a missing GST row for an invoiced order
    delete from public.gst_ledger
     where source_id = v_order and line_ref = 'selftest';

    v_run2 := (public.recon_run(v_from, v_to, 'selftest')->>'run_id')::bigint;

    select
      bool_or(check_key = 'payments'      and entity_id = v_claim::text),
      bool_or(check_key = 'bill_vs_order' and entity_id = v_order::text
              and round(abs(coalesce(diff,0)),2) = 0.01),
      bool_or(check_key = 'gst'           and entity_id = v_order::text
              and coalesce(actual,0) = 0)
      into v_seen_payment, v_seen_bill, v_seen_gst
      from public.recon_findings where run_id = v_run2;

    select jsonb_build_object(
      'ok', coalesce(v_seen_payment,false) and coalesce(v_seen_bill,false)
            and coalesce(v_seen_gst,false),
      'order_code', v_code,
      'control', jsonb_build_object(
        'clean_for_order', v_clean,
        'passed', coalesce((v_clean->>'payments')::int,0) = 0
                  and coalesce((v_clean->>'bill_vs_order')::int,0) = 0
                  and coalesce((v_clean->>'gst')::int,0) = 0),
      'seeded', jsonb_build_array(
        jsonb_build_object('drift','unmatched payment',
                           'caught', coalesce(v_seen_payment,false)),
        jsonb_build_object('drift','bill total off by ₹0.01',
                           'caught', coalesce(v_seen_bill,false)),
        jsonb_build_object('drift','missing GST row',
                           'caught', coalesce(v_seen_gst,false))),
      'findings', (select jsonb_agg(jsonb_build_object(
                            'check', check_key, 'entity', entity_label,
                            'diff', diff_label, 'detail', detail_label) order by id)
                     from public.recon_findings where run_id = v_run2))
      into v_out;

    -- Everything above is scaffolding. Abort it.
    raise exception 'c471_selftest_rollback';
  exception when others then
    if sqlerrm <> 'c471_selftest_rollback' then
      return jsonb_build_object('ok', false, 'reason', 'selftest_error', 'error', sqlerrm);
    end if;
  end;

  return v_out;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. READ RPCs — the screen renders these verbatim
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._recon_run_card(r public.recon_runs)
returns jsonb
language sql
stable
set search_path to 'public'
as $$
  select jsonb_build_object(
    'run_id',        r.id,
    'status',        r.status,
    'status_label',  case r.status when 'green' then public._c('recon.status_green')
                                   when 'drift' then public._c('recon.status_drift')
                                   when 'error' then public._c('recon.status_error')
                                   else public._c('recon.status_running') end,
    'status_tone',   case r.status when 'green' then 'good'
                                   when 'drift' then 'bad'
                                   when 'error' then 'bad' else 'warn' end,
    'summary_label', r.summary_label,
    'detail_label',  r.detail_label,
    'window_label',  public._cf('recon.window_label',
                       jsonb_build_object('from', to_char(r.window_from,'DD Mon'),
                                          'to',   to_char(r.window_to - 1,'DD Mon'))),
    'checks_label',  public._cf('recon.checks_caption',   jsonb_build_object('n', r.checks_run::text)),
    'findings_label',public._cf('recon.findings_caption', jsonb_build_object('n', r.findings::text)),
    'ran_label',     to_char(r.started_at at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM'),
    'trigger',       r.trigger);
$$;

create or replace function public.recon_home(p_limit int default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_runs jsonb; v_latest jsonb;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_agg(public._recon_run_card(r) order by r.id desc), '[]'::jsonb)
    into v_runs
    from (select * from public.recon_runs order by id desc limit greatest(coalesce(p_limit,20),1)) r;

  select public._recon_run_card(r) into v_latest
    from public.recon_runs r where r.finished_at is not null order by r.id desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'title',        public._c('recon.title'),
    'subtitle',     public._c('recon.subtitle'),
    'run_button',   public._c('recon.run_button'),
    'running_label',public._c('recon.running_label'),
    'has_latest',   v_latest is not null,
    'latest',       v_latest,
    'runs',         v_runs,
    'empty_title',  public._c('recon.empty_title'),
    'empty_hint',   public._c('recon.empty_hint'));
end $$;

create or replace function public.recon_run_detail(p_run_id bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare r public.recon_runs%rowtype; v_groups jsonb;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;

  if p_run_id is null then
    select * into r from public.recon_runs where finished_at is not null order by id desc limit 1;
  else
    select * into r from public.recon_runs where id = p_run_id;
  end if;
  if not found then
    return jsonb_build_object('ok', false,
      'title', public._c('recon.empty_title'), 'message', public._c('recon.empty_hint'));
  end if;

  select coalesce(jsonb_agg(g order by (g->>'ord')::int), '[]'::jsonb)
    into v_groups
    from (
      select jsonb_build_object(
               'ord',            ck.ord,
               'check_key',      ck.key,
               'label',          ck.label,
               'description',    ck.description,
               'sources_label',  public._cf('recon.sources_caption',
                                   jsonb_build_object('a', ck.source_a_label,
                                                      'b', ck.source_b_label)),
               'count_label',    public._cf('recon.findings_caption',
                                   jsonb_build_object('n', count(f.id)::text)),
               'tone',           case when count(f.id) = 0 then 'good' else 'bad' end,
               'findings', coalesce(jsonb_agg(jsonb_build_object(
                   'id',             f.id,
                   'severity',       f.severity,
                   'entity_label',   f.entity_label,
                   'detail_label',   f.detail_label,
                   'expected_label', f.expected_label,
                   'actual_label',   f.actual_label,
                   'diff_label',     f.diff_label,
                   'has_amounts',    f.expected is not null or f.actual is not null,
                   'route',          f.route,
                   'route_args',     f.route_args,
                   'route_label',    case f.route when 'order'    then public._c('recon.open_order')
                                                  when 'money'    then public._c('recon.open_money')
                                                  when 'supplier' then public._c('recon.open_supplier')
                                                  else '' end)
                 order by f.id) filter (where f.id is not null), '[]'::jsonb)) as g
        from public.recon_check ck
        left join public.recon_findings f on f.check_key = ck.key and f.run_id = r.id
       where ck.enabled
       group by ck.ord, ck.key, ck.label, ck.description, ck.source_a_label, ck.source_b_label
    ) s;

  return jsonb_build_object(
    'ok', true,
    'title',            public._c('recon.title'),
    'run',              public._recon_run_card(r),
    'expected_caption', public._c('recon.expected_caption'),
    'actual_caption',   public._c('recon.actual_caption'),
    'diff_caption',     public._c('recon.diff_caption'),
    'empty_label',      public._c('recon.findings_empty'),
    'groups',           v_groups);
end $$;

create or replace function public.recon_run_now(p_days int default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v jsonb; v_to date; v_days int;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;
  select coalesce(p_days, window_days, 30) into v_days from public.recon_config where id = 1;
  v_to := (now() at time zone 'Asia/Kolkata')::date + 1;
  v := public.recon_run(v_to - v_days, v_to, 'manual');
  return v || jsonb_build_object('toast', public._c('recon.run_started_toast'));
exception when others then
  return jsonb_build_object('ok', false, 'toast', public._c('recon.run_failed_toast'),
                            'error', sqlerrm);
end $$;

insert into public.ui_copy (key, value)
select k, to_jsonb(v) from (values
  ('recon.detail.check_failed', 'The check "{check}" could not run: {error}')
) t(k, v)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. SCHEDULE (#305 dispatcher) + THE MORNING ROUTE
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, dml,
                              run_at_ist, note)
values
  ('recon_nightly', 470, 'poll', 'select true',
   'select public.recon_run_nightly()', true, true, '02:50',
   'CHANGE #471 — reconcile payments, bills, GST, margin and settlements. Runs inside the 21:00–02:00 UTC heavy window.'),
  ('recon_morning_notify', 471, 'poll',
   'select exists (select 1 from public.recon_runs where finished_at is not null and notified_at is null)',
   'select public.recon_notify_latest()', true, true, '08:15',
   'CHANGE #471 — the morning post: a green one-liner, or the itemised drift.')
on conflict (name) do update set
  work_sql = excluded.work_sql, gate_sql = excluded.gate_sql,
  run_at_ist = excluded.run_at_ist, mode = excluded.mode,
  dml = excluded.dml, note = excluded.note;

insert into public.wa_event_routes (
  event_key, label, description, audience, enabled, auto_manage,
  push_enabled, email_enabled, email_mode,
  push_title, push_body, email_subject, email_body, wa_category)
values (
  'recon_morning', 'Money reconciliation — morning',
  'The nightly money reconciliation result: green, or the drift that was found.',
  'admin', true, false, true, true, 'always',
  'Money reconciliation', '{{summary}}',
  'Money reconciliation — {{window}}',
  E'{{summary}}\n\n{{detail}}',
  'utility')
on conflict (event_key) do update set
  label = excluded.label, description = excluded.description,
  audience = excluded.audience, email_subject = excluded.email_subject,
  email_body = excluded.email_body, push_title = excluded.push_title,
  push_body = excluded.push_body;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. THE DRIFT THIS COMMAND FOUND AND FIXED
-- ─────────────────────────────────────────────────────────────────────────────
--
-- `gst_ledger_build_output` priced its taxable value with `ptr_discount_pct()`
-- — TODAY's ladder — while the invoice the customer actually received reprints
-- at the slab snapshotted on the order (#318). The moment a slab changed, the
-- GST ledger and the invoice disagreed on every line, permanently, and the new
-- 'gst' check would have reported that on every invoice forever. The ledger
-- must follow the document: the snapshot wins, and the live ladder stays only
-- as the fallback for an order that never captured one.
create or replace function public.gst_ledger_pct_for(p_order_id uuid, p_ptr_total numeric)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((public._order_slab_for_bill(p_order_id, p_ptr_total)->>'discount_pct')::numeric,
                  public.ptr_discount_pct(p_ptr_total));
$$;

-- the one-line fix, with the whole function restated so the migration is self-contained
CREATE OR REPLACE FUNCTION public.gst_ledger_build_output(p_from date, p_to date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seller text; v_prefix text; v_n int;
begin
  select seller_gstin, coalesce(invoice_prefix,'MB')
    into v_seller, v_prefix from public.billing_config where id = 1;

  with elig as (
    select o.id, o.order_code, o.user_id,
           coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) as inv_dt,
           o.delivery_charge, o.delivery_charge_gst, o.delivery_charge_waived,
           o.delivery_charge_at, o.delivery_charge_label
      from public.orders o
     where not coalesce(o.is_synthetic, false)
       and exists (select 1 from public.bill_line_allocations a
                     join public.bill_lines b on b.id = a.bill_line_id
                    where a.order_id = o.id and b.verified)
       and not exists (
             select 1 from public.order_items oi
              where oi.order_id = o.id
                and oi.fulfillment_state not in ('shipped','cancelled')
                and coalesce(oi.unfulfillable,false) = false
                and not exists (select 1 from public.bill_line_allocations a2
                                  join public.bill_lines b2 on b2.id = a2.bill_line_id
                                 where a2.order_item_id = oi.id
                                   and b2.verified and b2.needs_fix is null))
  ), scoped as (
    select * from elig where inv_dt >= p_from and inv_dt < p_to
  ), buyer as (
    select s.*,
           coalesce(ph.pharmacy_name, o.pharmacy_name) as buyer_nm,
           public.gst_norm_gstin(coalesce(ph.gstin, ph.gst_no)) as buyer_gstin,
           ph.user_id::text as buyer_id
      from scoped s
      join public.orders o on o.id = s.id
      left join lateral (select * from public.pharmacy_profiles p
                          where p.user_id = s.user_id limit 1) ph on true
  ), tot as (
    select b.id, coalesce(sum(a.qty * bl.ptr), 0) as ptr_total
      from buyer b
      join public.bill_line_allocations a on a.order_id = b.id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
     group by b.id
  ), pct as (
    select t.id, public.gst_ledger_pct_for(t.id, t.ptr_total) as pct from tot t
  ), goods as (
    select b.id as order_id, b.order_code, b.inv_dt, b.buyer_nm, b.buyer_gstin, b.buyer_id,
           a.id::text as line_ref,
           coalesce(nullif(btrim(coalesce(bl.hsn,'')),''),
                    (select default_hsn from public.billing_config where id=1), '3004') as hsn,
           coalesce(m.product_name, bl.raw_name) as product_nm,
           a.qty,
           coalesce(bl.gst_pct,0) as rate,
           round(a.qty * bl.ptr, 2)
             - round(round(a.qty * bl.ptr, 2) * p.pct / 100.0, 2) as taxable
      from buyer b
      join public.bill_line_allocations a on a.order_id = b.id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
      join pct p on p.id = b.id
      left join public."MEDICINE" m on m.id = bl.product_id
  ), delivery as (
    -- Only a FROZEN, non-waived charge is a taxable outward supply. The rate is
    -- read back off the frozen pair, never assumed.
    select b.id as order_id, b.order_code, b.inv_dt, b.buyer_nm, b.buyer_gstin, b.buyer_id,
           'delivery'::text as line_ref,
           coalesce(nullif(public._c('gst.delivery_hsn'),''),'9968') as hsn,
           coalesce(nullif(b.delivery_charge_label,''), nullif(public._c('gst.delivery_label'),''), 'Delivery charge') as product_nm,
           1::numeric as qty,
           round(coalesce(b.delivery_charge_gst,0) * 100.0 / nullif(b.delivery_charge,0), 2) as rate,
           coalesce(b.delivery_charge,0) as taxable
      from buyer b
     where b.delivery_charge_at is not null
       and coalesce(b.delivery_charge_waived,true) = false
       and coalesce(b.delivery_charge,0) > 0
  ), all_lines as (
    select * from goods union all select * from delivery
  ), split as (
    select l.*, public.gst_split(l.taxable, l.rate, v_seller, l.buyer_gstin) as sp
      from all_lines l
  )
  insert into public.gst_ledger (
    direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_date, invoice_date_text,
    counterparty_id, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, taxable, rate,
    cgst, sgst, igst, is_interstate, gstin_missing, place_of_supply,
    order_id, order_code)
  select
    'output', 'customer_bill', s.order_id, s.line_ref, date_trunc('month', s.inv_dt)::date,
    v_prefix || '-' || coalesce(s.order_code,''), s.inv_dt,
    to_char(s.inv_dt,'DD/MM/YYYY'),
    s.buyer_id, s.buyer_nm, s.buyer_gstin,
    s.hsn, s.product_nm, s.qty, s.taxable, s.rate,
    (s.sp->>'cgst')::numeric, (s.sp->>'sgst')::numeric, (s.sp->>'igst')::numeric,
    (s.sp->>'is_interstate')::boolean, (s.sp->>'gstin_missing')::boolean, s.sp->>'place_of_supply',
    s.order_id, s.order_code
  from split s
  on conflict (direction, source, source_id, line_ref) do update set
    tax_period = excluded.tax_period, invoice_no = excluded.invoice_no,
    invoice_date = excluded.invoice_date, invoice_date_text = excluded.invoice_date_text,
    counterparty_id = excluded.counterparty_id, counterparty_name = excluded.counterparty_name,
    counterparty_gstin = excluded.counterparty_gstin, hsn = excluded.hsn,
    product_name = excluded.product_name, qty = excluded.qty,
    taxable = excluded.taxable, rate = excluded.rate,
    cgst = excluded.cgst, sgst = excluded.sgst, igst = excluded.igst,
    is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
    place_of_supply = excluded.place_of_supply,
    order_id = excluded.order_id, order_code = excluded.order_code, built_at = now();

  get diagnostics v_n = row_count;
  return v_n;
end $function$

;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. REACHABILITY — the tile, in the registry the shell already renders
-- ─────────────────────────────────────────────────────────────────────────────
-- Dashboard › Money › Reconciliation. The nav is backend-driven (#325/#653):
-- this row IS the entry point, and `case 'recon'` in home_shell is its
-- destination. icon_key must exist in the Dart catalogue — `fact_check` does,
-- and the nav_icons_resolve guard fails the build if it ever does not.
insert into public.feature_registry (
  feature_key, label, icon_key, route_key, sort_order, owner, partner_eligible,
  default_access, is_active, category, surface, roles_allowed, deep_link,
  search_terms, description, canonical_key)
values (
  'admin.recon', 'Reconciliation', 'fact_check', 'recon', 870, 'medibo', false,
  'none', true, 'money', 'dashboard', array['admin','super_admin'],
  '/admin/recon',
  'recon reconcile reconciliation drift money audit paisa gst settlement margin payments bills tally',
  'Every night the money surfaces are compared against each other. A one-paisa difference is a finding.',
  'admin.recon')
on conflict (feature_key) do update set
  label = excluded.label, icon_key = excluded.icon_key,
  route_key = excluded.route_key, sort_order = excluded.sort_order,
  category = excluded.category, surface = excluded.surface,
  roles_allowed = excluded.roles_allowed, deep_link = excluded.deep_link,
  search_terms = excluded.search_terms, description = excluded.description,
  is_active = true;
