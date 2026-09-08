-- CHANGE #916 — the behaviour test that keeps the persistence gate honest.
--
-- #751 added `c751_rg_watch_confirms_red` so nobody could quietly put the
-- first-run filing back. This is the same guard one level up: the confirmation
-- window must also require that the red STAND STILL, and the three carve-outs
-- that stop that from ever hiding a regression must survive too.
--
-- It asserts behaviour, not wording: rg_red_persistence() is exercised on real
-- rows (inside the behaviour savepoint, never surviving it) for the exact four
-- shapes that matter, and rg_watch's source is checked only for the decision
-- it must still be making.

insert into rg_behavior_tests (name, note, body, enabled)
values (
  'c916_rg_watch_needs_the_same_red',
  'CHANGE #916 — a schema-only red must be the SAME red, not three different ones. '
  || '#916 was filed after three consecutive reds whose diff sets did not overlap at all '
  || '(20 diffs from #712, then 28, then 5 from #707) and the guard went green two minutes '
  || 'later when a rebaseline landed: a fleet mid-build, not a regression. So the watcher '
  || 'now needs at least one diff present in EVERY run of the confirmation window. The three '
  || 'carve-outs are part of the contract and are tested here too: a critical files on sight, '
  || 'a REMOVED object files on sight, and max_red_age_s files a red that simply will not settle.',
$body$
do $b$
declare
  v_src text;
  v_p   jsonb;
begin
  -- 1. The knobs exist and mean something. require_persistent_diff off would
  --    be #751's behaviour again; a zero max_red_age_s would mean every red
  --    escapes the gate immediately.
  if not exists (select 1 from dev_runner_config
                  where key = 'rg_watch'
                    and coalesce((value->>'confirm_runs')::int, 0) >= 1) then
    raise exception 'RG_FAIL: dev_runner_config.rg_watch.confirm_runs must be >= 1 (CHANGE #751)';
  end if;
  if not exists (select 1 from dev_runner_config
                  where key = 'rg_watch'
                    and coalesce((value->>'max_red_age_s')::int, 0) >= 60) then
    raise exception 'RG_FAIL: dev_runner_config.rg_watch.max_red_age_s must be >= 60s — it is the escape hatch that stops a churning red from being suppressed forever (CHANGE #916)';
  end if;

  -- 2. Three reds carrying three unrelated diff sets are three different reds.
  --    These rows are written inside the behaviour savepoint and never survive.
  delete from rg_runs where ran_at > now();
  insert into rg_runs(ran_at, ok, report) values
   (now() + interval '3 min', false, '{"result":"red","diffs":{"function":{"added":["_journey_c707_assign()"],"removed":[],"changed":[]}}}'),
   (now() + interval '2 min', false, '{"result":"red","diffs":{"function":{"added":["_c712_emit(x)"],"removed":[],"changed":[]}}}'),
   (now() + interval '1 min', false, '{"result":"red","diffs":{"index":{"added":["order_items.foo_idx"],"removed":[],"changed":[]}}}');
  v_p := rg_red_persistence(3);
  if coalesce((v_p->>'persistent')::int, -1) <> 0 then
    raise exception 'RG_FAIL: a churning red must have 0 persistent diffs, got %', v_p->>'persistent';
  end if;
  if coalesce((v_p->>'explained')::boolean, false) is not true then
    raise exception 'RG_FAIL: a red whose newest run carries diffs must read explained=true, got %', v_p;
  end if;
  if coalesce((v_p->>'has_removal')::boolean, true) is not false then
    raise exception 'RG_FAIL: an additive-only red must read has_removal=false, got %', v_p;
  end if;

  -- 3. The same diff standing in every run of the window IS a held red.
  delete from rg_runs where ran_at > now();
  insert into rg_runs(ran_at, ok, report) values
   (now() + interval '3 min', false, '{"result":"red","diffs":{"function":{"added":["stuck_fn()"],"removed":[],"changed":[]}}}'),
   (now() + interval '2 min', false, '{"result":"red","diffs":{"function":{"added":["stuck_fn()","noise()"],"removed":[],"changed":[]}}}'),
   (now() + interval '1 min', false, '{"result":"red","diffs":{"function":{"added":["stuck_fn()"],"removed":[],"changed":[]}}}');
  v_p := rg_red_persistence(3);
  if coalesce((v_p->>'persistent')::int, 0) < 1 then
    raise exception 'RG_FAIL: a diff present in every run of the window must be persistent, got %', v_p;
  end if;
  if not (v_p->'sample' @> '["function|added|stuck_fn()"]'::jsonb) then
    raise exception 'RG_FAIL: the persistent diff must be named in sample for the command body, got %', v_p->'sample';
  end if;

  -- 4. A DROPPED object is never a runner mid-rebaseline: it files even while
  --    everything around it churns.
  delete from rg_runs where ran_at > now();
  insert into rg_runs(ran_at, ok, report) values
   (now() + interval '3 min', false, '{"result":"red","diffs":{"function":{"added":[],"removed":["important_fn()"],"changed":[]}}}'),
   (now() + interval '2 min', false, '{"result":"red","diffs":{"function":{"added":["a()"],"removed":[],"changed":[]}}}'),
   (now() + interval '1 min', false, '{"result":"red","diffs":{"function":{"added":["b()"],"removed":[],"changed":[]}}}');
  v_p := rg_red_persistence(3);
  if coalesce((v_p->>'has_removal')::boolean, false) is not true then
    raise exception 'RG_FAIL: a removed object on the newest red must set has_removal — a dropped function is never mid-rebaseline drift (CHANGE #916)';
  end if;

  -- 5. A green or a timeout still ends the streak, so the window can never
  --    span one.
  delete from rg_runs where ran_at > now();
  insert into rg_runs(ran_at, ok, report) values
   (now() + interval '3 min', false, '{"result":"red","diffs":{"function":{"added":["x()"],"removed":[],"changed":[]}}}'),
   (now() + interval '2 min', true,  '{"result":"green"}'),
   (now() + interval '1 min', false, '{"result":"red","diffs":{"function":{"added":["x()"],"removed":[],"changed":[]}}}');
  if coalesce((rg_red_persistence(3)->>'runs')::int, 0) <> 1 then
    raise exception 'RG_FAIL: a green run must end the streak — the persistence window may never span one, got %',
      rg_red_persistence(3);
  end if;
  delete from rg_runs where ran_at > now();

  -- 6. rg_watch still makes all four decisions. Wording is free to change;
  --    losing any of these is the regression.
  select prosrc into v_src from pg_proc
   where proname = 'rg_watch' and pronamespace = 'public'::regnamespace;
  if v_src is null then
    raise exception 'RG_FAIL: rg_watch() is gone';
  end if;
  if position('v_streak >= v_confirm' in v_src) = 0 then
    raise exception 'RG_FAIL: rg_watch no longer gates the RG-red command on the confirmation streak (CHANGE #751)';
  end if;
  if position('rg_red_persistence' in v_src) = 0 then
    raise exception 'RG_FAIL: rg_watch no longer asks whether the red is the SAME red (CHANGE #916)';
  end if;
  if position('v_critical' in v_src) = 0 then
    raise exception 'RG_FAIL: rg_watch lost the critical carve-out — a failing behaviour or a missing_critical must file on sight';
  end if;
  if position('max_red_age_s' in v_src) = 0 then
    raise exception 'RG_FAIL: rg_watch lost the max_red_age_s escape hatch — a red that never settles must still reach Om (CHANGE #916)';
  end if;

  -- 7. The card is the reason suppressing a command hides nothing. Without a
  --    surface, "no command" and "nothing wrong" look identical.
  if to_regprocedure('public.rg_guard_card(integer)') is null then
    raise exception 'RG_FAIL: rg_guard_card() is gone — the guard would have no surface again (CHANGE #916)';
  end if;
  if regexp_replace((select prosrc from pg_proc
                      where proname = 'rg_guard_card' and pronamespace = 'public'::regnamespace),
                    '--[^\n]*', '', 'g') ~* '\mrg_check[[:space:]]*\(' then
    raise exception 'RG_FAIL: rg_guard_card runs the guard inline — opening a screen must never cost a catalogue scan (CHANGE #647)';
  end if;

  raise exception 'RG_ROLLBACK';
end $b$;
$body$,
  true)
on conflict (name) do update
  set note = excluded.note, body = excluded.body, enabled = true;
