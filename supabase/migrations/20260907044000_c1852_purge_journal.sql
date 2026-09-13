-- CMD #1852 — PURGE IS EXACT AND PROVABLE: AN UNDO JOURNAL, NOT A DELETE BY ID.
--
-- #573 built the session and a purge that issues `delete from <table> where
-- test_session_id = <id>` over a hand-written table list. That misses what the
-- test WRITES CAUSED rather than what they inserted: a counter bumped on a
-- real pharmacy row, an aggregate cache rewritten, a row a test deleted, a
-- table nobody remembered to put in the list. #573 also designed the honest
-- ending — before_fp, after_fp, purge_state, purge_started_at, purged_at are
-- all already columns on test_sessions — and never filled them in with
-- anything that could fail. This finishes it.
--
-- The shape:
--   1. Every write made INSIDE a live session is journalled (table, primary
--      key, op, and the whole prior row for an update or a delete).
--   2. The purge REPLAYS THE JOURNAL BACKWARDS. Newest first, so a cascade
--      insert is removed before its parent and a counter is put back in the
--      order it was bumped.
--   3. before_fp / after_fp are real fingerprints of the affected tables —
--      row count AND a hash over full row CONTENT, so a mutated counter is
--      caught, not just a missing id. Unequal is reported per table and is
--      never called success.
--   4. Expiry purges itself, and an interrupted purge resumes from the
--      journal cursor instead of restarting.
--   5. The journal is the ONLY authority on what is reversed. A DELETE can
--      only ever come from an 'I' entry, and an 'I' entry can only exist for
--      a row the session created — so a row that predates the session can be
--      put back, never removed.
--   6. No session, no journal write: the insert path reads one column that is
--      already in memory and returns.
--
-- Idempotent throughout — a resumed worker may re-apply it whole.

begin;

-- ---------------------------------------------------------------------------
-- 1. THE JOURNAL
-- ---------------------------------------------------------------------------
create table if not exists public.test_session_journal (
  id          bigserial primary key,
  session_id  bigint      not null,
  at          timestamptz not null default clock_timestamp(),
  table_name  text        not null,
  op          text        not null check (op in ('I','U','D')),
  pk          jsonb       not null,     -- {pk_col: text value} — composite-safe
  before_row  jsonb,                    -- the WHOLE prior row for U and D
  undone_at   timestamptz,
  undo_error  text
);

comment on table public.test_session_journal is
  'CMD #1852 — the undo journal. One row per write made while a test session '
  'was live, in journal order (id). The purge replays it backwards. It is the '
  'ONLY authority on what a purge may touch: an I entry (a row the session '
  'created) is the only entry that can produce a DELETE.';

-- The purge reads (session_id, id desc) and only the entries it has not
-- undone; that partial index IS the resume cursor.
create index if not exists test_session_journal_undo_idx
  on public.test_session_journal (session_id, id desc) where undone_at is null;
create index if not exists test_session_journal_sess_idx
  on public.test_session_journal (session_id, id desc);

alter table public.test_session_journal enable row level security;
-- No policy: reachable only through the SECURITY DEFINER functions below.
revoke all on table public.test_session_journal from public, anon, authenticated;
grant select, insert, update, delete on table public.test_session_journal to service_role;
grant usage, select on sequence public.test_session_journal_id_seq to service_role;

-- ---------------------------------------------------------------------------
-- 2. ADDRESSING A ROW — the primary key, from the catalog, never guessed
-- ---------------------------------------------------------------------------
-- pg_catalog and not information_schema: lesson #259 — information_schema is a
-- join over every object and this runs inside a per-row trigger.
create or replace function public._test_pk_of(p_relid oid, p_row jsonb)
 returns jsonb
 language plpgsql stable security definer set search_path to 'public', 'pg_catalog'
as $fn$
declare v jsonb;
begin
  select jsonb_object_agg(att.attname, to_jsonb(p_row ->> att.attname))
    into v
    from pg_constraint c
    join lateral unnest(c.conkey) k(attnum) on true
    join pg_attribute att on att.attrelid = c.conrelid and att.attnum = k.attnum
   where c.conrelid = p_relid and c.contype = 'p';
  if v is null then return null; end if;
  -- A null primary-key value is not an address. Skip rather than guess.
  if exists (select 1 from jsonb_each(v) e where e.value = 'null'::jsonb) then
    return null;
  end if;
  return v;
exception when others then
  return null;
end $fn$;

-- The WHERE clause that addresses exactly that row, each value cast to the
-- column's own type so the primary-key index is used.
create or replace function public._test_pk_where(p_relid oid, p_pk jsonb)
 returns text
 language plpgsql stable security definer set search_path to 'public', 'pg_catalog'
as $fn$
declare v text;
begin
  select string_agg(format('%I = %L::%s', e.key, e.value #>> '{}',
                           format_type(att.atttypid, att.atttypmod)), ' and ')
    into v
    from jsonb_each(p_pk) e
    join pg_attribute att on att.attrelid = p_relid and att.attname = e.key
   where not att.attisdropped and att.attnum > 0;
  return v;
end $fn$;

revoke all on function public._test_pk_of(oid, jsonb) from public, anon, authenticated;
revoke all on function public._test_pk_where(oid, jsonb) from public, anon, authenticated;
grant execute on function public._test_pk_of(oid, jsonb) to service_role;
grant execute on function public._test_pk_where(oid, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. THE JOURNAL TRIGGER
-- ---------------------------------------------------------------------------
-- AFTER, so it records what actually landed, and FOR EACH ROW, because the
-- reversal addresses rows one at a time.
--
-- THE REAL PATH IS UNTOUCHED, and that is a structural guarantee rather than a
-- promise: on INSERT the answer is one column of a row already in memory —
-- a0_synthetic_inherit (BEFORE) has already decided whether this write belongs
-- to a session, and an unstamped insert returns without reading a catalog, a
-- header or another table. Only an UPDATE or a DELETE of a row that carries NO
-- session stamp pays for the ambient lookup, and that lookup returns null on a
-- header read when this install carries no token.
create or replace function public._test_session_journal()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $fn$
declare v_sess bigint; v_pk jsonb; v_old jsonb;
begin
  -- The reversal is a write too. It must never journal itself, or a resumed
  -- purge would undo its own undo.
  if coalesce(current_setting('medibo.test_purging', true), '') = 'on' then
    return null;
  end if;

  if tg_op = 'INSERT' then
    v_sess := nullif(to_jsonb(new) ->> 'test_session_id', '')::bigint;
    if v_sess is null then return null; end if;          -- the real path, free
    v_pk := public._test_pk_of(tg_relid, to_jsonb(new));
    if v_pk is null then return null; end if;
    insert into public.test_session_journal (session_id, table_name, op, pk)
    values (v_sess, tg_table_name, 'I', v_pk);
    return null;
  end if;

  v_old  := to_jsonb(old);
  -- A row the session created carries its stamp: that is the session that owns
  -- the change, whoever is making it.
  v_sess := nullif(v_old ->> 'test_session_id', '')::bigint;
  if v_sess is null then
    -- A row that PREDATES the session. It is journalled only while the caller
    -- is inside one, and only so its prior value can be PUT BACK.
    v_sess := public._test_session_ambient();
    if v_sess is null then return null; end if;
  end if;

  v_pk := public._test_pk_of(tg_relid, v_old);
  if v_pk is null then return null; end if;
  insert into public.test_session_journal (session_id, table_name, op, pk, before_row)
  values (v_sess, tg_table_name,
          case tg_op when 'UPDATE' then 'U' else 'D' end, v_pk, v_old);
  return null;
exception when others then
  -- Test-mode bookkeeping may never fail a real write.
  return null;
end $fn$;

-- Attach to every table that can carry a session stamp. Same data-driven loop
-- as synthetic_trigger_attach_all(), so a table flagged tomorrow is covered by
-- re-running this and nothing else.
create or replace function public.test_journal_attach_all()
 returns int
 language plpgsql security definer set search_path to 'public', 'pg_catalog'
as $fn$
declare t text; n int := 0;
begin
  for t in
    select c.relname
      from pg_class c
      join pg_namespace ns on ns.oid = c.relnamespace
      join pg_attribute a  on a.attrelid = c.oid and a.attname = 'test_session_id'
                          and a.attnum > 0 and not a.attisdropped
     where ns.nspname = 'public' and c.relkind = 'r'
  loop
    if not exists (
      select 1 from pg_trigger g join pg_class k on k.oid = g.tgrelid
       join pg_namespace kn on kn.oid = k.relnamespace
       where g.tgname = 'zz_test_session_journal'
         and k.relname = t and kn.nspname = 'public') then
      execute format(
        'create trigger zz_test_session_journal after insert or update or delete
           on public.%I for each row execute function public._test_session_journal()', t);
      n := n + 1;
    end if;
  end loop;
  return n;
end $fn$;

select public.test_journal_attach_all();

commit;
