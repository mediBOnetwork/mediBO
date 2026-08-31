-- CHANGE #318 — Discount slab table + slab-driven customer bill pricing.
--
-- Om's trade math, verified against Laxmi Pharma INV LP08651:
--   value   = rate x qty                       (Cystone 110.48 x 12 = 1325.76)
--   disc    = value x slab%                    (their CD 8%  -> 106.06)
--   taxable = value - disc                     (1219.70, their VALUE column)
--   gst     = taxable x gst%                   (5% -> 60.98)
--   amount  = taxable + gst                    (1280.68, their Amount column)
-- Our customer bill runs the IDENTICAL formula with OUR slab in place of theirs.
-- _bill_compose already computed exactly this; what did not exist was the slab
-- ladder itself, its effective dating, an admin surface, and the snapshot that
-- makes an issued bill reproducible forever.

-- ── 1. The table, renamed to what it actually holds ─────────────────────────
-- It was (min_ptr, pct, active) and only ptr_discount_pct() ever read it. The
-- threshold is measured on the pre-discount TAXABLE total, which is a rupee
-- amount, not a PTR — so the column is min_amount.
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='discount_slabs'
                and column_name='min_ptr') then
    alter table public.discount_slabs rename column min_ptr to min_amount;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='discount_slabs'
                and column_name='pct') then
    alter table public.discount_slabs rename column pct to discount_pct;
  end if;
end $$;

alter table public.discount_slabs
  add column if not exists effective_from date        not null default date '2000-01-01',
  add column if not exists note            text,
  add column if not exists created_at      timestamptz not null default now(),
  add column if not exists updated_at      timestamptz not null default now();

comment on table public.discount_slabs is
  'CHANGE #318 — the customer discount ladder. Highest matching min_amount wins, '
  'measured on the pre-discount taxable total at BILL time. Effective-dated: a new '
  'row applies from its date and never rewrites a bill that already snapshotted a slab.';

create unique index if not exists discount_slabs_amount_date_uq
  on public.discount_slabs (min_amount, effective_from);

create index if not exists discount_slabs_lookup_idx
  on public.discount_slabs (active, effective_from, min_amount desc);

-- ── 2. Om's ladder, seeded exactly ──────────────────────────────────────────
insert into public.discount_slabs (min_amount, discount_pct, active, effective_from, note)
values (2999,  3, true, date '2000-01-01', 'Above ₹2,999'),
       (5999,  5, true, date '2000-01-01', 'Above ₹5,999'),
       (19999, 6, true, date '2000-01-01', 'Above ₹19,999'),
       (49999, 7, true, date '2000-01-01', 'Above ₹49,999'),
       (99999, 8, true, date '2000-01-01', 'Above ₹99,999')
on conflict (min_amount, effective_from) do update
  set discount_pct = excluded.discount_pct,
      active       = true,
      updated_at   = now();

-- ── 3. The picker — one place decides which slab a number falls in ──────────
-- "Above 2999" is strict: 2999.00 itself is below the slab, 2999.01 is in it.
-- Two rows may share a min_amount with different effective_from; the latest one
-- that has already come into force wins, which is what makes an old bill
-- reproducible: pass the bill's own timestamp and the old ladder answers.
create or replace function public.discount_slab_pick(
  p_amount numeric,
  p_at     timestamptz default now())
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select jsonb_build_object(
              'slab_id',        s.id,
              'discount_pct',   s.discount_pct,
              'min_amount',     s.min_amount,
              'effective_from', s.effective_from,
              'matched',        true)
       from public.discount_slabs s
      where s.active
        and s.effective_from <= ((coalesce(p_at, now()) at time zone 'Asia/Kolkata')::date)
        and coalesce(p_amount, 0) > s.min_amount
      order by s.min_amount desc, s.effective_from desc
      limit 1),
    jsonb_build_object('slab_id', null, 'discount_pct', 0::numeric,
                       'min_amount', null, 'effective_from', null, 'matched', false));
$function$;

-- Kept for every existing caller (_bill_compose, _peek, _peek_bill): same
-- signature, same answer, now sourced from the one picker.
create or replace function public.ptr_discount_pct(p_ptr_total numeric)
returns numeric
language sql
stable
as $function$
  select coalesce((public.discount_slab_pick(p_ptr_total, now())->>'discount_pct')::numeric, 0);
$function$;
-- CHANGE #318 part B — the snapshot that freezes a slab onto an issued bill.

-- ── 4. Snapshot columns on the order ────────────────────────────────────────
-- Changing a slab tomorrow must never move an invoice already in a customer's
-- hands, so the slab that priced a bill is written onto the order the moment
-- the bill is generated, and the bill reads the snapshot from then on.
alter table public.orders
  add column if not exists bill_slab_id      integer,
  add column if not exists bill_discount_pct numeric,
  add column if not exists bill_slab_base    numeric,
  add column if not exists bill_slab_at      timestamptz;

comment on column public.orders.bill_discount_pct is
  'CHANGE #318 — the slab % this order was BILLED at, frozen at bill generation. '
  'Non-null means the bill reprints at this rate forever, whatever the ladder says today.';

-- ── 5. The pre-discount taxable base of an order ────────────────────────────
-- Exactly the sum of the Value column the invoice prints: rate x qty per
-- verified allocated line, rounded per line. Not MRP, not GST-inclusive.
create or replace function public._order_taxable_base(p_order_id uuid)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(sum(round(a.qty * b.ptr, 2)), 0)
    from public.bill_line_allocations a
    join public.bill_lines b on b.id = a.bill_line_id
   where a.order_id = p_order_id and b.verified;
$function$;

-- ── 6. Take the snapshot (idempotent) ───────────────────────────────────────
-- Called at bill generation. Once written it is never silently re-priced: a
-- second render attempt, a retry, a resend all reproduce the same invoice.
create or replace function public.order_slab_snapshot(
  p_order_id uuid,
  p_force    boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_base numeric; v_slab jsonb; o public.orders%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'order_not_found'); end if;

  if o.bill_discount_pct is not null and not coalesce(p_force, false) then
    return jsonb_build_object(
      'ok', true, 'source', 'snapshot',
      'slab_id', o.bill_slab_id, 'discount_pct', o.bill_discount_pct,
      'base', o.bill_slab_base, 'at', o.bill_slab_at);
  end if;

  v_base := public._order_taxable_base(p_order_id);
  v_slab := public.discount_slab_pick(v_base, now());

  update public.orders
     set bill_slab_id      = nullif(v_slab->>'slab_id','')::int,
         bill_discount_pct = coalesce((v_slab->>'discount_pct')::numeric, 0),
         bill_slab_base    = v_base,
         bill_slab_at      = now()
   where id = p_order_id;

  return jsonb_build_object(
    'ok', true, 'source', 'fresh',
    'slab_id', nullif(v_slab->>'slab_id','')::int,
    'discount_pct', coalesce((v_slab->>'discount_pct')::numeric, 0),
    'base', v_base, 'at', now());
end $function$;

-- ── 7. What the bill should print, snapshot first ───────────────────────────
-- A bill that has been issued reads its frozen slab; a preview of an order that
-- has not been billed yet reads today's ladder and says so, so an admin looking
-- at a draft is never shown a rate that is already locked.
create or replace function public._order_slab_for_bill(
  p_order_id uuid,
  p_base     numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare o public.orders%rowtype; v jsonb;
begin
  select * into o from public.orders where id = p_order_id;
  if found and o.bill_discount_pct is not null then
    return jsonb_build_object(
      'slab_id', o.bill_slab_id, 'discount_pct', o.bill_discount_pct,
      'base', o.bill_slab_base, 'at', o.bill_slab_at, 'source', 'snapshot');
  end if;
  v := public.discount_slab_pick(p_base, now());
  return v || jsonb_build_object('base', p_base, 'source', 'live');
end $function$;

-- ── 8. Clearing the bill un-issues it, so it re-prices on regeneration ──────
create or replace function public.delete_customer_bill(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('error','not_authorized');
  end if;
  update orders set cust_bill_bucket=null, cust_bill_path=null, cust_bill_name=null,
                    cust_bill_uploaded_at=null, cust_bill_uploaded_by=null,
                    -- CHANGE #318: the invoice is withdrawn, so its frozen slab
                    -- goes with it. A regenerated bill prices at today's ladder.
                    bill_slab_id=null, bill_discount_pct=null,
                    bill_slab_base=null, bill_slab_at=null
   where id = p_order_id;
  return jsonb_build_object('status','ok','order_id',p_order_id);
end $function$;
-- CHANGE #318 part C — the composer prints the slab it was HANDED.
--
-- Only two lines of behaviour change here: where the discount % comes from
-- (the invoice's own frozen slab when it has one, today's ladder otherwise)
-- and three extra keys in `totals` so the surface can say which of the two it
-- is looking at. The line math is untouched — it was already Om's formula:
--   value = round(qty*ptr,2) · disc = round(value*pct,2) · taxable = value-disc
--   gst = round(taxable*gst%,2) · amount = taxable+gst
-- Free quantity is never multiplied by a rate anywhere in it, so scheme free
-- goods carry zero value by construction.
create or replace function public._bill_compose(
  p_lines jsonb, p_invoice jsonb, p_paid numeric DEFAULT 0, p_advance numeric DEFAULT 0,
  p_sample boolean DEFAULT false, p_bank jsonb DEFAULT NULL::jsonb,
  p_delivery jsonb DEFAULT NULL::jsonb, p_credits jsonb DEFAULT NULL::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  cfg public.billing_config%rowtype;
  v_pa text; v_pn text;
  v_pct numeric; v_ptr_total numeric := 0;
  v_slab jsonb := coalesce(p_invoice->'slab', '{}'::jsonb);
  v_lines jsonb; v_hsn jsonb; v_gstsum jsonb;
  v_mrp numeric; v_disc numeric; v_taxable numeric; v_gst numeric;
  v_items int; v_qty numeric; v_free numeric;
  v_grand numeric; v_final numeric; v_round numeric; v_remaining numeric;
  v_bank jsonb; v_banklines jsonb; v_seller jsonb;
  -- CHANGE #309: the delivery charge and the doorstep credit notes.
  v_del numeric := 0; v_del_gst numeric := 0; v_credit numeric := 0;
  v_credit_lines jsonb := '[]'::jsonb;
begin
  select * into cfg from public.billing_config where id = 1;
  select pa, pn into v_pa, v_pn
    from public.payment_upi_accounts where is_active order by created_at desc limit 1;

  with r as (
    select coalesce((e->>'qty')::numeric,0) qty, coalesce((e->>'ptr')::numeric,0) ptr
      from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e)
  select coalesce(sum(qty*ptr),0) into v_ptr_total from r;

  -- CHANGE #318: an issued invoice carries its own slab and reprints at that
  -- rate forever; anything without one (the sample, a draft preview) falls back
  -- to today's ladder. The slab is a COMMITMENT to the customer — nothing here
  -- caps, floors or overrides it for margin.
  v_pct := coalesce(nullif(v_slab->>'discount_pct','')::numeric,
                    public.ptr_discount_pct(v_ptr_total));

  with r as (
    select row_number() over (order by ord) sn,
           e->>'product' product,
           upper(coalesce(e->>'company','')) company,
           nullif(btrim(regexp_replace(coalesce(e->>'pack',''),'(\d)\.0(\D)','\1\2','g')),'') pack,
           coalesce(nullif(btrim(coalesce(e->>'hsn','')),''), cfg.default_hsn, '3004') hsn,
           e->>'batch_no' batch_no,
           e->>'expiry' expiry,
           coalesce((e->>'qty')::numeric,0)      qty,
           coalesce((e->>'free_qty')::numeric,0) free_qty,
           coalesce((e->>'mrp')::numeric,0)      mrp,
           coalesce((e->>'ptr')::numeric,0)      ptr,
           coalesce((e->>'gst_pct')::numeric,0)  gst_pct
      from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) with ordinality t(e, ord)),
  -- The three money columns a pharmacist checks by hand are Value, Disc and
  -- Taxable. Rounding each of them independently off the raw product leaves
  -- lines where Value - Disc misses Taxable by a paisa, so taxable is DERIVED
  -- from the two rounded figures actually printed, and GST from that taxable.
  c as (
    select r.*,
           round(qty*mrp, 2)                                  line_mrp,
           round(qty*ptr, 2)                                  line_ptr,
           round(round(qty*ptr, 2) * v_pct/100, 2)            disc_amt,
           round(qty*ptr, 2) - round(round(qty*ptr, 2) * v_pct/100, 2)                     taxable,
           round((round(qty*ptr, 2) - round(round(qty*ptr, 2) * v_pct/100, 2))
                 * gst_pct/100, 2)                            gst_amt
      from r)
  select
    (select jsonb_agg(jsonb_build_object(
        'sn',       c.sn,
        'product',  c.product,
        'company',  c.company,
        'pack',     c.pack,
        'hsn',      c.hsn,
        'batch_no', c.batch_no,
        'expiry',   c.expiry,
        'qty',      trim_scale(c.qty)::text,
        'free',     case when c.free_qty > 0 then trim_scale(c.free_qty)::text else '-' end,
        'mrp',      to_char(c.mrp,'FM999990.00'),
        'ptr',      to_char(c.ptr,'FM999990.00'),
        'value',    to_char(c.line_ptr,'FM99,99,990.00'),
        'disc',     to_char(c.disc_amt,'FM99,99,990.00'),
        'taxable',  to_char(c.taxable,'FM99,99,990.00'),
        'gst_pct',  trim_scale(c.gst_pct)::text || '%',
        'gst_amt',  to_char(c.gst_amt,'FM99,99,990.00'),
        'amount',   to_char(round(c.taxable + c.gst_amt, 2),'FM99,99,990.00')
      ) order by c.sn) from c),
    (select coalesce(sum(line_mrp),0) from c),
    (select coalesce(sum(disc_amt),0) from c),
    (select coalesce(sum(taxable),0)  from c),
    (select coalesce(sum(gst_amt),0)  from c),
    (select count(*)::int             from c),
    (select coalesce(sum(qty),0)      from c),
    (select coalesce(sum(free_qty),0) from c),
    (select jsonb_agg(jsonb_build_object(
        'hsn',     g.hsn,
        'rate',    trim_scale(g.gst_pct)::text || '%',
        'taxable', '₹' || to_char(g.tx,'FM99,99,990.00'),
        'cgst',    '₹' || to_char(round(g.gt/2,2),'FM99,99,990.00'),
        'sgst',    '₹' || to_char(round(g.gt/2,2),'FM99,99,990.00'),
        'total',   '₹' || to_char(g.gt,'FM99,99,990.00')) order by g.hsn, g.gst_pct)
       from (select hsn, gst_pct, sum(taxable) tx, sum(gst_amt) gt
               from c group by hsn, gst_pct) g),
    (select jsonb_agg(jsonb_build_object(
        'rate',    trim_scale(g.gst_pct)::text || '%',
        'taxable', '₹' || to_char(g.tx,'FM99,99,990.00'),
        'cgst',    '₹' || to_char(round(g.gt/2,2),'FM99,99,990.00'),
        'sgst',    '₹' || to_char(round(g.gt/2,2),'FM99,99,990.00'),
        'total',   '₹' || to_char(g.gt,'FM99,99,990.00')) order by g.gst_pct)
       from (select gst_pct, sum(taxable) tx, sum(gst_amt) gt
               from c group by gst_pct) g)
  into v_lines, v_mrp, v_disc, v_taxable, v_gst, v_items, v_qty, v_free, v_hsn, v_gstsum;

  -- CHANGE #309: a delivery charge is added and doorstep credit notes are
  -- subtracted BEFORE the single rounding at the end. Rounding each block
  -- separately is how an invoice ends up a rupee away from the payment that
  -- clears it, so there is still exactly one round() in this function.
  v_del     := coalesce((p_delivery->>'amount')::numeric, 0);
  v_del_gst := coalesce((p_delivery->>'gst_amount')::numeric, 0);

  if p_credits is not null and jsonb_typeof(p_credits) = 'array' then
    select coalesce(sum(coalesce((e->>'amount')::numeric,0)), 0),
           coalesce(jsonb_agg(jsonb_build_object(
             'reason', coalesce(e->>'reason',''),
             'note',   coalesce(e->>'note',''),
             'amount_label', '- ' || public.inr_money(coalesce((e->>'amount')::numeric,0)))), '[]'::jsonb)
      into v_credit, v_credit_lines
      from jsonb_array_elements(p_credits) e;
  end if;

  v_grand     := round(coalesce(v_taxable,0) + coalesce(v_gst,0)
                       + v_del + v_del_gst - v_credit, 2);
  v_final     := round(v_grand);                    -- invoices round to the rupee
  v_round     := round(v_final - v_grand, 2);
  v_remaining := round(v_final - coalesce(p_paid,0), 2);

  -- Bank block: the sample supplies its own, a real invoice reads billing_config
  -- and simply omits any line that has not been filled in yet.
  v_bank := coalesce(p_bank, jsonb_build_object(
    'name', cfg.bank_name, 'account', cfg.bank_account,
    'ifsc', cfg.bank_ifsc, 'branch', cfg.bank_branch));

  v_banklines := coalesce((
    select jsonb_agg(x.line order by x.ord) from (
      select 1 ord, 'Bank: '    || (v_bank->>'name')    line where nullif(v_bank->>'name','')    is not null
      union all
      select 2,     'A/c No: '  || (v_bank->>'account')      where nullif(v_bank->>'account','') is not null
      union all
      select 3,     'IFSC: '    || (v_bank->>'ifsc')         where nullif(v_bank->>'ifsc','')    is not null
      union all
      select 4,     'Branch: '  || (v_bank->>'branch')       where nullif(v_bank->>'branch','')  is not null
    ) x), '[]'::jsonb);

  -- A real invoice prints only what the operator has actually filled in; the
  -- SAMPLE substitutes an obviously fake value so the layout is visible even
  -- before Om has entered the real FSSAI / contact line.
  v_seller := jsonb_build_object(
    'name',    cfg.seller_name,
    'gstin',   cfg.seller_gstin,
    'dl',      cfg.seller_dl,
    'fssai',   coalesce(cfg.seller_fssai, case when p_sample then '10000000000000 (SAMPLE)' end),
    'phone',   coalesce(cfg.seller_phone, case when p_sample then '90000 00000 (SAMPLE)' end),
    'email',   coalesce(cfg.seller_email, case when p_sample then 'sample@medibo.in' end),
    'address', cfg.seller_address,
    'state',   cfg.seller_state,
    'warning', case when cfg.seller_gstin is null or cfg.seller_dl is null
                    then 'Seller GSTIN / Drug Licence not set — this is not yet a valid tax invoice.' end);

  return jsonb_build_object(
    'ready', true,
    'status_label', 'Bill ready',
    'sample', coalesce(p_sample,false),
    'sample_banner', case when p_sample
      then 'SAMPLE INVOICE — NOT A VALID TAX INVOICE. Fictitious buyer, products, batches and amounts, for layout review only.' end,
    'watermark', case when p_sample then 'SAMPLE' end,
    'title', case when p_sample then 'SAMPLE TAX INVOICE' else 'TAX INVOICE' end,

    'invoice', jsonb_build_object(
      'number', p_invoice->>'number',
      'date',   coalesce(p_invoice->>'date', to_char(now() at time zone 'Asia/Kolkata','DD/MM/YYYY')),
      'seller', v_seller,
      'buyer',  coalesce(p_invoice->'buyer','{}'::jsonb)),

    -- the renderer draws EXACTLY these columns, in this order. It decides nothing.
    'columns', jsonb_build_array(
      jsonb_build_object('key','sn',      'label','#',       'align','left'),
      jsonb_build_object('key','product', 'label','Product', 'align','left'),
      jsonb_build_object('key','pack',    'label','Pack',    'align','left'),
      jsonb_build_object('key','hsn',     'label','HSN',     'align','left'),
      jsonb_build_object('key','batch_no','label','Batch',   'align','left'),
      jsonb_build_object('key','expiry',  'label','Exp',     'align','left'),
      jsonb_build_object('key','qty',     'label','Qty',     'align','right'),
      jsonb_build_object('key','free',    'label','Free',    'align','right'),
      jsonb_build_object('key','mrp',     'label','MRP',     'align','right'),
      jsonb_build_object('key','ptr',     'label','Rate',    'align','right'),
      jsonb_build_object('key','value',   'label','Value',   'align','right'),
      jsonb_build_object('key','disc',    'label','Disc',    'align','right'),
      jsonb_build_object('key','taxable', 'label','Taxable', 'align','right'),
      jsonb_build_object('key','gst_pct', 'label','GST%',    'align','right'),
      jsonb_build_object('key','gst_amt', 'label','GST',     'align','right'),
      jsonb_build_object('key','amount',  'label','Amount',  'align','right')),
    'lines', coalesce(v_lines,'[]'::jsonb),

    'counts', jsonb_build_object(
      'items',       v_items,
      'total_qty',   trim_scale(coalesce(v_qty,0))::text,
      'free_qty',    trim_scale(coalesce(v_free,0))::text,
      'label',       v_items || ' item' || case when v_items = 1 then '' else 's' end
                     || '  ·  ' || trim_scale(coalesce(v_qty,0))::text || ' qty'
                     || case when coalesce(v_free,0) > 0
                             then '  ·  ' || trim_scale(v_free)::text || ' free' else '' end),

    'totals', jsonb_build_object(
      'mrp_total_label',       '₹' || to_char(v_mrp,'FM99,99,990.00'),
      'ptr_total_caption',     'Sub Total',
      'ptr_total_label',       '₹' || to_char(v_ptr_total,'FM99,99,990.00'),
      'discount_pct',          v_pct,
      'discount_label',        case when v_pct > 0
                                    then 'Less: Discount @ ' || trim_scale(v_pct)::text || '%'
                                    else 'Less: Discount (below slab)' end,
      'discount_amount_label', '- ₹' || to_char(v_disc,'FM99,99,990.00'),
      -- CHANGE #318 — which ladder priced this bill, and whether that answer is
      -- already locked. 'snapshot' means an issued invoice reprinting itself.
      'discount_slab_id',      nullif(v_slab->>'slab_id','')::int,
      'discount_source',       coalesce(nullif(v_slab->>'source',''), 'live'),
      'discount_locked',       coalesce(nullif(v_slab->>'source',''), 'live') = 'snapshot',
      'discount_basis_label',  case when coalesce(nullif(v_slab->>'source',''),'live') = 'snapshot'
                                    then public._c('bill.slab_locked_note')
                                    else public._c('bill.slab_live_note') end,
      'taxable_label',         '₹' || to_char(v_taxable,'FM99,99,990.00'),
      'cgst_label',            '₹' || to_char(round(v_gst/2,2),'FM99,99,990.00'),
      'sgst_label',            '₹' || to_char(round(v_gst/2,2),'FM99,99,990.00'),
      'gst_total_label',       '₹' || to_char(v_gst,'FM99,99,990.00'),
      -- CHANGE #309. Absence is EXPLICIT: has_delivery false means the
      -- renderer prints no delivery row at all, never a row reading "₹0.00".
      'has_delivery',          (v_del + v_del_gst) > 0,
      'delivery_label',        coalesce(p_delivery->>'label', public._c('delivery.charge_line_label')),
      'delivery_amount_label', '+ ₹' || to_char(v_del + v_del_gst,'FM99,99,990.00'),
      'delivery_note',         coalesce(p_delivery->>'note',''),
      'has_credit',            v_credit > 0,
      'credit_label',          public._c('bill.credit_note_label'),
      'credit_amount_label',   '- ₹' || to_char(v_credit,'FM99,99,990.00'),
      'credit_lines',          v_credit_lines,

      'round_off_label',       case when v_round <> 0
                                    then (case when v_round > 0 then '+ ₹' else '- ₹' end)
                                         || to_char(abs(v_round),'FM990.00') end,
      'net_payable',           v_final,
      'net_payable_label',     '₹' || to_char(v_final,'FM99,99,990.00'),
      'in_words',              public.inr_words(v_final),
      'advance_expected_label','₹' || to_char(coalesce(p_advance,0),'FM99,99,990.00'),
      'paid_label',            '₹' || to_char(coalesce(p_paid,0),'FM99,99,990.00'),
      'remaining',             v_remaining,
      'remaining_label',       '₹' || to_char(v_remaining,'FM99,99,990.00'),
      'you_save_label',        '₹' || to_char(v_mrp - v_final,'FM99,99,990.00') || ' below MRP'),

    'hsn_summary', coalesce(v_hsn,'[]'::jsonb),
    'gst_summary', coalesce(v_gstsum,'[]'::jsonb),

    'payment', jsonb_build_object(
      'heading',    'Payment details',
      'bank_lines', v_banklines,
      'upi_label',  case when v_pa is not null then 'UPI: ' || v_pa
                                               || case when v_pn is not null then '  (' || v_pn || ')' else '' end end,
      'note',       'Please quote the invoice number with every payment.'),

    'footer', jsonb_build_object(
      'terms',        cfg.invoice_terms,
      'jurisdiction', cfg.jurisdiction,
      'signature_for','For ' || coalesce(cfg.seller_name,''),
      'signature',    'Authorised Signatory')
  );
end $function$;
-- CHANGE #318 part D — the bill hands the composer its slab, and the issue
-- path freezes one first.

create or replace function public.customer_bill(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  cfg public.billing_config%rowtype;
  o   public.orders%rowtype;
  ph  public.pharmacy_profiles%rowtype;
  v_unbilled int; v_nosup int;
  v_raw jsonb; v_paid numeric; v_adv numeric;
  v_base numeric; v_slab jsonb;
  v_taxable numeric; v_del jsonb; v_credits jsonb;
begin
  perform public._assert_can_see_order(p_order_id);
  select * into cfg from public.billing_config where id = 1;
  select * into o   from public.orders where id = p_order_id;
  select * into ph  from public.pharmacy_profiles where user_id = o.user_id limit 1;

  select count(*), count(*) filter (where oi.assigned_supplier is null)
    into v_unbilled, v_nosup
  from public.order_items oi
  where oi.order_id = p_order_id
    and oi.fulfillment_state not in ('shipped','cancelled')
    and coalesce(oi.unfulfillable,false) = false
    and not exists (select 1 from public.bill_line_allocations a
                    join public.bill_lines b on b.id = a.bill_line_id
                    where a.order_item_id = oi.id and b.verified and b.needs_fix is null);

  if v_unbilled > 0 then
    return jsonb_build_object('ready', false, 'status_label','Bill not ready',
      'unbilled_items', v_unbilled, 'items_without_supplier', v_nosup,
      'message', v_unbilled || ' item(s) on this order are not yet covered by a supplier bill'
                 || case when v_nosup > 0 then ' (' || v_nosup || ' still awaiting a supplier).'
                         else '.' end);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product',  coalesce(m.product_name, b.raw_name),
           'company',  m.marketer,
           'pack',     m.pack_qty,
           'hsn',      b.hsn,
           'batch_no', b.batch_no,
           'expiry',   b.expiry,
           'qty',      a.qty,
           'free_qty', b.free_qty,
           'mrp',      b.mrp,
           'ptr',      b.ptr,
           'gst_pct',  coalesce(b.gst_pct,0))
         order by coalesce(m.product_name, b.raw_name), b.batch_no), '[]'::jsonb)
    into v_raw
  from public.bill_line_allocations a
  join public.bill_lines b on b.id = a.bill_line_id
  left join public."MEDICINE" m on m.id = b.product_id
  where a.order_id = p_order_id and b.verified;

  select coalesce(sum(amount),0) into v_paid
  from public.payment_claims
  where order_id = p_order_id
    and status not in ('rejected','duplicate','need_details');

  select round(coalesce(sum(oi.quantity*oi.mrp),0) * coalesce(cfg.advance_pct,30)/100, 2)
    into v_adv from public.order_items oi where oi.order_id = p_order_id;

  -- CHANGE #309: the taxable value of the goods, computed the same way the
  -- composer does, so the free-above threshold and the printed invoice agree.
  -- CHANGE #318: that same PRE-DISCOUNT figure is the number the slab is
  -- measured on — the sum of the printed Value column, never MRP and never
  -- GST-inclusive. An issued bill answers with its frozen slab instead.
  select coalesce(sum(round(qty*ptr,2)),0) into v_base
    from (select coalesce((e->>'qty')::numeric,0) qty, coalesce((e->>'ptr')::numeric,0) ptr
            from jsonb_array_elements(coalesce(v_raw,'[]'::jsonb)) e) t;

  v_slab := public._order_slab_for_bill(p_order_id, v_base);
  v_taxable := round(v_base * (100 - coalesce((v_slab->>'discount_pct')::numeric,0)) / 100, 2);

  v_del := public._order_delivery_charge(p_order_id, v_taxable);
  v_credits := public._order_credit_notes(p_order_id);

  return public._bill_compose(
    v_raw,
    jsonb_build_object(
      'number', coalesce(cfg.invoice_prefix,'MB') || '-' || coalesce(o.order_code,''),
      'date',   to_char(now() at time zone 'Asia/Kolkata','DD/MM/YYYY'),
      'slab',   v_slab,
      'buyer',  jsonb_build_object(
        'name',    coalesce(ph.pharmacy_name, o.pharmacy_name),
        'gstin',   coalesce(ph.gstin, ph.gst_no),
        'dl',      coalesce(ph.drug_license, ph.dl_20b),
        'address', coalesce(ph.address, o.address),
        'state',   ph.state,
        'phone',   coalesce(ph.phone, o.phone))),
    v_paid, v_adv, false, null, v_del, v_credits);
end $function$;

-- The ONE place a bill becomes real: the renderer asks for its input. Taking
-- the snapshot here — and nowhere in the read paths — means an admin preview
-- never accidentally locks a rate, and a retry of the same job reprints the
-- rate the first attempt used.
create or replace function public.bill_job_render_input(p_job_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare j public.bill_jobs%rowtype; v_code text;
begin
  select * into j from public.bill_jobs where id = p_job_id;
  if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
  select order_code into v_code from orders where id = j.order_id;

  -- CHANGE #318 — freeze the slab before the invoice is composed. Idempotent:
  -- an order that already carries one keeps it.
  if coalesce((public._bill_ready(j.order_id)->>'ready')::boolean, false) then
    perform public.order_slab_snapshot(j.order_id);
  end if;

  return jsonb_build_object('ok', true, 'job_id', j.id, 'order_id', j.order_id,
    'order_code', coalesce(v_code,''), 'attempt', j.attempts,
    'bucket','customer-bills', 'bill', public.customer_bill(j.order_id));
end $function$;

-- ── Copy ────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('bill.slab_locked_note',  to_jsonb('Discount rate locked to this invoice.'::text)),
  ('bill.slab_live_note',    to_jsonb('Discount is decided from the slab table when the bill is generated.'::text)),
  ('admin_nav.overflow_discount_slabs', to_jsonb('Discount slabs'::text)),
  ('slabs.title',            to_jsonb('Discount slabs'::text)),
  ('slabs.subtitle',         to_jsonb('The discount every customer bill is priced at. The highest slab the bill clears wins, measured on the pre-discount taxable total.'::text)),
  ('slabs.commitment_note',  to_jsonb('The slab is a commitment to the customer. It applies whatever we bought the item at — never capped or overridden for margin.'::text)),
  ('slabs.add_label',        to_jsonb('Add slab'::text)),
  ('slabs.edit_label',       to_jsonb('Edit'::text)),
  ('slabs.save_label',       to_jsonb('Save slab'::text)),
  ('slabs.cancel_label',     to_jsonb('Cancel'::text)),
  ('slabs.delete_label',     to_jsonb('Delete'::text)),
  ('slabs.delete_confirm',   to_jsonb('Delete this slab? Bills already issued keep the rate they were billed at.'::text)),
  ('slabs.activate_label',   to_jsonb('Activate'::text)),
  ('slabs.deactivate_label', to_jsonb('Deactivate'::text)),
  ('slabs.empty_title',      to_jsonb('No slabs yet'::text)),
  ('slabs.empty_hint',       to_jsonb('Add a slab and every bill above its amount is discounted at that rate.'::text)),
  ('slabs.saved_toast',      to_jsonb('Slab saved.'::text)),
  ('slabs.deleted_toast',    to_jsonb('Slab deleted.'::text)),
  ('slabs.not_authorized',   to_jsonb('Only an admin can change the discount ladder.'::text)),
  ('slabs.field_min_amount', to_jsonb('Above amount (₹)'::text)),
  ('slabs.field_discount_pct', to_jsonb('Discount %'::text)),
  ('slabs.field_effective_from', to_jsonb('Effective from (YYYY-MM-DD)'::text)),
  ('slabs.field_note',       to_jsonb('Note (optional)'::text)),
  ('slabs.hint_min_amount',  to_jsonb('A bill whose taxable total is above this gets this discount.'::text)),
  ('slabs.hint_discount_pct', to_jsonb('Percent off Rate × Qty, taken before GST.'::text)),
  ('slabs.hint_effective_from', to_jsonb('The day this slab starts applying. Bills issued before it are untouched.'::text)),
  ('slabs.err_min_amount',   to_jsonb('Enter an amount of 0 or more.'::text)),
  ('slabs.err_discount_pct', to_jsonb('Enter a discount between 0 and 100.'::text)),
  ('slabs.err_duplicate',    to_jsonb('A slab for that amount already starts on that date.'::text)),
  ('slabs.scheduled_label',  to_jsonb('Scheduled'::text)),
  ('slabs.active_label',     to_jsonb('Active'::text)),
  ('slabs.inactive_label',   to_jsonb('Off'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();
-- CHANGE #318 part E — the admin surface over the ladder.
--
-- Every word this screen prints comes from here. Adding a sixth slab is an
-- INSERT through admin_discount_slab_save(), never a code change.

create or replace function public._slab_can_admin()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(public.get_my_role(),'') in ('admin','super_admin');
$function$;

create or replace function public.admin_discount_slabs()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb; v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public._slab_can_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('slabs.not_authorized'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',             s.id,
           'min_amount',     s.min_amount,
           'discount_pct',   s.discount_pct,
           'effective_from', to_char(s.effective_from,'YYYY-MM-DD'),
           'active',         s.active,
           'note',           coalesce(s.note,''),
           'amount_label',   'Above ' || public.inr_money(s.min_amount),
           'pct_label',      trim_scale(s.discount_pct)::text || '%',
           'effective_label','From ' || to_char(s.effective_from,'DD Mon YYYY'),
           'status_label',   case when not s.active then public._c('slabs.inactive_label')
                                  when s.effective_from > v_today then public._c('slabs.scheduled_label')
                                  else public._c('slabs.active_label') end,
           'status_tone',    case when not s.active then 'neutral'
                                  when s.effective_from > v_today then 'info'
                                  else 'success' end,
           'toggle_label',   case when s.active then public._c('slabs.deactivate_label')
                                  else public._c('slabs.activate_label') end,
           'toggle_to',      not s.active)
         order by s.min_amount, s.effective_from), '[]'::jsonb)
    into v_rows
  from public.discount_slabs s;

  return jsonb_build_object(
    'ok',            true,
    'title',         public._c('slabs.title'),
    'subtitle',      public._c('slabs.subtitle'),
    'commitment_note', public._c('slabs.commitment_note'),
    'add_label',     public._c('slabs.add_label'),
    'edit_label',    public._c('slabs.edit_label'),
    'save_label',    public._c('slabs.save_label'),
    'cancel_label',  public._c('slabs.cancel_label'),
    'delete_label',  public._c('slabs.delete_label'),
    'delete_confirm',public._c('slabs.delete_confirm'),
    'empty_title',   public._c('slabs.empty_title'),
    'empty_hint',    public._c('slabs.empty_hint'),
    'fields', jsonb_build_array(
      jsonb_build_object('key','min_amount','label',public._c('slabs.field_min_amount'),
                         'hint',public._c('slabs.hint_min_amount'),'kind','number'),
      jsonb_build_object('key','discount_pct','label',public._c('slabs.field_discount_pct'),
                         'hint',public._c('slabs.hint_discount_pct'),'kind','number'),
      jsonb_build_object('key','effective_from','label',public._c('slabs.field_effective_from'),
                         'hint',public._c('slabs.hint_effective_from'),'kind','date'),
      jsonb_build_object('key','note','label',public._c('slabs.field_note'),
                         'hint','','kind','text')),
    'rows',          v_rows,
    'today',         to_char(v_today,'YYYY-MM-DD'));
end $function$;

create or replace function public.admin_discount_slab_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_min numeric; v_pct numeric; v_from date; v_note text; v_id bigint;
begin
  if not public._slab_can_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('slabs.not_authorized'));
  end if;

  v_min  := nullif(btrim(coalesce(p->>'min_amount','')),'')::numeric;
  v_pct  := nullif(btrim(coalesce(p->>'discount_pct','')),'')::numeric;
  v_from := coalesce(nullif(btrim(coalesce(p->>'effective_from','')),'')::date,
                     (now() at time zone 'Asia/Kolkata')::date);
  v_note := nullif(btrim(coalesce(p->>'note','')),'');
  v_id   := nullif(btrim(coalesce(p->>'id','')),'')::bigint;

  if v_min is null or v_min < 0 then
    return jsonb_build_object('ok', false, 'error','bad_min_amount',
                              'message', public._c('slabs.err_min_amount'));
  end if;
  if v_pct is null or v_pct < 0 or v_pct > 100 then
    return jsonb_build_object('ok', false, 'error','bad_discount_pct',
                              'message', public._c('slabs.err_discount_pct'));
  end if;

  if exists (select 1 from public.discount_slabs s
              where s.min_amount = v_min and s.effective_from = v_from
                and (v_id is null or s.id <> v_id)) then
    return jsonb_build_object('ok', false, 'error','duplicate',
                              'message', public._c('slabs.err_duplicate'));
  end if;

  if v_id is not null then
    update public.discount_slabs
       set min_amount = v_min, discount_pct = v_pct, effective_from = v_from,
           note = v_note,
           active = coalesce((p->>'active')::boolean, active),
           updated_at = now()
     where id = v_id;
  else
    insert into public.discount_slabs (min_amount, discount_pct, effective_from, note, active)
    values (v_min, v_pct, v_from, v_note, coalesce((p->>'active')::boolean, true))
    returning id into v_id;
  end if;

  return public.admin_discount_slabs()
         || jsonb_build_object('toast', public._c('slabs.saved_toast'), 'saved_id', v_id);
end $function$;

create or replace function public.admin_discount_slab_set_active(p_id bigint, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not public._slab_can_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('slabs.not_authorized'));
  end if;
  update public.discount_slabs
     set active = coalesce(p_active, true), updated_at = now()
   where id = p_id;
  return public.admin_discount_slabs()
         || jsonb_build_object('toast', public._c('slabs.saved_toast'));
end $function$;

-- Deleting a slab changes what FUTURE bills are priced at. It cannot reach a
-- bill that already snapshotted it: that order carries its own frozen pct.
create or replace function public.admin_discount_slab_delete(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not public._slab_can_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('slabs.not_authorized'));
  end if;
  delete from public.discount_slabs where id = p_id;
  return public.admin_discount_slabs()
         || jsonb_build_object('toast', public._c('slabs.deleted_toast'));
end $function$;

grant execute on function public.admin_discount_slabs() to authenticated;
grant execute on function public.admin_discount_slab_save(jsonb) to authenticated;
grant execute on function public.admin_discount_slab_set_active(bigint, boolean) to authenticated;
grant execute on function public.admin_discount_slab_delete(bigint) to authenticated;
grant execute on function public.discount_slab_pick(numeric, timestamptz) to authenticated;
