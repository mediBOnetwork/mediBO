# CHANGE #1017 — staff visual system, three-role proof

The IA (#1016) put six verbs on the staff bar. This pass is what those six
screens LOOK like: the answer first, one list row, zone and date chosen once in
the header, badges only for waiting work, motion for state, a rail on tablets,
an offline banner, and a super-admin preview of what each role sees.

## Before (live build 99a457e4 · CHANGE #1100)
- `dev-cmd-proofs/1017/before_admin_dashboard.png` — the dashboard drew its OWN
  zone + date pickers inside its sticky header (128 px); no other tab had them.
- `dev-cmd-proofs/1017/before_admin_more.png` — More: search + tiles; no
  Appearance, no View-as.

## Parity checklist rerun (the #1016 capability list, on the #1017 backend)
- super_admin: 125 old features, 125 PASS, 0 FAIL — dashboard · customers · suppliers · fulfill · money · more
- admin: 93 old features, 93 PASS, 0 FAIL
- partner: 30 old features, 30 PASS, 0 FAIL
(`bash scripts/c1016_capability.sh`, rc=0, rewrote docs/STAFF_IA_CAPABILITY.md)

## After
_(filled by `bash scripts/c1017_visual_proof.sh <out>` once CHANGE #1017 is live)_
