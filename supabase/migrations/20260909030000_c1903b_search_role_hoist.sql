-- CMD #1903 (follow-up) — the flat search list answered HTTP 500 for anon.
--
-- storefront_search_page('dolo') took 3.04 s on live and the anon role has a
-- 3 s statement budget, so common one-word brand searches came back
-- 57014 "canceling statement due to statement timeout" and the storefront
-- rendered its Retry state instead of the new list. "monticope" (1.73 s) was
-- under the line, which is why the build verified green and the everyday
-- query did not.
--
-- The cost was not the ranking. public.get_my_role() is VOLATILE and sat in a
-- scalar CASE inside `scored`, so Postgres called it once for every candidate
-- row. Measured on live: 1,300 calls = 1.496 s, half the whole query. The
-- viewer's role cannot change inside one statement, so it is evaluated once
-- into v_is_admin and the CASE reads the variable. Nothing else moves — same
-- rows, same order, same payload.
--
-- Idempotent: CREATE OR REPLACE of one function.

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
  -- CMD #1903 (fix) — get_my_role() is VOLATILE, so the CASE below was
  -- re-evaluated once PER CANDIDATE ROW. Measured on live: 1,300 rows x
  -- get_my_role() = 1.50 s of a 3.04 s query, and the anon role has a 3 s
  -- statement budget (lesson 159), so "dolo" / "pan" / "azithral" answered
  -- HTTP 500 57014 and the storefront showed Retry. The role is constant
  -- within a statement; evaluating it once is behaviour-identical.
  v_is_admin boolean;
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
