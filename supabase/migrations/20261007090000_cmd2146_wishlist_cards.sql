-- CMD #2146 — wishlist_get also returns `cards`: the shared product card
-- payload for each saved product. Idempotent (CREATE OR REPLACE).
CREATE OR REPLACE FUNCTION public.wishlist_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_customer_id uuid;
  v_items       jsonb;
  v_cards       jsonb;
begin
  v_customer_id := my_customer_id();
  if v_customer_id is null then
    return jsonb_build_object(
      'ok',          false,
      'error',       'not_customer',
      'items',       '[]'::jsonb,
      'cards',       '[]'::jsonb,
      'title',       'My Wishlist',
      'count_label', '',
      'empty_title', 'Your wishlist is empty',
      'empty_body',  'Save products here to order them quickly later.'
    );
  end if;

  select coalesce(jsonb_agg(row order by row.saved_at desc), '[]'::jsonb)
  into v_items
  from (
    select
      m.id::text                                   as product_id,
      coalesce(m.product_name, '')                 as name,
      coalesce(m.marketer, '')                     as company,
      coalesce(m.pack_size, '')                    as pack_label,
      coalesce(
        (public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
          null::numeric, m.id))->>'price_display', '')            as price_display,
      -- CMD #1926 — ONE call to the shared helper, read four ways. It used to
      -- be three separate calls whose answers were only guaranteed to agree
      -- because they happened to be written identically.
      coalesce((av.a->'is_available')::boolean, false)            as in_stock,
      coalesce((av.a->'can_add')::boolean, false)                 as can_add,
      coalesce(av.a->>'cta_label', 'Add to cart')                 as cta_label,
      av.a                                                        as availability,
      coalesce(m.image_url_1, '')                                 as image_url,
      wi.created_at                                               as saved_at
    from wishlist_items wi
    join "MEDICINE" m on m.id = wi.product_id
    cross join lateral (select public.storefront_availability(m.id, m.supplier_count) as a) av
    where wi.account_id = v_customer_id
  ) row;

  -- CMD #2146 — the SAME card every other surface draws (_cat_cards ->
  -- _product_card), in saved order, so the wishlist renders ProductCard v5
  -- instead of its own copy.
  select coalesce(public._cat_cards(array_agg((it->>'product_id')::bigint order by ord)), '[]'::jsonb)
    into v_cards
    from jsonb_array_elements(v_items) with ordinality e(it, ord);

  return jsonb_build_object(
    'ok',           true,
    'items',        v_items,
    'cards',        v_cards,
    'title',        'My Wishlist',
    'count_label',  case
                      when jsonb_array_length(v_items) = 0 then ''
                      when jsonb_array_length(v_items) = 1 then '1 product'
                      else jsonb_array_length(v_items)::text || ' products'
                    end,
    'empty_title',  'Your wishlist is empty',
    'empty_body',   'Save products here to order them quickly later.',
    'remove_toast', 'Removed from wishlist',
    'add_toast',    'Added to wishlist',
    'cart_toast',   'Added to cart'
  );
end;
$function$;
