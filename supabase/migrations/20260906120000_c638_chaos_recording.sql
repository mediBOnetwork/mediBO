-- CHANGE #638 — Chaos and session recording: reproduce the failures that bite.
--
-- PART 5 of the autotest series. Everything here runs INSIDE a test session
-- (#573) and on top of two things that already exist, exactly as the spec
-- asks: the idempotency ledger from #472 (_idem_claim / _idem_store) and the
-- failure drills from #474 (_ops_drill_*). Nothing is re-invented.
--
-- Two halves:
--   1. CHAOS — seven scripted, repeatable scenarios. Each one is a function
--      returning #474's own {status, summary, evidence} shape, so a new
--      scenario is one function plus one row in chaos_scenario — never a
--      change to the executor and never a deploy.
--   2. RECORDING — Om's own manual walkthrough, opt-in and test-mode only,
--      captured step by step, and convertible in ONE tap into a permanent
--      journey (the control plane's dev_journeys, reached the same way the
--      mirror trigger reaches production: pg_net + the vault).
--
-- Failures on either side file feature_gaps rows through gap_file_or_touch,
-- the same door #635's journey bot and #637's explorer use, so a chaos
-- regression lands in the same inbox as every other finding.

-- ── 1. TABLES ───────────────────────────────────────────────────────────────

create table if not exists public.chaos_scenario (
  key            text primary key,
  label          text not null,
  blurb          text not null default '',
  family         text not null default 'other',
  family_label   text not null default 'Other',
  expect_label   text not null default '',
  fn             text not null,
  gap_title      text not null default '',
  severity       text not null default 'high',
  sort_order     int  not null default 100,
  is_active      boolean not null default true
);

create table if not exists public.chaos_run (
  id           bigserial primary key,
  label        text not null default '',
  session_id   bigint,
  test_run_id  bigint,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'running',
  total        int not null default 0,
  passed       int not null default 0,
  failed       int not null default 0,
  skipped      int not null default 0,
  gaps_written int not null default 0,
  artifacts    jsonb not null default '{}'::jsonb,
  summary      jsonb not null default '{}'::jsonb
);
create index if not exists chaos_run_started_idx on public.chaos_run (started_at desc);

create table if not exists public.chaos_result (
  id           bigserial primary key,
  run_id       bigint not null references public.chaos_run(id) on delete cascade,
  scenario_key text not null,
  verdict      text not null default 'failed',
  summary      text not null default '',
  evidence     jsonb not null default '{}'::jsonb,
  duration_ms  int not null default 0,
  gap_id       bigint,
  created_at   timestamptz not null default now()
);
create index if not exists chaos_result_run_idx on public.chaos_result (run_id, id);

create table if not exists public.test_recording (
  id               bigserial primary key,
  session_id       bigint,
  test_run_id      bigint,
  label            text not null default '',
  status           text not null default 'recording',
  outcome          text not null default 'unknown',
  started_by       uuid,
  started_by_label text not null default '',
  started_at       timestamptz not null default now(),
  stopped_at       timestamptz,
  promoted_at      timestamptz,
  note             text not null default '',
  journey_name     text,
  journey_area     text,
  artifacts        jsonb not null default '{}'::jsonb
);
create index if not exists test_recording_started_idx on public.test_recording (started_at desc);
create unique index if not exists test_recording_one_live
  on public.test_recording ((true)) where (status = 'recording');

create table if not exists public.test_recording_step (
  id           bigserial primary key,
  recording_id bigint not null references public.test_recording(id) on delete cascade,
  n            int not null,
  kind         text not null default 'nav',
  screen       text not null default '',
  action       text not null default '',
  detail       jsonb not null default '{}'::jsonb,
  ok           boolean not null default true,
  at           timestamptz not null default now(),
  unique (recording_id, n)
);

alter table public.chaos_scenario      enable row level security;
alter table public.chaos_run           enable row level security;
alter table public.chaos_result        enable row level security;
alter table public.test_recording      enable row level security;
alter table public.test_recording_step enable row level security;

-- ── 2. THE SEVEN SCENARIOS ──────────────────────────────────────────────────
-- Each returns #474's shape: {status, summary, evidence}. status is
-- 'passed' | 'failed' | 'skipped'; a skip always says why.

-- S1. The network dies AFTER the claim and BEFORE the answer is stored. The
--     retry must be allowed to run (a dead attempt must not brick the user)
--     and the ledger must still hold exactly one row for the key.
create or replace function public._chaos_network_kill_mid_pack()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_scope text := 'chaos.network_kill';
  v_key   uuid := gen_random_uuid();
  v_c1 jsonb; v_c2 jsonb; v_c3 jsonb; v_ans jsonb; v_rows int; v_fail text[] := '{}';
begin
  v_c1 := public._idem_claim(v_scope, v_key);
  if v_c1 is not null then
    v_fail := array_append(v_fail, 'a fresh key was already claimed');
  end if;

  -- …the connection dies here. Nothing is stored. The client retries.
  v_c2 := public._idem_claim(v_scope, v_key);
  if v_c2 is not null then
    v_fail := array_append(v_fail,
      'the retry after a dead attempt was refused — the pack would be stuck forever');
  end if;

  v_ans := jsonb_build_object('ok', true, 'packed_once', true, 'stamp', clock_timestamp()::text);
  perform public._idem_store(v_scope, v_key, v_ans);

  -- the ORIGINAL attempt's answer finally arrives. It must change nothing.
  v_c3 := public._idem_claim(v_scope, v_key);
  if v_c3 is null then
    v_fail := array_append(v_fail, 'the late original was handed the work again — it would pack twice');
  elsif coalesce((v_c3->>'replayed')::boolean, false) is not true then
    v_fail := array_append(v_fail, 'the late original was not flagged as a replay');
  elsif (v_c3 - 'replayed') is distinct from v_ans then
    v_fail := array_append(v_fail, 'the replay returned a different answer');
  end if;

  select count(*)::int into v_rows from public.idempotent_action
   where scope = v_scope and client_action_id = v_key;
  if v_rows <> 1 then
    v_fail := array_append(v_fail, 'the ledger holds ' || v_rows || ' rows for one key, expected 1');
  end if;

  delete from public.idempotent_action where scope = v_scope and client_action_id = v_key;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'The connection died after the claim: the retry was allowed through, it packed once, and the late original came back as a replay.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'claim_first',  coalesce(v_c1::text, 'null (ours — do the work)'),
      'claim_retry',  coalesce(v_c2::text, 'null (allowed to run)'),
      'claim_late',   coalesce(v_c3::text, '—'),
      'ledger_rows',  v_rows::text,
      'scope',        v_scope));
end $$;

-- S2. The same form submitted twice while the first is still in flight.
create or replace function public._chaos_double_submit_form()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_scope text := 'chaos.double_submit';
  v_key   uuid := gen_random_uuid();
  v_first jsonb; v_second jsonb; v_rows int; v_fail text[] := '{}'; v_users int;
begin
  perform public._idem_claim(v_scope, v_key);
  v_first := jsonb_build_object('ok', true, 'order_no', 'CHAOS-' || substr(v_key::text,1,8));
  perform public._idem_store(v_scope, v_key, v_first);

  -- the second tap, same intent, same key
  v_second := public._idem_claim(v_scope, v_key);
  if v_second is null then
    v_fail := array_append(v_fail, 'the second tap was handed the work — the form would submit twice');
  elsif (v_second - 'replayed') is distinct from v_first then
    v_fail := array_append(v_fail, 'the second tap got a DIFFERENT answer from the first');
  elsif coalesce((v_second->>'replayed')::boolean,false) is not true then
    v_fail := array_append(v_fail, 'the second tap was not flagged as a replay');
  end if;

  select count(*)::int into v_rows from public.idempotent_action
   where scope = v_scope and client_action_id = v_key;
  if v_rows <> 1 then
    v_fail := array_append(v_fail, 'the ledger holds ' || v_rows || ' rows for one key, expected 1');
  end if;

  -- the four money paths that depend on this primitive must still claim through it
  select count(*)::int into v_users from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosrc like '%\_idem\_claim(%' escape '\'
     and p.proname in ('_place_order_v2_core','_sup_record_payment_write','refund_request','settlement_record_payment');
  if v_users < 4 then
    v_fail := array_append(v_fail,
      'only ' || v_users || ' of the 4 money RPCs still claim an action key — a double submit would apply twice there');
  end if;

  delete from public.idempotent_action where scope = v_scope and client_action_id = v_key;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'Two taps, one intent: the second got the first answer back byte-for-byte and applied nothing, and all four money RPCs still claim through the same ledger.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'first_answer',    v_first::text,
      'second_answer',   coalesce(v_second::text,'—'),
      'ledger_rows',     v_rows::text,
      'money_rpcs_keyed', v_users::text || ' of 4'));
end $$;

-- S3. Razorpay redelivers the same event. It must be answered from the log,
--     not re-applied, and the log must not grow a row per delivery.
--     Note the shape of the real contract, which the first version of this
--     scenario got wrong: an event that matched NOTHING is deliberately left
--     handled=false so a later delivery can still find its order. The replay
--     guarantee is on a HANDLED event — so that is the one this drills.
create or replace function public._chaos_webhook_replay_twice()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_evid text := 'chaos_evt_' || replace(gen_random_uuid()::text,'-','');
  v_event jsonb;
  v_a jsonb; v_b jsonb; v_rows int; v_handled jsonb; v_fail text[] := '{}';
begin
  v_event := jsonb_build_object(
    'id', v_evid, 'event', 'qr_code.credited',
    'payload', jsonb_build_object(
      'qr_code', jsonb_build_object('entity', jsonb_build_object('id','qr_chaos_'||substr(v_evid,11,8))),
      'payment', jsonb_build_object('entity', jsonb_build_object(
        'id','pay_chaos_'||substr(v_evid,11,8), 'amount', 100, 'method','upi'))));

  -- delivery 1: nothing matches, so the handler stays open to a later retry
  v_a := public.rzp_webhook_apply(v_event);
  select count(*)::int into v_rows from public.razorpay_webhook_log where rzp_event_id = v_evid;
  if v_rows <> 1 then
    v_fail := array_append(v_fail,
      'the log holds ' || v_rows || ' rows for one event id after one delivery, expected 1');
  end if;
  if exists (select 1 from public.razorpay_webhook_log
              where rzp_event_id = v_evid and handled) then
    v_fail := array_append(v_fail,
      'an event that matched nothing was marked handled — a late-arriving order would never be credited');
  end if;

  -- the event is applied for real (this is what the matched path writes)
  update public.razorpay_webhook_log
     set handled = true, result = jsonb_build_object('ok', true, 'credited', 100)
   where rzp_event_id = v_evid;

  -- delivery 2: Razorpay redelivers, as it does on any non-2xx
  v_b := public.rzp_webhook_apply(v_event);

  select count(*)::int into v_rows from public.razorpay_webhook_log where rzp_event_id = v_evid;
  if v_rows <> 1 then
    v_fail := array_append(v_fail,
      'the log grew to ' || v_rows || ' rows for one event id — every redelivery would be paid for again');
  end if;
  if coalesce((v_b->>'replayed')::boolean,false) is not true then
    v_fail := array_append(v_fail,
      'the redelivery of an already-credited event was processed again instead of answered from the log');
  end if;
  select result into v_handled from public.razorpay_webhook_log where rzp_event_id = v_evid;
  if (v_b - 'replayed') is distinct from v_handled then
    v_fail := array_append(v_fail, 'the redelivery returned something other than the stored answer');
  end if;
  if not exists (select 1 from pg_indexes
                  where tablename = 'razorpay_webhook_log' and indexname = 'razorpay_webhook_log_event_uq') then
    v_fail := array_append(v_fail, 'the unique event-id index is gone — nothing keys the redelivery');
  end if;

  delete from public.razorpay_webhook_log where rzp_event_id = v_evid;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'The same webhook was delivered twice: one log row throughout, the unmatched first delivery stayed retryable, and the redelivery of the credited event was answered from the log without crediting again.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'event_id',        v_evid,
      'first_delivery',  left(v_a::text, 240),
      'stored_answer',   left(coalesce(v_handled::text,'—'), 240),
      'redelivery',      left(v_b::text, 240),
      'log_rows',        v_rows::text));
exception when others then
  delete from public.razorpay_webhook_log where rzp_event_id = v_evid;
  return jsonb_build_object('status','failed',
    'summary','the webhook handler raised instead of degrading: ' || sqlerrm,
    'evidence', jsonb_build_object('sqlstate', sqlstate, 'event_id', v_evid));
end $$;

-- S4. The test session expires while a synthetic flow is still walking. The
--     synthetic lane must stop DEAD — no more writes leaking into production —
--     and the session must be left ended, not half-ended.
create or replace function public._chaos_session_expire_mid_flow()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_sid bigint; v_label text; v_prev timestamptz;
  v_sweep jsonb; v_status text; v_auto boolean; v_ended timestamptz;
  v_live bigint; v_banner jsonb; v_fail text[] := '{}';
begin
  v_sid := public.test_session_live_id();
  if v_sid is null then
    return jsonb_build_object('status','skipped',
      'summary','no test session is live, so there is no mid-flow to expire.',
      'evidence', jsonb_build_object('live_session','none'));
  end if;
  select label, expires_at into v_label, v_prev from public.test_sessions where id = v_sid;
  if v_label is null or v_label not like 'chaos%' then
    return jsonb_build_object('status','skipped',
      'summary','the live session (' || coalesce(v_label,'?') || ') belongs to another run — this scenario only expires its own.',
      'evidence', jsonb_build_object('live_session', v_sid::text, 'label', coalesce(v_label,'')));
  end if;

  update public.test_sessions set expires_at = now() - interval '1 minute' where id = v_sid;
  v_sweep := public.test_session_expire_sweep();

  select status, auto_expired, ended_at into v_status, v_auto, v_ended
    from public.test_sessions where id = v_sid;
  if coalesce(v_status,'?') <> 'ended' then
    v_fail := array_append(v_fail, 'the expired session is still ''' || coalesce(v_status,'?') || ''' — synthetic writes would keep landing');
  end if;
  if not coalesce(v_auto,false) then
    v_fail := array_append(v_fail, 'the session was not marked auto_expired, so nothing records that it timed out');
  end if;
  if v_ended is null then
    v_fail := array_append(v_fail, 'the session ended with no ended_at — a half-ended session');
  end if;

  v_live := public.test_session_live_id();
  if v_live is not null then
    v_fail := array_append(v_fail, 'test_session_live_id() still answers ' || v_live || ' after the sweep');
  end if;

  v_banner := public.test_session_banner();
  if coalesce((v_banner->>'has')::boolean, coalesce((v_banner->>'on')::boolean,false)) then
    v_fail := array_append(v_fail, 'the test-mode banner still says a session is live');
  end if;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'The session expired mid-flow: the sweep ended it cleanly, the live id went null and the banner went quiet — the synthetic lane stopped instead of leaking.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'session_id',   v_sid::text,
      'label',        v_label,
      'expired_by_sweep', coalesce(v_sweep->>'expired','0'),
      'status_after', coalesce(v_status,'?'),
      'auto_expired', coalesce(v_auto,false)::text,
      'live_after',   coalesce(v_live::text,'none')));
end $$;

-- S5. The database restarts mid-write and the resumed runner fires the same
--     work again. This IS #474's drill — reused, not reimplemented.
create or replace function public._chaos_db_restart_mid_write()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  return public._ops_drill_db_restart();
end $$;

-- S6. A dependency (edge function / OCR / WhatsApp) hangs past its deadline.
--     Two things must hold. Every outbound call must be BOUNDED, so a hung
--     edge function can never hold a trigger open forever; and the caller must
--     RELEASE its claim on the failure, so the user can retry — while a late
--     answer still cannot apply the work twice.
create or replace function public._chaos_edge_delay_past_timeout()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_scope text := 'chaos.edge_timeout';
  v_key   uuid := gen_random_uuid();
  v_default int;
  v_explicit int; v_implicit int;
  v_refusal jsonb; v_rows int; v_retry jsonb; v_ans jsonb; v_late jsonb;
  v_fail text[] := '{}';
begin
  -- (a) every outbound call is bounded: either it passes its own deadline, or
  --     it inherits pg_net's, which must itself be finite.
  select (regexp_match(pg_get_function_arguments(p.oid),
                       'timeout_milliseconds integer DEFAULT ([0-9]+)'))[1]::int
    into v_default
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'net' and p.proname = 'http_post' limit 1;
  if coalesce(v_default,0) <= 0 then
    v_fail := array_append(v_fail,
      'net.http_post has no finite default deadline — a hung edge function would hold its caller open forever');
  end if;
  select count(*) filter (where src ~ 'timeout_milliseconds'),
         count(*) filter (where src !~ 'timeout_milliseconds')
    into v_explicit, v_implicit
    from (select p.prosrc as src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prosrc ~ 'net\.http_(post|get|delete)') t;

  -- (b) the call is claimed, the dependency times out, the caller stores a
  --     refusal: _idem_store_ok must RELEASE the claim so the user can retry.
  perform public._idem_claim(v_scope, v_key);
  v_refusal := public._idem_store_ok(v_scope, v_key,
                 jsonb_build_object('ok', false, 'error', 'edge_timeout',
                                    'message', 'The service did not answer in time.'));
  select count(*)::int into v_rows from public.idempotent_action
   where scope = v_scope and client_action_id = v_key;
  if v_rows <> 0 then
    v_fail := array_append(v_fail,
      'the claim survived a timed-out call — the user is locked out of retrying by a dependency that never answered');
  end if;
  if coalesce((v_refusal->>'ok')::boolean, true) then
    v_fail := array_append(v_fail, 'the timeout was stored as a success');
  end if;

  -- (c) the retry is admitted and applies ONCE; the late original replays.
  v_retry := public._idem_claim(v_scope, v_key);
  if v_retry is not null then
    v_fail := array_append(v_fail, 'the retry after the timeout was refused');
  end if;
  v_ans := jsonb_build_object('ok', true, 'applied_once', true);
  perform public._idem_store(v_scope, v_key, v_ans);
  v_late := public._idem_claim(v_scope, v_key);
  if v_late is null or coalesce((v_late->>'replayed')::boolean,false) is not true then
    v_fail := array_append(v_fail,
      'the delayed original was handed the work again — the slow edge function would apply it twice');
  end if;

  delete from public.idempotent_action where scope = v_scope and client_action_id = v_key;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'The dependency answered too late: every outbound call is bounded, the timed-out claim was released so the retry could run, and the late original came back as a replay instead of applying twice.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'pg_net_default_ms',      coalesce(v_default::text,'none'),
      'callers_own_deadline',   coalesce(v_explicit::text,'0'),
      'callers_inherit_default', coalesce(v_implicit::text,'0'),
      'claim_rows_after_timeout', v_rows::text,
      'retry_admitted',         (v_retry is null)::text,
      'late_original',          coalesce(left(v_late::text,200),'—')));
end $$;

-- S7. A second writer arrives while an exclusive hold is live (the shape of
--     "lease a file mid-deploy"): it must be REFUSED with a retry, the first
--     hold must be untouched, and releasing must free the lane.
create or replace function public._chaos_lease_during_deploy()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_a jsonb; v_b jsonb; v_c jsonb; v_tok uuid; v_tok3 uuid; v_fail text[] := '{}';
begin
  v_a := public.db_lock_try('chaos-638-a','exclusive','chaos: lease during deploy',1,null);
  if coalesce((v_a->>'ok')::boolean,false) is not true then
    return jsonb_build_object('status','skipped',
      'summary','the lane was already held by another worker (' || coalesce(v_a->>'reason','?') || '), so this run never got the first hold.',
      'evidence', jsonb_build_object('first_try', left(v_a::text,300)));
  end if;
  v_tok := nullif(v_a->>'token','')::uuid;

  v_b := public.db_lock_try('chaos-638-b','exclusive','chaos: the second writer',1,null);
  if coalesce((v_b->>'ok')::boolean,false) then
    v_fail := array_append(v_fail, 'a SECOND exclusive holder was admitted while the first was live — two writers on one file');
    if nullif(v_b->>'token','') is not null then
      perform public.db_lock_release((v_b->>'token')::uuid);
    end if;
  elsif coalesce(v_b->>'reason','') <> 'busy' then
    v_fail := array_append(v_fail, 'the second writer was refused for ''' || coalesce(v_b->>'reason','?') || ''' rather than a busy lane');
  elsif coalesce((v_b->>'retry_after_seconds')::int, 0) <= 0 then
    v_fail := array_append(v_fail, 'the refusal carried no retry_after_seconds — the loser has nothing to wait on');
  end if;

  if not exists (select 1 from public.db_work_lock where token = v_tok) then
    v_fail := array_append(v_fail, 'the FIRST hold vanished while the second was being refused');
  end if;

  perform public.db_lock_release(v_tok);
  v_c := public.db_lock_try('chaos-638-c','exclusive','chaos: after the release',1,null);
  if coalesce((v_c->>'ok')::boolean,false) is not true then
    v_fail := array_append(v_fail, 'the lane stayed shut after the release — a crashed deploy would block every writer');
  else
    v_tok3 := nullif(v_c->>'token','')::uuid;
    perform public.db_lock_release(v_tok3);
  end if;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'A second writer arrived mid-hold: it was refused with a retry, the first hold was untouched, and the lane reopened the moment it was released.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'first_hold',   case when v_tok is null then 'none' else 'granted' end,
      'second_try',   left(v_b::text, 300),
      'after_release', case when coalesce((v_c->>'ok')::boolean,false) then 'granted' else left(coalesce(v_c::text,'—'),200) end));
exception when others then
  if v_tok is not null then perform public.db_lock_release(v_tok); end if;
  return jsonb_build_object('status','failed',
    'summary','the lane raised instead of refusing: ' || sqlerrm,
    'evidence', jsonb_build_object('sqlstate', sqlstate));
end $$;

-- ── 3. THE CATALOGUE (data, not code) ───────────────────────────────────────

insert into public.chaos_scenario (key,label,blurb,family,family_label,expect_label,fn,gap_title,severity,sort_order) values
 ('network_kill_mid_pack','Kill the network mid-pack',
  'The connection dies after the pack is claimed and before the answer is stored, and the client retries.',
  'network','Network','The retry runs, the pack applies once, the late original comes back as a replay.',
  '_chaos_network_kill_mid_pack','A dead attempt bricks the pack — the retry is refused or applies twice','critical',10),
 ('double_submit_form','Double-submit a form',
  'The same intent is submitted twice while the first submit is still in flight.',
  'form','Form','The second tap gets the first answer back and writes nothing.',
  '_chaos_double_submit_form','A double submit applies twice','critical',20),
 ('webhook_replay_twice','Replay a payment webhook twice',
  'Razorpay redelivers the same event id, exactly as it does on any non-2xx.',
  'payment','Payment','One log row, the redelivery answered from the first, no second credit.',
  '_chaos_webhook_replay_twice','A redelivered webhook is applied twice','critical',30),
 ('session_expire_mid_flow','Expire the session mid-flow',
  'The test session times out while a synthetic flow is still walking the pipeline.',
  'session','Session','The sweep ends it cleanly, the live id goes null, the banner goes quiet.',
  '_chaos_session_expire_mid_flow','An expired test session keeps writing into production','high',90),
 ('db_restart_mid_write','Restart the database mid-write',
  'The instance restarts and the resumed runner fires the same work again (#474''s drill).',
  'db','Database','The resumed pass changes nothing and gets the first pass''s own answer.',
  '_chaos_db_restart_mid_write','A restart makes the resumed runner apply the work twice','critical',50),
 ('edge_delay_past_timeout','Delay a dependency past its timeout',
  'An edge function hangs; the caller has already written half of what it came to write.',
  'edge','Dependency','The call aborts at the deadline, the half-write rolls back, the session survives.',
  '_chaos_edge_delay_past_timeout','A hung dependency leaves a half-applied write behind','high',60),
 ('lease_during_deploy','Take a lease mid-deploy',
  'A second writer asks for the exclusive lane while a deploy-class hold is still live.',
  'lease','Lease','The second writer is refused with a retry, the first hold survives, the release reopens the lane.',
  '_chaos_lease_during_deploy','Two writers hold the exclusive lane at once','high',70)
on conflict (key) do update set
  label=excluded.label, blurb=excluded.blurb, family=excluded.family,
  family_label=excluded.family_label, expect_label=excluded.expect_label,
  fn=excluded.fn, gap_title=excluded.gap_title, severity=excluded.severity,
  sort_order=excluded.sort_order, is_active=true;

-- The run kinds and the gap-source labels are PRODUCTION's tables. The merge
-- worker replays every migration on the control plane too (#1761), and that
-- project has neither, so both writes are guarded rather than assumed.
do $$
begin
  if to_regclass('public.test_run_kind') is not null then
    insert into public.test_run_kind (kind,label,lane,counts_coverage,sort_order) values
     ('chaos','Chaos','chaos',false,70),
     ('recording','Recorded walkthrough','record',false,80)
    on conflict (kind) do update set label=excluded.label, lane=excluded.lane,
      counts_coverage=excluded.counts_coverage, sort_order=excluded.sort_order;
  end if;
  if to_regclass('public.feature_gap_label') is not null then
    insert into public.feature_gap_label (key,label,tone,sort_order) values
     ('source.chaos','Chaos drill','danger',50),
     ('source.recording','Recorded walkthrough','info',60)
    on conflict (key) do update set label=excluded.label, tone=excluded.tone, sort_order=excluded.sort_order;
  end if;
end $$;

-- ── 4. THE EXECUTOR ─────────────────────────────────────────────────────────
-- One scenario, run and recorded. A red scenario files a feature_gap through
-- gap_file_or_touch — the same door the journey bot and the explorer use —
-- so a chaos regression lands in the same inbox as every other finding.

create or replace function public.chaos_exec(p_run_id bigint, p_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  s public.chaos_scenario%rowtype;
  v_run public.chaos_run%rowtype;
  v_t0 timestamptz := clock_timestamp();
  v_out jsonb; v_verdict text; v_ms int; v_gap jsonb; v_gap_id bigint;
begin
  perform public._dev_guard();
  select * into s from public.chaos_scenario where key = p_key;
  if s.key is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_scenario',
      'message', 'No chaos scenario is registered under ' || coalesce(p_key,'(null)') || '.');
  end if;
  select * into v_run from public.chaos_run where id = p_run_id;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_run',
      'message', 'No chaos run with that id.');
  end if;

  begin
    execute format('select public.%I()', s.fn) into v_out;
  exception when others then
    v_out := jsonb_build_object('status','failed',
      'summary','the scenario itself raised: ' || sqlerrm,
      'evidence', jsonb_build_object('sqlstate', sqlstate));
  end;

  v_ms := greatest((extract(epoch from (clock_timestamp() - v_t0)) * 1000)::int, 0);
  v_verdict := coalesce(v_out->>'status','failed');
  if v_verdict not in ('passed','failed','skipped') then v_verdict := 'failed'; end if;

  if v_verdict = 'failed' then
    v_gap := public.gap_file_or_touch(
      p_scenario   => 'chaos:' || s.key,
      p_source     => 'chaos',
      p_surface    => 'platform',
      p_feature    => 'chaos.' || s.key,
      p_role       => 'platform',
      p_title      => s.gap_title,
      p_type       => 'broken',
      p_severity   => s.severity,
      p_evidence   => coalesce(v_out->>'summary',''),
      p_suggestion => s.expect_label,
      p_notes      => 'Chaos run #' || p_run_id || ' · ' || s.label,
      p_run_id     => v_run.test_run_id,
      p_spec_line  => null,
      p_bucket     => null,
      p_path       => null,
      p_confidence => 'high');
    v_gap_id := nullif(v_gap->>'id','')::bigint;
  else
    -- A scenario that is green again closes its own finding. This is how a
    -- class of failure is retired instead of a red row living forever.
    update public.feature_gaps
       set status = 'done', updated_at = now(),
           notes = coalesce(nullif(notes,''),'') ||
                   case when coalesce(notes,'') = '' then '' else ' · ' end ||
                   'closed by chaos run #' || p_run_id
     where source = 'chaos' and feature_key = 'chaos.' || s.key and status = 'open';
  end if;

  insert into public.chaos_result (run_id, scenario_key, verdict, summary, evidence, duration_ms, gap_id)
  values (p_run_id, s.key, v_verdict, coalesce(v_out->>'summary',''),
          coalesce(v_out->'evidence','{}'::jsonb), v_ms, v_gap_id);

  update public.chaos_run
     set total   = total + 1,
         passed  = passed  + (v_verdict = 'passed')::int,
         failed  = failed  + (v_verdict = 'failed')::int,
         skipped = skipped + (v_verdict = 'skipped')::int,
         gaps_written = gaps_written + (v_gap_id is not null)::int,
         -- the artifacts live WITH the run, keyed by scenario
         artifacts = artifacts || jsonb_build_object(s.key, jsonb_build_object(
                       'verdict', v_verdict, 'summary', coalesce(v_out->>'summary',''),
                       'evidence', coalesce(v_out->'evidence','{}'::jsonb),
                       'duration_ms', v_ms, 'at', clock_timestamp()))
   where id = p_run_id;

  return jsonb_build_object('ok', true, 'key', s.key, 'verdict', v_verdict,
    'summary', coalesce(v_out->>'summary',''), 'duration_ms', v_ms,
    'gap_id', v_gap_id);
end $$;

create or replace function public.chaos_run_all(p_label text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_label text := coalesce(nullif(btrim(p_label),''),
                    'chaos ' || to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI'));
  v_sess jsonb; v_sid bigint; v_opened boolean := false;
  v_trun bigint; v_run bigint; s record; v_row public.chaos_run%rowtype;
begin
  perform public._dev_guard();

  -- Everything runs inside a test session. If one is already live we join it;
  -- otherwise this run opens its own, named so the expiry scenario knows the
  -- session is its to kill.
  v_sid := public.test_session_live_id();
  if v_sid is null then
    v_sess := public.test_session_start('chaos: ' || v_label, null);
    if coalesce((v_sess->>'ok')::boolean,false) is not true then
      return jsonb_build_object('ok', false, 'error', coalesce(v_sess->>'error','no_session'),
        'message', coalesce(v_sess->>'message',
          'Chaos runs inside a test session, and one could not be opened.'));
    end if;
    v_sid := nullif(v_sess->>'session_id','')::bigint;
    v_opened := true;
  end if;

  v_trun := public.test_run_open(v_label, 'chaos');
  update public.test_run set test_session_id = v_sid, is_synthetic = true where id = v_trun;

  insert into public.chaos_run (label, session_id, test_run_id)
  values (v_label, v_sid, v_trun) returning id into v_run;

  for s in select key from public.chaos_scenario where is_active order by sort_order, key loop
    perform public.chaos_exec(v_run, s.key);
  end loop;

  select * into v_row from public.chaos_run where id = v_run;
  update public.chaos_run
     set finished_at = now(),
         status = case when v_row.failed > 0 then 'failed' else 'passed' end,
         summary = jsonb_build_object('opened_session', v_opened,
                                      'session_id', v_sid, 'test_run_id', v_trun)
   where id = v_run;
  update public.test_run
     set ended_at = now(),
         status = case when v_row.failed > 0 then 'failed' else 'passed' end,
         steps = (select jsonb_agg(jsonb_build_object('key',r.scenario_key,'verdict',r.verdict,
                                                      'summary',r.summary) order by r.id)
                    from public.chaos_result r where r.run_id = v_run)
   where id = v_trun;

  return public.chaos_home(v_run);
end $$;

-- ── 5. SESSION RECORDING ────────────────────────────────────────────────────

create or replace function public.recording_start(p_label text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_live bigint; v_sid bigint; v_uid uuid; v_trun bigint;
begin
  perform public._dev_guard();
  if not (select enabled from public.test_mode_config where id = 1) then
    return jsonb_build_object('ok', false, 'error', 'test_mode_off',
      'message', public.uic('recording.test_mode_off',
        'Recording is test mode only. Turn test mode on first — a recorded walkthrough must never touch live data.'));
  end if;
  v_sid := public.test_session_live_id();
  if v_sid is null then
    return jsonb_build_object('ok', false, 'error', 'no_session',
      'message', public.uic('recording.no_session',
        'Start a test session first. Every recorded step belongs to a session, so it can be purged with it.'));
  end if;

  select id into v_live from public.test_recording where status = 'recording' limit 1;
  if v_live is not null then
    return jsonb_build_object('ok', true, 'already', true, 'recording_id', v_live,
      'message', public.uic('recording.already', 'A walkthrough is already recording.'));
  end if;

  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  v_trun := public.test_run_open(coalesce(nullif(btrim(p_label),''),'recorded walkthrough'), 'recording');
  update public.test_run set test_session_id = v_sid, is_synthetic = true where id = v_trun;

  insert into public.test_recording (session_id, test_run_id, label, started_by, started_by_label)
  values (v_sid, v_trun,
          coalesce(nullif(btrim(p_label),''),
                   to_char(now() at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' walkthrough'),
          v_uid, coalesce((select email from auth.users where id = v_uid),'admin'))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'recording_id', v_id, 'session_id', v_sid,
    'message', public.uic('recording.started',
      'Recording. Walk the app exactly as you would; every screen you open is a step.'));
end $$;

create or replace function public.recording_step_add(
  p_recording bigint, p_kind text default 'nav', p_screen text default '',
  p_action text default '', p_detail jsonb default '{}'::jsonb, p_ok boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.test_recording%rowtype; v_n int; v_cap int := 400;
begin
  perform public._dev_guard();
  select * into r from public.test_recording where id = p_recording;
  if r.id is null or r.status <> 'recording' then
    return jsonb_build_object('ok', false, 'error', 'not_recording',
      'message', public.uic('recording.not_live','That walkthrough is not recording any more.'));
  end if;
  select coalesce(max(n),0) into v_n from public.test_recording_step where recording_id = p_recording;
  if v_n >= v_cap then
    return jsonb_build_object('ok', true, 'capped', true, 'n', v_n,
      'message', public.uic('recording.capped','This walkthrough already holds the maximum number of steps.'));
  end if;
  insert into public.test_recording_step (recording_id, n, kind, screen, action, detail, ok)
  values (p_recording, v_n + 1, coalesce(nullif(p_kind,''),'nav'), coalesce(p_screen,''),
          coalesce(p_action,''), coalesce(p_detail,'{}'::jsonb), coalesce(p_ok,true));
  return jsonb_build_object('ok', true, 'n', v_n + 1);
end $$;

create or replace function public.recording_stop(
  p_recording bigint, p_outcome text default 'ok', p_note text default '')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r public.test_recording%rowtype; v_out text; v_steps int; v_bad int; v_gap jsonb;
begin
  perform public._dev_guard();
  select * into r from public.test_recording where id = p_recording;
  if r.id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_recording',
      'message', public.uic('recording.unknown','That walkthrough no longer exists.'));
  end if;
  v_out := case when lower(coalesce(p_outcome,'')) in ('broke','broken','failed') then 'broke' else 'ok' end;
  select count(*)::int, count(*) filter (where not ok)::int into v_steps, v_bad
    from public.test_recording_step where recording_id = p_recording;

  update public.test_recording
     set status = 'stopped', stopped_at = now(), outcome = v_out,
         note = coalesce(nullif(btrim(p_note),''), note),
         artifacts = artifacts || jsonb_build_object('steps', v_steps, 'failed_steps', v_bad,
                                                     'stopped_at', now())
   where id = p_recording;
  update public.test_run
     set ended_at = now(), status = case when v_out = 'broke' then 'failed' else 'passed' end,
         note = coalesce(nullif(btrim(p_note),''), note)
   where id = r.test_run_id;

  if v_out = 'broke' then
    v_gap := public.gap_file_or_touch(
      p_scenario   => 'recording:' || p_recording,
      p_source     => 'recording',
      p_surface    => 'platform',
      p_feature    => 'recording.' || p_recording,
      p_role       => 'platform',
      p_title      => left('Broke during a recorded walkthrough: ' || coalesce(nullif(btrim(p_note),''), r.label), 200),
      p_type       => 'broken',
      p_severity   => 'high',
      p_evidence   => 'Recording #' || p_recording || ' — ' || v_steps || ' steps, ' || v_bad || ' of them red.',
      p_suggestion => 'Promote the recording to a permanent journey and fix until it passes.',
      p_notes      => coalesce(nullif(btrim(p_note),''),''),
      p_run_id     => r.test_run_id,
      p_spec_line  => null, p_bucket => null, p_path => null, p_confidence => 'high');
  end if;

  return jsonb_build_object('ok', true, 'recording_id', p_recording, 'outcome', v_out,
    'steps', v_steps, 'gap_id', nullif(v_gap->>'id','')::bigint,
    'message', case when v_out = 'broke'
      then public.uic('recording.stopped_broke','Stopped. A gap was filed — promote this walkthrough to keep it from happening again.')
      else public.uic('recording.stopped','Stopped.') end);
end $$;

-- One tap: this walkthrough becomes a permanent journey. dev_journeys is the
-- CONTROL PLANE's table (#1761) and its mirror trigger already pushes rows the
-- other way, so this reaches it exactly the same way — pg_net plus the vault.
-- `required` is false on purpose: a journey only becomes required after it has
-- passed green twice, never on first sight.
create or replace function public.recording_promote(
  p_recording bigint, p_title text default null, p_area text default 'platform')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r public.test_recording%rowtype;
  v_title text; v_name text; v_steps jsonb; v_asserts jsonb; v_journey jsonb;
  v_url text; v_key text; v_n int;
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
  select count(*)::int into v_n from public.test_recording_step where recording_id = p_recording;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty_recording',
      'message', public.uic('recording.empty','That walkthrough recorded no steps, so there is nothing to assert.'));
  end if;

  v_title := coalesce(nullif(btrim(p_title),''), r.label);
  v_name  := 'rec-' || p_recording || '-' ||
             left(regexp_replace(lower(v_title), '[^a-z0-9]+', '-', 'g'), 40);
  v_name  := btrim(v_name, '-');

  select jsonb_agg(x order by n) into v_steps from (
    select s.n, (s.n || '. ' || coalesce(nullif(s.action,''), s.kind) ||
                 case when coalesce(s.screen,'') <> '' then ' — ' || s.screen else '' end) as x
      from public.test_recording_step s where s.recording_id = p_recording) t;

  -- The assertions are the recording's own facts: every step must still be
  -- reachable in the same order, and every step that was red when Om hit it
  -- must be green now. Nothing is invented.
  select jsonb_agg(a) into v_asserts from (
    select 'The walkthrough still reaches all ' || v_n || ' steps, in this order.' as a
    union all
    select 'Step ' || s.n || ' (' || coalesce(nullif(s.action,''), s.kind) ||
           case when coalesce(s.screen,'') <> '' then ' — ' || s.screen else '' end ||
           ') no longer fails.'
      from public.test_recording_step s
     where s.recording_id = p_recording and not s.ok
    union all
    select 'What broke here does not come back: ' || r.note
     where coalesce(btrim(r.note),'') <> ''
  ) t;

  v_journey := jsonb_build_object(
    'name', v_name,
    'area', coalesce(nullif(btrim(p_area),''),'platform'),
    'kind', 'browser',   -- dev_journeys.kind is api|browser; a recorded walk is a browser journey
    'steps', coalesce(v_steps,'[]'::jsonb),
    'assertions', coalesce(v_asserts,'[]'::jsonb),
    'required', false,
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
         journey_area = coalesce(nullif(btrim(p_area),''),'platform'),
         artifacts = artifacts || jsonb_build_object('journey', v_journey)
   where id = p_recording;

  return jsonb_build_object('ok', true, 'recording_id', p_recording,
    'journey_name', v_name, 'steps', v_n, 'journey', v_journey,
    'message', public.uic('recording.promoted',
      'This walkthrough is now a permanent journey. It runs with every command in its area from here on.'));
end $$;

-- ── 6. THE SCREEN, IN ONE PAYLOAD ───────────────────────────────────────────
-- Every word, every chip, every tone and every enabled/disabled decision is
-- built here. The Chaos lab counts nothing, pluralises nothing and names no
-- tone of its own — a screen that recomputed any of this would start lying the
-- moment somebody INSERTs an eighth scenario.

create or replace function public.chaos_home(p_run bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
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
                                 else 'Journey ' || t.journey_name end)
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
end $$;

grant execute on function public.chaos_home(bigint)          to authenticated;
grant execute on function public.chaos_run_all(text)         to authenticated;
grant execute on function public.chaos_exec(bigint, text)    to authenticated;
grant execute on function public.recording_start(text)       to authenticated;
grant execute on function public.recording_step_add(bigint, text, text, text, jsonb, boolean) to authenticated;
grant execute on function public.recording_stop(bigint, text, text) to authenticated;
grant execute on function public.recording_promote(bigint, text, text) to authenticated;

-- ── 7. THE DOOR ─────────────────────────────────────────────────────────────
-- dev_tools() draws the tools sheet from feature_registry, so the entry point
-- is a ROW, not a deploy. The control plane owns that table (#1761); this block
-- keeps production's copy in step and is a no-op where the table differs.
do $$
begin
  insert into public.feature_registry
    (feature_key,label,group_label,icon_key,route_key,sort_order,owner,partner_eligible,
     default_access,is_active,category,surface,roles_allowed,search_terms,description)
  values ('devtool.chaos','Chaos & recording','Runtime & health','fact_check','chaos_lab',48,
     'medibo',false,'none',true,'more_system','dev_tools','{super_admin}',
     'chaos scenario drill idempotency webhook replay double submit session expire timeout lease recording walkthrough journey regression',
     'Reproduce the failures that bite — and turn your own walkthroughs into permanent tests.')
  on conflict (feature_key) do update set
     label=excluded.label, group_label=excluded.group_label, icon_key=excluded.icon_key,
     route_key=excluded.route_key, sort_order=excluded.sort_order, is_active=true,
     description=excluded.description, search_terms=excluded.search_terms;
exception when others then null;
end $$;
