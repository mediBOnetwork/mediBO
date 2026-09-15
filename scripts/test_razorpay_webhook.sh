#!/usr/bin/env bash
# test_razorpay_webhook.sh — CHANGE #300
#
# Replays REAL signed Razorpay deliveries against the live razorpay-webhook and
# prints a pass/fail line per case. This is the script that found the
# qr_code.closed defects fixed in migration 20260823_c300_rzp_webhook_close_guard.sql;
# re-run it after any change to razorpay-webhook or rzp_webhook_apply.
#
# It only sends events that are SAFE to send: the ignore sweep and the rejection
# matrix. The money cases (qr_code.credited / qr_code.closed against a real QR)
# are deliberately NOT automated here — they mutate an order and must be run
# against a snapshotted test order, as #300 did.
#
#   RAZORPAY_WEBHOOK_SECRET=... bash scripts/test_razorpay_webhook.sh
#
# The secret is normally an edge-function secret and is NOT on the VM. Without
# it the script still runs the negative cases (which need no valid signature)
# and says so.
set -uo pipefail

URL="${RZP_WEBHOOK_URL:-https://swojhmarmaijkshsbeih.supabase.co/functions/v1/razorpay-webhook}"
SECRET="${RAZORPAY_WEBHOOK_SECRET:-}"
pass=0; fail=0

sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" -r | cut -d' ' -f1; }

# post <raw> <sig-mode>  -> "<status> <body>"
post() {
  local raw="$1" mode="$2" hdr=()
  case "$mode" in
    good)     hdr=(-H "x-razorpay-signature: $(sign "$raw")") ;;
    bad)      hdr=(-H "x-razorpay-signature: $(printf '0%.0s' {1..64})") ;;
    tampered) hdr=(-H "x-razorpay-signature: $(sign "$raw ")") ;;
    none)     hdr=() ;;
  esac
  curl -sS -o /tmp/_rzp_body -w '%{http_code}' -X POST "$URL" \
    -H 'Content-Type: application/json' "${hdr[@]}" --data-binary "$raw"
  printf ' '; cat /tmp/_rzp_body
}

check() { # <label> <expected-status> <expected-body-substring> <raw> <mode>
  local got; got="$(post "$4" "$5")"
  local st="${got%% *}" body="${got#* }"
  if [ "$st" = "$2" ] && [[ "$body" == *"$3"* ]]; then
    printf 'PASS  %-46s %s %s\n' "$1" "$st" "$body"; pass=$((pass+1))
  else
    printf 'FAIL  %-46s %s %s   (wanted %s ~ %s)\n' "$1" "$st" "$body" "$2" "$3"; fail=$((fail+1))
  fi
}

echo "== rejection matrix (no valid signature needed) =="
check "missing signature header"  400 missing_signature '{"event":"qr_code.credited"}' none
check "bad signature"             400 bad_signature     '{"event":"qr_code.credited"}' bad

if [ -z "$SECRET" ]; then
  echo
  echo "RAZORPAY_WEBHOOK_SECRET not set — signed cases skipped."
  echo "Result: $pass passed, $fail failed (negative cases only)."
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

echo
echo "== signed rejection cases =="
check "tampered body, real sig for other bytes" 400 bad_signature '{"event":"qr_code.credited"}' tampered
check "truncated JSON, valid sig"               400 bad_json      '{"event":"qr_code.' good
check "non-JSON body, valid sig"                400 bad_json      'not json at all'     good
check "empty body, valid sig"                   400 bad_json      ''                    good

echo
echo "== every ticked event that we do not handle is ignored quietly =="
for ev in \
  account.activated_kyc_pending account.instantly_activated \
  engage.balance.low_balance engage.inventory.low_stock \
  engage.rewards.denomination_disabled engage.rewards.denomination_enabled \
  engage.rewards.denomination_updated engage.rewards.disabled \
  engage.rewards.discount_updated engage.rewards.enabled \
  engage.rewards.instructions_updated engage.rewards.termsandconditions_updated \
  fund_account.validation.completed fund_account.validation.failed \
  invoice.expired invoice.paid invoice.partially_paid \
  order.notification.delivered order.notification.failed order.paid \
  payment.authorized payment.captured \
  payment.dispute.action_required payment.dispute.closed payment.dispute.created \
  payment.dispute.lost payment.dispute.under_review payment.dispute.won \
  payment.downtime.resolved payment.downtime.started payment.downtime.updated \
  payment.failed \
  payment_link.cancelled payment_link.expired payment_link.paid payment_link.partially_paid \
  qr_code.created \
  refund.created refund.failed refund.processed refund.speed_changed \
  subscription.activated subscription.authenticated subscription.cancelled \
  subscription.charged subscription.completed subscription.halted \
  subscription.paused subscription.pending subscription.resumed subscription.updated \
  settlement.processed transfer.processed some.future.event.v9
do
  raw="{\"entity\":\"event\",\"event\":\"$ev\",\"contains\":[],\"payload\":{},\"created_at\":1787488000}"
  check "$ev" 200 "\"ignored\":\"$ev\"" "$raw" good
done

echo
echo "== a close for a QR we have never seen must report matched:0 =="
raw='{"entity":"event","event":"qr_code.closed","payload":{"qr_code":{"entity":{"id":"qr_NOSUCHQR300","close_reason":"on_demand"}}}}'
check "unknown qr_code.closed -> matched:0" 200 '"matched":0' "$raw" good

echo
echo "Result: $pass passed, $fail failed."
[ "$fail" -eq 0 ]
