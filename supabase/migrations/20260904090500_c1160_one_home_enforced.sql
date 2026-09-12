-- CHANGE #1160 — the regression guard went red on the scheduled run after
-- #1096: c1016_one_home_per_feature raised
--   "two tiles share one route_key: runbooks (admin.runbooks+devtool.runbooks)"
-- #474 registered admin.runbooks beside the devtool.runbooks row that already
-- owned /admin/go/runbooks, and its own later revision deleted the duplicate,
-- so the guard was red 07:35-07:37 UTC and green from 07:38 (verified: 08:15
-- run green, 0 diffs, and the registry now holds exactly one 'runbooks' row).
--
-- The diff was real and it is already gone. What this change fixes is the
-- CLASS: nothing stopped a migration writing a second active tile on a route
-- that was already owned, so the collision only became visible one cron run
-- later, in production, as a red guard on someone else's watch. #1016 made
-- "one home per feature" the law; this makes the WRITE refuse to break it,
-- with the same sentence the guard would have printed an hour later.
--
--   * route_key  — one active staff tile per route  (dashboard/both/dev_tools)
--   * deep_link  — one active staff tile per link   (+ fulfill_tab, as the rule)
--   * home       — a staff tile whose category has no home_tab is not refused
--                  (that would break a migration that inserts its category
--                  afterwards); it is HOMED, into the More grid's catch-all,
--                  exactly as #1016 homed the legacy categories. A late
--                  registration is never a tile with no home.
--
-- Idempotent: create or replace, drop trigger if exists, create index if not
-- exists. Applying it twice is a no-op.

create or replace function public._feature_registry_home_guard()
returns trigger
language plpgsql
as $fn$
declare
  v_staff   constant text[] := array['dashboard','both','dev_tools'];
  v_linked  constant text[] := array['dashboard','both','dev_tools','fulfill_tab'];
  v_owner   text;
  v_home    text;
begin
  -- An alias, a retired row or a non-staff surface is none of this trigger's
  -- business: the dedupe model (#1016) parks merged rows on surface 'alias'.
  if not coalesce(new.is_active, false) then return new; end if;

  if new.surface = any (v_staff) and coalesce(new.route_key,'') <> '' then
    select f.feature_key into v_owner
      from public.feature_registry f
     where f.is_active and f.surface = any (v_staff)
       and f.route_key = new.route_key
       and f.feature_key <> new.feature_key
     limit 1;
    if v_owner is not null then
      raise exception
        'RG_FAIL: two tiles share one route_key: % (%+%). One home per feature (#1016) — alias the loser (surface=''alias'', merged_into=''%'') instead of registering a second tile.',
        new.route_key, v_owner, new.feature_key, v_owner;
    end if;
  end if;

  if new.surface = any (v_linked) and coalesce(new.deep_link,'') <> '' then
    select f.feature_key into v_owner
      from public.feature_registry f
     where f.is_active and f.surface = any (v_linked)
       and f.deep_link = new.deep_link
       and f.feature_key <> new.feature_key
     limit 1;
    if v_owner is not null then
      raise exception
        'RG_FAIL: two tiles share one deep_link: % (%+%). One home per feature (#1016) — alias the loser instead of registering a second tile.',
        new.deep_link, v_owner, new.feature_key;
    end if;
  end if;

  -- Homeless staff tile: home it rather than refuse it.
  if new.surface = any (array['dashboard','both','dev_tools','fulfill_tab',
                              'customer_tab','supplier_tab'])
     and coalesce(new.route_key,'') <> '' then
    select c.home_tab into v_home
      from public.nav_category c
     where c.category_key = new.category and c.is_active;
    if v_home is null then
      new.category := 'more_system';
      raise notice
        'CHANGE #1160: % registered under a category with no home tab — homed into the More grid (more_system) so it is never a tile nobody can reach.',
        new.feature_key;
    end if;
  end if;

  return new;
end $fn$;

drop trigger if exists trg_feature_registry_home_guard on public.feature_registry;
create trigger trg_feature_registry_home_guard
  before insert or update on public.feature_registry
  for each row execute function public._feature_registry_home_guard();

-- The backstop the trigger cannot be talked out of (a disabled trigger, a
-- concurrent insert). Partial, so aliases and retired rows are unaffected.
create unique index if not exists feature_registry_one_tile_per_route
  on public.feature_registry (route_key)
  where is_active and surface in ('dashboard','both','dev_tools')
    and coalesce(route_key,'') <> '';

create unique index if not exists feature_registry_one_tile_per_link
  on public.feature_registry (deep_link)
  where is_active and surface in ('dashboard','both','dev_tools','fulfill_tab')
    and coalesce(deep_link,'') <> '';
