-- CHANGE #304 (c) — who may call what.
-- prepare/store mint and mutate Razorpay objects and re-derive money, so they
-- are edge-function-only (service_role). The two the APP calls are the two the
-- app is allowed to call, and both answer only for an order the caller owns.
revoke execute on function public.rzp_checkout_prepare(uuid, text, text) from anon, authenticated;
revoke execute on function public.rzp_checkout_store(uuid, text, text, text) from anon, authenticated;
revoke execute on function public._rzp_checkout_credit(uuid, uuid, text, numeric, text) from anon, authenticated;
revoke execute on function public._rzp_attempt_match(jsonb, jsonb) from anon, authenticated;

-- The client may report a DISMISSAL, never a success — and only on its own
-- order. A paid attempt stays paid whatever the client says.
create or replace function public.rzp_checkout_failed(p_attempt_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.rzp_payment_attempt%rowtype; v_ok boolean;
begin
  select (o.user_id = any (public.my_owner_user_ids())
          or o.customer_id is not distinct from public.my_customer_id()
          or public.get_my_role() in ('admin','super_admin'))
    into v_ok
    from public.rzp_payment_attempt t join orders o on o.id = t.order_id
   where t.id = p_attempt_id;
  if not coalesce(v_ok,false) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  update public.rzp_payment_attempt
     set status = case when status = 'paid' then 'paid' else 'failed' end,
         failure_reason = case when status = 'paid' then failure_reason
                               else left(coalesce(p_reason,'dismissed'), 200) end
   where id = p_attempt_id
  returning * into a;
  if not found then return jsonb_build_object('ok', false, 'error','attempt_not_found'); end if;
  return jsonb_build_object('ok', true, 'view', public._rzp_attempt_view(a.id));
end $$;
