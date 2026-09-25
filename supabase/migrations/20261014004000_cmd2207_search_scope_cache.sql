-- CMD #2207 — the two remaining customer RPCs over budget after the card
-- cache: storefront_company_page and search_page.
--
-- ── 1. storefront_company_page: the index, EXPLAINed ──────────────────────
-- The company list is
--     where marketer_canonical = $1
--       and lower(coalesce(buyable::text,'')) in ('true','t')
--     order by sales_count desc nulls last, id
-- and on live it took 2205 ms:
--
--   Limit  (actual time=2205.550..2205.556 rows=20)
--     ->  Sort  (Sort Key: sales_count DESC NULLS LAST, id)
--           ->  Bitmap Heap Scan on "MEDICINE"  (rows=2390)
--                 ->  BitmapAnd
--                       ->  Bitmap Index Scan idx_medicine_company_rank (rows=2390, 35 ms)
--                       ->  Bitmap Index Scan idx_medicine_buyable_true (rows=77853, 580 ms)
--
-- The catalogue has partial indexes on `WHERE buyable` (the boolean), but this
-- predicate is written on `lower(buyable::text)`, which the planner cannot
-- match to them — so it ANDed a 2,390-row bitmap with a 77,853-row one and
-- then sorted 2,390 heap rows it had to fetch. One partial index written in
-- the SAME expression the query uses answers the whole thing in order.
create index if not exists idx_medicine_company_buyable_sales
  on public."MEDICINE" (marketer_canonical, sales_count desc nulls last, id)
  where lower(coalesce(buyable::text, '')) = any (array['true','t']);

comment on index public.idx_medicine_company_buyable_sales is
  'CMD #2207 — storefront_company_page''s list, in its own order. Written on lower(buyable::text) because that is the predicate the RPC uses; the WHERE buyable partial indexes cannot serve it.';

-- The same expression is the one every storefront list filters on, and the
-- catalogue-wide "top sellers" order is the other half of it.
create index if not exists idx_medicine_buyable_expr_sales
  on public."MEDICINE" (sales_count desc nulls last, id)
  where lower(coalesce(buyable::text, '')) = any (array['true','t']);

-- ── 2. search_page: the ranked scope, precomputed ─────────────────────────
-- _search_page_core() asks search_medicines_priority() for up to
-- app_settings.search_scan_cap (1200) ranked candidates, COUNTS them for the
-- total and then shows 20. Measured on live: 35-130 ms warm and 1.8-2.0 s on a
-- cold buffer cache, 7,635 shared buffers for one word. The ranking is a pure
-- function of (query, category, zone switch, viewer zone, admin) and the
-- catalogue, so the ordered id list is cached and the page is a slice of it.
-- Byte-identical: v_total is the length of the same list and v_ids the same
-- window that the live scan produced.
create table if not exists public.search_scope_cache (
  skey       text   primary key,
  ids        bigint[] not null,
  built_at   timestamptz not null default now(),
  build_ms   int,
  hits       bigint not null default 0
);

create index if not exists idx_search_scope_cache_built
  on public.search_scope_cache (built_at);

alter table public.search_scope_cache enable row level security;
revoke all on public.search_scope_cache from anon, authenticated;

comment on table public.search_scope_cache is
  'CMD #2207 — the ordered id list search_medicines_priority() returns for one (query, category, zone switch, viewer zone, admin, cap). A search page is a slice of it.';

insert into public.app_settings (key, value) values
  ('search_scope_cache_ttl_s',  to_jsonb(900)),
  ('search_scope_cache_enabled', to_jsonb(true)),
  ('search_scope_cache_max_rows', to_jsonb(5000))
on conflict (key) do nothing;

create or replace function public._search_scope_key(
  p_q text, p_cat text, p_zone boolean, p_cap int)
returns text
language sql stable security definer
set search_path to 'public'
as $fn$
  select md5(coalesce(p_q,'') || E'\u0001' || coalesce(p_cat,'') || E'\u0001'
          || coalesce(p_zone::text,'') || E'\u0001' || coalesce(p_cap::text,'')
          || E'\u0001' || coalesce(public._viewer_zone_or_null()::text,'-')
          || E'\u0001' || (public.get_my_role() in ('admin','super_admin'))::text)
$fn$;

-- Reads the cached scope, or runs the ranking pass and stores it. VOLATILE:
-- _search_page_core() is volatile, so this is reached in a read-write
-- transaction; if it ever is not, the write is skipped and the scan still
-- answers.
create or replace function public._search_scope_ids(
  p_q text, p_cat text, p_zone boolean, p_cap int)
returns bigint[]
language plpgsql volatile security definer
set search_path to 'public'
as $fn$
declare
  v_key text; v_ids bigint[]; v_t0 timestamptz;
  v_ttl int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                   where key = 'search_scope_cache_ttl_s'), 900), 30);
  v_on boolean := coalesce((select (value #>> '{}')::boolean from public.app_settings
                             where key = 'search_scope_cache_enabled'), true);
  v_max int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                   where key = 'search_scope_cache_max_rows'), 5000), 100);
begin
  if v_on then
    v_key := public._search_scope_key(p_q, p_cat, p_zone, p_cap);
    select c.ids into v_ids
      from public.search_scope_cache c
     where c.skey = v_key
       and c.built_at > now() - make_interval(secs => v_ttl);
    if v_ids is not null then
      begin
        update public.search_scope_cache set hits = hits + 1 where skey = v_key;
      exception when others then null;   -- read-only transaction: not fatal
      end;
      return v_ids;
    end if;
  end if;

  v_t0 := clock_timestamp();
  select coalesce(array_agg(s.id), '{}'::bigint[]) into v_ids
    from public.search_medicines_priority(p_q, p_cat, 0, p_cap, p_zone) s;

  if v_on then
    begin
      insert into public.search_scope_cache (skey, ids, built_at, build_ms, hits)
      values (v_key, v_ids, now(),
              (extract(epoch from clock_timestamp() - v_t0) * 1000)::int, 0)
      on conflict (skey) do update
        set ids = excluded.ids, built_at = excluded.built_at,
            build_ms = excluded.build_ms;
      -- keep the table bounded: the least recently built rows go first.
      delete from public.search_scope_cache c
       where c.skey in (select skey from public.search_scope_cache
                         order by built_at desc offset v_max);
    exception when others then null;     -- read-only transaction: not fatal
    end;
  end if;

  return v_ids;
end $fn$;

comment on function public._search_scope_ids(text, text, boolean, int) is
  'CMD #2207 — the ordered candidate ids for one search, from search_scope_cache when fresh, otherwise from search_medicines_priority() (and stored).';

-- ── 3. _search_page_core(): the ranking pass becomes a cached id list ─────
-- All three branches only ever used s.id from search_medicines_priority(), so
-- each one now reads the SAME ordered id list through _search_scope_ids().
-- Nothing else in the function changes: v_total is still the length of the
-- ranked scope and v_ids still the window taken from it in the same order.
CREATE OR REPLACE FUNCTION public._search_page_core(p_q text, p_filters jsonb DEFAULT '{}'::jsonb, p_page integer DEFAULT 0, p_page_size integer DEFAULT NULL::integer, p_zone boolean DEFAULT true)
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
  v_nofilter boolean := false;
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

  -- When not one product filter is actually set, every predicate in the join
  -- below is a no-op, so joining "MEDICINE" for up to v_cap candidates buys
  -- nothing. Skip the join entirely in that case.
  v_nofilter := (v_pack = '{}'::text[])
            and (v_rx not in ('RX','OTC'))
            and ((v_f->>'habit_forming') is distinct from 'true')
            and ((v_f->>'cold_chain')    is distinct from 'true')
            and ((v_f->>'has_image')     is distinct from 'true')
            and ((v_f->>'has_scheme')    is distinct from 'true');

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
    if v_sort = 'relevance' and v_nofilter then
      with hit as materialized (
        select row_number() over () as rn, s.id
          from unnest(public._search_scope_ids(v_q, v_cat, p_zone, v_cap)) s(id)),
      pg as (select h.id, h.rn as o from hit h order by h.rn offset v_off limit v_size)
      select (select count(*)::int from hit),
             coalesce((select array_agg(pg.id order by pg.o) from pg), '{}'::bigint[])
        into v_total, v_ids;
    elsif v_sort = 'relevance' then
      with hit as materialized (
      select r.rn, r.id
        from (select s.id, row_number() over () as rn
                from unnest(public._search_scope_ids(v_q, v_cat, p_zone, v_cap)) s(id)) r
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
                from unnest(public._search_scope_ids(v_q, v_cat, p_zone, v_cap)) s(id)) r
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
end $function$;

-- ── 4. the cron_task that keeps the hot searches and company lists warm ───
create or replace function public.search_scope_warm_tick()
returns jsonb
language plpgsql volatile security definer
set search_path to 'public'
as $fn$
declare
  v_q text; v_n int := 0; v_t0 timestamptz := clock_timestamp();
  v_qn int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                  where key = 'sf_card_warm_queries'), 40), 0);
  v_cap int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                   where key = 'search_scan_cap'), 1200), 60);
  v_ttl int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                   where key = 'search_scope_cache_ttl_s'), 900), 30);
begin
  if not coalesce((select (value #>> '{}')::boolean from public.app_settings
                    where key = 'search_scope_cache_enabled'), true) then
    return jsonb_build_object('ok', true, 'skipped', 'disabled');
  end if;

  -- anonymous is the class most searches are run in; a zoned viewer's scope
  -- is warmed by their own first search.
  perform set_config('request.jwt.claims', '', true);
  perform set_config('medibo.m_vzone', '', true);
  perform set_config('medibo.m_role', '', true);

  for v_q in
    select r.q from public.search_recent r
     group by r.q order by count(*) desc, max(r.last_at) desc limit v_qn
  loop
    begin
      perform public._search_scope_ids(v_q, 'All', false, v_cap);
      perform public._search_scope_ids(v_q, 'All', true,  v_cap);
      v_n := v_n + 1;
    exception when others then null;
    end;
  end loop;

  delete from public.search_scope_cache
   where built_at < now() - make_interval(secs => v_ttl * 3);

  return jsonb_build_object('ok', true, 'queries', v_n,
    'ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::int);
end $fn$;

insert into public.cron_task (name, ord, mode, work_sql, step_timeout_ms, enabled,
                              base_interval_s, max_interval_s, dml, note)
values ('search_scope_warm', 122, 'poll', 'select public.search_scope_warm_tick()',
        240000, true, 300, 900, true,
        'CMD #2207 — keeps the ranked candidate list of the most-typed searches precomputed, so a search page is a slice of an array instead of a 1200-candidate ranking pass.')
on conflict (name) do update
   set work_sql = excluded.work_sql,
       step_timeout_ms = excluded.step_timeout_ms,
       enabled = true,
       base_interval_s = excluded.base_interval_s,
       max_interval_s = excluded.max_interval_s,
       dml = true,
       parked_reason = null,
       fail_count = 0,
       last_error = null,
       note = excluded.note;
