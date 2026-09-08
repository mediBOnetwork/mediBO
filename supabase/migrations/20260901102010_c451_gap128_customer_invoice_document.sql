-- CMD #451 · row 128 (part 2) — ONE customer-facing invoice document.
--
-- Rate resolution, in order, because a tax invoice may never price on MRP
-- (business rule: MRP is a regulatory ceiling, not a selling price):
--   1. the VERIFIED supplier bill line allocated to the order line  (receiving truth)
--   2. medicine_pricing.ptr where the catalogue carries a real trade rate
--   3. no rate  ->  the line is 'rate pending' and the document is NOT ready,
--      and the payload NAMES those lines instead of showing an empty file card.
--
-- order_items.price and .gst_percent are NULL on every one of the 290 live
-- lines, so nothing here can fall back to the order line's own rate.

create or replace function public._bill_lines_for_order(p_order_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with billable as (
    select oi.* from order_items oi
     where oi.order_id = p_order_id
       and oi.fulfillment_state not in ('shipped','cancelled')
       and coalesce(oi.unfulfillable,false) = false
  ),
  -- 1. every verified supplier bill line allocated to this order
  covered as (
    select a.order_item_id,
           coalesce(m.product_name, b.raw_name) as product,
           m.marketer as company, m.pack_qty as pack,
           b.hsn, b.batch_no, b.expiry,
           a.qty, b.free_qty, b.mrp, b.ptr, coalesce(b.gst_pct,0) as gst_pct,
           'supplier_bill'::text as rate_source
      from bill_line_allocations a
      join bill_lines b on b.id = a.bill_line_id
      left join public."MEDICINE" m on m.id = b.product_id
     where a.order_id = p_order_id and b.verified and b.needs_fix is null
  ),
  -- 2. an uncovered line priced from the catalogue's own trade rate
  from_catalogue as (
    select bi.id as order_item_id,
           coalesce(m.product_name, bi.product_name) as product,
           m.marketer as company, m.pack_qty as pack,
           coalesce(nullif(btrim(bi.hsn),''), null) as hsn,
           nullif(btrim(bi.batch_no),'') as batch_no,
           nullif(btrim(bi.expiry),'')   as expiry,
           bi.quantity::numeric as qty, 0::numeric as free_qty,
           nullif(regexp_replace(coalesce(bi.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp,
           mp.ptr,
           coalesce(mp.gst_pct, bi.gst_percent, m.gst_percent, 0)::numeric as gst_pct,
           'catalogue_rate'::text as rate_source
      from billable bi
      left join public."MEDICINE" m on m.id = bi.product_id
      join public.medicine_pricing mp on mp.product_id = bi.product_id
                                     and mp.ptr is not null
     where not exists (select 1 from covered c where c.order_item_id = bi.id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'product', x.product, 'company', x.company, 'pack', x.pack,
           'hsn', x.hsn, 'batch_no', x.batch_no, 'expiry', x.expiry,
           'qty', x.qty, 'free_qty', x.free_qty, 'mrp', x.mrp, 'ptr', x.ptr,
           'gst_pct', x.gst_pct, 'rate_source', x.rate_source)
         order by x.product, x.batch_no), '[]'::jsonb)
    from (select * from covered union all select * from from_catalogue) x;
$function$;

-- Which billable lines still have no rate from ANY source. This replaces the
-- old "not covered by a supplier bill" count, which could not see a line that a
-- catalogue rate had since made billable.
create or replace function public._bill_unrated_lines(p_order_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'order_item_id', oi.id,
           'product', coalesce(m.product_name, oi.product_name),
           'reason', case when oi.assigned_supplier is null
                          then public.uic('bill.line_no_supplier','No supplier assigned yet')
                          else public.uic('bill.line_no_rate','Waiting for the supplier bill') end)
         order by coalesce(m.product_name, oi.product_name)), '[]'::jsonb)
    from order_items oi
    left join public."MEDICINE" m on m.id = oi.product_id
   where oi.order_id = p_order_id
     and oi.fulfillment_state not in ('shipped','cancelled')
     and coalesce(oi.unfulfillable,false) = false
     and not exists (select 1 from bill_line_allocations a
                      join bill_lines b on b.id = a.bill_line_id
                     where a.order_item_id = oi.id and b.verified and b.needs_fix is null)
     and not exists (select 1 from medicine_pricing mp
                     where mp.product_id = oi.product_id and mp.ptr is not null);
$function$;

insert into public.ui_copy (key, value) values
  ('bill.line_no_supplier', to_jsonb('No supplier assigned yet'::text)),
  ('bill.line_no_rate',     to_jsonb('Waiting for the supplier bill'::text)),
  ('bill.not_ready_title',  to_jsonb('Invoice not ready'::text))
on conflict (key) do nothing;

create or replace function public._bill_ready(p_order_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_unrated jsonb; v_billable int; v_nosup int;
begin
  select count(*) into v_billable
  from order_items oi
  where oi.order_id = p_order_id
    and oi.fulfillment_state not in ('shipped','cancelled')
    and coalesce(oi.unfulfillable,false) = false;

  v_unrated := public._bill_unrated_lines(p_order_id);

  select count(*) into v_nosup
  from order_items oi
  where oi.order_id = p_order_id
    and oi.fulfillment_state not in ('shipped','cancelled')
    and coalesce(oi.unfulfillable,false) = false
    and oi.assigned_supplier is null;

  return jsonb_build_object(
    'ready', jsonb_array_length(v_unrated) = 0 and coalesce(v_billable,0) > 0,
    'billable', coalesce(v_billable,0),
    'uncovered', jsonb_array_length(v_unrated),
    'unrated_lines', v_unrated,
    'items_without_supplier', coalesce(v_nosup,0),
    'waiting_suppliers', to_jsonb(coalesce((
      select array_agg(distinct oi.assigned_supplier)
        from order_items oi
       where oi.order_id = p_order_id and oi.assigned_supplier is not null), '{}')));
end $function$;

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
  v_ready jsonb; v_raw jsonb; v_paid numeric; v_adv numeric;
  v_base numeric; v_slab jsonb; v_taxable numeric; v_del jsonb; v_credits jsonb;
  v_supplied boolean; v_doc jsonb; v_number text;
begin
  perform public._assert_can_see_order(p_order_id);
  select * into cfg from public.billing_config where id = 1;
  select * into o   from public.orders where id = p_order_id;
  select * into ph  from public.pharmacy_profiles where user_id = o.user_id limit 1;

  v_ready := public._bill_ready(p_order_id);
  if not (v_ready->>'ready')::boolean then
    return jsonb_build_object('ready', false,
      'status_label', public.uic('bill.not_ready_title','Invoice not ready'),
      'unbilled_items', (v_ready->>'uncovered')::int,
      'items_without_supplier', (v_ready->>'items_without_supplier')::int,
      'unrated_lines', v_ready->'unrated_lines',
      'message', (v_ready->>'uncovered') || ' item(s) on this order do not have a rate yet'
                 || case when (v_ready->>'items_without_supplier')::int > 0
                         then ' (' || (v_ready->>'items_without_supplier')
                              || ' still awaiting a supplier).'
                         else '.' end);
  end if;

  v_raw    := public._bill_lines_for_order(p_order_id);
  v_paid   := public._order_paid_net(p_order_id);
  v_supplied := public._order_is_supplied(p_order_id);

  -- The number is drawn from the statutory series ONLY for a real supply, and
  -- only once. A proforma stays unnumbered.
  if v_supplied then
    perform public.customer_invoice_issue(p_order_id);
    select invoice_no into v_number from orders where id = p_order_id;
    perform public.order_slab_snapshot(p_order_id);
  end if;

  select round(coalesce(sum(oi.quantity*oi.mrp),0) * coalesce(cfg.advance_pct,30)/100, 2)
    into v_adv from public.order_items oi where oi.order_id = p_order_id;

  select coalesce(sum(round(qty*ptr,2)),0) into v_base
    from (select coalesce((e->>'qty')::numeric,0) qty, coalesce((e->>'ptr')::numeric,0) ptr
            from jsonb_array_elements(coalesce(v_raw,'[]'::jsonb)) e) t;

  v_slab := public._order_slab_for_bill(p_order_id, v_base);
  v_taxable := round(v_base * (100 - coalesce((v_slab->>'discount_pct')::numeric,0)) / 100, 2);
  v_del := public._order_delivery_charge(p_order_id, v_taxable);
  v_credits := public._order_credit_notes(p_order_id);

  v_doc := public._bill_compose(
    v_raw,
    jsonb_build_object(
      'number', coalesce(v_number,
                         coalesce(cfg.invoice_prefix,'MB') || '-' || coalesce(o.order_code,'')),
      'date',   to_char(coalesce(o.invoice_issued_at, now()) at time zone 'Asia/Kolkata','DD/MM/YYYY'),
      'slab',   v_slab,
      'buyer',  jsonb_build_object(
        'name',    coalesce(ph.pharmacy_name, o.pharmacy_name),
        'gstin',   coalesce(ph.gstin, ph.gst_no),
        'dl',      coalesce(ph.drug_license, ph.dl_20b),
        'address', coalesce(ph.address, o.address),
        'state',   ph.state,
        'phone',   coalesce(ph.phone, o.phone))),
    v_paid, v_adv, false, null, v_del, v_credits);

  -- Proforma vs tax invoice is the BACKEND's word, and it is the only thing
  -- that overrides _bill_compose's own titling.
  if not v_supplied then
    v_doc := v_doc
      || jsonb_build_object(
           'title',           public.uic('bill.proforma_title','PROFORMA INVOICE'),
           'proforma',        true,
           'proforma_banner', public.uic('bill.proforma_banner',''),
           'proforma_reason', public.uic('bill.proforma_reason',
                                         'A tax invoice is raised when the order is dispatched.'));
    v_doc := jsonb_set(v_doc, '{invoice,number}', to_jsonb(''::text));
    v_doc := jsonb_set(v_doc, '{invoice,number_pending}',
                       to_jsonb(public.uic('bill.proforma_reason','')));
  else
    v_doc := v_doc || jsonb_build_object('proforma', false, 'invoice_no', v_number);
  end if;

  return v_doc || jsonb_build_object('is_supplied', v_supplied);
end $function$;

