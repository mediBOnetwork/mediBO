// CMD #417 — the AI counter's intent layer.
//
// The one thing this function is NOT allowed to do is write the sentence a
// patient reads. Grounding here is structural, not a prompt instruction:
//
//   1. storefront_ai_context() hands us THIS pharmacy's matching stock rows —
//      product name, pack, MRP, quantity. Nothing else about the shop, and
//      nothing at all about any other shop.
//   2. Gemini classifies the message: an intent, and which of those rows the
//      patient means. It returns keys we gave it, never prose.
//   3. storefront_ai_reply() re-resolves every key against pharmacy_stock and
//      COMPOSES the answer from ui_copy. A key that is not on that shelf is
//      dropped; nothing left => the conversation is handed to the pharmacy.
//
// So a hallucinated medicine cannot reach a patient: it is not a stock row, so
// there is no sentence for it. Model auth, endpoint and thinkingLevel follow
// the gemini-ocr pattern exactly (Vertex AI global, GCP_SA_KEY, no API keys).

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-notify-secret',
}

const MODEL = 'gemini-3.5-flash'

const CLASSIFY_RULES = `You are the message CLASSIFIER for one Indian pharmacy's WhatsApp counter.
You never write a reply. You only classify, and you may only refer to the stock rows given below.

Return STRICT JSON only, no markdown:
{"intent":"availability|price|reserve|other","keys":["<key from STOCK exactly>"],"qty":1}

RULES:
- "keys" may ONLY contain key values copied from the STOCK list. Never invent one, never
  translate one, never use world knowledge about medicines that are not in that list.
- The patient asks if something is available or what it costs -> "availability" or "price".
- The patient asks to keep/hold/reserve/book an item -> "reserve".
- Anything else at all — dosage advice, a medical question, a complaint, a delivery ask,
  a greeting, or an item that is not in STOCK — is "other" with an empty keys array.
  "other" hands the conversation to the pharmacy staff, which is the correct, safe answer.
- Never guess. Uncertainty is "other".`

async function getAccessToken(saJson: string): Promise<string> {
  const sa = JSON.parse(saJson) as Record<string, string>
  const now = Math.floor(Date.now() / 1000)
  const b64 = (d: string) => btoa(d).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const header = b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const payload = b64(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/cloud-platform',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }))
  const sigInput = `${header}.${payload}`
  const keyBytes = Uint8Array.from(
    atob(sa.private_key.replace('-----BEGIN PRIVATE KEY-----', '')
      .replace('-----END PRIVATE KEY-----', '').replace(/\s/g, '')),
    (c) => c.charCodeAt(0),
  )
  const privateKey = await crypto.subtle.importKey(
    'pkcs8', keyBytes, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  )
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', privateKey,
    new TextEncoder().encode(sigInput))
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${sigInput}.${sigB64}`,
    }),
  })
  if (!resp.ok) throw new Error(`Token exchange failed: ${await resp.text()}`)
  const td = await resp.json() as { access_token?: string }
  if (!td.access_token) throw new Error('No access_token in response')
  return td.access_token
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

async function rpc(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
    body: JSON.stringify(args),
  })
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${await r.text()}`)
  return await r.json()
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (b: unknown, status = 200) =>
    new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

  // Called by the inbound trigger through pg_net, which carries no JWT — so the
  // shared notify secret is this function's door, exactly as wa-reply's is.
  const secret = Deno.env.get('NOTIFY_SECRET') ?? 'medibo_order_notify_2027'
  if (req.headers.get('x-notify-secret') !== secret) {
    return json({ ok: false, error: 'forbidden' }, 403)
  }

  try {
    const body = await req.json() as { phone?: string; text?: string }
    const phone = (body.phone ?? '').replace(/\D/g, '').slice(-10)
    const text = (body.text ?? '').trim()
    if (phone.length !== 10 || !text) return json({ ok: false, error: 'bad_request' }, 400)

    // 1. the shelf, and only the shelf
    const ctx = await rpc('storefront_ai_context', { p_phone: phone, p_text: text }) as
      { ok?: boolean; error?: string; shop?: string; matches?: Array<Record<string, unknown>> }
    if (!ctx?.ok) return json({ ok: false, error: ctx?.error ?? 'no_context' })

    const stock = (ctx.matches ?? []).map((m) => ({
      key: String(m.key ?? ''),
      product_name: String(m.product_name ?? ''),
      pack_label: String(m.pack_label ?? ''),
      mrp_display: String(m.mrp_display ?? ''),
    }))

    // 2. classify — never compose
    let intent = 'other'
    let keys: string[] = []
    let qty = 1
    if (stock.length > 0) {
      const saJson = Deno.env.get('GCP_SA_KEY')
      if (!saJson) throw new Error('GCP_SA_KEY secret not set')
      const sa = JSON.parse(saJson) as Record<string, string>
      const accessToken = await getAccessToken(saJson)
      const endpoint =
        `https://aiplatform.googleapis.com/v1/projects/${sa.project_id}/locations/global` +
        `/publishers/google/models/${MODEL}:generateContent`
      const prompt = `${CLASSIFY_RULES}\n\nSTOCK (the only medicines that exist for this conversation):\n` +
        `${JSON.stringify(stock)}\n\nPATIENT MESSAGE:\n${text}\n\nJSON:`
      const res = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${accessToken}` },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: [{ text: prompt }] }],
          generationConfig: {
            temperature: 0,
            maxOutputTokens: 512,
            thinkingConfig: { thinkingLevel: 'low' },
          },
        }),
      })
      if (res.ok) {
        const data = await res.json() as {
          candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>
        }
        const raw = data.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('') ?? ''
        const m = raw.match(/\{[\s\S]*\}/)
        if (m) {
          try {
            const parsed = JSON.parse(m[0]) as { intent?: string; keys?: string[]; qty?: number }
            const allowed = new Set(stock.map((s) => s.key))
            // the model's keys are FILTERED against what we handed it, before
            // they ever reach the database. Belt; the RPC is the braces.
            keys = (parsed.keys ?? []).map(String).filter((k) => allowed.has(k))
            intent = ['availability', 'price', 'reserve'].includes(parsed.intent ?? '')
              ? String(parsed.intent) : 'other'
            qty = Math.max(1, Math.min(Number(parsed.qty ?? 1) || 1, 20))
            if (keys.length === 0) intent = 'other'
          } catch { /* malformed JSON is an 'other' — the pharmacy answers */ }
        }
      }
    }

    // 3. the backend composes the sentence and logs both sides
    const rep = await rpc('storefront_ai_reply', {
      p_phone: phone, p_text: text, p_intent: intent, p_keys: keys, p_qty: qty,
    }) as { ok?: boolean; reply?: string; handoff?: boolean }
    if (!rep?.ok || !rep.reply) return json({ ok: false, error: 'no_reply' })

    // 4. and only then does it go out, through the one WhatsApp door
    await fetch(`${SUPABASE_URL}/functions/v1/wa-reply`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-notify-secret': 'medibo_order_notify_2027' },
      body: JSON.stringify({ to: phone, tag: 'counter_ai', text: rep.reply }),
    })

    return json({ ok: true, intent, keys, handoff: rep.handoff === true })
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500)
  }
})
