#!/usr/bin/env bash
# Regression guard: gemini-ocr must return VERBATIM text, never expanded/official names.
# Run after every gemini-ocr deploy. Exit 1 = deploy failed.
set -euo pipefail

OCR_URL="https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr"
PASS=0
FAIL=0

check() {
  local label="$1"
  local input="$2"
  local must_contain="$3"
  local must_not_contain="$4"

  # Send a text-only prompt (no image) to test the prompt contract
  local resp
  resp=$(curl -sf -X POST "$OCR_URL" \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": \"Return a JSON array: [{\\\"seen\\\": \\\"${input}\\\", \\\"confidence\\\": \\\"high\\\"}]. Do not modify the text.\"}" \
    2>/dev/null || echo '{"error":"curl failed"}')

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
if [[ $FAIL -gt 0 ]]; then
  echo "DEPLOY FAILED — gemini-ocr is expanding/substituting company names"
  exit 1
fi
echo "All verbatim checks passed."
