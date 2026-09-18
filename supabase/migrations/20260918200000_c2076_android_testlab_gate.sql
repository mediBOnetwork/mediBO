-- CMD #2076 — ANDROID GATE: Firebase Test Lab must pass before every Play
-- Production upload.
--
-- The web build never compiles or runs the Kotlin plugins (PlayUpdate,
-- PaymentListener, OrderAlert, DocScanReadiness, SignInDiag, the run_location
-- channel). Until now an Android release could reach Play with a broken
-- plugin and nothing in the lane ever ran the app on an Android runtime.
--
-- What this adds, all backend-decided and rendered verbatim by the app:
--   * android_testlab_run — the run ledger: one row per Test Lab matrix
--     (device, API level, plan, per-check results, proofs, verdict, quota day).
--   * dev_commands.testlab_* — the latest verdict stamped on the command row,
--     so the Dev Queue list chip and the detail block read one column set.
--   * android_testlab_begin / _finish — the two calls scripts/android_testlab.sh
--     makes. begin decides EVERYTHING: whether the gate applies (web-only
--     commands skip it), the free daily quota (never pay), the spec-derived
--     plan, the device, the timeout and every human sentence the script may
--     print. finish records the verdict and stamps the command(s).
--   * android_testlab_gate — what publish_play.sh asks before a Production
--     upload; refused until a green run exists for this commit / version code.
--   * android_testlab_plan — the spec-derived check list (config-driven
--     keyword rules over the command's spec; a release with no command runs
--     the full sweep).
--   * _dev_android_gate — the finish-state 'android' condition now also
--     requires the Test Lab verdict for targets_android commands.
--   * build_rules.android_testlab — the rule, mirrored on production so
--     rg_check can assert it; rg_behavior_tests android_testlab_rule_present
--     goes red when the rule, its gate or its budget go missing, and when the
--     scripts/android_testlab.sh selfcheck verdict says the hooks are gone.
--
-- Idempotent, safe on BOTH databases: control-plane objects (everything that
-- touches dev_commands / play_release) are created only where dev_commands
-- exists; the config mirror, the copy and the rg checks land everywhere.
-- Function bodies that name control-plane tables are plpgsql inside EXECUTE,
-- never validated against a table that is not there.

-- ── 0. the rule (both databases) ─────────────────────────────────────────────
insert into dev_runner_config (key, value) values ('build_rules', '{}'::jsonb)
  on conflict (key) do nothing;

update dev_runner_config
   set value = jsonb_set(coalesce(value,'{}'::jsonb), '{android_testlab}', $j${
  "gate": "c_android_testlab",
  "change": 2076,
  "enforce": true,
  "enforce_off_reason": "",
  "rule": "For commands with targets_android=true: after the AAB/APK builds, a spec-derived Flutter integration test of the Android-only parts (Kotlin plugins, listeners, Play in-app update) runs on Firebase Test Lab — one virtual device, one API level, one run, at most 10 minutes, one blocking gcloud call, free Spark quota only (never pay). A Play Production upload is refused until that matrix is green. Web-only commands skip this entirely.",
  "why": "The Kotlin plugins, the notification listener and the Play in-app update exist only on Android; the web build never compiles or runs them.",
  "prompt_line": "ANDROID TEST LAB GATE (build_rules.android_testlab, gate c_android_testlab): only when targets_android=true — after the AAB/APK builds, `bash scripts/android_testlab.sh run --cmd <id>` runs the spec-derived integration test on Firebase Test Lab (one virtual device, one API level, one run, <=10 min, ONE blocking gcloud call, free Spark quota only — never pay; abort with the backend's reason when the quota is used up). A Play Production upload is refused until the matrix is green (publish_play.sh asks android_testlab_gate); the verdict, video, logcat and screenshots show on the Dev Queue row. Web-only commands skip this entirely.",
  "project": "medibo-23aee",
  "secret_name": "GCP_SA_KEY",
  "device": {"model": "MediumPhone.arm", "version": "33", "locale": "en", "orientation": "portrait"},
  "fallback_models": ["MediumPhone.arm", "SmallPhone.arm", "Pixel2.arm", "MediumPhone", "Pixel2"],
  "timeout_s": 600,
  "daily_quota": 10,
  "quota_day_tz": "America/Los_Angeles",
  "gate_max_age_h": 72,
  "verdict_max_age_h": 168,
  "test_target": "integration_test/android_gate_test.dart",
  "results_history": "medibo-testlab",
  "pull_dir": "/sdcard/Download/medibo_testlab",
  "core_checks": ["boot_first_frame", "channel_play_update", "channel_signin_diag"],
  "all_checks": ["boot_first_frame", "channel_play_update", "channel_signin_diag", "channel_pay_listen", "channel_order_alert", "channel_doc_scan", "channel_run_location", "fcm_token"],
  "plan_rules": [
    {"check": "channel_play_update",  "any": ["update", "in-app", "in app", "play store", "playupdate"]},
    {"check": "channel_pay_listen",   "any": ["payment", "upi", "listener", "pay_listen", "razorpay", "credited"]},
    {"check": "channel_order_alert",  "any": ["order alert", "ring", "alarm", "full screen", "full-screen", "order_alert", "notification"]},
    {"check": "channel_doc_scan",     "any": ["scan", "ocr", "document", "invoice photo", "doc_scan"]},
    {"check": "channel_run_location", "any": ["location", "gps", "rider", "run_location", "delivery run"]},
    {"check": "fcm_token",            "any": ["push", "fcm", "firebase messaging", "notification"]}
  ]
}$j$::jsonb, true)
 where key = 'build_rules'
   and coalesce((value->'android_testlab'->>'change')::int, 0) < 2076;

-- ── 1. copy (both databases; Om's later edits win) ───────────────────────────
do $mig$
begin
  if to_regclass('public.ui_copy') is null then return; end if;
  insert into public.ui_copy(key, value) values
    ('dev_queue.testlab_section',        to_jsonb('Firebase Test Lab'::text)),
    ('dev_queue.testlab_running',        to_jsonb('Test Lab running'::text)),
    ('dev_queue.testlab_passed',         to_jsonb('Test Lab passed'::text)),
    ('dev_queue.testlab_failed',         to_jsonb('Test Lab failed'::text)),
    ('dev_queue.testlab_error',          to_jsonb('Test Lab error'::text)),
    ('dev_queue.testlab_quota',          to_jsonb('Test Lab quota used up'::text)),
    ('dev_queue.testlab_blocked',        to_jsonb('Test Lab blocked'::text)),
    ('dev_queue.testlab_skipped',        to_jsonb('Test Lab skipped'::text)),
    ('dev_queue.testlab_chip_running',   to_jsonb('🧪 Test Lab running'::text)),
    ('dev_queue.testlab_chip_passed',    to_jsonb('🧪 Test Lab passed'::text)),
    ('dev_queue.testlab_chip_failed',    to_jsonb('🧪 Test Lab failed'::text)),
    ('dev_queue.testlab_chip_error',     to_jsonb('🧪 Test Lab error'::text)),
    ('dev_queue.testlab_chip_quota',     to_jsonb('🧪 Test Lab quota used up'::text)),
    ('dev_queue.testlab_chip_blocked',   to_jsonb('🧪 Test Lab blocked'::text)),
    ('dev_queue.testlab_chip_skipped',   to_jsonb('🧪 Test Lab skipped'::text)),
    ('dev_queue.testlab_open',           to_jsonb('Open the matrix in the Firebase console'::text)),
    ('dev_queue.testlab_proofs_title',   to_jsonb('Evidence from the device'::text)),
    ('dev_queue.testlab_proof_video',    to_jsonb('Video of the run'::text)),
    ('dev_queue.testlab_proof_logcat',   to_jsonb('Logcat'::text)),
    ('dev_queue.testlab_proof_screenshot', to_jsonb('Screenshot'::text)),
    ('dev_queue.testlab_proof_checks',   to_jsonb('Per-check results (JSON)'::text)),
    ('dev_queue.testlab_checks_title',   to_jsonb('Checks derived from the spec'::text)),
    ('dev_queue.testlab_check_pending',  to_jsonb('pending'::text)),
    ('dev_queue.testlab_check_ok',       to_jsonb('ok'::text)),
    ('dev_queue.testlab_check_failed',   to_jsonb('failed'::text)),
    ('dev_queue.testlab_check_boot_first_frame',      to_jsonb('App boots and paints its first frame'::text)),
    ('dev_queue.testlab_check_channel_play_update',   to_jsonb('Play in-app update plugin answers'::text)),
    ('dev_queue.testlab_check_channel_signin_diag',   to_jsonb('Sign-in diagnostics plugin answers'::text)),
    ('dev_queue.testlab_check_channel_pay_listen',    to_jsonb('Payment notification listener answers'::text)),
    ('dev_queue.testlab_check_channel_order_alert',   to_jsonb('Order alert channel answers'::text)),
    ('dev_queue.testlab_check_channel_doc_scan',      to_jsonb('Document scanner readiness answers'::text)),
    ('dev_queue.testlab_check_channel_run_location',  to_jsonb('Rider location channel answers'::text)),
    ('dev_queue.testlab_check_fcm_token',             to_jsonb('Firebase Messaging issues a device token'::text)),
    ('dev_queue.android_gate_testlab',   to_jsonb('Firebase Test Lab has not passed for this Android build — the last run is {status}. {detail}'::text)),
    ('testlab.reason_missing_secret',    to_jsonb('Google credentials missing on the VM: save the Test Lab service-account key as {secret} in the Vault (Dev Queue → Google Cloud → Secrets). The run was not started and nothing was paid.'::text)),
    ('testlab.reason_api_disabled',      to_jsonb('The Cloud Testing API is not enabled on {project} and the credentials on the VM cannot enable it.'::text)),
    ('testlab.reason_no_permission',     to_jsonb('The service account has no Firebase Test Lab role on {project}.'::text)),
    ('testlab.reason_quota',             to_jsonb('Free Test Lab quota used up for today ({used}/{quota} virtual runs) — it resets at midnight Pacific. The run was not started and nothing was paid.'::text)),
    ('testlab.reason_quota_gcloud',      to_jsonb('Firebase Test Lab refused the run: the free daily quota is used up. Nothing was paid; retry after the reset.'::text)),
    ('testlab.reason_timeout',           to_jsonb('The Test Lab matrix did not finish within {timeout} — treated as failed.'::text)),
    ('testlab.reason_build_failed',      to_jsonb('The instrumentation build failed before any device ran: {detail}'::text)),
    ('testlab.reason_infra',             to_jsonb('Test Lab infrastructure error (gcloud exit {rc}) — not a verdict on the code.'::text)),
    ('testlab.reason_enforce_off',       to_jsonb('The Test Lab gate is switched off in build_rules.android_testlab'::text)),
    ('testlab.reason_web_only',          to_jsonb('web-only command — Test Lab skipped'::text)),
    ('testlab.summary_running',          to_jsonb('Test Lab run in progress'::text)),
    ('testlab.summary_passed',           to_jsonb('Passed on {device} API {api} in {duration} · {n} check(s) green'::text)),
    ('testlab.summary_failed',           to_jsonb('Failed on {device} API {api}: {detail}'::text)),
    ('testlab.gate_not_production',      to_jsonb('not a Production upload (track {track}) — the Test Lab gate applies to Production only'::text)),
    ('testlab.gate_green',               to_jsonb('Firebase Test Lab green — run #{run}: {summary}'::text)),
    ('testlab.gate_refused_run',         to_jsonb('Play Production upload refused — Firebase Test Lab run #{run} is {status}: {reason}'::text)),
    ('testlab.gate_refused_none',        to_jsonb('Play Production upload refused — no Firebase Test Lab run is recorded for this build ({key}). Run scripts/android_testlab.sh first.'::text)),
    ('testlab.waived',                   to_jsonb('Test Lab waived on the record: {reason}'::text))
  on conflict (key) do nothing;
end $mig$;

-- ── 2. control-plane objects ─────────────────────────────────────────────────
do $mig$
begin
  if to_regclass('public.dev_commands') is null then return; end if;

  -- 2a. the ledger + the stamped columns
  execute $fn$
    create table if not exists public.android_testlab_run (
      id             bigserial primary key,
      command_id     bigint,
      command_ids    bigint[] not null default '{}',
      release_id     bigint,
      commit_sha     text,
      version_code   integer,
      version_name   text,
      track          text,
      status         text not null default 'running'
                     check (status in ('running','passed','failed','error','quota','blocked','skipped')),
      reason         text,
      summary        text,
      device_model   text,
      device_version text,
      matrix_id      text,
      console_url    text,
      results_dir    text,
      plan           jsonb not null default '[]'::jsonb,
      checks         jsonb not null default '[]'::jsonb,
      proofs         jsonb not null default '[]'::jsonb,
      outcome        jsonb not null default '{}'::jsonb,
      quota_day      date,
      started_at     timestamptz not null default now(),
      finished_at    timestamptz,
      duration_s     integer,
      rehearsal      boolean not null default false,
      worker         text
    )$fn$;
  execute 'create index if not exists android_testlab_run_cmd_idx on public.android_testlab_run(command_id, started_at desc)';
  execute 'create index if not exists android_testlab_run_commit_idx on public.android_testlab_run(commit_sha, started_at desc)';
  execute 'create index if not exists android_testlab_run_code_idx on public.android_testlab_run(version_code, started_at desc)';
  execute 'create index if not exists android_testlab_run_day_idx on public.android_testlab_run(quota_day)';
  execute 'revoke all on public.android_testlab_run from anon, authenticated';

  execute 'alter table public.dev_commands add column if not exists testlab_status text';
  execute 'alter table public.dev_commands add column if not exists testlab_run_id bigint';
  execute 'alter table public.dev_commands add column if not exists testlab_at timestamptz';
  execute 'alter table public.dev_commands add column if not exists testlab_summary text';

  -- 2b. config readers
  execute $fn$
    create or replace function public._testlab_cfg() returns jsonb
    language sql stable security definer set search_path=public as $f$
      select coalesce((select value->'android_testlab' from dev_runner_config where key='build_rules'), '{}'::jsonb);
    $f$ $fn$;
  execute $fn$
    create or replace function public._testlab_enforced() returns boolean
    language sql stable security definer set search_path=public as $f$
      select coalesce((_testlab_cfg()->>'enforce')::boolean, true);
    $f$ $fn$;
  execute $fn$
    create or replace function public._testlab_quota_day() returns date
    language sql stable security definer set search_path=public as $f$
      select (now() at time zone coalesce(_testlab_cfg()->>'quota_day_tz','America/Los_Angeles'))::date;
    $f$ $fn$;
  execute $fn$
    create or replace function public._testlab_copy(p_key text, p_fallback text) returns text
    language sql stable security definer set search_path=public as $f$
      select _dev_copy('testlab.' || p_key, p_fallback);
    $f$ $fn$;
  execute $fn$
    create or replace function public._testlab_duration(p_s integer) returns text
    language sql immutable as $f$
      select case when p_s is null then ''
                  when p_s < 60 then p_s::text || 's'
                  else (p_s / 60)::text || 'm ' || lpad((p_s % 60)::text, 2, '0') || 's' end;
    $f$ $fn$;

  -- 2c. the command stamp: one column set the list chip and the block read
  execute $fn$
    create or replace function public._testlab_stamp(p_ids bigint[], p_run bigint, p_status text, p_summary text)
    returns void language plpgsql security definer set search_path=public as $f$
    begin
      if p_ids is null or cardinality(p_ids) = 0 then return; end if;
      update dev_commands
         set testlab_status = p_status, testlab_run_id = p_run,
             testlab_at = now(), testlab_summary = p_summary
       where id = any(p_ids);
    end $f$ $fn$;

  -- 2d. the spec-derived plan
  execute $fn$
    create or replace function public.android_testlab_plan(p_command_ids bigint[] default null)
    returns jsonb language plpgsql stable security definer set search_path=public as $f$
    declare cfg jsonb := _testlab_cfg(); v_text text := ''; v_checks text[]; r record;
            v_all text[]; v_core text[];
    begin
      select coalesce(array_agg(x), '{}') into v_all  from jsonb_array_elements_text(coalesce(cfg->'all_checks','[]'::jsonb)) x;
      select coalesce(array_agg(x), '{}') into v_core from jsonb_array_elements_text(coalesce(cfg->'core_checks','[]'::jsonb)) x;
      if p_command_ids is null or cardinality(p_command_ids) = 0 then
        return to_jsonb(v_all);            -- a release with no command: the full sweep
      end if;
      select string_agg(lower(coalesce(title,'') || ' ' || coalesce(spec,'') || ' ' || coalesce(enriched_spec,'')), ' ')
        into v_text from dev_commands where id = any(p_command_ids);
      v_checks := v_core;
      for r in select value as v from jsonb_array_elements(coalesce(cfg->'plan_rules','[]'::jsonb)) loop
        if exists (select 1 from jsonb_array_elements_text(coalesce(r.v->'any','[]'::jsonb)) k
                    where position(lower(k) in coalesce(v_text,'')) > 0) then
          if not ((r.v->>'check') = any(v_checks)) then v_checks := v_checks || (r.v->>'check'); end if;
        end if;
      end loop;
      return to_jsonb(v_checks);
    end $f$ $fn$;

  -- 2e. begin — every decision the script needs, in one answer
  execute $fn$
    create or replace function public.android_testlab_begin(
      p_command_ids bigint[] default null, p_release_id bigint default null, p_commit text default null,
      p_version_code integer default null, p_version_name text default null, p_track text default null,
      p_rehearsal boolean default false, p_worker text default null)
    returns jsonb language plpgsql security definer set search_path=public as $f$
    declare cfg jsonb := _testlab_cfg(); v_id bigint; v_cmd bigint; v_targets boolean; v_used int; v_quota int;
            v_plan jsonb; v_day date := _testlab_quota_day(); v_reason text; v_copy jsonb;
            v_ids bigint[] := coalesce(p_command_ids, '{}'::bigint[]);
    begin
      perform _dev_guard();
      v_cmd   := case when cardinality(v_ids) > 0 then v_ids[1] else null end;
      v_quota := coalesce((cfg->>'daily_quota')::int, 10);
      v_copy  := jsonb_build_object(
        'missing_secret', _testlab_copy('reason_missing_secret', 'Google credentials missing on the VM: save the Test Lab service-account key as {secret} in the Vault (Dev Queue → Google Cloud → Secrets). The run was not started and nothing was paid.'),
        'api_disabled',   _testlab_copy('reason_api_disabled',   'The Cloud Testing API is not enabled on {project} and the credentials on the VM cannot enable it.'),
        'no_permission',  _testlab_copy('reason_no_permission',  'The service account has no Firebase Test Lab role on {project}.'),
        'quota_gcloud',   _testlab_copy('reason_quota_gcloud',   'Firebase Test Lab refused the run: the free daily quota is used up. Nothing was paid; retry after the reset.'),
        'timeout',        _testlab_copy('reason_timeout',        'The Test Lab matrix did not finish within {timeout} — treated as failed.'),
        'build_failed',   _testlab_copy('reason_build_failed',   'The instrumentation build failed before any device ran: {detail}'),
        'infra',          _testlab_copy('reason_infra',          'Test Lab infrastructure error (gcloud exit {rc}) — not a verdict on the code.'));
      if not _testlab_enforced() then
        return jsonb_build_object('ok', true, 'allowed', false, 'status', 'skipped', 'copy', v_copy,
          'reason', _testlab_copy('reason_enforce_off', 'The Test Lab gate is switched off in build_rules.android_testlab')
                    || coalesce(': ' || nullif(cfg->>'enforce_off_reason',''), ''));
      end if;
      if v_cmd is not null and not coalesce(p_rehearsal, false) then
        select bool_or(coalesce(targets_android, false)) into v_targets from dev_commands where id = any(v_ids);
        if not coalesce(v_targets, false) then
          return jsonb_build_object('ok', true, 'allowed', false, 'status', 'skipped', 'copy', v_copy,
            'reason', _testlab_copy('reason_web_only', 'web-only command — Test Lab skipped'));
        end if;
      end if;
      select count(*) into v_used from android_testlab_run
       where quota_day = v_day and status in ('running','passed','failed','error');
      v_plan := android_testlab_plan(case when cardinality(v_ids) > 0 then v_ids else null end);
      if v_used >= v_quota then
        v_reason := replace(replace(_testlab_copy('reason_quota',
          'Free Test Lab quota used up for today ({used}/{quota} virtual runs) — it resets at midnight Pacific. The run was not started and nothing was paid.'),
          '{used}', v_used::text), '{quota}', v_quota::text);
        insert into android_testlab_run(command_id, command_ids, release_id, commit_sha, version_code, version_name, track,
                                        status, reason, summary, plan, quota_day, finished_at, rehearsal, worker)
             values (v_cmd, v_ids, p_release_id, p_commit, p_version_code, p_version_name, p_track,
                     'quota', v_reason, v_reason, v_plan, v_day, now(), coalesce(p_rehearsal,false), p_worker)
          returning id into v_id;
        perform _testlab_stamp(v_ids, v_id, 'quota', v_reason);
        return jsonb_build_object('ok', true, 'allowed', false, 'status', 'quota', 'run_id', v_id,
                                  'reason', v_reason, 'copy', v_copy, 'quota_used', v_used, 'quota', v_quota);
      end if;
      insert into android_testlab_run(command_id, command_ids, release_id, commit_sha, version_code, version_name, track,
                                      status, plan, quota_day, device_model, device_version, rehearsal, worker)
           values (v_cmd, v_ids, p_release_id, p_commit, p_version_code, p_version_name, p_track,
                   'running', v_plan, v_day, cfg->'device'->>'model', cfg->'device'->>'version',
                   coalesce(p_rehearsal,false), p_worker)
        returning id into v_id;
      perform _testlab_stamp(v_ids, v_id, 'running', _testlab_copy('summary_running', 'Test Lab run in progress'));
      return jsonb_build_object(
        'ok', true, 'allowed', true, 'status', 'running', 'run_id', v_id, 'plan', v_plan,
        'project',        coalesce(cfg->>'project', 'medibo-23aee'),
        'secret_name',    coalesce(cfg->>'secret_name', 'GCP_SA_KEY'),
        'device',         coalesce(cfg->'device', '{}'::jsonb),
        'fallback_models',coalesce(cfg->'fallback_models', '[]'::jsonb),
        'timeout_s',      coalesce((cfg->>'timeout_s')::int, 600),
        'test_target',    coalesce(cfg->>'test_target', 'integration_test/android_gate_test.dart'),
        'results_history',coalesce(cfg->>'results_history', 'medibo-testlab'),
        'pull_dir',       coalesce(cfg->>'pull_dir', '/sdcard/Download/medibo_testlab'),
        'results_prefix', coalesce(v_cmd::text, 'release-' || coalesce(p_release_id::text, '0')) || '/testlab/' || v_id::text,
        'quota_used',     v_used, 'quota', v_quota, 'copy', v_copy);
    end $f$ $fn$;

  -- 2f. finish — the verdict, the proofs, the stamp
  execute $fn$
    create or replace function public.android_testlab_finish(
      p_run_id bigint, p_status text, p_reason text default null, p_matrix_id text default null,
      p_console_url text default null, p_results_dir text default null, p_checks jsonb default '[]'::jsonb,
      p_proofs jsonb default '[]'::jsonb, p_outcome jsonb default '{}'::jsonb,
      p_device_model text default null, p_device_version text default null)
    returns jsonb language plpgsql security definer set search_path=public as $f$
    declare r record; v_dur int; v_summary text; v_n int; v_failed text; v_dev text; v_api text;
    begin
      perform _dev_guard();
      if p_status not in ('passed','failed','error','quota','blocked','skipped') then
        raise exception 'android_testlab_finish: unknown status %', p_status;
      end if;
      select * into r from android_testlab_run where id = p_run_id;
      if not found then raise exception 'android_testlab_finish: run % not found', p_run_id; end if;
      v_dur := greatest(0, extract(epoch from (now() - r.started_at)))::int;
      v_dev := coalesce(p_device_model, r.device_model, '?');
      v_api := coalesce(p_device_version, r.device_version, '?');
      select count(*) into v_n from jsonb_array_elements(coalesce(p_checks,'[]'::jsonb)) c where (c->>'ok')::boolean;
      select string_agg(coalesce(c->>'key','?') || coalesce(' (' || nullif(c->>'detail','') || ')', ''), '; ')
        into v_failed from jsonb_array_elements(coalesce(p_checks,'[]'::jsonb)) c where not coalesce((c->>'ok')::boolean, false);
      v_summary := case p_status
        when 'passed' then replace(replace(replace(replace(_testlab_copy('summary_passed',
                            'Passed on {device} API {api} in {duration} · {n} check(s) green'),
                            '{device}', v_dev), '{api}', v_api), '{duration}', _testlab_duration(v_dur)), '{n}', v_n::text)
        when 'failed' then replace(replace(replace(_testlab_copy('summary_failed', 'Failed on {device} API {api}: {detail}'),
                            '{device}', v_dev), '{api}', v_api), '{detail}', coalesce(nullif(p_reason,''), v_failed, 'see the checks'))
        else coalesce(nullif(p_reason,''), p_status) end;
      update android_testlab_run
         set status = p_status, reason = coalesce(p_reason, reason), summary = v_summary,
             matrix_id = coalesce(p_matrix_id, matrix_id), console_url = coalesce(p_console_url, console_url),
             results_dir = coalesce(p_results_dir, results_dir),
             checks = coalesce(p_checks, '[]'::jsonb), proofs = coalesce(p_proofs, '[]'::jsonb),
             outcome = coalesce(p_outcome, '{}'::jsonb),
             device_model = v_dev, device_version = v_api,
             finished_at = now(), duration_s = v_dur
       where id = p_run_id;
      perform _testlab_stamp(r.command_ids, p_run_id, p_status, v_summary);
      return jsonb_build_object('ok', true, 'run_id', p_run_id, 'status', p_status, 'summary', v_summary,
                                'duration_s', v_dur, 'checks_green', v_n);
    end $f$ $fn$;

  -- 2g. the gate publish_play.sh asks before a Production upload
  execute $fn$
    create or replace function public.android_testlab_gate(
      p_track text, p_kind text default 'publish', p_commit text default null, p_version_code integer default null)
    returns jsonb language plpgsql stable security definer set search_path=public as $f$
    declare cfg jsonb := _testlab_cfg(); v_age int := coalesce((cfg->>'gate_max_age_h')::int, 72); r record; v_reason text;
    begin
      perform _dev_guard();
      if coalesce(p_track,'') <> 'production' then
        return jsonb_build_object('ok', true, 'allowed', true, 'applies', false,
          'reason', replace(_testlab_copy('gate_not_production',
                    'not a Production upload (track {track}) — the Test Lab gate applies to Production only'),
                    '{track}', coalesce(p_track,'?')));
      end if;
      if not _testlab_enforced() then
        return jsonb_build_object('ok', true, 'allowed', true, 'applies', false,
          'reason', _testlab_copy('reason_enforce_off', 'The Test Lab gate is switched off in build_rules.android_testlab')
                    || coalesce(': ' || nullif(cfg->>'enforce_off_reason',''), ''));
      end if;
      if coalesce(p_commit,'') = '' and p_version_code is null then
        return jsonb_build_object('ok', true, 'allowed', false, 'applies', true,
          'reason', replace(_testlab_copy('gate_refused_none',
                    'Play Production upload refused — no Firebase Test Lab run is recorded for this build ({key}). Run scripts/android_testlab.sh first.'),
                    '{key}', 'no commit or version code given'));
      end if;
      select * into r from android_testlab_run
       where status = 'passed' and started_at > now() - make_interval(hours => v_age)
         and ((coalesce(p_commit,'') <> '' and commit_sha = p_commit)
              or (p_version_code is not null and version_code = p_version_code))
       order by finished_at desc nulls last limit 1;
      if found then
        return jsonb_build_object('ok', true, 'allowed', true, 'applies', true, 'run_id', r.id,
          'reason', replace(replace(_testlab_copy('gate_green', 'Firebase Test Lab green — run #{run}: {summary}'),
                    '{run}', r.id::text), '{summary}', coalesce(r.summary, '')));
      end if;
      select * into r from android_testlab_run
       where ((coalesce(p_commit,'') <> '' and commit_sha = p_commit)
              or (p_version_code is not null and version_code = p_version_code))
       order by started_at desc limit 1;
      if found then
        v_reason := replace(replace(replace(_testlab_copy('gate_refused_run',
                      'Play Production upload refused — Firebase Test Lab run #{run} is {status}: {reason}'),
                      '{run}', r.id::text), '{status}', r.status), '{reason}', coalesce(r.summary, r.reason, ''));
        return jsonb_build_object('ok', true, 'allowed', false, 'applies', true, 'run_id', r.id, 'reason', v_reason);
      end if;
      v_reason := replace(_testlab_copy('gate_refused_none',
                    'Play Production upload refused — no Firebase Test Lab run is recorded for this build ({key}). Run scripts/android_testlab.sh first.'),
                    '{key}', coalesce('commit ' || left(nullif(p_commit,''), 8), 'version code ' || p_version_code::text, '?'));
      return jsonb_build_object('ok', true, 'allowed', false, 'applies', true, 'reason', v_reason);
    end $f$ $fn$;

  -- 2h. a waiver on the record (runner only; reason mandatory)
  execute $fn$
    create or replace function public.android_testlab_waive(p_command_id bigint, p_reason text)
    returns jsonb language plpgsql security definer set search_path=public as $f$
    declare v_id bigint; v_line text;
    begin
      perform _dev_guard();
      if coalesce(btrim(p_reason),'') = '' then raise exception 'android_testlab_waive: a reason is required'; end if;
      v_line := replace(_testlab_copy('waived', 'Test Lab waived on the record: {reason}'), '{reason}', btrim(p_reason));
      insert into android_testlab_run(command_id, command_ids, status, reason, summary, quota_day, finished_at)
           values (p_command_id, array[p_command_id], 'skipped', btrim(p_reason), v_line, _testlab_quota_day(), now())
        returning id into v_id;
      perform _testlab_stamp(array[p_command_id], v_id, 'skipped', v_line);
      return jsonb_build_object('ok', true, 'run_id', v_id, 'status', 'skipped', 'summary', v_line);
    end $f$ $fn$;

  -- 2i. the chip and the tone the list renders verbatim
  execute $fn$
    create or replace function public._dev_testlab_chip(p_status text) returns text
    language sql stable security definer set search_path=public as $f$
      select case when coalesce(p_status,'') = '' then ''
                  else _dev_copy('dev_queue.testlab_chip_' || p_status, '🧪 Test Lab ' || p_status) end;
    $f$ $fn$;
  execute $fn$
    create or replace function public._dev_testlab_tone(p_status text) returns text
    language sql immutable as $f$
      select case coalesce(p_status,'')
               when 'passed'  then 'success'
               when 'running' then 'info'
               when 'failed'  then 'danger'
               when 'error'   then 'warning'
               when 'quota'   then 'warning'
               when 'blocked' then 'warning'
               when 'skipped' then 'neutral'
               else 'neutral' end;
    $f$ $fn$;

  -- 2j. the detail block — one payload, printed
  execute $fn$
    create or replace function public._dev_testlab_block(p_id bigint) returns jsonb
    language plpgsql stable security definer set search_path=public as $f$
    declare r record; v_checks jsonb; v_proofs jsonb; v_sub text;
    begin
      select * into r from android_testlab_run
       where command_id = p_id or p_id = any(command_ids)
       order by started_at desc limit 1;
      if not found then return jsonb_build_object('has', false); end if;
      -- per-check rows: the device's results when it ran, the plan (pending) before
      if jsonb_array_length(coalesce(r.checks,'[]'::jsonb)) > 0 then
        select jsonb_agg(jsonb_build_object(
                 'key',    c->>'key',
                 'label',  _dev_copy('dev_queue.testlab_check_' || coalesce(c->>'key',''), coalesce(c->>'key','')),
                 'ok',     coalesce((c->>'ok')::boolean, false),
                 'status', case when coalesce((c->>'ok')::boolean,false)
                                then _dev_copy('dev_queue.testlab_check_ok','ok')
                                else _dev_copy('dev_queue.testlab_check_failed','failed') end,
                 'tone',   case when coalesce((c->>'ok')::boolean,false) then 'success' else 'danger' end,
                 'detail', coalesce(c->>'detail','')) order by ord)
          into v_checks from jsonb_array_elements(r.checks) with ordinality as t(c, ord);
      else
        select jsonb_agg(jsonb_build_object(
                 'key', k, 'label', _dev_copy('dev_queue.testlab_check_' || k, k), 'ok', null,
                 'status', _dev_copy('dev_queue.testlab_check_pending','pending'), 'tone', 'neutral', 'detail', '') order by ord)
          into v_checks from jsonb_array_elements_text(coalesce(r.plan,'[]'::jsonb)) with ordinality as t(k, ord);
      end if;
      select jsonb_agg(jsonb_build_object(
               'kind',   p->>'kind',
               'label',  _dev_copy('dev_queue.testlab_proof_' || coalesce(p->>'kind',''), initcap(coalesce(p->>'kind',''))),
               'path',   p->>'path',
               'bucket', 'dev-cmd-proofs') order by ord)
        into v_proofs from jsonb_array_elements(coalesce(r.proofs,'[]'::jsonb)) with ordinality as t(p, ord);
      v_sub := concat_ws(' · ',
                 case when coalesce(r.device_model,'') = '' then null
                      else r.device_model || coalesce(' API ' || nullif(r.device_version,''), '') end,
                 nullif(_testlab_duration(r.duration_s), ''),
                 to_char(r.started_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') || ' IST');
      return jsonb_build_object(
        'has',          true,
        'run_id',       r.id,
        'title',        _dev_copy('dev_queue.testlab_section', 'Firebase Test Lab'),
        'status',       r.status,
        'label',        _dev_copy('dev_queue.testlab_' || r.status, initcap(r.status)),
        'tone',         _dev_testlab_tone(r.status),
        'sub',          coalesce(v_sub, ''),
        'detail',       coalesce(r.summary, r.reason, ''),
        'url',          coalesce(r.console_url, ''),
        'url_label',    _dev_copy('dev_queue.testlab_open', 'Open the matrix in the Firebase console'),
        'checks_title', _dev_copy('dev_queue.testlab_checks_title', 'Checks derived from the spec'),
        'checks',       coalesce(v_checks, '[]'::jsonb),
        'proofs_title', _dev_copy('dev_queue.testlab_proofs_title', 'Evidence from the device'),
        'proofs',       coalesce(v_proofs, '[]'::jsonb),
        'rehearsal',    coalesce(r.rehearsal, false));
    end $f$ $fn$;

  -- 2k. the finish-state 'android' condition: the release AND its Test Lab verdict
  execute $fn$
    create or replace function public._dev_android_gate(p_id bigint) returns text
    language plpgsql stable security definer set search_path=public as $f$
    declare r record; v_st text; v_tl text;
    begin
      select targets_android, android_status, android_built_at,
             android_artifact_url, android_version_code, testlab_status, testlab_summary
        into r from dev_commands where id = p_id;
      if not found then return null; end if;
      if not coalesce(r.targets_android, false) then return null; end if;

      v_st := coalesce(r.android_status, 'not_requested');

      if v_st = 'not_requested' then
        return _dev_copy('dev_queue.android_gate_not_requested',
          'An Android release was asked for and never built — android_status is still not_requested.');
      elsif v_st in ('requested','building') then
        return replace(_dev_copy('dev_queue.android_gate_unfinished',
          'The Android build is still {status} — no artifact has been recorded yet.'), '{status}', v_st);
      elsif v_st = 'failed' then
        return _dev_copy('dev_queue.android_gate_failed',
          'The Android build failed. Fix it and record the release, or drop it on the record.');
      elsif v_st in ('built','published') then
        if r.android_built_at is null
           or (coalesce(btrim(r.android_artifact_url), '') = '' and r.android_version_code is null) then
          return replace(_dev_copy('dev_queue.android_gate_no_proof',
            'android_status is {status} but nothing proves it — android_built_at and an artifact are both required.'),
            '{status}', v_st);
        end if;
        -- CMD #2076 — built is not enough: the Android-only code has to have
        -- RUN on an Android device. 'skipped' is a waiver on the record.
        v_tl := coalesce(r.testlab_status, '');
        if _testlab_enforced() and v_tl not in ('passed', 'skipped') then
          return replace(replace(_dev_copy('dev_queue.android_gate_testlab',
            'Firebase Test Lab has not passed for this Android build — the last run is {status}. {detail}'),
            '{status}', coalesce(nullif(v_tl,''), 'not run')), '{detail}', coalesce(r.testlab_summary, ''));
        end if;
        return null;
      end if;

      return null;   -- 'skipped': waived on the record, with a reason
    end $f$ $fn$;

  execute 'revoke all on function public.android_testlab_plan(bigint[]) from anon, authenticated';
  execute 'revoke all on function public.android_testlab_begin(bigint[],bigint,text,integer,text,text,boolean,text) from anon, authenticated';
  execute 'revoke all on function public.android_testlab_finish(bigint,text,text,text,text,text,jsonb,jsonb,jsonb,text,text) from anon, authenticated';
  execute 'revoke all on function public.android_testlab_gate(text,text,text,integer) from anon, authenticated';
  execute 'revoke all on function public.android_testlab_waive(bigint,text) from anon, authenticated';
  execute 'grant execute on function public.android_testlab_plan(bigint[]) to service_role';
  execute 'grant execute on function public.android_testlab_begin(bigint[],bigint,text,integer,text,text,boolean,text) to service_role';
  execute 'grant execute on function public.android_testlab_finish(bigint,text,text,text,text,text,jsonb,jsonb,jsonb,text,text) to service_role';
  execute 'grant execute on function public.android_testlab_gate(text,text,text,integer) to service_role';
  execute 'grant execute on function public.android_testlab_waive(bigint,text) to service_role';
end $mig$;

-- ── 3. the row chip: patch _dev_cmd_rows IN PLACE ────────────────────────────
-- Redefining a 300-line function by hand is how one command's field silently
-- erases another's. This reads the LIVE definition, inserts three select-list
-- expressions after an anchor that #1950 owns, and executes the result — so it
-- composes with whatever else has changed the function, in any replay order.
do $mig$
declare v_def text; v_anchor text := '_dev_phone_proof_tone(dc.id) as phone_proof_tone,'; v_add text; v_oid oid;
begin
  if to_regclass('public.dev_commands') is null then return; end if;
  select oid into v_oid from pg_proc where proname = '_dev_cmd_rows' and pronamespace = 'public'::regnamespace limit 1;
  if v_oid is null then return; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('testlab_chip' in v_def) > 0 then return; end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'c2076: anchor "%" not found in _dev_cmd_rows — the row chip could not be added', v_anchor;
  end if;
  v_add := $q$
           -- CMD #2076 — the Test Lab verdict, printed by the list card.
           coalesce(dc.testlab_status, '') as testlab_status,
           _dev_testlab_chip(dc.testlab_status) as testlab_chip,
           _dev_testlab_tone(dc.testlab_status) as testlab_tone,$q$;
  v_def := replace(v_def, v_anchor, v_anchor || v_add);
  execute v_def;
end $mig$;

-- ── 3b. the card whitelist: patch _dev_card_keys IN PLACE ────────────────────
-- dev_cmd_list strips every card to _dev_card_keys() (#887); a chip that is
-- not on that list never reaches the phone. Same in-place patch as above.
do $mig$
declare v_def text; v_anchor text := $a$'phone_proof_chip','phone_proof_tone',$a$; v_oid oid;
begin
  if to_regclass('public.dev_commands') is null then return; end if;
  select oid into v_oid from pg_proc where proname = '_dev_card_keys' and pronamespace = 'public'::regnamespace limit 1;
  if v_oid is null then return; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('testlab_chip' in v_def) > 0 then return; end if;
  if position(v_anchor in v_def) = 0 then
    raise exception 'c2076: anchor % not found in _dev_card_keys — the row chip would be stripped from the card', v_anchor;
  end if;
  v_def := replace(v_def, v_anchor, v_anchor || $a$
    'testlab_status','testlab_chip','testlab_tone',$a$);
  execute v_def;
end $mig$;

-- ── 4. the detail block: patch dev_cmd_get IN PLACE (same reason) ────────────
do $mig$
declare v_def text; v_oid oid; v_new text;
begin
  if to_regclass('public.dev_commands') is null then return; end if;
  select oid into v_oid from pg_proc where proname = 'dev_cmd_get' and pronamespace = 'public'::regnamespace limit 1;
  if v_oid is null then return; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('_dev_testlab_block' in v_def) > 0 then return; end if;
  v_new := regexp_replace(v_def,
             $p$('android',\s*public\._dev_android_block\(p_id\),)$p$,
             $r$\1
      'testlab',              public._dev_testlab_block(p_id),$r$);
  if v_new = v_def then
    raise exception 'c2076: the android block anchor was not found in dev_cmd_get — the Test Lab block could not be added';
  end if;
  execute v_new;
end $mig$;

-- ── 5. the guard (both databases) ────────────────────────────────────────────
do $mig$
begin
  if to_regclass('public.rg_behavior_tests') is null then return; end if;
  insert into rg_behavior_tests (name, enabled, note, body) values (
   'android_testlab_rule_present', true,
   'CMD #2076 — the Android Test Lab gate: build_rules.android_testlab must exist with its gate, rule text, a free-tier budget (timeout <= 600 s, daily quota <= 10, one device) and enforce=true (or a written enforce_off_reason); and once scripts/android_testlab.sh selfcheck has written the android_testlab_gate_wired verdict, that verdict must be green and fresh.',
   $t$do $b$
  declare v jsonb; v_verdict jsonb; v_max_age int;
  begin
    select value->'android_testlab' into v from dev_runner_config where key='build_rules';
    if v is null or coalesce(v->>'rule','') = '' then
      raise exception 'RG_FAIL: dev_runner_config.build_rules.android_testlab is missing or has no rule text (CMD #2076) — the Play Production upload would no longer be gated on a Test Lab run.';
    end if;
    if coalesce(v->>'gate','') <> 'c_android_testlab' then
      raise exception 'RG_FAIL: build_rules.android_testlab.gate is %, expected c_android_testlab', coalesce(v->>'gate','(null)');
    end if;
    if coalesce((v->>'timeout_s')::int, 0) < 1 or coalesce((v->>'timeout_s')::int, 0) > 600 then
      raise exception 'RG_FAIL: build_rules.android_testlab.timeout_s must be 1..600 (one run, <= 10 min), found %', coalesce(v->>'timeout_s','(null)');
    end if;
    if coalesce((v->>'daily_quota')::int, 0) < 1 or coalesce((v->>'daily_quota')::int, 0) > 10 then
      raise exception 'RG_FAIL: build_rules.android_testlab.daily_quota must be 1..10 (the free Spark quota — never pay), found %', coalesce(v->>'daily_quota','(null)');
    end if;
    if coalesce(v->'device'->>'model','') = '' or coalesce(v->'device'->>'version','') = '' then
      raise exception 'RG_FAIL: build_rules.android_testlab.device must name one model and one API version';
    end if;
    if not coalesce((v->>'enforce')::boolean, true) and coalesce(btrim(v->>'enforce_off_reason'),'') = '' then
      raise exception 'RG_FAIL: build_rules.android_testlab.enforce is false with no enforce_off_reason — switching the gate off needs a written reason';
    end if;

    -- The hooks live in shell scripts no SQL can read; the selfcheck greps
    -- them and reports here. Never written is "not measured yet", not red.
    select to_jsonb(r) into v_verdict from rg_runner_verdict r where r.name='android_testlab_gate_wired';
    v_max_age := coalesce((v->>'verdict_max_age_h')::int, 168);
    if v_verdict is not null then
      if not coalesce((v_verdict->>'ok')::boolean,false) then
        raise exception 'RG_FAIL: the Android Test Lab gate is no longer wired — %',
          coalesce(v_verdict->>'detail','(no detail)');
      end if;
      if (v_verdict->>'at')::timestamptz < now() - make_interval(hours => v_max_age) then
        raise exception 'RG_FAIL: the android_testlab_gate_wired verdict is stale (last written %) — scripts/android_testlab.sh selfcheck has not run since',
          (v_verdict->>'at');
      end if;
    end if;
    raise exception 'RG_ROLLBACK';
  end $b$;$t$)
  on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;
end $mig$;
