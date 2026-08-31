-- ============================================================================
-- CHANGE #319 — Profit & loss: true margin per line, order, customer,
-- supplier and zone.
--
-- The rule this file exists to enforce: MARGIN IS TAXABLE MINUS TAXABLE.
-- GST is collected on the customer side and paid on the supplier side; it is
-- pass-through and never profit, so it appears nowhere in a margin number here.
--
-- Four traps this engine is built around:
--   1. SCHEME GOODS. A 10+1 means eleven units arrived for the price of ten,
--      so the real unit cost is ptr/11, not ptr. Costing a scheme line at ptr
--      reports fake margin on every scheme item we sell.
--   2. THE SLAB DRIFTS. The customer discount is an order-level slab
--      (ptr_discount_pct). If a credit note six weeks later reverses at
--      TODAY'S slab, the P&L of a closed order silently moves. So the slab in
--      force when the bill was generated is FROZEN in order_pnl_slab, and
--      every reversal reads that frozen number.
--   3. GROSS MARGIN IS NOT PROFIT. Delivery, the payment gateway's cut, the
--      per-message WhatsApp bill and packing are real money leaving on the
--      same order, so the headline figure is CONTRIBUTION margin, with the
--      gross figure shown beside it rather than instead of it.
--   4. A NEGATIVE LINE MUST BE VISIBLE, NEVER BLOCKING. Selling below cost is
--      reported at bill generation and nothing else: the committed customer
--      discount is never reduced and no bill is ever held back. The alert
--      hangs off an AFTER INSERT trigger on bill_jobs and is wrapped in its
--      own exception block, so a fault in this file cannot stop a bill.
--
-- Everything an admin reads on the P&L screen — every heading, tab, tile
-- label, empty state and footnote — is a row in pnl_label, and every rupee is
-- formatted by inr_money() in Postgres. Re-wording the screen is an UPDATE.
--
-- Idempotent by construction (#233): re-running this file is a silent no-op.
-- ============================================================================

-- ── 1. What the platform pays, beyond the goods ─────────────────────────────
-- One row. Rates, not measurements: Razorpay does not push its fee into this
-- database, so the gateway cut is modelled from the published rate and applied
-- to what was actually collected through the gateway. Cash and direct UPI cost
-- nothing and are excluded by construction (they never create a gateway row).
create table if not exists public.pnl_cost_config (
  id                      smallint primary key default 1,
  gateway_fee_pct         numeric not null default 2,
  gateway_fee_fixed       numeric not null default 0,
  gateway_fee_gst_pct     numeric not null default 18,
  packing_per_order       numeric not null default 0,
  packing_per_line        numeric not null default 0,
  delivery_cost_fallback  numeric not null default 0,
  negative_alert_enabled  boolean not null default true,
  negative_alert_phone    text,
  updated_at              timestamptz not null default now(),
  updated_by              text,
  constraint pnl_cost_config_singleton_ck check (id = 1)
);
insert into public.pnl_cost_config (id) values (1) on conflict (id) do nothing;

alter table public.pnl_cost_config enable row level security;
drop policy if exists pnl_cost_config_admin_all on public.pnl_cost_config;
create policy pnl_cost_config_admin_all on public.pnl_cost_config
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on table public.pnl_cost_config from public, anon;
grant select on table public.pnl_cost_config to authenticated;
grant all on table public.pnl_cost_config to service_role;

-- ── 2. What a credit note reverses ──────────────────────────────────────────
-- Revenue always reverses: the customer is not paying for it. Whether the COST
-- reverses depends on who is out of pocket — a short supply is stock we never
-- received and never pay for, while damage in our own transit is ours to eat.
-- A row here, so the rule is a policy Om can change, not a branch in SQL.
create table if not exists public.pnl_claim_rule (
  kind          text primary key,
  cost_reverses boolean not null default true,
  label         text not null,
  note          text
);
insert into public.pnl_claim_rule (kind, cost_reverses, label, note) values
  ('short',   true,  'Short supply',        'Never received, never paid for — cost reverses with the revenue.'),
  ('damaged', false, 'Damaged in transit',  'We paid the supplier and the customer is credited — the cost stays.'),
  ('missing', false, 'Missing on delivery', 'We paid the supplier and the customer is credited — the cost stays.')
on conflict (kind) do nothing;

alter table public.pnl_claim_rule enable row level security;
drop policy if exists pnl_claim_rule_read on public.pnl_claim_rule;
create policy pnl_claim_rule_read on public.pnl_claim_rule
  for select to authenticated using (public.is_admin());
revoke all on table public.pnl_claim_rule from public, anon;
grant select on table public.pnl_claim_rule to authenticated;
grant all on table public.pnl_claim_rule to service_role;

-- ── 3. The frozen slab ──────────────────────────────────────────────────────
-- Captured once, at bill generation, and never updated. `on conflict do
-- nothing` is the whole point: a re-billed order keeps the slab its FIRST
-- invoice used, which is the number the customer was actually charged at.
create table if not exists public.order_pnl_slab (
  order_id    uuid primary key references public.orders(id) on delete cascade,
  slab_pct    numeric not null,
  ptr_total   numeric not null,
  source      text not null default 'bill',
  captured_at timestamptz not null default now()
);
alter table public.order_pnl_slab enable row level security;
drop policy if exists order_pnl_slab_read on public.order_pnl_slab;
create policy order_pnl_slab_read on public.order_pnl_slab
  for select to authenticated using (public.is_admin());
revoke all on table public.order_pnl_slab from public, anon;
grant select on table public.order_pnl_slab to authenticated;
grant all on table public.order_pnl_slab to service_role;

-- ── 4. The negative-margin register ─────────────────────────────────────────
-- Visibility only. One row per (order, bill line) so a re-bill refreshes the
-- finding instead of growing a duplicate.
create table if not exists public.pnl_alert (
  id            bigserial primary key,
  order_id      uuid,
  order_code    text,
  bill_line_id  uuid,
  product       text,
  qty           numeric,
  cust_taxable  numeric,
  sup_taxable   numeric,
  margin        numeric,
  detail        jsonb,
  created_at    timestamptz not null default now(),
  seen_at       timestamptz
);
create unique index if not exists pnl_alert_identity_uk
  on public.pnl_alert (order_id, bill_line_id);
create index if not exists pnl_alert_created_idx on public.pnl_alert (created_at desc);

alter table public.pnl_alert enable row level security;
drop policy if exists pnl_alert_admin_all on public.pnl_alert;
create policy pnl_alert_admin_all on public.pnl_alert
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on table public.pnl_alert from public, anon;
grant select on table public.pnl_alert to authenticated;
grant all on table public.pnl_alert to service_role;
grant usage, select on sequence public.pnl_alert_id_seq to service_role;

-- ── 5. Backend-owned copy ───────────────────────────────────────────────────
-- tone is a DESIGN TOKEN NAME (brand/success/warning/danger/info/neutral),
-- never a hex — Flutter maps tone -> Ds.c.*, so ui_design_set() carries this
-- screen with the rest of the app.
create table if not exists public.pnl_label (
  key        text primary key,
  label      text not null,
  tone       text,
  sort_order int not null default 0
);
alter table public.pnl_label enable row level security;
drop policy if exists pnl_label_read on public.pnl_label;
create policy pnl_label_read on public.pnl_label
  for select to authenticated using (public.is_admin());
revoke all on table public.pnl_label from public, anon;
grant select on table public.pnl_label to authenticated;
grant all on table public.pnl_label to service_role;

insert into public.pnl_label (key, label, tone, sort_order) values
  ('ui.title',              'Profit & loss',                                   null, 0),
  ('ui.subtitle',           'Margin is taxable minus taxable. GST is pass-through on both sides and is never counted as profit.', null, 0),
  ('ui.range_days',         'Last %s days',                                    null, 0),
  ('ui.refresh',            'Refresh',                                         null, 0),
  ('ui.error',              'Could not load the profit & loss figures.',       'danger',  0),
  ('ui.retry',              'Retry',                                           null, 0),
  ('ui.not_authorized',     'Admins only.',                                    'danger',  0),
  ('ui.empty',              'No billed lines in this window yet. A line appears here once a supplier bill is verified and allocated to an order.', null, 0),
  ('ui.footnote',           'Cost is the supplier rate after their discount, spread across scheme free goods. Contribution subtracts delivery, the gateway cut, WhatsApp and packing.', null, 0),

  ('tab.overview',          'Overview',                                        null, 1),
  ('tab.customer',          'Customers',                                       null, 2),
  ('tab.supplier',          'Suppliers',                                       null, 3),
  ('tab.zone',              'Zones',                                           null, 4),
  ('tab.day',               'Daily',                                           null, 5),
  ('tab.month',             'Monthly',                                         null, 6),
  ('tab.order',             'Orders',                                          null, 7),
  ('tab.alerts',            'Below cost',                                      null, 8),
  ('tab.simulator',         'Slab simulator',                                  null, 9),

  ('tile.revenue',          'Revenue (taxable)',                               null, 1),
  ('tile.cost',             'Goods cost',                                      null, 2),
  ('tile.gross',            'Gross margin',                                    null, 3),
  ('tile.contribution',     'Contribution',                                    'brand', 4),
  ('tile.margin_pct',       'Gross margin %',                                  null, 5),
  ('tile.orders',           'Orders billed',                                   null, 6),
  ('tile.scheme',           'Scheme goods saved',                              'success', 7),
  ('tile.negative',         'Lines below cost',                                'danger',  8),

  ('cost.delivery',         'Delivery paid out',                               null, 1),
  ('cost.delivery_rec',     'Delivery recovered',                              null, 2),
  ('cost.gateway',          'Payment gateway',                                 null, 3),
  ('cost.whatsapp',         'WhatsApp messages',                               null, 4),
  ('cost.packing',          'Packing',                                         null, 5),
  ('cost.credit_rev',       'Credit notes (revenue)',                          null, 6),
  ('cost.credit_cost',      'Credit notes (cost back)',                        null, 7),
  ('cost.heading',          'Below the goods',                                 null, 0),

  ('sec.top_customers',     'Margin per customer',                             null, 1),
  ('sec.top_suppliers',     'Margin per supplier',                             null, 2),
  ('sec.by_zone',           'Margin per zone',                                 null, 3),
  ('sec.by_day',            'Margin per day',                                  null, 4),
  ('sec.alerts',            'Sold below cost',                                 'danger', 5),
  ('sec.lines',             'Lines',                                           null, 6),

  ('col.margin',            'Margin',                                          null, 0),
  ('col.revenue',           'Revenue',                                         null, 0),
  ('col.orders',            'orders',                                          null, 0),
  ('col.lines',             'lines',                                           null, 0),

  ('alert.empty',           'Nothing has sold below cost in this window.',     'success', 0),
  ('alert.title',           'Sold below cost',                                 'danger',  0),
  ('alert.note',            'Reported only. The customer discount that was committed is never reduced and no bill is ever held back.', null, 0),

  ('sim.title',             'Slab simulator',                                  null, 0),
  ('sim.subtitle',          'Replay a proposed slab against the orders already billed in this window, before you save it.', null, 0),
  ('sim.current',           'Current slab',                                     null, 0),
  ('sim.proposed',          'Proposed slab',                                    null, 0),
  ('sim.run',               'Run simulation',                                   'brand', 0),
  ('sim.min_ptr',           'Order value above',                                null, 0),
  ('sim.pct',               'Discount %',                                       null, 0),
  ('sim.result',            'Impact on the same orders',                        null, 0),
  ('sim.empty',             'No billed orders in this window to replay.',       null, 0),
  ('sim.note',              'A simulation changes nothing. Saving a slab is still done in the discount slab screen.', null, 0),
  ('sim.delta_margin',      'Gross margin change',                              null, 1),
  ('sim.delta_revenue',     'Revenue change',                                   null, 2),
  ('sim.delta_negative',    'Lines pushed below cost',                          'danger', 3),
  ('sim.orders_replayed',   'Orders replayed',                                  null, 4),

  ('cfg.heading',           'Rates used below the goods',                       null, 0),
  ('cfg.gateway_fee_pct',   'Gateway fee %',                                    null, 1),
  ('cfg.gateway_fee_fixed', 'Gateway fee per payment (₹)',                      null, 2),
  ('cfg.gateway_fee_gst_pct','GST on the gateway fee %',                        null, 3),
  ('cfg.packing_per_order', 'Packing per order (₹)',                            null, 4),
  ('cfg.packing_per_line',  'Packing per line (₹)',                             null, 5),
  ('cfg.delivery_cost_fallback','Delivery cost when a zone has no rate (₹)',    null, 6),
  ('cfg.saved',             'Saved.',                                           'success', 0),
  ('cfg.save',              'Save rates',                                       'brand',   0)
on conflict (key) do update
  set label = excluded.label, tone = excluded.tone, sort_order = excluded.sort_order;

create or replace function public._pnl_c(p_key text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select label from public.pnl_label where key = p_key), '');
$$;

create or replace function public._pnl_tone(p_key text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select tone from public.pnl_label where key = p_key), 'neutral');
$$;

-- ── 6. The per-message cost of talking to a customer ────────────────────────
-- The dispatcher stamps `cost` on most rows; the ones it could not price fall
-- back to the published rate for their channel and category.
create or replace function public._pnl_msg_cost(p_cost numeric, p_channel text, p_category text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    p_cost,
    (select unit_cost from public.notification_cost_config
      where channel = coalesce(nullif(p_channel,''),'whatsapp')
        and category = coalesce(nullif(p_category,''),'all') limit 1),
    (select unit_cost from public.notification_cost_config
      where channel = coalesce(nullif(p_channel,''),'whatsapp')
        and category = 'all' limit 1),
    0);
$$;

-- ── 7. Freezing the slab ────────────────────────────────────────────────────
create or replace function public.pnl_slab_capture(p_order_id uuid)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare v_total numeric; v_pct numeric; v_snap jsonb;
begin
  -- CHANGE #318 owns the bill-time slab: order_slab_snapshot() freezes it onto
  -- the order itself and every reprint reads it back. P&L does NOT keep a
  -- second opinion — it asks for that snapshot and mirrors it here so the
  -- margin history has its own dated copy to audit against.
  begin
    v_snap := public.order_slab_snapshot(p_order_id);
  exception when others then
    v_snap := null;
  end;

  v_total := coalesce((v_snap->>'base')::numeric, public._order_taxable_base(p_order_id));
  v_pct   := coalesce((v_snap->>'discount_pct')::numeric,
                      public.ptr_discount_pct(v_total), 0);

  insert into public.order_pnl_slab (order_id, slab_pct, ptr_total)
  values (p_order_id, v_pct, v_total)
  on conflict (order_id) do nothing;

  return v_pct;
end $$;

-- ── 8. THE ENGINE — one row per allocated bill line ─────────────────────────
-- Read as: what the customer was charged for this line, what the goods on it
-- actually cost us, and the difference. Both sides are TAXABLE — no GST.
--
-- The customer side is computed the way _bill_compose computes it, rounding in
-- the same order, so a line here and the same line on the printed invoice
-- agree to the paisa rather than "nearly".
--
-- The cost side applies the supplier's own discount and then spreads the money
-- across the goods that actually arrived: bill_qty paid for, free_qty free, so
-- the amortisation factor is qty/(qty+free). A 10+1 line costs ptr*10/11 a unit.
create or replace view public.pnl_line_v as
with base as (
  select
    a.id                                          as alloc_id,
    a.order_id,
    a.order_item_id,
    a.qty,
    b.id                                          as bill_line_id,
    coalesce(b.ptr, 0)                            as ptr,
    coalesce(b.mrp, 0)                            as mrp,
    coalesce(b.disc_pct, 0)                       as disc_pct,
    coalesce(b.free_qty, 0)                       as free_qty,
    coalesce(b.qty, 0)                            as bill_qty,
    coalesce(b.gst_pct, 0)                        as gst_pct,
    b.product_id,
    coalesce(m.product_name, b.raw_name)          as product,
    b.supplier_order_id,
    coalesce(so.supplier_name, b.supplier_name)   as supplier_name,
    so.supplier_id,
    o.order_code,
    coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) as order_date,
    o.zone_id,
    z.name                                        as zone_name,
    coalesce(pp.id::text, o.customer_id::text, o.user_id::text) as customer_key,
    coalesce(pp.pharmacy_name, o.pharmacy_name)   as customer_name
  from public.bill_line_allocations a
  join public.bill_lines b on b.id = a.bill_line_id and b.verified
  join public.orders o      on o.id = a.order_id
  left join public."MEDICINE" m on m.id = b.product_id
  left join public.supplier_orders so on so.id = b.supplier_order_id
  left join public.zones z on z.id = o.zone_id
  left join lateral (
    select p.* from public.pharmacy_profiles p
     where (o.customer_id is not null and p.id = o.customer_id)
        or (o.customer_id is null and p.user_id = o.user_id)
     limit 1) pp on true
),
tot as (
  -- the same base _order_taxable_base() uses: each line rounded, then summed
  select order_id, sum(round(qty * ptr, 2)) as ptr_total from base group by order_id
),
slab as (
  -- The FROZEN slab wins, and the order carries it: CHANGE #318 stamps
  -- bill_discount_pct at bill time and every reprint reads it back, so P&L
  -- reads the same number rather than re-deriving one. order_pnl_slab is the
  -- P&L-side mirror for orders billed before that stamp existed; only an order
  -- that was never billed at all falls through to today's ladder.
  select t.order_id,
         coalesce(o.bill_discount_pct, s.slab_pct,
                  public.ptr_discount_pct(t.ptr_total), 0)                  as slab_pct,
         (o.bill_discount_pct is not null or s.order_id is not null)        as slab_frozen
    from tot t
    join public.orders o on o.id = t.order_id
    left join public.order_pnl_slab s on s.order_id = t.order_id
)
select
  b.alloc_id,
  b.order_id,
  b.order_item_id,
  b.bill_line_id,
  b.order_code,
  b.order_date,
  to_char(b.order_date, 'YYYY-MM')                as order_month,
  b.zone_id,
  b.zone_name,
  b.customer_key,
  b.customer_name,
  b.supplier_id,
  b.supplier_name,
  b.product_id,
  b.product,
  b.qty,
  b.ptr,
  b.mrp,
  b.gst_pct,
  b.disc_pct,
  b.free_qty,
  b.bill_qty,
  s.slab_pct,
  s.slab_frozen,
  -- the amortisation factor, exposed so a credit note reverses at the SAME cost
  case when b.free_qty > 0 and (b.bill_qty + b.free_qty) > 0
       then b.bill_qty / (b.bill_qty + b.free_qty) else 1 end          as amort,
  round(b.qty * b.ptr, 2)                                              as line_value,
  round(round(b.qty * b.ptr, 2) * s.slab_pct / 100, 2)                 as cust_disc,
  round(b.qty * b.ptr, 2)
    - round(round(b.qty * b.ptr, 2) * s.slab_pct / 100, 2)             as cust_taxable,
  round(b.qty * b.ptr * (1 - b.disc_pct / 100), 2)                     as sup_taxable_unamortised,
  round(b.qty * b.ptr * (1 - b.disc_pct / 100)
        * (case when b.free_qty > 0 and (b.bill_qty + b.free_qty) > 0
                then b.bill_qty / (b.bill_qty + b.free_qty) else 1 end), 2) as sup_taxable,
  round(b.qty * b.ptr * (1 - b.disc_pct / 100), 2)
    - round(b.qty * b.ptr * (1 - b.disc_pct / 100)
        * (case when b.free_qty > 0 and (b.bill_qty + b.free_qty) > 0
                then b.bill_qty / (b.bill_qty + b.free_qty) else 1 end), 2) as scheme_saving,
  (round(b.qty * b.ptr, 2)
     - round(round(b.qty * b.ptr, 2) * s.slab_pct / 100, 2))
   - round(b.qty * b.ptr * (1 - b.disc_pct / 100)
        * (case when b.free_qty > 0 and (b.bill_qty + b.free_qty) > 0
                then b.bill_qty / (b.bill_qty + b.free_qty) else 1 end), 2) as margin
from base b
join slab s on s.order_id = b.order_id;

revoke all on public.pnl_line_v from public, anon, authenticated;

-- ── 9. Credit notes, reversed at the ORIGINAL slab ──────────────────────────
create or replace view public.pnl_credit_v as
select
  c.order_id,
  sum(case when x.ptr is not null and coalesce(c.qty,0) > 0
           then round(round(coalesce(c.qty,0) * x.ptr, 2) * (100 - x.slab_pct) / 100, 2)
           else coalesce(c.amount, 0) end)                              as revenue_reversal,
  sum(case when coalesce(r.cost_reverses, true) and x.ptr is not null and coalesce(c.qty,0) > 0
           then round(coalesce(c.qty,0) * x.ptr * (1 - x.disc_pct / 100) * x.amort, 2)
           else 0 end)                                                  as cost_reversal,
  count(*)                                                              as notes
from public.delivery_claims c
left join public.pnl_claim_rule r on r.kind = c.kind
left join lateral (
  select v.ptr, v.disc_pct, v.slab_pct, v.amort
    from public.pnl_line_v v
   where v.order_item_id = c.order_item_id
   limit 1) x on true
where c.status in ('approved','credited')
  and coalesce(c.amount, 0) > 0
group by c.order_id;

revoke all on public.pnl_credit_v from public, anon, authenticated;

-- ── 10. Per order: gross margin, then everything that leaves below it ───────
create or replace view public.pnl_order_v as
with l as (
  select order_id,
         min(order_date)        as order_date,
         min(order_month)       as order_month,
         min(zone_id)           as zone_id,
         min(zone_name)         as zone_name,
         min(customer_key)      as customer_key,
         min(customer_name)     as customer_name,
         min(order_code)        as order_code,
         count(*)               as lines,
         count(*) filter (where margin < 0) as negative_lines,
         sum(cust_taxable)      as revenue,
         sum(sup_taxable)       as goods_cost,
         sum(scheme_saving)     as scheme_saving,
         sum(margin)            as line_margin
    from public.pnl_line_v
   group by order_id
),
cfg as (select * from public.pnl_cost_config where id = 1),
wa as (
  select n.order_id,
         round(sum(public._pnl_msg_cost(n.cost, n.channel, n.wa_category)), 2) as cost
    from public.notification_log n
   where n.order_id is not null
     and coalesce(n.status,'') in ('sent','delivered','read')
   group by n.order_id
),
-- What the gateway actually took a cut of. A QR and a payment link for the
-- same order are two ways of collecting the SAME money, so the base is the
-- larger of the two rather than their sum — an order is never charged twice.
rzp as (
  select o.id as order_id,
         greatest(
           coalesce((select sum(q.amount) from public.razorpay_qr q
                      where q.order_id = o.id and q.status in ('paid','closed_paid')), 0),
           coalesce((select sum(t.amount) from public.rzp_payment_attempt t
                      where t.order_id = o.id and t.status in ('paid','captured')), 0)
         ) as collected,
         greatest(
           coalesce((select count(*) from public.razorpay_qr q
                      where q.order_id = o.id and q.status in ('paid','closed_paid')), 0),
           coalesce((select count(*) from public.rzp_payment_attempt t
                      where t.order_id = o.id and t.status in ('paid','captured')), 0)
         ) as txns
    from public.orders o
),
del as (
  select o.id as order_id,
         coalesce(
           (select sum(pl.amount) from public.delivery_payout_lines pl where pl.order_id = o.id),
           (select zdc.cost_per_drop from public.zone_delivery_config zdc where zdc.zone_id = o.zone_id),
           (select delivery_cost_fallback from cfg),
           0) as delivery_cost,
         case when coalesce(o.delivery_charge_waived, true) then 0
              else coalesce(o.delivery_charge, 0) end as delivery_recovered
    from public.orders o
)
select
  l.order_id, l.order_code, l.order_date, l.order_month,
  l.zone_id, l.zone_name, l.customer_key, l.customer_name,
  l.lines, l.negative_lines,
  l.revenue, l.goods_cost, l.scheme_saving,
  coalesce(cn.revenue_reversal, 0)                as credit_revenue,
  coalesce(cn.cost_reversal, 0)                   as credit_cost,
  -- gross margin AFTER credit notes: a returned line earns nothing
  round(l.line_margin - coalesce(cn.revenue_reversal, 0) + coalesce(cn.cost_reversal, 0), 2)
                                                  as gross_margin,
  coalesce(del.delivery_cost, 0)                  as delivery_cost,
  coalesce(del.delivery_recovered, 0)             as delivery_recovered,
  round(coalesce(rzp.collected, 0) * (select gateway_fee_pct from cfg) / 100
        + coalesce(rzp.txns, 0) * (select gateway_fee_fixed from cfg), 2)
                                                  as gateway_fee,
  round((coalesce(rzp.collected, 0) * (select gateway_fee_pct from cfg) / 100
         + coalesce(rzp.txns, 0) * (select gateway_fee_fixed from cfg))
        * (select gateway_fee_gst_pct from cfg) / 100, 2)
                                                  as gateway_fee_gst,
  coalesce(wa.cost, 0)                            as whatsapp_cost,
  round((select packing_per_order from cfg) + (select packing_per_line from cfg) * l.lines, 2)
                                                  as packing_cost,
  round(
    (l.line_margin - coalesce(cn.revenue_reversal, 0) + coalesce(cn.cost_reversal, 0))
    - coalesce(del.delivery_cost, 0)
    + coalesce(del.delivery_recovered, 0)
    - (coalesce(rzp.collected, 0) * (select gateway_fee_pct from cfg) / 100
       + coalesce(rzp.txns, 0) * (select gateway_fee_fixed from cfg))
      * (1 + (select gateway_fee_gst_pct from cfg) / 100)
    - coalesce(wa.cost, 0)
    - ((select packing_per_order from cfg) + (select packing_per_line from cfg) * l.lines)
  , 2)                                            as contribution
from l
left join public.pnl_credit_v cn on cn.order_id = l.order_id
left join wa  on wa.order_id  = l.order_id
left join rzp on rzp.order_id = l.order_id
left join del on del.order_id = l.order_id;

revoke all on public.pnl_order_v from public, anon, authenticated;

-- ── 11. The headline: one payload, fully worded and fully formatted ─────────
create or replace function public.pnl_dashboard(p_days int default 30,
                                                p_zone_id smallint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_from date := ((now() at time zone 'Asia/Kolkata')::date - (greatest(coalesce(p_days,30),1) - 1));
  v_rev numeric; v_cost numeric; v_gross numeric; v_contrib numeric;
  v_scheme numeric; v_orders int; v_lines int; v_neg int;
  v_del numeric; v_delr numeric; v_gw numeric; v_wa numeric; v_pack numeric;
  v_crev numeric; v_ccost numeric;
  v_tiles jsonb; v_sections jsonb; v_costs jsonb; v_alerts jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;

  select
    coalesce(sum(o.revenue),0), coalesce(sum(o.goods_cost),0),
    coalesce(sum(o.gross_margin),0), coalesce(sum(o.contribution),0),
    coalesce(sum(o.scheme_saving),0), count(*)::int, coalesce(sum(o.lines),0)::int,
    coalesce(sum(o.negative_lines),0)::int,
    coalesce(sum(o.delivery_cost),0), coalesce(sum(o.delivery_recovered),0),
    coalesce(sum(o.gateway_fee + o.gateway_fee_gst),0),
    coalesce(sum(o.whatsapp_cost),0), coalesce(sum(o.packing_cost),0),
    coalesce(sum(o.credit_revenue),0), coalesce(sum(o.credit_cost),0)
    into v_rev, v_cost, v_gross, v_contrib, v_scheme, v_orders, v_lines, v_neg,
         v_del, v_delr, v_gw, v_wa, v_pack, v_crev, v_ccost
  from public.pnl_order_v o
  where o.order_date >= v_from
    and (p_zone_id is null or o.zone_id = p_zone_id);

  v_tiles := jsonb_build_array(
    jsonb_build_object('key','revenue','label',public._pnl_c('tile.revenue'),
                       'value', public.inr_money(v_rev), 'tone', 'neutral'),
    jsonb_build_object('key','cost','label',public._pnl_c('tile.cost'),
                       'value', public.inr_money(v_cost), 'tone', 'neutral'),
    jsonb_build_object('key','gross','label',public._pnl_c('tile.gross'),
                       'value', public.inr_money(v_gross),
                       'tone', case when v_gross < 0 then 'danger' else 'success' end),
    jsonb_build_object('key','contribution','label',public._pnl_c('tile.contribution'),
                       'value', public.inr_money(v_contrib),
                       'tone', case when v_contrib < 0 then 'danger' else 'brand' end),
    jsonb_build_object('key','margin_pct','label',public._pnl_c('tile.margin_pct'),
                       'value', case when v_rev <> 0
                                     then to_char(round(v_gross / v_rev * 100, 2),'FM990.00') || '%'
                                     else '—' end,
                       'tone', case when v_gross < 0 then 'danger' else 'neutral' end),
    jsonb_build_object('key','orders','label',public._pnl_c('tile.orders'),
                       'value', v_orders::text, 'tone','neutral'),
    jsonb_build_object('key','scheme','label',public._pnl_c('tile.scheme'),
                       'value', public.inr_money(v_scheme), 'tone','success'),
    jsonb_build_object('key','negative','label',public._pnl_c('tile.negative'),
                       'value', v_neg::text,
                       'tone', case when v_neg > 0 then 'danger' else 'neutral' end));

  v_costs := jsonb_build_object(
    'heading', public._pnl_c('cost.heading'),
    'rows', jsonb_build_array(
      jsonb_build_object('label', public._pnl_c('cost.delivery'),    'value', '- ' || public.inr_money(v_del)),
      jsonb_build_object('label', public._pnl_c('cost.delivery_rec'),'value', '+ ' || public.inr_money(v_delr)),
      jsonb_build_object('label', public._pnl_c('cost.gateway'),     'value', '- ' || public.inr_money(v_gw)),
      jsonb_build_object('label', public._pnl_c('cost.whatsapp'),    'value', '- ' || public.inr_money(v_wa)),
      jsonb_build_object('label', public._pnl_c('cost.packing'),     'value', '- ' || public.inr_money(v_pack)),
      jsonb_build_object('label', public._pnl_c('cost.credit_rev'),  'value', '- ' || public.inr_money(v_crev)),
      jsonb_build_object('label', public._pnl_c('cost.credit_cost'), 'value', '+ ' || public.inr_money(v_ccost))));

  select jsonb_build_array(
    jsonb_build_object('key','customer','heading', public._pnl_c('sec.top_customers'),
      'empty_text', public._pnl_c('ui.empty'),
      'rows', coalesce((select jsonb_agg(r order by (r->>'sort')::numeric desc)
                          from (select jsonb_build_object(
                                  'key', customer_key,
                                  'label', coalesce(customer_name,'—'),
                                  'sub', count(distinct order_id)::text || ' ' || public._pnl_c('col.orders')
                                         || '  ·  ' || public.inr_money(sum(revenue)),
                                  'value', public.inr_money(sum(gross_margin)),
                                  'value_tone', case when sum(gross_margin) < 0 then 'danger' else 'success' end,
                                  'sort', sum(gross_margin)) r
                           from public.pnl_order_v
                          where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
                          group by customer_key, customer_name
                          order by sum(gross_margin) desc limit 10) q), '[]'::jsonb)),
    jsonb_build_object('key','supplier','heading', public._pnl_c('sec.top_suppliers'),
      'empty_text', public._pnl_c('ui.empty'),
      'rows', coalesce((select jsonb_agg(r order by (r->>'sort')::numeric desc)
                          from (select jsonb_build_object(
                                  'key', coalesce(supplier_id::text, supplier_name, '—'),
                                  'label', coalesce(supplier_name,'—'),
                                  'sub', count(*)::text || ' ' || public._pnl_c('col.lines')
                                         || '  ·  ' || public.inr_money(sum(cust_taxable)),
                                  'value', public.inr_money(sum(margin)),
                                  'value_tone', case when sum(margin) < 0 then 'danger' else 'success' end,
                                  'sort', sum(margin)) r
                           from public.pnl_line_v
                          where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
                          group by supplier_id, supplier_name
                          order by sum(margin) desc limit 10) q), '[]'::jsonb)),
    jsonb_build_object('key','zone','heading', public._pnl_c('sec.by_zone'),
      'empty_text', public._pnl_c('ui.empty'),
      'rows', coalesce((select jsonb_agg(r order by (r->>'sort')::numeric desc)
                          from (select jsonb_build_object(
                                  'key', coalesce(zone_id::text,'0'),
                                  'label', coalesce(zone_name,'—'),
                                  'sub', count(*)::text || ' ' || public._pnl_c('col.orders')
                                         || '  ·  ' || public.inr_money(sum(revenue)),
                                  'value', public.inr_money(sum(contribution)),
                                  'value_tone', case when sum(contribution) < 0 then 'danger' else 'brand' end,
                                  'sort', sum(contribution)) r
                           from public.pnl_order_v
                          where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
                          group by zone_id, zone_name) q), '[]'::jsonb)),
    jsonb_build_object('key','day','heading', public._pnl_c('sec.by_day'),
      'empty_text', public._pnl_c('ui.empty'),
      'rows', coalesce((select jsonb_agg(r order by (r->>'key') desc)
                          from (select jsonb_build_object(
                                  'key', to_char(order_date,'YYYY-MM-DD'),
                                  'label', to_char(order_date,'DD Mon YYYY'),
                                  'sub', count(*)::text || ' ' || public._pnl_c('col.orders')
                                         || '  ·  ' || public.inr_money(sum(revenue)),
                                  'value', public.inr_money(sum(gross_margin)),
                                  'value_tone', case when sum(gross_margin) < 0 then 'danger' else 'success' end) r
                           from public.pnl_order_v
                          where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
                          group by order_date
                          order by order_date desc limit 31) q), '[]'::jsonb)))
  into v_sections;

  select jsonb_build_object(
    'heading', public._pnl_c('sec.alerts'),
    'note',    public._pnl_c('alert.note'),
    'empty_text', public._pnl_c('alert.empty'),
    'count',   count(*),
    'rows', coalesce(jsonb_agg(jsonb_build_object(
              'key', a.id::text,
              'label', coalesce(a.product,'—'),
              'sub', coalesce(a.order_code,'') || '  ·  '
                     || public.inr_money(coalesce(a.cust_taxable,0)) || ' → '
                     || public.inr_money(coalesce(a.sup_taxable,0)),
              'value', public.inr_money(coalesce(a.margin,0)),
              'value_tone', 'danger') order by a.created_at desc), '[]'::jsonb))
    into v_alerts
  from (select * from public.pnl_alert order by created_at desc limit 10) a;

  return jsonb_build_object(
    'ok', true,
    'title',       public._pnl_c('ui.title'),
    'subtitle',    public._pnl_c('ui.subtitle'),
    'footnote',    public._pnl_c('ui.footnote'),
    'empty_text',  public._pnl_c('ui.empty'),
    'error_text',  public._pnl_c('ui.error'),
    'retry_text',  public._pnl_c('ui.retry'),
    'days',        greatest(coalesce(p_days,30),1),
    'range_label', replace(public._pnl_c('ui.range_days'), '%s', greatest(coalesce(p_days,30),1)::text),
    'has_data',    (v_lines > 0),
    'tabs', (select coalesce(jsonb_agg(jsonb_build_object(
                      'key', replace(key,'tab.',''), 'label', label) order by sort_order), '[]'::jsonb)
               from public.pnl_label where key like 'tab.%'),
    'tiles',    v_tiles,
    'costs',    v_costs,
    'sections', v_sections,
    'alerts',   v_alerts);
end $$;

revoke all on function public.pnl_dashboard(int, smallint) from public, anon;
grant execute on function public.pnl_dashboard(int, smallint) to authenticated, service_role;

-- ── 12. One dimension at a time, same shape ─────────────────────────────────
create or replace function public.pnl_breakdown(p_dim text default 'customer',
                                                p_days int default 30,
                                                p_limit int default 50,
                                                p_zone_id smallint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_from date := ((now() at time zone 'Asia/Kolkata')::date - (greatest(coalesce(p_days,30),1) - 1));
  v_dim text := coalesce(nullif(btrim(p_dim),''), 'customer');
  v_rows jsonb := '[]'::jsonb;
  v_head text;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;

  if v_dim = 'customer' then
    v_head := public._pnl_c('sec.top_customers');
    select coalesce(jsonb_agg(r order by (r->>'sort')::numeric desc), '[]'::jsonb) into v_rows
      from (select jsonb_build_object(
              'key', customer_key, 'label', coalesce(customer_name,'—'),
              'sub', count(distinct order_id)::text || ' ' || public._pnl_c('col.orders')
                     || '  ·  ' || public.inr_money(sum(revenue))
                     || '  ·  ' || public.inr_money(sum(contribution)),
              'value', public.inr_money(sum(gross_margin)),
              'value_tone', case when sum(gross_margin) < 0 then 'danger' else 'success' end,
              'sort', sum(gross_margin)) r
              from public.pnl_order_v
             where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
             group by customer_key, customer_name
             order by sum(gross_margin) desc
             limit greatest(coalesce(p_limit,50),1)) q;

  elsif v_dim = 'supplier' then
    v_head := public._pnl_c('sec.top_suppliers');
    select coalesce(jsonb_agg(r order by (r->>'sort')::numeric desc), '[]'::jsonb) into v_rows
      from (select jsonb_build_object(
              'key', coalesce(supplier_id::text, supplier_name, '—'),
              'label', coalesce(supplier_name,'—'),
              'sub', count(*)::text || ' ' || public._pnl_c('col.lines')
                     || '  ·  ' || public.inr_money(sum(cust_taxable))
                     || '  ·  ' || public.inr_money(sum(scheme_saving)),
              'value', public.inr_money(sum(margin)),
              'value_tone', case when sum(margin) < 0 then 'danger' else 'success' end,
              'sort', sum(margin)) r
              from public.pnl_line_v
             where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
             group by supplier_id, supplier_name
             order by sum(margin) desc
             limit greatest(coalesce(p_limit,50),1)) q;

  elsif v_dim = 'zone' then
    v_head := public._pnl_c('sec.by_zone');
    select coalesce(jsonb_agg(r order by (r->>'sort')::numeric desc), '[]'::jsonb) into v_rows
      from (select jsonb_build_object(
              'key', coalesce(zone_id::text,'0'), 'label', coalesce(zone_name,'—'),
              'sub', count(*)::text || ' ' || public._pnl_c('col.orders')
                     || '  ·  ' || public.inr_money(sum(revenue)),
              'value', public.inr_money(sum(contribution)),
              'value_tone', case when sum(contribution) < 0 then 'danger' else 'brand' end,
              'sort', sum(contribution)) r
              from public.pnl_order_v
             where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
             group by zone_id, zone_name) q;

  elsif v_dim = 'day' then
    v_head := public._pnl_c('sec.by_day');
    select coalesce(jsonb_agg(r order by (r->>'key') desc), '[]'::jsonb) into v_rows
      from (select jsonb_build_object(
              'key', to_char(order_date,'YYYY-MM-DD'),
              'label', to_char(order_date,'DD Mon YYYY'),
              'sub', count(*)::text || ' ' || public._pnl_c('col.orders')
                     || '  ·  ' || public.inr_money(sum(revenue)),
              'value', public.inr_money(sum(gross_margin)),
              'value_tone', case when sum(gross_margin) < 0 then 'danger' else 'success' end) r
              from public.pnl_order_v
             where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
             group by order_date
             order by order_date desc
             limit greatest(coalesce(p_limit,50),1)) q;

  elsif v_dim = 'month' then
    v_head := public._pnl_c('tab.month');
    select coalesce(jsonb_agg(r order by (r->>'key') desc), '[]'::jsonb) into v_rows
      from (select jsonb_build_object(
              'key', order_month,
              'label', to_char(to_date(order_month,'YYYY-MM'),'Mon YYYY'),
              'sub', count(*)::text || ' ' || public._pnl_c('col.orders')
                     || '  ·  ' || public.inr_money(sum(revenue))
                     || '  ·  ' || public.inr_money(sum(contribution)),
              'value', public.inr_money(sum(gross_margin)),
              'value_tone', case when sum(gross_margin) < 0 then 'danger' else 'success' end) r
              from public.pnl_order_v
             where (p_zone_id is null or zone_id = p_zone_id)
             group by order_month
             order by order_month desc
             limit greatest(coalesce(p_limit,50),1)) q;

  elsif v_dim = 'order' then
    v_head := public._pnl_c('col.orders');
    select coalesce(jsonb_agg(r order by (r->>'sort')::numeric desc), '[]'::jsonb) into v_rows
      from (select jsonb_build_object(
              'key', order_id::text,
              'label', coalesce(order_code,'—'),
              'sub', coalesce(customer_name,'—') || '  ·  ' || public.inr_money(revenue),
              'value', public.inr_money(gross_margin),
              'value_tone', case when gross_margin < 0 then 'danger' else 'success' end,
              'sort', gross_margin) r
              from public.pnl_order_v
             where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
             order by gross_margin desc
             limit greatest(coalesce(p_limit,50),1)) q;

  else
    v_head := public._pnl_c('sec.lines');
    select coalesce(jsonb_agg(r order by (r->>'sort')::numeric desc), '[]'::jsonb) into v_rows
      from (select jsonb_build_object(
              'key', alloc_id::text, 'label', coalesce(product,'—'),
              'sub', coalesce(order_code,'') || '  ·  ' || trim_scale(qty)::text || ' × '
                     || public.inr_money(ptr),
              'value', public.inr_money(margin),
              'value_tone', case when margin < 0 then 'danger' else 'success' end,
              'sort', margin) r
              from public.pnl_line_v
             where order_date >= v_from and (p_zone_id is null or zone_id = p_zone_id)
             order by margin desc
             limit greatest(coalesce(p_limit,50),1)) q;
  end if;

  return jsonb_build_object(
    'ok', true, 'dim', v_dim, 'heading', v_head,
    'range_label', replace(public._pnl_c('ui.range_days'), '%s', greatest(coalesce(p_days,30),1)::text),
    'empty_text', public._pnl_c('ui.empty'),
    'rows', v_rows);
end $$;

revoke all on function public.pnl_breakdown(text, int, int, smallint) from public, anon;
grant execute on function public.pnl_breakdown(text, int, int, smallint) to authenticated, service_role;

-- ── 13. One order, line by line, with everything below the goods ────────────
create or replace function public.pnl_order(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o public.pnl_order_v%rowtype; v_lines jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;

  select * into o from public.pnl_order_v where order_id = p_order_id;
  if o.order_id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
                              'message', public._pnl_c('ui.empty'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', alloc_id::text,
           'label', coalesce(product,'—'),
           'sub', trim_scale(qty)::text || ' × ' || public.inr_money(ptr)
                  || case when free_qty > 0 then '  ·  +' || trim_scale(free_qty)::text || ' free' else '' end
                  || '  ·  ' || coalesce(supplier_name,'—'),
           'revenue', public.inr_money(cust_taxable),
           'cost',    public.inr_money(sup_taxable),
           'value',   public.inr_money(margin),
           'value_tone', case when margin < 0 then 'danger' else 'success' end)
         order by margin), '[]'::jsonb)
    into v_lines
  from public.pnl_line_v where order_id = p_order_id;

  return jsonb_build_object(
    'ok', true,
    'title', coalesce(o.order_code, ''),
    'subtitle', coalesce(o.customer_name,'—'),
    'slab_frozen', exists (select 1 from public.order_pnl_slab s where s.order_id = p_order_id),
    'tiles', jsonb_build_array(
      jsonb_build_object('key','revenue','label',public._pnl_c('tile.revenue'),'value',public.inr_money(o.revenue),'tone','neutral'),
      jsonb_build_object('key','cost','label',public._pnl_c('tile.cost'),'value',public.inr_money(o.goods_cost),'tone','neutral'),
      jsonb_build_object('key','gross','label',public._pnl_c('tile.gross'),'value',public.inr_money(o.gross_margin),
                         'tone', case when o.gross_margin < 0 then 'danger' else 'success' end),
      jsonb_build_object('key','contribution','label',public._pnl_c('tile.contribution'),'value',public.inr_money(o.contribution),
                         'tone', case when o.contribution < 0 then 'danger' else 'brand' end)),
    'costs', jsonb_build_object('heading', public._pnl_c('cost.heading'), 'rows', jsonb_build_array(
      jsonb_build_object('label', public._pnl_c('cost.delivery'),     'value', '- ' || public.inr_money(o.delivery_cost)),
      jsonb_build_object('label', public._pnl_c('cost.delivery_rec'), 'value', '+ ' || public.inr_money(o.delivery_recovered)),
      jsonb_build_object('label', public._pnl_c('cost.gateway'),      'value', '- ' || public.inr_money(o.gateway_fee + o.gateway_fee_gst)),
      jsonb_build_object('label', public._pnl_c('cost.whatsapp'),     'value', '- ' || public.inr_money(o.whatsapp_cost)),
      jsonb_build_object('label', public._pnl_c('cost.packing'),      'value', '- ' || public.inr_money(o.packing_cost)),
      jsonb_build_object('label', public._pnl_c('cost.credit_rev'),   'value', '- ' || public.inr_money(o.credit_revenue)),
      jsonb_build_object('label', public._pnl_c('cost.credit_cost'),  'value', '+ ' || public.inr_money(o.credit_cost)))),
    'lines_heading', public._pnl_c('sec.lines'),
    'lines', v_lines);
end $$;

revoke all on function public.pnl_order(uuid) from public, anon;
grant execute on function public.pnl_order(uuid) to authenticated, service_role;

-- ── 14. The below-cost register ─────────────────────────────────────────────
create or replace function public.pnl_alerts(p_limit int default 50)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', a.id::text,
           'label', coalesce(a.product,'—'),
           'sub', coalesce(a.order_code,'') || '  ·  '
                  || trim_scale(coalesce(a.qty,0))::text || ' × '
                  || public.inr_money(coalesce(a.cust_taxable,0)) || ' → '
                  || public.inr_money(coalesce(a.sup_taxable,0)),
           'value', public.inr_money(coalesce(a.margin,0)),
           'value_tone', 'danger') order by a.created_at desc), '[]'::jsonb)
    into v_rows
  from (select * from public.pnl_alert order by created_at desc
         limit greatest(coalesce(p_limit,50),1)) a;

  return jsonb_build_object('ok', true,
    'heading', public._pnl_c('alert.title'),
    'note', public._pnl_c('alert.note'),
    'empty_text', public._pnl_c('alert.empty'),
    'rows', v_rows);
end $$;

revoke all on function public.pnl_alerts(int) from public, anon;
grant execute on function public.pnl_alerts(int) to authenticated, service_role;

-- ── 15. The rates, readable and editable ────────────────────────────────────
-- One shape, built from a row that is passed in, so the SET path can render
-- the row it JUST wrote. Calling a STABLE pnl_config_get() from inside the
-- setter returned the caller the values from before its own update — the
-- screen saved a rate and redrew the old one.
create or replace function public._pnl_config_payload(c public.pnl_cost_config)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('ok', true,
    'heading', public._pnl_c('cfg.heading'),
    'saved_text', public._pnl_c('cfg.saved'),
    'save_label', public._pnl_c('cfg.save'),
    'fields', jsonb_build_array(
      jsonb_build_object('key','gateway_fee_pct',       'label', public._pnl_c('cfg.gateway_fee_pct'),       'value', c.gateway_fee_pct),
      jsonb_build_object('key','gateway_fee_fixed',     'label', public._pnl_c('cfg.gateway_fee_fixed'),     'value', c.gateway_fee_fixed),
      jsonb_build_object('key','gateway_fee_gst_pct',   'label', public._pnl_c('cfg.gateway_fee_gst_pct'),   'value', c.gateway_fee_gst_pct),
      jsonb_build_object('key','packing_per_order',     'label', public._pnl_c('cfg.packing_per_order'),     'value', c.packing_per_order),
      jsonb_build_object('key','packing_per_line',      'label', public._pnl_c('cfg.packing_per_line'),      'value', c.packing_per_line),
      jsonb_build_object('key','delivery_cost_fallback','label', public._pnl_c('cfg.delivery_cost_fallback'),'value', c.delivery_cost_fallback)));
$$;

create or replace function public.pnl_config_get()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare c public.pnl_cost_config%rowtype;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;
  select * into c from public.pnl_cost_config where id = 1;
  return public._pnl_config_payload(c);
end $$;

create or replace function public.pnl_config_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c public.pnl_cost_config%rowtype;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;

  update public.pnl_cost_config set
    gateway_fee_pct        = coalesce((p_patch->>'gateway_fee_pct')::numeric,        gateway_fee_pct),
    gateway_fee_fixed      = coalesce((p_patch->>'gateway_fee_fixed')::numeric,      gateway_fee_fixed),
    gateway_fee_gst_pct    = coalesce((p_patch->>'gateway_fee_gst_pct')::numeric,    gateway_fee_gst_pct),
    packing_per_order      = coalesce((p_patch->>'packing_per_order')::numeric,      packing_per_order),
    packing_per_line       = coalesce((p_patch->>'packing_per_line')::numeric,       packing_per_line),
    delivery_cost_fallback = coalesce((p_patch->>'delivery_cost_fallback')::numeric, delivery_cost_fallback),
    updated_at = now(), updated_by = coalesce(auth.jwt()->>'email', 'admin')
  where id = 1
  returning * into c;

  return public._pnl_config_payload(c)
         || jsonb_build_object('message', public._pnl_c('cfg.saved'));
end $$;

revoke all on function public.pnl_config_get() from public, anon;
revoke all on function public.pnl_config_set(jsonb) from public, anon;
grant execute on function public.pnl_config_get() to authenticated, service_role;
grant execute on function public.pnl_config_set(jsonb) to authenticated, service_role;

-- ── 16. Which slab a proposed table would have picked ───────────────────────
-- Mirrors discount_slab_pick exactly, including its `>` (not `>=`) boundary and
-- its highest-band-wins ordering, so a simulation of the CURRENT table
-- reproduces the current bills to the paisa. Both the CHANGE #318 column names
-- (min_amount / discount_pct) and the older ones are accepted, so a proposal
-- typed against either vocabulary still prices.
create or replace function public._pnl_slab_pct(p_slabs jsonb, p_total numeric)
returns numeric language sql immutable set search_path to 'public' as $$
  select coalesce((
    select coalesce((e->>'discount_pct')::numeric, (e->>'pct')::numeric, 0)
      from jsonb_array_elements(coalesce(p_slabs, '[]'::jsonb)) e
     where coalesce(p_total,0) >
           coalesce((e->>'min_amount')::numeric, (e->>'min_ptr')::numeric, 0)
     order by coalesce((e->>'min_amount')::numeric, (e->>'min_ptr')::numeric, 0) desc
     limit 1), 0);
$$;

-- ── 17. The simulator ───────────────────────────────────────────────────────
-- Replays a PROPOSED slab table against the orders already billed in the
-- window, at the prices those orders actually carried. Nothing is written and
-- nothing is saved: this answers "what would this have cost me" before the
-- slab table is changed, which is the only moment the answer is still useful.
create or replace function public.pnl_slab_simulate(p_slabs jsonb default null,
                                                    p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_from date := ((now() at time zone 'Asia/Kolkata')::date - (greatest(coalesce(p_days,30),1) - 1));
  v_current jsonb;
  v_rev_old numeric := 0; v_rev_new numeric := 0;
  v_mar_old numeric := 0; v_mar_new numeric := 0;
  v_orders int := 0; v_pushed int := 0;
  v_rows jsonb := '[]'::jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
                    'slab_id', id, 'min_amount', min_amount, 'discount_pct', discount_pct)
                  order by min_amount), '[]'::jsonb)
    into v_current
  from public.discount_slabs where active;

  if p_slabs is null or jsonb_typeof(p_slabs) <> 'array' then
    return jsonb_build_object('ok', true, 'ran', false,
      'title', public._pnl_c('sim.title'),
      'subtitle', public._pnl_c('sim.subtitle'),
      'current_label', public._pnl_c('sim.current'),
      'proposed_label', public._pnl_c('sim.proposed'),
      'min_ptr_label', public._pnl_c('sim.min_ptr'),
      'pct_label', public._pnl_c('sim.pct'),
      'run_label', public._pnl_c('sim.run'),
      'note', public._pnl_c('sim.note'),
      'empty_text', public._pnl_c('sim.empty'),
      'range_label', replace(public._pnl_c('ui.range_days'), '%s', greatest(coalesce(p_days,30),1)::text),
      'current', v_current);
  end if;

  with ord as (
    select order_id, sum(line_value) as ptr_total
      from public.pnl_line_v where order_date >= v_from group by order_id),
  l as (
    select v.*, public._pnl_slab_pct(p_slabs, o.ptr_total) as new_pct
      from public.pnl_line_v v join ord o on o.order_id = v.order_id
     where v.order_date >= v_from),
  c as (
    select l.*,
           l.line_value - round(l.line_value * l.new_pct / 100, 2) as new_cust_taxable,
           (l.line_value - round(l.line_value * l.new_pct / 100, 2)) - l.sup_taxable as new_margin
      from l)
  select
    coalesce(sum(cust_taxable),0), coalesce(sum(new_cust_taxable),0),
    coalesce(sum(margin),0),       coalesce(sum(new_margin),0),
    count(distinct order_id)::int,
    count(*) filter (where new_margin < 0 and margin >= 0)::int
    into v_rev_old, v_rev_new, v_mar_old, v_mar_new, v_orders, v_pushed
  from c;

  with ord as (
    select order_id, sum(line_value) as ptr_total
      from public.pnl_line_v where order_date >= v_from group by order_id),
  l as (
    select v.*, public._pnl_slab_pct(p_slabs, o.ptr_total) as new_pct
      from public.pnl_line_v v join ord o on o.order_id = v.order_id
     where v.order_date >= v_from),
  c as (
    select l.customer_key, l.customer_name, l.margin,
           (l.line_value - round(l.line_value * l.new_pct / 100, 2)) - l.sup_taxable as new_margin
      from l)
  select coalesce(jsonb_agg(r order by (r->>'sort')::numeric), '[]'::jsonb) into v_rows
    from (select jsonb_build_object(
            'key', customer_key,
            'label', coalesce(customer_name,'—'),
            'sub', public.inr_money(sum(margin)) || ' → ' || public.inr_money(sum(new_margin)),
            'value', public.inr_money(sum(new_margin) - sum(margin)),
            'value_tone', case when sum(new_margin) - sum(margin) < 0 then 'danger' else 'success' end,
            'sort', sum(new_margin) - sum(margin)) r
            from c group by customer_key, customer_name
           order by sum(new_margin) - sum(margin)
           limit 20) q;

  return jsonb_build_object('ok', true, 'ran', true,
    'title', public._pnl_c('sim.title'),
    'subtitle', public._pnl_c('sim.subtitle'),
    'current_label', public._pnl_c('sim.current'),
    'proposed_label', public._pnl_c('sim.proposed'),
    'min_ptr_label', public._pnl_c('sim.min_ptr'),
    'pct_label', public._pnl_c('sim.pct'),
    'run_label', public._pnl_c('sim.run'),
    'note', public._pnl_c('sim.note'),
    'empty_text', public._pnl_c('sim.empty'),
    'range_label', replace(public._pnl_c('ui.range_days'), '%s', greatest(coalesce(p_days,30),1)::text),
    'current', v_current,
    'proposed', p_slabs,
    'result_heading', public._pnl_c('sim.result'),
    'has_data', (v_orders > 0),
    'tiles', jsonb_build_array(
      jsonb_build_object('key','delta_margin', 'label', public._pnl_c('sim.delta_margin'),
        'value', public.inr_money(round(v_mar_new - v_mar_old, 2)),
        'tone', case when v_mar_new < v_mar_old then 'danger' else 'success' end),
      jsonb_build_object('key','delta_revenue','label', public._pnl_c('sim.delta_revenue'),
        'value', public.inr_money(round(v_rev_new - v_rev_old, 2)),
        'tone', case when v_rev_new < v_rev_old then 'danger' else 'success' end),
      jsonb_build_object('key','pushed','label', public._pnl_c('sim.delta_negative'),
        'value', v_pushed::text,
        'tone', case when v_pushed > 0 then 'danger' else 'neutral' end),
      jsonb_build_object('key','orders','label', public._pnl_c('sim.orders_replayed'),
        'value', v_orders::text, 'tone','neutral')),
    'rows', v_rows);
end $$;

revoke all on function public.pnl_slab_simulate(jsonb, int) from public, anon;
grant execute on function public.pnl_slab_simulate(jsonb, int) to authenticated, service_role;

-- ── 18. The below-cost report, raised at bill generation ────────────────────
-- Visibility ONLY. It freezes the slab, records every line that sells below
-- cost, and best-effort pings the dispatcher. It reduces no discount, holds no
-- bill and returns no veto — there is nothing here a caller could act on to
-- stop a bill even if it wanted to.
create or replace function public.pnl_bill_generated(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pct numeric; v_n int := 0; cfg public.pnl_cost_config%rowtype;
begin
  v_pct := public.pnl_slab_capture(p_order_id);
  select * into cfg from public.pnl_cost_config where id = 1;

  insert into public.pnl_alert (order_id, order_code, bill_line_id, product, qty,
                                cust_taxable, sup_taxable, margin, detail)
  select v.order_id, v.order_code, v.bill_line_id, v.product, v.qty,
         v.cust_taxable, v.sup_taxable, v.margin,
         jsonb_build_object('slab_pct', v.slab_pct, 'ptr', v.ptr,
                            'disc_pct', v.disc_pct, 'free_qty', v.free_qty,
                            'supplier', v.supplier_name)
    from public.pnl_line_v v
   where v.order_id = p_order_id and v.margin < 0
  on conflict (order_id, bill_line_id) do update
    set margin       = excluded.margin,
        cust_taxable = excluded.cust_taxable,
        sup_taxable  = excluded.sup_taxable,
        detail       = excluded.detail,
        created_at   = now(),
        seen_at      = null;

  get diagnostics v_n = row_count;

  if v_n > 0 and coalesce(cfg.negative_alert_enabled, true) then
    begin
      perform public.notify('pnl_negative_margin', cfg.negative_alert_phone,
        jsonb_build_object(
          'order_id', p_order_id::text,
          'audience', 'admin',
          'count',    v_n::text,
          'order',    coalesce((select order_code from public.orders where id = p_order_id), '')));
    exception when others then
      null;  -- a notification that cannot go out never becomes a billing fault
    end;
  end if;

  return jsonb_build_object('ok', true, 'slab_pct', v_pct, 'below_cost', v_n);
end $$;

revoke all on function public.pnl_bill_generated(uuid) from public, anon, authenticated;
grant execute on function public.pnl_bill_generated(uuid) to service_role;

-- The admin's manual re-scan of one order (same work, guarded).
create or replace function public.pnl_rescan_order(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized',
                              'message', public._pnl_c('ui.not_authorized'));
  end if;
  return public.pnl_bill_generated(p_order_id);
end $$;
revoke all on function public.pnl_rescan_order(uuid) from public, anon;
grant execute on function public.pnl_rescan_order(uuid) to authenticated, service_role;

-- The hook: a bill_jobs row IS bill generation. Hooking here rather than
-- inside customer_bill() keeps this file out of the invoice path entirely —
-- the composer cannot be slowed, broken or blocked by anything below.
create or replace function public._trg_pnl_bill_job()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.pnl_bill_generated(new.order_id);
  exception when others then
    null;  -- reporting is never allowed to stop a bill
  end;
  return new;
end $$;

drop trigger if exists trg_pnl_on_bill_job on public.bill_jobs;
create trigger trg_pnl_on_bill_job
  after insert on public.bill_jobs
  for each row execute function public._trg_pnl_bill_job();

-- ── 19. The two strings a screen needs BEFORE its first payload arrives ─────
-- Everything else on the P&L screen comes down in the payload. These two are
-- what it says when the payload never came, so they live in ui_copy, which the
-- app already has cached at boot.
insert into public.ui_copy (key, value) values
  ('pnl.error', '"Could not load the profit & loss figures."'::jsonb),
  ('pnl.retry', '"Retry"'::jsonb)
on conflict (key) do nothing;

-- The label on the admin dashboard's quick tile that reaches this screen.
insert into public.ui_copy (key, value) values
  ('admin_dashboard.quick_pnl', '"Profit & loss"'::jsonb)
on conflict (key) do nothing;
