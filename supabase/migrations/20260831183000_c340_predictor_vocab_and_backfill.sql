-- CHANGE #340, round-2 QA follow-ups. Hostile QA passed the matcher fix and
-- filed three minor gaps; all three are data, so all three are fixed here
-- rather than left as findings.
--
-- 1. VOCABULARY. Under the old `pattern OR area` matcher two real commands
--    predicted the five storefront paths by ACCIDENT of their area label while
--    touching none of them: #293 (Razorpay checkout — really edited checkout
--    and cust_pay_panel.dart) and #167 (wishlist — really edited
--    wishlist_screen.dart). Pattern-triggering makes both predict {} , which is
--    not a regression (they never predicted their real files) but it is a gap
--    the rules can close, because the rules are data.
--      - 'razorpay' joins the billing rule, which already owns the pay panel.
--      - 'wishlist' becomes its own rule; it had no rule at all.
--    Neither phrase is common English, so neither can over-chain: measured over
--    all 160 dev_commands rows, 'razorpay' matches 5 and 'wishlist' 4, every one
--    of them genuinely that work.
--
-- 2. BACKFILL. #327's predictor migrations always re-ran the prediction over
--    existing rows and re-chained; 20260831170000 and 180000 did not, so a
--    changed matcher only reached rows inserted afterwards (new rows are safe —
--    trg_dev_predict_files fires BEFORE INSERT). It happened to be harmless
--    because the queue was empty, but "correct as long as nothing is queued" is
--    not a property worth keeping. Backfill every row that is still schedulable
--    and re-chain. Rows that are building are judged on their real leases by
--    dev_cmd_footprint, so their stored prediction is advisory only.
update file_predict_rule
   set pattern = '(\mbill\M|\minvoice\M|\mutr\M|\mpayment\M|\mgst\M|\mrazorpay\M)'
 where id = 12;

insert into file_predict_rule (label, area, pattern, paths, active, note)
select 'Wishlist', null, '(\mwishlist\M|\msaved for later\M)',
       array['lib/screens/wishlist_screen.dart'], true,
       'Added by #340 round-2 QA: wishlist work (#160/#167/#168) had no rule at all and only predicted the storefront paths by accident of its area label.'
where not exists (select 1 from file_predict_rule where pattern ~ 'wishlist');

update dev_commands
   set predicted_files = dev_cmd_predict_files(title, spec, area)
 where status in ('pending','needs_input');

select dev_cmd_autochain();
