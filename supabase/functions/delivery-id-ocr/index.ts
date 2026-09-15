import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

// Scans an Aadhaar card or driving licence and returns structured fields so the
// delivery-partner registration form fills itself. Deliberately SEPARATE from
// gemini-ocr (v42) so the supplier/company import pipeline cannot be affected.
//
// CMD #453 (feature_gaps 98): this file was deployed but had never been
// committed, so the rider onboarding OCR could not be reviewed, rolled back or
// redeployed from git. Recovered from the live deployment (version 5) and
// pinned to the GLOBAL Vertex endpoint only — the recovered copy carried a
// us-central1 fallback, which the absolute GEMINI RULE does not allow; every
// other OCR path (gemini-ocr) is global-only.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const MODEL = 'gemini-3.5-flash'
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const jitter = (b: number) => b + Math.floor(Math.random() * 400)
const RETRYABLE = new Set([429, 500, 502, 503, 504])

function endpoint(projectId: string): string {
  return `https://aiplatform.googleapis.com/v1/projects/${projectId}/locations/global` +
    `/publishers/google/models/${MODEL}:generateContent`
}

const ID_PROMPT = `You are reading an Indian government identity document: either an AADHAAR card or a DRIVING LICENCE.

Return STRICT JSON only - no markdown, no code fences, no commentary. Exactly this shape:

{
  "doc_type": "aadhaar|dl|unknown",
  "name": "",
  "id_number": "",
  "dob": "",
  "gender": "",
  "address": "",
  "city": "",
  "state": "",
  "pincode": "",
  "valid_till": "",
  "vehicle_classes": "",
  "confidence": "high|medium|low"
}

RULES - copy what is printed. You are a camera, not a database.
  - Never invent, expand, correct or complete a value. If a field is not printed, return "".
  - Never use world knowledge to fill anything in.
  - If the image is NOT an Aadhaar card or a driving licence, return {"doc_type":"unknown"} and nothing else.

FIELD BY FIELD:
  doc_type  - "aadhaar" if it shows a 12-digit Aadhaar/UIDAI number, "dl" if it is a driving licence.
  name      - the holder's full name exactly as printed. Not the father's/guardian's name.
  id_number - Aadhaar: the 12 digits, no spaces. DL: the licence number exactly as printed
              including slashes and letters, e.g. CG04 20110001234.
  dob       - date of birth as printed, normalised to DD-MM-YYYY.
  gender    - Male / Female / Other, or "".
  address   - the full address block on ONE line, commas kept.
  city, state, pincode - split out of the address if printed. pincode is 6 digits or "".
  valid_till - driving licence validity date as DD-MM-YYYY, or "" for Aadhaar.
  vehicle_classes - driving licence vehicle classes e.g. "MCWG, LMV", or "" for Aadhaar.

Read the WHOLE image including small print and the reverse-side address block if visible.`

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
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const saJson = Deno.env.get('GCP_SA_KEY')
    if (!saJson) throw new Error('GCP_SA_KEY secret not set')
    const projectId = (JSON.parse(saJson) as Record<string, string>).project_id
    if (!projectId) throw new Error('project_id missing from GCP_SA_KEY')

    const body = await req.json() as { image_base64?: string; mime_type?: string }
    const image_base64 = body.image_base64 ?? ''
    const mime_type = body.mime_type ?? 'image/jpeg'
    if (!image_base64) {
      return new Response(JSON.stringify({ ok: false, error: 'image_base64 required' }),
        { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    const token = await getAccessToken(saJson)
    const raw = await callVertex(projectId, token, {
      contents: [{ role: 'user', parts: [
        { inlineData: { mimeType: mime_type, data: image_base64 } },
        { text: ID_PROMPT },
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

    const docType = String(parsed.doc_type ?? 'unknown')
    if (docType === 'unknown' || !String(parsed.name ?? '').trim()) {
      return new Response(JSON.stringify({
        ok: false, error: 'not_an_id',
        title: 'Not an ID document',
        message: 'Point the camera at an Aadhaar card or a driving licence.',
      }), { headers: { ...cors, 'Content-Type': 'application/json' } })
    }

    // shaped so the client can hand it straight to delivery_partner_register /
    // agency_add_partner as ocr_payload, with the form prefilled from `prefill`
    return new Response(JSON.stringify({
      ok: true,
      doc_type: docType,
      doc_type_label: docType === 'aadhaar' ? 'Aadhaar card' : 'Driving licence',
      confidence: String(parsed.confidence ?? ''),
      prefill: {
        full_name: String(parsed.name ?? '').trim(),
        id_doc_type: docType,
        id_doc_number: String(parsed.id_number ?? '').trim(),
        address: String(parsed.address ?? '').trim(),
        city: String(parsed.city ?? '').trim(),
        state: String(parsed.state ?? '').trim(),
        pincode: String(parsed.pincode ?? '').trim(),
      },
      extra: {
        dob: String(parsed.dob ?? ''),
        gender: String(parsed.gender ?? ''),
        valid_till: String(parsed.valid_till ?? ''),
        vehicle_classes: String(parsed.vehicle_classes ?? ''),
      },
      ocr_payload: parsed,
    }), { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[delivery-id-ocr] FAILED:', msg)
    return new Response(JSON.stringify({ ok: false, error: msg }),
      { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } })
  }
})
