-- CMD #1903 (follow-up, Om live) — "Other packs" lists the OTHER packs.
--
-- The block shipped as a switch: the pack being viewed was in the list, marked
-- `selected`, and drawn as a filled green chip among grey ones. Om's call is
-- that a row on the product page should offer the packs you are NOT on — the
-- page itself already says which pack you are looking at, in its title.
--
-- So the anchor is dropped from `items`, `has` becomes "there is at least one
-- other pack" rather than "the family has more than one member", and the
-- `selected` key is gone from the payload entirely. An app build older than
-- this one reads no `selected`, renders every chip unselected, and is correct.
--
-- Idempotent: CREATE OR REPLACE of one function; the REVOKEs are repeated
-- because a REPLACE resets nothing but they cost nothing to re-assert.

CREATE OR REPLACE FUNCTION public.pdp_other_packs(p_product_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH me AS (
    SELECT m.id, m.marketer_canonical AS mc, public._brand_root(m.product_name) AS root
      FROM public."MEDICINE" m
     WHERE m.id = p_product_id
       AND nullif(btrim(coalesce(m.product_name, '')), '') IS NOT NULL
  ),
  me2 AS (SELECT * FROM me WHERE coalesce(root, '') <> ''),
  sib AS (
    SELECT s.id, s.sales_count,
           coalesce(public._cat_variant_rest(s.product_name, me2.root),
                    public.sf_pack_type_label(s.pack_type)) AS label
      FROM me2
      JOIN LATERAL (
        SELECT s2.id, s2.product_name, s2.pack_type, s2.sales_count, s2.buyable
          FROM public."MEDICINE" s2
         WHERE public._norm_name(s2.product_name) OPERATOR(pg_catalog.~>=~) me2.root
           AND public._norm_name(s2.product_name) OPERATOR(pg_catalog.~<~)
               (left(me2.root, length(me2.root) - 1) || chr(ascii(right(me2.root, 1)) + 1))
           AND s2.marketer_canonical IS NOT DISTINCT FROM me2.mc
           AND public._brand_root(s2.product_name) = me2.root
         LIMIT 80) s ON true
     WHERE lower(coalesce(s.buyable::text, '')) IN ('true', 't')
        OR s.id = p_product_id
  ),
  pick AS (
    SELECT DISTINCT ON (label) id, label, sales_count
      FROM sib
     WHERE nullif(btrim(label), '') IS NOT NULL
     ORDER BY label, (id = p_product_id) DESC, sales_count DESC NULLS LAST, id
  ),
  -- CMD #1903 (Om, live) — the pack you are LOOKING AT is not one of the
  -- "other packs". `pick` is DISTINCT ON (label) and prefers the anchor for
  -- its own label, so dropping the anchor row here drops that label with it
  -- and no other row can carry it: on DapaBiso 10/2.5 the block is exactly
  -- "10/1.25 Tablet" and "10/5 Tablet".
  top AS (
    SELECT id, label,
           row_number() over (ORDER BY label) AS rn,
           count(*) over () AS n
      FROM pick
     WHERE id <> p_product_id
  )
  -- `has` is now "there is at least one OTHER pack", and no item carries a
  -- `selected` flag: every chip in the row is the same outlined pill, because
  -- the row lists where you can go, not where you are.
  SELECT jsonb_build_object(
    'has',   coalesce((SELECT max(n) FROM top), 0) >= 1,
    'title', public.uic('catalogue.variants_title', 'Other packs'),
    'items', coalesce((SELECT jsonb_agg(jsonb_build_object(
                                'product_id', id,
                                'label',      label) ORDER BY rn)
                         FROM top WHERE rn <= 8), '[]'::jsonb));
$function$;

REVOKE ALL ON FUNCTION public.pdp_other_packs(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pdp_other_packs(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.pdp_other_packs(bigint) FROM authenticated;
