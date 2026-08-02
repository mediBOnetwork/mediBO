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
- `compact_card_test.dart` — the compact card computes nothing: price, struck
  MRP, ribbon and ADD label are backend strings, a ribbon appears only when the
  payload sent one, out-of-stock is can_add:false (never a stock number), and
  the grid extent stays derived from the card's own constants.

The suite runs on the Dart VM in ~2s. Keep it that way: no network, no goldens,
no Supabase, no camera — mock RPC payloads inline. If a widget resists mocking,
extract its decisions into a pure class and test that.
