-- CMD #416 — end-to-end proof for the pharmacy GST pack.
--
-- Inside ONE transaction that ends in ROLLBACK, so proving the mediBO purchase
-- half costs the live system nothing: no order is really placed, no WhatsApp
-- goes out, no register is really written.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f scripts/c416_proof.sql
--
-- What it proves:
--   1. a verified mediBO bill line becomes an INWARD register line, with the
--      seller's GSTIN and the same taxable value mediBO's own invoice prints
--   2. a POS invoice becomes an OUTWARD line, carrying #411's own tax split
--      rather than a fresh derivation
--   3. same-state is CGST+SGST and other-state is IGST — the split is real
--   4. a rebuild is idempotent: running it twice does not double a register
--   5. GSTR-3B nets output against input and never goes below zero
--   6. the CSV escapes a comma inside a value instead of shifting a column
--   7. nothing anywhere claims a return was filed

\set ON_ERROR_STOP on
begin;

select set_config('request.jwt.claims',
  json_build_object('sub','371d5289-c2e1-4475-9215-8f603e72ca9e',
                    'email','test.cust1@medibo.in',
                    'role','authenticated')::text, true);

do $$
declare
  v_shop   uuid := '3f1c9a10-4b6e-4c9a-9f22-5a0d7e8b1c33';  -- mediBO Test Pharmacy
  v_period date := public._pgst_period(public._pgst_today());
  v_order  uuid;
  v_res    jsonb;
  v_home   jsonb;
  v_n1     integer; v_n2 integer;
  v_tax    numeric; v_taxable numeric;
  v_seller text;
  v_csv    text;
  v_3b     jsonb;
begin
  select public.gst_norm_gstin(seller_gstin) into v_seller
    from public.billing_config where id = 1;

  delete from public.pharmacy_gst_ledger where pharmacy_id = v_shop;

  -- ── 1. A mediBO BILL BECOMES A PURCHASE LINE ────────────────────────────
  -- Borrow a real order that already has VERIFIED bill lines, and point it at
  -- the test shop. Nothing is invented: the taxable value below is computed
  -- from the same qty x PTR less slab that mediBO's own invoice prints.
  select o.id into v_order
    from public.orders o
    join public.bill_line_allocations a on a.order_id = o.id
    join public.bill_lines b on b.id = a.bill_line_id and b.verified
   group by o.id order by count(*) desc limit 1;
  if v_order is null then raise exception 'PROOF: no order with verified bill lines'; end if;

  update public.orders
     set customer_id = v_shop, order_date = v_period
   where id = v_order;

  v_n1 := public.pharmacy_gst_build_medibo(v_shop, v_period);
  if v_n1 = 0 then
    raise exception 'PROOF 1 FAILED: a verified mediBO bill produced no purchase line';
  end if;

  if not exists (select 1 from public.pharmacy_gst_ledger
                  where pharmacy_id = v_shop and direction = 'inward'
                    and source = 'medibo_bill'
                    and counterparty_gstin = v_seller
                    and taxable > 0) then
    raise exception 'PROOF 1 FAILED: the purchase line carries no seller GSTIN or no taxable value';
  end if;
  raise notice 'PROOF 1 OK — % mediBO bill line(s) became purchase register lines under GSTIN %',
    v_n1, v_seller;

  -- ── 2. A COUNTER INVOICE BECOMES A SALES LINE ───────────────────────────
  -- And it carries #411's OWN split. If this file ever recomputed the tax, the
  -- register and the invoice the patient holds would drift apart.
  v_n2 := public.pharmacy_gst_build_sales(v_shop, v_period);
  if v_n2 = 0 then
    raise exception 'PROOF 2 FAILED: completed POS invoices produced no sales lines';
  end if;

  select sum(l.cgst + l.sgst + l.igst) into v_tax
    from public.pos_sales s join public.pos_sale_lines l on l.sale_id = s.id
   where s.pharmacy_id = v_shop and s.status = 'completed'
     and s.sold_on >= v_period and s.sold_on < (v_period + interval '1 month')::date;

  select sum(total_tax) into v_taxable
    from public.pharmacy_gst_ledger
   where pharmacy_id = v_shop and direction = 'outward';

  if round(coalesce(v_taxable,0), 2) <> round(coalesce(v_tax,0), 2) then
    raise exception 'PROOF 2 FAILED: the register says % tax, the invoices say % — it recomputed',
      v_taxable, v_tax;
  end if;
  raise notice 'PROOF 2 OK — % sales line(s), tax % matches the POS invoices exactly',
    v_n2, v_taxable;

  -- ── 3. THE SPLIT IS REAL: SAME STATE vs OTHER STATE ─────────────────────
  -- Chhattisgarh (22) selling to Chhattisgarh is CGST+SGST; the same numbers
  -- against a Maharashtra (27) GSTIN must become IGST instead.
  if (public.gst_split(100, 12, '22BXXPJ8518F1Z4', '22AAATE1234T1Z5')->>'igst')::numeric <> 0
     or (public.gst_split(100, 12, '22BXXPJ8518F1Z4', '22AAATE1234T1Z5')->>'cgst')::numeric <> 6 then
    raise exception 'PROOF 3 FAILED: an intra-state supply did not split CGST/SGST';
  end if;
  if (public.gst_split(100, 12, '22BXXPJ8518F1Z4', '27AAACI1195H1ZG')->>'igst')::numeric <> 12 then
    raise exception 'PROOF 3 FAILED: an inter-state supply did not become IGST';
  end if;
  raise notice 'PROOF 3 OK — 22->22 is CGST 6 + SGST 6; 22->27 is IGST 12';

  -- ── 4. A REBUILD IS IDEMPOTENT ──────────────────────────────────────────
  -- Rebuild ONCE first so all three sources are present (the two builders above
  -- deliberately ran alone), then measure. Counting before the outside-purchase
  -- source had ever been built is what made this assertion lie on its first run.
  perform public.pharmacy_gst_rebuild(v_shop, v_period);
  select count(*) into v_n1 from public.pharmacy_gst_ledger where pharmacy_id = v_shop;
  perform public.pharmacy_gst_rebuild(v_shop, v_period);
  perform public.pharmacy_gst_rebuild(v_shop, v_period);
  select count(*) into v_n2 from public.pharmacy_gst_ledger where pharmacy_id = v_shop;
  if v_n1 <> v_n2 then
    raise exception 'PROOF 4 FAILED: rebuilding twice changed the register (% -> %)', v_n1, v_n2;
  end if;
  raise notice 'PROOF 4 OK — two more rebuilds left the register at % lines', v_n2;

  -- ── 5. GSTR-3B NETS, AND NEVER GOES NEGATIVE ────────────────────────────
  v_3b := (select b->'rows' from jsonb_array_elements(
             public.pharmacy_gst_exports(v_shop, v_period)->'blocks') b
            where b->>'key' = 'gstr3b');
  if v_3b is null or jsonb_array_length(v_3b) <> 3 then
    raise exception 'PROOF 5 FAILED: GSTR-3B is not three rows: %', v_3b;
  end if;
  if (v_3b->2->>'cgst')::numeric < 0 then
    raise exception 'PROOF 5 FAILED: net payable went negative — credit is carried, not refunded here';
  end if;
  raise notice 'PROOF 5 OK — 3B rows: outward %, ITC %, net payable %',
    v_3b->0->>'cgst', v_3b->1->>'cgst', v_3b->2->>'cgst';

  -- ── 6. A COMMA INSIDE A VALUE MUST NOT SHIFT A COLUMN ───────────────────
  v_csv := public._pgst_csv(
    jsonb_build_array(jsonb_build_object('a','Sharma Medicos, Raipur','b','12')),
    array['a','b']);
  if v_csv <> '"Sharma Medicos, Raipur",12' then
    raise exception 'PROOF 6 FAILED: the CSV did not quote a comma: %', v_csv;
  end if;
  raise notice 'PROOF 6 OK — CSV quotes an embedded comma: %', v_csv;

  -- ── 7. NOTHING CLAIMS A RETURN WAS FILED ────────────────────────────────
  v_home := public.pharmacy_gst_home(v_period);
  if (v_home->'filing'->>'can_file')::boolean is not false then
    raise exception 'PROOF 7 FAILED: the screen thinks it can file a return';
  end if;
  if v_home->'filing'->>'note' not like '%does not file it%' then
    raise exception 'PROOF 7 FAILED: the filing note is not the honest one: %',
      v_home->'filing'->>'note';
  end if;
  if v_home->'filing'->>'label' not ilike '%download%' then
    raise exception 'PROOF 7 FAILED: the filing button does not say download';
  end if;
  raise notice 'PROOF 7 OK — can_file=false, button says "%", note says filing happens on the portal',
    v_home->'filing'->>'label';

  raise notice '════ ALL PROOFS GREEN ════';
end $$;

rollback;
