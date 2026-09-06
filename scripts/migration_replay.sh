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
#
# CHANGE #1802 — AND ON THE CONTROL PLANE. #1761 moved dev_commands and every
# dev_cmd_* / deploy_* / rg_* function to the medibo-dev project, but this
# script kept replaying on production alone. A migration that redefines
# dev_cmd_complete therefore landed on the ONE database that no longer has
# dev_commands, and never reached the database the fleet actually calls:
# #1758's bounded heartbeat was measured missing from medibo-dev days after it
# "deployed". Every file is now applied to BOTH, prod first, and the ledger
# records it only when both took it — so a control-plane migration can never
# again report success from a database nobody reads. medibo-dev was cloned with
# pg_dump and has no supabase_migrations schema, so its own ledger is a plain
# table this script creates on first use; that also means the dev pass starts
# from THIS batch and never mass-replays the repo's history.
set -uo pipefail
REPO="${1:?usage: migration_replay.sh <repo-dir> [dburl-file]}"
DBFILE="${2:-$HOME/.medibo/dburl}"
DEVCMD="$HOME/mediBO-runner/devcmd.sh"
DB="$(cat "$DBFILE")"
DEVDBFILE="${MEDIBO_DEV_DBURL_FILE:-$HOME/.medibo/dev_dburl}"
DEVDB=""
if [ -f "$DEVDBFILE" ]; then
  DEVDB="$(cat "$DEVDBFILE")"
  # One project, two names, on a box whose cutover never happened: nothing to do.
  [ "$DEVDB" = "$DB" ] && DEVDB=""
fi

# WHICH files go to the control plane — the tables #1761 moved, and only those.
# Measured the hard way in batch 559: replaying EVERY file on medibo-dev died on
# 20260905183000_c668_test_cust1_owns_seeded_shop.sql at `function
# public.identity_norm(unknown) does not exist`. That file seeds the customer
# storefront and has no business on the control plane; medibo-dev is a pg_dump
# clone that has drifted from production's app schema, and chasing that drift is
# not this script's job. A migration that redefines dev_cmd_complete is the one
# that must land on both, and it is recognisable by the tables it names.
CP_TABLES="$REPO/scripts/control_plane_tables.txt"
[ -f "$CP_TABLES" ] || CP_TABLES="$HOME/mediBO-runner/cutover_1761.tables"
CP_RE=""
if [ -n "$DEVDB" ] && [ -f "$CP_TABLES" ]; then
  CP_RE=$(grep -vE '^[[:space:]]*(#|$)' "$CP_TABLES" | tr -cd 'A-Za-z0-9_\n' | grep -v '^$' | paste -sd'|' -)
fi
if [ -n "$DEVDB" ] && [ -z "$CP_RE" ]; then
  log "WARNING: no control-plane table list ($CP_TABLES) — the control-plane pass is OFF for this batch"
  "$DEVCMD" rpc rg_alert_raise "$(jq -nc '{p_kind:"migration_replay",p_level:"warn",
     p_title:"control-plane replay disabled",
     p_detail:"scripts/control_plane_tables.txt is missing, so migrations were applied to production only"}')" >/dev/null 2>&1 || true
  DEVDB=""
fi
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

# WHICH MODE — the backend decides (migration_replay_mode). While no runner
# has built on a Supabase branch, the files were applied to live by the
# runners that wrote them (today's behaviour): record them, apply nothing.
#
# CHANGE #1800 — ask the CONTROL PLANE for the mode, not production.
# migration_replay_mode() counts build_branch rows, and #1761's cutover moved
# build_branch to medibo-dev and dropped it from production. devcmd routes every
# migration_replay_* name to production, so the call threw
#   relation "public.build_branch" does not exist
# -> `.mode` was empty -> "mode unknown — refusing to touch live" -> the batch
# never deployed. Batch 553 (CHANGE #1147) died exactly there, and every batch
# after it would have. The LEDGER (migration_replay_ledger) and the DDL itself
# still belong to production, so _applied and _record below stay on prod; only
# this one read follows build_branch to the control plane. On a box whose
# runner.env has not been switched yet PROD_* and the control plane are the same
# pair, so the override is a no-op there.
mode_resp=$(DEVCMD_FORCE_DEV=1 "$DEVCMD" rpc migration_replay_mode '{}' 2>/dev/null)
mode=$(jq -r '.mode // empty' <<<"$mode_resp")
log "mode=${mode:-unknown}: $(jq -r '.reason // "no answer from migration_replay_mode"' <<<"$mode_resp")"
if [ "$mode" = "record" ]; then
  for f in "${pending[@]}"; do
    b=$(basename "$f" .sql); v="${b%%_*}"; n="${b#*_}"
    "$DEVCMD" rpc migration_replay_record "$(jq -nc --arg v "$v" --arg n "$n" '{p_version:$v,p_name:$n}')" >/dev/null 2>&1 && log "recorded $b (applied to live by its runner)"
  done
  exit 0
elif [ "$mode" != "replay" ]; then
  log "mode unknown — refusing to touch live"; exit 1
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

# The control plane's own ledger. medibo-dev carries no supabase_migrations
# schema (it was cloned data-only), so this is where "dev already has it" is
# recorded. Created once, idempotently, and never read by anything but this.
if [ -n "$DEVDB" ]; then
  if ! psql "$DEVDB" -q -v ON_ERROR_STOP=1 -c "
        create table if not exists public.migration_replay_dev_ledger(
          file text primary key, applied_at timestamptz not null default now())" \
        >/tmp/replay_devledger.log 2>&1; then
    log "control plane unreachable ($(head -c 160 /tmp/replay_devledger.log)) — refusing to deploy a half-applied schema"
    exit 1
  fi
fi

# CHANGE #1819 — knob, not a constant: pool_set() can turn the soft skip off the
# day a control-plane migration genuinely needs to fail the batch.
CP_SOFT=true
if [ -n "$DEVDB" ]; then
  CP_SOFT=$(psql "$DEVDB" -Atc "select case when coalesce((value->'replay'->>'cp_soft_missing')::boolean, true) then 'true' else 'false' end from dev_runner_config where key='worker_pool'" 2>/dev/null || echo true)
  [ -n "$CP_SOFT" ] || CP_SOFT=true
fi

rc=0
for f in "${pending[@]}"; do
  b=$(basename "$f" .sql); v="${b%%_*}"; n="${b#*_}"
  if ! psql "$DB" -q -v ON_ERROR_STOP=1 -c "set lock_timeout='30s'" -f "$f" >/tmp/replay_$v.log 2>&1; then
    log "FAILED $b: $(grep -m1 -i 'error' /tmp/replay_$v.log)"
    rc=1; break
  fi
  # CHANGE #1802 — the same file, on the control plane, before the ledger is
  # told anything. A file that lands on production and dies here is a FAILED
  # batch: half-applied across two databases is exactly the state #1761 left
  # behind and nobody noticed for two days.
  # CHANGE #637 — the file may SAY where it belongs, and the word beats the
  # guess. The heuristic reads intent out of table names, and #637 is the
  # counterexample it cannot survive: the visual/exploratory lane is entirely
  # production-side (test_runs, test_results, visual_shot) and merely READS
  # feature_registry and ui_copy, which exist on both databases. Named a
  # control-plane table, routed to the control plane, dead on `relation
  # "public.test_runs" does not exist` — and a failed control-plane pass fails
  # the whole batch, so one mis-guessed file blocks every branch beside it.
  #   -- replay-target: production     (skip the control-plane pass)
  #   -- replay-target: control-plane  (take it, whatever the names say)
  #   -- replay-target: both           (same; the production pass always runs)
  # Anything else, or nothing at all, keeps the table-name heuristic.
  target=$(grep -m1 -oEi '^--[[:space:]]*replay-target:[[:space:]]*[a-z-]+' "$f" \
             | sed -E 's/.*:[[:space:]]*//' | tr 'A-Z' 'a-z')
  if [ -n "$DEVDB" ] && [ "$target" = "production" ]; then
    log "$b declares replay-target: production — production only"
  elif [ -n "$DEVDB" ] && [ -z "$target" ] \
       && ! grep -qEi "(^|[^A-Za-z0-9_])(${CP_RE})([^A-Za-z0-9_]|$)" "$f"; then
    log "$b names no control-plane table — production only"
  elif [ -n "$DEVDB" ]; then
    already=$(psql "$DEVDB" -Atc "select 1 from public.migration_replay_dev_ledger where file = $(printf "%s" "$b" | sed "s/'/''/g; s/^/'/; s/$/'/")" 2>/dev/null)
    if [ "$already" != "1" ]; then
      if psql "$DEVDB" -q -v ON_ERROR_STOP=1 -c "set lock_timeout='30s'" -f "$f" >/tmp/replay_dev_$v.log 2>&1; then
        psql "$DEVDB" -q -c "insert into public.migration_replay_dev_ledger(file) values ($(printf "%s" "$b" | sed "s/'/''/g; s/^/'/; s/$/'/")) on conflict do nothing" >/dev/null 2>&1
        log "applied $b on the control plane too"
      else
        err=$(grep -m1 -i 'error' /tmp/replay_dev_$v.log)
        # CHANGE #1819 — three of the last eight batches died here, and not one
        # of them was a broken migration: 20260906120000 named a control-plane
        # table AND called viewer_is_approved_customer(), 20260906090000 called
        # my_customer_id() — production functions that medibo-dev has never had.
        # The file had already landed on production, so nothing was half-applied;
        # the only casualty was every OTHER branch in the batch. A missing
        # production symbol on the control plane means the file was mis-ROUTED,
        # which is a routing bug to alert on, not a reason to stop the fleet
        # deploying. Anything else still fails the batch.
        if [ "$CP_SOFT" = "true" ] && grep -qEi 'ERROR: +(function|relation|column) .* does not exist' /tmp/replay_dev_$v.log; then
          log "SKIPPED $b on the control plane (production-only symbol): $err — production applied, batch continues"
          psql "$DEVDB" -q -c "insert into public.migration_replay_dev_ledger(file) values ($(printf "%s" "$b" | sed "s/'/''/g; s/^/'/; s/$/'/")) on conflict do nothing" >/dev/null 2>&1
          psql "$DEVDB" -q -c "insert into public.rg_alerts(fingerprint,severity,kind,name,detail)
             values ('replay_cp_misroute_$b','warn','deploy','migration mis-routed to the control plane',
                     jsonb_build_object('file','$b','fix','add -- replay-target: production to the file'))
             on conflict (fingerprint) do update set last_seen=now(), seen_count=rg_alerts.seen_count+1" >/dev/null 2>&1 || true
        else
          log "FAILED $b on the CONTROL PLANE: $err"
          rc=1; break
        fi
      fi
    fi
  fi
  "$DEVCMD" rpc migration_replay_record "$(jq -nc --arg v "$v" --arg n "$n" '{p_version:$v,p_name:$n}')" >/dev/null 2>&1
  log "applied $b"
done
exit $rc
