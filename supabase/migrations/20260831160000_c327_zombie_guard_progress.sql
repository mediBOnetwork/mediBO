-- CHANGE #327 — the auto-heal root cause fix.
--
-- The previous attempt at #327 was killed with
--   "ZOMBIE: ETA frozen 20min while tokens climbed (602216 -> 1130627)"
--
-- Diagnosis: dev_cmd_watchdog's stall detector had exactly ONE progress
-- signal, eta_left_s changing. A build inside a genuinely long step — a big
-- migration, a 344-file scan, a full protected suite — reports an ETA that is
-- honestly unchanged for twenty minutes while burning tokens on real work.
-- To that rule it is indistinguishable from a wedged agent.
--
-- It also punished honesty in both directions: `eta_left_s = guard_snap_eta`
-- is NULL (never true) when no ETA is reported, so a runner that sent NO ETA
-- was immune while a runner that followed the ETA rule and reported a stable
-- estimate was the only one exposed. Saying nothing was the safest strategy,
-- which is exactly backwards.
--
-- Two changes, both idempotent:
--   1. steps_done becomes a second progress signal. A command that completed a
--      step since the last snapshot is making progress by definition, so the
--      stall clock restarts.
--   2. the ETA comparison becomes IS NOT DISTINCT FROM, so a silent runner is
--      judged on steps and tokens like everyone else.
--
-- The wedged-agent shape — same ETA AND same step count AND climbing tokens
-- past the stall window — is still killed. The heartbeat-lost and
-- runtime-ceiling guards are untouched.
--
-- Truth table, verified live against the patched function:
--   real zombie (eta frozen, no step, tokens climbing) -> killed
--   long step   (eta frozen, a step landed)            -> spared
--   healthy     (eta shrinking)                        -> spared
--   idle        (eta frozen, no step, tokens flat)     -> spared (heartbeat guard owns it)
--   silent, no step, tokens climbing                   -> killed  (was: immune)
--   silent but a step landed                           -> spared

alter table dev_commands
  add column if not exists guard_snap_steps int;

update dev_commands
   set guard_snap_steps = steps_done
 where status = 'building' and guard_snap_steps is null;

-- Patch the two statements that own the stall snapshot, leaving the rest of
-- dev_cmd_watchdog byte-identical. Anchored, so it refuses rather than
-- corrupting the function if it has changed shape; and re-runnable, because
-- the anchors are absent once applied.
do $mig$
declare
  v_src  text := pg_get_functiondef('public.dev_cmd_watchdog()'::regprocedure);
  v_old1 text := 'IF r.guard_snap_at IS NULL OR r.guard_snap_eta IS DISTINCT FROM r.eta_left_s THEN
      UPDATE dev_commands SET guard_snap_at=now(), guard_snap_tokens=r.tokens, guard_snap_eta=r.eta_left_s WHERE id=r.id;
    ELSIF r.eta_left_s = r.guard_snap_eta AND r.tokens > r.guard_snap_tokens';
  v_new1 text := 'IF r.guard_snap_at IS NULL OR r.guard_snap_eta IS DISTINCT FROM r.eta_left_s
       OR r.guard_snap_steps IS DISTINCT FROM r.steps_done THEN
      UPDATE dev_commands SET guard_snap_at=now(), guard_snap_tokens=r.tokens,
             guard_snap_eta=r.eta_left_s, guard_snap_steps=r.steps_done WHERE id=r.id;
    ELSIF r.eta_left_s IS NOT DISTINCT FROM r.guard_snap_eta
          AND r.guard_snap_steps IS NOT DISTINCT FROM r.steps_done
          AND r.tokens > r.guard_snap_tokens';
begin
  if position('guard_snap_steps' in v_src) > 0 then
    return;  -- already patched; a resumed worker must find this a no-op
  end if;
  if position(v_old1 in v_src) = 0 then
    raise exception 'c327: stall-rule anchor not found — dev_cmd_watchdog changed shape, refusing to patch blind';
  end if;
  execute replace(v_src, v_old1, v_new1);
end $mig$;
