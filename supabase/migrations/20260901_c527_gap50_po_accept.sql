-- c527 · feature_gaps #50 — "No supplier accept or decline step exists for a PO"
--
-- All 46 supplier_orders rows sat at status='pending': 0 packed, 0 settled, 0
-- with a submit_response. commit_supplier_order() creates the PO the moment
-- current_status flips to Available, cron autosend_pending_supplier_orders
-- sends it, and the ONLY supplier-side write was supplier_set_packed(). There
-- was no accept, no decline, no partial accept, and no state at all between
-- "created" and "packed" — so a supplier who could not serve the PO had no way
-- to say so, and the shortfall surfaced days later at receiving.
--
-- Now the PO has an acknowledgement state, packing is gated on it, and a
-- decline or a partial accept puts the unserved quantity straight back into the
-- waterfall (the #60 remainder cascade) instead of stranding it.

-- ── 1 · the acknowledgement state ──────────────────────────────────────────
alter table public.supplier_orders
  add column if not exists accept_state   text not null default 'pending',
  add column if not exists accepted_at    timestamptz,
  add column if not exists accepted_by    text,
  add column if not exists decline_reason text;

comment on column public.supplier_orders.accept_state is
  'c527 #50 — pending | accepted | partial | declined. Packing is gated on it.';

create index if not exists supplier_orders_accept_state_idx
  on public.supplier_orders (supplier_name, accept_state);

-- ── 2 · the copy (backend-owned, every word of it) ─────────────────────────
insert into public.ui_copy(key, value) values
  ('supplier_po.state_pending',   '"Awaiting your reply"'::jsonb),
  ('supplier_po.state_accepted',  '"Accepted"'::jsonb),
  ('supplier_po.state_partial',   '"Partly accepted"'::jsonb),
  ('supplier_po.state_declined',  '"Declined"'::jsonb),
  ('supplier_po.action_accept',   '"Accept order"'::jsonb),
  ('supplier_po.action_partial',  '"Accept part"'::jsonb),
  ('supplier_po.action_decline',  '"Can''t supply"'::jsonb),
  ('supplier_po.ack_title',       '"Can you supply this order?"'::jsonb),
  ('supplier_po.ack_hint',        '"Tell us before you pack — we send the rest to the next supplier straight away."'::jsonb),
  ('supplier_po.pack_blocked',    '"Accept the order before you mark it packed"'::jsonb),
  ('supplier_po.accepted_toast',  '"Order accepted"'::jsonb),
  ('supplier_po.partial_toast',   '"Part accepted — {n} item(s) sent to the next supplier"'::jsonb),
  ('supplier_po.declined_toast',  '"Order declined — sent to the next supplier"'::jsonb),
  ('supplier_po.err_action',      '"Choose accept, part accept or decline"'::jsonb),
  ('supplier_po.err_declined',    '"This order was already declined"'::jsonb),
  ('supplier_po.err_no_lines',    '"Enter the quantity you can supply for at least one item"'::jsonb),
  ('supplier_po.decline_reason',  '"Why can''t you supply it? (optional)"'::jsonb)
on conflict (key) do nothing;

-- ── 3 · state -> what the screen prints and offers ─────────────────────────
create or replace function public.supplier_po_accept_block(
  p_state text, p_packed boolean, p_declined_reason text default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'state', coalesce(nullif(p_state,''),'pending'),
    'label', case coalesce(nullif(p_state,''),'pending')
               when 'accepted' then public.uic('supplier_po.state_accepted','Accepted')
               when 'partial'  then public.uic('supplier_po.state_partial','Partly accepted')
               when 'declined' then public.uic('supplier_po.state_declined','Declined')
               else public.uic('supplier_po.state_pending','Awaiting your reply') end,
    'tone', case coalesce(nullif(p_state,''),'pending')
              when 'accepted' then 'success'
              when 'partial'  then 'warning'
              when 'declined' then 'danger'
              else 'info' end,
    'title', public.uic('supplier_po.ack_title','Can you supply this order?'),
    'hint',  public.uic('supplier_po.ack_hint',''),
    'reason', nullif(btrim(coalesce(p_declined_reason,'')),''),
    'reason_label', public.uic('supplier_po.decline_reason',''),
    'needs_reply', (coalesce(nullif(p_state,''),'pending') = 'pending'),
    'actions', case when coalesce(nullif(p_state,''),'pending') = 'pending'
      then jsonb_build_array(
        jsonb_build_object('action','accept',
          'label', public.uic('supplier_po.action_accept','Accept order'), 'tone','brand'),
        jsonb_build_object('action','partial',
          'label', public.uic('supplier_po.action_partial','Accept part'), 'tone','neutral'),
        jsonb_build_object('action','decline',
          'label', public.uic('supplier_po.action_decline','Can''t supply'), 'tone','danger'))
      else '[]'::jsonb end,
    'can_pack', (coalesce(nullif(p_state,''),'pending') in ('accepted','partial')),
    'pack_blocked_reason',
      case when coalesce(nullif(p_state,''),'pending') in ('accepted','partial') then null
           else public.uic('supplier_po.pack_blocked',
                           'Accept the order before you mark it packed') end);
$function$;

-- ── 4 · the supplier answers his PO ────────────────────────────────────────
-- accept  · the whole PO stands
-- partial · p_lines [{product_id, accepted_qty}] — the PO keeps accepted_qty and
--           the unserved remainder cascades to the next supplier immediately
-- decline · every line cascades; the PO is closed, not silently left pending
create or replace function public.supplier_respond_order(
  p_order_code text,
  p_action     text,
  p_reason     text  default null,
  p_lines      jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_self text; v_is_admin boolean; v_row supplier_orders%rowtype;
  it jsonb; v_items jsonb := '[]'::jsonb; v_kept numeric; v_ask numeric;
  v_inq bigint; v_cascaded int := 0; v_split jsonb; v_splits jsonb := '[]'::jsonb;
  v_state text; v_actor text; v_pid bigint; v_line jsonb;
begin
  if p_action not in ('accept','partial','decline') then
    return jsonb_build_object('ok', false, 'error', 'bad_action',
      'message', public.uic('supplier_po.err_action','Choose accept, part accept or decline'));
  end if;

  select sp.supplier_name into v_self from current_supplier_profile() sp;
  v_is_admin := get_my_role() in ('admin','super_admin');

  select * into v_row from supplier_orders
   where order_code = p_order_code or id::text = p_order_code
   limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.uic('supplier_po.err_not_found','That order is not on your account.'));
  end if;

  if not v_is_admin
     and lower(btrim(v_row.supplier_name)) <> lower(btrim(coalesce(v_self,''))) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('supplier_po.err_not_found','That order is not on your account.'));
  end if;

  if v_row.accept_state = 'declined' then
    return jsonb_build_object('ok', false, 'error', 'already_declined',
      'message', public.uic('supplier_po.err_declined','This order was already declined'));
  end if;

  v_actor := coalesce(v_self, get_my_role(), 'supplier');

  -- ── accept: nothing moves, the PO simply becomes answered ───────────────
  if p_action = 'accept' then
    update supplier_orders
       set accept_state = 'accepted', accepted_at = now(), accepted_by = v_actor,
           decline_reason = null
     where id = v_row.id;
    return jsonb_build_object('ok', true, 'order_code', v_row.order_code,
      'accept', public.supplier_po_accept_block('accepted', coalesce(v_row.packed,false)),
      'cascaded', 0,
      'message', public.uic('supplier_po.accepted_toast','Order accepted'));
  end if;

  -- ── decline: every line goes back to the waterfall ──────────────────────
  if p_action = 'decline' then
    for it in select * from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) loop
      v_pid := nullif(it->>'product_id','')::bigint;
      if v_pid is null then continue; end if;
      select i.id into v_inq from inquiry i
       where i.supplier_order_id = v_row.id and i.product_id = v_pid
       order by i.id desc limit 1;
      if v_inq is not null then
        v_split := public._inquiry_cascade_remainder(v_inq, v_row.supplier_name, 0, 'po_declined');
      else
        perform public._reinquiry_exclude_and_advance(v_pid, v_row.supplier_name);
        v_split := jsonb_build_object('ok', true, 'product_id', v_pid, 'via', 'reinquiry');
      end if;
      v_splits := v_splits || jsonb_build_array(v_split);
      v_cascaded := v_cascaded + 1;
    end loop;

    -- 'closed', not 'declined': uq_supplier_orders_open_supplier_date counts
    -- anything outside (shipped, closed, cancelled) as the ONE open PO for that
    -- supplier and date, so a bespoke status would block every later PO for the
    -- day and _supplier_po_for_date would keep merging new lines into a dead
    -- document. accept_state carries the meaning; items stay for the record and
    -- the total goes to zero, because a declined PO owes nothing.
    update supplier_orders
       set accept_state = 'declined', accepted_at = now(), accepted_by = v_actor,
           decline_reason = nullif(btrim(coalesce(p_reason,'')),''),
           status = 'closed',
           total_amount = 0, trade_total = 0
     where id = v_row.id;

    return jsonb_build_object('ok', true, 'order_code', v_row.order_code,
      'accept', public.supplier_po_accept_block('declined', false, p_reason),
      'cascaded', v_cascaded, 'splits', v_splits,
      'message', public.uic('supplier_po.declined_toast',
                            'Order declined — sent to the next supplier'));
  end if;

  -- ── partial: keep what he can serve, cascade the rest ───────────────────
  if p_lines is null or jsonb_array_length(coalesce(p_lines,'[]'::jsonb)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_lines',
      'message', public.uic('supplier_po.err_no_lines',
                            'Enter the quantity you can supply for at least one item'));
  end if;

  for it in select * from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) loop
    v_pid := nullif(it->>'product_id','')::bigint;
    v_ask := coalesce(nullif(it->>'quantity','')::numeric, 0);

    v_line := null;
    select l.value into v_line
      from jsonb_array_elements(p_lines) l
     where nullif(l.value->>'product_id','')::bigint = v_pid
     limit 1;

    -- a line the supplier did not mention is left exactly as it stands
    if v_line is null then
      v_items := v_items || jsonb_build_array(it);
      continue;
    end if;

    v_kept := greatest(least(coalesce(nullif(v_line->>'accepted_qty','')::numeric, v_ask), v_ask), 0);

    if v_kept > 0 then
      v_items := v_items || jsonb_build_array(
        it || jsonb_build_object('quantity', v_kept, 'asked_qty', v_ask,
                                 'partial', (v_kept < v_ask)));
    end if;

    if v_kept < v_ask and v_pid is not null then
      select i.id into v_inq from inquiry i
       where i.supplier_order_id = v_row.id and i.product_id = v_pid
       order by i.id desc limit 1;
      if v_inq is not null then
        v_split := public._inquiry_cascade_remainder(
                     v_inq, v_row.supplier_name, v_kept, 'po_partial_accept');
      else
        perform public._reinquiry_exclude_and_advance(v_pid, v_row.supplier_name);
        v_split := jsonb_build_object('ok', true, 'product_id', v_pid, 'via', 'reinquiry');
      end if;
      v_splits := v_splits || jsonb_build_array(v_split);
      v_cascaded := v_cascaded + 1;
    end if;
  end loop;

  v_state := case when jsonb_array_length(v_items) = 0 then 'declined'
                  when v_cascaded > 0 then 'partial'
                  else 'accepted' end;

  update supplier_orders
     set items = case when v_state='declined' then v_row.items else v_items end,
         accept_state = v_state, accepted_at = now(), accepted_by = v_actor,
         decline_reason = case when v_state='declined'
                               then nullif(btrim(coalesce(p_reason,'')),'') end,
         status = case when v_state='declined' then 'closed' else status end,
         total_amount = case when v_state='declined' then 0 else total_amount end
   where id = v_row.id;
  if v_state <> 'declined' then perform public.po_retotal(v_row.id); end if;

  return jsonb_build_object('ok', true, 'order_code', v_row.order_code,
    'accept', public.supplier_po_accept_block(v_state, coalesce(v_row.packed,false), p_reason),
    'cascaded', v_cascaded, 'splits', v_splits,
    'message', case when v_state = 'declined'
      then public.uic('supplier_po.declined_toast','Order declined — sent to the next supplier')
      else public.uicf('supplier_po.partial_toast',
             jsonb_build_object('n', v_cascaded::text),
             'Part accepted — {n} item(s) sent to the next supplier') end);
end $function$;

grant execute on function public.supplier_respond_order(text, text, text, jsonb) to authenticated;

-- ── 5 · packing is gated on the acknowledgement ────────────────────────────
create or replace function public.supplier_set_packed(
  p_order_code text, p_packed boolean, p_via text DEFAULT 'order_tab'::text,
  p_ready_after timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_parcels integer DEFAULT NULL::integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_self text; v_is_admin boolean; v_row supplier_orders%rowtype;
begin
  select sp.supplier_name into v_self from current_supplier_profile() sp;
  v_is_admin := get_my_role() in ('admin','super_admin');

  select * into v_row from supplier_orders where order_code = p_order_code;
  if not found then return jsonb_build_object('error','not_found'); end if;

  if not v_is_admin and lower(btrim(v_row.supplier_name)) <> lower(btrim(coalesce(v_self,''))) then
    return jsonb_build_object('error','not_authorized');
  end if;

  if p_parcels is not null and p_parcels < 0 then
    return jsonb_build_object('error','bad_parcels','message',_c('supplier.parcels_bad'));
  end if;

  -- c527 #50 — there is now a state between created and packed, and packing is
  -- on the far side of it. Admin is not gated: he answers for the supplier when
  -- the reply came in over the phone.
  if p_packed and not v_is_admin
     and coalesce(v_row.accept_state,'pending') not in ('accepted','partial') then
    return jsonb_build_object('ok', false, 'error','not_accepted',
      'accept', public.supplier_po_accept_block(coalesce(v_row.accept_state,'pending'), false),
      'message', public.uic('supplier_po.pack_blocked',
                            'Accept the order before you mark it packed'));
  end if;

  update supplier_orders
     set packed      = p_packed,
         packed_at   = case when p_packed then now() else null end,
         packed_via  = case when p_packed then coalesce(p_via,'order_tab') else null end,
         -- Un-packing clears both: a bag that is no longer packed has no
         -- ready time and no parcel count to plan a pickup around.
         ready_after  = case when p_packed then coalesce(p_ready_after, ready_after) else null end,
         parcel_count = case when p_packed then coalesce(p_parcels, parcel_count) else null end
   where order_code = p_order_code;

  return jsonb_build_object('ok', true, 'order_code', p_order_code,
                            'packed', p_packed,
                            'packed_via', case when p_packed then coalesce(p_via,'order_tab') else null end,
                            'ready', public.supplier_ready_block(v_row.supplier_name, v_row.order_date),
                            'message', case when p_packed then _c('supplier.packed_toast')
                                            else _c('supplier.unpacked_toast') end);
end $function$;

-- ── 6 · the orders list carries the state, the buttons and the line details ─
drop function if exists public.supplier_my_orders(uuid);

create function public.supplier_my_orders(p_supplier_id uuid DEFAULT NULL::uuid)
returns table(order_id uuid, order_no integer, created_at timestamp with time zone,
              status text, total_amount numeric, item_count integer, items jsonb,
              order_code text, packed boolean, packed_via text, pack_button jsonb,
              pricing jsonb, accept jsonb, line_details jsonb)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_name text;
begin
  if p_supplier_id is null then
    select sp.supplier_name into v_name from current_supplier_profile() sp;
  else
    if get_my_role() <> 'super_admin' then RETURN; end if;
    select sp.supplier_name into v_name from supplier_profiles sp where sp.id = p_supplier_id;
  end if;
  if v_name is null then return; end if;

  return query
  select so.id, so.order_no, so.created_at, so.status, so.total_amount,
         coalesce(jsonb_array_length(so.items),0) as item_count,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'product_id',        it->>'product_id',
                    'product_name',      it->>'product_name',
                    'quantity',          (it->>'quantity')::numeric,
                    'asked_qty',         it->'asked_qty',
                    'partial',           coalesce((it->>'partial')::boolean, false),
                    'pack_type',         nullif(btrim(med.pack_type),''),
                    'image_url',         nullif(btrim(med.image_url_1),''),
                    'therapeutic_class', nullif(btrim(med.therapeutic_class),''),
                    'company',           nullif(btrim(med.marketer),''),
                    'rate',              it->'rate',
                    'rate_source',       it->>'rate_source',
                    'rate_display',      it->>'rate_display',
                    'mrp_display',       it->>'mrp_display',
                    'line_total',        it->'line_total',
                    'line_total_display', it->>'line_total_display',
                    'price_basis_label', it->>'price_basis_label',
                    'batch_no',          d.batch_no,
                    'expiry',            d.expiry,
                    'hsn',               d.hsn
                  ) order by it->>'product_name')
           from jsonb_array_elements(so.items) it
           left join "MEDICINE" med on med.id = (it->>'product_id')::bigint
           left join public.supplier_order_line_detail d
                  on d.supplier_order_id = so.id
                 and d.product_id = (it->>'product_id')::bigint
         ), '[]'::jsonb) as items,
         so.order_code,
         coalesce(so.packed,false) as packed,
         so.packed_via,
         jsonb_build_object(
           'label',       case when coalesce(so.packed,false) then 'Packed ✓' else 'Mark Packed' end,
           'next_packed', not coalesce(so.packed,false),
           'enabled',     (coalesce(so.accept_state,'pending') in ('accepted','partial')),
           'blocked_reason',
             case when coalesce(so.accept_state,'pending') in ('accepted','partial') then null
                  else public.uic('supplier_po.pack_blocked',
                                  'Accept the order before you mark it packed') end,
           'bg',          case when coalesce(so.packed,false) then '#E1F5EE' else '#1B7A43' end,
           'fg',          case when coalesce(so.packed,false) then '#0F6E56' else '#FFFFFF' end
         ) as pack_button,
         public.po_pricing_block(so.id) as pricing,
         public.supplier_po_accept_block(coalesce(so.accept_state,'pending'),
                                         coalesce(so.packed,false), so.decline_reason) as accept,
         jsonb_build_object(
           'title',        public.uic('supplier_po.details_title','Batch & expiry'),
           'hint',         public.uic('supplier_po.details_hint','Required on the purchase bill'),
           'batch_label',  public.uic('supplier_po.batch_label','Batch no.'),
           'expiry_label', public.uic('supplier_po.expiry_label','Expiry (MM/YY)'),
           'hsn_label',    public.uic('supplier_po.hsn_label','HSN'),
           'save_label',   public.uic('supplier_po.save_details','Save batch & expiry'),
           'status_label',
             case when exists (select 1 from public.supplier_order_line_detail d
                                where d.supplier_order_id = so.id
                                  and d.batch_no is not null and d.expiry is not null)
                  then public.uic('supplier_po.details_done','Batch and expiry filled')
                  else public.uic('supplier_po.details_missing','Batch and expiry not filled') end,
           'complete',
             not exists (select 1 from jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it2
                          where not exists (select 1 from public.supplier_order_line_detail d2
                                             where d2.supplier_order_id = so.id
                                               and d2.product_id = (it2->>'product_id')::bigint
                                               and d2.batch_no is not null
                                               and d2.expiry is not null))
         ) as line_details
  from supplier_orders so
  where so.supplier_name = v_name
  order by so.created_at desc, so.order_no desc;
end;
$function$;

grant execute on function public.supplier_my_orders(uuid) to anon, authenticated, service_role;
