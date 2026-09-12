-- CHANGE #1802 — an Android release that was ASKED FOR can no longer be
-- reported as "nothing to deploy".
--
-- #1801 was given one job: build the AAB and publish it. It closed itself 8/8
-- as "backend only, nothing to deploy" while targets_android was true,
-- android_status was 'not_requested', android_artifact_url was NULL and
-- android_built_at was NULL. Nothing in the finish gate looked at Android at
-- all: dev_cmd_finish_state gates the WEB deploy (targets_web -> change number,
-- preview promoted, self-test) and has no Android condition, and
-- dev_cmd_complete's bug-loop block is inert because worker_pool.bugloop.enforce
-- is false. So a row whose whole purpose was a Play release could close green
-- with every Android column at its default, and the only way to notice was to
-- open the Play Console by hand.
--
-- This adds the missing condition, on the same footing as the spec checklist:
-- a HARD raise inside dev_cmd_complete (not behind bugloop.enforce, because the
-- flag that is off is exactly why this got through), a refusal on the fast
-- path, and a blocker in dev_cmd_finish_state so the harness's own auto-finish
-- cannot fire either. Silence is closed off in every direction; the two ways
-- OUT are both explicit and both leave a record:
--   dev_cmd_android_record(id, status, url, built_at, name, code) — it shipped
--   dev_cmd_android_skip(id, reason)                             — it did not,
--                                                                  and why.
--
-- Everything the screen prints is a ui_copy row, so the wording of a refusal is
-- an UPDATE and never a deploy.
--
-- Idempotent, and safe on BOTH databases: after #1761 the control plane holds
-- dev_commands and production does not, so every statement that touches that
-- table is guarded by to_regclass and the function bodies are plpgsql (never
-- validated against a table that is not there).

-- ── 1. the columns and the vocabulary ──────────────────────────────────────
do $mig$
begin
  if to_regclass('public.dev_commands') is null then return; end if;

  alter table public.dev_commands add column if not exists android_version_name text;
  alter table public.dev_commands add column if not exists android_version_code integer;

  -- 'published' (it is on a Play track) and 'skipped' (deliberately waived,
  -- with a reason) are the two terminal states the old vocabulary had no word
  -- for, so every finished release had to be filed as 'built' or left at its
  -- default. Both are what the gate reads.
  alter table public.dev_commands drop constraint if exists dev_commands_android_status_check;
  alter table public.dev_commands add constraint dev_commands_android_status_check
    check (android_status = any (array['not_requested','requested','building',
                                       'built','published','failed','skipped']));
end $mig$;


do $mig$
begin
  if to_regclass('public.ui_copy') is null then return; end if;
  insert into public.ui_copy(key, value) values
    ('dev_queue.android_published',   to_jsonb('Published to Play'::text)),
    ('dev_queue.android_skipped',     to_jsonb('Android skipped'::text)),
    -- The block on the detail screen names the STATE; the chip in the target
    -- row names the ACTION. They are different sentences, so they are
    -- different keys — the chip's 'Android' would read as a heading here.
    ('dev_queue.android_block_not_requested', to_jsonb('Not built'::text)),
    ('dev_queue.android_block_requested',     to_jsonb('Queued'::text)),
    ('dev_queue.android_block_building',      to_jsonb('Building'::text)),
    ('dev_queue.android_block_built',         to_jsonb('Built'::text)),
    ('dev_queue.android_block_published',     to_jsonb('Published to Play'::text)),
    ('dev_queue.android_block_failed',        to_jsonb('Build failed'::text)),
    ('dev_queue.android_block_skipped',       to_jsonb('Skipped, on the record'::text)),
    ('dev_queue.android_section',     to_jsonb('Android release'::text)),
    ('dev_queue.android_open',        to_jsonb('Download the APK'::text)),
    ('dev_queue.android_gate_not_requested', to_jsonb(
       'An Android release was asked for and never built — android_status is still not_requested. Build and publish it, record it with dev_cmd_android_record, or drop it on the record with dev_cmd_android_skip.'::text)),
    ('dev_queue.android_gate_unfinished', to_jsonb(
       'The Android build is still {status} — no artifact has been recorded yet.'::text)),
    ('dev_queue.android_gate_failed', to_jsonb(
       'The Android build failed. Fix it and record the release, or drop it on the record with dev_cmd_android_skip.'::text)),
    ('dev_queue.android_gate_no_proof', to_jsonb(
       'android_status is {status} but nothing proves it — android_built_at and an artifact (URL or versionCode) are both required.'::text))
  on conflict (key) do nothing;   -- never overwrite wording Om has edited
end $mig$;

-- ── 7. the phone's own update reminder ─────────────────────────────────────
-- app_releases lives on PRODUCTION and app_update_check reads it there, but
-- after #1761 publish_play.sh wrote the row through play_publish_finish on the
-- CONTROL PLANE, where nothing reads it: 1.3.24 (38) went live on Play while
-- production's newest app_releases row still said 1.3.23, so every phone was
-- told it was up to date. The script now calls this function (which devcmd
-- already routes to production) — and this function has to let the runner in.
-- The role check was written for a human in the admin UI; the release is made
-- by a service_role runner that has no auth.uid() at all, so it answered
-- "Only an admin can publish a release" to the one caller that ever publishes.
create or replace function public.app_release_publish(
  p_version_name text, p_version_code integer, p_apk_url text,
  p_notes text default null, p_mandatory boolean default false,
  p_platform text default 'android')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
begin
  if not (
        coalesce(auth.jwt()->>'role','') = 'service_role'
     or get_my_role() in ('admin','super_admin')
     or (coalesce(current_setting('request.jwt.claims', true), '') = ''
         and session_user in ('postgres','supabase_admin'))
  ) then
    return jsonb_build_object('error','not_authorized','message','Only an admin can publish a release');
  end if;
  insert into app_releases(platform, version_name, version_code, apk_url, notes, is_mandatory, released_by)
  values (coalesce(p_platform,'android'), btrim(p_version_name), p_version_code,
          nullif(btrim(p_apk_url),''), nullif(btrim(p_notes),''), coalesce(p_mandatory,false), auth.uid())
  on conflict (platform, version_code) do update
     set version_name = excluded.version_name, apk_url = excluded.apk_url,
         notes = excluded.notes, is_mandatory = excluded.is_mandatory, released_at = now();
  return jsonb_build_object('ok', true, 'message', 'Release ' || p_version_name || ' published');
end $fn$;


-- ── THE CONTROL-PLANE HALF ─────────────────────────────────────────────────
-- Everything below belongs to medibo-dev, which is where dev_commands lives
-- after CHANGE #1761. It is wrapped because the merge worker replays every
-- file on production too, and `declare c dev_commands%rowtype` is the ONE
-- plpgsql construct resolved at CREATE time: batch 560 died on production at
-- exactly that line while every other body sailed through, leaving a handful
-- of dev_cmd_* orphans on the database #1761 had just cleared them off. So the
-- guard does two jobs — it skips the half that does not belong, and it REMOVES
-- what the unguarded run left behind, which is why the drops are not dead code.
do $cp$
begin
  if to_regclass('public.dev_commands') is null then
    drop function if exists public.dev_cmd_android_record(bigint,text,text,timestamptz,text,integer,text);
    drop function if exists public.dev_cmd_android_skip(bigint,text);
    drop function if exists public._dev_android_block(bigint);
    drop function if exists public._dev_android_gate(bigint);
    drop function if exists public._dev_copy(text,text);
    drop function if exists public.dev_cmd_finish_state(bigint);
    drop function if exists public.dev_cmd_complete(bigint,text,integer,jsonb,text,jsonb);
    drop function if exists public.dev_cmd_complete_fast(bigint,integer,text);
    return;
  end if;

  execute $sql$
-- ── 0. copy lookup ─────────────────────────────────────────────────────────
create or replace function public._dev_copy(p_key text, p_fallback text)
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare v text;
begin
  begin
    select value #>> '{}' into v from ui_copy where key = p_key;
  exception when others then v := null;
  end;
  return coalesce(nullif(btrim(coalesce(v,'')), ''), p_fallback);
end $fn$
$sql$;

  execute $sql$

-- ── 2. the gate ────────────────────────────────────────────────────────────
-- Returns the sentence that refuses the completion, or NULL when the row is
-- free to close. Every caller prints it verbatim.
create or replace function public._dev_android_gate(p_id bigint)
returns text language plpgsql stable security definer set search_path to 'public' as $fn$
declare r record; v_st text;
begin
  select targets_android, android_status, android_built_at,
         android_artifact_url, android_version_code
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
    return null;
  end if;

  return null;   -- 'skipped': waived on the record, with a reason
end $fn$
$sql$;

  execute $sql$

-- ── 3. what the screen prints ──────────────────────────────────────────────
create or replace function public._dev_android_block(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare r record; v_block text; v_label text; v_tone text; v_sub text; v_ver text;
begin
  select targets_android, android_status, android_built_at, android_artifact_url,
         android_version_name, android_version_code, android_build_type
    into r from dev_commands where id = p_id;
  if not found or not coalesce(r.targets_android, false) then
    return jsonb_build_object('has', false);
  end if;

  v_block := _dev_android_gate(p_id);
  v_label := _dev_copy('dev_queue.android_block_' || coalesce(r.android_status,'not_requested'),
             _dev_copy('dev_queue.android_' || coalesce(r.android_status,'not_requested'),
                       initcap(replace(coalesce(r.android_status,'not_requested'), '_', ' '))));
  v_tone := case coalesce(r.android_status,'not_requested')
              when 'published' then 'success'
              when 'built'     then 'success'
              when 'failed'    then 'danger'
              when 'skipped'   then 'neutral'
              when 'building'  then 'warning'
              when 'requested' then 'warning'
              else 'warning' end;

  v_ver := case when coalesce(btrim(r.android_version_name),'') = '' then null
                else r.android_version_name ||
                     coalesce(' (' || r.android_version_code::text || ')', '') end;
  v_sub := concat_ws(' · ', v_ver,
             case when r.android_built_at is null then null
                  else to_char(r.android_built_at at time zone 'Asia/Kolkata',
                               'DD Mon YYYY, HH12:MI AM') || ' IST' end);

  return jsonb_build_object(
    'has',       true,
    'title',     _dev_copy('dev_queue.android_section', 'Android release'),
    'status',    coalesce(r.android_status,'not_requested'),
    'label',     v_label,
    'tone',      v_tone,
    'sub',       coalesce(nullif(v_sub,''), ''),
    'url',       coalesce(r.android_artifact_url, ''),
    'url_label', _dev_copy('dev_queue.android_open', 'Download the APK'),
    'blocker',   coalesce(v_block, ''));
end $fn$
$sql$;

  execute $sql$

-- ── 4. the two ways a runner answers the gate ──────────────────────────────
create or replace function public.dev_cmd_android_record(
  p_id bigint,
  p_status text,
  p_artifact_url text default null,
  p_built_at timestamptz default null,
  p_version_name text default null,
  p_version_code integer default null,
  p_build_type text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_st text;
begin
  perform _dev_guard();
  v_st := lower(btrim(coalesce(p_status, '')));
  if v_st not in ('requested','building','built','published','failed') then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', 'status must be one of requested, building, built, published, failed');
  end if;

  update dev_commands set
    targets_android       = true,
    android_status        = v_st,
    android_artifact_url  = coalesce(nullif(btrim(coalesce(p_artifact_url,'')), ''), android_artifact_url),
    android_built_at      = coalesce(p_built_at,
                              case when v_st in ('built','published') then now() else android_built_at end),
    android_version_name  = coalesce(nullif(btrim(coalesce(p_version_name,'')), ''), android_version_name),
    android_version_code  = coalesce(p_version_code, android_version_code),
    android_build_type    = coalesce(nullif(btrim(coalesce(p_build_type,'')), ''), android_build_type)
  where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no such command', 'id', p_id);
  end if;

  perform _audit('system','dev_cmd_android_record', p_id::text,
    jsonb_build_object('status', v_st, 'version_code', p_version_code,
                       'artifact_url', p_artifact_url));
  return jsonb_build_object('ok', true, 'android', _dev_android_block(p_id),
                            'blocker', coalesce(_dev_android_gate(p_id), ''));
end $fn$
$sql$;

  execute $sql$

-- The ONLY way past the gate without a release, and it costs a reason that is
-- written into the command's own decision log — the same standard every other
-- choice a runner makes alone is held to.
create or replace function public.dev_cmd_android_skip(p_id bigint, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_r text;
begin
  perform _dev_guard();
  v_r := btrim(coalesce(p_reason, ''));
  if length(v_r) < 10 then
    return jsonb_build_object('ok', false, 'error', 'reason_required',
      'message', 'skipping an Android release that was asked for needs a reason, not a flag');
  end if;

  update dev_commands set
    android_status = 'skipped',
    decisions = coalesce(decisions, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'question', 'An Android release was requested on this command — build it?',
      'options',  jsonb_build_array('build and publish it', 'skip it, with a reason'),
      'picked',   'skipped',
      'reason',   v_r,
      'at',       now()))
  where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no such command', 'id', p_id);
  end if;

  perform _audit('system','dev_cmd_android_skip', p_id::text, jsonb_build_object('reason', v_r));
  return jsonb_build_object('ok', true, 'android', _dev_android_block(p_id));
end $fn$
$sql$;

  execute $sql$

grant execute on function public.dev_cmd_android_record(bigint,text,text,timestamptz,text,integer,text) to authenticated, service_role
$sql$;

  execute $sql$
grant execute on function public.dev_cmd_android_skip(bigint,text) to authenticated, service_role
$sql$;

  execute $sql$

-- ── 5. the gate, wired into every door a command can leave by ──────────────
-- Three callers, one sentence. dev_cmd_finish_state so the harness's own
-- auto-finish sees it; dev_cmd_complete so the runner's own call is refused;
-- dev_cmd_complete_fast so phase 1 of the spooled two-phase write cannot slip
-- past phase 2's check. Bodies below are the live definitions with the Android
-- condition inserted — nothing else in them is changed.

CREATE OR REPLACE FUNCTION public.dev_cmd_finish_state(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v jsonb := '[]'::jsonb; v_block text[] := '{}';
        v_android text;
        v_gate boolean; v_proofs jsonb; v_missing text; v_change int;
        v_cfg jsonb; v_on boolean; v_grace int; v_selftest boolean;
        v_ready boolean; v_journeys int; v_spec text; v_spec_open int;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  select coalesce(value->'finish_gate', '{}'::jsonb) into v_cfg
    from dev_runner_config where key = 'worker_pool';
  v_on    := coalesce((v_cfg->>'enabled')::boolean, true);
  v_grace := coalesce((v_cfg->>'grace_s')::int, 120);

  v_gate := (coalesce(r.kind,'dev') = 'dev' and coalesce(r.route,'') <> 'fast' and coalesce(r.qa_required,false));

  if r.status <> 'building' then v_block := array_append(v_block, (('not building (' || r.status || ')'))::text); end if;
  if coalesce(r.needs_input_question,'') <> '' then v_block := array_append(v_block, ('an unanswered question is open')::text); end if;
  -- CHANGE #571 (2) — a parked row is WAITING, not finished. It must never be
  -- auto-completed while its blocker is still being waited on.
  if r.wait_state = 'parked' then
    v_block := array_append(v_block, ('parked: ' || coalesce(r.wait_reason,'waiting'))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','building','label','Row is building',
        'applies', true, 'ok', r.status = 'building' and coalesce(r.needs_input_question,'') = ''
                                and r.wait_state is distinct from 'parked',
        'detail', case when r.wait_state = 'parked' then 'parked' else r.status end));

  v := v || jsonb_build_array(jsonb_build_object('key','steps','label','Every step marked done',
        'applies', true,
        'ok', coalesce(r.steps_total,0) > 0 and coalesce(r.steps_done,0) >= r.steps_total,
        'detail', coalesce(r.steps_done,0)::text || '/' || coalesce(r.steps_total,0)::text));
  if coalesce(r.steps_total,0) = 0 then
    v_block := array_append(v_block, ('no step plan published')::text);
  elsif coalesce(r.steps_done,0) < r.steps_total then
    v_block := array_append(v_block, (('steps ' || coalesce(r.steps_done,0) || '/' || r.steps_total))::text);
  end if;

  -- CHANGE #571 (3) — the command's OWN spec checklist, on the same footing
  -- as the step plan. #536 finished with My Shop nav and Profile cleanup
  -- unbuilt because nothing ever compared the result against the spec.
  select count(*) into v_spec_open from dev_command_spec_item
   where command_id = p_id and status = 'open';
  v_spec := _dev_spec_gate(p_id);
  if v_spec is not null then v_block := array_append(v_block, v_spec::text); end if;
  v := v || jsonb_build_array(jsonb_build_object('key','spec','label','Every spec item built',
        'applies', exists (select 1 from dev_command_spec_item where command_id = p_id),
        'ok', coalesce(v_spec_open,0) = 0,
        'detail', ((select count(*) from dev_command_spec_item
                     where command_id = p_id and status <> 'open')::text || '/' ||
                   (select count(*) from dev_command_spec_item where command_id = p_id)::text)));

  if v_gate and coalesce(r.qa_status,'pending') not in ('passed','waived') then
    v_block := array_append(v_block, (('QA is ' || coalesce(r.qa_status,'pending')))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','qa','label','QA passed',
        'applies', v_gate, 'ok', (not v_gate) or coalesce(r.qa_status,'') in ('passed','waived'),
        'detail', coalesce(r.qa_status,'')));

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

  v_proofs := case when jsonb_array_length(coalesce(r.screenshots,'[]'::jsonb)) > 0
                   then r.screenshots else _dev_finish_proofs(p_id) end;
  if v_gate and jsonb_array_length(v_proofs) = 0 then
    v_block := array_append(v_block, ('no screenshot evidence in dev-cmd-proofs')::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','proof','label','Screenshot proof stored',
        'applies', v_gate, 'ok', (not v_gate) or jsonb_array_length(v_proofs) > 0,
        'detail', jsonb_array_length(v_proofs)::text));

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

  -- CHANGE #1802 — the ANDROID condition, on the same footing as the web
  -- deploy above. #1801 closed 8/8 green with targets_android true and every
  -- Android column at its default, because nothing here ever looked.
  v_android := _dev_android_gate(p_id);
  if v_android is not null then v_block := array_append(v_block, v_android::text); end if;
  v := v || jsonb_build_array(jsonb_build_object('key','android','label','Android release recorded',
        'applies', coalesce(r.targets_android,false),
        'ok', v_android is null,
        'detail', coalesce(r.android_status,'not_requested')));

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
    'spec_open', coalesce(v_spec_open,0),
    'waiting', r.wait_state = 'parked',
    'wait_reason', coalesce(r.wait_reason,''),
    'ready_at', r.finish_ready_at,
    'auto_finished', coalesce(r.auto_finished,false),
    'auto_finish_source', coalesce(r.auto_finish_source,''));
end $function$
$sql$;

  execute $sql$

CREATE OR REPLACE FUNCTION public.dev_cmd_complete(p_id bigint, p_result text, p_deploy_no integer DEFAULT NULL::integer, p_screenshots jsonb DEFAULT '[]'::jsonb, p_plain_summary text DEFAULT NULL::text, p_result_actions jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '30s'
AS $function$
DECLARE v_rg jsonb; v_row record; v_enforce boolean; v_missing text; v_block text := NULL;
        v_android text;
        v_selftest record; v_spec text;
BEGIN
  PERFORM _dev_guard();

  -- CHANGE #641 — rg_check(true,true) used to run HERE, inside a 180 s
  -- statement, on the caller's connection. It is now cron-only; this is a read.
  SELECT jsonb_build_object('ok', c.ok, 'at', c.at,
           'age_s', round(extract(epoch from now() - c.at))::int)
    INTO v_rg FROM rg_check_cache c ORDER BY c.at DESC LIMIT 1;

  SELECT * INTO v_row FROM dev_commands WHERE id=p_id;
  SELECT coalesce((value->'bugloop'->>'enforce')::boolean,false) INTO v_enforce FROM dev_runner_config WHERE key='worker_pool';

  v_spec := _dev_spec_gate(p_id);
  IF v_spec IS NOT NULL THEN
    RAISE EXCEPTION 'dev_cmd_complete blocked (spec gate): %', v_spec;
  END IF;

  -- CHANGE #1802 — the Android gate raises like the spec gate and NOT behind
  -- worker_pool.bugloop.enforce. That flag is false, which is precisely how
  -- #1801 reported "nothing to deploy" on a row whose only job was a Play
  -- release: a warning nobody reads is not a gate.
  v_android := _dev_android_gate(p_id);
  IF v_android IS NOT NULL THEN
    RAISE EXCEPTION 'dev_cmd_complete blocked (android gate): %', v_android;
  END IF;

  IF v_row.kind='dev' AND v_row.route <> 'fast' AND v_row.qa_required THEN
    IF v_row.qa_status NOT IN ('passed','waived') THEN
      v_block := 'QA verdict is '||v_row.qa_status||' — qa_report(passed) or qa_waive(PIN) required';
    END IF;
    IF v_block IS NULL AND EXISTS (
      SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.status='failed'
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr2 WHERE jr2.command_id=p_id AND jr2.journey_id=jr.journey_id AND jr2.status='passed' AND jr2.id>jr.id)
    ) THEN v_block := 'a journey run failed without a later pass'; END IF;
    IF v_block IS NULL THEN
      SELECT string_agg(j.name, ', ') INTO v_missing
      FROM dev_journeys j
      WHERE j.enabled
        AND (
              (j.required AND (j.area IS NULL OR j.area IS NOT DISTINCT FROM v_row.area))
              OR j.source_bug = p_id
            )
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.journey_id=j.id AND jr.status='passed');
      IF v_missing IS NOT NULL THEN v_block := 'required journeys not passed: '||v_missing; END IF;
    END IF;
    IF v_block IS NULL AND jsonb_array_length(coalesce(p_screenshots,'[]')) = 0 THEN
      v_block := 'no screenshot evidence attached';
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL THEN
      SELECT * INTO v_selftest FROM dev_selftest_log
       WHERE ok AND at > now() - interval '6 hours'
       ORDER BY at DESC LIMIT 1;
      IF NOT FOUND THEN
        v_block := 'no green self-test on record in the last 6h — scripts/selftest.sh '
                || '(protected suite + focused test) must pass before a web deploy';
      END IF;
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL AND v_row.targets_web
       AND coalesce(v_row.preview_status,'') <> 'promoted' THEN
      v_block := 'web deploy without preview→promote (preview_status='||coalesce(v_row.preview_status,'null')||')';
    END IF;

    IF v_block IS NOT NULL THEN
      IF v_enforce THEN
        RAISE EXCEPTION 'dev_cmd_complete blocked (bug-loop gate): %', v_block;
      ELSE
        PERFORM _audit('system','bugloop_warn', p_id::text, jsonb_build_object('would_block', v_block));
      END IF;
    END IF;
  END IF;

  UPDATE dev_commands SET
    status='completed', finished_at=now(),
    title = _dev_title(title, build_log),
    result_summary = p_result,
    plain_summary = coalesce(p_plain_summary, plain_summary),
    result_actions = coalesce(p_result_actions, '[]'::jsonb),
    web_deploy_no = coalesce(p_deploy_no, web_deploy_no),
    web_deployed_at = CASE WHEN p_deploy_no IS NOT NULL THEN now() ELSE web_deployed_at END,
    screenshots = coalesce(p_screenshots, '[]'),
    wait_state = NULL, wait_kind = NULL, wait_until = NULL
  WHERE id = p_id AND status='building';
  IF NOT FOUND THEN RAISE EXCEPTION 'dev_cmd_complete: row % not in building', p_id; END IF;
  IF coalesce(p_result,'') <> '' OR coalesce(p_plain_summary,'') <> '' THEN
    INSERT INTO dev_command_messages (command_id, sender, body, images, attachments)
    VALUES (p_id, 'agent',
      coalesce(nullif(p_plain_summary,''), p_result) ||
        CASE WHEN p_deploy_no IS NOT NULL THEN E'\n\n✅ CHANGE #'||p_deploy_no||' deployed' ELSE '' END,
      '[]', '[]');
  END IF;
  PERFORM _lease_release_internal(p_id);
  RETURN jsonb_build_object('ok', true, 'rg_last', v_rg, 'bugloop_warn', v_block);
END $function$
$sql$;

  execute $sql$

CREATE OR REPLACE FUNCTION public.dev_cmd_complete_fast(p_id bigint, p_deploy_no integer DEFAULT NULL::integer, p_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '10s'
AS $function$
declare r record; v_spec text; v_block text := null; v_enforce boolean; v_rg jsonb; v_android text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status = 'completed' then
    return jsonb_build_object('ok', true, 'already', true, 'id', p_id, 'status', 'completed',
      'change_no', r.web_deploy_no,
      'note', 'already completed — a retry of the fast write is a no-op by design');
  end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', false, 'error', 'not building', 'status', r.status);
  end if;

  -- CHANGE #571 (3) — the spec checklist gates the fast path too. Cheap: one
  -- indexed count over dev_command_spec_item.
  v_spec := _dev_spec_gate(p_id);
  if v_spec is not null then
    return jsonb_build_object('ok', false, 'retryable', false, 'blocked_by', 'spec_items',
      'error', v_spec, 'spec', dev_cmd_spec_items(p_id));
  end if;

  -- CHANGE #1802 — same refusal on the fast path. Phase 1 flips the status;
  -- a gate that only lives in phase 2 is a gate the spool walks straight past.
  v_android := _dev_android_gate(p_id);
  if v_android is not null then
    return jsonb_build_object('ok', false, 'retryable', false,
      'blocked_by', 'android_release', 'error', v_android,
      'android', _dev_android_block(p_id));
  end if;

  select coalesce((value->'bugloop'->>'enforce')::boolean, false) into v_enforce
    from dev_runner_config where key = 'worker_pool';
  if v_enforce and coalesce(r.kind,'dev') = 'dev' and coalesce(r.route,'') <> 'fast'
     and coalesce(r.qa_required,false) then
    if coalesce(r.qa_status,'pending') not in ('passed','waived') then
      v_block := 'QA is ' || coalesce(r.qa_status,'pending');
    elsif coalesce(r.steps_total,0) > 0 and coalesce(r.steps_done,0) < r.steps_total then
      v_block := 'steps ' || coalesce(r.steps_done,0) || '/' || r.steps_total;
    end if;
    if v_block is not null then
      return jsonb_build_object('ok', false, 'retryable', false, 'error',
        'bug-loop gate: ' || v_block);
    end if;
  end if;

  update dev_commands set
    status = 'completed', finished_at = now(),
    wait_state = null, wait_kind = null, wait_until = null,
    web_deploy_no   = coalesce(p_deploy_no, web_deploy_no),
    web_deployed_at = case when p_deploy_no is not null then now() else web_deployed_at end
  where id = p_id and status = 'building';
  if not found then
    return jsonb_build_object('ok', true, 'already', true, 'id', p_id,
      'note', 'closed concurrently — nothing left to do');
  end if;
  perform _lease_release_internal(p_id);
  perform _audit('system','dev_cmd_complete_fast', p_id::text,
    jsonb_build_object('agent', p_agent, 'deploy_no', p_deploy_no));

  -- INFORMATION ONLY. A single indexed read of the last cron-written verdict.
  -- It can be stale, it can be absent, and neither blocks a finished build.
  select jsonb_build_object('ok', c.ok, 'at', c.at,
           'age_s', round(extract(epoch from now() - c.at))::int)
    into v_rg from rg_check_cache c order by c.at desc limit 1;

  return jsonb_build_object('ok', true, 'phase', 'status', 'id', p_id,
    'status', 'completed', 'change_no', coalesce(p_deploy_no, r.web_deploy_no),
    'rg_last', v_rg, 'next', 'dev_cmd_result_write');
end $function$
$sql$;

  execute $sql$


-- ── 6. the detail screen's payload ────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.dev_cmd_get(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c dev_commands%rowtype; v_tail text;
begin
  perform _dev_guard();
  select * into c from dev_commands where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'command_not_found', 'id', p_id);
  end if;

  -- the tail is what the detail screen shows; the whole log is never shipped
  v_tail := right(coalesce(c.build_log, ''), 8000);

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'server_time', now(),
    'row', jsonb_build_object(
      'id',                   c.id,
      'title',                c.title,
      'status',               c.status,
      'spec',                 c.spec,
      'build_log_tail',       v_tail,
      'error_log',            c.error_log,
      'screenshots',          coalesce(c.screenshots,   '[]'::jsonb),
      'decisions',            coalesce(c.decisions,     '[]'::jsonb),
      -- predicted_files and depends_on are Postgres ARRAYS, not jsonb
      'predicted_files',      to_jsonb(coalesce(c.predicted_files, '{}'::text[])),
      'steps',                coalesce(c.steps,         '[]'::jsonb),
      'depends_on',           to_jsonb(coalesce(c.depends_on, '{}'::int8[])),
      'result_summary',       c.result_summary,
      'plain_summary',        c.plain_summary,
      'result_actions',       coalesce(c.result_actions,'[]'::jsonb),
      'needs_input_question', c.needs_input_question,
      'eta_note',             c.eta_note,
      'wait_blocker',         c.wait_blocker,
      -- CHANGE #1802 — the Android release block, printed verbatim by the
      -- detail screen. has:false on a row that never asked for one.
      'android',              public._dev_android_block(p_id),
      'finish_blockers',      (public.dev_cmd_finish_state(p_id) -> 'blockers')));
end $function$
$sql$;

end $cp$;
