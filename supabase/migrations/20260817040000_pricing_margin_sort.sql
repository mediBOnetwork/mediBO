-- CHANGE #174 (part 2) — sort the storefront by margin, where margin exists.
--
-- The pricing engine shipped in 20260816160000_pricing_margin_engine.sql. The
-- one acceptance bullet it left open was "Sort/filter by margin where
-- available". This adds it, and keeps the same promise the rest of #174 makes:
-- a control that has nothing real behind it does NOT appear. No empty sort
-- chip, no "Highest margin" list that is silently ordered by something else.
--
-- Three rules the design turns on:
--   1. The chips are a PAYLOAD, not a Dart list. `storefront_page` now carries
--      `sort_options[]`; the grid prints them and sends back the key it was
--      given. Renaming "Highest margin" is an UPDATE, never a deploy.
--   2. The margin lane is its OWN small query. Sorting 562k MEDICINE rows by a
--      computed margin would be the scalar-helper-scan anti-pattern from the
--      latency lessons; instead we page over medicine_pricing (partial index
--      idx_medicine_pricing_ready), which is exactly the set that HAS a margin.
--      "Sort by margin" and "filter to products with a margin" are the same
--      set here, which is what "where available" means.
--   3. Same viewer gate as the margin itself. `_pricing_block` only returns
--      display_mode='full' to an approved customer or an admin, so anyone else
--      gets no sort_options at all — there is no chip that would sort a list
--      by numbers the viewer is not shown.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Copy. The chip words live in the same table every other storefront label
--    does.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label(key, value, note) values
  ('sort_default_label', 'Popular',
   'CHANGE #174 — storefront sort chip: the normal ranked feed'),
  ('sort_margin_label',  'Highest margin',
   'CHANGE #174 — storefront sort chip: priced products, best margin first'),
  ('sort_margin_showing', 'Showing priced products, highest margin first',
   'CHANGE #174 — the showing line while the margin sort is active'),
  ('sort_margin_empty',  'No product has trade pricing yet.',
   'CHANGE #174 — margin sort with zero priced products (defensive: the chip is hidden in that case)')
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The options themselves. Returns [] — an ABSENT control, not a disabled
--    one — when this viewer would see no margin anyway, or when no buyable
--    product is priced yet. Coverage starts near zero by design (#174: the
--    data arrives bill by bill), so "no chips" is the normal first state.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.storefront_sort_options(p_active text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_default text := coalesce((select value from storefront_ui_label
                                where key = 'sort_default_label'), 'Popular');
  v_margin  text := coalesce((select value from storefront_ui_label
                                where key = 'sort_margin_label'), 'Highest margin');
  v_active  text := case when p_active = 'margin' then 'margin' else 'default' end;
begin
  -- The margin is not shown to this viewer → the chip that orders by it is not
  -- offered either. Same predicate as _pricing_block's full-mode gate.
  if not (public.viewer_is_approved_customer()
          or public.get_my_role() = any (array['admin','super_admin'])) then
    return '[]'::jsonb;
  end if;

  -- Nothing priced yet → no chips at all. The storefront looks exactly as it
  -- did before #174 until the first bill lands.
  if not exists (
    select 1 from public.medicine_pricing mp
      join "MEDICINE" m on m.id = mp.product_id
     where mp.pricing_ready
       and lower(coalesce(m.buyable::text, '')) in ('true', 't')) then
    return '[]'::jsonb;
  end if;

  return jsonb_build_array(
    jsonb_build_object('key', 'default', 'label', v_default,
                       'active', v_active = 'default'),
    jsonb_build_object('key', 'margin',  'label', v_margin,
                       'active', v_active = 'margin'));
end;
$$;

grant execute on function public.storefront_sort_options(text) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The margin lane.
--
--    Item shape is byte-for-byte what `storefront_page` returns, because the
--    grid parses one shape (Product.fromMap reads the raw MEDICINE column
--    names). That includes get_storefront_feed's pack_* remapping and its
--    admin-only supplier_label gate — copied deliberately, so a card does not
--    change appearance just because it was reached through a different sort.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.storefront_margin_page(
  p_offset integer default 0, p_limit integer default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_initial int := coalesce((select (value #>> '{}')::int from app_settings
                               where key = 'storefront_initial_limit'), 250);
  v_more    int := coalesce((select (value #>> '{}')::int from app_settings
                               where key = 'storefront_more_limit'), 100);
  v_lim     int := greatest(coalesce(nullif(p_limit, 0), v_initial), 1);
  v_off     int := greatest(coalesce(p_offset, 0), 0);
  v_disc    numeric := public.my_cart_discount_pct();
  v_is_admin boolean := public.get_my_role() = any (array['admin','super_admin']);
  v_total   bigint;
  v_items   jsonb;
  v_n       int;
begin
  -- A viewer with no margin has no margin lane. Fall back to the normal feed
  -- rather than erroring: the client asked for a sort it should never have
  -- been offered, and the honest answer is the default page.
  if not (public.viewer_is_approved_customer() or v_is_admin) then
    return public.storefront_page('All', v_off, v_lim);
  end if;

  with ready as (
    select mp.product_id,
           ((public._pricing_compute(
               nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
               mp.ptr, mp.gst_pct, v_disc, mp.scheme_buy_qty, mp.scheme_free_qty)
            ) ->> 'margin_pct')::numeric as margin_pct
      from public.medicine_pricing mp
      join "MEDICINE" m on m.id = mp.product_id
     where mp.pricing_ready
       and lower(coalesce(m.buyable::text, '')) in ('true', 't'))
  select count(*) into v_total from ready;

  with ready as (
    select mp.product_id,
           ((public._pricing_compute(
               nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
               mp.ptr, mp.gst_pct, v_disc, mp.scheme_buy_qty, mp.scheme_free_qty)
            ) ->> 'margin_pct')::numeric as margin_pct
      from public.medicine_pricing mp
      join "MEDICINE" m on m.id = mp.product_id
     where mp.pricing_ready
       and lower(coalesce(m.buyable::text, '')) in ('true', 't')),
  page as (
    select r.product_id, r.margin_pct
      from ready r
     order by r.margin_pct desc nulls last, r.product_id
     offset v_off limit v_lim)
  select coalesce(jsonb_agg(
           to_jsonb(m)
           -- get_storefront_feed's pack_* remapping, verbatim.
           || jsonb_build_object(
                'pack_size', coalesce(nullif(btrim(m.pack_qty), ''),  nullif(btrim(m.pack_size), '')),
                'pack_qty',  coalesce(nullif(btrim(m.pack_type), ''), nullif(btrim(m.pack_size), '')),
                'pack_type', coalesce(nullif(btrim(m.pack_qty), ''),  nullif(btrim(m.pack_size), '')))
           -- supplier_label is admin-only in the feed; it stays admin-only here.
           || jsonb_build_object('supplier_label',
                case when v_is_admin then coalesce(m.supplier_label, '') else '' end)
           || jsonb_build_object('availability',
                public.storefront_cta(public.storefront_effective_count(m.id,
                  coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text, ''), '[^0-9]', '', 'g'), '')::int, 0))))
           || jsonb_build_object('gst_percent_resolved',
                coalesce(m.gst_percent, public.gst_rate_for(m.therapeutic_class)))
           || jsonb_build_object('pricing', public.storefront_pricing(
                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                v_disc, m.id))
           order by p.margin_pct desc nulls last, p.product_id), '[]'::jsonb)
    into v_items
    from page p join "MEDICINE" m on m.id = p.product_id;

  v_n := jsonb_array_length(v_items);

  return jsonb_build_object(
    'status',        'ok',
    'category',      'All',
    'sort',          'margin',
    'sort_options',  public.storefront_sort_options('margin'),
    'page_offset',   v_off,
    'page_limit',    v_lim,
    'gated',         public.viewer_is_approved_customer(),
    'showing_label', coalesce((select value from storefront_ui_label
                                 where key = 'sort_margin_showing'), ''),
    'empty_label',   coalesce((select value from storefront_ui_label
                                 where key = 'sort_margin_empty'), ''),
    'total',         v_total,
    'count_label',   to_char(v_total, 'FM9,99,99,999'),
    'initial_limit', v_initial,
    'more_limit',    v_more,
    'next_offset',   v_off + v_n,
    'has_more',      (v_off + v_n) < v_total,
    'more_label',    coalesce((select value from storefront_ui_label
                                 where key = 'load_more_products'), ''),
    'end_label',     coalesce((select value from storefront_ui_label
                                 where key = 'feed_end_label'), ''),
    'items',         v_items);
end;
$$;

grant execute on function public.storefront_margin_page(integer, integer) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The default lane learns to advertise the chips. Same signature, so no
--    caller changes and the regression baseline sees one payload key added.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.storefront_page(
  category_filter text default 'All'::text,
  page_offset integer default 0,
  page_limit integer default null::integer)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  WITH cfg AS (
    SELECT
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_initial_limit'), 250) AS initial_limit,
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_more_limit'), 100) AS more_limit
  ),
  lim AS (
    SELECT greatest(coalesce(nullif(page_limit, 0), (SELECT initial_limit FROM cfg)), 1) AS n
  ),
  disc AS (SELECT public.my_cart_discount_pct() AS pct),
  rows AS (
    SELECT f.* FROM public.get_storefront_feed(
      category_filter, page_offset, (SELECT n FROM lim)) f
  ),
  n AS (SELECT count(*)::int AS returned FROM rows),
  t AS (SELECT public.get_storefront_count(category_filter)::bigint AS total)
  SELECT jsonb_build_object(
    'status','ok',
    'category', category_filter,
    -- CHANGE #174 part 2 — the sort control, absent until a margin exists.
    'sort', 'default',
    'sort_options', public.storefront_sort_options('default'),
    'page_offset', page_offset,
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'showing_label', (SELECT r.showing_label FROM rows r LIMIT 1),
    'total', (SELECT total FROM t),
    'count_label', to_char((SELECT total FROM t), 'FM9,99,99,999'),
    'banner_count_label', to_char((SELECT total FROM t), 'FM9,99,99,999') || '+ products',
    'show_all_label', 'Show all ' || to_char((SELECT total FROM t), 'FM9,99,99,999') || ' products',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', page_offset + (SELECT returned FROM n),
    'has_more', (page_offset + (SELECT returned FROM n)) < (SELECT total FROM t),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_products'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'feed_end_label'), ''),
    'items', coalesce((
      SELECT jsonb_agg(
        to_jsonb(r)
        || jsonb_build_object('availability', public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count)))
        || jsonb_build_object('gst_percent_resolved',
             coalesce(r.gst_percent, public.gst_rate_for(r.therapeutic_class)))
        || jsonb_build_object('pricing', public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id)))
      FROM rows r), '[]'::jsonb)
  );
$$;
