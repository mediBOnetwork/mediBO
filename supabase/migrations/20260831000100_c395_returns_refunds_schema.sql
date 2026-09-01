-- CHANGE #395 — Returns, refunds and cancellation.
-- Money could go out of mediBO but never came back: a prepaid order that was
-- cancelled or partly returned had no path into billing, GST or P&L. These are
-- the three record tables plus the reason registry every surface reads.
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ── The reason registry (max-backend: every label is a row, never a Dart string)
create table if not exists public.order_reason_option (
  scope          text    not null,   -- return | return_condition | cancel | refund
  code           text    not null,
  label          text    not null,
  sort           int     not null default 0,
  active         boolean not null default true,
  requires_photo boolean not null default false,
  auto_refund    boolean not null default false,
  tone           text,
  note           text,
  primary key (scope, code)
);

-- ── RETURNS. Line-level, deliberately the same shape as delivery_claims: the
-- bill composer already turns one claim row into one credit line, so a return
-- becomes a credit note through the SAME door rather than a parallel one.
create table if not exists public.order_returns (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid not null references public.orders(id) on delete cascade,
  order_item_id     uuid references public.order_items(id) on delete set null,
  product_id        bigint,
  product_name      text,
  qty               numeric not null,
  reason_code       text,
  condition_code    text,
  note              text,
  photo_path        text,
  status            text not null default 'pending',
  -- Frozen at approval from pnl_line_v — #318: a credit note is priced at the
  -- SAME slab the original bill used, never at today's ladder.
  slab_pct          numeric,
  ptr               numeric,
  gst_pct           numeric,
  credit_value      numeric,
  credit_disc       numeric,
  credit_taxable    numeric,
  credit_gst        numeric,
  credit_total      numeric,
  -- Linked, never duplicated: the supplier-side dispute matrix and the #309
  -- doorstep damage/short claim this return came from.
  dispute_id        uuid references public.supplier_disputes(id) on delete set null,
  delivery_claim_id uuid references public.delivery_claims(id) on delete set null,
  raised_by         uuid,
  raised_by_role    text,
  raised_at         timestamptz not null default now(),
  approved_by       uuid,
  approved_at       timestamptz,
  reject_reason     text,
  credited_at       timestamptz,
  created_at        timestamptz not null default now(),
  constraint order_returns_qty_pos check (qty > 0),
  constraint order_returns_status_ck
    check (status in ('pending','approved','rejected','credited','cancelled'))
);
create index if not exists order_returns_order_idx on public.order_returns(order_id);
create index if not exists order_returns_item_idx  on public.order_returns(order_item_id);
create index if not exists order_returns_status_idx on public.order_returns(status);

-- ── REFUNDS. Money actually leaving. provider_refund_id is unique so a
-- Razorpay webhook replay can never book the same refund twice.
create table if not exists public.refunds (
  id                  uuid primary key default gen_random_uuid(),
  order_id            uuid not null references public.orders(id) on delete cascade,
  amount              numeric not null,
  reason_code         text,
  note                text,
  method              text not null,              -- razorpay | manual_upi
  status              text not null default 'pending',
  provider_refund_id  text,
  provider_payment_id text,
  provider_status     text,
  provider_error      text,
  utr                 text,
  return_id           uuid references public.order_returns(id) on delete set null,
  cancellation_id     uuid,
  requested_by        uuid,
  requested_at        timestamptz not null default now(),
  approved_by         uuid,
  approved_at         timestamptz,
  processed_at        timestamptz,
  created_at          timestamptz not null default now(),
  constraint refunds_amount_pos check (amount > 0),
  constraint refunds_method_ck  check (method in ('razorpay','manual_upi')),
  constraint refunds_status_ck
    check (status in ('pending','processing','processed','failed','cancelled'))
);
create index if not exists refunds_order_idx  on public.refunds(order_id);
create index if not exists refunds_status_idx on public.refunds(status);
create unique index if not exists refunds_provider_refund_uk
  on public.refunds(provider_refund_id) where provider_refund_id is not null;

-- ── CANCELLATION. One per order; the reason is a code, never free text.
create table if not exists public.order_cancellations (
  id                 uuid primary key default gen_random_uuid(),
  order_id           uuid not null references public.orders(id) on delete cascade,
  reason_code        text not null,
  note               text,
  cancelled_by       uuid,
  cancelled_by_role  text,
  cancelled_at       timestamptz not null default now(),
  released_items     int not null default 0,
  released_inquiries int not null default 0,
  refund_id          uuid references public.refunds(id) on delete set null,
  refund_amount      numeric not null default 0,
  created_at         timestamptz not null default now()
);
create unique index if not exists order_cancellations_order_uk
  on public.order_cancellations(order_id);

do $$ begin
  alter table public.refunds
    add constraint refunds_cancellation_fk
    foreign key (cancellation_id) references public.order_cancellations(id) on delete set null;
exception when duplicate_object then null; end $$;

-- ── RLS. Writes go ONLY through the SECURITY DEFINER RPCs below; these
-- policies are read paths, copied from delivery_claims so a customer sees the
-- credit note and the refund on their own order and nothing else.
alter table public.order_returns        enable row level security;
alter table public.refunds              enable row level security;
alter table public.order_cancellations  enable row level security;
alter table public.order_reason_option  enable row level security;

drop policy if exists order_returns_read on public.order_returns;
create policy order_returns_read on public.order_returns for select to authenticated
  using (public.is_admin() or exists (
    select 1 from public.orders o join public.pharmacy_profiles pp on pp.id = o.customer_id
     where o.id = order_returns.order_id and pp.user_id = auth.uid()));

drop policy if exists refunds_read on public.refunds;
create policy refunds_read on public.refunds for select to authenticated
  using (public.is_admin() or exists (
    select 1 from public.orders o join public.pharmacy_profiles pp on pp.id = o.customer_id
     where o.id = refunds.order_id and pp.user_id = auth.uid()));

drop policy if exists order_cancellations_read on public.order_cancellations;
create policy order_cancellations_read on public.order_cancellations for select to authenticated
  using (public.is_admin() or exists (
    select 1 from public.orders o join public.pharmacy_profiles pp on pp.id = o.customer_id
     where o.id = order_cancellations.order_id and pp.user_id = auth.uid()));

drop policy if exists order_reason_option_read on public.order_reason_option;
create policy order_reason_option_read on public.order_reason_option for select to authenticated
  using (true);

-- ── Reason seeds. The four cancellation reasons the spec names, plus the
-- return reasons and conditions. auto_refund marks the reasons that must
-- refund a paid order without an operator remembering to.
insert into public.order_reason_option (scope, code, label, sort, requires_photo, auto_refund, tone) values
  ('cancel','out_of_stock',       'Out of stock',        10, false, true,  'warning'),
  ('cancel','customer_cancelled', 'Customer cancelled',  20, false, true,  'info'),
  ('cancel','payment_failed',     'Payment failed',      30, false, false, 'danger'),
  ('cancel','duplicate',          'Duplicate order',     40, false, true,  'info'),
  ('return','damaged',            'Damaged in transit',  10, true,  false, 'danger'),
  ('return','short',              'Short supplied',      20, false, false, 'warning'),
  ('return','wrong_product',      'Wrong product',       30, true,  false, 'danger'),
  ('return','expired',            'Expired / near expiry',40,true,  false, 'danger'),
  ('return','not_ordered',        'Not ordered',         50, false, false, 'info'),
  ('return','quality',            'Quality complaint',   60, true,  false, 'warning'),
  ('return_condition','sealed',   'Sealed / resaleable', 10, false, false, 'success'),
  ('return_condition','opened',   'Opened',              20, false, false, 'warning'),
  ('return_condition','damaged',  'Damaged',             30, false, false, 'danger'),
  ('return_condition','expired',  'Expired',             40, false, false, 'danger'),
  ('refund','return_credit',      'Return credit',       10, false, false, 'info'),
  ('refund','order_cancelled',    'Order cancelled',     20, false, false, 'info'),
  ('refund','overpayment',        'Overpayment',         30, false, false, 'info'),
  ('refund','goodwill',           'Goodwill',            40, false, false, 'info')
on conflict (scope, code) do nothing;

-- ── AUDIT TRAIL. The generic row auditor already exists; these three tables
-- just have to be registered and wired, so every insert/update lands in
-- audit_log with the actor, exactly like orders and payment_claims.
insert into public.audit_table_config (table_name, entity_type, pk_col, label, skip_cols, is_active) values
  ('order_returns',       'order_return',  'id', 'Return',           '{}', true),
  ('refunds',             'refund',        'id', 'Refund',           '{}', true),
  ('order_cancellations', 'order_cancel',  'id', 'Order cancellation','{}', true),
  ('order_reason_option', 'reason_option', 'code','Reason option',   '{}', true)
on conflict (table_name) do update
  set entity_type = excluded.entity_type, pk_col = excluded.pk_col,
      label = excluded.label, is_active = excluded.is_active;

drop trigger if exists zz_audit_row on public.order_returns;
create trigger zz_audit_row after insert or update or delete on public.order_returns
  for each row execute function public.audit_row_trg();
drop trigger if exists zz_audit_row on public.refunds;
create trigger zz_audit_row after insert or update or delete on public.refunds
  for each row execute function public.audit_row_trg();
drop trigger if exists zz_audit_row on public.order_cancellations;
create trigger zz_audit_row after insert or update or delete on public.order_cancellations
  for each row execute function public.audit_row_trg();
drop trigger if exists zz_audit_row on public.order_reason_option;
create trigger zz_audit_row after insert or update or delete on public.order_reason_option
  for each row execute function public.audit_row_trg();
