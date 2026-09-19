-- CMD #2105 — A FUNCTION SETTING THAT NO MIGRATION OWNS WILL BE LOST, AND THE
-- NEXT REBASELINE WILL BLESS THE LOSS.
--
-- The bug: public.rg_collect_payloads() carried `SET statement_timeout = 15000`
-- (CHANGE #191) so that a slow payload target comes back as a NAMED
-- query_canceled collection error instead of aborting the whole guard run.
-- On 2026-09-19 its proconfig read {search_path=public} on production AND on
-- the build branch — the SET was gone, and journey bug-191 failed its first
-- structural assert (v_a1), which is why the weekly mutation audit recorded it
-- as NOT EXERCISED: a red baseline cannot be said to have missed its break.
--
-- The root cause is not "somebody typed the wrong ALTER". It is that NO
-- migration in supabase/migrations/ ever declared that setting. The function
-- had only ever been applied by hand, so:
--   * a re-CREATE without the SET silently dropped it,
--   * rg_collect fingerprints functions with md5(pg_get_functiondef(...)),
--     which DOES include the SET — so the guard saw the change as a diff,
--   * and the diff was cleared by a rebaseline, which blessed the stripped
--     definition as the new truth. Nothing was left to put it back.
--
-- The fix is therefore three things, not one:
--   1. restore the SET,
--   2. make a MIGRATION own it, so every replay restores it forever,
--   3. declare the requirement as DATA and give it a permanent journey
--      (bug-2105) plus a regression-guard behaviour, so the next setting that
--      goes missing is caught on the day it goes missing instead of being
--      blessed away.
--
-- Idempotent throughout: create-if-not-exists, create-or-replace, upsert.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. RESTORE THE SETTING (the bug itself)
--    Guarded on existence: this file replays on a database where the function
--    may not exist yet, and a guard must never be the thing that throws.
-- ─────────────────────────────────────────────────────────────────────────────
do $c2105$
begin
  if to_regprocedure('public.rg_collect_payloads()') is not null then
    execute 'alter function public.rg_collect_payloads() set statement_timeout = 15000';
  end if;
end $c2105$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE REQUIREMENT IS DATA, NOT A BRANCH IN A FUNCTION
--    A new function setting that must never be lost is ONE INSERT here — never
--    a deploy, and never another hand-applied ALTER that nothing remembers.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.rg_function_setting (
  fn         text        not null,   -- identity args form: public.f(int,text)
  setting    text        not null,   -- the GUC name, e.g. statement_timeout
  value      text        not null,   -- the value proconfig must carry
  note       text        not null default '',
  owned_by   text        not null default '',  -- the migration file that applies it
  enabled    boolean     not null default true,
  created_at timestamptz not null default now(),
  primary key (fn, setting)
);

alter table public.rg_function_setting enable row level security;

comment on table public.rg_function_setting is
  'CMD #2105 — function settings (pg_proc.proconfig) that are part of a '
  'contract and must survive every re-create. Declared as rows so the guard, '
  'the journey and the repair all read the SAME list. A row here is only true '
  'if a migration named in owned_by actually applies it.';

insert into public.rg_function_setting (fn, setting, value, note, owned_by) values
  ('public.rg_collect_payloads()', 'statement_timeout', '15000',
   'CHANGE #191 — without it a slow payload target aborts the whole guard run '
   'instead of coming back as a named query_canceled collection error.',
   '20260924120000_cmd2105_function_settings_owned.sql')
on conflict (fn, setting) do update
  set value = excluded.value,
      note = excluded.note,
      owned_by = excluded.owned_by,
      enabled = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE REPORTER — one place that answers "is every declared setting still on
--    the function?", in the backend's own words.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.rg_function_settings_report()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $c2105$
declare
  r          record;
  v_oid      oid;
  v_cfg      text[];
  v_want     text;
  v_viol     jsonb := '[]'::jsonb;
  v_checked  int := 0;
begin
  for r in select * from public.rg_function_setting where enabled order by fn, setting loop
    v_checked := v_checked + 1;
    v_want := r.setting || '=' || r.value;
    -- to_regprocedure returns NULL for an absent function; the ::regprocedure
    -- cast RAISES, and a guard that throws on the database that needs it is
    -- the failure mode lesson 263 already paid for.
    v_oid := to_regprocedure(r.fn);
    if v_oid is null then
      v_viol := v_viol || jsonb_build_object(
        'fn', r.fn, 'setting', r.setting, 'want', r.value, 'found', null,
        'why', 'function does not exist on this database');
      continue;
    end if;
    select p.proconfig into v_cfg from pg_proc p where p.oid = v_oid;
    if v_cfg is null or not (v_want = any(v_cfg)) then
      v_viol := v_viol || jsonb_build_object(
        'fn', r.fn, 'setting', r.setting, 'want', r.value,
        'found', coalesce(array_to_string(v_cfg, ', '), ''),
        'why', 'proconfig does not carry ' || v_want ||
               ' — re-run the migration that owns it (' || coalesce(nullif(r.owned_by,''),'unowned') || ')');
    end if;
  end loop;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_viol) = 0,
    'checked', v_checked,
    'violations', v_viol,
    'label', case when jsonb_array_length(v_viol) = 0
                  then v_checked || ' declared function setting(s) intact'
                  else jsonb_array_length(v_viol) || ' of ' || v_checked ||
                       ' declared function setting(s) MISSING' end);
end $c2105$;

revoke all on function public.rg_function_settings_report() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE PERMANENT JOURNEY — bug-2105.
--    No branch is added to the 37 KB dev_journey_probe: CMD #1851 gave it a
--    by-convention hook it consults FIRST, so a journey named bug-2105 is
--    answered by a function named _journey_bug_2105().
--
--    Four asserts, and the last one is a real reproduction: strip the setting
--    inside a subtransaction, prove the reporter catches it, roll back.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._journey_bug_2105()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c2105$
declare
  v_a1 boolean;   -- the requirement is declared, and a migration file owns it
  v_a2 boolean;   -- every declared setting is present on this database
  v_a3 boolean;   -- the regression guard carries the check, and it is enabled
  v_a4 boolean;   -- a stripped setting is CAUGHT by the reporter
  v_a5 boolean;   -- ...and the guard behaviour itself goes red on it
  v_rep  jsonb;
  v_bad  jsonb;
  v_body text;
  v_ok   boolean;
  v_err  text;
begin
  -- a1 — the contract exists as data AND a migration file claims it. An
  -- unowned requirement is exactly the bug: nothing puts it back.
  select exists (
    select 1 from public.rg_function_setting
     where enabled and fn = 'public.rg_collect_payloads()'
       and setting = 'statement_timeout' and coalesce(owned_by,'') <> ''
  ) into v_a1;

  -- a2 — every declared setting is on its function right now.
  v_rep := public.rg_function_settings_report();
  v_a2  := coalesce((v_rep->>'ok')::boolean, false);

  -- a3 — the half of the bug that let it survive for weeks: rg_collect DOES
  -- fingerprint the setting (md5(pg_get_functiondef)), the guard DID see the
  -- stripped definition, and a rebaseline blessed it as the new truth. A
  -- behaviour test is the one part of rg_check a rebaseline cannot silence, so
  -- the protection lives THERE, not in the baseline.
  select exists (
    select 1 from public.rg_behavior_tests
     where name = 'c2105_declared_function_settings_intact' and enabled
  ) into v_a3;

  -- a4/a5 — REPRODUCTION. Strip the setting for real, prove both the reporter
  -- and the guard behaviour catch it, then leave by the exception door so the
  -- DDL is rolled back. Variables are not transactional, so the verdict
  -- escapes the rollback (the same door mutation_trial uses).
  begin
    execute 'alter function public.rg_collect_payloads() reset statement_timeout';

    v_bad := public.rg_function_settings_report();
    v_a4 := not coalesce((v_bad->>'ok')::boolean, true)
        and exists (select 1 from jsonb_array_elements(coalesce(v_bad->'violations','[]'::jsonb)) e
                     where e->>'fn' = 'public.rg_collect_payloads()');

    select body into v_body from public.rg_behavior_tests
     where name = 'c2105_declared_function_settings_intact' and enabled;
    if v_body is null then
      v_a5 := false;
    else
      begin
        execute v_body;
        v_a5 := false;   -- a body that returns without raising proves nothing
      exception when others then
        -- RG_ROLLBACK means the guard passed while the setting was MISSING.
        v_a5 := (sqlerrm <> 'RG_ROLLBACK');
      end;
    end if;

    raise exception using errcode = 'J2105', message = 'planned rollback';
  exception
    when sqlstate 'J2105' then null;
    when others then
      v_err := sqlerrm;
      v_a4  := null;
      v_a5  := null;
  end;

  -- The rollback above restores the SET. Say so out loud rather than assume it.
  v_rep := public.rg_function_settings_report();

  v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
      and coalesce(v_a4,false) and coalesce(v_a5,false)
      and coalesce((v_rep->>'ok')::boolean, false);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object(
      'db_proof',
        'declared and owned by a migration=' || coalesce(v_a1,false)::text ||
        ' | every declared setting present=' || coalesce(v_a2,false)::text ||
        ' | rg_check carries the behaviour=' || coalesce(v_a3,false)::text ||
        ' | stripping it is caught by the reporter=' || coalesce(v_a4,false)::text ||
        ' | and turns the guard behaviour red=' || coalesce(v_a5,false)::text ||
        ' | setting restored after the probe=' || coalesce((v_rep->>'ok')::boolean,false)::text ||
        ' | ' || coalesce(v_rep->>'label','') ||
        coalesce(' | probe error: ' || v_err, ''),
      'report', v_rep,
      'caught_when_stripped', v_bad));
end $c2105$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. AND THE REGRESSION GUARD ITSELF GOES RED ON DRIFT.
--    The journey runs with its area's commands; rg_check runs on a schedule and
--    before every deploy. Both read the same declared list. Every behaviour
--    body must end by raising RG_ROLLBACK — that is how rg_run_behaviors knows
--    the body ran to completion and reverted.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values (
  'c2105_declared_function_settings_intact',
  $body$
do $rgb$
declare v jsonb;
begin
  v := public.rg_function_settings_report();
  if not coalesce((v->>'ok')::boolean, false) then
    raise exception 'c2105: %', coalesce(v->>'label','declared function settings missing');
  end if;
  raise exception 'RG_ROLLBACK';
end $rgb$;
  $body$,
  true,
  'CMD #2105 — every setting declared in rg_function_setting is still on its '
  'function. rg_collect_payloads lost SET statement_timeout with nothing to '
  'put it back, and a rebaseline blessed the loss.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;
