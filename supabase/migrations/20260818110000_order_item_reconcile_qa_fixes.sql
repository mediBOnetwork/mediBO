-- CHANGE #238 (part 2) — QA round 1 fixes on top of
-- 20260818120000_order_item_reconcile.sql. Every statement is idempotent.
--
-- The important one is (A). Part 1 expressed _inq_confirmed() as a scan over
-- generate_series(1,30) with to_jsonb(i) evaluated per slot — i.e. 30 row->json
-- conversions per inquiry row, per evaluation. That predicate sits inside
-- rebuild_all_supplier_orders()'s per-order-item EXISTS, and that function is
-- fired by STATEMENT triggers on both order_items and inquiry. It is exactly
-- the scalar-helper-scan anti-pattern CLAUDE.md warns about, and it went live
-- minutes before the database stopped answering. It is replaced here with pure
-- column reads that are cheaper than the ORIGINAL predicate was.

-- ─────────────────────────────────────────────────────────────────────────────
-- A. _inq_confirmed: two column reads, no scan.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- t5_current_status_trg maintains `current_status` on EVERY insert and update
-- as "the AS answer sitting in the current supplier's own PS slot, else
-- Confirmation Pending". So `current_status = 'Available'` IS "the supplier we
-- are on right now answered Available" — the same predicate part 1 computed the
-- expensive way. Unlike `response` (the column the original tested, and the one
-- that named the PREVIOUS supplier), current_status cannot go stale: its
-- trigger is unconditional, not keyed to a column list.
CREATE OR REPLACE FUNCTION public._inq_confirmed(i inquiry)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT i.current_supplier IS NOT NULL
     AND btrim(i.current_supplier) <> ''
     AND i.current_status = 'Available'
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. The slot helpers: one to_jsonb, and prefer the slot that ANSWERED.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- A supplier can appear twice on a ladder. Taking the first matching PS slot
-- meant an earlier "Out of Stock" masked that supplier's later "Available" —
-- the very vanish this change exists to stop. Prefer an answered slot, and
-- among those prefer 'Available'.
CREATE OR REPLACE FUNCTION public._inq_slot_answer(i inquiry, p_supplier text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  WITH j AS (SELECT to_jsonb(i) AS r)
  SELECT a.ans
    FROM j, generate_series(1,30) n
    CROSS JOIN LATERAL (SELECT j.r->>('PS'||n) AS ps, j.r->>('AS'||n) AS ans) a
   WHERE p_supplier IS NOT NULL
     AND btrim(p_supplier) <> ''
     AND a.ps = p_supplier
   ORDER BY (a.ans = 'Available') DESC,
            (nullif(btrim(coalesce(a.ans,'')),'') IS NOT NULL) DESC,
            n
   LIMIT 1
$$;

CREATE OR REPLACE FUNCTION public._inq_responder(i inquiry)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  WITH j AS (SELECT to_jsonb(i) AS r),
  live AS (
    SELECT n, a.ps, a.ans
      FROM j, generate_series(1,30) n
      CROSS JOIN LATERAL (SELECT j.r->>('PS'||n) AS ps, j.r->>('AS'||n) AS ans) a
     WHERE a.ps IS NOT NULL AND btrim(a.ps) <> ''
  ),
  cur AS (SELECT min(n) AS idx FROM live WHERE ps = i.current_supplier)
  SELECT CASE
           WHEN i.current_supplier IS NULL OR btrim(i.current_supplier) = '' THEN NULL
           WHEN (SELECT idx FROM cur) IS NULL THEN NULL
           ELSE coalesce(
                  (SELECT l.ps FROM live l
                    WHERE l.n <= (SELECT idx FROM cur)
                      AND nullif(btrim(coalesce(l.ans,'')),'') IS NOT NULL
                    ORDER BY l.n DESC LIMIT 1),
                  'No supplier responded yet')
         END
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- C. Per-item state: units, not presence — and an exhausted ladder is not
--    "still under inquiry".
-- ─────────────────────────────────────────────────────────────────────────────
--
-- in_po used to ask only "does this product appear on that supplier's PO for
-- the day". rebuild_all_supplier_orders() writes ONE line per (supplier,
-- product, day) carrying the SUMMED quantity across every order that day, so a
-- product could be present while this order's units never made it — the exact
-- units-level version of "18 items, 9 on supplier orders". It now compares the
-- PO's quantity against the day's demand for that (supplier, product).
--
-- The product_id parse is also guarded: a supplier_orders.items entry with a
-- non-numeric or absent product_id used to raise 22P02 and take the whole panel
-- down.
CREATE OR REPLACE FUNCTION public._order_item_states(p_order_id uuid)
RETURNS TABLE(
  order_item_id uuid, product_id bigint, product_name text, quantity numeric,
  price numeric, mrp numeric, inquiry_id bigint, assigned_supplier text,
  unfulfillable boolean, unfulfillable_reason text, cancelled boolean,
  inq_id bigint, inq_current_supplier text, inq_next_supplier text,
  inq_current_status text, inq_confirmed boolean, inq_asked_at timestamptz,
  in_po boolean, po_units numeric, demand_units numeric, state text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT oi.id, oi.product_id, oi.product_name, oi.quantity, oi.price, oi.mrp,
         oi.inquiry_id, oi.assigned_supplier,
         coalesce(oi.unfulfillable,false), oi.unfulfillable_reason,
         (coalesce(oi.fulfillment_state,'') = 'cancelled') AS cancelled,
         i.id, i.current_supplier, i.next_supplier, i.current_status,
         coalesce(public._inq_confirmed(i.*), false), i.asked_at,
         (oi.assigned_supplier IS NOT NULL
          AND po.units IS NOT NULL
          AND po.units >= coalesce(dem.units, 0))              AS in_po,
         po.units, dem.units,
         CASE
           WHEN coalesce(oi.fulfillment_state,'') = 'cancelled' THEN 'cancelled'
           WHEN coalesce(oi.unfulfillable,false)                THEN 'unfulfillable'
           WHEN oi.assigned_supplier IS NOT NULL                THEN 'supplier_assigned'
           -- An inquiry row whose ladder has run out has nobody left to ask.
           -- Counting that as "still under inquiry" let a dead line sit inside
           -- a green "all items accounted for" forever.
           WHEN i.id IS NOT NULL
            AND nullif(btrim(coalesce(i.current_supplier,'')),'') IS NOT NULL
                                                                THEN 'in_inquiry'
           ELSE 'unaccounted'
         END AS state
    FROM order_items oi
    LEFT JOIN LATERAL (
      SELECT q.* FROM inquiry q
       WHERE (q.id = oi.inquiry_id)
          OR (oi.inquiry_id IS NULL
              AND q.product_id = oi.product_id
              AND q.batch_date = oi.order_date
              AND (q.zone_id IS NOT DISTINCT FROM oi.zone_id OR q.zone_id IS NULL))
       ORDER BY (q.id = oi.inquiry_id) DESC, q.id DESC
       LIMIT 1
    ) i ON true
    LEFT JOIN LATERAL (
      SELECT sum((it->>'quantity')::numeric) AS units
        FROM supplier_orders so,
             jsonb_array_elements(
               CASE WHEN jsonb_typeof(so.items) = 'array'
                    THEN so.items ELSE '[]'::jsonb END) it
       WHERE oi.assigned_supplier IS NOT NULL
         AND so.supplier_name = oi.assigned_supplier
         AND so.order_date = oi.order_date
         AND coalesce(so.status,'') <> 'cancelled'
         AND coalesce(it->>'product_id','') ~ '^[0-9]+$'
         AND (it->>'product_id')::bigint = oi.product_id
    ) po ON true
    LEFT JOIN LATERAL (
      SELECT sum(oi2.quantity) AS units
        FROM order_items oi2 JOIN orders o2 ON o2.id = oi2.order_id
       WHERE oi.assigned_supplier IS NOT NULL
         AND oi2.assigned_supplier = oi.assigned_supplier
         AND oi2.product_id = oi.product_id
         AND oi2.order_date = oi.order_date
         AND coalesce(oi2.fulfillment_state,'') <> 'cancelled'
         AND coalesce(o2.fulfillment_status,'') NOT IN ('shipped','cancelled')
    ) dem ON true
   WHERE oi.order_id = p_order_id
   ORDER BY oi.created_at, oi.id
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- D. Copy that adds up, plus the frontend's error/retry words.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The old bad-banner sentence printed assigned + unfulfillable + in_inquiry and
-- silently omitted `unaccounted`, so its own numbers did not sum to its own
-- total while the detail line underneath contradicted it. It now names every
-- bucket, and `assigned` is stated as ON purchase orders only when it is.
UPDATE app_settings SET value = value || jsonb_build_object(
  -- Every non-cancelled item lands in exactly one of these five buckets, so
  -- the sentence's own numbers sum to its own total. The first cut printed
  -- three of the five: it read "4 items — 1, 1, 1" while two items were missing
  -- from its own summary — the same silence in words that the pipeline had in
  -- data, and the protected test now refuses it.
  'reconcile_bad',
  '{total} items — {on_po} on purchase orders, {missing_po} assigned but not ordered, {unfulfillable} unfulfillable, {in_inquiry} under inquiry, {unaccounted} unaccounted',
  'detail_unaccounted',
  '{n} item(s) have no supplier, no inquiry and no unfulfillable reason.',
  'detail_missing_po',
  '{n} assigned item(s) have not reached their supplier''s purchase order.',
  'state_cancelled', 'Cancelled',
  'supplier_cancelled', 'Cancelled',
  'status_no_supplier', 'No supplier left to ask')
WHERE key = 'order_item_panel_copy';

INSERT INTO ui_copy (key, value) VALUES
  ('admin_customer.items_load_failed', 'Could not load this order''s items.'),
  ('admin_customer.retry', 'Retry')
ON CONFLICT (key) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- E. order_reconcile: gate it. It is SECURITY DEFINER (so it reads past RLS)
--    and granted to `authenticated`, and it had no role check — any signed-in
--    customer or supplier could pass any order id and read that order back.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.order_reconcile(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v jsonb;
  v_copy jsonb := coalesce((SELECT value FROM app_settings WHERE key='order_item_panel_copy'),'{}'::jsonb);
  v_total int; v_cancelled int; v_assigned int; v_unf int; v_inq int; v_unacc int; v_nopo int;
  v_counted int; v_on_po int; v_ok boolean; v_label text; v_detail text;
BEGIN
  IF public.get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;

  SELECT count(*)::int,
         count(*) FILTER (WHERE s.state='cancelled')::int,
         count(*) FILTER (WHERE s.state='supplier_assigned')::int,
         count(*) FILTER (WHERE s.state='unfulfillable')::int,
         count(*) FILTER (WHERE s.state='in_inquiry')::int,
         count(*) FILTER (WHERE s.state='unaccounted')::int,
         count(*) FILTER (WHERE s.state='supplier_assigned' AND NOT s.in_po)::int
    INTO v_total, v_cancelled, v_assigned, v_unf, v_inq, v_unacc, v_nopo
    FROM public._order_item_states(p_order_id) s;

  v_counted := v_total - v_cancelled;
  v_on_po   := v_assigned - v_nopo;          -- assigned AND actually on the PO
  v_ok := (v_unacc = 0 AND v_nopo = 0);

  v_label := CASE WHEN v_ok THEN coalesce(v_copy->>'reconcile_ok','')
                  ELSE coalesce(v_copy->>'reconcile_bad','') END;
  v_label := replace(replace(replace(replace(replace(replace(replace(v_label,
               '{total}', v_counted::text),
               '{on_po}', v_on_po::text),
               '{assigned}', v_assigned::text),
               '{unfulfillable}', v_unf::text),
               '{in_inquiry}', v_inq::text),
               '{unaccounted}', v_unacc::text),
               '{missing_po}', v_nopo::text);

  v_detail := btrim(concat_ws(' ',
    CASE WHEN v_unacc > 0
         THEN replace(coalesce(v_copy->>'detail_unaccounted',''),'{n}', v_unacc::text) END,
    CASE WHEN v_nopo > 0
         THEN replace(coalesce(v_copy->>'detail_missing_po',''),'{n}', v_nopo::text) END));

  v := jsonb_build_object(
    'balanced', v_ok, 'show', true,
    'total', v_counted, 'cancelled', v_cancelled,
    'assigned', v_assigned, 'on_po', v_on_po,
    'unfulfillable', v_unf, 'in_inquiry', v_inq,
    'unaccounted', v_unacc, 'missing_po', v_nopo,
    'label', v_label, 'detail', v_detail)
    || public.tone_colors(CASE WHEN v_ok THEN 'green' ELSE 'red' END);
  RETURN v;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- F. The panel: state decides the words, and no label can come back NULL.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Two lies fixed here:
--   • status_label fell through to "Not accounted for" whenever the line had no
--     inquiry row — but a direct-buy / offer line has no inquiry BY DESIGN
--     (CHANGE #223) and is assigned and on a PO. It rendered "Not accounted
--     for" inside a green chip.
--   • supplier_label used replace(tpl,'{a}', s.inq_current_supplier); when that
--     supplier was NULL the whole expression became SQL NULL, and a cancelled
--     or unfulfillable line still read "Asking <supplier>".
CREATE OR REPLACE FUNCTION public.order_item_status_panel(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_copy jsonb := coalesce((SELECT value FROM app_settings WHERE key='order_item_panel_copy'),'{}'::jsonb);
  v_lines jsonb;
BEGIN
  IF public.get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'order_item_id', s.order_item_id,
      'product_id',    s.product_id,
      'product_name',  s.product_name,
      'image_url',     nullif(btrim(m.image_url_1),''),
      'company',       upper(nullif(btrim(m.marketer),'')),
      'pack_label',    nullif(btrim(regexp_replace(coalesce(m.pack_qty,''),'(\d)\.0(\D)','\1\2','g')),''),
      'salt_composition', nullif(btrim(m.salt_composition),''),
      'quantity',      s.quantity,
      'qty_label',     (trim_scale(coalesce(s.quantity,0))::text || ' ' ||
                        CASE
                          WHEN nullif(btrim(m.pack_type),'') IS NULL
                            THEN CASE WHEN coalesce(s.quantity,0) > 1 THEN 'Units' ELSE 'Unit' END
                          WHEN coalesce(s.quantity,0) > 1 AND lower(btrim(m.pack_type)) ~ '(s|x|z|ch|sh)$'
                            THEN btrim(m.pack_type) || 'es'
                          WHEN coalesce(s.quantity,0) > 1 THEN btrim(m.pack_type) || 's'
                          ELSE btrim(m.pack_type)
                        END),
      'price',         s.price,
      'mrp',           s.mrp,
      'price_label',   CASE WHEN coalesce(s.price, s.mrp, 0) > 0
                            THEN public.inr_money(coalesce(nullif(s.price,0), s.mrp))
                            ELSE '' END,
      'line_total',    round(coalesce(s.quantity,0) * coalesce(s.price,0), 2),
      'state',         s.state,
      'state_label',   coalesce(v_copy->>('state_'||s.state),''),
      -- STATE decides the words first. Only a line that is genuinely walking
      -- the ladder shows the ladder's live status.
      'status_label',  coalesce(
                         CASE s.state
                           WHEN 'cancelled'    THEN coalesce(v_copy->>'state_cancelled','')
                           WHEN 'unfulfillable'
                             THEN coalesce(nullif(btrim(coalesce(s.unfulfillable_reason,'')),''),
                                           v_copy->>'state_unfulfillable')
                           WHEN 'unaccounted'
                             THEN CASE WHEN s.inq_id IS NOT NULL
                                       THEN coalesce(v_copy->>'status_no_supplier','')
                                       ELSE coalesce(v_copy->>'state_unaccounted','') END
                           WHEN 'supplier_assigned'
                             THEN coalesce(nullif(btrim(coalesce(s.inq_current_status,'')),''),
                                           v_copy->>'state_supplier_assigned')
                           ELSE coalesce(nullif(btrim(coalesce(s.inq_current_status,'')),''),
                                         v_copy->>'status_unknown')
                         END, ''),
      'status_colors', CASE
                         WHEN s.state IN ('unfulfillable','unaccounted')
                           THEN jsonb_build_object('bg','#FBE9E7','fg','#B42318')
                         WHEN s.state = 'supplier_assigned'
                           THEN jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                         WHEN s.state = 'cancelled'
                           THEN jsonb_build_object('bg','#EFEEE9','fg','#5A5A57')
                         ELSE jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                       END,
      'supplier_name', coalesce(nullif(btrim(coalesce(s.assigned_supplier,'')),''),
                                nullif(btrim(coalesce(s.inq_current_supplier,'')),''), ''),
      'has_supplier',  (s.state <> 'cancelled'
                        AND coalesce(nullif(btrim(coalesce(s.assigned_supplier,'')),''),
                                     nullif(btrim(coalesce(s.inq_current_supplier,'')),'')) IS NOT NULL),
      'supplier_label', coalesce(
          CASE
            WHEN s.state = 'cancelled' THEN coalesce(v_copy->>'supplier_cancelled','')
            WHEN s.state = 'supplier_assigned'
                 AND nullif(btrim(coalesce(s.assigned_supplier,'')),'') IS NOT NULL
              THEN replace(coalesce(v_copy->>'supplier_accepted',''), '{a}', s.assigned_supplier)
            WHEN nullif(btrim(coalesce(s.inq_current_supplier,'')),'') IS NOT NULL
              THEN replace(coalesce(v_copy->>'supplier_asking',''), '{a}', s.inq_current_supplier)
            ELSE coalesce(v_copy->>'supplier_none','')
          END, ''),
      'next_supplier_label', coalesce(
          CASE WHEN s.state = 'in_inquiry'
                AND nullif(btrim(coalesce(s.inq_next_supplier,'')),'') IS NOT NULL
               THEN replace(coalesce(v_copy->>'next_supplier',''), '{a}', s.inq_next_supplier)
               ELSE '' END, ''),
      'in_po',        s.in_po,
      'po_units',     s.po_units,
      'demand_units', s.demand_units,
      'po_warning',   CASE WHEN s.state = 'supplier_assigned' AND NOT s.in_po
                           THEN coalesce(v_copy->>'po_missing','') ELSE '' END,
      'unfulfillable', s.unfulfillable
    ) ORDER BY s.ordinality), '[]'::jsonb)
    INTO v_lines
    FROM public._order_item_states(p_order_id) WITH ORDINALITY AS s
    LEFT JOIN "MEDICINE" m ON m.id = s.product_id;

  RETURN jsonb_build_object(
    'ok', true, 'order_id', p_order_id,
    'lines', v_lines, 'count', jsonb_array_length(v_lines),
    'reconcile', public.order_reconcile(p_order_id));
END;
$$;

GRANT EXECUTE ON FUNCTION public.order_item_status_panel(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.order_reconcile(uuid)         TO authenticated;
GRANT EXECUTE ON FUNCTION public.order_reconcile_audit(date)   TO authenticated;
