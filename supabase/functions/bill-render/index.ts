// CHANGE #226 — the customer bill renderer for the AUTOMATIC chain.
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
