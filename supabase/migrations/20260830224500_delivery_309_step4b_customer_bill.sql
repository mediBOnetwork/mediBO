-- CHANGE #309 step 4b — customer_bill hands the delivery charge and the
-- doorstep credit notes to the composer.
--
-- The charge is stamped against the TAXABLE value of the goods (trade rate less
-- discount), never against MRP — the business context is explicit that any
-- build which prices or thresholds on MRP is wrong.
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

  -- CHANGE #309: the taxable value of the goods. This is the figure the
  -- free-above threshold is measured against — the trade value less the
  -- discount slab, NEVER MRP (the business context is explicit that any build
  -- which prices or thresholds on MRP is wrong).
  --
  -- It applies the slab to the ORDER total, where the composer applies it per
  -- line and sums; across every live slab (0/3/5%) the two agree exactly,
  -- verified for 500/1000/3000/5000/9000/25000. A multi-line order could in
  -- principle differ by a paisa of rounding, and that is deliberately
  -- tolerable: this number only decides which side of the free-delivery
  -- threshold the order falls on. The money actually PRINTED on the invoice is
  -- always the composer's own per-line arithmetic, never this.
  select coalesce(sum(round(qty*ptr,2)),0) into v_taxable
    from (select coalesce((e->>'qty')::numeric,0) qty, coalesce((e->>'ptr')::numeric,0) ptr
            from jsonb_array_elements(coalesce(v_raw,'[]'::jsonb)) e) t;
  v_taxable := round(v_taxable * (100 - coalesce(public.ptr_discount_pct(v_taxable),0)) / 100, 2);

  v_del := public._order_delivery_charge(p_order_id, v_taxable);
  v_credits := public._order_credit_notes(p_order_id);

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
    v_paid, v_adv, false, null, v_del, v_credits);
end $function$;
