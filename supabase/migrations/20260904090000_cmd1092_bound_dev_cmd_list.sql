-- CHANGE #1092 — Bound dev_cmd_list.
--
-- The runner breaker tripped naming dev_cmd_list as the worst offender: 13
-- statement cancellations in five minutes. Profiling on the live schema found
-- three separate problems, and only one of them was the rows the caller asked
-- for.
--
--   1. THE `full` VIEW HAD NO BUDGET AT ALL. #778/#887 bounded the cards view
--      (60 rows, 48 kB) and left `p_view='full'` untouched: it returns
--      result_summary, decisions, screenshots, error_log, 4 kB of build_log,
--      steps, wait_blocker, finish_blockers and predicted_files for up to
--      list_limits.max = 500 rows, with no byte cap.
--        measured: dev_cmd_list(null,null,null,500,'full')
--                  = 4 404 949 bytes, 8 007 buffers, 385 ms.
--      `dev_cmd_list_full()` is the same shape behind a second RPC name.
--
--   2. MORE THAN HALF OF AN ORDINARY CARDS POLL WAS FIXED OVERHEAD — work that
--      does not change when you ask for fewer rows:
--        _dev_cmd_base_tat()   166 buffers  (seq scan + sort of dev_commands
--                                            on EVERY call, for a median of 25
--                                            durations)
--        counts group-by       213 buffers  (index-only scan whose 217 heap
--                                            fetches came from a stale
--                                            visibility map)
--        match_count           a SECOND pass over the same table for a number
--                              the histogram above already contains.
--      The Dev Queue screen polls this every 5 s per open tab, and every
--      worker's finish_detect/boot_doctor polls it too.
--
--   3. THE SEARCH PATH COULD NOT USE ITS OWN INDEXES. dev_commands already had
--      GIN trigram indexes on title and spec, but the third OR branch was
--      `coalesce(result_summary,'') ilike ...` — a coalesce over an unindexed
--      column, which forces a seq scan and detoasts spec + result_summary for
--      every row (1 069 buffers on 405 rows, and it grows with the table).
--
-- Everything below is data or plan shape: no payload key is removed, and the
-- cards view returns byte-identical rows.

-- ── 1. The indexes the call was missing ─────────────────────────────────────

-- _dev_cmd_base_tat(): "the last 25 completed commands, by id desc". A partial
-- index carrying the two timestamps turns its seq-scan-and-sort into an
-- index-only scan that stops after it has 25.
create index if not exists dev_commands_tat_idx
  on public.dev_commands (id desc)
  include (started_at, finished_at)
  where status = 'completed' and finished_at > started_at;

-- The status histogram is computed on every single call. It was riding
-- idx_dev_commands_claim (status, urgent, priority, id) — four columns wide,
-- with a heap fetch per row. One narrow index answers it index-only.
create index if not exists dev_commands_status_idx
  on public.dev_commands (status);

-- The third search branch, so the OR can become a BitmapOr of three trigram
-- index scans instead of a full detoasting scan.
create index if not exists idx_dev_commands_trgm_result
  on public.dev_commands using gin (result_summary gin_trgm_ops);

-- ── 2. The ceilings, as data ────────────────────────────────────────────────
-- full_max/full_budget_bytes are new; cards_max/cards_default keep their
-- current values. Tunable with ui/pool config, never a deploy.
insert into public.dev_runner_config (key, value)
values ('list_limits', jsonb_build_object(
          'max', 500, 'cards_max', 60, 'cards_default', 120,
          'full_default', 40, 'full_max', 40,
          'cards_budget_bytes', 48000, 'full_budget_bytes', 300000))
on conflict (key) do update
  set value = dev_runner_config.value
              || jsonb_build_object('full_default', 40, 'full_max', 40,
                                    'cards_budget_bytes', 48000,
                                    'full_budget_bytes', 300000);

-- ── 3. The row builder: a search that an index can serve ────────────────────
create or replace function public._dev_cmd_rows(
  p_status text, p_search text, p_batch text, p_limit integer,
  p_slim boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows jsonb; v_tat numeric; v_stale numeric;
  v_models jsonb; v_efforts jsonb;
  t_steps text; t_live text; t_stall text; t_resume text; t_ssteps text; t_shint text;
  t_fready text; t_fauto text; t_wait text; t_whint text; t_spec text;
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
           (dc.wait_state = 'parked') as is_waiting,
           case when dc.wait_state = 'parked'
                then replace(replace(t_wait, '{reason}', coalesce(dc.wait_reason,'')),
                       '{age}', _fmt_dur(coalesce(extract(epoch from now()-dc.wait_since), 0)))
                else '' end as wait_chip,
           case when dc.wait_state = 'parked' then 'warning' else 'neutral' end as wait_tone,
           case when dc.wait_state = 'parked' then t_whint else '' end as wait_hint,
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
$function$;

-- ── 4. dev_cmd_list — ONE bounded path, both views ──────────────────────────
create or replace function public.dev_cmd_list(
  p_status text default null,
  p_search text default null,
  p_batch text default null,
  p_limit integer default null,
  p_view text default null,
  p_updated_since timestamp with time zone default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cfg     jsonb;
  v_view    text := lower(coalesce(nullif(p_view,''),'cards'));
  v_full    boolean;
  v_ask     int; v_ceiling int; v_budget int;
  v_counts  jsonb; v_raw jsonb; v_kept jsonb := '[]'::jsonb; v_arr jsonb[] := '{}';
  v_used    int := 0; v_len int; v_built int; v_row jsonb; v_card jsonb;
  v_trunc   boolean := false;
  v_matched int; v_note text := '';
begin
  perform _dev_guard();

  -- CHANGE #1092 — normalise once, here, so an empty string can never reach
  -- the row filter and defeat the trigram indexes underneath it.
  p_status := nullif(p_status, '');
  p_search := nullif(p_search, '');
  p_batch  := nullif(p_batch,  '');
  v_full   := (v_view = 'full');

  select coalesce(value, '{}'::jsonb) into v_cfg
    from dev_runner_config where key = 'list_limits';
  v_cfg := coalesce(v_cfg, '{}'::jsonb);

  -- CHANGE #778 — the ceiling. p_limit arrives NULL from the app and used to
  -- reach `limit NULL`, which is SQL for no limit at all.
  -- CHANGE #887 — and the ceiling BINDS: a caller asking for 500 was buying
  -- 440 rows of TOAST reads it was always going to discard.
  -- CHANGE #1092 — the `full` view gets both, for the first time. It was the
  -- one path with no byte cap: 500 rows × build_log/decisions/screenshots came
  -- to 4.4 MB and 8 007 buffers on an HTTP request.
  v_ask := public._dev_list_limit(p_limit,
             case when v_full then 'full_default' else 'cards_default' end);

  v_ceiling := greatest(least(v_ask,
                 case when v_full then coalesce((v_cfg->>'full_max')::int, 40)
                      else coalesce((v_cfg->>'cards_max')::int, 60) end), 1);

  v_budget := greatest(
                case when v_full
                     then coalesce((v_cfg->>'full_budget_bytes')::int, 300000)
                     else coalesce((v_cfg->>'cards_budget_bytes')::int, 48000) end,
                8000);

  -- ONE histogram scan per call. Below, it also answers "how many match"
  -- without a second pass over the table.
  select coalesce(jsonb_object_agg(status, n), '{}') into v_counts
    from (select status, count(*) n from dev_commands group by status) c;

  v_raw   := public._dev_cmd_rows(p_status, p_search, p_batch, v_ceiling, not v_full);
  v_built := jsonb_array_length(v_raw);

  -- Fill to the budget in payload order, then stop. Rows are already ordered by
  -- the list's own ranking, so a truncated page is the TOP of the list, never a
  -- random slice — and the caller is told there is more.
  -- CHANGE #887: strip INSIDE the loop, so a row over the budget is never
  -- stripped at all.
  for v_row in select value from jsonb_array_elements(v_raw)
  loop
    if p_updated_since is not null
       and greatest(
             coalesce((v_row->>'heartbeat_at')::timestamptz, '-infinity'::timestamptz),
             coalesce((v_row->>'finished_at')::timestamptz,  '-infinity'::timestamptz),
             coalesce((v_row->>'started_at')::timestamptz,   '-infinity'::timestamptz),
             coalesce((v_row->>'created_at')::timestamptz,   '-infinity'::timestamptz)
           ) <= p_updated_since then
      continue;
    end if;
    v_card := case when v_full then v_row else public._dev_card_strip(v_row) end;
    v_len  := octet_length(v_card::text) + 1;
    if v_used + v_len > v_budget then
      v_trunc := true;
      exit;
    end if;
    v_arr := v_arr || v_card;
    v_used := v_used + v_len;
  end loop;

  select coalesce(jsonb_agg(x order by o), '[]'::jsonb) into v_kept
    from unnest(v_arr) with ordinality u(x, o);

  -- How many rows actually match. CHANGE #1092: when nothing narrows the set —
  -- which is every poll the app makes — the histogram above already holds the
  -- answer, so the honesty line costs zero extra reads. A search or a batch
  -- filter still counts, still bounded at 5 000.
  if p_search is null and p_batch is null then
    if p_status is null then
      select coalesce(sum(v::int), 0) into v_matched
        from jsonb_each_text(v_counts) e(k, v);
    else
      v_matched := coalesce((v_counts->>p_status)::int, 0);
    end if;
  else
    select count(*) into v_matched from (
      select 1 from dev_commands dc
       where (p_status is null or dc.status = p_status)
         and (p_batch  is null or dc.batch_label = p_batch)
         and (p_search is null
              or dc.title          ilike '%'||p_search||'%'
              or dc.spec           ilike '%'||p_search||'%'
              or dc.result_summary ilike '%'||p_search||'%')
       limit 5000) x;
  end if;

  if jsonb_array_length(v_kept) < v_matched and p_updated_since is null then
    v_note := replace(replace(
      _c_or('dev_queue.list_truncated',
            'Showing the newest {shown} of {total} — filter or search to see the rest.'),
      '{shown}', jsonb_array_length(v_kept)::text),
      '{total}', v_matched::text);
  end if;

  return jsonb_build_object(
           'rows', v_kept,
           'counts', v_counts,
           'screen_title', 'Dev Queue',
           'view', case when v_full then 'full' else 'cards' end,
           'is_delta', (p_updated_since is not null),
           'updated_since', p_updated_since,
           'row_count', jsonb_array_length(v_kept),
           'truncated', v_trunc or (p_updated_since is null
                                     and jsonb_array_length(v_kept) < v_matched),
           'truncated_note', v_note,
           'dropped_rows', v_built - jsonb_array_length(v_kept),
           'row_ceiling', v_ceiling,
           'match_count', v_matched,
           'budget_bytes', v_budget,
           'server_time', now());
end
$function$;

-- ── 5. dev_cmd_list_full — the same shape behind a second name ──────────────
-- It had no ceiling and no budget either. It is now one line: the bounded path.
create or replace function public.dev_cmd_list_full(
  p_status text default null,
  p_search text default null,
  p_batch text default null,
  p_limit integer default 100)
returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  select public.dev_cmd_list(p_status, p_search, p_batch, p_limit, 'full', null);
$function$;
