-- CHANGE #1197 — Context economy.
-- Om, 4 Sep 2026: a mid-build /clear wipes the session and the agent burns
-- tokens re-reading the prompt, recovering state and re-running checks (#1182).
-- This migration is the BACKEND half of the permanent fix:
--   * config           — worker_pool.context_compact_pct (default 70) + the
--                        rest of the context knobs, so nothing is a literal in
--                        bash or Dart.
--   * state mirror     — dev_commands.resume_note holds the per-command state
--                        file, capped server-side at resume_words (200).
--   * resume brief     — dev_cmd_resume_brief(): the ONLY thing a resumed
--                        session is handed. Never the full prompt file.
--   * events           — dev_context_event records every /compact and /clear
--                        so the ratio is measured, not claimed.
--   * auto-split       — an xlarge spec with more than 8 numbered items is
--                        split at ADD time into chained parts of <= 6.
--   * metrics          — dev_context_metrics(): tokens/command before vs
--                        after, compact vs clear, average resume size. Render
--                        ready: every string and every number is formatted here.
-- Every statement is idempotent: a resumed worker re-applies this file as a
-- silent no-op.

-- ── 1. CONFIG ───────────────────────────────────────────────────────────────
update dev_runner_config
   set value = value
        || jsonb_build_object(
             'context_compact_pct',
             coalesce((value->>'context_compact_pct')::int, 70))
        || jsonb_build_object('context',
             coalesce(value->'context', '{}'::jsonb)
             || jsonb_build_object(
                  'compact_pct',       coalesce((value->'context'->>'compact_pct')::int, 70),
                  'window_tokens',     coalesce((value->'context'->>'window_tokens')::int, 200000),
                  'resume_words',      coalesce((value->'context'->>'resume_words')::int, 200),
                  'split_at_items',    coalesce((value->'context'->>'split_at_items')::int, 8),
                  'split_max_items',   coalesce((value->'context'->>'split_max_items')::int, 6),
                  'metric_window',     coalesce((value->'context'->>'metric_window')::int, 20),
                  'split_exempt_ids',  coalesce(value->'context'->'split_exempt_ids', '[1000,1016,1017]'::jsonb),
                  'since',             coalesce(value->'context'->>'since', to_char(now(),'YYYY-MM-DD"T"HH24:MI:SSOF'))
                ))
 where key = 'worker_pool';

-- ── 2. STATE MIRROR ─────────────────────────────────────────────────────────
alter table dev_commands add column if not exists resume_note       text;
alter table dev_commands add column if not exists resume_note_at    timestamptz;
alter table dev_commands add column if not exists resume_note_words integer;

create table if not exists dev_context_event (
  id         bigint generated always as identity primary key,
  command_id bigint references dev_commands(id) on delete set null,
  agent      text,
  kind       text not null,
  pct        numeric,
  ok         boolean not null default true,
  detail     jsonb   not null default '{}'::jsonb,
  at         timestamptz not null default now()
);
create index if not exists dev_context_event_at_idx  on dev_context_event (at desc);
create index if not exists dev_context_event_cmd_idx on dev_context_event (command_id);
alter table dev_context_event enable row level security;

-- ── 3. HELPERS ──────────────────────────────────────────────────────────────
create or replace function public.dev_context_cfg()
returns jsonb language sql stable set search_path to 'public' as $$
  select coalesce(
    (select value->'context' from dev_runner_config where key='worker_pool'),
    '{}'::jsonb)
    || jsonb_build_object('compact_pct',
         coalesce((select (value->>'context_compact_pct')::int from dev_runner_config where key='worker_pool'),
                  (select (value->'context'->>'compact_pct')::int from dev_runner_config where key='worker_pool'),
                  70));
$$;

-- Word-cap a block of prose without cutting a word in half.
create or replace function public._dev_words_cap(p_text text, p_words int)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when p_text is null then null
    when array_length(regexp_split_to_array(btrim(p_text), '\s+'), 1) <= p_words then btrim(p_text)
    else array_to_string(
           (regexp_split_to_array(btrim(p_text), '\s+'))[1:p_words], ' ') || ' …'
  end;
$$;

create or replace function public._dev_word_count(p_text text)
returns integer language sql immutable set search_path to 'public' as $$
  select case when coalesce(btrim(p_text),'') = '' then 0
              else array_length(regexp_split_to_array(btrim(p_text), '\s+'), 1) end;
$$;

-- Compact number for a card: 412345 -> "412K", 1_240_000 -> "1.2M".
create or replace function public._dev_num_short(p_n numeric)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when p_n is null            then '—'
    when abs(p_n) >= 1000000    then trim(to_char(p_n/1000000.0, 'FM9990.0')) || 'M'
    when abs(p_n) >= 1000       then trim(to_char(p_n/1000.0,    'FM9990'))   || 'K'
    else trim(to_char(p_n, 'FM9990'))
  end;
$$;

-- ── 4. STATE WRITE + RESUME BRIEF ───────────────────────────────────────────
-- devcmd.sh calls this after every step. The row carries the SAME text the
-- worker's ~/mediBO-runner/work/cmd-<id>.state.md holds, capped to
-- context.resume_words so the card, the watchdog and the resume prompt all
-- read one bounded string.
create or replace function public.dev_cmd_state_write(
  p_id bigint, p_state text, p_agent text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cap int; v_txt text;
begin
  perform _dev_guard();
  v_cap := coalesce((dev_context_cfg()->>'resume_words')::int, 200);
  v_txt := _dev_words_cap(p_state, v_cap);
  update dev_commands
     set resume_note       = v_txt,
         resume_note_at    = now(),
         resume_note_words = _dev_word_count(v_txt)
   where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  return jsonb_build_object('ok', true, 'id', p_id,
                            'words', _dev_word_count(v_txt),
                            'chars', length(coalesce(v_txt,'')),
                            'cap_words', v_cap,
                            'agent', p_agent);
end $$;

-- The ONLY thing a resumed session is handed. <= context.resume_words words.
-- Prefers the mirrored state file; falls back to a composed brief so a row that
-- never wrote one still resumes without re-reading anything.
create or replace function public.dev_cmd_resume_brief(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_cap int; v_txt text; v_src text; v_open text; v_next text; v_dec int;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  v_cap := coalesce((dev_context_cfg()->>'resume_words')::int, 200);

  if coalesce(btrim(r.resume_note),'') <> '' then
    v_txt := r.resume_note; v_src := 'state_file';
  else
    v_src := 'derived';
    select string_agg(n || '. ' || left(text, 90), '; ' order by n)
      into v_open from dev_command_spec_item
     where command_id = p_id and status = 'open';
    select s->>'title' into v_next
      from jsonb_array_elements(coalesce(r.steps,'[]'::jsonb)) s
     where s->>'status' <> 'done' order by (s->>'n')::int limit 1;
    v_dec := coalesce(jsonb_array_length(coalesce(r.decisions,'[]'::jsonb)), 0);
    v_txt := concat_ws(' ',
      'RESUME #' || p_id || '.',
      coalesce(r.steps_done,0) || '/' || coalesce(r.steps_total,0) || ' steps landed on branch ' ||
        coalesce(nullif(r.resume_branch,''), 'main') ||
        case when coalesce(r.resume_commit,'') <> '' then ' @' || left(r.resume_commit,12) else '' end || '.',
      case when v_dec > 0 then v_dec || ' decisions logged.' else '' end,
      case when v_next is not null then 'Next step: ' || v_next || '.' else 'All steps landed.' end,
      case when v_open is not null then 'Spec still open: ' || v_open || '.' else 'Spec checklist clear.' end,
      'Verify what landed before trusting it; migrations are idempotent. Do NOT re-read the prompt file.');
    v_txt := _dev_words_cap(v_txt, v_cap);
  end if;

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'source', v_src, 'text', v_txt,
    'words', _dev_word_count(v_txt), 'cap_words', v_cap,
    'branch', r.resume_branch, 'commit', r.resume_commit,
    'steps_done', coalesce(r.steps_done,0), 'steps_total', coalesce(r.steps_total,0),
    'written_at', r.resume_note_at);
end $$;

-- ── 5. CONTEXT EVENTS ───────────────────────────────────────────────────────
create or replace function public.dev_context_event(
  p_command_id bigint, p_agent text, p_kind text,
  p_pct numeric default null, p_ok boolean default true,
  p_detail jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint;
begin
  perform _dev_guard();
  if p_kind not in ('compact','compact_failed','clear','resume','threshold') then
    return jsonb_build_object('ok', false, 'error', 'unknown kind: ' || coalesce(p_kind,'null'));
  end if;
  insert into dev_context_event (command_id, agent, kind, pct, ok, detail)
  values (p_command_id, p_agent, p_kind, p_pct, coalesce(p_ok,true), coalesce(p_detail,'{}'::jsonb))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'kind', p_kind, 'pct', p_pct);
end $$;

-- ── 6. AUTO-SPLIT OF AN OVERSIZED SPEC ──────────────────────────────────────
-- At ADD time only. An xlarge spec carrying more than split_at_items numbered
-- items becomes chained parts of at most split_max_items each. "single command"
-- anywhere in the spec is an explicit opt-out and is always honoured.
create or replace function public.dev_spec_split_plan(
  p_title text, p_spec text, p_size text default null)
returns jsonb language plpgsql stable set search_path to 'public' as $$
declare v_cfg jsonb; v_at int; v_max int; ln text; v_txt text;
        v_head text := ''; v_items text[] := '{}'; v_seen boolean := false;
        v_n int; v_parts jsonb := '[]'::jsonb; v_chunks int; k int; a int; b int;
        v_body text;
begin
  v_cfg := dev_context_cfg();
  v_at  := coalesce((v_cfg->>'split_at_items')::int, 8);
  v_max := coalesce((v_cfg->>'split_max_items')::int, 6);

  if coalesce(p_spec,'') = '' then
    return jsonb_build_object('split', false, 'reason', 'empty spec');
  end if;
  if p_spec ~* 'single command' then
    return jsonb_build_object('split', false, 'reason', 'spec says "single command" — left whole');
  end if;
  if coalesce(p_size,'') <> 'xlarge' then
    return jsonb_build_object('split', false, 'reason', 'not xlarge (' || coalesce(p_size,'unknown') || ')');
  end if;

  -- Split on NUMBERED items only: a dashed bullet list is prose, not a plan.
  for ln in select unnest(string_to_array(p_spec, E'\n')) loop
    v_txt := btrim(ln);
    if v_txt ~ '^\d{1,2}[\).]\s+\S' then
      v_seen := true;
      v_items := v_items || v_txt;
    elsif v_seen then
      if v_txt <> '' and array_length(v_items,1) > 0 then
        v_items[array_length(v_items,1)] := v_items[array_length(v_items,1)] || E'\n' || v_txt;
      end if;
    else
      v_head := v_head || ln || E'\n';
    end if;
  end loop;

  v_n := coalesce(array_length(v_items,1), 0);
  if v_n <= v_at then
    return jsonb_build_object('split', false, 'reason', v_n || ' numbered items — at or under the ' || v_at || ' threshold', 'items', v_n);
  end if;

  v_chunks := ceil(v_n::numeric / v_max)::int;
  for k in 1..v_chunks loop
    a := (k-1)*v_max + 1;
    b := least(k*v_max, v_n);
    v_body := btrim(v_head);
    if v_body <> '' then v_body := v_body || E'\n\n'; end if;
    v_body := v_body
      || 'Part ' || k || ' of ' || v_chunks || ' — items ' || a || '–' || b
      || ' of the original spec. The other parts are chained behind this one; build ONLY these items.' || E'\n\n'
      || array_to_string(v_items[a:b], E'\n');
    v_parts := v_parts || jsonb_build_object(
      'k', k, 'of', v_chunks, 'from', a, 'to', b,
      'title', left(coalesce(p_title,'Command'), 44) || ' (' || k || '/' || v_chunks || ')',
      'spec', v_body);
  end loop;

  return jsonb_build_object(
    'split', true, 'items', v_n, 'chunks', v_chunks,
    'reason', v_n || ' numbered items on an xlarge spec — split into ' || v_chunks
              || ' chained parts of at most ' || v_max || ' (CHANGE #1197)',
    'parts', v_parts);
end $$;

-- ── 7. METRICS ──────────────────────────────────────────────────────────────
create or replace function public.dev_context_metrics(p_window int default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cfg jsonb; v_since timestamptz; v_w int;
        v_before numeric; v_after numeric; v_after_n int; v_before_n int;
        v_compact int; v_clear int; v_failed int; v_resume_words numeric; v_resume_n int;
        v_delta numeric; v_rows jsonb; v_tone text; v_delta_label text;
begin
  perform _dev_guard();
  v_cfg   := dev_context_cfg();
  v_w     := coalesce(p_window, (v_cfg->>'metric_window')::int, 20);
  v_since := coalesce((v_cfg->>'since')::timestamptz, now());

  select avg(t), count(*) into v_before, v_before_n from (
    select coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) t
      from dev_commands
     where status='completed' and finished_at < v_since
       and coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) > 0
     order by finished_at desc limit v_w) b;

  select avg(t), count(*) into v_after, v_after_n from (
    select coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) t
      from dev_commands
     where status='completed' and finished_at >= v_since
       and coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) > 0
     order by finished_at asc limit v_w) a;

  select count(*) filter (where kind='compact' and ok),
         count(*) filter (where kind='clear'),
         count(*) filter (where kind in ('compact_failed') or (kind='compact' and not ok))
    into v_compact, v_clear, v_failed
    from dev_context_event where at >= v_since;

  select avg(resume_note_words), count(*) into v_resume_words, v_resume_n
    from dev_commands where resume_note_words is not null and resume_note_at >= v_since;

  if v_before is not null and v_after is not null and v_before > 0 then
    v_delta := round(((v_after - v_before) / v_before) * 100.0, 1);
    v_delta_label := case when v_delta > 0 then '+' else '' end || trim(to_char(v_delta,'FM9990.0')) || '%';
    v_tone := case when v_delta <= 0 then 'success' else 'warning' end;
  else
    v_delta_label := 'measuring…'; v_tone := 'info';
  end if;

  v_rows := jsonb_build_array(
    jsonb_build_object('label','Tokens / command — before',
      'value', _dev_num_short(round(coalesce(v_before,0))),
      'sub',   v_before_n || ' commands', 'tone','info'),
    jsonb_build_object('label','Tokens / command — after',
      'value', case when v_after_n = 0 then '—' else _dev_num_short(round(coalesce(v_after,0))) end,
      'sub',   v_after_n || ' of ' || v_w || ' commands', 'tone','info'),
    jsonb_build_object('label','Change',
      'value', v_delta_label, 'sub', 'lower is better', 'tone', v_tone),
    jsonb_build_object('label','/compact vs /clear',
      'value', coalesce(v_compact,0) || ' · ' || coalesce(v_clear,0),
      'sub',   case when coalesce(v_failed,0) > 0 then v_failed || ' compact failed → cleared' else 'compact first, clear only on failure' end,
      'tone',  case when coalesce(v_clear,0) > coalesce(v_compact,0) then 'warning' else 'success' end),
    jsonb_build_object('label','Average resume size',
      'value', case when v_resume_n = 0 then '—' else trim(to_char(round(coalesce(v_resume_words,0)),'FM9990')) || ' words' end,
      'sub',   'cap ' || coalesce((v_cfg->>'resume_words')::int, 200) || ' words · ' || v_resume_n || ' rows',
      'tone',  case when coalesce(v_resume_words,0) > coalesce((v_cfg->>'resume_words')::int, 200) then 'warning' else 'success' end));

  return jsonb_build_object(
    'ok', true, 'has', true,
    'title', 'Context economy',
    'since', v_since,
    'since_label', 'since ' || to_char(v_since at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
    'threshold_label', 'compact at ' || coalesce((v_cfg->>'compact_pct')::int, 70) || '% context',
    'window', v_w,
    'rows', v_rows,
    'footnote', 'Measured over the ' || v_w || ' commands completed on each side of the change.');
end $$;

-- ── 8. dev_ctl_get carries the card (wrapper pattern) ───────────────────────
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='dev_ctl_get_core') then
    alter function public.dev_ctl_get() rename to dev_ctl_get_core;
  end if;
end $$;

create or replace function public.dev_ctl_get()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb; v_ctx jsonb;
begin
  v := public.dev_ctl_get_core();
  begin v_ctx := public.dev_context_metrics();
  exception when others then v_ctx := jsonb_build_object('ok', false, 'has', false);
  end;
  return v || jsonb_build_object('context', v_ctx);
end $$;

-- ── 9. GRANTS ───────────────────────────────────────────────────────────────
grant execute on function public.dev_context_cfg()                              to authenticated, service_role;
grant execute on function public.dev_cmd_state_write(bigint, text, text)        to authenticated, service_role;
grant execute on function public.dev_cmd_resume_brief(bigint)                   to authenticated, service_role;
grant execute on function public.dev_context_event(bigint, text, text, numeric, boolean, jsonb) to authenticated, service_role;
grant execute on function public.dev_spec_split_plan(text, text, text)          to authenticated, service_role;
grant execute on function public.dev_context_metrics(int)                       to authenticated, service_role;
grant execute on function public.dev_ctl_get()                                  to authenticated, service_role;
grant execute on function public.dev_ctl_get_core()                             to authenticated, service_role;
grant execute on function public._dev_words_cap(text, int)                      to authenticated, service_role;
grant execute on function public._dev_word_count(text)                          to authenticated, service_role;
grant execute on function public._dev_num_short(numeric)                        to authenticated, service_role;

-- ── 10. UI COPY (the card draws nothing of its own) ─────────────────────────
insert into ui_copy (key, value) values
  ('dev_queue.ctx_section',  '"Context economy"'::jsonb),
  ('dev_queue.ctx_empty',    '"No context events yet — the first /compact will show here."'::jsonb)
on conflict (key) do nothing;

-- ── 11. RG BEHAVIOUR TEST ───────────────────────────────────────────────────
insert into rg_behavior_tests (name, body, enabled, note) values (
'c1197_context_economy',
$b$
do $t$
declare v jsonb; v_id bigint; v_words int;
begin
  -- config: the threshold is data, not a bash literal
  if coalesce((select (value->>'context_compact_pct')::int from dev_runner_config where key='worker_pool'), 0)
     not between 1 and 100 then
    raise exception 'RG_FAIL: worker_pool.context_compact_pct missing or out of range (CHANGE #1197)';
  end if;

  -- the state mirror exists
  if not exists (select 1 from information_schema.columns
                  where table_name='dev_commands' and column_name='resume_note') then
    raise exception 'RG_FAIL: dev_commands.resume_note is gone — a resumed session would need the full prompt again (CHANGE #1197)';
  end if;

  -- force a compact mid-build: a building row + a state file + a compact event
  insert into dev_commands (title, spec, status, steps, steps_done, steps_total, resume_branch, resume_commit)
  values ('rg c1197 probe', E'1) one\n2) two', 'building',
          jsonb_build_array(jsonb_build_object('n',1,'title','one','status','done'),
                            jsonb_build_object('n',2,'title','two','status','pending')),
          1, 2, 'rg-probe', 'deadbeefcafe')
  returning id into v_id;

  perform public.dev_cmd_state_write(v_id,
    'STATE #' || v_id || '. Branch rg-probe @deadbeefcafe. Step 1 landed. Next: step 2.', 'rg');
  perform public.dev_context_event(v_id, 'rg', 'compact', 71.5, true, '{}'::jsonb);

  -- the resume is the state file, bounded, and never the prompt
  v := public.dev_cmd_resume_brief(v_id);
  if coalesce(v->>'source','') <> 'state_file' then
    raise exception 'RG_FAIL: dev_cmd_resume_brief did not resume from the state file (source=%) — that is the whole point of CHANGE #1197', v->>'source';
  end if;
  v_words := (v->>'words')::int;
  if v_words > coalesce((public.dev_context_cfg()->>'resume_words')::int, 200) then
    raise exception 'RG_FAIL: resume brief is % words — over the cap. A resume must never grow back into a full re-read (CHANGE #1197)', v_words;
  end if;

  -- the metrics card counts that compact
  v := public.dev_context_metrics();
  if coalesce((v->>'has')::boolean, false) is not true then
    raise exception 'RG_FAIL: dev_context_metrics() returned no card — the Context economy panel would be blank (CHANGE #1197)';
  end if;

  -- auto-split: 10 numbered items on an xlarge spec become chained parts of <= 6
  v := public.dev_spec_split_plan('probe',
        E'preamble\n1) a aaaa\n2) b bbbb\n3) c cccc\n4) d dddd\n5) e eeee\n6) f ffff\n7) g gggg\n8) h hhhh\n9) i iiii\n10) j jjjj',
        'xlarge');
  if coalesce((v->>'split')::boolean,false) is not true then
    raise exception 'RG_FAIL: a 10-item xlarge spec was not split (CHANGE #1197): %', v->>'reason';
  end if;
  if (v->>'chunks')::int <> 2 then
    raise exception 'RG_FAIL: expected 2 chained parts, got % (CHANGE #1197)', v->>'chunks';
  end if;

  -- "single command" is an explicit opt-out and must always win
  v := public.dev_spec_split_plan('probe',
        E'single command please\n1) a aaaa\n2) b bbbb\n3) c cccc\n4) d dddd\n5) e eeee\n6) f ffff\n7) g gggg\n8) h hhhh\n9) i iiii\n10) j jjjj',
        'xlarge');
  if coalesce((v->>'split')::boolean,false) is not false then
    raise exception 'RG_FAIL: a spec that says "single command" was split anyway (CHANGE #1197)';
  end if;

  raise exception 'RG_ROLLBACK';
end $t$;
$b$,
true,
'CHANGE #1197 — context economy: the compact threshold is config, the state mirror exists, a mid-build compact resumes from the state file inside the word cap, the metrics card renders, and an oversized numbered spec auto-splits unless the spec says "single command".')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── 12. AUTO-SPLIT AT ADD TIME ──────────────────────────────────────────────
-- dev_cmd_bulk_add is the ONE add path (the sheet, the drafter and bulk add all
-- land here). An xlarge spec with more than split_at_items numbered items now
-- becomes chained parts instead of one command no worker can hold in context.
-- Everything else in this function is unchanged from CHANGE #656.
CREATE OR REPLACE FUNCTION public.dev_cmd_bulk_add(p_items jsonb, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r jsonb; v_warn jsonb := '[]'; v_added jsonb := '[]'; v_id bigint; v_dup record; v_deps bigint[];
        v_scan jsonb; v_kind text; v_danger boolean; v_title text; v_imgs jsonb; v_atts jsonb;
        v_route text; v_area text; v_size text; v_why text; v_effort text; v_fast text;
        v_model text;
        v_split jsonb; v_part jsonb; v_prev bigint; v_pdeps bigint[];
BEGIN
  PERFORM _dev_guard();
  IF (_sec_cfg()->>'frozen')::boolean THEN RAISE EXCEPTION 'queue frozen — unlock with PIN first'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_title := coalesce(nullif(btrim(r->>'title'),''), left(regexp_replace(coalesce(r->>'spec',''), '\s+', ' ', 'g'), 60));
    v_scan := sec_scan_spec(coalesce(r->>'title','')||' '||coalesce(r->>'spec',''));
    IF NOT (v_scan->>'clean')::boolean THEN
      v_warn := v_warn || jsonb_build_object('title', v_title, 'reason','blocked', 'blocked_injection', v_scan->'hits');
      PERFORM _audit(_actor(),'cmd_blocked_injection', v_title, v_scan); CONTINUE;
    END IF;

    -- CHANGE #656: model/effort arrive from the add sheet and are AUTHORITATIVE.
    v_model  := coalesce(_dev_model_norm(r->>'model'), 'claude-opus-5');
    v_effort := coalesce(_dev_effort_norm(r->>'effort'), _dev_effort_for(r->>'spec', NULL, 0));
    IF v_model NOT IN ('claude-opus-5','claude-fable-5-1') THEN
      RAISE EXCEPTION 'dev_cmd_bulk_add: model "%" is not allowed (CHANGE #656 — only claude-opus-5 and claude-fable-5-1)', r->>'model';
    END IF;
    IF v_effort NOT IN ('high','extra') THEN
      RAISE EXCEPTION 'dev_cmd_bulk_add: effort "%" is not allowed (CHANGE #656 — only high and extra)', r->>'effort';
    END IF;

    SELECT id, title INTO v_dup FROM dev_commands
      WHERE status IN ('pending','building','awaiting_approval')
        AND (similarity(title, v_title) > 0.6 OR similarity(spec, r->>'spec') > 0.8)
      ORDER BY similarity(spec, r->>'spec') DESC LIMIT 1;
    IF v_dup.id IS NOT NULL AND NOT p_force THEN
      v_warn := v_warn || jsonb_build_object('title', v_title, 'reason','duplicate', 'duplicate_of', v_dup.id, 'duplicate_title', v_dup.title); CONTINUE;
    END IF;
    SELECT coalesce(array_agg(x::bigint), '{}') INTO v_deps FROM jsonb_array_elements_text(coalesce(r->'depends_on','[]'::jsonb)) x;
    v_kind := CASE WHEN coalesce(r->>'kind','dev')='gcp' THEN 'gcp' ELSE 'dev' END;
    v_danger := sec_is_danger(coalesce(r->>'spec',''));
    SELECT route, area, size_class, reason INTO v_route, v_area, v_size, v_why
      FROM _route_detect(v_title, r->>'spec');
    IF v_kind='gcp' THEN
      v_route := 'opus'; v_size := coalesce(v_size,'normal');
      v_why := 'Build lane — Google Cloud command, runs the gcloud lane.';
    END IF;

    -- ── CHANGE #1197: an oversized numbered spec is chained, never one row ──
    -- A 12-item xlarge spec cannot be held in one context, so it was being
    -- re-read from the top after every /clear. Split it here, at add time,
    -- into parts of at most context.split_max_items, each depending on the one
    -- before it. "single command" in the spec is an explicit opt-out.
    v_split := NULL;
    IF v_kind = 'dev' AND NOT p_force THEN
      v_split := dev_spec_split_plan(v_title, r->>'spec', v_size);
    END IF;
    IF v_split IS NOT NULL AND coalesce((v_split->>'split')::boolean, false) THEN
      v_prev := NULL;
      FOR v_part IN SELECT * FROM jsonb_array_elements(v_split->'parts') LOOP
        v_pdeps := CASE WHEN v_prev IS NULL THEN v_deps ELSE ARRAY[v_prev] END;
        INSERT INTO dev_commands (title, spec, status, priority, urgent, depends_on, batch_label,
                                  targets_web, targets_android, targets_ios, kind, is_danger,
                                  route, area, size_class, effort, model, route_reason, chain_reason,
                                  qa_required, created_by)
        VALUES (
          v_part->>'title', v_part->>'spec',
          CASE WHEN coalesce((r->>'require_approval')::boolean,false) THEN 'awaiting_approval' ELSE 'pending' END,
          coalesce((r->>'priority')::int, 100), coalesce((r->>'urgent')::boolean, false), v_pdeps,
          coalesce(r->>'batch_label', v_area),
          coalesce((r->>'targets_web')::boolean, true),
          coalesce((r->>'targets_android')::boolean, false), coalesce((r->>'targets_ios')::boolean, false),
          v_kind, v_danger, v_route, v_area, 'large', v_effort, v_model, v_why,
          v_split->>'reason',
          coalesce((r->>'qa_required')::boolean, true),
          auth.uid()
        ) RETURNING id INTO v_id;
        v_prev := v_id;
        v_added := v_added || jsonb_build_object('id', v_id, 'title', v_part->>'title', 'route', v_route,
                                                 'area', v_area, 'size_class', 'large', 'effort', v_effort,
                                                 'model', v_model, 'route_reason', v_why,
                                                 'is_danger', v_danger, 'split_part', v_part->>'k',
                                                 'split_of', v_part->>'of', 'split_reason', v_split->>'reason');
      END LOOP;
      PERFORM _audit(_actor(),'cmd_autosplit', v_title,
                     jsonb_build_object('items', v_split->>'items', 'chunks', v_split->>'chunks', 'why', v_split->>'reason'));
      v_warn := v_warn || jsonb_build_object('title', v_title, 'reason','auto_split', 'note', v_split->>'reason');
      CONTINUE;
    END IF;

    IF v_route='fast' AND v_kind='dev' AND NOT v_danger THEN
      v_fast := _fast_execute(r->>'spec');
      IF v_fast IS NOT NULL THEN
        INSERT INTO dev_commands (title, spec, status, kind, route, area, size_class, route_reason,
                                  plain_summary, result_summary, finished_at, started_at, created_by, qa_status, qa_required)
        VALUES (v_title, r->>'spec', 'completed', 'dev', 'fast', v_area, coalesce(v_size,'small'), v_why,
                v_fast, v_fast, now(), now(), auth.uid(), 'waived', false)
        RETURNING id INTO v_id;
        INSERT INTO dev_command_messages (command_id, sender, body) VALUES (v_id,'agent',v_fast);
        v_added := v_added || jsonb_build_object('id', v_id, 'title', v_title, 'route','fast', 'instant', true);
        PERFORM _audit(_actor(),'cmd_fastlane', v_id::text, jsonb_build_object('area',v_area));
        CONTINUE;
      ELSE
        v_route := 'opus';
        v_why := 'Build lane — fast-lane grammar did not apply, so it is a normal build on the command''s own model.';
      END IF;
    END IF;

    INSERT INTO dev_commands (title, spec, status, priority, urgent, depends_on, batch_label, targets_web, targets_android, targets_ios, kind, is_danger, route, area, size_class, effort, model, route_reason, qa_required, created_by)
    VALUES (
      v_title, r->>'spec',
      CASE WHEN coalesce((r->>'require_approval')::boolean,false) THEN 'awaiting_approval' ELSE 'pending' END,
      coalesce((r->>'priority')::int, 100), coalesce((r->>'urgent')::boolean, false), v_deps,
      coalesce(r->>'batch_label', v_area),
      coalesce((r->>'targets_web')::boolean, v_kind='dev'),
      coalesce((r->>'targets_android')::boolean, false), coalesce((r->>'targets_ios')::boolean, false),
      v_kind, v_danger, v_route, v_area, v_size, v_effort, v_model, v_why,
      coalesce((r->>'qa_required')::boolean, true),
      auth.uid()
    ) RETURNING id INTO v_id;
    v_imgs := coalesce(r->'images','[]'::jsonb); v_atts := coalesce(r->'attachments','[]'::jsonb);
    IF jsonb_array_length(v_imgs) > 0 OR jsonb_array_length(v_atts) > 0 THEN
      INSERT INTO dev_command_messages (command_id, sender, body, images, attachments)
      VALUES (v_id, 'om', coalesce(nullif(btrim(r->>'media_note'),''),'Attached with the spec'), v_imgs, v_atts);
    END IF;
    v_added := v_added || jsonb_build_object('id', v_id, 'title', v_title, 'route', v_route, 'area', v_area,
                                             'size_class', v_size, 'effort', v_effort, 'model', v_model,
                                             'route_reason', v_why, 'is_danger', v_danger);
    PERFORM _audit(_actor(),'cmd_add', v_id::text, jsonb_build_object('route',v_route,'area',v_area,'size',v_size,'effort',v_effort,'model',v_model,'danger',v_danger,'why',v_why));
  END LOOP;
  RETURN jsonb_build_object('added', v_added, 'warnings', v_warn);
END $function$;
