-- CMD #1912 — Cart page rebuild: one compact row per item.
--
-- Every string the new cart row prints is built HERE. The screen renders
-- `cart_render().items[].row` verbatim: the name, the pack caption, the
-- quantity that leads the row ("4 Strip"), the Rx chip, the one price line
-- inside the expanded body and the detail rows underneath it. Dart derives
-- nothing — the unit word used to be a chain of `contains()` calls in
-- _CartStepper._unit, which is exactly the kind of decision that belongs in
-- the payload.
--
-- Idempotent: every object is CREATE OR REPLACE / upsert, and the one
-- signature change (cart_summary_block gains the MRP total) drops the old
-- 4-argument form first so no call can ever be ambiguous.

-- ── copy ────────────────────────────────────────────────────────────────────
insert into ui_copy (key, value) values
  ('cart.unit_qty',            to_jsonb('{qty} {unit}'::text)),
  ('cart.row_mrp_line',        to_jsonb('MRP {mrp} × {qty}'::text)),
  ('cart.row_no_mrp',          to_jsonb('MRP not printed on this pack'::text)),
  ('cart.row_price_badge',     to_jsonb('Sale price: {price}'::text)),
  ('cart.row_price_on_quote',  to_jsonb('PTR'::text)),
  ('cart.row_rx_chip',         to_jsonb('Rx'::text)),
  ('cart.row_label_company',   to_jsonb('Company'::text)),
  ('cart.row_label_mrp',       to_jsonb('MRP'::text)),
  ('cart.row_label_pack',      to_jsonb('Pack'::text)),
  ('cart.row_pack_unknown',    to_jsonb('Pack size not listed'::text)),
  ('cart.row_expand_more',     to_jsonb('Details'::text)),
  ('cart.row_expand_less',     to_jsonb('Hide'::text)),
  ('cart.summary_items_label', to_jsonb('Items'::text)),
  ('cart.summary_mrp_label',   to_jsonb('MRP total'::text)),
  ('cart.rate_note',           to_jsonb('Rate confirmed after supplier quote.'::text)),
  ('home_shell.clear_cart_cancel', to_jsonb('Cancel'::text)),
  -- The pending basket said "rate confirmed after supplier quote" in the
  -- summary line AND, since this change, once above the total. It is one
  -- sentence, so the line goes back to being just the item count.
  ('cart.summary_pending',     to_jsonb('{items}'::text))
on conflict (key) do update set value = excluded.value;

-- ── the unit word, once, in the backend ─────────────────────────────────────
create or replace function public.cart_unit_label(p_pack text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when lower(coalesce(p_pack,'')) like '%strip%'   then public._c('cart.unit_strip')
    when lower(coalesce(p_pack,'')) like '%bottle%'  then public._c('cart.unit_bottle')
    when lower(coalesce(p_pack,'')) like '%vial%'    then public._c('cart.unit_vial')
    when lower(coalesce(p_pack,'')) like '%tube%'    then public._c('cart.unit_tube')
    when lower(coalesce(p_pack,'')) like '%sachet%'  then public._c('cart.unit_sachet')
    when lower(coalesce(p_pack,'')) like '%box%'     then public._c('cart.unit_box')
    when lower(coalesce(p_pack,'')) like '%ampoule%'
      or lower(coalesce(p_pack,'')) like '%ampule%'  then public._c('cart.unit_ampoule')
    when lower(coalesce(p_pack,'')) like '%pack%'    then public._c('cart.unit_pack')
    else public._c('cart.unit_default')
  end
$$;

-- ── one cart row ────────────────────────────────────────────────────────────
-- p_item is the cart_state() item (already carrying the #572 price keys),
-- p_trade the matching pricing line, p_rx whether this product is Rx.
create or replace function public.cart_row_block(p_item jsonb, p_trade jsonb, p_rx boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_qty   int     := coalesce((p_item->>'quantity')::int, 0);
  v_pack  text    := btrim(coalesce(p_item->>'pack_size',''));
  v_unit  text    := public.cart_unit_label(v_pack);
  v_has_mrp boolean := (nullif(p_item->>'mrp','') is not null);
  v_mrp   numeric := coalesce(nullif(p_item->>'mrp','')::numeric, 0);
  v_rate  boolean := coalesce((p_trade->>'has_trade_rate')::boolean, false);
  v_price text    := case when v_rate then coalesce(p_trade->>'price_display','')
                          else public._c('cart.row_price_on_quote') end;
  v_rows  jsonb   := '[]'::jsonb;
  v_company text  := btrim(coalesce(p_item->>'manufacturer',''));
begin
  -- The expanded body: company, MRP and pack detail. A value the record does
  -- not have is simply not a row — the cart never prints an empty dash.
  if v_company <> '' then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','company','label', public._c('cart.row_label_company'), 'value', v_company));
  end if;
  if v_has_mrp then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','mrp','label', public._c('cart.row_label_mrp'),
      'value', public.inr_money(v_mrp)));
  end if;
  if v_pack <> '' then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','pack','label', public._c('cart.row_label_pack'), 'value', v_pack));
  end if;

  return jsonb_build_object(
    'name',        coalesce(p_item->>'product_name',''),
    'pack_label',  case when v_pack <> '' then v_pack
                        else public._c('cart.row_pack_unknown') end,
    'has_pack',    (v_pack <> ''),
    'unit',        v_unit,
    'qty',         v_qty,
    -- "4 Strip" — the quantity that leads the row.
    'qty_label',   public._cf('cart.unit_qty',
                     jsonb_build_object('qty', v_qty::text, 'unit', v_unit)),
    'image_url',   coalesce(p_item->>'image_url',''),
    'company',     v_company,
    -- ONE price line inside the expanded row: "MRP ₹944.80 × 4" on the left,
    -- the sale-price badge on the right. When no MRP is printed on the pack
    -- the left side says so instead of inventing a figure.
    'mrp_line',    case when v_has_mrp
                        then public._cf('cart.row_mrp_line', jsonb_build_object(
                               'mrp', public.inr_money(v_mrp), 'qty', v_qty::text))
                        else public._c('cart.row_no_mrp') end,
    'has_mrp',     v_has_mrp,
    'price_badge', jsonb_build_object(
                     'has',   (v_price <> ''),
                     'label', case when v_price = '' then ''
                                   else public._cf('cart.row_price_badge',
                                          jsonb_build_object('price', v_price)) end,
                     'priced', v_rate,
                     'tone',  jsonb_build_object('bg','#D1FAE5','fg','#065F46')),
    'rx_chip',     jsonb_build_object(
                     'has',   coalesce(p_rx,false),
                     'label', public._c('cart.row_rx_chip'),
                     'tone',  jsonb_build_object('bg','#EFF6FF','fg','#1E40AF')),
    'expand',      jsonb_build_object(
                     'more', public._c('cart.row_expand_more'),
                     'less', public._c('cart.row_expand_less')),
    'detail_rows', v_rows);
end
$function$;

-- ── the summary ladder ──────────────────────────────────────────────────────
-- CMD #1912: Items · MRP total · Delivery, then the payable rows. The MRP
-- total is now an argument, so the old 4-argument form is dropped outright:
-- a defaulted 5th parameter would leave every 4-argument call ambiguous.
drop function if exists public.cart_summary_block(jsonb, jsonb, text, text);

create or replace function public.cart_summary_block(
  p_pricing jsonb, p_delivery jsonb, p_items_label text, p_grand_display text,
  p_mrp_total numeric, p_item_count int)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_net      numeric := coalesce((p_pricing->>'net_payable')::numeric, 0);
  v_unpriced int     := coalesce((p_pricing->>'unpriced_count')::int, 0);
  v_priced   int     := coalesce((p_pricing->>'priced_count')::int, 0);
  v_has      boolean := (v_net > 0);
  v_rows     jsonb   := '[]'::jsonb;
  v_line     text;
begin
  if not v_has then
    v_line := public._cf('cart.summary_pending', jsonb_build_object('items', p_items_label));
  elsif v_unpriced > 0 then
    v_line := public._cf('cart.summary_partial',
                jsonb_build_object('items', p_items_label, 'pending', v_unpriced::text));
  else
    v_line := public._cf('cart.summary_priced', jsonb_build_object('items', p_items_label));
  end if;

  -- Items — the count, as a number against a plain label.
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','items','label', public._c('cart.summary_items_label'),
    'amount', coalesce(p_item_count,0)::text, 'strong', false));

  -- MRP total — the printed ceiling, reference only.
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','mrp_total','label', public._c('cart.summary_mrp_label'),
    'amount', public.inr_money(coalesce(p_mrp_total,0)), 'strong', false));

  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','net','label', coalesce(p_pricing->>'net_payable_label','Net payable'),
      'amount', coalesce(p_pricing->>'net_payable_display',''), 'strong', false));
  end if;

  if coalesce((p_delivery->>'has')::boolean, false) then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','delivery','label', coalesce(p_delivery->>'label',''),
      'amount', coalesce(p_delivery->>'amount_display',''), 'strong', false));
    if coalesce((p_delivery->>'has_gst')::boolean, false) then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'key','delivery_gst','label', coalesce(p_delivery->>'gst_label',''),
        'amount', coalesce(p_delivery->>'gst_display',''), 'strong', false));
    end if;
  end if;

  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','grand','label', public._c('cart.grand_total_label'),
      'amount', p_grand_display, 'strong', true));
  end if;

  return jsonb_build_object(
    'line',           v_line,
    'delivery_note',  coalesce(p_delivery->>'note',''),
    'has_amount',     v_has,
    -- The line only earns its place next to an amount; the rows below say
    -- everything it used to say on a basket that has no total yet.
    'show_line',      v_has,
    'amount_display', case when v_has then coalesce(p_pricing->>'net_payable_display','') else '' end,
    'priced_count',   v_priced,
    'unpriced_count', v_unpriced,
    -- Said ONCE, above the total, instead of on every row.
    'rate_note',      case when v_unpriced > 0 then public._c('cart.rate_note') else '' end,
    'rows',           v_rows);
end
$function$;

-- ── the notice loses the Rx record line ─────────────────────────────────────
-- CMD #1912: "5 prescription items in this order" was a whole footer line for
-- something now shown where it belongs — a small Rx chip on the rows that
-- need one.
create or replace function public.cart_notice_block(p_rx jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_msg    text    := coalesce(p_rx->>'message','');
  v_reason text    := coalesce(p_rx->'licence'->>'reason','');
  v_block  boolean := coalesce((p_rx->>'blocked')::boolean, false);
  v_chip   jsonb   := coalesce(p_rx->'chip', jsonb_build_object('has', false));
  v_label  text;
begin
  if not v_block then
    return jsonb_build_object('has', false, 'blocking', false,
      'title', '', 'message', '',
      'note', '',
      'chip', v_chip,
      'action', jsonb_build_object('has', false));
  end if;

  v_label := case when v_reason = 'expired'
                  then public._c('cart.notice_renew_licence')
                  else public._c('cart.notice_add_licence') end;

  return jsonb_build_object(
    'has',      true,
    'blocking', true,
    'kind',     'drug_licence',
    'title',    coalesce(p_rx->>'title',''),
    'message',  v_msg,
    'note',     '',
    'chip',     v_chip,
    'tone',     coalesce(p_rx->'tone', jsonb_build_object('bg','#FEE2E2','fg','#991B1B')),
    'action',   jsonb_build_object(
                  'has',       (v_label <> ''),
                  'label',     v_label,
                  'kind',      'customer_route',
                  'route_key', 'cust_account',
                  'tab_key',   'profile',
                  'section',   'kyc'));
end
$function$;

-- ── the core payload carries a ready-made row per line ──────────────────────
create or replace function public._cart_render_core(p_guest_uid uuid DEFAULT NULL::uuid)
returns jsonb
language plpgsql
stable
security definer
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
  v_grand numeric;
  v_grand_display text;
  v_unpriced_line text := coalesce((select value from storefront_ui_label where key='cart_unpriced_line_note'),
                                   'Rate on supplier confirmation');
  v_no_mrp text := coalesce((select value from storefront_ui_label where key='cart_no_mrp_note'),
                            'MRP not printed on this pack');
begin
  -- ONE PRICE TRUTH PER LINE (#572) plus, since CMD #1912, ONE READY-MADE ROW.
  -- `row` is everything the compact cart row prints — the quantity that leads
  -- it, the pack caption, the Rx chip and the expanded detail — so the screen
  -- can render a line without deciding anything about it.
  select coalesce(jsonb_agg(
           it || coalesce(tp, '{}'::jsonb) || jsonb_build_object(
             'has_mrp',           (nullif(it->>'mrp','') is not null),
             'mrp_display',       case when nullif(it->>'mrp','') is null then ''
                                       else public.inr_money((it->>'mrp')::numeric) end,
             'line_mrp_display',  case when nullif(it->>'mrp','') is null then ''
                                       else public.inr_money(coalesce((it->>'line_mrp')::numeric,0)) end,
             'mrp_note',          case when nullif(it->>'mrp','') is null then v_no_mrp else '' end,
             'has_trade_rate',    coalesce((tp->>'has_trade_rate')::boolean, false),
             'rate_note',         case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then '' else v_unpriced_line end,
             'is_rx',             coalesce(rx, false),
             'row',               public.cart_row_block(it, coalesce(tp,'{}'::jsonb), coalesce(rx,false)),
             'qty_label',         case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then (it->>'quantity') || ' × ' || (tp->>'price_display')
                                       else (it->>'quantity') || ' × ' || v_unpriced_line end,
             'price_line',        case when coalesce((tp->>'has_trade_rate')::boolean, false)
                                       then coalesce(nullif(tp->>'line_net_display',''),
                                                     public.inr_money(coalesce((tp->>'line_net')::numeric,0)))
                                       else '' end,
             'price_note',        case
                                    when coalesce((tp->>'has_trade_rate')::boolean, false)
                                      then (it->>'quantity') || ' × ' || (tp->>'price_display')
                                    when nullif(it->>'mrp','') is null
                                      then public._c('cart.line_rate_pending_no_mrp')
                                    else public._cf('cart.line_rate_pending',
                                           jsonb_build_object('mrp',
                                             public.inr_money(coalesce(nullif(it->>'line_mrp','')::numeric,
                                                                       nullif(it->>'mrp','')::numeric, 0))))
                                  end)
           order by ord), '[]'::jsonb)
    into v_items
  from (select it, ordinality as ord
        from jsonb_array_elements(coalesce(v_cart->'items','[]'::jsonb))
             with ordinality as t(it, ordinality)) z
  left join lateral (
    select l as tp
      from jsonb_array_elements(coalesce(v_pricing->'lines','[]'::jsonb)) l
     where (l->>'product_id') = (z.it->>'product_id')
     limit 1) p on true
  left join lateral (
    select (upper(btrim(coalesce(m.rx_required,''))) = 'RX') as rx
      from "MEDICINE" m
     where m.id = (case when (z.it->>'product_id') ~ '^[0-9]+$'
                        then (z.it->>'product_id')::bigint end)
     limit 1) r on true;

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

-- Grants mirror what the replaced functions already carried: the cart renders
-- for guests, so anon must keep reaching it. cart_row_block/cart_unit_label are
-- helpers called by a SECURITY DEFINER parent and are NOT exposed to anon.
revoke all on function public.cart_row_block(jsonb, jsonb, boolean) from public, anon;
revoke all on function public.cart_unit_label(text) from public, anon;
grant execute on function public.cart_row_block(jsonb, jsonb, boolean) to authenticated, service_role;
grant execute on function public.cart_unit_label(text) to authenticated, service_role;
revoke all on function public.cart_summary_block(jsonb, jsonb, text, text, numeric, int) from public, anon;
grant execute on function public.cart_summary_block(jsonb, jsonb, text, text, numeric, int) to authenticated, service_role;
