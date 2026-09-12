-- CHANGE #1856 (part 2) — the COST on the card.
--
-- A hold and a cold resume are the same event to anyone reading the queue
-- today: the command "waited". They are not the same cost. A hold is free; a
-- cold resume re-reads a whole context, which is how #1848 reached 9.7M tokens.
-- So the card carries both counts and one backend-worded sentence, and the
-- waiting banner learns the third state (`holding`) that part 1 introduced.
--
-- Every string here is ui_copy, defaulted in place: nothing is worded in Dart.
-- =============================================================================

insert into ui_copy (key, value) values
  ('dev_queue.hold_chip',        to_jsonb('⏸ {reason} · held {age} · session alive'::text)),
  ('dev_queue.hold_hint',        to_jsonb('Not a failure and not a restart — the session is being kept alive, so it resumes with no context re-read.'::text)),
  ('dev_queue.wait_hold_msg',    to_jsonb('⏸ Holding — {reason}. The session is kept alive and idles until the blocker clears, so it resumes with NO context re-read (checked every {after}s).'::text)),
  ('dev_queue.wait_msg',         to_jsonb('⏸ Parked (COLD resume #{cold}) — {reason}. The work is committed and untouched; it resumes automatically when the blocker clears (checked every {after}s), but the next session re-reads the whole context.'::text)),
  ('dev_queue.resume_cost_line', to_jsonb('Waiting cost — {holds} hold(s) kept this session alive · {colds} cold resume{s} re-read the whole context'::text))
on conflict (key) do update set value = excluded.value;

-- The card whitelist. A key that is not named here never reaches the app.
create or replace function public._dev_card_keys()
returns text[] language sql immutable as $fn$
  select array[
    'id','title','status','kind','area','area_label','batch_label','priority',
    'urgent','is_danger','effort','route','route_label','route_tone',
    'claimed_by','model','model_chip','model_label','effort_label','retry_count',
    'created_at','started_at','finished_at','heartbeat_at','eta_at',
    'age_display','elapsed_display','remaining_display','tat_display',
    'ttt_display','speed_display','tokens_display','cost_display','cost_note',
    'has_eta','has_tokens','is_live','is_waiting','is_overrun','msg_count',
    'steps_done','steps_total','steps_chip','steps_stale_chip','steps_stale_hint',
    'spec_chip','spec_tone','spec_open','spec_total',
    'qa_chip','qa_tone','qa_status','qa_required','qa_open_findings',
    'journey_chip','preview_chip','preview_tone','preview_status',
    'chain_chip','chain_tone','finish_chip','finish_tone',
    'wait_chip','wait_tone','wait_kind','wait_reason','wait_hint','wait_state',
    -- CHANGE #1856 — a hold and a cold resume cost differently, so they count
    -- separately and the card says so in the backend's own sentence.
    'hold_count','cold_resume_count','hold_total_s','resume_cost_line','resume_cost_tone',
    'live_chip','stall_chip','resume_chip','debug_status','debug_requested',
    'size_class','qa_scope','diff_files','diff_rows','grade_chip','grade_tone','grade_reason',
    'auto_finished','auto_finish_source','rolled_back',
    'agent_chip','agent_tone','agent_rc_session','session_lost_count','started_flags',
    'web_deploy_no','android_status','ios_status',
    'targets_web','targets_android','targets_ios'
  ]::text[];
$fn$;

CREATE OR REPLACE FUNCTION public._dev_cmd_rows(p_status text, p_search text, p_batch text, p_limit integer, p_slim boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
declare
  v_rows jsonb; v_tat numeric; v_stale numeric;
  v_models jsonb; v_efforts jsonb;
  t_steps text; t_live text; t_stall text; t_resume text; t_ssteps text; t_shint text;
  t_fready text; t_fauto text; t_wait text; t_whint text; t_spec text;
  t_hold text; t_hhint text; t_cost text;   -- CHANGE #1856
begin
  -- CHANGE #1092 — an empty string is NOT a search. It used to reach the
  -- filter as '' and match every row through the coalesce branch, which is
  -- both wrong and unindexable.
  p_status := nullif(p_status, '');
  p_search := nullif(p_search, '');
  p_batch  := nullif(p_batch,  '');

  v_tat := _dev_cmd_base_tat();
  -- one config read for the whole page, not four or five per row
  v_models  := _dev_label_map('models');
  v_efforts := _dev_label_map('efforts');
  select coalesce((value->>'eta_stale_s')::numeric, 180) into v_stale
    from dev_runner_config where key='worker_pool';
  v_stale := coalesce(v_stale, 180);
  select value#>>'{}' into t_steps  from ui_copy where key='dev_queue.steps_chip';
  select value#>>'{}' into t_live   from ui_copy where key='dev_queue.live_stale';
  select value#>>'{}' into t_stall  from ui_copy where key='dev_queue.stall_chip';
  select value#>>'{}' into t_resume from ui_copy where key='dev_queue.resume_chip';
  select value#>>'{}' into t_ssteps from ui_copy where key='dev_queue.steps_stale_chip';
  select value#>>'{}' into t_shint  from ui_copy where key='dev_queue.steps_stale_hint';
  t_fready := _c_or('dev_queue.finish_ready_chip', '✅ All conditions met — closing automatically');
  t_fauto  := _c_or('dev_queue.finish_auto_chip',  '🤖 Auto-completed by the harness · {drift} after the last step');
  t_wait   := _c_or('dev_queue.wait_chip',  '⏸ {reason} · waiting {age}');
  t_whint  := _c_or('dev_queue.wait_hint',  'Not a failure — the work is committed and resumes automatically when the blocker clears.');
  t_spec   := _c_or('dev_queue.spec_chip',  'Spec {done}/{total}');
  -- CHANGE #1856 — a HELD command is waiting too, but nothing was torn down.
  t_hold   := _c_or('dev_queue.hold_chip',  '⏸ {reason} · held {age} · session alive');
  t_hhint  := _c_or('dev_queue.hold_hint',  'Not a failure and not a restart — the session is being kept alive, so it resumes with no context re-read.');
  t_cost   := _c_or('dev_queue.resume_cost_line',
                    'Waiting cost — {holds} hold(s) kept this session alive · {colds} cold resume{s} re-read the whole context');

  with pick as (
    -- THE CEILING. One index-ordered walk, p_limit rows, nothing else touched.
    -- CHANGE #1092: the result_summary branch lost its coalesce so all three
    -- OR branches are trigram-indexable and the planner can BitmapOr them.
    -- `NULL ilike '%x%'` is NULL, i.e. not true — the same rows the coalesce
    -- kept, now that an empty search can no longer reach here.
    select dc.id
      from dev_commands dc
     where (p_status is null or dc.status = p_status)
       and (p_batch  is null or dc.batch_label = p_batch)
       and (p_search is null
            or dc.title          ilike '%'||p_search||'%'
            or dc.spec           ilike '%'||p_search||'%'
            or dc.result_summary ilike '%'||p_search||'%')
     order by dc.created_at desc, dc.id desc
     limit greatest(coalesce(p_limit, 120), 1)
  ),
  spec_agg as (
    select si.command_id,
           count(*)::int                                     as total,
           count(*) filter (where si.status = 'open')::int    as open_n
      from dev_command_spec_item si
      join pick p on p.id = si.command_id
     group by si.command_id
  ),
  qa_agg as (
    select qf.command_id,
           count(*) filter (where qf.status = 'open')::int    as open_n
      from qa_findings qf
      join pick p on p.id = qf.command_id
     group by qf.command_id
  ),
  msg_agg as (
    select m.command_id, count(*)::int as n
      from dev_command_messages m
      join pick p on p.id = m.command_id
     group by m.command_id
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id desc), '[]')
    into v_rows
  from (
    select dc.id,
           -- #887: materialised on write. Was a regexp over the whole build_log.
           coalesce(dc.title_display, dc.title) as title,
           dc.status, dc.priority, dc.urgent, dc.depends_on, dc.batch_label,
           dc.route, dc.area,
           _route_label(dc.route) as route_label, _route_tone(dc.route) as route_tone,
           _area_label(dc.area) as area_label,
           (dc.enriched_spec is not null and length(coalesce(dc.enriched_spec,'')) > 0) as has_enriched,
           case when dc.route='fast' and dc.status='completed' then 'Instant · 0 tokens' else '' end as speed_display,
           coalesce(dc.kind,'dev') as kind, coalesce(dc.is_danger,false) as is_danger,
           case when p_slim then left(coalesce(dc.plain_summary,''), 200)
                else coalesce(dc.plain_summary,'') end as plain_summary,
           dc.targets_web, dc.targets_android, dc.targets_ios,
           dc.web_deploy_no, dc.web_deployed_at, dc.android_status, dc.android_artifact_url,
           dc.android_built_at, dc.ios_status,
           dc.android_build_type, dc.debug_requested, dc.debug_status,
           -- #887: the cards view drops every one of these in _dev_card_strip,
           -- so the slim build never reads them off disk in the first place.
           case when p_slim then null::text  else dc.result_summary end as result_summary,
           case when p_slim then null::jsonb else dc.decisions      end as decisions,
           case when p_slim then null::jsonb else dc.screenshots    end as screenshots,
           case when p_slim then null::text  else dc.error_log      end as error_log,
           dc.retry_count,
           dc.cost_input_tokens, dc.cost_output_tokens, dc.cost_inr, dc.claimed_by, dc.heartbeat_at,
           coalesce(dc.model,'') as model, coalesce(dc.effort,'') as effort,
           coalesce(dc.price_mode,'') as price_mode,
           _dev_model_chip_m(v_models, v_efforts, dc.model, dc.effort, dc.price_mode,
                             dc.actual_model, dc.actual_effort) as model_chip,
           coalesce(dc.actual_model,'') as actual_model,
           coalesce(dc.actual_effort,'') as actual_effort,
           _dev_model_label_m(v_models, dc.model)   as model_label,
           _dev_effort_label_m(v_efforts, dc.effort) as effort_label,
           case when (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0)
                then ('₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990')) || ' — API-equivalent (included in your Max plan · ₹0 extra)'
                else '' end as cost_note,
           (dc.cost_input_tokens + dc.cost_output_tokens) as tokens_total,
           _fmt_tokens(dc.cost_input_tokens + dc.cost_output_tokens) as tokens_display,
           '₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990') as cost_display,
           (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0) as has_tokens,
           _ist_age(coalesce(dc.finished_at, dc.started_at, dc.created_at)) as age_display,
           dc.needs_input_question, dc.rolled_back, dc.created_at, dc.started_at, dc.finished_at,
           case when p_slim then null::text else left(dc.build_log, 4000) end as build_log_tail,
           tm.tat_seconds, tm.tat_display, tm.eta_at, tm.elapsed_seconds, tm.elapsed_display,
           tm.remaining_seconds, tm.remaining_display, tm.is_overrun, tm.has_eta, tm.eta_note,
           dc.eta_total_s, dc.eta_left_s,
           case when dc.status in ('completed','failed') then tm.ttt_display else '' end as ttt_display,
           case when p_slim then null::jsonb else coalesce(dc.steps, '[]'::jsonb) end as steps,
           dc.steps_done, dc.steps_total, dc.resume_count,
           -- CHANGE #1674 — the GRADE, on the card. Om could not see whether a
           -- command bought a hostile QA pass it did not need.
           coalesce(dc.size_class,'') as size_class,
           coalesce(dc.qa_scope,'')   as qa_scope,
           coalesce(dc.diff_files, 0) as diff_files,
           coalesce(dc.diff_rows, 0)  as diff_rows,
           coalesce(dc.grade_reason,'') as grade_reason,
           public._dev_grade_chip(dc.size_class, dc.qa_scope,
             case coalesce(dc.qa_scope,'standard') when 'deep' then 3 else 1 end) as grade_chip,
           case coalesce(dc.size_class,'')
                when 'xlarge' then 'warning'
                when 'small'  then 'success'
                else 'info' end as grade_tone,
           coalesce(dc.resume_branch,'') as resume_branch,
           coalesce(dc.release_reason,'') as release_reason,
           case when coalesce(dc.steps_total,0) > 0
                then replace(replace(coalesce(t_steps,'Step {done} of {total}'),
                       '{done}', coalesce(dc.steps_done,0)::text), '{total}', dc.steps_total::text)
                else '' end as steps_chip,
           (dc.status='building' and dc.heartbeat_at is not null
              and dc.heartbeat_at > now() - (v_stale || ' seconds')::interval) as is_live,
           case when dc.status='building'
                 and (dc.heartbeat_at is null
                      or dc.heartbeat_at <= now() - (v_stale || ' seconds')::interval)
                then replace(coalesce(t_live,'Worker offline — no heartbeat for {age}'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.heartbeat_at), 0)))
                else '' end as live_chip,
           -- ── CHANGE #1023 — the AGENT's liveness, not the runner's ──────────
           -- live_chip above says the heartbeat stopped. This says the beat is
           -- fine and the Claude session behind it is not — the exact state
           -- #1016 sat in for 32 minutes with nothing on the card to show it.
           dev_cmd_agent_chip(dc.status, dc.agent_silent_flagged, dc.agent_silent_at, dc.agent_pane_alive) as agent_chip,
           case when dc.status='building' and coalesce(dc.agent_silent_flagged,false)
                then case when dc.agent_pane_alive is false then 'error' else 'warning' end
                else 'neutral' end as agent_tone,
           coalesce(dc.agent_rc_session,'') as agent_rc_session,
           coalesce(dc.session_lost_count,0) as session_lost_count,
           coalesce(dc.started_flags,'') as started_flags,
           case when dc.status='building' and coalesce(dc.token_stall_flagged,false)
                then replace(coalesce(t_stall,'Tokens frozen {age} — build may be stuck'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.token_stall_at), 0)))
                else '' end as stall_chip,
           case when dc.status='building' and coalesce(dc.steps_stale_flagged,false)
                then replace(coalesce(t_ssteps,'Steps not being reported — checklist may be stale ({age})'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.steps_stale_at), 0)))
                else '' end as steps_stale_chip,
           case when dc.status='building' and coalesce(dc.steps_stale_flagged,false)
                then coalesce(t_shint,'') else '' end as steps_stale_hint,
           coalesce(dc.steps_auto_count,0) as steps_auto_count,
           coalesce(dc.steps_nudge_count,0) as steps_nudge_count,
           case when coalesce(dc.resume_count,0) > 0
                then replace(coalesce(t_resume,'Resumed {n}×'), '{n}', dc.resume_count::text)
                else '' end as resume_chip,
           -- ── CHANGE #571: WAITING IS NOT FAILING, and the card says which ──
           coalesce(dc.wait_state,'')  as wait_state,
           coalesce(dc.wait_kind,'')   as wait_kind,
           coalesce(dc.wait_reason,'') as wait_reason,
           case when p_slim then null::jsonb
                else coalesce(dc.wait_blocker,'{}'::jsonb) end as wait_blocker,
           dc.wait_since, coalesce(dc.wait_count,0) as wait_count,
           -- CHANGE #1856 — HOLDING is a waiting state too. It is not a
           -- failure and it is not a restart: the session is still there.
           (dc.wait_state in ('parked','holding')) as is_waiting,
           case when dc.wait_state = 'parked'
                then replace(replace(t_wait, '{reason}', coalesce(dc.wait_reason,'')),
                       '{age}', _fmt_dur(coalesce(extract(epoch from now()-dc.wait_since), 0)))
                when dc.wait_state = 'holding'
                then replace(replace(t_hold, '{reason}', coalesce(dc.wait_reason,'')),
                       '{age}', _fmt_dur(coalesce(extract(epoch from now()-dc.wait_since), 0)))
                else '' end as wait_chip,
           case when dc.wait_state = 'parked'  then 'warning'
                when dc.wait_state = 'holding' then 'info'
                else 'neutral' end as wait_tone,
           case when dc.wait_state = 'parked'  then t_whint
                when dc.wait_state = 'holding' then t_hhint
                else '' end as wait_hint,
           -- ── CHANGE #1856 — what the waiting actually COST this command ──
           coalesce(dc.hold_count,0)        as hold_count,
           coalesce(dc.cold_resume_count,0) as cold_resume_count,
           coalesce(dc.hold_total_s,0)      as hold_total_s,
           case when coalesce(dc.hold_count,0) + coalesce(dc.cold_resume_count,0) = 0 then ''
                else replace(replace(replace(t_cost,
                       '{holds}', coalesce(dc.hold_count,0)::text),
                       '{colds}', coalesce(dc.cold_resume_count,0)::text),
                       '{s}', case when coalesce(dc.cold_resume_count,0) = 1 then '' else 's' end)
           end as resume_cost_line,
           case when coalesce(dc.cold_resume_count,0) > 0 then 'warning'
                when coalesce(dc.hold_count,0) > 0        then 'success'
                else 'neutral' end as resume_cost_tone,
           -- ── CHANGE #571 spec checklist — #887: set-based, was 8 subqueries ──
           coalesce(sa.total, 0)  as spec_total,
           coalesce(sa.open_n, 0) as spec_open,
           case when coalesce(sa.total,0) = 0 then ''
                else replace(replace(t_spec,
                       '{done}', (coalesce(sa.total,0) - coalesce(sa.open_n,0))::text),
                       '{total}', coalesce(sa.total,0)::text) end as spec_chip,
           case when dc.status = 'building' and coalesce(sa.open_n,0) > 0 then 'warning'
                when coalesce(sa.total,0) > 0 and coalesce(sa.open_n,0) = 0 then 'success'
                else 'neutral' end as spec_tone,
           -- ── CHANGE #369: the finish gate, on the card ────────────────────
           case when dc.status='completed' and coalesce(dc.auto_finished,false)
                then replace(t_fauto, '{drift}',
                       _fmt_dur(greatest(coalesce(extract(epoch from dc.finished_at - dc.steps_snap_at), 0), 0)))
                when dc.status='building' and dc.finish_ready_at is not null then t_fready
                else '' end as finish_chip,
           case when dc.status='completed' and dc.steps_snap_at is not null
                then round(extract(epoch from dc.finished_at - dc.steps_snap_at))::int
                else null end as finish_drift_s,
           case when dc.status='completed' and dc.steps_snap_tokens is not null
                then greatest((dc.cost_input_tokens + dc.cost_output_tokens) - dc.steps_snap_tokens, 0)
                else null end as finish_tokens_after,
           case when dc.status='completed' and coalesce(dc.auto_finished,false) then 'success'
                when dc.status='building' and dc.finish_ready_at is not null then 'info'
                else 'neutral' end as finish_tone,
           coalesce(dc.auto_finished,false) as auto_finished,
           coalesce(dc.auto_finish_source,'') as auto_finish_source,
           case when p_slim then null::jsonb
                else coalesce(dc.finish_blockers,'[]'::jsonb) end as finish_blockers,
           dc.finish_ready_at,
           dc.qa_status, dc.qa_required, dc.preview_status, dc.journey_pass_count,
           coalesce(qa.open_n, 0) as qa_open_findings,
           case when not dc.qa_required or dc.qa_status='waived' then ''
                when dc.qa_status='pending' then ''
                when dc.qa_status='running' then '🔍 QA testing'
                when dc.qa_status='passed' then '✅ QA passed'
                when dc.qa_status='failed' then '❌ QA: '||coalesce(qa.open_n,0)||' finding(s)'
                else '' end as qa_chip,
           case when dc.qa_status='waived' then 'neutral'
                when dc.qa_status='running' then 'info'
                when dc.qa_status='passed' then 'success'
                when dc.qa_status='failed' then 'error' else 'neutral' end as qa_tone,
           case coalesce(dc.preview_status,'')
                when 'deployed' then '🔎 On preview'
                when 'promoted' then '🚀 Promoted' else '' end as preview_chip,
           case coalesce(dc.preview_status,'')
                when 'deployed' then 'info' when 'promoted' then 'success' else 'neutral' end as preview_tone,
           _dev_chain_chip(dc.status, dc.chain_reason) as chain_chip,
           'info'::text as chain_tone,
           case when p_slim then null::text[] else coalesce(dc.predicted_files,'{}') end as predicted_files,
           case when dc.journey_pass_count > 0
                then '🧭 '||dc.journey_pass_count||' journey'||case when dc.journey_pass_count=1 then '' else 's' end||' green'
                else '' end as journey_chip,
           coalesce(ma.n, 0) as msg_count
      from pick pk
      join dev_commands dc on dc.id = pk.id
      left join spec_agg sa on sa.command_id = dc.id
      left join qa_agg   qa on qa.command_id = dc.id
      left join msg_agg  ma on ma.command_id = dc.id,
      lateral _dev_cmd_timing(dc.started_at, dc.finished_at, dc.status, v_tat,
                              dc.eta_total_s, dc.eta_left_s, dc.heartbeat_at, dc.eta_note) tm
  ) t;

  return coalesce(v_rows, '[]'::jsonb);
end
$fn$

;
