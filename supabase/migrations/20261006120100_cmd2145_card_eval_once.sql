-- CMD #2145 — RG red after #1473 (c747_catalogue_budget: catalogue_list
-- 425–1621 ms against a 300 ms budget). Profiled with track_functions on
-- live: 24 cards cost ~450 ms, and three evaluation bugs made most of it.
--  1. _product_card: the planner flattens subquery x and copies x.b into
--     each of its two uses, so _product_card_base ran TWICE per card.
--     `offset 0` keeps x an evaluated-once subquery.
--  2. _product_card_base: foot_idle and action.qty_foot_tpl were two calls
--     of the identical _product_card_foot — computed once now.
--  3. _product_card_foot: `key = case public.viewer_price_state() …` was
--     re-evaluated per storefront_ui_label row (36 calls per card). The key
--     is now an uncorrelated scalar subquery — one initplan per call.
-- Output is byte-identical; only the number of evaluations changes.
-- Idempotent: create or replace.

CREATE OR REPLACE FUNCTION public._product_card_foot(p_card jsonb, p_scheme_line text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with l as (select
      (select value from storefront_ui_label where key='card_foot_unavailable') as unavail,
      (select value from storefront_ui_label where key='card_foot_notified')    as notified),
  f as (
    select case
      when p_card is null then null
      when not coalesce((p_card#>>'{availability,is_available}')::boolean, false)
           and coalesce((p_card->>'notified')::boolean, false) then
        jsonb_build_object('label', coalesce(l.notified, ''),
          'tone', jsonb_build_object('name','muted','bg','#F3F4F6','fg','#6B7280'))
      when not coalesce((p_card#>>'{availability,is_available}')::boolean, false) then
        jsonb_build_object('label', coalesce(l.unavail, nullif(p_card#>>'{availability,label}', ''), ''),
          'tone', jsonb_build_object('name','danger','bg','#FEE2E2','fg','#991B1B'))
      when coalesce((p_card->>'locked')::boolean, false) then
        jsonb_build_object('label', coalesce(
            (select value from storefront_ui_label where key =
               case (select public.viewer_price_state())
                 when 'register' then 'card_foot_locked_register'
                 when 'pending'  then 'card_foot_locked_pending'
                 else 'card_foot_locked' end),
            (select value from storefront_ui_label where key='card_foot_locked'),
            p_card#>>'{price,locked_note}', ''),
          'tone', jsonb_build_object('name','muted','bg','#F3F4F6','fg','#6B7280'))
      when coalesce(p_scheme_line, '') <> '' then
        jsonb_build_object('label', p_scheme_line,
          'tone', jsonb_build_object('name','brand','bg','#D1FAE5','fg','#1B7A43'))
      when coalesce((p_card#>>'{price,has_margin}')::boolean, false)
           and coalesce(p_card#>>'{price,margin_label}', '') <> '' then
        jsonb_build_object('label', p_card#>>'{price,margin_label}',
          'tone', jsonb_build_object('name','brand','bg','#D1FAE5','fg','#1B7A43'))
      else
        jsonb_build_object('label', coalesce(p_card#>>'{availability,label}', ''),
          'tone', jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46'))
    end as foot
    from l)
  select case when f.foot is null then null
              when not coalesce((select (value #>> '{}')::boolean from public.app_settings where key = 'card.show_foot'), true)
                then f.foot || jsonb_build_object('label', '', 'has', false)
              else f.foot || jsonb_build_object('has', coalesce(f.foot->>'label', '') <> '') end
    from f;
$function$

;

CREATE OR REPLACE FUNCTION public._product_card_base(m "MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_img   text := nullif(btrim(coalesce(m.image_url_1, '')), '');
  v_avail boolean := coalesce((p_avail->>'is_available')::boolean, false);
  v_price jsonb := coalesce(p_pricing->'card_price', '{}'::jsonb);
  v_locked boolean := coalesce((v_price->>'price_locked')::boolean, true)
                      and not public.viewer_is_approved_customer();
  v_qty   int := greatest(coalesce(p_qty, 0), 0);
  v_offer text;
  v_card  jsonb;
  v_idle  jsonb;
  v_scheme text := coalesce(p_pricing#>>'{scheme_effective,label}', '');
begin
  v_offer := case
    when coalesce((p_pricing->>'has_scheme')::boolean, false)
      then coalesce(p_pricing#>>'{scheme_badge,label}', p_pricing->>'scheme_text', '')
    when coalesce(m.has_scheme, false)
      then public.uic('catalogue.scheme_chip','Scheme available')
    else '' end;

  v_card := jsonb_build_object(
    'v', 1,
    'id', m.id,
    'name', coalesce(m.product_name, ''),
    'company', coalesce(m.marketer, ''),
    'image', jsonb_build_object(
      'url', coalesce(v_img, ''),
      'placeholder', v_img is null,
      'placeholder_letter', upper(left(btrim(coalesce(m.product_name, '?')), 1))),
    'pack_line', coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                          nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
    'unit_word', initcap(coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                  nullif(btrim(coalesce(m.pack_size, '')), ''), '')),
    'composition', coalesce(nullif(btrim(coalesce(m.salt_composition, '')), ''), ''),
    'has_composition', nullif(btrim(coalesce(m.salt_composition, '')), '') is not null,
    'rx', public.rx_card_badge(m.rx_required),
    'offer', jsonb_build_object('has', v_offer <> '', 'label', v_offer,
               'tone', jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46')),
    'availability', jsonb_build_object(
      'is_available', v_avail,
      'label', case when v_avail
                    then coalesce((select value from storefront_ui_label where key='card_avail_in'), '')
                    else coalesce(p_avail->>'cta_short', '') end,
      'tone', case when v_avail
                   then jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46')
                   else jsonb_build_object('name','neutral',
                          'bg', coalesce(p_avail#>>'{colors,bg}','#F3F4F6'),
                          'fg', coalesce(p_avail#>>'{colors,fg}','#6B7280')) end),
    'price', v_price || jsonb_build_object(
      'has_margin',   coalesce((p_pricing->>'has_margin')::boolean, false),
      'margin_label', coalesce(p_pricing->>'margin_label', ''),
      'margin_chip',  p_pricing->'margin_chip'),
    'qty_in_cart', v_qty,
    'notified', coalesce(p_notified, false),
    'locked', v_locked,
    'cta', public._product_card_cta(v_avail, v_locked, v_qty, p_notified, p_avail->'colors'),
    'wish', public.card_wish(m.id),
    -- CMD #2124 — every word the card's action can move to after a tap.
    'action', public._product_card_action(m, v_qty, p_notified));

  -- CMD #2122 — the ONE line under the price. CMD #2124 — plus the line the
  -- card falls back to once the pack leaves the cart (the pill set to 0).
  -- CMD #2145 — the idle foot is computed ONCE; it was two identical calls.
  v_idle := public._product_card_foot(v_card || jsonb_build_object('qty_in_cart', 0), v_scheme);
  return v_card || jsonb_build_object(
    'foot', case when v_qty = 0 then v_idle else public._product_card_foot(v_card, v_scheme) end,
    'foot_idle', v_idle,
    -- The pill already shows "N strip": the in-cart foot is the idle foot.
    'action', (v_card->'action') || jsonb_build_object(
                'qty_foot_tpl', coalesce(v_idle->>'label', ''),
                'qty_foot', case when v_qty > 0 then coalesce(v_idle->>'label', '') else '' end));
end $function$


;

CREATE OR REPLACE FUNCTION public._product_card(m "MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select x.b || jsonb_build_object(
    'style', x.st,
    'pack_chip', jsonb_build_object('label', x.pc, 'has', x.pc <> ''),
    'sub_line', public.card_sub_line(m) || jsonb_build_object('fg', x.st->>'sub_fg'),
    'placeholder', jsonb_build_object('kind', public.card_placeholder_kind(m.pack_qty, m.pack_type)),
    'layout', jsonb_build_object(
      'text_lines', coalesce((select (value #>> '{}')::int from public.app_settings where key = 'card.text_lines'), 3),
      'name_max_lines', 2),
    'price', coalesce(x.b->'price', '{}'::jsonb) || jsonb_build_object('mrp_struck', true, 'mrp_fg', x.st->>'mrp_fg'))
  from (select public._product_card_base(m, p_pricing, p_avail, p_qty, p_notified) b,
               public.card_pack_chip(m.pack_qty, m.pack_type) pc,
               public.card_style() st
        offset 0) x   -- CMD #2145: evaluate _product_card_base once, not per use of x.b
$function$


;
