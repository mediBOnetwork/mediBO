-- CHANGE #1055 (follow-on, same command) — the autofinish backstop needs the
-- guard fix ONE level deeper than the sweep.
--
-- The first migration let dev_cmd_autofinish_sweep() past _dev_guard() for the
-- local tokenless dispatcher, and it now runs. It then calls
-- dev_cmd_autofinish(id, 'watchdog') for each candidate — and THAT function
-- raises 'dev_queue: not authorized' from its own _dev_guard() on line 5, so
-- the sweep still completed nothing:
--
--   SQL statement "SELECT _dev_guard()"
--   PL/pgSQL function dev_cmd_autofinish(bigint,text) line 5 at PERFORM
--   PL/pgSQL function dev_cmd_autofinish_sweep() line 11 at assignment
--
-- Caught by actually calling the sweep as the dispatcher's caller shape rather
-- than trusting that fixing the outer function was enough. CHANGE #369's
-- 2-minute backstop has therefore never once closed a row from cron.
--
-- Same guard, same reasoning: _dev_guard_or_local_cron() admits only a
-- session_user of postgres/supabase_admin carrying no JWT at all. PostgREST
-- connects as `authenticator` and SET ROLEs, which never changes session_user,
-- so nothing arriving over the API can reach that branch. The anon and
-- authenticated EXECUTE this function still carried is revoked, so the outer
-- lock closes as the inner one opens — the same shape dev_cmd_watchdog has.
--
-- Idempotent: create or replace + revoke.

begin;

CREATE OR REPLACE FUNCTION public.dev_cmd_autofinish(p_id bigint, p_source text DEFAULT 'harness'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare st jsonb; comp jsonb; v_grace int; v_ready_at timestamptz; v_err text; r record;
        v_chat jsonb; v_body text; v_chat_err text;
begin
  perform _dev_guard_or_local_cron();
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

  -- CHANGE #476 — compose the chat message from the SAME artifacts, here, while
  -- there is still nothing to undo. It is posted only if the completion lands.
  begin
    v_chat := dev_cmd_finish_chat(p_id, p_source, comp->>'result');
    v_body := nullif(trim(coalesce(v_chat->>'body', '')), '');
  exception when others then
    v_chat_err := left(SQLERRM, 300);
    v_body := null;
  end;
  if v_body is null then
    v_body := replace(_c_or('dev_queue.finish_msg',
      '🤖 Auto-completed by the harness — every finish condition was observed ({source}).'),
      '{source}', p_source);
  end if;

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

  -- The last message in the thread is the whole result, on BOTH paths (p_source
  -- is 'harness' or 'watchdog'), inserted here so it is in the chat before
  -- kill_session ever reaches finish_detect.sh.
  insert into dev_command_messages (command_id, sender, body) values (p_id, 'system', v_body);

  perform _audit('system','dev_cmd_autofinish', p_id::text,
                 jsonb_build_object('source', p_source, 'change_no', comp->>'deploy_no',
                                    'chat_chars', length(v_body), 'chat_error', v_chat_err));
  select * into r from dev_commands where id = p_id;
  return jsonb_build_object('ok', true, 'completed', true, 'source', p_source,
    'change_no', (comp->>'deploy_no')::int, 'result', comp->>'result',
    'chat_body', v_body, 'chat_chars', length(v_body), 'chat_error', v_chat_err,
    'agent', coalesce(r.claimed_by,''), 'kill_session',
    coalesce(((select value->'finish_gate'->>'kill_session' from dev_runner_config where key='worker_pool'))::boolean, true));
end $function$;

revoke all on function public.dev_cmd_autofinish(p_id bigint, p_source text) from public, anon, authenticated;

commit;
