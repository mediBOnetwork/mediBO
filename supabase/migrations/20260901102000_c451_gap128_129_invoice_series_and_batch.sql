-- CMD #451 · feature_gaps rows 128 (no system-generated GST tax invoice) and
-- 129 (no batch/expiry on any order line).
--
-- What was already there (CHANGE #226/#309/#318): _bill_compose() composes a
-- complete GST tax invoice — HSN summary, CGST/SGST split, round-off, amount in
-- words, seller GSTIN/DL/FSSAI, buyer GSTIN/DL, batch and expiry columns — and
-- bill-render turns it into a PDF. It has never fired ONCE: bill_jobs is empty,
-- because _bill_ready() demands that EVERY billable line be covered by a
-- VERIFIED supplier bill line, and only one such allocation exists in the whole
-- database. So the customer's only bill really was a human upload
-- (29 of 31 orders had none).
--
-- Three real gaps closed here:
--   1. No invoice NUMBER SERIES. The number was invoice_prefix || order_code —
--      not sequential, not per financial year, not persisted, and it changed if
--      the order code changed. Now: a per-FY series, assigned ONCE, immutable.
--   2. The document could not be composed without a supplier bill import. Now
--      an uncovered line falls back to the ORDER LINE itself (the contractual
--      trade rate, quantity, GST%, batch, expiry), so nothing waits on a human.
--   3. Before supply there is no tax invoice to raise, so the surface showed
--      nothing at all. Now it shows a PROFORMA INVOICE (unnumbered, clearly
--      titled by the backend) and becomes a numbered TAX INVOICE at dispatch.

-- ── 129: the order line's own batch / expiry / HSN ───────────────────────────
alter table public.order_items add column if not exists hsn text;

-- Every batch that actually covers this line. Verified supplier bill lines
-- first (they are the receiving truth), then the pack scan that counted the
-- unit, then whatever was typed onto the line itself. Never invented.
create or replace function public._order_item_batches(p_order_item_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with from_bill as (
    select b.batch_no, b.expiry, a.qty, b.hsn, 'supplier_bill'::text as source
      from bill_line_allocations a
      join bill_lines b on b.id = a.bill_line_id
     where a.order_item_id = p_order_item_id
       and b.verified and b.needs_fix is null
       and coalesce(nullif(btrim(b.batch_no),''), '') <> ''
  ),
  from_pack as (
    select m.batch_no,
           case when m.expiry_date is not null
                then to_char(m.expiry_date, 'MM/YYYY') end as expiry,
           m.qty, null::text as hsn, 'pack_scan'::text as source
      from pack_clip_mentions m
      join order_items oi on oi.order_id = m.order_id
                        and oi.product_id = m.product_id
     where oi.id = p_order_item_id
       and coalesce(nullif(btrim(m.batch_no),''), '') <> ''
       and not exists (select 1 from from_bill)
  ),
  from_line as (
    select oi.batch_no, oi.expiry, oi.quantity::numeric as qty, oi.hsn,
           'order_line'::text as source
      from order_items oi
     where oi.id = p_order_item_id
       and coalesce(nullif(btrim(oi.batch_no),''), '') <> ''
       and not exists (select 1 from from_bill)
       and not exists (select 1 from from_pack)
  ),
  all_rows as (
    select * from from_bill union all select * from from_pack union all select * from from_line)
  select coalesce(jsonb_agg(jsonb_build_object(
           'batch_no', r.batch_no,
           'expiry',   coalesce(r.expiry, ''),
           'qty',      trim_scale(coalesce(r.qty,0))::text,
           'hsn',      coalesce(r.hsn, ''),
           'source',   r.source,
           'label',    public.uic('order_line.batch_word','Batch') || ' ' || r.batch_no
                       || case when coalesce(nullif(btrim(r.expiry),''),'') <> ''
                               then '  ·  ' || public.uic('order_line.expiry_word','Exp')
                                    || ' ' || r.expiry
                               else '' end)
         order by r.batch_no), '[]'::jsonb)
    from all_rows r;
$function$;

-- The ONE string the order card prints. Absence is explicit and worded by the
-- backend — the app never composes "Batch —" out of an empty value.
create or replace function public.order_item_batch_block(p_order_item_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with b as (select public._order_item_batches(p_order_item_id) as arr)
  select jsonb_build_object(
    'has',     jsonb_array_length((select arr from b)) > 0,
    'batches', (select arr from b),
    'label',   case when jsonb_array_length((select arr from b)) > 0
                    then (select string_agg(e->>'label', '   ')
                            from jsonb_array_elements((select arr from b)) e)
                    else '' end,
    'hint',    case when jsonb_array_length((select arr from b)) = 0
                    then public.uic('order_line.batch_pending',
                                    'Batch and expiry are printed once the pack is received.')
                    else '' end);
$function$;

insert into public.ui_copy (key, value) values
  ('order_line.batch_word',    to_jsonb('Batch'::text)),
  ('order_line.expiry_word',   to_jsonb('Exp'::text)),
  ('order_line.batch_pending', to_jsonb('Batch and expiry are printed once the pack is received.'::text))
on conflict (key) do nothing;

-- ── 128: a real invoice number series ────────────────────────────────────────
alter table public.orders add column if not exists invoice_no text;
alter table public.orders add column if not exists invoice_issued_at timestamptz;
create unique index if not exists orders_invoice_no_uidx on public.orders (invoice_no)
  where invoice_no is not null;

create table if not exists public.customer_invoice_series (
  fy         text primary key,          -- '2026-27'
  prefix     text not null,
  next_no    int  not null default 1,
  updated_at timestamptz not null default now()
);

-- Indian financial year for an IST instant: 1 April to 31 March.
create or replace function public._fy_ist(p_at timestamptz default now())
returns text
language sql
immutable
set search_path to 'public'
as $function$
  select case when extract(month from (p_at at time zone 'Asia/Kolkata')) >= 4
              then to_char(p_at at time zone 'Asia/Kolkata','YYYY') || '-' ||
                   to_char((p_at at time zone 'Asia/Kolkata') + interval '1 year','YY')
              else to_char((p_at at time zone 'Asia/Kolkata') - interval '1 year','YYYY') || '-' ||
                   to_char(p_at at time zone 'Asia/Kolkata','YY') end;
$function$;

create or replace function public._next_customer_invoice_no()
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_fy text := public._fy_ist(); v_prefix text; v_no int;
begin
  select coalesce(invoice_prefix,'MB') into v_prefix from public.billing_config where id = 1;
  insert into public.customer_invoice_series (fy, prefix, next_no)
  values (v_fy, coalesce(v_prefix,'MB'), 1)
  on conflict (fy) do nothing;

  update public.customer_invoice_series
     set next_no = next_no + 1, updated_at = now()
   where fy = v_fy
  returning next_no - 1 into v_no;

  return coalesce(v_prefix,'MB') || '/' || v_fy || '/' || to_char(v_no, 'FM0000');
end $function$;

-- A tax invoice exists only once the goods have moved. Before that the document
-- is a proforma and carries no number — issuing a number early would burn a
-- slot in a statutory series for a supply that may never happen.
create or replace function public._order_is_supplied(p_order_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select o.status in ('shipped','delivered','completed') from orders o where o.id = p_order_id),
    false)
  or exists (select 1 from order_items oi
              where oi.order_id = p_order_id
                and oi.fulfillment_state in ('shipped','received','delivered'));
$function$;

-- Assign the number ONCE. Idempotent: an order that already carries one keeps
-- it forever, whatever else changes on the order.
create or replace function public.customer_invoice_issue(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_no text; v_supplied boolean;
begin
  select invoice_no into v_no from orders where id = p_order_id;
  if v_no is not null then
    return jsonb_build_object('ok', true, 'already', true, 'invoice_no', v_no);
  end if;

  v_supplied := public._order_is_supplied(p_order_id);
  if not v_supplied then
    return jsonb_build_object('ok', false, 'reason','not_supplied',
      'message', public.uic('bill.proforma_reason',
                            'A tax invoice is raised when the order is dispatched.'));
  end if;

  v_no := public._next_customer_invoice_no();
  update orders set invoice_no = v_no, invoice_issued_at = now()
   where id = p_order_id and invoice_no is null;

  select invoice_no into v_no from orders where id = p_order_id;
  return jsonb_build_object('ok', true, 'already', false, 'invoice_no', v_no);
end $function$;

insert into public.ui_copy (key, value) values
  ('bill.proforma_reason',  to_jsonb('A tax invoice is raised when the order is dispatched.'::text)),
  ('bill.proforma_title',   to_jsonb('PROFORMA INVOICE'::text)),
  ('bill.proforma_banner',  to_jsonb('Proforma — not a tax invoice. Rates and GST are final; batch, expiry and the invoice number are added on dispatch.'::text)),
  ('bill.line_source_order',to_jsonb('Priced from your order'::text))
on conflict (key) do nothing;

