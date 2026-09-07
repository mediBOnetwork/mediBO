-- CMD #1852 (f) — THE OUTCOME, IN THE BACKEND'S OWN WORDS.
--
-- Until now End & purge answered with one sentence and the banner showed it in
-- a snackbar. That is not a report: it never said what was REVERSED, and it
-- never said whether the before and after fingerprints agreed — which is the
-- only thing that makes a purge provable rather than hopeful.
--
-- test_session_outcome() renders the whole verdict: every label, every value,
-- every tone and the close button. Dart chooses no word and no colour.

begin;

create or replace function public.test_session_outcome(p_session bigint)
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $fn$
declare s public.test_sessions%rowtype; p jsonb; v_lines jsonb := '[]'::jsonb;
        v_swept bigint; v_undo_err bigint; v_clean boolean; v_fp jsonb;
begin
  select * into s from public.test_sessions where id = p_session;
  if not found then return jsonb_build_object('has', false); end if;
  p := coalesce(s.proof, '{}'::jsonb);
  if not (p ? 'clean') then
    -- Ended but not yet finished purging: say exactly that, and say it once.
    return jsonb_build_object(
      'has', true,
      'title', public.uic('test_session.result_running','Still purging'),
      'tone', 'warning',
      'lines', jsonb_build_array(jsonb_build_object(
        'label', public.uic('test_session.reversed_label','Writes reversed'),
        'value', coalesce(s.purge_state #>> '{undo,reversed}', '0'),
        'tone',  'neutral')),
      'verdict', public.uic('test_session.end_purge_partial',''),
      'verdict_tone', 'warning',
      'close', public.uic('test_session.result_close','Done'));
  end if;

  v_clean := coalesce((p->>'clean')::boolean, false);
  v_fp    := coalesce(p->'fingerprint', '{}'::jsonb);
  select coalesce(sum((e.value)::text::bigint), 0) into v_swept
    from jsonb_each(coalesce(p->'rows_deleted','{}'::jsonb)) e;
  v_undo_err := coalesce((p #>> '{undo,failed_total}')::bigint, 0);

  v_lines := jsonb_build_array(
    jsonb_build_object(
      'label', public.uic('test_session.reversed_label','Writes reversed'),
      'value', coalesce(p #>> '{undo,reversed}', '0'),
      'tone',  'neutral'),
    jsonb_build_object(
      'label', public.uic('test_session.swept_label','Rows removed by the sweep'),
      'value', v_swept::text,
      'tone',  'neutral'),
    jsonb_build_object(
      'label', public.uic('test_session.files_removed_label','Files removed'),
      'value', coalesce(p->>'files_deleted','0'),
      'tone',  'neutral'),
    jsonb_build_object(
      'label', public.uic('test_session.residue_label','Rows still held'),
      'value', coalesce(p #>> '{residue,total}', '0'),
      'tone',  case when coalesce((p #>> '{residue,total}')::bigint,0) > 0 then 'danger' else 'success' end));

  if v_undo_err > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'label', public.uic('test_session.undo_failed_label','Writes that would not reverse'),
      'value', v_undo_err::text,
      'tone',  'danger'));
  end if;

  return jsonb_build_object(
    'has', true,
    'title', case when v_clean
      then public.uic('test_session.result_clean_title','Test session purged')
      else public.uic('test_session.result_dirty_title','Purge incomplete') end,
    'tone', case when v_clean then 'success' else 'danger' end,
    'lines', v_lines,
    -- The fingerprint sentence IS the proof. It names the table when the two
    -- do not agree, and it never reads as success over a mismatch.
    'verdict', coalesce(nullif(v_fp->>'line',''),
                        public.uic('test_session.fp_unavailable','')),
    'verdict_tone', coalesce(nullif(v_fp->>'tone',''), 'neutral'),
    'close', public.uic('test_session.result_close','Done'));
end $fn$;

create or replace function public.test_session_end_purge(p_session bigint default null)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $fn$
declare v_id bigint; v_purge jsonb; v_uid uuid; v_kind text; v_mine boolean;
begin
  v_id := coalesce(p_session, public.test_session_mine());
  if v_id is null then
    return jsonb_build_object('ok',true,'already',true,
      'message', public.uic('test_session.already_off','Test mode is already off.'));
  end if;
  if not (public._test_session_participant(v_id) or public._test_guard()) then
    return jsonb_build_object('ok',false,'error','not_owner',
      'message', public.uic('test_session.not_owner',
        'Only the device that started this session, or an admin, can end it.'));
  end if;

  v_kind := public._test_caller_origin();
  begin v_uid := auth.uid(); exception when others then v_uid := null; end;
  v_mine := coalesce(public.test_session_mine() = v_id, false);
  update public.test_sessions
     set status = case when status='live' then 'ended' else status end,
         ended_at = coalesce(ended_at, now()),
         ended_by = coalesce(ended_by, v_uid),
         ended_kind = coalesce(ended_kind, v_kind)
   where id = v_id;

  perform set_config('request.jwt.claim.role', 'service_role', true);
  v_purge := public.test_session_purge(v_id, 20000);

  return jsonb_build_object('ok', coalesce((v_purge->>'ok')::boolean, false),
    'session_id', v_id,
    'ended', true,
    'clear_token', v_mine,
    'purge', v_purge,
    'done', coalesce((v_purge->>'done')::boolean, false),
    -- CMD #1852 — the banner shows the whole verdict, not a one-line snackbar.
    'outcome', public.test_session_outcome(v_id),
    'message', case when coalesce((v_purge->>'done')::boolean, false)
      then public.uic('test_session.end_purged','Test session ended and its rows purged.')
      else public.uic('test_session.end_purge_partial','Session ended; the purge is still running — tap again to finish.') end);
end $fn$;

revoke all on function public.test_session_outcome(bigint) from public, anon;
grant execute on function public.test_session_outcome(bigint) to authenticated, service_role;
revoke all on function public.test_session_end_purge(bigint) from public, anon;
grant execute on function public.test_session_end_purge(bigint) to authenticated, service_role;

insert into public.ui_copy (key, value) values
  ('test_session.result_clean_title',  to_jsonb('Test session purged'::text)),
  ('test_session.result_dirty_title',  to_jsonb('Purge incomplete'::text)),
  ('test_session.result_running',      to_jsonb('Still purging'::text)),
  ('test_session.result_close',        to_jsonb('Done'::text)),
  ('test_session.swept_label',         to_jsonb('Rows removed by the sweep'::text)),
  ('test_session.files_removed_label', to_jsonb('Files removed'::text)),
  ('test_session.undo_failed_label',   to_jsonb('Writes that would not reverse'::text)),
  ('test_session.end_purge_partial',   to_jsonb('Session ended; the purge is still running — tap again to finish.'::text))
on conflict (key) do update set value = excluded.value;

commit;
