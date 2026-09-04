-- CHANGE #1160 (B) — a timing guard must measure the CODE, not the weather.
--
-- While this command was fixing the one-home red, the scheduled guard filed a
-- second one: "dashboard_v2 took 1421 ms from cache (limit 200)", eleven
-- minutes after the database was restarted. Measured immediately afterwards,
-- six consecutive calls ran in 31-56 ms. The function was never slow; one
-- sample was taken while the caches were cold.
--
-- That is not a harmless blip. A red guard files an RG-red command, which
-- claims a runner, loads a context and spends tokens on a fault that does not
-- exist — and a single sample had already done real damage today: one 2072 ms
-- reading of dev_cmd_complete_fast during the same restart evicted a green
-- branch from the deploy lane twice (batches 395/396, CHANGE #1016).
--
-- c747_catalogue_budget already solved this in the only honest way: sample up
-- to three times, keep the BEST, and stop as soon as one sample is inside the
-- budget. Code that genuinely misses its budget misses it on all three; an
-- environmental outlier no longer speaks for it. The budgets themselves are
-- unchanged — 200 ms for dashboard_v2, 2000 ms for complete_fast — so nothing
-- is being relaxed, only measured properly. Idempotent: plain updates.

update public.rg_behavior_tests set body = $rgbody$
do $rg$
declare
  v jsonb; t0 timestamptz; ms numeric; best numeric; v_bytes int; i int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','f5d6ce2f-1182-427f-93de-fb70cde2cf2a','role','authenticated')::text, true);
  -- warm the plan, then measure the read the app actually makes
  v := public.dashboard_v2(null, null);

  -- CHANGE #1160 — best of three, stopping at the first sample inside the
  -- budget. A cold cache is not a regression (c747 sets the pattern).
  best := null;
  for i in 1..3 loop
    t0 := clock_timestamp();
    v := public.dashboard_v2(null, null);
    ms := extract(epoch from (clock_timestamp() - t0)) * 1000.0;
    best := least(coalesce(best, ms), ms);
    exit when best <= 200;
  end loop;

  if coalesce((v->>'ok')::boolean, false) is not true then
    raise exception 'RG_FAIL: dashboard_v2 not ok %', left(v::text, 300);
  end if;
  if best > 200 then
    raise exception 'RG_FAIL: dashboard_v2 took % ms from cache, best of 3 (limit 200)', round(best);
  end if;
  v_bytes := octet_length(v::text);
  if v_bytes > 30720 then
    raise exception 'RG_FAIL: dashboard_v2 payload % bytes (limit 30720)', v_bytes;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$rgbody$
where name = 'dashboard_v2_fast_and_small';

update public.rg_behavior_tests set body = $rgbody$
do $rg$
declare v_id bigint := -641; v_t timestamptz; v_ms numeric; v_best numeric; v jsonb; i int;
begin
  perform set_config('request.jwt.claims',
    json_build_object('role','service_role')::text, true);

  -- CHANGE #1160 — best of three. One 2072 ms sample taken during a database
  -- restart evicted a green branch from the deploy lane twice (#1016); the
  -- budget below is unchanged, it is now just measured properly.
  v_best := null;
  for i in 1..3 loop
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
    v_best := least(coalesce(v_best, v_ms), v_ms);
    exit when v_best <= 2000;
  end loop;

  if v_best > 2000 then
    raise exception 'RG_FAIL: dev_cmd_complete_fast took % ms, best of 3 — the budget is 2000 ms. An RPC a runner calls over HTTP must never do heavy work (CHANGE #641).', round(v_best);
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$rgbody$
where name = 'c641_complete_fast_under_2s';
