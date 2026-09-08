-- CHANGE #327 — the auto-chain says so on the card.
create or replace function public._dev_chain_chip(p_status text, p_reason text)
returns text language sql immutable set search_path to 'public' as $$
  select case when p_status = 'pending' and coalesce(p_reason,'') <> '' then p_reason else '' end;
$$;

-- dev_cmd_list gains chain_chip / chain_tone / predicted_files.
CREATE OR REPLACE FUNCTION public.dev_cmd_list(p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_batch text DEFAULT NULL::text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_counts jsonb; v_tat numeric; v_stale numeric;
        t_steps text; t_live text; t_stall text; t_resume text;
begin
  perform _dev_guard();
  v_tat := _dev_cmd_base_tat();
  select coalesce((value->>'eta_stale_s')::numeric, 180) into v_stale
    from dev_runner_config where key='worker_pool';
  v_stale := coalesce(v_stale, 180);
  select value#>>'{}' into t_steps  from ui_copy where key='dev_queue.steps_chip';
  select value#>>'{}' into t_live   from ui_copy where key='dev_queue.live_stale';
  select value#>>'{}' into t_stall  from ui_copy where key='dev_queue.stall_chip';
  select value#>>'{}' into t_resume from ui_copy where key='dev_queue.resume_chip';

  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id desc), '[]') into v_rows from (
    select dc.id, _dev_title(dc.title, dc.build_log) as title, dc.status, dc.priority, dc.urgent, dc.depends_on, dc.batch_label,
           dc.route, dc.area,
           _route_label(dc.route) as route_label, _route_tone(dc.route) as route_tone,
           _area_label(dc.area) as area_label,
           (dc.enriched_spec is not null and length(coalesce(dc.enriched_spec,'')) > 0) as has_enriched,
           case when dc.route='fast' and dc.status='completed' then 'Instant · 0 tokens' else '' end as speed_display,
           coalesce(dc.kind,'dev') as kind, coalesce(dc.is_danger,false) as is_danger,
           coalesce(dc.plain_summary,'') as plain_summary,
           dc.targets_web, dc.targets_android, dc.targets_ios,
           dc.web_deploy_no, dc.web_deployed_at, dc.android_status, dc.android_artifact_url, dc.android_built_at, dc.ios_status,
           dc.android_build_type, dc.debug_requested, dc.debug_status,
           dc.result_summary, dc.decisions, dc.screenshots, dc.error_log, dc.retry_count,
           dc.cost_input_tokens, dc.cost_output_tokens, dc.cost_inr, dc.claimed_by, dc.heartbeat_at,
           coalesce(dc.model,'') as model, coalesce(dc.effort,'') as effort, coalesce(dc.price_mode,'') as price_mode,
           _dev_model_chip(dc.model, dc.effort, dc.price_mode) as model_chip,
           case when (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0)
                then ('₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990')) || ' — API-equivalent (included in your Max plan · ₹0 extra)'
                else '' end as cost_note,
           (dc.cost_input_tokens + dc.cost_output_tokens) as tokens_total,
           _fmt_tokens(dc.cost_input_tokens + dc.cost_output_tokens) as tokens_display,
           '₹' || to_char(round(dc.cost_inr), 'FM9,99,99,990') as cost_display,
           (dc.cost_input_tokens > 0 or dc.cost_output_tokens > 0) as has_tokens,
           _ist_age(coalesce(dc.finished_at, dc.started_at, dc.created_at)) as age_display,
           dc.needs_input_question, dc.rolled_back, dc.created_at, dc.started_at, dc.finished_at,
           left(dc.build_log, 4000) as build_log_tail,
           tm.tat_seconds, tm.tat_display, tm.eta_at, tm.elapsed_seconds, tm.elapsed_display,
           tm.remaining_seconds, tm.remaining_display, tm.is_overrun, tm.has_eta, tm.eta_note,
           dc.eta_total_s, dc.eta_left_s,
           case when dc.status in ('completed','failed') then tm.ttt_display else '' end as ttt_display,
           -- ── CHANGE #233: checkpoint + liveness ──────────────────────────
           coalesce(dc.steps, '[]'::jsonb) as steps,
           dc.steps_done, dc.steps_total, dc.resume_count,
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
           case when dc.status='building' and coalesce(dc.token_stall_flagged,false)
                then replace(coalesce(t_stall,'Tokens frozen {age} — build may be stuck'), '{age}',
                       _fmt_dur(coalesce(extract(epoch from now()-dc.token_stall_at), 0)))
                else '' end as stall_chip,
           case when coalesce(dc.resume_count,0) > 0
                then replace(coalesce(t_resume,'Resumed {n}×'), '{n}', dc.resume_count::text)
                else '' end as resume_chip,
           -- ────────────────────────────────────────────────────────────────
           dc.qa_status, dc.qa_required, dc.preview_status, dc.journey_pass_count,
           (select count(*) from qa_findings qf where qf.command_id=dc.id and qf.status='open') as qa_open_findings,
           case when not dc.qa_required or dc.qa_status='waived' then ''
                when dc.qa_status='pending' then ''
                when dc.qa_status='running' then '🔍 QA testing'
                when dc.qa_status='passed' then '✅ QA passed'
                when dc.qa_status='failed' then '❌ QA: '||(select count(*) from qa_findings qf where qf.command_id=dc.id and qf.status='open')||' finding(s)'
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
           coalesce(dc.predicted_files,'{}') as predicted_files,
           case when dc.journey_pass_count > 0
                then '🧭 '||dc.journey_pass_count||' journey'||case when dc.journey_pass_count=1 then '' else 's' end||' green'
                else '' end as journey_chip,
           (select count(*) from dev_command_messages m where m.command_id = dc.id) as msg_count
    from dev_commands dc,
         lateral _dev_cmd_timing(dc.started_at, dc.finished_at, dc.status, v_tat,
                                 dc.eta_total_s, dc.eta_left_s, dc.heartbeat_at, dc.eta_note) tm
    where (p_status is null or dc.status = p_status)
      and (p_batch is null or dc.batch_label = p_batch)
      and (p_search is null or dc.title ilike '%'||p_search||'%' or dc.spec ilike '%'||p_search||'%' or coalesce(dc.result_summary,'') ilike '%'||p_search||'%')
    order by dc.created_at desc, dc.id desc limit p_limit
  ) t;
  select coalesce(jsonb_object_agg(status, n), '{}') into v_counts from (select status, count(*) n from dev_commands group by status) c;
  return jsonb_build_object('rows', v_rows, 'counts', v_counts, 'screen_title', 'Dev Queue');
end $function$

;
