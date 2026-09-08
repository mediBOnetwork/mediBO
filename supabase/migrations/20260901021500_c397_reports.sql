-- CHANGE #397 — part 4: the reports themselves.
--
-- Pure data again. Every report is one SELECT whose only parameter is $1, the
-- filters jsonb the screen collected. Adding "supplier statement, but by state"
-- is an INSERT here.
--
-- Money rule (business context): every ₹ figure comes from trade rate ± discount
-- + GST. MRP appears only where it is genuinely a printed reference (the
-- purchase register's batch line), never as a revenue or price column.

insert into public.export_report(key, label, hint, feature_key, source_sql, columns, filters, sort_order)
values

('orders', 'Orders', 'Every order with its status, zone and value.',
 'admin.fulfillment',
$sql$
select to_char(o.created_at at time zone 'Asia/Kolkata','DD-MM-YYYY HH24:MI') as placed_at,
       coalesce(o.order_code, right(o.id::text,8))                            as order_code,
       coalesce(o.pharmacy_name,'')                                           as customer,
       coalesce(o.phone,'')                                                   as phone,
       coalesce(o.status,'')                                                  as status,
       coalesce(o.fulfillment_status,'')                                      as fulfillment,
       coalesce(o.zone_id::text,'')                                           as zone,
       round(coalesce(o.total_amount,0)::numeric, 2)::text                    as total_inr,
       coalesce(o.bag_no::text,'')                                            as bag_no,
       coalesce(o.source,'')                                                  as source
  from public.orders o
 where (coalesce($1->>'from','') = '' or o.created_at >= ($1->>'from')::date)
   and (coalesce($1->>'to','')   = '' or o.created_at <  (($1->>'to')::date + 1))
   and (coalesce($1->>'status','') = '' or lower(o.status) = lower($1->>'status'))
   and (coalesce($1->>'zone','')   = '' or o.zone_id::text = $1->>'zone')
 order by o.created_at desc
$sql$,
 '[{"key":"placed_at","label":"Placed (IST)"},{"key":"order_code","label":"Order"},
   {"key":"customer","label":"Customer"},{"key":"phone","label":"Phone"},
   {"key":"status","label":"Status"},{"key":"fulfillment","label":"Fulfilment"},
   {"key":"zone","label":"Zone"},{"key":"total_inr","label":"Total (INR)"},
   {"key":"bag_no","label":"Bag"},{"key":"source","label":"Source"}]'::jsonb,
 '[{"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"},
   {"key":"status","label":"Status","kind":"enum",
    "options":[{"value":"pending","label":"Pending"},{"value":"accepted","label":"Accepted"},
               {"value":"cancelled","label":"Cancelled"}]}]'::jsonb,
 10),

('bills', 'Supplier bills', 'Bills received from suppliers, with their import status.',
 'admin.bill_pipeline',
$sql$
select to_char(coalesce(b.received_at, b.created_at) at time zone 'Asia/Kolkata','DD-MM-YYYY HH24:MI') as received_at,
       coalesce(b.supplier_name,'')                       as supplier,
       coalesce(b.file_name,'')                           as file_name,
       coalesce(b.status,'')                              as status,
       coalesce(b.verdict,'')                             as verdict,
       coalesce(to_char(b.imported_at at time zone 'Asia/Kolkata','DD-MM-YYYY HH24:MI'),'') as imported_at,
       coalesce(b.source,'')                              as source,
       round(coalesce((select sum(l.line_amount) from public.bill_lines l
                        where l.pending_bill_id = b.id),0)::numeric,2)::text as value_inr
  from public.pending_bills b
 where (coalesce($1->>'from','') = '' or coalesce(b.received_at,b.created_at) >= ($1->>'from')::date)
   and (coalesce($1->>'to','')   = '' or coalesce(b.received_at,b.created_at) <  (($1->>'to')::date + 1))
   and (coalesce($1->>'status','') = '' or lower(b.status) = lower($1->>'status'))
 order by coalesce(b.received_at, b.created_at) desc
$sql$,
 '[{"key":"received_at","label":"Received (IST)"},{"key":"supplier","label":"Supplier"},
   {"key":"file_name","label":"File"},{"key":"status","label":"Status"},
   {"key":"verdict","label":"Verdict"},{"key":"imported_at","label":"Imported (IST)"},
   {"key":"source","label":"Source"},{"key":"value_inr","label":"Value (INR)"}]'::jsonb,
 '[{"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"},
   {"key":"status","label":"Status","kind":"text"}]'::jsonb,
 20),

('payments', 'Payments received', 'Customer payment claims with their UTR and verification state.',
 'admin.payment_upi',
$sql$
select to_char(coalesce(c.paid_ts, c.received_at, c.created_at) at time zone 'Asia/Kolkata','DD-MM-YYYY HH24:MI') as paid_at,
       coalesce(c.payee_name,'')                          as paid_to,
       coalesce(c.sender_phone,'')                        as sender,
       coalesce(c.sender_type,'')                         as sender_type,
       round(coalesce(c.amount,0)::numeric,2)::text       as amount_inr,
       coalesce(c.utr,'')                                 as utr,
       coalesce(c.app,'')                                 as app,
       coalesce(c.payment_method,'')                      as method,
       coalesce(c.status,'')                              as status,
       coalesce(c.verify_reason,'')                       as note,
       coalesce(c.order_id::text,'')                      as order_id
  from public.payment_claims c
 where (coalesce($1->>'from','') = '' or coalesce(c.paid_ts,c.received_at,c.created_at) >= ($1->>'from')::date)
   and (coalesce($1->>'to','')   = '' or coalesce(c.paid_ts,c.received_at,c.created_at) <  (($1->>'to')::date + 1))
   and (coalesce($1->>'status','') = '' or lower(c.status) = lower($1->>'status'))
 order by coalesce(c.paid_ts, c.received_at, c.created_at) desc
$sql$,
 '[{"key":"paid_at","label":"Paid (IST)"},{"key":"paid_to","label":"Paid to"},
   {"key":"sender","label":"Sender"},{"key":"sender_type","label":"Sender type"},
   {"key":"amount_inr","label":"Amount (INR)"},{"key":"utr","label":"UTR"},
   {"key":"app","label":"App"},{"key":"method","label":"Method"},
   {"key":"status","label":"Status"},{"key":"note","label":"Note"},
   {"key":"order_id","label":"Order"}]'::jsonb,
 '[{"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"},
   {"key":"status","label":"Status","kind":"text"}]'::jsonb,
 30),

('gst_register', 'GST register', 'The GST ledger, ready for the return: taxable value, CGST/SGST/IGST per invoice line.',
 'admin.gst',
$sql$
select coalesce(to_char(g.tax_period,'YYYY-MM'),'')       as tax_period,
       coalesce(g.direction,'')                           as direction,
       coalesce(g.invoice_no,'')                          as invoice_no,
       coalesce(g.invoice_date_text,
                to_char(g.invoice_date,'DD-MM-YYYY'),'')  as invoice_date,
       coalesce(g.counterparty_name,'')                   as counterparty,
       coalesce(g.counterparty_gstin,'')                  as gstin,
       coalesce(g.hsn,'')                                 as hsn,
       coalesce(g.product_name,'')                        as product,
       coalesce(g.qty::text,'')                           as qty,
       round(coalesce(g.taxable,0)::numeric,2)::text      as taxable_inr,
       coalesce(g.rate::text,'')                          as rate_pct,
       round(coalesce(g.cgst,0)::numeric,2)::text         as cgst_inr,
       round(coalesce(g.sgst,0)::numeric,2)::text         as sgst_inr,
       round(coalesce(g.igst,0)::numeric,2)::text         as igst_inr,
       round(coalesce(g.total_tax,0)::numeric,2)::text    as total_tax_inr,
       coalesce(g.place_of_supply,'')                     as place_of_supply,
       coalesce(g.order_code,'')                          as order_code
  from public.gst_ledger g
 where (coalesce($1->>'period','')    = '' or to_char(g.tax_period,'YYYY-MM') = $1->>'period')
   and (coalesce($1->>'direction','') = '' or g.direction  = $1->>'direction')
   and (coalesce($1->>'from','') = '' or g.invoice_date >= ($1->>'from')::date)
   and (coalesce($1->>'to','')   = '' or g.invoice_date <= ($1->>'to')::date)
 order by g.tax_period, g.direction, g.invoice_date, g.invoice_no
$sql$,
 '[{"key":"tax_period","label":"Tax period"},{"key":"direction","label":"Direction"},
   {"key":"invoice_no","label":"Invoice no"},{"key":"invoice_date","label":"Invoice date"},
   {"key":"counterparty","label":"Counterparty"},{"key":"gstin","label":"GSTIN"},
   {"key":"hsn","label":"HSN"},{"key":"product","label":"Product"},
   {"key":"qty","label":"Qty"},{"key":"taxable_inr","label":"Taxable (INR)"},
   {"key":"rate_pct","label":"Rate %"},{"key":"cgst_inr","label":"CGST (INR)"},
   {"key":"sgst_inr","label":"SGST (INR)"},{"key":"igst_inr","label":"IGST (INR)"},
   {"key":"total_tax_inr","label":"Total tax (INR)"},
   {"key":"place_of_supply","label":"Place of supply"},{"key":"order_code","label":"Order"}]'::jsonb,
 '[{"key":"period","label":"Tax period (YYYY-MM)","kind":"text"},
   {"key":"direction","label":"Direction","kind":"enum",
    "options":[{"value":"outward","label":"Outward (sales)"},{"value":"inward","label":"Inward (purchases)"}]},
   {"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"}]'::jsonb,
 40),

('pnl', 'Profit & loss (daily)', 'Sales value against purchase cost, per day. Trade rates only — MRP is never revenue.',
 'admin.pnl',
$sql$
with days as (
  select d::date as day
    from generate_series(
      coalesce(nullif($1->>'from','')::date, (now() at time zone 'Asia/Kolkata')::date - 30),
      coalesce(nullif($1->>'to','')::date,   (now() at time zone 'Asia/Kolkata')::date),
      interval '1 day') d
), sales as (
  select (o.created_at at time zone 'Asia/Kolkata')::date as day,
         count(*) as orders, sum(coalesce(o.total_amount,0)) as sales
    from public.orders o
   where lower(coalesce(o.status,'')) <> 'cancelled'
   group by 1
), purchase as (
  select (s.created_at at time zone 'Asia/Kolkata')::date as day,
         count(*) as pos, sum(coalesce(s.trade_total, s.total_amount, 0)) as cost
    from public.supplier_orders s
   group by 1
)
select to_char(d.day,'DD-MM-YYYY')                                    as day,
       coalesce(sa.orders,0)::text                                    as orders,
       round(coalesce(sa.sales,0)::numeric,2)::text                   as sales_inr,
       coalesce(pu.pos,0)::text                                       as purchase_orders,
       round(coalesce(pu.cost,0)::numeric,2)::text                    as purchase_inr,
       round((coalesce(sa.sales,0) - coalesce(pu.cost,0))::numeric,2)::text as gross_margin_inr
  from days d
  left join sales    sa on sa.day = d.day
  left join purchase pu on pu.day = d.day
 order by d.day desc
$sql$,
 '[{"key":"day","label":"Day"},{"key":"orders","label":"Orders"},
   {"key":"sales_inr","label":"Sales (INR)"},{"key":"purchase_orders","label":"Purchase orders"},
   {"key":"purchase_inr","label":"Purchase (INR)"},
   {"key":"gross_margin_inr","label":"Gross margin (INR)"}]'::jsonb,
 '[{"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"}]'::jsonb,
 50),

('purchase_register', 'Purchase register', 'Every purchased batch line: qty, batch, expiry, trade rate, GST.',
 'admin.bill_pipeline',
$sql$
select to_char(coalesce(b.received_at, l.created_at) at time zone 'Asia/Kolkata','DD-MM-YYYY') as bill_date,
       coalesce(l.supplier_name, b.supplier_name,'')      as supplier,
       coalesce(b.file_name,'')                           as bill_file,
       coalesce(nullif(l.raw_name,''), l.raw_company,'')  as product,
       coalesce(l.batch_no,'')                            as batch_no,
       coalesce(l.expiry,'')                              as expiry,
       coalesce(l.hsn,'')                                 as hsn,
       coalesce(l.qty::text,'')                           as qty,
       coalesce(l.free_qty::text,'')                      as free_qty,
       round(coalesce(l.mrp,0)::numeric,2)::text          as mrp_printed,
       round(coalesce(l.ptr,0)::numeric,2)::text          as ptr_inr,
       coalesce(l.disc_pct::text,'')                      as discount_pct,
       coalesce(l.gst_pct::text,'')                       as gst_pct,
       round(coalesce(l.line_amount,0)::numeric,2)::text  as line_amount_inr,
       case when l.verified then 'Yes' else 'No' end      as verified
  from public.bill_lines l
  left join public.pending_bills b on b.id = l.pending_bill_id
 where (coalesce($1->>'from','') = '' or coalesce(b.received_at, l.created_at) >= ($1->>'from')::date)
   and (coalesce($1->>'to','')   = '' or coalesce(b.received_at, l.created_at) <  (($1->>'to')::date + 1))
   and (coalesce($1->>'supplier','') = ''
        or coalesce(l.supplier_name, b.supplier_name,'') ilike '%' || ($1->>'supplier') || '%')
 order by coalesce(b.received_at, l.created_at) desc, l.id
$sql$,
 '[{"key":"bill_date","label":"Bill date"},{"key":"supplier","label":"Supplier"},
   {"key":"bill_file","label":"Bill"},{"key":"product","label":"Product (as printed)"},
   {"key":"batch_no","label":"Batch"},{"key":"expiry","label":"Expiry"},
   {"key":"hsn","label":"HSN"},{"key":"qty","label":"Qty"},
   {"key":"free_qty","label":"Free qty"},{"key":"mrp_printed","label":"MRP printed"},
   {"key":"ptr_inr","label":"PTR (INR)"},{"key":"discount_pct","label":"Discount %"},
   {"key":"gst_pct","label":"GST %"},{"key":"line_amount_inr","label":"Line amount (INR)"},
   {"key":"verified","label":"Verified"}]'::jsonb,
 '[{"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"},
   {"key":"supplier","label":"Supplier","kind":"text"}]'::jsonb,
 60),

('supplier_statement', 'Supplier statement', 'Purchase orders raised against a supplier and the payments made to them.',
 'admin.suppliers',
$sql$
select entry_date, supplier, entry_type, reference, debit_inr, credit_inr, note from (
  select (s.created_at at time zone 'Asia/Kolkata')::date          as sort_day,
         to_char(s.created_at at time zone 'Asia/Kolkata','DD-MM-YYYY') as entry_date,
         coalesce(s.supplier_name,'')                              as supplier,
         'Purchase order'                                          as entry_type,
         coalesce(s.order_code, s.order_no::text, right(s.id::text,8)) as reference,
         round(coalesce(s.trade_total, s.total_amount, 0)::numeric,2)::text as debit_inr,
         ''                                                        as credit_inr,
         coalesce(s.status,'')                                     as note
    from public.supplier_orders s
   where (coalesce($1->>'supplier','') = '' or s.supplier_name ilike '%' || ($1->>'supplier') || '%')
     and (coalesce($1->>'from','') = '' or s.created_at >= ($1->>'from')::date)
     and (coalesce($1->>'to','')   = '' or s.created_at <  (($1->>'to')::date + 1))
  union all
  select (p.created_at at time zone 'Asia/Kolkata')::date,
         to_char(p.created_at at time zone 'Asia/Kolkata','DD-MM-YYYY'),
         coalesce(p.supplier_name,''),
         'Payment',
         coalesce(nullif(p.utr,''), nullif(p.txn_id,''), right(p.id::text,8)),
         '',
         round(coalesce(p.amount,0)::numeric,2)::text,
         coalesce(nullif(p.mode,''), coalesce(p.kind,''))
    from public.supplier_payments p
   where (coalesce($1->>'supplier','') = '' or p.supplier_name ilike '%' || ($1->>'supplier') || '%')
     and (coalesce($1->>'from','') = '' or p.created_at >= ($1->>'from')::date)
     and (coalesce($1->>'to','')   = '' or p.created_at <  (($1->>'to')::date + 1))
) t order by supplier, sort_day desc
$sql$,
 '[{"key":"entry_date","label":"Date"},{"key":"supplier","label":"Supplier"},
   {"key":"entry_type","label":"Entry"},{"key":"reference","label":"Reference"},
   {"key":"debit_inr","label":"Purchased (INR)"},{"key":"credit_inr","label":"Paid (INR)"},
   {"key":"note","label":"Note"}]'::jsonb,
 '[{"key":"supplier","label":"Supplier","kind":"text"},
   {"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"}]'::jsonb,
 70),

('audit_trail', 'Audit trail', 'Who changed what, including every bulk change and every undo.',
 'admin.audit_log',
$sql$
select to_char(l.at at time zone 'Asia/Kolkata','DD-MM-YYYY HH24:MI') as at_ist,
       coalesce(l.actor_email,'system')  as actor,
       coalesce(l.actor_role,'')         as role,
       l.action                          as action,
       l.entity_type                     as entity_type,
       coalesce(l.entity_id,'')          as entity_id,
       coalesce(array_to_string(l.changed_keys, ' '),'') as changed_fields,
       coalesce(l.batch_id::text,'')     as batch_id,
       coalesce(l.undo_of::text,'')      as undo_of
  from public.audit_log l
 where (coalesce($1->>'from','') = '' or l.at >= ($1->>'from')::date)
   and (coalesce($1->>'to','')   = '' or l.at <  (($1->>'to')::date + 1))
   and (coalesce($1->>'actor','') = '' or l.actor_email ilike '%' || ($1->>'actor') || '%')
   and (coalesce($1->>'entity_type','') = '' or l.entity_type = $1->>'entity_type')
 order by l.id desc
$sql$,
 '[{"key":"at_ist","label":"When (IST)"},{"key":"actor","label":"Actor"},
   {"key":"role","label":"Role"},{"key":"action","label":"Action"},
   {"key":"entity_type","label":"Entity"},{"key":"entity_id","label":"Entity id"},
   {"key":"changed_fields","label":"Changed fields"},
   {"key":"batch_id","label":"Batch"},{"key":"undo_of","label":"Undo of"}]'::jsonb,
 '[{"key":"from","label":"From","kind":"date"},{"key":"to","label":"To","kind":"date"},
   {"key":"actor","label":"Actor","kind":"text"},
   {"key":"entity_type","label":"Entity","kind":"text"}]'::jsonb,
 80)

on conflict (key) do update set
  label = excluded.label, hint = excluded.hint, feature_key = excluded.feature_key,
  source_sql = excluded.source_sql, columns = excluded.columns,
  filters = excluded.filters, sort_order = excluded.sort_order, is_active = true;
