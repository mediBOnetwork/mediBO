// CMD #420 — the pharmacy-to-pharmacy TAX INVOICE.
//
// The document that makes a dead-stock trade or an emergency borrow a legal
// sale rather than an informal favour: seller's GSTIN, BUYER's GSTIN, the batch
// and expiry that were disclosed, GST split CGST/SGST, and the near-expiry
// disclosure the buyer accepted printed on the face of it.
//
// Same three-part shape as #411's POS invoice and #415's khata statement —
// request -> draw -> report — and it computes NOTHING. Every rupee, every
// percentage, every column label and the column ORDER arrive finished from
// px_invoice_render_input(). If a number here is wrong, the bug is in SQL.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1'
import fontkit from 'https://esm.sh/@pdf-lib/fontkit@1.1.1'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

const PW = 595, PH = 842, PM = 36

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

function wrap(s: string, font: any, size: number, max: number): string[] {
  const words = ansi(s).split(/\s+/)
  const out: string[] = []
  let line = ''
  for (const w of words) {
    const t = line ? line + ' ' + w : w
    if (font.widthOfTextAtSize(t, size) > max && line) { out.push(line); line = w }
    else line = t
  }
  if (line) out.push(line)
  return out
}

async function render(inv: any): Promise<Uint8Array> {
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

  const page = pdf.addPage([PW, PH])
  let y = PH - PM
  const txt = (s: unknown, x: number, yy: number, size = 8.5, f = F, c = ink) =>
    page.drawText(ansi(s), { x, y: yy, size, font: f, color: c })
  const rtxt = (s: unknown, xr: number, yy: number, size = 8.5, f = F, c = ink) => {
    const t = ansi(s)
    page.drawText(t, { x: xr - f.widthOfTextAtSize(t, size), y: yy, size, font: f, color: c })
  }
  const hr = (yy: number) => page.drawLine({
    start: { x: PM, y: yy }, end: { x: PW - PM, y: yy }, thickness: 0.5, color: line })

  txt(inv.title ?? 'TAX INVOICE', PM, y, 14, FB, brand)
  y -= 20
  hr(y); y -= 14

  // BOTH parties, side by side. This is the whole legal point of the document:
  // two licensed establishments, each with a GSTIN.
  const colW = (PW - 2 * PM) / 2
  const party = (p: any, x: number) => {
    let yy = y
    txt(p?.heading ?? '', x, yy, 7.5, FB, grey); yy -= 12
    txt(clip(String(p?.name ?? ''), FB, 10, colW - 10), x, yy, 10, FB); yy -= 12
    for (const l of [p?.address, p?.phone, p?.gstin_label, p?.dl_label]) {
      if (!l) continue
      for (const ln of wrap(String(l), F, 8, colW - 10)) {
        txt(ln, x, yy, 8, F, grey); yy -= 10
      }
    }
    return yy
  }
  const ySeller = party(inv.seller, PM)
  const yBuyer = party(inv.buyer, PM + colW)
  y = Math.min(ySeller, yBuyer) - 4
  hr(y); y -= 14

  let col = 0
  for (const m of (Array.isArray(inv.meta) ? inv.meta : [])) {
    if (!m || !m.value) continue
    const x = PM + (col % 2) * colW
    txt(m.label ?? '', x, y, 7.5, FB, grey)
    txt(m.value, x + 62, y, 8.5)
    if (col % 2 === 1) y -= 12
    col++
  }
  if (col % 2 === 1) y -= 12
  y -= 6; hr(y); y -= 14

  // px deal:    130+46+40+30+52+62+38+65 = 463 <= 523 printable
  // settlement: 294+50+52+62+65          = 523 <= 523 printable
  // CHANGE #695 — a key with no width here silently falls back to 50px, which
  // is fine for a code and wrong for a sentence. The settlement line is ONE
  // description of a service and it gets the whole slack the narrow columns
  // leave: at 200 it clipped mid-period ("...(27 Aug – 02"), which on a tax
  // document reads as a different supply than the one that was billed.
  const WCOL: Record<string, number> = {
    product: 130, batch: 46, expiry: 40, qty: 30, rate: 52,
    taxable: 62, gst: 38, amount: 65,
    desc: 294, sac: 50,
  }
  const RIGHT = new Set(['qty', 'rate', 'taxable', 'gst', 'amount'])
  const cols = (Array.isArray(inv.columns) ? inv.columns : [])
    .filter((c: any) => c && typeof c.key === 'string')
    .map((c: any) => ({
      key: c.key, label: String(c.label ?? ''), w: WCOL[c.key] ?? 50,
      right: c.align ? c.align === 'right' : RIGHT.has(c.key),
    }))

  let x = PM
  for (const c of cols) {
    if (c.right) rtxt(c.label, x + c.w, y, 7.5, FB, grey)
    else txt(clip(c.label, FB, 7.5, c.w - 3), x, y, 7.5, FB, grey)
    x += c.w
  }
  y -= 4; hr(y); y -= 11

  for (const row of (Array.isArray(inv.lines) ? inv.lines : [])) {
    x = PM
    for (const c of cols) {
      const v = row[c.key]
      if (c.right) rtxt(v ?? '', x + c.w, y, 8)
      else txt(clip(String(v ?? ''), F, 8, c.w - 3), x, y, 8)
      x += c.w
    }
    y -= 12
  }
  y -= 2; hr(y); y -= 16

  for (const t of (Array.isArray(inv.totals) ? inv.totals : [])) {
    if (!t) continue
    txt(t.label ?? '', PW - PM - 190, y, 8.5, F, grey)
    rtxt(t.value ?? '', PW - PM, y, 8.5)
    y -= 12
  }
  hr(y + 8); y -= 4
  const net = inv.net ?? {}
  txt(net.label ?? '', PW - PM - 190, y - 4, 10.5, FB)
  rtxt(net.value ?? '', PW - PM, y - 4, 11.5, FB, brand)
  y -= 26

  // The disclosure, on the face of the invoice - what the buyer was told about
  // batch and expiry, printed where it cannot be argued about later.
  if (inv.disclosure) {
    for (const ln of wrap(String(inv.disclosure), F, 8, PW - 2 * PM)) {
      txt(ln, PM, y, 8, F, ink); y -= 10
    }
    y -= 6
  }

  // CHANGE #695 — the two footer halves share one line, so the left one is
  // CLIPPED to the room the right one leaves. They used to be drawn at fixed
  // ends and a long terms string ran straight through the note ("...paid on
  // the due dateThis is a computer-generated tax invoice."), which is the kind
  // of overlap nobody notices until it is on a document sent to a CA.
  const foot = inv.footer ?? {}
  hr(y); y -= 12
  const noteW = foot.note ? F.widthOfTextAtSize(ansi(foot.note), 7.5) : 0
  if (foot.items) {
    txt(clip(String(foot.items), F, 7.5, PW - 2 * PM - noteW - 12), PM, y, 7.5, F, grey)
  }
  if (foot.note) rtxt(foot.note, PW - PM, y, 7.5, F, grey)

  return await pdf.save()
}

// CHANGE #695 — the renderer above is now shared.
//
// It already draws a GST tax invoice and computes NOTHING: parties, meta rows,
// columns, lines, totals and net all arrive finished from SQL. The settlement
// tax invoice is the same document with a different source, so it reuses this
// drawing code rather than a second copy of it — one place for a layout bug,
// one place for the font fallback, one place for the rupee glyph.
//
// A source names the pair of RPCs that feed and answer it. 'px_deal' is the
// default and its request body is unchanged, so #420's caller keeps working
// exactly as it did.
type Source = {
  idKey: string                              // body key carrying the id
  input: string                              // render-input RPC
  report: string                             // report RPC
  idArg: string                              // the id argument both take
}
const SOURCES: Record<string, Source> = {
  px_deal: {
    idKey: 'deal_id',
    input: 'px_invoice_render_input',
    report: 'px_invoice_report',
    idArg: 'p_deal_id',
  },
  settlement_invoice: {
    idKey: 'invoice_id',
    input: 'settlement_invoice_render_input',
    report: 'settlement_invoice_report',
    idArg: 'p_invoice_id',
  },
}

Deno.serve(async (req) => {
  let id = ''
  let src: Source = SOURCES.px_deal
  try {
    const body = await req.json().catch(() => ({}))
    const key = String(body?.source ?? 'px_deal')
    if (!SOURCES[key]) return json({ error: 'unknown source: ' + key }, 400)
    src = SOURCES[key]
    id = String(body?.[src.idKey] ?? '')
    if (!id) return json({ error: src.idKey + ' required' }, 400)

    const { data: input, error: inErr } = await supabase
      .rpc(src.input, { [src.idArg]: id })
    if (inErr) throw new Error(src.input + ': ' + inErr.message)
    if (!input?.ok) {
      await supabase.rpc(src.report, {
        [src.idArg]: id, p_ok: false,
        p_error: 'render_input: ' + (input?.error ?? 'unknown'),
      }).catch(() => {})
      return json({ ok: false, reason: input?.error ?? 'no_input' })
    }

    const bytes = await render(input.invoice)
    const up = await supabase.storage.from(String(input.bucket))
      .upload(String(input.path), bytes,
              { contentType: 'application/pdf', upsert: true })
    if (up.error) throw new Error('upload: ' + up.error.message)

    const { data: rep } = await supabase.rpc(src.report, {
      [src.idArg]: id, p_ok: true, p_bucket: input.bucket,
      p_path: input.path, p_name: input.file_name, p_bytes: bytes.length,
    })
    return json({ ok: true, [src.idKey]: id, path: input.path,
                  name: input.file_name, bytes: bytes.length, report: rep })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (id) {
      await supabase.rpc(src.report,
        { [src.idArg]: id, p_ok: false, p_error: msg }).catch(() => {})
    }
    return json({ ok: false, error: msg }, 200)
  }
})
