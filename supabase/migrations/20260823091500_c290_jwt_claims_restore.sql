-- CHANGE #290 — rg_collect_payloads must give the caller its identity back.
--
-- Found by the mutation audit, and it was not a weak assertion — it was a dead
-- suite. `dev_journeys_run` was raising `dev_queue: not authorized` and writing
-- ZERO dev_journey_runs rows, which silently disarms the proof-based completion
-- gate (§14) for every command in every area.
--
-- The chain:
--   rg_collect_payloads() impersonates each payload target
--     (set_config('request.jwt.claims', {sub, role:authenticated}, true))
--     and finishes by CLEARING the claims outright.
--   set_config(..., true) is transaction-local, so the caller never gets its
--     service_role identity back for the rest of the transaction.
--   dev_journeys_run() probes every enabled journey in ONE transaction, ordered
--     by id. Journey 16 is bug-191, whose probe calls rg_check ->
--     rg_collect_payloads. From that point on the transaction is anonymous.
--   CHANGE #290 (a8b08ae) then added `perform _dev_guard()` to
--     dev_journey_probe — correctly, it was EXECUTE-able by anon while doing
--     DDL — and every probe after bug-191 started failing the guard, aborting
--     the whole run.
--
-- So the security fix was right and the leak was always there; together they
-- killed the suite. Fixing the leak keeps both properties: the probe stays
-- guarded, and a caller that was service_role before rg_check is still
-- service_role after it.
--
-- Spliced, never blind-replaced: two workers doing CREATE OR REPLACE from a
-- definition they read minutes ago is how branches get silently deleted. Each
-- block reads the LIVE pg_get_functiondef, returns early if its marker is
-- already present (idempotent re-apply), and RAISEs if an anchor moved rather
-- than no-opping into a false success. Plain replace() on exact multi-line
-- literals only — a regex anchored on `end` also matches `end if`.

-- ── 1. rg_collect_payloads: save the caller's claims, restore them at the end ──
do $c290a$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'rg_collect_payloads';
  if v_def is null then
    raise exception 'c290: rg_collect_payloads not found';
  end if;
  if position('c290_caller_claims' in v_def) > 0 then
    return;                                   -- already spliced; no-op
  end if;

  -- (a) declare the holder
  v_new := replace(v_def,
    $a$declare t record; v jsonb; e text; s text;$a$,
    $a$declare t record; v jsonb; e text; s text; c290_caller_claims text;$a$);
  if v_new = v_def then
    raise exception 'c290: rg_collect_payloads declare anchor moved';
  end if;

  -- (b) capture the caller's identity before the first impersonation
  v_new := replace(v_new,
$b$begin
  for t in select$b$,
$b$begin
  c290_caller_claims := coalesce(current_setting('request.jwt.claims', true), '');
  for t in select$b$);
  if position('c290_caller_claims := coalesce' in v_new) = 0 then
    raise exception 'c290: rg_collect_payloads begin anchor moved';
  end if;

  -- (c) the FINAL clear becomes a restore. The identical clear inside the loop
  --     is left alone on purpose — a target with no jwt_sub really must be
  --     collected anonymously; only the exit path is wrong.
  v_new := replace(v_new,
$c$  end loop;
  perform set_config('request.jwt.claims','', true);
end $c$,
$c$  end loop;
  perform set_config('request.jwt.claims', c290_caller_claims, true);
end $c$);
  if position($d$set_config('request.jwt.claims', c290_caller_claims, true)$d$ in v_new) = 0 then
    raise exception 'c290: rg_collect_payloads trailing-clear anchor moved';
  end if;

  execute v_new;
end $c290a$;

-- ── 2. dev_journeys_run: re-assert its own identity before every probe ────────
-- Defence in depth. The leak above is fixed at the source, but this loop is the
-- one place where one probe's side effects can disarm every probe after it, and
-- a suite that dies half way must never be possible again from a GUC.
do $c290b$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journeys_run';
  if v_def is null then
    raise exception 'c290: dev_journeys_run not found';
  end if;
  if position('c290_run_claims' in v_def) > 0 then
    return;
  end if;

  v_new := replace(v_def,
    $a$declare j record; v jsonb; st text;$a$,
    $a$declare c290_run_claims text; j record; v jsonb; st text;$a$);
  if v_new = v_def then
    raise exception 'c290: dev_journeys_run declare anchor moved';
  end if;

  v_new := replace(v_new,
$b$  for j in
    select * from dev_journeys$b$,
$b$  c290_run_claims := coalesce(current_setting('request.jwt.claims', true), '');
  for j in
    select * from dev_journeys$b$);
  if position('c290_run_claims := coalesce' in v_new) = 0 then
    raise exception 'c290: dev_journeys_run for-loop anchor moved';
  end if;

  v_new := replace(v_new,
$c$  loop
    v := dev_journey_probe(j.name);$c$,
$c$  loop
    perform set_config('request.jwt.claims', c290_run_claims, true);
    v := dev_journey_probe(j.name);$c$);
  if position($d$perform set_config('request.jwt.claims', c290_run_claims, true);$d$ in v_new) = 0 then
    raise exception 'c290: dev_journeys_run probe-call anchor moved';
  end if;

  execute v_new;
end $c290b$;

revoke execute on function public.dev_journeys_run(bigint, text) from public, anon, authenticated;
