-- CMD #1852 (c) — THE PURGE REPLAYS THE JOURNAL BACKWARDS.
--
-- Newest first. That order is the whole correctness argument: a cascade insert
-- is removed before the parent it hangs off, a counter is put back through the
-- same values it was walked up, and a row that the test deleted and then
-- re-created is re-created and then removed in the order that leaves the table
-- exactly where it started.
--
-- `delete from <table> where test_session_id = <id>` — #573's purge — cannot do
-- any of that. It is kept BELOW this, as a backstop for rows stamped by the
-- parent-inheritance path before this journal existed.
--
-- Idempotent, and interruptible at any row: `undone_at` on the journal entry IS
-- the resume cursor, so a purge that dies half-way carries on from the next
-- un-reversed entry rather than restarting or giving up.

begin;

-- The UPDATE that puts a row back to its recorded prior value. Every column
-- except the primary key and the generated ones, assigned from the before
-- image. Built from the catalog at reversal time, so a column added since the
-- journal entry was written is simply not in the image and is left alone.
--
-- It builds its OWN where clause rather than reusing _test_pk_where(), because
-- the statement joins the target to jsonb_populate_record() and both sides own
-- a column called `id`: an unqualified predicate fails with "column reference
-- \"id\" is ambiguous", which the per-row handler records as an undo_error and
-- the row stays changed. Qualify with the target alias.
drop function if exists public._test_restore_sql(oid, text, text);

create or replace function public._test_restore_sql(p_relid oid, p_table text, p_pk jsonb)
 returns text
 language plpgsql stable security definer set search_path to 'public', 'pg_catalog'
as $fn$
declare v_set text; v_where text;
begin
  select string_agg(format('%I = r.%I', a.attname, a.attname), ', ')
    into v_set
    from pg_attribute a
   where a.attrelid = p_relid and a.attnum > 0 and not a.attisdropped
     and a.attgenerated = ''
     and not exists (
       select 1 from pg_constraint c
        where c.conrelid = p_relid and c.contype = 'p' and a.attnum = any(c.conkey));
  if v_set is null then return null; end if;

  select string_agg(format('t.%I = %L::%s', e.key, e.value #>> '{}',
                           format_type(att.atttypid, att.atttypmod)), ' and ')
    into v_where
    from jsonb_each(p_pk) e
    join pg_attribute att on att.attrelid = p_relid and att.attname = e.key
   where not att.attisdropped and att.attnum > 0;
  if v_where is null then return null; end if;

  return format(
    'update public.%I as t set %s from jsonb_populate_record(null::public.%I, $1) as r where %s',
    p_table, v_set, p_table, v_where);
end $fn$;

-- ---------------------------------------------------------------------------
-- THE REVERSAL
-- ---------------------------------------------------------------------------
create or replace function public.test_session_undo(
  p_session bigint, p_budget_ms int default 8000)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $fn$
declare r record; v_started timestamptz := clock_timestamp();
        v_relid oid; v_where text; v_sql text;
        v_undone jsonb := '{}'::jsonb; v_n int := 0; v_err int := 0;
        v_left bigint; v_failed bigint; v_touched text[];
begin
  if p_session is null then
    return jsonb_build_object('ok', false, 'error', 'no_session');
  end if;

  -- The reversal is itself a set of writes on journalled tables. Without this
  -- flag it would journal its own undo, and the next resumed pass would undo
  -- the undo — a purge that oscillates instead of finishing.
  perform set_config('medibo.test_purging', 'on', true);
  -- Nothing downstream may react to a test row leaving: a synthetic inquiry
  -- delete used to fire inquiry_engine_sync() and rewrite every inquiry form on
  -- the platform. Replica mode is transaction-local and covers only this block.
  begin
    set local session_replication_role = 'replica';
  exception when others then null;
  end;
  set local lock_timeout = '5s';

  for r in
    select * from public.test_session_journal
     where session_id = p_session and undone_at is null
     order by id desc
  loop
    begin
      v_relid := to_regclass('public.' || quote_ident(r.table_name));
      if v_relid is null then
        update public.test_session_journal
           set undone_at = now(), undo_error = 'table_gone' where id = r.id;
        v_err := v_err + 1;
      else
        v_where := public._test_pk_where(v_relid, r.pk);
        if v_where is null then
          update public.test_session_journal
             set undone_at = now(), undo_error = 'no_pk' where id = r.id;
          v_err := v_err + 1;
        else
          if r.op = 'I' then
            -- The ONLY branch that deletes, and it can only ever be reached by
            -- an entry the session's own INSERT wrote. A row that predates the
            -- session has no 'I' entry and can therefore never be removed here.
            execute format('delete from public.%I where %s', r.table_name, v_where);
          elsif r.op = 'U' then
            v_sql := public._test_restore_sql(v_relid, r.table_name, r.pk);
            if v_sql is not null then
              execute v_sql using r.before_row;
            end if;
          else  -- 'D' — put back exactly what was removed
            execute format(
              'insert into public.%I select * from jsonb_populate_record(null::public.%I, $1)',
              r.table_name, r.table_name) using r.before_row;
          end if;
          update public.test_session_journal set undone_at = now() where id = r.id;
          v_undone := v_undone || jsonb_build_object(
            r.table_name, coalesce((v_undone->>r.table_name)::bigint, 0) + 1);
          v_n := v_n + 1;
        end if;
      end if;
    exception when others then
      -- A single row that will not reverse is RECORDED, not swallowed and not
      -- allowed to abandon the rest of the journal. It keeps undo_error, so the
      -- proof below can never call this purge clean.
      update public.test_session_journal
         set undone_at = now(), undo_error = left(sqlerrm, 300) where id = r.id;
      v_err := v_err + 1;
    end;
    exit when extract(epoch from (clock_timestamp() - v_started)) * 1000 > p_budget_ms;
  end loop;

  select count(*) into v_left  from public.test_session_journal
   where session_id = p_session and undone_at is null;
  select count(*) into v_failed from public.test_session_journal
   where session_id = p_session and undo_error is not null;
  select coalesce(array_agg(distinct table_name), '{}') into v_touched
    from public.test_session_journal where session_id = p_session;

  return jsonb_build_object(
    'ok', true,
    'done', (v_left = 0),
    'reversed', v_n,
    'by_table', v_undone,
    'errors', v_err,
    'failed_total', v_failed,
    'remaining', v_left,
    'touched', to_jsonb(v_touched));
end $fn$;

revoke all on function public._test_restore_sql(oid, text, jsonb) from public, anon, authenticated;
revoke all on function public.test_session_undo(bigint, int) from public, anon, authenticated;
grant execute on function public._test_restore_sql(oid, text, jsonb) to service_role;
grant execute on function public.test_session_undo(bigint, int) to service_role;

commit;
