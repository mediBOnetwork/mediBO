-- CHANGE #1593 — Autoscaler v2.
--
-- ROOT CAUSE, measured 5 Sep: runner_health_probe sat at semaphore 3 with score
-- 100 and a 48-probe green streak, and could not move. Not because anything was
-- unhealthy — because the green band's target IS the fixed
-- runner_health.sem_green, so "green" resolved to 3 and the scale-up branch
-- (`v_target > v_cur`) was never true. The Pool-settings slider said 6, so the
-- real limit was both invisible and unreachable; raising sem_green to 4 by hand
-- scaled the fleet instantly, which is the proof.
--
-- Two more things the old probe got wrong, both now that #1149/#1570 put builds
-- on a Supabase branch:
--   * it scores PRODUCTION latency, connections and timeouts. Production
--     pressure is a reason to protect the STOREFRONT, not a reason to run fewer
--     BUILDS, once builds no longer touch production.
--   * it has no idea what the box it is scaling actually has left. CPU is worth
--     15 points of a score; RAM, load per vCPU and free disk are worth nothing
--     at all, so the fleet could climb into a box with no headroom.
--
-- v2: the Pool-settings cap is the ONLY ceiling. Bands are brakes. Every brake
-- has a name, the card prints it, and every scale decision records the metric
-- that decided it.

-- ── 1. config. All of it lives in worker_pool.autoscale so Pool settings can
-- edit it and nothing here is a Dart or SQL literal at runtime.
update public.dev_runner_config
   set value = jsonb_set(value, '{autoscale}',
     coalesce(value->'autoscale', '{}'::jsonb) || jsonb_build_object(
       'enabled',   true,
       'note',      'CHANGE #1593 — the cap is the ceiling; everything here is a brake.',
       'step_up',   1,
       'step_up_fast', 2,
       'fast_score', 100,
       'fast_headroom_pct', 50,
       'green_streak_required', 3,
       'headroom', jsonb_build_object(
          'cpu_soft', 70, 'cpu_hard', 92,
          'ram_soft', 75, 'ram_hard', 90,
          'load_per_vcpu_soft', 2.0, 'load_per_vcpu_hard', 4.0,
          'disk_free_soft_pct', 20, 'disk_free_hard_pct', 10,
          'vcpus', 4),
       'branch', jsonb_build_object(
          'enabled', true,
          'stale_s', 300,
          'latency_ok_ms', 80, 'latency_bad_ms', 2000,
          'conn_ok_pct', 65, 'conn_bad_pct', 90,
          'timeout_ceiling', 10),
       'ceiling', jsonb_build_object(
          'enabled', true, 'window_min', 20, 'learned', null, 'learned_at', null,
          'clean_windows_required', 1),
       'pace', jsonb_build_object('enabled', true, 'slack_pct', 10),
       'wait', jsonb_build_object('enabled', true, 'window_min', 45, 'min_gain_pct', 5)))
 where key = 'worker_pool';

-- The bands stop being ceilings. sem_black stays: it is not a cap, it is how
-- deep a trip goes, and deleting it would quietly change what a trip does.
update public.dev_runner_config
   set value = value || jsonb_build_object(
     'bands_note', 'CHANGE #1593 — sem_green/sem_amber/sem_red are NO LONGER ceilings and are not read by the probe. worker_pool.cap is the only ceiling. sem_black is retained: it is the depth of a trip, not a cap.')
 where key = 'runner_health';

-- ── 2. what a build branch's health looks like, reported from where it can be
-- measured. runner_health_probe is plpgsql running on PRODUCTION; it cannot
-- time a query on the branch instance without dblink, a stored branch
-- credential and an outbound connection per probe on a 1 GB box. The VM already
-- holds the branch URL, so branch_probe.sh measures it there and reports here.
create table if not exists public.branch_health (
  id           boolean primary key default true check (id),
  ref          text,
  at           timestamptz not null default now(),
  ok           boolean not null default true,
  latency_p95_ms numeric,
  conns        integer,
  max_conns    integer,
  timeouts_5min integer,
  error        text,
  detail       jsonb not null default '{}'::jsonb
);

create or replace function public.branch_health_report(
  p_ref text default null, p_latency_ms numeric default null,
  p_conns int default null, p_max_conns int default null,
  p_timeouts int default null, p_ok boolean default true,
  p_error text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  perform public._build_branch_guard();
  insert into public.branch_health (id, ref, at, ok, latency_p95_ms, conns, max_conns,
                                    timeouts_5min, error)
  values (true, p_ref, now(), coalesce(p_ok, true), p_latency_ms, p_conns, p_max_conns,
          p_timeouts, nullif(p_error,''))
  on conflict (id) do update
    set ref = excluded.ref, at = now(), ok = excluded.ok,
        latency_p95_ms = excluded.latency_p95_ms, conns = excluded.conns,
        max_conns = excluded.max_conns, timeouts_5min = excluded.timeouts_5min,
        error = excluded.error;
  return jsonb_build_object('ok', true);
end $fn$;

-- ── 3. the helpers each brake is made of ───────────────────────────────────
create or replace function public._autoscale_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce((select value->'autoscale' from public.dev_runner_config
                    where key = 'worker_pool'), '{}'::jsonb);
$fn$;

-- THE ONLY CEILING. One resolution of the Pool-settings cap, bounded by the
-- slider's own min/max, so no caller can invent a different one.
-- It must ALWAYS return a number. A missing worker_pool row (the build branch
-- carries no control-plane config at all) would otherwise make the ceiling
-- null, and `least(x, null)` is null — which is how an autoscaler writes NULL
-- into build_semaphore and takes the fleet to nothing.
create or replace function public._pool_cap()
returns int language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(
    (select greatest(least(
              coalesce((value->>'cap')::int, 3),
              coalesce((value->>'max')::int, 8)),
            coalesce((value->>'min')::int, 1))
       from public.dev_runner_config where key = 'worker_pool'), 1);
$fn$;

-- Headroom: what the BOX has left, from the vitals it already reports. Every
-- term is optional — a metric the host has not sent is UNKNOWN and constrains
-- nothing, because a brake that engages on missing data is how a healthy fleet
-- gets held at one worker (the #1369 lesson, in a new place).
create or replace function public._autoscale_headroom()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare ps jsonb; gs jsonb; h jsonb; v_vcpu numeric;
        v_cpu numeric; v_ram numeric; v_load numeric; v_lpv numeric; v_free numeric;
        -- array_append, never `arr || 'x'`: with a text[] on the left Postgres
        -- resolves || to array||array and rejects the bare literal at RUNTIME
        -- ("malformed array literal"), which is a brake that compiles and then
        -- fails on the one probe where it was needed.
        soft text[] := '{}'; hard text[] := '{}'; v_worst numeric := 0; v_known int := 0;
begin
  h := coalesce(public._autoscale_cfg()->'headroom', '{}'::jsonb);
  select value into ps from public.dev_runner_config where key = 'pool_state';
  select value into gs from public.dev_runner_config where key = 'gcp_status';
  ps := coalesce(ps,'{}'::jsonb); gs := coalesce(gs,'{}'::jsonb);
  v_vcpu := greatest(coalesce((h->>'vcpus')::numeric, 4), 1);

  v_cpu  := nullif(ps->>'cpu_pct','')::numeric;
  v_ram  := nullif(ps->>'ram_pct','')::numeric;
  v_load := nullif(ps->>'load','')::numeric;
  v_lpv  := case when v_load is null then null else round(v_load / v_vcpu, 2) end;
  -- disk_pct is USED; free is what a build needs.
  v_free := case when (gs->>'disk_pct') is null then null
                 else 100 - (gs->>'disk_pct')::numeric end;

  if v_cpu is not null then
    v_known := v_known + 1;
    v_worst := greatest(v_worst, 100.0 * v_cpu / greatest(coalesce((h->>'cpu_hard')::numeric,92),1));
    if v_cpu >= coalesce((h->>'cpu_hard')::numeric, 92) then hard := array_append(hard, 'cpu');
    elsif v_cpu >= coalesce((h->>'cpu_soft')::numeric, 70) then soft := array_append(soft, 'cpu'); end if;
  end if;
  if v_ram is not null then
    v_known := v_known + 1;
    v_worst := greatest(v_worst, 100.0 * v_ram / greatest(coalesce((h->>'ram_hard')::numeric,90),1));
    if v_ram >= coalesce((h->>'ram_hard')::numeric, 90) then hard := array_append(hard, 'ram');
    elsif v_ram >= coalesce((h->>'ram_soft')::numeric, 75) then soft := array_append(soft, 'ram'); end if;
  end if;
  if v_lpv is not null then
    v_known := v_known + 1;
    v_worst := greatest(v_worst, 100.0 * v_lpv / greatest(coalesce((h->>'load_per_vcpu_hard')::numeric,4),0.1));
    if v_lpv >= coalesce((h->>'load_per_vcpu_hard')::numeric, 4) then hard := array_append(hard, 'load');
    elsif v_lpv >= coalesce((h->>'load_per_vcpu_soft')::numeric, 2) then soft := array_append(soft, 'load'); end if;
  end if;
  if v_free is not null then
    v_known := v_known + 1;
    if v_free <= coalesce((h->>'disk_free_hard_pct')::numeric, 10) then hard := array_append(hard, 'disk');
    elsif v_free <= coalesce((h->>'disk_free_soft_pct')::numeric, 20) then soft := array_append(soft, 'disk'); end if;
    v_worst := greatest(v_worst, 100.0 * (100 - v_free)
                        / greatest(100 - coalesce((h->>'disk_free_hard_pct')::numeric,10), 1));
  end if;

  return jsonb_build_object(
    'known', v_known,
    'cpu_pct', v_cpu, 'ram_pct', v_ram, 'load', v_load, 'load_per_vcpu', v_lpv,
    'disk_free_pct', v_free,
    'used_pct', round(least(v_worst, 999), 1),
    'soft', to_jsonb(soft), 'hard', to_jsonb(hard),
    'soft_breached', array_length(soft,1) is not null,
    'hard_breached', array_length(hard,1) is not null,
    'worst', case when array_length(hard,1) is not null then hard[1]
                  when array_length(soft,1) is not null then soft[1] else null end);
end $fn$;

-- Which database this probe is entitled to judge, and what it read there.
-- `judged` is the answer the card prints: production while there is no branch,
-- the branch while there is one AND the VM has reported it recently. A branch
-- that is up but silent is UNKNOWN — the score falls back to production for the
-- STOREFRONT's sake, and says so, rather than pretending either reading is the
-- other.
create or replace function public._autoscale_branch()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare c jsonb; bs jsonb; bh public.branch_health; v_age numeric; v_on boolean;
begin
  c := coalesce(public._autoscale_cfg()->'branch', '{}'::jsonb);
  begin bs := public.build_branch_state();
  exception when others then bs := '{}'::jsonb; end;
  v_on := coalesce(bs->>'status','off') = 'on'
          and coalesce((c->>'enabled')::boolean, true);
  select * into bh from public.branch_health where id;
  v_age := case when bh.at is null then null
                else extract(epoch from (now() - bh.at)) end;

  if not v_on then
    return jsonb_build_object('judged','production','has',false,
      'reason', case when coalesce((c->>'enabled')::boolean,true)
                     then 'no build branch is up' else 'branch health disabled' end);
  end if;
  if bh.at is null or v_age > coalesce((c->>'stale_s')::numeric, 300)
     or not coalesce(bh.ok, false) then
    return jsonb_build_object('judged','production','has',false,'branch_on',true,
      'age_s', v_age, 'ref', bs->>'project_ref',
      'reason', case when bh.at is null then 'branch health never reported'
                     when not coalesce(bh.ok,false) then coalesce(bh.error,'branch probe failed')
                     else 'branch health is stale' end);
  end if;
  return jsonb_build_object('judged','branch','has',true,'branch_on',true,
    'ref', coalesce(bh.ref, bs->>'project_ref'), 'age_s', v_age,
    'latency_p95_ms', bh.latency_p95_ms, 'conns', bh.conns, 'max_conns', bh.max_conns,
    'timeouts_5min', coalesce(bh.timeouts_5min, 0),
    'conn_pct', case when coalesce(bh.max_conns,0) > 0
                     then round(100.0 * bh.conns / bh.max_conns, 1) else null end,
    'reason', 'branch health reported ' || round(coalesce(v_age,0)) || 's ago');
end $fn$;

-- Did the last step up actually buy anything? Real queue wait (pending → picked
-- up) and real merge-lane wait, at THIS concurrency against the one before it.
-- A step that bought nothing is a reason to stay put, never to shrink: the
-- queue is not being harmed, it is just not being helped.
create or replace function public._autoscale_wait(p_current int)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare c jsonb; v_win int; v_now numeric; v_prev numeric; v_gain numeric; v_prev_sem int;
begin
  c := coalesce(public._autoscale_cfg()->'wait', '{}'::jsonb);
  if not coalesce((c->>'enabled')::boolean, true) then
    return jsonb_build_object('has', false, 'reason', 'wait backpressure disabled');
  end if;
  v_win := greatest(coalesce((c->>'window_min')::int, 45), 5);

  -- Median minutes a command waited before a worker picked it up, in the
  -- window, split by the semaphore that was in force when it was picked up.
  with picked as (
    select c2.started_at,
           extract(epoch from (c2.started_at - c2.created_at))/60.0 as wait_min,
           (select h.semaphore from public.dev_runner_health h
             where h.at <= c2.started_at order by h.at desc limit 1) as sem
      from public.dev_commands c2
     where c2.started_at is not null
       and c2.started_at > now() - make_interval(mins => v_win * 4)
       and c2.created_at is not null and c2.started_at > c2.created_at)
  select percentile_cont(0.5) within group (order by wait_min) filter (where sem = p_current),
         percentile_cont(0.5) within group (order by wait_min) filter (where sem = p_current - 1),
         max(sem) filter (where sem < p_current)
    into v_now, v_prev, v_prev_sem
    from picked;

  if v_now is null or v_prev is null or v_prev <= 0 then
    return jsonb_build_object('has', false, 'wait_now_min', round(coalesce(v_now,0)::numeric, 1),
      'reason', 'not enough history at this concurrency yet');
  end if;
  v_gain := round(100.0 * (v_prev - v_now) / v_prev, 1);
  return jsonb_build_object('has', true,
    'wait_now_min', round(v_now::numeric, 1), 'wait_prev_min', round(v_prev::numeric, 1),
    'prev_semaphore', v_prev_sem, 'gain_pct', v_gain,
    'helped', v_gain >= coalesce((c->>'min_gain_pct')::numeric, 5),
    'reason', case when v_gain >= coalesce((c->>'min_gain_pct')::numeric, 5)
                   then 'the last step cut queue wait by ' || v_gain || '%'
                   else 'the last step did not cut queue wait (' || v_gain || '%)' end);
end $fn$;

-- The learned ceiling. The highest concurrency that has actually survived a
-- full clean window — no DB timeouts, no merge-lane evictions and no worsening
-- build time. Blind climbing past it is not allowed; it only rises after the
-- CURRENT level has itself run clean, so the fleet earns each rung once and
-- then keeps it.
create or replace function public._autoscale_window_clean(p_sem int, p_win int)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare v_from timestamptz; v_probes int; v_to int; v_evict int; v_now numeric; v_before numeric;
begin
  v_from := now() - make_interval(mins => p_win);
  select count(*), coalesce(sum(timeouts_5min),0)
    into v_probes, v_to
    from public.dev_runner_health
   where at > v_from and semaphore = p_sem;
  select count(*) into v_evict from public.deploy_queue
   where status = 'evicted' and coalesce(finished_at, pushed_at) > v_from;
  select avg(extract(epoch from (finished_at - started_at))/60.0)
    into v_now from public.dev_commands
   where status = 'completed' and finished_at > v_from
     and started_at is not null and finished_at > started_at;
  select avg(extract(epoch from (finished_at - started_at))/60.0)
    into v_before from public.dev_commands
   where status = 'completed'
     and finished_at between v_from - make_interval(mins => p_win) and v_from
     and started_at is not null and finished_at > started_at;

  return jsonb_build_object(
    'sem', p_sem, 'probes', v_probes, 'timeouts', v_to, 'evictions', v_evict,
    'build_min_now', round(coalesce(v_now,0)::numeric,1),
    'build_min_before', round(coalesce(v_before,0)::numeric,1),
    -- A window with no probes at this level is not a clean window; it is no
    -- window. Silence is never evidence.
    'clean', v_probes >= greatest(p_win / 2, 1) and v_to = 0 and v_evict = 0
             and (v_before is null or v_now is null or v_now <= v_before * 1.25));
end $fn$;

create or replace function public._autoscale_ceiling(p_current int)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare c jsonb; v_win int; v_learned int; v_clean jsonb; v_cap int;
begin
  c := coalesce(public._autoscale_cfg()->'ceiling', '{}'::jsonb);
  v_cap := public._pool_cap();
  if not coalesce((c->>'enabled')::boolean, true) then
    return jsonb_build_object('has', false, 'ceiling', v_cap, 'reason', 'learned ceiling disabled');
  end if;
  v_win := greatest(coalesce((c->>'window_min')::int, 20), 5);
  v_learned := nullif(c->>'learned','')::int;
  v_clean := public._autoscale_window_clean(p_current, v_win);

  -- The current level ran clean for a full window: it is proven, and one rung
  -- above it becomes explorable. This is the ONLY way the ceiling rises.
  if coalesce((v_clean->>'clean')::boolean, false)
     and (v_learned is null or p_current >= v_learned) then
    v_learned := least(p_current + 1, v_cap);
    update public.dev_runner_config
       set value = jsonb_set(jsonb_set(value, '{autoscale,ceiling,learned}', to_jsonb(v_learned)),
                             '{autoscale,ceiling,learned_at}', to_jsonb(now()))
     where key = 'worker_pool';
  end if;

  return jsonb_build_object('has', v_learned is not null,
    'ceiling', least(coalesce(v_learned, v_cap), v_cap), 'cap', v_cap,
    'learned', v_learned, 'window', v_clean,
    'reason', case when v_learned is null
                   then 'no clean window recorded yet — the cap is the only ceiling'
                   else 'highest concurrency proven clean for ' || v_win || ' min' end);
end $fn$;

-- Cost-aware pacing. With billing_mode=max_subscription the quota is a budget
-- that refills at a known moment, so the right response to burning it fast is
-- to SLOW DOWN, never to stop: a stopped fleet cannot refresh the token that
-- reports the quota, which is exactly how a stale 100% held the pool at one
-- worker for hours on 5 Sep.
-- Deliberately NOT stable: dev_cmd_session_usage() may refresh its own reading.
create or replace function public._autoscale_pace()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare c jsonb; wp jsonb; u jsonb; v_pct numeric; v_reset timestamptz;
        v_win_h numeric; v_elapsed_h numeric; v_expect numeric; v_slack numeric;
begin
  c := coalesce(public._autoscale_cfg()->'pace', '{}'::jsonb);
  select value into wp from public.dev_runner_config where key='worker_pool';
  if not coalesce((c->>'enabled')::boolean, true)
     or coalesce(wp->>'billing_mode','') <> 'max_subscription' then
    return jsonb_build_object('has', false, 'reason', 'pacing off or not a subscription plan');
  end if;
  begin u := public.dev_cmd_session_usage();
  exception when others then u := '{}'::jsonb; end;
  -- An unknown reading paces nothing. Ever.
  if coalesce((u->>'quota_unknown')::boolean, true) then
    return jsonb_build_object('has', false, 'reason', 'usage reading is unknown');
  end if;
  v_pct   := coalesce((u->>'quota_pct')::numeric, 0);
  v_reset := nullif(u#>>'{five_hour,resets_at}','')::timestamptz;
  if v_reset is null or v_reset <= now() then
    return jsonb_build_object('has', false, 'quota_pct', v_pct, 'reason', 'no live window to pace against');
  end if;
  v_win_h    := 5;
  v_elapsed_h := v_win_h - extract(epoch from (v_reset - now()))/3600.0;
  if v_elapsed_h <= 0 then
    return jsonb_build_object('has', false, 'quota_pct', v_pct, 'reason', 'window just reset');
  end if;
  -- Where the burn SHOULD be if it is to land exactly at the reset.
  v_expect := round(100.0 * v_elapsed_h / v_win_h, 1);
  v_slack  := coalesce((c->>'slack_pct')::numeric, 10);
  return jsonb_build_object('has', true,
    'quota_pct', v_pct, 'expected_pct', v_expect, 'slack_pct', v_slack,
    'ahead_pct', round(v_pct - v_expect, 1),
    'hold', v_pct > v_expect + v_slack,
    'reason', case when v_pct > v_expect + v_slack
        then 'quota is ' || round(v_pct - v_expect,1) || '% ahead of the window — pacing'
        else 'quota is on pace for the reset' end);
end $fn$;

-- ── 4. ONE decide step. Every brake in one place, each with a name, so the
-- card can say WHY and the event row can name the metric that decided it.
create or replace function public.runner_autoscale_decide(
  p_score int, p_current int, p_streak int, p_timeouts int, p_judged jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare c jsonb; hcfg jsonb; v_cap int; v_head jsonb; v_ceil jsonb; v_pace jsonb; v_wait jsonb;
        v_green int; v_amber int; v_red int; v_target int; v_step int; v_req int;
        v_brake text := 'cap'; v_metric jsonb; v_up boolean; v_ceiling int;
begin
  c := public._autoscale_cfg();
  hcfg := public._runner_health_cfg();
  v_cap := greatest(coalesce(public._pool_cap(), 1), 1);
  -- Every input is coalesced HERE, once. Downstream this function does
  -- arithmetic and least()/greatest() on all of them, and one null would
  -- propagate all the way into build_semaphore.
  p_current := greatest(coalesce(p_current, 1), 0);
  p_score   := coalesce(p_score, 0);
  p_streak  := coalesce(p_streak, 0);
  p_timeouts := coalesce(p_timeouts, 0);
  p_judged  := coalesce(p_judged, '{}'::jsonb);
  v_green := coalesce((hcfg->>'green_score')::int, 80);
  v_amber := coalesce((hcfg->>'amber_score')::int, 60);
  v_red   := coalesce((hcfg->>'red_score')::int,   40);
  v_req   := greatest(coalesce((c->>'green_streak_required')::int,
                      coalesce((hcfg->>'green_streak_required')::int, 3)), 1);

  v_head := public._autoscale_headroom();
  v_ceil := public._autoscale_ceiling(p_current);
  v_pace := public._autoscale_pace();
  v_wait := public._autoscale_wait(p_current);
  v_ceiling := greatest(least(coalesce((v_ceil->>'ceiling')::int, v_cap), v_cap), 1);

  -- DOWN FIRST, and down is instant. A hard headroom breach or a red score
  -- costs a worker on the same probe that saw it; only the black band drops
  -- further than one step, because that is a trip, not a scale.
  if p_score < v_red then
    return jsonb_build_object('target', coalesce((hcfg->>'sem_black')::int, 0),
      'direction','trip', 'brake','score',
      'label', replace(replace(public._c_or('dev_queue.as_brake_score',
                 'health score {s} — pausing builds'), '{s}', p_score::text), '{n}', '0'),
      'cap', v_cap, 'ceiling', v_ceiling, 'headroom', v_head, 'ceiling_detail', v_ceil,
      'pace', v_pace, 'wait', v_wait, 'judged', p_judged,
      'metric', jsonb_build_object('name','score','value',p_score,'limit',v_red));
  end if;

  if coalesce((v_head->>'hard_breached')::boolean, false) and p_current > 1 then
    return jsonb_build_object('target', p_current - 1, 'direction','down', 'brake','headroom',
      'label', replace(replace(public._c_or('dev_queue.as_brake_headroom_hard',
                 '{n} — {what} is past its hard limit'), '{n}', (p_current-1)::text),
                 '{what}', coalesce(v_head->>'worst','the box')),
      'cap', v_cap, 'ceiling', v_ceiling, 'headroom', v_head, 'ceiling_detail', v_ceil,
      'pace', v_pace, 'wait', v_wait, 'judged', p_judged,
      'metric', jsonb_build_object('name', coalesce(v_head->>'worst','headroom'),
                                   'value', v_head->>'used_pct', 'limit', 100));
  end if;

  if p_score < v_amber and p_current > 1 then
    return jsonb_build_object('target', p_current - 1, 'direction','down', 'brake','score',
      'label', replace(replace(public._c_or('dev_queue.as_brake_score_down',
                 '{n} — health score {s}'), '{n}', (p_current-1)::text), '{s}', p_score::text),
      'cap', v_cap, 'ceiling', v_ceiling, 'headroom', v_head, 'ceiling_detail', v_ceil,
      'pace', v_pace, 'wait', v_wait, 'judged', p_judged,
      'metric', jsonb_build_object('name','score','value',p_score,'limit',v_amber));
  end if;

  -- UP. The cap is the ceiling; everything below is a named brake, and the
  -- first one that applies is the one the card prints.
  v_up := p_score >= v_green and p_streak >= v_req
          and not coalesce((v_head->>'soft_breached')::boolean, false);

  if p_current >= v_cap then
    v_brake := 'cap';
    v_metric := jsonb_build_object('name','cap','value',p_current,'limit',v_cap);
  elsif p_current >= v_ceiling then
    v_brake := 'learned_ceiling';
    v_metric := jsonb_build_object('name','learned_ceiling','value',p_current,'limit',v_ceiling);
  elsif coalesce((v_pace->>'hold')::boolean, false) then
    v_brake := 'quota';
    v_metric := jsonb_build_object('name','quota','value',v_pace->>'quota_pct','limit',v_pace->>'expected_pct');
  elsif coalesce((v_head->>'soft_breached')::boolean, false) then
    v_brake := 'headroom';
    v_metric := jsonb_build_object('name', coalesce(v_head->>'worst','headroom'),
                                   'value', v_head->>'used_pct', 'limit', 100);
  elsif coalesce((v_wait->>'has')::boolean, false)
        and not coalesce((v_wait->>'helped')::boolean, true) then
    v_brake := 'wait';
    v_metric := jsonb_build_object('name','queue_wait','value',v_wait->>'wait_now_min',
                                   'limit',v_wait->>'wait_prev_min');
  elsif p_score < v_green then
    v_brake := 'score';
    v_metric := jsonb_build_object('name','score','value',p_score,'limit',v_green);
  elsif p_streak < v_req then
    v_brake := 'streak';
    v_metric := jsonb_build_object('name','green_streak','value',p_streak,'limit',v_req);
  else
    v_brake := 'none';
    v_metric := jsonb_build_object('name','none','value',p_current,'limit',v_cap);
  end if;

  if v_up and v_brake = 'none' then
    -- +2 when it is very green with real room: score at the fast mark, headroom
    -- under half its hard limits, and not one timeout in the window.
    v_step := case when p_score >= coalesce((c->>'fast_score')::int, 100)
                    and coalesce((v_head->>'used_pct')::numeric, 100)
                        < coalesce((c->>'fast_headroom_pct')::numeric, 50)
                    and coalesce(p_timeouts, 0) = 0
                   then coalesce((c->>'step_up_fast')::int, 2)
                   else coalesce((c->>'step_up')::int, 1) end;
    v_target := least(p_current + v_step, v_ceiling, v_cap);
    if v_target > p_current then
      return jsonb_build_object('target', v_target, 'direction','up', 'brake','none',
        'step', v_target - p_current,
        'label', replace(public._c_or('dev_queue.as_up','climbing to {n}'), '{n}', v_target::text),
        'cap', v_cap, 'ceiling', v_ceiling, 'headroom', v_head, 'ceiling_detail', v_ceil,
        'pace', v_pace, 'wait', v_wait, 'judged', p_judged, 'metric', v_metric);
    end if;
  end if;

  return jsonb_build_object('target', p_current, 'direction','hold', 'brake', v_brake,
    'label', replace(replace(public._c_or('dev_queue.as_hold', 'holding at {n} — {why}'),
               '{n}', p_current::text),
               '{why}', public._c_or('dev_queue.as_why_' || v_brake, v_brake)),
    'cap', v_cap, 'ceiling', v_ceiling, 'headroom', v_head, 'ceiling_detail', v_ceil,
    'pace', v_pace, 'wait', v_wait, 'judged', p_judged, 'metric', v_metric);
end $fn$;

-- ── 5. the probe, v2 ───────────────────────────────────────────────────────
-- Same measurement discipline as v1 (its scoring terms are kept, and the
-- breaker/auto-resume path is unchanged), with two changes that matter:
--   * when a build branch is up and the VM has reported its health recently,
--     latency / connections / timeouts are the BRANCH's. Production pressure
--     alone no longer shrinks builds, because builds no longer touch it.
--   * the band no longer decides the target. runner_autoscale_decide does, and
--     the Pool-settings cap is the only ceiling in it.
create or replace function public.runner_health_probe()
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_catalog' set statement_timeout to '8s' as $fn$
declare
  cfg jsonb; wp jsonb; ds jsonb; b jsonb; jb jsonb; dec jsonb;
  v_t0 timestamptz; v_samples numeric[] := '{}'; v_i int;
  v_lat numeric; v_conns int; v_max int; v_pct numeric;
  v_to int; v_tr int; v_cpu numeric; v_ram numeric;
  v_score numeric := 100; v_pen numeric;
  v_green int; v_amber int; v_red int; v_target int; v_cur int;
  v_streak int; v_req int; v_action text := 'hold'; v_wf text;
  v_manual text; v_tripped boolean; v_reason text := ''; v_res jsonb;
  v_bwin int; v_thresh int; v_judged text;
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

  -- Production is always measured: it is the storefront, and the breaker still
  -- protects it. Whether it SCORES the fleet is what changes below.
  for v_i in 1..7 loop
    v_t0 := clock_timestamp();
    perform 1 from public.dev_runner_config where key = 'desired_state';
    v_samples := v_samples || (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::numeric;
  end loop;
  select round(percentile_cont(0.95) within group (order by s)::numeric, 3)
    into v_lat from unnest(v_samples) s;
  select count(*)::int into v_conns from pg_stat_activity where datname = current_database();
  v_max := coalesce(nullif(current_setting('max_connections', true), '')::int, 60);
  select count(*)::int, count(*) filter (where detail->>'kind' = 'transport_blackout')::int
    into v_to, v_tr
    from public.db_timeout_event where at > now() - interval '5 minutes';

  -- WHICH DATABASE IS BEING JUDGED. A branch that is up and freshly reported
  -- replaces the three numbers the score is built from; a branch that is up and
  -- SILENT does not — unknown is unknown, and the storefront's numbers are the
  -- honest fallback rather than an optimistic guess.
  jb := public._autoscale_branch();
  v_judged := coalesce(jb->>'judged', 'production');
  if v_judged = 'branch' then
    v_lat   := coalesce((jb->>'latency_p95_ms')::numeric, v_lat);
    v_conns := coalesce((jb->>'conns')::int, v_conns);
    v_max   := coalesce((jb->>'max_conns')::int, v_max);
    v_to    := coalesce((jb->>'timeouts_5min')::int, 0);
    v_tr    := 0;
  end if;
  v_pct := round(100.0 * v_conns / greatest(v_max,1), 1);

  select (value->>'cpu_pct')::numeric, (value->>'ram_pct')::numeric
    into v_cpu, v_ram
    from public.dev_runner_config where key = 'pool_state';
  if v_cpu is not null or v_ram is not null then
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

  -- ── the score, against whichever database is being judged ────────────────
  v_pen := greatest(0, least(30,
    30 * (v_lat - case when v_judged = 'branch'
                       then coalesce((_autoscale_cfg()#>>'{branch,latency_ok_ms}')::numeric, 80)
                       else coalesce((cfg->>'latency_ok_ms')::numeric, 50) end)
       / greatest(case when v_judged = 'branch'
                       then coalesce((_autoscale_cfg()#>>'{branch,latency_bad_ms}')::numeric, 2000)
                       else coalesce((cfg->>'latency_bad_ms')::numeric, 1500) end
                  - case when v_judged = 'branch'
                       then coalesce((_autoscale_cfg()#>>'{branch,latency_ok_ms}')::numeric, 80)
                       else coalesce((cfg->>'latency_ok_ms')::numeric, 50) end, 1)));
  v_score := v_score - v_pen;

  v_pen := greatest(0, least(25,
    25 * (v_pct - coalesce((cfg->>'conn_ok_pct')::numeric, 65))
       / greatest(coalesce((cfg->>'conn_bad_pct')::numeric, 90)
                  - coalesce((cfg->>'conn_ok_pct')::numeric, 65), 1)));
  v_score := v_score - v_pen;

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

  v_green := coalesce((cfg->>'green_score')::int, 80);
  v_amber := coalesce((cfg->>'amber_score')::int, 60);
  v_red   := coalesce((cfg->>'red_score')::int,   40);
  v_cur   := coalesce((wp->>'build_semaphore')::int, 1);

  select coalesce(green_streak, 0) into v_streak
    from public.dev_runner_health order by at desc limit 1;
  v_streak := case when v_score >= v_amber then coalesce(v_streak,0) + 1 else 0 end;
  v_req := greatest(coalesce((b->>'required_streak')::int,
                             coalesce((cfg->>'green_streak_required')::int, 3)), 1);

  dec := public.runner_autoscale_decide(v_score::int, v_cur, v_streak, v_to, jb);
  -- A decision that cannot name a number is not a decision: hold where we are.
  v_target := coalesce((dec->>'target')::int, v_cur);
  v_reason := coalesce(dec->>'label', '');

  -- ── act ──────────────────────────────────────────────────────────────────
  if v_score < v_red then
    v_reason := format('health score %s (< %s): %s DB timeout(s) in %s min, p95 %s ms, %s of %s connections (judged: %s)',
                       v_score, v_red, v_to, v_bwin, v_lat, v_conns, v_max, v_judged);
    if not v_tripped and v_wf = 'on' then
      v_res := runner_breaker_trip(v_reason, v_score::int,
                 jsonb_build_object('source','probe','timeouts_5min',v_to,
                                    'latency_p95_ms',v_lat,'conns',v_conns,'judged',v_judged));
      v_action := 'trip';
    else
      v_action := 'paused';
    end if;
    if v_target <> v_cur then
      update public.dev_runner_config
         set value = jsonb_set(value, '{build_semaphore}', to_jsonb(v_target))
       where key = 'worker_pool';
    end if;
    v_streak := 0;
    v_tripped := true;

  elsif v_tripped then
    v_action := 'awaiting_resume';
    v_target := v_cur;

  elsif v_target < v_cur then
    update public.dev_runner_config
       set value = jsonb_set(value, '{build_semaphore}', to_jsonb(v_target))
     where key = 'worker_pool';
    v_action := 'scale_down';
    insert into public.dev_runner_breaker_event (kind, score, semaphore, reason, detail)
    values ('scale_down', v_score::int, v_target, v_reason,
            jsonb_build_object('from', v_cur, 'to', v_target, 'timeouts_5min', v_to,
                               'brake', dec->>'brake', 'metric', dec->'metric',
                               'judged', v_judged, 'headroom', dec->'headroom'));

  elsif v_target > v_cur then
    update public.dev_runner_config
       set value = jsonb_set(value, '{build_semaphore}', to_jsonb(v_target))
     where key = 'worker_pool';
    v_action := 'scale_up';
    insert into public.dev_runner_breaker_event (kind, score, semaphore, reason, detail)
    values ('scale_up', v_score::int, v_target, v_reason,
            jsonb_build_object('from', v_cur, 'to', v_target, 'streak', v_streak,
                               'step', dec->>'step', 'metric', dec->'metric',
                               'judged', v_judged, 'ceiling', dec->>'ceiling',
                               'cap', dec->>'cap', 'headroom', dec->'headroom'));
    v_streak := 0;   -- the next rung earns its own greens
  else
    v_target := v_cur;
    -- A HOLD IS A DECISION AND IT GETS RECORDED. #1593 existed for 48 probes
    -- during which the fleet held at 3 and nothing anywhere said why; a brake
    -- that leaves no trace is indistinguishable from a bug. Once per brake
    -- change, not once per probe — the card reads the latest either way.
    if coalesce(dec->>'brake','none') <> 'none'
       and coalesce((select detail->>'brake' from public.dev_runner_breaker_event
                      where kind = 'hold' order by at desc limit 1), '') <> (dec->>'brake') then
      insert into public.dev_runner_breaker_event (kind, score, semaphore, reason, detail)
      values ('hold', v_score::int, v_cur, v_reason,
              jsonb_build_object('brake', dec->>'brake', 'metric', dec->'metric',
                                 'judged', v_judged, 'cap', dec->>'cap',
                                 'ceiling', dec->>'ceiling', 'wait', dec->'wait',
                                 'pace', dec->'pace', 'headroom', dec->'headroom'));
    end if;
  end if;

  -- ── auto-resume (unchanged in shape; the target is the decider's now) ────
  if v_tripped and v_score >= v_amber and v_streak >= v_req then
    if coalesce(v_manual, 'on') = 'off' then
      v_action := 'blocked_manual';
      v_reason := 'workflow was switched off by hand — auto-resume stands down';
    else
      -- Resume at ONE and let the ladder earn the rest: a resume is the moment
      -- least entitled to guess how much the database can take.
      v_target := greatest(coalesce((wp->>'min')::int, 1), 1);
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
              jsonb_build_object('streak', v_streak, 'required', v_req, 'auto', true,
                                 'judged', v_judged));
      begin perform _audit('system','db_breaker_auto_resume', null,
                jsonb_build_object('score', v_score, 'streak', v_streak,
                                   'semaphore', v_target)); exception when others then null; end;
      v_streak := 0;
      v_tripped := false;
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
                         'conn_pct', v_pct, 'manual', v_manual,
                         'judged', v_judged, 'judged_detail', jb,
                         'brake', dec->>'brake', 'brake_label', dec->>'label',
                         'metric', dec->'metric', 'cap', dec->>'cap',
                         'ceiling', dec->>'ceiling', 'headroom', dec->'headroom',
                         'pace', dec->'pace', 'wait', dec->'wait'))
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
    'timeouts_5min', v_to, 'transport_5min', v_tr, 'tripped', v_tripped,
    'judged', v_judged, 'brake', dec->>'brake', 'cap', dec->>'cap',
    'ceiling', dec->>'ceiling', 'decision', dec);
end $fn$;

-- ── 6. the card: the brake IS the next action, plus which DB was judged, what
-- the box has left, and the ladder (current / learned ceiling / Pool cap).
CREATE OR REPLACE FUNCTION public.runner_health_card()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  cfg jsonb; wp jsonb; ds jsonb; b jsonb; h public.dev_runner_health%rowtype;
  t public.cron_task%rowtype;
  v_green int; v_amber int; v_red int; v_req int; v_sem int; v_tone text;
  v_active boolean; v_manual text; v_next text; v_metrics jsonb; v_hist jsonb;
  v_up_need int; v_target int; v_probe_s int; v_tripped boolean;
begin
  -- Same door as every other dev-queue read: the fleet's health, its pool
  -- config and its trip history are super-admin material, not something any
  -- signed-in pharmacy can enumerate.
  perform _dev_guard();
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
  -- CHANGE #1593 — when the probe named a brake, the brake IS the next action.
  -- "Holding at 4 — database healthy" was true and useless for 48 probes while
  -- the real answer was "holding at 4 — the green band's fixed ceiling".
  if coalesce(h.detail->>'brake_label','') <> ''
     and coalesce(h.detail->>'brake','none') <> 'none' then
    v_next := h.detail->>'brake_label';
  end if;

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
                   else 'warning' end))
    -- CHANGE #1593 — WHICH DATABASE WAS JUDGED. Without it the five numbers
    -- above are unreadable: 0.7 ms means one thing about production and another
    -- about the branch a build is actually writing to.
    || jsonb_build_array(jsonb_build_object(
         'label', _c_or('dev_queue.health_m_judged','Judged'),
         'value', case coalesce(h.detail->>'judged','production')
                    when 'branch' then _c_or('dev_queue.health_judged_branch','build branch')
                    else _c_or('dev_queue.health_judged_prod','production') end,
         'tone',  case when coalesce(h.detail->>'judged','production') = 'branch'
                       then 'info' else 'neutral' end))
    -- and what the box has left, which is what actually stops a climb.
    || case when (h.detail#>>'{headroom,used_pct}') is null then '[]'::jsonb
       else jsonb_build_array(jsonb_build_object(
         'label', _c_or('dev_queue.health_m_headroom','Headroom used'),
         'value', (h.detail#>>'{headroom,used_pct}') || '%',
         'tone',  case when coalesce((h.detail#>>'{headroom,hard_breached}')::boolean,false) then 'danger'
                       when coalesce((h.detail#>>'{headroom,soft_breached}')::boolean,false) then 'warning'
                       else 'success' end)) end;

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
    -- "5 of 3 green" is nonsense: the streak only has a TARGET while something
    -- is waiting on it (a resume, or a step up). With nothing pending it is
    -- just a run of good probes and says so.
    'streak_display', case when v_tripped or v_target > v_sem
        then c755_copy('dev_queue.health_streak_fmt',
               jsonb_build_object('n', coalesce(h.green_streak,0),
                                  'need', case when v_tripped then v_req else v_up_need end))
        else c755_copy('dev_queue.health_streak_plain',
               jsonb_build_object('n', coalesce(h.green_streak,0))) end,
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
    -- CHANGE #1593 — the ladder, verbatim. current / learned ceiling / the
    -- Pool-settings cap, plus the brake that is holding it where it is.
    'autoscale', jsonb_build_object(
      'has',    coalesce(h.detail->>'brake','') <> '',
      'brake',  coalesce(h.detail->>'brake','none'),
      'label',  coalesce(h.detail->>'brake_label',''),
      'judged', coalesce(h.detail->>'judged','production'),
      'current', v_sem,
      'ceiling', nullif(h.detail->>'ceiling','')::int,
      'cap',     nullif(h.detail->>'cap','')::int,
      'ladder_label', replace(replace(replace(
        _c_or('dev_queue.health_ladder','{n} of {cap} · ceiling {ceil}'),
        '{n}', v_sem::text),
        '{cap}', coalesce(h.detail->>'cap','—')),
        '{ceil}', coalesce(h.detail->>'ceiling','—')),
      'metric', h.detail->'metric',
      'headroom', h.detail->'headroom',
      'pace', h.detail->'pace',
      'wait', h.detail->'wait'),
    'history_title', c755_copy('dev_queue.health_history_title','{}'::jsonb),
    'history_empty', c755_copy('dev_queue.health_history_empty','{}'::jsonb),
    'history', coalesce(v_hist, '[]'::jsonb));
end $function$

;

-- ── 7. a read-only view of the whole decision, for the app and for a human
-- asking "why is it not climbing?" without waiting for the next probe.
create or replace function public.runner_autoscale_state()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_cur int; dec jsonb; h public.dev_runner_health;
begin
  perform public._dev_guard();
  select coalesce((value->>'build_semaphore')::int, 1) into v_cur
    from public.dev_runner_config where key = 'worker_pool';
  v_cur := greatest(coalesce(v_cur, 1), 1);
  select * into h from public.dev_runner_health order by at desc limit 1;
  dec := public.runner_autoscale_decide(coalesce(h.score, 100), v_cur,
           coalesce(h.green_streak, 0), coalesce(h.timeouts_5min, 0),
           public._autoscale_branch());
  return dec || jsonb_build_object('ok', true, 'current', v_cur,
    'zone', admin_active_zone(), 'date', admin_active_date());
end $fn$;

-- ── 8. the words ───────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('dev_queue.as_hold',                to_jsonb('Holding at {n} — {why}'::text)),
  ('dev_queue.as_up',                  to_jsonb('Climbing to {n}'::text)),
  ('dev_queue.as_brake_score',         to_jsonb('Health score {s} — pausing builds'::text)),
  ('dev_queue.as_brake_score_down',    to_jsonb('Down to {n} — health score {s}'::text)),
  ('dev_queue.as_brake_headroom_hard', to_jsonb('Down to {n} — {what} is past its hard limit'::text)),
  ('dev_queue.as_why_cap',             to_jsonb('that is the worker cap in Pool settings'::text)),
  ('dev_queue.as_why_learned_ceiling', to_jsonb('the highest concurrency proven clean so far'::text)),
  ('dev_queue.as_why_quota',           to_jsonb('pacing the Claude quota to its reset'::text)),
  ('dev_queue.as_why_headroom',        to_jsonb('the box is near a soft limit'::text)),
  ('dev_queue.as_why_wait',            to_jsonb('the last extra worker did not cut queue wait'::text)),
  ('dev_queue.as_why_score',           to_jsonb('the health score is below green'::text)),
  ('dev_queue.as_why_streak',          to_jsonb('waiting for a longer green streak'::text)),
  ('dev_queue.as_why_none',            to_jsonb('nothing is holding it back'::text)),
  ('dev_queue.health_m_judged',        to_jsonb('Judged'::text)),
  ('dev_queue.health_judged_branch',   to_jsonb('build branch'::text)),
  ('dev_queue.health_judged_prod',     to_jsonb('production'::text)),
  ('dev_queue.health_m_headroom',      to_jsonb('Headroom used'::text)),
  ('dev_queue.health_ladder',          to_jsonb('{n} of {cap} · ceiling {ceil}'::text))
on conflict (key) do nothing;

grant execute on function public.branch_health_report(text, numeric, int, int, int, boolean, text) to service_role;
grant execute on function public.runner_autoscale_decide(int, int, int, int, jsonb) to service_role;
grant execute on function public.runner_autoscale_state() to authenticated, service_role;
grant execute on function public._pool_cap() to authenticated, service_role;
