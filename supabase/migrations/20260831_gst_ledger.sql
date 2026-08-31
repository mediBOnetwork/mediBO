-- CHANGE #320 — GST input credit ledger, monthly position and GSTR exports.
--
-- Before this migration mediBO had no GST at all: only raw fields
-- (bill_lines.gst_pct/.hsn, supplier_profiles.gstin, billing_config.seller_gstin,
-- pharmacy_profiles.gstin, MEDICINE.gst_percent). No ledger, no CGST/SGST/IGST
-- split, no liability.
--
-- Applied live via psql/apply_migration and dumped back out of the database, so
-- this file is exactly what is running. Idempotent throughout: every object is
-- `create or replace` / `if not exists`, so a resumed worker re-applying it is a
-- silent no-op.
--
-- Reconciliation is the whole point, and it is proved rather than asserted:
--   * INPUT  — qty x PTR rounded, less the line discount rounded, is what a
--              purchase invoice prints; gst_split() then makes cgst+sgst (or
--              igst) EXACTLY the tax on that line.
--   * OUTPUT — the same arithmetic _bill_compose() prints, with the slab read
--              from ptr_discount_pct(), so the ledger and the customer's own
--              invoice agree by construction.
set search_path to public;

-- ── tables ─────────────────────────────────────────────────────────────
create table if not exists public.gst_2b_entry (
  id uuid default gen_random_uuid() not null,
  tax_period date not null,
  gstin text,
  invoice_no text,
  invoice_date date,
  taxable numeric default 0 not null,
  tax numeric default 0 not null,
  raw text,
  created_at timestamp with time zone default now() not null
);
create table if not exists public.gst_ledger (
  id uuid default gen_random_uuid() not null,
  direction text not null,
  source text not null,
  source_id uuid not null,
  line_ref text not null,
  tax_period date not null,
  invoice_no text,
  invoice_date date,
  invoice_date_text text,
  counterparty_id text,
  counterparty_name text,
  counterparty_gstin text,
  hsn text,
  product_name text,
  qty numeric,
  taxable numeric default 0 not null,
  rate numeric default 0 not null,
  cgst numeric default 0 not null,
  sgst numeric default 0 not null,
  igst numeric default 0 not null,
  total_tax numeric generated always as (((cgst + sgst) + igst)) stored,
  is_interstate boolean default false not null,
  gstin_missing boolean default false not null,
  place_of_supply text,
  order_id uuid,
  order_code text,
  built_at timestamp with time zone default now() not null
);
create table if not exists public.gst_state_code (
  code text not null,
  name text not null
);

CREATE INDEX gst_2b_entry_match_idx ON public.gst_2b_entry USING btree (tax_period, gstin, invoice_no);
CREATE INDEX gst_2b_entry_period_idx ON public.gst_2b_entry USING btree (tax_period);
CREATE UNIQUE INDEX gst_2b_entry_pkey ON public.gst_2b_entry USING btree (id);
CREATE INDEX gst_ledger_party_idx ON public.gst_ledger USING btree (direction, counterparty_id, tax_period);
CREATE INDEX gst_ledger_period_idx ON public.gst_ledger USING btree (tax_period, direction);
CREATE UNIQUE INDEX gst_ledger_pkey ON public.gst_ledger USING btree (id);
CREATE UNIQUE INDEX gst_ledger_row_uq ON public.gst_ledger USING btree (direction, source, source_id, line_ref);
CREATE UNIQUE INDEX gst_state_code_pkey ON public.gst_state_code USING btree (code);

-- ── functions ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._gst_assert_admin()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if public.is_admin() then return; end if;
  if current_user in ('service_role','postgres','supabase_admin') then return; end if;
  raise exception 'not authorised' using errcode = '42501';
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_gst_screen(p_period date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cur    date := date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)::date;
  v_period date;
  v_periods jsonb; v_seller text;
  o_tx numeric:=0; o_c numeric:=0; o_s numeric:=0; o_i numeric:=0; o_t numeric:=0;
  i_tx numeric:=0; i_c numeric:=0; i_s numeric:=0; i_i numeric:=0; i_t numeric:=0;
  v_net numeric; v_rows int; v_out_rows int;
  v_position jsonb; v_credit jsonb; v_exports jsonb; v_recon jsonb;
  v_sup jsonb; v_b2b jsonb; v_b2b_txt text; v_hsn jsonb; v_hsn_txt text;
  v_3b jsonb; v_3b_txt text; v_rrows jsonb;
  v_excluded int := 0; v_pend_tax numeric := 0; v_pend_n int := 0; v_2b int := 0;
begin
  perform public._gst_assert_admin();
  select seller_gstin into v_seller from public.billing_config where id = 1;

  v_period := date_trunc('month', coalesce(p_period,
                (select max(tax_period) from public.gst_ledger), v_cur))::date;

  select jsonb_agg(jsonb_build_object(
           'key', to_char(p,'YYYY-MM-DD'),
           'label', to_char(p,'FMMonth YYYY'),
           'selected', p = v_period) order by p desc)
    into v_periods
    from (select distinct tax_period p from public.gst_ledger
          union select v_cur union select v_period) q;

  select coalesce(sum(taxable)   filter (where direction='output'),0),
         coalesce(sum(cgst)      filter (where direction='output'),0),
         coalesce(sum(sgst)      filter (where direction='output'),0),
         coalesce(sum(igst)      filter (where direction='output'),0),
         coalesce(sum(total_tax) filter (where direction='output'),0),
         coalesce(sum(taxable)   filter (where direction='input'),0),
         coalesce(sum(cgst)      filter (where direction='input'),0),
         coalesce(sum(sgst)      filter (where direction='input'),0),
         coalesce(sum(igst)      filter (where direction='input'),0),
         coalesce(sum(total_tax) filter (where direction='input'),0),
         count(*)::int,
         count(*) filter (where direction='output')::int
    into o_tx,o_c,o_s,o_i,o_t, i_tx,i_c,i_s,i_i,i_t, v_rows, v_out_rows
    from public.gst_ledger where tax_period = v_period;

  v_net := round(o_t - i_t, 2);

  -- ── 4) Monthly position, with the working shown ─────────────────────────
  v_position := jsonb_build_object(
    'heading', public._c('gst.working.heading'),
    'note',    public._c('gst.working.note'),
    'empty',   case when v_rows = 0 then public._c('gst.position.empty') end,
    'rows', jsonb_build_array(
      jsonb_build_object('label', public._c('gst.working.output'),
        'sub', 'on ' || public.inr_money(o_tx) || ' taxable',
        'value_label', public.inr_money(o_t), 'tone','neutral'),
      jsonb_build_object('label', public._c('gst.working.input'),
        'sub', 'on ' || public.inr_money(i_tx) || ' taxable',
        'value_label', '- ' || public.inr_money(i_t), 'tone','success')),
    'net_label', case when v_net >= 0 then public._c('gst.working.net')
                      else public._c('gst.working.carry') end,
    'net_value_label', public.inr_money(abs(v_net)),
    'net_is_payable', v_net >= 0,
    'net_tone', case when v_net > 0 then 'warning' else 'success' end,
    'head_columns', jsonb_build_array(
      jsonb_build_object('key','label','label','Head','align','left'),
      jsonb_build_object('key','output_label','label','Output','align','right'),
      jsonb_build_object('key','input_label','label','Credit','align','right'),
      jsonb_build_object('key','net_label','label','Net','align','right')),
    'heads', jsonb_build_array(
      jsonb_build_object('label','CGST','output_label',public.inr_money(o_c),
        'input_label',public.inr_money(i_c),'net_label',public.inr_money(round(o_c-i_c,2))),
      jsonb_build_object('label','SGST','output_label',public.inr_money(o_s),
        'input_label',public.inr_money(i_s),'net_label',public.inr_money(round(o_s-i_s,2))),
      jsonb_build_object('label','IGST','output_label',public.inr_money(o_i),
        'input_label',public.inr_money(i_i),'net_label',public.inr_money(round(o_i-i_i,2)))));

  -- ── 5) Input credit BY SOURCE, invoice numbers and dates ────────────────
  with inv as (
    select counterparty_id, coalesce(nullif(counterparty_name,''),'(unnamed supplier)') nm,
           counterparty_gstin gstin, invoice_no, invoice_date, invoice_date_text,
           sum(taxable) tx, sum(total_tax) tax
      from public.gst_ledger
     where tax_period = v_period and direction = 'input'
     group by 1,2,3,4,5,6
  ), sup as (
    select nm, gstin, sum(tax) tax, sum(tx) tx, count(*)::int n,
           jsonb_agg(jsonb_build_object(
             'invoice_no', coalesce(nullif(invoice_no,''),'(no number on the bill)'),
             'date_label', coalesce(nullif(invoice_date_text,''), to_char(invoice_date,'DD/MM/YYYY')),
             'taxable_label', public.inr_money(tx),
             'tax_label', public.inr_money(tax))
             order by invoice_date desc, invoice_no) invoices
      from inv group by 1,2
  )
  select jsonb_agg(jsonb_build_object(
           'name', nm,
           'gstin', coalesce(gstin,''),
           'gstin_label', case when gstin is null then public._c('gst.recon.no_gstin')
                               else gstin || '  ·  ' || public.gst_state_label(gstin) end,
           'has_gstin', gstin is not null,
           'credit_label', public.inr_money(tax),
           'taxable_label', public.inr_money(tx),
           'count_label', n || ' invoice' || case when n = 1 then '' else 's' end,
           'invoices', invoices) order by tax desc)
    into v_sup from sup;

  v_credit := jsonb_build_object(
    'heading', public._c('gst.credit.heading'),
    'empty', case when v_sup is null then public._c('gst.credit.empty') end,
    'total_label', public.inr_money(i_t),
    'suppliers', coalesce(v_sup,'[]'::jsonb));

  -- ── 6) GSTR-1 (outward, invoice-wise) ───────────────────────────────────
  with b as (
    select coalesce(nullif(counterparty_gstin,''),'URP') gstin,
           coalesce(nullif(counterparty_name,''),'') nm,
           coalesce(nullif(invoice_no,''),'') inv,
           invoice_date dt, rate,
           sum(taxable) tx, sum(cgst) c, sum(sgst) s, sum(igst) i
      from public.gst_ledger
     where tax_period = v_period and direction = 'output'
     group by 1,2,3,4,5)
  select jsonb_agg(jsonb_build_object(
           'gstin', gstin, 'name', nm, 'invoice_no', inv,
           'date', to_char(dt,'DD/MM/YYYY'),
           'rate', trim_scale(rate)::text || '%',
           'taxable', public.inr_money(tx),
           'cgst', public.inr_money(c), 'sgst', public.inr_money(s),
           'igst', public.inr_money(i),
           'total', public.inr_money(round(c+s+i,2))) order by dt, inv, rate),
         string_agg(gstin||','||replace(nm,',',' ')||','||inv||','||to_char(dt,'DD/MM/YYYY')||','
                    ||trim_scale(rate)::text||','||tx::text||','||c::text||','||s::text||','||i::text,
                    E'\n' order by dt, inv, rate)
    into v_b2b, v_b2b_txt from b;

  with h as (
    select hsn, rate, sum(qty) q, sum(taxable) tx, sum(cgst) c, sum(sgst) s, sum(igst) i
      from public.gst_ledger
     where tax_period = v_period and direction = 'output'
     group by 1,2)
  select jsonb_agg(jsonb_build_object(
           'hsn', hsn, 'rate', trim_scale(rate)::text || '%',
           'qty', trim_scale(coalesce(q,0))::text,
           'taxable', public.inr_money(tx),
           'cgst', public.inr_money(c), 'sgst', public.inr_money(s),
           'igst', public.inr_money(i),
           'total', public.inr_money(round(c+s+i,2))) order by hsn, rate),
         string_agg(hsn||','||trim_scale(rate)::text||','||trim_scale(coalesce(q,0))::text||','
                    ||tx::text||','||c::text||','||s::text||','||i::text, E'\n' order by hsn, rate)
    into v_hsn, v_hsn_txt from h;

  -- GSTR-3B: the summary the portal asks for, in its own row order.
  v_3b := jsonb_build_array(
    jsonb_build_object('row','3.1(a)','label','Outward taxable supplies',
      'taxable', public.inr_money(o_tx), 'cgst', public.inr_money(o_c),
      'sgst', public.inr_money(o_s), 'igst', public.inr_money(o_i)),
    jsonb_build_object('row','4(A)(5)','label','ITC — all other input tax credit',
      'taxable', public.inr_money(i_tx), 'cgst', public.inr_money(i_c),
      'sgst', public.inr_money(i_s), 'igst', public.inr_money(i_i)),
    jsonb_build_object('row','5.1','label','Tax payable in cash',
      'taxable', '', 'cgst', public.inr_money(greatest(round(o_c-i_c,2),0)),
      'sgst', public.inr_money(greatest(round(o_s-i_s,2),0)),
      'igst', public.inr_money(greatest(round(o_i-i_i,2),0))));
  v_3b_txt :=
    '3.1(a),Outward taxable supplies,'||o_tx::text||','||o_c::text||','||o_s::text||','||o_i::text||E'\n'||
    '4(A)(5),ITC all other,'||i_tx::text||','||i_c::text||','||i_s::text||','||i_i::text||E'\n'||
    '5.1,Tax payable in cash,,'||greatest(round(o_c-i_c,2),0)::text||','
      ||greatest(round(o_s-i_s,2),0)::text||','||greatest(round(o_i-i_i,2),0)::text;

  v_exports := jsonb_build_object(
    'heading', public._c('gst.exports.heading'),
    'copy_hint', public._c('gst.exports.copy_hint'),
    'empty', case when v_out_rows = 0 then public._c('gst.exports.empty') end,
    'blocks', jsonb_build_array(
      jsonb_build_object('key','gstr1_b2b','title', public._c('gst.exports.gstr1'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','gstin','label','GSTIN','align','left'),
          jsonb_build_object('key','invoice_no','label','Invoice','align','left'),
          jsonb_build_object('key','date','label','Date','align','left'),
          jsonb_build_object('key','rate','label','Rate','align','right'),
          jsonb_build_object('key','taxable','label','Taxable','align','right'),
          jsonb_build_object('key','cgst','label','CGST','align','right'),
          jsonb_build_object('key','sgst','label','SGST','align','right'),
          jsonb_build_object('key','igst','label','IGST','align','right')),
        'rows', coalesce(v_b2b,'[]'::jsonb),
        'csv_header','gstin,name,invoice_no,invoice_date,rate,taxable,cgst,sgst,igst',
        'csv', coalesce(v_b2b_txt,'')),
      jsonb_build_object('key','gstr1_hsn','title', public._c('gst.exports.hsn'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','hsn','label','HSN','align','left'),
          jsonb_build_object('key','rate','label','Rate','align','right'),
          jsonb_build_object('key','qty','label','Qty','align','right'),
          jsonb_build_object('key','taxable','label','Taxable','align','right'),
          jsonb_build_object('key','cgst','label','CGST','align','right'),
          jsonb_build_object('key','sgst','label','SGST','align','right'),
          jsonb_build_object('key','igst','label','IGST','align','right')),
        'rows', coalesce(v_hsn,'[]'::jsonb),
        'csv_header','hsn,rate,qty,taxable,cgst,sgst,igst',
        'csv', coalesce(v_hsn_txt,'')),
      jsonb_build_object('key','gstr3b','title', public._c('gst.exports.gstr3b'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','row','label','Row','align','left'),
          jsonb_build_object('key','label','label','Description','align','left'),
          jsonb_build_object('key','taxable','label','Taxable','align','right'),
          jsonb_build_object('key','cgst','label','CGST','align','right'),
          jsonb_build_object('key','sgst','label','SGST','align','right'),
          jsonb_build_object('key','igst','label','IGST','align','right')),
        'rows', v_3b,
        'csv_header','row,description,taxable,cgst,sgst,igst',
        'csv', v_3b_txt)));

  -- ── 7) GSTR-2B reconciliation ───────────────────────────────────────────
  select count(*)::int into v_2b from public.gst_2b_entry where tax_period = v_period;

  select count(*)::int into v_excluded
    from public.bill_lines b join public.pending_bills pb on pb.id = b.pending_bill_id
   where pb.status = 'imported' and b.needs_fix is not null
     and date_trunc('month', public.gst_parse_date(pb.scan_result->>'invoice_date',
           (coalesce(pb.received_at, pb.created_at) at time zone 'Asia/Kolkata')::date)) = v_period;

  with inv as (
    select coalesce(nullif(counterparty_name,''),'(unnamed supplier)') nm,
           counterparty_gstin gstin, invoice_no, invoice_date, invoice_date_text,
           sum(taxable) tx, sum(total_tax) tax
      from public.gst_ledger
     where tax_period = v_period and direction = 'input'
     group by 1,2,3,4,5
  ), st as (
    select i.*,
           case
             when i.gstin is null then 'no_gstin'
             when exists (select 1 from public.gst_2b_entry e
                           where e.tax_period = v_period
                             and e.gstin = i.gstin
                             and public.gst_inv_key(e.invoice_no) is not distinct from public.gst_inv_key(i.invoice_no))
               then 'matched'
             else 'pending'
           end as status
      from inv i
  )
  select jsonb_agg(jsonb_build_object(
           'supplier', nm,
           'gstin', coalesce(gstin, ''),
           'invoice_no', coalesce(nullif(invoice_no,''),'(no number on the bill)'),
           'date_label', coalesce(nullif(invoice_date_text,''), to_char(invoice_date,'DD/MM/YYYY')),
           'taxable_label', public.inr_money(tx),
           'tax_label', public.inr_money(tax),
           'status', status,
           'status_label', case status
                             when 'matched' then public._c('gst.recon.matched')
                             when 'pending' then public._c('gst.recon.pending')
                             else public._c('gst.recon.no_gstin') end,
           'tone', case status when 'matched' then 'success'
                               when 'pending' then 'warning' else 'danger' end)
           order by case status when 'matched' then 2 else 1 end, tax desc),
         coalesce(sum(tax) filter (where status <> 'matched'),0),
         count(*) filter (where status <> 'matched')::int
    into v_rrows, v_pend_tax, v_pend_n from st;

  v_recon := jsonb_build_object(
    'heading', public._c('gst.recon.heading'),
    'note',    public._c('gst.recon.note'),
    'empty',   case when v_rrows is null then public._c('gst.credit.empty')
                    when v_pend_n = 0 then public._c('gst.recon.empty') end,
    'rows', coalesce(v_rrows,'[]'::jsonb),
    'at_risk_label', public.inr_money(v_pend_tax),
    'summary_label', case when v_pend_n = 0 then public._c('gst.recon.empty')
                          else v_pend_n || ' invoice' || case when v_pend_n = 1 then '' else 's' end
                               || '  ·  ' || public.inr_money(v_pend_tax) || ' of credit not confirmed' end,
    'has_2b', v_2b > 0,
    'source_label', case when v_2b > 0
                         then v_2b || ' GSTR-2B row' || case when v_2b = 1 then '' else 's' end || ' loaded'
                         else 'No GSTR-2B loaded for this month — paste the portal extract to match it.' end,
    'excluded_label', case when v_excluded > 0
                           then v_excluded || ' purchase line' || case when v_excluded = 1 then '' else 's' end
                                || ' held back until the bill is fixed' end,
    'import_label', 'Paste GSTR-2B',
    'import_hint', 'One row per line: GSTIN, invoice no, invoice date, taxable, tax. JSON from the portal works too.');

  return jsonb_build_object(
    'ok', true,
    'title', public._c('gst.title'),
    'subtitle', public._c('gst.subtitle'),
    'seller_gstin', coalesce(v_seller,''),
    'seller_label', case when v_seller is null then 'Seller GSTIN not set in billing config.'
                         else v_seller || '  ·  ' || public.gst_state_label(v_seller) end,
    'period_key', to_char(v_period,'YYYY-MM-DD'),
    'period_label', to_char(v_period,'FMMonth YYYY'),
    'periods', coalesce(v_periods,'[]'::jsonb),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','position','label', public._c('gst.tab.position')),
      jsonb_build_object('key','credit',  'label', public._c('gst.tab.credit')),
      jsonb_build_object('key','exports', 'label', public._c('gst.tab.exports')),
      jsonb_build_object('key','recon',   'label', public._c('gst.tab.recon'))),
    'rebuild_label', public._c('gst.rebuild'),
    'retry_label', public._c('gst.retry'),
    'position', v_position,
    'credit', v_credit,
    'exports', v_exports,
    'recon', v_recon);
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_2b_import(p_period date, p_text text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_period date := date_trunc('month', coalesce(p_period, (now() at time zone 'Asia/Kolkata')::date))::date;
  v_txt text := btrim(coalesce(p_text,''));
  v_json jsonb; v_ok int := 0; v_bad int := 0;
  ln text; parts text[];
begin
  perform public._gst_assert_admin();
  if v_txt = '' then
    return jsonb_build_object('ok', false, 'message', 'Nothing pasted.');
  end if;

  delete from public.gst_2b_entry where tax_period = v_period;

  if left(v_txt,1) in ('[','{') then
    begin
      v_json := v_txt::jsonb;
    exception when others then
      return jsonb_build_object('ok', false, 'message', 'That is not valid JSON.');
    end;
    if jsonb_typeof(v_json) = 'object' then v_json := jsonb_build_array(v_json); end if;
    insert into public.gst_2b_entry (tax_period, gstin, invoice_no, invoice_date, taxable, tax, raw)
    select v_period,
           public.gst_norm_gstin(e->>'gstin'),
           nullif(btrim(coalesce(e->>'invoice_no', e->>'inum','')),''),
           public.gst_parse_date(coalesce(e->>'invoice_date', e->>'idt'), v_period),
           coalesce((e->>'taxable')::numeric, (e->>'txval')::numeric, 0),
           coalesce((e->>'tax')::numeric,
                    coalesce((e->>'cgst')::numeric,0) + coalesce((e->>'sgst')::numeric,0)
                    + coalesce((e->>'igst')::numeric,0), 0),
           e::text
      from jsonb_array_elements(v_json) e;
    get diagnostics v_ok = row_count;
  else
    foreach ln in array regexp_split_to_array(v_txt, E'\r?\n') loop
      ln := btrim(ln);
      continue when ln = '';
      parts := regexp_split_to_array(ln, '\s*,\s*');
      if array_length(parts,1) is null or array_length(parts,1) < 2 then
        v_bad := v_bad + 1; continue;
      end if;
      if public.gst_norm_gstin(parts[1]) is null and public.gst_inv_key(parts[2]) is null then
        v_bad := v_bad + 1; continue;   -- header row or junk
      end if;
      begin
        insert into public.gst_2b_entry (tax_period, gstin, invoice_no, invoice_date, taxable, tax, raw)
        values (v_period,
                public.gst_norm_gstin(parts[1]),
                nullif(btrim(parts[2]),''),
                public.gst_parse_date(coalesce(parts[3],''), v_period),
                coalesce(nullif(regexp_replace(coalesce(parts[4],''),'[^0-9.\-]','','g'),'')::numeric, 0),
                coalesce(nullif(regexp_replace(coalesce(parts[5],''),'[^0-9.\-]','','g'),'')::numeric, 0),
                ln);
        v_ok := v_ok + 1;
      exception when others then
        v_bad := v_bad + 1;
      end;
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true, 'imported', v_ok, 'skipped', v_bad,
    'message', v_ok || ' GSTR-2B row' || case when v_ok = 1 then '' else 's' end
               || ' loaded for ' || to_char(v_period,'FMMonth YYYY')
               || case when v_bad > 0 then '  ·  ' || v_bad || ' line(s) skipped' else '' end);
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_inv_key(p_no text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select nullif(upper(regexp_replace(coalesce(p_no,''), '[^A-Za-z0-9]', '', 'g')), '');
$function$
;

CREATE OR REPLACE FUNCTION public.gst_ledger_build_input(p_from date, p_to date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seller text; v_n int;
begin
  select seller_gstin into v_seller from public.billing_config where id = 1;

  with src as (
    select
      b.id                                              as line_id,
      pb.id                                             as bill_id,
      pb.supplier_id                                    as supplier_id,
      coalesce(sp.supplier_name, pb.supplier_name, b.supplier_name) as supplier_nm,
      public.gst_norm_gstin(coalesce(sp.gstin, sp.gst)) as supplier_gstin,
      nullif(btrim(coalesce(pb.scan_result->>'invoice_no','')),'')   as inv_no,
      nullif(btrim(coalesce(pb.scan_result->>'invoice_date','')),'') as inv_dt_text,
      public.gst_parse_date(pb.scan_result->>'invoice_date',
        (coalesce(pb.received_at, pb.created_at) at time zone 'Asia/Kolkata')::date) as inv_dt,
      b.hsn, coalesce(m.product_name, b.raw_name) as product_nm,
      coalesce(b.qty,0) as qty,
      round(coalesce(b.qty,0) * coalesce(b.ptr,0), 2) as gross,
      coalesce(b.disc_pct,0) as disc_pct,
      coalesce(b.gst_pct,0)  as rate
    from public.bill_lines b
    join public.pending_bills pb on pb.id = b.pending_bill_id
    left join public.supplier_profiles sp on sp.id::text = pb.supplier_id
    left join public."MEDICINE" m on m.id = b.product_id
    where pb.status = 'imported'
      and coalesce(b.qty,0) > 0
      and coalesce(b.ptr,0) > 0
      and b.gst_pct is not null
  ), calc as (
    select s.*, s.gross - round(s.gross * s.disc_pct / 100.0, 2) as taxable from src s
  ), split as (
    select c.*, public.gst_split(c.taxable, c.rate, v_seller, c.supplier_gstin) as sp
      from calc c where c.inv_dt >= p_from and c.inv_dt < p_to
  )
  insert into public.gst_ledger (
    direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_date, invoice_date_text,
    counterparty_id, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, taxable, rate,
    cgst, sgst, igst, is_interstate, gstin_missing, place_of_supply)
  select
    'input', 'supplier_bill', s.bill_id, s.line_id::text, date_trunc('month', s.inv_dt)::date,
    s.inv_no, s.inv_dt, s.inv_dt_text,
    s.supplier_id, s.supplier_nm, s.supplier_gstin,
    coalesce(nullif(btrim(coalesce(s.hsn,'')),''), (select default_hsn from public.billing_config where id=1), '3004'),
    s.product_nm, s.qty, s.taxable, s.rate,
    (s.sp->>'cgst')::numeric, (s.sp->>'sgst')::numeric, (s.sp->>'igst')::numeric,
    (s.sp->>'is_interstate')::boolean, (s.sp->>'gstin_missing')::boolean, s.sp->>'place_of_supply'
  from split s
  on conflict (direction, source, source_id, line_ref) do update set
    tax_period = excluded.tax_period, invoice_no = excluded.invoice_no,
    invoice_date = excluded.invoice_date, invoice_date_text = excluded.invoice_date_text,
    counterparty_id = excluded.counterparty_id, counterparty_name = excluded.counterparty_name,
    counterparty_gstin = excluded.counterparty_gstin, hsn = excluded.hsn,
    product_name = excluded.product_name, qty = excluded.qty,
    taxable = excluded.taxable, rate = excluded.rate,
    cgst = excluded.cgst, sgst = excluded.sgst, igst = excluded.igst,
    is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
    place_of_supply = excluded.place_of_supply, built_at = now();

  get diagnostics v_n = row_count;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_ledger_build_output(p_from date, p_to date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seller text; v_prefix text; v_n int;
begin
  select seller_gstin, coalesce(invoice_prefix,'MB')
    into v_seller, v_prefix from public.billing_config where id = 1;

  with elig as (
    select o.id, o.order_code, o.user_id,
           coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) as inv_dt,
           o.delivery_charge, o.delivery_charge_gst, o.delivery_charge_waived,
           o.delivery_charge_at, o.delivery_charge_label
      from public.orders o
     where exists (select 1 from public.bill_line_allocations a
                     join public.bill_lines b on b.id = a.bill_line_id
                    where a.order_id = o.id and b.verified)
       and not exists (
             select 1 from public.order_items oi
              where oi.order_id = o.id
                and oi.fulfillment_state not in ('shipped','cancelled')
                and coalesce(oi.unfulfillable,false) = false
                and not exists (select 1 from public.bill_line_allocations a2
                                  join public.bill_lines b2 on b2.id = a2.bill_line_id
                                 where a2.order_item_id = oi.id
                                   and b2.verified and b2.needs_fix is null))
  ), scoped as (
    select * from elig where inv_dt >= p_from and inv_dt < p_to
  ), buyer as (
    select s.*,
           coalesce(ph.pharmacy_name, o.pharmacy_name) as buyer_nm,
           public.gst_norm_gstin(coalesce(ph.gstin, ph.gst_no)) as buyer_gstin,
           ph.user_id::text as buyer_id
      from scoped s
      join public.orders o on o.id = s.id
      left join lateral (select * from public.pharmacy_profiles p
                          where p.user_id = s.user_id limit 1) ph on true
  ), tot as (
    select b.id, coalesce(sum(a.qty * bl.ptr), 0) as ptr_total
      from buyer b
      join public.bill_line_allocations a on a.order_id = b.id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
     group by b.id
  ), pct as (
    select t.id, public.ptr_discount_pct(t.ptr_total) as pct from tot t
  ), goods as (
    select b.id as order_id, b.order_code, b.inv_dt, b.buyer_nm, b.buyer_gstin, b.buyer_id,
           a.id::text as line_ref,
           coalesce(nullif(btrim(coalesce(bl.hsn,'')),''),
                    (select default_hsn from public.billing_config where id=1), '3004') as hsn,
           coalesce(m.product_name, bl.raw_name) as product_nm,
           a.qty,
           coalesce(bl.gst_pct,0) as rate,
           round(a.qty * bl.ptr, 2)
             - round(round(a.qty * bl.ptr, 2) * p.pct / 100.0, 2) as taxable
      from buyer b
      join public.bill_line_allocations a on a.order_id = b.id
      join public.bill_lines bl on bl.id = a.bill_line_id and bl.verified
      join pct p on p.id = b.id
      left join public."MEDICINE" m on m.id = bl.product_id
  ), delivery as (
    -- Only a FROZEN, non-waived charge is a taxable outward supply. The rate is
    -- read back off the frozen pair, never assumed.
    select b.id as order_id, b.order_code, b.inv_dt, b.buyer_nm, b.buyer_gstin, b.buyer_id,
           'delivery'::text as line_ref,
           coalesce(nullif(public._c('gst.delivery_hsn'),''),'9968') as hsn,
           coalesce(nullif(b.delivery_charge_label,''), nullif(public._c('gst.delivery_label'),''), 'Delivery charge') as product_nm,
           1::numeric as qty,
           round(coalesce(b.delivery_charge_gst,0) * 100.0 / nullif(b.delivery_charge,0), 2) as rate,
           coalesce(b.delivery_charge,0) as taxable
      from buyer b
     where b.delivery_charge_at is not null
       and coalesce(b.delivery_charge_waived,true) = false
       and coalesce(b.delivery_charge,0) > 0
  ), all_lines as (
    select * from goods union all select * from delivery
  ), split as (
    select l.*, public.gst_split(l.taxable, l.rate, v_seller, l.buyer_gstin) as sp
      from all_lines l
  )
  insert into public.gst_ledger (
    direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_date, invoice_date_text,
    counterparty_id, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, taxable, rate,
    cgst, sgst, igst, is_interstate, gstin_missing, place_of_supply,
    order_id, order_code)
  select
    'output', 'customer_bill', s.order_id, s.line_ref, date_trunc('month', s.inv_dt)::date,
    v_prefix || '-' || coalesce(s.order_code,''), s.inv_dt,
    to_char(s.inv_dt,'DD/MM/YYYY'),
    s.buyer_id, s.buyer_nm, s.buyer_gstin,
    s.hsn, s.product_nm, s.qty, s.taxable, s.rate,
    (s.sp->>'cgst')::numeric, (s.sp->>'sgst')::numeric, (s.sp->>'igst')::numeric,
    (s.sp->>'is_interstate')::boolean, (s.sp->>'gstin_missing')::boolean, s.sp->>'place_of_supply',
    s.order_id, s.order_code
  from split s
  on conflict (direction, source, source_id, line_ref) do update set
    tax_period = excluded.tax_period, invoice_no = excluded.invoice_no,
    invoice_date = excluded.invoice_date, invoice_date_text = excluded.invoice_date_text,
    counterparty_id = excluded.counterparty_id, counterparty_name = excluded.counterparty_name,
    counterparty_gstin = excluded.counterparty_gstin, hsn = excluded.hsn,
    product_name = excluded.product_name, qty = excluded.qty,
    taxable = excluded.taxable, rate = excluded.rate,
    cgst = excluded.cgst, sgst = excluded.sgst, igst = excluded.igst,
    is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
    place_of_supply = excluded.place_of_supply,
    order_id = excluded.order_id, order_code = excluded.order_code, built_at = now();

  get diagnostics v_n = row_count;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_ledger_rebuild(p_months integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_started timestamptz := now();
  v_from date := (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
                  - make_interval(months => greatest(coalesce(p_months,24),1) - 1))::date;
  v_to   date := (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
                  + interval '1 month')::date;
  v_in int; v_out int; v_stale int;
begin
  perform public._gst_assert_admin();

  v_in  := public.gst_ledger_build_input(v_from, v_to);
  v_out := public.gst_ledger_build_output(v_from, v_to);

  delete from public.gst_ledger g
   where g.tax_period >= v_from and g.tax_period < v_to
     and g.built_at < v_started;
  get diagnostics v_stale = row_count;

  return jsonb_build_object(
    'ok', true,
    'from', v_from, 'to', v_to,
    'input_rows', v_in, 'output_rows', v_out, 'removed_rows', v_stale,
    'message', public._c('gst.rebuilt'));
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_norm_gstin(p_gstin text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
           when p_gstin is null then null
           when upper(regexp_replace(p_gstin, '[^A-Za-z0-9]', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]{3}$'
             then upper(regexp_replace(p_gstin, '[^A-Za-z0-9]', '', 'g'))
           else null
         end;
$function$
;

CREATE OR REPLACE FUNCTION public.gst_parse_date(p_text text, p_fallback date)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare t text := btrim(coalesce(p_text,'')); m text;
begin
  if t = '' then return p_fallback; end if;
  begin
    m := substring(t from '^\d{4}-\d{2}-\d{2}');
    if m is not null then return to_date(m,'YYYY-MM-DD'); end if;

    m := substring(t from '^\d{1,2}[/-]\d{1,2}[/-]\d{4}');
    if m is not null then return to_date(replace(m,'-','/'),'DD/MM/YYYY'); end if;

    m := substring(t from '^\d{1,2}[/-]\d{1,2}[/-]\d{2}$');
    if m is not null then return to_date(replace(m,'-','/'),'DD/MM/YY'); end if;

    m := substring(t from '^\d{1,2}[ -][A-Za-z]{3}[A-Za-z]*[ -]\d{4}$');
    if m is not null then return to_date(regexp_replace(m,'[ -]','-','g'),'DD-Mon-YYYY'); end if;
  exception when others then
    return p_fallback;
  end;
  return p_fallback;
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_split(p_taxable numeric, p_rate numeric, p_seller_gstin text, p_other_gstin text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_total numeric := round(coalesce(p_taxable,0) * coalesce(p_rate,0) / 100.0, 2);
  v_s text := public.gst_state_of(p_seller_gstin);
  v_o text := public.gst_state_of(p_other_gstin);
  v_inter boolean; v_cgst numeric := 0; v_sgst numeric := 0; v_igst numeric := 0;
begin
  v_inter := (v_s is not null and v_o is not null and v_s <> v_o);
  if v_inter then v_igst := v_total;
  else v_cgst := round(v_total / 2.0, 2); v_sgst := v_total - v_cgst; end if;
  return jsonb_build_object(
    'total_tax', v_total, 'cgst', v_cgst, 'sgst', v_sgst, 'igst', v_igst,
    'is_interstate', v_inter, 'gstin_missing', (v_o is null),
    'place_of_supply', coalesce(nullif(public.gst_state_label(p_other_gstin),''),
                                nullif(public.gst_state_label(p_seller_gstin),''), ''));
end $function$
;

CREATE OR REPLACE FUNCTION public.gst_state_label(p_gstin text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select coalesce(
    (select s.name || ' (' || s.code || ')'
       from public.gst_state_code s
      where s.code = public.gst_state_of(p_gstin)),
    '');
$function$
;

CREATE OR REPLACE FUNCTION public.gst_state_of(p_gstin text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select left(public.gst_norm_gstin(p_gstin), 2);
$function$
;

