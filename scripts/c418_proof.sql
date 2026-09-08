-- CMD #418 — the proof.
--
-- SCOPE NOTE, stated plainly: the Vertex leg cannot run on this project today.
-- `aiplatform.googleapis.com` answers 403 BILLING_DISABLED for
-- project-b83d3f5f-25d0-45ef-a4e, and it does so for the EXISTING `gemini-ocr`
-- function too — this is an environment blocker that affects every AI/OCR
-- feature in mediBO right now, not something this command introduced. That leg
-- is proven as far as it can be: a real photo was uploaded through storage RLS
-- as the pharmacy, rx-ocr called Vertex, the 403 came back, and the failure was
-- RECORDED (status='failed') so the counter shows the backend's own sentence
-- rather than spinning — which is asserted below.
--
-- Everything downstream of the read is this command's own SQL, and it is proven
-- end to end here by handing rx_scan_report the line set a camera would produce.
-- That is a MATCHER proof and it is labelled as one: it asserts what mediBO
-- does with what was read, never what Gemini read.
\set ON_ERROR_STOP on
\pset pager off
\set shop '''3f1c9a10-4b6e-4c9a-9f22-5a0d7e8b1c33'''

delete from public.rx_scan where pharmacy_id = :shop and created_by is null;

insert into public.rx_scan (id, pharmacy_id, status, image_path, image_mime)
values ('c4180000-0000-4000-8000-000000000001', :shop, 'reading',
        'c418/proof.png', 'image/png');

\echo '── the read, as a camera would report it (four lines, one illegible) ────'
select public.rx_scan_report(
  'c4180000-0000-4000-8000-000000000001', true, 'gemini-3.5-flash',
  $j$[
    {"seen_text":"Tab. Isojol","seen_dose":"1-0-1","seen_duration":"5 days",
     "readable":true,"confidence":"high","qty_guess":10,"qty_basis":"1-0-1 x 5 days = 10"},
    {"seen_text":"Tab. Molmat 650","seen_dose":"1-1-1","seen_duration":"3 days",
     "readable":true,"confidence":"high","qty_guess":9,"qty_basis":"1-1-1 x 3 days = 9"},
    {"seen_text":"Syp. Azimax 100","seen_dose":"1 tsp BD","seen_duration":"5 days",
     "readable":true,"confidence":"medium","qty_guess":1,"qty_basis":"one bottle"},
    {"seen_text":"Rmnptqllne 40","seen_dose":"0-0-1","seen_duration":"10 dys",
     "readable":false,"confidence":"low"}
  ]$j$::jsonb) as reported;

\echo ''
\echo '── what SQL made of it: shelf first, FEFO batch, substitutes, human ─────'
select l.line_no, l.seen_text, l.readable, l.match_kind, l.matched_name,
       l.batch_no, l.expiry, l.on_hand, l.qty_guess,
       jsonb_array_length(l.substitutes) as subs
  from public.rx_scan_line l
 where l.scan_id = 'c4180000-0000-4000-8000-000000000001'
 order by l.line_no;

\echo ''
\echo '── FEFO: the shop holds TWO Isojol batches; the earlier expiry is used ──'
select batch_no, expiry, qty from public.pharmacy_stock
 where pharmacy_id = :shop and product_name = 'Isojol Tablet' order by expiry_on;

\echo ''
\echo '── the substitutes offered for the line they do not stock, best margin ──'
select s->>'product_name' as in_stock_instead, s->>'expiry' as expiry,
       s->>'on_hand_label' as on_hand, s->>'mrp_display' as mrp,
       s->>'margin_display' as your_margin
  from public.rx_scan_line l, jsonb_array_elements(l.substitutes) s
 where l.scan_id = 'c4180000-0000-4000-8000-000000000001' and l.line_no = 2;

\echo ''
\echo '── the counter payload: state, tone and the verbatim text side by side ──'
select l->>'line_no' as n, l->>'seen_text' as written_as, l->>'product_name' as matched,
       l->>'state_label' as state, l->>'tone' as tone, l->>'default_on' as ticked,
       coalesce(l->>'fefo_note','') as fefo, coalesce(l->>'confidence_note','') as warn
  from (select public._c418_detail(:shop, 'c4180000-0000-4000-8000-000000000001') d) q,
       jsonb_array_elements(d->'lines') l;

\echo ''
\echo '── only a line the shop can FILL starts ticked; nothing else does ───────'
select count(*) filter (where (l->>'default_on')::boolean) as pre_ticked,
       count(*) as total_lines
  from (select public._c418_detail(:shop, 'c4180000-0000-4000-8000-000000000001') d) q,
       jsonb_array_elements(d->'lines') l;

\echo ''
\echo '── an unreadable line is never matched onto a product ──────────────────'
select line_no, seen_text, readable, match_kind, matched_name is null as no_product_guessed
  from public.rx_scan_line
 where scan_id = 'c4180000-0000-4000-8000-000000000001' and not readable;

\echo ''
\echo '── a read FAILURE shows the backend sentence, never the raw error ──────'
select public._c418_detail(:shop, r.id)->>'failed_message' as counter_sees,
       length(r.ocr_error) > 200 as raw_error_kept_for_audit,
       position('BILLING_DISABLED' in
         coalesce(public._c418_detail(:shop, r.id)::text, '')) = 0 as raw_never_in_payload
  from public.rx_scan r
 where r.pharmacy_id = :shop and r.status = 'failed'
 order by r.created_at desc limit 1;

\echo ''
\echo '── the security fence ──────────────────────────────────────────────────'
select jsonb_pretty(public.c418_qa_report());
