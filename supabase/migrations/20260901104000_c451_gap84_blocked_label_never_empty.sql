-- CMD #451 · row 84 follow-up, caught on the live PDP: the blocked branch's
-- cta_label came back as an EMPTY STRING for every caller that does not pass
-- p_status (product_detail, storefront_product, _sf_cards, cart_availability
-- and the rest — nine of the eleven).
--
-- Why: med_status_block(NULL)->>'label' is '' rather than NULL (initcap('') is
-- ''), so `coalesce(that, 'Not for sale')` picked the empty string. A blocked
-- product therefore rendered a BLANK button on any surface printing cta_label.
-- nullif() is the whole fix; the sentinel path keeps working unchanged.
create or replace function public.storefront_cta(
  p_supplier_count integer,
  p_resolved boolean default true,
  p_status text default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  select case
    when coalesce(p_supplier_count, 0) < 0
      or (p_status is not null and not public.med_status_sellable(p_status)) then
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label', coalesce(nullif(public.med_status_block(p_status)->>'label',''),
                              public.uic('storefront.not_for_sale_label','Not for sale')),
        'gated', public.viewer_is_approved_customer(),
        'blocked_by', 'status',
        'note', coalesce(nullif(public.med_status_block(p_status)->>'reason',''),
                         public.uic('storefront.status_blocked_note','This product is not for sale.')),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='not_for_sale_label'),
                              public.uic('storefront.not_for_sale_label','Not for sale')),
        'colors', jsonb_build_object('bg','#FEE2E2','fg','#991B1B'))

    when not coalesce(p_resolved, true) then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'unresolved', true,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    when coalesce(p_supplier_count, 0) >= 1 then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    else
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label','Unavailable','gated', public.viewer_is_approved_customer(),
        'blocked_by', 'no_supplier',
        'note', case when auth.uid() is null
                     then public.uic('storefront.signed_out_note',
                                     'Sign in to see availability in your area.')
                     else public.uic('storefront.no_supplier_note',
                                     'No supplier for this product right now') end,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='stock_out_label'), 'Out of stock'),
        'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF'))
  end;
$function$;

insert into public.ui_copy (key, value)
values ('storefront.not_for_sale_label', to_jsonb('Not for sale'::text))
on conflict (key) do nothing;

-- The card label a blocked product shows, as DATA rather than a SQL fallback.
insert into public.storefront_ui_label (key, value)
values ('not_for_sale_label', 'Not for sale')
on conflict (key) do nothing;

