-- CHANGE #472 — the STOCK edges, and the webhook's front door.
--
-- Every function below was already idempotent BY STATE CHECK — it reads a
-- status, decides, and writes. That is a correct answer to a sequential replay
-- and no answer at all to a concurrent one: both callers read the same status
-- before either writes. The fix is the row lock the check always assumed it
-- had, added at the SELECT that reads the status. Nothing else changes, so the
-- payloads and the copy keys are untouched.
--
-- Left alone deliberately, because the audit found them already safe:
--   delivery_replay      — the house standard (client_action_id PK + stored result)
--   pos_commit_sale      — #411, unique client_action_id on pos_sales
--   khata_entry_add      — #415, unique client_action_id on khata_entry
--   bill_job_enqueue     — `on conflict (idem_key) do nothing` + already_billed
--   pack_undo_item       — a converging reset: the second fire finds nothing packed
--   pack_set_dispatch_ready — recomputes a flag from the lines every time
--   settlement_close_due — selects `status='open'` and leaves them 'due'
--   _rzp_refund_apply    — `where ... and status <> 'processed'`

-- ── DELIVERY COMPLETION (all three proof methods) ──────────────────────────
-- `if d.status = 'delivered' then return already` is the correct answer and
-- was read with nothing holding the row, so a rider tapping Delivered twice on
-- a slow connection — or the OTP method and the photo method arriving together
-- from a replayed offline queue — could both pass the check and both write the
-- completion, the delivery_events row and the customer notification.
CREATE OR REPLACE FUNCTION public._delivery_complete(p_delivery_id uuid, p_method text, p_lat numeric, p_lng numeric, p_receiver text DEFAULT NULL::text, p_photo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d public.deliveries%rowtype;
  v_actor text := coalesce(auth.jwt()->>'email','system');
  v_cfg jsonb; v_radius numeric; v_action text;
  v_dist numeric; v_dist_m integer; v_ok boolean; v_flag boolean := false;
begin
  -- CHANGE #472 — hold the stop while we decide, so a second tap waits here
  -- and then reads status='delivered' instead of racing this one.
  select * into d from public.deliveries where id = p_delivery_id for update;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if d.status = 'delivered' then
    return jsonb_build_object('ok',true,'already',true,'message','Already delivered',
      'delivered_at', d.delivered_at);
  end if;

  -- CHANGE #462 (gap 105): completion is a TRANSITION, not an assignment. Only
  -- a stop that is actually out with a rider can be closed. 'failed', 'rto',
  -- 'cancelled' and 'unassigned' are terminal or unowned here — a failed stop
  -- comes back through delivery_redeliver, which is what that function is for.
  if d.status not in ('assigned','out_for_delivery') then
    return jsonb_build_object('ok',false,'error','bad_state','status', d.status,
      'title',   public._c('delivery.bad_state_title'),
      'message', public._c('delivery.bad_state_msg'));
  end if;

  -- CHANGE #309 (1): custody must be on record before a delivery can be closed.
  if d.handover_at is null and not public._handover_exempt(d) then
    return jsonb_build_object('ok',false,'error','handover_required',
      'title',   public._c('delivery.handover_required_title'),
      'message', public._c('delivery.handover_required_msg'));
  end if;

  -- CHANGE #309 (10): a temperature-sensitive parcel needs a photo at the door.
  if d.is_cold_chain
     and coalesce((public._dcfg(d.zone_id)->>'cold_chain_photo_required')::boolean, true)
     and nullif(btrim(coalesce(p_photo,'')),'') is null
     and nullif(btrim(coalesce(d.proof_photo_path,'')),'') is null then
    return jsonb_build_object('ok',false,'error','cold_chain_photo_required',
      'title',   public._c('delivery.cold_chain_badge'),
      'message', public._c('delivery.cold_chain_photo_required'));
  end if;

  -- CHANGE #462 (gap 106): the coordinates the app has always sent are finally
  -- compared with the stop. Default action is FLAG, not block — a rider with a
  -- bad GPS fix must never be stranded at a customer's door — but the run now
  -- carries the evidence, and an admin can switch the knob to 'block'.
  v_cfg    := public._dcfg(d.zone_id);
  v_radius := nullif((v_cfg->>'geofence_radius_m')::numeric, 0);
  v_action := coalesce(v_cfg->>'completion_geofence_action', 'flag');

  if p_lat is not null and p_lng is not null and d.lat is not null and d.lng is not null then
    v_dist   := public._geo_m(d.lat, d.lng, p_lat, p_lng);
    v_dist_m := round(v_dist)::int;
    v_ok     := (v_radius is null) or (v_dist <= v_radius);
    if not v_ok and v_action = 'block' then
      return jsonb_build_object('ok',false,'error','outside_geofence',
        'distance_m', v_dist_m, 'radius_m', v_radius,
        'title',   public._c('delivery.too_far_title'),
        'message', public._c('delivery.too_far_msg'));
    end if;
    v_flag := (not coalesce(v_ok,true)) and v_action <> 'off';
  end if;

  update public.deliveries
     set status='delivered', delivered_at=now(), proof_method=p_method,
         delivered_lat=p_lat, delivered_lng=p_lng,
         delivered_distance_m=v_dist_m,
         geofence_ok=v_ok,
         completion_flagged=v_flag,
         receiver_name=coalesce(nullif(btrim(coalesce(p_receiver,'')),''), receiver_name),
         proof_photo_path=coalesce(p_photo, proof_photo_path)
   where id = p_delivery_id;

  update public.orders set shipped_at = coalesce(shipped_at, now()) where id = d.order_id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'delivered', p_method, p_lat, p_lng, v_actor);

  if v_flag then
    insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'geofence_flag',
            v_dist_m::text || 'm from the stop (radius ' || coalesce(v_radius::text,'-') || 'm)',
            p_lat, p_lng, v_actor);
  end if;

  -- CHANGE #295: window-gated. Free-form only while the window is open.
  begin
    perform public.wa_notify_event(
      'delivery_delivered', null, '{}'::jsonb, null, d.order_id,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
      jsonb_build_object('event','delivered','delivery_id',p_delivery_id));
  exception when others then
    perform public._wa_log_attempt('delivery_delivered', d.order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  return jsonb_build_object('ok',true,'status','delivered','method',p_method,
    'message','Delivered', 'delivered_at', now(),
    'distance_m', v_dist_m, 'geofence_ok', v_ok, 'flagged', v_flag);
end $function$;

-- ── SIGNATURE PROOF ────────────────────────────────────────────────────────
-- The signature event row was inserted before the completion choke point, so
-- it landed on every call even when _delivery_complete then answered 'already
-- delivered'. The proof timeline grew a duplicate line per retry.
CREATE OR REPLACE FUNCTION public.delivery_attach_signature(p_delivery_id uuid, p_signature_path text, p_receiver text DEFAULT NULL::text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_res jsonb;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid())
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if nullif(btrim(coalesce(p_signature_path,'')),'') is null then
    return jsonb_build_object('ok',false,'error','signature_required',
      'message', public.uic('delivery.signature_required','Capture the signature first.'));
  end if;

  update deliveries
     set signature_path = p_signature_path,
         receiver_name  = coalesce(nullif(btrim(coalesce(p_receiver,'')),''), receiver_name)
   where id = p_delivery_id;
  -- CHANGE #472 — one signature line per delivery. A retry updates the proof
  -- above (same path, same receiver) and adds no second event.
  if not exists (select 1 from delivery_events
                  where delivery_id = p_delivery_id and event = 'signature') then
    insert into delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
    values (p_delivery_id, d.order_id, d.partner_id, 'signature',
            nullif(btrim(coalesce(p_receiver,'')),''), p_lat, p_lng,
            coalesce(auth.jwt()->>'email','rider'));
  end if;

  -- the same choke point the photo and OTP methods use: custody, cold-chain and
  -- the delivered notification are all decided in there, once, for every method.
  v_res := public._delivery_complete(p_delivery_id, 'signature', p_lat, p_lng, p_receiver, null);
  return coalesce(v_res, '{}'::jsonb) || jsonb_build_object('signature_saved', true);
end $function$;

-- ── PAPER SALE CONFIRM (#429) ──────────────────────────────────────────────
-- Confirming a sheet pours stock out of lots and feeds the velocity table.
-- The 'already confirmed' guard was a bare read: two taps on a slow tablet
-- both saw 'open' and both drained the lots.
CREATE OR REPLACE FUNCTION public.paper_sale_confirm(p_sheet_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public._c429_shop();
  v_s    public.pharmacy_sale_sheet%rowtype;
  v_line record; v_lot record;
  v_need numeric; v_take numeric; v_item text; v_nkey text;
  v_lines integer := 0; v_units numeric := 0; v_short numeric := 0;
begin
  if v_shop is null then return public._c429_denied(); end if;
  -- CHANGE #472 — lock the sheet for the whole confirm, so the status check
  -- below is the only one that can win.
  select * into v_s from public.pharmacy_sale_sheet
   where id = p_sheet_id and pharmacy_id = v_shop
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_sheet',
                              'message', public.ui_text('paper429.err_no_sheet'));
  end if;
  if v_s.status = 'confirmed' then
    return jsonb_build_object('ok', true, 'already', true, 'sheet_id', p_sheet_id,
      'message', public.ui_text('paper429.already_confirmed'));
  end if;

  for v_line in
    select * from public.pharmacy_sale_line
     where sheet_id = p_sheet_id
       and is_new                         -- live tally: only what is new counts
       and flag not in ('dropped', 'unreadable', 'unmatched')
       and medicine_id is not null
       and coalesce(qty, 0) > 0
     order by line_no
  loop
    v_need  := v_line.qty;
    v_lines := v_lines + 1;
    v_units := v_units + v_need;
    v_item  := public._phs_item_key(v_line.medicine_id, v_line.product_name);
    v_nkey  := 'n:' || public._norm_name(coalesce(v_line.product_name, ''));

    for v_lot in
      select s.id, s.qty from public.pharmacy_stock s
       where s.pharmacy_id = v_shop
         and (s.item_key = v_item or s.name_key = v_nkey)
         and s.qty > 0
       order by s.expiry_on asc nulls last, s.created_at asc
    loop
      exit when v_need <= 0;
      v_take := least(v_lot.qty, v_need);
      perform public._phs_apply(
        p_shop        => v_shop,
        p_medicine_id => v_line.medicine_id,
        p_name        => v_line.product_name,
        p_pack        => v_line.pack_label,
        p_batch       => null, p_expiry => null,
        p_qty_delta   => -v_take,
        p_unit_cost   => null, p_mrp => null,
        p_kind        => 'sale',
        p_source_kind => null,
        p_note        => public.ui_text('paper429.move_note'),
        p_ref_kind    => 'paper_line_lot',
        p_ref_id      => v_line.id::text || ':' || v_lot.id::text,
        p_lot_id      => v_lot.id);
      v_need := v_need - v_take;
    end loop;

    -- Anything the shelf still could not account for. The counter was offered
    -- the opening-stock correction and declined it, so it is recorded honestly
    -- as a shortfall rather than quietly dropped.
    if v_need > 0 then
      perform public._phs_apply(
        p_shop        => v_shop,
        p_medicine_id => v_line.medicine_id,
        p_name        => v_line.product_name,
        p_pack        => null, p_expiry => null, p_batch => null,
        p_qty_delta   => -v_need,
        p_unit_cost   => null, p_mrp => null,
        p_kind        => 'sale',
        p_source_kind => 'adjustment',
        p_note        => public.ui_text('paper429.short_note'),
        p_ref_kind    => 'paper_line_short',
        p_ref_id      => v_line.id::text);
      v_short := v_short + v_need;
    end if;

    update public.pharmacy_sale_line set applied = true where id = v_line.id;

    -- The usual quantity learns from what was actually confirmed.
    insert into public.pharmacy_sale_qty_default as d
      (pharmacy_id, medicine_id, usual_qty, seen_count)
    values (v_shop, v_line.medicine_id, v_line.qty, 1)
    on conflict (pharmacy_id, medicine_id) do update
      set usual_qty = round((d.usual_qty * d.seen_count + excluded.usual_qty)
                            / (d.seen_count + 1), 2),
          seen_count = d.seen_count + 1,
          updated_at = now();

    -- GROUND TRUTH into #424's posterior. A day of observed selling is a day of
    -- evidence, and it outranks any presumption the engine had made.
    begin
      insert into public.pharmacy_sku_velocity as v
        (pharmacy_id, medicine_id, alpha, beta, per_day, units_seen, days_seen,
         source, updated_at)
      values (v_shop, v_line.medicine_id, v_line.qty, 1, v_line.qty,
              v_line.qty, 1, 'paper_sale', now())
      on conflict (pharmacy_id, medicine_id) do update
        set alpha = v.alpha + excluded.alpha,
            beta  = v.beta  + excluded.beta,
            per_day = (v.alpha + excluded.alpha) / nullif(v.beta + excluded.beta, 0),
            units_seen = v.units_seen + excluded.units_seen,
            days_seen  = v.days_seen  + excluded.days_seen,
            source = 'paper_sale',
            updated_at = now();
    exception when others then
      raise warning 'c429: velocity feed skipped for line % — %', v_line.id, sqlerrm;
    end;
  end loop;

  update public.pharmacy_sale_sheet
     set status = 'confirmed', confirmed_at = now(),
         tally_cursor = greatest(tally_cursor, line_count)
   where id = p_sheet_id;

  -- Re-pour the inference on the new evidence.
  begin
    perform public.pharmacy_infer_lots(v_shop);
  exception when others then
    raise warning 'c429: inference re-pour skipped — %', sqlerrm;
  end;

  return jsonb_build_object('ok', true, 'sheet_id', p_sheet_id,
    'lines', v_lines, 'units', v_units, 'short', v_short,
    'message', public._c429_fmt('paper429.confirmed',
                 jsonb_build_object('n', v_lines::text, 'u', v_units::text)),
    'short_note', case when v_short > 0
      then public._c429_fmt('paper429.short_summary',
             jsonb_build_object('n', v_short::text)) end);
end $function$;

-- ── PARCEL COUNT LEDGER (#431) ─────────────────────────────────────────────
-- Finishing a count writes lot corrections and moves stock. `if c.status <>
-- 'open'` was read without a lock, so a double-fire could apply the same
-- deltas twice. (phpc_one_open already stops a second OPEN session existing;
-- this stops the one session being finished twice.)
CREATE OR REPLACE FUNCTION public.pharmacy_parcel_finish(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public._c431_shop();
  c      public.pharmacy_parcel_count%rowtype;
  l      public.pharmacy_parcel_count_line%rowtype;
  v_lot  uuid;
  v_delta numeric;
  v_ver  integer := 0;
  v_iss  integer := 0;
  v_conf jsonb;
begin
  if v_shop is null then return public._c431_denied(); end if;
  -- CHANGE #472 — hold the session while its lines are applied.
  select * into c from public.pharmacy_parcel_count
   where id = p_session_id and pharmacy_id = v_shop
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_session',
                              'message', public.ui_text('phpc.err_no_session'));
  end if;
  if c.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'closed',
                              'message', public.ui_text('phpc.err_closed'));
  end if;
  if c.lines_counted = 0 then
    return jsonb_build_object('ok', false, 'error', 'nothing_counted',
                              'message', public.ui_text('phpc.err_nothing'));
  end if;

  -- Counted values land on the bill line BESIDE the billed ones. The invoice
  -- keeps its own numbers so #416's GST purchase register still reports what
  -- the supplier actually invoiced.
  for l in
    select * from public.pharmacy_parcel_count_line
     where session_id = p_session_id and verdict <> 'pending'
     order by line_no
  loop
    if l.bill_line_id is not null then
      update public.pharmacy_purchase_bill_line
         set counted_qty    = l.counted_qty,
             counted_batch  = l.counted_batch,
             counted_expiry = l.counted_expiry,
             count_verdict  = l.verdict
       where id = l.bill_line_id;
    end if;
    if l.verdict <> 'match' then v_iss := v_iss + 1; end if;
  end loop;

  if c.kind = 'outside' then
    -- One writer of a lot: #423's confirm, now reading the counted numbers.
    v_conf := public.pharmacy_vault_bill_confirm(c.bill_id);
  end if;

  for l in
    select * from public.pharmacy_parcel_count_line
     where session_id = p_session_id and verdict <> 'pending'
       and counted_qty is not null
     order by line_no
  loop
    v_lot := null;

    if c.kind = 'medibo' then
      -- A WRONG BATCH is not a quantity problem, it is two lots. The shelf was
      -- given the batch the bill promised; what actually arrived is a
      -- different batch entirely. So the promised lot is taken back to zero and
      -- the batch in the box is added beside it — otherwise the expiry radar
      -- would spend the next two years watching a batch that never existed.
      if public._c431_batch_key(l.counted_batch) is not null
         and public._c431_batch_key(l.expected_batch)
             is distinct from public._c431_batch_key(l.counted_batch)
      then
        perform public._phs_apply(
          p_shop        => v_shop,
          p_medicine_id => l.medicine_id,
          p_name        => l.product_name,
          p_pack        => l.pack_label,
          p_batch       => l.expected_batch,
          p_expiry      => l.expected_expiry,
          p_qty_delta   => -coalesce(l.expected_qty, 0),
          p_unit_cost   => l.unit_cost,
          p_mrp         => l.mrp,
          p_kind        => 'count_verify',
          p_source_kind => 'medibo_order',
          p_reason      => 'parcel_count',
          p_note        => public.ui_fmt('phpc.move_wrong_batch', jsonb_build_object(
                             'exp', coalesce(l.expected_batch, '—'),
                             'got', coalesce(l.counted_batch, '—'))),
          p_ref_kind    => 'parcel_count_rev',
          p_ref_id      => l.id::text,
          p_order_id    => c.order_id,
          p_actor       => l.counted_by);
        v_delta := coalesce(l.counted_qty, 0);
      else
        -- The shelf already holds what the bill said. Move it to what the hands
        -- found; a matching line moves it by zero and is still stamped verified.
        v_delta := coalesce(l.counted_qty, 0) - coalesce(l.expected_qty, 0);
      end if;
      if v_delta <> 0 then
        v_lot := public._phs_apply(
          p_shop        => v_shop,
          p_medicine_id => l.medicine_id,
          p_name        => l.product_name,
          p_pack        => l.pack_label,
          p_batch       => coalesce(l.counted_batch, l.expected_batch),
          p_expiry      => coalesce(l.counted_expiry, l.expected_expiry),
          p_qty_delta   => v_delta,
          p_unit_cost   => l.unit_cost,
          p_mrp         => l.mrp,
          p_kind        => 'count_verify',
          p_source_kind => 'medibo_order',
          p_reason      => 'parcel_count',
          p_note        => public.ui_fmt('phpc.move_note', jsonb_build_object(
                             'exp', public._phs_qty(l.expected_qty),
                             'got', public._phs_qty(l.counted_qty))),
          p_ref_kind    => 'parcel_count',
          p_ref_id      => l.id::text,
          p_order_id    => c.order_id,
          p_actor       => l.counted_by);
      end if;
    end if;

    -- Find the lot this line settled on, whichever path wrote it.
    if v_lot is null and l.bill_line_id is not null then
      select lot_id into v_lot from public.pharmacy_purchase_bill_line
       where id = l.bill_line_id;
    end if;
    if v_lot is null then
      select id into v_lot from public.pharmacy_stock
       where pharmacy_id = v_shop
         and item_key   = coalesce(l.item_key, public._phs_item_key(l.medicine_id, l.product_name))
         and batch_key  = upper(coalesce(nullif(btrim(coalesce(l.counted_batch, l.expected_batch, '')), ''), '~'))
         and expiry_key = coalesce(nullif(btrim(coalesce(l.counted_expiry, l.expected_expiry, '')), ''), '~')
       limit 1;
    end if;

    if v_lot is not null then
      update public.pharmacy_parcel_count_line set lot_id = v_lot where id = l.id;
      update public.pharmacy_stock
         set verified_at = now(), verified_by = l.counted_by,
             verified_qty = l.counted_qty, verify_session = p_session_id,
             is_unquantified = false
       where id = v_lot;

      -- #424's ground truth. A lot counted on arrival is known exactly, and
      -- this is the channel its posterior already treats as method='corrected'.
      if l.medicine_id is not null then
        insert into public.pharmacy_lot_correction (
          lot_id, pharmacy_id, medicine_id, actual_left, inferred_was, source, created_by)
        select v_lot, v_shop, l.medicine_id, l.counted_qty,
               (select inferred_left from public.pharmacy_lot_inference where lot_id = v_lot),
               'parcel_count', l.counted_by;
      end if;
      v_ver := v_ver + 1;
    end if;
  end loop;

  update public.pharmacy_parcel_count
     set status = 'done', finished_at = now(), updated_at = now()
   where id = p_session_id;

  update public.pharmacy_purchase_bill
     set count_status = 'counted', counted_at = now(),
         discrepancy_count = v_iss
   where id = c.bill_id;

  -- Re-run the posterior so the corrections are visible immediately. Never let
  -- a slow recompute lose a finished count.
  begin
    perform public.pharmacy_infer_lots(v_shop);
  exception when others then
    raise warning 'c431: inference recompute skipped — %', sqlerrm;
  end;

  return jsonb_build_object('ok', true,
    'session_id', p_session_id,
    'verified',   v_ver,
    'issues',     v_iss,
    'title',      public.ui_text('phpc.done_title'),
    'message',    public.ui_fmt('phpc.done', jsonb_build_object(
                    'n', v_ver::text, 'i', v_iss::text)),
    'evidence',   case when c.kind = 'outside' and v_iss > 0
                       then public.ui_text('phpc.evidence_outside') else null end,
    'tone',       case when v_iss > 0 then 'warning' else 'success' end);
end $function$;


-- ── THE RAZORPAY WEBHOOK, KEYED ON ITS OWN EVENT ID ────────────────────────
-- (the unique index on razorpay_webhook_log.rzp_event_id ships in
--  20260904100100_c472_money_edges.sql, alongside the other money keys)
CREATE OR REPLACE FUNCTION public.rzp_webhook_apply(p_event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_event text := p_event->>'event';
  v_qr    jsonb := p_event #> '{payload,qr_code,entity}';
  v_pay   jsonb := p_event #> '{payload,payment,entity}';
  v_qrid  text  := v_qr->>'id';
  v_payid text  := v_pay->>'id';
  v_order uuid;
  v_amount numeric;
  v_row   public.razorpay_qr%rowtype;
  v_claim uuid; v_ph text; v_owner uuid;
  v_out jsonb;
  v_log bigint;
  v_n   integer;
  v_evid text; v_done jsonb;
begin
  v_evid := nullif(btrim(coalesce(p_event->>'id','')),'');

  -- CHANGE #472 — the FRONT DOOR. Razorpay redelivers on any non-2xx, and the
  -- edge function answers 500 on a partial failure precisely so that it will.
  -- Every handled event was then re-run from the top: the money paths survived
  -- that on payment_claims' unique index, but the log grew a row per delivery
  -- and each redelivery paid for the whole match again. x-razorpay-event-id was
  -- already being stored here — it simply was not unique, so it could not be
  -- used as the key it is. A redelivery now gets the first answer back.
  if v_evid is not null then
    select result into v_done from public.razorpay_webhook_log
     where rzp_event_id = v_evid and handled and result is not null
     limit 1;
    if v_done is not null then
      return v_done || jsonb_build_object('replayed', true);
    end if;
  end if;

  insert into public.razorpay_webhook_log (event, rzp_event_id, payload_id, handled)
  values (coalesce(v_event,'(none)'), v_evid, coalesce(v_payid, v_qrid), false)
  on conflict (rzp_event_id)
    where rzp_event_id is not null and btrim(rzp_event_id) <> ''
    do update set received_at = now(), handled = false
  returning id into v_log;

  delete from public.razorpay_webhook_log where received_at < now() - interval '30 days';

  if v_event = 'qr_code.closed' then
    with upd as (
      update public.razorpay_qr
         set status        = case when status = 'paid' then 'paid' else 'closed' end,
             closed_reason = case when status = 'paid' then closed_reason
                                  else coalesce(v_qr->>'close_reason', 'closed') end
       where rzp_qr_id = v_qrid
      returning 1
    )
    select count(*) into v_n from upd;
    v_out := jsonb_build_object('ok', true, 'closed', v_n > 0,
                                'matched', v_n, 'qr_id', v_qrid);
    update public.razorpay_webhook_log
       set handled = (v_n > 0), result = v_out where id = v_log;
    return v_out;
  end if;

  -- ── CHANGE #395 — money going BACK. Razorpay settles a refund
  -- asynchronously, so its webhook (not our create call) is what marks one
  -- processed. Matched on the provider refund id, falling back to the notes we
  -- sent, and never downgrading a refund already marked processed.
  if v_event in ('refund.created','refund.processed','refund.failed',
                 'refund.speed_changed') then
    return public._rzp_refund_apply(p_event, v_log);
  end if;

  if v_event in ('payment_link.paid','payment_link.expired','payment_link.cancelled',
                 'payment.captured','payment.failed') then
    declare
      v_link jsonb := p_event #> '{payload,payment_link,entity}';
      v_att  uuid  := public._rzp_attempt_match(
                        coalesce(p_event #> '{payload,payment_link,entity}','{}'::jsonb),
                        coalesce(v_pay,'{}'::jsonb));
      v_ord  uuid;
      v_amt  numeric;
    begin
      if v_att is null and v_event in ('payment.captured','payment.failed') then
        v_out := jsonb_build_object('ok', true, 'ignored', v_event, 'reason','no_attempt');
        update public.razorpay_webhook_log set result = v_out where id = v_log;
        return v_out;
      end if;

      if v_event in ('payment_link.expired','payment_link.cancelled') then
        update public.rzp_payment_attempt
           set status = case when status = 'paid' then 'paid' else 'expired' end,
               failure_reason = case when status = 'paid' then failure_reason
                                     else replace(v_event,'payment_link.','') end
         where id = v_att;
        v_out := jsonb_build_object('ok', true, 'attempt_id', v_att, 'event', v_event);
        update public.razorpay_webhook_log set handled = (v_att is not null), result = v_out
         where id = v_log;
        return v_out;
      end if;

      if v_event = 'payment.failed' then
        update public.rzp_payment_attempt
           set status = case when status = 'paid' then 'paid' else 'failed' end,
               failure_reason = case when status = 'paid' then failure_reason
                                     else left(coalesce(v_pay->>'error_description','failed'),200) end
         where id = v_att;
        v_out := jsonb_build_object('ok', true, 'attempt_id', v_att, 'event', v_event);
        update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
        return v_out;
      end if;

      if nullif(btrim(coalesce(v_payid,'')),'') is null then
        v_out := jsonb_build_object('ok', false, 'error','no_payment_id', 'event', v_event);
        update public.razorpay_webhook_log set result = v_out where id = v_log;
        return v_out;
      end if;

      v_ord := nullif(coalesce(v_link #>> '{notes,order_id}',
                               v_pay  #>> '{notes,order_id}'), '')::uuid;
      if v_ord is null and v_att is not null then
        select order_id into v_ord from public.rzp_payment_attempt where id = v_att;
      end if;
      v_amt := round(coalesce((v_pay->>'amount')::numeric,
                              (v_link->>'amount_paid')::numeric, 0) / 100.0, 2);

      v_out := public._rzp_checkout_credit(v_att, v_ord, v_payid, v_amt, v_pay->>'method');
      update public.razorpay_webhook_log
         set handled = coalesce((v_out->>'ok')::boolean,false), result = v_out where id = v_log;
      return v_out;
    end;
  end if;

  if v_event is distinct from 'qr_code.credited' then
    v_out := jsonb_build_object('ok', true, 'ignored', coalesce(v_event,'(none)'));
    update public.razorpay_webhook_log set result = v_out where id = v_log;
    return v_out;
  end if;

  if nullif(btrim(coalesce(v_payid,'')),'') is null then
    v_out := jsonb_build_object('ok', false, 'error', 'no_payment_id');
    update public.razorpay_webhook_log set result = v_out where id = v_log;
    return v_out;
  end if;

  if exists (select 1 from payment_claims
              where utr = v_payid and payment_method = 'razorpay_qr') then
    v_out := jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
    update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
    return v_out;
  end if;

  v_order := nullif(coalesce(v_qr #>> '{notes,order_id}', v_pay #>> '{notes,order_id}'), '')::uuid;
  select * into v_row from public.razorpay_qr where rzp_qr_id = v_qrid;
  if v_order is null then v_order := v_row.order_id; end if;
  if v_order is null then
    v_out := jsonb_build_object('ok', false, 'error', 'unmatched_order', 'qr_id', v_qrid);
    update public.razorpay_webhook_log set result = v_out where id = v_log;
    return v_out;
  end if;

  v_amount := round(coalesce((v_pay->>'amount')::numeric, 0) / 100.0, 2);

  update public.razorpay_qr
     set status = 'paid', payment_id = v_payid, paid_at = now(),
         closed_reason = coalesce(v_qr->>'close_reason', 'paid')
   where rzp_qr_id = v_qrid;

  select o.user_id into v_owner from orders o where o.id = v_order;
  select right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
    into v_ph from pharmacy_profiles pp
   where pp.user_id = v_owner and coalesce(pp.is_deleted,false) = false limit 1;

  begin
    insert into payment_claims (
      order_id, sender_phone, sender_type, amount, utr, txn_id, app,
      payee_name, status, verify_reason, payment_method, received_at, created_at)
    values (
      v_order, v_ph, 'customer', v_amount, v_payid, v_payid,
      coalesce(v_pay->>'method','upi'), 'Razorpay', 'verified',
      public._rzp_copy('claim_reason'), 'razorpay_qr', now(), now())
    returning id into v_claim;
  exception
    when unique_violation then
      v_out := jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
      update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
      return v_out;
  end;

  update orders
     set status = 'accepted',
         payment_id = v_payid
   where id = v_order and coalesce(status,'') <> 'accepted';

  v_out := jsonb_build_object('ok', true, 'order_id', v_order, 'claim_id', v_claim,
                              'payment_id', v_payid, 'amount', v_amount);
  update public.razorpay_webhook_log set handled = true, result = v_out where id = v_log;
  return v_out;
exception
  when unique_violation then
    v_out := jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
    insert into public.razorpay_webhook_log (event, rzp_event_id, payload_id, handled, result)
    values (coalesce(v_event,'(none)'),
            nullif(btrim(coalesce(p_event->>'id','')),''),
            coalesce(v_payid, v_qrid), true, v_out)
    on conflict (rzp_event_id)
      where rzp_event_id is not null and btrim(rzp_event_id) <> ''
      do update set handled = true, result = excluded.result;
    return v_out;
end $function$;
