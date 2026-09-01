// CMD #411 — the pharmacy's own RETAIL tax invoice.
//
// A mediBO pharmacy sells over its counter to a walk-in patient and prints a
// GST tax invoice on its OWN GSTIN and drug licence. pos_invoice_request()
// posts {pos_sale_id} here; this function asks the backend for the finished
// document (pos_invoice_render_input), draws it, stores the PDF under
// customer-bills/pos/<pharmacy>/<sale>.pdf and reports through
// pos_invoice_report() — which is what flips the receipt to `ready` and lets
// the counter print it or send it on WhatsApp.
//
// It gets its own function rather than a branch inside bill-render for two
// reasons: bill-render draws the customer invoices for the whole B2B business
// and is not worth the blast radius of an unrelated change, and a retail
// counter bill is a genuinely different document — portrait, short, and headed
// by the PHARMACY's identity rather than mediBO's.
//
// It computes NOTHING. Every string on the page — every rupee, every
// percentage, the amount in words, every column label and its order — arrives
// finished from pos_invoice_render_input().
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1'
import fontkit from 'https://esm.sh/@pdf-lib/fontkit@1.1.1'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

// A4 portrait — a counter bill is a tall, short document.
const PW = 595, PH = 842, PM = 36

// An invoice that prints "Rs." where the pharmacist expects ₹ looks wrong, so
// Noto Sans (which has U+20B9) is embedded and the built-in WinAnsi fonts are
// the fallback. UNICODE says which mode we are in; ansi() only strips when it
// has to — pdf-lib's standard fonts THROW on ₹ rather than dropping it, and
// every money string the backend sends starts with one.
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

function ansi(s: unknown): string {
  const raw = String(s ?? '')
  if (UNICODE) return raw
  return raw
    .replace(/₹/g, 'Rs.')
    .replace(/[−–—]/g, '-')
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/·/g, '|')
    .replace(/[^\x20-\x7E\xA0-\xFF]/g, '')
}

function clip(s: string, font: any, size: number, max: number): string {
  let t = ansi(s)
  while (t.length > 1 && font.widthOfTextAtSize(t, size) > max) t = t.slice(0, -1)
  return t
}

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
  const hr = (yy: number) => page.drawLine({
    start: { x: PM, y: yy }, end: { x: PW - PM, y: yy }, thickness: 0.5, color: line })
  const newPage = () => { page = pdf.addPage([PW, PH]); y = PH - PM }

  const seller = inv.seller ?? {}, invo = inv.invoice ?? {}, net = inv.net ?? {}

  // ── the SELLER is the pharmacy, on its own licence ────────────────────────
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

  // ── invoice meta, two to a row ────────────────────────────────────────────
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

  // ── the line table. Widths are this file's layout; the column ORDER and the
  //    LABELS are the payload's, so a backend column change moves the page.
  // These must SUM to no more than the printable width (PW - 2*PM = 523pt) or
  // the right-hand columns run off the page — the first render clipped every
  // Amount to "₹11.3". 18+120+38+40+32+26+46+32+46+30+38+57 = 523.
  const PCOL: Record<string, number> = {
    sn: 18, product: 120, pack: 38, batch_no: 40, expiry: 32, qty: 26,
    mrp: 46, disc: 32, taxable: 46, gst_pct: 30, gst_amt: 38, amount: 57,
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

  // ── tax ladder (left) beside the totals (right) ───────────────────────────
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
  hr(ty + 8)
  ty -= 4
  txt(net.label ?? '', PW - PM - 190, ty - 4, 10.5, FB)
  rtxt(net.value ?? '', PW - PM, ty - 4, 11.5, FB, brand)
  ty -= 20

  y = Math.min(ladderEnd, ty) - 12
  if (net.words) { txt(net.words, PM, y, 8, F, grey); y -= 14 }

  const foot = inv.footer ?? {}
  hr(y); y -= 12
  if (foot.items) txt(foot.items, PM, y, 7.5, F, grey)
  if (foot.note) rtxt(foot.note, PW - PM, y, 7.5, F, grey)

  return await pdf.save()
}

Deno.serve(async (req) => {
  let saleId = ''
  try {
    const body = await req.json().catch(() => ({}))
    saleId = String(body?.pos_sale_id ?? '')
    if (!saleId) return json({ error: 'pos_sale_id required' }, 400)

    const { data: input, error: inErr } = await supabase
      .rpc('pos_invoice_render_input', { p_sale_id: saleId })
    if (inErr) throw new Error('pos_invoice_render_input: ' + inErr.message)
    if (!input?.ok) {
      await supabase.rpc('pos_invoice_report', {
        p_sale_id: saleId, p_ok: false,
        p_error: 'render_input: ' + (input?.error ?? 'unknown'),
      }).catch(() => {})
      return json({ ok: false, reason: input?.error ?? 'no_input' })
    }

    const bytes = await renderPosInvoice(input.invoice)
    const up = await supabase.storage.from(String(input.bucket))
      .upload(String(input.path), bytes,
              { contentType: 'application/pdf', upsert: true })
    if (up.error) throw new Error('upload: ' + up.error.message)

    const { data: rep } = await supabase.rpc('pos_invoice_report', {
      p_sale_id: saleId, p_ok: true, p_bucket: input.bucket,
      p_path: input.path, p_name: input.file_name, p_bytes: bytes.length,
    })
    return json({ ok: true, pos_sale_id: saleId, path: input.path,
                  name: input.file_name, bytes: bytes.length, report: rep })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (saleId) {
      await supabase.rpc('pos_invoice_report',
        { p_sale_id: saleId, p_ok: false, p_error: msg }).catch(() => {})
    }
    return json({ ok: false, error: msg }, 200)
  }
})
