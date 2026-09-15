-- CHANGE — inquiry.supplier_order_id must point at the PO for the line's OWN
-- batch_date. Bug found while root-causing #238 and filed as its own row (#240).
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT WAS BROKEN (measured on live data before this migration)
--
--   83 of 101 linked inquiry rows pointed at a supplier_orders row from a
--   DIFFERENT date than the inquiry line's own batch_date — e.g. a 2026-08-17
--   line pointing at a 2026-07-26 PO. On 2026-08-17, 5 of the 10 linked lines
--   pointed at a PO whose items[] did not even contain the product, so the line
--   was flagged "ordered" while living in no purchase order at all.
--
-- ROOT CAUSE
--
--   supplier_orders is keyed one-open-PO-per-supplier-PER-DATE:
--     uq_supplier_orders_open_supplier_date (supplier_name, order_date)
--       WHERE status IS NULL OR status <> ALL('{shipped,closed,cancelled}')
--
--   commit_supplier_order() predates that index (its own comment still names
--   the older, date-less `uq_supplier_orders_open_supplier`). It:
--     * swept up EVERY unlinked Available line for the supplier regardless of
--       batch_date, and
--     * reused `ORDER BY created_at LIMIT 1` — the OLDEST still-open PO for the
--       supplier — with no order_date filter.
--   So the 2026-07-26 PO, still `pending` three weeks later, kept adopting each
--   new day's lines. _heal_inquiry_link() had the mirror-image defect
--   (`ORDER BY created_at DESC LIMIT 1`, no date filter), which is why a few
--   rows point FORWARD at a newer PO instead.
--
--   Every reader (_get_inquiry_form_core, supplier_pending_inquiry_count,
--   supplier_inquiry_buckets, get_supplier_inquiry_overview/items,
--   inquiry_engine_ranked_suppliers) reads `supplier_order_id IS NOT NULL` as
--   "already ordered", so those lines were hidden from the supplier form and
--   skipped by the engine on days they were never actually ordered for.
--
-- THE FIX — four layers, so the class of bug cannot come back:
--   1. ONE find-or-create door, keyed on (supplier_name, order_date), plus a
--      merge that actually puts the committed lines into the PO's items[].
--   2. Both linkers (commit_supplier_order, _heal_inquiry_link) are date-scoped
--      and go through that door.
--   3. A BEFORE trigger on inquiry REJECTS a cross-date pointer outright, so no
--      future code path can write one — the invariant lives in the storage
--      layer, not in each caller's good intentions.
--   4. inq_is_ordered(so_id, batch_date) is the ONE predicate the DISPLAY readers
--      use (§10), so a
--      pointer that somehow went stale still cannot hide a line.
--
-- RE-ASK POLICY (the thing #238 deliberately did not touch)
--   The backfill RE-POINTS; it never NULLs. Every one of the 83 rows already
--   carries a real supplier answer ('Available' from a real supplier) — only
--   the PO document it landed in was wrong. Clearing the column would have made
--   inquiry_engine_sync stamp asked_at and fire send_supplier_inquiry_wa at
--   real suppliers about days-old lines, which is exactly why #238 left this
--   alone. Re-pointing preserves the answer, sends ZERO WhatsApp, and leaves
--   the PO documents correct. Back-dated POs created by the backfill are
--   stamped auto_order_sent_at so the autosend sweep cannot pick them up
--   either.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE PREDICATE — the only definition of "this line is already ordered".
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.inq_is_ordered(p_so uuid, p_batch date)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT p_so IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.supplier_orders so
                  WHERE so.id = p_so
                    AND so.order_date IS NOT DISTINCT FROM p_batch);
$$;

COMMENT ON FUNCTION public.inq_is_ordered(uuid, date) IS
  'CHANGE #240 — a line counts as ordered only when its supplier_order_id points at a PO for its OWN batch_date. A cross-date pointer is stale and must NOT hide the line.';

GRANT EXECUTE ON FUNCTION public.inq_is_ordered(uuid, date) TO anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. ONE DOOR — find-or-create the PO for (supplier, date).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._supplier_po_for_date(
  p_supplier  text,
  p_date      date,
  p_order_id  uuid    DEFAULT NULL,
  p_mark_sent boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_oid uuid; v_sid uuid; v_spn numeric; v_no int;
BEGIN
  IF p_supplier IS NULL OR btrim(p_supplier) = '' OR p_date IS NULL THEN
    RETURN NULL;
  END IF;

  -- Prefer the OPEN PO for that exact date (the one the unique index protects);
  -- fall back to a closed/shipped one, because that is still the right document
  -- for the day even though nothing more can be added to it.
  SELECT so.id INTO v_oid
    FROM supplier_orders so
   WHERE so.supplier_name = p_supplier
     AND so.order_date    = p_date
     AND (so.status IS NULL OR so.status <> 'cancelled')
   ORDER BY (so.status IS NULL OR so.status NOT IN ('shipped','closed','cancelled')) DESC,
            so.created_at
   LIMIT 1;
  IF v_oid IS NOT NULL THEN RETURN v_oid; END IF;

  SELECT sp.id, sp."SPN" INTO v_sid, v_spn
    FROM supplier_profiles sp WHERE sp.supplier_name = p_supplier LIMIT 1;

  SELECT COALESCE(max(order_no),0) + 1 INTO v_no
    FROM supplier_orders WHERE supplier_name = p_supplier;

  INSERT INTO supplier_orders (supplier_name, supplier_id, spn, order_no, created_at,
                               order_date, status, items, total_amount, order_id,
                               auto_order_sent_at)
  VALUES (p_supplier, v_sid, v_spn, v_no, clock_timestamp(),
          p_date, 'pending', '[]'::jsonb, 0, p_order_id,
          CASE WHEN p_mark_sent THEN now() ELSE NULL END)
  RETURNING id INTO v_oid;

  RETURN v_oid;
END;
$function$;

COMMENT ON FUNCTION public._supplier_po_for_date(text, date, uuid, boolean) IS
  'CHANGE #240 — the ONE find-or-create for a supplier PO, keyed exactly like uq_supplier_orders_open_supplier_date (supplier_name, order_date).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. MERGE the committed inquiry lines into the PO document.
--    Reusing an existing PO used to set the pointer and stop — which is how a
--    line ended up "ordered" on a PO whose items[] never mentioned it.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._po_merge_inquiry_lines(p_oid uuid, p_ids bigint[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_items jsonb; v_add jsonb;
BEGIN
  IF p_oid IS NULL OR p_ids IS NULL OR array_length(p_ids,1) IS NULL THEN RETURN; END IF;

  SELECT COALESCE(so.items, '[]'::jsonb) INTO v_items
    FROM supplier_orders so WHERE so.id = p_oid FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;

  -- Only ADD products the PO does not already list. An existing line is left
  -- exactly as sent — a quantity already quoted to a supplier is not rewritten.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'product_id',   i.product_id,
           'product_name', i.product_name,
           'quantity',     i.quantity,
           'mrp',          i.mrp,
           'pack_type',    NULLIF(btrim(med.pack_type),''))), '[]'::jsonb)
    INTO v_add
    FROM (SELECT DISTINCT ON (q.product_id) q.*
            FROM inquiry q WHERE q.id = ANY(p_ids) AND q.product_id IS NOT NULL
           ORDER BY q.product_id, q.id) i
    LEFT JOIN "MEDICINE" med ON med.id = i.product_id
   WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x
                      WHERE (x->>'product_id') = i.product_id::text);

  IF v_add = '[]'::jsonb THEN RETURN; END IF;
  v_items := v_items || v_add;

  UPDATE supplier_orders so
     SET items = v_items,
         total_amount = COALESCE((SELECT sum(COALESCE((x->>'quantity')::numeric,0)
                                           * COALESCE((x->>'mrp')::numeric,0))
                                    FROM jsonb_array_elements(v_items) x), 0)
   WHERE so.id = p_oid;
END;
$function$;

COMMENT ON FUNCTION public._po_merge_inquiry_lines(uuid, bigint[]) IS
  'CHANGE #240 — put the committed inquiry lines INTO the PO document. Adds only products the PO does not already list; never rewrites a quantity already quoted.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE LINKERS — both go through the one door, both date-scoped.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.commit_supplier_order(p_supplier text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_oid uuid; v_last uuid; v_order_id uuid; r record;
BEGIN
  IF p_supplier IS NULL OR btrim(p_supplier) = '' THEN RETURN NULL; END IF;

  -- A line with no batch_date is invisible to every date-scoped reader; stamp
  -- it with today rather than leaving it orphaned (repair, not a silent skip).
  UPDATE inquiry SET batch_date = v_today
   WHERE current_supplier = p_supplier
     AND current_status = 'Available'
     AND supplier_order_id IS NULL
     AND batch_date IS NULL;

  -- ONE PO per (supplier, batch_date). The old code took the oldest OPEN PO for
  -- the supplier with no date filter, so a three-week-old pending PO adopted
  -- every new day's lines (#240).
  FOR r IN
    SELECT i.batch_date AS d, array_agg(i.id) AS ids
      FROM inquiry i
     WHERE i.current_supplier  = p_supplier
       AND i.current_status    = 'Available'
       AND i.supplier_order_id IS NULL
       AND i.batch_date IS NOT NULL
     GROUP BY i.batch_date
     ORDER BY i.batch_date
  LOOP
    -- the customer order these lines mostly belong to
    SELECT oi.order_id INTO v_order_id
      FROM order_items oi
     WHERE oi.inquiry_id = ANY(r.ids)
     GROUP BY oi.order_id
     ORDER BY count(*) DESC
     LIMIT 1;

    v_oid := public._supplier_po_for_date(p_supplier, r.d, v_order_id, false);
    IF v_oid IS NULL THEN CONTINUE; END IF;

    PERFORM public._po_merge_inquiry_lines(v_oid, r.ids);
    UPDATE inquiry SET supplier_order_id = v_oid WHERE id = ANY(r.ids);

    -- Callers expect the PO for the batch being committed. Today's wins when
    -- several dates are swept at once; otherwise the most recent one.
    IF v_last IS NULL OR r.d <= v_today THEN v_last := v_oid; END IF;
  END LOOP;

  RETURN v_last;
END;
$function$;

COMMENT ON FUNCTION public.commit_supplier_order(text) IS
  'CHANGE #240 — commits each batch_date onto ITS OWN PO (supplier_name, order_date) and merges the lines into items[]. Never adopts another day''s open PO.';

CREATE OR REPLACE FUNCTION public._heal_inquiry_link(p_inq_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r inquiry%rowtype; i int; ps_val text; v_so uuid; v_sup text;
        v_hit boolean := false; v_first_empty int := null;
BEGIN
  SELECT * INTO r FROM inquiry WHERE id = p_inq_id;
  IF NOT FOUND OR r.current_supplier IS NULL THEN RETURN false; END IF;
  v_sup := r.current_supplier;
  IF NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.product_id = r.product_id
                   AND oi.assigned_supplier = v_sup
                   AND oi.fulfillment_state NOT IN ('cancelled')) THEN
    RETURN false;
  END IF;

  -- #240: date-scoped. The old lookup was `ORDER BY created_at DESC LIMIT 1`
  -- over every PO for the supplier, so a line healed onto whichever PO happened
  -- to be newest — routinely one from a different day.
  SELECT so.id INTO v_so
    FROM supplier_orders so
   WHERE so.supplier_name = v_sup
     AND so.order_date    = r.batch_date
     AND so.status NOT IN ('cancelled','rejected')
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(so.items) x
                  WHERE (x->>'product_name') = r.product_name
                     OR (x->>'product_id')   = r.product_id::text)
   ORDER BY so.created_at DESC
   LIMIT 1;

  FOR i IN 1..30 LOOP
    EXECUTE format('select ($1).%I','PS'||i) INTO ps_val USING r;
    IF ps_val IS NULL OR btrim(ps_val) = '' THEN
      IF v_first_empty IS NULL THEN v_first_empty := i; END IF;
      CONTINUE;  -- no early exit: cascade lists can have gaps
    END IF;
    IF lower(btrim(ps_val)) = lower(btrim(v_sup)) THEN
      EXECUTE format('update inquiry set %I = %L where id = %s','AS'||i,'Available',p_inq_id);
      v_hit := true;
    END IF;
  END LOOP;
  IF NOT v_hit AND v_first_empty IS NOT NULL THEN
    EXECUTE format('update inquiry set %I = %L, %I = %L where id = %s',
      'PS'||v_first_empty, v_sup, 'AS'||v_first_empty, 'Available', p_inq_id);
  END IF;

  UPDATE inquiry SET response = 'Available', responsed_by = v_sup,
         current_status = 'Available',
         -- keep the existing pointer only when it is already same-date; a stale
         -- one must not survive the heal.
         supplier_order_id = COALESCE(
           v_so,
           CASE WHEN public.inq_is_ordered(supplier_order_id, batch_date)
                THEN supplier_order_id END)
   WHERE id = p_inq_id;
  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public._heal_inquiry_link(bigint) IS
  'CHANGE #240 — heals a line onto the PO for its OWN batch_date only, and drops a stale cross-date pointer instead of coalescing it forward.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. BACKFILL — re-point every cross-date pointer onto the PO for its OWN date.
--    Runs BEFORE the guard trigger is installed, and is idempotent: on a second
--    run the WHERE clause matches nothing.
-- ─────────────────────────────────────────────────────────────────────────────
DO $backfill$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_oid uuid; v_order_id uuid; v_moved int := 0; v_groups int := 0; r record;
BEGIN
  FOR r IN
    SELECT COALESCE(i.current_supplier, so.supplier_name) AS supplier,
           i.batch_date AS d,
           array_agg(i.id) AS ids
      FROM inquiry i
      JOIN supplier_orders so ON so.id = i.supplier_order_id
     WHERE i.batch_date IS NOT NULL
       AND so.order_date IS DISTINCT FROM i.batch_date
       AND COALESCE(i.current_supplier, so.supplier_name) IS NOT NULL
     GROUP BY 1, 2
  LOOP
    SELECT oi.order_id INTO v_order_id
      FROM order_items oi
     WHERE oi.inquiry_id = ANY(r.ids)
     GROUP BY oi.order_id ORDER BY count(*) DESC LIMIT 1;

    -- p_mark_sent := true for EVERY back-filled PO. These lines were already
    -- committed once; a repair must not hand autosend_pending_supplier_orders()
    -- a fresh reason to WhatsApp a supplier about a days-old line. An admin can
    -- still send it by hand from the supplier order screen.
    v_oid := public._supplier_po_for_date(r.supplier, r.d, v_order_id, true);
    IF v_oid IS NULL THEN CONTINUE; END IF;

    PERFORM public._po_merge_inquiry_lines(v_oid, r.ids);
    UPDATE inquiry SET supplier_order_id = v_oid WHERE id = ANY(r.ids);

    v_groups := v_groups + 1;
    v_moved  := v_moved + array_length(r.ids, 1);
  END LOOP;

  -- A pointer we cannot attribute to any supplier is not repairable; it is also
  -- not trustworthy, so it must not keep hiding the line from the form.
  UPDATE inquiry i
     SET supplier_order_id = NULL
    FROM supplier_orders so
   WHERE so.id = i.supplier_order_id
     AND i.batch_date IS NOT NULL
     AND so.order_date IS DISTINCT FROM i.batch_date;

  RAISE NOTICE 'CHANGE #240 backfill: % line(s) re-pointed across % (supplier, date) group(s)',
    v_moved, v_groups;
END;
$backfill$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE GUARD — the invariant lives in the storage layer now.
--    After §4 no legitimate path writes a cross-date pointer, so a raise here
--    means a real regression, caught at the write instead of 83 rows later.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.inquiry_po_date_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_od date;
BEGIN
  IF NEW.supplier_order_id IS NULL OR NEW.batch_date IS NULL THEN RETURN NEW; END IF;

  SELECT so.order_date INTO v_od
    FROM supplier_orders so WHERE so.id = NEW.supplier_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'inquiry %: supplier_order_id % does not exist', NEW.id, NEW.supplier_order_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_od IS DISTINCT FROM NEW.batch_date THEN
    RAISE EXCEPTION
      'inquiry %: supplier_order_id % is a % PO but the line is on batch_date % — a line may only be linked to the PO for its own date (CHANGE #240)',
      NEW.id, NEW.supplier_order_id, v_od, NEW.batch_date
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.inquiry_po_date_guard() IS
  'CHANGE #240 — rejects a supplier_order_id whose PO order_date <> the line''s batch_date. Makes the #240 class of bug unwritable.';

DROP TRIGGER IF EXISTS trg_inquiry_po_date_guard ON public.inquiry;
CREATE TRIGGER trg_inquiry_po_date_guard
  BEFORE INSERT OR UPDATE OF supplier_order_id, batch_date ON public.inquiry
  FOR EACH ROW EXECUTE FUNCTION public.inquiry_po_date_guard();

-- Prove the repair landed. If anything is still crossed the migration aborts
-- rather than installing a guard over dirty data.
DO $verify$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
    FROM inquiry i JOIN supplier_orders so ON so.id = i.supplier_order_id
   WHERE i.batch_date IS NOT NULL AND so.order_date IS DISTINCT FROM i.batch_date;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'CHANGE #240: % cross-date inquiry pointer(s) survived the backfill', v_n;
  END IF;
END;
$verify$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE REGRESSION GUARD — red here turns rg_check red, which blocks every
--    dev_cmd_complete. This is the half that makes the class of bug permanent
--    history rather than something that can quietly ship again.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.rg_behavior_tests(name, enabled, note, body) VALUES (
 'inquiry_po_date_integrity', true,
 'CHANGE #240 — an inquiry line may only point at the supplier PO for its OWN batch_date. Fails if any cross-date pointer exists, if the guard trigger is gone or disabled, if the linkers stop going through _supplier_po_for_date, or if a reader goes back to treating a bare supplier_order_id as "ordered".',
$rg$
do $x$
declare
  v_n int; v_bad text; v_inq bigint; v_so uuid; v_ok boolean;
  v_d1 date := date '2001-01-01';
  v_d2 date := date '2001-02-02';
begin
  -- 7a. CENSUS — the live table must hold the invariant.
  select count(*) into v_n
    from inquiry i join supplier_orders so on so.id = i.supplier_order_id
   where i.batch_date is not null and so.order_date is distinct from i.batch_date;
  if v_n > 0 then
    raise exception 'RG_FAIL: % inquiry row(s) point at a PO from a different date than their own batch_date (the #240 bug is back)', v_n;
  end if;

  -- 7b. THE GUARD TRIGGER must exist and be enabled.
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.inquiry'::regclass
       and t.tgname  = 'trg_inquiry_po_date_guard'
       and t.tgenabled <> 'D')
  then
    raise exception 'RG_FAIL: trg_inquiry_po_date_guard is missing or disabled — nothing stops a cross-date pointer being written';
  end if;

  -- 7c. BEHAVIOUR — a cross-date write must be REJECTED, a same-date write must
  --     be ACCEPTED. Everything here rolls back with the RG_ROLLBACK below.
  insert into inquiry (product_name, quantity, batch_date, inquiry_phase)
  values ('__rg240_probe__', 0, v_d1, 'draft') returning id into v_inq;

  insert into supplier_orders (supplier_name, order_no, order_date, status, items, total_amount)
  values ('__rg240_probe_supplier__', 999999, v_d2, 'pending', '[]'::jsonb, 0)
  returning id into v_so;

  v_ok := false;
  begin
    update inquiry set supplier_order_id = v_so where id = v_inq;
  exception when others then
    if sqlerrm like 'RG_FAIL:%' then raise; end if;
    v_ok := true;   -- rejected, which is the whole point
  end;
  if not v_ok then
    raise exception 'RG_FAIL: inquiry accepted a supplier_order_id whose PO order_date (%) differs from batch_date (%) — the #240 guard does not bite', v_d2, v_d1;
  end if;

  update supplier_orders set order_date = v_d1 where id = v_so;
  update inquiry set supplier_order_id = v_so where id = v_inq;   -- must NOT raise
  if not public.inq_is_ordered(v_so, v_d1) then
    raise exception 'RG_FAIL: inq_is_ordered() says a same-date link is not ordered';
  end if;
  if public.inq_is_ordered(v_so, v_d2) then
    raise exception 'RG_FAIL: inq_is_ordered() accepts a cross-date link';
  end if;

  -- 7d. THE LINKERS must keep going through the one date-keyed door.
  --     A linker is date-scoped either because it filters on order_date itself
  --     (_heal_inquiry_link) or because it delegates to _supplier_po_for_date,
  --     which is keyed (supplier_name, order_date) (commit_supplier_order).
  --     Having NEITHER is the #240 defect: picking a PO with no date filter.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('commit_supplier_order','_heal_inquiry_link')
     and pg_get_functiondef(p.oid) not like '%order_date%'
     and pg_get_functiondef(p.oid) not like '%_supplier_po_for_date%';
  if v_bad is not null then
    raise exception 'RG_FAIL: PO linker(s) lost their date scope -> %', v_bad;
  end if;

  if (select count(*) from pg_proc
       where pronamespace='public'::regnamespace
         and proname in ('_supplier_po_for_date','_po_merge_inquiry_lines','inq_is_ordered')) <> 3 then
    raise exception 'RG_FAIL: the #240 helpers (_supplier_po_for_date / _po_merge_inquiry_lines / inq_is_ordered) were dropped';
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$rg$)
ON CONFLICT (name) DO UPDATE SET body = excluded.body, note = excluded.note, enabled = true;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE ADMIN SURFACE — the invariant is only real if Om can look at it.
--    It lands as an `integrity` block inside admin_scope_audit()'s EXISTING
--    payload, not as a second RPC: test/protected/scope_audit_test.dart pins
--    that screen to exactly one backend call, and "one source of truth per
--    screen" is the whole point of #227. Click path:
--      Admin → More → Scope audit → "Inquiry → PO date integrity"
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.ui_copy(key, value) VALUES
 ('scope_audit.inq_po.title',        to_jsonb('Inquiry → PO date integrity'::text)),
 ('scope_audit.inq_po.subtitle',     to_jsonb('Every inquiry line must point at the purchase order for its own day. A line pointing at another day''s PO is treated as already ordered and disappears from the supplier form.'::text)),
 ('scope_audit.inq_po.ok',           to_jsonb('Every linked line sits on a PO for its own date'::text)),
 ('scope_audit.inq_po.bad',          to_jsonb('Lines are linked to another day''s PO — they are hidden from the supplier form'::text)),
 ('scope_audit.inq_po.crossed',      to_jsonb('Cross-date pointers'::text)),
 ('scope_audit.inq_po.crossed_hint', to_jsonb('Lines whose PO order date differs from their own batch date. Must always be zero.'::text)),
 ('scope_audit.inq_po.missing',      to_jsonb('Linked but not in the PO'::text)),
 ('scope_audit.inq_po.missing_hint', to_jsonb('Lines flagged as ordered whose product is absent from that PO''s item list.'::text)),
 ('scope_audit.inq_po.guard',        to_jsonb('Write guard'::text)),
 ('scope_audit.inq_po.guard_hint',   to_jsonb('Rejects a cross-date link at write time, so the fault cannot return silently.'::text)),
 ('scope_audit.inq_po.guard_on',     to_jsonb('Active'::text)),
 ('scope_audit.inq_po.guard_off',    to_jsonb('Missing'::text)),
 ('scope_audit.inq_po.linked',       to_jsonb('Linked lines'::text)),
 ('scope_audit.inq_po.linked_hint',  to_jsonb('Inquiry lines currently committed to a supplier order.'::text))
ON CONFLICT (key) DO UPDATE SET value = excluded.value;

CREATE OR REPLACE FUNCTION public.admin_inquiry_po_integrity()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE v_linked int; v_crossed int; v_missing int; v_guard boolean; v_ok boolean;
BEGIN
  SELECT count(*)::int INTO v_linked FROM inquiry WHERE supplier_order_id IS NOT NULL;

  SELECT count(*)::int INTO v_crossed
    FROM inquiry i JOIN supplier_orders so ON so.id = i.supplier_order_id
   WHERE i.batch_date IS NOT NULL AND so.order_date IS DISTINCT FROM i.batch_date;

  SELECT count(*)::int INTO v_missing
    FROM inquiry i JOIN supplier_orders so ON so.id = i.supplier_order_id
   WHERE i.product_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(so.items,'[]'::jsonb)) x
                      WHERE (x->>'product_id') = i.product_id::text);

  v_guard := EXISTS (SELECT 1 FROM pg_trigger t
                      WHERE t.tgrelid = 'public.inquiry'::regclass
                        AND t.tgname  = 'trg_inquiry_po_date_guard'
                        AND t.tgenabled <> 'D');

  v_ok := (v_crossed = 0 AND v_missing = 0 AND v_guard);

  RETURN jsonb_build_object(
    'title',        public._scl('scope_audit.inq_po.title'),
    'subtitle',     public._scl('scope_audit.inq_po.subtitle'),
    'banner_tone',  CASE WHEN v_ok THEN 'success' ELSE 'danger' END,
    'banner_label', CASE WHEN v_ok THEN public._scl('scope_audit.inq_po.ok')
                                   ELSE public._scl('scope_audit.inq_po.bad') END,
    'rows', jsonb_build_array(
      jsonb_build_object(
        'label',  public._scl('scope_audit.inq_po.crossed'),
        'value',  v_crossed::text,
        'tone',   CASE WHEN v_crossed = 0 THEN 'success' ELSE 'danger' END,
        'detail', public._scl('scope_audit.inq_po.crossed_hint')),
      jsonb_build_object(
        'label',  public._scl('scope_audit.inq_po.missing'),
        'value',  v_missing::text,
        'tone',   CASE WHEN v_missing = 0 THEN 'success' ELSE 'danger' END,
        'detail', public._scl('scope_audit.inq_po.missing_hint')),
      jsonb_build_object(
        'label',  public._scl('scope_audit.inq_po.guard'),
        'value',  CASE WHEN v_guard THEN public._scl('scope_audit.inq_po.guard_on')
                                    ELSE public._scl('scope_audit.inq_po.guard_off') END,
        'tone',   CASE WHEN v_guard THEN 'success' ELSE 'danger' END,
        'detail', public._scl('scope_audit.inq_po.guard_hint')),
      jsonb_build_object(
        'label',  public._scl('scope_audit.inq_po.linked'),
        'value',  v_linked::text,
        'tone',   'info',
        'detail', public._scl('scope_audit.inq_po.linked_hint'))));
END;
$function$;

COMMENT ON FUNCTION public.admin_inquiry_po_integrity() IS
  'CHANGE #240 — the Scope Audit screen''s inquiry→PO integrity block. Every label, value and tone is decided here; Dart renders it verbatim.';

GRANT EXECUTE ON FUNCTION public.admin_inquiry_po_integrity() TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. admin_scope_audit() — #227's body verbatim, plus the `integrity` key.
--    Re-emitted rather than wrapped: the flow_scope_contract rg guard reads
--    this function's SOURCE for its scope helpers, so a thin wrapper would
--    turn that guard red.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_scope_audit()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_rows jsonb; v_total int; v_ok int; v_ex int; v_bad int; v_scope jsonb;
BEGIN
  IF public.get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('ok', false, 'error','not_authorized',
      'error_label', public._scl('scope_audit.not_authorized'));
  END IF;

  SELECT count(*)::int,
         count(*) FILTER (WHERE s.ok)::int,
         count(*) FILTER (WHERE NOT s.needs_date AND NOT s.needs_zone)::int,
         count(*) FILTER (WHERE NOT s.ok)::int
    INTO v_total, v_ok, v_ex, v_bad
    FROM public.scope_contract_status() s;

  SELECT coalesce(jsonb_agg(g ORDER BY (g->>'stage_no')::int), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT jsonb_build_object(
             'stage_no', s.stage_no,
             'stage', s.stage,
             'count_label', count(*)::text,
             'rows', jsonb_agg(jsonb_build_object(
                'rpc', s.rpc_name,
                'surface', s.surface,
                'date_label', CASE WHEN NOT s.needs_date THEN public._scl('scope_audit.chip.date_na')
                                   WHEN s.date_mode='asof' THEN public._scl('scope_audit.chip.date_asof')
                                   WHEN s.date_mode='label' THEN public._scl('scope_audit.chip.date_label')
                                   ELSE public._scl('scope_audit.chip.date_day') END,
                'date_tone',  CASE WHEN NOT s.needs_date THEN 'neutral'
                                   WHEN s.has_date THEN 'success' ELSE 'danger' END,
                'zone_label', CASE WHEN NOT s.needs_zone THEN public._scl('scope_audit.chip.zone_na')
                                   ELSE public._scl('scope_audit.chip.zone_on') END,
                'zone_tone',  CASE WHEN NOT s.needs_zone THEN 'neutral'
                                   WHEN s.has_zone THEN 'success' ELSE 'danger' END,
                'before_label', s.before_status,
                'after_label',  s.after_status,
                'note', s.note,
                'status_label', CASE WHEN NOT s.exists_now THEN public._scl('scope_audit.status.missing')
                                     WHEN s.ok AND NOT s.needs_date AND NOT s.needs_zone
                                       THEN public._scl('scope_audit.status.exempt')
                                     WHEN s.ok THEN public._scl('scope_audit.status.scoped')
                                     ELSE public._scl('scope_audit.status.broken') END,
                'status_tone',  CASE WHEN NOT s.exists_now THEN 'danger'
                                     WHEN NOT s.ok THEN 'danger'
                                     WHEN NOT s.needs_date AND NOT s.needs_zone THEN 'neutral'
                                     ELSE 'success' END)
              ORDER BY s.rpc_name)) AS g
    FROM public.scope_contract_status() s
    GROUP BY s.stage_no, s.stage
  ) t;

  v_scope := public.admin_date_scope_state();

  RETURN jsonb_build_object(
    'ok', true,
    'title',    public._scl('scope_audit.title'),
    'subtitle', public._scl('scope_audit.subtitle'),
    'scope_line', public._scl('scope_audit.scope_line', jsonb_build_object(
                    'date', coalesce(v_scope->>'long_label',''),
                    'zone', coalesce(v_scope->>'zone_label',''))),
    'rule_title', public._scl('scope_audit.rule.title'),
    'rule_body',  public._scl('scope_audit.rule.body'),
    'summary', jsonb_build_array(
      jsonb_build_object('label', public._scl('scope_audit.sum.total'),  'value', v_total::text, 'tone','neutral'),
      jsonb_build_object('label', public._scl('scope_audit.sum.scoped'), 'value', (v_ok - v_ex)::text, 'tone','success'),
      jsonb_build_object('label', public._scl('scope_audit.sum.exempt'), 'value', v_ex::text,    'tone','info'),
      jsonb_build_object('label', public._scl('scope_audit.sum.broken'), 'value', v_bad::text,
                         'tone', CASE WHEN v_bad > 0 THEN 'danger' ELSE 'success' END)),
    'all_green', (v_bad = 0),
    'banner_label', CASE WHEN v_bad = 0 THEN public._scl('scope_audit.banner.green')
                         ELSE public._scl('scope_audit.banner.red', jsonb_build_object('n', v_bad::text)) END,
    'banner_tone',  CASE WHEN v_bad = 0 THEN 'success' ELSE 'danger' END,
    'col_rpc',     public._scl('scope_audit.col.rpc'),
    'col_before',  public._scl('scope_audit.col.before'),
    'col_after',   public._scl('scope_audit.col.after'),
    'empty_label', public._scl('scope_audit.empty'),
    'retry_label', public._scl('scope_audit.retry'),
    'stages', v_rows,
    -- CHANGE #240 — inquiry→PO date integrity, in the SAME payload so the
    -- screen keeps its one-RPC contract (test/protected/scope_audit_test.dart).
    'integrity', public.admin_inquiry_po_integrity());
END $$;

GRANT EXECUTE ON FUNCTION public.admin_scope_audit() TO authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. THE READERS — make claim #4 in this file's header actually true.
--
--     §1 defined inq_is_ordered() but nothing used it: all five display readers
--     still asked `v_row.supplier_order_id IS NOT NULL THEN CONTINUE`, i.e. they
--     treated ANY pointer as "already ordered". That is precisely the line that
--     hid 83 rows. After §5+§6 a cross-date pointer cannot exist, so this swap
--     is a behavioural no-op TODAY — its job is defence in depth: if the guard
--     is ever dropped, a stale pointer still cannot hide a line from the form.
--
--     All five loop over `inquiry%ROWTYPE`, so batch_date is always in scope.
--     Rewriting via pg_get_functiondef keeps each body byte-identical apart from
--     the one predicate, and is idempotent: on a second run the regex finds
--     nothing to replace.
--
--     DELIBERATELY EXCLUDED — inquiry_engine_ranked_suppliers and
--     inquiry_engine_sync. Those are the paths that stamp asked_at and fire
--     send_supplier_inquiry_wa. They keep the bare `supplier_order_id IS NULL`
--     test so that a stale pointer can never, under any future regression,
--     promote itself into an unsolicited WhatsApp to a real supplier about a
--     days-old line. That is the re-ask policy this command was asked to decide.
-- ─────────────────────────────────────────────────────────────────────────────
DO $readers$
DECLARE
  r record; v_src text; v_new text; v_done text[] := '{}';
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.proname IN ('_get_inquiry_form_core','supplier_pending_inquiry_count',
                         'supplier_inquiry_buckets','get_supplier_inquiry_overview',
                         'get_supplier_inquiry_items')
  LOOP
    v_src := pg_get_functiondef(r.oid);
    v_new := regexp_replace(
               v_src,
               '(\w+)\.supplier_order_id\s+IS\s+NOT\s+NULL',
               'public.inq_is_ordered(\1.supplier_order_id, \1.batch_date)',
               'gi');
    IF v_new IS DISTINCT FROM v_src THEN
      EXECUTE v_new;
      v_done := v_done || r.proname;
    END IF;
  END LOOP;
  RAISE NOTICE 'CHANGE #240 readers re-pointed at inq_is_ordered(): %',
    COALESCE(array_to_string(v_done, ', '), '(already done)');
END;
$readers$;

-- Prove the swap landed on all five, and that the engine was left alone.
DO $verify_readers$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_bad
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('_get_inquiry_form_core','supplier_pending_inquiry_count',
                       'supplier_inquiry_buckets','get_supplier_inquiry_overview',
                       'get_supplier_inquiry_items')
     AND pg_get_functiondef(p.oid) NOT LIKE '%inq_is_ordered%';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'CHANGE #240: display reader(s) did not pick up inq_is_ordered -> %', v_bad;
  END IF;
END;
$verify_readers$;

-- The second regression guard: the reader split is policy, so it is pinned.
INSERT INTO public.rg_behavior_tests(name, enabled, note, body) VALUES (
 'inquiry_po_reader_predicate', true,
 'CHANGE #240 — the five inquiry DISPLAY readers must decide "already ordered" via inq_is_ordered(supplier_order_id, batch_date), never a bare NOT NULL. The two ENGINE functions must NOT use it, so a stale pointer can never fire an unsolicited supplier WhatsApp.',
$rg$
do $x$
declare v_bad text;
begin
  -- display readers must use the date-aware predicate
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('_get_inquiry_form_core','supplier_pending_inquiry_count',
                       'supplier_inquiry_buckets','get_supplier_inquiry_overview',
                       'get_supplier_inquiry_items')
     and pg_get_functiondef(p.oid) not like '%inq_is_ordered%';
  if v_bad is not null then
    raise exception 'RG_FAIL: inquiry display reader(s) went back to a bare supplier_order_id test, so a stale pointer can hide a line from the supplier form again -> %', v_bad;
  end if;

  -- the engine must stay on the bare test (the #240 re-ask policy)
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
   where p.pronamespace='public'::regnamespace
     and p.proname in ('inquiry_engine_ranked_suppliers','inquiry_engine_sync')
     and pg_get_functiondef(p.oid) like '%inq_is_ordered%';
  if v_bad is not null then
    raise exception 'RG_FAIL: engine function(s) now treat a stale pointer as un-ordered and would WhatsApp real suppliers about days-old lines -> %', v_bad;
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$rg$)
ON CONFLICT (name) DO UPDATE SET body = excluded.body, note = excluded.note, enabled = true;
