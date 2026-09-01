// CHANGE #226 — the customer bill renderer for the AUTOMATIC chain.
// CHANGE #403 — the SAME pipeline now also draws supplier documents: a purchase
//               order, a copy of an imported bill, and a monthly statement.
//               POST {supplier_doc_id} asks supplier_doc_render_input() for a
//               finished payload, draws it with renderDoc(), stores it under
//               supplier-docs/<supplier>/<kind>/<ref>.pdf and reports through
//               supplier_doc_report(). It gets its own layout rather than the
//               invoice one because renderPdf() hardcodes an invoice's shape —
//               a CGST/SGST ladder, an HSN summary, "Less: Paid" — none of
//               which belongs on a purchase order or a statement. It still
//               computes nothing: every label, number and column below arrives
//               in the payload.
// CHANGE #236 — the full tax-invoice page: HSN + free quantity columns, an
//               HSN-wise tax summary, item/quantity counts, the bank + UPI
//               block, the jurisdiction line, a signature block, and a SAMPLE
//               watermark for customer_bill_sample().
//
// bill_jobs_tick() posts {job_id} here. This function asks the backend for the
// finished bill (bill_job_render_input), draws it, stores the PDF in the
// `customer-bills` bucket, and reports back through bill_job_report() — which
// is what sets orders.cust_bill_path and fires the two WhatsApp messages.
//
// POST {sample:true} renders customer_bill_sample() instead: the SAME payload
// shape through the SAME code below, stored under sample/, touching no order.
//
// It computes nothing. Every number, label and column on the page arrives in
// the payload from customer_bill() / customer_bill_sample(); this file only
// lays them out.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { PDFDocument, StandardFonts, degrees, rgb } from 'https://esm.sh/pdf-lib@1.17.1'
import fontkit from 'https://esm.sh/@pdf-lib/fontkit@1.1.1'

const NOTIFY_SECRET = 'medibo_order_notify_2027'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

// A4 landscape
const W = 842, H = 595, M = 20

type Col = { key: string; label: string; w: number; right?: boolean }
// Widths are the renderer's own layout constants; the LABELS and the order come
// from the payload's `columns`, so a backend column change moves the page.
const COL_W: Record<string, number> = {
  sn: 16, product: 138, pack: 56, hsn: 34, batch_no: 52, expiry: 30,
  qty: 26, free: 26, mrp: 44, ptr: 44, value: 52, disc: 44,
  taxable: 52, gst_pct: 30, gst_amt: 46, amount: 56,
}
const RIGHT_KEYS = new Set(['qty', 'free', 'mrp', 'ptr', 'value', 'disc', 'taxable', 'gst_pct', 'gst_amt', 'amount'])

function columnsOf(bill: any): Col[] {
  const raw = Array.isArray(bill?.columns) ? bill.columns : []
  const cols: Col[] = raw
    .filter((c: any) => c && typeof c.key === 'string')
    .map((c: any) => ({
      key: c.key,
      label: String(c.label ?? ''),
      w: COL_W[c.key] ?? 46,
      right: c.align ? c.align === 'right' : RIGHT_KEYS.has(c.key),
    }))
  return cols.length ? cols : []
}

// CHANGE #236: an invoice that prints "Rs." instead of ₹ looks wrong to the
// pharmacy receiving it, so we embed Noto Sans (which has U+20B9) and fall back
// to the built-in WinAnsi fonts if the font fetch fails for any reason. UNICODE
// says which mode a render is in; ansi() only strips when it has to.
const FONT_REG_URL = 'https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Regular.ttf'
const FONT_BOLD_URL = 'https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf/NotoSans/NotoSans-Bold.ttf'
let FONT_CACHE: { reg: Uint8Array; bold: Uint8Array } | null = null
let UNICODE = false

async function unicodeFonts(): Promise<{ reg: Uint8Array; bold: Uint8Array } | null> {
  if (FONT_CACHE) return FONT_CACHE
  try {
    const ctl = new AbortController()
    const t = setTimeout(() => ctl.abort(), 8000)
    const [a, b] = await Promise.all([
      fetch(FONT_REG_URL, { signal: ctl.signal }),
      fetch(FONT_BOLD_URL, { signal: ctl.signal }),
    ])
    clearTimeout(t)
    if (!a.ok || !b.ok) return null
    FONT_CACHE = {
      reg: new Uint8Array(await a.arrayBuffer()),
      bold: new Uint8Array(await b.arrayBuffer()),
    }
    return FONT_CACHE
  } catch (_) { return null }
}

// pdf-lib's standard fonts are WinAnsi — ₹ (U+20B9) and − (U+2212) are not in
// that encoding and drawText THROWS on them rather than dropping them. Every
// money label the backend sends starts with ₹, so without this the whole render
// fails. Same mapping is applied to the on-demand `bill-pdf` download.
function ansi(s: unknown): string {
  const raw = String(s ?? '')
  if (UNICODE) return raw
  return raw
    .replace(/₹/g, 'Rs.')
    .replace(/[−–—]/g, '-')
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/·/g, '|')
    // anything still outside WinAnsi would throw; drop it rather than fail
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, '')
}

function clip(s: string, font: any, size: number, max: number): string {
  let t = ansi(s)
  while (t.length > 1 && font.widthOfTextAtSize(t, size) > max) t = t.slice(0, -1)
  return t
}

async function renderPdf(bill: any): Promise<Uint8Array> {
  const inv = bill.invoice ?? {}, tot = bill.totals ?? {}
  const pay = bill.payment ?? {}, foot = bill.footer ?? {}, counts = bill.counts ?? {}
  const COLS = columnsOf(bill)
  const pdf = await PDFDocument.create()
  let F: any, FB: any
  const uni = await unicodeFonts()
  if (uni) {
    try {
      pdf.registerFontkit(fontkit)
      F = await pdf.embedFont(uni.reg, { subset: true })
      FB = await pdf.embedFont(uni.bold, { subset: true })
      UNICODE = true
    } catch (_) { UNICODE = false }
  } else UNICODE = false
  if (!F) {
    F = await pdf.embedFont(StandardFonts.Helvetica)
    FB = await pdf.embedFont(StandardFonts.HelveticaBold)
  }
  const ink = rgb(0.1, 0.1, 0.1), grey = rgb(0.45, 0.45, 0.45), line = rgb(0.8, 0.8, 0.8)
  const brand = rgb(0.05, 0.42, 0.24), warn = rgb(0.8, 0.2, 0.2)

  let page = pdf.addPage([W, H])
  let y = H - M
  const pages: any[] = [page]

  const txt = (s: unknown, x: number, yy: number, size = 8, f = F, c = ink) =>
    page.drawText(ansi(s), { x, y: yy, size, font: f, color: c })
  const rtxt = (s: unknown, xRight: number, yy: number, size = 8, f = F, c = ink) => {
    const t = ansi(s)
    page.drawText(t, { x: xRight - f.widthOfTextAtSize(t, size), y: yy, size, font: f, color: c })
  }
  const hr = (yy: number) => page.drawLine({
    start: { x: M, y: yy }, end: { x: W - M, y: yy }, thickness: 0.5, color: line })

  const header = () => {
    y = H - M - 10
    txt(bill.title ?? 'TAX INVOICE', M, y, 13, FB, brand)
    rtxt(inv.number, W - M, y, 10, FB)
    y -= 14
    txt(inv.seller?.name, M, y, 9, FB)
    rtxt('Date: ' + ansi(inv.date), W - M, y, 8, F, grey)
    y -= 11
    const sBits = [
      inv.seller?.address?.replace(/\s*\n\s*/g, ', '), inv.seller?.state,
      inv.seller?.gstin ? 'GSTIN: ' + inv.seller.gstin : null,
      inv.seller?.dl ? 'DL: ' + inv.seller.dl : null,
    ].filter(Boolean).join('  |  ')
    txt(clip(sBits, F, 7.5, W - 2 * M), M, y, 7.5, F, grey)
    y -= 10
    const sBits2 = [
      inv.seller?.fssai ? 'FSSAI: ' + inv.seller.fssai : null,
      inv.seller?.phone ? 'Phone: ' + inv.seller.phone : null,
      inv.seller?.email ? 'Email: ' + inv.seller.email : null,
    ].filter(Boolean).join('  |  ')
    if (sBits2) { txt(clip(sBits2, F, 7.5, W - 2 * M), M, y, 7.5, F, grey); y -= 10 }
    y -= 4

    txt('Billed to:', M, y, 8, FB)
    txt(inv.buyer?.name, M + 45, y, 8, FB)
    y -= 10
    const bBits = [
      inv.buyer?.address, inv.buyer?.state, inv.buyer?.phone,
      inv.buyer?.gstin ? 'GSTIN: ' + inv.buyer.gstin : null,
      inv.buyer?.dl ? 'DL: ' + inv.buyer.dl : null,
    ].filter(Boolean).join('  |  ')
    txt(clip(bBits, F, 7.5, W - 2 * M), M, y, 7.5, F, grey)
    y -= 12

    if (bill.sample_banner) { txt(clip(String(bill.sample_banner), FB, 7.5, W - 2 * M), M, y, 7.5, FB, warn); y -= 11 }
    if (inv.seller?.warning) { txt(inv.seller.warning, M, y, 7, FB, warn); y -= 11 }
    hr(y); y -= 12

    let x = M
    for (const c of COLS) {
      if (c.right) rtxt(c.label, x + c.w, y, 7.5, FB); else txt(c.label, x, y, 7.5, FB)
      x += c.w
    }
    y -= 4; hr(y); y -= 11
  }

  header()

  for (const L of (bill.lines ?? []) as Record<string, string>[]) {
    if (y < 190) { page = pdf.addPage([W, H]); pages.push(page); header() }
    let x = M
    for (const c of COLS) {
      const v = L[c.key] ?? ''
      if (c.right) rtxt(v, x + c.w, y, 7); else txt(clip(v, F, 7, c.w - 4), x, y, 7)
      x += c.w
    }
    y -= 10
  }

  y -= 4; hr(y); y -= 12
  if (counts.label) txt(counts.label, M, y, 7.5, FB, grey)
  y -= 14
  const blockTop = y

  // ── totals column (right) ────────────────────────────────────────────────
  const RX = W - M, LX = W - M - 160
  const row = (label: string, value: unknown, bold = false, size = 8) => {
    txt(label, LX, y, size, bold ? FB : F, bold ? ink : grey)
    rtxt(value, RX, y, size, bold ? FB : F)
    y -= 11
  }
  row(ansi(tot.ptr_total_caption ?? 'Sub Total'), tot.ptr_total_label)
  row(ansi(tot.discount_label ?? 'Discount'), tot.discount_amount_label)
  row('Taxable Value', tot.taxable_label, true)
  row('CGST', tot.cgst_label)
  row('SGST', tot.sgst_label)
  if (tot.round_off_label) row('Round Off', tot.round_off_label)
  y -= 2
  page.drawLine({ start: { x: LX, y: y + 6 }, end: { x: RX, y: y + 6 }, thickness: 0.8, color: ink })
  y -= 4
  row('NET TOTAL', tot.net_payable_label, true, 10)
  row('Less: Paid', tot.paid_label)
  row('BALANCE DUE', tot.remaining_label, true, 10)
  const totalsBottom = y

  // ── HSN-wise tax summary (left), starting level with the totals ──────────
  let gy = blockTop
  txt('HSN-wise tax summary', M, gy, 8, FB); gy -= 11
  const HC = [
    { k: 'hsn', l: 'HSN', x: 0 }, { k: 'rate', l: 'Rate', x: 46 },
    { k: 'taxable', l: 'Taxable', x: 86 }, { k: 'cgst', l: 'CGST', x: 156 },
    { k: 'sgst', l: 'SGST', x: 216 }, { k: 'total', l: 'Tax Total', x: 276 },
  ]
  for (const c of HC) txt(c.l, M + c.x, gy, 7, FB, grey)
  gy -= 10
  for (const g of (bill.hsn_summary ?? []) as Record<string, string>[]) {
    for (const c of HC) txt(g[c.k] ?? '', M + c.x, gy, 7)
    gy -= 10
  }
  gy -= 6
  txt('Amount in words: ' + ansi(tot.in_words), M, gy, 7.5, FB)
  gy -= 6

  // ── payment block + signature + footer, below both columns ───────────────
  const flow = Math.min(gy, totalsBottom) - 10
  let py = flow > 120 ? 120 : flow      // pinned to the foot when there is room
  hr(py + 6)
  const sigTop = py
  if (pay.heading) { txt(pay.heading, M, py, 8, FB); py -= 11 }
  for (const l of (pay.bank_lines ?? []) as string[]) { txt(l, M, py, 7); py -= 10 }
  if (pay.upi_label) { txt(pay.upi_label, M, py, 7); py -= 10 }
  if (pay.note) { txt(pay.note, M, py, 6.5, F, grey); py -= 14 }

  rtxt(foot.signature_for ?? '', W - M, sigTop, 8, F)
  rtxt(foot.signature ?? '', W - M, sigTop - 34, 7, F, grey)

  if (foot.terms) { txt(clip(String(foot.terms), F, 6.5, W - 2 * M), M, py, 6.5, F, grey); py -= 10 }
  if (foot.jurisdiction) txt(clip(String(foot.jurisdiction), F, 6.5, W - 2 * M), M, py, 6.5, F, grey)

  // ── SAMPLE watermark, last so it sits over the page ──────────────────────
  if (bill.watermark) {
    const mark = ansi(bill.watermark)
    for (const p of pages) {
      p.drawText(mark, {
        x: 120, y: 150, size: 110, font: FB,
        color: rgb(0.85, 0.24, 0.24), opacity: 0.16, rotate: degrees(28),
      })
    }
  }

  return await pdf.save()
}


// ── CHANGE #403: the supplier-document page ─────────────────────────────────
// A generic document: a title, a header block of label/value pairs, one or
// more column/row sections, a totals ladder and notes. It names nothing — even
// the column widths arrive in the payload — so a fourth document kind is a
// change in SQL and no deploy here.
// ── CMD #411: the pharmacy's own RETAIL tax invoice ──────────────────────────
// A counter bill is a different document from a trade invoice: it is portrait,
// it is short, and its header is the PHARMACY's identity (its GSTIN, its drug
// licence) rather than mediBO's. It gets its own layout for the same reason the
// supplier documents did — renderPdf() hardcodes a trade invoice's shape.
//
// It computes NOTHING. Every string below — every rupee, every percentage,
// every label, the amount in words — arrives finished from
// pos_invoice_render_input().
const PW = 595, PH = 842, PM = 36   // A4 portrait

async function renderPosInvoice(inv: any): Promise<Uint8Array> {
  const pdf = await PDFDocument.create()
  let F: any, FB: any
  const uni = await unicodeFonts()
  if (uni) {
    try {
      pdf.registerFontkit(fontkit)
      F = await pdf.embedFont(uni.reg, { subset: true })
      FB = await pdf.embedFont(uni.bold, { subset: true })
      UNICODE = true
    } catch (_) { UNICODE = false }
  } else UNICODE = false
  if (!F) {
    F = await pdf.embedFont(StandardFonts.Helvetica)
    FB = await pdf.embedFont(StandardFonts.HelveticaBold)
  }

  const ink = rgb(0.07, 0.09, 0.15), grey = rgb(0.42, 0.45, 0.5)
  const line = rgb(0.85, 0.87, 0.9), brand = rgb(0.05, 0.42, 0.24)

  let page = pdf.addPage([PW, PH])
  let y = PH - PM
  const txt = (s: unknown, x: number, yy: number, size = 8.5, f = F, c = ink) =>
    page.drawText(ansi(s), { x, y: yy, size, font: f, color: c })
  const rtxt = (s: unknown, xr: number, yy: number, size = 8.5, f = F, c = ink) => {
    const t = ansi(s)
    page.drawText(t, { x: xr - f.widthOfTextAtSize(t, size), y: yy, size, font: f, color: c })
  }
  const hr = (yy: number, c = line) => page.drawLine({
    start: { x: PM, y: yy }, end: { x: PW - PM, y: yy }, thickness: 0.5, color: c })
  const newPage = () => { page = pdf.addPage([PW, PH]); y = PH - PM }

  const seller = inv.seller ?? {}, invo = inv.invoice ?? {}, net = inv.net ?? {}

  // ── seller block: the PHARMACY, on its own licence ────────────────────────
  txt(inv.title ?? 'TAX INVOICE', PM, y, 14, FB, brand)
  y -= 18
  txt(seller.name ?? '', PM, y, 11, FB)
  y -= 12
  for (const l of [seller.address, seller.phone, seller.gstin_label, seller.dl_label]) {
    if (!l) continue
    txt(l, PM, y, 8, F, grey)
    y -= 10
  }
  y -= 4; hr(y); y -= 14

  // ── invoice meta ──────────────────────────────────────────────────────────
  const meta: Array<[string, unknown]> = [
    ['Invoice No.', invo.number], ['Date', invo.date], ['Time', invo.time],
    ['Payment', invo.payment], ['Billed by', invo.staff],
    ['Patient', invo.patient], ['Mobile', invo.patient_phone],
  ]
  let col = 0
  for (const [label, value] of meta) {
    if (!value) continue
    const x = PM + (col % 2) * ((PW - 2 * PM) / 2)
    txt(label, x, y, 7.5, FB, grey)
    txt(value, x + 62, y, 8.5)
    if (col % 2 === 1) y -= 12
    col++
  }
  if (col % 2 === 1) y -= 12
  y -= 6; hr(y); y -= 14

  // ── the line table. Column ORDER and LABELS are the payload's ─────────────
  const PCOL: Record<string, number> = {
    sn: 18, product: 150, pack: 44, batch_no: 46, expiry: 32, qty: 26,
    mrp: 46, disc: 32, taxable: 50, gst_pct: 30, gst_amt: 40, amount: 52,
  }
  const PRIGHT = new Set(['qty', 'mrp', 'disc', 'taxable', 'gst_pct', 'gst_amt', 'amount'])
  const cols = (Array.isArray(inv.columns) ? inv.columns : [])
    .filter((c: any) => c && typeof c.key === 'string')
    .map((c: any) => ({
      key: c.key, label: String(c.label ?? ''), w: PCOL[c.key] ?? 44,
      right: c.align ? c.align === 'right' : PRIGHT.has(c.key),
    }))

  const headRow = () => {
    let x = PM
    for (const c of cols) {
      if (c.right) rtxt(c.label, x + c.w, y, 7.5, FB, grey)
      else txt(clip(c.label, FB, 7.5, c.w - 3), x, y, 7.5, FB, grey)
      x += c.w
    }
    y -= 4; hr(y); y -= 11
  }
  headRow()

  for (const row of (Array.isArray(inv.lines) ? inv.lines : [])) {
    if (y < PM + 150) { newPage(); headRow() }
    let x = PM
    for (const c of cols) {
      const v = row[c.key]
      if (c.right) rtxt(v ?? '', x + c.w, y, 8)
      else txt(clip(String(v ?? ''), F, 8, c.w - 3), x, y, 8)
      x += c.w
    }
    y -= 12
  }
  y -= 2; hr(y); y -= 16

  // ── tax ladder (left) + totals (right) ────────────────────────────────────
  const ladderTop = y
  const slabs = Array.isArray(inv.tax_summary) ? inv.tax_summary : []
  if (slabs.length) {
    txt('Tax summary', PM, y, 8, FB, grey); y -= 12
    txt('Rate', PM, y, 7.5, FB, grey)
    txt('Taxable', PM + 44, y, 7.5, FB, grey)
    txt('CGST', PM + 108, y, 7.5, FB, grey)
    txt('SGST', PM + 158, y, 7.5, FB, grey)
    y -= 11
    for (const sl of slabs) {
      txt(sl.rate ?? '', PM, y, 8)
      txt(sl.taxable ?? '', PM + 44, y, 8)
      txt(sl.cgst ?? '', PM + 108, y, 8)
      txt(sl.sgst ?? '', PM + 158, y, 8)
      y -= 11
    }
  }
  const ladderEnd = y

  let ty = ladderTop
  for (const t of (Array.isArray(inv.totals) ? inv.totals : [])) {
    if (!t || t.hide === true) continue
    txt(t.label ?? '', PW - PM - 190, ty, 8.5, F, grey)
    rtxt(t.value ?? '', PW - PM, ty, 8.5)
    ty -= 12
  }
  ty -= 4
  hr(ty + 8)
  txt(net.label ?? '', PW - PM - 190, ty - 4, 10.5, FB)
  rtxt(net.value ?? '', PW - PM, ty - 4, 11.5, FB, brand)
  ty -= 20

  y = Math.min(ladderEnd, ty) - 12
  if (net.words) { txt(net.words, PM, y, 8, F, grey); y -= 14 }

  const foot = inv.footer ?? {}
  hr(y); y -= 12
  if (foot.items) { txt(foot.items, PM, y, 7.5, F, grey) }
  if (foot.note) { rtxt(foot.note, PW - PM, y, 7.5, F, grey) }

  return await pdf.save()
}

async function renderDoc(doc: any): Promise<Uint8Array> {
  const pdf = await PDFDocument.create()
  let F: any, FB: any
  const uni = await unicodeFonts()
  if (uni) {
    try {
      pdf.registerFontkit(fontkit)
      F = await pdf.embedFont(uni.reg, { subset: true })
      FB = await pdf.embedFont(uni.bold, { subset: true })
      UNICODE = true
    } catch (_) { UNICODE = false }
  } else UNICODE = false
  if (!F) {
    F = await pdf.embedFont(StandardFonts.Helvetica)
    FB = await pdf.embedFont(StandardFonts.HelveticaBold)
  }
  const ink = rgb(0.1, 0.1, 0.1), grey = rgb(0.45, 0.45, 0.45)
  const line = rgb(0.8, 0.8, 0.8), brand = rgb(0.05, 0.42, 0.24)

  let page = pdf.addPage([W, H])
  let y = H - M
  const txt = (s: unknown, x: number, yy: number, size = 8, f = F, c = ink) =>
    page.drawText(ansi(s), { x, y: yy, size, font: f, color: c })
  const rtxt = (s: unknown, xRight: number, yy: number, size = 8, f = F, c = ink) => {
    const t = ansi(s)
    page.drawText(t, { x: xRight - f.widthOfTextAtSize(t, size), y: yy, size, font: f, color: c })
  }
  const hr = (yy: number) => page.drawLine({
    start: { x: M, y: yy }, end: { x: W - M, y: yy }, thickness: 0.5, color: line })
  const newPage = () => { page = pdf.addPage([W, H]); y = H - M - 10 }

  // ── title + header ────────────────────────────────────────────────────────
  y -= 10
  txt(doc.title ?? '', M, y, 13, FB, brand)
  rtxt(doc.brand ?? '', W - M, y, 9, FB, grey)
  y -= 12
  if (doc.subtitle) { txt(doc.subtitle, M, y, 7.5, F, grey); y -= 12 }

  const header = Array.isArray(doc.header) ? doc.header : []
  for (let i = 0; i < header.length; i += 2) {
    const pair = (h: any, x: number) => {
      if (!h) return
      const label = ansi(h.label ?? '')
      txt(label, x, y, 7.5, FB, grey)
      txt(h.value ?? '', x + Math.max(90, F.widthOfTextAtSize(label, 7.5) + 8), y, 8)
    }
    pair(header[i], M)
    pair(header[i + 1], M + (W - 2 * M) / 2)
    y -= 11
  }
  y -= 2; hr(y); y -= 14

  // ── sections ──────────────────────────────────────────────────────────────
  for (const sec of (Array.isArray(doc.sections) ? doc.sections : [])) {
    const cols = (Array.isArray(sec.columns) ? sec.columns : [])
      .filter((c: any) => c && typeof c.key === 'string')
      .map((c: any) => ({
        key: c.key, label: String(c.label ?? ''),
        w: Number(c.width) > 0 ? Number(c.width) : 70,
        right: c.align === 'right',
      }))
    const rows = Array.isArray(sec.rows) ? sec.rows : []

    if (y < 90) newPage()
    if (sec.heading) { txt(sec.heading, M, y, 9, FB); y -= 12 }

    const headRow = () => {
      let x = M
      for (const c of cols) {
        if (c.right) rtxt(c.label, x + c.w, y, 7.5, FB, grey)
        else txt(clip(c.label, FB, 7.5, c.w - 4), x, y, 7.5, FB, grey)
        x += c.w
      }
      y -= 4; hr(y); y -= 11
    }
    if (cols.length) headRow()

    if (!rows.length) {
      txt(sec.empty_label ?? '', M, y, 7.5, F, grey)
      y -= 16
      continue
    }
    for (const r of rows as Record<string, string>[]) {
      if (y < 70) { newPage(); if (cols.length) headRow() }
      let x = M
      for (const c of cols) {
        const v = r[c.key] ?? ''
        if (c.right) rtxt(clip(v, F, 7, c.w - 4), x + c.w, y, 7)
        else txt(clip(v, F, 7, c.w - 4), x, y, 7)
        x += c.w
      }
      y -= 10
    }
    y -= 10
  }

  // ── totals ladder, right column ───────────────────────────────────────────
  const totals = Array.isArray(doc.totals) ? doc.totals : []
  if (totals.length) {
    if (y < 40 + 12 * totals.length) newPage()
    const RX = W - M, LX = W - M - 200
    page.drawLine({ start: { x: LX, y: y + 8 }, end: { x: RX, y: y + 8 },
                    thickness: 0.8, color: ink })
    for (const t of totals) {
      const bold = t?.bold === true
      txt(t?.label ?? '', LX, y, bold ? 9 : 8, bold ? FB : F, bold ? ink : grey)
      rtxt(t?.value ?? '', RX, y, bold ? 9 : 8, bold ? FB : F)
      y -= 12
    }
    y -= 6
  }

  // ── notes + footer ────────────────────────────────────────────────────────
  for (const n of (Array.isArray(doc.notes) ? doc.notes : [])) {
    if (!n) continue
    if (y < 40) newPage()
    txt(clip(String(n), F, 7, W - 2 * M), M, y, 7, F, grey)
    y -= 10
  }
  if (doc.footer) {
    if (y < 34) newPage()
    y -= 4
    hr(y); y -= 11
    txt(clip(String(doc.footer), F, 6.5, W - 2 * M), M, y, 6.5, F, grey)
  }

  return await pdf.save()
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)
  if ((req.headers.get('x-notify-secret') ?? '') !== NOTIFY_SECRET)
    return json({ error: 'forbidden' }, 403)

  let jobId = ''
  try {
    const body = await req.json().catch(() => ({}))

    // ── sample mode: no job, no order, nothing written outside sample/ ─────
    if (body?.sample === true) {
      const { data: sample, error: sErr } = await supabase.rpc('customer_bill_sample')
      if (sErr) throw new Error('customer_bill_sample: ' + sErr.message)
      const bytes = await renderPdf(sample)
      const stamp = String(body?.stamp ?? Date.now()).replace(/[^0-9A-Za-z-]/g, '')
      const path = `sample/${stamp}.pdf`
      const name = String(body?.name ?? `mediBO-SAMPLE-Invoice.pdf`).replace(/[^0-9A-Za-z._-]/g, '')
      const up = await supabase.storage.from('customer-bills')
        .upload(path, bytes, { contentType: 'application/pdf', upsert: true })
      if (up.error) throw new Error('upload: ' + up.error.message)
      return json({
        ok: true, sample: true, bucket: 'customer-bills', path, name,
        bytes: bytes.length,
        invoice_no: sample?.invoice?.number ?? null,
        net_payable: sample?.totals?.net_payable ?? null,
        remaining: sample?.totals?.remaining ?? null,
      })
    }

    // ── CMD #411: pharmacy retail invoice mode ───────────────────────────
    const posSaleId = String(body?.pos_sale_id ?? '')
    if (posSaleId) {
      const { data: input, error: pErr } = await supabase
        .rpc('pos_invoice_render_input', { p_sale_id: posSaleId })
      if (pErr) throw new Error('pos_invoice_render_input: ' + pErr.message)
      if (!input?.ok) {
        await supabase.rpc('pos_invoice_report', {
          p_sale_id: posSaleId, p_ok: false,
          p_error: 'render_input: ' + (input?.error ?? 'unknown'),
        }).catch(() => {})
        return json({ ok: false, reason: input?.error ?? 'no_input' })
      }
      try {
        const bytes = await renderPosInvoice(input.invoice)
        const up = await supabase.storage.from(String(input.bucket))
          .upload(String(input.path), bytes,
                  { contentType: 'application/pdf', upsert: true })
        if (up.error) throw new Error('upload: ' + up.error.message)
        const { data: rep } = await supabase.rpc('pos_invoice_report', {
          p_sale_id: posSaleId, p_ok: true, p_bucket: input.bucket,
          p_path: input.path, p_name: input.file_name, p_bytes: bytes.length,
        })
        return json({ ok: true, pos_sale_id: posSaleId, path: input.path,
                      name: input.file_name, bytes: bytes.length, report: rep })
      } catch (e) {
        const m = e instanceof Error ? e.message : String(e)
        await supabase.rpc('pos_invoice_report', {
          p_sale_id: posSaleId, p_ok: false, p_error: m }).catch(() => {})
        return json({ ok: false, pos_sale_id: posSaleId, error: m })
      }
    }

    // ── CHANGE #403: supplier document mode ──────────────────────────────
    const docId = String(body?.supplier_doc_id ?? '')
    if (docId) {
      const { data: input, error: dErr } = await supabase
        .rpc('supplier_doc_render_input', { p_doc_id: docId })
      if (dErr) throw new Error('supplier_doc_render_input: ' + dErr.message)
      if (!input?.ok) {
        await supabase.rpc('supplier_doc_report', {
          p_doc_id: docId, p_ok: false,
          p_error: 'render_input: ' + (input?.error ?? 'unknown'),
        }).catch(() => {})
        return json({ ok: false, reason: input?.error ?? 'no_input' })
      }
      try {
        const bytes = await renderDoc(input.document)
        const up = await supabase.storage.from(String(input.bucket))
          .upload(String(input.path), bytes,
                  { contentType: 'application/pdf', upsert: true })
        if (up.error) throw new Error('upload: ' + up.error.message)
        const { data: rep } = await supabase.rpc('supplier_doc_report', {
          p_doc_id: docId, p_ok: true, p_bucket: input.bucket, p_path: input.path,
          p_name: input.file_name, p_bytes: bytes.length,
        })
        return json({ ok: true, doc_id: docId, path: input.path,
                      name: input.file_name, bytes: bytes.length, report: rep })
      } catch (e) {
        const m = e instanceof Error ? e.message : String(e)
        await supabase.rpc('supplier_doc_report', {
          p_doc_id: docId, p_ok: false, p_error: m }).catch(() => {})
        return json({ ok: false, doc_id: docId, error: m })
      }
    }

    jobId = String(body?.job_id ?? '')
    if (!jobId) return json({ error: 'job_id required' }, 400)

    const { data: input, error: inErr } = await supabase
      .rpc('bill_job_render_input', { p_job_id: jobId })
    if (inErr) throw new Error('render_input: ' + inErr.message)
    if (!input?.ok) throw new Error('render_input: ' + (input?.error ?? 'unknown'))

    const bill = input.bill
    if (!bill?.ready) {
      // The order stopped being ready between enqueue and render. Report it as a
      // failure so the job retries instead of storing half an invoice.
      await supabase.rpc('bill_job_report', {
        p_job_id: jobId, p_ok: false,
        p_error: 'bill_not_ready: ' + (bill?.message ?? ''),
      })
      return json({ ok: false, reason: 'bill_not_ready' })
    }

    const bytes = await renderPdf(bill)
    const code = String(input.order_code ?? '').replace(/[^A-Za-z0-9-]/g, '') || 'order'
    const name = `Invoice-${code}.pdf`
    const path = `auto/${code}/${jobId}.pdf`

    const up = await supabase.storage.from('customer-bills')
      .upload(path, bytes, { contentType: 'application/pdf', upsert: true })
    if (up.error) throw new Error('upload: ' + up.error.message)

    const { data: rep, error: repErr } = await supabase.rpc('bill_job_report', {
      p_job_id: jobId, p_ok: true,
      p_bucket: 'customer-bills', p_path: path, p_name: name,
    })
    if (repErr) throw new Error('report: ' + repErr.message)

    return json({ ok: true, job_id: jobId, path, name, report: rep })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (jobId) {
      await supabase.rpc('bill_job_report', { p_job_id: jobId, p_ok: false, p_error: msg })
        .catch(() => {})
    }
    return json({ ok: false, error: msg }, 200)
  }
})
