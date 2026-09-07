-- CMD #1864 — the VM toggle must show the REAL EC2 state and actually start the box.
--
-- Target project: the CONTROL PLANE (medibo-dev). Not a production migration:
-- dev_ctl_*, strip_v3_card and dev_runner_config live there. Apply with
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/dev/c1864_vm_state.sql
-- Every statement is idempotent.
--
-- WHAT WAS BROKEN (07 Sep 2026, both halves proven before writing a line):
--
-- 1. Toggle ON started nothing. The Runners strip (strip_v3_card) flips a
--    toggle with dev_ctl_set and IGNORES the `call_edge` verdict it answers
--    with — so `desired_state.vm` went to 'on' and no EC2 call was ever made.
--    The supervisor on the box honours 'off' by powering itself down, which is
--    why STOP worked and START did not: stop needs no cloud call, start does.
--
-- 2. The chip lied. vm-control writes vm_status with a service client for its
--    OWN project (`createClient(SUPABASE_URL, SVC)`). The working copy is
--    PRODUCTION's, so its readings land in PRODUCTION's dev_runner_config —
--    while the chip reads dev_ctl_get on the CONTROL PLANE. The control plane's
--    vm_status is therefore only ever written by the runner ON the box, and a
--    box that is off writes nothing: the chip froze at the last word it heard
--    ("running") and stayed there while EC2 said Stopped.
--
-- THE FIX: the EC2 call is made SERVER-SIDE, from the control plane, by
-- _ops_vm_call() — which already posts to production's vm-control with the
-- production service key (the medibo-dev copy of the function carries a dead
-- AWS key: AuthFailure on every call). pg_net answers asynchronously, so the
-- reply is collected on the next poll and written into the control plane's OWN
-- vm_status. Both cards then read one row that a live DescribeInstances wrote.
--
-- The app gains no logic: it calls dev_ctl_set / dev_vm_poll and prints
-- chip_label, chip_tone and the blocked sentence verbatim.

-- ── the writer ──────────────────────────────────────────────────────────────
-- dev_vm_status_write() is service_role-only (it is the runner's door) and it
-- cannot be relaxed without opening that door to the app. This is the internal
-- twin: same table, same vocabulary, callable from the RPCs below. It REPLACES
-- the row rather than merging it, so a collected reading always clears the
-- in-flight bookkeeping (request_id / awaiting_edge) that led to it.
create or replace function public._vm_status_put(
  p_status    text,
  p_operation text default null,
  p_source    text default 'edge',
  p_extra     jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; s text;
begin
  s := coalesce(p_status, 'unknown');
  if s not in ('running','stopped','starting','stopping','unknown') then
    s := 'unknown';
  end if;
  insert into dev_runner_config(key, value)
  values ('vm_status',
    jsonb_build_object(
      'status',       s,
      'operation',    p_operation,
      'source',       coalesce(p_source, 'edge'),
      'last_checked', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    || coalesce(p_extra, '{}'::jsonb))
  on conflict (key) do update set value = excluded.value;
  select value into v from dev_runner_config where key = 'vm_status';
  return v;
end $$;

-- ── the render-ready block ──────────────────────────────────────────────────
-- One place decides the word, the tone and the freshness verdict. Dart holds no
-- status→label map any more: chip_label and chip_tone are printed verbatim.
create or replace function public._vm_block() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb; v_poll jsonb; v_age numeric; v_status text; v_live boolean;
begin
  select value into v      from dev_runner_config where key = 'vm_status';
  select value into v_poll from dev_runner_config where key = 'vm_poll';
  v      := coalesce(v, '{}'::jsonb);
  v_poll := coalesce(v_poll, '{}'::jsonb);

  v_status := coalesce(v->>'status', 'unknown');
  if v_status not in ('running','stopped','starting','stopping') then
    v_status := 'unknown';
  end if;

  begin v_age := extract(epoch from (now() - (v->>'last_checked')::timestamptz));
  exception when others then v_age := null;
  end;

  -- A reading is only worth showing while it is young. Transitional states go
  -- stale in seconds; a resting one is trusted for much longer. Both numbers
  -- are config (dev_runner_config.vm_poll), never constants in an app.
  v_live := case
    when coalesce((v->>'awaiting_edge')::boolean, false) then true
    when v_age is null then true
    when v_status in ('starting','stopping','unknown')
      then v_age >= coalesce((v_poll->>'transitional_after_s')::numeric, 5)
    else v_age >= coalesce((v_poll->>'stale_after_s')::numeric, 90)
  end;

  return v || jsonb_build_object(
    'status',           v_status,
    'age_s',            round(coalesce(v_age, 999999)),
    'needs_live_check', v_live,
    'settled',          v_status in ('running','stopped'),
    'chip_label',       _c_or('dev_queue.ctl_vm_' || v_status, initcap(v_status)),
    'chip_tone',        case v_status
                          when 'running'  then 'completed'
                          when 'stopped'  then 'paused'
                          when 'starting' then 'awaiting_approval'
                          when 'stopping' then 'awaiting_approval'
                          else 'paused' end,
    'poll', jsonb_build_object(
      'interval_ms', coalesce((v_poll->>'interval_ms')::int, 6000),
      'max_polls',   coalesce((v_poll->>'max_polls')::int, 20)));
end $$;

-- ── ask EC2, server-side ────────────────────────────────────────────────────
-- Fires one vm-control call through _ops_vm_call (pg_net, production, service
-- key) and books the request so the next poll can collect it. Never paints an
-- outcome: the status becomes 'unknown' with awaiting_edge until AWS answers.
create or replace function public._vm_ask(p_action text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; v jsonb; v_keep text;
begin
  if p_action not in ('start','stop','status') then
    return jsonb_build_object('ok', false, 'reason', 'bad_action');
  end if;
  r := _ops_vm_call(p_action);
  select value into v from dev_runner_config where key = 'vm_status';
  v := coalesce(v, '{}'::jsonb);

  if coalesce((r->>'ok')::boolean, false) is not true then
    -- The call never left the database. Say so instead of showing a state.
    perform _vm_status_put('unknown', null, 'edge',
      jsonb_build_object('note', coalesce(r->>'reason', '')));
    return jsonb_build_object('ok', false, 'reason', coalesce(r->>'reason',''));
  end if;

  -- A power flip invalidates whatever word we were showing: it is a guess from
  -- the toggle position until EC2 is read back. A plain 'status' refresh keeps
  -- the current word (it is still the last thing AWS actually said) and only
  -- marks the row as awaiting a fresher reading.
  v_keep := case when p_action = 'status' then coalesce(v->>'status','unknown')
                 else 'unknown' end;
  perform _vm_status_put(v_keep,
    case when p_action = 'status' then v->>'operation' else null end,
    coalesce(v->>'source','edge'),
    jsonb_build_object(
      'request_id',    (r->>'request_id')::bigint,
      'awaiting_edge', true,
      'asked_action',  p_action,
      'asked_at',      to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'note',          ''));
  return jsonb_build_object('ok', true, 'request_id', (r->>'request_id')::bigint,
                            'action', p_action);
end $$;

-- ── the poll the app runs until the state settles ───────────────────────────
-- Collect the pg_net reply if it has landed, write it as the new truth, then
-- ask again when the reading the backend itself judges too old. Returns the
-- same render-ready block every surface draws.
create or replace function public.dev_vm_poll() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_rid bigint; v_code int; v_content text; v_err text;
        v_body jsonb; v_status text; v_note text; v_pending boolean := false;
        v_asked timestamptz; v_block jsonb;
begin
  perform _dev_guard();

  select value into v from dev_runner_config where key = 'vm_status';
  v := coalesce(v, '{}'::jsonb);
  v_rid := nullif(v->>'request_id','')::bigint;

  if v_rid is not null then
    select r.status_code, r.content, r.error_msg
      into v_code, v_content, v_err
      from net._http_response r where r.id = v_rid;

    if found then
      begin v_body := v_content::jsonb; exception when others then v_body := '{}'::jsonb; end;
      v_status := coalesce(v_body->>'status', 'unknown');
      v_note   := '';
      if v_err is not null then
        v_status := 'unknown'; v_note := v_err;
      elsif coalesce(v_code, 0) >= 400 then
        -- vm-control words its own refusals (no key, IAM denied, AWS error).
        v_status := coalesce(nullif(v_body->>'status',''), 'unknown');
        v_note   := coalesce(v_body->>'message', 'HTTP ' || coalesce(v_code, 0));
      end if;
      perform _vm_status_put(v_status, v_body->>'operation', 'edge',
        jsonb_build_object('note', v_note, 'http_status', v_code));
    else
      -- Still in flight — unless it never will be. pg_net drops its response
      -- rows on a timer, so a request_id that never resolves would otherwise
      -- pin the chip on 'unknown, awaiting' for ever.
      begin v_asked := (v->>'asked_at')::timestamptz; exception when others then v_asked := null; end;
      if v_asked is null or now() - v_asked < interval '90 seconds' then
        v_pending := true;
      end if;
    end if;
  end if;

  v_block := _vm_block();
  if not v_pending and coalesce((v_block->>'needs_live_check')::boolean, false) then
    perform _vm_ask('status');
    v_block := _vm_block();
  end if;

  return jsonb_build_object(
    'ok',      true,
    'vm',      v_block,
    'settled', coalesce((v_block->>'settled')::boolean, false),
    'poll',    v_block->'poll');
end $$;

-- ── the flip itself now reaches EC2 ─────────────────────────────────────────
-- Same signature, same desired_state write, same workflow/breaker side effects.
-- The vm branch stops handing the app a `call_edge` errand it was free to drop:
-- the call is made HERE, and the reply carries the poll cadence to chase.
-- dev_ctl_set — vm branch rewritten (CMD #1864)
CREATE OR REPLACE FUNCTION public.dev_ctl_set(p_key text, p_value text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb; v_vm jsonb;
BEGIN
  PERFORM _dev_guard();
  IF p_key NOT IN ('vm','claude','workflow') THEN RAISE EXCEPTION 'dev_ctl_set: bad key'; END IF;
  IF p_value NOT IN ('on','off') THEN RAISE EXCEPTION 'dev_ctl_set: bad value'; END IF;
  IF (_sec_cfg()->>'frozen')::boolean AND p_value='on' THEN RAISE EXCEPTION 'frozen — unlock with PIN first'; END IF;
  UPDATE dev_runner_config SET value = jsonb_set(value, ARRAY[p_key], to_jsonb(p_value)) WHERE key='desired_state'
  RETURNING value INTO v;
  PERFORM _audit(_actor(),'toggle_set', p_key, jsonb_build_object('value',p_value));

  -- CHANGE #755 — a HUMAN flip is remembered as a manual flag. The self-healing
  -- controller reads it and stands down: a manual OFF is never auto-resumed
  -- over, and a manual ON is only taken back down by a score in the black band.
  -- The auto path never comes through here, so it can never forge this flag.
  IF p_key = 'workflow' THEN
    UPDATE dev_runner_config
       SET value = jsonb_set(coalesce(value,'{}'::jsonb), '{manual}',
             jsonb_build_object('workflow', p_value, 'at', now(), 'by', _actor()))
     WHERE key = 'runner_health';
    INSERT INTO dev_runner_breaker_event (kind, reason, detail)
    VALUES ('manual', 'Workflow switched ' || p_value || ' by hand',
            jsonb_build_object('value', p_value, 'by', _actor()));
  END IF;

  -- Turning Workflow back on IS the acknowledgement: the badge clears with it,
  -- so it can never outlive the pause it is describing.
  IF p_key = 'workflow' AND p_value = 'on' THEN
    UPDATE dev_runner_config
       SET value = jsonb_build_object('tripped', false, 'cleared_at', now(),
                                      'auto', false, 'last', value)
     WHERE key = 'db_breaker' AND coalesce((value->>'tripped')::boolean, false);
    -- The queue is live again: put the probe back on its 60 s cadence now
    -- rather than at the end of the idle back-off.
    PERFORM runner_health_wake();
  END IF;

  -- CMD #1864 — the flip makes the cloud call ITSELF.
  --
  -- It used to answer `call_edge:true` and leave the EC2 call to whoever was
  -- rendering. The Runners strip never made it, so START was a no-op: the
  -- switch moved, desired_state changed, and nothing on AWS was ever asked.
  -- _ops_vm_call posts to production's vm-control (the medibo-dev copy holds a
  -- dead AWS key) over pg_net, so the reply lands on the next dev_vm_poll and
  -- is written into THIS project's vm_status — the row the chip reads.
  IF p_key = 'vm' THEN
    v_vm := _vm_ask(CASE WHEN p_value='on' THEN 'start' ELSE 'stop' END);
    RETURN jsonb_build_object('ok',true,'desired_state',v,
      -- false on purpose: the call is already made. A renderer that still
      -- honours this key must not fire a second one.
      'call_edge', false,
      'action',    CASE WHEN p_value='on' THEN 'start' ELSE 'stop' END,
      'asked_ok',  coalesce((v_vm->>'ok')::boolean, false),
      'vm',        _vm_block(),
      'poll',      _vm_block()->'poll',
      'toast',     CASE WHEN coalesce((v_vm->>'ok')::boolean, false)
                        THEN _c_or(CASE WHEN p_value='on'
                                        THEN 'dev_queue.ctl_vm_start_sent'
                                        ELSE 'dev_queue.ctl_vm_stop_queued' END, '')
                        ELSE _c_or('dev_queue.ctl_edge_failed', '') END);
  END IF;

  RETURN jsonb_build_object('ok',true,'desired_state',v);
END $function$;

-- dev_ctl_get — the vm block is rendered once, in the backend (CMD #1864)
CREATE OR REPLACE FUNCTION public.dev_ctl_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_wait jsonb; v jsonb; v_ctx jsonb; v_blocked jsonb; v_disk jsonb; v_auth jsonb; v_branch jsonb; v_login jsonb; v_rc jsonb;
begin
  v := public.dev_ctl_get_core();
  begin v_wait := public.dev_wait_report(24);   /* c1819_waiting */
  exception when others then v_wait := jsonb_build_object('has', false);
  end;
  begin v_ctx := public.dev_context_metrics_cached(60);
  exception when others then v_ctx := jsonb_build_object('ok', false, 'has', false);
  end;
  begin v_blocked := public.runner_blocked_badge();
  exception when others then v_blocked := jsonb_build_object('has', false);
  end;
  begin v_disk := public.runner_disk_state();
  exception when others then v_disk := jsonb_build_object('has', false);
  end;
  begin v_auth := public.claude_auth_status();
  exception when others then v_auth := jsonb_build_object('has', false);
  end;
  begin v_login := public.claude_login_line();
  exception when others then v_login := jsonb_build_object('has', false);
  end;
  begin v_branch := public.build_branch_card();
  exception when others then v_branch := jsonb_build_object('has', false);
  end;
  -- CHANGE #1662 — Remote Control health sits INSIDE pool.state, next to
  -- shrink_display, because that is the card that already draws a banner.
  begin v_rc := public.dev_rc_health();
  exception when others then v_rc := jsonb_build_object('has', false);
  end;
  if coalesce((v->'health'->>'ok')::boolean, false) then
    v := jsonb_set(v, '{health,metrics}',
           coalesce(v->'health'->'metrics','[]'::jsonb)
           || jsonb_build_array(public.runner_health_disk_metric()));
  end if;
  if coalesce((v_rc->>'has')::boolean, false) and v ? 'pool' then
    v := jsonb_set(v, '{pool,state}',
           coalesce(v->'pool'->'state','{}'::jsonb)
           || jsonb_build_object('rc_banner', v_rc->>'rc_banner',
                                 'rc_banner_tone', v_rc->>'rc_banner_tone'));
  end if;

  -- CMD #1864 — one place decides the VM word, its tone and whether the
  -- reading is fresh enough to show. dev_ctl_get_core still reads the row; this
  -- overlays the rendered block so every surface prints the same strings.
  v := jsonb_set(v, '{vm}', public._vm_block());

  return v || jsonb_build_object('context', v_ctx, 'blocked', v_blocked, 'disk', v_disk,
                                 'claude_auth', v_auth, 'build_branch', v_branch,
                                 'rc_health', v_rc, 'waiting', v_wait);
end $function$;

-- strip_v3_card — the VM row and the blocked banner read vm_status (CMD #1864)
CREATE OR REPLACE FUNCTION public.strip_v3_card()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d jsonb; a jsonb; wp jsonb; v_blocked jsonb := '[]'::jsonb; v_add text;
        v_vm jsonb; v_vm_state text;
        v_max int; v_drain jsonb; v_branch_want jsonb; v_toggles jsonb;
        v_bs jsonb; v_on boolean;
begin
  perform _dev_guard();
  select value into d  from dev_runner_config where key='desired_state';
  select value into wp from dev_runner_config where key='worker_pool';
  select value into v_drain from dev_runner_config where key='drain_after';
  d := coalesce(d,'{}'::jsonb); wp := coalesce(wp,'{}'::jsonb);
  v_drain := coalesce(v_drain,'{}'::jsonb);
  a := strip_v3_actual();
  v_max := greatest(coalesce((wp->>'max_workers')::int, (wp->>'build_semaphore')::int, 3), 1);

  begin v_branch_want := build_branch_decide();
  exception when others then v_branch_want := '{}'::jsonb;
  end;
  begin v_bs := build_branch_state();
  exception when others then v_bs := '{}'::jsonb;
  end;
  v_on := coalesce(a->>'branch_status','') in ('on','ready');

  -- CMD #1864 — the banner reads the LIVE EC2 state, not the switch. Reading
  -- desired_state here said "the VM is off" only when Om had asked for it to be
  -- off, so a box that had stopped on its own, or one that refused to start,
  -- read as perfectly healthy.
  v_vm := _vm_block();
  v_vm_state := coalesce(v_vm->>'status','unknown');
  if v_vm_state <> 'running' then
    v_blocked := v_blocked || jsonb_build_array(
      _c_or('dev_queue.v3_vm_' || v_vm_state,
            _c_or('dev_queue.v3_vm_off','The VM is off, so nothing can build')));
  end if;

  if (a->>'rc_sessions') is not null and (a->>'rc_sessions')::int = 0
     and coalesce(d->>'vm','off') = 'on' then
    v_blocked := v_blocked || jsonb_build_array(_c_or('dev_queue.v3_rc_off',''));
  end if;

  if coalesce((v_branch_want->>'want')::boolean,false) and not v_on then
    v_add := replace(_c_or('dev_queue.v3_branch_wanted','Branch wanted for {n} command(s), not created yet'),
               '{n}', (coalesce((v_branch_want->>'pending')::int,0)
                     + coalesce((v_branch_want->>'building')::int,0))::text);
    v_blocked := v_blocked || jsonb_build_array(v_add);
  end if;

  -- A branch that is up and carrying nothing is the #1570 failure, stated.
  if v_on and coalesce((v_bs->>'on_live_now')::int,0) > 0 then
    v_blocked := v_blocked || jsonb_build_array(
      replace(_c_or('dev_queue.v3_branch_bypassed','{n} build(s) running on production while the branch is on'),
              '{n}', (v_bs->>'on_live_now')));
  elsif v_on and coalesce((v_bs->>'builds')::int,0) = 0
        and coalesce((a->>'building')::int,0) > 0 then
    v_blocked := v_blocked || jsonb_build_array(
      _c_or('dev_queue.v3_branch_unused','A build branch is on but no build has used it'));
  end if;

  if coalesce(v_bs->>'refusal_label','') <> '' then
    v_blocked := v_blocked || jsonb_build_array(v_bs->>'refusal_label');
  end if;

  if coalesce(a->>'usage_error','') <> '' then
    v_blocked := v_blocked || jsonb_build_array(
      replace(_c_or('dev_queue.v3_usage_stale','Usage sync failing: {reason}'),
              '{reason}', a->>'usage_error'));
  end if;

  v_toggles := jsonb_build_array(
    -- The switch is what Om asked for (desired_state); the word beside it is
    -- what EC2 says (vm_status). Both labels are the same live word so the
    -- strip prints the real state whichever side of the switch it is on.
    jsonb_build_object('key','vm', 'label', _c_or('dev_queue.v3_vm','VM'),
      'desired', coalesce(d->>'vm','off') = 'on',
      'actual',  v_vm_state = 'running',
      'actual_label', v_vm->>'chip_label',
      'not_actual_label', v_vm->>'chip_label',
      'sub', ''),
    jsonb_build_object('key','claude', 'label', _c_or('dev_queue.v3_start','Start building'),
      'desired', coalesce(d->>'claude','off') = 'on',
      'actual',  coalesce((a->>'building')::int,0) > 0,
      'actual_label', _c_or('dev_queue.v3_running','running'),
      'not_actual_label', _c_or('dev_queue.v3_not_running','not running'),
      'sub', _c_or('dev_queue.v3_start_sub','')),
    jsonb_build_object('key','workflow', 'label', _c_or('dev_queue.v3_parallel','Parallel building'),
      'desired', coalesce(d->>'workflow','off') = 'on',
      'actual',  coalesce((a->>'building')::int,0) > 1,
      'actual_label', _c_or('dev_queue.v3_running','running'),
      'not_actual_label', _c_or('dev_queue.v3_not_running','not running'),
      'sub', replace(_c_or('dev_queue.v3_parallel_sub',''), '{n}', v_max::text)));

  return jsonb_build_object(
    'has', true,
    'title', _c_or('dev_queue.v3_title','Runners'),
    'toggles', v_toggles,
    'gauges', strip_v3_gauges(),
    'workers', strip_v3_workers(),
    'workers_title', _c_or('dev_queue.v3_workers','Workers'),
    'workers_empty', _c_or('dev_queue.v3_workers_empty','No worker has reported yet.'),
    'building_label', case when coalesce((a->>'building')::int,0) = 0
      then _c_or('dev_queue.v3_building_none','Nothing building right now.')
      else replace(_c_or('dev_queue.v3_building','Building {ids}'), '{ids}', a->>'building_ids') end,
    'building_ids', a->>'building_ids',
    'branch_label', case when v_on
        then replace(_c_or('dev_queue.v3_branch_on','Build branch on · {age}'), '{age}', coalesce(a->>'branch_age',''))
      else _c_or('dev_queue.v3_branch_off','Build branch off') end,
    'branch', jsonb_build_object(
      'has',   v_on,
      'label', case when v_on
          then replace(_c_or('dev_queue.v3_branch_on','Build branch on · {age}'), '{age}', coalesce(a->>'branch_age',''))
        else _c_or('dev_queue.v3_branch_off','Build branch off') end,
      'ref',           coalesce(v_bs->>'project_ref',''),
      'builds',        coalesce((v_bs->>'builds')::int, 0),
      'builds_label',  coalesce(v_bs->>'builds_label',''),
      'builds_tone',   coalesce(v_bs->>'builds_tone','neutral'),
      'refusal_label', coalesce(v_bs->>'refusal_label',''),
      'tone', case when not v_on then 'neutral'
                   when coalesce((v_bs->>'builds')::int,0) = 0 then 'warning'
                   else 'success' end),
    'blocked', v_blocked,
    'headline', case when jsonb_array_length(v_blocked) = 0
      then _c_or('dev_queue.v3_ok','Running as asked.')
      else replace(_c_or('dev_queue.v3_blocked','Blocked: {reason}'),
                   '{reason}', v_blocked->>0) end,
    'tone', case when jsonb_array_length(v_blocked) = 0 then 'success' else 'warning' end,
    'drain_label', case when (v_drain->>'id') is null then ''
      else replace(_c_or('dev_queue.v3_drain_on','Draining: will stop after #{id}'), '{id}', v_drain->>'id') end,
    'actual', a,
    'vm', v_vm,
    'zone', admin_active_zone(),
    'date', admin_active_date());
end $function$;

-- ── copy ────────────────────────────────────────────────────────────────────
-- Every word the strip can print for a VM that is not running. The chip words
-- themselves (dev_queue.ctl_vm_running/stopped/starting/stopping/unknown) were
-- already rows; these are the sentences the banner needs so it stops saying
-- "off" about a box that is starting, stopping, or unreadable.
insert into ui_copy(key, value) values
  ('dev_queue.v3_vm_stopped',  to_jsonb('The VM is off, so nothing can build'::text)),
  ('dev_queue.v3_vm_starting', to_jsonb('The VM is starting — nothing can build until it is up'::text)),
  ('dev_queue.v3_vm_stopping', to_jsonb('The VM is shutting down, so nothing can build'::text)),
  ('dev_queue.v3_vm_unknown',  to_jsonb('The VM state could not be read from AWS just now'::text))
on conflict (key) do nothing;

grant execute on function public._vm_status_put(text, text, text, jsonb) to service_role;
grant execute on function public._vm_block() to anon, authenticated, service_role;
grant execute on function public._vm_ask(text) to service_role;
grant execute on function public.dev_vm_poll() to anon, authenticated, service_role;
