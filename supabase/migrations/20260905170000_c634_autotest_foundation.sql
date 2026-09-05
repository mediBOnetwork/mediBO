-- CHANGE #634 — Autotest foundation, part 1 of Om's self-testing bot.
--
-- Three things land here and nothing else: the CONTRACT every feature must
-- declare before it can ship, the RUN RECORD every later part writes into, and
-- the COVERAGE LEDGER Om watches. The journey scripts themselves are parts 2-6.
--
-- The whole thing rides TEST MODE (#573): a run opens a test session, does its
-- work as a real user against the real deployed app, and purges. `orders` and
-- 56 other tables already carry test_session_id and are stamped ambiently, so
-- nothing the bot does can survive its own run.
--
-- Idempotent throughout: the merge worker replays this file on live once.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. THE MANIFEST — feature_registry declares its own test contract
-- ─────────────────────────────────────────────────────────────────────────
-- The registry is already the list of everything mediBO does (159 active
-- rows). Making the contract a column ON that row, rather than a side table
-- nobody joins, is what makes "a feature without a contract" a fact the rg
-- guard can read in one predicate.
alter table public.feature_registry
  add column if not exists test_entry       text,
  add column if not exists test_roles       text[],
  add column if not exists test_steps       jsonb   not null default '[]'::jsonb,
  add column if not exists test_expect      jsonb   not null default '{}'::jsonb,
  add column if not exists test_automatable boolean not null default true,
  add column if not exists test_skip_reason text,
  add column if not exists test_contract_at timestamptz;

comment on column public.feature_registry.test_entry is
  'CHANGE #634 — entry point/deep link the harness navigates to (e.g. /admin/go/customers).';
comment on column public.feature_registry.test_roles is
  'CHANGE #634 — roles that should be able to REACH this feature; the harness drives one session per role.';
comment on column public.feature_registry.test_steps is
  'CHANGE #634 — the happy path, an ordered array of {kind,...} steps the harness executes verbatim.';
comment on column public.feature_registry.test_expect is
  'CHANGE #634 — the expected end state: {kind:''db''|''visible'', ...}. One assertion, checked last.';
comment on column public.feature_registry.test_skip_reason is
  'CHANGE #634 — why this feature genuinely cannot be automated. Required when test_automatable is false.';

-- A contract is COMPLETE when it can actually be run, or when it says in
-- writing why it cannot. Generated (not a view, not a trigger) so no code path
-- can ever write a row whose "has contract" flag disagrees with its contract.
do $c634_gen$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='feature_registry'
       and column_name='has_test_contract') then
    alter table public.feature_registry
      add column has_test_contract boolean
      generated always as (
        case
          when test_automatable = false
            then coalesce(btrim(test_skip_reason), '') <> ''
          else coalesce(btrim(test_entry), '') <> ''
           and coalesce(cardinality(test_roles), 0) >= 1
           and jsonb_typeof(test_steps) = 'array'
           and jsonb_array_length(test_steps) >= 1
           and coalesce(test_expect ->> 'kind', '') <> ''
        end
      ) stored;
  end if;
end
$c634_gen$;

create index if not exists feature_registry_no_contract_idx
  on public.feature_registry (feature_key)
  where is_active and not has_test_contract;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. RUN RECORDS — one row per bot run, one row per feature/role/scenario
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.test_runs (
  id               bigserial primary key,
  run_key          uuid        not null default gen_random_uuid(),
  kind             text        not null default 'preview',   -- preview | prod_smoke | local
  target_url       text        not null default '',
  git_commit       text,
  deploy_no        int,
  command_id       bigint,
  test_session_id  bigint      references public.test_sessions(id) on delete set null,
  triggered_by     text        not null default 'vm',        -- vm | dispatcher | admin
  status           text        not null default 'running',   -- running | passed | failed | error | aborted
  started_at       timestamptz not null default now(),
  ended_at         timestamptz,
  duration_ms      int,
  totals           jsonb       not null default '{}'::jsonb,
  artifacts_path   text,
  console_errors   int         not null default 0,
  network_failures int         not null default 0,
  note             text
);
create unique index if not exists test_runs_run_key_idx on public.test_runs (run_key);
create index if not exists test_runs_started_idx on public.test_runs (started_at desc);
create index if not exists test_runs_status_idx on public.test_runs (status, started_at desc);

create table if not exists public.test_results (
  id           bigserial primary key,
  run_id       bigint      not null references public.test_runs(id) on delete cascade,
  feature_key  text        not null,
  role         text        not null default '',
  scenario     text        not null default 'happy_path',
  verdict      text        not null default 'skipped',   -- passed | failed | skipped | blocked
  duration_ms  int         not null default 0,
  steps        jsonb       not null default '[]'::jsonb,
  artifacts    jsonb       not null default '{}'::jsonb, -- {video, shots[], console[], network[]}
  error        text,
  created_at   timestamptz not null default now()
);
create index if not exists test_results_run_idx     on public.test_results (run_id);
create index if not exists test_results_feature_idx on public.test_results (feature_key, created_at desc);
create unique index if not exists test_results_unique_idx
  on public.test_results (run_id, feature_key, role, scenario);

-- ─────────────────────────────────────────────────────────────────────────
-- 3. COVERAGE LEDGER — the number Om watches
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.test_coverage (
  feature_key    text primary key,
  has_contract   boolean     not null default false,
  automatable    boolean     not null default true,
  skip_reason    text,
  last_run_id    bigint,
  last_run_at    timestamptz,
  last_verdict   text,
  last_green_at  timestamptz,
  runs_30d       int         not null default 0,
  fails_30d      int         not null default 0,
  flake_pct      numeric     not null default 0,
  never_tested   boolean     not null default true,
  updated_at     timestamptz not null default now()
);
create index if not exists test_coverage_never_idx on public.test_coverage (never_tested, feature_key);

alter table public.test_runs     enable row level security;
alter table public.test_results  enable row level security;
alter table public.test_coverage enable row level security;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. COPY — every word the coverage screen prints lives here, not in Dart
-- ─────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('test_coverage.title',            to_jsonb('Test coverage'::text)),
  ('test_coverage.subtitle',         to_jsonb('{covered} of {total} features carry a test contract'::text)),
  ('test_coverage.filter_all',       to_jsonb('All'::text)),
  ('test_coverage.filter_never',     to_jsonb('Never tested'::text)),
  ('test_coverage.filter_failing',   to_jsonb('Failing'::text)),
  ('test_coverage.filter_nocontract',to_jsonb('No contract'::text)),
  ('test_coverage.filter_manual',    to_jsonb('Manual only'::text)),
  ('test_coverage.never_tested',     to_jsonb('Never tested'::text)),
  ('test_coverage.no_contract',      to_jsonb('No contract'::text)),
  ('test_coverage.manual_only',      to_jsonb('Manual only'::text)),
  ('test_coverage.last_never',       to_jsonb('never run'::text)),
  ('test_coverage.last_prefix',      to_jsonb('last run {when}'::text)),
  ('test_coverage.green_prefix',     to_jsonb('last green {when}'::text)),
  ('test_coverage.green_never',      to_jsonb('never green'::text)),
  ('test_coverage.flake_label',      to_jsonb('{pct}% flaky over {runs} runs'::text)),
  ('test_coverage.empty',            to_jsonb('Nothing matches this filter.'::text)),
  ('test_coverage.runs_title',       to_jsonb('Recent runs'::text)),
  ('test_coverage.runs_none',        to_jsonb('The bot has not run yet.'::text)),
  ('test_coverage.verdict_passed',   to_jsonb('Passed'::text)),
  ('test_coverage.verdict_failed',   to_jsonb('Failed'::text)),
  ('test_coverage.verdict_skipped',  to_jsonb('Skipped'::text)),
  ('test_coverage.verdict_blocked',  to_jsonb('Blocked'::text)),
  ('test_coverage.headline_label',   to_jsonb('Coverage'::text)),
  ('test_coverage.never_headline',   to_jsonb('{n} features have never been tested'::text)),
  ('test_coverage.never_headline_none', to_jsonb('Every feature with a contract has been run at least once'::text)),
  ('test_coverage.nav_label',        to_jsonb('Test coverage'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. RPCs
-- ─────────────────────────────────────────────────────────────────────────

-- Write one feature's contract. The generated has_test_contract column decides
-- whether what was written actually counts — this function never asserts it.
create or replace function public.test_contract_set(
  p_feature      text,
  p_entry        text    default null,
  p_roles        text[]  default null,
  p_steps        jsonb   default null,
  p_expect       jsonb   default null,
  p_automatable  boolean default null,
  p_skip_reason  text    default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_row public.feature_registry;
begin
  perform public._dev_guard();
  update public.feature_registry f
     set test_entry       = coalesce(p_entry, f.test_entry),
         test_roles       = coalesce(p_roles, f.test_roles),
         test_steps       = coalesce(p_steps, f.test_steps),
         test_expect      = coalesce(p_expect, f.test_expect),
         test_automatable = coalesce(p_automatable, f.test_automatable),
         test_skip_reason = coalesce(p_skip_reason, f.test_skip_reason),
         test_contract_at = now()
   where f.feature_key = p_feature
  returning f.* into v_row;

  if v_row.feature_key is null then
    return jsonb_build_object('ok', false, 'error', 'no_such_feature', 'feature_key', p_feature);
  end if;

  perform public.test_coverage_sync(p_feature);
  return jsonb_build_object('ok', true, 'feature_key', v_row.feature_key,
                            'has_contract', v_row.has_test_contract);
end $$;

-- Keep ONE feature's ledger row in step with its contract. Called by
-- test_contract_set and by the registry trigger, so the ledger can never claim
-- a contract the registry does not hold.
create or replace function public.test_coverage_sync(p_feature text)
returns void
language plpgsql security definer set search_path to 'public'
as $$
begin
  insert into public.test_coverage (feature_key, has_contract, automatable, skip_reason, updated_at)
  select f.feature_key, f.has_test_contract, f.test_automatable, f.test_skip_reason, now()
    from public.feature_registry f
   where f.feature_key = p_feature
  on conflict (feature_key) do update
     set has_contract = excluded.has_contract,
         automatable  = excluded.automatable,
         skip_reason  = excluded.skip_reason,
         updated_at   = now();
end $$;

create or replace function public._trg_feature_registry_coverage()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  perform public.test_coverage_sync(new.feature_key);
  return new;
end $$;

drop trigger if exists feature_registry_coverage_trg on public.feature_registry;
create trigger feature_registry_coverage_trg
  after insert or update on public.feature_registry
  for each row execute function public._trg_feature_registry_coverage();

-- THE MANIFEST the harness reads. It never decides what to test — this does.
create or replace function public.test_manifest(
  p_role           text    default null,
  p_feature        text    default null,
  p_include_manual boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v jsonb;
begin
  perform public._dev_guard();
  select coalesce(jsonb_agg(x order by x->>'feature_key'), '[]'::jsonb) into v
    from (
      select jsonb_build_object(
               'feature_key',  f.feature_key,
               'label',        f.label,
               'category',     f.category,
               'surface',      f.surface,
               'route_key',    f.route_key,
               'entry',        f.test_entry,
               'roles',        to_jsonb(coalesce(f.test_roles, array[]::text[])),
               'steps',        f.test_steps,
               'expect',       f.test_expect,
               'automatable',  f.test_automatable,
               'skip_reason',  f.test_skip_reason) as x
        from public.feature_registry f
       where f.is_active
         and f.has_test_contract
         and (p_feature is null or f.feature_key = p_feature)
         and (p_include_manual or f.test_automatable)
         and (p_role is null or p_role = any(coalesce(f.test_roles, array[]::text[])))
    ) s;
  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v), 'features', v);
end $$;

-- Open a run. A run OWNS a test session: everything it writes downstream is
-- stamped with that session id and dies when the run purges.
create or replace function public.test_run_start(
  p_kind        text default 'preview',
  p_target_url  text default '',
  p_commit      text default null,
  p_deploy_no   int  default null,
  p_command_id  bigint default null,
  p_triggered_by text default 'vm',
  p_note        text default null,
  p_open_session boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_key uuid; v_sess jsonb; v_sid bigint;
begin
  perform public._dev_guard();
  if p_open_session then
    v_sess := public.test_session_start('autotest ' || coalesce(p_kind,'preview'), null);
    v_sid  := nullif(v_sess->>'session_id','')::bigint;
  end if;

  insert into public.test_runs (kind, target_url, git_commit, deploy_no, command_id,
                                test_session_id, triggered_by, note)
  values (coalesce(nullif(p_kind,''),'preview'), coalesce(p_target_url,''), p_commit,
          p_deploy_no, p_command_id, v_sid, coalesce(nullif(p_triggered_by,''),'vm'), p_note)
  returning id, run_key into v_id, v_key;

  return jsonb_build_object('ok', true, 'run_id', v_id, 'run_key', v_key,
                            'test_session_id', v_sid,
                            'session', coalesce(v_sess, '{}'::jsonb));
end $$;

-- Record results. Idempotent per (run, feature, role, scenario) so a retried
-- step overwrites its own row instead of inflating the run.
create or replace function public.test_result_report(p_run_id bigint, p_results jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_n int := 0;
begin
  perform public._dev_guard();
  if jsonb_typeof(p_results) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'results_not_an_array');
  end if;

  insert into public.test_results (run_id, feature_key, role, scenario, verdict,
                                   duration_ms, steps, artifacts, error)
  select p_run_id,
         r->>'feature_key',
         coalesce(r->>'role',''),
         coalesce(nullif(r->>'scenario',''),'happy_path'),
         coalesce(nullif(r->>'verdict',''),'skipped'),
         coalesce((r->>'duration_ms')::int, 0),
         coalesce(r->'steps', '[]'::jsonb),
         coalesce(r->'artifacts', '{}'::jsonb),
         nullif(r->>'error','')
    from jsonb_array_elements(p_results) r
   where coalesce(r->>'feature_key','') <> ''
  on conflict (run_id, feature_key, role, scenario) do update
     set verdict     = excluded.verdict,
         duration_ms = excluded.duration_ms,
         steps       = excluded.steps,
         artifacts   = excluded.artifacts,
         error       = excluded.error,
         created_at  = now();
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'recorded', v_n);
end $$;

-- Close a run: totals from the rows that were actually written, ledger
-- refreshed, and the test session ended + purged so nothing survives.
create or replace function public.test_run_finish(
  p_run_id          bigint,
  p_status          text default null,
  p_artifacts_path  text default null,
  p_console_errors  int  default null,
  p_network_failures int default null,
  p_purge           boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_run public.test_runs; v_tot jsonb; v_status text;
  v_pass int; v_fail int; v_skip int; v_block int; v_purge jsonb := '{}'::jsonb;
begin
  perform public._dev_guard();
  select * into v_run from public.test_runs where id = p_run_id;
  if v_run.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_such_run');
  end if;

  select count(*) filter (where verdict='passed'),
         count(*) filter (where verdict='failed'),
         count(*) filter (where verdict='skipped'),
         count(*) filter (where verdict='blocked')
    into v_pass, v_fail, v_skip, v_block
    from public.test_results where run_id = p_run_id;

  v_tot := jsonb_build_object('passed',v_pass,'failed',v_fail,
                              'skipped',v_skip,'blocked',v_block,
                              'total',v_pass+v_fail+v_skip+v_block);
  v_status := coalesce(nullif(p_status,''),
                       case when v_fail > 0 then 'failed'
                            when v_pass > 0 then 'passed'
                            else 'error' end);

  update public.test_runs
     set status = v_status,
         ended_at = now(),
         duration_ms = (extract(epoch from (now() - started_at)) * 1000)::int,
         totals = v_tot,
         artifacts_path = coalesce(p_artifacts_path, artifacts_path),
         console_errors = coalesce(p_console_errors, console_errors),
         network_failures = coalesce(p_network_failures, network_failures)
   where id = p_run_id;

  -- The session dies with the run. A bot that leaves its data behind is worse
  -- than no bot: #573 exists so a synthetic order is never a real one.
  if p_purge and v_run.test_session_id is not null then
    begin
      perform public.test_session_end(v_run.test_session_id);
      v_purge := public.test_session_purge(v_run.test_session_id);
    exception when others then
      v_purge := jsonb_build_object('ok', false, 'error', sqlerrm);
    end;
  end if;

  perform public.test_coverage_refresh();
  return jsonb_build_object('ok', true, 'run_id', p_run_id, 'status', v_status,
                            'totals', v_tot, 'purge', v_purge);
end $$;

-- Rebuild the whole ledger from the registry + the result history.
create or replace function public.test_coverage_refresh()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_n int;
begin
  insert into public.test_coverage (feature_key, has_contract, automatable, skip_reason, updated_at)
  select f.feature_key, f.has_test_contract, f.test_automatable, f.test_skip_reason, now()
    from public.feature_registry f
   where f.is_active
  on conflict (feature_key) do update
     set has_contract = excluded.has_contract,
         automatable  = excluded.automatable,
         skip_reason  = excluded.skip_reason,
         updated_at   = now();

  with last as (
    select distinct on (r.feature_key)
           r.feature_key, r.run_id, r.verdict, r.created_at
      from public.test_results r
     order by r.feature_key, r.created_at desc
  ), green as (
    select r.feature_key, max(r.created_at) as at
      from public.test_results r where r.verdict = 'passed'
     group by r.feature_key
  ), win as (
    select r.feature_key,
           count(*)                                  as runs,
           count(*) filter (where r.verdict='failed') as fails
      from public.test_results r
     where r.created_at > now() - interval '30 days'
     group by r.feature_key
  )
  update public.test_coverage c
     set last_run_id   = l.run_id,
         last_run_at   = l.created_at,
         last_verdict  = l.verdict,
         last_green_at = g.at,
         runs_30d      = coalesce(w.runs, 0),
         fails_30d     = coalesce(w.fails, 0),
         flake_pct     = case when coalesce(w.runs,0) = 0 then 0
                              else round(100.0 * coalesce(w.fails,0) / w.runs, 1) end,
         never_tested  = (l.feature_key is null),
         updated_at    = now()
    from public.test_coverage c2
    left join last  l on l.feature_key = c2.feature_key
    left join green g on g.feature_key = c2.feature_key
    left join win   w on w.feature_key = c2.feature_key
   where c.feature_key = c2.feature_key;

  select count(*) into v_n from public.test_coverage;
  return jsonb_build_object('ok', true, 'features', v_n);
end $$;

-- "3h ago" / "just now" — one place, so no screen ever formats a timestamp.
create or replace function public.test_ago_label(p_at timestamptz)
returns text
language sql stable security definer set search_path to 'public'
as $$
  select case
    when p_at is null then ''
    when now() - p_at < interval '90 seconds' then 'just now'
    when now() - p_at < interval '1 hour'
      then (extract(epoch from (now() - p_at))/60)::int || 'm ago'
    when now() - p_at < interval '24 hours'
      then (extract(epoch from (now() - p_at))/3600)::int || 'h ago'
    else (extract(epoch from (now() - p_at))/86400)::int || 'd ago'
  end;
$$;

-- THE SCREEN. Every string the Flutter panel prints is built here; the panel
-- computes nothing, not even the percentage.
create or replace function public.test_coverage_home(p_filter text default 'all')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_filter text := coalesce(nullif(p_filter,''), 'all');
  v_total int; v_covered int; v_never int; v_failing int; v_nocontract int; v_manual int;
  v_pct numeric; v_rows jsonb; v_runs jsonb;
begin
  perform public._dev_guard();
  perform public.test_coverage_refresh();

  select count(*),
         count(*) filter (where has_contract),
         count(*) filter (where has_contract and automatable and never_tested),
         count(*) filter (where last_verdict = 'failed'),
         count(*) filter (where not has_contract),
         count(*) filter (where not automatable)
    into v_total, v_covered, v_never, v_failing, v_nocontract, v_manual
    from public.test_coverage;

  v_pct := case when coalesce(v_total,0) = 0 then 0
                else round(100.0 * v_covered / v_total) end;

  select coalesce(jsonb_agg(x order by ord, feature_key), '[]'::jsonb) into v_rows
    from (
      select c.feature_key,
             case when not c.has_contract then 0
                  when c.never_tested and c.automatable then 1
                  when c.last_verdict = 'failed' then 2
                  else 3 end as ord,
             jsonb_build_object(
               'feature_key', c.feature_key,
               'label',       coalesce(f.label, c.feature_key),
               'group_label', coalesce(f.group_label, ''),
               'entry',       coalesce(f.test_entry, ''),
               'tone',
                 case when not c.has_contract then 'danger'
                      when not c.automatable then 'neutral'
                      when c.never_tested then 'warning'
                      when c.last_verdict = 'failed' then 'danger'
                      when c.last_verdict = 'passed' then 'success'
                      else 'neutral' end,
               'status_label',
                 case when not c.has_contract then public.uic('test_coverage.no_contract','No contract')
                      when not c.automatable  then public.uic('test_coverage.manual_only','Manual only')
                      when c.never_tested     then public.uic('test_coverage.never_tested','Never tested')
                      when c.last_verdict='passed'  then public.uic('test_coverage.verdict_passed','Passed')
                      when c.last_verdict='failed'  then public.uic('test_coverage.verdict_failed','Failed')
                      when c.last_verdict='blocked' then public.uic('test_coverage.verdict_blocked','Blocked')
                      else public.uic('test_coverage.verdict_skipped','Skipped') end,
               'sub_label',
                 case
                   when not c.automatable and coalesce(c.skip_reason,'') <> '' then c.skip_reason
                   when c.last_run_at is null then public.uic('test_coverage.last_never','never run')
                   else replace(public.uic('test_coverage.last_prefix','last run {when}'),
                                '{when}', public.test_ago_label(c.last_run_at))
                 end,
               'green_label',
                 case when c.last_green_at is null
                        then public.uic('test_coverage.green_never','never green')
                      else replace(public.uic('test_coverage.green_prefix','last green {when}'),
                                   '{when}', public.test_ago_label(c.last_green_at)) end,
               'flake_label',
                 case when c.runs_30d = 0 then ''
                      else replace(replace(public.uic('test_coverage.flake_label','{pct}% flaky over {runs} runs'),
                                   '{pct}', c.flake_pct::text), '{runs}', c.runs_30d::text) end
             ) as x
        from public.test_coverage c
        left join public.feature_registry f on f.feature_key = c.feature_key
       where case v_filter
               when 'never'      then c.has_contract and c.automatable and c.never_tested
               when 'failing'    then c.last_verdict = 'failed'
               when 'nocontract' then not c.has_contract
               when 'manual'     then not c.automatable
               else true end
    ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'run_id', r.id,
           'label',  coalesce(nullif(r.kind,''),'preview') || ' · ' || coalesce(r.git_commit, ''),
           'value',  coalesce(r.totals->>'passed','0') || '/' || coalesce(r.totals->>'total','0'),
           'sub',    public.test_ago_label(r.started_at),
           'tone',   case r.status when 'passed' then 'success'
                                   when 'failed' then 'danger'
                                   when 'running' then 'info'
                                   else 'warning' end
         ) order by r.started_at desc), '[]'::jsonb) into v_runs
    from (select * from public.test_runs order by started_at desc limit 10) r;

  return jsonb_build_object(
    'ok', true, 'has', true,
    'title',    public.uic('test_coverage.title','Test coverage'),
    'subtitle', replace(replace(public.uic('test_coverage.subtitle',
                  '{covered} of {total} features carry a test contract'),
                  '{covered}', v_covered::text), '{total}', v_total::text),
    'headline', jsonb_build_object(
       'label', public.uic('test_coverage.headline_label','Coverage'),
       'value', v_pct::text || '%',
       'tone',  case when v_pct >= 95 then 'success'
                     when v_pct >= 70 then 'warning' else 'danger' end,
       'sub',   case when v_never = 0
                     then public.uic('test_coverage.never_headline_none',
                            'Every feature with a contract has been run at least once')
                     else replace(public.uic('test_coverage.never_headline',
                            '{n} features have never been tested'), '{n}', v_never::text) end),
    'filters', jsonb_build_array(
       jsonb_build_object('key','all',       'label',public.uic('test_coverage.filter_all','All'),
                          'count',v_total,      'selected', v_filter='all'),
       jsonb_build_object('key','never',     'label',public.uic('test_coverage.filter_never','Never tested'),
                          'count',v_never,      'selected', v_filter='never'),
       jsonb_build_object('key','failing',   'label',public.uic('test_coverage.filter_failing','Failing'),
                          'count',v_failing,    'selected', v_filter='failing'),
       jsonb_build_object('key','nocontract','label',public.uic('test_coverage.filter_nocontract','No contract'),
                          'count',v_nocontract, 'selected', v_filter='nocontract'),
       jsonb_build_object('key','manual',    'label',public.uic('test_coverage.filter_manual','Manual only'),
                          'count',v_manual,     'selected', v_filter='manual')),
    'rows', v_rows,
    'empty_label', public.uic('test_coverage.empty','Nothing matches this filter.'),
    'runs', jsonb_build_object(
       'title',      public.uic('test_coverage.runs_title','Recent runs'),
       'none_label', public.uic('test_coverage.runs_none','The bot has not run yet.'),
       'rows',       v_runs));
end $$;

revoke all on function public.test_contract_set(text,text,text[],jsonb,jsonb,boolean,text) from public, anon;
revoke all on function public.test_manifest(text,text,boolean) from public, anon;
revoke all on function public.test_run_start(text,text,text,int,bigint,text,text,boolean) from public, anon;
revoke all on function public.test_result_report(bigint,jsonb) from public, anon;
revoke all on function public.test_run_finish(bigint,text,text,int,int,boolean) from public, anon;
revoke all on function public.test_coverage_home(text) from public, anon;
grant execute on function public.test_contract_set(text,text,text[],jsonb,jsonb,boolean,text) to authenticated, service_role;
grant execute on function public.test_manifest(text,text,boolean) to authenticated, service_role;
grant execute on function public.test_run_start(text,text,text,int,bigint,text,text,boolean) to authenticated, service_role;
grant execute on function public.test_result_report(bigint,jsonb) to authenticated, service_role;
grant execute on function public.test_run_finish(bigint,text,text,int,int,boolean) to authenticated, service_role;
grant execute on function public.test_coverage_home(text) to authenticated, service_role;
grant execute on function public.test_coverage_refresh() to authenticated, service_role;
grant execute on function public.test_ago_label(timestamptz) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. SEED — every active feature gets a contract, in bulk
-- ─────────────────────────────────────────────────────────────────────────
-- The generic contract is a REACHABILITY contract and says so: sign in as the
-- role, open the registry's own deep link, and prove the route actually
-- painted. It is deliberately not a pretend end-to-end — Flutter draws to
-- canvas, so the only honest visible assertion is the render-log the app
-- writes itself (#325's c325_deep_link, and boot_status from the boot path).
-- Parts 2-6 deepen these one area at a time; this is the floor nobody falls
-- below, and the rg gate keeps it that way.

-- 6a. Aliases are tested at the row they were merged into, never twice.
update public.feature_registry f
   set test_automatable = false,
       test_skip_reason = 'Alias of ' || f.merged_into || ' — the journey runs there.',
       test_contract_at = now()
 where f.is_active
   and coalesce(f.merged_into,'') <> ''
   and f.test_contract_at is null;

-- 6b. Genuinely un-automatable: hardware the VM does not have, or a real
--     third party that would be charged / published / paged for real.
update public.feature_registry f
   set test_automatable = false,
       test_skip_reason = v.reason,
       test_contract_at = now()
  from (values
    ('admin.rx_scan',      'Needs a real camera and a physical prescription — no headless equivalent.'),
    ('shop.pos_upi',       'Generates a live UPI QR against the payment provider; a bot run would be a real collection request.'),
    ('devtool.play_store', 'Drives the Google Play Console, which is outside this app and publishes to real users.'),
    ('devtool.gcp',        'Mutates cloud infrastructure; a bot run would start or stop real machines.'),
    ('admin.admin_push',   'Delivery can only be proven on a real device that received the push.'),
    ('admin.notify_cost',  'Reads the provider''s billed usage — nothing to drive, and a send would be charged.')
  ) as v(feature_key, reason)
 where f.feature_key = v.feature_key
   and f.is_active
   and f.test_contract_at is null;

-- 6c. Everything else: the reachability contract, derived from the row itself.
update public.feature_registry f
   set test_entry = coalesce(nullif(f.deep_link,''),
                             case when coalesce(f.route_key,'') <> ''
                                  then '/admin/go/' || f.route_key end),
       test_roles = coalesce(nullif(f.roles_allowed, array[]::text[]),
                             array['super_admin']::text[]),
       test_steps = jsonb_build_array(
         jsonb_build_object('kind','auth',  'role','{role}'),
         jsonb_build_object('kind','goto',  'path',
           coalesce(nullif(f.deep_link,''),
                    case when coalesce(f.route_key,'') <> ''
                         then '/admin/go/' || f.route_key end)),
         jsonb_build_object('kind','settle','ms', 6000)),
       test_expect = case
         when coalesce(f.deep_link,'') = '' and coalesce(f.route_key,'') <> ''
           then jsonb_build_object('kind','visible','source','render_log',
                                   'key','c325_deep_link','equals', f.route_key)
           else jsonb_build_object('kind','visible','source','render_log',
                                   'key','boot_status','equals','painted')
         end,
       test_automatable = true,
       test_contract_at = now()
 where f.is_active
   and f.test_contract_at is null
   and (coalesce(f.deep_link,'') <> '' or coalesce(f.route_key,'') <> '');

-- 6d. A row with neither a deep link nor a route key cannot be navigated to at
--     all. That is a registry gap, not a testing one — say so rather than
--     inventing a path that would 404.
update public.feature_registry f
   set test_automatable = false,
       test_skip_reason = 'No deep link and no route key in the registry — nothing to navigate to. Give the row an entry point and this contract becomes automatable.',
       test_contract_at = now()
 where f.is_active and f.test_contract_at is null;

-- 6e. THE PROVEN ONE. cust.orders carries a real end-to-end contract, not a
--     reachability one: a customer signs in, puts a real line in a real cart,
--     places it through place_order_v2 and the ORDER ROW is the assertion.
--     It runs inside the run's test session, so the order it creates is
--     synthetic and is purged when the run finishes.
update public.feature_registry
   set test_entry  = '/',
       test_roles  = array['customer']::text[],
       test_steps  = jsonb_build_array(
         jsonb_build_object('kind','auth',   'role','customer'),
         jsonb_build_object('kind','goto',   'path','/'),
         jsonb_build_object('kind','expect_render','key','boot_status','equals','painted'),
         jsonb_build_object('kind','rpc',    'fn','cart_clear',    'as','user'),
         jsonb_build_object('kind','pick_product'),
         jsonb_build_object('kind','rpc',    'fn','cart_set_item', 'as','user',
                            'args', jsonb_build_object('p_qty', 1)),
         jsonb_build_object('kind','goto',   'path','/cart'),
         jsonb_build_object('kind','settle', 'ms', 5000),
         jsonb_build_object('kind','rpc',    'fn','place_order_v2','as','user'),
         jsonb_build_object('kind','goto',   'path','/admin/go/cust_orders'),
         jsonb_build_object('kind','settle', 'ms', 5000)),
       test_expect = jsonb_build_object(
         'kind','db',
         'note','an order row exists for this customer, stamped with the run''s test session',
         'rpc','test_assert_order_placed'),
       test_automatable = true,
       test_skip_reason = null,
       test_contract_at = now()
 where feature_key = 'cust.orders';

-- The end-state assertion for 6e, server-side: the harness never writes SQL.
create or replace function public.test_assert_order_placed(p_run_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_sid bigint; v_n int; v_id uuid;
begin
  perform public._dev_guard();
  select test_session_id into v_sid from public.test_runs where id = p_run_id;
  if v_sid is null then
    return jsonb_build_object('ok', false, 'error', 'run_has_no_test_session');
  end if;
  select count(*), max(o.id::text)::uuid into v_n, v_id
    from public.orders o where o.test_session_id = v_sid;
  return jsonb_build_object(
    'ok', v_n > 0, 'orders', v_n, 'order_id', v_id, 'test_session_id', v_sid,
    'detail', case when v_n > 0
                   then v_n || ' synthetic order(s) landed in session ' || v_sid
                   else 'no order was created in session ' || v_sid end);
end $$;
revoke all on function public.test_assert_order_placed(bigint) from public, anon;
grant execute on function public.test_assert_order_placed(bigint) to authenticated, service_role;

select public.test_coverage_refresh();

-- ─────────────────────────────────────────────────────────────────────────
-- 7. THE GATE — nothing new ships untested
-- ─────────────────────────────────────────────────────────────────────────
-- One fact, one function, read by the behaviour test AND by the screen: which
-- active features are missing a contract right now.
create or replace function public.rg_contract_gap()
returns table(feature_key text, label text, reason text)
language sql stable security definer set search_path to 'public'
as $$
  select f.feature_key, f.label,
         case when f.test_automatable = false
                then 'marked not automatable but gives no reason'
              when coalesce(btrim(f.test_entry),'') = ''
                then 'no entry point'
              when coalesce(cardinality(f.test_roles),0) = 0
                then 'no roles'
              when jsonb_typeof(f.test_steps) <> 'array' or jsonb_array_length(f.test_steps) = 0
                then 'no happy path'
              else 'no expected end state' end
    from public.feature_registry f
   where f.is_active and not f.has_test_contract
   order by f.feature_key;
$$;
grant execute on function public.rg_contract_gap() to authenticated, service_role;

-- The rg guard itself. rg_check() counts a failing behaviour as critical, so a
-- feature added to the registry without a test contract turns the guard RED in
-- the same command that added it — which is the whole point of #634.
insert into public.rg_behavior_tests (name, body, enabled, note) values (
  'c634_every_feature_declares_a_test_contract',
  $body$
do $c634$
declare v_gap int; v_names text; v_probe int; v_probe_key text;
begin
  -- 1. the live fact: no active feature may be without a contract.
  select count(*), coalesce(string_agg(feature_key, ', ' order by feature_key), '')
    into v_gap, v_names
    from public.rg_contract_gap();
  if v_gap > 0 then
    raise exception 'c634: % active feature(s) have no test contract: %', v_gap, left(v_names, 400);
  end if;

  -- 2. the gate is only worth having if it can still SEE a gap. Blank one
  --    real row's entry point and prove rg_contract_gap() reports it. Blanking
  --    an existing row rather than inserting a probe row keeps this test free
  --    of the registry's own foreign keys (icon, category), which a build
  --    branch does not always carry — a gate that only runs on production is
  --    not a gate. The whole body is rolled back either way.
  select feature_key into v_probe_key
    from public.feature_registry
   where is_active and test_automatable and coalesce(btrim(test_entry),'') <> ''
   order by feature_key limit 1;

  if v_probe_key is not null then
    update public.feature_registry set test_entry = '' where feature_key = v_probe_key;
    select count(*) into v_probe
      from public.rg_contract_gap() g where g.feature_key = v_probe_key;
    if v_probe <> 1 then
      raise exception 'c634: the contract gate did not report %, whose entry point was just removed', v_probe_key;
    end if;
  end if;

  raise exception 'RG_ROLLBACK';
end
$c634$;
  $body$,
  true,
  'CHANGE #634 — a feature without a test contract turns the guard red, and the gate is proven still able to see one.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. WHO THE BOT SIGNS IN AS — backend-owned, passwords never stored here
-- ─────────────────────────────────────────────────────────────────────────
-- qa_test_identities has existed since #129 with every row ready=false and no
-- identity, so nothing could ever be driven as a role. The three published test
-- logins (CLAUDE.md) are filled in here; the PASSWORD stays on the VM in
-- ~/.medibo/autotest.env (chmod 600, never committed, never in a payload).
-- A role with no identity is reported by the harness as BLOCKED with this
-- table's own note — never as a failure, and never silently skipped.
insert into public.qa_test_identities (role, identity, ready, note)
values ('customer', 'test.cust1@medibo.in', true, 'password lives in ~/.medibo/autotest.env on the build VM'),
       ('admin',    'test.admin@medibo.in', true, 'password lives in ~/.medibo/autotest.env on the build VM'),
       ('supplier', 'test.sup1@medibo.in',  true, 'password lives in ~/.medibo/autotest.env on the build VM')
on conflict (role) do update
   set identity = excluded.identity,
       ready    = true,
       note     = excluded.note
 where coalesce(public.qa_test_identities.identity,'') = '';

update public.qa_test_identities
   set note = 'no test account exists for this role yet — seed one and set ready'
 where coalesce(identity,'') = '' and coalesce(note,'') like 'seed a test-only%';

create or replace function public.test_identities()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'role', t.role, 'identity', coalesce(t.identity,''),
           'ready', t.ready, 'note', coalesce(t.note,'')) order by t.role), '[]'::jsonb)
    from public.qa_test_identities t;
$$;
revoke all on function public.test_identities() from public, anon;
grant execute on function public.test_identities() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. THE BOT'S SESSION IS SCOPED TO THE BOT
-- ─────────────────────────────────────────────────────────────────────────
-- test_session_start() opens a GLOBAL session: while it is live, EVERY user's
-- writes are stamped with it, and test_run_finish() purges everything carrying
-- that stamp. For a human doing a deliberate ten-minute test that is the point.
-- For a bot that may run hourly against production it is a way to delete a real
-- customer's real order.
--
-- So a run narrows its own session to 'actors' — the mode #573 already
-- supports in _test_session_ambient() — and registers exactly the bot's test
-- logins as those actors. A real customer ordering during a run is not stamped
-- and cannot be purged. Only a session this function CREATED is narrowed; one
-- a human already had open is left exactly as they set it.
create or replace function public.test_run_scope_to_bot(p_session bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_n int := 0;
begin
  if p_session is null then return jsonb_build_object('ok', false, 'error', 'no_session'); end if;

  insert into public.test_session_actor (session_id, user_id, label)
  select p_session, u.id, t.role
    from public.qa_test_identities t
    join auth.users u on lower(u.email) = lower(t.identity)
   where coalesce(t.identity,'') <> ''
  on conflict (session_id, user_id) do nothing;
  get diagnostics v_n = row_count;

  -- Narrowing with no actors would stamp NOTHING and the run would assert on
  -- an empty session, so the scope only changes once there is somebody in it.
  if v_n > 0 then
    update public.test_sessions set scope = 'actors' where id = p_session;
  end if;

  return jsonb_build_object('ok', v_n > 0, 'actors', v_n,
                            'scope', (select scope from public.test_sessions where id = p_session));
end $$;
revoke all on function public.test_run_scope_to_bot(bigint) from public, anon;
grant execute on function public.test_run_scope_to_bot(bigint) to service_role;

create or replace function public.test_run_start(
  p_kind        text default 'preview',
  p_target_url  text default '',
  p_commit      text default null,
  p_deploy_no   int  default null,
  p_command_id  bigint default null,
  p_triggered_by text default 'vm',
  p_note        text default null,
  p_open_session boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint; v_key uuid; v_sess jsonb; v_sid bigint; v_scope jsonb := '{}'::jsonb;
begin
  perform public._dev_guard();
  if p_open_session then
    v_sess := public.test_session_start('autotest ' || coalesce(p_kind,'preview'), null);
    v_sid  := nullif(v_sess->>'session_id','')::bigint;
    -- Only a session this call opened is narrowed to the bot's logins.
    if v_sid is not null and coalesce((v_sess->>'already')::boolean, false) = false then
      v_scope := public.test_run_scope_to_bot(v_sid);
    end if;
  end if;

  insert into public.test_runs (kind, target_url, git_commit, deploy_no, command_id,
                                test_session_id, triggered_by, note)
  values (coalesce(nullif(p_kind,''),'preview'), coalesce(p_target_url,''), p_commit,
          p_deploy_no, p_command_id, v_sid, coalesce(nullif(p_triggered_by,''),'vm'), p_note)
  returning id, run_key into v_id, v_key;

  return jsonb_build_object('ok', true, 'run_id', v_id, 'run_key', v_key,
                            'test_session_id', v_sid,
                            'scope', v_scope,
                            'session', coalesce(v_sess, '{}'::jsonb));
end $$;
grant execute on function public.test_run_start(text,text,text,int,bigint,text,text,boolean) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 10. THE DISPATCHER LANE — the schedule asks, the VM runs
-- ─────────────────────────────────────────────────────────────────────────
-- The #305 dispatcher executes SQL; Playwright needs a machine. So the
-- dispatcher does not run the bot, it REQUESTS a run, and the VM claims that
-- request on its next pass. One row, claimed with SKIP LOCKED, so two workers
-- can never run the same request twice.
create table if not exists public.test_run_request (
  id           bigserial primary key,
  kind         text        not null default 'prod_smoke',
  args         jsonb       not null default '{}'::jsonb,
  requested_by text        not null default 'dispatcher',
  status       text        not null default 'pending',   -- pending | claimed | done | failed
  run_id       bigint,
  created_at   timestamptz not null default now(),
  claimed_at   timestamptz,
  claimed_by   text,
  finished_at  timestamptz,
  note         text
);
create index if not exists test_run_request_pending_idx
  on public.test_run_request (created_at) where status = 'pending';
alter table public.test_run_request enable row level security;

create or replace function public.test_run_request_add(
  p_kind text default 'prod_smoke', p_args jsonb default '{}'::jsonb,
  p_by text default 'dispatcher')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint;
begin
  perform public._dev_guard();
  -- One waiting request is enough. A dispatcher that fell behind must not
  -- queue six identical smoke runs for the VM to work through.
  select id into v_id from public.test_run_request
   where status = 'pending' and kind = coalesce(nullif(p_kind,''),'prod_smoke') limit 1;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'request_id', v_id);
  end if;
  insert into public.test_run_request (kind, args, requested_by)
  values (coalesce(nullif(p_kind,''),'prod_smoke'), coalesce(p_args,'{}'::jsonb),
          coalesce(nullif(p_by,''),'dispatcher'))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'request_id', v_id);
end $$;

create or replace function public.test_run_request_claim(p_worker text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r public.test_run_request;
begin
  perform public._dev_guard();
  select * into r from public.test_run_request
   where status = 'pending' order by created_at
   for update skip locked limit 1;
  if r.id is null then return jsonb_build_object('ok', true, 'has', false); end if;
  update public.test_run_request
     set status='claimed', claimed_at=now(), claimed_by=coalesce(nullif(p_worker,''),'vm')
   where id = r.id;
  return jsonb_build_object('ok', true, 'has', true, 'request_id', r.id,
                            'kind', r.kind, 'args', r.args);
end $$;

create or replace function public.test_run_request_close(
  p_request bigint, p_status text, p_run_id bigint default null, p_note text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
begin
  perform public._dev_guard();
  update public.test_run_request
     set status = coalesce(nullif(p_status,''),'done'), run_id = p_run_id,
         finished_at = now(), note = p_note
   where id = p_request;
  return jsonb_build_object('ok', true, 'request_id', p_request);
end $$;

revoke all on function public.test_run_request_add(text,jsonb,text) from public, anon;
revoke all on function public.test_run_request_claim(text) from public, anon;
revoke all on function public.test_run_request_close(bigint,text,bigint,text) from public, anon;
grant execute on function public.test_run_request_add(text,jsonb,text) to authenticated, service_role;
grant execute on function public.test_run_request_claim(text) to service_role;
grant execute on function public.test_run_request_close(bigint,text,bigint,text) to service_role;

-- The schedule itself. DISABLED on arrival, deliberately: parts 2-6 write the
-- journeys, and a nightly bot that runs an unfinished library would teach
-- everyone to ignore a red. Enable it with one UPDATE when the library is real.
-- The offset is not a bare */N — a step expression collides on minute 0, which
-- is how the 29-minute connection-exhaustion outage happened.
insert into public.cron_task (name, ord, mode, work_sql, enabled, night_only, note)
values ('autotest_nightly', 900, 'poll',
        $$select public.test_run_request_add('prod_smoke', '{"limit":40}'::jsonb, 'dispatcher')$$,
        false, true,
        'CHANGE #634 — asks the VM for a nightly bot run. The VM claims it with test_run_request_claim(). Enable once the journey library (parts 2-6) is real.')
on conflict (name) do nothing;

-- The Retry button's word. It is the one string the coverage screen needs when
-- the RPC itself failed and there is no payload to print from.
insert into public.ui_copy (key, value)
values ('dev_queue.retry', to_jsonb('Retry'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 11. THE DOOR — Test coverage is a registered dev tool
-- ─────────────────────────────────────────────────────────────────────────
-- #349 made the Dev Queue's tools a REGISTRY, not a row of glyphs: dev_tools()
-- admits what is registered here and the app opens what it has a screen for.
-- Registering the ledger is therefore the whole of its wiring — and because it
-- is a feature, it needs a contract of its own, written here rather than left
-- for the seed above (which has already run by this point in the file).
-- The row shape is #349's, verbatim, and that is not cosmetic: the protected
-- guard dev_tools_registry_test reads every migration for
-- ('<route_key>', <sort>, 'medibo', … 'dev_tools') and asserts that set equals
-- what the build can open. A row written in some other column order would be
-- invisible to it, and a tool nobody can prove is openable is exactly the #349
-- defect that guard exists to retire.
insert into public.feature_registry
  (feature_key, label, description, group_label, icon_key, route_key,
   sort_order, owner, partner_eligible, default_access, is_active, category,
   surface, roles_allowed, deep_link, search_terms, badge_source, badge_noun)
values
  ('devtool.test_coverage','Test coverage',
   'Which features carry a test contract, and what has never been tested',
   'Proof & QA','science',
   'test_coverage',15,'medibo',false,'none',true,'system','dev_tools',
   array['super_admin'],null,'test coverage contract bot autotest never tested',null,null)
on conflict (feature_key) do update
   set label = excluded.label, description = excluded.description,
       group_label = excluded.group_label, icon_key = excluded.icon_key,
       route_key = excluded.route_key, surface = excluded.surface,
       is_active = true;

update public.feature_registry
   set test_entry  = '/admin/go/test_coverage',
       test_roles  = array['super_admin']::text[],
       test_steps  = jsonb_build_array(
         jsonb_build_object('kind','auth','role','super_admin'),
         jsonb_build_object('kind','goto','path','/admin/go/test_coverage'),
         jsonb_build_object('kind','settle','ms', 6000)),
       test_expect = jsonb_build_object('kind','visible','source','render_log',
                                        'key','c325_deep_link','equals','test_coverage'),
       test_automatable = true,
       test_contract_at = now()
 where feature_key = 'devtool.test_coverage';

select public.test_coverage_refresh();
