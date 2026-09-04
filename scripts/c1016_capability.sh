#!/usr/bin/env bash
# CHANGE #1016 — the ZERO CAPABILITY LOSS checklist, three roles.
#
#   bash scripts/c1016_capability.sh            # rewrites docs/STAFF_IA_CAPABILITY.md, exit 1 on any FAIL
#
# For super admin, admin and partner it impersonates a real login of that role
# in psql (request.jwt.claims + role authenticated — the same identity the app
# carries), then:
#   OLD  = every feature the role could open under the pre-#1016 registry
#          (nav_parity_baseline × the OLD visibility predicate: roles_allowed +
#          admin_access(), or partner_eligible + partner_access()).
#   NEW  = every door the role is offered now: staff_nav() tabs + every tile of
#          staff_home(tab) for each visible tab + the nav_redirect map.
#   PASS = the old feature's canonical home (nav_parity_report) is a visible
#          tile, a visible tab, or an old route the redirect map sends to one.
# Screens are re-homed, not rewritten: the git diff of this change touches no
# screen body except the dashboard (trimmed under v2, whole under the v1 flag)
# and the supplier tab label, so a screen's own buttons are unchanged and the
# capability question is exactly "can this role still reach it" — which is what
# this proves, row by row, from the backend's own payloads.
set -uo pipefail
cd "$(dirname "$0")/.."
DB="$(cat "${MEDIBO_DBURL_FILE:-$HOME/.medibo/dburl}")"
OUT=docs/STAFF_IA_CAPABILITY.md
TMP="${TMPDIR:-/tmp}/c1016_cap"; mkdir -p "$TMP"
rc=0

# role label → the login to impersonate
declare -A WHO=(
  [super_admin]="select u.id, u.email from auth.users u join public.admins a on lower(a.email)=lower(u.email) where coalesce(a.is_super,false) order by a.created_at limit 1"
  [admin]="select u.id, u.email from auth.users u where u.email='test.admin@medibo.in'"
  [partner]="select u.id, u.email from auth.users u where u.email='test.partner1@medibo.in'"
)

CHECK_SQL=$(cat <<'SQL'
with me as (select coalesce(public.get_my_role(),'none') as role, public.my_partner_id() as partner),
tabs as (select (t->>'key') as tab_key, (t->>'route_key') as route_key, coalesce((t->>'visible')::bool,false) as visible
           from jsonb_array_elements(public.staff_nav()->'tabs') t),
tiles as (select tb.tab_key, (i->>'feature_key') as feature_key, (i->>'route_key') as route_key
            from tabs tb,
                 jsonb_array_elements(public.staff_home(tb.tab_key)->'sections') s,
                 jsonb_array_elements(s->'items') i
           where tb.visible),
newvis as (select feature_key, route_key from tiles
           union select null, route_key from tabs where visible),
redir as (select e.key as from_route, e.value->>'to' as to_route from jsonb_each(public.staff_nav()->'redirects') e),
old as (select b.feature_key, b.label, b.surface, b.group_label, b.route_key
          from public.nav_parity_baseline b
          left join public.feature_registry f on f.feature_key = b.feature_key
          cross join me
         where b.is_active and coalesce(b.route_key,'') <> ''
           and case when me.partner is not null
                    then coalesce(f.partner_eligible,false)
                         and coalesce(public.partner_access(b.feature_key, me.partner),'none') <> 'none'
                    when b.surface = 'dev_tools' then me.role = 'super_admin' and me.role = any (b.roles_allowed)
                    else me.role = any (b.roles_allowed)
                         and coalesce(public.admin_access(b.feature_key),'none') <> 'none' end),
map as (select r->>'old_key' as old_key, r->>'new_key' as new_key, r->>'new_route' as new_route,
               r->>'new_home' as new_home, r->>'new_label' as new_label, r->>'kind' as kind
          from jsonb_array_elements(public.nav_parity_report()->'rows') r),
-- An in-page tab (Customers / Suppliers / Fulfill page's own tab row) is not a
-- home tile: its door is the parent page, and the row itself stays gated by
-- the same access matrix (allowedTabIndexes / fulfill_tabs) it was before.
inpage as (select f.feature_key,
                  case f.surface when 'customer_tab' then 'customers' when 'supplier_tab' then 'suppliers'
                                 when 'fulfill_tab' then 'fulfill' end as parent_tab
             from public.feature_registry f where f.surface in ('customer_tab','supplier_tab','fulfill_tab'))
select o.feature_key, o.label, o.surface || ' · ' || coalesce(o.group_label,''), o.route_key,
       coalesce(m.new_home, case when o.surface = 'profile' then 'header' end, '?'),
       coalesce(m.new_label, case when o.surface = 'profile' then o.label end, '?'),
       coalesce(m.new_route, case when o.surface = 'profile' then o.route_key end, '?'),
       coalesce(m.kind, case when o.surface = 'profile' then 'shell' end, 'unmapped'),
       case when o.surface = 'profile' then 'SHELL'   -- the identity menu is the shell's own; proven from the Dart below
            when exists (select 1 from newvis n where n.route_key = m.new_route)
              or exists (select 1 from newvis n where n.feature_key = m.new_key)
              or exists (select 1 from redir rd join newvis n on n.route_key = rd.to_route where rd.from_route = o.route_key)
              or exists (select 1 from inpage ip join tabs tb on tb.tab_key = ip.parent_tab and tb.visible
                          where ip.feature_key = m.new_key)
            then 'PASS' else 'FAIL' end
  from old o left join map m on m.old_key = o.feature_key
 order by case coalesce(m.new_home,'?') when 'dashboard' then 1 when 'customers' then 2 when 'suppliers' then 3
                                        when 'fulfill' then 4 when 'money' then 5 when 'more' then 6 else 9 end,
          m.new_label, o.feature_key;
SQL
)

TABS_SQL="select string_agg((t->>'key') || case when coalesce((t->>'visible')::bool,false) then '' else ' (hidden)' end, ' · ' order by n)
            from jsonb_array_elements(public.staff_nav()->'tabs') with ordinality as x(t, n);"

run_role() {  # <role> → writes $TMP/<role>.rows and $TMP/<role>.tabs
  local role="$1" who="${WHO[$1]}"
  local ident; ident=$(psql "$DB" -At -F'|' -c "$who")
  local uid="${ident%%|*}" email="${ident##*|}"
  [ -z "$uid" ] && { echo "no login for $role"; return 1; }
  {
    echo "begin;"
    echo "select set_config('request.jwt.claims', json_build_object('sub','$uid','email','$email','role','authenticated')::text, true);"
    echo "set local role authenticated;"
    echo "\\o $TMP/$role.tabs"; echo "$TABS_SQL"
    echo "\\o $TMP/$role.rows"; echo "$CHECK_SQL"
    echo "\\o"; echo "rollback;"
  } | psql "$DB" -At -F'|' -q >/dev/null 2>"$TMP/$role.err" || { cat "$TMP/$role.err"; return 1; }
  echo "$email" > "$TMP/$role.who"
  # surface='profile' rows (view profile, logout) are the identity menu the
  # shell draws itself for every role — never a homed feature, so the parity
  # report leaves them out. Their door is a shell case, proven from the Dart.
  awk -F'|' -v OFS='|' '$9=="SHELL" { cmd="grep -c \"case '"'"'" $4 "'"'"':\" lib/screens/home_shell.dart"; cmd | getline n; close(cmd);
                                       $9 = (n+0 > 0) ? "PASS" : "FAIL" } { print }' "$TMP/$role.rows" > "$TMP/$role.rows2" \
    && mv "$TMP/$role.rows2" "$TMP/$role.rows"
}

for r in super_admin admin partner; do run_role "$r" || rc=1; done

{
  echo "# Staff app capability checklist — CHANGE #1016"
  echo
  echo "Generated by \`scripts/c1016_capability.sh\` on $(date -u +%Y-%m-%dT%H:%MZ) from the live backend."
  echo "Each role is impersonated in psql exactly as the app authenticates it; OLD is the pre-change"
  echo "registry baseline filtered by that role's own access matrix, NEW is \`staff_nav()\` + \`staff_home()\`"
  echo "+ the redirect map for the same login. A row is **PASS** when the old feature's one new home is a"
  echo "tile or tab the role is offered (or its old route redirects to one). Screens are re-homed, not"
  echo "rewritten, so their own buttons/actions are untouched; reachability is the capability."
  echo
  echo "| Role | Login | Tabs offered | Old features | PASS | FAIL |"
  echo "|---|---|---|---|---|---|"
  for r in super_admin admin partner; do
    n=$(wc -l < "$TMP/$r.rows"); p=$(grep -c '|PASS$' "$TMP/$r.rows"); f=$(grep -c '|FAIL$' "$TMP/$r.rows")
    [ "$f" -gt 0 ] && rc=1
    echo "| $r | $(cat "$TMP/$r.who") | $(cat "$TMP/$r.tabs") | $n | $p | **$f** |"
  done
  echo
  for r in super_admin admin partner; do
    echo "## $r — $(cat "$TMP/$r.who")"
    echo
    echo "| Old feature | Old label | Old surface · group | Old route | New home | New tile | New route | Kind | Result |"
    echo "|---|---|---|---|---|---|---|---|---|"
    awk -F'|' '{printf "| `%s` | %s | %s | `%s` | **%s** | %s | `%s` | %s | %s |\n", $1,$2,$3,$4,$5,$6,$7,$8,$9}' "$TMP/$r.rows"
    echo
  done
} > "$OUT"

for r in super_admin admin partner; do
  echo "$r: $(wc -l < "$TMP/$r.rows") old features, $(grep -c '|PASS$' "$TMP/$r.rows") PASS, $(grep -c '|FAIL$' "$TMP/$r.rows") FAIL — tabs: $(cat "$TMP/$r.tabs")"
done
echo "c1016_capability: wrote $OUT (rc=$rc)"; exit $rc
