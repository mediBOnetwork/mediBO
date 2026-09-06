#!/usr/bin/env bash
# CHANGE #639 — the triage bridge.
#
# The evidence lives on PRODUCTION (visual_shot, autotest_*, dev_journeys,
# test_coverage) and the dev queue lives on the CONTROL PLANE (medibo-dev).
# Nothing in SQL can cross that line, so this is the one process that does:
#
#   1. production: triage_batch_pending()  → batches Om approved
#   2. control plane: dev_cmd_bulk_add()   → real fix commands
#   3. production: triage_batch_bind()     → the command id comes home
#   4. control plane: which of those commands completed?
#   5. production: triage_batch_completed() → re-run the exact scenario
#
# It posts nothing back into a command thread on purpose: a reply on a completed
# command opens a FOLLOW-UP, and a reopened row is not a follow-up — it goes
# back to Om's inbox and is re-batched from there.
#
# It approves NOTHING. Approval is a person's tap; see _triage_human().
# Runtime location is ~/mediBO-runner/triage_bridge.sh (where every other runner
# script lives, because the shared ~/mediBO checkout sits on whichever branch a
# runner last used). This file is the committed source; medibo-triage.timer runs
# the runner copy. To update it after a deploy:
#   cp ~/mediBO/scripts/triage_bridge.sh ~/mediBO-runner/triage_bridge.sh
set -uo pipefail

RUNNER_DIR="${RUNNER_DIR:-$HOME/mediBO-runner}"

# An explicitly exported target WINS over runner.env — that is how this script
# is pointed at a build branch for a rehearsal instead of at production.
_in_url="${SUPABASE_URL:-}"        _in_key="${SERVICE_ROLE_KEY:-}"
_in_purl="${PROD_SUPABASE_URL:-}"  _in_pkey="${PROD_SERVICE_ROLE_KEY:-}"
# shellcheck disable=SC1090
[ -f "$RUNNER_DIR/runner.env" ] && . "$RUNNER_DIR/runner.env"
[ -n "$_in_url" ]  && SUPABASE_URL="$_in_url"
[ -n "$_in_key" ]  && SERVICE_ROLE_KEY="$_in_key"
[ -n "$_in_purl" ] && PROD_SUPABASE_URL="$_in_purl"
[ -n "$_in_pkey" ] && PROD_SERVICE_ROLE_KEY="$_in_pkey"

: "${SUPABASE_URL:?SUPABASE_URL (control plane) not set}"
: "${SERVICE_ROLE_KEY:?SERVICE_ROLE_KEY (control plane) not set}"
PROD_SUPABASE_URL="${PROD_SUPABASE_URL:-$SUPABASE_URL}"
PROD_SERVICE_ROLE_KEY="${PROD_SERVICE_ROLE_KEY:-$SERVICE_ROLE_KEY}"

MAX_BATCHES="${TRIAGE_MAX_BATCHES:-4}"

_call() {  # _call <url> <key> <fn> <json-args>
  curl -sS --max-time 60 -X POST "$1/rest/v1/rpc/$3" \
    -H "apikey: $2" -H "Authorization: Bearer $2" \
    -H 'Content-Type: application/json' --data "$4"
}
prod() { _call "$PROD_SUPABASE_URL" "$PROD_SERVICE_ROLE_KEY" "$1" "${2:-{\}}"; }
ctl()  { _call "$SUPABASE_URL"      "$SERVICE_ROLE_KEY"      "$1" "${2:-{\}}"; }

log() { printf '%s triage_bridge: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# ── 1-3. ready batches become real commands ──────────────────────────────
send_batches() {
  local pending sent=0
  pending="$(prod triage_batch_pending "{\"p_limit\":$MAX_BATCHES}")"
  [ -z "$pending" ] && return 0
  echo "$pending" | jq -e 'type=="array"' >/dev/null 2>&1 || { log "pending: $pending"; return 0; }

  local n; n="$(echo "$pending" | jq 'length')"
  [ "$n" -eq 0 ] && return 0

  local i bid item res cmd
  for ((i=0; i<n; i++)); do
    bid="$(echo "$pending"  | jq -r ".[$i].batch_id")"
    item="$(echo "$pending" | jq -c ".[$i].item")"
    # p_force: every batch shares the same boilerplate preamble, so bulk_add's
    # 0.8 spec-similarity check calls them all duplicates of each other. They are
    # not — each title names DIFFERENT row ids, and same-surface rows were already
    # merged into one batch on the production side. Routing and autochaining still
    # happen inside bulk_add; only the similarity veto is waived.
    res="$(ctl dev_cmd_bulk_add "$(jq -nc --argjson it "[$item]" '{p_items:$it,p_force:true}')")"
    cmd="$(echo "$res" | jq -r '.added[0].id // empty')"
    if [ -n "$cmd" ]; then
      prod triage_batch_bind "{\"p_batch_id\":$bid,\"p_command_id\":$cmd}" >/dev/null
      log "batch $bid → command #$cmd"
      sent=$((sent+1))
    else
      # A duplicate binds ONLY when the existing command is literally this batch
      # (same title, so the same row ids). Binding to a command that never
      # mentions these rows would let it report them fixed without touching them.
      local want dup_title
      want="$(echo "$item" | jq -r '.title')"
      cmd="$(echo "$res" | jq -r '.warnings[0].duplicate_of // empty')"
      dup_title="$(echo "$res" | jq -r '.warnings[0].duplicate_title // empty')"
      if [ -n "$cmd" ] && [ "$dup_title" = "$want" ]; then
        prod triage_batch_bind "{\"p_batch_id\":$bid,\"p_command_id\":$cmd}" >/dev/null
        log "batch $bid → existing command #$cmd (same batch, already queued)"
        sent=$((sent+1))
      else
        prod triage_batch_fail "$(jq -nc --argjson b "$bid" --arg n "$(echo "$res" | head -c 400)" \
            '{p_batch_id:$b,p_note:$n}')" >/dev/null
        log "batch $bid could not be queued — rows returned to Om's approved pile"
      fi
    fi
  done
  echo "$sent"
}

# ── 4-6. completed commands get their scenarios re-run ───────────────────
reverify_completed() {
  local open cmds done=0
  open="$(prod triage_batch_open_commands '{}')"
  echo "$open" | jq -e 'type=="array"' >/dev/null 2>&1 || return 0
  cmds="$(echo "$open" | jq -r '.[]')"
  [ -z "$cmds" ] && return 0

  local c status res
  for c in $cmds; do
    status="$(ctl dev_cmd_get "{\"p_id\":$c}" | jq -r '.status // .row.status // empty')"
    [ "$status" != "completed" ] && continue
    res="$(prod triage_batch_completed "{\"p_command_id\":$c}")"
    log "command #$c re-verified: $(echo "$res" | jq -c '{fixed,reopened,escalated,still_checking}' 2>/dev/null || echo "$res" | head -c 200)"
    done=$((done+1))
  done
  echo "$done"
}

case "${1:-run}" in
  send)     send_batches ;;
  reverify) reverify_completed ;;
  run|*)
    prod triage_intake '{"p_limit":200}' >/dev/null
    prod triage_generate_commands '{}'   >/dev/null
    send_batches      >/dev/null
    reverify_completed >/dev/null
    log "pass complete"
    ;;
esac
