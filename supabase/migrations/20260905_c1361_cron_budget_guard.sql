-- CHANGE #1361 — no cron task may eat its own interval.
--
-- Om, 5 Sep 00:42 and 05:32 IST: "the app takes minutes per tab while NOTHING
-- is building and the VM is off." Measured: catalogue_cache_refresh ran every
-- 60 s and each unit took 22-66 s (facet scans, zone_scan, suggest_brand over
-- 5.6 lakh MEDICINE rows) — 1,028 runs since 3 Sep. storefront_home_warm took
-- 4 s every 120 s on top. On a 1 GB instance that is the database busy for
-- 25-60 seconds of every minute, all day, and every user-facing query queues
-- behind it. Om disabled both by hand.
--
-- Disabling them by hand is not a fix, because nothing stopped the NEXT task
-- from doing it. This is the permanent rule, and it is deliberately about the
-- SHAPE of a schedule rather than about these two jobs:
--
--   a task that cannot finish inside a fifth of its own interval is
--   mis-scheduled, and the dispatcher parks it instead of running it again.
--
-- Proof it is not theoretical: at the moment this was written rg_after_deploy
-- was taking 53,475 ms on a 120 s interval — 44.6% — and it last ran at 10:43,
-- which is the same minute the connection pool starved and REST + the pooler
-- both went to Cloudflare 522 for eight minutes.

-- ── 1. the columns the rule needs ───────────────────────────────────────────
alter table public.cron_task
  add column if not exists parked_reason  text,
  add column if not exists parked_at      timestamptz,
  add column if not exists parked_ms      int,
  -- Heavy rebuilds are night work. The window itself is config, not a literal.
  add column if not exists night_only     boolean not null default false,
  -- An escape hatch that has to be set deliberately, per task, and shows up on
  -- the card — never a silent global "off".
  add column if not exists budget_exempt  boolean not null default false,
  add column if not exists budget_pct     int;

alter table public.cron_guard_config
  add column if not exists budget_enforce   boolean not null default true,
  add column if not exists budget_pct       int     not null default 20,
  -- "or 20 s absolute for per-minute tasks" — for a fast task a fifth of the
  -- interval is unusably small, so the absolute ceiling is the kinder of the
  -- two and is what applies below night_fast_s.
  add column if not exists budget_abs_ms    int     not null default 20000,
  add column if not exists budget_fast_s    int     not null default 60,
  add column if not exists night_start_ist  time    not null default '02:00',
  add column if not exists night_end_ist    time    not null default '05:00',
  add column if not exists daytime_row_cap  int     not null default 50000;

insert into public.wa_event_routes (event_key, label, description, enabled, auto_manage, audience,
                                   push_title, push_body, dedupe_minutes)
values ('sec_cron_parked', 'Cron task parked',
        'A scheduled task took more than its share of its own interval and was parked',
        true, true, 'admin', 'Cron task parked', '{{reason}}', 30)
on conflict (event_key) do nothing;

insert into public.ui_copy (key, value) values
 ('dev_queue.cron_budget_title',   '"Budget"'::jsonb),
 ('dev_queue.cron_parked_label',   '"Parked — over budget"'::jsonb),
 ('dev_queue.cron_parked_detail',  '"{name} took {ms} of its {interval} interval ({pct}). It is parked until an admin re-enables it."'::jsonb),
 ('dev_queue.cron_budget_ok',      '"{pct} of its interval"'::jsonb),
 ('dev_queue.cron_night_label',    '"Night only ({from}-{to} IST)"'::jsonb),
 ('dev_queue.cron_night_waiting',  '"Waiting for the {from}-{to} IST window"'::jsonb),
 ('dev_queue.cron_parked_none',    '"No task is over its budget."'::jsonb),
 ('dev_queue.cron_parked_head',    '"Parked tasks"'::jsonb)
on conflict (key) do nothing;

-- ── 2. the rule itself, as one function so it has exactly one definition ────
-- Returns the ceiling in ms for a task, or NULL when the task cannot be judged
-- (no interval of its own, or deliberately exempt). NULL means "never park".
-- Takes SCALARS, never a rowtype: the dispatcher's loop variable is `record`
-- (a `for t in select * from ...` never carries the table's composite type),
-- and a rowtype parameter there fails with "cannot cast type record to
-- cron_task" — which aborts the whole tick. Scalars are also the honest
-- signature, since the rule only ever needed these three fields, and they let
-- the dispatcher, the behaviour test and the ops card all call ONE function.
create or replace function public._cron_budget_ms(
  p_interval_s int, p_exempt boolean default false, p_pct int default null)
returns int language plpgsql stable security definer set search_path to 'public' as $$
declare c public.cron_guard_config; v_pct int;
begin
  select * into c from public.cron_guard_config where id;
  if not coalesce(c.budget_enforce, true) then return null; end if;
  if coalesce(p_exempt, false) then return null; end if;
  -- A task with no interval is pinned to a clock time or woken by an event;
  -- there is no "share of the interval" to take, so there is nothing to judge.
  if p_interval_s is null then return null; end if;
  v_pct := greatest(coalesce(p_pct, c.budget_pct, 20), 1);
  if p_interval_s <= coalesce(c.budget_fast_s, 60) then
    return coalesce(c.budget_abs_ms, 20000);
  end if;
  return (p_interval_s * 1000 * v_pct / 100)::int;
end $$;

-- Park one task. Separated from the dispatcher so the ops surface, a test and
-- a future admin action all park the same way.
create or replace function public._cron_park(p_name text, p_ms int, p_limit int)
returns void language plpgsql security definer set search_path to 'public' as $$
declare t public.cron_task; v_pct text; v_reason text;
begin
  select * into t from public.cron_task where name = p_name;
  if not found or not t.enabled then return; end if;
  v_pct := round(p_ms::numeric / (t.base_interval_s * 10.0), 1)::text || '%';
  v_reason := replace(replace(replace(replace(
      _c_or('dev_queue.cron_parked_detail',
            '{name} took {ms} of its {interval} interval ({pct}).'),
      '{name}', p_name),
      '{ms}', _fmt_dur(p_ms / 1000.0)),
      '{interval}', _fmt_dur(t.base_interval_s)),
      '{pct}', v_pct);

  update public.cron_task
     set enabled = false, parked_reason = v_reason, parked_at = now(), parked_ms = p_ms,
         next_run_at = null
   where name = p_name;

  perform wa_send_event('sec_cron_parked', null,
    jsonb_build_object('reason', v_reason, 'task', p_name,
                       'ms', p_ms::text, 'limit_ms', p_limit::text), null, null);
  insert into rg_alerts (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
  values ('cron_budget:'||p_name, 'warn', 'cron_budget',
          _c_or('dev_queue.cron_parked_label','Parked — over budget'),
          jsonb_build_object('task', p_name, 'ms', p_ms, 'limit_ms', p_limit,
                             'interval_s', t.base_interval_s),
          now(), now(), 1)
  on conflict (fingerprint) do update
    set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
        detail = excluded.detail;
  perform _audit('system','cron_park', p_name,
                 jsonb_build_object('ms', p_ms, 'limit_ms', p_limit, 'reason', v_reason));
end $$;

-- ── 3. the night window ─────────────────────────────────────────────────────
-- One place decides what "night" means, so the dispatcher, the planner and the
-- card can never disagree about it. IST because that is the only clock this
-- business runs on.
create or replace function public._cron_is_night()
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare c public.cron_guard_config; v_now time;
begin
  select * into c from public.cron_guard_config where id;
  v_now := (now() at time zone 'Asia/Kolkata')::time;
  -- Written to survive a window that crosses midnight, because someone will
  -- eventually set 23:00-03:00 and a naive BETWEEN would silently never fire.
  if coalesce(c.night_start_ist,'02:00') <= coalesce(c.night_end_ist,'05:00') then
    return v_now >= coalesce(c.night_start_ist,'02:00')
       and v_now <  coalesce(c.night_end_ist,'05:00');
  end if;
  return v_now >= coalesce(c.night_start_ist,'02:00')
      or v_now <  coalesce(c.night_end_ist,'05:00');
end $$;

-- ── 4. the dispatcher enforces both ─────────────────────────────────────────
-- Reproduced whole because CREATE OR REPLACE has no other shape. Two additions
-- and nothing else: a night gate before a task may start, and a budget check on
-- the duration it actually took. #327 is the reason the rest is copied verbatim
-- rather than reconstructed — editing this function from memory silently drops
-- rules that are not visibly there.
CREATE OR REPLACE FUNCTION public.cron_dispatch()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  t record; v_started timestamptz := clock_timestamp(); v_budget_ms int;
  v_hard_ms int; v_remain_ms int; v_step_ms int; v_reserve_ms constant int := 5000;
  v_run boolean; v_signalled boolean; v_t0 timestamptz; v_ms int;
  v_ran int := 0; v_skipped int := 0; v_failed int := 0; v_deferred int := 0;
  v_cursor text; v_last text := null; v_truncated boolean := false;
  v_rows int; v_iv int; v_next timestamptz; v_err text; v_scheduled boolean;
  v_did boolean; v_limit_ms int; v_parked int := 0;
begin
  if not pg_try_advisory_lock(7301, 1) then
    return jsonb_build_object('ok', true, 'skipped', 'previous tick still running');
  end if;

  select tick_budget_ms, tick_hard_ms into v_budget_ms, v_hard_ms
    from public.cron_guard_config where id;
  v_budget_ms := coalesce(v_budget_ms, 25000);
  -- CHANGE #1055 — THE TICK HAS A HARD WALL, NOT JUST A BUDGET.
  -- tick_budget_ms only decides whether to START another task. It was checked
  -- BEFORE each task and the task itself was then bounded by nothing but its
  -- own step_timeout_ms, so a task with a 110 s step could begin at 24.9 s and
  -- run to 135 s -- past the 120 s statement_timeout pg_cron wraps this call
  -- in. That outer cancel aborts the WHOLE transaction: the cursor update at
  -- the bottom never happens and the task's own next_run_at is never re-armed,
  -- so the very next tick starts at the same task and dies the same way. That
  -- is the wedge behind "the cron dispatcher is not ticking" (#305) -- five
  -- consecutive ticks were killed by one search_suggest_stage rebuild on
  -- 2026-09-04, and play-reap-stale sat two hours past due behind it.
  v_hard_ms := greatest(coalesce(v_hard_ms, 100000), v_budget_ms + v_reserve_ms);
  select cursor_name into v_cursor from public.cron_dispatch_state where id;

  for t in
    select * from public.cron_task where enabled
    order by (case when v_cursor is null
                     or (ord, name) > (select c.ord, c.name from public.cron_task c where c.name = v_cursor)
                   then 0 else 1 end),
             ord, name
  loop
    -- Both walls are tested here, BEFORE v_last is moved onto this task, so a
    -- truncated tick resumes ON the task it declined to start rather than
    -- skipping it.
    v_remain_ms := v_hard_ms - (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int;
    if extract(epoch from (clock_timestamp() - v_started)) * 1000 > v_budget_ms
       or v_remain_ms <= v_reserve_ms then
      v_truncated := true; exit;
    end if;

    v_scheduled := (t.base_interval_s is not null or t.run_at_ist is not null);

    select true into v_signalled from public.cron_signal where task = t.name;
    v_signalled := coalesce(v_signalled, false);

    -- Not due: the cheapest outcome there is. No gate SQL, no write, no stats
    -- row. This is what lets one tick host fifty former pg_cron jobs for free.
    if not v_signalled and t.next_run_at is not null and t.next_run_at > now() then
      v_deferred := v_deferred + 1;
      v_last := t.name;
      continue;
    end if;

    v_last := t.name;

    -- CHANGE #1361 — HEAVY REBUILDS ARE NIGHT WORK.
    -- The catalogue rebuild is not wrong, it is wrongly TIMED: a facet scan or
    -- a zone_scan over 5.6 lakh MEDICINE rows is 20-66 s of a 1 GB instance,
    -- and at 11:00 IST every user-facing query queues behind it. Same work,
    -- moved to 02:00-05:00 IST, costs nobody anything. A signalled task still
    -- runs — a real event is served whenever it happens.
    if not v_signalled and t.night_only and not public._cron_is_night() then
      update public.cron_task
         set last_checked_at = now(), skips = skips + 1, last_result = 'night',
             next_run_at = now() + make_interval(secs => greatest(coalesce(t.base_interval_s, 600), 600))
       where name = t.name;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- Business hours never gate a signalled task: a real event is still served
    -- at 3am. Only tasks nothing user-facing waits on opt in.
    if not v_signalled and t.business_hours_only and not public._cron_business_open() then
      update public.cron_task
         set last_checked_at = now(), skips = skips + 1, last_result = 'closed',
             next_run_at = now() + make_interval(secs => greatest(coalesce(t.base_interval_s, 900), 900))
       where name = t.name;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_run := v_signalled;
    if not v_run and t.gate_sql is not null then
      begin
        execute 'set local statement_timeout = 3000';
        execute t.gate_sql into v_run;
      exception when others then
        v_run := true;
      end;
      v_run := coalesce(v_run, false);
    elsif not v_run and t.gate_sql is null and v_scheduled then
      -- No gate but its own schedule: being due IS the decision to run. A
      -- gate-less task with NO schedule stays what it always was - event-only,
      -- woken by cron_signal and by nothing else.
      v_run := true;
    end if;

    if not v_run then
      v_iv := null; v_next := null;
      if t.run_at_ist is not null then
        v_next := public._cron_next_pinned(t.run_at_ist, t.run_dow);
      elsif t.base_interval_s is not null then
        v_iv := least(greatest(coalesce(t.max_interval_s, 3600), t.base_interval_s),
                      greatest(coalesce(t.current_interval_s, t.base_interval_s), 1) * 2);
        v_next := now() + make_interval(secs => v_iv);
      end if;

      update public.cron_task
         set last_checked_at = now(), skips = skips + 1, last_result = 'idle',
             consecutive_idle = consecutive_idle + 1,
             current_interval_s = coalesce(v_iv, current_interval_s),
             next_run_at = v_next
       where name = t.name;

      if v_scheduled then
        insert into public.cron_job_stats (job_name, source, started_at, duration_ms, rows_touched, did_work)
        values (t.name, 'dispatcher', now(), 0, 0, false);
      end if;

      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_t0 := clock_timestamp(); v_err := null; v_rows := null;
    begin
      -- Never hand a task more time than the tick has left to give.
      v_step_ms := greatest(least(t.step_timeout_ms, v_remain_ms - v_reserve_ms), 1000);
      execute format('set local statement_timeout = %s', v_step_ms);
      execute t.work_sql;
      get diagnostics v_rows = ROW_COUNT;
      v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;

      -- For `select fn()` ROW_COUNT is always 1 and means nothing, so only a
      -- task that declared itself DML is judged on the rows it touched.
      v_did := (not coalesce(t.dml, false)) or coalesce(v_rows, 0) > 0;

      if t.run_at_ist is not null then
        v_next := public._cron_next_pinned(t.run_at_ist, t.run_dow);
        v_iv := null;
      elsif t.base_interval_s is not null then
        v_iv := case when v_did then t.base_interval_s
                     else least(greatest(coalesce(t.max_interval_s, 3600), t.base_interval_s),
                                greatest(coalesce(t.current_interval_s, t.base_interval_s), 1) * 2) end;
        v_next := now() + make_interval(secs => v_iv);
      else
        v_iv := null; v_next := null;
      end if;

      update public.cron_task
         set last_checked_at = now(), last_run_at = now(), last_ms = v_ms,
             last_error = null, fail_count = 0,
             runs  = runs  + (case when v_did then 1 else 0 end),
             skips = skips + (case when v_did then 0 else 1 end),
             last_result = case when v_did then 'ran' else 'idle' end,
             consecutive_idle = case when v_did then 0 else consecutive_idle + 1 end,
             current_interval_s = v_iv, next_run_at = v_next
       where name = t.name;
      delete from public.cron_signal where task = t.name;

      if v_did then v_ran := v_ran + 1; else v_skipped := v_skipped + 1; end if;
    exception when others then
      v_ms := (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int;
      v_err := left(sqlerrm, 500);
      v_did := false;

      -- A failing task is still re-armed, or one error freezes it forever.
      if t.run_at_ist is not null then
        v_next := public._cron_next_pinned(t.run_at_ist, t.run_dow);
      elsif t.base_interval_s is not null then
        v_next := now() + make_interval(secs => t.base_interval_s);
      else
        v_next := null;
      end if;

      update public.cron_task
         set last_checked_at = now(), last_run_at = now(), last_ms = v_ms,
             last_error = v_err, fail_count = fail_count + 1,
             last_result = 'error', next_run_at = v_next
       where name = t.name;
      delete from public.cron_signal where task = t.name;
      v_failed := v_failed + 1;
    end;

    insert into public.cron_job_stats (job_name, source, started_at, duration_ms, rows_touched, did_work, error)
    values (t.name, 'dispatcher', v_t0, v_ms, v_rows, coalesce(v_did, false), v_err);

    -- CHANGE #1361 — THE BUDGET RULE, applied to the run that just happened.
    -- Deliberately AFTER the stats row: the evidence is written first, so a
    -- parked task can always be explained from cron_job_stats afterwards.
    -- Deliberately on the ACTUAL duration rather than on a declared estimate,
    -- because #747's units were declared bounded and measured 22-66 s.
    v_limit_ms := public._cron_budget_ms(t.base_interval_s, t.budget_exempt, t.budget_pct);
    if v_limit_ms is not null and coalesce(v_ms, 0) > v_limit_ms then
      perform public._cron_park(t.name, v_ms, v_limit_ms);
      v_parked := v_parked + 1;
    end if;
  end loop;

  -- The sweep used to run with statement_timeout = 0 inside the same outer
  -- 120 s window it could therefore overrun. It gets what is left, never all.
  execute format('set local statement_timeout = %s',
    greatest(v_hard_ms - (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int, 2000));

  begin
    perform public.cron_guard_sweep();
  exception when others then null;
  end;

  update public.cron_dispatch_state
     set cursor_name  = case when v_truncated then v_last else null end,
         last_tick_at = now(), last_ran = v_ran, last_skipped = v_skipped,
         last_failed = v_failed,
         last_ms = (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int,
         ticks = ticks + 1
   where id;

  perform pg_advisory_unlock(7301, 1);

  return jsonb_build_object('ok', true, 'ran', v_ran, 'skipped', v_skipped,
    'failed', v_failed, 'deferred', v_deferred, 'truncated', v_truncated,
    'parked', v_parked,
    'ms', (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int);
exception when others then
  perform pg_advisory_unlock(7301, 1);
  raise;
end $function$

;

-- ── 5. the planner stops re-planning the whole catalogue ────────────────────
-- catalogue_refresh_plan() deletes every unit and enqueues the ENTIRE catalogue
-- — a zone_scan per 150k-id range per zone, seven facets per zone, a
-- suggest_brand per 25k-id range, a reset over 3.6 lakh rows — and its gate
-- fires that every 12 hours, at whatever hour it happens to be. Measured unit
-- costs: zone_scan 31.8 s, suggest_facet 29.1 s, facet 20.0 s, suggest_brand
-- 18.8 s. That is the 22-66 s Om saw, and in daytime it is simply the wrong
-- work at the wrong time.
--
-- NOTE ON THE SPEC: it says trg_medicine_refresh_dirty "already marks" changed
-- rows so daytime can refresh only those. It does not — it calls
-- job_mark_dirty() on three JOB names; there is no changed-row set anywhere.
-- Building one means a per-row trigger on a 5.6 lakh-row table whose writes
-- already cost ~50 ms each across 36 indexes, and that is the dirty-flag
-- feedback-loop class that has already cost this project hours. So the
-- guarantee the spec actually wants — never a full scan in daytime — is kept
-- by BOUNDING the day instead of instrumenting every write.
create or replace function public.catalogue_refresh_plan(p_mode text default null)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare
  v_min bigint; v_max bigint; v_step bigint := 150000;
  v_ord int := 0; v_lo bigint; z record; f text; b int; v_full boolean;
begin
  -- Mode is DECIDED here, once: the caller may force it, otherwise the clock
  -- does. A full plan is night work by definition.
  v_full := case when p_mode = 'full' then true
                 when p_mode = 'incremental' then false
                 else public._cron_is_night() end;

  select min(id), max(id) into v_min, v_max from "MEDICINE";
  if v_min is null then return 0; end if;

  delete from public.catalogue_refresh_unit;

  if v_full then
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
  end if;

  -- The facet counts are the cheap half and they are what a user actually
  -- sees, so they are planned in BOTH modes.
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

  -- Everything below rewrites the typeahead cache off the whole MEDICINE
  -- table. Night only — there is no version of it that belongs at 11:00 IST.
  if v_full then
    v_ord := v_ord + 1;
    insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg)
      values (v_ord, 'suggest_reset', 0::smallint, '');
    v_lo := v_min;
    while v_lo <= v_max loop
      v_ord := v_ord + 1;
      insert into public.catalogue_refresh_unit(ord, kind, zone_id, arg, arg2)
        values (v_ord, 'suggest_brand', 0::smallint, v_lo::text,
                least(v_lo + 24999, v_max)::text);
      v_lo := v_lo + 25000;
    end loop;
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
  end if;

  update public.catalogue_refresh_state
     set cycle_started = now(), cycle_ended = null,
         last_note = 'planned ' || v_ord || ' units (' ||
                     case when v_full then 'full' else 'incremental' end || ')'
   where id = 1;
  return v_ord;
end $$;

-- ── 6. the tasks, re-classified ─────────────────────────────────────────────
-- Om disabled catalogue_cache_refresh and storefront_home_warm by hand. They go
-- back on, under the rules above rather than on trust.
update public.cron_task
   set night_only = true, enabled = true,
       parked_reason = null, parked_at = null, parked_ms = null,
       base_interval_s = 300,
       note = 'CHANGE #1361 — the full catalogue rebuild is NIGHT work (02:00-05:00 IST). '
              'Each unit measured 19-32 s against 5.6 lakh MEDICINE rows; at 11:00 IST that '
              'is the whole instance. Daytime plans are incremental (facet counts only).'
 where name = 'catalogue_cache_refresh';

-- home warm is NOT night work: 3,944 ms on a 120 s interval is 3.3%, it is
-- inside budget, and it is what keeps the anonymous home page from being cold
-- for every first-time visitor. Making it night-only would fix nothing and cost
-- every daytime visitor the slow path. It comes back at a wider interval
-- because its own gate already only fires when the payload is over 8 minutes
-- old.
update public.cron_task
   set enabled = true, night_only = false, base_interval_s = 300,
       parked_reason = null, parked_at = null, parked_ms = null,
       note = 'CHANGE #678 — rebuilds the anonymous home payload. #1361: measured 3.9 s '
              'per run = 1.3% of a 300 s interval, comfortably inside budget; re-enabled.'
 where name = 'storefront_home_warm';

-- rg_after_deploy was the worst live offender at the moment this was written:
-- 53,475 ms on a 120 s interval — 44.6% — and it last ran at 10:43 UTC, the
-- same minute the pool starved and REST went to 522 for eight minutes. It is
-- not misbehaving; rg_check IS a catalogue-wide scan and its interval was
-- simply set far too tight. Widened rather than exempted: 53 s of 600 s is
-- 8.9%, inside budget, and the guard still runs within ten minutes of a deploy.
-- Exempting it would have hidden exactly the signal this change exists to give.
update public.cron_task
   set base_interval_s = 600,
       note = coalesce(note,'') || ' #1361: interval 120s->600s — it measured 53.5 s, '
              '44.6% of its old interval, and starved the connection pool.'
 where name = 'rg_after_deploy';

-- ── 7. the daytime row cap ──────────────────────────────────────────────────
-- The second half of "never a full scan in daytime". The night window stops
-- the full PLAN from being made; this stops any single unit that turns out to
-- be huge from running anyway, whatever planned it. Called by the tick.
create or replace function public._cron_daytime_ok(p_rows_estimate bigint)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare c public.cron_guard_config;
begin
  if public._cron_is_night() then return true; end if;
  select * into c from public.cron_guard_config where id;
  return coalesce(p_rows_estimate, 0) <= coalesce(c.daytime_row_cap, 50000);
end $$;

-- ── 8. the guard rule ───────────────────────────────────────────────────────
-- Two reds, both stated as the spec states them. This is a BEHAVIOUR test, not
-- a signature diff, because it is about what the schedule DOES rather than
-- about the shape of anything — and behaviour failures are never rebaselined
-- away.
insert into public.rg_behavior_tests (name, body, enabled, note) values
('cron_budget_respected', $rg$
do $t$
declare r record; v_limit int; v_bad text := '';
begin
  -- 1. no enabled task may exceed its budget. A task over budget should have
  --    been parked by the dispatcher, so finding one still enabled means the
  --    rule is not running.
  for r in select * from public.cron_task where enabled loop
    v_limit := public._cron_budget_ms(r.base_interval_s, r.budget_exempt, r.budget_pct);
    if v_limit is not null and coalesce(r.last_ms,0) > v_limit then
      v_bad := v_bad || r.name || ' took ' || r.last_ms || 'ms of a '
            || r.base_interval_s || 's interval (limit ' || v_limit || 'ms); ';
    end if;
  end loop;
  if v_bad <> '' then
    raise exception 'cron budget exceeded and not parked: %', v_bad;
  end if;

  -- 2. no daytime run may touch more than the cap. Judged on what the
  --    dispatcher actually recorded, not on an estimate.
  select string_agg(job_name || ' touched ' || rows_touched || ' rows at '
                    || to_char(started_at at time zone 'Asia/Kolkata','HH24:MI'), '; ')
    into v_bad
  from public.cron_job_stats
  where started_at > now() - interval '24 hours'
    and coalesce(rows_touched,0) > (select coalesce(daytime_row_cap,50000)
                                      from public.cron_guard_config where id)
    and (started_at at time zone 'Asia/Kolkata')::time
        not between (select night_start_ist from public.cron_guard_config where id)
                and (select night_end_ist   from public.cron_guard_config where id);
  if coalesce(v_bad,'') <> '' then
    raise exception 'daytime run over the row cap: %', v_bad;
  end if;

  -- The harness's success marker: rg_run_behavior treats a body that returns
  -- without raising RG_ROLLBACK as a FAILED test, so a green run has to say so.
  raise exception 'RG_ROLLBACK';
end $t$;
$rg$, true,
'CHANGE #1361 — a task that cannot finish in a fifth of its own interval is mis-scheduled, and heavy scans belong to the night window. Never rebaseline this: it is a behaviour, not a signature.')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── 9. the ops surface ──────────────────────────────────────────────────────
-- cron_health() gains the two things Om could not see on 5 Sep: what each task
-- costs as a share of its own interval, and what has been parked for taking too
-- much. Every string is built here.
create or replace function public.cron_budget_card()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare c public.cron_guard_config; v_parked jsonb; v_top jsonb; v_night text;
begin
  perform _dev_guard();
  select * into c from public.cron_guard_config where id;

  v_night := replace(replace(_c_or('dev_queue.cron_night_label','Night only ({from}-{to} IST)'),
               '{from}', to_char(coalesce(c.night_start_ist,'02:00'),'HH24:MI')),
               '{to}',   to_char(coalesce(c.night_end_ist,'05:00'),'HH24:MI'));

  select coalesce(jsonb_agg(jsonb_build_object(
           'name', t.name,
           'label', _c_or('dev_queue.cron_parked_label','Parked — over budget'),
           'detail', coalesce(t.parked_reason,''),
           'at_label', to_char(t.parked_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
           'tone', 'warning') order by t.parked_at desc), '[]'::jsonb)
    into v_parked
  from public.cron_task t where t.parked_at is not null and not t.enabled;

  -- The five most expensive schedules as a SHARE of their own interval, which
  -- is the number that actually predicts starvation. A task at 44% is the one
  -- to look at even when a 30 s task on a 4 hour interval looks worse.
  select coalesce(jsonb_agg(x order by x->>'pct_num' desc), '[]'::jsonb) into v_top
  from (
    select jsonb_build_object(
             'name', t.name,
             'value', replace(_c_or('dev_queue.cron_budget_ok','{pct} of its interval'),
                        '{pct}', round(t.last_ms::numeric / (t.base_interval_s*10.0),1)::text || '%'),
             'sub', _fmt_dur(t.last_ms/1000.0) || ' every ' || _fmt_dur(t.base_interval_s),
             'pct_num', round(t.last_ms::numeric / (t.base_interval_s*10.0),1),
             'night', t.night_only,
             'tone', case when public._cron_budget_ms(t.base_interval_s, t.budget_exempt, t.budget_pct) is null then 'neutral'
                          when t.last_ms > public._cron_budget_ms(t.base_interval_s, t.budget_exempt, t.budget_pct) then 'danger'
                          when t.last_ms > public._cron_budget_ms(t.base_interval_s, t.budget_exempt, t.budget_pct)/2 then 'warning'
                          else 'success' end) as x
    from public.cron_task t
    where t.enabled and t.base_interval_s is not null and coalesce(t.last_ms,0) > 0
    order by t.last_ms::numeric / t.base_interval_s desc limit 5
  ) q;

  return jsonb_build_object(
    'has', true,
    'title', _c_or('dev_queue.cron_budget_title','Budget'),
    'night_label', v_night,
    'enforced', coalesce(c.budget_enforce, true),
    'rule_label', 'Over ' || coalesce(c.budget_pct,20) || '% of its own interval ('
                  || _fmt_dur(coalesce(c.budget_abs_ms,20000)/1000.0)
                  || ' for tasks under ' || _fmt_dur(coalesce(c.budget_fast_s,60)) || ') is parked',
    'parked_head', _c_or('dev_queue.cron_parked_head','Parked tasks'),
    'parked_empty', _c_or('dev_queue.cron_parked_none','No task is over its budget.'),
    'parked', v_parked,
    'top', v_top,
    'zone', admin_active_zone(),
    'date', admin_active_date());
end $$;

-- ── 10. grants ──────────────────────────────────────────────────────────────
-- Caught by rg behaviour `cron_surface_closed_to_clients` on the first run of
-- this change, which is exactly what it is for. A new function inherits the
-- DEFAULT PUBLIC EXECUTE grant, and the anon key ships inside the web bundle
-- and the APK — so without this an anonymous caller could have called
-- _cron_park() and parked any scheduled task in the system.
--
-- Revoke from PUBLIC, not just from anon/authenticated: anon inherits the
-- PUBLIC grant and revoking a direct grant it never had is a no-op (#305).
--
-- Left over from this change's own first apply: the rowtype overload the
-- dispatcher could not call. Dropped so there is exactly one definition.
drop function if exists public._cron_budget_ms(public.cron_task);

revoke execute on function public._cron_budget_ms(int, boolean, int) from public, anon, authenticated;
revoke execute on function public._cron_daytime_ok(bigint)           from public, anon, authenticated;
revoke execute on function public._cron_park(text, int, int)         from public, anon, authenticated;
revoke execute on function public._cron_is_night()                   from public, anon, authenticated;
grant  execute on function public._cron_budget_ms(int, boolean, int) to service_role;
grant  execute on function public._cron_daytime_ok(bigint)           to service_role;
grant  execute on function public._cron_park(text, int, int)         to service_role;
grant  execute on function public._cron_is_night()                   to service_role;

-- The card follows cron_health() exactly: the signed-in admin app calls it and
-- _dev_guard() inside decides whether that caller may see anything. anon never
-- reaches it at all.
revoke execute on function public.cron_budget_card() from public, anon;
grant  execute on function public.cron_budget_card() to authenticated, service_role;

-- ── 11. one planner, not two ────────────────────────────────────────────────
-- Adding catalogue_refresh_plan(p_mode text) beside the original
-- catalogue_refresh_plan() left an OVERLOADED name, which rg_overload_risks()
-- rates critical and rightly so: cron_task.work_sql calls it as
-- `catalogue_refresh_plan()` and with both present that call is ambiguous —
-- which of the two runs is then down to resolution order rather than intent,
-- and the wrong one is a full catalogue sweep at 11:00 IST. The new signature
-- has a DEFAULT, so the no-argument call still works and means "let the clock
-- decide", which is exactly what the old one should have been doing.
drop function if exists public.catalogue_refresh_plan();

-- ── 12. night throughput ────────────────────────────────────────────────────
-- The night window is three hours and the tick takes ONE unit per interval, so
-- the interval decides how much actually drains. At 300 s that is 36 units a
-- night against a 66-unit full plan — a full cycle would take two nights.
--
-- It cannot simply be made fast, because the budget rule applies to this task
-- like every other: units measure 19-32 s, so anything under ~160 s would park
-- it the first time a unit ran long, and a 60 s interval would hit the 20 s
-- absolute ceiling immediately. 240 s gives a 48 s budget — a comfortable
-- margin over the worst unit measured (32 s) — and drains ~45 units per window,
-- so a full cycle finishes inside one night. Daytime cost is unchanged: the
-- task is night_only, so in daylight this interval only decides how often it
-- re-checks the clock and defers.
update public.cron_task
   set base_interval_s = 240
 where name = 'catalogue_cache_refresh';

-- ── 13. the dispatcher's own budget ─────────────────────────────────────────
-- Found while verifying this change: the worst offender on the box is not a
-- TASK at all, it is the tick that runs them. cron_dispatch is scheduled
-- '* * * * *' and its last completed tick took 99,200 ms — 165% of its own
-- minute — against the 120 s statement_timeout pg_cron wraps the call in. At
-- 11:12 on 5 Sep it duly lost the race: "canceling statement due to statement
-- timeout". That cancel aborts the WHOLE transaction, so the cursor update and
-- every task's next_run_at re-arm are rolled back, and the next tick starts on
-- the same task and dies the same way. cron_dispatch's own comments name that
-- as the #305 wedge; tick_hard_ms was added to prevent it and then set at
-- 100,000 ms, which leaves 20 s for the reserve AND the guard sweep AND the
-- final bookkeeping. That is not margin, it is a coin toss under load.
--
-- 75,000 ms leaves 45 s of headroom under the cap. It costs nothing: a
-- truncated tick already resumes from its cursor on the next minute, so a
-- shorter wall means more ticks doing less each, not less work done. The rule
-- this whole change is about, applied to the thing that enforces it.
update public.cron_guard_config set tick_hard_ms = 75000 where id;
