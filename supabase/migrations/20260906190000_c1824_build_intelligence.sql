-- replay-target: control-plane
--
-- THE PRODUCTION PASS RUNS ON THIS FILE TOO — SO THE FILE SAYS NO ITSELF.
-- Same guard as #1820: only the dev-queue control plane carries
-- dev_runner_config.project_identity.role = 'dev-queue control plane'.
-- Production still holds a LEFTOVER dev_commands (701 'fixture N' rows), so a
-- to_regclass check is not enough — the identity row is what is asked.
select coalesce(to_regclass('public.dev_runner_config')::text,'') = '' as c1824_no_cfg \gset
\if :c1824_no_cfg
\echo 'c1824: no dev_runner_config here — control-plane migration, nothing to apply'
\quit
\endif
select not exists (select 1 from public.dev_runner_config
                    where key = 'project_identity'
                      and value->>'role' = 'dev-queue control plane') as c1824_not_cp \gset
\if :c1824_not_cp
\echo 'c1824: not the dev-queue control plane — nothing to apply'
\quit
\endif

-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1824 — THE REGISTRY IS A DIARY. MAKE IT A CONTROLLER.
--
-- Measured 6 Sep 2026: 461 commands with ~130 outcome columns each, 5289
-- lease events, 4039 journey runs, 378 QA findings, 277 lessons — and only two
-- functions in pg_proc that ever READ any of it back. Estimates ran 2.5× over
-- actuals and were never corrected; 35% of commands needed rework and no cause
-- was ever clustered; lessons had no usage columns at all.
--
-- Nothing here logs anything new. It is the READ side:
--   1. dev_command_outcome      — prediction beside reality, one row a command
--   2. dev_eta_estimate()       — the measured median/p80 for a shape of work,
--                                 seeded into the FIRST heartbeat by trigger;
--                                 an agent may only raise it, with an eta_note
--   3. dev_cause_scan()         — rework + QA findings clustered by cause; a
--                                 cause hitting one area 3× becomes a
--                                 dev_build_constraint injected into every
--                                 future spec for that area at claim time,
--                                 then MEASURED before/after
--   4. dev_lessons usage        — last_used_at / hit_count / prevented_count,
--                                 stamped by dev_lessons_get; dead weight listed
--   5. dev_waste_scan()         — waiting / re-reading / re-planning /
--                                 restart-after-loss / oversized-context, each
--                                 mapped to an existing worker_pool knob and
--                                 written as a PROPOSAL Om applies (PIN)
--   6. dev_build_intelligence() — the fully rendered dashboard payload
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 0. config ──────────────────────────────────────────────────────────────
update public.dev_runner_config
   set value = value || jsonb_build_object('build_intel',
       coalesce(value->'build_intel','{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
         'window_days',      coalesce((value->'build_intel'->>'window_days')::int, 30),
         'min_samples',      coalesce((value->'build_intel'->>'min_samples')::int, 5),
         'promote_at',       coalesce((value->'build_intel'->>'promote_at')::int, 3),
         'dead_lesson_days', coalesce((value->'build_intel'->>'dead_lesson_days')::int, 30),
         'proposal_min_pct', coalesce((value->'build_intel'->>'proposal_min_pct')::numeric, 5),
         'scan_stale_s',     coalesce((value->'build_intel'->>'scan_stale_s')::int, 600),
         'baseline_factor',  coalesce((value->'build_intel'->>'baseline_factor')::numeric, 2.5),
         'lessons_tracked_since', coalesce((value->'build_intel'->>'lessons_tracked_since')::timestamptz, now()),
         'note', 'CMD #1824 — knobs for the Build intelligence loops. baseline_factor is the estimate error measured 6 Sep 2026 (4176 s estimated vs 1694 s actual), the number the calibrated ETA has to beat.')))
 where key = 'worker_pool';

-- ── 1. columns ─────────────────────────────────────────────────────────────
alter table public.dev_commands
  add column if not exists eta_source       text,
  add column if not exists eta_seed_s       integer,
  add column if not exists eta_error_factor numeric;
comment on column public.dev_commands.eta_source is 'CMD #1824 — where eta_total_s came from: measured (dev_eta_estimate seeded it), agent (no sample ≥ min_samples yet), agent_override (agent raised the measured seed with an eta_note).';
comment on column public.dev_commands.eta_error_factor is 'CMD #1824 — stamped at completion: greatest(eta,elapsed)/least(eta,elapsed). 1.0 is a perfect estimate.';

alter table public.dev_lessons
  add column if not exists last_used_at    timestamptz,
  add column if not exists hit_count       integer not null default 0,
  add column if not exists prevented_count integer not null default 0;

create table if not exists public.dev_lesson_read (
  id          bigserial primary key,
  lesson_id   bigint not null references public.dev_lessons(id) on delete cascade,
  command_id  bigint,
  at          timestamptz not null default now()
);
create index if not exists dev_lesson_read_lesson_idx on public.dev_lesson_read(lesson_id, at desc);
create index if not exists dev_lesson_read_cmd_idx    on public.dev_lesson_read(command_id);

create table if not exists public.dev_cause_rule (
  id              bigserial primary key,
  ord             integer not null,
  pattern         text not null,
  cause_key       text not null unique,
  label           text not null,
  constraint_text text not null,
  enabled         boolean not null default true,
  note            text,
  created_at      timestamptz not null default now()
);

create table if not exists public.dev_build_constraint (
  id              bigserial primary key,
  area            text,
  cause_key       text not null,
  text            text not null,
  status          text not null default 'active' check (status in ('active','retired')),
  promoted_at     timestamptz not null default now(),
  measure_from    timestamptz not null default now(),
  before_count    integer not null default 0,
  injected_count  integer not null default 0,
  last_injected_at timestamptz,
  rewritten_at    timestamptz,
  rewrite_count   integer not null default 0,
  note            text,
  updated_at      timestamptz not null default now(),
  unique (area, cause_key)
);

create table if not exists public.dev_build_constraint_hit (
  id            bigserial primary key,
  constraint_id bigint not null references public.dev_build_constraint(id) on delete cascade,
  command_id    bigint not null,
  at            timestamptz not null default now()
);
create index if not exists dev_build_constraint_hit_c_idx on public.dev_build_constraint_hit(constraint_id, at desc);

create table if not exists public.dev_build_proposal (
  id             bigserial primary key,
  class_key      text not null,
  label          text not null,
  knob_path      text not null,
  current_value  jsonb,
  proposed_value jsonb,
  patch          jsonb not null,
  tokens         bigint not null default 0,
  commands       integer not null default 0,
  evidence       jsonb not null default '{}'::jsonb,
  rationale      text not null,
  status         text not null default 'open' check (status in ('open','applied','dismissed','superseded')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  decided_at     timestamptz,
  note           text
);
create unique index if not exists dev_build_proposal_open_uq
  on public.dev_build_proposal(class_key) where status = 'open';

-- ── 2. cause rules (data — a new class is one INSERT, not a deploy) ───────
insert into public.dev_cause_rule (ord, pattern, cause_key, label, constraint_text) values
 (10,  'heartbeat stale|heartbeat lost|worker went silent|went silent',
       'heartbeat_stale', 'Heartbeat went stale',
       'Heartbeat every 60 s with a log tail. Before any long test, build or wait, send a beat FIRST — a silent runner is released at 15 minutes and the row restarts from its last step.'),
 (20,  'agent exited|without a terminal status',
       'agent_exited', 'Agent exited without a terminal status',
       'Finish with exactly one of complete / fail / ask before the session ends. Never exit, /quit, or let the loop clear a row that is still building.'),
 (30,  'ETA frozen|no ETA change|no token activity',
       'eta_frozen', 'ETA frozen while tokens climbed',
       'Re-estimate eta_left_s on every heartbeat from what is actually left. A frozen ETA with rising tokens is killed as a zombie.'),
 (40,  'RELEASED \(shutdown|boot_doctor|worker stopped|^shutdown$|power_off|IDLE',
       'worker_shutdown', 'Worker stopped mid-build',
       'Mark each step with step_done the moment it lands, so a restart resumes at the right step instead of from zero.'),
 (50,  'merge lane|merge queue|conflicts with main|deploy lane|evict',
       'merge_wait', 'Queued or evicted in the merge lane',
       'Run spec_rebase.sh while coding and clear conflicts BEFORE queue_push. Wait on the lane with devcmd.sh wait, never by polling.'),
 (60,  'held by #|lease',
       'lease_wait', 'Waited on a file lease',
       'Lease every file before editing (lease_split). Build the free paths first and wait on the held one with devcmd.sh wait lease.'),
 (70,  'completion RPC did not answer|RPC timeout|statement timeout|57014|did not answer',
       'rpc_timeout', 'RPC timed out',
       'An RPC timeout is a WAIT, not a failure: park with devcmd.sh park rpc. Never fail the row for it and never loop on complete.'),
 (80,  'Remote Control|LIVENESS',
       'liveness_lost', 'Remote Control session unreachable',
       'Keep the session alive: no /quit, no exit. Run long steps inside one Bash call, with a heartbeat sent before them.'),
 (90,  'Supabase outage|connection slots|too many connections|520|522',
       'db_outage', 'Database outage during the build',
       'On a 520/522 or a connection-slot error, park the row with devcmd.sh park db and keep the DB-free work moving.'),
 (100, 'Version check failed|version\.json',
       'version_mismatch', 'Live version check failed',
       'After deploy run scripts/verify_live.sh until version.json shows the new change number. Never report success on a stale version.'),
 (110, 'executable by anon|anon reachab|RLS|policy',
       'anon_exposure', 'Anonymous reachability or RLS gap',
       'Every new RPC gets an explicit grant review: revoke from anon unless the spec says public, and probe it as anon before completing.'),
 (120, 'tests? failed|FAILED|assertion|Expected:|compile error',
       'test_failure', 'A test or build failed',
       'Run devcmd.sh tests before queue_push. A red protected suite is fixed in the code, never in the test.'),
 (130, 'design literal|literal gate|style literal',
       'design_literal', 'Design literal gate red',
       'Use Ds tokens only — no Color(0x…), fontSize or bare EdgeInsets in a screen. Run the literal gate before pushing.'),
 (140, 'rg_check|regression guard|baseline',
       'rg_red', 'Regression guard red',
       'After any migration: verify the new schema is what you intended, then rebaseline and rgcheck true BEFORE queue_push.'),
 (150, 'duplicate of #|replaced by|cancelled by Om|paused by Om|superseded by #',
       'superseded_by_om', 'Cancelled or replaced by Om',
       'Before building, read the related completed rows so a superseded or duplicate spec is caught at the start, not after the build.'),
 (160, 'claimed by mistake|looking for #|handing over|handing back|recovering #|releasing to finish',
       'claim_handover', 'Row claimed by the wrong slot',
       'Re-read claimed_by after any outage, watchdog or re-queue message. Never finish, release or lease-release a row another slot now owns.')
on conflict (cause_key) do update
  set pattern = excluded.pattern, label = excluded.label,
      constraint_text = excluded.constraint_text, ord = excluded.ord;

-- Normalise one free-text cause into a cause_key. Rules first; the fallback
-- keeps the first six words with every number folded to N, so "RETRY 2 after"
-- and "RETRY 5 after" cluster together.
create or replace function public._dev_cause_key(p_text text)
returns text language plpgsql stable as $$
declare v_key text; v_norm text;
begin
  if nullif(btrim(coalesce(p_text,'')),'') is null then return null; end if;
  select r.cause_key into v_key
    from public.dev_cause_rule r
   where r.enabled and p_text ~* r.pattern
   order by r.ord limit 1;
  if v_key is not null then return v_key; end if;
  v_norm := lower(regexp_replace(regexp_replace(p_text, '[0-9]+', 'N', 'g'), '[^a-zA-Z0-9 ]+', ' ', 'g'));
  v_norm := btrim(regexp_replace(v_norm, '\s+', ' ', 'g'));
  v_norm := array_to_string((string_to_array(v_norm, ' '))[1:6], '_');
  if v_norm = '' then return null; end if;
  return 'other:' || left(v_norm, 60);
end $$;

create or replace function public._dev_cause_label(p_key text)
returns text language sql stable as $$
  select coalesce((select label from public.dev_cause_rule where cause_key = p_key),
                  case when p_key like 'other:%' then replace(substr(p_key, 7), '_', ' ')
                       when p_key like 'qa:%'    then 'QA: ' || replace(substr(p_key, 4), '_', ' ')
                       else p_key end);
$$;

-- ── 3. THE OUTCOME LEDGER — prediction beside reality ─────────────────────
create or replace view public.dev_command_outcome as
with leased as (
  select command_id, array_agg(distinct path order by path) as leased_files
    from public.lease_event where kind = 'granted' group by command_id
), resumes as (
  select command_id, sum(tokens_added) as resume_tokens
    from public.dev_resume_ledger where closed_at is not null group by command_id
), ctx as (
  select command_id,
         count(*) filter (where kind in ('compact','clear','compact_failed')) as compact_events,
         count(*) filter (where kind = 'threshold') as threshold_events
    from public.dev_context_event group by command_id
), jr as (
  select command_id,
         count(*) filter (where status = 'passed') as journeys_passed,
         count(*) filter (where status = 'failed') as journeys_failed
    from public.dev_journey_runs group by command_id
), qf as (
  select command_id, count(*) as qa_finding_count from public.qa_findings group by command_id
)
select c.id, c.title, c.status, c.area, c.size_class, c.route, c.kind,
       coalesce(nullif(c.actual_model,''), c.model)   as model,
       coalesce(nullif(c.actual_effort,''), c.effort) as effort,
       c.started_at, c.finished_at,
       greatest(extract(epoch from (c.finished_at - c.started_at)), 0)::int as elapsed_s,
       c.eta_total_s, c.eta_source, c.eta_seed_s,
       case when c.eta_total_s > 0 and c.finished_at > c.started_at
            then round(c.eta_total_s::numeric / greatest(extract(epoch from (c.finished_at - c.started_at)), 1), 3) end as eta_ratio,
       coalesce(c.eta_error_factor,
         case when c.eta_total_s > 0 and c.finished_at > c.started_at
              then round(greatest(c.eta_total_s::numeric, extract(epoch from (c.finished_at - c.started_at)))
                       / greatest(least(c.eta_total_s::numeric, extract(epoch from (c.finished_at - c.started_at))), 1), 3) end) as eta_error_factor,
       c.predicted_files,
       l.leased_files,
       coalesce(array_length(c.predicted_files,1),0) as predicted_count,
       coalesce(array_length(l.leased_files,1),0)   as leased_count,
       (select count(*) from unnest(coalesce(c.predicted_files,'{}'::text[])) p where p = any(coalesce(l.leased_files,'{}'::text[])))::int as predicted_hit_count,
       coalesce(c.cost_input_tokens,0) + coalesce(c.cost_output_tokens,0) as tokens,
       c.cost_inr,
       c.diff_files, c.diff_rows, c.steps_total, c.steps_done,
       case when coalesce(c.diff_rows,0) > 0
            then round((coalesce(c.cost_input_tokens,0) + coalesce(c.cost_output_tokens,0))::numeric / c.diff_rows) end as tokens_per_diff_row,
       coalesce(c.retry_count,0)  as retry_count,
       coalesce(c.resume_count,0) as resume_count,
       coalesce(c.qa_rounds,0)    as qa_rounds,
       c.qa_status,
       coalesce(c.journey_pass_count,0) as journey_pass_count,
       coalesce(j.journeys_passed,0) as journeys_passed,
       coalesce(j.journeys_failed,0) as journeys_failed,
       coalesce(q.qa_finding_count,0) as qa_finding_count,
       coalesce(c.wait_total_s,0)   as wait_total_s,
       coalesce(c.wait_turns,0)     as wait_turns,
       coalesce(c.wait_turn_tokens,0) as wait_turn_tokens,
       coalesce(c.session_lost_count,0) as session_lost_count,
       coalesce(c.steps_nudge_count,0)  as steps_nudge_count,
       coalesce(r.resume_tokens,0)  as resume_tokens,
       coalesce(x.compact_events,0) as compact_events,
       coalesce(x.threshold_events,0) as threshold_events,
       (coalesce(c.retry_count,0) > 0 or coalesce(c.resume_count,0) > 0 or coalesce(c.qa_rounds,0) > 1) as needs_rework,
       c.error_log, c.release_reason
  from public.dev_commands c
  left join leased  l on l.command_id = c.id
  left join resumes r on r.command_id = c.id
  left join ctx     x on x.command_id = c.id
  left join jr      j on j.command_id = c.id
  left join qf      q on q.command_id = c.id
 where c.status in ('completed','failed','cancelled') and c.finished_at is not null;

comment on view public.dev_command_outcome is 'CMD #1824 — one row per finished command putting the prediction (eta, predicted_files, size_class) beside the outcome (elapsed, leased_files, tokens, diff, rework). Computes nothing new: it joins what the registry already stores.';

-- Every occurrence of a normalised cause: rework lines from error_log and
-- release_reason, plus every QA finding. `at` is when it happened, so a
-- constraint can be measured before/after its promotion.
create or replace function public.dev_cause_occurrences()
returns table (command_id bigint, area text, cause_key text, at timestamptz, source text)
language sql stable as $$
  with rework as (
    select o.id, o.area, o.finished_at, l.line
      from public.dev_command_outcome o
      cross join lateral (
        select unnest(array_remove(array_cat(
                 regexp_split_to_array(coalesce(o.error_log,''), E'\n'),
                 array[coalesce(o.release_reason,'')]), '')) as line) l
     where o.needs_rework
       -- Only a TAGGED line is a cause: "RELEASED (…", "ZOMBIE:", "RETRY 2 after:".
       -- The log tail that follows a retry line is the agent's own output and
       -- must never cluster ("bypass permissions on shift+tab" is not a cause).
       and (l.line ~ '^[A-Z][A-Za-z0-9 _/-]{2,}[:(]' or l.line = coalesce(o.release_reason,''))
  ), rework_keys as (
    select distinct r.id as command_id, r.area, public._dev_cause_key(r.line) as cause_key,
           r.finished_at as at, 'rework'::text as source
      from rework r
     where public._dev_cause_key(r.line) is not null
  ), qa as (
    -- A finding that matches a rule takes the rule's key; anything else clusters
    -- under qa:<first words of its title> so a repeated finding still counts.
    select distinct f.command_id, c.area,
           case when k.key like 'other:%' then 'qa:' || substr(k.key, 7) else k.key end as cause_key,
           f.created_at as at, 'qa'::text as source
      from public.qa_findings f
      join public.dev_commands c on c.id = f.command_id
      cross join lateral (select coalesce(public._dev_cause_key(coalesce(f.title,'') || ' ' || coalesce(f.detail,'')), 'other:unlabelled') as key) k
     where f.title not ilike 'OK:%' and f.title not ilike 'Verified clean%' and f.title not ilike 'Reachable and screenshot%'
  )
  select * from rework_keys
  union all
  select * from qa;
$$;

-- ── 4. LOOP A — the ETA is measured, not guessed ──────────────────────────
create or replace function public.dev_eta_estimate(
  p_area text default null, p_size_class text default null,
  p_route text default null, p_model text default null)
returns jsonb language plpgsql stable as $$
declare v_min int; v_n int; v_med numeric; v_p80 numeric; v_level text; v_sentence text; v_shape text;
begin
  select coalesce((value->'build_intel'->>'min_samples')::int, 5) into v_min
    from public.dev_runner_config where key = 'worker_pool';
  v_min := coalesce(v_min, 5);
  v_shape := concat_ws(' · ', nullif(p_area,''), nullif(p_size_class,''), nullif(p_route,''), nullif(p_model,''));
  if v_shape = '' then v_shape := 'any command'; end if;

  -- Progressively relax the match: the tightest shape with enough samples wins,
  -- and the payload SAYS which level answered, so a coarse match is never
  -- mistaken for a precise one.
  for v_level in select unnest(array['area+size+route+model','area+size','area','size','all']) loop
    select count(*),
           percentile_cont(0.5) within group (order by elapsed_s),
           percentile_cont(0.8) within group (order by elapsed_s)
      into v_n, v_med, v_p80
      from public.dev_command_outcome o
     where o.status = 'completed' and o.elapsed_s > 30
       and (v_level not in ('area+size+route+model','area+size','area') or o.area is not distinct from nullif(p_area,''))
       and (v_level not in ('area+size+route+model','area+size','size') or o.size_class is not distinct from nullif(p_size_class,''))
       and (v_level <> 'area+size+route+model' or (o.route is not distinct from nullif(p_route,'') and o.model is not distinct from nullif(p_model,'')));
    exit when coalesce(v_n,0) >= v_min;
  end loop;

  if coalesce(v_n,0) < v_min then
    return jsonb_build_object('ok', true, 'has', false, 'n', coalesce(v_n,0), 'min_samples', v_min,
      'matched_on', 'none', 'shape', v_shape,
      'sentence', 'Not enough finished commands to measure ' || v_shape || ' yet (' || coalesce(v_n,0) || ' of ' || v_min || ') — the agent''s own estimate stands.');
  end if;

  return jsonb_build_object('ok', true, 'has', true, 'n', v_n, 'min_samples', v_min,
    'median_s', round(v_med)::int, 'p80_s', round(v_p80)::int,
    'median_label', public._fmt_dur(round(v_med)::bigint),
    'p80_label',    public._fmt_dur(round(v_p80)::bigint),
    'matched_on', v_level, 'shape', v_shape,
    'sentence', 'Measured over ' || v_n || ' finished command(s) matching ' || v_level || ': median '
                || public._fmt_dur(round(v_med)::bigint) || ', 80% finish within ' || public._fmt_dur(round(v_p80)::bigint)
                || '. The first heartbeat is seeded with the median; raise it only with an eta_note saying why.');
end $$;

-- The seed and the override rule live in ONE trigger, so every writer of
-- eta_total_s (the heartbeat RPC today, anything else tomorrow) obeys it:
--   * first ETA on a building row: the measured median replaces the agent's
--     guess when there are enough samples; the agent's number survives only
--     when it is HIGHER and carries an eta_note (source = agent_override);
--   * later beats: raising the total needs a note; without one the old total
--     stands and eta_left_s is clamped to it.
--   * at completion: eta_error_factor is stamped, so the error is recorded per
--     command and the calibration can be proven, not assumed.
create or replace function public._dev_eta_govern_trg()
returns trigger language plpgsql as $$
declare v_est jsonb; v_note text; v_elapsed int;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    if new.eta_total_s > 0 and coalesce(new.finished_at, now()) > new.started_at then
      new.eta_error_factor := round(greatest(new.eta_total_s::numeric, extract(epoch from (coalesce(new.finished_at, now()) - new.started_at)))
                                  / greatest(least(new.eta_total_s::numeric, extract(epoch from (coalesce(new.finished_at, now()) - new.started_at))), 1), 3);
    end if;
    return new;
  end if;

  if new.eta_total_s is not distinct from old.eta_total_s then return new; end if;
  if new.status <> 'building' then return new; end if;
  v_note := nullif(btrim(coalesce(new.eta_note,'')), '');

  if old.eta_total_s is null and new.eta_total_s is not null then
    v_est := public.dev_eta_estimate(new.area, new.size_class, new.route, coalesce(nullif(new.actual_model,''), new.model));
    if coalesce((v_est->>'has')::boolean, false) then
      new.eta_seed_s := (v_est->>'median_s')::int;
      if new.eta_total_s > (v_est->>'median_s')::int and v_note is not null then
        new.eta_source := 'agent_override';
      else
        v_elapsed := greatest(extract(epoch from (now() - coalesce(new.started_at, now())))::int, 0);
        new.eta_total_s := (v_est->>'median_s')::int;
        new.eta_left_s  := greatest(new.eta_total_s - v_elapsed, 60);
        new.eta_source  := 'measured';
      end if;
    else
      new.eta_source := 'agent';
    end if;
    return new;
  end if;

  -- A later raise of a measured total needs a note; a raise with a note is an
  -- override and is honoured.
  if new.eta_total_s > old.eta_total_s and old.eta_source in ('measured','agent_override') then
    if v_note is not null and new.eta_note is distinct from old.eta_note then
      new.eta_source := 'agent_override';
    else
      new.eta_total_s := old.eta_total_s;
      new.eta_left_s  := least(coalesce(new.eta_left_s, old.eta_total_s), old.eta_total_s);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_dev_eta_govern on public.dev_commands;
create trigger trg_dev_eta_govern
  before update of eta_total_s, status on public.dev_commands
  for each row execute function public._dev_eta_govern_trg();

-- ── 5. LOOP B — a repeating cause becomes a constraint ────────────────────
create or replace function public.dev_cause_scan()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_at int; v_promoted int := 0; r record;
begin
  select coalesce((value->'build_intel'->>'promote_at')::int, 3) into v_at
    from dev_runner_config where key = 'worker_pool';
  v_at := coalesce(v_at, 3);
  for r in
    select o.area, o.cause_key, count(*) as n, min(o.at) as first_at, max(o.at) as last_at
      from dev_cause_occurrences() o
     where o.area is not null
     group by o.area, o.cause_key
    having count(*) >= v_at
  loop
    insert into dev_build_constraint (area, cause_key, text, before_count, note)
    values (r.area, r.cause_key,
            coalesce((select constraint_text from dev_cause_rule where cause_key = r.cause_key),
                     'Do not repeat the failure "' || _dev_cause_label(r.cause_key) || '": it has hit ' || r.area || ' ' || r.n || ' times (first ' || to_char(r.first_at at time zone 'Asia/Kolkata','DD Mon') || ', last ' || to_char(r.last_at at time zone 'Asia/Kolkata','DD Mon') || '). Check for it explicitly before queue_push.'),
            r.n,
            'promoted automatically: ' || r.n || ' occurrences in ' || r.area)
    on conflict (area, cause_key) do nothing;
    if found then v_promoted := v_promoted + 1; end if;
  end loop;
  update dev_runner_config
     set value = value || jsonb_build_object('build_intel', (value->'build_intel') || jsonb_build_object('cause_scan_at', now()))
   where key = 'worker_pool';
  return jsonb_build_object('ok', true, 'promoted', v_promoted, 'promote_at', v_at);
end $$;

-- Om rewrites a constraint whose class keeps recurring; measurement restarts.
create or replace function public.dev_build_constraint_rewrite(p_id bigint, p_text text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  if nullif(btrim(coalesce(p_text,'')),'') is null then
    return jsonb_build_object('ok', false, 'message', 'The rewritten constraint cannot be empty.');
  end if;
  update dev_build_constraint
     set text = btrim(p_text), rewritten_at = now(), measure_from = now(),
         rewrite_count = rewrite_count + 1, status = 'active', updated_at = now()
   where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'message', 'No constraint #' || p_id || '.'); end if;
  return jsonb_build_object('ok', true, 'message', 'Constraint #' || p_id || ' rewritten — its before/after count starts again from now.');
end $$;

create or replace function public.dev_build_constraint_retire(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  update dev_build_constraint set status = 'retired', updated_at = now() where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'message', 'No constraint #' || p_id || '.'); end if;
  return jsonb_build_object('ok', true, 'message', 'Constraint #' || p_id || ' retired — it is no longer injected.');
end $$;

-- The injection. Called by dev_cmd_claim on the row it just handed out: the
-- returned spec carries every active constraint for the row's area (and the
-- global ones), the stored spec is untouched, and the hit is recorded so the
-- dashboard can say how many builds each constraint has reached.
create or replace function public._dev_constraints_inject(p_row jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_area text; v_id bigint; v_block text := ''; v_list jsonb := '[]'::jsonb; r record;
begin
  if p_row is null or p_row->>'id' is null then return p_row; end if;
  v_id := (p_row->>'id')::bigint; v_area := p_row->>'area';
  for r in
    select c.id, c.text, c.cause_key, c.area
      from dev_build_constraint c
     where c.status = 'active' and (c.area is null or c.area = v_area)
     order by c.area nulls last, c.promoted_at
  loop
    v_block := v_block || E'\n- ' || r.text || ' [constraint #' || r.id || ', ' || _dev_cause_label(r.cause_key) || ']';
    v_list  := v_list || jsonb_build_object('id', r.id, 'text', r.text, 'cause_key', r.cause_key);
    update dev_build_constraint set injected_count = injected_count + 1, last_injected_at = now(), updated_at = now() where id = r.id;
    insert into dev_build_constraint_hit (constraint_id, command_id) values (r.id, v_id);
  end loop;
  if v_block = '' then return p_row || jsonb_build_object('constraints', v_list); end if;
  return p_row || jsonb_build_object(
    'constraints', v_list,
    'spec', coalesce(p_row->>'spec','') || E'\n\n## ENFORCED CONSTRAINTS — repeat causes in this area (CMD #1824)\n'
            || 'Each line below is a cause that has already hit this area at least three times. It is a hard requirement of this build, not advice.'
            || v_block);
exception when others then
  -- Injection must never cost a claim: on any error the row goes out as it was.
  return p_row;
end $$;

-- What the prompt prints for a human: the block alone, for one command.
create or replace function public.dev_build_constraints_for(p_area text default null)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'area', c.area, 'text', c.text,
                    'cause', _dev_cause_label(c.cause_key)) order by c.area nulls last, c.promoted_at), '[]'::jsonb)
    from dev_build_constraint c
   where c.status = 'active' and (c.area is null or c.area = p_area);
$$;

-- ── 6. LESSONS MUST EARN THEIR PLACE ──────────────────────────────────────
-- Same name, one more defaulted argument: the zero/one-arg overload is dropped
-- first so `dev_lessons_get('infra')` cannot become ambiguous (#1470 lesson).
drop function if exists public.dev_lessons_get(text);
create or replace function public.dev_lessons_get(p_area text default null, p_cmd bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_ids bigint[];
begin
  perform _dev_guard();
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'area', area, 'title', title, 'lesson', lesson) order by id desc), '[]'),
         coalesce(array_agg(id), '{}')
    into v, v_ids
    from dev_lessons where p_area is null or area = p_area or area is null;
  if coalesce(array_length(v_ids,1),0) > 0 then
    update dev_lessons set last_used_at = now(), hit_count = hit_count + 1 where id = any(v_ids);
    insert into dev_lesson_read (lesson_id, command_id) select unnest(v_ids), p_cmd;
  end if;
  return v;
end $$;

-- prevented_count = builds that read the lesson and finished with no rework.
-- Recomputed here (277 rows, cheap) rather than kept live by trigger.
create or replace function public.dev_lessons_health()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_days int; v_rows jsonb; v_dead int; v_ineffective int; v_tracked timestamptz;
begin
  select coalesce((value->'build_intel'->>'dead_lesson_days')::int, 30),
         coalesce((value->'build_intel'->>'lessons_tracked_since')::timestamptz, now())
    into v_days, v_tracked
    from dev_runner_config where key = 'worker_pool';
  v_days := coalesce(v_days, 30); v_tracked := coalesce(v_tracked, now());

  update dev_lessons l set prevented_count = s.n
    from (select r.lesson_id, count(distinct r.command_id) as n
            from dev_lesson_read r
            join dev_command_outcome o on o.id = r.command_id
           where o.status = 'completed' and not o.needs_rework
           group by r.lesson_id) s
   where s.lesson_id = l.id and l.prevented_count is distinct from s.n;

  with stats as (
    select l.id, l.area, l.title, l.created_at, l.last_used_at, l.hit_count, l.prevented_count,
           (select count(distinct r.command_id) from dev_lesson_read r join dev_command_outcome o on o.id = r.command_id where r.lesson_id = l.id) as finished_readers,
           (select count(distinct r.command_id) from dev_lesson_read r join dev_command_outcome o on o.id = r.command_id where r.lesson_id = l.id and o.needs_rework) as rework_readers
      from dev_lessons l
  ), judged as (
    select s.*,
      case
        when greatest(s.created_at, v_tracked) < now() - (v_days || ' days')::interval and s.last_used_at is null then 'dead'
        when s.last_used_at is not null and s.last_used_at < now() - (v_days || ' days')::interval then 'dead'
        when s.hit_count >= 3 and s.finished_readers >= 3 and s.rework_readers * 2 >= s.finished_readers then 'ineffective'
        else 'alive' end as verdict
      from stats s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', j.id, 'label', coalesce(nullif(j.title,''), 'lesson #' || j.id),
           'area', coalesce(j.area, 'global'),
           'value', case j.verdict when 'dead' then 'dead weight' else 'not working' end,
           'tone',  case j.verdict when 'dead' then 'warning' else 'danger' end,
           'sub',   case j.verdict
                      when 'dead' then case when j.last_used_at is null
                             then 'never read since ' || to_char(j.created_at at time zone 'Asia/Kolkata', 'DD Mon') || ' · ' || v_days || '-day rule'
                             else 'last read ' || to_char(j.last_used_at at time zone 'Asia/Kolkata', 'DD Mon') || ' · read ' || j.hit_count || ' time(s) in total' end
                      else 'read ' || j.hit_count || ' time(s) · ' || j.rework_readers || ' of ' || j.finished_readers || ' builds that read it still needed rework' end)
           order by case j.verdict when 'ineffective' then 0 else 1 end, j.hit_count desc, j.id), '[]'::jsonb),
         count(*) filter (where j.verdict = 'dead'), count(*) filter (where j.verdict = 'ineffective')
    into v_rows, v_dead, v_ineffective
    from judged j where j.verdict <> 'alive';

  return jsonb_build_object('ok', true, 'rows', v_rows, 'dead', coalesce(v_dead,0), 'ineffective', coalesce(v_ineffective,0),
    'total', (select count(*) from dev_lessons), 'days', v_days);
end $$;

-- ── 7. LOOP C — waste classes → proposals ─────────────────────────────────
-- Each class is measured against the commands finished inside the window, the
-- tokens it can be blamed for are summed, and ONE open proposal per class is
-- written naming the existing worker_pool knob and the value to try. Nothing
-- is applied here: dev_build_proposal_apply is Om's PIN-gated tap.
create or replace function public.dev_waste_scan()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pool jsonb; v_days int; v_min_pct numeric; v_since timestamptz; v_total bigint;
        v_classes jsonb := '[]'::jsonb; v_written int := 0; r record;
        v_cur jsonb; v_prop jsonb; v_patch jsonb; v_knob text; v_why text; v_pct numeric; v_label text;
begin
  select value into v_pool from dev_runner_config where key = 'worker_pool';
  v_days    := coalesce((v_pool->'build_intel'->>'window_days')::int, 30);
  v_min_pct := coalesce((v_pool->'build_intel'->>'proposal_min_pct')::numeric, 5);
  v_since   := now() - (v_days || ' days')::interval;

  select coalesce(sum(tokens),0) into v_total from dev_command_outcome
   where status = 'completed' and finished_at >= v_since;

  create temp table if not exists _c1824_waste (class_key text, label text, cmd bigint, tokens bigint) on commit drop;
  truncate _c1824_waste;

  insert into _c1824_waste
  with med as (
    select size_class, percentile_cont(0.5) within group (order by tokens) as med
      from dev_command_outcome where status = 'completed' and finished_at >= v_since and tokens > 0
     group by size_class
  ), o as (
    select o.*, coalesce(m.med, 0) as class_med
      from dev_command_outcome o left join med m on m.size_class is not distinct from o.size_class
     where o.status = 'completed' and o.finished_at >= v_since and o.tokens > 0
  )
  select 'waiting', 'Waiting', id, wait_turn_tokens from o where wait_turn_tokens > 0
  union all
  select 'restart_after_loss', 'Restart after loss', id, resume_tokens from o where (session_lost_count > 0 or resume_count > 0) and resume_tokens > 0
  union all
  select 're_reading', 'Re-reading', id, greatest(tokens - class_med, 0)::bigint from o
   where compact_events + threshold_events > 0 and session_lost_count = 0 and resume_count = 0 and tokens > class_med
  union all
  select 're_planning', 'Re-planning', id, greatest(tokens - class_med, 0)::bigint from o
   where (steps_nudge_count > 0 or (resume_count > 0 and steps_done = 0)) and tokens > class_med
  union all
  select 'oversized_context', 'Oversized context', id, greatest(tokens - class_med, 0)::bigint from o
   where class_med > 0 and tokens > 3 * class_med
     and wait_turn_tokens = 0 and resume_count = 0 and session_lost_count = 0 and compact_events + threshold_events = 0 and steps_nudge_count = 0;

  for r in
    select k.class_key, k.label, k.knob,
           coalesce(w.tokens,0) as tokens, coalesce(w.n,0) as n, coalesce(w.cmds, '[]'::jsonb) as cmds
      from (values
             ('waiting',            'Waiting',            'wait_gate.poll_s'),
             ('re_reading',         'Re-reading',         'context_compact_pct'),
             ('re_planning',        'Re-planning',        'steps_watchdog.stale_min'),
             ('restart_after_loss', 'Restart after loss', 'liveness.disconnect_grace_min'),
             ('oversized_context',  'Oversized context',  'batch_max')) as k(class_key, label, knob)
      left join (select class_key, sum(tokens) as tokens, count(distinct cmd) as n,
                        jsonb_agg(cmd order by tokens desc) as cmds
                   from _c1824_waste group by class_key) w on w.class_key = k.class_key
     order by coalesce(w.tokens,0) desc
  loop
    v_pct := case when v_total > 0 then round(r.tokens * 100.0 / v_total, 1) else 0 end;
    v_knob := r.knob; v_patch := null; v_cur := null; v_prop := null; v_why := null;
    if r.class_key = 'waiting' then
      v_cur  := v_pool->'wait_gate'->'poll_s';
      v_prop := to_jsonb(least(coalesce((v_pool->'wait_gate'->>'poll_s')::int, 60) * 2, 300));
      v_patch := jsonb_build_object('wait_gate', jsonb_build_object('poll_s', v_prop));
      v_why := 'Every wake-up while a row is asleep is a model turn paid for nothing. Fewer, longer polls mean fewer chances to wake.';
    elsif r.class_key = 're_reading' then
      v_cur  := v_pool->'context_compact_pct';
      v_prop := to_jsonb(case when coalesce((v_pool->>'context_compact_pct')::int, 99) > 70 then 70
                              else greatest(coalesce((v_pool->>'context_compact_pct')::int, 70) - 10, 50) end);
      v_patch := jsonb_build_object('context_compact_pct', v_prop);
      v_why := 'A session that crosses the threshold late compacts a bigger window and re-reads more of it. Compacting earlier keeps each re-read small.';
    elsif r.class_key = 're_planning' then
      v_cur  := v_pool->'steps_watchdog'->'stale_min';
      v_prop := to_jsonb(greatest(coalesce((v_pool->'steps_watchdog'->>'stale_min')::int, 12) - 4, 6));
      v_patch := jsonb_build_object('steps_watchdog', (v_pool->'steps_watchdog') || jsonb_build_object('stale_min', v_prop));
      v_why := 'A checklist that goes stale is re-planned from scratch on the next nudge or resume. A shorter stale window catches the drift while it is still one step.';
    elsif r.class_key = 'restart_after_loss' then
      v_cur  := v_pool->'liveness'->'disconnect_grace_min';
      v_prop := to_jsonb(least(coalesce((v_pool->'liveness'->>'disconnect_grace_min')::int, 1) + 2, 5));
      v_patch := jsonb_build_object('liveness', (v_pool->'liveness') || jsonb_build_object('disconnect_grace_min', v_prop));
      v_why := 'Every restart replays the resume brief and re-derives context. A longer disconnect grace stops a flapping Remote Control link from being read as a dead agent.';
    else
      v_cur  := v_pool->'batch_max';
      v_prop := to_jsonb(greatest(coalesce((v_pool->>'batch_max')::int, 4) - 1, 1));
      v_patch := jsonb_build_object('batch_max', v_prop);
      v_why := 'A command that costs three times its class median with no wait, resume or compact to blame is carrying context it did not need. Smaller batches keep one session''s window to one job.';
    end if;

    v_label := case when r.n = 0 then 'nothing in this class'
                    else _dev_num_short(r.tokens) || ' tokens · ' || r.n || ' command(s) · ' || v_pct || '% of the window' end;

    if r.n >= 3 and v_pct >= v_min_pct then
      insert into dev_build_proposal (class_key, label, knob_path, current_value, proposed_value, patch, tokens, commands, evidence, rationale)
      values (r.class_key, r.label, v_knob, v_cur, v_prop, v_patch, r.tokens, r.n,
              jsonb_build_object('window_days', v_days, 'since', v_since, 'pct_of_window', v_pct, 'commands', r.cmds),
              v_why)
      on conflict (class_key) where status = 'open' do update
        set tokens = excluded.tokens, commands = excluded.commands, evidence = excluded.evidence,
            current_value = excluded.current_value, proposed_value = excluded.proposed_value,
            patch = excluded.patch, rationale = excluded.rationale, updated_at = now();
      v_written := v_written + 1;
    end if;

    v_classes := v_classes || jsonb_build_object(
      'key', r.class_key, 'label', r.label, 'value', v_label,
      'knob', v_knob, 'knob_label', 'knob: worker_pool.' || v_knob,
      'tokens', r.tokens, 'commands', r.n, 'pct', v_pct,
      'tone', case when r.n = 0 then 'success' when v_pct >= v_min_pct then 'warning' else 'info' end,
      'sub', case when r.n = 0 then 'no command in the last ' || v_days || ' days paid for this'
                  when v_pct >= v_min_pct then 'over the ' || v_min_pct || '% proposal threshold — a proposal is open below'
                  else 'under the ' || v_min_pct || '% proposal threshold — measured, not proposed' end);
  end loop;

  update dev_runner_config
     set value = value || jsonb_build_object('build_intel', (value->'build_intel') || jsonb_build_object('waste_scan_at', now()))
   where key = 'worker_pool';
  return jsonb_build_object('ok', true, 'classes', v_classes, 'proposals_written', v_written,
                            'window_tokens', v_total, 'window_days', v_days, 'since', v_since);
end $$;

create or replace function public.dev_build_proposal_apply(p_id bigint, p_pin text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v dev_build_proposal%rowtype; v_res jsonb;
begin
  perform _dev_guard();
  select * into v from dev_build_proposal where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'message', 'No proposal #' || p_id || '.'); end if;
  if v.status <> 'open' then return jsonb_build_object('ok', false, 'message', 'Proposal #' || p_id || ' is already ' || v.status || '.'); end if;
  -- pool_set is the ONE writer of worker_pool and it verifies the PIN itself.
  v_res := pool_set(v.patch, p_pin);
  update dev_build_proposal set status = 'applied', decided_at = now(), updated_at = now(),
         note = 'applied: worker_pool.' || knob_path || ' ' || coalesce(current_value::text,'—') || ' → ' || coalesce(proposed_value::text,'—')
   where id = p_id;
  return jsonb_build_object('ok', true, 'message', 'Applied — worker_pool.' || v.knob_path || ' is now ' || coalesce(v.proposed_value::text,'—') || '. The next scan measures whether the class shrinks.', 'pool', v_res);
exception when others then
  return jsonb_build_object('ok', false, 'message', sqlerrm);
end $$;

create or replace function public.dev_build_proposal_dismiss(p_id bigint, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  update dev_build_proposal set status = 'dismissed', decided_at = now(), updated_at = now(), note = coalesce(p_note, note)
   where id = p_id and status = 'open';
  if not found then return jsonb_build_object('ok', false, 'message', 'Proposal #' || p_id || ' is not open.'); end if;
  return jsonb_build_object('ok', true, 'message', 'Dismissed — the knob stays as it is; the class is still measured.');
end $$;

-- ── 8. THE DASHBOARD PAYLOAD ──────────────────────────────────────────────
create or replace function public.dev_build_intelligence()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_pool jsonb; v_bi jsonb; v_days int; v_min int; v_since timestamptz; v_prev timestamptz; v_stale int;
        v_base_n int; v_base_factor numeric; v_base_mae numeric; v_cal_n int; v_cal_factor numeric; v_cal_mae numeric;
        v_base_med numeric; v_cal_med numeric; v_base_mae_s numeric; v_cal_mae_s numeric;
        v_spec_base numeric; v_acc jsonb; v_rw jsonb; v_rw_n int; v_rw_rework int; v_prev_n int; v_prev_rework int;
        v_rw_pct numeric; v_prev_pct numeric; v_trend text; v_causes jsonb; v_waste jsonb; v_props jsonb; v_lessons jsonb;
        v_lh jsonb; v_wscan jsonb; v_hint text; v_tiles jsonb; v_seeded int; v_override int;
begin
  perform _dev_guard();
  select value into v_pool from dev_runner_config where key = 'worker_pool';
  v_bi    := coalesce(v_pool->'build_intel', '{}'::jsonb);
  v_days  := coalesce((v_bi->>'window_days')::int, 30);
  v_min   := coalesce((v_bi->>'min_samples')::int, 5);
  v_stale := coalesce((v_bi->>'scan_stale_s')::int, 600);
  v_spec_base := coalesce((v_bi->>'baseline_factor')::numeric, 2.5);
  v_since := now() - (v_days || ' days')::interval;
  v_prev  := v_since - (v_days || ' days')::interval;

  -- The scans are cheap (hundreds of rows) and run here when stale, so the
  -- screen is never older than scan_stale_s; the cron row is the backstop.
  if coalesce((v_bi->>'cause_scan_at')::timestamptz, 'epoch'::timestamptz) < now() - (v_stale || ' seconds')::interval then
    perform dev_cause_scan();
  end if;
  -- The waste scan IS the classes section, so it always runs (hundreds of rows).
  v_wscan := dev_waste_scan();

  -- ACCURACY: agent guesses (the baseline) vs calibrated seeds.
  -- Three readings of the same error, none of them computed in Dart:
  --   factor  = sum(estimate)/sum(actual)  — the spec's 2.5× baseline shape
  --   mae     = mean |estimate − actual| in seconds per command
  --   median  = the typical per-command greatest/least factor (outlier-proof)
  select count(*), round(sum(eta_total_s)::numeric / greatest(sum(elapsed_s),1), 2),
         round(avg(abs(eta_total_s - elapsed_s))), round((percentile_cont(0.5) within group (order by eta_error_factor))::numeric, 2)
    into v_base_n, v_base_factor, v_base_mae_s, v_base_med
    from dev_command_outcome where status = 'completed' and eta_total_s > 0 and elapsed_s > 0
     and coalesce(eta_source,'agent') in ('agent');
  select count(*), round(sum(eta_total_s)::numeric / greatest(sum(elapsed_s),1), 2),
         round(avg(abs(eta_total_s - elapsed_s))), round((percentile_cont(0.5) within group (order by eta_error_factor))::numeric, 2)
    into v_cal_n, v_cal_factor, v_cal_mae_s, v_cal_med
    from dev_command_outcome where status = 'completed' and eta_total_s > 0 and elapsed_s > 0
     and eta_source in ('measured','agent_override');
  select count(*) filter (where eta_source = 'measured'), count(*) filter (where eta_source = 'agent_override')
    into v_seeded, v_override from dev_commands where eta_source is not null;

  if coalesce(v_cal_n,0) >= v_min then
    v_acc := jsonb_build_object('key','accuracy','has', true, 'label', 'Estimate error — calibrated',
      'value', v_cal_factor || '× estimate/actual',
      'sub', 'mean absolute error ' || _fmt_dur(coalesce(v_cal_mae_s,0)::bigint) || ' · typical command ' || coalesce(v_cal_med::text,'—') || '× off · ' || v_cal_n || ' calibrated finish(es) · agents guessed '
             || coalesce(v_base_factor::text,'—') || '× (MAE ' || _fmt_dur(coalesce(v_base_mae_s,0)::bigint) || ', ' || coalesce(v_base_n,0) || ' commands) · baseline ' || v_spec_base || '×',
      'tone', case when v_cal_factor < least(coalesce(v_base_factor, v_spec_base), v_spec_base) and v_cal_factor >= 0.4 then 'success' else 'danger' end);
  else
    v_acc := jsonb_build_object('key','accuracy','has', true, 'label', 'Estimate error — calibrated',
      'value', 'not enough calibrated finishes yet',
      'sub', coalesce(v_cal_n,0) || ' of ' || v_min || ' needed · ' || coalesce(v_seeded,0) || ' build(s) seeded so far · agents guessed '
             || coalesce(v_base_factor::text,'—') || '× estimate/actual (MAE ' || _fmt_dur(coalesce(v_base_mae_s,0)::bigint) || ', typical command ' || coalesce(v_base_med::text,'—') || '× off, ' || coalesce(v_base_n,0) || ' commands) · baseline to beat ' || v_spec_base || '×',
      'tone', 'info');
  end if;

  -- REWORK: share needing retry / resume / a second QA round, this window vs the one before.
  select count(*), count(*) filter (where needs_rework) into v_rw_n, v_rw_rework
    from dev_command_outcome where status = 'completed' and finished_at >= v_since;
  select count(*), count(*) filter (where needs_rework) into v_prev_n, v_prev_rework
    from dev_command_outcome where status = 'completed' and finished_at >= v_prev and finished_at < v_since;
  if coalesce(v_rw_n,0) >= v_min then
    v_rw_pct := round(v_rw_rework * 100.0 / v_rw_n, 1);
    if coalesce(v_prev_n,0) >= v_min then
      v_prev_pct := round(v_prev_rework * 100.0 / v_prev_n, 1);
      v_trend := case when v_rw_pct < v_prev_pct then 'trending down from ' || v_prev_pct || '%'
                      when v_rw_pct > v_prev_pct then 'trending up from ' || v_prev_pct || '%'
                      else 'flat against the previous ' || v_days || ' days' end;
    else
      v_trend := 'no trend yet — the previous ' || v_days || ' days hold ' || coalesce(v_prev_n,0) || ' of ' || v_min || ' needed';
    end if;
    v_rw := jsonb_build_object('key','rework','has', true, 'label', 'Rework', 'value', v_rw_pct || '%',
      'sub', v_rw_rework || ' of ' || v_rw_n || ' commands needed a retry, a resume or a second QA round · ' || v_trend,
      'tone', case when coalesce(v_prev_pct, v_rw_pct) > v_rw_pct then 'success' when v_rw_pct >= 35 then 'danger' when v_rw_pct >= 20 then 'warning' else 'success' end);
  else
    v_rw := jsonb_build_object('key','rework','has', true, 'label', 'Rework',
      'value', 'not enough finished commands yet',
      'sub', coalesce(v_rw_n,0) || ' of ' || v_min || ' needed in the last ' || v_days || ' days', 'tone', 'info');
  end if;
  v_tiles := jsonb_build_array(v_acc, v_rw);

  -- REPEAT CAUSES with before/after and whether a constraint is enforcing.
  with occ as (select * from dev_cause_occurrences()),
  agg as (
    select o.area, o.cause_key, count(*) as n, max(o.at) as last_at from occ o where o.area is not null group by 1,2
  ),
  con as (
    select c.*, (select count(*) from occ where occ.area = c.area and occ.cause_key = c.cause_key and occ.at >= c.measure_from) as after_n,
           (select count(*) from occ where occ.area = c.area and occ.cause_key = c.cause_key and occ.at <  c.measure_from) as before_n,
           (select count(*) from dev_commands d where d.area = c.area and d.started_at >= c.measure_from) as since_builds
      from dev_build_constraint c where c.status = 'active'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', con.id,
           'label', _dev_cause_label(a.cause_key) || ' · ' || a.area,
           'value', a.n || '×',
           'before_label', 'before: ' || coalesce(con.before_n, a.n),
           'after_label',  case when con.id is null then 'after: —' else 'after: ' || con.after_n end,
           'enforcing', con.id is not null,
           'enforcing_label', case when con.id is null then 'not enforced (' || a.n || ' of 3)'
                                   when con.since_builds < v_min then 'enforcing · too early (' || con.since_builds || ' of ' || v_min || ' builds since)'
                                   when con.after_n = 0 then 'enforcing · proven — 0 since'
                                   else 'enforcing · still recurring — rewrite it' end,
           'tone', case when con.id is null then 'neutral'
                        when con.since_builds < v_min then 'info'
                        when con.after_n = 0 then 'success' else 'danger' end,
           'sub', case when con.id is null then 'last seen ' || to_char(a.last_at at time zone 'Asia/Kolkata', 'DD Mon')
                       else 'constraint #' || con.id || ' · reached ' || con.injected_count || ' build(s) since ' || to_char(con.measure_from at time zone 'Asia/Kolkata', 'DD Mon')
                            || case when con.rewrite_count > 0 then ' · rewritten ' || con.rewrite_count || '×' else '' end end,
           'text', con.text)
           order by (con.id is not null and con.after_n > 0 and con.since_builds >= v_min) desc, a.n desc, a.last_at desc), '[]'::jsonb)
    into v_causes
    from (select * from agg order by n desc, last_at desc limit 12) a
    left join con on con.area = a.area and con.cause_key = a.cause_key;

  -- WASTE classes straight from the scan; PROPOSALS with the apply affordance.
  v_waste := coalesce(v_wscan->'classes', '[]'::jsonb);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'label', p.label || ' → worker_pool.' || p.knob_path,
           'value', coalesce(p.current_value::text,'—') || ' → ' || coalesce(p.proposed_value::text,'—'),
           'sub', _dev_num_short(p.tokens) || ' tokens over ' || p.commands || ' command(s) · ' || p.rationale,
           'tone', 'warning', 'can_apply', true,
           'apply_label', 'Apply (PIN)', 'dismiss_label', 'Dismiss',
           'opened_label', 'opened ' || to_char(p.created_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI'))
           order by p.tokens desc), '[]'::jsonb)
    into v_props from dev_build_proposal p where p.status = 'open';

  v_lh := dev_lessons_health();
  v_lessons := coalesce(v_lh->'rows', '[]'::jsonb);

  v_hint := 'Window: the last ' || v_days || ' days (since ' || to_char(v_since at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST). '
         || 'A metric with fewer than ' || v_min || ' samples says so instead of printing a number.';

  return jsonb_build_object(
    'ok', true, 'has', true,
    'title', 'Build intelligence',
    'subtitle', 'What the registry has learned, and what it is now enforcing.',
    'window_label', 'last ' || v_days || ' days',
    'since_label', 'since ' || to_char(v_since at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
    'window_hint', v_hint,
    'retry_label', 'Retry',
    'pin_hint', 'Safety PIN',
    'tiles', v_tiles,
    'sections', jsonb_build_array(
      jsonb_build_object('key','causes','kind','rows','title','Repeat causes',
        'sub','A cause seen 3× in one area becomes a constraint injected into every spec for that area. Before/after are counted from the promotion.',
        'empty_label','No cause has repeated in one area yet — nothing is enforced.',
        'rows', v_causes),
      jsonb_build_object('key','waste','kind','rows','title','Waste classes',
        'sub','Tokens attributable to each class over the window, and the existing knob it maps to. Measured every time; proposed only past ' || coalesce((v_bi->>'proposal_min_pct'),'5') || '% of the window.',
        'empty_label','No spend could be classified yet.',
        'rows', v_waste),
      jsonb_build_object('key','proposals','kind','proposals','title','Open proposals',
        'sub','Nothing here changes on its own. Apply asks for your safety PIN and goes through pool_set; Dismiss leaves the knob alone.',
        'empty_label','No proposal is open — every class is under the threshold, or already decided.',
        'rows', v_props),
      jsonb_build_object('key','lessons','kind','rows','title','Lessons health',
        'sub', coalesce((v_lh->>'total'),'0') || ' lessons · ' || coalesce((v_lh->>'dead'),'0') || ' dead weight (unread ' || coalesce((v_lh->>'days'),'30') || ' days) · ' || coalesce((v_lh->>'ineffective'),'0') || ' not working. Nothing is discarded automatically.',
        'empty_label','No lesson qualifies yet. Reads have been tracked since ' || to_char(coalesce((v_bi->>'lessons_tracked_since')::timestamptz, now()) at time zone 'Asia/Kolkata', 'DD Mon') || ' — a lesson unread for ' || coalesce((v_lh->>'days'),'30') || ' days from then, or read 3+ times while its readers still need rework, is listed here with the evidence.',
        'rows', v_lessons)),
    'footnote', 'Estimate error is greatest(estimate, actual) ÷ least(estimate, actual) per command, averaged; 1.0× is perfect. The 2.5× baseline is the estimate/actual ratio measured on 6 Sep 2026 (4176 s estimated against 1694 s actual over 319 commands). A calibrated build is one whose first heartbeat was seeded by dev_eta_estimate; ' || coalesce(v_seeded,0) || ' seeded and ' || coalesce(v_override,0) || ' overridden upward so far.');
end $$;

-- ── 9. claim-time injection — three lines added to dev_cmd_claim ──────────
-- (applied below by re-creating the function with the injection call after
-- dev_qa_scope; the body is otherwise the live one, verbatim)
CREATE OR REPLACE FUNCTION public.dev_cmd_claim(p_agent text, p_routes text[] DEFAULT NULL::text[], p_prefer_area text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_hold bigint; v_hold_t text; v jsonb; v_res jsonb; v_blocked int; v_adm jsonb; v_scope jsonb;
        v_fact boolean; v_msg text; v_env jsonb; v_drain jsonb;
BEGIN
  PERFORM _dev_guard();

  SELECT dc.id, dc.title INTO v_hold, v_hold_t
    FROM dev_commands dc WHERE dc.claimed_by = p_agent AND dc.status = 'building'
    ORDER BY dc.started_at LIMIT 1;
  IF v_hold IS NOT NULL THEN
    RETURN jsonb_build_object('empty', true, 'busy', true, 'holding', v_hold,
      'label', 'Already building #' || v_hold,
      'detail', coalesce(v_hold_t,''),
      'next_step', 'Finish #' || v_hold || ' with complete/fail/ask, or release it, then claim again.');
  END IF;

  -- Sep 5 2026 — DRAIN IS A CLAIM-TIME GATE, not advice to the supervisor.
  SELECT value#>'{ops,drain}' INTO v_drain FROM dev_runner_config WHERE key='worker_pool';
  IF coalesce((v_drain->>'on')::boolean, false) THEN
    RETURN jsonb_build_object('empty', true, 'draining', true,
      'reason', coalesce(nullif(v_drain->>'reason',''),
        'Drain is on — finishing what is building, claiming nothing new.'),
      'since', v_drain->>'at');
  END IF;

  IF (_sec_cfg()->>'frozen')::boolean THEN RETURN jsonb_build_object('empty',true,'frozen',true); END IF;
  IF (sec_check_budget()->>'over')::boolean THEN RETURN jsonb_build_object('empty',true,'budget_paused',true); END IF;

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
    WHERE c.status='pending' AND coalesce(c.wait_state,'') <> 'parked' /* c1819_park_fence */
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
     WHERE c.status='pending' AND coalesce(c.wait_state,'') <> 'parked' /* c1819_park_fence */ AND (p_routes IS NULL OR c.route = ANY(p_routes));
    SELECT value#>>'{}' INTO v_msg FROM ui_copy
     WHERE key = CASE WHEN v_blocked > 0 THEN 'dev_queue.claim_blocked' ELSE 'dev_queue.claim_empty' END;
    RETURN jsonb_build_object('empty', true, 'pending_blocked', v_blocked,
      'reason', coalesce(v_msg, CASE WHEN v_blocked > 0
        THEN 'Every pending command is held behind a file another build is holding right now.'
        ELSE 'Queue empty.' END));
  END IF;

  BEGIN
    v_env := build_branch_env(p_agent, (v->>'id')::bigint, true);
  EXCEPTION WHEN others THEN
    v_env := jsonb_build_object('ok', false, 'on', false, 'target', 'live', 'error', sqlerrm);
  END;

  v_res := _dev_resume_block(v);
  v_scope := dev_qa_scope((v->>'id')::bigint);
  v := _dev_constraints_inject(v); -- CMD #1824: active constraints for the area ride on the returned spec
  RETURN v || jsonb_build_object('resume', v_res,
                                 'is_resume', coalesce((v_res->>'is_resume')::boolean, false),
                                 'qa_scope', v_scope,
                                 'build_env', v_env,
                                 'session_guard', db_guard_check(), 'run_flags', dev_cmd_run_flags(v->>'model', v->>'effort'));
END $function$

;

-- ── 10. backstop cron (offset schedule via the one dispatcher, never bare */N) ─
insert into public.cron_task (name, ord, mode, work_sql, base_interval_s, enabled, dml, note)
values ('build-intel-scan', 455, 'poll', 'select public.dev_cause_scan(); select public.dev_waste_scan();', 3600, true, true,
        'CMD #1824 — promotes repeat causes to constraints and refreshes waste proposals hourly; the dashboard also scans on read when stale')
on conflict (name) do update set work_sql = excluded.work_sql, enabled = true, note = excluded.note;

-- ── 11. the door: Dev Queue header → Tools → Build intelligence ────────────
insert into public.feature_registry
  (feature_key, label, group_label, category, route_key, sort_order, owner,
   surface, is_active, roles_allowed, icon_key, description)
values (
  'devtool.build_intelligence', 'Build intelligence', 'Runtime & health', 'more_system',
  'build_intelligence', 42, 'medibo', 'dev_tools', true, array['admin','super_admin'], 'insights',
  'What the registry has learned: calibrated ETAs, repeat causes now enforced as constraints, waste classes with their knobs, and lessons that earn their place.')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label, route_key = excluded.route_key,
      sort_order = excluded.sort_order, surface = excluded.surface, icon_key = excluded.icon_key,
      description = excluded.description, roles_allowed = excluded.roles_allowed, is_active = true;

grant select on public.dev_command_outcome to service_role;
revoke all on function public.dev_build_intelligence() from anon;
revoke all on function public.dev_build_proposal_apply(bigint, text) from anon;
revoke all on function public.dev_build_proposal_dismiss(bigint, text) from anon;
revoke all on function public.dev_build_constraint_rewrite(bigint, text) from anon;
revoke all on function public.dev_build_constraint_retire(bigint) from anon;
revoke all on function public.dev_cause_scan() from anon;
revoke all on function public.dev_waste_scan() from anon;
revoke all on function public.dev_lessons_health() from anon;
revoke all on function public.dev_eta_estimate(text, text, text, text) from anon;
revoke all on function public.dev_lessons_get(text, bigint) from anon;
