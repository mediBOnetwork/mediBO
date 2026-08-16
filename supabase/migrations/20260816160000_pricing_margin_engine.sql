-- CHANGE #174 — B2B net-rate / margin pricing engine.
--
-- The storefront has only ever shown MRP. mediBO sells on PTR ± discount +
-- GST (legal_get_page('about'): "Any build that prices, totals, or reports
-- revenue on MRP is wrong"). This migration ships the ENGINE now; the DATA
-- arrives product-by-product from supplier bills and an admin backfill screen.
--
-- The whole design turns on one rule: a product with no pricing row renders
-- EXACTLY what it renders today — MRP, no margin, no chip, no zero. Absence is
-- explicit (`display_mode`), never a fabricated number.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Data model — a linked sparse table, not 10 nullable columns on a 562k-row
--    MEDICINE. Keeps its own RLS and audit trail (see the command's decisions).
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.medicine_pricing (
  product_id          bigint primary key references public."MEDICINE"(id) on delete cascade,
  ptr                 numeric,
  gst_pct             numeric,
  scheme_text         text,
  scheme_buy_qty      numeric,
  scheme_free_qty     numeric,
  discount_pct        numeric,
  -- Recomputed on every write so reporting can read them without the engine.
  taxable_amount      numeric,
  net_payable         numeric,
  -- True ONLY when the minimum viable set is present: a PTR and a GST rate.
  pricing_ready       boolean not null default false,
  pricing_source      text,
  pricing_updated_at  timestamptz,
  updated_by          uuid
);

comment on table public.medicine_pricing is
  'CHANGE #174 — per-product B2B trade pricing (PTR/GST/scheme). Sparse: a missing row means "no pricing yet", which renders as MRP-only.';

create index if not exists idx_medicine_pricing_ready
  on public.medicine_pricing (pricing_ready) where pricing_ready;

alter table public.medicine_pricing enable row level security;

-- Storefront lesson (dev_lessons, storefront): never key a policy to
-- auth.uid() matching a profile PK — resolve the ROLE instead.
drop policy if exists medicine_pricing_read on public.medicine_pricing;
create policy medicine_pricing_read on public.medicine_pricing
  for select using (
    public.viewer_is_approved_customer()
    or public.get_my_role() = any (array['admin','super_admin'])
  );

drop policy if exists medicine_pricing_write on public.medicine_pricing;
create policy medicine_pricing_write on public.medicine_pricing
  for all using (public.get_my_role() = any (array['admin','super_admin']))
  with check (public.get_my_role() = any (array['admin','super_admin']));

grant select on public.medicine_pricing to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Backend-owned copy and colours. Nothing below is ever written in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label(key, value, note) values
  ('net_rate_caption',   'NET',        'CHANGE #174 — caption above the net payable rate on a card'),
  ('ptr_caption',        'PTR',        'CHANGE #174 — caption for the trade rate on the PDP'),
  ('margin_earn_prefix', 'You earn',   'CHANGE #174 — prefix of the margin line, e.g. "You earn ₹42.10"'),
  ('margin_chip_suffix', 'margin',     'CHANGE #174 — suffix of the margin chip, e.g. "22% margin"'),
  ('gst_breakup_title',  'GST breakup','CHANGE #174 — PDP section title for the tax split'),
  ('gst_taxable_label',  'Taxable value', 'CHANGE #174 — first row of the GST breakup'),
  ('cart_margin_label',  'You earn on this order', 'CHANGE #174 — cart margin row label'),
  ('cart_net_label',     'Net payable (trade)',    'CHANGE #174 — cart net total row label')
on conflict (key) do nothing;

-- Margin bands: label + the two colours, so the chip is a payload, not a
-- Dart branch. Muted state colours from the design system (CLAUDE.md).
insert into public.app_settings(key, value) values
  ('pricing_margin_bands', '[
     {"min_pct": 20,    "label": "High margin", "bg": "#D1FAE5", "fg": "#065F46"},
     {"min_pct": 10,    "label": "Good margin", "bg": "#EFF6FF", "fg": "#1E40AF"},
     {"min_pct": 0,     "label": "Low margin",  "bg": "#FEF3C7", "fg": "#92400E"},
     {"min_pct": -1000, "label": "Above MRP",   "bg": "#FEE2E2", "fg": "#991B1B"}
   ]'::jsonb)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2b. Percent formatting. to_char(12,'FM990.99') is '12.' — a trailing dot that
--     reads as a typo in "GST 12.%". One helper so every percent prints the
--     same way. (rtrim'ing zeros is NOT safe: '20.0' would rtrim to '2'.)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._num_label(v numeric)
returns text
language sql
immutable
as $$
  select case
           when v is null then ''
           when v = trunc(v) then to_char(v, 'FM999999999990')
           else trim(to_char(v, 'FM999999999990.99'))
         end;
$$;

grant execute on function public._num_label(numeric) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The math — ONE function, pure, used by cards, PDP, cart and reports alike.
--    Returns null when there is no PTR: callers then fall back to MRP-only.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._pricing_compute(
  p_mrp numeric, p_ptr numeric, p_gst numeric, p_disc numeric,
  p_buy numeric, p_free numeric, p_igst boolean default false)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_ptr    numeric := nullif(coalesce(p_ptr, 0), 0);
  v_gst    numeric := coalesce(p_gst, 0);
  v_disc   numeric := coalesce(p_disc, 0);
  v_factor numeric := 1;
  v_taxable numeric; v_gstamt numeric; v_net numeric;
  v_cgst numeric := 0; v_sgst numeric := 0; v_igst numeric := 0;
  v_margin numeric; v_mpct numeric;
begin
  if v_ptr is null then
    return null;
  end if;

  -- Scheme, e.g. 10+1: eleven units land for the price of ten, so the
  -- per-unit trade rate is ptr * 10/11.
  if coalesce(p_free, 0) > 0 and coalesce(p_buy, 0) > 0 then
    v_factor := p_buy / (p_buy + p_free);
  end if;

  v_taxable := round(v_ptr * (1 - v_disc / 100.0) * v_factor, 2);
  v_gstamt  := round(v_taxable * v_gst / 100.0, 2);

  if p_igst then
    v_igst := v_gstamt;
  else
    v_cgst := round(v_gstamt / 2.0, 2);
    v_sgst := round(v_gstamt - v_cgst, 2);   -- the odd paisa stays with SGST
  end if;

  v_net := round(v_taxable + v_gstamt, 2);

  -- MRP is GST-inclusive (#585), so it compares directly against net payable.
  if p_mrp is not null and p_mrp > 0 then
    v_margin := round(p_mrp - v_net, 2);
    v_mpct   := round((p_mrp - v_net) / p_mrp * 100.0, 1);
  end if;

  return jsonb_build_object(
    'ptr',           v_ptr,
    'gst_pct',       v_gst,
    'discount_pct',  v_disc,
    'scheme_factor', v_factor,
    'taxable',       v_taxable,
    'gst_amount',    v_gstamt,
    'cgst',          v_cgst,
    'sgst',          v_sgst,
    'igst',          v_igst,
    'is_igst',       p_igst,
    'net_payable',   v_net,
    'margin_amount', v_margin,
    'margin_pct',    v_mpct);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The rendered block. Every string and colour a surface prints comes from
--    here. `display_mode` is the ONLY thing a client branches on.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._pricing_block(
  p_mrp numeric, p_row public.medicine_pricing, p_discount_pct numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_has   boolean := (p_mrp is not null and p_mrp > 0);
  v_mrp   numeric := coalesce(p_mrp, 0);
  v_cap   text := coalesce((select value from storefront_ui_label where key = 'price_caption'), 'MRP');
  v_net_cap text := coalesce((select value from storefront_ui_label where key = 'net_rate_caption'), 'NET');
  v_ptr_cap text := coalesce((select value from storefront_ui_label where key = 'ptr_caption'), 'PTR');
  v_earn  text := coalesce((select value from storefront_ui_label where key = 'margin_earn_prefix'), 'You earn');
  v_suffix text := coalesce((select value from storefront_ui_label where key = 'margin_chip_suffix'), 'margin');
  v_gst_title text := coalesce((select value from storefront_ui_label where key = 'gst_breakup_title'), 'GST breakup');
  v_tax_label text := coalesce((select value from storefront_ui_label where key = 'gst_taxable_label'), 'Taxable value');
  v_base  jsonb;
  v_calc  jsonb;
  v_band  jsonb;
  v_pct   numeric;
  v_net   numeric;
  v_chip  text;
  v_lines jsonb;
begin
  -- The MRP-only payload. Byte-for-byte the block CHANGE #676 shipped, plus
  -- explicit-absence keys so no surface has to guess what it was not sent.
  v_base := jsonb_build_object(
    'has_price',      v_has,
    'mrp',            v_mrp,
    'sale_price',     v_mrp,
    'price_display',  case when v_has then public.inr_money(v_mrp) else '' end,
    'price_caption',  case when v_has then v_cap else '' end,
    'mrp_display',    '',
    'discount_pct',   0,
    'has_discount',   false,
    'discount_label', '',
    'ribbon_top',     '',
    'ribbon_bottom',  '',
    'margin_label',   '',
    -- CHANGE #174 — absence, stated:
    'display_mode',   'mrp_only',
    'pricing_ready',  false,
    'has_net',        false,
    'net_display',    '',
    'net_caption',    '',
    'has_margin',     false,
    'margin_pct',     null,
    'margin_chip',    null,
    'has_ptr',        false,
    'ptr_display',    '',
    'ptr_caption',    '',
    'has_scheme',     false,
    'scheme_text',    '',
    'has_struck_mrp', false,
    'gst',            null);

  -- No MRP to compare against, or no pricing captured yet → MRP-only. This is
  -- the normal state for most of the catalogue and must never look broken.
  --
  -- The viewer gate belongs here too: PTR, net rate and "you earn" are TRADE
  -- terms. The storefront is public, so without this an anonymous visitor would
  -- read mediBO's buying price off a product page. Everyone else gets the same
  -- MRP-only block an un-priced product returns — no "hidden price" tell.
  if not v_has or not coalesce(p_row.pricing_ready, false)
     or not (public.viewer_is_approved_customer()
             or public.get_my_role() = any (array['admin','super_admin'])) then
    return v_base;
  end if;

  v_calc := public._pricing_compute(v_mrp, p_row.ptr, p_row.gst_pct,
              coalesce(p_row.discount_pct, 0),
              p_row.scheme_buy_qty, p_row.scheme_free_qty, false);
  if v_calc is null then
    return v_base;
  end if;

  v_net := (v_calc->>'net_payable')::numeric;
  v_pct := (v_calc->>'margin_pct')::numeric;

  select b into v_band
    from jsonb_array_elements(
           coalesce((select value from app_settings where key = 'pricing_margin_bands'), '[]'::jsonb)) b
   where (b->>'min_pct')::numeric <= v_pct
   order by (b->>'min_pct')::numeric desc
   limit 1;

  v_chip := trim(public._num_label(v_pct) || '% ' || v_suffix);

  -- The tax split as printable rows, so the PDP prints a list instead of
  -- assembling labels out of numbers.
  v_lines := jsonb_build_array(
    jsonb_build_object('label', v_tax_label,
                       'value', public.inr_money((v_calc->>'taxable')::numeric)))
    || case when (v_calc->>'is_igst')::boolean
         then jsonb_build_array(jsonb_build_object(
                'label', 'IGST ' || public._num_label((v_calc->>'gst_pct')::numeric) || '%',
                'value', public.inr_money((v_calc->>'igst')::numeric)))
         else jsonb_build_array(
                jsonb_build_object(
                  'label', 'CGST ' || public._num_label((v_calc->>'gst_pct')::numeric / 2) || '%',
                  'value', public.inr_money((v_calc->>'cgst')::numeric)),
                jsonb_build_object(
                  'label', 'SGST ' || public._num_label((v_calc->>'gst_pct')::numeric / 2) || '%',
                  'value', public.inr_money((v_calc->>'sgst')::numeric)))
       end;

  return v_base || jsonb_build_object(
    'display_mode',   'full',
    'pricing_ready',  true,
    -- The headline number on every card becomes what the pharmacy actually
    -- pays. MRP moves to the struck reference position.
    'price_display',  public.inr_money(v_net),
    'price_caption',  v_net_cap,
    'sale_price',     v_net,
    'has_net',        true,
    'net_display',    public.inr_money(v_net),
    'net_caption',    v_net_cap,
    'has_struck_mrp', true,
    'mrp_display',    public.inr_money(v_mrp),
    -- has_discount keeps the existing widgets striking the MRP and painting
    -- the chip; margin_chip carries the colours for the ones that read it.
    'has_discount',   true,
    'discount_label', v_chip,
    'has_margin',     ((v_calc->>'margin_amount')::numeric is not null),
    'margin_pct',     v_pct,
    'margin_label',   v_earn || ' ' || public.inr_money((v_calc->>'margin_amount')::numeric),
    'margin_chip', jsonb_build_object(
      'label', v_chip,
      'bg',    coalesce(v_band->>'bg', '#EFF6FF'),
      'fg',    coalesce(v_band->>'fg', '#1E40AF'),
      'band',  coalesce(v_band->>'label', '')),
    -- The compact grid card already renders a two-line corner ribbon from
    -- these (empty since #676). Filling them puts the margin on the grid with
    -- NO change to that card's fixed geometry.
    'ribbon_top',     public._num_label(v_pct) || '%',
    'ribbon_bottom',  v_suffix,
    'has_ptr',        true,
    'ptr_display',    public.inr_money((v_calc->>'ptr')::numeric),
    'ptr_caption',    v_ptr_cap,
    'has_scheme',     (nullif(btrim(coalesce(p_row.scheme_text, '')), '') is not null),
    'scheme_text',    coalesce(nullif(btrim(coalesce(p_row.scheme_text, '')), ''), ''),
    'gst', jsonb_build_object(
      'title',           v_gst_title,
      'pct',             (v_calc->>'gst_pct')::numeric,
      'pct_display',     'GST ' || public._num_label((v_calc->>'gst_pct')::numeric) || '%',
      'is_igst',         (v_calc->>'is_igst')::boolean,
      'taxable_display', public.inr_money((v_calc->>'taxable')::numeric),
      'amount_display',  public.inr_money((v_calc->>'gst_amount')::numeric),
      'net_display',     public.inr_money(v_net),
      'lines',           v_lines),
    'source',         coalesce(p_row.pricing_source, ''),
    'raw', jsonb_build_object(
      'ptr',           (v_calc->>'ptr')::numeric,
      'net_payable',   v_net,
      'taxable',       (v_calc->>'taxable')::numeric,
      'margin_amount', (v_calc->>'margin_amount')::numeric,
      'margin_pct',    v_pct));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. storefront_pricing — the block every surface already calls.
--    The 2-arg form keeps working (MRP-only); a 3-arg form takes the product id
--    and can therefore return full mode. No defaults on the 3-arg overload, so
--    resolution stays by argument count and can never be ambiguous.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.storefront_pricing(
  p_mrp numeric, p_discount_pct numeric default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_none public.medicine_pricing;
begin
  -- No product id → no pricing lookup possible → MRP-only, exactly as before.
  return public._pricing_block(p_mrp, v_none, p_discount_pct);
end;
$$;

create or replace function public.storefront_pricing(
  p_mrp numeric, p_discount_pct numeric, p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_row public.medicine_pricing;
begin
  if p_product_id is not null then
    select * into v_row from public.medicine_pricing where product_id = p_product_id;
  end if;
  -- p_discount_pct is the cart TIER discount. It is applied once, on the cart
  -- total, and must not also be applied per unit here.
  return public._pricing_block(p_mrp, v_row, p_discount_pct);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Read + write RPCs.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.product_pricing(
  p_product_id bigint, p_customer_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_mrp numeric;
  v_row public.medicine_pricing;
  v_block jsonb;
begin
  select nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric
    into v_mrp
  from "MEDICINE" m where m.id = p_product_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into v_row from public.medicine_pricing where product_id = p_product_id;
  v_block := public._pricing_block(v_mrp, v_row, null);

  return jsonb_build_object(
    'ok',            true,
    'product_id',    p_product_id,
    'display_mode',  v_block->>'display_mode',
    'pricing',       v_block,
    'updated_at',    v_row.pricing_updated_at,
    'source',        coalesce(v_row.pricing_source, ''));
end;
$$;

-- The writer. Recomputes the stored numbers, decides pricing_ready, and
-- refuses to let an OLDER supplier bill overwrite a NEWER manual correction.
create or replace function public._pricing_apply(
  p_product_id bigint, p_fields jsonb, p_source text, p_at timestamptz, p_by uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_old public.medicine_pricing;
  v_ptr numeric; v_gst numeric; v_disc numeric;
  v_buy numeric; v_free numeric; v_scheme text;
  v_calc jsonb; v_ready boolean;
begin
  if p_product_id is null or not exists (select 1 from "MEDICINE" where id = p_product_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  select * into v_old from public.medicine_pricing where product_id = p_product_id;

  -- Precedence: a hand-entered value stands until a NEWER bill arrives.
  if v_old.product_id is not null
     and coalesce(v_old.pricing_source, '') = 'manual'
     and p_source = 'supplier_bill'
     and coalesce(v_old.pricing_updated_at, '-infinity'::timestamptz) > coalesce(p_at, now()) then
    return jsonb_build_object('ok', true, 'skipped', 'manual_is_newer',
                              'product_id', p_product_id);
  end if;

  -- Absent key = keep what is stored. Explicit null = clear it.
  v_ptr    := case when p_fields ? 'ptr'             then nullif(p_fields->>'ptr','')::numeric            else v_old.ptr end;
  v_gst    := case when p_fields ? 'gst_pct'         then nullif(p_fields->>'gst_pct','')::numeric        else v_old.gst_pct end;
  v_disc   := case when p_fields ? 'discount_pct'    then nullif(p_fields->>'discount_pct','')::numeric   else v_old.discount_pct end;
  v_buy    := case when p_fields ? 'scheme_buy_qty'  then nullif(p_fields->>'scheme_buy_qty','')::numeric else v_old.scheme_buy_qty end;
  v_free   := case when p_fields ? 'scheme_free_qty' then nullif(p_fields->>'scheme_free_qty','')::numeric else v_old.scheme_free_qty end;
  v_scheme := case when p_fields ? 'scheme_text'     then nullif(btrim(coalesce(p_fields->>'scheme_text','')),'') else v_old.scheme_text end;

  -- Ready means the minimum viable set is present AND sane. Anything less
  -- stays MRP-only rather than rendering a half number.
  v_ready := (v_ptr is not null and v_ptr > 0 and v_gst is not null and v_gst >= 0);

  v_calc := public._pricing_compute(
              nullif(regexp_replace(coalesce((select m.mrp::text from "MEDICINE" m where m.id = p_product_id), ''), '[^0-9.]', '', 'g'), '')::numeric,
              v_ptr, v_gst, coalesce(v_disc, 0), v_buy, v_free, false);

  insert into public.medicine_pricing as mp (
    product_id, ptr, gst_pct, scheme_text, scheme_buy_qty, scheme_free_qty,
    discount_pct, taxable_amount, net_payable, pricing_ready,
    pricing_source, pricing_updated_at, updated_by)
  values (
    p_product_id, v_ptr, v_gst, v_scheme, v_buy, v_free,
    v_disc, (v_calc->>'taxable')::numeric, (v_calc->>'net_payable')::numeric, v_ready,
    p_source, coalesce(p_at, now()), p_by)
  on conflict (product_id) do update set
    ptr = excluded.ptr, gst_pct = excluded.gst_pct,
    scheme_text = excluded.scheme_text,
    scheme_buy_qty = excluded.scheme_buy_qty,
    scheme_free_qty = excluded.scheme_free_qty,
    discount_pct = excluded.discount_pct,
    taxable_amount = excluded.taxable_amount,
    net_payable = excluded.net_payable,
    pricing_ready = excluded.pricing_ready,
    pricing_source = excluded.pricing_source,
    pricing_updated_at = excluded.pricing_updated_at,
    updated_by = excluded.updated_by;

  return jsonb_build_object(
    'ok', true, 'product_id', p_product_id,
    'pricing_ready', v_ready, 'source', p_source,
    'pricing', public.product_pricing(p_product_id));
end;
$$;

create or replace function public.product_pricing_upsert(
  p_product_id bigint, p_fields jsonb, p_source text default 'manual')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if public.get_my_role() is distinct from 'admin'
     and public.get_my_role() is distinct from 'super_admin'
     and coalesce(current_setting('request.jwt.claim.role', true),
                  current_setting('role', true), '') not in ('service_role') then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  return public._pricing_apply(p_product_id, coalesce(p_fields, '{}'::jsonb),
                               coalesce(nullif(p_source, ''), 'manual'),
                               now(), auth.uid());
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Auto-capture. bill_lines already carries ptr / gst_pct / free_qty from the
--    supplier-bill scan, so pricing fills itself as bills are processed.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._bill_line_capture_pricing()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.product_id is not null
     and coalesce(new.ptr, 0) > 0
     and new.gst_pct is not null then
    perform public._pricing_apply(
      new.product_id,
      jsonb_build_object(
        'ptr',             new.ptr,
        'gst_pct',         new.gst_pct,
        'discount_pct',    new.disc_pct,
        'scheme_buy_qty',  new.qty,
        'scheme_free_qty', new.free_qty,
        'scheme_text',     case when coalesce(new.free_qty, 0) > 0
                                then trim(to_char(coalesce(new.qty,0), 'FM999999')) || '+' ||
                                     trim(to_char(new.free_qty, 'FM999999'))
                           end),
      'supplier_bill',
      coalesce(new.created_at, now()),
      null);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_bill_line_capture_pricing on public.bill_lines;
create trigger trg_bill_line_capture_pricing
  after insert or update of product_id, ptr, gst_pct, disc_pct, free_qty, qty
  on public.bill_lines
  for each row execute function public._bill_line_capture_pricing();

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Admin backfill feed — coverage first, then the products worth pricing.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_pricing_list(
  p_search text default null, p_offset integer default 0, p_limit integer default 40)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_total bigint; v_ready bigint; v_pct numeric;
  v_rows jsonb; v_n int; v_lim int := least(greatest(coalesce(p_limit, 40), 1), 100);
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if public.get_my_role() is distinct from 'admin'
     and public.get_my_role() is distinct from 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select count(*) into v_total from "MEDICINE" where buyable is true;
  select count(*) into v_ready
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where mp.pricing_ready and m.buyable is true;
  v_pct := case when v_total > 0 then round(v_ready::numeric / v_total * 100, 1) else 0 end;

  with page as (
    select m.id, m.product_name, m.marketer, m.pack_size, m.sales_count,
           nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric as mrp_num,
           mp.ptr, mp.gst_pct, mp.discount_pct, mp.scheme_text,
           mp.scheme_buy_qty, mp.scheme_free_qty,
           coalesce(mp.pricing_ready, false) as ready,
           coalesce(mp.pricing_source, '') as source, mp.pricing_updated_at
      from "MEDICINE" m
      left join public.medicine_pricing mp on mp.product_id = m.id
     where m.buyable is true
       and (v_q is null or m.product_name ilike '%' || v_q || '%'
                        or m.marketer ilike '%' || v_q || '%')
     order by coalesce(m.sales_count, 0) desc, m.id
     offset greatest(coalesce(p_offset, 0), 0) limit v_lim)
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',    p.id,
           'name',          coalesce(p.product_name, ''),
           'company',       coalesce(p.marketer, ''),
           'pack_label',    coalesce(p.pack_size, ''),
           'mrp',           p.mrp_num,
           'mrp_display',   coalesce(case when p.mrp_num is not null then public.inr_money(p.mrp_num) end, ''),
           'ptr',           p.ptr,
           'gst_pct',       p.gst_pct,
           'discount_pct',  p.discount_pct,
           'scheme_text',   coalesce(p.scheme_text, ''),
           'scheme_buy_qty',  p.scheme_buy_qty,
           'scheme_free_qty', p.scheme_free_qty,
           'ready',         p.ready,
           'status_label',  case when p.ready then 'Priced' else 'MRP only' end,
           'status_bg',     case when p.ready then '#D1FAE5' else '#F5F6F8' end,
           'status_fg',     case when p.ready then '#065F46' else '#6B7280' end,
           'source_label',  case when p.source = 'supplier_bill' then 'From bill'
                                 when p.source = 'manual' then 'Entered'
                                 else '' end,
           'pricing',       (public.product_pricing(p.id) -> 'pricing'))), '[]'::jsonb),
         count(*)::int
    into v_rows, v_n
  from page p;

  return jsonb_build_object(
    'ok',    true,
    'title', 'Product pricing',
    'subtitle', 'Enter PTR and GST — the storefront starts showing net rate and margin the moment you save.',
    'coverage', jsonb_build_object(
      'ready',   v_ready,
      'total',   v_total,
      'pct',     v_pct,
      'label',   public._num_label(v_pct) || '% priced',
      'detail',  to_char(v_ready, 'FM9,99,99,999') || ' of ' ||
                 to_char(v_total, 'FM9,99,99,999') || ' buyable products have PTR + GST'),
    'labels', jsonb_build_object(
      'search_hint',   'Search product or company',
      'ptr',           'PTR (₹)',
      'gst',           'GST %',
      'discount',      'Discount %',
      'scheme',        'Scheme (e.g. 10+1)',
      'save',          'Save pricing',
      'saved',         'Pricing saved',
      'empty',         'No products match that search.',
      'more',          'Load more'),
    'rows',       v_rows,
    'next_offset', greatest(coalesce(p_offset, 0), 0) + v_n,
    'has_more',   v_n >= v_lim);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Cart margin. Only priced lines count; the rest are named, never zeroed.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.cart_margin_block(p_items jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_net numeric := 0; v_margin numeric := 0;
  v_ready int := 0; v_pending int := 0;
  v_label text := coalesce((select value from storefront_ui_label where key = 'cart_margin_label'), 'You earn on this order');
  v_net_label text := coalesce((select value from storefront_ui_label where key = 'cart_net_label'), 'Net payable (trade)');
begin
  select
    coalesce(sum(case when mp.pricing_ready then l.qty * (x.c->>'net_payable')::numeric end), 0),
    coalesce(sum(case when mp.pricing_ready and l.mrp > 0
                      then l.qty * (x.c->>'margin_amount')::numeric end), 0),
    count(*) filter (where coalesce(mp.pricing_ready, false)),
    count(*) filter (where not coalesce(mp.pricing_ready, false))
    into v_net, v_margin, v_ready, v_pending
  from (
    select nullif(it->>'product_id', '')::bigint as pid,
           coalesce((it->>'quantity')::numeric, 0) as qty,
           coalesce((it->>'mrp')::numeric, 0) as mrp
      from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) it
     where nullif(it->>'product_id', '') is not null) l
  left join public.medicine_pricing mp on mp.product_id = l.pid
  left join lateral (
    select public._pricing_compute(l.mrp, mp.ptr, mp.gst_pct,
             coalesce(mp.discount_pct, 0), mp.scheme_buy_qty, mp.scheme_free_qty, false) as c) x on true;

  return jsonb_build_object(
    'has',            (v_ready > 0),
    'label',          v_label,
    'total',          round(v_margin, 2),
    'total_display',  public.inr_money(round(v_margin, 2)),
    'net_label',      v_net_label,
    'net_total',      round(v_net, 2),
    'net_total_display', public.inr_money(round(v_net, 2)),
    'ready_count',    v_ready,
    'pending_count',  v_pending,
    -- Named, not zeroed: an un-priced line is excluded from the total and the
    -- customer is told so in words.
    'note', case when v_pending > 0 and v_ready > 0
                 then v_pending::text || ' item' || case when v_pending = 1 then '' else 's' end
                      || ' not priced yet — not counted above'
                 else '' end);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. Grants — mirror the surrounding storefront RPCs.
-- ─────────────────────────────────────────────────────────────────────────────
grant execute on function public._pricing_compute(numeric, numeric, numeric, numeric, numeric, numeric, boolean) to anon, authenticated;
grant execute on function public._pricing_block(numeric, public.medicine_pricing, numeric) to anon, authenticated;
grant execute on function public.storefront_pricing(numeric, numeric, bigint) to anon, authenticated;
grant execute on function public.product_pricing(bigint, uuid) to anon, authenticated;
grant execute on function public.product_pricing_upsert(bigint, jsonb, text) to authenticated;
grant execute on function public.admin_pricing_list(text, integer, integer) to authenticated;
grant execute on function public.cart_margin_block(jsonb) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. Point every storefront_pricing() caller at the id-aware overload.
--     Done as a text patch on pg_get_functiondef so each caller keeps its own
--     body; each patch ASSERTS it changed something, because a caller silently
--     left on the 1/2-arg form would show MRP-only forever — the exact failure
--     this change exists to remove. storefront_product was missed on the first
--     pass and caught by the assertion below; that is why it is there.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare
  d text;
  pairs text[][] := array[
    array['public.storefront_page(text, integer, integer)',
          '(SELECT pct FROM disc))))',
          '(SELECT pct FROM disc), r.id)))'],
    array['public.storefront_search_page(text, text, integer, integer)',
          '(SELECT pct FROM disc))))',
          '(SELECT pct FROM disc), r.id)))'],
    array['public._sf_cards(bigint[])',
          E'\'\')::numeric),\n    \'mrp_label\'',
          E'\'\')::numeric, null::numeric, m.id),\n    \'mrp_label\''],
    array['public.medicine_page_v2(bigint, integer, text, text, boolean)',
          E'\'\')::numeric,\n                v_pct))',
          E'\'\')::numeric,\n                v_pct, m.id))'],
    array['public.wishlist_get()',
          E'\'\')::numeric\n        ))->>\'price_display\'',
          E'\'\')::numeric, null::numeric, m.id\n        ))->>\'price_display\''],
    array['public.product_detail(bigint)',
          'public.storefront_pricing(v_mrp)',
          'public.storefront_pricing(v_mrp, null::numeric, p_product_id)'],
    array['public.storefront_product(bigint)',
          E'\'\')::numeric))',
          E'\'\')::numeric, null::numeric, m.id))']
  ];
  i int;
begin
  for i in 1 .. array_length(pairs, 1) loop
    d := pg_get_functiondef(pairs[i][1]::regprocedure);
    if position(pairs[i][2] in d) = 0 then
      raise exception 'CHANGE #174: anchor not found in %', pairs[i][1];
    end if;
    execute replace(d, pairs[i][2], pairs[i][3]);
  end loop;
end $$;

do $$
declare
  fns text[] := array[
    'public.storefront_page(text, integer, integer)',
    'public.storefront_search_page(text, text, integer, integer)',
    'public.storefront_product(bigint)',
    'public.product_detail(bigint)',
    'public._sf_cards(bigint[])',
    'public.medicine_page_v2(bigint, integer, text, text, boolean)',
    'public.wishlist_get()'
  ];
  f text; d text; call text; p int;
begin
  foreach f in array fns loop
    d := pg_get_functiondef(f::regprocedure);
    p := position('storefront_pricing(' in d);
    if p = 0 then
      raise exception 'CHANGE #174: % no longer calls storefront_pricing', f;
    end if;
    call := substr(d, p, 400);
    if position('m.id' in call) = 0
       and position('r.id' in call) = 0
       and position('p_product_id' in call) = 0 then
      raise exception 'CHANGE #174: % still calls storefront_pricing without a product id', f;
    end if;
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. Pre-existing bug, found while wiring the auto-capture above and fixed
--     here because §5's acceptance is untestable without it: every append in
--     this trigger was `text[] || <untyped literal>`, which Postgres resolves
--     as array||array and fails with "malformed array literal". So ANY bill
--     line missing a batch no / expiry / qty / PTR / MRP / GST% threw on
--     insert — precisely the incomplete lines the trigger exists to flag.
--     Latent only because bill_lines was still empty. One ::text cast each.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.trg_bill_line_needs_fix()
returns trigger
language plpgsql
as $function$
DECLARE m text[] := '{}';
BEGIN
  IF NEW.product_id IS NULL         THEN m := m || 'product not matched'::text; END IF;
  IF COALESCE(NEW.batch_no,'') = '' THEN m := m || 'batch no'::text; END IF;
  IF COALESCE(NEW.expiry,'')   = '' THEN m := m || 'expiry'::text;   END IF;
  IF COALESCE(NEW.qty,0)      <= 0  THEN m := m || 'qty'::text;      END IF;
  IF COALESCE(NEW.ptr,0)      <= 0  THEN m := m || 'PTR'::text;      END IF;
  IF COALESCE(NEW.mrp,0)      <= 0  THEN m := m || 'MRP'::text;      END IF;
  IF NEW.gst_pct IS NULL            THEN m := m || 'GST %'::text;    END IF;
  NEW.needs_fix := NULLIF(array_to_string(m, ', '), '');
  IF NEW.needs_fix IS NOT NULL THEN NEW.verified := false; END IF;
  RETURN NEW;
END;
$function$;

-- Backend copy for the admin menu entry (ui_copy, read by c()).
insert into public.ui_copy(key, value)
values ('admin_nav.overflow_pricing', '"Product pricing"'::jsonb)
on conflict (key) do update set value = excluded.value;
