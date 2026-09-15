-- CMD #367 · feature_gaps row 174 — Purchases view + downloadable purchase register.
--
-- The pharmacy buying on mediBO gets what PharmEasy Retailer / Udaan give a
-- retailer: spend by month, top products and companies, savings against the
-- printed MRP, and a purchase register it can reconcile against GSTR-2B.
-- Every number and every string is computed here; the Flutter screen prints
-- the payload verbatim. Money is INR, dates are IST.
--
-- Money convention (matches _order_taxable_base + gst_split): order_items
-- line_total is the TAXABLE base (qty x trade rate); GST is added on top at
-- the line's own gst_percent. MRP is reference only and is never a price.

-- ── copy ────────────────────────────────────────────────────────────────────
insert into app_settings (key, value) values
  ('purchases_screen_copy', jsonb_build_object(
     'title',            'Purchases',
     'subtitle',         'Your buying, month by month',
     'summary_title',    'This period',
     'spend_label',      'Total purchases',
     'orders_label',     'Orders',
     'gst_label',        'GST paid',
     'savings_label',    'Saved vs MRP',
     'months_title',     'Spend by month',
     'products_title',   'Top products',
     'companies_title',  'Top companies',
     'register_title',   'Purchase register',
     'register_note',    'Invoice-wise register with GST, ready to reconcile.',
     'register_csv',     'Download CSV',
     'register_pdf',     'Print / save PDF',
     'register_rows_label', 'lines',
     'empty_title',      'No purchases yet',
     'empty_note',       'Once your orders are billed, your spend, top products and register appear here.',
     'no_account_title', 'No pharmacy account',
     'no_account_note',  'This login is not linked to a pharmacy, so it has no purchase history.',
     'period_label',     'Last 12 months',
     'savings_none',     'No MRP on record',
     'register_empty',   'No billed lines in this period.'))
on conflict (key) do nothing;

-- ── the one line-level view every purchase number is built from ─────────────
-- Deliberately a function, not a view: it has to run as the caller's own
-- pharmacy and stay invisible to every other one.
create or replace function public._purchase_lines(p_cust uuid, p_from date, p_to date)
returns table (
  order_id      uuid,
  invoice_no    text,
  order_date    date,
  product_id    bigint,
  product_name  text,
  company       text,
  pack_label    text,
  qty           numeric,
  rate          numeric,
  taxable       numeric,
  gst_pct       numeric,
  gst_amt       numeric,
  line_total    numeric,
  mrp           numeric,
  mrp_value     numeric,
  saving        numeric
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with l as (
    select
      o.id                                             as order_id,
      coalesce(nullif(btrim(o.order_code),''), left(o.id::text, 8)) as invoice_no,
      coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) as order_date,
      oi.product_id,
      coalesce(nullif(btrim(oi.product_name),''), nullif(btrim(m.product_name),''), '') as product_name,
      coalesce(nullif(btrim(m.marketer),''), '')       as company,
      coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),''), '') as pack_label,
      coalesce(oi.quantity, 0)                          as qty,
      coalesce(oi.price, 0)                             as rate,
      round(coalesce(oi.line_total, coalesce(oi.quantity,0) * coalesce(oi.price,0)), 2) as taxable,
      -- The line carries its own GST when billing stamped one; otherwise the
      -- catalog resolver decides it. A register that prints 0% because nobody
      -- stamped the row is not reconcilable against GSTR-2B.
      coalesce(nullif(oi.gst_percent, 0),
               nullif((public.gst_for_product(oi.product_id)->>'pct')::numeric, 0),
               0)                                        as gst_pct,
      coalesce(oi.mrp, 0)                               as mrp
    from order_items oi
    join orders o on o.id = oi.order_id
    left join "MEDICINE" m on m.id = oi.product_id
    where p_cust is not null
      and o.customer_id = p_cust
      and coalesce(oi.unfulfillable, false) = false
      and (p_from is null or coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) >= p_from)
      and (p_to   is null or coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) <= p_to)
  )
  select
    l.order_id, l.invoice_no, l.order_date, l.product_id, l.product_name,
    l.company, l.pack_label, l.qty, l.rate, l.taxable, l.gst_pct,
    round(l.taxable * l.gst_pct / 100.0, 2)                     as gst_amt,
    l.taxable + round(l.taxable * l.gst_pct / 100.0, 2)         as line_total,
    l.mrp,
    round(l.qty * l.mrp, 2)                                     as mrp_value,
    -- A saving only exists where BOTH a trade rate and an MRP are on record.
    -- An unpriced line (rate 0, never billed) would otherwise report its whole
    -- MRP as money saved, which is the opposite of true.
    case when l.mrp > 0 and l.taxable > 0
         then greatest(round(l.qty * l.mrp, 2) - l.taxable, 0) else 0 end as saving
  from l;
$$;

-- ── the Purchases screen ────────────────────────────────────────────────────
create or replace function public.my_purchases_screen(p_months integer default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_copy   jsonb := coalesce((select value from app_settings where key='purchases_screen_copy'), '{}'::jsonb);
  v_cust   uuid  := public.my_customer_id();
  v_admin  boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_n      int   := greatest(1, least(coalesce(p_months, 12), 36));
  v_from   date;
  v_to     date  := (now() at time zone 'Asia/Kolkata')::date;
  v_spend  numeric := 0; v_gst numeric := 0; v_save numeric := 0; v_mrpv numeric := 0;
  v_orders int := 0; v_lines int := 0;
  v_months jsonb := '[]'::jsonb;
  v_prod   jsonb := '[]'::jsonb;
  v_comp   jsonb := '[]'::jsonb;
  v_peak   numeric := 0;
begin
  v_from := (date_trunc('month', v_to) - make_interval(months => v_n - 1))::date;

  if v_cust is null then
    return jsonb_build_object(
      'ok', true, 'copy', v_copy, 'has_data', false, 'no_customer_account', true,
      'is_admin_session', v_admin,
      'empty_title', coalesce(v_copy->>'no_account_title',''),
      'empty_note',  coalesce(v_copy->>'no_account_note',''),
      'period_label', coalesce(v_copy->>'period_label',''),
      'summary', '[]'::jsonb, 'months', '[]'::jsonb,
      'top_products', '[]'::jsonb, 'top_companies', '[]'::jsonb,
      'register', jsonb_build_object('available', false, 'row_count', 0, 'formats', '[]'::jsonb));
  end if;

  select coalesce(sum(l.line_total),0), coalesce(sum(l.gst_amt),0),
         coalesce(sum(l.saving),0),
         coalesce(sum(l.mrp_value) filter (where l.taxable > 0 and l.mrp > 0), 0),
         count(distinct l.order_id),    count(*)
    into v_spend, v_gst, v_save, v_mrpv, v_orders, v_lines
  from public._purchase_lines(v_cust, v_from, v_to) l;

  -- Spend by month: every month in the window is present, including the
  -- empty ones, so the bar chart never lies about a gap.
  select coalesce(max(x.spend), 0) into v_peak
  from (select coalesce(sum(l.line_total),0) as spend
          from public._purchase_lines(v_cust, v_from, v_to) l
         group by date_trunc('month', l.order_date)) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key',           to_char(g.m, 'YYYY-MM'),
           'label',         to_char(g.m, 'Mon YYYY'),
           'short_label',   to_char(g.m, 'Mon'),
           'spend',         coalesce(t.spend, 0),
           'spend_display', public.inr_money(coalesce(t.spend, 0)),
           'orders',        coalesce(t.orders, 0),
           'orders_label',  coalesce(t.orders, 0)::text || ' ' ||
                            case when coalesce(t.orders,0) = 1 then 'order' else 'orders' end,
           'bar_pct',       case when v_peak > 0
                                 then round(coalesce(t.spend,0) * 100.0 / v_peak)::int
                                 else 0 end,
           'is_empty',      (coalesce(t.spend, 0) = 0))
         order by g.m), '[]'::jsonb)
    into v_months
  from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') g(m)
  left join lateral (
    select sum(l.line_total) as spend, count(distinct l.order_id) as orders
      from public._purchase_lines(v_cust, v_from, v_to) l
     where date_trunc('month', l.order_date) = g.m) t on true;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',    coalesce(p.product_id::text,''),
           'name',          p.product_name,
           'company',       p.company,
           'qty',           p.qty,
           'qty_label',     trim_scale(p.qty)::text || ' ' ||
                            case when p.qty = 1 then 'unit' else 'units' end,
           'spend',         p.spend,
           'spend_display', public.inr_money(p.spend),
           'share_pct',     case when v_spend > 0 then round(p.spend * 100.0 / v_spend)::int else 0 end,
           'share_label',   case when v_spend > 0
                                 then round(p.spend * 100.0 / v_spend)::int::text || '% of spend'
                                 else '' end,
           'rank_label',    '#' || p.rn::text)
         order by p.rn), '[]'::jsonb)
    into v_prod
  from (
    select l.product_id,
           max(l.product_name)   as product_name,
           max(l.company)        as company,
           sum(l.qty)            as qty,
           sum(l.line_total)     as spend,
           row_number() over (order by sum(l.line_total) desc, max(l.product_name)) as rn
      from public._purchase_lines(v_cust, v_from, v_to) l
     group by l.product_id
     order by sum(l.line_total) desc
     limit 10) p;

  select coalesce(jsonb_agg(jsonb_build_object(
           'name',          c.company,
           'spend',         c.spend,
           'spend_display', public.inr_money(c.spend),
           'lines',         c.n,
           'share_pct',     case when v_spend > 0 then round(c.spend * 100.0 / v_spend)::int else 0 end,
           'share_label',   case when v_spend > 0
                                 then round(c.spend * 100.0 / v_spend)::int::text || '% of spend'
                                 else '' end,
           'rank_label',    '#' || c.rn::text)
         order by c.rn), '[]'::jsonb)
    into v_comp
  from (
    select l.company, sum(l.line_total) as spend, count(*) as n,
           row_number() over (order by sum(l.line_total) desc, l.company) as rn
      from public._purchase_lines(v_cust, v_from, v_to) l
     where l.company <> ''
     group by l.company
     order by sum(l.line_total) desc
     limit 10) c;

  return jsonb_build_object(
    'ok',                 true,
    'copy',               v_copy,
    'has_data',           (v_lines > 0),
    'no_customer_account',false,
    'is_admin_session',   v_admin,
    'period_label',       coalesce(v_copy->>'period_label',''),
    'from',               v_from::text,
    'to',                 v_to::text,
    'empty_title',        coalesce(v_copy->>'empty_title',''),
    'empty_note',         coalesce(v_copy->>'empty_note',''),
    -- Rendered as tiles in payload order; the screen picks nothing.
    'summary', jsonb_build_array(
      jsonb_build_object('key','spend',  'label', coalesce(v_copy->>'spend_label',''),
                         'value', public.inr_money(v_spend), 'tone','brand'),
      jsonb_build_object('key','orders', 'label', coalesce(v_copy->>'orders_label',''),
                         'value', v_orders::text, 'tone','neutral'),
      jsonb_build_object('key','gst',    'label', coalesce(v_copy->>'gst_label',''),
                         'value', public.inr_money(v_gst), 'tone','neutral'),
      jsonb_build_object('key','savings','label', coalesce(v_copy->>'savings_label',''),
                         'value', case when v_mrpv > 0 then public.inr_money(v_save)
                                       else coalesce(v_copy->>'savings_none','') end,
                         'tone', case when v_mrpv > 0 then 'success' else 'neutral' end)),
    'months_title',    coalesce(v_copy->>'months_title',''),
    'months',          v_months,
    'products_title',  coalesce(v_copy->>'products_title',''),
    'top_products',    v_prod,
    'companies_title', coalesce(v_copy->>'companies_title',''),
    'top_companies',   v_comp,
    'register', jsonb_build_object(
      'title',      coalesce(v_copy->>'register_title',''),
      'note',       coalesce(v_copy->>'register_note',''),
      'available',  (v_lines > 0),
      'row_count',  v_lines,
      'count_label',v_lines::text || ' ' || coalesce(v_copy->>'register_rows_label','lines'),
      'empty_note', coalesce(v_copy->>'register_empty',''),
      'formats',    case when v_lines > 0 then jsonb_build_array(
                      jsonb_build_object('key','csv','label', coalesce(v_copy->>'register_csv','')),
                      jsonb_build_object('key','pdf','label', coalesce(v_copy->>'register_pdf','')))
                    else '[]'::jsonb end));
end $$;

-- ── the register itself, generated server-side in both formats ──────────────
-- 'csv'  → a real comma-separated register (GSTR-2B reconcilable).
-- 'pdf'  → a complete, self-contained print document. There is no PDF writer
--          in plpgsql, so the backend renders the finished page and the
--          browser's own print pipeline saves it as PDF — the app still
--          composes nothing.
create or replace function public.purchase_register_export(
  p_format text default 'csv',
  p_from   date default null,
  p_to     date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='purchases_screen_copy'), '{}'::jsonb);
  v_cust uuid  := public.my_customer_id();
  v_fmt  text  := lower(coalesce(nullif(btrim(p_format),''), 'csv'));
  v_from date  := coalesce(p_from, (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date) - interval '11 months')::date);
  v_to   date  := coalesce(p_to, (now() at time zone 'Asia/Kolkata')::date);
  v_name text;
  v_body text := '';
  v_rows int  := 0;
  v_pharm text := '';
  v_spend numeric := 0; v_tax numeric := 0; v_gst numeric := 0; v_save numeric := 0;
begin
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'no_customer_account',
      'message', coalesce(v_copy->>'no_account_note',''));
  end if;
  if v_fmt not in ('csv','pdf') then v_fmt := 'csv'; end if;

  select count(*), coalesce(sum(l.line_total),0), coalesce(sum(l.taxable),0),
         coalesce(sum(l.gst_amt),0), coalesce(sum(l.saving),0)
    into v_rows, v_spend, v_tax, v_gst, v_save
  from public._purchase_lines(v_cust, v_from, v_to) l;

  if v_rows = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty',
      'message', coalesce(v_copy->>'register_empty',''));
  end if;

  select coalesce(max(o.pharmacy_name), '') into v_pharm
    from orders o where o.customer_id = v_cust;

  v_name := 'purchase-register-' || to_char(v_from,'YYYYMMDD') || '-' || to_char(v_to,'YYYYMMDD');

  if v_fmt = 'csv' then
    v_body := 'Invoice No,Date,Product,Company,Pack,Qty,Rate,Taxable,GST %,GST Amount,Line Total,MRP,Saved vs MRP' || E'\n';
    select v_body || coalesce(string_agg(
             public._csv_cell(l.invoice_no)      || ',' ||
             to_char(l.order_date,'DD-MM-YYYY')  || ',' ||
             public._csv_cell(l.product_name)    || ',' ||
             public._csv_cell(l.company)         || ',' ||
             public._csv_cell(l.pack_label)      || ',' ||
             trim_scale(l.qty)::text             || ',' ||
             to_char(l.rate,      'FM9999999990.00') || ',' ||
             to_char(l.taxable,   'FM9999999990.00') || ',' ||
             trim_scale(l.gst_pct)::text         || ',' ||
             to_char(l.gst_amt,   'FM9999999990.00') || ',' ||
             to_char(l.line_total,'FM9999999990.00') || ',' ||
             to_char(l.mrp,       'FM9999999990.00') || ',' ||
             to_char(l.saving,    'FM9999999990.00'),
             E'\n' order by l.order_date, l.invoice_no, l.product_name), '')
      into v_body
    from public._purchase_lines(v_cust, v_from, v_to) l;

    v_body := v_body || E'\n' ||
      'TOTAL,,,,,,,' || to_char(v_tax,'FM9999999990.00') || ',,' ||
      to_char(v_gst,'FM9999999990.00') || ',' ||
      to_char(v_spend,'FM9999999990.00') || ',,' ||
      to_char(v_save,'FM9999999990.00') || E'\n';

    return jsonb_build_object(
      'ok', true, 'format', 'csv',
      'filename',  v_name || '.csv',
      'mime',      'text/csv;charset=utf-8',
      'content',   v_body,
      'row_count', v_rows,
      'toast',     'Purchase register downloaded');
  end if;

  -- print document
  select
    '<!doctype html><html><head><meta charset="utf-8">'
    || '<title>Purchase register ' || to_char(v_from,'DD Mon YYYY') || ' – ' || to_char(v_to,'DD Mon YYYY') || '</title>'
    || '<style>'
    || 'body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:#111827;margin:24px;}'
    || 'h1{font-size:20px;font-weight:700;margin:0 0 4px;}'
    || 'p.sub{font-size:13px;color:#6B7280;margin:0 0 24px;}'
    || 'table{border-collapse:collapse;width:100%;font-size:12px;}'
    || 'th{text-align:left;color:#6B7280;font-weight:600;border-bottom:1px solid #E5E7EB;padding:8px 6px;}'
    || 'td{padding:8px 6px;border-bottom:1px solid #E5E7EB;}'
    || 'td.n,th.n{text-align:right;}'
    || 'tfoot td{font-weight:700;border-top:2px solid #E5E7EB;border-bottom:none;}'
    || '@media print{body{margin:12mm;} @page{size:A4 landscape;}}'
    || '</style></head><body>'
    || '<h1>' || public._html_cell(coalesce(v_copy->>'register_title','Purchase register')) || '</h1>'
    || '<p class="sub">'
    || case when v_pharm <> '' then public._html_cell(v_pharm) || ' &middot; ' else '' end
    || to_char(v_from,'DD Mon YYYY') || ' &ndash; ' || to_char(v_to,'DD Mon YYYY')
    || ' &middot; ' || v_rows::text || ' ' || coalesce(v_copy->>'register_rows_label','lines') || '</p>'
    || '<table><thead><tr>'
    || '<th>Invoice No</th><th>Date</th><th>Product</th><th>Company</th><th>Pack</th>'
    || '<th class="n">Qty</th><th class="n">Rate</th><th class="n">Taxable</th>'
    || '<th class="n">GST %</th><th class="n">GST</th><th class="n">Line total</th>'
    || '<th class="n">MRP</th><th class="n">Saved</th>'
    || '</tr></thead><tbody>'
    || coalesce((select string_agg(
           '<tr><td>' || public._html_cell(l.invoice_no) || '</td>'
        || '<td>' || to_char(l.order_date,'DD-MM-YYYY') || '</td>'
        || '<td>' || public._html_cell(l.product_name) || '</td>'
        || '<td>' || public._html_cell(l.company) || '</td>'
        || '<td>' || public._html_cell(l.pack_label) || '</td>'
        || '<td class="n">' || trim_scale(l.qty)::text || '</td>'
        || '<td class="n">' || public.inr_money(l.rate) || '</td>'
        || '<td class="n">' || public.inr_money(l.taxable) || '</td>'
        || '<td class="n">' || trim_scale(l.gst_pct)::text || '</td>'
        || '<td class="n">' || public.inr_money(l.gst_amt) || '</td>'
        || '<td class="n">' || public.inr_money(l.line_total) || '</td>'
        || '<td class="n">' || public.inr_money(l.mrp) || '</td>'
        || '<td class="n">' || public.inr_money(l.saving) || '</td></tr>',
        '' order by l.order_date, l.invoice_no, l.product_name)
      from public._purchase_lines(v_cust, v_from, v_to) l), '')
    || '</tbody><tfoot><tr><td colspan="7">TOTAL</td>'
    || '<td class="n">' || public.inr_money(v_tax)   || '</td><td></td>'
    || '<td class="n">' || public.inr_money(v_gst)   || '</td>'
    || '<td class="n">' || public.inr_money(v_spend) || '</td><td></td>'
    || '<td class="n">' || public.inr_money(v_save)  || '</td></tr></tfoot>'
    || '</table></body></html>'
    into v_body;

  return jsonb_build_object(
    'ok', true, 'format', 'pdf',
    'filename',  v_name || '.pdf',
    'mime',      'text/html;charset=utf-8',
    'content',   v_body,
    'row_count', v_rows,
    'toast',     'Opening the register — use your browser''s Save as PDF');
end $$;

-- csv / html escaping, so a product name with a comma or a quote can never
-- corrupt the register.
create or replace function public._csv_cell(p text)
returns text language sql immutable as $$
  select case when coalesce(p,'') ~ '[",\n\r]'
              then '"' || replace(coalesce(p,''), '"', '""') || '"'
              else coalesce(p,'') end;
$$;

create or replace function public._html_cell(p text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(p,''),
    '&','&amp;'), '<','&lt;'), '>','&gt;'), '"','&quot;');
$$;

grant execute on function public.my_purchases_screen(integer) to authenticated;
grant execute on function public.purchase_register_export(text, date, date) to authenticated;
revoke execute on function public._purchase_lines(uuid, date, date) from public, anon, authenticated;
