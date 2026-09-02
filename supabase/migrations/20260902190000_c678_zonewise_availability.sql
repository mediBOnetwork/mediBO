-- CHANGE #678 — zone-wise availability everywhere, and the trigger that kept
-- nuking it. (v2 — supersedes the first cut of this file on the same branch.)
--
-- THE COLLAPSE (root cause, verified 2026-09-02 23:35 IST)
--   The Raipur hero read "220+ products"; it had been ~74,000. `sf_avail_counts`
--   for zone 1 held 220, published 16:06 UTC from a MASTER LIST that was in the
--   middle of a full rebuild (`zone_sync_state` zone 1 reset to last_id 0,
--   done=false, at ~16:24 UTC; zone 2 reset too).
--
--   WHO reset it: the trigger `trg_supplier_zone_lists_resync`
--   (AFTER UPDATE OF zone_id, is_deleted, supplier_name ON supplier_profiles)
--   ran `_zone_lists_full_resync()`, whose last statement was
--
--       UPDATE zone_sync_state SET last_id = 0, done = false;   -- EVERY zone
--
--   So ANY supplier rename, zone change, or soft-delete — including a QA or an
--   rg test supplier — tore down every zone's MEDICINE master list and rebuilt
--   it from scratch (hours), and for those hours availability read near-zero.
--   #640's rewrite of the sync happened to reset the cursor too, which is what
--   fired it today; but the trigger was the standing landmine.
--
-- THE FIX
--   1. Incremental propagation. A supplier edit (or a company's supplier map
--      changing) recomputes ONLY the companies that list that supplier, for
--      ONLY the zones involved, through a work queue drained every minute. The
--      master list is edited in place; zone_sync_state is never touched.
--   2. A cursor reset is IMPOSSIBLE except through `zone_full_rebuild()`
--      (super-admin, refuses a populated zone unless forced): a BEFORE trigger
--      on zone_sync_state rejects any last_id decrease, delete or truncate that
--      does not carry the rebuild flag — so a migration replay, a restore, a
--      stray UPDATE or an old function body all fail loudly instead of wiping
--      availability. A new zone (zone_add) has no cursor row, which is the only
--      other way the backfill starts.
--   3. Count refreshes (hero, category tiles, storefront feed, count cache)
--      SKIP while any active zone is mid-rebuild or the queue is non-empty and
--      keep the last good snapshot; a refresh that would drop a zone's number
--      by >20% is refused, recorded in sf_avail_counts_hist and raised as an
--      rg_alert; the rg behaviour `c678_avail_count_no_drop` turns the guard
--      red. A partial master list can never publish a number again.
--   4. ONE availability definition, everywhere:
--        effective(zone) = (master ∪ available) − oos − nostock
--      medicine_zone_standby, the hero/category/feed refresh, the buyable
--      trigger and the heal pass all read that expression.
--   5. The viewer rule, on every surface: anonymous / registered-but-unapproved
--      viewers see the GLOBAL catalogue and every sellable product as
--      available; an approved customer sees ONLY their zone — hero count,
--      category tiles + counts, the storefront feed (a per-zone feed table),
--      search ranking, product page and cart all resolve through the same two
--      helpers (_viewer_zone_or_null / storefront_effective_count).
--
-- Idempotent throughout: re-running it replaces functions, re-attaches
-- triggers, and touches no availability data.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE WORK QUEUE for incremental propagation
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.zone_resync_queue (
  zone_id     smallint not null,
  company_key text     not null,
  enqueued_at timestamptz not null default now(),
  primary key (zone_id, company_key)
);
alter table public.zone_resync_queue enable row level security;
comment on table public.zone_resync_queue is
  'CHANGE #678 — pending per-company master-list recomputes. A supplier edit '
  'or a company supplier-map change enqueues (zone, company_key); '
  'zone_resync_drain() applies them with zone_sync_by_key(). Replaces the full '
  'zone_sync_state reset that collapsed availability on every supplier edit.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. INCREMENTAL PROPAGATION — supplier edits stop resetting the world
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._supplier_zone_incremental()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_zones smallint[];
  v_names text[];
  v_zid   smallint;
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

  foreach v_zid in array v_zones loop
    -- keep both `company.z_<code>_sup` and this zone's lookup current; both are
    -- over the ~thousands-row `company` table, so this is seconds, not the
    -- multi-hour MEDICINE rebuild the old trigger kicked off.
    perform public.zone_sync_company(v_zid);
    perform public.zone_build_company_lookup(v_zid);

    -- Enqueue every company key that lists (or listed) this supplier, so only
    -- those products' master lists are recomputed.
    insert into public.zone_resync_queue (zone_id, company_key)
    select v_zid, l.key
      from public.zone_company_lookup l
     where l.zone_id = v_zid
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

-- The old full-resync function is kept (other callers / the rg baseline name
-- it) but DEFANGED: it no longer resets zone_sync_state. It refreshes the
-- company lists + lookup (cheap) and enqueues every lookup key for a targeted,
-- in-place recompute. Same effect, none of the collapse.
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
  -- collapsed availability on every supplier edit.
  insert into public.zone_resync_queue (zone_id, company_key)
  select l.zone_id, l.key from public.zone_company_lookup l
    join zones z on z.id = l.zone_id and z.is_active
  on conflict (zone_id, company_key) do update set enqueued_at = now();
  return coalesce(NEW, OLD);
end;
$$;

-- A company's supplier map changed (supplier_company map/unmap →
-- refresh_company_suppliers → company.suppliers → PS1..PS30). The old body
-- rewrote every product of the company INLINE with
-- `resolve_company_canonical(m.marketer) = ANY(keys)` — a function call per
-- row over 563k rows, inside a trigger, on every supplier mapping. It now keeps
-- company.z_<code>_sup + the lookup current (cheap, indexed) and ENQUEUES the
-- company for the drain, which reaches the products through the indexed
-- marketer_canonical column within a minute.
create or replace function public.company_ps_to_medicine()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare z record; v_zone_sups text[]; v_keys text[]; j jsonb;
begin
  j := to_jsonb(NEW);
  v_keys := array(select k from unnest(array[
              nullif(btrim(coalesce(NEW.name_canonical,'')),''),
              nullif(lower(btrim(coalesce(NEW.company_name,''))),'')]) k where k is not null);
  if array_length(v_keys,1) is null then return NEW; end if;

  for z in select id, code from zones where is_active loop
    select coalesce(array_agg(distinct btrim(x.v) order by btrim(x.v)),'{}')
      into v_zone_sups
    from (select j ->> ('PS'||g) as v from generate_series(1,30) g) x
    join supplier_profiles sp
      on lower(btrim(sp.supplier_name)) = lower(btrim(x.v))
     and sp.zone_id = z.id and not coalesce(sp.is_deleted,false)
    where btrim(coalesce(x.v,'')) <> '';

    execute format('update public.company set %I = $1 where id = $2 and %I is distinct from $1',
                   'z_'||z.code||'_sup','z_'||z.code||'_sup') using v_zone_sups, NEW.id;

    update zone_company_lookup l set sups = v_zone_sups
     where l.zone_id = z.id and l.key = any(v_keys) and l.sups is distinct from v_zone_sups;
    insert into zone_company_lookup(zone_id, key, sups)
    select z.id, k, v_zone_sups from unnest(v_keys) k
    on conflict (zone_id, key) do nothing;

    -- CHANGE #678 — the products are recomputed by the drain, not here.
    insert into public.zone_resync_queue (zone_id, company_key)
    select z.id, k from unnest(v_keys) k
    on conflict (zone_id, company_key) do update set enqueued_at = now();
  end loop;
  return NEW;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE DRAIN — applies the queue with a bounded, indexed recompute
-- ─────────────────────────────────────────────────────────────────────────────
-- zone_sync_by_key gains a row cap so one 5,000-product company can never pin
-- the cron dispatcher: the drain writes at most p_limit rows per key per tick
-- and keeps the key queued while rows remain. (The old 2-arg signature is
-- dropped so the call site resolves to exactly one function.)
drop function if exists public.zone_sync_by_key(smallint, text);
create or replace function public.zone_sync_by_key(p_zone_id smallint, p_key text, p_limit integer default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_code text; v_canons text[]; v_n int;
begin
  select code into v_code from zones where id = p_zone_id and is_active;
  if v_code is null then return 0; end if;

  -- Every marketer_canonical that resolves to this key: the key itself, plus
  -- every alias variant grouped under it. resolve_company_canonical() says the
  -- same thing one row at a time; this says it once, as a set.
  select coalesce(array_agg(distinct u.c), '{}'::text[]) into v_canons
    from (select p_key as c
          union all
          select a.variant_canonical from company_alias a where a.group_key = p_key) u;

  execute format($q$
    WITH src AS (
      SELECT m.id,
             (SELECT coalesce(array_agg(DISTINCT t.s ORDER BY t.s), '{}'::text[])
                FROM (SELECT btrim(x) AS s FROM unnest(
                        coalesce(l.sups,'{}'::text[])
                        || coalesce(m.%2$I,'{}'::text[])
                        || coalesce(m.%3$I,'{}'::text[])
                        || coalesce(m.%4$I,'{}'::text[])) x) t
               WHERE t.s <> '') AS want
      FROM public."MEDICINE" m
      LEFT JOIN zone_company_lookup l ON l.zone_id = $2 AND l.key = $3
      WHERE m.marketer_canonical = ANY($1)
    ), todo AS (
      SELECT s.id, s.want FROM src s
      JOIN public."MEDICINE" m ON m.id = s.id
      WHERE m.%1$I IS DISTINCT FROM s.want
      ORDER BY s.id
      LIMIT $4
    ), upd AS (
      UPDATE public."MEDICINE" m SET %1$I = t.want
        FROM todo t WHERE m.id = t.id
      RETURNING m.id
    )
    -- a pending inquiry on a recomputed product re-ranks against the new list
    UPDATE inquiry SET product_id = product_id
     WHERE supplier_order_id IS NULL AND asked_at IS NULL
       AND product_id IN (SELECT id FROM upd)
  $q$, 'z_'||v_code||'_sup', 'z_'||v_code||'_av',
       'z_'||v_code||'_oos', 'z_'||v_code||'_nostock')
  USING v_canons, p_zone_id, p_key, greatest(coalesce(p_limit, 1000000), 1);

  -- rows written = rows the CTE selected; the inquiry poke's row count is not it
  execute format($q$
    SELECT count(*) FROM public."MEDICINE" m
     WHERE m.marketer_canonical = ANY($1)
       AND m.%1$I IS DISTINCT FROM (
             SELECT coalesce(array_agg(DISTINCT t.s ORDER BY t.s), '{}'::text[])
               FROM (SELECT btrim(x) AS s FROM unnest(
                       coalesce((SELECT l.sups FROM zone_company_lookup l
                                  WHERE l.zone_id = $2 AND l.key = $3),'{}'::text[])
                       || coalesce(m.%2$I,'{}'::text[])
                       || coalesce(m.%3$I,'{}'::text[])
                       || coalesce(m.%4$I,'{}'::text[])) x) t
              WHERE t.s <> '')
  $q$, 'z_'||v_code||'_sup', 'z_'||v_code||'_av',
       'z_'||v_code||'_oos', 'z_'||v_code||'_nostock')
  INTO v_n USING v_canons, p_zone_id, p_key;

  -- rows STILL pending for this key (0 = converged). The drain keeps the key
  -- queued while this is > 0.
  return coalesce(v_n, 0);
end;
$$;

create or replace function public.zone_resync_drain(p_limit integer default 200)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; v_keys int := 0; v_done int := 0; v_left int; v_t0 timestamptz := clock_timestamp();
begin
  for r in
    select zone_id, company_key from public.zone_resync_queue
     order by enqueued_at limit greatest(coalesce(p_limit,200),1)
  loop
    -- 400 rows per key per tick keeps one write burst inside the dispatcher's
    -- budget on this 1 GB instance (~50 ms per non-HOT MEDICINE update).
    v_left := public.zone_sync_by_key(r.zone_id::smallint, r.company_key, 400);
    v_keys := v_keys + 1;
    if v_left = 0 then
      delete from public.zone_resync_queue
       where zone_id = r.zone_id and company_key = r.company_key;
      v_done := v_done + 1;
    else
      update public.zone_resync_queue set enqueued_at = now()
       where zone_id = r.zone_id and company_key = r.company_key;
    end if;
    -- never run past the tick's budget; the rest waits for the next minute
    exit when clock_timestamp() - v_t0 > interval '20 seconds';
  end loop;
  return jsonb_build_object('status','ok','keys',v_keys,'converged',v_done,
                            'remaining',(select count(*) from public.zone_resync_queue));
end;
$$;

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

-- The drain runs every minute (Om's requirement: a newly mapped supplier's
-- products are available in its zone within a minute); the backfill task is
-- re-armed — its gate only opens for a zone with no finished cursor, which after
-- this change means a NEW zone (zone_add) or an explicit zone_full_rebuild().
update public.cron_task
   set enabled = true, base_interval_s = 60, max_interval_s = 300,
       current_interval_s = 60, step_timeout_ms = 55000, dml = true,
       next_run_at = least(coalesce(next_run_at, now()), now() + interval '1 minute'),
       note = 'CHANGE #678 — drains zone_resync_queue (incremental master-list propagation). Never resets zone_sync_state.'
 where name = 'zone_sup_sync';
update public.cron_task
   set enabled = true,
       note = 'CHANGE #678 — id-sweep backfill for a zone whose cursor is not done: a NEW zone (zone_add) or an explicit zone_full_rebuild(). Nothing else can open this gate.'
 where name = 'zone_backfill';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. FULL REBUILD IS ADMIN-ONLY — and a cursor reset is otherwise impossible
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._zone_sync_state_guard()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('medibo.zone_rebuild_ok', true), '') = '1' then
    return coalesce(NEW, OLD);
  end if;
  if TG_OP = 'DELETE' then
    raise exception 'zone_sync_state: deleting zone % cursor is refused (CHANGE #678) — a master-list rebuild must go through zone_full_rebuild()', OLD.zone_id
      using errcode = 'check_violation';
  end if;
  if NEW.last_id < OLD.last_id then
    raise exception 'zone_sync_state: cursor reset for zone % (% → %) is refused (CHANGE #678) — that rebuild collapses availability for hours; use zone_full_rebuild()', OLD.zone_id, OLD.last_id, NEW.last_id
      using errcode = 'check_violation';
  end if;
  return NEW;
end;
$$;

create or replace function public._zone_sync_state_no_truncate()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('medibo.zone_rebuild_ok', true), '') = '1' then
    return null;
  end if;
  raise exception 'zone_sync_state: TRUNCATE is refused (CHANGE #678) — use zone_full_rebuild()'
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists zzz_zone_sync_state_guard on public.zone_sync_state;
create trigger zzz_zone_sync_state_guard
  before update or delete on public.zone_sync_state
  for each row execute function public._zone_sync_state_guard();
drop trigger if exists zzz_zone_sync_state_no_truncate on public.zone_sync_state;
create trigger zzz_zone_sync_state_no_truncate
  before truncate on public.zone_sync_state
  for each statement execute function public._zone_sync_state_no_truncate();

-- The ONLY legitimate cursor reset: a super-admin rebuilding a zone from zero,
-- and even that refuses a populated zone unless forced.
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

  perform set_config('medibo.zone_rebuild_ok', '1', true);   -- transaction-local
  insert into zone_sync_state(zone_id, last_id, done) values (p_zone_id, 0, false)
    on conflict (zone_id) do update set last_id = 0, done = false, updated_at = now();
  perform set_config('medibo.zone_rebuild_ok', '', true);
  return jsonb_build_object('status','ok','zone',v_code,'note','cursor reset — zone_backfill will fill it');
end;
$$;
revoke all on function public.zone_full_rebuild(smallint, boolean) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. ONE DEFINITION — effective(zone) = (master ∪ available) − oos − nostock
-- ─────────────────────────────────────────────────────────────────────────────
-- medicine_zone_standby used to subtract array LENGTHS (sup − oos − nostock),
-- which disagrees with the set expression whenever a responder sits in oos
-- without being on the master list. Every reader now uses the set.
create or replace function public.medicine_zone_standby(p_product_id bigint, p_zone_id smallint)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_code text; v_n int;
begin
  select code into v_code from zones where id = p_zone_id and is_active;
  if v_code is null then return 0; end if;
  execute format(
    'select cardinality(public.medicine_zone_effective(%I,%I,%I,%I)) from public."MEDICINE" where id = $1',
    'z_'||v_code||'_sup','z_'||v_code||'_av','z_'||v_code||'_oos','z_'||v_code||'_nostock')
    into v_n using p_product_id;
  return coalesce(v_n, 0);
end $$;

-- _ps_count (buyable_recompute_tick's per-row count) counted the raw master
-- lists; the trigger counts the effective set. Same number now.
create or replace function public._ps_count(m "MEDICINE")
returns integer
language sql
stable
as $$
  select count(distinct s)::int
  from zones z,
       lateral unnest(public.medicine_zone_effective_j(to_jsonb(m), z.code)) s
  where z.is_active;
$$;

-- The heal pass: rewrite supplier_count / buyable / supplier_label from the
-- effective sets for one id range, only where they disagree. Generated per
-- active zone so it names the columns (no to_jsonb detoast per row).
create or replace function public.availability_heal_batch(p_from bigint, p_to bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_expr text; v_n int;
begin
  select string_agg(format('public.medicine_zone_effective(m.%I, m.%I, m.%I, m.%I)',
           'z_'||z.code||'_sup', 'z_'||z.code||'_av', 'z_'||z.code||'_oos', 'z_'||z.code||'_nostock'), ' || ')
    into v_expr
    from (select code from zones where is_active order by code) z;
  if v_expr is null then return jsonb_build_object('ok', false, 'reason', 'no active zones'); end if;

  execute format($q$
    with x as (
      select m.id, (select count(distinct s) from unnest(%s) s)::int as n
        from public."MEDICINE" m
       where m.id > $1 and m.id <= $2
    ), upd as (
      update public."MEDICINE" m
         set supplier_count = x.n, buyable = (x.n > 0), supplier_label = public._supplier_label(x.n)
        from x
       where m.id = x.id
         and (m.supplier_count is distinct from x.n
              or coalesce(m.buyable, false) is distinct from (x.n > 0)
              or m.supplier_label is distinct from public._supplier_label(x.n))
      returning m.id
    )
    select count(*) from upd
  $q$, v_expr) into v_n using p_from, p_to;
  return jsonb_build_object('ok', true, 'from', p_from, 'to', p_to, 'healed', coalesce(v_n, 0));
end;
$$;
revoke all on function public.availability_heal_batch(bigint, bigint) from anon, authenticated;

-- A supplier who ANSWERED for a product (inquiry history, stock-update loop)
-- belongs on that zone's master list even if the company map has forgotten
-- them — the invariant set_state keeps live, restored here for history that a
-- rebuild may have dropped. Idempotent; returns rows touched per zone.
create or replace function public.zone_readd_responders()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare z record; v_n int; v_out jsonb := '{}'::jsonb;
begin
  for z in select id, code from zones where is_active and not coalesce(is_synthetic,false) loop
    execute format($q$
      with r as (
        select i.product_id, btrim(i.responsed_by) as sup
          from inquiry i
         where i.zone_id = $1 and i.product_id is not null
           and btrim(coalesce(i.responsed_by,'')) <> ''
        union
        select q.product_id, btrim(q.supplier_name)
          from stock_update_queue q
         where q.zone_id = $1 and q.product_id is not null
           and btrim(coalesce(q.supplier_name,'')) <> ''
      ), live as (
        select r.product_id, sp.supplier_name as sup
          from r
          join supplier_profiles sp
            on lower(btrim(sp.supplier_name)) = lower(r.sup)
           and sp.zone_id = $1 and not coalesce(sp.is_deleted,false)
      )
      update public."MEDICINE" m
         set %1$I = (select coalesce(array_agg(distinct s order by s), '{}'::text[])
                       from unnest(m.%1$I || l.sups) s)
        from (select product_id, array_agg(distinct sup) as sups from live group by product_id) l
       where m.id = l.product_id
         and not (m.%1$I @> l.sups)
    $q$, 'z_'||z.code||'_sup') using z.id;
    get diagnostics v_n = row_count;
    v_out := v_out || jsonb_build_object(z.code, v_n);
  end loop;
  return v_out;
end;
$$;
revoke all on function public.zone_readd_responders() from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE VIEWER RULE — anon / unapproved = global, approved = zone
-- ─────────────────────────────────────────────────────────────────────────────
-- The viewer's zone, or NULL for anon / unapproved (→ global). Resolved through
-- the ACCOUNT (customer_users, View-As) like the cart, not only auth.uid().
create or replace function public._viewer_zone_or_null()
returns smallint
language sql
stable
security definer
set search_path to 'public'
as $$
  select case when public.viewer_is_approved_customer()
              then coalesce((select pp.zone_id from public.pharmacy_profiles pp
                              where pp.id = public.my_customer_id()),
                            (select zone_id from public._storefront_viewer()))
         end;
$$;

-- The one product-level answer. Anonymous / unregistered / unapproved viewers
-- see every sellable product as available (the global catalogue, never a zone
-- verdict); an approved customer sees their zone's standby count.
create or replace function public.storefront_effective_count(p_product_id bigint, p_global integer)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_zone smallint; v_status text;
begin
  select m.status into v_status from public."MEDICINE" m where m.id = p_product_id;
  if not public.med_status_sellable(v_status) then
    return -1;                       -- banned / discontinued / not for sale
  end if;
  v_zone := public._viewer_zone_or_null();
  if v_zone is not null then
    return public.medicine_zone_standby(p_product_id, v_zone);  -- zone truth
  end if;
  -- CHANGE #678: anon and unapproved viewers see everything as available.
  return greatest(coalesce(p_global, 0), 1);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE COUNT GUARD + ONE PASS PER ZONE: hero, category tiles, feed
-- ─────────────────────────────────────────────────────────────────────────────
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

-- Every refresh attempt, accepted or refused, is history: the rg behaviour
-- reads it, and so does anyone asking "what did the hero say yesterday".
create table if not exists public.sf_avail_counts_hist (
  id        bigserial primary key,
  zone_id   smallint not null,
  cnt       bigint   not null,          -- the number proposed by the refresh
  prev      bigint,                     -- what was published before it
  accepted  boolean  not null,
  reason    text,
  at        timestamptz not null default now()
);
create index if not exists sf_avail_counts_hist_zone_at on public.sf_avail_counts_hist(zone_id, at desc);
alter table public.sf_avail_counts_hist enable row level security;

-- Per-zone category counts (the tiles) …
create table if not exists public.sf_category_counts_z (
  zone_id smallint not null,
  name    text     not null,
  n       bigint   not null,
  refreshed_at timestamptz not null default now(),
  primary key (zone_id, name)
);
alter table public.sf_category_counts_z enable row level security;
comment on table public.sf_category_counts_z is
  'CHANGE #678 — per-zone available-per-category counts (name ''All'' = the zone '
  'total = the hero number). Written by _refresh_zone_avail() in the same pass '
  'as sf_avail_counts and storefront_feed_z; read for approved customers.';

-- … and the per-zone feed (what an approved customer scrolls).
create table if not exists public.storefront_feed_z (
  zone_id    smallint not null,
  category   text     not null,
  rank       integer  not null,
  product_id bigint   not null,
  primary key (zone_id, category, rank)
);
create index if not exists storefront_feed_z_lookup on public.storefront_feed_z(zone_id, lower(category), rank);
alter table public.storefront_feed_z enable row level security;
comment on table public.storefront_feed_z is
  'CHANGE #678 — the storefront feed per zone: every product available in the '
  'zone, image+price rows first, then by sales. Read by _sf_feed_ids() for an '
  'approved customer; anon reads the global storefront_feed.';

-- ONE pass for ONE zone: scan MEDICINE once with the one definition, then write
-- the hero number, the category counts and the feed together — or, if the
-- guard refuses, none of them. Numbers on the three surfaces can never
-- disagree, because they are the same scan.
create or replace function public._refresh_zone_avail(p_zone_id smallint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_code text; v_total bigint; v_prev bigint; v_cats int;
begin
  select code into v_code from zones
   where id = p_zone_id and is_active and not coalesce(is_synthetic, false);
  if v_code is null then return jsonb_build_object('ok', false, 'reason', 'unknown_zone'); end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='MEDICINE' and column_name='z_'||v_code||'_sup') then
    return jsonb_build_object('ok', false, 'reason', 'no_columns');
  end if;

  drop table if exists _zr;
  execute format($q$
    create temp table _zr on commit drop as
    select m.id,
           coalesce(nullif(btrim(m.therapeutic_class),''),'OTHERS') as cat,
           (m.image_url_1 is not null and btrim(m.image_url_1) <> ''
             and m.image_url_1 not ilike '%%drive.google.com%%'
             and coalesce(nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),'')::numeric, 0) > 0) as feed_ok,
           m.sales_count
      from public."MEDICINE" m
     where (cardinality(m.%1$I) > 0 or cardinality(m.%2$I) > 0)
       and cardinality(public.medicine_zone_effective(m.%1$I, m.%2$I, m.%3$I, m.%4$I)) > 0
  $q$, 'z_'||v_code||'_sup','z_'||v_code||'_av','z_'||v_code||'_oos','z_'||v_code||'_nostock');

  select count(*) into v_total from _zr;
  select cnt into v_prev from public.sf_avail_counts where zone_id = p_zone_id;

  -- the >20% drop guard: never let a partial list halve the hero again
  if v_prev is not null and v_prev > 100 and v_total < v_prev * 0.8 then
    insert into public.sf_avail_counts_hist(zone_id, cnt, prev, accepted, reason)
      values (p_zone_id, v_total, v_prev, false, 'refused: >20% drop');
    perform public._avail_count_guard_alert('sf_drop',
      jsonb_build_object('zone', p_zone_id, 'code', v_code, 'prev', v_prev, 'proposed', v_total,
        'reason','refused a >20% drop; kept the last snapshot'));
    return jsonb_build_object('ok', false, 'reason', 'drop_guard', 'zone', v_code,
                              'prev', v_prev, 'proposed', v_total);
  end if;

  -- 1. the hero number
  insert into public.sf_avail_counts(zone_id, cnt, updated_at)
    values (p_zone_id, v_total, now())
    on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();
  insert into public.sf_avail_counts_hist(zone_id, cnt, prev, accepted, reason)
    values (p_zone_id, v_total, v_prev, true, null);

  -- 2. the category counts (+ 'All' = the same total as the hero)
  delete from public.sf_category_counts_z where zone_id = p_zone_id;
  insert into public.sf_category_counts_z(zone_id, name, n, refreshed_at)
    select p_zone_id, cat, count(*), now() from _zr group by cat;
  insert into public.sf_category_counts_z(zone_id, name, n, refreshed_at)
    values (p_zone_id, 'All', v_total, now())
    on conflict (zone_id, name) do update set n = excluded.n, refreshed_at = now();
  get diagnostics v_cats = row_count;

  -- 3. the feed: image+price rows first, then by sales, stable tiebreak
  delete from public.storefront_feed_z where zone_id = p_zone_id;
  insert into public.storefront_feed_z(zone_id, category, rank, product_id)
    select p_zone_id, 'All',
           row_number() over (order by feed_ok desc, sales_count desc nulls last, md5(id::text)),
           id
      from _zr;
  insert into public.storefront_feed_z(zone_id, category, rank, product_id)
    select p_zone_id, cat,
           row_number() over (partition by cat order by feed_ok desc, sales_count desc nulls last, md5(id::text)),
           id
      from _zr;

  drop table if exists _zr;
  -- the hero number for this zone just changed: drop every cached home payload
  delete from public.storefront_home_cache;
  return jsonb_build_object('ok', true, 'zone', v_code, 'available', v_total, 'prev', v_prev);
end;
$$;

-- All zones, guarded: hold everything while any zone is settling. Zone 0 (the
-- anonymous hero) is the catalogue total from the count cache.
create or replace function public.refresh_zone_availability_counts(p_zone_id smallint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare z record; v_total bigint; v_out jsonb := '[]'::jsonb;
begin
  if public.zone_counts_are_settling() then
    perform public._avail_count_guard_alert('sf_settling',
      jsonb_build_object('reason','a zone master list is still building; kept the last snapshot',
                         'zones', (select jsonb_agg(jsonb_build_object('zone',zone_id,'done',done,'last_id',last_id) order by zone_id) from zone_sync_state),
                         'queued', (select count(*) from zone_resync_queue)));
    return jsonb_build_object('skipped', true, 'reason', 'settling');
  end if;

  select total into v_total from public.medicine_count_cache where id = 1;
  if v_total is null then select count(*) into v_total from "MEDICINE"; end if;
  insert into public.sf_avail_counts(zone_id, cnt, updated_at)
    values (0, v_total, now())
    on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();

  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic, false)
              and (p_zone_id is null or id = p_zone_id)
            order by id loop
    v_out := v_out || public._refresh_zone_avail(z.id);
  end loop;
  return jsonb_build_object('ok', true, 'global', v_total, 'zones', v_out);
end;
$$;

-- Old names stay callable: refresh_storefront_feed() and the cron rows call
-- refresh_sf_avail_counts(); the first cut of this change registered
-- refresh_zone_category_counts(). Both are now the one pass above.
create or replace function public.refresh_sf_avail_counts()
returns void
language sql
security definer
set search_path to 'public'
as $$ select public.refresh_zone_availability_counts(null); $$;

create or replace function public.refresh_zone_category_counts()
returns jsonb
language sql
security definer
set search_path to 'public'
as $$ select public.refresh_zone_availability_counts(null); $$;

-- The scheduled tick refreshes ONE zone per run (each scan is ~1 minute on this
-- instance and the dispatcher tick is bounded), stalest first, when it is older
-- than 4 hours. The catalogue total (zone 0) rides along.
create or replace function public.zone_avail_counts_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_z smallint; v_total bigint;
begin
  if public.zone_counts_are_settling() then
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'settling');
  end if;
  select z.id into v_z
    from public.zones z
    left join (select zone_id, max(refreshed_at) as at from public.sf_category_counts_z group by zone_id) c
           on c.zone_id = z.id
   where z.is_active and not coalesce(z.is_synthetic, false)
     and coalesce(c.at, '-infinity'::timestamptz) < now() - interval '4 hours'
   order by c.at nulls first, z.id
   limit 1;
  if v_z is null then
    return jsonb_build_object('ok', true, 'idle', true);
  end if;
  select total into v_total from public.medicine_count_cache where id = 1;
  if v_total is not null then
    insert into public.sf_avail_counts(zone_id, cnt, updated_at) values (0, v_total, now())
      on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();
  end if;
  return jsonb_build_object('ok', true, 'zone', v_z, 'result', public._refresh_zone_avail(v_z));
end;
$$;

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled,
                              base_interval_s, max_interval_s, current_interval_s, next_run_at, dml, note)
values ('zone_avail_counts', 537, 'poll',
        $g$select not public.zone_counts_are_settling()
              and exists (select 1 from public.zones z
                           left join (select zone_id, max(refreshed_at) as at from public.sf_category_counts_z group by zone_id) c on c.zone_id = z.id
                          where z.is_active and not coalesce(z.is_synthetic,false)
                            and coalesce(c.at, '-infinity'::timestamptz) < now() - interval '4 hours')$g$,
        'select public.zone_avail_counts_tick()',
        110000, true, 900, 3600, 900, now() + interval '15 minutes', true,
        'CHANGE #678 — per-zone hero count + category counts + zone feed, one zone per tick, stalest first, every ~4h. Skips while a zone is settling; refuses a >20% drop.')
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql, step_timeout_ms = excluded.step_timeout_ms,
      enabled = true, base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      dml = true, note = excluded.note;

-- medicine_count_cache: the global buyable_total. Skip while settling; refuse a
-- >20% buyable drop.
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

-- The global (buyable) category cache: skip while settling — buyable heals
-- with the sweep, so a half-healed catalogue would lower every tile.
create or replace function public.refresh_medicine_category_counts()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_rows int;
begin
  if public.zone_counts_are_settling() then
    perform public._avail_count_guard_alert('mcc_settling',
      jsonb_build_object('reason','kept the last global category counts while a zone is building'));
    return 0;
  end if;
  create temp table _mcc_new on commit drop as
    select therapeutic_class as name, count(*)::bigint as n
    from public."MEDICINE"
    where buyable = true and therapeutic_class is not null and therapeutic_class <> ''
    group by therapeutic_class;

  select count(*) into v_rows from _mcc_new;
  if v_rows = 0 then
    return 0;   -- never blank the cache on a bad read
  end if;

  delete from public.medicine_category_counts_cache;
  insert into public.medicine_category_counts_cache(name, n, refreshed_at)
    select name, n, now() from _mcc_new;
  return v_rows;
end $$;

-- refresh_storefront_feed: the GLOBAL feed (buyable + image + price) and, via
-- refresh_sf_avail_counts, the zone pass. Guarded as a whole.
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

-- The dirty-flag wrapper used to clear the flag BEFORE running, so a refresh
-- skipped by the guard lost its trigger until the daily safety net. The flag
-- now survives a skip.
create or replace function public.refresh_storefront_feed_if_dirty()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_dirty boolean;
begin
  select dirty into v_dirty from job_dirty_state where job = 'storefront_feed';
  if not coalesce(v_dirty, true) then return jsonb_build_object('skipped', true); end if;
  if public.zone_counts_are_settling() then
    return jsonb_build_object('skipped', true, 'reason', 'settling', 'dirty_kept', true);
  end if;
  update job_dirty_state set dirty = false, last_run_at = now() where job = 'storefront_feed';
  perform public.refresh_storefront_feed();
  return jsonb_build_object('ran', true);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE READERS — every count and feed RPC branches on the viewer's zone
-- ─────────────────────────────────────────────────────────────────────────────
-- (category, total) for the viewer: the zone cache when the viewer is an
-- approved customer and their zone has been counted, else the global feed meta.
create or replace function public._sf_category_counts()
returns table(category text, total bigint)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_zone smallint := public._viewer_zone_or_null();
begin
  if v_zone is not null
     and exists (select 1 from sf_category_counts_z c where c.zone_id = v_zone) then
    return query select c.name, c.n from sf_category_counts_z c where c.zone_id = v_zone;
  else
    return query select m.category, m.total from storefront_feed_meta m;
  end if;
end;
$$;

-- (product_id, rank) for the viewer's feed page: the zone feed for an approved
-- customer whose zone has one, else the global feed.
create or replace function public._sf_feed_ids(p_category text, p_offset integer, p_limit integer)
returns table(product_id bigint, rank integer)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_zone smallint := public._viewer_zone_or_null();
begin
  if v_zone is not null
     and exists (select 1 from storefront_feed_z f where f.zone_id = v_zone) then
    return query
      select f.product_id, f.rank from storefront_feed_z f
       where f.zone_id = v_zone and lower(f.category) = lower(coalesce(p_category,'All'))
       order by f.rank limit greatest(coalesce(p_limit,20),1) offset greatest(coalesce(p_offset,0),0);
  else
    return query
      select sf.product_id, sf.rank from storefront_feed sf
       where lower(sf.category) = lower(coalesce(p_category,'All'))
       order by sf.rank limit greatest(coalesce(p_limit,20),1) offset greatest(coalesce(p_offset,0),0);
  end if;
end;
$$;

create or replace function public.get_storefront_count(category_filter text default 'All'::text)
returns bigint
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select c.total from public._sf_category_counts() c
                    where lower(c.category) = lower(coalesce(category_filter,'All')) limit 1), 0);
$$;

create or replace function public.get_all_storefront_counts()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_object_agg(c.category, c.total), '{}'::jsonb)
    from public._sf_category_counts() c;
$$;

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

-- medicine_catalogue_count: the "N medicines" block — the viewer's number.
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

-- The feed page reads the viewer's feed. Same columns as before.
create or replace function public.get_storefront_feed(category_filter text default 'All'::text, page_offset integer default 0, page_limit integer default 20)
returns table(url text, product_name text, salt_composition text, marketer text, rx_required text, image_url_1 text, image_url_2 text, image_url_3 text, image_url_4 text, image_url_5 text, image_count text, storage text, mrp text, pack_size text, pack_qty text, pack_type text, scrapping_status text, status text, status_reason text, uses text, benefits text, side_effects text, how_it_works text, habit_forming text, therapeutic_class text, chemical_class text, action_class text, product_introduction text, product_highlight text, id bigint, _row_id bigint, sales_count integer, has_scheme boolean, has_image boolean, gst_percent integer, "PS1" text, "PS2" text, "PS3" text, "PS4" text, "PS5" text, "PS6" text, "PS7" text, "PS8" text, "PS9" text, "PS10" text, "PS11" text, "PS12" text, "PS13" text, "PS14" text, "PS15" text, "PS16" text, "PS17" text, "PS18" text, "PS19" text, "PS20" text, "PS21" text, "PS22" text, "PS23" text, "PS24" text, "PS25" text, "PS26" text, "PS27" text, "PS28" text, "PS29" text, "PS30" text, buyable boolean, data_source text, marketer_canonical text, tm_id bigint, supplier_count integer, supplier_label text, showing_label text)
language sql
stable
security definer
set search_path to 'public'
as $$
  with page as (
    select m.*, f.rank as _rank, count(*) over () as _n
    from public._sf_feed_ids(category_filter, page_offset, page_limit) f
    join "MEDICINE" m on m.id = f.product_id
  )
  select p.url, p.product_name, p.salt_composition, p.marketer, p.rx_required,
         p.image_url_1, p.image_url_2, p.image_url_3, p.image_url_4, p.image_url_5,
         p.image_count, p.storage, p.mrp,
         coalesce(nullif(btrim(p.pack_qty),''),  nullif(btrim(p.pack_size),'')) as pack_size,
         coalesce(nullif(btrim(p.pack_type),''), nullif(btrim(p.pack_size),'')) as pack_qty,
         coalesce(nullif(btrim(p.pack_qty),''),  nullif(btrim(p.pack_size),'')) as pack_type,
         p.scrapping_status, p.status, p.status_reason, p.uses, p.benefits,
         p.side_effects, p.how_it_works, p.habit_forming, p.therapeutic_class,
         p.chemical_class, p.action_class, p.product_introduction, p.product_highlight,
         p.id, p._row_id, p.sales_count, p.has_scheme, p.has_image, p.gst_percent,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         NULL::text, NULL::text, NULL::text, NULL::text, NULL::text, NULL::text,
         p.buyable, p.data_source, p.marketer_canonical, p.tm_id,
         p.supplier_count,
         case when public.get_my_role() in ('admin','super_admin')
              then coalesce(p.supplier_label,'') else '' end,
         'Showing ' || p._n::text
                    || ' of ' || coalesce(public.get_storefront_count(category_filter),0)::text
                    || ' products'
                    || case when lower(coalesce(category_filter,'All')) = 'all'
                            then '' else ' in ' || category_filter end
  from page p
  order by p._rank;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE HOME FEED — rails and the category grid follow the viewer too
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.storefront_home_v2(p_items integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_sections    jsonb := '[]'::jsonb;
  v_ids         bigint[];
  v_see_all     text;
  v_see_fmt     text;
  v_label       text;
  v_search_hint text;
  v_theme       jsonb;
  v_title       text;
  v_accentw     text;
  v_subtitle    text;
  v_n           int;
  v_total       int;
  v_cap         int;
  v_cards       jsonb;
  s             record;
begin
  select public.storefront_theme() into v_theme;
  v_see_all := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_label'), 'See all products');
  v_see_fmt := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_count_label'), '');
  v_search_hint := coalesce((select value from public.storefront_ui_label
                              where key = 'search_hint'), '');

  for s in
    select * from public.storefront_home_section where active order by ord
  loop
    v_n := least(s.item_count, greatest(coalesce(p_items, 100), 1));

    if s.kind = 'feed' then
      -- CHANGE #678: the viewer's feed (zone feed for an approved customer).
      select array_agg(f.product_id order by f.rank) into v_ids
        from public._sf_feed_ids(s.category, 0, v_n) f;
      continue when v_ids is null;

      v_title    := case when s.title <> '' then s.title
                         else initcap(lower(s.category)) end;
      v_accentw  := case when s.accent_word <> '' then s.accent_word
                         else split_part(initcap(lower(s.category)), ' ', 1) end;
      v_subtitle := case when s.subtitle <> '' then s.subtitle
                         else 'TOP PICKS IN ' || s.category end;

      v_total := public.get_storefront_count(s.category);
      v_cap   := case when s.max_items > 0 then least(v_total, s.max_items)
                      else v_total end;
      v_label := case when v_see_fmt <> ''
                      then replace(v_see_fmt, '{n}', to_char(v_total, 'FM999,999'))
                      else v_see_all end;

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', s.layout,
        'title', v_title, 'accent_word', v_accentw, 'subtitle', v_subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'see_all_label', v_label,
        'see_all', jsonb_build_object('type','category','key', s.category),
        'infinite', s.infinite,
        'next_offset', coalesce(array_length(v_ids, 1), 0),
        'page_size', s.page_size,
        'total', v_cap,
        'items', public._sf_cards(v_ids));

    elsif s.kind = 'recently_viewed' then
      continue when auth.uid() is null;

      select array_agg(product_id order by viewed_at desc) into v_ids
      from (select product_id, viewed_at from public.recently_viewed
             where user_id = auth.uid()
             order by viewed_at desc limit v_n) t;
      continue when v_ids is null;

      v_cards := public._sf_cards(v_ids);
      continue when jsonb_array_length(v_cards) = 0;

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', s.layout,
        'title',       case when s.title <> '' then s.title
                            else public.sf_label('recent_title') end,
        'accent_word', case when s.accent_word <> '' then s.accent_word
                            else public.sf_label('recent_accent_word') end,
        'subtitle',    case when s.subtitle <> '' then s.subtitle
                            else public.sf_label('recent_subtitle') end,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'see_all_label', '',
        'see_all', jsonb_build_object('type','','key',''),
        'infinite', false,
        'next_offset', 0,
        'page_size', 0,
        'total', jsonb_array_length(v_cards),
        'items', v_cards);

    elsif s.kind = 'icon_grid' then
      -- CHANGE #678: the viewer's category counts (zone for approved).
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'icon_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', initcap(lower(fm.category)),
            'count_label', to_char(fm.total,'FM999,999') || ' products',
            'key', fm.category) order by fm.total desc), '[]'::jsonb)
          from (select c.category, c.total from public._sf_category_counts() c
                 where c.category <> 'All' and c.total > 0
                 order by c.total desc limit s.item_count) fm));

    elsif s.kind = 'brand_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'brand_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', mc.display,
            'count_label', to_char(mc.buyable_count,'FM999,999') || ' products',
            'key', mc.canon) order by mc.buyable_count desc), '[]'::jsonb)
          from (select display, canon, buyable_count from public.medicine_company
                 where buyable_count > 0 order by buyable_count desc
                 limit s.item_count) mc));

    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'generated_for', 'home',
    'theme', v_theme,
    'header', jsonb_build_object(
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'fg',        '#FFFFFF',
      'accent',    v_theme->>'accent',
      'search_hint', v_search_hint),
    'hero', jsonb_build_object(
      'show',    true,
      'eyebrow', coalesce((select value from public.storefront_ui_label where key = 'hero_eyebrow'), ''),
      'title',   coalesce((select value from public.storefront_ui_label where key = 'hero_title'), ''),
      'cta',     coalesce((select value from public.storefront_ui_label where key = 'hero_cta'), ''),
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'accent',    v_theme->>'accent',
      -- the hero number: the viewer's count (zone for approved, catalogue for anon)
      'props', jsonb_build_array(
        jsonb_build_object('icon','inventory','label',
          to_char(public.storefront_viewer_count(),'FM9,99,99,999') || '+ products'),
        jsonb_build_object('icon','truck','label',coalesce((select value from public.storefront_ui_label where key='delivery_time'),'Same-day delivery')),
        jsonb_build_object('icon','verified','label','Licensed distributors'))),
    'sections', v_sections);
end
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9b. THE HOME PAYLOAD IS CACHED PER VIEWER CLASS
-- ─────────────────────────────────────────────────────────────────────────────
-- storefront_home_v2 builds 25 rails × 24 cards (~1 MB) on every visit: 2–4 s
-- on this instance (pg_stat_statements mean 4.2 s), while the anon role's
-- statement_timeout is 3 s — so the public home, the surface that shows the
-- hero number, failed with "Retry" whenever the box was busy. The payload is
-- identical for every viewer of one class (anon / unapproved, or one zone's
-- approved customers) except the per-user recently-viewed rail, so it is built
-- once per class, kept 10 minutes, invalidated by every count refresh, warmed
-- for anon by the cron, and the recently-viewed rail is spliced in per user.
create table if not exists public.storefront_home_cache (
  cache_key text primary key,                  -- 'anon:100' | 'zone:1:100'
  payload   jsonb not null,
  ords      jsonb not null default '[]'::jsonb, -- ord of every section in payload, in order
  built_at  timestamptz not null default now(),
  build_ms  integer
);
alter table public.storefront_home_cache enable row level security;

-- The builder: the whole payload except the per-user rail, plus the ord list.
create or replace function public._storefront_home_build(p_items integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_sections    jsonb := '[]'::jsonb;
  v_ords        jsonb := '[]'::jsonb;
  v_ids         bigint[];
  v_see_all     text;
  v_see_fmt     text;
  v_label       text;
  v_search_hint text;
  v_theme       jsonb;
  v_title       text;
  v_accentw     text;
  v_subtitle    text;
  v_n           int;
  v_total       int;
  v_cap         int;
  s             record;
begin
  select public.storefront_theme() into v_theme;
  v_see_all := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_label'), 'See all products');
  v_see_fmt := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_count_label'), '');
  v_search_hint := coalesce((select value from public.storefront_ui_label
                              where key = 'search_hint'), '');

  for s in
    select * from public.storefront_home_section where active order by ord
  loop
    v_n := least(s.item_count, greatest(coalesce(p_items, 100), 1));

    if s.kind = 'feed' then
      select array_agg(f.product_id order by f.rank) into v_ids
        from public._sf_feed_ids(s.category, 0, v_n) f;
      continue when v_ids is null;

      v_title    := case when s.title <> '' then s.title
                         else initcap(lower(s.category)) end;
      v_accentw  := case when s.accent_word <> '' then s.accent_word
                         else split_part(initcap(lower(s.category)), ' ', 1) end;
      v_subtitle := case when s.subtitle <> '' then s.subtitle
                         else 'TOP PICKS IN ' || s.category end;

      v_total := public.get_storefront_count(s.category);
      v_cap   := case when s.max_items > 0 then least(v_total, s.max_items)
                      else v_total end;
      v_label := case when v_see_fmt <> ''
                      then replace(v_see_fmt, '{n}', to_char(v_total, 'FM999,999'))
                      else v_see_all end;

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', s.layout,
        'title', v_title, 'accent_word', v_accentw, 'subtitle', v_subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'see_all_label', v_label,
        'see_all', jsonb_build_object('type','category','key', s.category),
        'infinite', s.infinite,
        'next_offset', coalesce(array_length(v_ids, 1), 0),
        'page_size', s.page_size,
        'total', v_cap,
        'items', public._sf_cards(v_ids));
      v_ords := v_ords || to_jsonb(s.ord);

    elsif s.kind = 'recently_viewed' then
      continue;   -- per user: spliced in by storefront_home_v2

    elsif s.kind = 'icon_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'icon_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', initcap(lower(fm.category)),
            'count_label', to_char(fm.total,'FM999,999') || ' products',
            'key', fm.category) order by fm.total desc), '[]'::jsonb)
          from (select c.category, c.total from public._sf_category_counts() c
                 where c.category <> 'All' and c.total > 0
                 order by c.total desc limit s.item_count) fm));
      v_ords := v_ords || to_jsonb(s.ord);

    elsif s.kind = 'brand_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'brand_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', mc.display,
            'count_label', to_char(mc.buyable_count,'FM999,999') || ' products',
            'key', mc.canon) order by mc.buyable_count desc), '[]'::jsonb)
          from (select display, canon, buyable_count from public.medicine_company
                 where buyable_count > 0 order by buyable_count desc
                 limit s.item_count) mc));
      v_ords := v_ords || to_jsonb(s.ord);
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'generated_for', 'home',
    'theme', v_theme,
    'header', jsonb_build_object(
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'fg',        '#FFFFFF',
      'accent',    v_theme->>'accent',
      'search_hint', v_search_hint),
    'hero', jsonb_build_object(
      'show',    true,
      'eyebrow', coalesce((select value from public.storefront_ui_label where key = 'hero_eyebrow'), ''),
      'title',   coalesce((select value from public.storefront_ui_label where key = 'hero_title'), ''),
      'cta',     coalesce((select value from public.storefront_ui_label where key = 'hero_cta'), ''),
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'accent',    v_theme->>'accent',
      -- the hero number: the viewer's count (zone for approved, catalogue for anon)
      'props', jsonb_build_array(
        jsonb_build_object('icon','inventory','label',
          to_char(public.storefront_viewer_count(),'FM9,99,99,999') || '+ products'),
        jsonb_build_object('icon','truck','label',coalesce((select value from public.storefront_ui_label where key='delivery_time'),'Same-day delivery')),
        jsonb_build_object('icon','verified','label','Licensed distributors'))),
    'sections', v_sections,
    '_ords', v_ords);
end
$$;
revoke all on function public._storefront_home_build(integer) from anon, authenticated;

-- The per-user rail, with its ord so it can be spliced at the right place.
create or replace function public._storefront_home_recent(p_items integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare s record; v_n int; v_ids bigint[]; v_cards jsonb; v_theme jsonb;
begin
  if auth.uid() is null then return null; end if;
  select * into s from public.storefront_home_section
   where active and kind = 'recently_viewed' order by ord limit 1;
  if s.id is null then return null; end if;
  v_n := least(s.item_count, greatest(coalesce(p_items, 100), 1));
  select array_agg(product_id order by viewed_at desc) into v_ids
  from (select product_id, viewed_at from public.recently_viewed
         where user_id = auth.uid()
         order by viewed_at desc limit v_n) t;
  if v_ids is null then return null; end if;
  v_cards := public._sf_cards(v_ids);
  if jsonb_array_length(v_cards) = 0 then return null; end if;
  select public.storefront_theme() into v_theme;
  return jsonb_build_object(
    'id', s.id, 'layout', s.layout,
    'title',       case when s.title <> '' then s.title
                        else public.sf_label('recent_title') end,
    'accent_word', case when s.accent_word <> '' then s.accent_word
                        else public.sf_label('recent_accent_word') end,
    'subtitle',    case when s.subtitle <> '' then s.subtitle
                        else public.sf_label('recent_subtitle') end,
    'band', coalesce(v_theme->>s.band_key, ''),
    'accent', s.accent,
    'see_all_label', '',
    'see_all', jsonb_build_object('type','','key',''),
    'infinite', false,
    'next_offset', 0,
    'page_size', 0,
    'total', jsonb_array_length(v_cards),
    'items', v_cards,
    '_ord', s.ord);
end
$$;
revoke all on function public._storefront_home_recent(integer) from anon, authenticated;

-- The RPC: serve the class's cached payload (build it when missing or older
-- than 10 minutes; serve stale while another caller rebuilds), then splice the
-- viewer's own recently-viewed rail at its ord. VOLATILE because it writes the
-- cache; PostgREST calls it by POST as before.
create or replace function public.storefront_home_v2(p_items integer default 100)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_zone smallint; v_key text; v_n int := greatest(coalesce(p_items, 100), 1);
  v_cached jsonb; v_ords jsonb; v_built timestamptz; v_payload jsonb;
  v_rv jsonb; v_idx int; v_t0 timestamptz;
begin
  v_zone := public._viewer_zone_or_null();
  v_key  := coalesce('zone:' || v_zone::text, 'anon') || ':' || v_n;

  select payload, ords, built_at into v_cached, v_ords, v_built
    from public.storefront_home_cache where cache_key = v_key;

  if v_cached is null or v_built < now() - interval '10 minutes' then
    if v_cached is not null
       and not pg_try_advisory_xact_lock(hashtext('c678_home:' || v_key)) then
      v_payload := v_cached;                 -- someone else is rebuilding; stale is fine
    else
      v_t0 := clock_timestamp();
      v_payload := public._storefront_home_build(v_n);
      v_ords    := coalesce(v_payload -> '_ords', '[]'::jsonb);
      v_payload := v_payload - '_ords';
      insert into public.storefront_home_cache (cache_key, payload, ords, built_at, build_ms)
      values (v_key, v_payload, v_ords, now(),
              (extract(epoch from clock_timestamp() - v_t0) * 1000)::int)
      on conflict (cache_key) do update
        set payload = excluded.payload, ords = excluded.ords,
            built_at = now(), build_ms = excluded.build_ms;
    end if;
  else
    v_payload := v_cached;
  end if;

  if auth.uid() is not null then
    v_rv := public._storefront_home_recent(v_n);
    if v_rv is not null then
      select count(*) into v_idx
        from jsonb_array_elements_text(coalesce(v_ords, '[]'::jsonb)) o
       where o::int < (v_rv ->> '_ord')::int;
      v_payload := jsonb_set(v_payload, '{sections}',
        jsonb_insert(coalesce(v_payload -> 'sections', '[]'::jsonb),
                     array[v_idx::text], v_rv - '_ord'));
    end if;
  end if;
  return v_payload;
end
$$;
grant execute on function public.storefront_home_v2(integer) to anon, authenticated;

-- Warm the public home every few minutes so an anonymous visit never pays the
-- build (the anon role has a 3 s statement budget). Zone classes are built
-- lazily by their first approved visitor (8 s budget) and kept 10 minutes.
create or replace function public.storefront_home_warm_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_payload jsonb; v_ords jsonb; v_t0 timestamptz := clock_timestamp();
begin
  perform set_config('request.jwt.claims', '', true);   -- build as anon
  v_payload := public._storefront_home_build(100);
  v_ords    := coalesce(v_payload -> '_ords', '[]'::jsonb);
  v_payload := v_payload - '_ords';
  insert into public.storefront_home_cache (cache_key, payload, ords, built_at, build_ms)
  values ('anon:100', v_payload, v_ords, now(),
          (extract(epoch from clock_timestamp() - v_t0) * 1000)::int)
  on conflict (cache_key) do update
    set payload = excluded.payload, ords = excluded.ords,
        built_at = now(), build_ms = excluded.build_ms;
  delete from public.storefront_home_cache where built_at < now() - interval '1 hour';
  return jsonb_build_object('ok', true, 'key', 'anon:100',
                            'ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::int,
                            'hero', v_payload -> 'hero' -> 'props' -> 0 ->> 'label');
end
$$;
revoke all on function public.storefront_home_warm_tick() from anon, authenticated;

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled,
                              base_interval_s, max_interval_s, current_interval_s, next_run_at, dml, note)
values ('storefront_home_warm', 538, 'poll',
        $g$select not exists (select 1 from public.storefront_home_cache
                             where cache_key = 'anon:100' and built_at > now() - interval '8 minutes')$g$,
        'select public.storefront_home_warm_tick()',
        50000, true, 120, 600, 120, now() + interval '1 minute', true,
        'CHANGE #678 — rebuilds the anonymous home payload (25 rails, ~1 MB, 2-4 s) so an anon visit is served from cache inside the 3 s anon budget. Invalidated by every count refresh.')
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql, step_timeout_ms = excluded.step_timeout_ms,
      enabled = true, base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      dml = true, note = excluded.note;

-- A count refresh changes the hero number: drop every cached home.
create or replace function public.refresh_zone_availability_counts(p_zone_id smallint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare z record; v_total bigint; v_out jsonb := '[]'::jsonb;
begin
  if public.zone_counts_are_settling() then
    perform public._avail_count_guard_alert('sf_settling',
      jsonb_build_object('reason','a zone master list is still building; kept the last snapshot',
                         'zones', (select jsonb_agg(jsonb_build_object('zone',zone_id,'done',done,'last_id',last_id) order by zone_id) from zone_sync_state),
                         'queued', (select count(*) from zone_resync_queue)));
    return jsonb_build_object('skipped', true, 'reason', 'settling');
  end if;

  select total into v_total from public.medicine_count_cache where id = 1;
  if v_total is null then select count(*) into v_total from "MEDICINE"; end if;
  insert into public.sf_avail_counts(zone_id, cnt, updated_at)
    values (0, v_total, now())
    on conflict (zone_id) do update set cnt = excluded.cnt, updated_at = now();

  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic, false)
              and (p_zone_id is null or id = p_zone_id)
            order by id loop
    v_out := v_out || public._refresh_zone_avail(z.id);
  end loop;
  delete from public.storefront_home_cache;   -- the hero number just changed
  return jsonb_build_object('ok', true, 'global', v_total, 'zones', v_out);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. SEARCH — an approved customer's results rank their zone's availability
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.search_medicines_priority(search_term text, category_filter text default 'All'::text, page_offset integer default 0, page_limit integer default 20)
returns table(id bigint, product_name text, salt_composition text, marketer text, therapeutic_class text, image_url_1 text, pack_qty text, pack_size text, pack_type text, mrp text, gst_percent integer, status text, rx_required text, sales_count integer, has_scheme boolean, has_image boolean, buyable boolean, supplier_count integer, supplier_label text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_clean text; v_all boolean; v_brand text; v_pref text; v_tok text;
  v_toks text[]; v_keep text[]; v_compact text; v_cl int; v_brand_dm text;
  v_co text; v_co_norm text; v_co_tier int := 0;
  v_zone smallint := public._viewer_zone_or_null();   -- CHANGE #678
  c_forms text[] := array['tab','tablet','tablets','cap','capsule','capsules','inj','injection',
      'syp','syr','syrup','oint','ointment','cream','gel','drop','drops','susp','suspension',
      'sachet','powder','lotion','soln','solution','tube','kit','sol','spray','respules',
      'rotacap','inhaler','er','sr','xr','md','mg','ml','gm','gms','mcg','mgs','the','and','for'];
  c_brandskip text[] := array['tab','tablet','tablets','cap','capsule','capsules','inj','injection',
      'syp','syr','syrup','oint','ointment','cream','gel','drop','drops','susp','suspension',
      'sachet','powder','lotion','soln','solution','tube','kit','sol','spray','respules',
      'rotacap','inhaler','the','and','for','type','types'];
begin
  category_filter := coalesce(nullif(btrim(category_filter),''), 'All');
  v_all := (category_filter = 'All');
  v_clean := public._norm_name(search_term);
  if length(replace(v_clean,' ','')) < 3 then return; end if;
  v_toks := coalesce(regexp_split_to_array(v_clean, '\s+'), array[]::text[]);

  v_brand := null;
  foreach v_tok in array v_toks loop
    if v_tok ~ '[a-z]' and length(v_tok) >= 3 and not (v_tok = any(c_brandskip)) then
      v_brand := v_tok; exit; end if;
  end loop;
  if v_brand is null then v_brand := split_part(v_clean,' ',1); end if;
  v_pref     := left(v_brand, 3);
  v_brand_dm := dmetaphone(v_brand);

  v_keep := array[]::text[];
  foreach v_tok in array v_toks loop
    if not (v_tok = any(c_forms)) then v_keep := v_keep || v_tok; end if;
  end loop;
  if array_length(v_keep,1) is null then v_keep := v_toks; end if;
  v_compact := array_to_string(v_keep, '');
  v_cl      := length(v_compact);

  select mc.canon, mc.name_norm into v_co, v_co_norm
  from medicine_company mc
  where mc.name_norm = v_clean
     or (length(v_clean) >= 4 and mc.name_norm like v_clean || '%')
  order by (mc.name_norm = v_clean) desc, mc.buyable_count desc, mc.product_count desc
  limit 1;

  if v_co is null and length(replace(v_clean,' ','')) >= 5 then
    select mc.canon, mc.name_norm into v_co, v_co_norm
    from medicine_company mc
    where mc.name_norm like '%' || v_clean || '%'
    order by mc.buyable_count desc, mc.product_count desc
    limit 1;
  end if;

  if v_co is not null then
    v_co_tier := case
      when v_co_norm = v_clean           then 92
      when v_co_norm like v_clean || '%' then 86
      else 78 end;
  end if;

  return query
  with co_ids as materialized (
    select m.id from "MEDICINE" m
    where v_co is not null
      and m.marketer_canonical = v_co
      and (v_all or lower(m.therapeutic_class) = lower(category_filter))
    order by m.buyable desc, m.sales_count desc nulls last
    limit 250
  ),
  cand as materialized (
    ( select m.id from "MEDICINE" m
      where public._norm_name(m.product_name) like '%'||v_clean||'%'
        and (v_all or lower(m.therapeutic_class) = lower(category_filter)) limit 300 )
    union
    ( select m.id from "MEDICINE" m
      where public._norm_name(m.product_name) like v_pref||'%'
        and (v_all or lower(m.therapeutic_class) = lower(category_filter)) limit 1000 )
    union
    ( select ci.id from co_ids ci )
  ),
  scored as materialized (
    select m.id, m.product_name, m.salt_composition, m.marketer, m.therapeutic_class,
           m.image_url_1, m.pack_qty, m.pack_size, m.pack_type, m.mrp, m.gst_percent,
           m.status, m.rx_required, m.sales_count, m.has_scheme, m.has_image, m.buyable,
           m.supplier_count, m.marketer_canonical,
           case when public.get_my_role() in ('admin','super_admin')
                then coalesce(m.supplier_label,'') else '' end as supplier_label,
           public._norm_name(m.product_name) as prod_clean,
           (ci.id is not null) as is_co
    from "MEDICINE" m
    join cand c on c.id = m.id
    left join co_ids ci on ci.id = m.id
  ),
  scored2 as materialized (
    select s.*,
           regexp_split_to_array(s.prod_clean,' ') as prod_toks,
           replace(s.prod_clean,' ','')            as prod_compact,
           length(replace(s.prod_clean,' ',''))    as pc_len,
           split_part(s.prod_clean,' ',1)          as prod_first,
           similarity(s.prod_clean, v_clean)       as sim_full
    from scored s
  ),
  tokcum as materialized (
    select s.id,
           sum(length(t.tok)) over (partition by s.id order by t.ord
                                    rows between unbounded preceding and current row) as cumlen
    from scored2 s
    cross join lateral unnest(s.prod_toks) with ordinality as t(tok, ord)
    where v_cl >= 4 and s.prod_compact like v_compact || '%'
  ),
  tokmatch as materialized (
    select distinct tc.id from tokcum tc where tc.cumlen = v_cl
  ),
  ranked as (
    select s.*,
      greatest(
        (case
           when s.prod_clean = v_clean then 100
           when s.prod_clean like v_clean || '%' then 97
           when v_cl >= 4 and s.id in (select tm.id from tokmatch tm) then 96
           when v_cl >= 4 and s.prod_compact like v_compact || '%'
                and ( s.pc_len = v_cl or right(v_compact,1) !~ '[a-z]'
                      or substr(s.prod_compact, v_cl + 1, 1) !~ '[a-z]' ) then 95
           when v_cl >= 5 and s.prod_compact ~ ('(^|[^a-z])' || v_compact || '([^a-z]|$)') then 88
           when s.prod_first = v_brand then 85
           when levenshtein(v_brand, s.prod_first) <= 1 then 72
           when levenshtein(v_brand, s.prod_first) <= 2 then 60
           when v_brand_dm = dmetaphone(s.prod_first) then 55
           else 0 end),
        (case when s.is_co then v_co_tier else 0 end)
      ) as tier
    from scored2 s
  ),
  -- #451: sellability is a set-based JOIN against the 6-row policy table, so
  -- 563k rows are never probed once per candidate.
  finalr as (
    select r.*,
           (case when r.tier = 0 and r.sim_full >= 0.45 then 50 else r.tier end) as tier_final,
           coalesce(p.sellable, true) as sellable
    from ranked r
    left join public.medicine_status_policy p
           on p.status_key = public._med_status_key(r.status)
  ),
  -- CHANGE #678: for an approved customer the "has a supplier" rank is their
  -- ZONE's standby, so what is available to them sorts first. Anon keeps the
  -- catalogue count. Evaluated only for rows that survive the tier cut.
  kept as (
    select f.*,
           (case when not f.sellable then 2
                 when (case when v_zone is null then coalesce(f.supplier_count, 0)
                            else public.medicine_zone_standby(f.id, v_zone) end) < 1 then 1
                 else 0 end) as sell_rank
    from finalr f where f.tier_final >= 50
  ),
  -- #451: one row per (normalised name, marketer). The identical 'Dolo-T
  -- Tablet [NOT FOR SALE]' pair collapses to its best-ranked member.
  deduped as (
    select k.*, row_number() over (
             partition by k.prod_clean, coalesce(k.marketer_canonical, k.marketer, '')
             order by k.sell_rank asc, k.tier_final desc, k.buyable desc,
                      k.sales_count desc nulls last, k.has_image desc, k.id asc) as dup_rn
    from kept k
  )
  select f.id, f.product_name, f.salt_composition, f.marketer, f.therapeutic_class,
         f.image_url_1,
         coalesce(nullif(btrim(f.pack_type),''), nullif(btrim(f.pack_size),'')) as pack_qty,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_size,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_type,
         f.mrp, f.gst_percent,
         f.status, f.rx_required, f.sales_count, f.has_scheme, f.has_image, f.buyable,
         f.supplier_count, f.supplier_label
  from deduped f
  where f.dup_rn = 1
  order by f.sell_rank asc, f.tier_final desc, f.buyable desc,
           f.sales_count desc nulls last, f.sim_full desc, length(f.product_name) asc
  limit page_limit offset page_offset;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. RG BEHAVIOURS — the guard is red, not just noisy
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c678_avail_count_no_drop', $rgb$
do $rg$
declare v_alert record; v_bad int; v_mis record;
begin
  -- 1. a refused >20% drop in the last 24h is a live incident, not history
  select fingerprint, detail into v_alert from rg_alerts
   where fingerprint in ('c678_sf_drop','c678_count_cache_drop')
     and last_seen > now() - interval '24 hours'
   order by last_seen desc limit 1;
  if v_alert.fingerprint is not null then
    raise exception 'RG_FAIL: an availability count refresh refused a >20%% drop within 24h: % %', v_alert.fingerprint, v_alert.detail;
  end if;
  -- 2. a PUBLISHED number that fell >20% between consecutive refreshes is the collapse itself
  select count(*) into v_bad from (
    select zone_id, cnt, lag(cnt) over (partition by zone_id order by at) as prev
      from sf_avail_counts_hist where accepted and at > now() - interval '7 days') h
   where prev is not null and prev > 100 and cnt < prev * 0.8;
  if v_bad > 0 then
    raise exception 'RG_FAIL: a published available count fell >20%% between refreshes (% zone snapshots)', v_bad;
  end if;
  -- 3. the hero number and the category total are the same scan; they must agree
  select a.zone_id, a.cnt, c.n into v_mis
    from sf_avail_counts a
    join sf_category_counts_z c on c.zone_id = a.zone_id and c.name = 'All'
    join zones z on z.id = a.zone_id and z.is_active and not coalesce(z.is_synthetic,false)
   where a.cnt <> c.n limit 1;
  if v_mis.zone_id is not null then
    raise exception 'RG_FAIL: zone % hero count % disagrees with its category total %', v_mis.zone_id, v_mis.cnt, v_mis.n;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$rgb$, true,
 'CHANGE #678 — the >20% drop rule: a refused drop (rg_alert within 24h), a published drop between consecutive snapshots, or a hero/category-total mismatch turns rg red. Never republish a number from a partial master list.'),
('c678_zone_cursor_guard', $rgb$
do $rg$
declare v_refused boolean := false; v_zone smallint;
begin
  -- the zone with the furthest cursor: a reset there is a real decrease
  select zone_id into v_zone from zone_sync_state where last_id > 0 order by last_id desc limit 1;
  if v_zone is null then raise exception 'RG_ROLLBACK'; end if;
  begin
    update zone_sync_state set last_id = 0 where zone_id = v_zone;
  exception when check_violation then v_refused := true;
  end;
  if not v_refused then
    raise exception 'RG_FAIL: a bare zone_sync_state cursor reset was NOT refused — the availability collapse of 2 Sep 2026 is possible again';
  end if;
  begin
    delete from zone_sync_state where zone_id = v_zone;
  exception when check_violation then v_refused := true;
  end;
  raise exception 'RG_ROLLBACK';
end $rg$;
$rgb$, true,
 'CHANGE #678 — the master-list cursor cannot be reset or deleted outside zone_full_rebuild(): a migration replay, a restore or a stray UPDATE fails loudly instead of wiping availability for hours.'),
('c678_anon_sees_everything_available', $rgb$
do $rg$
declare v_pid bigint; v_av jsonb;
begin
  -- a sellable product with NO supplier anywhere
  select id into v_pid from "MEDICINE"
   where coalesce(supplier_count,0) = 0 and coalesce(status,'') = 'Available'
   order by id limit 1;
  if v_pid is null then raise exception 'RG_ROLLBACK'; end if;
  perform set_config('request.jwt.claims','', true);
  v_av := public.product_detail(v_pid)->'availability';
  if not coalesce((v_av->>'is_available')::boolean, false) or not coalesce((v_av->>'can_add')::boolean, false) then
    raise exception 'RG_FAIL: anon must see every sellable product as available, got %', v_av;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$rgb$, true,
 'CHANGE #678 — anonymous / unregistered / unapproved viewers see the global catalogue with every sellable product available; only an approved customer gets a zone verdict.')
on conflict (name) do update
  set body = excluded.body, enabled = excluded.enabled, note = excluded.note;

update public.rg_behavior_tests
   set note = 'CMD #451 → CHANGE #678: anon sees every sellable product as available (global catalogue, no zone verdict); a non-sellable status blocks everyone; an approved customer sees own-zone standby truth.'
 where name = 'approved_zone_gate';

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. GRANTS — the app calls these as anon / authenticated
-- ─────────────────────────────────────────────────────────────────────────────
grant execute on function public.get_storefront_count(text)                     to anon, authenticated;
grant execute on function public.get_all_storefront_counts()                    to anon, authenticated;
grant execute on function public.medicine_category_counts()                     to anon, authenticated;
grant execute on function public.medicine_catalogue_count()                     to anon, authenticated;
grant execute on function public.get_storefront_feed(text, integer, integer)    to anon, authenticated;
grant execute on function public.storefront_home_v2(integer)                    to anon, authenticated;
grant execute on function public.search_medicines_priority(text, text, integer, integer) to anon, authenticated;
grant execute on function public.storefront_effective_count(bigint, integer)    to anon, authenticated;
grant execute on function public.medicine_zone_standby(bigint, smallint)        to anon, authenticated;
revoke all on function public._sf_feed_ids(text, integer, integer)              from anon, authenticated;
revoke all on function public._sf_category_counts()                             from anon, authenticated;
revoke all on function public._refresh_zone_avail(smallint)                     from anon, authenticated;
revoke all on function public.refresh_zone_availability_counts(smallint)        from anon, authenticated;
revoke all on function public.zone_avail_counts_tick()                          from anon, authenticated;
revoke all on function public.zone_resync_drain(integer)                        from anon, authenticated;
revoke all on function public.zone_sync_by_key(smallint, text, integer)         from anon, authenticated;
revoke all on function public.zone_sup_sync_tick()                              from anon, authenticated;
