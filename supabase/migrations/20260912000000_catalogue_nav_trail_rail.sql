-- CMD #1908 — Catalogue navigation: one trail, one letter strip, no pack chips
-- inside a drill-down.
--
-- Three facts move into the backend here, because all three were either
-- missing or being decided by the screen:
--
--   1. THE TRAIL. Every catalogue payload now carries `trail` — the words AND
--      the route each word goes back to. The app prints the words and copies
--      the route; it never joins "Catalogue" to a tab name, never counts a
--      depth and never decides that a company page sits under "Company".
--   2. THE LETTER TRACK. `_cat_rail()` builds the same fixed A–Z track for
--      companies, salts and classes, so one widget can draw all three. The
--      track is EVERY letter, always, with `enabled` saying which ones have
--      rows behind them — a track that changes length cannot be learned.
--   3. WHICH CHIPS A LIST OFFERS. The pack/Rx sentence belongs to a SEARCH,
--      where you are narrowing a guess. Inside a company, a salt or a class
--      you already chose the scope, so `catalogue_list()` returns an empty
--      sentence and empty filter groups there. The SORT options stay — that is
--      how you read a list you already scoped.
--
-- Idempotent: every object is create-or-replace, and the two signature changes
-- drop the old arity first so the replay cannot leave an ambiguous overload.

-- ── 1. the letter of a label ────────────────────────────────────────────────
create or replace function public._cat_letter(p_label text)
returns text
language sql
immutable
set search_path to 'public'
as $$
  select case
    when upper(left(btrim(coalesce(p_label,'')),1)) between 'A' and 'Z'
      then upper(left(btrim(p_label),1))
    else '#' end;
$$;

-- ── 2. the fixed A–Z track, for any facet ───────────────────────────────────
-- The track is A..Z then '#', always all 27, in that order. `n` is how many
-- rows sit behind the letter in THIS scope and `enabled` is n > 0.
create or replace function public._cat_rail(
  p_facet text,
  p_zone_count smallint,
  p_parent text default null
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with have as (
    select public._cat_letter(c.label) as key, count(*)::bigint as n
      from public.catalogue_facet_count c
     where c.facet = p_facet
       and c.zone_id = coalesce(p_zone_count, 0::smallint)
       and (p_parent is null or c.parent_key = p_parent)
     group by 1
  ),
  track as (
    select l.key,
           case when l.key = '#' then public.uic('catalogue.rail_other','#') else l.key end as label,
           coalesce(h.n, 0) as n
      from (select chr(64 + generate_series(1,26)) as key
            union all select '#') l
      left join have h on h.key = l.key
  )
  select jsonb_build_object(
    'label', public.uic('catalogue.rail_label','Jump to a letter'),
    'all_label', public.uic('catalogue.letter_all','All'),
    -- An index over NOTHING is furniture. A scope with no rows behind any
    -- letter (a leaf class, an empty zone) sends no track at all, and the app
    -- draws no strip — rather than 27 grey letters that cannot be tapped.
    'letters', case when not exists (select 1 from have) then '[]'::jsonb
               else coalesce((select jsonb_agg(jsonb_build_object(
                  'key', t.key, 'label', t.label, 'n', t.n, 'enabled', t.n > 0)
                  order by (t.key = '#'), t.key) from track t), '[]'::jsonb) end);
$$;

-- ── 3. the breadcrumb ───────────────────────────────────────────────────────
-- "Catalogue › Company › SUN PHARMA"
-- "Catalogue › Category › ANTI INFECTIVES › Cephalosporins"
-- "Catalogue › Salt › Ofloxacin (200mg)"
--
-- Every item carries its own `route` — the four values the screen's route is
-- made of. Tapping a crumb is "copy this object into the route", which is why
-- the app can be sure a crumb goes where the backend says and nowhere else.
create or replace function public.catalogue_trail(
  p_tab text default 'browse',
  p_path text[] default '{}'::text[],
  p_kind text default null,
  p_key text default null,
  p_title text default null
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
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
    'route', jsonb_build_object('tab','browse','path','[]'::jsonb,
                                'list_kind', null, 'list_key', null)));

  -- Which section of the catalogue this is. The LIST kind wins over the tab,
  -- because a company list opened from a search is still under "Company".
  if v_kind = 'company' or v_tab = 'companies' then
    v_sect := public.uic('catalogue.trail_company','Company');  v_stab := 'companies';
  elsif v_kind = 'salt' or v_tab = 'salts' then
    v_sect := public.uic('catalogue.trail_salt','Salt');        v_stab := 'salts';
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
    when v_kind in ('company','salt','search')
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
end $$;

-- ── 4. companies: same payload, plus the trail ──────────────────────────────
create or replace function public.catalogue_companies(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  have as (select letter, count(*) as n from public.catalogue_facet_count
            where facet='company' and zone_id=(select cz from z) group by letter),
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
    'trail', public.catalogue_trail('companies', '{}'::text[], null, null, null),
    'letters', coalesce((select jsonb_agg(jsonb_build_object('key', l.letter, 'label', l.letter, 'n', l.n)
                                order by l.letter) from have l), '[]'::jsonb),
    'rail', public._cat_rail('company', (select cz from z), null),
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

-- ── 5. salts: a letter track of its own ─────────────────────────────────────
-- The old 4-argument shape is dropped first so the new default cannot create
-- an ambiguous overload (the app calls with named arguments).
drop function if exists public.catalogue_salts(text, integer, integer, boolean);

create or replace function public.catalogue_salts(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  hit as (
    select c.facet_key, c.label, c.n, public._cat_letter(c.label) as letter
      from public.catalogue_facet_count c
     where c.facet = 'salt' and c.zone_id = (select cz from z)
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or public._cat_letter(c.label) = upper(btrim(p_letter)))
  ),
  -- Biggest first is the salt list's own order. Once a letter is picked the
  -- letter IS the ordering the reader is looking for, so it reads A→Z.
  page as (select * from hit
            order by case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else label end nulls last,
                     n desc, facet_key
            offset (select off from lim) limit (select n from lim) + 1),
  shown as (select * from page
             order by case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else label end nulls last,
                      n desc, facet_key
             limit (select n from lim))
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.salts_title','Salts'),
    'zone', public.catalogue_zone_switch(p_zone),
    'letter', nullif(upper(btrim(coalesce(p_letter,''))),''),
    'q', nullif(btrim(coalesce(p_q,'')),''),
    'all_label', public.uic('catalogue.letter_all','All'),
    'trail', public.catalogue_trail('salts', '{}'::text[], null, null, null),
    'rail', public._cat_rail('salt', (select cz from z), null),
    -- CMD #1908 — the salt list lost its own search box: the one search bar at
    -- the top of the screen and this letter track are the two ways in. The
    -- hint stays in the payload for any caller that still offers a field.
    'search_hint', public.uic('catalogue.salt_search_hint','Search a salt, e.g. Paracetamol'),
    'lead_label', public.uic('catalogue.salts_lead','Biggest salts first — search to narrow.'),
    'brands_word', public.uic('catalogue.brands_word','brands'),
    'empty_label', public.uic('catalogue.salts_empty','No salt matches this search in this view.'),
    'count_label', to_char((select count(*) from hit),'FM9,99,99,999') || ' '
                   || public.uic('catalogue.salts_word','salts'),
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'n', s.n, 'letter', s.letter,
              'count_label', to_char(s.n,'FM9,99,99,999') || ' '
                             || case when s.n = 1 then public.uic('catalogue.brand_word','brand')
                                     else public.uic('catalogue.brands_word','brands') end)
              order by case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else s.label end nulls last,
                       s.n desc, s.facet_key)
              from shown s), '[]'::jsonb));
$$;

-- ── 6. classes: the same letter track, the same trail ───────────────────────
drop function if exists public.catalogue_tree(text[], boolean);

create or replace function public.catalogue_tree(
  p_path text[] default '{}'::text[],
  p_letter text default null,
  p_zone boolean default true)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lvl as (select coalesce(array_length(p_path,1),0) as d),
  node as (
    select case (select d from lvl)
             when 0 then 'therapeutic' when 1 then 'chemical' else 'action' end as facet,
           case (select d from lvl)
             when 0 then '' when 1 then p_path[1]
             else public.catalogue_parent_key(p_path[1], p_path[2]) end as parent
  ),
  rows as (
    select c.facet_key, c.label, c.n
      from public.catalogue_facet_count c
     where c.zone_id = (select cz from z)
       and c.facet   = (select facet from node)
       and c.parent_key = (select parent from node)
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or public._cat_letter(c.label) = upper(btrim(p_letter)))
     order by c.n desc, c.label
  )
  select jsonb_build_object(
    'ok', true,
    'title', case (select d from lvl)
               when 0 then public.uic('catalogue.tree_l0','Therapeutic class')
               when 1 then public.uic('catalogue.tree_l1','Chemical class')
               else        public.uic('catalogue.tree_l2','Action class') end,
    'level', (select d from lvl),
    'path', to_jsonb(p_path),
    'zone', public.catalogue_zone_switch(p_zone),
    'letter', nullif(upper(btrim(coalesce(p_letter,''))),''),
    'all_label', public.uic('catalogue.letter_all','All'),
    -- CMD #1908 — the crumb trail is `trail` now: the words AND where each
    -- word goes. `crumbs` stays for one release so an older bundle keeps
    -- painting a trail while the new one rolls out.
    'crumbs', (select coalesce(jsonb_agg(jsonb_build_object(
                 'label', p, 'depth', o) order by o), '[]'::jsonb)
                 from unnest(p_path) with ordinality t(p, o)),
    'trail', public.catalogue_trail('browse', p_path, 'tree', null, null),
    'rail', public._cat_rail((select facet from node), (select cz from z), (select parent from node)),
    'home_label', public.uic('catalogue.tree_home','All classes'),
    'child_opens', case when (select d from lvl) >= 2 then 'products' else 'level' end,
    'products_label', public.uic('catalogue.tree_products','View products'),
    'has_products', (select d from lvl) >= 1,
    'empty_label', case when (select d from lvl) = 0
                        then public.uic('catalogue.tree_empty_root','The catalogue has no classes in this view.')
                        else public.uic('catalogue.tree_empty','Nothing below this class in this view — open the products instead.') end,
    'count_label', public.cat_count_label(coalesce((select sum(n)::bigint from rows),0::bigint)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', r.facet_key, 'label', r.label,
              'n', r.n, 'count_label', public.cat_count_label(r.n::bigint))
              order by r.n desc, r.label) from rows r), '[]'::jsonb));
$$;

-- ── 7. the product list: a trail, and chips only where they belong ──────────
create or replace function public.catalogue_list(
  p_kind text default 'tree'::text, p_key text default null,
  p_path text[] default '{}'::text[], p_filters jsonb default '{}'::jsonb,
  p_sort text default 'name'::text, p_zone boolean default true,
  p_cursor text default null, p_limit integer default 24)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
  v_filtered boolean := coalesce(public._cat_filtered(coalesce(p_filters,'{}'::jsonb)), false);
  v_head text;
  v_zname text;
  v_empty text;
  v_zsw jsonb := public.catalogue_zone_switch(p_zone);
  -- CMD #1908 — the narrowing chips are a SEARCH tool. Inside a company, a
  -- salt or a class the scope is already chosen, so the sentence and the
  -- filter GROUPS are empty there. The sort options are not filters and stay.
  v_narrow boolean := (p_kind = 'search');
  v_filters jsonb;
  v_sentence jsonb;
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

  v_zname := nullif(v_zsw->>'zone_label','');
  v_empty := case
    when v_filtered then public.uic('catalogue.list_empty_filtered',
                       'Nothing matches these filters. Clear one and try again.')
    when v_zname is not null and coalesce((v_zsw->>'on')::boolean, false)
      then replace(replace(public.uic('catalogue.list_empty_zone',
             'No {scope} in {zone} yet.'), '{scope}', v_head), '{zone}', v_zname)
    else public.uic('catalogue.list_empty','Nothing here in this view.') end;

  v_filters := public.catalogue_filter_defs(coalesce(p_filters,'{}'::jsonb), v_cz);
  if not v_narrow then
    v_filters := jsonb_set(v_filters, '{groups}', '[]'::jsonb);
    v_sentence := jsonb_build_object(
      'lead','', 'separator','', 'all_label','', 'clear_label','',
      'has_selection', false, 'parts', '[]'::jsonb);
  else
    v_sentence := public.catalogue_sentence(coalesce(p_filters,'{}'::jsonb), p_zone, v_cz);
  end if;

  return jsonb_build_object(
    'ok', true,
    'kind', p_kind, 'key', p_key, 'path', to_jsonb(p_path),
    'title', v_head,
    'subtitle', case
      when p_kind = 'salt' then public.uic('catalogue.salt_subtitle','Every brand for this salt')
      when p_kind = 'company' then public.uic('catalogue.company_subtitle','Products from this company')
      when p_kind = 'search' then public.uic('catalogue.search_subtitle','Matches in the catalogue')
      else '' end,
    'trail', public.catalogue_trail(
               case when p_kind = 'company' then 'companies'
                    when p_kind = 'salt' then 'salts'
                    else 'browse' end,
               p_path, p_kind, p_key, v_head),
    'zone', v_zsw,
    'sort', v_sort,
    'filters', v_filters,
    'sentence', v_sentence,
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

-- ── 8. the words ────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('catalogue.trail_root',     to_jsonb('Catalogue'::text)),
  ('catalogue.trail_company',  to_jsonb('Company'::text)),
  ('catalogue.trail_salt',     to_jsonb('Salt'::text)),
  ('catalogue.trail_category', to_jsonb('Category'::text)),
  ('catalogue.trail_search',   to_jsonb('Search'::text)),
  ('catalogue.trail_label',    to_jsonb('You are here'::text)),
  ('catalogue.trail_sep',      to_jsonb('›'::text)),
  ('catalogue.salts_word',     to_jsonb('salts'::text))
on conflict (key) do nothing;

-- ── 9. grants ───────────────────────────────────────────────────────────────
-- The catalogue is public browsing: anon reads it on medibo.in before login,
-- exactly as catalogue_companies/_tree/_list already did.
grant execute on function public._cat_letter(text) to anon, authenticated, service_role;
grant execute on function public._cat_rail(text, smallint, text) to anon, authenticated, service_role;
grant execute on function public.catalogue_trail(text, text[], text, text, text) to anon, authenticated, service_role;
grant execute on function public.catalogue_salts(text, text, integer, integer, boolean) to anon, authenticated, service_role;
grant execute on function public.catalogue_tree(text[], text, boolean) to anon, authenticated, service_role;
