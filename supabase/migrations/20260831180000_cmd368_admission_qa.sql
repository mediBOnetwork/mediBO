-- CMD #368 — Adaptive runner admission control, right-sized QA, and the
-- #301 session guardrails applied SERVER-SIDE so no agent can skip them.
--
-- Evidence this exists for (31 Aug 2026, 15:15–16:25 UTC): five Opus runners
-- claimed #352–#356 inside fifteen minutes, the 1 GB instance logged 37 agent
-- statement timeouts plus cron "job startup timeout" in that window, and every
-- agent query crawled. #352 took 61 min / ₹1,215, #353 69 min, #355 68 min,
-- #356 63 min — the CODE was finished long before the wall clock was. Two
-- causes, both fixed here: nothing limited how many heavy runners hit the DB at
-- once, and size_class landed on 'xlarge' for 100% of rows (opus_min_chars=0
-- makes `n >= c_opus` always true), so a two-row defect fix bought the same
-- multi-round hostile QA as a data-model rewrite.
--
-- Everything below is idempotent: a resumed worker re-applies it as a no-op.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. ADMISSION CONTROL — the claim is refused BEFORE a runner loads a context
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.dev_admission_config (
  id                      boolean primary key default true check (id),
  enabled                 boolean not null default true,
  max_concurrent_builds   int     not null default 3,
  timeouts_5min_max       int     not null default 3,
  conn_pct_max            int     not null default 75,
  long_txn_seconds_max    int     not null default 120,
  retry_after_seconds     int     not null default 45,
  sample_stale_seconds    int     not null default 180,
  heartbeat_fresh_seconds int     not null default 300,
  heavy_statement_seconds int     not null default 25,
  updated_at              timestamptz not null default now(),
  updated_by              text
);
insert into public.dev_admission_config (id) values (true) on conflict (id) do nothing;
alter table public.dev_admission_config enable row level security;

create table if not exists public.dev_admission_event (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  agent    text,
  admitted boolean not null,
  reason   text,
  detail   text,
  pressure jsonb
);
alter table public.dev_admission_event enable row level security;
create index if not exists dev_admission_event_at_idx on public.dev_admission_event (at desc);
create index if not exists db_timeout_event_at_idx     on public.db_timeout_event (at desc);

-- A cheap read of how loaded the instance is right now. Prefers the watchdog's
-- own minute sample (already written by db_watchdog_tick) and only touches
-- pg_stat_activity when that sample has gone stale, so five runners polling
-- every 60 s cost the instance almost nothing.
create or replace function public.db_pressure_snapshot()
returns jsonb
language plpgsql stable security definer set search_path to 'public', 'pg_catalog'
as $$
declare
  cfg    public.dev_admission_config%rowtype;
  s      public.db_health_sample%rowtype;
  v_fresh boolean := false;
  v_conns int; v_max int; v_txn int; v_to int; v_builds int; v_pct int;
begin
  select * into cfg from public.dev_admission_config where id;
  select * into s from public.db_health_sample order by at desc limit 1;
  v_fresh := s.at is not null
             and s.at > now() - make_interval(secs => cfg.sample_stale_seconds);

  if v_fresh then
    v_conns := s.conns; v_max := s.max_conns; v_txn := s.longest_txn_s;
  else
    select count(*), coalesce(max(extract(epoch from (now() - xact_start)))::int, 0)
      into v_conns, v_txn
      from pg_stat_activity where datname = current_database();
    v_max := coalesce(nullif(current_setting('max_connections', true), '')::int, 60);
  end if;

  select count(*) into v_to
    from public.db_timeout_event where at > now() - interval '5 minutes';

  -- Only a runner that is still BEATING counts as heavy load. A zombie row left
  -- in 'building' by a killed session must never wedge the whole fleet out of
  -- the queue — that would turn a safety valve into an outage.
  select count(*) into v_builds
    from public.dev_commands
   where status = 'building'
     and heartbeat_at > now() - make_interval(secs => cfg.heartbeat_fresh_seconds);

  v_pct := case when coalesce(v_max, 0) > 0
                then round(v_conns::numeric * 100 / v_max)::int else 0 end;

  return jsonb_build_object(
    'conns', v_conns, 'max_conns', v_max, 'conn_pct', v_pct,
    'longest_txn_s', v_txn, 'timeouts_5min', v_to,
    'builds_in_flight', v_builds,
    'source', case when v_fresh then 'watchdog sample' else 'live read' end,
    'sampled_at', s.at);
end $$;

-- The gate itself. Returns admit:true/false plus the sentence the runner logs
-- and the app renders — the caller words nothing.
create or replace function public.db_admission_check(p_agent text default null)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_catalog'
as $$
declare
  cfg    public.dev_admission_config%rowtype;
  p      jsonb;
  v_reason text := null;
  v_detail text := null;
begin
  select * into cfg from public.dev_admission_config where id;
  p := public.db_pressure_snapshot();

  if not cfg.enabled then
    return jsonb_build_object('admit', true, 'pressure', p,
      'label', 'Admission control is off — every claim is admitted.');
  end if;

  -- Floor: with nothing in flight the queue must always be able to start, even
  -- on a sick instance. Otherwise a bad minute could freeze the fleet forever
  -- with no runner left to fix it.
  if (p->>'builds_in_flight')::int = 0 then
    return jsonb_build_object('admit', true, 'pressure', p, 'floor', true,
      'label', 'Admitted — nothing is building, so the first claim always goes through.');
  end if;

  if (p->>'builds_in_flight')::int >= cfg.max_concurrent_builds then
    v_reason := 'builds_in_flight';
    v_detail := format('%s builds already in flight — this instance sustains %s at a time.',
                       p->>'builds_in_flight', cfg.max_concurrent_builds);
  elsif (p->>'timeouts_5min')::int > cfg.timeouts_5min_max then
    v_reason := 'statement_timeouts';
    v_detail := format('%s statement timeouts in the last 5 minutes — ceiling is %s.',
                       p->>'timeouts_5min', cfg.timeouts_5min_max);
  elsif (p->>'conn_pct')::int > cfg.conn_pct_max then
    v_reason := 'connections';
    v_detail := format('%s of %s connections in use (%s%%) — ceiling is %s%%.',
                       p->>'conns', p->>'max_conns', p->>'conn_pct', cfg.conn_pct_max);
  elsif (p->>'longest_txn_s')::int > cfg.long_txn_seconds_max then
    v_reason := 'long_transaction';
    v_detail := format('a transaction has been open %s s — ceiling is %s s.',
                       p->>'longest_txn_s', cfg.long_txn_seconds_max);
  end if;

  if v_reason is null then
    return jsonb_build_object('admit', true, 'pressure', p,
      'label', format('Admitted — %s of %s builds in flight, %s timeouts in 5 min.',
                      p->>'builds_in_flight', cfg.max_concurrent_builds, p->>'timeouts_5min'));
  end if;

  insert into public.dev_admission_event (agent, admitted, reason, detail, pressure)
  values (coalesce(p_agent, 'agent'), false, v_reason, v_detail, p);
  delete from public.dev_admission_event where at < now() - interval '3 days';

  return jsonb_build_object(
    'admit', false,
    'reason', v_reason,
    'detail', v_detail,
    'retry_after_seconds', cfg.retry_after_seconds,
    'pressure', p,
    'label', format('DB busy — retry in %s s · %s', cfg.retry_after_seconds, v_detail),
    'instruction', format('Do not claim. Sleep %s s and try again — the queue is NOT empty, so this is not an idle tick and must not count toward idle shutdown.',
                          cfg.retry_after_seconds));
end $$;

-- Editable from admin (Dev Queue → Cron health → Database lane).
create or replace function public.db_admission_set(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
begin
  perform public._dev_guard();
  update public.dev_admission_config set
    enabled = coalesce((p_patch->>'enabled')::boolean, enabled),
    max_concurrent_builds = greatest(least(coalesce((p_patch->>'max_concurrent_builds')::int, max_concurrent_builds), 8), 1),
    timeouts_5min_max     = greatest(least(coalesce((p_patch->>'timeouts_5min_max')::int, timeouts_5min_max), 100), 0),
    conn_pct_max          = greatest(least(coalesce((p_patch->>'conn_pct_max')::int, conn_pct_max), 100), 20),
    long_txn_seconds_max  = greatest(least(coalesce((p_patch->>'long_txn_seconds_max')::int, long_txn_seconds_max), 3600), 10),
    retry_after_seconds   = greatest(least(coalesce((p_patch->>'retry_after_seconds')::int, retry_after_seconds), 600), 5),
    heavy_statement_seconds = greatest(least(coalesce((p_patch->>'heavy_statement_seconds')::int, heavy_statement_seconds), 600), 5),
    updated_at = now(),
    updated_by = coalesce(p_patch->>'by', auth.jwt()->>'email', 'admin')
  where id;
  return public.db_admission_status();
end $$;

-- The render-ready block. Every label, every hint, every sentence is built
-- here; the Flutter card prints them in payload order and computes nothing.
create or replace function public.db_admission_status()
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_catalog'
as $$
declare cfg public.dev_admission_config%rowtype; p jsonb; v_ref int; v_last timestamptz;
begin
  perform public._dev_guard();
  select * into cfg from public.dev_admission_config where id;
  p := public.db_pressure_snapshot();
  select count(*), max(at) into v_ref, v_last
    from public.dev_admission_event where at > now() - interval '24 hours' and not admitted;

  return jsonb_build_object(
    'label', 'Runner admission control',
    'value_label', case when not cfg.enabled
      then 'Off — every claim is admitted regardless of database pressure.'
      else format('%s of %s builds in flight · %s timeouts in 5 min · %s connections (%s%%) · %s claim(s) held back in 24 h',
                  p->>'builds_in_flight', cfg.max_concurrent_builds, p->>'timeouts_5min',
                  p->>'conns', p->>'conn_pct', v_ref) end,
    'tone', case when not cfg.enabled then 'neutral'
                 when (p->>'builds_in_flight')::int >= cfg.max_concurrent_builds
                   or (p->>'timeouts_5min')::int > cfg.timeouts_5min_max then 'warning'
                 else 'success' end,
    'source_label', format('Pressure read from the %s%s',
       p->>'source',
       case when p->>'sampled_at' is null then ''
            else format(' taken %s IST', to_char((p->>'sampled_at')::timestamptz at time zone 'Asia/Kolkata','DD Mon HH24:MI:SS')) end),
    'updated_label', format('Thresholds updated %s IST by %s',
       to_char(cfg.updated_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
       coalesce(cfg.updated_by, 'setup')),
    'toggle', jsonb_build_object('key','enabled','label','Admission control','value',cfg.enabled,
       'hint','Off lets every runner claim no matter how loaded the database is — that is the behaviour that produced the 15:15 choke.'),
    'thresholds', jsonb_build_array(
      jsonb_build_object('key','max_concurrent_builds','label','Concurrent builds',
        'value',cfg.max_concurrent_builds,'min',1,'max',8,'unit','builds',
        'hint','Five runners choked the 1 GB instance; two to three fly. A sixth claim waits instead of crawling.'),
      jsonb_build_object('key','timeouts_5min_max','label','Statement timeouts in 5 min',
        'value',cfg.timeouts_5min_max,'min',0,'max',100,'unit','timeouts',
        'hint','Above this the instance is already shedding work — a new build would only add to it.'),
      jsonb_build_object('key','conn_pct_max','label','Connections in use',
        'value',cfg.conn_pct_max,'min',20,'max',100,'unit','%',
        'hint','Percent of max_connections. Slot starvation is what served Cloudflare 520s on 18 Aug.'),
      jsonb_build_object('key','long_txn_seconds_max','label','Longest open transaction',
        'value',cfg.long_txn_seconds_max,'min',10,'max',3600,'unit','s',
        'hint','A transaction held this long is blocking others; adding a runner makes the queue worse.'),
      jsonb_build_object('key','retry_after_seconds','label','Retry after',
        'value',cfg.retry_after_seconds,'min',5,'max',600,'unit','s',
        'hint','How long a refused runner sleeps. It idles cheaply — it never loads a context it cannot use.'),
      jsonb_build_object('key','heavy_statement_seconds','label','Heavy statement',
        'value',cfg.heavy_statement_seconds,'min',5,'max',600,'unit','s',
        'hint','A statement running longer than this outside the DB work lane is logged as a lane violation.')),
    'recent_heading', 'Claims held back',
    'recent_empty', 'No runner has been held back in the last 24 hours — the fleet has stayed under every ceiling.',
    'recent', coalesce((select jsonb_agg(jsonb_build_object(
         'at_label', to_char(e.at at time zone 'Asia/Kolkata','DD Mon HH24:MI:SS'),
         'label', e.agent, 'detail', e.detail, 'tone', 'warning') order by e.at desc)
       from (select * from public.dev_admission_event
              where not admitted order by at desc limit 8) e), '[]'::jsonb));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. THE CLAIM GATE — dev_cmd_claim / dev_cmd_claim_batch refuse under pressure
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.dev_cmd_claim(p_agent text, p_routes text[] DEFAULT NULL::text[], p_prefer_area text DEFAULT NULL::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE v jsonb; v_res jsonb; v_blocked int; v_adm jsonb; v_scope jsonb;
BEGIN
  PERFORM _dev_guard();
  IF (_sec_cfg()->>'frozen')::boolean THEN RETURN jsonb_build_object('empty',true,'frozen',true); END IF;
  IF (sec_check_budget()->>'over')::boolean THEN RETURN jsonb_build_object('empty',true,'budget_paused',true); END IF;

  -- CMD #368 — admission control. Refuse BEFORE the runner boots a context, so
  -- an overloaded instance costs a 45 s sleep instead of an hour of crawling.
  v_adm := db_admission_check(p_agent);
  IF coalesce((v_adm->>'admit')::boolean, true) = false THEN
    RETURN jsonb_build_object('empty', true, 'db_busy', true,
      'retry_after_seconds', coalesce((v_adm->>'retry_after_seconds')::int, 45),
      'reason', v_adm->>'label', 'admission', v_adm);
  END IF;

  UPDATE dev_commands dc SET status='building', claimed_by=p_agent, started_at=now(), heartbeat_at=now(),
         resume_count = resume_count + CASE WHEN dc.steps_done > 0 THEN 1 ELSE 0 END
  WHERE dc.id = (
    SELECT c.id FROM dev_commands c
    WHERE c.status='pending'
      AND (p_routes IS NULL OR c.route = ANY(p_routes))
      AND NOT EXISTS (SELECT 1 FROM dev_commands d WHERE d.id = ANY(c.depends_on) AND d.status <> 'completed')
      AND NOT EXISTS (
        SELECT 1 FROM dev_commands b
        WHERE b.status = 'building' AND b.id <> c.id
          AND dev_paths_overlap(dev_cmd_footprint(b.id), c.predicted_files))
    ORDER BY c.urgent DESC,
             (p_prefer_area IS NOT NULL AND c.area IS NOT DISTINCT FROM p_prefer_area) DESC,
             c.priority, c.id
    FOR UPDATE OF c SKIP LOCKED LIMIT 1
  )
  RETURNING to_jsonb(dc) INTO v;
  IF v IS NULL THEN
    SELECT count(*) INTO v_blocked FROM dev_commands c
     WHERE c.status='pending' AND (p_routes IS NULL OR c.route = ANY(p_routes));
    RETURN jsonb_build_object('empty', true, 'pending_blocked', v_blocked,
      'reason', CASE WHEN v_blocked > 0
        THEN 'Every pending command is chained behind work in flight — nothing to build without a file collision.'
        ELSE 'Queue empty.' END);
  END IF;
  v_res := _dev_resume_block(v);
  -- CMD #368 — grade the QA depth from real scope the moment the row is owned,
  -- and hand the runner the guardrails its session is already running under.
  v_scope := dev_qa_scope((v->>'id')::bigint);
  RETURN v || jsonb_build_object('resume', v_res,
                                 'is_resume', coalesce((v_res->>'is_resume')::boolean, false),
                                 'qa_scope', v_scope,
                                 'session_guard', db_guard_check());
END $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. RIGHT-SIZED QA — grade by real scope, not by a size_class that is always
--    'xlarge' (routing.opus_min_chars = 0 makes `n >= c_opus` always true)
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.dev_qa_scope_config (
  id                      boolean primary key default true check (id),
  enabled                 boolean not null default true,
  targeted_max_files      int not null default 3,
  targeted_max_spec_chars int not null default 1500,
  standard_max_files      int not null default 8,
  deep_min_spec_chars     int not null default 6000,
  rounds_targeted         int not null default 1,
  rounds_standard         int not null default 1,
  rounds_deep             int not null default 2,
  updated_at timestamptz not null default now(),
  updated_by text
);
insert into public.dev_qa_scope_config (id) values (true) on conflict (id) do nothing;
alter table public.dev_qa_scope_config enable row level security;

alter table public.dev_commands add column if not exists qa_scope text;
alter table public.dev_commands add column if not exists qa_rounds int not null default 0;

-- Grades one command and stores the grade on the row. Volatile on purpose: the
-- footprint sharpens as leases land, so calling it again after lease_learn is
-- how a command that turned out small gets a targeted round instead of a deep
-- one. Returns the whole plan — the QA agent runs exactly what is listed.
create or replace function public.dev_qa_scope(p_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  cfg   public.dev_qa_scope_config%rowtype;
  r     record;
  v_files text[];
  v_n int; v_chars int; v_mig boolean; v_dart boolean;
  v_scope text; v_why text; v_rounds int;
begin
  select * into cfg from public.dev_qa_scope_config where id;
  select id, spec, is_danger, kind, route, size_class, area, qa_required
    into r from public.dev_commands where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'not_found', true);
  end if;

  v_files := coalesce(public.dev_cmd_footprint(p_id), '{}');
  v_n     := coalesce(array_length(v_files, 1), 0);
  v_chars := length(coalesce(r.spec, ''));
  v_mig   := exists (select 1 from unnest(v_files) f where f like 'supabase/%');
  v_dart  := exists (select 1 from unnest(v_files) f where f like '%.dart');

  if not cfg.enabled then
    v_scope := 'deep';
    v_why   := 'Scope grading is switched off — every command gets the deep treatment.';
  elsif r.is_danger then
    v_scope := 'deep';
    v_why   := 'Deep — the row is flagged dangerous, so QA gets the full hostile pass whatever its size.';
  elsif v_chars >= cfg.deep_min_spec_chars or v_n > cfg.standard_max_files then
    v_scope := 'deep';
    v_why   := format('Deep — %s files touched and a %s-character spec: genuinely large work.', v_n, v_chars);
  elsif v_n > 0 and v_n <= cfg.targeted_max_files and v_chars <= cfg.targeted_max_spec_chars then
    v_scope := 'targeted';
    v_why   := format('Targeted — %s file(s) touched, %s-character spec. One round against the preview is the right size; a two-row defect fix does not need a multi-round hostile pass.',
                      v_n, v_chars);
  else
    v_scope := 'standard';
    v_why   := format('Standard — %s file(s) touched, %s-character spec.', v_n, v_chars);
  end if;

  v_rounds := case v_scope when 'targeted' then cfg.rounds_targeted
                           when 'standard' then cfg.rounds_standard
                           else cfg.rounds_deep end;

  update public.dev_commands set qa_scope = v_scope where id = p_id;

  return jsonb_build_object(
    'ok', true, 'command_id', p_id,
    'scope', v_scope,
    'rounds_max', v_rounds,
    'files_touched', v_n,
    'spec_chars', v_chars,
    'has_migration', v_mig,
    'has_dart', v_dart,
    'label', case v_scope
      when 'targeted' then format('Targeted QA · %s round', v_rounds)
      when 'standard' then format('Standard QA · %s round', v_rounds)
      else format('Deep QA · up to %s rounds', v_rounds) end,
    'tone', case v_scope when 'targeted' then 'success' when 'standard' then 'info' else 'warning' end,
    'why', v_why,
    'checks', case v_scope
      when 'targeted' then jsonb_build_array('boot', 'version', 'area smoke')
      when 'standard' then jsonb_build_array('boot', 'version', 'api smoke', 'area smoke')
      else jsonb_build_array('boot', 'version', 'api smoke', 'area smoke', 'edge cases', 'spec promises') end,
    'instruction', format('Run %s QA round(s) against the PREVIEW. Hold no lane while testing — QA never takes the deploy lock or a DB lane.', v_rounds));
end $$;

create or replace function public.dev_qa_scope_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
begin
  perform public._dev_guard();
  update public.dev_qa_scope_config set
    enabled                 = coalesce((p_patch->>'enabled')::boolean, enabled),
    targeted_max_files      = greatest(least(coalesce((p_patch->>'targeted_max_files')::int, targeted_max_files), 50), 1),
    targeted_max_spec_chars = greatest(least(coalesce((p_patch->>'targeted_max_spec_chars')::int, targeted_max_spec_chars), 20000), 100),
    standard_max_files      = greatest(least(coalesce((p_patch->>'standard_max_files')::int, standard_max_files), 100), 1),
    deep_min_spec_chars     = greatest(least(coalesce((p_patch->>'deep_min_spec_chars')::int, deep_min_spec_chars), 50000), 500),
    rounds_targeted         = greatest(least(coalesce((p_patch->>'rounds_targeted')::int, rounds_targeted), 5), 1),
    rounds_standard         = greatest(least(coalesce((p_patch->>'rounds_standard')::int, rounds_standard), 5), 1),
    rounds_deep             = greatest(least(coalesce((p_patch->>'rounds_deep')::int, rounds_deep), 5), 1),
    updated_at = now(),
    updated_by = coalesce(p_patch->>'by', auth.jwt()->>'email', 'admin')
  where id;
  return jsonb_build_object('ok', true);
end $$;

-- qa_report counts the round it just filed, so "rounds used vs rounds allowed"
-- is a fact on the row rather than something an agent remembers.
create or replace function public.qa_report(p_command_id bigint, p_verdict text, p_findings jsonb DEFAULT '[]'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE f jsonb; n int := 0; v_area text; v_fid bigint; v_jn text;
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN RAISE EXCEPTION 'qa_report: runner only'; END IF;
  IF p_verdict NOT IN ('running','passed','failed') THEN RAISE EXCEPTION 'qa_report: bad verdict'; END IF;
  SELECT area INTO v_area FROM dev_commands WHERE id=p_command_id;
  UPDATE dev_commands SET qa_status = p_verdict,
         qa_rounds = qa_rounds + CASE WHEN p_verdict IN ('passed','failed') THEN 1 ELSE 0 END
   WHERE id = p_command_id;
  FOR f IN SELECT * FROM jsonb_array_elements(p_findings) LOOP
    INSERT INTO qa_findings(command_id, severity, title, detail)
    VALUES (p_command_id, coalesce(f->>'severity','major'), f->>'title', f->>'detail')
    RETURNING id INTO v_fid;
    n := n+1;
    IF coalesce(f->>'severity','major') = 'blocker' THEN
      v_jn := 'qa-'||p_command_id||'-'||v_fid;
      INSERT INTO dev_journeys(name, area, kind, steps, source_bug, required, enabled)
      VALUES (v_jn, v_area, 'api',
              jsonb_build_array('TODO implement before completing #'||p_command_id||' — must reproduce QA blocker: '||left(coalesce(f->>'title',''),150)),
              p_command_id, false, true)
      ON CONFLICT (name) DO NOTHING;
    END IF;
  END LOOP;
  IF p_verdict='failed' THEN
    INSERT INTO dev_command_messages(command_id, sender, body)
    VALUES (p_command_id,'system','🔍 QA failed: '||n||' finding(s). Fix and re-run QA before completing.');
  END IF;
  RETURN jsonb_build_object('ok',true,'findings',n,'scope',dev_qa_scope(p_command_id));
END $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE #301 GUARDRAILS, SERVER-SIDE — a runner cannot skip what it never sets
-- ═══════════════════════════════════════════════════════════════════════════
-- service_role already carried lock_timeout=5s and
-- idle_in_transaction_session_timeout=30s; statement_timeout was never set, so
-- one bad agent query could run until the instance gave up. PostgREST applies
-- pg_db_role_setting per request (this is how Supabase caps anon at 3 s and
-- authenticated at 8 s), so this reaches EVERY runner session with no client
-- co-operation at all. Functions that legitimately need longer keep their own
-- `SET statement_timeout` — a function-level setting always wins.
do $$
begin
  execute 'alter role service_role set statement_timeout = ''55s''';
  execute 'alter role service_role set lock_timeout = ''5s''';
  execute 'alter role service_role set idle_in_transaction_session_timeout = ''30s''';
exception when insufficient_privilege then
  raise notice 'cmd368: could not ALTER ROLE service_role — guardrails stay client-side';
end $$;

-- rg_baseline_all and rg_check already carry their own `SET statement_timeout
-- TO '180000'`, and a function-level setting outranks the role setting — so the
-- 55 s cap cannot make the regression guard start failing on a busy instance.

create or replace function public.db_guard_check()
returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare cfg public.db_guard_config%rowtype; v_st text; v_lt text; v_it text; v_guarded boolean;
begin
  perform public._db_guard();
  select * into cfg from public.db_guard_config where id;
  v_st := current_setting('statement_timeout');
  v_lt := current_setting('lock_timeout');
  v_it := current_setting('idle_in_transaction_session_timeout');
  -- CMD #368: statement_timeout joins the two the role already carried. All
  -- three now arrive as role settings, so `guarded` reports what the SERVER
  -- applied rather than whether the agent remembered to ask.
  v_guarded := (v_st <> '0' and v_lt <> '0' and v_it <> '0');
  return jsonb_build_object('ok', true,
    'user', current_user,
    'statement_timeout', v_st, 'lock_timeout', v_lt,
    'idle_in_transaction_session_timeout', v_it,
    'policy', jsonb_build_object('statement_timeout_ms', cfg.statement_timeout_ms,
                                 'lock_timeout_ms', cfg.lock_timeout_ms,
                                 'idle_in_txn_ms', cfg.idle_in_txn_ms,
                                 'max_batch_rows', cfg.max_batch_rows),
    'guarded', v_guarded,
    'source', 'ALTER ROLE service_role — PostgREST applies role settings on every request, so no runner can skip them',
    'label', case when v_guarded
      then format('Session capped server-side: statement %s · lock %s · idle-in-transaction %s. Bulk writes still go in batches of at most %s rows.',
                  v_st, v_lt, v_it, cfg.max_batch_rows)
      else 'This session is NOT capped — call db_session_guard() before any heavy DB step.' end,
    'instruction', 'If guarded is false, call db_session_guard() before running any heavy DB step.');
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. HEAVY WORK OUTSIDE THE LANE IS LOGGED, NOT TRUSTED TO GOODWILL
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.db_lane_violation (
  id      bigserial primary key,
  at      timestamptz not null default now(),
  pid     int,
  usename text,
  seconds int,
  query   text,
  detail  jsonb
);
alter table public.db_lane_violation enable row level security;
create index if not exists db_lane_violation_at_idx on public.db_lane_violation (at desc);

-- Runs on the cron dispatcher. Any statement that has been active longer than
-- heavy_statement_seconds and looks like DDL / a bulk write / a VACUUM, while
-- db_work_lock holds nothing, is recorded. This is the enforcement an agent
-- cannot skip: it observes the database, not the agent's intentions.
create or replace function public.db_lane_violation_scan()
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_catalog'
as $$
declare cfg public.dev_admission_config%rowtype; v_locks int; v_n int := 0; v_bucket text;
begin
  select * into cfg from public.dev_admission_config where id;
  perform public._db_lock_reap();
  select count(*) into v_locks from public.db_work_lock;
  if v_locks > 0 then
    return jsonb_build_object('ok', true, 'skipped', 'lane held', 'violations', 0);
  end if;

  with heavy as (
    select a.pid, a.usename,
           round(extract(epoch from (now() - a.query_start)))::int as secs,
           left(a.query, 300) as q
      from pg_stat_activity a
     where a.datname = current_database()
       and a.state = 'active'
       and a.pid <> pg_backend_pid()
       and a.query_start < now() - make_interval(secs => cfg.heavy_statement_seconds)
       and a.query ~* '^\s*(create\s+(unique\s+)?index|alter\s+table|drop\s+table|vacuum|reindex|cluster|truncate|refresh\s+materialized)'
  ), ins as (
    insert into public.db_lane_violation (pid, usename, seconds, query, detail)
    select h.pid, h.usename, h.secs, h.q,
           jsonb_build_object('threshold_s', cfg.heavy_statement_seconds)
      from heavy h
     where not exists (
       select 1 from public.db_lane_violation v
        where v.pid = h.pid and v.query = h.q and v.at > now() - interval '10 minutes')
    returning 1)
  select count(*) into v_n from ins;

  if v_n > 0 then
    v_bucket := to_char(date_trunc('hour', now()), 'YYYY-MM-DD HH24');
    insert into public.rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('db_lane|violation|'||v_bucket), 'warn', 'db_lane_violation',
            format('%s heavy statement(s) ran outside the DB work lane', v_n),
            jsonb_build_object('count', v_n, 'threshold_s', cfg.heavy_statement_seconds))
    on conflict (fingerprint) do update set last_seen = now(),
      seen_count = public.rg_alerts.seen_count + 1, detail = excluded.detail;
  end if;

  delete from public.db_lane_violation where at < now() - interval '14 days';
  return jsonb_build_object('ok', true, 'violations', v_n);
end $$;

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, dml,
                              base_interval_s, max_interval_s, note)
values ('db_lane_violation_scan', 6, 'poll', 'select true',
        'select public.db_lane_violation_scan()', true, true, 60, 600,
        'CMD #368 — records a heavy statement that ran outside the db_work_lock lane.')
on conflict (name) do update set work_sql = excluded.work_sql,
                                 enabled  = excluded.enabled,
                                 note     = excluded.note;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. SURFACES — the Database lane card and the command's QA section
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.db_health_status()
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_catalog'
as $$
declare
  cfg  public.db_watchdog_config%rowtype;
  lcfg public.db_work_lock_config%rowtype;
  gcfg public.db_guard_config%rowtype;
  s    public.db_health_sample%rowtype;
  v_ex int; v_hr int; v_peak int; v_alerts int; v_tone text; v_viol int;
begin
  begin
    perform public._db_guard();
  exception when others then
    return jsonb_build_object('ok', false, 'title', 'Database lane',
      'error', coalesce((select value #>> '{}' from public.ui_copy
                          where key = 'dev_queue.db_lane_forbidden'), ''));
  end;

  select * into cfg  from public.db_watchdog_config where id;
  select * into lcfg from public.db_work_lock_config where id;
  select * into gcfg from public.db_guard_config where id;
  select * into s from public.db_health_sample order by at desc limit 1;
  perform public._db_lock_reap();
  select count(*) filter (where kind = 'exclusive'), count(*) filter (where kind = 'heavy_read')
    into v_ex, v_hr from public.db_work_lock;
  select coalesce(max(conns), 0) into v_peak
    from public.db_health_sample where at > now() - interval '24 hours';
  select count(*) into v_alerts
    from public.rg_alerts where kind like 'db\_%' and last_seen > now() - interval '7 days';
  select count(*) into v_viol
    from public.db_lane_violation where at > now() - interval '7 days';

  v_tone := case
    when s.at is null then 'warning'
    when s.conns > cfg.conn_max - 5 or s.timeouts_5min > cfg.timeouts_5min_warn then 'error'
    when s.conns > cfg.conn_warn or s.longest_txn_s > cfg.long_txn_seconds then 'warning'
    else 'success' end;

  return jsonb_build_object(
    'ok', true,
    'title', 'Database lane',
    'tone', v_tone,
    'headline', case when s.at is null
      then 'The watchdog has not sampled yet — it runs on the next dispatcher tick.'
      else format('%s of %s connections · peak %s in 24 h · %s statement timeouts in the last 5 minutes',
                  s.conns, s.max_conns, v_peak, s.timeouts_5min) end,
    'sampled_label', case when s.at is null then 'never'
      else format('Sampled %s IST', to_char(s.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI:SS')) end,
    'stats', jsonb_build_array(
      jsonb_build_object('label', 'Connections', 'value', format('%s / %s', coalesce(s.conns, 0), coalesce(s.max_conns, cfg.conn_max))),
      jsonb_build_object('label', 'Longest transaction', 'value', format('%s s', coalesce(s.longest_txn_s, 0))),
      jsonb_build_object('label', 'Timeouts (5 min)', 'value', coalesce(s.timeouts_5min, 0)::text)),
    'lanes', jsonb_build_array(
      jsonb_build_object(
        'label', 'Exclusive — DDL, bulk writes over 20k rows, VACUUM, index builds',
        'value_label', case when v_ex + v_hr = 0
            then format('%s slot · free', lcfg.exclusive_slots)
            else format('%s slot · busy', lcfg.exclusive_slots) end,
        'tone', case when v_ex + v_hr = 0 then 'success' else 'info' end),
      jsonb_build_object(
        'label', 'Heavy read — scans and audits over a big table',
        'value_label', case when v_ex > 0
            then format('%s slots · blocked by an exclusive step', lcfg.heavy_read_slots)
            else format('%s slots · %s in use', lcfg.heavy_read_slots, v_hr) end,
        'tone', case when v_ex > 0 then 'info' when v_hr >= lcfg.heavy_read_slots then 'warning' else 'success' end)),
    'held', coalesce((select jsonb_agg(jsonb_build_object(
              'label', format('%s · %s', l.holder, case l.kind when 'exclusive' then 'exclusive' else 'heavy read' end),
              'detail', format('%s · held %s s · expires in %s s',
                               coalesce(l.title, 'untitled'),
                               round(extract(epoch from (now() - l.acquired_at)))::int,
                               greatest(round(extract(epoch from (l.expires_at - now())))::int, 0)),
              'tone', 'info') order by l.acquired_at) from public.db_work_lock l), '[]'::jsonb),
    'held_empty', 'No agent is holding a database lane. Coding, tests and web builds never take one — only the rare exclusive step does.',
    'admission', public.db_admission_status(),
    'guard', jsonb_build_object('label', 'Session guardrails',
      'value_label', format('statement %s s · lock %s s · idle-in-transaction %s s · bulk writes in batches of %s — applied to every runner session as a role setting, not by the agent',
                            gcfg.statement_timeout_ms / 1000, gcfg.lock_timeout_ms / 1000,
                            gcfg.idle_in_txn_ms / 1000, gcfg.max_batch_rows)),
    'violations', jsonb_build_object('label', 'Heavy work outside the lane',
      'value_label', case when v_viol = 0
        then 'None in 7 days — every heavy statement took the lane first.'
        else format('%s heavy statement(s) ran outside the lane in 7 days', v_viol) end,
      'tone', case when v_viol = 0 then 'success' else 'warning' end,
      'recent', coalesce((select jsonb_agg(jsonb_build_object(
            'at_label', to_char(x.at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
            'label', format('%s · %s s', coalesce(x.usename,'?'), x.seconds),
            'detail', left(x.query, 160)) order by x.at desc)
          from (select * from public.db_lane_violation order by at desc limit 5) x), '[]'::jsonb)),
    'window', jsonb_build_object('label', 'Heavy scheduled audits',
      'value_label', format('%s jobs run in the 21:00–02:00 UTC window (02:30–07:30 IST)',
        (select count(*) from cron.job where active
          and schedule ~ '^[0-9]+ (2[1-3]|0[01]) '))),
    'alerts', jsonb_build_object('label', 'Watchdog',
      'value_label', format('%s database alerts in 7 days · thresholds: %s connections, %s s transaction, %s timeouts in 5 min',
                            v_alerts, cfg.conn_warn, cfg.long_txn_seconds, cfg.timeouts_5min_warn),
      'quiet', 'Quiet — no connection, transaction or timeout alert in the last 7 days.',
      'recent', coalesce((select jsonb_agg(jsonb_build_object(
            'at_label', to_char(a.last_seen at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'),
            'severity', a.severity, 'kind', a.kind, 'name', a.name,
            'detail', format('seen %s time(s) · first %s IST', a.seen_count,
                             to_char(a.first_seen at time zone 'Asia/Kolkata', 'DD Mon HH24:MI')))
          order by a.last_seen desc)
        from (select * from public.rg_alerts where kind like 'db\_%'
               order by last_seen desc limit 8) a), '[]'::jsonb)));
end $$;

-- The command's QA section now says which size of QA this row earned and why.
create or replace function public.dev_cmd_qa_detail(p_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v jsonb; v_findings jsonb; v_runs jsonb; v_qa text; v_prev text; v_jpc int; v_req boolean;
        v_scope jsonb; v_rounds int;
begin
  perform _dev_guard();
  select qa_status, preview_status, journey_pass_count, qa_required, qa_rounds
    into v_qa, v_prev, v_jpc, v_req, v_rounds
    from dev_commands where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'not_found', true);
  end if;
  v_scope := dev_qa_scope(p_id);

  select coalesce(jsonb_agg(to_jsonb(f) order by f.ord, f.id), '[]') into v_findings from (
    select qf.id,
           coalesce(qf.severity,'info') as severity,
           case coalesce(qf.severity,'info')
             when 'critical' then 'Critical' when 'high' then 'High'
             when 'medium' then 'Medium' when 'low' then 'Low' else 'Info' end as severity_label,
           case coalesce(qf.severity,'info')
             when 'critical' then 'error' when 'high' then 'error'
             when 'medium' then 'warning' when 'low' then 'info' else 'neutral' end as severity_tone,
           case coalesce(qf.severity,'info')
             when 'critical' then 0 when 'high' then 1 when 'medium' then 2 when 'low' then 3 else 4 end as ord,
           coalesce(qf.title,'') as title,
           coalesce(qf.detail,'') as detail,
           coalesce(qf.status,'open') as status,
           case coalesce(qf.status,'open')
             when 'open' then 'Open' when 'fixed' then 'Fixed'
             when 'waived' then 'Waived' else initcap(coalesce(qf.status,'open')) end as status_label,
           case coalesce(qf.status,'open')
             when 'fixed' then 'success' when 'waived' then 'neutral' else 'error' end as status_tone,
           qf.fix_command
    from qa_findings qf where qf.command_id = p_id
  ) f;

  select coalesce(jsonb_agg(to_jsonb(r) order by r.at desc), '[]') into v_runs from (
    select jr.id, jr.journey_id,
           coalesce(j.name, 'journey #'||jr.journey_id) as name,
           coalesce(j.area,'global') as area,
           coalesce(jr.status,'') as status,
           case coalesce(jr.status,'')
             when 'passed' then '✅ Passed' when 'failed' then '❌ Failed'
             when 'skipped' then '⏭ Skipped' when 'running' then '🔍 Running'
             else coalesce(jr.status,'') end as status_label,
           case coalesce(jr.status,'')
             when 'passed' then 'success' when 'failed' then 'error'
             when 'skipped' then 'neutral' else 'info' end as status_tone,
           coalesce(jr.evidence,'{}'::jsonb) as evidence,
           case when jr.duration_ms is null then ''
                else (round(jr.duration_ms/1000.0,1)::text||'s') end as duration_display,
           to_char((jr.at at time zone 'Asia/Kolkata'),'DD Mon, HH24:MI') as at_display,
           jr.at
    from dev_journey_runs jr
    left join dev_journeys j on j.id = jr.journey_id
    where jr.command_id = p_id
  ) r;

  v := jsonb_build_object(
    'ok', true,
    'command_id', p_id,
    'qa_status', coalesce(v_qa,'pending'),
    'qa_required', coalesce(v_req,false),
    'qa_status_label', case coalesce(v_qa,'pending')
        when 'pending' then 'QA pending' when 'running' then 'QA testing'
        when 'passed' then 'QA passed' when 'failed' then 'QA failed'
        when 'waived' then 'QA waived' else coalesce(v_qa,'pending') end,
    'qa_status_tone', case coalesce(v_qa,'pending')
        when 'passed' then 'success' when 'failed' then 'error'
        when 'running' then 'info' when 'waived' then 'neutral' else 'neutral' end,
    'can_waive', (coalesce(v_qa,'') = 'failed'),
    'scope', v_scope,
    'scope_label', coalesce(v_scope->>'label',''),
    'scope_tone', coalesce(v_scope->>'tone','neutral'),
    'scope_why', coalesce(v_scope->>'why',''),
    'rounds_label', format('%s of %s round(s) used', coalesce(v_rounds,0),
                           coalesce((v_scope->>'rounds_max')::int, 1)),
    'preview_status', coalesce(v_prev,''),
    'preview_label', case coalesce(v_prev,'')
        when 'deployed' then 'On preview' when 'promoted' then 'Promoted to production' else '' end,
    'journey_pass_count', coalesce(v_jpc,0),
    'findings', v_findings,
    'findings_empty', c_ui('dev_queue.qa_no_findings'),
    'runs', v_runs,
    'runs_empty', c_ui('dev_queue.qa_no_runs')
  );
  return v;
end $function$;

grant execute on function public.db_pressure_snapshot()      to service_role;
grant execute on function public.db_admission_check(text)    to service_role;
grant execute on function public.db_admission_status()       to service_role, authenticated;
grant execute on function public.db_admission_set(jsonb)     to service_role, authenticated;
grant execute on function public.db_guard_check()            to service_role, authenticated;
grant execute on function public.db_lane_violation_scan()    to service_role;
grant execute on function public.dev_qa_scope(bigint)        to service_role, authenticated;
grant execute on function public.dev_qa_scope_set(jsonb)     to service_role, authenticated;
