// CMD #426 — the counter poster.
//
// A pharmacy's zero-setup online presence: one A4 sheet with their own name
// and a QR code that opens their /near listing. It is the cheapest possible
// bridge between the shop counter and the consumer search — print it, tape it
// to the till, and a walk-in can check availability before they walk in.
//
// Same three-part shape as #420's px-invoice and #411's POS invoice —
// request -> draw -> report — and it computes NOTHING. The name, the area,
// the headline, the badge and the URL the QR encodes all arrive finished from
// near_poster_job(); this file only draws them. No price, no quantity and no
// trade data reaches it, because the RPC never puts any in the payload.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { PDFDocument, StandardFonts, rgb } from 'https://esm.sh/pdf-lib@1.17.1'
import QRCode from 'https://esm.sh/qrcode@1.5.3'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

const PW = 595, PH = 842        // A4 at 72 dpi
const BRAND = rgb(0.106, 0.478, 0.263)   // #1B7A43 — the one brand green
const INK   = rgb(0.067, 0.094, 0.153)   // #111827
const MUTED = rgb(0.420, 0.447, 0.502)   // #6B7280

// Centre a line of text without measuring it twice at the call site.
function centre(page: any, text: string, font: any, size: number, y: number, color: any) {
  const w = font.widthOfTextAtSize(text, size)
  page.drawText(text, { x: (PW - w) / 2, y, size, font, color })
  return w
}

// Shrink a long pharmacy name until it fits the sheet rather than letting it
// run off the edge — a 40-character shop name is normal in Chhattisgarh.
function fitSize(text: string, font: any, max: number, width: number): number {
  let s = max
  while (s > 14 && font.widthOfTextAtSize(text, s) > width) s -= 1
  return s
}

async function render(job: Record<string, unknown>): Promise<Uint8Array> {
  const pdf = await PDFDocument.create()
  const F  = await pdf.embedFont(StandardFonts.Helvetica)
  const FB = await pdf.embedFont(StandardFonts.HelveticaBold)
  const page = pdf.addPage([PW, PH])

  const name = String(job.name ?? '')
  const area = String(job.area ?? '')
  const url  = String(job.url ?? '')

  // A brand band across the head of the sheet, so it reads as a poster from
  // across a shop rather than as a printed form.
  page.drawRectangle({ x: 0, y: PH - 96, width: PW, height: 96, color: BRAND })
  centre(page, 'mediBO', FB, 30, PH - 62, rgb(1, 1, 1))

  const nameSize = fitSize(name, FB, 30, PW - 96)
  centre(page, name, FB, nameSize, PH - 168, INK)
  if (area) centre(page, area, F, 14, PH - 194, MUTED)

  centre(page, String(job.headline ?? ''), FB, 19, PH - 262, INK)

  // ── the QR, drawn as vectors so it stays crisp at any print size ─────────
  const qr = QRCode.create(url, { errorCorrectionLevel: 'M' })
  const mods: number = qr.modules.size
  const bits: Uint8Array = qr.modules.data
  const QS = 320                              // drawn size in points
  const cell = QS / mods
  const qx = (PW - QS) / 2
  const qy = PH - 262 - 40 - QS

  // Quiet zone. A QR with no white margin does not scan.
  page.drawRectangle({ x: qx - 16, y: qy - 16, width: QS + 32, height: QS + 32,
                       color: rgb(1, 1, 1), borderColor: rgb(0.898, 0.906, 0.922),
                       borderWidth: 1 })
  for (let r = 0; r < mods; r++) {
    for (let c = 0; c < mods; c++) {
      if (!bits[r * mods + c]) continue
      page.drawRectangle({
        x: qx + c * cell,
        y: qy + QS - (r + 1) * cell,
        width: cell, height: cell, color: INK,
      })
    }
  }

  centre(page, String(job.badge ?? ''), FB, 13, qy - 44, BRAND)
  centre(page, url, F, 11, qy - 66, MUTED)

  // The honesty line belongs on the poster too — the whole product rests on
  // the consumer understanding that this is an estimate, not a reservation.
  const foot = String(job.footer ?? '')
  if (foot) {
    const words = foot.split(' ')
    const lines: string[] = []
    let line = ''
    for (const w of words) {
      const t = line ? line + ' ' + w : w
      if (F.widthOfTextAtSize(t, 10) > PW - 120) { lines.push(line); line = w } else line = t
    }
    if (line) lines.push(line)
    lines.slice(0, 3).forEach((l, i) => centre(page, l, F, 10, 78 - i * 14, MUTED))
  }

  return await pdf.save()
}

Deno.serve(async (req) => {
  let token = ''
  try {
    const body = await req.json().catch(() => ({}))
    token = String(body?.token ?? '')
    if (!token) return json({ error: 'token required' }, 400)

    const { data: job, error: jErr } = await supabase
      .rpc('near_poster_job', { p_token: token })
    if (jErr) throw new Error('near_poster_job: ' + jErr.message)
    if (!job?.ok) {
      await supabase.rpc('near_poster_report', {
        p_token: token, p_error: 'job: ' + (job?.error ?? 'unknown'),
      }).catch(() => {})
      return json({ ok: false, reason: job?.error ?? 'no_job' })
    }

    const bytes = await render(job)
    const up = await supabase.storage.from(String(job.bucket))
      .upload(String(job.path), bytes,
              { contentType: 'application/pdf', upsert: true })
    if (up.error) throw new Error('upload: ' + up.error.message)

    const { data: rep } = await supabase.rpc('near_poster_report', {
      p_token: token, p_bucket: job.bucket, p_path: job.path, p_bytes: bytes.length,
    })
    return json({ ok: true, token, path: job.path, bytes: bytes.length, report: rep })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    if (token) {
      await supabase.rpc('near_poster_report', { p_token: token, p_error: msg }).catch(() => {})
    }
    return json({ ok: false, error: msg }, 200)
  }
})
