-- CHANGE #309 step 4 — DELIVERY CHARGE, and the margin on every drop.
--
-- The audit found no delivery_charge on orders at all, so delivery was being
-- given away with no record of what it cost. Two numbers are needed, and they
-- are NOT the same number:
--   * what the CUSTOMER is charged  -> flows into the bill and the tax invoice
--   * what the DROP actually COST us -> never shown to the customer, but it is
--     the only way "margin per delivery" can ever be answered
-- Both are stamped on the order/delivery rather than recomputed at read time,
-- because a bill that silently reprices itself when config changes is not a
-- bill. The config is the quote; the stamp is the contract.
--
-- Pricing rule (business context): mediBO prices on PTR-style trade rates, so
-- the free-above threshold is measured against the TAXABLE order value, never
-- against MRP. Any build that thresholds on MRP is wrong.

alter table public.orders
  add column if not exists delivery_charge        numeric(10,2),
  add column if not exists delivery_charge_gst    numeric(10,2),
  add column if not exists delivery_charge_waived boolean,
  add column if not exists delivery_charge_label  text,
  add column if not exists delivery_charge_at     timestamptz;

alter table public.deliveries
  add column if not exists cost_amount  numeric(10,2),   -- what this drop cost us
  add column if not exists cost_source  text;            -- 'rider_rate' | 'zone_config'

-- ── The quote: what delivery would cost, before an order exists ─────────────
-- Used by checkout (there is no order yet) and by the bill (there is). Pure —
-- it writes nothing, so the cart can call it on every keystroke.
create or replace function public.delivery_charge_quote(
  p_zone smallint default null,
  p_order_value numeric default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  cfg jsonb := public._dcfg(p_zone);
  v_charge numeric := coalesce((cfg->>'charge_amount')::numeric, 0);
  v_free_above numeric := coalesce((cfg->>'free_above_amount')::numeric, 0);
  v_gst_pct numeric := coalesce((cfg->>'charge_gst_pct')::numeric, 0);
  v_val numeric := coalesce(p_order_value, 0);
  v_waived boolean;
  v_gst numeric;
  v_short numeric;
begin
  -- free_above of 0 means "never free"; a charge of 0 means delivery is free
  -- for everyone, and neither case should print a threshold note.
  v_waived := (v_charge <= 0) or (v_free_above > 0 and v_val >= v_free_above);
  if v_waived then v_charge := 0; end if;
  v_gst := round(v_charge * v_gst_pct / 100, 2);
  v_short := case when v_free_above > 0 and not v_waived
                  then round(v_free_above - v_val, 2) end;

  return jsonb_build_object(
    'amount',        v_charge,
    'gst_amount',    v_gst,
    'gst_pct',       v_gst_pct,
    'total',         round(v_charge + v_gst, 2),
    'waived',        v_waived,
    'free_above',    v_free_above,
    'label',         case when v_waived then public._c('delivery.charge_free_label')
                          else public._c('delivery.charge_line_label') end,
    'amount_label',  case when v_waived then public._c('delivery.charge_free_label')
                          else public.inr_money(round(v_charge + v_gst, 2)) end,
    'note',          case
                       when v_waived and v_free_above > 0
                         then public._cf('delivery.charge_free_note',
                                jsonb_build_object('threshold', public.inr_money(v_free_above)))
                       when v_short is not null and v_short > 0
                         then public._cf('delivery.charge_note',
                                jsonb_build_object('shortfall', public.inr_money(v_short)))
                       else '' end,
    'shortfall',     v_short);
end $function$;

-- ── The stamp: freeze the charge onto the order ────────────────────────────
-- Called from the bill. Idempotent by design — once delivery_charge_at is set
-- the answer never moves, so a bill regenerated next week still shows the price
-- the customer was actually quoted.
create or replace function public._order_delivery_charge(
  p_order_id uuid, p_taxable numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare o public.orders%rowtype; q jsonb;
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return jsonb_build_object('amount',0,'waived',true); end if;

  if o.delivery_charge_at is not null then
    return jsonb_build_object(
      'amount',       coalesce(o.delivery_charge,0),
      'gst_amount',   coalesce(o.delivery_charge_gst,0),
      'total',        round(coalesce(o.delivery_charge,0) + coalesce(o.delivery_charge_gst,0), 2),
      'waived',       coalesce(o.delivery_charge_waived,true),
      'label',        coalesce(o.delivery_charge_label, public._c('delivery.charge_line_label')),
      'amount_label', case when coalesce(o.delivery_charge_waived,true)
                           then public._c('delivery.charge_free_label')
                           else public.inr_money(round(coalesce(o.delivery_charge,0)
                                                     + coalesce(o.delivery_charge_gst,0), 2)) end,
      'frozen', true);
  end if;

  q := public.delivery_charge_quote(o.zone_id, p_taxable);

  update public.orders
     set delivery_charge        = (q->>'amount')::numeric,
         delivery_charge_gst    = (q->>'gst_amount')::numeric,
         delivery_charge_waived = (q->>'waived')::boolean,
         delivery_charge_label  = q->>'label',
         delivery_charge_at     = now()
   where id = p_order_id;

  return q || jsonb_build_object('frozen', false);
end $function$;

-- ── What the drop cost us ───────────────────────────────────────────────────
-- Stamped when custody passes, because that is the moment the cost is actually
-- incurred. Prefers the rider's own negotiated per-drop rate over the zone
-- default, so an agency on a different rate reports its real margin.
create or replace function public.trg_delivery_stamp_cost()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_rate numeric;
begin
  if new.handover_at is not null and old.handover_at is null and new.cost_amount is null then
    select per_drop_rate into v_rate
      from public.delivery_partner_registrations where id = new.partner_id;
    if v_rate is not null and v_rate > 0 then
      new.cost_amount := v_rate; new.cost_source := 'rider_rate';
    else
      new.cost_amount := coalesce((public._dcfg(new.zone_id)->>'cost_per_drop')::numeric, 0);
      new.cost_source := 'zone_config';
    end if;
  end if;
  return new;
end $function$;

drop trigger if exists trg_delivery_stamp_cost on public.deliveries;
create trigger trg_delivery_stamp_cost
  before update of handover_at on public.deliveries
  for each row execute function public.trg_delivery_stamp_cost();

-- ── The bill learns two new lines ───────────────────────────────────────────
-- _bill_compose gains p_delivery (this step) and p_credits (step 7's doorstep
-- claims). Both are optional with a default, so every existing caller —
-- customer_bill, customer_bill_sample, _peek_bill — keeps working unchanged.
-- Doing both in ONE signature change means one rg_check rebaseline, not two.
--
-- This definition is the LIVE one with four surgical edits (signature, declares,
-- the total, and the new totals keys). It is not a retyped copy: retyping 200
-- lines of invoice arithmetic to add two of them is how a rounding rule quietly
-- changes.

CREATE OR REPLACE FUNCTION public._bill_compose(p_lines jsonb, p_invoice jsonb, p_paid numeric DEFAULT 0, p_advance numeric DEFAULT 0, p_sample boolean DEFAULT false, p_bank jsonb DEFAULT NULL::jsonb, p_delivery jsonb DEFAULT NULL::jsonb, p_credits jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg public.billing_config%rowtype;
  v_pa text; v_pn text;
  v_pct numeric; v_ptr_total numeric := 0;
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
end $function$

;

grant execute on function public.delivery_charge_quote(smallint,numeric) to authenticated;
