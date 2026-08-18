-- ─────────────────────────────────────────────────────────────────────────────
-- STATUS: STAGED, NOT APPLIED.  Authored during CHANGE #229 in response to the
-- 06:13 UTC outage, but deliberately NOT applied under #229: order closure
-- needs nothing from it (the closure tick is already offset at '16-59/10'),
-- while this migration unschedules 15 LIVE per-minute jobs — including
-- dev-auto-heal and the inquiry engine — so a dispatcher bug would take down
-- the platform and the runner with it.  It is committed here so the outage
-- analysis and the fix are not lost, and belongs to its own command where the
-- dispatcher can be rehearsed against all 15 jobs before the cutover.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 522 OUTAGE FIX (2026-08-18 06:13 UTC) — collapse the per-minute cron fan-out
-- into ONE dispatcher connection.
--
-- WHAT HAPPENED
--   06:13:00–06:13:05  21 pg_cron jobs on '* * * * *' started within 1.1s of
--                      each other and all completed by :05.
--   06:13:20           last postgres log line.
--   06:13:32+          postgres stops accepting TCP entirely; supavisor logs
--                      "Connection failed {:error, :timeout}" to :5432, and
--                      Cloudflare serves 522 for every REST/auth call.
--   edge_logs origin time went 142ms (06:12) → 8.6s (06:13) → 117s (06:14).
--
--   The 2026-08-18 02:30 stagger fix (20260818023000) phase-shifted every
--   '*/N' job off minute 0 — correct, and those are still spread. But it could
--   not help '* * * * *' jobs: a per-minute schedule fires at second 0 of EVERY
--   minute by definition, so 21 of them are a permanent, unavoidable 21-way
--   concurrent burst on a ~1 GB instance. Staggering cannot fix frequency.
--
-- THE FIX
--   One job, one connection: 'minute-tick-dispatch' runs the same work
--   sequentially inside a single backend, guarded by an advisory lock (no
--   overlap) and a wall-clock budget (never runs into the next minute). Each
--   step is exception-isolated, so one failing tick cannot sink the rest — the
--   behaviour pg_cron gave us for free with separate jobs.
--
--   Peak concurrent cron backends at :00 goes 21 → 1.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.minute_tick_registry (
  id          bigserial primary key,
  job_name    text        not null unique,
  command     text        not null,
  ord         int         not null default 100,
  enabled     boolean     not null default true,
  last_run_at timestamptz,
  last_ms     int,
  last_error  text,
  fail_count  int         not null default 0,
  created_at  timestamptz not null default now()
);

comment on table public.minute_tick_registry is
  'Every job that used to hold its own ''* * * * *'' pg_cron slot. Rows are run
   sequentially by minute_tick_dispatch() in ONE connection. Add work here
   instead of cron.schedule(''* * * * *'') — that pattern caused the 2026-08-18
   06:13 UTC outage.';

-- Seed from whatever is actually scheduled per-minute right now, so this is
-- correct regardless of which jobs exist when it runs. Never seeds itself.
insert into public.minute_tick_registry (job_name, command, ord)
select j.jobname, j.command, (row_number() over (order by j.jobid))::int
  from cron.job j
 where j.schedule = '* * * * *'
   and j.jobname is distinct from 'minute-tick-dispatch'
   and j.active
on conflict (job_name) do nothing;

-- A PROCEDURE, not a function: each step commits on its own, exactly as it did
-- when it was its own cron job. Wrapping 21 ticks in ONE transaction would hold
-- a single snapshot (and every lock) for the whole minute — cheaper on
-- connections but worse on bloat and lock contention than what we replaced.
create or replace procedure public.minute_tick_dispatch(p_budget_ms int default 45000)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  r       record;
  t0      timestamptz := clock_timestamp();
  t_step  timestamptz;
  ran     int := 0;
  failed  int := 0;
begin
  -- Never let two dispatchers overlap: if the previous minute is still running,
  -- this tick does nothing rather than doubling the load it exists to prevent.
  -- Session-scoped (not xact) because we commit between steps; pg_cron gives
  -- each run its own backend, so the lock dies with the run either way.
  if not pg_try_advisory_lock(hashtext('minute_tick_dispatch')) then
    return;
  end if;

  for r in
    select id, command from public.minute_tick_registry
     where enabled order by ord, id
  loop
    -- Wall-clock budget: stop cleanly instead of bleeding into the next tick.
    exit when extract(epoch from (clock_timestamp() - t0)) * 1000 > p_budget_ms;

    t_step := clock_timestamp();
    begin
      execute r.command;
      update public.minute_tick_registry
         set last_run_at = now(),
             last_ms     = (extract(epoch from (clock_timestamp() - t_step)) * 1000)::int,
             last_error  = null,
             fail_count  = 0
       where id = r.id;
      ran := ran + 1;
    exception when others then
      -- Isolated exactly as a separate cron job would be: one bad tick must
      -- never stop the other twenty.
      failed := failed + 1;
      update public.minute_tick_registry
         set last_run_at = now(),
             last_ms     = (extract(epoch from (clock_timestamp() - t_step)) * 1000)::int,
             last_error  = left(sqlerrm, 500),
             fail_count  = fail_count + 1
       where id = r.id;
    end;

    -- Outside the exception block (no subtransaction active), so this is legal
    -- and gives every tick its own transaction boundary.
    commit;
  end loop;

  perform pg_advisory_unlock(hashtext('minute_tick_dispatch'));
  raise notice 'minute_tick_dispatch: ran=% failed=% ms=%',
    ran, failed, (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
end;
$$;

revoke all on procedure public.minute_tick_dispatch(int) from public, anon, authenticated;

-- Retire the individual per-minute jobs, then schedule the single dispatcher.
do $$
declare j record;
begin
  for j in
    select jobname from cron.job
     where schedule = '* * * * *'
       and jobname is distinct from 'minute-tick-dispatch'
  loop
    perform cron.unschedule(j.jobname);
  end loop;
end $$;

select cron.schedule('minute-tick-dispatch', '* * * * *',
                     $$call public.minute_tick_dispatch()$$);
