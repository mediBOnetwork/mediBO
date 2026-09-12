// CMD #1929 — AI fallback for a payment notification no rule could read.
//
// TRANSPORT ONLY. Every word of the prompt, every decision about what the
// answer means and every stored string comes from the backend:
//   payment_alert_ai_prompt(alert_id)  -> the prompt, built in SQL
//   gemini-ocr                         -> the ONE pinned Vertex caller
//   payment_alert_ai_apply(alert_id, parsed, model) -> stores + matches
//
// GEMINI RULE: this function never talks to Vertex itself. It posts to the
// gemini-ocr edge function, which is the single place the model
// (gemini-3.5-flash), the global aiplatform endpoint, thinkingLevel and
// GCP_SA_KEY auth are pinned. Adding a second Vertex caller here is exactly
// what that rule forbids.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL_LABEL = 'gemini-3.5-flash'

type Parsed = {
  is_credit?: boolean
  amount?: number | string | null
  utr?: string | null
  vpa?: string | null
  sender?: string | null
}

// Gemini is asked for strict JSON, but a model may still wrap it in a fence.
function firstJsonObject(text: string): Parsed | null {
  const cleaned = text.replace(/```json/gi, '').replace(/```/g, '').trim()
  const start = cleaned.indexOf('{')
  const end = cleaned.lastIndexOf('}')
  if (start < 0 || end <= start) return null
  try {
    return JSON.parse(cleaned.slice(start, end + 1)) as Parsed
  } catch {
    return null
  }
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status, headers: { ...cors, 'Content-Type': 'application/json' },
    })

  try {
    const url = Deno.env.get('SUPABASE_URL') ?? ''
    const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set')

    const body = await req.json() as { alert_id?: string }
    const alertId = (body.alert_id ?? '').trim()
    if (!alertId) return json({ error: 'alert_id required' }, 400)

    const rpc = async (fn: string, args: unknown) => {
      const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'apikey': key,
          'Authorization': `Bearer ${key}`,
        },
        body: JSON.stringify(args),
      })
      const text = await r.text()
      if (!r.ok) throw new Error(`${fn} ${r.status}: ${text}`)
      return text ? JSON.parse(text) : null
    }

    // 1. The prompt is the BACKEND's, verbatim.
    const p = await rpc('payment_alert_ai_prompt', { p_alert_id: alertId }) as
      { ok?: boolean; error?: string; prompt?: string }
    if (!p?.ok || !p.prompt) return json({ error: p?.error ?? 'no_prompt' }, 404)

    // 2. The ONE pinned Vertex caller.
    const g = await fetch(`${url}/functions/v1/gemini-ocr`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${key}` },
      body: JSON.stringify({ prompt: p.prompt }),
    })
    const gText = await g.text()
    if (!g.ok) throw new Error(`gemini-ocr ${g.status}: ${gText}`)
    const gData = JSON.parse(gText) as { text?: string; error?: string }
    if (gData.error) throw new Error(`gemini-ocr: ${gData.error}`)

    const parsed = firstJsonObject(gData.text ?? '')
    if (!parsed) {
      // Unreadable answer is not a credit we can act on: the backend records
      // that and leaves the alert for a human, with its own wording.
      const out = await rpc('payment_alert_ai_apply', {
        p_alert_id: alertId,
        p_parsed: { is_credit: true, amount: null },
        p_model: MODEL_LABEL,
      })
      return json({ ok: false, reason: 'unparseable_model_output', state: out })
    }

    // 3. What it read, applied and matched — all in SQL.
    const out = await rpc('payment_alert_ai_apply', {
      p_alert_id: alertId,
      p_parsed: parsed,
      p_model: MODEL_LABEL,
    })
    return json({ ok: true, state: out })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    return json({ error: msg }, 500)
  }
})
