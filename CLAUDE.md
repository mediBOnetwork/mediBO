# RULES - NEVER BREAK THESE

## Deploy Rules
- NEVER deploy anything to Netlify. Netlify is permanently abandoned.
- NEVER use netlify deploy or any netlify CLI command.
- Deploy = `bash ~/deploy.sh` — ONE command, always. It builds Flutter, fingerprints the
  bundle, then does ONE `npx wrangler pages deploy build/web` (Direct Upload to Cloudflare
  Pages project "medibo", branch "main"). This bypasses the Cloudflare git-build queue
  that was causing 30+ min delays. Live in ~30s after upload.
- `git push` runs in the BACKGROUND after wrangler succeeds — it is history/rollback only
  and NEVER gates the deploy. Do NOT wait on it. Do NOT add a second deploy step.
- Token lives in ~/.medibo/cf.env (chmod 600, never committed). deploy.sh sources it.
- NEVER add a second `wrangler pages deploy` call. Exactly one per run.

## After every code change:
Run ~/deploy.sh — does `flutter clean` then build + wrangler Direct Upload → live in ~3min on medibo.in.
NEVER skip `flutter clean`: skipping it produces corrupt dart2js bundles that boot-hang even with identical source (proven 2026-07-03).

## HEADLESS SELF-VERIFICATION RULE (PERMANENT — overrides all prior habits)
- After every deploy, ~/deploy.sh runs `node ~/render_verify.js --keys boot_status` automatically.
- For feature-specific keys, run: `node ~/render_verify.js --keys key1,key2,...`
- render_verify.js loads medibo.in as admin (headless Chromium), reads #medibo-render-log from the DOM, and asserts build-hash match + all required keys.
- NEVER end a task with "render-log is stale / needs a real visit" — that is a FAILURE, not a pass. The script self-loads the page; stale render-log cannot happen.
- NEVER substitute a DB-count check or source-code check for actual render-log verification. DB check is ADDITIONAL only.
- If render_verify.js exits non-zero: fix the Flutter code and redeploy. Do not declare success.
There is no local preview step. Every change goes straight to production via deploy.sh.

## VERIFICATION RULE (mandatory)
Flutter web renders to canvas — automated browser tools (Puppeteer/CDP) CANNOT read Flutter UI. Never install Puppeteer or attempt browser-click verification for Flutter.

### Deploy verification (every deploy)
1. `curl https://medibo.in/version.json` → confirm commit matches just-built hash
2. For DB changes: Supabase MCP `execute_sql` confirming expected rows

### UI VERIFICATION (canvas app — replaces JS-grep PERMANENTLY)
NEVER grep the JS bundle to prove a widget rendered. String-in-bundle is NOT proof — it only proves the code compiled, not that the widget rendered.

After deploy, have the test user open the relevant screen. Then:

**Step 1 — confirm live build:**
```
curl https://medibo.in/version.json
```
Note the commit hash.

**Step 2 — read real render counts:**
```
curl https://medibo.in/render-log
```
Or via Supabase MCP:
```sql
SELECT build_hash, data FROM render_log WHERE id = 'singleton';
```

**Proof criteria:**
- `build` field matches the version.json commit → you're reading the live build
- The relevant count > 0 (e.g. `spn_buttons` > 0, `company_rows` matches expected supplier)
- If count = 0 or build hash doesn't match → the widget did NOT render — keep fixing

**After every UI feature deploy:** run the curl commands above. Do not report success until `build` matches and the relevant count confirms the widget rendered.

Visual verification = the USER checks the live site on their device using the matching test credential:
- admin change → test.admin@medibo.in / TestAdmin#26
- supplier change → test.sup1@medibo.in / TestSup1#26
- customer change → test.cust1@medibo.in / TestCust1#26

Report the commit hash and the matching test credential. Never install Puppeteer. Never attempt CDP/canvas clicking.

## Behaviour
- Wait for user instruction
- Do NOT auto-suggest next steps

## DESIGN SYSTEM (apply to all UI work)

Apply these rules automatically to every frontend/UI change in this Flutter web app — no reminder needed. Target visual language: 1mg / PharmEasy / Apollo Pharmacy — professional, clean, trusted Indian pharma.

### COLORS
- Primary brand green: `#1B7A43` — one dominant green, no rainbow palette
- Backgrounds: `#F5F6F8` page, `#FFFFFF` cards/surfaces
- Primary text: `#111827` — Secondary text / labels: `#6B7280`
- Borders / dividers: `#E5E7EB` (1 px, used sparingly)
- State colors — muted, not vivid:
  - Success / active: `#D1FAE5` bg · `#065F46` text
  - Pending / warning: `#FEF3C7` bg · `#92400E` text
  - Error / cancelled: `#FEE2E2` bg · `#991B1B` text
  - Info / neutral: `#EFF6FF` bg · `#1E40AF` text
- Never use purple gradients, neon accents, or decorative multi-color fills

### SPACING
- Scale: 4 · 8 · 12 · 16 · 24 · 32 px — no arbitrary values
- Generous whitespace inside cards and between sections; never cram content
- Group related items tightly (8–12 px gap); separate unrelated blocks (24–32 px)
- Card internal padding: 16–20 px; page horizontal padding: 16 px mobile, 24–32 px desktop

### TYPOGRAPHY
- Hierarchy (max 3 sizes per screen):
  - Screen / section titles: `FontWeight.w700`, ~20–22 px, `#111827`
  - Body / primary data: `FontWeight.w500`, ~15–16 px, `#111827`
  - Captions / labels / hints: `FontWeight.w400`, ~13 px, `#6B7280`
- Left-align all prose and labels; right-align all numbers, prices, quantities
- Never bold entire paragraphs; use weight contrast for emphasis only

### COMPONENTS
- **Cards**: `BorderRadius.circular(12–16)`, background `#FFFFFF`, border `1px #E5E7EB` only when needed, shadow `BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: Offset(0,2))`
- **Primary button**: filled `#1B7A43`, white label, radius 8–10 px, height 44–48 px
- **Secondary button**: outlined `#1B7A43` border + text, same size, no fill
- **Inputs / dropdowns**: light fill `#F5F6F8`, border `#E5E7EB`, focus border `#1B7A43`, radius 8 px, height 44–48 px, clear placeholder in `#9CA3AF`
- **Chips / badges**: small radius (20 px), muted state colors above, `FontWeight.w500` ~12 px
- **Dividers**: `#E5E7EB`, hairline (0.5–1 px); prefer whitespace over heavy lines

### TABLES & LISTS
- Columns on a strict grid — never ragged
- Consistent row height (48–56 px for data rows, 40 px for compact)
- Alternate rows with `#F9FAFB` zebra OR use 1 px `#E5E7EB` dividers — pick one, not both
- Numbers / prices: right-aligned, `₹` prefix, 2 decimal places max, `FontWeight.w600`
- Column headers: `#6B7280`, `FontWeight.w600`, ~13 px, uppercase or title-case — consistent

### RESPONSIVE
- Use `LayoutBuilder` / `MediaQuery` — proportional/flexible widths, never hard-coded pixel widths
- Test breakpoints: 360 px · 390 px · 414 px (mobile), 768 px (tablet), 1280 px+ (desktop)
- Text must never squish, truncate, or overflow while space remains — use `Flexible`/`Expanded`/`FittedBox` as needed
- Touch targets minimum 44×44 px on mobile

### RULES — ALWAYS
- No purple, no gradients on primary surfaces, no decorative icons as space-fillers
- No "AI slop" look: no oversized emoji in UI, no confetti illustrations, no generic card-with-icon grids
- Every screen must have clear visual hierarchy: one focal element, supporting data, then metadata
- Alignment is non-negotiable — every element must sit on the grid
- Prefer clarity and breathing room over information density

## VERIFICATION RULE (mandatory — never skip)
NEVER use CDP/Puppeteer/incognito automation — Flutter canvas is unreadable by browser tools.
NEVER report success from source code or JS bundle grep alone — string-in-bundle ≠ widget rendered.

After EVERY deploy, run the autonomous verifier FIRST:
```
bash scripts/verify_live.sh
```
- Exit 0 = VERIFIED (version.json matches + render-log shows boot_status=painted).
- Exit 1 = BROKEN (HTTP check failed — diagnose and redeploy before reporting anything).
- Exit 2 = DEPLOYED BUT UNCONFIRMED (deploy landed; no browser has visited yet). In this
  case report the commit hash + ask Om to open medibo.in — then re-run the script.

For UI feature verification also confirm the specific render count:
1. `curl https://medibo.in/render-log` — `build` must match commit AND relevant count > 0

If count = 0 → widget did NOT render → keep fixing.
This rule overrides everything else.

## LIVE VERIFICATION IS CLAUDE CODE'S JOB — NEVER OM'S
Claude Code MUST run `bash scripts/verify_live.sh` after every deploy and report the result.
NEVER say "please check the site", "please open medibo.in", or "let me know if it works".
The only time Om's eyes are needed is for subjective UI review (layout, colours) — not for
proving the app boots or a feature works. That proof comes from render-log.

## DEFENSIVE IMPORT RULE (prevents dart2js static-init crashes)
NEVER add `import 'dart:html'`, `import 'dart:js'`, or any `dart:*` web-only library to files
that are imported by the widget tree (e.g. view_as_state.dart, app_state.dart, user_state.dart,
any model or notifier). These libraries cause static-initialization ordering crashes in
dart2js -O4 release builds, white-screening the entire app.

Only `main.dart` (the entry point) may import `dart:html` — it is loaded last.
If a feature needs localStorage/sessionStorage, use the `shared_preferences` package instead.

## BOOT RESILIENCE RULE (permanent)
main.dart MUST always wrap startup in `runZonedGuarded`. Supabase.initialize and every other
init step MUST be individually try/caught. `_AppRoot` MUST remain a StatefulWidget with a
hard 5-second boot timeout that forces HomeShell if auth never resolves. FlutterError.onError
MUST be set at boot. Never revert these patterns — a feature crash MUST NOT white-screen the app.

## GEMINI RULE (ABSOLUTE)
Every AI/OCR feature uses ONLY gemini-3.5-flash on Vertex AI global endpoint (aiplatform.googleapis.com, locations/global, thinkingLevel='low', GCP_SA_KEY auth). NEVER gemini-2.5/2.0/1.5, NEVER generativelanguage.googleapis.com, NEVER API-key auth. Before writing any Gemini code, copy the exact pattern from the gemini-ocr edge function.

### GEMINI ENTITY IDENTITY RULE (never remove)
official_name = formal legal name of EXACTLY the entity on the card. NEVER substitute a parent, acquirer, group, or successor. Expanding the same entity's abbreviation is allowed (ALKEM→Alkem Laboratories Ltd.); replacing a distinct entity is forbidden (Aventis→Sanofi India Ltd. ✗, German Remedies→Zydus Lifesciences Ltd. ✗, Cipla Diagnostics→Cipla Ltd. ✗). When in doubt, keep visible_name verbatim as official_name with confidence=low.

## COMPANY NAMING RULE (ABSOLUTE)
Gemini never generates or normalizes company names — it extracts verbatim text only (`seen` field). The review modal pre-fills the editable name field with the verbatim seen text. Import stores whatever the admin leaves in the field (default = verbatim). No resolution, no fuzzy matching, no expansion in the import path.

## OCR NAMING RULE (ABSOLUTE, PERMANENT)
All OCR in mediBO returns VERBATIM text exactly as printed — never official names, never expansions, never corrections, never parent/group companies, never world knowledge. The review modal and stored records carry verbatim seen text only. Run scripts/test_ocr_verbatim.sh after every gemini-ocr change; deploy fails if it fails. NEVER remove this rule or the script.

## PROTECTED TEST SUITE (CHANGE #635 — never remove)
Before EVERY deploy, run `flutter test test/protected/` in addition to the
change's own focused test. A protected test may only be modified when the CHANGE
explicitly changes that protected behaviour — never to make an unrelated change
pass. New fragile flows get a new file here.

Current files and what they hold down:
- `recorder_policy_test.dart` — voice window lifecycle: Stop opens no new window,
  the sub-2s stop artifact is never submitted, silence is not an error toast.
- `barcode_count_test.dart` — scan/stage/commit: backend strings verbatim, tap
  zones, qty 0 keeps the item and writes nothing, Pack never crosses into the
  supplier ledger.
- `supplier_shop_state_test.dart` — fw_get_state: qty_label/status_label/
  status_tone rendered verbatim, count_locked (not a client-side OR) blocks entry.
- `pack_screen_test.dart` — pack_get_queue chips + can_mark_ready verbatim,
  pack_button (from pack_list_orders) verbatim, hold-to-undo's RPC contract.
- `product_detail_test.dart` — the product page is ONE RPC printed verbatim:
  headings come from the storefront_ui_label table (not Dart literals), absence
  is explicit (has_mrp/has_gst/has_supplier_label/my_history.has), ok:false
  renders the backend's not-found page instead of throwing.
- `company_notify_test.dart` — company page renders label/count_label verbatim
  and pages by offset while the BACKEND says has_more (appending never
  duplicates); company_not_found is an empty state; an out-of-stock card offers
  Notify, whose toast and subscribed state come only from the RPC; the
  back-in-stock strip reports exactly the ids it showed; and the PDP price is
  pricing.price_display — the same block every card reads.
- `home_sections_test.dart` — the home feed is one RPC rendered in payload
  order: unknown layouts and empty sections are skipped silently (forward
  compat), the green accent is located inside the title rather than guessed,
  and taps carry the backend's own key (category) / label (company search).
- `compact_card_test.dart` — the compact card computes nothing: price, struck
  MRP, ribbon and ADD label are backend strings, a ribbon appears only when the
  payload sent one, out-of-stock is can_add:false (never a stock number), and
  the grid extent stays derived from the card's own constants.

- `stock_update_form_test.dart` — the public /stock-update/<token> page renders
  items in payload order (fixture is deliberately non-alphabetical), draws the
  two buttons from buttons[] with still_oos LEFT / back_in_stock RIGHT and
  their own tones, keeps one answer per item, and submits
  [{product_id, back_in_stock}] for ANSWERED items only — an untouched item is
  omitted, never defaulted to "still out of stock". Expired renders the
  backend's copy instead of throwing.
- `inquiry_prestate_test.dart` — the auto-tick, on the ONE widget all three
  inquiry surfaces share: prestate 'Available' arrives pre-selected AND stays
  editable, prestate null arrives unselected, a submitted answer outranks the
  tick and a live tap outranks both, and items render in payload order (no
  client sort).
- `cart_unavailable_test.dart` — the cart's red state is the backend's flag:
  per-line unavailable/qty_locked are carried through untouched,
  unavailable_badge prints verbatim (never pluralised in Dart), the badge is
  absent at count 0, re-rendering after a removal clears both because the
  SERVER recomputed them, and CartOrderRefusal treats only
  error:'unavailable_in_cart' as that refusal, keeping its message verbatim.

The suite runs on the Dart VM in ~2s. Keep it that way: no network, no goldens,
no Supabase, no camera — mock RPC payloads inline. If a widget resists mocking,
extract its decisions into a pure class and test that.
(Set `RenderLog.flushEnabled = false` in setUpAll for any test that renders a
widget calling RenderLog.write — its 800 ms debounce is a real Timer and would
otherwise outlive the test and try to reach Supabase.)

---

# ═══════════════════════════════════════════════
# DEV QUEUE RUNNER — PERMANENT RULES (NON-NEGOTIABLE)
# Claude: these rules override everything except safety.
# Re-read this block before EVERY command you claim.
# ═══════════════════════════════════════════════

## PRIME DIRECTIVE
You are an autonomous runner. Your job: claim → build → deploy → verify → record → next.
You NEVER stop, NEVER wait for a human, NEVER leave a row half-updated.

## 1. NEVER ASK QUESTIONS
- If a choice arises: pick the recommended/safest option, KEEP BUILDING.
- Log every choice via the decisions helper: {question, options, picked, reason}.
- ONLY exception — truly destructive/irreversible actions:
  dropping tables/columns with data, deleting user data, auth/RLS weakening,
  payment config changes. For these: call dev_cmd_ask(id, question),
  then IMMEDIATELY claim the next command. Never idle.

## 2. STATUS DISCIPLINE (every row, every time)
- Claim ONLY via dev_cmd_claim (SKIP LOCKED). Never SELECT+UPDATE manually.
- Heartbeat via dev_cmd_heartbeat every 60s with log tail + tokens. A silent
  runner is treated as crashed at 15 min — do not go silent.
- ETA (CHANGE #68): estimate total build seconds right after reading the spec;
  send eta_total_s + eta_left_s on the FIRST heartbeat and honest re-estimates of
  eta_left_s on every beat (it shrinks). On any problem, set eta_note to a plain
  one-liner and grow eta_left_s/eta_total_s; clear the note when resolved. Never
  fake a countdown from elapsed time.
- Finish EVERY command with exactly one of: dev_cmd_complete / dev_cmd_fail /
  dev_cmd_ask. A row left in 'building' is a bug you caused.

## 3. DEPLOY LANE — EXACT SEQUENCE, NO SHORTCUTS
deploy_lock_try → if busy wait 60s retry (NEVER merge to main while another
agent holds the lock) → git fetch + rebase onto origin/main → flutter test
test/protected/ (MUST pass) → build → deploy_claim_number → stamp version.json
with THAT number (never reuse, never go backwards) → deploy → verify live
(site 200 + version.json shows new number + one smoke RPC) → rg_check() MUST
be green → deploy_lock_release. Skipping ANY step = failed command.

## 4. BUILD RULES
- Max-backend: logic, strings, labels, formatting live in Supabase.
  Flutter renders payloads verbatim. If you write a display string in Dart,
  you are wrong — move it to the backend.
- Backend AND frontend both belong to you. Never output "paste this SQL" —
  run it. Never output "add this to Flutter" — write it.
- All money in INR. All timestamps IST for display.
- Never touch test/protected/ tests to make them pass. Fix the code.
- Never edit another agent's in-flight branch. Your branch, your command only.

## 5. RECORDING (the registry is the memory)
- result_summary FORMAT — Om's rule, mandatory every time:
  - Bullet points only. Each bullet = **Title** — short description.
  - Title and description clearly separate.
  - MAX 10 lines. Each line MAX 5 words. Whole result MAX 50 words.
  - No paragraphs, no walls of text. Keep the deploy #, tests pass/fail,
    and decisions count as their own short bullets.
  - Example:
    • Change no — CHANGE #707 live.
    • Built — result banner + pill.
    • Backend — title auto-derived server-side.
    • Tests — protected 283 green.
    • Decisions — 2 logged.
- Capture 2–3 screenshots of changed screens → dev-cmd-proofs bucket.
- Before building: read the spec fully + check dev_commands for related
  completed rows so you never undo a previous command's work.

## 6. FAILURE RULES
- Any error: attempt reasonable fix ONCE within the command. If still broken:
  dev_cmd_fail with the full error. Auto-retry is handled by the system —
  do not loop yourself.
- NEVER mark complete with red tests, failed rg_check, or unverified deploy.
- NEVER fabricate results, deploy numbers, or screenshots.

## 7. FORBIDDEN — INSTANT VIOLATIONS
✗ Asking the human anything except via dev_cmd_ask
✗ Idling/waiting when pending commands exist
✗ Merging to main while deploy lock is held by another agent
✗ Reusing or guessing a change number
✗ Hardcoding display strings in Flutter
✗ Leaving a row in 'building' at exit
✗ Skipping heartbeat, tests, rg_check, or live verification

## 8. SOLVE, DON'T FLAG
- You NEVER report a problem and stop. Finding an issue = you fix it
  in the same command, then record what you fixed in result_summary.
- "Flagged for review", "needs manual attention", "please check",
  "recommend Om looks at" — these phrases are FORBIDDEN outputs.
- Blockers you hit (missing column, broken RPC, failing build, stale
  data, config gap) are part of the job: repair them, log the repair,
  continue. The human gives zero manual input.
- The ONLY thing you may hand back is a dev_cmd_ask for the destructive
  list in Rule 1. Everything else you solve yourself.

## 9. KNOW THE BUSINESS BEFORE YOU BUILD
- Before starting EVERY command: read the business context doc —
  legal_get_page('about') — plus the spec, fully.
- mediBO decisions must match its real business model as written there
  (who it serves, how pricing/billing actually works, roles, flows).
  If your general assumption conflicts with the context doc, the
  context doc WINS. Wrong-model builds are failed commands.
- If the context doc is missing or thin, improve it from the codebase
  truth as part of your command — do not build on guesses.

## 10. GCP COMMANDS (kind='gcp')
- A claimed `kind='gcp'` row does NOT use the web deploy lane: no flutter build,
  no version.json, complete with `p_deploy_no NULL`.
- On runner start, `gcp_bootstrap.sh` activates gcloud from the Vault secret
  `GCP_SA_KEY`. If absent → capability OFF: any gcp command completes with a
  plain "Google setup pending" summary + copy-chip result_actions (the Cloud
  Shell one-liner, the secret name `GCP_SA_KEY`) and `dev_cmd_ask` so it resumes
  after Om saves the key and replies done. NEVER put key material in logs,
  results, or build_log; key files are chmod 600.
- Loop: goal → plan gcloud steps → PREFLIGHT with read-only calls (verify
  roles/APIs); missing → one-line plain_summary + result_actions [copy: exact
  grant/enable command] + `dev_cmd_ask`. Then run→read→fix→rerun until met.
  Destructive steps use the is_danger ask path (backend PIN-gates the "yes").
- PLAIN-LANGUAGE MANDATE: every gcp completion writes `p_plain_summary` (2-4
  short non-technical sentences: what was done, what it means, what's left) and
  puts any copyable follow-up (commands, names, links) in `p_result_actions`.
  Technical output stays in build_log only.
- Status: `gcp_status.sh` writes VM state/disk/IP/APIs/region via
  `dev_gcp_status_write` on boot + every 10 min (systemd timer). Billing is
  best-effort — no billing role → `billing:{available:false}`, no error spam.
- Backups: `gcp_backup.sh` (01:30 IST timer) pg_dumps the DB + git-bundles the
  repo to the private `db-backups` bucket, `backup_report()` each. Needs
  `SUPABASE_DB_URL` in the Vault; absent → one plain setup card, then auto-runs.
- Secrets hygiene: never dump env; key files 600; results/build_log never
  contain secret values. Preflight before every mutate. Freeze (`sec_freeze`)
  stops all claims/adds; unlock with PIN.

## 11. FRONTEND IS THE FINISH LINE (100% BACKEND + MANDATORY FRONTEND WIRING)

The app is 100% backend-driven: every piece of logic, computation,
string, label, format, decision, and state lives in the BACKEND.
The frontend has exactly TWO permissions: REQUEST the backend and
RENDER what it returns. Nothing else. A display string written in
Dart, a calculation done in Flutter, a hardcoded label — all wrong;
move it to the backend.

But backend alone is HALF a feature. A feature Om cannot see and
tap in the deployed app DOES NOT EXIST. Multiple times backend was
built and the frontend was forgotten or left unwired — that is a
FAILED command, even if every RPC works.

MANDATORY for every build / change / update:
1. GAP CHECK FIRST: before wiring anything, check whether the
   backend for it exists. Any logic currently missing, or any
   logic sitting in the frontend, is a gap — BUILD THE BACKEND
   FIRST (tables, RPCs, strings, rules), then wire.
2. FRONTEND WIRING IS COMPULSORY: every backend feature you build
   or change MUST ship in the SAME command with its frontend:
   a visible, reachable entry point (menu item, button, chip,
   card, or screen), wired to the new RPCs, rendering their
   payloads verbatim.
3. REACHABILITY PROOF: after deploy, verify on the LIVE site that
   a super-admin (or the right role) can actually navigate to and
   use the change. Screenshot it. State the exact click path in
   the result. "Deployed but not visible/reachable" = incomplete
   = do NOT mark complete; fix the wiring first.
4. NO ORPHANS EITHER WAY: no backend without frontend access; no
   frontend without backend logic. Both, always, in one command.

Definition of done = backend built + frontend wired + deployed +
reachable + click path reported + screenshot proof.

## 12. DESIGN CONTRACT (permanent — CHANGE #66)

The app is styled 100% from backend design tokens. `ui_boot().design` →
`Ds.*` (lib/design_tokens.dart) → `buildTheme()`. Change a token via
`ui_design_set(patch)` and the WHOLE app recolours on next boot with ZERO code
change — no deploy. `ui_design_get()` reads current tokens.

Every screen build or change MUST follow **DESIGN.md** (repo root) and use the
tokens. Hardcoded style literals in a screen are a FAILED command:
- NO `Color(0x…)` — use `Ds.c.*` (brand, bg, surface, text, textSecondary,
  divider, success/warning/danger/info + `*Soft` tints).
- NO `fontSize:` / raw `TextStyle` sizes — use `Ds.t.*` (display/title/subtitle/
  body/caption) or the theme text slots.
- NO bare numeric `EdgeInsets`/`SizedBox`/`BorderRadius`/`BoxShadow` — use
  `Ds.space.*`, `Ds.r.r*`, `Ds.elevation.e1/e2`.
- One `Ds.c.brand` primary action per screen; red only destructive; ≤3 hues.

Only `lib/design_tokens.dart` and `lib/theme.dart` may hold style literals
(they DEFINE the tokens). The literal gate `test/protected/design_literal_gate_test.dart`
runs before every deploy: a NEW literal in a screen, or an increase over a
file's frozen baseline, FAILS the build. Baselines ratchet DOWN only — every
polish batch lowers `test/protected/design_literal_baseline.json`, never raises
it. To legitimately reduce a baseline after migrating a file: run
`dart run tool/design_baseline.dart --write` and commit the new baseline.

### DESIGN QA GATE (runner — after ANY command that touches UI)
Before `dev_cmd_complete` on a UI command, self-review the changed screens
against this checklist; if any check fails, FIX and re-check before completing.
Write "Design QA: passed (N checks)" into result_summary.
1. Spacing rhythm — only 4/8/12/16/24/32/48; unrelated blocks ≥24 apart.
2. Colour discipline — one brand primary; red only destructive; ≤3 hues.
3. Hierarchy — ≤3 type sizes; a real title; captions in textSecondary.
4. Components — cards radius16+e1; primary button full-width ≥44; sheets>dialogs.
5. Touch — every tap target ≥44×44.
6. States — empty state has one-line guidance; loading is a skeleton not a bare
   spinner; errors show backend copy + Retry.
7. Tokens — zero new style literals (gate green); everything via Ds/theme.

## 13. PARALLEL WORKERS (permanent — CHANGE #74)

The VM runs a WORKER POOL, not a single builder. The supervisor
(`mediBO-runner/supervisor.sh`) is the orchestrator: every 20s it reads
`desired_state` + `worker_pool` config (`pool_get`/`pool_set`) + queue depth,
scales tmux worker sessions `claude-1..claude-N` (agents `runner-1..N`; slot 1
is the visible primary Om attaches to), and publishes a render-ready snapshot
via `pool_status_write` that the app draws verbatim (`dev_ctl_get().pool`).

Rules every worker follows, in order:
1. **Plan → lease → build.** Before editing anything, list the EXACT repo files
   you will create/edit and call `lease_try_all(command_id, worker_id, paths)`.
   All-or-nothing, race-safe. NEVER edit an unleased file.
2. **Conflict → next command, don't block.** `ok:false` → heartbeat a one-line
   note (`waiting: <file> leased by #x`), lease nothing, and immediately claim
   the NEXT pending command instead. Re-attempt the blocked one only when
   re-claimed. Mid-build new file → single-path `lease_try_all` first; conflict
   you can't route around → finish what you can, note it, `dev_cmd_fail`.
3. **Leases free themselves.** `complete`/`fail`/`ask`/`cancel`/watchdog and the
   `lease_sweep` cron all auto-release. Call nothing extra.
4. **Build semaphore.** At most `build_semaphore` (default 2) concurrent
   `flutter build` (flock `mediBO-runner/.build.sem`); coding is unlimited.
5. **Deploy lane stays serialized** (deploy lock). Batching: when the lane frees
   and ≥2 workers hold ready branches, merge in one lane pass → one CHANGE #;
   each completed row names the shared number.
6. **Backend-only command → skip the build.** Touched zero frontend files →
   no `flutter build`, deploy nothing, `complete` with `p_deploy_no NULL` and
   say so in `plain_summary`.
7. **One worker per command.** Never edit another worker's in-flight branch.

Guards (supervisor enforces): `billing_mode=max_subscription` AND Claude usage
≥ `quota_shrink_pct` → pool shrinks to 1 (`shrink_reason=quota`); loadavg >
`cpu_load_max` → shrink by one (`cpu`); `workflow=off` or frozen → 0 claims
(sessions may stay alive idle). Idle ≥ `idle_shutdown_min` with an empty queue →
VM powers off. The primary session is never killed while it is building.

## 14. PROOF-BASED COMPLETION (permanent — CHANGE #129, Bug-Loop Prevention)

Completion is EVIDENCE, never a claim. A command is done when it is proven done,
not when the runner says so. The backend enforces this gate inside
`dev_cmd_complete` when `worker_pool.bugloop.enforce=true`.

Non-negotiable for every UI-touching command:
1. **Journeys.** After deploy (to preview when the preview lane is live), run the
   command's area journeys (+ global) → `journey_report(cmd, results[])`. Every
   `required=true` journey for the area MUST pass. A journey only becomes
   `required=true` after it has passed GREEN TWICE — never on first sight, never
   by hand to make a red command go green.
2. **QA (L2).** A separate hostile QA agent tests the preview and files
   `qa_report(cmd, 'passed'|'failed', findings[])`. The gate needs `passed` or an
   explicit PIN-gated `qa_waive`. Failed → back to the builder (max 2 rounds),
   then `needs_input` with the findings summary. Skip QA only for
   docs-only / gcp / mutation commands (`qa_required=false`).
3. **Screenshot.** ≥1 screenshot of the changed screen in `dev-cmd-proofs`, plus
   the exact click path in `result_summary`. Backend without a reachable,
   proven frontend is a FAILED command (§11).
4. **Bugs become journeys.** Every `bug_report` finding creates a permanent
   linked journey; the fix cannot complete until that journey passes. This is
   how a class of bug is retired forever instead of one screenshot at a time.

The chip row on each command (`qa_chip`, `preview_chip`, `journey_chip`) and the
detail screen's QA & Journeys section render this proof verbatim from
`dev_cmd_list` / `dev_cmd_qa_detail`. "Report a bug" (Dev Queue header) and the
Journey Library screen (header map icon) are the Om-facing surfaces.

NEVER flip `bugloop.enforce=true` until the full chain (preview → journeys → QA →
promote) is rehearsed end-to-end on a harmless command — flipping it early blocks
every future completion.

<!-- BEGIN agent_memory -->
<!-- AUTO-GENERATED pointer for claude. Do not edit inside these markers. -->
# Portable agent memory (claude)
@import RULES.md
# ^ The full, current rules live in RULES.md (regenerated from Supabase each
#   session by memory_render.sh). If RULES.md is missing, run that script.
<!-- END agent_memory -->
