-- ─────────────────────────────────────────────────────────────────────────────
-- 522 OUTAGE — THE CUTOVER (third occurrence, 2026-08-18 10:01 UTC)
--
-- This is the command 20260818170000_minute_tick_dispatch.sql was staged for.
-- That file was authored under #229 and deliberately NOT applied, because it
-- unschedules every live per-minute job and a dispatcher bug would take the
-- platform down with it. It has now been rehearsed and is applied here with
-- two defects fixed (tail starvation + no per-step timeout).
--
-- EVIDENCE FOR THIS OCCURRENCE (postgres_logs, project swojhmarmaijkshsbeih)
--   10:01:00.018 .. 10:01:00.105   21 jobs on '* * * * *' start within 87 ms
--   10:01:00.480 .. 10:01:00.974   all 21 complete
--   10:01:24.478                   rg_check() logged duration 13,573 ms
--   10:01:57.802                   LAST postgres log line of any kind
--   10:02:00 onward                postgres_logs = 0 rows/min (was ~40/min)
--   10:16 onward                   supavisor logs connection failures
--   whole window                   PostgREST/auth/admin-SQL = Cloudflare 522
--
-- Same shape as 02:00 UTC (29 min) and 06:13 UTC. Three outages in one day.
--
-- WHY STAGGERING CANNOT FIX IT
--   20260818023000 phase-shifted every '*/N' job off minute 0 and that holds.
--   But a '* * * * *' job fires at second 0 of EVERY minute by definition, so
--   21 of them are a permanent 21-way concurrent burst on a ~1 GB instance with
--   max_connections=60. Frequency, not phase, is the problem.
--
-- THE FIX — one job, one connection.
--   Peak concurrent cron backends at :00 goes 21 -> 1.
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
   instead of cron.schedule(''* * * * *'') — that pattern caused the three
   2026-08-18 outages (02:00, 06:13, 10:01 UTC).';

-- Round-robin cursor. Without it a budget-truncated tick always restarts at
-- ord 1, so the tail of the list would never run again — silent permanent
-- starvation of whichever jobs sort last. (Defect in the staged version.)
create table if not exists public.minute_tick_state (
  id            boolean primary key default true check (id),
  cursor_ord    int         not null default 0,
  cursor_id     bigint      not null default 0,
  last_tick_at  timestamptz,
  last_ran      int,
  last_failed   int,
  last_ms       int
);
insert into public.minute_tick_state (id) values (true) on conflict (id) do nothing;

-- ── SECURITY: these two tables drive a SECURITY DEFINER `execute` ────────────
-- minute_tick_dispatch() runs minute_tick_registry.command verbatim as the
-- table owner. Anything that can write a row to that table therefore has
-- arbitrary SQL execution as the definer. Both tables live in `public`, which
-- PostgREST exposes, and the anon key ships inside the web bundle and the APK
-- (lib/supabase_config.dart) — so without this block any anonymous caller
-- could insert a command and own the database within sixty seconds. RLS with
-- no policy denies anon/authenticated outright; the revokes drop the
-- schema-level grants Supabase hands those roles by default.
-- The dispatcher is unaffected: RLS does not apply to the table owner (no
-- FORCE ROW LEVEL SECURITY), and pg_cron runs it as the job owner.
alter table public.minute_tick_registry enable row level security;
alter table public.minute_tick_state    enable row level security;

revoke all on table    public.minute_tick_registry     from anon, authenticated;
revoke all on table    public.minute_tick_state        from anon, authenticated;
revoke all on sequence public.minute_tick_registry_id_seq from anon, authenticated;

-- Seed from whatever is actually scheduled per-minute right now, so this is
-- correct regardless of which jobs exist when it runs. Never seeds itself.
insert into public.minute_tick_registry (job_name, command, ord)
select j.jobname, j.command, (row_number() over (order by j.jobid))::int
  from cron.job j
 where j.schedule = '* * * * *'
   and j.jobname is distinct from 'minute-tick-dispatch'
   and j.active
on conflict (job_name) do nothing;

-- Defensive: the staged #229 draft declared minute_tick_dispatch(int). If any
-- box ever applied it, leaving both signatures would make the cron call
-- 'minute_tick_dispatch()' ambiguous. Drop the old arity before creating.
drop procedure if exists public.minute_tick_dispatch(int);

-- A PROCEDURE, not a function: each step commits on its own, exactly as it did
-- when it was its own cron job. Wrapping 21 ticks in ONE transaction would hold
-- a single snapshot (and every lock) for the whole minute — cheaper on
-- connections but worse on bloat and lock contention than what we replaced.
create or replace procedure public.minute_tick_dispatch(
  p_budget_ms int default 45000,
  p_step_timeout_ms int default 15000)
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  r        record;
  t0       timestamptz := clock_timestamp();
  t_step   timestamptz;
  ran      int := 0;
  failed   int := 0;
  c_ord    int;
  c_id     bigint;
  last_ord int := 0;
  last_id  bigint := 0;
  done     boolean := true;
begin
  -- Never let two dispatchers overlap: if the previous minute is still running,
  -- this tick does nothing rather than doubling the load it exists to prevent.
  -- Session-scoped (not xact) because we commit between steps; pg_cron gives
  -- each run its own backend, so the lock dies with the run either way.
  if not pg_try_advisory_lock(hashtext('minute_tick_dispatch')) then
    return;
  end if;

  select cursor_ord, cursor_id into c_ord, c_id from public.minute_tick_state where id;
  c_ord := coalesce(c_ord, 0);
  c_id  := coalesce(c_id, 0);

  -- Rows AFTER the cursor first (in ord order), then wrap to the start. Every
  -- enabled row is visited at most once per tick, and a tick cut short by the
  -- budget resumes next minute where it stopped instead of replaying the head.
  for r in
    select id, ord, command
      from public.minute_tick_registry
     where enabled
     order by ((ord, id) > (c_ord, c_id)) desc, ord, id
  loop
    -- Wall-clock budget: stop cleanly instead of bleeding into the next tick.
    if extract(epoch from (clock_timestamp() - t0)) * 1000 > p_budget_ms then
      done := false;
      exit;
    end if;

    t_step := clock_timestamp();
    begin
      -- One hung step must not eat the whole minute's budget and starve the
      -- rest. local => reverts at this step's commit. (Defect in the staged
      -- version: a single slow tick could consume all 45s every minute.)
      perform set_config('statement_timeout', p_step_timeout_ms::text, true);
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

    last_ord := r.ord;
    last_id  := r.id;

    -- Outside the exception block (no subtransaction active), so this is legal
    -- and gives every tick its own transaction boundary.
    commit;
  end loop;

  update public.minute_tick_state
     set cursor_ord   = case when done then 0 else last_ord end,
         cursor_id    = case when done then 0 else last_id  end,
         last_tick_at = now(),
         last_ran     = ran,
         last_failed  = failed,
         last_ms      = (extract(epoch from (clock_timestamp() - t0)) * 1000)::int
   where id;
  commit;

  perform pg_advisory_unlock(hashtext('minute_tick_dispatch'));
  raise notice 'minute_tick_dispatch: ran=% failed=% ms=%',
    ran, failed, (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
end;
$$;

revoke all on procedure public.minute_tick_dispatch(int, int) from public, anon, authenticated;

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

-- ── GUARD: stop this outage pattern from coming back ─────────────────────────
-- The collapse above is only durable if nothing re-introduces a second
-- '* * * * *' job. Three outages in one day (02:00, 06:13, 10:01 UTC) all came
-- from that one habit, and a comment asking people not to do it is not a
-- control. This refuses the schedule at the source and names the alternative.
--
-- Deliberately LAST in the file, and wrapped: cron.job is owned by the pg_cron
-- superuser and this project may not be permitted to attach a trigger to it.
-- A guard that cannot be installed must not abort the outage fix, so failure
-- downgrades to a warning and the collapse still lands.
create or replace function public.minute_tick_guard()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $$
begin
  if new.schedule = '* * * * *'
     and new.jobname is distinct from 'minute-tick-dispatch' then
    raise exception using
      errcode = 'check_violation',
      message = format('refusing to schedule %L on ''* * * * *''', new.jobname),
      hint    = 'Per-minute work belongs in public.minute_tick_registry, which '
                'minute-tick-dispatch runs sequentially on ONE connection. '
                'Individual per-minute jobs caused the 2026-08-18 outages.';
  end if;
  return new;
end $$;

do $$
begin
  drop trigger if exists minute_tick_guard_trg on cron.job;
  create trigger minute_tick_guard_trg
    before insert or update on cron.job
    for each row execute function public.minute_tick_guard();
  raise notice 'minute_tick_guard installed on cron.job';
exception when others then
  raise warning 'minute_tick_guard NOT installed (%) — the per-minute collapse '
                'is still applied; re-add the guard as a superuser.', sqlerrm;
end $$;
