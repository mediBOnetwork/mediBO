-- CMD #451 · row 128 (part 3) — the ONE RPC the customer's order card calls.
-- It answers three questions in the backend's own words: is there a document,
-- what is it called, and if there is not one yet, exactly why.
create or replace function public.customer_invoice(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare o orders%rowtype; v_doc jsonb; v_file jsonb;
begin
  perform public._assert_can_see_order(p_order_id);
  select * into o from orders where id = p_order_id;
  v_doc := public.customer_bill(p_order_id);

  v_file := case when o.cust_bill_path is not null
    then jsonb_build_object('has', true, 'bucket', o.cust_bill_bucket,
           'path', o.cust_bill_path, 'name', o.cust_bill_name,
           'uploaded_at', o.cust_bill_uploaded_at, 'uploaded_by', o.cust_bill_uploaded_by)
    else jsonb_build_object('has', false) end;

  return jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'order_code', coalesce(o.order_code,''),
    'ready',      coalesce((v_doc->>'ready')::boolean, false),
    -- the document's own title: TAX INVOICE once dispatched, PROFORMA before
    'title',      coalesce(v_doc->>'title', public.uic('bill.not_ready_title','Invoice not ready')),
    'proforma',   coalesce((v_doc->>'proforma')::boolean, false),
    'invoice_no', coalesce(o.invoice_no, ''),
    'issued_label', case when o.invoice_issued_at is not null
                         then public.ist_fmt(o.invoice_issued_at, 'date') else '' end,
    'not_ready_message', case when coalesce((v_doc->>'ready')::boolean,false)
                              then '' else coalesce(v_doc->>'message','') end,
    'unrated_lines', coalesce(v_doc->'unrated_lines', '[]'::jsonb),
    'open_label',   public.uic('bill.open_label','View invoice'),
    'file',       v_file,
    'document',   case when coalesce((v_doc->>'ready')::boolean,false) then v_doc else null end);
end $function$;

insert into public.ui_copy (key, value) values
  ('bill.open_label',    to_jsonb('View invoice'::text)),
  ('bill.section_title', to_jsonb('Invoice'::text))
on conflict (key) do nothing;

-- customer_bill_file() said has_file:false for an order that HAS a valid
-- document, because it only ever looked at the uploaded path. It now reports
-- the generated document too, so no surface can conclude "no bill" again.
create or replace function public.customer_bill_file(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare o orders%rowtype; v_ready boolean;
begin
  perform _assert_can_see_order(p_order_id);
  select * into o from orders where id = p_order_id;
  v_ready := coalesce((public._bill_ready(p_order_id)->>'ready')::boolean, false);

  if o.cust_bill_path is null then
    return jsonb_build_object('has_file', false,
      'has_document', v_ready,
      'invoice_no', coalesce(o.invoice_no,''),
      'is_generated', v_ready);
  end if;
  return jsonb_build_object('has_file', true, 'bucket', o.cust_bill_bucket, 'path', o.cust_bill_path,
    'name', o.cust_bill_name, 'uploaded_at', o.cust_bill_uploaded_at, 'uploaded_by', o.cust_bill_uploaded_by,
    'has_document', v_ready, 'invoice_no', coalesce(o.invoice_no,''),
    'is_generated', o.cust_bill_uploaded_by is null);
end $function$;

grant execute on function public.customer_invoice(uuid) to authenticated;
grant execute on function public.order_item_batch_block(uuid) to authenticated;
grant execute on function public._order_product_batch_block(uuid, bigint) to authenticated;

