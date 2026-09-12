-- CHANGE #1367 — Runner control strip v3: DESIRED vs ACTUAL.
--
-- Why this exists, in one sentence: three separate capabilities were switched
-- ON and silently were not running, and nothing in the app could tell you.
--
-- The build branch is the proof. `build_branch_state()` said enabled=true,
-- `build_branch_decide()` said want=true with 22 pending commands — and status
-- had been 'off' since #1149 shipped. The supervisor logged "SUPABASE_ACCESS_TOKEN
-- not in the vault" on every tick while the vault held the token the whole time:
-- secret_get_runner returns a BARE JSON STRING and the caller piped it through
-- `jq .value`, which cannot index a string, errored to empty, and read as
-- absent. So production carried every build's load for days, the card said the
-- feature was on, and the one diagnostic anybody had pointed at the wrong thing.
--
-- A toggle that reports what it WANTS is not a status. This change makes the
-- card report both, and name the gap:
--
--     desired   — what Om asked for (dev_runner_config.desired_state)
--     actual    — what is observably true right now
--     blocked   — the backend's sentence for WHY they differ, or nothing
--
-- Every string below is built here. The strip prints them in payload order and
-- decides nothing.

-- ── 1. copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
 ('dev_queue.v3_vm',              '"VM"'::jsonb),
 ('dev_queue.v3_start',           '"Start building"'::jsonb),
 ('dev_queue.v3_parallel',        '"Parallel building"'::jsonb),
 ('dev_queue.v3_start_sub',       '"One runner, one command at a time."'::jsonb),
 ('dev_queue.v3_parallel_sub',    '"Up to {n} runners at once (Pool settings)."'::jsonb),
 ('dev_queue.v3_building',        '"Building {ids}"'::jsonb),
 ('dev_queue.v3_building_none',   '"Nothing building right now."'::jsonb),
 ('dev_queue.v3_blocked',         '"Blocked: {reason}"'::jsonb),
 ('dev_queue.v3_ok',              '"Running as asked."'::jsonb),
 ('dev_queue.v3_branch_on',       '"Build branch on · {age}"'::jsonb),
 ('dev_queue.v3_branch_off',      '"Build branch off"'::jsonb),
 ('dev_queue.v3_branch_missing',  '"Branch off: access token missing"'::jsonb),
 ('dev_queue.v3_branch_wanted',   '"Branch wanted for {n} pending, not created yet"'::jsonb),
 ('dev_queue.v3_usage_stale',     '"Usage sync failing: {reason}"'::jsonb),
 ('dev_queue.v3_rc_off',          '"Remote Control has no session — the app will look empty"'::jsonb),
 ('dev_queue.v3_vm_off',          '"The VM is off, so nothing can build"'::jsonb),
 ('dev_queue.v3_drain',           '"Stop after #{id}"'::jsonb),
 ('dev_queue.v3_drain_on',        '"Draining: will stop after #{id}"'::jsonb),
 ('dev_queue.v3_title',           '"Runners"'::jsonb)
on conflict (key) do nothing;

-- Draining is fleet state with two fields; it does not deserve a table.
insert into public.dev_runner_config (key, value) values ('drain_after', '{}'::jsonb)
on conflict (key) do nothing;

-- ── 2. ACTUAL — observed, never assumed ─────────────────────────────────────
-- Each field answers "is this observably true right now?" and nothing here
-- reads desired_state. That separation is the whole point: a function that
-- consults the toggle to describe reality can only ever agree with it.
create or replace function public.strip_v3_actual()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rc int; v_sess int; v_rep jsonb; v_rep_age numeric; v_building int; v_ids text; v_branch jsonb;
        v_usage jsonb; v_usage_age numeric; v_usage_err text; v_pending int;
begin
  select count(*) into v_sess from dev_agent_session where released_at is null;

  -- REMOTE CONTROL CANNOT BE OBSERVED FROM SQL. The rc-runner-N companions live
  -- in tmux; dev_agent_session records the WORKER loop (claude-N), so counting
  -- 'rc-%' here returns 0 on a perfectly healthy box. That is precisely the
  -- false negative #1369 shipped and had to fix hours later — a probe that
  -- reads absence of evidence as evidence of absence, wired to something that
  -- stops work. So RC is REPORTED by the supervisor (strip_v3_report) and read
  -- here with a staleness guard: no report, or a stale one, is UNKNOWN, and
  -- unknown never raises a blocker.
  select value into v_rep from dev_runner_config where key = 'strip_actual';
  v_rep := coalesce(v_rep, '{}'::jsonb);
  v_rep_age := case when (v_rep->>'at') is null then null
                    else extract(epoch from (now() - (v_rep->>'at')::timestamptz)) / 60.0 end;
  v_rc := case when v_rep_age is null or v_rep_age > 5 then null
               else (v_rep->>'rc_sessions')::int end;

  select count(*), string_agg('#'||id, ', ' order by id)
    into v_building, v_ids
    from dev_commands where status = 'building';

  select count(*) into v_pending from dev_commands where status = 'pending';

  begin v_branch := build_branch_state();
  exception when others then v_branch := jsonb_build_object('status','unknown');
  end;

  -- Usage freshness is a FACT about the last successful fetch — dev_usage_poll_state()
  -- owns it (and #1365 hardened it), so it is READ here rather than re-derived.
  -- A second opinion about the same clock is how two surfaces start disagreeing.
  begin
    v_usage := dev_usage_poll_state();
    v_usage_age := (v_usage->>'fetched_age_secs')::numeric / 60.0;
    v_usage_err := nullif(v_usage->>'fetch_error','');
  exception when others then
    v_usage_age := null; v_usage_err := 'usage state unreadable';
  end;

  return jsonb_build_object(
    'sessions',      v_sess,
    'rc_sessions',   v_rc,               -- null = not reported recently, NOT zero
    'rc_report_age_min', v_rep_age,
    'building',      v_building,
    'building_ids',  coalesce(v_ids, ''),
    'pending',       v_pending,
    'branch_status', coalesce(v_branch->>'status','unknown'),
    'branch_age',    coalesce(v_branch->>'age_label',''),
    'usage_age_min', v_usage_age,
    'usage_error',   coalesce(v_usage_err,''),
    'checked_at',    now());
end $$;

-- The supervisor's one write. Everything it reports is something SQL cannot
-- see for itself; nothing it reports is a decision.
create or replace function public.strip_v3_report(
  p_rc_sessions int default null, p_host_session boolean default null,
  p_detail text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  insert into dev_runner_config (key, value) values ('strip_actual','{}'::jsonb)
    on conflict (key) do nothing;
  update dev_runner_config
     set value = coalesce(value,'{}'::jsonb) || jsonb_build_object(
           'at', now()::text,
           'rc_sessions', p_rc_sessions,
           'host_session', p_host_session,
           'detail', left(coalesce(p_detail,''), 300))
   where key = 'strip_actual';
  return jsonb_build_object('ok', true);
end $$;

-- ── 3. the card: desired, actual, and the GAP named out loud ───────────────
-- The one rule: a blocker is only raised when the difference is OBSERVED. A
-- capability we cannot see (rc_sessions null, branch status unknown) is never
-- reported as broken — #1369 shipped a gate that read "cannot tell" as "broken"
-- and stopped the whole fleet with it inside a day.
create or replace function public.strip_v3_card()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare d jsonb; a jsonb; wp jsonb; v_blocked jsonb := '[]'::jsonb; v_add text;
        v_max int; v_drain jsonb; v_branch_want jsonb; v_toggles jsonb;
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

  -- ── the gaps, each stated as the backend's sentence ──────────────────────
  if coalesce(d->>'vm','off') <> 'on' then
    v_blocked := v_blocked || jsonb_build_array(_c_or('dev_queue.v3_vm_off','The VM is off, so nothing can build'));
  end if;

  -- Remote Control: only when the supervisor has actually SAID there are none.
  if (a->>'rc_sessions') is not null and (a->>'rc_sessions')::int = 0
     and coalesce(d->>'vm','off') = 'on' then
    v_blocked := v_blocked || jsonb_build_array(_c_or('dev_queue.v3_rc_off',''));
  end if;

  -- The build branch, which is the reason this change exists: wanted, enabled,
  -- work waiting, and still not there.
  if coalesce((v_branch_want->>'want')::boolean,false)
     and coalesce(a->>'branch_status','') <> 'ready' then
    -- pending + building: the branch is wanted for work IN FLIGHT too, and
    -- "wanted for 0 pending" is a sentence that makes a real blocker look like
    -- a glitch.
    v_add := replace(_c_or('dev_queue.v3_branch_wanted','Branch wanted for {n} command(s), not created yet'),
               '{n}', (coalesce((v_branch_want->>'pending')::int,0)
                     + coalesce((v_branch_want->>'building')::int,0))::text);
    v_blocked := v_blocked || jsonb_build_array(v_add);
  end if;

  if coalesce(a->>'usage_error','') <> '' then
    v_blocked := v_blocked || jsonb_build_array(
      replace(_c_or('dev_queue.v3_usage_stale','Usage sync failing: {reason}'),
              '{reason}', a->>'usage_error'));
  end if;

  -- ── the three toggles, each carrying desired AND actual ──────────────────
  v_toggles := jsonb_build_array(
    jsonb_build_object('key','vm', 'label', _c_or('dev_queue.v3_vm','VM'),
      'desired', coalesce(d->>'vm','off') = 'on',
      'actual',  coalesce((a->>'sessions')::int,0) > 0,
      'sub', ''),
    jsonb_build_object('key','claude', 'label', _c_or('dev_queue.v3_start','Start building'),
      'desired', coalesce(d->>'claude','off') = 'on',
      'actual',  coalesce((a->>'building')::int,0) > 0,
      'sub', _c_or('dev_queue.v3_start_sub','')),
    jsonb_build_object('key','workflow', 'label', _c_or('dev_queue.v3_parallel','Parallel building'),
      'desired', coalesce(d->>'workflow','off') = 'on',
      'actual',  coalesce((a->>'building')::int,0) > 1,
      'sub', replace(_c_or('dev_queue.v3_parallel_sub',''), '{n}', v_max::text)));

  return jsonb_build_object(
    'has', true,
    'title', _c_or('dev_queue.v3_title','Runners'),
    'toggles', v_toggles,
    'building_label', case when coalesce((a->>'building')::int,0) = 0
      then _c_or('dev_queue.v3_building_none','Nothing building right now.')
      else replace(_c_or('dev_queue.v3_building','Building {ids}'), '{ids}', a->>'building_ids') end,
    'building_ids', a->>'building_ids',
    'branch_label', case
      when coalesce(a->>'branch_status','') = 'ready'
        then replace(_c_or('dev_queue.v3_branch_on','Build branch on · {age}'), '{age}', coalesce(a->>'branch_age',''))
      else _c_or('dev_queue.v3_branch_off','Build branch off') end,
    'blocked', v_blocked,
    -- One sentence for the collapsed strip: the FIRST gap, or the all-clear.
    'headline', case when jsonb_array_length(v_blocked) = 0
      then _c_or('dev_queue.v3_ok','Running as asked.')
      else replace(_c_or('dev_queue.v3_blocked','Blocked: {reason}'),
                   '{reason}', v_blocked->>0) end,
    'tone', case when jsonb_array_length(v_blocked) = 0 then 'success' else 'warning' end,
    'drain_label', case when (v_drain->>'id') is null then ''
      else replace(_c_or('dev_queue.v3_drain_on','Draining: will stop after #{id}'), '{id}', v_drain->>'id') end,
    'actual', a,
    'zone', admin_active_zone(),
    'date', admin_active_date());
end $$;

-- ── 4. "stop after #N" ──────────────────────────────────────────────────────
-- A drain is the one control Om asked for that is neither a toggle nor a
-- restart: keep working through the queue, then stop once #N is done. It is
-- fleet state with one field, so it lives in dev_runner_config beside the
-- others rather than earning a table, and dev_cmd_claim consults it the same
-- way it consults the freeze.
create or replace function public.strip_v3_drain_set(p_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  insert into dev_runner_config (key, value) values ('drain_after','{}'::jsonb)
    on conflict (key) do nothing;
  if p_id is null then
    update dev_runner_config set value = '{}'::jsonb where key='drain_after';
    perform _audit('admin','strip_drain_clear','fleet','{}'::jsonb);
  else
    update dev_runner_config
       set value = jsonb_build_object('id', p_id, 'at', now()::text)
     where key='drain_after';
    perform _audit('admin','strip_drain_set', p_id::text, '{}'::jsonb);
  end if;
  return strip_v3_card();
end $$;

-- Is the fleet allowed to take NEW work right now? Drain says: only ids at or
-- below the marker. Deliberately a separate readable function rather than a
-- clause buried in the claim, so the strip and the claim path agree by
-- construction.
create or replace function public.strip_v3_drain_blocks(p_id bigint)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb;
begin
  select value into v from dev_runner_config where key='drain_after';
  if v is null or (v->>'id') is null then return false; end if;
  return p_id > (v->>'id')::bigint;
end $$;
