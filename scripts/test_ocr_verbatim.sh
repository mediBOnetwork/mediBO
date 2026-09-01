#!/usr/bin/env bash
# Regression guard: gemini-ocr must return VERBATIM text, never expanded/official names.
# Run after every gemini-ocr deploy. Exit 1 = deploy failed.
set -euo pipefail

OCR_URL="https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr"
PASS=0
FAIL=0
INFRA=""

# CMD #423 — THE GUARD WAS LYING. Every call below went out with no
# Authorization header, so gemini-ocr (verify_jwt on, like every other function
# in this project) answered 401, `curl -sf` returned nothing, and the script
# printed "DEPLOY FAILED — gemini-ocr is expanding/substituting company names"
# for six checks that had never reached the model. A guard that cries wolf on a
# healthy deploy trains people to ignore it, which is worse than no guard.
#
# So: authenticate like a real caller, and tell the two failures apart. A
# verbatim breach still fails the deploy exactly as before — nothing about the
# naming contract is relaxed — but an infrastructure failure (401, 500, Vertex
# billing disabled) now says so in its own words instead of accusing the model.
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
if [[ -z "$KEY" && -f "$HOME/mediBO-runner/runner.env" ]]; then
  KEY=$(grep -oP '(?<=^SERVICE_ROLE_KEY=).*' "$HOME/mediBO-runner/runner.env" | tr -d '"' || true)
fi
if [[ -z "$KEY" ]]; then
  echo "test_ocr_verbatim: no service-role key (set SUPABASE_SERVICE_ROLE_KEY)" >&2
  exit 1
fi

check() {
  local label="$1"
  local input="$2"
  local must_contain="$3"
  local must_not_contain="$4"

  # Send a text-only prompt (no image) to test the prompt contract
  local resp
  resp=$(curl -s -X POST "$OCR_URL" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": \"Return a JSON array: [{\\\"seen\\\": \\\"${input}\\\", \\\"confidence\\\": \\\"high\\\"}]. Do not modify the text.\"}" \
    2>/dev/null || echo '{"error":"curl failed"}')

  # The model never answered — that is an infrastructure fault, not a naming
  # breach, and it must not be reported as one.
  if echo "$resp" | grep -q '"error"'; then
    local why
    why=$(echo "$resp" | sed -E 's/.*"error"[: ]*"?//; s/".*//' | head -c 160)
    echo "INFRA [$label]: gemini-ocr did not answer — $why"
    INFRA="$why"
    ((FAIL++)) || true
    return
  fi

  local ok=1
  if [[ -n "$must_contain" ]] && ! echo "$resp" | grep -qi "$must_contain"; then
    echo "FAIL [$label]: expected '$must_contain' in response"
    echo "  Response: $resp"
    ok=0
  fi
  if [[ -n "$must_not_contain" ]] && echo "$resp" | grep -qi "$must_not_contain"; then
    echo "FAIL [$label]: forbidden '$must_not_contain' found in response"
    echo "  Response: $resp"
    ok=0
  fi
  if [[ $ok -eq 1 ]]; then
    echo "PASS [$label]"
    ((PASS++)) || true
  else
    ((FAIL++)) || true
  fi
}

echo "=== gemini-ocr verbatim regression ==="

# These tokens must come back as-is; their expanded forms are forbidden
check "BIOPHAR verbatim"            "BIOPHAR"            "BIOPHAR"      ""
check "Troikaa no suffix"           "Troikaa"            "Troikaa"      "Pharmaceuticals Ltd"
check "Cipla Diagnostics no parent" "Cipla Diagnostics"  "Cipla Diagnostics" "Cipla Ltd"
check "German Remedies no Zydus"    "German Remedies"    "German Remedies"   "Zydus"
check "Aventis no Sanofi"           "Aventis"            "Aventis"      "Sanofi"
check "gsk lowercase"               "gsk"                "gsk"          "GlaxoSmithKline"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ -n "$INFRA" ]]; then
  echo "DEPLOY BLOCKED — gemini-ocr could not be reached, so the verbatim"
  echo "contract is UNPROVEN (not breached). Cause: $INFRA"
  exit 1
fi
if [[ $FAIL -gt 0 ]]; then
  echo "DEPLOY FAILED — gemini-ocr is expanding/substituting company names"
  exit 1
fi
echo "All verbatim checks passed."
