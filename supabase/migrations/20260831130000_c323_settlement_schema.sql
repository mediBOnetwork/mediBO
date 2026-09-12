-- ============================================================================
-- CHANGE #323 — Fulfilment mode per zone, editable per-order costs, and the
-- 50:50 partner profit settlement. Schema + seeds.
--
-- mediBO does not always fulfil. A zone is either SELF (mediBO's own team keeps
-- 100%) or PARTNER (a local house fulfils and takes an agreed share of what is
-- left after costs). Raipur is PARTNER = Jai Mahakal Medical And Surgical at
-- 50:50.
--
-- Four rules this file exists to hold down:
--
--   1. THE DEAL IS SNAPSHOTTED, NEVER READ BACK. Changing the split next month
--      must not rewrite last month's settlement, so mode, partner and split_pct
--      are stamped onto the order at bill time into order_fulfilment_snapshot
--      with `on conflict do nothing`, and every settlement reads the stamp.
--
--   2. A COST TYPE'S BASIS IS CHOSEN ONCE, FROM THE FRONTEND. Om, on this
--      command: "Cost of delivery will not always depend upon the km and box
--      qty... We will decide once and then it goes on." So basis is a field on
--      cost_types — flat / per_km / per_box / pct_of_order — that Om sets in
--      the UI and that then applies to every order until he changes it. flat is
--      the seeded basis for delivery and packaging. Adding a whole NEW cost
--      type is an INSERT from the same sheet, never a deploy.
--
--   3. EVERY COST LINE IS EDITABLE PER ORDER, AND THE COMPUTED VALUE SURVIVES.
--      order_costs keeps computed_amount AND override_amount side by side: the
--      override wins on the money, the computed figure stays visible beside it
--      so an edit is always readable as a deviation.
--
--   4. LOSSES NET OFF WITHIN THE PERIOD, NEVER PER ORDER. Om was explicit. A
--      single order may be under water; it is not settled on its own. The
--      per-order rows in partner_settlements are the DETAIL, and the split is
--      applied to the PERIOD TOTAL in partner_settlement_periods, so a negative
--      order simply pulls the period total down. A period that nets negative
--      transfers NOTHING and carries the negative into the next period as a
--      visible `brought_forward` line — the partner is never asked to pay back.
--
--   5. THE CADENCE IS A ZONE-LEVEL CHOICE, AND IT IS AUTOMATIC. same_day (the
--      default), t_plus_2 (a two-day holding window for returns and disputes),
--      weekly or monthly. Om picks it in the UI; the period row STORES the
--      cadence it was generated under, so changing the choice moves future
--      periods only and every printed statement stays reproducible. The
--      dispatcher task `settlement_close` (registered in cron_task — CHANGE
--      #305's single dispatcher, never a new pg_cron job) closes each due
--      period, writes the statement, and on the automatic Route lane queues the
--      transfer, with no manual step.
--
-- Every word this feature shows is a row in settlement_label; every rupee is
-- formatted by inr_money(). Re-wording the screen is an UPDATE.
-- Idempotent by construction (#233): re-running this file is a silent no-op.
-- ============================================================================

-- ── 1. The deal, per zone ───────────────────────────────────────────────────
-- split_pct is the PARTNER's share. mode='self' means mediBO keeps 100% and
-- split_pct is forced to 0 by the check, so a self zone can never leak a share
-- to a partner that is not there.
create table if not exists public.zone_fulfilment_mode (
  zone_id     smallint primary key references public.zones(id) on delete cascade,
  mode        text     not null default 'self',
  partner_id  bigint   references public.region_partners(id),
  split_pct   numeric  not null default 0,
  cadence     text     not null default 'same_day',
  note        text,
  updated_at  timestamptz not null default now(),
  updated_by  text,
  constraint zone_fulfilment_mode_mode_ck  check (mode in ('self','partner')),
  constraint zone_fulfilment_mode_split_ck check (split_pct >= 0 and split_pct <= 100),
  constraint zone_fulfilment_mode_cadence_ck check (cadence in ('same_day','t_plus_2','weekly','monthly')),
  constraint zone_fulfilment_mode_deal_ck  check (
    (mode = 'partner' and partner_id is not null)
    or (mode = 'self' and split_pct = 0)
  )
);

alter table public.zone_fulfilment_mode enable row level security;
drop policy if exists zone_fulfilment_mode_admin_all on public.zone_fulfilment_mode;
create policy zone_fulfilment_mode_admin_all on public.zone_fulfilment_mode
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists zone_fulfilment_mode_partner_read on public.zone_fulfilment_mode;
create policy zone_fulfilment_mode_partner_read on public.zone_fulfilment_mode
  for select to authenticated
  using (public.is_partner() and partner_id = public.my_partner_id());
revoke all on table public.zone_fulfilment_mode from public, anon;
grant select on table public.zone_fulfilment_mode to authenticated;
grant all on table public.zone_fulfilment_mode to service_role;

-- Every zone gets a row, defaulting to SELF — an unconfigured zone must never
-- silently settle money to somebody.
insert into public.zone_fulfilment_mode (zone_id, mode, split_pct)
select z.id, 'self', 0 from public.zones z
on conflict (zone_id) do nothing;

-- Raipur = partner, Jai Mahakal Medical And Surgical, 50:50. Matched by the
-- partner's own zone_id rather than a hardcoded id, so a reseeded database
-- lands on the right row.
update public.zone_fulfilment_mode m
   set mode = 'partner', partner_id = rp.id, split_pct = 50, updated_by = 'change-323'
  from public.region_partners rp
 where rp.zone_id = m.zone_id
   and coalesce(rp.is_active, true)
   and m.mode = 'self'
   and m.partner_id is null;

-- ── 2. What an order costs us, beyond the goods ─────────────────────────────
-- Fully frontend-managed. basis is the ONE decision Om makes per cost type and
-- it then applies to every order:
--   flat          amount            = base
--   per_km        amount            = base + rate x road km for the drop
--   per_box       amount            = base + rate x boxes the order was bagged into
--   pct_of_order  amount            = base + rate% of the order's taxable revenue
-- One formula, four drivers — see _stl_cost_amount().
create table if not exists public.cost_types (
  slug          text primary key,
  label         text not null,
  basis         text not null default 'flat',
  default_value numeric not null default 0,
  rate_value    numeric not null default 0,
  active        boolean not null default true,
  sort_order    int     not null default 100,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    text,
  constraint cost_types_basis_ck check (basis in ('flat','per_km','per_box','pct_of_order'))
);

alter table public.cost_types enable row level security;
drop policy if exists cost_types_admin_all on public.cost_types;
create policy cost_types_admin_all on public.cost_types
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists cost_types_partner_read on public.cost_types;
create policy cost_types_partner_read on public.cost_types
  for select to authenticated using (public.is_partner());
revoke all on table public.cost_types from public, anon;
grant select on table public.cost_types to authenticated;
grant all on table public.cost_types to service_role;

-- The four Om named. Rates seed at ZERO on purpose: inventing a rupee figure
-- here would fabricate settlement money nobody agreed to. Om sets them on the
-- cost-types sheet, and delivery/packaging start on `flat` per his correction.
insert into public.cost_types (slug, label, basis, default_value, rate_value, sort_order, note) values
  ('delivery',     'Delivery',               'flat',         0, 0, 10, 'One fixed amount per order. Switch to per-km to charge base + rate x the road distance the route builder computed.'),
  ('packaging',    'Packaging',              'flat',         0, 0, 20, 'One fixed amount per order. Switch to per-box to charge base + rate x the number of boxes the order was bagged into.'),
  ('platform_fee', 'Platform operation fee', 'pct_of_order', 0, 0, 30, 'A percentage of the order''s taxable value.'),
  ('marketing',    'Marketing',              'flat',         0, 0, 40, 'One fixed amount per order. Switch to a percentage if marketing is charged on order value.')
on conflict (slug) do nothing;

-- ── 3. The cost lines of one order ──────────────────────────────────────────
-- computed_amount is what the basis produced; override_amount is what a human
-- decided instead. Both are kept — the override wins the money, the computed
-- figure stays on screen beside it.
create table if not exists public.order_costs (
  id              bigserial primary key,
  order_id        uuid not null references public.orders(id) on delete cascade,
  cost_type       text not null references public.cost_types(slug) on delete cascade,
  computed_amount numeric not null default 0,
  override_amount numeric,
  source          text not null default 'auto',
  driver_value    numeric,
  driver_label    text,
  note            text,
  edited_by       text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint order_costs_source_ck check (source in ('auto','manual'))
);
create unique index if not exists order_costs_identity_uk
  on public.order_costs (order_id, cost_type);
create index if not exists order_costs_order_idx on public.order_costs (order_id);

alter table public.order_costs enable row level security;
drop policy if exists order_costs_admin_all on public.order_costs;
create policy order_costs_admin_all on public.order_costs
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on table public.order_costs from public, anon;
grant select on table public.order_costs to authenticated;
grant all on table public.order_costs to service_role;
grant usage, select on sequence public.order_costs_id_seq to service_role;

-- ── 4. THE SNAPSHOT ─────────────────────────────────────────────────────────
-- Stamped at bill time and never updated. `on conflict do nothing` is the whole
-- point: change the deal tomorrow and every already-billed order still settles
-- on the terms that were live when it was billed.
create table if not exists public.order_fulfilment_snapshot (
  order_id     uuid primary key references public.orders(id) on delete cascade,
  zone_id      smallint,
  mode         text not null,
  partner_id   bigint,
  partner_name text,
  split_pct    numeric not null default 0,
  source       text not null default 'bill',
  captured_at  timestamptz not null default now(),
  constraint order_fulfilment_snapshot_mode_ck check (mode in ('self','partner'))
);
create index if not exists order_fulfilment_snapshot_partner_idx
  on public.order_fulfilment_snapshot (partner_id);

alter table public.order_fulfilment_snapshot enable row level security;
drop policy if exists order_fulfilment_snapshot_admin_all on public.order_fulfilment_snapshot;
create policy order_fulfilment_snapshot_admin_all on public.order_fulfilment_snapshot
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists order_fulfilment_snapshot_partner_read on public.order_fulfilment_snapshot;
create policy order_fulfilment_snapshot_partner_read on public.order_fulfilment_snapshot
  for select to authenticated
  using (public.is_partner() and partner_id = public.my_partner_id());
revoke all on table public.order_fulfilment_snapshot from public, anon;
grant select on table public.order_fulfilment_snapshot to authenticated;
grant all on table public.order_fulfilment_snapshot to service_role;

-- ── 5. The period that is actually settled ──────────────────────────────────
-- The split is applied HERE, to the total, because a loss nets off across the
-- period rather than being settled on its own order. The identity carries
-- split_pct so that if the deal changed mid-period the two halves settle on
-- their own snapshotted terms instead of one of them being silently restated.
create table if not exists public.partner_settlement_periods (
  id             bigserial primary key,
  partner_id     bigint not null references public.region_partners(id) on delete cascade,
  zone_id        smallint,
  period_start   date not null,
  period_end     date not null,
  cadence        text not null default 'same_day',
  due_on         date not null,
  split_pct      numeric not null,
  orders_count   int     not null default 0,
  revenue        numeric not null default 0,
  goods_cost     numeric not null default 0,
  gross_margin   numeric not null default 0,
  cost_total     numeric not null default 0,
  distributable  numeric not null default 0,
  partner_share  numeric not null default 0,
  medibo_share   numeric not null default 0,
  brought_forward numeric not null default 0,
  net_due        numeric not null default 0,
  payable        numeric not null default 0,
  carry_forward  numeric not null default 0,
  status         text    not null default 'open',
  closed_at      timestamptz,
  settled_at     timestamptz,
  settled_by     text,
  computed_at    timestamptz not null default now(),
  constraint partner_settlement_periods_status_ck  check (status in ('open','due','settled')),
  constraint partner_settlement_periods_cadence_ck check (cadence in ('same_day','t_plus_2','weekly','monthly'))
);
create unique index if not exists partner_settlement_periods_identity_uk
  on public.partner_settlement_periods (partner_id, cadence, period_start, period_end, split_pct);
create index if not exists partner_settlement_periods_due_idx
  on public.partner_settlement_periods (status, due_on);

alter table public.partner_settlement_periods enable row level security;
drop policy if exists psp_admin_all on public.partner_settlement_periods;
create policy psp_admin_all on public.partner_settlement_periods
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists psp_partner_read on public.partner_settlement_periods;
create policy psp_partner_read on public.partner_settlement_periods
  for select to authenticated
  using (public.is_partner() and partner_id = public.my_partner_id());
revoke all on table public.partner_settlement_periods from public, anon;
grant select on table public.partner_settlement_periods to authenticated;
grant all on table public.partner_settlement_periods to service_role;
grant usage, select on sequence public.partner_settlement_periods_id_seq to service_role;

-- ── 6. One row per order — the detail behind the period ─────────────────────
-- partner_share/medibo_share here are the order's ARITHMETIC share, shown so a
-- statement can be read line by line. They are NOT what is paid: the money is
-- the period row above. A negative distributable is stored as it stands.
create table if not exists public.partner_settlements (
  id            bigserial primary key,
  order_id      uuid not null references public.orders(id) on delete cascade,
  period_id     bigint references public.partner_settlement_periods(id) on delete set null,
  partner_id    bigint,
  zone_id       smallint,
  order_code    text,
  order_date    date,
  mode          text not null default 'self',
  split_pct     numeric not null default 0,
  revenue       numeric not null default 0,
  goods_cost    numeric not null default 0,
  gross_margin  numeric not null default 0,
  cost_total    numeric not null default 0,
  distributable numeric not null default 0,
  partner_share numeric not null default 0,
  medibo_share  numeric not null default 0,
  computed_at   timestamptz not null default now()
);
create unique index if not exists partner_settlements_order_uk
  on public.partner_settlements (order_id);
create index if not exists partner_settlements_period_idx
  on public.partner_settlements (period_id);
create index if not exists partner_settlements_partner_date_idx
  on public.partner_settlements (partner_id, order_date);

alter table public.partner_settlements enable row level security;
drop policy if exists partner_settlements_admin_all on public.partner_settlements;
create policy partner_settlements_admin_all on public.partner_settlements
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists partner_settlements_partner_read on public.partner_settlements;
create policy partner_settlements_partner_read on public.partner_settlements
  for select to authenticated
  using (public.is_partner() and partner_id = public.my_partner_id());
revoke all on table public.partner_settlements from public, anon;
grant select on table public.partner_settlements to authenticated;
grant all on table public.partner_settlements to service_role;
grant usage, select on sequence public.partner_settlements_id_seq to service_role;

-- ── 7. What was actually moved ──────────────────────────────────────────────
-- ONE table for both Razorpay Route and a manual bank transfer, because the
-- statement must read the same either way: due, transferred, pending. An
-- automatic settlement writes a `queued` row carrying the transfer id once
-- Route reports it; a manual one writes a `paid` row carrying the reference the
-- operator typed. Pending is due minus the paid rows, in both modes.
create table if not exists public.partner_settlement_payments (
  id              bigserial primary key,
  period_id       bigint not null references public.partner_settlement_periods(id) on delete cascade,
  amount          numeric not null,
  method          text not null default 'manual',
  status          text not null default 'paid',
  rzp_transfer_id text,
  reference       text,
  note            text,
  paid_at         timestamptz not null default now(),
  recorded_by     text,
  constraint psp_pay_method_ck check (method in ('manual','razorpay_route')),
  constraint psp_pay_status_ck check (status in ('queued','paid','failed'))
);
create index if not exists psp_pay_period_idx on public.partner_settlement_payments (period_id);

alter table public.partner_settlement_payments enable row level security;
drop policy if exists psp_pay_admin_all on public.partner_settlement_payments;
create policy psp_pay_admin_all on public.partner_settlement_payments
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists psp_pay_partner_read on public.partner_settlement_payments;
create policy psp_pay_partner_read on public.partner_settlement_payments
  for select to authenticated
  using (public.is_partner() and exists (
    select 1 from public.partner_settlement_periods p
     where p.id = period_id and p.partner_id = public.my_partner_id()));
revoke all on table public.partner_settlement_payments from public, anon;
grant select on table public.partner_settlement_payments to authenticated;
grant all on table public.partner_settlement_payments to service_role;
grant usage, select on sequence public.partner_settlement_payments_id_seq to service_role;

-- ── 8. The one switch: how the partner is actually paid ─────────────────────
-- Seeded MANUAL. Razorpay Route moves real money to a linked account, so the
-- automatic lane is opt-in from the screen rather than the default a migration
-- silently turned on.
create table if not exists public.settlement_config (
  id                 smallint primary key default 1,
  route_mode         text    not null default 'manual',
  default_cadence    text    not null default 'same_day',
  auto_close         boolean not null default true,
  updated_at         timestamptz not null default now(),
  updated_by         text,
  constraint settlement_config_singleton_ck check (id = 1),
  constraint settlement_config_mode_ck  check (route_mode in ('manual','automatic')),
  constraint settlement_config_cadence_ck check (default_cadence in ('same_day','t_plus_2','weekly','monthly'))
);
insert into public.settlement_config (id) values (1) on conflict (id) do nothing;

alter table public.settlement_config enable row level security;
drop policy if exists settlement_config_admin_all on public.settlement_config;
create policy settlement_config_admin_all on public.settlement_config
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists settlement_config_partner_read on public.settlement_config;
create policy settlement_config_partner_read on public.settlement_config
  for select to authenticated using (public.is_partner());
revoke all on table public.settlement_config from public, anon;
grant select on table public.settlement_config to authenticated;
grant all on table public.settlement_config to service_role;

-- ── 9. Backend-owned copy ───────────────────────────────────────────────────
-- tone is a DESIGN TOKEN NAME (brand/success/warning/danger/info), never a hex.
create table if not exists public.settlement_label (
  key        text primary key,
  label      text not null,
  tone       text,
  sort_order int not null default 0
);
alter table public.settlement_label enable row level security;
drop policy if exists settlement_label_read on public.settlement_label;
create policy settlement_label_read on public.settlement_label
  for select to authenticated using (public.is_admin() or public.is_partner());
revoke all on table public.settlement_label from public, anon;
grant select on table public.settlement_label to authenticated;
grant all on table public.settlement_label to service_role;

insert into public.settlement_label (key, label, tone, sort_order) values
  ('ui.title',            'Partner settlement',                        null, 0),
  ('ui.subtitle',         'A zone is fulfilled by mediBO or by a partner. Profit is split on the period total after costs, so a loss-making order nets off instead of being settled on its own.', null, 0),
  ('ui.error',            'Could not load the settlement figures.',     'danger', 0),
  ('ui.retry',            'Retry',                                      null, 0),
  ('ui.not_authorized',   'Admins only.',                               'danger', 0),
  ('ui.partner_denied',   'This statement is not shared with your account.', 'danger', 0),
  ('ui.empty',            'Nothing to settle in this window yet. A period appears once an order in a partner zone has been billed.', null, 0),
  ('ui.footnote',         'Distributable profit is gross margin (GST excluded on both sides) minus every cost line on the order. The split is the one snapshotted on the order at bill time, so changing the deal never rewrites a past settlement.', null, 0),
  ('ui.refresh',          'Refresh',                                    null, 0),
  ('ui.range_days',       'Last %s days',                               null, 0),
  ('ui.recalculate',      'Recalculate',                                null, 0),
  ('ui.recalculated',     'Costs and settlements recalculated.',        'success', 0),
  ('ui.saved',            'Saved.',                                     'success', 0),
  ('ui.save',             'Save',                                       null, 0),
  ('ui.cancel',           'Cancel',                                     null, 0),
  ('ui.add_cost_type',    'Add a cost type',                            null, 0),

  ('tab.overview',        'Overview',                                   null, 1),
  ('tab.zones',           'Zones',                                      null, 2),
  ('tab.costs',           'Cost types',                                 null, 3),
  ('tab.periods',         'Periods',                                    null, 4),
  ('tab.orders',          'Orders',                                     null, 5),

  ('tile.revenue',        'Revenue (taxable)',                          null, 1),
  ('tile.goods',          'Cost of goods',                              null, 2),
  ('tile.gross',          'Gross margin',                               null, 3),
  ('tile.costs',          'Costs',                                      null, 4),
  ('tile.distributable',  'Distributable profit',                       'brand',   5),
  ('tile.medibo',         'mediBO share',                               null, 6),
  ('tile.partner',        'Partner share',                              null, 7),
  ('tile.due',            'Due to partner',                             null, 8),
  ('tile.transferred',    'Transferred',                                'success', 9),
  ('tile.pending',        'Pending',                                    'warning', 10),
  ('tile.orders',         'Orders settled',                             null, 11),

  ('sec.zones',           'Zones and their deal',                       null, 1),
  ('sec.costs',           'Cost types',                                 null, 2),
  ('sec.periods',         'Settlement periods',                         null, 3),
  ('sec.payments',        'Transfers',                                  null, 4),
  ('sec.orders',          'Orders in this period',                      null, 5),
  ('sec.cost_lines',      'Cost lines on this order',                   null, 6),

  ('mode.self',           'mediBO fulfils',                             null, 0),
  ('mode.partner',        'Partner fulfils',                            'brand', 0),
  ('mode.self_note',      '100% to mediBO.',                            null, 0),

  ('basis.flat',          'Flat per order',                             null, 1),
  ('basis.per_km',        'Base + per km',                              null, 2),
  ('basis.per_box',       'Base + per box',                             null, 3),
  ('basis.pct_of_order',  'Base + % of order value',                    null, 4),

  ('driver.flat',         'Flat',                                       null, 0),
  ('driver.per_km',       '%s km',                                      null, 0),
  ('driver.per_box',      '%s boxes',                                   null, 0),
  ('driver.pct_of_order', '%s of order value',                          null, 0),

  ('fld.mode',            'Fulfilment mode',                            null, 1),
  ('fld.partner',         'Partner',                                    null, 2),
  ('fld.split',           'Partner share %',                            null, 3),
  ('fld.label',           'Name',                                       null, 1),
  ('fld.slug',            'Key',                                        null, 2),
  ('fld.basis',           'How it is charged',                          null, 3),
  ('fld.base',            'Base amount (₹)',                            null, 4),
  ('fld.rate',            'Rate',                                       null, 5),
  ('fld.active',          'Active',                                     null, 6),
  ('fld.override',        'Override (₹)',                               null, 1),
  ('fld.note',            'Note',                                       null, 2),
  ('fld.amount',          'Amount (₹)',                                 null, 1),
  ('fld.reference',       'Reference / transfer id',                    null, 2),

  ('cost.computed',       'Computed',                                   null, 0),
  ('cost.override',       'Override',                                   'warning', 0),
  ('cost.clear',          'Use the computed amount',                    null, 0),
  ('cost.total',          'Total costs',                                null, 0),
  ('cost.empty',          'No cost lines on this order yet. Recalculate to build them from the active cost types.', null, 0),

  ('route.heading',       'How the partner is paid',                    null, 0),
  ('route.manual',        'Manual — mediBO transfers separately',       null, 1),
  ('route.automatic',     'Automatic — Razorpay Route splits at settlement', null, 2),
  ('route.manual_note',   'Record each transfer here after you send it. The statement shows due, transferred and pending exactly as it does on the automatic lane.', null, 0),
  ('route.automatic_note','Settling queues a Razorpay Route transfer for the partner''s linked account. It shows as pending until Route reports the transfer id.', null, 0),
  ('route.queued',        'Queued with Razorpay Route',                 'info', 0),
  ('route.record',        'Record a transfer',                          null, 0),
  ('route.recorded',      'Transfer recorded.',                         'success', 0),

  ('period.open',         'Open',                                       'info', 0),
  ('period.settled',      'Settled',                                    'success', 0),
  ('period.settle',       'Settle this period',                         null, 0),
  ('period.settled_msg',  'Period settled.',                            'success', 0),
  ('period.empty',        'No periods yet.',                            null, 0),
  ('period.loss_note',    'A period total below zero is carried, not paid — the loss nets off against the next period rather than being billed to the partner.', 'warning', 0),

  ('err.no_zone',         'That zone does not exist.',                  'danger', 0),
  ('err.no_partner',      'Pick a partner before switching the zone to partner fulfilment.', 'danger', 0),
  ('err.bad_split',       'The partner share must be between 0 and 100.', 'danger', 0),
  ('err.no_cost_type',    'That cost type does not exist.',             'danger', 0),
  ('err.slug_required',   'A key is required.',                         'danger', 0),
  ('err.label_required',  'A name is required.',                        'danger', 0),
  ('err.bad_basis',       'Pick how this cost is charged.',             'danger', 0),
  ('err.no_period',       'That settlement period does not exist.',     'danger', 0),
  ('err.no_order',        'That order does not exist.',                 'danger', 0),
  ('err.bad_amount',      'Enter an amount greater than zero.',         'danger', 0),

  ('cad.same_day',        'Same day',                                   null, 1),
  ('cad.t_plus_2',        'Two days after (T+2)',                       null, 2),
  ('cad.weekly',          'Weekly',                                     null, 3),
  ('cad.monthly',         'Monthly',                                    null, 4),
  ('cad.same_day_note',   'The day closes and the statement is written the same day.', null, 0),
  ('cad.t_plus_2_note',   'The statement is written two days after the day closes, leaving a window for returns and disputes.', null, 0),
  ('cad.weekly_note',     'Monday to Sunday, written when the week closes.', null, 0),
  ('cad.monthly_note',    'Calendar month, written when the month closes.', null, 0),
  ('fld.cadence',         'Settle every',                               null, 4),
  ('fld.route_mode',      'How the partner is paid',                    null, 5),
  ('fld.auto_close',      'Close and write statements automatically',   null, 6),

  ('tile.brought_forward','Brought forward',                            'warning', 12),
  ('tile.net_due',        'Net due',                                    null, 13),
  ('tile.carry_forward',  'Carried to next period',                     'warning', 14),
  ('row.brought_forward', 'Brought forward from the previous period',   'warning', 0),
  ('row.carry_forward',   'Carried into the next period',               'warning', 0),
  ('period.due',          'Due',                                        'warning', 0),
  ('period.due_on',       'Due on %s',                                  null, 0),
  ('period.window',       '%s to %s',                                   null, 0),
  ('period.negative',     'This period nets below zero, so nothing is transferred. The shortfall is carried into the next statement instead of being billed back.', 'warning', 0),
  ('period.auto_note',    'Statements are written automatically when the period closes.', null, 0),
  ('sec.month_rollup',    'Monthly rollup',                             null, 7),
  ('cost.frozen',         'This period is closed — cost lines on it can no longer be recomputed.', null, 0),
  ('cost.basis_note',     'Changing how a cost is charged applies to orders billed from now on. Orders already costed keep the figures they were billed with.', null, 0)
on conflict (key) do update
  set label = excluded.label, tone = excluded.tone, sort_order = excluded.sort_order;
