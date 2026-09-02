#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# scripts/ui_copy_param_check.sh — CHANGE #686 — the OTHER half of the bug.
#
# Om photographed "Ordered by: ${row.pharmacy.isNotEmpty ?" on the admin
# Customer order tab. That defect had TWO halves:
#
#   1. the ui_copy VALUE was Dart source instead of a sentence  →  guarded in
#      SQL by ui_copy_is_source_code() + the ui_copy_no_dart_source CHECK.
#   2. the call site passed {a}/{b} at a template that takes {name}  →  NOT
#      guarded by anything, because no single place can see both sides: SQL
#      cannot read Dart, and a protected test cannot reach the database.
#
# This script is that single place. It reads every cf()/c() call site out of
# lib/ and every template out of the LIVE ui_copy table, and reports the three
# ways the two can disagree:
#
#   missing_param   template wants {x}, the call site never passes it
#                   → cf() leaves the slot, _stripUnresolved deletes it, and
#                     the reader loses the value (exactly Om's header).
#   unused_param    the call site passes 'x', the template never uses it
#                   → the value is silently dropped on the floor.
#   unfilled_c      a key with a {slot} is read with c(), which fills nothing.
#
# It is a REPORT, never a deploy gate: it runs post-deploy beside rg_check.
# Enforcement lives where it always does — the rows it writes make the rg
# behaviour test c686_ui_copy_params go red, and dev_cmd_complete() RAISES on
# a red guard, so the command that introduced a mismatch cannot be marked done.
#
#   bash scripts/ui_copy_param_check.sh          # scan + post
#   bash scripts/ui_copy_param_check.sh --dry    # scan + print, post nothing
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRY=0; [ "${1:-}" = "--dry" ] && DRY=1
DBURL_FILE="$HOME/.medibo/dburl"
[ -f "$DBURL_FILE" ] || { echo "ui_copy_param_check: no $DBURL_FILE — skipped"; exit 0; }

# The live templates, as TSV. Single-brace {slot} only: {{slot}} is the
# backend's own notification-template convention and is filled server-side.
TPL_FILE="$(mktemp)"
trap 'rm -f "$TPL_FILE"' EXIT
psql "$(cat "$DBURL_FILE")" -At -F$'\t' \
  -c "select key, replace(replace(value #>> '{}', E'\t', ' '), E'\n', ' ') from ui_copy" \
  > "$TPL_FILE" 2>/dev/null \
  || { echo "ui_copy_param_check: database unreachable — skipped"; exit 0; }
[ -s "$TPL_FILE" ] || { echo "ui_copy_param_check: no templates read — skipped"; exit 0; }

REPORT="$(python3 - "$ROOT" "$TPL_FILE" <<'PY'
import json, os, re, sys

root = sys.argv[1]
templates = {}
for line in open(sys.argv[2], encoding='utf-8', errors='replace').read().splitlines():
    if '\t' in line:
        k, v = line.split('\t', 1)
        templates[k] = v

SLOT = re.compile(r'(?<!\{)\{([A-Za-z0-9_]+)\}(?!\})')

def slots(v):
    return set(SLOT.findall(v))

# cf('key', { 'a': …, 'b': … })  — brace-matched so nested maps/ternaries in the
# VALUES cannot end the scan early. Only the keys of the top-level map count.
CF = re.compile(r"""(?<![A-Za-z0-9_])cf\(\s*'([A-Za-z0-9_.]+)'\s*,\s*\{""")
C  = re.compile(r"""(?<![A-Za-z0-9_])c\(\s*'([A-Za-z0-9_.]+)'\s*\)""")
PARAM = re.compile(r"""'([A-Za-z0-9_]+)'\s*:""")

findings = []
for dirpath, _dirs, files in os.walk(os.path.join(root, 'lib')):
    for fn in files:
        if not fn.endswith('.dart'):
            continue
        path = os.path.join(dirpath, fn)
        rel = os.path.relpath(path, root)
        src = open(path, encoding='utf-8', errors='replace').read()
        # A cf() written inside a doc comment is documentation, not a call
        # site: ui_copy.dart's own header explains the #633 bug with a literal
        # cf('admin_customer.failed_to_load', {'a': …}) example, and scanning
        # it would report the very defect the comment says was fixed. Comments
        # are blanked (not deleted) so reported line numbers stay true.
        src = re.sub(r'/\*.*?\*/', lambda m: re.sub(r'[^\n]', ' ', m.group(0)),
                     src, flags=re.S)
        src = re.sub(r'(?m)//[^\n]*', lambda m: ' ' * len(m.group(0)), src)

        for m in CF.finditer(src):
            key = m.group(1)
            i, depth = m.end() - 1, 0
            while i < len(src):
                if src[i] == '{':
                    depth += 1
                elif src[i] == '}':
                    depth -= 1
                    if depth == 0:
                        break
                i += 1
            body = src[m.end():i]
            # Only top-level keys of THIS map: drop anything inside a nested {}.
            flat, depth2 = [], 0
            for ch in body:
                if ch == '{':
                    depth2 += 1
                elif ch == '}':
                    depth2 -= 1
                elif depth2 == 0:
                    flat.append(ch)
            passed = set(PARAM.findall(''.join(flat)))
            if key not in templates:
                continue
            want = slots(templates[key])
            line = src.count('\n', 0, m.start()) + 1
            for miss in sorted(want - passed):
                findings.append({'kind': 'missing_param', 'key': key, 'param': miss,
                                 'file': rel, 'line': line, 'template': templates[key]})
            for extra in sorted(passed - want):
                findings.append({'kind': 'unused_param', 'key': key, 'param': extra,
                                 'file': rel, 'line': line, 'template': templates[key]})

        for m in C.finditer(src):
            key = m.group(1)
            if key not in templates:
                continue
            want = slots(templates[key])
            if want:
                line = src.count('\n', 0, m.start()) + 1
                findings.append({'kind': 'unfilled_c', 'key': key,
                                 'param': ','.join(sorted(want)),
                                 'file': rel, 'line': line, 'template': templates[key]})

# One row per (kind, key, param) — the same key read from three screens is one
# defect, not three.
seen, unique = set(), []
for f in findings:
    sig = (f['kind'], f['key'], f['param'])
    if sig in seen:
        continue
    seen.add(sig)
    unique.append(f)
unique.sort(key=lambda f: (f['kind'], f['key'], f['param']))
print(json.dumps({'count': len(unique), 'findings': unique}))
PY
)"

[ -z "$REPORT" ] && { echo "ui_copy_param_check: scanner produced nothing — skipped"; exit 0; }
COUNT="$(printf '%s' "$REPORT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo 0)"

if [ "$DRY" = "1" ]; then
  printf '%s\n' "$REPORT" | python3 -m json.tool
  echo "ui_copy_param_check: $COUNT mismatch(es) (dry run — nothing posted)"
  exit 0
fi

"$HOME/mediBO-runner/devcmd.sh" rpc ui_copy_param_drift_report \
  "$(jq -nc --argjson r "$REPORT" '{p_report:$r}')" >/dev/null 2>&1 \
  || echo "ui_copy_param_check: report POST failed (non-fatal)"
echo "ui_copy_param_check: $COUNT mismatch(es) recorded"
exit 0
