-- CHANGE #1663 — Slow call: dev_journeys_run — bound it.
--
-- The runner breaker named dev_journeys_run as the worst offender: 5 CANCELLED
-- calls in one episode with worst_s 0. Zero is the tell — the call never got
-- far enough to record a duration. The authenticator role carries
-- statement_timeout=8s, and dev_journeys_run looped over EVERY enabled journey
-- for an area (85 in the library today: 21 storefront + 3 global = 24 probes in
-- one HTTP call), calling dev_journey_probe on each. Each probe runs real RPCs
-- against real rows. So the call could not fit in 8s, was killed mid-loop, and
-- did it again on retry — burning connections (18 of 60 at the trip) and
-- leaving half-written run batches behind.
--
-- Two unbounded shapes, both fixed here:
--   1. The LOOP had no ceiling. It now takes at most `row_ceiling` journeys per
--      call (config-driven, default 8, hard max 40) and stops early on a
--      wall-clock `budget_ms` (default 5000, hard max 7000 — under the 8s
--      timeout), returning a cursor so the caller pages instead of being killed.
--   2. The promote-to-required check ran `count(*)` over dev_journey_runs ONCE
--      PER JOURNEY with no index on journey_id — the scalar-helper-scan
--      anti-pattern. It is now ONE set-based UPDATE for the whole page, and the
--      per-row test stops at 2 index tuples (`limit 2`) instead of counting
--      every passed run that ever existed.
-- dev_journey_probe's external-proof branch carried the same unbounded count;
-- it is patched in place below (from its live definition, so this file cannot
-- revert whatever else that function has grown).
--
-- Idempotent: safe to replay on live.

-- ── 1. The indexes the counts were missing ────────────────────────────────────
create index if not exists idx_journey_runs_passed
  on public.dev_journey_runs (journey_id)
  where status = 'passed';

create index if not exists idx_journey_runs_ext_passed
  on public.dev_journey_runs (journey_id)
  where status = 'passed' and not (evidence ? 'db_proof');

-- Ordered early-stop for the page window.
create index if not exists idx_dev_journeys_enabled_id
  on public.dev_journeys (id)
  where enabled;

-- ── 2. The knob, so the ceiling moves without a deploy ────────────────────────
update public.dev_runner_config
   set value = jsonb_set(value, '{journeys}',
         coalesce(value->'journeys','{}'::jsonb)
           || jsonb_build_object('max_per_run', coalesce(value->'journeys'->'max_per_run', to_jsonb(8)),
                                 'budget_ms',   coalesce(value->'journeys'->'budget_ms',   to_jsonb(5000))),
         true)
 where key = 'worker_pool';

-- ── 3. The bounded call ───────────────────────────────────────────────────────
-- Adding defaulted parameters to the 2-arg function would make every existing
-- 2-arg call ambiguous, so the old signature is dropped first. Callers that
-- pass only (p_command_id, p_area) keep working and get the first page.
drop function if exists public.dev_journeys_run(bigint, text);

create or replace function public.dev_journeys_run(
  p_command_id bigint,
  p_area       text,
  p_after_id   bigint default null,
  p_limit      int     default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text; j record; v jsonb; st text; v_ev jsonb;
  passed int := 0; failed int := 0; skipped int := 0;
  v_cfg jsonb; v_limit int; v_budget int;
  v_t0 timestamptz; v_p0 timestamptz; v_ms int;
  v_cursor bigint := coalesce(p_after_id, 0);
  v_last   bigint := coalesce(p_after_id, 0);
  v_scanned int := 0;
  v_stop text := 'complete';
  v_passed_ids bigint[] := '{}';
  promoted text[] := '{}';
  runs jsonb := '[]';
  v_more boolean;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'dev_journeys_run: runner only';
  end if;
  v_claims := coalesce(current_setting('request.jwt.claims', true), '');

  select coalesce(value->'journeys', '{}'::jsonb) into v_cfg
    from dev_runner_config where key = 'worker_pool';
  v_cfg := coalesce(v_cfg, '{}'::jsonb);

  -- The ceiling is a hard cap, not a suggestion: config can lower it, nothing
  -- can raise it past 40 rows or past 7s of a role that is killed at 8s.
  v_limit  := greatest(1,   least(coalesce(p_limit, nullif(v_cfg->>'max_per_run','')::int, 8),   40));
  v_budget := greatest(500, least(coalesce(nullif(v_cfg->>'budget_ms','')::int, 5000),         7000));

  v_t0 := clock_timestamp();

  for j in
    select id, name, required
      from dev_journeys
     where enabled
       and (area is null or area = p_area)
       and id > v_cursor
     order by id
     limit v_limit
  loop
    -- Budget checked BEFORE each probe: a page returns a result, never a
    -- cancellation. Whatever is left comes back on the next page.
    if extract(epoch from (clock_timestamp() - v_t0)) * 1000 >= v_budget then
      v_stop := 'budget';
      exit;
    end if;

    perform set_config('request.jwt.claims', v_claims, true);
    v_p0 := clock_timestamp();
    v := dev_journey_probe(j.name);
    v_ms := (extract(epoch from (clock_timestamp() - v_p0)) * 1000)::int;

    insert into dev_journey_runs(command_id, journey_id, status, evidence, duration_ms)
    values (p_command_id, j.id, v->>'status', coalesce(v->'evidence','{}'), v_ms)
    returning status, evidence into st, v_ev;

    v_scanned := v_scanned + 1;
    v_last    := j.id;

    if st = 'passed' then
      passed := passed + 1;
      if not j.required then v_passed_ids := v_passed_ids || j.id; end if;
    elsif st = 'failed' then failed := failed + 1;
    else skipped := skipped + 1;
    end if;

    runs := runs || jsonb_build_object('journey', j.name, 'status', st,
                                       'evidence', v_ev, 'duration_ms', v_ms);
  end loop;

  -- Promote to required once green twice — ONE statement for the whole page,
  -- and each row's test reads at most 2 tuples from idx_journey_runs_passed.
  if array_length(v_passed_ids, 1) > 0 then
    with promo as (
      update dev_journeys dj
         set required = true
       where dj.id = any(v_passed_ids)
         and not dj.required
         and (select count(*) from (
                select 1 from dev_journey_runs r
                 where r.journey_id = dj.id and r.status = 'passed'
                 limit 2) z) >= 2
      returning dj.name)
    select coalesce(array_agg(name), '{}'::text[]) into promoted from promo;
  end if;

  if passed > 0 then
    update dev_commands set journey_pass_count = journey_pass_count + passed
     where id = p_command_id;
  end if;

  select exists (select 1 from dev_journeys
                  where enabled and (area is null or area = p_area) and id > v_last)
    into v_more;
  if v_more and v_stop = 'complete' then v_stop := 'ceiling'; end if;

  return jsonb_build_object(
    'ok', true, 'area', p_area,
    'passed', passed, 'failed', failed, 'skipped', skipped,
    'promoted_to_required', promoted, 'runs', runs,
    'scanned', v_scanned, 'row_ceiling', v_limit, 'budget_ms', v_budget,
    'elapsed_ms', (extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int,
    'stopped', v_stop, 'has_more', coalesce(v_more, false), 'next_after_id', v_last);
end $fn$;

grant execute on function public.dev_journeys_run(bigint, text, bigint, int)
  to postgres, anon, authenticated, service_role;

-- ── 4. The same unbounded count inside dev_journey_probe ──────────────────────
-- Patched from the definition that is live at replay time, so this file never
-- reverts an unrelated change to that 36 KB dispatcher. A no-op once applied.
do $mig$
declare v_def text; v_new text;
begin
  v_def := pg_get_functiondef('public.dev_journey_probe(text)'::regprocedure);

  v_new := replace(v_def,
$old$    select count(*) into v_pass_count
    from dev_journey_runs
    where journey_id = v_jid and status = 'passed'
      and not (coalesce(evidence,'{}'::jsonb) ? 'db_proof');
    if v_pass_count >= 2 then
      return jsonb_build_object('status','passed','evidence',
        jsonb_build_object('db_proof',
          'browser runner recorded '||v_pass_count||' passed runs for '||p_name));$old$,
$new$    -- CHANGE #1663: bounded. The question is "are there two?", not "how
    -- many are there?" — this stops at the 2nd tuple of
    -- idx_journey_runs_ext_passed instead of counting every passed run a
    -- journey ever had. (evidence is NOT NULL default '{}', so the coalesce
    -- that used to wrap it only served to hide the index.)
    select count(*) into v_pass_count
    from (select 1 from dev_journey_runs
           where journey_id = v_jid and status = 'passed'
             and not (evidence ? 'db_proof')
           limit 2) z;
    if v_pass_count >= 2 then
      return jsonb_build_object('status','passed','evidence',
        jsonb_build_object('db_proof',
          'browser runner recorded at least 2 passed runs for '||p_name));$new$);

  if v_new <> v_def then
    execute v_new;
    raise notice 'CHANGE #1663: dev_journey_probe external-proof count bounded';
  else
    raise notice 'CHANGE #1663: dev_journey_probe already bounded (no-op)';
  end if;
end $mig$;
