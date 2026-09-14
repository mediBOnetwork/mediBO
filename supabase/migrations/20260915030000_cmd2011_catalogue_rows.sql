-- CMD #2011 — Catalogue tab: the two chip rows under the search bar go.
--
-- 1. The inline CATEGORY chip row (All · PAIN · CARDIAC · …) is Home's browse
--    filter and stays there; on the Catalogue tab it duplicated the
--    Therapeutic class list further down the page. Which surfaces draw it is
--    now a backend value (app_settings.search_chip_row_surfaces), so moving it
--    is an UPDATE and never a deploy.
-- 2. The narrowing sentence ("Showing everything · Bottle · Piece · Strip ·
--    Rx only") is deleted outright: catalogue_sentence() is dropped, the
--    'sentence' key leaves catalogue_home() and catalogue_list(), and the four
--    ui_copy strings only it printed go with it. Filtering inside a list is
--    unchanged — that is the list toolbar, which has its own chips.
--
-- Idempotent: every statement is a replace, an ON CONFLICT DO NOTHING insert,
-- a DROP IF EXISTS or a DELETE of keys that may already be gone.

insert into public.app_settings (key, value)
values ('search_chip_row_surfaces', '["home"]'::jsonb)
on conflict (key) do nothing;

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
end $function$;

CREATE OR REPLACE FUNCTION public.catalogue_home(p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with z as (select public._cat_count_zone(p_zone) as cz)
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.title','Catalogue'),
    'subtitle', public.uic('catalogue.subtitle','Browse the whole product list by class, company or salt.'),
    'zone', public.catalogue_zone_switch(p_zone),
    'total', public._cat_meta((select cz from z), 'total'),
    'refreshed_at', (select refreshed_at from public.catalogue_facet_count
                      where facet='meta' and zone_id=(select cz from z) and facet_key='total'),
    'stale_label', public.uic('catalogue.counts_note','Counts refresh automatically.'),
    'search_hint', public.uic('catalogue.search_hint','Search a salt or a company'),
    -- CHANGE #799 — the search bar is the hero, so it gets its own block
    -- rather than one loose hint string.
    'search', jsonb_build_object(
      'placeholder', public.uic('catalogue.search_placeholder','Search a medicine, salt or company'),
      'hint',        public.uic('catalogue.search_hint','Search a salt or a company'),
      'clear_label', public.uic('catalogue.search_clear','Clear')),
    -- CHANGE #799 — three doors, large and calm. Icon key + letter follow the
    -- nav-registry convention (#349): a key this build can draw wins, the
    -- letter is the honest fallback, and neither is chosen in Dart.
    'doors_title', public.uic('catalogue.doors_title','Browse by'),
    'doors', jsonb_build_array(
      jsonb_build_object(
        'key','companies', 'kind','companies', 'tab','companies',
        'label', public.uic('catalogue.door_company','Company'),
        'icon_key','store', 'icon_letter','C',
        'count_label', to_char(public._cat_meta((select cz from z), 'companies'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.companies_word','companies')),
      jsonb_build_object(
        'key','salts', 'kind','salts', 'tab','salts',
        'label', public.uic('catalogue.door_salt','Salt'),
        'icon_key','science', 'icon_letter','S',
        'count_label', to_char(public._cat_meta((select cz from z), 'salts'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.salts_word','salts')),
      jsonb_build_object(
        'key','conditions', 'kind','conditions', 'tab','conditions',
        'label', public.uic('catalogue.door_condition','Use'),
        'icon_key','medication', 'icon_letter','U',
        'count_label', public.cat_count_label(
          public._cat_meta((select cz from z), 'condition_products'))),
      jsonb_build_object(
        'key','browse', 'kind','tree', 'tab','browse',
        'label', public.uic('catalogue.door_category','Category'),
        'icon_key','book', 'icon_letter','K',
        'count_label', public.cat_count_label(
          coalesce((select sum(n)::bigint from public.catalogue_facet_count
                     where facet='therapeutic' and zone_id=(select cz from z)), 0::bigint)))),
    -- CHANGE #799 — the strip above the doors. `has` is the backend's, so an
    -- anonymous visitor and a buyer with no history both simply get no strip.
    'recent_viewed', (
      select jsonb_build_object(
        'has',   coalesce((r->>'has')::boolean, false),
        'title', case when coalesce(nullif(r->>'title',''), '') = ''
                      then public.uic('catalogue.recent_viewed_title','Recently viewed')
                      else r->>'title' end,
        'items', coalesce(r->'items','[]'::jsonb))
        from (select public.recently_viewed_rail(12) as r) t),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','browse','label', public.uic('catalogue.tab_browse','Browse'),
        'kind','tree',
        'count_label', public.cat_count_label(
          coalesce((select sum(n)::bigint from public.catalogue_facet_count
                     where facet='therapeutic' and zone_id=(select cz from z)), 0::bigint))),
      jsonb_build_object('key','companies','label', public.uic('catalogue.tab_companies','Companies'),
        'kind','companies',
        'count_label', to_char(public._cat_meta((select cz from z), 'companies'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.companies_word','companies')),
      jsonb_build_object('key','salts','label', public.uic('catalogue.tab_salts','Salts'),
        'kind','salts',
        'count_label', to_char(public._cat_meta((select cz from z), 'salts'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.salts_word','salts')),
      jsonb_build_object('key','conditions','label', public.uic('catalogue.tab_conditions','Uses'),
        'kind','conditions',
        'count_label', to_char(public._cat_meta((select cz from z), 'conditions'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.conditions_word','uses')),
      jsonb_build_object('key','schemes','label', public.uic('catalogue.tab_schemes','Schemes'),
        'kind','list', 'list_kind','tab', 'list_key','schemes',
        'count_label', public.cat_count_label(coalesce((select n::bigint from public.catalogue_facet_count
                     where facet='tab' and zone_id=(select cz from z) and facet_key='schemes'),0)),
        'empty_label', public.uic('catalogue.schemes_empty','No product is running a scheme right now.')),
      jsonb_build_object('key','cold_chain','label', public.uic('catalogue.tab_cold','Cold chain'),
        'kind','list', 'list_kind','tab', 'list_key','cold_chain',
        'count_label', public.cat_count_label(coalesce((select n::bigint from public.catalogue_facet_count
                     where facet='tab' and zone_id=(select cz from z) and facet_key='cold_chain'),0)),
        'empty_label', public.uic('catalogue.cold_empty','No cold-chain product in this view.'))),
    'filters', public.catalogue_filter_defs('{}'::jsonb, (select cz from z)));
$function$;

CREATE OR REPLACE FUNCTION public.catalogue_list(p_kind text DEFAULT 'tree'::text, p_key text DEFAULT NULL::text, p_path text[] DEFAULT '{}'::text[], p_filters jsonb DEFAULT '{}'::jsonb, p_sort text DEFAULT 'name'::text, p_zone boolean DEFAULT true, p_cursor text DEFAULT NULL::text, p_limit integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  -- p_zone survives in the signature only so a deep link, a cached page or an
  -- app build from before this change still resolves the function. Nothing
  -- reads it any more; _cat_zone() returns NULL whatever it is handed.
  v_azone smallint := public._cat_avail_zone();
  v_cz    smallint := public._cat_count_zone(p_zone);   -- 0 — all zones
  v_n     int      := least(greatest(coalesce(p_limit,24),1),50);
  v_sort  text     := case when coalesce(p_sort,'name') = 'newest' then 'newest' else 'name' end;
  v_where text     := public._cat_where(p_kind, p_key, p_path, coalesce(p_filters,'{}'::jsonb));
  v_cur   jsonb;
  v_cg    smallint;
  v_sql   text;
  v_ids   bigint[] := '{}'::bigint[];
  v_grps  smallint[] := '{}'::smallint[];
  v_part  bigint[];
  v_got   int;
  v_last_id bigint; v_last_name text; v_last_g smallint;
  v_filtered boolean := coalesce(public._cat_filtered(coalesce(p_filters,'{}'::jsonb)), false);
  v_head text;
  v_empty text;
  -- CMD #1905 — a TYPED query is the only scope that may offer
  -- "Request this product"; a navigated one (company / salt / class)
  -- never is, because the shopper did not type anything to miss with.
  v_typed boolean := (p_kind = 'search' and coalesce(btrim(coalesce(p_key,'')),'') <> '');
  v_request boolean := false;
  v_empty_hint text := '';
  v_zsw jsonb := public.catalogue_zone_switch(p_zone);
  v_narrow boolean := (p_kind = 'search');
  v_filters jsonb;
  v_total bigint; v_total_in bigint; v_total_out bigint;
  v_lbl_in text; v_lbl_out text;
  v_more boolean;
begin
  begin v_cur := nullif(btrim(coalesce(p_cursor,'')),'')::jsonb; exception when others then v_cur := null; end;
  -- A cursor minted before this change carries no 'g'. It was a position in
  -- the zone-filtered list, which is now group 0 — so read it as one.
  v_cg := case when v_cur is null then null
               when v_cur ? 'g'  then (v_cur->>'g')::smallint
               else 0::smallint end;
  if v_azone is null then v_cg := null; end if;

  -- ── the page ────────────────────────────────────────────────────────────
  -- Two keyset reads, never a sort over the whole scope: group 0 is the same
  -- indexed join #747 always ran, group 1 is the same walk with an anti-join
  -- on the (zone_id, product_id) primary key. Ordering by a computed group
  -- column instead would have made a 5.6-lakh scope sort on every page.
  if v_azone is null then
    v_part := public._cat_page_ids(v_where, v_sort, v_cur, null::smallint, null::smallint, v_n);
    v_ids  := v_part;
    v_grps := array_fill(0::smallint, array[coalesce(array_length(v_ids,1),0)]);
  else
    if v_cg is null or v_cg = 0 then
      v_part := public._cat_page_ids(v_where, v_sort, case when v_cg = 0 then v_cur end,
                                     v_azone, 0::smallint, v_n);
      v_ids  := v_part;
      v_grps := array_fill(0::smallint, array[coalesce(array_length(v_part,1),0)]);
      v_got  := coalesce(array_length(v_part,1),0);
      if v_got < v_n then
        v_part := public._cat_page_ids(v_where, v_sort, null::jsonb, v_azone, 1::smallint, v_n - v_got);
        v_ids  := v_ids || v_part;
        v_grps := v_grps || array_fill(1::smallint, array[coalesce(array_length(v_part,1),0)]);
      end if;
    else
      v_part := public._cat_page_ids(v_where, v_sort, v_cur, v_azone, 1::smallint, v_n);
      v_ids  := v_part;
      v_grps := array_fill(1::smallint, array[coalesce(array_length(v_part,1),0)]);
    end if;
  end if;
  v_ids  := coalesce(v_ids, '{}'::bigint[]);
  v_grps := coalesce(v_grps, '{}'::smallint[]);
  v_got  := coalesce(array_length(v_ids,1),0);

  if v_got > 0 then
    select id, coalesce(product_name,'') into v_last_id, v_last_name
      from public."MEDICINE" where id = v_ids[v_got];
    v_last_g := v_grps[v_got];
  end if;

  -- ── the counts ──────────────────────────────────────────────────────────
  -- Both totals come from catalogue_facet_count, which already keeps a row per
  -- (facet, zone): zone 0 is the whole catalogue, the viewer's zone is what is
  -- reachable. Subtracting is the ONE piece of arithmetic here and it is done
  -- in SQL, never in Dart. A filtered scope has no precomputed total, so every
  -- count goes NULL together and the labels print without numbers.
  v_total     := case when v_filtered then null
                      else public._cat_scope_total(p_kind, p_key, p_path, 0::smallint) end;
  v_total_in  := case when v_filtered or v_azone is null then null
                      else public._cat_scope_total(p_kind, p_key, p_path, v_azone) end;
  v_total_out := case when v_total is null or v_total_in is null then null
                      else greatest(v_total - v_total_in, 0) end;
  v_lbl_in    := public.cat_group_label('in',  v_total_in);
  v_lbl_out   := public.cat_group_label('out', v_total_out);

  v_head := case
    when p_kind = 'company' then coalesce((select label from public.catalogue_facet_count
        where facet='company' and zone_id=v_cz and facet_key = coalesce(p_key,'')), coalesce(p_key,''))
    when p_kind = 'salt'    then coalesce(p_key,'')
    when p_kind = 'condition' then coalesce(
        (select label from public.catalogue_facet_count
          where facet='condition' and zone_id=v_cz and facet_key = coalesce(p_key,'')),
        (select label from public.use_bucket where condition_key = coalesce(p_key,'')),
        coalesce(p_key,''))
    when p_kind = 'search'  then coalesce(nullif(btrim(coalesce(p_key,'')),''),
                                          public.uic('catalogue.all_products','All products'))
    when p_kind = 'tab' and p_key = 'schemes'    then public.uic('catalogue.tab_schemes','Schemes')
    when p_kind = 'tab' and p_key = 'cold_chain' then public.uic('catalogue.tab_cold','Cold chain')
    when p_kind = 'tree' and coalesce(array_length(p_path,1),0) > 0
      then p_path[array_length(p_path,1)]
    else public.uic('catalogue.all_products','All products') end;

  -- Nothing is hidden any more, so "nothing here" can no longer be the zone's
  -- fault and the copy stops blaming it.
  -- CMD #1905 — an empty scope NAMES itself. "Nothing here in this view."
  -- told a shopper who had just tapped a company with 2,461 products nothing
  -- at all; v_head is already the scope's own title, so the sentence uses it.
  v_empty := case
    when v_filtered then replace(public.uic('catalogue.list_empty_filtered_scope',
                         'Nothing in {scope} matches these filters.'), '{scope}', v_head)
    when v_typed    then replace(public.uic('catalogue.list_empty_search',
                         'No product matches “{q}”.'), '{q}', btrim(p_key))
    else replace(public.uic('catalogue.list_empty_scope',
                   'Nothing in {scope} right now.'), '{scope}', v_head) end;
  -- "Request this product" is true ONLY after a typed query found nothing.
  -- On a company, a salt or a class it was an offer to request the very
  -- catalogue the shopper had asked to see.
  -- TYPED is the whole gate, not "typed and unfiltered": a shopper who typed
  -- a word and narrowed it may still want the product requested. What the
  -- filters change is the ORDER — clearing them comes first below, because a
  -- filter the shopper set themselves is the likelier reason for the blank.
  v_request := v_typed
    and coalesce((select request_open from public.catalogue_extras_config where id = 1), true);
  v_empty_hint := case when v_typed and not v_filtered
    then public.uic('catalogue.list_empty_search_hint',
                    'Check the spelling, or try a shorter word.') else '' end;

  v_filters := public.catalogue_filter_defs(coalesce(p_filters,'{}'::jsonb), v_cz);
  if not v_narrow then
    v_filters := jsonb_set(v_filters, '{groups}', '[]'::jsonb);
  end if;

  -- A full page means there may be more. With two groups that still holds:
  -- group 0 short + group 1 topping the page up to v_n means group 1 has more.
  v_more := (v_got = v_n);

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind, 'key', p_key, 'path', to_jsonb(p_path),
    'title', v_head,
    'subtitle', case
      when p_kind = 'salt' then public.uic('catalogue.salt_subtitle','Every brand for this salt')
      when p_kind = 'condition' then public.uic('catalogue.condition_subtitle','Products used for this condition')
      when p_kind = 'company' then public.uic('catalogue.company_subtitle','Products from this company')
      when p_kind = 'search' then public.uic('catalogue.search_subtitle','Matches in the catalogue')
      else '' end,
    'trail', public.catalogue_trail(
               case when p_kind = 'company' then 'companies'
                    when p_kind = 'salt' then 'salts'
                    when p_kind = 'condition' then 'conditions'
                    else 'browse' end,
               p_path, p_kind, p_key, v_head),
    'zone', v_zsw,
    'grouped', v_azone is not null,
    'groups', case when v_azone is null then '[]'::jsonb else jsonb_build_array(
        jsonb_build_object('key','in',  'label', v_lbl_in,  'count', v_total_in),
        jsonb_build_object('key','out', 'label', v_lbl_out, 'count', v_total_out)) end,
    'sort', v_sort,
    'filters', v_filters,
    'filters_active', v_filtered,
    'filters_active_label', case when v_filtered
      then public.uic('catalogue.filters_on','Filters on') else '' end,
    'total', v_total,
    'count_label', case when v_total is null
      then to_char(v_got,'FM9,99,99,999') || ' ' || public.uic('catalogue.showing_word','shown')
      else public.cat_count_label(v_total) end,
    'empty_label', v_empty,
    'empty', jsonb_build_object(
      'label', v_empty,
      'hint', v_empty_hint,
      'action', jsonb_build_object(
        'has',  v_request,
        'kind', 'request',
        'label', public.uic('catalogue.empty_action','Request this product')),
      'clear', jsonb_build_object(
        'has', v_filtered,
        'kind','clear_filters',
        'label', public.uic('catalogue.filters_clear','Clear all')),
      -- CMD #1905 — the buttons in the order they are drawn, tone included.
      -- Clear filters comes FIRST when filters are on: the shopper's own
      -- filter is the likeliest reason the scope is empty, so undoing it is
      -- the primary way out and requesting a product is the afterthought.
      'buttons', (
        case when v_filtered then jsonb_build_array(jsonb_build_object(
               'kind','clear_filters', 'tone','primary',
               'label', public.uic('catalogue.filters_clear','Clear all')))
             else '[]'::jsonb end
        ||
        case when v_request then jsonb_build_array(jsonb_build_object(
               'kind','request',
               'tone', case when v_filtered then 'secondary' else 'primary' end,
               'label', public.uic('catalogue.empty_action','Request this product')))
             else '[]'::jsonb end)),
    'limit', v_n,
    'has_more', v_more,
    'more_label', public.uic('catalogue.load_more','Load more'),
    'end_label', public.uic('catalogue.list_end','That is the whole list.'),
    'next_cursor', case when v_more and v_last_id is not null then
      (case when v_sort = 'newest'
            then jsonb_build_object('g', coalesce(v_last_g,0), 'i', v_last_id)
            else jsonb_build_object('g', coalesce(v_last_g,0), 'i', v_last_id, 'n', v_last_name) end)::text
      end,
    'items', public._cat_group_cards(v_ids, v_grps, v_azone, v_cg, v_lbl_in, v_lbl_out));
end $function$;

drop function if exists public.catalogue_sentence(jsonb, boolean, smallint);

delete from public.ui_copy
 where key in ('catalogue.sentence_lead','catalogue.sentence_all',
               'catalogue.sentence_sep','catalogue.sentence_zone');

-- ─────────────────────────────────────────────────────────────────────────
-- CMD #2011, second pass (Om, same build): the catalogue LANDING.
--
--  * The four Browse-by tiles are the landing. No class list opens
--    preselected under them any more, so the A–Z strip — which belongs to a
--    chosen list — is not on the default view either.
--  * The breadcrumb is the only header under the search bar, and on the
--    landing it is the backend's own one-crumb trail.
--  * The root crumb goes back to that landing; 'browse' is now the Category
--    tile's destination rather than the default view.
-- ─────────────────────────────────────────────────────────────────────────

insert into public.app_settings (key, value)
values ('catalogue_landing',
        '{"show_recent": true, "show_tabs": true, "show_tree": false}'::jsonb)
on conflict (key) do nothing;

CREATE OR REPLACE FUNCTION public.catalogue_trail(p_tab text DEFAULT 'browse'::text, p_path text[] DEFAULT '{}'::text[], p_kind text DEFAULT NULL::text, p_key text DEFAULT NULL::text, p_title text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_items jsonb := '[]'::jsonb;
  v_tab   text  := coalesce(nullif(btrim(coalesce(p_tab,'')),''), 'browse');
  v_kind  text  := nullif(btrim(coalesce(p_kind,'')),'');
  v_sect  text;
  v_stab  text;
  v_leaf  text;
  v_d     int   := coalesce(array_length(p_path,1),0);
  i       int;
begin
  -- The root is always first and always tappable.
  v_items := v_items || jsonb_build_array(jsonb_build_object(
    'label', public.uic('catalogue.trail_root','Catalogue'),
    'current', false,
    -- CMD #2011 — the root goes HOME (the four Browse-by tiles), not to the
    -- class tree. 'browse' is now the Category door's own destination.
    'route', jsonb_build_object('tab','home','path','[]'::jsonb,
                                'list_kind', null, 'list_key', null)));

  -- Which section of the catalogue this is. The LIST kind wins over the tab,
  -- because a company list opened from a search is still under "Company".
  if v_kind = 'company' or v_tab = 'companies' then
    v_sect := public.uic('catalogue.trail_company','Company');  v_stab := 'companies';
  elsif v_kind = 'salt' or v_tab = 'salts' then
    v_sect := public.uic('catalogue.trail_salt','Salt');        v_stab := 'salts';
  elsif v_kind = 'condition' or v_tab = 'conditions' then
    v_sect := public.uic('catalogue.trail_condition','Use');    v_stab := 'conditions';
  elsif v_kind = 'search' then
    v_sect := public.uic('catalogue.trail_search','Search');    v_stab := 'browse';
  elsif v_kind = 'tab' then
    v_sect := coalesce(nullif(btrim(coalesce(p_title,'')),''),
                       public.uic('catalogue.trail_category','Category'));
    v_stab := v_tab;
  elsif v_d > 0 or v_kind = 'tree' then
    v_sect := public.uic('catalogue.trail_category','Category'); v_stab := 'browse';
  end if;

  if v_sect is not null then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'label', v_sect,
      'current', false,
      'route', jsonb_build_object('tab', v_stab, 'path','[]'::jsonb,
                                  'list_kind', case when v_kind = 'tab' then 'tab' end,
                                  'list_key',  case when v_kind = 'tab' then p_key end)));
  end if;

  -- The class trail. Each step goes back to the level it names.
  for i in 1 .. v_d loop
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'label', p_path[i],
      'current', false,
      'route', jsonb_build_object('tab','browse',
                                  'path', to_jsonb(p_path[1:i]),
                                  'list_kind', null, 'list_key', null)));
  end loop;

  -- The leaf a scoped LIST adds: the company, the salt, the search words.
  v_leaf := case
    when v_kind in ('company','salt','search','condition')
      then coalesce(nullif(btrim(coalesce(p_title,'')),''), nullif(btrim(coalesce(p_key,'')),''))
    else null end;
  if v_leaf is not null then
    v_items := v_items || jsonb_build_array(jsonb_build_object(
      'label', v_leaf,
      'current', false,
      'route', jsonb_build_object('tab', v_stab, 'path','[]'::jsonb,
                                  'list_kind', v_kind, 'list_key', p_key)));
  end if;

  -- The last item is where you are. It is still tappable (it reloads the same
  -- place) but it is drawn as the current step.
  v_items := jsonb_set(v_items,
    array[(jsonb_array_length(v_items) - 1)::text, 'current'], 'true'::jsonb);

  return jsonb_build_object(
    'label', public.uic('catalogue.trail_label','You are here'),
    'separator', public.uic('catalogue.trail_sep','›'),
    'items', v_items);
end $function$;

CREATE OR REPLACE FUNCTION public.catalogue_home(p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with z as (select public._cat_count_zone(p_zone) as cz)
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.title','Catalogue'),
    'subtitle', public.uic('catalogue.subtitle','Browse the whole product list by class, company or salt.'),
    'zone', public.catalogue_zone_switch(p_zone),
    'total', public._cat_meta((select cz from z), 'total'),
    'refreshed_at', (select refreshed_at from public.catalogue_facet_count
                      where facet='meta' and zone_id=(select cz from z) and facet_key='total'),
    'stale_label', public.uic('catalogue.counts_note','Counts refresh automatically.'),
    'search_hint', public.uic('catalogue.search_hint','Search a salt or a company'),
    -- CHANGE #799 — the search bar is the hero, so it gets its own block
    -- rather than one loose hint string.
    'search', jsonb_build_object(
      'placeholder', public.uic('catalogue.search_placeholder','Search a medicine, salt or company'),
      'hint',        public.uic('catalogue.search_hint','Search a salt or a company'),
      'clear_label', public.uic('catalogue.search_clear','Clear')),
    -- CHANGE #799 — three doors, large and calm. Icon key + letter follow the
    -- nav-registry convention (#349): a key this build can draw wins, the
    -- letter is the honest fallback, and neither is chosen in Dart.
    -- CMD #2011 — the landing's own breadcrumb ("Catalogue"), so the header
    -- under the search bar is a payload and not a word written in Dart.
    'trail', public.catalogue_trail('home','{}'::text[], null, null, null),
    -- CMD #2011 — WHAT the default landing shows. The class list used to open
    -- preselected underneath the doors; it is now behind the Category tile,
    -- with the A–Z strip that belongs to it. Each flag is an UPDATE of
    -- app_settings.catalogue_landing away, with no deploy.
    'landing', coalesce(
      (select value from public.app_settings where key = 'catalogue_landing'),
      '{"show_recent": true, "show_tabs": true, "show_tree": false}'::jsonb),
    'doors_title', public.uic('catalogue.doors_title','Browse by'),
    'doors', jsonb_build_array(
      jsonb_build_object(
        'key','companies', 'kind','companies', 'tab','companies',
        'label', public.uic('catalogue.door_company','Company'),
        'icon_key','store', 'icon_letter','C',
        'count_label', to_char(public._cat_meta((select cz from z), 'companies'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.companies_word','companies')),
      jsonb_build_object(
        'key','salts', 'kind','salts', 'tab','salts',
        'label', public.uic('catalogue.door_salt','Salt'),
        'icon_key','science', 'icon_letter','S',
        'count_label', to_char(public._cat_meta((select cz from z), 'salts'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.salts_word','salts')),
      jsonb_build_object(
        'key','conditions', 'kind','conditions', 'tab','conditions',
        'label', public.uic('catalogue.door_condition','Use'),
        'icon_key','medication', 'icon_letter','U',
        'count_label', public.cat_count_label(
          public._cat_meta((select cz from z), 'condition_products'))),
      jsonb_build_object(
        'key','browse', 'kind','tree', 'tab','browse',
        'label', public.uic('catalogue.door_category','Category'),
        'icon_key','book', 'icon_letter','K',
        'count_label', public.cat_count_label(
          coalesce((select sum(n)::bigint from public.catalogue_facet_count
                     where facet='therapeutic' and zone_id=(select cz from z)), 0::bigint)))),
    -- CHANGE #799 — the strip above the doors. `has` is the backend's, so an
    -- anonymous visitor and a buyer with no history both simply get no strip.
    'recent_viewed', (
      select jsonb_build_object(
        'has',   coalesce((r->>'has')::boolean, false),
        'title', case when coalesce(nullif(r->>'title',''), '') = ''
                      then public.uic('catalogue.recent_viewed_title','Recently viewed')
                      else r->>'title' end,
        'items', coalesce(r->'items','[]'::jsonb))
        from (select public.recently_viewed_rail(12) as r) t),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','browse','label', public.uic('catalogue.tab_browse','Browse'),
        'kind','tree',
        'count_label', public.cat_count_label(
          coalesce((select sum(n)::bigint from public.catalogue_facet_count
                     where facet='therapeutic' and zone_id=(select cz from z)), 0::bigint))),
      jsonb_build_object('key','companies','label', public.uic('catalogue.tab_companies','Companies'),
        'kind','companies',
        'count_label', to_char(public._cat_meta((select cz from z), 'companies'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.companies_word','companies')),
      jsonb_build_object('key','salts','label', public.uic('catalogue.tab_salts','Salts'),
        'kind','salts',
        'count_label', to_char(public._cat_meta((select cz from z), 'salts'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.salts_word','salts')),
      jsonb_build_object('key','conditions','label', public.uic('catalogue.tab_conditions','Uses'),
        'kind','conditions',
        'count_label', to_char(public._cat_meta((select cz from z), 'conditions'),'FM9,99,99,999')
                     || ' ' || public.uic('catalogue.conditions_word','uses')),
      jsonb_build_object('key','schemes','label', public.uic('catalogue.tab_schemes','Schemes'),
        'kind','list', 'list_kind','tab', 'list_key','schemes',
        'count_label', public.cat_count_label(coalesce((select n::bigint from public.catalogue_facet_count
                     where facet='tab' and zone_id=(select cz from z) and facet_key='schemes'),0)),
        'empty_label', public.uic('catalogue.schemes_empty','No product is running a scheme right now.')),
      jsonb_build_object('key','cold_chain','label', public.uic('catalogue.tab_cold','Cold chain'),
        'kind','list', 'list_kind','tab', 'list_key','cold_chain',
        'count_label', public.cat_count_label(coalesce((select n::bigint from public.catalogue_facet_count
                     where facet='tab' and zone_id=(select cz from z) and facet_key='cold_chain'),0)),
        'empty_label', public.uic('catalogue.cold_empty','No cold-chain product in this view.'))),
    'filters', public.catalogue_filter_defs('{}'::jsonb, (select cz from z)));
$function$;
