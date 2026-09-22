-- CMD #2178 — RG red after #1501: c747_catalogue_budget.
--
-- The red was ONE behaviour, not a schema diff: catalogue_home came back at
-- 364 ms best-of-3 against a 300 ms budget. Profiled on live, the cost was not
-- the RPC's own shape but two full aggregates it ran on every single call,
-- inside catalogue_browse_tiles:
--
--   sum(n) where facet='company'    → 499 ms cold / 6 ms warm
--   sum(n) where facet='salt'       → 4202 ms cold / 45 ms warm
--
-- catalogue_facet_count holds 155,919 rows, so those two are heap scans of the
-- whole facet table on a landing screen. The counts they produce are DERIVED
-- and already have a home: the 'meta' facet rows that catalogue_cache_tick
-- writes, which _cat_meta() reads as a single point lookup. 'companies',
-- 'salts', 'conditions' and 'condition_products' were rows already; the four
-- product totals were left as live scans.
--
-- This migration makes them rows too — company_products, salt_products,
-- categories, category_products — written by the same 'meta' unit (which
-- already runs after the company/salt/therapeutic units for its zone, so the
-- numbers it sums are the ones it just wrote), backfills them for every zone
-- that already has facet rows, and turns catalogue_browse_tiles and
-- catalogue_home's Browse tab into point lookups.
--
-- Idempotent: every statement is a CREATE OR REPLACE or a delete+insert of
-- exactly the keys it owns.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. the tick writes the four new meta rows
-- ─────────────────────────────────────────────────────────────────────────────
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
    -- CMD #2023 — the zone store is SELF-MAINTAINING. Every write that can
    -- change a pack's zone standby lands on the "MEDICINE" zone arrays, and
    -- zzz_zone_avail_sync_trg updates catalogue_zone_avail in the same
    -- statement. A periodic rescan can only reintroduce the drift this change
    -- removed (the snapshot the storefront was reading was last swapped on
    -- 2 Sep), so the unit stays in the cycle as a no-op instead of rebuilding.
    v_rows := 0;

  elsif u.kind = 'zone_swap' then
    v_rows := 0;

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
    elsif u.arg = 'condition' then
      -- CMD #1953 — the source is MEDICINE.condition, the text[] derived from
      -- MEDICINE.uses. No link table: one lateral unnest over the column the
      -- GIN index is built on. The count is still DISTINCT products, because a
      -- product sits under every condition it treats and a door that says
      -- 12,410 when the list holds 9,200 is a door that lies.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'condition', %1$L::smallint, '', t.cond, t.cond,
               public._cat_letter(t.cond), count(distinct t.id)
          from (select m.id, x.cond
                  from public."MEDICINE" m %2$s
                  cross join lateral unnest(m.condition) as x(cond)
                 where %3$s and m.condition is not null
                   and cardinality(m.condition) > 0) t
         where nullif(btrim(t.cond),'') is not null
         group by t.cond
        having count(distinct t.id) > 0
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'meta' then
      -- The numbers the Catalogue TAB BAR prints, and the pack-type filter's
      -- own vocabulary. Both were live scans in the first draft: rendering the
      -- tab bar cost `select distinct pack_type from "MEDICINE"` — 10.2 s on
      -- this instance — which is the exact thing the spec forbids. They are
      -- rows now, so the landing screen is six point lookups.
      --
      -- CMD #2178 — and so are the four PRODUCT totals the Browse-by tiles
      -- print. They were sum(n)/count(*) over the whole facet table on every
      -- catalogue_home call (the salt one: 4.2 s cold, 45 ms warm, 155,919
      -- rows), which is what blew the c747 budget. This unit already runs
      -- after 'company', 'salt' and 'therapeutic' for its own zone, so the
      -- rows it sums here are the ones it just wrote.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'meta', %1$L::smallint, '', 'total', 'total', '', count(*)
          from public."MEDICINE" m %2$s where %3$s
        union all
        select 'meta', %1$L::smallint, '', 'companies', 'companies', '',
               count(*) from public.catalogue_facet_count
                where facet = 'company' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'company_products', 'company_products', '',
               coalesce(sum(n), 0)::bigint from public.catalogue_facet_count
                where facet = 'company' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'salts', 'salts', '',
               count(*) from public.catalogue_facet_count
                where facet = 'salt' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'salt_products', 'salt_products', '',
               coalesce(sum(n), 0)::bigint from public.catalogue_facet_count
                where facet = 'salt' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'categories', 'categories', '',
               count(*) from public.catalogue_facet_count
                where facet = 'therapeutic' and zone_id = %1$L::smallint
                  and parent_key = ''
        union all
        select 'meta', %1$L::smallint, '', 'category_products', 'category_products', '',
               coalesce(sum(n), 0)::bigint from public.catalogue_facet_count
                where facet = 'therapeutic' and zone_id = %1$L::smallint
                  and parent_key = ''
        union all
        select 'meta', %1$L::smallint, '', 'conditions', 'conditions', '',
               count(*) from public.catalogue_facet_count
                where facet = 'condition' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'condition_products', 'condition_products', '',
               count(distinct m.id)
          from public."MEDICINE" m %2$s
         where %3$s and m.condition is not null and cardinality(m.condition) > 0
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. backfill the four new keys for every zone that already has facet rows,
--    so the tiles never print 0 while waiting for the next refresh cycle.
-- ─────────────────────────────────────────────────────────────────────────────
delete from public.catalogue_facet_count
 where facet = 'meta'
   and facet_key in ('company_products','salt_products','categories','category_products');

insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
select 'meta', z.zone_id, '', k.facet_key, k.facet_key, '', k.n
  from (select distinct zone_id from public.catalogue_facet_count) z
  cross join lateral (
    select 'company_products'::text as facet_key,
           coalesce((select sum(c.n) from public.catalogue_facet_count c
                      where c.facet = 'company' and c.zone_id = z.zone_id), 0)::bigint as n
    union all
    select 'salt_products',
           coalesce((select sum(c.n) from public.catalogue_facet_count c
                      where c.facet = 'salt' and c.zone_id = z.zone_id), 0)::bigint
    union all
    select 'categories',
           coalesce((select count(*) from public.catalogue_facet_count c
                      where c.facet = 'therapeutic' and c.zone_id = z.zone_id
                        and c.parent_key = ''), 0)::bigint
    union all
    select 'category_products',
           coalesce((select sum(c.n) from public.catalogue_facet_count c
                      where c.facet = 'therapeutic' and c.zone_id = z.zone_id
                        and c.parent_key = ''), 0)::bigint
  ) k
on conflict (facet, zone_id, parent_key, facet_key) do update set n = excluded.n;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. the tiles read rows, not scans
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.catalogue_browse_tiles()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with az as (select public._cat_tile_zone() as z),
  cfg as (select public._cat_landing_cfg() as c),
  -- CMD #2178 — eight point lookups. Every one of these was a meta row
  -- already or is one now; none of them scans catalogue_facet_count.
  n as (
    select
      public._cat_meta((select z from az), 'companies')          as companies,
      public._cat_meta((select z from az), 'company_products')   as company_products,
      public._cat_meta((select z from az), 'salts')              as salts,
      public._cat_meta((select z from az), 'salt_products')      as salt_products,
      public._cat_meta((select z from az), 'conditions')         as conditions,
      public._cat_meta((select z from az), 'condition_products') as condition_products,
      public._cat_meta((select z from az), 'categories')         as categories,
      public._cat_meta((select z from az), 'category_products')  as category_products
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
$function$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. and so does the Browse tab's own count label
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.catalogue_home(p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        -- CMD #2178 — was sum(n) over every 'therapeutic' row on every call.
        'count_label', public.cat_count_label(
          public._cat_meta((select az from az), 'category_products'))),
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
$function$;
