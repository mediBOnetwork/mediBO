-- CMD #449 — HIGH defects, admin batch A: feature_gaps rows 10, 11, 12, 14, 15, 17.
--
-- Every statement here is idempotent (create or replace / if not exists /
-- on conflict do nothing): a resumed worker re-applies this file as a no-op.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PART 1 — gaps #10 and #11 share ONE root cause, reproduced under rollback.
--
--   order_try_close()            -> update order_items set fulfillment_state='shipped'
--   supplier_order_try_settle()  -> the same update
--     -> _trg_prune_supplier_orders_on_reassign() fires on the shipped transition
--       -> _prune_supplier_orders_for(old supplier)
--         -> DELETE FROM supplier_orders
--           -> _guard_supplier_order_delete() RAISES P0001
--
-- That is why order_closure_log has ZERO rows and why no order and no supplier
-- order has ever reached a terminal state: BOTH engines abort on a trigger the
-- moment they touch the first line. The three functions already agree in their
-- own comments that shipping must never erase a purchase order ("A purchase
-- order records what was ordered; completing or shipping it is not a reason to
-- erase it") — the leftover was the trigger CONDITION, which still fired the
-- prune on 'shipped', and the prune's DELETE, which used a per-product test
-- while the guard uses a per-supplier-per-date test, so the two could disagree.
--
-- Fix 1a: the prune fires on a genuine reassignment and on 'cancelled' (which
--         really does remove demand) — never on 'shipped'.
-- Fix 1b: the prune applies the GUARD'S OWN test before deleting, so the two
--         can never contradict each other again. A PO the guard would protect
--         is left alone silently instead of raising through the caller.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._trg_prune_supplier_orders_on_reassign()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE v_old text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_old := OLD.assigned_supplier;
  ELSIF TG_OP = 'UPDATE' THEN
    -- CMD #449 — 'shipped' REMOVED from this condition. Shipping a line is the
    -- completion of a purchase order, not a reassignment away from it, and the
    -- delete guard refuses to erase a PO that still has live lines for that
    -- supplier on that date. Firing the prune here made every close and every
    -- settle raise P0001. A genuine supplier change, and a cancelled line
    -- (which really does withdraw the demand), still prune.
    IF NEW.assigned_supplier IS DISTINCT FROM OLD.assigned_supplier
       OR (NEW.fulfillment_state = 'cancelled' AND coalesce(OLD.fulfillment_state,'') <> 'cancelled') THEN
      v_old := OLD.assigned_supplier;
    ELSE
      RETURN NULL;
    END IF;
  ELSE
    RETURN NULL;
  END IF;

  IF v_old IS NOT NULL AND btrim(v_old) <> '' THEN
    PERFORM _prune_supplier_orders_for(v_old);
  END IF;
  RETURN NULL;
END; $function$;

create or replace function public._prune_supplier_orders_for(p_supplier text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE r record; v_new jsonb; v_total numeric; v_live int;
BEGIN
  IF p_supplier IS NULL OR btrim(p_supplier) = '' THEN RETURN; END IF;

  FOR r IN
    SELECT so.id, so.items, so.order_date
    FROM supplier_orders so
    WHERE so.supplier_name = p_supplier
      AND so.status NOT IN ('shipped','cancelled','delivered')
  LOOP
    -- keep an item while a live line for that product exists for this supplier ON THIS PO'S DATE.
    -- 'shipped' is NOT a reason to strip: the PO records what was ordered.
    SELECT COALESCE(jsonb_agg(it), '[]'::jsonb) INTO v_new
    FROM jsonb_array_elements(r.items) it
    WHERE EXISTS (
      SELECT 1 FROM order_items oi
      JOIN orders o ON o.id = oi.order_id
      WHERE oi.assigned_supplier = p_supplier
        AND oi.product_id = (it->>'product_id')::bigint
        AND coalesce(oi.fulfillment_state,'') <> 'cancelled'
        AND (r.order_date IS NULL
             OR (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = r.order_date)
    );

    IF jsonb_array_length(v_new) = 0 THEN
      -- CMD #449 — ask the delete guard's OWN question before deleting. The
      -- guard counts live lines for this supplier on this date REGARDLESS of
      -- product; the loop above matches PER product. When the two disagree the
      -- DELETE raised P0001 straight through order_try_close /
      -- supplier_order_try_settle and killed the whole closure path. A PO the
      -- guard protects is now left exactly as it is.
      v_live := 0;
      IF r.order_date IS NOT NULL THEN
        SELECT count(*) INTO v_live
        FROM order_items oi
        JOIN orders o ON o.id = oi.order_id
        WHERE oi.assigned_supplier = p_supplier
          AND (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = r.order_date
          AND coalesce(oi.fulfillment_state,'') <> 'cancelled'
          AND coalesce(o.fulfillment_status,'')  <> 'cancelled';
      END IF;

      IF v_live = 0
         OR coalesce(current_setting('medibo.po_guard_off', true), '') = '1' THEN
        DELETE FROM supplier_orders WHERE id = r.id;
      END IF;
    ELSIF v_new <> r.items THEN
      SELECT COALESCE(SUM((it->>'quantity')::numeric * COALESCE((it->>'mrp')::numeric,0)),0) INTO v_total
      FROM jsonb_array_elements(v_new) it;
      UPDATE supplier_orders SET items = v_new, total_amount = v_total WHERE id = r.id;
    END IF;
  END LOOP;
END $function$;
