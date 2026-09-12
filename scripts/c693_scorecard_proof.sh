#!/usr/bin/env bash
# CHANGE #693 — the partner scorecard proof (feature_gaps row 156).
#
# Seeds ONE month of fulfilment for partner 1 inside a single transaction,
# asserts every one of the seven metrics, a target's progress, an incentive
# scheme earning its bonus, and that bonus landing in a settlement period —
# then ROLLS BACK. Nothing is left in the books, and the proof is re-runnable
# any time the measurement changes.
#
#   bash scripts/c693_scorecard_proof.sh
#
# Exits non-zero on the first assertion that fails.
set -euo pipefail

PGURL="${SUPABASE_DB_URL:-$(cat "$HOME/.medibo/dburl")}"

psql "$PGURL" -X -v ON_ERROR_STOP=1 -q <<'SQL'
begin;
-- The seed is DATA, not a user journey: the order triggers (WhatsApp notify,
-- order-hours gate, approval enforcement, bag numbering) are the app's, not
-- this proof's, and firing them would test them instead of the scorecard.
set local session_replication_role = 'replica';
set local request.jwt.claim.role = 'service_role';

create temp table c693_ids(k text primary key, id uuid) on commit drop;

-- ── 5 orders in February 2026 for partner 1 / zone 1 ────────────────────────
-- o1..o4 became dispatch-ready 6 h, 10 h, 30 h and 8 h after the order landed;
-- o5 never did. Dispatch SLA is 12 h, so three of the four were on time.
insert into c693_ids(k, id)
select 'o' || g, gen_random_uuid() from generate_series(1,5) g;

insert into public.orders
  (id, order_code, status, fulfillment_status, created_at, order_date, zone_id,
   fulfillment_partner_id, unfulfilled_count, total_amount, items, source)
select i.id,
       'C693-' || i.k,
       'delivered', 'shipped',
       timestamptz '2026-02-05 04:00:00+00' + make_interval(days => (right(i.k,1)::int)),
       date '2026-02-05' + (right(i.k,1)::int),
       1, 1,
       case when i.k in ('o1','o2') then 1 else 0 end,
       1000, '[]'::jsonb, 'website'
  from c693_ids i;

update public.orders o set dispatch_ready_at = o.created_at + make_interval(hours => h.hrs)
  from (values ('o1',6),('o2',10),('o3',30),('o4',8)) h(k,hrs)
  join c693_ids i on i.k = h.k
 where o.id = i.id;

-- 10 ordered lines: two per order.
insert into public.order_items (order_id, product_name, quantity, price, line_total)
select i.id, 'C693 line ' || n, 1, 100, 100
  from c693_ids i, generate_series(1,2) n;

-- ── 1 of those 10 lines raised a dispute → 10.0% ────────────────────────────
insert into public.supplier_disputes (order_item_id, product_name, ordered_qty, short_qty)
select oi.id, oi.product_name, 1, 1
  from public.order_items oi
  join c693_ids i on i.id = oi.order_id and i.k = 'o3'
 order by oi.id limit 1;

-- ── 4 deliveries, 3 inside the promised window → 75.0% ──────────────────────
insert into public.deliveries (order_id, status, promised_at, delivered_at)
select i.id, 'delivered',
       o.created_at + interval '48 hours',
       o.created_at + case when i.k = 'o3' then interval '72 hours'
                                           else interval '40 hours' end
  from c693_ids i join public.orders o on o.id = i.id
 where i.k in ('o1','o2','o3','o4');

-- ── a statement that CLOSED in February, acknowledged 36 h later ────────────
insert into public.partner_settlement_periods
  (partner_id, zone_id, period_start, period_end, cadence, due_on, split_pct,
   status, closed_at)
values (1, 1, date '2026-02-01', date '2026-02-07', 'weekly', date '2026-02-09', 60,
        'due', timestamptz '2026-02-08 04:00:00+00');

insert into public.partner_settlement_ack (period_id, partner_id, state, acked_at)
select id, 1, 'agreed', closed_at + interval '36 hours'
  from public.partner_settlement_periods
 where partner_id = 1 and period_start = date '2026-02-01';

-- ── 4 zone-1 exceptions closed in February, 3 inside the 24 h SLA → 75.0% ───
insert into public.exception_state
  (id, reason_code, ref_id, status, zone_id, started_at, closed_at)
select 'c693-x' || g, 'c693_proof', 'ref' || g, 'closed', 1,
       timestamptz '2026-02-10 04:00:00+00',
       timestamptz '2026-02-10 04:00:00+00'
         + case when g = 4 then interval '40 hours' else interval '5 hours' end
  from generate_series(1,4) g;

-- ── ASSERT: every metric, computed from exactly that ────────────────────────
do $$
declare v jsonb; got text; want text;
begin
  select coalesce(jsonb_object_agg(m.metric, m.value), '{}'::jsonb) into v
    from public._partner_metric_values(1, date '2026-02-01') m;

  raise notice 'measured: %', v;

  for got, want in
    select * from (values
      (v->>'inquiry_to_pack_h',      '13.50'),   -- (6+10+30+8)/4
      (v->>'on_time_dispatch_pct',   '75.00'),   -- 3 of 4 inside 12 h
      (v->>'count_dispute_rate_pct', '10.00'),   -- 1 disputed line of 10
      (v->>'unfulfilled_rate_pct',   '20.00'),   -- 2 unfulfilled of 10
      (v->>'delivery_sla_pct',       '75.00'),   -- 3 of 4 inside the window
      (v->>'settlement_ack_h',       '36.00'),   -- acknowledged 36 h after close
      (v->>'exception_sla_pct',      '75.00')    -- 3 of 4 closed inside 24 h
    ) t(a,b)
  loop
    if got is distinct from want then
      raise exception 'metric mismatch: got % want %', got, want;
    end if;
  end loop;
  raise notice 'PASS 1/4 — all seven metrics measured from the seeded month';
end $$;

-- ── ASSERT: a target moves the progress bar, and only the target ────────────
do $$
declare r jsonb; p numeric;
begin
  perform public.partner_targets_set(1, date '2026-02-01', '{"inquiry_to_pack_h":"9"}'::jsonb);
  select m into r from jsonb_array_elements(public.partner_scorecard(1, date '2026-02-01')->'metrics') m
   where m->>'slug' = 'inquiry_to_pack_h';
  p := (r->>'progress')::numeric;
  -- lower_better: 9 h target against 13.5 h actual = 66.7 score = 0.6670
  if abs(p - 0.6670) > 0.0002 then
    raise exception 'target progress wrong: % (row %)', p, r;
  end if;
  if r->>'target_label' <> '9.0 h' or r->>'tone' <> 'danger' then
    raise exception 'target label/tone wrong: %', r;
  end if;
  raise notice 'PASS 2/4 — target 9.0 h gives progress % and tone %', p, r->>'tone';
end $$;

-- ── ASSERT: a partner-scope scheme earns its bonus for the month ────────────
do $$
declare v_scheme uuid; v_amount numeric; v_res jsonb;
begin
  -- The statement that will carry it: the first one still open that ends after
  -- February. It has to exist BEFORE the evaluation, because the evaluation
  -- attaches the bonus the moment it is earned.
  insert into public.partner_settlement_periods
    (partner_id, zone_id, period_start, period_end, cadence, due_on, split_pct,
     status, brought_forward)
  values (1, 1, date '2026-03-01', date '2026-03-31', 'monthly', date '2026-04-02', 60,
          'open', 0);

  insert into public.incentive_schemes
    (slug, label, scope, region_partner_id, metric, threshold, bonus_amount, active, note)
  values ('c693_proof_dispatch', 'C693 proof — on-time dispatch', 'partner', 1,
          'on_time_dispatch_pct', 70, 2500, true, 'rolled back by the proof script')
  returning id into v_scheme;

  v_res := public.partner_incentive_evaluate_month(date '2026-02-01', 1);
  raise notice 'evaluate: %', v_res;

  select amount into v_amount from public.partner_incentive_earning
   where scheme_id = v_scheme and partner_id = 1 and month = date '2026-02-01';
  if coalesce(v_amount,0) <> 2500 then
    raise exception 'bonus not earned: %', v_amount;
  end if;
  raise notice 'PASS 3/4 — 75%% on-time clears the 70%% threshold, bonus 2500 earned';
end $$;

-- ── ASSERT: the earned bonus lands in the settlement ────────────────────────
do $$
declare v_period bigint; p public.partner_settlement_periods%rowtype;
begin
  select id into v_period from public.partner_settlement_periods
   where partner_id = 1 and period_start = date '2026-03-01';

  -- Idempotent: re-running the attach must not double-count.
  perform public.partner_bonus_attach(1);
  select * into p from public.partner_settlement_periods where id = v_period;

  if p.bonus_total <> 2500 then
    raise exception 'bonus did not reach the period: bonus_total=%', p.bonus_total;
  end if;
  if p.net_due <> 2500 or p.payable <> 2500 then
    raise exception 'net_due/payable did not carry the bonus: % / %', p.net_due, p.payable;
  end if;
  if p.medibo_share <> -2500 then
    raise exception 'mediBO did not fund the bonus: medibo_share=%', p.medibo_share;
  end if;
  if not exists (select 1 from public.partner_incentive_earning
                  where partner_id = 1 and month = date '2026-02-01' and period_id = v_period) then
    raise exception 'the earning was not attached to the period';
  end if;
  raise notice 'PASS 4/4 — bonus_total % , net_due % , payable % , medibo_share %',
    p.bonus_total, p.net_due, p.payable, p.medibo_share;
end $$;

rollback;
SQL

echo "c693 scorecard proof: all four assertions passed, transaction rolled back."
