// CMD #418 — rx-ocr: read a prescription photo, and read NOTHING into it.
//
// This is `gemini-ocr`'s pattern, copied deliberately rather than adapted:
// gemini-3.5-flash on the Vertex AI GLOBAL endpoint, thinkingLevel 'low',
// GCP_SA_KEY service-account auth, temperature 0. No other model, no other
// endpoint, no API-key auth. (CLAUDE.md GEMINI RULE.)
//
// WHAT MAKES A PRESCRIPTION DIFFERENT FROM A COMPANY CARD
// The verbatim contract is the same contract, and here it is a safety property
// rather than a data-quality one. A model that "helpfully" resolves a doctor's
// scrawl into the drug it guesses was meant is how a patient is handed the
// wrong medicine. So an unreadable line comes back readable:false with the
// characters that COULD be made out — never a name that was inferred, never a
// nearest-match from world knowledge, never a correction of a misspelling.
//
// It is also why this function is told NOTHING about the pharmacy's stock. The
// matching happens afterwards, in SQL (`_c418_match_line`). A model that knew
// what was on the shelf could be steered into recognising it; a model that has
// never heard of the shelf cannot.
//
// Flow: rx_scan_read_input(scan_id) → download from the private rx-scans
// bucket with the service key → Vertex → rx_scan_report(scan_id, lines).
// Both of those RPCs are service_role-only; nothing here is reachable from a
// browser except through this function's own CORS door.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL = 'gemini-3.5-flash'

// The camera contract, in the words a prescription needs.
const RX_PROMPT = `This image is a doctor's prescription from an Indian clinic.

PURE EXTRACTION CONTRACT — read before anything else:
Your ONLY job is to copy what is written. You are a camera, not a pharmacist and
not a database.
FORBIDDEN — do any of these and the output is wrong and dangerous:
  ✗ Guessing a drug name from partly legible handwriting
  ✗ Correcting a spelling ("Azithral" stays "Azithral", "Azithrl" stays "Azithrl")
  ✗ Expanding or substituting a brand for its salt, or a salt for a brand
  ✗ Adding a medicine that is implied by the diagnosis but not written
  ✗ Adding a strength, dose or duration that is not written
  ✗ Using any world knowledge about what is usually prescribed together
CORRECT: copy the characters. If a line cannot be read, say so.

Return STRICT JSON only — no markdown, no prose:
{"lines":[{
  "seen_text":"the medicine name exactly as written",
  "seen_strength":"strength exactly as written, or null",
  "seen_dose":"dose/frequency exactly as written (1-0-1, BD, TDS…), or null",
  "seen_duration":"duration exactly as written (5 days, 1 week…), or null",
  "readable":true,
  "confidence":"high|medium|low",
  "qty_guess":null,
  "qty_basis":"how the quantity follows from dose x duration, or null"
}],
"patient_name":"exactly as written, or null",
"doctor_name":"exactly as written, or null"}

RULES:
1. One entry per prescribed line. Never merge two lines. Never split one.
2. A line you cannot read: readable=false, confidence="low", and seen_text = the
   characters you CAN make out (or "?" if none). NEVER a guessed name.
3. qty_guess: only when dose AND duration are both written. Multiply them and
   put the arithmetic in qty_basis (e.g. "1-0-1 x 5 days = 10"). If either is
   missing, qty_guess is null and qty_basis is null — do not estimate.
4. confidence is about LEGIBILITY, not about whether the drug exists.
5. Ignore letterhead, diagnosis, advice and follow-up dates. Medicines only.`

async function getAccessToken(saJson: string): Promise<string> {
  const sa = JSON.parse(saJson) as Record<string, string>
  const now = Math.floor(Date.now() / 1000)

  const encodeB64url = (data: string) =>
    btoa(data).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')

  const header = encodeB64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const payload = encodeB64url(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/cloud-platform',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }))

  const sigInput = `${header}.${payload}`
  const keyPem = sa.private_key
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '')
  const keyBytes = Uint8Array.from(atob(keyPem), (c) => c.charCodeAt(0))

  const privateKey = await crypto.subtle.importKey(
    'pkcs8', keyBytes,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  )
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', privateKey, new TextEncoder().encode(sigInput),
  )
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')

  const tokenResp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: sigInput + '.' + sigB64,
    }),
  })
  if (!tokenResp.ok) throw new Error(`Token exchange failed: ${await tokenResp.text()}`)
  const td = await tokenResp.json() as { access_token?: string }
  if (!td.access_token) throw new Error('No access_token in response')
  return td.access_token
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

async function rpc(fn: string, body: unknown): Promise<unknown> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'apikey': SERVICE_KEY,
      'Authorization': `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  })
  if (!r.ok) throw new Error(`${fn} failed ${r.status}: ${await r.text()}`)
  return await r.json()
}

/** The model is told to return strict JSON; a fenced block is still cheap to survive. */
function parseLines(text: string): Record<string, unknown> {
  const cleaned = text.trim()
    .replace(/^```(?:json)?/i, '').replace(/```$/, '').trim()
  const start = cleaned.indexOf('{')
  const end = cleaned.lastIndexOf('}')
  if (start < 0 || end <= start) throw new Error('model returned no JSON object')
  return JSON.parse(cleaned.slice(start, end + 1)) as Record<string, unknown>
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  const started = Date.now()
  let scanId = ''
  try {
    const body = await req.json() as { scan_id?: string; image_base64?: string }
    scanId = (body.scan_id ?? '').trim()
    if (!scanId) throw new Error('scan_id required')

    const saJson = Deno.env.get('GCP_SA_KEY')
    if (!saJson) throw new Error('GCP_SA_KEY secret not set')
    const projectId = (JSON.parse(saJson) as Record<string, string>).project_id
    if (!projectId) throw new Error('project_id missing from GCP_SA_KEY')

    // Where the photo lives. The BACKEND owns that answer; a caller cannot
    // point this function at another shop's folder.
    const input = await rpc('rx_scan_read_input', { p_scan_id: scanId }) as {
      ok?: boolean; bucket?: string; path?: string; mime?: string
    }
    if (!input?.ok || !input.path) throw new Error('prescription photo not found')

    let b64 = body.image_base64 ?? ''
    if (!b64) {
      const obj = await fetch(
        `${SUPABASE_URL}/storage/v1/object/${input.bucket}/${input.path}`,
        { headers: { 'Authorization': `Bearer ${SERVICE_KEY}`, 'apikey': SERVICE_KEY } },
      )
      if (!obj.ok) throw new Error(`photo download failed ${obj.status}`)
      const bytes = new Uint8Array(await obj.arrayBuffer())
      let bin = ''
      for (let i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
      }
      b64 = btoa(bin)
    }

    const accessToken = await getAccessToken(saJson)
    const endpoint =
      `https://aiplatform.googleapis.com/v1/projects/${projectId}/locations/global` +
      `/publishers/google/models/${MODEL}:generateContent`

    const res = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${accessToken}`,
      },
      body: JSON.stringify({
        contents: [{
          role: 'user',
          parts: [
            { inlineData: { mimeType: input.mime ?? 'image/jpeg', data: b64 } },
            { text: RX_PROMPT },
          ],
        }],
        generationConfig: {
          temperature: 0,
          maxOutputTokens: 8192,
          thinkingConfig: { thinkingLevel: 'low' },
        },
      }),
    })
    if (!res.ok) throw new Error(`Vertex AI error ${res.status}: ${await res.text()}`)

    const data = await res.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
    }
    const text = data.candidates?.[0]?.content?.parts?.[0]?.text ?? ''
    const parsed = parseLines(text)
    const lines = Array.isArray(parsed.lines) ? parsed.lines : []

    // SQL does the matching. This function hands over what was READ and stops.
    const reported = await rpc('rx_scan_report', {
      p_scan_id: scanId,
      p_ok: true,
      p_model: MODEL,
      p_lines: lines,
      p_raw: parsed,
      p_ms: Date.now() - started,
    })

    return new Response(JSON.stringify({ ok: true, scan_id: scanId, reported }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    // A failure is RECORDED, never swallowed: the counter screen shows the
    // backend's own "take it again, or bill it by hand" rather than spinning.
    if (scanId) {
      try {
        await rpc('rx_scan_report', {
          p_scan_id: scanId, p_ok: false, p_model: MODEL,
          p_lines: [], p_error: msg, p_ms: Date.now() - started,
        })
      } catch (_) { /* the original error is the one that matters */ }
    }
    return new Response(JSON.stringify({ ok: false, error: msg }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
