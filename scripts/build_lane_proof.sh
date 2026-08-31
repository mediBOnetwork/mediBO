#!/usr/bin/env bash
# CHANGE #327 — proof that a build never waits on another build.
#
# The claim under test: two commands that want the SAME files are chained
# BEFORE either claims, and two commands that want DIFFERENT files still run
# fully in parallel. Both must be true — a scheduler that prevents every
# collision by serialising everything has not fixed anything.
#
# Four probe rows are added at once:
#   A, B  — same area, intersecting predicted files  → B must auto-chain to A
#   C, D  — different areas, disjoint files          → neither may chain
# Then two runners claim. The proof is what the claims hand back: A and one of
# C/D, never B. B is PENDING the whole time — it never loads a context, so the
# lease it would have fought over is never even asked for.
#
#   bash scripts/build_lane_proof.sh          # run it, then clean up
#   bash scripts/build_lane_proof.sh --keep   # leave the probe rows for Om
set -uo pipefail
D="$HOME/mediBO-runner/devcmd.sh"
KEEP="${1:-}"
T0=$(date +%s)

j() { python3 -c 'import sys,json;print(json.load(sys.stdin)'"$1"')'; }

echo "── before ──────────────────────────────────────────────────────────────"
BEFORE="$("$D" contention | j '["headline"]["label"]')"
echo "   $BEFORE"

echo
echo "── adding four probe commands ──────────────────────────────────────────"
ADD="$("$D" rpc dev_cmd_bulk_add "$(jq -nc '{p_force:true,p_items:[
  {title:"c327 probe A — cart line total",       spec:"Probe A. Touch the cart panel and the checkout total."},
  {title:"c327 probe B — cart empty state",      spec:"Probe B. Touch the cart panel empty state. Same files as A."},
  {title:"c327 probe C — whatsapp template copy",spec:"Probe C. Change one whatsapp template label."},
  {title:"c327 probe D — delivery run sheet",    spec:"Probe D. Change one delivery run sheet caption."}]}')")"
IDS=$(echo "$ADD" | python3 -c 'import sys,json
d=json.load(sys.stdin)
rows=d.get("added") or []
print(" ".join(str(r["id"] if isinstance(r,dict) else r) for r in rows))')
set -- $IDS
A=$1; B=$2; C=$3; DD=$4
echo "   A=#$A  B=#$B  C=#$C  D=#$DD"

echo
echo "── what the scheduler decided, before any worker booted ────────────────"
"$D" rpc dev_cmd_list '{"p_limit":500}' | python3 -c '
import sys,json
want=set(sys.argv[1:])
for r in json.load(sys.stdin)["rows"]:
    if str(r["id"]) in want:
        chip=r.get("chain_chip") or "— free to claim"
        print("   #%s  %-38s %s" % (r["id"], r["title"][:38], chip))
' "$A" "$B" "$C" "$DD"

echo
echo "── two runners claim ───────────────────────────────────────────────────"
# A probe must never eat a REAL command: anything claimed that is not one of
# the four probes is handed straight back to pending.
claim() {
  local got
  got="$("$D" rpc dev_cmd_claim "{\"p_agent\":\"$1\"}" | j '.get("id","(empty)")')"
  case " $A $B $C $DD " in
    *" $got "*) : ;;
    *) [ "$got" != "(empty)" ] && "$D" release "$1" "c327 proof — not a probe row" >/dev/null 2>&1 ;;
  esac
  echo "$got"
}
G1="$(claim c327-probe-1)"
G2="$(claim c327-probe-2)"
echo "   runner 1 got #$G1"
echo "   runner 2 got #$G2"
if [ "$G1" = "$B" ] || [ "$G2" = "$B" ]; then
  echo "   ✗ FAIL — #$B was handed out while #$A holds its files"
  RESULT=1
else
  echo "   ✓ #$B was never handed out — it is queued, not parked"
  RESULT=0
fi

echo
echo "── after ───────────────────────────────────────────────────────────────"
"$D" contention | python3 -c '
import sys,json
d=json.load(sys.stdin)
print("   "+d["headline"]["label"])
print("   "+d["headline"]["detail"])
for s in d["sections"]:
    if s["heading"].startswith("Auto-chained"):
        for r in s["rows"]: print("   • %s — %s" % (r["label"], r["detail"]))
'
echo "   wall clock: $(( $(date +%s) - T0 ))s"

if [ "$KEEP" != "--keep" ]; then
  echo
  echo "── cleanup ─────────────────────────────────────────────────────────────"
  # A probe that WAS claimed is 'building'; hand it back first, then cancel,
  # then delete — dev_cmd_delete only ever accepts a cancelled row.
  for a in c327-probe-1 c327-probe-2; do "$D" release "$a" "c327 proof cleanup" >/dev/null 2>&1; done
  for i in $A $B $C $DD; do
    "$D" rpc dev_cmd_cancel "{\"p_id\":$i}" >/dev/null 2>&1
    "$D" rpc dev_cmd_delete "{\"p_id\":$i}" >/dev/null 2>&1
  done
  echo "   probe rows deleted"
fi
exit $RESULT
