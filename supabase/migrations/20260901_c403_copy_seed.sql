-- CHANGE #403 — the copy for the supplier records layer. English in ui_copy is
-- the guaranteed fallback; Hindi in ui_copy_i18n is what a supplier who chose
-- Hindi in #402 actually reads. A key with no Hindi row is not a bug — it is a
-- row in ui_language_report(), which is how the gap stays visible.
--
-- Every string a supplier sees on these four surfaces is here. There is no
-- display string in Dart on this feature: changing a word is an UPDATE.

with seed(k, en, hi) as (values
  -- ── the surface ─────────────────────────────────────────────────────────
  ('supplier_records.feature_label', 'Records', 'रिकॉर्ड'),
  ('supplier_records.title', 'My records', 'मेरे रिकॉर्ड'),
  ('supplier_records.subtitle', 'Your documents, deductions, sales and old bills — all read-only.', 'आपके दस्तावेज़, कटौतियां, बिक्री और पुराने बिल — सभी केवल पढ़ने के लिए।'),
  ('supplier_records.tab_documents', 'Documents', 'दस्तावेज़'),
  ('supplier_records.tab_debits', 'Deductions', 'कटौतियां'),
  ('supplier_records.tab_sales', 'Sales', 'बिक्री'),
  ('supplier_records.tab_bills', 'Bills', 'बिल'),
  ('supplier_records.err_not_authorized', 'You do not have access to records.', 'आपको रिकॉर्ड की अनुमति नहीं है।'),

  -- ── documents tab ───────────────────────────────────────────────────────
  ('supplier_docs.title', 'Documents', 'दस्तावेज़'),
  ('supplier_docs.subtitle', 'Download a purchase order, a copy of a bill you sent us, or a monthly statement.', 'खरीद आदेश, आपके भेजे बिल की कॉपी, या मासिक विवरण डाउनलोड करें।'),
  ('supplier_docs.download_label', 'Download', 'डाउनलोड'),
  ('supplier_docs.building_label', 'Preparing…', 'तैयार हो रहा है…'),
  ('supplier_docs.building_message', 'Preparing your document. It opens in a few seconds.', 'आपका दस्तावेज़ तैयार हो रहा है। कुछ ही क्षणों में खुल जाएगा।'),
  ('supplier_docs.ready_message', 'Your document is ready.', 'आपका दस्तावेज़ तैयार है।'),
  ('supplier_docs.statements_heading', 'Monthly statements', 'मासिक विवरण'),
  ('supplier_docs.statements_empty', 'No months to report yet.', 'अभी दिखाने के लिए कोई महीना नहीं है।'),
  ('supplier_docs.statement_subtitle', 'Orders, bills, deductions, payments and balance', 'ऑर्डर, बिल, कटौतियां, भुगतान और शेष'),
  ('supplier_docs.po_heading', 'Purchase orders', 'खरीद आदेश'),
  ('supplier_docs.po_empty', 'No purchase orders yet.', 'अभी कोई खरीद आदेश नहीं है।'),
  ('supplier_docs.po_subtitle', '{date} · {amount}', '{date} · {amount}'),
  ('supplier_docs.bills_heading', 'Bills you sent us', 'आपके भेजे बिल'),
  ('supplier_docs.bills_empty', 'No bills received from you yet.', 'आपसे अभी तक कोई बिल नहीं मिला।'),
  ('supplier_docs.bill_subtitle', '{date} · {status}', '{date} · {status}'),
  ('supplier_docs.original_label', 'Original', 'मूल फ़ाइल'),
  ('supplier_docs.err_unknown_kind', 'That document type is not available.', 'यह दस्तावेज़ प्रकार उपलब्ध नहीं है।'),
  ('supplier_docs.err_not_found', 'That document is not yours, or no longer exists.', 'यह दस्तावेज़ आपका नहीं है, या अब मौजूद नहीं है।'),
  ('supplier_docs.err_failed', 'Could not prepare that document. Try again.', 'यह दस्तावेज़ तैयार नहीं हो सका। फिर कोशिश करें।'),

  -- ── the printed page ────────────────────────────────────────────────────
  ('supplier_doc.brand', 'mediBO', 'mediBO'),
  ('supplier_doc.subtitle', 'Generated {at} IST', '{at} IST पर बनाया गया'),
  ('supplier_doc.footer', 'Jai Mahakal Medical And Surgical (mediBO), Chhattisgarh, India. This is a computer-generated document.', 'जय महाकाल मेडिकल एंड सर्जिकल (mediBO), छत्तीसगढ़, भारत। यह कंप्यूटर से बना दस्तावेज़ है।'),
  ('supplier_doc.po_title', 'Purchase order {code}', 'खरीद आदेश {code}'),
  ('supplier_doc.bill_title', 'Bill copy {no}', 'बिल कॉपी {no}'),
  ('supplier_doc.stmt_title', 'Statement — {month}', 'विवरण — {month}'),
  ('supplier_doc.lbl_supplier', 'Supplier', 'सप्लायर'),
  ('supplier_doc.lbl_order_code', 'Order', 'ऑर्डर'),
  ('supplier_doc.lbl_order_date', 'Order date', 'ऑर्डर तिथि'),
  ('supplier_doc.lbl_status', 'Status', 'स्थिति'),
  ('supplier_doc.lbl_invoice_no', 'Invoice no.', 'बिल संख्या'),
  ('supplier_doc.lbl_received', 'Received', 'प्राप्त'),
  ('supplier_doc.lbl_file', 'File', 'फ़ाइल'),
  ('supplier_doc.lbl_period', 'Period', 'अवधि'),
  ('supplier_doc.lbl_items', 'Items', 'आइटम'),
  ('supplier_doc.lbl_lines', 'Lines', 'पंक्तियां'),
  ('supplier_doc.lbl_bill_total', 'Bill total', 'बिल कुल'),
  ('supplier_doc.lbl_ordered', 'Ordered', 'ऑर्डर किया'),
  ('supplier_doc.lbl_billed', 'Billed', 'बिल किया'),
  ('supplier_doc.lbl_debits', 'Deductions', 'कटौतियां'),
  ('supplier_doc.lbl_paid', 'Paid', 'भुगतान'),
  ('supplier_doc.lbl_balance', 'Balance', 'शेष'),
  ('supplier_doc.col_product', 'Product', 'उत्पाद'),
  ('supplier_doc.col_pack', 'Pack', 'पैक'),
  ('supplier_doc.col_qty', 'Qty', 'मात्रा'),
  ('supplier_doc.col_free', 'Free', 'फ्री'),
  ('supplier_doc.col_amount', 'Amount', 'राशि'),
  ('supplier_doc.col_batch', 'Batch', 'बैच'),
  ('supplier_doc.col_expiry', 'Expiry', 'एक्सपायरी'),
  ('supplier_doc.col_ptr', 'Rate', 'रेट'),
  ('supplier_doc.col_gst', 'GST', 'GST'),
  ('supplier_doc.col_date', 'Date', 'तिथि'),
  ('supplier_doc.col_ref', 'Reference', 'संदर्भ'),
  ('supplier_doc.col_detail', 'Detail', 'विवरण'),
  ('supplier_doc.po_lines_heading', 'Items ordered', 'ऑर्डर किए गए आइटम'),
  ('supplier_doc.bill_lines_heading', 'Bill lines', 'बिल की पंक्तियां'),
  ('supplier_doc.bill_lines_empty', 'This bill has no matched lines yet.', 'इस बिल की कोई पंक्ति अभी मिलान नहीं हुई।'),
  ('supplier_doc.bill_copy_note', 'This is mediBO''s record of the bill you sent. The original file stays available in your Bills tab.', 'यह आपके भेजे बिल का mediBO रिकॉर्ड है। मूल फ़ाइल आपके बिल टैब में उपलब्ध रहती है।'),
  ('supplier_doc.stmt_orders_heading', 'Orders', 'ऑर्डर'),
  ('supplier_doc.stmt_orders_empty', 'No orders this month.', 'इस महीने कोई ऑर्डर नहीं।'),
  ('supplier_doc.stmt_bills_heading', 'Bills received', 'प्राप्त बिल'),
  ('supplier_doc.stmt_bills_empty', 'No bills this month.', 'इस महीने कोई बिल नहीं।'),
  ('supplier_doc.stmt_payments_heading', 'Payments made to you', 'आपको किए गए भुगतान'),
  ('supplier_doc.stmt_payments_empty', 'No payments this month.', 'इस महीने कोई भुगतान नहीं।'),
  ('supplier_doc.stmt_debits_heading', 'Deductions', 'कटौतियां'),
  ('supplier_doc.stmt_debits_empty', 'No deductions this month.', 'इस महीने कोई कटौती नहीं।'),
  ('supplier_doc.stmt_note', 'Balance is billed value less deductions less payments already made. Trade rates only — MRP is never the selling price.', 'शेष = बिल की राशि − कटौतियां − किए गए भुगतान। केवल ट्रेड रेट — MRP कभी बिक्री मूल्य नहीं है।'),

  -- ── deductions tab ──────────────────────────────────────────────────────
  ('supplier_debits.title', 'Deductions', 'कटौतियां'),
  ('supplier_debits.subtitle', 'Every return or short/damage claim that came off a bill, with the reason and the proof.', 'हर वापसी या कम/खराब माल का दावा जो बिल से काटा गया — कारण और प्रमाण के साथ।'),
  ('supplier_debits.empty', 'No deductions against you. Nothing has been taken off a bill.', 'आपके विरुद्ध कोई कटौती नहीं है। किसी बिल से कुछ नहीं काटा गया।'),
  ('supplier_debits.src_return', 'Customer return', 'ग्राहक वापसी'),
  ('supplier_debits.src_dispute', 'Short / damage claim', 'कम / खराब माल का दावा'),
  ('supplier_debits.ref_order', 'Customer order', 'ग्राहक ऑर्डर'),
  ('supplier_debits.ref_supplier_order', 'Your order', 'आपका ऑर्डर'),
  ('supplier_debits.qty_label', 'Qty {qty}', 'मात्रा {qty}'),
  ('supplier_debits.effect_label', 'Reduces your payable by {amount}', 'आपके देय में {amount} की कमी'),
  ('supplier_debits.photo_label', 'Photo proof', 'फोटो प्रमाण'),
  ('supplier_debits.payable_note', '{amount} has been deducted from what mediBO owes you.', 'mediBO के आपके प्रति देय में से {amount} काटा गया है।'),
  ('supplier_debits.sum_count', 'Deductions', 'कटौतियां'),
  ('supplier_debits.sum_total', 'Total deducted', 'कुल कटौती'),
  ('supplier_debits.sum_open', 'Not yet credited', 'अभी क्रेडिट नहीं'),
  ('supplier_debits.status_approved', 'Approved', 'स्वीकृत'),
  ('supplier_debits.status_credited', 'Credited', 'क्रेडिट किया'),
  ('supplier_debits.status_pending', 'Pending', 'लंबित'),
  ('supplier_debits.status_resolved', 'Settled', 'निपटाया'),
  ('supplier_debits.reason_short', 'Short supplied', 'कम माल भेजा'),
  ('supplier_debits.reason_damage', 'Damaged', 'खराब'),
  ('supplier_debits.reason_wrong', 'Wrong product', 'गलत उत्पाद'),
  ('supplier_debits.reason_expiry', 'Near expiry', 'एक्सपायरी के पास'),

  -- ── sales tab ───────────────────────────────────────────────────────────
  ('supplier_sales.title', 'Monthly sales', 'मासिक बिक्री'),
  ('supplier_sales.tile_total', 'Sold to mediBO', 'mediBO को बेचा'),
  ('supplier_sales.tile_growth', 'Vs last month', 'पिछले महीने की तुलना में'),
  ('supplier_sales.tile_fill', 'Fill rate', 'पूर्ति दर'),
  ('supplier_sales.orders_caption', '{n} orders', '{n} ऑर्डर'),
  ('supplier_sales.growth_caption', '{month}: {prev}', '{month}: {prev}'),
  ('supplier_sales.fill_caption', '{got} of {asked} units supplied', '{asked} में से {got} यूनिट भेजी'),
  ('supplier_sales.no_growth', 'No last month', 'पिछला महीना नहीं'),
  ('supplier_sales.no_fill', 'Nothing asked', 'कुछ नहीं मांगा'),
  ('supplier_sales.qty_label', '{qty} units', '{qty} यूनिट'),
  ('supplier_sales.top_heading', 'Your top products this month', 'इस महीने आपके शीर्ष उत्पाद'),
  ('supplier_sales.top_empty', 'Nothing ordered from you this month.', 'इस महीने आपसे कुछ नहीं मंगाया गया।'),
  ('supplier_sales.note', 'Amounts are trade value at the rate on the order — never MRP.', 'राशि ऑर्डर की दर पर ट्रेड मूल्य है — MRP कभी नहीं।'),

  -- ── bill archive tab ────────────────────────────────────────────────────
  ('supplier_bills.title', 'Bill archive', 'बिल संग्रह'),
  ('supplier_bills.subtitle', 'Find any bill you sent us — by invoice number, date or amount.', 'आपका भेजा कोई भी बिल खोजें — बिल संख्या, तिथि या राशि से।'),
  ('supplier_bills.search_hint', 'Invoice number or file name', 'बिल संख्या या फ़ाइल का नाम'),
  ('supplier_bills.from_label', 'From', 'से'),
  ('supplier_bills.to_label', 'To', 'तक'),
  ('supplier_bills.min_label', 'Min ₹', 'न्यूनतम ₹'),
  ('supplier_bills.max_label', 'Max ₹', 'अधिकतम ₹'),
  ('supplier_bills.search_label', 'Search', 'खोजें'),
  ('supplier_bills.clear_label', 'Clear', 'साफ़ करें'),
  ('supplier_bills.empty', 'No bills match that search.', 'इस खोज से कोई बिल नहीं मिला।'),
  ('supplier_bills.count_label', '{n} bills', '{n} बिल'),
  ('supplier_bills.qty_label', 'Qty {qty}', 'मात्रा {qty}'),
  ('supplier_bills.lines_heading', 'What we read on this bill', 'इस बिल पर हमने जो पढ़ा'),
  ('supplier_bills.lines_empty', 'No lines matched on this bill yet.', 'इस बिल की कोई पंक्ति अभी मिलान नहीं हुई।'),
  ('supplier_bills.line_verified', 'Verified', 'सत्यापित'),
  ('supplier_bills.line_unverified', 'Being checked', 'जांच जारी'),
  ('supplier_bills.payments_heading', 'Payments linked to this bill', 'इस बिल से जुड़े भुगतान'),
  ('supplier_bills.payments_empty', 'No payment recorded against this bill yet.', 'इस बिल के विरुद्ध अभी कोई भुगतान दर्ज नहीं।'),
  ('supplier_bills.paid_label', '{amount} paid against this bill', 'इस बिल के विरुद्ध {amount} भुगतान'),
  ('supplier_bills.status_pending', 'Being checked', 'जांच जारी'),
  ('supplier_bills.status_imported', 'Accepted', 'स्वीकृत'),
  ('supplier_bills.status_rejected', 'Not accepted', 'स्वीकार नहीं'),
  ('supplier_bills.err_not_found', 'That bill is not yours, or no longer exists.', 'यह बिल आपका नहीं है, या अब मौजूद नहीं है।')
)
, up_en as (
  insert into public.ui_copy(key, value, updated_at)
  select k, to_jsonb(en), now() from seed where en is not null
  on conflict (key) do update set value = excluded.value, updated_at = now()
  returning 1)
insert into public.ui_copy_i18n(key, lang, value, source, updated_by, updated_at)
select k, 'hi', to_jsonb(hi), 'seed', 'c403', now() from seed where hi is not null
on conflict (key, lang) do update
  set value = excluded.value, source = 'seed', updated_at = now();

-- The four new supplier-facing prefixes join the Hindi report, so a missing
-- translation on this surface shows up the same way #402's did.
insert into public.ui_i18n_scope(prefix, label, sort_order, is_active) values
  ('supplier_records.','Supplier records',100,true),
  ('supplier_docs.','Supplier documents',105,true),
  ('supplier_doc.','Supplier document page',110,true),
  ('supplier_debits.','Supplier deductions',115,true),
  ('supplier_sales.','Supplier monthly sales',120,true),
  ('supplier_bills.','Supplier bill archive',125,true)
on conflict (prefix) do update
  set label = excluded.label, sort_order = excluded.sort_order, is_active = true;
