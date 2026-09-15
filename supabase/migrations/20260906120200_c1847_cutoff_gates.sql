-- replay-target: production
-- CMD #1847 — the two gates. Both are EXISTING choke points; each gains one
-- named reason, so every surface that already reads them obeys the cut-off
-- without learning anything new.

-- GATE 1 — _order_change_gate is the single gate behind the customer's Edit
-- order and Cancel order (_order_edit_gate / _order_customer_cancel_gate /
-- _order_customer_actions all read it). Past the cut-off both simply stop
-- being rendered, exactly as they do when order hours shut.
create or replace function public._order_change_gate(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  o        public.orders%rowtype;
  v_cid    uuid    := public.my_customer_id();
  v_admin  boolean := coalesce(public.get_my_role() in ('admin','super_admin'), false);
  v_code   text;
  v_asked  boolean;
  v_moved  boolean;
  v_disp   boolean;
  v_open   boolean;
  v_reason text;
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then
    v_code := 'not_found';
  elsif not (o.customer_id is not distinct from v_cid or v_admin) then
    v_code := 'not_authorized';
  elsif o.closed_at is not null
     or lower(coalesce(o.status,'')) in ('cancelled','canceled','rejected','delivered','completed')
     or exists (select 1 from public.order_cancellations where order_id = p_order_id) then
    v_code := 'closed';
  end if;

  -- Om's rule. The window closes the moment the waterfall asks its first
  -- supplier for this order — asked_at, or a supplier order already cut.
  -- fulfillment_status leaving 'open' means the same thing by another route.
  if v_code is null then
    select exists (
      select 1
        from public.order_items oi
        left join lateral (
          select q.* from public.inquiry q
           where q.id = oi.inquiry_id
              or (oi.inquiry_id is null
                  and q.product_id = oi.product_id
                  and q.batch_date = coalesce(oi.order_date, o.order_date)
                  and (q.zone_id is not distinct from coalesce(oi.zone_id, o.zone_id)
                       or q.zone_id is null))
           order by (q.id = oi.inquiry_id) desc, q.id desc
           limit 1) i on true
       where oi.order_id = p_order_id
         and (i.asked_at is not null or i.supplier_order_id is not null)
    ) into v_asked;
    if v_asked or coalesce(o.fulfillment_status,'open') <> 'open' then
      v_code := 'inquiry_started';
    end if;
  end if;

  -- Physical fulfilment having started. NOT bag_no: that is stamped at
  -- placement by assign_order_bag_no() and means nothing has happened yet.
  if v_code is null then
    select exists (
      select 1 from public.order_items oi
       where oi.order_id = p_order_id
         and (coalesce(oi.fulfillment_state,'pending') <> 'pending'
              or coalesce(oi.received_qty,0) > 0
              or coalesce(oi.at_warehouse,false)
              or coalesce(oi.packed,false)
              or oi.shop_qty is not null
              or oi.assigned_supplier is not null)
    ) into v_moved;
    if v_moved then v_code := 'inquiry_started'; end if;
  end if;

  if v_code is null then
    select exists (select 1 from public.deliveries d
                    where d.order_id = p_order_id
                      and coalesce(d.status,'') in ('assigned','out_for_delivery','delivered'))
      into v_disp;
    if coalesce(o.dispatch_ready,false) or coalesce(v_disp,false) then
      v_code := 'dispatched';
    end if;
  end if;

  -- CMD #1847 — the day's order cut-off. At the cut-off the customer's Edit
  -- and Cancel disappear for that day's orders. An admin still has both: the
  -- cut-off closes the CUSTOMER side, and the admin's own actions (extend,
  -- cancel now, exempt, restore) live on the cut-off console.
  if v_code is null and not v_admin
     and coalesce((select c.cutoff_enabled from public.order_alert_config c
                    where c.id = 'singleton'), false)
     and now() >= public._order_cutoff_at(
                    o.zone_id, (o.created_at at time zone 'Asia/Kolkata')::date) then
    v_code := 'cutoff_passed';
  end if;

  -- The second closer Om asked for: order hours. A shut counter is a shut
  -- counter for changes as well as for new orders.
  if v_code is null then
    v_open := coalesce((public.order_hours_state(o.zone_id)->>'is_open')::boolean, true);
    if not v_open then v_code := 'hours_closed'; end if;
  end if;

  if v_code is not null then
    v_reason := public._c('order_change.reason_' || v_code);
    return jsonb_build_object(
      'ok',          (v_code not in ('not_found','not_authorized')),
      'open',        false,
      'show',        false,
      'can_edit',    false,
      'can_cancel',  false,
      'reason_code', v_code,
      'reason',      v_reason,
      'message',     v_reason,
      'note',        v_reason);
  end if;

  return jsonb_build_object(
    'ok',           true,
    'open',         true,
    'show',         true,
    'can_edit',     true,
    'can_cancel',   true,
    'reason_code',  'open',
    'reason',       '',
    'message',      '',
    'note',         public._c('order_change.window_open'),
    'edit_label',   public.ui_text('order_edit.button'),
    'cancel_label', public._c('cancel.cust_action_label'),
    'window_label', public._c('order_change.window_open'));
end $$;

-- GATE 2 — inquiry_send_readiness() is the gate start_inquiry_for_suppliers()
-- already obeys (it raises inquiry_send_blocked when can_send is false). The
-- restoration window becomes a SIXTH check in the checks[] the screen already
-- renders; when the window shuts, the check turns green by itself and the
-- inquiry runs.
create or replace function public.inquiry_send_readiness()
returns jsonb language plpgsql stable security definer set search_path = public as $$
DECLARE
  h order_hours%ROWTYPE;
  d date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_leads int; v_lead_codes text[];
  v_claims int; v_claim_codes text[];
  v_undecided int; v_undecided_codes text[];
  v_mode text; v_items int; v_suppliers int; v_locked boolean;
  c1 boolean; c2 boolean; c3 boolean; c4 boolean; c5 boolean; c6 boolean;
  v_nothing_to_ask boolean;
  v_checks jsonb; v_breakdown jsonb;
  v_passed int; v_failed_names text[]; v_gate_ok boolean;
  v_zone smallint; v_hold int; v_hold_until timestamptz;
BEGIN
  IF get_my_role() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  SELECT * INTO h FROM order_hours WHERE id = 1;
  v_locked := public.inquiry_locked();

  c1 := NOT h.is_open;

  SELECT count(*), COALESCE(array_agg(COALESCE(lead_code, customer_name))
           FILTER (WHERE COALESCE(lead_code, customer_name) IS NOT NULL),'{}')
    INTO v_leads, v_lead_codes
  FROM pending_orders
  WHERE status='pending' AND (created_at AT TIME ZONE 'Asia/Kolkata')::date = d;
  c2 := v_leads = 0;

  SELECT count(*), COALESCE(array_agg(DISTINCT o.order_code)
           FILTER (WHERE o.order_code IS NOT NULL),'{}')
    INTO v_claims, v_claim_codes
  FROM payment_claims p JOIN orders o ON o.id = p.order_id
  WHERE p.status='claimed' AND (p.received_at AT TIME ZONE 'Asia/Kolkata')::date = d;
  c3 := v_claims = 0;

  SELECT count(*), COALESCE(array_agg(order_code) FILTER (WHERE order_code IS NOT NULL),'{}')
    INTO v_undecided, v_undecided_codes
  FROM orders
  WHERE (created_at AT TIME ZONE 'Asia/Kolkata')::date = d
    AND COALESCE(status,'pending') NOT IN ('accepted','rejected','cancelled');
  c4 := v_undecided = 0;

  SELECT value #>> '{}' INTO v_mode FROM app_settings WHERE key='allocation_mode';
  c5 := v_mode IN ('first_available','fewest_baskets');

  -- CMD #1847 — the restoration window. While a cut-off cancellation can still
  -- be restored, sourcing must not start: restoring an order whose lines have
  -- already gone to a supplier is not a restore.
  v_zone := public.admin_active_zone();
  SELECT count(*), max(r.restore_until) INTO v_hold, v_hold_until
    FROM public.order_cutoff_run r
   WHERE r.state = 'cancelled' AND r.restore_until IS NOT NULL
     AND now() < r.restore_until
     AND (v_zone IS NULL OR r.zone_id = v_zone);
  c6 := COALESCE(v_hold,0) = 0;

  SELECT COALESCE(sum(v.current_count),0)::int, count(*)::int
    INTO v_items, v_suppliers
  FROM get_supplier_inquiry_overview() v;
  v_nothing_to_ask := (v_items = 0);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'supplier', v.supplier_name, 'items', v.current_count,
           'label', v.supplier_name || ' — ' || v.current_count || ' item'
                    || CASE WHEN v.current_count > 1 THEN 's' ELSE '' END,
           'products', (SELECT array_agg(i.product_name ORDER BY i.product_name)
                          FROM inquiry i
                         WHERE i.current_supplier = v.supplier_name
                           AND COALESCE(i.current_status,'') <> 'Available')
         ) ORDER BY v.current_count DESC, v.supplier_name), '[]'::jsonb)
    INTO v_breakdown FROM get_supplier_inquiry_overview() v;

  v_checks := jsonb_build_array(
    jsonb_build_object('key','order_hours','ok',c1,'label','Order hours',
      'value', CASE WHEN c1 THEN 'Closed' ELSE 'Still open' END,
      'detail', CASE WHEN NOT c1 THEN 'Closes ' || to_char(h.auto_close_time,'FMHH12:MI AM') END),
    jsonb_build_object('key','leads','ok',c2,'label','Leads',
      'value', CASE WHEN c2 THEN 'Clear' ELSE v_leads || ' pending' END,
      'detail', CASE WHEN NOT c2 THEN NULLIF(array_to_string(v_lead_codes, ', '),'') END),
    jsonb_build_object('key','payments','ok',c3,'label','Payments',
      'value', CASE WHEN c3 THEN 'Clear' ELSE v_claims || ' awaiting' END,
      'detail', CASE WHEN NOT c3 THEN NULLIF(array_to_string(v_claim_codes, ', '),'') END),
    jsonb_build_object('key','orders','ok',c4,'label','Orders',
      'value', CASE WHEN c4 THEN 'All decided' ELSE v_undecided || ' undecided' END,
      'detail', CASE WHEN NOT c4 THEN NULLIF(array_to_string(v_undecided_codes, ', '),'') END),
    jsonb_build_object('key','allocation','ok',c5,'label','Allocation',
      'value', CASE WHEN v_mode='fewest_baskets' THEN 'Bundle'
                    WHEN v_mode='first_available' THEN 'SPN' ELSE 'Not set' END,
      'detail', CASE WHEN NOT c5 THEN 'Choose Bundle or SPN' END),
    jsonb_build_object('key','restore_window','ok',c6,
      'label', public.oa_label('cutoff_inquiry_check'),
      'value', CASE WHEN c6 THEN 'Closed' ELSE v_hold || ' restorable' END,
      'detail', CASE WHEN NOT c6 THEN public.oa_label('cutoff_window_open') END)
  );

  SELECT count(*) FILTER (WHERE (c->>'ok')::boolean),
         COALESCE(array_agg(c->>'label') FILTER (WHERE NOT (c->>'ok')::boolean), '{}')
    INTO v_passed, v_failed_names
  FROM jsonb_array_elements(v_checks) c;

  v_gate_ok := c1 AND c2 AND c3 AND c4 AND c5 AND c6;       -- 6 gating checks
  RETURN jsonb_build_object(
    'title', 'SEND-ALL READINESS',
    'date_label', to_char(d,'DD/MM/YYYY'),
    'scope_label', 'Today only',

    'can_send', v_gate_ok AND NOT v_nothing_to_ask,
    'nothing_to_ask', v_nothing_to_ask,
    'status_label', CASE
        WHEN v_locked THEN 'INQUIRY RUNNING'
        WHEN array_length(v_failed_names,1) IS NOT NULL
          THEN array_length(v_failed_names,1) || ' BLOCKING'
        WHEN v_nothing_to_ask THEN 'NOTHING TO ASK'
        ELSE 'READY TO SEND' END,
    'status_tone', CASE
        WHEN v_locked THEN 'running'
        WHEN array_length(v_failed_names,1) IS NOT NULL THEN 'blocked'
        WHEN v_nothing_to_ask THEN 'neutral'
        ELSE 'ok' END,
    'progress_label', v_passed || ' of 6 checks passed',
    'progress', v_passed,
    'progress_total', 6,

    'checks', v_checks,

    'summary_label', v_items || ' items → ' || v_suppliers || ' suppliers',
    'blocked_label', CASE WHEN array_length(v_failed_names,1) IS NOT NULL
      THEN 'Blocked — ' || array_to_string(v_failed_names, ', ') END,
    'nothing_to_ask_label', CASE WHEN v_nothing_to_ask AND v_gate_ok
      THEN 'Nothing to ask right now' END,
    'backlog_label', NULL,

    'slider_label', CASE WHEN v_locked THEN 'Inquiry running' ELSE 'Start inquiry' END,
    'slider_enabled', v_gate_ok AND NOT v_nothing_to_ask AND NOT v_locked,
    'locked', v_locked,
    'lock_label', CASE WHEN v_locked
      THEN 'Admin ordering is paused. Unlocks at midnight if you forget.' END,

    'restore_window_open', NOT c6,
    'restore_window_until', v_hold_until,

    'breakdown', v_breakdown,
    'allocation_mode', v_mode,
    'items', v_items, 'suppliers', v_suppliers,
    'pending_leads', v_leads, 'unanswered_claims', v_claims, 'undecided_orders', v_undecided
  );
END $$;
