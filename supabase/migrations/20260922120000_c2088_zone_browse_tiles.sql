-- CMD #2088 — the Catalogue's Browse-by tiles count the VIEWER'S ZONE.
--
-- The four tiles printed 18,563 companies / 1,06,571 salts / 47,910 and
-- 3,43,545 products: the whole catalogue, in a shop that can only sell what a
-- zone supplier actually stands by. `catalogue_facet_count` has carried a
-- zone_id since the cache was built (zone 0 = the whole catalogue, a real zone
-- = the rows joined to `catalogue_zone_avail`, which `_zone_avail_sync` keeps
-- live off medicine_zone_standby). Nothing needed computing — the landing was
-- simply reading row 0.
--
-- Everything here is data or a payload string. Idempotent: CREATE OR REPLACE
-- plus upserts.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. ONE zone resolver, and it is the one the product grids already use.
--
-- `_cat_avail_zone()` decided the Available-in-your-zone / Not-available split
-- inside catalogue_list(). It answered for an approved CUSTOMER only, so every
-- staff session fell back to "all zones" and saw the whole catalogue with no
-- split at all. It now answers for staff too — a partner is zone-locked and a
-- super admin's header pick wins, both through admin_active_zone(), which
-- my_zone_id() already routes to. The facet-count gate is unchanged and is the
-- safety net: a zone whose cache has never been built answers NULL and the
-- caller reads the whole catalogue rather than printing zeroes.
create or replace function public._cat_avail_zone()
returns smallint
language sql stable security definer set search_path to 'public'
as $$
  select z.zid
    from (select coalesce(public._viewer_zone_or_null(), public.my_zone_id()) as zid) z
   where z.zid is not null
     and exists (select 1 from public.catalogue_facet_count c
                  where c.zone_id = z.zid and c.facet = 'meta');
$$;

-- The tiles, the lists and the group dividers all ask this one question.
create or replace function public._cat_tile_zone()
returns smallint
language sql stable security definer set search_path to 'public'
as $$ select coalesce(public._cat_avail_zone(), 0::smallint) $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. The tile line. Word, number and sentence all arrive from the backend;
--    the number is grouped the Indian way, like every other count on the page.
create or replace function public.cat_avail_line(p_word text, p_n bigint)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select replace(
           replace(public.uic('catalogue.avail_line', '{word} {n} available'),
                   '{word}', coalesce(p_word, '')),
           '{n}', to_char(coalesce(p_n, 0), 'FM9,99,99,999'));
$$;

insert into public.ui_copy(key, value) values
  ('catalogue.avail_line',        '"{word} {n} available"'::jsonb),
  ('catalogue.tile_word_company',   '"Companies"'::jsonb),
  ('catalogue.tile_word_salt',      '"Salts"'::jsonb),
  ('catalogue.tile_word_condition', '"Conditions"'::jsonb),
  ('catalogue.tile_word_category',  '"Categories"'::jsonb),
  ('catalogue.tile_word_products',  '"Products"'::jsonb),
  ('catalogue.door_condition',      '"Condition"'::jsonb),
  ('catalogue.doors_title',         '"Browse by"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────
-- 3. ONE RPC returns the four tiles.
--
-- Two lines each and nothing else: the entity count and the products behind
-- it, both scoped to the viewer's zone. The letter discs (K/D/B/S), the two
-- sample salts, the two sample uses and the ANTI INFECTIVES chip are gone —
-- they were a preview of the whole catalogue sitting under a number that is
-- now about one zone, and a tile that shows a product it cannot sell is the
-- same lie in a smaller font. Tile ORDER is data (app_settings.catalogue_
-- landing -> door_order), so re-ordering the grid is an UPDATE.
create or replace function public.catalogue_browse_tiles()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with az as (select public._cat_tile_zone() as z),
  cfg as (select public._cat_landing_cfg() as c),
  n as (
    select
      public._cat_meta((select z from az), 'companies') as companies,
      coalesce((select sum(c.n)::bigint from public.catalogue_facet_count c
                 where c.facet = 'company' and c.zone_id = (select z from az)), 0::bigint)
        as company_products,
      public._cat_meta((select z from az), 'salts') as salts,
      coalesce((select sum(c.n)::bigint from public.catalogue_facet_count c
                 where c.facet = 'salt' and c.zone_id = (select z from az)), 0::bigint)
        as salt_products,
      public._cat_meta((select z from az), 'conditions') as conditions,
      public._cat_meta((select z from az), 'condition_products') as condition_products,
      coalesce((select count(*)::bigint from public.catalogue_facet_count c
                 where c.facet = 'therapeutic' and c.zone_id = (select z from az)
                   and c.parent_key = ''), 0::bigint) as categories,
      coalesce((select sum(c.n)::bigint from public.catalogue_facet_count c
                 where c.facet = 'therapeutic' and c.zone_id = (select z from az)
                   and c.parent_key = ''), 0::bigint) as category_products
  ),
  tile as (
    select 'companies'::text as key, 'companies'::text as kind, 'companies'::text as tab,
           public.uic('catalogue.door_company', 'Company') as label,
           'store'::text as icon_key,
           (select c->'tiles'->'companies' from cfg) as gradient,
           public.cat_avail_line(public.uic('catalogue.tile_word_company', 'Companies'),
                                 (select companies from n)) as entity_label,
           public.cat_avail_line(public.uic('catalogue.tile_word_products', 'Products'),
                                 (select company_products from n)) as products_label
    union all
    select 'salts', 'salts', 'salts',
           public.uic('catalogue.door_salt', 'Salt'), 'science',
           (select c->'tiles'->'salts' from cfg),
           public.cat_avail_line(public.uic('catalogue.tile_word_salt', 'Salts'),
                                 (select salts from n)),
           public.cat_avail_line(public.uic('catalogue.tile_word_products', 'Products'),
                                 (select salt_products from n))
    union all
    select 'conditions', 'conditions', 'conditions',
           public.uic('catalogue.door_condition', 'Condition'), 'medication',
           (select c->'tiles'->'conditions' from cfg),
           public.cat_avail_line(public.uic('catalogue.tile_word_condition', 'Conditions'),
                                 (select conditions from n)),
           public.cat_avail_line(public.uic('catalogue.tile_word_products', 'Products'),
                                 (select condition_products from n))
    union all
    select 'browse', 'tree', 'browse',
           public.uic('catalogue.door_category', 'Category'), 'book',
           (select c->'tiles'->'browse' from cfg),
           public.cat_avail_line(public.uic('catalogue.tile_word_category', 'Categories'),
                                 (select categories from n)),
           public.cat_avail_line(public.uic('catalogue.tile_word_products', 'Products'),
                                 (select category_products from n))
  ),
  ord as (
    select o.key, o.pos
      from jsonb_array_elements_text(
             coalesce((select c->'door_order' from cfg),
                      '["companies","salts","conditions","browse"]'::jsonb))
           with ordinality o(key, pos)
  )
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.doors_title', 'Browse by'),
    'zone_id', (select z from az),
    'tiles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', t.key, 'kind', t.kind, 'tab', t.tab,
               'label', t.label,
               'icon_key', t.icon_key,
               'gradient', t.gradient,
               'entity_label', t.entity_label,
               'products_label', t.products_label,
               -- Older bundles print `count_label`; they get the entity line.
               'count_label', t.entity_label)
             order by o.pos)
        from tile t join ord o on o.key = t.key), '[]'::jsonb));
$$;

revoke all on function public.catalogue_browse_tiles() from public;
grant execute on function public.catalogue_browse_tiles() to anon, authenticated, service_role;
grant execute on function public.cat_avail_line(text, bigint) to anon, authenticated, service_role;
grant execute on function public._cat_tile_zone() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The drill-down lists: zone-available first, everything else below.
--
-- Each list reads the viewer's zone for its first group and zone 0 for the
-- rest, anti-joined so nothing appears twice. Two index-driven branches, not
-- one sorted join — idx_cat_facet_key_zone carries the anti-join. The header
-- count is the zone count, which is the number the tile printed, and the
-- divider between the groups is cat_group_label() — the same sentence the
-- product grids have used since #1909.
--
-- `group_label` is non-empty on the first row of a group in the returned page,
-- and empty on every other row: the app prints whatever arrived and decides
-- nothing.

create or replace function public.catalogue_companies(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  az as (select public._cat_avail_zone() as az),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  have as (select letter, count(*) as n from public.catalogue_facet_count
            where facet='company' and zone_id=(select cz from z) group by letter),
  hit as (
    -- group 0: available in the viewer's zone (or the whole catalogue when
    -- there is no zone to speak of)
    select c.facet_key, c.label, c.letter, c.n, 0::smallint as grp
      from public.catalogue_facet_count c
     where c.facet = 'company'
       and c.zone_id = coalesce((select az from az), (select cz from z))
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
    union all
    -- group 1: the rest of the catalogue, only when a zone narrowed group 0
    select c.facet_key, c.label, c.letter, c.n, 1::smallint
      from public.catalogue_facet_count c
     where (select az from az) is not null
       and c.facet = 'company' and c.zone_id = (select cz from z)
       and not exists (select 1 from public.catalogue_facet_count a
                        where a.facet = 'company' and a.facet_key = c.facet_key
                          and a.zone_id = (select az from az))
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
  ),
  grp_n as (select grp, count(*) as n from hit group by grp),
  page as (select * from hit order by grp, label
            offset (select off from lim) limit (select n from lim) + 1),
  shown as (select p.*, row_number() over (partition by p.grp order by p.label) as rn
              from (select * from page order by grp, label limit (select n from lim)) p)
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
    -- The header count is the tile's number: what this zone can actually sell.
    'count_label', to_char(case when nullif(btrim(coalesce(p_q,'')),'') is null
                                 and nullif(btrim(coalesce(p_letter,'')),'') is null
                                then public._cat_meta(public._cat_tile_zone(), 'companies')
                                else coalesce((select n from grp_n where grp = 0), 0) end,
                           'FM9,99,99,999') || ' '
                   || public.uic('catalogue.companies_word','companies'),
    'empty_label', public.uic('catalogue.companies_empty','No company matches this view.'),
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'letter', s.letter,
              'n', s.n, 'count_label', public.cat_count_label(s.n::bigint),
              'group', s.grp,
              'group_label', case when s.rn = 1 and (select az from az) is not null
                                  then public.cat_group_label(
                                         case when s.grp = 0 then 'in' else 'out' end,
                                         (select g.n from grp_n g where g.grp = s.grp))
                                  else '' end)
              order by s.grp, s.label)
              from shown s), '[]'::jsonb));
$$;

create or replace function public.catalogue_salts(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  az as (select public._cat_avail_zone() as az),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  lt as (select nullif(upper(btrim(coalesce(p_letter,''))),'') as l),
  hit as (
    select c.facet_key, c.label, c.n, c.letter, 0::smallint as grp
      from public.catalogue_facet_count c
     where c.facet = 'salt'
       and c.zone_id = coalesce((select az from az), (select cz from z))
       and c.letter between coalesce((select l from lt),'') and coalesce((select l from lt),'zzzzz')
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
    union all
    select c.facet_key, c.label, c.n, c.letter, 1::smallint
      from public.catalogue_facet_count c
     where (select az from az) is not null
       and c.facet = 'salt' and c.zone_id = (select cz from z)
       and c.letter between coalesce((select l from lt),'') and coalesce((select l from lt),'zzzzz')
       and not exists (select 1 from public.catalogue_facet_count a
                        where a.facet = 'salt' and a.facet_key = c.facet_key
                          and a.zone_id = (select az from az))
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%')
  ),
  grp_n as (select grp, count(*) as n from hit group by grp),
  -- Biggest first is the salt list's own order; a picked letter reads A→Z.
  -- The zone group always comes first.
  page as (select * from hit
            order by grp,
                     case when (select l from lt) is null then null else label end nulls last,
                     n desc, facet_key
            offset (select off from lim) limit (select n from lim) + 1),
  shown as (select p.*, row_number() over (
                     partition by p.grp
                     order by case when (select l from lt) is null then null else p.label end nulls last,
                              p.n desc, p.facet_key) as rn
              from (select * from page
                     order by grp,
                              case when (select l from lt) is null then null else label end nulls last,
                              n desc, facet_key
                     limit (select n from lim)) p)
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.salts_title','Salts'),
    'zone', public.catalogue_zone_switch(p_zone),
    'letter', nullif(upper(btrim(coalesce(p_letter,''))),''),
    'q', nullif(btrim(coalesce(p_q,'')),''),
    'all_label', public.uic('catalogue.letter_all','All'),
    'trail', public.catalogue_trail('salts', '{}'::text[], null, null, null),
    'rail', public._cat_rail('salt', (select cz from z), null),
    'search_hint', public.uic('catalogue.salt_search_hint','Search a salt, e.g. Paracetamol'),
    'lead_label', public.uic('catalogue.salts_lead','Biggest salts first — search to narrow.'),
    'empty_label', public.uic('catalogue.salts_empty','No salt matches this search.'),
    'count_label', to_char(case when nullif(btrim(coalesce(p_q,'')),'') is null
                                 and (select l from lt) is null
                                then public._cat_meta(public._cat_tile_zone(), 'salts')
                                else coalesce((select n from grp_n where grp = 0), 0) end,
                           'FM9,99,99,999') || ' '
                   || public.uic('catalogue.salts_word','salts'),
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'n', s.n, 'letter', s.letter,
              'count_label', public.cat_count_label(s.n),
              'group', s.grp,
              'group_label', case when s.rn = 1 and (select az from az) is not null
                                  then public.cat_group_label(
                                         case when s.grp = 0 then 'in' else 'out' end,
                                         (select g.n from grp_n g where g.grp = s.grp))
                                  else '' end)
              order by s.grp,
                       case when (select l from lt) is null then null else s.label end nulls last,
                       s.n desc, s.facet_key)
              from shown s), '[]'::jsonb));
$$;

create or replace function public.catalogue_conditions(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  az as (select public._cat_avail_zone() as az),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  hit as (
    select c.facet_key, c.label, c.n, c.letter, 0::smallint as grp
      from public.catalogue_facet_count c
      left join public.use_bucket cond
             on lower(btrim(cond.label)) = lower(btrim(c.facet_key)) and cond.is_active
     where c.facet = 'condition'
       and c.zone_id = coalesce((select az from az), (select cz from z))
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%'
            or exists (select 1 from unnest(coalesce(cond.synonyms,'{}'::text[])) s
                        where lower(s) like '%' || lower(btrim(p_q)) || '%'))
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
    union all
    select c.facet_key, c.label, c.n, c.letter, 1::smallint
      from public.catalogue_facet_count c
      left join public.use_bucket cond
             on lower(btrim(cond.label)) = lower(btrim(c.facet_key)) and cond.is_active
     where (select az from az) is not null
       and c.facet = 'condition' and c.zone_id = (select cz from z)
       and not exists (select 1 from public.catalogue_facet_count a
                        where a.facet = 'condition' and a.facet_key = c.facet_key
                          and a.zone_id = (select az from az))
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%'
            or exists (select 1 from unnest(coalesce(cond.synonyms,'{}'::text[])) s
                        where lower(s) like '%' || lower(btrim(p_q)) || '%'))
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
  ),
  grp_n as (select grp, count(*) as n from hit group by grp),
  page as (select * from hit
            order by grp,
                     case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else label end nulls last,
                     n desc, facet_key
            offset (select off from lim) limit (select n from lim) + 1),
  shown as (select p.*, row_number() over (
                     partition by p.grp
                     order by case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else p.label end nulls last,
                              p.n desc, p.facet_key) as rn
              from (select * from page
                     order by grp,
                              case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else label end nulls last,
                              n desc, facet_key
                     limit (select n from lim)) p)
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.conditions_title','Shop by condition'),
    'zone', public.catalogue_zone_switch(p_zone),
    'letter', nullif(upper(btrim(coalesce(p_letter,''))),''),
    'q', nullif(btrim(coalesce(p_q,'')),''),
    'all_label', public.uic('catalogue.letter_all','All'),
    'trail', public.catalogue_trail('conditions', '{}'::text[], null, null, null),
    'rail', public._cat_rail('condition', (select cz from z), null),
    'search_hint', public.uic('catalogue.condition_search_hint','Search a use, e.g. Fever'),
    'lead_label', public.uic('catalogue.conditions_lead','Biggest uses first — search to narrow.'),
    'empty_label', public.uic('catalogue.conditions_empty','No use matches this search.'),
    'count_label', to_char(case when nullif(btrim(coalesce(p_q,'')),'') is null
                                 and nullif(btrim(coalesce(p_letter,'')),'') is null
                                then public._cat_meta(public._cat_tile_zone(), 'conditions')
                                else coalesce((select n from grp_n where grp = 0), 0) end,
                           'FM9,99,99,999') || ' '
                   || case when coalesce((select n from grp_n where grp = 0), 0) = 1
                           then public.uic('catalogue.condition_word','use')
                           else public.uic('catalogue.conditions_word','uses') end,
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'n', s.n, 'letter', s.letter,
              'count_label', public.cat_count_label(s.n),
              'group', s.grp,
              'group_label', case when s.rn = 1 and (select az from az) is not null
                                  then public.cat_group_label(
                                         case when s.grp = 0 then 'in' else 'out' end,
                                         (select g.n from grp_n g where g.grp = s.grp))
                                  else '' end)
              order by s.grp,
                       case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else s.label end nulls last,
                       s.n desc, s.facet_key)
              from shown s), '[]'::jsonb));
$$;

create or replace function public.catalogue_tree(
  p_path text[] default '{}'::text[], p_letter text default null,
  p_zone boolean default true)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
  az as (select public._cat_avail_zone() as az),
  lvl as (select coalesce(array_length(p_path,1),0) as d),
  node as (
    select case (select d from lvl)
             when 0 then 'therapeutic' when 1 then 'chemical' else 'action' end as facet,
           case (select d from lvl)
             when 0 then '' when 1 then p_path[1]
             else public.catalogue_parent_key(p_path[1], p_path[2]) end as parent
  ),
  rows as (
    select c.facet_key, c.label, c.n, 0::smallint as grp
      from public.catalogue_facet_count c
     where c.zone_id = coalesce((select az from az), (select cz from z))
       and c.facet   = (select facet from node)
       and c.parent_key = (select parent from node)
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
    union all
    select c.facet_key, c.label, c.n, 1::smallint
      from public.catalogue_facet_count c
     where (select az from az) is not null
       and c.zone_id = (select cz from z)
       and c.facet   = (select facet from node)
       and c.parent_key = (select parent from node)
       and not exists (select 1 from public.catalogue_facet_count a
                        where a.facet = c.facet and a.facet_key = c.facet_key
                          and a.parent_key = c.parent_key
                          and a.zone_id = (select az from az))
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
  ),
  grp_n as (select grp, count(*) as n from rows group by grp),
  shown as (select r.*, row_number() over (partition by r.grp order by r.n desc, r.label) as rn
              from rows r)
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
    'count_label', public.cat_count_label(
                     coalesce((select sum(n)::bigint from rows where grp = 0), 0::bigint)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label,
              'n', s.n, 'count_label', public.cat_count_label(s.n::bigint),
              'group', s.grp,
              'group_label', case when s.rn = 1 and (select az from az) is not null
                                  then public.cat_group_label(
                                         case when s.grp = 0 then 'in' else 'out' end,
                                         (select g.n from grp_n g where g.grp = s.grp))
                                  else '' end)
              order by s.grp, s.n desc, s.label) from shown s), '[]'::jsonb));
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. The landing takes its tiles from the one RPC, and its tab counts from
--    the same zone, so the chip row can never disagree with the grid above it.
create or replace function public.catalogue_home(p_zone boolean default true)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with z as (select public._cat_count_zone(p_zone) as cz),
       az as (select public._cat_tile_zone() as az),
       cfg as (select public._cat_landing_cfg() as c),
       tiles as (select public.catalogue_browse_tiles() as t),
       schemes as (
         select coalesce((select n::bigint from public.catalogue_facet_count
                           where facet='tab' and zone_id=(select az from az)
                             and facet_key='schemes'), 0::bigint) as n),
       cold as (
         select coalesce((select n::bigint from public.catalogue_facet_count
                           where facet='tab' and zone_id=(select az from az)
                             and facet_key='cold_chain'), 0::bigint) as n)
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.title','Catalogue'),
    'subtitle', public.uic('catalogue.subtitle','Browse the whole product list by class, company or salt.'),
    'zone', public.catalogue_zone_switch(p_zone),
    'total', public._cat_meta((select az from az), 'total'),
    'refreshed_at', (select refreshed_at from public.catalogue_facet_count
                      where facet='meta' and zone_id=(select az from az) and facet_key='total'),
    'stale_label', public.uic('catalogue.counts_note','Counts refresh automatically.'),
    'search_hint', public.uic('catalogue.search_hint','Search a salt or a company'),
    'search', jsonb_build_object(
      'placeholder', public.uic('catalogue.search_placeholder','Search a medicine, salt or company'),
      'hint',        public.uic('catalogue.search_hint','Search a salt or a company'),
      'clear_label', public.uic('catalogue.search_clear','Clear')),
    'trail', jsonb_build_object(
      'label', public.uic('catalogue.trail_label','You are here'),
      'separator', public.uic('catalogue.trail_separator','›'),
      'items', '[]'::jsonb),
    'landing', (select c from cfg),
    -- CMD #2088 — the four tiles are ONE RPC's answer now, zone-scoped and two
    -- lines each. This function only forwards it.
    'doors_title', (select t->>'title' from tiles),
    'doors', (select t->'tiles' from tiles),
    'top_selling', public.catalogue_top_selling(p_zone),
    'promo', jsonb_build_object(
      'has', (select n from schemes) > 0,
      'key','schemes', 'list_kind','tab', 'list_key','schemes',
      'title',    public.uic('catalogue.schemes_promo_title','Schemes & offers'),
      'subtitle', public.uic('catalogue.schemes_promo_subtitle','Extra units on selected packs'),
      'count_label', public.cat_count_label((select n from schemes)),
      'action_label', public.uic('catalogue.schemes_promo_action','View all'),
      'gradient', (select c->'promo' from cfg)),
    'chips', case when (select n from cold) > 0 then jsonb_build_array(
        jsonb_build_object('key','cold_chain','label', public.uic('catalogue.tab_cold','Cold chain'),
          'kind','list', 'list_kind','tab', 'list_key','cold_chain',
          'count_label', public.cat_count_label((select n from cold)),
          'empty_label', public.uic('catalogue.cold_empty','No cold-chain product in this view.')))
      else '[]'::jsonb end,
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
                     where facet='therapeutic' and zone_id=(select az from az)
                       and parent_key=''), 0::bigint))),
      jsonb_build_object('key','companies','label', public.uic('catalogue.tab_companies','Companies'),
        'kind','companies',
        'count_label', public.cat_avail_line(
          public.uic('catalogue.tile_word_company','Companies'),
          public._cat_meta((select az from az), 'companies'))),
      jsonb_build_object('key','salts','label', public.uic('catalogue.tab_salts','Salts'),
        'kind','salts',
        'count_label', public.cat_avail_line(
          public.uic('catalogue.tile_word_salt','Salts'),
          public._cat_meta((select az from az), 'salts'))),
      jsonb_build_object('key','conditions','label', public.uic('catalogue.tab_conditions','Uses'),
        'kind','conditions',
        'count_label', public.cat_avail_line(
          public.uic('catalogue.tile_word_condition','Conditions'),
          public._cat_meta((select az from az), 'conditions'))),
      jsonb_build_object('key','cold_chain','label', public.uic('catalogue.tab_cold','Cold chain'),
        'kind','list', 'list_kind','tab', 'list_key','cold_chain',
        'count_label', public.cat_count_label((select n from cold)),
        'empty_label', public.uic('catalogue.cold_empty','No cold-chain product in this view.'))),
    'filters', public.catalogue_filter_defs('{}'::jsonb, (select cz from z)));
$$;
