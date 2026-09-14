-- CMD #2010 — search is ONE surface: results as you type.
--
-- What this migration removes, and why:
--   • the suggestion path (`search_suggest`, `suggest_medicines`,
--     `search_page().suggest_enabled`). A typed character produced a LIST OF
--     WORDS that had to be tapped before anything was searched. The grid now
--     answers the keystroke itself, so a panel offering to search for the word
--     already in the box is a step with nothing behind it.
--   • the recent-search strip, its write and its read. Nothing about what a
--     shopper typed is recorded any more. `search_recent` / `search_recent_config`
--     are LEFT IN PLACE (dropping a table holding user rows is the destructive
--     list, and an unread table records nothing) — CMD #2010 decision log.
--
-- What it adds:
--   • `search_idle_rail()` — the focused-but-empty state. This customer's own
--     previously ordered products when there are any, the zone's top sellers
--     when there are none. The BACKEND picks the rail AND words the title;
--     Flutter renders whichever arrived.
--
-- Idempotent: every statement is create-or-replace / drop-if-exists / insert
-- on conflict, so the live replay can run it more than once.

-- ── titles + the rail size ──────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('search.rail_last_ordered', to_jsonb('Your last ordered'::text)),
  ('search.rail_top_sellers',  to_jsonb('Top sellers near you'::text))
on conflict (key) do nothing;

insert into public.app_settings (key, value) values
  ('search_rail_limit', '12'::jsonb)
on conflict (key) do nothing;

-- ── the idle rail ───────────────────────────────────────────────────────────
create or replace function public.search_idle_rail(p_limit int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_uid  uuid := auth.uid();
  v_zone smallint := public._cat_avail_zone();
  v_n    int := least(greatest(coalesce(nullif(p_limit, 0),
                   coalesce((select (value #>> '{}')::int from public.app_settings
                               where key = 'search_rail_limit'), 12)), 1), 30);
  v_ids  bigint[] := '{}'::bigint[];
  v_kind text := 'top_sellers';
  v_items jsonb := '[]'::jsonb;
begin
  -- 1. what this customer has ordered before, most recent order first.
  if v_uid is not null then
    select array_agg(t.product_id order by t.last_at desc)
      into v_ids
      from (select oi.product_id, max(o.created_at) as last_at
              from public.order_items oi
              join public.orders o on o.id = oi.order_id
             where oi.product_id is not null
               and (o.user_id = v_uid or o.customer_id = v_uid)
             group by oi.product_id
             order by max(o.created_at) desc
             limit v_n) t;
    if coalesce(array_length(v_ids, 1), 0) > 0 then
      v_kind := 'last_ordered';
      v_items := public._sf_cards(v_ids);
    end if;
  end if;

  -- 2. no orders (or none of them survived the availability filter): the
  --    zone's top sellers. A viewer with no zone gets the catalogue's own
  --    order, which is what every other anonymous surface already shows.
  if v_kind = 'top_sellers' or jsonb_array_length(v_items) = 0 then
    v_kind := 'top_sellers';
    select array_agg(t.id order by t.sc desc nulls last, t.id)
      into v_ids
      from (select m.id,
                   nullif(regexp_replace(coalesce(m.sales_count::text,''),
                                         '[^0-9]', '', 'g'), '')::int as sc
              from "MEDICINE" m
             where lower(coalesce(m.buyable::text,'')) in ('true','t')
               and (v_zone is null
                    or exists (select 1 from public.catalogue_zone_avail z
                                where z.zone_id = v_zone and z.product_id = m.id))
             order by nullif(regexp_replace(coalesce(m.sales_count::text,''),
                                            '[^0-9]', '', 'g'), '')::int desc nulls last,
                      m.id
             limit v_n) t;
    v_items := case when v_ids is null then '[]'::jsonb
                    else public._sf_cards(v_ids) end;
  end if;

  return jsonb_build_object(
    'ok',    true,
    'has',   jsonb_array_length(v_items) > 0,
    'kind',  v_kind,
    'title', case when v_kind = 'last_ordered'
                  then public.uic('search.rail_last_ordered', 'Your last ordered')
                  else public.uic('search.rail_top_sellers',  'Top sellers near you') end,
    'items', v_items);
end
$fn$;

revoke all on function public.search_idle_rail(int) from public;
grant execute on function public.search_idle_rail(int) to anon, authenticated, service_role;

-- ── search_page(): no recent strip, no suggest flag, one rail ───────────────
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

-- ── the suggestion path is gone ─────────────────────────────────────────────
drop function if exists public.search_suggest(text, boolean);
drop function if exists public.suggest_medicines(text);
drop function if exists public.search_recent_clear();

-- The suggestion switch has nothing left to switch, and neither has its copy.
delete from public.app_settings where key = 'search_suggest_enabled';
delete from public.ui_copy
 where key in ('search.suggest_min_chars', 'search.recent_title', 'search.recent_clear');
