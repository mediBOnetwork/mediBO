-- CHANGE #287 — the storefront card's two pack strings swap places, and both
-- arrive from the backend already rendered.
--
-- The problem Om saw: the ADD row prints the pack QUANTITY beside a 72px add
-- pill, so "10 tablet er…" / "10 capsules" is ellipsised on every card. The
-- one-word container type ("Strip", "Vial") always fits that gap; the long
-- quantity sentence belongs on the full-width chip above the product name.
--
-- Backend, not layout, because the card must not pick between three raw
-- columns. Until now `Product.fromMap` walked pack_qty → pack_size → pack_type
-- in Dart, and `storefront_margin_page` even RE-KEYED those three columns so
-- that client-side chain would land on the string it wanted. Both are the app
-- deciding wording. Two explicit keys end it:
--
--   pack_qty_label  — MEDICINE.pack_qty VERBATIM ("10.0 tablets in 1 strip").
--                     Om's call on this command: the chip shows the stored
--                     sentence, not the shortened badge. Empty when the
--                     column is null (most `Piece` rows) — the card then draws
--                     no chip at all rather than an invented one.
--   pack_type_label — MEDICINE.pack_type verbatim, one word. Empty when the
--                     column is null; pack_size is deliberately NOT a fallback
--                     because it is a sentence ("Vial of 1 Injection") and
--                     would re-create the truncation this change removes.
--
-- `sf_pack_badge()` stays exactly as it is — the product page and the older
-- `pack_label` key still use it. Nothing is dropped.
--
-- Idempotent: create-or-replace only.

-- ── 1. the two label functions ───────────────────────────────────────────────
create or replace function public.sf_pack_qty_label(p_pack_qty text)
returns text
language sql
immutable
as $function$
  select coalesce(nullif(btrim(coalesce(p_pack_qty, '')), ''), '');
$function$;

comment on function public.sf_pack_qty_label(text) is
  'CHANGE #287 — the pack quantity chip above the product name: MEDICINE.pack_qty verbatim, '''' when absent (card hides the chip).';

create or replace function public.sf_pack_type_label(p_pack_type text)
returns text
language sql
immutable
as $function$
  select coalesce(nullif(btrim(coalesce(p_pack_type, '')), ''), '');
$function$;

comment on function public.sf_pack_type_label(text) is
  'CHANGE #287 — the one word beside the ADD pill: MEDICINE.pack_type verbatim, '''' when absent. Never falls back to pack_size, which is a sentence.';

grant execute on function public.sf_pack_qty_label(text)  to anon, authenticated, service_role;
grant execute on function public.sf_pack_type_label(text) to anon, authenticated, service_role;

-- ── 2. the shared card builder (home rails, home "more", company page,
--       back-in-stock strip) ──────────────────────────────────────────────────
create or replace function public._sf_cards(p_ids bigint[])
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'pack_qty_display', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_size_display', coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),'')),
    'pack_type', m.pack_type,
    'pack_qty', m.pack_qty,
    'pack_size', m.pack_size,
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false) then 'Scheme available' else '' end,
    'availability', public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0))),
    'pricing', public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id),
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t')
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  where lower(coalesce(m.buyable::text,'')) in ('true','t');
$function$;

-- ── 3. the category / All grid ───────────────────────────────────────────────
-- The labels read the TRUE catalog columns. `get_storefront_feed` RE-KEYS
-- pack_qty / pack_size / pack_type on the way out (a hack that exists only to
-- steer the old Dart fallback chain), so r.pack_qty is the container type and
-- r.pack_type is the quantity sentence. That base function is shared with
-- admin screens, so it is left alone and this wrapper resolves both labels
-- from "MEDICINE" by primary key. Feed order is pinned by an explicit ordinal
-- so the added join can never reshuffle the page.
create or replace function public.storefront_page(
  category_filter text default 'All'::text,
  page_offset integer default 0,
  page_limit integer default null::integer)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
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
    SELECT f.*, row_number() over () AS _ord FROM public.get_storefront_feed(
      category_filter, page_offset, (SELECT n FROM lim)) f
  ),
  n AS (SELECT count(*)::int AS returned FROM rows),
  t AS (SELECT public.get_storefront_count(category_filter)::bigint AS total)
  SELECT jsonb_build_object(
    'status','ok',
    'category', category_filter,
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
        (to_jsonb(r) - '_ord')
        || jsonb_build_object('availability', public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count)))
        || jsonb_build_object('pack_badge', public.sf_pack_badge(src.pack_qty, src.pack_size, src.pack_type))
        || jsonb_build_object('type_chip', coalesce(nullif(btrim(src.pack_type),''), nullif(btrim(src.pack_size),''), ''))
        || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
        || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
        || jsonb_build_object('gst_percent_resolved',
             coalesce(r.gst_percent, public.gst_rate_for(r.therapeutic_class)))
        || jsonb_build_object('pricing', public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id))
        ORDER BY r._ord)
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id), '[]'::jsonb)
  );
$function$;

-- ── 4. search ────────────────────────────────────────────────────────────────
-- `search_medicines_priority` carries the same column re-keying, so the labels
-- come from "MEDICINE" here too, and rank order is pinned by the probe's rn.
create or replace function public.storefront_search_page(
  search_term text,
  category_filter text default 'All'::text,
  page_offset integer default 0,
  page_limit integer default null::integer)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
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
  probe AS (
    SELECT s.*, row_number() over () AS rn
    FROM public.search_medicines_priority(
           search_term, category_filter, page_offset, (SELECT n FROM lim) + 1) s
  ),
  rows AS (SELECT * FROM probe WHERE rn <= (SELECT n FROM lim)),
  n AS (SELECT count(*)::int AS returned FROM rows)
  SELECT jsonb_build_object(
    'status','ok',
    'search_term', search_term,
    'category', category_filter,
    'page_offset', page_offset,
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'result_count', (SELECT returned FROM n),
    'showing_label', (SELECT (page_offset + returned)::text FROM n)
                     || ' result(s) for "' || search_term || '"',
    'empty_label', 'No products match "' || search_term || '"',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', page_offset + (SELECT returned FROM n),
    'has_more', (SELECT count(*) FROM probe) > (SELECT n FROM lim),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_results'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'search_end_label'), ''),
    'items', coalesce((
      SELECT jsonb_agg(
        (to_jsonb(r) - 'rn')
        || jsonb_build_object('availability', public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count)))
        || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
        || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
        || jsonb_build_object('pricing', public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id))
        ORDER BY r.rn)
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id), '[]'::jsonb)
  );
$function$;

-- ── 5. the margin lane ───────────────────────────────────────────────────────
-- The three re-keyed pack columns are GONE. They existed only to steer the
-- Dart fallback chain (pack_size got the quantity, pack_qty got the type…),
-- which made this RPC's payload disagree with every other card RPC about what
-- `pack_type` means. It now sends the real columns plus the two labels.
create or replace function public.storefront_margin_page(
  p_offset integer default 0,
  p_limit integer default null::integer)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
           || jsonb_build_object(
                'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
                'pack_type_label', public.sf_pack_type_label(m.pack_type))
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
$function$;
