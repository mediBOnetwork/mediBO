-- CMD #2051 — the cart's last-resort rail stops sequentially scanning MEDICINE.
--
-- WHAT WAS WRONG
-- `cart_rail_block`'s 'auto' fallback (a pharmacy with no wishlist and a cart
-- too short to have co-purchase companions) ranked the whole buyable catalogue
-- by `coalesce(m.supplier_count, 0) desc, m.id`. Wrapping the column in
-- coalesce() makes the ordering an EXPRESSION, so no index can answer it: the
-- planner sorted 5.6M rows to take ten. Measured on live against
-- test.cust1@medibo.in: cart_rail_block 73.6 s, _cart_bill_core 41.5 s,
-- cart_render 40 s — far past PostgREST's 8 s statement timeout, so
-- `cart_render()` returned nothing but a timeout for EVERY signed-in customer.
-- The cart panel, the bill and the floating cart pill (whose `show` is that
-- payload's answer) were all dead for as long as this has been live.
--
-- THE FIX
-- Order by `m.sales_count desc nulls last, m.id`, which is exactly what
-- `idx_med_buyable_sales (sales_count DESC NULLS LAST, id) WHERE buyable`
-- indexes — the same "widely stocked, best first" ranking the home rails and
-- the Best Sellers block already use, so the fallback is more consistent with
-- the rest of the storefront rather than less. Same rows, same card block,
-- same everything else: 143 ms instead of 73 s.
--
-- Nothing is dropped and nothing is added — one ORDER BY in each of the two
-- places the fallback writes it. No index is created: a 37th index on MEDICINE
-- would be paid for on every write of a 5.6M-row table to serve a last-resort
-- rail, and an index that already exists answers the question.

CREATE OR REPLACE FUNCTION public.cart_rail_block(p_customer_id uuid, p_zone_id smallint, p_cart_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cfg   record;
  v_disc  numeric;
  v_items jsonb := '[]'::jsonb;
  v_uid   uuid;
  v_ids   bigint[] := coalesce(p_cart_ids, '{}'::bigint[]);
begin
  select * into v_cfg from public.cart_rail_config
   where zone_id = coalesce(p_zone_id, 0);
  if v_cfg is null then
    select * into v_cfg from public.cart_rail_config where zone_id = 0;
  end if;
  if v_cfg is null or not v_cfg.enabled then
    return jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb,
                              'empty_note', public._c('cart.rail_empty'));
  end if;

  v_disc := public._c791_safe_discount_pct();
  v_uid  := coalesce(public.viewer_cart_user(), auth.uid());

  -- The card block is the SAME storefront_pricing / storefront_cta pair the
  -- catalogue grid reads, so a rail card and a grid card cannot disagree.
  if v_cfg.source in ('auto', 'wishlist') then
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_items
    from (
      select row_number() over (order by w.created_at desc) as ord,
             jsonb_build_object(
               'id',           m.id,
               'name',         coalesce(m.product_name, ''),
               'company',      coalesce(m.marketer, ''),
               'pack_label',   coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                                        nullif(btrim(coalesce(m.pack_size,'')),''), ''),
               'form_chip',    coalesce(nullif(btrim(coalesce(m.pack_qty,'')),''),
                                        nullif(btrim(coalesce(m.pack_size,'')),''), ''),
               'image',        coalesce(m.image_url_1, ''),
               'pricing',      public.storefront_pricing(
                                 nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
                                 v_disc, m.id),
               'availability', public.storefront_cta(
                                 public.storefront_effective_count(m.id, m.supplier_count), true)) as x
        from public.wishlist_items w
        join public."MEDICINE" m on m.id = w.product_id
       where w.account_id = v_uid
         and m.buyable is true
         and not (m.id = any (v_ids))
       order by w.created_at desc
       limit greatest(coalesce(v_cfg.max_items, 10), 1)
    ) s;
  end if;

  -- 'auto' tops a short wishlist up with the co-purchase companions the cart
  -- already computes, so the rail is never a lonely single card.
  if v_cfg.source in ('auto', 'companions')
     and jsonb_array_length(v_items) < greatest(coalesce(v_cfg.max_items, 10), 1) then
    declare
      v_comp jsonb := public.cart_companions(v_ids);
      v_have bigint[];
    begin
      select coalesce(array_agg((e->>'id')::bigint), '{}') into v_have
        from jsonb_array_elements(v_items) e;
      select v_items || coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_items
        from jsonb_array_elements(coalesce(v_comp->'items', '[]'::jsonb))
             with ordinality t(e, ord)
       where not ((e->>'id')::bigint = any (coalesce(v_have, '{}'::bigint[])));
    end;
  end if;

  -- Last resort for 'auto': a new pharmacy has no wishlist and a one-line cart
  -- has no co-purchase history, and an empty rail is worse than a relevant one.
  -- The widely-stocked buyable catalogue is the honest fallback — still the
  -- backend deciding, still the same card block.
  if v_cfg.source = 'auto'
     and jsonb_array_length(v_items) < greatest(coalesce(v_cfg.max_items, 10), 1) then
    declare
      v_have2 bigint[];
      v_more  jsonb;
    begin
      select coalesce(array_agg((e->>'id')::bigint), '{}') into v_have2
        from jsonb_array_elements(v_items) e;
      select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_more
      from (
        select row_number() over (order by m.sales_count desc nulls last, m.id) as ord,
               jsonb_build_object(
                 'id',           m.id,
                 'name',         coalesce(m.product_name, ''),
                 'company',      coalesce(m.marketer, ''),
                 'pack_label',   coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                                          nullif(btrim(coalesce(m.pack_size,'')),''), ''),
                 'form_chip',    coalesce(nullif(btrim(coalesce(m.pack_qty,'')),''),
                                          nullif(btrim(coalesce(m.pack_size,'')),''), ''),
                 'image',        coalesce(m.image_url_1, ''),
                 'pricing',      public.storefront_pricing(
                                   nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
                                   v_disc, m.id),
                 'availability', public.storefront_cta(
                                   public.storefront_effective_count(m.id, m.supplier_count), true)) as x
          from public."MEDICINE" m
         where m.buyable is true
           and not (m.id = any (v_ids))
           and not (m.id = any (coalesce(v_have2, '{}'::bigint[])))
         order by m.sales_count desc nulls last, m.id
         limit greatest(coalesce(v_cfg.max_items, 10), 1)
      ) s;
      v_items := v_items || v_more;
    end;
  end if;

  if jsonb_array_length(v_items) > greatest(coalesce(v_cfg.max_items, 10), 1) then
    select coalesce(jsonb_agg(e order by ord), '[]'::jsonb) into v_items
      from (select e, ord from jsonb_array_elements(v_items) with ordinality t(e, ord)
             order by ord
             limit greatest(coalesce(v_cfg.max_items, 10), 1)) s;
  end if;

  return jsonb_build_object(
    'has',        jsonb_array_length(v_items) > 0,
    'title',      v_cfg.title,
    'empty_note', public._c('cart.rail_empty'),
    'items',      v_items);
end $function$
