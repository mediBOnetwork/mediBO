import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL = 'gemini-3.5-flash'

// Shared rules appended to every company-extraction prompt.
const COMPANY_GRID_RULES = `
RULES FOR "companies" — GRID SCAN (CRITICAL — follow in order):
STEP 1: Scan the entire company section and COUNT every distinct tile/cell/logo box. There may be 20–50 tiles. Hold that count.
STEP 2: Output EXACTLY one JSON entry per tile. Your array length MUST equal your tile count. NEVER skip a tile. NEVER merge two tiles into one entry.
STEP 3 per tile:
  seen = the VERBATIM text/abbreviation printed on the tile (strip brackets: "ABBOTT [DIGENE]" → "ABBOTT"). If the tile has no readable text, write the brand name you can visually identify from the logo. Output the text EXACTLY as it appears on the card — do NOT expand abbreviations, do NOT substitute parent/owner/successor company names, do NOT apply any corporate knowledge.
  confidence = high if certain, medium if likely, low if the tile is unrecognizable.
STEP 4: After writing the array, verify: array.length === tile count from STEP 1. If not, add missing entries with confidence=low.`

// Company-list-only mode prompt (mode:'company_list').
const COMPANY_LIST_PROMPT =
  'This image is a pharma distributor company list containing logos. ' +
  'Return strict JSON array only (no other text, no markdown): ' +
  '[{"seen":"...","confidence":"high|medium|low"}].' +
  COMPANY_GRID_RULES

// Generate a GCP access token from a service account JSON key.
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
    'pkcs8',
    keyBytes,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  )

  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    privateKey,
    new TextEncoder().encode(sigInput),
  )
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')

  const jwt = `${sigInput}.${sigB64}`

  const tokenResp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  })
  if (!tokenResp.ok) throw new Error(`Token exchange failed: ${await tokenResp.text()}`)
  const td = await tokenResp.json() as { access_token?: string }
  if (!td.access_token) throw new Error('No access_token in response')
  return td.access_token
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  try {
    const saJson = Deno.env.get('GCP_SA_KEY')
    if (!saJson) throw new Error('GCP_SA_KEY secret not set')

    const sa = JSON.parse(saJson) as Record<string, string>
    const projectId = sa.project_id
    if (!projectId) throw new Error('project_id missing from GCP_SA_KEY')

    const body = await req.json() as {
      image_base64?: string
      mime_type?: string
      prompt?: string
      mode?: string
    }

    const { image_base64 = '', mime_type = 'image/jpeg', mode } = body
    const prompt = mode === 'company_list' ? COMPANY_LIST_PROMPT : (body.prompt ?? '')

    if (!prompt) {
      return new Response(JSON.stringify({ error: 'prompt or mode required' }), {
        status: 400, headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    const accessToken = await getAccessToken(saJson)

    const endpoint =
      `https://aiplatform.googleapis.com/v1/projects/${projectId}/locations/global` +
      `/publishers/google/models/${MODEL}:generateContent`

    const parts: unknown[] = []
    if (image_base64) {
      parts.push({ inlineData: { mimeType: mime_type, data: image_base64 } })
    }
    parts.push({ text: prompt })

    const payload = {
      contents: [{ role: 'user', parts }],
      generationConfig: {
        temperature: 0,
        maxOutputTokens: 8192,
        thinkingConfig: { thinkingLevel: 'low' },
      },
    }

    const res = await fetch(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${accessToken}`,
      },
      body: JSON.stringify(payload),
    })

    if (!res.ok) {
      const errText = await res.text()
      throw new Error(`Vertex AI error ${res.status}: ${errText}`)
    }

    const data = await res.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
    }
    const text = data.candidates?.[0]?.content?.parts?.[0]?.text ?? ''

    return new Response(JSON.stringify({ text }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
