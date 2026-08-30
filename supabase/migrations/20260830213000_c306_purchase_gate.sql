-- ============================================================================
-- CHANGE #306 — THE PURCHASE GATE.
--
-- Om's actual risk: accept an unpaid order, buy the stock from the supplier,
-- and then the customer refuses to pay. So accepting an unpaid order is
-- allowed and starts the inquiry — but the moment that inquiry would become a
-- REAL purchase, the money has to be there or a named admin has to have said
-- otherwise, in writing.
--
-- Where the choke point actually is: supplier_orders are per-supplier, per-day
-- aggregates (only 2 of 46 carry a customer order_id), and their `items` are
-- rebuilt from order_items by _oi_sync_supplier_order(). So the gate belongs in
-- that rebuild — a blocked order's lines never enter a supplier order at all —
-- with a second check on the send itself for the linked case.
-- ============================================================================

-- ── Is buying for this order authorised? ────────────────────────────────────
-- Accepted-but-unpaid is deliberately still blocked: acceptance starts the
-- inquiry, it does not authorise the purchase.
create or replace function public.order_purchase_blocked(p_order_id uuid)
returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select purchase_gate_enabled from public.order_alert_config
                    where id='singleton'), false)
     and p_order_id is not null
     and not public.order_is_paid(p_order_id)
     and not exists (select 1 from public.purchase_override po
                      where po.order_id = p_order_id and po.revoked_at is null)
$$;

create or replace function public.purchase_gate_check(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_paid boolean; v_override public.purchase_override%rowtype;
        v_credit jsonb; v_cust uuid; v_reason text; v_allowed boolean;
begin
  if not coalesce((select purchase_gate_enabled from public.order_alert_config
                    where id='singleton'), false) then
    return jsonb_build_object('ok', true, 'allowed', true, 'reason','gate_off', 'message','');
  end if;
  if p_order_id is null then
    return jsonb_build_object('ok', true, 'allowed', true, 'reason','no_customer_order',
                              'message','');
  end if;

  v_paid := public.order_is_paid(p_order_id);
  select * into v_override from public.purchase_override
   where order_id = p_order_id and revoked_at is null
   order by created_at desc limit 1;
  select customer_id into v_cust from public.orders where id = p_order_id;
  v_credit := public.customer_credit_state(v_cust);

  if v_paid then
    v_allowed := true; v_reason := 'purchase_allowed_paid';
  elsif v_override.id is not null then
    v_allowed := true; v_reason := 'purchase_allowed_override';
  elsif coalesce((v_credit->>'blocked')::boolean,false) then
    v_allowed := false; v_reason := 'purchase_reason_credit';
  else
    v_allowed := false; v_reason := 'purchase_reason_unpaid';
  end if;

  return jsonb_build_object(
    'ok', true,
    'allowed',      v_allowed,
    'paid',         v_paid,
    'reason',       v_reason,
    'reason_label', public.oa_label(v_reason),
    'message',      case when v_allowed then ''
                         else public.oa_label('purchase_blocked',
                                jsonb_build_object('reason', public.oa_label(v_reason))) end,
    'override',     case when v_override.id is null then null
                         else jsonb_build_object(
                                'id', v_override.id,
                                'by', coalesce(v_override.granted_by_label,''),
                                'reason', v_override.reason,
                                'at', v_override.created_at) end,
    'credit',       v_credit);
end $$;

-- One row per (order, supplier) per day: enough to explain a missing line on
-- the supplier order, never enough to be a log flood.
create or replace function public._purchase_gate_log(
  p_order_id uuid, p_supplier text, p_allowed boolean, p_reason text, p_detail jsonb)
returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if exists (select 1 from public.purchase_gate_log l
              where l.order_id = p_order_id
                and coalesce(l.supplier_name,'') = coalesce(p_supplier,'')
                and l.allowed = p_allowed
                and l.created_at > now() - interval '1 day') then
    return;
  end if;
  insert into public.purchase_gate_log (order_id, supplier_name, allowed, reason, detail)
  values (p_order_id, p_supplier, p_allowed, p_reason, p_detail);
end $$;

-- ── The rebuild, gated ──────────────────────────────────────────────────────
-- Byte-for-byte the previous body, plus one predicate: a line whose customer
-- order is not authorised for purchase does not enter the supplier order. The
-- exclusion is set-based (a NOT EXISTS over the blocked orders of this
-- supplier's day), never a scalar helper called per row.
create or replace function public._oi_sync_supplier_order()
returns trigger
language plpgsql as $function$
declare v_sup text := NEW.assigned_supplier; v_so uuid; v_date date; b record;
begin
  if current_setting('medibo.in_broadcast', true) = '1' then return NEW; end if;
  if v_sup is null then return NEW; end if;

  select id, order_date into v_so, v_date
    from supplier_orders
   where supplier_name = v_sup and status = 'pending'
   order by created_at desc limit 1;
  if v_so is null then return NEW; end if;
  v_date := coalesce(v_date, (now() at time zone 'Asia/Kolkata')::date);

  perform set_config('medibo.in_broadcast','1',true);
  update supplier_orders so
  set items = (
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', t.product_id, 'product_name', t.product_name,
             'quantity', t.qty, 'mrp', t.mrp,
             'pack_type', nullif(btrim(med.pack_type),''))), '[]'::jsonb)
    from (
      select oi.product_id, max(oi.product_name) as product_name,
             sum(oi.quantity) as qty, max(oi.mrp) as mrp
      from order_items oi
      join orders o on o.id = oi.order_id
      where oi.assigned_supplier = v_sup
        and oi.fulfillment_state <> 'cancelled'
        and coalesce(oi.at_warehouse,false) = false
        and coalesce(oi.packed,false) = false
        and (o.created_at at time zone 'Asia/Kolkata')::date = v_date
        and not public.order_purchase_blocked(o.id)   -- CHANGE #306
      group by oi.product_id
    ) t left join "MEDICINE" med on med.id = t.product_id
  )
  where so.id = v_so;
  perform set_config('medibo.in_broadcast','0',true);

  -- Say why a line is missing, once a day per order+supplier.
  for b in
    select distinct o.id
      from order_items oi join orders o on o.id = oi.order_id
     where oi.assigned_supplier = v_sup
       and (o.created_at at time zone 'Asia/Kolkata')::date = v_date
       and public.order_purchase_blocked(o.id)
  loop
    perform public._purchase_gate_log(b.id, v_sup, false, 'held_from_supplier_order',
              public.purchase_gate_check(b.id));
  end loop;

  return NEW;
end $function$;

-- ── The send, gated ─────────────────────────────────────────────────────────
-- Same body as before plus the gate, for the case where a supplier order IS
-- tied to one customer order.
create or replace function public.send_supplier_order_wa(p_supplier text, p_order_id uuid)
returns void
language plpgsql security definer set search_path to 'public' as $function$
declare v_phone text; v_cust_order uuid; v_gate jsonb;
begin
  if p_supplier is null or btrim(p_supplier) = '' then return; end if;

  select so.order_id into v_cust_order from public.supplier_orders so where so.id = p_order_id;
  if v_cust_order is not null then
    v_gate := public.purchase_gate_check(v_cust_order);
    if not coalesce((v_gate->>'allowed')::boolean, true) then
      perform public._purchase_gate_log(v_cust_order, p_supplier, false,
                'send_blocked', v_gate);
      return;   -- no purchase without payment or a logged override
    end if;
    perform public._purchase_gate_log(v_cust_order, p_supplier, true,
              coalesce(v_gate->>'reason','allowed'), v_gate);
  end if;

  v_phone := public.sup_pick_send_phone(p_supplier);
  perform public.notify('supplier_order', v_phone,
    jsonb_build_object(
      'supplier_name', p_supplier,
      'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/supplier-order-notify',
      'legacy_body', jsonb_build_object('supplier_name', p_supplier, 'order_id', p_order_id)
                     || case when v_phone is not null
                             then jsonb_build_object('to_phone', v_phone) else '{}'::jsonb end));
end $function$;

-- ── The override: who, and why ──────────────────────────────────────────────
create or replace function public.purchase_override_grant(p_order_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_label text; v_id bigint;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  if coalesce(btrim(p_reason),'') = '' then
    return jsonb_build_object('ok', false, 'error','no_reason',
                              'message', public.oa_label('override_missing_reason'));
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();

  insert into public.purchase_override (order_id, granted_by, granted_by_label, reason)
  values (p_order_id, auth.uid(), coalesce(v_label,'admin'), btrim(p_reason))
  returning id into v_id;

  perform public._purchase_gate_log(p_order_id, null, true, 'override_granted',
            jsonb_build_object('by', coalesce(v_label,'admin'), 'reason', btrim(p_reason)));

  return jsonb_build_object('ok', true, 'id', v_id,
                            'message', public.oa_label('override_saved'),
                            'gate', public.purchase_gate_check(p_order_id));
end $$;

create or replace function public.purchase_override_revoke(p_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_label text; v_order uuid;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select lower(btrim(u.email)) into v_label from auth.users u where u.id = auth.uid();
  update public.purchase_override
     set revoked_at = now(), revoked_by = coalesce(v_label,'admin')
   where id = p_id and revoked_at is null
   returning order_id into v_order;
  return jsonb_build_object('ok', v_order is not null,
                            'gate', public.purchase_gate_check(v_order));
end $$;
