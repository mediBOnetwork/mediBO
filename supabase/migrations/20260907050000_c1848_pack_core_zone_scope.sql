-- CMD #1848 (follow-up) — pack_list_orders_core carries its own zone scope.
--
-- The c1094 zone-scope ratchet grandfathers an unscoped list body only while
-- it is untouched. This command changed pack_list_orders_core (the
-- test_row_visible line), so the core is judged on its own — and its wrapper
-- pack_list_orders is the only thing that applied admin_active_zone(), while
-- the core stayed executable by any signed-in user, so the wrapper could be
-- bypassed. The core now applies the SAME predicate the wrapper applies
-- (zone_filter_order_array keeps an order only when o.zone_id = the picked
-- zone; a NULL picker means every zone), and direct execution is revoked from
-- anon/authenticated: the wrapper is SECURITY DEFINER and still reaches it.
begin;

CREATE OR REPLACE FUNCTION public.pack_list_orders_core(p_date date DEFAULT admin_active_date(), p_include_older boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_rows jsonb;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'order_id', o.id, 'order_code', o.order_code,
           'pharmacy_name', o.pharmacy_name,
           'dispatch_ready', COALESCE(o.dispatch_ready,false),
           'created_at', o.created_at,
           'items_total', x.n_items, 'items_packed', x.n_packed,
           'fulfillment_status', COALESCE(o.fulfillment_status,''),
           -- NEW: backend-owned order status label + colours
           'status_label', CASE COALESCE(o.fulfillment_status,'')
                             WHEN 'ready' THEN 'Ready'
                             WHEN 'partial_ready' THEN 'Partially ready'
                             WHEN 'in_transit' THEN 'In transit'
                             WHEN 'collecting' THEN 'Collecting'
                             WHEN 'open' THEN 'Open'
                             WHEN 'shipped' THEN 'Shipped'
                             WHEN 'delivered' THEN 'Delivered'
                             WHEN '' THEN 'Open'
                             ELSE initcap(replace(COALESCE(o.fulfillment_status,''),'_',' ')) END,
           'status_colors', CASE
                             WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                             WHEN COALESCE(o.fulfillment_status,'') IN ('partial_ready','in_transit') THEN jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                             WHEN COALESCE(o.fulfillment_status,'') IN ('shipped','delivered') THEN jsonb_build_object('bg','#E6F1FB','fg','#0C447C')
                             ELSE jsonb_build_object('bg','#FEF3C7','fg','#92400E') END,
           'dot', jsonb_build_object(
             'state', CASE WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN 'green'
                           WHEN COALESCE(o.fulfillment_status,'') IN ('partial_ready','in_transit') THEN 'light_yellow'
                           ELSE 'yellow' END,
             'fill',  CASE WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN '#1B7A43'
                           WHEN COALESCE(o.fulfillment_status,'') IN ('partial_ready','in_transit') THEN '#FEF3C7'
                           ELSE '#FCD34D' END,
             'border',CASE WHEN COALESCE(o.fulfillment_status,'') = 'ready' THEN '#1B7A43'
                           ELSE '#F59E0B' END),
           'pack_button', jsonb_build_object(
             'label', CASE WHEN x.n_items <= 0 THEN 'Start Packing'
                           WHEN x.n_packed = 0 THEN 'Start Packing'
                           WHEN x.n_packed >= x.n_items THEN 'Packed ✓ — View'
                           ELSE 'Resume Packing (' || x.n_packed || '/' || x.n_items || ')' END,
             'fill', '#1B7A43'),
           'can_mark_ready', x.can_ready
         ) ORDER BY o.created_at DESC), '[]'::jsonb)
    INTO v_rows
  FROM orders o
  JOIN LATERAL (
    SELECT count(*) AS n_items,
           count(*) FILTER (WHERE COALESCE(q.packed,false)) AS n_packed,
           (count(*) FILTER (WHERE q.fulfillment_state IN ('received','short')) > 0
            AND count(*) FILTER (
                  WHERE q.fulfillment_state IN ('received','short')
                    AND NOT ( COALESCE(q.packed_qty,0) >= q.packable_qty
                              AND COALESCE(q.packed_qty,0) > 0
                              AND q.pack_counted_qty IS NOT NULL
                              AND COALESCE(q.pack_counted_qty,0) >= q.packable_qty
                              AND COALESCE(q.pack_counted_qty,0) > 0 )
                ) = 0) AS can_ready
    FROM (
      SELECT oi.packed, oi.packed_qty, oi.pack_counted_qty, oi.fulfillment_state,
             least(
               COALESCE((SELECT sum(bic.qty) FROM bag_item_counts bic
                         WHERE bic.assigned_supplier = oi.assigned_supplier
                           AND bic.product_id = oi.product_id AND bic.qty > 0),0),
               oi.quantity
             ) AS packable_qty
      FROM order_items oi
      WHERE oi.order_id = o.id AND oi.fulfillment_state NOT IN ('shipped','cancelled')
    ) q
  ) x ON true
  WHERE x.n_items > 0
    AND public.test_row_visible(o.is_synthetic, o.test_session_id)   -- CMD #1848
    AND (public.admin_active_zone() IS NULL OR o.zone_id = public.admin_active_zone())   -- CMD #1848: the picked zone, same rule as the wrapper
    AND NOT public._c708_order_held(o.id)   -- CHANGE #708
    AND (p_date IS NULL OR (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = p_date);

  RETURN jsonb_build_object('status','ok','orders',v_rows,
    'older_open', 0, 'date', p_date, 'include_older', false);
END;
$function$;

revoke execute on function public.pack_list_orders_core(date, boolean) from public, anon, authenticated;
grant execute on function public.pack_list_orders_core(date, boolean) to postgres, service_role;

commit;
