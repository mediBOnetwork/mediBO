-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2025 — Cart made instant.
--
-- Every qty tap used to run cart_set_item (which calls the WHOLE cart_render,
-- avg 1 s, max 6.8 s) and then a second cart_availability pass. This migration
-- gives the tap its own door: cart_update_item() writes the line and answers
-- with that ONE row plus the summary totals the bar prints. No re-render, no
-- availability recheck, no rail, no bill.
--
-- Also here:
--   * _cart_write_item()  — the validation + write, split out of cart_set_item
--                           so the fast door and the old door cannot drift.
--   * _cart_line_json()   — ONE cart line, worded once, used by both
--                           _cart_render_core() and cart_update_item().
--   * the pack caption is now the SAME sf_pack_badge() string the storefront
--     card prints, instead of the cart's own "1 Strip".
--   * cart_availability() joined "MEDICINE" on m.id::text = ci.product_id,
--     which can never use the primary key — a sequential scan of the whole
--     catalogue on every open. Cast the TEXT side instead.
--
-- Idempotent: re-running replaces functions and re-asserts copy/indexes.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. backend copy — the inline retry the row shows instead of a toast ─────
insert into public.ui_copy (key, value) values
  ('cart.row_retry',       '"Retry"'::jsonb),
  ('cart.row_save_failed', '"Not saved"'::jsonb),
  ('cart.back_to_cart',    '"Back to cart"'::jsonb)
on conflict (key) do nothing;

-- ── 2. the indexes the cart's own reads want ────────────────────────────────
create index if not exists cart_items_customer_live_ix
  on public.cart_items (customer_id, product_id)
  where coalesce(removed_by_admin, false) = false;

create index if not exists cart_items_user_live_ix
  on public.cart_items (user_id, product_id)
  where coalesce(removed_by_admin, false) = false;

-- ── 3. ONE cart line, worded once ───────────────────────────────────────────
-- Exactly the object _cart_render_core() used to build inline. Pulling it out
-- is what lets a single-row answer and a full render carry identical strings:
-- there is one definition, so the fast door cannot word a line differently.
-- p_trade NULL means "resolve the trade line yourself"; a caller that already
-- has the pricing line passes it (even as '{}') and nothing is recomputed.
create or replace function public._cart_line_json(p_item jsonb, p_trade jsonb default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_pid  bigint := case when (p_item->>'product_id') ~ '^[0-9]+$'
                        then (p_item->>'product_id')::bigint end;
  v_tp   jsonb;
  v_rx   boolean := false;
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

  if v_pid is not null then
    select (upper(btrim(coalesce(m.rx_required,''))) = 'RX')
      into v_rx
      from "MEDICINE" m
     where m.id = v_pid
     limit 1;
  end if;
  v_rx := coalesce(v_rx, false);
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
end $function$;

-- ── 4. the pack caption the STOREFRONT prints ───────────────────────────────
-- cart_items.pack_size is whatever was copied at add time and is usually
-- blank, so the row fell back to the unit word and printed "1 Strip". The card
-- and the product page print sf_pack_badge(pack_qty, pack_size, pack_type);
-- the cart now carries that same string on the line and the row prefers it.
create or replace function public.cart_state(p_guest_uid uuid default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_uid uuid := coalesce(public.viewer_cart_user(), p_guest_uid);
        v_cust uuid := coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id());
        v_items jsonb; v_units int; v_mrp numeric; v_lines int; v_pricing jsonb;
begin
  if auth.uid() is not null then v_uid := public.viewer_cart_user(); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ci.id,
           'product_id', coalesce(ci.product_id,''), 'product_name', coalesce(ci.product_name,''),
           'quantity', coalesce(ci.quantity,0), 'mrp', ci.mrp,
           'image_url', coalesce(ci.image_url,''), 'manufacturer', coalesce(ci.manufacturer,''),
           'pack_size', coalesce(ci.pack_size,''),
           -- CMD #2025 — the storefront card's own pack string, on the line.
           'pack_label', coalesce(nullif(btrim(coalesce(mb.pack_label,'')),''),
                                  coalesce(ci.pack_size,'')),
           'added_by', coalesce(ci.added_by,''),
           'category', coalesce(nullif(btrim(ci.category),''),'Other'),
           'added_by_admin', (coalesce(ci.added_by,'') = 'admin'),
           'buyable', coalesce(mb.buyable, false),
           -- reference only: what this line is worth at the printed ceiling.
           -- No MRP on record => no reference value, not zero.
           'line_mrp', case when ci.mrp is null then null
                            else round(coalesce(ci.quantity,0) * ci.mrp, 2) end)
           order by ci.id), '[]'::jsonb),
         coalesce(sum(ci.quantity),0),
         coalesce(round(sum(coalesce(ci.quantity,0) * ci.mrp) filter (where ci.mrp is not null), 2),0)
    into v_items, v_units, v_mrp
  from cart_items ci
  left join lateral (
    select m.buyable,
           public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type) as pack_label
      from "MEDICINE" m
     where m.id = (case when ci.product_id ~ '^[0-9]+$' then ci.product_id::bigint end)
     limit 1
  ) mb on true
  where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
    and coalesce(ci.removed_by_admin,false) = false;

  v_lines := jsonb_array_length(v_items);
  v_pricing := public.cart_pricing_block(v_items);

  return jsonb_build_object(
    'items', v_items,
    'admin_removed', '[]'::jsonb,
    'item_count', v_lines,
    'unit_count', v_units,
    'mrp_total', v_mrp,
    'pricing', v_pricing,
    'subtotal', (v_pricing->>'taxable')::numeric,
    'net_payable', (v_pricing->>'net_payable')::numeric,
    'customer_id', coalesce(v_cust::text, ''),
    'header', case when v_lines = 1 then '1 product in cart'
                   when v_lines = 0 then 'Your cart is empty'
                   else v_lines::text || ' products in cart' end,
    'badge', case when v_lines > 0 then v_lines::text else '' end,
    'cta_label', case when v_lines > 0
                      then v_lines::text || case when v_lines = 1 then ' item' else ' items' end
                      else '' end,
    'empty_title', 'Your cart is empty',
    'empty_note',  'Add products from the catalog to start an order.'
  );
end $function$;

-- The row prefers the catalogue's pack string and falls back to whatever the
-- line carried before, so a payload built the old way still renders.
create or replace function public.cart_row_block(p_item jsonb, p_trade jsonb, p_rx boolean, p_card jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_qty   int     := coalesce((p_item->>'quantity')::int, 0);
  -- CMD #2025 — the storefront card's pack string first, the line's own
  -- pack_size only when the catalogue had nothing to say.
  v_pack  text    := coalesce(nullif(btrim(coalesce(p_item->>'pack_label','')), ''),
                              btrim(coalesce(p_item->>'pack_size','')));
  v_unit  text    := public.cart_unit_label(v_pack);
  v_card  jsonb   := coalesce(p_card, '{}'::jsonb);
  -- The catalogue's own two numbers. The cart never re-prices a line: the
  -- value it prints is the SAME price_display the product cards print, so the
  -- two surfaces cannot disagree.
  v_mrp_num numeric := coalesce(nullif(v_card->>'mrp_value','')::numeric,
                                nullif(p_item->>'mrp','')::numeric);
  v_ptr_num numeric := nullif(v_card->>'ptr_value','')::numeric;
  v_locked  boolean := coalesce((v_card->>'price_locked')::boolean, true);
  v_value   text    := coalesce(nullif(v_card->>'price_display',''),
                                case when coalesce((p_trade->>'has_trade_rate')::boolean,false)
                                     then coalesce(p_trade->>'price_display','') else '' end);
  v_mrp_disp text   := case when v_mrp_num is not null and v_mrp_num > 0
                            then public.inr_money(v_mrp_num) else '' end;
  -- A strike is only honest when there are TWO prices and the viewer may see
  -- both of them. A withheld ("PTR") value gets one plain line, no strike.
  v_show_strike boolean := (not v_locked) and v_mrp_num is not null and v_ptr_num is not null
                           and v_mrp_num > 0 and v_ptr_num > 0 and v_ptr_num < v_mrp_num;
  v_pct     int;
  v_disc    text := '';
begin
  if v_show_strike then
    v_pct := floor((v_mrp_num - v_ptr_num) * 100.0 / v_mrp_num)::int;
    if v_pct > 0 then
      v_disc := public._cf('cart.row_discount', jsonb_build_object('pct', v_pct::text));
    end if;
  end if;

  return jsonb_build_object(
    'name',        coalesce(p_item->>'product_name',''),
    'pack_label',  case when v_pack <> '' then v_pack
                        else public._c('cart.row_pack_unknown') end,
    'has_pack',    (v_pack <> ''),
    'unit',        v_unit,
    'qty',         v_qty,
    'image_url',   coalesce(p_item->>'image_url',''),
    'company',     btrim(coalesce(p_item->>'manufacturer','')),
    'has_mrp',     (v_mrp_disp <> ''),
    'mrp_display', v_mrp_disp,
    'remove_label', public._c('cart.row_remove'),
    -- CMD #2025 — the row's own tap target: the product page, and the words
    -- for the trip back. The screen navigates; it words nothing.
    'open',        jsonb_build_object(
                     'has',        (p_item->>'product_id') ~ '^[0-9]+$',
                     'product_id', coalesce(p_item->>'product_id',''),
                     'back_label', public._c('cart.back_to_cart')),
    -- CMD #2025 — what the row says when its own save did not land. Inline,
    -- on that row, with the backend's word for the retry.
    'retry',       jsonb_build_object(
                     'label', public._c('cart.row_retry'),
                     'note',  public._c('cart.row_save_failed')),
    -- The pill prints the number; the unit word is a caption under it.
    'stepper',     jsonb_build_object(
                     'qty',        v_qty,
                     'qty_text',   v_qty::text,
                     'unit_label', v_unit),
    -- CMD #2013 — THE money block, and the only one on the row. Two lines at
    -- most: a struck MRP above, the price with its discount percent below.
    -- `has_strike:false` is the backend saying "one line, no ceiling".
    'price',       jsonb_build_object(
                     'has',            (v_value <> ''),
                     'value',          v_value,
                     'locked',         v_locked,
                     'has_strike',     v_show_strike and v_mrp_disp <> '',
                     'mrp_display',    case when v_show_strike then v_mrp_disp else '' end,
                     'has_discount',   (v_disc <> ''),
                     'discount_label', v_disc,
                     'discount_fg',    coalesce((select value from storefront_ui_label
                                                  where key='cart_row_discount_fg'), '#065F46')),
    -- A small solid badge on the thumbnail's top-right corner.
    'rx_chip',     jsonb_build_object(
                     'has',   coalesce(p_rx,false),
                     'label', public._c('cart.row_rx_chip'),
                     'tone',  jsonb_build_object(
                                'bg', coalesce((select value from storefront_ui_label
                                                 where key='cart_row_rx_bg'), '#1E40AF'),
                                'fg', coalesce((select value from storefront_ui_label
                                                 where key='cart_row_rx_fg'), '#FFFFFF'))));
end $function$;

-- ── 5. the full render, now built from the one line builder ─────────────────
create or replace function public._cart_render_core(p_guest_uid uuid default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
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
      'pill', jsonb_build_object(
        'show',        (v_lines > 0),
        'items_label', v_items_label,
        'cta',         coalesce(public.storefront_labels()->>'cart_pill_cta', ''),
        'image',       coalesce(v_items->0->>'image_url', '')),
      'labels', jsonb_build_object(
        'subtotal',     coalesce(v_pricing->>'taxable_label', 'Taxable value'),
        'mrp_worth',    coalesce(v_pricing->>'mrp_worth_label', 'MRP worth'),
        'gst',          coalesce(v_pricing->>'gst_total_label', 'GST'),
        'delivery',     coalesce(v_delivery->>'label', 'Delivery'),
        'grand',        public._c('cart.grand_total_label'),
        'total',        coalesce(v_pricing->>'net_payable_label', 'Net payable'))));
end
$function$;

-- ── 6. the write, split out of cart_set_item ────────────────────────────────
-- Same validation, same refusal messages, same upsert. cart_set_item() and
-- cart_update_item() both call it, so the fast door can never accept a write
-- the slow door would have refused.
create or replace function public._cart_write_item(p_product_id text, p_quantity integer, p_guest_uid uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_uid uuid; v_cust uuid; m record; v_mrp numeric; v_gst integer;
        v_tp jsonb; v_price numeric; v_src text; v_policy text;
begin
  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid  := p_guest_uid;
    v_cust := null;
  end if;

  if v_uid is null then
    return jsonb_build_object('ok',false,'message','Please log in');
  end if;
  if p_product_id is null or btrim(p_product_id) = '' then
    return jsonb_build_object('ok',false,'message','Product missing');
  end if;

  if coalesce(p_quantity,0) <= 0 then
    delete from cart_items
     where product_id = p_product_id
       and (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);
    return jsonb_build_object('ok',true,'removed',true,'message','Removed from cart');
  end if;

  select id, product_name, mrp, image_url_1, marketer, pack_size, therapeutic_class,
         gst_percent, supplier_count
    into m
  from "MEDICINE" where id::text = p_product_id;

  if not found then return jsonb_build_object('ok',false,'message','Product not found'); end if;

  -- CHANGE #640 — the SAME call every card, the product page and the cart's own
  -- render make. This line used to read `m.supplier_count` raw.
  if public.storefront_effective_count(m.id, m.supplier_count) < 1
     and public.viewer_is_approved_customer() then
    return jsonb_build_object('ok', false,
      'message', public.uic('storefront.no_supplier_note',
                            'No supplier for this product right now'));
  end if;

  v_mrp := nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric;

  -- #355 — the price is RESOLVED, never copied from the MRP.
  v_tp    := public.trade_price_line(m.id, p_quantity);
  v_price := nullif(v_tp->>'price','')::numeric;
  v_src   := nullif(v_tp->>'price_source','');
  v_gst   := round(coalesce((v_tp->>'gst_pct')::numeric, 0))::int;

  -- feature_gaps #80 — the sellability policy. 'strict' refuses a product with
  -- no trade rate instead of letting it into a cart it cannot price; 'inquiry'
  -- (the default) keeps mediBO's own model, where the rate arrives with the
  -- supplier quote AFTER the order.
  v_policy := coalesce((select value->>'mode' from app_settings where key='pricing_policy'), 'inquiry');
  if v_policy = 'strict' and v_src is null then
    return jsonb_build_object('ok', false,
      'message', coalesce((select value from storefront_ui_label where key='cart_no_price_yet'),
                          'Awaiting supplier rates'));
  end if;

  insert into cart_items (user_id, customer_id, product_id, product_name, price, mrp, quantity,
                          image_url, manufacturer, pack_size, category, gst_percent, added_by,
                          price_source)
  values (v_uid, v_cust, p_product_id, m.product_name, v_price, v_mrp, p_quantity,
          m.image_url_1, m.marketer, m.pack_size, m.therapeutic_class, v_gst,
          case when auth.uid() is null then 'guest'
               when public.my_acting_as() is not null then 'admin' else 'customer' end,
          v_src)
  on conflict (user_id, product_id) do update
    set quantity = excluded.quantity,
        price = excluded.price,
        price_source = excluded.price_source,
        gst_percent = excluded.gst_percent,
        customer_id = coalesce(excluded.customer_id, cart_items.customer_id),
        removed_by_admin = false,
        updated_at = now();

  return jsonb_build_object('ok',true,'removed',false,'message','Cart updated');
end;
$function$;

create or replace function public.cart_set_item(p_product_id text, p_quantity integer, p_guest_uid uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare w jsonb;
begin
  w := public._cart_write_item(p_product_id, p_quantity, p_guest_uid);
  if not coalesce((w->>'ok')::boolean, false) then
    return w;
  end if;
  return w || jsonb_build_object('cart', public.cart_render(p_guest_uid));
end;
$function$;

-- ── 7. the fast door ────────────────────────────────────────────────────────
-- ONE row back plus the two numbers the bar prints. No cart_render, no
-- cart_availability, no bill, no rail. `item` is null when the line is gone.
create or replace function public.cart_update_item(p_product_id text, p_quantity integer, p_guest_uid uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  v_retry   jsonb := jsonb_build_object('label', public._c('cart.row_retry'),
                                        'note',  public._c('cart.row_save_failed'));
begin
  w := public._cart_write_item(p_product_id, p_quantity, p_guest_uid);

  if not coalesce((w->>'ok')::boolean, false) then
    -- The refusal is the backend's own sentence; the row prints it inline and
    -- offers the backend's retry word. Nothing is worded on the client.
    return w || jsonb_build_object('product_id', p_product_id, 'retry', v_retry);
  end if;

  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid  := p_guest_uid;
    v_cust := null;
  end if;

  -- the one line that changed, in the SAME shape cart_render() sends
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

  -- the summary the bar prints: one aggregate over this cart's own rows.
  select count(*),
         coalesce(sum(coalesce(ci.quantity,0)), 0),
         coalesce(round(sum(coalesce(ci.quantity,0) * ci.mrp) filter (where ci.mrp is not null), 2), 0)
    into v_lines, v_units, v_mrp
    from cart_items ci
   where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
     and coalesce(ci.removed_by_admin, false) = false;

  -- the advance this basket would freeze — same ladder cart_summary_block
  -- reads. Any failure leaves it at zero; it never breaks a tap.
  begin
    if v_cust is not null then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
    v_adv     := public.advance_pct_for(v_cust, v_zone);
    v_adv_amt := round(v_mrp * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv_amt := 0;
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
      'bottom', jsonb_build_object(
        'has',             true,
        'items_label',     public._c('cart.bottom_items_label'),
        'items_value',     v_lines::text,
        'advance_label',   public._c('cart.bottom_advance_label'),
        'has_advance',     (v_adv_amt > 0),
        'advance_display', case when v_adv_amt > 0 then public.inr_money(v_adv_amt) else '' end)));
end $function$;

-- ── 8. cart_availability — the join that could never use the key ────────────
create or replace function public.cart_availability()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  -- CHANGE #640 — `eff` is computed ONCE per line and every answer below reads
  -- it: the count on the row, the verdict, the unavailable tally and the
  -- blocking label.
  -- CMD #2025 — the join was `m.id::text = ci.product_id`, which casts the
  -- INDEXED side and so scanned the whole catalogue on every cart open. The
  -- TEXT side is cast instead, guarded by the same digits test cart_state()
  -- uses, so a non-catalogue row still lands in `unresolved`.
  WITH lines AS (
    SELECT ci.product_id, ci.product_name, ci.quantity,
           m.id AS mid,
           public.storefront_effective_count(m.id, m.supplier_count) AS eff
      FROM cart_items ci
      LEFT JOIN "MEDICINE" m
             ON m.id = (CASE WHEN ci.product_id ~ '^[0-9]+$' THEN ci.product_id::bigint END)
     WHERE (CASE
              WHEN coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id()) IS NOT NULL
                THEN ci.customer_id = coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id())
              ELSE ci.user_id = public.viewer_cart_user()
            END)
       AND (ci.removed_by_admin IS NULL OR ci.removed_by_admin = false)
  ), tally AS (
    SELECT count(*) FILTER (WHERE mid IS NOT NULL AND coalesce(eff,0) < 1) AS bad,
           count(*) FILTER (WHERE mid IS NULL)                             AS unresolved
      FROM lines
  )
  SELECT jsonb_build_object(
    'gated', public.viewer_is_approved_customer(),
    'acting_as', public.my_acting_as(),
    'cart_user', public.viewer_cart_user(),
    'unavailable_count', t.bad,
    'unresolved_count',  t.unresolved,
    'items', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'product_id', l.product_id, 'product_name', l.product_name,
                 'quantity', l.quantity,
                 'supplier_count', l.eff,
                 'resolved', (l.mid IS NOT NULL),
                 'availability', public.storefront_cta(l.eff, (l.mid IS NOT NULL)))
               ORDER BY l.product_name)
          FROM lines l), '[]'::jsonb),
    'blocking_label', CASE WHEN public.viewer_is_approved_customer() AND t.bad > 0
                           THEN t.bad::text || ' item(s) in this cart have no supplier and will be removed'
                      END,
    'unresolved_note', CASE WHEN t.unresolved > 0
                            THEN t.unresolved::text || ' item(s) could not be checked and were kept' END)
  FROM tally t;
$function$;

-- ── 9. grants — the fast door is reachable exactly where the old one is ─────
revoke all on function public.cart_update_item(text, integer, uuid) from public;
revoke all on function public._cart_write_item(text, integer, uuid) from public;
revoke all on function public._cart_line_json(jsonb, jsonb) from public;
grant execute on function public.cart_update_item(text, integer, uuid)
  to anon, authenticated, service_role;
grant execute on function public._cart_line_json(jsonb, jsonb)
  to anon, authenticated, service_role;
-- _cart_write_item is an internal step: only the two doors above call it.
grant execute on function public._cart_write_item(text, integer, uuid) to service_role;
