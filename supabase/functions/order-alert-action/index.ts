// CHANGE #306 — the Accept / Reject buttons on the lock-screen notification.
//
// A button tapped over the lock screen has no Supabase session to speak of and
// must not carry one: refreshing a user JWT from a BroadcastReceiver would mean
// keeping long-lived credentials on the device. Instead every push carries a
// one-shot token minted by order_alert_push() for exactly that alert and that
// admin, expiring with the alert. This function is the only door that token
// opens, and it decides nothing — order_alert_action_by_token() applies the
// action, enforces the credit block and words the reply.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

  let body: { token?: string; action?: string; reason?: string }
  try {
    body = await req.json()
  } catch {
    return json({ ok: false, error: 'bad_json' }, 400)
  }

  const token = (body.token ?? '').trim()
  const action = (body.action ?? '').trim()
  if (!token) return json({ ok: false, error: 'no_token' }, 400)
  if (action !== 'accept' && action !== 'reject') {
    return json({ ok: false, error: 'bad_action' }, 400)
  }

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/order_alert_action_by_token`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_token: token,
      p_action: action,
      p_reason: body.reason ?? null,
    }),
  })

  const text = await r.text()
  if (!r.ok) return json({ ok: false, error: 'rpc_failed', status: r.status, detail: text.slice(0, 300) })
  try {
    return json(JSON.parse(text))
  } catch {
    return json({ ok: false, error: 'bad_rpc_reply' })
  }
})
