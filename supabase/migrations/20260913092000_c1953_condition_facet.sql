-- CMD #1953 — STEP 3: the Use door reads the column.
--
-- "Shop by condition" said 0 uses because catalogue_facet_count held no
-- 'condition' rows: the facet was built from a 46-bucket link table that only
-- an admin re-seed ever filled. From here the facet is built from
-- MEDICINE.condition — the text[] #1953 derives from MEDICINE.uses — so a
-- condition exists exactly when products carry it, per zone, and the product
-- list is `condition @> array[key]` straight down the GIN index.
--
-- The facet_key IS the printed phrase now ('Pain relief'), not a slug. That
-- keeps the door, the breadcrumb, the search chip and the product list on one
-- string with nothing to look up.

-- ── the scope ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._cat_where(p_kind text, p_key text, p_path text[], p_filters jsonb)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare w text := 'true'; v text; q text;
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
  elsif p_kind = 'condition' then
    -- CMD #1953 — array containment, which is what idx_medicine_condition_gin
    -- is for. No IN-list, no link table, no second scan.
    if coalesce(btrim(p_key),'') = '' then
      w := w || ' and false';
    else
      w := w || format(' and m.condition @> array[%L]::text[]', p_key);
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
    -- The first range of a zone clears its staging rows: a cycle never mixes
    -- two sweeps, and a re-run of the same unit is a silent no-op.
    if u.arg::bigint = (select min(arg::bigint) from public.catalogue_refresh_unit
                         where kind='zone_scan' and zone_id = u.zone_id) then
      delete from public.catalogue_zone_avail_stage where zone_id = u.zone_id;
    end if;
    execute format($q$
      insert into public.catalogue_zone_avail_stage(zone_id, product_id)
      select %1$L::smallint, m.id
        from public."MEDICINE" m
       where m.id between %2$L::bigint and %3$L::bigint
         and (cardinality(m.%4$I) > 0 or cardinality(m.%5$I) > 0)
         and cardinality(public.medicine_zone_effective(m.%4$I, m.%5$I, m.%6$I, m.%7$I)) > 0
      on conflict do nothing
    $q$, u.zone_id, u.arg, u.arg2,
        'z_'||v_code||'_sup', 'z_'||v_code||'_av',
        'z_'||v_code||'_oos', 'z_'||v_code||'_nostock');
    get diagnostics v_rows = row_count;

  elsif u.kind = 'zone_swap' then
    -- The exchange. Narrow table, two statements, one transaction: a shopper
    -- either sees the old list or the new one, never half of either.
    delete from public.catalogue_zone_avail where zone_id = u.zone_id;
    insert into public.catalogue_zone_avail(zone_id, product_id)
      select zone_id, product_id from public.catalogue_zone_avail_stage
       where zone_id = u.zone_id;
    get diagnostics v_rows = row_count;
    delete from public.catalogue_zone_avail_stage where zone_id = u.zone_id;

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
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'meta', %1$L::smallint, '', 'total', 'total', '', count(*)
          from public."MEDICINE" m %2$s where %3$s
        union all
        select 'meta', %1$L::smallint, '', 'companies', 'companies', '',
               count(*) from public.catalogue_facet_count
                where facet = 'company' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'salts', 'salts', '',
               count(*) from public.catalogue_facet_count
                where facet = 'salt' and zone_id = %1$L::smallint
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
end $function$

;

-- ── the list screen ───────────────────────────────────────────────────────
-- Same shape as #1910's, one join changed: the synonym row is found by the
-- bucket's own LABEL now, because the facet key is a printed phrase rather
-- than a slug. A bucket whose label matches a derived condition still lends
-- it "bukhar", and a condition with no bucket simply has no synonyms.
create or replace function public.catalogue_conditions(
  p_letter text default null, p_q text default null,
  p_offset integer default 0, p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $fn$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  hit as (
    select c.facet_key, c.label, c.n, c.letter
      from public.catalogue_facet_count c
      left join public.use_bucket cond
             on lower(btrim(cond.label)) = lower(btrim(c.facet_key)) and cond.is_active
     where c.facet = 'condition' and c.zone_id = (select cz from z)
       and (nullif(btrim(coalesce(p_q,'')),'') is null
            or lower(c.label) like '%' || lower(btrim(p_q)) || '%'
            or exists (select 1 from unnest(coalesce(cond.synonyms,'{}'::text[])) s
                        where lower(s) like '%' || lower(btrim(p_q)) || '%'))
       and (nullif(btrim(coalesce(p_letter,'')),'') is null
            or c.letter = upper(btrim(p_letter)))
  ),
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
    'count_label', to_char((select count(*) from hit),'FM9,99,99,999') || ' '
                   || case when (select count(*) from hit) = 1
                           then public.uic('catalogue.condition_word','use')
                           else public.uic('catalogue.conditions_word','uses') end,
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'n', s.n, 'letter', s.letter,
              'count_label', public.cat_count_label(s.n))
              order by case when nullif(btrim(coalesce(p_letter,'')),'') is null then null else s.label end nulls last,
                       s.n desc, s.facet_key)
              from shown s), '[]'::jsonb));
$fn$;

grant execute on function public.catalogue_conditions(text, text, integer, integer, boolean)
  to anon, authenticated, service_role;

-- ── the typeahead ─────────────────────────────────────────────────────────
-- A suggestion that cannot be navigated is not a suggestion (lesson #307):
-- the key it carries is the same facet_key the door and _cat_where use.
create or replace function public.search_suggest_conditions_rebuild()
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_rows bigint := 0;
begin
  with zone_of as (
    select z.facet_key, array_agg(distinct z.zone_id order by z.zone_id) as zones
      from public.catalogue_facet_count z
     where z.facet = 'condition' and z.zone_id > 0
     group by z.facet_key
  ),
  src as (
    select c.facet_key as key,
           c.label,
           c.n,
           -- The label FIRST, so a prefix match on the real word still ranks
           -- as a prefix; the synonyms follow for the contains lane.
           public._norm_name(c.label || ' ' ||
             coalesce(array_to_string(cond.synonyms, ' '), '')) as norm,
           coalesce(zo.zones, '{}'::smallint[]) as zones
      from public.catalogue_facet_count c
      left join public.use_bucket cond
             on lower(btrim(cond.label)) = lower(btrim(c.facet_key)) and cond.is_active
      left join zone_of zo on zo.facet_key = c.facet_key
     where c.facet = 'condition' and c.zone_id = 0
       and nullif(btrim(c.label), '') is not null
  )
  insert into public.search_suggest_cache(kind, key, label, sub_label, n, rank, norm, zones, query)
  select 'condition', s.key, s.label, '', s.n, s.n::bigint, s.norm, s.zones, s.label
    from src s
  on conflict (kind, key) do update
    set label = excluded.label, sub_label = excluded.sub_label, n = excluded.n,
        rank = excluded.rank, norm = excluded.norm, zones = excluded.zones,
        query = excluded.query;
  get diagnostics v_rows = row_count;

  delete from public.search_suggest_cache c
   where c.kind = 'condition'
     and not exists (select 1 from public.catalogue_facet_count f
                     where f.facet = 'condition' and f.zone_id = 0
                       and f.facet_key = c.key);
  return v_rows;
end $fn$;

revoke all on function public.search_suggest_conditions_rebuild() from public, anon, authenticated;

-- ── the words ─────────────────────────────────────────────────────────────
-- The page title the spec names. Everything else #1910 wrote stays as it is.
insert into public.ui_copy (key, value) values
  ('catalogue.conditions_title', to_jsonb('Shop by condition'::text))
on conflict (key) do update set value = excluded.value;

-- The Use door is planned in both catalogue modes already (#1910). This makes
-- sure the first cycle after the replay actually rebuilds it rather than
-- waiting for the nightly plan.
insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
select coalesce((select max(u.ord) from public.catalogue_refresh_unit u), 0) + 1,
       'facet', 0::smallint, 'condition'
 where not exists (select 1 from public.catalogue_refresh_unit u2
                    where u2.kind = 'facet' and u2.zone_id = 0
                      and u2.arg = 'condition' and u2.state = 'pending');
