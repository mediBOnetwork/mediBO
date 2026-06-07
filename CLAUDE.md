# RULES - NEVER BREAK THESE

## Deploy Rules
- NEVER deploy anything to Netlify. Netlify is permanently abandoned. The ONLY deploy target is Cloudflare Pages via git push origin main.
- NEVER use wrangler pages deploy
- NEVER use netlify deploy or any netlify CLI command
- Cloudflare Pages auto-deploys medibo.in from the GitHub repo (build/web is committed)

## After every code change:
Run ~/deploy.sh — this builds, commits, and pushes to production (Cloudflare Pages → medibo.in).
There is no local preview step. Every change goes straight to production via deploy.sh.

## VERIFICATION RULE (NEVER BREAK)
After every deploy, open medibo.in in INCOGNITO and log in with the matching test cred (admin=test.admin@medibo.in/TestAdmin#26, supplier=test.sup1@medibo.in/TestSup1#26, customer=test.cust1@medibo.in/TestCust1#26). CHECK the change actually rendered and works. If not, KEEP FIXING until it does. Never report success from bundle/source alone. Keep output minimal — check only the specific element, no full DOM/semantic tree dumps.
- After every deploy, poll https://medibo.in/version.json and confirm `"commit"` equals the SHORT hash from `git rev-parse --short HEAD`.
- NEVER use `grep -c` on a common word (e.g. "Dashboard", "mediBO", "Pharmacy") as proof of deploy — it false-positives on page headings and cached stale HTML.
- Feature proof = paste the corrected source code, not a word count.
- Deploy proof = `{"commit":"<HASH>"}` live on medibo.in/version.json matching the just-built hash.

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

## VERIFICATION RULE (updated)
After every deploy, open medibo.in in INCOGNITO and log in with the matching test credential:
- admin change → test.admin@medibo.in / TestAdmin#26
- supplier change → test.sup1@medibo.in / TestSup1#26
- customer change → test.cust1@medibo.in / TestCust1#26
CHECK the change actually rendered and works. If not, KEEP FIXING until it does. Never report success from bundle/source alone. Keep output minimal — check only the specific element, no full DOM/semantic tree dumps.
