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
  if new.event_type <> 'sale.completed' or new.consumed is not null then
    return new;
  end if;
  begin
    v_res := public.pharmacy_stock_consume_sale(new.sale_id);
  exception when others then
    v_res := jsonb_build_object('ok', false, 'error', 'stock_consume_failed',
                                'detail', sqlerrm, 'at', now());
  end;
  update public.pos_sale_event set consumed = v_res where id = new.id;
  return new;
end $$;

drop trigger if exists phs_sale_event_trg on public.pos_sale_event;
create trigger phs_sale_event_trg
  after insert on public.pos_sale_event
  for each row execute function public._phs_sale_event_trg();
