#!/usr/bin/env bash
# CHANGE #1149 — replay a batch's migration files on LIVE, once, at deploy time.
#
# Runners build on a Supabase BRANCH now, so production never sees their DDL
# while they work. The migrations still have to reach live: this script is the
# ONE place they do, called by merge_worker.sh right before deploy.sh. It applies
# every supabase/migrations/*.sql in the merged tree that the live ledger
# (supabase_migrations.schema_migrations) does not already hold, in version
# order, inside one exclusive DB-lane slot, and records each one — so a resumed
# batch, or the next batch, never replays a file twice. One PostgREST schema
# reload per batch instead of one per build step.
#
#   scripts/migration_replay.sh <repo-dir> [dburl-file]
# Exit 0 = every pending file applied (or nothing pending). Exit 1 = a file
# failed; the batch must not deploy on top of a half-applied schema.
set -uo pipefail
REPO="${1:?usage: migration_replay.sh <repo-dir> [dburl-file]}"
DBFILE="${2:-$HOME/.medibo/dburl}"
DEVCMD="$HOME/mediBO-runner/devcmd.sh"
DB="$(cat "$DBFILE")"
cd "$REPO" || exit 1
log() { printf '[%s] replay: %s\n' "$(date -u +%FT%TZ)" "$*"; }

mapfile -t FILES < <(ls supabase/migrations/*.sql 2>/dev/null | sort)
[ ${#FILES[@]} -eq 0 ] && { log "no migration files"; exit 0; }

# Keyed by the full file basename (CHANGE #1149 D): bare-date prefixes such
# as 20260904_ are shared by several files, so a version alone is ambiguous.
files_json=$(for f in "${FILES[@]}"; do basename "$f" .sql; done | jq -R . | jq -sc .)
resp=$("$DEVCMD" rpc migration_replay_applied "$(jq -nc --argjson v "$files_json" '{p_files:$v}')" 2>/dev/null)
applied=$(jq -c '.applied_files // empty' <<<"$resp")
# A ledger that answers nothing (RPC missing, empty table, network) is NOT
# "nothing applied": replaying the whole tree on live is the one outcome this
# script exists to prevent. Refuse instead.
if [ -z "$applied" ] || [ "$(jq -r 'length' <<<"$applied")" -eq 0 ]; then
  log "ledger unreadable or empty (resp: ${resp:0:200}) — refusing to replay anything"; exit 1
fi

pending=()
for f in "${FILES[@]}"; do
  b=$(basename "$f" .sql); v="${b%%_*}"
  # Files with no leading version (legacy names) are applied by the runner that
  # wrote them and never replayed: nothing to key them on.
  [[ "$v" =~ ^[0-9]{8,}$ ]] || continue
  if ! jq -e --arg b "$b" 'index($b) != null' <<<"$applied" >/dev/null; then pending+=("$f"); fi
done
[ ${#pending[@]} -eq 0 ] && { log "nothing pending (${#FILES[@]} files, all in the ledger)"; exit 0; }
log "${#pending[@]} pending file(s) to replay on live"
if [ ${#pending[@]} -gt "${REPLAY_MAX_FILES:-15}" ]; then
  log "refusing: ${#pending[@]} pending files is not one batch's worth — seed the ledger (migration_replay_seed) first"; exit 1
fi

# The DB lane: DDL is exclusive. Wait politely, never hammer.
token=""; for try in $(seq 1 20); do
  r=$("$DEVCMD" dblock merge-worker exclusive "migration replay ($(basename "$REPO"))" 10 2>/dev/null || true)
  token=$(jq -r '.token // empty' <<<"$r" 2>/dev/null)
  [ -n "$token" ] && break
  log "db lane busy — retry $try/20 in 45s"; sleep 45
done
[ -z "$token" ] && { log "could not take the exclusive DB lane"; exit 1; }
trap '"$DEVCMD" dbunlock "$token" >/dev/null 2>&1 || true' EXIT

rc=0
for f in "${pending[@]}"; do
  b=$(basename "$f" .sql); v="${b%%_*}"; n="${b#*_}"
  if psql "$DB" -q -v ON_ERROR_STOP=1 -c "set lock_timeout='30s'" -f "$f" >/tmp/replay_$v.log 2>&1; then
    "$DEVCMD" rpc migration_replay_record "$(jq -nc --arg v "$v" --arg n "$n" '{p_version:$v,p_name:$n}')" >/dev/null 2>&1
    log "applied $b"
  else
    log "FAILED $b: $(grep -m1 -i 'error' /tmp/replay_$v.log)"
    rc=1; break
  fi
done
exit $rc
