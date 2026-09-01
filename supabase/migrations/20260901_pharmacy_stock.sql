-- CMD #412 — Pharmacy auto-inventory: shelf stock that builds itself.
--
-- WHY THIS SHAPE. Every standalone pharmacy inventory app in India dies the same
-- death: somebody has to type the opening stock and then keep typing every
-- purchase, forever. Nobody does, the numbers drift, and the app is abandoned
-- inside a month. mediBO already KNOWS what it delivered to this pharmacy — the
-- product, the quantity, the batch, the expiry and the rate it was billed at —
-- so the shelf builds itself from the purchase side and only the exceptions are
-- typed. That is the whole design.
--
-- FOUR WAYS A LOT IS BORN, exactly one of which is automatic:
--   1. medibo_order  — a delivered mediBO order. Automatic. The trigger on
--      `deliveries` fires the instant a rider's proof lands.
--   2. opening       — the register they already keep, brought in ONCE, by CSV
--      or by photographing the pages (gemini OCR, verbatim, reviewed before it
--      is applied — the camera is not a database).
--   3. outside       — a purchase from a local distributor, typed.
--   4. adjustment    — damage, expiry, a count correction. Never silent: every
--      one carries a reason and the auth user who did it.
--
-- FEFO, NOT FIFO. Medicine is dated goods; the batch that expires first must
-- leave first or it is written off. A POS sale (#411) is consumed off
-- `pos_sale_event` by expiry order, and a batch the cashier picked by hand wins
-- over the FEFO guess because they are holding the strip.
--
-- NEGATIVE STOCK IS ALLOWED AND SHOUTED ABOUT. A pharmacy that cannot bill
-- because "the system says zero" turns the system off. So the sale always goes
-- through; the shortfall becomes a negative lot, badged loudly on the stock
-- screen. Negative stock is not an error, it is the discovery that something was
-- on the shelf the system never knew about — which is precisely the list they
-- need to fix. Trust is built by being useful first and right second.
--
-- THIS TABLE IS A SUBSTRATE, not a screen. Expiry alerts (#413/#425), auto
-- reorder, the margin finder, the theft radar and the near-expiry exchange
-- (#223) all read it, so the keys are chosen for them, not for this screen:
--   * (pharmacy_id, item_key, batch_key, expiry_key) is unique — a lot is
--     addressable without a join, from any of those features.
--   * expiry_on is a real DATE parsed out of whatever the pack printed, so
--     "what expires in 90 days" is an index scan, not a string parse per row.
--   * every movement is a row in pharmacy_stock_move with an actor — the theft
--     radar is a query over that ledger, not a new pipeline.
--
-- Idempotent throughout: a resumed worker, a re-fired trigger and a re-delivered
-- order all land as no-ops.

-- ─────────────────────────── 1. ORDER LINE BATCH/EXPIRY ─────────────────────
-- #129 owns putting batch/expiry ON the supplier bill line. Until it lands the
-- columns simply do not exist, and this command cannot consume what is not
-- there. They are added here, nullable, so #129's own `add column if not
-- exists` is a no-op and the intake below reads one place forever. Until they
-- are populated the intake falls back to the warehouse lot the line was picked
-- from (`order_items.stock_lot_id` -> `stock_lot`), which already carries the
-- batch and expiry the goods physically arrived with.
alter table public.order_items add column if not exists batch_no text;
alter table public.order_items add column if not exists expiry   text;

comment on column public.order_items.batch_no is
  'Batch printed on the pack that filled this line. #129 fills it from the supplier bill; #412 reads it into pharmacy shelf stock.';
comment on column public.order_items.expiry is
  'Expiry printed on the pack, verbatim (MM/YY as printed). #412 parses it to a date for the expiry radar.';

-- ─────────────────────────── 2. HELPERS ─────────────────────────────────────

-- Expiry as printed -> the last day of that month. A pack says "09/27" and it
-- is good to the END of September. Accepts MM/YY, MM/YYYY, MM-YY, YYYY-MM,
-- MMYY and a full date; anything it cannot read is NULL, which sorts last in
-- FEFO instead of pretending to be urgent.
create or replace function public._phs_expiry_on(p text)
returns date language plpgsql immutable as $$
declare
  s text := upper(btrim(coalesce(p,'')));
  mm int; yy int; m text[];
begin
  if s = '' then return null; end if;

  -- YYYY-MM or YYYY/MM
  m := regexp_match(s, '^(\d{4})[-/](\d{1,2})$');
  if m is not null then yy := m[1]::int; mm := m[2]::int;
  else
    -- MM/YY, MM-YY, MM.YY, MM/YYYY
    m := regexp_match(s, '^(\d{1,2})[-/. ](\d{2}|\d{4})$');
    if m is not null then
      mm := m[1]::int;
      yy := m[2]::int;
      if yy < 100 then yy := 2000 + yy; end if;
    else
      -- MMYY / MMYYYY with no separator
      m := regexp_match(s, '^(\d{2})(\d{2}|\d{4})$');
      if m is not null then
        mm := m[1]::int;
        yy := m[2]::int;
        if yy < 100 then yy := 2000 + yy; end if;
      else
        -- a full ISO date
        begin
          return (date_trunc('month', s::date) + interval '1 month - 1 day')::date;
        exception when others then
          return null;
        end;
      end if;
    end if;
  end if;

  if mm is null or mm < 1 or mm > 12 or yy < 2000 or yy > 2100 then return null; end if;
  return (make_date(yy, mm, 1) + interval '1 month - 1 day')::date;
end $$;

-- Quantity as a number, never a surprise. Blank/garbage is 0, not an exception.
create or replace function public._phs_num(p text)
returns numeric language sql immutable as $$
  select coalesce(nullif(regexp_replace(coalesce(p,''), '[^0-9.\-]', '', 'g'), '')::numeric, 0);
$$;

create or replace function public._phs_shop()
returns uuid language sql stable as $$ select public.my_customer_id(); $$;

create or replace function public._phs_denied()
returns jsonb language sql stable as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('phstock.err_not_pharmacy'));
$$;

create or replace function public._phs_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

-- Money is formatted HERE. Dart never sees a bare number it has to make a
-- rupee string out of. inr_money() is the platform's lakh-grouped formatter.
create or replace function public._phs_money(p numeric)
returns text language sql immutable as $$ select public.inr_money(coalesce(p,0)); $$;

-- Quantities print without a trailing '.00' on a whole number but keep a real
-- fraction (half a bottle is a real thing). CMD #407's lesson: to_char with an
-- FM mask leaves a naked '18.' behind — trim_scale + ::text does not.
create or replace function public._phs_qty(p numeric)
returns text language sql immutable as $$
  select trim_scale(round(coalesce(p,0), 3))::text;
$$;

-- ─────────────────────────── 3. TABLES ──────────────────────────────────────

-- One row per (pharmacy, item, batch, expiry). NOT one row per purchase: two
-- deliveries of the same batch are the same physical pile on the shelf, so they
-- merge and the cost becomes the weighted average of what was actually paid.
-- The purchase history is not lost — it is every receipt row in
-- pharmacy_stock_move, which is where the margin finder reads it from.
create table if not exists public.pharmacy_stock (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,

  -- The catalogue id when mediBO knows the product, NULL for something they
  -- bought locally that is not in the catalogue. item_key is the join key every
  -- downstream feature groups on, and it works in both cases.
  medicine_id    bigint,
  product_name   text not null,
  pack_label     text,
  item_key       text not null,

  batch_no       text,
  expiry         text,                       -- verbatim, as printed on the pack
  expiry_on      date,                       -- parsed month-end; NULL sorts last

  qty            numeric not null default 0, -- on hand. MAY be negative, on purpose.
  unit_cost      numeric,                    -- weighted average, INR, ex-GST
  mrp            numeric,

  source_kind    text not null default 'medibo_order'
                 check (source_kind in ('medibo_order','opening','outside','adjustment')),
  supplier_label text,
  first_order_id uuid,
  received_on    date,

  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  -- Normalised shadows so the uniqueness holds with NULLs in it. '~' is the
  -- "no batch printed" bucket: one lot per item for goods that arrived without
  -- a batch on the bill, rather than a new lot every single delivery.
  batch_key      text generated always as
                   (upper(coalesce(nullif(btrim(batch_no), ''), '~'))) stored,
  expiry_key     text generated always as
                   (coalesce(nullif(btrim(expiry), ''), '~')) stored
);

create unique index if not exists pharmacy_stock_lot_uidx
  on public.pharmacy_stock (pharmacy_id, item_key, batch_key, expiry_key);

-- FEFO reads this one every sale: the open lots of one item, earliest expiry
-- first. Partial on qty <> 0 so the dead lots never widen it.
create index if not exists pharmacy_stock_fefo_idx
  on public.pharmacy_stock (pharmacy_id, item_key, expiry_on nulls last, created_at)
  where qty <> 0;

-- The expiry radar's index (#413/#425): "what expires before <date>".
create index if not exists pharmacy_stock_expiry_idx
  on public.pharmacy_stock (pharmacy_id, expiry_on)
  where qty > 0;

create index if not exists pharmacy_stock_shop_idx
  on public.pharmacy_stock (pharmacy_id, product_name);

comment on table public.pharmacy_stock is
  'CMD #412 — a pharmacy''s own shelf stock, one row per item+batch+expiry. Built automatically from delivered mediBO orders; the substrate for expiry alerts, auto-reorder, margin finder, theft radar and the near-expiry exchange.';

-- Every single change, with a name against it. This is the audit the adjustment
-- rule demands and the ledger the theft radar is a query over.
create table if not exists public.pharmacy_stock_move (
  id             bigserial primary key,
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  stock_id       uuid references public.pharmacy_stock(id) on delete set null,
  item_key       text,

  kind           text not null
                 check (kind in ('receipt_order','receipt_outside','opening',
                                 'sale','sale_void','adjust')),
  qty_delta      numeric not null,           -- signed: +in, -out
  qty_after      numeric,
  unit_cost      numeric,

  reason_code    text,                       -- adjustments only
  note           text,

  actor_user_id  uuid,
  actor_label    text,

  -- What caused it. (ref_kind, ref_id) is UNIQUE, which is the whole
  -- idempotency story: a re-fired delivery trigger, a resumed import and a
  -- replayed POS sale all collide here and write nothing the second time.
  ref_kind       text,
  ref_id         text,

  created_at     timestamptz not null default now()
);

create unique index if not exists pharmacy_stock_move_ref_uidx
  on public.pharmacy_stock_move (ref_kind, ref_id)
  where ref_kind is not null and ref_id is not null;

create index if not exists pharmacy_stock_move_stock_idx
  on public.pharmacy_stock_move (stock_id, created_at desc);

create index if not exists pharmacy_stock_move_shop_idx
  on public.pharmacy_stock_move (pharmacy_id, created_at desc);

-- Adjustment reasons are DATA. A new reason is one INSERT, never a deploy, and
-- the screen renders whatever this table says in this order.
create table if not exists public.pharmacy_stock_reason (
  code       text primary key,
  label      text not null,
  direction  text not null default 'both' check (direction in ('down','up','both')),
  sort       integer not null default 100,
  is_active  boolean not null default true
);

insert into public.pharmacy_stock_reason (code, label, direction, sort) values
  ('damage',           'Damaged / broken',        'down', 10),
  ('expired',          'Expired — written off',   'down', 20),
  ('count_correction', 'Count correction',        'both', 30),
  ('shortage',         'Missing / not on shelf',  'down', 40),
  ('return_supplier',  'Returned to supplier',    'down', 50),
  ('found',            'Found on shelf',          'up',   60),
  ('free_sample',      'Free / sample received',  'up',   70)
on conflict (code) do nothing;

-- Opening stock arrives in a BATCH that is reviewed before it is believed. The
-- camera is not a database: OCR fills a draft, a human confirms it, and only
-- then does it touch the shelf.
create table if not exists public.pharmacy_stock_import (
  id           uuid primary key default gen_random_uuid(),
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  kind         text not null check (kind in ('csv','photo')),
  status       text not null default 'draft'
               check (status in ('draft','scanning','ready','applied','failed','discarded')),
  bucket       text,
  path         text,
  ocr_error    text,
  rows_total   integer not null default 0,
  rows_applied integer not null default 0,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  applied_at   timestamptz
);

create index if not exists pharmacy_stock_import_shop_idx
  on public.pharmacy_stock_import (pharmacy_id, created_at desc);

create table if not exists public.pharmacy_stock_import_row (
  id           uuid primary key default gen_random_uuid(),
  import_id    uuid not null references public.pharmacy_stock_import(id) on delete cascade,
  line_no      integer not null,
  raw          jsonb,                        -- exactly what the CSV/OCR said
  medicine_id  bigint,
  product_name text,
  pack_label   text,
  batch_no     text,
  expiry       text,
  qty          numeric,
  unit_cost    numeric,
  mrp          numeric,
  match_status text not null default 'unmatched'
               check (match_status in ('matched','unmatched','off_catalog')),
  keep         boolean not null default true,
  created_at   timestamptz not null default now()
);

create index if not exists pharmacy_stock_import_row_idx
  on public.pharmacy_stock_import_row (import_id, line_no);

-- Per-shop thresholds. One row, created on demand, so the badges are the
-- pharmacy's own definition of "low" rather than a number baked into Dart.
create table if not exists public.pharmacy_stock_settings (
  pharmacy_id      uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  low_qty          numeric not null default 5,
  near_expiry_days integer not null default 90,
  updated_at       timestamptz not null default now()
);

-- No policies on purpose: RLS on with none written denies every direct table
-- read, and every caller path below is SECURITY DEFINER and scoped to
-- my_customer_id(). Same fence the POS layer stands behind.
alter table public.pharmacy_stock             enable row level security;
alter table public.pharmacy_stock_move        enable row level security;
alter table public.pharmacy_stock_reason      enable row level security;
alter table public.pharmacy_stock_import      enable row level security;
alter table public.pharmacy_stock_import_row  enable row level security;
alter table public.pharmacy_stock_settings    enable row level security;

-- ─────────────────────────── 4. THE WRITE ENGINE ────────────────────────────

-- The grouping key every downstream feature joins on. A catalogue product is
-- addressed by its id; something they bought locally is addressed by its
-- normalised name, so renaming the label does not fork the pile.
create or replace function public._phs_item_key(p_medicine_id bigint, p_name text)
returns text language sql immutable as $$
  select case
    when p_medicine_id is not null then 'm:' || p_medicine_id::text
    else 'n:' || public._norm_name(coalesce(p_name, ''))
  end;
$$;

create or replace function public._phs_settings(p_shop uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'low_qty',          coalesce(s.low_qty, 5),
    'near_expiry_days', coalesce(s.near_expiry_days, 90))
  from (select 1) one
  left join public.pharmacy_stock_settings s on s.pharmacy_id = p_shop;
$$;

-- Whoever is holding the phone. Falls back to the shop's own name for a
-- machine-made movement (the delivery trigger runs with no auth.uid()).
create or replace function public._phs_actor_label(p_shop uuid)
returns text language sql stable as $$
  select coalesce(
    (select nullif(btrim(coalesce(pp.owner_name, pp.customer_name, '')), '')
       from public.pharmacy_profiles pp where pp.id = p_shop),
    (select pp.pharmacy_name from public.pharmacy_profiles pp where pp.id = p_shop),
    '');
$$;

-- ONE door into the shelf. Everything — a delivery, an import, a typed
-- purchase, a sale, an adjustment — goes through here, so there is exactly one
-- place that can get the weighted average, the audit row or the idempotency
-- wrong. Returns the lot id.
--
-- p_ref_kind/p_ref_id are the idempotency handle: pass them and a second call
-- with the same pair writes NOTHING and returns the lot it already wrote to.
create or replace function public._phs_apply(
  p_shop        uuid,
  p_medicine_id bigint,
  p_name        text,
  p_pack        text,
  p_batch       text,
  p_expiry      text,
  p_qty_delta   numeric,          -- signed
  p_unit_cost   numeric,
  p_mrp         numeric,
  p_kind        text,             -- pharmacy_stock_move.kind
  p_source_kind text,             -- pharmacy_stock.source_kind for a NEW lot
  p_reason      text default null,
  p_note        text default null,
  p_ref_kind    text default null,
  p_ref_id      text default null,
  p_supplier    text default null,
  p_order_id    uuid default null,
  p_received_on date default null,
  p_actor       uuid default null,
  p_lot_id      uuid default null  -- deduct from THIS lot, skipping the match
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_item   text := public._phs_item_key(p_medicine_id, p_name);
  v_batch  text := nullif(btrim(coalesce(p_batch,'')), '');
  v_exp    text := nullif(btrim(coalesce(p_expiry,'')), '');
  v_lot    public.pharmacy_stock%rowtype;
  v_id     uuid;
  v_after  numeric;
  v_cost   numeric;
  v_name   text := nullif(btrim(coalesce(p_name,'')), '');
begin
  if p_shop is null then return null; end if;
  if coalesce(p_qty_delta, 0) = 0 and p_lot_id is null then return null; end if;

  -- Already applied? Answer with the lot it hit and write nothing. This is what
  -- makes the delivery trigger, the POS consumer and a resumed import safe to
  -- re-run any number of times.
  if p_ref_kind is not null and p_ref_id is not null then
    select stock_id into v_id from public.pharmacy_stock_move
     where ref_kind = p_ref_kind and ref_id = p_ref_id;
    if found then return v_id; end if;
  end if;

  if p_lot_id is not null then
    select * into v_lot from public.pharmacy_stock where id = p_lot_id and pharmacy_id = p_shop;
    if not found then return null; end if;
  else
    select * into v_lot from public.pharmacy_stock
     where pharmacy_id = p_shop
       and item_key    = v_item
       and batch_key   = upper(coalesce(v_batch, '~'))
       and expiry_key  = coalesce(v_exp, '~');
  end if;

  if v_lot.id is null then
    insert into public.pharmacy_stock(
      pharmacy_id, medicine_id, product_name, pack_label, item_key,
      batch_no, expiry, expiry_on, qty, unit_cost, mrp,
      source_kind, supplier_label, first_order_id, received_on)
    values (
      p_shop, p_medicine_id, coalesce(v_name, '—'), nullif(btrim(coalesce(p_pack,'')),''), v_item,
      v_batch, v_exp, public._phs_expiry_on(v_exp),
      p_qty_delta,
      case when p_qty_delta > 0 then p_unit_cost else null end,
      p_mrp,
      coalesce(p_source_kind, 'outside'),
      nullif(btrim(coalesce(p_supplier,'')),''), p_order_id,
      coalesce(p_received_on, public._phs_today()))
    on conflict (pharmacy_id, item_key, batch_key, expiry_key) do update
      set qty = public.pharmacy_stock.qty + excluded.qty,
          updated_at = now()
    returning id, qty into v_id, v_after;
  else
    -- Weighted average cost, and only goods COMING IN move it. A sale or a
    -- write-off leaves the cost of what is left exactly where it was.
    v_cost := v_lot.unit_cost;
    if p_qty_delta > 0 and p_unit_cost is not null then
      if v_lot.unit_cost is null or v_lot.qty <= 0 then
        v_cost := p_unit_cost;
      else
        v_cost := round(
          ((v_lot.unit_cost * v_lot.qty) + (p_unit_cost * p_qty_delta))
          / nullif(v_lot.qty + p_qty_delta, 0), 4);
      end if;
    end if;

    update public.pharmacy_stock
       set qty         = qty + p_qty_delta,
           unit_cost   = coalesce(v_cost, unit_cost),
           mrp         = coalesce(p_mrp, mrp),
           pack_label  = coalesce(pack_label, nullif(btrim(coalesce(p_pack,'')),'')),
           supplier_label = coalesce(nullif(btrim(coalesce(p_supplier,'')),''), supplier_label),
           expiry_on   = coalesce(expiry_on, public._phs_expiry_on(expiry)),
           updated_at  = now()
     where id = v_lot.id
    returning id, qty into v_id, v_after;
  end if;

  insert into public.pharmacy_stock_move(
    pharmacy_id, stock_id, item_key, kind, qty_delta, qty_after, unit_cost,
    reason_code, note, actor_user_id, actor_label, ref_kind, ref_id)
  values (
    p_shop, v_id, v_item, p_kind, p_qty_delta, v_after,
    coalesce(p_unit_cost, (select unit_cost from public.pharmacy_stock where id = v_id)),
    p_reason, p_note,
    coalesce(p_actor, auth.uid()),
    coalesce(nullif(btrim(coalesce(p_supplier,'')),''), public._phs_actor_label(p_shop)),
    p_ref_kind, p_ref_id)
  on conflict do nothing;

  return v_id;
end $$;

-- ─────────────────────────── 5. INTAKE: A DELIVERED ORDER ───────────────────
--
-- The zero-data-entry half. When a rider's proof lands on `deliveries`, every
-- line of that order becomes shelf stock for the pharmacy that ordered it.
--
-- Batch and expiry come from the bill line (#129's columns) and fall back to
-- the warehouse lot the goods were physically picked from — `stock_lot` already
-- records the batch and expiry that arrived from the supplier. Where neither
-- knows, the lot is created with no batch and the screen says so out loud
-- rather than inventing one.
--
-- Cost is `order_items.price`: the PTR-style trade rate the pharmacy was billed
-- at, ex-GST, exactly as legal_get_page('about') defines B2B pricing. MRP is
-- carried across as the retail reference the POS counter sells at — it is NOT
-- the cost and is never used as one.
create or replace function public.pharmacy_stock_ingest_order(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop  uuid;
  v_date  date;
  v_it    record;
  v_qty   numeric;
  v_n     integer := 0;
  v_lot   uuid;
begin
  select o.customer_id, coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date)
    into v_shop, v_date
    from public.orders o where o.id = p_order_id;

  -- An order placed by an account that is not a pharmacy profile has no shelf
  -- to land on. Not an error — there is simply nothing to do.
  if v_shop is null then
    return jsonb_build_object('ok', true, 'skipped', 'no_pharmacy', 'lots', 0);
  end if;

  for v_it in
    select oi.id, oi.product_id, oi.product_name, oi.quantity, oi.received_qty,
           oi.packed_qty, oi.price, oi.mrp, oi.batch_no, oi.expiry,
           oi.stock_lot_id, oi.assigned_supplier,
           sl.batch_no as lot_batch, sl.expiry as lot_expiry,
           sl.supplier_name as lot_supplier,
           m.pack_size, m.pack_type
      from public.order_items oi
      left join public.stock_lot sl on sl.id = oi.stock_lot_id
      left join public."MEDICINE" m on m.id = oi.product_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable, false) = false
  loop
    -- What actually went in the bag, in priority order: what Pack counted,
    -- else what the warehouse received, else what was ordered.
    v_qty := coalesce(nullif(v_it.packed_qty, 0),
                      nullif(v_it.received_qty, 0),
                      v_it.quantity, 0);
    if coalesce(v_qty, 0) <= 0 then continue; end if;

    v_lot := public._phs_apply(
      p_shop        => v_shop,
      p_medicine_id => v_it.product_id,
      p_name        => v_it.product_name,
      p_pack        => nullif(btrim(coalesce(v_it.pack_size, v_it.pack_type, '')), ''),
      p_batch       => coalesce(nullif(btrim(coalesce(v_it.batch_no,'')),''), v_it.lot_batch),
      p_expiry      => coalesce(nullif(btrim(coalesce(v_it.expiry,'')),''),  v_it.lot_expiry),
      p_qty_delta   => v_qty,
      p_unit_cost   => v_it.price,
      p_mrp         => v_it.mrp,
      p_kind        => 'receipt_order',
      p_source_kind => 'medibo_order',
      p_ref_kind    => 'order_item',
      p_ref_id      => v_it.id::text,
      p_supplier    => coalesce(v_it.lot_supplier, v_it.assigned_supplier),
      p_order_id    => p_order_id,
      p_received_on => v_date);

    if v_lot is not null then v_n := v_n + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'order_id', p_order_id,
                            'pharmacy_id', v_shop, 'lots', v_n);
end $$;

-- The rider's proof is the event. Fires once, on the transition into delivered
-- — not on every later touch of the row — and the ref-key uniqueness inside
-- _phs_apply makes even that belt-and-braces.
create or replace function public._phs_delivery_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.delivered_at is not null
     and (tg_op = 'INSERT' or old.delivered_at is distinct from new.delivered_at)
     and new.order_id is not null then
    perform public.pharmacy_stock_ingest_order(new.order_id);
  end if;
  return new;
end $$;

drop trigger if exists phs_delivery_trg on public.deliveries;
create trigger phs_delivery_trg
  after insert or update of delivered_at on public.deliveries
  for each row execute function public._phs_delivery_trg();

-- ─────────────────────────── 6. FEFO: A POS SALE LEAVES THE SHELF ───────────
--
-- #411 writes a `sale.completed` row on pos_sale_event for exactly this, with a
-- `consumed` column for the answer. Nothing in the POS code is touched here —
-- this layer bolts on behind that event, which is why either command could
-- ship first.
--
-- ORDER OF PREFERENCE for which physical stock left the shop:
--   1. the batch the cashier typed on the line. They are holding the strip;
--      they are right and FEFO is a guess.
--   2. FEFO — earliest expiry first, undated lots last. Dated goods must leave
--      in expiry order or the pharmacy eats the write-off.
--   3. the shortfall. It is NOT refused and NOT rounded away: it becomes a
--      negative lot, which is the honest statement "this was sold and the shelf
--      never knew it was there".
create or replace function public.pharmacy_stock_consume_sale(p_sale_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop   uuid;
  v_line   record;
  v_lot    record;
  v_need   numeric;
  v_take   numeric;
  v_item   text;
  v_short  numeric := 0;
  v_neg    integer := 0;
  v_lines  integer := 0;
  v_negs   jsonb := '[]'::jsonb;
begin
  select pharmacy_id into v_shop from public.pos_sales where id = p_sale_id;
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error', 'sale_not_found');
  end if;

  for v_line in
    select l.id, l.line_no, l.medicine_id, l.product_name, l.pack_label,
           l.batch_no, l.expiry, l.qty, l.mrp
      from public.pos_sale_lines l
     where l.sale_id = p_sale_id
     order by l.line_no
  loop
    v_need := coalesce(v_line.qty, 0);
    if v_need <= 0 then continue; end if;
    v_lines := v_lines + 1;
    v_item  := public._phs_item_key(v_line.medicine_id, v_line.product_name);

    -- 1 + 2 in one pass: the cashier's batch is simply sorted to the front of
    -- the FEFO list, so a hand-picked batch wins and everything after it is
    -- still strict earliest-expiry-first.
    for v_lot in
      select s.id, s.qty
        from public.pharmacy_stock s
       where s.pharmacy_id = v_shop
         and s.item_key    = v_item
         and s.qty         > 0
       order by
         (case when nullif(btrim(coalesce(v_line.batch_no,'')),'') is not null
                and s.batch_key = upper(btrim(v_line.batch_no)) then 0 else 1 end),
         s.expiry_on asc nulls last,
         s.created_at asc
    loop
      exit when v_need <= 0;
      v_take := least(v_lot.qty, v_need);
      perform public._phs_apply(
        p_shop      => v_shop,
        p_medicine_id => v_line.medicine_id,
        p_name      => v_line.product_name,
        p_pack      => v_line.pack_label,
        p_batch     => null, p_expiry => null,
        p_qty_delta => -v_take,
        p_unit_cost => null, p_mrp => null,
        p_kind      => 'sale',
        p_source_kind => null,
        p_ref_kind  => 'pos_sale_line_lot',
        p_ref_id    => v_line.id::text || ':' || v_lot.id::text,
        p_lot_id    => v_lot.id);
      v_need := v_need - v_take;
    end loop;

    -- 3. Whatever the shelf could not account for. Attributed to the batch the
    -- cashier named when there was one, so the correction lands on the right
    -- pile instead of a nameless bucket.
    if v_need > 0 then
      perform public._phs_apply(
        p_shop        => v_shop,
        p_medicine_id => v_line.medicine_id,
        p_name        => v_line.product_name,
        p_pack        => v_line.pack_label,
        p_batch       => v_line.batch_no,
        p_expiry      => v_line.expiry,
        p_qty_delta   => -v_need,
        p_unit_cost   => null,
        p_mrp         => v_line.mrp,
        p_kind        => 'sale',
        p_source_kind => 'adjustment',
        p_note        => public.ui_text('phstock.note_sold_unknown'),
        p_ref_kind    => 'pos_sale_line_short',
        p_ref_id      => v_line.id::text);
      v_short := v_short + v_need;
      v_neg   := v_neg + 1;
      v_negs  := v_negs || jsonb_build_object(
                   'line_no', v_line.line_no,
                   'product_name', v_line.product_name,
                   'short_qty', v_need);
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'lines', v_lines,
    'short_qty', v_short, 'negative_lines', v_neg, 'negatives', v_negs,
    'at', now());
end $$;

-- The bolt-on. A failure here writes its reason into `consumed` and returns
-- normally: a shelf that cannot be decremented must NEVER stop a bill from
-- being saved, because a counter that refuses to bill is a counter that gets
-- switched off.
create or replace function public._phs_sale_event_trg()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_res jsonb;
begin
  -- `consumed` is a MAP of consumer -> result, not one consumer's slot: #416
  -- will stamp the register's own key on the same row. So the guard is our own
  -- key, and the write is a merge — never an overwrite of somebody else's answer.
  if new.event_type <> 'sale.completed' or coalesce(new.consumed, '{}'::jsonb) ? 'stock' then
    return new;
  end if;
  begin
    v_res := public.pharmacy_stock_consume_sale(new.sale_id);
  exception when others then
    v_res := jsonb_build_object('ok', false, 'error', 'stock_consume_failed',
                                'detail', sqlerrm, 'at', now());
  end;
  update public.pos_sale_event
     set consumed = coalesce(consumed, '{}'::jsonb) || jsonb_build_object('stock', v_res)
   where id = new.id;
  return new;
end $$;

drop trigger if exists phs_sale_event_trg on public.pos_sale_event;
create trigger phs_sale_event_trg
  after insert on public.pos_sale_event
  for each row execute function public._phs_sale_event_trg();

-- ─────────────────────────── 7. THE MANUAL PATHS ────────────────────────────
-- Everything the purchase side cannot know: the stock that was already on the
-- shelf the day they joined, a strip bought from the shop down the road, and
-- the corrections.

-- 7a. Outside purchase — one lot, typed.
create or replace function public.pharmacy_stock_add_purchase(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phs_shop();
  v_qty  numeric := public._phs_num(p->>'qty');
  v_name text := nullif(btrim(coalesce(p->>'product_name','')), '');
  v_mid  bigint := nullif(p->>'medicine_id','')::bigint;
  v_lot  uuid;
begin
  if v_shop is null then return public._phs_denied(); end if;
  if v_mid is not null and v_name is null then
    select m.product_name into v_name from public."MEDICINE" m where m.id = v_mid;
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false, 'error', 'no_product',
      'message', public.ui_text('phstock.err_no_product'));
  end if;
  if v_qty <= 0 then
    return jsonb_build_object('ok', false, 'error', 'no_qty',
      'message', public.ui_text('phstock.err_no_qty'));
  end if;

  v_lot := public._phs_apply(
    p_shop        => v_shop,
    p_medicine_id => v_mid,
    p_name        => v_name,
    p_pack        => p->>'pack_label',
    p_batch       => p->>'batch_no',
    p_expiry      => p->>'expiry',
    p_qty_delta   => v_qty,
    p_unit_cost   => nullif(p->>'unit_cost','')::numeric,
    p_mrp         => nullif(p->>'mrp','')::numeric,
    p_kind        => 'receipt_outside',
    p_source_kind => 'outside',
    p_note        => nullif(btrim(coalesce(p->>'note','')), ''),
    p_ref_kind    => 'outside',
    p_ref_id      => coalesce(nullif(p->>'client_action_id',''), gen_random_uuid()::text),
    p_supplier    => p->>'supplier_label');

  return jsonb_build_object('ok', true, 'stock_id', v_lot,
    'message', public.ui_text('phstock.added_toast'));
end $$;

-- 7b. Adjustment — a reason is NOT optional. `who` is auth.uid(), recorded on
-- the movement, which is the audit this command has to prove.
create or replace function public.pharmacy_stock_adjust(
  p_stock_id uuid, p_new_qty numeric, p_reason text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop  uuid := public._phs_shop();
  v_lot   public.pharmacy_stock%rowtype;
  v_delta numeric;
begin
  if v_shop is null then return public._phs_denied(); end if;

  select * into v_lot from public.pharmacy_stock
   where id = p_stock_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_lot',
      'message', public.ui_text('phstock.err_no_lot'));
  end if;

  if not exists (select 1 from public.pharmacy_stock_reason
                  where code = p_reason and is_active) then
    return jsonb_build_object('ok', false, 'error', 'no_reason',
      'message', public.ui_text('phstock.err_no_reason'));
  end if;

  v_delta := coalesce(p_new_qty, 0) - v_lot.qty;
  if v_delta = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_change',
      'message', public.ui_text('phstock.err_no_change'));
  end if;

  perform public._phs_apply(
    p_shop        => v_shop,
    p_medicine_id => v_lot.medicine_id,
    p_name        => v_lot.product_name,
    p_pack        => v_lot.pack_label,
    p_batch       => null, p_expiry => null,
    p_qty_delta   => v_delta,
    p_unit_cost   => null, p_mrp => null,
    p_kind        => 'adjust',
    p_source_kind => null,
    p_reason      => p_reason,
    p_note        => nullif(btrim(coalesce(p_note,'')), ''),
    p_ref_kind    => 'adjust',
    p_ref_id      => gen_random_uuid()::text,
    p_lot_id      => v_lot.id);

  return jsonb_build_object('ok', true, 'stock_id', v_lot.id,
    'message', public.ui_text('phstock.adjusted_toast'));
end $$;

-- 7c. Opening stock. Two doors into ONE review table, because the risk is the
-- same either way: a machine read their handwriting and a human has to agree
-- with it before the shelf believes it.
create or replace function public.pharmacy_stock_import_start(
  p_kind text, p_bucket text default null, p_path text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phs_shop(); v_id uuid;
begin
  if v_shop is null then return public._phs_denied(); end if;
  if coalesce(p_kind,'') not in ('csv','photo') then
    return jsonb_build_object('ok', false, 'error', 'bad_kind');
  end if;
  insert into public.pharmacy_stock_import(pharmacy_id, kind, bucket, path, created_by,
                                           status)
  values (v_shop, p_kind, p_bucket, p_path, auth.uid(),
          case when p_kind = 'photo' then 'scanning' else 'draft' end)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'import_id', v_id,
    'message', public.ui_text(case when p_kind='photo'
                              then 'phstock.import_scanning' else 'phstock.import_started' end));
end $$;

-- One CSV line -> fields, honouring quoted commas. Kept in SQL on purpose: Dart
-- must not parse the file, or the parse becomes a second implementation nobody
-- can change without a deploy.
create or replace function public._phs_csv_cells(p_line text)
returns text[] language sql immutable as $$
  select array(
    select btrim(btrim(c), '"')
      from unnest(regexp_split_to_array(coalesce(p_line,''),
             ',(?=(?:[^"]*"[^"]*")*[^"]*$)')) c);
$$;

create or replace function public.pharmacy_stock_import_csv(p_import_id uuid, p_text text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop  uuid := public._phs_shop();
  v_imp   public.pharmacy_stock_import%rowtype;
  v_line  text;
  v_cells text[];
  v_head  text[];
  v_no    integer := 0;
  v_kept  integer := 0;
  i_name int := 1; i_batch int := 2; i_exp int := 3;
  i_qty  int := 4; i_cost  int := 5; i_mrp int := 6;
  k int; h text;
  v_nm text; v_mid bigint;
begin
  if v_shop is null then return public._phs_denied(); end if;
  select * into v_imp from public.pharmacy_stock_import
   where id = p_import_id and pharmacy_id = v_shop;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_import'); end if;

  delete from public.pharmacy_stock_import_row where import_id = p_import_id;

  for v_line in
    select l from regexp_split_to_table(replace(coalesce(p_text,''), E'\r', ''), E'\n') l
  loop
    if btrim(coalesce(v_line,'')) = '' then continue; end if;
    v_cells := public._phs_csv_cells(v_line);

    -- A header is recognised, not required. Recognised, the columns may be in
    -- any order and named in any of the ways a pharmacy actually names them.
    if v_no = 0 and v_kept = 0
       and lower(array_to_string(v_cells, ',')) ~ '(product|item|medicine|name)' then
      v_head := v_cells;
      for k in 1 .. array_length(v_head, 1) loop
        h := lower(btrim(coalesce(v_head[k], '')));
        if   h ~ '(product|item|medicine|^name)' then i_name := k;
        elsif h ~ 'batch'                        then i_batch := k;
        elsif h ~ '(expiry|exp)'                 then i_exp  := k;
        elsif h ~ '(qty|quantity|stock)'         then i_qty  := k;
        elsif h ~ '(cost|rate|ptr|purchase)'     then i_cost := k;
        elsif h ~ 'mrp'                          then i_mrp  := k;
        end if;
      end loop;
      continue;
    end if;

    v_no := v_no + 1;
    v_nm := nullif(btrim(coalesce(v_cells[i_name], '')), '');
    if v_nm is null then continue; end if;

    select m.id into v_mid from public."MEDICINE" m
     where public._norm_name(m.product_name) = public._norm_name(v_nm)
     limit 1;

    insert into public.pharmacy_stock_import_row(
      import_id, line_no, raw, medicine_id, product_name, batch_no, expiry,
      qty, unit_cost, mrp, match_status)
    values (
      p_import_id, v_no, to_jsonb(v_cells), v_mid, v_nm,
      nullif(btrim(coalesce(v_cells[i_batch],'')),''),
      nullif(btrim(coalesce(v_cells[i_exp],'')),''),
      public._phs_num(v_cells[i_qty]),
      nullif(public._phs_num(v_cells[i_cost]), 0),
      nullif(public._phs_num(v_cells[i_mrp]), 0),
      case when v_mid is not null then 'matched' else 'unmatched' end);
    v_kept := v_kept + 1;
  end loop;

  update public.pharmacy_stock_import
     set rows_total = v_kept, status = 'ready'
   where id = p_import_id;

  return public.pharmacy_stock_import_preview(p_import_id);
end $$;

-- The photo door. The edge function does the reading and calls this with what
-- Gemini saw — VERBATIM, exactly as the OCR rule demands. No expansion, no
-- correction, no world knowledge; a name it cannot match stays unmatched and
-- the human decides.
create or replace function public.pharmacy_stock_import_ocr_report(
  p_import_id uuid, p_rows jsonb, p_error text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_imp public.pharmacy_stock_import%rowtype;
  v_r   jsonb; v_no integer := 0; v_nm text; v_mid bigint;
begin
  select * into v_imp from public.pharmacy_stock_import where id = p_import_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_import'); end if;

  if p_error is not null then
    update public.pharmacy_stock_import
       set status = 'failed', ocr_error = p_error where id = p_import_id;
    return jsonb_build_object('ok', false, 'error', 'ocr_failed');
  end if;

  delete from public.pharmacy_stock_import_row where import_id = p_import_id;

  for v_r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    v_nm := nullif(btrim(coalesce(v_r->>'product_name','')), '');
    if v_nm is null then continue; end if;
    v_no := v_no + 1;

    select m.id into v_mid from public."MEDICINE" m
     where public._norm_name(m.product_name) = public._norm_name(v_nm)
     limit 1;

    insert into public.pharmacy_stock_import_row(
      import_id, line_no, raw, medicine_id, product_name, batch_no, expiry,
      qty, unit_cost, mrp, match_status)
    values (p_import_id, v_no, v_r, v_mid, v_nm,
      nullif(btrim(coalesce(v_r->>'batch_no','')),''),
      nullif(btrim(coalesce(v_r->>'expiry','')),''),
      public._phs_num(v_r->>'qty'),
      nullif(public._phs_num(v_r->>'unit_cost'), 0),
      nullif(public._phs_num(v_r->>'mrp'), 0),
      case when v_mid is not null then 'matched' else 'unmatched' end);
  end loop;

  update public.pharmacy_stock_import
     set rows_total = v_no, status = 'ready', ocr_error = null
   where id = p_import_id;

  return jsonb_build_object('ok', true, 'rows', v_no);
end $$;

create or replace function public.pharmacy_stock_import_row_set(p_row_id uuid, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phs_shop(); v_imp uuid;
begin
  if v_shop is null then return public._phs_denied(); end if;
  select r.import_id into v_imp
    from public.pharmacy_stock_import_row r
    join public.pharmacy_stock_import i on i.id = r.import_id
   where r.id = p_row_id and i.pharmacy_id = v_shop;
  if v_imp is null then return jsonb_build_object('ok', false, 'error', 'no_row'); end if;

  update public.pharmacy_stock_import_row r
     set product_name = coalesce(nullif(btrim(coalesce(p_patch->>'product_name','')),''), r.product_name),
         batch_no  = case when p_patch ? 'batch_no' then nullif(btrim(coalesce(p_patch->>'batch_no','')),'') else r.batch_no end,
         expiry    = case when p_patch ? 'expiry'   then nullif(btrim(coalesce(p_patch->>'expiry','')),'')   else r.expiry end,
         qty       = case when p_patch ? 'qty'       then public._phs_num(p_patch->>'qty')                    else r.qty end,
         unit_cost = case when p_patch ? 'unit_cost' then nullif(public._phs_num(p_patch->>'unit_cost'), 0)   else r.unit_cost end,
         mrp       = case when p_patch ? 'mrp'       then nullif(public._phs_num(p_patch->>'mrp'), 0)         else r.mrp end,
         keep      = case when p_patch ? 'keep'      then coalesce((p_patch->>'keep')::boolean, r.keep)       else r.keep end
   where r.id = p_row_id;

  return public.pharmacy_stock_import_preview(v_imp);
end $$;

create or replace function public.pharmacy_stock_import_apply(p_import_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phs_shop();
  v_imp  public.pharmacy_stock_import%rowtype;
  v_r    record; v_n integer := 0;
begin
  if v_shop is null then return public._phs_denied(); end if;
  select * into v_imp from public.pharmacy_stock_import
   where id = p_import_id and pharmacy_id = v_shop;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_import'); end if;
  if v_imp.status = 'applied' then
    return jsonb_build_object('ok', true, 'already', true, 'rows', v_imp.rows_applied,
      'message', public.ui_text('phstock.import_already'));
  end if;

  for v_r in
    select * from public.pharmacy_stock_import_row
     where import_id = p_import_id and keep and coalesce(qty,0) > 0
     order by line_no
  loop
    perform public._phs_apply(
      p_shop        => v_shop,
      p_medicine_id => v_r.medicine_id,
      p_name        => v_r.product_name,
      p_pack        => v_r.pack_label,
      p_batch       => v_r.batch_no,
      p_expiry      => v_r.expiry,
      p_qty_delta   => v_r.qty,
      p_unit_cost   => v_r.unit_cost,
      p_mrp         => v_r.mrp,
      p_kind        => 'opening',
      p_source_kind => 'opening',
      p_ref_kind    => 'import_row',
      p_ref_id      => v_r.id::text);
    v_n := v_n + 1;
  end loop;

  update public.pharmacy_stock_import
     set status = 'applied', rows_applied = v_n, applied_at = now()
   where id = p_import_id;

  return jsonb_build_object('ok', true, 'rows', v_n,
    'message', public.ui_textf(
                 case when v_n = 1 then 'phstock.import_applied_one'
                      else 'phstock.import_applied_many' end,
                 jsonb_build_object('n', v_n::text)));
end $$;

-- ─────────────────────────── 8. READ: THE STOCK SCREEN ──────────────────────
-- One RPC, every string already a string. Dart adds nothing up, formats no
-- rupee, pluralises no word and decides no badge colour.

create or replace function public.pharmacy_stock_entry()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phs_shop();
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  return jsonb_build_object(
    'ok', true, 'show', true,
    'route_key', 'pharmacy_stock',
    'icon_key',  'inventory_2',
    'label',     public.ui_text('phstock.nav_label'),
    'sub_label', public.ui_text('phstock.subtitle'));
end $$;

-- The per-lot state machine, in ONE place. Every badge on the screen and every
-- filter count below is this function's answer, so a lot can never be counted
-- as "low" by the tile and drawn as "ok" by the row.
create or replace function public._phs_lot_state(
  p_qty numeric, p_expiry_on date, p_low numeric, p_near_days integer, p_today date)
returns text language sql immutable as $$
  select case
    when coalesce(p_qty,0) < 0                                          then 'negative'
    when p_expiry_on is not null and p_expiry_on < p_today              then 'expired'
    when coalesce(p_qty,0) = 0                                          then 'out'
    when p_expiry_on is not null
     and p_expiry_on <= p_today + (coalesce(p_near_days,90) || ' days')::interval
                                                                        then 'near_expiry'
    when coalesce(p_qty,0) <= coalesce(p_low,5)                         then 'low'
    else 'ok' end;
$$;

-- The rows this screen is looking at, tagged with their state, in ONE place.
-- Both the tile counts and the row list read it, so a lot can never be counted
-- as low by the header and drawn as fine in the list.
create or replace function public._phs_scope(p_shop uuid, p_q text)
returns table (id uuid, item_key text, state text)
language sql stable security definer set search_path = public as $$
  select s.id, s.item_key,
         public._phs_lot_state(s.qty, s.expiry_on,
           (public._phs_settings(p_shop)->>'low_qty')::numeric,
           (public._phs_settings(p_shop)->>'near_expiry_days')::integer,
           public._phs_today())
    from public.pharmacy_stock s
   where s.pharmacy_id = p_shop
     and (p_q is null
          or s.product_name ilike '%' || p_q || '%'
          or coalesce(s.batch_no,'') ilike '%' || p_q || '%');
$$;

create or replace function public.pharmacy_stock_home(
  p_q text default null, p_filter text default 'all',
  p_limit integer default 40, p_offset integer default 0)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop   uuid := public._phs_shop();
  v_cfg    jsonb;
  v_low    numeric; v_near integer; v_today date := public._phs_today();
  v_q      text := nullif(btrim(coalesce(p_q,'')), '');
  v_f      text := lower(coalesce(nullif(btrim(coalesce(p_filter,'')),''), 'all'));
  v_lim    integer := least(greatest(coalesce(p_limit,40), 1), 100);
  v_off    integer := greatest(coalesce(p_offset,0), 0);
  v_rows   jsonb; v_items integer; v_more boolean;
  v_val    numeric; v_neg integer; v_low_n integer; v_out_n integer;
  v_exp_n  integer; v_near_n integer; v_lots integer;
begin
  if v_shop is null then return public._phs_denied(); end if;
  v_cfg  := public._phs_settings(v_shop);
  v_low  := (v_cfg->>'low_qty')::numeric;
  v_near := (v_cfg->>'near_expiry_days')::integer;

  -- The counts, computed once, on the same scope the rows come from.
  select
    coalesce(sum(case when s.qty > 0 then s.qty * coalesce(s.unit_cost,0) else 0 end), 0),
    count(*) filter (where sc.state = 'negative'),
    count(*) filter (where sc.state = 'low'),
    count(*) filter (where sc.state = 'out'),
    count(*) filter (where sc.state = 'expired'),
    count(*) filter (where sc.state = 'near_expiry'),
    count(*),
    count(distinct s.item_key)
    into v_val, v_neg, v_low_n, v_out_n, v_exp_n, v_near_n, v_lots, v_items
    from public._phs_scope(v_shop, v_q) sc join public.pharmacy_stock s on s.id = sc.id;

  select coalesce(jsonb_agg(r order by r_neg desc, r_name), '[]'::jsonb), count(*) > v_off + v_lim
    into v_rows, v_more
    from (
      select jsonb_build_object(
               'item_key',     g.item_key,
               'medicine_id',  g.medicine_id,
               'product_name', g.product_name,
               'pack_label',   g.pack_label,
               'qty_label',    public.ui_textf('phstock.on_hand',
                                 jsonb_build_object('qty', public._phs_qty(g.qty_total))),
               'value_label',  public._phs_money(g.value_total),
               'badge',        case
                 when g.n_negative > 0 then jsonb_build_object(
                        'label', public.ui_text('phstock.badge_negative'), 'tone', 'danger')
                 when g.qty_total = 0 then jsonb_build_object(
                        'label', public.ui_text('phstock.badge_out'), 'tone', 'danger')
                 when g.n_expired > 0 then jsonb_build_object(
                        'label', public.ui_text('phstock.badge_expired'), 'tone', 'danger')
                 when g.qty_total <= v_low then jsonb_build_object(
                        'label', public.ui_text('phstock.badge_low'), 'tone', 'warning')
                 when g.n_near > 0 then jsonb_build_object(
                        'label', public.ui_text('phstock.badge_near'), 'tone', 'warning')
                 else null end,
               'batches',      g.batches) as r,
             (g.n_negative > 0) as r_neg,
             g.product_name    as r_name
        from (
          select s.item_key,
                 min(s.medicine_id)                                  as medicine_id,
                 min(s.product_name)                                 as product_name,
                 min(s.pack_label)                                   as pack_label,
                 sum(s.qty)                                          as qty_total,
                 sum(case when s.qty > 0 then s.qty * coalesce(s.unit_cost,0) else 0 end) as value_total,
                 count(*) filter (where sc.state = 'negative')       as n_negative,
                 count(*) filter (where sc.state = 'expired')        as n_expired,
                 count(*) filter (where sc.state = 'near_expiry')    as n_near,
                 jsonb_agg(jsonb_build_object(
                     'stock_id',      s.id,
                     'batch_label',   case
                        when nullif(btrim(coalesce(s.batch_no,'')),'') is not null
                        then public.ui_textf('phstock.batch_line',
                               jsonb_build_object('batch', s.batch_no))
                        else public.ui_text('phstock.batch_unknown') end,
                     'expiry_label',  case
                        when nullif(btrim(coalesce(s.expiry,'')),'') is not null
                        then public.ui_textf('phstock.expiry_line',
                               jsonb_build_object('expiry', s.expiry))
                        else public.ui_text('phstock.expiry_unknown') end,
                     'qty_label',     public._phs_qty(s.qty),
                     'qty',           s.qty,
                     'cost_label',    case when s.unit_cost is not null
                        then public.ui_textf('phstock.unit_cost',
                               jsonb_build_object('amount', public._phs_money(s.unit_cost)))
                        else public.ui_text('phstock.cost_unknown') end,
                     'value_label',   public._phs_money(
                                        case when s.qty > 0 then s.qty * coalesce(s.unit_cost,0) else 0 end),
                     'state',         sc.state,
                     'tone',          case sc.state
                                        when 'negative'    then 'danger'
                                        when 'expired'     then 'danger'
                                        when 'out'         then 'muted'
                                        when 'low'         then 'warning'
                                        when 'near_expiry' then 'warning'
                                        else 'ok' end,
                     'state_label',   case sc.state
                        when 'negative'    then public.ui_text('phstock.state_negative')
                        when 'expired'     then public.ui_text('phstock.state_expired')
                        when 'out'         then public.ui_text('phstock.state_out')
                        when 'low'         then public.ui_text('phstock.state_low')
                        when 'near_expiry' then public.ui_text('phstock.state_near')
                        else null end,
                     'source_label',  case s.source_kind
                        when 'medibo_order' then public.ui_text('phstock.src_medibo')
                        when 'opening'      then public.ui_text('phstock.src_opening')
                        when 'outside'      then public.ui_text('phstock.src_outside')
                        else public.ui_text('phstock.src_adjust') end)
                   order by s.expiry_on asc nulls last, s.created_at asc)  as batches
            from public._phs_scope(v_shop, v_q) sc
            join public.pharmacy_stock s on s.id = sc.id
           where v_f = 'all' or sc.state = v_f
           group by s.item_key
        ) g
       order by r_neg desc, r_name
       offset v_off limit v_lim
    ) paged;

  return jsonb_build_object(
    'ok', true,
    'title',       public.ui_text('phstock.title'),
    'subtitle',    public.ui_text('phstock.subtitle'),
    'search_hint', public.ui_text('phstock.search_hint'),
    'tiles', jsonb_build_array(
      jsonb_build_object('key','value','label', public.ui_text('phstock.tile_value'),
                         'value', public._phs_money(v_val), 'tone','ok'),
      jsonb_build_object('key','items','label', public.ui_text('phstock.tile_items'),
                         'value', v_items::text, 'tone','ok'),
      jsonb_build_object('key','low','label', public.ui_text('phstock.tile_low'),
                         'value', (v_low_n + v_out_n)::text,
                         'tone', case when (v_low_n + v_out_n) > 0 then 'warning' else 'ok' end),
      jsonb_build_object('key','negative','label', public.ui_text('phstock.tile_negative'),
                         'value', v_neg::text,
                         'tone', case when v_neg > 0 then 'danger' else 'ok' end)),
    'filters', jsonb_build_array(
      jsonb_build_object('key','all',        'label', public.ui_text('phstock.f_all'),      'count', v_lots,   'selected', v_f='all'),
      jsonb_build_object('key','negative',   'label', public.ui_text('phstock.f_negative'), 'count', v_neg,    'selected', v_f='negative'),
      jsonb_build_object('key','low',        'label', public.ui_text('phstock.f_low'),      'count', v_low_n,  'selected', v_f='low'),
      jsonb_build_object('key','out',        'label', public.ui_text('phstock.f_out'),      'count', v_out_n,  'selected', v_f='out'),
      jsonb_build_object('key','near_expiry','label', public.ui_text('phstock.f_near'),     'count', v_near_n, 'selected', v_f='near_expiry'),
      jsonb_build_object('key','expired',    'label', public.ui_text('phstock.f_expired'),  'count', v_exp_n,  'selected', v_f='expired')),
    'reasons', (select coalesce(jsonb_agg(jsonb_build_object(
                  'code', code, 'label', label, 'direction', direction) order by sort), '[]'::jsonb)
                  from public.pharmacy_stock_reason where is_active),
    'rows',      v_rows,
    'has_more',  coalesce(v_more, false),
    'negative_note', case when v_neg > 0
                     then public.ui_textf(
                            case when v_neg = 1 then 'phstock.negative_note_one'
                                 else 'phstock.negative_note_many' end,
                            jsonb_build_object('n', v_neg::text)) else null end,
    'empty', case when jsonb_array_length(v_rows) = 0 then jsonb_build_object(
                 'title', public.ui_text(case when v_q is not null or v_f <> 'all'
                                          then 'phstock.empty_filtered_title'
                                          else 'phstock.empty_title' end),
                 'body',  public.ui_text(case when v_q is not null or v_f <> 'all'
                                          then 'phstock.empty_filtered_body'
                                          else 'phstock.empty_body' end)) else null end,
    'copy', jsonb_build_object(
      'add_button',     public.ui_text('phstock.add_button'),
      'import_button',  public.ui_text('phstock.import_button'),
      'adjust_button',  public.ui_text('phstock.adjust_button'),
      'adjust_title',   public.ui_text('phstock.adjust_title'),
      'adjust_qty',     public.ui_text('phstock.adjust_qty'),
      'adjust_reason',  public.ui_text('phstock.adjust_reason'),
      'adjust_note',    public.ui_text('phstock.adjust_note'),
      'add_title',      public.ui_text('phstock.add_title'),
      'f_product',      public.ui_text('phstock.f_product'),
      'f_batch',        public.ui_text('phstock.f_batch'),
      'f_expiry',       public.ui_text('phstock.f_expiry'),
      'f_qty',          public.ui_text('phstock.f_qty'),
      'f_cost',         public.ui_text('phstock.f_cost'),
      'f_mrp',          public.ui_text('phstock.f_mrp'),
      'f_supplier',     public.ui_text('phstock.f_supplier'),
      'save',           public.ui_text('phstock.save'),
      'saving',         public.ui_text('phstock.saving'),
      'cancel',         public.ui_text('phstock.cancel'),
      'history_title',  public.ui_text('phstock.history_title'),
      'import_title',   public.ui_text('phstock.import_title'),
      'import_body',    public.ui_text('phstock.import_body'),
      'import_csv',     public.ui_text('phstock.import_csv'),
      'import_photo',   public.ui_text('phstock.import_photo'),
      'import_apply',   public.ui_text('phstock.import_apply'),
      'retry',          public.ui_text('phstock.retry'),
      'error_generic',  public.ui_text('phstock.error_generic')));
end $$;

-- The audit trail for one lot: who moved it, when, why, and where it stood
-- afterwards. This is the proof the adjustment rule asks for.
create or replace function public.pharmacy_stock_moves(
  p_stock_id uuid, p_limit integer default 40)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phs_shop();
  v_lot  public.pharmacy_stock%rowtype;
  v_rows jsonb;
begin
  if v_shop is null then return public._phs_denied(); end if;
  select * into v_lot from public.pharmacy_stock
   where id = p_stock_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_lot',
      'message', public.ui_text('phstock.err_no_lot'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',        m.id,
      'kind_label', case m.kind
         when 'receipt_order'   then public.ui_text('phstock.mv_receipt_order')
         when 'receipt_outside' then public.ui_text('phstock.mv_receipt_outside')
         when 'opening'         then public.ui_text('phstock.mv_opening')
         when 'sale'            then public.ui_text('phstock.mv_sale')
         when 'sale_void'       then public.ui_text('phstock.mv_sale_void')
         else public.ui_text('phstock.mv_adjust') end,
      'qty_label', case when m.qty_delta >= 0 then '+' else '−' end
                   || public._phs_qty(abs(m.qty_delta)),
      'tone',      case when m.qty_delta >= 0 then 'ok' else 'muted' end,
      'after_label', public.ui_textf('phstock.mv_after',
                       jsonb_build_object('qty', public._phs_qty(m.qty_after))),
      'reason_label', (select r.label from public.pharmacy_stock_reason r
                        where r.code = m.reason_code),
      'note',      m.note,
      'actor',     nullif(btrim(coalesce(m.actor_label,'')), ''),
      'when',      to_char(m.created_at at time zone 'Asia/Kolkata',
                           'DD Mon YYYY, HH12:MI AM'))
      order by m.created_at desc, m.id desc), '[]'::jsonb)
    into v_rows
    from (select * from public.pharmacy_stock_move
           where stock_id = p_stock_id
           order by created_at desc, id desc
           limit least(greatest(coalesce(p_limit,40),1),200)) m;

  return jsonb_build_object('ok', true,
    'title', public.ui_text('phstock.history_title'),
    'product_name', v_lot.product_name,
    'rows', v_rows,
    'empty', case when jsonb_array_length(v_rows) = 0
             then public.ui_text('phstock.history_empty') else null end);
end $$;

-- The product picker behind "add an outside purchase". Deliberately its own
-- function rather than a call into the POS search: the two screens are allowed
-- to diverge without one of them breaking the other.
create or replace function public.pharmacy_stock_product_search(
  p_q text, p_limit integer default 20)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phs_shop();
  v_q text := btrim(coalesce(p_q,''));
  v_rows jsonb;
begin
  if v_shop is null then return public._phs_denied(); end if;
  if length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb,
      'message', public.ui_text('phstock.search_short'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'medicine_id',  m.id,
           'product_name', m.product_name,
           'pack_label',   nullif(btrim(coalesce(m.pack_size, m.pack_type,'')),''),
           'mrp',          m.mrp,
           'mrp_label',    case when m.mrp is not null
                           then public.ui_textf('phstock.mrp_line',
                                  jsonb_build_object('amount', public._phs_money(m.mrp)))
                           else null end) order by m.product_name), '[]'::jsonb)
    into v_rows
    from (select id, product_name, pack_size, pack_type, mrp
            from public."MEDICINE"
           where product_name ilike '%' || v_q || '%'
           order by product_name
           limit least(greatest(coalesce(p_limit,20),1),50)) m;

  return jsonb_build_object('ok', true, 'rows', v_rows,
    'empty', case when jsonb_array_length(v_rows) = 0
             then public.ui_text('phstock.search_empty') else null end);
end $$;

create or replace function public.pharmacy_stock_import_preview(p_import_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phs_shop();
  v_imp  public.pharmacy_stock_import%rowtype;
  v_rows jsonb;
begin
  if v_shop is null then return public._phs_denied(); end if;
  select * into v_imp from public.pharmacy_stock_import
   where id = p_import_id and pharmacy_id = v_shop;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_import'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'row_id',       r.id,
           'line_no',      r.line_no,
           'product_name', r.product_name,
           'batch_label',  coalesce(nullif(btrim(coalesce(r.batch_no,'')),''),
                                    public.ui_text('phstock.batch_unknown')),
           'expiry_label', coalesce(nullif(btrim(coalesce(r.expiry,'')),''),
                                    public.ui_text('phstock.expiry_unknown')),
           'qty_label',    public._phs_qty(r.qty),
           'cost_label',   case when r.unit_cost is not null
                           then public._phs_money(r.unit_cost)
                           else public.ui_text('phstock.cost_unknown') end,
           'match_label',  case r.match_status
                             when 'matched' then public.ui_text('phstock.match_ok')
                             else public.ui_text('phstock.match_none') end,
           'match_tone',   case r.match_status when 'matched' then 'ok' else 'warning' end,
           'keep',         r.keep) order by r.line_no), '[]'::jsonb)
    into v_rows
    from public.pharmacy_stock_import_row r where r.import_id = p_import_id;

  return jsonb_build_object('ok', true,
    'import_id', v_imp.id,
    'kind',      v_imp.kind,
    'status',    v_imp.status,
    'title',     public.ui_text('phstock.import_review_title'),
    'status_label', case v_imp.status
       when 'scanning' then public.ui_text('phstock.import_scanning')
       when 'ready'    then public.ui_textf(
                              case when v_imp.rows_total = 1 then 'phstock.import_ready_one'
                                   else 'phstock.import_ready_many' end,
                              jsonb_build_object('n', v_imp.rows_total::text))
       when 'applied'  then public.ui_textf(
                              case when v_imp.rows_applied = 1 then 'phstock.import_applied_one'
                                   else 'phstock.import_applied_many' end,
                              jsonb_build_object('n', v_imp.rows_applied::text))
       when 'failed'   then public.ui_text('phstock.import_failed')
       else public.ui_text('phstock.import_started') end,
    'error',     v_imp.ocr_error,
    'rows',      v_rows,
    'can_apply', v_imp.status = 'ready' and jsonb_array_length(v_rows) > 0,
    'apply_label', public.ui_text('phstock.import_apply'));
end $$;

-- The edge function's own door: it reads the image it was pointed at and hands
-- the rows back through pharmacy_stock_import_ocr_report. service_role only.
create or replace function public.pharmacy_stock_import_ocr_input(p_import_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_imp public.pharmacy_stock_import%rowtype;
begin
  select * into v_imp from public.pharmacy_stock_import where id = p_import_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_import'); end if;
  return jsonb_build_object('ok', true, 'import_id', v_imp.id,
    'bucket', v_imp.bucket, 'path', v_imp.path,
    'prompt', public.ui_text('phstock.ocr_prompt'));
end $$;

-- ─────────────────────────── 9. THE WORDS ───────────────────────────────────
-- Every string the screen can print. Changing the wording is an UPDATE here,
-- never a deploy — which is the whole point of keeping it out of Dart.
insert into public.ui_copy (key, value) values
  ('phstock.nav_label',        to_jsonb('Shelf stock'::text)),
  ('phstock.title',            to_jsonb('Shelf stock'::text)),
  ('phstock.subtitle',         to_jsonb('Builds itself from your mediBO deliveries'::text)),
  ('phstock.search_hint',      to_jsonb('Search a medicine or a batch'::text)),
  ('phstock.err_not_pharmacy', to_jsonb('Shelf stock is for a pharmacy account.'::text)),

  ('phstock.tile_value',       to_jsonb('Stock value'::text)),
  ('phstock.tile_items',       to_jsonb('Medicines'::text)),
  ('phstock.tile_low',         to_jsonb('Low or out'::text)),
  ('phstock.tile_negative',    to_jsonb('Negative'::text)),

  ('phstock.f_all',            to_jsonb('All'::text)),
  ('phstock.f_negative',       to_jsonb('Negative'::text)),
  ('phstock.f_low',            to_jsonb('Low'::text)),
  ('phstock.f_out',            to_jsonb('Out of stock'::text)),
  ('phstock.f_near',           to_jsonb('Near expiry'::text)),
  ('phstock.f_expired',        to_jsonb('Expired'::text)),

  ('phstock.on_hand',          to_jsonb('{qty} on hand'::text)),
  ('phstock.batch_line',       to_jsonb('Batch {batch}'::text)),
  ('phstock.batch_unknown',    to_jsonb('Batch not on the bill'::text)),
  ('phstock.expiry_line',      to_jsonb('Exp {expiry}'::text)),
  ('phstock.expiry_unknown',   to_jsonb('Expiry not recorded'::text)),
  ('phstock.unit_cost',        to_jsonb('{amount} / unit'::text)),
  ('phstock.cost_unknown',     to_jsonb('Cost not known'::text)),
  ('phstock.mrp_line',         to_jsonb('MRP {amount}'::text)),

  ('phstock.badge_negative',   to_jsonb('NEGATIVE'::text)),
  ('phstock.badge_out',        to_jsonb('OUT'::text)),
  ('phstock.badge_expired',    to_jsonb('EXPIRED'::text)),
  ('phstock.badge_low',        to_jsonb('LOW'::text)),
  ('phstock.badge_near',       to_jsonb('NEAR EXPIRY'::text)),

  ('phstock.state_negative',   to_jsonb('Sold more than the shelf knew about'::text)),
  ('phstock.state_expired',    to_jsonb('Past expiry'::text)),
  ('phstock.state_out',        to_jsonb('Finished'::text)),
  ('phstock.state_low',        to_jsonb('Running low'::text)),
  ('phstock.state_near',       to_jsonb('Expiring soon'::text)),

  ('phstock.src_medibo',       to_jsonb('From a mediBO delivery'::text)),
  ('phstock.src_opening',      to_jsonb('Opening stock'::text)),
  ('phstock.src_outside',      to_jsonb('Outside purchase'::text)),
  ('phstock.src_adjust',       to_jsonb('Adjusted'::text)),

  ('phstock.negative_note_one', to_jsonb('1 batch went negative — the counter sold stock this list did not know you had. Correct it and the numbers start telling the truth.'::text)),
  ('phstock.negative_note_many', to_jsonb('{n} batches went negative — the counter sold stock this list did not know you had. Correct them and the numbers start telling the truth.'::text)),
  ('phstock.note_sold_unknown', to_jsonb('Sold at the counter with no stock on record'::text)),

  ('phstock.empty_title',      to_jsonb('Nothing on the shelf yet'::text)),
  ('phstock.empty_body',       to_jsonb('Your next delivered mediBO order lands here on its own — batch, expiry and cost included. Bring your current register in with Opening stock to start from where you are.'::text)),
  ('phstock.empty_filtered_title', to_jsonb('Nothing matches'::text)),
  ('phstock.empty_filtered_body',  to_jsonb('Try another search, or switch back to All.'::text)),

  ('phstock.add_button',       to_jsonb('Add purchase'::text)),
  ('phstock.import_button',    to_jsonb('Opening stock'::text)),
  ('phstock.adjust_button',    to_jsonb('Adjust'::text)),
  ('phstock.add_title',        to_jsonb('Outside purchase'::text)),
  ('phstock.adjust_title',     to_jsonb('Adjust this batch'::text)),
  ('phstock.adjust_qty',       to_jsonb('Counted quantity'::text)),
  ('phstock.adjust_reason',    to_jsonb('Reason'::text)),
  ('phstock.adjust_note',      to_jsonb('Note (optional)'::text)),
  ('phstock.f_product',        to_jsonb('Medicine'::text)),
  ('phstock.f_batch',          to_jsonb('Batch'::text)),
  ('phstock.f_expiry',         to_jsonb('Expiry (MM/YY)'::text)),
  ('phstock.f_qty',            to_jsonb('Quantity'::text)),
  ('phstock.f_cost',           to_jsonb('Cost per unit'::text)),
  ('phstock.f_mrp',            to_jsonb('MRP'::text)),
  ('phstock.f_supplier',       to_jsonb('Bought from'::text)),
  ('phstock.save',             to_jsonb('Save'::text)),
  ('phstock.saving',           to_jsonb('Saving…'::text)),
  ('phstock.cancel',           to_jsonb('Cancel'::text)),
  ('phstock.retry',            to_jsonb('Retry'::text)),
  ('phstock.error_generic',    to_jsonb('Could not load shelf stock. Check the connection and try again.'::text)),
  ('phstock.search_short',     to_jsonb('Type at least 2 letters to search.'::text)),
  ('phstock.search_empty',     to_jsonb('No medicine matched that.'::text)),

  ('phstock.added_toast',      to_jsonb('Added to the shelf'::text)),
  ('phstock.adjusted_toast',   to_jsonb('Stock corrected'::text)),
  ('phstock.err_no_product',   to_jsonb('Pick a medicine first.'::text)),
  ('phstock.err_no_qty',       to_jsonb('Enter how many came in.'::text)),
  ('phstock.err_no_lot',       to_jsonb('That batch is no longer on your shelf.'::text)),
  ('phstock.err_no_reason',    to_jsonb('Choose a reason — every correction is recorded with one.'::text)),
  ('phstock.err_no_change',    to_jsonb('That is already the counted quantity.'::text)),

  ('phstock.history_title',    to_jsonb('Batch history'::text)),
  ('phstock.history_empty',    to_jsonb('Nothing has moved yet.'::text)),
  ('phstock.mv_receipt_order', to_jsonb('mediBO delivery'::text)),
  ('phstock.mv_receipt_outside', to_jsonb('Outside purchase'::text)),
  ('phstock.mv_opening',       to_jsonb('Opening stock'::text)),
  ('phstock.mv_sale',          to_jsonb('Counter sale'::text)),
  ('phstock.mv_sale_void',     to_jsonb('Sale cancelled'::text)),
  ('phstock.mv_adjust',        to_jsonb('Adjustment'::text)),
  ('phstock.mv_after',         to_jsonb('{qty} left'::text)),

  ('phstock.import_title',     to_jsonb('Opening stock'::text)),
  ('phstock.import_body',      to_jsonb('Bring in the stock you already hold, once. Upload a CSV, or photograph the pages of your register and check what was read before it is saved.'::text)),
  ('phstock.import_csv',       to_jsonb('Upload CSV'::text)),
  ('phstock.import_photo',     to_jsonb('Photograph the register'::text)),
  ('phstock.import_apply',     to_jsonb('Add to shelf'::text)),
  ('phstock.import_started',   to_jsonb('Ready for your file'::text)),
  ('phstock.import_scanning',  to_jsonb('Reading the photo…'::text)),
  ('phstock.import_ready_one',  to_jsonb('1 row read — check it before saving'::text)),
  ('phstock.import_ready_many', to_jsonb('{n} rows read — check them before saving'::text)),
  ('phstock.import_applied_one',  to_jsonb('1 row added to the shelf'::text)),
  ('phstock.import_applied_many', to_jsonb('{n} rows added to the shelf'::text)),
  ('phstock.import_already',   to_jsonb('This list was already added'::text)),
  ('phstock.import_failed',    to_jsonb('The photo could not be read. Try a straighter, brighter shot.'::text)),
  ('phstock.import_review_title', to_jsonb('Check before saving'::text)),
  ('phstock.match_ok',         to_jsonb('In catalogue'::text)),
  ('phstock.match_none',       to_jsonb('Not in catalogue'::text)),

  -- The OCR prompt is copy too, so tuning it is an UPDATE, not a redeploy of an
  -- edge function. VERBATIM is not a preference here — it is the OCR naming
  -- rule: no expansion, no correction, no world knowledge, ever.
  ('phstock.ocr_prompt', to_jsonb($ocr$You are reading a photograph of an Indian pharmacy's own handwritten or printed stock register. Return ONLY what is physically printed or written on the page.

Return a JSON array. One object per stock line:
{"product_name": "...", "batch_no": "...", "expiry": "...", "qty": "...", "unit_cost": "...", "mrp": "..."}

ABSOLUTE RULES:
- product_name is the text EXACTLY as written on the page. Never expand an abbreviation, never correct a spelling, never substitute a brand you think they meant, never use outside knowledge of medicine names.
- A field that is not on the page is an empty string. Never guess a batch, an expiry or a price.
- expiry exactly as written (for example "09/27", "SEP 27").
- qty, unit_cost and mrp as digits only.
- Skip headings, totals and page numbers.
- Return the JSON array and nothing else — no prose, no code fence.$ocr$::text))
on conflict (key) do nothing;

-- ─────────────────────────── 10. THE FENCE ──────────────────────────────────
-- Every function here is SECURITY DEFINER, so the grant IS the access control.
-- Revoke the lot, then hand back only the doors a pharmacy is meant to open.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'pharmacy\_stock%' or p.proname like '\_phs\_%')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('revoke all on function %s from authenticated', r.sig);
  end loop;
end $$;

grant execute on function public.pharmacy_stock_entry()                              to authenticated;
grant execute on function public.pharmacy_stock_home(text, text, integer, integer)   to authenticated;
grant execute on function public.pharmacy_stock_moves(uuid, integer)                 to authenticated;
grant execute on function public.pharmacy_stock_product_search(text, integer)        to authenticated;
grant execute on function public.pharmacy_stock_add_purchase(jsonb)                  to authenticated;
grant execute on function public.pharmacy_stock_adjust(uuid, numeric, text, text)    to authenticated;
grant execute on function public.pharmacy_stock_import_start(text, text, text)       to authenticated;
grant execute on function public.pharmacy_stock_import_csv(uuid, text)               to authenticated;
grant execute on function public.pharmacy_stock_import_preview(uuid)                 to authenticated;
grant execute on function public.pharmacy_stock_import_row_set(uuid, jsonb)          to authenticated;
grant execute on function public.pharmacy_stock_import_apply(uuid)                   to authenticated;

-- The OCR pair belongs to the edge function, not to a browser.
grant execute on function public.pharmacy_stock_import_ocr_input(uuid)               to service_role;
grant execute on function public.pharmacy_stock_import_ocr_report(uuid, jsonb, text) to service_role;

-- Intake is machine-driven: the delivery trigger runs it, and service_role can
-- re-run it for a backfill. A pharmacy cannot conjure its own receipts.
grant execute on function public.pharmacy_stock_ingest_order(uuid)                   to service_role;
grant execute on function public.pharmacy_stock_consume_sale(uuid)                   to service_role;
