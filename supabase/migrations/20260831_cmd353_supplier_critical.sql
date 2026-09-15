-- CHANGE #353 — SUPPLIER surface: the 5 approved critical feature_gaps rows.
--   #24 login              — any signed-in user could seize a supplier account by email
--   #25 payment received   — sup_order_bill_panel leaked supplier financials to anon
--   #34 receive inquiry    — the no-response timeout had never fired once
--   #29 receive the order  — the supplier PO was priced entirely at MRP   ┐ one root
--   #59 respond w/ availability — the supplier could never quote a price  ┘ cause
-- Every statement is idempotent: a resumed worker re-applies this file safely.

-- ─────────────────────────────────────────────────────────────────────────────
-- #24  The takeover: claim_supplier_profile() matched on the CALLER-SUPPLIED
--      email with no proof the caller owns it, then wrote user_id = auth.uid().
--      11 approved profiles with a real email and a NULL user_id were takeover-
--      able. The fallback is deleted: identity is now ONLY my_identity_keys()
--      (login_identities), which is what branch 1 already did. p_email is kept
--      in the signature (the RPC surface is baselined) but is honoured only
--      when it IS one of the caller's own verified identities.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.claim_supplier_profile(p_email text default null::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row supplier_profiles%rowtype;
  v_uid uuid := auth.uid();
  v_keys text[] := public.my_identity_keys();
begin
  -- An unauthenticated caller has no identity to claim with.
  if v_uid is null then
    return jsonb_build_object('status','not_found');
  end if;

  -- 1. identity-based match (email OR phone login, approved or pending)
  select sp.* into v_row
  from supplier_profiles sp
  join login_identities li
    on li.owner_type = 'supplier' and li.owner_id = sp.id::text
  where li.identity = any (v_keys)
    and coalesce(sp.is_deleted,false) = false
  order by sp.id
  limit 1;

  -- 2. the passed email is accepted ONLY when it is one of MY OWN identities.
  --    Matching a stranger's email here is what made every unlinked approved
  --    supplier profile claimable by any signed-in user (#24).
  if not found
     and p_email is not null and btrim(p_email) <> ''
     and public.identity_norm(p_email) = any (v_keys) then
    select sp.* into v_row
    from supplier_profiles sp
    where lower(btrim(sp.email)) = lower(btrim(p_email))
      and coalesce(sp.is_deleted,false) = false
    limit 1;
  end if;

  if not found then
    return jsonb_build_object('status','not_found');
  end if;

  if v_row.approved is not true then
    return jsonb_build_object('status','pending_approval',
                              'supplier_name', coalesce(v_row.supplier_name,''));
  end if;

  if v_row.user_id is not null and v_row.user_id <> v_uid then
    return jsonb_build_object('status','conflict');
  end if;

  if v_row.user_id is null then
    update supplier_profiles set user_id = v_uid where id = v_row.id;
    v_row.user_id := v_uid;
  end if;

  return jsonb_build_object(
    'status',       'ok',
    'id',            v_row.id::text,
    'supplier_name', coalesce(v_row.supplier_name,''),
    'email',         coalesce(v_row.email,'')
  );
end $function$;

revoke execute on function public.claim_supplier_profile(text) from public, anon;
grant  execute on function public.claim_supplier_profile(text) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- #25  sup_order_bill_panel(uuid) is SECURITY DEFINER, was granted to anon and
--      checked NOTHING: any caller holding the anon key that ships in the web
--      bundle could read a supplier's UPI address, every UTR/txn/payee/
--      screenshot path, every bill file path and the money totals. Guarded with
--      the same rule supplier_my_orders() uses, and anon is revoked. The refusal
--      is a rendered payload (backend copy), never an exception.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sup_order_bill_panel(p_supplier_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare so record; v_sid uuid; v_pa text; v_mrp numeric := 0; v_paid numeric := 0;
        v_adv_paid numeric := 0; v_bill_total numeric := 0; v_any_imported boolean := false;
        v_adj_total numeric := 0; v_adjustments jsonb := '[]'::jsonb; v jsonb;
        v_order_date date; v_role text; v_me text; v_pay numeric := 0;
begin
  select id, supplier_id, supplier_name, order_code, created_at, items,
         coalesce(total_amount,0) total_amount
    into so from supplier_orders where id = p_supplier_order_id;
  if not found then return jsonb_build_object('found', false); end if;

  -- OWNERSHIP GATE (#25). Platform staff, or the supplier this PO belongs to.
  v_role := public.get_my_role();
  if v_role not in ('super_admin','admin') then
    select sp.supplier_name into v_me from public.current_supplier_profile() sp;
    if v_me is null or lower(btrim(v_me)) is distinct from lower(btrim(so.supplier_name)) then
      return jsonb_build_object(
        'found', false,
        'error', 'forbidden',
        'message', public.uic('sup_order_bill_panel.forbidden','This bill panel belongs to another supplier.'));
    end if;
  end if;

  v_order_date := (so.created_at AT TIME ZONE 'Asia/Kolkata')::date;

  v_sid := coalesce(so.supplier_id,
             (select id from supplier_profiles where lower(supplier_name)=lower(so.supplier_name) limit 1));
  select payment_address into v_pa from supplier_profiles where id = v_sid;

  select coalesce(sum(coalesce(
           nullif(regexp_replace(coalesce(it->>'mrp',''),'[^0-9.]','','g'),'')::numeric,
           (select nullif(regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g'),'')::numeric
              from "MEDICINE" m where m.id = nullif(it->>'product_id','')::bigint)
         ,0) * coalesce(nullif(it->>'quantity','')::numeric,1)),0)
    into v_mrp
  from jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it;

  -- #29: the advance is a share of what is PAYABLE (trade rate where the
  -- supplier has quoted one), not of the MRP ceiling. total_amount is written
  -- by po_retotal() and falls back to the MRP figure only while a line is
  -- still unquoted.
  v_pay := case when so.total_amount > 0 then so.total_amount else v_mrp end;

  select coalesce(sum(amount),0), coalesce(sum(amount) filter (where kind='advance'),0)
    into v_paid, v_adv_paid from supplier_payments where supplier_order_id = so.id;

  select coalesce(sum(d.adj_amount),0),
         coalesce(jsonb_agg(jsonb_build_object(
             'dispute_id', d.id, 'dispute_code', d.dispute_code, 'product_name', d.product_name,
             'qty', d.adj_qty, 'rate', d.adj_rate, 'amount', d.adj_amount,
             'label', '+'||coalesce(d.adj_qty,0)||' units @ '||coalesce(d.adj_rate,0)||' (excess kept)',
             'at', d.resolved_at) order by d.resolved_at desc), '[]'::jsonb)
    into v_adj_total, v_adjustments
  from supplier_disputes d
  where d.adj_supplier_order_id = so.id and d.resolution_outcome = 'excess_kept'
    and coalesce(d.adj_amount,0) > 0;

  with bl as (
    select id, file_path, file_name, coalesce(bucket, case when file_path like 'whatsapp/%' then 'whatsapp-media' else 'supplier-bills' end) bucket,
           source, received_at, scan_status, scan_result,
           (imported_at is not null or lower(coalesce(status,''))='imported') as imported
    from pending_bills
    where ((v_sid is not null and supplier_id = v_sid::text)
       or (supplier_id is null and supplier_name is not null and lower(supplier_name)=lower(so.supplier_name)))
      and lower(coalesce(verdict,'')) <> 'fake'
      -- STRICT DATE MATCH (locked with Om 23 Jul): bill's received date (IST) must equal
      -- the supplier order's created date (IST). Prevents an old bill from a prior day
      -- leaking onto a fresh same-supplier order.
      and (received_at AT TIME ZONE 'Asia/Kolkata')::date = v_order_date
  ),
  nb as (select row_number() over (order by received_at asc) bill_no, * from bl)
  select coalesce(sum(nullif(regexp_replace(coalesce(scan_result->>'total',''),'[^0-9.]','','g'),'')::numeric) filter (where imported),0),
         coalesce(bool_or(imported), false),
         jsonb_build_object(
           'found', true,
           'supplier_order_id', so.id,
           'order_code', so.order_code,
           'supplier_name', so.supplier_name,
           'payment_address', v_pa,
           'bills_total',    count(*),
           'bills_imported', count(*) filter (where imported),
           'bills_left',     count(*) filter (where not imported),
           'bills', coalesce(jsonb_agg(jsonb_build_object(
               'bill_no', bill_no, 'id', id, 'bucket', bucket, 'file_path', file_path, 'file_name', file_name,
               'source', source, 'received_at', received_at, 'imported', imported, 'scan_status', scan_status,
               'bill_amount', nullif(regexp_replace(coalesce(scan_result->>'total',''),'[^0-9.]','','g'),'')::numeric
             ) order by bill_no) filter (where id is not null), '[]'::jsonb))
    into v_bill_total, v_any_imported, v
  from nb;

  v := coalesce(v, jsonb_build_object('found', true, 'supplier_order_id', so.id, 'order_code', so.order_code,
        'supplier_name', so.supplier_name, 'payment_address', v_pa,
        'bills_total',0,'bills_imported',0,'bills_left',0,'bills','[]'::jsonb));

  v := v || jsonb_build_object(
    'mrp_total',        round(v_mrp,2),
    'payable_total',    round(v_pay,2),
    'pricing',          public.po_pricing_block(so.id),
    'total_paid',       round(v_paid,2),
    'advance_required', round(v_pay*0.30,0),
    'advance_paid',     round(v_adv_paid,2),
    'any_bill_imported', v_any_imported,
    'bills_amount_total', round(v_bill_total,2),
    'adjustments',       v_adjustments,
    'adjustments_total', round(v_adj_total,2),
    'remaining_due', case when v_any_imported then round(greatest(v_bill_total + v_adj_total - v_paid, 0),2) else null end,
    'payments', coalesce((select jsonb_agg(jsonb_build_object(
        'id',id,'kind',kind,'amount',amount,'mode',mode,'note',note,'at',created_at,
        'payee_name',payee_name,'payee_vpa',payee_vpa,'utr',utr,'txn_id',txn_id,'app',app,'paid_at',paid_at,
        'screenshot_path',screenshot_path,'screenshot_bucket',screenshot_bucket
      ) order by created_at desc) from supplier_payments where supplier_order_id = so.id), '[]'::jsonb));
  return v;
end; $function$;

-- anon inherits the default PUBLIC grant, so revoke from PUBLIC too (#305).
revoke execute on function public.sup_order_bill_panel(uuid) from public, anon;
grant  execute on function public.sup_order_bill_panel(uuid) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- #59 + #29  ONE ROOT CAUSE. A supplier could only ever answer with one of three
--      availability strings — there was no rate field anywhere in the answer
--      path (#59) — so the purchase order had nothing to price with and fell
--      back to MRP * qty (#29). legal_get_page('about'): MRP is the legal
--      ceiling and a display field, NEVER the selling price.
--      The quote is now captured per (supplier, product, batch date) and is the
--      source of the PO line price. MRP stays on the line as a display-only
--      reference and is used ONLY as a clearly-flagged provisional figure while
--      a line is still unquoted, so no live PO total is silently zeroed.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.supplier_quote (
  id            bigserial primary key,
  inquiry_id    bigint,
  supplier_name text        not null,
  product_id    bigint      not null,
  batch_date    date,
  rate          numeric(12,2) not null,
  scheme        text,
  source        text        not null default 'supplier_form',
  quoted_at     timestamptz not null default now(),
  constraint supplier_quote_rate_positive check (rate > 0)
);
create unique index if not exists supplier_quote_uniq
  on public.supplier_quote (supplier_name, product_id, coalesce(batch_date, '1900-01-01'::date));
create index if not exists supplier_quote_product_idx on public.supplier_quote (product_id, quoted_at desc);

alter table public.supplier_quote enable row level security;
-- Deny-all to clients on purpose: every write goes through submit_inquiry_form
-- (SECURITY DEFINER) and every read through a definer RPC.
revoke all on table public.supplier_quote from public, anon, authenticated;

-- The rate a supplier is charging for one product on one batch date:
-- their own quote for that date -> their most recent quote -> the catalog trade
-- rate (medicine_pricing.ptr) -> nothing. MRP is deliberately NOT in this chain.
create or replace function public.supplier_rate_for(p_supplier text, p_product_id bigint, p_date date default null)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    (select q.rate from supplier_quote q
      where lower(btrim(q.supplier_name)) = lower(btrim(p_supplier))
        and q.product_id = p_product_id
        and (p_date is null or q.batch_date = p_date)
      order by q.quoted_at desc limit 1),
    (select q.rate from supplier_quote q
      where lower(btrim(q.supplier_name)) = lower(btrim(p_supplier))
        and q.product_id = p_product_id
      order by q.quoted_at desc limit 1),
    (select mp.ptr from medicine_pricing mp where mp.product_id = p_product_id and mp.ptr > 0 limit 1)
  );
$function$;

alter table public.supplier_orders add column if not exists trade_total   numeric;
alter table public.supplier_orders add column if not exists mrp_total     numeric;
alter table public.supplier_orders add column if not exists rate_pending  integer;
alter table public.supplier_orders add column if not exists pricing_basis text;

-- The ONE place a supplier PO is priced. Every writer (the inquiry trigger, the
-- commit path and the day rebuild) calls this after it writes items[], so the
-- pricing rule can never drift between them.
create or replace function public.po_retotal(p_oid uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  so record; v_items jsonb; v_new jsonb := '[]'::jsonb; it jsonb;
  v_qty numeric; v_mrp numeric; v_rate numeric; v_src text; v_eff numeric;
  v_trade numeric := 0; v_mrpt numeric := 0; v_pay numeric := 0; v_pending int := 0;
  v_basis text; v_pid bigint;
begin
  select id, supplier_name, order_date, coalesce(items,'[]'::jsonb) items
    into so from supplier_orders where id = p_oid;
  if not found then return jsonb_build_object('ok', false); end if;

  for it in select * from jsonb_array_elements(so.items) loop
    v_pid := nullif(it->>'product_id','')::bigint;
    v_qty := coalesce(nullif(regexp_replace(coalesce(it->>'quantity',''),'[^0-9.]','','g'),'')::numeric, 0);
    v_mrp := coalesce(
               nullif(regexp_replace(coalesce(it->>'mrp',''),'[^0-9.]','','g'),'')::numeric,
               (select nullif(regexp_replace(coalesce(m.mrp,''),'[^0-9.]','','g'),'')::numeric
                  from "MEDICINE" m where m.id = v_pid), 0);
    v_rate := case when v_pid is null then null
                   else public.supplier_rate_for(so.supplier_name, v_pid, so.order_date) end;
    if v_rate is not null and v_rate > 0 then
      v_src := case when exists (select 1 from supplier_quote q
                                  where lower(btrim(q.supplier_name)) = lower(btrim(so.supplier_name))
                                    and q.product_id = v_pid)
                    then 'quote' else 'catalog' end;
      v_eff := v_rate;
      v_trade := v_trade + v_qty * v_rate;
    else
      v_src := 'pending';
      v_eff := v_mrp;                    -- provisional ONLY, and flagged as such
      v_pending := v_pending + 1;
    end if;

    v_mrpt := v_mrpt + v_qty * v_mrp;
    v_pay  := v_pay  + v_qty * v_eff;

    v_new := v_new || jsonb_build_array(
      it
      || jsonb_build_object(
           'rate',               v_rate,
           'rate_source',        v_src,
           'rate_display',       case when v_rate is not null then public.inr_money(v_rate)
                                      else public.uic('supplier_po.rate_pending_dash','—') end,
           'line_total',         round(v_qty * v_eff, 2),
           'line_total_display', public.inr_money(round(v_qty * v_eff, 2)),
           'mrp_display',        public.inr_money(v_mrp),
           'price_basis_label',  case v_src
                                   when 'quote'   then public.uic('supplier_po.basis_line_quote','Supplier rate')
                                   when 'catalog' then public.uic('supplier_po.basis_line_catalog','Catalog trade rate')
                                   else public.uic('supplier_po.basis_line_pending','Rate pending — shown at MRP')
                                 end));
  end loop;

  v_basis := case when jsonb_array_length(v_new) = 0 then 'empty'
                  when v_pending = 0 then 'quote'
                  when v_trade > 0 then 'mixed'
                  else 'mrp_provisional' end;

  update supplier_orders
     set items         = v_new,
         total_amount  = round(v_pay, 2),
         trade_total   = round(v_trade, 2),
         mrp_total     = round(v_mrpt, 2),
         rate_pending  = v_pending,
         pricing_basis = v_basis
   where id = p_oid;

  return jsonb_build_object('ok', true, 'basis', v_basis, 'payable', round(v_pay,2),
                            'trade_total', round(v_trade,2), 'mrp_total', round(v_mrpt,2),
                            'rate_pending', v_pending);
end $function$;

-- The rendered pricing block every PO reader prints verbatim.
create or replace function public.po_pricing_block(p_oid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare so record; v_basis text; v_label text; v_tone text;
begin
  select coalesce(pricing_basis,'mrp_provisional') basis, coalesce(rate_pending,0) pending,
         coalesce(trade_total,0) trade, coalesce(mrp_total,0) mrpt, coalesce(total_amount,0) pay
    into so from supplier_orders where id = p_oid;
  if not found then return jsonb_build_object('has', false); end if;

  v_basis := so.basis;
  v_label := case v_basis
               when 'quote' then public.uic('supplier_po.basis_quote','Priced at the supplier''s quoted rate')
               when 'mixed' then public.uic('supplier_po.basis_mixed','Some lines are still awaiting a supplier rate')
               when 'empty' then public.uic('supplier_po.basis_empty','No lines on this order yet')
               else public.uic('supplier_po.basis_mrp','Rates pending — totals are provisional at MRP')
             end;
  v_tone := case v_basis when 'quote' then 'success' when 'mixed' then 'warning'
                         when 'empty' then 'info' else 'warning' end;

  return jsonb_build_object(
    'has',                true,
    'basis',              v_basis,
    'label',              v_label,
    'tone',               v_tone,
    'rate_pending',       so.pending,
    'payable_total',      round(so.pay,2),
    'payable_display',    public.inr_money(round(so.pay,2)),
    'trade_total',        round(so.trade,2),
    'trade_display',      public.inr_money(round(so.trade,2)),
    'mrp_total',          round(so.mrpt,2),
    'mrp_display',        public.inr_money(round(so.mrpt,2)),
    'mrp_note',           public.uic('supplier_po.mrp_note','MRP is the printed ceiling — reference only, never the trade price'),
    'payable_label',      public.uic('supplier_po.payable_label','Payable'),
    'rate_column_label',  public.uic('supplier_po.rate_column','Rate'),
    'mrp_column_label',   public.uic('supplier_po.mrp_column','MRP'));
end $function$;

insert into public.ui_copy (key, value) values
  ('sup_order_bill_panel.forbidden', to_jsonb('This bill panel belongs to another supplier.'::text)),
  ('supplier_po.basis_quote',        to_jsonb('Priced at the supplier''s quoted rate'::text)),
  ('supplier_po.basis_mixed',        to_jsonb('Some lines are still awaiting a supplier rate'::text)),
  ('supplier_po.basis_mrp',          to_jsonb('Rates pending — totals are provisional at MRP'::text)),
  ('supplier_po.basis_empty',        to_jsonb('No lines on this order yet'::text)),
  ('supplier_po.basis_line_quote',   to_jsonb('Supplier rate'::text)),
  ('supplier_po.basis_line_catalog', to_jsonb('Catalog trade rate'::text)),
  ('supplier_po.basis_line_pending', to_jsonb('Rate pending — shown at MRP'::text)),
  ('supplier_po.rate_pending_dash',  to_jsonb('—'::text)),
  ('supplier_po.mrp_note',           to_jsonb('MRP is the printed ceiling — reference only, never the trade price'::text)),
  ('supplier_po.payable_label',      to_jsonb('Payable'::text)),
  ('supplier_po.rate_column',        to_jsonb('Rate'::text)),
  ('supplier_po.mrp_column',         to_jsonb('MRP'::text)),
  ('inquiry_rate.label',             to_jsonb('Your rate per unit'::text)),
  ('inquiry_rate.hint',              to_jsonb('Trade rate you will bill at (excl. GST)'::text)),
  ('inquiry_rate.prefix',            to_jsonb('₹'::text)),
  ('inquiry_rate.mrp_caption',       to_jsonb('MRP is reference only'::text)),
  ('inquiry_rate.error_required',    to_jsonb('Enter your rate for the items you marked Available'::text)),
  ('inquiry_rate.error_invalid',     to_jsonb('Rate must be a number greater than zero'::text))
on conflict (key) do nothing;

-- The three PO writers now delegate pricing to po_retotal() ────────────────────
create or replace function public._po_merge_inquiry_lines(p_oid uuid, p_ids bigint[])
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_items jsonb; v_add jsonb;
BEGIN
  IF p_oid IS NULL OR p_ids IS NULL OR array_length(p_ids,1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(so.items, '[]'::jsonb) INTO v_items
    FROM supplier_orders so WHERE so.id = p_oid FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  -- Only ADD products the PO does not already list. An existing line is left
  -- exactly as sent — a quantity already quoted to a supplier is not rewritten.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id',   i.product_id,
           'product_name', i.product_name,
           'quantity',     i.quantity,
           'mrp',          i.mrp,
           'pack_type',    NULLIF(btrim(med.pack_type),''))), '[]'::jsonb)
    INTO v_add
    FROM (SELECT DISTINCT ON (q.product_id) q.*
            FROM inquiry q WHERE q.id = ANY(p_ids) AND q.product_id IS NOT NULL
           ORDER BY q.product_id, q.id) i
    LEFT JOIN "MEDICINE" med ON med.id = i.product_id
   WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x
                      WHERE (x->>'product_id') = i.product_id::text);

  IF v_add = '[]'::jsonb THEN
    PERFORM public.po_retotal(p_oid);   -- rates may have arrived since
    RETURN;
  END IF;

  UPDATE supplier_orders so SET items = v_items || v_add WHERE so.id = p_oid;
  -- #29: the total is NEVER sum(mrp*qty) any more. po_retotal() prices each
  -- line from the supplier's quote and marks anything still unquoted.
  PERFORM public.po_retotal(p_oid);
END;
$function$;

-- NOTE: kept SECURITY INVOKER with no search_path override, exactly as it was —
-- this is a trigger function and its privilege shape is baselined by rg_check.
create or replace function public.inquiry_to_supplier_orders()
returns trigger
language plpgsql
as $function$
DECLARE s text; d date; v_items jsonb; v_total numeric; v_oid uuid;
BEGIN
  IF pg_trigger_depth() > 1 THEN RETURN COALESCE(NEW, OLD); END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.current_supplier IS NOT DISTINCT FROM OLD.current_supplier
     AND NEW.current_status   IS NOT DISTINCT FROM OLD.current_status THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.current_supplier IS NULL
     AND NEW.current_status   IS NULL
     AND NEW.inquiry_code     IS NULL THEN
    RETURN NEW;
  END IF;

  d := COALESCE(
         public._inq_date(COALESCE(NEW.inquiry_code, OLD.inquiry_code)),
         (now() AT TIME ZONE 'Asia/Kolkata')::date
       );

  FOR s IN SELECT DISTINCT x FROM (VALUES (NEW.current_supplier),(OLD.current_supplier)) v(x)
           WHERE x IS NOT NULL AND btrim(x)<>'' LOOP

    SELECT jsonb_agg(jsonb_build_object('product_id',i.product_id,'product_name',i.product_name,
                                        'quantity',i.quantity,'mrp',i.mrp)),
           COALESCE(SUM(i.quantity*COALESCE(i.mrp,0)),0)
      INTO v_items, v_total
      FROM inquiry i
     WHERE i.current_supplier = s
       AND i.current_status = 'Available'
       AND COALESCE(public._inq_date(i.inquiry_code),
                    (now() AT TIME ZONE 'Asia/Kolkata')::date) = d;

    IF v_items IS NOT NULL THEN
      INSERT INTO supplier_orders (supplier_name, supplier_id, spn, items, total_amount, order_date)
      VALUES (s,
              (SELECT id FROM supplier_profiles WHERE supplier_name=s LIMIT 1),
              (SELECT "SPN" FROM supplier_profiles WHERE supplier_name=s LIMIT 1),
              v_items, v_total, d)
      ON CONFLICT (supplier_name, order_date)
        WHERE (status is null or status <> all (array['shipped','closed','cancelled']))
      DO UPDATE SET items = EXCLUDED.items,
                    total_amount = EXCLUDED.total_amount,
                    supplier_id = EXCLUDED.supplier_id,
                    spn = EXCLUDED.spn
      RETURNING id INTO v_oid;
      -- #29: re-price off the supplier's quote. The MRP sum above is only the
      -- seed the insert needs; po_retotal() decides the money.
      IF v_oid IS NOT NULL THEN PERFORM public.po_retotal(v_oid); END IF;
    ELSE
      DELETE FROM supplier_orders so
       WHERE so.supplier_name = s
         AND so.order_date = d
         AND (so.status is null or so.status <> all (array['shipped','closed','cancelled']));
    END IF;
  END LOOP;

  RETURN COALESCE(NEW, OLD);
END;
$function$;

create or replace function public.rebuild_all_supplier_orders(p_date date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE r record; v_id uuid; v_n int := 0; v_units numeric := 0;
        v_day date := COALESCE(p_date, public.admin_active_date());
        v_stamp timestamptz;
BEGIN
  FOR r IN
    SELECT d.assigned_supplier AS supplier,
           jsonb_agg(jsonb_build_object(
             'product_id', d.product_id, 'product_name', d.product_name,
             'quantity', d.qty, 'mrp', d.mrp, 'pack_type', d.pack_type)
             ORDER BY d.product_name) AS items,
           sum(d.qty * COALESCE(d.mrp,0)) AS total,
           sum(d.qty) AS units
    FROM (
      SELECT oi.assigned_supplier, oi.product_id, oi.product_name,
             sum(oi.quantity) AS qty, max(oi.mrp) AS mrp, max(m.pack_type) AS pack_type
      FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      LEFT JOIN "MEDICINE" m ON m.id = oi.product_id
      WHERE oi.assigned_supplier IS NOT NULL
        AND EXISTS (SELECT 1 FROM inquiry i
                     WHERE i.id = oi.inquiry_id
                       AND public._inq_confirmed(i)
                       AND i.batch_date = oi.order_date
                       AND i.current_supplier = oi.assigned_supplier)
        AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_day
        AND coalesce(o.fulfillment_status,'') NOT IN ('shipped','cancelled')
        AND coalesce(oi.fulfillment_state,'') <> 'cancelled'
      GROUP BY oi.assigned_supplier, oi.product_id, oi.product_name
    ) d
    GROUP BY d.assigned_supplier
  LOOP
    SELECT id INTO v_id FROM supplier_orders
     WHERE supplier_name = r.supplier
       AND order_date = v_day
       AND (status IS NULL OR status NOT IN ('shipped','closed','cancelled'))
     ORDER BY created_at LIMIT 1;

    IF v_id IS NULL THEN
      SELECT COALESCE(min(o.created_at), (v_day::text || ' 09:00')::timestamp AT TIME ZONE 'Asia/Kolkata')
        INTO v_stamp
        FROM order_items oi JOIN orders o ON o.id = oi.order_id
       WHERE oi.assigned_supplier = r.supplier
         AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_day;

      INSERT INTO supplier_orders (supplier_name, supplier_id, spn, items, total_amount, status, order_id, order_date, created_at)
      VALUES (r.supplier,
              (SELECT id FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1),
              (SELECT "SPN" FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1),
              r.items, r.total, 'pending', NULL, v_day, v_stamp)
      RETURNING id INTO v_id;
    ELSE
      UPDATE supplier_orders
         SET items = r.items, total_amount = r.total,
             supplier_id = COALESCE(supplier_id,(SELECT id FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1)),
             spn = COALESCE(spn,(SELECT "SPN" FROM supplier_profiles WHERE supplier_name=r.supplier LIMIT 1))
       WHERE id = v_id;
    END IF;

    PERFORM public.po_retotal(v_id);   -- #29: trade rate, not MRP
    v_n := v_n + 1; v_units := v_units + r.units;
  END LOOP;

  DELETE FROM supplier_orders so
   WHERE so.order_date = v_day
     AND (so.status IS NULL OR so.status NOT IN ('shipped','closed','cancelled'))
     AND NOT EXISTS (
       SELECT 1 FROM order_items oi
       JOIN orders o ON o.id = oi.order_id
       WHERE oi.assigned_supplier = so.supplier_name
         AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_day
         AND coalesce(oi.fulfillment_state,'') <> 'cancelled'
         AND coalesce(o.fulfillment_status,'') <> 'cancelled');

  RETURN jsonb_build_object('ok', true, 'supplier_orders', v_n, 'units', v_units, 'date', v_day);
END;
$function$;

-- The supplier's own PO list carries the rate, its source and the pricing block,
-- all pre-rendered. Flutter prints them; it computes nothing.
-- adds one column (pricing) to the result, so the old signature is dropped first
drop function if exists public.supplier_my_orders(uuid);
create or replace function public.supplier_my_orders(p_supplier_id uuid default null::uuid)
returns table(order_id uuid, order_no integer, created_at timestamp with time zone, status text,
              total_amount numeric, item_count integer, items jsonb, order_code text,
              packed boolean, packed_via text, pack_button jsonb, pricing jsonb)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_name text;
begin
  if p_supplier_id is null then
    select sp.supplier_name into v_name from current_supplier_profile() sp;
  else
    if get_my_role() <> 'super_admin' then RETURN; end if;
    select sp.supplier_name into v_name from supplier_profiles sp where sp.id = p_supplier_id;
  end if;
  if v_name is null then return; end if;

  return query
  select so.id, so.order_no, so.created_at, so.status, so.total_amount,
         coalesce(jsonb_array_length(so.items),0) as item_count,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'product_id',        it->>'product_id',
                    'product_name',      it->>'product_name',
                    'quantity',          (it->>'quantity')::int,
                    'pack_type',         nullif(btrim(med.pack_type),''),
                    'image_url',         nullif(btrim(med.image_url_1),''),
                    'therapeutic_class', nullif(btrim(med.therapeutic_class),''),
                    'company',           nullif(btrim(med.marketer),''),
                    'rate',              it->'rate',
                    'rate_source',       it->>'rate_source',
                    'rate_display',      it->>'rate_display',
                    'mrp_display',       it->>'mrp_display',
                    'line_total',        it->'line_total',
                    'line_total_display', it->>'line_total_display',
                    'price_basis_label', it->>'price_basis_label'
                  ) order by it->>'product_name')
           from jsonb_array_elements(so.items) it
           left join "MEDICINE" med on med.id = (it->>'product_id')::bigint
         ), '[]'::jsonb) as items,
         so.order_code,
         coalesce(so.packed,false) as packed,
         so.packed_via,
         jsonb_build_object(
           'label',       case when coalesce(so.packed,false) then 'Packed ✓' else 'Mark Packed' end,
           'next_packed', not coalesce(so.packed,false),
           'bg',          case when coalesce(so.packed,false) then '#E1F5EE' else '#1B7A43' end,
           'fg',          case when coalesce(so.packed,false) then '#0F6E56' else '#FFFFFF' end
         ) as pack_button,
         public.po_pricing_block(so.id) as pricing
  from supplier_orders so
  where so.supplier_name = v_name
  order by so.created_at desc, so.order_no desc;
end;
$function$;

-- The form's rate-capture contract: label, hint, prefix and every error string
-- come from the backend, so the wording changes with an UPDATE, not a deploy.
create or replace function public.inquiry_rate_capture()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'enabled',        true,
    'required',       coalesce((select (value #>> '{}')::boolean from app_settings where key='inquiry_rate_required'), false),
    'answer',         'Available',
    'label',          public.uic('inquiry_rate.label','Your rate per unit'),
    'hint',           public.uic('inquiry_rate.hint','Trade rate you will bill at (excl. GST)'),
    'prefix',         public.uic('inquiry_rate.prefix','₹'),
    'mrp_caption',    public.uic('inquiry_rate.mrp_caption','MRP is reference only'),
    'error_required', public.uic('inquiry_rate.error_required','Enter your rate for the items you marked Available'),
    'error_invalid',  public.uic('inquiry_rate.error_invalid','Rate must be a number greater than zero'));
$function$;
grant execute on function public.inquiry_rate_capture() to anon, authenticated, service_role;

-- #59: the answer payload now carries the supplier's RATE. Availability alone
-- was never a quote — legal_get_page('about') says line prices are trade/PTR
-- rates from supplier quotes, and there was nowhere to put one.
create or replace function public.submit_inquiry_form(p_token text, p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_supplier text; v_status text; v_expires timestamptz; ans record; r_inq inquiry%ROWTYPE;
  i int; ps_val text; as_val text; slot_n int; new_current text; new_next text; found_ct int;
  v_ps text; v_as text; relevant_ct int; answered_ct int;
  v_remember jsonb := '[]'::jsonb; m jsonb; v_r jsonb;
  v_rate numeric; v_required boolean;
BEGIN
  SELECT f.supplier_name, f.status, f.expires_at INTO v_supplier, v_status, v_expires
  FROM inquiry_forms f WHERE f.token = p_token;
  -- Fallback: accept the public inquiry code too.
  IF NOT FOUND THEN
    v_r := public.resolve_code(p_token);
    IF v_r ? 'token' THEN
      p_token := v_r->>'token';
      SELECT f.supplier_name, f.status, f.expires_at INTO v_supplier, v_status, v_expires
      FROM inquiry_forms f WHERE f.token = p_token;
    END IF;
    IF v_supplier IS NULL THEN RETURN jsonb_build_object('error','invalid'); END IF;
  END IF;
  IF v_status='expired' OR (v_expires IS NOT NULL AND v_expires < now()) THEN
    RETURN jsonb_build_object('error','expired'); END IF;

  v_required := coalesce((select (value #>> '{}')::boolean from app_settings where key='inquiry_rate_required'), false);

  FOR ans IN SELECT * FROM jsonb_to_recordset(p_answers)
                       AS x(inquiry_id bigint, answer text, rate text, scheme text) LOOP
    IF ans.answer NOT IN ('Available','Out of Stock','We don''t stock this product') THEN
      RETURN jsonb_build_object('error','invalid_answer','value',ans.answer); END IF;

    v_rate := nullif(regexp_replace(coalesce(ans.rate,''),'[^0-9.]','','g'),'')::numeric;
    IF ans.answer = 'Available' THEN
      IF v_rate IS NOT NULL AND v_rate <= 0 THEN
        RETURN jsonb_build_object('error','invalid_rate',
                                  'message', public.uic('inquiry_rate.error_invalid','Rate must be a number greater than zero'));
      END IF;
      IF v_rate IS NULL AND v_required THEN
        RETURN jsonb_build_object('error','rate_required',
                                  'message', public.uic('inquiry_rate.error_required','Enter your rate for the items you marked Available'));
      END IF;
    ELSE
      v_rate := NULL;                       -- a rate is meaningless without stock
    END IF;

    SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = ans.inquiry_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    slot_n := NULL; as_val := NULL;
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO ps_val, as_val USING r_inq;
      IF ps_val = v_supplier THEN slot_n := i; EXIT; END IF;
      as_val := NULL;
    END LOOP;

    IF slot_n IS NOT NULL AND as_val IS NULL AND r_inq.current_supplier = v_supplier THEN
      EXECUTE format('UPDATE inquiry SET %I = $1 WHERE inquiry.id = $2','AS'||slot_n)
        USING ans.answer, ans.inquiry_id;

      -- the quote itself — one row per (supplier, product, batch date)
      IF v_rate IS NOT NULL AND r_inq.product_id IS NOT NULL THEN
        INSERT INTO supplier_quote (inquiry_id, supplier_name, product_id, batch_date, rate, scheme, source)
        VALUES (ans.inquiry_id, v_supplier, r_inq.product_id, r_inq.batch_date, round(v_rate,2),
                nullif(btrim(coalesce(ans.scheme,'')),''), 'supplier_form')
        ON CONFLICT (supplier_name, product_id, coalesce(batch_date,'1900-01-01'::date))
        DO UPDATE SET rate = EXCLUDED.rate, scheme = EXCLUDED.scheme,
                      inquiry_id = EXCLUDED.inquiry_id, quoted_at = now();
      END IF;

      v_remember := v_remember || jsonb_build_array(jsonb_build_object(
        'product_id', r_inq.product_id, 'answer', ans.answer));

      SELECT * INTO r_inq FROM inquiry WHERE inquiry.id = ans.inquiry_id;
      new_current := NULL; new_next := NULL; found_ct := 0;
      FOR i IN 1..30 LOOP
        EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO v_ps, v_as USING r_inq;
        IF v_ps IS NULL OR btrim(v_ps)='' THEN EXIT; END IF;
        IF v_as IS NULL OR btrim(v_as)='' OR v_as='Available' THEN
          found_ct := found_ct + 1;
          IF found_ct=1 THEN new_current := v_ps; ELSIF found_ct=2 THEN new_next := v_ps; EXIT; END IF;
        END IF;
      END LOOP;
      UPDATE inquiry SET current_supplier=new_current, next_supplier=new_next,
        asked_at = CASE WHEN new_current IS DISTINCT FROM r_inq.current_supplier
                        THEN now() ELSE inquiry.asked_at END
      WHERE inquiry.id = ans.inquiry_id;

      IF new_current IS NOT NULL AND new_current <> v_supplier THEN
        INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
        VALUES (new_current, now(), now()+interval '10 minutes','pending')
        ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
          last_sent_at=now(), expires_at=now()+interval '10 minutes',
          status=CASE WHEN inquiry_forms.status='expired' THEN 'pending'
                      ELSE inquiry_forms.status END;
      END IF;
    END IF;
  END LOOP;

  SELECT COUNT(*) INTO relevant_ct FROM inquiry WHERE inquiry.current_supplier = v_supplier;
  answered_ct := 0;
  FOR r_inq IN SELECT * FROM inquiry WHERE inquiry.current_supplier = v_supplier LOOP
    FOR i IN 1..30 LOOP
      EXECUTE format('SELECT ($1).%I, ($1).%I','PS'||i,'AS'||i) INTO ps_val, as_val USING r_inq;
      IF ps_val = v_supplier THEN
        IF as_val IS NOT NULL THEN answered_ct := answered_ct+1; END IF; EXIT; END IF;
      as_val := NULL;
    END LOOP;
  END LOOP;
  UPDATE inquiry_forms SET last_responded_at=now(),
    status=CASE WHEN relevant_ct=0 THEN 'responded'
                WHEN answered_ct>=relevant_ct THEN 'responded'
                WHEN answered_ct>0 THEN 'partially_responded'
                ELSE inquiry_forms.status END
  WHERE inquiry_forms.token = p_token;

  PERFORM commit_supplier_order(v_supplier);

  FOR m IN SELECT * FROM jsonb_array_elements(v_remember) LOOP
    PERFORM public.remember_supplier_answer(
      v_supplier, (m->>'product_id')::bigint, m->>'answer');
  END LOOP;

  RETURN get_inquiry_form(p_token);
END;
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- #34  The no-response timeout had NEVER fired: cron_task inquiry_timeout_advance
--      gated on inquiry_phase='sent', and the only function that ever wrote
--      'sent' — send_inquiry_form() — is called by nothing. All 156 inquiry rows
--      sat at 'draft' with asked_at NULL, so a supplier who simply never replied
--      pinned the item on themselves forever.
--      Fix: the real dispatch path stamps the phase, and both the body and the
--      cron gate key off asked_at — the timestamp the dispatch actually writes.
--      Rows that were never dispatched have asked_at NULL and are still never
--      advanced, so nothing historic is swept.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.start_inquiry_for_suppliers(
  p_supplier_names text[] default null::text[], p_force boolean default false)
returns table(supplier_name text, token text, status text, expires_at timestamp with time zone)
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_suppliers text[]; v_sup text; v_token text; v_status text;
  v_expires timestamptz; v_ready jsonb; v_started boolean;
BEGIN
  v_ready := public.inquiry_send_readiness();
  IF NOT (v_ready->>'can_send')::boolean THEN
    IF p_force AND get_my_role() = 'super_admin' THEN NULL;
    ELSE RAISE EXCEPTION 'inquiry_send_blocked' USING HINT = v_ready::text; END IF;
  END IF;

  v_started := public.inquiry_locked();

  IF p_supplier_names IS NULL THEN
    SELECT ARRAY_AGG(DISTINCT sup) INTO v_suppliers
    FROM ( SELECT i.current_supplier AS sup FROM inquiry i WHERE i.current_supplier IS NOT NULL
           UNION
           SELECT i.next_supplier AS sup FROM inquiry i WHERE i.next_supplier IS NOT NULL ) t;
  ELSE
    v_suppliers := p_supplier_names;
  END IF;
  IF v_suppliers IS NULL OR array_length(v_suppliers, 1) = 0 THEN RETURN; END IF;

  FOREACH v_sup IN ARRAY v_suppliers LOOP
    IF v_started THEN
      INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
      VALUES (v_sup, now(), now() + interval '10 minutes', 'pending')
      ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
        last_sent_at = now(), expires_at = now() + interval '10 minutes',
        status = CASE WHEN inquiry_forms.status IN ('expired','draft') THEN 'pending' ELSE inquiry_forms.status END;
      -- #34: stamp the clock AND the phase. inquiry_phase='sent' is what the
      -- timeout task was always waiting for; nothing ever wrote it.
      UPDATE inquiry SET asked_at = COALESCE(asked_at, now()),
                         inquiry_phase = 'sent'
       WHERE (current_supplier = v_sup OR next_supplier = v_sup)
         AND coalesce(inquiry_phase,'draft') IN ('draft','sent');
    ELSE
      INSERT INTO inquiry_forms (supplier_name, last_sent_at, expires_at, status)
      VALUES (v_sup, now(), NULL, 'draft')
      ON CONFLICT ON CONSTRAINT inquiry_forms_supplier_name_key DO UPDATE SET
        last_sent_at = now(), expires_at = NULL,
        status = CASE WHEN inquiry_forms.status IN ('pending','expired') THEN 'draft' ELSE inquiry_forms.status END;
      UPDATE inquiry SET asked_at = NULL,
                         inquiry_phase = 'draft'
       WHERE (current_supplier = v_sup OR next_supplier = v_sup)
         AND coalesce(inquiry_phase,'draft') IN ('draft','sent');
    END IF;

    SELECT f.token, f.status, f.expires_at INTO v_token, v_status, v_expires
    FROM inquiry_forms f WHERE f.supplier_name = v_sup;
    RETURN QUERY SELECT v_sup, v_token, v_status, v_expires;
  END LOOP;
END;
$function$;

create or replace function public.timeout_advance()
returns void
language plpgsql
as $function$
DECLARE rec record;
BEGIN
  -- asked_at is the dispatch stamp: it is written when (and only when) the form
  -- actually goes out, so it — not inquiry_phase — decides whether the 10-minute
  -- clock has started. NULL-safe on current_status: `<> 'Available'` alone drops
  -- every row whose status is NULL.
  FOR rec IN
    SELECT id FROM inquiry
    WHERE current_supplier IS NOT NULL
      AND asked_at IS NOT NULL
      AND asked_at < now() - interval '10 minutes'
      AND coalesce(current_status,'') <> 'Available'
      AND coalesce(inquiry_phase,'draft') IN ('draft','sent')
  LOOP
    PERFORM advance_to_next_supplier(rec.id);
  END LOOP;
END;
$function$;

update public.cron_task
   set gate_sql = $gate$select exists (select 1 from public.inquiry
        where current_supplier is not null
          and asked_at is not null
          and asked_at < now() - interval '10 minutes'
          and coalesce(current_status,'') <> 'Available'
          and coalesce(inquiry_phase,'draft') in ('draft','sent'))$gate$,
       note = 'A supplier NOT answering within 10 minutes is the absence of an event. Gated on asked_at (the dispatch stamp) — CHANGE #353: the old gate wanted inquiry_phase=''sent'', which nothing ever wrote, so the task skipped 17,883 times and never ran once.'
 where name = 'inquiry_timeout_advance';

-- The inquiry engine's own internals are not a client surface. anon inherits the
-- default PUBLIC grant, so revoke from PUBLIC too (#305).
revoke execute on function public.timeout_advance() from public, anon;
revoke execute on function public.send_inquiry_form(bigint[]) from public, anon;

grant execute on function public.supplier_my_orders(uuid) to authenticated, service_role;
grant execute on function public.po_pricing_block(uuid) to authenticated, service_role;
grant execute on function public.po_retotal(uuid) to service_role;
grant execute on function public.supplier_rate_for(text, bigint, date) to authenticated, service_role;
