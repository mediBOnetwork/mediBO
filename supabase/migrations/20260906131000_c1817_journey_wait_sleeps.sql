-- replay-target: control-plane
-- CMD #1817 — the journey that keeps waiting free.
--
-- The class of bug: a command that has finished its code, is queued behind
-- something it cannot hurry, and spends the wait THINKING. #1812 spent 159,555
-- tokens that way; the batch it was waiting for took 17 minutes and cost
-- nothing. This probe holds the whole state machine down on a scratch row it
-- seeds and rolls back, so it needs no live wait and leaves no events behind:
--
--   begin  → the row is asleep, the token mark is taken, ONE wait_start
--   poll   → quiet: no wait_turn, and the blocker is still there
--   poll   → after tokens move: exactly ONE wait_turn carrying the delta
--   poll   → tokens quiet again: no second wait_turn (the mark is high-water)
--   end    → the wait is banked, ONE wait_end, and the resume is ONE LINE
--   backstop → _wait_burn_check still sees a sleeping row as waiting
CREATE OR REPLACE FUNCTION public._journey_qa_1817_wait_sleeps()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_id      bigint := -18170001;        -- negative: this probe owns its row
  v_turn    bigint;
  v_begin   jsonb; v_p1 jsonb; v_p2 jsonb; v_p3 jsonb; v_end jsonb; v_burn jsonb;
  v_state   text;  v_since timestamptz; v_mark bigint;
  v_starts  int;   v_turns int; v_ends int; v_delta bigint; v_turn_rows int;
  v_line    text;  v_total int;
  a1 boolean := false; a2 boolean := false; a3 boolean := false;
  a4 boolean := false; a5 boolean := false; a6 boolean := false;
begin
  perform public._dev_guard();
  v_turn := (public._dev_wait_cfg()->>'turn_tokens')::bigint;

  begin
    insert into public.dev_commands (id, spec, title, status, claimed_by,
                                     cost_input_tokens, cost_output_tokens, steps)
    overriding system value
    values (v_id, 'c1817 wait probe', 'c1817 wait probe', 'building', 'probe-1817',
            10000, 0,
            '[{"n":1,"title":"probe step","status":"pending"}]'::jsonb);

    -- ① begin — asleep, marked, announced once
    v_begin := public.dev_wait_begin(v_id, 'probe-1817', 'other', 'c1817 probe wait', '{}'::jsonb);
    select wait_state, wait_since, wait_started_tokens
      into v_state, v_since, v_mark from public.dev_commands where id = v_id;
    select count(*) into v_starts from public.dev_context_event
     where command_id = v_id and kind = 'wait_start';
    a1 := coalesce((v_begin->>'ok')::boolean, false)
          and v_state = 'sleeping' and v_since is not null and v_mark = 10000
          and v_starts = 1
          and (v_begin->>'poll_s')::int > 0 and (v_begin->>'max_wait_s')::int > 0;

    -- ② a quiet poll costs nothing and reports nothing
    v_p1 := public.dev_wait_poll(v_id);
    select count(*) into v_turns from public.dev_context_event
     where command_id = v_id and kind = 'wait_turn';
    a2 := coalesce((v_p1->>'ok')::boolean, false)
          and coalesce((v_p1->>'free')::boolean, true) is false
          and v_turns = 0
          and coalesce(v_p1->>'hold_line','') <> ''
          and (v_p1->>'hold_line') not like '%' || chr(10) || '%';   -- ONE line

    -- ③ the bug, made visible: tokens moved while the row was asleep
    update public.dev_commands
       set cost_output_tokens = v_turn + 1500 where id = v_id;
    v_p2 := public.dev_wait_poll(v_id);
    select count(*), max((detail->>'delta')::bigint)
      into v_turn_rows, v_delta
      from public.dev_context_event where command_id = v_id and kind = 'wait_turn';
    a3 := v_turn_rows = 1 and v_delta = v_turn + 1500;

    -- ④ the same tokens are never a second turn (high-water mark)
    v_p3 := public.dev_wait_poll(v_id);
    select count(*) into v_turn_rows from public.dev_context_event
     where command_id = v_id and kind = 'wait_turn';
    a4 := v_turn_rows = 1;

    -- ⑤ the backstop still recognises a SLEEPING row as waiting, and does not
    --    kill it under the grace
    v_burn := public._wait_burn_check(v_id);
    a5 := coalesce((v_burn->>'kill')::boolean, true) is false
          and coalesce((v_burn->>'waiting')::boolean, false) is true;

    -- ⑥ end — banked, announced once, and the resume is ONE LINE that names
    --    the next step instead of re-reading anything
    v_end := public.dev_wait_end(v_id, 'probe done');
    select wait_state, wait_total_s into v_state, v_total
      from public.dev_commands where id = v_id;
    select count(*) into v_ends from public.dev_context_event
     where command_id = v_id and kind = 'wait_end';
    v_line := coalesce(v_end->>'resume_line','');
    a6 := coalesce((v_end->>'ok')::boolean, false)
          and v_state is null and v_ends = 1
          and v_line <> '' and v_line not like '%' || chr(10) || '%'
          and v_line like '%probe step%';

    raise exception using errcode = 'P0001', message = 'c1817_probe_rollback';
  exception when others then
    null;   -- the sub-transaction unwinds; the reads above survive in the vars
  end;

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 and a6 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'begin marks the row asleep at its token count, once=' || a1::text
   || ' | a quiet poll logs no wake-up and returns one hold line=' || a2::text
   || ' | tokens moving while asleep logs exactly one wait_turn (delta '
   || coalesce(v_delta::text,'null') || ', threshold ' || v_turn || ')=' || a3::text
   || ' | the same tokens are never a second wake-up=' || a4::text
   || ' | _wait_burn_check still reads sleeping as waiting=' || a5::text
   || ' | end banks the wait and resumes on ONE line ("'
   || left(coalesce(v_line,''), 90) || '")=' || a6::text));
end
$function$;

GRANT EXECUTE ON FUNCTION public._journey_qa_1817_wait_sleeps() TO service_role;

-- probe_on='dev': this journey reads dev_commands / dev_context_event, which
-- #1761 moved to the control plane. Without it the probe lane sends it to the
-- build branch, where the function does not exist and it reports "unknown
-- journey" for ever.
INSERT INTO public.dev_journeys (name, area, kind, probe_on, steps, assertions, required, enabled)
VALUES ('qa-1817-wait-sleeps', 'runner', 'api', 'dev',
  '["seed a scratch building command and open a wait on it",
    "poll once while nothing moves — expect no wake-up and one hold line",
    "move the token counter past wait_gate.turn_tokens and poll again",
    "poll a third time with the counter quiet",
    "ask the backstop what it sees, then end the wait and read the resume line"]'::jsonb,
  '["dev_wait_begin puts the row asleep, records the token mark and announces the wait exactly once",
    "a poll that finds nothing moved logs no wait_turn and returns a single-line hold string",
    "a token delta over wait_gate.turn_tokens while asleep logs exactly one wait_turn carrying that delta",
    "the same tokens are never reported as a second wake-up",
    "_wait_burn_check treats a sleeping row as waiting and does not kill it under waiting_token_grace",
    "dev_wait_end clears the wait, writes one wait_end and returns a ONE-LINE resume that names the next step"]'::jsonb,
  false, true)
ON CONFLICT (name) DO UPDATE
  SET area = excluded.area, kind = excluded.kind, probe_on = excluded.probe_on,
      steps = excluded.steps, assertions = excluded.assertions, enabled = true;
