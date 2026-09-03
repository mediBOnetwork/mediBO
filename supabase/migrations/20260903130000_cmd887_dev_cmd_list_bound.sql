-- CHANGE #887 — dev_cmd_list: bound it.
--
-- The runner breaker named dev_cmd_list as the worst offender: 15 cancelled
-- calls in five minutes. Measured before this migration, on the exact call the
-- runner watch loop makes every poll:
--
--   dev_cmd_list('completed', null, null, 500)  ->  808-963 ms, 10,884 shared
--   dev_cmd_list(null,        null, null, null) ->  309 ms,      6,036 shared
--
-- 384 rows in the table. Nothing here was a "big table" problem; three separate
-- unbounded shapes were:
--
-- 1. THE TITLE DETOASTED THE WHOLE LOG. `_dev_title(dc.title, dc.build_log)`
--    runs a regexp over the ENTIRE build_log for every row of every page.
--    build_log averages 105 kB and peaks at 246 kB; the column holds 39 MB
--    across the 384 rows. A 286-row `completed` page therefore decompressed
--    ~30 MB of TOAST to keep one line of text. Slicing the input is NOT a fix:
--    the "claimed #N:" line sits as far as 153 kB into the log (95th percentile
--    46 kB), so a prefix scan returns a DIFFERENT title. Derive it once, on the
--    write that produces it, and store it: title_display + a BEFORE trigger.
--    Read side is coalesce(title_display, title), which is _dev_title exactly.
--
-- 2. ELEVEN CORRELATED SUBQUERIES PER ROW. spec_total/spec_open/spec_chip/
--    spec_tone re-counted dev_command_spec_item eight times per row, qa_chip +
--    qa_open_findings hit qa_findings twice, msg_count once. Resolved set-based
--    in three CTEs joined to the bounded id list — the scalar-helper-scan
--    anti-pattern, one row at a time.
--
-- 3. THE CARDS VIEW BUILT WHAT IT THREW AWAY. dev_cmd_list asks for the FULL
--    row (build_log_tail, result_summary, error_log, decisions, screenshots,
--    steps, predicted_files...), then _dev_card_strip keeps only the ~80 card
--    keys and a 48 kB budget truncates to ~90 rows. p_limit=500 built 500 full
--    rows to publish 90. Now: a slim build that never selects the heavy
--    columns, plus a hard row ceiling the caller cannot raise.
--
-- Everything below is idempotent — a resumed worker re-applies it as a no-op.

-- ── 1. the derived title, computed once on write ───────────────────────────
alter table public.dev_commands
  add column if not exists title_display text;

comment on column public.dev_commands.title_display is
  'CHANGE #887 — the title derived from the first "claimed/building #N:" line '
  'of build_log, materialised by trg_dev_title_sync so no read ever detoasts '
  'the log. NULL means the log carries no derived title; readers use '
  'coalesce(title_display, title).';

create or replace function public._dev_title_sync()
returns trigger
language plpgsql
as $fn$
begin
  -- The log only ever grows by appending, so once a derived title is found it
  -- can never change. Recompute only while we still have none (or the log was
  -- reset/truncated) — that makes this amortised O(1) on the heartbeat path
  -- instead of a full-log regexp on every write.
  if tg_op = 'INSERT'
     or (new.build_log is distinct from old.build_log
         and (new.title_display is null
              or length(coalesce(new.build_log,'')) < length(coalesce(old.build_log,'')))) then
    new.title_display := nullif(trim((regexp_match(coalesce(new.build_log,''),
      '(?:claimed|building) #\d+:\s*([^\n\r.]+)'))[1]), '');
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_dev_title_sync on public.dev_commands;
create trigger trg_dev_title_sync
  before insert or update on public.dev_commands
  for each row execute function public._dev_title_sync();

-- Backfill. 384 rows; re-running is a no-op for anything already derived.
update public.dev_commands
   set title_display = nullif(trim((regexp_match(coalesce(build_log,''),
         '(?:claimed|building) #\d+:\s*([^\n\r.]+)'))[1]), '')
 where title_display is null;

-- ── 2. the index the bounded, ordered pick was missing ─────────────────────
-- Every hot call filters on status and orders by (created_at desc, id desc).
-- dev_commands_created_idx serves the unfiltered page; idx_dev_commands_claim
-- is (status, urgent, priority, id) and cannot serve this ORDER BY, so a
-- status page scanned the created index and threw rows away.
create index if not exists dev_commands_status_created_idx
  on public.dev_commands (status, created_at desc, id desc);

-- ── 3. the ceiling, as data ────────────────────────────────────────────────
-- cards_max is the hard number of rows the cards view may BUILD. The 48 kB
-- payload budget only ever publishes ~90 card rows, so building more than this
-- is work that is guaranteed to be discarded. Tunable without a deploy.
-- Measured, not guessed: a card row averages ~1.6 kB, so the 48 kB budget
-- publishes THIRTY rows. cards_default was 120 and p_limit=500 built 500 — four
-- to sixteen times the work, all of it thrown away by the loop below. 60 is
-- double what the budget can hold, so a page of unusually small cards still
-- fills it, and it is config: raise it with pool config, no deploy.
update public.dev_runner_config
   set value = value || jsonb_build_object('cards_max', 60)
 where key = 'list_limits';

insert into public.dev_runner_config (key, value)
select 'list_limits',
       '{"max":500,"full_default":100,"cards_default":120,"cards_max":60}'::jsonb
where not exists (select 1 from public.dev_runner_config where key = 'list_limits');

insert into public.ui_copy (key, value)
values ('dev_queue.list_truncated',
        to_jsonb('Showing the newest {shown} of {total} — filter or search to see the rest.'::text))
on conflict (key) do nothing;

-- ── 4. the model/effort chips stopped querying config once per ROW ────────
-- Measured after steps 1-6 the list was still 154 ms / 3,223 buffers for 160
-- slim rows — 20 buffers a row on a 166-page table. The remainder was here:
-- _dev_model_label and _dev_effort_label each SELECT from dev_runner_config,
-- and every row called them four to five times (model_label, effort_label, and
-- _dev_model_chip which calls both again, twice on drift). 160 rows bought
-- ~700 config lookups. The map is one row of config; load it once per call and
-- look the row up in jsonb. Same three functions, same output, taking the map.
create or replace function public._dev_model_label_m(p_map jsonb, m text)
returns text language sql immutable as $fn$
  select coalesce(p_map->>m,
                  regexp_replace(coalesce(nullif(m,''),'claude-opus-5'), '^claude-', ''));
$fn$;

create or replace function public._dev_effort_label_m(p_map jsonb, e text)
returns text language sql immutable as $fn$
  select coalesce(p_map->>coalesce(nullif(e,''),'high'),
                  initcap(coalesce(nullif(e,''),'high'))||' effort');
$fn$;

create or replace function public._dev_model_chip_m(
  p_models jsonb, p_efforts jsonb,
  p_model text, p_effort text, p_mode text,
  p_actual_model text default null, p_actual_effort text default null)
returns text language sql immutable as $fn$
  with v as (
    select coalesce(nullif(p_actual_model,''),  nullif(p_model,''),  'claude-opus-5') as m,
           coalesce(nullif(p_actual_effort,''), nullif(p_effort,''), 'high')          as e,
           nullif(p_actual_model,'') is not null
             and nullif(p_model,'') is not null
             and nullif(p_actual_model,'') <> nullif(p_model,'')                      as drift
  )
  select public._dev_model_label_m(p_models, v.m)
         || ' · ' || public._dev_effort_label_m(p_efforts, v.e)
         || coalesce(' · ' || nullif(p_mode,''), '')
         || case when v.drift then ' · asked ' || public._dev_model_label_m(p_models, p_model)
                 else '' end
    from v;
$fn$;

-- The two label maps, read once per call. `distinct on ... order by value, ord`
-- keeps the FIRST entry for a value, which is what the old `LIMIT 1` returned.
create or replace function public._dev_label_map(p_field text)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_object_agg(value, label), '{}'::jsonb)
    from (
      select distinct on (x->>'value')
             x->>'value' as value,
             x->>(case when p_field = 'efforts' then 'chip' else 'label' end) as label
        from dev_runner_config c,
             jsonb_array_elements(coalesce(c.value->p_field, '[]'::jsonb)) with ordinality e(x, ord)
       where c.key = 'models'
         and x->>'value' is not null
       order by x->>'value', ord
    ) m;
$fn$;

-- ── 5. the row builder: one bounded pick, set-based aggregates, slim cards ──
create or replace function public._dev_cmd_rows(
  p_status  text,
  p_search  text,
  p_batch   text,
  p_limit   integer,
  p_slim    boolean default false
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_rows jsonb; v_tat numeric; v_stale numeric;
  v_models jsonb; v_efforts jsonb;
  t_steps text; t_live text; t_stall text; t_resume text; t_ssteps text; t_shint text;
  t_fready text; t_fauto text; t_wait text; t_whint text; t_spec text;
begin
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
    select dc.id
      from dev_commands dc
     where (p_status is null or dc.status = p_status)
       and (p_batch  is null or dc.batch_label = p_batch)
       and (p_search is null
            or dc.title ilike '%'||p_search||'%'
            or dc.spec  ilike '%'||p_search||'%'
            or coalesce(dc.result_summary,'') ilike '%'||p_search||'%')
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
$fn$;

-- Internal helper: it carries no guard of its own, so nobody but the two
-- guarded RPCs above may call it.
revoke all on function public._dev_cmd_rows(text,text,text,integer,boolean) from public;

-- ── 6. dev_cmd_list_full — same signature, same payload, bounded internals ──
create or replace function public.dev_cmd_list_full(
  p_status text default null,
  p_search text default null,
  p_batch  text default null,
  p_limit  integer default 100
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_counts jsonb;
begin
  perform _dev_guard();
  select coalesce(jsonb_object_agg(status, n), '{}') into v_counts
    from (select status, count(*) n from dev_commands group by status) c;
  return jsonb_build_object(
    'rows', public._dev_cmd_rows(p_status, p_search, p_batch,
                                 public._dev_list_limit(p_limit, 'full_default'), false),
    'counts', v_counts,
    'screen_title', 'Dev Queue');
end
$fn$;

-- ── 7. dev_cmd_list — the cards path, with a ceiling it cannot be argued out of ──
create or replace function public.dev_cmd_list(
  p_status         text default null,
  p_search         text default null,
  p_batch          text default null,
  p_limit          integer default null,
  p_view           text default null,
  p_updated_since  timestamp with time zone default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_raw jsonb; v_counts jsonb; v_kept jsonb := '[]'::jsonb; v_arr jsonb[] := '{}';
  v_view text := lower(coalesce(nullif(p_view,''),'cards'));
  v_budget int := 48000;   -- rows only; the envelope (counts, chips, meta) rides
                           -- on top and the WHOLE payload must stay under 50 kB
  v_used int := 0; v_row jsonb; v_card jsonb; v_len int; v_built int;
  v_trunc boolean := false;
  v_ask int; v_ceiling int; v_matched int; v_note text := '';
begin
  perform _dev_guard();

  -- CHANGE #778 — the ceiling. p_limit arrives NULL from the app and used to
  -- reach `limit NULL`, which is SQL for no limit at all.
  -- CHANGE #887 — and the ceiling now BINDS. The cards budget below can only
  -- ever publish ~90 rows, so a caller asking for 500 was buying 410 rows of
  -- TOAST reads, aggregates and jsonb it was always going to discard. Rows
  -- built are capped at list_limits.cards_max (data, tunable with no deploy);
  -- the payload says so instead of silently ending.
  v_ask := public._dev_list_limit(p_limit,
             case when v_view = 'full' then 'full_default' else 'cards_default' end);

  if v_view = 'full' then
    select coalesce(jsonb_object_agg(status, n), '{}') into v_counts
      from (select status, count(*) n from dev_commands group by status) c;
    return jsonb_build_object(
             'rows', public._dev_cmd_rows(p_status, p_search, p_batch, v_ask, false),
             'counts', v_counts,
             'screen_title', 'Dev Queue')
           || jsonb_build_object('view','full','row_ceiling', v_ask, 'server_time', now());
  end if;

  select least(v_ask, coalesce((value->>'cards_max')::int, 60)) into v_ceiling
    from dev_runner_config where key='list_limits';
  v_ceiling := greatest(coalesce(v_ceiling, least(v_ask, 60)), 1);

  select coalesce(jsonb_object_agg(status, n), '{}') into v_counts
    from (select status, count(*) n from dev_commands group by status) c;

  v_raw   := public._dev_cmd_rows(p_status, p_search, p_batch, v_ceiling, true);
  v_built := jsonb_array_length(v_raw);

  -- Fill to the budget in payload order, then stop. Rows are already ordered by
  -- the list's own ranking, so a truncated page is the TOP of the list, never a
  -- random slice — and the caller is told there is more.
  -- CHANGE #887: strip INSIDE the loop. The old shape stripped all 120 rows
  -- (80 key lookups each) and then discarded 90 of them one line later.
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
    v_card := public._dev_card_strip(v_row);
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

  -- How many rows actually match, bounded so the honesty line can never become
  -- the next slow call: the count itself stops at 5 000.
  select count(*) into v_matched from (
    select 1 from dev_commands dc
     where (p_status is null or dc.status = p_status)
       and (p_batch  is null or dc.batch_label = p_batch)
       and (p_search is null
            or dc.title ilike '%'||p_search||'%'
            or dc.spec  ilike '%'||p_search||'%'
            or coalesce(dc.result_summary,'') ilike '%'||p_search||'%')
     limit 5000) x;

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
           'view','cards',
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
$fn$;
