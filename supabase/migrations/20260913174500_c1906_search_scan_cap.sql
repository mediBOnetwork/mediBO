-- CMD #1906 — QA round 1: the shared search must answer inside anon's budget.
--
-- Hostile QA on the live build (2026-09-13) drove the storefront RPCs as the
-- ANON role, which is what every shopper's phone actually is, and found:
--
--   search_page('paracetamol')  -> HTTP 500  57014 "canceling statement due
--                                  to statement timeout"   3.11s
--   search_page('cal')          -> HTTP 200                 2.77s
--   search_page('zzzzqqqnotathing') -> HTTP 200             0.50s
--
-- The cost tracked the number of MATCHES, not the page size, because
-- search_page asked search_medicines_priority for page_limit => null: every
-- match for the term was ranked and materialised so that thirty of them could
-- be returned. The anon role has a 3-second statement budget (the standing
-- storefront lesson), so the most-searched molecule in an Indian pharmacy
-- answered with the app's Retry screen.
--
-- Bounded here, in three places, with no change to what page 1 contains:
--   1. the candidate scan takes a cap (app_settings.search_scan_cap, so the
--      number is Om's to tune with an UPDATE and never a deploy),
--   2. relevance — the default sort — stops re-joining "MEDICINE" just to
--      order by a column it does not sort on,
--   3. a total that hit the cap is worded as a floor ("1,200+"), from
--      ui_copy, so the count never claims to be exact when it is not.
--
-- Idempotent: create or replace + on conflict do nothing.

insert into public.app_settings (key, value)
values ('search_scan_cap', '1200'::jsonb)
on conflict (key) do nothing;

-- CMD #1906, Om's call on 2026-09-13 — the typeahead panel is OFF.
-- On Home a keystroke produced the panel and nothing else: the shopper typed
-- a brand, got one card offering to search for the word already in the box,
-- and the page behind it did not move. The frontend keeps the whole panel,
-- the chip and #1905's navigation; whether it is OFFERED is this row, so
-- turning it back on is an UPDATE and never a deploy.
insert into public.app_settings (key, value)
values ('search_suggest_enabled', 'false'::jsonb)
on conflict (key) do nothing;

insert into public.ui_copy (key, value) values
  ('search.count_capped', to_jsonb('{n}+ products'::text))
on conflict (key) do nothing;

create or replace function public.search_page(
  p_q         text,
  p_filters   jsonb   default '{}'::jsonb,
  p_page      integer default 0,
  p_page_size integer default null,
  p_zone      boolean default true
) returns jsonb
language plpgsql volatile security definer set search_path to 'public'
as $function$
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
  v_keep    smallint;
  v_recent  jsonb := jsonb_build_object('has', false, 'items', '[]'::jsonb);
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

  -- ── the recent-search strip ─────────────────────────────────────────────
  select keep_n into v_keep from public.search_recent_config where id = 1;
  v_keep := coalesce(v_keep, 6);
  if v_uid is not null then
    if v_typed and v_page = 0
       and coalesce((select enabled from public.search_recent_config where id = 1), true) then
      insert into public.search_recent (user_id, q_norm, q, last_at)
      values (v_uid, lower(v_q), v_q, now())
      on conflict (user_id, q_norm) do update set q = excluded.q, last_at = excluded.last_at;
      delete from public.search_recent r
       where r.user_id = v_uid
         and r.q_norm not in (select q_norm from public.search_recent
                               where user_id = v_uid order by last_at desc limit v_keep);
    end if;
    select jsonb_build_object(
             'has', count(*) > 0,
             'title', public.uic('search.recent_title','Recent searches'),
             'clear_label', public.uic('search.recent_clear','Clear'),
             'items', coalesce(jsonb_agg(jsonb_build_object('q', t.q, 'label', t.q)
                                         order by t.last_at desc), '[]'::jsonb))
      into v_recent
      from (select q, last_at from public.search_recent
             where user_id = v_uid order by last_at desc limit v_keep) t;
  else
    v_recent := jsonb_build_object(
      'has', false,
      'title', public.uic('search.recent_title','Recent searches'),
      'clear_label', public.uic('search.recent_clear','Clear'),
      'items', '[]'::jsonb);
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
    'suggest_enabled', coalesce((select (value #>> '{}') = 'true'
                                   from public.app_settings
                                  where key = 'search_suggest_enabled'), false),
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
    'recent', v_recent,
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