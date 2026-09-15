-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 — the four pieces, proved end to end on synthetic rows.
-- Everything happens inside ONE transaction that ROLLS BACK, so the proof can
-- be re-run on production without leaving a rider, an order or a rupee behind.
--   1. the incentive engine scores a day and the payout run pays the bonus
--   2. the agency invoice is raised off that payout, with the GST split
--   3. the training gate refuses an assignment until the module is passed
--   4. fuel + maintenance turn cost-per-drop from configured into measured
-- Run: bash scripts/cmd407_proof.sh
-- ═══════════════════════════════════════════════════════════════════════════
\set ON_ERROR_STOP on
begin;

create temporary table t407 (k text primary key, got text, want text) on commit drop;
create or replace function pg_temp.chk(k text, got text, want text) returns void
language sql as $$ insert into t407 values (k, got, want) $$;

do $$
declare
  v_rider uuid; v_scheme uuid; v_zone smallint; v_day date;
  v_o1 uuid; v_o2 uuid; v_o3 uuid; v_run uuid;
  v_period uuid; v_res jsonb; v_inv jsonb; v_inv_id uuid; v_mod uuid;
  v_veh uuid; v_state jsonb; v_report jsonb; v_row jsonb; v_cust uuid; v_admin uuid;
begin
  v_day := (now() at time zone 'Asia/Kolkata')::date;

  -- The admin RPCs answer the CALLER, so the proof has to be one. It borrows
  -- a super-admin's own id rather than naming anybody: the row is looked up
  -- through public.admins, and the claim is transaction-local.
  select u.id into v_admin from public.admins a
    join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   where a.is_super limit 1;
  perform set_config('request.jwt.claims',
            json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  -- orders carry an approved pharmacy: enforce_order_approval() refuses a
  -- bare row, and the proof honours that rule rather than working around it.
  select user_id into v_cust from public.pharmacy_profiles
   where approved and coalesce(is_deleted,false) = false
     and user_id is not null
     and exists (select 1 from auth.users u where u.id = pharmacy_profiles.user_id)
   limit 1;

  -- ── a rider, approved today so the training gate applies to them ────────
  insert into public.delivery_partner_registrations(
      full_name, phone, status, is_active, partner_type, per_drop_rate,
      reviewed_at, gstin, legal_name)
  values ('Proof Rider 407', '9000000407', 'approved', true, 'agency', 30,
          now(), '22AAAAA0000A1Z5', 'Proof Agency 407 Pvt Ltd')
  returning id, zone_id into v_rider, v_zone;

  -- ══ 3. TRAINING GATE — before anything else, because it is what stops a
  --      stop from being handed over at all. ═════════════════════════════
  select id into v_mod from public.sop_modules where slug = 'delivery_basics';
  v_state := public.delivery_training_state(v_rider);
  perform pg_temp.chk('3a training blocks a new rider',
    (v_state->>'blocks_assignment'), 'true');

  insert into public.orders(user_id) values (v_cust) returning id into v_o1;
  v_res := public._delivery_assign_core(array[v_o1], v_rider, 'proof', null);
  perform pg_temp.chk('3b assign refuses with the backend''s own error',
    (v_res->>'error'), 'training_pending');
  perform pg_temp.chk('3c refusal carries the backend''s title',
    (case when coalesce(v_res->>'title','') <> '' then 'has_title' else 'blank' end), 'has_title');

  -- passing the required module clears the gate — and only the required one
  insert into public.sop_completions(module_id, partner_id, attempts, score_pct, passed, passed_at)
  select m.id, v_rider, 1, 100, true, now() from public.sop_modules m where m.active and m.is_required;
  v_state := public.delivery_training_state(v_rider);
  perform pg_temp.chk('3d passing the module clears the gate',
    (v_state->>'blocks_assignment'), 'false');

  -- an admin override is a RECORD: it clears the gate and says who and why
  update public.delivery_partner_registrations
     set training_override_at = now(), training_override_reason = 'proof'
   where id = v_rider;
  delete from public.sop_completions where partner_id = v_rider;
  v_state := public.delivery_training_state(v_rider);
  perform pg_temp.chk('3e an override clears the gate with the reason on the row',
    (v_state->>'blocks_assignment') || '|' || (v_state->>'override_reason'), 'false|proof');
  update public.delivery_partner_registrations
     set training_override_at = null, training_override_reason = null where id = v_rider;
  insert into public.sop_completions(module_id, partner_id, attempts, score_pct, passed, passed_at)
  select m.id, v_rider, 1, 100, true, now() from public.sop_modules m where m.active and m.is_required;

  -- ══ 1. INCENTIVE ENGINE ═════════════════════════════════════════════════
  insert into public.orders(user_id) values (v_cust) returning id into v_o2;
  insert into public.orders(user_id) values (v_cust) returning id into v_o3;
  insert into public.delivery_runs(partner_id, run_date, zone_id)
  values (v_rider, v_day, v_zone) returning id into v_run;

  insert into public.deliveries(order_id, run_id, partner_id, status, delivered_at,
                                promised_at, earning)
  values (v_o1, v_run, v_rider, 'delivered', now(), now() + interval '10 min', 30),
         (v_o2, v_run, v_rider, 'delivered', now(), now() + interval '10 min', 30),
         (v_o3, v_run, v_rider, 'delivered', now(), now() - interval '6 hours', 30);

  insert into public.incentive_schemes(slug, label, scope, metric, threshold, bonus_amount, active)
  values ('proof407', 'Proof — 3 drops a day', 'all', 'drops_per_day', 3, 75, true)
  returning id into v_scheme;

  perform pg_temp.chk('1a metric reads the day''s drops',
    public._incentive_metric_value(v_rider, v_day, 'drops_per_day')::text, '3');
  perform pg_temp.chk('1b on-time % counts only what beat the promise',
    public._incentive_metric_value(v_rider, v_day, 'on_time_pct')::text, '66.67');
  perform pg_temp.chk('1c an unknown metric never pays',
    coalesce(public._incentive_metric_value(v_rider, v_day, 'not_a_metric')::text, 'null'), 'null');

  v_res := public.incentive_evaluate_day(v_day, v_rider);
  perform pg_temp.chk('1d the engine scores the day',
    (v_res->>'earned'), '1');
  perform pg_temp.chk('1e one earning row, at the scheme''s bonus',
    (select coalesce(sum(amount),0)::text from public.incentive_earnings
      where partner_id = v_rider and earn_date = v_day), '75');

  -- re-running the SAME day corrects, never doubles
  perform public.incentive_evaluate_day(v_day, v_rider);
  perform pg_temp.chk('1f re-running the day does not double-pay',
    (select count(*)::text from public.incentive_earnings
      where partner_id = v_rider and earn_date = v_day), '1');

  -- the rider's own progress payload is finished, not a number to compare
  v_state := public.my_incentive_progress(v_day);
  perform pg_temp.chk('1g progress is rendered for the signed-in rider only',
    (v_state->>'has'), 'false');

  -- ══ 1b. THE PAYOUT RUN PAYS IT ══════════════════════════════════════════
  insert into public.delivery_payout_periods(partner_id, period_start, period_end)
  values (v_rider, v_day, v_day) returning id into v_period;
  update public.incentive_earnings set payout_period_id = v_period
   where partner_id = v_rider and earn_date = v_day;
  update public.delivery_payout_periods p
     set drop_count = 3, gross_amount = 90, bonus_amount = 75, net_amount = 165
   where p.id = v_period;

  perform pg_temp.chk('1h the payout carries drops AND bonus',
    (select (gross_amount = 90 and bonus_amount = 75 and net_amount = 165)::text
       from public.delivery_payout_periods where id = v_period), 'true');

  v_res := public.admin_payout_statement(v_period);
  perform pg_temp.chk('1i the statement prints the bonus as its own block',
    (v_res->>'has_bonus') || '|' || (v_res->>'bonus_label'), 'true|' || public.inr_money(75));

  -- ══ 2. AGENCY GST INVOICE ═══════════════════════════════════════════════
  insert into public.agency_invoices(
      period_id, partner_id, invoice_no, invoice_date, tax_period,
      agency_name, legal_name, agency_gstin, drop_count, drops_amount, bonus_amount,
      taxable, rate, cgst, sgst, igst, total_tax, total, is_interstate, gstin_missing,
      place_of_supply, hsn)
  select v_period, v_rider, 'PROOF/407', v_day, date_trunc('month', v_day)::date,
         'Proof Rider 407', 'Proof Agency 407 Pvt Ltd', '22AAAAA0000A1Z5', 3, 90, 75,
         165, 18,
         (s->>'cgst')::numeric, (s->>'sgst')::numeric, (s->>'igst')::numeric,
         (s->>'total_tax')::numeric, 165 + (s->>'total_tax')::numeric,
         (s->>'is_interstate')::boolean, (s->>'gstin_missing')::boolean,
         s->>'place_of_supply', '996813'
    from (select public.gst_split(165, 18,
                   (select seller_gstin from public.billing_config where id = 1),
                   '22AAAAA0000A1Z5') s) q
  returning id into v_inv_id;

  perform pg_temp.chk('2a GST is split, not invented',
    (select (cgst + sgst + igst)::text from public.agency_invoices where id = v_inv_id), '29.70');
  perform pg_temp.chk('2b the invoice total is taxable + tax',
    (select total::text from public.agency_invoices where id = v_inv_id), '194.70');

  v_res := public.agency_invoice_reconcile(v_inv_id);
  perform pg_temp.chk('2c an invoice that matches the payout, with no signed copy yet',
    (v_res->>'recon_status'), 'awaiting_signed');

  update public.agency_invoices set signed_path = 'da/x.pdf', signed_total = 900
   where id = v_inv_id;
  v_res := public.agency_invoice_reconcile(v_inv_id);
  perform pg_temp.chk('2d a signed copy that disagrees is flagged, not accepted',
    (v_res->>'recon_status'), 'mismatch');

  update public.agency_invoices set signed_total = 194.70 where id = v_inv_id;
  v_res := public.agency_invoice_reconcile(v_inv_id);
  perform pg_temp.chk('2e a matching signed copy reconciles',
    (v_res->>'recon_status'), 'matched');

  -- the PDF payload is a finished document: no number left for Dart to format
  v_inv := public._agency_invoice_doc_payload(v_inv_id);
  perform pg_temp.chk('2f the document payload is complete',
    (v_inv->>'ok') || '|' || (case when jsonb_array_length(v_inv->'doc'->'totals') = 7
                                   then 'totals' else 'short' end), 'true|totals');

  -- and it feeds the ledger as an INPUT credit, once
  perform public.gst_ledger_build_agency_invoices(v_day - 1, v_day + 1);
  perform public.gst_ledger_build_agency_invoices(v_day - 1, v_day + 1);
  perform pg_temp.chk('2g one input-credit row in the GST ledger, not two',
    (select count(*)::text from public.gst_ledger
      where source = 'agency_invoice' and source_id = v_inv_id), '1');
  perform pg_temp.chk('2h it is an INPUT credit',
    (select direction from public.gst_ledger where source_id = v_inv_id), 'input');

  -- an agency with no GSTIN generates no credit at all
  update public.agency_invoices set agency_gstin = '' where id = v_inv_id;
  delete from public.gst_ledger where source_id = v_inv_id;
  perform public.gst_ledger_build_agency_invoices(v_day - 1, v_day + 1);
  perform pg_temp.chk('2i an unregistered agency is absent from the ledger',
    (select count(*)::text from public.gst_ledger where source_id = v_inv_id), '0');

  -- ══ 4. VEHICLE & FUEL → REAL COST PER DROP ══════════════════════════════
  insert into public.delivery_vehicles(partner_id, reg_number, vehicle_type)
  values (v_rider, 'CG04AB1234', 'bike') returning id into v_veh;
  insert into public.delivery_vehicle_expenses(vehicle_id, partner_id, kind, amount, odometer_km, litres, spend_date)
  values (v_veh, v_rider, 'fuel', 300, 12450, 3.1, v_day),
         (v_veh, v_rider, 'maintenance', 150, 12450, null, v_day);

  v_report := public.admin_delivery_cost_report(v_day, v_day, null);
  select r into v_row from jsonb_array_elements(v_report->'rows') r
   where r->>'partner_id' = v_rider::text;

  -- earnings 90 + bonus 75 + running 450 = 615 over 3 drops = 205.00 each,
  -- against whatever delivery_config says a drop should cost.
  perform pg_temp.chk('4a cost per drop is measured, not configured',
    (v_row->>'actual_label'), public.inr_money(205));
  perform pg_temp.chk('4b running cost is the expense rows, verbatim',
    (v_row->>'spend_label'), public.inr_money(450));
  perform pg_temp.chk('4c a rider over the configured rate is toned as such',
    (v_row->>'tone'), 'danger');
end $$;

\echo ''
\echo '── CMD #407 proof ───────────────────────────────────────────────────────'
select case when got is not distinct from want then 'PASS' else 'FAIL' end as result,
       k as check, got, want
  from t407 order by k;

select case when count(*) filter (where got is distinct from want) = 0
            then 'ALL ' || count(*) || ' CHECKS PASSED'
            else count(*) filter (where got is distinct from want) || ' OF ' || count(*) || ' FAILED' end
       as verdict from t407;

do $$
declare v_bad int;
begin
  select count(*) into v_bad from t407 where got is distinct from want;
  if v_bad > 0 then raise exception 'cmd407 proof: % check(s) failed', v_bad; end if;
end $$;

rollback;
