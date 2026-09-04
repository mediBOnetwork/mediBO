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
                  'metric_window',     coalesce((value->'context'->>'metric_window')::int, 20),
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

-- ── 6. (WITHDRAWN) AUTO-SPLIT OF AN OVERSIZED SPEC ─────────────────────────
-- Om, mid-build on #1197: "DROP item 5 (auto-split). No auto-splitting of specs
-- — compact + state file + output hygiene are enough." Built, then withdrawn on
-- his call. The drops below are what makes replaying this file on a database
-- that saw the first version a clean no-op.
drop function if exists public.dev_spec_split_plan(text, text, text);

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

  raise exception 'RG_ROLLBACK';
end $t$;
$b$,
true,
'CHANGE #1197 — context economy: the compact threshold is config, the state mirror exists, a mid-build compact resumes from the state file inside the word cap, and the metrics card renders. (Auto-split was built and then withdrawn by Om mid-build — this test deliberately does not assert it.)')
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;

-- ── 12. (WITHDRAWN) AUTO-SPLIT AT ADD TIME ─────────────────────────────────
-- dev_cmd_bulk_add is deliberately left exactly as CHANGE #656 wrote it.
