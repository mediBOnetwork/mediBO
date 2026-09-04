#!/usr/bin/env bash
# CHANGE #1016 — the live proof, three roles.
#   bash scripts/c1016_proof.sh <out-dir>
# admin  : render_verify.js as test.admin — render-log keys + screenshots of
#          Dashboard, Customers (strip), Fulfill (strip), Money, More.
# partner: the playwright partner session (test.partner1) — Money and More.
# super  : the six tabs, the More grid count and the parity report, read
#          through psql impersonation (the super admin has no test password
#          and a canvas cannot be clicked; the payload IS the screen).
set -uo pipefail
OUT="${1:-/tmp/c1016_proof}"; mkdir -p "$OUT"
cd "$(dirname "$0")/.."
DB="$(cat "$HOME/.medibo/dburl")"
rc=0

echo "── admin (test.admin) ──"
node "$HOME/render_verify.js" --keys boot_status,c1016_staff_tabs,c1016_staff_layout,c1016_dashboard_layout \
  --admin-path /admin/go/dashboard --shot "$OUT/admin_dashboard.png" --timeout 75 || rc=1
node "$HOME/render_verify.js" --keys c1016_home_money --admin-path /admin/go/money_home \
  --shot "$OUT/admin_money.png" --timeout 75 || rc=1
node "$HOME/render_verify.js" --keys c1016_home_more --admin-path /admin/go/more \
  --shot "$OUT/admin_more.png" --timeout 75 || rc=1
node "$HOME/render_verify.js" --keys c1016_strip_customers --admin-path /admin/go/customers \
  --shot "$OUT/admin_customers.png" --timeout 75 || rc=1
node "$HOME/render_verify.js" --keys c1016_strip_fulfill --admin-path /admin/go/fulfillment \
  --shot "$OUT/admin_fulfill.png" --timeout 75 || rc=1

echo "── partner (test.partner1) ──"
for p in money_home more fulfillment; do
  node "$HOME/mediBO-runner/journeys/shot_partner_c398.js" "$OUT/partner_$p.png" 1280 800 "https://medibo.in/admin/go/$p" \
    | grep -oE "c1016_[a-z_]+=[^;]*" | sort -u | tee "$OUT/partner_$p.keys" || rc=1
done

echo "── super admin (payload) ──"
(echo "begin; select set_config('request.jwt.claims', json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text, true) from auth.users u join public.admins a on lower(a.email)=lower(u.email) where coalesce(a.is_super,false) limit 1; set local role authenticated;"
 cat /tmp/c1016_role_proof.sql; echo "rollback;") | psql "$DB" -At -F' | ' 2>&1 | grep -vE "^(BEGIN|SET|ROLLBACK|\{\"sub\"|\s*$)" | tee "$OUT/super_payload.txt"
psql "$DB" -Atc "select 'parity: '||(nav_parity_report()->>'total')||' rows, '||(nav_parity_report()->>'unresolved')||' unresolved'" | tee -a "$OUT/super_payload.txt"
echo "proof rc=$rc"; exit $rc
