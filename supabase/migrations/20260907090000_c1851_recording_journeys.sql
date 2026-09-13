-- CMD #1851 — CLICKING THROUGH A FLOW ONCE BECOMES A PERMANENT REGRESSION JOURNEY.
--
-- test_recording / test_recording_step were created by #638 and never filled: the
-- Chaos lab could start and stop a walkthrough, and the recorder observed route
-- pushes and RenderLog writes, but NOTHING ever recorded the one thing a replay
-- can actually assert on — the RPC the screen called and the payload it got back.
-- Flutter renders to canvas, so a pixel replay is worthless here; the ANSWER is
-- the asset. This migration wires that end of it and gives the recording a way
-- back out again: promote -> a durable plan -> a replay -> a journey verdict.
--
-- Nothing here runs outside a live test session. With no session, capture is
-- refused in one STABLE read and the client never calls it at all (§6).
--
-- Idempotent: every object is create-or-replace / if-not-exists, and every seed
-- is an upsert on a natural key.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE MATCH RULES ARE DATA (spec §5)
--    A replayed payload legitimately varies: a timestamp moves, an id is new,
--    a signed URL is re-signed. Which paths those are is a ROW, not a branch in
--    a function — a new volatile key is one INSERT, never a deploy.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.recording_match_rule (
  id            bigserial primary key,
  fn            text        not null default '*',    -- '*' = every recorded RPC
  path_pattern  text        not null,                -- POSIX regex over the JSON path
  mode          text        not null default 'shape',-- exact | shape | ignore | skip_step
  priority      int         not null default 100,    -- lower wins
  note          text        not null default '',     -- the backend's own words
  enabled       boolean     not null default true,
  created_at    timestamptz not null default now()
);

do $$ begin
  alter table public.recording_match_rule drop constraint if exists recording_match_rule_mode_chk;
  alter table public.recording_match_rule
    add constraint recording_match_rule_mode_chk
    check (mode in ('exact','shape','ignore','skip_step','fresh_uuid'));
exception when duplicate_object then null; end $$;

create unique index if not exists recording_match_rule_key
  on public.recording_match_rule (fn, path_pattern);

alter table public.recording_match_rule enable row level security;

comment on table public.recording_match_rule is
  'CMD #1851 — how a replayed payload is compared, per function and JSON path. '
  'Data, not code: mode shape ignores the value and keeps the type, ignore drops '
  'the path entirely, skip_step keeps a function out of replay altogether, and '
  'fresh_uuid (matched on $args.<name>) hands the call a NEW id instead of the '
  'recorded one — an idempotency key replayed verbatim answers "already done" '
  'and every step after it then diverges for the wrong reason.';

insert into public.recording_match_rule (fn, path_pattern, mode, priority, note) values
  -- volatile values: the shape is the assertion, the value never was
  ('*', '_at$',                         'shape',  10, 'A timestamp moves on every run — the type is what is asserted.'),
  ('*', '(^|\.)id$',                    'shape',  10, 'A fresh row carries a fresh id.'),
  ('*', '_id$',                         'shape',  10, 'A fresh row carries a fresh id.'),
  ('*', '_ms$',                         'shape',  10, 'A duration is not a fact about the payload.'),
  ('*', '(^|\.)now$',                   'shape',  10, 'The clock moves.'),
  ('*', '(created|updated|expires)',    'shape',  20, 'Lifecycle stamps move with the run.'),
  ('*', '(duration|elapsed|age|seq)',   'shape',  20, 'Counters and clocks move with the run.'),
  ('*', 'order_code$',                  'shape',  20, 'An order code is minted per order.'),
  ('*', 'token',                        'ignore', 10, 'A token is re-issued per session and is never compared.'),
  ('*', 'signed_url|signedurl|(^|\.)url$', 'ignore', 20, 'A signed URL is re-signed on every read.'),
  -- an idempotency key is per ATTEMPT. Replayed verbatim, place_order_v2 answers
  -- {replayed:true} without placing anything, and the cart it should have
  -- emptied then diverges two steps later — which is what #1851's first replay
  -- reported, correctly and uselessly. The rule for that is a row.
  ('*', '^\$args\.(p_)?(client_action_id|idempotency_key|request_key)$', 'fresh_uuid', 5,
        'An idempotency key belongs to one attempt; the replay is a new attempt and gets a new one.'),
  -- the recording plumbing must never replay itself
  ('recording_capture',       '^\$$', 'skip_step', 1, 'Recording plumbing is never part of a replay.'),
  ('recording_state',         '^\$$', 'skip_step', 1, 'Recording plumbing is never part of a replay.'),
  ('recording_start',         '^\$$', 'skip_step', 1, 'Recording plumbing is never part of a replay.'),
  ('recording_stop',          '^\$$', 'skip_step', 1, 'Recording plumbing is never part of a replay.'),
  ('recording_promote',       '^\$$', 'skip_step', 1, 'Recording plumbing is never part of a replay.'),
  ('recording_replay',        '^\$$', 'skip_step', 1, 'Recording plumbing is never part of a replay.'),
  ('recording_step_add',      '^\$$', 'skip_step', 1, 'Recording plumbing is never part of a replay.'),
  ('test_session_banner',     '^\$$', 'skip_step', 1, 'The test-mode banner polls on a timer; it is noise in a walkthrough.'),
  ('test_session_start',      '^\$$', 'skip_step', 1, 'Replaying a session start would open a second session.'),
  ('test_session_end',        '^\$$', 'skip_step', 1, 'Replaying a session end would close the one the replay runs in.'),
  ('test_session_end_purge',  '^\$$', 'skip_step', 1, 'Replaying a purge would delete the rows under the replay.'),
  ('test_session_purge',      '^\$$', 'skip_step', 1, 'Replaying a purge would delete the rows under the replay.')
on conflict (fn, path_pattern) do update
  set mode = excluded.mode, priority = excluded.priority, note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE DURABLE PLAN
--    A recording is purged with its test session (that is the whole point of a
--    test session). A promoted journey must outlive it, so promote copies the
--    replayable plan out into a table that purge never touches.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.recording_journey_plan (
  name          text primary key,
  area          text        not null default 'platform',
  recording_id  bigint,
  label         text        not null default '',
  plan          jsonb       not null default '[]'::jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
alter table public.recording_journey_plan enable row level security;

comment on table public.recording_journey_plan is
  'CMD #1851 — the replayable body of a promoted walkthrough: the ordered RPC '
  'steps and the payloads they returned. Survives the purge of the test session '
  'the walkthrough was recorded in.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. UI COPY — every word a screen shows about recording lives here.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('recording.capture_no_session', to_jsonb('There is no live test session on this device, so nothing was recorded.'::text)),
  ('recording.capture_not_live',   to_jsonb('That walkthrough is not recording any more.'::text)),
  ('recording.state_idle',         to_jsonb('Not recording.'::text)),
  ('recording.state_live',         to_jsonb('Recording — every screen you open and every call the app makes is a step.'::text)),
  ('recording.offer_title',        to_jsonb('Keep this walkthrough as a test?'::text)),
  ('recording.offer_body',         to_jsonb('Saving it makes a journey that replays these steps and their answers on every future command in its area. It starts advisory: it has to pass twice before it can ever block one.'::text)),
  ('recording.offer_save',         to_jsonb('Save as journey'::text)),
  ('recording.offer_discard',      to_jsonb('Discard'::text)),
  ('recording.offer_name_label',   to_jsonb('Name'::text)),
  ('recording.offer_area_label',   to_jsonb('Area'::text)),
  ('recording.replay_pass',        to_jsonb('Replayed clean — every recorded answer came back the same.'::text)),
  ('recording.replay_fail',        to_jsonb('The walkthrough no longer answers the way it did when it was recorded.'::text)),
  ('recording.replay_empty',       to_jsonb('This walkthrough recorded no backend call, so there is nothing to replay.'::text)),
  ('recording.replay_no_plan',     to_jsonb('That journey has no recorded plan on this database.'::text)),
  ('recording.replay_action',      to_jsonb('Replay'::text)),
  ('recording.step_screen',        to_jsonb('screen'::text)),
  ('recording.step_skipped',       to_jsonb('skipped'::text)),
  ('recording.diverge_missing',    to_jsonb('the answer no longer carries this'::text)),
  ('recording.diverge_extra',      to_jsonb('the answer now carries this and did not before'::text)),
  ('recording.diverge_type',       to_jsonb('the answer changed shape'::text)),
  ('recording.diverge_value',      to_jsonb('the answer changed'::text)),
  ('recording.diverge_length',     to_jsonb('the answer has a different number of rows'::text)),
  ('recording.replay_threw',       to_jsonb('the call itself failed'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. CAPTURE — one batched write, gated on a LIVE TEST SESSION and nothing else.
--
--    The gate is deliberately the session, not a role: Om walks the flow from
--    his customer, supplier, partner and delivery logins, and a capture that
--    only worked for a super-admin would record the one journey nobody needs.
--    With no session this returns in a single STABLE read and writes nothing.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.recording_live_id()
returns bigint
language sql
stable
security definer
set search_path to 'public'
as $$
  select r.id
    from public.test_recording r
   where r.status = 'recording'
     and r.session_id is not null
     and r.session_id = public.test_session_mine()
   limit 1;
$$;

comment on function public.recording_live_id() is
  'CMD #1851 — the walkthrough recording on THIS install''s test session, or NULL. '
  'NULL is the no-session answer too: no session, no recording, no write.';

create or replace function public.recording_capture(p_events jsonb, p_recording bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id bigint; v_n int; v_cap int := 400; v_added int := 0; e jsonb; v_kind text;
  v_uid uuid; v_role text; v_email text;
begin
  v_id := public.recording_live_id();
  if v_id is null then
    -- §6: the no-session path. One read, no write, no row touched.
    return jsonb_build_object('ok', false, 'error', 'no_recording', 'recording', false,
      'message', public.uic('recording.capture_no_session',
        'There is no live test session on this device, so nothing was recorded.'));
  end if;
  if p_recording is not null and p_recording <> v_id then
    return jsonb_build_object('ok', false, 'error', 'not_recording', 'recording', false,
      'message', public.uic('recording.capture_not_live',
        'That walkthrough is not recording any more.'));
  end if;

  select coalesce(max(n),0) into v_n from public.test_recording_step where recording_id = v_id;
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  begin
    v_role  := coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role', 'authenticated');
    v_email := nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'email';
  exception when others then v_role := 'authenticated'; v_email := null; end;

  for e in select * from jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) loop
    exit when v_n >= v_cap;
    v_kind := coalesce(nullif(e->>'kind',''), 'nav');
    v_n := v_n + 1;
    -- WHO was walking is part of the step. A replay that ran as the platform
    -- would call cart_state with no customer and call the difference a
    -- regression; #1851's first run did exactly that.
    insert into public.test_recording_step (recording_id, n, kind, screen, action, detail, ok)
    values (v_id, v_n, v_kind,
            coalesce(e->>'screen',''),
            coalesce(e->>'action',''),
            coalesce(e->'detail','{}'::jsonb)
              || jsonb_build_object('actor', jsonb_strip_nulls(jsonb_build_object(
                   'uid', v_uid, 'role', v_role, 'email', v_email))),
            coalesce((e->>'ok')::boolean, true));
    v_added := v_added + 1;
  end loop;

  return jsonb_build_object('ok', true, 'recording', true, 'recording_id', v_id,
    'added', v_added, 'steps', v_n, 'capped', v_n >= v_cap);
end $$;

comment on function public.recording_capture(jsonb, bigint) is
  'CMD #1851 — append a BATCH of observed steps (screens and RPC calls with their '
  'arguments and the answer they got) to the live walkthrough. Refused, with no '
  'write at all, when this install has no live test session.';

revoke all on function public.recording_capture(jsonb, bigint) from public, anon;
grant execute on function public.recording_capture(jsonb, bigint) to authenticated, service_role;
revoke all on function public.recording_live_id() from public, anon;
grant execute on function public.recording_live_id() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. STATE — what the app is allowed to know about recording. This is what
--    turns the client tap on and off, and what it must send.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.recording_state()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_id bigint; r public.test_recording%rowtype; v_steps int;
begin
  v_id := public.recording_live_id();
  if v_id is null then
    return jsonb_build_object('on', false,
      'label', public.uic('recording.state_idle','Not recording.'));
  end if;
  select * into r from public.test_recording where id = v_id;
  select count(*)::int into v_steps from public.test_recording_step where recording_id = v_id;
  return jsonb_build_object(
    'on', true,
    'recording_id', v_id,
    'label', r.label,
    'steps', v_steps,
    'hint', public.uic('recording.state_live',
      'Recording — every screen you open and every call the app makes is a step.'),
    -- what the client tap obeys. All of it is data: retune without a deploy.
    'capture', jsonb_build_object(
      'flush_ms',  1500,
      'max_batch', 25,
      'max_body',  16384,
      'skip_fns',  (select coalesce(jsonb_agg(distinct fn), '[]'::jsonb)
                      from public.recording_match_rule
                     where enabled and mode = 'skip_step' and fn <> '*')));
end $$;

revoke all on function public.recording_state() from public, anon;
grant execute on function public.recording_state() to authenticated, service_role;

-- The banner the whole app already polls carries it, so no screen needs a
-- second call and no service outside test mode learns anything new.
create or replace function public.test_session_banner()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare s public.test_sessions%rowtype; c public.test_mode_config%rowtype;
        v_uid uuid; v_id bigint; v_owner boolean;
begin
  select * into c from public.test_mode_config where id = 1;
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  -- CMD #1848 — this install's session, by its header. Another device, and
  -- the same login anywhere else, gets on:false.
  v_id := public.test_session_mine();
  if v_id is not null then
    select * into s from public.test_sessions
     where id = v_id and origin = 'human';
  end if;
  if v_id is null or s.id is null then
    return jsonb_build_object('on', false, 'poll_ms', coalesce(c.banner_poll_ms, 20000));
  end if;
  v_owner := (s.started_by = v_uid);
  return jsonb_build_object(
    'on', true,
    'poll_ms', coalesce(c.banner_poll_ms, 20000),
    'session_id', s.id,
    'text',  public.uic('test_session.banner','TEST MODE — nothing here is real'),
    'label', s.label,
    'hint',  public.uic('test_session.banner_hint',''),
    'owner_label', public.uic('test_session.owner_label','Started by') || ' ' ||
                   coalesce(nullif(s.started_by_label,''), 'admin'),
    'ends_label', public.uic('test_session.expiry_label','Auto-ends') || ' ' ||
                  to_char(s.expires_at at time zone 'Asia/Kolkata','DD Mon HH24:MI'),
    'badge', public.uic('test_mode.badge','TEST'),
    'tone', 'danger',
    'is_owner', v_owner,
    'can_end', true,
    'end_action',  public.uic('test_session.end_purge_action','End & purge'),
    'end_confirm', public.uic('test_session.confirm_end_purge',''),
    'end_cancel',  public.uic('test_session.confirm_cancel','Keep testing'),
    -- CMD #1851 — the recording tap reads this and nothing else. Absent block
    -- (no session at all) is the tap's OFF state.
    'recording', public.recording_state());
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE COMPARISON. Every word of a divergence is written here, once.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._recording_mode(p_fn text, p_path text)
returns public.recording_match_rule
language sql
stable
security definer
set search_path to 'public'
as $c1851$
  select r.*
    from public.recording_match_rule r
   where r.enabled
     and (r.fn = p_fn or r.fn = '*')
     and p_path ~ r.path_pattern
   order by (r.fn = '*'), r.priority, r.id
   limit 1;
$c1851$;

create or replace function public._recording_diff(p_fn text, p_path text,
                                                  p_expected jsonb, p_actual jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $c1851$
declare
  v_rule public.recording_match_rule;
  v_out jsonb := '[]'::jsonb;
  v_et text; v_at text; k text; i int; v_len_e int; v_len_a int;
begin
  v_rule := public._recording_mode(p_fn, p_path);
  if v_rule.mode in ('ignore','skip_step') then
    return '[]'::jsonb;
  end if;

  v_et := jsonb_typeof(p_expected);
  v_at := jsonb_typeof(p_actual);

  if p_expected is null and p_actual is null then return '[]'::jsonb; end if;
  if p_expected is null then
    return jsonb_build_array(jsonb_build_object('path', p_path, 'why',
      public.uic('recording.diverge_extra','the answer now carries this and did not before'),
      'expected', null, 'actual', p_actual));
  end if;
  if p_actual is null then
    return jsonb_build_array(jsonb_build_object('path', p_path, 'why',
      public.uic('recording.diverge_missing','the answer no longer carries this'),
      'expected', p_expected, 'actual', null));
  end if;

  if v_et is distinct from v_at then
    return jsonb_build_array(jsonb_build_object('path', p_path, 'why',
      public.uic('recording.diverge_type','the answer changed shape'),
      'expected', to_jsonb(v_et), 'actual', to_jsonb(v_at)));
  end if;

  -- shape mode: the type IS the assertion. A timestamp, an id, a fresh code.
  if v_rule.mode = 'shape' then return '[]'::jsonb; end if;

  if v_et = 'object' then
    for k in select key from jsonb_object_keys(p_expected) key
             union select key from jsonb_object_keys(p_actual) key loop
      v_out := v_out || public._recording_diff(p_fn, p_path || '.' || k,
                          p_expected -> k, p_actual -> k);
    end loop;
    return v_out;
  end if;

  if v_et = 'array' then
    v_len_e := jsonb_array_length(p_expected);
    v_len_a := jsonb_array_length(p_actual);
    if v_len_e <> v_len_a then
      return jsonb_build_array(jsonb_build_object('path', p_path, 'why',
        public.uic('recording.diverge_length','the answer has a different number of rows'),
        'expected', to_jsonb(v_len_e), 'actual', to_jsonb(v_len_a)));
    end if;
    for i in 0 .. greatest(v_len_e - 1, -1) loop
      v_out := v_out || public._recording_diff(p_fn, p_path || '[]',
                          p_expected -> i, p_actual -> i);
    end loop;
    return v_out;
  end if;

  if p_expected is distinct from p_actual then
    return jsonb_build_array(jsonb_build_object('path', p_path, 'why',
      public.uic('recording.diverge_value','the answer changed'),
      'expected', p_expected, 'actual', p_actual));
  end if;
  return '[]'::jsonb;
end $c1851$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE CALL. A recorded step names a function and the arguments it was given;
--    replaying it means calling THAT function with THOSE arguments, coerced to
--    the signature Postgres actually declares. Nothing is simulated.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._recording_call(p_fn text, p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare
  v_oid oid; v_names text[]; v_retset boolean; v_ret oid;
  v_arglist text := ''; v_expr text; v_type text; v_name text; i int;
  v_sql text; v_out jsonb;
begin
  select p.oid, p.proargnames, p.proretset, p.prorettype
    into v_oid, v_names, v_retset, v_ret
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = p_fn
   order by (select count(*) from unnest(coalesce(p.proargnames,'{}'::text[])) a
              where coalesce(p_args,'{}'::jsonb) ? a) desc,
            coalesce(array_length(p.proargnames,1),0)
   limit 1;
  if v_oid is null then
    raise exception 'unknown_function:%', p_fn;
  end if;

  for i in 1 .. coalesce(array_length(v_names,1),0) loop
    v_name := v_names[i];
    continue when v_name is null or v_name = '' or not (coalesce(p_args,'{}'::jsonb) ? v_name);
    -- the declared type of argument i, as Postgres itself declares it
    select format_type(a, null) into v_type
      from unnest((select proargtypes from pg_proc where oid = v_oid)::oid[]) with ordinality u(a, ord)
     where u.ord = i;
    if v_type is null then continue; end if;
    v_expr := case
      when v_type in ('json','jsonb') then format('($1->%L)', v_name)
      when v_type like '%[]' then format(
        '(case when jsonb_typeof($1->%L) = ''array'''
        || ' then (select array_agg(x #>> ''{}'') from jsonb_array_elements($1->%L) x)::%s'
        || ' else ($1->>%L)::%s end)', v_name, v_name, v_type, v_name, v_type)
      else format('(($1->>%L)::%s)', v_name, v_type)
    end;
    v_arglist := v_arglist || case when v_arglist = '' then '' else ', ' end
                 || format('%I := %s', v_name, v_expr);
  end loop;

  if v_retset then
    v_sql := format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I(%s) t',
                    p_fn, v_arglist);
  else
    v_sql := format('select to_jsonb(public.%I(%s))', p_fn, v_arglist);
  end if;
  execute v_sql into v_out using coalesce(p_args, '{}'::jsonb);
  return v_out;
end $c1851$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE REPLAY. Runs the real RPCs, in order, against real rows — and ROLLS
--    EVERY WRITE BACK, the same way c707_fulfil_proof does. It reports which
--    step diverged and how, in the words above; it never guesses.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._recording_replay_plan(p_plan jsonb, p_label text default '')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare
  v_steps jsonb := '[]'::jsonb;
  v_pass int := 0; v_fail int := 0; v_skip int := 0; v_screens int := 0;
  v_first jsonb; v_len int; i int; e jsonb;
  v_fn text; v_actual jsonb; v_diffs jsonb; v_rule public.recording_match_rule;
  v_arule public.recording_match_rule; v_args jsonb; v_key text; v_tok text;
  v_status text; v_why text;
begin
  v_len := jsonb_array_length(coalesce(p_plan,'[]'::jsonb));
  if v_len = 0 then
    return jsonb_build_object('ok', true, 'passed', false, 'empty', true,
      'steps', '[]'::jsonb, 'pass', 0, 'fail', 0, 'skipped', 0,
      'message', public.uic('recording.replay_empty',
        'This walkthrough recorded no backend call, so there is nothing to replay.'));
  end if;

  begin
    -- A walkthrough is only ever recorded inside a TEST SESSION, so a replay
    -- outside one is not the same call: the synthetic markers the session puts
    -- on an order are absent and every one of them reads as a regression. If a
    -- session is live the replay joins it; if none is, it opens one — and the
    -- rollback below takes that away again with everything else.
    select t.token into v_tok from public.test_sessions t
     where t.status = 'live' and t.ended_at is null and now() < t.expires_at
       and coalesce(t.scope,'global') <> 'canary'
     order by t.id desc limit 1;
    if v_tok is null then
      perform set_config('request.jwt.claim.role', 'service_role', true);
      v_tok := public.test_session_start('replay of ' || coalesce(nullif(p_label,''),'a walkthrough'), 1) ->> 'token';
    end if;
    if v_tok is not null then
      perform set_config('request.headers',
        json_build_object('x-medibo-test-session', v_tok)::text, true);
    end if;

    for i in 0 .. v_len - 1 loop
      e := p_plan -> i;
      if coalesce(e->>'kind','nav') <> 'rpc' then
        v_screens := v_screens + 1;
        v_steps := v_steps || jsonb_build_object(
          'n', coalesce((e->>'n')::int, i + 1), 'kind', coalesce(e->>'kind','nav'),
          'label', coalesce(nullif(e->>'action',''), e->>'screen'),
          'status', 'screen', 'why', public.uic('recording.step_screen','screen'));
        continue;
      end if;

      v_fn := coalesce(e->>'fn','');
      v_rule := public._recording_mode(v_fn, '$');
      v_args := coalesce(e->'args','{}'::jsonb);
      -- an argument the rules call per-attempt is minted fresh, never replayed
      for v_key in select jsonb_object_keys(v_args) loop
        v_arule := public._recording_mode(v_fn, '$args.' || v_key);
        if v_arule.mode = 'fresh_uuid' then
          v_args := jsonb_set(v_args, array[v_key], to_jsonb(gen_random_uuid()::text));
        end if;
      end loop;
      if v_fn = '' or v_rule.mode = 'skip_step' then
        v_skip := v_skip + 1;
        v_steps := v_steps || jsonb_build_object(
          'n', coalesce((e->>'n')::int, i + 1), 'kind', 'rpc', 'label', v_fn,
          'status', 'skipped',
          'why', coalesce(nullif(v_rule.note,''), public.uic('recording.step_skipped','skipped')));
        continue;
      end if;

      begin
        -- Replay AS THE WALKER. set_config(..., true) is transaction-local, so
        -- it is undone by the same rollback the writes are.
        if coalesce(e->'actor','{}'::jsonb) <> '{}'::jsonb then
          perform set_config('request.jwt.claims',
            (jsonb_build_object('role', coalesce(e->'actor'->>'role','authenticated'))
             || case when e->'actor'->>'uid' is null then '{}'::jsonb
                     else jsonb_build_object('sub', e->'actor'->>'uid') end
             || case when e->'actor'->>'email' is null then '{}'::jsonb
                     else jsonb_build_object('email', e->'actor'->>'email') end)::text,
            true);
        end if;
        v_actual := public._recording_call(v_fn, v_args);
        v_diffs := public._recording_diff(v_fn, '$', e->'payload', v_actual);
        if jsonb_array_length(v_diffs) = 0 then
          v_status := 'passed'; v_why := ''; v_pass := v_pass + 1;
        else
          v_status := 'failed'; v_fail := v_fail + 1;
          v_why := (v_diffs->0->>'path') || ' — ' || (v_diffs->0->>'why');
        end if;
      exception when others then
        v_status := 'failed'; v_fail := v_fail + 1;
        v_diffs := jsonb_build_array(jsonb_build_object('path', '$', 'why',
          public.uic('recording.replay_threw','the call itself failed'),
          'expected', e->'payload', 'actual', to_jsonb(sqlerrm)));
        v_why := public.uic('recording.replay_threw','the call itself failed') || ': ' || sqlerrm;
      end;

      v_steps := v_steps || jsonb_build_object(
        'n', coalesce((e->>'n')::int, i + 1), 'kind', 'rpc', 'label', v_fn,
        'status', v_status, 'why', v_why,
        'diffs', case when v_status = 'failed' then v_diffs else '[]'::jsonb end);
      if v_status = 'failed' and v_first is null then
        v_first := v_steps -> (jsonb_array_length(v_steps) - 1);
      end if;
    end loop;

    -- Everything this block wrote goes away here. The verdict is in plpgsql
    -- variables, which a rollback does not touch.
    raise exception using errcode = 'ZZ851', message = 'c1851_rollback';
  exception
    when sqlstate 'ZZ851' then null;
    when others then
      v_fail := v_fail + 1;
      v_steps := v_steps || jsonb_build_object('n', 0, 'kind', 'rpc', 'label', p_label,
        'status', 'failed', 'why', sqlerrm, 'diffs', '[]'::jsonb);
      if v_first is null then v_first := v_steps -> (jsonb_array_length(v_steps) - 1); end if;
  end;

  return jsonb_build_object(
    'ok', true,
    'passed', v_fail = 0 and v_pass > 0,
    'pass', v_pass, 'fail', v_fail, 'skipped', v_skip, 'screens', v_screens,
    'steps', v_steps,
    'first_divergence', v_first,
    'message', case when v_fail = 0 and v_pass > 0
      then public.uic('recording.replay_pass','Replayed clean — every recorded answer came back the same.')
      when v_pass = 0 and v_fail = 0
      then public.uic('recording.replay_empty','This walkthrough recorded no backend call, so there is nothing to replay.')
      else public.uic('recording.replay_fail','The walkthrough no longer answers the way it did when it was recorded.')
        || ' ' || coalesce(v_first->>'label','') || ': ' || coalesce(v_first->>'why','') end);
end $c1851$;

create or replace function public._recording_plan_of(p_recording bigint)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $c1851$
  select coalesce(jsonb_agg(jsonb_build_object(
           'n', s.n, 'kind', s.kind, 'screen', s.screen, 'action', s.action,
           'fn', coalesce(s.detail->>'fn',''),
           'args', coalesce(s.detail->'args','{}'::jsonb),
           'actor', coalesce(s.detail->'actor','{}'::jsonb),
           'payload', s.detail->'payload') order by s.n), '[]'::jsonb)
    from public.test_recording_step s
   where s.recording_id = p_recording;
$c1851$;

create or replace function public.recording_replay(p_recording bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare r public.test_recording%rowtype;
begin
  perform public._dev_guard();
  select * into r from public.test_recording where id = p_recording;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_recording',
      'message', public.uic('recording.unknown','That walkthrough no longer exists.'));
  end if;
  return jsonb_build_object('recording_id', p_recording, 'label', r.label)
         || public._recording_replay_plan(public._recording_plan_of(p_recording), r.label);
end $c1851$;

create or replace function public.recording_replay_journey(p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare p public.recording_journey_plan%rowtype;
begin
  perform public._dev_guard();
  select * into p from public.recording_journey_plan where name = p_name;
  if p.name is null then
    return jsonb_build_object('ok', false, 'error', 'no_plan', 'name', p_name,
      'message', public.uic('recording.replay_no_plan',
        'That journey has no recorded plan on this database.'));
  end if;
  return jsonb_build_object('name', p.name, 'area', p.area, 'label', p.label)
         || public._recording_replay_plan(p.plan, p.label);
end $c1851$;

revoke all on function public.recording_replay(bigint) from public, anon;
revoke all on function public.recording_replay_journey(text) from public, anon;
revoke all on function public._recording_call(text, jsonb) from public, anon;
revoke all on function public._recording_replay_plan(jsonb, text) from public, anon;
grant execute on function public.recording_replay(bigint) to service_role;
grant execute on function public.recording_replay_journey(text) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. PROMOTE — the walkthrough becomes a journey, and takes its replayable body
--    with it. required:false is not a nicety: dev_journeys_record promotes a
--    journey to required only after it has come back green TWICE, so a bad
--    recording can never block a command it was made after (§4).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.recording_promote(p_recording bigint, p_title text default null,
                                                    p_area text default 'platform')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare
  r public.test_recording%rowtype;
  v_title text; v_name text; v_steps jsonb; v_asserts jsonb; v_journey jsonb;
  v_url text; v_key text; v_n int; v_rpc int; v_plan jsonb; v_area text;
begin
  perform public._dev_guard();
  select * into r from public.test_recording where id = p_recording;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_recording',
      'message', public.uic('recording.unknown','That walkthrough no longer exists.'));
  end if;
  if r.status = 'recording' then
    return jsonb_build_object('ok', false, 'error', 'still_recording',
      'message', public.uic('recording.stop_first','Stop the walkthrough before turning it into a test.'));
  end if;
  select count(*)::int, count(*) filter (where kind = 'rpc')::int
    into v_n, v_rpc from public.test_recording_step where recording_id = p_recording;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty_recording',
      'message', public.uic('recording.empty','That walkthrough recorded no steps, so there is nothing to assert.'));
  end if;

  v_area  := coalesce(nullif(btrim(p_area),''),'platform');
  v_title := coalesce(nullif(btrim(p_title),''), r.label);
  v_name  := 'rec-' || p_recording || '-' ||
             left(regexp_replace(lower(v_title), '[^a-z0-9]+', '-', 'g'), 40);
  v_name  := btrim(v_name, '-');

  select jsonb_agg(x order by n) into v_steps from (
    select s.n, (s.n || '. ' || coalesce(nullif(s.action,''), s.kind) ||
                 case when coalesce(s.screen,'') <> '' then ' — ' || s.screen else '' end) as x
      from public.test_recording_step s where s.recording_id = p_recording) t;

  -- The assertions are the recording's own facts: every step must still be
  -- reachable in the same order, and every backend answer must still come back
  -- the same, allowing for what the match rules call volatile. Nothing invented.
  select jsonb_agg(a) into v_asserts from (
    select 'The walkthrough still reaches all ' || v_n || ' steps, in this order.' as a
    union all
    select 'All ' || v_rpc || ' recorded backend answers still come back the same.'
     where v_rpc > 0
    union all
    select 'Step ' || s.n || ' (' || coalesce(nullif(s.action,''), s.kind) ||
           case when coalesce(s.screen,'') <> '' then ' — ' || s.screen else '' end ||
           ') no longer fails.'
      from public.test_recording_step s
     where s.recording_id = p_recording and not s.ok
    union all
    select 'What broke here does not come back: ' || r.note
     where r.outcome = 'broke' and coalesce(btrim(r.note),'') <> ''
  ) t;

  -- The plan is copied OUT of the recording, because the recording is purged
  -- with its test session and the journey has to outlive it.
  v_plan := public._recording_plan_of(p_recording);
  insert into public.recording_journey_plan (name, area, recording_id, label, plan)
  values (v_name, v_area, p_recording, v_title, v_plan)
  on conflict (name) do update
    set area = excluded.area, recording_id = excluded.recording_id,
        label = excluded.label, plan = excluded.plan, updated_at = now();

  v_journey := jsonb_build_object(
    'name', v_name,
    'area', v_area,
    'kind', 'browser',   -- dev_journeys.kind is api|browser; a recorded walk is a browser journey
    'steps', coalesce(v_steps,'[]'::jsonb),
    'assertions', coalesce(v_asserts,'[]'::jsonb),
    'plan', v_plan,
    'probe_on', 'branch',
    'required', false,   -- §4 — advisory until it has passed green twice
    'enabled', true);

  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'MEDIBO_DEV_URL';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'MEDIBO_DEV_SERVICE_ROLE_KEY';
  if v_url is null or v_key is null then
    return jsonb_build_object('ok', false, 'error', 'no_control_plane',
      'message', public.uic('recording.no_control_plane',
        'The journey library could not be reached, so nothing was promoted.'),
      'journey', v_journey);
  end if;
  perform net.http_post(
    url := v_url || '/rest/v1/rpc/journey_save',
    headers := jsonb_build_object('Content-Type','application/json','apikey', v_key,
                                  'Authorization','Bearer ' || v_key),
    body := jsonb_build_object('p', v_journey),
    timeout_milliseconds := 8000);

  update public.test_recording
     set status = 'promoted', promoted_at = now(), journey_name = v_name,
         journey_area = v_area,
         artifacts = artifacts || jsonb_build_object('journey', v_journey - 'plan')
   where id = p_recording;

  return jsonb_build_object('ok', true, 'recording_id', p_recording,
    'journey_name', v_name, 'steps', v_n, 'rpc_steps', v_rpc,
    'journey', v_journey - 'plan', 'required', false,
    'message', public.uic('recording.promoted',
      'This walkthrough is now a permanent journey. It runs with every command in its area from here on.'));
end $c1851$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. THE PROBE. A recorded journey is named rec-<recording>-<slug>, and that
--     is all the dispatcher needs: no generated function per recording, and no
--     new branch in the 37 KB dev_journey_probe — the by-convention hook it
--     already consults first answers for the whole family.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.recording_journey_probe(p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare v_res jsonb; p public.recording_journey_plan%rowtype;
begin
  select * into p from public.recording_journey_plan where name = p_name;
  if p.name is null then
    return jsonb_build_object('status','skipped','evidence', jsonb_build_object(
      'db_proof', public.uic('recording.replay_no_plan',
        'That journey has no recorded plan on this database.') || ' (' || p_name || ')'));
  end if;
  v_res := public._recording_replay_plan(p.plan, p.label);
  return jsonb_build_object(
    'status', case when v_res->>'passed' = 'true' then 'passed' else 'failed' end,
    'evidence', jsonb_build_object(
      'db_proof', coalesce(v_res->>'message','') ||
        ' | ' || coalesce(v_res->>'pass','0') || ' answers matched, ' ||
        coalesce(v_res->>'fail','0') || ' diverged, ' ||
        coalesce(v_res->>'skipped','0') || ' skipped by rule, ' ||
        coalesce(v_res->>'screens','0') || ' screens — replayed against real rows and rolled back',
      'first_divergence', v_res->'first_divergence'));
end $c1851$;

create or replace function public._dev_journey_by_convention(p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare
  v_fn text := '_journey_' || regexp_replace(lower(coalesce(p_name,'')), '[^a-z0-9]+', '_', 'g');
  v_out jsonb;
begin
  -- CMD #1851 — a recorded walkthrough is a journey with no function of its
  -- own: its body is the plan promote stored, and one prober replays them all.
  if coalesce(p_name,'') ~ '^rec-[0-9]+-' then
    return public.recording_journey_probe(p_name);
  end if;
  -- the transformed name must be a plain identifier, and the function must
  -- actually exist; anything else falls through to the hand-written branches.
  if v_fn !~ '^_journey_[a-z0-9_]+$' then return null; end if;
  if to_regprocedure('public.' || quote_ident(v_fn) || '()') is null then return null; end if;
  execute format('select public.%I()', v_fn) into v_out;
  return v_out;
end $c1851$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. ENDING THE SESSION OFFERS THE JOURNEY (§3). The offer is the BACKEND's:
--     its title, its body, its default name and its area all arrive with the
--     end result, so the sheet that shows it decides nothing.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.recording_offer(p_session bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $c1851$
declare r public.test_recording%rowtype; v_n int; v_rpc int;
begin
  select * into r from public.test_recording
   where (p_session is null or session_id = p_session)
     and status in ('recording','stopped')
   order by id desc limit 1;
  if r.id is null then return jsonb_build_object('has', false); end if;
  select count(*)::int, count(*) filter (where kind='rpc')::int
    into v_n, v_rpc from public.test_recording_step where recording_id = r.id;
  if v_n = 0 then return jsonb_build_object('has', false); end if;
  return jsonb_build_object(
    'has', true,
    'recording_id', r.id,
    'title',  public.uic('recording.offer_title','Keep this walkthrough as a test?'),
    'body',   public.uic('recording.offer_body',''),
    'save',   public.uic('recording.offer_save','Save as journey'),
    'discard',public.uic('recording.offer_discard','Discard'),
    'name_label', public.uic('recording.offer_name_label','Name'),
    'area_label', public.uic('recording.offer_area_label','Area'),
    'default_name', r.label,
    'default_area', coalesce(nullif(r.journey_area,''),'platform'),
    'steps', v_n, 'rpc_steps', v_rpc,
    'count_label', v_n || ' steps, ' || v_rpc || ' of them a backend answer');
end $c1851$;

revoke all on function public.recording_offer(bigint) from public, anon;
grant execute on function public.recording_offer(bigint) to authenticated, service_role;

create or replace function public.test_session_end(p_session bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare v_id bigint; v_uid uuid; v_kind text; v_mine boolean; v_offer jsonb;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_id := coalesce(p_session, public.test_session_mine(), public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  v_kind := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  -- Was it THIS install's session? Then the client drops its token too.
  v_mine := coalesce(public.test_session_mine() = v_id, false);
  -- CMD #1851 — read the offer BEFORE the session closes: recording_offer is
  -- scoped to the session, and after the update there is nothing to offer.
  v_offer := public.recording_offer(v_id);
  -- A walkthrough left running is stopped with the session that owns it, so the
  -- offer it produced is a stopped recording that promote will accept.
  update public.test_recording
     set status = 'stopped', stopped_at = coalesce(stopped_at, now())
   where session_id = v_id and status = 'recording';
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         ended_by = coalesce(ended_by, v_uid),
         ended_kind = coalesce(ended_kind, v_kind)
   where id = v_id;
  return jsonb_build_object('ok',true,'session_id',v_id,
    'clear_token', v_mine,
    'residue', public.test_session_residue(v_id),
    'recording_offer', v_offer,
    'message', public.uic('test_session.ended','Test mode is OFF.'));
end $c1851$;

-- CMD #1851 — the Chaos lab row gains a Replay affordance. Everything about
-- it (whether it is offered, its label, why it is not) is decided here.
create or replace function public.chaos_home()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare
  v_mode boolean; v_sid bigint; v_slabel text; v_sexp timestamptz;
  v_run public.chaos_run%rowtype;
  v_scen jsonb; v_recs jsonb; v_live public.test_recording%rowtype;
  v_live_steps jsonb; v_live_n int; v_gaps jsonb; v_open int;
  v_can_start boolean; v_start_why text;
begin
  perform public._dev_guard();
  select enabled into v_mode from public.test_mode_config where id = 1;
  v_mode := coalesce(v_mode,false);
  v_sid := public.test_session_live_id();
  if v_sid is not null then
    select label, expires_at into v_slabel, v_sexp from public.test_sessions where id = v_sid;
  end if;

  if p_run is null then
    select * into v_run from public.chaos_run order by id desc limit 1;
  else
    select * into v_run from public.chaos_run where id = p_run;
  end if;

  select jsonb_agg(jsonb_build_object(
           'key', s.key, 'label', s.label, 'blurb', s.blurb,
           'family_label', s.family_label, 'expect_label', s.expect_label,
           'verdict_label', case r.verdict
                              when 'passed'  then 'Degraded safely'
                              when 'failed'  then 'Broke'
                              when 'skipped' then 'Skipped'
                              else 'Never run' end,
           'verdict_tone',  case r.verdict
                              when 'passed'  then 'success'
                              when 'failed'  then 'danger'
                              when 'skipped' then 'neutral'
                              else 'neutral' end,
           'has_result',    (r.id is not null),
           'duration_label', case when r.id is null then ''
                                  when r.duration_ms < 1000 then r.duration_ms || ' ms'
                                  else round(r.duration_ms / 1000.0, 1) || ' s' end,
           'summary', coalesce(r.summary,''),
           'evidence', coalesce((select jsonb_agg(jsonb_build_object(
                                   'label', replace(e.key,'_',' '), 'value', e.value #>> '{}')
                                   order by e.key)
                                 from jsonb_each(coalesce(r.evidence,'{}'::jsonb)) e), '[]'::jsonb),
           'gap_label', case when r.gap_id is not null
                             then 'Gap #' || r.gap_id || ' filed' else '' end)
           order by s.sort_order, s.key)
    into v_scen
    from public.chaos_scenario s
    left join lateral (select * from public.chaos_result cr
                        where cr.run_id = v_run.id and cr.scenario_key = s.key
                        order by cr.id desc limit 1) r on true
   where s.is_active;

  select * into v_live from public.test_recording where status = 'recording' limit 1;
  if v_live.id is not null then
    select count(*)::int into v_live_n from public.test_recording_step where recording_id = v_live.id;
    select jsonb_agg(jsonb_build_object(
             'n', s.n,
             'label', coalesce(nullif(s.action,''), s.kind),
             'sub', coalesce(nullif(s.screen,''),''),
             'tone', case when s.ok then 'neutral' else 'danger' end)
             order by s.n desc)
      into v_live_steps
      from (select * from public.test_recording_step
             where recording_id = v_live.id order by n desc limit 12) s;
  end if;

  v_can_start := v_mode and v_sid is not null and v_live.id is null;
  v_start_why := case
    when not v_mode then 'Test mode is off. A walkthrough is only ever recorded in the synthetic lane.'
    when v_sid is null then 'No test session is live. Start one in Test mode first.'
    when v_live.id is not null then 'A walkthrough is already recording.'
    else '' end;

  select jsonb_agg(jsonb_build_object(
           'id', t.id, 'label', t.label,
           'sub', to_char(t.started_at at time zone 'Asia/Kolkata','DD Mon HH24:MI')
                  || ' IST · ' || t.started_by_label,
           'chip', case t.status
                     when 'recording' then 'Recording'
                     when 'promoted'  then 'Permanent test'
                     else case t.outcome when 'broke' then 'Something broke' else 'Clean run' end end,
           'chip_tone', case t.status
                     when 'recording' then 'brand'
                     when 'promoted'  then 'success'
                     else case t.outcome when 'broke' then 'danger' else 'neutral' end end,
           'steps_label', (select count(*) from public.test_recording_step p where p.recording_id = t.id)
                          || case when (select count(*) from public.test_recording_step p where p.recording_id = t.id) = 1
                                  then ' step' else ' steps' end,
           'note', coalesce(t.note,''),
           'promote', jsonb_build_object(
             'can', (t.status = 'stopped'
                     and exists (select 1 from public.test_recording_step p where p.recording_id = t.id)),
             'label', 'Make this a permanent test',
             'disabled_reason', case
               when t.status = 'recording' then 'Stop the walkthrough first.'
               when t.status = 'promoted' then ''
               when not exists (select 1 from public.test_recording_step p where p.recording_id = t.id)
                 then 'This walkthrough recorded no steps.'
               else '' end),
           'journey_label', case when t.journey_name is null then ''
                                 else 'Journey ' || t.journey_name end,
           -- CMD #1851 — a walkthrough that recorded a backend answer can be
           -- replayed. Whether it can, and what the button says, are both here.
           'replay', jsonb_build_object(
             'can', exists (select 1 from public.test_recording_step p
                             where p.recording_id = t.id and p.kind = 'rpc'),
             'label', public.uic('recording.replay_action','Replay'),
             'disabled_reason', case
               when exists (select 1 from public.test_recording_step p
                             where p.recording_id = t.id and p.kind = 'rpc') then ''
               else public.uic('recording.replay_empty',
                 'This walkthrough recorded no backend call, so there is nothing to replay.')
               end))
           order by t.id desc)
    into v_recs
    from (select * from public.test_recording order by id desc limit 20) t;

  select count(*)::int into v_open from public.feature_gaps
   where source in ('chaos','recording') and status = 'open';
  select jsonb_agg(jsonb_build_object(
           'id', g.id, 'title', g.title,
           'sub', coalesce(g.evidence,''),
           'chip', case g.source when 'chaos' then 'Chaos drill' else 'Recorded walkthrough' end,
           'chip_tone', case g.source when 'chaos' then 'danger' else 'info' end)
           order by g.id desc)
    into v_gaps
    from (select * from public.feature_gaps
           where source in ('chaos','recording') and status = 'open'
           order by id desc limit 10) g;

  return jsonb_build_object(
    'ok', true, 'has', true,
    'title', 'Chaos & recording',
    'subtitle', 'The failures that actually bite, reproduced on demand — and Om''s own walkthroughs turned into permanent tests.',
    'test_mode', jsonb_build_object(
      'on', v_mode,
      'label', case when v_mode then 'Test mode is ON' else 'Test mode is OFF' end,
      'tone', case when v_mode then 'success' else 'warning' end,
      'sub', case when v_mode
                  then 'Everything below runs in the synthetic lane and is purged with the session.'
                  else 'Turn test mode on before running anything here.' end),
    'session', jsonb_build_object(
      'has', v_sid is not null,
      'label', case when v_sid is null then 'No test session is live'
                    else 'Session: ' || coalesce(v_slabel,'') end,
      'sub', case when v_sid is null then 'A chaos run opens its own.'
                  else 'Expires ' || to_char(v_sexp at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST' end),
    'run', jsonb_build_object(
      'has', v_run.id is not null,
      'id', v_run.id,
      'label', coalesce(v_run.label,''),
      'chip', case when v_run.id is null then 'Never run'
                   when v_run.status = 'running' then 'Running'
                   when v_run.failed > 0 then v_run.failed || ' broke'
                   else 'All ' || v_run.passed || ' degraded safely' end,
      'chip_tone', case when v_run.id is null then 'neutral'
                        when v_run.status = 'running' then 'info'
                        when v_run.failed > 0 then 'danger' else 'success' end,
      'counts_label', case when v_run.id is null then ''
                           else v_run.passed || ' safe · ' || v_run.failed || ' broke · '
                                || v_run.skipped || ' skipped' end,
      'sub', case when v_run.id is null then ''
                  else 'Run #' || v_run.id || ' · '
                       || to_char(v_run.started_at at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST'
                       || case when v_run.gaps_written > 0
                               then ' · ' || v_run.gaps_written || ' gap(s) filed' else '' end end),
    'action', jsonb_build_object(
      'key', 'run_all',
      'label', 'Run every scenario',
      'tone', 'brand',
      'enabled', v_mode,
      'disabled_reason', case when v_mode then '' else 'Test mode is off.' end),
    'scenarios', coalesce(v_scen, '[]'::jsonb),
    'scenarios_empty', 'No chaos scenario is registered yet.',
    'recording', jsonb_build_object(
      'title', 'Recorded walkthroughs',
      'blurb', 'Record yourself using the app. When something breaks, one tap turns that exact walk into a permanent test.',
      'live', jsonb_build_object(
        'has', v_live.id is not null,
        'id', v_live.id,
        'label', coalesce(v_live.label,''),
        'step_label', case when v_live.id is null then ''
                           when coalesce(v_live_n,0) = 1 then '1 step so far'
                           else coalesce(v_live_n,0) || ' steps so far' end,
        'steps', coalesce(v_live_steps, '[]'::jsonb),
        'steps_empty', 'Walk the app — every screen you open lands here.'),
      'start', jsonb_build_object('label','Start recording','tone','brand',
                                  'enabled', v_can_start, 'disabled_reason', v_start_why),
      'stop', jsonb_build_object('label','Stop','tone','neutral',
                                 'enabled', v_live.id is not null),
      'broke_label', 'Stop — something broke',
      'rows', coalesce(v_recs, '[]'::jsonb),
      'empty_label', 'Nothing recorded yet.'),
    'gaps', jsonb_build_object(
      'label', case when v_open = 1 then '1 open finding' else v_open || ' open findings' end,
      'rows', coalesce(v_gaps, '[]'::jsonb),
      'empty_label', 'No chaos or walkthrough has filed a finding.'),
    'footnote', 'Chaos artifacts and recorded steps are stored with the run and purged with the session. A failure files a gap through the same door every other source uses.');
end 
$c1851$;

-- End & purge is the button Om actually uses, so it offers the journey too.
-- The offer is read BEFORE anything is ended, and a walkthrough still running
-- is stopped with the session that owns it. Purge does not touch the recording
-- tables, so the offer stays answerable after the wipe.
create or replace function public.test_session_end_purge(p_session bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare v_id bigint; v_purge jsonb; v_uid uuid; v_kind text; v_mine boolean; v_offer jsonb;
begin
  v_id := coalesce(p_session, public.test_session_mine());
  if v_id is null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  if not (public._test_session_participant(v_id) or public._test_guard()) then
    return jsonb_build_object('ok',false,'error','not_owner',
      'message', public.uic('test_session.not_owner',
        'Only the device that started this session, or an admin, can end it.'));
  end if;

  v_kind := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  v_mine := coalesce(public.test_session_mine() = v_id, false);
  -- CMD #1851 — before anything closes.
  v_offer := public.recording_offer(v_id);
  update public.test_recording
     set status = 'stopped', stopped_at = coalesce(stopped_at, now())
   where session_id = v_id and status = 'recording';
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         ended_by = coalesce(ended_by, v_uid),
         ended_kind = coalesce(ended_kind, v_kind)
   where id = v_id;

  perform set_config('request.jwt.claim.role', 'service_role', true);
  v_purge := public.test_session_purge(v_id, 20000);

  return jsonb_build_object('ok', coalesce((v_purge->>'ok')::boolean, false),
    'session_id', v_id,
    'ended', true,
    'clear_token', v_mine,
    'recording_offer', v_offer,
    'purge', v_purge,
    'done', coalesce((v_purge->>'done')::boolean, false),
    'message', case when coalesce((v_purge->>'done')::boolean, false)
      then public.uic('test_session.end_purged','Test session ended and its rows purged.')
      else public.uic('test_session.end_purge_partial','Session ended; the purge is still running — tap again to finish.') end);
end $c1851$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. SEEDING A DATABASE THAT DID NOT DO THE WALKING.
--     A build branch is a schema restore with no rows, so a recorded journey
--     whose plan lives in production has nothing to replay there and reports
--     `skipped` rather than pretending. This is the door the plan comes back
--     through: the library holds the same plan (dev_journeys.plan), and one
--     call puts it on the database that is about to be probed.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.recording_plan_import(p_name text, p_plan jsonb,
                                                        p_area text default 'platform',
                                                        p_label text default '')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare v_n int;
begin
  perform public._dev_guard();
  v_n := jsonb_array_length(coalesce(p_plan,'[]'::jsonb));
  if coalesce(p_name,'') !~ '^rec-[0-9]+-' or v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_a_recorded_journey');
  end if;
  insert into public.recording_journey_plan (name, area, label, plan)
  values (p_name, coalesce(nullif(btrim(p_area),''),'platform'),
          coalesce(nullif(btrim(p_label),''), p_name), p_plan)
  on conflict (name) do update
    set area = excluded.area, label = excluded.label,
        plan = excluded.plan, updated_at = now();
  return jsonb_build_object('ok', true, 'name', p_name, 'steps', v_n);
end $c1851$;

revoke all on function public.recording_plan_import(text, jsonb, text, text) from public, anon;
grant execute on function public.recording_plan_import(text, jsonb, text, text) to service_role;
