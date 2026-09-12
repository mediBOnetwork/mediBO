-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1906 — ONE SEARCH for Home and Catalogue.
--
-- Home used storefront_search_page (category chips, no suggestions, offset
-- paging). Catalogue used search_suggest + catalogue_list(kind='search')
-- (a suggestion popup, pack/Rx/flag filters, a sort, "Request this product").
-- Two behaviours, two looks, two matchers — the prefix-only _cat_where scan on
-- one side and search_medicines_priority's ranked/deduped/zone-aware pass on
-- the other, so the SAME query answered differently depending on which box a
-- pharmacy typed into.
--
-- From here there is ONE entry: search_page(q, filters, page). It ranks with
-- search_medicines_priority (nothing about the ranking changes), applies the
-- catalogue's own filter vocabulary on top, and returns every string both
-- screens print — header, filters, empty state, paging and the recent-search
-- strip. storefront_search_page becomes a thin wrapper over it for one
-- release; catalogue_list keeps its non-search kinds untouched and its search
-- branch is no longer reached by any screen.
--
-- Idempotent: safe to replay.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. recent searches ──────────────────────────────────────────────────────
-- The strip under the box, shared by both screens. It is the BACKEND's list:
-- search_page records the query it just answered and hands the last N back
-- with their labels, so Home and Catalogue cannot show different histories.
create table if not exists public.search_recent (
  user_id  uuid        not null,
  q_norm   text        not null,
  q        text        not null,
  last_at  timestamptz not null default now(),
  primary key (user_id, q_norm)
);

create index if not exists idx_search_recent_user_at
  on public.search_recent (user_id, last_at desc);

alter table public.search_recent enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'search_recent'
                    and policyname = 'search_recent_own') then
    create policy search_recent_own on public.search_recent
      for all using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
end $$;

revoke all on public.search_recent from anon;
grant select, insert, update, delete on public.search_recent to authenticated;
grant all on public.search_recent to service_role;

create table if not exists public.search_recent_config (
  id        smallint primary key default 1,
  keep_n    smallint not null default 6,
  enabled   boolean  not null default true
);
insert into public.search_recent_config (id) values (1) on conflict (id) do nothing;
grant select on public.search_recent_config to anon, authenticated, service_role;

-- ── 2. the filter set, in ONE order ─────────────────────────────────────────
-- Category, pack type, Rx, product flags, sort. Both screens draw exactly this
-- array in exactly this order; the order lives here, not in Dart. The category
-- group is Home's chip row and the Catalogue's missing filter, merged: 'All'
-- plus every therapeutic_class with the count the shopper already saw.
create or replace function public.search_filter_defs(
  p_filters jsonb default '{}'::jsonb
) returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  with sel as (
    select coalesce(nullif(btrim(coalesce(p_filters->>'category','')),''), 'All') as cat,
           coalesce(nullif(btrim(coalesce(p_filters->>'sort','')),''), 'relevance') as srt
  ),
  cats as (
    select c.name, c.n from public.medicine_category_counts() c
  )
  select jsonb_build_object(
    'title',       public.uic('search.filters_title','Filters'),
    'clear_label', public.uic('search.filters_clear','Clear all'),
    'apply_label', public.uic('search.filters_apply','Show results'),
    'groups', jsonb_build_array(
      -- 1. CATEGORY — Home's chip row, now a filter on both screens.
      jsonb_build_object(
        'key','category', 'label', public.uic('search.f_category','Category'),
        'mode','single', 'chip_row', true,
        'options',
          jsonb_build_array(jsonb_build_object(
            'key','All', 'label', public.uic('search.f_category_all','All'),
            'n', null, 'selected', (select cat from sel) = 'All'))
          || coalesce((select jsonb_agg(jsonb_build_object(
                 'key', c.name, 'label', c.name, 'n', c.n,
                 'selected', lower(c.name) = lower((select cat from sel)))
               order by c.n desc, c.name) from cats c), '[]'::jsonb)),
      -- 2. PACK TYPE
      jsonb_build_object(
        'key','pack_type', 'label', public.uic('search.f_pack_type','Pack type'),
        'mode','multi', 'chip_row', false,
        'options', coalesce((select jsonb_agg(jsonb_build_object(
                       'key', c.facet_key, 'label', c.label, 'n', c.n,
                       'selected', coalesce(p_filters->'pack_type','[]'::jsonb) ? c.facet_key)
                       order by c.n desc, c.label)
                    from public.catalogue_facet_count c
                     where c.facet = 'pack_type' and c.zone_id = 0), '[]'::jsonb)),
      -- 3. Rx
      jsonb_build_object(
        'key','rx', 'label', public.uic('search.f_rx','Prescription'),
        'mode','single', 'chip_row', false,
        'options', jsonb_build_array(
          jsonb_build_object('key','Rx','label', public.uic('search.f_rx_only','Rx only'),
            'n', null, 'selected', (p_filters->>'rx') = 'Rx'),
          jsonb_build_object('key','OTC','label', public.uic('search.f_otc_only','OTC only'),
            'n', null, 'selected', (p_filters->>'rx') = 'OTC'))),
      -- 4. PRODUCT FLAGS — carried over from the catalogue filter sheet.
      --    Dropping them would have been a silent capability loss.
      jsonb_build_object(
        'key','flags', 'label', public.uic('search.f_flags','Product'),
        'mode','multi', 'chip_row', false,
        'options', jsonb_build_array(
          jsonb_build_object('key','habit_forming','label', public.uic('search.f_habit','Habit forming'),
            'n', null, 'selected', (p_filters->>'habit_forming') = 'true'),
          jsonb_build_object('key','cold_chain','label', public.uic('search.f_cold','Cold chain'),
            'n', null, 'selected', (p_filters->>'cold_chain') = 'true'),
          jsonb_build_object('key','has_image','label', public.uic('search.f_image','Has photo'),
            'n', null, 'selected', (p_filters->>'has_image') = 'true'),
          jsonb_build_object('key','has_scheme','label', public.uic('search.f_scheme','Has scheme'),
            'n', null, 'selected', (p_filters->>'has_scheme') = 'true'))),
      -- 5. SORT — a group like any other, so one widget draws all five.
      jsonb_build_object(
        'key','sort', 'label', public.uic('search.sort_title','Sort'),
        'mode','single', 'chip_row', false,
        'options', jsonb_build_array(
          jsonb_build_object('key','relevance','label', public.uic('search.sort_relevance','Best match'),
            'n', null, 'selected', (select srt from sel) = 'relevance'),
          jsonb_build_object('key','name','label', public.uic('search.sort_name','Name A–Z'),
            'n', null, 'selected', (select srt from sel) = 'name'),
          jsonb_build_object('key','newest','label', public.uic('search.sort_newest','Newest added'),
            'n', null, 'selected', (select srt from sel) = 'newest')))));
$function$;

-- ── 3. is anything narrowed? ────────────────────────────────────────────────
create or replace function public._search_filtered(p_filters jsonb)
returns boolean
language sql immutable
as $function$
  select coalesce(nullif(btrim(coalesce(p_filters->>'category','')),''),'All') <> 'All'
      or coalesce(jsonb_array_length(p_filters->'pack_type'),0) > 0
      or (p_filters->>'rx') in ('Rx','OTC')
      or (p_filters->>'habit_forming') = 'true'
      or (p_filters->>'cold_chain') = 'true'
      or (p_filters->>'has_image') = 'true'
      or (p_filters->>'has_scheme') = 'true';
$function$;

-- ── 4. the result row, built once ───────────────────────────────────────────
-- _cat_cards' shape (which ProductRowCard already renders on both screens),
-- plus the cart discount Home's own search has always passed to
-- storefront_pricing, plus the out-of-zone availability override the catalogue
-- list applies. One builder, so the two screens cannot draw different rows.
create or replace function public._search_cards(
  p_ids bigint[], p_pct numeric, p_zone smallint
) returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
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
      'is_new', (m.created_at is not null
                 and m.created_at >= now() - make_interval(days =>
                       coalesce((select new_days from public.catalogue_extras_config where id = 1), 30))),
      'new_badge', case when (m.created_at is not null
                 and m.created_at >= now() - make_interval(days =>
                       coalesce((select new_days from public.catalogue_extras_config where id = 1), 30)))
                   then public.uic('catalogue.new_badge','New') else '' end,
      'rx', public.rx_badge(m.rx_required),
      'availability', case
        when p_zone is null or exists (select 1 from public.catalogue_zone_avail za
                                        where za.zone_id = p_zone and za.product_id = m.id)
        then public.storefront_cta(
               public.storefront_effective_count(m.id,
                 coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
               true)
        else public.storefront_cta(
               public.storefront_effective_count(m.id,
                 coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
               true)
             || jsonb_build_object(
                  'is_available', false, 'can_add', false, 'blocked_by', 'not_in_zone',
                  'cta_label', public.uic('catalogue.zone_block_note','Not available in your zone'),
                  'note',      public.uic('catalogue.zone_block_note','Not available in your zone'),
                  'cta_short', public.uic('catalogue.zone_block_cta','Not in your zone'),
                  'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF')) end,
      'pricing', public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, p_pct, m.id),
      'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                   then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
      'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t')
    ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid;
$function$;

-- ── 5. the ONE entry ────────────────────────────────────────────────────────
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
    with hit as materialized (
      select r.rn, r.id
        from (select s.id, row_number() over () as rn
                from public.search_medicines_priority(v_q, v_cat, 0, null, p_zone) s) r
        join "MEDICINE" m on m.id = r.id
       where (v_pack = '{}'::text[] or m.pack_type = any(v_pack))
         and (v_rx not in ('RX','OTC')
              or upper(btrim(coalesce(m.rx_required,''))) = v_rx)
         and ((v_f->>'habit_forming') is distinct from 'true'
              or upper(btrim(coalesce(m.habit_forming,''))) = 'YES')
         and ((v_f->>'cold_chain') is distinct from 'true' or m.cold_chain)
         and ((v_f->>'has_image') is distinct from 'true'
              or (m.image_url_1 is not null and btrim(m.image_url_1) <> ''))
         and ((v_f->>'has_scheme') is distinct from 'true' or m.has_scheme)
    ),
    ord as (
      select h.id,
             row_number() over (order by
               case when v_sort = 'relevance' then h.rn end asc,
               case when v_sort = 'name'   then public._norm_name(m.product_name) end asc,
               case when v_sort = 'newest' then m.created_at end desc nulls last,
               h.rn asc) as o
        from hit h join "MEDICINE" m on m.id = h.id
    ),
    pg as (select id, o from ord order by o offset v_off limit v_size)
    select (select count(*)::int from hit),
           coalesce((select array_agg(pg.id order by pg.o) from pg), '{}'::bigint[])
      into v_total, v_ids;
    v_got := coalesce(array_length(v_ids,1), 0);
  end if;

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
    'filters_active_label', case when v_filtered
      then public.uic('search.filters_on','Filters on') else '' end,
    'total', v_total,
    'count_label', case when v_typed then public.cat_count_label(v_total::bigint) else '' end,
    'header_label', case when v_typed
      then replace(replace(public.uic('search.header','{n} for “{q}”'),
                           '{n}', public.cat_count_label(v_total::bigint)), '{q}', v_q)
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

-- ── 6. clearing the strip ───────────────────────────────────────────────────
create or replace function public.search_recent_clear()
returns jsonb
language plpgsql volatile security definer set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    return jsonb_build_object('ok', true, 'cleared', 0);
  end if;
  delete from public.search_recent where user_id = v_uid;
  return jsonb_build_object('ok', true, 'cleared', 1,
    'toast', public.uic('search.recent_cleared','Recent searches cleared'));
end $function$;

-- ── 7. the old RPC, now a thin wrapper (ONE release) ────────────────────────
-- CMD #1906 — storefront_search_page is no longer an implementation. It maps
-- search_page onto the key names an app build from before this change reads,
-- so a cached bundle keeps working; the next release deletes it.
create or replace function public.storefront_search_page(
  search_term text,
  category_filter text default 'All'::text,
  page_offset integer default 0,
  page_limit integer default null::integer,
  p_zone boolean default true
) returns jsonb
language plpgsql volatile security definer set search_path to 'public'
as $function$
declare
  v_size int := greatest(coalesce(nullif(page_limit,0),
                  coalesce((select (value #>> '{}')::int from public.app_settings
                              where key = 'search_initial_limit'), 30)), 1);
  v_page int := case when v_size > 0 then greatest(coalesce(page_offset,0),0) / v_size else 0 end;
  v_p    jsonb;
begin
  v_p := public.search_page(search_term,
           jsonb_build_object('category', coalesce(nullif(btrim(category_filter),''),'All')),
           v_page, v_size, p_zone);
  return jsonb_build_object(
    'status','ok',
    'search_term', search_term,
    'category', coalesce(nullif(btrim(category_filter),''),'All'),
    'page_offset', v_page * v_size,
    'page_limit', v_size,
    'gated', v_p->'gated',
    'result_count', v_p#>'{paging,returned}',
    'result_total', v_p->'total',
    'showing_label', v_p->>'header_label',
    'empty_label', v_p->>'empty_label',
    'initial_limit', v_size,
    'more_limit', v_size,
    'next_offset', (v_page * v_size) + coalesce((v_p#>>'{paging,returned}')::int, 0),
    'has_more', v_p#>'{paging,has_more}',
    'more_label', v_p#>>'{paging,more_label}',
    'end_label', v_p#>>'{paging,end_label}',
    'zone_switch', v_p->'zone',
    'items', v_p->'items');
end $function$;

-- ── 8. copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('search.placeholder',      to_jsonb('Search medicines, salts, companies'::text)),
  ('search.filters_title',    to_jsonb('Filters'::text)),
  ('search.filters_clear',    to_jsonb('Clear all'::text)),
  ('search.filters_apply',    to_jsonb('Show results'::text)),
  ('search.filters_on',       to_jsonb('Filters on'::text)),
  ('search.f_category',       to_jsonb('Category'::text)),
  ('search.f_category_all',   to_jsonb('All'::text)),
  ('search.f_pack_type',      to_jsonb('Pack type'::text)),
  ('search.f_rx',             to_jsonb('Prescription'::text)),
  ('search.f_rx_only',        to_jsonb('Rx only'::text)),
  ('search.f_otc_only',       to_jsonb('OTC only'::text)),
  ('search.f_flags',          to_jsonb('Product'::text)),
  ('search.f_habit',          to_jsonb('Habit forming'::text)),
  ('search.f_cold',           to_jsonb('Cold chain'::text)),
  ('search.f_image',          to_jsonb('Has photo'::text)),
  ('search.f_scheme',         to_jsonb('Has scheme'::text)),
  ('search.sort_title',       to_jsonb('Sort'::text)),
  ('search.sort_relevance',   to_jsonb('Best match'::text)),
  ('search.sort_name',        to_jsonb('Name A–Z'::text)),
  ('search.sort_newest',      to_jsonb('Newest added'::text)),
  ('search.header',           to_jsonb('{n} for “{q}”'::text)),
  ('search.empty_no_query',   to_jsonb('Type a medicine, salt or company name.'::text)),
  ('search.empty_search',     to_jsonb('No product matches “{q}”.'::text)),
  ('search.empty_filtered',   to_jsonb('Nothing matching “{q}” fits these filters.'::text)),
  ('search.empty_hint',       to_jsonb('Check the spelling, or try a shorter word.'::text)),
  ('search.empty_action',     to_jsonb('Request this product'::text)),
  ('search.recent_title',     to_jsonb('Recent searches'::text)),
  ('search.recent_clear',     to_jsonb('Clear'::text)),
  ('search.recent_cleared',   to_jsonb('Recent searches cleared'::text)),
  ('search.load_more',        to_jsonb('Load more'::text)),
  ('search.list_end',         to_jsonb('That is the whole list.'::text))
on conflict (key) do nothing;

-- ── 9. grants ───────────────────────────────────────────────────────────────
-- Searching is public browsing on medibo.in, exactly as storefront_search_page
-- and catalogue_list already were. search_recent_clear is per-viewer and is a
-- no-op for anon (auth.uid() is null), so it is safe to expose but writes
-- nothing without a session.
revoke all on function public.search_page(text, jsonb, integer, integer, boolean) from public, anon, authenticated;
revoke all on function public.search_filter_defs(jsonb) from public, anon, authenticated;
-- The two helpers are only ever called from inside search_page, which is
-- SECURITY DEFINER and therefore runs them as its owner. Nobody outside needs
-- them, and _search_cards takes a discount percentage as an argument — a knob
-- no caller should be able to turn.
revoke all on function public._search_filtered(jsonb) from public, anon, authenticated;
revoke all on function public._search_cards(bigint[], numeric, smallint) from public, anon, authenticated;
revoke all on function public.search_recent_clear() from public, anon;

-- Searching is public browsing on medibo.in, exactly as storefront_search_page
-- and catalogue_list already were: anon may search and may read the filter set.
grant execute on function public.search_page(text, jsonb, integer, integer, boolean)
  to anon, authenticated, service_role;
grant execute on function public.search_filter_defs(jsonb) to anon, authenticated, service_role;
grant execute on function public._search_filtered(jsonb) to service_role;
grant execute on function public._search_cards(bigint[], numeric, smallint) to service_role;
-- The recent strip is per-viewer: it needs a session, so anon is revoked above.
grant execute on function public.search_recent_clear() to authenticated, service_role;
