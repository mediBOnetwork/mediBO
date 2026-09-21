import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

// CMD #2128 — "Scan a licence" on registration step 3.
//
// One photo of a Drug Licence (Form 20B/21B) or a GST certificate, and the
// numbers the registration form asks for come back. It is deliberately
// SEPARATE from gemini-ocr (the supplier/company import pipeline) and from
// kyc-verify (which is queue-driven and writes its own verdict): this one is
// synchronous, reads nothing from the database and writes nothing to it. The
// fields it returns are handed to custreg_licence_scan_review(), which is the
// only place they become form fields.
//
// Same model, same endpoint, same credential as every other OCR path in
// mediBO — gemini-3.5-flash on the Vertex GLOBAL endpoint, GCP_SA_KEY auth.

// CMD #2141 (QA round) — THE real OCR bug. Since CMD #2100 the web app sends
// x-medibo-flavor on every request; this allow-list did not name it, so the
// browser stopped after the OPTIONS preflight and the POST never came (6
// OPTIONS, 0 POST in a day of logs). The preflight now echoes whatever
// headers the browser asks to send, and the fixed list names the app's own.
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-medibo-flavor',
}
const preflight = (req: Request) => ({
  ...cors,
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers':
    req.headers.get('Access-Control-Request-Headers') || cors['Access-Control-Allow-Headers'],
})
const MODEL = 'gemini-3.5-flash'
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const jitter = (b: number) => b + Math.floor(Math.random() * 400)
const RETRYABLE = new Set([429, 500, 502, 503, 504])

function endpoint(projectId: string): string {
  return `https://aiplatform.googleapis.com/v1/projects/${projectId}/locations/global` +
    `/publishers/google/models/${MODEL}:generateContent`
}

// VERBATIM-ONLY CONTRACT — the same one kyc-verify carries. A licence number
// that is "corrected" into a plausible one is worse than an empty field: an
// empty field is handled, an invented one is filed.
const LICENCE_PROMPT = `You are reading ONE Indian pharmacy document: a DRUG LICENCE (Form 20, 21,
20B, 21B or a state equivalent), a GST REGISTRATION CERTIFICATE (Form GST REG-06), a PAN CARD,
an FSSAI LICENCE / REGISTRATION, or another shop licence or certificate.

Return STRICT JSON only - no markdown, no code fences, no commentary. Exactly this shape:

{
  "doc_type": "drug_licence|gst|pan|fssai|other|unknown",
  "licence_20b": "",
  "licence_21b": "",
  "licence_number": "",
  "licensee_name": "",
  "valid_from": "",
  "valid_to": "",
  "gstin": "",
  "legal_name": "",
  "pan": "",
  "fssai": "",
  "document_number": "",
  "name": "",
  "confidence": "high|medium|low"
}

RULES - copy what is printed. You are a camera, not a database.
  - Never invent, expand, correct, complete or reformat a value. If a field is not printed, return "".
  - Never substitute a parent, group, acquirer or successor company.
  - Never use world knowledge to fill anything in.
  - If the image is not a document at all, return {"doc_type":"unknown"} and nothing else.

FIELD BY FIELD:
  doc_type       - "drug_licence" for a Form 20/21/20B/21B licence, "gst" for a GST REG-06 certificate.
  licence_20b    - the licence number printed against Form 20B / Form 20, verbatim, separators kept.
  licence_21b    - the licence number printed against Form 21B / Form 21, verbatim, separators kept.
  licence_number - the licence number when the form is NOT named on the paper. Otherwise "".
  licensee_name  - the firm or person the licence is issued to, verbatim.
  valid_from / valid_to - printed validity dates, normalised to yyyy-mm-dd, or "".
  gstin          - the 15-character GSTIN exactly as printed, or "".
  legal_name     - the GST "Legal Name" field, verbatim, or "".
  pan            - the 10-character PAN exactly as printed on a PAN card, or "".
  fssai          - the 14-digit FSSAI licence / registration number exactly as printed, or "".
  document_number- for any OTHER licence or certificate, its main number verbatim, or "".
  name           - the person or firm the PAN card / FSSAI licence / other paper is issued to, verbatim.

A single paper can carry BOTH a 20B and a 21B number - read the whole page and fill both.
A number that itself names its form (RLF20..., RLF21..., 20B/..., 21B/..., "Form 20" / "Form 21")
goes under licence_20b (Form 20/20B) or licence_21b (Form 21/21B), verbatim.`

async function getAccessToken(saJson: string): Promise<string> {
  const sa = JSON.parse(saJson) as Record<string, string>
  const now = Math.floor(Date.now() / 1000)
  const b64url = (d: string) => btoa(d).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const payload = b64url(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/cloud-platform',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now, exp: now + 3600,
  }))
  const sigInput = `${header}.${payload}`
  const keyPem = sa.private_key
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '')
  const keyBytes = Uint8Array.from(atob(keyPem), (c) => c.charCodeAt(0))
  const privateKey = await crypto.subtle.importKey(
    'pkcs8', keyBytes, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', privateKey, new TextEncoder().encode(sigInput))
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const jwt = `${sigInput}.${sigB64}`

  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt,
    }),
  })
  if (!r.ok) throw new Error(`token ${r.status}: ${(await r.text()).slice(0, 200)}`)
  const td = await r.json() as { access_token?: string }
  if (!td.access_token) throw new Error('no access_token')
  return td.access_token
}

async function callVertex(projectId: string, token: string, payload: unknown): Promise<string> {
  let lastErr = ''
  for (let attempt = 1; attempt <= 3; attempt++) {
    let res: Response
    try {
      const ctrl = new AbortController()
      const t = setTimeout(() => ctrl.abort(), 60_000)
      try {
        res = await fetch(endpoint(projectId), {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
          body: JSON.stringify(payload), signal: ctrl.signal,
        })
      } finally { clearTimeout(t) }
    } catch (e) {
      lastErr = `network: ${String((e as Error)?.message || e)}`
      if (attempt < 3) { await sleep(jitter(700)); continue }
      break
    }
    if (!res.ok) {
      lastErr = `vertex ${res.status}: ${(await res.text()).slice(0, 200)}`
      if (RETRYABLE.has(res.status) && attempt < 3) { await sleep(jitter(800 * attempt)); continue }
      break
    }
    const data = await res.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
    }
    const text = data?.candidates?.[0]?.content?.parts?.[0]?.text ?? ''
    if (text) return text
    lastErr = 'empty'
    if (attempt < 3) { await sleep(jitter(700)); continue }
  }
  throw new Error(lastErr || 'vertex_failed')
}

const strip = (t: string) => t.replace(/```json/gi, '').replace(/```/g, '').trim()

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: preflight(req) })
  try {
    const saJson = Deno.env.get('GCP_SA_KEY')
    if (!saJson) throw new Error('GCP_SA_KEY secret not set')
    const projectId = (JSON.parse(saJson) as Record<string, string>).project_id
    if (!projectId) throw new Error('project_id missing from GCP_SA_KEY')

    // CMD #2135 — every Documents upload is read by itself; `kind` is the row
    // it belongs to (dl_20b, gst, pan …), kept for the logs only:
    // the prompt reads whatever is printed and the backend maps it per kind.
    const body = await req.json() as {
      image_base64?: string; mime_type?: string; kind?: string; bucket?: string; path?: string
    }
    let image_base64 = body.image_base64 ?? ''
    let mime_type = body.mime_type ?? 'image/jpeg'
    // CMD #2141 — the paper is already in storage by the time it is read, so
    // the app sends its bucket + path and the file is fetched HERE with the
    // caller's own token — storage policies still decide who may read it, and
    // the phone never re-sends a multi-megabyte photo. (The missing POSTs were
    // the CORS preflight above, not the body size.)
    if (!image_base64 && body.bucket && body.path) {
      const base = Deno.env.get('SUPABASE_URL') ?? ''
      const anon = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
      const auth = req.headers.get('Authorization') ?? `Bearer ${anon}`
      const path = body.path.split('/').map(encodeURIComponent).join('/')
      const obj = await fetch(`${base}/storage/v1/object/authenticated/${encodeURIComponent(body.bucket)}/${path}`,
        { headers: { Authorization: auth, apikey: anon } })
      if (!obj.ok) {
        return new Response(JSON.stringify({ ok: false, error: `storage ${obj.status}`, fields: {} }),
          { headers: { ...cors, 'Content-Type': 'application/json' } })
      }
      const ct = (obj.headers.get('content-type') ?? '').split(';')[0].trim()
      if (ct === 'application/pdf' || ct.startsWith('image/')) mime_type = ct
      const bytes = new Uint8Array(await obj.arrayBuffer())
      let bin = ''
      for (let i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
      }
      image_base64 = btoa(bin)
    }
    if (!image_base64) {
      return new Response(JSON.stringify({ ok: false, error: 'image_base64 required' }),
        { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const token = await getAccessToken(saJson)
    const raw = await callVertex(projectId, token, {
      contents: [{ role: 'user', parts: [
        { inlineData: { mimeType: mime_type, data: image_base64 } },
        { text: LICENCE_PROMPT },
      ] }],
      generationConfig: {
        temperature: 0, maxOutputTokens: 4096,
        thinkingConfig: { thinkingLevel: 'low' },
      },
    })

    let parsed: Record<string, unknown> = {}
    try { parsed = JSON.parse(strip(raw)) } catch {
      return new Response(JSON.stringify({ ok: false, error: 'unparseable', raw: raw.slice(0, 400) }),
        { headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const s = (k: string) => String(parsed[k] ?? '').trim()
    const docType = s('doc_type') || 'unknown'
    const anyField = ['licence_20b', 'licence_21b', 'licence_number', 'gstin', 'pan', 'fssai',
      'document_number'].some((k) => s(k) !== '')
    if (docType === 'unknown' || !anyField) {
      // No sentence is composed here — the caller prints the backend's own
      // "could not read that photo" copy from custreg_licence_scan_review().
      return new Response(JSON.stringify({ ok: false, error: 'not_a_licence', fields: {} }),
        { headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    // Shaped for custreg_licence_scan_review(p_fields) and custreg_doc_read_save(p_ocr).
    return new Response(JSON.stringify({
      ok: true,
      fields: {
        doc_type: docType,
        licence_20b: s('licence_20b'),
        licence_21b: s('licence_21b'),
        licence_number: s('licence_number'),
        valid_from: s('valid_from'),
        valid_to: s('valid_to'),
        gstin: s('gstin'),
        licensee_name: s('licensee_name'),
        legal_name: s('legal_name'),
        pan: s('pan'),
        fssai: s('fssai'),
        document_number: s('document_number'),
        name: s('name'),
        confidence: s('confidence'),
      },
      ocr_payload: parsed,
    }), { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[licence-ocr] FAILED:', msg)
    return new Response(JSON.stringify({ ok: false, error: msg }),
      { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } })
  }
})
