-- CMD #1952 — Cart correction: every row shows the SAME sale price the product
-- cards show, the top strip is items + advance due, and everything else moves
-- below the list.
--
-- Idempotent by construction: copy rows upsert, stale overloads are dropped by
-- a catalogue sweep (arity changed on cart_row_block and cart_summary_block),
-- and every function is CREATE OR REPLACE.

-- 1. Copy. Every string the cart row, the top strip and the sticky bar print
--    lives here, so a wording change is an UPDATE, never a deploy.
insert into public.ui_copy (key, value) values
  ('cart.row_label_sale',     to_jsonb('Sale price'::text)),
  ('cart.row_label_mrp',      to_jsonb('MRP'::text)),
  ('cart.row_label_company',  to_jsonb('Company'::text)),
  ('cart.row_label_pack',     to_jsonb('Pack'::text)),
  ('cart.row_pack_unknown',   to_jsonb('Pack size not listed'::text)),
  ('cart.row_pack_mrp',       to_jsonb('1 {unit} · MRP'::text)),
  ('cart.row_pack_only',      to_jsonb('1 {unit}'::text)),
  ('cart.row_mrp_qty',        to_jsonb('{mrp} × {qty}'::text)),
  ('cart.row_mrp_line',       to_jsonb('MRP {mrp} × {qty}'::text)),
  ('cart.row_no_mrp',         to_jsonb('MRP not printed on this pack'::text)),
  ('cart.row_price_badge',    to_jsonb('Sale price: {price}'::text)),
  ('cart.row_price_pending',  to_jsonb('PTR'::text)),
  ('cart.row_rx_chip',        to_jsonb('Rx'::text)),
  ('cart.row_expand_more',    to_jsonb('Details'::text)),
  ('cart.row_expand_less',    to_jsonb('Hide'::text)),
  ('cart.unit_qty',           to_jsonb('{qty} {unit}'::text)),
  ('cart.top_items',          to_jsonb('Items × {n}'::text)),
  ('cart.top_advance_label',  to_jsonb('Advance to pay:'::text)),
  ('cart.summary_items_label',to_jsonb('Items'::text)),
  ('cart.summary_mrp_label',  to_jsonb('MRP total'::text)),
  ('cart.bar_sale_label',     to_jsonb('Sale price (PTR)'::text)),
  ('cart.rate_note',          to_jsonb('Rate confirmed after supplier quote.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- 2. Arity changed on two blocks; a stale overload would make the call
--    ambiguous, so drop every signature that is not the one created below.
do $mig$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('cart_row_block','cart_summary_block','cart_top_strip','cart_card_price')
       and p.oid::regprocedure::text not in (
             'cart_row_block(jsonb,jsonb,boolean,jsonb)',
             'cart_summary_block(jsonb,jsonb,text,text,numeric,integer)',
             'cart_top_strip(integer,numeric)',
             'cart_card_price(bigint)')
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $mig$;

-- 3. cart_unit_label
CREATE OR REPLACE FUNCTION public.cart_unit_label(p_pack text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$

;

-- 3. cart_card_price
CREATE OR REPLACE FUNCTION public.cart_card_price(p_product_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_mrp numeric;
  v_row public.medicine_pricing;
begin
  if p_product_id is null then return '{}'::jsonb; end if;
  select nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric
    into v_mrp
  from "MEDICINE" m where m.id = p_product_id;
  select * into v_row from public.medicine_pricing where product_id = p_product_id;
  return coalesce(public._pricing_block(v_mrp, v_row, null)->'card_price', '{}'::jsonb);
exception when others then
  -- A cart that cannot price a line still renders. The row falls back to the
  -- locked wording, which is the honest answer anyway.
  return '{}'::jsonb;
end $function$

;

-- 3. cart_top_strip
CREATE OR REPLACE FUNCTION public.cart_top_strip(p_item_count integer, p_mrp_total numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cust uuid; v_zone smallint; v_adv jsonb; v_amt numeric;
begin
  begin
    v_cust := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                       public.my_customer_id());
    if v_cust is not null then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
    v_adv := public.advance_pct_for(v_cust, v_zone);
  exception when others then
    v_adv := null;
  end;

  v_amt := round(coalesce(p_mrp_total,0) * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);

  return jsonb_build_object(
    'show',            coalesce(p_item_count,0) > 0,
    'items_label',     public._cf('cart.top_items',
                         jsonb_build_object('n', coalesce(p_item_count,0)::text)),
    'item_count',      coalesce(p_item_count,0),
    'advance_label',   public._c('cart.top_advance_label'),
    'has_advance',     (v_adv is not null and v_amt > 0),
    'advance',         v_amt,
    'advance_display', public.inr_money(v_amt),
    'advance_pct',     (v_adv->>'pct')::numeric,
    'advance_pct_label', coalesce(v_adv->>'pct_label',''),
    'advance_source',  coalesce(v_adv->>'source',''));
end $function$

;

-- 3. cart_row_block
CREATE OR REPLACE FUNCTION public.cart_row_block(p_item jsonb, p_trade jsonb, p_rx boolean, p_card jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_qty   int     := coalesce((p_item->>'quantity')::int, 0);
  v_pack  text    := btrim(coalesce(p_item->>'pack_size',''));
  v_unit  text    := public.cart_unit_label(v_pack);
  v_has_mrp boolean := (nullif(p_item->>'mrp','') is not null);
  v_mrp   numeric := coalesce(nullif(p_item->>'mrp','')::numeric, 0);
  v_mrp_disp text := case when v_has_mrp then public.inr_money(v_mrp) else '' end;
  v_rate  boolean := coalesce((p_trade->>'has_trade_rate')::boolean, false);
  v_card  jsonb   := coalesce(p_card, '{}'::jsonb);
  -- The card's two strings, verbatim. An older payload (or a product that is
  -- not in the catalogue at all) has neither, and the row then says what it
  -- has always said rather than inventing a price.
  v_sale_label text := coalesce(nullif(v_card->>'sale_label',''),
                                coalesce((select value from storefront_ui_label
                                           where key='sale_price_caption'), 'Sale price:'));
  v_sale_value text := coalesce(v_card->>'price_display', '');
  v_sale_lock  boolean := coalesce((v_card->>'price_locked')::boolean, true);
  v_badge text    := case
                       when v_rate then public._cf('cart.row_price_badge',
                              jsonb_build_object('price',
                                coalesce(p_trade->>'price_display','')))
                       else public._c('cart.row_price_pending')
                     end;
  v_mrp_qty text  := case when v_has_mrp
                          then public._cf('cart.row_mrp_qty', jsonb_build_object(
                                 'mrp', v_mrp_disp, 'qty', v_qty::text))
                          else '' end;
  v_rows  jsonb   := '[]'::jsonb;
  v_exp   jsonb   := '[]'::jsonb;
  v_company text  := btrim(coalesce(p_item->>'manufacturer',''));
  v_sale_tone jsonb;
begin
  -- The sale badge's colours are the card's own, so one green means one thing
  -- across the app. A locked value ("PTR") keeps the same plate — it is the
  -- same line, with the amount withheld, not a different kind of line.
  v_sale_tone := jsonb_build_object(
    'bg', coalesce(nullif(v_card->>'sale_bg',''),
                   coalesce((select value from storefront_ui_label where key='sale_badge_bg'), '#1B7A43')),
    'fg', coalesce(nullif(v_card->>'sale_fg',''),
                   coalesce((select value from storefront_ui_label where key='sale_badge_fg'), '#FFFFFF')));

  -- The expanded body, IN ORDER: sale price, MRP × qty, company, pack. The
  -- screen renders this list top to bottom and decides none of it.
  if v_sale_value <> '' then
    v_exp := v_exp || jsonb_build_array(jsonb_build_object(
      'key','sale', 'label', public._c('cart.row_label_sale'),
      'value', v_sale_value, 'tone', v_sale_tone, 'strong', true));
  end if;
  if v_mrp_qty <> '' then
    v_exp := v_exp || jsonb_build_array(jsonb_build_object(
      'key','mrp', 'label', public._c('cart.row_label_mrp'),
      'value', v_mrp_qty, 'strike', true));
  end if;
  if v_company <> '' then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','company','label', public._c('cart.row_label_company'), 'value', v_company));
  end if;
  if v_pack <> '' then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','pack','label', public._c('cart.row_label_pack'), 'value', v_pack));
  end if;
  v_exp := v_exp || v_rows;

  return jsonb_build_object(
    'name',        coalesce(p_item->>'product_name',''),
    'pack_label',  case when v_pack <> '' then v_pack
                        else public._c('cart.row_pack_unknown') end,
    'has_pack',    (v_pack <> ''),
    'unit',        v_unit,
    'qty',         v_qty,
    'qty_label',   public._cf('cart.unit_qty',
                     jsonb_build_object('qty', v_qty::text, 'unit', v_unit)),
    -- CMD #1952 — the compact pill prints the number; the unit word is a
    -- label UNDER it. "1 S…" was the unit being squeezed into a 44px slot.
    'stepper',     jsonb_build_object(
                     'qty',        v_qty,
                     'qty_text',   v_qty::text,
                     'unit_label', v_unit),
    -- CMD #1952 — the caption that replaced the clipped chip. Two parts, so
    -- the MRP amount alone can be struck: it is an indicator, not a price.
    'pack_mrp',    jsonb_build_object(
                     'has',     true,
                     'prefix',  case when v_has_mrp
                                     then public._cf('cart.row_pack_mrp',
                                            jsonb_build_object('unit', v_unit))
                                     else public._cf('cart.row_pack_only',
                                            jsonb_build_object('unit', v_unit)) end,
                     'amount',  v_mrp_disp,
                     'strike',  v_has_mrp),
    -- CMD #1952 — THE price line, on every row, expanded or not: the card's
    -- caption and the card's `price_display`.
    'sale',        jsonb_build_object(
                     'has',    (v_sale_value <> ''),
                     'label',  v_sale_label,
                     'value',  v_sale_value,
                     'locked', v_sale_lock,
                     'tone',   v_sale_tone),
    'image_url',   coalesce(p_item->>'image_url',''),
    'company',     v_company,
    'mrp_line',    case when v_has_mrp
                        then public._cf('cart.row_mrp_line', jsonb_build_object(
                               'mrp', v_mrp_disp, 'qty', v_qty::text))
                        else public._c('cart.row_no_mrp') end,
    'mrp_qty',     v_mrp_qty,
    'mrp_display', v_mrp_disp,
    'has_mrp',     v_has_mrp,
    'price_badge', jsonb_build_object(
                     'has',    (v_badge <> ''),
                     'label',  v_badge,
                     'priced', v_rate,
                     'tone',   case when v_rate
                                 then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
                                 else jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                               end),
    'rx_chip',     jsonb_build_object(
                     'has',   coalesce(p_rx,false),
                     'label', public._c('cart.row_rx_chip'),
                     'tone',  jsonb_build_object('bg','#EFF6FF','fg','#1E40AF')),
    'expand',      jsonb_build_object(
                     'more', public._c('cart.row_expand_more'),
                     'less', public._c('cart.row_expand_less')),
    'expanded_rows', v_exp,
    'detail_rows', v_rows);
end $function$

;

-- 3. cart_summary_block
CREATE OR REPLACE FUNCTION public.cart_summary_block(p_pricing jsonb, p_delivery jsonb, p_items_label text, p_grand_display text, p_mrp_total numeric, p_item_count integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_net      numeric := coalesce((p_pricing->>'net_payable')::numeric, 0);
  v_unpriced int     := coalesce((p_pricing->>'unpriced_count')::int, 0);
  v_priced   int     := coalesce((p_pricing->>'priced_count')::int, 0);
  v_has      boolean := (v_net > 0);
  v_rows     jsonb   := '[]'::jsonb;
  v_line     text;
  v_sale_cap text := coalesce((select value from storefront_ui_label where key='sale_price_caption'),
                              'Sale price:');
  v_ptr_cap  text := coalesce((select value from storefront_ui_label where key='ptr_caption'), 'PTR');
  v_entitled boolean := false;
  v_taxable  numeric := coalesce((p_pricing->>'taxable')::numeric, 0);
begin
  if not v_has then
    v_line := public._cf('cart.summary_pending', jsonb_build_object('items', p_items_label));
  elsif v_unpriced > 0 then
    v_line := public._cf('cart.summary_partial',
                jsonb_build_object('items', p_items_label, 'pending', v_unpriced::text));
  else
    v_line := public._cf('cart.summary_priced', jsonb_build_object('items', p_items_label));
  end if;

  -- MRP total — the printed ceiling, reference only.
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','mrp_total','label', public._c('cart.summary_mrp_label'),
    'amount', public.inr_money(coalesce(p_mrp_total,0)), 'strong', false));

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

  -- A basket that IS priced still has to say what it costs. The spec's list is
  -- the unpriced case — dropping the payable from a priced basket would hide
  -- the one number the buyer is committing to.
  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','net','label', coalesce(p_pricing->>'net_payable_label','Net payable'),
      'amount', coalesce(p_pricing->>'net_payable_display',''), 'strong', false));
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','grand','label', public._c('cart.grand_total_label'),
      'amount', p_grand_display, 'strong', true));
  end if;

  begin
    v_entitled := coalesce(public.viewer_sees_trade_price(), false);
  exception when others then
    v_entitled := false;
  end;

  return jsonb_build_object(
    'line',           v_line,
    'delivery_note',  coalesce(p_delivery->>'note',''),
    'has_amount',     v_has,
    'show_line',      v_has,
    'amount_display', case when v_has then coalesce(p_pricing->>'net_payable_display','') else '' end,
    'priced_count',   v_priced,
    'unpriced_count', v_unpriced,
    'rate_note',      case when v_unpriced > 0 then public._c('cart.rate_note') else '' end,
    -- CMD #1952 — the sticky bar's own sale line.
    'sale_line', jsonb_build_object(
      'has',    true,
      'label',  coalesce(nullif(public._c('cart.bar_sale_label'),''), v_sale_cap),
      'value',  case when v_entitled and v_priced > 0 then public.inr_money(v_taxable)
                     else v_ptr_cap end,
      'locked', not (v_entitled and v_priced > 0),
      'tone',   jsonb_build_object(
                  'bg', coalesce((select value from storefront_ui_label where key='sale_badge_bg'), '#1B7A43'),
                  'fg', coalesce((select value from storefront_ui_label where key='sale_badge_fg'), '#FFFFFF'))),
    'rows',           v_rows);
end $function$

;

-- 3. _cart_render_core
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
  v_unpriced_line text := coalesce((select value from storefront_ui_label where key='cart_unpriced_line_note'),
                                   'Rate on supplier confirmation');
  v_no_mrp text := coalesce((select value from storefront_ui_label where key='cart_no_mrp_note'),
                            'MRP not printed on this pack');
begin
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
             -- CMD #1952 — the card's own price block travels with the line.
             'card_price',        coalesce(cp, '{}'::jsonb),
             'row',               public.cart_row_block(it, coalesce(tp,'{}'::jsonb),
                                                        coalesce(rx,false), coalesce(cp,'{}'::jsonb)),
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
     limit 1) r on true
  left join lateral (
    select public.cart_card_price(
             case when (z.it->>'product_id') ~ '^[0-9]+$'
                  then (z.it->>'product_id')::bigint end) as cp) cpx on true;

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
$function$

;

grant execute on function public.cart_unit_label(text)     to anon, authenticated;
grant execute on function public.cart_card_price(bigint)   to anon, authenticated;
grant execute on function public.cart_top_strip(integer,numeric) to anon, authenticated;
grant execute on function public.cart_row_block(jsonb,jsonb,boolean,jsonb) to anon, authenticated;
grant execute on function public.cart_summary_block(jsonb,jsonb,text,text,numeric,integer) to anon, authenticated;
grant execute on function public._cart_render_core(uuid)   to anon, authenticated;
notify pgrst, 'reload schema';
