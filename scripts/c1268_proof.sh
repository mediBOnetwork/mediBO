#!/usr/bin/env bash
# CHANGE #1268 — proof that a runner can hold exactly ONE building command and
# that an agent id belongs to exactly ONE live session.
#
#   bash scripts/c1268_proof.sh
#
# Four guards are exercised, each on its own, because each one has to hold
# alone: the backend claim refusal, the database index, the runner lockfile,
# and the session registry. Nothing here writes to a real command — it uses a
# throwaway agent name and reads its own rows back.
set -uo pipefail
DEVCMD="${DEVCMD:-$HOME/mediBO-runner/devcmd.sh}"
DBURL="$(cat "$HOME/.medibo/dburl")"
AG="proof-$$"
PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
psqlq() { psql "$DBURL" -Atc "$1" 2>&1; }

echo "── 1. five simultaneous claims for one agent ───────────────────────────"
# A parked helper row is claimed by the agent first, so the other four must all
# be refused. Any answer that is not {busy} would be a second build.
# The row this proof owns. It is inserted ALREADY BUILDING and already held by
# the throwaway agent, so the guards can be exercised without ever claiming —
# and therefore without ever touching — a real queued command. (An earlier
# version claimed from the live queue and then deleted what it had claimed;
# nothing may be deleted here that this script did not create.)
CID=$(psqlq "insert into dev_commands(spec,title,status,area,route,kind,claimed_by,started_at,heartbeat_at)
             values ('c1268 proof row','c1268 proof','building','infra','fast','dev','$AG',now(),now())
             returning id;" | head -n1 | tr -dc '0-9')
case "$CID" in
  ''|*[!0-9]*) bad "could not create the proof row: $(head -c 120 <<<"$CID")"; CID="" ;;
  *) ok "proof row #$CID is building as $AG" ;;
esac

busy=0
for i in 1 2 3 4 5; do
  ( "$DEVCMD" rpc dev_cmd_claim "$(jq -nc --arg a "$AG" '{p_agent:$a}')" > "/tmp/c1268.$$.$i" 2>/dev/null ) &
done
wait
for i in 1 2 3 4 5; do
  [ "$(jq -r '.busy // false' < "/tmp/c1268.$$.$i" 2>/dev/null)" = "true" ] && busy=$((busy+1))
  rm -f "/tmp/c1268.$$.$i"
done
[ "$busy" -eq 5 ] && ok "all 5 concurrent claims refused with busy+holding" \
                  || bad "only $busy of 5 concurrent claims were refused"

echo "── 2. a second building row for the same agent, straight into the DB ───"
OUT=$(psqlq "insert into dev_commands(spec,title,status,area,route,kind,claimed_by)
             values ('c1268 second','c1268 second','building','infra','fast','dev','$AG');")
grep -qi "duplicate key\|dev_commands_one_build_per_agent" <<<"$OUT" \
  && ok "database refused the second building row" \
  || bad "database ACCEPTED a second building row: $(head -c 120 <<<"$OUT")"

echo "── 3. the runner lockfile refuses the next claim ───────────────────────"
LOCK="$HOME/mediBO-runner/work/agent-$AG.lock"
printf '%s\nproof\n' "${CID:-1}" > "$LOCK"
L=$(AGENT="$AG" "$DEVCMD" claim "$AG" 2>/dev/null)
[ "$(jq -r '.busy // false' <<<"$L")" = "true" ] \
  && ok "claim loop refused while the lockfile is held" \
  || bad "lockfile did not stop the claim: $(head -c 120 <<<"$L")"

echo "── 4. a devcmd call for a command this session does not hold ───────────"
AGENT="$AG" "$DEVCMD" step_done 1 1 abc "should never land" >/dev/null 2>&1
[ "$?" -eq 9 ] && ok "cross-command call aborted (exit 9)" \
               || bad "cross-command call was NOT aborted"
rm -f "$LOCK"

echo "── 5. one agent id, one live session ───────────────────────────────────"
R1=$("$DEVCMD" rpc dev_agent_register "$(jq -nc --arg a "$AG" --arg s "sessA-$$" '{p_agent:$a,p_session_id:$s}')" 2>/dev/null)
R2=$("$DEVCMD" rpc dev_agent_register "$(jq -nc --arg a "$AG" --arg s "sessB-$$" '{p_agent:$a,p_session_id:$s}')" 2>/dev/null)
[ "$(jq -r '.ok' <<<"$R1")" = "true" ] && ok "first session registered $AG" || bad "first registration failed"
[ "$(jq -r '.taken // false' <<<"$R2")" = "true" ] \
  && ok "second session refused the same agent id" \
  || bad "second session was allowed to shadow $AG"

echo "── 6. a heartbeat from the wrong session ───────────────────────────────"
if [ -n "$CID" ]; then
  psqlq "update dev_commands set claim_session_id='sessA-$$' where id=$CID;" >/dev/null
  H=$("$DEVCMD" rpc dev_cmd_heartbeat "$(jq -nc --argjson i "$CID" --arg s "sessB-$$" '{p_id:$i,p_session_id:$s}')" 2>/dev/null)
  [ "$(jq -r '.wrong_session // false' <<<"$H")" = "true" ] \
    && ok "heartbeat from the wrong session was rejected" \
    || bad "heartbeat from the wrong session was accepted: $(head -c 120 <<<"$H")"
fi

# cleanup: the proof owns every row it made.
# ONLY the row this script created, by id. Never a query that could match a
# real command.
[ -n "$CID" ] && psqlq "delete from dev_commands where id=$CID and claimed_by='$AG';" >/dev/null
psqlq "update dev_agent_session set released_at=now(), release_reason='proof' where agent='$AG';" >/dev/null
psqlq "delete from dev_agent_incident where agent='$AG';" >/dev/null

echo
echo "c1268 proof: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
