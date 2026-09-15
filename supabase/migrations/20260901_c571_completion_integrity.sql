-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #571 — COMPLETION INTEGRITY
--
-- Three failure modes seen live on #536, fixed permanently in the harness:
--
--   1) RETRYABLE COMPLETION. dev_cmd_complete does rg_check + the whole
--      bug-loop gate + the rich result write in ONE 180 s statement. Under DB
--      load that call times out, and a build that was finished flails trying
--      to register that it finished. Completion is now TWO phases:
--        dev_cmd_complete_fast()  — id, status, change no. Cheap, idempotent.
--        dev_cmd_result_write()   — the rich summary, screenshots, chat message.
--      Each is retried from a local spool by devcmd.sh until it lands.
--
--   2) WAIT IS NOT FAILURE. #536 was marked FAILED with every test green and
--      the work committed: its deploy was evicted and two files were leased by
--      #460. Neither is a failing artifact. dev_cmd_fail now routes every
--      error through a DATA-DRIVEN classifier (dev_fail_rule): a wait verdict
--      PARKS the row (status stays 'building', a visible waiting note, the
--      session released) and dev_cmd_wait_sweep() resumes it when the blocker
--      clears. Only a failing artifact — red test, broken build, red rg_check,
--      QA fail — may fail a command.
--
--   3) SPEC-GATED FINISH. #536 declared success with core spec items unbuilt.
--      Every claimed row now carries a checklist derived from its OWN spec
--      (dev_command_spec_item). An open item blocks dev_cmd_complete,
--      dev_cmd_complete_fast and dev_cmd_finish_state alike — a final summary
--      is refused exactly like a completion. Items are closed with evidence,
--      or dropped WITH A REASON that is logged as a decision. Nothing is
--      silently discarded.
--
-- Every statement here is idempotent: a resumed worker re-applies it as a no-op.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── A. THE WAIT STATE ON THE ROW ───────────────────────────────────────────
alter table dev_commands add column if not exists wait_state   text;      -- null | 'parked'
alter table dev_commands add column if not exists wait_kind    text;      -- lease | merge | db | rpc | other
alter table dev_commands add column if not exists wait_reason  text;
alter table dev_commands add column if not exists wait_blocker jsonb default '{}'::jsonb;
alter table dev_commands add column if not exists wait_since   timestamptz;
alter table dev_commands add column if not exists wait_until   timestamptz;
alter table dev_commands add column if not exists wait_count   integer default 0;
alter table dev_commands add column if not exists wait_total_s integer default 0;

create index if not exists dev_commands_wait_idx
  on dev_commands (wait_state, wait_until) where wait_state is not null;

-- ── B. THE CLASSIFIER'S RULES ARE DATA, NOT CODE ──────────────────────────
-- A new contention shape is one INSERT, never a deploy. Ordered by `ord`;
-- first match wins; no match at all = 'fail' (the safe default: an error we
-- have never seen before is treated as a real failure, not silently parked).
create table if not exists dev_fail_rule (
  id           bigserial primary key,
  ord          integer not null default 100,
  pattern      text    not null,              -- case-insensitive regex on the error text
  verdict      text    not null check (verdict in ('wait','fail')),
  kind         text    not null default 'other',
  label        text    not null,              -- rendered verbatim on the card
  retry_after_s integer not null default 120,
  enabled      boolean not null default true,
  note         text,
  created_at   timestamptz not null default now()
);

insert into dev_fail_rule (ord, pattern, verdict, kind, label, retry_after_s, note) values
  (10, '(lease|leased|file_leases|lease_try|held by #)',                'wait', 'lease',
       'Waiting on a file lease', 90,  'another command is writing the same file — #327 build lane'),
  (20, '(evict|merge queue|merge_batch|deploy_queue|deploy lane|batch (was )?bisect)', 'wait', 'merge',
       'Waiting on the merge queue', 180, 'the batch was bisected/evicted — the branch is fine, requeue it'),
  (30, '(57014|statement timeout|canceling statement|lock timeout|55P03)', 'wait', 'db',
       'Waiting on the database', 120, 'DB busy — never a build failure'),
  (40, '(connection (timed out|terminated|refused)|could not connect|EOF|502|503|504|gateway|Empty reply)', 'wait', 'rpc',
       'Waiting on the backend', 120, 'transport hiccup — the work is untouched'),
  (50, '(db_busy|admission|remaining connection slots|too many connections)', 'wait', 'db',
       'Waiting for a database slot', 120, 'admission control — #368'),
  (60, '(deploy_lock|lock is held|lane busy)',                          'wait', 'merge',
       'Waiting for the deploy lane', 120, null),
  (100,'(test(s)? failed|FAILED|assertion|Expected:|compil|build failed|dart2js|flutter build|analyzer)', 'fail', 'artifact',
       'Build or test failure', 0, 'a failing artifact — this IS a failure'),
  (110,'(rg_check|regression guard|baseline)',                          'fail', 'artifact',
       'Regression guard red', 0, null),
  (120,'(qa_report|QA failed|hostile QA)',                              'fail', 'artifact',
       'QA verdict failed', 0, null)
on conflict do nothing;

create or replace function _dev_fail_classify(p_error text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r record;
begin
  -- A failing ARTIFACT always wins over a contention word that happens to
  -- appear in the same log tail: "2 tests failed while waiting on a lease" is
  -- a failure. So the artifact rules are consulted first, by ord.
  for r in select * from dev_fail_rule where enabled order by
             case verdict when 'fail' then 0 else 1 end, ord, id loop
    if p_error ~* r.pattern then
      return jsonb_build_object('verdict', r.verdict, 'kind', r.kind,
        'label', r.label, 'retry_after_s', r.retry_after_s, 'rule', r.id,
        'matched', true);
    end if;
  end loop;
  return jsonb_build_object('verdict', 'fail', 'kind', 'unknown',
    'label', _c_or('dev_queue.fail_unclassified', 'Unclassified error'),
    'retry_after_s', 0, 'rule', null, 'matched', false);
end $$;

-- ── C. PARK / UNPARK ──────────────────────────────────────────────────────
-- Parking keeps the row `building` (the work is real and still owned) but
-- releases the session: `dev_cmd_status_for_runner` reports 'parked', the
-- runner loop stops watching, and the worker claims the next command.
create or replace function dev_cmd_park(
  p_id bigint, p_kind text, p_reason text,
  p_blocker jsonb default '{}'::jsonb, p_retry_after_s integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_after int; v_label text;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', false, 'error', 'not building', 'status', r.status);
  end if;
  v_after := coalesce(p_retry_after_s,
    (select retry_after_s from dev_fail_rule where kind = p_kind and enabled order by ord limit 1), 120);
  v_label := coalesce(nullif(p_reason,''),
    (select label from dev_fail_rule where kind = p_kind and enabled order by ord limit 1),
    _c_or('dev_queue.wait_generic','Waiting on a blocker'));

  update dev_commands set
    wait_state   = 'parked',
    wait_kind    = coalesce(nullif(p_kind,''), 'other'),
    wait_reason  = v_label,
    wait_blocker = coalesce(p_blocker, '{}'::jsonb),
    wait_since   = now(),
    wait_until   = now() + (v_after || ' seconds')::interval,
    wait_count   = coalesce(wait_count,0) + 1
  where id = p_id;

  -- The leases go back the moment we park: holding a file while waiting on a
  -- DIFFERENT blocker is how one park becomes a fleet-wide queue.
  perform _lease_release_internal(p_id);
  perform _audit('system','dev_cmd_park', p_id::text,
    jsonb_build_object('kind', p_kind, 'reason', v_label, 'blocker', p_blocker, 'retry_after_s', v_after));
  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system', replace(replace(
    _c_or('dev_queue.wait_msg','⏸ Parked — {reason}. The work is committed and untouched; it resumes automatically when the blocker clears (checked every {after}s).'),
    '{reason}', v_label), '{after}', v_after::text));

  return jsonb_build_object('ok', true, 'parked', true, 'id', p_id,
    'kind', p_kind, 'reason', v_label, 'retry_after_s', v_after,
    'note', 'status stays building; the session is released and the row auto-resumes');
end $$;

-- Unpark: back to `pending` with the step plan, branch and commit intact, so
-- dev_cmd_claim hands it out as a RESUME and no work is redone.
create or replace function dev_cmd_unpark(p_id bigint, p_reason text default 'blocker cleared')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found or r.wait_state is distinct from 'parked' then
    return jsonb_build_object('ok', false, 'error', 'not parked');
  end if;
  update dev_commands set
    status       = 'pending',
    claimed_by   = null,
    released_at  = now(),
    release_reason = 'parked: ' || coalesce(r.wait_reason,''),
    urgent       = true,
    wait_state   = null, wait_kind = null, wait_until = null,
    wait_reason  = null, wait_blocker = '{}'::jsonb,
    wait_total_s = coalesce(wait_total_s,0)
                   + greatest(round(extract(epoch from now() - coalesce(r.wait_since, now())))::int, 0)
  where id = p_id;
  perform _audit('system','dev_cmd_unpark', p_id::text, jsonb_build_object('reason', p_reason));
  insert into dev_command_messages (command_id, sender, body)
  values (p_id, 'system', replace(_c_or('dev_queue.wait_clear_msg',
    '▶ Resuming — {reason}. Picking up at the first unfinished step.'), '{reason}', p_reason));
  return jsonb_build_object('ok', true, 'resumed', true, 'id', p_id);
end $$;

-- ── D. FAIL IS NOW A CLASSIFIER, NOT A BUTTON ─────────────────────────────
create or replace function dev_cmd_fail(p_id bigint, p_error text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_retry int; v_cls jsonb; v_gate boolean; v_max int; v_row record;
BEGIN
  PERFORM _dev_guard();
  SELECT * INTO v_row FROM dev_commands WHERE id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'no such command'); END IF;
  v_retry := coalesce(v_row.retry_count, 0);

  -- CHANGE #571 — contention is a WAIT, never a failure. The model no longer
  -- decides this: whatever it passes as an error is classified here.
  SELECT coalesce((value->'wait_gate'->>'enabled')::boolean, true),
         coalesce((value->'wait_gate'->>'max_parks')::int, 6)
    INTO v_gate, v_max FROM dev_runner_config WHERE key = 'worker_pool';
  v_cls := _dev_fail_classify(coalesce(p_error, ''));

  IF coalesce(v_gate, true)
     AND v_cls->>'verdict' = 'wait'
     AND v_row.status = 'building'
     AND coalesce(v_row.wait_count, 0) < coalesce(v_max, 6) THEN
    RETURN dev_cmd_park(p_id, v_cls->>'kind', v_cls->>'label',
             jsonb_build_object('error', left(coalesce(p_error,''), 1000),
                                'classified', v_cls),
             (v_cls->>'retry_after_s')::int)
           || jsonb_build_object('classified', v_cls, 'failed', false);
  END IF;

  IF v_retry = 0 THEN
    UPDATE dev_commands SET status='pending', retry_count=1, claimed_by=NULL,
      effort='high',
      wait_state=NULL, wait_kind=NULL, wait_until=NULL,
      route_reason = coalesce(route_reason,'')||' · retry escalated to high effort',
      error_log = coalesce(error_log||E'\n---\n','')||'RETRY 1 after: '||p_error
    WHERE id=p_id AND status='building';
  ELSE
    UPDATE dev_commands SET status='failed', finished_at=now(), claimed_by=NULL,
      wait_state=NULL, wait_kind=NULL, wait_until=NULL,
      error_log = coalesce(error_log||E'\n---\n','')||p_error
    WHERE id=p_id AND status='building';
    IF FOUND THEN
      PERFORM wa_send_event('dev_cmd_failed', NULL, jsonb_build_object('command_id', p_id::text, 'error', left(p_error,300)), NULL, NULL);
    END IF;
  END IF;
  PERFORM _lease_release_internal(p_id);
  RETURN jsonb_build_object('ok', true, 'retried', v_retry = 0, 'failed', true,
                            'classified', v_cls);
END $$;

-- ── E. THE SWEEP THAT RESUMES A PARKED ROW ────────────────────────────────
create or replace function dev_cmd_wait_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; n_res int := 0; n_hold int := 0; v_ids bigint[] := '{}';
        v_free boolean; v_paths text[]; v_maxage int;
begin
  perform _dev_guard();
  select coalesce((value->'wait_gate'->>'max_park_minutes')::int, 45)
    into v_maxage from dev_runner_config where key = 'worker_pool';
  v_maxage := coalesce(v_maxage, 45);

  for r in select * from dev_commands
            where wait_state = 'parked' and status = 'building'
            order by wait_until nulls first, id loop
    v_free := false;

    if r.wait_until is not null and r.wait_until > now() then
      n_hold := n_hold + 1;
      continue;                                   -- the retry window is not up
    end if;

    if r.wait_kind = 'lease' then
      v_paths := coalesce((select array_agg(value #>> '{}')
                             from jsonb_array_elements(coalesce(r.wait_blocker->'paths','[]'::jsonb))), '{}');
      v_free := (v_paths = '{}') or not exists (
        select 1 from file_leases fl
         where fl.path = any(v_paths) and fl.command_id <> r.id);
    elsif r.wait_kind = 'merge' then
      -- the lane is free when nothing is mid-batch for this command any more
      v_free := not exists (select 1 from deploy_queue q
                             where q.command_id = r.id
                               and q.status in ('queued','batched','merging'));
    else
      v_free := true;                             -- db / rpc / other: time heals it
    end if;

    -- Never strand a row: past max_park_minutes it resumes regardless, and the
    -- next worker re-discovers the blocker cheaply instead of a human doing it.
    if not v_free and r.wait_since < now() - (v_maxage || ' minutes')::interval then
      v_free := true;
    end if;

    if v_free then
      perform dev_cmd_unpark(r.id, coalesce(r.wait_reason, 'blocker cleared'));
      n_res := n_res + 1; v_ids := v_ids || r.id;
    else
      update dev_commands
         set wait_until = now() + (greatest(coalesce(
               (select retry_after_s from dev_fail_rule where kind = r.wait_kind and enabled order by ord limit 1),
               120), 60) || ' seconds')::interval
       where id = r.id;
      n_hold := n_hold + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'resumed', n_res, 'holding', n_hold, 'ids', to_jsonb(v_ids));
end $$;

insert into cron_task (name, ord, mode, gate_sql, work_sql, dml, note)
values ('dev_cmd_wait_sweep', 7, 'poll',
        'select exists (select 1 from public.dev_commands where wait_state = ''parked'')',
        'select public.dev_cmd_wait_sweep()', true,
        'CHANGE #571 — resumes a parked (waiting, not failed) command when its blocker clears')
on conflict (name) do update set
  gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
  enabled = true, note = excluded.note;

-- ── F. THE SPEC CHECKLIST ─────────────────────────────────────────────────
create table if not exists dev_command_spec_item (
  id          bigserial primary key,
  command_id  bigint not null references dev_commands(id) on delete cascade,
  n           integer not null,
  text        text    not null,
  source      text    not null default 'spec' check (source in ('spec','agent','followup')),
  status      text    not null default 'open' check (status in ('open','done','dropped')),
  evidence    text,
  drop_reason text,
  done_at     timestamptz,
  created_at  timestamptz not null default now(),
  unique (command_id, n)
);
create index if not exists dev_spec_item_open_idx
  on dev_command_spec_item (command_id) where status = 'open';

-- Derivation is deliberately CONSERVATIVE: only an explicitly enumerated spec
-- becomes a checklist ("1)" / "2." / "- " / "• "), and only when it lists at
-- least `min_items`. A prose spec yields no items and no gate — a wrong gate
-- that blocks every completion would be a worse bug than the one being fixed.
create or replace function _dev_spec_items_derive(p_id bigint)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare r record; ln text; v_txt text; v_cnt int := 0; v_min int; v_max int; v_items text[] := '{}';
begin
  select * into r from dev_commands where id = p_id;
  if not found then return 0; end if;
  if exists (select 1 from dev_command_spec_item where command_id = p_id) then
    return (select count(*)::int from dev_command_spec_item where command_id = p_id);
  end if;
  select coalesce((value->'spec_gate'->>'min_items')::int, 2),
         coalesce((value->'spec_gate'->>'max_items')::int, 20)
    into v_min, v_max from dev_runner_config where key = 'worker_pool';
  v_min := coalesce(v_min, 2); v_max := coalesce(v_max, 20);

  for ln in select unnest(string_to_array(coalesce(nullif(r.enriched_spec,''), r.spec, ''), E'\n')) loop
    v_txt := btrim(ln);
    continue when v_txt = '';
    if v_txt ~ '^(\d{1,2}[\).]|[-*•●])\s+\S' then
      v_txt := btrim(regexp_replace(v_txt, '^(\d{1,2}[\).]|[-*•●])\s+', ''));
      -- a heading-only bullet ("Backend:") is not a deliverable
      if length(v_txt) >= 12 then
        v_items := v_items || left(v_txt, 400);
      end if;
    end if;
  end loop;

  if coalesce(array_length(v_items,1),0) < v_min then return 0; end if;
  foreach v_txt in array v_items loop
    v_cnt := v_cnt + 1;
    exit when v_cnt > v_max;
    insert into dev_command_spec_item (command_id, n, text, source)
    values (p_id, v_cnt, v_txt, 'spec')
    on conflict (command_id, n) do nothing;
  end loop;
  return least(v_cnt, v_max);
end $$;

-- Derive the moment a row starts building, on EVERY path into `building`
-- (claim, resume, requeue) — a trigger, so no call site can forget.
create or replace function _dev_spec_items_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status = 'building' and coalesce(old.status,'') <> 'building'
     and coalesce(new.kind,'dev') = 'dev' then
    perform _dev_spec_items_derive(new.id);
  end if;
  return new;
end $$;
drop trigger if exists _dev_spec_items_trg on dev_commands;
create trigger _dev_spec_items_trg after update on dev_commands
  for each row execute function _dev_spec_items_trg();

-- Render-ready, verbatim. Nothing about this list is composed in Dart.
create or replace function dev_cmd_spec_items(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb; v_open int; v_total int; v_on boolean;
begin
  perform _dev_guard();
  select coalesce((value->'spec_gate'->>'enforce')::boolean, true) into v_on
    from dev_runner_config where key = 'worker_pool';
  select coalesce(jsonb_agg(jsonb_build_object(
           'n', s.n, 'text', s.text, 'status', s.status, 'source', s.source,
           'evidence', coalesce(s.evidence,''), 'drop_reason', coalesce(s.drop_reason,''),
           'status_label', case s.status
              when 'done'    then _c_or('dev_queue.spec_done','Built')
              when 'dropped' then _c_or('dev_queue.spec_dropped','Dropped')
              else                _c_or('dev_queue.spec_open','Open') end,
           'tone', case s.status when 'done' then 'success'
                                 when 'dropped' then 'neutral' else 'warning' end)
           order by s.n), '[]') into v
    from dev_command_spec_item s where s.command_id = p_id;
  select count(*) filter (where status = 'open'), count(*)
    into v_open, v_total from dev_command_spec_item where command_id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id, 'items', v,
    'open', coalesce(v_open,0), 'total', coalesce(v_total,0),
    'enforced', coalesce(v_on, true),
    'title', _c_or('dev_queue.spec_title','Spec checklist'),
    'empty_label', _c_or('dev_queue.spec_empty','This spec has no enumerated items — the step plan is the checklist.'),
    'chip', case when coalesce(v_total,0) = 0 then ''
                 else replace(replace(_c_or('dev_queue.spec_chip','Spec {done}/{total}'),
                        '{done}', (v_total - v_open)::text), '{total}', v_total::text) end);
end $$;

create or replace function dev_cmd_spec_item_done(p_id bigint, p_n integer, p_evidence text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  perform _dev_guard();
  update dev_command_spec_item
     set status = 'done', evidence = coalesce(nullif(p_evidence,''), evidence), done_at = now()
   where command_id = p_id and n = p_n;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such spec item'); end if;
  return dev_cmd_spec_items(p_id);
end $$;

-- Dropping is allowed, silence is not: the reason lands in the decisions log
-- where Om reads it, so "not in scope" is a recorded choice, never a gap.
create or replace function dev_cmd_spec_item_drop(p_id bigint, p_n integer, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_txt text;
begin
  perform _dev_guard();
  if coalesce(btrim(p_reason),'') = '' then
    return jsonb_build_object('ok', false, 'error', 'a drop needs a reason');
  end if;
  select text into v_txt from dev_command_spec_item where command_id = p_id and n = p_n;
  if v_txt is null then return jsonb_build_object('ok', false, 'error', 'no such spec item'); end if;
  update dev_command_spec_item
     set status = 'dropped', drop_reason = p_reason, done_at = now()
   where command_id = p_id and n = p_n;
  perform dev_cmd_log_decision(p_id, 'Spec item ' || p_n || ': ' || left(v_txt, 200),
            '["build it","drop it"]'::jsonb, 'drop it', p_reason);
  return dev_cmd_spec_items(p_id);
end $$;

-- The agent's own accurate checklist REPLACES the derived guess when the spec
-- was prose, or the derivation split an item badly. Same gate either way.
create or replace function dev_cmd_spec_items_set(p_id bigint, p_items jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare it text; v_cnt int := 0;
begin
  perform _dev_guard();
  delete from dev_command_spec_item where command_id = p_id and status = 'open';
  for it in select value #>> '{}' from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) loop
    if coalesce(btrim(it),'') = '' then continue; end if;
    v_cnt := v_cnt + 1;
    insert into dev_command_spec_item (command_id, n, text, source)
    values (p_id, coalesce((select max(n) from dev_command_spec_item where command_id = p_id), 0) + 1,
            left(btrim(it), 400), 'agent')
    on conflict (command_id, n) do nothing;
  end loop;
  return dev_cmd_spec_items(p_id);
end $$;

-- One place decides whether a row may close. Both completion paths and the
-- finish detector call it, so "final summary" is refused exactly like a
-- completion — that is the #536 hole.
create or replace function _dev_spec_gate(p_id bigint)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare r record; v_on boolean; v_open text; v_n int;
begin
  select coalesce((value->'spec_gate'->>'enforce')::boolean, true) into v_on
    from dev_runner_config where key = 'worker_pool';
  if not coalesce(v_on, true) then return null; end if;
  select * into r from dev_commands where id = p_id;
  if not found then return null; end if;
  if coalesce(r.kind,'dev') <> 'dev' or coalesce(r.route,'') = 'fast' then return null; end if;
  select count(*), string_agg('#' || n || ' ' || left(text, 80), ' · ' order by n)
    into v_n, v_open from dev_command_spec_item where command_id = p_id and status = 'open';
  if coalesce(v_n,0) = 0 then return null; end if;
  return replace(replace(_c_or('dev_queue.spec_block',
      '{n} spec item(s) still open: {items} — build them, or drop each with a reason'),
      '{n}', v_n::text), '{items}', v_open);
end $$;

-- ── G. RG_CHECK, CACHED — the reason completion timed out ─────────────────
-- rg_check collects the whole schema plus live payloads. Running it inside the
-- completion write is what made a finished build unable to register itself.
-- The guard stays honest: the cached verdict must be GREEN and recent.
create table if not exists rg_check_cache (
  id serial primary key, ok boolean not null, result jsonb not null,
  at timestamptz not null default now());

create or replace function rg_check_cached(p_max_age_s integer default 900, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c record; v jsonb;
begin
  perform _dev_guard();
  if not p_force then
    select * into c from rg_check_cache
     where at > now() - (p_max_age_s || ' seconds')::interval
     order by at desc limit 1;
    if found then
      return c.result || jsonb_build_object('cached', true,
        'age_s', round(extract(epoch from now() - c.at))::int);
    end if;
  end if;
  v := rg_check(true, true);
  insert into rg_check_cache (ok, result) values (coalesce((v->>'ok')::boolean,false), v);
  delete from rg_check_cache where at < now() - interval '2 days';
  return v || jsonb_build_object('cached', false, 'age_s', 0);
end $$;

-- ── H. COMPLETION, PHASE 1 — THE FAST WRITE ───────────────────────────────
-- id, status, change no, and the gates that must never be skipped, read from
-- indexed columns and a cached rg verdict. Idempotent: a retry that arrives
-- after the row already closed answers ok/already, never an exception, because
-- a completion that cannot be retried is the bug this change exists to remove.
create or replace function dev_cmd_complete_fast(
  p_id bigint, p_deploy_no integer default null, p_agent text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
set statement_timeout to '25s' as $$
declare r record; v_rg jsonb; v_spec text; v_block text := null; v_enforce boolean;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;
  if r.status = 'completed' then
    return jsonb_build_object('ok', true, 'already', true, 'id', p_id, 'status', 'completed',
      'change_no', r.web_deploy_no,
      'note', 'already completed — a retry of the fast write is a no-op by design');
  end if;
  if r.status <> 'building' then
    return jsonb_build_object('ok', false, 'error', 'not building', 'status', r.status);
  end if;

  v_rg := rg_check_cached(900, false);
  if coalesce((v_rg->>'ok')::boolean, false) = false then
    return jsonb_build_object('ok', false, 'retryable', false, 'error',
      'rg_check not green — rebaseline the intentional changes first',
      'rg', v_rg);
  end if;

  -- CHANGE #571 (3) — the spec checklist gates the fast path too.
  v_spec := _dev_spec_gate(p_id);
  if v_spec is not null then
    return jsonb_build_object('ok', false, 'retryable', false, 'blocked_by', 'spec_items',
      'error', v_spec, 'spec', dev_cmd_spec_items(p_id));
  end if;

  select coalesce((value->'bugloop'->>'enforce')::boolean, false) into v_enforce
    from dev_runner_config where key = 'worker_pool';
  if v_enforce and coalesce(r.kind,'dev') = 'dev' and coalesce(r.route,'') <> 'fast'
     and coalesce(r.qa_required,false) then
    if coalesce(r.qa_status,'pending') not in ('passed','waived') then
      v_block := 'QA is ' || coalesce(r.qa_status,'pending');
    elsif coalesce(r.steps_total,0) > 0 and coalesce(r.steps_done,0) < r.steps_total then
      v_block := 'steps ' || coalesce(r.steps_done,0) || '/' || r.steps_total;
    end if;
    if v_block is not null then
      return jsonb_build_object('ok', false, 'retryable', false, 'error',
        'bug-loop gate: ' || v_block);
    end if;
  end if;

  update dev_commands set
    status = 'completed', finished_at = now(),
    wait_state = null, wait_kind = null, wait_until = null,
    web_deploy_no   = coalesce(p_deploy_no, web_deploy_no),
    web_deployed_at = case when p_deploy_no is not null then now() else web_deployed_at end
  where id = p_id and status = 'building';
  if not found then
    -- someone closed it between the read and the write: still a success
    return jsonb_build_object('ok', true, 'already', true, 'id', p_id,
      'note', 'closed concurrently — nothing left to do');
  end if;
  perform _lease_release_internal(p_id);
  perform _audit('system','dev_cmd_complete_fast', p_id::text,
    jsonb_build_object('agent', p_agent, 'deploy_no', p_deploy_no));
  return jsonb_build_object('ok', true, 'phase', 'status', 'id', p_id,
    'status', 'completed', 'change_no', coalesce(p_deploy_no, r.web_deploy_no),
    'next', 'dev_cmd_result_write');
end $$;

-- ── I. COMPLETION, PHASE 2 — THE RICH RESULT ──────────────────────────────
-- Retried separately, and it works on an ALREADY completed row: the status
-- flip must never wait on the summary, and the summary must never be lost
-- because the flip won the race.
create or replace function dev_cmd_result_write(
  p_id bigint, p_result text, p_screenshots jsonb default '[]'::jsonb,
  p_plain_summary text default null, p_result_actions jsonb default null,
  p_deploy_no integer default null)
returns jsonb language plpgsql security definer set search_path to 'public'
set statement_timeout to '45s' as $$
declare r record; v_spec text; v_posted boolean := false;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  -- A FINAL SUMMARY IS A COMPLETION CLAIM. #536 wrote one while core spec
  -- items were unbuilt, so it is refused on exactly the same condition.
  if r.status not in ('completed','failed') then
    v_spec := _dev_spec_gate(p_id);
    if v_spec is not null then
      return jsonb_build_object('ok', false, 'blocked_by', 'spec_items',
        'error', 'final summary refused: ' || v_spec, 'spec', dev_cmd_spec_items(p_id));
    end if;
  end if;

  update dev_commands set
    title           = _dev_title(title, build_log),
    result_summary  = coalesce(nullif(p_result,''), result_summary),
    plain_summary   = coalesce(nullif(p_plain_summary,''), plain_summary),
    result_actions  = coalesce(p_result_actions, result_actions, '[]'::jsonb),
    screenshots     = case when jsonb_array_length(coalesce(p_screenshots,'[]'::jsonb)) > 0
                           then p_screenshots else screenshots end,
    web_deploy_no   = coalesce(p_deploy_no, web_deploy_no)
  where id = p_id;

  -- the agent's message is posted once, however many times this is retried
  if coalesce(p_result,'') <> '' or coalesce(p_plain_summary,'') <> '' then
    if not exists (select 1 from dev_command_messages m
                    where m.command_id = p_id and m.sender = 'agent'
                      and m.body like (left(coalesce(nullif(p_plain_summary,''), p_result), 60) || '%')) then
      insert into dev_command_messages (command_id, sender, body, images, attachments)
      values (p_id, 'agent',
        coalesce(nullif(p_plain_summary,''), p_result) ||
          case when coalesce(p_deploy_no, r.web_deploy_no) is not null
               then E'\n\n✅ CHANGE #' || coalesce(p_deploy_no, r.web_deploy_no) || ' deployed' else '' end,
        '[]', '[]');
      v_posted := true;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'phase', 'result', 'id', p_id,
    'status', r.status, 'message_posted', v_posted);
end $$;

-- ── J. THE ORIGINAL dev_cmd_complete KEEPS THE SPEC GATE TOO ──────────────
create or replace function dev_cmd_complete(p_id bigint, p_result text, p_deploy_no integer DEFAULT NULL::integer, p_screenshots jsonb DEFAULT '[]'::jsonb, p_plain_summary text DEFAULT NULL::text, p_result_actions jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' SET statement_timeout TO '180s'
AS $function$
DECLARE v_rg jsonb; v_row record; v_enforce boolean; v_missing text; v_block text := NULL;
        v_selftest record; v_spec text;
BEGIN
  PERFORM _dev_guard();
  v_rg := rg_check(true, true);
  IF coalesce((v_rg->>'ok')::boolean, false) = false THEN
    RAISE EXCEPTION 'dev_cmd_complete blocked: rg_check not green (rebaseline intentional changes first): %', left(v_rg::text, 400);
  END IF;
  INSERT INTO rg_check_cache (ok, result) VALUES (true, v_rg);

  SELECT * INTO v_row FROM dev_commands WHERE id=p_id;
  SELECT coalesce((value->'bugloop'->>'enforce')::boolean,false) INTO v_enforce FROM dev_runner_config WHERE key='worker_pool';

  -- CHANGE #571 (3) — an open spec item blocks completion outright. This one
  -- is NOT behind bugloop.enforce: shipping a command with a core spec item
  -- unbuilt is the failure this change exists to end.
  v_spec := _dev_spec_gate(p_id);
  IF v_spec IS NOT NULL THEN
    RAISE EXCEPTION 'dev_cmd_complete blocked (spec gate): %', v_spec;
  END IF;

  IF v_row.kind='dev' AND v_row.route <> 'fast' AND v_row.qa_required THEN
    IF v_row.qa_status NOT IN ('passed','waived') THEN
      v_block := 'QA verdict is '||v_row.qa_status||' — qa_report(passed) or qa_waive(PIN) required';
    END IF;
    IF v_block IS NULL AND EXISTS (
      SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.status='failed'
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr2 WHERE jr2.command_id=p_id AND jr2.journey_id=jr.journey_id AND jr2.status='passed' AND jr2.id>jr.id)
    ) THEN v_block := 'a journey run failed without a later pass'; END IF;
    IF v_block IS NULL THEN
      SELECT string_agg(j.name, ', ') INTO v_missing
      FROM dev_journeys j
      WHERE j.enabled
        AND (
              (j.required AND (j.area IS NULL OR j.area IS NOT DISTINCT FROM v_row.area))
              OR j.source_bug = p_id
            )
        AND NOT EXISTS (SELECT 1 FROM dev_journey_runs jr WHERE jr.command_id=p_id AND jr.journey_id=j.id AND jr.status='passed');
      IF v_missing IS NOT NULL THEN v_block := 'required journeys not passed: '||v_missing; END IF;
    END IF;
    IF v_block IS NULL AND jsonb_array_length(coalesce(p_screenshots,'[]')) = 0 THEN
      v_block := 'no screenshot evidence attached';
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL THEN
      SELECT * INTO v_selftest FROM dev_selftest_log
       WHERE ok AND at > now() - interval '6 hours'
       ORDER BY at DESC LIMIT 1;
      IF NOT FOUND THEN
        v_block := 'no green self-test on record in the last 6h — scripts/selftest.sh '
                || '(protected suite + focused test + rg_check) must pass before a web deploy';
      END IF;
    END IF;

    IF v_block IS NULL AND p_deploy_no IS NOT NULL AND v_row.targets_web
       AND coalesce(v_row.preview_status,'') <> 'promoted' THEN
      v_block := 'web deploy without preview→promote (preview_status='||coalesce(v_row.preview_status,'null')||')';
    END IF;

    IF v_block IS NOT NULL THEN
      IF v_enforce THEN
        RAISE EXCEPTION 'dev_cmd_complete blocked (bug-loop gate): %', v_block;
      ELSE
        PERFORM _audit('system','bugloop_warn', p_id::text, jsonb_build_object('would_block', v_block));
      END IF;
    END IF;
  END IF;

  UPDATE dev_commands SET
    status='completed', finished_at=now(),
    title = _dev_title(title, build_log),
    result_summary = p_result,
    plain_summary = coalesce(p_plain_summary, plain_summary),
    result_actions = coalesce(p_result_actions, '[]'::jsonb),
    web_deploy_no = coalesce(p_deploy_no, web_deploy_no),
    web_deployed_at = CASE WHEN p_deploy_no IS NOT NULL THEN now() ELSE web_deployed_at END,
    screenshots = coalesce(p_screenshots, '[]'),
    wait_state = NULL, wait_kind = NULL, wait_until = NULL
  WHERE id = p_id AND status='building';
  IF NOT FOUND THEN RAISE EXCEPTION 'dev_cmd_complete: row % not in building', p_id; END IF;
  IF coalesce(p_result,'') <> '' OR coalesce(p_plain_summary,'') <> '' THEN
    INSERT INTO dev_command_messages (command_id, sender, body, images, attachments)
    VALUES (p_id, 'agent',
      coalesce(nullif(p_plain_summary,''), p_result) ||
        CASE WHEN p_deploy_no IS NOT NULL THEN E'\n\n✅ CHANGE #'||p_deploy_no||' deployed' ELSE '' END,
      '[]', '[]');
  END IF;
  PERFORM _lease_release_internal(p_id);
  RETURN jsonb_build_object('ok', true, 'rg', v_rg, 'bugloop_warn', v_block);
END $function$;

-- ── K. THE FINISH DETECTOR LEARNS BOTH NEW CONDITIONS ─────────────────────
create or replace function dev_cmd_finish_state(p_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare r record; v jsonb := '[]'::jsonb; v_block text[] := '{}';
        v_gate boolean; v_proofs jsonb; v_missing text; v_change int;
        v_cfg jsonb; v_on boolean; v_grace int; v_selftest boolean;
        v_ready boolean; v_journeys int; v_spec text; v_spec_open int;
begin
  perform _dev_guard();
  select * into r from dev_commands where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no such command'); end if;

  select coalesce(value->'finish_gate', '{}'::jsonb) into v_cfg
    from dev_runner_config where key = 'worker_pool';
  v_on    := coalesce((v_cfg->>'enabled')::boolean, true);
  v_grace := coalesce((v_cfg->>'grace_s')::int, 120);

  v_gate := (coalesce(r.kind,'dev') = 'dev' and coalesce(r.route,'') <> 'fast' and coalesce(r.qa_required,false));

  if r.status <> 'building' then v_block := array_append(v_block, (('not building (' || r.status || ')'))::text); end if;
  if coalesce(r.needs_input_question,'') <> '' then v_block := array_append(v_block, ('an unanswered question is open')::text); end if;
  -- CHANGE #571 (2) — a parked row is WAITING, not finished. It must never be
  -- auto-completed while its blocker is still being waited on.
  if r.wait_state = 'parked' then
    v_block := array_append(v_block, ('parked: ' || coalesce(r.wait_reason,'waiting'))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','building','label','Row is building',
        'applies', true, 'ok', r.status = 'building' and coalesce(r.needs_input_question,'') = ''
                                and r.wait_state is distinct from 'parked',
        'detail', case when r.wait_state = 'parked' then 'parked' else r.status end));

  v := v || jsonb_build_array(jsonb_build_object('key','steps','label','Every step marked done',
        'applies', true,
        'ok', coalesce(r.steps_total,0) > 0 and coalesce(r.steps_done,0) >= r.steps_total,
        'detail', coalesce(r.steps_done,0)::text || '/' || coalesce(r.steps_total,0)::text));
  if coalesce(r.steps_total,0) = 0 then
    v_block := array_append(v_block, ('no step plan published')::text);
  elsif coalesce(r.steps_done,0) < r.steps_total then
    v_block := array_append(v_block, (('steps ' || coalesce(r.steps_done,0) || '/' || r.steps_total))::text);
  end if;

  -- CHANGE #571 (3) — the command's OWN spec checklist, on the same footing
  -- as the step plan. #536 finished with My Shop nav and Profile cleanup
  -- unbuilt because nothing ever compared the result against the spec.
  select count(*) into v_spec_open from dev_command_spec_item
   where command_id = p_id and status = 'open';
  v_spec := _dev_spec_gate(p_id);
  if v_spec is not null then v_block := array_append(v_block, v_spec::text); end if;
  v := v || jsonb_build_array(jsonb_build_object('key','spec','label','Every spec item built',
        'applies', exists (select 1 from dev_command_spec_item where command_id = p_id),
        'ok', coalesce(v_spec_open,0) = 0,
        'detail', ((select count(*) from dev_command_spec_item
                     where command_id = p_id and status <> 'open')::text || '/' ||
                   (select count(*) from dev_command_spec_item where command_id = p_id)::text)));

  if v_gate and coalesce(r.qa_status,'pending') not in ('passed','waived') then
    v_block := array_append(v_block, (('QA is ' || coalesce(r.qa_status,'pending')))::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','qa','label','QA passed',
        'applies', v_gate, 'ok', (not v_gate) or coalesce(r.qa_status,'') in ('passed','waived'),
        'detail', coalesce(r.qa_status,'')));

  if v_gate then
    if exists (select 1 from dev_journey_runs jr
                where jr.command_id = p_id and jr.status = 'failed'
                  and not exists (select 1 from dev_journey_runs jr2
                                   where jr2.command_id = p_id and jr2.journey_id = jr.journey_id
                                     and jr2.status = 'passed' and jr2.id > jr.id))
    then v_block := array_append(v_block, ('a journey run failed without a later pass')::text); end if;
    select string_agg(j.name, ', ') into v_missing
      from dev_journeys j
     where j.enabled
       and ((j.required and (j.area is null or j.area is not distinct from r.area)) or j.source_bug = p_id)
       and not exists (select 1 from dev_journey_runs jr
                        where jr.command_id = p_id and jr.journey_id = j.id and jr.status = 'passed');
    if v_missing is not null then v_block := array_append(v_block, (('journeys not passed: ' || v_missing))::text); end if;
  end if;
  select count(*) into v_journeys from dev_journey_runs jr
   where jr.command_id = p_id and jr.status = 'passed';
  v := v || jsonb_build_array(jsonb_build_object('key','journeys','label','Required journeys green',
        'applies', v_gate, 'ok', (not v_gate) or v_missing is null, 'detail', v_journeys::text || ' passed'));

  v_proofs := case when jsonb_array_length(coalesce(r.screenshots,'[]'::jsonb)) > 0
                   then r.screenshots else _dev_finish_proofs(p_id) end;
  if v_gate and jsonb_array_length(v_proofs) = 0 then
    v_block := array_append(v_block, ('no screenshot evidence in dev-cmd-proofs')::text);
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','proof','label','Screenshot proof stored',
        'applies', v_gate, 'ok', (not v_gate) or jsonb_array_length(v_proofs) > 0,
        'detail', jsonb_array_length(v_proofs)::text));

  select coalesce(r.web_deploy_no,
           (select q.change_no from deploy_queue q
             where q.command_id = p_id and q.status = 'deployed' and q.change_no is not null
             order by q.id desc limit 1)) into v_change;
  select exists (select 1 from dev_selftest_log s where s.ok and s.at > now() - interval '6 hours')
    into v_selftest;
  if v_gate and coalesce(r.targets_web,false) then
    if v_change is null then v_block := array_append(v_block, ('no deployed change number yet')::text); end if;
    if coalesce(r.preview_status,'') <> 'promoted' then
      v_block := array_append(v_block, (('preview_status=' || coalesce(r.preview_status,'null')))::text);
    end if;
    if v_change is not null and not v_selftest then
      v_block := array_append(v_block, ('no green self-test in the last 6h')::text);
    end if;
  end if;
  v := v || jsonb_build_array(jsonb_build_object('key','deploy','label','Change deployed and promoted',
        'applies', v_gate and coalesce(r.targets_web,false),
        'ok', (not (v_gate and coalesce(r.targets_web,false)))
              or (v_change is not null and coalesce(r.preview_status,'') = 'promoted' and v_selftest),
        'detail', coalesce('CHANGE #' || v_change::text, 'none')));

  v_ready := (array_length(v_block,1) is null) and v_on;
  if not v_on then v_block := array_append(v_block, ('finish gate disabled in worker_pool.finish_gate')::text); end if;

  return jsonb_build_object(
    'ok', true, 'id', p_id, 'status', r.status,
    'enabled', v_on, 'grace_s', v_grace,
    'ready', v_ready,
    'gate_applies', v_gate,
    'conditions', v,
    'blockers', to_jsonb(coalesce(v_block, '{}'::text[])),
    'blocker_text', coalesce(array_to_string(v_block, ' · '), ''),
    'change_no', v_change,
    'screenshots', v_proofs,
    'spec_open', coalesce(v_spec_open,0),
    'waiting', r.wait_state = 'parked',
    'wait_reason', coalesce(r.wait_reason,''),
    'ready_at', r.finish_ready_at,
    'auto_finished', coalesce(r.auto_finished,false),
    'auto_finish_source', coalesce(r.auto_finish_source,''));
end $function$;

-- ── L. THE COPY (backend-owned, as every string is) ───────────────────────
insert into ui_copy (key, value) values
  ('dev_queue.wait_chip',      to_jsonb('⏸ {reason} · waiting {age}'::text)),
  ('dev_queue.wait_hint',      to_jsonb('Not a failure — the work is committed and resumes automatically when the blocker clears.'::text)),
  ('dev_queue.wait_generic',   to_jsonb('Waiting on a blocker'::text)),
  ('dev_queue.wait_msg',       to_jsonb('⏸ Parked — {reason}. The work is committed and untouched; it resumes automatically when the blocker clears (checked every {after}s).'::text)),
  ('dev_queue.wait_clear_msg', to_jsonb('▶ Resuming — {reason}. Picking up at the first unfinished step.'::text)),
  ('dev_queue.fail_unclassified', to_jsonb('Unclassified error'::text)),
  ('dev_queue.spec_title',     to_jsonb('Spec checklist'::text)),
  ('dev_queue.spec_chip',      to_jsonb('Spec {done}/{total}'::text)),
  ('dev_queue.spec_open',      to_jsonb('Open'::text)),
  ('dev_queue.spec_done',      to_jsonb('Built'::text)),
  ('dev_queue.spec_dropped',   to_jsonb('Dropped'::text)),
  ('dev_queue.spec_empty',     to_jsonb('This spec has no enumerated items — the step plan is the checklist.'::text)),
  ('dev_queue.spec_block',     to_jsonb('{n} spec item(s) still open: {items} — build them, or drop each with a reason'::text))
on conflict (key) do update set value = excluded.value;

-- ── M. CONFIG DEFAULTS (knobs, no deploy) ─────────────────────────────────
update dev_runner_config
   set value = jsonb_set(
         jsonb_set(value, '{wait_gate}',
           coalesce(value->'wait_gate','{}'::jsonb)
           || jsonb_build_object('enabled', true, 'max_parks', 6, 'max_park_minutes', 45), true),
         '{spec_gate}',
         coalesce(value->'spec_gate','{}'::jsonb)
         || jsonb_build_object('enforce', true, 'min_items', 2, 'max_items', 20), true)
 where key = 'worker_pool';

-- ── N. THE CARD RENDERS BOTH NEW STATES, VERBATIM ─────────────────────────
-- Same dev_cmd_list, plus the wait chip and the spec-checklist chip. Every
-- string is composed HERE; the Flutter card prints what it is handed.
CREATE OR REPLACE FUNCTION public.dev_cmd_list(p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_batch text DEFAULT NULL::text, p_limit integer DEFAULT 100)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
    order by dc.created_at desc, dc.id desc limit p_limit
  ) t;
  select coalesce(jsonb_object_agg(status, n), '{}') into v_counts from (select status, count(*) n from dev_commands group by status) c;
  return jsonb_build_object('rows', v_rows, 'counts', v_counts, 'screen_title', 'Dev Queue');
end $function$;

-- ── O. THE WATCHDOG MUST NOT FAIL A ROW THAT IS WAITING ───────────────────
-- dev_cmd_watchdog re-queues a `building` row whose heartbeat is 15 minutes
-- old, and FAILS it the second time. A parked row is deliberately silent —
-- its session was released on purpose — so without this it would be failed by
-- the watchdog for exactly the reason #571 exists to stop. dev_cmd_wait_sweep
-- owns parked rows; the watchdog skips them. Patched in place (idempotent) so
-- the rest of that 8 KB function keeps whatever it grows next.
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.dev_cmd_watchdog()'::regprocedure);
  if position('WAIT_STATE IS DISTINCT FROM ''parked''' in upper(d)) = 0 then
    d := replace(d,
      'FROM dev_commands WHERE status=''building'' LOOP',
      'FROM dev_commands WHERE status=''building'' AND wait_state IS DISTINCT FROM ''parked'' LOOP');
    execute d;
  end if;
end $do$;
