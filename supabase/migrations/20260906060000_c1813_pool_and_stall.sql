-- CHANGE / CMD #1813 — the shared ~14s stall.
--
-- Measured on production (swojhmarmaijkshsbeih) 2026-09-06 04:24 UTC, read-only:
--   max_connections 60, 41 in use, 29 idle.
--   authenticator (PostgREST 14.5) held 21 IDLE backends, the oldest idle for
--   25,987 s = 7.2 hours. Each idle backend is a full Postgres process, so on a
--   1 GB Micro that pool was holding roughly a sixth of the box's RAM doing
--   nothing — RAM that is page cache everywhere else.
--   Database is 7,257 MB, shared_buffers 256 MB, cache hit 93.25 %,
--   21,323,533 blocks (166 GB) read from disk, 2,046 MB spilled to temp files.
--
-- This migration does the part that is ours to fix: it bounds the app's
-- connection pool, evicts idle backends instead of parking them for hours, and
-- makes a pool wait fail fast rather than hang until the app's own ~15 s
-- timeout. It is deliberately idempotent — ALTER ROLE ... SET is last-write-wins
-- and the cron_task updates are guarded — because the merge worker replays this
-- file on live.
--
-- What it does NOT claim: it does not make a 7.2 GB database fit in 1 GB of
-- RAM. See the verdict recorded on #1813.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    raise notice 'c1813: no authenticator role here — skipping PostgREST pool config';
    return;
  end if;

  -- PostgREST in-database configuration (Supabase reads pgrst.* off the
  -- authenticator role and these take precedence over the shipped config).
  --
  -- db_pool 12: the box has 2 shared cores. More pooled connections than that
  -- buys queueing, not throughput, and every extra one is resident memory.
  execute $q$alter role authenticator set pgrst.db_pool = '12'$q$;

  -- Fail fast. A request that cannot get a connection in 8 s must return, not
  -- sit until the app's ~15 s timeout paints a blank screen.
  execute $q$alter role authenticator set pgrst.db_pool_acquisition_timeout = '8'$q$;

  -- The actual fix for the 7.2-hour idlers: hand a connection back to the OS
  -- after a minute of doing nothing, and never keep one longer than 30 minutes.
  execute $q$alter role authenticator set pgrst.db_pool_max_idletime = '60'$q$;
  execute $q$alter role authenticator set pgrst.db_pool_max_lifetime = '1800'$q$;

  -- Postgres-side backstops, so this holds even if PostgREST ignores the
  -- in-database pool settings.
  execute $q$alter role authenticator set idle_in_transaction_session_timeout = '15s'$q$;
  execute $q$alter role authenticator set idle_session_timeout = '900s'$q$;

  -- A CONNECTION LIMIT on authenticator would be the hard ceiling, but supautils
  -- reserves that role: "only superusers can modify it" (proven on the build
  -- branch before this file shipped). The reservation therefore comes from the
  -- pool bounds above — 12 pooled connections that are handed back after a
  -- minute idle — which leaves the other ~48 of 60 slots for realtime, cron,
  -- storage, the pooler and admin instead of the 21 the app was parking.

  -- The two roles PostgREST assumes per request.
  execute $q$alter role authenticated set idle_in_transaction_session_timeout = '10s'$q$;
  execute $q$alter role anon set idle_in_transaction_session_timeout = '5s'$q$;
end$$;

-- Tell a running PostgREST to pick the above up without a restart.
do $$
begin
  perform pg_notify('pgrst', 'reload config');
exception when others then
  raise notice 'c1813: pgrst reload notify skipped: %', sqlerrm;
end$$;

-- ---------------------------------------------------------------------------
-- The other half of the shared stall: heavy periodic scans in front of
-- customers. Measured last_ms on production —
--   rg_after_deploy            50,855 ms, every 1,800 s, all day
--   catalogue_cache_refresh    13,304 ms, every   240 s, all day (1,045 runs)
-- A 50 s scan that reads 213,965 blocks and spills 40,032 temp blocks empties
-- the 256 MB buffer cache and saturates the Micro's disk budget; every app RPC
-- in that window waits together, which is the ~13.9 s signature. Same work,
-- a third of the duty cycle.
do $$
begin
  if to_regclass('public.cron_task') is null then
    raise notice 'c1813: no cron_task here — skipping duty-cycle relief';
    return;
  end if;

  update public.cron_task
     set base_interval_s    = 5400,
         current_interval_s = greatest(coalesce(current_interval_s, 0), 5400)
   where name = 'rg_after_deploy'
     and coalesce(base_interval_s, 0) < 5400;

  update public.cron_task
     set base_interval_s    = 900,
         current_interval_s = greatest(coalesce(current_interval_s, 0), 900)
   where name = 'catalogue_cache_refresh'
     and coalesce(base_interval_s, 0) < 900;
end$$;

-- ---------------------------------------------------------------------------
-- Role settings are read when a session STARTS, so the pool that is already
-- parked keeps the old behaviour: on the branch, two authenticator backends
-- were still sitting at 22,018 s idle after the reload. Reclaim them once here,
-- and keep reclaiming them forever with a task on the existing dispatcher, so
-- this cannot silently regress if PostgREST ever ignores db_pool_max_idletime.
-- Only `idle` backends are touched — never `idle in transaction`, never
-- `active` — so no in-flight request is interrupted; PostgREST reopens on
-- demand in a few milliseconds.
create or replace function public.pgrst_idle_reap(p_idle_s integer default 600)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $fn$
declare
  v_killed int := 0;
begin
  select count(*) into v_killed from (
    select pg_terminate_backend(pid)
      from pg_stat_activity
     where usename = 'authenticator'
       and state = 'idle'
       and backend_type = 'client backend'
       and state_change < now() - make_interval(secs => greatest(p_idle_s, 60))
  ) t;
  return jsonb_build_object('ok', true, 'killed', v_killed, 'idle_s', greatest(p_idle_s, 60));
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end
$fn$;

revoke all on function public.pgrst_idle_reap(integer) from public, anon, authenticated;

select public.pgrst_idle_reap(600);

do $$
begin
  if to_regclass('public.cron_task') is null then
    raise notice 'c1813: no cron_task here — reaper stays manual';
    return;
  end if;

  insert into public.cron_task (name, ord, mode, work_sql, step_timeout_ms,
                                enabled, base_interval_s, max_interval_s, dml, note)
  values ('pgrst_idle_reaper', 915, 'poll',
          'select public.pgrst_idle_reap(600)', 5000,
          true, 300, 300, false,
          'CMD #1813 — hands back authenticator backends idle over 10 min. '
          'They were parking for 7+ hours and holding a sixth of a 1 GB box.')
  on conflict (name) do update
     set work_sql        = excluded.work_sql,
         enabled         = true,
         base_interval_s = excluded.base_interval_s,
         max_interval_s  = excluded.max_interval_s,
         step_timeout_ms = excluded.step_timeout_ms,
         note            = excluded.note;
end$$;
