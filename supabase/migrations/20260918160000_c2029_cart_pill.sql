-- CMD #2029 — the floating "View cart" pill, rebuilt.
--
-- The pill is now a two-line card with a stack of the two MOST RECENTLY ADDED
-- thumbnails on the left and a round chevron button on the right. Every string
-- and every thumbnail in it is decided here: Flutter draws `render.pill` and
-- computes nothing (no pluralising in Dart, no "take the first image", no
-- client-side count).
--
-- Idempotent: CREATE OR REPLACE + label upserts only.

-- Wording lives in storefront_ui_label so "13 items" / "1 item" / "View cart"
-- are an UPDATE, never a deploy. {n} is the line count.
insert into storefront_ui_label (key, value) values
  ('cart_pill_items_one',  '1 item'),
  ('cart_pill_items_many', '{n} items'),
  ('cart_pill_cta',        'View cart')
on conflict (key) do nothing;

-- The pill block. `thumbs` is in DRAW order: [0] sits behind, [1] is the newest
-- item and is drawn on top, offset down-right. `has_image` is the backend's
-- explicit answer to "is there a picture?", so the app never has to guess from
-- an empty string what to put in the white square.
create or replace function public.cart_pill_block(p_items jsonb, p_lines int)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with lbl as (
    select
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_items_one'),''),
               '1 item')  as one,
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_items_many'),''),
               '{n} items') as many,
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_cta'),''),
               'View cart') as cta
  ),
  -- The cart arrives oldest-first (cart_state orders by cart_items.id), so the
  -- LAST two rows are the two most recently added. They are re-emitted
  -- oldest-of-the-two first: that is the draw order the pill stacks them in.
  picked as (
    select it, ord
      from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality as t(it, ord)
     order by ord desc
     limit 2
  ),
  thumbs as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', coalesce(it->>'product_id',''),
             'name',       coalesce(it->>'product_name',''),
             'image_url',  coalesce(it->>'image_url',''),
             'has_image',  (coalesce(btrim(it->>'image_url'),'') <> '')
           ) order by ord), '[]'::jsonb) as arr
      from picked
  )
  select jsonb_build_object(
    'show',        (coalesce(p_lines,0) > 0),
    'items_label', case when coalesce(p_lines,0) = 1
                        then lbl.one
                        else replace(lbl.many, '{n}', coalesce(p_lines,0)::text) end,
    'cta',         lbl.cta,
    'thumbs',      thumbs.arr,
    'thumb_count', jsonb_array_length(thumbs.arr),
    -- kept for back-compat with anything still reading a single image
    'image',       coalesce(thumbs.arr->-1->>'image_url', '')
  )
  from lbl, thumbs;
$fn$;

-- _cart_render_core, verbatim from live, with the pill block delegated.
CREATE OR REPLACE FUNCTION public._cart_render_core(p_guest_uid uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cart jsonb := public.cart_state(p_guest_uid);
  v_mrp numeric := coalesce((v_cart->>'mrp_total')::numeric, 0);
  v_lines int := coalesce((v_cart->>'item_count')::int, 0);
  v_units int := coalesce((v_cart->>'unit_count')::int, 0);
  v_pricing jsonb := coalesce(v_cart->'pricing', '{}'::jsonb);
  v_net numeric := coalesce((v_pricing->>'net_payable')::numeric, 0);
  v_items jsonb;
  v_items_label text;
  v_margin jsonb;
  v_delivery jsonb;
  v_rx jsonb;
  v_rewards jsonb;
  v_notice jsonb;
  v_summary jsonb;
  v_cta jsonb;
  v_top jsonb;
  v_grand numeric;
  v_grand_display text;
begin
  -- CMD #2025 — one line builder, shared with cart_update_item(). The pricing
  -- line is handed in (never null), so nothing here re-resolves a trade price.
  select coalesce(jsonb_agg(public._cart_line_json(z.it, coalesce(p.tp, '{}'::jsonb))
                            order by z.ord), '[]'::jsonb)
    into v_items
  from (select it, ordinality as ord
        from jsonb_array_elements(coalesce(v_cart->'items','[]'::jsonb))
             with ordinality as t(it, ordinality)) z
  left join lateral (
    select l as tp
      from jsonb_array_elements(coalesce(v_pricing->'lines','[]'::jsonb)) l
     where (l->>'product_id') = (z.it->>'product_id')
     limit 1) p on true;

  v_items_label := case when v_lines = 1 then '1 item' else v_lines::text || ' items' end;

  v_margin := public.cart_margin_block(v_items);
  v_delivery := public.delivery_charge_block(public.my_customer_id(), v_net);
  v_grand    := round(v_net + coalesce((v_delivery->>'total')::numeric, 0), 2);
  v_rx := public.cart_rx_gate(public.my_customer_id(), coalesce(v_cart->'items','[]'::jsonb));
  v_rewards := public.cart_rewards_block(public.my_customer_id(), v_margin);

  v_grand_display := case when v_net > 0 then public.inr_money(v_grand) else '' end;

  v_notice  := public.cart_notice_block(v_rx);
  v_summary := public.cart_summary_block(v_pricing, v_delivery, v_items_label,
                                         v_grand_display, v_mrp, v_lines);
  v_cta     := public.cart_cta_block((v_net > 0), not coalesce((v_rx->>'can_order')::boolean, true));
  v_top     := public.cart_top_strip(v_lines, v_mrp);

  return v_cart || jsonb_build_object(
    'items', v_items,
    'margin', v_margin,
    'delivery', v_delivery,
    'rx_gate', v_rx,
    'rewards', v_rewards,
    'render', jsonb_build_object(
      'subtotal_display',     coalesce(v_pricing->>'taxable_display', public.inr_money(0)),
      'mrp_total_display',    public.inr_money(v_mrp),
      'net_payable_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'delivery',             v_delivery,
      'rx_gate',              v_rx,
      'rewards',              v_rewards,
      'summary',              v_summary,
      'top_strip',            v_top,
      'notice',               v_notice,
      'cta',                  v_cta,
      'items_total',          v_net,
      'items_total_display',  coalesce(v_pricing->>'net_payable_display', ''),
      'grand_total',          v_grand,
      'grand_total_display',  case when coalesce((v_delivery->>'total')::numeric,0) > 0
                                   then public.inr_money(v_grand)
                                   else coalesce(v_pricing->>'net_payable_display', '') end,
      'item_count',           v_lines,
      'unit_count',           v_units,
      'items_label',          v_items_label,
      'subtotal_line',        v_summary->>'line',
      'pricing',              v_pricing,
      'tax_lines',            coalesce(v_pricing->'tax_lines', '[]'::jsonb),
      'has_tax',              coalesce((v_pricing->>'has_tax')::boolean, false),
      'margin',               v_margin,
      'pill',                 public.cart_pill_block(v_items, v_lines),
      'labels', jsonb_build_object(
        'subtotal',     coalesce(v_pricing->>'taxable_label', 'Taxable value'),
        'mrp_worth',    coalesce(v_pricing->>'mrp_worth_label', 'MRP worth'),
        'gst',          coalesce(v_pricing->>'gst_total_label', 'GST'),
        'delivery',     coalesce(v_delivery->>'label', 'Delivery'),
        'grand',        public._c('cart.grand_total_label'),
        'total',        coalesce(v_pricing->>'net_payable_label', 'Net payable'))));
end
$function$

;

grant execute on function public.cart_pill_block(jsonb,int) to anon, authenticated;
revoke execute on function public.cart_pill_block(jsonb,int) from public;
notify pgrst, 'reload schema';
