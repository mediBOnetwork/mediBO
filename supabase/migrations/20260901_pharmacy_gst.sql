-- CMD #416 — the pharmacy's own GST pack: purchase register, sales register,
-- GSTR-shaped exports and a month's paperwork their CA can actually use.
--
-- WHY IT IS WORTH BUILDING. A small Indian pharmacy pays a CA every month
-- largely to re-type paper it already has: the purchase invoices it was sent
-- and the counter bills it wrote. mediBO already holds half of that — every
-- bill it raised to this pharmacy — and #411 now holds the other half, every
-- retail invoice the counter printed. So the register builds itself and the
-- pharmacy's monthly job shrinks to checking it.
--
-- THIS IS THE PHARMACY'S LEDGER, NOT mediBO's. #320's `gst_ledger` is the
-- PLATFORM's own liability and input credit; it is untouched here, and the two
-- never share a row. What they DO share is the arithmetic — `gst_split()`,
-- `gst_norm_gstin()`, `gst_state_of()`, `gst_inv_key()` are the same primitives,
-- so mediBO's outward line and the pharmacy's inward line for the SAME invoice
-- cannot disagree about the tax on it. That is the reconciliation the whole
-- feature is worth having.
--
-- DIRECTION, from the pharmacy's chair:
--   inward  — what it BOUGHT. Two sources: a mediBO bill (automatic) and a
--             local purchase (typed, or read off a photo of the bill).
--   outward — what it SOLD over its own counter (#411's invoices). Retail, so
--             MRP is GST-INCLUSIVE and the tax is BACK-CALCULATED — never added
--             on top. pos_sale_lines already carries the split #411 computed,
--             and this file reads it rather than recomputing it, so the ledger
--             and the printed invoice agree by construction.
--
-- FILING IS HONEST. There is no GSP integration here, so nothing in this file
-- ever claims a return was filed. `pharmacy_gst_settings.filing_mode` is
-- 'download' and the screen says "download for filing"; a GSP adapter later
-- flips that column and the seam (`filing_mode`, `gsp_provider`, `gsp_status`,
-- and the `pharmacy_gst_export_run` audit) is already the shape it needs.
--
-- Idempotent throughout: every object is create-or-replace / if-not-exists, and
-- every builder is a delete-then-insert for its own (pharmacy, period, source),
-- so a resumed worker re-running it lands on the same numbers.
set search_path to public;

-- ─────────────────────────── 1. TABLES ──────────────────────────────────────

create table if not exists public.pharmacy_gst_ledger (
  id           uuid primary key default gen_random_uuid(),
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,

  direction    text not null check (direction in ('inward','outward')),
  source       text not null check (source in ('medibo_bill','outside_purchase','pos_sale')),
  source_id    text,
  -- Stable per source row, so a rebuild REPLACES a line instead of doubling it.
  line_ref     text not null,

  tax_period   date not null,                    -- first of the month, IST
  invoice_no   text,
  invoice_key  text,                             -- normalised, for matching
  invoice_date date,

  counterparty_name  text,
  counterparty_gstin text,

  hsn          text,
  product_name text,
  qty          numeric,
  rate         numeric,                          -- GST %
  taxable      numeric not null default 0,
  cgst         numeric not null default 0,
  sgst         numeric not null default 0,
  igst         numeric not null default 0,
  total_tax    numeric not null default 0,

  is_interstate  boolean not null default false,
  gstin_missing  boolean not null default false,
  place_of_supply text,

  built_at     timestamptz not null default now()
);

create unique index if not exists pharmacy_gst_ledger_uidx
  on public.pharmacy_gst_ledger (pharmacy_id, direction, source, line_ref);

create index if not exists pharmacy_gst_ledger_period_idx
  on public.pharmacy_gst_ledger (pharmacy_id, tax_period, direction);

comment on table public.pharmacy_gst_ledger is
  'CMD #416 — a PHARMACY''s own GST register (inward purchases, outward counter sales). Separate from gst_ledger, which is mediBO''s own liability (#320).';

-- A purchase from someone other than mediBO. Header + lines, because a bill is
-- a bill: one invoice number, many rows. The photo path fills a DRAFT that a
-- human confirms — the camera is not a database.
create table if not exists public.pharmacy_purchase_bill (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  supplier_name  text,
  supplier_gstin text,
  invoice_no     text,
  invoice_date   date,
  status         text not null default 'draft'
                 check (status in ('draft','scanning','ready','confirmed','failed')),
  bucket         text,
  path           text,
  ocr_error      text,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  confirmed_at   timestamptz
);

create index if not exists pharmacy_purchase_bill_shop_idx
  on public.pharmacy_purchase_bill (pharmacy_id, invoice_date desc);

create table if not exists public.pharmacy_purchase_bill_line (
  id           uuid primary key default gen_random_uuid(),
  bill_id      uuid not null references public.pharmacy_purchase_bill(id) on delete cascade,
  line_no      integer not null,
  raw          jsonb,
  product_name text,
  hsn          text,
  qty          numeric,
  taxable      numeric,
  rate         numeric,
  created_at   timestamptz not null default now()
);

create index if not exists pharmacy_purchase_bill_line_idx
  on public.pharmacy_purchase_bill_line (bill_id, line_no);

-- The pharmacy's filing identity, and the GSP seam. Nothing in this build
-- files anything; these columns are what an adapter will read when it exists.
create table if not exists public.pharmacy_gst_settings (
  pharmacy_id  uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  gstin        text,
  legal_name   text,
  filing_mode  text not null default 'download' check (filing_mode in ('download','gsp')),
  gsp_provider text,
  gsp_status   text,
  updated_at   timestamptz not null default now()
);

-- Every export the pharmacy pulled, so "what did we hand the CA in July" has an
-- answer. It is also where a future GSP push records its acknowledgement.
create table if not exists public.pharmacy_gst_export_run (
  id           uuid primary key default gen_random_uuid(),
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  tax_period   date not null,
  export_key   text not null,
  row_count    integer not null default 0,
  mode         text not null default 'download',
  actor_user_id uuid,
  created_at   timestamptz not null default now()
);

create index if not exists pharmacy_gst_export_run_idx
  on public.pharmacy_gst_export_run (pharmacy_id, tax_period, created_at desc);

alter table public.pharmacy_gst_ledger          enable row level security;
alter table public.pharmacy_purchase_bill       enable row level security;
alter table public.pharmacy_purchase_bill_line  enable row level security;
alter table public.pharmacy_gst_settings        enable row level security;
alter table public.pharmacy_gst_export_run      enable row level security;

-- ─────────────────────────── 2. HELPERS ─────────────────────────────────────

create or replace function public._pgst_shop()
returns uuid language sql stable as $$ select public.my_customer_id(); $$;

create or replace function public._pgst_denied()
returns jsonb language sql stable as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('pgst.err_not_pharmacy'));
$$;

create or replace function public._pgst_today()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

create or replace function public._pgst_period(p date)
returns date language sql immutable as $$
  select date_trunc('month', coalesce(p, current_date))::date;
$$;

create or replace function public._pgst_money(p numeric)
returns text language sql immutable as $$ select public.inr_money(coalesce(p,0)); $$;

create or replace function public._pgst_num(p numeric)
returns text language sql immutable as $$
  select trim_scale(round(coalesce(p,0), 2))::text;
$$;

-- The pharmacy's own GSTIN, from its settings row and falling back to the
-- profile it registered with. One place, so every register and every export
-- agrees about who is filing.
create or replace function public._pgst_gstin(p_shop uuid)
returns text language sql stable as $$
  select coalesce(
    public.gst_norm_gstin((select s.gstin from public.pharmacy_gst_settings s
                            where s.pharmacy_id = p_shop)),
    public.gst_norm_gstin((select coalesce(p.gstin, p.gst_no) from public.pharmacy_profiles p
                            where p.id = p_shop)));
$$;

-- ─────────────────────────── 3. THE INWARD REGISTER ─────────────────────────
--
-- 3a. What mediBO sold them. Read off the SAME verified bill lines mediBO
-- raises its own invoice from, with the same PTR-slab discount, so the
-- pharmacy's purchase register and mediBO's sales invoice are the same numbers
-- seen from opposite sides of the counter.
create or replace function public.pharmacy_gst_build_medibo(
  p_shop uuid, p_period date)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_period date := public._pgst_period(p_period);
  v_next   date := (v_period + interval '1 month')::date;
  v_seller text; v_seller_nm text; v_prefix text; v_hsn text;
  v_buyer  text := public._pgst_gstin(p_shop);
  v_n      integer := 0;
begin
  select public.gst_norm_gstin(seller_gstin), seller_name,
         coalesce(invoice_prefix,'MB'), coalesce(default_hsn,'3004')
    into v_seller, v_seller_nm, v_prefix, v_hsn
    from public.billing_config where id = 1;

  delete from public.pharmacy_gst_ledger
   where pharmacy_id = p_shop and tax_period = v_period and source = 'medibo_bill';

  with scoped as (
    select o.id as order_id, o.order_code,
           coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) as inv_dt
      from public.orders o
     where o.customer_id = p_shop
       and coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) >= v_period
       and coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) <  v_next
  ), tot as (
    select s.order_id, coalesce(sum(a.qty * bl.ptr), 0) as ptr_total
      from scoped s
      join public.bill_line_allocations a on a.order_id = s.order_id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
     group by s.order_id
  ), pct as (
    select t.order_id, public.ptr_discount_pct(t.ptr_total) as pct from tot t
  ), lines as (
    select s.order_id, s.order_code, s.inv_dt,
           a.id::text as line_ref,
           coalesce(nullif(btrim(coalesce(bl.hsn,'')),''), v_hsn) as hsn,
           coalesce(m.product_name, bl.raw_name) as product_name,
           a.qty,
           coalesce(bl.gst_pct, 0) as rate,
           -- Exactly what the invoice prints: qty x PTR rounded, less the slab
           -- discount rounded. Never a fresh derivation of its own.
           round(a.qty * bl.ptr, 2)
             - round(round(a.qty * bl.ptr, 2) * coalesce(p.pct,0) / 100.0, 2) as taxable
      from scoped s
      join public.bill_line_allocations a on a.order_id = s.order_id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
      left join pct p on p.order_id = s.order_id
      left join public."MEDICINE" m on m.id = bl.product_id
  )
  insert into public.pharmacy_gst_ledger(
    pharmacy_id, direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_key, invoice_date, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, rate, taxable, cgst, sgst, igst, total_tax,
    is_interstate, gstin_missing, place_of_supply)
  select p_shop, 'inward', 'medibo_bill', l.order_id::text, l.line_ref, v_period,
         v_prefix || '/' || l.order_code,
         public.gst_inv_key(v_prefix || '/' || l.order_code),
         l.inv_dt, v_seller_nm, v_seller,
         l.hsn, l.product_name, l.qty, l.rate, l.taxable,
         (public.gst_split(l.taxable, l.rate, v_seller, v_buyer)->>'cgst')::numeric,
         (public.gst_split(l.taxable, l.rate, v_seller, v_buyer)->>'sgst')::numeric,
         (public.gst_split(l.taxable, l.rate, v_seller, v_buyer)->>'igst')::numeric,
         (public.gst_split(l.taxable, l.rate, v_seller, v_buyer)->>'total_tax')::numeric,
         (public.gst_split(l.taxable, l.rate, v_seller, v_buyer)->>'is_interstate')::boolean,
         (v_buyer is null),
         public.gst_split(l.taxable, l.rate, v_seller, v_buyer)->>'place_of_supply'
    from lines l;

  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- 3b. What they bought locally. Same ledger, typed or read off a photograph.
create or replace function public.pharmacy_gst_build_outside(
  p_shop uuid, p_period date)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_period date := public._pgst_period(p_period);
  v_next   date := (v_period + interval '1 month')::date;
  v_buyer  text := public._pgst_gstin(p_shop);
  v_n      integer := 0;
begin
  delete from public.pharmacy_gst_ledger
   where pharmacy_id = p_shop and tax_period = v_period and source = 'outside_purchase';

  insert into public.pharmacy_gst_ledger(
    pharmacy_id, direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_key, invoice_date, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, rate, taxable, cgst, sgst, igst, total_tax,
    is_interstate, gstin_missing, place_of_supply)
  select p_shop, 'inward', 'outside_purchase', b.id::text, l.id::text, v_period,
         b.invoice_no, public.gst_inv_key(b.invoice_no), b.invoice_date,
         b.supplier_name, public.gst_norm_gstin(b.supplier_gstin),
         l.hsn, l.product_name, l.qty, coalesce(l.rate,0), coalesce(l.taxable,0),
         (public.gst_split(l.taxable, l.rate, public.gst_norm_gstin(b.supplier_gstin), v_buyer)->>'cgst')::numeric,
         (public.gst_split(l.taxable, l.rate, public.gst_norm_gstin(b.supplier_gstin), v_buyer)->>'sgst')::numeric,
         (public.gst_split(l.taxable, l.rate, public.gst_norm_gstin(b.supplier_gstin), v_buyer)->>'igst')::numeric,
         (public.gst_split(l.taxable, l.rate, public.gst_norm_gstin(b.supplier_gstin), v_buyer)->>'total_tax')::numeric,
         (public.gst_split(l.taxable, l.rate, public.gst_norm_gstin(b.supplier_gstin), v_buyer)->>'is_interstate')::boolean,
         (public.gst_norm_gstin(b.supplier_gstin) is null),
         public.gst_split(l.taxable, l.rate, public.gst_norm_gstin(b.supplier_gstin), v_buyer)->>'place_of_supply'
    from public.pharmacy_purchase_bill b
    join public.pharmacy_purchase_bill_line l on l.bill_id = b.id
   where b.pharmacy_id = p_shop
     and b.status = 'confirmed'
     and b.invoice_date >= v_period and b.invoice_date < v_next;

  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ─────────────────────────── 4. THE OUTWARD REGISTER ────────────────────────
--
-- The counter's own invoices. #411 already back-calculated the tax out of the
-- MRP-inclusive amount (retail law: MRP INCLUDES GST), so this READS that split
-- rather than recomputing it — the register can never disagree with the invoice
-- the patient was handed. A walk-in patient is unregistered, so these are B2CS
-- lines: no counterparty GSTIN, intra-state by definition.
create or replace function public.pharmacy_gst_build_sales(
  p_shop uuid, p_period date)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_period date := public._pgst_period(p_period);
  v_next   date := (v_period + interval '1 month')::date;
  v_self   text := public._pgst_gstin(p_shop);
  v_hsn    text;
  v_n      integer := 0;
begin
  select coalesce(default_hsn,'3004') into v_hsn from public.billing_config where id = 1;

  delete from public.pharmacy_gst_ledger
   where pharmacy_id = p_shop and tax_period = v_period and source = 'pos_sale';

  insert into public.pharmacy_gst_ledger(
    pharmacy_id, direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_key, invoice_date, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, rate, taxable, cgst, sgst, igst, total_tax,
    is_interstate, gstin_missing, place_of_supply)
  select p_shop, 'outward', 'pos_sale', s.id::text, l.id::text, v_period,
         s.invoice_no, public.gst_inv_key(s.invoice_no), s.sold_on,
         nullif(btrim(coalesce(s.patient_name,'')),''), null,
         coalesce(nullif(btrim(coalesce(l.hsn,'')),''), v_hsn),
         l.product_name, l.qty, coalesce(l.gst_percent,0), coalesce(l.taxable,0),
         coalesce(l.cgst,0), coalesce(l.sgst,0), coalesce(l.igst,0),
         coalesce(l.cgst,0) + coalesce(l.sgst,0) + coalesce(l.igst,0),
         false, true,
         coalesce(nullif(public.gst_state_label(v_self),''), '')
    from public.pos_sales s
    join public.pos_sale_lines l on l.sale_id = s.id
   where s.pharmacy_id = p_shop
     and s.status = 'completed'
     and s.sold_on >= v_period and s.sold_on < v_next;

  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- One call rebuilds a month, all three sources. Idempotent by construction:
-- each builder clears its own slice first.
create or replace function public.pharmacy_gst_rebuild(
  p_shop uuid, p_period date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_m integer; v_o integer; v_s integer;
begin
  v_m := public.pharmacy_gst_build_medibo(p_shop, p_period);
  v_o := public.pharmacy_gst_build_outside(p_shop, p_period);
  v_s := public.pharmacy_gst_build_sales(p_shop, p_period);
  return jsonb_build_object('ok', true, 'medibo_lines', v_m,
    'outside_lines', v_o, 'sales_lines', v_s,
    'period', public._pgst_period(p_period));
end $$;

-- ─────────────────────────── 5. THE EXPORTS ─────────────────────────────────
--
-- Same block shape #320 already renders: columns + rows + a csv_header and a
-- csv body. The screen is a table printer; it never builds a line of CSV, never
-- formats a rupee and never decides a heading.
--
-- WHAT IS AND IS NOT CLAIMED HERE. These are the GSTR-1 and GSTR-3B SHAPES,
-- ready to hand to a CA or paste into the portal's offline tool. Nothing here
-- files anything, and no status in this file ever says "filed".

create or replace function public._pgst_csv(p_rows jsonb, p_keys text[])
returns text language sql immutable as $$
  select coalesce(string_agg(
    (select string_agg(
       -- A comma or a quote inside a value must not shift a column, so quote
       -- and double-up exactly the way a CSV reader expects.
       case when coalesce(r.v,'') ~ '[",\n]'
            then '"' || replace(coalesce(r.v,''), '"', '""') || '"'
            else coalesce(r.v,'') end, ',' order by r.i)
       from unnest(p_keys) with ordinality as k(key, i)
       cross join lateral (select row_el ->> k.key as v, k.i as i) r),
    E'\n' order by ord), '')
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) with ordinality as t(row_el, ord);
$$;

create or replace function public.pharmacy_gst_exports(p_shop uuid, p_period date)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period date := public._pgst_period(p_period);
  v_b2cs jsonb; v_hsn jsonb; v_3b jsonb; v_pur jsonb;
begin
  -- GSTR-1, B2CS: a walk-in patient is unregistered, so counter sales are
  -- summarised by place of supply and rate, never listed invoice by invoice.
  select coalesce(jsonb_agg(jsonb_build_object(
           'type', 'OE',
           'place_of_supply', coalesce(nullif(place_of_supply,''), '—'),
           'rate', public._pgst_num(rate),
           'taxable', public._pgst_num(sum_taxable),
           'cgst', public._pgst_num(sum_cgst),
           'sgst', public._pgst_num(sum_sgst),
           'igst', public._pgst_num(sum_igst)) order by rate), '[]'::jsonb)
    into v_b2cs
    from (select place_of_supply, rate,
                 sum(taxable) sum_taxable, sum(cgst) sum_cgst,
                 sum(sgst) sum_sgst, sum(igst) sum_igst
            from public.pharmacy_gst_ledger
           where pharmacy_id = p_shop and tax_period = v_period and direction = 'outward'
           group by 1,2) g;

  -- HSN summary — outward, the table the portal asks for.
  select coalesce(jsonb_agg(jsonb_build_object(
           'hsn', hsn, 'rate', public._pgst_num(rate),
           'qty', public._pgst_num(sum_qty),
           'taxable', public._pgst_num(sum_taxable),
           'cgst', public._pgst_num(sum_cgst),
           'sgst', public._pgst_num(sum_sgst),
           'igst', public._pgst_num(sum_igst)) order by hsn, rate), '[]'::jsonb)
    into v_hsn
    from (select coalesce(nullif(hsn,''),'—') hsn, rate,
                 sum(coalesce(qty,0)) sum_qty, sum(taxable) sum_taxable,
                 sum(cgst) sum_cgst, sum(sgst) sum_sgst, sum(igst) sum_igst
            from public.pharmacy_gst_ledger
           where pharmacy_id = p_shop and tax_period = v_period and direction = 'outward'
           group by 1,2) g;

  -- The purchase register, invoice by invoice — what the CA reconciles against
  -- GSTR-2B, and the input credit half of the position.
  select coalesce(jsonb_agg(jsonb_build_object(
           'supplier', coalesce(nullif(counterparty_name,''), '—'),
           'gstin', coalesce(nullif(counterparty_gstin,''), '—'),
           'invoice_no', coalesce(nullif(invoice_no,''), '—'),
           'invoice_date', coalesce(to_char(invoice_date, 'DD Mon YYYY'), '—'),
           'rate', public._pgst_num(rate),
           'taxable', public._pgst_num(sum_taxable),
           'cgst', public._pgst_num(sum_cgst),
           'sgst', public._pgst_num(sum_sgst),
           'igst', public._pgst_num(sum_igst))
           order by invoice_date, invoice_no, rate), '[]'::jsonb)
    into v_pur
    from (select counterparty_name, counterparty_gstin, invoice_no, invoice_date, rate,
                 sum(taxable) sum_taxable, sum(cgst) sum_cgst,
                 sum(sgst) sum_sgst, sum(igst) sum_igst
            from public.pharmacy_gst_ledger
           where pharmacy_id = p_shop and tax_period = v_period and direction = 'inward'
           group by 1,2,3,4,5) g;

  -- GSTR-3B: the three rows a small retailer actually fills.
  select jsonb_build_array(
    jsonb_build_object('row','3.1(a)',
      'label', public.ui_text('pgst.r3b_outward'),
      'taxable', public._pgst_num(coalesce(o.taxable,0)),
      'cgst', public._pgst_num(coalesce(o.cgst,0)),
      'sgst', public._pgst_num(coalesce(o.sgst,0)),
      'igst', public._pgst_num(coalesce(o.igst,0))),
    jsonb_build_object('row','4(A)(5)',
      'label', public.ui_text('pgst.r3b_itc'),
      'taxable', public._pgst_num(coalesce(i.taxable,0)),
      'cgst', public._pgst_num(coalesce(i.cgst,0)),
      'sgst', public._pgst_num(coalesce(i.sgst,0)),
      'igst', public._pgst_num(coalesce(i.igst,0))),
    jsonb_build_object('row','5.1',
      'label', public.ui_text('pgst.r3b_net'),
      'taxable', '',
      'cgst', public._pgst_num(greatest(coalesce(o.cgst,0) - coalesce(i.cgst,0), 0)),
      'sgst', public._pgst_num(greatest(coalesce(o.sgst,0) - coalesce(i.sgst,0), 0)),
      'igst', public._pgst_num(greatest(coalesce(o.igst,0) - coalesce(i.igst,0), 0))))
    into v_3b
    from (select sum(taxable) taxable, sum(cgst) cgst, sum(sgst) sgst, sum(igst) igst
            from public.pharmacy_gst_ledger
           where pharmacy_id = p_shop and tax_period = v_period and direction = 'outward') o
   cross join
        (select sum(taxable) taxable, sum(cgst) cgst, sum(sgst) sgst, sum(igst) igst
            from public.pharmacy_gst_ledger
           where pharmacy_id = p_shop and tax_period = v_period and direction = 'inward') i;

  return jsonb_build_object(
    'heading',  public.ui_text('pgst.exports_heading'),
    'note',     public.ui_text('pgst.exports_note'),
    'blocks', jsonb_build_array(
      jsonb_build_object('key','gstr1_b2cs', 'title', public.ui_text('pgst.exp_b2cs'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','type','label','Type','align','left'),
          jsonb_build_object('key','place_of_supply','label','Place of supply','align','left'),
          jsonb_build_object('key','rate','label','Rate','align','right'),
          jsonb_build_object('key','taxable','label','Taxable','align','right'),
          jsonb_build_object('key','cgst','label','CGST','align','right'),
          jsonb_build_object('key','sgst','label','SGST','align','right'),
          jsonb_build_object('key','igst','label','IGST','align','right')),
        'rows', v_b2cs,
        'csv_header','type,place_of_supply,rate,taxable,cgst,sgst,igst',
        'csv', public._pgst_csv(v_b2cs,
                 array['type','place_of_supply','rate','taxable','cgst','sgst','igst'])),
      jsonb_build_object('key','gstr1_hsn', 'title', public.ui_text('pgst.exp_hsn'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','hsn','label','HSN','align','left'),
          jsonb_build_object('key','rate','label','Rate','align','right'),
          jsonb_build_object('key','qty','label','Qty','align','right'),
          jsonb_build_object('key','taxable','label','Taxable','align','right'),
          jsonb_build_object('key','cgst','label','CGST','align','right'),
          jsonb_build_object('key','sgst','label','SGST','align','right'),
          jsonb_build_object('key','igst','label','IGST','align','right')),
        'rows', v_hsn,
        'csv_header','hsn,rate,qty,taxable,cgst,sgst,igst',
        'csv', public._pgst_csv(v_hsn,
                 array['hsn','rate','qty','taxable','cgst','sgst','igst'])),
      jsonb_build_object('key','purchase_register', 'title', public.ui_text('pgst.exp_purchase'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','supplier','label','Supplier','align','left'),
          jsonb_build_object('key','gstin','label','GSTIN','align','left'),
          jsonb_build_object('key','invoice_no','label','Invoice','align','left'),
          jsonb_build_object('key','invoice_date','label','Date','align','left'),
          jsonb_build_object('key','rate','label','Rate','align','right'),
          jsonb_build_object('key','taxable','label','Taxable','align','right'),
          jsonb_build_object('key','cgst','label','CGST','align','right'),
          jsonb_build_object('key','sgst','label','SGST','align','right'),
          jsonb_build_object('key','igst','label','IGST','align','right')),
        'rows', v_pur,
        'csv_header','supplier,gstin,invoice_no,invoice_date,rate,taxable,cgst,sgst,igst',
        'csv', public._pgst_csv(v_pur,
                 array['supplier','gstin','invoice_no','invoice_date','rate','taxable','cgst','sgst','igst'])),
      jsonb_build_object('key','gstr3b', 'title', public.ui_text('pgst.exp_3b'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','row','label','Row','align','left'),
          jsonb_build_object('key','label','label','Description','align','left'),
          jsonb_build_object('key','taxable','label','Taxable','align','right'),
          jsonb_build_object('key','cgst','label','CGST','align','right'),
          jsonb_build_object('key','sgst','label','SGST','align','right'),
          jsonb_build_object('key','igst','label','IGST','align','right')),
        'rows', v_3b,
        'csv_header','row,description,taxable,cgst,sgst,igst',
        'csv', public._pgst_csv(v_3b,
                 array['row','label','taxable','cgst','sgst','igst']))));
end $$;

-- ─────────────────────────── 6. THE SCREEN ──────────────────────────────────

create or replace function public.pharmacy_gst_entry()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._pgst_shop();
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  return jsonb_build_object(
    'ok', true, 'show', true,
    'route_key', 'pharmacy_gst',
    'icon_key',  'receipt_long',
    'label',     public.ui_text('pgst.nav_label'),
    'sub_label', public.ui_text('pgst.subtitle'));
end $$;

-- One RPC for the whole screen: the month picker, the position, both registers
-- and every export block. Rebuilds the month on read, so the numbers are never
-- a stale snapshot of a bill that changed.
create or replace function public.pharmacy_gst_home(p_period date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop   uuid := public._pgst_shop();
  v_period date;
  v_gstin  text;
  v_mode   text;
  v_out    record; v_in record;
  v_net_c  numeric; v_net_s numeric; v_net_i numeric;
  v_months jsonb; v_pur jsonb; v_sal jsonb;
begin
  if v_shop is null then return public._pgst_denied(); end if;
  v_period := public._pgst_period(coalesce(p_period, public._pgst_today()));
  v_gstin  := public._pgst_gstin(v_shop);

  perform public.pharmacy_gst_rebuild(v_shop, v_period);

  select coalesce(filing_mode,'download') into v_mode
    from public.pharmacy_gst_settings where pharmacy_id = v_shop;
  v_mode := coalesce(v_mode, 'download');

  select coalesce(sum(taxable),0) taxable, coalesce(sum(cgst),0) cgst,
         coalesce(sum(sgst),0) sgst, coalesce(sum(igst),0) igst, count(*) n
    into v_out
    from public.pharmacy_gst_ledger
   where pharmacy_id = v_shop and tax_period = v_period and direction = 'outward';

  select coalesce(sum(taxable),0) taxable, coalesce(sum(cgst),0) cgst,
         coalesce(sum(sgst),0) sgst, coalesce(sum(igst),0) igst, count(*) n
    into v_in
    from public.pharmacy_gst_ledger
   where pharmacy_id = v_shop and tax_period = v_period and direction = 'inward';

  v_net_c := greatest(v_out.cgst - v_in.cgst, 0);
  v_net_s := greatest(v_out.sgst - v_in.sgst, 0);
  v_net_i := greatest(v_out.igst - v_in.igst, 0);

  -- The last twelve months, so the picker is the backend's list rather than a
  -- date widget Dart has to reason about.
  select jsonb_agg(jsonb_build_object(
           'period', to_char(m, 'YYYY-MM-DD'),
           'label',  to_char(m, 'Mon YYYY'),
           'selected', m = v_period) order by m desc)
    into v_months
    from generate_series(
      (public._pgst_period(public._pgst_today()) - interval '11 months')::date,
      public._pgst_period(public._pgst_today()), interval '1 month') m;

  select coalesce(jsonb_agg(jsonb_build_object(
           'invoice_no', coalesce(nullif(invoice_no,''),'—'),
           'date_label', coalesce(to_char(invoice_date,'DD Mon'),'—'),
           'party', coalesce(nullif(counterparty_name,''), public.ui_text('pgst.party_unknown')),
           'gstin', coalesce(nullif(counterparty_gstin,''), public.ui_text('pgst.gstin_missing')),
           'has_gstin', counterparty_gstin is not null,
           'source_label', case source
              when 'medibo_bill' then public.ui_text('pgst.src_medibo')
              else public.ui_text('pgst.src_outside') end,
           'taxable_label', public._pgst_money(sum_taxable),
           'tax_label', public._pgst_money(sum_tax),
           'lines_label', public.ui_textf(
              case when n_lines = 1 then 'pgst.lines_one' else 'pgst.lines_many' end,
              jsonb_build_object('n', n_lines::text)))
           order by invoice_date desc nulls last, invoice_no), '[]'::jsonb)
    into v_pur
    from (select invoice_no, invoice_date, counterparty_name, counterparty_gstin, source,
                 sum(taxable) sum_taxable, sum(total_tax) sum_tax, count(*) n_lines
            from public.pharmacy_gst_ledger
           where pharmacy_id = v_shop and tax_period = v_period and direction = 'inward'
           group by 1,2,3,4,5) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'invoice_no', coalesce(nullif(invoice_no,''),'—'),
           'date_label', coalesce(to_char(invoice_date,'DD Mon'),'—'),
           'party', coalesce(nullif(counterparty_name,''), public.ui_text('pgst.walk_in')),
           'taxable_label', public._pgst_money(sum_taxable),
           'tax_label', public._pgst_money(sum_tax),
           'lines_label', public.ui_textf(
              case when n_lines = 1 then 'pgst.lines_one' else 'pgst.lines_many' end,
              jsonb_build_object('n', n_lines::text)))
           order by invoice_date desc nulls last, invoice_no desc), '[]'::jsonb)
    into v_sal
    from (select invoice_no, invoice_date, counterparty_name,
                 sum(taxable) sum_taxable, sum(total_tax) sum_tax, count(*) n_lines
            from public.pharmacy_gst_ledger
           where pharmacy_id = v_shop and tax_period = v_period and direction = 'outward'
           group by 1,2,3) g;

  return jsonb_build_object(
    'ok', true,
    'title',    public.ui_text('pgst.title'),
    'subtitle', public.ui_text('pgst.subtitle'),
    'period',   to_char(v_period, 'YYYY-MM-DD'),
    'period_label', to_char(v_period, 'Mon YYYY'),
    'months',   coalesce(v_months, '[]'::jsonb),
    'gstin_label', case when v_gstin is not null
                   then public.ui_textf('pgst.your_gstin', jsonb_build_object('gstin', v_gstin))
                   else public.ui_text('pgst.no_gstin') end,
    'has_gstin', v_gstin is not null,

    -- The position: what they owe, what they can claim, what is left to pay.
    -- Every one of these is a finished rupee string.
    'position', jsonb_build_object(
      'heading', public.ui_text('pgst.position_heading'),
      'tiles', jsonb_build_array(
        jsonb_build_object('key','output','label', public.ui_text('pgst.tile_output'),
          'value', public._pgst_money(v_out.cgst + v_out.sgst + v_out.igst), 'tone','warning'),
        jsonb_build_object('key','input','label', public.ui_text('pgst.tile_input'),
          'value', public._pgst_money(v_in.cgst + v_in.sgst + v_in.igst), 'tone','ok'),
        jsonb_build_object('key','net','label', public.ui_text('pgst.tile_net'),
          'value', public._pgst_money(v_net_c + v_net_s + v_net_i),
          'tone', case when (v_net_c + v_net_s + v_net_i) > 0 then 'danger' else 'ok' end)),
      'note', public.ui_text('pgst.position_note')),

    'tabs', jsonb_build_array(
      jsonb_build_object('key','position', 'label', public.ui_text('pgst.tab_position')),
      jsonb_build_object('key','purchase', 'label', public.ui_text('pgst.tab_purchase')),
      jsonb_build_object('key','sales',    'label', public.ui_text('pgst.tab_sales')),
      jsonb_build_object('key','exports',  'label', public.ui_text('pgst.tab_exports'))),

    'purchase', jsonb_build_object(
      'heading', public.ui_text('pgst.purchase_heading'),
      'rows', v_pur,
      'total_label', public._pgst_money(v_in.taxable),
      'tax_label',   public._pgst_money(v_in.cgst + v_in.sgst + v_in.igst),
      'empty', case when jsonb_array_length(v_pur) = 0
               then public.ui_text('pgst.purchase_empty') end,
      'add_label', public.ui_text('pgst.add_purchase')),

    'sales', jsonb_build_object(
      'heading', public.ui_text('pgst.sales_heading'),
      'rows', v_sal,
      'total_label', public._pgst_money(v_out.taxable),
      'tax_label',   public._pgst_money(v_out.cgst + v_out.sgst + v_out.igst),
      'empty', case when jsonb_array_length(v_sal) = 0
               then public.ui_text('pgst.sales_empty') end),

    'exports', public.pharmacy_gst_exports(v_shop, v_period),

    -- The honest bit. There is no GSP here, so the button says DOWNLOAD and the
    -- banner says out loud that filing still happens on the portal.
    'filing', jsonb_build_object(
      'mode', v_mode,
      'can_file', false,
      'label', public.ui_text('pgst.filing_download'),
      'note',  public.ui_text('pgst.filing_note')),

    'copy', jsonb_build_object(
      'pack_button',  public.ui_text('pgst.pack_button'),
      'pack_working', public.ui_text('pgst.pack_working'),
      'pack_ready',   public.ui_text('pgst.pack_ready'),
      'copy_button',  public.ui_text('pgst.copy_button'),
      'copied',       public.ui_text('pgst.copied'),
      'retry',        public.ui_text('pgst.retry'),
      'error_generic',public.ui_text('pgst.error_generic'),
      'save',         public.ui_text('pgst.save'),
      'saving',       public.ui_text('pgst.saving'),
      'cancel',       public.ui_text('pgst.cancel'),
      'f_supplier',   public.ui_text('pgst.f_supplier'),
      'f_gstin',      public.ui_text('pgst.f_gstin'),
      'f_invoice',    public.ui_text('pgst.f_invoice'),
      'f_date',       public.ui_text('pgst.f_date'),
      'f_taxable',    public.ui_text('pgst.f_taxable'),
      'f_rate',       public.ui_text('pgst.f_rate'),
      'f_hsn',        public.ui_text('pgst.f_hsn'),
      'add_title',    public.ui_text('pgst.add_title')));
end $$;

-- A pulled export is recorded, so "what did we give the CA in July" has an
-- answer — and so a future GSP push has somewhere to write its acknowledgement.
create or replace function public.pharmacy_gst_export_log(
  p_period date, p_key text, p_rows integer default 0)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._pgst_shop();
begin
  if v_shop is null then return public._pgst_denied(); end if;
  insert into public.pharmacy_gst_export_run(
    pharmacy_id, tax_period, export_key, row_count, mode, actor_user_id)
  values (v_shop, public._pgst_period(p_period), coalesce(p_key,'unknown'),
          greatest(coalesce(p_rows,0),0), 'download', auth.uid());
  return jsonb_build_object('ok', true,
    'message', public.ui_text('pgst.export_logged'));
end $$;

-- ─────────────────────────── 7. OUTSIDE PURCHASE ENTRY ──────────────────────

create or replace function public.pharmacy_gst_bill_save(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._pgst_shop();
  v_id   uuid;
  v_line jsonb;
  v_n    integer := 0;
  v_date date;
begin
  if v_shop is null then return public._pgst_denied(); end if;

  v_date := public.gst_parse_date(p->>'invoice_date', null);
  if v_date is null then
    return jsonb_build_object('ok', false, 'error', 'no_date',
      'message', public.ui_text('pgst.err_no_date'));
  end if;
  if coalesce(jsonb_array_length(p->'lines'), 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_lines',
      'message', public.ui_text('pgst.err_no_lines'));
  end if;

  v_id := nullif(p->>'bill_id','')::uuid;
  if v_id is null then
    insert into public.pharmacy_purchase_bill(
      pharmacy_id, supplier_name, supplier_gstin, invoice_no, invoice_date,
      status, created_by, confirmed_at)
    values (v_shop,
      nullif(btrim(coalesce(p->>'supplier_name','')),''),
      nullif(btrim(coalesce(p->>'supplier_gstin','')),''),
      nullif(btrim(coalesce(p->>'invoice_no','')),''),
      v_date, 'confirmed', auth.uid(), now())
    returning id into v_id;
  else
    update public.pharmacy_purchase_bill
       set supplier_name  = nullif(btrim(coalesce(p->>'supplier_name','')),''),
           supplier_gstin = nullif(btrim(coalesce(p->>'supplier_gstin','')),''),
           invoice_no     = nullif(btrim(coalesce(p->>'invoice_no','')),''),
           invoice_date   = v_date,
           status         = 'confirmed',
           confirmed_at   = now()
     where id = v_id and pharmacy_id = v_shop;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'no_bill');
    end if;
    delete from public.pharmacy_purchase_bill_line where bill_id = v_id;
  end if;

  for v_line in select * from jsonb_array_elements(p->'lines') loop
    v_n := v_n + 1;
    insert into public.pharmacy_purchase_bill_line(
      bill_id, line_no, raw, product_name, hsn, qty, taxable, rate)
    values (v_id, v_n, v_line,
      nullif(btrim(coalesce(v_line->>'product_name','')),''),
      nullif(btrim(coalesce(v_line->>'hsn','')),''),
      nullif(regexp_replace(coalesce(v_line->>'qty',''), '[^0-9.]', '', 'g'),'')::numeric,
      coalesce(nullif(regexp_replace(coalesce(v_line->>'taxable',''), '[^0-9.]', '', 'g'),'')::numeric, 0),
      coalesce(nullif(regexp_replace(coalesce(v_line->>'rate',''), '[^0-9.]', '', 'g'),'')::numeric, 0));
  end loop;

  -- The register is rebuilt for that month straight away, so the position tile
  -- moves the moment the bill is saved.
  perform public.pharmacy_gst_build_outside(v_shop, v_date);

  return jsonb_build_object('ok', true, 'bill_id', v_id, 'lines', v_n,
    'message', public.ui_text('pgst.bill_saved'));
end $$;

-- The photo door, reusing #412's proven shape: the backend picks the bucket and
-- the path (so a pharmacy can only write into its own folder) and the OCR fills
-- a DRAFT a human confirms with pharmacy_gst_bill_save.
create or replace function public.pharmacy_gst_bill_photo_start()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._pgst_shop(); v_id uuid := gen_random_uuid();
begin
  if v_shop is null then return public._pgst_denied(); end if;
  insert into public.pharmacy_purchase_bill(
    id, pharmacy_id, status, bucket, path, created_by)
  values (v_id, v_shop, 'scanning', 'stock-imports',
          v_shop::text || '/gst-' || v_id::text || '.jpg', auth.uid());
  return jsonb_build_object('ok', true, 'bill_id', v_id,
    'bucket', 'stock-imports',
    'path', v_shop::text || '/gst-' || v_id::text || '.jpg',
    'scan_function', 'stock-ocr',
    'message', public.ui_text('pgst.photo_scanning'));
end $$;

-- ─────────────────────────── 8. THE WORDS ───────────────────────────────────
insert into public.ui_copy (key, value) values
  ('pgst.nav_label',       to_jsonb('GST pack'::text)),
  ('pgst.title',           to_jsonb('GST pack'::text)),
  ('pgst.subtitle',        to_jsonb('Your purchase and sales registers, ready for your CA'::text)),
  ('pgst.err_not_pharmacy',to_jsonb('The GST pack is for a pharmacy account.'::text)),

  ('pgst.tab_position',    to_jsonb('Position'::text)),
  ('pgst.tab_purchase',    to_jsonb('Purchases'::text)),
  ('pgst.tab_sales',       to_jsonb('Sales'::text)),
  ('pgst.tab_exports',     to_jsonb('Returns'::text)),

  ('pgst.position_heading',to_jsonb('This month'::text)),
  ('pgst.tile_output',     to_jsonb('Tax you collected'::text)),
  ('pgst.tile_input',      to_jsonb('Credit you can claim'::text)),
  ('pgst.tile_net',        to_jsonb('Net payable'::text)),
  ('pgst.position_note',   to_jsonb('Counter sales carry the tax you collected. Purchase bills carry the credit you can set against it. What is left is what you pay.'::text)),

  ('pgst.purchase_heading',to_jsonb('Purchase register'::text)),
  ('pgst.sales_heading',   to_jsonb('Sales register'::text)),
  ('pgst.purchase_empty',  to_jsonb('No purchases this month yet. Every mediBO bill lands here on its own; add an outside bill for anything you bought locally.'::text)),
  ('pgst.sales_empty',     to_jsonb('No counter sales this month. Every bill you save at the counter lands here on its own.'::text)),
  ('pgst.add_purchase',    to_jsonb('Add outside bill'::text)),
  ('pgst.src_medibo',      to_jsonb('mediBO'::text)),
  ('pgst.src_outside',     to_jsonb('Outside'::text)),
  ('pgst.party_unknown',   to_jsonb('Supplier not named'::text)),
  ('pgst.gstin_missing',   to_jsonb('No GSTIN on the bill'::text)),
  ('pgst.walk_in',         to_jsonb('Counter sale'::text)),
  ('pgst.lines_one',       to_jsonb('1 item'::text)),
  ('pgst.lines_many',      to_jsonb('{n} items'::text)),
  ('pgst.your_gstin',      to_jsonb('Filing as {gstin}'::text)),
  ('pgst.no_gstin',        to_jsonb('No GSTIN on your account yet — add it so the returns carry it'::text)),

  ('pgst.exports_heading', to_jsonb('Returns'::text)),
  ('pgst.exports_note',    to_jsonb('These are the GSTR-1 and GSTR-3B tables in the shape the portal expects. Copy one, or download the month''s pack, and file on the GST portal.'::text)),
  ('pgst.exp_b2cs',        to_jsonb('GSTR-1 · B2CS (counter sales)'::text)),
  ('pgst.exp_hsn',         to_jsonb('GSTR-1 · HSN summary'::text)),
  ('pgst.exp_purchase',    to_jsonb('Purchase register (for GSTR-2B matching)'::text)),
  ('pgst.exp_3b',          to_jsonb('GSTR-3B · summary'::text)),
  ('pgst.r3b_outward',     to_jsonb('Outward taxable supplies'::text)),
  ('pgst.r3b_itc',         to_jsonb('ITC available — all other ITC'::text)),
  ('pgst.r3b_net',         to_jsonb('Tax payable after credit'::text)),

  -- The honest sentence. There is no GSP adapter behind this build, and the
  -- screen must never imply a return was filed from here.
  ('pgst.filing_download', to_jsonb('Download for filing'::text)),
  ('pgst.filing_note',     to_jsonb('mediBO prepares the return; it does not file it. Filing happens on the GST portal or through your CA — one-tap filing needs a licensed GSP, which is not connected yet.'::text)),

  ('pgst.pack_button',     to_jsonb('Monthly pack for your CA'::text)),
  ('pgst.pack_working',    to_jsonb('Preparing the pack…'::text)),
  ('pgst.pack_ready',      to_jsonb('Pack ready'::text)),
  ('pgst.copy_button',     to_jsonb('Copy table'::text)),
  ('pgst.copied',          to_jsonb('Copied — paste it into the portal tool or a sheet'::text)),
  ('pgst.export_logged',   to_jsonb('Saved to this month''s export history'::text)),
  ('pgst.retry',           to_jsonb('Retry'::text)),
  ('pgst.error_generic',   to_jsonb('Could not load the GST pack. Check the connection and try again.'::text)),
  ('pgst.save',            to_jsonb('Save'::text)),
  ('pgst.saving',          to_jsonb('Saving…'::text)),
  ('pgst.cancel',          to_jsonb('Cancel'::text)),

  ('pgst.add_title',       to_jsonb('Outside purchase bill'::text)),
  ('pgst.f_supplier',      to_jsonb('Supplier'::text)),
  ('pgst.f_gstin',         to_jsonb('Supplier GSTIN'::text)),
  ('pgst.f_invoice',       to_jsonb('Invoice number'::text)),
  ('pgst.f_date',          to_jsonb('Invoice date'::text)),
  ('pgst.f_taxable',       to_jsonb('Taxable value'::text)),
  ('pgst.f_rate',          to_jsonb('GST %'::text)),
  ('pgst.f_hsn',           to_jsonb('HSN'::text)),
  ('pgst.err_no_date',     to_jsonb('Enter the invoice date.'::text)),
  ('pgst.err_no_lines',    to_jsonb('Add at least one line from the bill.'::text)),
  ('pgst.bill_saved',      to_jsonb('Bill added to the purchase register'::text)),
  ('pgst.photo_scanning',  to_jsonb('Reading the bill…'::text))
on conflict (key) do nothing;

-- ─────────────────────────── 9. THE FENCE ───────────────────────────────────
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'pharmacy\_gst%' or p.proname like '\_pgst\_%')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('revoke all on function %s from authenticated', r.sig);
  end loop;
end $$;

grant execute on function public.pharmacy_gst_entry()                        to authenticated;
grant execute on function public.pharmacy_gst_home(date)                     to authenticated;
grant execute on function public.pharmacy_gst_export_log(date, text, integer) to authenticated;
grant execute on function public.pharmacy_gst_bill_save(jsonb)               to authenticated;
grant execute on function public.pharmacy_gst_bill_photo_start()             to authenticated;

-- The builders are machine-side: a pharmacy reads its register, it does not
-- get to rewrite it out of band.
grant execute on function public.pharmacy_gst_rebuild(uuid, date)            to service_role;
grant execute on function public.pharmacy_gst_build_medibo(uuid, date)       to service_role;
grant execute on function public.pharmacy_gst_build_outside(uuid, date)      to service_role;
grant execute on function public.pharmacy_gst_build_sales(uuid, date)        to service_role;
grant execute on function public.pharmacy_gst_exports(uuid, date)            to service_role;

-- ─────────────────────────── 10. THE MONTHLY PACK ───────────────────────────
--
-- "Hand this to your CA" — one PDF holding the position, both register
-- summaries and the GSTR-1/3B tables for the month. Same request → render →
-- report shape #411's invoice uses, so the screen polls one status field and
-- the renderer stays a dumb printer of a payload built here.
alter table public.pharmacy_gst_export_run add column if not exists pack_status text;
alter table public.pharmacy_gst_export_run add column if not exists pack_bucket text;
alter table public.pharmacy_gst_export_run add column if not exists pack_path   text;
alter table public.pharmacy_gst_export_run add column if not exists pack_name   text;
alter table public.pharmacy_gst_export_run add column if not exists pack_bytes  integer;
alter table public.pharmacy_gst_export_run add column if not exists pack_error  text;
alter table public.pharmacy_gst_export_run add column if not exists pack_ready_at timestamptz;

create or replace function public.pharmacy_gst_pack_request(p_period date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._pgst_shop();
  v_period date;
  v_id uuid;
begin
  if v_shop is null then return public._pgst_denied(); end if;
  v_period := public._pgst_period(coalesce(p_period, public._pgst_today()));

  -- The pack is always drawn from a freshly rebuilt month; a CA must never be
  -- handed a snapshot of a bill that has since been corrected.
  perform public.pharmacy_gst_rebuild(v_shop, v_period);

  insert into public.pharmacy_gst_export_run(
    pharmacy_id, tax_period, export_key, mode, actor_user_id, pack_status)
  values (v_shop, v_period, 'ca_pack', 'download', auth.uid(), 'pending')
  returning id into v_id;

  -- Dispatched by the DATABASE with the service key, exactly the way #411's
  -- invoice is: the browser never calls the renderer, so the function can keep
  -- verify_jwt on and there is one authenticated path into it.
  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gst-pack',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('run_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'run_id', v_id,
    'poll_ms', 1500,
    'status', 'pending',
    'message', public.ui_text('pgst.pack_working'));
end $$;

-- Everything the renderer prints, already worded and already in rupees. The
-- edge function draws; it decides nothing.
create or replace function public.pharmacy_gst_pack_input(p_run_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_run public.pharmacy_gst_export_run%rowtype;
  v_shop uuid; v_period date;
  v_out record; v_in record;
  v_name text; v_gstin text;
begin
  select * into v_run from public.pharmacy_gst_export_run where id = p_run_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_run'); end if;
  v_shop := v_run.pharmacy_id; v_period := v_run.tax_period;

  select coalesce(nullif(btrim(coalesce(s.legal_name,'')),''), p.pharmacy_name)
    into v_name
    from public.pharmacy_profiles p
    left join public.pharmacy_gst_settings s on s.pharmacy_id = p.id
   where p.id = v_shop;
  v_gstin := public._pgst_gstin(v_shop);

  select coalesce(sum(taxable),0) taxable, coalesce(sum(cgst),0) cgst,
         coalesce(sum(sgst),0) sgst, coalesce(sum(igst),0) igst
    into v_out from public.pharmacy_gst_ledger
   where pharmacy_id = v_shop and tax_period = v_period and direction = 'outward';

  select coalesce(sum(taxable),0) taxable, coalesce(sum(cgst),0) cgst,
         coalesce(sum(sgst),0) sgst, coalesce(sum(igst),0) igst
    into v_in from public.pharmacy_gst_ledger
   where pharmacy_id = v_shop and tax_period = v_period and direction = 'inward';

  return jsonb_build_object(
    'ok', true,
    'run_id', p_run_id,
    'bucket', 'partner-receipts',
    'path',   v_shop::text || '/gst/' || to_char(v_period,'YYYY-MM') || '-' || p_run_id::text || '.pdf',
    'name',   'GST-' || to_char(v_period,'YYYY-MM') || '.pdf',
    'title',  public.ui_text('pgst.pack_title'),
    'shop_name', v_name,
    'gstin_line', case when v_gstin is not null
                  then public.ui_textf('pgst.your_gstin', jsonb_build_object('gstin', v_gstin))
                  else public.ui_text('pgst.no_gstin') end,
    'period_label', to_char(v_period, 'Mon YYYY'),
    'disclaimer', public.ui_text('pgst.filing_note'),
    'summary', jsonb_build_array(
      jsonb_build_object('label', public.ui_text('pgst.tile_output'),
                         'value', public._pgst_money(v_out.cgst + v_out.sgst + v_out.igst)),
      jsonb_build_object('label', public.ui_text('pgst.tile_input'),
                         'value', public._pgst_money(v_in.cgst + v_in.sgst + v_in.igst)),
      jsonb_build_object('label', public.ui_text('pgst.tile_net'),
                         'value', public._pgst_money(
                           greatest(v_out.cgst - v_in.cgst, 0)
                         + greatest(v_out.sgst - v_in.sgst, 0)
                         + greatest(v_out.igst - v_in.igst, 0)))),
    'blocks', public.pharmacy_gst_exports(v_shop, v_period)->'blocks');
end $$;

create or replace function public.pharmacy_gst_pack_report(
  p_run_id uuid, p_ok boolean, p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes integer default null, p_error text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.pharmacy_gst_export_run
     set pack_status = case when p_ok then 'ready' else 'failed' end,
         pack_bucket = coalesce(p_bucket, pack_bucket),
         pack_path   = coalesce(p_path, pack_path),
         pack_name   = coalesce(p_name, pack_name),
         pack_bytes  = coalesce(p_bytes, pack_bytes),
         pack_error  = p_error,
         pack_ready_at = case when p_ok then now() else pack_ready_at end
   where id = p_run_id;
  return jsonb_build_object('ok', true);
end $$;

-- What the screen polls: the backend's own status word, its own poll interval
-- and the bucket+path to open. The screen builds no URL and invents no timeout.
create or replace function public.pharmacy_gst_pack_status(p_run_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._pgst_shop(); v_run public.pharmacy_gst_export_run%rowtype;
begin
  if v_shop is null then return public._pgst_denied(); end if;
  select * into v_run from public.pharmacy_gst_export_run
   where id = p_run_id and pharmacy_id = v_shop;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_run'); end if;

  return jsonb_build_object('ok', true,
    'status', coalesce(v_run.pack_status,'pending'),
    'ready',  coalesce(v_run.pack_status,'') = 'ready',
    'poll_ms', 1500,
    'bucket', v_run.pack_bucket, 'path', v_run.pack_path, 'name', v_run.pack_name,
    'message', case coalesce(v_run.pack_status,'pending')
                 when 'ready'  then public.ui_text('pgst.pack_ready')
                 when 'failed' then public.ui_text('pgst.pack_failed')
                 else public.ui_text('pgst.pack_working') end);
end $$;

insert into public.ui_copy (key, value) values
  ('pgst.pack_title',  to_jsonb('GST pack'::text)),
  ('pgst.pack_failed', to_jsonb('The pack could not be prepared. Try again.'::text))
on conflict (key) do nothing;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'pharmacy\_gst\_pack%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

grant execute on function public.pharmacy_gst_pack_request(date)  to authenticated;
grant execute on function public.pharmacy_gst_pack_status(uuid)   to authenticated;
grant execute on function public.pharmacy_gst_pack_input(uuid)    to service_role;
grant execute on function public.pharmacy_gst_pack_report(uuid, boolean, text, text, text, integer, text) to service_role;
