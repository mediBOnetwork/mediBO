-- CHANGE #1856 (part 3) — the journey that holds the hold down.
--
-- qa-1817-wait-sleeps proves a wait SLEEPS. This one proves the door chooses
-- correctly between the two doors that come after it: a blocker that clears by
-- itself is HELD (the session survives, nothing is re-read) and only a long
-- blocker, a file lease, or a runner another command needs is a COLD park.
--
-- It runs entirely inside a sub-transaction on a negative id it owns, and
-- unwinds — nothing it writes survives except the verdict.
-- =============================================================================

create or replace function public._journey_qa_1856_hold_not_cold()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_id     bigint := -18560001;
  v_hold1  jsonb; v_hold2 jsonb; v_poll jsonb; v_park jsonb; v_row jsonb;
  v_state  text;  v_status text; v_agent text;
  v_holds  int;   v_colds int; v_hev int; v_pev int; v_msg text;
  v_cost   text;  v_mode text;
  a1 boolean := false; a2 boolean := false; a3 boolean := false;
  a4 boolean := false; a5 boolean := false; a6 boolean := false;
begin
  perform public._dev_guard();

  begin
    insert into public.dev_commands (id, spec, title, status, claimed_by, area,
                                     cost_input_tokens, cost_output_tokens, steps)
    overriding system value
    values (v_id, 'c1856 hold probe', 'c1856 hold probe', 'building', 'probe-1856',
            'runner', 10000, 0,
            '[{"n":1,"title":"probe step","status":"pending"}]'::jsonb);

    -- ① a db restart is longer than a sleep and shorter than a session:
    --    HELD. The row stays building and stays claimed.
    v_hold1 := public.dev_wait_enter(v_id, 'probe-1856', 'db', 'the database is restarting');
    select wait_state, status, claimed_by, hold_count, cold_resume_count
      into v_state, v_status, v_agent, v_holds, v_colds
      from public.dev_commands where id = v_id;
    a1 := (v_hold1->>'mode') = 'hold'
          and v_state = 'holding' and v_status = 'building' and v_agent = 'probe-1856'
          and v_holds = 1 and v_colds = 0;

    -- ② the MESSAGE LOG says hold, not resume — the acceptance test of #1856.
    select body into v_msg from public.dev_command_messages
     where command_id = v_id order by id desc limit 1;
    select count(*) into v_hev from public.dev_context_event
     where command_id = v_id and kind = 'wait_hold' and detail->>'mode' = 'hold';
    a2 := v_hev = 1 and coalesce(v_msg,'') ilike '%holding%'
          and coalesce(v_msg,'') not ilike '%parked%';

    -- ③ re-entering the SAME hold continues it: one hold, not two, and the
    --    line is a single line the agent can act on without re-reading.
    v_hold2 := public.dev_wait_enter(v_id, 'probe-1856', 'db', 'the database is restarting');
    select hold_count into v_holds from public.dev_commands where id = v_id;
    v_poll := public.dev_wait_poll(v_id);
    a3 := (v_hold2->>'mode') = 'hold' and v_holds = 1
          and (v_poll->>'mode') = 'hold'
          and coalesce(v_poll->>'hold_line','') <> ''
          and (v_poll->>'hold_line') not like '%' || chr(10) || '%';

    -- ④ a FILE LEASE is held by another BUILD, so it is never a hold: it parks,
    --    and the park is counted as the cold resume it is.
    update public.dev_commands set wait_state = null, status = 'building',
           claimed_by = 'probe-1856' where id = v_id;
    insert into public.dev_commands (id, spec, title, status, area)
    overriding system value
    values (v_id - 1, 'c1856 holder', 'c1856 holder', 'building', 'runner');
    insert into public.file_leases (path, command_id, worker)
    values ('lib/screens/c1856_probe.dart', v_id - 1, 'probe-holder');
    v_park := public.dev_wait_enter(v_id, 'probe-1856', 'lease', 'waiting on a file lease',
                                    '{"paths":["lib/screens/c1856_probe.dart"]}'::jsonb);
    select wait_state, status, claimed_by, cold_resume_count
      into v_state, v_status, v_agent, v_colds
      from public.dev_commands where id = v_id;
    a4 := (v_park->>'mode') = 'park' and v_state = 'parked'
          and v_status = 'pending' and v_agent is null and v_colds = 1;

    -- ⑤ the park announces itself as COLD, in the message log and the event.
    select body into v_msg from public.dev_command_messages
     where command_id = v_id order by id desc limit 1;
    select count(*) into v_pev from public.dev_context_event
     where command_id = v_id and kind = 'wait_park' and detail->>'mode' = 'cold';
    a5 := v_pev = 1 and coalesce(v_msg,'') ilike '%cold%';

    -- ⑥ the card prints ONE backend sentence naming both prices.
    update public.dev_commands set status = 'building', claimed_by = 'probe-1856',
           wait_state = null where id = v_id;
    select r into v_row from jsonb_array_elements(
      public._dev_cmd_rows(null, 'c1856 hold probe', null, 5, false)) r limit 1;
    v_cost := coalesce(v_row->>'resume_cost_line','');
    v_mode := coalesce(v_row->>'resume_cost_tone','');
    a6 := v_cost <> '' and v_cost like '%hold%' and v_cost like '%cold resume%'
          and v_mode = 'warning'
          and (v_row->>'hold_count') = '1' and (v_row->>'cold_resume_count') = '1';

    raise exception using errcode = 'P0001', message = 'c1856_probe_rollback';
  exception when others then
    null;   -- the sub-transaction unwinds; the reads above survive in the vars
  end;

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 and a6 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'a db restart is HELD — row still building, still claimed, hold_count=1=' || a1::text
   || ' | the message log says holding and never parked=' || a2::text
   || ' | re-entering continues ONE hold and returns one hold line=' || a3::text
   || ' | a file lease held by another build PARKS and counts a cold resume=' || a4::text
   || ' | the park announces itself as COLD=' || a5::text
   || ' | the card prints one sentence naming both prices ("'
   || left(coalesce(v_cost,''), 90) || '")=' || a6::text));
end $fn$;

grant execute on function public._journey_qa_1856_hold_not_cold() to service_role;

-- The probe_on column is #1761's and reached production out of band, so a
-- REPLAY of the migration set (a build branch, a rebuilt environment) has a
-- dev_journeys without it and every journey insert since then aborts. Repaired
-- idempotently here, the same gap part 1 repaired for wait_started_tokens.
alter table public.dev_journeys add column if not exists probe_on text;

-- probe_on='dev': it reads dev_commands / dev_context_event, which #1761 moved
-- to the control plane. Without it the probe lane aims at the build branch,
-- where the function does not exist, and it reports "unknown journey" for ever.
insert into public.dev_journeys (name, area, kind, probe_on, steps, assertions, required, enabled)
values ('qa-1856-hold-not-cold', 'runner', 'api', 'dev',
  '["seed a scratch building command and open a db wait on it",
    "read the message log and the context event the hold wrote",
    "re-enter the same wait and poll once",
    "put a file lease on another build and open a lease wait",
    "read the park message and its event",
    "render the command row and read its waiting-cost sentence"]'::jsonb,
  '["a blocker that clears by itself is HELD: the row stays building, stays claimed, and hold_count rises",
    "the message log says holding and never says parked, and exactly one wait_hold event carries mode=hold",
    "re-entering the same hold continues it rather than counting a second one, and the poll returns ONE hold line",
    "a file lease held by another BUILD parks instead of holding, releases the runner and counts a cold resume",
    "the park announces itself as COLD in both the message log and its wait_park event",
    "the card prints one backend sentence naming holds and cold resumes, with the payload tone"]'::jsonb,
  false, true)
on conflict (name) do update
  set area = excluded.area, kind = excluded.kind, probe_on = excluded.probe_on,
      steps = excluded.steps, assertions = excluded.assertions, enabled = true;
