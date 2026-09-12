-- CHANGE #1369 — Claude login expiry can never churn the queue.
--
-- 5 Sep: the VM's Claude Code login expired. `claude --version` still answered
-- (2.1.261) so every check the boot doctor ran was green, but every session
-- died the instant it started: the runner claimed, posted "started
-- (remote-control)", dev_agent_session came back with a NULL pid, 0 tokens were
-- ever spent, the 5-minute liveness sweep released the row as "Worker went
-- silent", and the loop claimed it straight back. 28 claims in 40 minutes on
-- #1362 / #1354 / #1366, and nothing in the fleet could tell Om WHY.
--
-- This is the permanent layer, in four parts:
--   1. dev_claude_auth  — the doctor's verdict for a host, plus token expiry,
--                         plus the phone re-login handshake. One row per host.
--   2. claude_auth_*    — report / status / gate / re-login RPCs. Every string
--                         the card prints is built here (ui_copy), never in Dart.
--   3. churn breaker    — a row released twice inside the window having spent
--                         ZERO tokens is not re-handed: it parks as needs_input
--                         with kind 'infra', the fleet pauses, one alert fires,
--                         and the auto-resolver is taught to never answer it.
--   4. claim gate       — dev_cmd_claim refuses while a FRESH red report stands.
--                         Absent or stale reports never block: a dead reporter
--                         must not brick the fleet.

-- ── 1. the table ────────────────────────────────────────────────────────────
create table if not exists public.dev_claude_auth (
  host                 text primary key,
  agent                text,
  checked_at           timestamptz,
  cli_version          text,
  auth_ok              boolean     not null default false,
  smoke_ok             boolean     not null default false,
  expires_at           timestamptz,
  detail               text        not null default '',
  blocked              boolean     not null default false,
  alert_bucket         text,
  alerted_at           timestamptz,
  relogin_state        text        not null default 'idle',
  relogin_url          text,
  relogin_code         text,
  relogin_message      text        not null default '',
  relogin_requested_at timestamptz,
  relogin_updated_at   timestamptz,
  updated_at           timestamptz not null default now()
);
alter table public.dev_claude_auth enable row level security;

-- ── churn-breaker bookkeeping, on the row that churns ───────────────────────
alter table public.dev_commands
  add column if not exists zero_release_count int not null default 0,
  add column if not exists zero_release_first_at timestamptz,
  add column if not exists churn_parked_at timestamptz;

-- ── config: every threshold is a knob, so tuning is pool_set, not a deploy ──
update public.dev_runner_config
   set value = jsonb_set(value, '{claude_auth}',
         coalesce(value->'claude_auth', '{}'::jsonb) || jsonb_build_object(
           'enabled',          true,
           'block_claims',     true,
           'stale_min',        30,     -- a report older than this never blocks
           'warn_days',        jsonb_build_array(3, 1),
           'churn_max',        2,      -- 0-token releases before the breaker
           'churn_window_min', 15,
           'pause_fleet',      true,
           'launch_gate_s',    90))
 where key = 'worker_pool';

-- ── every string the card prints ────────────────────────────────────────────
insert into public.ui_copy (key, value) values
 ('dev_queue.claude_auth_title',        '"Claude login"'::jsonb),
 ('dev_queue.claude_auth_ok',           '"Signed in"'::jsonb),
 ('dev_queue.claude_auth_blocked',      '"Runners blocked: Claude login expired"'::jsonb),
 ('dev_queue.claude_auth_blocked_sub',  '"No worker can start a session, so nothing is being claimed. Re-login below to bring the fleet back."'::jsonb),
 ('dev_queue.claude_auth_smoke_bad',    '"Runners blocked: Claude does not answer"'::jsonb),
 ('dev_queue.claude_auth_smoke_sub',    '"The CLI is installed and logged in but a test prompt returned nothing. The doctor will retry; re-login if it stays red."'::jsonb),
 ('dev_queue.claude_auth_expiring',     '"Claude login expires in {days}"'::jsonb),
 ('dev_queue.claude_auth_expiring_sub', '"Re-login before it lapses — an expired login stops every runner."'::jsonb),
 ('dev_queue.claude_auth_expired',      '"Claude login has expired"'::jsonb),
 ('dev_queue.claude_auth_stale',        '"No login check for {age}"'::jsonb),
 ('dev_queue.claude_auth_stale_sub',    '"The doctor has not reported on this host recently. Claims are still allowed."'::jsonb),
 ('dev_queue.claude_auth_checked',      '"Checked {age} ago on {host}"'::jsonb),
 ('dev_queue.claude_auth_never',        '"Never checked"'::jsonb),
 ('dev_queue.claude_auth_relogin',      '"Re-login from here"'::jsonb),
 ('dev_queue.claude_auth_relogin_wait', '"Starting login on the VM…"'::jsonb),
 ('dev_queue.claude_auth_relogin_url',  '"Open this link, then enter the code"'::jsonb),
 ('dev_queue.claude_auth_relogin_done', '"Signed in — runners released"'::jsonb),
 ('dev_queue.claude_auth_relogin_fail', '"Login could not be started on the VM"'::jsonb),
 ('dev_queue.claude_auth_relogin_hint', '"The VM starts the login and posts the link and code here within a minute."'::jsonb),
 ('dev_queue.claude_auth_version',      '"CLI {version}"'::jsonb),
 ('dev_queue.claude_auth_churn',        '"Runner cannot start Claude"'::jsonb),
 ('dev_queue.claude_auth_churn_q',      '"#{id} was handed out {n} times in {mins} minutes and spent zero tokens every time — the worker cannot start a Claude session. The queue is paused and this row is held here on purpose. Fix the login on the VM (Runner card → Re-login), then reply resume."'::jsonb),
 ('dev_queue.claude_auth_churn_msg',    '"⛔ Churn breaker: released {n} times in {mins} min with 0 tokens. Not re-handed — the runner cannot start Claude."'::jsonb),
 ('dev_queue.claim_blocked_auth',       '"Claiming is paused: the Claude login on this host is expired or unusable."'::jsonb)
on conflict (key) do nothing;

insert into public.wa_event_routes (event_key, label, description, enabled, auto_manage, audience,
                                    push_title, push_body, dedupe_minutes)
values ('sec_claude_auth', 'Claude login problem',
        'The VM cannot start Claude sessions (login expired, unusable, or about to expire)',
        true, true, 'admin', 'Claude login problem', '{{reason}}', 60)
on conflict (event_key) do nothing;

-- ── 2. helpers ──────────────────────────────────────────────────────────────
create or replace function public._claude_auth_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce((select value->'claude_auth' from dev_runner_config where key='worker_pool'), '{}'::jsonb)
$$;

-- The one place a verdict becomes a bucket. 'red' outranks every expiry
-- bucket: a login that already fails is not "expiring in 3 days".
create or replace function public._claude_auth_bucket(r public.dev_claude_auth)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v_days numeric; v_warn jsonb; w int;
begin
  if r.host is null then return 'unknown'; end if;
  if not r.auth_ok then return 'red_auth'; end if;
  if not r.smoke_ok then return 'red_smoke'; end if;
  if r.expires_at is null then return 'ok'; end if;
  v_days := extract(epoch from (r.expires_at - now())) / 86400.0;
  if v_days <= 0 then return 'expired'; end if;
  v_warn := coalesce(_claude_auth_cfg()->'warn_days', jsonb_build_array(3,1));
  -- smallest configured threshold the remaining time has fallen under
  select min((x)::int) into w from jsonb_array_elements_text(v_warn) t(x)
   where v_days <= (x)::numeric;
  if w is null then return 'ok'; end if;
  return 'warn_' || w || 'd';
end $$;

create or replace function public._claude_auth_host()
returns text language sql stable security definer set search_path to 'public' as $$
  select host from dev_claude_auth order by checked_at desc nulls last limit 1
$$;

-- ── 3. the doctor writes here ───────────────────────────────────────────────
create or replace function public.claude_auth_report(
  p_host text, p_auth_ok boolean, p_smoke_ok boolean,
  p_cli_version text default null, p_expires_at timestamptz default null,
  p_detail text default '', p_agent text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.dev_claude_auth; v_bucket text; v_prev text; v_blocked boolean;
        v_reason text; v_alerted boolean := false;
begin
  perform _dev_guard();
  if coalesce(btrim(p_host),'') = '' then
    return jsonb_build_object('ok', false, 'error', 'host required');
  end if;

  select alert_bucket into v_prev from dev_claude_auth where host = p_host;
  v_blocked := not (coalesce(p_auth_ok,false) and coalesce(p_smoke_ok,false));

  insert into dev_claude_auth as d
    (host, agent, checked_at, cli_version, auth_ok, smoke_ok, expires_at, detail, blocked, updated_at)
  values (p_host, p_agent, now(), p_cli_version, coalesce(p_auth_ok,false),
          coalesce(p_smoke_ok,false), p_expires_at, coalesce(p_detail,''), v_blocked, now())
  on conflict (host) do update set
    agent       = coalesce(excluded.agent, d.agent),
    checked_at  = excluded.checked_at,
    cli_version = coalesce(excluded.cli_version, d.cli_version),
    auth_ok     = excluded.auth_ok,
    smoke_ok    = excluded.smoke_ok,
    -- a probe that could not read the expiry must not erase a known one
    expires_at  = coalesce(excluded.expires_at, d.expires_at),
    detail      = excluded.detail,
    blocked     = excluded.blocked,
    updated_at  = now()
  returning * into r;

  v_bucket := _claude_auth_bucket(r);

  -- A GREEN report clears the handshake: whatever Om started on his phone has
  -- landed, so the card stops offering a login that is no longer needed.
  if not v_blocked and r.relogin_state in ('requested','running','url_ready') then
    update dev_claude_auth set relogin_state = 'done',
           relogin_message = _c_or('dev_queue.claude_auth_relogin_done','Signed in — runners released'),
           relogin_updated_at = now()
     where host = p_host returning * into r;
  end if;

  -- ONE alert per bucket transition. A red login re-reported every 60 s must
  -- not become an alert every 60 s.
  if v_bucket <> 'ok' and v_bucket is distinct from v_prev then
    v_reason := case v_bucket
      when 'red_auth'  then _c_or('dev_queue.claude_auth_blocked','Runners blocked: Claude login expired')
      when 'red_smoke' then _c_or('dev_queue.claude_auth_smoke_bad','Runners blocked: Claude does not answer')
      when 'expired'   then _c_or('dev_queue.claude_auth_expired','Claude login has expired')
      else replace(_c_or('dev_queue.claude_auth_expiring','Claude login expires in {days}'),
                   '{days}', replace(v_bucket,'warn_','') ) end;
    perform wa_send_event('sec_claude_auth', null,
      jsonb_build_object('reason', v_reason, 'host', p_host,
                         'detail', left(coalesce(p_detail,''), 300)), null, null);
    insert into rg_alerts (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
    values ('claude_auth:'||p_host||':'||v_bucket,
            case when v_bucket like 'red_%' or v_bucket='expired' then 'critical' else 'warn' end,
            'claude_auth', v_reason,
            jsonb_build_object('host',p_host,'bucket',v_bucket,'detail',left(coalesce(p_detail,''),500)),
            now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
    v_alerted := true;
  end if;

  update dev_claude_auth
     set alert_bucket = v_bucket,
         alerted_at = case when v_alerted then now() else alerted_at end
   where host = p_host;

  return jsonb_build_object('ok', true, 'host', p_host, 'blocked', v_blocked,
                            'bucket', v_bucket, 'alerted', v_alerted);
exception when others then
  -- The doctor must never die because the alert path did. A report that could
  -- not be filed is a red check on the runner, not a crashed boot.
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;

-- ── the gate the claim path and the doctor both read ────────────────────────
-- Fail OPEN on absence and on staleness. The only thing that blocks a claim is
-- a report that is BOTH fresh and explicitly red.
create or replace function public.claude_auth_gate(p_host text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r public.dev_claude_auth; cfg jsonb; v_age numeric; v_stale boolean;
begin
  cfg := _claude_auth_cfg();
  select * into r from dev_claude_auth where host = coalesce(p_host, _claude_auth_host());
  if not found or r.checked_at is null then
    return jsonb_build_object('blocked', false, 'reason', '', 'known', false);
  end if;
  v_age := extract(epoch from (now() - r.checked_at)) / 60.0;
  v_stale := v_age > coalesce((cfg->>'stale_min')::numeric, 30);
  if v_stale or not coalesce((cfg->>'enabled')::boolean, true)
     or not coalesce((cfg->>'block_claims')::boolean, true) then
    return jsonb_build_object('blocked', false, 'reason', '', 'known', true,
                              'stale', v_stale, 'age_min', round(v_age));
  end if;
  return jsonb_build_object(
    'blocked', r.blocked, 'known', true, 'stale', false, 'age_min', round(v_age),
    'host', r.host, 'bucket', _claude_auth_bucket(r),
    'reason', case when r.blocked
      then _c_or('dev_queue.claim_blocked_auth',
                 'Claiming is paused: the Claude login on this host is expired or unusable.')
      else '' end);
end $$;

-- ── 4. the card. Every label, tone and sub-line is built HERE ───────────────
create or replace function public.claude_auth_status()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r public.dev_claude_auth; cfg jsonb; v_bucket text; v_age numeric;
        v_stale boolean; v_title text; v_sub text; v_tone text; v_days numeric;
        v_dlabel text; v_can boolean; v_state text; v_slabel text;
begin
  perform _dev_guard();
  cfg := _claude_auth_cfg();
  select * into r from dev_claude_auth where host = _claude_auth_host();

  if not found or r.checked_at is null then
    return jsonb_build_object('has', false, 'blocked', false,
      -- Zone/date live in the header picker and are echoed, never re-picked
      -- here: runner health is host-scoped infrastructure with no zone or day
      -- dimension to filter on.
      'zone', admin_active_zone(), 'date', admin_active_date());
  end if;

  v_bucket := _claude_auth_bucket(r);
  v_age    := extract(epoch from (now() - r.checked_at)) / 60.0;
  v_stale  := v_age > coalesce((cfg->>'stale_min')::numeric, 30);

  if v_bucket = 'red_auth' then
    v_title := _c_or('dev_queue.claude_auth_blocked','Runners blocked: Claude login expired');
    v_sub   := _c_or('dev_queue.claude_auth_blocked_sub','');
    v_tone  := 'danger';
  elsif v_bucket = 'red_smoke' then
    v_title := _c_or('dev_queue.claude_auth_smoke_bad','Runners blocked: Claude does not answer');
    v_sub   := _c_or('dev_queue.claude_auth_smoke_sub','');
    v_tone  := 'danger';
  elsif v_bucket = 'expired' then
    v_title := _c_or('dev_queue.claude_auth_expired','Claude login has expired');
    v_sub   := _c_or('dev_queue.claude_auth_blocked_sub','');
    v_tone  := 'danger';
  elsif v_bucket like 'warn_%' then
    v_days  := extract(epoch from (r.expires_at - now())) / 86400.0;
    v_dlabel := case when v_days < 1 then _fmt_dur(extract(epoch from (r.expires_at - now())))
                     else round(v_days)::text || ' days' end;
    v_title := replace(_c_or('dev_queue.claude_auth_expiring','Claude login expires in {days}'),
                       '{days}', v_dlabel);
    v_sub   := _c_or('dev_queue.claude_auth_expiring_sub','');
    v_tone  := 'warning';
  elsif v_stale then
    v_title := replace(_c_or('dev_queue.claude_auth_stale','No login check for {age}'),
                       '{age}', _fmt_dur(v_age * 60));
    v_sub   := _c_or('dev_queue.claude_auth_stale_sub','');
    v_tone  := 'warning';
  else
    v_title := _c_or('dev_queue.claude_auth_ok','Signed in');
    v_sub   := '';
    v_tone  := 'success';
  end if;

  v_state := r.relogin_state;
  v_slabel := case v_state
    when 'requested' then _c_or('dev_queue.claude_auth_relogin_wait','Starting login on the VM…')
    when 'running'   then _c_or('dev_queue.claude_auth_relogin_wait','Starting login on the VM…')
    when 'url_ready' then _c_or('dev_queue.claude_auth_relogin_url','Open this link, then enter the code')
    when 'done'      then _c_or('dev_queue.claude_auth_relogin_done','Signed in — runners released')
    when 'failed'    then _c_or('dev_queue.claude_auth_relogin_fail','Login could not be started on the VM')
    else '' end;
  -- Offer the button whenever a login would actually help, and while a
  -- handshake is already running keep it closed so a second tap cannot restart
  -- the VM's login mid-flow.
  v_can := (v_tone <> 'success') and v_state not in ('requested','running','url_ready');

  return jsonb_build_object(
    'has',      true,
    'host',     r.host,
    'blocked',  r.blocked,
    'bucket',   v_bucket,
    'tone',     v_tone,
    'title',    v_title,
    'sub',      v_sub,
    'checked',  replace(replace(_c_or('dev_queue.claude_auth_checked','Checked {age} ago on {host}'),
                  '{age}', _fmt_dur(v_age*60)), '{host}', r.host),
    'version',  case when coalesce(r.cli_version,'') = '' then ''
                     else replace(_c_or('dev_queue.claude_auth_version','CLI {version}'),
                                  '{version}', r.cli_version) end,
    'detail',   coalesce(r.detail,''),
    'relogin',  jsonb_build_object(
       'can',          v_can,
       'label',        _c_or('dev_queue.claude_auth_relogin','Re-login from here'),
       'state',        v_state,
       'state_label',  v_slabel,
       'url',          coalesce(r.relogin_url,''),
       'code',         coalesce(r.relogin_code,''),
       'message',      coalesce(r.relogin_message,''),
       'hint',         _c_or('dev_queue.claude_auth_relogin_hint','')),
    'zone',     admin_active_zone(),
    'date',     admin_active_date());
end $$;

-- ── the phone taps here ─────────────────────────────────────────────────────
create or replace function public.claude_auth_relogin_request(p_host text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_host text;
begin
  perform _dev_guard();
  v_host := coalesce(p_host, _claude_auth_host());
  if v_host is null then return jsonb_build_object('ok', false, 'error', 'no host has reported yet'); end if;
  update dev_claude_auth
     set relogin_state = 'requested', relogin_url = null, relogin_code = null,
         relogin_message = _c_or('dev_queue.claude_auth_relogin_wait','Starting login on the VM…'),
         relogin_requested_at = now(), relogin_updated_at = now()
   where host = v_host;
  perform _audit('admin','claude_auth_relogin_request', v_host, '{}'::jsonb);
  return claude_auth_status();
end $$;

-- ── the VM answers here ─────────────────────────────────────────────────────
create or replace function public.claude_auth_relogin_post(
  p_host text, p_state text, p_url text default null,
  p_code text default null, p_message text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pending boolean;
begin
  perform _dev_guard();
  if p_state not in ('idle','requested','running','url_ready','done','failed') then
    return jsonb_build_object('ok', false, 'error', 'bad state');
  end if;
  update dev_claude_auth
     set relogin_state = p_state,
         relogin_url = coalesce(p_url, relogin_url),
         relogin_code = coalesce(p_code, relogin_code),
         relogin_message = coalesce(nullif(p_message,''), relogin_message),
         relogin_updated_at = now()
   where host = p_host;
  select relogin_state = 'requested' into v_pending from dev_claude_auth where host = p_host;
  return jsonb_build_object('ok', true, 'host', p_host, 'state', p_state);
end $$;

-- Polled by the VM: is there a login for me to start right now?
create or replace function public.claude_auth_relogin_pending(p_host text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.dev_claude_auth;
begin
  perform _dev_guard();
  select * into r from dev_claude_auth where host = p_host;
  if not found then return jsonb_build_object('pending', false); end if;
  return jsonb_build_object('pending', r.relogin_state = 'requested',
                            'requested_at', r.relogin_requested_at,
                            'state', r.relogin_state);
end $$;

-- ── 5. the churn breaker ────────────────────────────────────────────────────
-- Called from dev_runner_liveness at the moment a row would be released. It
-- answers ONE question: is this release the one that proves the worker cannot
-- start Claude? True => the row is already parked and must not go back to
-- pending.
create or replace function public._claude_churn_check(p_id bigint, p_tokens bigint)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb; v_max int; v_win int; r record; v_n int; v_first timestamptz;
        v_mins int; v_q text;
begin
  cfg := _claude_auth_cfg();
  if not coalesce((cfg->>'enabled')::boolean, true) then return false; end if;
  v_max := greatest(coalesce((cfg->>'churn_max')::int, 2), 2);
  v_win := greatest(coalesce((cfg->>'churn_window_min')::int, 15), 1);

  select zero_release_count, zero_release_first_at into v_n, v_first
    from dev_commands where id = p_id;

  -- A release that DID spend tokens is a normal release: the counter resets,
  -- because whatever went wrong, it was not "Claude never started".
  if coalesce(p_tokens, 0) > 0 then
    update dev_commands set zero_release_count = 0, zero_release_first_at = null where id = p_id;
    return false;
  end if;

  if v_first is null or v_first < now() - make_interval(mins => v_win) then
    v_n := 1; v_first := now();
  else
    v_n := coalesce(v_n, 0) + 1;
  end if;
  update dev_commands set zero_release_count = v_n, zero_release_first_at = v_first where id = p_id;

  if v_n < v_max then return false; end if;

  -- BREAKER. The row is held, not re-handed. needs_input_kind='infra' is what
  -- keeps dev_auto_resolve away from it: only Om (or a green login) frees it.
  v_mins := greatest(ceil(extract(epoch from (now() - v_first)) / 60.0)::int, 1);
  v_q := replace(replace(replace(
           _c_or('dev_queue.claude_auth_churn_q',
             '#{id} was handed out {n} times in {mins} minutes and spent zero tokens every time.'),
           '{id}', p_id::text), '{n}', v_n::text), '{mins}', v_mins::text);

  update dev_commands
     set status = 'needs_input', claimed_by = null,
         needs_input_kind = 'infra',
         needs_input_question = v_q,
         churn_parked_at = now(),
         released_at = now(),
         release_reason = _c_or('dev_queue.claude_auth_churn','Runner cannot start Claude'),
         eta_left_s = null, eta_total_s = null, eta_note = null,
         guard_snap_at = null, guard_snap_tokens = null, guard_snap_eta = null,
         token_stall_at = null, token_stall_tokens = null, token_stall_flagged = false,
         error_log = coalesce(error_log || E'\n---\n','')
           || 'CHURN BREAKER: released ' || v_n || ' times in ' || v_mins
           || ' min with 0 tokens — the runner cannot start Claude. Not re-handed.'
   where id = p_id;

  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system', replace(replace(
    _c_or('dev_queue.claude_auth_churn_msg',
      '⛔ Churn breaker: released {n} times in {mins} min with 0 tokens.'),
    '{n}', v_n::text), '{mins}', v_mins::text));

  perform _lease_release_internal(p_id);

  -- Pause the fleet. Claiming into a box that cannot start Claude is what
  -- turned one broken login into 28 claims.
  if coalesce((cfg->>'pause_fleet')::boolean, true) then
    update dev_runner_config
       set value = jsonb_set(value, '{workflow}', to_jsonb('off'::text))
     where key = 'desired_state';
  end if;

  perform wa_send_event('sec_claude_auth', null,
    jsonb_build_object('reason', _c_or('dev_queue.claude_auth_churn','Runner cannot start Claude')
                                 || ' — #' || p_id || ' held, queue paused',
                       'host', coalesce(_claude_auth_host(),'')), null, null);
  insert into rg_alerts (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
  values ('claude_churn:'||p_id, 'critical', 'claude_auth',
          _c_or('dev_queue.claude_auth_churn','Runner cannot start Claude'),
          jsonb_build_object('command_id', p_id, 'releases', v_n, 'window_min', v_mins),
          now(), now(), 1)
  on conflict (fingerprint) do update
    set last_seen = now(), seen_count = rg_alerts.seen_count + 1;

  perform _audit('system','claude_churn_park', p_id::text,
                 jsonb_build_object('releases', v_n, 'window_min', v_mins));
  return true;
end $$;

-- ── 6. the launch gate's other half: a SICK RUNNER, not a sick command ──────
-- #1369's third failure was blaming the row. The harness posts "started" only
-- once a claude pid exists AND a first heartbeat has landed; when that never
-- happens the row goes back untouched and the RUNNER is marked sick here. Kept
-- in dev_runner_config rather than a new table on purpose: this is fleet state
-- with a handful of keys, and every extra DDL costs the whole fleet a
-- PostgREST schema reload.
create or replace function public.runner_sick_set(p_agent text, p_sick boolean, p_reason text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb;
begin
  perform _dev_guard();
  if coalesce(btrim(p_agent),'') = '' then
    return jsonb_build_object('ok', false, 'error', 'agent required');
  end if;
  insert into dev_runner_config (key, value) values ('runner_sick', '{}'::jsonb)
    on conflict (key) do nothing;
  select coalesce(value,'{}'::jsonb) into v from dev_runner_config where key='runner_sick';
  if coalesce(p_sick,false) then
    v := v || jsonb_build_object(p_agent, jsonb_build_object(
           'since',  coalesce(v->p_agent->>'since', now()::text),
           'at',     now()::text,
           'count',  coalesce((v->p_agent->>'count')::int, 0) + 1,
           'reason', left(coalesce(p_reason,''), 300)));
  else
    v := v - p_agent;
  end if;
  update dev_runner_config set value = v where key='runner_sick';
  perform _audit('system','runner_sick_set', p_agent,
                 jsonb_build_object('sick', coalesce(p_sick,false), 'reason', left(coalesce(p_reason,''),300)));
  return jsonb_build_object('ok', true, 'agent', p_agent, 'sick', coalesce(p_sick,false),
                            'sick_agents', v);
end $$;

create or replace function public.runner_sick_get(p_agent text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb;
begin
  select coalesce(value,'{}'::jsonb) into v from dev_runner_config where key='runner_sick';
  v := coalesce(v,'{}'::jsonb);
  if p_agent is null then return jsonb_build_object('sick_agents', v, 'count', (select count(*) from jsonb_object_keys(v))); end if;
  return jsonb_build_object('agent', p_agent, 'sick', v ? p_agent, 'detail', coalesce(v->p_agent,'{}'::jsonb));
end $$;

-- ── 7. the claim gate ───────────────────────────────────────────────────────
-- Two new refusals, both BEFORE a row is ever taken out of pending: a fresh red
-- Claude report on this host, and this particular runner being marked sick by
-- its own launch gate. Both fail OPEN when unknown — a dead reporter must never
-- brick the fleet.
create or replace function public.dev_cmd_claim(p_agent text, p_routes text[] DEFAULT NULL::text[], p_prefer_area text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_hold bigint; v_hold_t text; v jsonb; v_res jsonb; v_blocked int; v_adm jsonb; v_scope jsonb;
        v_fact boolean; v_msg text; v_auth jsonb; v_sick jsonb;
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
    SELECT value#>>'{}' INTO v_msg FROM ui_copy
     WHERE key = CASE WHEN v_blocked > 0 THEN 'dev_queue.claim_blocked' ELSE 'dev_queue.claim_empty' END;
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

insert into public.ui_copy (key, value) values
 ('dev_queue.claim_blocked_sick', '"This runner could not start a Claude session on its last try, so it is not claiming."'::jsonb)
on conflict (key) do nothing;

-- ── 8. every release path asks the breaker first ────────────────────────────
-- The breaker is not a fourth watchdog. It is one question asked at the exact
-- moment a row would go back to pending: has this row now been handed out
-- twice inside the window having spent ZERO tokens? If so it is already parked
-- as needs_input by _claude_churn_check and must NOT be re-queued here.
create or replace function public.dev_cmd_liveness_sweep()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE cfg jsonb; v_on boolean; v_warn int; v_grace int; v_maxlost int;
        r record; v_why text; v_msg text; v_q text; v_silent numeric;
        n_warn int := 0; n_lost int := 0; n_stop int := 0; n_churn int := 0;
BEGIN
  SELECT coalesce(value->'liveness','{}'::jsonb) INTO cfg FROM dev_runner_config WHERE key='worker_pool';
  v_on      := coalesce((cfg->>'enabled')::boolean, true);
  v_warn    := coalesce((cfg->>'warn_min')::int, 6);
  v_grace   := coalesce((cfg->>'disconnect_grace_min')::int, 1);
  v_maxlost := coalesce((cfg->>'max_lost')::int, 3);
  IF NOT v_on THEN RETURN jsonb_build_object('ok', true, 'enabled', false); END IF;

  SELECT value#>>'{}' INTO v_msg FROM ui_copy WHERE key='dev_queue.session_lost_msg';
  SELECT value#>>'{}' INTO v_q   FROM ui_copy WHERE key='dev_queue.session_lost_stop';

  FOR r IN SELECT id, agent_alive_at, agent_pane_alive, agent_rc_session,
                  agent_silent_flagged, session_lost_count, claimed_by,
                  cost_input_tokens + cost_output_tokens AS tokens
             FROM dev_commands
            WHERE status='building'
              AND wait_state IS DISTINCT FROM 'parked'
              AND agent_alive_at IS NOT NULL
              AND (started_at IS NULL OR agent_alive_at >= started_at)
              AND (heartbeat_at IS NULL OR heartbeat_at < now() - make_interval(mins => v_grace))
  LOOP
    v_silent := extract(epoch from now() - r.agent_alive_at) / 60.0;
    v_why := NULL;

    IF r.agent_pane_alive IS FALSE AND v_silent >= v_grace THEN
      v_why := 'the Remote Control session is not reachable and the agent has been quiet for '
               || _fmt_dur(v_silent * 60);
    END IF;

    IF v_why IS NULL THEN
      IF r.agent_pane_alive IS FALSE OR v_silent >= v_warn THEN
        IF NOT coalesce(r.agent_silent_flagged,false) THEN
          UPDATE dev_commands SET agent_silent_flagged=true,
                 agent_silent_at=coalesce(agent_silent_at, r.agent_alive_at) WHERE id=r.id;
          n_warn := n_warn + 1;
        END IF;
      ELSIF coalesce(r.agent_silent_flagged,false) THEN
        UPDATE dev_commands SET agent_silent_flagged=false, agent_silent_at=NULL WHERE id=r.id;
      END IF;
      CONTINUE;
    END IF;

    -- CHANGE #1369 — the breaker answers BEFORE anything is re-queued. It parks
    -- the row itself when it trips, so there is nothing left to hand out.
    IF _claude_churn_check(r.id, r.tokens) THEN
      n_churn := n_churn + 1;
      CONTINUE;
    END IF;

    IF coalesce(r.session_lost_count,0) + 1 >= v_maxlost THEN
      UPDATE dev_commands SET status='needs_input', claimed_by=NULL,
             session_lost_count = coalesce(session_lost_count,0)+1,
             agent_silent_flagged=false, agent_silent_at=NULL,
             agent_alive_at=NULL, agent_pane_alive=NULL,
             -- CHANGE #1369 — kind 'infra'. This question is about the BOX, so
             -- the auto-resolver must never "answer" it by re-queueing: that is
             -- exactly how #1369 collected three identical AUTO-RESOLVER NOTEs
             -- while the login stayed expired.
             needs_input_kind = 'infra',
             needs_input_question = replace(coalesce(v_q,'This build has lost its Claude session {n} times. Reply yes to hand it out again, or split the spec.'),
                                            '{n}', (coalesce(r.session_lost_count,0)+1)::text)
       WHERE id=r.id AND status='building';
      n_stop := n_stop + 1;
    ELSE
      UPDATE dev_commands SET status='pending', claimed_by=NULL,
             session_lost_count = coalesce(session_lost_count,0)+1,
             agent_silent_flagged=false, agent_silent_at=NULL,
             agent_alive_at=NULL, agent_pane_alive=NULL,
             error_log = coalesce(error_log||E'\n---\n','')||'LIVENESS: '||v_why||' — re-queued'
       WHERE id=r.id AND status='building';
      n_lost := n_lost + 1;
    END IF;

    INSERT INTO dev_command_messages (command_id, sender, body)
    VALUES (r.id, 'system', replace(coalesce(v_msg,'↻ Re-queued: the Claude session for this build is gone ({why}).'), '{why}', v_why));
    PERFORM _lease_release_internal(r.id);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'warned', n_warn, 'requeued', n_lost,
                            'stopped', n_stop, 'churn_parked', n_churn,
                            'warn_min', v_warn,
                            'disconnect_grace_min', v_grace);
END $$;

create or replace function public.dev_cmd_release(p_agent text DEFAULT NULL::text, p_reason text DEFAULT 'shutdown'::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare r record; v_ids bigint[] := '{}'; v_churn bigint[] := '{}';
begin
  perform _dev_guard();
  for r in select id, steps_done, steps_total,
                  cost_input_tokens + cost_output_tokens as tokens
             from dev_commands
            where status = 'building'
              and (p_agent is null or claimed_by = p_agent)
            for update
  loop
    -- CHANGE #1369 — same question, same moment. A worker that keeps releasing
    -- a row it never spent a token on is not "shutting down", it cannot start.
    if _claude_churn_check(r.id, r.tokens) then
      v_churn := v_churn || r.id;
      continue;
    end if;
    update dev_commands
       set status = 'pending', claimed_by = NULL,
           released_at = now(), release_reason = p_reason,
           eta_left_s = NULL, eta_total_s = NULL, eta_note = NULL,
           guard_snap_at = NULL, guard_snap_tokens = NULL, guard_snap_eta = NULL,
           token_stall_at = NULL, token_stall_tokens = NULL, token_stall_flagged = false,
           error_log = coalesce(error_log || E'\n---\n','')
             || 'RELEASED (' || p_reason || '): worker stopped, row returned to pending'
             || case when r.steps_done > 0
                     then ' — resumes at step ' || (r.steps_done + 1) || '/' || r.steps_total
                     else '' end
     where id = r.id;
    insert into dev_command_messages (command_id, sender, body) values (r.id, 'system',
      '↻ Released back to pending (' || p_reason || ')'
      || case when r.steps_done > 0
              then ' — ' || r.steps_done || '/' || r.steps_total
                   || ' steps already landed, it will resume at step ' || (r.steps_done + 1) || '.'
              else '.' end);
    perform _lease_release_internal(r.id);
    v_ids := v_ids || r.id;
  end loop;
  return jsonb_build_object('ok', true, 'count', coalesce(array_length(v_ids,1),0),
                            'released', to_jsonb(v_ids),
                            'churn_parked', to_jsonb(v_churn));
end $$;

-- The watchdog's two re-queue doors get the same guard. Everything else in this
-- function is untouched: it is reproduced whole because CREATE OR REPLACE has
-- no other shape, and #327 proved that editing it by memory silently disables
-- rules that are not visibly there.
create or replace function public.dev_cmd_watchdog()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r record; n int := 0; v_stall int; v_ceiling int;
        v_sw jsonb; v_sw_on boolean; v_sw_min int; v_sw_tok bigint;
        v_sw_renudge int; v_sw_max int;
        t_noplan text; t_stale text; v_body text; v_age text;
        v_flagged int := 0; v_nudged int := 0; v_churn int := 0;
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

  FOR r IN SELECT id, retry_count, started_at, heartbeat_at, eta_left_s,
                  cost_input_tokens+cost_output_tokens AS tokens,
                  guard_snap_at, guard_snap_tokens, guard_snap_eta, guard_snap_steps,
                  steps_done, steps_total, steps_snap_at, steps_snap_done,
                  steps_snap_tokens, steps_stale_flagged, steps_nudge_count, steps_nudged_at
           FROM dev_commands WHERE status='building' AND wait_state IS DISTINCT FROM 'parked' LOOP

    IF r.heartbeat_at < now() - interval '15 minutes' THEN
      -- CHANGE #1369 — the breaker first. A row whose heartbeat never arrived
      -- and whose token count never moved is the churn signature itself.
      IF _claude_churn_check(r.id, r.tokens) THEN
        v_churn := v_churn + 1; n := n + 1; CONTINUE;
      END IF;
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

    IF v_sw_on THEN
      IF r.steps_snap_at IS NULL OR r.steps_snap_done IS DISTINCT FROM r.steps_done THEN
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
      -- CHANGE #1369 — the dead-worker door. Zero tokens is literally the
      -- condition this branch fires on, so it is the churn signature twice over.
      IF _claude_churn_check(r.id, r.tokens) THEN
        v_churn := v_churn + 1; n := n + 1; CONTINUE;
      END IF;
      UPDATE dev_commands SET status='pending', claimed_by=NULL, retry_count=greatest(retry_count,0),
        error_log = coalesce(error_log||E'\n---\n','')||'STALLED: no ETA change and no token activity for '||(v_stall*2)||'min (worker likely lost) — re-queued'
      WHERE id=r.id;
      INSERT INTO dev_command_messages (command_id, sender, body) VALUES (r.id,'system','↻ Re-queued: worker appears lost (no progress, no activity for '||(v_stall*2)||' min).');
      PERFORM _lease_release_internal(r.id);
      PERFORM wa_send_event('sec_zombie_killed', NULL, jsonb_build_object('command_id',r.id::text,'reason','dead worker (no activity)','tokens',r.tokens::text), NULL, NULL);
      n:=n+1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('acted', n, 'steps_flagged', v_flagged, 'steps_nudged', v_nudged,
                            'churn_parked', v_churn);
END $$;

-- ── 9. the auto-resolver never answers an infrastructure question ───────────
-- It answered #1369's three times, each time appending an AUTO-RESOLVER NOTE
-- and handing the row straight back to a box whose login was still expired.
-- 'infra' joins 'danger' and 'external' in the escalate list, and the old rows
-- (tagged before this change) are recognised from the question text.
create or replace function public.dev_auto_resolve()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r record; cfg jsonb; n int := 0; v_max int; v_kind text; v_budget bigint;
BEGIN
  SELECT value->'auto_resolver' INTO cfg FROM dev_runner_config WHERE key='worker_pool';
  IF NOT coalesce((cfg->>'enabled')::boolean,false) THEN RETURN jsonb_build_object('disabled',true); END IF;
  v_max := coalesce((cfg->>'max_auto_resolves')::int,3);

  FOR r IN SELECT id, needs_input_question, needs_input_kind, auto_resolve_count, is_danger,
                  cost_input_tokens+cost_output_tokens AS tokens, token_budget_extra, size_class
           FROM dev_commands WHERE status='needs_input' LOOP

    v_kind := coalesce(r.needs_input_kind,
      CASE
        WHEN r.needs_input_question ILIKE '%token budget%' THEN 'budget'
        WHEN r.is_danger OR r.needs_input_question ILIKE '%PIN%' OR r.needs_input_question ILIKE '%delete%' OR r.needs_input_question ILIKE '%destroy%' THEN 'danger'
        WHEN r.needs_input_question ILIKE '%password%' OR r.needs_input_question ILIKE '%login%' OR r.needs_input_question ILIKE '%credential%' OR r.needs_input_question ILIKE '%secret%' OR r.needs_input_question ILIKE '%token (from|key)%' THEN 'external'
        ELSE 'question' END);

    -- CHANGE #1369 — an infrastructure question is about the BOX. Re-queueing
    -- it changes nothing on the box, so it is never auto-answered, whatever the
    -- text says.
    IF r.needs_input_question ILIKE '%lost its Claude session%'
       OR r.needs_input_question ILIKE '%cannot start Claude%'
       OR r.needs_input_question ILIKE '%spent zero tokens%' THEN
      v_kind := 'infra';
    END IF;

    IF v_kind IN ('danger','external','infra') THEN CONTINUE; END IF;

    IF r.auto_resolve_count >= v_max THEN CONTINUE; END IF;

    IF v_kind = 'budget' AND coalesce((cfg->>'auto_budget_continue')::boolean,true) THEN
      v_budget := coalesce((SELECT (value->'token_budget_by_class'->>coalesce(r.size_class,'normal'))::bigint FROM dev_runner_config WHERE key='worker_pool'),1500000);
      UPDATE dev_commands SET
        token_budget_extra = greatest(token_budget_extra, r.tokens),
        status='pending', urgent=true, needs_input_question=NULL,
        auto_resolve_count = auto_resolve_count + 1
      WHERE id=r.id AND status='needs_input';
      INSERT INTO dev_command_messages(command_id, sender, body)
      VALUES (r.id,'system','🤖 Auto-resolver: budget window granted automatically (#'||(r.auto_resolve_count+1)||'/'||v_max||'), resuming.');
      PERFORM _audit('system','auto_resolve', r.id::text, jsonb_build_object('kind','budget','count',r.auto_resolve_count+1));
      n := n+1;
    ELSE
      UPDATE dev_commands SET
        spec = spec || E'\n\nAUTO-RESOLVER NOTE: you previously paused asking: "'||left(coalesce(r.needs_input_question,''),300)||'". Do NOT pause again for this — pick the safest sensible default consistent with legal_get_page(''about''), existing patterns, and dev_lessons, log the decision, and continue. Only a money/destructive/credential question may pause.',
        status='pending', urgent=true, needs_input_question=NULL,
        auto_resolve_count = auto_resolve_count + 1
      WHERE id=r.id AND status='needs_input';
      INSERT INTO dev_command_messages(command_id, sender, body)
      VALUES (r.id,'system','🤖 Auto-resolver: answered a build question with the sensible default (#'||(r.auto_resolve_count+1)||'/'||v_max||'), resuming.');
      PERFORM _audit('system','auto_resolve', r.id::text, jsonb_build_object('kind','question','count',r.auto_resolve_count+1));
      n := n+1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('resolved', n);
END $$;

-- ── 10. the card reaches the app on the payload it already fetches ──────────
create or replace function public.dev_ctl_get()
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
declare v jsonb; v_ctx jsonb; v_blocked jsonb; v_disk jsonb; v_auth jsonb;
begin
  v := public.dev_ctl_get_core();
  begin v_ctx := public.dev_context_metrics_cached(60);
  exception when others then v_ctx := jsonb_build_object('ok', false, 'has', false);
  end;
  begin v_blocked := public.runner_blocked_badge();
  exception when others then v_blocked := jsonb_build_object('has', false);
  end;
  begin v_disk := public.runner_disk_state();
  exception when others then v_disk := jsonb_build_object('has', false);
  end;
  -- CHANGE #1369 — the Claude login rides the SAME payload the control card
  -- already fetches, so the banner costs no extra round trip and cannot be a
  -- second source of truth.
  begin v_auth := public.claude_auth_status();
  exception when others then v_auth := jsonb_build_object('has', false);
  end;
  if coalesce((v->'health'->>'ok')::boolean, false) then
    v := jsonb_set(v, '{health,metrics}',
           coalesce(v->'health'->'metrics','[]'::jsonb)
           || jsonb_build_array(public.runner_health_disk_metric()));
  end if;

  return v || jsonb_build_object('context', v_ctx, 'blocked', v_blocked, 'disk', v_disk,
                                 'claude_auth', v_auth);
end $$;

-- ── 11. the breaker un-pauses itself ────────────────────────────────────────
-- A breaker that only ever stops the fleet needs a human to restart it, which
-- is the churn problem wearing a different hat. So the pause is ATTRIBUTED
-- (paused_by_breaker), and the next GREEN login report — the one that arrives
-- seconds after Om finishes the re-login on his phone — puts the fleet back
-- exactly as it found it. A pause Om made himself is never touched.
create or replace function public._claude_breaker_pause(p_on boolean)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_cur text;
begin
  select value->>'workflow' into v_cur from dev_runner_config where key='desired_state';
  if p_on then
    if coalesce(v_cur,'off') = 'off' then return; end if;   -- already stopped; not ours to own
    update dev_runner_config
       set value = jsonb_set(value, '{workflow}', to_jsonb('off'::text))
     where key = 'desired_state';
    update dev_runner_config
       set value = jsonb_set(value, '{claude_auth,paused_by_breaker}', to_jsonb(true))
     where key = 'worker_pool';
  else
    if not coalesce((_claude_auth_cfg()->>'paused_by_breaker')::boolean, false) then return; end if;
    update dev_runner_config
       set value = jsonb_set(value, '{workflow}', to_jsonb('on'::text))
     where key = 'desired_state';
    update dev_runner_config
       set value = jsonb_set(value, '{claude_auth,paused_by_breaker}', to_jsonb(false))
     where key = 'worker_pool';
    perform _audit('system','claude_breaker_resume','fleet',
                   jsonb_build_object('reason','Claude login green again'));
  end if;
end $$;

create or replace function public._claude_churn_check(p_id bigint, p_tokens bigint)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare cfg jsonb; v_max int; v_win int; v_n int; v_first timestamptz;
        v_mins int; v_q text;
begin
  cfg := _claude_auth_cfg();
  if not coalesce((cfg->>'enabled')::boolean, true) then return false; end if;
  v_max := greatest(coalesce((cfg->>'churn_max')::int, 2), 2);
  v_win := greatest(coalesce((cfg->>'churn_window_min')::int, 15), 1);

  select zero_release_count, zero_release_first_at into v_n, v_first
    from dev_commands where id = p_id;

  -- A release that DID spend tokens is a normal release: the counter resets,
  -- because whatever went wrong, it was not "Claude never started".
  if coalesce(p_tokens, 0) > 0 then
    update dev_commands set zero_release_count = 0, zero_release_first_at = null where id = p_id;
    return false;
  end if;

  if v_first is null or v_first < now() - make_interval(mins => v_win) then
    v_n := 1; v_first := now();
  else
    v_n := coalesce(v_n, 0) + 1;
  end if;
  update dev_commands set zero_release_count = v_n, zero_release_first_at = v_first where id = p_id;

  if v_n < v_max then return false; end if;

  v_mins := greatest(ceil(extract(epoch from (now() - v_first)) / 60.0)::int, 1);
  v_q := replace(replace(replace(
           _c_or('dev_queue.claude_auth_churn_q',
             '#{id} was handed out {n} times in {mins} minutes and spent zero tokens every time.'),
           '{id}', p_id::text), '{n}', v_n::text), '{mins}', v_mins::text);

  update dev_commands
     set status = 'needs_input', claimed_by = null,
         needs_input_kind = 'infra',
         needs_input_question = v_q,
         churn_parked_at = now(),
         released_at = now(),
         release_reason = _c_or('dev_queue.claude_auth_churn','Runner cannot start Claude'),
         eta_left_s = null, eta_total_s = null, eta_note = null,
         guard_snap_at = null, guard_snap_tokens = null, guard_snap_eta = null,
         token_stall_at = null, token_stall_tokens = null, token_stall_flagged = false,
         error_log = coalesce(error_log || E'\n---\n','')
           || 'CHURN BREAKER: released ' || v_n || ' times in ' || v_mins
           || ' min with 0 tokens — the runner cannot start Claude. Not re-handed.'
   where id = p_id;

  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system', replace(replace(
    _c_or('dev_queue.claude_auth_churn_msg',
      '⛔ Churn breaker: released {n} times in {mins} min with 0 tokens.'),
    '{n}', v_n::text), '{mins}', v_mins::text));

  perform _lease_release_internal(p_id);

  if coalesce((cfg->>'pause_fleet')::boolean, true) then
    perform _claude_breaker_pause(true);
  end if;

  perform wa_send_event('sec_claude_auth', null,
    jsonb_build_object('reason', _c_or('dev_queue.claude_auth_churn','Runner cannot start Claude')
                                 || ' — #' || p_id || ' held, queue paused',
                       'host', coalesce(_claude_auth_host(),'')), null, null);
  insert into rg_alerts (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
  values ('claude_churn:'||p_id, 'critical', 'claude_auth',
          _c_or('dev_queue.claude_auth_churn','Runner cannot start Claude'),
          jsonb_build_object('command_id', p_id, 'releases', v_n, 'window_min', v_mins),
          now(), now(), 1)
  on conflict (fingerprint) do update
    set last_seen = now(), seen_count = rg_alerts.seen_count + 1;

  perform _audit('system','claude_churn_park', p_id::text,
                 jsonb_build_object('releases', v_n, 'window_min', v_mins));
  return true;
end $$;

-- claude_auth_report, with the resume half wired in.
create or replace function public.claude_auth_report(
  p_host text, p_auth_ok boolean, p_smoke_ok boolean,
  p_cli_version text default null, p_expires_at timestamptz default null,
  p_detail text default '', p_agent text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.dev_claude_auth; v_bucket text; v_prev text; v_blocked boolean;
        v_reason text; v_alerted boolean := false; v_resumed boolean := false;
begin
  perform _dev_guard();
  if coalesce(btrim(p_host),'') = '' then
    return jsonb_build_object('ok', false, 'error', 'host required');
  end if;

  select alert_bucket into v_prev from dev_claude_auth where host = p_host;
  v_blocked := not (coalesce(p_auth_ok,false) and coalesce(p_smoke_ok,false));

  insert into dev_claude_auth as d
    (host, agent, checked_at, cli_version, auth_ok, smoke_ok, expires_at, detail, blocked, updated_at)
  values (p_host, p_agent, now(), p_cli_version, coalesce(p_auth_ok,false),
          coalesce(p_smoke_ok,false), p_expires_at, coalesce(p_detail,''), v_blocked, now())
  on conflict (host) do update set
    agent       = coalesce(excluded.agent, d.agent),
    checked_at  = excluded.checked_at,
    cli_version = coalesce(excluded.cli_version, d.cli_version),
    auth_ok     = excluded.auth_ok,
    smoke_ok    = excluded.smoke_ok,
    expires_at  = coalesce(excluded.expires_at, d.expires_at),
    detail      = excluded.detail,
    blocked     = excluded.blocked,
    updated_at  = now()
  returning * into r;

  v_bucket := _claude_auth_bucket(r);

  if not v_blocked and r.relogin_state in ('requested','running','url_ready') then
    update dev_claude_auth set relogin_state = 'done',
           relogin_message = _c_or('dev_queue.claude_auth_relogin_done','Signed in — runners released'),
           relogin_updated_at = now()
     where host = p_host returning * into r;
  end if;

  -- The resume half. Green login => whatever the breaker stopped, restart.
  if not v_blocked then
    perform _claude_breaker_pause(false);
    v_resumed := true;
  end if;

  if v_bucket <> 'ok' and v_bucket is distinct from v_prev then
    v_reason := case v_bucket
      when 'red_auth'  then _c_or('dev_queue.claude_auth_blocked','Runners blocked: Claude login expired')
      when 'red_smoke' then _c_or('dev_queue.claude_auth_smoke_bad','Runners blocked: Claude does not answer')
      when 'expired'   then _c_or('dev_queue.claude_auth_expired','Claude login has expired')
      else replace(_c_or('dev_queue.claude_auth_expiring','Claude login expires in {days}'),
                   '{days}', replace(v_bucket,'warn_','') ) end;
    perform wa_send_event('sec_claude_auth', null,
      jsonb_build_object('reason', v_reason, 'host', p_host,
                         'detail', left(coalesce(p_detail,''), 300)), null, null);
    insert into rg_alerts (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
    values ('claude_auth:'||p_host||':'||v_bucket,
            case when v_bucket like 'red_%' or v_bucket='expired' then 'critical' else 'warn' end,
            'claude_auth', v_reason,
            jsonb_build_object('host',p_host,'bucket',v_bucket,'detail',left(coalesce(p_detail,''),500)),
            now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
    v_alerted := true;
  end if;

  update dev_claude_auth
     set alert_bucket = v_bucket,
         alerted_at = case when v_alerted then now() else alerted_at end
   where host = p_host;

  return jsonb_build_object('ok', true, 'host', p_host, 'blocked', v_blocked,
                            'bucket', v_bucket, 'alerted', v_alerted,
                            'fleet_resume_checked', v_resumed);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;
