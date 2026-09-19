-- CMD #2081 — the View-cart pill takes the Blinkit shape.
--
-- The widget draws two STACKED lines, up to two overlapping thumbnails and a
-- "+N" bubble when the basket holds more than the pill can show. Every one of
-- those is a string the BACKEND writes: the pill's Dart never counts, never
-- pluralises and never builds "+2" out of arithmetic it did itself.
--
-- Idempotent: labels upsert, the function is CREATE OR REPLACE.

insert into public.storefront_ui_label (key, value, note) values
  ('cart_pill_more', '+{n}',
   'CMD #2081 — the overflow bubble on the cart pill. {n} = items beyond the thumbnails shown.'),
  ('cart_pill_a11y', '{cta}, {items}',
   'CMD #2081 — screen-reader label for the whole cart pill.')
on conflict (key) do update
  set value = excluded.value,
      note  = excluded.note,
      updated_at = now()
  where public.storefront_ui_label.value is null
     or btrim(public.storefront_ui_label.value) = '';

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
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_more'),''),
               '+{n}') as more,
      coalesce(nullif((select value from storefront_ui_label where key='cart_pill_a11y'),''),
               '{cta}, {items}') as a11y
  ),
  -- The cart arrives oldest-first (cart_state orders by cart_items.id), so the
  -- LAST two rows are the two most recently added. They are re-emitted
  -- oldest-of-the-two first: that is the draw order the pill stacks them in,
  -- which puts the newest item on TOP of the overlap.
  picked as (
    select it, ord
      from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality as t(it, ord)
     order by ord desc
     limit 2
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
      lbl.more                                               as more_tpl,
      lbl.a11y                                               as a11y_tpl
      from lbl, thumbs
  )
  select jsonb_build_object(
    'show',        (n_lines > 0),
    -- CMD #2081 — the tap target's stable name, so a journey and a test name
    -- the same thing the app names.
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
    -- "+N" only exists when the basket really holds more than the pill shows.
    'has_more',    (n_lines > n_thumbs),
    'more_label',  case when n_lines > n_thumbs
                        then replace(more_tpl, '{n}', (n_lines - n_thumbs)::text)
                        else '' end,
    'a11y',        replace(replace(a11y_tpl, '{cta}', cta), '{items}', items_label),
    -- kept for back-compat with anything still reading a single image
    'image',       coalesce(arr->-1->>'image_url', '')
  )
  from computed;
$function$;

revoke all on function public.cart_pill_block(jsonb, integer) from public;
grant execute on function public.cart_pill_block(jsonb, integer) to anon, authenticated, service_role;
