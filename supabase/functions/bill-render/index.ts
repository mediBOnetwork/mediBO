// CHANGE #226 — the customer bill renderer for the AUTOMATIC chain.
//
// bill_jobs_tick() posts {job_id} here. This function asks the backend for the
// finished bill (bill_job_render_input), draws it, stores the PDF in the
// `customer-bills` bucket, and reports back through bill_job_report() — which
// is what sets orders.cust_bill_path and fires the two WhatsApp messages.
//
// It computes nothing. Every number, label and column on the page arrives in
// the payload from customer_bill(); this file only lays them out.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1'

const NOTIFY_SECRET = 'medibo_order_notify_2027'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

// A4 landscape
const W = 842, H = 595, M = 20

type Col = { key: string; label: string; w: number; right?: boolean }
const COLS: Col[] = [
  { key: 'sn',       label: '#',       w: 18 },
  { key: 'product',  label: 'Product', w: 150 },
  { key: 'pack',     label: 'Pack',    w: 70 },
  { key: 'batch_no', label: 'Batch',   w: 50 },
  { key: 'expiry',   label: 'Exp',     w: 35 },
  { key: 'qty',      label: 'Qty',     w: 28, right: true },
  { key: 'mrp',      label: 'MRP',     w: 45, right: true },
  { key: 'ptr',      label: 'PTR',     w: 45, right: true },
  { key: 'value',    label: 'Value',   w: 55, right: true },
  { key: 'disc',     label: 'Disc',    w: 45, right: true },
  { key: 'taxable',  label: 'Taxable', w: 55, right: true },
  { key: 'gst_pct',  label: 'GST%',    w: 32, right: true },
  { key: 'gst_amt',  label: 'GST',     w: 48, right: true },
  { key: 'amount',   label: 'Amount',  w: 60, right: true },
]

// pdf-lib's standard fonts are WinAnsi — ₹ (U+20B9) and − (U+2212) are not in
// that encoding and drawText THROWS on them rather than dropping them. Every
// money label the backend sends starts with ₹, so without this the whole render
// fails. Same mapping is applied to the on-demand `bill-pdf` download.
function ansi(s: unknown): string {
  return String(s ?? '')
    .replace(/₹/g, 'Rs.')
    .replace(/[−–—]/g, '-')
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
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
  const pdf = await PDFDocument.create()
  const F = await pdf.embedFont(StandardFonts.Helvetica)
  const FB = await pdf.embedFont(StandardFonts.HelveticaBold)
  const ink = rgb(0.1, 0.1, 0.1), grey = rgb(0.45, 0.45, 0.45), line = rgb(0.8, 0.8, 0.8)
  const brand = rgb(0.05, 0.42, 0.24)

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

  const header = () => {
    y = H - M - 10
    txt('TAX INVOICE', M, y, 13, FB, brand)
    rtxt(inv.number, W - M, y, 10, FB)
    y -= 14
    txt(inv.seller?.name, M, y, 9, FB)
    rtxt('Date: ' + ansi(inv.date), W - M, y, 8, F, grey)
    y -= 11
    const sBits = [
      inv.seller?.address, inv.seller?.state,
      inv.seller?.gstin ? 'GSTIN: ' + inv.seller.gstin : null,
      inv.seller?.dl ? 'DL: ' + inv.seller.dl : null,
    ].filter(Boolean).join('  |  ')
    txt(clip(sBits, F, 7.5, W - 2 * M), M, y, 7.5, F, grey)
    y -= 14

    txt('Billed to:', M, y, 8, FB)
    txt(inv.buyer?.name, M + 45, y, 8, FB)
    y -= 10
    const bBits = [
      inv.buyer?.address, inv.buyer?.phone,
      inv.buyer?.gstin ? 'GSTIN: ' + inv.buyer.gstin : null,
      inv.buyer?.dl ? 'DL: ' + inv.buyer.dl : null,
    ].filter(Boolean).join('  |  ')
    txt(clip(bBits, F, 7.5, W - 2 * M), M, y, 7.5, F, grey)
    y -= 12

    if (inv.seller?.warning) { txt(inv.seller.warning, M, y, 7, FB, rgb(0.8, 0.2, 0.2)); y -= 11 }
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
    if (y < 120) { page = pdf.addPage([W, H]); header() }
    let x = M
    for (const c of COLS) {
      const v = L[c.key] ?? ''
      if (c.right) rtxt(v, x + c.w, y, 7); else txt(clip(v, F, 7, c.w - 4), x, y, 7)
      x += c.w
    }
    y -= 10
  }

  y -= 4; hr(y); y -= 14

  const RX = W - M, LX = W - M - 150
  const row = (label: string, value: unknown, bold = false, size = 8) => {
    txt(label, LX, y, size, bold ? FB : F, bold ? ink : grey)
    rtxt(value, RX, y, size, bold ? FB : F)
    y -= 11
  }
  row(ansi(tot.ptr_total_caption ?? 'Gross Total'), tot.ptr_total_label)
  row(ansi(tot.discount_label ?? 'Discount'), tot.discount_amount_label)
  row('Net Taxable', tot.taxable_label, true)
  row('CGST', tot.cgst_label)
  row('SGST', tot.sgst_label)
  if (tot.round_off_label) row('Round Off', tot.round_off_label)
  y -= 2
  page.drawLine({ start: { x: LX, y: y + 6 }, end: { x: RX, y: y + 6 }, thickness: 0.8, color: ink })
  y -= 4
  row('NET PAYABLE', tot.net_payable_label, true, 10)
  row('Less: Paid', tot.paid_label)
  row('BALANCE DUE', tot.remaining_label, true, 10)

  let gy = y + 88
  txt('GST Summary', M, gy, 8, FB); gy -= 11
  txt('Rate', M, gy, 7, FB); txt('Taxable', M + 45, gy, 7, FB)
  txt('CGST', M + 115, gy, 7, FB); txt('SGST', M + 175, gy, 7, FB)
  txt('Total', M + 235, gy, 7, FB)
  gy -= 10
  for (const g of (bill.gst_summary ?? []) as Record<string, string>[]) {
    txt(g.rate, M, gy, 7); txt(g.taxable, M + 45, gy, 7)
    txt(g.cgst, M + 115, gy, 7); txt(g.sgst, M + 175, gy, 7)
    txt(g.total, M + 235, gy, 7)
    gy -= 10
  }
  gy -= 4
  txt('Amount in words: ' + ansi(tot.in_words), M, gy, 7.5, FB)
  gy -= 16
  txt('E. & O.E.   |   Goods once sold will not be taken back.', M, gy, 6.5, F, grey)
  rtxt('For ' + ansi(inv.seller?.name), W - M, gy + 16, 8, F)
  rtxt('Authorised Signatory', W - M, gy, 7, F, grey)

  return await pdf.save()
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)
  if ((req.headers.get('x-notify-secret') ?? '') !== NOTIFY_SECRET)
    return json({ error: 'forbidden' }, 403)

  let jobId = ''
  try {
    const body = await req.json().catch(() => ({}))
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
