-- CHANGE #641 — never-again fix: an HTTP RPC may never run the regression guard.
-- Applied live via Supabase apply_migration; this file is the repo copy.
-- Idempotent: every statement is create-or-replace / on-conflict.

-- ═══ c641_completion_rpcs_never_run_rg_check ═══
-- CHANGE #641 (1) — an HTTP RPC may never run the regression guard.
--
-- Root cause, from the Postgres log Sep 1 20:47 UTC -> Sep 2 07:30: every
-- dev_cmd_complete_fast opened with rg_check_cached(900,false), whose miss path
-- is rg_check(true,true) — a 10-25 minute scan on this instance. The function's
-- own `SET statement_timeout '25s'` never applies mid-statement, so the runner's
-- curl gave up while the SERVER kept scanning; the runner retried; #463/#466/#573
-- were retried 98 times for roughly 18 hours of database time. CPU 98%, the
-- PostgREST schema cache fell into a 503 loop and every runner ended up in
-- standby.
--
-- The fix is structural, not a timeout: completion no longer knows what
-- rg_check is. It READS the last cached verdict for information and never
-- blocks on it. Compute is not being upgraded — this design must be incapable
-- of recurring.

create or replace function public.dev_cmd_complete_fast(
  p_id bigint, p_deploy_no integer default null, p_agent text default null)
returns jsonb language plpgsql security definer
set search_path to 'public'
set statement_timeout to '10s'
as $function$
declare r record; v_spec text; v_block text := null; v_enforce boolean; v_rg jsonb;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status = 'completed' then
    return jsonb_build_object('ok', true, 'already', true, 'id', p_id, 'status', 'completed',
      'change_no', r.web_deploy_no,
      'note', 'already completed — a retry of the fast write is a no-op by design');
  end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', false, 'error', 'not building', 'status', r.status);
  end if;

  -- CHANGE #571 (3) — the spec checklist gates the fast path too. Cheap: one
  -- indexed count over dev_command_spec_item.
  v_spec := _dev_spec_gate(p_id);
  if v_spec is not null then
    return jsonb_build_object('ok', false, 'retryable', false, 'blocked_by', 'spec_items',
      'error', v_spec, 'spec', dev_cmd_spec_items(p_id));
  end if;

  select coalesce((value->'bugloop'->>'enforce')::boolean, false) into v_enforce
    from dev_runner_config where key = 'worker_pool';
  if v_enforce and coalesce(r.kind,'dev') = 'dev' and coalesce(r.route,'') <> 'fast'
     and coalesce(r.qa_required,false) then
    if coalesce(r.qa_status,'pending') not in ('passed','waived') then
      v_block := 'QA is ' || coalesce(r.qa_status,'pending');
    elsif coalesce(r.steps_total,0) > 0 and coalesce(r.steps_done,0) < r.steps_total then
      v_block := 'steps ' || coalesce(r.steps_done,0) || '/' || r.steps_total;
    end if;
    if v_block is not null then
      return jsonb_build_object('ok', false, 'retryable', false, 'error',
        'bug-loop gate: ' || v_block);
    end if;
  end if;

  update dev_commands set
    status = 'completed', finished_at = now(),
    wait_state = null, wait_kind = null, wait_until = null,
    web_deploy_no   = coalesce(p_deploy_no, web_deploy_no),
    web_deployed_at = case when p_deploy_no is not null then now() else web_deployed_at end
  where id = p_id and status = 'building';
  if not found then
    return jsonb_build_object('ok', true, 'already', true, 'id', p_id,
      'note', 'closed concurrently — nothing left to do');
  end if;
  perform _lease_release_internal(p_id);
  perform _audit('system','dev_cmd_complete_fast', p_id::text,
    jsonb_build_object('agent', p_agent, 'deploy_no', p_deploy_no));

  -- INFORMATION ONLY. A single indexed read of the last cron-written verdict.
  -- It can be stale, it can be absent, and neither blocks a finished build.
  select jsonb_build_object('ok', c.ok, 'at', c.at,
           'age_s', round(extract(epoch from now() - c.at))::int)
    into v_rg from rg_check_cache c order by c.at desc limit 1;

  return jsonb_build_object('ok', true, 'phase', 'status', 'id', p_id,
    'status', 'completed', 'change_no', coalesce(p_deploy_no, r.web_deploy_no),
    'rg_last', v_rg, 'next', 'dev_cmd_result_write');
end $function$;

create or replace function public.dev_cmd_complete(
  p_id bigint, p_result text, p_deploy_no integer default null,
  p_screenshots jsonb default '[]'::jsonb, p_plain_summary text default null,
  p_result_actions jsonb default null)
returns jsonb language plpgsql security definer
set search_path to 'public'
set statement_timeout to '30s'
as $function$
DECLARE v_rg jsonb; v_row record; v_enforce boolean; v_missing text; v_block text := NULL;
        v_selftest record; v_spec text;
BEGIN
  PERFORM _dev_guard();

  -- CHANGE #641 — rg_check(true,true) used to run HERE, inside a 180 s
  -- statement, on the caller's connection. It is now cron-only; this is a read.
  SELECT jsonb_build_object('ok', c.ok, 'at', c.at,
           'age_s', round(extract(epoch from now() - c.at))::int)
    INTO v_rg FROM rg_check_cache c ORDER BY c.at DESC LIMIT 1;

  SELECT * INTO v_row FROM dev_commands WHERE id=p_id;
  SELECT coalesce((value->'bugloop'->>'enforce')::boolean,false) INTO v_enforce FROM dev_runner_config WHERE key='worker_pool';

  v_spec := _dev_spec_gate(p_id);
  IF v_spec IS NOT NULL THEN
    RAISE EXCEPTION 'dev_cmd_complete blocked (spec gate): %', v_spec;
  END IF;

  IF v_row.kind='dev' AND v_row.route <> 'fast' AND v_row.qa_required THEN
    IF v_row.qa_status NOT IN ('passed','waived') THEN
      v_block := 'QA verdict is '||v_row.qa_status||' — qa_report(passed) or qa_waive(PIN) required';
    END IF;
    IF v_block IS NULL AND EXISTS (
      SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.status='failed'
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr2 WHERE jr2.command_id=p_id AND jr2.journey_id=jr.journey_id AND jr2.status='passed' AND jr2.id>jr.id)
    ) THEN v_block := 'a journey run failed without a later pass'; END IF;
    IF v_block IS NULL THEN
      SELECT string_agg(j.name, ', ') INTO v_missing
      FROM dev_journeys j
      WHERE j.enabled
        AND (
              (j.required AND (j.area IS NULL OR j.area IS NOT DISTINCT FROM v_row.area))
              OR j.source_bug = p_id
            )
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.journey_id=j.id AND jr.status='passed');
      IF v_missing IS NOT NULL THEN v_block := 'required journeys not passed: '||v_missing; END IF;
    END IF;
    IF v_block IS NULL AND jsonb_array_length(coalesce(p_screenshots,'[]')) = 0 THEN
      v_block := 'no screenshot evidence attached';
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL THEN
      SELECT * INTO v_selftest FROM dev_selftest_log
       WHERE ok AND at > now() - interval '6 hours'
       ORDER BY at DESC LIMIT 1;
      IF NOT FOUND THEN
        v_block := 'no green self-test on record in the last 6h — scripts/selftest.sh '
                || '(protected suite + focused test) must pass before a web deploy';
      END IF;
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL AND v_row.targets_web
       AND coalesce(v_row.preview_status,'') <> 'promoted' THEN
      v_block := 'web deploy without preview→promote (preview_status='||coalesce(v_row.preview_status,'null')||')';
    END IF;

    IF v_block IS NOT NULL THEN
      IF v_enforce THEN
        RAISE EXCEPTION 'dev_cmd_complete blocked (bug-loop gate): %', v_block;
      ELSE
        PERFORM _audit('system','bugloop_warn', p_id::text, jsonb_build_object('would_block', v_block));
      END IF;
    END IF;
  END IF;

  UPDATE dev_commands SET
    status='completed', finished_at=now(),
    title = _dev_title(title, build_log),
    result_summary = p_result,
    plain_summary = coalesce(p_plain_summary, plain_summary),
    result_actions = coalesce(p_result_actions, '[]'::jsonb),
    web_deploy_no = coalesce(p_deploy_no, web_deploy_no),
    web_deployed_at = CASE WHEN p_deploy_no IS NOT NULL THEN now() ELSE web_deployed_at END,
    screenshots = coalesce(p_screenshots, '[]'),
    wait_state = NULL, wait_kind = NULL, wait_until = NULL
  WHERE id = p_id AND status='building';
  IF NOT FOUND THEN RAISE EXCEPTION 'dev_cmd_complete: row % not in building', p_id; END IF;
  IF coalesce(p_result,'') <> '' OR coalesce(p_plain_summary,'') <> '' THEN
    INSERT INTO dev_command_messages (command_id, sender, body, images, attachments)
    VALUES (p_id, 'agent',
      coalesce(nullif(p_plain_summary,''), p_result) ||
        CASE WHEN p_deploy_no IS NOT NULL THEN E'\n\n✅ CHANGE #'||p_deploy_no||' deployed' ELSE '' END,
      '[]', '[]');
  END IF;
  PERFORM _lease_release_internal(p_id);
  RETURN jsonb_build_object('ok', true, 'rg_last', v_rg, 'bugloop_warn', v_block);
END $function$;

-- ═══ c641_rg_check_budgeted_single_flight ═══
-- CHANGE #641 (2) — rg_check gets a hard budget and can only ever run once at
-- a time. Two properties, both structural:
--
--   * SINGLE FLIGHT. pg_try_advisory_xact_lock means a second caller does not
--     queue behind the first — it returns the last cached verdict immediately.
--     98 retries of the same command can no longer become 98 concurrent scans.
--     The lock is transaction-scoped, so it cannot leak on an exception.
--   * A 90 s BUDGET checked with clock_timestamp() BETWEEN test groups, which
--     is the only place a plpgsql function can honour one. `SET statement_timeout`
--     is not a budget: Postgres does not re-arm it mid-statement, which is why
--     the old '25s' on complete_fast was decorative. The statement_timeout of
--     120 s below is the backstop for a single group that overruns.
--
-- A run that hits the budget returns result='timeout' — NOT red. A timeout is
-- an unfinished measurement, and treating one as a regression would file a bug
-- command every two hours on a busy instance.

create or replace function public.rg_check(
  p_run_behaviors boolean default true, p_run_payloads boolean default true)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_catalog', 'cron'
set statement_timeout to '120s'
as $function$
declare
  v_kinds text[] := array['function','trigger','column','policy','index','cron','setting'];
  k text; v_d jsonb; v_diffs jsonb := '{}'::jsonb;
  v_over jsonb; v_missing jsonb; v_beh jsonb := '[]'::jsonb;
  v_crit int; v_changes int := 0; v_base int;
  v_errs jsonb := '[]'::jsonb; v_chg jsonb; v_n int;
  v_re jsonb; v_reerr jsonb;
  v_started timestamptz := clock_timestamp();
  v_budget_s int := coalesce(
    (select (value->'rg'->>'budget_s')::int from dev_runner_config where key='worker_pool'), 90);
  v_timeout boolean := false; v_stopped_at text := null;
  v_cached jsonb;
begin
  -- ONE AT A TIME. A caller that cannot get the lock never waits for it.
  if not pg_try_advisory_xact_lock(hashtext('public.rg_check')) then
    select c.result into v_cached from rg_check_cache c order by c.at desc limit 1;
    return coalesce(v_cached, '{}'::jsonb) || jsonb_build_object(
      'ok', coalesce((v_cached->>'ok')::boolean, false),
      'result', 'busy', 'busy', true, 'checked_at', now(),
      'note', 'another rg_check is already running — returning the last verdict');
  end if;

  if p_run_payloads then v_kinds := array_append(v_kinds, 'payload'); end if;
  foreach k in array v_kinds loop
    if clock_timestamp() > v_started + make_interval(secs => v_budget_s) then
      v_timeout := true; v_stopped_at := 'kind:' || k; exit;
    end if;
    select count(*) into v_base from rg_baseline b where b.kind = k;
    if v_base = 0 then continue; end if;

    with live as (select * from rg_collect(k)),
    base as (select * from rg_baseline b where b.kind = k)
    select jsonb_build_object(
      'added',   coalesce((select jsonb_agg(l.name) from live l left join base b on b.name = l.name where b.name is null),'[]'::jsonb),
      'removed', coalesce((select jsonb_agg(b.name) from base b left join live l on l.name = b.name where l.name is null),'[]'::jsonb),
      'changed', coalesce((select jsonb_agg(l.name) from live l join base b on b.name = l.name
                            where l.hash <> 'ERROR' and b.hash is distinct from l.hash),'[]'::jsonb),
      'errors',  coalesce((select jsonb_agg(jsonb_build_object(
                              'kind', k, 'name', l.name,
                              'sqlstate', l.content->>'sqlstate',
                              'error', l.content->>'error'))
                            from live l where l.hash = 'ERROR'),'[]'::jsonb))
    into v_d;

    -- CONFIRM BEFORE REPORT (#197). Payload targets snapshot live business
    -- state that legitimately moves mid-run; a second read settles it. The
    -- re-read may only CONFIRM drift, never clear it by failing.
    if k = 'payload' and jsonb_array_length(v_d->'changed') > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('name', l.name, 'hash', l.hash)), '[]'::jsonb)
        into v_re
        from rg_collect('payload') l
       where l.name in (select t.value from jsonb_array_elements_text(v_d->'changed') as t(value));

      select coalesce(jsonb_agg(e->>'name'), '[]'::jsonb) into v_chg
        from jsonb_array_elements(v_re) e
        join rg_baseline b on b.kind = 'payload' and b.name = e->>'name'
       where (e->>'hash') = 'ERROR'
          or b.hash is distinct from (e->>'hash');

      select coalesce(jsonb_agg(jsonb_build_object(
               'kind','payload', 'name', e->>'name', 'sqlstate','recheck',
               'error','confirm re-read failed — drift kept, not cleared')), '[]'::jsonb)
        into v_reerr
        from jsonb_array_elements(v_re) e where (e->>'hash') = 'ERROR';
      if jsonb_array_length(v_reerr) > 0 then v_errs := v_errs || v_reerr; end if;

      v_d := jsonb_set(v_d, '{changed}', v_chg) || jsonb_build_object('reconfirmed', true);
    end if;

    if jsonb_array_length(v_d->'errors') > 0 then
      v_errs := v_errs || (v_d->'errors');
    end if;
    v_d := v_d - 'errors';

    v_n := jsonb_array_length(v_d->'added') + jsonb_array_length(v_d->'removed') + jsonb_array_length(v_d->'changed');
    if v_n > 0 then
      v_diffs := v_diffs || jsonb_build_object(k, v_d);
      v_changes := v_changes + v_n;
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('severity', o.severity, 'fn', o.proname, 'a', o.sig_a, 'b', o.sig_b)),'[]'::jsonb)
    into v_over from rg_overload_risks() o;
  select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'name', m.name)),'[]'::jsonb)
    into v_missing from rg_missing_critical() m;

  if p_run_behaviors then
    if clock_timestamp() > v_started + make_interval(secs => v_budget_s) then
      v_timeout := true; v_stopped_at := coalesce(v_stopped_at, 'behaviors');
    else
      v_beh := rg_run_behaviors();
    end if;
  end if;

  v_crit := (select count(*) from jsonb_array_elements(v_over) e where e->>'severity' = 'critical')
          + jsonb_array_length(v_missing)
          + (select count(*) from jsonb_array_elements(v_beh) e where (e->>'ok')::boolean is not true);

  return jsonb_build_object(
    'ok', (not v_timeout and v_crit = 0 and v_changes = 0),
    'result', case when v_timeout then 'timeout'
                   when (v_crit = 0 and v_changes = 0) then 'green' else 'red' end,
    'timeout', v_timeout,
    'stopped_at', v_stopped_at,
    'budget_s', v_budget_s,
    'elapsed_s', round(extract(epoch from clock_timestamp() - v_started))::int,
    'checked_at', now(),
    'summary', jsonb_build_object('critical', v_crit, 'diffs', v_changes,
                                  'collection_errors', jsonb_array_length(v_errs)),
    'overload_risks', v_over,
    'missing_critical', v_missing,
    'collection_errors', v_errs,
    'behaviors', v_beh,
    'diffs', v_diffs);
end $function$;

-- The cache writer stops forcing a live scan on a miss when one is already in
-- flight: rg_check itself now answers 'busy' from cache in that case.
create or replace function public.rg_check_cached(
  p_max_age_s integer default 900, p_force boolean default false)
returns jsonb language plpgsql security definer
set search_path to 'public'
set statement_timeout to '125s'
as $function$
declare c record; v jsonb;
begin
  perform _dev_guard();
  if not p_force then
    select * into c from rg_check_cache
     where at > now() - (p_max_age_s || ' seconds')::interval
     order by at desc limit 1;
    if found then
      return c.result || jsonb_build_object('cached', true,
        'age_s', round(extract(epoch from now() - c.at))::int);
    end if;
  end if;
  v := rg_check(true, true);
  -- A timeout or a busy short-circuit is not a measurement: never cache one as
  -- if it were, or the next reader inherits a verdict nobody took.
  if coalesce(v->>'result','') not in ('timeout','busy') then
    insert into rg_check_cache (ok, result) values (coalesce((v->>'ok')::boolean,false), v);
    delete from rg_check_cache where at < now() - interval '2 days';
  end if;
  return v || jsonb_build_object('cached', false, 'age_s', 0);
end $function$;

-- ═══ c641_rg_watch_files_bug_and_two_new_guards ═══
-- CHANGE #641 (2)(3) — rg_watch is now the ONLY place a full scan is taken,
-- it writes the verdict everything else reads, and a red verdict becomes a
-- WORK ITEM instead of a wall that finished builds crash into.

create or replace function public.rg_watch()
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare r jsonb; rec record; fp text; v_res text; v_change int; v_open bigint; v_new bigint;
begin
  r := rg_check(true, true);
  v_res := coalesce(r->>'result', case when coalesce((r->>'ok')::boolean,false) then 'green' else 'red' end);

  -- A busy short-circuit measured nothing: record nothing, decide nothing.
  if v_res = 'busy' then
    return jsonb_build_object('ok', r->'ok', 'result', 'busy', 'at', now());
  end if;

  insert into rg_runs(ok, report) values ((r->>'ok')::boolean, r);
  delete from rg_runs where ran_at < now() - interval '30 days';

  -- The verdict every cheap reader (dev_cmd_complete_fast, the Dev Queue card)
  -- shows. A timeout is not a measurement and must never become the cached one.
  if v_res <> 'timeout' then
    insert into rg_check_cache (ok, result) values (coalesce((r->>'ok')::boolean,false), r);
    delete from rg_check_cache where at < now() - interval '2 days';
  else
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (md5('rg_timeout|' || to_char(date_trunc('hour', now()),'YYYY-MM-DD HH24')),
            'warn', 'rg_timeout',
            format('rg_check hit its %ss budget at %s', coalesce(r->>'budget_s','90'),
                   coalesce(r->>'stopped_at','?')),
            jsonb_build_object('elapsed_s', r->'elapsed_s', 'stopped_at', r->'stopped_at'))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end if;

  for rec in select value as v from jsonb_array_elements(r->'overload_risks') loop
    fp := md5('overload|'||(rec.v->>'fn')||'|'||(rec.v->>'a')||'|'||(rec.v->>'b'));
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, rec.v->>'severity', 'overload', rec.v->>'fn', rec.v)
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;
  for rec in select value as v from jsonb_array_elements(r->'missing_critical') loop
    fp := md5('missing|'||(rec.v->>'kind')||'|'||(rec.v->>'name'));
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, 'critical', 'missing_'||(rec.v->>'kind'), rec.v->>'name', rec.v)
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;
  for rec in select value as v from jsonb_array_elements(r->'behaviors') where ((value->>'ok')::boolean) is not true loop
    fp := md5('behavior|'||(rec.v->>'name'));
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, 'critical', 'behavior', rec.v->>'name', rec.v)
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;
  for rec in
    select d.key as k2, t.typ, n.nm
    from jsonb_each(r->'diffs') d,
         lateral (values ('added'),('removed'),('changed')) t(typ),
         lateral jsonb_array_elements_text(d.value->t.typ) n(nm)
  loop
    fp := md5('diff|'||rec.k2||'|'||rec.typ||'|'||rec.nm);
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, 'warn', 'diff_'||rec.k2, rec.nm, jsonb_build_object('type', rec.typ))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;

  -- RED IS A COMMAND, NOT A BLOCKER (#641). One open row at a time: a guard
  -- that stays red for a day must not file a bug every two hours.
  if v_res = 'red' then
    select d.change_no into v_change from deploy_registry d
     where d.deployed_at is not null order by d.deployed_at desc limit 1;
    select c.id into v_open from dev_commands c
     where c.title like 'RG red after #%' and c.status in ('pending','building','needs_input')
     order by c.id desc limit 1;
    if v_open is null then
      insert into dev_commands (title, spec, urgent, priority, kind, qa_required, targets_web)
      values ('RG red after #' || coalesce(v_change::text, '?'),
              'The regression guard went red on the scheduled run after change #'
              || coalesce(v_change::text, '?') || E'.\n\n'
              || 'Read the newest rg_runs row (select report from rg_runs order by ran_at desc limit 1) '
              || 'and the open rg_alerts. For each diff decide: an INTENTIONAL change gets rebaselined '
              || '(devcmd.sh rebaseline), an UNINTENTIONAL one gets fixed in the code. Behaviour '
              || 'failures and missing_critical are never rebaselined — fix them. Finish with '
              || 'devcmd.sh rgcheck printing true.' || E'\n\n'
              || 'Summary at the time it was filed: ' || coalesce(r->>'summary','{}'),
              true, 1, 'dev', false, false)
      returning id into v_new;
    end if;
  end if;

  begin
    perform rg_probe_edges();
  exception when others then null;
  end;
  return jsonb_build_object('ok', r->'ok', 'result', v_res, 'summary', r->'summary',
    'bug_command', v_new, 'at', now());
end $function$;

-- ── (3) the new RG rule: no HTTP RPC may call the guard inline ───────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values (
'c641_no_rg_in_http_rpcs',
$probe$
do $rg$
declare v_bad text;
begin
  -- Comments are stripped first: the rule is about what the function CALLS,
  -- and this very rule is described in a comment inside dev_cmd_complete.
  select string_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
                    ', ' order by p.proname)
    into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like 'dev\_cmd\_%' or p.proname like 'dev\_ctl\_%' or p.proname like 'merge\_%')
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g')
         ~* '(\mrg_(check|baseline)[a-z_]*|\mdev_journeys_run)[[:space:]]*\(';
  if v_bad is not null then
    raise exception 'RG_FAIL: an HTTP RPC calls the regression guard inline (CHANGE #641 — this is what pinned the instance for 11 hours): %', v_bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$probe$,
true,
'CHANGE #641 — dev_cmd_*/dev_ctl_*/merge_* are called over HTTP with a client deadline. rg_check/rg_baseline/dev_journeys_run take minutes. A call from one to the other is the outage of 2026-09-01, so it is a guard, not a convention.')
on conflict (name) do update set body = excluded.body, enabled = true, note = excluded.note;

-- ── (7) the protected timing test, where it can actually run ────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values (
'c641_complete_fast_under_2s',
$probe$
do $rg$
declare v_id bigint := -641; v_t timestamptz; v_ms numeric; v jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('role','service_role')::text, true);

  -- A reserved negative id, so the probe never consumes a real command number.
  delete from dev_commands where id = v_id;
  insert into dev_commands (id, title, spec, status, kind, route, claimed_by,
                            started_at, qa_required, targets_web, auto_debug)
  overriding system value
  values (v_id, 'rg probe — complete_fast timing', 'rg probe', 'building', 'dev',
          'fast', 'rg-probe', now(), false, false, false);
  -- Whatever derived a spec checklist for it is not what we are timing.
  delete from dev_command_spec_item where command_id = v_id;

  v_t := clock_timestamp();
  v   := public.dev_cmd_complete_fast(v_id, null, 'rg-probe');
  v_ms := extract(epoch from (clock_timestamp() - v_t)) * 1000;

  if coalesce((v->>'ok')::boolean, false) is not true then
    raise exception 'RG_FAIL: complete_fast refused a seeded building row: %', v;
  end if;
  if v_ms > 2000 then
    raise exception 'RG_FAIL: dev_cmd_complete_fast took % ms — the budget is 2000 ms. An RPC a runner calls over HTTP must never do heavy work (CHANGE #641).', round(v_ms);
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$probe$,
true,
'CHANGE #641 (7) — seeds a building command, times dev_cmd_complete_fast end to end and fails over 2 s. It lives here, not in test/protected/, because that suite is Dart-VM-only with no Supabase (CLAUDE.md); this is the only place the real RPC can be timed against the real database.')
on conflict (name) do update set body = excluded.body, enabled = true, note = excluded.note;

-- ═══ c641_rpc_watchdog_and_circuit_breaker ═══
-- CHANGE #641 (4)(6) — the two things that were missing while the instance was
-- pinned for eleven hours: nothing killed the runaway server-side calls after
-- the clients had already given up on them, and nothing stopped the fleet from
-- adding more.

-- Config defaults. Knobs live in worker_pool so they change with pool_set(),
-- never a deploy.
update public.dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{rpc_watchdog}',
        coalesce(value->'rpc_watchdog','{}'::jsonb) || jsonb_build_object(
          'enabled', coalesce(value->'rpc_watchdog'->'enabled', 'true'::jsonb),
          'cancel_after_s', coalesce(value->'rpc_watchdog'->'cancel_after_s', '90'::jsonb),
          'breaker_count', coalesce(value->'rpc_watchdog'->'breaker_count', '10'::jsonb),
          'breaker_window_min', coalesce(value->'rpc_watchdog'->'breaker_window_min', '5'::jsonb)),
        true)
 where key = 'worker_pool';

update public.dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{rg}',
        coalesce(value->'rg','{}'::jsonb) || jsonb_build_object(
          'budget_s', coalesce(value->'rg'->'budget_s', '90'::jsonb)), true)
 where key = 'worker_pool';

insert into public.dev_runner_config (key, value)
values ('db_breaker', jsonb_build_object('tripped', false))
on conflict (key) do nothing;

insert into public.ui_copy (key, value) values
  ('dev_queue.breaker_label',  to_jsonb('Auto-paused: DB timeouts'::text)),
  ('dev_queue.breaker_detail', to_jsonb('{n} database timeouts in {win} min — Workflow was switched off at {at} IST so the runners stop adding load. Fix the slow call, then turn Workflow back on.'::text)),
  ('dev_queue.breaker_clear',  to_jsonb('Cleared'::text))
on conflict (key) do nothing;

-- ── (4) cancel what the client already abandoned ────────────────────────────
create or replace function public.db_rpc_watchdog_tick()
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_catalog'
set statement_timeout to '10s'
as $function$
declare
  cfg jsonb; v_on boolean; v_after int; v_count int; v_win int;
  rec record; v_killed int := 0; v_list jsonb := '[]'::jsonb;
  v_recent int; v_wf text; v_state jsonb; v_tripped boolean := false;
begin
  select coalesce(value->'rpc_watchdog','{}'::jsonb) into cfg
    from dev_runner_config where key = 'worker_pool';
  v_on    := coalesce((cfg->>'enabled')::boolean, true);
  v_after := coalesce((cfg->>'cancel_after_s')::int, 90);
  v_count := coalesce((cfg->>'breaker_count')::int, 10);
  v_win   := coalesce((cfg->>'breaker_window_min')::int, 5);
  if not v_on then return jsonb_build_object('ok', true, 'enabled', false); end if;

  -- A PostgREST backend still running past the deadline is, by definition, work
  -- nobody is waiting for any more: devcmd.sh gives up at 70 s. Leaving it to
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
      -- cannot signal that backend: report it, never crash the dispatcher
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

  -- ── (6) the circuit breaker ───────────────────────────────────────────────
  select count(*) into v_recent from db_timeout_event
   where at > now() - make_interval(mins => v_win);

  select coalesce(value->>'workflow','off') into v_wf
    from dev_runner_config where key = 'desired_state';

  if v_recent >= v_count and v_wf = 'on' then
    update dev_runner_config
       set value = jsonb_set(value, '{workflow}', to_jsonb('off'::text))
     where key = 'desired_state';

    v_state := jsonb_build_object('tripped', true, 'at', now(),
                 'count', v_recent, 'window_min', v_win, 'threshold', v_count);
    update dev_runner_config set value = v_state where key = 'db_breaker';
    v_tripped := true;

    insert into rg_alerts (fingerprint, severity, kind, name, detail)
    values (md5('db_breaker|' || to_char(now(),'YYYY-MM-DD HH24:MI')),
            'critical', 'db_breaker',
            format('auto-paused: %s DB timeouts in %s min — Workflow switched off',
                   v_recent, v_win),
            v_state)
    on conflict (fingerprint) do update set last_seen = now(),
      seen_count = rg_alerts.seen_count + 1, detail = excluded.detail;

    perform _audit('system','db_breaker_trip', null, v_state);
    begin
      perform wa_send_event('dev_cmd_daily_digest', null, jsonb_build_object(
        'done','0','failed','0','pending','0',
        'titles', format('⚠ auto-paused: %s DB timeouts in %s min — Workflow is OFF',
                         v_recent, v_win)), null, null);
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'killed', v_killed,
    'timeouts_in_window', v_recent, 'window_min', v_win,
    'threshold', v_count, 'breaker_tripped', v_tripped);
end $function$;

revoke all on function public.db_rpc_watchdog_tick() from public, anon, authenticated;

-- Every minute, alongside the existing db_watchdog. step_timeout keeps it
-- honest: this task may never be the thing that is slow.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                              enabled, dml, base_interval_s, max_interval_s, note)
values ('rpc_watchdog', 4, 'poll', 'select true',
        'select public.db_rpc_watchdog_tick()', 12000, true, true, 60, 60,
        'CHANGE #641 — cancels PostgREST calls the client has already abandoned and trips the workflow breaker on a timeout storm.')
on conflict (name) do update set
  ord = excluded.ord, mode = excluded.mode, gate_sql = excluded.gate_sql,
  work_sql = excluded.work_sql, step_timeout_ms = excluded.step_timeout_ms,
  enabled = true, dml = true, base_interval_s = 60, max_interval_s = 60,
  note = excluded.note;

-- (2) rg_check "after each deploy": a gate, not a hook — it fires on the first
-- dispatch after a deploy_registry row goes live with nothing scanned since.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms,
                              enabled, dml, base_interval_s, max_interval_s, note)
values ('rg_after_deploy', 909, 'poll',
        $g$select exists (
             select 1 from public.deploy_registry d
              where d.deployed_at is not null
                and d.deployed_at > coalesce((select max(ran_at) from public.rg_runs), 'epoch'::timestamptz))$g$,
        'select public.rg_watch()', 125000, true, true, 120, 600,
        'CHANGE #641 — the post-deploy regression scan. rg_check is cron-only now, so this is what runs it after a change goes live.')
on conflict (name) do update set
  ord = excluded.ord, mode = excluded.mode, gate_sql = excluded.gate_sql,
  work_sql = excluded.work_sql, step_timeout_ms = excluded.step_timeout_ms,
  enabled = true, dml = true, base_interval_s = 120, max_interval_s = 600,
  note = excluded.note;

update public.cron_task
   set step_timeout_ms = 125000,
       note = 'CHANGE #641 — the every-2h scan. rg_check budgets itself at 90s and runs one at a time.'
 where name = 'rg_watch_2h';

-- ═══ c641_breaker_badge_in_dev_ctl ═══
-- CHANGE #641 (6, frontend half) — the breaker is only real if Om can SEE that
-- it fired. dev_ctl_get renders the badge; the strip prints it verbatim.

create or replace function public.dev_ctl_set(p_key text, p_value text)
returns jsonb language plpgsql security definer
set search_path to 'public'
as $function$
DECLARE v jsonb;
BEGIN
  PERFORM _dev_guard();
  IF p_key NOT IN ('vm','claude','workflow') THEN RAISE EXCEPTION 'dev_ctl_set: bad key'; END IF;
  IF p_value NOT IN ('on','off') THEN RAISE EXCEPTION 'dev_ctl_set: bad value'; END IF;
  IF (_sec_cfg()->>'frozen')::boolean AND p_value='on' THEN RAISE EXCEPTION 'frozen — unlock with PIN first'; END IF;
  UPDATE dev_runner_config SET value = jsonb_set(value, ARRAY[p_key], to_jsonb(p_value)) WHERE key='desired_state'
  RETURNING value INTO v;
  PERFORM _audit(_actor(),'toggle_set', p_key, jsonb_build_object('value',p_value));

  -- Turning Workflow back on IS the acknowledgement: the badge clears with it,
  -- so it can never outlive the pause it is describing.
  IF p_key = 'workflow' AND p_value = 'on' THEN
    UPDATE dev_runner_config
       SET value = jsonb_build_object('tripped', false, 'cleared_at', now(),
                                      'last', value)
     WHERE key = 'db_breaker' AND coalesce((value->>'tripped')::boolean, false);
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
END $function$;

create or replace function public._dev_breaker_badge()
returns jsonb language plpgsql stable security definer
set search_path to 'public'
as $function$
declare b jsonb; v_at timestamptz;
begin
  select value into b from dev_runner_config where key = 'db_breaker';
  if not coalesce((b->>'tripped')::boolean, false) then
    return jsonb_build_object('tripped', false, 'label', '', 'detail', '', 'tone', 'neutral');
  end if;
  begin v_at := (b->>'at')::timestamptz; exception when others then v_at := null; end;
  return jsonb_build_object(
    'tripped', true,
    'tone',    'danger',
    'label',   coalesce((select value#>>'{}' from ui_copy where key='dev_queue.breaker_label'), ''),
    'detail',  replace(replace(replace(
        coalesce((select value#>>'{}' from ui_copy where key='dev_queue.breaker_detail'), ''),
        '{n}',   coalesce(b->>'count','?')),
        '{win}', coalesce(b->>'window_min','?')),
        '{at}',  coalesce(to_char(v_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'), '—')),
    'at', v_at, 'count', b->'count', 'window_min', b->'window_min');
end $function$;

create or replace function public.dev_ctl_get()
returns jsonb language plpgsql security definer
set search_path to 'public'
as $function$
DECLARE v_counts jsonb; v_ds jsonb; vm text; cl text; wf text;
        vm_l boolean; cl_l boolean; wf_l boolean;
        v_vm jsonb; v_poll jsonb; v_age numeric; v_status text; v_live boolean;
        v_cfg jsonb; v_rs jsonb; v_ps jsonb; v_rs_age numeric; v_ps_age numeric;
        v_rs_stale boolean; v_ps_stale boolean; v_rc text;
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

  RETURN jsonb_build_object(
    'desired_state', v_ds,
    'runner_status', v_rs,
    'vm',            v_vm,
    'vm_poll',       v_poll,
    'vm_identity',   coalesce((SELECT value FROM dev_runner_config WHERE key='vm_identity'), '{}'::jsonb),
    'queue_counts',  v_counts,
    'breaker',       _dev_breaker_badge(),
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
END $function$;

