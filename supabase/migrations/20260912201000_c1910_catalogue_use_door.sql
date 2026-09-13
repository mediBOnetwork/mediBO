-- CMD #1910 — the catalogue learns the fourth door.
--
-- Everything here is an EXTENSION of the machinery companies and salts already
-- use: one more facet in catalogue_facet_count, one more kind in _cat_where,
-- one more door in catalogue_home, one more section in catalogue_trail and a
-- catalogue_conditions() that is catalogue_salts() with a different facet. The
-- A-Z strip, the breadcrumb, the zone grouping and the product grid are the
-- SAME code paths — a "Use" list is not a new screen, it is a new scope.

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
    -- IN, not EXISTS: the small side is one condition's product list, which
    -- Postgres hashes once. An EXISTS per MEDICINE row is the shape that makes
    -- a 250k-row scope crawl.
    w := w || format(' and m.id in (select cm.medicine_id from public.condition_medicine cm'
                  || ' join public.condition c on c.id = cm.condition_id'
                  || ' where c.condition_key = %L)', coalesce(p_key,''));
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

CREATE OR REPLACE FUNCTION public._cat_scope_total(p_kind text, p_key text, p_path text[], p_zone smallint)
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with k as (
    select case p_kind
             when 'company' then 'company' when 'salt' then 'salt' when 'tab' then 'tab'
             when 'condition' then 'condition'
             when 'tree' then case coalesce(array_length(p_path,1),0)
                                when 1 then 'therapeutic' when 2 then 'chemical'
                                when 3 then 'action' end
           end as facet,
           case when p_kind = 'tree' then
                  case coalesce(array_length(p_path,1),0)
                    when 2 then p_path[1]
                    when 3 then public.catalogue_parent_key(p_path[1], p_path[2])
                    else '' end
                else '' end as parent,
           case p_kind
             when 'tree' then p_path[greatest(coalesce(array_length(p_path,1),0),1)]
             else coalesce(p_key,'') end as fkey
  )
  select c.n from public.catalogue_facet_count c, k
   where k.facet is not null
     and c.facet = k.facet and c.zone_id = p_zone
     and c.parent_key = k.parent and c.facet_key = k.fkey;
$function$;

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
      -- The count is DISTINCT products, because a product can sit under more
      -- than one condition and a door that says 12,410 when the list holds
      -- 9,200 is a door that lies.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'condition', %1$L::smallint, '', c.condition_key, c.label,
               case when upper(left(c.label,1)) between 'A' and 'Z'
                    then upper(left(c.label,1)) else '#' end,
               count(distinct m.id)
          from public.condition c
          join public.condition_medicine cm on cm.condition_id = c.id
          join public."MEDICINE" m on m.id = cm.medicine_id %2$s
         where %3$s and c.is_active
         group by c.condition_key, c.label
        having count(distinct m.id) > 0
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
          from public.condition c
          join public.condition_medicine cm on cm.condition_id = c.id
          join public."MEDICINE" m on m.id = cm.medicine_id %2$s
         where %3$s and c.is_active
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

CREATE OR REPLACE FUNCTION public.catalogue_refresh_plan(p_mode text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_min bigint; v_max bigint; v_step bigint := 150000;
  v_ord int := 0; v_lo bigint; z record; f text; b int; v_full boolean;
begin
  -- Mode is DECIDED here, once: the caller may force it, otherwise the clock
  -- does. A full plan is night work by definition.
  v_full := case when p_mode = 'full' then true
                 when p_mode = 'incremental' then false
                 else public._cron_is_night() end;

  select min(id), max(id) into v_min, v_max from "MEDICINE";
  if v_min is null then return 0; end if;

  delete from public.catalogue_refresh_unit;

  if v_full then
    for z in select id from public.zones
              where is_active and not coalesce(is_synthetic,false) order by id loop
      v_lo := v_min;
      while v_lo <= v_max loop
        v_ord := v_ord + 1;
        insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg, arg2)
          values (v_ord, 'zone_scan', z.id, v_lo::text, least(v_lo + v_step - 1, v_max)::text);
        v_lo := v_lo + v_step;
      end loop;
      v_ord := v_ord + 1;
      insert into public.catalogue_refresh_unit(ord, kind, zone_id)
        values (v_ord, 'zone_swap', z.id);
    end loop;
  end if;

  -- The facet counts are the cheap half and they are what a user actually
  -- sees, so they are planned in BOTH modes.
  foreach f in array array['therapeutic','chemical','action','company','salt','condition','tab','meta'] loop
    v_ord := v_ord + 1;
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      values (v_ord, 'facet', 0::smallint, f);
  end loop;
  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    foreach f in array array['therapeutic','chemical','action','company','salt','condition','tab','meta'] loop
      v_ord := v_ord + 1;
      insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
        values (v_ord, 'facet', z.id, f);
    end loop;
  end loop;

  -- CMD #1894 — #790's typeahead cache is no longer planned at all. Nothing
  -- reads search_suggest_cache any more, so rebuilding 3.6 lakh rows of it
  -- every night was pure cost; the table and its rows are left untouched.

  update public.catalogue_refresh_state
     set cycle_started = now(), cycle_ended = null,
         last_note = 'planned ' || v_ord || ' units (' ||
                     case when v_full then 'full' else 'incremental' end || ')'
   where id = 1;
  return v_ord;
end $function$;

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
    'route', jsonb_build_object('tab','browse','path','[]'::jsonb,
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
  v_sentence jsonb;
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
        (select label from public.condition where condition_key = coalesce(p_key,'')),
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
    v_sentence := jsonb_build_object(
      'lead','', 'separator','', 'all_label','', 'clear_label','',
      'has_selection', false, 'parts', '[]'::jsonb);
  else
    v_sentence := public.catalogue_sentence(coalesce(p_filters,'{}'::jsonb), p_zone, v_cz);
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
    'sentence', v_sentence,
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

-- ── the Use index: catalogue_salts() with a different facet ───────────────
-- Same shape, same rail, same trail, same paging contract — so the screen that
-- draws companies and salts draws this with no new branch of its own.
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
    -- A condition is found by its printed label OR by any of the words a
    -- shopper actually uses for it. The synonyms live in the table, so adding
    -- "bukhar" to Fever is an admin edit, never a deploy.
    select c.facet_key, c.label, c.n, c.letter
      from public.catalogue_facet_count c
      left join public.condition cond on cond.condition_key = c.facet_key
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
    'title', public.uic('catalogue.conditions_title','Use'),
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

-- ── the words ─────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('catalogue.door_condition',        to_jsonb('Use'::text)),
  ('catalogue.tab_conditions',        to_jsonb('Uses'::text)),
  ('catalogue.conditions_word',       to_jsonb('uses'::text)),
  ('catalogue.conditions_title',      to_jsonb('Use'::text)),
  ('catalogue.trail_condition',       to_jsonb('Use'::text)),
  ('catalogue.condition_subtitle',    to_jsonb('Products used for this condition'::text)),
  ('catalogue.condition_search_hint', to_jsonb('Search a use, e.g. Fever'::text)),
  ('catalogue.conditions_lead',       to_jsonb('Biggest uses first — search to narrow.'::text)),
  ('catalogue.conditions_empty',      to_jsonb('No use matches this search.'::text)),
  ('catalogue.condition_word',        to_jsonb('use'::text))
on conflict (key) do nothing;

-- ── the counts, now ───────────────────────────────────────────────────────
-- The nightly plan will rebuild these with everything else; the door must not
-- print "0 products" until then.
do $$
declare z record;
begin
  insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
    select coalesce((select max(ord) from public.catalogue_refresh_unit),0) + 1,
           'facet', 0::smallint, 'condition'
   where not exists (select 1 from public.catalogue_refresh_unit
                      where kind='facet' and zone_id=0 and arg='condition' and state='pending');
  insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
    select coalesce((select max(ord) from public.catalogue_refresh_unit),0) + 1,
           'facet', 0::smallint, 'meta'
   where not exists (select 1 from public.catalogue_refresh_unit
                      where kind='facet' and zone_id=0 and arg='meta' and state='pending');
  for z in select id from public.zones where is_active and not coalesce(is_synthetic,false) order by id loop
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      select coalesce((select max(ord) from public.catalogue_refresh_unit),0) + 1,
             'facet', z.id, 'condition'
     where not exists (select 1 from public.catalogue_refresh_unit
                        where kind='facet' and zone_id=z.id and arg='condition' and state='pending');
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      select coalesce((select max(ord) from public.catalogue_refresh_unit),0) + 1,
             'facet', z.id, 'meta'
     where not exists (select 1 from public.catalogue_refresh_unit
                        where kind='facet' and zone_id=z.id and arg='meta' and state='pending');
  end loop;
end $$;
