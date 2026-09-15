-- CHANGE #916 — the regression guard stops filing commands for a red that is
-- still moving, and finally gets a face of its own.
--
-- WHY. #751 made a schema-only red wait for `rg_watch.confirm_runs` (3)
-- consecutive red runs before it filed an urgent "RG red after #N" command,
-- because a runner's intentional DDL is drift until that same runner
-- rebaselines it. It was the right idea measured in the wrong unit. #916 was
-- filed after exactly three consecutive reds — and those three reds were three
-- DIFFERENT reds:
--
--   run 1791  14:08  20 diffs   (#712 customer-event triggers/functions)
--   run 1798  14:15  28 diffs   (#712 again, plus indexes/policies/payload)
--   run 1817  14:18   5 diffs   (#707 fulfilment journeys — none of the above)
--   ...filed here...
--   run 1824  14:19  10 diffs   (#707 + #705 KYC journeys)
--   run 1831  14:20  10 diffs
--   run 1838  14:21   0 diffs   green — a rebaseline landed at 14:20:25
--
-- Not one object was present in all three runs of the confirmation window, and
-- nothing was ever REMOVED. That is not a regression holding; that is a fleet
-- mid-build, and it healed itself two minutes after it cost an Opus worker.
-- Nine such commands have been filed (#699 #749 #750 #751 #752 #788 #803 #857
-- #902) and most concluded "intentional, already rebaselined".
--
-- WHAT CHANGES. A schema-only red now has to be the SAME red: at least one
-- diff must survive every run of the confirmation window. A red whose diff set
-- churns is drift in motion and files nothing. Three escape hatches keep this
-- from ever hiding a real regression:
--   * a critical (failing behaviour / missing_critical) still files on sight,
--     exactly as #751 left it — untouched below;
--   * a REMOVED object files immediately: a dropped function, column, index,
--     policy or trigger is never a runner mid-rebaseline;
--   * `max_red_age_s` (1 h) files regardless of churn, so a guard that simply
--     will not settle still reaches Om.
-- Every red is still written to rg_runs and still raises its rg_alerts rows.
-- This delays the COMMAND; it hides nothing — and #916 also gives the guard a
-- visible surface (`rg_guard_card`, on Cron health) so a suppressed red is
-- something Om can SEE rather than something he is not told.

-- ── 1. the knobs ────────────────────────────────────────────────────────────
insert into dev_runner_config (key, value)
values ('rg_watch', jsonb_build_object(
  'confirm_runs', 3,
  'require_persistent_diff', true,
  'max_red_age_s', 3600,
  'note', 'Consecutive red rg runs required before rg_watch files an urgent "RG red" command. '
       || 'CHANGE #916: a schema-only red must also be the SAME red — at least one diff present '
       || 'in every run of that window (require_persistent_diff). A churning diff set is a fleet '
       || 'mid-build, not a regression. A failing behaviour, a missing_critical or any REMOVED '
       || 'object still files on the first run, and a red older than max_red_age_s files whatever '
       || 'its diffs are doing.'))
on conflict (key) do update
  set value = dev_runner_config.value
            || jsonb_build_object(
                 'require_persistent_diff',
                   coalesce(dev_runner_config.value->'require_persistent_diff', 'true'::jsonb),
                 'max_red_age_s',
                   coalesce(dev_runner_config.value->'max_red_age_s', '3600'::jsonb),
                 'note', excluded.value->>'note');

-- ── 2. is this the same red, or a moving one? ──────────────────────────────
-- Returns the shape of the CURRENT unbroken red streak: how long it has stood,
-- and which diffs (if any) have survived every run of the confirmation window.
-- `persistent` is the number of such diffs; `has_removal` is the carve-out for
-- a dropped object; `sample` names up to eight of them for the card and the
-- command body. A leading run that is not red makes the whole thing empty.
create or replace function public.rg_red_persistence(p_runs integer default 3)
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $function$
  with recent as (
    select r.ran_at, r.report,
           coalesce(r.report->>'result', case when r.ok then 'green' else 'red' end) as res,
           row_number() over (order by r.ran_at desc) as rn
      from rg_runs r
     order by r.ran_at desc
     limit greatest(coalesce(p_runs, 3) * 4, 24)
  ),
  -- the leading unbroken red streak; a green or a timeout ends it, exactly as
  -- rg_red_streak() counts it.
  streak as (
    select * from recent
     where rn <= coalesce((select min(rn) - 1 from recent where res <> 'red'),
                          (select count(*) from recent))
       and res = 'red'
  ),
  win as (select * from streak where rn <= greatest(coalesce(p_runs, 3), 1)),
  sigs as (
    select w.rn,
           d.key || '|' || t.typ || '|' || n.nm as sig,
           t.typ as typ
      from win w,
           lateral jsonb_each(coalesce(w.report->'diffs', '{}'::jsonb)) d,
           lateral (values ('added'), ('removed'), ('changed')) t(typ),
           lateral jsonb_array_elements_text(coalesce(d.value->t.typ, '[]'::jsonb)) n(nm)
  ),
  -- a diff that was present in EVERY run of the window: the red is standing
  -- still, which is what "held for N runs" was always supposed to mean.
  persist as (
    select sig from sigs
     group by sig
    having count(distinct rn) = (select count(*) from win)
  )
  select jsonb_build_object(
    'runs',        (select count(*) from win),
    'age_s',       coalesce((select round(extract(epoch from now() - min(ran_at)))::int
                               from streak), 0),
    'diffs_now',   (select count(*) from sigs where rn = 1),
    'persistent',  (select count(*) from persist),
    -- a red we cannot explain with diffs (0 diffs on the newest run) is never
    -- suppressed: only a red we can fully account for as schema churn is.
    'explained',   (select count(*) from sigs where rn = 1) > 0,
    'has_removal', exists (select 1 from sigs where rn = 1 and typ = 'removed'),
    'sample',      coalesce((select jsonb_agg(s.sig order by s.sig)
                               from (select sig from persist order by sig limit 8) s),
                            '[]'::jsonb)
  );
$function$;

revoke all on function public.rg_red_persistence(integer) from public, anon, authenticated;

-- ── 3. the gate ─────────────────────────────────────────────────────────────
create or replace function public.rg_watch()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare
  r jsonb; rec record; fp text; v_res text; v_change int; v_open bigint; v_new bigint;
  v_confirm int; v_streak int; v_critical boolean;
  v_persist jsonb; v_stable boolean; v_need_persist boolean; v_max_age int; v_file boolean;
  v_why text;
begin
  r := rg_check(true, true);
  v_res := coalesce(r->>'result', case when coalesce((r->>'ok')::boolean,false) then 'green' else 'red' end);

  -- A busy short-circuit measured nothing: record nothing, decide nothing.
  if v_res = 'busy' then
    return jsonb_build_object('ok', r->'ok', 'result', 'busy', 'at', now());
  end if;

  insert into rg_runs(ok, report) values ((r->>'ok')::boolean, r);
  delete from rg_runs where ran_at < now() - interval '30 days';

  -- The verdict every cheap reader (dev_cmd_complete_fast, the Dev Queue card)
  -- shows. A timeout is not a measurement and must never become the cached one.
  if v_res <> 'timeout' then
    insert into rg_check_cache (ok, result) values (coalesce((r->>'ok')::boolean,false), r);
    delete from rg_check_cache where at < now() - interval '2 days';
  else
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (md5('rg_timeout|' || to_char(date_trunc('hour', now()),'YYYY-MM-DD HH24')),
            'warn', 'rg_timeout',
            format('rg_check hit its %ss budget at %s', coalesce(r->>'budget_s','90'),
                   coalesce(r->>'stopped_at','?')),
            jsonb_build_object('elapsed_s', r->'elapsed_s', 'stopped_at', r->'stopped_at'))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end if;

  for rec in select value as v from jsonb_array_elements(r->'overload_risks') loop
    fp := md5('overload|'||(rec.v->>'fn')||'|'||(rec.v->>'a')||'|'||(rec.v->>'b'));
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, rec.v->>'severity', 'overload', rec.v->>'fn', rec.v)
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;
  for rec in select value as v from jsonb_array_elements(r->'missing_critical') loop
    fp := md5('missing|'||(rec.v->>'kind')||'|'||(rec.v->>'name'));
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, 'critical', 'missing_'||(rec.v->>'kind'), rec.v->>'name', rec.v)
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;
  for rec in select value as v from jsonb_array_elements(r->'behaviors') where ((value->>'ok')::boolean) is not true loop
    fp := md5('behavior|'||(rec.v->>'name'));
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, 'critical', 'behavior', rec.v->>'name', rec.v)
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;
  for rec in
    select d.key as k2, t.typ, n.nm
    from jsonb_each(r->'diffs') d,
         lateral (values ('added'),('removed'),('changed')) t(typ),
         lateral jsonb_array_elements_text(d.value->t.typ) n(nm)
  loop
    fp := md5('diff|'||rec.k2||'|'||rec.typ||'|'||rec.nm);
    insert into rg_alerts(fingerprint, severity, kind, name, detail)
    values (fp, 'warn', 'diff_'||rec.k2, rec.nm, jsonb_build_object('type', rec.typ))
    on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
  end loop;

  -- RED IS A COMMAND, NOT A BLOCKER (#641). One open row at a time: a guard
  -- that stays red for a day must not file a bug every two hours.
  -- RED IS CONFIRMED BEFORE IT COSTS A WORKER (#751). The guard runs every
  -- minute; a runner's intentional DDL is drift until that same runner
  -- rebaselines it seconds later. A red made only of schema diffs must survive
  -- rg_watch.confirm_runs consecutive red runs. A red carrying a critical — a
  -- failing behaviour or a missing_critical — files on first sight, because
  -- that is never someone mid-rebaseline. Every red is still written to
  -- rg_runs and still raises its rg_alerts rows: this delays the COMMAND, it
  -- hides nothing.
  -- AND IT MUST BE THE SAME RED (#916). Three consecutive reds carrying three
  -- unrelated diff sets are three different reds; #916 was filed by exactly
  -- that and healed itself two minutes later. So the window must also hold at
  -- least one diff in common. A removal, a critical, or a red older than
  -- max_red_age_s bypasses that and files anyway.
  if v_res = 'red' then
    v_critical := coalesce(jsonb_array_length(r->'missing_critical'), 0) > 0
               or exists (select 1 from jsonb_array_elements(r->'behaviors') b
                           where ((b.value->>'ok')::boolean) is not true);
    select coalesce((value->>'confirm_runs')::int, 3),
           coalesce((value->>'require_persistent_diff')::boolean, true),
           coalesce((value->>'max_red_age_s')::int, 3600)
      into v_confirm, v_need_persist, v_max_age
      from dev_runner_config where key = 'rg_watch';
    v_confirm := greatest(coalesce(v_confirm, 3), 1);
    v_need_persist := coalesce(v_need_persist, true);
    v_max_age := greatest(coalesce(v_max_age, 3600), 60);
    v_streak := rg_red_streak();

    -- Is the red standing still? Only asked once the streak is long enough —
    -- below that nothing files anyway and this is a scan we can skip.
    v_stable := true;
    if v_streak >= v_confirm and v_need_persist and not v_critical then
      v_persist := rg_red_persistence(v_confirm);
      v_stable := (coalesce((v_persist->>'persistent')::int, 0) > 0)
               or (coalesce((v_persist->>'has_removal')::boolean, false))
               or (not coalesce((v_persist->>'explained')::boolean, false))
               or (coalesce((v_persist->>'age_s')::int, 0) >= v_max_age);
      if not v_stable then
        v_why := format(
          'RG red held %s run(s) but no diff survived the whole window (%s on the newest run, 0 persistent) — a fleet mid-build, not a regression. No command filed.',
          v_streak, coalesce(v_persist->>'diffs_now', '?'));
        insert into rg_alerts(fingerprint, severity, kind, name, detail)
        values (md5('rg_red_churn|' || to_char(date_trunc('hour', now()),'YYYY-MM-DD HH24')),
                'warn', 'rg_red_churn', v_why,
                jsonb_build_object('streak', v_streak, 'persistence', v_persist))
        on conflict (fingerprint) do update set last_seen = now(), seen_count = rg_alerts.seen_count + 1;
      end if;
    end if;

    v_file := v_critical or (v_streak >= v_confirm and v_stable);

    if v_file then
      select d.change_no into v_change from deploy_registry d
       where d.deployed_at is not null order by d.deployed_at desc limit 1;
      select c.id into v_open from dev_commands c
       where c.title like 'RG red after #%' and c.status in ('pending','building','needs_input')
       order by c.id desc limit 1;
      if v_open is null then
        insert into dev_commands (title, spec, urgent, priority, kind, qa_required, targets_web)
        values ('RG red after #' || coalesce(v_change::text, '?'),
                'The regression guard went red on the scheduled run after change #'
                || coalesce(v_change::text, '?') || E'.\n\n'
                || 'Read the newest rg_runs row (select report from rg_runs order by ran_at desc limit 1) '
                || 'and the open rg_alerts. For each diff decide: an INTENTIONAL change gets rebaselined '
                || '(devcmd.sh rebaseline), an UNINTENTIONAL one gets fixed in the code. Behaviour '
                || 'failures and missing_critical are never rebaselined — fix them. Finish with '
                || 'devcmd.sh rgcheck printing true.' || E'\n\n'
                || 'Summary at the time it was filed: ' || coalesce(r->>'summary','{}')
                || E'\n' || 'Red held for ' || v_streak || ' consecutive run(s)'
                || case when v_critical then '; a critical signal filed it on sight.' else '.' end
                || case when v_persist is not null
                        then E'\n' || 'Diffs that survived the whole confirmation window: '
                             || coalesce(v_persist->>'sample', '[]')
                        else '' end,
                true, 1, 'dev', false, false)
        returning id into v_new;
      end if;
    end if;
  end if;

  begin
    perform rg_probe_edges();
  exception when others then null;
  end;
  return jsonb_build_object('ok', r->'ok', 'result', v_res, 'summary', r->'summary',
    'red_streak', v_streak, 'red_critical', v_critical, 'confirm_runs', v_confirm,
    'red_persistence', v_persist, 'red_stable', v_stable, 'filed', coalesce(v_file, false),
    'bug_command', v_new, 'at', now());
end $function$;

revoke all on function public.rg_watch() from public, anon, authenticated, service_role;
