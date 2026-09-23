-- CMD #2167 — the product card is ONE size everywhere and 100% backend-driven.
--
-- Three blocks now ride on every card payload, so a card's geometry, colours
-- and which parts it draws are all an UPDATE and never a deploy:
--
--   layout         — spacing, radius, padding, photo box, text sizes/weights,
--                    border, shadow, image fit, the grid's own gap/min width
--                    (app_settings 'card.layout')
--   show           — pack_chip, sub_line, mrp, ptr_badge, scheme_badge,
--                    action, photo  (app_settings 'card.show')
--   layout_screens — per-screen overrides of layout/style/show, keyed
--                    home|catalogue|search|company|wishlist|category
--                    (app_settings 'card.layout_screens')
--
-- `style` (card_style(), app_settings 'card.style') already carried the
-- colours; it stays where it is and is merged the same way.
--
-- The defaults below reproduce EXACTLY what the app draws today, so this
-- migration changes no pixel by itself — it only moves the numbers out of
-- Dart. Anything Om wants different is an update to app_settings.
--
-- Idempotent: create or replace + upserts.

-- ── 1. the settings rows ──────────────────────────────────────────────────
insert into public.app_settings(key, value)
values ('card.layout', '{
  "radius": 16,
  "border_w": 1,
  "pad_x": 12,
  "pad_bottom": 12,
  "gap_s": 4,
  "gap_m": 6,
  "gap_l": 8,
  "photo_pad": 0,
  "image_pct": 92,
  "image_fit": "contain",
  "name_size": 14,
  "name_weight": 700,
  "name_lines": 2,
  "name_line_h": 18,
  "sub_size": 12,
  "sub_weight": 400,
  "sub_line_h": 16,
  "price_size": 14,
  "price_weight": 800,
  "mrp_size": 12,
  "mrp_weight": 500,
  "chip_h": 26,
  "chip_size": 10,
  "chip_weight": 700,
  "chip_radius": 8,
  "action_h": 36,
  "touch_min": 44,
  "grid_gap": 12,
  "page_pad": 16,
  "min_card_w": 162,
  "max_cols": 6,
  "shadow_blur": 3,
  "shadow_dy": 1,
  "shadow_alpha": 0.06
}'::jsonb)
on conflict (key) do nothing;

insert into public.app_settings(key, value)
values ('card.show', '{
  "pack_chip": true,
  "sub_line": true,
  "mrp": true,
  "ptr_badge": true,
  "scheme_badge": true,
  "action": true,
  "photo": true,
  "wish": true
}'::jsonb)
on conflict (key) do nothing;

-- Per-screen overrides. Empty today: every screen draws the one card. A screen
-- key may carry {"layout":{…},"style":{…},"show":{…}} and only the keys it
-- names are overridden.
insert into public.app_settings(key, value)
values ('card.layout_screens', '{
  "home": {},
  "catalogue": {},
  "search": {},
  "company": {},
  "wishlist": {},
  "category": {}
}'::jsonb)
on conflict (key) do nothing;

-- ── 2. the readers ────────────────────────────────────────────────────────
create or replace function public.card_layout()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select '{"radius":16,"border_w":1,"pad_x":12,"pad_bottom":12,"gap_s":4,
           "gap_m":6,"gap_l":8,"photo_pad":0,"image_pct":92,
           "image_fit":"contain","name_size":14,"name_weight":700,
           "name_lines":2,"name_line_h":18,"sub_size":12,"sub_weight":400,
           "sub_line_h":16,"price_size":14,"price_weight":800,"mrp_size":12,
           "mrp_weight":500,"chip_h":26,"chip_size":10,"chip_weight":700,
           "chip_radius":8,"action_h":36,"touch_min":44,"grid_gap":12,
           "page_pad":16,"min_card_w":162,"max_cols":6,"shadow_blur":3,
           "shadow_dy":1,"shadow_alpha":0.06}'::jsonb
         || coalesce((select value from public.app_settings where key = 'card.layout'), '{}'::jsonb)
$function$;

create or replace function public.card_show()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select '{"pack_chip":true,"sub_line":true,"mrp":true,"ptr_badge":true,
           "scheme_badge":true,"action":true,"photo":true,"wish":true}'::jsonb
         || coalesce((select value from public.app_settings where key = 'card.show'), '{}'::jsonb)
$function$;

create or replace function public.card_layout_screens()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select coalesce((select value from public.app_settings where key = 'card.layout_screens'),
                  '{}'::jsonb)
$function$;

revoke all on function public.card_layout() from public;
revoke all on function public.card_show() from public;
revoke all on function public.card_layout_screens() from public;
grant execute on function public.card_layout() to anon, authenticated, service_role;
grant execute on function public.card_show() to anon, authenticated, service_role;
grant execute on function public.card_layout_screens() to anon, authenticated, service_role;

-- ── 3. every card carries them ────────────────────────────────────────────
-- `layout` keeps its two v5 keys (text_lines / name_max_lines) so nothing that
-- reads them breaks, and gains the whole geometry block underneath.
create or replace function public._product_card(m "MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select x.b || jsonb_build_object(
    'style', x.st,
    'pack_chip', jsonb_build_object('label', x.pc, 'has', x.pc <> ''),
    'sub_line', public.card_sub_line(m) || jsonb_build_object('fg', x.st->>'sub_fg'),
    'placeholder', jsonb_build_object('kind', public.card_placeholder_kind(m.pack_qty, m.pack_type)),
    -- CMD #2167 — the card's whole geometry, live in the payload.
    'layout', x.ly || jsonb_build_object(
      'text_lines', coalesce((select (value #>> '{}')::int from public.app_settings where key = 'card.text_lines'), 3),
      'name_max_lines', coalesce((x.ly->>'name_lines')::int, 2)),
    'show', x.sh,
    'layout_screens', x.sc,
    'price', coalesce(x.b->'price', '{}'::jsonb) || jsonb_build_object('mrp_struck', true, 'mrp_fg', x.st->>'mrp_fg'),
    -- CMD #2160 — Product card v6.
    'v6', jsonb_build_object(
      'image_pct', coalesce((x.ly->>'image_pct')::int, (x.v6->>'image_pct')::int, 92),
      'scheme', public.card_scheme_short(m, p_pricing),
      'unavail_chip', jsonb_build_object(
        'has', not coalesce((x.b#>>'{availability,is_available}')::boolean, false),
        'label', coalesce((select value from storefront_ui_label where key = 'card_chip_unavailable'), ''),
        'bg', coalesce(x.v6->>'unavail_bg', '#FEE2E2'),
        'fg', coalesce(x.v6->>'unavail_fg', '#991B1B')),
      'notify_pill', jsonb_build_object(
        'bg', coalesce(x.v6->>'notify_bg', '#DC2626'),
        'fg', coalesce(x.v6->>'notify_fg', '#FFFFFF'))))
  from (select public._product_card_base(m, p_pricing, p_avail, p_qty, p_notified) b,
               public.card_pack_chip(m.pack_qty, m.pack_type) pc,
               public.card_style() st,
               public.card_layout() ly,
               public.card_show() sh,
               public.card_layout_screens() sc,
               coalesce((select value from public.app_settings where key = 'card.v6'), '{}'::jsonb) v6
        offset 0) x   -- CMD #2145: evaluate _product_card_base once, not per use of x.b
$function$;

-- ── 4. the cart's "You may also like" sends FULL cards ────────────────────
-- It was building its own little item object (name / pack / image / pricing),
-- which is why that rail could never be the storefront card: no `card` block,
-- no wish heart, no v6 geometry. It now ranks exactly as before and hands the
-- ids to _sf_cards(), the same builder the home feed and the grid read, and
-- ships them as `cards` (with `items` kept as the same array so an older app
-- build renders the rail rather than nothing).
create or replace function public.cart_also_like_block(
  p_zone_id     smallint,
  p_cart_ids    bigint[],
  p_exclude_ids bigint[] default '{}'::bigint[])
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ids   bigint[] := coalesce(p_cart_ids, '{}'::bigint[]);
  v_skip  bigint[] := coalesce(p_exclude_ids, '{}'::bigint[]);
  v_zone  smallint;
  v_use   smallint;
  v_max   int := 10;
  v_pick  bigint[] := '{}'::bigint[];
  v_more  bigint[];
  v_cards jsonb := '[]'::jsonb;
begin
  if array_length(v_ids, 1) is null then
    return jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb,
                              'cards', '[]'::jsonb,
                              'empty_note', public._c('cart.also_like_empty'));
  end if;

  v_zone := coalesce(p_zone_id, public._viewer_zone_or_null(), public.my_zone_id());

  if v_zone is not null and exists (
       select 1 from public.product_copurchase
        where product_id = any (v_ids) and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  -- 1 — the evidence: what pharmacies actually bought with this basket.
  select coalesce(array_agg(s.id order by s.support desc, s.id), '{}'::bigint[])
    into v_pick
  from (
    select m.id, sum(c.support)::int as support
      from public.product_copurchase c
      join public."MEDICINE" m on m.id = c.companion_id
     where c.product_id = any (v_ids)
       and c.zone_id = v_use
       and not (c.companion_id = any (v_ids))
       and not (c.companion_id = any (v_skip))
       and m.buyable is true
     group by m.id
     order by 2 desc, 1
     limit v_max
  ) s;

  -- 2 — the fallback: the widely-stocked buyable catalogue, minus this basket
  -- and minus everything the wishlist rail above already drew.
  if coalesce(array_length(v_pick, 1), 0) < v_max then
    select coalesce(array_agg(s.id order by s.ord), '{}'::bigint[]) into v_more
    from (
      select m.id, row_number() over (order by m.sales_count desc nulls last, m.id) as ord
        from public."MEDICINE" m
       where m.buyable is true
         and not (m.id = any (v_ids))
         and not (m.id = any (v_skip))
         and not (m.id = any (coalesce(v_pick, '{}'::bigint[])))
       order by m.sales_count desc nulls last, m.id
       limit greatest(v_max - coalesce(array_length(v_pick, 1), 0), 0)
    ) s;
    v_pick := v_pick || coalesce(v_more, '{}'::bigint[]);
  end if;

  -- 3 — ONE card builder for the whole app. Same block the grid reads.
  v_cards := case when coalesce(array_length(v_pick, 1), 0) > 0
                  then public._sf_cards(v_pick)
                  else '[]'::jsonb end;

  return jsonb_build_object(
    'has',        jsonb_array_length(v_cards) > 0,
    'title',      coalesce((select value from public.storefront_ui_label
                             where key = 'cart_also_like_title'), ''),
    'empty_note', public._c('cart.also_like_empty'),
    'zone_id',    v_use,
    'cards',      v_cards,
    'items',      v_cards);
end
$function$;

revoke all on function public.cart_also_like_block(smallint, bigint[], bigint[]) from public;
revoke all on function public.cart_also_like_block(smallint, bigint[], bigint[]) from anon;
grant execute on function public.cart_also_like_block(smallint, bigint[], bigint[]) to authenticated, service_role;
