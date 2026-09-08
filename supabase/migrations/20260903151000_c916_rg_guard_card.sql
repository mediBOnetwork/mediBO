-- CHANGE #916 — the regression guard gets a face.
--
-- Until now the guard had NO surface in the app. Its only way to reach Om was
-- to file an urgent "RG red after #N" command — which is why #751 and #916 both
-- had to be about making that command rarer, and why making it rarer felt like
-- hiding something. It was: with no panel, "no command" and "nothing wrong"
-- looked identical.
--
-- `rg_guard_card()` is the panel, beside the three lanes on Cron health. It
-- renders the verdict, the last runs in order (the churn is the evidence), what
-- the watcher will do about a red, and the guard alerts of the last day. It
-- reads rg_runs / rg_check_cache / rg_alerts only — it NEVER runs rg_check
-- (#647: the guard runs from cron-dispatch and nowhere else), so opening the
-- screen cannot cost the database a catalogue scan.
--
-- Every word, tone, count and timestamp on the card is built here. The Flutter
-- section lays out the payload and decides nothing.

create or replace function public.rg_guard_card(p_runs integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare
  v_last record; v_res text; v_tone text; v_mode text;
  v_streak int; v_confirm int; v_need_persist boolean; v_max_age int;
  v_persist jsonb; v_stable boolean; v_critical int; v_beh_total int; v_beh_red int;
  v_open bigint; v_open_status text;
  v_runs jsonb; v_alerts jsonb; v_decide jsonb;
  v_head_label text; v_head_detail text; v_diffs int;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'The regression guard is visible to super-admins only.');
  end if;

  select r.ran_at, r.ok, r.report into v_last
    from rg_runs r order by r.ran_at desc limit 1;

  if v_last.ran_at is null then
    return jsonb_build_object('ok', true,
      'title', 'Regression guard',
      'subtitle', 'The schema and behaviour guard has not run yet on this database.',
      'mode_label', 'NO RUNS', 'mode_tone', 'neutral', 'window_label', '',
      'headline', jsonb_build_object('tone','neutral',
        'label','No guard run recorded',
        'detail','rg_watch writes a row to rg_runs on every cron dispatch; none exists yet.'),
      'sections', '[]'::jsonb);
  end if;

  v_res := coalesce(v_last.report->>'result',
                    case when v_last.ok then 'green' else 'red' end);
  v_diffs := coalesce((v_last.report->'summary'->>'diffs')::int, 0);
  v_critical := coalesce((v_last.report->'summary'->>'critical')::int, 0);
  select count(*), count(*) filter (where (b.value->>'ok')::boolean is not true)
    into v_beh_total, v_beh_red
    from jsonb_array_elements(coalesce(v_last.report->'behaviors','[]'::jsonb)) b;

  v_mode := upper(v_res);
  v_tone := case v_res when 'green' then 'success'
                       when 'red' then 'error'
                       when 'timeout' then 'warning'
                       else 'neutral' end;

  select coalesce((value->>'confirm_runs')::int, 3),
         coalesce((value->>'require_persistent_diff')::boolean, true),
         coalesce((value->>'max_red_age_s')::int, 3600)
    into v_confirm, v_need_persist, v_max_age
    from dev_runner_config where key = 'rg_watch';
  v_confirm := greatest(coalesce(v_confirm, 3), 1);
  v_need_persist := coalesce(v_need_persist, true);
  v_max_age := greatest(coalesce(v_max_age, 3600), 60);

  v_streak := rg_red_streak();
  v_persist := rg_red_persistence(v_confirm);
  v_stable := (coalesce((v_persist->>'persistent')::int, 0) > 0)
           or coalesce((v_persist->>'has_removal')::boolean, false)
           or not coalesce((v_persist->>'explained')::boolean, false)
           or coalesce((v_persist->>'age_s')::int, 0) >= v_max_age;

  select c.id, c.status into v_open, v_open_status
    from dev_commands c
   where c.title like 'RG red after #%'
     and c.status in ('pending','building','needs_input')
   order by c.id desc limit 1;

  -- ── the headline: one sentence, already decided ──────────────────────────
  if v_res = 'green' then
    v_head_label  := 'Guard green — schema matches the baseline';
    v_head_detail := v_beh_total || ' behaviour test' || case when v_beh_total = 1 then '' else 's' end
                  || ' passing · 0 diffs · last run ' || _ist_age(v_last.ran_at);
  elsif v_res = 'timeout' then
    v_head_label  := 'Guard timed out — this run measured nothing';
    v_head_detail := 'A timeout is neither green nor red: it never becomes the cached verdict and it breaks the red streak.';
  else
    v_head_label  := 'Guard red — ' || v_diffs || ' diff' || case when v_diffs = 1 then '' else 's' end
                  || case when v_beh_red > 0
                          then ' and ' || v_beh_red || ' failing behaviour' || case when v_beh_red = 1 then '' else 's' end
                          else '' end;
    v_head_detail := 'Red for ' || v_streak || ' consecutive run' || case when v_streak = 1 then '' else 's' end
                  || ' · ' || _ist_age(v_last.ran_at);
  end if;

  -- ── recent runs, newest first: the churn is the evidence ─────────────────
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', to_char(x.ran_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
           'detail', case
                       when x.res = 'green' then 'no drift'
                       when x.res = 'timeout' then 'budget hit — nothing measured'
                       else x.d || ' diff' || case when x.d = 1 then '' else 's' end
                            || case when x.cr > 0 then ' · ' || x.cr || ' critical' else '' end
                     end,
           'value_label', upper(x.res),
           'tone', case x.res when 'green' then 'success'
                              when 'timeout' then 'warning'
                              else 'error' end)
         order by x.ran_at desc), '[]')
    into v_runs
  from (select r.ran_at,
               coalesce(r.report->>'result', case when r.ok then 'green' else 'red' end) as res,
               coalesce((r.report->'summary'->>'diffs')::int, 0) as d,
               coalesce((r.report->'summary'->>'critical')::int, 0) as cr
          from rg_runs r
         order by r.ran_at desc
         limit greatest(coalesce(p_runs, 8), 1)) x;

  -- ── what the watcher will do, in its own words ───────────────────────────
  if v_res <> 'red' then
    v_decide := jsonb_build_array(jsonb_build_object(
      'label', 'Nothing to file',
      'detail', 'The watcher only opens a command for a red that holds. Green runs cost nothing.',
      'value_label', 'idle', 'tone', 'success'));
  else
    v_decide := jsonb_build_array(
      jsonb_build_object(
        'label', 'Red streak',
        'detail', 'A schema-only red must survive ' || v_confirm
                  || ' consecutive runs before it costs a worker (CHANGE #751).',
        'value_label', v_streak || ' of ' || v_confirm,
        'tone', case when v_streak >= v_confirm then 'warning' else 'info' end),
      jsonb_build_object(
        'label', 'Is it the same red?',
        'detail', coalesce((v_persist->>'persistent')::int, 0) || ' diff'
                  || case when coalesce((v_persist->>'persistent')::int,0) = 1 then '' else 's' end
                  || ' survived every run of that window · '
                  || coalesce(v_persist->>'diffs_now', '0') || ' on the newest run'
                  || case when coalesce((v_persist->>'has_removal')::boolean,false)
                          then ' · something was REMOVED' else '' end,
        'value_label', case when v_stable then 'holding' else 'churning' end,
        'tone', case when v_stable then 'warning' else 'info' end));

    if v_beh_red > 0 or v_critical > 0 then
      v_decide := v_decide || jsonb_build_array(jsonb_build_object(
        'label', 'Critical signal — files on sight',
        'detail', 'A failing behaviour or a missing critical object is never a runner mid-rebaseline, so it never waits for the streak.',
        'value_label', 'file now', 'tone', 'error'));
    end if;

    if v_open is not null then
      v_decide := v_decide || jsonb_build_array(jsonb_build_object(
        'label', 'Command #' || v_open || ' is already open',
        'detail', 'One RG-red row at a time (CHANGE #641) — a guard that stays red for a day must not file a bug every two hours.',
        'value_label', v_open_status, 'tone', 'info'));
    elsif (v_beh_red > 0 or v_critical > 0) or (v_streak >= v_confirm and v_stable) then
      v_decide := v_decide || jsonb_build_array(jsonb_build_object(
        'label', 'A command will be filed on the next dispatch',
        'detail', 'The confirmation window is satisfied and no RG-red row is open.',
        'value_label', 'filing', 'tone', 'warning'));
    else
      v_decide := v_decide || jsonb_build_array(jsonb_build_object(
        'label', 'No command — this red is still moving',
        'detail', 'Three consecutive reds carrying three unrelated diff sets are three different reds, not one held regression (CHANGE #916). Every diff is still recorded below and in rg_alerts.',
        'value_label', 'suppressed', 'tone', 'info'));
    end if;
  end if;

  -- ── guard alerts of the last day ─────────────────────────────────────────
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', a.name,
           'detail', a.kind || ' · first seen ' || _ist_age(a.first_seen)
                     || ' · last ' || _ist_age(a.last_seen),
           'value_label', a.seen_count || '×',
           'tone', case a.severity when 'critical' then 'error'
                                   when 'error' then 'error'
                                   else 'warning' end)
         order by (a.severity in ('critical','error')) desc, a.last_seen desc), '[]')
    into v_alerts
  from (select * from rg_alerts
         where last_seen >= now() - interval '24 hours'
           and (kind in ('behavior','rg_timeout','rg_red_churn')
                or kind like 'missing\_%')
         order by (severity in ('critical','error')) desc, last_seen desc
         limit 8) a;

  return jsonb_build_object(
    'ok', true,
    'title', 'Regression guard',
    'subtitle', 'One catalogue snapshot plus ' || v_beh_total || ' behaviour tests, run from the cron dispatcher. '
             || 'A diff against the stored baseline is drift until someone decides it was intended.',
    'mode_label', v_mode,
    'mode_tone', v_tone,
    'window_label', _ist_age(v_last.ran_at),
    'headline', jsonb_build_object('tone', v_tone, 'label', v_head_label, 'detail', v_head_detail),
    'sections', jsonb_build_array(
      jsonb_build_object('heading', 'Recent runs', 'rows', v_runs,
        'empty_hint', 'No guard run has been recorded yet.'),
      jsonb_build_object('heading', 'What the watcher will do', 'rows', v_decide,
        'empty_hint', 'The watcher has nothing to decide while the guard is green.'),
      jsonb_build_object('heading', 'Guard alerts · last 24 h', 'rows', v_alerts,
        'empty_hint', 'No failing behaviour, timeout or suppressed red in the last day.')));
end $function$;

grant execute on function public.rg_guard_card(integer) to authenticated, service_role;
