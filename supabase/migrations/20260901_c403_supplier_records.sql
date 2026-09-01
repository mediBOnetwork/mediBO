-- CHANGE #403 — THE SUPPLIER RECORDS LAYER.
--
-- Four things a supplier could not do from his own login before this change:
--   1. download a document — the purchase order mediBO sent him, a copy of a
--      bill he uploaded, or a monthly statement of what he is owed;
--   2. see a debit — a return or a short/damage claim that came off his bill,
--      which until now was a phone argument with nothing on either side;
--   3. read what he sold mediBO this month, against last month;
--   4. find an old bill by its invoice number, a date range or an amount.
--
-- Every one of them is READ-ONLY over data that already exists, scoped to
-- my_supplier_id(), and none of them messages anybody. The documents reuse the
-- EXISTING render pipeline: the backend hands a finished payload to the
-- bill-render edge function, which draws it, stores it and reports back —
-- exactly the bill_jobs shape, one table down.
--
-- Every statement is idempotent: a resumed worker re-applies this silently.

-- ═══════════════════════════════════════════════════════════════════════════
-- 0. THE LANGUAGE-AWARE FORMATTER
--    ui_text() resolves a key in the reader's language; _cf() interpolates but
--    reads English only. Supplier-facing copy needs both, so this is _cf() on
--    top of ui_text() rather than a second copy of either.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.ui_textf(p_key text, p_vars jsonb default '{}'::jsonb)
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare v text := public.ui_text(p_key); k text;
begin
  if v is null or v = '' then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v := replace(v, '{' || k || '}', coalesce(p_vars->>k, ''));
  end loop;
  return v;
end $fn$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE SURFACE
--    One feature key, four tabs. The tab list is DATA (supplier_record_tab), so
--    a fifth record type later is an INSERT and no deploy.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.supplier_feature(feature_key, copy_key, icon_key, sort_order, is_active)
values ('supplier.records', 'supplier_records.feature_label', 'folder', 70, true)
on conflict (feature_key) do update
  set copy_key = excluded.copy_key, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, is_active = true;

-- Staff who already handle billing and orders can READ the records. Nobody can
-- write them — there is nothing on this surface to write.
update public.supplier_role_preset
   set grants = grants || jsonb_build_object('supplier.records', 'read')
 where role_key in ('billing_only', 'full');

create table if not exists public.supplier_record_tab (
  tab_key    text primary key,
  copy_key   text not null,
  icon_key   text,
  sort_order int not null default 100,
  is_active  boolean not null default true
);

insert into public.supplier_record_tab(tab_key, copy_key, icon_key, sort_order, is_active) values
  ('documents', 'supplier_records.tab_documents', 'description',  10, true),
  ('debits',    'supplier_records.tab_debits',    'remove_circle', 20, true),
  ('sales',     'supplier_records.tab_sales',     'insights',     30, true),
  ('bills',     'supplier_records.tab_bills',     'search',       40, true)
on conflict (tab_key) do update
  set copy_key = excluded.copy_key, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, is_active = true;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. THE DOCUMENT REGISTRY
--    One row per (supplier, kind, ref). `source_stamp` is what the document was
--    rendered FROM — when the underlying order or bill changes, the stamp
--    changes and the next request re-renders instead of serving a stale PDF.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.supplier_document (
  id           uuid primary key default gen_random_uuid(),
  supplier_id  uuid not null,
  kind         text not null,
  ref_key      text not null,
  title        text,
  file_name    text,
  bucket       text,
  path         text,
  status       text not null default 'queued',
  attempts     int  not null default 0,
  last_error   text,
  source_stamp text,
  requested_by uuid,
  requested_at timestamptz not null default now(),
  started_at   timestamptz,
  ready_at     timestamptz,
  bytes        int
);

create unique index if not exists supplier_document_ref_uq
  on public.supplier_document(supplier_id, kind, ref_key);
create index if not exists supplier_document_status_idx
  on public.supplier_document(status, requested_at);

alter table public.supplier_document enable row level security;

-- The rows are read through SECURITY DEFINER RPCs only; no direct table read.
drop policy if exists supplier_document_admin_all on public.supplier_document;
create policy supplier_document_admin_all on public.supplier_document
  for all to authenticated
  using (public.get_my_role() = any (array['admin','super_admin']))
  with check (public.get_my_role() = any (array['admin','super_admin']));

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE BUCKET
--    Private, and scoped by the first path segment — a supplier can sign a URL
--    for his own folder and for nothing else. Same shape as the existing
--    wa_media_supplier_bill policy.
-- ═══════════════════════════════════════════════════════════════════════════
insert into storage.buckets(id, name, public)
values ('supplier-docs', 'supplier-docs', false)
on conflict (id) do nothing;

drop policy if exists supplier_docs_own_read on storage.objects;
create policy supplier_docs_own_read on storage.objects
  for select to authenticated
  using (bucket_id = 'supplier-docs'
         and public.my_supplier_id() is not null
         and (storage.foldername(name))[1] = public.my_supplier_id()::text);

drop policy if exists supplier_docs_admin_all on storage.objects;
create policy supplier_docs_admin_all on storage.objects
  for all to authenticated
  using (bucket_id = 'supplier-docs'
         and public.get_my_role() = any (array['admin','super_admin']))
  with check (bucket_id = 'supplier-docs'
              and public.get_my_role() = any (array['admin','super_admin']));

-- A supplier may read the bill file he uploaded himself. supplier-bills is
-- already readable by any authenticated login; this narrows nothing and opens
-- nothing — it is the whatsapp-media twin, so a bill that arrived over WhatsApp
-- and one that arrived through the app behave identically on his screen.
drop policy if exists supplier_bills_own_read on storage.objects;
create policy supplier_bills_own_read on storage.objects
  for select to authenticated
  using (bucket_id = 'supplier-bills'
         and exists (select 1 from public.pending_bills pb
                      where pb.file_path = storage.objects.name
                        and pb.supplier_id = (public.my_supplier_id())::text));
-- ═══════════════════════════════════════════════════════════════════════════
-- 4. WHO IS ASKING
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._c403_me()
returns uuid language sql stable security definer set search_path to 'public' as $fn$
  select case when public.supplier_can('supplier.records','read')
              then public.my_supplier_id() end
$fn$;

create or replace function public._c403_supplier_name(p_supplier uuid)
returns text language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(sp.supplier_name,'') from public.supplier_profiles sp where sp.id = p_supplier
$fn$;

create or replace function public._c403_denied()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object('ok', false, 'error', 'not_authorized',
                            'message', public.ui_text('supplier_records.err_not_authorized'))
$fn$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. THE DEBIT ROWS — ONE SET, TWO SOURCES
--    A debit against a supplier can be raised two ways today: the customer
--    return (#395) on an item HE supplied, and the short/damage adjustment the
--    dispute matrix already stamps onto his own supplier order. Both are the
--    same fact to him — money coming off what mediBO owes — so they are one
--    set here and one list on his screen, each row naming which side it came
--    from. Nothing is computed twice: the amounts are the ones the returns
--    engine and the dispute resolution already froze.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._c403_debit_rows(p_supplier uuid)
returns table (
  src text, id uuid, at timestamptz, ref_label text, ref_kind text,
  product_name text, qty numeric, amount numeric, reason_label text,
  note text, photo_bucket text, photo_path text, photo_url text,
  status text
)
language sql stable security definer set search_path to 'public' as $fn$
  with me as (select public._c403_supplier_name(p_supplier) nm)
  select 'return'::text,
         r.id,
         coalesce(r.credited_at, r.approved_at, r.raised_at),
         coalesce(o.order_code, ''),
         'order'::text,
         coalesce(r.product_name, ''),
         coalesce(r.qty, 0),
         coalesce(r.credit_total, 0),
         coalesce(nullif(ro.label, ''), coalesce(r.reason_code, '')),
         coalesce(r.note, ''),
         case when coalesce(r.photo_path,'') <> '' then 'dispute-proofs' else '' end,
         coalesce(r.photo_path, ''),
         ''::text,
         coalesce(r.status, '')
    from public.order_returns r
    join public.order_items oi on oi.id = r.order_item_id
    left join public.orders o on o.id = r.order_id
    left join public.order_reason_option ro
           on ro.scope = 'return' and ro.code = r.reason_code
   cross join me
   where me.nm <> ''
     and oi.assigned_supplier = me.nm
     and r.status in ('approved', 'credited')
     and coalesce(r.credit_total, 0) > 0

  union all

  select 'dispute'::text,
         d.id,
         coalesce(d.resolved_at, d.responded_at, d.created_at),
         coalesce(so.order_code, coalesce(d.dispute_code, '')),
         'supplier_order'::text,
         coalesce(d.product_name, ''),
         coalesce(d.adj_qty, d.short_qty, 0),
         coalesce(d.adj_amount, 0),
         coalesce(nullif(public.ui_text('supplier_debits.reason_' || coalesce(d.kind,'short')), ''),
                  coalesce(d.kind, '')),
         coalesce(d.resolution_note, ''),
         ''::text,
         ''::text,
         coalesce(d.proof_url, ''),
         coalesce(d.status, '')
    from public.supplier_disputes d
    left join public.supplier_orders so on so.id = d.adj_supplier_order_id
   cross join me
   where me.nm <> ''
     and d.assigned_supplier = me.nm
     and coalesce(d.adj_amount, 0) > 0
$fn$;
-- ═══════════════════════════════════════════════════════════════════════════
-- 6. THE DOCUMENT PAYLOAD
--    One generic shape for all three kinds: a header block, one or more
--    column/row sections, a totals ladder and notes. The renderer draws it and
--    names nothing itself — every label below comes out of ui_copy.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._c403_doc_payload(p_supplier uuid, p_kind text, p_ref text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_name text := public._c403_supplier_name(p_supplier);
  v_stamp text; v_title text; v_file text;
  v_header jsonb; v_sections jsonb; v_totals jsonb; v_notes jsonb;
  so public.supplier_orders%rowtype;
  pb public.pending_bills%rowtype;
  v_from timestamptz; v_to timestamptz; v_month date;
  v_rows jsonb; v_n int; v_sum numeric;
  v_billed numeric := 0; v_paid numeric := 0; v_debit numeric := 0; v_ordered numeric := 0;
begin
  if p_kind = 'purchase_order' then
    select * into so from public.supplier_orders
      where id = p_ref::uuid and supplier_id = p_supplier;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

    v_stamp := md5(coalesce(so.items::text,'') || coalesce(so.status,'') ||
                   coalesce(so.total_amount,0)::text || coalesce(so.trade_total,0)::text);
    v_title := public.ui_textf('supplier_doc.po_title',
                 jsonb_build_object('code', coalesce(so.order_code,'')));
    v_file  := 'PO-' || coalesce(nullif(so.order_code,''), left(so.id::text,8)) || '.pdf';

    v_header := jsonb_build_array(
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_supplier'), 'value', v_name),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_order_code'), 'value', coalesce(so.order_code,'')),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_order_date'),
                         'value', coalesce(to_char(so.order_date,'DD/MM/YYYY'),
                                           public.ist_fmt(so.created_at,'dmy'))),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_status'), 'value', coalesce(so.status,'')));

    select coalesce(jsonb_agg(jsonb_build_object(
             'sn', row_number() over ()::text,
             'product', coalesce(it->>'product_name',''),
             'pack', coalesce(it->>'pack_type',''),
             'qty', coalesce(it->>'quantity',''),
             'mrp', coalesce(it->>'mrp_display',''),
             'rate', coalesce(it->>'rate_display',''),
             'amount', coalesce(it->>'line_total_display',''))), '[]'::jsonb),
           count(*), coalesce(sum((it->>'line_total')::numeric),0)
      into v_rows, v_n, v_sum
      from jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it;

    v_sections := jsonb_build_array(jsonb_build_object(
      'heading', public.ui_text('supplier_doc.po_lines_heading'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','sn','label','#','align','left','width',20),
        jsonb_build_object('key','product','label',public.ui_text('supplier_doc.col_product'),'align','left','width',210),
        jsonb_build_object('key','pack','label',public.ui_text('supplier_doc.col_pack'),'align','left','width',60),
        jsonb_build_object('key','qty','label',public.ui_text('supplier_doc.col_qty'),'align','right','width',44),
        jsonb_build_object('key','mrp','label',public.ui_text('supplier_po.mrp_column'),'align','right','width',66),
        jsonb_build_object('key','rate','label',public.ui_text('supplier_po.rate_column'),'align','right','width',66),
        jsonb_build_object('key','amount','label',public.ui_text('supplier_doc.col_amount'),'align','right','width',76)),
      'rows', v_rows,
      'empty_label', public.ui_text('supplier_po.basis_empty')));

    v_totals := jsonb_build_array(
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_items'), 'value', v_n::text),
      jsonb_build_object('label', public.ui_text('supplier_po.payable_label'),
                         'value', public.inr_money(coalesce(so.total_amount, v_sum)), 'bold', true));
    v_notes := jsonb_build_array(public.ui_text('supplier_po.mrp_note'));

  elsif p_kind = 'bill_copy' then
    select * into pb from public.pending_bills
      where id = p_ref::uuid and supplier_id = p_supplier::text;
    if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

    v_stamp := md5(coalesce(pb.status,'') || coalesce(pb.verdict,'') ||
                   coalesce(pb.scan_result::text,'') || coalesce(pb.imported_at,pb.created_at)::text);
    v_title := public.ui_textf('supplier_doc.bill_title',
                 jsonb_build_object('no', coalesce(nullif(pb.scan_result->>'invoice_no',''),
                                                   coalesce(pb.file_name,''))));
    v_file  := 'BILL-' || regexp_replace(
                 coalesce(nullif(pb.scan_result->>'invoice_no',''), left(pb.id::text,8)),
                 '[^0-9A-Za-z-]','','g') || '.pdf';

    v_header := jsonb_build_array(
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_supplier'), 'value', v_name),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_invoice_no'),
                         'value', coalesce(pb.scan_result->>'invoice_no','')),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_received'),
                         'value', public.ist_fmt(coalesce(pb.received_at, pb.created_at),'dmy')),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_status'), 'value', coalesce(pb.status,'')),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_file'), 'value', coalesce(pb.file_name,'')));

    select coalesce(jsonb_agg(jsonb_build_object(
             'sn', row_number() over (order by bl.created_at)::text,
             'product', coalesce(nullif(bl.raw_name,''),''),
             'batch', coalesce(bl.batch_no,''),
             'expiry', coalesce(bl.expiry,''),
             'qty', coalesce(trim_scale(bl.qty)::text,''),
             'free', coalesce(trim_scale(bl.free_qty)::text,''),
             'mrp', public.inr_money(bl.mrp),
             'ptr', public.inr_money(bl.ptr),
             'gst', coalesce(trim_scale(bl.gst_pct)::text,'') || '%',
             'amount', public.inr_money(bl.line_amount)) order by bl.created_at), '[]'::jsonb),
           count(*), coalesce(sum(bl.line_amount),0)
      into v_rows, v_n, v_sum
      from public.bill_lines bl where bl.pending_bill_id = pb.id;

    v_sections := jsonb_build_array(jsonb_build_object(
      'heading', public.ui_text('supplier_doc.bill_lines_heading'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','sn','label','#','align','left','width',20),
        jsonb_build_object('key','product','label',public.ui_text('supplier_doc.col_product'),'align','left','width',170),
        jsonb_build_object('key','batch','label',public.ui_text('supplier_doc.col_batch'),'align','left','width',60),
        jsonb_build_object('key','expiry','label',public.ui_text('supplier_doc.col_expiry'),'align','left','width',48),
        jsonb_build_object('key','qty','label',public.ui_text('supplier_doc.col_qty'),'align','right','width',36),
        jsonb_build_object('key','free','label',public.ui_text('supplier_doc.col_free'),'align','right','width',36),
        jsonb_build_object('key','mrp','label',public.ui_text('supplier_po.mrp_column'),'align','right','width',60),
        jsonb_build_object('key','ptr','label',public.ui_text('supplier_doc.col_ptr'),'align','right','width',60),
        jsonb_build_object('key','gst','label',public.ui_text('supplier_doc.col_gst'),'align','right','width',40),
        jsonb_build_object('key','amount','label',public.ui_text('supplier_doc.col_amount'),'align','right','width',70)),
      'rows', v_rows,
      'empty_label', public.ui_text('supplier_doc.bill_lines_empty')));

    v_totals := jsonb_build_array(
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_lines'), 'value', v_n::text),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_bill_total'),
        'value', public.inr_money(coalesce(nullif(pb.scan_result->>'total','')::numeric, v_sum)),
        'bold', true));
    v_notes := jsonb_build_array(public.ui_text('supplier_doc.bill_copy_note'));

  elsif p_kind = 'monthly_statement' then
    v_month := to_date(p_ref || '-01', 'YYYY-MM-DD');
    v_from  := (v_month::text || ' 00:00:00 Asia/Kolkata')::timestamptz;
    v_to    := ((v_month + interval '1 month')::date::text || ' 00:00:00 Asia/Kolkata')::timestamptz;

    select coalesce(sum(coalesce(so2.total_amount,0)),0) into v_ordered
      from public.supplier_orders so2
     where so2.supplier_id = p_supplier
       and coalesce(so2.order_date, (so2.created_at at time zone 'Asia/Kolkata')::date)
           between v_month and (v_month + interval '1 month' - interval '1 day')::date;

    select coalesce(sum(coalesce(nullif(pb2.scan_result->>'total','')::numeric,0)),0) into v_billed
      from public.pending_bills pb2
     where pb2.supplier_id = p_supplier::text
       and coalesce(pb2.received_at, pb2.created_at) >= v_from
       and coalesce(pb2.received_at, pb2.created_at) <  v_to;

    select coalesce(sum(coalesce(sp2.amount,0)),0) into v_paid
      from public.supplier_payments sp2
      join public.supplier_orders so3 on so3.id = sp2.supplier_order_id
     where so3.supplier_id = p_supplier
       and sp2.created_at >= v_from and sp2.created_at < v_to;

    select coalesce(sum(amount),0) into v_debit
      from public._c403_debit_rows(p_supplier) d
     where d.at >= v_from and d.at < v_to;

    v_stamp := md5(v_ordered::text || v_billed::text || v_paid::text || v_debit::text);
    v_title := public.ui_textf('supplier_doc.stmt_title',
                 jsonb_build_object('month', to_char(v_month, 'Mon YYYY')));
    v_file  := 'STATEMENT-' || p_ref || '.pdf';

    v_header := jsonb_build_array(
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_supplier'), 'value', v_name),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_period'),
                         'value', to_char(v_month,'DD/MM/YYYY') || ' — ' ||
                                  to_char((v_month + interval '1 month' - interval '1 day')::date,'DD/MM/YYYY')));

    select coalesce(jsonb_agg(x order by x->>'date'), '[]'::jsonb) into v_rows from (
      select jsonb_build_object(
               'date', coalesce(to_char(so4.order_date,'DD/MM/YYYY'), public.ist_fmt(so4.created_at,'dmy')),
               'ref', coalesce(so4.order_code,''),
               'detail', coalesce(so4.status,''),
               'amount', public.inr_money(coalesce(so4.total_amount,0))) x
        from public.supplier_orders so4
       where so4.supplier_id = p_supplier
         and coalesce(so4.order_date, (so4.created_at at time zone 'Asia/Kolkata')::date)
             between v_month and (v_month + interval '1 month' - interval '1 day')::date) s;

    v_sections := jsonb_build_array(jsonb_build_object(
      'heading', public.ui_text('supplier_doc.stmt_orders_heading'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','date','label',public.ui_text('supplier_doc.col_date'),'align','left','width',80),
        jsonb_build_object('key','ref','label',public.ui_text('supplier_doc.col_ref'),'align','left','width',180),
        jsonb_build_object('key','detail','label',public.ui_text('supplier_doc.col_detail'),'align','left','width',200),
        jsonb_build_object('key','amount','label',public.ui_text('supplier_doc.col_amount'),'align','right','width',100)),
      'rows', v_rows,
      'empty_label', public.ui_text('supplier_doc.stmt_orders_empty')));

    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object(
               'date', public.ist_fmt(coalesce(pb3.received_at,pb3.created_at),'dmy'),
               'ref', coalesce(nullif(pb3.scan_result->>'invoice_no',''), coalesce(pb3.file_name,'')),
               'detail', coalesce(pb3.status,''),
               'amount', public.inr_money(coalesce(nullif(pb3.scan_result->>'total','')::numeric,0))) x
        from public.pending_bills pb3
       where pb3.supplier_id = p_supplier::text
         and coalesce(pb3.received_at,pb3.created_at) >= v_from
         and coalesce(pb3.received_at,pb3.created_at) <  v_to
       order by coalesce(pb3.received_at,pb3.created_at)) s;

    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'heading', public.ui_text('supplier_doc.stmt_bills_heading'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','date','label',public.ui_text('supplier_doc.col_date'),'align','left','width',80),
        jsonb_build_object('key','ref','label',public.ui_text('supplier_doc.lbl_invoice_no'),'align','left','width',180),
        jsonb_build_object('key','detail','label',public.ui_text('supplier_doc.col_detail'),'align','left','width',200),
        jsonb_build_object('key','amount','label',public.ui_text('supplier_doc.col_amount'),'align','right','width',100)),
      'rows', v_rows,
      'empty_label', public.ui_text('supplier_doc.stmt_bills_empty')));

    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_rows from (
      select jsonb_build_object(
               'date', public.ist_fmt(sp4.created_at,'dmy'),
               'ref', coalesce(nullif(sp4.utr,''), coalesce(sp4.mode,'')),
               'detail', coalesce(sp4.note,''),
               'amount', public.inr_money(coalesce(sp4.amount,0))) x
        from public.supplier_payments sp4
        join public.supplier_orders so5 on so5.id = sp4.supplier_order_id
       where so5.supplier_id = p_supplier
         and sp4.created_at >= v_from and sp4.created_at < v_to
       order by sp4.created_at) s;

    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'heading', public.ui_text('supplier_doc.stmt_payments_heading'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','date','label',public.ui_text('supplier_doc.col_date'),'align','left','width',80),
        jsonb_build_object('key','ref','label',public.ui_text('supplier_doc.col_ref'),'align','left','width',180),
        jsonb_build_object('key','detail','label',public.ui_text('supplier_doc.col_detail'),'align','left','width',200),
        jsonb_build_object('key','amount','label',public.ui_text('supplier_doc.col_amount'),'align','right','width',100)),
      'rows', v_rows,
      'empty_label', public.ui_text('supplier_doc.stmt_payments_empty')));

    select coalesce(jsonb_agg(jsonb_build_object(
             'date', public.ist_fmt(d.at,'dmy'),
             'ref', d.ref_label,
             'detail', d.product_name || ' · ' || d.reason_label,
             'amount', public.inr_money(d.amount)) order by d.at), '[]'::jsonb)
      into v_rows
      from public._c403_debit_rows(p_supplier) d
     where d.at >= v_from and d.at < v_to;

    v_sections := v_sections || jsonb_build_array(jsonb_build_object(
      'heading', public.ui_text('supplier_doc.stmt_debits_heading'),
      'columns', jsonb_build_array(
        jsonb_build_object('key','date','label',public.ui_text('supplier_doc.col_date'),'align','left','width',80),
        jsonb_build_object('key','ref','label',public.ui_text('supplier_doc.col_ref'),'align','left','width',180),
        jsonb_build_object('key','detail','label',public.ui_text('supplier_doc.col_detail'),'align','left','width',200),
        jsonb_build_object('key','amount','label',public.ui_text('supplier_doc.col_amount'),'align','right','width',100)),
      'rows', v_rows,
      'empty_label', public.ui_text('supplier_doc.stmt_debits_empty')));

    v_totals := jsonb_build_array(
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_ordered'), 'value', public.inr_money(v_ordered)),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_billed'),  'value', public.inr_money(v_billed)),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_debits'),  'value', public.inr_money(v_debit)),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_paid'),    'value', public.inr_money(v_paid)),
      jsonb_build_object('label', public.ui_text('supplier_doc.lbl_balance'),
                         'value', public.inr_money(v_billed - v_debit - v_paid), 'bold', true));
    v_notes := jsonb_build_array(public.ui_text('supplier_doc.stmt_note'));

  else
    return jsonb_build_object('ok', false, 'error', 'unknown_kind');
  end if;

  return jsonb_build_object(
    'ok', true,
    'stamp', v_stamp,
    'file_name', v_file,
    'doc', jsonb_build_object(
      'title', v_title,
      'subtitle', public.ui_textf('supplier_doc.subtitle',
                    jsonb_build_object('at', public.ist_fmt(now(),'dmy_hm'))),
      'brand', public.ui_text('supplier_doc.brand'),
      'header', v_header,
      'sections', v_sections,
      'totals', coalesce(v_totals,'[]'::jsonb),
      'notes', coalesce(v_notes,'[]'::jsonb),
      'footer', public.ui_text('supplier_doc.footer')));
end $fn$;
-- ═══════════════════════════════════════════════════════════════════════════
-- 7. THE DOCUMENT LIFECYCLE
--    request → (edge render) → report → ready. The same three-beat as
--    bill_jobs, one table down. A document is re-rendered only when its
--    SOURCE changed (source_stamp), so tapping the same statement twice in a
--    minute is one render and one file.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.supplier_documents_list(p_limit int default 24)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare sid uuid := public._c403_me(); v_groups jsonb; v jsonb; n int := least(greatest(coalesce(p_limit,24),1),100);
begin
  if sid is null then return public._c403_denied(); end if;

  -- monthly statements: every month this supplier has any activity in, newest
  -- first, plus the current month so he can always pull a running statement.
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'monthly_statement',
           'ref', m,
           'title', to_char(to_date(m||'-01','YYYY-MM-DD'),'FMMonth YYYY'),
           'subtitle', public.ui_text('supplier_docs.statement_subtitle'),
           'ready', exists (select 1 from public.supplier_document sd
                             where sd.supplier_id = sid and sd.kind='monthly_statement'
                               and sd.ref_key = m and sd.status='ready')
         ) order by m desc), '[]'::jsonb) into v
    from (select distinct to_char(coalesce(so.order_date,
                             (so.created_at at time zone 'Asia/Kolkata')::date),'YYYY-MM') m
            from public.supplier_orders so where so.supplier_id = sid
          union
          select to_char((now() at time zone 'Asia/Kolkata')::date,'YYYY-MM')) s
   where m is not null;

  v_groups := jsonb_build_array(jsonb_build_object(
    'key','statements','heading', public.ui_text('supplier_docs.statements_heading'),
    'empty_label', public.ui_text('supplier_docs.statements_empty'), 'rows', v));

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v from (
    select jsonb_build_object(
             'kind','purchase_order',
             'ref', so.id::text,
             'title', coalesce(nullif(so.order_code,''), left(so.id::text,8)),
             'subtitle', public.ui_textf('supplier_docs.po_subtitle', jsonb_build_object(
                           'date', coalesce(to_char(so.order_date,'DD/MM/YYYY'),
                                            public.ist_fmt(so.created_at,'dmy')),
                           'amount', public.inr_money(coalesce(so.total_amount,0)))),
             'ready', exists (select 1 from public.supplier_document sd
                               where sd.supplier_id = sid and sd.kind='purchase_order'
                                 and sd.ref_key = so.id::text and sd.status='ready')) x
      from public.supplier_orders so
     where so.supplier_id = sid
     order by coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date) desc,
              so.created_at desc
     limit n) s;

  v_groups := v_groups || jsonb_build_array(jsonb_build_object(
    'key','purchase_orders','heading', public.ui_text('supplier_docs.po_heading'),
    'empty_label', public.ui_text('supplier_docs.po_empty'), 'rows', v));

  select coalesce(jsonb_agg(x), '[]'::jsonb) into v from (
    select jsonb_build_object(
             'kind','bill_copy',
             'ref', pb.id::text,
             'title', coalesce(nullif(pb.scan_result->>'invoice_no',''),
                               coalesce(nullif(pb.file_name,''), left(pb.id::text,8))),
             'subtitle', public.ui_textf('supplier_docs.bill_subtitle', jsonb_build_object(
                           'date', public.ist_fmt(coalesce(pb.received_at,pb.created_at),'dmy'),
                           'status', coalesce(pb.status,''))),
             'ready', exists (select 1 from public.supplier_document sd
                               where sd.supplier_id = sid and sd.kind='bill_copy'
                                 and sd.ref_key = pb.id::text and sd.status='ready'),
             'source_bucket', coalesce(pb.bucket,''),
             'source_path', coalesce(pb.file_path,''),
             'source_label', case when coalesce(pb.file_path,'') = '' then ''
                                  else public.ui_text('supplier_docs.original_label') end) x
      from public.pending_bills pb
     where pb.supplier_id = sid::text
     order by coalesce(pb.received_at, pb.created_at) desc
     limit n) s;

  v_groups := v_groups || jsonb_build_array(jsonb_build_object(
    'key','bills','heading', public.ui_text('supplier_docs.bills_heading'),
    'empty_label', public.ui_text('supplier_docs.bills_empty'), 'rows', v));

  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('supplier_docs.title'),
    'subtitle', public.ui_text('supplier_docs.subtitle'),
    'download_label', public.ui_text('supplier_docs.download_label'),
    'building_label', public.ui_text('supplier_docs.building_label'),
    'groups', v_groups);
end $fn$;

create or replace function public.supplier_doc_request(p_kind text, p_ref text)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $fn$
declare
  sid uuid := public._c403_me();
  pay jsonb; d public.supplier_document%rowtype; v_id uuid;
begin
  if sid is null then return public._c403_denied(); end if;
  if coalesce(p_kind,'') not in ('purchase_order','bill_copy','monthly_statement') then
    return jsonb_build_object('ok', false, 'error', 'unknown_kind',
      'message', public.ui_text('supplier_docs.err_unknown_kind'));
  end if;

  pay := public._c403_doc_payload(sid, p_kind, p_ref);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
      'message', public.ui_text('supplier_docs.err_not_found'));
  end if;

  select * into d from public.supplier_document
   where supplier_id = sid and kind = p_kind and ref_key = p_ref;

  -- Nothing changed since the last render: serve the file that already exists.
  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok', true, 'status', 'ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public.ui_text('supplier_docs.ready_message'));
  end if;

  insert into public.supplier_document(
      supplier_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (sid, p_kind, p_ref, pay->'doc'->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (supplier_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('supplier_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status', 'building', 'doc_id', v_id,
    'poll_ms', 1500, 'message', public.ui_text('supplier_docs.building_message'));
end $fn$;

create or replace function public.supplier_doc_status(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare sid uuid := public._c403_me(); d public.supplier_document%rowtype;
begin
  if sid is null then return public._c403_denied(); end if;
  select * into d from public.supplier_document where id = p_id and supplier_id = sid;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('supplier_docs.err_not_found'));
  end if;
  if d.status = 'ready' and coalesce(d.path,'') <> '' then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public.ui_text('supplier_docs.ready_message'));
  end if;
  if d.status = 'failed' then
    return jsonb_build_object('ok', false, 'status','failed', 'doc_id', d.id,
      'error', 'render_failed', 'message', public.ui_text('supplier_docs.err_failed'));
  end if;
  return jsonb_build_object('ok', true, 'status','building', 'doc_id', d.id,
    'poll_ms', 1500, 'message', public.ui_text('supplier_docs.building_message'));
end $fn$;

-- ── the renderer's two doors (service role only) ────────────────────────────
create or replace function public.supplier_doc_render_input(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare d public.supplier_document%rowtype; pay jsonb;
begin
  select * into d from public.supplier_document where id = p_doc_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'doc_not_found'); end if;

  update public.supplier_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  pay := public._c403_doc_payload(d.supplier_id, d.kind, d.ref_key);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'supplier-docs',
    'path', d.supplier_id::text || '/' || d.kind || '/' ||
            regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'document.pdf'),
    'document', pay->'doc');
end $fn$;

create or replace function public.supplier_doc_report(
  p_doc_id uuid, p_ok boolean, p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes int default null, p_error text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  if p_ok then
    update public.supplier_document
       set status = 'ready', bucket = p_bucket, path = p_path,
           file_name = coalesce(nullif(p_name,''), file_name),
           bytes = p_bytes, ready_at = now(), last_error = null
     where id = p_doc_id;
  else
    update public.supplier_document
       set status = case when attempts >= 3 then 'failed' else 'queued' end,
           last_error = left(coalesce(p_error,''), 500)
     where id = p_doc_id;
  end if;
  return jsonb_build_object('ok', true, 'doc_id', p_doc_id);
end $fn$;

revoke execute on function public.supplier_doc_render_input(uuid) from public, anon, authenticated;
revoke execute on function public.supplier_doc_report(uuid, boolean, text, text, text, int, text)
  from public, anon, authenticated;
grant execute on function public.supplier_doc_render_input(uuid) to service_role;
grant execute on function public.supplier_doc_report(uuid, boolean, text, text, text, int, text)
  to service_role;

-- A render that never reported back is retried, never lost — the bill_jobs
-- guard, on the one dispatcher (no bare */N schedule).
create or replace function public.supplier_doc_sweep()
returns int language plpgsql security definer set search_path to 'public','net' as $fn$
declare r record; n int := 0;
begin
  update public.supplier_document
     set status = 'queued',
         last_error = coalesce(last_error, 'render timed out')
   where status = 'running' and started_at < now() - interval '5 minutes';

  for r in select id from public.supplier_document
            where status = 'queued' and attempts < 3
              and requested_at > now() - interval '1 day'
            order by requested_at limit 5 for update skip locked
  loop
    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('supplier_doc_id', r.id),
      timeout_milliseconds := 20000);
    n := n + 1;
  end loop;
  return n;
end $fn$;

insert into public.cron_task(name, ord, mode, work_sql, base_interval_s, enabled, note)
values ('supplier-doc-sweep', 225, 'poll', 'select public.supplier_doc_sweep()', 180, true,
        'CHANGE #403 — retries a supplier document whose render never reported back.')
on conflict (name) do update
  set work_sql = excluded.work_sql, base_interval_s = excluded.base_interval_s,
      enabled = true, note = excluded.note;
