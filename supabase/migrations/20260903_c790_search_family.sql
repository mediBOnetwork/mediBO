-- CHANGE #790, part C — the search RESULTS: brand-family cards, the Hinglish
-- mapping applied to the product query, and #747's zone switch honoured.
--
-- Three things change about a search:
--   1. A Hindi/Hinglish word is resolved to a salt or a class BEFORE any name
--      matching happens, and its rows carry their own rank tier (nothing about
--      "bukhar" looks like "Paracetamol", so the name tiers would drop them).
--   2. The zone switch now FILTERS as well as ranks. #678 sorted zone-available
--      rows first; #747 gave the catalogue a switch; a search that ignored it
--      was the last surface where "available in my zone" meant nothing.
--   3. Variants of one brand collapse into ONE card. Grouping is
--      brand_family_key() — same brand root, same company — and it is done in
--      this function, so the grid renders blocks it is handed rather than
--      guessing which rows belong together.
--
-- The 4-argument search is dropped and recreated with p_zone: a defaulted
-- fifth parameter alongside the old signature would make every 4-argument call
-- ambiguous.
drop function if exists public.search_medicines_priority(text, text, integer, integer);

CREATE OR REPLACE FUNCTION public.search_medicines_priority(search_term text, category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT 20, p_zone boolean DEFAULT true)
 RETURNS TABLE(id bigint, product_name text, salt_composition text, marketer text, therapeutic_class text, image_url_1 text, pack_qty text, pack_size text, pack_type text, mrp text, gst_percent integer, status text, rx_required text, sales_count integer, has_scheme boolean, has_image boolean, buyable boolean, supplier_count integer, supplier_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_clean text; v_all boolean; v_brand text; v_pref text; v_tok text;
  v_toks text[]; v_keep text[]; v_compact text; v_cl int; v_brand_dm text;
  v_co text; v_co_norm text; v_co_tier int := 0;
  v_zone smallint := public._viewer_zone_or_null();   -- CHANGE #678
  -- CHANGE #790 — the #747 zone switch, and the Hinglish mapping.
  v_zfilter smallint := public._cat_zone(coalesce(p_zone, true));
  v_syn jsonb; v_syn_kind text := null; v_syn_target text := null;
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

  -- CHANGE #790 — Hindi/Hinglish FIRST. "bukhar" is not a brand and will never
  -- match one by name; it is resolved to the salt it means and the search runs
  -- on that. A mapped term is also allowed past the 3-character gate, because
  -- "bp" is a real search once it is known to mean Amlodipine.
  v_syn := public.search_query_expand(v_clean);
  if coalesce((v_syn->>'has')::boolean, false) then
    v_syn_kind   := v_syn->>'target_kind';
    v_syn_target := v_syn->>'target';
  end if;

  if length(replace(v_clean,' ','')) < 3 and v_syn_kind is null then return; end if;
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
           m.status, m.rx_required, m.sales_count, m.has_scheme, m.has_image, m.buyable,
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
  -- #451: sellability is a set-based JOIN against the 6-row policy table, so
  -- 563k rows are never probed once per candidate.
  finalr as (
    select r.*,
           (case when r.tier = 0 and r.sim_full >= 0.45 then 50 else r.tier end) as tier_final,
           coalesce(p.sellable, true) as sellable
    from ranked r
    left join public.medicine_status_policy p
           on p.status_key = public._med_status_key(r.status)
  ),
  -- CHANGE #678: for an approved customer the "has a supplier" rank is their
  -- ZONE's standby, so what is available to them sorts first. Anon keeps the
  -- catalogue count. Evaluated only for rows that survive the tier cut.
  kept as (
    select f.*,
           (case when not f.sellable then 2
                 when (case when v_zone is null then coalesce(f.supplier_count, 0)
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
             order by k.sell_rank asc, k.tier_final desc, k.buyable desc,
                      k.sales_count desc nulls last, k.has_image desc, k.id asc) as dup_rn
    from kept k
  )
  select f.id, f.product_name, f.salt_composition, f.marketer, f.therapeutic_class,
         f.image_url_1,
         coalesce(nullif(btrim(f.pack_type),''), nullif(btrim(f.pack_size),'')) as pack_qty,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_size,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_type,
         f.mrp, f.gst_percent,
         f.status, f.rx_required, f.sales_count, f.has_scheme, f.has_image, f.buyable,
         f.supplier_count, f.supplier_label
  from deduped f
  where f.dup_rn = 1
  order by f.sell_rank asc, f.tier_final desc, f.buyable desc,
           f.sales_count desc nulls last, f.sim_full desc, length(f.product_name) asc
  limit page_limit offset page_offset;
end;
$function$;

grant execute on function public.search_medicines_priority(text, text, integer, integer, boolean)
  to anon, authenticated;

-- ── the printed brand and the variant chip ──────────────────────────────────
-- `_brand_root()` returns a NORMALISED root ("monticope"). The card prints the
-- catalogue's own capitalisation and the chip prints what is left over, so a
-- family reads "Monticope" with chips "Tablet", "-A Tablet", "5 mg Tablet" —
-- all of it real product text, none of it composed here.
create or replace function public._brand_split(p_name text, p_root text)
returns text[]
language plpgsql
immutable
parallel safe
as $function$
declare
  v_need int := length(replace(coalesce(p_root, ''), ' ', ''));
  v_seen int := 0;
  i int;
  ch text;
begin
  if v_need = 0 or coalesce(p_name, '') = '' then
    return array[coalesce(p_name, ''), ''];
  end if;
  for i in 1..length(p_name) loop
    ch := substr(p_name, i, 1);
    if ch ~ '[A-Za-z0-9]' then v_seen := v_seen + 1; end if;
    if v_seen = v_need then
      return array[
        btrim(substr(p_name, 1, i)),
        btrim(regexp_replace(substr(p_name, i + 1), '^[^A-Za-z0-9(]+', ''))
      ];
    end if;
  end loop;
  return array[btrim(p_name), ''];
end $function$;

comment on function public._brand_split(text, text) is
  'CHANGE #790 — splits a product name into its printed brand and the variant text after it.';

grant execute on function public._brand_split(text, text) to anon, authenticated;

-- ── the search page ─────────────────────────────────────────────────────────
drop function if exists public.storefront_search_page(text, text, integer, integer);

create or replace function public.storefront_search_page(
  search_term text,
  category_filter text default 'All'::text,
  page_offset integer default 0,
  page_limit integer default null::integer,
  p_zone boolean default true)
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
  expanded AS (SELECT public.search_query_expand(search_term) AS x),
  probe AS (
    SELECT s.*, row_number() over () AS rn
    FROM public.search_medicines_priority(
           search_term, category_filter, page_offset, (SELECT n FROM lim) + 1, p_zone) s
  ),
  rows AS (SELECT * FROM probe WHERE rn <= (SELECT n FROM lim)),
  n AS (SELECT count(*)::int AS returned FROM rows),
  -- every row, once, with the family it belongs to and the full item payload
  item AS (
    SELECT r.rn, r.id,
           public.brand_family_key(r.product_name, src.marketer_canonical) AS fam,
           r.product_name,
           src.marketer_canonical AS mc,
           public._brand_root(r.product_name) AS root,
           (to_jsonb(r) - 'rn')
             || jsonb_build_object('availability',
                  public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count),
                                        true, src.status))
             || jsonb_build_object('status', public.med_status_block(src.status)->>'label')
             || jsonb_build_object('status_block', public.med_status_block(src.status))
             || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
             || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
             || jsonb_build_object('pricing', public.storefront_pricing(
                  nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
                  (SELECT pct FROM disc), r.id))
             AS obj
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id
  ),
  fam AS (
    SELECT i.fam,
           min(i.rn) AS ord,
           count(*)::int AS n_variants,
           (array_agg(i.root       ORDER BY i.rn))[1] AS root,
           (array_agg(i.product_name ORDER BY i.rn))[1] AS lead_name,
           (array_agg(coalesce(i.mc, '') ORDER BY i.rn))[1] AS mc
      FROM item i
     GROUP BY i.fam
  ),
  blocks AS (
    SELECT f.ord,
      CASE WHEN f.n_variants >= 2 THEN
        jsonb_build_object(
          'kind', 'family',
          'family_key', f.fam,
          'title', (public._brand_split(f.lead_name, f.root))[1],
          'company_label', coalesce(mc.display, nullif(f.mc, ''), ''),
          'sub_label', CASE WHEN coalesce(mc.display, nullif(f.mc, ''), '') = '' THEN ''
                            ELSE replace(public.uic('search.family_by', 'by {company}'),
                                         '{company}', coalesce(mc.display, f.mc)) END,
          'variant_count', f.n_variants,
          'count_label', replace(public.uic('search.family_variants', '{n} variants'),
                                 '{n}', f.n_variants::text),
          'variants', (
            SELECT jsonb_agg(
                     i2.obj || jsonb_build_object(
                       'variant_label',
                       coalesce(nullif((public._brand_split(i2.product_name, i2.root))[2], ''),
                                i2.product_name))
                     ORDER BY i2.rn)
              FROM item i2 WHERE i2.fam = f.fam))
      ELSE
        jsonb_build_object(
          'kind', 'product',
          'item', (SELECT i3.obj FROM item i3 WHERE i3.fam = f.fam ORDER BY i3.rn LIMIT 1))
      END AS block
      FROM fam f
      LEFT JOIN public.medicine_company mc ON mc.canon = nullif(f.mc, '')
  )
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
    -- CHANGE #790 — what a Hindi/Hinglish word was taken to mean, printed
    -- above the results so the shopper can see the search that actually ran.
    'expanded', (SELECT x FROM expanded),
    'expanded_prefix', public.uic('search.hinglish_prefix', 'Searching for'),
    -- CHANGE #790 / #747 — the switch itself, rendered verbatim.
    'zone_switch', public.catalogue_zone_switch(coalesce(p_zone, true)),
    -- CHANGE #790 — the grid renders THIS: one block per card, families
    -- already folded, in result order. `items` stays exactly as it was.
    'blocks', coalesce((SELECT jsonb_agg(b.block ORDER BY b.ord) FROM blocks b), '[]'::jsonb),
    'items', coalesce((
      SELECT jsonb_agg(i.obj ORDER BY i.rn) FROM item i), '[]'::jsonb)
  );
$function$;

comment on function public.storefront_search_page(text, text, integer, integer, boolean) is
  'CHANGE #790 — search results: brand-family blocks, Hinglish expansion note, #747 zone switch. Never prices on MRP (#746).';

grant execute on function public.storefront_search_page(text, text, integer, integer, boolean)
  to anon, authenticated;
