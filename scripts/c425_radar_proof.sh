#!/usr/bin/env bash
# CHANGE #425 — end-to-end proof of the four WhatsApp loops, on the mediBO Test
# Pharmacy only. Every send in this run is admitted by _c425_may_send() because
# the test number is the ONLY number in app_settings.expiry_radar.test_numbers
# while build_phase is on — a real pharmacy or supplier number is refused by the
# database, not by this script.
#
#   1. urgent expected-loss ping (with the one-tap ask attached)
#   2. the answer coming back over WhatsApp → the lot is corrected
#   3. a forwarded bill photo → vault OCR queue + confirmation
#   4. the monthly stock digest
#
# Usage: bash scripts/c425_radar_proof.sh
set -euo pipefail
DBURL="$(cat "$HOME/.medibo/dburl")"
SHOP='3f1c9a10-4b6e-4c9a-9f22-5a0d7e8b1c33'   # mediBO Test Pharmacy
PHONE='9111100011'

psql "$DBURL" -X -q -v ON_ERROR_STOP=1 -v shop="$SHOP" -v phone="$PHONE" <<'SQL'
\set QUIET on
\pset pager off

-- ── 0. a clean slate for this proof, test pharmacy only ─────────────────────
delete from pharmacy_radar_send_log where pharmacy_id = :'shop';
delete from pharmacy_radar_ask         where pharmacy_id = :'shop';
delete from pharmacy_wa_intake         where pharmacy_id = :'shop';
delete from whatsapp_messages          where wa_message_id like 'c425-proof-%';
delete from pharmacy_purchase_bill     where pharmacy_id = :'shop' and source = 'whatsapp';
delete from pharmacy_stock             where pharmacy_id = :'shop' and batch_no = 'JAN-425';

insert into pharmacy_radar_config (pharmacy_id, opt_in, max_msgs_per_week)
values (:'shop', true, 6)
on conflict (pharmacy_id) do update
  set opt_in = true, max_msgs_per_week = 6, urgent_enabled = true,
      ask_corrections = true, monthly_digest = true, wa_intake = true;

-- ── 1. Om's own example: a January lot that is not moving ───────────────────
insert into pharmacy_stock (id, pharmacy_id, medicine_id, product_name, pack_label,
                            item_key, batch_no, expiry, expiry_on, qty, unit_cost, mrp,
                            source_kind, supplier_label, received_on)
values ('c4250000-0000-4000-8000-000000000425', :'shop', null,
        'Montikop 10 Tablets', '10 tablets', 'c425-montikop', 'JAN-425',
        '10/2026', date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date
                    + interval '1 month 9 days',
        10, 180, 210, 'outside', 'SAI GANESH PHARMA',
        (now() at time zone 'Asia/Kolkata')::date - 210);

-- the inference engine's view of it: ten bought, barely anything sold
insert into pharmacy_lot_inference (lot_id, pharmacy_id, expiry_on, qty_in,
       inferred_sold, inferred_left, left_low, left_high, confidence, method, per_day, days_live)
values ('c4250000-0000-4000-8000-000000000425', :'shop',
        (date_trunc('month', (now() at time zone 'Asia/Kolkata'))::date + interval '1 month 9 days')::date,
        10, 0, 10, 8, 10, 0.6, 'inferred', 0.01, 210)
on conflict (lot_id) do update set inferred_left = 10, per_day = 0.01, qty_in = 10;

select public.pharmacy_radar_rebind() as rebind;

\echo '--- radar rows (expected loss, worst first)'
select product_name, batch_no, est_left, basis, unit_cost,
       value_at_cost, expected_loss, days_to_expiry, window_state
  from _c425_rows(:'shop') order by expected_loss desc limit 4;

-- ── LOOP 1: the urgent ping ─────────────────────────────────────────────────
\echo '--- loop 1: urgent expected-loss ping'
select public.pharmacy_radar_scan(5) as urgent_scan;
select kind, dedupe_key, detail->>'text' as text, detail#>>'{result,ok}' as sent_ok,
       detail->>'window_open' as window_open
  from pharmacy_radar_send_log where pharmacy_id = :'shop' and kind = 'radar_urgent';
select question, options, status from pharmacy_radar_ask where pharmacy_id = :'shop';

-- ── LOOP 2: the one-tap answer coming back ──────────────────────────────────
\echo '--- loop 2: the pharmacy answers "4" on WhatsApp'
insert into whatsapp_messages (id, sender_phone, sender_type, msg_type, text_body,
                               direction, wa_message_id, received_at)
values (gen_random_uuid(), :'phone', 'customer', 'text', '4', 'in',
        'c425-proof-answer', now());
select status, answered_qty, answer_source from pharmacy_radar_ask where pharmacy_id = :'shop';
select qty as stock_qty_now from pharmacy_stock where id = 'c4250000-0000-4000-8000-000000000425';
select reason_code, qty_delta, qty_after, actor_label, ref_kind
  from pharmacy_stock_move where stock_id = 'c4250000-0000-4000-8000-000000000425'
 order by created_at desc limit 1;

-- ── LOOP 3: a forwarded bill photo ──────────────────────────────────────────
\echo '--- loop 3: a bill photo forwarded to mediBO'
insert into whatsapp_messages (id, sender_phone, sender_type, msg_type, file_path,
                               media_bucket, mime_type, direction, wa_message_id, received_at)
values (gen_random_uuid(), :'phone', 'customer', 'image',
        'c425/proof-bill.jpg', 'whatsapp-media', 'image/jpeg', 'in',
        'c425-proof-bill', now());
select i.status, i.reason, b.status as bill_status, b.source, s.bucket, s.path
  from pharmacy_wa_intake i
  left join pharmacy_purchase_bill b on b.id = i.bill_id
  left join pharmacy_bill_shot s on s.bill_id = i.bill_id
 where i.pharmacy_id = :'shop';

-- what the reader found, told back to the shop (the OCR itself is #423's)
update pharmacy_purchase_bill
   set status = 'review', supplier_name = 'SAI GANESH PHARMA', invoice_no = 'SG/4417',
       line_count = 7, total_amount = 8420.50, unreadable_count = 0
 where pharmacy_id = :'shop' and source = 'whatsapp';
select public.pharmacy_radar_bill_confirm_sweep() as confirm_sweep;
select kind, detail->>'text' as text from pharmacy_radar_send_log
 where pharmacy_id = :'shop' and kind = 'radar_bill_read';

-- ── LOOP 4: the monthly digest ──────────────────────────────────────────────
\echo '--- loop 4: monthly stock digest'
select public.pharmacy_radar_month_scan(5) as month_scan;
select kind, dedupe_key, detail->>'text' as text from pharmacy_radar_send_log
 where pharmacy_id = :'shop' and kind = 'radar_month';

-- ── GUARD: a real pharmacy number and a supplier number are refused ─────────
\echo '--- guard: who the radar may talk to during the build phase'
select :'phone' as number, public._c425_may_send(:'phone') as may_send
union all select '9826445810', public._c425_may_send('9826445810')   -- a real supplier
union all select '8357881876', public._c425_may_send('8357881876');  -- a real customer

\echo '--- VERDICT'
select
  (select count(*) from pharmacy_radar_send_log
    where pharmacy_id = :'shop' and kind = 'radar_urgent')     as urgent_sent,
  (select count(*) from pharmacy_radar_ask
    where pharmacy_id = :'shop' and status = 'answered' and answered_qty = 4
      and answer_source = 'whatsapp')                          as answer_applied,
  (select count(*) from pharmacy_wa_intake
    where pharmacy_id = :'shop' and status = 'read')           as bill_read,
  (select count(*) from pharmacy_radar_send_log
    where pharmacy_id = :'shop' and kind = 'radar_month')      as digest_sent,
  (select count(*) from (select public._c425_may_send('9826445810') a
                          union all select public._c425_may_send('8357881876')) g
    where g.a)                                                  as leaks;
SQL
