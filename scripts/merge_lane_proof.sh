#!/usr/bin/env bash
# merge_lane_proof.sh — CHANGE #1822. The merge lane never loses its own
# finished work.
#
# Batches 589-601 (6 Sep 2026): the deploy phase ran 238-801 s against a lock
# the worker took once and never renewed, so the claim expired mid-deploy,
# merge_batch_finish answered not_lock_holder, the batch was swept as failed
# with the site already serving it, and a green protected suite plus a finished
# build were thrown away and redone. This script drives one batch through the
# control plane's real RPCs inside ONE transaction that is always rolled back,
# with the deploy phase aged past lock_ttl_minutes, and asserts four things:
#
#   1. the lane is still held at the end            (merge_lane_touch renewed it)
#   2. finish returns ok on the FIRST attempt        (no not_lock_holder)
#   3. exactly one change number was claimed         (finish is idempotent, and
#                                                     the resumed batch reuses it)
#   4. reopening the same tree skips the test phase  (merge_batch_tree resumes)
#
#   bash scripts/merge_lane_proof.sh
#
# It touches the real deploy_lock row for well under a second and rolls back,
# so it may run while the merge worker is live; if the lane is genuinely busy
# the proof frees it INSIDE the transaction only.
set -uo pipefail
DEVDB="${MEDIBO_DEV_DBURL:-$(cat "${MEDIBO_DEV_DBURL_FILE:-$HOME/.medibo/dev_dburl}" 2>/dev/null)}"
[ -n "$DEVDB" ] || { echo "merge_lane_proof: no control-plane DB url"; exit 2; }

out=$(psql "$DEVDB" -v ON_ERROR_STOP=1 -q 2>&1 <<'SQL'
begin;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
do $proof$
declare
  v_tree text := 'proof-' || replace(gen_random_uuid()::text, '-', '');
  v_q1 bigint; v_q2 bigint; v_open jsonb; v_b1 bigint; v_t1 uuid; v_r jsonb;
  v_no int; v_t2 uuid; v_touch jsonb; v_fin1 jsonb; v_fin2 jsonb; v_b2 bigint;
  v_ttl int; v_lock deploy_lock%rowtype; v_regs int; v_skip jsonb;
begin
  v_ttl := coalesce((_mq_cfg()->>'lock_ttl_minutes')::int, 2);
  -- the proof owns the lane for the length of this (rolled-back) transaction
  update deploy_lock set token = null, holder = null, title = null,
                         acquired_at = null, expires_at = null, renewals = 0 where id = 1;
  insert into deploy_queue(command_id, agent, title, branch, commit_sha, status, pushed_at)
  values (null, 'proof-1822', 'merge lane proof', 'proof/c1822', 'abc1234', 'waiting', now() - interval '1 hour')
  returning id into v_q1;

  v_open := merge_batch_open('proof-worker');
  if (v_open->>'ok') <> 'true' then raise exception 'open refused: %', v_open; end if;
  v_b1 := (v_open->>'batch_id')::bigint; v_t1 := (v_open->>'token')::uuid;
  v_r := merge_batch_tree(v_b1, v_tree, 'proof-worker');
  if (v_r->>'resumed') <> 'false' then raise exception 'fresh tree must not resume: %', v_r; end if;
  perform merge_lane_unlock(v_t1);
  perform merge_batch_phase(v_b1, 'test', 607, 'protected suite GREEN', false);
  v_r := merge_batch_prenumber(v_b1, 'proof-worker', 'abc1234');
  v_no := (v_r->>'change_no')::int;
  if v_no is null then raise exception 'prenumber refused: %', v_r; end if;
  v_r := merge_lane_relock(v_b1, 'proof-worker');
  if (v_r->>'ok') <> 'true' then raise exception 'relock refused: %', v_r; end if;
  v_t2 := (v_r->>'token')::uuid;

  -- THE DEPLOY PHASE, forced longer than lock_ttl_minutes: age the claim so
  -- the wall-clock TTL has already passed while the holder is still alive.
  update deploy_lock
     set acquired_at = now() - make_interval(mins => v_ttl * 4),
         expires_at  = now() - interval '1 second'
   where id = 1 and token = v_t2;
  v_touch := merge_lane_touch(v_b1, 'proof-worker', v_t2);
  if (v_touch->>'ok') <> 'true' then raise exception 'touch refused: %', v_touch; end if;
  perform merge_lane_touch(v_b1, 'proof-worker', v_t2);   -- idempotent: a second tick
  perform merge_batch_phase(v_b1, 'migrate', 4, 'live migration replay', true);
  perform merge_batch_phase(v_b1, 'deploy', 706, 'build + upload', true);

  -- 1. the lane is still held at the end of the long deploy
  select * into v_lock from deploy_lock where id = 1;
  if v_lock.token is distinct from v_t2 or v_lock.expires_at <= now() then
    raise exception 'ASSERT 1 lane lost: token=% expires_at=% now=%', v_lock.token, v_lock.expires_at, now();
  end if;
  raise notice 'PASS 1 lane still held after a deploy longer than the TTL (renewed % times, expires_at % > now)', v_lock.renewals, v_lock.expires_at;

  -- 2. finish succeeds on the FIRST attempt
  v_fin1 := merge_batch_finish(v_t2, 'success', 'abc1234', 'proof');
  if (v_fin1->>'ok') <> 'true' or (v_fin1->>'already') <> 'false' then
    raise exception 'ASSERT 2 first finish did not succeed: %', v_fin1;
  end if;
  raise notice 'PASS 2 finish ok on the first attempt (hold_s=%, %)', v_fin1->>'hold_s', v_fin1->>'lane_note';

  -- 3. exactly one change number — a second finish is already:true
  v_fin2 := merge_batch_finish(v_t2, 'success', 'abc1234', 'proof again');
  if (v_fin2->>'already') <> 'true' or (v_fin2->>'change_no')::int <> v_no then
    raise exception 'ASSERT 3 second finish: %', v_fin2;
  end if;
  select count(*) into v_regs from deploy_registry where batch_id = v_b1;
  if v_regs <> 1 then raise exception 'ASSERT 3 registry rows for batch %: %', v_b1, v_regs; end if;
  raise notice 'PASS 3 exactly one change number (#%) — second finish answered already:true', v_no;

  -- and finish without the lane at all: a batch whose claim was swept
  -- (a fresh batch, its lock cleared underneath it, finish must still record)
  -- 4. reopen the same tree — after the earlier batch DIED after its deploy
  update deploy_batch set status = 'failed', deployed_at = null,
         note = 'expired by deploy_lane_sweep (simulated)' where id = v_b1;
  update deploy_registry set status = 'claimed', deployed_at = null where change_no = v_no;
  insert into deploy_queue(command_id, agent, title, branch, commit_sha, status, pushed_at)
  values (null, 'proof-1822', 'merge lane proof (retry)', 'proof/c1822', 'abc1234', 'waiting', now() - interval '1 hour')
  returning id into v_q2;
  v_open := merge_batch_open('proof-worker');
  if (v_open->>'ok') <> 'true' then raise exception 'reopen refused: %', v_open; end if;
  v_b2 := (v_open->>'batch_id')::bigint;
  v_r := merge_batch_tree(v_b2, v_tree, 'proof-worker');
  v_skip := coalesce(v_r->'skip', '[]'::jsonb);
  if (v_r->>'resumed') <> 'true' or not (v_skip ? 'test') then
    raise exception 'ASSERT 4 same tree did not resume past test: %', v_r;
  end if;
  if (v_r->>'change_no')::int <> v_no or (v_r->>'change_reused') <> 'true' then
    raise exception 'ASSERT 4 change number not reused: %', v_r;
  end if;
  if not (v_skip ? 'deploy') then
    raise exception 'ASSERT 4 a finished upload of the SAME number must be skipped: %', v_r;
  end if;
  select count(*) into v_regs from deploy_registry where change_no = v_no;
  if v_regs <> 1 then raise exception 'ASSERT 4 change #% claimed % times', v_no, v_regs; end if;
  raise notice 'PASS 4 reopening tree % skipped % (batch % resumed from %, CHANGE #% reused once)',
    left(v_tree, 13), v_skip::text, v_b2, v_r->>'from_batch', v_no;

  -- and the lane-free finish: sweep the lock from under the resumed batch
  perform merge_lane_unlock((select token from deploy_batch where id = v_b2));
  v_r := merge_lane_relock(v_b2, 'proof-worker');
  v_t2 := (v_r->>'token')::uuid;
  update deploy_lock set token = null, holder = null, expires_at = null where id = 1;  -- the sweep
  v_fin1 := merge_batch_finish(v_t2, 'success', 'abc1234', 'proof after sweep');
  if (v_fin1->>'ok') <> 'true' or (v_fin1->>'lane_released') <> 'false' then
    raise exception 'ASSERT 2b finish after a swept lane: %', v_fin1;
  end if;
  raise notice 'PASS 2b finish recorded the deploy with NO lane held (%)', v_fin1->>'lane_note';
end $proof$;
rollback;
SQL
); rc=$?
printf '%s\n' "$out" | grep -E 'NOTICE|PASS|ERROR|ASSERT' | sed 's/^psql:[^ ]* //; s/^NOTICE:  /  ✓ /'
if [ "$rc" -ne 0 ] || ! grep -q 'PASS 4' <<<"$out"; then
  echo "MERGE LANE PROOF: RED"; exit 1
fi
echo "MERGE LANE PROOF: green — the lane renews, finish never needs it, one number, resume skips the suite."
