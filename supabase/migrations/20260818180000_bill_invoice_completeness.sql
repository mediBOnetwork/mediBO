-- CHANGE #236 — the customer invoice, complete.
--
-- #226 built the automatic bill chain (customer_bill -> bill-render -> WhatsApp).
-- The page it drew was missing half of what a GST tax invoice must carry: HSN per
-- line, free quantity, the seller's FSSAI, an HSN-wise tax summary, item/quantity
-- counts, bank + UPI payment details, the jurisdiction line and a signature block.
--
-- This migration:
--   1. gives bill_lines an HSN column and billing_config the invoice identity /
--      bank fields (all nullable, all editable from the existing admin
--      "Platform Details" form — no new screen, no deploy);
--   2. splits the money out of customer_bill() into _bill_compose(), the ONE place
--      a bill is priced, formatted and worded;
--   3. adds customer_bill_sample() — a fully fake invoice that runs through the
--      SAME _bill_compose() and therefore the SAME renderer, so a sample is proof
--      of the real layout rather than a mock of it.
--
-- Nothing here computes in Dart or in the edge function: the renderer only draws
-- the strings this file produces.

-- ── 1. columns ──────────────────────────────────────────────────────────────
alter table public.bill_lines    add column if not exists hsn text;

alter table public.billing_config add column if not exists seller_fssai   text;
alter table public.billing_config add column if not exists seller_phone   text;
alter table public.billing_config add column if not exists seller_email   text;
alter table public.billing_config add column if not exists bank_name      text;
alter table public.billing_config add column if not exists bank_account   text;
alter table public.billing_config add column if not exists bank_ifsc      text;
alter table public.billing_config add column if not exists bank_branch    text;
alter table public.billing_config add column if not exists jurisdiction   text;
alter table public.billing_config add column if not exists default_hsn    text;
alter table public.billing_config add column if not exists invoice_terms  text;

update public.billing_config
   set default_hsn   = coalesce(default_hsn, '3004'),
       jurisdiction  = coalesce(jurisdiction,
                        'Subject to ' || coalesce(seller_state,'Chhattisgarh') || ' jurisdiction only.'),
       invoice_terms = coalesce(invoice_terms,
                        'E. & O.E.  |  Goods once sold will not be taken back.  |  '
                        || 'Interest @18% p.a. is chargeable on bills not paid on the due date.')
 where id = 1;

-- ── 2. the one composer ─────────────────────────────────────────────────────
-- Everything a bill says is decided here: the slab, the per-line maths, every
-- ₹ string, the tax summaries, the counts, the payment block and the footer.
-- Callers only supply raw lines + who the buyer is.
create or replace function public._bill_compose(
  p_lines   jsonb,                     -- [{product,company,pack,hsn,batch_no,expiry,qty,free_qty,mrp,ptr,gst_pct}]
  p_invoice jsonb,                     -- {number,date,buyer:{name,gstin,dl,address,phone,state}}
  p_paid    numeric default 0,
  p_advance numeric default 0,
  p_sample  boolean default false,
  p_bank    jsonb   default null)      -- sample override for the bank block
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  cfg public.billing_config%rowtype;
  v_pa text; v_pn text;
  v_pct numeric; v_ptr_total numeric := 0;
  v_lines jsonb; v_hsn jsonb; v_gstsum jsonb;
  v_mrp numeric; v_disc numeric; v_taxable numeric; v_gst numeric;
  v_items int; v_qty numeric; v_free numeric;
  v_grand numeric; v_final numeric; v_round numeric; v_remaining numeric;
  v_bank jsonb; v_banklines jsonb; v_seller jsonb;
begin
  select * into cfg from public.billing_config where id = 1;
  select pa, pn into v_pa, v_pn
    from public.payment_upi_accounts where is_active order by created_at desc limit 1;

  with r as (
    select coalesce((e->>'qty')::numeric,0) qty, coalesce((e->>'ptr')::numeric,0) ptr
      from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e)
  select coalesce(sum(qty*ptr),0) into v_ptr_total from r;

  v_pct := public.ptr_discount_pct(v_ptr_total);

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
  c as (
    select r.*,
           round(qty*mrp, 2)                                  line_mrp,
           round(qty*ptr, 2)                                  line_ptr,
           round(qty*ptr*v_pct/100, 2)                        disc_amt,
           round(qty*ptr*(1 - v_pct/100), 2)                  taxable,
           round(qty*ptr*(1 - v_pct/100)*gst_pct/100, 2)      gst_amt
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

  v_grand     := round(coalesce(v_taxable,0) + coalesce(v_gst,0), 2);
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
      'discount_amount_label', '− ₹' || to_char(v_disc,'FM99,99,990.00'),
      'taxable_label',         '₹' || to_char(v_taxable,'FM99,99,990.00'),
      'cgst_label',            '₹' || to_char(round(v_gst/2,2),'FM99,99,990.00'),
      'sgst_label',            '₹' || to_char(round(v_gst/2,2),'FM99,99,990.00'),
      'gst_total_label',       '₹' || to_char(v_gst,'FM99,99,990.00'),
      'round_off_label',       case when v_round <> 0
                                    then (case when v_round > 0 then '+ ₹' else '− ₹' end)
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
end $fn$;

-- ── 3. customer_bill(), now a thin gatherer over the composer ───────────────
create or replace function public.customer_bill(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  cfg public.billing_config%rowtype;
  o   public.orders%rowtype;
  ph  public.pharmacy_profiles%rowtype;
  v_unbilled int; v_nosup int;
  v_raw jsonb; v_paid numeric; v_adv numeric;
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

  return public._bill_compose(
    v_raw,
    jsonb_build_object(
      'number', coalesce(cfg.invoice_prefix,'MB') || '-' || coalesce(o.order_code,''),
      'date',   to_char(now() at time zone 'Asia/Kolkata','DD/MM/YYYY'),
      'buyer',  jsonb_build_object(
        'name',    coalesce(ph.pharmacy_name, o.pharmacy_name),
        'gstin',   coalesce(ph.gstin, ph.gst_no),
        'dl',      coalesce(ph.drug_license, ph.dl_20b),
        'address', coalesce(ph.address, o.address),
        'state',   ph.state,
        'phone',   coalesce(ph.phone, o.phone))),
    v_paid, v_adv, false, null);
end $fn$;

-- ── 4. the sample ───────────────────────────────────────────────────────────
-- Fictitious buyer, products, batches and amounts — run through the SAME
-- composer, so what comes out is the real invoice, not a drawing of one.
create or replace function public.customer_bill_sample()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_lines jsonb; v_bank jsonb;
begin
  v_lines := jsonb_build_array(
    jsonb_build_object('product','Dolo 650 Tablet','company','Micro Labs Ltd','pack','15 tablets',
      'hsn','3004','batch_no','DLO24A117','expiry','07/27','qty',20,'free_qty',2,'mrp',30.36,'ptr',21.68,'gst_pct',12),
    jsonb_build_object('product','Dolo 650 Tablet','company','Micro Labs Ltd','pack','15 tablets',
      'hsn','3004','batch_no','DLO25B042','expiry','11/27','qty',10,'free_qty',0,'mrp',30.36,'ptr',21.68,'gst_pct',12),
    jsonb_build_object('product','Azithral 500 Tablet','company','Alembic Pharmaceuticals Ltd','pack','5 tablets',
      'hsn','3004','batch_no','AZL25C338','expiry','03/28','qty',15,'free_qty',0,'mrp',118.50,'ptr',84.64,'gst_pct',12),
    jsonb_build_object('product','Pan-D Capsule','company','Alkem Laboratories Ltd','pack','15 capsules',
      'hsn','3004','batch_no','PND24K905','expiry','09/27','qty',10,'free_qty',1,'mrp',245.00,'ptr',175.00,'gst_pct',12),
    jsonb_build_object('product','Monocef 1gm Injection','company','Aristo Pharmaceuticals Pvt Ltd','pack','1 vial',
      'hsn','3004','batch_no','MNC25A071','expiry','05/27','qty',10,'free_qty',0,'mrp',92.00,'ptr',65.71,'gst_pct',12),
    jsonb_build_object('product','Zincovit Tablet','company','Apex Laboratories Pvt Ltd','pack','15 tablets',
      'hsn','3004','batch_no','ZNV24L226','expiry','12/27','qty',20,'free_qty',2,'mrp',112.00,'ptr',80.00,'gst_pct',12),
    jsonb_build_object('product','Dettol Antiseptic Liquid 550ml','company','Reckitt Benckiser India Ltd','pack','1 bottle',
      'hsn','3808','batch_no','DTL25C614','expiry','08/28','qty',6,'free_qty',0,'mrp',285.00,'ptr',213.75,'gst_pct',18),
    jsonb_build_object('product','Accu-Chek Active Test Strips','company','Roche Diabetes Care India Pvt Ltd','pack','50 strips',
      'hsn','3822','batch_no','ACT25B489','expiry','06/27','qty',2,'free_qty',0,'mrp',1150.00,'ptr',920.00,'gst_pct',12));

  v_bank := jsonb_build_object(
    'name','Sample Bank of India (SAMPLE)',
    'account','0000 1111 2222 3333',
    'ifsc','SAMP0000123',
    'branch','Raipur — SAMPLE');

  return public._bill_compose(
    v_lines,
    jsonb_build_object(
      'number', 'MB-SAMPLE-0001',
      'date',   to_char(now() at time zone 'Asia/Kolkata','DD/MM/YYYY'),
      'buyer',  jsonb_build_object(
        'name',    'Sunrise Medical Store (SAMPLE — NOT A REAL BUYER)',
        'gstin',   '22AAAAA0000A1Z5',
        'dl',      '20B: SAMPLE/20B/0000  |  21B: SAMPLE/21B/0000',
        'address', 'Shop 4, Sample Market Road, Raipur, Chhattisgarh 492001',
        'state',   'Chhattisgarh',
        'phone',   '90000 00000')),
    0, 0, true, v_bank);
end $fn$;

revoke all on function public._bill_compose(jsonb,jsonb,numeric,numeric,boolean,jsonb) from public, anon, authenticated;
revoke all on function public.customer_bill_sample()                                   from public, anon;
grant  execute on function public.customer_bill_sample()                               to service_role;
