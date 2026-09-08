-- CHANGE #708 (follow-up) — ask WHO before answering WHAT.
--
-- Found by this command's own hostile pass: order_resume() checked "is this
-- order on hold?" before "is this order yours?", so any signed-in login that
-- knew an order id learned whether it was parked. Nothing could be written —
-- the actor check still guarded every write — but the answer itself was a fact
-- about somebody else's order. The actor question goes first; a stranger now
-- gets the same sentence whether the order is held or not.
-- Idempotent.

create or replace function public.order_resume(
  p_order_id uuid, p_note text default null, p_kind text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  h order_hold%rowtype;
  v_act jsonb;
  v_kind text := nullif(btrim(coalesce(p_kind,'')),'');
  v_sync jsonb; v_cust uuid; v_phone text; v_code text;
begin
  -- WHO is asking, before anything is said about the order.
  if v_kind = 'system' then
    v_act := jsonb_build_object('has', true, 'kind','system',
                                'label', _c('order_hold.held_by_system'));
  else
    v_act := public._c708_actor(p_order_id);
    if not coalesce((v_act->>'has')::boolean,false) then
      return jsonb_build_object('ok', false, 'error','not_yours', 'tone','danger',
        'message', _c('order_hold.err_not_yours'));
    end if;
  end if;

  select * into h from order_hold where order_id = p_order_id and status='active' limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_held', 'tone','danger',
      'message', _c('order_hold.err_not_held'),
      'state', public.order_hold_state(p_order_id));
  end if;

  update order_hold
     set status = 'resumed',
         resumed_at = now(),
         resumed_by = auth.uid(),
         resumed_kind = v_act->>'kind',
         resume_note = nullif(btrim(coalesce(p_note,'')),''),
         held_seconds = greatest(0, extract(epoch from (now() - held_at)))::bigint
   where id = h.id;

  -- The waterfall may have moved on while this order was parked: a supplier
  -- that has since gone dark, or a new standby that now outranks the one we
  -- were waiting on. Re-ranking is the ENGINE's own tick — ask it, never
  -- reimplement it, and never let a quiet engine stop the resume.
  begin
    v_sync := public.inquiry_engine_sync();
  exception when others then v_sync := jsonb_build_object('engine','error');
  end;

  begin
    select o.order_code, o.customer_id,
           coalesce(nullif(pp.whatsapp_no,''), nullif(pp.phone,''), o.phone)
      into v_code, v_cust, v_phone
      from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
     where o.id = p_order_id;
    perform public.wa_send_event('order_resumed', v_cust,
      jsonb_build_object('code', coalesce(v_code,''), 'link','https://medibo.in/'),
      v_phone, p_order_id);
  exception when others then null;
  end;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', _c('order_hold.resumed_toast'),
    'reranked', coalesce(v_sync, '{}'::jsonb),
    'state', public.order_hold_state(p_order_id),
    'sheet', public.order_hold_sheet(p_order_id));
end
$fn$;

revoke all on function public.order_resume(uuid,text,text) from public, anon, authenticated;
grant execute on function public.order_resume(uuid,text,text) to authenticated;
