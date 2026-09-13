-- CMD #1852 (d) — THE PURGE, REBUILT AROUND THE JOURNAL, AND ITS PROOF.
--
-- Order matters and is the argument:
--   0. storage objects, before the rows that point at them;
--   1. THE JOURNAL, replayed backwards — the exact reversal;
--   2. the #573 by-id sweep, kept as a BACKSTOP for rows the parent-inheritance
--      path stamped before this journal existed (an older session, a table
--      whose trigger was attached later). It only ever deletes rows carrying
--      the session's own stamp, so it can no more touch a pre-existing row
--      than the journal can;
--   3. after_fp, measured over EXACTLY the tables before_fp measured, and the
--      verdict.
--
-- `clean` is now four conditions, and every one of them is measured:
--   - no row is left carrying the session stamp;
--   - no file is left;
--   - every journal entry is reversed, and none of them recorded an error;
--   - no table the session TOUCHED differs from its before fingerprint.
-- A mismatch names the table. Success is never reported over one.

begin;

create or replace function public.test_session_purge(
  p_session bigint default null, p_budget_ms int default 20000)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $fn$
declare v_id bigint; s public.test_sessions%rowtype;
        v_tables text[]; v_i int; v_done boolean := true;
        t text; n bigint; v_deleted jsonb; v_files bigint;
        r record; v_paths text[]; v_bucket text; v_started timestamptz := clock_timestamp();
        v_after jsonb; v_res jsonb; v_clean boolean;
        v_undo jsonb; v_touched text[]; v_fp jsonb; v_left_budget int;
        v_journal_ok boolean; v_fp_ok boolean; v_fp_names text;
begin
  if not public._test_guard() then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  -- Nothing downstream reacts to a test row leaving, and NOTHING the purge
  -- does is itself journalled — a purge that journals its own deletes would
  -- give the next resumed pass a journal to undo, for ever.
  perform set_config('medibo.test_purging', 'on', true);
  begin
    set local session_replication_role = 'replica';
  exception when others then null;
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
      if not exists (select 1 from pg_attribute a
                      join pg_class c on c.oid = a.attrelid
                      join pg_namespace ns on ns.oid = c.relnamespace
                     where ns.nspname='public' and c.relname = r.src_table
                       and a.attname = 'test_session_id' and a.attnum > 0 and not a.attisdropped)
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

  -- Step 1 — THE JOURNAL, BACKWARDS. Half the budget, because the by-id sweep
  -- below is only a backstop and must never starve the exact reversal.
  v_left_budget := greatest(1000,
    p_budget_ms - (extract(epoch from (clock_timestamp() - v_started)) * 1000)::int);
  v_undo := public.test_session_undo(v_id, greatest(1000, v_left_budget / 2));
  select coalesce(array_agg(distinct table_name), '{}') into v_touched
    from public.test_session_journal where session_id = v_id;
  if not coalesce((v_undo->>'done')::boolean, false) then
    -- The journal is not finished. Save the cursor and come back — the sweep
    -- must not run over a half-reversed session.
    update public.test_sessions
       set purge_state = jsonb_build_object('i', v_i, 'deleted', v_deleted,
                                            'files', v_files, 'undo', v_undo)
     where id = v_id;
    return jsonb_build_object('ok',true,'done',false,'session_id',v_id,
      'deleted',v_deleted,'files',v_files,'undo',v_undo,
      'message', public.uic('test_session.purge_more','Still purging — tap again to continue.'));
  end if;

  -- Steps 2..N — the #573 backstop, one table per step so an interrupted purge
  -- resumes at the table it stopped on.
  while v_i <= array_length(v_tables,1) loop
    t := v_tables[v_i];
    if exists (select 1 from pg_attribute a
                join pg_class c on c.oid = a.attrelid
                join pg_namespace ns on ns.oid = c.relnamespace
               where ns.nspname='public' and c.relname = t
                 and a.attname = 'test_session_id' and a.attnum > 0 and not a.attisdropped) then
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
     set purge_state = jsonb_build_object('i', v_i, 'deleted', v_deleted,
                                          'files', v_files, 'undo', v_undo)
   where id = v_id;

  if not v_done then
    return jsonb_build_object('ok',true,'done',false,'session_id',v_id,
      'deleted',v_deleted,'files',v_files,'undo',v_undo,
      'message', public.uic('test_session.purge_more','Still purging — tap again to continue.'));
  end if;

  -- Finished: the run ledger, then the proof.
  delete from public.test_event  where run_id in (select id from public.test_run where test_session_id = v_id);
  delete from public.test_run    where test_session_id = v_id;
  delete from public.synthetic_blocked_write
   where created_at >= s.started_at
     and created_at <= coalesce(s.ended_at, now());

  -- after_fp is measured over EXACTLY the tables before_fp measured. Comparing
  -- two different table sets is how a fingerprint starts lying.
  v_after := public.test_fingerprint(20000,
    case when s.before_fp is null then null
         else array(select jsonb_object_keys(s.before_fp)) end);
  v_res   := public.test_session_residue(v_id);
  v_fp    := public.test_fingerprint_diff(s.before_fp, v_after, v_touched);

  select (count(*) filter (where undone_at is null) = 0
          and count(*) filter (where undo_error is not null) = 0)
    into v_journal_ok
    from public.test_session_journal where session_id = v_id;

  -- An unavailable comparison is NOT a pass. It is only excused when there was
  -- never a before fingerprint to compare with (a session opened before #1852).
  v_fp_ok := case
    when coalesce((v_fp->>'available')::boolean, false) then coalesce((v_fp->>'matched')::boolean, false)
    else s.before_fp is null end;

  v_clean := (coalesce((v_res->>'total')::bigint,0) = 0)
             and (coalesce((v_res->>'files')::bigint,0) = 0)
             and coalesce(v_journal_ok, false)
             and v_fp_ok;

  update public.test_sessions
     set status='purged', purged_at=now(), after_fp=v_after,
         proof = jsonb_build_object(
           'clean', v_clean,
           'rows_deleted', v_deleted,
           'files_deleted', v_files,
           'residue', v_res,
           'undo', v_undo,
           'journal_ok', coalesce(v_journal_ok, false),
           'touched', to_jsonb(coalesce(v_touched,'{}'::text[])),
           'fingerprint', v_fp,
           'business_unchanged', v_fp_ok,
           'tables_compared', coalesce((v_fp->>'checked')::int, 0))
   where id = v_id;

  return jsonb_build_object('ok',true,'done',true,'session_id',v_id,
    'deleted',v_deleted,'files',v_files,'clean',v_clean,'residue',v_res,
    'undo', v_undo, 'journal_ok', coalesce(v_journal_ok,false),
    'fingerprint', v_fp,
    'business_unchanged', v_fp_ok,
    'message', case when v_clean
      then public.uic('test_session.purged_clean','Purged. Nothing of that session is left and no business row moved.')
      else public.uic('test_session.purged_dirty','Purged, but something is still left — open the session to see what.') end);
end $fn$;

commit;
