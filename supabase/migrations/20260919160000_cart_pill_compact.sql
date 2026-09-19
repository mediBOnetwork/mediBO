-- CMD #2089 — the View-cart pill gets smaller, greener, and loses the "+N".
--
-- WHAT CHANGED
--   1. No overflow bubble. "N items" on the second line already answers "how
--      many", so a second count in a circle was the same fact twice. The pill
--      now shows at most `cart_pill_ui_max_thumbs` overlapping thumbnails and
--      nothing else; `has_more` is emitted false and `more_label` empty, so
--      the widget draws no bubble and no Dart had to be taught to stop.
--   2. Smaller: 48 px tall and 55% of the screen, both down from #2081's
--      64 / 60%. Thumbnail, chevron circle and paddings scale with it.
--   3. The mediBO brand green — the SAME token the primary buttons use
--      (`design.colors.brand`) — instead of `brandDark`. The pill names the
--      TOKEN, never a hex: `ui_design_set` still recolours it with the rest of
--      the app and the widget holds no colour literal.
--
-- WHY IT IS CONFIG AND NOT CONSTANTS
-- Spec item 5: "Colour, height and labels come from backend ui config."
-- Every number and the colour token live in `storefront_ui_label` beside the
-- words, so re-proportioning the pill is an UPDATE, not a deploy. The widget
-- keeps its own constants ONLY as the value it draws before the first payload
-- arrives — a pill that is briefly 48 px is right; a pill that is briefly
-- invisible is not.
--
-- Idempotent: labels upsert, the function is CREATE OR REPLACE.

-- ── the pill's ui config, beside its words ──────────────────────────────────
-- Inserted with the value we want NOW and updated on re-run, because these are
-- this change's own geometry rather than copy someone may have edited: #2081's
-- guard (only fill a blank) is right for wording and wrong for a size this
-- migration exists to change.
insert into public.storefront_ui_label (key, value, note) values
  ('cart_pill_ui_color_token', 'brand',
   'CMD #2089 — which design.colors token paints the pill. brand = the primary green the Place-order button uses. Any DsColors key works (brand, brandDark, success, ...).'),
  ('cart_pill_ui_height', '48',
   'CMD #2089 — the pill''s height in logical px. Was 64 in #2081.'),
  ('cart_pill_ui_width_pct', '55',
   'CMD #2089 — the pill''s width as a PERCENT of the screen. Was 60 in #2081.'),
  ('cart_pill_ui_min_width', '190',
   'CMD #2089 — the pill never renders narrower than this, so a 320px phone still fits two thumbs, two lines and the chevron.'),
  ('cart_pill_ui_max_thumbs', '2',
   'CMD #2089 — how many overlapping thumbnails the pill shows. The rest are not counted in a bubble any more.'),
  ('cart_pill_ui_thumb', '30',
   'CMD #2089 — thumbnail diameter in logical px, scaled for the 48px pill.'),
  ('cart_pill_ui_thumb_overlap', '11',
   'CMD #2089 — how far each further thumbnail is pushed right of the one before it.'),
  ('cart_pill_ui_chevron_box', '26',
   'CMD #2089 — the chevron''s circle diameter.'),
  ('cart_pill_ui_chevron', '18',
   'CMD #2089 — the chevron glyph size inside that circle.'),
  ('cart_pill_ui_pad_left', '8',
   'CMD #2089 — inset before the thumbnails.'),
  ('cart_pill_ui_pad_right', '10',
   'CMD #2089 — inset after the chevron.')
on conflict (key) do update
  set value = excluded.value,
      note  = excluded.note,
      updated_at = now();

create or replace function public.cart_pill_block(p_items jsonb, p_lines integer)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with lbl as (
    select
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_items_one'),''),
               '1 item')  as one,
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_items_many'),''),
               '{n} items') as many,
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_cta'),''),
               'View cart') as cta,
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_a11y'),''),
               '{cta}, {items}') as a11y
  ),
  -- CMD #2089 — the geometry, read the same way the words are. Every one of
  -- these is a NUMBER in a text column, so a bad edit falls back to this
  -- change's own value rather than rendering a pill of height NULL.
  ui as (
    select
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_ui_color_token'),''),
               'brand')                                                    as color_token,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_height'), 48)            as height,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_width_pct'), 55)         as width_pct,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_min_width'), 190)        as min_width,
      greatest(coalesce((select nullif(btrim(value),'')::int from storefront_ui_label where key='cart_pill_ui_max_thumbs'), 2), 0) as max_thumbs,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_thumb'), 30)             as thumb,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_thumb_overlap'), 11)     as thumb_overlap,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_chevron_box'), 26)       as chevron_box,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_chevron'), 18)           as chevron,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_pad_left'), 8)           as pad_left,
      coalesce((select nullif(btrim(value),'')::numeric from storefront_ui_label where key='cart_pill_ui_pad_right'), 10)         as pad_right
  ),
  -- The cart arrives oldest-first (cart_state orders by cart_items.id), so the
  -- LAST `max_thumbs` rows are the most recently added. They are re-emitted
  -- oldest-of-those first: that is the draw order the pill stacks them in,
  -- which puts the newest item on TOP of the overlap.
  picked as (
    select it, ord
      from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality as t(it, ord),
           ui
     order by ord desc
     limit (select max_thumbs from ui)
  ),
  thumbs as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', coalesce(it->>'product_id',''),
             'name',       coalesce(it->>'product_name',''),
             'image_url',  coalesce(it->>'image_url',''),
             'has_image',  (coalesce(btrim(it->>'image_url'),'') <> '')
           ) order by ord), '[]'::jsonb) as arr
      from picked
  ),
  computed as (
    select
      greatest(coalesce(p_lines,0), 0)                       as n_lines,
      jsonb_array_length(thumbs.arr)                         as n_thumbs,
      thumbs.arr                                             as arr,
      case when coalesce(p_lines,0) = 1 then lbl.one
           else replace(lbl.many, '{n}', greatest(coalesce(p_lines,0),0)::text) end as items_label,
      lbl.cta                                                as cta,
      lbl.a11y                                               as a11y_tpl,
      ui.*
      from lbl, thumbs, ui
  )
  select jsonb_build_object(
    'show',        (n_lines > 0),
    -- The tap target's stable name, so a journey and a test name the same
    -- thing the app names.
    'identifier',  'cart_pill',
    -- The two stacked lines, in draw order. The widget renders lines[0] as the
    -- strong line and lines[1] beneath it; it never decides what they say.
    'lines', jsonb_build_array(
      jsonb_build_object('key','cta',   'text', cta),
      jsonb_build_object('key','count', 'text', items_label)
    ),
    'items_label', items_label,
    'cta',         cta,
    'thumbs',      arr,
    'thumb_count', n_thumbs,
    -- CMD #2089 — THE BUBBLE IS GONE. The second line already says "N items",
    -- so the circle was the same number twice and the widest thing in a pill
    -- this change is making narrower. Both keys stay in the payload with
    -- their empty answers so nothing reading the old shape breaks.
    'has_more',    false,
    'more_label',  '',
    'a11y',        replace(replace(a11y_tpl, '{cta}', cta), '{items}', items_label),
    -- CMD #2089 — the geometry and the colour TOKEN, so the widget draws a
    -- shape it was handed instead of one it was compiled with.
    'ui', jsonb_build_object(
      'color_token',   color_token,
      'height',        height,
      'width_factor',  round(width_pct / 100.0, 4),
      'min_width',     min_width,
      'max_thumbs',    max_thumbs,
      'thumb',         thumb,
      'thumb_overlap', thumb_overlap,
      'chevron_box',   chevron_box,
      'chevron',       chevron,
      'pad_left',      pad_left,
      'pad_right',     pad_right
    ),
    -- kept for back-compat with anything still reading a single image
    'image',       coalesce(arr->-1->>'image_url', '')
  )
  from computed;
$function$;

revoke all on function public.cart_pill_block(jsonb, integer) from public;
grant execute on function public.cart_pill_block(jsonb, integer) to anon, authenticated, service_role;
