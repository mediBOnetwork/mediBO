-- CMD #1812 — Remove 1mg's status / status_reason from availability.
-- Zone standby is the ONLY availability truth:
--   standby = master zone supplier list − (out-of-stock + nostock);
--   available when standby > 0 (medicine_zone_standby / medicine_zone_available).
-- MEDICINE.status / status_reason are scraped 1mg fields. They made Abbott Gel
-- Hand Sanitizer render a red "Discontinued" badge and "Not for sale" instead of
-- Add, on a pack a supplier in the zone could send. ~6,200 rows also carried the
-- reason glued onto the status word. This file strips the field out of every
-- availability decision and every payload; the companion file drops the helpers,
-- the policy table and the columns themselves.
-- Part A — rewrite. No table DDL here on purpose.

-- Signature changes (a narrowed argument list / a narrowed RETURNS TABLE) need a
-- real DROP first; CREATE OR REPLACE would leave the old overload alive and a
-- caller would silently keep resolving to it.
DROP FUNCTION IF EXISTS public.storefront_cta(integer, boolean, text);
DROP FUNCTION IF EXISTS public.get_storefront_feed(text, integer, integer);
DROP FUNCTION IF EXISTS public.search_medicines_priority(text, text, integer, integer, boolean);

-- ── storefront_cta ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.storefront_cta(p_supplier_count integer, p_resolved boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- CMD #1812 — there is exactly ONE availability rule and it is the zone's
  -- standby count. 1mg's scraped `status` used to open a third branch here
  -- ("Not for sale", red) on a product a supplier in the zone could send; that
  -- branch, its parameter and its copy keys are gone.
  select case
    when not coalesce(p_resolved, true) then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'unresolved', true,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    when coalesce(p_supplier_count, 0) >= 1 then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    else
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label','Unavailable','gated', public.viewer_is_approved_customer(),
        'blocked_by', 'no_supplier',
        'note', case when auth.uid() is null
                     then public.uic('storefront.signed_out_note',
                                     'Sign in to see availability in your area.')
                     else public.uic('storefront.no_supplier_note',
                                     'No supplier for this product right now') end,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='stock_out_label'), 'Out of stock'),
        'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF'))
  end;
$function$;

-- ── storefront_effective_count ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.storefront_effective_count(p_product_id bigint, p_global integer)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_zone smallint;
begin
  -- CMD #1812: no catalogue word can make a pack unbuyable. Zone standby only.
  v_zone := public._viewer_zone_or_null();
  if v_zone is not null then
    return public.medicine_zone_standby(p_product_id, v_zone);  -- zone truth
  end if;
  -- CHANGE #678: anon and unapproved viewers see everything as available.
  return greatest(coalesce(p_global, 0), 1);
end $function$;

-- ── get_storefront_feed ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_storefront_feed(category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT 20)
 RETURNS TABLE(url text, product_name text, salt_composition text, marketer text, rx_required text, image_url_1 text, image_url_2 text, image_url_3 text, image_url_4 text, image_url_5 text, image_count text, storage text, mrp text, pack_size text, pack_qty text, pack_type text, scrapping_status text, uses text, benefits text, side_effects text, how_it_works text, habit_forming text, therapeutic_class text, chemical_class text, action_class text, product_introduction text, product_highlight text, id bigint, _row_id bigint, sales_count integer, has_scheme boolean, has_image boolean, gst_percent integer, "PS1" text, "PS2" text, "PS3" text, "PS4" text, "PS5" text, "PS6" text, "PS7" text, "PS8" text, "PS9" text, "PS10" text, "PS11" text, "PS12" text, "PS13" text, "PS14" text, "PS15" text, "PS16" text, "PS17" text, "PS18" text, "PS19" text, "PS20" text, "PS21" text, "PS22" text, "PS23" text, "PS24" text, "PS25" text, "PS26" text, "PS27" text, "PS28" text, "PS29" text, "PS30" text, buyable boolean, data_source text, marketer_canonical text, tm_id bigint, supplier_count integer, supplier_label text, showing_label text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with page as (
    select m.*, f.rank as _rank, count(*) over () as _n
    from public._sf_feed_ids(category_filter, page_offset, page_limit) f
    join "MEDICINE" m on m.id = f.product_id
  )
  select p.url, p.product_name, p.salt_composition, p.marketer, p.rx_required,
         p.image_url_1, p.image_url_2, p.image_url_3, p.image_url_4, p.image_url_5,
         p.image_count, p.storage, p.mrp,
         coalesce(nullif(btrim(p.pack_qty),''),  nullif(btrim(p.pack_size),'')) as pack_size,
         coalesce(nullif(btrim(p.pack_type),''), nullif(btrim(p.pack_size),'')) as pack_qty,
         coalesce(nullif(btrim(p.pack_qty),''),  nullif(btrim(p.pack_size),'')) as pack_type,
         p.scrapping_status, p.uses, p.benefits,
         p.side_effects, p.how_it_works, p.habit_forming, p.therapeutic_class,
         p.chemical_class, p.action_class, p.product_introduction, p.product_highlight,
         p.id, p._row_id, p.sales_count, p.has_scheme, p.has_image, p.gst_percent,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         p.buyable, p.data_source, p.marketer_canonical, p.tm_id,
         p.supplier_count,
         case when public.get_my_role() in ('admin','super_admin')
              then coalesce(p.supplier_label,'') else '' end,
         'Showing ' || p._n::text
                    || ' of ' || coalesce(public.get_storefront_count(category_filter),0)::text
                    || ' products'
                    || case when lower(coalesce(category_filter,'All')) = 'all'
                            then '' else ' in ' || category_filter end
  from page p
  order by p._rank;
$function$;

-- ── search_medicines_priority ───────────────────────────────────────────────
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
           (case when r.tier = 0 and r.sim_full >= 0.45 then 50 else r.tier end) as tier_final
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
         f.rx_required, f.sales_count, f.has_scheme, f.has_image, f.buyable,
         f.supplier_count, f.supplier_label
  from deduped f
  where f.dup_rn = 1
  order by f.sell_rank asc, f.tier_final desc, f.buyable desc,
           f.sales_count desc nulls last, f.sim_full desc, length(f.product_name) asc
  limit page_limit offset page_offset;
end;
$function$;

-- ── _cat_cards ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._cat_cards(p_ids bigint[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'salt', m.salt_composition,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false)
                       then public.uic('catalogue.scheme_chip','Scheme available') else '' end,
    -- CHANGE #748 — the "New" chip. A card is new because the BACKEND says so
    -- against its own window, never because Dart compared a date: is_new and
    -- the label travel together and an absent created_at is simply not new.
    'is_new', (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30))),
    'new_badge', case when (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30)))
                 then public.uic('catalogue.new_badge','New') else '' end,
    'rx', public.rx_badge(m.rx_required),
    'availability', public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
        true),
    'pricing', public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id),
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t')
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid;
$function$;

-- ── cart_companions ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cart_companions(p_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_zone  smallint;
  v_show  int;
  v_use   smallint;
  v_disc  numeric;
  v_items jsonb;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb);
  end if;

  v_show := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_show_top_n'), 6);
  v_zone := coalesce(public._viewer_zone_or_null(), public.my_zone_id());
  v_disc := public._c791_safe_discount_pct();

  if v_zone is not null and exists (
       select 1 from product_copurchase
        where product_id = any (p_ids) and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  select coalesce(jsonb_agg(x order by x_support desc, x_id), '[]'::jsonb) into v_items
  from (
    select m.id as x_id, sum(c.support)::int as x_support,
           jsonb_build_object(
             'id',            m.id,
             'name',          coalesce(m.product_name, ''),
             'company',       coalesce(m.marketer, ''),
             'pack_label',    coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'form_chip',     coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'image',         coalesce(m.image_url_1, ''),
             'support_label', sum(c.support)::text || ' orders',
             'pricing',       public.storefront_pricing(
                                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                                v_disc, m.id),
             'availability',  public.storefront_cta(
                                public.storefront_effective_count(m.id, m.supplier_count),
                                true)) as x
      from product_copurchase c
      join "MEDICINE" m on m.id = c.companion_id
     where c.product_id = any (p_ids)
       and c.zone_id = v_use
       and not (c.companion_id = any (p_ids))
       and m.buyable is true
     group by m.id, m.product_name, m.marketer, m.pack_type, m.pack_size,
              m.pack_qty, m.image_url_1, m.mrp, m.supplier_count
     order by 2 desc, 1
     limit greatest(v_show, 1)
  ) s;

  return jsonb_build_object(
    'has',   jsonb_array_length(v_items) > 0,
    'title', coalesce((select value from storefront_ui_label where key = 'cart_companions_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key = 'cart_companions_note'), ''),
    'zone_id', v_use,
    'items', v_items);
end;
$function$;

-- ── product_companions ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.product_companions(p_product_id bigint, p_exclude bigint[] DEFAULT '{}'::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_zone  smallint;
  v_show  int;
  v_use   smallint;
  v_disc  numeric;
  v_items jsonb;
begin
  v_show := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_show_top_n'), 6);
  v_zone := coalesce(public._viewer_zone_or_null(), public.my_zone_id());
  v_disc := public._c791_safe_discount_pct();

  -- Prefer the viewer's own zone; fall back to the platform roll-up (0).
  if v_zone is not null and exists (
       select 1 from product_copurchase
        where product_id = p_product_id and zone_id = v_zone) then
    v_use := v_zone;
  else
    v_use := 0;
  end if;

  select coalesce(jsonb_agg(x order by x_rank), '[]'::jsonb) into v_items
  from (
    select c.rank as x_rank,
           jsonb_build_object(
             'id',            m.id,
             'name',          coalesce(m.product_name, ''),
             'company',       coalesce(m.marketer, ''),
             'pack_label',    coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'form_chip',     coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                                       nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
             'image',         coalesce(m.image_url_1, ''),
             'support_label', c.support::text || ' orders',
             'pricing',       public.storefront_pricing(
                                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                                v_disc, m.id),
             'availability',  public.storefront_cta(
                                public.storefront_effective_count(m.id, m.supplier_count),
                                true)) as x
      from product_copurchase c
      join "MEDICINE" m on m.id = c.companion_id
     where c.product_id = p_product_id
       and c.zone_id = v_use
       and m.buyable is true
       and not (m.id = any (coalesce(p_exclude, '{}'::bigint[])))
     order by c.rank
     limit greatest(v_show, 1)
  ) s;

  return jsonb_build_object(
    'has',   jsonb_array_length(v_items) > 0,
    'title', coalesce((select value from storefront_ui_label where key = 'pdp_companions_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key = 'pdp_companions_note'), ''),
    'zone_id', v_use,
    'items', v_items);
end;
$function$;

-- ── copurchase_rebuild ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.copurchase_rebuild()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_min   int;
  v_top   int;
  v_days  int;
  v_rows  bigint;
begin
  v_min  := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_min_support'), 3);
  v_top  := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_store_top_n'), 12);
  v_days := coalesce((select (value #>> '{}')::int from app_settings where key = 'copurchase_lookback_days'), 365);

  drop table if exists _cop_new;
  create temporary table _cop_new on commit drop as
  with lines as (
    select distinct
           oi.order_id,
           oi.product_id,
           coalesce(oi.zone_id, o.zone_id)::smallint as zone_id
      from order_items oi
      join orders o on o.id = oi.order_id
     where oi.product_id is not null
       and coalesce(oi.order_date, o.order_date) >= (current_date - v_days)
       and coalesce(oi.unfulfillable, false) = false
  ),
  cls as (
    select l.*, (upper(btrim(coalesce(m.rx_required, ''))) = 'RX') as is_rx
      from lines l
      join "MEDICINE" m on m.id = l.product_id
     where m.buyable is true
  ),
  -- Ordered pairs (both directions) so a lookup by either side is one index hit.
  -- The Rx class must MATCH: that is the "never across Rx restrictions" rule,
  -- enforced where the pair is formed rather than filtered at read time.
  pairs as (
    select a.zone_id, a.product_id, b.product_id as companion_id, a.is_rx, a.order_id
      from cls a
      join cls b
        on b.order_id = a.order_id
       and b.product_id <> a.product_id
       and b.is_rx = a.is_rx
  ),
  by_zone as (
    select zone_id, product_id, companion_id, bool_or(is_rx) as is_rx,
           count(distinct order_id)::int as support
      from pairs
     where zone_id is not null
     group by 1, 2, 3
  ),
  global as (
    select 0::smallint as zone_id, product_id, companion_id, bool_or(is_rx) as is_rx,
           count(distinct order_id)::int as support
      from pairs
     group by 2, 3
  ),
  unioned as (
    select * from by_zone
    union all
    select * from global
  )
  select zone_id, product_id, companion_id, support, is_rx,
         row_number() over (partition by zone_id, product_id
                            order by support desc, companion_id)::int as rank
    from unioned
   where support >= v_min;

  delete from _cop_new where _cop_new.rank > v_top;

  -- Whole-table swap. The set is small (top-N per product per zone) and a
  -- partial rebuild would leave yesterday's pairs for a product that dropped
  -- below the floor today.
  delete from public.product_copurchase;
  insert into public.product_copurchase (zone_id, product_id, companion_id, support, rank, is_rx, built_at)
  select zone_id, product_id, companion_id, support, rank, is_rx, now() from _cop_new;

  get diagnostics v_rows = row_count;

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'min_support', v_min,
    'top_n', v_top,
    'zones', (select count(distinct zone_id) from public.product_copurchase),
    'products', (select count(distinct product_id) from public.product_copurchase));
end;
$function$;

-- ── substitute_candidates ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.substitute_candidates(p_product_id bigint, p_zone_id smallint DEFAULT NULL::smallint, p_customer_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m       public."MEDICINE"%rowtype;
  v_zone  smallint := p_zone_id;
  v_lim   int := coalesce(p_limit,
                   (select (value #>> '{}')::int from app_settings
                     where key = 'substitute_ask_max_options'), 3);
  v_units numeric;
  v_items jsonb;
begin
  select * into m from public."MEDICINE" where id = p_product_id;
  if m.id is null or not public.med_substitutable(p_product_id) then
    return jsonb_build_object('has', false, 'salt_key', '', 'items', '[]'::jsonb);
  end if;
  v_zone  := coalesce(v_zone, public.zone_default_id());
  v_units := nullif(regexp_replace(coalesce(m.pack_qty,''), '\D', '', 'g'), '')::numeric;

  with pool as (
    -- Bounded on purpose: the salt index hands back the same-salt shelf, and
    -- everything expensive below (zone standby, purchase history) only ever
    -- runs over that shelf, never over the 563k-row catalogue.
    select s.id, s.product_name, s.marketer, s.salt_composition,
           s.pack_type, s.pack_qty, s.pack_size, s.image_url_1,
           coalesce(s.supplier_count, 0) as supplier_count,
           coalesce(s.sales_count, 0)    as sales_count,
           nullif(regexp_replace(coalesce(s.pack_qty,''), '\D', '', 'g'), '')::numeric as units
      from public."MEDICINE" s
     where s.buyable is true
       and s.salt_composition = m.salt_composition
       and s.id <> m.id
       and public._norm_seg(s.pack_type) = public._norm_seg(m.pack_type)
       and public._norm_seg(s.marketer) <> public._norm_seg(coalesce(m.marketer,''))
     order by coalesce(s.sales_count, 0) desc, s.id
     limit 60
  ), zoned as (
    select p.*, public.medicine_zone_standby(p.id, v_zone) as zone_count
      from pool p
  ), live as (
    select z.* from zoned z
     where z.zone_count > 0 and public.med_substitutable(z.id)
  ), one_per_product as (
    -- ONE row per product+company. The catalogue is per pack; the customer is
    -- choosing a MEDICINE. Keep the pack nearest the original's strip size —
    -- that is the one substitute_equivalent_qty converts most cleanly.
    select distinct on (public._norm_seg(l.product_name), public._norm_seg(l.marketer)) l.*
      from live l
     order by public._norm_seg(l.product_name), public._norm_seg(l.marketer),
              case when v_units is null or l.units is null
                   then 999999 else abs(l.units - v_units) end,
              l.sales_count desc, l.id
  ), history as (
    select oi.product_id, count(*)::int as bought
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where p_customer_id is not null
       and o.customer_id = p_customer_id
       and oi.product_id in (select id from one_per_product)
     group by oi.product_id
  ), ranked as (
    select c.*, coalesce(h.bought, 0) as bought,
           row_number() over (order by coalesce(h.bought,0) desc,
                                       c.supplier_count desc,
                                       c.sales_count desc,
                                       c.id) as rnk
      from one_per_product c
      left join history h on h.product_id = c.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',  r.id,
           'name',        coalesce(r.product_name, ''),
           'company',     coalesce(r.marketer, ''),
           'strength',    coalesce(r.salt_composition, ''),
           'pack_label',  coalesce(nullif(btrim(r.pack_qty), ''),
                                   nullif(btrim(r.pack_type), ''),
                                   nullif(btrim(r.pack_size), ''), ''),
           'image',       coalesce(r.image_url_1, ''),
           'bought_before', (r.bought > 0),
           'rank',        r.rnk) order by r.rnk), '[]'::jsonb)
    into v_items
    from ranked r
   where r.rnk <= greatest(v_lim, 1);

  return jsonb_build_object(
    'has',      jsonb_array_length(v_items) > 0,
    'salt_key', coalesce(public.med_composition_key(m.salt_composition, '', m.pack_type), ''),
    'items',    v_items);
end $function$;

-- ── _product_detail_core ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._product_detail_core(p_product_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  m               record;
  v_imgs          jsonb;
  v_overview      jsonb;
  v_sections      jsonb;
  v_similar       jsonb := '[]'::jsonb;
  v_hist_qty      numeric;
  v_idx_ready     boolean;
  v_mrp           numeric;
  v_gst           text;
  v_labels        jsonb;
  v_acct          uuid;
  v_is_wishlisted boolean := false;
  v_trust         jsonb;
BEGIN
  v_labels := public.storefront_labels();

  SELECT * INTO m FROM "MEDICINE" WHERE id = p_product_id;
  IF m.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found', 'labels', v_labels);
  END IF;

  v_mrp := nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric;
  v_gst := nullif(replace(btrim(coalesce(m.gst_percent::text,'')), '%', ''), '');

  SELECT coalesce(jsonb_agg(u) FILTER (WHERE u IS NOT NULL AND u <> ''), '[]'::jsonb)
    INTO v_imgs
  FROM unnest(array[m.image_url_1, m.image_url_2, m.image_url_3, m.image_url_4, m.image_url_5]) u;

  SELECT coalesce(jsonb_agg(jsonb_build_object('label', l, 'value', val))
                  FILTER (WHERE nullif(btrim(val),'') IS NOT NULL), '[]'::jsonb)
    INTO v_overview
  FROM (VALUES
    ('Composition',       m.salt_composition),
    ('Manufacturer',      m.marketer),
    ('Therapeutic class', m.therapeutic_class),
    ('Chemical class',    m.chemical_class),
    ('Action class',      m.action_class),
    ('Storage',           m.storage),
    ('Habit forming',     m.habit_forming)
  ) t(l, val);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'title', ti,
           'body', btrim(regexp_replace(bo, 'show\s?more|show\s?less', '', 'gi'))))
         FILTER (WHERE nullif(btrim(bo),'') IS NOT NULL), '[]'::jsonb)
    INTO v_sections
  FROM (VALUES
    ('Introduction', m.product_introduction),
    ('Uses',         m.uses),
    ('Benefits',     m.benefits),
    ('Side effects', m.side_effects),
    ('How it works', m.how_it_works)
  ) t(ti, bo);

  -- Similar rail: same predicate as idx_medicine_salt_buyable partial index.
  v_idx_ready := to_regclass('public.idx_medicine_salt_buyable') IS NOT NULL;
  IF v_idx_ready AND nullif(btrim(m.salt_composition),'') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id',         s.id,
             'name',       coalesce(s.product_name,''),
             'company',    coalesce(s.marketer,''),
             'pack_label', coalesce(nullif(btrim(s.pack_type),''), nullif(btrim(s.pack_size),''), ''),
             'form_chip',  coalesce(nullif(btrim(s.pack_qty),''), nullif(btrim(s.pack_size),''), ''),
             'pack_type',  coalesce(s.pack_type,''),
             'pack_qty',   coalesce(s.pack_qty,''),
             'pack_size',  coalesce(s.pack_size,''),
             'image',      coalesce(s.image_url_1,''),
             'mrp_label',  coalesce(
               CASE WHEN nullif(regexp_replace(coalesce(s.mrp::text,''),'[^0-9.]','','g'),'') IS NOT NULL
                    THEN public.inr_money(nullif(regexp_replace(coalesce(s.mrp::text,''),'[^0-9.]','','g'),'')::numeric)
               END, ''))), '[]'::jsonb)
      INTO v_similar
    FROM (SELECT * FROM "MEDICINE" s
           WHERE s.salt_composition = m.salt_composition
             AND s.id <> m.id
             AND s.buyable IS TRUE
           ORDER BY s.sales_count DESC NULLS LAST LIMIT 10) s;
  END IF;

  -- History and wishlist are keyed to the ACCOUNT, never to auth.uid() directly.
  v_acct := public.my_customer_id();
  IF v_acct IS NOT NULL THEN
    SELECT sum(oi.quantity) INTO v_hist_qty
    FROM order_items oi
    WHERE oi.product_id = p_product_id
      AND oi.order_date >= current_date - 90
      AND oi.order_id IN (SELECT o.id FROM orders o WHERE o.customer_id = v_acct);

    -- Wishlist state for the current account.
    v_is_wishlisted := EXISTS (
      SELECT 1 FROM wishlist_items
      WHERE account_id = v_acct AND product_id = p_product_id
    );
  END IF;

  -- Row 177 — the trust strip. Fill rate and cold chain ONLY.
  -- No expiry promise anywhere: expiry and batch change with every purchase,
  -- so a minimum-expiry claim made before the stock is bought would be false.
  v_trust := public.product_trust_strip(p_product_id, m.cold_chain);

  RETURN jsonb_build_object(
    'ok',     true,
    'id',     m.id,
    'labels', v_labels,
    'header', jsonb_build_object(
      'name',        coalesce(m.product_name,''),
      'company',     coalesce(m.marketer,''),
      'pack_label',  coalesce(nullif(btrim(coalesce(m.pack_type,'')),''),
                              nullif(btrim(coalesce(m.pack_size,'')),''), ''),
      'form_chip',   coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),''), ''),
      'rx_required', (coalesce(m.rx_required::text,'') ILIKE '%yes%'
                      OR lower(coalesce(m.rx_required::text,'')) IN ('true','t','1')),
      'images',      v_imgs),
    'price', jsonb_build_object(
      'has_mrp',   (v_mrp IS NOT NULL),
      'mrp_label', coalesce(CASE WHEN v_mrp IS NOT NULL THEN public.inr_money(v_mrp) END, ''),
      'mrp_note',  'MRP',
      'has_gst',   (v_gst IS NOT NULL),
      'gst_label', coalesce(CASE WHEN v_gst IS NOT NULL THEN 'GST '||v_gst||'%' END, ''),
      'scheme',    (lower(coalesce(m.has_scheme::text,'')) IN ('true','t','yes','1'))),
    'availability', public.storefront_cta(public.storefront_effective_count(m.id, m.supplier_count)),
    'pricing',      public.storefront_pricing(v_mrp, null::numeric, p_product_id),
    -- CMD #1812: 1mg's scraped status is gone. Whether a pack can be bought is
    -- its zone standby (already inside `availability`); `buyable` here is the
    -- catalogue flag alone, and the supplier chip is an operator-only detail.
    'stock', jsonb_build_object(
      'buyable',            (m.buyable IS TRUE),
      'has_supplier_label', public.get_my_role() IN ('admin','super_admin')
                            AND (nullif(btrim(coalesce(m.supplier_label,'')),'') IS NOT NULL),
      'supplier_label',     CASE WHEN public.get_my_role() IN ('admin','super_admin')
                                 THEN coalesce(m.supplier_label,'') ELSE '' END),
    'trust',         v_trust,
    'overview',      v_overview,
    'has_highlight', (nullif(btrim(coalesce(m.product_highlight,'')),'') IS NOT NULL),
    'highlight',     coalesce(nullif(btrim(coalesce(m.product_highlight,'')),''), ''),
    'sections',      v_sections,
    'similar',       v_similar,
    'similar_ready', v_idx_ready,
    'show_wishlist', public.viewer_is_approved_customer(),
    'is_wishlisted', v_is_wishlisted,
    'my_history', jsonb_build_object(
      'has',   (v_hist_qty IS NOT NULL AND v_hist_qty > 0),
      'label', coalesce(CASE WHEN v_hist_qty IS NOT NULL AND v_hist_qty > 0
                             THEN 'You ordered '||v_hist_qty::bigint||' in the last 90 days'
                        END, '')));
END;
$function$;

-- ── storefront_page ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.storefront_page(category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT NULL::integer)
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
  rows AS (
    SELECT f.*, row_number() over () AS _ord FROM public.get_storefront_feed(
      category_filter, page_offset, (SELECT n FROM lim)) f
  ),
  -- CMD #791 — one scan of order_items for the whole page.
  ov AS (
    SELECT public.purchase_overlay_map(array(SELECT r.id FROM rows r)) AS m
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
        || jsonb_build_object('availability',
             public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count),
                                   true))
        || jsonb_build_object('pack_badge', public.sf_pack_badge(src.pack_qty, src.pack_size, src.pack_type))
        || jsonb_build_object('type_chip', coalesce(nullif(btrim(src.pack_type),''), nullif(btrim(src.pack_size),''), ''))
        || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
        || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
        || jsonb_build_object('gst_percent_resolved',
             coalesce(r.gst_percent, public.gst_rate_for(r.therapeutic_class)))
        || jsonb_build_object('pricing', public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id))
        || jsonb_build_object('purchase',
             coalesce((SELECT m -> r.id::text FROM ov), jsonb_build_object('has', false)))
        ORDER BY r._ord)
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id), '[]'::jsonb)
  );
$function$;

-- ── storefront_search_page ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.storefront_search_page(search_term text, category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT NULL::integer, p_zone boolean DEFAULT true)
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
                                        true))
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

-- ── storefront_gate ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.storefront_gate()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'gated', public.viewer_is_approved_customer(),
    'acting_as', public.my_acting_as(),
    'reason', case when public.my_acting_as() is not null then 'admin acting as a customer'
                   when public.viewer_is_approved_customer() then 'approved customer'
                   else 'signed out — catalogue-wide supplier truth, no zone' end,
    'rule', 'a product is available when its zone standby count is at least one — nothing else',
    'min_supplier_count', 1, 'field', 'supplier_count',
    'available', jsonb_build_object('is_available', true, 'can_add', true,
      'cta_label','Add to cart', 'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF')),
    'unavailable', jsonb_build_object('is_available', false, 'can_add', false,
      'cta_label','Unavailable',
      'note', public.uic('storefront.no_supplier_note','No supplier for this product right now'),
      'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF')),
    'blocked_add_message','This product has no supplier right now, so it cannot be ordered.');
$function$;

-- ── medicine_search_available ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.medicine_search_available(p_term text, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; t text := btrim(coalesce(p_term,''));
begin
  select coalesce(jsonb_agg(to_jsonb(m) || public.mrp_display_block(m.mrp) order by m.sales_count desc nulls last), '[]'::jsonb)
    into v from (
      select * from "MEDICINE"
       where (product_name ilike '%'||t||'%'
              or salt_composition ilike '%'||t||'%'
              or marketer ilike '%'||t||'%')
       order by sales_count desc nulls last
       limit greatest(1, least(coalesce(p_limit,20), 100))) m;
  return jsonb_build_object('rows', v, 'count', jsonb_array_length(v));
end $function$;

-- ── cart_availability ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.cart_availability()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- CHANGE #640 — `eff` is computed ONCE per line and every answer below reads
  -- it: the count on the row, the verdict, the unavailable tally and the
  -- blocking label. Before this the function read `m.supplier_count` raw while
  -- the storefront card for the same product read the zone truth, which is the
  -- contradiction a customer saw between adding an item and looking at it.
  WITH lines AS (
    SELECT ci.product_id, ci.product_name, ci.quantity,
           m.id AS mid,
           public.storefront_effective_count(m.id, m.supplier_count) AS eff
      FROM cart_items ci
      LEFT JOIN "MEDICINE" m ON m.id::text = ci.product_id
     WHERE (CASE
              WHEN coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id()) IS NOT NULL
                THEN ci.customer_id = coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id())
              ELSE ci.user_id = public.viewer_cart_user()
            END)
       AND (ci.removed_by_admin IS NULL OR ci.removed_by_admin = false)
  ), tally AS (
    SELECT count(*) FILTER (WHERE mid IS NOT NULL AND coalesce(eff,0) < 1) AS bad,
           count(*) FILTER (WHERE mid IS NULL)                             AS unresolved
      FROM lines
  )
  SELECT jsonb_build_object(
    'gated', public.viewer_is_approved_customer(),
    'acting_as', public.my_acting_as(),
    'cart_user', public.viewer_cart_user(),
    'unavailable_count', t.bad,
    'unresolved_count',  t.unresolved,
    'items', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'product_id', l.product_id, 'product_name', l.product_name,
                 'quantity', l.quantity,
                 'supplier_count', l.eff,
                 'resolved', (l.mid IS NOT NULL),
                 'availability', public.storefront_cta(l.eff, (l.mid IS NOT NULL)))
               ORDER BY l.product_name)
          FROM lines l), '[]'::jsonb),
    'blocking_label', CASE WHEN public.viewer_is_approved_customer() AND t.bad > 0
                           THEN t.bad::text || ' item(s) in this cart have no supplier and will be removed'
                      END,
    'unresolved_note', CASE WHEN t.unresolved > 0
                            THEN t.unresolved::text || ' item(s) could not be checked and were kept' END)
  FROM tally t;
$function$;

-- ── _cat_where ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._cat_where(p_kind text, p_key text, p_path text[], p_filters jsonb)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare w text := 'true'; v text; q text;
begin
  if p_kind = 'tree' then
    if coalesce(array_length(p_path,1),0) >= 1 then
      w := w || format(' and m.therapeutic_class = %L', p_path[1]); end if;
    if coalesce(array_length(p_path,1),0) >= 2 then
      w := w || format(' and m.chemical_class = %L', p_path[2]); end if;
    if coalesce(array_length(p_path,1),0) >= 3 then
      w := w || format(' and m.action_class = %L', p_path[3]); end if;
  elsif p_kind = 'company' then
    w := w || format(' and m.marketer_canonical = %L', coalesce(p_key,''));
  elsif p_kind = 'salt' then
    w := w || format(' and m.salt_composition = %L', coalesce(p_key,''));
  elsif p_kind = 'search' then
    q := public._norm_name(coalesce(p_key,''));
    if coalesce(q,'') = '' then
      w := w || ' and false';
    else
      w := w || format(
        ' and public._norm_name(m.product_name) operator(pg_catalog.~>=~) %L'
        || ' and public._norm_name(m.product_name) operator(pg_catalog.~<~) %L',
        q, left(q, length(q)-1) || chr(ascii(right(q,1)) + 1));
    end if;
  elsif p_kind = 'tab' then
    -- Written as the bare boolean, not coalesce(...,false): the partial
    -- indexes below are declared `where has_scheme` / `where cold_chain`, and a
    -- coalesce wrapper stops the planner matching them (4.2 s vs 3 ms).
    if p_key = 'schemes'    then w := w || ' and m.has_scheme';
    elsif p_key = 'cold_chain' then w := w || ' and m.cold_chain';
    end if;
  end if;

  if coalesce(jsonb_array_length(p_filters->'pack_type'),0) > 0 then
    select string_agg(format('%L', x), ',') into v
      from jsonb_array_elements_text(p_filters->'pack_type') x;
    w := w || format(' and m.pack_type in (%s)', v);
  end if;
  if (p_filters->>'rx') in ('Rx','OTC') then
    w := w || format(' and upper(btrim(coalesce(m.rx_required,''''))) = %L', upper(p_filters->>'rx'));
  end if;
  if (p_filters->>'habit_forming') = 'true' then
    w := w || ' and upper(btrim(coalesce(m.habit_forming,''''))) = ''YES''';
  end if;
  if (p_filters->>'cold_chain') = 'true' then w := w || ' and m.cold_chain'; end if;
  -- has_image reads image_url_1, not the has_image boolean: the boolean is true
  -- on 4,095 rows while 252,760 actually carry a photo, and this filter has to
  -- agree with the picture the grid draws.
  if (p_filters->>'has_image') = 'true' then
    w := w || ' and m.image_url_1 is not null and btrim(m.image_url_1) <> ''''';
  end if;
  if (p_filters->>'has_scheme') = 'true' then w := w || ' and m.has_scheme'; end if;
  return w;
end $function$;

-- ── catalogue_cache_tick ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.catalogue_cache_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  u record; v_code text; v_t0 timestamptz := clock_timestamp(); v_rows bigint := 0;
  v_where text; v_join text;
begin
  select * into u from public.catalogue_refresh_unit
   where state = 'pending' order by ord limit 1 for update skip locked;

  if u.ord is null then
    update public.catalogue_refresh_state
       set cycle_ended = coalesce(cycle_ended, now()),
           last_note   = 'idle — every unit done'
     where id = 1;
    return jsonb_build_object('ok', true, 'idle', true);
  end if;

  -- CHANGE #790 — the typeahead cache rides the same bounded tick. Its work
  -- lives in search_suggest_unit() so this dispatcher stays a dispatcher.
  if u.kind like 'suggest%' then
    v_rows := public.search_suggest_unit(u.kind, coalesce(u.arg,''), coalesce(u.arg2,''));

  elsif u.kind = 'zone_scan' then
    select code into v_code from public.zones where id = u.zone_id;
    if v_code is null then
      update public.catalogue_refresh_unit set state='done', ran_at=now(),
             last_error='unknown zone' where ord = u.ord;
      return jsonb_build_object('ok', true, 'skipped', 'unknown_zone');
    end if;
    -- The first range of a zone clears its staging rows: a cycle never mixes
    -- two sweeps, and a re-run of the same unit is a silent no-op.
    if u.arg::bigint = (select min(arg::bigint) from public.catalogue_refresh_unit
                         where kind='zone_scan' and zone_id = u.zone_id) then
      delete from public.catalogue_zone_avail_stage where zone_id = u.zone_id;
    end if;
    execute format($q$
      insert into public.catalogue_zone_avail_stage(zone_id, product_id)
      select %1$L::smallint, m.id
        from public."MEDICINE" m
       where m.id between %2$L::bigint and %3$L::bigint
         and (cardinality(m.%4$I) > 0 or cardinality(m.%5$I) > 0)
         and cardinality(public.medicine_zone_effective(m.%4$I, m.%5$I, m.%6$I, m.%7$I)) > 0
      on conflict do nothing
    $q$, u.zone_id, u.arg, u.arg2,
        'z_'||v_code||'_sup', 'z_'||v_code||'_av',
        'z_'||v_code||'_oos', 'z_'||v_code||'_nostock');
    get diagnostics v_rows = row_count;

  elsif u.kind = 'zone_swap' then
    -- The exchange. Narrow table, two statements, one transaction: a shopper
    -- either sees the old list or the new one, never half of either.
    delete from public.catalogue_zone_avail where zone_id = u.zone_id;
    insert into public.catalogue_zone_avail(zone_id, product_id)
      select zone_id, product_id from public.catalogue_zone_avail_stage
       where zone_id = u.zone_id;
    get diagnostics v_rows = row_count;
    delete from public.catalogue_zone_avail_stage where zone_id = u.zone_id;

  elsif u.kind = 'facet' then
    -- zone 0 is the whole catalogue; a real zone joins the materialised list.
    if u.zone_id = 0 then
      v_join := '';
    else
      v_join := format('join public.catalogue_zone_avail za on za.product_id = m.id and za.zone_id = %L::smallint', u.zone_id);
    end if;
    v_where := 'true';

    -- 'meta' writes two facets, so it clears two. Re-running any unit is a
    -- clean rewrite of exactly what it owns and nothing else.
    delete from public.catalogue_facet_count
     where zone_id = u.zone_id
       and facet = any (case when u.arg = 'meta' then array['meta','pack_type'] else array[u.arg] end);

    if u.arg = 'therapeutic' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'therapeutic', %1$L::smallint, '', m.therapeutic_class, m.therapeutic_class,
               upper(left(m.therapeutic_class,1)), count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.therapeutic_class),'') is not null
         group by 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'chemical' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'chemical', %1$L::smallint, m.therapeutic_class, m.chemical_class,
               m.chemical_class, upper(left(m.chemical_class,1)), count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.therapeutic_class),'') is not null
           and nullif(btrim(m.chemical_class),'') is not null
         group by 3, 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'action' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'action', %1$L::smallint,
               public.catalogue_parent_key(m.therapeutic_class, m.chemical_class),
               m.action_class, m.action_class,
               upper(left(m.action_class,1)), count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.therapeutic_class),'') is not null
           and nullif(btrim(m.chemical_class),'') is not null
           and nullif(btrim(m.action_class),'') is not null
         group by 3, 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'company' then
      -- The company's PRINTED name is medicine_company.display (#430's registry),
      -- never the raw marketer text and never a name this migration invents.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'company', %1$L::smallint, '', m.marketer_canonical,
               coalesce(mc.display, m.marketer_canonical),
               case when upper(left(coalesce(mc.display, m.marketer_canonical),1)) between 'A' and 'Z'
                    then upper(left(coalesce(mc.display, m.marketer_canonical),1)) else '#' end,
               count(*)
          from public."MEDICINE" m %2$s
          left join public.medicine_company mc on mc.canon = m.marketer_canonical
         where %3$s and nullif(btrim(m.marketer_canonical),'') is not null
         group by 4, 5, 6
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'salt' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'salt', %1$L::smallint, '', m.salt_composition, m.salt_composition,
               case when upper(left(m.salt_composition,1)) between 'A' and 'Z'
                    then upper(left(m.salt_composition,1)) else '#' end,
               count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.salt_composition),'') is not null
         group by 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'meta' then
      -- The numbers the Catalogue TAB BAR prints, and the pack-type filter's
      -- own vocabulary. Both were live scans in the first draft: rendering the
      -- tab bar cost `select distinct pack_type from "MEDICINE"` — 10.2 s on
      -- this instance — which is the exact thing the spec forbids. They are
      -- rows now, so the landing screen is six point lookups.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'meta', %1$L::smallint, '', 'total', 'total', '', count(*)
          from public."MEDICINE" m %2$s where %3$s
        union all
        select 'meta', %1$L::smallint, '', 'companies', 'companies', '',
               count(*) from public.catalogue_facet_count
                where facet = 'company' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'salts', 'salts', '',
               count(*) from public.catalogue_facet_count
                where facet = 'salt' and zone_id = %1$L::smallint
      $q$, u.zone_id, v_join, v_where);
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'pack_type', %1$L::smallint, '', m.pack_type, m.pack_type, '', count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.pack_type),'') is not null
         group by 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'tab' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'tab', %1$L::smallint, '', t.k, t.k, '', t.c from (
          select 'schemes' as k, count(*) filter (where coalesce(m.has_scheme,false)) as c
            from public."MEDICINE" m %2$s where %3$s
          union all
          select 'cold_chain', count(*) filter (where coalesce(m.cold_chain,false))
            from public."MEDICINE" m %2$s where %3$s
        ) t
      $q$, u.zone_id, v_join, v_where);
    end if;
    get diagnostics v_rows = row_count;
  end if;

  update public.catalogue_refresh_unit
     set state = 'done', ran_at = now(), rows_seen = v_rows,
         ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::int,
         last_error = null
   where ord = u.ord;

  update public.catalogue_refresh_state
     set last_note = u.kind || ' ' || coalesce(nullif(u.arg,''), 'zone ' || u.zone_id)
                     || ' → ' || v_rows || ' rows'
   where id = 1;

  return jsonb_build_object('ok', true, 'ord', u.ord, 'kind', u.kind,
    'zone', u.zone_id, 'arg', u.arg, 'rows', v_rows,
    'left', (select count(*) from public.catalogue_refresh_unit where state = 'pending'));
exception when others then
  update public.catalogue_refresh_unit
     set state = 'done', ran_at = now(), last_error = left(sqlerrm, 400)
   where ord = u.ord;
  return jsonb_build_object('ok', false, 'ord', u.ord, 'error', left(sqlerrm, 400));
end $function$;

-- ── search_suggest_unit ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.search_suggest_unit(p_kind text, p_arg text DEFAULT ''::text, p_arg2 text DEFAULT ''::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rows bigint := 0;
  v_bucket int;
  v_facet text;
begin
  if p_kind = 'suggest_reset' then
    delete from public.search_suggest_stage;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_brand' then
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select 'brand', g.root || '|' || coalesce(g.mc, ''), p_arg, g.label,
           coalesce(mc.display, g.mc, ''), g.n, g.rank, g.root, '{}'::smallint[], g.label
      from (
        select b.root, b.mc,
               (array_agg(b.product_name order by b.nlen, b.sales_count desc nulls last, b.id))[1] as label,
               count(*)::int as n,
               coalesce(sum(b.sales_count), 0)::bigint as rank
          from (
            select m.id, m.product_name, m.marketer_canonical as mc, m.sales_count,
                   public._brand_root(m.product_name) as root,
                   length(public._norm_name(m.product_name)) as nlen
              from public."MEDICINE" m
             where m.id between p_arg::bigint and p_arg2::bigint
               and true
               and nullif(btrim(m.product_name), '') is not null
          ) b
         group by b.root, b.mc
      ) g
      left join public.medicine_company mc on mc.canon = g.mc
    on conflict (kind, key, src) do update
      set n = excluded.n, rank = excluded.rank, label = excluded.label,
          sub_label = excluded.sub_label, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_zone' then
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    with fam as (
      select distinct public.brand_family_key(m.product_name, m.marketer_canonical) as key
        from public.catalogue_zone_avail za
        join public."MEDICINE" m on m.id = za.product_id
       where za.zone_id = v_bucket::smallint
    )
    update public.search_suggest_stage s
       set zones = (select coalesce(array_agg(distinct z order by z), '{}'::smallint[])
                      from unnest(s.zones || array[v_bucket::smallint]) z)
      from fam
     where s.kind = 'brand' and s.key = fam.key
       and not (s.zones @> array[v_bucket::smallint]);
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_facet' then
    -- CHANGE #790E — the zone list is aggregated ONCE, keyed by facet_key, and
    -- joined. The old shape ran one correlated subquery per row: 106,571 of
    -- them for salts, which never finished inside the statement cap.
    v_facet := case p_arg when 'category' then 'therapeutic' else p_arg end;
    with zone_of as (
      select z.facet_key,
             array_agg(distinct z.zone_id order by z.zone_id) as zones
        from public.catalogue_facet_count z
       where z.facet = v_facet
         and z.zone_id > 0
       group by z.facet_key
    )
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select p_arg, c.facet_key, '', c.label, '', c.n, c.n::bigint,
           public._norm_name(c.label),
           coalesce(zo.zones, '{}'::smallint[]),
           c.label
      from public.catalogue_facet_count c
      left join zone_of zo on zo.facet_key = c.facet_key
     where c.zone_id = 0
       and c.facet = v_facet
       and nullif(btrim(c.label), '') is not null
    on conflict (kind, key, src) do update
      set label = excluded.label, n = excluded.n, rank = excluded.rank,
          norm = excluded.norm, zones = excluded.zones, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_swap' then
    -- CHANGE #790E — this statement never once succeeded. `zones` is
    -- smallint[], so array_agg(s.zones) is smallint[][] and subscripting it
    -- with [1] yields a scalar smallint, which the column refuses:
    --   ERROR: column "zones" is of type smallint[] but expression is of
    --          type smallint
    -- The swap is the ONLY writer of search_suggest_cache, so the cache stayed
    -- empty and every typeahead answer was empty with it — the whole feature
    -- was dead on arrival and nothing said so, because catalogue_cache_tick()
    -- records the unit's error and moves on.
    -- A family that appears in several id ranges is available in the UNION of
    -- the zones those ranges saw, so the zones are unnested and re-aggregated
    -- rather than picked from one row.
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    delete from public.search_suggest_cache c
     where abs(hashtext(c.key)) % 6 = v_bucket;
    with src as (
      select s.* from public.search_suggest_stage s
       where abs(hashtext(s.key)) % 6 = v_bucket
    ),
    pick as (
      select s.kind, s.key,
             (array_agg(s.label     order by length(s.label), s.src))[1] as label,
             (array_agg(s.sub_label order by length(s.label), s.src))[1] as sub_label,
             sum(s.n)::int    as n,
             sum(s.rank)::bigint as rank,
             (array_agg(s.norm  order by length(s.label), s.src))[1] as norm,
             (array_agg(s.query order by length(s.label), s.src))[1] as query
        from src s group by s.kind, s.key
    ),
    zed as (
      select s.kind, s.key,
             coalesce(array_agg(distinct zz order by zz)
                        filter (where zz is not null), '{}'::smallint[]) as zones
        from src s
        left join lateral unnest(s.zones) zz on true
       group by s.kind, s.key
    )
    insert into public.search_suggest_cache(kind, key, label, sub_label, n, rank, norm, zones, query)
    select p.kind, p.key, p.label, p.sub_label, p.n, p.rank, p.norm,
           coalesce(z.zones, '{}'::smallint[]), p.query
      from pick p
      left join zed z on z.kind = p.kind and z.key = p.key
    on conflict (kind, key) do update
      set label = excluded.label, sub_label = excluded.sub_label, n = excluded.n,
          rank = excluded.rank, norm = excluded.norm, zones = excluded.zones,
          query = excluded.query;
    get diagnostics v_rows = row_count;
  end if;

  return v_rows;
end $function$;

-- ── admin_write_medicines ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_write_medicines(p_rows jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role   text := coalesce(public.get_my_role(),'none');
  v_allowed text[];
  r        jsonb;
  v_id     bigint;
  v_data   jsonb;
  v_key    text;
  v_val    text;
  v_cols   text[];
  v_vals   text[];
  v_set    text;
  n_ins int := 0; n_upd int := 0; n_skip int := 0;
begin
  if v_role not in ('admin','super_admin') then
    raise exception 'not authorized';
  end if;

  -- Settable columns = every MEDICINE column except identity / computed / system.
  select array_agg(column_name) into v_allowed
  from information_schema.columns
  where table_schema='public' and table_name='MEDICINE'
    and column_name not in (
      'id','_row_id','buyable','supplier_count','supplier_label',
      'tm_id','marketer_canonical','data_source','marketer_raw_backup',
      'z_rpr_sup','z_rpr_oos','z_rpr_nostock','z_blp_sup','z_blp_oos',
      'z_blp_nostock','z_rpr_av','z_blp_av');

  for r in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb))
  loop
    begin
      v_id   := nullif(r->>'id','')::bigint;
      v_data := coalesce(r->'data','{}'::jsonb);
      v_cols := array[]::text[];
      v_vals := array[]::text[];

      for v_key, v_val in select key, value from jsonb_each_text(v_data)
      loop
        if v_key = any(v_allowed) and coalesce(v_val,'') <> '' then
          v_cols := v_cols || v_key;
          v_vals := v_vals || v_val;
        end if;
      end loop;

      if v_id is not null then
        -- UPDATE existing
        if array_length(v_cols,1) is null then continue; end if;
        v_set := (select string_agg(format('%I = %L', v_cols[i], v_vals[i]), ', ')
                  from generate_subscripts(v_cols,1) i);
        execute format('update public."MEDICINE" set %s where id = %L', v_set, v_id);
        n_upd := n_upd + 1;
      else
        -- INSERT new (same fixed defaults the client used, unless already mapped)
        if not ('sales_count' = any(v_cols)) then v_cols := v_cols||'sales_count'; v_vals := v_vals||'0';         end if;
        if not ('has_scheme'  = any(v_cols)) then v_cols := v_cols||'has_scheme';  v_vals := v_vals||'false';     end if;
        if not ('has_image'   = any(v_cols)) then v_cols := v_cols||'has_image';   v_vals := v_vals||'false';     end if;
        execute format('insert into public."MEDICINE" (%s) values (%s)',
          (select string_agg(format('%I', v_cols[i]), ', ') from generate_subscripts(v_cols,1) i),
          (select string_agg(format('%L', v_vals[i]), ', ') from generate_subscripts(v_cols,1) i));
        n_ins := n_ins + 1;
      end if;
    exception when others then
      n_skip := n_skip + 1;
    end;
  end loop;

  return jsonb_build_object('inserted', n_ins, 'updated', n_upd, 'skipped', n_skip);
end $function$;

-- Grants lost with the DROPped signatures.
GRANT EXECUTE ON FUNCTION public.storefront_cta(integer, boolean) TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_storefront_feed(text, integer, integer) TO PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_medicines_priority(text, text, integer, integer, boolean) TO PUBLIC, anon, authenticated, service_role;

-- The two views project the MEDICINE row verbatim, so they pin the columns.
-- CREATE OR REPLACE cannot drop a column from a view — it has to be rebuilt.
DROP VIEW IF EXISTS public.medicine_browse;
DROP VIEW IF EXISTS public.v_medicine_dedup;
CREATE OR REPLACE VIEW public.medicine_browse AS
 SELECT url,
    product_name,
    salt_composition,
    marketer,
    rx_required,
    image_url_1,
    image_url_2,
    image_url_3,
    image_url_4,
    image_url_5,
    image_count,
    storage,
    mrp,
    pack_size,
    pack_qty,
    pack_type,
    scrapping_status,
    uses,
    benefits,
    side_effects,
    how_it_works,
    habit_forming,
    therapeutic_class,
    chemical_class,
    action_class,
    product_introduction,
    product_highlight,
    id,
    _row_id,
    sales_count,
    has_scheme,
    has_image,
    gst_percent,
    NULL::text AS "PS1",
    NULL::text AS "PS2",
    NULL::text AS "PS3",
    NULL::text AS "PS4",
    NULL::text AS "PS5",
    NULL::text AS "PS6",
    NULL::text AS "PS7",
    NULL::text AS "PS8",
    NULL::text AS "PS9",
    NULL::text AS "PS10",
    NULL::text AS "PS11",
    NULL::text AS "PS12",
    NULL::text AS "PS13",
    NULL::text AS "PS14",
    NULL::text AS "PS15",
    NULL::text AS "PS16",
    NULL::text AS "PS17",
    NULL::text AS "PS18",
    NULL::text AS "PS19",
    NULL::text AS "PS20",
    NULL::text AS "PS21",
    NULL::text AS "PS22",
    NULL::text AS "PS23",
    NULL::text AS "PS24",
    NULL::text AS "PS25",
    NULL::text AS "PS26",
    NULL::text AS "PS27",
    NULL::text AS "PS28",
    NULL::text AS "PS29",
    NULL::text AS "PS30",
    buyable,
    md5(id::text) AS browse_rank
   FROM "MEDICINE" m;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.medicine_browse TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW public.v_medicine_dedup AS
 SELECT DISTINCT ON (((lower(regexp_replace(COALESCE(product_name, ''::text), '[^a-z0-9]'::text, ''::text, 'g'::text)) || '|'::text) || lower(regexp_replace(COALESCE(pack_size, ''::text), '[^a-z0-9]'::text, ''::text, 'g'::text)))) url,
    product_name,
    salt_composition,
    marketer,
    rx_required,
    image_url_1,
    image_url_2,
    image_url_3,
    image_url_4,
    image_url_5,
    image_count,
    storage,
    mrp,
    pack_size,
    pack_qty,
    pack_type,
    scrapping_status,
    uses,
    benefits,
    side_effects,
    how_it_works,
    habit_forming,
    therapeutic_class,
    chemical_class,
    action_class,
    product_introduction,
    product_highlight,
    id,
    _row_id,
    sales_count,
    has_scheme,
    has_image,
    gst_percent,
    NULL::text AS "PS1",
    NULL::text AS "PS2",
    NULL::text AS "PS3",
    NULL::text AS "PS4",
    NULL::text AS "PS5",
    NULL::text AS "PS6",
    NULL::text AS "PS7",
    NULL::text AS "PS8",
    NULL::text AS "PS9",
    NULL::text AS "PS10",
    NULL::text AS "PS11",
    NULL::text AS "PS12",
    NULL::text AS "PS13",
    NULL::text AS "PS14",
    NULL::text AS "PS15",
    NULL::text AS "PS16",
    NULL::text AS "PS17",
    NULL::text AS "PS18",
    NULL::text AS "PS19",
    NULL::text AS "PS20",
    NULL::text AS "PS21",
    NULL::text AS "PS22",
    NULL::text AS "PS23",
    NULL::text AS "PS24",
    NULL::text AS "PS25",
    NULL::text AS "PS26",
    NULL::text AS "PS27",
    NULL::text AS "PS28",
    NULL::text AS "PS29",
    NULL::text AS "PS30",
    buyable,
    data_source,
    marketer_canonical,
    tm_id,
    supplier_count,
    supplier_label
   FROM "MEDICINE"
  ORDER BY ((lower(regexp_replace(COALESCE(product_name, ''::text), '[^a-z0-9]'::text, ''::text, 'g'::text)) || '|'::text) || lower(regexp_replace(COALESCE(pack_size, ''::text), '[^a-z0-9]'::text, ''::text, 'g'::text))), (NULLIF(btrim(COALESCE(mrp, ''::text)), ''::text) IS NULL), product_name, pack_size;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.v_medicine_dedup TO anon, authenticated, service_role;
