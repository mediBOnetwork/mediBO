-- CHANGE #747 · step 1 — the Catalogue tab's COUNTS, and nothing that counts live.
--
-- Om: "the Catalogue bottom-nav button is dead". It has been dead since #630
-- gave the slot page_index 0 (Home) — a registry row pointing at a screen that
-- was never built. This command builds the section, and this migration builds
-- the only part of it that is expensive: the numbers beside every browse row.
--
-- The rule the spec states and the box enforces: NEVER count live over 5.6 lakh
-- rows. "MEDICINE" is 562,549 rows on a 1 GB instance whose anon role has a 3 s
-- statement budget (the #678 lesson), and a browse tree prints a count beside
-- every one of 22 therapeutic classes, 920 chemical classes, 439 action classes,
-- 18,578 companies and 107,619 salts. Counted live that is one aggregate scan
-- per screen; counted from here it is an indexed read of a narrow table.
--
-- TWO caches, because they answer two different questions:
--
--  catalogue_zone_avail  — WHICH products exist in a zone. This is the "Available
--    in my zone" switch's index. The truth lives in "MEDICINE".z_<code>_{sup,av,
--    oos,nostock} and is only computable through medicine_zone_effective(), which
--    is an array expression no index can serve. Materialised as (zone, product)
--    it becomes a plain join, so the switch costs a nested loop instead of a scan.
--
--  catalogue_facet_count — HOW MANY products sit under each browse node, per zone.
--    One table for all five facets (plus the two tabs) because they are the same
--    question asked of a different column, and one table means one refresh, one
--    staleness stamp and one place to look when a number is wrong.
--
-- Both are refreshed by BOUNDED units on the existing cron dispatcher — never a
-- bare */N schedule (the 2026-08-18 connection-exhaustion outage), never one giant
-- transaction, and never inside a user request.

-- ── the zone availability index ─────────────────────────────────────────────
create table if not exists public.catalogue_zone_avail (
  zone_id    smallint not null,
  product_id bigint   not null,
  primary key (zone_id, product_id)
);
comment on table public.catalogue_zone_avail is
  'CHANGE #747 — product ids available in each zone, materialised from '
  '"MEDICINE".z_<code>_* through medicine_zone_effective(). The index behind the '
  'catalogue''s "Available in my zone" switch. Refreshed in bounded id-range '
  'units by catalogue_cache_tick(); never written from a user request.';

-- The staging half of the swap: a sweep builds here, then one atomic exchange
-- replaces the zone. A half-built list is never visible to a shopper.
create table if not exists public.catalogue_zone_avail_stage (
  zone_id    smallint not null,
  product_id bigint   not null,
  primary key (zone_id, product_id)
);

alter table public.catalogue_zone_avail       enable row level security;
alter table public.catalogue_zone_avail_stage enable row level security;

-- ── the facet counts ────────────────────────────────────────────────────────
create table if not exists public.catalogue_facet_count (
  facet        text     not null,             -- therapeutic|chemical|action|company|salt|tab
  zone_id      smallint not null,             -- 0 = every zone (the anon / switch-off view)
  parent_key   text     not null default '',  -- '' | therapeutic | therapeutic+US+chemical
  facet_key    text     not null,             -- the value itself (company = canon)
  label        text     not null default '',  -- what the row PRINTS. Never derived in Dart.
  letter       text     not null default '',  -- A–Z or '#', for the company index
  n            bigint   not null default 0,
  refreshed_at timestamptz not null default now(),
  primary key (facet, zone_id, parent_key, facet_key)
);
comment on table public.catalogue_facet_count is
  'CHANGE #747 — one row per browse node per zone: therapeutic / chemical / '
  'action class, company, salt and the two tabs. `label` is the printed string '
  'and `n` the product count; the app renders both verbatim.';

alter table public.catalogue_facet_count enable row level security;

-- Ordering by size is the default on every catalogue list, so it gets the index.
create index if not exists idx_cat_facet_rank
  on public.catalogue_facet_count (facet, zone_id, parent_key, n desc, facet_key);
-- The company A–Z jumps straight to a letter.
create index if not exists idx_cat_facet_letter
  on public.catalogue_facet_count (facet, zone_id, letter, label)
  where facet = 'company';
-- Salt / company search is a prefix+substring match over the printed label.
create index if not exists idx_cat_facet_label_trgm
  on public.catalogue_facet_count using gin (lower(label) gin_trgm_ops);

-- ── the bounded refresh unit queue ──────────────────────────────────────────
-- Every unit is ONE statement's worth of work and one dispatcher tick. There is
-- no loop anywhere that can run long: the queue IS the loop, and it survives a
-- restart, a statement timeout and a busy instance.
create table if not exists public.catalogue_refresh_unit (
  ord        int      not null,
  kind       text     not null,               -- zone_scan | zone_swap | facet
  zone_id    smallint not null,
  arg        text     not null default '',    -- id-range start (scan) | facet name
  arg2       text     not null default '',    -- id-range end
  state      text     not null default 'pending',   -- pending | done
  rows_seen  bigint   not null default 0,
  ran_at     timestamptz,
  ms         int,
  last_error text,
  primary key (ord)
);
alter table public.catalogue_refresh_unit enable row level security;

create table if not exists public.catalogue_refresh_state (
  id            int primary key default 1,
  cycle_started timestamptz,
  cycle_ended   timestamptz,
  last_note     text not null default '',
  constraint catalogue_refresh_state_singleton check (id = 1)
);
insert into public.catalogue_refresh_state(id) values (1) on conflict (id) do nothing;
alter table public.catalogue_refresh_state enable row level security;

-- ── plan a cycle ────────────────────────────────────────────────────────────
-- Rebuilt from the live zone list every cycle, so onboarding a third zone is a
-- row in `zones` and nothing else. Ranges are id ranges, not offsets: an OFFSET
-- sweep re-reads everything it already read.
create or replace function public.catalogue_refresh_plan()
returns int
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_min bigint; v_max bigint; v_step bigint := 150000;
  v_ord int := 0; v_lo bigint; z record; f text;
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

  update public.catalogue_refresh_state
     set cycle_started = now(), cycle_ended = null,
         last_note = 'planned ' || v_ord || ' units'
   where id = 1;
  return v_ord;
end $$;

-- ── the universe ────────────────────────────────────────────────────────────
-- What the catalogue is allowed to show at all. Banned rows are not a stock
-- state, they are a legal one, so they leave the catalogue rather than render
-- as unavailable.
create or replace function public.catalogue_universe_ok(p_status text)
returns boolean
language sql immutable parallel safe
as $$ select coalesce(btrim(p_status),'') <> 'BANNED FOR SALE' $$;

-- The unit separator that joins therapeutic+chemical into an action class's
-- parent key. A character no class name can contain, so a split is exact.
create or replace function public.catalogue_parent_key(p_a text, p_b text)
returns text
language sql immutable parallel safe
as $$ select coalesce(p_a,'') || chr(31) || coalesce(p_b,'') $$;

-- ── run ONE unit ────────────────────────────────────────────────────────────
create or replace function public.catalogue_cache_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
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

  if u.kind = 'zone_scan' then
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
end $$;

-- ── the dispatcher row ──────────────────────────────────────────────────────
-- One unit a minute while there is work, silent when there is none. Never a
-- bare */N pg_cron schedule: the 2026-08-18 outage was 35 jobs colliding on
-- minute 0, and cron_task exists so a new job cannot join that pile-up.
insert into public.cron_task(name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                             enabled, note, base_interval_s, max_interval_s)
values (
  'catalogue_cache_refresh', 539, 'poll',
  $g$select exists (select 1 from public.catalogue_refresh_unit where state = 'pending')
        or coalesce((select cycle_ended from public.catalogue_refresh_state where id = 1),
                    '-infinity'::timestamptz) < now() - interval '12 hours'$g$,
  $w$select case
       when exists (select 1 from public.catalogue_refresh_unit where state='pending')
         then public.catalogue_cache_tick()
       else jsonb_build_object('planned', public.catalogue_refresh_plan())
     end$w$,
  50000, true,
  'CHANGE #747 — one bounded unit of the catalogue count rebuild per tick. '
  'Re-plans a whole cycle when the last one finished more than 12 hours ago.',
  60, 3600)
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      step_timeout_ms = excluded.step_timeout_ms, note = excluded.note,
      base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      enabled = true;
