#!/usr/bin/env bash
# android_testlab.sh — CMD #2076: the Firebase Test Lab gate.
#
#   bash scripts/android_testlab.sh run --cmd <id> [--cmd <id>…] [--release <id>]
#        [--commit <sha>] [--version-code <n>] [--version-name <s>] [--track <t>]
#        [--rehearsal] [--worker <name>]
#   bash scripts/android_testlab.sh gate --track production [--commit <sha>] [--version-code <n>] [--kind publish|promote]
#   bash scripts/android_testlab.sh preflight        # credentials + API + device catalogue, no run, no quota
#   bash scripts/android_testlab.sh plan --cmd <id>  # the spec-derived checks the backend would run
#   bash scripts/android_testlab.sh selfcheck        # writes the rg verdict android_testlab_gate_wired
#
# The web build never compiles or runs the Kotlin plugins. `run` builds the
# debug app APK with integration_test/android_gate_test.dart as its entrypoint
# and the androidTest APK, then makes ONE blocking `gcloud firebase test android
# run` call on ONE virtual device at ONE API level with a hard timeout, pulls the
# video / logcat / screenshots / per-check JSON into the dev-cmd-proofs bucket,
# and records the verdict. It prints exactly ONE line and only pass/fail enters
# the caller's context; everything else goes to $LOG.
#
# NOTHING IS DECIDED HERE. android_testlab_begin() (control plane) says whether
# the gate applies (web-only commands skip), whether the free daily quota has
# room (never pay — a used-up quota is recorded as 'quota' and the run is not
# started), which checks the spec derives, which device, which timeout, and
# every sentence this script may print. android_testlab_finish() records the
# verdict and stamps the command row(s). android_testlab_gate() is what
# publish_play.sh asks before a Production upload.
#
# Exit codes for `run`: 0 passed · 1 failed · 2 not run (quota/blocked/error) ·
# 3 skipped (gate does not apply). For `gate`: 0 allowed · 1 refused.
#
# SECRETS. The service-account key is read from the Vault into /dev/shm
# (chmod 600), gcloud's config dir lives in /dev/shm too, and both are shredded
# by the EXIT trap. Nothing here echoes key material.
set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
RUNNER="$HOME/mediBO-runner"
DEVCMD="$RUNNER/devcmd.sh"
LOG="${TESTLAB_LOG:-$RUNNER/testlab.log}"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$HOME/google-cloud-sdk/bin:$JAVA_HOME/bin:$HOME/flutter/bin:$HOME/.local/bin:$PATH"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%FT%TZ)] [testlab] $*" >>"$LOG"; }

SHM=$(mktemp -d /dev/shm/testlab.XXXXXX)
chmod 700 "$SHM"
export CLOUDSDK_CONFIG="$SHM/gcloud"
mkdir -p "$CLOUDSDK_CONFIG"
cleanup() {
  [ -f "$SHM/sa.json" ] && { shred -u "$SHM/sa.json" 2>/dev/null || rm -f "$SHM/sa.json"; }
  rm -rf "$SHM"
  return 0
}
trap cleanup EXIT

jqr() { jq -r "$@" 2>/dev/null; }
rpc() { "$DEVCMD" rpc "$1" "$2" 2>>"$LOG"; }

# ── args ──────────────────────────────────────────────────────────────────────
MODE="${1:-}"; shift || true
FLAVOR="${MEDIBO_FLAVOR:-customer}"
CMDS=(); REL=""; COMMIT=""; VCODE=""; VNAME=""; TRACK=""; REHEARSAL=false; WORKER="${AGENT:-$(hostname)}"; KIND="publish"
while [ $# -gt 0 ]; do
  case "$1" in
    --cmd)          CMDS+=("${2:?--cmd needs an id}"); shift ;;
    --cmds)         for c in ${2:?}; do CMDS+=("$c"); done; shift ;;
    --release)      REL="${2:?}"; shift ;;
    --commit)       COMMIT="${2:-}"; shift ;;
    --version-code) VCODE="${2:-}"; shift ;;
    --version-name) VNAME="${2:-}"; shift ;;
    --track)        TRACK="${2:-}"; shift ;;
    --kind)         KIND="${2:-publish}"; shift ;;
    --worker)       WORKER="${2:-}"; shift ;;
    # CMD #2100 — which product flavor to build and run (customer | partner).
    --flavor)       FLAVOR="${2:-customer}"; shift ;;
    --rehearsal)    REHEARSAL=true ;;
    --help|-h)      sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "android_testlab: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$COMMIT" ] || COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
ids_json=$(printf '%s\n' "${CMDS[@]:-}" | grep -E '^[0-9]+$' | jq -R 'tonumber' | jq -sc . 2>/dev/null || echo '[]')
[ "$ids_json" = "" ] && ids_json='[]'

# fill <template> <k=v>… — the backend's sentence with its {placeholders} filled.
fill() {
  local s="$1"; shift
  for kv in "$@"; do s="${s//\{${kv%%=*}\}/${kv#*=}}"; done
  printf '%s' "$s"
}

# ── the credential (Vault → /dev/shm) ─────────────────────────────────────────
# Prints "" on success; else one of missing|transient with the reason in CRED_WHY.
CRED_WHY=""
load_credential() { # <secret-name>
  local name="$1" raw attempt
  for attempt in 1 2 3; do
    raw=$(rpc secret_get_runner "$(jq -nc --arg n "$name" '{p_name:$n}')" || true)
    if jq -e 'type=="string"' >/dev/null 2>&1 <<<"$raw"; then
      umask 077
      jq -r '.' <<<"$raw" > "$SHM/sa.json"
      chmod 600 "$SHM/sa.json"
      if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["type"]=="service_account"' "$SHM/sa.json" 2>/dev/null; then
        CRED_WHY=""; return 0
      fi
      CRED_WHY="the Vault value for $name is not a service-account key"; return 1
    fi
    if jq -e 'type=="object" and .code=="P0001" and (.message|test("not found"))' >/dev/null 2>&1 <<<"$raw"; then
      CRED_WHY="missing"; return 1
    fi
    sleep $((attempt * 3))
  done
  CRED_WHY="the Vault did not answer for $name (3 attempts)"; return 1
}

activate() { # → 0 ok
  gcloud auth activate-service-account --key-file="$SHM/sa.json" >>"$LOG" 2>&1 || return 1
  gcloud config set project "$PROJECT" >>"$LOG" 2>&1 || true
  SA_EMAIL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("client_email",""))' "$SHM/sa.json" 2>/dev/null)
  log "gcloud active as ${SA_EMAIL:-?} on $PROJECT"
  return 0
}

# classify_gcloud_error <stderr-file> → api_disabled | no_permission | quota | other
classify_gcloud_error() {
  local e="$1"
  if grep -qiE 'has not been used in project|is disabled|API \[[a-z.]+\] not enabled' "$e"; then echo api_disabled
  elif grep -qiE 'RESOURCE_EXHAUSTED|quota' "$e"; then echo quota
  elif grep -qiE 'PERMISSION_DENIED|does not have permission|permission denied' "$e"; then echo no_permission
  else echo other; fi
}

# catalogue → picks DEV_MODEL / DEV_VERSION. Returns 1 with WHY set on failure.
WHY=""
pick_device() {
  local cat="$SHM/catalogue.json" err="$SHM/catalogue.err" kind m v
  if ! gcloud firebase test android models list --project "$PROJECT" --filter='form=VIRTUAL' --format=json >"$cat" 2>"$err"; then
    kind=$(classify_gcloud_error "$err")
    if [ "$kind" = api_disabled ]; then
      # Spec §3: enable it with the credentials on the VM when they can.
      log "Cloud Testing API off — trying to enable it as ${SA_EMAIL:-?}"
      if gcloud services enable testing.googleapis.com toolresults.googleapis.com --project "$PROJECT" >>"$LOG" 2>&1 \
         && gcloud firebase test android models list --project "$PROJECT" --filter='form=VIRTUAL' --format=json >"$cat" 2>"$err"; then
        log "Cloud Testing API enabled"
      else
        WHY="api_disabled"; tail -c 400 "$err" >>"$LOG"; return 1
      fi
    else
      WHY="$kind"; tail -c 400 "$err" >>"$LOG"; return 1
    fi
  fi
  m=$(jq -r --arg m "$WANT_MODEL" --arg v "$WANT_VERSION" \
        '.[] | select(.id==$m) | select(.supportedVersionIds|index($v)) | .id' "$cat" | head -1)
  if [ -n "$m" ]; then DEV_MODEL="$m"; DEV_VERSION="$WANT_VERSION"; return 0; fi
  # the configured pair is gone: first fallback model that exists, at the
  # highest API it supports that does not exceed the configured one
  for m in $(jq -r '.[]' <<<"$FALLBACKS") "$WANT_MODEL"; do
    v=$(jq -r --arg m "$m" --arg v "$WANT_VERSION" \
          '.[] | select(.id==$m) | [.supportedVersionIds[] | select(test("^[0-9]+$")) | tonumber | select(. <= ($v|tonumber))] | max // empty' "$cat" | head -1)
    if [ -n "$v" ]; then DEV_MODEL="$m"; DEV_VERSION="$v"; log "device fallback: $m API $v (wanted $WANT_MODEL API $WANT_VERSION)"; return 0; fi
  done
  m=$(jq -r '.[0].id // empty' "$cat"); v=$(jq -r '.[0].supportedVersionIds | map(select(test("^[0-9]+$"))|tonumber) | max // empty' "$cat")
  if [ -n "$m" ] && [ -n "$v" ]; then DEV_MODEL="$m"; DEV_VERSION="$v"; log "device fallback (first virtual): $m API $v"; return 0; fi
  WHY="other"; echo "no virtual device in the catalogue" >>"$LOG"; return 1
}

# ── proofs → dev-cmd-proofs (production storage) + the ledger ─────────────────
proof_upload() { # <file> <bucket-path> <content-type> → 0 ok
  local f="$1" p="$2" ct="$3"
  # runner.env is sourced INTO A SUBSHELL so its SUPABASE_URL cannot leak into
  # devcmd routing here (the #1802 trap).
  ( set +u; source "$RUNNER/runner.env"
    U="${PROD_SUPABASE_URL:-$SUPABASE_URL}"; K="${PROD_SERVICE_ROLE_KEY:-$SERVICE_ROLE_KEY}"
    curl --connect-timeout 10 --max-time 900 -fsS -X POST "$U/storage/v1/object/dev-cmd-proofs/$p" \
      -H "apikey: $K" -H "Authorization: Bearer $K" -H "Content-Type: $ct" -H "x-upsert: true" \
      --data-binary "@$f" >/dev/null 2>>"$LOG" ) || return 1
  rpc dev_proof_note "$(jq -nc --arg n "$p" --argjson c "${CMDS[0]:-null}" '{p_name:$n,p_command_id:$c}')" >/dev/null || true
  return 0
}

finish() { # <status> <reason> [checks-json] [proofs-json] [outcome-json]
  local st="$1" why="$2" checks="${3:-[]}" proofs="${4:-[]}" outcome="${5:-{\}}" out
  out=$(rpc android_testlab_finish "$(jq -nc --argjson id "$RUN_ID" --arg s "$st" --arg r "$why" \
          --arg m "${MATRIX_ID:-}" --arg u "${CONSOLE_URL:-}" --arg d "${RESULTS_GS:-}" \
          --argjson c "$checks" --argjson p "$proofs" --argjson o "$outcome" \
          --arg dm "${DEV_MODEL:-}" --arg dv "${DEV_VERSION:-}" \
          '{p_run_id:$id,p_status:$s,p_reason:$r,p_matrix_id:(if $m=="" then null else $m end),
            p_console_url:(if $u=="" then null else $u end),p_results_dir:(if $d=="" then null else $d end),
            p_checks:$c,p_proofs:$p,p_outcome:$o,
            p_device_model:(if $dm=="" then null else $dm end),p_device_version:(if $dv=="" then null else $dv end)}')")
  SUMMARY=$(jqr '.summary // empty' <<<"$out"); [ -n "$SUMMARY" ] || SUMMARY="$why"
  log "run #$RUN_ID → $st: $SUMMARY"
}

say() { echo "TESTLAB $1 — $2 (run #${RUN_ID:-none})"; }

# ── selfcheck: the rg verdict ────────────────────────────────────────────────
if [ "$MODE" = "selfcheck" ]; then
  ok=true; why=()
  command -v gcloud >/dev/null 2>&1 || { ok=false; why+=("gcloud is not on the VM (expected ~/google-cloud-sdk/bin/gcloud)"); }
  grep -q 'android_testlab_gate' scripts/publish_play.sh 2>/dev/null || { ok=false; why+=("scripts/publish_play.sh no longer asks android_testlab_gate before the upload"); }
  grep -q 'android_testlab.sh' scripts/publish_play.sh 2>/dev/null || { ok=false; why+=("scripts/publish_play.sh no longer runs android_testlab.sh before the upload"); }
  grep -q 'android_testlab.sh' "$RUNNER/android_build.sh" 2>/dev/null || { ok=false; why+=("mediBO-runner/android_build.sh no longer runs the Test Lab after the build"); }
  [ -f integration_test/android_gate_test.dart ] || { ok=false; why+=("integration_test/android_gate_test.dart is missing"); }
  [ -f android/app/src/androidTest/java/in/medibo/app/MainActivityTest.java ] || { ok=false; why+=("the androidTest runner is missing"); }
  grep -q 'testInstrumentationRunner' android/app/build.gradle.kts 2>/dev/null || { ok=false; why+=("android/app/build.gradle.kts has no testInstrumentationRunner"); }
  gate=$(rpc dev_build_rules '{}' | jqr '.android_testlab.gate // empty')
  [ "$gate" = "c_android_testlab" ] || { ok=false; why+=("build_rules.android_testlab.gate is '${gate:-missing}', expected c_android_testlab"); }
  detail=$(IFS='; '; echo "${why[*]:-all hooks present: publish_play gate, android_build post-build run, integration test, androidTest runner, gcloud}")
  rpc rg_runner_verdict_write "$(jq -nc --argjson ok "$ok" --arg d "$detail" \
        --arg h "$(git rev-parse --short HEAD 2>/dev/null || echo '')" \
        '{p_name:"android_testlab_gate_wired",p_ok:$ok,p_detail:$d,p_payload:{change:2076},p_build_hash:$h}')" >/dev/null || true
  echo "TESTLAB selfcheck $([ "$ok" = true ] && echo ok || echo FAILED) — $detail"
  [ "$ok" = true ]; exit $?
fi

# ── plan ──────────────────────────────────────────────────────────────────────
if [ "$MODE" = "plan" ]; then
  rpc android_testlab_plan "$(jq -nc --argjson ids "$ids_json" '{p_command_ids:(if ($ids|length)==0 then null else $ids end)}')" | jq -c .
  exit 0
fi

# ── gate ──────────────────────────────────────────────────────────────────────
if [ "$MODE" = "gate" ]; then
  g=$(rpc android_testlab_gate "$(jq -nc --arg t "$TRACK" --arg k "$KIND" --arg c "$COMMIT" --arg v "$VCODE" \
        '{p_track:$t,p_kind:$k,p_commit:(if $c=="" then null else $c end),p_version_code:(if $v=="" then null else ($v|tonumber) end)}')")
  echo "TESTLAB gate $([ "$(jqr '.allowed // false' <<<"$g")" = true ] && echo allowed || echo REFUSED) — $(jqr '.reason // "no answer from android_testlab_gate"' <<<"$g")"
  [ "$(jqr '.allowed // false' <<<"$g")" = true ]; exit $?
fi

# ── preflight (no run, no quota) ──────────────────────────────────────────────
if [ "$MODE" = "preflight" ]; then
  cfg=$(rpc dev_build_rules '{}' | jq -c '.android_testlab // {}')
  PROJECT=$(jqr '.project // "medibo-23aee"' <<<"$cfg"); SECRET=$(jqr '.secret_name // "GCP_SA_KEY"' <<<"$cfg")
  WANT_MODEL=$(jqr '.device.model // "MediumPhone.arm"' <<<"$cfg"); WANT_VERSION=$(jqr '.device.version // "33"' <<<"$cfg")
  FALLBACKS=$(jq -c '.fallback_models // []' <<<"$cfg")
  if ! load_credential "$SECRET"; then
    echo "TESTLAB preflight BLOCKED — $([ "$CRED_WHY" = missing ] && echo "Vault secret $SECRET is missing" || echo "$CRED_WHY")"; exit 2
  fi
  activate || { echo "TESTLAB preflight BLOCKED — gcloud could not activate the $SECRET service account"; exit 2; }
  if pick_device; then echo "TESTLAB preflight ok — ${SA_EMAIL:-?} on $PROJECT can run Test Lab; device $DEV_MODEL API $DEV_VERSION"; exit 0; fi
  echo "TESTLAB preflight BLOCKED — $WHY on $PROJECT as ${SA_EMAIL:-?} (see $LOG)"; exit 2
fi

[ "$MODE" = "run" ] || { echo "android_testlab: usage — run|gate|preflight|plan|selfcheck (see --help)" >&2; exit 2; }

# ── 1. begin: the backend decides ─────────────────────────────────────────────
begin=$(rpc android_testlab_begin "$(jq -nc --argjson ids "$ids_json" --arg rel "$REL" --arg c "$COMMIT" \
          --arg vc "$VCODE" --arg vn "$VNAME" --arg t "$TRACK" --argjson rh "$REHEARSAL" --arg w "$WORKER" \
          '{p_command_ids:(if ($ids|length)==0 then null else $ids end),
            p_release_id:(if $rel=="" then null else ($rel|tonumber) end),
            p_commit:(if $c=="" then null else $c end),
            p_version_code:(if $vc=="" then null else ($vc|tonumber) end),
            p_version_name:(if $vn=="" then null else $vn end),
            p_track:(if $t=="" then null else $t end),
            p_rehearsal:$rh, p_worker:$w}')")
if [ "$(jqr '.ok // false' <<<"$begin")" != "true" ]; then
  echo "TESTLAB error — android_testlab_begin did not answer: $(head -c 200 <<<"$begin")"; exit 2
fi
RUN_ID=$(jqr '.run_id // empty' <<<"$begin")
STATUS=$(jqr '.status' <<<"$begin")
if [ "$(jqr '.allowed // false' <<<"$begin")" != "true" ]; then
  say "$STATUS" "$(jqr '.reason' <<<"$begin")"
  [ "$STATUS" = skipped ] && exit 3; exit 2
fi
PLAN_CSV=$(jqr '.plan | join(",")' <<<"$begin")
PROJECT=$(jqr '.project' <<<"$begin"); SECRET=$(jqr '.secret_name' <<<"$begin")
WANT_MODEL=$(jqr '.device.model // "MediumPhone.arm"' <<<"$begin"); WANT_VERSION=$(jqr '.device.version // "33"' <<<"$begin")
DEV_LOCALE=$(jqr '.device.locale // "en"' <<<"$begin"); DEV_ORIENT=$(jqr '.device.orientation // "portrait"' <<<"$begin")
FALLBACKS=$(jq -c '.fallback_models // []' <<<"$begin")
TIMEOUT_S=$(jqr '.timeout_s // 600' <<<"$begin"); TARGET=$(jqr '.test_target' <<<"$begin")
HISTORY=$(jqr '.results_history // "medibo-testlab"' <<<"$begin"); PULL_DIR=$(jqr '.pull_dir // "/sdcard/Download/medibo_testlab"' <<<"$begin")
PREFIX=$(jqr '.results_prefix' <<<"$begin"); COPY=$(jq -c '.copy // {}' <<<"$begin")
copy() { jqr --arg k "$1" '.[$k] // empty' <<<"$COPY"; }
log "── run #$RUN_ID: cmds=$ids_json commit=${COMMIT:0:8} code=${VCODE:-–} track=${TRACK:-–} plan=$PLAN_CSV quota $(jqr '.quota_used' <<<"$begin")/$(jqr '.quota' <<<"$begin") ──"

# ── 2. the credential, the project, the device ───────────────────────────────
if ! load_credential "$SECRET"; then
  if [ "$CRED_WHY" = missing ]; then why=$(fill "$(copy missing_secret)" "secret=$SECRET"); else why="$CRED_WHY"; fi
  finish blocked "$why"; say blocked "$SUMMARY"; exit 2
fi
activate || { finish blocked "gcloud could not activate the $SECRET service account"; say blocked "$SUMMARY"; exit 2; }
if ! pick_device; then
  case "$WHY" in
    api_disabled)  why=$(fill "$(copy api_disabled)" "project=$PROJECT") ;;
    no_permission) why=$(fill "$(copy no_permission)" "project=$PROJECT") ;;
    quota)         why="$(copy quota_gcloud)"; finish quota "$why"; say quota "$SUMMARY"; exit 2 ;;
    *)             why="Test Lab device catalogue unreadable on $PROJECT as ${SA_EMAIL:-?} — $(tail -c 200 "$SHM/catalogue.err" 2>/dev/null | tr '\n' ' ')" ;;
  esac
  finish blocked "$why"; say blocked "$SUMMARY"; exit 2
fi

# ── 3. the two APKs (under the build semaphore) ───────────────────────────────
# CMD #2100 — flavored outputs: app-<flavor>-debug.apk and the androidTest APK
# under its flavor directory; the Gradle task carries the flavor in its name.
APP="build/app/outputs/flutter-apk/app-${FLAVOR}-debug.apk"
TEST="build/app/outputs/apk/androidTest/${FLAVOR}/debug/app-${FLAVOR}-debug-androidTest.apk"
FLAVOR_TASK="$(printf '%s' "$FLAVOR" | sed 's/^./\U&/')"
build_apks() {
  rm -f "$APP" "$TEST"
  mkdir -p /dev/shm/gtmp
  flutter build apk --debug --flavor "$FLAVOR" -t "$TARGET" \
    "--dart-define=TESTLAB_PLAN=$PLAN_CSV" "--dart-define=TESTLAB_RUN_ID=$RUN_ID" \
    "--dart-define=TESTLAB_OUT=$PULL_DIR" >>"$LOG" 2>&1 || return 1
  ( cd android && ./gradlew -q "app:assemble${FLAVOR_TASK}DebugAndroidTest" -Ptarget="$REPO/$TARGET" \
      -Pdart-defines="$(printf 'TESTLAB_PLAN=%s' "$PLAN_CSV" | base64 -w0),$(printf 'TESTLAB_RUN_ID=%s' "$RUN_ID" | base64 -w0),$(printf 'TESTLAB_OUT=%s' "$PULL_DIR" | base64 -w0)" ) >>"$LOG" 2>&1 || return 1
  [ -f "$APP" ] && [ -f "$TEST" ]
}
log "building the instrumentation APKs ($TARGET)…"
exec 8>"$RUNNER/.build.sem"
flock -w 3600 8 || true
if ! build_apks; then
  why=$(fill "$(copy build_failed)" "detail=$(tail -c 300 "$LOG" | tr '\n' ' ' | sed 's/  */ /g')")
  flock -u 8; finish error "$why"; say error "$SUMMARY"; exit 2
fi
flock -u 8
log "APKs ready: $(stat -c%s "$APP") + $(stat -c%s "$TEST") bytes"

# ── 4. ONE blocking gcloud call ──────────────────────────────────────────────
RESULTS_DIR="run-${RUN_ID}-$(date -u +%Y%m%d%H%M%S)"
OUT="$SHM/matrix.json"; ERR="$SHM/matrix.err"
log "gcloud firebase test android run … device $DEV_MODEL API $DEV_VERSION, timeout ${TIMEOUT_S}s"
timeout $((TIMEOUT_S + 420)) gcloud firebase test android run --type instrumentation \
  --app "$APP" --test "$TEST" \
  --device "model=$DEV_MODEL,version=$DEV_VERSION,locale=$DEV_LOCALE,orientation=$DEV_ORIENT" \
  --timeout "${TIMEOUT_S}s" --record-video --directories-to-pull "$PULL_DIR" \
  --results-history-name "$HISTORY" --results-dir "$RESULTS_DIR" \
  --num-flaky-test-attempts 0 --no-use-orchestrator --project "$PROJECT" \
  --format=json --quiet >"$OUT" 2>"$ERR"
RC=$?
cat "$ERR" >>"$LOG"
CONSOLE_URL=$(grep -oE 'https://console\.firebase\.google\.com/[^] ]+' "$ERR" | head -1)
MATRIX_ID=$(grep -oE 'matrices/[A-Za-z0-9_-]+' "$ERR" | head -1 | cut -d/ -f2)
RESULTS_GS=$(grep -oE 'storage/browser/[^] ]+' "$ERR" | head -1 | sed 's#storage/browser/#gs://#; s#/$##')
OUTCOME=$(jq -c '.' "$OUT" 2>/dev/null || echo '{}')
[ "$(jq -r 'type' <<<"$OUTCOME")" = "object" ] || OUTCOME=$(jq -c '{matrix:.}' <<<"$OUTCOME")
log "gcloud exit $RC · matrix ${MATRIX_ID:-?} · results ${RESULTS_GS:-?}"

# ── 5. the evidence: video, logcat, screenshots, per-check JSON ──────────────
PROOFS='[]'; CHECKS='[]'
if [ -n "$RESULTS_GS" ]; then
  mkdir -p "$SHM/art"
  gcloud storage ls -r "$RESULTS_GS/**" >"$SHM/ls.txt" 2>>"$LOG" || true
  fetch() { # <gs-uri> <local-name> <kind> <content-type>
    local uri="$1" name="$2" kind="$3" ct="$4"
    gcloud storage cp "$uri" "$SHM/art/$name" >>"$LOG" 2>&1 || return 0
    [ -s "$SHM/art/$name" ] || return 0
    if proof_upload "$SHM/art/$name" "$PREFIX/$name" "$ct"; then
      PROOFS=$(jq -c --arg k "$kind" --arg p "$PREFIX/$name" '. + [{kind:$k,path:$p}]' <<<"$PROOFS")
    fi
  }
  u=$(grep -E '/video\.mp4$' "$SHM/ls.txt" | head -1); [ -n "$u" ] && fetch "$u" video.mp4 video video/mp4
  u=$(grep -E '/logcat$' "$SHM/ls.txt" | head -1);    [ -n "$u" ] && fetch "$u" logcat.txt logcat text/plain
  u=$(grep -E '/checks\.json$' "$SHM/ls.txt" | head -1); [ -n "$u" ] && fetch "$u" checks.json checks application/json
  n=0
  for u in $(grep -E '\.png$' "$SHM/ls.txt" | head -6); do
    n=$((n+1)); fetch "$u" "shot-$n-$(basename "$u")" screenshot image/png
  done
  [ -s "$SHM/art/checks.json" ] && CHECKS=$(jq -c 'if type=="array" then . else (.checks // []) end' "$SHM/art/checks.json" 2>/dev/null || echo '[]')
fi
log "proofs: $(jq -r 'length' <<<"$PROOFS") stored under $PREFIX"

# ── 6. the verdict ────────────────────────────────────────────────────────────
if [ "$RC" -eq 0 ]; then
  [ "$CHECKS" = "[]" ] && CHECKS=$(jq -nc --arg p "$PLAN_CSV" '[$p | split(",")[] | select(.!="") | {key:., ok:true, detail:""}]')
  finish passed "" "$CHECKS" "$PROOFS" "$OUTCOME"; say passed "$SUMMARY"; exit 0
fi
kind=$(classify_gcloud_error "$ERR")
if [ "$kind" = quota ]; then
  finish quota "$(copy quota_gcloud)" "$CHECKS" "$PROOFS" "$OUTCOME"; say quota "$SUMMARY"; exit 2
fi
case "$RC" in
  10|124)
    if [ "$RC" -eq 124 ] || grep -qi 'timed out' "$ERR"; then why=$(fill "$(copy timeout)" "timeout=${TIMEOUT_S}s");
    else why=$(jq -r '[.[]? | select(.outcome!=null) | "\(.axis_value // .device // "device"): \(.outcome) \(.test_details // "")"] | join("; ")' "$OUT" 2>/dev/null | head -c 300); fi
    [ -n "$why" ] || why="one or more checks failed on the device"
    finish failed "$why" "$CHECKS" "$PROOFS" "$OUTCOME"; say failed "$SUMMARY"; exit 1 ;;
  *)
    case "$kind" in
      api_disabled)  why=$(fill "$(copy api_disabled)" "project=$PROJECT") ;;
      no_permission) why=$(fill "$(copy no_permission)" "project=$PROJECT") ;;
      *)             why="$(fill "$(copy infra)" "rc=$RC") $(grep -m1 -E '^ERROR' "$ERR" | head -c 200)" ;;
    esac
    finish error "$why" "$CHECKS" "$PROOFS" "$OUTCOME"; say error "$SUMMARY"; exit 2 ;;
esac
