-- CMD #1903d — the flat search list has to answer inside the anon budget.
--
-- After the get_my_role() hoist (#1903b) and an ANALYZE of "MEDICINE" /
-- medicine_company / catalogue_zone_avail — none of which had EVER been
-- analysed, so the planner was costing a 5.6-lakh-row table as if it were
-- empty (standing lesson 160) — the live numbers were:
--
--     crocin     0.74 s   ok
--     azithral   2.04 s   ok
--     dolo       2.37 s   ok, but a quarter of a second from failing
--     pan        3.16 s   HTTP 500 57014
--
-- The anon role has a 3 s statement budget (standing lesson 159) and a query
-- over it does not return a slow list, it returns a 500 and the storefront
-- draws Retry. Two costs are left, and this file removes both:
--
--   1. THE THREE-LETTER CONTAINS SCAN. '%pan%' is a single trigram, so the GIN
--      index hands back a bitmap the size of the catalogue: 1.34 s to find the
--      arbitrary 300 rows the branch caps at. '%dolo%' is two trigrams and
--      takes 10 ms. The branch now runs for queries of four characters or
--      more; three-letter queries are answered by the prefix branch, which is
--      what "pan" means anyway.
--
--   2. A 250-ROW FIRST PAGE. Each row costs a storefront_cta, a
--      storefront_effective_count and a storefront_pricing call — about 2.2 s
--      of dolo's 2.37 s. Search now reads `search_initial_limit` (60) and
--      falls back to the catalogue's setting, so the two surfaces can be tuned
--      apart with an UPDATE. Paging is unchanged: the payload has always
--      carried has_more / next_offset / more_limit and the app has always
--      obeyed them.
--
-- Idempotent: CREATE OR REPLACE of two functions and two INSERT … ON CONFLICT.

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
  v_is_admin boolean;   -- CMD #1903b: get_my_role() is VOLATILE, read it ONCE
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
  v_is_admin := public.get_my_role() in ('admin','super_admin');
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
    -- CMD #1903d — the CONTAINS scan is for queries of four characters or
    -- more. `_norm_name(product_name) gin_trgm_ops` answers '%dolo%' from two
    -- trigrams in 10 ms; a three-letter query is ONE trigram, so '%pan%'
    -- matched a bitmap the size of the catalogue and took 1.34 s of the 3 s
    -- the anon role is allowed — the single reason searching "pan" answered
    -- HTTP 500 while "crocin" answered in 0.74 s. Nothing of value is lost:
    -- the 300 rows it capped at were an arbitrary 300 out of tens of
    -- thousands, and a three-letter query is a prefix ("pan" → Pan 40,
    -- Pantop, Pantocid), which the branch below answers exactly.
    ( select m.id from "MEDICINE" m
      where length(replace(v_clean,' ','')) >= 4
        and public._norm_name(m.product_name) like '%'||v_clean||'%'
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
           case when v_is_admin
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
  -- CMD #1903d — SEARCH has its own first page. The catalogue's 250 is a
  -- browse page the viewer scrolls; a search list is read from the top and
  -- pages itself on `has_more` / `next_offset`, and every one of those 250
  -- rows costs a storefront_cta + storefront_effective_count +
  -- storefront_pricing call — 2.2 s of the 2.37 s "dolo" took. Sixty rows is
  -- more than a screen and roughly a quarter of the cost. It is a setting, so
  -- retuning it is an UPDATE, not a deploy.
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

-- The settings themselves, so the numbers are data. ON CONFLICT DO NOTHING:
-- if Om has already retuned either one, this migration must not overrule it.
INSERT INTO public.app_settings (key, value)
VALUES ('search_initial_limit', to_jsonb(60)),
       ('search_more_limit',    to_jsonb(60))
ON CONFLICT (key) DO NOTHING;
