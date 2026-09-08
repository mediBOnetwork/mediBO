#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Journey: qa-298-114 — an unregistered platform is an ABSENCE, never another
# platform's value.
#
# Retires the blocker found while proving #298: push_config_get() returned
# coalesce(web_api_key, api_key) and coalesce(web_app_id, app_id). Firebase
# project medibo-23aee has an ANDROID app and no WEB app, so the payload handed
# the browser SDK an Android application id. Two failures followed from one
# fallback: Firebase.initializeApp() would have died deep inside the SDK instead
# of the app simply knowing browser push is not set up, and Admin > Push
# notifications printed a fully-populated web app that does not exist — so
# nobody would ever have gone and registered one.
#
# This journey probes PRODUCTION with the same anon key that ships inside the
# web bundle and the APK — the payload every client actually sees — and fails if
# the fallback ever returns, in either direction (web borrowing Android's
# values, or Android borrowing web's).
#
# Usage: bash scripts/journey_push_platform_absence.sh
# Exit 0 = every platform speaks for itself. Exit 1 = a value was borrowed.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail
cd ~/mediBO || exit 1

URL="https://swojhmarmaijkshsbeih.supabase.co"
ANON=$(python3 -c "
import re
s = open('lib/supabase_config.dart').read()
m = re.search(r\"anonKey\s*=\s*'([^']+)'\", s, re.S)
print(m.group(1).replace('\n', '').strip() if m else '')")

if [ -z "$ANON" ]; then
  echo "FAIL: could not read the shipped anon key from lib/supabase_config.dart"
  exit 1
fi

curl -s -X POST "$URL/rest/v1/rpc/push_config_get" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" -d '{}' > /tmp/journey_push_cfg.json

python3 - <<'PY'
import json, sys

try:
    c = json.load(open('/tmp/journey_push_cfg.json'))
except Exception as e:
    print(f'FAIL: push_config_get returned no JSON ({e})')
    sys.exit(1)

fails = []
def blank(v):
    return v is None or (isinstance(v, str) and not v.strip())

# 1. Neither platform may be handed the other's identity.
if not blank(c.get('web_api_key')) and c.get('web_api_key') == c.get('api_key'):
    fails.append('web_api_key is the ANDROID api_key — the coalesce fallback is back')
if not blank(c.get('web_app_id')) and c.get('web_app_id') == c.get('app_id'):
    fails.append('web_app_id is the ANDROID app_id — the coalesce fallback is back')

# 2. Readiness is the backend's answer, and it is a real boolean.
for k in ('web_ready', 'android_ready'):
    if k not in c:
        fails.append(f'{k} missing — the app would have to infer which platforms can receive')
    elif not isinstance(c[k], bool):
        fails.append(f'{k} is {type(c[k]).__name__}, not a boolean')

# 3. Readiness must agree with the keys it describes: ready means BOTH halves
#    are present, not-ready means the app must not try.
if c.get('web_ready') is True and (blank(c.get('web_api_key')) or blank(c.get('web_app_id'))):
    fails.append('web_ready is true with no web app registered')
if c.get('web_ready') is False and not (blank(c.get('web_api_key')) or blank(c.get('web_app_id'))):
    fails.append('web_ready is false while both web keys are present')
if c.get('android_ready') is True and (blank(c.get('api_key')) or blank(c.get('app_id'))):
    fails.append('android_ready is true with no android app registered')

# 4. An app id names its own platform. Firebase ids read 1:<n>:<platform>:<hash>.
for key, want in (('app_id', 'android'), ('web_app_id', 'web')):
    v = c.get(key)
    if not blank(v):
        parts = str(v).split(':')
        if len(parts) > 2 and parts[2] != want:
            fails.append(f'{key} is a {parts[2]} application id, not {want}')

if fails:
    print('FAIL: ' + '; '.join(fails))
    sys.exit(1)

print('PASS: web_ready=%s android_ready=%s; web keys %s; app_id platform=%s' % (
    c.get('web_ready'), c.get('android_ready'),
    'absent' if blank(c.get('web_api_key')) else 'their own',
    str(c.get('app_id', '::?')).split(':')[2] if str(c.get('app_id', '')).count(':') > 2 else '?'))
PY
RC=$?
rm -f /tmp/journey_push_cfg.json
exit $RC
