-- CHANGE #350 — the three moving parts of self-ticking step progress.
--
--   A. dev_cmd_step_autotick(id, facts[]) — a DERIVED tick. The runner harness
--      reports a FACT it observed ("migration", "tests", "queue_push",
--      "deployed"); the backend decides which pending step that fact satisfies
--      from dev_step_fact_rule. Progress stops depending on the agent
--      remembering to call step_done.
--   B. dev_cmd_step_done — a real tick now also CLEARS the stale flag and
--      restarts the step clock, so the card recovers the instant work is
--      reported instead of waiting for the next cron tick.
--   C. dev_cmd_watchdog — gains the backstop rule: tokens climbing while
--      steps_done stands still => nudge the agent on the same message channel
--      Om's replies ride, and flag the card so the stale checklist reads as
--      untrusted rather than silently wrong.
--
-- ⚠ AND it fixes the watchdog itself. #327 added `r.guard_snap_steps` to the
-- stall IF but never added the column to the FOR-loop SELECT, so every tick
-- raised `record "r" has no field "guard_snap_steps"` the moment it reached a
-- healthy building row. The heartbeat-lost re-queue, the runtime ceiling and the
-- zombie kill have all been dead since. Verified before this migration by
-- calling dev_cmd_watchdog() directly. Backstops must be executed, not assumed.

-- ── A. the derived tick ─────────────────────────────────────────────────────
create or replace function public.dev_cmd_step_autotick(
  p_id bigint, p_facts jsonb, p_commit text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_steps jsonb; v_status text; v_on boolean; v_fact text; v_hit jsonb;
  v_ticked jsonb := '[]'::jsonb; v_done int; v_total int; v_next jsonb;
begin
  perform _dev_guard();
  if jsonb_typeof(p_facts) is distinct from 'array' then
    return jsonb_build_object('ok', false, 'error', 'p_facts must be a JSON array of fact keys');
  end if;

  select coalesce((value->'steps_watchdog'->>'autotick')::boolean, true)
    into v_on from dev_runner_config where key='worker_pool';
  if not coalesce(v_on, true) then
    return jsonb_build_object('ok', true, 'ticked', '[]'::jsonb, 'note', 'autotick disabled');
  end if;

  select coalesce(steps,'[]'::jsonb), status into v_steps, v_status
    from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  -- A derived tick is a statement about a build in flight. It never edits a
  -- finished row's record, and it never invents a plan that was never published
  -- — "Step 0 of 0" is the watchdog's problem (C), not something to paper over.
  if v_status <> 'building' then
    return jsonb_build_object('ok', true, 'ticked', '[]'::jsonb, 'note', 'row is not building');
  end if;
  if jsonb_array_length(v_steps) = 0 then
    return jsonb_build_object('ok', true, 'ticked', '[]'::jsonb, 'no_plan', true,
      'note', 'no step plan published — nothing to tick');
  end if;

  -- One fact ticks at most ONE step, the lowest-numbered pending step whose
  -- title the rule matches. Facts are consumed in the order given.
  for v_fact in select jsonb_array_elements_text(p_facts) loop
    select jsonb_build_object('n', (s->>'n')::int, 'title', s->>'title',
                              'fact', v_fact, 'note', fr.note)
      into v_hit
      from jsonb_array_elements(v_steps) s
      join dev_step_fact_rule fr
        on fr.enabled and fr.fact = v_fact and (s->>'title') ~* fr.pattern
     where coalesce(s->>'status','pending') <> 'done'
     order by (s->>'n')::int, fr.ord
     limit 1;
    continue when v_hit is null;

    select coalesce(jsonb_agg(
             case when (s->>'n')::int = (v_hit->>'n')::int
                  then jsonb_strip_nulls(s || jsonb_build_object(
                         'status', 'done',
                         'by',     'auto',
                         'commit', coalesce(nullif(p_commit,''), s->>'commit'),
                         'at',     to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                         'note',   coalesce(nullif(v_hit->>'note',''), 'auto: ' || v_fact)))
                  else s end order by (s->>'n')::int), '[]'::jsonb)
      into v_steps from jsonb_array_elements(v_steps) s;
    v_ticked := v_ticked || jsonb_build_array(v_hit);
  end loop;

  if jsonb_array_length(v_ticked) = 0 then
    return jsonb_build_object('ok', true, 'ticked', '[]'::jsonb,
      'note', 'no pending step matched those facts');
  end if;

  select count(*) into v_done from jsonb_array_elements(v_steps) s where s->>'status' = 'done';
  v_total := jsonb_array_length(v_steps);
  select s into v_next from jsonb_array_elements(v_steps) s where s->>'status' <> 'done'
    order by (s->>'n')::int limit 1;

  update dev_commands
     set steps = v_steps, steps_done = v_done, steps_total = v_total,
         steps_auto_count = coalesce(steps_auto_count,0) + jsonb_array_length(v_ticked),
         resume_commit = coalesce(nullif(p_commit,''), resume_commit),
         -- progress was reported (by observation): the card is trustworthy again
         steps_stale_flagged = false, steps_stale_at = null,
         steps_snap_at = now(), steps_snap_done = v_done,
         steps_snap_tokens = cost_input_tokens + cost_output_tokens
   where id = p_id;

  return jsonb_build_object('ok', true, 'ticked', v_ticked,
    'steps_done', v_done, 'steps_total', v_total, 'next', v_next);
end $function$;

grant execute on function public.dev_cmd_step_autotick(bigint, jsonb, text) to service_role;

-- ── B. a real tick clears the flag and restarts the step clock ───────────────
create or replace function public.dev_cmd_step_done(
  p_id bigint, p_step integer, p_commit text default null, p_note text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_new jsonb; v_done int; v_total int; v_next jsonb; v_hit boolean;
begin
  perform _dev_guard();
  select coalesce(steps,'[]'::jsonb) into v_new from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  select bool_or((s->>'n')::int = p_step) into v_hit from jsonb_array_elements(v_new) s;
  if not coalesce(v_hit,false) then
    return jsonb_build_object('ok', false, 'error', 'step ' || p_step || ' is not in the plan');
  end if;

  select coalesce(jsonb_agg(
           case when (s->>'n')::int = p_step
                then jsonb_strip_nulls(s || jsonb_build_object(
                       'status','done',
                       'commit', coalesce(nullif(p_commit,''), s->>'commit'),
                       'at',     to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                       'note',   coalesce(nullif(p_note,''), s->>'note')))
                else s end order by (s->>'n')::int), '[]'::jsonb)
    into v_new from jsonb_array_elements(v_new) s;

  select count(*) into v_done  from jsonb_array_elements(v_new) s where s->>'status' = 'done';
  v_total := jsonb_array_length(v_new);
  select s into v_next from jsonb_array_elements(v_new) s where s->>'status' <> 'done'
    order by (s->>'n')::int limit 1;

  update dev_commands
     set steps = v_new, steps_done = v_done, steps_total = v_total,
         resume_commit = coalesce(nullif(p_commit,''), resume_commit),
         -- CHANGE #350: reporting progress is what makes the checklist
         -- trustworthy again, so the flag and the step clock reset HERE rather
         -- than on the next cron tick.
         steps_stale_flagged = false, steps_stale_at = null,
         steps_snap_at = now(), steps_snap_done = v_done,
         steps_snap_tokens = cost_input_tokens + cost_output_tokens
   where id = p_id;

  return jsonb_build_object('ok', true, 'steps_done', v_done, 'steps_total', v_total, 'next', v_next);
end $function$;

-- ── C. the watchdog: fixed, plus the step-sync backstop ─────────────────────
create or replace function public.dev_cmd_watchdog()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
DECLARE r record; n int := 0; v_stall int; v_ceiling int;
        v_sw jsonb; v_sw_on boolean; v_sw_min int; v_sw_tok bigint;
        v_sw_renudge int; v_sw_max int;
        t_noplan text; t_stale text; v_body text; v_age text;
        v_flagged int := 0; v_nudged int := 0;
BEGIN
  SELECT coalesce((value->>'stall_window_min')::int,20), coalesce((value->>'max_build_min')::int,90),
         coalesce(value->'steps_watchdog','{}'::jsonb)
    INTO v_stall, v_ceiling, v_sw FROM dev_runner_config WHERE key='worker_pool';
  v_sw_on      := coalesce((v_sw->>'enabled')::boolean, true);
  v_sw_min     := coalesce((v_sw->>'stale_min')::int, 12);
  v_sw_tok     := coalesce((v_sw->>'min_tokens')::bigint, 40000);
  v_sw_renudge := coalesce((v_sw->>'renudge_min')::int, 12);
  v_sw_max     := coalesce((v_sw->>'nudge_max')::int, 3);
  SELECT value#>>'{}' INTO t_noplan FROM ui_copy WHERE key='dev_queue.steps_nudge_noplan';
  SELECT value#>>'{}' INTO t_stale  FROM ui_copy WHERE key='dev_queue.steps_nudge_stale';

  -- guard_snap_steps and the steps_* columns MUST be in this SELECT: the stall
  -- rule below reads them off `r`, and a missing field aborts the whole
  -- function (that is exactly how #327 silently disabled every rule here).
  FOR r IN SELECT id, retry_count, started_at, heartbeat_at, eta_left_s,
                  cost_input_tokens+cost_output_tokens AS tokens,
                  guard_snap_at, guard_snap_tokens, guard_snap_eta, guard_snap_steps,
                  steps_done, steps_total, steps_snap_at, steps_snap_done,
                  steps_snap_tokens, steps_stale_flagged, steps_nudge_count, steps_nudged_at
           FROM dev_commands WHERE status='building' LOOP

    IF r.heartbeat_at < now() - interval '15 minutes' THEN
      IF r.retry_count = 0 THEN
        UPDATE dev_commands SET status='pending', retry_count=1, claimed_by=NULL,
          error_log = coalesce(error_log||E'\n---\n','')||'WATCHDOG: heartbeat lost, re-queued' WHERE id=r.id;
      ELSE
        UPDATE dev_commands SET status='failed', finished_at=now(), claimed_by=NULL,
          error_log = coalesce(error_log||E'\n---\n','')||'WATCHDOG: heartbeat lost twice, failed' WHERE id=r.id;
        PERFORM wa_send_event('dev_cmd_failed', NULL, jsonb_build_object('command_id', r.id::text, 'error', 'watchdog: heartbeat lost twice'), NULL, NULL);
      END IF;
      PERFORM _lease_release_internal(r.id); n:=n+1; CONTINUE;
    END IF;

    IF r.started_at < now() - (v_ceiling||' minutes')::interval THEN
      UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
        needs_input_question='Build exceeded the '||v_ceiling||'-minute ceiling. Reply yes to allow one more window, or refine the spec.'
      WHERE id=r.id;
      INSERT INTO dev_command_messages (command_id, sender, body) VALUES (r.id,'system','⛔ Auto-stopped: over '||v_ceiling||' min runtime ceiling.');
      PERFORM _lease_release_internal(r.id);
      PERFORM wa_send_event('sec_zombie_killed', NULL, jsonb_build_object('command_id',r.id::text,'reason','runtime ceiling','tokens',r.tokens::text), NULL, NULL);
      n:=n+1; CONTINUE;
    END IF;

    -- ── CHANGE #350: the step-sync backstop ─────────────────────────────────
    -- Never terminal. It only tells the truth about the checklist and asks the
    -- agent, in the reply channel it already reads, to sync it.
    IF v_sw_on THEN
      IF r.steps_snap_at IS NULL OR r.steps_snap_done IS DISTINCT FROM r.steps_done THEN
        -- progress moved (or this is the first sight of the row): restart the
        -- clock and stop calling the checklist stale.
        UPDATE dev_commands
           SET steps_snap_at=now(), steps_snap_done=r.steps_done, steps_snap_tokens=r.tokens,
               steps_stale_flagged=false, steps_stale_at=NULL
         WHERE id=r.id;
      ELSIF r.steps_snap_at < now() - (v_sw_min||' minutes')::interval
            AND r.tokens - coalesce(r.steps_snap_tokens,0) >= v_sw_tok THEN
        v_age := _fmt_dur(coalesce(extract(epoch from now()-r.steps_snap_at), 0));
        IF NOT coalesce(r.steps_stale_flagged,false) THEN
          UPDATE dev_commands SET steps_stale_flagged=true,
                 steps_stale_at=coalesce(steps_stale_at, r.steps_snap_at) WHERE id=r.id;
          v_flagged := v_flagged + 1;
        END IF;
        IF coalesce(r.steps_nudge_count,0) < v_sw_max
           AND (r.steps_nudged_at IS NULL
                OR r.steps_nudged_at < now() - (v_sw_renudge||' minutes')::interval) THEN
          v_body := CASE WHEN coalesce(r.steps_total,0) = 0
                         THEN coalesce(t_noplan, '⚠ STEP SYNC — #{id} has no step plan published after {tokens} tokens. Publish it with devcmd.sh steps_set {id}.')
                         ELSE coalesce(t_stale,  '⚠ STEP SYNC — #{id} still reads Step {done} of {total} after {age} and {tokens} tokens. Mark what landed with devcmd.sh step_done {id} <n>.') END;
          v_body := replace(v_body, '{id}',     r.id::text);
          v_body := replace(v_body, '{done}',   coalesce(r.steps_done,0)::text);
          v_body := replace(v_body, '{total}',  coalesce(r.steps_total,0)::text);
          v_body := replace(v_body, '{age}',    v_age);
          v_body := replace(v_body, '{tokens}', r.tokens::text);
          INSERT INTO dev_command_messages (command_id, sender, body)
          VALUES (r.id, 'system', v_body);
          UPDATE dev_commands SET steps_nudge_count = coalesce(steps_nudge_count,0)+1,
                 steps_nudged_at = now() WHERE id=r.id;
          v_nudged := v_nudged + 1;
        END IF;
      END IF;
    END IF;

    IF r.guard_snap_at IS NULL OR r.guard_snap_eta IS DISTINCT FROM r.eta_left_s
       OR r.guard_snap_steps IS DISTINCT FROM r.steps_done THEN
      -- CHANGE #327: steps_done is a SECOND progress signal. A command that
      -- finished a step since the last snapshot is making progress by
      -- definition, so the stall clock restarts.
      UPDATE dev_commands SET guard_snap_at=now(), guard_snap_tokens=r.tokens,
             guard_snap_eta=r.eta_left_s, guard_snap_steps=r.steps_done WHERE id=r.id;
    ELSIF r.eta_left_s IS NOT DISTINCT FROM r.guard_snap_eta
          AND r.guard_snap_steps IS NOT DISTINCT FROM r.steps_done
          AND r.tokens > r.guard_snap_tokens
          AND r.guard_snap_at < now() - (v_stall||' minutes')::interval THEN
      UPDATE dev_commands SET status='failed', finished_at=now(), claimed_by=NULL,
        error_log = coalesce(error_log||E'\n---\n','')||'ZOMBIE: ETA frozen '||v_stall||'min while tokens climbed ('||r.guard_snap_tokens||'→'||r.tokens||')'
      WHERE id=r.id;
      INSERT INTO dev_command_messages (command_id, sender, body) VALUES (r.id,'system','⛔ Zombie killed: no progress for '||v_stall||' min while burning tokens.');
      PERFORM _lease_release_internal(r.id);
      PERFORM wa_send_event('sec_zombie_killed', NULL, jsonb_build_object('command_id',r.id::text,'reason','stall (eta frozen, tokens climbing)','tokens',r.tokens::text), NULL, NULL);
      n:=n+1;
    ELSIF r.eta_left_s IS NOT DISTINCT FROM r.guard_snap_eta AND r.tokens = r.guard_snap_tokens
          AND r.guard_snap_at < now() - ((v_stall*2)||' minutes')::interval THEN
      UPDATE dev_commands SET status='pending', claimed_by=NULL, retry_count=greatest(retry_count,0),
        error_log = coalesce(error_log||E'\n---\n','')||'STALLED: no ETA change and no token activity for '||(v_stall*2)||'min (worker likely lost) — re-queued'
      WHERE id=r.id;
      INSERT INTO dev_command_messages (command_id, sender, body) VALUES (r.id,'system','↻ Re-queued: worker appears lost (no progress, no activity for '||(v_stall*2)||' min).');
      PERFORM _lease_release_internal(r.id);
      PERFORM wa_send_event('sec_zombie_killed', NULL, jsonb_build_object('command_id',r.id::text,'reason','dead worker (no activity)','tokens',r.tokens::text), NULL, NULL);
      n:=n+1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('acted', n, 'steps_flagged', v_flagged, 'steps_nudged', v_nudged);
END $function$;
