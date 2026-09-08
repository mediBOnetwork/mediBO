// audit-pdf — CMD #430: the owner's copy of a stock audit, as one PDF.
//
// A DUMB PRINTER, and deliberately the SAME printer as #416's CA pack: the
// payload shape is identical, so the audit report and the GST pack can never
// drift into two different layouts of the same table. Every heading, every
// rupee string, every row and the disclaimer arrive finished from
// pharmacy_audit_pdf_input(); this file decides nothing except where the ink
// goes.
//
// It never claims an audit opinion. The footer it prints is the backend's own
// sentence, which says plainly that this states what was counted — and carries
// the sealed log's entry number and hash so the numbers can be traced back to
// an append-only record.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1'
import fontkit from 'https://esm.sh/@pdf-lib/fontkit@1.1.1'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

const PW = 595, PH = 842, PM = 36

// ₹ is in every money string the backend sends, and pdf-lib's built-in fonts
// THROW on it rather than dropping it — so Noto Sans is embedded when it can be
// fetched, and ansi() degrades to "Rs." only when it cannot.
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

async function renderAudit(input: any): Promise<Uint8Array> {
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

  const nl = (n = 14) => { y -= n }
  const need = (n: number) => {
    if (y - n < PM + 24) { page = pdf.addPage([PW, PH]); y = PH - PM }
  }
  const txt = (s: unknown, x: number, size: number, font: any, color = ink) =>
    page.drawText(clip(String(s ?? ''), font, size, PW - x - PM), { x, y, size, font, color })
  const rtxt = (s: unknown, right: number, size: number, font: any, color = ink) => {
    const t = ansi(s)
    page.drawText(t, { x: right - font.widthOfTextAtSize(t, size), y, size, font, color })
  }
  const rule = () => {
    page.drawLine({ start: { x: PM, y: y + 4 }, end: { x: PW - PM, y: y + 4 },
                    thickness: 0.7, color: line })
  }

  // ── header ───────────────────────────────────────────────────────────────
  txt(input.title, PM, 18, FB, brand)
  rtxt(input.period_label, PW - PM, 12, FB, grey); nl(18)
  txt(input.shop_name, PM, 12, FB); nl(13)
  txt(input.gstin_line, PM, 9, F, grey); nl(16)
  rule(); nl(18)

  // ── the position, three numbers ──────────────────────────────────────────
  for (const s of (input.summary ?? [])) {
    txt(s.label, PM, 10, F, grey)
    rtxt(s.value, PW - PM, 11, FB)
    nl(15)
  }
  nl(6); rule(); nl(18)

  // ── every export block, printed as the table it already is ───────────────
  for (const b of (input.blocks ?? [])) {
    const cols: any[] = b.columns ?? []
    const rows: any[] = b.rows ?? []
    need(60)
    txt(b.title, PM, 11, FB, brand); nl(15)

    // Columns share the width in proportion to how wide their content runs:
    // a GSTIN needs room, a rate does not.
    const weights = cols.map((c: any) => (c.align === 'right' ? 1 : 1.9))
    const total = weights.reduce((a: number, w: number) => a + w, 0) || 1
    const width = PW - PM * 2
    const xs: number[] = []
    let acc = PM
    for (const w of weights) { xs.push(acc); acc += (w / total) * width }

    cols.forEach((c: any, i: number) => {
      const w = ((weights[i] / total) * width)
      if (c.align === 'right') rtxt(c.label, xs[i] + w - 4, 7.5, FB, grey)
      else txt(c.label, xs[i], 7.5, FB, grey)
    })
    nl(11)

    if (rows.length === 0) {
      txt('—', PM, 8.5, F, grey); nl(14)
    }
    for (const r of rows) {
      need(20)
      cols.forEach((c: any, i: number) => {
        const w = ((weights[i] / total) * width)
        const v = String(r[c.key] ?? '')
        if (c.align === 'right') rtxt(v, xs[i] + w - 4, 8.5, F)
        else page.drawText(clip(v, F, 8.5, w - 6), { x: xs[i], y, size: 8.5, font: F, color: ink })
      })
      nl(12)
    }
    nl(8)
  }

  // ── the honest footer. The backend's own sentence, never a friendlier one ─
  need(40); rule(); nl(14)
  const words = ansi(input.disclaimer ?? '').split(' ')
  let cur = ''
  for (const w of words) {
    const t = cur ? cur + ' ' + w : w
    if (F.widthOfTextAtSize(t, 7.5) > PW - PM * 2) { txt(cur, PM, 7.5, F, grey); nl(10); cur = w }
    else cur = t
  }
  if (cur) txt(cur, PM, 7.5, F, grey)

  return await pdf.save()
}

Deno.serve(async (req) => {
  let sessionId = ''
  try {
    const body = await req.json().catch(() => ({}))
    sessionId = String(body?.session_id ?? '')
    if (!sessionId) return json({ error: 'session_id required' }, 400)

    const { data: input, error: inErr } =
      await supabase.rpc('pharmacy_audit_pdf_input', { p_session_id: sessionId })
    if (inErr) throw new Error('pharmacy_audit_pdf_input: ' + inErr.message)
    if (!input?.ok) {
      await supabase.rpc('pharmacy_audit_pdf_report', {
        p_session_id: sessionId, p_ok: false,
        p_error: 'audit_input: ' + (input?.error ?? 'unknown'),
      }).catch(() => {})
      return json({ ok: false, reason: input?.error ?? 'no_input' })
    }

    const bytes = await renderAudit(input)
    const up = await supabase.storage.from(String(input.bucket))
      .upload(String(input.path), bytes,
              { contentType: 'application/pdf', upsert: true })
    if (up.error) throw new Error('upload: ' + up.error.message)

    const { data: rep } = await supabase.rpc('pharmacy_audit_pdf_report', {
      p_session_id: sessionId, p_ok: true, p_bucket: input.bucket,
      p_path: input.path, p_bytes: bytes.length,
    })
    return json({ ok: true, session_id: sessionId, path: input.path,
                  name: input.name, bytes: bytes.length, report: rep })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (sessionId) {
      await supabase.rpc('pharmacy_audit_pdf_report',
        { p_session_id: sessionId, p_ok: false, p_error: msg }).catch(() => {})
    }
    return json({ ok: false, error: msg }, 200)
  }
})
