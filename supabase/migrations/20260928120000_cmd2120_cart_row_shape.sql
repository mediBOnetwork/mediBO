-- CMD #2120 — the cart row gets the Bulk Upload shape.
--
-- The phone cart row printed a name, a pack caption, a 150px − 1 + stepper and
-- a two-line money block. The Bulk Upload review list (#2115 / CHANGE #1454,
-- #2119) had already settled what a four-line product row looks like on a
-- 360px phone, and the cart was the one storefront surface still drawing its
-- own: two different shapes for the same product, three taps apart.
--
-- This file adds what the cart row was missing so the SAME four lines can be
-- printed from the payload. Nothing new is computed in Dart:
--
--   line 1  name            — already on the row
--   line 2  composition     — MEDICINE.salt_composition, VERBATIM, one line
--   line 3  sale_badge      — _pricing_block()'s card_price: the formatted
--                             amount for an approved viewer, the locked word
--                             ("PTR") for everyone else, in the badge's own
--                             two colours. No MRP line, no strike, no percent
--                             derived anywhere.
--   line 4  qty_chip        — bulk_qty_line(qty, pack_type): "5 strip", the
--                             SAME template and the SAME lowercase unit word
--                             the Bulk Upload row prints, plus the pack_type
--                             the picker needs so the cart chip can open
--                             bulk_qty_picker() — one popup, not two.
--
-- Zone/date: this file adds no list, no count and no report. The one thing on
-- the row that IS zone-scoped — the price — already arrives through
-- cart_card_price() → _pricing_block(), and the availability verdict beside it
-- is cart_availability()'s, whose storefront_effective_count() reads the
-- viewer's zone. There is no new query here with a zone dimension to read.
--
-- Idempotent: ui_copy inserts are on-conflict-do-nothing, both functions are
-- create-or-replace with their existing signatures.

-- ── copy ─────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  -- The accessible name of the quantity chip. The chip's visible text is
  -- bulk_qty_line() ("5 strip"); this is what it is FOR.
  ('cart.qty_chip_hint', '"Change quantity"'::jsonb)
on conflict (key) do nothing;

-- ── the line builder: two more columns off the lookup it already does ───────
-- rx_required and image_url_1 were already being read by primary key for every
-- line. salt_composition and pack_type ride along on the same row — no extra
-- query, and both reach cart_row_block() on the item itself.
create or replace function public._cart_line_json(p_item jsonb, p_trade jsonb default null::jsonb)
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
  v_img  text := '';
  v_salt text := '';
  v_ptype text := '';
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
  -- `cart_items.image_url` is whatever the client happened to write when the
  -- line was added, and in production it is blank on EVERY row. The product's
  -- own image_url_1 is the authority the rest of the storefront reads; the
  -- stored value only wins when it is genuinely set.
  -- CMD #2120 — salt_composition and pack_type come off the same read.
  if v_pid is not null then
    select (upper(btrim(coalesce(m.rx_required,''))) = 'RX'),
           coalesce(nullif(btrim(m.image_url_1), ''), ''),
           coalesce(nullif(btrim(m.salt_composition), ''), ''),
           coalesce(nullif(btrim(m.pack_type), ''), '')
      into v_rx, v_img, v_salt, v_ptype
      from "MEDICINE" m
     where m.id = v_pid
     limit 1;
  end if;
  v_rx  := coalesce(v_rx, false);
  v_img := coalesce(v_img, '');
  if coalesce(btrim(p_item->>'image_url'), '') = '' and v_img <> '' then
    p_item := p_item || jsonb_build_object('image_url', v_img);
  end if;
  p_item := p_item || jsonb_build_object(
              'salt_composition', coalesce(v_salt, ''),
              'pack_type',        coalesce(v_ptype, ''));
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

-- ── the row block: three more members, nothing removed ──────────────────────
-- `stepper` and `price` STAY on the payload. The phone row no longer draws
-- either of them, but the desktop cart is untouched by this change and still
-- reads both, and a client mid-deploy must keep rendering.
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
  -- CMD #2120 — the catalogue's own pack word, and the salts, VERBATIM.
  v_ptype text    := btrim(coalesce(p_item->>'pack_type', ''));
  v_salt  text    := btrim(coalesce(p_item->>'salt_composition', ''));
  v_chip_unit text := case when v_ptype <> '' then v_ptype else v_unit end;
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
    -- CMD #2120 — line 2 of the phone row. MEDICINE.salt_composition as it is
    -- printed on the pack, never expanded, corrected or looked up elsewhere.
    -- `has_composition:false` is the backend saying "this line has no second
    -- line" — the screen draws nothing rather than inventing a caption.
    'composition',     v_salt,
    'has_composition', (v_salt <> ''),
    -- CMD #2120 — line 3. ONE badge, the sale price and nothing else: the
    -- formatted amount when the viewer is entitled to it, the locked word
    -- otherwise, in _pricing_block()'s own two colours. No MRP, no strike, no
    -- percent — a PTR number can never reach an unapproved viewer because the
    -- value IS card_price.price_display, which is already withheld upstream.
    'sale_badge',  jsonb_build_object(
                     'has',    (v_value <> ''),
                     'label',  coalesce(v_card->>'sale_label', ''),
                     'value',  v_value,
                     'locked', v_locked,
                     'bg',     coalesce(nullif(v_card->>'sale_bg',''), '#1B7A43'),
                     'fg',     coalesce(nullif(v_card->>'sale_fg',''), '#FFFFFF')),
    -- CMD #2120 — line 4. The quantity and the pack word, through the SAME
    -- template the Bulk Upload review row prints ("5 strip"), plus the
    -- pack_type bulk_qty_picker() needs: tapping the chip opens that one
    -- popup, centred on `qty`, capped by bulk.qty_picker_max.
    'qty_chip',    jsonb_build_object(
                     'has',       true,
                     'label',     public.bulk_qty_line(v_qty, v_chip_unit),
                     'qty',       v_qty,
                     'pack_type', v_chip_unit,
                     'hint',      public._c('cart.qty_chip_hint')),
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
    -- CMD #2013 — the desktop money block. Two lines at most: a struck MRP
    -- above, the price with its discount percent below. `has_strike:false` is
    -- the backend saying "one line, no ceiling".
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

-- ── grants: unchanged surfaces, re-stated so a replay cannot drop them ──────
revoke all on function public._cart_line_json(jsonb, jsonb) from public;
grant execute on function public._cart_line_json(jsonb, jsonb) to anon, authenticated, service_role;
revoke all on function public.cart_row_block(jsonb, jsonb, boolean, jsonb) from public;
grant execute on function public.cart_row_block(jsonb, jsonb, boolean, jsonb) to anon, authenticated, service_role;
