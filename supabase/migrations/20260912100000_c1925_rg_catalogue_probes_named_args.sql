-- replay-target: production
-- CMD #1925 — the regression guard went red after CHANGE #1300.
--
-- TWO faults, one cause. #1300 (catalogue navigation: breadcrumb + A–Z rail)
-- INSERTED a p_letter parameter into two catalogue RPCs and dropped the old
-- signatures:
--     catalogue_tree(text[], boolean)          -> catalogue_tree(text[], text, boolean)
--     catalogue_salts(text, int, int, boolean) -> catalogue_salts(text, text, int, int, boolean)
-- Named callers (the app, through PostgREST) kept working — the new parameters
-- carry defaults. The casualties were the guard's own CHANGE #747 probes, which
-- call these functions POSITIONALLY:
--     payload   c747_catalogue_tree_root    42883 function ... does not exist
--     payload   c747_catalogue_salts_top    42883 function ... does not exist
--     behaviour c747_catalogue_budget       42883  (critical — filed on sight)
--
-- 1. THE PROBES. The signature change is intentional and already live, so the
--    probe is what is wrong. Every catalogue call in the three probes is
--    rewritten with NAMED arguments (p_x => v), which survive the next
--    parameter insertion instead of breaking on it.
--
-- 2. THE REGRESSION THE BROKEN PROBE WAS HIDING. With the probes running again
--    the budget behaviour failed for real: catalogue_salts 4,438 ms against a
--    300 ms budget, catalogue_companies 350 ms. #1300's new _cat_rail groups by
--    public._cat_letter(c.label) — a SQL function with a SET clause, so Postgres
--    cannot inline it and it is called once per row over 107,619 salt rows
--    (measured: 7.0 s for the aggregate alone). catalogue_facet_count has
--    carried a materialised `letter` column since #747 for exactly this, and the
--    pre-#1300 rail read it. So: the rail reads the column again, the column is
--    normalised to _cat_letter()'s own rule (btrim + non-A–Z bucketed to '#'),
--    catalogue_cache_tick writes it that way from now on, and the group-by gets
--    its index.
--
-- Idempotent throughout: UPDATEs by name, create-or-replace, create index if
-- not exists, and a backfill whose WHERE clause is already empty on a second run.

begin;

-- ── 1. the guard's probes, on named arguments ───────────────────────────────

update public.rg_payload_targets
   set sql = 'select public.catalogue_tree(p_path => ''{}''::text[], p_zone => true)'
 where name = 'c747_catalogue_tree_root';

update public.rg_payload_targets
   set sql = 'select public.catalogue_salts(p_q => null, p_offset => 0, p_limit => 10, p_zone => true)'
 where name = 'c747_catalogue_salts_top';

update public.rg_behavior_tests
   set body = $c1925$

do $c747$
declare
  t0 timestamptz; ms int; best int; sz int; bad text := '';
  budget_ms int := 300; budget_kb int := 512; i int;
begin
  -- One RPC, up to three attempts, the best time wins.
  create temp table if not exists _c747(q text, ms int, kb int) on commit drop;
  delete from _c747 where true;   -- a WHERE keeps the probe runnable under pg_safeupdate roles too

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_home(p_zone => true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_home', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_tree(p_path => '{}'::text[], p_zone => true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_tree', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_companies(p_letter => null, p_q => null,
                                    p_offset => 0, p_limit => 40, p_zone => true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_companies', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_salts(p_letter => null, p_q => null,
                                p_offset => 0, p_limit => 40, p_zone => true)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_salts', best, sz/1024);

  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    sz := length(public.catalogue_list(p_kind => 'tree', p_key => null,
                                       p_path => array['ANTI INFECTIVES'],
                                       p_filters => '{}'::jsonb, p_sort => 'name',
                                       p_zone => true, p_cursor => null, p_limit => 24)::text);
    ms := round(extract(epoch from clock_timestamp() - t0) * 1000);
    best := least(coalesce(best, ms), ms);
    exit when best <= budget_ms;
  end loop;
  insert into _c747 values ('catalogue_list', best, sz/1024);

  select string_agg(format('%s %sms; ', t.q, t.ms), '') into bad
    from _c747 t where t.ms > budget_ms;
  select coalesce(bad,'') || coalesce(string_agg(format('%s %skb; ', t.q, t.kb), ''), '')
    into bad from _c747 t where t.kb > budget_kb;

  if coalesce(bad,'') <> '' then
    raise exception 'RG_FAIL: catalogue budget blown (limit %ms / %kb, best of 3 attempts) — %',
      budget_ms, budget_kb, bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $c747$;

$c1925$
 where name = 'c747_catalogue_budget';

-- ── 2a. the cache writes the normalised letter ──────────────────────────────
-- therapeutic/chemical/action stored a raw upper(left(label,1)) — 171 rows whose
-- letter was a digit or a bracket, reachable by no A–Z filter. company/salt
-- already bucketed to '#' but without btrim. _cat_letter() is the one rule.

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
               public._cat_letter(m.therapeutic_class), count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.therapeutic_class),'') is not null
         group by 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'chemical' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'chemical', %1$L::smallint, m.therapeutic_class, m.chemical_class,
               m.chemical_class, public._cat_letter(m.chemical_class), count(*)
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
               public._cat_letter(m.action_class), count(*)
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
               public._cat_letter(coalesce(mc.display, m.marketer_canonical)),
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
               public._cat_letter(m.salt_composition),
               count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.salt_composition),'') is not null
         group by 4
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

-- ── 2b. backfill the rows already in the cache ──────────────────────────────
-- 224 rows on live at the time of writing; the WHERE is empty on a second run.
update public.catalogue_facet_count
   set letter = public._cat_letter(label)
 where letter is distinct from public._cat_letter(label);

-- ── 2c. the rail's index ────────────────────────────────────────────────────
-- (facet, zone_id, letter) is the group-by; parent_key rides along so the
-- drill-down rail (p_parent) stays on the index too.
-- the expression index built while diagnosing (it indexed _cat_letter(label)
-- itself) is superseded: the planner never got an index-only scan out of it and
-- still called the function once per row.
drop index if exists public.idx_cat_facet_rail;
create index if not exists idx_cat_facet_rail_letter
  on public.catalogue_facet_count (facet, zone_id, letter) include (parent_key);

-- ── 2d. the rail reads the column instead of calling the function per row ────
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
    select c.letter as key, count(*)::bigint as n
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
    'letters', coalesce((select jsonb_agg(jsonb_build_object(
                  'key', t.key, 'label', t.label, 'n', t.n, 'enabled', t.n > 0)
                  order by (t.key = '#'), t.key) from track t), '[]'::jsonb));
$$;

grant execute on function public._cat_rail(text, smallint, text) to anon, authenticated, service_role;

-- ── 2e. the two list RPCs stop calling _cat_letter per row ─────────────────
-- catalogue_salts called _cat_letter(label) once per row over all 107,619 salt
-- rows to build `hit`, and `hit` is read three times, so it also materialised
-- the whole facet to temp before returning 40 rows. catalogue_tree called the
-- function once per row inside its letter filter. catalogue_companies already
-- read the column, which is why it was the one that stayed near budget.
--
-- Measured on live, best of three, p_zone=true:
--     catalogue_salts()            4,438 ms -> 175 ms   (budget 300 ms)
--     catalogue_salts(letter 'A')    545 ms ->  73 ms
--     catalogue_salts(q 'para')    1,173 ms -> 188 ms
--     catalogue_tree()                        26 ms

CREATE OR REPLACE FUNCTION public.catalogue_salts(p_letter text DEFAULT NULL::text, p_q text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 40, p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with z as (select public._cat_count_zone(p_zone) as cz),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  -- NOT MATERIALIZED: `hit` is read twice (the page and the count), so Postgres
  -- spilled all 107,619 salt rows to temp before returning 40. Inlined, each
  -- reader gets its own index-only scan: idx_cat_facet_size for the page,
  -- idx_cat_facet_rail_letter for the count.
  -- The letter as a RANGE, so the same predicate is sargable whether or not a
  -- letter was picked: ('A','A') for a pick, ('','zzzzz') for the whole track.
  lt as (select nullif(upper(btrim(coalesce(p_letter,''))),'') as l),
  -- NOT MATERIALIZED and split on q. `hit` is read three times (the count and
  -- the two page branches); materialised it spilled all 107,619 salt rows to
  -- temp before returning 40, and an OR'd predicate cost every reader a heap
  -- scan. Each branch below carries a pseudoconstant WHERE the planner turns
  -- into a One-Time Filter, so exactly one is live and it is index-driven:
  -- no q -> the (facet, zone_id, letter) index; a q -> the label trigram index.
  hit as not materialized (
    (select c.facet_key, c.label, c.n, c.letter
       from public.catalogue_facet_count c
      where c.facet = 'salt' and c.zone_id = (select cz from z)
        and c.letter between coalesce((select l from lt),'') and coalesce((select l from lt),'zzzzz')
        and nullif(btrim(coalesce(p_q,'')),'') is null)
    union all
    (select c.facet_key, c.label, c.n, c.letter
       from public.catalogue_facet_count c
      where c.facet = 'salt' and c.zone_id = (select cz from z)
        and c.letter between coalesce((select l from lt),'') and coalesce((select l from lt),'zzzzz')
        and nullif(btrim(coalesce(p_q,'')),'') is not null
        and lower(c.label) like '%' || lower(btrim(p_q)) || '%')
  ),
  -- Biggest first is the salt list's own order. Once a letter is picked the
  -- letter IS the ordering the reader is looking for, so it reads A→Z.
  -- Two branches instead of one CASE in the ORDER BY. A CASE over a PARAMETER
  -- is not folded in the cached plan, so the old shape sorted all 107,619 rows
  -- on every call; each branch here carries a pseudoconstant WHERE, which the
  -- planner turns into a One-Time Filter, so the unused branch never runs and
  -- the live one sorts nothing: no letter -> idx_cat_facet_size (n desc,
  -- facet_key) straight off the index, a letter -> the few rows behind it.
  page as (
    (select * from hit
      where nullif(btrim(coalesce(p_letter,'')),'') is null
      order by n desc, facet_key
      offset (select off from lim) limit (select n from lim) + 1)
    union all
    (select * from hit
      where nullif(btrim(coalesce(p_letter,'')),'') is not null
      order by label, n desc, facet_key
      offset (select off from lim) limit (select n from lim) + 1)),
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
$function$;

grant execute on function public.catalogue_salts(text, text, integer, integer, boolean) to anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.catalogue_tree(p_path text[] DEFAULT '{}'::text[], p_letter text DEFAULT NULL::text, p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
            or c.letter = upper(btrim(p_letter)))
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
$function$;

grant execute on function public.catalogue_tree(text[], text, boolean) to anon, authenticated, service_role;

commit;
