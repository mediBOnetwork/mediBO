-- CMD #1903e — the search header is a TOTAL, and it was a page size.
--
-- Spec item 5 asks for a small grey "126 results for monticope". What #1903d
-- actually shipped was `page_offset + rows-on-this-page`:
--
--     monticope, first page   ->  "60 results for monticope"   (119 match)
--     monticope, page 2       ->  "119 results for monticope"
--     azithral, offset 5000   ->  "5000 results for azithral"  (0 rows)
--
-- So the one line above the list undercounted every first page — the only page
-- most buyers see — and printed the offset as a result count past the end.
-- Hostile QA on #1903 caught it against live.
--
-- The fix ranks ONCE and counts what it ranked:
--
--   ranked   search_medicines_priority with NO inner LIMIT (offset 0), numbered
--   tot      count(*) over that -> the true total, and the header
--   win      the page window, rn > page_offset .. page_offset + n
--   item     the EXPENSIVE per-row enrichment, still only on the window
--
-- This costs no second ranking pass. search_medicines_priority already
-- materialises every kept row before its own LIMIT — `kept` computes
-- medicine_zone_standby per row and `deduped` runs a window function over all
-- of it — so dropping the inner LIMIT adds row transport and nothing else. The
-- 2.2 s that #1903d removed was storefront_cta + storefront_effective_count +
-- storefront_pricing per row, and those still run on 60 rows, never on 119 or
-- 1800. The anon role's 3 s budget (standing lesson 159) is preserved; the
-- candidate set is hard-capped at ~1800 ids by construction, so the count can
-- never walk the catalogue.
--
-- has_more / next_offset now come from the total instead of a +1 probe row,
-- which also fixes "Load more" offering itself one page past the end.
--
-- Idempotent: a single CREATE OR REPLACE FUNCTION.

CREATE OR REPLACE FUNCTION public.storefront_search_page(
  search_term text,
  category_filter text DEFAULT 'All'::text,
  page_offset integer DEFAULT 0,
  page_limit integer DEFAULT NULL::integer,
  p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH cfg AS (
    SELECT
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'search_initial_limit'),
               (SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_initial_limit'), 60) AS initial_limit,
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'search_more_limit'),
               (SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_more_limit'), 60) AS more_limit
  ),
  lim AS (
    SELECT greatest(coalesce(nullif(page_limit, 0), (SELECT initial_limit FROM cfg)), 1) AS n
  ),
  off AS (SELECT greatest(coalesce(page_offset, 0), 0) AS o),
  disc AS (SELECT public.my_cart_discount_pct() AS pct),
  -- ONE ranking pass, unwindowed. row_number() over () keeps the function's
  -- own ORDER BY — the same pattern #1903d's probe used.
  ranked AS MATERIALIZED (
    SELECT s.*, row_number() over () AS rn
      FROM public.search_medicines_priority(
             search_term, category_filter, 0, NULL, p_zone) s
  ),
  tot AS (SELECT count(*)::int AS total FROM ranked),
  win AS (
    SELECT * FROM ranked
     WHERE rn >  (SELECT o FROM off)
       AND rn <= (SELECT o FROM off) + (SELECT n FROM lim)
  ),
  n AS (SELECT count(*)::int AS returned FROM win),
  item AS (
    SELECT r.rn, r.id,
           (to_jsonb(r) - 'rn')
             || jsonb_build_object('availability',
                  public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count),
                                        true))
             || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
             || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
             || jsonb_build_object('pricing', public.storefront_pricing(
                  nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
                  (SELECT pct FROM disc), r.id))
             AS obj
      FROM win r JOIN "MEDICINE" src ON src.id = r.id
  )
  SELECT jsonb_build_object(
    'status','ok',
    'search_term', search_term,
    'category', category_filter,
    'page_offset', (SELECT o FROM off),
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'result_count', (SELECT returned FROM n),
    -- CMD #1903e — the header line, and it is the TOTAL: the number of
    -- products that match, not the number fetched so far. Small, grey, and
    -- the only thing above the list.
    'result_total', (SELECT total FROM tot),
    'showing_label', (SELECT total::text FROM tot)
                     || ' result' || (SELECT CASE WHEN total = 1 THEN '' ELSE 's' END FROM tot)
                     || ' for ' || btrim(coalesce(search_term, '')),
    'empty_label', 'No products match "' || coalesce(search_term, '') || '"',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', (SELECT o FROM off) + (SELECT returned FROM n),
    'has_more', (SELECT o FROM off) + (SELECT returned FROM n) < (SELECT total FROM tot),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_results'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'search_end_label'), ''),
    'zone_switch', public.catalogue_zone_switch(coalesce(p_zone, true)),
    'items', coalesce((
      SELECT jsonb_agg(i.obj ORDER BY i.rn) FROM item i), '[]'::jsonb)
  );
$function$;
