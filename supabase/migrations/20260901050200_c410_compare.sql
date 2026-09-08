-- CMD #410 part 3 — SIDE-BY-SIDE COMPARE.
--
-- The same-salt block (#366) already answers "what else is this salt". This
-- answers the next question a pharmacy actually asks: "of these three, which
-- one do I buy?" — rate, margin, GST, pack, fill rate, company and rating,
-- laid out one column per product.
--
-- The table is composed HERE, not in Dart. product_compare() returns rows in
-- render order, each row already carrying its label and one cell per product,
-- so the app runs a nested loop and prints strings. It does not know that
-- "Rate" is a currency and "Fill rate" is a percentage, and it must not — the
-- moment the app formats a cell, two renderings of one number exist again.
--
-- THE NO-FALSE-NUMBERS RULE (#366) IS THE POINT OF THIS FILE. Every cell is
-- {has, value}: a product with no trade rate has has:false on the rate row and
-- on the margin row, and the app prints the backend's own dash. It never
-- shows 0, never falls back to MRP (MRP is the legal ceiling, not a price we
-- sell at, per the business doc), and never computes a comparison the backend
-- did not make. A rating below the review floor is has:false for the same
-- reason — see product_rating_summary().

insert into public.storefront_ui_label (key, value, note) values
  ('cmp_title',      'Compare',                                    'Compare screen title'),
  ('cmp_note',       'Rate and margin show only where a real trade rate exists.', 'Compare subtitle'),
  ('cmp_empty',      'Pick up to 3 products to compare.',           'Compare empty state'),
  ('cmp_cta',        'Compare',                                    'Opens the compare table'),
  ('cmp_add',        'Compare',                                    'Checkbox label on a card'),
  ('cmp_clear',      'Clear',                                      'Clears the compare tray'),
  ('cmp_remove',     'Remove',                                     'Removes one product from the tray'),
  ('cmp_full',       'You can compare 3 at a time.',               'Toast when a 4th is picked'),
  ('cmp_min',        'Pick one more to compare.',                  'Toast when only 1 is picked'),
  ('cmp_absent',     '—',                                          'Cell with no real value'),
  ('cmp_row_rate',   'Net rate',                                   'Compare row label'),
  ('cmp_row_margin', 'Margin',                                     'Compare row label'),
  ('cmp_row_gst',    'GST',                                        'Compare row label'),
  ('cmp_row_pack',   'Pack',                                       'Compare row label'),
  ('cmp_row_fill',   'Fill rate',                                  'Compare row label'),
  ('cmp_row_company','Company',                                    'Compare row label'),
  ('cmp_row_rating', 'Rating',                                     'Compare row label'),
  ('cmp_row_stock',  'Availability',                               'Compare row label')
on conflict (key) do nothing;

create or replace function public.product_compare(p_ids bigint[])
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_disc  numeric := public.my_cart_discount_pct();
  v_absent text  := coalesce((select value from storefront_ui_label where key='cmp_absent'), '');
  v_ids   bigint[];
  v_cols  jsonb;
  v_rows  jsonb;
begin
  -- At most three, de-duplicated, in the order the customer picked them. The
  -- cap is enforced here as well as in the tray: a hand-made call must not be
  -- able to build a twenty-column table on a 1 GB instance.
  select array_agg(id order by ord) into v_ids
    from (select distinct on (id) id, ord
            from unnest(coalesce(p_ids, '{}'::bigint[])) with ordinality as t(id, ord)
           order by id, ord) d
   where ord <= 3;

  if v_ids is null or array_length(v_ids, 1) is null then
    return jsonb_build_object(
      'ok', true, 'has', false,
      'title', coalesce((select value from storefront_ui_label where key='cmp_title'), ''),
      'note',  coalesce((select value from storefront_ui_label where key='cmp_note'), ''),
      'empty', coalesce((select value from storefront_ui_label where key='cmp_empty'), ''),
      'products', '[]'::jsonb, 'rows', '[]'::jsonb);
  end if;

  -- One pass over the chosen products, as a CTE rather than a temp table:
  -- this function is STABLE (a read the storefront makes on every tray open)
  -- and a STABLE function may not CREATE TABLE. Everything a cell can need is
  -- resolved here, from the SAME helpers the product page and the cards use:
  -- storefront_pricing (rate/margin/GST), product_trust_strip (fill rate),
  -- product_rating_summary (the reviews aggregate), storefront_cta
  -- (availability). No second opinion is computed anywhere below.
  --
  -- Each row is built the same way: a label, then one {has,value} cell per
  -- column, ordered by the position the customer picked. `has:false` is the
  -- ONLY way a cell says "we do not know this" — there is no empty-string
  -- convention for the app to misread as a value.
  with src as (
    select m.id,
           ord.n                                as pos,
           coalesce(m.product_name, '')         as name,
           coalesce(m.marketer, '')             as company,
           coalesce(m.image_url_1, '')          as image,
           coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),''), '') as pack,
           public.storefront_pricing(
             nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
             v_disc, m.id)                      as pricing,
           public.product_trust_strip(m.id, m.cold_chain) as trust,
           public.product_rating_summary(m.id)  as rating,
           public.storefront_cta(public.storefront_effective_count(m.id, m.supplier_count)) as cta
      from unnest(v_ids) with ordinality as ord(pid, n)
      join "MEDICINE" m on m.id = ord.pid
  ), cols as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',      c.id::text,
             'name',    c.name,
             'company', c.company,
             'image',   c.image,
             'pricing', c.pricing) order by c.pos), '[]'::jsonb) as v
      from src c
  ), cells as (
    select 'rate' as key, 1 as ord,
           coalesce((select value from storefront_ui_label where key='cmp_row_rate'), '') as label,
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.pricing->>'has_net')::boolean, false),
             'value', case when coalesce((c.pricing->>'has_net')::boolean, false)
                           then c.pricing->>'net_display' else v_absent end,
             'tone',  'text') order by c.pos) as cells
      from src c
    union all
    select 'margin', 2,
           coalesce((select value from storefront_ui_label where key='cmp_row_margin'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.pricing->>'has_margin')::boolean, false),
             'value', case when coalesce((c.pricing->>'has_margin')::boolean, false)
                           then c.pricing->'margin_chip'->>'label' else v_absent end,
             'tone',  case when coalesce((c.pricing->>'has_margin')::boolean, false)
                           and coalesce((c.pricing->>'margin_pct')::numeric, 0) >= 0
                           then 'success' else 'text' end) order by c.pos)
      from src c
    union all
    select 'gst', 3,
           coalesce((select value from storefront_ui_label where key='cmp_row_gst'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (c.pricing->'gst' is not null and c.pricing->'gst' <> 'null'::jsonb),
             'value', coalesce(c.pricing->'gst'->>'pct_display', v_absent),
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'pack', 4,
           coalesce((select value from storefront_ui_label where key='cmp_row_pack'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (c.pack <> ''),
             'value', case when c.pack <> '' then c.pack else v_absent end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'fill', 5,
           coalesce((select value from storefront_ui_label where key='cmp_row_fill'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.trust->'fill_rate'->>'has')::boolean, false),
             'value', case when coalesce((c.trust->'fill_rate'->>'has')::boolean, false)
                           then c.trust->'fill_rate'->>'label' else v_absent end,
             'tone',  coalesce(c.trust->'fill_rate'->>'tone', 'text')) order by c.pos)
      from src c
    union all
    select 'rating', 6,
           coalesce((select value from storefront_ui_label where key='cmp_row_rating'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   coalesce((c.rating->>'has')::boolean, false),
             'value', case when coalesce((c.rating->>'has')::boolean, false)
                           then (c.rating->>'stars_label') || ' · ' || (c.rating->>'count_label')
                           else coalesce(nullif(c.rating->>'empty',''), v_absent) end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'company', 7,
           coalesce((select value from storefront_ui_label where key='cmp_row_company'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   (c.company <> ''),
             'value', case when c.company <> '' then c.company else v_absent end,
             'tone',  'text') order by c.pos)
      from src c
    union all
    select 'stock', 8,
           coalesce((select value from storefront_ui_label where key='cmp_row_stock'), ''),
           jsonb_agg(jsonb_build_object(
             'has',   true,
             'value', coalesce(c.cta->>'cta_label', v_absent),
             'tone',  case when coalesce((c.cta->>'can_add')::boolean, false)
                           then 'success' else 'warning' end) order by c.pos)
      from src c
  )
  select (select v from cols),
         coalesce((select jsonb_agg(jsonb_build_object('key', key, 'label', label, 'cells', cells)
                                    order by ord) from cells), '[]'::jsonb)
    into v_cols, v_rows;

  return jsonb_build_object(
    'ok',       true,
    'has',      true,
    'title',    coalesce((select value from storefront_ui_label where key='cmp_title'), ''),
    'note',     coalesce((select value from storefront_ui_label where key='cmp_note'), ''),
    'empty',    coalesce((select value from storefront_ui_label where key='cmp_empty'), ''),
    'max',      3,
    'labels', jsonb_build_object(
      'add',    coalesce((select value from storefront_ui_label where key='cmp_add'), ''),
      'cta',    coalesce((select value from storefront_ui_label where key='cmp_cta'), ''),
      'clear',  coalesce((select value from storefront_ui_label where key='cmp_clear'), ''),
      'remove', coalesce((select value from storefront_ui_label where key='cmp_remove'), ''),
      'full',   coalesce((select value from storefront_ui_label where key='cmp_full'), ''),
      'min',    coalesce((select value from storefront_ui_label where key='cmp_min'), '')),
    'products', v_cols,
    'rows',     v_rows);
end $function$;

grant execute on function public.product_compare(bigint[]) to anon, authenticated;
