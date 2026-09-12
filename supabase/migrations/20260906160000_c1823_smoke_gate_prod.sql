-- CHANGE #1823 — the critical-path smoke gate was switched off by its own
-- reporting bug. Measured on the box, 6 Sep 2026: every batch ended with
-- "critical-path smoke could not run (exit 2) — not treated as a failure".
-- The run did not fail to start; it found two real reds and then died in
-- test_result_report on feature_gaps_identity_uk (23505), and the merge worker
-- forgave the crash. This file fixes what the reds were made of:
--
--   1. _trg_test_result_gap upserts on the identity key — a gap that was
--      closed and fails again is REOPENED, never a duplicate-key abort.
--   2. The red itself: test_sim_supplier_answer -> inquiry_broadcast_to_oi
--      updated every order line with the same product and date, including
--      synthetic lines whose order an earlier purge had already deleted
--      (replica mode, no cascade) — 23503 on order_items_order_id_fkey1.
--      The broadcast now stays on its own side of is_synthetic, the purge
--      deletes a session's lines before its orders and sweeps orphans, the
--      pipeline stamps lines + inquiries with the session, and the four
--      orphans on live are removed here.
--   3. qa_test_identities.super_admin points at test.super@medibo.in and is
--      ready, so the super_admin journeys run instead of reporting BLOCKED.
-- Idempotent: every statement is create-or-replace / conditional.

CREATE OR REPLACE FUNCTION public._trg_test_result_gap()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_f record; v_shot text; v_console text; v_net jsonb; v_id bigint;
begin
  if new.verdict is distinct from 'failed' then return new; end if;

  select feature_key, label, surface, test_entry into v_f
    from public.feature_registry where feature_key = new.feature_key;

  v_shot := coalesce(
    (select s->>'shot' from jsonb_array_elements(coalesce(new.steps,'[]'::jsonb)) s
      where coalesce((s->>'ok')::boolean,true) = false and coalesce(s->>'shot','') <> ''
      limit 1),
    (select a from jsonb_array_elements_text(coalesce(new.artifacts->'shots','[]'::jsonb)) a
      order by a desc limit 1),
    '');
  v_console := left(coalesce(
    (select string_agg(c, E'\n') from jsonb_array_elements_text(
       coalesce(new.artifacts->'console','[]'::jsonb)) c), ''), 4000);
  v_net := coalesce(new.artifacts->'network', '[]'::jsonb);

  -- One OPEN gap per (feature, role, scenario). A failure that is still open
  -- is refreshed with the newest evidence rather than stacked, so the list
  -- stays the list of broken things instead of a log of every nightly run.
  select id into v_id from public.feature_gaps
   where status = 'open' and feature_key = new.feature_key
     and coalesce(role,'') = coalesce(new.role,'')
     and coalesce(scenario,'') = coalesce(new.scenario,'')
   order by id desc limit 1;

  if v_id is not null then
    update public.feature_gaps
       set test_result_id = new.id, test_run_id = new.run_id,
           evidence = left(coalesce(new.error,''), 4000),
           screenshot = v_shot, console_error = v_console, network_trace = v_net,
           repro = public._test_repro(new), updated_at = now(),
           seen_count = coalesce(seen_count,1) + 1, last_seen_at = now()
     where id = v_id;
    return new;
  end if;

  -- CHANGE #1823: the identity key (surface, journey_step, title) is unique
  -- across EVERY status. A gap that was closed by a passing run and now fails
  -- again has the same title, so a plain insert raised 23505 — and because
  -- this fires inside test_result_report, the whole smoke run died on it,
  -- AFTER finding two real reds, and the merge worker read the crash as
  -- "could not run" and shipped. Reporting the same gap twice is normal; it
  -- REOPENS the row, bumps seen_count and carries the newest evidence.
  insert into public.feature_gaps
    (surface, journey_step, title, type, severity, evidence, suggestion, effort_guess,
     status, found_at, updated_at,
     test_result_id, test_run_id, feature_key, role, scenario,
     screenshot, console_error, network_trace, repro, seen_count, last_seen_at)
  values (
    public._test_gap_surface(v_f.surface, new.role),
    coalesce(nullif(new.scenario,''),'happy_path'),
    format('%s failed for %s (%s)',
           coalesce(v_f.label, new.feature_key),
           coalesce(nullif(new.role,''),'anon'),
           coalesce(nullif(new.scenario,''),'happy_path')),
    case when coalesce(new.scenario,'') like 'hostile:%' then 'partial' else 'broken' end,
    case when coalesce(new.scenario,'') = 'deny' then 'high'
         when coalesce(new.scenario,'') = 'happy_path' then 'high'
         else 'medium' end,
    left(coalesce(new.error,''), 4000),
    'Reproduce with the command in repro.command, then fix the step that says ok:false.',
    'unknown', 'open', now(), now(),
    new.id, new.run_id, new.feature_key, new.role, coalesce(nullif(new.scenario,''),'happy_path'),
    v_shot, v_console, v_net, public._test_repro(new), 1, now())
  on conflict (surface, coalesce(journey_step, ''), title) do update
     set status         = 'open',
         test_result_id = excluded.test_result_id,
         test_run_id    = excluded.test_run_id,
         feature_key    = excluded.feature_key,
         role           = excluded.role,
         scenario       = excluded.scenario,
         evidence       = excluded.evidence,
         screenshot     = excluded.screenshot,
         console_error  = excluded.console_error,
         network_trace  = excluded.network_trace,
         repro          = excluded.repro,
         seen_count     = coalesce(public.feature_gaps.seen_count,1) + 1,
         last_seen_at   = now(),
         updated_at     = now(),
         notes          = coalesce(nullif(public.feature_gaps.notes,'') || ' · ', '')
                          || 'reopened by run ' || excluded.test_run_id || ' — the same journey failed again';
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.inquiry_broadcast_to_oi()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  perform set_config('medibo.in_broadcast','1',true);

  if public._inq_confirmed(NEW) then
    update public.order_items oi
       set assigned_supplier = NEW.current_supplier,
           inquiry_id        = coalesce(oi.inquiry_id, NEW.id)
     where oi.product_id = NEW.product_id
       -- CHANGE #1823: a synthetic inquiry answers synthetic lines and only those;
       -- a real one never touches a test order. Same product, same day is not
       -- the same order book.
       and coalesce(oi.is_synthetic,false) = coalesce(NEW.is_synthetic,false)
       and oi.order_date = NEW.batch_date
       and oi.fulfillment_state <> 'cancelled'
       and not coalesce(oi.received_locked,false);
  else
    update public.order_items oi
       set assigned_supplier = null
     where oi.inquiry_id = NEW.id
       and coalesce(oi.is_synthetic,false) = coalesce(NEW.is_synthetic,false)
       and oi.order_date = NEW.batch_date
       and oi.fulfillment_state <> 'cancelled'
       and not coalesce(oi.received_locked,false)
       and coalesce(oi.at_warehouse,false) = false
       and coalesce(oi.packed,false) = false;
  end if;

  perform set_config('medibo.in_broadcast','0',true);
  return NEW;
end;
$function$;

CREATE OR REPLACE FUNCTION public.test_session_purge(p_session bigint DEFAULT NULL::bigint, p_budget_ms integer DEFAULT 20000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id bigint; s public.test_sessions%rowtype;
        v_tables text[]; v_i int; v_done boolean := true;
        t text; n bigint; v_deleted jsonb; v_files bigint;
        r record; v_paths text[]; v_bucket text; v_started timestamptz := clock_timestamp();
        v_after jsonb; v_res jsonb; v_clean boolean;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  -- A purge must be INERT. Deleting a synthetic inquiry row fired
  -- trg_inquiry_rebuild_spo -> inquiry_engine_sync(), which rewrites every
  -- inquiry_forms row on the platform; the first live purge died on a lock
  -- timeout there. Nothing downstream should react to a test row LEAVING —
  -- it was never real. Replica mode is transaction-local and only covers the
  -- deletes below.
  begin
    set local session_replication_role = 'replica';
  exception when others then null;   -- not permitted here: fall back to plain deletes
  end;
  set local lock_timeout = '5s';

  v_id := coalesce(p_session, public.test_session_live_id());
  if v_id is null then
    return jsonb_build_object('ok',false,'error','no_session',
      'message', public.uic('test_session.no_session','There is no test session to purge.'));
  end if;
  select * into s from public.test_sessions where id = v_id;
  if not found then return jsonb_build_object('ok',false,'error','no_session'); end if;

  -- Ending is implicit: you cannot purge a run you are still inside.
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         purge_started_at = coalesce(purge_started_at, now())
   where id = v_id;

  v_tables  := public._test_session_tables();
  v_i       := coalesce((s.purge_state->>'i')::int, 0);
  v_deleted := coalesce(s.purge_state->'deleted', '{}'::jsonb);
  v_files   := coalesce((s.purge_state->>'files')::bigint, 0);

  -- Step 0 — the storage objects, BEFORE the rows that point at them.
  if v_i = 0 then
    for r in select * from public.test_storage_rule loop
      if not exists (select 1 from information_schema.columns
                      where table_schema='public' and table_name=r.src_table and column_name='test_session_id')
        then continue; end if;
      begin
        execute format(
          'select coalesce(array_agg(distinct %I), ''{}'') from public.%I
             where test_session_id = $1 and %I is not null and %I <> ''''',
          r.path_col, r.src_table, r.path_col, r.path_col)
          into v_paths using v_id;
      exception when others then v_paths := '{}'; end;
      if coalesce(array_length(v_paths,1),0) = 0 then continue; end if;

      if r.bucket is not null then
        v_files := v_files + public._test_storage_delete(r.bucket, v_paths);
      else
        for v_bucket in
          execute format('select distinct %I from public.%I where test_session_id = $1 and %I is not null',
                         r.bucket_col, r.src_table, r.bucket_col) using v_id
        loop
          v_files := v_files + public._test_storage_delete(v_bucket, v_paths);
        end loop;
      end if;
    end loop;
    v_i := 1;
  end if;

  -- Steps 1..N — the rows, in dependency order, one table per step so an
  -- interrupted purge resumes at the table it stopped on.
  while v_i <= array_length(v_tables,1) loop
    t := v_tables[v_i];
    if exists (select 1 from information_schema.columns
                where table_schema='public' and table_name=t and column_name='test_session_id') then
      -- CHANGE #1823: this purge runs in replica mode, so ON DELETE CASCADE
      -- never fires. An order the session stamped whose lines were NOT stamped
      -- (the bot's pipeline stamps the order after the fact, its lines were
      -- written under no auth.uid()) left orphan order_items behind; the next
      -- run's supplier-answer broadcast then touched those orphans and died on
      -- order_items_order_id_fkey1. The lines go first, whatever they carry.
      if t = 'orders' then
        delete from public.order_items oi
         where oi.order_id in (select o.id from public.orders o where o.test_session_id = v_id);
        get diagnostics n = row_count;
        if n > 0 then
          v_deleted := v_deleted || jsonb_build_object('order_items', coalesce((v_deleted->>'order_items')::bigint,0) + n);
        end if;
      end if;
      execute format('delete from public.%I where test_session_id = $1', t) using v_id;
      get diagnostics n = row_count;
      if n > 0 then
        v_deleted := v_deleted || jsonb_build_object(t, coalesce((v_deleted->>t)::bigint,0) + n);
      end if;
    end if;
    v_i := v_i + 1;
    if extract(epoch from (clock_timestamp() - v_started)) * 1000 > p_budget_ms
       and v_i <= array_length(v_tables,1) then
      v_done := false;
      exit;
    end if;
  end loop;

  update public.test_sessions
     set purge_state = jsonb_build_object('i', v_i, 'deleted', v_deleted, 'files', v_files)
   where id = v_id;

  if not v_done then
    return jsonb_build_object('ok',true,'done',false,'session_id',v_id,
      'deleted',v_deleted,'files',v_files,
      'message', public.uic('test_session.purge_more','Still purging — tap again to continue.'));
  end if;

  -- CHANGE #1823: whatever an earlier purge left dangling. Synthetic lines
  -- whose order is gone are residue by definition, never business data.
  delete from public.order_items oi
   where coalesce(oi.is_synthetic,false)
     and not exists (select 1 from public.orders o where o.id = oi.order_id);

  -- Finished: the run ledger, then the proof.
  delete from public.test_event  where run_id in (select id from public.test_run where test_session_id = v_id);
  delete from public.test_run    where test_session_id = v_id;
  delete from public.synthetic_blocked_write
   where created_at >= s.started_at
     and created_at <= coalesce(s.ended_at, now());

  v_after := public.test_fingerprint();
  v_res   := public.test_session_residue(v_id);
  v_clean := (coalesce((v_res->>'total')::bigint,0) = 0)
             and (coalesce((v_res->>'files')::bigint,0) = 0)
             and (s.before_fp is null or s.before_fp = v_after);

  update public.test_sessions
     set status='purged', purged_at=now(), after_fp=v_after,
         proof = jsonb_build_object(
           'clean', v_clean,
           'rows_deleted', v_deleted,
           'files_deleted', v_files,
           'residue', v_res,
           'business_unchanged', (s.before_fp is not null and s.before_fp = v_after),
           'tables_compared', (select count(*) from jsonb_object_keys(v_after)))
   where id = v_id;

  return jsonb_build_object('ok',true,'done',true,'session_id',v_id,
    'deleted',v_deleted,'files',v_files,'clean',v_clean,'residue',v_res,
    'business_unchanged',(s.before_fp is not null and s.before_fp = v_after),
    'message', case when v_clean
      then public.uic('test_session.purged_clean','Purged. Nothing of that session is left and no business row moved.')
      else public.uic('test_session.purged_dirty','Purged, but something is still left — open the session to see what.') end);
end $function$;

CREATE OR REPLACE FUNCTION public.test_pipeline_run(p_run_id bigint DEFAULT NULL::bigint, p_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v jsonb; v_order uuid := p_order_id; v_stages jsonb := '[]'::jsonb;
        v_ok boolean := true; v_failed text := ''; v_legacy bigint; v_blocked boolean := false;
begin
  perform public._dev_guard();
  if not public.test_mode_on() then
    return jsonb_build_object('ok', false, 'error','test_mode_off',
      'message', public.uic('test_mode.off','Test mode is switched off.'));
  end if;

  v_legacy := public.test_run_open('CHANGE #635 — 9-stage pipeline', 'manual');

  for r in select * from public.test_pipeline_stage where is_active order by sort_order loop
    if r.stage_key = 'placed' and v_order is not null then
      v := jsonb_build_object('ok', true, 'detail','order supplied by the caller');
    else
      v := public.test_sim_stage(v_order, r.stage_key, v_legacy);
    end if;
    if r.stage_key = 'placed' and v_order is null then
      v_order := nullif(v->>'order_id','')::uuid;
    end if;
    v_stages := v_stages || jsonb_build_object(
      'stage_key', r.stage_key, 'label', r.label, 'sort_order', r.sort_order,
      'ok', coalesce((v->>'ok')::boolean, false),
      'blocked', coalesce((v->>'blocked')::boolean, false),
      'detail', coalesce(v->>'detail', v->>'error', ''),
      'tone', case when coalesce((v->>'ok')::boolean,false) then 'success'
                   when coalesce((v->>'blocked')::boolean,false) then 'warning'
                   else 'danger' end);
    if not coalesce((v->>'ok')::boolean, false) then
      v_ok := false;
      v_blocked := coalesce((v->>'blocked')::boolean, false);
      if v_failed = '' then v_failed := r.stage_key; end if;
      exit;
    end if;
  end loop;

  update public.test_run
     set status = case when v_ok then 'passed' when v_blocked then 'blocked' else 'failed' end,
         ended_at = now(), order_id = v_order, steps = v_stages
   where id = v_legacy;

  if p_run_id is not null and v_order is not null then
    update public.orders
       set test_session_id = coalesce(test_session_id,
             (select test_session_id from public.test_runs where id = p_run_id))
     where id = v_order;
    -- CHANGE #1823: the lines and the inquiry rows carry the same stamp as the
    -- order, so the purge (replica mode, no cascade) removes the whole order.
    update public.order_items oi
       set test_session_id = coalesce(oi.test_session_id,
             (select test_session_id from public.test_runs where id = p_run_id))
     where oi.order_id = v_order;
    update public.inquiry i
       set test_session_id = coalesce(i.test_session_id,
             (select test_session_id from public.test_runs where id = p_run_id))
     where i.id in (select oi.inquiry_id from public.order_items oi where oi.order_id = v_order and oi.inquiry_id is not null);
  end if;

  return jsonb_build_object('ok', v_ok, 'blocked', v_blocked, 'order_id', v_order,
    'run_id', p_run_id, 'legacy_run_id', v_legacy,
    'stages', v_stages,
    'stages_total', (select count(*) from public.test_pipeline_stage where is_active),
    'stages_passed', (select count(*) from jsonb_array_elements(v_stages) s where (s->>'ok')::boolean),
    'failed_stage', nullif(v_failed,''),
    'detail', case when v_ok then 'all 9 stages passed on a synthetic order'
                   when v_blocked then 'pipeline could not start at ' || v_failed || ': '
                        || coalesce((select s->>'detail' from jsonb_array_elements(v_stages) s
                                      where s->>'stage_key' = v_failed limit 1), '')
                   else 'pipeline stopped at ' || v_failed end);
end $function$;

-- 2c. The residue the old purge left behind on live (4 rows on 6 Sep 2026):
-- synthetic lines whose order is gone. Never business data.
delete from public.order_items oi
 where coalesce(oi.is_synthetic,false)
   and not exists (select 1 from public.orders o where o.id = oi.order_id);

-- 3. The super_admin test identity. The password lives beside the others in
-- ~/.medibo/autotest.env on the build VM (AUTOTEST_PASS_SUPER_ADMIN).
insert into public.qa_test_identities (role, identity, ready, note)
values ('super_admin', 'test.super@medibo.in', true,
        'password lives in ~/.medibo/autotest.env on the build VM')
on conflict (role) do update
   set identity = excluded.identity,
       ready    = true,
       note     = excluded.note
 where coalesce(public.qa_test_identities.identity,'') = '';
