#!/usr/bin/env bash
# CHANGE #1017 — the staff visual system, proven live for three roles.
#   bash scripts/c1017_visual_proof.sh <out-dir>
# admin  : render_verify.js as test.admin — the header scope bar key
#          (c1017_scope_bar) plus the #1016 tabs key, and screenshots of
#          Dashboard (pickers gone from the screen, bar above it) and More
#          (the Appearance door).
# super  : the payload IS the screen — psql impersonation of a real super
#          login: scope block, own tabs, and the previewed bars for admin and
#          partner (view_as active, banner, exit label).
# partner: psql impersonation of a real partner login — zone_locked=true,
#          can_pick_zone=false, the zone label, and NO view_as options.
set -uo pipefail
OUT="${1:-/tmp/c1017_proof}"; mkdir -p "$OUT"
cd "$(dirname "$0")/.."
DB="$(cat "$HOME/.medibo/dburl")"
rc=0
echo "── admin (test.admin) — live render ──"
node "$HOME/render_verify.js" --keys boot_status,c1016_staff_tabs,c1017_scope_bar,c813_header_title \
  --admin-path /admin/go/dashboard --shot "$OUT/after_admin_dashboard.png" --timeout 90 || rc=1
node "$HOME/render_verify.js" --keys c1016_home_more,c1017_scope_bar \
  --admin-path /admin/go/more --shot "$OUT/after_admin_more.png" --timeout 90 || rc=1

impersonate() { # <role: super|partner>
  case "$1" in
    super)   echo "(select json_build_object('sub',u.id,'email',u.email,'role','authenticated')::text from auth.users u join admins a on lower(a.email)=lower(u.email) and coalesce(a.is_super,false) limit 1)";;
    partner) echo "(select json_build_object('sub',pu.auth_user_id,'email',u.email,'role','authenticated')::text from partner_users pu join auth.users u on u.id = pu.auth_user_id limit 1)";;
  esac
}
echo "── super admin — the payload is the screen ──"
psql "$DB" -At <<SQL | tee "$OUT/super_payload.txt"
select set_config('request.jwt.claims', $(impersonate super), false);
select 'scope: ' || (public.staff_nav()->'scope')::text;
select 'own tabs: ' || (select string_agg(t->>'key', ' · ') from jsonb_array_elements(public.staff_nav()->'tabs') t where (t->>'visible')::boolean);
select 'view_as options: ' || (public.staff_nav()->'view_as'->'options')::text;
select 'preview admin: ' || (select string_agg(t->>'key', ' · ') from jsonb_array_elements(public.staff_nav('admin')->'tabs') t where (t->>'visible')::boolean) || ' | banner=' || (public.staff_nav('admin')->'view_as'->>'banner');
select 'preview partner: ' || (select string_agg(t->>'key', ' · ') from jsonb_array_elements(public.staff_nav('partner')->'tabs') t where (t->>'visible')::boolean) || ' | banner=' || (public.staff_nav('partner')->'view_as'->>'banner');
select 'dark tokens v' || (value->>'version') || ' bg=' || (value->'dark'->'colors'->>'bg') from dev_runner_config where key='ui_design';
SQL
grep -q "preview partner: .*banner=Viewing as Partner" "$OUT/super_payload.txt" || { echo "FAIL: partner preview did not answer"; rc=1; }
echo "── partner — zone-locked, no preview ──"
psql "$DB" -At <<SQL | tee "$OUT/partner_payload.txt"
select set_config('request.jwt.claims', $(impersonate partner), false);
select 'scope: ' || (public.staff_nav()->'scope')::text;
select 'view_as can_preview: ' || (public.staff_nav()->'view_as'->>'can_preview') || ' options=' || (public.staff_nav()->'view_as'->'options')::text;
select 'asked for a preview anyway: active=' || (public.staff_nav('admin')->'view_as'->>'active');
SQL
grep -q '"zone_locked": true' "$OUT/partner_payload.txt" || { echo "FAIL: partner is not zone-locked in scope"; rc=1; }
grep -q 'asked for a preview anyway: active=false' "$OUT/partner_payload.txt" || { echo "FAIL: a partner could enter a preview"; rc=1; }
echo "── parity checklist rerun ──"
bash scripts/c1016_capability.sh | tail -4 || rc=1
[ "$rc" = 0 ] && echo "── c1017 proof: PASS ──" || echo "── c1017 proof: FAIL ──"
exit $rc
