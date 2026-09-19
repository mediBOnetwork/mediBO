#!/usr/bin/env bash
# bump_android_version.sh — CMD #2100. The ONE writer of an Android version,
# per flavor. Two product flavors live in android/app/build.gradle.kts:
#   customer → defaultConfig { versionCode / versionName }  + kAndroidVersionCode
#   partner  → create("partner") { versionCode / versionName } + kPartnerAndroidVersionCode
# A bare `sed s/versionCode = .*/` would rewrite BOTH blocks, so this edits the
# one block the flavor owns and the matching Dart constant, and verifies both.
#
#   bash scripts/bump_android_version.sh <flavor> --current      # prints "<code> <name>"
#   bash scripts/bump_android_version.sh <flavor> <code> <name>  # writes, verifies
set -euo pipefail
cd "$(dirname "$0")/.."
FLAVOR="${1:?flavor}"; shift
case "$FLAVOR" in customer|partner) ;; *) echo "unknown flavor $FLAVOR" >&2; exit 2 ;; esac
GRADLE=android/app/build.gradle.kts
if [ "$FLAVOR" = customer ]; then
  DART=lib/services/app_update_feed.dart; CONST=kAndroidVersionCode
else
  DART=lib/build_info.dart; CONST=kPartnerAndroidVersionCode
fi
export FLAVOR GRADLE DART CONST
if [ "${1:-}" = "--current" ]; then
  python3 - <<'PY'
import os,re
s=open(os.environ['GRADLE']).read()
if os.environ['FLAVOR']=='customer':
    blk = re.search(r'defaultConfig\s*\{.*?\n    \}', s, re.S).group(0)
else:
    # the PRODUCT FLAVOR block — signingConfigs has its own create("partner")
    pf = re.search(r'productFlavors\s*\{.*?\n    \}', s, re.S).group(0)
    blk = re.search(r'create\("partner"\)\s*\{.*?\n        \}', pf, re.S).group(0)
print(re.search(r'versionCode = (\d+)', blk).group(1), re.search(r'versionName = "([^"]+)"', blk).group(1))
PY
  exit 0
fi
CODE="${1:?code}"; NAME="${2:?name}"
export CODE NAME
python3 - <<'PY'
import os,re,sys
g=os.environ['GRADLE']; s=open(g).read(); f=os.environ['FLAVOR']; code=os.environ['CODE']; name=os.environ['NAME']
if f=='customer':
    m=re.search(r'(defaultConfig\s*\{.*?\n    \})', s, re.S); off=0
else:
    pf=re.search(r'productFlavors\s*\{.*?\n    \}', s, re.S); off=pf.start()
    m=re.search(r'(create\("partner"\)\s*\{.*?\n        \})', pf.group(0), re.S)
blk=m.group(1); st=off+m.start(1); en=off+m.end(1)
nb=re.sub(r'versionCode = \d+', f'versionCode = {code}', blk, 1)
nb=re.sub(r'versionName = "[^"]+"', f'versionName = "{name}"', nb, 1)
if nb!=blk: open(g,'w').write(s[:st]+nb+s[en:])
d=os.environ['DART']; c=os.environ['CONST']; t=open(d).read()
nt=re.sub(rf'const int {c} = \d+;', f'const int {c} = {code};', t, 1)
if nt!=t: open(d,'w').write(nt)
PY
read -r C N < <(bash "$0" "$FLAVOR" --current)
[ "$C" = "$CODE" ] && [ "$N" = "$NAME" ] && grep -q "const int $CONST = $CODE;" "$DART" \
  || { echo "version bump did not apply to every file for $FLAVOR — refusing to build out of lockstep" >&2; exit 1; }
echo "$FLAVOR: $NAME ($CODE)"
