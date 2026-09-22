-- CMD #2152 — Delivery / Self pickup must never answer HTTP 409.
--
-- The live feature journey tapped Delivery and cart_set_receive_mode raised a
-- foreign-key violation (PostgREST 409): _cart2_customer() took
-- customer_id_for_user() first, which reads login_identities.owner_id
-- verbatim — an id that can point at a pharmacy_profiles row that no longer
-- exists (a purged / re-registered pharmacy). cart_receive_mode.customer_id
-- references pharmacy_profiles, so the insert failed.
--
-- 1. _cart2_customer() only returns an id that exists in pharmacy_profiles,
--    falling back to my_customer_id() (which already resolves through it).
-- 2. cart_set_receive_mode() answers ok:false 'no_customer' with the current
--    receive block instead of raising, if no such row exists.
-- Idempotent: CREATE OR REPLACE only.

create or replace function public._cart2_customer()
 returns uuid
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v uuid;
begin
  if auth.uid() is null then return null; end if;
  begin
    v := public.customer_id_for_user(public.viewer_cart_user());
  exception when others then v := null; end;
  if v is null or not exists (select 1 from public.pharmacy_profiles pp where pp.id = v) then
    begin
      v := public.my_customer_id();
    exception when others then v := null; end;
  end if;
  return v;
end $function$;

create or replace function public.cart_set_receive_mode(p_mode text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_cust uuid := public._cart2_customer(); v_zone smallint;
begin
  if v_cust is null or not exists (select 1 from public.pharmacy_profiles where id = v_cust) then
    return jsonb_build_object('ok', false, 'error', 'no_customer');
  end if;
  if p_mode not in ('delivery','pickup') then return jsonb_build_object('ok', false, 'error', 'bad_mode'); end if;
  select zone_id into v_zone from public.pharmacy_profiles where id = v_cust;
  if p_mode = 'pickup' and public._cart2_partner(v_zone) is null then
    return jsonb_build_object('ok', false, 'error', 'no_partner', 'receive', public._cart2_receive(v_cust, v_zone));
  end if;
  insert into public.cart_receive_mode(customer_id, mode, updated_at) values (v_cust, p_mode, now())
  on conflict (customer_id) do update set mode = excluded.mode, updated_at = now();
  return jsonb_build_object('ok', true, 'receive', public._cart2_receive(v_cust, v_zone));
end $function$;

revoke all on function public.cart_set_receive_mode(text) from public, anon;
grant execute on function public.cart_set_receive_mode(text) to authenticated;
