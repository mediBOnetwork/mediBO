-- replay-target: production
--
-- CHANGE #636 — the nightly safety net moves off the dispatcher's own tick.
--
-- #1808 disabled c636_safety_net_nightly and left the reason in parked_reason:
-- autotest_safety_net_run(150 RPCs) cancels on get_companies_by_category at
-- cron_dispatch()'s 15 s dblink budget and takes the WHOLE tick down with it,
-- stopping every other scheduled task. That is correct — a multi-minute job
-- has no business running inside a per-minute dispatcher — and the fix it
-- named is the one three other nightly jobs already use: the cron task only
-- ENQUEUES, and the VM lane (scripts/autotest/run.js --if-requested, which the
-- merge worker runs after every deploy) drains the queue where there is no
-- dblink budget to blow.
--
-- So the work_sql becomes a single fast INSERT that cannot time out, and the
-- task comes back on. The run's own arguments travel in the request payload,
-- which is where a knob belongs: changing 150 to 40 is an UPDATE, not a deploy.
-- test_run_request_add already refuses to queue a second identical pending
-- request, so a dispatcher that falls behind cannot stack six of these.

update public.cron_task
   set work_sql = $w$select public.test_run_request_add(
                       'safety_net',
                       '{"fuzz_rpcs":150,"variants":2,"label":"nightly safety net"}'::jsonb,
                       'dispatcher')$w$,
       enabled = true,
       parked_at = null,
       parked_reason = null,
       parked_ms = null,
       night_only = true,
       base_interval_s = 86400,
       note = 'CHANGE #636 — enqueues the nightly safety net; the VM lane runs it. '
              'Never call autotest_safety_net_run() from the dispatcher: it is minutes '
              'of work inside a 15 s dblink budget and it takes the whole tick with it (#1808).'
 where name = 'c636_safety_net_nightly';

-- A database that never saw the original insert still gets the task.
insert into public.cron_task (name, ord, mode, work_sql, enabled, base_interval_s,
                              night_only, note)
select 'c636_safety_net_nightly', 940, 'poll',
       $w$select public.test_run_request_add(
             'safety_net',
             '{"fuzz_rpcs":150,"variants":2,"label":"nightly safety net"}'::jsonb,
             'dispatcher')$w$,
       true, 86400, true,
       'CHANGE #636 — enqueues the nightly safety net; the VM lane runs it.'
 where not exists (select 1 from public.cron_task where name = 'c636_safety_net_nightly');

-- The drain, with a kind filter. test_run_request_claim() takes the head of the
-- queue whatever it is, which is right for a general lane and wrong for a timer
-- that must only ever run ONE job: #634's 'full' request is the entire hostile
-- suite against production and turning that on is not this change's to make.
-- A NEW NAME rather than a defaulted argument on the existing one — an
-- overload whose old zero-filter call still resolves is how a claim silently
-- keeps taking everything.
create or replace function public.test_run_request_claim_kind(
  p_worker text default 'vm', p_kinds text[] default array['safety_net'])
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare r public.test_run_request;
begin
  perform public._dev_guard();
  select * into r from public.test_run_request
   where status = 'pending'
     and (p_kinds is null or kind = any(p_kinds))
   order by created_at
   for update skip locked limit 1;
  if r.id is null then return jsonb_build_object('ok', true, 'has', false); end if;
  update public.test_run_request
     set status = 'claimed', claimed_at = now(),
         claimed_by = coalesce(nullif(p_worker,''),'vm')
   where id = r.id;
  return jsonb_build_object('ok', true, 'has', true, 'request_id', r.id,
                            'kind', r.kind, 'args', r.args);
end $fn$;

revoke all on function public.test_run_request_claim_kind(text, text[]) from public, anon, authenticated;
grant execute on function public.test_run_request_claim_kind(text, text[]) to service_role;
