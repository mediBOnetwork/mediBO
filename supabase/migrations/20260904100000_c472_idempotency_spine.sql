-- CHANGE #472 — Idempotency audit: the spine.
--
-- The audit (see the command result for the full table) found five money/stock
-- edges that double-apply when fired twice, and six more that are only safe
-- because nobody has yet fired them concurrently — they read a status, decide,
-- and write, with no row lock between the read and the write.
--
-- The house standard already exists: delivery_replay() takes a
-- client_action_id, looks for a stored result, and returns THAT instead of
-- doing the work again (delivery_action_log, PK on client_action_id). #411's
-- pos_commit_sale and #415's khata_entry_add carry the same column with their
-- own unique index. The spec says reuse it rather than invent a mechanism per
-- edge, so this migration generalises exactly that shape into one ledger and
-- two helpers, and every hardened edge below calls them.
--
-- The contract, and why each line of it matters:
--   _idem_claim(scope, key)  -> null            you own it, do the work
--                            -> the stored jsonb someone already did it, return this
--   _idem_store(scope, key, result)             record what you did
--
-- Concurrency is handled by the unique index, not by a check:
-- `insert ... on conflict do nothing` BLOCKS on the index while the first
-- caller's transaction is open, then inserts nothing once it commits — so the
-- second caller reads the first one's result instead of racing it. That is the
-- one property a read-then-write status check can never have.

create table if not exists public.idempotent_action (
  client_action_id uuid        not null,
  scope            text        not null,
  actor            uuid,
  result           jsonb,
  done             boolean     not null default false,
  created_at       timestamptz not null default now(),
  finished_at      timestamptz,
  primary key (scope, client_action_id)
);

comment on table public.idempotent_action is
  'CHANGE #472 — one ledger for every money/stock edge that must survive being '
  'fired twice. Keyed (scope, client_action_id); the row is claimed before the '
  'work and carries the result after it, so a replay returns the first answer.';

create index if not exists idempotent_action_created_idx
  on public.idempotent_action (created_at desc);

-- Nobody reaches this table directly; the helpers are SECURITY DEFINER and the
-- edges call them. RLS on with no policy = no direct client access at all.
alter table public.idempotent_action enable row level security;

-- ── claim ───────────────────────────────────────────────────────────────────
-- Returns NULL when the caller now owns the action, or the stored result when
-- somebody already completed it. A claimed-but-unfinished row can only be seen
-- after the owning transaction committed without storing a result (it raised),
-- so it is re-claimable: an edge that failed must be retryable.
create or replace function public._idem_claim(p_scope text, p_key uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_row public.idempotent_action%rowtype; v_ins int;
begin
  if p_key is null or coalesce(btrim(p_scope),'') = '' then
    return null;   -- no key supplied: the caller keeps its old behaviour
  end if;

  insert into public.idempotent_action (client_action_id, scope, actor)
  values (p_key, p_scope, auth.uid())
  on conflict (scope, client_action_id) do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 1 then
    return null;                                   -- ours; do the work
  end if;

  select * into v_row from public.idempotent_action
   where scope = p_scope and client_action_id = p_key;

  if v_row.done then
    -- The replay marker is added on the way out, never stored, so the first
    -- caller's answer is returned byte-for-byte apart from that one flag.
    return coalesce(v_row.result, jsonb_build_object('ok', true))
           || jsonb_build_object('replayed', true);
  end if;

  -- Claimed but never finished: the previous attempt died. Let this one run.
  update public.idempotent_action set created_at = now(), actor = auth.uid()
   where scope = p_scope and client_action_id = p_key;
  return null;
end $function$;

-- ── store ───────────────────────────────────────────────────────────────────
create or replace function public._idem_store(p_scope text, p_key uuid, p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_key is null or coalesce(btrim(p_scope),'') = '' then
    return p_result;
  end if;
  insert into public.idempotent_action (client_action_id, scope, actor, result, done, finished_at)
  values (p_key, p_scope, auth.uid(), p_result, true, now())
  on conflict (scope, client_action_id) do update
    set result = excluded.result, done = true, finished_at = now();
  return p_result;
end $function$;

-- A refusal is NOT a completed action. Storing "ok:false, bad_amount" would
-- make a corrected retry with the same key return the old refusal for ever, so
-- every edge below stores only on success — this helper makes that explicit
-- and is what the behaviour test asserts.
create or replace function public._idem_store_ok(p_scope text, p_key uuid, p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce((p_result->>'ok')::boolean, false) then
    return public._idem_store(p_scope, p_key, p_result);
  end if;
  -- release the claim so the caller can fix the input and retry
  delete from public.idempotent_action
   where scope = p_scope and client_action_id = p_key and done = false;
  return p_result;
end $function$;

-- 90 days is well past any client's offline queue; the ledger is a dedupe
-- window, not an audit log (every edge writes its own real row).
create or replace function public.idem_sweep()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int;
begin
  delete from public.idempotent_action where created_at < now() - interval '90 days';
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

-- The lockdown shape this repo learned the hard way (delivery lesson): a bare
-- `revoke from anon` leaves the implicit PUBLIC grant standing, and revoking
-- PUBLIC without re-granting `authenticated` locks the app out of its own RPC.
revoke all on function public._idem_claim(text, uuid)          from public, anon;
revoke all on function public._idem_store(text, uuid, jsonb)   from public, anon;
revoke all on function public._idem_store_ok(text, uuid, jsonb) from public, anon;
revoke all on function public.idem_sweep()                     from public, anon;
grant execute on function public._idem_claim(text, uuid)          to authenticated, service_role;
grant execute on function public._idem_store(text, uuid, jsonb)   to authenticated, service_role;
grant execute on function public._idem_store_ok(text, uuid, jsonb) to authenticated, service_role;
grant execute on function public.idem_sweep()                     to service_role;

-- The sweep rides the ONE cron dispatcher (#273) — never a bare */N schedule,
-- which is what starved the 60-connection cap on 18 Aug. Gated, so on the days
-- there is nothing to drop it costs one cheap `exists` and no work at all.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql,
                              base_interval_s, max_interval_s, enabled, note)
values ('idem_sweep', 90, 'poll',
        'select exists (select 1 from public.idempotent_action '
          || 'where created_at < now() - interval ''90 days'')',
        'select public.idem_sweep()',
        3600, 3600, true,
        'CHANGE #472 — drop idempotency keys older than 90 days')
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      base_interval_s = excluded.base_interval_s,
      max_interval_s = excluded.max_interval_s, note = excluded.note;
