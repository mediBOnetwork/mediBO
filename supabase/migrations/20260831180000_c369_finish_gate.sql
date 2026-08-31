-- CHANGE #369 — FINISHED MEANS EXIT.
--
-- Measured on #355: all 12 steps done, CHANGE #855 live, render_verify green,
-- QA journeys green, the agent even wrote "Completing." — and then it ran two
-- more command batches and sat idle while the card still read status=building
-- at 1.3M tokens. The step-sync backstop nagged it 15 minutes AFTER everything
-- had landed. The build was over; the SESSION was not.
--
-- The fix is not another instruction in the prompt. Completion stops being a
-- model turn and becomes an OBSERVATION the harness makes:
--
--   dev_cmd_finish_state(id)   the gate — every condition, named, with the
--                              blocker text the card renders.
--   dev_cmd_result_compose(id) result_summary + plain_summary composed
--                              MECHANICALLY from the artifacts already on the
--                              row (steps, change no, QA verdict, journeys,
--                              proofs, decisions). The model never gets a
--                              "write the summary" turn.
--   dev_cmd_autofinish(id,src) completes the row server-side the moment the
--                              gate is green. Called every heartbeat by
--                              finish_detect.sh, which then interrupts the
--                              agent's turn — zero model turns after success.
--   dev_cmd_autofinish_sweep() the backstop: a row that sits green for longer
--                              than finish_gate.grace_s (120s) is completed by
--                              the cron dispatcher whether or not a worker is
--                              still listening. Drift becomes impossible
--                              rather than discouraged.
--
-- IT CANNOT FIRE EARLY. Every condition must hold TOGETHER, and the gate is a
-- superset of the bug-loop gate inside dev_cmd_complete (which still runs, and
-- still raises on a red rg_check — an exception here is caught and reported as
-- a blocker, never as a completion).

-- ── 1. the row's own finish state ───────────────────────────────────────────
alter table dev_commands add column if not exists finish_ready_at   timestamptz;
alter table dev_commands add column if not exists finish_blockers   jsonb;
alter table dev_commands add column if not exists auto_finished     boolean not null default false;
alter table dev_commands add column if not exists auto_finish_source text;

-- ── 2. config + copy (change the wording with an UPDATE, never a deploy) ────
update dev_runner_config
   set value = jsonb_set(value, '{finish_gate}',
        coalesce(value->'finish_gate', '{}'::jsonb) ||
        jsonb_build_object(
          'enabled',      coalesce(value->'finish_gate'->'enabled', 'true'::jsonb),
          'grace_s',      coalesce(value->'finish_gate'->'grace_s', '120'::jsonb),
          'kill_session', coalesce(value->'finish_gate'->'kill_session', 'true'::jsonb),
          'note', to_jsonb('CHANGE #369 — the harness completes a finished command and interrupts the session. grace_s is the watchdog backstop only; the heartbeat detector fires with no grace.'::text)))
 where key = 'worker_pool';

insert into ui_copy (key, value) values
  ('dev_queue.finish_ready_chip',  to_jsonb('✅ All conditions met — closing automatically'::text)),
  ('dev_queue.finish_auto_chip',   to_jsonb('🤖 Auto-completed by the harness'::text)),
  ('dev_queue.finish_msg',         to_jsonb('🤖 Auto-completed by the harness — every finish condition was observed ({source}). The session was interrupted so nothing runs after success.'::text)),
  ('dev_queue.finish_line_change', to_jsonb('• Change no — CHANGE #{n} live.'::text)),
  ('dev_queue.finish_line_nodeploy', to_jsonb('• Deploy — backend only, none.'::text)),
  ('dev_queue.finish_line_built',  to_jsonb('• Built — {title}.'::text)),
  ('dev_queue.finish_line_steps',  to_jsonb('• Steps — {done} of {total} landed.'::text)),
  ('dev_queue.finish_line_tests',  to_jsonb('• Tests — selftest green.'::text)),
  ('dev_queue.finish_line_qa',     to_jsonb('• QA — {verdict}, {n} journeys.'::text)),
  ('dev_queue.finish_line_proof',  to_jsonb('• Proof — {n} screenshots stored.'::text)),
  ('dev_queue.finish_line_files',  to_jsonb('• Files — {n} touched.'::text)),
  ('dev_queue.finish_line_dec',    to_jsonb('• Decisions — {n} logged.'::text)),
  ('dev_queue.finish_line_closed', to_jsonb('• Closed — harness, no drift.'::text)),
  ('dev_queue.finish_plain',       to_jsonb('Command #{id} is finished and was closed automatically the moment every check passed. {change} Nothing is left for you to do here.'::text)),
  ('dev_queue.finish_plain_change',to_jsonb('It is live as CHANGE #{n}.'::text)),
  ('dev_queue.finish_plain_nochange', to_jsonb('It was a backend-only change, so there was nothing to deploy.'::text))
on conflict (key) do nothing;

-- ── 3a. copy with a fallback ────────────────────────────────────────────────
-- _c() returns '' for a key that does not exist yet; a summary line composed
-- from '' would silently lose a bullet. Every string below therefore carries
-- the shipped default next to it, and the ui_copy row overrides it.
create or replace function _c_or(p_key text, p_default text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(nullif((select value #>> '{}' from public.ui_copy where key = p_key), ''), p_default);
$$;

-- ── 3. the proofs this command actually uploaded ────────────────────────────
-- Screenshots are dropped into dev-cmd-proofs under whatever prefix the worker
-- used — 355/, cmd355/, cmd-368/ all exist today. Discover them instead of
-- demanding one convention, so completion never fails on a folder name.
create or replace function _dev_finish_proofs(p_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(name order by name), '[]'::jsonb)
    from (select o.name from storage.objects o
           where o.bucket_id = 'dev-cmd-proofs'
             and o.name ~ ('^(cmd[-_]?)?' || p_id::text || '/')
           limit 12) s;
$$;

-- ── 4. THE GATE ─────────────────────────────────────────────────────────────
-- One evaluation, every condition named. `applies=false` means the condition is
-- not part of THIS row's contract (a backend-only row has no deploy to prove);
-- it can never be the reason a row is held open, and it can never be the reason
-- a row closes either.
create or replace function dev_cmd_finish_state(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r record; v jsonb := '[]'::jsonb; v_block text[] := '{}';
        v_gate boolean; v_proofs jsonb; v_missing text; v_change int;
        v_cfg jsonb; v_on boolean; v_grace int; v_selftest boolean;
        v_ready boolean; v_journeys int;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  select coalesce(value->'finish_gate', '{}'::jsonb) into v_cfg
    from dev_runner_config where key = 'worker_pool';
  v_on    := coalesce((v_cfg->>'enabled')::boolean, true);
  v_grace := coalesce((v_cfg->>'grace_s')::int, 120);

  -- the bug-loop contract, exactly as dev_cmd_complete applies it
  v_gate := (coalesce(r.kind,'dev') = 'dev' and coalesce(r.route,'') <> 'fast' and coalesce(r.qa_required,false));

  -- (a) still building, and nobody is waiting on an answer
  if r.status <> 'building' then v_block := array_append(v_block, (('not building (' || r.status || ')'))::text); end if;
  if coalesce(r.needs_input_question,'') <> '' then v_block := array_append(v_block, ('an unanswered question is open')::text); end if;
  v := v || jsonb_build_array(jsonb_build_object('key','building','label','Row is building',
        'applies', true, 'ok', r.status = 'building' and coalesce(r.needs_input_question,'') = '',
        'detail', r.status));

  -- (b) the checklist is complete — and a row with NO plan never qualifies
  v := v || jsonb_build_array(jsonb_build_object('key','steps','label','Every step marked done',
        'applies', true,
        'ok', coalesce(r.steps_total,0) > 0 and coalesce(r.steps_done,0) >= r.steps_total,
        'detail', coalesce(r.steps_done,0)::text || '/' || coalesce(r.steps_total,0)::text));
  if coalesce(r.steps_total,0) = 0 then
    v_block := array_append(v_block, ('no step plan published')::text);
  elsif coalesce(r.steps_done,0) < r.steps_total then
    v_block := array_append(v_block, (('steps ' || coalesce(r.steps_done,0) || '/' || r.steps_total))::text);
  end if;

  -- (c) QA verdict
  if v_gate and coalesce(r.qa_status,'pending') not in ('passed','waived') then
    v_block := array_append(v_block, (('QA is ' || coalesce(r.qa_status,'pending')))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','qa','label','QA passed',
        'applies', v_gate, 'ok', (not v_gate) or coalesce(r.qa_status,'') in ('passed','waived'),
        'detail', coalesce(r.qa_status,'')));

  -- (d) journeys: no red without a later green, and every required one green
  if v_gate then
    if exists (select 1 from dev_journey_runs jr
                where jr.command_id = p_id and jr.status = 'failed'
                  and not exists (select 1 from dev_journey_runs jr2
                                   where jr2.command_id = p_id and jr2.journey_id = jr.journey_id
                                     and jr2.status = 'passed' and jr2.id > jr.id))
    then v_block := array_append(v_block, ('a journey run failed without a later pass')::text); end if;
    select string_agg(j.name, ', ') into v_missing
      from dev_journeys j
     where j.enabled
       and ((j.required and (j.area is null or j.area is not distinct from r.area)) or j.source_bug = p_id)
       and not exists (select 1 from dev_journey_runs jr
                        where jr.command_id = p_id and jr.journey_id = j.id and jr.status = 'passed');
    if v_missing is not null then v_block := array_append(v_block, (('journeys not passed: ' || v_missing))::text); end if;
  end if;
  select count(*) into v_journeys from dev_journey_runs jr
   where jr.command_id = p_id and jr.status = 'passed';
  v := v || jsonb_build_array(jsonb_build_object('key','journeys','label','Required journeys green',
        'applies', v_gate, 'ok', (not v_gate) or v_missing is null, 'detail', v_journeys::text || ' passed'));

  -- (e) screenshot evidence
  v_proofs := case when jsonb_array_length(coalesce(r.screenshots,'[]'::jsonb)) > 0
                   then r.screenshots else _dev_finish_proofs(p_id) end;
  if v_gate and jsonb_array_length(v_proofs) = 0 then
    v_block := array_append(v_block, ('no screenshot evidence in dev-cmd-proofs')::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','proof','label','Screenshot proof stored',
        'applies', v_gate, 'ok', (not v_gate) or jsonb_array_length(v_proofs) > 0,
        'detail', jsonb_array_length(v_proofs)::text));

  -- (f) the deploy actually landed (web rows only)
  select coalesce(r.web_deploy_no,
           (select q.change_no from deploy_queue q
             where q.command_id = p_id and q.status = 'deployed' and q.change_no is not null
             order by q.id desc limit 1)) into v_change;
  select exists (select 1 from dev_selftest_log s where s.ok and s.at > now() - interval '6 hours')
    into v_selftest;
  if v_gate and coalesce(r.targets_web,false) then
    if v_change is null then v_block := array_append(v_block, ('no deployed change number yet')::text); end if;
    if coalesce(r.preview_status,'') <> 'promoted' then
      v_block := array_append(v_block, (('preview_status=' || coalesce(r.preview_status,'null')))::text);
    end if;
    if v_change is not null and not v_selftest then
      v_block := array_append(v_block, ('no green self-test in the last 6h')::text);
    end if;
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','deploy','label','Change deployed and promoted',
        'applies', v_gate and coalesce(r.targets_web,false),
        'ok', (not (v_gate and coalesce(r.targets_web,false)))
              or (v_change is not null and coalesce(r.preview_status,'') = 'promoted' and v_selftest),
        'detail', coalesce('CHANGE #' || v_change::text, 'none')));

  v_ready := (array_length(v_block,1) is null) and v_on;
  if not v_on then v_block := array_append(v_block, ('finish gate disabled in worker_pool.finish_gate')::text); end if;

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'status', r.status,
    'enabled', v_on, 'grace_s', v_grace,
    'ready', v_ready,
    'gate_applies', v_gate,
    'conditions', v,
    'blockers', to_jsonb(coalesce(v_block, '{}'::text[])),
    'blocker_text', coalesce(array_to_string(v_block, ' · '), ''),
    'change_no', v_change,
    'screenshots', v_proofs,
    'ready_at', r.finish_ready_at,
    'auto_finished', coalesce(r.auto_finished,false),
    'auto_finish_source', coalesce(r.auto_finish_source,''));
end $$;

-- ── 5. THE SUMMARY, COMPOSED FROM ARTIFACTS ─────────────────────────────────
-- Om's result_summary format is a hard contract: bullets only, ≤10 lines, ≤5
-- words a line, ≤50 words total. Composing it from the row's own artifacts is
-- the only way to keep that true without spending a model turn on it.
create or replace function dev_cmd_result_compose(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r record; st jsonb; v_lines text[] := '{}'; v_txt text; v_title text;
        v_change int; v_proofs jsonb; v_files int; v_dec int; v_j int;
        v_plain text; v_ch text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  st := dev_cmd_finish_state(p_id);
  v_change := (st->>'change_no')::int;
  v_proofs := coalesce(st->'screenshots', '[]'::jsonb);
  -- leases are released the moment the row completes, so the honest count is
  -- whichever is bigger: what is still leased, or what lease_learn recorded.
  select greatest(count(*), coalesce(array_length(r.predicted_files,1),0))
    into v_files from file_leases fl where fl.command_id = p_id;
  v_dec := jsonb_array_length(coalesce(r.decisions, '[]'::jsonb));
  select count(*) into v_j from dev_journey_runs jr where jr.command_id = p_id and jr.status = 'passed';
  -- the title, trimmed to the five words the format allows
  v_title := array_to_string((string_to_array(regexp_replace(coalesce(r.title,''), '\s+', ' ', 'g'), ' '))[1:5], ' ');
  -- a five-word cut lands mid-phrase often enough to matter; drop the dangling
  -- connector and the trailing dash rather than print "resolve its."
  v_title := regexp_replace(v_title, '[\s—–,-]*\m(its|the|a|an|and|of|to|for|with|in|on|that|so)\M$', '', 'i');
  v_title := regexp_replace(v_title, '[\s—–,:-]+$', '');

  if v_change is not null then
    v_lines := array_append(v_lines, replace(_c_or('dev_queue.finish_line_change','• Change no — CHANGE #{n} live.'), '{n}', v_change::text));
  else
    v_lines := array_append(v_lines, _c_or('dev_queue.finish_line_nodeploy','• Deploy — backend only, none.'));
  end if;
  if v_title <> '' then
    v_lines := array_append(v_lines, replace(_c_or('dev_queue.finish_line_built','• Built — {title}.'), '{title}', v_title));
  end if;
  v_lines := array_append(v_lines, replace(replace(_c_or('dev_queue.finish_line_steps','• Steps — {done} of {total} landed.'),
               '{done}', coalesce(r.steps_done,0)::text), '{total}', coalesce(r.steps_total,0)::text));
  if v_change is not null then
    v_lines := array_append(v_lines, _c_or('dev_queue.finish_line_tests','• Tests — selftest green.'));
  end if;
  if coalesce(r.qa_required,false) then
    v_lines := array_append(v_lines, replace(replace(_c_or('dev_queue.finish_line_qa','• QA — {verdict}, {n} journeys.'),
                 '{verdict}', coalesce(r.qa_status,'pending')), '{n}', v_j::text));
  end if;
  if jsonb_array_length(v_proofs) > 0 then
    v_lines := array_append(v_lines, replace(_c_or('dev_queue.finish_line_proof','• Proof — {n} screenshots stored.'),
                 '{n}', jsonb_array_length(v_proofs)::text));
  end if;
  if v_files > 0 then
    v_lines := array_append(v_lines, replace(_c_or('dev_queue.finish_line_files','• Files — {n} touched.'), '{n}', v_files::text));
  end if;
  if v_dec > 0 then
    v_lines := array_append(v_lines, replace(_c_or('dev_queue.finish_line_dec','• Decisions — {n} logged.'), '{n}', v_dec::text));
  end if;
  v_lines := array_append(v_lines, _c_or('dev_queue.finish_line_closed','• Closed — harness, no drift.'));
  -- the format caps the whole thing at ten lines; keep the last one (the close)
  if array_length(v_lines,1) > 10 then
    v_lines := v_lines[1:9] || v_lines[array_length(v_lines,1)];
  end if;
  v_txt := array_to_string(v_lines, E'\n');

  v_ch := case when v_change is not null
               then replace(_c_or('dev_queue.finish_plain_change','It is live as CHANGE #{n}.'), '{n}', v_change::text)
               else _c_or('dev_queue.finish_plain_nochange','It was a backend-only change, so there was nothing to deploy.') end;
  v_plain := replace(replace(_c_or('dev_queue.finish_plain',
      'Command #{id} is finished and was closed automatically the moment every check passed. {change} Nothing is left for you to do here.'),
      '{id}', p_id::text), '{change}', v_ch);

  return jsonb_build_object('ok', true, 'result', v_txt, 'plain', v_plain,
    'screenshots', v_proofs, 'deploy_no', v_change, 'lines', array_length(v_lines,1));
end $$;

-- ── 6. THE COMPLETION ITSELF ────────────────────────────────────────────────
create or replace function dev_cmd_autofinish(p_id bigint, p_source text default 'harness')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare st jsonb; comp jsonb; v_grace int; v_ready_at timestamptz; v_err text; r record;
begin
  perform _dev_guard();
  st := dev_cmd_finish_state(p_id);
  if coalesce((st->>'ok')::boolean, false) = false then return st; end if;
  v_grace := coalesce((st->>'grace_s')::int, 120);

  if coalesce((st->>'ready')::boolean, false) = false then
    -- conditions no longer hold: the clock restarts, and the card says why
    update dev_commands set finish_ready_at = null, finish_blockers = st->'blockers'
     where id = p_id and finish_ready_at is not null;
    update dev_commands set finish_blockers = st->'blockers' where id = p_id;
    return jsonb_build_object('ok', true, 'completed', false, 'ready', false,
      'blockers', st->'blockers', 'blocker_text', st->>'blocker_text');
  end if;

  -- first sighting stamps the clock; the harness path completes immediately,
  -- the watchdog path waits out the grace so a worker mid-`complete` wins.
  update dev_commands set finish_ready_at = coalesce(finish_ready_at, now()), finish_blockers = '[]'::jsonb
   where id = p_id returning finish_ready_at into v_ready_at;
  if p_source <> 'harness' and v_ready_at > now() - (v_grace || ' seconds')::interval then
    return jsonb_build_object('ok', true, 'completed', false, 'ready', true, 'waiting_grace', true,
      'grace_s', v_grace, 'ready_at', v_ready_at);
  end if;

  comp := dev_cmd_result_compose(p_id);
  begin
    perform dev_cmd_complete(p_id, comp->>'result', (comp->>'deploy_no')::int,
                             coalesce(comp->'screenshots','[]'::jsonb), comp->>'plain', null);
  exception when others then
    -- rg_check red, the bug-loop gate, or a worker that completed it a
    -- millisecond earlier. Never a completion, never a crashed sweep.
    v_err := left(SQLERRM, 300);
    update dev_commands set finish_blockers = to_jsonb(array[v_err]) where id = p_id;
    return jsonb_build_object('ok', true, 'completed', false, 'ready', true, 'error', v_err);
  end;

  update dev_commands
     set auto_finished = true, auto_finish_source = p_source, finish_blockers = '[]'::jsonb
   where id = p_id;
  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system',
          replace(_c_or('dev_queue.finish_msg',
            '🤖 Auto-completed by the harness — every finish condition was observed ({source}).'),
          '{source}', p_source));
  perform _audit('system','dev_cmd_autofinish', p_id::text,
                 jsonb_build_object('source', p_source, 'change_no', comp->>'deploy_no'));
  select * into r from dev_commands where id = p_id;
  return jsonb_build_object('ok', true, 'completed', true, 'source', p_source,
    'change_no', (comp->>'deploy_no')::int, 'result', comp->>'result',
    'agent', coalesce(r.claimed_by,''), 'kill_session',
    coalesce(((select value->'finish_gate'->>'kill_session' from dev_runner_config where key='worker_pool'))::boolean, true));
end $$;

-- ── 7. THE BACKSTOP ─────────────────────────────────────────────────────────
-- Rides the one cron dispatcher (never a bare */N schedule). A row that has
-- been green for longer than grace_s is completed whether or not any worker is
-- still listening — that is what makes drift impossible instead of discouraged.
create or replace function dev_cmd_autofinish_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; res jsonb; n_done int := 0; n_armed int := 0; v_ids bigint[] := '{}';
begin
  perform _dev_guard();
  for r in select id from dev_commands
            where status = 'building'
              and coalesce(steps_total,0) > 0
              and coalesce(steps_done,0) >= steps_total
              and coalesce(needs_input_question,'') = ''
            order by id loop
    res := dev_cmd_autofinish(r.id, 'watchdog');
    if coalesce((res->>'completed')::boolean,false) then
      n_done := n_done + 1; v_ids := v_ids || r.id;
    elsif coalesce((res->>'waiting_grace')::boolean,false) then
      n_armed := n_armed + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'completed', n_done, 'armed', n_armed, 'ids', to_jsonb(v_ids));
end $$;

insert into cron_task (name, ord, mode, gate_sql, work_sql, enabled, base_interval_s, note)
values ('dev-cmd-autofinish', 412, 'poll',
        'select exists (select 1 from public.dev_commands
                         where status = ''building'' and coalesce(steps_total,0) > 0
                           and coalesce(steps_done,0) >= steps_total)',
        'select public.dev_cmd_autofinish_sweep()', true, 60,
        'CHANGE #369 — completes a command that has been finished for longer than worker_pool.finish_gate.grace_s, so post-success drift cannot happen.')
on conflict (name) do update
   set work_sql = excluded.work_sql, gate_sql = excluded.gate_sql,
       base_interval_s = excluded.base_interval_s, enabled = true, note = excluded.note;

grant execute on function dev_cmd_finish_state(bigint)      to service_role, authenticated;
grant execute on function dev_cmd_result_compose(bigint)    to service_role, authenticated;
grant execute on function dev_cmd_autofinish(bigint, text)  to service_role, authenticated;
grant execute on function dev_cmd_autofinish_sweep()        to service_role, authenticated;
grant execute on function _dev_finish_proofs(bigint)        to service_role, authenticated;
grant execute on function _c_or(text, text)                 to service_role, authenticated, anon;
