-- CMD #2013 — The cart is a tight list, not a stack of cards.
--
-- One compact row per item: square thumbnail, name + pack, a solid quantity
-- pill and — directly under it — the money: the struck MRP, then the sale
-- price with its discount percent beside it. The "Sale price: PTR" chip, the
-- "MRP × qty" caption and the whole expanded detail body are gone, and so is
-- the ladder that used to sit above Place order (Sale price (PTR), MRP total,
-- Delivery FREE, the rate-confirmed note). In their place: ONE summary row —
-- "Total items 4" on the left, "Advance to pay ₹229.31" on the right.
--
-- Every string, every amount and the discount percent are decided and
-- formatted here. The screen prints them and computes nothing.
--
-- Idempotent by construction: copy rows upsert, every function is
-- CREATE OR REPLACE at its existing arity.

-- ── 1. Copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('cart.header_title',         to_jsonb('Cart'::text)),
  ('cart.bottom_items_label',   to_jsonb('Total items'::text)),
  ('cart.bottom_advance_label', to_jsonb('Advance to pay'::text)),
  ('cart.row_discount',         to_jsonb('{pct}% OFF'::text)),
  ('cart.row_remove',           to_jsonb('Remove'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

insert into public.storefront_ui_label (key, value) values
  ('cart_row_discount_fg', '#065F46'),
  ('cart_row_rx_bg',       '#1E40AF'),
  ('cart_row_rx_fg',       '#FFFFFF')
on conflict (key) do nothing;

-- ── 2. cart_card_price — carry the NUMBERS as well as the strings ───────────
-- The row needs mrp and ptr as numerics to word a discount percent. They were
-- already read here; only the two extra keys are new, so every existing caller
-- keeps the block it always got.
create or replace function public.cart_card_price(p_product_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_mrp numeric;
  v_row public.medicine_pricing;
begin
  if p_product_id is null then return '{}'::jsonb; end if;
  select nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric
    into v_mrp
  from "MEDICINE" m where m.id = p_product_id;
  select * into v_row from public.medicine_pricing where product_id = p_product_id;
  return coalesce(public._pricing_block(v_mrp, v_row, null)->'card_price', '{}'::jsonb)
         || jsonb_build_object(
              'mrp_value', v_mrp,
              'ptr_value', v_row.ptr);
exception when others then
  -- A cart that cannot price a line still renders. The row falls back to the
  -- locked wording, which is the honest answer anyway.
  return '{}'::jsonb;
end $function$;

-- ── 3. cart_row_block v3 — the compact row ──────────────────────────────────
create or replace function public.cart_row_block(
  p_item jsonb, p_trade jsonb, p_rx boolean, p_card jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_qty   int     := coalesce((p_item->>'quantity')::int, 0);
  v_pack  text    := btrim(coalesce(p_item->>'pack_size',''));
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

-- ── 4. cart_summary_block — ONE row above Place order ───────────────────────
-- `rows` stays in the payload for the View As / sidebar callers that still read
-- a ladder; the cart itself now prints `bottom` and nothing else.
create or replace function public.cart_summary_block(
  p_pricing jsonb, p_delivery jsonb, p_items_label text,
  p_grand_display text, p_mrp_total numeric, p_item_count integer)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_net      numeric := coalesce((p_pricing->>'net_payable')::numeric, 0);
  v_unpriced int     := coalesce((p_pricing->>'unpriced_count')::int, 0);
  v_priced   int     := coalesce((p_pricing->>'priced_count')::int, 0);
  v_has      boolean := (v_net > 0);
  v_rows     jsonb   := '[]'::jsonb;
  v_line     text;
  v_cust     uuid; v_zone smallint; v_adv jsonb; v_adv_amt numeric := 0;
begin
  if not v_has then
    v_line := public._cf('cart.summary_pending', jsonb_build_object('items', p_items_label));
  elsif v_unpriced > 0 then
    v_line := public._cf('cart.summary_partial',
                jsonb_build_object('items', p_items_label, 'pending', v_unpriced::text));
  else
    v_line := public._cf('cart.summary_priced', jsonb_build_object('items', p_items_label));
  end if;

  -- The advance this basket would freeze, from the same ladder the top strip
  -- used to read. Never allowed to break a cart: any failure leaves it at 0.
  begin
    v_cust := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                       public.my_customer_id());
    if v_cust is not null then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
    v_adv := public.advance_pct_for(v_cust, v_zone);
    v_adv_amt := round(coalesce(p_mrp_total,0) * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv := null; v_adv_amt := 0;
  end;

  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','items','label', public._c('cart.summary_items_label'),
    'amount', coalesce(p_item_count,0)::text, 'strong', false));
  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','grand','label', public._c('cart.grand_total_label'),
      'amount', p_grand_display, 'strong', true));
  end if;

  return jsonb_build_object(
    'line',           v_line,
    'delivery_note',  coalesce(p_delivery->>'note',''),
    'has_amount',     v_has,
    'show_line',      v_has,
    'amount_display', case when v_has then coalesce(p_pricing->>'net_payable_display','') else '' end,
    'priced_count',   v_priced,
    'unpriced_count', v_unpriced,
    'rate_note',      '',
    'rows',           v_rows,
    -- CMD #2013 — the ONE row the cart prints above Place order.
    'bottom', jsonb_build_object(
      'has',              true,
      'items_label',      public._c('cart.bottom_items_label'),
      'items_value',      coalesce(p_item_count,0)::text,
      'advance_label',    public._c('cart.bottom_advance_label'),
      'has_advance',      (v_adv_amt > 0),
      'advance_display',  case when v_adv_amt > 0 then public.inr_money(v_adv_amt) else '' end));
end $function$;

-- ── 5. The cart header is a TITLE ───────────────────────────────────────────
-- It read "4 products in cart", which said the item count a second time three
-- centimetres above the list that shows it. The whole #791 body is reproduced
-- verbatim; only the `header` key is added to each return.
create or replace function public.cart_render(p_guest_uid uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb; k text; arr jsonb; el jsonb; i int; n int := 0; bad bigint[]; ids bigint[];
begin
  v := public._cart_render_core(p_guest_uid);
  select coalesce(array_agg(u.product_id),'{}') into bad from public._cart_unavailable_lines() u;

  select coalesce(array_agg(distinct (e->>'product_id')::bigint), '{}')
    into ids
    from jsonb_array_elements(coalesce(v->'items','[]'::jsonb)) e
   where (e->>'product_id') ~ '^[0-9]+$';

  if coalesce(array_length(bad,1),0) = 0 or v is null or jsonb_typeof(v) <> 'object' then
    return coalesce(v,'{}'::jsonb)
        || jsonb_build_object('unavailable_count', 0)
        || jsonb_build_object('companions', public.cart_companions(ids))
        || jsonb_build_object('header', public._c('cart.header_title'));
  end if;
  for k in select jsonb_object_keys(v) loop
    if jsonb_typeof(v->k) = 'array' and jsonb_array_length(v->k) > 0
       and jsonb_typeof((v->k)->0) = 'object' and ((v->k)->0) ? 'product_id' then
      arr := '[]'::jsonb;
      for i in 0..jsonb_array_length(v->k)-1 loop
        el := (v->k)->i;
        if (nullif(el->>'product_id','')::bigint = any(bad)) then
          el := el || jsonb_build_object('unavailable', true, 'qty_locked', true);
          n := n + 1;
        end if;
        arr := arr || el;
      end loop;
      v := jsonb_set(v, array[k], arr);
    end if;
  end loop;
  return v || jsonb_build_object(
    'unavailable_count', coalesce(array_length(bad,1),0),
    'unavailable_badge', coalesce(array_length(bad,1),0)::text || ' item'
      || case when coalesce(array_length(bad,1),0) = 1 then '' else 's' end || ' not available',
    'companions', public.cart_companions(ids),
    'header', public._c('cart.header_title'));
end $function$;
