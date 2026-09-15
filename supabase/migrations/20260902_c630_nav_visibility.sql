-- CHANGE #630 (Om's live addition) — the bottom bar's ORDER and its AUDIENCE
-- both become registry data.
--
-- Om: "customer bottom-nav SEQUENCE changes to exactly: Home · Catalogue ·
-- Bulk · Orders · My Shop (My Shop LAST, Bulk moves to third). Registry
-- sort_order owns it; do not hardcode the order in Dart."
--
-- The order landed in 20260901_c630_orders_tab.sql. What was still in Dart was
-- the other half of the same question: WHO gets a slot. #536 QA round 2 found
-- that an admin and a signed-out visitor were being shown a My Shop tab whose
-- RPC refuses them (customer_shop_home() has no EXECUTE for anon), and the fix
-- was `showMyShop = isAuthenticated && !isAdmin` computed in the shell — twice,
-- once per layout. That is a backend decision living in the client, and with a
-- registry-driven bar it is also the one thing that could still leave a hole in
-- the slot list. So the row carries it now, `customer_nav()` resolves it
-- against the caller, and both layouts obey one answer.
--
-- Idempotent: re-applying this is a no-op (add column if not exists, guarded
-- constraint, conditional updates, create or replace).

alter table public.customer_nav_slot
  add column if not exists visibility text not null default 'always',
  add column if not exists badge_key  text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'customer_nav_slot_visibility_ck') then
    alter table public.customer_nav_slot
      add constraint customer_nav_slot_visibility_ck
      check (visibility in ('always', 'customer_only'));
  end if;
end $$;

comment on column public.customer_nav_slot.visibility is
  'always = every viewer; customer_only = a signed-in non-admin only (#536 QA round 2, moved out of Dart by #630).';
comment on column public.customer_nav_slot.badge_key is
  'Which badge the slot carries: cart (the order count the shell already holds), shop (customer_shop_badge()), or null. The ROW decides, never the widget.';

-- The order slot carries the cart count; My Shop carries its own attention
-- count and belongs to a signed-in pharmacy.
update public.customer_nav_slot
   set badge_key = 'cart', updated_at = now()
 where slot_key = 'orders' and badge_key is distinct from 'cart';

update public.customer_nav_slot
   set badge_key = 'shop', visibility = 'customer_only', updated_at = now()
 where slot_key = 'my_shop'
   and (badge_key is distinct from 'shop' or visibility is distinct from 'customer_only');

-- The bar, rendered for THIS caller. `badge_key` names the badge each slot
-- carries; the shell reads the number it already has rather than the row
-- inventing one.
create or replace function public.customer_nav()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $fn$
  with me as (
    select auth.uid() is not null            as signed_in,
           coalesce(public._is_admin(), false) as is_admin
  )
  select jsonb_build_object(
    'ok', true,
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key',        s.slot_key,
               'label',      public._c(s.label_key),
               'icon_key',   s.icon_key,
               'page_index', s.page_index,
               'badge_key',  s.badge_key)
             order by s.sort_order, s.slot_key)
        from public.customer_nav_slot s, me
       where s.is_active
         and (s.visibility = 'always'
              or (me.signed_in and not me.is_admin))), '[]'::jsonb));
$fn$;

revoke all on function public.customer_nav() from public;
grant execute on function public.customer_nav() to anon, authenticated, service_role;
