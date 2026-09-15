-- CMD #2043 — WHICH surfaces float the "View cart" pill is a registry answer.
--
-- The shell decided it with `_index == 0`: a page number written in Dart, in
-- two places (mobile and desktop), that nobody thought about again when the
-- Catalogue became page 12. The result is the bug this command fixes — a
-- shopper browsing a company or a salt list has a cart with things in it and
-- no way back to it.
--
-- The nav registry already knows every storefront page the customer can stand
-- on, so the flag belongs on the row: `cart_pill` is part of each slot in
-- `customer_nav()`, and turning the pill on for a new surface is an UPDATE.
--
-- Idempotent: add-column-if-not-exists, an UPDATE and CREATE OR REPLACE.

alter table public.customer_nav_slot
  add column if not exists cart_pill boolean not null default false;

comment on column public.customer_nav_slot.cart_pill is
  'CMD #2043 — this slot''s page floats the View cart pill (storefront surfaces only).';

-- Home and the Catalogue are the storefront. Orders, Bulk upload and My Shop
-- are not: a floating "View cart" over an order list is chrome with nothing to
-- do with the page under it.
update public.customer_nav_slot
   set cart_pill = true, updated_at = now()
 where slot_key in ('home', 'catalogue')
   and cart_pill is distinct from true;

update public.customer_nav_slot
   set cart_pill = false, updated_at = now()
 where slot_key not in ('home', 'catalogue')
   and cart_pill is distinct from false;

-- customer_nav(), verbatim from live with the one key added.
create or replace function public.customer_nav()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- CHANGE #570 — the audience of a slot is the slot's own roles_allowed, not
  -- "not an admin". get_my_role() is the one role answer the whole app uses.
  with me as (select coalesce(public.get_my_role(),'none') as role)
  select jsonb_build_object(
    'ok', true,
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key',        s.slot_key,
               'label',      public._c(s.label_key),
               'icon_key',   s.icon_key,
               'page_index', s.page_index,
               'badge_key',  s.badge_key,
               -- CMD #2043 — does this page float the cart pill?
               'cart_pill',  s.cart_pill)
             order by s.sort_order, s.slot_key)
        from public.customer_nav_slot s, me
       where s.is_active
         and (s.roles_allowed is null
              or me.role = any (s.roles_allowed))), '[]'::jsonb));
$function$;
