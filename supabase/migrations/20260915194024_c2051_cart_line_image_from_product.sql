-- CMD #2051 — the cart pill's thumbs, and the cart rows, get their picture.
--
-- Found by this command's own hostile QA round: the shipped pill draws two
-- overlapping product thumbs and both were blank white circles. Not the
-- widget — the payload. cart_render().render.pill.thumbs carried
-- has_image:false / image_url:"" for every line, because the only source of a
-- cart line's picture was cart_items.image_url, which nothing populates.
--
-- Idempotent: CREATE OR REPLACE of one function, no schema change, no data
-- written. Blank stays blank when the product has no picture either.

CREATE OR REPLACE FUNCTION public._cart_line_json(p_item jsonb, p_trade jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pid  bigint := case when (p_item->>'product_id') ~ '^[0-9]+$'
                        then (p_item->>'product_id')::bigint end;
  v_tp   jsonb;
  v_rx   boolean := false;
  v_img  text := '';
  v_cp   jsonb;
  v_unpriced_line text := coalesce((select value from storefront_ui_label
                                     where key='cart_unpriced_line_note'),
                                   'Rate on supplier confirmation');
  v_no_mrp text := coalesce((select value from storefront_ui_label
                              where key='cart_no_mrp_note'),
                            'MRP not printed on this pack');
begin
  v_tp := coalesce(
            p_trade,
            case when v_pid is null then null
                 else public.trade_price_line(v_pid,
                        coalesce((p_item->>'quantity')::numeric, 0)) end,
            '{}'::jsonb);

  -- CMD #2051 QA round 1 — THE PICTURE COMES FROM THE PRODUCT, NOT THE CART ROW.
  --
  -- `cart_items.image_url` is whatever the client happened to write when the
  -- line was added, and in production it is blank on EVERY row — so the cart
  -- pill drew its two thumbs as empty white circles and the cart rows had no
  -- picture either, on a page where the same products' photos load fine three
  -- inches higher up. The product's own `image_url_1` is the authority the
  -- rest of the storefront already reads (cart_rail_block reads exactly this
  -- column); the stored value only wins when it is genuinely set, so a line
  -- that carries its own picture keeps it.
  --
  -- It costs nothing: this is the SAME single primary-key lookup that already
  -- had to happen for rx_required, with one more column selected. Resolving it
  -- here rather than in the pill is what makes one fix cover both surfaces —
  -- cart_row_block and cart_pill_block are both handed this item.
  if v_pid is not null then
    select (upper(btrim(coalesce(m.rx_required,''))) = 'RX'),
           coalesce(nullif(btrim(m.image_url_1), ''), '')
      into v_rx, v_img
      from "MEDICINE" m
     where m.id = v_pid
     limit 1;
  end if;
  v_rx  := coalesce(v_rx, false);
  v_img := coalesce(v_img, '');
  if coalesce(btrim(p_item->>'image_url'), '') = '' and v_img <> '' then
    p_item := p_item || jsonb_build_object('image_url', v_img);
  end if;
  v_cp := coalesce(public.cart_card_price(v_pid), '{}'::jsonb);

  return p_item || v_tp || jsonb_build_object(
    'has_mrp',          (nullif(p_item->>'mrp','') is not null),
    'mrp_display',      case when nullif(p_item->>'mrp','') is null then ''
                             else public.inr_money((p_item->>'mrp')::numeric) end,
    'line_mrp_display', case when nullif(p_item->>'mrp','') is null then ''
                             else public.inr_money(coalesce((p_item->>'line_mrp')::numeric,0)) end,
    'mrp_note',         case when nullif(p_item->>'mrp','') is null then v_no_mrp else '' end,
    'has_trade_rate',   coalesce((v_tp->>'has_trade_rate')::boolean, false),
    'rate_note',        case when coalesce((v_tp->>'has_trade_rate')::boolean, false)
                             then '' else v_unpriced_line end,
    'is_rx',            v_rx,
    'card_price',       v_cp,
    'row',              public.cart_row_block(p_item, v_tp, v_rx, v_cp),
    'qty_label',        case when coalesce((v_tp->>'has_trade_rate')::boolean, false)
                             then (p_item->>'quantity') || ' × ' || (v_tp->>'price_display')
                             else (p_item->>'quantity') || ' × ' || v_unpriced_line end,
    'price_line',       case when coalesce((v_tp->>'has_trade_rate')::boolean, false)
                             then coalesce(nullif(v_tp->>'line_net_display',''),
                                           public.inr_money(coalesce((v_tp->>'line_net')::numeric,0)))
                             else '' end,
    'price_note',       case
                          when coalesce((v_tp->>'has_trade_rate')::boolean, false)
                            then (p_item->>'quantity') || ' × ' || (v_tp->>'price_display')
                          when nullif(p_item->>'mrp','') is null
                            then public._c('cart.line_rate_pending_no_mrp')
                          else public._cf('cart.line_rate_pending',
                                 jsonb_build_object('mrp',
                                   public.inr_money(coalesce(nullif(p_item->>'line_mrp','')::numeric,
                                                             nullif(p_item->>'mrp','')::numeric, 0))))
                        end);
end $function$

;
