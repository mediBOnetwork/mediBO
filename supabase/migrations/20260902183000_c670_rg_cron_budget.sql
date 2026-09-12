-- CMD #670, P2 — the 90 s self-stop was unreachable from the only path allowed
-- to run it.
--
-- CHANGE #641/#647 made rg_check cron-only and gave it a 90 s budget
-- (worker_pool.rg.budget_s) that it checks between kinds and before behaviours.
-- But the dispatcher applies each task's step_timeout_ms as statement_timeout
-- (cron_dispatch: `set local statement_timeout = t.step_timeout_ms`), and both
-- rg tasks were left on the 20 000 ms default. So a guard run that went long was
-- killed by Postgres at 20 s and NEVER reached its own self-stop: no 'timeout'
-- result, no stopped_at, no rg_timeout alert — just a cancelled statement and a
-- cron_task fail_count. The budget existed and could not fire.
--
-- 120 s is the ceiling the spec asks for and leaves 30 s of headroom over the
-- 90 s budget, so the self-stop is what ends a slow run and the statement
-- timeout stays the backstop it was meant to be.
update public.cron_task
   set step_timeout_ms = 120000,
       note = coalesce(note,'') ||
              case when coalesce(note,'') = '' then '' else ' ' end ||
              'cmd #670: 120 s so rg_check''s own 90 s budget is what stops it.'
 where name in ('rg_watch_2h','rg_after_deploy')
   and step_timeout_ms < 120000;

-- A guard for the guard: if either rg task is ever put back under the budget,
-- the self-stop is dead again and rg_check goes red saying so.
insert into public.rg_behavior_tests (name, body, enabled, note) values (
  'c670_rg_cron_timeout_over_budget',
$body$
do $b$
declare v_budget_ms int; v_bad text;
begin
  select coalesce((value->'rg'->>'budget_s')::int, 90) * 1000
    into v_budget_ms from public.dev_runner_config where key='worker_pool';
  select string_agg(format('%s=%sms', name, step_timeout_ms), ', ')
    into v_bad
    from public.cron_task
   where work_sql ilike '%rg_watch%'
     and enabled
     and step_timeout_ms <= v_budget_ms;
  if v_bad is not null then
    raise exception 'RG_FAIL: rg cron task statement_timeout is at or under rg_check''s own %ms budget (%) — the 90s self-stop can never fire', v_budget_ms, v_bad;
  end if;
  raise exception 'RG_ROLLBACK';
end
$b$;
$body$,
  true,
  'cmd #670 P2 — cron_dispatch applies step_timeout_ms as statement_timeout. If an rg task sits at or below worker_pool.rg.budget_s, Postgres kills the run before rg_check can stop itself, and a slow guard produces a cancelled statement instead of result=timeout.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;
