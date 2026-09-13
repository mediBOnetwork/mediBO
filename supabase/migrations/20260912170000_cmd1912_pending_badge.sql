-- CMD #1912 (QA round 1) — a line awaiting a supplier quote stopped claiming
-- a sale price.
--
-- cart_row_block() painted EVERY price badge in the success pair
-- (#D1FAE5 / #065F46) and labelled it "Sale price: {price}". For a line with
-- no trade rate that came out as a green "Sale price: PTR": the success
-- colour the design system reserves for a confirmed figure, wrapped around an
-- acronym that is not a price. The summary already says "1 awaiting supplier
-- quote"; the row itself said the opposite.
--
-- The badge now carries the tone its own `priced` flag implies — success when
-- the trade rate is known, the pending pair (#FEF3C7 / #92400E) when it is
-- not — and the pending label is its own sentence rather than a price
-- template with a placeholder poured into it. Both are copy and both are
-- colours the payload sends, so the screen keeps rendering the badge verbatim
-- and no Dart changes.
--
-- A NEW file, not an edit of 20260912120000_cmd1912_cart_rows.sql: the replay
-- ledger keys on the filename, so editing a file that already ran on live
-- would leave production on the first version (standing lesson #303).
-- Idempotent: copy upserts, function is CREATE OR REPLACE.

insert into ui_copy (key, value) values
  -- The badge on a line whose rate is not confirmed yet. It is a state, not a
  -- price, so it is not poured through 'cart.row_price_badge'.
  ('cart.row_price_pending',   to_jsonb('Rate on quote'::text)),
  -- Kept as the pending PRICE token for anything that still wants one word.
  ('cart.row_price_on_quote',  to_jsonb('PTR'::text))
on conflict (key) do update set value = excluded.value;

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
  -- The badge is two different sentences, not one sentence with two values.
  v_badge text    := case
                       when v_rate then public._cf('cart.row_price_badge',
                              jsonb_build_object('price',
                                coalesce(p_trade->>'price_display','')))
                       else public._c('cart.row_price_pending')
                     end;
  v_rows  jsonb   := '[]'::jsonb;
  v_company text  := btrim(coalesce(p_item->>'manufacturer',''));
begin
  -- The expanded body: company and pack detail. A value the record does not
  -- have is simply not a row — the cart never prints an empty dash.
  if v_company <> '' then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','company','label', public._c('cart.row_label_company'), 'value', v_company));
  end if;
  -- MRP is deliberately NOT a detail row: the expanded body's one price line
  -- already prints it ("MRP ₹944.80 × 4"), and the same number twice in one
  -- panel is the repetition this rebuild exists to remove.
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
    -- the badge on the right. When no MRP is printed on the pack the left
    -- side says so instead of inventing a figure.
    'mrp_line',    case when v_has_mrp
                        then public._cf('cart.row_mrp_line', jsonb_build_object(
                               'mrp', public.inr_money(v_mrp), 'qty', v_qty::text))
                        else public._c('cart.row_no_mrp') end,
    'has_mrp',     v_has_mrp,
    'price_badge', jsonb_build_object(
                     'has',    (v_badge <> ''),
                     'label',  v_badge,
                     'priced', v_rate,
                     -- Success only for a rate that exists; the pending pair
                     -- otherwise. The screen paints what it is handed.
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
    'detail_rows', v_rows);
end
$function$;

revoke all on function public.cart_row_block(jsonb, jsonb, boolean) from public, anon;
grant execute on function public.cart_row_block(jsonb, jsonb, boolean) to authenticated, service_role;
