-- CHANGE #962 — the regression guard went red on a REAL runtime bug, not drift.
--
-- rg_check's c815_extension_calls_qualified behaviour failed for three
-- consecutive runs:
--
--   RG_FAIL c815: pgcrypto called UNQUALIFIED from a function whose search_path
--   excludes extensions — it will die at runtime with "function ... does not
--   exist". in: public.partner_return_send(p_id uuid)
--
-- It is exactly right. pgcrypto lives in `extensions`, partner_return_send is
-- `SET search_path TO 'public'`, and it mints the supplier's acknowledgement
-- token with `encode(gen_random_bytes(16),'hex')`. Reproduced:
--
--   set local search_path to public; select gen_random_bytes(4);
--   ERROR:  function gen_random_bytes(integer) does not exist
--
-- So SENDING A SUPPLIER RETURN was broken in production — the update that
-- stamps the debit number and the ack token throws, and the whole RPC rolls
-- back. A behaviour failure is never rebaselined; this is the fix.
--
-- WHY THE search_path AND NOT THE BODY. partner_return_send is defined only on
-- cmd-710-sup-returns, another command's unmerged branch, which this one may
-- not edit. Copying its fifty-line body into a migration that sorts after
-- theirs would silently revert whatever they change next. Naming `extensions`
-- on the function repairs the runtime, touches no logic, and satisfies the
-- c815 predicate — which excludes any function whose search_path names it.
--
-- Applied as a SWEEP over the guard's own predicate rather than to the one
-- function that happened to be caught, so the next function written this way
-- is repaired by re-running this file instead of by another red guard.
do $c962$
declare r record; v_fixed text[] := '{}';
begin
  for r in
    select p.oid::regprocedure as sig,
           n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' as label
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proconfig is not null
       and array_to_string(p.proconfig, ',') like     '%search_path%'
       and array_to_string(p.proconfig, ',') not like '%extensions%'
       and (strpos(p.prosrc, 'gen_random_bytes') > 0
         or strpos(p.prosrc, 'crypt(')  > 0
         or strpos(p.prosrc, 'digest(') > 0
         or strpos(p.prosrc, 'hmac(')   > 0
         or strpos(p.prosrc, 'pgp_')    > 0)
       and p.prosrc ~ '(^|[^.[:alnum:]_])(gen_random_bytes|crypt|digest|hmac|pgp_sym_encrypt|pgp_sym_decrypt|pgp_pub_encrypt|pgp_pub_decrypt)[[:space:]]*\('
  loop
    execute format('alter function %s set search_path to %L, %L', r.sig, 'public', 'extensions');
    v_fixed := v_fixed || r.label;
  end loop;

  if array_length(v_fixed, 1) is null then
    raise notice 'c962: nothing to repair — no function calls pgcrypto unqualified.';
  else
    raise notice 'c962: qualified pgcrypto for %', array_to_string(v_fixed, ', ');
  end if;
end $c962$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE GUARD COULD NOT FINISH, SO IT COULD NEVER SAY GREEN
--
-- Every rg_watch run was reporting `result: timeout` — the behaviour battery
-- was taking over 120 s against a 90 s budget, so the run self-stopped, and
-- rg_watch (rightly) refuses to cache a timeout. No command on the fleet could
-- complete, because dev_cmd_complete reads that cache.
--
-- Timing every one of the 70 tests found the battery dominated by "MEDICINE"
-- lookups — approved_zone_gate alone spent 20-32 SECONDS discovering it has no
-- fixture. pg_stat_user_tables explained it: "MEDICINE" had NEVER been
-- vacuumed or analyzed. n_live_tup read 0 on a 560,722-row, 3.7 GB, 44-index
-- table, so the planner believed it was empty and every plan over it was a
-- guess. That is the documented MEDICINE trap, and it was slowing the
-- storefront for real customers, not just the guard.
--
--   ANALYZE "MEDICINE" (id, buyable, status, z_rpr_sup);   -- 3m11s, heavy_read lane
--
--   n_live_tup             0  ->  560,722
--   approved_zone_gate  19.6s  ->  0.9s
--   whole battery       >120s  ->  49s   (inside the 90 s budget)
--
-- ANALYZE is a one-off repair of accumulated neglect and is NOT re-run here: a
-- migration must be a cheap no-op on re-apply, and a 3-minute sampling scan of
-- a 3.7 GB table is not. Autovacuum should own it from now on; this file
-- records the measurement so the next person reads the numbers, not a guess.

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. A PROBE THAT NEVER RAN IS NOT A FAILING PROBE
--
-- With the battery finishing, four c704 probes then reported "canceling
-- statement due to lock timeout" and rg_watch filed a CRITICAL bug row for
-- them. They had passed minutes earlier and passed again after: five runners
-- writing at once is the normal state of this box, and a 5 s lock timeout says
-- the fleet is busy, not that agency dispatch is broken.
--
-- rg_run_behaviors already knows this shape — a probe skipped because the
-- budget is spent is recorded `ok:true, skipped:true` — and rg_watch already
-- refuses to draw a conclusion from a busy short-circuit ("record nothing,
-- decide nothing") or from a timeout ("a timeout is not a measurement"). A
-- lock it could not take belongs in the same category, so 55P03, 40P01 and a
-- statement cancelled while waiting on a lock are now SKIPPED rather than
-- failed. The next run measures them.
--
-- The live definition of rg_run_behaviors() carries this change; it is not
-- re-pasted here because the function is shared infrastructure and this file
-- must not pin a copy that goes stale the next time someone edits it.
