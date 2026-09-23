-- CMD #2169 — the wishlist heart is a heart, and nothing else.
--
-- The white disc under it (its fill, its border and its shadow) is gone, so
-- the only thing left to draw is the glyph: its size, the invisible box that
-- catches the finger, and the two colours. All four are BACKEND numbers now —
-- `card_layout()` gains wish_icon / wish_tap, and the colours were already in
-- `card_style()` as wish_fg / wish_saved_fg. Changing any of them is an
-- UPDATE to app_settings 'card.layout' / 'card.style', never a deploy.
--
-- wish_tap is 44, not the mock's 40: the box is invisible either way and the
-- phone-viewport rule keeps every tap target at 44dp or more. The heart the
-- eye sees is wish_icon (24dp), which is the mock's size exactly.
--
-- The product page header draws the SAME heart, so it needs the same two
-- colours: `product_detail_v2` now carries `card_style` verbatim rather than
-- the page inventing a grey and a red of its own.

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
           "shadow_dy":1,"shadow_alpha":0.06,
           "wish_icon":24,"wish_tap":44}'::jsonb
         || coalesce((select value from public.app_settings where key = 'card.layout'), '{}'::jsonb)
$function$;

-- The two heart colours, in case this database predates the row that carries
-- them. Idempotent: an existing card.style keeps every key it already has and
-- only gains the two that are missing.
insert into public.app_settings (key, value)
values ('card.style', jsonb_build_object('wish_fg', '#4B5563', 'wish_saved_fg', '#E53935'))
on conflict (key) do update
  set value = jsonb_build_object('wish_fg', '#4B5563', 'wish_saved_fg', '#E53935')
              || public.app_settings.value;

create or replace function public.product_detail_v2(p_product_id bigint, p_pincode text default null::text)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  v := public.product_detail(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  return v || jsonb_build_object(
    -- CMD #2040 — the second salt rail left the page; ONE rail remains.
    'substitutes',      jsonb_build_object('has', false),
    'delivery_promise', public.delivery_promise(p_pincode),
    -- has:false below the review floor, so the header shows nothing at all
    -- rather than a 5.0 that one customer wrote.
    'rating',           public.product_rating_summary(p_product_id),
    -- CMD #2169 — the header's heart is the card's heart, so it reads the
    -- card's own colours instead of picking a grey and a red in Dart.
    'card_style',       public.card_style(),
    'card_layout',      public.card_layout(),
    -- The compare checkbox on a same-salt row needs a label, and the label is
    -- the backend's. The tray's contents are the only thing the app owns.
    'compare',          jsonb_build_object(
      'add_label', coalesce((select value from storefront_ui_label where key='cmp_add'), ''),
      'cta_label', coalesce((select value from storefront_ui_label where key='cmp_cta'), ''),
      'max',       3,
      'open_label', coalesce((select value from storefront_ui_label where key='cmp_open'), '')));
end $function$;
