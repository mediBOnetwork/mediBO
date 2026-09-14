// agreement-pdf — CMD #1986: the partner agreement, typeset as a contract.
//
// Om's complaint on 14 Sep was exact: the signed copy "renders as plain text on
// a blank page — it reads like a toy, not a contract". It did, because the
// agreement was riding renderDoc(), the generic table printer the settlement
// statement uses. A contract is not a table.
//
// This is a TYPESETTING ENGINE, not a text dump:
//   • A4 portrait, 20 mm margins, a serif face at 10.5 pt on 1.4 line spacing.
//   • Paragraphs are JUSTIFIED — the inter-word space is solved per line, not
//     left ragged — and clause bodies hang off the clause number.
//   • Widow/orphan control: a paragraph that cannot place two lines starts on
//     the next page, and a heading never sits alone at the foot of one.
//   • TWO PASSES. The first lays the whole document out and records which page
//     every heading landed on; the second reprints it with those numbers in the
//     table of contents. That is how a contents page gets real page numbers.
//   • Every page carries the letterhead, the agreement number, "Page x of y",
//     an initials rule for each Party, and the verification QR.
//
// It decides NOTHING about wording. agreement_contract_doc() composes every
// sentence, label, heading and status line; this file decides where ink goes.
//
// Deno edge functions cannot spawn a process, so Typst and wkhtmltopdf are not
// available here (CMD #1986 decision log). The layout below is the engine.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1'
import fontkit from 'https://esm.sh/@pdf-lib/fontkit@1.1.1'
import qrcode from 'https://esm.sh/qrcode-generator@1.4.4'

const NOTIFY_SECRET = 'medibo_order_notify_2027'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

// ── the face ────────────────────────────────────────────────────────────────
// A contract is set in a serif. Noto Serif is fetched once per cold start and
// embedded; if GitHub is unreachable the document still prints, in Times, and
// ₹ degrades to "Rs." rather than throwing inside pdf-lib's WinAnsi encoder.
const SERIF = 'https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSerif/'
const FONT_URLS = {
  reg: SERIF + 'NotoSerif-Regular.ttf',
  bold: SERIF + 'NotoSerif-Bold.ttf',
  ital: SERIF + 'NotoSerif-Italic.ttf',
}
let FONT_CACHE: { reg: Uint8Array; bold: Uint8Array; ital: Uint8Array } | null = null

async function serifFonts() {
  if (FONT_CACHE) return FONT_CACHE
  try {
    const ctl = new AbortController()
    const t = setTimeout(() => ctl.abort(), 9000)
    const [a, b, c] = await Promise.all([
      fetch(FONT_URLS.reg, { signal: ctl.signal }),
      fetch(FONT_URLS.bold, { signal: ctl.signal }),
      fetch(FONT_URLS.ital, { signal: ctl.signal }),
    ])
    clearTimeout(t)
    if (!a.ok || !b.ok || !c.ok) return null
    FONT_CACHE = {
      reg: new Uint8Array(await a.arrayBuffer()),
      bold: new Uint8Array(await b.arrayBuffer()),
      ital: new Uint8Array(await c.arrayBuffer()),
    }
    return FONT_CACHE
  } catch { return null }
}

let UNICODE = false
function safe(s: unknown): string {
  const raw = String(s ?? '')
  if (UNICODE) return raw.replace(/\r/g, '')
  return raw
    .replace(/₹/g, 'Rs.')
    .replace(/[‘’]/g, "'").replace(/[“”]/g, '"')
    .replace(/[–—]/g, '-').replace(/…/g, '...')
    .replace(/·/g, '-')
    .replace(/[^\x20-\x7E\n]/g, '')
}

// ── the ink ─────────────────────────────────────────────────────────────────
const INK = rgb(0.09, 0.11, 0.13)
const GREY = rgb(0.42, 0.45, 0.49)
const RULE = rgb(0.80, 0.82, 0.85)
const BRAND = rgb(0.106, 0.478, 0.263)      // #1B7A43, the one brand green
const SOFT = rgb(0.96, 0.965, 0.97)

type Ctx = {
  pdf: any; F: any; FB: any; FI: any
  page: any; y: number; pageNo: number
  W: number; H: number; M: number
  size: number; lead: number
  doc: any; qrMods: boolean[][] | null
  anchors: Record<string, number>
  pageMap: Record<string, number> | null
  contentBottom: number
}

// ── QR, drawn as modules (no image round-trip, no external service) ─────────
function qrModules(text: string): boolean[][] | null {
  try {
    const qr = qrcode(0, 'M')
    qr.addData(text)
    qr.make()
    const n = qr.getModuleCount()
    const out: boolean[][] = []
    for (let r = 0; r < n; r++) {
      const row: boolean[] = []
      for (let c = 0; c < n; c++) row.push(qr.isDark(r, c))
      out.push(row)
    }
    return out
  } catch { return null }
}

function drawQr(ctx: Ctx, x: number, y: number, size: number) {
  const m = ctx.qrMods
  if (!m || !m.length) return
  const n = m.length
  const s = size / n
  ctx.page.drawRectangle({ x: x - 2, y: y - 2, width: size + 4, height: size + 4,
                           color: rgb(1, 1, 1) })
  for (let r = 0; r < n; r++) {
    for (let c = 0; c < n; c++) {
      if (!m[r][c]) continue
      ctx.page.drawRectangle({
        x: x + c * s, y: y + (n - 1 - r) * s,
        width: s + 0.15, height: s + 0.15, color: INK })
    }
  }
}

// ── measuring and drawing ───────────────────────────────────────────────────
const w = (f: any, s: string, size: number) => f.widthOfTextAtSize(s, size)

function text(ctx: Ctx, s: string, x: number, y: number, size: number, f: any, c = INK) {
  ctx.page.drawText(safe(s), { x, y, size, font: f, color: c })
}
function rtext(ctx: Ctx, s: string, xr: number, y: number, size: number, f: any, c = INK) {
  const t = safe(s)
  ctx.page.drawText(t, { x: xr - w(f, t, size), y, size, font: f, color: c })
}
function ctext(ctx: Ctx, s: string, cx: number, y: number, size: number, f: any, c = INK) {
  const t = safe(s)
  ctx.page.drawText(t, { x: cx - w(f, t, size) / 2, y, size, font: f, color: c })
}
function rule(ctx: Ctx, x1: number, x2: number, y: number, c = RULE, th = 0.6) {
  ctx.page.drawLine({ start: { x: x1, y }, end: { x: x2, y }, thickness: th, color: c })
}

/// Break a paragraph into lines that fit `width`. Returns the word runs so the
/// caller can justify them; a word longer than the measure is hard-split rather
/// than allowed to run off the page.
function wrap(f: any, s: string, size: number, width: number): string[][] {
  const words = safe(s).split(/\s+/).filter(Boolean)
  const lines: string[][] = []
  let cur: string[] = []
  let curW = 0
  const spaceW = w(f, ' ', size)
  for (let word of words) {
    while (w(f, word, size) > width) {
      let cut = word.length - 1
      while (cut > 1 && w(f, word.slice(0, cut) + '-', size) > width) cut--
      if (cur.length) { lines.push(cur); cur = []; curW = 0 }
      lines.push([word.slice(0, cut) + '-'])
      word = word.slice(cut)
    }
    const add = w(f, word, size)
    if (cur.length && curW + spaceW + add > width) {
      lines.push(cur); cur = [word]; curW = add
    } else {
      curW += (cur.length ? spaceW : 0) + add
      cur.push(word)
    }
  }
  if (cur.length) lines.push(cur)
  return lines
}

/// One justified line. The last line of a paragraph is set flush left — that is
/// what justification means; stretching it is the tell of a fake one.
function drawLine(ctx: Ctx, words: string[], x: number, y: number, size: number,
                  f: any, width: number, justify: boolean, c = INK) {
  if (!words.length) return
  if (!justify || words.length === 1) {
    text(ctx, words.join(' '), x, y, size, f, c)
    return
  }
  const wordsW = words.reduce((a, t) => a + w(f, t, size), 0)
  const gap = (width - wordsW) / (words.length - 1)
  // A line that would need a cavernous space is set flush left instead.
  if (gap > w(f, ' ', size) * 3.2) { text(ctx, words.join(' '), x, y, size, f, c); return }
  let cx = x
  for (const t of words) {
    text(ctx, t, cx, y, size, f, c)
    cx += w(f, t, size) + gap
  }
}

// ── page furniture ──────────────────────────────────────────────────────────
function chrome(ctx: Ctx, cover: boolean) {
  const d = ctx.doc
  const lh = d.letterhead ?? {}, ft = d.footer ?? {}
  const M = ctx.M, W = ctx.W, H = ctx.H

  if (!cover) {
    text(ctx, lh.left ?? '', M, H - M + 14, 8, ctx.FB, GREY)
    rtext(ctx, lh.right ?? '', W - M, H - M + 14, 8, ctx.F, GREY)
    rule(ctx, M, W - M, H - M + 8, RULE, 0.5)
  }

  // The footer band: agreement number, page x of y, initials for both Parties,
  // and the verification QR — on EVERY page, which is what makes a loose page
  // traceable back to the agreement it came from.
  const fy = M - 16
  rule(ctx, M, W - M, fy + 30, RULE, 0.5)
  text(ctx, ft.left ?? '', M, fy + 19, 7, ctx.F, GREY)

  if (!cover) {
    // initials rules, left of the QR
    const ix = M
    const iy = fy + 6
    const seg = 62
    text(ctx, (ft.initials_operator ?? '') + ':', ix, iy, 6.5, ctx.F, GREY)
    const ox = ix + w(ctx.F, safe((ft.initials_operator ?? '') + ':'), 6.5) + 4
    rule(ctx, ox, ox + seg, iy - 1, GREY, 0.5)
    const px = ox + seg + 14
    text(ctx, (ft.initials_partner ?? '') + ':', px, iy, 6.5, ctx.F, GREY)
    const px2 = px + w(ctx.F, safe((ft.initials_partner ?? '') + ':'), 6.5) + 4
    rule(ctx, px2, px2 + seg, iy - 1, GREY, 0.5)
  }

  const total = ctx.pageMap?.__total ?? 0
  const pageLine = String(ft.page_fmt ?? '')
    .replace('{p}', String(ctx.pageNo))
    .replace('{n}', total ? String(total) : String(ctx.pageNo))
  ctext(ctx, pageLine, W / 2, fy + 19, 7, ctx.F, GREY)

  const v = ctx.doc.verify ?? {}
  drawQr(ctx, W - M - 30, fy + 2, 30)
  rtext(ctx, v.code ?? '', W - M - 34, fy + 19, 6.5, ctx.F, GREY)
}

function newPage(ctx: Ctx, cover = false) {
  ctx.page = ctx.pdf.addPage([ctx.W, ctx.H])
  ctx.pageNo += 1
  chrome(ctx, cover)
  ctx.y = ctx.H - ctx.M - (cover ? 0 : 12)
}

function need(ctx: Ctx, h: number) {
  if (ctx.y - h < ctx.contentBottom) newPage(ctx)
}

function anchor(ctx: Ctx, key: string) {
  if (ctx.anchors[key] === undefined) ctx.anchors[key] = ctx.pageNo
}

// ── blocks ──────────────────────────────────────────────────────────────────
function para(ctx: Ctx, s: string, x: number, width: number, opts: {
  size?: number; font?: any; colour?: any; justify?: boolean; gapAfter?: number
  firstIndent?: number
} = {}) {
  const size = opts.size ?? ctx.size
  const f = opts.font ?? ctx.F
  const lead = size * (ctx.doc.page?.line_gap ?? 1.4)
  const lines = wrap(f, s, size, width)
  // Widow/orphan: never leave a single line of a multi-line paragraph behind.
  if (lines.length > 1 && ctx.y - lead * 2 < ctx.contentBottom) newPage(ctx)
  for (let i = 0; i < lines.length; i++) {
    if (ctx.y - lead < ctx.contentBottom) {
      // An orphan check on the way out too: one line left over starts a page.
      newPage(ctx)
    }
    ctx.y -= lead
    drawLine(ctx, lines[i], x, ctx.y, size, f, width,
             (opts.justify ?? true) && i < lines.length - 1, opts.colour ?? INK)
  }
  ctx.y -= opts.gapAfter ?? size * 0.7
}

function sectionHeading(ctx: Ctx, s: string, key?: string) {
  // A heading needs its first two lines of body under it or it moves on.
  need(ctx, 64)
  if (key) anchor(ctx, key)
  ctx.y -= 20
  text(ctx, s, ctx.M, ctx.y, 12.5, ctx.FB, BRAND)
  ctx.y -= 6
  rule(ctx, ctx.M, ctx.M + 46, ctx.y, BRAND, 1.2)
  ctx.y -= 10
}

// ── the cover ───────────────────────────────────────────────────────────────
function cover(ctx: Ctx) {
  const d = ctx.doc, c = d.cover ?? {}
  const M = ctx.M, W = ctx.W, H = ctx.H
  newPage(ctx, true)

  // masthead
  ctx.y = H - M - 30
  text(ctx, c.mark ?? '', M, ctx.y, 24, ctx.FB, BRAND)
  if (c.tagline) {
    ctx.y -= 14
    text(ctx, c.tagline, M, ctx.y, 9, ctx.FI, GREY)
  }
  ctx.y -= 12
  rule(ctx, M, W - M, ctx.y, BRAND, 1.6)

  ctx.y -= 66
  text(ctx, c.kicker ?? '', M, ctx.y, 9.5, ctx.F, GREY)
  ctx.y -= 30
  for (const ln of wrap(ctx.FB, c.title ?? '', 22, W - 2 * M)) {
    text(ctx, ln.join(' '), M, ctx.y, 22, ctx.FB, INK)
    ctx.y -= 27
  }

  ctx.y -= 16
  text(ctx, c.between ?? '', M, ctx.y, 9.5, ctx.FI, GREY)
  ctx.y -= 18

  const parties = Array.isArray(c.parties) ? c.parties : []
  for (let i = 0; i < parties.length; i++) {
    const p = parties[i] ?? {}
    ctx.y -= 4
    text(ctx, String(p.role ?? '').toUpperCase(), M, ctx.y, 7.5, ctx.FB, BRAND)
    ctx.y -= 15
    for (const ln of wrap(ctx.FB, p.name ?? '', 13, W - 2 * M)) {
      text(ctx, ln.join(' '), M, ctx.y, 13, ctx.FB, INK); ctx.y -= 16
    }
    for (const l of (Array.isArray(p.lines) ? p.lines : [])) {
      if (!String(l ?? '').trim()) continue
      for (const ln of wrap(ctx.F, String(l), 9, W - 2 * M)) {
        text(ctx, ln.join(' '), M, ctx.y, 9, ctx.F, GREY); ctx.y -= 12
      }
    }
    if (i < parties.length - 1) {
      ctx.y -= 6
      text(ctx, c.and_label ?? '', M, ctx.y, 9.5, ctx.FI, GREY)
      ctx.y -= 16
    }
  }

  // the meta panel, sitting on the grid at the foot of the cover
  const panelH = 26 + 16 * (Array.isArray(c.meta) ? c.meta.length : 0)
  const py = M + 74
  ctx.page.drawRectangle({ x: M, y: py, width: W - 2 * M, height: panelH,
                           color: SOFT, borderColor: RULE, borderWidth: 0.6 })
  let my = py + panelH - 18
  for (const m of (Array.isArray(c.meta) ? c.meta : [])) {
    text(ctx, m?.label ?? '', M + 14, my, 8, ctx.F, GREY)
    rtext(ctx, m?.value ?? '', W - M - 14, my, 9, ctx.FB, INK)
    my -= 16
  }

  // the status line — the one place the cover says Draft or Signed
  const tone = String(c.status_tone ?? 'neutral')
  const col = tone === 'success' ? BRAND : tone === 'warning' ? rgb(0.57, 0.25, 0.05) : GREY
  ctx.y = py - 20
  text(ctx, c.status_line ?? '', M, ctx.y, 10, ctx.FB, col)
  ctx.y -= 14
  for (const ln of wrap(ctx.F, c.note ?? '', 7.5, W - 2 * M)) {
    text(ctx, ln.join(' '), M, ctx.y, 7.5, ctx.F, GREY); ctx.y -= 10
  }
}

// ── contents ────────────────────────────────────────────────────────────────
function contents(ctx: Ctx) {
  const t = ctx.doc.toc ?? {}
  const entries = Array.isArray(t.entries) ? t.entries : []
  newPage(ctx)
  sectionHeading(ctx, t.heading ?? '')
  rtext(ctx, t.col_page ?? '', ctx.W - ctx.M, ctx.y, 7.5, ctx.FB, GREY)
  ctx.y -= 12

  for (const e of entries) {
    need(ctx, 20)
    ctx.y -= 15
    const label = safe(e?.label ?? '')
    const pageNo = ctx.pageMap ? ctx.pageMap[String(e?.key ?? '')] : undefined
    const num = pageNo ? String(pageNo) : ''
    const isTop = String(e?.key ?? '').indexOf(':') < 0
    const f = isTop ? ctx.FB : ctx.F
    text(ctx, label, ctx.M + (isTop ? 0 : 12), ctx.y, 9.5, f, INK)
    rtext(ctx, num, ctx.W - ctx.M, ctx.y, 9.5, f, INK)
    // dot leader
    const lx = ctx.M + (isTop ? 0 : 12) + w(f, label, 9.5) + 6
    const rx = ctx.W - ctx.M - w(f, num, 9.5) - 6
    if (rx > lx) rule(ctx, lx, rx, ctx.y + 2.5, RULE, 0.5)
  }
}

/// A hanging paragraph: an optional marker in the left margin ("A.", "(c)"),
/// an optional bold lead-in that runs INTO the first line (a defined term), and
/// a justified body. Every line is placed one at a time, so a page break in the
/// middle of a definition still leaves its marker on the line it belongs to —
/// the bug that comes from measuring a block and then drawing it.
function hangPara(ctx: Ctx, o: {
  marker?: string; markerX?: number; lead?: string; body: string
  x: number; width: number; size?: number; gapAfter?: number
}) {
  const size = o.size ?? ctx.size
  const lh = size * (ctx.doc.page?.line_gap ?? 1.4)
  const leadTxt = safe(o.lead ?? '')
  const leadW = leadTxt ? w(ctx.FB, leadTxt, size) + w(ctx.F, ' ', size) : 0
  const words = safe(o.body).split(/\s+/).filter(Boolean)
  const sp = w(ctx.F, ' ', size)
  const lines: string[][] = []
  let cur: string[] = [], curW = 0
  for (const word of words) {
    const avail = (lines.length === 0 ? o.width - leadW : o.width)
    const add = w(ctx.F, word, size)
    if (cur.length && curW + sp + add > avail) { lines.push(cur); cur = [word]; curW = add }
    else { curW += (cur.length ? sp : 0) + add; cur.push(word) }
  }
  if (cur.length) lines.push(cur)
  if (!lines.length) lines.push([])
  if (lines.length > 1 && ctx.y - lh * 2 < ctx.contentBottom) newPage(ctx)
  for (let i = 0; i < lines.length; i++) {
    if (ctx.y - lh < ctx.contentBottom) newPage(ctx)
    ctx.y -= lh
    const justify = i < lines.length - 1
    if (i === 0) {
      if (o.marker) text(ctx, o.marker, o.markerX ?? ctx.M, ctx.y, size, ctx.F, GREY)
      if (leadTxt) text(ctx, leadTxt, o.x, ctx.y, size, ctx.FB, INK)
      drawLine(ctx, lines[0], o.x + leadW, ctx.y, size, ctx.F, o.width - leadW, justify)
    } else {
      drawLine(ctx, lines[i], o.x, ctx.y, size, ctx.F, o.width, justify)
    }
  }
  ctx.y -= o.gapAfter ?? size * 0.7
}

// ── body ────────────────────────────────────────────────────────────────────
function recitals(ctx: Ctx) {
  const r = ctx.doc.recitals ?? {}
  const items = Array.isArray(r.items) ? r.items : []
  if (!items.length) return
  newPage(ctx)
  sectionHeading(ctx, r.heading ?? '', 'recitals')
  const HANG = 26
  for (const it of items) {
    if (it?.is_lead_out === true) {
      ctx.y -= 6
      para(ctx, it?.text ?? '', ctx.M, ctx.W - 2 * ctx.M, { font: ctx.FB, gapAfter: 8 })
      continue
    }
    hangPara(ctx, {
      marker: String(it?.label ?? ''), body: String(it?.text ?? ''),
      x: ctx.M + HANG, width: ctx.W - 2 * ctx.M - HANG, gapAfter: 9 })
  }
}

function definitions(ctx: Ctx) {
  const d = ctx.doc.definitions ?? {}
  const items = Array.isArray(d.items) ? d.items : []
  if (!items.length) return
  sectionHeading(ctx, d.heading ?? '', 'definitions')
  if (d.lead) para(ctx, d.lead, ctx.M, ctx.W - 2 * ctx.M, { gapAfter: 10 })
  const HANG = 30
  for (const it of items) {
    hangPara(ctx, {
      marker: String(it?.label ?? ''), lead: String(it?.term ?? ''),
      body: String(it?.text ?? ''),
      x: ctx.M + HANG, width: ctx.W - 2 * ctx.M - HANG, gapAfter: 8 })
  }
  if (d.note) {
    para(ctx, d.note, ctx.M, ctx.W - 2 * ctx.M,
         { size: 8.5, font: ctx.FI, colour: GREY, gapAfter: 8 })
  }
}

function clauses(ctx: Ctx) {
  const list = Array.isArray(ctx.doc.clauses) ? ctx.doc.clauses : []
  if (!list.length) return
  sectionHeading(ctx, ctx.doc.clauses_heading ?? '')
  const HANG = 30
  for (const c of list) {
    const paras: string[] = Array.isArray(c?.paras) ? c.paras.map((p: unknown) => String(p)) : []
    // heading + two lines of the first paragraph, or the clause starts a page
    need(ctx, 30 + ctx.size * 1.4 * 2)
    anchor(ctx, 'clause:' + String(c?.n ?? ''))
    ctx.y -= 12
    const num = String(c?.number ?? '')
    text(ctx, num, ctx.M, ctx.y, 10.5, ctx.FB, INK)
    const hw = ctx.W - 2 * ctx.M - HANG
    const hl = wrap(ctx.FB, String(c?.heading ?? ''), 10.5, hw)
    for (let i = 0; i < hl.length; i++) {
      text(ctx, hl[i].join(' '), ctx.M + HANG, ctx.y, 10.5, ctx.FB, INK)
      if (i < hl.length - 1) ctx.y -= 14
    }
    if (String(c?.badge ?? '')) {
      rtext(ctx, String(c.badge), ctx.W - ctx.M, ctx.y, 7, ctx.FI, BRAND)
    }
    ctx.y -= 6
    for (const p of paras) {
      para(ctx, p, ctx.M + HANG, ctx.W - 2 * ctx.M - HANG, { gapAfter: 6 })
    }
    ctx.y -= 6
  }
}

// ── schedules ───────────────────────────────────────────────────────────────
function tableRow(ctx: Ctx, cols: any[], row: any, f: any, size: number, colour = INK) {
  const avail = ctx.W - 2 * ctx.M
  const fixed = cols.reduce((a, c) => a + (Number(c.width) > 0 ? Number(c.width) : 0), 0)
  const flexN = cols.filter((c) => !(Number(c.width) > 0)).length
  const flexW = flexN ? Math.max(60, (avail - fixed) / flexN) : 0
  // measure the tallest cell first — a row is one block, never split
  let maxLines = 1
  const cells = cols.map((c) => {
    const cw = (Number(c.width) > 0 ? Number(c.width) : flexW) - 8
    const lines = wrap(f, String(row?.[c.key] ?? ''), size, cw)
    maxLines = Math.max(maxLines, lines.length)
    return { lines, cw, right: c.align === 'right' }
  })
  const lead = size * 1.35
  need(ctx, lead * maxLines + 8)
  const top = ctx.y
  let x = ctx.M
  for (const cell of cells) {
    let yy = top
    for (const ln of cell.lines) {
      yy -= lead
      const s = ln.join(' ')
      if (cell.right) rtext(ctx, s, x + cell.cw, yy, size, f, colour)
      else text(ctx, s, x, yy, size, f, colour)
    }
    x += cell.cw + 8
  }
  ctx.y = top - lead * maxLines - 4
}

function schedules(ctx: Ctx) {
  const list = Array.isArray(ctx.doc.schedules) ? ctx.doc.schedules : []
  if (!list.length) return
  newPage(ctx)
  sectionHeading(ctx, ctx.doc.schedules_heading ?? '')
  for (const s of list) {
    need(ctx, 120)
    anchor(ctx, 'schedule:' + String(s?.code ?? ''))
    ctx.y -= 10
    text(ctx, String(s?.code ?? '').toUpperCase(), ctx.M, ctx.y, 8, ctx.FB, BRAND)
    ctx.y -= 16
    text(ctx, s?.heading ?? '', ctx.M, ctx.y, 12, ctx.FB, INK)
    ctx.y -= 8
    if (s?.intro) para(ctx, s.intro, ctx.M, ctx.W - 2 * ctx.M,
                       { size: 9, colour: GREY, gapAfter: 8 })

    const cols = (Array.isArray(s?.columns) ? s.columns : [])
      .filter((c: any) => c && typeof c.key === 'string')
    const rows = Array.isArray(s?.rows) ? s.rows : []
    if (cols.length) {
      need(ctx, 26)
      const head: Record<string, string> = {}
      for (const c of cols) head[c.key] = String(c.label ?? '')
      tableRow(ctx, cols, head, ctx.FB, 8, GREY)
      rule(ctx, ctx.M, ctx.W - ctx.M, ctx.y + 3)
      ctx.y -= 4
    }
    if (!rows.length) {
      para(ctx, s?.empty_label ?? '', ctx.M, ctx.W - 2 * ctx.M,
           { size: 9, font: ctx.FI, colour: GREY, gapAfter: 6 })
    }
    for (const r of rows) {
      tableRow(ctx, cols, r, ctx.F, 9.5)
      rule(ctx, ctx.M, ctx.W - ctx.M, ctx.y + 4, rgb(0.92, 0.93, 0.94), 0.4)
    }
    ctx.y -= 4
    for (const n of (Array.isArray(s?.notes) ? s.notes : [])) {
      if (!String(n ?? '').trim()) continue
      para(ctx, String(n), ctx.M, ctx.W - 2 * ctx.M,
           { size: 8.5, font: ctx.FI, colour: GREY, gapAfter: 6 })
    }
    ctx.y -= 14
  }
}

// ── execution + verification ────────────────────────────────────────────────
function execution(ctx: Ctx) {
  const sg = ctx.doc.signature ?? {}
  const parties = Array.isArray(sg.parties) ? sg.parties : []
  const rowsMax = parties.reduce(
    (a: number, p: any) => Math.max(a, (Array.isArray(p?.rows) ? p.rows.length : 0)), 0)
  const blockH = 70 + rowsMax * 15
  need(ctx, blockH + 80)
  anchor(ctx, 'signatures')
  sectionHeading(ctx, sg.heading ?? '')
  if (sg.lead) para(ctx, sg.lead, ctx.M, ctx.W - 2 * ctx.M, { gapAfter: 14 })

  need(ctx, blockH + 10)
  const colW = (ctx.W - 2 * ctx.M - 22) / 2
  const top = ctx.y
  for (let i = 0; i < parties.length; i++) {
    const p = parties[i] ?? {}
    const x = ctx.M + i * (colW + 22)
    let yy = top
    ctx.page.drawRectangle({ x: x - 8, y: top - blockH + 12, width: colW + 16,
                             height: blockH, color: rgb(1, 1, 1),
                             borderColor: RULE, borderWidth: 0.6 })
    yy -= 14
    for (const ln of wrap(ctx.FB, String(p.title ?? ''), 8.5, colW)) {
      text(ctx, ln.join(' '), x, yy, 8.5, ctx.FB, BRAND); yy -= 11
    }
    yy -= 4
    for (const r of (Array.isArray(p.rows) ? p.rows : [])) {
      text(ctx, r?.label ?? '', x, yy, 7.5, ctx.F, GREY)
      const vx = x + 62
      const vl = wrap(ctx.FB, String(r?.value ?? ''), 8.5, colW - 62)
      for (let k = 0; k < vl.length; k++) {
        text(ctx, vl[k].join(' '), vx, yy - k * 10, 8.5, ctx.FB, INK)
      }
      yy -= 15 + (vl.length - 1) * 10
    }
    // the rule a pen would sign on
    yy -= 6
    rule(ctx, x, x + colW - 10, yy, GREY, 0.6)
  }
  ctx.y = top - blockH - 6

  if (sg.note) para(ctx, sg.note, ctx.M, ctx.W - 2 * ctx.M,
                    { size: 8.5, font: ctx.FI, colour: GREY, gapAfter: 10 })

  // ── the verification panel ────────────────────────────────────────────────
  const v = ctx.doc.verify ?? {}
  need(ctx, 112)
  ctx.y -= 8
  const panelTop = ctx.y
  const panelH = 96
  ctx.page.drawRectangle({ x: ctx.M, y: panelTop - panelH, width: ctx.W - 2 * ctx.M,
                           height: panelH, color: SOFT, borderColor: RULE, borderWidth: 0.6 })
  drawQr(ctx, ctx.W - ctx.M - 84, panelTop - panelH + 16, 68)
  let vy = panelTop - 20
  text(ctx, v.heading ?? '', ctx.M + 14, vy, 10, ctx.FB, BRAND)
  vy -= 14
  for (const ln of wrap(ctx.F, String(v.line ?? ''), 8.5, ctx.W - 2 * ctx.M - 120)) {
    text(ctx, ln.join(' '), ctx.M + 14, vy, 8.5, ctx.F, INK); vy -= 11
  }
  vy -= 4
  for (const ln of wrap(ctx.F, String(v.url ?? ''), 8, ctx.W - 2 * ctx.M - 120)) {
    text(ctx, ln.join(' '), ctx.M + 14, vy, 8, ctx.FB, BRAND); vy -= 10
  }
  for (const ln of wrap(ctx.F, String(v.caption ?? ''), 7.5, ctx.W - 2 * ctx.M - 120)) {
    text(ctx, ln.join(' '), ctx.M + 14, vy, 7.5, ctx.F, GREY); vy -= 9
  }
  ctx.y = panelTop - panelH - 10
}

// ── one pass over the whole document ────────────────────────────────────────
async function layout(doc: any, pageMap: Record<string, number> | null) {
  const pdf = await PDFDocument.create()
  const fonts = await serifFonts()
  let F: any, FB: any, FI: any
  if (fonts) {
    pdf.registerFontkit(fontkit)
    F = await pdf.embedFont(fonts.reg, { subset: true })
    FB = await pdf.embedFont(fonts.bold, { subset: true })
    FI = await pdf.embedFont(fonts.ital, { subset: true })
    UNICODE = true
  } else {
    F = await pdf.embedFont(StandardFonts.TimesRoman)
    FB = await pdf.embedFont(StandardFonts.TimesBold)
    FI = await pdf.embedFont(StandardFonts.TimesItalic)
    UNICODE = false
  }

  const pg = doc.page ?? {}
  const M = Number(pg.margin) > 0 ? Number(pg.margin) : 57
  const ctx: Ctx = {
    pdf, F, FB, FI, page: null, y: 0, pageNo: 0,
    W: Number(pg.width) || 595, H: Number(pg.height) || 842, M,
    size: Number(pg.body_size) || 10.5, lead: 1.4,
    doc, qrMods: qrModules(String(doc?.verify?.url ?? '')),
    anchors: {}, pageMap, contentBottom: M + 26,
  }

  cover(ctx)
  contents(ctx)
  recitals(ctx)
  definitions(ctx)
  clauses(ctx)
  schedules(ctx)
  execution(ctx)

  return { pdf, anchors: ctx.anchors, total: ctx.pageNo }
}

/// TWO PASSES: lay it out, learn which page each heading landed on, print it
/// again with those numbers in the contents. Nothing after the contents page
/// differs between the passes, so the numbers are exact rather than guessed.
export async function renderContract(doc: any): Promise<Uint8Array> {
  const first = await layout(doc, null)
  const map: Record<string, number> = { ...first.anchors }
  map.__total = first.total
  const second = await layout(doc, map)
  return await second.pdf.save()
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)
  if ((req.headers.get('x-notify-secret') ?? '') !== NOTIFY_SECRET)
    return json({ error: 'forbidden' }, 403)

  let docId = ''
  try {
    const body = await req.json().catch(() => ({}))
    docId = String(body?.partner_doc_id ?? '')
    if (!docId) return json({ error: 'partner_doc_id required' }, 400)

    const { data: input, error } = await supabase
      .rpc('agreement_pdf_input', { p_doc_id: docId })
    if (error) throw new Error('agreement_pdf_input: ' + error.message)
    if (!input?.ok) {
      await supabase.rpc('partner_doc_report', {
        p_doc_id: docId, p_ok: false,
        p_error: 'render_input: ' + (input?.error ?? 'unknown'),
      }).catch(() => {})
      return json({ ok: false, reason: input?.error ?? 'no_input' })
    }

    const bytes = await renderContract(input.contract)
    const up = await supabase.storage.from(String(input.bucket))
      .upload(String(input.path), bytes,
              { contentType: 'application/pdf', upsert: true })
    if (up.error) throw new Error('upload: ' + up.error.message)

    const { data: rep } = await supabase.rpc('partner_doc_report', {
      p_doc_id: docId, p_ok: true, p_bucket: input.bucket, p_path: input.path,
      p_name: input.file_name, p_bytes: bytes.length,
    })
    return json({ ok: true, doc_id: docId, path: input.path,
                  name: input.file_name, bytes: bytes.length, report: rep })
  } catch (e) {
    const m = e instanceof Error ? e.message : String(e)
    if (docId) {
      await supabase.rpc('partner_doc_report', {
        p_doc_id: docId, p_ok: false, p_error: m }).catch(() => {})
    }
    return json({ ok: false, error: m }, 200)
  }
})
