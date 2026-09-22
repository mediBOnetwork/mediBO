-- CMD #2152 — Cart: live totals + advance, Wishlist rail keeps in-cart items.
--
-- 1. cart_update_item() (the per-tap fast door) now also answers with the
--    Cart v2 block (_cart_v2_block over the rows it just re-read), so the v2
--    bill's Total MRP / item count, the advance in the bill and in the green
--    bar move on every qty change, add, remove, swipe-remove and undo — the
--    app adopts summary.v2 verbatim instead of waiting for a full cart_render.
-- 2. cart_rail_block(): the wishlist part no longer drops products that are
--    already in the cart — the rail lists EVERY wishlisted item and the shared
--    card shows its cart qty. Top-ups (companions / catalogue) still skip cart
--    items. Idempotent: CREATE OR REPLACE only.

CREATE OR REPLACE FUNCTION public.cart_update_item(p_product_id text, p_quantity integer, p_guest_uid uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  w         jsonb;
  v_uid     uuid;
  v_cust    uuid;
  v_item    jsonb;
  v_lines   int := 0;
  v_units   int := 0;
  v_mrp     numeric := 0;
  v_zone    smallint;
  v_adv     jsonb;
  v_adv_amt numeric := 0;
  v_all     jsonb := '[]'::jsonb;
  v_bill    jsonb;
  v_pill    jsonb;
  v_v2      jsonb;
  v_retry   jsonb := jsonb_build_object('label', public._c('cart.row_retry'),
                                        'note',  public._c('cart.row_save_failed'));
begin
  w := public._cart_write_item(p_product_id, p_quantity, p_guest_uid);

  if not coalesce((w->>'ok')::boolean, false) then
    return w || jsonb_build_object('product_id', p_product_id, 'retry', v_retry);
  end if;

  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid  := p_guest_uid;
    v_cust := null;
  end if;

  select public._cart_line_json(jsonb_build_object(
           'id', ci.id,
           'product_id', coalesce(ci.product_id,''),
           'product_name', coalesce(ci.product_name,''),
           'quantity', coalesce(ci.quantity,0), 'mrp', ci.mrp,
           'image_url', coalesce(ci.image_url,''),
           'manufacturer', coalesce(ci.manufacturer,''),
           'pack_size', coalesce(ci.pack_size,''),
           'pack_label', coalesce(nullif(btrim(coalesce(
                           public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),'')),''),
                                  coalesce(ci.pack_size,'')),
           'added_by', coalesce(ci.added_by,''),
           'category', coalesce(nullif(btrim(ci.category),''),'Other'),
           'added_by_admin', (coalesce(ci.added_by,'') = 'admin'),
           'buyable', coalesce(m.buyable, false),
           'line_mrp', case when ci.mrp is null then null
                            else round(coalesce(ci.quantity,0) * ci.mrp, 2) end))
    into v_item
    from cart_items ci
    left join "MEDICINE" m
           on m.id = (case when ci.product_id ~ '^[0-9]+$' then ci.product_id::bigint end)
   where ci.product_id = p_product_id
     and (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
     and coalesce(ci.removed_by_admin, false) = false
   limit 1;

  -- The whole basket, in cart_state()'s own order and shape. It is what the
  -- pill stacks its thumbnails from and what the bill is priced against, so
  -- the bar, the card and the pill are three readings of ONE list.
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',   coalesce(ci.product_id,''),
           'product_name', coalesce(ci.product_name,''),
           'quantity',     coalesce(ci.quantity,0),
           'mrp',          ci.mrp,
           'image_url',    coalesce(ci.image_url,'')) order by ci.id), '[]'::jsonb),
         count(*),
         coalesce(sum(coalesce(ci.quantity,0)), 0),
         coalesce(round(sum(coalesce(ci.quantity,0) * ci.mrp)
                    filter (where ci.mrp is not null), 2), 0)
    into v_all, v_lines, v_units, v_mrp
    from cart_items ci
   where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
     and coalesce(ci.removed_by_admin, false) = false;

  begin
    if v_cust is not null then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
    v_adv     := public.advance_pct_for(v_cust, v_zone);
    v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv_amt := 0;
  end;

  begin
    v_bill := (public._cart_bill_core(
                 jsonb_build_object('items', v_all, 'mrp_total', v_mrp,
                                    'item_count', v_lines, 'unit_count', v_units),
                 v_cust, v_zone))->'bill';
  exception when others then
    v_bill := null;
  end;

  begin
    v_pill := public.cart_pill_block(v_all, v_lines);
  exception when others then
    v_pill := null;
  end;

  begin
    v_v2 := public._cart_v2_block(
              jsonb_build_object('items', v_all, 'mrp_total', v_mrp,
                                 'item_count', v_lines, 'unit_count', v_units),
              v_cust, v_zone);
  exception when others then
    v_v2 := null;
  end;

  return jsonb_build_object(
    'ok',         true,
    'message',    w->>'message',
    'product_id', p_product_id,
    'removed',    (v_item is null),
    'item',       coalesce(v_item, 'null'::jsonb),
    'retry',      v_retry,
    'summary', jsonb_build_object(
      'item_count',  v_lines,
      'unit_count',  v_units,
      'items_label', case when v_lines = 1 then '1 item' else v_lines::text || ' items' end,
      'badge',       case when v_lines > 0 then v_lines::text else '' end,
      'mrp_total',   v_mrp,
      'bill',        coalesce(v_bill, 'null'::jsonb),
      'pill',        coalesce(v_pill, 'null'::jsonb),
      'v2',          coalesce(v_v2, 'null'::jsonb),
      'bottom', jsonb_build_object(
        'has',             true,
        'items_label',     public._c('cart.bottom_items_label'),
        'items_value',     v_lines::text,
        'advance_label',   public._c('cart.bottom_advance_label'),
        'has_advance',     (v_adv_amt > 0),
        'advance_display', case when v_adv_amt > 0 then public.inr_money(v_adv_amt) else '' end)));
end $function$

;

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
               'pack_label',   coalesce(nullif(btrim(coalesce(m.pack_qty,'')),''),
                                        nullif(btrim(coalesce(m.pack_size,'')),''), ''),
               'form_chip',    coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                                        nullif(btrim(coalesce(m.pack_size,'')),''), ''),
               'image',        coalesce(m.image_url_1, ''),
               'pricing',      public.storefront_pricing(
                                 nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
                                 v_disc, m.id),
               'availability', public.storefront_cta(
                                 public.storefront_effective_count(m.id, m.supplier_count), true)) as x
        from public.wishlist_items w
        join public."MEDICINE" m on m.id = w.product_id
       where w.account_id = coalesce(p_customer_id, public.my_customer_id())
         and m.buyable is true
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

;
