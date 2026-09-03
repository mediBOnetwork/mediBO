-- CHANGE #790 — catalogue search upgrade, part A: the suggestion CACHE.
--
-- Typeahead may never touch "MEDICINE". 5.6 lakh rows on a 1 GB instance is
-- the one thing a keystroke cannot afford, so every suggestion this feature
-- serves is a row in `search_suggest_cache`, written by the SAME bounded cron
-- that already fills the catalogue facet counts (`catalogue_cache_tick`, #747).
-- A keystroke is a prefix probe on a narrow table; a typo is a trigram probe
-- on the same one.
--
-- Brand families: a family is (brand root, company). `_brand_root()` is the
-- rule — the leading word(s) of the normalised name, before the strength, the
-- pack form and the "-A" suffix — so Monticope, Monticope-A, Monticope Syrup
-- and Monticope 5 mg are ONE family and a Monticope from another company is
-- not. It is IMMUTABLE and derived, so nothing is written back to "MEDICINE":
-- that table carries 36 indexes and a 5.6 lakh-row UPDATE on it is hours of
-- write churn plus every refresh-dirty trigger it owns, for a value that is a
-- pure function of two columns already there.

-- ── 1. the brand-root rule ──────────────────────────────────────────────────
create or replace function public._brand_root(p_name text)
returns text language sql immutable parallel safe as $f$
  with t as (
    select tok, ord
      from unnest(regexp_split_to_array(public._norm_name(p_name), ' '))
           with ordinality u(tok, ord)
  ),
  kept as (
    select tok, ord,
           sum(length(tok) + 1) over (order by ord
               rows between unbounded preceding and current row) as cum
      from t where tok <> ''
  )
  -- The first word is the brand. A one- or two-letter first word ("A To Z")
  -- is not a brand on its own, so it borrows the next words until it is long
  -- enough to be one — never past three words or twelve characters.
  select coalesce(nullif(btrim(string_agg(tok, ' ' order by ord)), ''),
                  public._norm_name(p_name))
    from kept
   where ord = 1
      or (ord <= 3 and (select length(k2.tok) from kept k2 where k2.ord = 1) < 4
          and tok ~ '^[a-z]' and cum <= 12);
$f$;

comment on function public._brand_root(text) is
  'CHANGE #790 — the brand-family rule: leading word(s) of the normalised product name, before strength/form/suffix.';

create or replace function public.brand_family_key(p_name text, p_company text)
returns text language sql immutable parallel safe as $f$
  select public._brand_root(p_name) || '|' || coalesce(nullif(btrim(p_company), ''), '');
$f$;

comment on function public.brand_family_key(text, text) is
  'CHANGE #790 — brand_family key: same brand root AND same company is one family. Derived, never stored on MEDICINE.';

-- ── 2. the cache and its staging twin ───────────────────────────────────────
create table if not exists public.search_suggest_cache (
  kind       text       not null,             -- brand | salt | company | category
  key        text       not null,             -- brand: family key; salt/company/category: the facet key
  label      text       not null,             -- printed, verbatim catalogue text
  sub_label  text       not null default '',  -- brand: the company that makes it
  n          integer    not null default 0,   -- variants (brand) / products (rest)
  rank       bigint     not null default 0,   -- popularity, for ordering
  norm       text       not null,             -- what a keystroke is matched against
  zones      smallint[] not null default '{}',-- zones this suggestion is available in
  query      text       not null,             -- what goes in the search box when picked
  primary key (kind, key)
);

-- Staging is keyed by (kind, key, SRC) — src being the unit that wrote the
-- row. A family spans id ranges, so a range unit contributes a PARTIAL count;
-- keeping the contributions apart is what makes re-running a unit a replace
-- rather than a double count, which is the difference between a resumable
-- bounded job and a cache that inflates every time the VM restarts.
drop table if exists public.search_suggest_stage;
create table public.search_suggest_stage (
  kind       text       not null,
  key        text       not null,
  src        text       not null default '',
  label      text       not null,
  sub_label  text       not null default '',
  n          integer    not null default 0,
  rank       bigint     not null default 0,
  norm       text       not null,
  zones      smallint[] not null default '{}',
  query      text       not null,
  primary key (kind, key, src)
);
create index if not exists idx_sss_bucket
  on public.search_suggest_stage ((abs(hashtext(key)) % 6));

create index if not exists idx_ssc_norm_prefix
  on public.search_suggest_cache (norm text_pattern_ops);
create index if not exists idx_ssc_norm_trgm
  on public.search_suggest_cache using gin (norm gin_trgm_ops);
create index if not exists idx_ssc_kind_rank
  on public.search_suggest_cache (kind, rank desc, n desc);
create index if not exists idx_ssc_zones
  on public.search_suggest_cache using gin (zones);
-- The swap deletes one hash bucket at a time; without this it is a seq scan
-- per bucket over the whole cache.
create index if not exists idx_ssc_bucket
  on public.search_suggest_cache (kind, (abs(hashtext(key)) % 6));

-- Guarded: a resumed worker re-applies this file, and an unconditional ALTER
-- takes an AccessExclusiveLock that the realtime publication can make wait.
do $$ begin
  if not (select relrowsecurity from pg_class where oid = 'public.search_suggest_cache'::regclass) then
    alter table public.search_suggest_cache enable row level security;
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.search_suggest_stage'::regclass) then
    alter table public.search_suggest_stage enable row level security;
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public'
                   and tablename = 'search_suggest_cache'
                   and policyname = 'public read search_suggest_cache') then
    create policy "public read search_suggest_cache"
      on public.search_suggest_cache for select using (true);
  end if;
end $$;

comment on table public.search_suggest_cache is
  'CHANGE #790 — every typeahead suggestion. Written by catalogue_cache_tick(); NEVER queried live over MEDICINE.';

-- ── 3. the Hinglish / Hindi mapping ─────────────────────────────────────────
-- Seeded once from Gemini (edge function `search-synonym-seed`, Vertex global,
-- gemini-3.5-flash) and admin-editable after that. The mapping runs BEFORE the
-- product query: "bukhar" becomes a Paracetamol search, not a name match.
create table if not exists public.search_synonym (
  term        text primary key,                    -- normalised, what the user types
  display     text not null,                       -- as printed back ('बुखार', 'bukhar')
  lang        text not null default 'hi',          -- notif language this belongs to
  target_kind text not null default 'salt',        -- salt | category | query
  target      text not null,                       -- 'Paracetamol', 'Cough & Cold', ...
  note        text not null default '',            -- the English meaning ('fever')
  source      text not null default 'gemini',      -- gemini | admin
  active      boolean not null default true,
  hits        bigint not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists idx_search_synonym_active
  on public.search_synonym (active, term);
create index if not exists idx_search_synonym_trgm
  on public.search_synonym using gin (term gin_trgm_ops);

do $$ begin
  if not (select relrowsecurity from pg_class where oid = 'public.search_synonym'::regclass) then
    alter table public.search_synonym enable row level security;
  end if;
end $$;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public'
                   and tablename = 'search_synonym'
                   and policyname = 'public read search_synonym') then
    create policy "public read search_synonym"
      on public.search_synonym for select using (true);
  end if;
end $$;

comment on table public.search_synonym is
  'CHANGE #790 — Hindi/Hinglish search terms mapped to a salt or a therapeutic class. Seeded from Gemini, admin-editable.';

-- ── 4. the bounded refresh units ────────────────────────────────────────────
-- Same table, same tick, same 60 s cron as #747. Suggestions are planned LAST
-- so they read a zone list and a facet count that this cycle already rebuilt.
create or replace function public.catalogue_refresh_plan()
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_min bigint; v_max bigint; v_step bigint := 150000;
  v_ord int := 0; v_lo bigint; z record; f text; b int;
begin
  select min(id), max(id) into v_min, v_max from "MEDICINE";
  if v_min is null then return 0; end if;

  delete from public.catalogue_refresh_unit;

  -- 1. sweep the zone arrays into the staging list, one id range at a time
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

  -- 2. then the counts, per zone (0 = everything) and per facet
  foreach f in array array['therapeutic','chemical','action','company','salt','tab','meta'] loop
    v_ord := v_ord + 1;
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      values (v_ord, 'facet', 0::smallint, f);
  end loop;
  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    foreach f in array array['therapeutic','chemical','action','company','salt','tab','meta'] loop
      v_ord := v_ord + 1;
      insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
        values (v_ord, 'facet', z.id, f);
    end loop;
  end loop;

  -- 3. CHANGE #790 — and finally the typeahead cache, off the rows step 1 and
  --    step 2 just wrote. Reset, then the brand sweep (id ranges, because the
  --    families come from "MEDICINE" itself), then the three facet-derived
  --    kinds, then a bucketed swap so no single statement rewrites 3 lakh rows.
  v_ord := v_ord + 1;
  insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
    values (v_ord, 'suggest_reset', 0::smallint, '');
  -- 25k ids per unit, not 150k: the brand sweep needs four wide columns per
  -- row, so it is heap I/O bound (~50 s per range on a cold cache) and a 150k
  -- range ran past the statement cap outright.
  v_lo := v_min;
  while v_lo <= v_max loop
    v_ord := v_ord + 1;
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg, arg2)
      values (v_ord, 'suggest_brand', 0::smallint, v_lo::text,
              least(v_lo + 24999, v_max)::text);
    v_lo := v_lo + 25000;
  end loop;
  -- zone membership for the families, off the 83k-row zone list rather than
  -- dragged through the 5.6 lakh-row sweep above
  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    v_ord := v_ord + 1;
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      values (v_ord, 'suggest_zone', z.id, z.id::text);
  end loop;
  foreach f in array array['salt','company','category'] loop
    v_ord := v_ord + 1;
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      values (v_ord, 'suggest_facet', 0::smallint, f);
  end loop;
  for b in 0..5 loop
    v_ord := v_ord + 1;
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      values (v_ord, 'suggest_swap', 0::smallint, b::text);
  end loop;

  update public.catalogue_refresh_state
     set cycle_started = now(), cycle_ended = null,
         last_note = 'planned ' || v_ord || ' units'
   where id = 1;
  return v_ord;
end $function$;

-- ── 5. one bounded unit of suggestion work ──────────────────────────────────
-- Called by catalogue_cache_tick() for the four `suggest_*` kinds. Every unit
-- is small enough to finish well inside the 55 s statement cap, and re-running
-- any unit is a clean rewrite of exactly what it owns.
create or replace function public.search_suggest_unit(
  p_kind text, p_arg text default '', p_arg2 text default '')
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows bigint := 0;
  v_bucket int;
begin
  if p_kind = 'suggest_reset' then
    delete from public.search_suggest_stage;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_brand' then
    -- One id range of "MEDICINE" folded into (brand root, company) families.
    -- The printed name is the SHORTEST real product name in the family — the
    -- catalogue's own text, never a name this function invents.
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select 'brand', g.root || '|' || coalesce(g.mc, ''), p_arg, g.label,
           coalesce(mc.display, g.mc, ''), g.n, g.rank, g.root, '{}'::smallint[], g.label
      from (
        select b.root, b.mc,
               (array_agg(b.product_name order by b.nlen, b.sales_count desc nulls last, b.id))[1] as label,
               count(*)::int as n,
               coalesce(sum(b.sales_count), 0)::bigint as rank
          from (
            select m.id, m.product_name, m.marketer_canonical as mc, m.sales_count,
                   public._brand_root(m.product_name) as root,
                   length(public._norm_name(m.product_name)) as nlen
              from public."MEDICINE" m
             where m.id between p_arg::bigint and p_arg2::bigint
               and public.catalogue_universe_ok(m.status)
               and nullif(btrim(m.product_name), '') is not null
          ) b
         group by b.root, b.mc
      ) g
      left join public.medicine_company mc on mc.canon = g.mc
    -- one row per (family, id range): re-running the range overwrites exactly
    -- what that range contributed and nothing else
    on conflict (kind, key, src) do update
      set n = excluded.n, rank = excluded.rank, label = excluded.label,
          sub_label = excluded.sub_label, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_zone' then
    -- Which families a zone can actually send, read off the materialised zone
    -- list (#747) instead of re-deriving availability here.
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    with fam as (
      select distinct public.brand_family_key(m.product_name, m.marketer_canonical) as key
        from public.catalogue_zone_avail za
        join public."MEDICINE" m on m.id = za.product_id
       where za.zone_id = v_bucket::smallint
    )
    update public.search_suggest_stage s
       set zones = (select coalesce(array_agg(distinct z order by z), '{}'::smallint[])
                      from unnest(s.zones || array[v_bucket::smallint]) z)
      from fam
     where s.kind = 'brand' and s.key = fam.key
       and not (s.zones @> array[v_bucket::smallint]);
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_facet' then
    -- Salts, companies and categories are already counted per zone by the
    -- facet units above (#747). Reading them costs one index scan each.
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select p_arg, c.facet_key, '', c.label, '', c.n, c.n::bigint,
           public._norm_name(c.label),
           coalesce((select array_agg(distinct z.zone_id order by z.zone_id)
                       from public.catalogue_facet_count z
                      where z.facet = c.facet and z.zone_id > 0
                        and z.facet_key = c.facet_key), '{}'::smallint[]),
           c.label
      from public.catalogue_facet_count c
     where c.zone_id = 0
       and c.facet = case p_arg when 'category' then 'therapeutic' else p_arg end
       and nullif(btrim(c.label), '') is not null
    on conflict (kind, key, src) do update
      set label = excluded.label, n = excluded.n, rank = excluded.rank,
          norm = excluded.norm, zones = excluded.zones, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_swap' then
    -- The exchange, one hash bucket at a time: no statement ever rewrites the
    -- whole cache, and a shopper mid-keystroke always reads a complete row.
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    delete from public.search_suggest_cache c
     where abs(hashtext(c.key)) % 6 = v_bucket;
    insert into public.search_suggest_cache(kind, key, label, sub_label, n, rank, norm, zones, query)
    select s.kind, s.key,
           (array_agg(s.label     order by length(s.label), s.src))[1],
           (array_agg(s.sub_label order by length(s.label), s.src))[1],
           sum(s.n)::int, sum(s.rank)::bigint,
           (array_agg(s.norm      order by length(s.label), s.src))[1],
           (array_agg(s.zones     order by cardinality(s.zones) desc, s.src))[1],
           (array_agg(s.query     order by length(s.label), s.src))[1]
      from public.search_suggest_stage s
     where abs(hashtext(s.key)) % 6 = v_bucket
     group by s.kind, s.key
    on conflict (kind, key) do update
      set label = excluded.label, sub_label = excluded.sub_label, n = excluded.n,
          rank = excluded.rank, norm = excluded.norm, zones = excluded.zones,
          query = excluded.query;
    get diagnostics v_rows = row_count;
  end if;

  return v_rows;
end $function$;

comment on function public.search_suggest_unit(text, text, text) is
  'CHANGE #790 — one bounded unit of typeahead-cache work, driven by catalogue_cache_tick().';

-- ── 6. the tick dispatches the new kinds ────────────────────────────────────
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
    v_where := 'public.catalogue_universe_ok(m.status)';

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
