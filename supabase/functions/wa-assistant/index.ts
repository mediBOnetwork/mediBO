import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

// CHANGE #714 — the WhatsApp order assistant's CLASSIFIER, and only that.
//
// This function reads a customer's message and answers ONE question: which of
// the eight intents is this, how sure am I, and is the person angry. It never
// writes a sentence the customer will see — the reply is assembled in SQL from
// order_timeline / customer_track_order / the bill and payment rows, using a
// template out of ui_copy. So the model can pick the wrong TEMPLATE (and the
// confidence floor plus the hand-off rules catch that), but it can never
// invent a delivery date, an amount or a status.
//
// Model, endpoint and credential are the ones this codebase mandates and are
// copied from gemini-ocr, which is the ONE place they are named:
// gemini-3.5-flash on Vertex AI's global endpoint, thinkingLevel 'low',
// GCP_SA_KEY service-account auth. No API key, no generativelanguage.
//
// FAILING SAFE IS THE POINT. Vertex is unreachable on this project today
// (billing), so every path that cannot produce a confident intent returns
// ok:false with a reason, and the SQL side hands the conversation to a person.
// That is the direction this feature must fail in.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL = 'gemini-3.5-flash'

// The classifier's whole vocabulary. It may return one of these and nothing
// else; anything unrecognised is treated as 'other', which always hands off.
const INTENTS = [
  'where_is_order',
  'bill',
  'payment_status',
  'return_status',
  'reorder',
  'unavailable_item',
  'complaint',
  'other',
] as const

const PROMPT = `You are classifying ONE message a pharmacy sent to its wholesale supplier on WhatsApp, in English, Hindi or Hinglish.

Return STRICT JSON and nothing else:
{"intent":"<one of ${INTENTS.join('|')}>","confidence":<0..1>,"sentiment":"<positive|neutral|negative>","order_code":"<an order code the message quotes, or empty>"}

What each intent means:
- where_is_order: asking where an order is, when it will arrive, or its status.
- bill: asking for a bill, invoice, or what an order came to.
- payment_status: asking whether a payment was received, or what is outstanding.
- return_status: asking about a return, a replacement or a credit note.
- reorder: asking to order the same thing again.
- unavailable_item: asking about an item that was short, missing or not supplied.
- complaint: angry, dissatisfied, alleging a mistake, or threatening to stop buying.
- other: anything else, including greetings, or a message you are not sure about.

Rules:
- If the message is angry or abusive in ANY language, sentiment is "negative".
- If you are not sure, use "other" and a LOW confidence. Guessing is worse than
  handing the conversation to a person.
- order_code is only a code that literally appears in the message. Never invent one.`

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

  const json = (payload: unknown, status = 200) =>
    new Response(JSON.stringify(payload), {
      status,
      headers: { ...cors, 'Content-Type': 'application/json' },
    })

  try {
    const body = await req.json() as { text?: string }
    const text = (body.text ?? '').toString().trim()
    if (!text) {
      return json({ ok: false, reason: 'empty_text' })
    }

    const saJson = Deno.env.get('GCP_SA_KEY')
    if (!saJson) {
      // No credential is not an error the customer should feel: the SQL side
      // reads ok:false and hands the conversation to a person.
      return json({ ok: false, reason: 'no_credential' })
    }
    const sa = JSON.parse(saJson) as Record<string, string>
    const projectId = sa.project_id
    if (!projectId) return json({ ok: false, reason: 'no_project' })

    const accessToken = await getAccessToken(saJson)

    const resp = await fetch(
      `https://aiplatform.googleapis.com/v1/projects/${projectId}/locations/global` +
        `/publishers/google/models/${MODEL}:generateContent`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          contents: [{
            role: 'user',
            parts: [{ text: `${PROMPT}\n\nMESSAGE:\n${text}` }],
          }],
          generationConfig: {
            temperature: 0,
            responseMimeType: 'application/json',
            thinkingConfig: { thinkingLevel: 'low' },
          },
        }),
      },
    )

    if (!resp.ok) {
      const detail = (await resp.text()).slice(0, 300)
      return json({ ok: false, reason: 'vertex_error', detail, model: MODEL })
    }

    const data = await resp.json() as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
    }
    const raw = data.candidates?.[0]?.content?.parts?.[0]?.text ?? ''
    let parsed: Record<string, unknown>
    try {
      parsed = JSON.parse(raw) as Record<string, unknown>
    } catch {
      return json({ ok: false, reason: 'unparseable', detail: raw.slice(0, 200) })
    }

    const intent = String(parsed.intent ?? '')
    const confidence = Number(parsed.confidence ?? 0)
    const sentiment = String(parsed.sentiment ?? 'neutral')

    return json({
      ok: true,
      model: MODEL,
      // An intent outside the vocabulary is 'other', which always hands off.
      intent: (INTENTS as readonly string[]).includes(intent) ? intent : 'other',
      confidence: Number.isFinite(confidence)
        ? Math.max(0, Math.min(1, confidence))
        : 0,
      sentiment: ['positive', 'neutral', 'negative'].includes(sentiment)
        ? sentiment
        : 'neutral',
      order_code: String(parsed.order_code ?? '').slice(0, 40),
    })
  } catch (e) {
    return json({ ok: false, reason: 'exception', detail: String(e).slice(0, 300) })
  }
})
