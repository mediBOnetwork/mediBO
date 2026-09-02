-- CHANGE #643 (3/5) — dev_cmd_list stops shipping a book to draw a list.
--
-- Measured 2026-09-02: dev_cmd_list(null,null,null,200) returns 2,418,496
-- bytes. Per row (11,051 bytes) the weight is almost entirely detail nobody
-- can see on a card:
--     build_log_tail   4,244 b      predicted_files  1,063 b
--     steps            1,046 b      finish_blockers    929 b
--     decisions          854 b      everything else  ~2,900 b
-- At 19,592 calls/day that is ~12 GB — 99% of the 36 GB egress on 1 Sep.
--
-- Two changes, no new contract for the screens to learn:
--   * dev_cmd_list keeps its name and every key a CARD renders; the six heavy
--     keys and the long free text are stripped, and plain_summary is capped at
--     200 characters. p_view='full' still returns everything for anything that
--     genuinely needs it.
--   * dev_cmd_get(id) is the detail read: the FULL row, one command at a time,
--     fetched when a card is opened instead of 200 of them on every poll.
--   * p_updated_since makes the admin poll a DELTA: rows whose clock has not
--     moved are not sent again.
--
-- The original body is untouched — it is renamed to dev_cmd_list_full and the
-- new dev_cmd_list is a thin projection over it. Nothing about how a card is
-- decided moves into this file; the backend still decides every chip.

do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'dev_cmd_list'
      and pg_get_function_identity_arguments(p.oid) = 'p_status text, p_search text, p_batch text, p_limit integer'
  ) and not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'dev_cmd_list_full'
  ) then
    alter function public.dev_cmd_list(text, text, text, integer)
      rename to dev_cmd_list_full;
  end if;
end $$;

-- A card is an ALLOW list, not a deny list. A deny list keeps growing back:
-- the 119-key row was 119 keys because every command that added a field added
-- it here too. This is exactly the set the card widgets read
-- (dev_queue_screen.dart + dev_queue_common.dart) plus the identity and clocks
-- the list needs to sort and to poll deltas. Anything else — the log tail, the
-- spec, the decisions, the screenshots, the step list, the finish blockers —
-- is detail, and detail arrives from dev_cmd_get when a card is opened.
-- With 119 keys the key NAMES alone were ~1.8 kB of every row.
create or replace function public._dev_card_keys()
returns text[]
language sql
immutable
as $$
  select array[
    'id','title','status','kind','area','area_label','batch_label','priority',
    'urgent','is_danger','effort','route','route_label','route_tone',
    'claimed_by','model','model_chip','retry_count',
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
    'live_chip','stall_chip','resume_chip','debug_status','debug_requested',
    'auto_finished','auto_finish_source','rolled_back',
    'web_deploy_no','android_status','ios_status',
    'targets_web','targets_android','targets_ios'
  ]::text[];
$$;

create or replace function public._dev_card_strip(p_row jsonb)
returns jsonb
language sql
stable
as $$
  select coalesce(
    (select jsonb_object_agg(k, p_row -> k)
       from unnest(public._dev_card_keys()) k
      where p_row ? k), '{}'::jsonb)
    || jsonb_build_object(
         'plain_summary', left(coalesce(p_row->>'plain_summary',''), 200));
$$;

create or replace function public.dev_cmd_list(
  p_status         text        default null,
  p_search         text        default null,
  p_batch          text        default null,
  p_limit          integer     default null,
  p_view           text        default null,
  p_updated_since  timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare j jsonb; v_rows jsonb; v_view text := lower(coalesce(nullif(p_view,''),'cards'));
begin
  j := public.dev_cmd_list_full(p_status, p_search, p_batch, p_limit);
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

  return jsonb_set(j, '{rows}', v_rows)
         || jsonb_build_object(
              'view','cards',
              'is_delta', (p_updated_since is not null),
              'updated_since', p_updated_since,
              'row_count', jsonb_array_length(v_rows),
              'server_time', now());
end $$;

grant execute on function public.dev_cmd_list(text, text, text, integer, text, timestamptz)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dev_cmd_get — one command, everything about it. Read on open, not on poll.
-- ---------------------------------------------------------------------------
-- Read straight from the row: building a 500-command list to answer a question
-- about ONE command would have re-created the problem this file exists to fix.
-- The card is already on screen (it came from dev_cmd_list); this returns the
-- parts _dev_card_strip left behind, plus the long free text in full.
create or replace function public.dev_cmd_get(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare c dev_commands%rowtype; v_tail text;
begin
  perform _dev_guard();
  select * into c from dev_commands where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'command_not_found', 'id', p_id);
  end if;

  -- the tail is what the detail screen shows; the whole log is never shipped
  v_tail := right(coalesce(c.build_log, ''), 8000);

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'server_time', now(),
    'row', jsonb_build_object(
      'id',                   c.id,
      'title',                c.title,
      'status',               c.status,
      'spec',                 c.spec,
      'build_log_tail',       v_tail,
      'error_log',            c.error_log,
      'screenshots',          coalesce(c.screenshots,   '[]'::jsonb),
      'decisions',            coalesce(c.decisions,     '[]'::jsonb),
      'predicted_files',      coalesce(c.predicted_files,'[]'::jsonb),
      'steps',                coalesce(c.steps,         '[]'::jsonb),
      'depends_on',           coalesce(c.depends_on,    '[]'::jsonb),
      'result_summary',       c.result_summary,
      'plain_summary',        c.plain_summary,
      'result_actions',       coalesce(c.result_actions,'[]'::jsonb),
      'needs_input_question', c.needs_input_question,
      'eta_note',             c.eta_note,
      'wait_blocker',         c.wait_blocker,
      'finish_blockers',      (public.dev_cmd_finish_state(p_id) -> 'blockers')));
end $$;

grant execute on function public.dev_cmd_get(bigint) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- dev_cmd_messages — paginated thread; media as URLs, never inline payloads.
-- ---------------------------------------------------------------------------
create or replace function public.dev_cmd_messages(
  p_id       bigint,
  p_limit    integer default 50,
  p_after_id bigint  default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_lim int := least(greatest(coalesce(p_limit,50),1),50);
        v_rows jsonb; v_total int;
begin
  perform _dev_guard();

  select count(*) into v_total from dev_command_messages where command_id = p_id;

  select coalesce(jsonb_agg(x order by x_id), '[]'::jsonb) into v_rows
  from (
    select m.id as x_id,
           jsonb_build_object(
             'id', m.id,
             'sender', m.sender,
             'body', m.body,
             'created_at', m.created_at,
             -- URLs only. The stored rows may carry an object per item; the
             -- thread only ever needs somewhere to point the browser.
             'images', coalesce((
               select jsonb_agg(case when jsonb_typeof(e) = 'string' then e
                                     else coalesce(e->'url', e->'path', e->'signed_url') end)
               from jsonb_array_elements(coalesce(m.images,'[]'::jsonb)) e), '[]'::jsonb),
             'attachments', coalesce((
               select jsonb_agg(case when jsonb_typeof(e) = 'string' then e
                                     else coalesce(e->'url', e->'path', e->'signed_url') end)
               from jsonb_array_elements(coalesce(m.attachments,'[]'::jsonb)) e), '[]'::jsonb)
           ) as x
    from dev_command_messages m
    where m.command_id = p_id
      and (p_after_id is null or m.id > p_after_id)
    order by m.id
    limit v_lim
  ) s;

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'rows', v_rows,
    'count', jsonb_array_length(v_rows),
    'total', v_total,
    'page_size', v_lim,
    'has_more', (jsonb_array_length(v_rows) = v_lim),
    'next_after_id', (select max((e->>'id')::bigint) from jsonb_array_elements(v_rows) e));
end $$;

grant execute on function public.dev_cmd_messages(bigint, integer, bigint)
  to authenticated, service_role;
