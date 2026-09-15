-- CMD #2026 — the storefront search box: multi-word typing, the icon swap, and
-- no category chip row above search results.
--
-- What moves into the backend here:
--   1. `search_page().search_bar` — the box, described: the minimum characters
--      before a query is worth asking for, the debounce, WHICH buttons sit on
--      the right of the field in each state (empty → scan + mic, typing → one
--      ×) and whether the chip row may sit above RESULTS (it may not). The app
--      had all four as Dart constants.
--   2. `search_medicines_priority` — a multi-word query is a set of REQUIRED
--      tokens in ANY order. "telmed ah tablet" and "ah telmed" are the same
--      search; a pack missing one of the typed words is not a result.
-- Idempotent: every statement is safe to replay on live.

-- ── 1. copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('search.clear', '"Clear search"'::jsonb)
on conflict (key) do nothing;

insert into public.app_settings (key, value) values
  ('search_min_chars',   '2'::jsonb),
  ('search_debounce_ms', '250'::jsonb)
on conflict (key) do nothing;

-- The buttons are DATA: one UPDATE reorders them, drops one or adds a third,
-- with no deploy. `state` is which half of the swap the button belongs to —
-- 'empty' (nothing typed) or 'typing' (any text at all). The × is LAST in the
-- typing list because the list is drawn in order and it owns the far right.
insert into public.app_settings (key, value) values
  ('search_bar_actions', '[
     {"kind":"scan","state":"empty","icon":"scan","copy_key":"storefront.scan_button"},
     {"kind":"mic","state":"empty","icon":"mic","copy_key":"storefront.mic_button"},
     {"kind":"clear","state":"typing","icon":"close","copy_key":"search.clear"}
   ]'::jsonb)
on conflict (key) do nothing;

-- ── 2. the bar block, added to the ONE payload the box already reads ───────
-- A separate RPC would have been a second round trip for a box that is already
-- holding a `search_page()` answer, and the app caches that payload for the
-- offline first paint — the bar rides along for free.
create or replace function public.search_bar_block()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'placeholder', public.uic('search.placeholder','Search medicines, salts, companies'),
    'min_chars',   greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'search_min_chars'), 2), 1),
    'debounce_ms', greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'search_debounce_ms'), 250), 0),
    'actions', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind',  a->>'kind',
               'state', a->>'state',
               'icon',  a->>'icon',
               'label', public.uic(a->>'copy_key',''))
             order by ord), '[]'::jsonb)
        from jsonb_array_elements(
               coalesce((select value from public.app_settings
                           where key = 'search_bar_actions'), '[]'::jsonb))
             with ordinality t(a, ord)),
    -- CMD #2026 §3 — results start directly under the search bar. WHICH
    -- surface draws the row with an EMPTY box stays `chip_row_surfaces`
    -- (CMD #2011 kept Home on that list and left the Catalogue off it).
    'chip_row_on_results', false
  );
$function$;

revoke all on function public.search_bar_block() from public;
grant execute on function public.search_bar_block() to anon, authenticated, service_role;

comment on function public.search_bar_block() is
  'CMD #2026 — the search box described by the backend (min chars, debounce, the '
  'right-hand buttons per state, the chip-row-on-results rule). Rides inside '
  'search_page().search_bar; anon on purpose, the storefront search is public.';

-- ── 3. search_page(): carry the bar block ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.search_page(p_q text, p_filters jsonb DEFAULT '{}'::jsonb, p_page integer DEFAULT 0, p_page_size integer DEFAULT NULL::integer, p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_f       jsonb   := coalesce(p_filters, '{}'::jsonb);
  v_q       text    := btrim(coalesce(p_q, ''));
  v_cat     text    := coalesce(nullif(btrim(coalesce(v_f->>'category','')),''), 'All');
  v_sort    text    := case when coalesce(v_f->>'sort','relevance') in ('name','newest','relevance')
                            then coalesce(v_f->>'sort','relevance') else 'relevance' end;
  v_size    int;
  v_page    int     := greatest(coalesce(p_page, 0), 0);
  v_off     int;
  v_zone    smallint := public._cat_avail_zone();
  v_pct     numeric  := public.my_cart_discount_pct();
  v_filtered boolean := coalesce(public._search_filtered(v_f), false);
  v_typed   boolean  := v_q <> '';
  v_total   int := 0;
  v_ids     bigint[] := '{}'::bigint[];
  v_got     int := 0;
  -- ── CMD #1906, QA round 1: THE CANDIDATE SCAN IS BOUNDED ────────────────
  -- search_medicines_priority was called with page_limit => null, so a broad
  -- term ranked and materialised EVERY match before paging 30 of them. As
  -- anon that is a 3-second statement budget (the storefront cap) spent on
  -- rows nobody asked for: hostile QA measured search_page('paracetamol')
  -- at HTTP 500 / 57014 in 3.11s on live, i.e. the single most common search
  -- in an Indian pharmacy returned a Retry screen. The scan is capped, the
  -- cap is a setting rather than a constant, and the total says "1,200+"
  -- when it is hit so the count stays honest.
  v_scan_cap int := greatest(coalesce((select (value #>> '{}')::int
                       from public.app_settings where key = 'search_scan_cap'), 1200), 60);
  v_cap     int;
  v_capped  boolean := false;
  v_count_label text := '';
  v_uid     uuid := auth.uid();
  v_rail    jsonb := jsonb_build_object('has', false, 'items', '[]'::jsonb);
  v_empty   text;
  v_hint    text := '';
  v_request boolean := false;
  v_buttons jsonb := '[]'::jsonb;
  v_pack    text[] := '{}'::text[];
  v_rx      text   := upper(coalesce(v_f->>'rx',''));
begin
  select greatest(coalesce(nullif(p_page_size, 0),
           coalesce((select (value #>> '{}')::int from public.app_settings
                       where key = 'search_initial_limit'), 30)), 1)
    into v_size;
  v_size := least(v_size, 60);
  v_off  := v_page * v_size;

  -- Filters are applied AFTER the ranking pass, so a filtered search has to
  -- look at more candidates to fill the same page. Both cases stay bounded,
  -- and the cap never falls below the window actually asked for.
  v_cap := greatest(v_off + v_size,
                    case when v_filtered then v_scan_cap * 4 else v_scan_cap end);

  if coalesce(jsonb_array_length(v_f->'pack_type'),0) > 0 then
    select array_agg(x) into v_pack from jsonb_array_elements_text(v_f->'pack_type') x;
  end if;

  -- ── the ranked, filtered scope ──────────────────────────────────────────
  -- ONE ranking pass through search_medicines_priority: the tiering, the
  -- dedup, the zone standby tiebreak and the anonymous behaviour are all
  -- exactly what Home's search has always used. Everything below only
  -- NARROWS and ORDERS what it returned.
  if v_typed then
    -- ONE statement: the ranked scope, its total and the requested window.
    -- A second pass through search_medicines_priority would have doubled the
    -- cost of every search, and anon gets 3 seconds for the whole call.
    -- Relevance is the default and the overwhelming majority of searches,
    -- and in relevance order the window is just the first rows of `hit` —
    -- no second pass over "MEDICINE" to sort by a column nobody sorted on.
    if v_sort = 'relevance' then
      with hit as materialized (
      select r.rn, r.id
        from (select s.id, row_number() over () as rn
                from public.search_medicines_priority(v_q, v_cat, 0, v_cap, p_zone) s) r
        join "MEDICINE" m on m.id = r.id
       where (v_pack = '{}'::text[] or m.pack_type = any(v_pack))
         and (v_rx not in ('RX','OTC')
              or upper(btrim(coalesce(m.rx_required,''))) = v_rx)
         and ((v_f->>'habit_forming') is distinct from 'true'
              or upper(btrim(coalesce(m.habit_forming,''))) = 'YES')
         and ((v_f->>'cold_chain') is distinct from 'true' or m.cold_chain)
         and ((v_f->>'has_image') is distinct from 'true'
              or (m.image_url_1 is not null and btrim(m.image_url_1) <> ''))
         and ((v_f->>'has_scheme') is distinct from 'true' or m.has_scheme)),
      pg as (select h.id, h.rn as o from hit h order by h.rn offset v_off limit v_size)
      select (select count(*)::int from hit),
             coalesce((select array_agg(pg.id order by pg.o) from pg), '{}'::bigint[])
        into v_total, v_ids;
    else
      with hit as materialized (
      select r.rn, r.id
        from (select s.id, row_number() over () as rn
                from public.search_medicines_priority(v_q, v_cat, 0, v_cap, p_zone) s) r
        join "MEDICINE" m on m.id = r.id
       where (v_pack = '{}'::text[] or m.pack_type = any(v_pack))
         and (v_rx not in ('RX','OTC')
              or upper(btrim(coalesce(m.rx_required,''))) = v_rx)
         and ((v_f->>'habit_forming') is distinct from 'true'
              or upper(btrim(coalesce(m.habit_forming,''))) = 'YES')
         and ((v_f->>'cold_chain') is distinct from 'true' or m.cold_chain)
         and ((v_f->>'has_image') is distinct from 'true'
              or (m.image_url_1 is not null and btrim(m.image_url_1) <> ''))
         and ((v_f->>'has_scheme') is distinct from 'true' or m.has_scheme)),
      ord as (
        select h.id,
               row_number() over (order by
                 case when v_sort = 'name'   then public._norm_name(m.product_name) end asc,
                 case when v_sort = 'newest' then m.created_at end desc nulls last,
                 h.rn asc) as o
          from hit h join "MEDICINE" m on m.id = h.id
      ),
      pg as (select id, o from ord order by o offset v_off limit v_size)
      select (select count(*)::int from hit),
             coalesce((select array_agg(pg.id order by pg.o) from pg), '{}'::bigint[])
        into v_total, v_ids;
    end if;
    v_got    := coalesce(array_length(v_ids,1), 0);
    v_capped := v_total >= v_cap;
  end if;

  -- The count the shopper reads. When the scan cap was reached the total is a
  -- floor, not a count, and it is WORDED as one — never a number that claims
  -- to be exact. Both strings come from ui_copy.
  v_count_label := case when v_typed then
      case when v_capped
           -- {n} is the NUMBER, not cat_count_label's finished phrase: the
           -- plus belongs to the figure ("1,200+ products"), never after the
           -- noun ("1,200 products+"). Indian digit grouping either way, and
           -- a capped total is always well past 1, so the plural is safe.
           then replace(public.uic('search.count_capped','{n}+ products'),
                        '{n}', to_char(v_total, 'FM9,99,99,999'))
           else public.cat_count_label(v_total::bigint) end
    else '' end;

  -- ── the idle rail (CMD #2010) ───────────────────────────────────────────
  -- With nothing typed the surface is not blank: it offers what this shopper
  -- already buys. The BACKEND picks which rail and words its title — Flutter
  -- renders whichever one arrives. A typed query never pays for it.
  if not v_typed and v_page = 0 then
    v_rail := public.search_idle_rail();
  end if;

  -- ── the empty state, identical on both screens ──────────────────────────
  v_empty := case
    when not v_typed then public.uic('search.empty_no_query','Type a medicine, salt or company name.')
    when v_filtered  then replace(public.uic('search.empty_filtered',
                            'Nothing matching “{q}” fits these filters.'), '{q}', v_q)
    else replace(public.uic('search.empty_search','No product matches “{q}”.'), '{q}', v_q) end;
  v_hint := case when v_typed and not v_filtered
    then public.uic('search.empty_hint','Check the spelling, or try a shorter word.') else '' end;
  v_request := v_typed
    and coalesce((select request_open from public.catalogue_extras_config where id = 1), true);
  v_buttons :=
      (case when v_filtered then jsonb_build_array(jsonb_build_object(
              'kind','clear_filters', 'tone','primary',
              'label', public.uic('search.filters_clear','Clear all'))) else '[]'::jsonb end)
   || (case when v_request then jsonb_build_array(jsonb_build_object(
              'kind','request',
              'tone', case when v_filtered then 'secondary' else 'primary' end,
              'label', public.uic('search.empty_action','Request this product'))) else '[]'::jsonb end);

  return jsonb_build_object(
    'ok', true,
    'query', v_q,
    'has_query', v_typed,
    'placeholder', public.uic('search.placeholder','Search medicines, salts, companies'),
    'sort', v_sort,
    'category', v_cat,
    'filters', public.search_filter_defs(v_f),
    -- CMD #2011 — WHICH SURFACE draws the inline category chip row is the
    -- backend's call, not the widget's. The Catalogue tab lost that row (the
    -- Therapeutic class list further down the page is the way in); Home keeps
    -- it, because there the chips ARE the browse filter. One UPDATE of
    -- app_settings.search_chip_row_surfaces moves it, with no deploy.
    -- CMD #2026 — the BOX, described: min chars, debounce, the right-hand
    -- buttons per state and the chip-row-on-results rule. Four things the app
    -- used to hold as Dart constants.
    'search_bar', public.search_bar_block(),
    'chip_row_surfaces', coalesce(
      (select value from public.app_settings where key = 'search_chip_row_surfaces'),
      '["home"]'::jsonb),
    'filters_active', v_filtered,
    'filters_active_label', case when v_filtered
      then public.uic('search.filters_on','Filters on') else '' end,
    'total', v_total,
    'count_label', v_count_label,
    'total_capped', v_capped,
    'header_label', case when v_typed
      then replace(replace(public.uic('search.header','{n} for “{q}”'),
                           '{n}', v_count_label), '{q}', v_q)
      else '' end,
    'empty', jsonb_build_object(
      'label', v_empty, 'hint', v_hint, 'buttons', v_buttons),
    'empty_label', v_empty,
    'rail', v_rail,
    'paging', jsonb_build_object(
      'page', v_page, 'page_size', v_size, 'returned', v_got,
      'has_more', v_off + v_got < v_total,
      'next_page', v_page + 1,
      'more_label', public.uic('search.load_more','Load more'),
      'end_label',  public.uic('search.list_end','That is the whole list.')),
    'zone', public.catalogue_zone_switch(coalesce(p_zone, true)),
    'gated', public.viewer_is_approved_customer(),
    'items', public._search_cards(v_ids, v_pct, v_zone));
end $function$

;

-- ── 4. ranking: every typed word is a required token, in any order ────────
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
  -- CMD #2026 — a multi-word query is a SET of required tokens, in any order.
  -- v_sig is the significant half of the query (form words like 'tablet' are
  -- noise, they still rank but they never gate), v_multi says we are in that
  -- mode at all: a single-word query keeps exactly the plan it had, so the
  -- common search pays nothing for this.
  v_sig text[] := '{}'::text[]; v_multi boolean := false;
  v_min int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                    where key = 'search_min_chars'), 3), 1);
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
  if length(replace(v_clean,' ','')) < v_min then return; end if;
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

  -- The required set: the kept tokens, minus anything too short to narrow
  -- anything ('a', '5'). Two or more of them is what turns the mode on.
  select coalesce(array_agg(t), '{}'::text[]) into v_sig
    from unnest(v_keep) t where length(t) >= 2;
  v_multi := coalesce(array_length(v_sig, 1), 0) >= 2;

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
    -- CMD #2026 — order independence starts here. The prefix scan above is
    -- seeded off ONE word (the first that looks like a brand), so "ah telmed"
    -- or "telmed ah" only ever saw products starting "tel". Every significant
    -- token now seeds its own bounded prefix scan, and the required-token
    -- filter below throws away whatever the other tokens do not confirm.
    ( select x.id from unnest(v_sig) w
        cross join lateral (
          select m.id from "MEDICINE" m
           where v_multi and length(w) >= 3
             and public._norm_name(m.product_name) like left(w,3) || '%'
             and (v_all or lower(m.therapeutic_class) = lower(category_filter))
           limit 400) x )
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
           similarity(s.prod_clean, v_clean)       as sim_full,
           -- EVERY significant token present, in any order, anywhere in the
           -- name. This is the whole of "all words are required tokens".
           (v_multi and (select bool_and(s.prod_clean like '%' || w || '%')
                           from unnest(v_sig) w)) as all_tok
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
        (case when s.is_syn then 70 else 0 end),
        -- CMD #2026 — a row carrying every typed word outranks a fuzzy
        -- single-word hit, and sits just under the contiguous-phrase tiers.
        (case when s.all_tok then 90 else 0 end)
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
           (case when public.zone_available(f.id, v_zone) then 0 else 1 end) as sell_rank
    from finalr f
   where f.tier_final >= 50
     -- CMD #2026 — with more than one significant word typed, a row that is
     -- missing any of them is not a result. "telmed ah" stops returning every
     -- Telmisartan pack that has no AH in its name.
     and (not v_multi or f.all_tok)
     -- CHANGE #790 — #747's switch, applied to search: with it on, an approved
     -- customer is shown what a supplier in their zone can actually send.
     and (v_zfilter is null
          or public.zone_available(f.id, v_zfilter))
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
