-- CMD #2196 — c747_catalogue_budget: catalogue_list over its 300 ms budget.
--
-- The guard had gone red 25 times in 400 runs, always on the same two RPCs
-- (catalogue_list 308-459 ms, catalogue_home 337-397 ms). Nothing in the
-- schema had drifted: rg_runs reported diffs 0, collection_errors 0, no
-- missing_critical. The page was simply sitting at ~200 ms warm with a 300 ms
-- budget, so any contention pushed all three attempts over.
--
-- WHERE THE TIME WENT (pg_stat_statements, track='all', ten calls of the
-- behaviour's own catalogue_list, diffed against a snapshot):
--   catalogue_list  ~200 ms  →  _cat_cards 192 ms  →  _product_card 150 ms
-- and _product_card's own children only account for ~80 ms of that. Running
-- the IDENTICAL body inline, as a lateral in a query, costs 82 ms for the same
-- 24 cards; going through the function costs 150-160 ms. The wrapper alone was
-- ~2.9 ms per card — 75 ms, over a third of the whole page.
--
-- The cause is the shape, not the attributes. Tested on live with pg_temp
-- copies: security definer / set search_path / neither all measured the same
-- (148-162 ms). `_product_card` is a LANGUAGE sql function whose body has a
-- FROM clause — the `offset 0` fence CMD #2145 put there to stop
-- _product_card_base being evaluated once per REFERENCE of x.b. A SQL function
-- with a FROM clause can never be inlined, so every card pays a full query
-- executor start/stop for a SubqueryScan whose only job is "compute these
-- three values once".
--
-- plpgsql says "compute these three values once" in the language itself: three
-- DECLARE variables, no subquery, no fence, and the same guarantee CMD #2145
-- wanted. Measured on live, same 24 cards, interleaved: 85 ms vs 159 ms.
-- _product_card_action is the same shape (two CTEs, one row) and goes the same
-- way: 4-17 ms vs 20 ms.
--
-- Output is byte-identical, proven on live before this was written: 1,200
-- (card, qty, notified, chrome-passed / chrome-null) combinations over 300
-- products, including scheme products and image-less products — 1,200 of 1,200
-- identical texts; and 1,000 of 1,000 for _product_card_action.
--
-- Projection: catalogue_list ~200 ms → ~115 ms, catalogue_home likewise, which
-- is the headroom the 300 ms budget needs.

create or replace function public._product_card(
  m "MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer,
  p_notified boolean, p_chrome jsonb default null::jsonb)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  -- CMD #2145's fence, said in the language instead of with `offset 0`: each of
  -- these is evaluated exactly once, however many times it is referenced below.
  -- CMD #2184: the page's chrome is built ONCE by the list builder and passed
  -- in; the coalesce still short-circuits for the callers that do not.
  v_b  jsonb := public._product_card_base(m, p_pricing, p_avail, p_qty, p_notified);
  v_pc text  := public.card_pack_chip(m.pack_qty, m.pack_type);
  v_ch jsonb := coalesce(p_chrome, public._product_card_chrome());
begin
  return v_b || jsonb_build_object(
    'style', v_ch->'style',
    'pack_chip', jsonb_build_object('label', v_pc, 'has', v_pc <> ''),
    'sub_line', public.card_sub_line(m) || jsonb_build_object('fg', v_ch->>'sub_fg'),
    'placeholder', jsonb_build_object('kind', public.card_placeholder_kind(m.pack_qty, m.pack_type)),
    -- CMD #2167 — the card's whole geometry, live in the payload.
    'layout', v_ch->'layout',
    'show', v_ch->'show',
    'layout_screens', v_ch->'layout_screens',
    'price', coalesce(v_b->'price', '{}'::jsonb) || jsonb_build_object('mrp_struck', true, 'mrp_fg', v_ch->>'mrp_fg'),
    -- CMD #2160 — Product card v6.
    'v6', jsonb_build_object(
      'image_pct', (v_ch->>'image_pct')::int,
      'scheme', public.card_scheme_short(m, p_pricing),
      'unavail_chip', jsonb_build_object(
        'has', not coalesce((v_b#>>'{availability,is_available}')::boolean, false),
        'label', v_ch->>'unavail_label',
        'bg', v_ch->>'unavail_bg',
        'fg', v_ch->>'unavail_fg'),
      'notify_pill', jsonb_build_object(
        'bg', v_ch->>'notify_bg',
        'fg', v_ch->>'notify_fg')));
end
$function$;

create or replace function public._product_card_action(
  m "MEDICINE", p_qty integer, p_notified boolean)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_unit text  := public.bulk_qty_unit(m.pack_type);
  v_qty  int   := greatest(coalesce(p_qty, 0), 0);
  -- CMD #2190 — one scan for every label this block prints.
  v_l    jsonb;
  -- "{qty} strip" — singular template (kept for old builds); _one/_many
  -- pluralise ("4 strips"). One read, three uses.
  v_tpl  text  := public.uic('bulk.qty_line', '{qty} {unit}');
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_l
    from storefront_ui_label
   where key in ('card_qty_foot','card_notify_short','card_notified_label',
                 'card_foot_unavailable','card_foot_notified');

  return jsonb_build_object(
    'picker', jsonb_build_object('rpc', 'card_qty_picker', 'pack_type', coalesce(m.pack_type, '')),
    'qty_tpl', replace(v_tpl, '{unit}', v_unit),
    'qty_tpl_one', replace(v_tpl, '{unit}', v_unit),
    'qty_tpl_many', replace(v_tpl, '{unit}', public._unit_plural(v_unit, 2)),
    'qty_label', case when v_qty > 0 then public.bulk_qty_line(v_qty, m.pack_type) else '' end,
    'qty_foot_tpl', replace(coalesce(v_l->>'card_qty_foot', ''), '{unit}', v_unit),
    'qty_foot', case when v_qty > 0 then
                  replace(replace(coalesce(v_l->>'card_qty_foot', ''),
                                  '{unit}', public._unit_plural(v_unit, v_qty)), '{qty}', v_qty::text)
                else '' end,
    'notify', jsonb_build_object(
      'rpc', 'stock_notify_request',
      'notified', coalesce(p_notified, false),
      'label', coalesce(v_l->>'card_notify_short', ''),
      'done_label', coalesce(v_l->>'card_notified_label', ''),
      'idle_line', coalesce(v_l->>'card_foot_unavailable', ''),
      'done_line', coalesce(v_l->>'card_foot_notified', ''),
      'tone', jsonb_build_object('name','danger','bg','#FEE2E2','fg','#991B1B')));
end
$function$;
