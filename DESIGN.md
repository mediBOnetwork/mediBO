# mediBO DESIGN — the taste contract

mediBO is B2B pharma trade software used all day by pharmacists, suppliers,
warehouse and delivery staff. It must feel **calm, confident and Apple-grade**:
airy, quiet, trustworthy — not a dashboard, not a toy. Every screen is rendered
from ONE backend payload; this file governs how that payload is dressed.

**The whole app is styled from tokens.** `ui_boot().design` → `Ds.*` → the
theme. Never write a colour, size, radius, gap or shadow as a literal in a
screen. If you typed `Color(0x…)`, `fontSize:`, a bare `EdgeInsets` number, a
`BorderRadius` number or a `BoxShadow` in a screen, you are wrong — reach for
`Ds` instead. The literal gate (`test/protected/design_literal_gate_test.dart`)
enforces this and ratchets down over time.

Token source of truth: `ui_design_get()` / `ui_design_set(patch)` (super-admin,
audited). Accessors: `Ds.c.*` (colours), `Ds.space.x16` / `Ds.space(i)`,
`Ds.r.rCard` (radii), `Ds.t.title` (type), `Ds.elevation.e1`, `Ds.motion`,
`Ds.touch.minTarget`.

---

## 1. Feel — calm, airy, confident

- **Whitespace is a feature.** Do — let a screen breathe: 24–32 px between
  unrelated blocks, generous card padding (16–20 px). Don't — cram rows edge to
  edge to fit more; density is not a virtue here.
- **One focal element per screen.** Do — one clear primary action, everything
  else quiet. Don't — three competing green buttons shouting at once.
- **Confident, not decorative.** Do — trust type and spacing to create
  hierarchy. Don't — add icons as space-fillers, gradients on surfaces, or
  emoji as UI.

## 2. Colour discipline

- **One green.** `Ds.c.brand` is the ONLY primary/action colour and appears
  once per screen as the primary button. Do — keep secondary actions outlined
  or text. Don't — paint five things brand green.
- **Neutrals everywhere.** Do — `Ds.c.text` for headings/data, `Ds.c.textSecondary`
  for captions/labels, `Ds.c.surface` cards on `Ds.c.bg` page. Don't — reach
  for colour where grey reads fine.
- **State colours are muted and mean one thing.** `success` = done/available,
  `warning` = pending, `danger` = destructive/cancelled only, `info` = neutral
  notice. Use the `*Soft` tints for backgrounds, the solid for text/icon. Do —
  red ONLY for destructive or error. Don't — red as an accent.
- **≤ 3 hues per screen.** Do — brand + one state + neutrals. Don't — a rainbow
  of category colours competing with the action colour.

## 3. Hierarchy & type

- Max **3 type sizes per screen**. Do — `Ds.t.title` for the screen/section
  title, `Ds.t.body` for data, `Ds.t.caption` (secondary colour) for metadata.
  Don't — five weights and sizes in one card.
- **Big titles, real gaps.** Do — a confident `Ds.t.display`/`title`, then 24 px
  before the content. Don't — a 15 px "title" indistinguishable from the body.
- Left-align prose and labels; **right-align all numbers, prices, quantities**
  with `₹` prefix and ≤ 2 decimals. Money and timestamps are backend display
  strings — never format in Dart.
- Never bold whole paragraphs; weight is for emphasis, not decoration.

## 4. Components

- **Cards:** `Ds.c.surface`, `Ds.r.rCard` (16), border `Ds.c.divider` only when
  needed, shadow `Ds.elevation.e1`. Do — one elevation level for resting cards.
  Don't — heavy drop shadows or stacked borders + shadow + zebra all at once.
- **Primary button:** filled `Ds.c.brand`, white label, `Ds.r.button` (12),
  height ≥ `Ds.touch.minTarget` (44), **full-width** on mobile forms. Do — one
  per screen. Don't — tiny 32 px buttons.
- **Secondary button:** outlined brand, same height, no fill.
- **Inputs:** light fill `Ds.c.bg`, focus does not flash a coloured ring, clear
  placeholder in `Ds.c.textSecondary`, height ≥ 44.
- **Chips / badges:** `Ds.r.rChip`, muted state tint bg + solid state text,
  small and quiet.
- **Sheets over dialogs.** Do — a bottom sheet (`Ds.r.rSheet`) for choices and
  confirmations. Don't — a boxy Material AlertDialog where a sheet fits.
- **Skeletons over spinners.** Do — a grey skeleton of the coming layout while
  the RPC loads. Don't — a lone centered spinner on a blank screen.
- **Dividers:** hairline `Ds.c.divider`; prefer whitespace over lines.

## 5. Rhythm & layout

- Spacing comes ONLY from the scale: 4 · 8 · 12 · 16 · 24 · 32 · 48
  (`Ds.space.x4 … x48`). No arbitrary 7, 13, 19 px.
- Group related items tightly (8–12), separate unrelated blocks (24–32).
- Columns on a strict grid — never ragged. Consistent row height
  (`Ds.touch.listRowMinHeight` 56 for data rows).
- ≤ **2 information densities per row** — a title + one supporting value, not
  five stats squeezed onto one line.
- Touch targets ≥ 44 × 44 on mobile. Test 360 / 390 / 414 / 768 / 1280 px;
  text must never squish, truncate or overflow while space remains.

## 6. States

- **Empty states** carry one line of guidance (from the backend copy), not a
  blank void. Do — "No orders yet — placed orders appear here." Don't — an
  empty scroll area.
- **Loading** is a skeleton of the real layout. **Errors** show the backend's
  own message + a Retry, never a raw exception.

## 7. Iconography & motion

- Icons: rounded family, consistent 1.5 px optical weight, sized to the text
  they sit beside. No oversized decorative icons, no confetti, no illustration
  clip-art.
- Motion: `Ds.motion.standard` (200 ms, easeOut) for state changes,
  `Ds.motion.sheet` (300 ms) for sheets. Subtle — nothing bounces.

---

### The literal ban (how it's enforced)

Screens must contain **no** `Color(0x…)`, `fontSize:`, numeric `EdgeInsets`,
numeric `BorderRadius`, or `BoxShadow`. These belong to `Ds`/`theme` only
(allowlisted files: `lib/design_tokens.dart`, `lib/theme.dart`). A new literal
in any screen, or an increase over a file's frozen baseline, fails
`test/protected/design_literal_gate_test.dart` — which runs before every deploy.
The baseline only ratchets **down**: every polish batch lowers it, never raises
it.
