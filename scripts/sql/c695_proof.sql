\set ON_ERROR_STOP on
begin;
set local request.jwt.claim.email = 'test.admin@medibo.in';
do $t$
declare
  v_pid bigint; v_period bigint; v_inv jsonb; v_id uuid; i public.settlement_invoice%rowtype;
  v_doc jsonb; v_cn jsonb; v_list jsonb; v_reg jsonb; v_again jsonb; v_cn2 jsonb;
begin
  -- A real partner with a GSTIN, and a settlement period of our own to settle.
  select id into v_pid from public.region_partners
   where coalesce(btrim(gstin),'') <> '' order by id limit 1;
  if v_pid is null then raise exception 'E2E: no partner with a GSTIN'; end if;

  insert into public.partner_settlement_periods
    (partner_id, zone_id, period_start, period_end, cadence, due_on, split_pct,
     orders_count, revenue, goods_cost, gross_margin, cost_total, distributable,
     partner_share, medibo_share, brought_forward, net_due, payable, carry_forward, status)
  values (v_pid, 1, current_date - 7, current_date - 1, 'weekly', current_date, 70,
          10, 100000, 70000, 30000, 5000, 25000, 17500, 7500, 0, 17500, 17500, 0, 'open')
  returning id into v_period;

  -- 1. An unsettled period has no invoice to raise.
  if (public._c695_issue(v_period)->>'error') <> 'not_settled' then
    raise exception 'E2E: an open period must not be invoiced';
  end if;

  update public.partner_settlement_periods set status='settled', settled_at=now() where id=v_period;

  -- 2. Issue. medibo_share 7500 > 0 => mediBO invoices the partner.
  v_inv := public._c695_issue(v_period, 'e2e');
  if coalesce(v_inv->>'ok','') <> 'true' then raise exception 'E2E: issue failed %', v_inv; end if;
  v_id := (v_inv->>'invoice_id')::uuid;
  select * into i from public.settlement_invoice where id = v_id;

  if i.direction <> 'medibo_to_partner' or i.issuer_key <> 'medibo' then
    raise exception 'E2E: wrong direction % / %', i.direction, i.issuer_key;
  end if;
  -- 3. The tax split. Both parties are Chhattisgarh (22) => CGST+SGST, no IGST.
  if i.is_interstate then raise exception 'E2E: 22->22 must be intrastate'; end if;
  if i.taxable <> 7500 or i.cgst <> 675 or i.sgst <> 675 or i.igst <> 0 or i.total <> 8850 then
    raise exception 'E2E: split wrong taxable=% cgst=% sgst=% igst=% total=%',
      i.taxable, i.cgst, i.sgst, i.igst, i.total;
  end if;
  if i.pos_code <> '22' then raise exception 'E2E: place of supply %', i.pos_code; end if;
  if i.sac_code = '' or i.invoice_no not like 'MBS/%' then
    raise exception 'E2E: sac/number wrong % %', i.sac_code, i.invoice_no;
  end if;

  -- 4. Regenerate is blocked.
  v_again := public._c695_issue(v_period, 'e2e');
  if (v_again->>'error') <> 'already_issued' then
    raise exception 'E2E: a second invoice was allowed: %', v_again;
  end if;

  -- 5. The PDF payload the shared renderer draws.
  v_doc := public.settlement_invoice_render_input(v_id);
  if coalesce(v_doc->>'ok','') <> 'true'
     or jsonb_array_length(v_doc->'invoice'->'lines') <> 1
     or jsonb_array_length(v_doc->'invoice'->'totals') <> 3
     or (v_doc->'invoice'->'net'->>'value') is null
     or (v_doc->>'file_name') not like 'MBS-%' then
    raise exception 'E2E: doc payload wrong: %', v_doc;
  end if;
  if (v_doc->'invoice'->'seller'->>'gstin_label') not like 'GSTIN: %'
     or (v_doc->'invoice'->'buyer'->>'gstin_label') not like 'GSTIN: %' then
    raise exception 'E2E: both GSTINs must print';
  end if;

  -- 6. Credit note: the adjustment, clamped, and only one.
  v_cn := public.settlement_invoice_credit_note(v_id, 2500, 'e2e adjustment');
  if coalesce(v_cn->>'ok','') <> 'true' then raise exception 'E2E: credit note failed %', v_cn; end if;
  select * into i from public.settlement_invoice where id = (v_cn->>'invoice_id')::uuid;
  if i.doc_kind <> 'credit_note' or i.parent_invoice_id <> v_id
     or i.taxable <> 2500 or i.cgst <> 225 or i.sgst <> 225 or i.total <> 2950 then
    raise exception 'E2E: credit note wrong %', to_jsonb(i);
  end if;
  v_cn2 := public.settlement_invoice_credit_note(v_id, 100, 'second');
  if (v_cn2->>'error') <> 'credit_note_exists' then
    raise exception 'E2E: a second credit note was allowed: %', v_cn2;
  end if;

  -- 7. The register carries both, in GSTR-1 columns, and the CSV agrees.
  v_reg := public.settlement_invoice_register(current_date);
  if coalesce(v_reg->>'ok','') <> 'true' or (v_reg->>'count')::int < 2 then
    raise exception 'E2E: register wrong %', (v_reg - 'csv' - 'rows');
  end if;
  if position('GSTIN/UIN of Recipient' in (v_reg->>'csv')) <> 1 then
    raise exception 'E2E: csv header wrong';
  end if;
  if position('"C"' in (v_reg->>'csv')) = 0 then
    raise exception 'E2E: the credit note must be typed C in the register';
  end if;

  -- 8. The console lists them, formatted, newest first.
  v_list := public.settlement_invoices(v_pid);
  if coalesce(v_list->>'ok','') <> 'true' or (v_list->>'count')::int < 2 then
    raise exception 'E2E: list wrong %', (v_list - 'rows');
  end if;
  if (v_list->'rows'->0->>'total_value') !~ '^₹' then
    raise exception 'E2E: money must arrive formatted, got %', (v_list->'rows'->0->>'total_value');
  end if;

  -- 9. The other direction, and IGST. A negative fee leg means the PARTNER
  -- supplied the service, so they issue; and two different state codes must
  -- produce IGST with both intrastate heads at zero.
  if (public._c695_tax_split(1000, 18, true)  ->>'igst')::numeric <> 180
     or (public._c695_tax_split(1000, 18, true) ->>'cgst')::numeric <> 0
     or (public._c695_tax_split(1000, 18, false)->>'igst')::numeric <> 0
     or (public._c695_tax_split(1000, 18, false)->>'cgst')::numeric <> 90 then
    raise exception 'E2E: tax split wrong';
  end if;
  -- A GSTIN decides the state, never the free-text name: a trailing space and
  -- a different case are the same state, and '27...' is not.
  if public._c695_state_code('22BXXPJ8518F1Z4','Maharashtra') <> '22'
     or public._c695_state_code('', ' CHHATTISGARH ') <> '22'
     or public._c695_state_code('27AAA', 'Chhattisgarh') <> '27'
     or public._c695_state_code('', 'Atlantis') <> '' then
    raise exception 'E2E: state code wrong';
  end if;

  insert into public.partner_settlement_periods
    (partner_id, zone_id, period_start, period_end, cadence, due_on, split_pct,
     orders_count, revenue, goods_cost, gross_margin, cost_total, distributable,
     partner_share, medibo_share, brought_forward, net_due, payable, carry_forward, status)
  values (v_pid, 1, current_date - 21, current_date - 15, 'weekly', current_date, 70,
          4, 20000, 18000, 2000, 500, 1500, 3000, -1500, 0, 3000, 3000, 0, 'settled')
  returning id into v_period;
  v_inv := public._c695_issue(v_period, 'e2e');
  if coalesce(v_inv->>'ok','') <> 'true' then raise exception 'E2E: reverse issue failed %', v_inv; end if;
  select * into i from public.settlement_invoice where id = (v_inv->>'invoice_id')::uuid;
  if i.direction <> 'partner_to_medibo' or i.issuer_key <> 'partner'
     or i.invoice_no not like 'PRS/%' or i.taxable <> 1500 then
    raise exception 'E2E: reverse direction wrong %', to_jsonb(i);
  end if;
  -- The parties are swapped against the forward leg. Deliberately asserted on
  -- the NAMES and not the GSTINs: in Raipur the partner IS the operator entity
  -- (both 22BXXPJ8518F1Z4), so a GSTIN comparison would fail on correct data -
  -- and that same coincidence is exactly why the split must be driven by state
  -- CODES rather than by "are these two rows different".
  if i.issuer_name <> (select coalesce(partner_name,'') from public.region_partners where id = v_pid)
     or i.recipient_name <> (select coalesce(seller_name,'') from public.billing_config where id = 1) then
    raise exception 'E2E: parties not swapped on the reverse leg (% -> %)',
      i.issuer_name, i.recipient_name;
  end if;
  if i.issuer_gstin = '' or i.recipient_gstin = '' then
    raise exception 'E2E: a tax invoice must carry both GSTINs';
  end if;

  raise notice 'C695 E2E OK  invoice=% total=% cgst=% sgst=%  cn=% reg_rows=%',
    (v_inv->>'invoice_no'), (v_inv->>'total'), 675, 675,
    (v_cn->>'invoice_no'), (v_reg->>'count');
end $t$;
rollback;
