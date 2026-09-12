-- CHANGE #301 — session guardrails for agent DB work.
--
-- An agent session (Supabase management SQL) connects as `postgres` with
-- statement_timeout 2min, lock_timeout 0 and idle_in_transaction 0. lock_timeout
-- 0 is the wedge: a blocked statement waits forever behind whatever else is
-- heavy, and on a 1 GB instance that is how "trivial SETs take 15 s" starts.
--
-- What is enforced where, and why:
--   * lock_timeout / idle_in_transaction are set on the ROLES — strictly a
--     tightening, so nothing that works today can start waiting longer.
--   * statement_timeout is NOT forced onto the `postgres` role: pg_cron's
--     VACUUM of "MEDICINE", index builds and the nightly pg_dump all run as
--     postgres and legitimately exceed a minute. Capping that role would break
--     backups. The 55 s ceiling is applied to the AGENT SESSION instead, via
--     db_session_guard(), which every agent calls before heavy DB work.

create table if not exists public.db_guard_config (
  id                    boolean primary key default true check (id),
  statement_timeout_ms  int not null default 55000,
  lock_timeout_ms       int not null default 5000,
  idle_in_txn_ms        int not null default 30000,
  max_batch_rows        int not null default 20000
);
insert into public.db_guard_config (id) values (true) on conflict (id) do nothing;

-- Session-scoped ceiling for the caller's own connection. Idempotent, cheap,
-- and safe to call at the top of every agent DB session.
create or replace function public.db_session_guard(
  p_statement_ms int default null,
  p_lock_ms      int default null,
  p_idle_ms      int default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare cfg public.db_guard_config%rowtype;
begin
  perform public._db_guard();
  select * into cfg from public.db_guard_config where id;
  perform set_config('statement_timeout',
                     greatest(coalesce(p_statement_ms, cfg.statement_timeout_ms), 1000)::text, false);
  perform set_config('lock_timeout',
                     greatest(coalesce(p_lock_ms, cfg.lock_timeout_ms), 100)::text, false);
  perform set_config('idle_in_transaction_session_timeout',
                     greatest(coalesce(p_idle_ms, cfg.idle_in_txn_ms), 1000)::text, false);
  return jsonb_build_object('ok', true,
    'statement_timeout', current_setting('statement_timeout'),
    'lock_timeout', current_setting('lock_timeout'),
    'idle_in_transaction_session_timeout', current_setting('idle_in_transaction_session_timeout'),
    'max_batch_rows', cfg.max_batch_rows,
    'note', format('Session capped. Bulk writes must run in batches of at most %s rows, committing each batch — never one giant transaction.', cfg.max_batch_rows));
end $$;

create or replace function public.db_guard_check()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare cfg public.db_guard_config%rowtype; v_st text; v_lt text; v_it text;
begin
  perform public._db_guard();
  select * into cfg from public.db_guard_config where id;
  v_st := current_setting('statement_timeout');
  v_lt := current_setting('lock_timeout');
  v_it := current_setting('idle_in_transaction_session_timeout');
  return jsonb_build_object('ok', true,
    'user', current_user,
    'statement_timeout', v_st, 'lock_timeout', v_lt,
    'idle_in_transaction_session_timeout', v_it,
    'policy', jsonb_build_object('statement_timeout_ms', cfg.statement_timeout_ms,
                                 'lock_timeout_ms', cfg.lock_timeout_ms,
                                 'idle_in_txn_ms', cfg.idle_in_txn_ms,
                                 'max_batch_rows', cfg.max_batch_rows),
    'guarded', (v_lt <> '0' and v_it <> '0'),
    'instruction', 'If guarded is false, call db_session_guard() before running any heavy DB step.');
end $$;

-- The batching tool. `p_sql` must contain exactly one %s where the batch size
-- goes, and must be written so it can only touch that many rows, e.g.
--   delete from big_table where ctid = any (array(
--     select ctid from big_table where at < now() - interval '30 days' limit %s))
-- Each batch is its own transaction: a crash mid-run loses one batch, never the
-- whole job, and no single transaction ever pins the instance.
create or replace procedure public.db_bulk_batch(
  p_sql text,
  p_batch int default null,
  p_max_batches int default 1000
)
language plpgsql
as $$
declare cfg public.db_guard_config%rowtype; v_b int; v_n int; i int := 0; v_total bigint := 0;
begin
  select * into cfg from public.db_guard_config where id;
  v_b := least(greatest(coalesce(p_batch, cfg.max_batch_rows), 1), cfg.max_batch_rows);
  loop
    i := i + 1;
    exit when i > greatest(coalesce(p_max_batches, 1000), 1);
    execute format(p_sql, v_b);
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
    commit;
    exit when v_n = 0;
  end loop;
  raise notice 'db_bulk_batch: % batches of <=% rows, % rows total', i, v_b, v_total;
end $$;

revoke all on function public.db_session_guard(int, int, int) from public;
revoke all on function public.db_guard_check() from public;
revoke all on procedure public.db_bulk_batch(text, int, int) from public;
grant execute on function public.db_session_guard(int, int, int) to authenticated, service_role;
grant execute on function public.db_guard_check() to authenticated, service_role;
grant execute on procedure public.db_bulk_batch(text, int, int) to service_role;

alter table public.db_guard_config enable row level security;

-- Role-level tightening. Both are new settings, so nothing that works today
-- gets a longer wait; a blocked statement now fails fast instead of queueing,
-- and a transaction abandoned by a dead agent is reaped instead of holding its
-- locks forever.
alter role postgres     set lock_timeout = '5s';
alter role postgres     set idle_in_transaction_session_timeout = '120s';
alter role service_role set lock_timeout = '5s';
alter role service_role set idle_in_transaction_session_timeout = '30s';
