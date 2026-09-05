-- CHANGE #1368 — RUNNER OPS POLICIES.
--
-- #1367 gave the strip an honest answer to "is it running?". This gives the
-- fleet an answer to "SHOULD it be running, right now?" — and puts every one
-- of those answers in ONE place that the claim path, the supervisor and the
-- card all read, instead of three places that drift.
--
-- The shape is deliberately the same as #1367's: the backend DECIDES and words
-- it; the supervisor and the app only act and print. Every policy is a field in
-- worker_pool.ops, editable from Pool settings behind the safety PIN, and every
-- refusal comes back as a sentence the card can show without composing one.
--
-- Eight policies, one gate:
--   drain      — finish what is building, claim nothing new. A VM stop from the
--                app turns this on FIRST, so the box never dies mid-claim.
--   hours      — an IST window outside which nothing is claimed.
--   pace       — spread the burn so weekly / 5h usage lands AT the reset rather
--                than at Tuesday lunchtime; optionally flip to api billing at
--                the cap.
--   boost      — one tap, N extra workers, auto-reverts. No off switch to forget.
--   peak       — while order hours are open anywhere, the build semaphore drops:
--                customers ordering outrank builds on a 1 GB instance.
--   safe       — overnight, only work nobody has to watch: no danger rows, no
--                Android, no schema.
--   selfheal   — boot doctor red twice running reboots the box; still red after
--                that is a person's problem and says so.
--   drill      — every night, kill the VM on purpose and prove it comes back.
--
-- THE RULE #1369 COST A FLEET-DAY, restated: a policy may only block on a fact
-- it can SEE. An unknown usage reading, an unreadable clock, a missing config
-- are all "carry on" — never "stop". Every gate below fails OPEN.

-- ── 1. copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
 ('dev_queue.ops_title',           '"Runner policies"'::jsonb),
 ('dev_queue.ops_all_clear',       '"No policy is holding the queue."'::jsonb),
 ('dev_queue.ops_holding',         '"Holding: {reason}"'::jsonb),
 ('dev_queue.ops_drain',           '"Drain"'::jsonb),
 ('dev_queue.ops_drain_sub',       '"Finish what is building, claim nothing new."'::jsonb),
 ('dev_queue.ops_drain_on',        '"Draining — {n} still building"'::jsonb),
 ('dev_queue.ops_drain_done',      '"Drained. Nothing is building."'::jsonb),
 ('dev_queue.ops_drain_block',     '"Draining: the queue is finishing what it started and taking nothing new."'::jsonb),
 ('dev_queue.ops_hours',           '"Build hours"'::jsonb),
 ('dev_queue.ops_hours_sub',       '"Claim only between {from} and {to} IST."'::jsonb),
 ('dev_queue.ops_hours_block',     '"Outside build hours ({from}–{to} IST). Next window opens {in}."'::jsonb),
 ('dev_queue.ops_pace',            '"Quota pacing"'::jsonb),
 ('dev_queue.ops_pace_sub',        '"Spread the burn so usage lands at the reset."'::jsonb),
 ('dev_queue.ops_pace_ok',         '"On pace · weekly {w}, 5h {s}"'::jsonb),
 ('dev_queue.ops_pace_ahead',      '"{pct} ahead of pace on {window}"'::jsonb),
 ('dev_queue.ops_pace_block',      '"Pacing: {pct} ahead of the {window} budget — claiming again in {in}."'::jsonb),
 ('dev_queue.ops_pace_unknown',    '"Usage not readable — pacing stood down."'::jsonb),
 ('dev_queue.ops_api_switch',      '"Switched billing to api at {pct} — the subscription cap was reached."'::jsonb),
 ('dev_queue.ops_boost',           '"Boost"'::jsonb),
 ('dev_queue.ops_boost_sub',       '"{n} extra workers for one urgent batch."'::jsonb),
 ('dev_queue.ops_boost_on',        '"Boost: +{n} workers, {in} left"'::jsonb),
 ('dev_queue.ops_boost_off',       '"Boost off"'::jsonb),
 ('dev_queue.ops_peak',            '"Peak-hours throttle"'::jsonb),
 ('dev_queue.ops_peak_sub',        '"Drop to {n} worker while order hours are open."'::jsonb),
 ('dev_queue.ops_peak_on',         '"Order hours open — throttled to {n}"'::jsonb),
 ('dev_queue.ops_safe',            '"Safe night mode"'::jsonb),
 ('dev_queue.ops_safe_sub',        '"{from}–{to} IST: nothing risky claims unattended."'::jsonb),
 ('dev_queue.ops_safe_block',      '"Safe night mode ({from}–{to} IST): this command touches {what}, so it waits for the morning."'::jsonb),
 ('dev_queue.ops_safe_danger',     '"something marked dangerous"'::jsonb),
 ('dev_queue.ops_safe_android',    '"an Android release"'::jsonb),
 ('dev_queue.ops_safe_schema',     '"the database schema"'::jsonb),
 ('dev_queue.ops_selfheal',        '"Self-heal"'::jsonb),
 ('dev_queue.ops_selfheal_sub',    '"Reboot the VM after {n} red boot checks in a row."'::jsonb),
 ('dev_queue.ops_selfheal_fired',  '"Rebooting: {agent} failed its boot check {n} running."'::jsonb),
 ('dev_queue.ops_selfheal_watch',  '"{agent} went red {n} — one more and it reboots."'::jsonb),
 ('dev_queue.ops_once',            '"once"'::jsonb),
 ('dev_queue.ops_times',           '"{n} times"'::jsonb),
 ('dev_queue.ops_selfheal_failed', '"{agent} is STILL red after a reboot — this one needs you."'::jsonb),
 ('dev_queue.ops_drill',           '"Nightly kill-VM drill"'::jsonb),
 ('dev_queue.ops_drill_sub',       '"{at} IST: stop the box, boot it, prove it claims."'::jsonb),
 ('dev_queue.ops_drill_green',     '"Drill green — back and claiming in {secs}s"'::jsonb),
 ('dev_queue.ops_drill_red',       '"Drill RED — {reason}"'::jsonb),
 ('dev_queue.ops_drill_never',     '"Not run yet"'::jsonb),
 ('dev_queue.ops_drill_running',   '"Drill running — {phase}"'::jsonb),
 ('dev_queue.ops_stop_after',      '"Stop after #{id} — this one is past the marker."'::jsonb),
 ('dev_queue.ops_vm_off',          '"The VM powered itself off: {reason}"'::jsonb),
 ('dev_queue.ops_usage_cap',       '"Claude usage is at {pct} of the {window} limit."'::jsonb),
 ('dev_queue.ops_pin',             '"Policy changes need the safety PIN."'::jsonb),
 ('dev_queue.ops_boost_do',        '"Boost +2 · 30m"'::jsonb),
 ('dev_queue.ops_drill_do',        '"Run it now"'::jsonb),
 ('dev_queue.ops_toggled',         '"{label} is now {state}."'::jsonb),
 ('dev_queue.ops_on',              '"On"'::jsonb),
 ('dev_queue.ops_off',             '"Off"'::jsonb)
on conflict (key) do nothing;

-- ── 2. the policy block, with defaults ─────────────────────────────────────
-- Stored under worker_pool.ops so Pool settings already reaches it and nothing
-- needs a new table. Read through _ops_cfg() so a field added here later is
-- live for every caller without a backfill.
create or replace function public._ops_cfg()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare d jsonb; st jsonb; k text;
begin
  d := jsonb_build_object(
    'drain',    jsonb_build_object('on', false, 'at', null, 'reason', '', 'alerted', false),
    'hours',    jsonb_build_object('enabled', false, 'from', '00:00', 'to', '23:59'),
    'pace',     jsonb_build_object('enabled', true, 'slack_pct', 12, 'max_hold_s', 900,
                                   'api_switch', false, 'api_switch_pct', 95),
    'boost',    jsonb_build_object('until', null, 'workers', 0),
    'peak',     jsonb_build_object('enabled', true, 'semaphore', 1),
    'safe',     jsonb_build_object('enabled', true, 'from', '23:00', 'to', '06:30'),
    'selfheal', jsonb_build_object('enabled', true, 'reds', 2, 'cooldown_min', 60, 'last_at', null),
    'drill',    jsonb_build_object('enabled', true, 'at_ist', '03:10',
                                   'claim_within_s', 120, 'max_min', 25, 'last_on', null),
    'alerts',   jsonb_build_object('enabled', true, 'usage_pct', 90),
    'cycle',    jsonb_build_object('phase', 'idle', 'reason', '', 'checks', '{}'::jsonb));
  select value->'ops' into st from dev_runner_config where key='worker_pool';
  st := coalesce(st, '{}'::jsonb);
  -- DEEP by one level, which is all this block has. A shallow `d || st` would
  -- make every _ops_put on a nested path DELETE that policy's other defaults:
  -- writing {selfheal,last_at} alone would leave selfheal with no `enabled`,
  -- no `reds` and no cooldown, and the next tick would read them as absent.
  for k in select jsonb_object_keys(st) loop
    if jsonb_typeof(st->k) = 'object' and jsonb_typeof(d->k) = 'object' then
      d := jsonb_set(d, array[k], (d->k) || (st->k), true);
    else
      d := jsonb_set(d, array[k], st->k, true);
    end if;
  end loop;
  return d;
end $$;

-- A jsonb deep-merge for exactly two levels, which is all worker_pool.ops has.
-- pool_set() shallow-merges the top level, so patching {"ops":{"peak":{...}}}
-- through it would DELETE every other policy. That is not a hypothetical: the
-- same shallow merge is why pool_set carries a special case for `routing`.
create or replace function public.runner_ops_set(p_patch jsonb, p_pin text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_ops jsonb; k text;
begin
  perform _dev_guard();
  if not sec_pin_verify(p_pin) then
    raise exception '%', _c_or('dev_queue.ops_pin','Policy changes need the safety PIN.');
  end if;
  select value into v from dev_runner_config where key='worker_pool';
  v := coalesce(v,'{}'::jsonb);
  v_ops := coalesce(v->'ops','{}'::jsonb);
  for k in select jsonb_object_keys(coalesce(p_patch,'{}'::jsonb)) loop
    if jsonb_typeof(p_patch->k) = 'object' then
      v_ops := jsonb_set(v_ops, array[k], coalesce(v_ops->k,'{}'::jsonb) || (p_patch->k), true);
    else
      v_ops := jsonb_set(v_ops, array[k], p_patch->k, true);
    end if;
  end loop;
  update dev_runner_config set value = jsonb_set(v, '{ops}', v_ops, true) where key='worker_pool';
  perform _audit(_actor(),'runner_ops_set', null, jsonb_build_object('patch', p_patch));
  return runner_ops_card();
end $$;

-- One private writer for the fields the POLICIES set themselves (drain flags,
-- boost expiry, the cycle phase). Never PIN-gated — these are the machine's own
-- bookkeeping, not Om's settings.
create or replace function public._ops_put(p_path text[], p_value jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; ops jsonb;
begin
  select value into v from dev_runner_config where key='worker_pool';
  v := coalesce(v,'{}'::jsonb);
  ops := coalesce(v->'ops','{}'::jsonb);
  -- jsonb_set CANNOT create an intermediate object. Setting {pace,slack_pct} on
  -- a document that has no `pace` returns the document UNCHANGED and reports
  -- success — so every nested write here (drain.alerted, selfheal.last_at,
  -- drill.last_on, and every cycle phase transition) was a silent no-op on a
  -- fresh install. That is the whole drill machine failing to advance while
  -- each step reports ok. The parent is materialised from the defaults first.
  if array_length(p_path,1) > 1 and not (ops ? p_path[1]) then
    ops := jsonb_set(ops, array[p_path[1]], coalesce(_ops_cfg()->p_path[1], '{}'::jsonb), true);
  end if;
  ops := jsonb_set(ops, p_path, p_value, true);
  update dev_runner_config set value = jsonb_set(v, '{ops}', ops, true) where key='worker_pool';
end $$;

-- ── 3. clocks ──────────────────────────────────────────────────────────────
-- One IST window test, used by build hours and safe mode alike, including the
-- wrap across midnight that safe mode always has.
create or replace function public._ops_in_window(p_from text, p_to text)
returns boolean language plpgsql immutable set search_path to 'public' as $$
declare t time; a time; b time;
begin
  begin
    t := (now() at time zone 'Asia/Kolkata')::time;
    a := p_from::time; b := p_to::time;
  exception when others then
    return true;                       -- unreadable clock or config: never block
  end;
  if a = b then return true; end if;
  if a < b then return t >= a and t < b; end if;
  return t >= a or t < b;              -- wraps midnight
end $$;

-- Seconds until the window opens again, for an honest retry_after.
create or replace function public._ops_until_window(p_from text)
returns int language plpgsql stable set search_path to 'public' as $$
declare n timestamptz; o timestamptz;
begin
  begin
    n := now() at time zone 'Asia/Kolkata';
    o := date_trunc('day', n) + p_from::time;
    if o <= n then o := o + interval '1 day'; end if;
    return greatest(60, least(6*3600, extract(epoch from (o - n))::int));
  exception when others then return 300;
  end;
end $$;

-- ── 4. pacing ──────────────────────────────────────────────────────────────
-- "Spread claims so weekly / 5h usage lands at the reset." Both windows carry a
-- resets_at and a length, so the budget line is simply how far through the
-- window we are. Burning ahead of that line is the only thing pacing reacts to,
-- and it self-clears as the clock moves — the hold can never become permanent.
--
-- An UNKNOWN reading stands pacing down entirely. #1365 is the reason: a stale
-- 100% weekly whose window had already reset shrank the pool to one, so nothing
-- claimed, so no session started, so the token never refreshed and the reading
-- never updated. A guard that cannot be cleared by the thing it stops is a trap.
create or replace function public.runner_ops_pace()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare u jsonb; l jsonb; v_w numeric; v_s numeric; v_wp numeric; v_sp numeric;
        v_known boolean := false; v_ahead numeric := 0; v_win text := '';
        v_reset timestamptz; v_len numeric;
begin
  begin select value into u from dev_runner_config where key='claude_usage';
  exception when others then u := null; end;
  u := coalesce(u,'{}'::jsonb);
  if (u->>'fetched_at') is null then
    return jsonb_build_object('known', false, 'ahead_pct', 0, 'window', '');
  end if;

  -- 5h session
  v_reset := nullif(u#>>'{five_hour,resets_at}','')::timestamptz;
  v_s     := nullif(u#>>'{five_hour,utilization}','')::numeric;
  if v_reset is not null and v_s is not null and v_reset > now() then
    v_len := 5*3600;
    v_sp  := greatest(0, least(100, 100 * (1 - extract(epoch from (v_reset - now())) / v_len)));
    v_known := true;
    if v_s - v_sp > v_ahead then v_ahead := v_s - v_sp; v_win := '5h'; end if;
  end if;

  -- weekly (all models)
  v_reset := nullif(u#>>'{seven_day,resets_at}','')::timestamptz;
  v_w     := nullif(u#>>'{seven_day,utilization}','')::numeric;
  if v_reset is not null and v_w is not null and v_reset > now() then
    v_len := 7*24*3600;
    v_wp  := greatest(0, least(100, 100 * (1 - extract(epoch from (v_reset - now())) / v_len)));
    v_known := true;
    if v_w - v_wp > v_ahead then v_ahead := v_w - v_wp; v_win := 'weekly'; end if;
  end if;

  return jsonb_build_object(
    'known', v_known,
    'weekly_pct', v_w, 'weekly_pace_pct', round(coalesce(v_wp,0)),
    'session_pct', v_s, 'session_pace_pct', round(coalesce(v_sp,0)),
    'ahead_pct', round(v_ahead), 'window', v_win);
end $$;

-- ── 5. the effective worker count ──────────────────────────────────────────
-- build_semaphore stays exactly what Om set. Peak and boost are applied HERE,
-- never written back — pool_set() rewrites build_semaphore from cap whenever a
-- patch omits it, so a throttle stored in that field would be silently undone
-- by the next unrelated settings save, and a boost stored there would become
-- permanent. Derived, every time, from facts.
create or replace function public.runner_ops_semaphore()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o jsonb; wp jsonb; v_base int; v_eff int; v_reason text := '';
        v_peak boolean := false; v_boost int := 0; v_until timestamptz;
begin
  o := _ops_cfg();
  select value into wp from dev_runner_config where key='worker_pool';
  wp := coalesce(wp,'{}'::jsonb);
  v_base := greatest(coalesce((wp->>'build_semaphore')::int, (wp->>'cap')::int, 2), 1);
  v_eff := v_base;

  v_until := nullif(o#>>'{boost,until}','')::timestamptz;
  if v_until is not null and v_until > now() then
    v_boost := greatest(coalesce((o#>>'{boost,workers}')::int, 0), 0);
    v_eff := v_eff + v_boost;
    if v_boost > 0 then v_reason := 'boost'; end if;
  end if;

  if coalesce((o#>>'{peak,enabled}')::boolean, true) then
    select exists(select 1 from order_hours where is_open) into v_peak;
    if v_peak then
      v_eff := least(v_eff, greatest(coalesce((o#>>'{peak,semaphore}')::int, 1), 1));
      v_reason := 'peak';
    end if;
  end if;

  v_eff := greatest(least(v_eff, greatest(coalesce((wp->>'max')::int, 8), 1)), 1);
  return jsonb_build_object(
    'base', v_base, 'effective', v_eff, 'reason', v_reason,
    'peak_open', v_peak, 'boost_workers', v_boost,
    'boost_until', v_until,
    'boost_left_s', case when v_until is null or v_until <= now() then 0
                         else extract(epoch from (v_until - now()))::int end);
end $$;

-- ── 6. THE GATE — fleet half ───────────────────────────────────────────────
-- Called once per claim, before any row is looked at. Every branch fails OPEN:
-- an exception anywhere returns "carry on", because a policy layer that stops
-- the fleet when IT breaks is worse than no policy layer.
create or replace function public.runner_ops_gate(p_agent text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o jsonb; p jsonb; v_slack numeric; v_hold int; v_in int;
begin
  o := _ops_cfg();

  if coalesce((o#>>'{drain,on}')::boolean, false) then
    return jsonb_build_object('block', true, 'policy', 'drain',
      'reason', _c_or('dev_queue.ops_drain_block','Draining — the queue is taking nothing new.'),
      'retry_after_seconds', 300);
  end if;

  if coalesce((o#>>'{hours,enabled}')::boolean, false)
     and not _ops_in_window(o#>>'{hours,from}', o#>>'{hours,to}') then
    v_in := _ops_until_window(o#>>'{hours,from}');
    return jsonb_build_object('block', true, 'policy', 'hours',
      'reason', replace(replace(replace(
          _c_or('dev_queue.ops_hours_block','Outside build hours ({from}-{to} IST). Next window opens {in}.'),
          '{from}', coalesce(o#>>'{hours,from}','')), '{to}', coalesce(o#>>'{hours,to}','')),
          '{in}', _ops_dur(v_in)),
      'retry_after_seconds', v_in);
  end if;

  if coalesce((o#>>'{pace,enabled}')::boolean, true) then
    p := runner_ops_pace();
    if coalesce((p->>'known')::boolean, false) then
      v_slack := coalesce((o#>>'{pace,slack_pct}')::numeric, 12);
      if coalesce((p->>'ahead_pct')::numeric, 0) > v_slack then
        v_hold := least(greatest(coalesce((o#>>'{pace,max_hold_s}')::int, 900), 60),
                        greatest(60, (((p->>'ahead_pct')::numeric - v_slack) * 30)::int));
        return jsonb_build_object('block', true, 'policy', 'pace',
          'reason', replace(replace(replace(
              _c_or('dev_queue.ops_pace_block','Pacing: {pct} ahead of the {window} budget - claiming again in {in}.'),
              '{pct}', (p->>'ahead_pct')||'%'), '{window}', coalesce(p->>'window','')),
              '{in}', _ops_dur(v_hold)),
          'retry_after_seconds', v_hold, 'pace', p);
      end if;
    end if;
  end if;

  return jsonb_build_object('block', false, 'policy', '', 'reason', '');
exception when others then
  return jsonb_build_object('block', false, 'policy', '', 'reason', '', 'gate_error', sqlerrm);
end $$;

-- A duration in words, so no caller ever formats one.
create or replace function public._ops_dur(p_secs int)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when coalesce(p_secs,0) < 90 then greatest(coalesce(p_secs,0),0)::text || 's'
    when p_secs < 5400 then (p_secs/60)::text || 'm'
    else (p_secs/3600)::text || 'h ' || ((p_secs%3600)/60)::text || 'm' end
$$;

-- ── 7. THE GATE — row half ─────────────────────────────────────────────────
-- Takes the row's own columns rather than its id: the claim runs this inside a
-- WHERE over every pending candidate, and a function that re-selected the row
-- it was just handed would turn one scan into N.
create or replace function public.runner_ops_row_blocked(
  p_id bigint, p_is_danger boolean, p_android boolean, p_files text[])
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare o jsonb;
begin
  if strip_v3_drain_blocks(p_id) then return true; end if;   -- "stop after #N" (#1367)
  o := _ops_cfg();
  if not coalesce((o#>>'{safe,enabled}')::boolean, true) then return false; end if;
  if not _ops_in_window(o#>>'{safe,from}', o#>>'{safe,to}') then return false; end if;
  return coalesce(p_is_danger,false)
      or coalesce(p_android,false)
      or exists (select 1 from unnest(coalesce(p_files,'{}'::text[])) f
                  where f like 'supabase/migrations/%');
exception when others then return false;
end $$;

-- The same decision in words, for the card and for the claim's "nothing for
-- you" reply. Kept beside the boolean so the two can never say different things.
create or replace function public.runner_ops_row_reason(p_id bigint)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare o jsonb; r record; v_what text;
begin
  select is_danger, targets_android, predicted_files into r from dev_commands where id = p_id;
  if not found then return ''; end if;
  if strip_v3_drain_blocks(p_id) then
    return replace(_c_or('dev_queue.ops_stop_after','Stop after #{id}.'), '{id}', p_id::text);
  end if;
  o := _ops_cfg();
  if not coalesce((o#>>'{safe,enabled}')::boolean, true)
     or not _ops_in_window(o#>>'{safe,from}', o#>>'{safe,to}') then return ''; end if;
  v_what := case
    when coalesce(r.is_danger,false) then _c_or('dev_queue.ops_safe_danger','something marked dangerous')
    when coalesce(r.targets_android,false) then _c_or('dev_queue.ops_safe_android','an Android release')
    when exists (select 1 from unnest(coalesce(r.predicted_files,'{}'::text[])) f
                  where f like 'supabase/migrations/%')
      then _c_or('dev_queue.ops_safe_schema','the database schema')
    else '' end;
  if v_what = '' then return ''; end if;
  return replace(replace(replace(
    _c_or('dev_queue.ops_safe_block','Safe night mode ({from}-{to} IST): this command touches {what}.'),
    '{from}', coalesce(o#>>'{safe,from}','')), '{to}', coalesce(o#>>'{safe,to}','')),
    '{what}', v_what);
end $$;

-- ── 8. drain ───────────────────────────────────────────────────────────────
create or replace function public.runner_ops_drain_set(p_on boolean, p_reason text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  perform _ops_put('{drain}'::text[], jsonb_build_object(
    'on', coalesce(p_on,false),
    'at', case when coalesce(p_on,false) then now()::text else null end,
    'reason', left(coalesce(p_reason,''), 200),
    'alerted', false));
  perform _audit(_actor(), case when coalesce(p_on,false) then 'ops_drain_on' else 'ops_drain_off' end,
                 null, jsonb_build_object('reason', p_reason));
  return runner_ops_card();
end $$;

-- "VM stop from the app always drains first." The stop path is dev_ctl_set,
-- which is a large function several changes already depend on; a trigger on the
-- row it writes gets the same guarantee without reopening it — and catches the
-- supervisor's own writes and any future caller too, which an edit inside
-- dev_ctl_set would not.
create or replace function public._ops_desired_state_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if NEW.key <> 'desired_state' then return NEW; end if;
  if coalesce(NEW.value->>'vm','on') = 'off'
     and coalesce(OLD.value->>'vm','on') <> 'off' then
    NEW.value := NEW.value;      -- untouched; the drain lives in worker_pool
    perform _ops_put('{drain}'::text[], jsonb_build_object(
      'on', true, 'at', now()::text, 'alerted', false,
      'reason', 'VM stop requested — draining first'));
  elsif coalesce(NEW.value->>'vm','on') = 'on'
        and coalesce(OLD.value->>'vm','on') = 'off' then
    -- Coming back up clears the drain the stop set. A drain Om set BY HAND is
    -- left alone: it carries no such reason and outlives a power cycle.
    if coalesce((_ops_cfg()#>>'{drain,reason}'), '') like 'VM stop requested%' then
      perform _ops_put('{drain}'::text[], jsonb_build_object(
        'on', false, 'at', null, 'reason', '', 'alerted', false));
    end if;
  end if;
  return NEW;
exception when others then return NEW;
end $$;

drop trigger if exists _ops_desired_state_trg on public.dev_runner_config;
create trigger _ops_desired_state_trg
  before update on public.dev_runner_config
  for each row execute function public._ops_desired_state_trg();

-- ── 9. boost ───────────────────────────────────────────────────────────────
create or replace function public.runner_ops_boost(p_minutes int default 30, p_workers int default 2)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_min int; v_w int;
begin
  perform _dev_guard();
  v_min := least(greatest(coalesce(p_minutes,30), 5), 240);
  v_w   := least(greatest(coalesce(p_workers,2), 0), 6);
  perform _ops_put('{boost}'::text[], jsonb_build_object(
    'until', case when v_w = 0 then null else (now() + make_interval(mins => v_min))::text end,
    'workers', v_w));
  perform _audit(_actor(),'ops_boost', null, jsonb_build_object('minutes',v_min,'workers',v_w));
  return runner_ops_card();
end $$;

-- ── 10. alerts ─────────────────────────────────────────────────────────────
-- FOUR NEW ROUTES, and deliberately not a fifth for "runners blocked": #1366
-- already ships sec_runner_blocked and _runner_blocked_sync already fires it on
-- a red boot. A second route for the same fact would double every alert. What
-- was genuinely missing is the ESCALATION — a box that is still red AFTER the
-- self-heal reboot — so that is the fourth route here.
--
-- Sent through notify(), never wa_send_event(): a route created in a migration
-- has template_id NULL, and wa_send_event answers route_disabled for exactly
-- that, so an alert written this way is silent on the day it ships. notify()
-- takes the same route row and tries push, then the WA template, then email.
insert into public.wa_event_routes
  (event_key, label, description, audience, enabled, template_name, auto_template_name,
   auto_manage, variable_map, dedupe_minutes, wa_category, bypass_send_window,
   push_enabled, email_enabled, push_title, push_body, email_subject, email_body,
   fallback_event_key)
values
  ('ops_usage_cap', 'Claude usage near the cap',
   'Claude usage crossed the alert threshold in worker_pool.ops.alerts.usage_pct. Re-sent at most every 2 hours while it stays there.',
   'admin', true, 'ops_usage_cap', 'ops_usage_cap', true,
   '["{{pct}}","{{window}}","{{resets}}"]'::jsonb, 120, 'utility', true,
   true, true, 'Claude usage {{pct}}', '{{window}} limit · resets {{resets}}',
   'mediBO — Claude usage at {{pct}}',
   'The {{window}} limit is at {{pct}}. It resets {{resets}}. Builds keep running; pacing is spreading what is left.',
   -- FALLBACK IS SET EXPLICITLY, and it is NULL for everything that is not a
   -- failure. An admin route left without one inherits `dev_cmd_failed`, whose
   -- approved body is "mediBO dev queue: command {{1}} failed. Reason: {{2}}."
   -- The first proof send of ops_drain_complete went out on that carrier and
   -- told Om that a drain which had just SUCCEEDED had failed — a paid message
   -- saying the opposite of what happened. Until Meta approves the seeded
   -- templates above, these three go by push / email and otherwise wait in the
   -- retry queue, which is honest. Only the genuinely-failed one rides the
   -- failure carrier, where the sentence is true.
   NULL),
  ('ops_vm_auto_off', 'Builder VM powered off',
   'The builder VM shut itself down — idle, or the VM toggle was switched off. Sent once per power-off.',
   'admin', true, 'ops_vm_auto_off', 'ops_vm_auto_off', true,
   '["{{reason}}","{{at}}"]'::jsonb, 10, 'utility', true,
   true, true, 'Builder VM off', '{{reason}}',
   'mediBO builder VM powered off',
   'The builder VM powered off at {{at}}. Reason: {{reason}}. Switch VM back on in Dev Queue when you need it.', NULL),
  ('ops_drain_complete', 'Drain complete',
   'Drain mode was on and the last building command finished — the fleet is now idle and claiming nothing.',
   'admin', true, 'ops_drain_complete', 'ops_drain_complete', true,
   '["{{reason}}","{{at}}"]'::jsonb, 10, 'utility', true,
   true, true, 'Drain complete', 'Nothing is building. {{reason}}',
   'mediBO — drain complete',
   'Every building command finished at {{at}} and the queue is taking nothing new. Reason for the drain: {{reason}}.', NULL),
  ('ops_selfheal_failed', 'Runner still red after reboot',
   'Self-heal rebooted the builder VM because the boot doctor went red twice, and it came back red anyway. This one needs a person.',
   'admin', true, 'ops_selfheal_failed', 'ops_selfheal_failed', true,
   '["{{agent}}","{{reds}}","{{reason}}"]'::jsonb, 60, 'utility', true,
   true, true, 'Runner still red', '{{agent}}: {{reason}}',
   'mediBO — {{agent}} still red after a reboot',
   '{{agent}} failed its boot check {{reds}} times and a reboot did not fix it. Last reason: {{reason}}. Nothing is claiming until this is sorted.',
   'dev_cmd_failed')
on conflict (event_key) do update set
  label = excluded.label, description = excluded.description,
  audience = excluded.audience, fallback_event_key = excluded.fallback_event_key, enabled = excluded.enabled,
  variable_map = excluded.variable_map, dedupe_minutes = excluded.dedupe_minutes,
  push_enabled = excluded.push_enabled, email_enabled = excluded.email_enabled,
  push_title = excluded.push_title, push_body = excluded.push_body,
  email_subject = excluded.email_subject, email_body = excluded.email_body;

-- The WA leg only lights up once Meta approves a template, and template
-- creation needs an authenticated super admin — a migration cannot do it. The
-- seed rows are the copy waiting for that approval; notify() reaches Om today
-- through push and email regardless.
insert into public.wa_event_template_seeds (name, category, language, token_map, components)
values
 ('ops_usage_cap','UTILITY','en', '["pct","window","resets"]'::jsonb,
  '[{"type":"BODY","text":"mediBO: Claude usage is at {{1}} of the {{2}} limit. It resets {{3}}.","example":{"body_text":[["92%","weekly","Sat 12 Sep"]]}},{"type":"FOOTER","text":"mediBO — builder"}]'::jsonb),
 ('ops_vm_auto_off','UTILITY','en', '["reason","at"]'::jsonb,
  '[{"type":"BODY","text":"mediBO: the builder VM powered off at {{2}}. Reason: {{1}}.","example":{"body_text":[["idle 30m, queue empty","05 Sep 03:14 IST"]]}},{"type":"FOOTER","text":"mediBO — builder"}]'::jsonb),
 ('ops_drain_complete','UTILITY','en', '["reason","at"]'::jsonb,
  '[{"type":"BODY","text":"mediBO: the build queue drained at {{2}}. Nothing is building. Reason: {{1}}.","example":{"body_text":[["VM stop requested","05 Sep 03:14 IST"]]}},{"type":"FOOTER","text":"mediBO — builder"}]'::jsonb),
 ('ops_selfheal_failed','UTILITY','en', '["agent","reds","reason"]'::jsonb,
  '[{"type":"BODY","text":"mediBO: {{1}} failed its boot check {{2}} times and a reboot did not fix it. Last reason: {{3}}.","example":{"body_text":[["runner-1","3","disk 98% full"]]}},{"type":"FOOTER","text":"mediBO — builder"}]'::jsonb)
on conflict (name) do update set
  category = excluded.category, language = excluded.language,
  token_map = excluded.token_map, components = excluded.components;

-- ops_drill_run.runbook_key is a foreign key into ops_runbook, so the two
-- cycles this change can run are declared there as first-class runbooks — which
-- also puts them on the Ops runbook screen beside the other drills instead of
-- inventing a second place to look.
insert into public.ops_runbook
  (key, sort, title, dependency, failure, detection, fallback, manual_steps,
   alert_kind, drill_note, owner_label)
values
 ('runner_kill_vm_drill', 90, 'Builder VM does not come back',
  'AWS EC2 + the builder VM''s own boot path',
  'The VM stops (idle, a toggle, a crash) and never returns to a state where it can build: usage never syncs, Remote Control never registers, or nothing is ever claimed.',
  'The nightly kill-VM drill stops the box on purpose and asserts all three within the window; a red drill raises an rg_alert and messages Om.',
  'Switch the VM toggle on by hand in Dev Queue; the supervisor reconciles the rest on its next tick.',
  '["Dev Queue -> Runner policies -> read the drill line","Switch VM on in the Runner strip","Watch usage sync and the worker chips come back","If it stays down, check the EC2 console and the AWS key in Secrets"]'::jsonb,
  'ops_selfheal_failed',
  'Stops the VM while the queue is idle, boots it, and asserts usage freshness, a registered Remote Control session, and a claim inside the configured window.',
  'Ops'),
 ('runner_kill_vm_selfheal', 91, 'Builder boot doctor red twice running',
  'The builder VM',
  'The boot doctor fails twice in a row, so the box refuses to claim and the queue silently stops moving.',
  'runner_ops_tick() derives consecutive reds from runner_boot_event and reboots the box once; a box that is still red after that messages Om.',
  'Nothing claims until it is fixed by hand — the alert names the failing check.',
  '["Read the boot check named in the alert","Free disk / restore the Claude login as it says","Restart the supervisor","Confirm a green boot event in Dev Queue -> Runner boot"]'::jsonb,
  'ops_selfheal_failed',
  'Not scheduled — fires by itself the second time a boot check goes red.',
  'Ops')
on conflict (key) do update set
  title = excluded.title, failure = excluded.failure, detection = excluded.detection,
  fallback = excluded.fallback, manual_steps = excluded.manual_steps,
  drill_note = excluded.drill_note, updated_at = now();

create or replace function public.runner_ops_alert(p_kind text, p_vars jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare o jsonb; v jsonb;
begin
  o := _ops_cfg();
  if not coalesce((o#>>'{alerts,enabled}')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'alerts_disabled');
  end if;
  v := notify(p_kind, null, coalesce(p_vars,'{}'::jsonb));
  return jsonb_build_object('ok', true, 'kind', p_kind, 'notify', v);
exception when others then
  return jsonb_build_object('ok', false, 'reason', sqlerrm);
end $$;

-- The supervisor calls this immediately before `shutdown -h now`, so the alert
-- is sent by a box that still exists.
create or replace function public.runner_ops_vm_off_report(p_reason text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  return runner_ops_alert('ops_vm_auto_off', jsonb_build_object(
    'reason', left(coalesce(p_reason,''), 200),
    'at', to_char(now() at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST'));
end $$;

-- ── 11. self-heal ──────────────────────────────────────────────────────────
-- Consecutive reds are DERIVED from runner_boot_event rather than counted into
-- a field: a counter has to be reset by somebody, and the somebody is always
-- the path that is already broken.
create or replace function public.runner_ops_reds(p_agent text)
returns int language sql stable security definer set search_path to 'public' as $$
  with e as (
    select verdict, row_number() over (order by at desc) rn
      from runner_boot_event
     where agent = p_agent
     order by at desc limit 20)
  select coalesce((select min(rn) from e where verdict = 'green'), (select count(*)+1 from e))::int - 1
$$;

create or replace function public.runner_ops_health()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o jsonb; r record; v_worst int := 0; v_agent text := ''; v_reason text := '';
        v_reds int;
begin
  o := _ops_cfg();
  -- Only an agent that has booted RECENTLY can be currently failing. A runner
  -- whose last event was a red two days ago has not been red since — it has not
  -- been anything since — and counting it would leave the card permanently
  -- accusing a slot that no longer exists.
  for r in
    select agent, max(at) as last_at from runner_boot_event
     where at > now() - interval '6 hours' group by agent
  loop
    v_reds := runner_ops_reds(r.agent);
    if v_reds > v_worst then v_worst := v_reds; v_agent := r.agent; end if;
  end loop;
  if v_agent <> '' then
    select coalesce(be.checks::text, '') into v_reason
      from runner_boot_event be where be.agent = v_agent order by be.at desc limit 1;
  end if;
  return jsonb_build_object(
    'enabled', coalesce((o#>>'{selfheal,enabled}')::boolean, true),
    'threshold', coalesce((o#>>'{selfheal,reds}')::int, 2),
    'reds', v_worst, 'agent', v_agent,
    'reds_label', case when v_worst = 1 then _c_or('dev_queue.ops_once','once')
                       else replace(_c_or('dev_queue.ops_times','{n} times'), '{n}', v_worst::text) end,
    'reason', left(coalesce(v_reason,''), 200));
end $$;

-- ── 12. the VM power cycle — ONE machine, two callers ──────────────────────
-- Self-heal and the nightly drill both want the same thing: take the box down,
-- bring it back, and judge what came back. Written once. The phases live in
-- worker_pool.ops.cycle and every step is driven from the CRON DISPATCHER, not
-- from the box — which is the whole point, because for most of the run the box
-- is off and can drive nothing.
create or replace function public._ops_vm_call(p_action text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_key text; v_req bigint;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'SERVICE_ROLE_KEY';
  if v_key is null then return jsonb_build_object('ok', false, 'reason', 'no_service_key'); end if;
  select net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/vm-control',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || v_key),
    body := jsonb_build_object('action', p_action),
    timeout_milliseconds := 20000) into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req, 'action', p_action);
exception when others then
  return jsonb_build_object('ok', false, 'reason', sqlerrm);
end $$;

-- Seconds since the box last said anything at all. NULL means it has never
-- reported, which is not the same as "it is down" and is never treated as such.
create or replace function public._ops_box_age()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select extract(epoch from (now() - (value->>'alive_at')::timestamptz))
    from dev_runner_config where key = 'runner_status'
$$;

create or replace function public.runner_ops_cycle_start(p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare o jsonb; v_build int; v_max int;
begin
  perform _dev_guard();
  o := _ops_cfg();
  if coalesce(o#>>'{cycle,phase}', 'idle') not in ('idle','green','red') then
    return jsonb_build_object('ok', false, 'reason', 'a power cycle is already running',
                              'phase', o#>>'{cycle,phase}');
  end if;
  select count(*) into v_build from dev_commands where status = 'building';
  if v_build > 0 and p_reason = 'drill' then
    return jsonb_build_object('ok', false, 'reason', 'not idle', 'building', v_build);
  end if;
  v_max := greatest(coalesce((o#>>'{drill,max_min}')::int, 25), 5);
  perform _ops_put('{cycle}'::text[], jsonb_build_object(
    'reason', p_reason, 'phase', 'stopping', 'at', now()::text,
    'deadline', (now() + make_interval(mins => v_max))::text,
    'checks', '{}'::jsonb, 'note', ''));
  -- Belt and braces, on purpose. desired_state.vm='off' is the path that has
  -- ALWAYS worked (the running box powers itself down and needs no cloud
  -- credential); vm-control stop is the one that also works when the box is
  -- already wedged. The drain trigger fires off the first, so in-flight work is
  -- finished before anything stops.
  update dev_runner_config
     set value = jsonb_set(value, '{vm}', '"off"'::jsonb) where key = 'desired_state';
  perform _ops_vm_call('stop');
  perform _audit('runner','ops_cycle_start', p_reason, '{}'::jsonb);
  return jsonb_build_object('ok', true, 'phase', 'stopping', 'reason', p_reason);
end $$;

create or replace function public.runner_ops_cycle_step()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare o jsonb; c jsonb; v_phase text; v_age numeric; v_dead timestamptz;
        v_boot timestamptz; v_usage jsonb; v_rc jsonb; v_rc_age numeric;
        v_claimed boolean; v_pending int; v_checks jsonb; v_fail text := '';
        v_secs int;
begin
  o := _ops_cfg(); c := coalesce(o->'cycle','{}'::jsonb);
  v_phase := coalesce(c->>'phase','idle');
  if v_phase in ('idle','green','red') then
    return jsonb_build_object('ok', true, 'phase', v_phase, 'acted', false);
  end if;
  v_dead := nullif(c->>'deadline','')::timestamptz;
  v_age  := _ops_box_age();

  if v_dead is not null and now() > v_dead then
    perform _ops_put('{cycle,phase}'::text[], '"red"'::jsonb);
    perform _ops_put('{cycle,note}'::text[],
      to_jsonb('timed out in phase '||v_phase));
    perform _ops_finish_cycle(c->>'reason', 'red', 'timed out in phase '||v_phase, c);
    return jsonb_build_object('ok', true, 'phase', 'red', 'reason', 'timeout');
  end if;

  if v_phase = 'stopping' then
    -- Down means silent. 120 s is four supervisor ticks: long enough that a slow
    -- tick is never mistaken for a dead box.
    if v_age is null or v_age > 120 then
      update dev_runner_config
         set value = jsonb_set(value, '{vm}', '"on"'::jsonb) where key = 'desired_state';
      perform _ops_vm_call('start');
      perform _ops_put('{cycle,phase}'::text[], '"starting"'::jsonb);
      perform _ops_put('{cycle,down_at}'::text[], to_jsonb(now()::text));
      return jsonb_build_object('ok', true, 'phase', 'starting');
    end if;
    return jsonb_build_object('ok', true, 'phase', 'stopping', 'box_age_s', v_age);
  end if;

  if v_phase = 'starting' then
    if v_age is not null and v_age < 120 then
      perform _ops_put('{cycle,phase}'::text[], '"booting"'::jsonb);
      perform _ops_put('{cycle,boot_at}'::text[], to_jsonb(now()::text));
      return jsonb_build_object('ok', true, 'phase', 'booting');
    end if;
    return jsonb_build_object('ok', true, 'phase', 'starting', 'box_age_s', v_age);
  end if;

  -- booting: the three asserts the drill exists to make.
  v_boot := coalesce(nullif(c->>'boot_at','')::timestamptz, now());
  begin v_usage := dev_usage_poll_state(); exception when others then v_usage := '{}'::jsonb; end;
  select value into v_rc from dev_runner_config where key = 'strip_actual';
  v_rc := coalesce(v_rc,'{}'::jsonb);
  v_rc_age := case when (v_rc->>'at') is null then null
                   else extract(epoch from (now() - (v_rc->>'at')::timestamptz)) end;
  select count(*) into v_pending from dev_commands where status = 'pending';
  select exists(select 1 from dev_commands
                 where started_at is not null and started_at >= v_boot) into v_claimed;

  v_checks := jsonb_build_object(
    'usage_fresh', coalesce((v_usage->>'fetched_age_secs')::numeric, 1e9) < 900,
    'usage_age_s', v_usage->>'fetched_age_secs',
    'rc_registered', coalesce(v_rc_age, 1e9) < 300 and coalesce((v_rc->>'rc_sessions')::int, 0) >= 1,
    'rc_sessions', v_rc->>'rc_sessions',
    -- With an empty queue there is nothing to claim, and calling that a failure
    -- would make the drill go red on every quiet night. It is reported as
    -- not-applicable and passes, with the count so the report is not a mystery.
    'claimed', v_claimed or v_pending = 0,
    'claim_na', v_pending = 0,
    'pending', v_pending);

  v_secs := greatest(0, extract(epoch from (now() - v_boot))::int);
  if (v_checks->>'usage_fresh')::boolean
     and (v_checks->>'rc_registered')::boolean
     and (v_checks->>'claimed')::boolean then
    perform _ops_put('{cycle,phase}'::text[], '"green"'::jsonb);
    perform _ops_put('{cycle,checks}'::text[], v_checks);
    perform _ops_finish_cycle(c->>'reason', 'green',
      replace(_c_or('dev_queue.ops_drill_green','Drill green - back and claiming in {secs}s'),
              '{secs}', v_secs::text),
      c || jsonb_build_object('checks', v_checks, 'secs', v_secs));
    return jsonb_build_object('ok', true, 'phase', 'green', 'checks', v_checks);
  end if;

  -- Still short of the claim deadline? Keep waiting; only the deadline decides.
  if now() < v_boot + make_interval(secs => greatest(coalesce((o#>>'{drill,claim_within_s}')::int,120),30)) then
    perform _ops_put('{cycle,checks}'::text[], v_checks);
    return jsonb_build_object('ok', true, 'phase', 'booting', 'checks', v_checks);
  end if;

  v_fail := case
    when not (v_checks->>'usage_fresh')::boolean then 'usage did not sync after boot'
    when not (v_checks->>'rc_registered')::boolean then 'Remote Control did not register'
    else 'nothing claimed within the window' end;
  perform _ops_put('{cycle,phase}'::text[], '"red"'::jsonb);
  perform _ops_put('{cycle,checks}'::text[], v_checks);
  perform _ops_finish_cycle(c->>'reason', 'red', v_fail, c || jsonb_build_object('checks', v_checks));
  return jsonb_build_object('ok', true, 'phase', 'red', 'reason', v_fail, 'checks', v_checks);
exception when others then
  return jsonb_build_object('ok', false, 'reason', sqlerrm);
end $$;

-- What a finished cycle leaves behind: a permanent run row, and an alert when
-- it went red. Both callers land here, so a self-heal that fails is recorded
-- exactly like a drill that fails.
create or replace function public._ops_finish_cycle(
  p_reason text, p_status text, p_note text, p_evidence jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare h jsonb;
begin
  insert into ops_drill_run (runbook_key, status, summary, evidence, trigger)
  values ('runner_kill_vm_' || case when coalesce(p_reason,'drill') = 'selfheal' then 'selfheal' else 'drill' end,
          case when p_status = 'green' then 'passed' else 'failed' end,
          left(coalesce(p_note,''), 500), coalesce(p_evidence,'{}'::jsonb), 'cron');

  if p_status <> 'green' then
    begin
      insert into rg_alerts (fingerprint, severity, kind, name, detail)
      values ('c1368_cycle_red_' || coalesce(p_reason,'drill'), 'warn', 'runner',
              'Kill-VM ' || coalesce(p_reason,'drill') || ' went red — ' || left(coalesce(p_note,''),120),
              coalesce(p_evidence,'{}'::jsonb))
      on conflict (fingerprint) do update
        set last_seen = now(), seen_count = rg_alerts.seen_count + 1, detail = excluded.detail;
    exception when others then null;
    end;
  end if;

  if coalesce(p_reason,'') = 'selfheal' then
    h := runner_ops_health();
    if p_status <> 'green' or coalesce((h->>'reds')::int,0) > 0 then
      perform runner_ops_alert('ops_selfheal_failed', jsonb_build_object(
        'agent', coalesce(nullif(h->>'agent',''), 'the builder'),
        'reds', coalesce(h->>'reds_label', h->>'reds', '?'),
        'reason', left(coalesce(p_note,''), 160)));
    end if;
  elsif p_status <> 'green' then
    perform runner_ops_alert('ops_selfheal_failed', jsonb_build_object(
      'agent', 'nightly drill', 'reds', '0', 'reason', left(coalesce(p_note,''), 160)));
  end if;

  -- A CYCLE THAT WENT RED MUST NOT LEAVE THE BOX DELIBERATELY OFF. The whole
  -- machine starts by writing desired_state.vm='off'; if it then times out in
  -- `stopping` or `starting`, that 'off' is still standing and the builder stays
  -- down all night with the queue stacking up behind it. So the last thing a
  -- red cycle does is ask for the box back — the toggle AND the cloud call,
  -- because either one alone has a failure mode the other covers.
  if p_status <> 'green' then
    update dev_runner_config
       set value = jsonb_set(value, '{vm}', '"on"'::jsonb) where key = 'desired_state';
    perform _ops_vm_call('start');
  end if;

  perform _ops_put('{cycle,finished_at}'::text[], to_jsonb(now()::text));
end $$;

-- ── 13. the tick ───────────────────────────────────────────────────────────
-- One minute, one function, on the cron DISPATCHER (never a bare */N schedule —
-- the 18 Aug outage was 35 jobs all starting on minute 0). It runs in the
-- database precisely so that it keeps running while the box it manages is off.
create or replace function public.runner_ops_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare o jsonb; u jsonb; h jsonb; p jsonb; wp jsonb;
        v_build int; v_did jsonb := '[]'::jsonb; v_pct numeric; v_win text;
        v_today date; v_at time; v_cycle text;
begin
  o := _ops_cfg();
  v_cycle := coalesce(o#>>'{cycle,phase}', 'idle');

  -- (a) DRAIN COMPLETE. Fired once, by the flag, so a drain that stays on for a
  -- day does not alert every minute.
  if coalesce((o#>>'{drain,on}')::boolean,false)
     and not coalesce((o#>>'{drain,alerted}')::boolean,false) then
    select count(*) into v_build from dev_commands where status = 'building';
    if v_build = 0 then
      perform _ops_put('{drain,alerted}'::text[], 'true'::jsonb);
      perform runner_ops_alert('ops_drain_complete', jsonb_build_object(
        'reason', coalesce(o#>>'{drain,reason}',''),
        'at', to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST'));
      v_did := v_did || '["drain_complete"]'::jsonb;
    end if;
  end if;

  -- (b) USAGE AT THE ALERT LINE, and the optional switch to api billing.
  begin u := dev_cmd_session_usage(); exception when others then u := '{}'::jsonb; end;
  if not coalesce((u->>'quota_unknown')::boolean, true) then
    v_pct := coalesce((u->>'quota_pct')::numeric, 0);
    v_win := case when coalesce((u->>'quota_weekly_pct')::numeric,0)
                     >= coalesce((u->>'quota_session_pct')::numeric,0)
                  then 'weekly' else '5h' end;
    if v_pct >= coalesce((o#>>'{alerts,usage_pct}')::numeric, 90) then
      perform runner_ops_alert('ops_usage_cap', jsonb_build_object(
        'pct', v_pct::int || '%', 'window', v_win,
        'resets', coalesce((select l->>'resets_display' from jsonb_array_elements(u->'limits') l
                             where coalesce((l->>'active')::boolean,false) limit 1), 'soon')));
      v_did := v_did || '["usage_alert"]'::jsonb;
    end if;

    -- PIN-set option: only ever true because somebody turned it on behind the
    -- safety PIN, so this can never surprise a bill into existence by default.
    if coalesce((o#>>'{pace,api_switch}')::boolean, false)
       and v_pct >= coalesce((o#>>'{pace,api_switch_pct}')::numeric, 95) then
      select value into wp from dev_runner_config where key='worker_pool';
      if coalesce(wp->>'billing_mode','max_subscription') <> 'api' then
        update dev_runner_config
           set value = jsonb_set(value, '{billing_mode}', '"api"'::jsonb)
         where key = 'worker_pool';
        perform _audit('runner','ops_billing_api', null,
                       jsonb_build_object('pct', v_pct, 'window', v_win));
        v_did := v_did || '["billing_api"]'::jsonb;
      end if;
    end if;
  end if;

  -- (c) the power cycle, if one is in flight.
  if v_cycle not in ('idle','green','red') then
    perform runner_ops_cycle_step();
    v_did := v_did || '["cycle_step"]'::jsonb;
    return jsonb_build_object('ok', true, 'did', v_did, 'phase', _ops_cfg()#>>'{cycle,phase}');
  end if;

  -- (d) SELF-HEAL. Reds are derived, the cooldown stops a reboot loop, and a
  -- box with work in flight is left alone — a reboot that throws away a build
  -- is not a repair.
  h := runner_ops_health();
  if coalesce((h->>'enabled')::boolean, true)
     and coalesce((h->>'reds')::int, 0) >= coalesce((h->>'threshold')::int, 2)
     and coalesce(nullif(o#>>'{selfheal,last_at}','')::timestamptz, 'epoch'::timestamptz) <
         now() - make_interval(mins => greatest(coalesce((o#>>'{selfheal,cooldown_min}')::int,60),10))
  then
    select count(*) into v_build from dev_commands where status = 'building';
    if v_build = 0 then
      perform _ops_put('{selfheal,last_at}'::text[], to_jsonb(now()::text));
      perform runner_ops_cycle_start('selfheal');
      v_did := v_did || '["selfheal_reboot"]'::jsonb;
      return jsonb_build_object('ok', true, 'did', v_did, 'health', h);
    end if;
  end if;

  -- (e) ARM THE NIGHTLY DRILL. Once per IST day, inside a five-minute window
  -- after the configured time so a skipped dispatcher tick does not skip the
  -- night, and never while anything is building.
  if coalesce((o#>>'{drill,enabled}')::boolean, true) then
    v_today := (now() at time zone 'Asia/Kolkata')::date;
    begin v_at := coalesce(o#>>'{drill,at_ist}','03:10')::time;
    exception when others then v_at := '03:10'::time; end;
    if coalesce(o#>>'{drill,last_on}','') <> v_today::text
       and (now() at time zone 'Asia/Kolkata')::time >= v_at
       and (now() at time zone 'Asia/Kolkata')::time < v_at + interval '5 minutes' then
      select count(*) into v_build from dev_commands where status = 'building';
      if v_build = 0 then
        perform _ops_put('{drill,last_on}'::text[], to_jsonb(v_today::text));
        perform runner_ops_cycle_start('drill');
        v_did := v_did || '["drill_start"]'::jsonb;
      end if;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'did', v_did);
exception when others then
  return jsonb_build_object('ok', false, 'reason', sqlerrm);
end $$;

-- ── 14. the card ───────────────────────────────────────────────────────────
-- Every string, every tone, every state word is built here. The widget prints
-- the list in payload order and computes nothing — including the ON/OFF words.
create or replace function public.runner_ops_card()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o jsonb; g jsonb; s jsonb; p jsonb; h jsonb; c jsonb;
        v_rows jsonb := '[]'::jsonb; v_build int; v_drill jsonb; v_last record;
        v_on text; v_off text;
begin
  perform _dev_guard();
  o := _ops_cfg();
  g := runner_ops_gate(null);
  s := runner_ops_semaphore();
  p := runner_ops_pace();
  h := runner_ops_health();
  c := coalesce(o->'cycle','{}'::jsonb);
  select count(*) into v_build from dev_commands where status = 'building';
  v_on  := _c_or('dev_queue.ops_on','On');
  v_off := _c_or('dev_queue.ops_off','Off');

  -- drain
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','drain', 'label', _c_or('dev_queue.ops_drain','Drain'),
    'sub', _c_or('dev_queue.ops_drain_sub',''),
    'on', coalesce((o#>>'{drain,on}')::boolean,false),
    'can_toggle', true,
    'state_label', case when not coalesce((o#>>'{drain,on}')::boolean,false) then v_off
      when v_build = 0 then _c_or('dev_queue.ops_drain_done','Drained. Nothing is building.')
      else replace(_c_or('dev_queue.ops_drain_on','Draining - {n} still building'), '{n}', v_build::text) end,
    'state_tone', case when not coalesce((o#>>'{drain,on}')::boolean,false) then 'neutral'
      when v_build = 0 then 'success' else 'warning' end));

  -- build hours
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','hours', 'label', _c_or('dev_queue.ops_hours','Build hours'),
    'sub', replace(replace(_c_or('dev_queue.ops_hours_sub',''),
             '{from}', coalesce(o#>>'{hours,from}','')), '{to}', coalesce(o#>>'{hours,to}','')),
    'on', coalesce((o#>>'{hours,enabled}')::boolean,false),
    'can_toggle', true,
    'state_label', case when not coalesce((o#>>'{hours,enabled}')::boolean,false) then v_off
      when _ops_in_window(o#>>'{hours,from}', o#>>'{hours,to}') then v_on
      else replace(replace(replace(_c_or('dev_queue.ops_hours_block',''),
             '{from}', coalesce(o#>>'{hours,from}','')), '{to}', coalesce(o#>>'{hours,to}','')),
             '{in}', _ops_dur(_ops_until_window(o#>>'{hours,from}'))) end,
    'state_tone', case when not coalesce((o#>>'{hours,enabled}')::boolean,false) then 'neutral'
      when _ops_in_window(o#>>'{hours,from}', o#>>'{hours,to}') then 'success' else 'warning' end));

  -- pacing
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','pace', 'label', _c_or('dev_queue.ops_pace','Quota pacing'),
    'sub', _c_or('dev_queue.ops_pace_sub',''),
    'on', coalesce((o#>>'{pace,enabled}')::boolean,true),
    'can_toggle', true,
    'state_label', case
      when not coalesce((o#>>'{pace,enabled}')::boolean,true) then v_off
      when not coalesce((p->>'known')::boolean,false) then _c_or('dev_queue.ops_pace_unknown','')
      when coalesce((p->>'ahead_pct')::numeric,0) > coalesce((o#>>'{pace,slack_pct}')::numeric,12)
        then replace(replace(_c_or('dev_queue.ops_pace_ahead',''),
               '{pct}', (p->>'ahead_pct')||'%'), '{window}', coalesce(p->>'window',''))
      else replace(replace(_c_or('dev_queue.ops_pace_ok',''),
             '{w}', coalesce((p->>'weekly_pct')::numeric,0)::int||'%'),
             '{s}', coalesce((p->>'session_pct')::numeric,0)::int||'%') end,
    'state_tone', case
      when not coalesce((o#>>'{pace,enabled}')::boolean,true) then 'neutral'
      when not coalesce((p->>'known')::boolean,false) then 'neutral'
      when coalesce((p->>'ahead_pct')::numeric,0) > coalesce((o#>>'{pace,slack_pct}')::numeric,12)
        then 'warning' else 'success' end));

  -- boost
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','boost', 'label', _c_or('dev_queue.ops_boost','Boost'),
    'sub', replace(_c_or('dev_queue.ops_boost_sub',''),
             '{n}', greatest(coalesce((s->>'boost_workers')::int,0),2)::text),
    'on', coalesce((s->>'boost_left_s')::int,0) > 0,
    'can_toggle', false, 'action', 'boost',
    'action_label', _c_or('dev_queue.ops_boost_do','Boost'),
    'state_label', case when coalesce((s->>'boost_left_s')::int,0) > 0
      then replace(replace(_c_or('dev_queue.ops_boost_on',''),
             '{n}', coalesce(s->>'boost_workers','0')), '{in}', _ops_dur((s->>'boost_left_s')::int))
      else _c_or('dev_queue.ops_boost_off','Boost off') end,
    'state_tone', case when coalesce((s->>'boost_left_s')::int,0) > 0 then 'info' else 'neutral' end));

  -- peak throttle
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','peak', 'label', _c_or('dev_queue.ops_peak','Peak-hours throttle'),
    'sub', replace(_c_or('dev_queue.ops_peak_sub',''),
             '{n}', coalesce(o#>>'{peak,semaphore}','1')),
    'on', coalesce((o#>>'{peak,enabled}')::boolean,true),
    'can_toggle', true,
    'state_label', case when not coalesce((o#>>'{peak,enabled}')::boolean,true) then v_off
      when coalesce((s->>'peak_open')::boolean,false)
        then replace(_c_or('dev_queue.ops_peak_on',''), '{n}', coalesce(s->>'effective','1'))
      else v_on end,
    'state_tone', case when not coalesce((o#>>'{peak,enabled}')::boolean,true) then 'neutral'
      when coalesce((s->>'peak_open')::boolean,false) then 'info' else 'success' end));

  -- safe night mode
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','safe', 'label', _c_or('dev_queue.ops_safe','Safe night mode'),
    'sub', replace(replace(_c_or('dev_queue.ops_safe_sub',''),
             '{from}', coalesce(o#>>'{safe,from}','')), '{to}', coalesce(o#>>'{safe,to}','')),
    'on', coalesce((o#>>'{safe,enabled}')::boolean,true),
    'can_toggle', true,
    'state_label', case when not coalesce((o#>>'{safe,enabled}')::boolean,true) then v_off
      when _ops_in_window(o#>>'{safe,from}', o#>>'{safe,to}')
        then replace(replace(replace(_c_or('dev_queue.ops_safe_block',''),
               '{from}', coalesce(o#>>'{safe,from}','')), '{to}', coalesce(o#>>'{safe,to}','')),
               '{what}', _c_or('dev_queue.ops_safe_danger','risky work'))
      else v_on end,
    'state_tone', case when not coalesce((o#>>'{safe,enabled}')::boolean,true) then 'neutral'
      when _ops_in_window(o#>>'{safe,from}', o#>>'{safe,to}') then 'info' else 'success' end));

  -- self-heal
  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','selfheal', 'label', _c_or('dev_queue.ops_selfheal','Self-heal'),
    'sub', replace(_c_or('dev_queue.ops_selfheal_sub',''), '{n}', coalesce(h->>'threshold','2')),
    'on', coalesce((h->>'enabled')::boolean,true),
    'can_toggle', true,
    'state_label', case when not coalesce((h->>'enabled')::boolean,true) then v_off
      when coalesce((h->>'reds')::int,0) = 0 then v_on
      when coalesce((h->>'reds')::int,0) < coalesce((h->>'threshold')::int,2)
        then replace(replace(_c_or('dev_queue.ops_selfheal_watch',''),
               '{agent}', coalesce(nullif(h->>'agent',''),'the builder')),
               '{n}', coalesce(h->>'reds_label','')) 
      else replace(replace(_c_or('dev_queue.ops_selfheal_fired',''),
             '{agent}', coalesce(nullif(h->>'agent',''),'the builder')),
             '{n}', coalesce(h->>'reds_label','')) end,
    'state_tone', case when not coalesce((h->>'enabled')::boolean,true) then 'neutral'
      when coalesce((h->>'reds')::int,0) = 0 then 'success'
      when coalesce((h->>'reds')::int,0) < coalesce((h->>'threshold')::int,2) then 'warning'
      else 'danger' end));

  -- nightly drill
  select status, summary, ran_at into v_last
    from ops_drill_run where runbook_key like 'runner_kill_vm_%'
   order by ran_at desc limit 1;
  v_drill := jsonb_build_object(
    'key','drill', 'label', _c_or('dev_queue.ops_drill','Nightly kill-VM drill'),
    'sub', replace(_c_or('dev_queue.ops_drill_sub',''), '{at}', coalesce(o#>>'{drill,at_ist}','03:10')),
    'on', coalesce((o#>>'{drill,enabled}')::boolean,true),
    'can_toggle', true, 'action', 'drill_now',
    'action_label', _c_or('dev_queue.ops_drill_do','Run it now'),
    'state_label', case
      when coalesce(o#>>'{cycle,phase}','idle') not in ('idle','green','red')
        then replace(_c_or('dev_queue.ops_drill_running',''), '{phase}', coalesce(o#>>'{cycle,phase}',''))
      when v_last.status is null then _c_or('dev_queue.ops_drill_never','Not run yet')
      when v_last.status = 'passed' then coalesce(v_last.summary,'')
      else replace(_c_or('dev_queue.ops_drill_red',''), '{reason}', coalesce(v_last.summary,'')) end,
    'state_tone', case
      when coalesce(o#>>'{cycle,phase}','idle') not in ('idle','green','red') then 'info'
      when v_last.status is null then 'neutral'
      when v_last.status = 'passed' then 'success' else 'danger' end);
  v_rows := v_rows || jsonb_build_array(v_drill);

  return jsonb_build_object(
    'has', true,
    'title', _c_or('dev_queue.ops_title','Runner policies'),
    'headline', case when coalesce((g->>'block')::boolean,false)
      then replace(_c_or('dev_queue.ops_holding','Holding: {reason}'), '{reason}', coalesce(g->>'reason',''))
      else _c_or('dev_queue.ops_all_clear','No policy is holding the queue.') end,
    'tone', case when coalesce((g->>'block')::boolean,false) then 'warning' else 'success' end,
    'policies', v_rows,
    'workers_label', 'Workers ' || coalesce(s->>'effective','?') || ' / ' || coalesce(s->>'base','?'),
    'gate', g, 'semaphore', s, 'pace', p, 'cycle', c,
    'zone', admin_active_zone(), 'date', admin_active_date());
end $$;

-- ── 15. the claim path ─────────────────────────────────────────────────────
-- The one edit that makes any of this real. Fleet gate before the scan, row
-- gate inside it — and the row gate takes the columns it judges rather than an
-- id, so a queue of 200 pending rows is still one pass.
create or replace function public.dev_cmd_claim(
  p_agent text, p_routes text[] default null, p_prefer_area text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_hold bigint; v_hold_t text; v jsonb; v_res jsonb; v_blocked int; v_adm jsonb; v_scope jsonb;
        v_fact boolean; v_msg text; v_auth jsonb; v_sick jsonb; v_ops jsonb;
BEGIN
  PERFORM _dev_guard();

  -- CHANGE #1268 — ONE RUNNER, ONE BUILDING COMMAND.
  SELECT dc.id, dc.title INTO v_hold, v_hold_t
    FROM dev_commands dc WHERE dc.claimed_by = p_agent AND dc.status = 'building'
    ORDER BY dc.started_at LIMIT 1;
  IF v_hold IS NOT NULL THEN
    RETURN jsonb_build_object('empty', true, 'busy', true, 'holding', v_hold,
      'label', 'Already building #' || v_hold,
      'detail', coalesce(v_hold_t,''),
      'next_step', 'Finish #' || v_hold || ' with complete/fail/ask, or release it, then claim again.');
  END IF;
  IF (_sec_cfg()->>'frozen')::boolean THEN RETURN jsonb_build_object('empty',true,'frozen',true); END IF;
  IF (sec_check_budget()->>'over')::boolean THEN RETURN jsonb_build_object('empty',true,'budget_paused',true); END IF;

  -- CHANGE #1369 — a box that cannot start Claude must not be handed work.
  v_auth := claude_auth_gate(NULL);
  IF coalesce((v_auth->>'blocked')::boolean, false) THEN
    RETURN jsonb_build_object('empty', true, 'claude_blocked', true,
      'retry_after_seconds', 120,
      'reason', v_auth->>'reason', 'claude_auth', v_auth);
  END IF;
  v_sick := runner_sick_get(p_agent);
  IF coalesce((v_sick->>'sick')::boolean, false) THEN
    RETURN jsonb_build_object('empty', true, 'runner_sick', true,
      'retry_after_seconds', 120,
      'reason', _c_or('dev_queue.claim_blocked_sick',
                      'This runner could not start a Claude session on its last try, so it is not claiming.'),
      'runner_sick', v_sick);
  END IF;

  -- CHANGE #1368 — the ops policies: drain, build hours, quota pacing. Fails
  -- OPEN by construction (runner_ops_gate swallows its own errors), so a broken
  -- policy layer can never be the reason the fleet stopped.
  v_ops := runner_ops_gate(p_agent);
  IF coalesce((v_ops->>'block')::boolean, false) THEN
    RETURN jsonb_build_object('empty', true, 'ops_blocked', true,
      'policy', v_ops->>'policy',
      'retry_after_seconds', coalesce((v_ops->>'retry_after_seconds')::int, 300),
      'reason', v_ops->>'reason', 'ops', v_ops);
  END IF;

  -- CMD #368 — admission control.
  v_adm := db_admission_check(p_agent);
  IF coalesce((v_adm->>'admit')::boolean, true) = false THEN
    RETURN jsonb_build_object('empty', true, 'db_busy', true,
      'retry_after_seconds', coalesce((v_adm->>'retry_after_seconds')::int, 45),
      'reason', v_adm->>'label', 'admission', v_adm);
  END IF;

  SELECT coalesce((value->'chain'->>'require_lease')::boolean, true) INTO v_fact
    FROM dev_runner_config WHERE key='worker_pool';
  v_fact := coalesce(v_fact, true);

  UPDATE dev_commands dc SET status='building', claimed_by=p_agent, claim_session_id=(SELECT s.session_id FROM dev_agent_session s WHERE s.agent=p_agent AND s.released_at IS NULL ORDER BY s.registered_at DESC LIMIT 1), started_at=now(), heartbeat_at=now(),
         resume_count = resume_count + CASE WHEN dc.steps_done > 0 THEN 1 ELSE 0 END,
         agent_alive_at = NULL, agent_pane_alive = NULL, agent_rc_session = NULL,
         agent_silent_flagged = false, agent_silent_at = NULL
  WHERE dc.id = (
    SELECT c.id FROM dev_commands c
    WHERE c.status='pending'
      AND (p_routes IS NULL OR c.route = ANY(p_routes))
      AND NOT runner_ops_row_blocked(c.id, c.is_danger, c.targets_android, c.predicted_files)
      AND NOT EXISTS (SELECT 1 FROM dev_commands d WHERE d.id = ANY(c.depends_on) AND d.status <> 'completed')
      AND NOT EXISTS (
        SELECT 1 FROM dev_commands b
        WHERE b.status = 'building' AND b.id <> c.id
          AND coalesce(array_length(
                dev_paths_conflict(
                  CASE WHEN v_fact THEN dev_cmd_leased_footprint(b.id)
                       ELSE dev_cmd_footprint(b.id) END,
                  c.predicted_files), 1), 0) > 0)
    ORDER BY c.urgent DESC,
             (p_prefer_area IS NOT NULL AND c.area IS NOT DISTINCT FROM p_prefer_area) DESC,
             c.priority, c.id
    FOR UPDATE OF c SKIP LOCKED LIMIT 1
  )
  RETURNING to_jsonb(dc) INTO v;
  IF v IS NULL THEN
    SELECT count(*) INTO v_blocked FROM dev_commands c
     WHERE c.status='pending' AND (p_routes IS NULL OR c.route = ANY(p_routes));
    -- A row held by a POLICY says so in the policy's own words: "every pending
    -- command is behind a file lease" was the only sentence available before,
    -- and it would have been a lie every night that safe mode held a migration.
    SELECT runner_ops_row_reason(c.id) INTO v_msg FROM dev_commands c
     WHERE c.status='pending' AND (p_routes IS NULL OR c.route = ANY(p_routes))
       AND runner_ops_row_blocked(c.id, c.is_danger, c.targets_android, c.predicted_files)
     ORDER BY c.urgent DESC, c.priority, c.id LIMIT 1;
    IF coalesce(v_msg,'') = '' THEN
      SELECT value#>>'{}' INTO v_msg FROM ui_copy
       WHERE key = CASE WHEN v_blocked > 0 THEN 'dev_queue.claim_blocked' ELSE 'dev_queue.claim_empty' END;
    END IF;
    RETURN jsonb_build_object('empty', true, 'pending_blocked', v_blocked,
      'reason', coalesce(v_msg, CASE WHEN v_blocked > 0
        THEN 'Every pending command is held behind a file another build is holding right now.'
        ELSE 'Queue empty.' END));
  END IF;
  v_res := _dev_resume_block(v);
  v_scope := dev_qa_scope((v->>'id')::bigint);
  RETURN v || jsonb_build_object('resume', v_res,
                                 'is_resume', coalesce((v_res->>'is_resume')::boolean, false),
                                 'qa_scope', v_scope,
                                 'session_guard', db_guard_check(), 'run_flags', dev_cmd_run_flags(v->>'model', v->>'effort'));
END $$;

-- The batch path inherits the fleet gate (it calls dev_cmd_claim for its first
-- row) but picked its SIBLINGS with a separate query — a hole that would have
-- let safe night mode hold a migration and then hand out three more beside it.
create or replace function public.dev_cmd_claim_batch(
  p_agent text, p_routes text[] default null, p_prefer_area text default null,
  p_max int default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE
  v_first jsonb; v_id bigint; v_area text; v_size text; v_route text;
  v_max int; v_label text; v_rows jsonb := '[]'; v_extra jsonb;
BEGIN
  v_first := dev_cmd_claim(p_agent, p_routes, p_prefer_area);
  IF coalesce((v_first->>'empty')::boolean,false) THEN RETURN v_first; END IF;

  v_id   := (v_first->>'id')::bigint;
  v_area := v_first->>'area';
  v_size := coalesce(v_first->>'size_class','normal');
  v_route:= coalesce(v_first->>'route','opus');
  v_rows := jsonb_build_array(v_first);

  SELECT coalesce(p_max, (value->>'batch_max')::int, 4) INTO v_max
    FROM dev_runner_config WHERE key='worker_pool';
  v_max := greatest(coalesce(v_max,4), 1);

  IF v_size <> 'small' OR v_max < 2 OR v_area IS NULL THEN
    RETURN jsonb_build_object('batch', false, 'count', 1, 'rows', v_rows, 'first', v_first);
  END IF;

  v_label := 'batch-'||v_id;

  WITH picked AS (
    SELECT c.id FROM dev_commands c
     WHERE c.status='pending'
       AND c.area IS NOT DISTINCT FROM v_area
       AND coalesce(c.size_class,'normal') = 'small'
       AND coalesce(c.kind,'dev') = 'dev'
       AND coalesce(c.is_danger,false) = false
       AND coalesce(c.route,'opus') = v_route
       AND (p_routes IS NULL OR c.route = ANY(p_routes))
       AND NOT runner_ops_row_blocked(c.id, c.is_danger, c.targets_android, c.predicted_files)
       AND coalesce(array_length(c.depends_on,1),0) = 0
       AND NOT EXISTS (SELECT 1 FROM dev_commands d
                        WHERE d.depends_on @> ARRAY[c.id] AND d.status <> 'completed')
     ORDER BY c.urgent DESC, c.priority, c.id
     FOR UPDATE OF c SKIP LOCKED
     LIMIT (v_max - 1)
  ), upd AS (
    UPDATE dev_commands dc
       SET status='building', claimed_by=p_agent, started_at=now(),
           heartbeat_at=now(), batch_label=v_label,
           resume_count = dc.resume_count + CASE WHEN dc.steps_done > 0 THEN 1 ELSE 0 END
     WHERE dc.id IN (SELECT id FROM picked)
    RETURNING to_jsonb(dc) AS row
  )
  SELECT coalesce(jsonb_agg(
           (row || jsonb_build_object('resume', _dev_resume_block(row),
                                      'is_resume', coalesce((_dev_resume_block(row)->>'is_resume')::boolean,false)))
           ORDER BY (row->>'id')::bigint), '[]'::jsonb) INTO v_extra FROM upd;

  IF jsonb_array_length(v_extra) > 0 THEN
    UPDATE dev_commands SET batch_label = v_label WHERE id = v_id;
    v_rows := v_rows || v_extra;
  END IF;

  RETURN jsonb_build_object(
    'batch', jsonb_array_length(v_rows) > 1,
    'batch_label', v_label,
    'count', jsonb_array_length(v_rows),
    'area', v_area,
    'note', 'Build each row in order in ONE context, then ship all of them through a single deploy-lane pass. Complete every row separately — a failure fails only its own row.',
    'ids', (SELECT jsonb_agg((x->>'id')::bigint) FROM jsonb_array_elements(v_rows) x),
    'rows', v_rows,
    'first', v_first);
END $$;

-- ── 16. the schedule ───────────────────────────────────────────────────────
-- On the ONE dispatcher (CHANGE #273), never a bare cron schedule. The gate is
-- deliberately loose: this tick must keep running while the VM is OFF, because
-- half of what it does is bring the VM back.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled,
                              base_interval_s, max_interval_s, step_timeout_ms,
                              dml, budget_exempt, note)
values ('runner_ops_tick', 4, 'poll',
        'select true',
        'select public.runner_ops_tick()',
        true, 60, 60, 9000, true, true,
        'CHANGE #1368 — runner ops policies: drain-complete alert, usage alert + api switch, the VM power-cycle state machine (self-heal and the nightly kill-VM drill), and arming that drill. Runs in the DATABASE on purpose: for most of a drill the box it manages is powered off.')
on conflict (name) do update set
  work_sql = excluded.work_sql, gate_sql = excluded.gate_sql,
  base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
  enabled = excluded.enabled, budget_exempt = excluded.budget_exempt, note = excluded.note;

-- Seed the policy block so Pool settings has something to render on day one.
update public.dev_runner_config
   set value = jsonb_set(value, '{ops}', coalesce(value->'ops','{}'::jsonb), true)
 where key = 'worker_pool';

grant execute on function public.runner_ops_card() to authenticated;
grant execute on function public.runner_ops_set(jsonb, text) to authenticated;
grant execute on function public.runner_ops_drain_set(boolean, text) to authenticated;
grant execute on function public.runner_ops_boost(int, int) to authenticated;
grant execute on function public.runner_ops_cycle_start(text) to authenticated;
