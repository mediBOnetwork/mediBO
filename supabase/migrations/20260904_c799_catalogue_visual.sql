-- CHANGE #799 — the Catalogue tab's visual system, backend half.
--
-- Om's direction: search first, three calm doors, a filter row that reads like
-- a sentence, an A–Z rail you can drag, minimal cards carrying their own pack
-- variants, and empty states that teach and act. Every one of those is a
-- STRING or a STATE, so every one of them is decided here. The Flutter side of
-- this change renders what these functions return and nothing else.
--
-- Idempotent throughout: `create or replace`, `on conflict do update`.

-- ── copy ──────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('catalogue.search_placeholder', to_jsonb('Search a medicine, salt or company'::text)),
  ('catalogue.search_clear',       to_jsonb('Clear'::text)),
  ('catalogue.doors_title',        to_jsonb('Browse by'::text)),
  ('catalogue.door_company',       to_jsonb('Company'::text)),
  ('catalogue.door_salt',          to_jsonb('Salt'::text)),
  ('catalogue.door_category',      to_jsonb('Category'::text)),
  ('catalogue.recent_viewed_title',to_jsonb('Recently viewed'::text)),
  ('catalogue.sentence_lead',      to_jsonb('Showing'::text)),
  ('catalogue.sentence_all',       to_jsonb('everything'::text)),
  ('catalogue.sentence_sep',       to_jsonb('·'::text)),
  ('catalogue.sentence_zone',      to_jsonb('In my zone'::text)),
  ('catalogue.rail_label',         to_jsonb('Jump to a letter'::text)),
  ('catalogue.rail_other',         to_jsonb('#'::text)),
  ('catalogue.variants_title',     to_jsonb('Other packs'::text)),
  ('catalogue.peek_title',         to_jsonb('Quick look'::text)),
  ('catalogue.peek_open',          to_jsonb('Open full page'::text)),
  ('catalogue.added_toast',        to_jsonb('Added to cart'::text)),
  ('catalogue.added_undo',         to_jsonb('Undo'::text)),
  ('catalogue.empty_action',       to_jsonb('Request this product'::text)),
  ('catalogue.empty_zone_hint',    to_jsonb('Turn off "Available in my zone" to see the whole catalogue.'::text)),
  ('catalogue.company_salts_title',to_jsonb('Salts this company makes'::text)),
  ('catalogue.company_back',       to_jsonb('Back'::text))
on conflict (key) do nothing;

-- ── variants: the pack family a card belongs to ───────────────────────────
-- The variant's own words are the stored product name with the brand root
-- sliced off its front. Verbatim text, never a word invented here.
create or replace function public._cat_variant_rest(p_name text, p_root text)
returns text language sql immutable set search_path to public as $$
  select nullif(btrim(regexp_replace(
           coalesce(p_name,''),
           '^' || replace(regexp_replace(coalesce(p_root,''), '([\^$.|?*+()\[\]{}])', '\\\1', 'g'),
                          ' ', '[^a-zA-Z0-9]+')
                || '[^a-zA-Z0-9]*', '', 'i')), '');
$$;

-- The siblings of each id, keyed by id. Bounded: the brand root is a PREFIX
-- range on idx_medicine_name_norm_prefix, so this is 24 short index scans and
-- not a scan of the 5.6-lakh table.
--
-- `buyable` is filtered OUTSIDE the lateral on purpose. Inside it, the planner
-- bitmap-ANDs the prefix index with idx_medicine_buyable_true and reads 10,000
-- buffers to throw nearly all of them away — 800 ms for 24 cards. Outside, the
-- same answer costs 45 ms.
create or replace function public._cat_variants(p_ids bigint[])
returns jsonb language sql stable security definer set search_path to public as $$
  with me as (
    select m.id, m.marketer_canonical as mc,
           public._brand_root(m.product_name) as root
      from unnest(coalesce(p_ids,'{}'::bigint[])) i
      join public."MEDICINE" m on m.id = i
     where nullif(btrim(coalesce(m.product_name,'')),'') is not null
  ),
  sib as (
    select me.id as anchor, s.id, s.sales_count,
           coalesce(public._cat_variant_rest(s.product_name, me.root),
                    public.sf_pack_type_label(s.pack_type)) as label
      from me
      join lateral (
        select s2.id, s2.product_name, s2.pack_type, s2.sales_count, s2.buyable
          from public."MEDICINE" s2
         where public._norm_name(s2.product_name) operator(pg_catalog.~>=~) me.root
           and public._norm_name(s2.product_name) operator(pg_catalog.~<~)
               (left(me.root, length(me.root)-1) || chr(ascii(right(me.root,1)) + 1))
           and s2.marketer_canonical is not distinct from me.mc
           and public._brand_root(s2.product_name) = me.root
         limit 60) s on true
     where lower(coalesce(s.buyable::text,'')) in ('true','t')
  ),
  pick as (
    select distinct on (anchor, label) anchor, id, label
      from sib
     where nullif(btrim(label),'') is not null
     order by anchor, label, (id = anchor) desc, sales_count desc nulls last, id
  ),
  top as (
    select anchor, id, label,
           row_number() over (partition by anchor order by (id = anchor) desc, label) as rn,
           count(*) over (partition by anchor) as n
      from pick
  )
  select coalesce(jsonb_object_agg(anchor::text, blk), '{}'::jsonb)
    from (
      select anchor,
             jsonb_build_object(
               'has', max(n) > 1,
               'items', jsonb_agg(jsonb_build_object(
                          'product_id', id, 'label', label,
                          'selected', id = anchor) order by rn)) as blk
        from top where rn <= 4 group by anchor) z;
$$;

-- The public lane. Called AFTER a page of cards has painted, so the chips
-- arrive without the grid waiting on them: catalogue_list is already 190 ms on
-- a warm scope and this would have added 170 ms to every first paint.
create or replace function public.catalogue_variants(p_ids bigint[] default '{}'::bigint[])
returns jsonb language sql stable security definer set search_path to public as $$
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.variants_title','Other packs'),
    'map', public._cat_variants((select array_agg(x) from unnest(coalesce(p_ids,'{}'::bigint[]))
                                  with ordinality t(x, o) where o <= 60)));
$$;
grant execute on function public.catalogue_variants(bigint[]) to anon, authenticated;

-- ── the filter row, as a sentence ─────────────────────────────────────────
-- "Tablets · Rx · In my zone". Each part is a chip with its own label, its own
-- selected state and the group/key the app hands straight back to the filter
-- RPC. Nothing about this sentence — not the separator, not the lead word, not
-- which chips are worth offering — is decided in Dart.
create or replace function public.catalogue_sentence(
  p_filters jsonb default '{}'::jsonb,
  p_zone boolean default true,
  p_zone_count smallint default 0)
returns jsonb language sql stable security definer set search_path to public as $$
  with f as (select coalesce(p_filters,'{}'::jsonb) as j),
  zone as (select public.catalogue_zone_switch(p_zone) as z),
  -- The pack types worth offering when nothing is chosen yet: the biggest few
  -- in this zone, in the zone's own count order.
  offer as (
    select c.facet_key as key, c.label, c.n
      from public.catalogue_facet_count c
     where c.facet = 'pack_type' and c.zone_id = coalesce(p_zone_count, 0::smallint)
     order by c.n desc, c.label
     limit 3
  ),
  chosen_pack as (
    select c.facet_key as key, c.label
      from public.catalogue_facet_count c, f
     where c.facet = 'pack_type' and c.zone_id = coalesce(p_zone_count, 0::smallint)
       and coalesce(f.j->'pack_type','[]'::jsonb) ? c.facet_key
  ),
  parts as (
    -- selected pack types first, then the Rx verdict, then the zone, then the
    -- offers that are not already chosen. The ORDER is the sentence.
    select 1 as ord, 'pack_type' as grp, key, label, true as selected from chosen_pack
    union all
    select 2, 'rx', (select j->>'rx' from f),
           case (select j->>'rx' from f)
             when 'Rx'  then public.uic('catalogue.f_rx_only','Rx only')
             when 'OTC' then public.uic('catalogue.f_otc_only','OTC only') end,
           true
     where (select j->>'rx' from f) is not null
    union all
    select 3, 'flags', k.key, k.label, true
      from (values
        ('cold_chain',   public.uic('catalogue.f_cold','Cold chain')),
        ('has_scheme',   public.uic('catalogue.f_scheme','Has scheme')),
        ('has_image',    public.uic('catalogue.f_image','Has photo')),
        ('habit_forming',public.uic('catalogue.f_habit','Habit forming'))
      ) k(key, label), f
     where (f.j->>k.key) = 'true'
    union all
    select 4, 'zone', 'zone', public.uic('catalogue.sentence_zone','In my zone'), true
      from zone
     where (zone.z->>'has')::boolean and (zone.z->>'on')::boolean
    union all
    select 5, 'pack_type', o.key, o.label, false
      from offer o
     where not exists (select 1 from chosen_pack c where c.key = o.key)
    union all
    select 6, 'rx', 'Rx', public.uic('catalogue.f_rx_only','Rx only'), false
     where (select j->>'rx' from f) is null
  ),
  numbered as (
    select *, row_number() over (order by ord, label) as rn,
           count(*) filter (where selected) over () as n_sel
      from parts
  )
  select jsonb_build_object(
    'lead', public.uic('catalogue.sentence_lead','Showing'),
    'separator', public.uic('catalogue.sentence_sep','·'),
    'all_label', public.uic('catalogue.sentence_all','everything'),
    'clear_label', public.uic('catalogue.filters_clear','Clear all'),
    'has_selection', coalesce((select max(n_sel) from numbered), 0) > 0,
    'parts', coalesce((select jsonb_agg(jsonb_build_object(
                'group', grp, 'key', key, 'label', label,
                'selected', selected,
                'mode', case when grp in ('rx','zone') then 'single' else 'multi' end)
                order by rn) from numbered where key is not null and label is not null),
              '[]'::jsonb));
$$;
grant execute on function public.catalogue_sentence(jsonb, boolean, smallint) to anon, authenticated;

-- ── the three doors + the recently-viewed strip + the hero search ─────────
create or replace function public.catalogue_home(p_zone boolean default true)
returns jsonb language sql stable security definer set search_path to public as $$
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
    'sentence', public.catalogue_sentence('{}'::jsonb, p_zone, (select cz from z)),
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
$$;

-- ── the A–Z rail ──────────────────────────────────────────────────────────
-- The rail is EVERY letter, always, with the backend saying which ones have
-- companies behind them. A rail that grows and shrinks as you filter is a rail
-- you cannot learn the shape of, and drag-to-jump needs a fixed track.
create or replace function public.catalogue_companies(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40, p_zone boolean default true)
returns jsonb language sql stable security definer set search_path to public as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  have as (select letter, count(*) as n from public.catalogue_facet_count
            where facet='company' and zone_id=(select cz from z) group by letter),
  track as (
    select l.key,
           case when l.key = '#' then public.uic('catalogue.rail_other','#') else l.key end as label,
           coalesce(h.n, 0) as n
      from (select chr(64 + generate_series(1,26)) as key
            union all select '#') l
      left join have h on h.letter = l.key
  ),
  hit as (
    select c.facet_key, c.label, c.letter, c.n
      from public.catalogue_facet_count c
     where c.facet = 'company' and c.zone_id = (select cz from z)
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
  ),
  page as (select * from hit order by label
            offset (select off from lim) limit (select n from lim) + 1),
  shown as (select * from page order by label limit (select n from lim))
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.companies_title','Companies'),
    'zone', public.catalogue_zone_switch(p_zone),
    'letter', nullif(upper(btrim(coalesce(p_letter,''))),''),
    'q', nullif(btrim(coalesce(p_q,'')),''),
    'search_hint', public.uic('catalogue.company_search_hint','Search a company'),
    'all_label', public.uic('catalogue.letter_all','All'),
    'letters', coalesce((select jsonb_agg(jsonb_build_object('key', l.letter, 'label', l.letter, 'n', l.n)
                                order by l.letter) from have l), '[]'::jsonb),
    -- CHANGE #799 — the fixed drag-to-jump track.
    'rail', jsonb_build_object(
      'label', public.uic('catalogue.rail_label','Jump to a letter'),
      'all_label', public.uic('catalogue.letter_all','All'),
      'letters', coalesce((select jsonb_agg(jsonb_build_object(
                    'key', t.key, 'label', t.label, 'n', t.n, 'enabled', t.n > 0)
                    order by (t.key = '#'), t.key) from track t), '[]'::jsonb)),
    'count_label', to_char(case when nullif(btrim(coalesce(p_q,'')),'') is null
                                 and nullif(btrim(coalesce(p_letter,'')),'') is null
                                then public._cat_meta((select cz from z), 'companies')
                                else (select count(*) from hit) end,'FM9,99,99,999') || ' '
                   || public.uic('catalogue.companies_word','companies'),
    'empty_label', public.uic('catalogue.companies_empty','No company matches this view.'),
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'letter', s.letter,
              'n', s.n, 'count_label', public.cat_count_label(s.n::bigint)) order by s.label)
              from shown s), '[]'::jsonb));
$$;

-- ── the list: a free-text scope, a sentence filter row, an empty state ────
-- CHANGE #799 — `kind='search'`. The hero search bar and every brand the
-- typeahead offers land here. It is a PREFIX range on
-- idx_medicine_name_norm_prefix (`~>=~` / `~<~`, the text_pattern_ops
-- operators), not a trigram scan: a brand the shopper is already halfway
-- through typing is a prefix, and a prefix is the one shape 5.6 lakh rows can
-- answer in milliseconds.
create or replace function public._cat_where(p_kind text, p_key text, p_path text[], p_filters jsonb)
returns text language plpgsql immutable set search_path to public as $function$
declare w text := 'public.catalogue_universe_ok(m.status)'; v text; q text;
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

-- ── the list: a sentence filter row and an empty state that acts ──────────
create or replace function public.catalogue_list(
  p_kind text default 'tree', p_key text default null, p_path text[] default '{}'::text[],
  p_filters jsonb default '{}'::jsonb, p_sort text default 'name',
  p_zone boolean default true, p_cursor text default null, p_limit integer default 24)
returns jsonb language plpgsql stable security definer set search_path to public as $function$
declare
  v_zone smallint := public._cat_zone(p_zone);
  v_cz   smallint := public._cat_count_zone(p_zone);
  v_n    int      := least(greatest(coalesce(p_limit,24),1),50);
  v_sort text     := case when coalesce(p_sort,'name') = 'newest' then 'newest' else 'name' end;
  v_where text    := public._cat_where(p_kind, p_key, p_path, coalesce(p_filters,'{}'::jsonb));
  v_join  text    := case when v_zone is null then ''
                     else format('join public.catalogue_zone_avail za on za.product_id = m.id and za.zone_id = %L::smallint', v_zone) end;
  v_cur  jsonb;
  v_keyset text := '';
  v_order  text;
  v_sql    text;
  v_ids  bigint[];
  v_last_id bigint; v_last_name text;
  v_total bigint;
  -- CHANGE #799 — coalesced. `_cat_filtered('{}')` answers NULL, and the new
  -- empty-state block asks `not v_filtered` for whether to offer "Request this
  -- product": NULL there is neither true nor false, so an unfiltered empty
  -- scope silently lost its only way out.
  v_filtered boolean := coalesce(public._cat_filtered(coalesce(p_filters,'{}'::jsonb)), false);
  v_head text;
  v_zname text;
  v_empty text;
  v_zsw jsonb := public.catalogue_zone_switch(p_zone);
begin
  begin v_cur := nullif(btrim(coalesce(p_cursor,'')),'')::jsonb; exception when others then v_cur := null; end;

  if v_sort = 'newest' then
    v_order := 'order by m.id desc';
    if v_cur ? 'i' then v_keyset := format(' and m.id < %L::bigint', v_cur->>'i'); end if;
  else
    v_order := 'order by m.product_name, m.id';
    if v_cur ? 'i' then
      v_keyset := format(' and (m.product_name, m.id) > (%L, %L::bigint)',
                         coalesce(v_cur->>'n',''), v_cur->>'i');
    end if;
  end if;

  -- The LIMIT is inside, the numbering outside. Written the other way round
  -- (`row_number() over ()` beside the sort) the window ran BEFORE the sort, so
  -- it both materialised every matching row and numbered them in the wrong
  -- order — a cold-chain page walked 4,413 rows to return 24 of them, scrambled.
  v_sql := format(
    'select array_agg(t.id order by t.ord) from ('
    || 'select s.id, row_number() over () as ord from ('
    || 'select m.id, m.product_name from public."MEDICINE" m %s where %s%s %s limit %s'
    || ') s) t', v_join, v_where, v_keyset, v_order, v_n);
  execute v_sql into v_ids;
  v_ids := coalesce(v_ids, '{}'::bigint[]);

  if array_length(v_ids,1) is not null then
    select id, coalesce(product_name,'') into v_last_id, v_last_name
      from "MEDICINE" where id = v_ids[array_length(v_ids,1)];
  end if;

  v_total := case when v_filtered then null
                  else public._cat_scope_total(p_kind, p_key, p_path, v_cz) end;

  v_head := case
    when p_kind = 'company' then coalesce((select label from public.catalogue_facet_count
        where facet='company' and zone_id=v_cz and facet_key = coalesce(p_key,'')), coalesce(p_key,''))
    when p_kind = 'salt'    then coalesce(p_key,'')
    when p_kind = 'search'  then coalesce(nullif(btrim(coalesce(p_key,'')),''),
                                          public.uic('catalogue.all_products','All products'))
    when p_kind = 'tab' and p_key = 'schemes'    then public.uic('catalogue.tab_schemes','Schemes')
    when p_kind = 'tab' and p_key = 'cold_chain' then public.uic('catalogue.tab_cold','Cold chain')
    when p_kind = 'tree' and coalesce(array_length(p_path,1),0) > 0
      then p_path[array_length(p_path,1)]
    else public.uic('catalogue.all_products','All products') end;

  -- CHANGE #799 — the empty state names the SCOPE and the ZONE, because
  -- "Nothing here in this view" taught nobody anything. "No Cold chain in
  -- Raipur yet — request one" is the same fact with a way out of it.
  v_zname := nullif(v_zsw->>'zone_label','');
  v_empty := case
    when v_filtered then public.uic('catalogue.list_empty_filtered',
                       'Nothing matches these filters. Clear one and try again.')
    when v_zname is not null and coalesce((v_zsw->>'on')::boolean, false)
      then replace(replace(public.uic('catalogue.list_empty_zone',
             'No {scope} in {zone} yet.'), '{scope}', v_head), '{zone}', v_zname)
    else public.uic('catalogue.list_empty','Nothing here in this view.') end;

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind, 'key', p_key, 'path', to_jsonb(p_path),
    'title', v_head,
    'subtitle', case
      when p_kind = 'salt' then public.uic('catalogue.salt_subtitle','Every brand for this salt')
      when p_kind = 'company' then public.uic('catalogue.company_subtitle','Products from this company')
      when p_kind = 'search' then public.uic('catalogue.search_subtitle','Matches in the catalogue')
      else '' end,
    'zone', v_zsw,
    'sort', v_sort,
    'filters', public.catalogue_filter_defs(coalesce(p_filters,'{}'::jsonb), v_cz),
    'sentence', public.catalogue_sentence(coalesce(p_filters,'{}'::jsonb), p_zone, v_cz),
    'filters_active', v_filtered,
    'filters_active_label', case when v_filtered
      then public.uic('catalogue.filters_on','Filters on') else '' end,
    'total', v_total,
    'count_label', case when v_total is null
      then to_char(coalesce(array_length(v_ids,1),0),'FM9,99,99,999') || ' '
           || public.uic('catalogue.showing_word','shown')
      else public.cat_count_label(v_total) end,
    'empty_label', v_empty,
    'empty', jsonb_build_object(
      'label', v_empty,
      'hint', case when v_filtered then ''
                   when coalesce((v_zsw->>'has')::boolean, false)
                        and coalesce((v_zsw->>'on')::boolean, false)
                   then public.uic('catalogue.empty_zone_hint',
                          'Turn off "Available in my zone" to see the whole catalogue.')
                   else '' end,
      'action', jsonb_build_object(
        'has',  not v_filtered
                and coalesce((select request_open from public.catalogue_extras_config where id = 1), true),
        'kind', 'request',
        'label', public.uic('catalogue.empty_action','Request this product')),
      'clear', jsonb_build_object(
        'has', v_filtered,
        'kind','clear_filters',
        'label', public.uic('catalogue.filters_clear','Clear all'))),
    'limit', v_n,
    'has_more', coalesce(array_length(v_ids,1),0) = v_n,
    'more_label', public.uic('catalogue.load_more','Load more'),
    'end_label', public.uic('catalogue.list_end','That is the whole list.'),
    'next_cursor', case when coalesce(array_length(v_ids,1),0) = v_n and v_last_id is not null
      then (case when v_sort = 'newest'
                 then jsonb_build_object('i', v_last_id)
                 else jsonb_build_object('i', v_last_id, 'n', v_last_name) end)::text
      end,
    'items', public._cat_cards(v_ids));
end $function$;

insert into public.ui_copy(key, value) values
  ('catalogue.list_empty_zone', to_jsonb('No {scope} in {zone} yet.'::text)),
  ('catalogue.search_subtitle', to_jsonb('Matches in the catalogue'::text))
on conflict (key) do nothing;

-- ── the company page: a salt cloud and a header that collapses ────────────
-- The cloud is its OWN call, for the same reason the pack variants are: the
-- group-by over a big marketer's 2,510 rows costs a second, and a header must
-- not hold the products behind it. The page paints name + count immediately
-- and the cloud lands into it.
create or replace function public.company_salt_cloud(p_key text)
returns jsonb language sql stable security definer set search_path to public as $function$
  with s as (
    select nullif(btrim(m.salt_composition),'') as salt, count(*)::bigint as n
      from public."MEDICINE" m
     where m.marketer_canonical = p_key
       and lower(coalesce(m.buyable::text,'')) in ('true','t')
       and nullif(btrim(m.salt_composition),'') is not null
     group by 1 order by 2 desc, 1 limit 12)
  select jsonb_build_object(
    'ok', true,
    'has', exists (select 1 from s),
    'title', public.uic('catalogue.company_salts_title','Salts this company makes'),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
                'key', s.salt, 'label', s.salt,
                'count_label', public.cat_count_label(s.n)) order by s.n desc, s.salt)
                from s), '[]'::jsonb));
$function$;
grant execute on function public.company_salt_cloud(text) to anon, authenticated;

create or replace function public.storefront_company_page(
  p_key text, p_offset integer default 0, p_limit integer default 24)
returns jsonb language plpgsql stable security definer set search_path to public as $function$
declare c record; v_ids bigint[]; v_total int;
begin
  select display, canon, buyable_count into c from medicine_company where canon = p_key;
  if c.canon is null then return jsonb_build_object('ok', false, 'error', 'company_not_found'); end if;
  select array_agg(id) into v_ids from (
    select id from "MEDICINE"
    where marketer_canonical = p_key and lower(coalesce(buyable::text,'')) in ('true','t')
    order by sales_count desc nulls last, id
    offset greatest(p_offset,0) limit least(greatest(p_limit,1),50)) t;
  v_total := coalesce(c.buyable_count, 0);

  return jsonb_build_object(
    'ok', true,
    'company', jsonb_build_object('label', c.display, 'key', c.canon,
      -- CHANGE #799 — the logo box's fallback mark. There is no company
      -- artwork in the catalogue, so the entity's own initial is the honest
      -- one, composed here because it is a display string.
      'icon_letter', upper(left(btrim(coalesce(c.display,'?')), 1)),
      'sub_label', to_char(v_total,'FM999,999')||' products',
      'count_label', to_char(v_total,'FM999,999')||' products'),
    'back_label', public.uic('catalogue.company_back','Back'),
    'items', public._sf_cards(coalesce(v_ids, '{}'::bigint[])),
    'offset', greatest(p_offset,0),
    'has_more', (greatest(p_offset,0) + coalesce(array_length(v_ids,1),0)) < v_total);
end $function$;

-- ── the extras block gains the motion copy ────────────────────────────────
-- The add toast, its undo word and the quick-peek headings. Dart shows a
-- snackbar only when these arrive: a toast worded in the app is a toast that
-- cannot be changed without a deploy.
create or replace function public.catalogue_extras(p_zone boolean default true)
returns jsonb language plpgsql stable security definer set search_path to public as $function$
declare c public.catalogue_extras_config%rowtype; v_recent int; v jsonb;
begin
  select * into c from public.catalogue_extras_config where id = 1;
  select count(*) into v_recent from public."MEDICINE"
   where created_at is not null
     and created_at >= now() - make_interval(days => coalesce(c.new_days,30));

  return jsonb_build_object(
    'recent', jsonb_build_object(
      'key',   'recent',
      'kind',  'recent',
      'label', public.uic('catalogue.recent_title','Recently added'),
      'count', v_recent,
      'count_label', public.cat_count_label(v_recent::bigint),
      'show',  v_recent > 0),
    'added', jsonb_build_object(
      'label',      public.uic('catalogue.added_toast','Added to cart'),
      'undo_label', public.uic('catalogue.added_undo','Undo')),
    'peek', jsonb_build_object(
      'title',      public.uic('catalogue.peek_title','Quick look'),
      'open_label', public.uic('catalogue.peek_open','Open full page')),
    'request', jsonb_build_object(
      'show',         coalesce(c.request_open,true),
      'title',        public.uic('catalogue.request_title','Missing product?'),
      'subtitle',     public.uic('catalogue.request_sub','Tell us what you could not find and we will add it.'),
      'submit_label', public.uic('catalogue.request_submit','Send request'),
      'fields', jsonb_build_array(
        jsonb_build_object('key','name',    'label', public.uic('catalogue.request_name','Product name'),    'required', true),
        jsonb_build_object('key','company', 'label', public.uic('catalogue.request_company','Company'),      'required', false),
        jsonb_build_object('key','salt',    'label', public.uic('catalogue.request_salt','Salt / composition'),'required', false),
        jsonb_build_object('key','pack',    'label', public.uic('catalogue.request_pack','Pack'),            'required', false)),
      'photo_label',  public.uic('catalogue.request_photo','Add a photo (optional)')),
    'export', jsonb_build_object(
      'show',         true,
      'title',        public.uic('catalogue.export_title','Print / share my catalogue list'),
      'subtitle',     public.uic('catalogue.export_sub','A plain product list — no prices.'),
      'action_label', public.uic('catalogue.export_action','Make the PDF'),
      'max',          coalesce(c.export_max,500)));
end $function$;
