-- CMD #1852 (g) — THE PROOF.
--
-- Every claim this command makes, executed against the real triggers, the real
-- journal and the real purge, on a fixture where a REAL row sits in the same
-- table as the test rows. Nothing here is asserted from source.
--
-- It cleans up after itself, including the deliberately-dirty fixture of
-- check 6, and it never leaves a session behind.

begin;

create or replace function public.c1852_proof()
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $fn$
declare v_checks jsonb := '[]'::jsonb; v_pass boolean; v_detail text;
        v_sess bigint; v_real bigint; v_test bigint; v_fp text; v_n bigint;
        v_undo jsonb; v_purge jsonb; v_diff jsonb; v_before jsonb; v_after jsonb;
        v_a jsonb; v_b jsonb; v_hashed boolean;
begin
  if not public._test_guard() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  ------------------------------------------------------------------ 1. no session, no journal
  -- Run FIRST, before any fixture session exists: with nothing live, the write
  -- path must be byte-identical to production and must journal nothing.
  if public._test_session_ambient() is not null then
    v_checks := v_checks || jsonb_build_array(jsonb_build_object(
      'name','no_session_no_journal','pass',false,
      'detail','a test session was already live — rerun with no session open'));
  else
    select count(*) into v_n from public.test_session_journal;
    insert into public.notification_log (event_key, recipient, channel, status)
    values ('c1852_proof_nosess','x','test','queued') returning id into v_real;
    update public.notification_log set status='sent' where id = v_real;
    delete from public.notification_log where id = v_real;
    select count(*) - v_n into v_n from public.test_session_journal;
    v_checks := v_checks || jsonb_build_array(jsonb_build_object(
      'name','no_session_no_journal','pass',(v_n = 0),
      'detail', format('insert+update+delete with no session wrote %s journal rows (want 0)', v_n)));
  end if;

  ------------------------------------------------------------------ the fixture
  insert into public.notification_log (event_key, recipient, channel, status)
  values ('c1852_proof_real','x','test','queued') returning id into v_real;
  select md5(x::text) into v_fp from public.notification_log x where id = v_real;

  insert into public.test_sessions (label, scope, origin, status, expires_at, before_fp)
  values ('c1852 proof', 'automated', 'automated', 'live',
          now() + interval '10 minutes', public.test_fingerprint())
  returning id into v_sess;

  -- The session writes: it creates rows, it TOUCHES the real row, and it
  -- DELETES the real row. Everything a delete-by-id purge cannot put back.
  insert into public.notification_log (event_key, recipient, channel, status)
  values ('c1852_proof_t1','x','test','queued') returning id into v_test;
  insert into public.notification_log (event_key, recipient, channel, status, parent_log_id)
  values ('c1852_proof_t2','x','test','queued', v_test);
  update public.notification_log set status='sent', reason='changed by the test' where id = v_real;
  delete from public.notification_log where id = v_real;

  ------------------------------------------------------------------ 2. the journal recorded it
  select count(*) into v_n from public.test_session_journal where session_id = v_sess;
  v_pass := (v_n = 4)
    and exists (select 1 from public.test_session_journal
                 where session_id=v_sess and op='U' and before_row->>'status' = 'queued')
    and exists (select 1 from public.test_session_journal
                 where session_id=v_sess and op='D' and before_row->>'status' = 'sent');
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'name','journal_records_prior_state','pass',v_pass,
    'detail', format('%s entries; the U carries status=queued and the D carries status=sent', v_n)));

  ------------------------------------------------------------------ 3. resumable
  -- A zero budget reverses exactly one entry and stops. The second call must
  -- carry on from the cursor rather than restart or give up.
  v_undo := public.test_session_undo(v_sess, 0);
  v_pass := (coalesce((v_undo->>'done')::boolean,true) = false)
            and coalesce((v_undo->>'reversed')::int,0) = 1;
  v_detail := format('first pass reversed %s, remaining %s',
                     v_undo->>'reversed', v_undo->>'remaining');
  v_undo := public.test_session_undo(v_sess, 20000);
  v_pass := v_pass and coalesce((v_undo->>'done')::boolean,false)
            and coalesce((v_undo->>'errors')::int,1) = 0;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'name','purge_resumes_from_cursor','pass',v_pass,
    'detail', v_detail || format('; resumed pass reversed %s, errors %s, done %s',
                                 v_undo->>'reversed', v_undo->>'errors', v_undo->>'done')));

  ------------------------------------------------------------------ 4. the real row is untouched
  select md5(x::text) into v_detail from public.notification_log x where id = v_real;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'name','adjacent_real_row_byte_identical','pass',(v_detail is not null and v_detail = v_fp),
    'detail', case when v_detail is null then 'the real row was not put back at all'
                   when v_detail = v_fp then 'updated and deleted by the test, restored byte-identical'
                   else 'the row is back but its content differs' end));

  ------------------------------------------------------------------ 5. nothing of the session is left
  select count(*) into v_n from public.notification_log where test_session_id = v_sess;
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'name','session_rows_gone','pass',(v_n = 0),
    'detail', format('%s rows still carry the session stamp (want 0)', v_n)));

  ------------------------------------------------------------------ 6. a mismatch is never success
  -- Force one journal entry to look already-reversed, so the real row stays
  -- changed. The purge must refuse to call that clean and must NAME the table.
  --
  -- Both of the reversal's transaction-local settings are still in force:
  -- `medibo.test_purging` is ON and session_replication_role is 'replica', so
  -- EVERY trigger is off. That is right in production, where a purge is the
  -- last thing its transaction does; it is fatal here, where this one function
  -- keeps writing afterwards. Without clearing them the fixture below is
  -- silently not journalled and check 6 passes for entirely the wrong reason.
  perform set_config('medibo.test_purging', 'off', true);
  set local session_replication_role = 'origin';
  update public.test_sessions set status='live', ended_at=null, purge_started_at=null,
         purge_state='{}'::jsonb, purged_at=null, proof=null,
         before_fp = public.test_fingerprint(), expires_at = now() + interval '10 minutes'
   where id = v_sess;
  delete from public.test_session_journal where session_id = v_sess;
  update public.notification_log set status='sent', reason='left behind on purpose' where id = v_real;
  update public.test_session_journal set undone_at = now()
   where session_id = v_sess and undone_at is null;
  select coalesce((before_fp #>> '{notification_log,hashed}')::boolean, false)
    into v_hashed from public.test_sessions where id = v_sess;
  v_purge := public.test_session_purge(v_sess, 20000);
  -- The table must be NAMED when it was content-hashed. Above the hash budget
  -- only the row count is measured, and this fixture changes no row count —
  -- so the check asserts what was actually measurable and says which.
  v_pass := (coalesce((v_purge->>'clean')::boolean, true) = false)
            and (not v_hashed or (v_purge #>> '{fingerprint,line}') like '%notification_log%');
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'name','mismatch_is_never_reported_clean','pass',v_pass,
    'detail', format('hashed=%s, clean=%s, verdict=%s',
                     v_hashed, v_purge->>'clean', v_purge #>> '{fingerprint,line}')));

  ------------------------------------------------------------------ 7. content, not just ids
  v_a := jsonb_build_object('_v', 2, 'orders', jsonb_build_object('n', 5, 'h', 'aaa', 'hashed', true));
  v_b := jsonb_build_object('_v', 2, 'orders', jsonb_build_object('n', 5, 'h', 'bbb', 'hashed', true));
  v_diff := public.test_fingerprint_diff(v_a, v_b, array['orders']);
  v_pass := (coalesce((v_diff->>'matched')::boolean, true) = false)
            and (v_diff->>'line') like '%orders%';
  v_checks := v_checks || jsonb_build_array(jsonb_build_object(
    'name','content_change_with_same_row_count_is_caught','pass',v_pass,
    'detail', format('same count, different content -> matched=%s', v_diff->>'matched')));

  ------------------------------------------------------------------ tidy up
  perform set_config('medibo.test_purging', 'on', true);
  update public.notification_log set status='queued', reason=null where id = v_real;
  delete from public.notification_log where event_key like 'c1852_proof%';
  delete from public.test_session_journal where session_id = v_sess;
  delete from public.test_sessions where id = v_sess;

  select bool_and((c->>'pass')::boolean) into v_pass from jsonb_array_elements(v_checks) c;
  return jsonb_build_object(
    'ok', coalesce(v_pass, false),
    'checks', v_checks,
    'total', jsonb_array_length(v_checks),
    'failed', (select count(*) from jsonb_array_elements(v_checks) c where (c->>'pass')::boolean is not true));
end $fn$;

revoke all on function public.c1852_proof() from public, anon, authenticated;
grant execute on function public.c1852_proof() to service_role;

commit;
