-- CHANGE #755 — Self-healing runner breaker.
--
-- #641 gave the fleet a circuit breaker that switched Workflow OFF after ten DB
-- timeouts in five minutes. It worked. What it did not have was a way back:
-- on 03 Sep 2026 04:37 IST it tripped and the fleet sat idle for seven hours
-- waiting for a human to flip a switch, while the database it was protecting
-- was perfectly healthy the whole time (CPU 22%, 26 of 60 connections).
-- Automatic off with manual on is not a breaker, it is a trapdoor.
--
-- This replaces the on/off with a MEASURED score and adaptive concurrency:
--   * a bounded probe writes a 0-100 health score into dev_runner_health,
--   * worker_pool.build_semaphore is derived from that score (>=80 -> 3,
--     60-79 -> 2, 40-59 -> 1, <40 -> 0 and Workflow paused),
--   * down is immediate, up is one step per three consecutive green probes,
--   * a tripped breaker resumes ITSELF once the score holds green,
--   * a second trip inside the cooldown window doubles the green streak it
--     needs and is the only one that WhatsApps Om,
--   * every trip names the slowest calls and files ONE deduped command to
--     bound the worst one.
--
-- The probe is deliberately NOT free-running: its cron gate requires VM+Claude
-- on and at least one pending/building command (or a tripped breaker waiting
-- to resume). An idle hour costs zero probe runs; the dispatcher backs the gate
-- check itself off to one cheap read every ten minutes, and a new command or a
-- manual Workflow ON wakes it immediately through cron_signal.
--
-- Every migration here is idempotent: a resumed worker re-applies it silently.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. STORAGE
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.dev_runner_health (
  at              timestamptz primary key default date_trunc('second', now()),
  score           int         not null,
  latency_p95_ms  numeric,
  conns           int,
  max_conns       int,
  timeouts_5min   int         not null default 0,
  transport_5min  int         not null default 0,
  cpu_pct         numeric,
  ram_pct         numeric,
  semaphore       int,
  green_streak    int         not null default 0,
  workflow        text,
  action          text        not null default 'hold',
  detail          jsonb       not null default '{}'::jsonb
);
comment on table public.dev_runner_health is
  'CHANGE #755 — one row per health probe. score 0-100 drives worker_pool.build_semaphore.';

create index if not exists dev_runner_health_at_idx
  on public.dev_runner_health (at desc);

create table if not exists public.dev_runner_breaker_event (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  kind      text        not null,   -- trip | resume | scale_down | scale_up | manual
  score     int,
  semaphore int,
  reason    text        not null default '',
  detail    jsonb       not null default '{}'::jsonb
);
comment on table public.dev_runner_breaker_event is
  'CHANGE #755 — the trip/resume/scale history the runner control card renders.';

create index if not exists dev_runner_breaker_event_at_idx
  on public.dev_runner_breaker_event (at desc);

alter table public.dev_runner_health          enable row level security;
alter table public.dev_runner_breaker_event   enable row level security;
-- No policy: SECURITY DEFINER RPCs are the only readers/writers, exactly like
-- db_health_sample. RLS on with no policy = closed to PostgREST.

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. CONFIG — every threshold is data, so tuning is an UPDATE, not a deploy.
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.dev_runner_config (key, value)
values ('runner_health', jsonb_build_object(
  'enabled',               true,
  'probe_s',               60,
  'idle_probe_s',          600,
  'green_score',           80,
  'amber_score',           60,
  'red_score',             40,
  'sem_green',             3,
  'sem_amber',             2,
  'sem_red',               1,
  'sem_black',             0,
  'green_streak_required', 3,
  'max_streak_required',   15,
  'cooldown_window_min',   15,
  'latency_ok_ms',         50,
  'latency_bad_ms',        1500,
  'conn_ok_pct',           65,
  'conn_bad_pct',          90,
  'cpu_ok_pct',            70,
  'cpu_bad_pct',           98,
  'retain_days',           7,
  'manual',                jsonb_build_object('workflow', null, 'at', null, 'by', null),
  'note', 'CHANGE #755 — score bands drive worker_pool.build_semaphore. Manual Workflow OFF always wins; a manual ON is only overridden downward by score < red_score.'
))
on conflict (key) do nothing;

-- build_semaphore is the supervisor''s worker-count target and it is clamped up
-- to worker_pool.min. min was 3, which made every band below 3 unreachable —
-- adaptive concurrency cannot exist with a floor equal to the ceiling. 1 is
-- also what the quota guard''s own comment already claimed it was ("the single
-- base worker still runs the queue serially").
update public.dev_runner_config
   set value = jsonb_set(value, '{min}', to_jsonb(1))
 where key = 'worker_pool'
   and coalesce((value->>'min')::int, 1) <> 1;

create or replace function public._runner_health_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce((select value from public.dev_runner_config where key = 'runner_health'),
                  '{}'::jsonb);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE PROBE'S INPUTS
-- ─────────────────────────────────────────────────────────────────────────────

-- Top-3 slowest calls since a moment. Two independent sources, because they see
-- different failures: db_timeout_event knows which RPC was CANCELLED, while
-- pg_stat_statements knows what is merely slow and has not been cancelled yet.
create or replace function public._runner_slow_calls(p_since timestamptz)
returns jsonb language plpgsql stable security definer
set search_path to 'public', 'pg_catalog' as $$
declare v jsonb := '[]'::jsonb; v_pgss jsonb := '[]'::jsonb;
begin
  select coalesce(jsonb_agg(x order by x.n desc), '[]'::jsonb) into v
  from (
    select coalesce(
             nullif(e.detail->>'rpc', ''),
             (regexp_match(coalesce(e.detail->>'query',''),
                           '(?:public\.)"?([a-z_][a-z0-9_]{2,})"?\s*\('))[1],
             nullif(e.detail->>'kind',''),
             'unknown') as fn,
           count(*)::int as n,
           max(coalesce((e.detail->>'seconds')::numeric, 0)) as worst_s
      from public.db_timeout_event e
     where e.at > p_since
     group by 1
     order by 2 desc, 3 desc
     limit 3
  ) x(fn, n, worst_s);

  begin
    select coalesce(jsonb_agg(y order by y.mean_ms desc), '[]'::jsonb) into v_pgss
    from (
      select coalesce((regexp_match(s.query, '(?:public\.)"?([a-z_][a-z0-9_]{2,})"?\s*\('))[1],
                      left(regexp_replace(s.query, '\s+', ' ', 'g'), 60)) as fn,
             round(s.mean_exec_time::numeric, 1) as mean_ms,
             s.calls::bigint as calls
        from pg_stat_statements s
       where s.calls > 3
         and s.mean_exec_time > 250
       order by s.mean_exec_time desc
       limit 3
    ) y(fn, mean_ms, calls);
  exception when others then v_pgss := '[]'::jsonb;
  end;

  return jsonb_build_object('cancelled', v, 'slowest', v_pgss, 'since', p_since);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE TRIP — one place, so the watchdog and the probe cannot disagree
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.runner_breaker_trip(
  p_reason text, p_score int default null, p_detail jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_catalog' as $$
declare
  cfg jsonb; b jsonb; v_prev_at timestamptz; v_prev_req int; v_prev_seq int;
  v_seq int := 1; v_req int; v_cool int; v_slow jsonb; v_fn text;
  v_title text; v_open bigint; v_new bigint; v_since timestamptz; v_state jsonb;
  v_was_on boolean;
begin
  cfg := _runner_health_cfg();
  select value into b from public.dev_runner_config where key = 'db_breaker';
  b := coalesce(b, '{}'::jsonb);

  -- Already tripped and nobody cleared it: this is the same episode, not a new
  -- one. Re-tripping would inflate the sequence and re-file the same command.
  if coalesce((b->>'tripped')::boolean, false) then
    return jsonb_build_object('ok', true, 'already_tripped', true, 'state', b);
  end if;

  v_cool := greatest(coalesce((cfg->>'cooldown_window_min')::int, 15), 1);
  v_req  := greatest(coalesce((cfg->>'green_streak_required')::int, 3), 1);

  begin v_prev_at := (b#>>'{last,at}')::timestamptz; exception when others then v_prev_at := null; end;
  v_prev_req := coalesce((b#>>'{last,required_streak}')::int, v_req);
  v_prev_seq := coalesce((b#>>'{last,trip_seq}')::int, 0);

  -- ESCALATING COOLDOWN. A second trip inside the window doubles the green
  -- streak the fleet must show before it may come back, capped so the wait can
  -- never exceed max_streak_required probes (~15 min at a 60 s probe).
  if v_prev_at is not null and v_prev_at > now() - make_interval(mins => v_cool) then
    v_seq := v_prev_seq + 1;
    v_req := least(greatest(v_prev_req, 1) * 2,
                   greatest(coalesce((cfg->>'max_streak_required')::int, 15), v_req));
  end if;

  v_since := coalesce(v_prev_at, now() - make_interval(mins => v_cool));
  v_slow  := _runner_slow_calls(v_since);
  v_fn    := coalesce(v_slow#>>'{cancelled,0,fn}', v_slow#>>'{slowest,0,fn}');

  -- Pause the fleet: Workflow off IS the "semaphore 0" band.
  select coalesce(value->>'workflow','off') = 'on' into v_was_on
    from public.dev_runner_config where key = 'desired_state';
  update public.dev_runner_config
     set value = jsonb_set(value, '{workflow}', to_jsonb('off'::text))
   where key = 'desired_state';
  update public.dev_runner_config
     set value = jsonb_set(value, '{build_semaphore}',
                           to_jsonb(coalesce((cfg->>'sem_black')::int, 0)))
   where key = 'worker_pool';

  v_state := jsonb_build_object(
    'tripped',         true,
    'at',              now(),
    'reason',          p_reason,
    'score',           p_score,
    'trip_seq',        v_seq,
    'required_streak', v_req,
    'prev_trip_at',    v_prev_at,
    'slow_calls',      v_slow,
    'was_on',          v_was_on)
    || coalesce(p_detail, '{}'::jsonb);

  -- FILE THE WORK. One command per distinct slow call, deduped against an open
  -- one, so a flapping database cannot fill the queue with the same row.
  if v_fn is not null and v_fn <> 'unknown' then
    v_title := 'Slow call: ' || v_fn || ' — bound it';
    select c.id into v_open from public.dev_commands c
     where c.title = v_title and c.status in ('pending','building','needs_input')
     order by c.id desc limit 1;
    if v_open is null then
      insert into public.dev_commands (title, spec, urgent, priority, kind, qa_required, targets_web)
      values (v_title,
        'The runner breaker tripped and named this call as the worst offender.' || E'\n\n'
        || 'Trip: ' || p_reason || E'\n'
        || 'Health score at the trip: ' || coalesce(p_score::text, 'n/a') || E'\n'
        || 'Trip sequence in this episode: ' || v_seq || E'\n\n'
        || 'Evidence (top calls since the previous trip at '
        || coalesce(to_char(v_since at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'), '—') || ' IST):' || E'\n'
        || jsonb_pretty(v_slow) || E'\n\n'
        || 'Bound it: give the call a hard ceiling on the rows it can touch, add the '
        || 'index or the set-based rewrite it is missing, and prove the new shape with '
        || 'explain (analyze, buffers). Heavy work belongs in the db_work_lock lane '
        || '(devcmd.sh dblock) or on the cron dispatcher, never on an HTTP path. '
        || 'Finish with devcmd.sh rgcheck printing true.',
        true, 1, 'dev', false, false)
      returning id into v_new;
      v_state := v_state || jsonb_build_object('filed_command', v_new);
    else
      v_state := v_state || jsonb_build_object('filed_command', v_open, 'filed_deduped', true);
    end if;
  end if;

  update public.dev_runner_config set value = v_state where key = 'db_breaker';

  insert into public.dev_runner_breaker_event (kind, score, semaphore, reason, detail)
  values ('trip', p_score, coalesce((cfg->>'sem_black')::int, 0), p_reason, v_state);

  insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
  values (md5('db_breaker|' || to_char(now(),'YYYY-MM-DD HH24:MI')),
          'critical', 'db_breaker',
          format('auto-paused: %s — Workflow off, resuming after %s green probe(s)',
                 p_reason, v_req),
          v_state)
  on conflict (fingerprint) do update set last_seen = now(),
    seen_count = public.rg_alerts.seen_count + 1, detail = excluded.detail;

  begin perform _audit('system','db_breaker_trip', null, v_state); exception when others then null; end;

  -- WHATSAPP ON THE SECOND TRIP ONLY. The first trip is the system doing its
  -- job and resuming itself; the second inside the window is the one that
  -- means the database is not recovering on its own.
  if v_seq >= 2 then
    begin
      perform wa_send_event('dev_cmd_daily_digest', null, jsonb_build_object(
        'done','0','failed','0','pending','0',
        'titles', format('⚠ breaker tripped %sx in %s min — %s. Worst call: %s. Auto-resume needs %s green probes.',
                         v_seq, v_cool, p_reason, coalesce(v_fn,'n/a'), v_req)), null, null);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'tripped', true, 'state', v_state,
                            'trip_seq', v_seq, 'required_streak', v_req,
                            'filed_command', v_state->'filed_command');
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE PROBE
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.runner_health_probe()
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_catalog'
set statement_timeout to '8s' as $$
declare
  cfg jsonb; wp jsonb; ds jsonb; b jsonb;
  v_t0 timestamptz; v_samples numeric[] := '{}'; v_i int;
  v_lat numeric; v_conns int; v_max int; v_pct numeric;
  v_to int; v_tr int; v_cpu numeric; v_ram numeric;
  v_score numeric := 100; v_pen numeric;
  v_green int; v_amber int; v_red int; v_target int; v_cur int; v_next int;
  v_streak int; v_req int; v_action text := 'hold'; v_wf text;
  v_manual text; v_tripped boolean; v_reason text := ''; v_res jsonb;
  v_bcount int; v_bwin int; v_thresh int;
begin
  cfg := _runner_health_cfg();
  if not coalesce((cfg->>'enabled')::boolean, true) then
    return jsonb_build_object('ok', true, 'enabled', false);
  end if;

  select value into wp from public.dev_runner_config where key = 'worker_pool';
  select value into ds from public.dev_runner_config where key = 'desired_state';
  select value into b  from public.dev_runner_config where key = 'db_breaker';
  wp := coalesce(wp,'{}'::jsonb); ds := coalesce(ds,'{}'::jsonb); b := coalesce(b,'{}'::jsonb);
  v_wf      := coalesce(ds->>'workflow','off');
  v_manual  := cfg#>>'{manual,workflow}';
  v_tripped := coalesce((b->>'tripped')::boolean, false);

  -- (a) p95 latency of a trivial query. Seven real index lookups; the whole
  --     measurement costs microseconds and is the only thing here that would
  --     notice a database that is up but crawling.
  for v_i in 1..7 loop
    v_t0 := clock_timestamp();
    perform 1 from public.dev_runner_config where key = 'desired_state';
    v_samples := v_samples || (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::numeric;
  end loop;
  select round(percentile_cont(0.95) within group (order by s)::numeric, 3)
    into v_lat from unnest(v_samples) s;

  -- (b) connections
  select count(*)::int into v_conns from pg_stat_activity where datname = current_database();
  v_max := coalesce(nullif(current_setting('max_connections', true), '')::int, 60);
  v_pct := round(100.0 * v_conns / greatest(v_max,1), 1);

  -- (c) timeouts and transport failures in the last 5 minutes. transport_blackout
  --     is the client-observed 503/unreachable class: PostgREST answered nothing
  --     at all, which is strictly worse than a statement that timed out.
  select count(*)::int,
         count(*) filter (where detail->>'kind' = 'transport_blackout')::int
    into v_to, v_tr
    from public.db_timeout_event where at > now() - interval '5 minutes';

  -- (d) CPU / RAM. The VM publishes them on its pool heartbeat; db_health_sample
  --     is the named home for host vitals, so the probe MIRRORS them onto the
  --     newest sample row and then reads that row. A box that has not reported
  --     yet leaves both null and the CPU term simply does not apply.
  select (value->>'cpu_pct')::numeric, (value->>'ram_pct')::numeric
    into v_cpu, v_ram
    from public.dev_runner_config where key = 'pool_state';
  if v_cpu is not null or v_ram is not null then
    -- BEST EFFORT, ALWAYS. db_watchdog_tick writes this table on the same
    -- minute the probe runs, so the mirror can lose a race for the row — and a
    -- health probe that dies because it could not annotate a sample is a
    -- watchdog that takes the fleet down to report that the fleet is fine.
    begin
      update public.db_health_sample s
         set detail = s.detail
                      || case when v_cpu is not null
                              then jsonb_build_object('host_cpu_pct', v_cpu) else '{}'::jsonb end
                      || case when v_ram is not null
                              then jsonb_build_object('host_ram_pct', v_ram) else '{}'::jsonb end
       where s.at = (select max(at) from public.db_health_sample);
    exception when others then null;
    end;
  end if;
  select coalesce(v_cpu, (detail->>'host_cpu_pct')::numeric),
         coalesce(v_ram, (detail->>'host_ram_pct')::numeric)
    into v_cpu, v_ram
    from public.db_health_sample order by at desc limit 1;

  -- ── the score ────────────────────────────────────────────────────────────
  v_pen := greatest(0, least(30,
    30 * (v_lat - coalesce((cfg->>'latency_ok_ms')::numeric, 50))
       / greatest(coalesce((cfg->>'latency_bad_ms')::numeric, 1500)
                  - coalesce((cfg->>'latency_ok_ms')::numeric, 50), 1)));
  v_score := v_score - v_pen;

  v_pen := greatest(0, least(25,
    25 * (v_pct - coalesce((cfg->>'conn_ok_pct')::numeric, 65))
       / greatest(coalesce((cfg->>'conn_bad_pct')::numeric, 90)
                  - coalesce((cfg->>'conn_ok_pct')::numeric, 65), 1)));
  v_score := v_score - v_pen;

  -- Timeouts are scaled against the BREAKER's own threshold, so the score and
  -- the breaker can never disagree about what "ten in five minutes" means:
  -- a full threshold of timeouts costs 70 points and lands the score in the
  -- black band on its own.
  v_thresh := greatest(coalesce((wp#>>'{rpc_watchdog,breaker_count}')::int, 10), 1);
  v_bwin   := greatest(coalesce((wp#>>'{rpc_watchdog,breaker_window_min}')::int, 5), 1);
  v_score  := v_score - least(70, 70.0 * v_to / v_thresh);
  if v_tr > 0 then v_score := v_score - 10; end if;

  if v_cpu is not null then
    v_pen := greatest(0, least(15,
      15 * (v_cpu - coalesce((cfg->>'cpu_ok_pct')::numeric, 70))
         / greatest(coalesce((cfg->>'cpu_bad_pct')::numeric, 98)
                    - coalesce((cfg->>'cpu_ok_pct')::numeric, 70), 1)));
    v_score := v_score - v_pen;
  end if;

  v_score := greatest(0, least(100, round(v_score)));

  -- ── bands ────────────────────────────────────────────────────────────────
  v_green := coalesce((cfg->>'green_score')::int, 80);
  v_amber := coalesce((cfg->>'amber_score')::int, 60);
  v_red   := coalesce((cfg->>'red_score')::int,   40);
  v_target := case
    when v_score >= v_green then coalesce((cfg->>'sem_green')::int, 3)
    when v_score >= v_amber then coalesce((cfg->>'sem_amber')::int, 2)
    when v_score >= v_red   then coalesce((cfg->>'sem_red')::int,   1)
    else                         coalesce((cfg->>'sem_black')::int, 0) end;
  v_cur := coalesce((wp->>'build_semaphore')::int, v_target);

  -- ── the green streak ─────────────────────────────────────────────────────
  -- Green for the purposes of coming back means "at or above amber": the
  -- fleet resumes at reduced concurrency, it does not wait for perfect.
  select coalesce(green_streak, 0) into v_streak
    from public.dev_runner_health order by at desc limit 1;
  v_streak := case when v_score >= v_amber then coalesce(v_streak,0) + 1 else 0 end;

  v_req := greatest(coalesce((b->>'required_streak')::int,
                             coalesce((cfg->>'green_streak_required')::int, 3)), 1);

  -- ── act ──────────────────────────────────────────────────────────────────
  if v_score < v_red then
    -- Black band. This IS the pause; runner_breaker_trip is idempotent while a
    -- trip is already open, so a sustained bad patch trips exactly once.
    v_reason := format('health score %s (< %s): %s DB timeout(s) in %s min, p95 %s ms, %s of %s connections',
                       v_score, v_red, v_to, v_bwin, v_lat, v_conns, v_max);
    if not v_tripped and v_wf = 'on' then
      v_res := runner_breaker_trip(v_reason, v_score::int,
                 jsonb_build_object('source','probe','timeouts_5min',v_to,
                                    'latency_p95_ms',v_lat,'conns',v_conns));
      v_action := 'trip';
    else
      v_action := 'paused';
    end if;
    v_target := coalesce((cfg->>'sem_black')::int, 0);
    v_streak := 0;
    v_tripped := true;

  elsif v_tripped then
    -- A tripped breaker is not scaled, it is RESUMED. Letting the scale-up
    -- branch spend the green streak here is how the auto-resume never happens:
    -- it would consume the third green probe to move the semaphore 0 -> 1 and
    -- reset the streak the resume was waiting on.
    v_action := 'awaiting_resume';
    v_target := v_cur;

  elsif v_target < v_cur then
    -- DOWN IS IMMEDIATE. Pressure does not get a grace period.
    update public.dev_runner_config
       set value = jsonb_set(value, '{build_semaphore}', to_jsonb(v_target))
     where key = 'worker_pool';
    v_action := 'scale_down';
    v_reason := format('score %s — parallel builds %s → %s', v_score, v_cur, v_target);
    insert into public.dev_runner_breaker_event (kind, score, semaphore, reason, detail)
    values ('scale_down', v_score::int, v_target, v_reason,
            jsonb_build_object('from', v_cur, 'to', v_target, 'timeouts_5min', v_to));

  elsif v_target > v_cur and v_streak >= greatest(coalesce((cfg->>'green_streak_required')::int, 3), 1) then
    -- UP IS ONE STEP PER THREE CONSECUTIVE GREEN PROBES.
    v_next := v_cur + 1;
    update public.dev_runner_config
       set value = jsonb_set(value, '{build_semaphore}', to_jsonb(v_next))
     where key = 'worker_pool';
    v_action := 'scale_up';
    v_reason := format('score %s held green — parallel builds %s → %s', v_score, v_cur, v_next);
    insert into public.dev_runner_breaker_event (kind, score, semaphore, reason, detail)
    values ('scale_up', v_score::int, v_next, v_reason,
            jsonb_build_object('from', v_cur, 'to', v_next, 'streak', v_streak));
    v_target := v_next;
    v_streak := 0;   -- the next step needs its own three greens
  else
    v_target := v_cur;
  end if;

  -- ── auto-resume ──────────────────────────────────────────────────────────
  -- Only from a TRIPPED breaker, only on a held green streak, and never over a
  -- manual OFF: Om's switch is the one thing this must not fight.
  if v_tripped and v_score >= v_amber and v_streak >= v_req then
    if coalesce(v_manual, 'on') = 'off' then
      v_action := 'blocked_manual';
      v_reason := 'workflow was switched off by hand — auto-resume stands down';
    else
      v_target := case
        when v_score >= v_green then coalesce((cfg->>'sem_green')::int, 3)
        when v_score >= v_amber then coalesce((cfg->>'sem_amber')::int, 2)
        else                         coalesce((cfg->>'sem_red')::int, 1) end;
      update public.dev_runner_config
         set value = jsonb_set(value, '{workflow}', to_jsonb('on'::text))
       where key = 'desired_state';
      update public.dev_runner_config
         set value = jsonb_set(value, '{build_semaphore}', to_jsonb(v_target))
       where key = 'worker_pool';
      update public.dev_runner_config
         set value = jsonb_build_object('tripped', false, 'cleared_at', now(),
                                        'auto', true, 'auto_resumed_at', now(),
                                        'resumed_score', v_score, 'last', value)
       where key = 'db_breaker';
      v_action := 'auto_resume';
      v_reason := format('score %s for %s consecutive probe(s) — Workflow back on at %s parallel',
                         v_score, v_streak, v_target);
      insert into public.dev_runner_breaker_event (kind, score, semaphore, reason, detail)
      values ('resume', v_score::int, v_target, v_reason,
              jsonb_build_object('streak', v_streak, 'required', v_req, 'auto', true));
      begin perform _audit('system','db_breaker_auto_resume', null,
                jsonb_build_object('score', v_score, 'streak', v_streak,
                                   'semaphore', v_target)); exception when others then null; end;
      v_streak := 0;
      v_tripped := false;
      -- a resumed fleet has work waiting: probe again on the next tick
      insert into public.cron_signal (task) values ('runner_health_probe')
        on conflict (task) do update set last_at = now(), n = public.cron_signal.n + 1;
    end if;
  end if;

  insert into public.dev_runner_health (at, score, latency_p95_ms, conns, max_conns,
      timeouts_5min, transport_5min, cpu_pct, ram_pct, semaphore, green_streak,
      workflow, action, detail)
  values (date_trunc('second', now()), v_score::int, v_lat, v_conns, v_max,
      v_to, v_tr, v_cpu, v_ram, v_target, v_streak,
      coalesce((select value->>'workflow' from public.dev_runner_config where key='desired_state'), v_wf),
      v_action,
      jsonb_build_object('reason', v_reason, 'target', v_target, 'was', v_cur,
                         'tripped', v_tripped, 'required_streak', v_req,
                         'conn_pct', v_pct, 'manual', v_manual))
  on conflict (at) do update set
      score = excluded.score, latency_p95_ms = excluded.latency_p95_ms,
      conns = excluded.conns, timeouts_5min = excluded.timeouts_5min,
      transport_5min = excluded.transport_5min, semaphore = excluded.semaphore,
      green_streak = excluded.green_streak, action = excluded.action,
      detail = excluded.detail;

  delete from public.dev_runner_health
   where at < now() - make_interval(days => greatest(coalesce((cfg->>'retain_days')::int, 7), 1));
  delete from public.dev_runner_breaker_event
   where at < now() - interval '30 days';

  return jsonb_build_object('ok', true, 'score', v_score, 'semaphore', v_target,
    'green_streak', v_streak, 'required_streak', v_req, 'action', v_action,
    'reason', v_reason, 'latency_p95_ms', v_lat, 'conns', v_conns, 'max_conns', v_max,
    'timeouts_5min', v_to, 'transport_5min', v_tr, 'tripped', v_tripped);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. WAKING THE PROBE — it is parked, not dead
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.runner_health_wake()
returns void language plpgsql security definer
set search_path to 'public' as $$
begin
  insert into public.cron_signal (task) values ('runner_health_probe')
    on conflict (task) do update set last_at = now(), n = public.cron_signal.n + 1;
exception when others then null;
end $$;

create or replace function public._runner_health_wake_trg()
returns trigger language plpgsql security definer
set search_path to 'public' as $$
begin
  perform public.runner_health_wake();
  return null;
end $$;

drop trigger if exists dev_commands_health_wake_ins on public.dev_commands;
create trigger dev_commands_health_wake_ins
  after insert on public.dev_commands
  for each row when (new.status = 'pending')
  execute function public._runner_health_wake_trg();

drop trigger if exists dev_commands_health_wake_upd on public.dev_commands;
create trigger dev_commands_health_wake_upd
  after update of status on public.dev_commands
  for each row when (old.status is distinct from new.status and new.status = 'building')
  execute function public._runner_health_wake_trg();

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE CRON ROW — bounded by its own gate, never free-running
-- ─────────────────────────────────────────────────────────────────────────────
-- Om's rule, verbatim: probe every 60 s ONLY while Workflow is on AND at least
-- one command is pending/building; if VM or Claude is off, or the queue is
-- idle, the probe stops entirely. The gate below is that sentence in SQL. When
-- it is false the dispatcher records a skip and DOUBLES the interval to the
-- 600 s ceiling — so an idle hour costs zero runs and about nine cheap gate
-- reads, settling at one every ten minutes. The one addition is a tripped
-- breaker: it keeps probing while work waits, because the auto-resume is the
-- probe. cron_signal (runner_health_wake) puts it straight back on 60 s the
-- moment a command is added, a command starts building, or Om flips Workflow on.

insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note,
   base_interval_s, max_interval_s, current_interval_s, next_run_at, dml)
values (
  'runner_health_probe', 4, 'poll',
  $gate$
  select coalesce((select value->>'vm'     from public.dev_runner_config where key='desired_state'),'off') = 'on'
     and coalesce((select value->>'claude' from public.dev_runner_config where key='desired_state'),'off') = 'on'
     and exists (select 1 from public.dev_commands where status in ('pending','building'))
     and (
           coalesce((select value->>'workflow' from public.dev_runner_config where key='desired_state'),'off') = 'on'
        or coalesce((select (value->>'tripped')::boolean from public.dev_runner_config where key='db_breaker'), false)
         )
  $gate$,
  'select public.runner_health_probe()',
  9000, true,
  'CHANGE #755 — the self-healing breaker''s health probe. Gated: VM+Claude on, a command pending/building, and Workflow on (or the breaker tripped and waiting to resume). Idle => zero runs, gate backs off to 600 s; cron_signal wakes it on the next claim or Workflow ON.',
  60, 600, 60, now(), false)
on conflict (name) do update set
  gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
  step_timeout_ms = excluded.step_timeout_ms, enabled = excluded.enabled,
  note = excluded.note, base_interval_s = excluded.base_interval_s,
  max_interval_s = excluded.max_interval_s, ord = excluded.ord, dml = excluded.dml;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE WATCHDOG'S TRIP NOW GOES THROUGH THE ONE TRIP FUNCTION
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.db_rpc_watchdog_tick()
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_catalog'
set statement_timeout to '10s' as $$
declare
  cfg jsonb; v_on boolean; v_after int; v_count int; v_win int;
  rec record; v_killed int := 0; v_list jsonb := '[]'::jsonb;
  v_recent int; v_wf text; v_tripped boolean := false; v_res jsonb;
begin
  select coalesce(value->'rpc_watchdog','{}'::jsonb) into cfg
    from dev_runner_config where key = 'worker_pool';
  v_on    := coalesce((cfg->>'enabled')::boolean, true);
  v_after := coalesce((cfg->>'cancel_after_s')::int, 90);
  v_count := coalesce((cfg->>'breaker_count')::int, 10);
  v_win   := coalesce((cfg->>'breaker_window_min')::int, 5);
  if not v_on then return jsonb_build_object('ok', true, 'enabled', false); end if;

  -- A PostgREST backend still running past the deadline is, by definition, work
  -- nobody is waiting for any more: devcmd.sh gives up at 60 s. Leaving it to
  -- run is how one abandoned rg_check became 98 of them.
  for rec in
    select a.pid, a.usename,
           round(extract(epoch from (clock_timestamp() - a.query_start)))::int as secs,
           left(a.query, 300) as q
      from pg_stat_activity a
     where a.datname = current_database()
       and a.state = 'active'
       and a.usename = 'authenticator'
       and a.application_name like 'PostgREST%'
       and a.pid <> pg_backend_pid()
       and a.query_start < clock_timestamp() - make_interval(secs => v_after)
     order by a.query_start
     limit 20
  loop
    begin
      if pg_cancel_backend(rec.pid) then
        v_killed := v_killed + 1;
        v_list := v_list || jsonb_build_object('pid', rec.pid, 'seconds', rec.secs,
                                               'query', rec.q);
        perform db_timeout_report('rpc-watchdog', jsonb_build_object(
          'kind', 'rpc_watchdog_cancel', 'pid', rec.pid, 'seconds', rec.secs,
          'cancel_after_s', v_after, 'query', rec.q));
      end if;
    exception when others then
      perform db_timeout_report('rpc-watchdog', jsonb_build_object(
        'kind', 'rpc_watchdog_cancel_failed', 'pid', rec.pid,
        'seconds', rec.secs, 'error', left(SQLERRM, 200)));
    end;
  end loop;

  if v_killed > 0 then
    insert into rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('rpc_watchdog|' || to_char(date_trunc('hour', now()),'YYYY-MM-DD HH24')),
            'warn', 'rpc_watchdog',
            format('cancelled %s PostgREST call(s) running over %ss', v_killed, v_after),
            jsonb_build_object('killed', v_killed, 'cancel_after_s', v_after, 'calls', v_list))
    on conflict (fingerprint) do update set last_seen = now(),
      seen_count = rg_alerts.seen_count + 1, detail = excluded.detail;
  end if;

  -- ── the circuit breaker (CHANGE #755: one trip function, one policy) ──────
  -- The watchdog still owns the threshold it always owned; what it no longer
  -- owns is what a trip MEANS. Naming the slow calls, filing the command, the
  -- escalating cooldown and the WhatsApp all live in runner_breaker_trip so the
  -- probe and the watchdog cannot drift apart.
  select count(*) into v_recent from db_timeout_event
   where at > now() - make_interval(mins => v_win);

  select coalesce(value->>'workflow','off') into v_wf
    from dev_runner_config where key = 'desired_state';

  if v_recent >= v_count and v_wf = 'on' then
    v_res := runner_breaker_trip(
      format('%s DB timeouts in %s min', v_recent, v_win), null,
      jsonb_build_object('source','rpc_watchdog','count',v_recent,
                         'window_min',v_win,'threshold',v_count));
    v_tripped := coalesce((v_res->>'tripped')::boolean, false);
  end if;

  return jsonb_build_object('ok', true, 'killed', v_killed,
    'timeouts_in_window', v_recent, 'window_min', v_win,
    'threshold', v_count, 'breaker_tripped', v_tripped);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE MANUAL FLAG — Om's switch is recorded, so the machine can defer to it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.dev_ctl_set(p_key text, p_value text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v jsonb;
BEGIN
  PERFORM _dev_guard();
  IF p_key NOT IN ('vm','claude','workflow') THEN RAISE EXCEPTION 'dev_ctl_set: bad key'; END IF;
  IF p_value NOT IN ('on','off') THEN RAISE EXCEPTION 'dev_ctl_set: bad value'; END IF;
  IF (_sec_cfg()->>'frozen')::boolean AND p_value='on' THEN RAISE EXCEPTION 'frozen — unlock with PIN first'; END IF;
  UPDATE dev_runner_config SET value = jsonb_set(value, ARRAY[p_key], to_jsonb(p_value)) WHERE key='desired_state'
  RETURNING value INTO v;
  PERFORM _audit(_actor(),'toggle_set', p_key, jsonb_build_object('value',p_value));

  -- CHANGE #755 — a HUMAN flip is remembered as a manual flag. The self-healing
  -- controller reads it and stands down: a manual OFF is never auto-resumed
  -- over, and a manual ON is only taken back down by a score in the black band.
  -- The auto path never comes through here, so it can never forge this flag.
  IF p_key = 'workflow' THEN
    UPDATE dev_runner_config
       SET value = jsonb_set(coalesce(value,'{}'::jsonb), '{manual}',
             jsonb_build_object('workflow', p_value, 'at', now(), 'by', _actor()))
     WHERE key = 'runner_health';
    INSERT INTO dev_runner_breaker_event (kind, reason, detail)
    VALUES ('manual', 'Workflow switched ' || p_value || ' by hand',
            jsonb_build_object('value', p_value, 'by', _actor()));
  END IF;

  -- Turning Workflow back on IS the acknowledgement: the badge clears with it,
  -- so it can never outlive the pause it is describing.
  IF p_key = 'workflow' AND p_value = 'on' THEN
    UPDATE dev_runner_config
       SET value = jsonb_build_object('tripped', false, 'cleared_at', now(),
                                      'auto', false, 'last', value)
     WHERE key = 'db_breaker' AND coalesce((value->>'tripped')::boolean, false);
    -- The queue is live again: put the probe back on its 60 s cadence now
    -- rather than at the end of the idle back-off.
    PERFORM runner_health_wake();
  END IF;

  IF p_key = 'vm' THEN
    UPDATE dev_runner_config
       SET value = coalesce(value,'{}'::jsonb) || jsonb_build_object('awaiting_edge', true)
     WHERE key = 'vm_status';
    RETURN jsonb_build_object('ok',true,'desired_state',v,
      'call_edge', true,
      'action',    CASE WHEN p_value='on' THEN 'start' ELSE 'stop' END);
  END IF;

  RETURN jsonb_build_object('ok',true,'desired_state',v);
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. THE BADGE — a pause that ended by itself says so
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._dev_breaker_badge()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare b jsonb; v_at timestamptz; v_res timestamptz;
begin
  select value into b from dev_runner_config where key = 'db_breaker';
  b := coalesce(b, '{}'::jsonb);

  if not coalesce((b->>'tripped')::boolean, false) then
    -- CHANGE #755 — an auto-resume is news for as long as it is fresh: it is
    -- the difference between "Om flipped it back" and "it healed itself".
    begin v_res := (b->>'auto_resumed_at')::timestamptz; exception when others then v_res := null; end;
    if coalesce((b->>'auto')::boolean, false) and v_res is not null
       and v_res > now() - interval '2 hours' then
      return jsonb_build_object(
        'tripped', false, 'auto_resumed', true, 'tone', 'success',
        'label', replace(coalesce((select value#>>'{}' from ui_copy where key='dev_queue.breaker_auto_resumed'), ''),
                         '{at}', to_char(v_res at time zone 'Asia/Kolkata', 'HH24:MI')),
        'detail', replace(coalesce((select value#>>'{}' from ui_copy where key='dev_queue.breaker_auto_detail'), ''),
                          '{score}', coalesce(b->>'resumed_score','?')),
        'at', v_res);
    end if;
    return jsonb_build_object('tripped', false, 'auto_resumed', false,
                              'label', '', 'detail', '', 'tone', 'neutral');
  end if;

  begin v_at := (b->>'at')::timestamptz; exception when others then v_at := null; end;
  return jsonb_build_object(
    'tripped', true,
    'tone',    'danger',
    'label',   coalesce((select value#>>'{}' from ui_copy where key='dev_queue.breaker_label'), ''),
    'detail',  replace(replace(replace(replace(
        coalesce((select value#>>'{}' from ui_copy where key='dev_queue.breaker_detail'), ''),
        '{n}',   coalesce(b->>'count', b->>'reason', '?')),
        '{win}', coalesce(b->>'window_min','?')),
        '{at}',  coalesce(to_char(v_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'), '—')),
        '{need}', coalesce(b->>'required_streak','?')),
    'at', v_at, 'count', b->'count', 'window_min', b->'window_min',
    'reason', b->>'reason', 'required_streak', b->'required_streak',
    'trip_seq', b->'trip_seq', 'slow_calls', b->'slow_calls',
    'filed_command', b->'filed_command');
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. THE CARD — one payload, printed verbatim by the runner control panel
-- ─────────────────────────────────────────────────────────────────────────────
-- Nothing here is computed in Dart: every number arrives already formatted,
-- every label comes from ui_copy, every tone is chosen server-side.

-- A copy helper with token substitution, so no display string is ever built in
-- Dart and a wording change is an UPDATE on ui_copy, never a deploy.
create or replace function public.c755_copy(p_key text, p_tokens jsonb)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v text; k text;
begin
  select value#>>'{}' into v from ui_copy where key = p_key;
  v := coalesce(v, '');
  for k in select jsonb_object_keys(coalesce(p_tokens,'{}'::jsonb)) loop
    v := replace(v, '{' || k || '}', coalesce(p_tokens->>k, ''));
  end loop;
  return v;
end $$;

create or replace function public.runner_health_card()
returns jsonb language plpgsql stable security definer
set search_path to 'public', 'pg_catalog' as $$
declare
  cfg jsonb; wp jsonb; ds jsonb; b jsonb; h public.dev_runner_health%rowtype;
  t public.cron_task%rowtype;
  v_green int; v_amber int; v_red int; v_req int; v_sem int; v_tone text;
  v_active boolean; v_manual text; v_next text; v_metrics jsonb; v_hist jsonb;
  v_up_need int; v_target int; v_probe_s int; v_tripped boolean;
begin
  cfg := _runner_health_cfg();
  select value into wp from public.dev_runner_config where key = 'worker_pool';
  select value into ds from public.dev_runner_config where key = 'desired_state';
  select value into b  from public.dev_runner_config where key = 'db_breaker';
  wp := coalesce(wp,'{}'::jsonb); ds := coalesce(ds,'{}'::jsonb); b := coalesce(b,'{}'::jsonb);
  select * into h from public.dev_runner_health order by at desc limit 1;
  select * into t from public.cron_task where name = 'runner_health_probe';

  v_green := coalesce((cfg->>'green_score')::int, 80);
  v_amber := coalesce((cfg->>'amber_score')::int, 60);
  v_red   := coalesce((cfg->>'red_score')::int,   40);
  v_up_need := greatest(coalesce((cfg->>'green_streak_required')::int, 3), 1);
  v_req   := greatest(coalesce((b->>'required_streak')::int, v_up_need), 1);
  v_sem   := coalesce((wp->>'build_semaphore')::int, 0);
  v_probe_s := coalesce((cfg->>'probe_s')::int, 60);
  v_manual  := cfg#>>'{manual,workflow}';
  v_tripped := coalesce((b->>'tripped')::boolean, false);

  v_tone := case when h.score is null then 'neutral'
                 when h.score >= v_green then 'success'
                 when h.score >= v_amber then 'info'
                 when h.score >= v_red   then 'warning'
                 else 'danger' end;

  v_active := coalesce(ds->>'vm','off') = 'on'
          and coalesce(ds->>'claude','off') = 'on'
          and exists (select 1 from public.dev_commands where status in ('pending','building'))
          and (coalesce(ds->>'workflow','off') = 'on' or v_tripped);

  v_target := case when h.score is null then v_sem
                   when h.score >= v_green then coalesce((cfg->>'sem_green')::int, 3)
                   when h.score >= v_amber then coalesce((cfg->>'sem_amber')::int, 2)
                   when h.score >= v_red   then coalesce((cfg->>'sem_red')::int,   1)
                   else 0 end;

  -- ── the one sentence that says what happens next ─────────────────────────
  v_next := case
    when h.score is null then
      c755_copy('dev_queue.health_next_none', '{}'::jsonb)
    when v_tripped and coalesce(v_manual,'on') = 'off' then
      c755_copy('dev_queue.health_next_manual_off', '{}'::jsonb)
    when v_tripped then
      c755_copy('dev_queue.health_next_paused',
        jsonb_build_object('need', v_req, 'have', coalesce(h.green_streak,0)))
    when v_target < v_sem then
      c755_copy('dev_queue.health_next_down', jsonb_build_object('sem', v_target))
    when v_target > v_sem then
      c755_copy('dev_queue.health_next_up',
        jsonb_build_object('next', v_sem + 1,
                           'left', greatest(v_up_need - coalesce(h.green_streak,0), 0)))
    else
      c755_copy('dev_queue.health_next_hold', jsonb_build_object('sem', v_sem))
  end;

  -- ── the measured inputs, each already a string ───────────────────────────
  v_metrics := jsonb_build_array(
    jsonb_build_object('label', c755_copy('dev_queue.health_m_latency','{}'::jsonb),
      'value', coalesce(round(h.latency_p95_ms, 1)::text, '—') || ' ms',
      'tone', case when h.latency_p95_ms is null then 'neutral'
                   when h.latency_p95_ms <= coalesce((cfg->>'latency_ok_ms')::numeric,50) then 'success'
                   when h.latency_p95_ms >= coalesce((cfg->>'latency_bad_ms')::numeric,1500) then 'danger'
                   else 'warning' end),
    jsonb_build_object('label', c755_copy('dev_queue.health_m_conns','{}'::jsonb),
      'value', coalesce(h.conns::text,'—') || ' / ' || coalesce(h.max_conns::text,'—'),
      'tone', case when h.conns is null then 'neutral'
                   when h.conns::numeric / greatest(coalesce(h.max_conns,60),1) * 100
                        <= coalesce((cfg->>'conn_ok_pct')::numeric,50) then 'success'
                   when h.conns::numeric / greatest(coalesce(h.max_conns,60),1) * 100
                        >= coalesce((cfg->>'conn_bad_pct')::numeric,90) then 'danger'
                   else 'warning' end),
    jsonb_build_object('label', c755_copy('dev_queue.health_m_timeouts','{}'::jsonb),
      'value', coalesce(h.timeouts_5min,0)::text,
      'tone', case when coalesce(h.timeouts_5min,0) = 0 then 'success'
                   when coalesce(h.timeouts_5min,0) >= greatest(coalesce((wp#>>'{rpc_watchdog,breaker_count}')::int,10),1) then 'danger'
                   else 'warning' end),
    jsonb_build_object('label', c755_copy('dev_queue.health_m_transport','{}'::jsonb),
      'value', coalesce(h.transport_5min,0)::text,
      'tone', case when coalesce(h.transport_5min,0) = 0 then 'success' else 'danger' end),
    jsonb_build_object('label', c755_copy('dev_queue.health_m_cpu','{}'::jsonb),
      'value', case when h.cpu_pct is null then '—' else round(h.cpu_pct)::text || '%' end,
      'tone', case when h.cpu_pct is null then 'neutral'
                   when h.cpu_pct <= coalesce((cfg->>'cpu_ok_pct')::numeric,70) then 'success'
                   when h.cpu_pct >= coalesce((cfg->>'cpu_bad_pct')::numeric,98) then 'danger'
                   else 'warning' end));

  -- ── trips and resumes, newest first ──────────────────────────────────────
  select coalesce(jsonb_agg(q.j order by q.at desc), '[]'::jsonb) into v_hist
  from (
    select e.at as at,
           jsonb_build_object(
             'at_display', to_char(e.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
             'kind', e.kind,
             'kind_label', c755_copy('dev_queue.health_kind_' || e.kind, '{}'::jsonb),
             'tone', case e.kind when 'trip' then 'danger' when 'resume' then 'success'
                                 when 'scale_down' then 'warning' when 'scale_up' then 'info'
                                 else 'neutral' end,
             'score_display', case when e.score is null then '' else e.score::text end,
             'semaphore', e.semaphore,
             'reason', e.reason) as j
      from public.dev_runner_breaker_event e
     order by e.at desc
     limit 8
  ) q;

  return jsonb_build_object(
    'ok', true,
    'title',          c755_copy('dev_queue.health_title','{}'::jsonb),
    'has',            h.at is not null,
    'score',          h.score,
    'score_display',  coalesce(h.score::text, '—'),
    'score_label',    c755_copy('dev_queue.health_score_label','{}'::jsonb),
    'tone',           v_tone,
    'semaphore',      v_sem,
    'semaphore_display', v_sem::text,
    'semaphore_label',   c755_copy('dev_queue.health_sem_label','{}'::jsonb),
    'streak',         coalesce(h.green_streak, 0),
    'streak_label',   c755_copy('dev_queue.health_streak_label','{}'::jsonb),
    'streak_display', c755_copy('dev_queue.health_streak_fmt',
                        jsonb_build_object('n', coalesce(h.green_streak,0),
                                           'need', case when v_tripped then v_req else v_up_need end)),
    'next_action',    v_next,
    'probe', jsonb_build_object(
      'active',  v_active,
      'display', case when v_active
                      then c755_copy('dev_queue.health_probe_active', jsonb_build_object('s', v_probe_s))
                      else c755_copy('dev_queue.health_probe_idle',
                             jsonb_build_object('s', coalesce(t.current_interval_s, 600))) end,
      'tone',    case when v_active then 'success' else 'neutral' end,
      'last_display', case when h.at is null then c755_copy('dev_queue.health_probe_never','{}'::jsonb)
                           else c755_copy('dev_queue.health_last_fmt', jsonb_build_object(
                                  'at', to_char(h.at at time zone 'Asia/Kolkata','HH24:MI'))) end,
      'runs',    coalesce(t.runs, 0),
      'skips',   coalesce(t.skips, 0),
      'interval_s', coalesce(t.current_interval_s, 0)),
    'manual',  jsonb_build_object('workflow', v_manual, 'at', cfg#>>'{manual,at}'),
    'breaker', _dev_breaker_badge(),
    'metrics', v_metrics,
    'history_title', c755_copy('dev_queue.health_history_title','{}'::jsonb),
    'history_empty', c755_copy('dev_queue.health_history_empty','{}'::jsonb),
    'history', coalesce(v_hist, '[]'::jsonb));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. WIRE IT INTO THE PAYLOAD THE CONTROL PANEL ALREADY POLLS
-- ─────────────────────────────────────────────────────────────────────────────
-- The control strip reads dev_ctl_get every 10 s. Adding `health` there costs
-- one extra cheap read instead of a second round trip, and means the card can
-- never be a poll behind the toggles it sits under.

create or replace function public.dev_ctl_get()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_counts jsonb; v_ds jsonb; vm text; cl text; wf text;
        vm_l boolean; cl_l boolean; wf_l boolean;
        v_vm jsonb; v_poll jsonb; v_age numeric; v_status text; v_live boolean;
        v_cfg jsonb; v_rs jsonb; v_ps jsonb; v_rs_age numeric; v_ps_age numeric;
        v_rs_stale boolean; v_ps_stale boolean; v_rc text; v_health jsonb;
BEGIN
  PERFORM _dev_guard();
  SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb) INTO v_counts
  FROM (SELECT status, count(*) n FROM dev_commands GROUP BY status) s;

  v_ds := coalesce((SELECT value FROM dev_runner_config WHERE key='desired_state'), '{}'::jsonb);
  vm := coalesce(v_ds->>'vm','off'); cl := coalesce(v_ds->>'claude','off'); wf := coalesce(v_ds->>'workflow','off');
  vm_l := (vm='on' AND cl='on');
  cl_l := (cl='on' AND wf='on') OR (cl='off' AND vm='off');
  wf_l := (wf='off' AND cl='off');

  v_cfg := coalesce((SELECT value FROM dev_runner_config WHERE key='worker_pool'), '{}'::jsonb);

  v_vm   := coalesce((SELECT value FROM dev_runner_config WHERE key='vm_status'), '{}'::jsonb);
  v_poll := coalesce((SELECT value FROM dev_runner_config WHERE key='vm_poll'), '{}'::jsonb);
  v_status := coalesce(v_vm->>'status','unknown');
  BEGIN
    v_age := extract(epoch FROM (now() - (v_vm->>'last_checked')::timestamptz));
  EXCEPTION WHEN others THEN v_age := NULL;
  END;

  v_live := CASE
    WHEN coalesce((v_vm->>'awaiting_edge')::boolean, false) THEN true
    WHEN v_age IS NULL THEN true
    WHEN v_status IN ('starting','stopping','unknown')
      THEN v_age >= coalesce((v_poll->>'transitional_after_s')::numeric, 5)
    ELSE v_age >= coalesce((v_poll->>'stale_after_s')::numeric, 90)
  END;

  v_vm := v_vm || jsonb_build_object(
    'age_s',            round(coalesce(v_age, 999999)),
    'needs_live_check', v_live,
    'settled',          v_status IN ('running','stopped')
  );

  v_rs := coalesce((SELECT value FROM dev_runner_config WHERE key='runner_status'), '{}'::jsonb);
  BEGIN v_rs_age := extract(epoch FROM (now() - (v_rs->>'alive_at')::timestamptz));
  EXCEPTION WHEN others THEN v_rs_age := NULL; END;
  v_rs_stale := v_rs_age IS NULL OR v_rs_age > coalesce((v_cfg->>'runner_stale_s')::numeric, 180);
  IF v_rs_stale THEN
    v_rs := v_rs || jsonb_build_object('state','stopped','current_command_id', NULL,
                                       'remote_control','off');
  END IF;
  v_rc := coalesce(v_rs->>'remote_control','off');
  v_rs := v_rs || jsonb_build_object(
    'age_s',  round(coalesce(v_rs_age, 999999)),
    'stale',  v_rs_stale,
    'remote_display', CASE WHEN v_rc='on'
        THEN (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_remote_on')
        ELSE (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_remote_off') END,
    'remote_tone', CASE WHEN v_rc='on' THEN 'success' ELSE 'neutral' END);

  v_rs := v_rs || jsonb_build_object(
    'phone_sessions', CASE WHEN v_rs_stale THEN 0
                           ELSE coalesce((v_rs->>'phone_sessions')::int, 0) END,
    'phone_names',    CASE WHEN v_rs_stale THEN '[]'::jsonb
                           ELSE coalesce(v_rs->'phone_names', '[]'::jsonb) END);
  v_rs := v_rs || jsonb_build_object(
    'phone_display', CASE WHEN (v_rs->>'phone_sessions')::int > 0
        THEN replace((SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_on'),
                     '{n}', (v_rs->>'phone_sessions'))
        ELSE (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_off') END,
    'phone_tone', CASE WHEN (v_rs->>'phone_sessions')::int > 0 THEN 'success' ELSE 'warning' END,
    'phone_hint', CASE WHEN (v_rs->>'phone_sessions')::int > 0
        THEN (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_hint_on')
        ELSE (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.ctl_phone_hint_off') END);

  v_ps := coalesce((SELECT value FROM dev_runner_config WHERE key='pool_state'), '{}'::jsonb);
  BEGIN v_ps_age := extract(epoch FROM (now() - (v_ps->>'updated_at')::timestamptz));
  EXCEPTION WHEN others THEN v_ps_age := NULL; END;
  v_ps_stale := v_ps_age IS NULL OR v_ps_age > coalesce((v_cfg->>'pool_stale_s')::numeric, 180);
  IF v_ps_stale THEN
    v_ps := v_ps || jsonb_build_object(
      'workers', '[]'::jsonb, 'active_workers', 0,
      'quota_display','', 'load_display','', 'shrink_display','',
      'stale_display', (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.pool_stale'));
  ELSE
    v_ps := v_ps || jsonb_build_object('stale_display','');
  END IF;
  v_ps := v_ps || jsonb_build_object('stale', v_ps_stale, 'age_s', round(coalesce(v_ps_age, 999999)));

  -- CHANGE #755 — the self-healing breaker's card. Never allowed to break the
  -- control strip: a health payload that throws returns an empty object and the
  -- toggles still render.
  BEGIN v_health := runner_health_card();
  EXCEPTION WHEN others THEN v_health := jsonb_build_object('ok', false, 'has', false);
  END;

  RETURN jsonb_build_object(
    'desired_state', v_ds,
    'runner_status', v_rs,
    'vm',            v_vm,
    'vm_poll',       v_poll,
    'vm_identity',   coalesce((SELECT value FROM dev_runner_config WHERE key='vm_identity'), '{}'::jsonb),
    'queue_counts',  v_counts,
    'breaker',       _dev_breaker_badge(),
    'health',        v_health,
    'pool', jsonb_build_object(
      'config', v_cfg,
      'state',  v_ps,
      'lease_counts', coalesce((SELECT jsonb_object_agg(command_id::text, n) FROM (SELECT command_id, count(*) n FROM file_leases GROUP BY command_id) l), '{}'::jsonb)),
    'controls', jsonb_build_object(
      'vm',       jsonb_build_object('locked', vm_l,
        'lock_msg', CASE WHEN vm_l THEN (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.lock_claude_off_first') ELSE '' END),
      'claude',   jsonb_build_object('locked', cl_l,
        'lock_msg', CASE WHEN NOT cl_l THEN ''
                         WHEN cl='on' THEN (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.lock_workflow_off_first')
                         ELSE (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.lock_vm_on_first') END),
      'workflow', jsonb_build_object('locked', wf_l,
        'lock_msg', CASE WHEN wf_l THEN (SELECT value#>>'{}' FROM ui_copy WHERE key='dev_queue.lock_claude_on_first') ELSE '' END)
    ),
    'server_now',    now()
  );
END $$;

grant execute on function public.runner_health_card() to authenticated, service_role;
grant execute on function public.runner_health_probe() to service_role;
grant execute on function public.runner_breaker_trip(text, int, jsonb) to service_role;
grant execute on function public.runner_health_wake() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. COPY — every word the card prints
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.ui_copy (key, value) values
  ('dev_queue.health_title',           '"Runner health"'::jsonb),
  ('dev_queue.health_score_label',     '"Health score"'::jsonb),
  ('dev_queue.health_sem_label',       '"Parallel builds"'::jsonb),
  ('dev_queue.health_streak_label',    '"Green streak"'::jsonb),
  ('dev_queue.health_streak_fmt',      '"{n} of {need} green"'::jsonb),
  ('dev_queue.health_next_hold',       '"Holding at {sem} — database healthy"'::jsonb),
  ('dev_queue.health_next_up',         '"Scaling to {next} after {left} more green probe(s)"'::jsonb),
  ('dev_queue.health_next_down',       '"Scaling down to {sem} — database under pressure"'::jsonb),
  ('dev_queue.health_next_paused',     '"Paused — resuming after {need} green probes ({have} so far)"'::jsonb),
  ('dev_queue.health_next_manual_off', '"Workflow is off by hand — auto-resume stands down"'::jsonb),
  ('dev_queue.health_next_none',       '"Waiting for the first probe"'::jsonb),
  ('dev_queue.health_probe_active',    '"Probing every {s}s"'::jsonb),
  ('dev_queue.health_probe_idle',      '"Parked — queue idle, checking every {s}s"'::jsonb),
  ('dev_queue.health_probe_never',     '"No probe yet"'::jsonb),
  ('dev_queue.health_last_fmt',        '"Last probe {at}"'::jsonb),
  ('dev_queue.health_m_latency',       '"Latency p95"'::jsonb),
  ('dev_queue.health_m_conns',         '"Connections"'::jsonb),
  ('dev_queue.health_m_timeouts',      '"DB timeouts · 5 min"'::jsonb),
  ('dev_queue.health_m_transport',     '"Transport failures · 5 min"'::jsonb),
  ('dev_queue.health_m_cpu',           '"VM CPU"'::jsonb),
  ('dev_queue.health_history_title',   '"Trips & resumes"'::jsonb),
  ('dev_queue.health_history_empty',   '"No trips recorded"'::jsonb),
  ('dev_queue.health_kind_trip',       '"Tripped"'::jsonb),
  ('dev_queue.health_kind_resume',     '"Auto-resumed"'::jsonb),
  ('dev_queue.health_kind_scale_down', '"Scaled down"'::jsonb),
  ('dev_queue.health_kind_scale_up',   '"Scaled up"'::jsonb),
  ('dev_queue.health_kind_manual',     '"Manual toggle"'::jsonb),
  ('dev_queue.breaker_auto_resumed',   '"Auto-resumed {at}"'::jsonb),
  ('dev_queue.breaker_auto_detail',    '"The database came back green (score {score}) and Workflow switched itself on."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- The tripped badge now carries the reason and the streak it is waiting for,
-- instead of only a raw timeout count.
update public.ui_copy
   set value = '"Paused at {at} — {n}. Resuming after {need} green probes."'::jsonb,
       updated_at = now()
 where key = 'dev_queue.breaker_detail';

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. THE BEHAVIOUR TEST — the three things this change promises
-- ─────────────────────────────────────────────────────────────────────────────
-- rg_run_behaviors executes each body in a subtransaction that MUST end in
-- RG_ROLLBACK, so this drives the REAL controller against the REAL config and
-- leaves nothing behind. Nothing here is mocked: it inserts real timeout
-- events, calls the real probe, and asserts what the fleet would actually do.

insert into public.rg_behavior_tests (name, enabled, note, body) values (
 'c755_self_healing_breaker', true,
 'CHANGE #755 — ten timeouts must pause the fleet (semaphore 0), a held green streak must resume it by itself, and a manual Workflow OFF must survive both.',
$c755$
do $b755$
declare
  v jsonb; v_i int; v_wf text; v_sem int; v_trip boolean; v_req int;
begin
  -- ── fixture: a healthy fleet at full concurrency ────────────────────────
  update public.dev_runner_config
     set value = jsonb_set(jsonb_set(value,'{workflow}','"on"'),'{claude}','"on"')
   where key = 'desired_state';
  update public.dev_runner_config set value = jsonb_build_object('tripped', false)
   where key = 'db_breaker';
  update public.dev_runner_config
     set value = jsonb_set(value,'{build_semaphore}','3') where key = 'worker_pool';
  update public.dev_runner_config
     set value = jsonb_set(value,'{manual}', jsonb_build_object('workflow','on','at',now(),'by','rg'))
   where key = 'runner_health';
  delete from public.dev_runner_health;
  delete from public.db_timeout_event;

  -- ── 1. ten timeouts → semaphore 0, Workflow paused ──────────────────────
  insert into public.db_timeout_event (agent, detail)
  select 'c755-proof', jsonb_build_object('kind','statement_timeout','rpc','c755_proof_fn')
    from generate_series(1,10);

  v := public.runner_health_probe();
  if coalesce((v->>'semaphore')::int, -1) <> 0 then
    raise exception 'RG_FAIL c755: 10 timeouts left semaphore at % (score %)',
      v->>'semaphore', v->>'score';
  end if;
  if coalesce((v->>'score')::int, 100) >= 40 then
    raise exception 'RG_FAIL c755: 10 timeouts scored % — that is not the black band', v->>'score';
  end if;
  select coalesce(value->>'workflow','?') into v_wf
    from public.dev_runner_config where key = 'desired_state';
  if v_wf <> 'off' then
    raise exception 'RG_FAIL c755: breaker tripped but Workflow is still %', v_wf;
  end if;
  select coalesce((value->>'tripped')::boolean,false), coalesce((value->>'required_streak')::int,0)
    into v_trip, v_req from public.dev_runner_config where key = 'db_breaker';
  if not v_trip then raise exception 'RG_FAIL c755: db_breaker was not marked tripped'; end if;
  if v_req < 1 then raise exception 'RG_FAIL c755: trip recorded no required green streak'; end if;
  -- the trip must NAME the offender and FILE the work
  if not exists (select 1 from public.dev_commands
                  where title = 'Slow call: c755_proof_fn — bound it'
                    and status = 'pending') then
    raise exception 'RG_FAIL c755: the trip did not file a Slow call command for the worst offender';
  end if;

  -- ── 2. the database comes back → the fleet resumes ITSELF ───────────────
  delete from public.db_timeout_event;
  for v_i in 1..v_req loop
    v := public.runner_health_probe();
  end loop;
  select coalesce(value->>'workflow','?') into v_wf
    from public.dev_runner_config where key = 'desired_state';
  if v_wf <> 'on' then
    raise exception 'RG_FAIL c755: % green probes did not auto-resume Workflow (still %, score %, streak %)',
      v_req, v_wf, v->>'score', v->>'green_streak';
  end if;
  select coalesce((value->>'build_semaphore')::int,-1) into v_sem
    from public.dev_runner_config where key = 'worker_pool';
  if v_sem < 1 then
    raise exception 'RG_FAIL c755: auto-resume came back at semaphore %', v_sem;
  end if;
  if not exists (select 1 from public.dev_runner_breaker_event where kind = 'resume') then
    raise exception 'RG_FAIL c755: the auto-resume was not recorded in the history';
  end if;

  -- ── 3. a MANUAL Workflow OFF is never resumed over ──────────────────────
  update public.dev_runner_config
     set value = jsonb_set(value,'{manual}', jsonb_build_object('workflow','off','at',now(),'by','rg'))
   where key = 'runner_health';
  -- db_breaker is deliberately LEFT as the auto-resume wrote it: its `last`
  -- block is what makes the next trip a SECOND trip inside the window.
  delete from public.dev_runner_health;

  insert into public.db_timeout_event (agent, detail)
  select 'c755-proof', jsonb_build_object('kind','statement_timeout','rpc','c755_proof_fn')
    from generate_series(1,10);
  v := public.runner_health_probe();          -- trips again (2nd trip in-window)
  select coalesce((value->>'required_streak')::int,0), coalesce((value->>'trip_seq')::int,0)
    into v_req, v_i from public.dev_runner_config where key = 'db_breaker';
  if v_i < 2 then
    raise exception 'RG_FAIL c755: a second trip inside the cooldown window was not counted (seq %)', v_i;
  end if;
  if v_req <= greatest(coalesce((public._runner_health_cfg()->>'green_streak_required')::int,3),1) then
    raise exception 'RG_FAIL c755: the second trip did not escalate the required streak (still %)', v_req;
  end if;

  delete from public.db_timeout_event;
  for v_i in 1..(v_req + 2) loop
    v := public.runner_health_probe();
  end loop;
  select coalesce(value->>'workflow','?') into v_wf
    from public.dev_runner_config where key = 'desired_state';
  if v_wf <> 'off' then
    raise exception 'RG_FAIL c755: a MANUAL Workflow OFF was overridden by the auto-resume';
  end if;

  raise exception 'RG_ROLLBACK';
end $b755$;
$c755$)
on conflict (name) do update set
  enabled = excluded.enabled, note = excluded.note, body = excluded.body;
