-- CHANGE — journey `bug-240`, the permanent proof for the inquiry→PO date class.
--
-- dev_journeys row 19 was auto-created by _dev_bug_to_journey_trg with a TODO
-- placeholder body. This implements it, so the class of bug retires for good:
-- the fix cannot be marked complete until this journey passes, and it will keep
-- running on every future inquiry-area command.
--
-- It asserts FOUR independent things, because any one alone can be true while
-- the bug is back:
--   census      — zero live cross-date pointers
--   structure   — the guard trigger is installed AND enabled
--   readers     — the 5 display readers use inq_is_ordered; the 2 engine
--                 functions deliberately do NOT (the re-ask policy)
--   behaviour   — a cross-date write is actually REJECTED and a same-date write
--                 is actually ACCEPTED, proven by writing both
--
-- The behavioural half writes two throwaway rows and always deletes them. No
-- trigger on `inquiry` sends WhatsApp (checked: all 17 are compute/realtime), so
-- the probe cannot message a supplier.

CREATE OR REPLACE FUNCTION public._journey_bug240()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_crossed int; v_missing int;
  v_guard boolean; v_readers boolean; v_engine boolean;
  v_rejected boolean := null; v_accepted boolean := null;
  v_inq bigint; v_so uuid; v_err text := null;
  v_bad text;
  v_d1 constant date := date '2001-01-01';
  v_d2 constant date := date '2001-02-02';
  v_ok boolean;
BEGIN
  -- ── census ────────────────────────────────────────────────────────────────
  SELECT count(*)::int INTO v_crossed
    FROM inquiry i JOIN supplier_orders so ON so.id = i.supplier_order_id
   WHERE i.batch_date IS NOT NULL AND so.order_date IS DISTINCT FROM i.batch_date;

  SELECT count(*)::int INTO v_missing
    FROM inquiry i JOIN supplier_orders so ON so.id = i.supplier_order_id
   WHERE i.product_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(so.items,'[]'::jsonb)) x
                      WHERE (x->>'product_id') = i.product_id::text);

  -- ── structure ─────────────────────────────────────────────────────────────
  v_guard := EXISTS (SELECT 1 FROM pg_trigger t
                      WHERE t.tgrelid = 'public.inquiry'::regclass
                        AND t.tgname  = 'trg_inquiry_po_date_guard'
                        AND t.tgenabled <> 'D');

  -- ── readers ───────────────────────────────────────────────────────────────
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_bad
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('_get_inquiry_form_core','supplier_pending_inquiry_count',
                       'supplier_inquiry_buckets','get_supplier_inquiry_overview',
                       'get_supplier_inquiry_items')
     AND pg_get_functiondef(p.oid) NOT LIKE '%inq_is_ordered%';
  v_readers := (v_bad IS NULL);

  v_engine := NOT EXISTS (
    SELECT 1 FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('inquiry_engine_ranked_suppliers','inquiry_engine_sync')
       AND pg_get_functiondef(p.oid) LIKE '%inq_is_ordered%');

  -- ── behaviour ─────────────────────────────────────────────────────────────
  BEGIN
    INSERT INTO supplier_orders (supplier_name, order_no, order_date, status, items, total_amount)
    VALUES ('__j240_probe_supplier__', 999999, v_d2, 'pending', '[]'::jsonb, 0)
    RETURNING id INTO v_so;

    INSERT INTO inquiry (product_name, quantity, batch_date, inquiry_phase)
    VALUES ('__j240_probe__', 0, v_d1, 'draft')
    RETURNING id INTO v_inq;

    -- a cross-date pointer must be REJECTED
    BEGIN
      UPDATE inquiry SET supplier_order_id = v_so WHERE id = v_inq;
      v_rejected := false;          -- accepted -> the #240 bug is writable again
    EXCEPTION WHEN others THEN
      v_rejected := true;
    END;

    -- and a same-date pointer must still be ACCEPTED (the guard must not be a
    -- blanket block that would stop every legitimate commit)
    UPDATE supplier_orders SET order_date = v_d1 WHERE id = v_so;
    BEGIN
      UPDATE inquiry SET supplier_order_id = v_so WHERE id = v_inq;
      v_accepted := true;
    EXCEPTION WHEN others THEN
      v_accepted := false;
    END;
  EXCEPTION WHEN others THEN
    v_err := sqlerrm;
  END;

  -- cleanup ALWAYS, whatever happened above
  BEGIN
    DELETE FROM inquiry         WHERE id = v_inq;
    DELETE FROM supplier_orders WHERE id = v_so;
  EXCEPTION WHEN others THEN NULL;
  END;

  v_ok := v_crossed = 0
      AND v_missing = 0
      AND COALESCE(v_guard,false)
      AND COALESCE(v_readers,false)
      AND COALESCE(v_engine,false)
      AND COALESCE(v_rejected,false)
      AND COALESCE(v_accepted,false);

  RETURN jsonb_build_object(
    'status', CASE WHEN v_ok THEN 'passed' ELSE 'failed' END,
    'evidence', jsonb_build_object(
      'db_proof',
        'cross-date pointers='||v_crossed::text
        ||' | linked-but-absent-from-PO='||v_missing::text
        ||' | guard trigger enabled='||COALESCE(v_guard,false)::text
        ||' | display readers use inq_is_ordered='||COALESCE(v_readers,false)::text
        ||' | engine kept OFF the predicate='||COALESCE(v_engine,false)::text
        ||' | cross-date write REJECTED='||COALESCE(v_rejected::text,'null')
        ||' | same-date write ACCEPTED='||COALESCE(v_accepted::text,'null'),
      'readers_missing_predicate', COALESCE(v_bad,''),
      'probe_cleaned_up', NOT EXISTS (SELECT 1 FROM inquiry WHERE product_name = '__j240_probe__')
                      AND NOT EXISTS (SELECT 1 FROM supplier_orders WHERE supplier_name = '__j240_probe_supplier__'),
      'error', v_err));
END;
$function$;

COMMENT ON FUNCTION public._journey_bug240() IS
  'CHANGE #240 — journey bug-240. Census + structure + reader split + a real write test that the guard rejects a cross-date pointer and still accepts a same-date one.';

GRANT EXECUTE ON FUNCTION public._journey_bug240() TO service_role;

-- Delegate from dev_journey_probe. Spliced into the existing body rather than
-- re-emitting ~300 lines of it, so no other journey can be damaged in passing.
DO $splice$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname='dev_journey_probe';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'dev_journey_probe not found';
  END IF;

  IF v_src LIKE '%_journey_bug240%' THEN
    RAISE NOTICE 'CHANGE #240: dev_journey_probe already delegates bug-240';
    RETURN;
  END IF;

  v_new := replace(
    v_src,
    E'begin\n\n  -- CHANGE #197',
    E'begin\n\n  -- CHANGE #240 — inquiry->PO date integrity (see _journey_bug240).\n'
    || E'  if p_name = ''bug-240'' then return public._journey_bug240(); end if;\n\n  -- CHANGE #197');

  IF v_new = v_src THEN
    RAISE EXCEPTION 'CHANGE #240: could not splice bug-240 into dev_journey_probe (anchor moved)';
  END IF;

  EXECUTE v_new;
  RAISE NOTICE 'CHANGE #240: bug-240 delegation spliced into dev_journey_probe';
END;
$splice$;

-- The journey itself: replace the auto-generated TODO with the real thing.
-- `required` is deliberately NOT set here — dev_journeys_run promotes a journey
-- to required only after it has passed GREEN TWICE, and that rule is not one a
-- migration may shortcut.
UPDATE public.dev_journeys
   SET area  = 'inquiry',
       kind  = 'api',
       steps = jsonb_build_array(
         'Census: count inquiry rows whose supplier_order_id points at a supplier_orders row with a different order_date than the line''s own batch_date.',
         'Census: count inquiry rows flagged as ordered whose product_id is absent from that PO''s items[].',
         'Structure: assert trg_inquiry_po_date_guard exists on public.inquiry and is enabled.',
         'Readers: assert the 5 display readers (_get_inquiry_form_core, supplier_pending_inquiry_count, supplier_inquiry_buckets, get_supplier_inquiry_overview, get_supplier_inquiry_items) decide "already ordered" via inq_is_ordered().',
         'Readers: assert inquiry_engine_ranked_suppliers and inquiry_engine_sync do NOT use inq_is_ordered, so a stale pointer can never fire an unsolicited supplier WhatsApp.',
         'Behaviour: insert a throwaway PO dated 2001-02-02 and a throwaway inquiry line dated 2001-01-01, then attempt to link them — the write MUST be rejected.',
         'Behaviour: move the PO to 2001-01-01 and link again — the write MUST now be accepted, proving the guard is date-aware and not a blanket block.',
         'Cleanup: delete both throwaway rows and assert none remain.'),
       assertions = jsonb_build_array(
         'cross-date pointers = 0',
         'linked-but-absent-from-PO = 0',
         'trg_inquiry_po_date_guard enabled = true',
         'all 5 display readers use inq_is_ordered = true',
         'neither engine function uses inq_is_ordered = true',
         'cross-date write rejected = true',
         'same-date write accepted = true',
         'probe rows cleaned up = true')
 WHERE name = 'bug-240';
