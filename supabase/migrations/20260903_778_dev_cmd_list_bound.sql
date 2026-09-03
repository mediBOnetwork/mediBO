-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #778 — bound dev_cmd_list.
--
-- The runner breaker tripped with 11 DB timeouts in five minutes and named
-- this call 39 times. Measured before the fix, on 370 dev_commands rows:
--
--   dev_cmd_list(...)        cold  42,211 ms   warm 1,098 ms
--   dev_cmd_list_full(...)          765 ms, returning 3,569,343 bytes
--
-- Two faults, and the first is the one that made it unbounded:
--
-- 1. `dev_cmd_list` declares `p_limit integer DEFAULT NULL` and hands it
--    straight to `dev_cmd_list_full`, whose own DEFAULT 100 is therefore never
--    applied — the app calls it with no limit, NULL reaches `limit p_limit`,
--    and in SQL `LIMIT NULL` means NO LIMIT. Every call built every row that
--    has ever existed. The wrapper then trimmed the result to a 48 kB card
--    budget, so 3.5 MB was assembled and 98.7% of it discarded.
--
-- 2. `qa_findings` had no index on command_id, and the row builder runs two
--    correlated counts against it. explain (analyze, buffers) on that slice:
--
--      SubPlan 2
--        ->  Aggregate (actual time=0.051..0.051 rows=1 loops=370)
--              ->  Seq Scan on qa_findings qf_1  (loops=370)
--                    Rows Removed by Filter: 318
--                    Buffers: shared hit=9250
--
--    370 loops × a full scan of the table, twice, for two numbers.
--
-- The fix is a ceiling and an index. Nothing about what the screen SHOWS
-- changes: the card view already truncated to 48 kB and told the caller so.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. The index the correlated counts were missing ───────────────────────
create index if not exists qa_findings_command_idx
  on public.qa_findings (command_id);

-- The open-findings count is the one on the hot path (it drives the QA chip),
-- so it gets its own partial index the way dev_command_spec_item already has.
create index if not exists qa_findings_open_idx
  on public.qa_findings (command_id) where status = 'open';

-- ── 2. The list's own ORDER BY ────────────────────────────────────────────
-- `order by created_at desc, id desc limit N` had no index to walk; with the
-- ceiling in place this turns the sort of the whole table into a top-N read.
create index if not exists dev_commands_created_idx
  on public.dev_commands (created_at desc, id desc);

analyze public.qa_findings;
analyze public.dev_commands;

-- ── 3. The ceiling. NULL must never reach `limit`. ────────────────────────
--
-- The number is config, not a literal, so tuning the page size is a pool_set()
-- and not a deploy. `dev_cmd_list_full` keeps its own DEFAULT 100 for direct
-- callers; what changes is that a NULL passed INTO it is now the default too,
-- rather than "every row".
insert into public.dev_runner_config (key, value)
values ('list_limits', jsonb_build_object(
  'cards_default', 120,   -- the card view trims to a 48 kB budget anyway
  'full_default',  100,
  'max',           500))
on conflict (key) do update
  set value = public.dev_runner_config.value || excluded.value;

create or replace function public._dev_list_limit(p_limit integer, p_key text default 'cards_default')
returns integer
language sql stable security definer set search_path to 'public'
as $$
  with c as (
    select coalesce((select value from dev_runner_config where key='list_limits'),
                    '{}'::jsonb) v
  )
  select least(
           greatest(
             coalesce(nullif(p_limit, 0),
                      (select coalesce((v->>p_key)::int, 120) from c)),
             1),
           (select coalesce((v->>'max')::int, 500) from c))
$$;

-- ── 4. What it bought (measured on this instance, 370 dev_commands rows) ──
--
--                                  before          after
--   dev_cmd_list  cold           42,211 ms        802 ms
--   dev_cmd_list  warm            1,098 ms    371-463 ms
--   dev_cmd_list  status filter          —      14.2 ms
--   dev_cmd_list  search 'supplier'      —       230 ms
--   dev_cmd_list  delta (10 min)         —      98.2 ms
--   dev_cmd_list_full payload      3,569,343 b   844,805 b
--
-- The card payload is UNCHANGED — 46,781 bytes, 32 rows, truncated:true both
-- before and after — because the 48 kB budget was always the real page size.
-- All that changed is how many rows were built to fill it.
--
-- The qa_findings slice, before:
--
--   SubPlan 2
--     ->  Aggregate (actual time=0.051..0.051 rows=1 loops=370)
--           ->  Seq Scan on qa_findings qf_1  (loops=370)
--                 Rows Removed by Filter: 318
--                 Buffers: shared hit=9250
--
-- and after, with the ceiling and the index:
--
--   Limit (actual time=15.476..16.050 rows=60 loops=1)
--     ->  Index Only Scan using dev_commands_created_idx on dev_commands dc
--           ->  Aggregate (actual time=0.003..0.003 rows=1 loops=60)
--                 ->  Index Only Scan using qa_findings_open_idx on qa_findings
--                       Index Cond: (command_id = dc.id)
--                       Buffers: shared hit=75
--
-- 18,500 buffer hits for two counts became 149.
--
-- Not done, deliberately: `left(dc.build_log, 4000)` is computed for every row
-- and then dropped by _dev_card_strip, because build_log_tail is not a card
-- key. Measured at 4.4 ms of the ~400 ms (233 buffers vs 61), so removing it
-- would need a signature change on a function other callers share to buy 1%.
-- Recorded here so the next person measures instead of guessing.


-- ── 5. The two functions, with the ceiling applied ────────────────────────
-- Bodies are otherwise untouched: the only edits are `limit p_limit` ->
-- `limit public._dev_list_limit(...)` in the full builder, and the call site
-- in the wrapper passing a resolved limit instead of the NULL it received.

CREATE OR REPLACE FUNCTION public.dev_cmd_list_full(p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_batch text DEFAULT NULL::text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_counts jsonb; v_tat numeric; v_stale numeric;
        t_steps text; t_live text; t_stall text; t_resume text; t_ssteps text; t_shint text;
        t_fready text; t_fauto text; t_wait text; t_whint text; t_spec text;
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
  select value#>>'{}' into t_ssteps from ui_copy where key='dev_queue.steps_stale_chip';
  select value#>>'{}' into t_shint  from ui_copy where key='dev_queue.steps_stale_hint';
  t_fready := _c_or('dev_queue.finish_ready_chip', '✅ All conditions met — closing automatically');
  t_fauto  := _c_or('dev_queue.finish_auto_chip',  '🤖 Auto-completed by the harness · {drift} after the last step');
  t_wait   := _c_or('dev_queue.wait_chip',  '⏸ {reason} · waiting {age}');
  t_whint  := _c_or('dev_queue.wait_hint',  'Not a failure — the work is committed and resumes automatically when the blocker clears.');
  t_spec   := _c_or('dev_queue.spec_chip',  'Spec {done}/{total}');

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
           _dev_model_chip(dc.model, dc.effort, dc.price_mode, dc.actual_model, dc.actual_effort) as model_chip,
           coalesce(dc.actual_model,'') as actual_model,
           coalesce(dc.actual_effort,'') as actual_effort,
           _dev_model_label(dc.model) as model_label,
           _dev_effort_label(dc.effort) as effort_label,
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
           coalesce(dc.wait_blocker,'{}'::jsonb) as wait_blocker,
           dc.wait_since, coalesce(dc.wait_count,0) as wait_count,
           (dc.wait_state = 'parked') as is_waiting,
           case when dc.wait_state = 'parked'
                then replace(replace(t_wait, '{reason}', coalesce(dc.wait_reason,'')),
                       '{age}', _fmt_dur(coalesce(extract(epoch from now()-dc.wait_since), 0)))
                else '' end as wait_chip,
           case when dc.wait_state = 'parked' then 'warning' else 'neutral' end as wait_tone,
           case when dc.wait_state = 'parked' then t_whint else '' end as wait_hint,
           -- ── CHANGE #571: the command's own spec checklist ────────────────
           (select count(*) from dev_command_spec_item si where si.command_id = dc.id) as spec_total,
           (select count(*) from dev_command_spec_item si where si.command_id = dc.id and si.status='open') as spec_open,
           case when (select count(*) from dev_command_spec_item si where si.command_id = dc.id) = 0 then ''
                else replace(replace(t_spec,
                       '{done}', (select count(*) from dev_command_spec_item si
                                   where si.command_id = dc.id and si.status <> 'open')::text),
                       '{total}', (select count(*) from dev_command_spec_item si
                                    where si.command_id = dc.id)::text) end as spec_chip,
           case when dc.status = 'building'
                 and (select count(*) from dev_command_spec_item si
                       where si.command_id = dc.id and si.status='open') > 0 then 'warning'
                when (select count(*) from dev_command_spec_item si where si.command_id = dc.id) > 0
                 and (select count(*) from dev_command_spec_item si
                       where si.command_id = dc.id and si.status='open') = 0 then 'success'
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
           coalesce(dc.finish_blockers,'[]'::jsonb) as finish_blockers,
           dc.finish_ready_at,
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
    order by dc.created_at desc, dc.id desc limit public._dev_list_limit(p_limit, 'full_default')
  ) t;
  select coalesce(jsonb_object_agg(status, n), '{}') into v_counts from (select status, count(*) n from dev_commands group by status) c;
  return jsonb_build_object('rows', v_rows, 'counts', v_counts, 'screen_title', 'Dev Queue');
end $function$

;

CREATE OR REPLACE FUNCTION public.dev_cmd_list(p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_batch text DEFAULT NULL::text, p_limit integer DEFAULT NULL::integer, p_view text DEFAULT NULL::text, p_updated_since timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  j jsonb; v_rows jsonb; v_kept jsonb := '[]'::jsonb;
  v_view text := lower(coalesce(nullif(p_view,''),'cards'));
  v_budget int := 48000;   -- rows only; the envelope (counts, chips, meta) rides
                           -- on top and the WHOLE payload must stay under 50 kB
  v_used int := 0; v_row jsonb; v_len int; v_total int; v_trunc boolean := false;
begin
  -- CHANGE #778 — the ceiling. p_limit arrives NULL from the app and used to
  -- reach `limit NULL`, which is SQL for no limit at all; the card budget
  -- below then threw away 98% of what that built.
  j := public.dev_cmd_list_full(p_status, p_search, p_batch,
         public._dev_list_limit(p_limit, case when v_view = 'full'
                                             then 'full_default' else 'cards_default' end));
  if v_view = 'full' then
    return j || jsonb_build_object('view','full','server_time', now());
  end if;

  select coalesce(jsonb_agg(public._dev_card_strip(t.r) order by t.ord), '[]'::jsonb)
    into v_rows
  from jsonb_array_elements(coalesce(j->'rows','[]'::jsonb)) with ordinality t(r, ord)
  where p_updated_since is null
     or greatest(
          coalesce((t.r->>'heartbeat_at')::timestamptz, '-infinity'::timestamptz),
          coalesce((t.r->>'finished_at')::timestamptz,  '-infinity'::timestamptz),
          coalesce((t.r->>'started_at')::timestamptz,   '-infinity'::timestamptz),
          coalesce((t.r->>'created_at')::timestamptz,   '-infinity'::timestamptz)
        ) > p_updated_since;

  v_total := jsonb_array_length(v_rows);

  -- Fill to the budget in payload order, then stop. Rows are already ordered by
  -- the list's own ranking, so a truncated page is the TOP of the list, never a
  -- random slice — and the caller is told to ask for a smaller page.
  for v_row in select value from jsonb_array_elements(v_rows)
  loop
    v_len := octet_length(v_row::text) + 1;
    if v_used + v_len > v_budget then
      v_trunc := true;
      exit;
    end if;
    v_kept := v_kept || jsonb_build_array(v_row);
    v_used := v_used + v_len;
  end loop;

  return jsonb_set(j, '{rows}', v_kept)
         || jsonb_build_object(
              'view','cards',
              'is_delta', (p_updated_since is not null),
              'updated_since', p_updated_since,
              'row_count', jsonb_array_length(v_kept),
              'truncated', v_trunc,
              'dropped_rows', v_total - jsonb_array_length(v_kept),
              'budget_bytes', v_budget,
              'server_time', now());
end $function$

;

-- A new SECURITY DEFINER function inherits Postgres's default GRANT TO PUBLIC,
-- and the anon key ships in the web bundle and the APK. This one only returns a
-- number, but the house rule is the house rule (#436).
revoke all on function public._dev_list_limit(integer, text) from public, anon;
grant execute on function public._dev_list_limit(integer, text) to authenticated, service_role;
