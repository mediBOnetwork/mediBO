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

## DESIGN SYSTEM (apply to all UI work) — rewritten by CHANGE #673

**Read this first.** The version of this section that stood until #673 listed hex
codes inline and mandated "one dominant green, no rainbow palette", "state colors
— muted, not vivid", "no gradients on primary surfaces" and "prefer clarity and
breathing room over information density". Followed literally — which is what
happened — it produced a storefront Om described as "a 90's website". Everything
sat in one tonal band, every surface was white-on-grey with a hairline, and the
only accent in the app was a single green. The rules were not wrong about
discipline; they were wrong about *flatness*, and they were wrong to keep colour
values in a markdown file at all.

The replacement has two halves: where values live, and what still holds.

### THE SOURCE OF TRUTH IS NOT THIS FILE

- Every colour, radius and text style is in `lib/theme.dart` — `Brand`, `Rad`,
  `AppType`, `CategoryStyle`. Never type a hex code, a font size or a radius
  literal in a widget. If you need a value that is not in `theme.dart`, add it
  there.
- Anything the STOREFRONT shows is further owned by Postgres, not by
  `theme.dart`: section band colours, per-section accents, the hero, and every
  user-facing word come from `storefront_theme()` / `storefront_home_v2()` /
  `storefront_ui_label`. Recolouring a section or rewording a button is an
  `UPDATE`. If a storefront colour change needs a deploy, that is the bug.
- Do not copy a palette back into this file. A hex code in markdown is a fourth
  copy of a value that already has an owner.

### WHAT ACTUALLY MAKES IT LOOK DESIGNED

These are the devices #673 added. Keep them; they are the difference.

- **Colour is allowed, and is the point.** Category tiles, section bands and
  accents are a real palette (`Brand.bands`, `CategoryStyle`), not tints of one
  green. `Brand.accent` (#FF5A1F) is the call-to-action colour; `Brand.green` is
  the brand. A screen with exactly one hue on it is a defect, not restraint.
- **Alternating full-bleed section bands.** A feed that is one continuous grey
  reads as a table. Bands are what make it read as blocks.
- **One element crossing one boundary.** The product card's ADD pill overlaps
  the image plate and hangs below it. This single overlap does more than any
  other change in #673. Do not "clean it up" back inside the box.
- **Dark chrome.** The header block is a `Brand.deep` → `Brand.deepAlt`
  gradient with a white search pill on it. Gradients on chrome are correct here;
  the old "no gradients" rule is withdrawn.
- **Typeset text.** `AppType` is DM Sans with negative letter-spacing scaled to
  size. Never fall back to stock Roboto at tracking 0 — that alone reads as
  unstyled.
- **Density is fine when it is aligned.** B2B users are scanning a catalogue.
  The old "breathing room over density" line is withdrawn: two columns of tight,
  gridded cards beat one column of airy ones.

### WHAT STILL HOLDS (unchanged, and non-negotiable)

- **Spacing scale: 4 · 8 · 12 · 16 · 24 · 32.** No arbitrary values.
- **Alignment.** Every element sits on the grid; columns are never ragged.
- **Touch targets ≥ 44×44 px on mobile.**
- **Text never truncates while space remains** — `Flexible`/`Expanded`, and
  `maxLines` + `ellipsis` on anything backend-sent. A widget that only fits
  today's copy will break on tomorrow's `UPDATE`; see the `_PriceLine` overflow
  #673 caught in test.
- **Numbers right-aligned in tables**, `₹` prefix, 2 decimals.
- **No "AI slop":** no oversized emoji, no confetti illustrations, no decorative
  icons as space-fillers. Colour must carry meaning (category, state, accent) —
  decoration for its own sake is still banned.
- **Fixed-extent grids stay fixed.** `CompactProductCard.extent` is summed from
  the card's own constants and must never become a function of viewport width,
  or the grid's reserved height and the card's real height diverge per device.
- Breakpoints to check: 360 · 390 · 414 (mobile), 768 (tablet), 1280+ (desktop).

### B2B, NOT B2C — never blur this

mediBO does not take prescriptions and does not sell at MRP. It sells at **PTR**.
So: no Rx badges, no "% off MRP" consumer framing. The card's ribbon is a
**MARGIN** ribbon and the caption above the price is
`pricing.price_caption` from the backend. Copying a B2C storefront's *layout* is
correct; copying its *pricing story* is not.

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
