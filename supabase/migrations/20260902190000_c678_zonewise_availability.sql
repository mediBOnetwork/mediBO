-- CHANGE #678 — zone-wise availability, and the trigger that kept nuking it.
--
-- THE COLLAPSE (root cause, verified 2026-09-02)
--   The Raipur hero read "220+ products"; it had been ~74,000. `sf_avail_counts`
--   for zone 1 held 220, published 16:06 UTC from a MASTER LIST that was in the
--   middle of a full rebuild (`zone_sync_state` zone 1 reset to last_id 0,
--   done=false, at ~16:24 UTC; zone 2 reset too).
--
--   WHO reset it: the trigger `trg_supplier_zone_lists_resync`
--   (AFTER UPDATE OF zone_id, is_deleted, supplier_name ON supplier_profiles)
--   runs `_zone_lists_full_resync()`, whose last statement is
--
--       UPDATE zone_sync_state SET last_id = 0, done = false;   -- EVERY zone
--
--   So ANY supplier rename, zone change, or soft-delete — including a QA or an
--   rg test supplier — tore down every zone's MEDICINE master list and rebuilt
--   it from scratch (hours), and for those hours availability read near-zero.
--   #640's rewrite of the sync happened to reset the cursor too, which is what
--   fired it today; but the trigger is the standing landmine.
--
-- THE FIX
--   1. Replace the full resync with INCREMENTAL propagation. A supplier edit
--      recomputes ONLY the companies that list that supplier, for ONLY the zones
--      involved, and NEVER resets zone_sync_state. The master list is edited in
--      place, so availability never dips.
--   2. A full cursor reset (`zone_sync_state` = 0) is now reachable ONLY through
--      an explicit admin RPC (`zone_full_rebuild`) — never a trigger, never a
--      migration replay, never a restore. This migration does not reset it.
--   3. Count refreshes (sf_avail_counts, medicine_count_cache, category caches,
--      the storefront feed) SKIP while any active zone is mid-rebuild and keep
--      the last good snapshot; and a refresh that would drop a zone's available
--      count by more than 20% is refused and raises an rg_alert. A partial
--      master list can never publish a number again.
--   4. Category counts become zone-aware: anon sees the global feed counts,
--      an approved customer sees their own zone's — the same rule the hero and
--      the cards already follow.
--
-- Idempotent throughout: re-running it replaces functions and re-attaches the
-- trigger, and touches no availability data.

-- 1. THE WORK QUEUE for incremental propagation
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.zone_resync_queue (
  zone_id     smallint not null,
  company_key text     not null,
  enqueued_at timestamptz not null default now(),
  primary key (zone_id, company_key)
);
comment on table public.zone_resync_queue is
  'CHANGE #678 — pending per-company master-list recomputes. A supplier edit '
  'enqueues (zone, company_key); zone_resync_drain() applies them with '
  'zone_sync_by_key(). Replaces the full zone_sync_state reset that collapsed '
  'availability on every supplier edit.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. INCREMENTAL PROPAGATION — the trigger stops resetting the world
-- ─────────────────────────────────────────────────────────────────────────────
--
-- What actually changed when a supplier row is updated:
--   * its zone (OLD.zone_id vs NEW.zone_id),
--   * whether it is deleted (is_deleted),
--   * its name (supplier_name).
-- The companies affected are those whose PS1..PS30 list the old or the new
-- name. We refresh company.z_<code>_sup and that zone's lookup for the affected
-- zones (both cheap — over the small `company` table), then ENQUEUE each
-- affected company key so its products' master lists are recomputed by
-- zone_sync_by_key on the next drain tick. zone_sync_state is never touched.
create or replace function public._supplier_zone_incremental()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_zones smallint[];
  v_names text[];
  z record;
begin
  -- Zones touched: the supplier's old and new zone.
  v_zones := (select array_agg(distinct zid)
                from unnest(array[OLD.zone_id, NEW.zone_id]) zid
               where zid is not null);
  if v_zones is null then return coalesce(NEW, OLD); end if;

  -- Names touched: old and new (a rename must clean up the old one too).
  v_names := (select array_agg(distinct lower(btrim(nm)))
                from unnest(array[OLD.supplier_name, NEW.supplier_name]) nm
               where btrim(coalesce(nm,'')) <> '');
  if v_names is null then return coalesce(NEW, OLD); end if;

  foreach z.id in array v_zones loop
    -- keep both `company.z_<code>_sup` and this zone's lookup current; both are
    -- over the ~thousands-row `company` table, so this is milliseconds, not the
    -- multi-hour MEDICINE rebuild the old trigger kicked off.
    perform public.zone_sync_company(z.id);
    perform public.zone_build_company_lookup(z.id);

    -- Enqueue every company key that lists (or listed) this supplier, so only
    -- those products' master lists are recomputed.
    insert into public.zone_resync_queue (zone_id, company_key)
    select z.id, l.key
      from public.zone_company_lookup l
     where l.zone_id = z.id
       and exists (select 1 from unnest(l.sups) s where lower(btrim(s)) = any(v_names))
    on conflict (zone_id, company_key) do update set enqueued_at = now();
  end loop;

  return coalesce(NEW, OLD);
end;
$$;


drop trigger if exists trg_supplier_zone_lists_resync on public.supplier_profiles;
drop trigger if exists trg_supplier_zone_incremental   on public.supplier_profiles;
create trigger trg_supplier_zone_incremental
  after update of zone_id, is_deleted, supplier_name on public.supplier_profiles
  for each row execute function public._supplier_zone_incremental();


-- The old full-resync function is kept (other callers/rg baseline may name it)
-- but DEFANGED: it no longer resets zone_sync_state. It refreshes the company
-- lists + lookup (cheap) and enqueues every lookup key for a targeted, in-place
-- recompute. Same effect, none of the collapse.
create or replace function public._zone_lists_full_resync()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform public.zone_sync_company(z.id)         from zones z where z.is_active;
  perform public.zone_build_company_lookup(z.id) from zones z where z.is_active;
  -- CHANGE #678 — NO `update zone_sync_state set last_id=0`. That single line
  -- collapsed availability on every supplier edit. Instead, enqueue every
  -- lookup key for an in-place, targeted recompute that never dips the count.
  insert into public.zone_resync_queue (zone_id, company_key)
  select l.zone_id, l.key from public.zone_company_lookup l
    join zones z on z.id = l.zone_id and z.is_active
  on conflict (zone_id, company_key) do update set enqueued_at = now();
  return coalesce(NEW, OLD);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE DRAIN — applies the queue with #640's targeted, indexed recompute
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.zone_resync_drain(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; v_keys int := 0; v_rows int := 0;
begin
  for r in
    select zone_id, company_key from public.zone_resync_queue
     order by enqueued_at limit greatest(coalesce(p_limit,200),1)
  loop
    v_rows := v_rows + public.zone_sync_by_key(r.zone_id::smallint, r.company_key);
    v_keys := v_keys + 1;
    delete from public.zone_resync_queue
     where zone_id = r.zone_id and company_key = r.company_key;
  end loop;
  return jsonb_build_object('status','ok','keys',v_keys,'rows_written',v_rows,
                            'remaining',(select count(*) from public.zone_resync_queue));
end;
$$;

-- Repoint the #640 dispatcher task: it drains the incremental queue now, and it
-- NEVER resets zone_sync_state. (The old body restarted the full sweep every
-- 20 h — a daily availability collapse in its own right.)
create or replace function public.zone_sup_sync_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not exists (select 1 from public.zone_resync_queue) then
    return jsonb_build_object('ok', true, 'idle', true);
  end if;
  return jsonb_build_object('ok', true, 'drained', public.zone_resync_drain(200));
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. FULL REBUILD IS ADMIN-ONLY — never a trigger, replay, or restore
-- ─────────────────────────────────────────────────────────────────────────────
-- A from-scratch cursor rebuild is legitimate exactly once: when a NEW zone is
-- added and its MEDICINE columns have never been filled. This is the ONLY place
-- allowed to set zone_sync_state back to 0, it is guarded to super-admin, and it
-- refuses to run for a zone that already has a substantial master list unless
-- forced — so a stray call can never wipe a healthy zone.
create or replace function public.zone_full_rebuild(p_zone_id smallint, p_force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_code text; v_have bigint;
begin
  if not public._is_super() then
    return jsonb_build_object('error','forbidden');
  end if;
  select code into v_code from zones where id = p_zone_id and is_active;
  if v_code is null then return jsonb_build_object('error','unknown_zone'); end if;

  execute format('select count(*) from public."MEDICINE" where coalesce(array_length(%I,1),0) > 0',
                 'z_'||v_code||'_sup') into v_have;
  if coalesce(v_have,0) > 1000 and not p_force then
    return jsonb_build_object('error','zone_not_empty','have',v_have,
      'hint','This zone already has a master list. Pass p_force=true only if you really mean to rebuild it from zero (availability will dip until it completes).');
  end if;

  insert into zone_sync_state(zone_id, last_id, done) values (p_zone_id, 0, false)
    on conflict (zone_id) do update set last_id = 0, done = false, updated_at = now();
  return jsonb_build_object('status','ok','zone',v_code,'note','cursor reset — zone_backfill will fill it');
end;
$$;
revoke all on function public.zone_full_rebuild(smallint, boolean) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE COUNT GUARD — never publish a number from a partial master list
-- ─────────────────────────────────────────────────────────────────────────────
--
-- A count refresh must be refused, keeping the last good snapshot, whenever:
--   (a) any active zone is mid-rebuild (zone_sync_state.done = false), OR
--   (b) the queue of pending per-company recomputes is non-empty, OR
--   (c) the number it is about to publish is more than 20% below the last one.
-- Each refusal raises an rg_alert so the guard is visible, not silent.

create or replace function public.zone_counts_are_settling()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
           select 1 from zone_sync_state s
             join zones z on z.id = s.zone_id and z.is_active
            where coalesce(s.done, false) = false)
      or exists (select 1 from zone_resync_queue);
$$;
comment on function public.zone_counts_are_settling() is
  'CHANGE #678 — true while any active zone master list is still being built or '
  'has pending per-company recomputes. Count refreshes hold the last snapshot '
  'while this is true, so a partial list never publishes a number.';

create or replace function public._avail_count_guard_alert(p_kind text, p_detail jsonb)
returns void
language sql
security definer
set search_path to 'public'
as $$
  insert into rg_alerts(fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
  values ('c678_'||p_kind, 'warn', 'ops', 'Availability count refresh held', p_detail, now(), now(), 1)
  on conflict (fingerprint) do update
    set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
        detail = excluded.detail, severity = 'warn';
$$;

-- sf_avail_counts: the hero and the storefront total. Rewritten to (1) skip
-- while settling, (2) refuse any per-zone value that is a >20% drop from the
-- stored one. It writes zone by zone, so a healthy zone still updates even if
-- another is settling.
create or replace function public.refresh_sf_avail_counts()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare z record; c bigint; v_total bigint; v_col text; v_prev bigint;
begin
  -- (a) hold everything while any active zone is still settling.
  if public.zone_counts_are_settling() then
    perform public._avail_count_guard_alert('sf_settling',
      jsonb_build_object('reason','a zone master list is still building; kept the last snapshot',
                         'zones', (select jsonb_agg(jsonb_build_object('zone',zone_id,'done',done,'last_id',last_id) order by zone_id) from zone_sync_state)));
    return;
  end if;

  -- global total (zone 0) comes from the count cache, never a fresh 563k scan.
  select total into v_total from public.medicine_count_cache limit 1;
  if v_total is null then select count(*) into v_total from "MEDICINE"; end if;
  insert into public.sf_avail_counts(zone_id, cnt, updated_at)
    values (0, v_total, now())
    on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();

  for z in select id, code from public.zones
            where is_active and not coalesce(is_synthetic, false) loop
    v_col := 'z_' || z.code || '_sup';
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name='MEDICINE' and column_name=v_col) then
      continue;
    end if;

    -- available = (master − oos − nostock) > 0, the one definition. This is the
    -- same expression the hero, the cards and the cart resolve through.
    execute format($q$
      select count(*) from "MEDICINE"
       where cardinality(public.medicine_zone_effective(%I,%I,%I,%I)) > 0
    $q$, 'z_'||z.code||'_sup','z_'||z.code||'_av','z_'||z.code||'_oos','z_'||z.code||'_nostock')
      into c;

    select cnt into v_prev from public.sf_avail_counts where zone_id = z.id;

    -- (c) a >20% drop is refused. Never let a partial list halve the hero again.
    if v_prev is not null and v_prev > 100 and coalesce(c,0) < v_prev * 0.8 then
      perform public._avail_count_guard_alert('sf_drop',
        jsonb_build_object('zone', z.id, 'code', z.code, 'prev', v_prev, 'proposed', c,
          'reason','refused a >20% drop; kept the last snapshot'));
      continue;   -- keep the old value for THIS zone
    end if;

    insert into public.sf_avail_counts(zone_id, cnt, updated_at)
      values (z.id, coalesce(c,0), now())
      on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();
  end loop;
end;
$$;

-- medicine_count_cache: the global buyable_total. Skip while settling so a
-- half-built catalogue never lowers it.
create or replace function public.refresh_medicine_count_cache()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_total bigint; v_buyable bigint; v_prev bigint;
begin
  if public.zone_counts_are_settling() then
    perform public._avail_count_guard_alert('count_cache_settling',
      jsonb_build_object('reason','kept the last buyable_total while a zone is building'));
    return jsonb_build_object('skipped', true, 'reason','settling');
  end if;

  select count(*), count(*) filter (where buyable is true) into v_total, v_buyable from "MEDICINE";
  select buyable_total into v_prev from medicine_count_cache where id = 1;
  if v_prev is not null and v_prev > 100 and v_buyable < v_prev * 0.8 then
    perform public._avail_count_guard_alert('count_cache_drop',
      jsonb_build_object('prev', v_prev, 'proposed', v_buyable, 'reason','refused a >20% buyable drop'));
    return jsonb_build_object('skipped', true, 'reason','drop_guard', 'prev', v_prev, 'proposed', v_buyable);
  end if;

  insert into medicine_count_cache (id, total, buyable_total, updated_at)
  values (1, v_total, v_buyable, now())
  on conflict (id) do update set total = excluded.total, buyable_total = excluded.buyable_total, updated_at = excluded.updated_at;
  return jsonb_build_object('total', v_total, 'buyable_total', v_buyable, 'at', now());
end;
$$;

-- refresh_storefront_feed: it rebuilds the feed AND calls refresh_sf_avail_counts.
-- Guard the whole thing — a feed rebuilt from a partial catalogue would drop the
-- category totals just like the hero. Skip while settling.
create or replace function public.refresh_storefront_feed()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if public.zone_counts_are_settling() then
    perform public._avail_count_guard_alert('feed_settling',
      jsonb_build_object('reason','kept the last storefront feed + category totals while a zone is building'));
    return;
  end if;
  if not pg_try_advisory_lock(778899001) then return; end if;
  perform set_config('statement_timeout', '240s', true);

  create temp table _all on commit drop as
    select id,
           coalesce(nullif(btrim(therapeutic_class), ''), 'OTHERS') as cat,
           (buyable
             and image_url_1 is not null
             and btrim(image_url_1) <> ''
             and image_url_1 not ilike '%drive.google.com%'
             and coalesce(nullif(regexp_replace(mrp::text,'[^0-9.]','','g'),'')::numeric, 0) > 0
           ) as feed_ok,
           sales_count
    from "MEDICINE";

  create temp table _ranked on commit drop as
    select id, cat,
           row_number() over (partition by lower(cat)
             order by sales_count desc nulls last, md5(id::text)) as rn
    from _all where feed_ok;

  delete from public.storefront_feed;
  insert into public.storefront_feed (category, rank, product_id)
  select 'All', row_number() over (order by rn, lower(cat)), id from _ranked;
  insert into public.storefront_feed (category, rank, product_id)
  select cat, rn, id from _ranked;

  delete from public.storefront_feed_meta;
  insert into public.storefront_feed_meta (category, total)
  select 'All', count(*) from _ranked
  union all select cat, count(*) from _ranked group by cat;

  perform public.refresh_sf_avail_counts();
  perform pg_advisory_unlock(778899001);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ZONE-AWARE CATEGORY COUNTS — anon = global, approved = their zone
-- ─────────────────────────────────────────────────────────────────────────────
--
-- The hero and the product cards already follow the rule (storefront_viewer_count
-- / storefront_effective_count). The CATEGORY tiles did not: get_all_storefront_counts
-- and medicine_category_counts returned the GLOBAL feed counts to everyone, so an
-- approved Raipur customer saw the whole catalogue's per-category numbers, not
-- their zone's. This adds a per-zone category cache and makes the three count
-- RPCs branch anon=global / approved=zone, exactly like the hero.

create table if not exists public.sf_category_counts_z (
  zone_id smallint not null,
  name    text     not null,
  n       bigint   not null,
  refreshed_at timestamptz not null default now(),
  primary key (zone_id, name)
);
comment on table public.sf_category_counts_z is
  'CHANGE #678 — per-zone available-per-category counts. Populated by '
  'refresh_zone_category_counts() while nothing is settling; read by the '
  'category-count RPCs for approved customers (global cache for anon).';

-- Rebuild a zone's category counts from the ONE availability definition:
-- available = (master − oos − nostock) > 0. Guarded: skips while settling.
create or replace function public.refresh_zone_category_counts()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare z record; v_rows int; v_total int := 0;
begin
  if public.zone_counts_are_settling() then
    perform public._avail_count_guard_alert('zone_cat_settling',
      jsonb_build_object('reason','kept the last per-zone category counts while a zone is building'));
    return jsonb_build_object('skipped', true, 'reason','settling');
  end if;

  for z in select id, code from public.zones
            where is_active and not coalesce(is_synthetic,false) loop
    execute format($q$
      create temp table _zc on commit drop as
      select coalesce(nullif(btrim(therapeutic_class),''),'OTHERS') as name, count(*)::bigint as n
        from "MEDICINE"
       where cardinality(public.medicine_zone_effective(%I,%I,%I,%I)) > 0
       group by 1
    $q$, 'z_'||z.code||'_sup','z_'||z.code||'_av','z_'||z.code||'_oos','z_'||z.code||'_nostock');

    select count(*) into v_rows from _zc;
    if v_rows > 0 then
      delete from public.sf_category_counts_z where zone_id = z.id;
      insert into public.sf_category_counts_z(zone_id, name, n, refreshed_at)
        select z.id, name, n, now() from _zc;
      insert into public.sf_category_counts_z(zone_id, name, n, refreshed_at)
        select z.id, 'All', coalesce(sum(n),0), now() from _zc
        on conflict (zone_id, name) do update set n = excluded.n, refreshed_at = now();
      v_total := v_total + v_rows;
    end if;
    drop table if exists _zc;
  end loop;
  return jsonb_build_object('ok', true, 'rows', v_total);
end;
$$;

-- The viewer's zone, or NULL for anon / unapproved (→ global).
create or replace function public._viewer_zone_or_null()
returns smallint
language sql
stable
security definer
set search_path to 'public'
as $$
  select case when public.viewer_is_approved_customer()
              then (select zone_id from public._storefront_viewer())
         end;
$$;

-- get_all_storefront_counts: the bulk map the storefront tiles read. Zone cache
-- for an approved viewer (when it is populated), else the global feed meta.
create or replace function public.get_all_storefront_counts()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with z as (select public._viewer_zone_or_null() as zid)
  select case
    when (select zid from z) is not null
         and exists (select 1 from sf_category_counts_z c where c.zone_id = (select zid from z))
      then (select coalesce(jsonb_object_agg(c.name, c.n),'{}'::jsonb)
              from sf_category_counts_z c where c.zone_id = (select zid from z))
    else (select coalesce(jsonb_object_agg(category, total),'{}'::jsonb)
            from storefront_feed_meta)
  end;
$$;

-- medicine_category_counts: the (name, n) list. Same branch.
create or replace function public.medicine_category_counts()
returns table(name text, n bigint)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_zone smallint := public._viewer_zone_or_null();
begin
  if v_zone is not null
     and exists (select 1 from sf_category_counts_z c where c.zone_id = v_zone and c.name <> 'All') then
    return query
      select c.name, c.n from sf_category_counts_z c
       where c.zone_id = v_zone and c.name <> 'All'
       order by c.n desc, c.name;
  elsif exists (select 1 from medicine_category_counts_cache) then
    return query
      select c.name, c.n from medicine_category_counts_cache c
       order by c.n desc, c.name;
  else
    return query
      select m.therapeutic_class as name, count(*)::bigint as n
        from "MEDICINE" m
       where m.buyable = true and m.therapeutic_class is not null and m.therapeutic_class <> ''
       group by m.therapeutic_class order by count(*) desc, m.therapeutic_class;
  end if;
end;
$$;

-- medicine_catalogue_count: the hero's own count block. buyable_total becomes
-- the viewer's zone available count (sf_avail_counts) for an approved customer,
-- the global buyable_total for anon — so the "N medicines" label matches the
-- hero pill.
create or replace function public.medicine_catalogue_count()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'total', c.total,
    'buyable_total', public.storefront_viewer_count(),
    'counted_at', c.updated_at,
    'label', to_char(public.storefront_viewer_count(), 'FM999,999,999') || ' medicines')
  from medicine_count_cache c where c.id = 1;
$$;
