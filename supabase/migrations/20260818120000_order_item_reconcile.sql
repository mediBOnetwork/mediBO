-- CHANGE #238 — "supplier orders show 9 items against a customer order of 18".
--
-- ROOT CAUSE (proven on 2026-08-17 live data, orders CPO170826PAL124O1 +
-- CPO170826CHAO1):
--
--   compute_responsed_by() named the supplier ONE SLOT BEFORE the current one
--   (`PS[cur_idx-1]`) as the responder. compute_response() then copied THAT
--   supplier's answer into `response`. So an item whose current supplier had
--   itself answered 'Available' at PS2+ carried response='Out of Stock' (the
--   PREVIOUS supplier's answer). _inq_confirmed() tests `response`, so it
--   returned false; inquiry_broadcast_to_oi() then NULLed
--   order_items.assigned_supplier, and rebuild_all_supplier_orders() skips
--   every row with `assigned_supplier IS NOT NULL` false. The item vanished:
--   no PO line, not unfulfillable, nothing on screen.
--
--   Secondary: t3_responsed_by_trg fired only on (current_supplier, AS1), so
--   an answer written into AS2..AS30 never refreshed responsed_by/response and
--   the stale value persisted (inquiry #2017).
--
-- THE FIX
--   1. One immutable source of truth for "which supplier answered, and what
--      did they say" — _inq_slot_answer / _inq_responder — and _inq_confirmed
--      re-expressed as "the supplier we are on right now answered Available".
--      Measured on all 116 live inquiry rows: 7 gained, 0 lost. Strict superset.
--   2. t3 widened to every AS column so the answer columns can never go stale.
--   3. Every order item now resolves to an EXPLICIT state — supplier_assigned /
--      unfulfillable / in_inquiry / cancelled / unaccounted — and a
--      reconciliation check flags any order where the states do not add up, or
--      where an assigned item is missing from its supplier's PO.
--   4. order_item_status_panel() renders the customer order tab's item list
--      backend-side: per-item status label, the supplier being asked right now
--      or the one that accepted, and the reconciliation banner.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Inquiry answer primitives
-- ─────────────────────────────────────────────────────────────────────────────

-- The answer sitting in the AS slot that belongs to p_supplier's own PS slot.
-- NULL when that supplier is not on the ladder or has not answered.
CREATE OR REPLACE FUNCTION public._inq_slot_answer(i inquiry, p_supplier text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT a.ans
    FROM generate_series(1,30) n
    CROSS JOIN LATERAL (SELECT to_jsonb(i)->>('PS'||n) AS ps,
                               to_jsonb(i)->>('AS'||n) AS ans) a
   WHERE p_supplier IS NOT NULL
     AND btrim(p_supplier) <> ''
     AND a.ps = p_supplier
   ORDER BY n
   LIMIT 1
$$;

-- The supplier whose answer describes this row: the LAST supplier at or above
-- the current one who actually answered. 'No supplier responded yet' when the
-- ladder has been asked but nobody has replied; NULL when there is no current
-- supplier at all.
--
-- This replaces "the supplier one slot before the current one", which named the
-- wrong supplier the moment the current one answered at PS2+.
CREATE OR REPLACE FUNCTION public._inq_responder(i inquiry)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  WITH live AS (
    SELECT n, a.ps, a.ans
      FROM generate_series(1,30) n
      CROSS JOIN LATERAL (SELECT to_jsonb(i)->>('PS'||n) AS ps,
                                 to_jsonb(i)->>('AS'||n) AS ans) a
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

-- Confirmed == the supplier we are on right now said Available in their OWN
-- slot. compute_current_supplier_fx only ever parks on a supplier whose answer
-- is null/empty/'Available', so this can never confirm an out-of-stock reply.
CREATE OR REPLACE FUNCTION public._inq_confirmed(i inquiry)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT i.current_supplier IS NOT NULL
     AND btrim(i.current_supplier) <> ''
     AND public._inq_slot_answer(i, i.current_supplier) = 'Available'
$$;

CREATE OR REPLACE FUNCTION public.compute_responsed_by()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.responsed_by := public._inq_responder(NEW);
  RETURN NEW;
END;
$$;

-- Widen the trigger: an answer landing in ANY AS column must refresh
-- responsed_by. Name is unchanged so BEFORE-trigger firing order (t2 -> t3 ->
-- t4 -> t5) is preserved.
DROP TRIGGER IF EXISTS t3_responsed_by_trg ON public.inquiry;
CREATE TRIGGER t3_responsed_by_trg
  BEFORE INSERT OR UPDATE OF current_supplier,
    "AS1","AS2","AS3","AS4","AS5","AS6","AS7","AS8","AS9","AS10",
    "AS11","AS12","AS13","AS14","AS15","AS16","AS17","AS18","AS19","AS20",
    "AS21","AS22","AS23","AS24","AS25","AS26","AS27","AS28","AS29","AS30"
  ON public.inquiry
  FOR EACH ROW EXECUTE FUNCTION public.compute_responsed_by();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Per-item state — nothing may silently disappear
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._order_item_states(p_order_id uuid)
RETURNS TABLE(
  order_item_id uuid, product_id bigint, product_name text, quantity numeric,
  price numeric, mrp numeric, inquiry_id bigint, assigned_supplier text,
  unfulfillable boolean, unfulfillable_reason text, cancelled boolean,
  inq_id bigint, inq_current_supplier text, inq_next_supplier text,
  inq_current_status text, inq_confirmed boolean, inq_asked_at timestamptz,
  in_po boolean, state text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT oi.id, oi.product_id, oi.product_name, oi.quantity, oi.price, oi.mrp,
         oi.inquiry_id, oi.assigned_supplier,
         coalesce(oi.unfulfillable,false), oi.unfulfillable_reason,
         (coalesce(oi.fulfillment_state,'') = 'cancelled') AS cancelled,
         i.id, i.current_supplier, i.next_supplier, i.current_status,
         coalesce(public._inq_confirmed(i.*), false), i.asked_at,
         EXISTS (
           SELECT 1 FROM supplier_orders so,
                        jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it
            WHERE oi.assigned_supplier IS NOT NULL
              AND so.supplier_name = oi.assigned_supplier
              AND so.order_date = oi.order_date
              AND coalesce(so.status,'') <> 'cancelled'
              AND nullif(it->>'product_id','')::bigint = oi.product_id
         ) AS in_po,
         CASE
           WHEN coalesce(oi.fulfillment_state,'') = 'cancelled' THEN 'cancelled'
           WHEN coalesce(oi.unfulfillable,false)                THEN 'unfulfillable'
           WHEN oi.assigned_supplier IS NOT NULL                THEN 'supplier_assigned'
           WHEN i.id IS NOT NULL                                THEN 'in_inquiry'
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
   WHERE oi.order_id = p_order_id
   ORDER BY oi.created_at, oi.id
$$;

-- The reconciliation check itself. Balanced == every non-cancelled item is
-- either on a purchase order, explicitly unfulfillable, or explicitly still
-- under inquiry — AND every assigned item actually reached its supplier's PO.
CREATE OR REPLACE FUNCTION public.order_reconcile(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v jsonb;
  v_copy jsonb := coalesce((SELECT value FROM app_settings WHERE key='order_item_panel_copy'),'{}'::jsonb);
  v_total int; v_cancelled int; v_assigned int; v_unf int; v_inq int; v_unacc int; v_nopo int;
  v_counted int; v_ok boolean; v_label text; v_detail text;
BEGIN
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
  v_ok := (v_unacc = 0 AND v_nopo = 0);

  v_label := CASE WHEN v_ok THEN coalesce(v_copy->>'reconcile_ok','')
                  ELSE coalesce(v_copy->>'reconcile_bad','') END;
  v_label := replace(replace(replace(replace(replace(replace(v_label,
               '{total}', v_counted::text),
               '{assigned}', v_assigned::text),
               '{unfulfillable}', v_unf::text),
               '{in_inquiry}', v_inq::text),
               '{unaccounted}', v_unacc::text),
               '{missing_po}', v_nopo::text);

  v_detail := CASE
    WHEN v_unacc > 0 THEN replace(coalesce(v_copy->>'detail_unaccounted',''),'{n}', v_unacc::text)
    WHEN v_nopo > 0  THEN replace(coalesce(v_copy->>'detail_missing_po',''),'{n}', v_nopo::text)
    ELSE '' END;

  v := jsonb_build_object(
    'balanced', v_ok,
    'show', true,
    'total', v_counted,
    'cancelled', v_cancelled,
    'assigned', v_assigned,
    'unfulfillable', v_unf,
    'in_inquiry', v_inq,
    'unaccounted', v_unacc,
    'missing_po', v_nopo,
    'label', v_label,
    'detail', v_detail)
    || public.tone_colors(CASE WHEN v_ok THEN 'green' ELSE 'red' END);
  RETURN v;
END;
$$;

-- Day-wide sweep: every order whose items do not reconcile.
CREATE OR REPLACE FUNCTION public.order_reconcile_audit(p_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_day date := coalesce(p_date, public.admin_active_date()); v_rows jsonb;
BEGIN
  IF public.get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'order_code'),'[]'::jsonb) INTO v_rows
  FROM (
    SELECT jsonb_build_object(
             'order_id', o.id,
             'order_code', coalesce(o.order_code,''),
             'pharmacy_name', coalesce(o.pharmacy_name,''),
             'reconcile', public.order_reconcile(o.id)) AS x
      FROM orders o
     WHERE (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_day
  ) z
  WHERE (z.x->'reconcile'->>'balanced')::boolean IS DISTINCT FROM true;

  RETURN jsonb_build_object('ok', true, 'date', v_day,
    'count', jsonb_array_length(v_rows), 'orders', v_rows);
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Backend copy for the panel (every visible string lives here)
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO app_settings (key, value)
VALUES ('order_item_panel_copy', jsonb_build_object(
  'state_supplier_assigned', 'On purchase order',
  'state_unfulfillable',     'Could not be sourced',
  'state_in_inquiry',        'Still under inquiry',
  'state_cancelled',         'Cancelled',
  'state_unaccounted',       'Not accounted for',
  'supplier_accepted',       'Accepted by {a}',
  'supplier_asking',         'Asking {a}',
  'supplier_none',           'No supplier yet',
  'next_supplier',           'Next: {a}',
  'po_missing',              'Not on the purchase order',
  'reconcile_ok',            'All {total} items accounted for',
  'reconcile_bad',           '{total} items — {assigned} on purchase orders, {unfulfillable} unfulfillable, {in_inquiry} under inquiry',
  'detail_unaccounted',      '{n} item(s) have no supplier, no inquiry and no unfulfillable reason.',
  'detail_missing_po',       '{n} assigned item(s) are missing from their supplier''s purchase order.',
  'status_unknown',          'Awaiting response'))
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The customer order tab's item panel — render-ready, backend-ordered
-- ─────────────────────────────────────────────────────────────────────────────

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
      -- The status the ladder is actually in, printed verbatim.
      'status_label',  CASE
                         WHEN s.unfulfillable THEN coalesce(nullif(btrim(coalesce(s.unfulfillable_reason,'')),''),
                                                            coalesce(v_copy->>'state_unfulfillable',''))
                         WHEN nullif(btrim(coalesce(s.inq_current_status,'')),'') IS NOT NULL
                           THEN s.inq_current_status
                         WHEN s.inq_id IS NULL THEN coalesce(v_copy->>'state_unaccounted','')
                         ELSE coalesce(v_copy->>'status_unknown','')
                       END,
      'status_colors', CASE
                         WHEN s.state = 'unfulfillable' THEN jsonb_build_object('bg','#FBE9E7','fg','#B42318')
                         WHEN s.state = 'unaccounted'   THEN jsonb_build_object('bg','#FBE9E7','fg','#B42318')
                         WHEN s.state = 'supplier_assigned' THEN jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                         WHEN s.state = 'cancelled'     THEN jsonb_build_object('bg','#EFEEE9','fg','#5A5A57')
                         ELSE jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                       END,
      -- Who is being asked right now, or who accepted. Straight off inquiry —
      -- no longer hidden behind asked_at, which is NULL for the whole manual
      -- lane and blanked this badge on every item.
      'supplier_name', coalesce(nullif(btrim(coalesce(s.assigned_supplier,'')),''),
                                nullif(btrim(coalesce(s.inq_current_supplier,'')),''), ''),
      'has_supplier',  coalesce(nullif(btrim(coalesce(s.assigned_supplier,'')),''),
                                nullif(btrim(coalesce(s.inq_current_supplier,'')),'')) IS NOT NULL,
      'supplier_label', CASE
          WHEN coalesce(nullif(btrim(coalesce(s.assigned_supplier,'')),''),
                        nullif(btrim(coalesce(s.inq_current_supplier,'')),'')) IS NULL
            THEN coalesce(v_copy->>'supplier_none','')
          WHEN s.state = 'supplier_assigned' OR s.inq_confirmed
            THEN replace(coalesce(v_copy->>'supplier_accepted',''), '{a}',
                   coalesce(nullif(btrim(coalesce(s.assigned_supplier,'')),''), s.inq_current_supplier))
          ELSE replace(coalesce(v_copy->>'supplier_asking',''), '{a}', s.inq_current_supplier)
        END,
      'next_supplier_label', CASE
          WHEN s.state <> 'supplier_assigned'
           AND nullif(btrim(coalesce(s.inq_next_supplier,'')),'') IS NOT NULL
            THEN replace(coalesce(v_copy->>'next_supplier',''), '{a}', s.inq_next_supplier)
          ELSE '' END,
      'in_po',        s.in_po,
      'po_warning',   CASE WHEN s.state = 'supplier_assigned' AND NOT s.in_po
                           THEN coalesce(v_copy->>'po_missing','') ELSE '' END,
      'unfulfillable', s.unfulfillable
    ) ORDER BY s.ordinality), '[]'::jsonb)
    INTO v_lines
    FROM public._order_item_states(p_order_id) WITH ORDINALITY AS s
    LEFT JOIN "MEDICINE" m ON m.id = s.product_id;

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'lines', v_lines,
    'count', jsonb_array_length(v_lines),
    'reconcile', public.order_reconcile(p_order_id));
END;
$$;

GRANT EXECUTE ON FUNCTION public.order_item_status_panel(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.order_reconcile(uuid)         TO authenticated;
GRANT EXECUTE ON FUNCTION public.order_reconcile_audit(date)   TO authenticated;
