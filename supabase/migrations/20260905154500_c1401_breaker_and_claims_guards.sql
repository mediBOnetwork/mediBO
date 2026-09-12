-- CHANGE #1401 — two guards the fleet lost this afternoon, both repaired here.
--
-- 1. c755_self_healing_breaker went RED on live at 15:16 with
--    "RG_FAIL c755: 10 timeouts left semaphore at 3 (score 100)". Nothing about
--    the breaker changed: #1593's autoscaler v2 made runner_health_probe score
--    whichever database is being JUDGED, and a live build branch's
--    timeouts_5min replaces production's. The fixture inserts production
--    timeout rows, so from that moment the test's verdict depended on whether a
--    branch happened to be up. It now says which database it means.
--
-- 2. #1662's stranded migration (20260905210000_c1662_journeys_run_claims.sql)
--    took the whole of batch 538 down with
--    'ERROR: "c290_run_claims" is not a known variable'. It is a string-patch
--    that bolts a claims restore onto the OLD 2-arg dev_journeys_run — the
--    function 20260905153000 replaced with the bounded 4-arg one that restores
--    the claims properly. It is broken AND superseded: if it ever succeeded it
--    would resurrect the unbounded loop. Its own guard stands down when the
--    function already assigns c290_run_claims, so the claims variable is
--    adopted under exactly that name. The landmine defuses itself, on a branch
--    nobody owns any more, without anyone editing it.
--
-- Both halves are idempotent.

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
  c290_run_claims text; j record; v jsonb; st text; v_ev jsonb;
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
  c290_run_claims := coalesce(current_setting('request.jwt.claims', true), '');

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

    perform set_config('request.jwt.claims', c290_run_claims, true);
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

  -- CHANGE #1401 — PIN THE DATABASE THIS TEST IS JUDGING.
  -- #1593 (autoscaler v2) made runner_health_probe score whichever database is
  -- being judged: when a build branch is up and freshly reported, the branch's
  -- timeouts_5min REPLACES production's. This fixture inserts ten PRODUCTION
  -- timeout rows, so from that change on the assertion below passed or failed
  -- purely on whether a branch happened to be alive — it read
  -- "10 timeouts left semaphore at 3 (score 100)" the moment one was.
  -- The promise c755 makes is about the breaker, not about branch selection, so
  -- the fixture states which database it means instead of inheriting the fleet's
  -- current one. Everything here is rolled back by RG_ROLLBACK.
  begin execute 'delete from public.branch_health';
  exception when others then null; end;

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

