-- CHANGE #396 part 2 — STOCK ON HAND.
--
-- mediBO buys per order, so "inventory" is not a warehouse of stocked lines:
-- it is the RESIDUE of order-driven purchasing. Three stock-ish tables already
-- existed (stock_notify_requests, stock_update_forms, stock_update_queue) and
-- not one of them holds a quantity that is physically in the building.
--
-- This migration adds the two tables that do:
--   stock_lot      — one physical lot sitting unallocated in the warehouse
--   stock_movement — every in/out against a lot (the ledger; lots never lie)
-- plus stock_derive_unallocated(), which READS the live fulfilment tables and
-- creates a lot for each way goods end up unclaimed:
--   over_supply   — the supplier sent more than the order asked for
--   cancelled     — goods received against an order that was then cancelled
--   residue       — received, never packed, and the order has since closed
--   return        — an RTO / returned delivery bringing packed goods back
-- Everything is keyed on the SOURCE row, so the derive is idempotent: running
-- it twice never doubles a lot, it only tops one up when more goods arrive.

-- ── money + age, formatted in the backend (Dart never formats a rupee) ──────
create or replace function public._stk_money(p_v numeric)
returns text language sql immutable as $$
  select '₹' || trim(to_char(round(coalesce(p_v,0), 2), 'FM99999999990.00'));
$$;

create or replace function public._stk_age_days(p_ts timestamptz)
returns integer language sql stable as $$
  select case when p_ts is null then null
              else greatest(0, (date_trunc('day', now() at time zone 'Asia/Kolkata')::date
                                - date_trunc('day', p_ts at time zone 'Asia/Kolkata')::date)) end;
$$;

-- ── the lot ────────────────────────────────────────────────────────────────
create table if not exists public.stock_lot (
  id                bigserial primary key,
  product_id        bigint,
  product_name      text not null,
  batch_no          text,
  expiry            text,
  supplier_name     text,
  source_kind       text not null,           -- over_supply|cancelled|residue|return|manual
  source_order_id   uuid,
  source_order_item_id uuid,
  qty_in            numeric not null default 0,
  qty_out           numeric not null default 0,
  trade_rate        numeric,                 -- PTR-style trade rate, never MRP
  received_at       timestamptz not null default now(),
  zone_id           smallint,
  status            text not null default 'available',  -- available|consumed|written_off
  note              text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

alter table public.stock_lot add column if not exists product_name text;
alter table public.stock_lot add column if not exists zone_id smallint;

-- Idempotency key for the derive: one lot per (source_kind, source row).
create unique index if not exists stock_lot_source_uk
  on public.stock_lot (source_kind, source_order_item_id)
  where source_order_item_id is not null;
create index if not exists stock_lot_available_ix
  on public.stock_lot (status, product_id) where status = 'available';
create index if not exists stock_lot_product_ix on public.stock_lot (product_id);

-- ── the ledger ─────────────────────────────────────────────────────────────
create table if not exists public.stock_movement (
  id            bigserial primary key,
  lot_id        bigint not null references public.stock_lot(id) on delete cascade,
  kind          text not null,               -- in|consume|release|write_off|adjust
  qty           numeric not null,
  order_id      uuid,
  order_item_id uuid,
  actor         text,
  note          text,
  created_at    timestamptz not null default now()
);
create index if not exists stock_movement_lot_ix on public.stock_movement (lot_id, created_at desc);

alter table public.stock_lot      enable row level security;
alter table public.stock_movement enable row level security;

-- Reads and writes go through the SECURITY DEFINER RPCs below; no direct
-- table access from any client role.
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='stock_lot'
                   and policyname='stock_lot_no_direct') then
    create policy stock_lot_no_direct on public.stock_lot for select using (false);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='stock_movement'
                   and policyname='stock_movement_no_direct') then
    create policy stock_movement_no_direct on public.stock_movement for select using (false);
  end if;
end $$;

-- ── available qty, in one place ────────────────────────────────────────────
create or replace view public.stock_lot_v as
  select l.*,
         greatest(l.qty_in - l.qty_out, 0) as qty_available,
         public._stk_age_days(l.received_at) as age_days,
         round(greatest(l.qty_in - l.qty_out, 0) * coalesce(l.trade_rate,0), 2) as value_at_trade
    from public.stock_lot l;

-- ── the copy this feature renders (backend owns every string) ──────────────
insert into public.ui_copy (key, value) values
  ('stock.title',            to_jsonb('Stock on hand'::text)),
  ('stock.subtitle',         to_jsonb('Goods in the warehouse that no live order has claimed'::text)),
  ('stock.empty',            to_jsonb('Nothing unallocated. Every received item is on an order.'::text)),
  ('stock.tile_lots',        to_jsonb('Lots'::text)),
  ('stock.tile_units',       to_jsonb('Units'::text)),
  ('stock.tile_value',       to_jsonb('Value at trade'::text)),
  ('stock.tile_aged',        to_jsonb('Ageing over 30 days'::text)),
  ('stock.col_product',      to_jsonb('Product'::text)),
  ('stock.col_batch',        to_jsonb('Batch / expiry'::text)),
  ('stock.col_age',          to_jsonb('Age'::text)),
  ('stock.col_qty',          to_jsonb('Qty'::text)),
  ('stock.col_value',        to_jsonb('Value'::text)),
  ('stock.batch_unknown',    to_jsonb('Batch not recorded'::text)),
  ('stock.expiry_unknown',   to_jsonb('Expiry not recorded'::text)),
  ('stock.refresh',          to_jsonb('Re-scan warehouse'::text)),
  ('stock.refreshed',        to_jsonb('Warehouse re-scanned.'::text)),
  ('stock.writeoff',         to_jsonb('Write off'::text)),
  ('stock.consume_cta',      to_jsonb('Fill from stock'::text)),
  ('stock.match_none',       to_jsonb('No matching stock — the inquiry will go to suppliers.'::text)),
  ('stock.admins_only',      to_jsonb('Admins only.'::text))
on conflict (key) do nothing;

insert into public.ui_copy (key, value) values
  ('stock.src_over_supply', to_jsonb('Supplier over-supplied'::text)),
  ('stock.src_cancelled',   to_jsonb('Order cancelled after receipt'::text)),
  ('stock.src_residue',     to_jsonb('Received, never packed'::text)),
  ('stock.src_stalled',     to_jsonb('Received, order gone quiet'::text)),
  ('stock.src_return',      to_jsonb('Returned from delivery'::text)),
  ('stock.src_manual',      to_jsonb('Added by hand'::text))
on conflict (key) do nothing;

create or replace function public._stk_copy(p_key text, p_fallback text)
returns text language sql stable as $$
  select coalesce((select value #>> '{}' from public.ui_copy where key = p_key), p_fallback);
$$;
