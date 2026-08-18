-- ─────────────────────────────────────────────────────────────────────────────
-- KILL THE PER-MINUTE CRON STORM — event-driven work, one dispatcher (#273)
--
-- WHY (measured, project swojhmarmaijkshsbeih, 2026-08-18)
--   Three 520/522 outages in one day: 02:00 UTC (29 min), 06:13 UTC, and
--   10:01 UTC — the last one held Postgres silent for over two hours
--   (postgres_logs = 0 rows/min from 10:02; cron.job_run_details records 54
--   runs in the 10:00 hour and ZERO in the 11:00 hour, against ~1,140/hour
--   normal). The 02:30 stagger migration phase-shifted every '*/N' job off
--   minute 0 and that holds — but a '* * * * *' job fires at second 0 of EVERY
--   minute by definition, so 15 of them are a permanent 15-way concurrent
--   burst on a t3a.micro with max_connections = 60. Frequency, not phase.
--
--   Clean-hour baseline (08:00-09:00 UTC, before this migration):
--     active cron jobs ........... 65   (15 on '* * * * *')
--     cron runs / hour .......... 1164   (900 = 77% from the per-minute jobs)
--     cron DB-seconds / hour .... 210.7  (89.0 from the per-minute jobs)
--     peak concurrent cron ........ 19   backends, against 60 total slots
--   Nobody uses the app yet. Every one of those 900 runs found nothing to do.
--
-- WHAT THIS DOES
--   1. Deletes the per-minute cron slot for all 15 jobs.
--   2. Work that a real event creates is fired BY that event (triggers write a
--      cron_signal row) instead of being hunted for once a minute.
--   3. Everything time-bound (a 10-minute inquiry timeout, an auto-open time)
--      runs inside ONE dispatcher, sequentially, in ONE connection, and every
--      task starts with a cheap existence gate that returns immediately when
--      there is nothing to do.
--   4. A guard refuses any NEW per-minute job and auto-repairs one that slips
--      in; a semaphore caps how much cron work may run at once.
--
-- SUPERSEDES supabase/migrations/20260818103000_minute_tick_cutover.sql, which
-- was authored under #229 and never applied (public.minute_tick_registry does
-- not exist on the live database). This file is the applied fix. It keeps that
-- draft's two hard-won defences — a round-robin cursor so a budget-truncated
-- tick cannot starve the tail, and a per-step statement_timeout so one hung
-- task cannot eat the whole budget — and drops its riskiest property: nothing
-- here is a SECURITY DEFINER that executes caller-supplied SQL.
--
-- Idempotent end to end: safe to re-apply after a runner restart.
-- ─────────────────────────────────────────────────────────────────────────────

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE TASK REGISTRY
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.cron_task (
  name            text        primary key,
  ord             int         not null default 100,
  mode            text        not null default 'poll'
                              check (mode in ('poll','event')),
  -- A cheap boolean. NULL = this task ONLY ever runs on a signal.
  gate_sql        text,
  work_sql        text        not null,
  step_timeout_ms int         not null default 20000,
  enabled         boolean     not null default true,
  note            text,
  -- observability
  last_checked_at timestamptz,
  last_run_at     timestamptz,
  last_ms         int,
  last_error      text,
  runs            bigint      not null default 0,
  skips           bigint      not null default 0,
  fail_count      int         not null default 0,
  created_at      timestamptz not null default now()
);

comment on table public.cron_task is
  'Every job that used to hold its own ''* * * * *'' pg_cron slot. Rows are run
   sequentially by cron_dispatch() in ONE connection, each behind its own cheap
   gate_sql. Add work here — never with cron.schedule(''* * * * *''), which
   caused the three 2026-08-18 outages (02:00, 06:13, 10:01 UTC).';

-- Round-robin cursor. Without it a budget-truncated tick always restarts at
-- ord 1, so whichever tasks sort last would silently never run again.
create table if not exists public.cron_dispatch_state (
  id            boolean primary key default true check (id),
  cursor_name   text,
  last_tick_at  timestamptz,
  last_ran      int not null default 0,
  last_skipped  int not null default 0,
  last_failed   int not null default 0,
  last_ms       int not null default 0,
  ticks         bigint not null default 0
);
insert into public.cron_dispatch_state (id) values (true) on conflict (id) do nothing;

-- The event side: a trigger writes one tiny row here; the dispatcher drains it.
create table if not exists public.cron_signal (
  task          text primary key references public.cron_task(name) on delete cascade,
  first_at      timestamptz not null default now(),
  last_at       timestamptz not null default now(),
  n             bigint      not null default 1
);

comment on table public.cron_signal is
  'Work announced by the event that created it. A trigger calls cron_wake();
   the next dispatcher tick runs the task and clears the row. This is what
   replaces polling for orphan cleanup, dev-command auto-heal/resolve, supplier
   matching and route-plan builds.';

create table if not exists public.cron_guard_config (
  id              boolean primary key default true check (id),
  max_concurrent  int     not null default 6,
  dispatcher_job  text    not null default 'cron-dispatch',
  enforce         boolean not null default true,
  tick_budget_ms  int     not null default 25000
);
insert into public.cron_guard_config (id) values (true) on conflict (id) do nothing;

create table if not exists public.cron_guard_event (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  kind       text not null,          -- 'refused' | 'repaired' | 'semaphore_skip'
  job_name   text,
  detail     text
);
create index if not exists cron_guard_event_at_idx on public.cron_guard_event (at desc);

-- ── SECURITY ────────────────────────────────────────────────────────────────
-- cron_task.work_sql is executed verbatim by cron_dispatch(). Anything that
-- can write a row to cron_task therefore controls what the dispatcher runs.
-- These tables live in `public`, which PostgREST exposes, and the anon key
-- ships inside the web bundle and the APK — so they are closed to anon and
-- authenticated outright. RLS with no policy denies; the revokes drop the
-- schema-level grants Supabase hands those roles by default.
-- (cron_dispatch() itself is SECURITY INVOKER, so even a leaked call site
-- executes with the caller's own — anon's — privileges, not the owner's.)
alter table public.cron_task           enable row level security;
alter table public.cron_dispatch_state enable row level security;
alter table public.cron_signal         enable row level security;
alter table public.cron_guard_config   enable row level security;
alter table public.cron_guard_event    enable row level security;

revoke all on table public.cron_task           from anon, authenticated;
revoke all on table public.cron_dispatch_state from anon, authenticated;
revoke all on table public.cron_signal         from anon, authenticated;
revoke all on table public.cron_guard_config   from anon, authenticated;
revoke all on table public.cron_guard_event    from anon, authenticated;
revoke all on sequence public.cron_guard_event_id_seq from anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. cron_wake() — the door an event uses to announce work
-- ═══════════════════════════════════════════════════════════════════════════
-- SECURITY DEFINER because the triggers that call it fire inside an ordinary
-- customer/admin transaction, and those roles must not (and do not) hold write
-- access to cron_signal. The only argument is a task NAME, validated against
-- cron_task — there is no SQL surface here.
create or replace function public.cron_wake(p_task text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into public.cron_signal (task) values (p_task)
  on conflict (task) do update set last_at = now(), n = cron_signal.n + 1;
exception
  when foreign_key_violation then
    -- unknown task name: never break the user's transaction over bookkeeping
    return;
end $$;

revoke all on function public.cron_wake(text) from public;
grant execute on function public.cron_wake(text) to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. cron_run() — the concurrency cap
-- ═══════════════════════════════════════════════════════════════════════════
-- pg_cron's own cap, cron.max_running_jobs, is 32 (more than half of
-- max_connections = 60) and is postmaster-context: changing it needs a restart
-- of the production database. This is the same cap enforced in userspace, live,
-- reversible, and with no downtime: a job that cannot take one of N advisory
-- slots returns immediately instead of piling onto a database that is already
-- saturated. SECURITY INVOKER by design — pg_cron runs jobs as postgres, so no
-- elevation is needed, and a leaked call site gains the caller nothing.
create or replace function public.cron_run(p_job text, p_sql text)
returns void
language plpgsql
as $$
declare v_slot int; v_max int; v_enforce boolean; v_slot_held int := null;
begin
  select max_concurrent, enforce into v_max, v_enforce
    from public.cron_guard_config where id;

  if coalesce(v_enforce, true) then
    for v_slot in 1..greatest(coalesce(v_max, 6), 1) loop
      if pg_try_advisory_lock(7302, v_slot) then v_slot_held := v_slot; exit; end if;
    end loop;

    if v_slot_held is null then
      insert into public.cron_guard_event (kind, job_name, detail)
      values ('semaphore_skip', p_job,
              format('all %s slots busy — skipped this run rather than queueing another backend', v_max));
      return;
    end if;
  end if;

  begin
    execute p_sql;
  exception when others then
    if v_slot_held is not null then perform pg_advisory_unlock(7302, v_slot_held); end if;
    raise;
  end;

  if v_slot_held is not null then perform pg_advisory_unlock(7302, v_slot_held); end if;
end $$;

revoke all on function public.cron_run(text, text) from public;
grant execute on function public.cron_run(text, text) to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE GUARD — nothing may be scheduled '* * * * *' again
-- ═══════════════════════════════════════════════════════════════════════════
-- cron.job is owned by supabase_admin, so a BEFORE trigger on it is not
-- available to us. The guard is therefore two layers that ARE:
--   a) cron_add() — the sanctioned door. Raises on a per-minute schedule.
--   b) cron_guard_sweep() — runs on every dispatcher tick. Any job that got in
--      another way and fires every minute is moved to a staggered schedule and
--      logged. Self-healing beats a check nobody runs.
-- rg_check()'s cron baseline is the third layer: a new job turns it red.

create or replace function public.cron_is_per_minute(p_schedule text)
returns boolean
language sql
immutable
as $$
  -- '* * * * *', '*/1 * * * *', '0-59/1 * * * *', '0-59 * * * *' and friends
  select regexp_replace(btrim(coalesce(p_schedule,'')), '\s+', ' ', 'g')
         ~ '^(\*|\*/1|0-59|0-59/1) \* \* \* \*$';
$$;

create or replace function public.cron_add(p_name text, p_schedule text, p_command text)
returns bigint
language plpgsql
as $$
declare v_dispatcher text; v_id bigint;
begin
  select dispatcher_job into v_dispatcher from public.cron_guard_config where id;

  if public.cron_is_per_minute(p_schedule) and p_name is distinct from v_dispatcher then
    -- NB: no guard-event INSERT here. A raise in the same subtransaction rolls
    -- it back, so it would never exist. The refusal IS the exception;
    -- cron_guard_sweep() is the layer that logs (its repairs commit).
    raise exception
      'cron_add: % is per-minute. Fifteen of these took the site down three times on 2026-08-18. Register the work in public.cron_task instead (it runs inside the % dispatcher), or pick an offset schedule such as ''7-59/10 * * * *''.',
      p_schedule, v_dispatcher;
  end if;

  if p_schedule ~ '^\*/[0-9]+ ' then
    raise exception
      'cron_add: %L has a bare */N step, so it collides on minute 0 with every other bare */N job. Use an offset, e.g. ''7-59/10 * * * *''.',
      p_schedule;
  end if;

  select cron.schedule(p_name, p_schedule, p_command) into v_id;
  return v_id;
end $$;

revoke all on function public.cron_add(text, text, text) from public;
grant execute on function public.cron_add(text, text, text) to postgres, service_role;

create or replace function public.cron_guard_sweep()
returns jsonb
language plpgsql
as $$
declare r record; v_dispatcher text; v_fixed int := 0; v_slot int := 0; v_sched text;
begin
  select dispatcher_job into v_dispatcher from public.cron_guard_config where id;

  for r in
    select jobid, jobname, schedule, command from cron.job
     where active and public.cron_is_per_minute(schedule)
       and jobname is distinct from v_dispatcher
  loop
    -- park it on a staggered 10-minute schedule rather than deleting someone's
    -- work outright; the event is logged so the owner can move it to cron_task.
    v_slot := (v_slot + 3) % 10;
    v_sched := format('%s-59/10 * * * *', v_slot);
    perform cron.alter_job(r.jobid, schedule => v_sched);
    insert into public.cron_guard_event (kind, job_name, detail)
    values ('repaired', r.jobname,
            format('was ''%s'' — moved to ''%s''. Register it in public.cron_task instead.', r.schedule, v_sched));
    v_fixed := v_fixed + 1;
  end loop;

  return jsonb_build_object('repaired', v_fixed);
end $$;

revoke all on function public.cron_guard_sweep() from public;
grant execute on function public.cron_guard_sweep() to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. THE DISPATCHER — one job, one connection, sequential, gated
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.cron_dispatch()
returns jsonb
language plpgsql
as $$
declare
  t            record;
  v_started    timestamptz := clock_timestamp();
  v_budget_ms  int;
  v_run        boolean;
  v_signalled  boolean;
  v_t0         timestamptz;
  v_ms         int;
  v_ran        int := 0;
  v_skipped    int := 0;
  v_failed     int := 0;
  v_cursor     text;
  v_last       text := null;
  v_truncated  boolean := false;
begin
  -- Only ever one tick at a time, even if a tick overruns a minute.
  if not pg_try_advisory_lock(7301, 1) then
    return jsonb_build_object('ok', true, 'skipped', 'previous tick still running');
  end if;

  select tick_budget_ms into v_budget_ms from public.cron_guard_config where id;
  v_budget_ms := coalesce(v_budget_ms, 25000);
  select cursor_name into v_cursor from public.cron_dispatch_state where id;

  -- Round-robin: start just after wherever the last tick stopped, then wrap.
  for t in
    select * from public.cron_task where enabled
    order by (case when v_cursor is null or (ord, name) > (
                     select ord, name from public.cron_task where name = v_cursor
                   ) then 0 else 1 end),
             ord, name
  loop
    if extract(epoch from (clock_timestamp() - v_started)) * 1000 > v_budget_ms then
      v_truncated := true;
      exit;
    end if;

    -- (a) did an event announce this work?
    select true into v_signalled from public.cron_signal where task = t.name;
    v_signalled := coalesce(v_signalled, false);

    -- (b) the cheap existence check. This is the whole point: on an idle
    --     database every one of these is an index/one-page probe that returns
    --     false, and no task body runs at all.
    v_run := v_signalled;
    if not v_run and t.gate_sql is not null then
      begin
        execute 'set local statement_timeout = 3000';
        execute t.gate_sql into v_run;
      exception when others then
        v_run := true;   -- a broken gate must never silently disable the work
      end;
      v_run := coalesce(v_run, false);
    end if;

    v_last := t.name;

    if not v_run then
      update public.cron_task
         set last_checked_at = now(), skips = skips + 1
       where name = t.name;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- (c) run it, with its own ceiling so one hung task cannot eat the budget
    v_t0 := clock_timestamp();
    begin
      execute format('set local statement_timeout = %s', t.step_timeout_ms);
      execute t.work_sql;
      v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;
      update public.cron_task
         set last_checked_at = now(), last_run_at = now(), last_ms = v_ms,
             last_error = null, runs = runs + 1, fail_count = 0
       where name = t.name;
      delete from public.cron_signal where task = t.name;
      v_ran := v_ran + 1;
    exception when others then
      v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;
      update public.cron_task
         set last_checked_at = now(), last_run_at = now(), last_ms = v_ms,
             last_error = left(sqlerrm, 500), fail_count = fail_count + 1
       where name = t.name;
      delete from public.cron_signal where task = t.name;
      v_failed := v_failed + 1;
    end;
  end loop;

  execute 'set local statement_timeout = 0';

  -- the guard runs last so a per-minute intruder is repaired within a minute
  begin
    perform public.cron_guard_sweep();
  exception when others then null;
  end;

  update public.cron_dispatch_state
     set cursor_name  = case when v_truncated then v_last else null end,
         last_tick_at = now(),
         last_ran     = v_ran,
         last_skipped = v_skipped,
         last_failed  = v_failed,
         last_ms      = (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int,
         ticks        = ticks + 1
   where id;

  perform pg_advisory_unlock(7301, 1);

  return jsonb_build_object(
    'ok', true, 'ran', v_ran, 'skipped', v_skipped, 'failed', v_failed,
    'truncated', v_truncated,
    'ms', (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int);
exception when others then
  perform pg_advisory_unlock(7301, 1);
  raise;
end $$;

revoke all on function public.cron_dispatch() from public;
grant execute on function public.cron_dispatch() to postgres, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. THE TASKS
-- ═══════════════════════════════════════════════════════════════════════════
-- gate_sql NULL  => signal-only: this work exists only because an event made it.
-- gate_sql set   => time-bound work that no event can announce; the gate is a
--                   one-probe existence check, not the job itself.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms, note) values

-- ── time-bound: genuinely cannot be event-driven (the event is elapsed time) ──
('order_hours', 10, 'poll',
 -- Mirror order_hours_tick()'s OWN predicate. Gating merely on "a zone has an
 -- auto-open time configured" is true all day, so the task ran every minute
 -- anyway - measured before this was tightened.
 $g$select exists (
  select 1 from public.order_hours
   where zone_id is not null
     and ((auto_open_time is not null and not is_open
           and (now() at time zone 'Asia/Kolkata')::time >= auto_open_time
           and coalesce(last_auto_open_on, date '1900-01-01') < (now() at time zone 'Asia/Kolkata')::date
           and (auto_close_time is null or (now() at time zone 'Asia/Kolkata')::time < auto_close_time))
       or (auto_close_time is not null and is_open
           and (now() at time zone 'Asia/Kolkata')::time >= auto_close_time
           and coalesce(last_auto_close_on, date '1900-01-01') < (now() at time zone 'Asia/Kolkata')::date)))$g$,
 $w$select public.order_hours_tick()$w$, 10000,
 'Auto open/close a zone at its configured wall-clock time. No row can announce "it is now 09:00".'),

('inquiry_timeout_advance', 20, 'poll',
 $g$select exists (select 1 from public.inquiry
        where inquiry_phase = 'sent' and current_supplier is not null
          and current_status <> 'Available'
          and asked_at < now() - interval '10 minutes')$g$,
 $w$select public.timeout_advance()$w$, 20000,
 'A supplier NOT answering within 10 minutes is the absence of an event.'),

('inquiry_sweep_timeouts', 30, 'poll',
 $g$select exists (select 1 from public.inquiry
        where current_supplier is not null and asked_at is not null
          and asked_at < now() - interval '10 minutes')
     or exists (select 1 from public.inquiry_forms
        where status not in ('responded','partially_responded')
          and expires_at is not null and expires_at < now())
     or exists (select 1 from public.inquiry_forms f
        where f.status not in ('responded','partially_responded')
          and not exists (select 1 from public.inquiry i
                          where i.current_supplier = f.supplier_name))$g$,
 $w$select public.sweep_inquiry_timeouts()$w$, 30000,
 'Timeout advance + expiring the supplier form. Gate covers all three branches of the body.'),

('inquiry_engine_sync', 40, 'poll',
 $g$select coalesce((select (value #>> '{}')::boolean from public.app_settings
                    where key = 'inquiry_engine_mode'), false)$g$,
 $w$select public.inquiry_engine_sync()$w$, 20000,
 'Reconciles the waterfall against the open supplier. Zero work while the engine is off.'),

('wa_campaign', 50, 'poll',
 $g$select exists (select 1 from public.wa_campaigns
                   where status in ('running','scheduled'))$g$,
 $w$select public.wa_campaign_tick()$w$, 30000,
 'Send-window and drip pacing are clock-bound. Zero work with no live campaign.'),

('bulk_ocr_sweep', 60, 'poll',
 $g$select exists (select 1 from public.bulk_ocr_jobs
                   where status in ('queued','processing'))
     or exists (select 1 from public.bulk_ocr_inputs)$g$,
 $w$select public.bulk_ocr_sweep_stuck()$w$, 20000,
 'Watchdog for a worker that died mid-job — i.e. for an event that never arrived.'),

-- ── event-driven: fired by the thing that creates the work ───────────────────
('orphan_inquiry_cleanup', 110, 'event', null,
 $w$select public.cleanup_orphan_inquiry()$w$, 30000,
 'Orphans exist only because order_items rows were deleted. Trigger cron_signal_order_items_del announces it. Was the most expensive per-minute job: 330 ms avg / 2,041 ms max, forever, finding nothing.'),

('dev_auto_heal', 120, 'event',
 $g$select exists (select 1 from public.dev_commands
        where status = 'failed' and coalesce(rolled_back,false) = false)$g$,
 $w$select public.dev_auto_heal()$w$, 20000,
 'A command turning failed is the event; the trigger signals it. Gate re-arms it for multi-pass retries.'),

('dev_auto_resolve', 130, 'event',
 $g$select exists (select 1 from public.dev_commands where status = 'needs_input')$g$,
 $w$select public.dev_auto_resolve()$w$, 20000,
 'A command asking a question is the event; the trigger signals it.'),

('supplier_match_dispatch', 140, 'event',
 $g$select exists (select 1 from public.supplier_company where match_state = 'pending')$g$,
 $w$select public.dispatch_supplier_matches(4)$w$, 20000,
 'A supplier row entering match_state=pending is the event. Gate re-arms it until the queue drains.'),

('route_plan_drain', 150, 'event',
 $g$select exists (select 1 from public.route_plans where status = 'queued')$g$,
 $w$select public.route_plan_drain()$w$, 95000,
 'An admin queueing a plan is the event. Long ceiling on purpose — the round-robin cursor lets the other tasks resume on the next tick.'),

('lead_scrape_drain', 160, 'event',
 $g$select exists (select 1 from public.lead_scrape_runs where status = 'running')$g$,
 $w$select public.lead_scrape_tick()$w$, 20000,
 'A scrape run going running is the event; the gate keeps draining its batches.'),

('lead_enrich_drain', 170, 'event',
 $g$select exists (select 1 from public.lead_enrich_runs where status = 'running')$g$,
 $w$select public.lead_enrich_tick()$w$, 20000,
 'An enrich run going running is the event; the gate keeps draining its batches.'),

('zone_backfill', 180, 'event',
 $g$select exists (select 1 from public.zones z
        left join public.zone_sync_state s on s.zone_id = z.id
        where z.is_active and not coalesce(s.done,false))$g$,
 $w$select public.zone_backfill_tick()$w$, 60000,
 'A zone being activated is the event; the gate keeps backfilling until done.')

on conflict (name) do update set
  ord = excluded.ord, mode = excluded.mode, gate_sql = excluded.gate_sql,
  work_sql = excluded.work_sql, step_timeout_ms = excluded.step_timeout_ms,
  note = excluded.note;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. THE TRIGGERS — the events announce their own work
-- ═══════════════════════════════════════════════════════════════════════════

-- (a) inquiry orphans are created by deleting order_items (directly, or by
--     cascade from a deleted order). Statement-level: one signal per DELETE,
--     not one per row.
create or replace function public._cron_sig_orphan_inquiry()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public.cron_wake('orphan_inquiry_cleanup'); return null; end $$;

drop trigger if exists cron_signal_order_items_del on public.order_items;
create trigger cron_signal_order_items_del
  after delete on public.order_items
  for each statement execute function public._cron_sig_orphan_inquiry();

-- (b) a dev command failing / asking is the event auto-heal and auto-resolve
--     used to hunt for sixty times an hour.
create or replace function public._cron_sig_dev_command()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status = 'failed' then
    perform public.cron_wake('dev_auto_heal');
  elsif new.status = 'needs_input' then
    perform public.cron_wake('dev_auto_resolve');
  end if;
  return null;
end $$;

drop trigger if exists cron_signal_dev_command on public.dev_commands;
create trigger cron_signal_dev_command
  after insert or update of status on public.dev_commands
  for each row when (new.status in ('failed','needs_input'))
  execute function public._cron_sig_dev_command();

-- (c) a supplier entering the match queue
create or replace function public._cron_sig_supplier_match()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public.cron_wake('supplier_match_dispatch'); return null; end $$;

drop trigger if exists cron_signal_supplier_match on public.supplier_company;
create trigger cron_signal_supplier_match
  after insert or update of match_state on public.supplier_company
  for each row when (new.match_state = 'pending')
  execute function public._cron_sig_supplier_match();

-- (d) an admin queueing a route plan
create or replace function public._cron_sig_route_plan()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public.cron_wake('route_plan_drain'); return null; end $$;

drop trigger if exists cron_signal_route_plan on public.route_plans;
create trigger cron_signal_route_plan
  after insert or update of status on public.route_plans
  for each row when (new.status = 'queued')
  execute function public._cron_sig_route_plan();

-- (e) a lead scrape / enrich run starting
create or replace function public._cron_sig_lead_scrape()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public.cron_wake('lead_scrape_drain'); return null; end $$;

create or replace function public._cron_sig_lead_enrich()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin perform public.cron_wake('lead_enrich_drain'); return null; end $$;

drop trigger if exists cron_signal_lead_scrape on public.lead_scrape_runs;
create trigger cron_signal_lead_scrape
  after insert or update of status on public.lead_scrape_runs
  for each row when (new.status = 'running')
  execute function public._cron_sig_lead_scrape();

drop trigger if exists cron_signal_lead_enrich on public.lead_enrich_runs;
create trigger cron_signal_lead_enrich
  after insert or update of status on public.lead_enrich_runs
  for each row when (new.status = 'running')
  execute function public._cron_sig_lead_enrich();

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. THE CUTOVER — 15 per-minute jobs become 1
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare r record; v_n int := 0;
begin
  -- medicine-ps-sync is dead code: sync_medicine_ps_batch() returns
  -- {"retired":true} and touches nothing. It is not migrated, just removed.
  for r in select jobid, jobname from cron.job
            where jobname in (
              'bulk-ocr-sweep-1min','cleanup-orphan-inquiry','dev-auto-heal','dev-auto-resolve',
              'inquiry-engine-sync','inquiry-timeout-advance','lead-enrich-drain','lead-scrape-drain',
              'medicine-ps-sync','order-hours-tick','route-plan-drain','supplier-match-dispatch',
              'sweep_inquiry_timeouts_1min','wa_campaign_tick_1min','zone_backfill')
  loop
    perform cron.unschedule(r.jobid);
    v_n := v_n + 1;
  end loop;
  raise notice 'cron: unscheduled % per-minute jobs', v_n;
end $$;

-- The one job that may be per-minute, and the only one the guard allows.
select cron.schedule('cron-dispatch', '* * * * *',
  $$select public.cron_run('cron-dispatch', 'select public.cron_dispatch()')$$);

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. READ SURFACE — cron health, rendered verbatim by CronHealthScreen
-- ═══════════════════════════════════════════════════════════════════════════
-- NB: _dev_guard() RETURNS VOID and raises; it is not a boolean. Same door
-- every other dev-queue RPC uses: service_role or super_admin, nobody else.
create or replace function public.cron_health()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; st record; v_peak int;
begin
  -- Refuse with a PAYLOAD, not a raise. _dev_guard() raises, and a raise leaves
  -- Dart with nothing to show but its own stringified exception — a display
  -- string written in Dart, which this app forbids. ok:false + backend copy.
  begin
    perform public._dev_guard();
  exception when others then
    return jsonb_build_object(
      'ok', false,
      'title', 'Cron health',
      'error', coalesce((select value #>> '{}' from public.ui_copy
                          where key = 'dev_queue.cron_health_forbidden'), ''));
  end;

  select * into st from public.cron_dispatch_state where id;

  -- sweep-line over cron.job_run_details: the real peak concurrency, not a
  -- point sample of pg_stat_activity
  with ev as (
    select start_time t, 1 d from cron.job_run_details where start_time > now() - interval '1 hour'
    union all
    select coalesce(end_time, start_time) t, -1 d from cron.job_run_details where start_time > now() - interval '1 hour'
  ), run as (
    select sum(d) over (order by t, d desc rows between unbounded preceding and current row) c from ev
  )
  select coalesce(max(c), 0) into v_peak from run;

  select jsonb_build_object(
    'ok', true,
    'title', 'Cron health',
    'headline', format('%s cron jobs · %s per-minute · peak %s concurrent in the last hour',
                       (select count(*) from cron.job where active),
                       (select count(*) from cron.job where active and public.cron_is_per_minute(schedule)),
                       v_peak),
    'tick', jsonb_build_object(
      'label', 'Last dispatcher tick',
      'at_label', coalesce(to_char(st.last_tick_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI:SS'), 'never'),
      'value_label', format('%s ran · %s skipped as idle · %s failed · %s ms',
                            st.last_ran, st.last_skipped, st.last_failed, st.last_ms),
      'tone', case when st.last_failed > 0 then 'error'
                   when st.last_tick_at is null or st.last_tick_at < now() - interval '5 minutes' then 'warning'
                   else 'success' end),
    'runs_last_hour', (select count(*) from cron.job_run_details where start_time > now() - interval '1 hour'),
    'db_seconds_last_hour', (select round(coalesce(sum(extract(epoch from (end_time - start_time))), 0)::numeric, 1)
                             from cron.job_run_details where start_time > now() - interval '1 hour'),
    'peak_concurrent', v_peak,
    'tasks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', t.name,
        'mode_label', case t.mode when 'event' then 'Event-driven' else 'Time-bound' end,
        'state_label', case
            when not t.enabled then 'Disabled'
            when t.last_error is not null then 'Last run failed'
            when t.last_run_at is null then 'Idle - never needed yet'
            else format('Last ran %s IST · %s ms',
                        to_char(t.last_run_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'), t.last_ms) end,
        'counts_label', format('%s run · %s skipped as idle', t.runs, t.skips),
        'tone', case when t.last_error is not null then 'error'
                     when not t.enabled then 'warning'
                     when t.mode = 'event' then 'info' else 'success' end,
        'error', t.last_error,
        'note', t.note)
      order by t.ord, t.name) from public.cron_task t), '[]'::jsonb),
    'guard', jsonb_build_object(
      'label', 'Guard',
      'value_label', format('max %s concurrent · %s refusal/repair events in 7 days',
        (select max_concurrent from public.cron_guard_config where id),
        (select count(*) from public.cron_guard_event where at > now() - interval '7 days')),
      'recent', coalesce((select jsonb_agg(jsonb_build_object(
          'at_label', to_char(g.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
          'kind', g.kind, 'job', g.job_name, 'detail', g.detail) order by g.at desc)
        from (select * from public.cron_guard_event order by at desc limit 10) g), '[]'::jsonb))
  ) into v;

  return v;
end $$;

grant execute on function public.cron_health() to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. COPY — every visible word on the screen is a backend string
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy (key, value) values
 ('dev_queue.cron_health_nav_label',  to_jsonb('Cron health'::text)),
 ('dev_queue.cron_health_refresh',    to_jsonb('Refresh'::text)),
 ('dev_queue.cron_health_tasks_title',to_jsonb('Registered work'::text)),
 ('dev_queue.cron_health_runs_hour',  to_jsonb('Runs / hour'::text)),
 ('dev_queue.cron_health_db_seconds', to_jsonb('DB seconds / hour'::text)),
 ('dev_queue.cron_health_peak',       to_jsonb('Peak concurrent'::text)),
 ('dev_queue.cron_health_guard_quiet',to_jsonb('No refusals or repairs in the last 7 days.'::text)),
 ('dev_queue.cron_health_forbidden',
  to_jsonb('Cron health is a super-admin screen. Sign in as a super-admin to see the dispatcher, its registered work and the guard log.'::text)),
 ('dev_queue.cron_health_unreachable',
  to_jsonb('Could not reach the backend. Nothing was changed — tap Refresh to try again.'::text))
on conflict (key) do update set value = excluded.value;
