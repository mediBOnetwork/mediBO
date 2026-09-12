-- CHANGE #304 (e) — reference_id must be unique per ATTEMPT, not per second.
-- The first cut stamped it to the second, so two prepares inside one second
-- collided on rzp_payment_attempt_ref_uk. Razorpay also rejects a duplicate
-- reference_id, so this was a real "second tap fails" bug, not a test artefact.
create or replace function public.rzp_checkout_prepare(
  p_order_id uuid, p_kind text default 'advance', p_mode text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_mode text; v_kind text; v_amount numeric; v_code text; v_hours integer;
  v_open public.rzp_payment_attempt%rowtype; v_ref text;
begin
  select order_code into v_code from orders where id = p_order_id;
  if v_code is null then
    return jsonb_build_object('ok', false, 'error','order_not_found');
  end if;

  v_mode := coalesce(nullif(btrim(coalesce(p_mode,'')),''), public.rzp_pay_mode(p_order_id));
  if v_mode = 'manual' then
    return jsonb_build_object('ok', false, 'pay_mode','manual', 'provider','upi_manual');
  end if;

  v_kind   := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;
  v_amount := public.rzp_amount_due(p_order_id, v_kind);
  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'error','nothing_due',
                              'message', public._rzp_copy('nothing_due_label'));
  end if;

  select greatest(coalesce(razorpay_close_hours,24),1) into v_hours
    from payment_config where id = 1;
  v_hours := coalesce(v_hours, 24);

  -- RESUME, never duplicate: an attempt that is still open for this exact
  -- order+kind+amount is handed straight back with the SAME Razorpay link.
  select * into v_open from public.rzp_payment_attempt
   where order_id = p_order_id and kind = v_kind
     and status in ('pending','attempted')
     and round(amount,2) = round(v_amount,2)
     and coalesce(expires_at, created_at + make_interval(hours => v_hours)) > now()
     and short_url is not null
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'reused', true, 'pay_mode', v_mode,
                              'view', public._rzp_attempt_view(v_open.id));
  end if;

  -- A stale open attempt for a DIFFERENT amount is closed, not left dangling.
  update public.rzp_payment_attempt
     set status = 'expired', failure_reason = 'superseded'
   where order_id = p_order_id and kind = v_kind
     and status in ('pending','attempted');

  insert into public.rzp_payment_attempt (order_id, kind, mode, amount, expires_at)
  values (p_order_id, v_kind, v_mode, v_amount, now() + make_interval(hours => v_hours))
  returning * into v_open;

  -- Unique per attempt by construction. Razorpay refuses a repeated
  -- reference_id, so this is also what stops it minting two links for one tap.
  v_ref := v_code || ':' || v_kind || ':' || replace(v_open.id::text,'-','');
  update public.rzp_payment_attempt set reference_id = v_ref where id = v_open.id;

  return jsonb_build_object(
    'ok', true, 'reused', false, 'pay_mode', v_mode,
    'attempt_id', v_open.id,
    'kind', v_kind,
    'order_code', v_code,
    'amount', v_amount,
    'amount_paise', (round(v_amount, 2) * 100)::bigint,
    'reference_id', v_ref,
    'expire_by', (extract(epoch from v_open.expires_at))::bigint,
    'description', 'mediBO ' || v_code || ' — ' || v_kind,
    'notes', jsonb_build_object('order_id', p_order_id::text, 'order_code', v_code,
                                'kind', v_kind, 'attempt_id', v_open.id::text));
end $$;
revoke execute on function public.rzp_checkout_prepare(uuid, text, text) from anon, authenticated;
