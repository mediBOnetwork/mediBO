# RULES - NEVER BREAK THESE

## Deploy Rules
- NEVER deploy anything to Netlify. Netlify is permanently abandoned. The ONLY deploy target is Cloudflare Pages via git push origin main.
- NEVER use wrangler pages deploy
- NEVER use netlify deploy or any netlify CLI command
- Cloudflare Pages auto-deploys medibo.in from the GitHub repo (build/web is committed)

## After every code change:
Run ~/deploy.sh — this builds, commits, and pushes to production (Cloudflare Pages → medibo.in).
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

After EVERY UI deploy, verify with render-log:
1. `curl https://medibo.in/version.json` — confirm commit hash
2. Have test user open the relevant screen (logged in with matching credential)
3. `curl https://medibo.in/render-log` — confirm `build=<hash>` matches AND relevant count > 0
   OR: Supabase MCP `SELECT build_hash, data FROM render_log WHERE id='singleton'`

If count = 0 → widget did NOT render → keep fixing.
This rule overrides everything else.

## GEMINI RULE (ABSOLUTE)
Every AI/OCR feature uses ONLY gemini-3.5-flash on Vertex AI global endpoint (aiplatform.googleapis.com, locations/global, thinkingLevel='low', GCP_SA_KEY auth). NEVER gemini-2.5/2.0/1.5, NEVER generativelanguage.googleapis.com, NEVER API-key auth. Before writing any Gemini code, copy the exact pattern from the gemini-ocr edge function.

### GEMINI ENTITY IDENTITY RULE (never remove)
official_name = formal legal name of EXACTLY the entity on the card. NEVER substitute a parent, acquirer, group, or successor. Expanding the same entity's abbreviation is allowed (ALKEM→Alkem Laboratories Ltd.); replacing a distinct entity is forbidden (Aventis→Sanofi India Ltd. ✗, German Remedies→Zydus Lifesciences Ltd. ✗, Cipla Diagnostics→Cipla Ltd. ✗). When in doubt, keep visible_name verbatim as official_name with confidence=low.

## COMPANY NAMING RULE (ABSOLUTE)
Gemini never generates or normalizes company names anywhere in mediBO — it extracts verbatim text only (field name: `seen`). Canonical names come exclusively from the `company` table via brand-token matching (`_fzBestMatch`). New names that don't match the corpus are inserted verbatim into the `company` table (ON CONFLICT DO NOTHING via upsert) and flagged with a NEW badge in the review UI for admin confirmation. There is no `official_name` field anywhere in the OCR pipeline — only `seen` + `confidence` from Gemini, then `matched` resolved in Flutter.
