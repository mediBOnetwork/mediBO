-- CMD #1903 — search results are a flat, ranked product list.
--
-- Searching "monticope" used to answer with brand-FAMILY cards ("Monticope ·
-- 3 variants" and a chip per pack): the pack a pharmacy typed was never a row
-- of its own, and the row that led the list was whichever member of the family
-- happened to have a supplier in the viewer's zone. This change makes the list
-- what it says it is — one row per product, closest match first — and moves
-- the family onto the product page, where "Other packs" is a strip under the
-- price rather than a chip on a card in a list.
--
-- Three things live here:
--   1. search_medicines_priority — the RANKING. Tier leads the order now
--      (exact name, then the same brand's other packs, then similar brands);
--      zone availability breaks ties one step down instead of leading.
--   2. storefront_search_page — the flat payload and its counter line, worded
--      here ("126 results for monticope") because a plural is not the app's to
--      decide. No family fold, no `blocks` key.
--   3. pdp_other_packs + product_detail — the "Other packs" block the product
--      page prints under the price.
--
-- Idempotent: every statement is CREATE OR REPLACE / INSERT … ON CONFLICT.

CREATE OR REPLACE FUNCTION public.search_medicines_priority(search_term text, category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT 20, p_zone boolean DEFAULT true)
 RETURNS TABLE(id bigint, product_name text, salt_composition text, marketer text, therapeutic_class text, image_url_1 text, pack_qty text, pack_size text, pack_type text, mrp text, gst_percent integer, rx_required text, sales_count integer, has_scheme boolean, has_image boolean, buyable boolean, supplier_count integer, supplier_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_clean text; v_all boolean; v_brand text; v_pref text; v_tok text;
  v_toks text[]; v_keep text[]; v_compact text; v_cl int; v_brand_dm text;
  v_co text; v_co_norm text; v_co_tier int := 0;
  v_zone smallint := public._viewer_zone_or_null();   -- CHANGE #678
  -- CHANGE #790 — the #747 zone switch. CMD #1894 removed the Hinglish
  -- mapping that used to sit beside it; v_syn_kind/v_syn_target stay declared
  -- and stay NULL, which is what makes the two syn_* branches below empty.
  v_zfilter smallint := public._cat_zone(coalesce(p_zone, true));
  v_syn_kind text := null; v_syn_target text := null;
  c_forms text[] := array['tab','tablet','tablets','cap','capsule','capsules','inj','injection',
      'syp','syr','syrup','oint','ointment','cream','gel','drop','drops','susp','suspension',
      'sachet','powder','lotion','soln','solution','tube','kit','sol','spray','respules',
      'rotacap','inhaler','er','sr','xr','md','mg','ml','gm','gms','mcg','mgs','the','and','for'];
  c_brandskip text[] := array['tab','tablet','tablets','cap','capsule','capsules','inj','injection',
      'syp','syr','syrup','oint','ointment','cream','gel','drop','drops','susp','suspension',
      'sachet','powder','lotion','soln','solution','tube','kit','sol','spray','respules',
      'rotacap','inhaler','the','and','for','type','types'];
begin
  category_filter := coalesce(nullif(btrim(category_filter),''), 'All');
  v_all := (category_filter = 'All');
  v_clean := public._norm_name(search_term);

  -- CMD #1894 — #790's Hindi/Hinglish expansion is GONE from the query path.
  -- search_query_expand() is not called from anywhere any more and the
  -- search_synonyms table it reads is kept only as data. "bukhar" is now a
  -- word that matches no product name, which is what #747 shipped.
  if length(replace(v_clean,' ','')) < 3 then return; end if;
  v_toks := coalesce(regexp_split_to_array(v_clean, '\s+'), array[]::text[]);

  v_brand := null;
  foreach v_tok in array v_toks loop
    if v_tok ~ '[a-z]' and length(v_tok) >= 3 and not (v_tok = any(c_brandskip)) then
      v_brand := v_tok; exit; end if;
  end loop;
  if v_brand is null then v_brand := split_part(v_clean,' ',1); end if;
  v_pref     := left(v_brand, 3);
  v_brand_dm := dmetaphone(v_brand);

  v_keep := array[]::text[];
  foreach v_tok in array v_toks loop
    if not (v_tok = any(c_forms)) then v_keep := v_keep || v_tok; end if;
  end loop;
  if array_length(v_keep,1) is null then v_keep := v_toks; end if;
  v_compact := array_to_string(v_keep, '');
  v_cl      := length(v_compact);

  select mc.canon, mc.name_norm into v_co, v_co_norm
  from medicine_company mc
  where mc.name_norm = v_clean
     or (length(v_clean) >= 4 and mc.name_norm like v_clean || '%')
  order by (mc.name_norm = v_clean) desc, mc.buyable_count desc, mc.product_count desc
  limit 1;

  if v_co is null and length(replace(v_clean,' ','')) >= 5 then
    select mc.canon, mc.name_norm into v_co, v_co_norm
    from medicine_company mc
    where mc.name_norm like '%' || v_clean || '%'
    order by mc.buyable_count desc, mc.product_count desc
    limit 1;
  end if;

  if v_co is not null then
    v_co_tier := case
      when v_co_norm = v_clean           then 92
      when v_co_norm like v_clean || '%' then 86
      else 78 end;
  end if;

  return query
  with syn_salts as materialized (
    -- CHANGE #790 — "Paracetamol" is a WORD; `salt_composition` holds 106k
    -- real strings like 'Paracetamol (500mg)'. Resolving the word against the
    -- cached salt list first turns the product lookup into equality on
    -- idx_medicine_salt_plain — an ILIKE over 5.6 lakh rows never runs.
    select c.key as salt
      from public.search_suggest_cache c
     where v_syn_kind = 'salt'
       and c.kind = 'salt'
       and c.norm like '%' || public._norm_name(v_syn_target) || '%'
     order by c.rank desc
     limit 40
  ),
  syn_ids as materialized (
    select distinct u.id from (
      ( select m.id from "MEDICINE" m
          join syn_salts ss on ss.salt = m.salt_composition
         where (v_all or lower(m.therapeutic_class) = lower(category_filter))
         order by m.buyable desc, m.sales_count desc nulls last
         limit 250 )
      union all
      ( select m.id from "MEDICINE" m
         where v_syn_kind = 'category'
           and m.therapeutic_class = v_syn_target
           and (v_all or lower(m.therapeutic_class) = lower(category_filter))
         order by m.buyable desc, m.sales_count desc nulls last
         limit 250 )
    ) u
  ),
  co_ids as materialized (
    select m.id from "MEDICINE" m
    where v_co is not null
      and m.marketer_canonical = v_co
      and (v_all or lower(m.therapeutic_class) = lower(category_filter))
    order by m.buyable desc, m.sales_count desc nulls last
    limit 250
  ),
  cand as materialized (
    ( select m.id from "MEDICINE" m
      where public._norm_name(m.product_name) like '%'||v_clean||'%'
        and (v_all or lower(m.therapeutic_class) = lower(category_filter)) limit 300 )
    union
    ( select m.id from "MEDICINE" m
      where public._norm_name(m.product_name) like v_pref||'%'
        and (v_all or lower(m.therapeutic_class) = lower(category_filter)) limit 1000 )
    union
    ( select ci.id from co_ids ci )
    union
    ( select si.id from syn_ids si )
  ),
  scored as materialized (
    select m.id, m.product_name, m.salt_composition, m.marketer, m.therapeutic_class,
           m.image_url_1, m.pack_qty, m.pack_size, m.pack_type, m.mrp, m.gst_percent,
           m.rx_required, m.sales_count, m.has_scheme, m.has_image, m.buyable,
           m.supplier_count, m.marketer_canonical,
           case when public.get_my_role() in ('admin','super_admin')
                then coalesce(m.supplier_label,'') else '' end as supplier_label,
           public._norm_name(m.product_name) as prod_clean,
           (ci.id is not null) as is_co,
           (si.id is not null) as is_syn
    from "MEDICINE" m
    join cand c on c.id = m.id
    left join co_ids ci on ci.id = m.id
    left join syn_ids si on si.id = m.id
  ),
  scored2 as materialized (
    select s.*,
           regexp_split_to_array(s.prod_clean,' ') as prod_toks,
           replace(s.prod_clean,' ','')            as prod_compact,
           length(replace(s.prod_clean,' ',''))    as pc_len,
           split_part(s.prod_clean,' ',1)          as prod_first,
           similarity(s.prod_clean, v_clean)       as sim_full
    from scored s
  ),
  tokcum as materialized (
    select s.id,
           sum(length(t.tok)) over (partition by s.id order by t.ord
                                    rows between unbounded preceding and current row) as cumlen
    from scored2 s
    cross join lateral unnest(s.prod_toks) with ordinality as t(tok, ord)
    where v_cl >= 4 and s.prod_compact like v_compact || '%'
  ),
  tokmatch as materialized (
    select distinct tc.id from tokcum tc where tc.cumlen = v_cl
  ),
  ranked as (
    select s.*,
      greatest(
        (case
           when s.prod_clean = v_clean then 100
           when s.prod_clean like v_clean || '%' then 97
           when v_cl >= 4 and s.id in (select tm.id from tokmatch tm) then 96
           when v_cl >= 4 and s.prod_compact like v_compact || '%'
                and ( s.pc_len = v_cl or right(v_compact,1) !~ '[a-z]'
                      or substr(s.prod_compact, v_cl + 1, 1) !~ '[a-z]' ) then 95
           when v_cl >= 5 and s.prod_compact ~ ('(^|[^a-z])' || v_compact || '([^a-z]|$)') then 88
           when s.prod_first = v_brand then 85
           when levenshtein(v_brand, s.prod_first) <= 1 then 72
           when levenshtein(v_brand, s.prod_first) <= 2 then 60
           when v_brand_dm = dmetaphone(s.prod_first) then 55
           else 0 end),
        (case when s.is_co then v_co_tier else 0 end),
        -- a mapped word ("bukhar") matches nothing by name, so its rows carry
        -- their own tier or the tier cut below would drop every one of them
        (case when s.is_syn then 70 else 0 end)
      ) as tier
    from scored2 s
  ),
  -- CMD #1812: there is no sellability word any more. A row ranks by whether a
  -- supplier in the viewer's zone can actually send it, and by nothing else.
  finalr as (
    select r.*,
           (case when r.tier = 0 and r.sim_full >= 0.45 then 50 else r.tier end) as tier_final,
           -- CMD #1903 — inside one tier, the CLOSEST pack first: the exact
           -- name, then the query as the whole first word ("Monticope Tablet",
           -- "Monticope Suspension"), then a longer brand off the same root
           -- ("Monticope-A Tablet SR"). This is what puts the pack a buyer
           -- typed at the top of the list instead of behind its own family.
           (case
              when r.prod_clean = v_clean            then 0
              when r.prod_first = v_clean            then 1
              when r.prod_clean like v_clean || ' %' then 2
              when r.prod_clean like v_clean || '%'  then 3
              else 4 end) as name_rank
    from ranked r
  ),
  -- CHANGE #678: for an approved customer the "has a supplier" rank is their
  -- ZONE's standby, so what is available to them sorts first. Anon keeps the
  -- catalogue count. Evaluated only for rows that survive the tier cut.
  kept as (
    select f.*,
           (case when (case when v_zone is null then coalesce(f.supplier_count, 0)
                            else public.medicine_zone_standby(f.id, v_zone) end) < 1 then 1
                 else 0 end) as sell_rank
    from finalr f
   where f.tier_final >= 50
     -- CHANGE #790 — #747's switch, applied to search: with it on, an approved
     -- customer is shown what a supplier in their zone can actually send.
     and (v_zfilter is null
          or exists (select 1 from public.catalogue_zone_avail za
                      where za.zone_id = v_zfilter and za.product_id = f.id))
  ),
  -- #451: one row per (normalised name, marketer). The identical 'Dolo-T
  -- Tablet [NOT FOR SALE]' pair collapses to its best-ranked member.
  deduped as (
    select k.*, row_number() over (
             partition by k.prod_clean, coalesce(k.marketer_canonical, k.marketer, '')
             order by k.tier_final desc, k.name_rank asc, k.sell_rank asc,
                      k.buyable desc,
                      k.sales_count desc nulls last, k.has_image desc, k.id asc) as dup_rn
    from kept k
  )
  select f.id, f.product_name, f.salt_composition, f.marketer, f.therapeutic_class,
         f.image_url_1,
         coalesce(nullif(btrim(f.pack_type),''), nullif(btrim(f.pack_size),'')) as pack_qty,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_size,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_type,
         f.mrp, f.gst_percent,
         f.rx_required, f.sales_count, f.has_scheme, f.has_image, f.buyable,
         f.supplier_count, f.supplier_label
  from deduped f
  where f.dup_rn = 1
  -- CMD #1903 — the ranked, flat order this list has to have: the closest
  -- match first, then the other packs of the same brand (they share its
  -- tier), then similar brands. `sell_rank` used to lead, so an exact match
  -- with no supplier in the viewer's zone sank below every loosely-matched
  -- pack that had one — searching "monticope" never showed Monticope Tablet.
  -- It still breaks ties, one step down.
  order by f.tier_final desc, f.name_rank asc, length(f.prod_clean) asc,
           f.sell_rank asc, f.buyable desc,
           f.sales_count desc nulls last, f.sim_full desc, length(f.product_name) asc
  limit page_limit offset page_offset;
end;
$function$

;

-- ── 2. The search payload: one flat list, and a counter line worded here ─────
--
-- CHANGE #790's `blocks` array (brand_family_key + _brand_split) is gone for
-- good: `items` is the only list this payload has, in the backend's own rank
-- order, and the grid renders it row by row. `showing_label` is the small grey
-- line above the list — "126 results for monticope" — including its plural,
-- because a plural is a display decision and display decisions are the
-- backend's.
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
           search_term, category_filter, page_offset, (SELECT n FROM lim) + 1, p_zone) s
  ),
  rows AS (SELECT * FROM probe WHERE rn <= (SELECT n FROM lim)),
  n AS (SELECT count(*)::int AS returned FROM rows),
  shown AS (SELECT page_offset + (SELECT returned FROM n) AS total),
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
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id
  )
  SELECT jsonb_build_object(
    'status','ok',
    'search_term', search_term,
    'category', category_filter,
    'page_offset', page_offset,
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'result_count', (SELECT returned FROM n),
    -- CMD #1903 — the header line. Small, grey, and the only thing above the
    -- list: the "Search Results" title the app used to draw is gone.
    'showing_label', (SELECT total::text FROM shown)
                     || ' result' || (SELECT CASE WHEN total = 1 THEN '' ELSE 's' END FROM shown)
                     || ' for ' || btrim(coalesce(search_term, '')),
    'empty_label', 'No products match "' || search_term || '"',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', page_offset + (SELECT returned FROM n),
    'has_more', (SELECT count(*) FROM probe) > (SELECT n FROM lim),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_results'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'search_end_label'), ''),
    'zone_switch', public.catalogue_zone_switch(coalesce(p_zone, true)),
    'items', coalesce((
      SELECT jsonb_agg(i.obj ORDER BY i.rn) FROM item i), '[]'::jsonb)
  );
$function$;

-- ── 3. "Other packs" — the family, on the product page and nowhere else ──────
--
-- The same brand root + same marketer join `_cat_variants` uses for the (now
-- removed) card chips, widened to eight entries and anchored on ONE product:
-- the pack being viewed is always in the list and always `selected`, so the
-- strip reads as a switch rather than as a set of links away from the page.
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
  top AS (
    SELECT id, label,
           row_number() over (ORDER BY (id = p_product_id) DESC, label) AS rn,
           count(*) over () AS n
      FROM pick
  )
  SELECT jsonb_build_object(
    'has',   coalesce((SELECT max(n) FROM top), 0) > 1,
    'title', public.uic('catalogue.variants_title', 'Other packs'),
    'items', coalesce((SELECT jsonb_agg(jsonb_build_object(
                                'product_id', id,
                                'label',      label,
                                'selected',   id = p_product_id) ORDER BY rn)
                         FROM top WHERE rn <= 8), '[]'::jsonb));
$function$;

-- Not a client-facing RPC: the product page reads it through product_detail(),
-- which is SECURITY DEFINER and calls it as the owner. Nothing anonymous, and
-- nothing signed in, may reach it directly.
REVOKE ALL ON FUNCTION public.pdp_other_packs(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pdp_other_packs(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.pdp_other_packs(bigint) FROM authenticated;

-- ── 4. The product page carries it, so the page stays ONE RPC ───────────────
-- test/protected/product_detail_test.dart holds that contract down: the whole
-- page is one payload, printed verbatim. A second call for the pack family
-- would break it, so the family rides here.
CREATE OR REPLACE FUNCTION public.product_detail(p_product_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v jsonb; v_rx text;
  v_gallery jsonb; v_facts jsonb; v_purchase jsonb; v_companions jsonb;
  v_supply jsonb; v_lines jsonb; v_mrp numeric;
  v_parts jsonb; v_title jsonb; v_chip text; v_packs jsonb;
begin
  v := public._product_detail_core(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  select m.rx_required into v_rx from "MEDICINE" m where m.id = p_product_id;

  begin v_gallery := public.product_gallery(p_product_id);
  exception when others then v_gallery := jsonb_build_object('has', false, 'count', 0, 'images', '[]'::jsonb); end;

  begin v_facts := public.product_facts(p_product_id);
  exception when others then v_facts := jsonb_build_object('has', false, 'title', '', 'rows', '[]'::jsonb); end;

  begin v_purchase := public.purchase_overlay(p_product_id);
  exception when others then v_purchase := jsonb_build_object('has', false); end;

  begin v_companions := public.product_companions(p_product_id, array[p_product_id]);
  exception when others then v_companions := jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb); end;

  -- CMD #1826 — supply confidence (a band, never a count) and the two price
  -- lines. Both worded here; the page prints them.
  v_mrp := nullif(v#>>'{pricing,mrp}', '')::numeric;
  begin v_supply := public.pdp_supply_confidence(p_product_id);
  exception when others then v_supply := jsonb_build_object('has', false); end;
  begin v_lines := public.pdp_price_lines(p_product_id, v_mrp);
  exception when others then v_lines := jsonb_build_object('has', false); end;

  -- CMD #1903 — the family, as a strip under the price. `has:false` for a
  -- pack that is the only one of its brand, so the page draws nothing rather
  -- than a strip with one chip in it.
  begin v_packs := public.pdp_other_packs(p_product_id);
  exception when others then v_packs := jsonb_build_object('has', false, 'title', '', 'items', '[]'::jsonb); end;

  -- CMD #1896 — the title block.
  begin v_parts := public._pdp_pack_parts(p_product_id);
  exception when others then v_parts := jsonb_build_object('has', false); end;
  v_chip := coalesce(nullif(btrim(coalesce(v_parts->>'type', '')), ''),
                     nullif(btrim(coalesce(v_parts->>'container', '')), ''), '');
  v_title := jsonb_build_object(
    'has',     true,
    'name',    coalesce(v#>>'{header,name}', ''),
    'company', coalesce(v#>>'{header,company}', ''),
    'form_chip', jsonb_build_object(
      'has',   (v_chip <> ''),
      'label', initcap(v_chip),
      'tone',  'success'),
    'pack_line', jsonb_build_object(
      'has',   coalesce((v_parts->>'has')::boolean, false),
      'label', coalesce(v_parts->>'pack_line', '')));

  -- CHANGE #461/#170: the prescription class, and (for a signed-in pharmacy)
  -- whether their drug licence is on file for it.
  return v
    || jsonb_build_object('header',
         coalesce(v->'header','{}'::jsonb)
         || jsonb_build_object('rx_required',
              (upper(btrim(coalesce(v_rx,''))) = 'RX')))
    || jsonb_build_object(
    'rx',         public.rx_badge(v_rx),
    'rx_licence', case when upper(btrim(coalesce(v_rx,''))) = 'RX'
                            and public.my_customer_id() is not null
                       then public.rx_licence_state(public.my_customer_id())
                       else jsonb_build_object('has', true, 'reason', 'n/a') end)
    -- CMD #791 — depth: the gallery, the fact table, this buyer's own history
    -- with the pack, and what it is bought with.
    || jsonb_build_object(
    'gallery',    v_gallery,
    'facts',      v_facts,
    'purchase',   v_purchase,
    'companions', v_companions)
    -- CMD #1826 — and NEVER a raw sourcing count in the payload: the trust
    -- strip's internal ask/fill tallies stay in the database.
    || jsonb_build_object(
    'trust',       public._pdp_strip_counts(v->'trust'),
    'supply',      v_supply,
    'price_lines', v_lines,
    'title',       v_title,
    'other_packs', v_packs);
end $function$;
