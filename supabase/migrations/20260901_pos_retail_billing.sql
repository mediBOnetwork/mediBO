-- CMD #411 — Pharmacy POS: retail billing to walk-in patients.
--
-- The anchor of the free shop-management layer. A mediBO pharmacy (a
-- `pharmacy_profiles` row, i.e. a customer account) sells over its own counter
-- to a walk-in patient and prints a GST tax invoice on its OWN GSTIN/DL.
--
-- WHAT IS DIFFERENT FROM mediBO's OWN BILLING, and why it is not a contradiction
-- of the "never price on MRP" rule in legal_get_page('about'):
--   * mediBO's B2B trade billing prices on PTR/trade rate. MRP there is the
--     legal ceiling and a display field only. That rule is untouched.
--   * THIS is the pharmacy's own RETAIL counter. An Indian retail pharmacy sells
--     to a patient AT MRP, and MRP is GST-INCLUSIVE by law. So a retail line's
--     taxable value is BACK-CALCULATED out of the MRP-inclusive amount
--     (taxable = amount / (1 + gst/100)), never added on top. Adding GST on top
--     of MRP would over-charge the patient and print an illegal invoice.
--   * A walk-in sale is intra-state by definition (the patient is standing in
--     the shop), so the tax always splits CGST + SGST at half each. IGST columns
--     exist on the row and stay zero — the register (#416) wants the column.
--
-- EVERYTHING IS COMPUTED HERE. Every rupee, percentage, label and plural on the
-- POS screen is a string built in this file. Dart adds nothing up.
--
-- The offline story: `pos_commit_sale` is keyed on a client-generated
-- `client_action_id`. The counter keeps billing with no network, replays when it
-- returns, and a replayed sale RESOLVES to the row it already wrote instead of
-- writing a second bill. Same invoice number, same PDF, applied once.
--
-- Downstream (built separately, events designed now):
--   * #412 pharmacy auto-inventory consumes `pos_sale_event` 'sale.completed'
--     to decrement shelf stock.
--   * #416 pharmacy GST pack reads `pos_sales` / `pos_sale_lines` as the SALES
--     register (the purchase register is the mediBO side).

-- ─────────────────────────── 1. TABLES ──────────────────────────────────────

create table if not exists public.pos_sales (
  id                 uuid primary key default gen_random_uuid(),
  pharmacy_id        uuid not null references public.pharmacy_profiles(id) on delete cascade,

  -- Sequential per pharmacy, per financial year. Never global, never reused.
  fy                 text not null,
  invoice_seq        bigint not null,
  invoice_no         text not null,

  sold_at            timestamptz not null default now(),
  sold_on            date not null,                    -- IST calendar day
  status             text not null default 'completed'
                     check (status in ('completed','void')),

  -- Who rang it up. #408 (pharmacy staff logins) is a separate command; until it
  -- lands this is the signed-in account. The column is the auth user either way,
  -- so #408's staff table joins onto it without a backfill.
  staff_user_id      uuid,
  staff_label        text,

  patient_name       text,
  patient_phone      text,

  payment_mode       text not null default 'cash'
                     check (payment_mode in ('cash','upi','card','credit')),

  -- Money. All INR, all 2dp, all computed by pos_price_bill().
  gross_amount       numeric(12,2) not null default 0,  -- sum of qty * mrp
  line_discount      numeric(12,2) not null default 0,
  bill_discount_pct  numeric(6,3)  not null default 0,
  bill_discount      numeric(12,2) not null default 0,
  taxable            numeric(12,2) not null default 0,
  cgst               numeric(12,2) not null default 0,
  sgst               numeric(12,2) not null default 0,
  igst               numeric(12,2) not null default 0,
  round_off          numeric(12,2) not null default 0,
  net_amount         numeric(12,2) not null default 0,

  -- Offline replay. UNIQUE is the whole mechanism: a replayed commit collides
  -- and is answered with the sale that already exists.
  client_action_id   uuid not null unique,

  -- The receipt PDF, drawn by the bill-render edge function.
  pdf_status         text not null default 'none'
                     check (pdf_status in ('none','queued','ready','failed')),
  pdf_bucket         text,
  pdf_path           text,
  pdf_name           text,
  pdf_bytes          integer,
  pdf_error          text,
  pdf_requested_at   timestamptz,
  pdf_ready_at       timestamptz,

  created_at         timestamptz not null default now(),
  unique (pharmacy_id, fy, invoice_seq)
);

create index if not exists pos_sales_shop_day_idx
  on public.pos_sales (pharmacy_id, sold_on desc, sold_at desc);
create index if not exists pos_sales_staff_idx
  on public.pos_sales (pharmacy_id, staff_user_id, sold_on desc);

create table if not exists public.pos_sale_lines (
  id            uuid primary key default gen_random_uuid(),
  sale_id       uuid not null references public.pos_sales(id) on delete cascade,
  line_no       integer not null,

  medicine_id   bigint,                -- null = a free-text counter item
  product_name  text not null,
  pack_label    text,
  hsn           text,
  batch_no      text,
  expiry        text,

  qty           numeric(12,3) not null check (qty > 0),
  mrp           numeric(12,2) not null check (mrp >= 0),
  disc_pct      numeric(6,3)  not null default 0,
  disc_amount   numeric(12,2) not null default 0,
  gross         numeric(12,2) not null default 0,   -- qty * mrp
  amount        numeric(12,2) not null default 0,   -- gross - disc (GST-inclusive)
  gst_percent   numeric(6,2)  not null default 0,
  taxable       numeric(12,2) not null default 0,   -- back-calculated out of amount
  cgst          numeric(12,2) not null default 0,
  sgst          numeric(12,2) not null default 0,
  igst          numeric(12,2) not null default 0,

  unique (sale_id, line_no)
);

create index if not exists pos_sale_lines_sale_idx on public.pos_sale_lines (sale_id, line_no);
create index if not exists pos_sale_lines_med_idx  on public.pos_sale_lines (medicine_id);

-- Per-pharmacy invoice counter. Advanced under a row lock inside the commit.
create table if not exists public.pos_invoice_counter (
  pharmacy_id uuid not null references public.pharmacy_profiles(id) on delete cascade,
  fy          text not null,
  next_no     bigint not null default 1,
  primary key (pharmacy_id, fy)
);

-- The event stream the shop-management layer is built on. #412 (auto-inventory)
-- and #416 (GST sales register) consume these; both land separately, so the
-- rows accumulate from today and neither has to backfill.
create table if not exists public.pos_sale_event (
  id          bigserial primary key,
  sale_id     uuid not null references public.pos_sales(id) on delete cascade,
  pharmacy_id uuid not null,
  event_type  text not null check (event_type in ('sale.completed','sale.void')),
  payload     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  consumed    jsonb not null default '{}'::jsonb   -- {"inventory":"2026-09-01T…"}
);
create index if not exists pos_sale_event_shop_idx
  on public.pos_sale_event (pharmacy_id, created_at desc);
create index if not exists pos_sale_event_unconsumed_idx
  on public.pos_sale_event (event_type, created_at) where consumed = '{}'::jsonb;

-- Per-pharmacy counter settings. One row, created on first use.
create table if not exists public.pos_settings (
  pharmacy_id       uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  invoice_prefix    text not null default 'INV',
  default_payment   text not null default 'cash',
  round_off_enabled boolean not null default true,
  updated_at        timestamptz not null default now()
);

alter table public.pos_sales          enable row level security;
alter table public.pos_sale_lines     enable row level security;
alter table public.pos_invoice_counter enable row level security;
alter table public.pos_sale_event     enable row level security;
alter table public.pos_settings       enable row level security;

-- No RLS policies by design: every read and write goes through the SECURITY
-- DEFINER RPCs below, each of which resolves the caller's own pharmacy with
-- pos_shop(). A direct PostgREST select on these tables returns nothing.

-- ─────────────────────────── 2. COPY ────────────────────────────────────────
-- Every user-visible string on the POS surface. Changing any word here is an
-- UPDATE, not a deploy.

insert into public.ui_copy (key, value) values
  ('pos.title',                 to_jsonb('Counter'::text)),
  ('pos.subtitle',              to_jsonb('Bill a walk-in patient'::text)),
  ('pos.nav_label',             to_jsonb('Counter (POS)'::text)),
  ('pos.search_hint',           to_jsonb('Search or scan a medicine'::text)),
  ('pos.search_empty',          to_jsonb('No medicine matched that.'::text)),
  ('pos.search_hint_short',     to_jsonb('Type at least 2 letters to search.'::text)),
  ('pos.cart_empty',            to_jsonb('No items yet'::text)),
  ('pos.cart_empty_hint',       to_jsonb('Search or scan a medicine to start the bill.'::text)),
  ('pos.qty_label',             to_jsonb('Qty'::text)),
  ('pos.disc_label',            to_jsonb('Disc %'::text)),
  ('pos.bill_disc_label',       to_jsonb('Bill discount %'::text)),
  ('pos.patient_name_label',    to_jsonb('Patient name (optional)'::text)),
  ('pos.patient_phone_label',   to_jsonb('Patient mobile (optional)'::text)),
  ('pos.pay_label',             to_jsonb('Payment'::text)),
  ('pos.pay_cash',              to_jsonb('Cash'::text)),
  ('pos.pay_upi',               to_jsonb('UPI'::text)),
  ('pos.pay_card',              to_jsonb('Card'::text)),
  ('pos.pay_credit',            to_jsonb('Credit'::text)),
  ('pos.save_button',           to_jsonb('Save bill'::text)),
  ('pos.saving',                to_jsonb('Saving…'::text)),
  ('pos.saved_toast',           to_jsonb('Bill saved'::text)),
  ('pos.replayed_toast',        to_jsonb('Already saved — showing the same bill'::text)),
  ('pos.remove',                to_jsonb('Remove'::text)),
  ('pos.gross_label',           to_jsonb('Gross'::text)),
  ('pos.line_disc_label',       to_jsonb('Item discount'::text)),
  ('pos.bill_disc_total_label', to_jsonb('Bill discount'::text)),
  ('pos.taxable_label',         to_jsonb('Taxable'::text)),
  ('pos.cgst_label',            to_jsonb('CGST'::text)),
  ('pos.sgst_label',            to_jsonb('SGST'::text)),
  ('pos.round_label',           to_jsonb('Round off'::text)),
  ('pos.net_label',             to_jsonb('Net payable'::text)),
  ('pos.mrp_note',              to_jsonb('Prices are MRP, inclusive of GST'::text)),
  ('pos.invoice_label',         to_jsonb('Invoice'::text)),
  ('pos.receipt_title',         to_jsonb('Receipt'::text)),
  ('pos.print_button',          to_jsonb('Print'::text)),
  ('pos.whatsapp_button',       to_jsonb('Send on WhatsApp'::text)),
  ('pos.building_message',      to_jsonb('Preparing the invoice…'::text)),
  ('pos.ready_message',         to_jsonb('Invoice ready'::text)),
  ('pos.pdf_failed',            to_jsonb('The invoice could not be prepared. Tap to try again.'::text)),
  ('pos.new_bill',              to_jsonb('New bill'::text)),
  ('pos.day_close_title',       to_jsonb('Day close'::text)),
  ('pos.day_close_bills',       to_jsonb('Bills'::text)),
  ('pos.day_close_sales',       to_jsonb('Sales'::text)),
  ('pos.day_close_cash',        to_jsonb('Cash'::text)),
  ('pos.day_close_upi',         to_jsonb('UPI'::text)),
  ('pos.day_close_card',        to_jsonb('Card'::text)),
  ('pos.day_close_credit',      to_jsonb('Credit'::text)),
  ('pos.day_close_empty',       to_jsonb('No bills yet today.'::text)),
  ('pos.day_close_empty_hint',  to_jsonb('Sales you ring up today will appear here.'::text)),
  ('pos.today_label',           to_jsonb('Today'::text)),
  ('pos.err_not_pharmacy',      to_jsonb('The counter is available on a pharmacy account.'::text)),
  ('pos.err_no_lines',          to_jsonb('Add at least one item before saving.'::text)),
  ('pos.err_bad_qty',           to_jsonb('Quantity must be more than zero.'::text)),
  ('pos.err_no_price',          to_jsonb('That medicine has no MRP on record — enter the item manually.'::text)),
  ('pos.err_not_found',         to_jsonb('That bill was not found.'::text)),
  ('pos.err_bad_phone',         to_jsonb('Enter a 10-digit mobile number.'::text)),
  ('pos.wa_queued',             to_jsonb('The invoice is on its way on WhatsApp.'::text)),
  ('pos.retry',                 to_jsonb('Retry'::text)),
  ('pos.boot_failed',           to_jsonb('The counter could not be reached. Check the connection and try again.'::text)),
  ('pos.staff_label',           to_jsonb('Billed by'::text))
on conflict (key) do nothing;

-- ─────────────────────── 3. THE PRICING ENGINE ──────────────────────────────

-- MEDICINE.mrp is TEXT ("₹123.50", "123", "" …). Never trust it to cast.
create or replace function public._pos_num(p text)
returns numeric language sql immutable as $$
  select nullif(regexp_replace(coalesce(p,''), '[^0-9.]', '', 'g'), '')::numeric;
$$;

-- The financial year an IST date falls in: 1 Apr → 31 Mar, printed '2026-27'.
create or replace function public._pos_fy(p_on date)
returns text language sql immutable as $$
  select case when extract(month from p_on) >= 4
              then to_char(p_on, 'YYYY') || '-' || to_char(p_on + interval '1 year', 'YY')
              else to_char(p_on - interval '1 year', 'YYYY') || '-' || to_char(p_on, 'YY')
         end;
$$;

create or replace function public._pos_today()
returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date; $$;

-- THE one place a retail bill is priced. Everything else calls this: the live
-- quote the counter renders while typing, and the commit that writes the rows.
-- Same input, same numbers — the saved bill can never disagree with the screen.
--
-- p_lines: [{medicine_id, product_name?, mrp?, qty, disc_pct?, batch_no?, expiry?}]
--   mrp is honoured ONLY for a free-text line (medicine_id null). For a catalog
--   line the price comes from MEDICINE — a client cannot post its own price.
create or replace function public.pos_price_bill(
  p_lines             jsonb,
  p_bill_discount_pct numeric default 0,
  p_round             boolean default true)
returns jsonb
language plpgsql stable
set search_path to 'public'
as $function$
declare
  v_in            jsonb;
  v_out           jsonb := '[]'::jsonb;
  v_n             integer := 0;
  v_bill_pct      numeric := least(greatest(coalesce(p_bill_discount_pct,0),0),100);
  v_mid           bigint;
  v_qty           numeric;
  v_disc_pct      numeric;
  v_mrp           numeric;
  v_gst           numeric;
  v_name          text;
  v_pack          text;
  v_gross         numeric;
  v_line_disc     numeric;
  v_pre           numeric;
  v_bill_disc     numeric;
  v_amount        numeric;
  v_taxable       numeric;
  v_gst_amt       numeric;
  v_cgst          numeric;
  v_sgst          numeric;
  t_gross         numeric := 0;
  t_line_disc     numeric := 0;
  t_bill_disc     numeric := 0;
  t_amount        numeric := 0;
  t_taxable       numeric := 0;
  t_cgst          numeric := 0;
  t_sgst          numeric := 0;
  v_round         numeric := 0;
  v_net           numeric;
  v_qty_total     numeric := 0;
  v_slabs         jsonb;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_lines',
      'message', public.ui_text('pos.err_no_lines'));
  end if;

  for v_in in select * from jsonb_array_elements(p_lines) loop
    v_n   := v_n + 1;
    v_qty := coalesce((v_in->>'qty')::numeric, 0);
    if v_qty <= 0 then
      return jsonb_build_object('ok', false, 'error', 'bad_qty',
        'message', public.ui_text('pos.err_bad_qty'));
    end if;
    v_disc_pct := least(greatest(coalesce((v_in->>'disc_pct')::numeric, 0), 0), 100);
    v_mid      := nullif(v_in->>'medicine_id','')::bigint;

    if v_mid is not null then
      -- Catalog line: the price and the tax rate come from the catalog, never
      -- from the client.
      select m.product_name,
             public._pos_num(m.mrp),
             -- NOT m.gst_percent directly: it is null across the whole catalog,
             -- and a 0% tax invoice is not a legal one. See _pos_gst_for().
             coalesce(public._pos_gst_for(m.id), 0)::numeric,
             nullif(btrim(coalesce(m.pack_size, m.pack_type, '')), '')
        into v_name, v_mrp, v_gst, v_pack
        from public."MEDICINE" m where m.id = v_mid;
      if v_name is null then
        return jsonb_build_object('ok', false, 'error', 'unknown_medicine',
          'message', public.ui_text('pos.err_not_found'));
      end if;
      if v_mrp is null or v_mrp <= 0 then
        return jsonb_build_object('ok', false, 'error', 'no_price',
          'message', public.ui_text('pos.err_no_price'));
      end if;
    else
      -- Free-text counter item (a non-catalog SKU). Here the operator IS the
      -- source of the price, so the payload carries it.
      v_name := nullif(btrim(coalesce(v_in->>'product_name','')),'');
      v_mrp  := coalesce((v_in->>'mrp')::numeric, 0);
      v_gst  := coalesce((v_in->>'gst_percent')::numeric, 0);
      v_pack := nullif(btrim(coalesce(v_in->>'pack_label','')),'');
      if v_name is null then
        return jsonb_build_object('ok', false, 'error', 'unknown_medicine',
          'message', public.ui_text('pos.err_not_found'));
      end if;
      if v_mrp <= 0 then
        return jsonb_build_object('ok', false, 'error', 'no_price',
          'message', public.ui_text('pos.err_no_price'));
      end if;
    end if;

    v_gross     := round(v_qty * v_mrp, 2);
    v_line_disc := round(v_gross * v_disc_pct / 100.0, 2);
    v_pre       := v_gross - v_line_disc;
    -- The bill discount is spread across the lines BEFORE the tax is split out,
    -- so the CGST/SGST on the invoice is the tax on what the patient actually
    -- pays. Splitting tax on the pre-discount amount would over-report GST.
    v_bill_disc := round(v_pre * v_bill_pct / 100.0, 2);
    v_amount    := v_pre - v_bill_disc;

    -- MRP is GST-INCLUSIVE: back-calculate, never add on top.
    v_taxable := round(v_amount / (1 + v_gst / 100.0), 2);
    v_gst_amt := v_amount - v_taxable;
    v_cgst    := round(v_gst_amt / 2.0, 2);
    v_sgst    := v_gst_amt - v_cgst;   -- absorbs the odd paisa, never drifts

    t_gross     := t_gross     + v_gross;
    t_line_disc := t_line_disc + v_line_disc;
    t_bill_disc := t_bill_disc + v_bill_disc;
    t_amount    := t_amount    + v_amount;
    t_taxable   := t_taxable   + v_taxable;
    t_cgst      := t_cgst      + v_cgst;
    t_sgst      := t_sgst      + v_sgst;
    v_qty_total := v_qty_total + v_qty;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'line_no',      v_n,
      'medicine_id',  v_mid,
      'product_name', v_name,
      'pack_label',   v_pack,
      'batch_no',     nullif(btrim(coalesce(v_in->>'batch_no','')),''),
      'expiry',       nullif(btrim(coalesce(v_in->>'expiry','')),''),
      'qty',          v_qty,
      'qty_label',    public._pos_dec(v_qty),
      'mrp',          v_mrp,
      'mrp_display',  public.inr_money(v_mrp),
      'disc_pct',     v_disc_pct,
      'disc_display', case when v_disc_pct > 0
                           then public._pos_dec(v_disc_pct) || '%' else null end,
      'disc_amount',  v_line_disc,
      'gross',        v_gross,
      'amount',       v_amount,
      'amount_display', public.inr_money(v_amount),
      'gst_percent',  v_gst,
      'gst_label',    public._pos_dec(v_gst) || '%',
      'taxable',      v_taxable,
      'cgst',         v_cgst,
      'sgst',         v_sgst,
      'igst',         0));
  end loop;

  -- Round the bill to the nearest rupee (the counter hands over notes/coins).
  if coalesce(p_round, true) then
    v_net   := round(t_amount, 0);
    v_round := v_net - t_amount;
  else
    v_net   := t_amount;
    v_round := 0;
  end if;

  -- The HSN/GST-rate ladder the invoice prints, one row per distinct rate.
  select coalesce(jsonb_agg(s order by (s->>'gst_percent')::numeric), '[]'::jsonb)
    into v_slabs
    from (
      select jsonb_build_object(
               'gst_percent',  (l->>'gst_percent')::numeric,
               'rate_label',   (l->>'gst_label'),
               'taxable',      sum((l->>'taxable')::numeric),
               'taxable_display', public.inr_money(sum((l->>'taxable')::numeric)),
               'cgst',         sum((l->>'cgst')::numeric),
               'cgst_display', public.inr_money(sum((l->>'cgst')::numeric)),
               'sgst',         sum((l->>'sgst')::numeric),
               'sgst_display', public.inr_money(sum((l->>'sgst')::numeric))) as s
        from jsonb_array_elements(v_out) l
       group by (l->>'gst_percent')::numeric, (l->>'gst_label')
    ) q;

  return jsonb_build_object(
    'ok', true,
    'lines', v_out,
    'totals', jsonb_build_object(
      'item_count',        v_n,
      'item_count_label',  v_n::text || case when v_n = 1 then ' item' else ' items' end,
      'qty_total',         v_qty_total,
      'qty_total_label',   public._pos_dec(v_qty_total),
      'gross',             round(t_gross,2),
      'gross_display',     public.inr_money(round(t_gross,2)),
      'line_discount',     round(t_line_disc,2),
      'line_discount_display', public.inr_money(round(t_line_disc,2)),
      'has_line_discount', t_line_disc > 0,
      'bill_discount_pct', v_bill_pct,
      'bill_discount',     round(t_bill_disc,2),
      'bill_discount_display', public.inr_money(round(t_bill_disc,2)),
      'has_bill_discount', t_bill_disc > 0,
      'taxable',           round(t_taxable,2),
      'taxable_display',   public.inr_money(round(t_taxable,2)),
      'cgst',              round(t_cgst,2),
      'cgst_display',      public.inr_money(round(t_cgst,2)),
      'sgst',              round(t_sgst,2),
      'sgst_display',      public.inr_money(round(t_sgst,2)),
      'igst',              0,
      'round_off',         round(v_round,2),
      'round_off_display', public.inr_money(round(v_round,2)),
      'has_round_off',     round(v_round,2) <> 0,
      'net_amount',        round(v_net,2),
      'net_display',       public.inr_money(round(v_net,2)),
      'net_words',         public.inr_words(round(v_net,2)),
      'mrp_note',          public.ui_text('pos.mrp_note')),
    'tax_slabs', v_slabs);
end $function$;

-- ─────────────────────── 4. THE COUNTER RPCs ────────────────────────────────

-- The one resolver. A pharmacy IS a customer account, so my_customer_id() is
-- the answer — and because that function reads `login_identities`, the staff
-- logins from #408 (owner_type='customer') will resolve to their shop here with
-- no change to this file.
create or replace function public.pos_shop()
returns uuid language sql stable security definer
set search_path to 'public' as $$ select public.my_customer_id(); $$;

create or replace function public._pos_denied()
returns jsonb language sql stable
set search_path to 'public' as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('pos.err_not_pharmacy'));
$$;

-- The invoice header: the PHARMACY's own identity, never mediBO's.
create or replace function public._pos_header(p_shop uuid)
returns jsonb language plpgsql stable
set search_path to 'public' as $function$
declare pp public.pharmacy_profiles%rowtype; v_gst text; v_dl text;
begin
  select * into pp from public.pharmacy_profiles where id = p_shop;
  if not found then return '{}'::jsonb; end if;
  v_gst := nullif(btrim(coalesce(pp.gstin, pp.gst_no, '')), '');
  v_dl  := nullif(btrim(concat_ws(' / ', nullif(btrim(coalesce(pp.dl_20b,'')),''),
                                          nullif(btrim(coalesce(pp.dl_21b,'')),''))), '');
  if v_dl is null then v_dl := nullif(btrim(coalesce(pp.drug_license,'')),''); end if;
  return jsonb_build_object(
    'pharmacy_id',  pp.id,
    'name',         pp.pharmacy_name,
    'address',      btrim(concat_ws(', ',
                      nullif(btrim(coalesce(pp.address,'')),''),
                      nullif(btrim(coalesce(pp.city,'')),''),
                      nullif(btrim(coalesce(pp.state,'')),''),
                      nullif(btrim(coalesce(pp.pincode,'')),''))),
    'phone',        nullif(btrim(coalesce(pp.phone, pp.whatsapp_no, '')),''),
    'gstin',        v_gst,
    'gstin_label',  case when v_gst is not null then 'GSTIN: ' || v_gst else null end,
    'has_gstin',    v_gst is not null,
    'drug_license', v_dl,
    'dl_label',     case when v_dl is not null then 'D.L. No.: ' || v_dl else null end,
    'has_dl',       v_dl is not null);
end $function$;

-- Settings, read-only with defaults. A shop that has never opened the counter
-- has no row yet and must still get a working payload — so the defaults live
-- HERE rather than in an insert, which also keeps every read path STABLE.
create or replace function public._pos_settings(p_shop uuid)
returns jsonb language sql stable
set search_path to 'public' as $$
  select jsonb_build_object(
    'invoice_prefix',    coalesce(s.invoice_prefix, 'INV'),
    'default_payment',   coalesce(s.default_payment, 'cash'),
    'round_off_enabled', coalesce(s.round_off_enabled, true))
  from (select 1) one
  left join public.pos_settings s on s.pharmacy_id = p_shop;
$$;

-- ── pos_home: the counter boots from exactly one call ───────────────────────
create or replace function public.pos_home()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  v_today date := public._pos_today();
  v_bills int; v_net numeric;
begin
  if v_shop is null then return public._pos_denied(); end if;

  select count(*), coalesce(sum(net_amount),0) into v_bills, v_net
    from public.pos_sales
   where pharmacy_id = v_shop and sold_on = v_today and status = 'completed';

  return jsonb_build_object(
    'ok', true,
    'header', public._pos_header(v_shop),
    'labels', jsonb_build_object(
      'title',            public.ui_text('pos.title'),
      'subtitle',         public.ui_text('pos.subtitle'),
      'search_hint',      public.ui_text('pos.search_hint'),
      'search_empty',     public.ui_text('pos.search_empty'),
      'search_min',       public.ui_text('pos.search_hint_short'),
      'cart_empty',       public.ui_text('pos.cart_empty'),
      'cart_empty_hint',  public.ui_text('pos.cart_empty_hint'),
      'qty',              public.ui_text('pos.qty_label'),
      'disc',             public.ui_text('pos.disc_label'),
      'bill_disc',        public.ui_text('pos.bill_disc_label'),
      'patient_name',     public.ui_text('pos.patient_name_label'),
      'patient_phone',    public.ui_text('pos.patient_phone_label'),
      'pay',              public.ui_text('pos.pay_label'),
      'save',             public.ui_text('pos.save_button'),
      'saving',           public.ui_text('pos.saving'),
      'remove',           public.ui_text('pos.remove'),
      'gross',            public.ui_text('pos.gross_label'),
      'line_discount',    public.ui_text('pos.line_disc_label'),
      'bill_discount',    public.ui_text('pos.bill_disc_total_label'),
      'taxable',          public.ui_text('pos.taxable_label'),
      'cgst',             public.ui_text('pos.cgst_label'),
      'sgst',             public.ui_text('pos.sgst_label'),
      'round_off',        public.ui_text('pos.round_label'),
      'net',              public.ui_text('pos.net_label'),
      'mrp_note',         public.ui_text('pos.mrp_note'),
      'new_bill',         public.ui_text('pos.new_bill'),
      'day_close',        public.ui_text('pos.day_close_title'),
      'today',            public.ui_text('pos.today_label'),
      'retry',            public.ui_text('pos.retry')),
    'payment_modes', jsonb_build_array(
      jsonb_build_object('key','cash',  'label', public.ui_text('pos.pay_cash')),
      jsonb_build_object('key','upi',   'label', public.ui_text('pos.pay_upi')),
      jsonb_build_object('key','card',  'label', public.ui_text('pos.pay_card')),
      jsonb_build_object('key','credit','label', public.ui_text('pos.pay_credit'))),
    'default_payment', public._pos_settings(v_shop)->>'default_payment',
    'search_min_chars', 2,
    'today_strip', jsonb_build_object(
      'bills',        v_bills,
      'bills_label',  v_bills::text || case when v_bills = 1 then ' bill' else ' bills' end,
      'net',          v_net,
      'net_display',  public.inr_money(v_net),
      'has_any',      v_bills > 0,
      'date_label',   to_char(v_today, 'DD Mon YYYY')));
end $function$;

-- ── pos_search / pos_scan: the counter's two ways to add a line ─────────────
-- Both ride the existing normalised indexes (_norm_name prefix, _norm_barcode),
-- so neither ever scans the 563k-row catalog.
create or replace function public.pos_search(p_q text, p_limit integer default 20)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  v_q text := btrim(coalesce(p_q,''));
  v_norm text; v_rows jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  if length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb,
      'message', public.ui_text('pos.search_hint_short'));
  end if;
  v_norm := public._norm_name(v_q);

  select coalesce(jsonb_agg(r order by r_sales desc nulls last, r_name), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'medicine_id',  m.id,
               'product_name', m.product_name,
               'pack_label',   nullif(btrim(coalesce(m.pack_size, m.pack_type,'')),''),
               'marketer',     nullif(btrim(coalesce(m.marketer,'')),''),
               'mrp',          public._pos_num(m.mrp),
               'mrp_display',  case when public._pos_num(m.mrp) is not null
                                    then public.inr_money(public._pos_num(m.mrp)) else null end,
               'has_mrp',      public._pos_num(m.mrp) is not null and public._pos_num(m.mrp) > 0,
               'gst_percent',  public._pos_gst_for(m.id),
               'gst_label',    public._pos_dec(public._pos_gst_for(m.id)) || '%',
               'rx_required',  coalesce(m.rx_required,'') ilike '%yes%') as r,
             m.sales_count as r_sales, m.product_name as r_name
        from public."MEDICINE" m
       where public._norm_name(m.product_name) like v_norm || '%'
       order by m.sales_count desc nulls last, m.product_name
       limit greatest(least(coalesce(p_limit,20), 50), 1)
    ) q;

  return jsonb_build_object('ok', true, 'rows', v_rows,
    'empty_message', public.ui_text('pos.search_empty'));
end $function$;

create or replace function public.pos_scan(p_barcode text)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  v_code text := public._norm_barcode(coalesce(p_barcode,''));
  v_row jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  if coalesce(v_code,'') = '' then
    return jsonb_build_object('ok', false, 'error', 'no_barcode',
      'message', public.ui_text('pos.search_empty'));
  end if;

  select jsonb_build_object(
           'medicine_id',  m.id,
           'product_name', m.product_name,
           'pack_label',   nullif(btrim(coalesce(m.pack_size, m.pack_type,'')),''),
           'mrp',          public._pos_num(m.mrp),
           'mrp_display',  case when public._pos_num(m.mrp) is not null
                                then public.inr_money(public._pos_num(m.mrp)) else null end,
           'has_mrp',      public._pos_num(m.mrp) is not null and public._pos_num(m.mrp) > 0,
           'gst_percent',  public._pos_gst_for(m.id),
           'gst_label',    public._pos_dec(public._pos_gst_for(m.id)) || '%')
    into v_row
    from public."MEDICINE" m
   where public._norm_barcode(m.barcode) = v_code
   limit 1;

  if v_row is null then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('pos.search_empty'));
  end if;
  return jsonb_build_object('ok', true, 'row', v_row);
end $function$;

-- ── pos_quote: the live bill while the operator types. Same engine as commit ─
create or replace function public.pos_quote(p_lines jsonb, p_bill_discount_pct numeric default 0)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop();
begin
  if v_shop is null then return public._pos_denied(); end if;
  return public.pos_price_bill(p_lines, p_bill_discount_pct,
                               (public._pos_settings(v_shop)->>'round_off_enabled')::boolean);
end $function$;

-- ── pos_commit_sale: the bill is written HERE, exactly once ─────────────────
--
-- THE OFFLINE CONTRACT. The counter mints a `client_action_id` (a uuid) when
-- the operator taps Save — BEFORE it knows whether the network is up. It stores
-- the pending sale locally and posts it; if the post fails, it posts the same
-- payload with the SAME id later. Because `client_action_id` is UNIQUE:
--   * first arrival  → a sale is written, `replayed:false`
--   * every re-arrival → the sale already there is returned, `replayed:true`,
--     with the same invoice number and the same PDF. Never a duplicate bill,
--     never a burnt invoice number, no matter how many times the queue retries.
-- This is why the invoice number is claimed INSIDE the same transaction as the
-- insert: a crash between the two would otherwise leave a hole in a statutory
-- sequence.
create or replace function public.pos_commit_sale(
  p_client_action_id  uuid,
  p_lines             jsonb,
  p_bill_discount_pct numeric default 0,
  p_payment_mode      text    default 'cash',
  p_patient           jsonb   default '{}'::jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $function$
declare
  v_shop     uuid := public.pos_shop();
  v_existing public.pos_sales%rowtype;
  v_priced   jsonb;
  v_tot      jsonb;
  v_line     jsonb;
  v_today    date := public._pos_today();
  v_fy       text;
  v_seq      bigint;
  v_prefix   text;
  v_no       text;
  v_sale     uuid;
  v_mode     text := lower(btrim(coalesce(p_payment_mode,'cash')));
  v_staff    uuid := auth.uid();
  v_staff_lb text;
begin
  if v_shop is null then return public._pos_denied(); end if;
  if p_client_action_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_action_id',
      'message', public.ui_text('pos.err_no_lines'));
  end if;

  -- REPLAY: this bill is already on the books. Answer with it, write nothing.
  select * into v_existing from public.pos_sales
   where client_action_id = p_client_action_id;
  if found then
    if v_existing.pharmacy_id <> v_shop then return public._pos_denied(); end if;
    return public.pos_sale_detail(v_existing.id) || jsonb_build_object(
      'replayed', true, 'message', public.ui_text('pos.replayed_toast'));
  end if;

  if v_mode not in ('cash','upi','card','credit') then v_mode := 'cash'; end if;

  v_priced := public.pos_price_bill(p_lines, p_bill_discount_pct,
                (public._pos_settings(v_shop)->>'round_off_enabled')::boolean);
  if coalesce(v_priced->>'ok','false') <> 'true' then return v_priced; end if;
  v_tot := v_priced->'totals';

  v_fy     := public._pos_fy(v_today);
  v_prefix := public._pos_settings(v_shop)->>'invoice_prefix';

  -- Claim the next number under a row lock, in THIS transaction.
  insert into public.pos_invoice_counter(pharmacy_id, fy, next_no)
  values (v_shop, v_fy, 1)
  on conflict (pharmacy_id, fy) do nothing;

  update public.pos_invoice_counter
     set next_no = next_no + 1
   where pharmacy_id = v_shop and fy = v_fy
  returning next_no - 1 into v_seq;

  v_no := v_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 5, '0');

  select coalesce(nullif(btrim(coalesce(pp.owner_name, pp.customer_name, '')), ''),
                  pp.pharmacy_name)
    into v_staff_lb from public.pharmacy_profiles pp where pp.id = v_shop;

  insert into public.pos_sales(
      pharmacy_id, fy, invoice_seq, invoice_no, sold_at, sold_on, status,
      staff_user_id, staff_label, patient_name, patient_phone, payment_mode,
      gross_amount, line_discount, bill_discount_pct, bill_discount,
      taxable, cgst, sgst, igst, round_off, net_amount, client_action_id)
  values (
      v_shop, v_fy, v_seq, v_no, now(), v_today, 'completed',
      v_staff, v_staff_lb,
      nullif(btrim(coalesce(p_patient->>'name','')),''),
      nullif(regexp_replace(coalesce(p_patient->>'phone',''),'\D','','g'),''),
      v_mode,
      (v_tot->>'gross')::numeric, (v_tot->>'line_discount')::numeric,
      (v_tot->>'bill_discount_pct')::numeric, (v_tot->>'bill_discount')::numeric,
      (v_tot->>'taxable')::numeric, (v_tot->>'cgst')::numeric,
      (v_tot->>'sgst')::numeric, (v_tot->>'igst')::numeric,
      (v_tot->>'round_off')::numeric, (v_tot->>'net_amount')::numeric,
      p_client_action_id)
  returning id into v_sale;

  for v_line in select * from jsonb_array_elements(v_priced->'lines') loop
    insert into public.pos_sale_lines(
        sale_id, line_no, medicine_id, product_name, pack_label, batch_no, expiry,
        qty, mrp, disc_pct, disc_amount, gross, amount,
        gst_percent, taxable, cgst, sgst, igst)
    values (
        v_sale, (v_line->>'line_no')::int,
        nullif(v_line->>'medicine_id','')::bigint,
        v_line->>'product_name', v_line->>'pack_label',
        v_line->>'batch_no', v_line->>'expiry',
        (v_line->>'qty')::numeric, (v_line->>'mrp')::numeric,
        (v_line->>'disc_pct')::numeric, (v_line->>'disc_amount')::numeric,
        (v_line->>'gross')::numeric, (v_line->>'amount')::numeric,
        (v_line->>'gst_percent')::numeric, (v_line->>'taxable')::numeric,
        (v_line->>'cgst')::numeric, (v_line->>'sgst')::numeric,
        (v_line->>'igst')::numeric);
  end loop;

  -- The event the rest of the shop layer is built on. #412 decrements shelf
  -- stock from `lines`; #416 reads the same row as the sales register. Written
  -- now so neither has to backfill the day it ships.
  insert into public.pos_sale_event(sale_id, pharmacy_id, event_type, payload)
  values (v_sale, v_shop, 'sale.completed', jsonb_build_object(
    'invoice_no', v_no, 'sold_on', v_today, 'net_amount', (v_tot->>'net_amount')::numeric,
    'payment_mode', v_mode, 'staff_user_id', v_staff,
    'lines', (select coalesce(jsonb_agg(jsonb_build_object(
                'medicine_id', (l->>'medicine_id'), 'qty', (l->>'qty')::numeric,
                'amount', (l->>'amount')::numeric)), '[]'::jsonb)
                from jsonb_array_elements(v_priced->'lines') l)));

  -- Draw the receipt straight away; the screen polls for it.
  perform public.pos_invoice_request(v_sale);

  return public.pos_sale_detail(v_sale) || jsonb_build_object(
    'replayed', false, 'message', public.ui_text('pos.saved_toast'));
end $function$;

-- ── pos_sale_detail: the receipt screen, and the commit's own answer ────────
create or replace function public.pos_sale_detail(p_sale_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  s public.pos_sales%rowtype;
  v_lines jsonb; v_slabs jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  select * into s from public.pos_sales where id = p_sale_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('pos.err_not_found'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'line_no', l.line_no, 'medicine_id', l.medicine_id,
           'product_name', l.product_name, 'pack_label', l.pack_label,
           'batch_no', l.batch_no, 'expiry', l.expiry,
           'qty', l.qty, 'qty_label', public._pos_dec(l.qty),
           'mrp', l.mrp, 'mrp_display', public.inr_money(l.mrp),
           'disc_pct', l.disc_pct,
           'disc_display', case when l.disc_pct > 0
                                then public._pos_dec(l.disc_pct) || '%' else null end,
           'gst_percent', l.gst_percent,
           'gst_label', public._pos_dec(l.gst_percent) || '%',
           'taxable', l.taxable, 'cgst', l.cgst, 'sgst', l.sgst,
           'amount', l.amount, 'amount_display', public.inr_money(l.amount))
         order by l.line_no), '[]'::jsonb)
    into v_lines from public.pos_sale_lines l where l.sale_id = s.id;

  -- One row per distinct GST rate — the ladder a tax invoice must print.
  select coalesce(jsonb_agg(q.js order by q.rate), '[]'::jsonb)
    into v_slabs
    from (select l.gst_percent as rate,
                 jsonb_build_object(
                   'rate_label',      public._pos_dec(l.gst_percent) || '%',
                   'taxable_display', public.inr_money(sum(l.taxable)),
                   'cgst_display',    public.inr_money(sum(l.cgst)),
                   'sgst_display',    public.inr_money(sum(l.sgst))) as js
            from public.pos_sale_lines l
           where l.sale_id = s.id
           group by l.gst_percent) q;

  return jsonb_build_object(
    'ok', true,
    'sale_id', s.id,
    'header', public._pos_header(v_shop),
    'invoice', jsonb_build_object(
      'number',      s.invoice_no,
      'number_label', public.ui_text('pos.invoice_label') || ' ' || s.invoice_no,
      'date_label',  to_char(s.sold_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, hh12:mi AM'),
      'staff_label', case when s.staff_label is not null
                         then public.ui_text('pos.staff_label') || ': ' || s.staff_label else null end,
      'patient_name', s.patient_name,
      'patient_phone', s.patient_phone,
      'has_patient', s.patient_name is not null or s.patient_phone is not null,
      'payment_label', public.ui_text('pos.pay_' || s.payment_mode),
      'payment_mode', s.payment_mode),
    'lines', v_lines,
    'tax_slabs', coalesce(v_slabs,'[]'::jsonb),
    'totals', jsonb_build_object(
      'gross_display',         public.inr_money(s.gross_amount),
      'line_discount_display', public.inr_money(s.line_discount),
      'has_line_discount',     s.line_discount > 0,
      'bill_discount_display', public.inr_money(s.bill_discount),
      'has_bill_discount',     s.bill_discount > 0,
      'taxable_display',       public.inr_money(s.taxable),
      'cgst_display',          public.inr_money(s.cgst),
      'sgst_display',          public.inr_money(s.sgst),
      'round_off_display',     public.inr_money(s.round_off),
      'has_round_off',         s.round_off <> 0,
      'net_display',           public.inr_money(s.net_amount),
      'net_words',             public.inr_words(s.net_amount),
      'mrp_note',              public.ui_text('pos.mrp_note')),
    'receipt', jsonb_build_object(
      'status',      s.pdf_status,
      'is_ready',    s.pdf_status = 'ready',
      'is_building', s.pdf_status in ('queued','none'),
      'failed',      s.pdf_status = 'failed',
      'bucket',      s.pdf_bucket,
      'path',        s.pdf_path,
      'file_name',   s.pdf_name,
      'expires_s',   300,
      'poll_ms',     1500,
      'message',     case s.pdf_status
                       when 'ready'  then public.ui_text('pos.ready_message')
                       when 'failed' then public.ui_text('pos.pdf_failed')
                       else public.ui_text('pos.building_message') end,
      'print_label',    public.ui_text('pos.print_button'),
      'whatsapp_label', public.ui_text('pos.whatsapp_button')));
end $function$;

-- ─────────────────── 5. THE RECEIPT PDF (bill-render) ───────────────────────
-- Same shape as supplier_doc_request/report (#403): the RPC asks, the edge
-- function draws and stores, the screen polls on the backend's own poll_ms and
-- opens the backend's own bucket+path. The screen never builds a URL and never
-- invents a timeout.

create or replace function public.pos_invoice_request(p_sale_id uuid)
returns jsonb language plpgsql security definer
set search_path to 'public', 'net' as $function$
declare s public.pos_sales%rowtype;
begin
  select * into s from public.pos_sales where id = p_sale_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('pos.err_not_found'));
  end if;
  -- Called straight from pos_commit_sale (already scoped) and from the screen's
  -- retry, which must be the sale's own shop.
  if public.pos_shop() is not null and s.pharmacy_id <> public.pos_shop() then
    return public._pos_denied();
  end if;

  if s.pdf_status = 'ready' and coalesce(s.pdf_path,'') <> '' then
    return jsonb_build_object('ok', true, 'status', 'ready', 'sale_id', s.id,
      'bucket', s.pdf_bucket, 'path', s.pdf_path, 'file_name', s.pdf_name,
      'expires_s', 300, 'message', public.ui_text('pos.ready_message'));
  end if;

  update public.pos_sales
     set pdf_status = 'queued', pdf_error = null, pdf_requested_at = now()
   where id = s.id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/pos-invoice',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('pos_sale_id', s.id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status', 'building', 'sale_id', s.id,
    'poll_ms', 1500, 'message', public.ui_text('pos.building_message'));
end $function$;

-- What the renderer draws. It computes NOTHING — every label, number and column
-- below is already a finished string.
create or replace function public.pos_invoice_render_input(p_sale_id uuid)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  s public.pos_sales%rowtype; v jsonb; v_lines jsonb; v_slabs jsonb;
begin
  select * into s from public.pos_sales where id = p_sale_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sn',      l.line_no,
           'product', l.product_name,
           'pack',    coalesce(l.pack_label,''),
           'batch_no', coalesce(l.batch_no,''),
           'expiry',  coalesce(l.expiry,''),
           'qty',     public._pos_dec(l.qty),
           'mrp',     public.inr_money(l.mrp),
           'disc',    case when l.disc_pct > 0
                           then public._pos_dec(l.disc_pct) || '%' else '' end,
           'taxable', public.inr_money(l.taxable),
           'gst_pct', public._pos_dec(l.gst_percent) || '%',
           'gst_amt', public.inr_money(l.cgst + l.sgst + l.igst),
           'amount',  public.inr_money(l.amount))
         order by l.line_no), '[]'::jsonb)
    into v_lines from public.pos_sale_lines l where l.sale_id = s.id;

  select coalesce(jsonb_agg(q.js order by q.rate), '[]'::jsonb)
    into v_slabs
    from (select l.gst_percent as rate,
                 jsonb_build_object(
                   'rate',    public._pos_dec(l.gst_percent) || '%',
                   'taxable', public.inr_money(sum(l.taxable)),
                   'cgst',    public.inr_money(sum(l.cgst)),
                   'sgst',    public.inr_money(sum(l.sgst)),
                   'total',   public.inr_money(sum(l.cgst + l.sgst))) as js
            from public.pos_sale_lines l where l.sale_id = s.id
           group by l.gst_percent) q;

  v := jsonb_build_object(
    'title',  'TAX INVOICE',
    'seller', public._pos_header(s.pharmacy_id),
    'invoice', jsonb_build_object(
      'number',     s.invoice_no,
      'date',       to_char(s.sold_at at time zone 'Asia/Kolkata', 'DD Mon YYYY'),
      'time',       to_char(s.sold_at at time zone 'Asia/Kolkata', 'hh12:mi AM'),
      'payment',    public.ui_text('pos.pay_' || s.payment_mode),
      'staff',      coalesce(s.staff_label,''),
      'patient',    coalesce(s.patient_name,''),
      'patient_phone', coalesce(s.patient_phone,'')),
    'columns', jsonb_build_array(
      jsonb_build_object('key','sn','label','#'),
      jsonb_build_object('key','product','label','Item'),
      jsonb_build_object('key','pack','label','Pack'),
      jsonb_build_object('key','batch_no','label','Batch'),
      jsonb_build_object('key','expiry','label','Exp'),
      jsonb_build_object('key','qty','label','Qty','align','right'),
      jsonb_build_object('key','mrp','label','MRP','align','right'),
      jsonb_build_object('key','disc','label','Disc','align','right'),
      jsonb_build_object('key','taxable','label','Taxable','align','right'),
      jsonb_build_object('key','gst_pct','label','GST','align','right'),
      jsonb_build_object('key','gst_amt','label','Tax','align','right'),
      jsonb_build_object('key','amount','label','Amount','align','right')),
    'lines', v_lines,
    'tax_summary', v_slabs,
    'totals', jsonb_build_array(
      jsonb_build_object('label', public.ui_text('pos.gross_label'),
                         'value', public.inr_money(s.gross_amount)),
      jsonb_build_object('label', public.ui_text('pos.line_disc_label'),
                         'value', public.inr_money(s.line_discount),
                         'hide', s.line_discount = 0),
      jsonb_build_object('label', public.ui_text('pos.bill_disc_total_label'),
                         'value', public.inr_money(s.bill_discount),
                         'hide', s.bill_discount = 0),
      jsonb_build_object('label', public.ui_text('pos.taxable_label'),
                         'value', public.inr_money(s.taxable)),
      jsonb_build_object('label', public.ui_text('pos.cgst_label'),
                         'value', public.inr_money(s.cgst)),
      jsonb_build_object('label', public.ui_text('pos.sgst_label'),
                         'value', public.inr_money(s.sgst)),
      jsonb_build_object('label', public.ui_text('pos.round_label'),
                         'value', public.inr_money(s.round_off),
                         'hide', s.round_off = 0)),
    'net', jsonb_build_object('label', public.ui_text('pos.net_label'),
                              'value', public.inr_money(s.net_amount),
                              'words', public.inr_words(s.net_amount)),
    'footer', jsonb_build_object(
      'note',  public.ui_text('pos.mrp_note'),
      'items', (select count(*)::text from public.pos_sale_lines where sale_id = s.id) || ' item(s)'));

  return jsonb_build_object('ok', true,
    'invoice', v,
    'bucket', 'customer-bills',
    'path',   'pos/' || s.pharmacy_id::text || '/' || s.id::text || '.pdf',
    'file_name', 'Invoice-' || regexp_replace(s.invoice_no,'[^A-Za-z0-9-]','-','g') || '.pdf');
end $function$;

create or replace function public.pos_invoice_report(
  p_sale_id uuid, p_ok boolean,
  p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes integer default null,
  p_error text default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
begin
  if coalesce(p_ok,false) then
    update public.pos_sales
       set pdf_status = 'ready', pdf_bucket = p_bucket, pdf_path = p_path,
           pdf_name = p_name, pdf_bytes = p_bytes, pdf_error = null,
           pdf_ready_at = now()
     where id = p_sale_id;
  else
    update public.pos_sales
       set pdf_status = 'failed', pdf_error = left(coalesce(p_error,'render_failed'), 500)
     where id = p_sale_id;
  end if;
  return jsonb_build_object('ok', true, 'sale_id', p_sale_id);
end $function$;

-- Send the finished invoice to the patient on WhatsApp. Same window-gated
-- outbound path every other document uses.
create or replace function public.pos_invoice_wa(p_sale_id uuid, p_phone text default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  s public.pos_sales%rowtype;
  v_ph text; v jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  select * into s from public.pos_sales where id = p_sale_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('pos.err_not_found'));
  end if;

  v_ph := right(regexp_replace(coalesce(p_phone, s.patient_phone, ''), '\D', '', 'g'), 10);
  if length(v_ph) <> 10 then
    return jsonb_build_object('ok', false, 'error', 'bad_phone',
      'message', public.ui_text('pos.err_bad_phone'));
  end if;
  if s.pdf_status <> 'ready' then
    return jsonb_build_object('ok', false, 'error', 'not_ready',
      'message', public.ui_text('pos.building_message'));
  end if;

  v := public.wa_notify_event(
         'pos_invoice', null, '{}'::jsonb, v_ph, null,
         'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
         jsonb_build_object('event','pos_invoice', 'pos_sale_id', s.id,
                            'phone', v_ph, 'bucket', s.pdf_bucket, 'path', s.pdf_path,
                            'invoice_no', s.invoice_no));

  return jsonb_build_object('ok', true, 'status', 'queued',
    'sale_id', s.id, 'phone', v_ph,
    'message', public.ui_text('pos.wa_queued'));
end $function$;

-- ─────────────────────────── 6. DAY CLOSE ───────────────────────────────────
-- Today's counter, the way a pharmacist reads it at closing: how many bills,
-- how much, and how it was paid. Every number is a finished string.
create or replace function public.pos_day_close(p_date date default null)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public.pos_shop();
  v_on   date;
  v_bills int; v_net numeric; v_qty numeric;
  v_splits jsonb; v_recent jsonb; v_staff jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  v_on := coalesce(p_date, public._pos_today());

  select count(*), coalesce(sum(net_amount),0) into v_bills, v_net
    from public.pos_sales
   where pharmacy_id = v_shop and sold_on = v_on and status = 'completed';

  select coalesce(sum(l.qty),0) into v_qty
    from public.pos_sale_lines l join public.pos_sales s on s.id = l.sale_id
   where s.pharmacy_id = v_shop and s.sold_on = v_on and s.status = 'completed';

  -- Every mode always appears, zero included: a day-close that hides "UPI ₹0.00"
  -- makes the pharmacist wonder whether it is missing or zero.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   m.key,
           'label', public.ui_text('pos.pay_' || m.key),
           'bills', coalesce(t.bills,0),
           'bills_label', coalesce(t.bills,0)::text
                          || case when coalesce(t.bills,0) = 1 then ' bill' else ' bills' end,
           'amount', coalesce(t.amt,0),
           'amount_display', public.inr_money(coalesce(t.amt,0)))
         order by m.ord), '[]'::jsonb)
    into v_splits
    from (values ('cash',1),('upi',2),('card',3),('credit',4)) as m(key, ord)
    left join (
      select payment_mode, count(*) as bills, sum(net_amount) as amt
        from public.pos_sales
       where pharmacy_id = v_shop and sold_on = v_on and status = 'completed'
       group by payment_mode) t on t.payment_mode = m.key;

  select coalesce(jsonb_agg(jsonb_build_object(
           'sale_id', s.id, 'invoice_no', s.invoice_no,
           'time_label', to_char(s.sold_at at time zone 'Asia/Kolkata','hh12:mi AM'),
           'patient', coalesce(s.patient_name,''),
           'payment_label', public.ui_text('pos.pay_' || s.payment_mode),
           'net_display', public.inr_money(s.net_amount))
         order by s.sold_at desc), '[]'::jsonb)
    into v_recent
    from (select * from public.pos_sales
           where pharmacy_id = v_shop and sold_on = v_on and status = 'completed'
           order by sold_at desc limit 25) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'staff_label', coalesce(q.staff_label,'—'),
           'bills', q.bills,
           'amount_display', public.inr_money(q.amt)) order by q.amt desc), '[]'::jsonb)
    into v_staff
    from (select staff_label, count(*) as bills, sum(net_amount) as amt
            from public.pos_sales
           where pharmacy_id = v_shop and sold_on = v_on and status = 'completed'
           group by staff_label) q;

  return jsonb_build_object(
    'ok', true,
    'date', v_on,
    'date_label', to_char(v_on, 'DD Mon YYYY'),
    'title', public.ui_text('pos.day_close_title'),
    'has_any', v_bills > 0,
    'empty_message', public.ui_text('pos.day_close_empty'),
    'empty_hint', public.ui_text('pos.day_close_empty_hint'),
    'tiles', jsonb_build_array(
      jsonb_build_object('key','bills', 'label', public.ui_text('pos.day_close_bills'),
                         'value', v_bills::text),
      jsonb_build_object('key','sales', 'label', public.ui_text('pos.day_close_sales'),
                         'value', public.inr_money(v_net)),
      jsonb_build_object('key','items', 'label', 'Items',
                         'value', public._pos_dec(v_qty))),
    'splits', v_splits,
    'by_staff', v_staff,
    'recent', v_recent);
end $function$;

grant execute on function public.pos_home()                            to authenticated;
grant execute on function public.pos_search(text, integer)             to authenticated;
grant execute on function public.pos_scan(text)                        to authenticated;
grant execute on function public.pos_quote(jsonb, numeric)             to authenticated;
grant execute on function public.pos_commit_sale(uuid, jsonb, numeric, text, jsonb) to authenticated;
grant execute on function public.pos_sale_detail(uuid)                 to authenticated;
grant execute on function public.pos_invoice_request(uuid)             to authenticated;
grant execute on function public.pos_invoice_wa(uuid, text)            to authenticated;
grant execute on function public.pos_day_close(date)                   to authenticated;

-- ────────────────── 7. REACHABILITY (the entry point) ───────────────────────
-- The counter is a PHARMACY surface, so it hangs off the customer's own profile
-- menu rather than the admin dashboard (nav_registry's dashboard branch admits
-- only `admin.%` keys and partner features — a customer never sees a tile
-- there). One cheap call at boot decides whether the entry is drawn at all, and
-- supplies its words: Dart holds no label and makes no role test.
create or replace function public.pos_entry()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public.pos_shop();
begin
  if v_shop is null then
    return jsonb_build_object('ok', true, 'show', false);
  end if;
  return jsonb_build_object(
    'ok', true, 'show', true,
    'route_key', 'pos',
    'icon_key',  'point_of_sale',
    'label',     public.ui_text('pos.nav_label'),
    'sub_label', public.ui_text('pos.subtitle'));
end $function$;

grant execute on function public.pos_entry() to authenticated;

-- NO feature_registry row, deliberately. `feature_registry_surface_ck` locks the
-- 'profile' surface to exactly two identity features (#325 put that guard there
-- so a tile cannot sneak back into the account menu), and the 'dashboard'
-- surface only ever renders `admin.%` keys or partner features — a customer
-- gets no tile there at all. A row on either surface would therefore be a
-- registration that renders NOWHERE, which is the same trap #397 found from the
-- other side: a tile with no screen. The counter's reachability is pos_entry()
-- plus the account menu, which is real and provable.

-- ─────────────────── 8. THE GST RATE RESOLVER (a gap this command found) ────
--
-- The spec says the CGST/SGST breakup comes from MEDICINE.gst_percent. It does
-- — when that column has a value. It does not: gst_percent is NULL on EVERY row
-- of the 563k-row catalog, and `medicine_pricing` (the #174 PTR/GST backfill)
-- has two rows in it. Left alone, every retail invoice this counter printed
-- would show 0% GST and a taxable value equal to the amount, which is not a
-- legal tax invoice and would understate the pharmacy's output tax in its own
-- GSTR-1.
--
-- Inventing a per-product rate would be worse than the gap. So the rate is
-- RESOLVED, in priority order, and every step is data the pharmacy or an admin
-- can correct with an UPDATE instead of a deploy:
--   1. MEDICINE.gst_percent      — product-specific truth, the moment it exists
--   2. medicine_pricing.gst_pct  — the #174 backfill, same story
--   3. pos_gst_rule              — a matched rule (therapeutic class / name)
--   4. the default rule          — 12%, which is the GST rate for the large
--                                  majority of formulations in India
-- Priority 1 is unchanged from the spec; 2–4 only ever answer where 1 is silent.

create table if not exists public.pos_gst_rule (
  id           bigserial primary key,
  match_kind   text not null check (match_kind in ('default','therapeutic_class','name_like')),
  match_value  text,
  gst_percent  numeric(6,2) not null check (gst_percent >= 0 and gst_percent <= 28),
  note         text,
  priority     integer not null default 100,
  is_active    boolean not null default true,
  updated_at   timestamptz not null default now()
);
create unique index if not exists pos_gst_rule_default_idx
  on public.pos_gst_rule (match_kind) where match_kind = 'default';
create index if not exists pos_gst_rule_lookup_idx
  on public.pos_gst_rule (match_kind, priority) where is_active;

-- The statutory slabs, as data. These are the standard Indian GST rates for
-- pharmacy stock; a pharmacy whose accountant disagrees changes a row.
insert into public.pos_gst_rule (match_kind, match_value, gst_percent, note, priority)
values
  ('default',           null,            12, 'Most formulations attract 12% GST', 900),
  ('name_like',         'insulin',        5, 'Insulin is a 5% item',              10),
  ('name_like',         'oral rehydration', 5, 'ORS is a 5% item',                10),
  ('name_like',         ' ors ',          5, 'ORS is a 5% item',                  10),
  ('name_like',         'vaccine',        5, 'Vaccines are 5% items',             10),
  ('name_like',         'condom',         0, 'Contraceptives are NIL-rated',      10),
  ('name_like',         'contracept',     0, 'Contraceptives are NIL-rated',      10),
  ('name_like',         'sanitary napkin',0, 'NIL-rated',                         10),
  ('therapeutic_class', 'VACCINES',       5, 'Vaccines are 5% items',             50)
on conflict do nothing;

-- Resolve the rate for one catalog product. STABLE and index-friendly: the
-- rule table is tiny, so this is a nested-loop over a handful of rows, never a
-- scan of the catalog.
create or replace function public._pos_gst_for(p_medicine_id bigint)
returns numeric
language plpgsql stable
set search_path to 'public'
as $function$
declare
  v_rate  numeric;
  v_name  text;
  v_class text;
begin
  if p_medicine_id is null then return null; end if;

  select coalesce(m.gst_percent, 0)::numeric, lower(coalesce(m.product_name,'')),
         upper(btrim(coalesce(m.therapeutic_class,'')))
    into v_rate, v_name, v_class
    from public."MEDICINE" m where m.id = p_medicine_id;
  if not found then return null; end if;

  -- 1. the catalog's own column, when it actually says something
  if v_rate is not null and v_rate > 0 then return v_rate; end if;

  -- 2. the #174 pricing backfill
  select p.gst_pct into v_rate from public.medicine_pricing p
   where p.product_id = p_medicine_id and p.gst_pct is not null;
  if v_rate is not null and v_rate > 0 then return v_rate; end if;

  -- 3. a matched rule, most specific first
  select r.gst_percent into v_rate
    from public.pos_gst_rule r
   where r.is_active
     and ((r.match_kind = 'therapeutic_class' and v_class = upper(btrim(r.match_value)))
       or (r.match_kind = 'name_like' and v_name like '%' || lower(r.match_value) || '%'))
   order by r.priority, r.id
   limit 1;
  if v_rate is not null then return v_rate; end if;

  -- 4. the default
  select r.gst_percent into v_rate from public.pos_gst_rule r
   where r.is_active and r.match_kind = 'default' limit 1;
  return coalesce(v_rate, 12);
end $function$;

-- Decimals print without a dangling separator. to_char(2,'FM…0.999') returns
-- '2.' — FM drops the trailing zeros but leaves the '.' behind, which put "2."
-- on every quantity and "12.%" on every GST label. Every quantity, percentage
-- and rate label on the bill and the invoice goes through this.
create or replace function public._pos_dec(p numeric)
returns text language sql immutable as $$
  select rtrim(rtrim(to_char(coalesce(p,0), 'FM9999990.999'), '0'), '.');
$$;

-- ──────────────────── 9. GRANTS: the fence, made explicit ──────────────────
--
-- TWO defaults conspire here, and the first revoke only closed one of them:
--   1. Postgres grants EXECUTE on a new function to PUBLIC, and PUBLIC includes
--      `anon` — whose key ships inside the web bundle and the APK. That is what
--      the `privileged_rpcs_are_not_anon` guard exists to catch.
--   2. This project also carries ALTER DEFAULT PRIVILEGES granting EXECUTE to
--      `authenticated` and `service_role` on every function created in `public`.
--      So even after revoking PUBLIC, every internal helper was still callable
--      by any logged-in account.
-- Both matter. `_pos_header(uuid)` would otherwise let any signed-in user read
-- any pharmacy's address and GSTIN, and `pos_invoice_render_input(uuid)` would
-- hand them any pharmacy's whole invoice — it takes a sale_id and deliberately
-- makes NO shop check, because only the renderer (service key) calls it.
--
-- The bodies were already safe (every caller-facing RPC resolves pos_shop() and
-- refuses a null), but "safe because of a check inside the body" is one edit
-- away from not being safe. The grant is the fence.
--
-- Revoking from the internals costs nothing: a SECURITY DEFINER function runs as
-- its owner, so pos_quote() calling pos_price_bill() is checked against postgres,
-- never against the caller.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'pos\_%' or p.proname like '\_pos\_%')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('revoke all on function %s from authenticated', r.sig);
  end loop;
end $$;

-- The caller-facing API, and nothing else.
grant execute on function public.pos_entry()                           to authenticated;
grant execute on function public.pos_home()                            to authenticated;
grant execute on function public.pos_search(text, integer)             to authenticated;
grant execute on function public.pos_scan(text)                        to authenticated;
grant execute on function public.pos_quote(jsonb, numeric)             to authenticated;
grant execute on function public.pos_commit_sale(uuid, jsonb, numeric, text, jsonb) to authenticated;
grant execute on function public.pos_sale_detail(uuid)                 to authenticated;
grant execute on function public.pos_invoice_request(uuid)             to authenticated;
grant execute on function public.pos_invoice_wa(uuid, text)            to authenticated;
grant execute on function public.pos_day_close(date)                   to authenticated;

-- Internal: the renderer's own pair, service_role only.
grant execute on function public.pos_invoice_render_input(uuid)        to service_role;
grant execute on function public.pos_invoice_report(uuid, boolean, text, text, text, integer, text) to service_role;

-- The rename in section 8 leaves the old helper behind on a database that ran
-- an earlier copy of this file; drop it by signature, after the grant loop has
-- stopped iterating over it.
drop function if exists public._pos_qty(numeric);
