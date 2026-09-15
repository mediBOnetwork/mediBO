// CHANGE #298 — push-send: FCM HTTP v1, authenticated with FIREBASE_SA_KEY.
//
// THE CREDENTIAL IS NOT GCP_SA_KEY. Same JWT dance as gemini-ocr (see the
// GEMINI RULE — only the scope and endpoint differ), but a DIFFERENT service
// account: medibo-fcm@medibo-23aee, which owns the Firebase project the app is
// registered against. GCP_SA_KEY belongs to another Google account entirely
// (project-b83d3f5f-25d0-45ef-a4e) and is Vertex AI only; using it here would
// POST every push to a project that has never heard of in.medibo.app. Never
// swap these two, and never overwrite GCP_SA_KEY with this one.
//
// Contract, called by notif_push_send() over pg_net:
//   { log_id, tokens: [..], title, body, deep_link, event_key, order_id }
// Every outcome is reported back to notif_push_result(), which closes the
// notification_log row, retires dead tokens, and falls back to WhatsApp when
// the push did not land. This function decides nothing about wording — title
// and body arrive rendered by the backend.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-notify-secret',
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

// FCM answers with these when a registration token is gone for good. Anything
// else (quota, transient 5xx) must NOT retire the token.
const DEAD_CODES = new Set([
  'UNREGISTERED',
  'INVALID_ARGUMENT',
  'SENDER_ID_MISMATCH',
])

let cachedToken: { value: string; exp: number } | null = null

async function getAccessToken(saJson: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  if (cachedToken && cachedToken.exp > now + 60) return cachedToken.value

  const sa = JSON.parse(saJson) as Record<string, string>
  const b64 = (d: string) => btoa(d).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const header = b64(JSON.stringify({ alg: 'RS256', typ: 'JWT' }))
  const payload = b64(JSON.stringify({
    iss: sa.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }))
  const sigInput = `${header}.${payload}`
  const pem = sa.private_key
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '')
  const keyBytes = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0))
  const key = await crypto.subtle.importKey(
    'pkcs8', keyBytes, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  )
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(sigInput))
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
  if (!resp.ok) throw new Error(`token_exchange_failed_${resp.status}`)
  const td = await resp.json() as { access_token: string; expires_in?: number }
  cachedToken = { value: td.access_token, exp: now + (td.expires_in ?? 3600) }
  return td.access_token
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  })
  return { status: r.status, body: await r.text() }
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (o: unknown, status = 200) =>
    new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

  let payload: {
    log_id?: number
    tokens?: string[]
    title?: string
    body?: string
    deep_link?: string
    event_key?: string
    order_id?: string
    dry_run?: boolean
    // CHANGE #306 — the full-screen order alert. Present = this is a ringing
    // alert, not an ordinary notification, and the message must be DATA-ONLY
    // so our own Android service builds it with a full-screen intent, a
    // looping alert sound and Accept / Reject buttons. Every string inside is
    // already rendered by order_alert_push(); this function words nothing.
    alert?: Record<string, unknown>
  }
  try {
    payload = await req.json()
  } catch {
    return json({ ok: false, error: 'bad_json' }, 400)
  }

  const logId = payload.log_id ?? null
  const tokens = (payload.tokens ?? []).filter((t) => typeof t === 'string' && t.length > 0)

  const report = async (ok: boolean, providerId: string | null, reason: string | null, dead: string[]) => {
    if (logId == null) return
    await rpc('notif_push_result', {
      p_log_id: logId,
      p_ok: ok,
      p_provider_id: providerId,
      p_reason: reason,
      p_dead_tokens: dead,
    })
  }

  // See the header: FIREBASE_SA_KEY, never GCP_SA_KEY.
  const saRaw = Deno.env.get('FIREBASE_SA_KEY') ?? ''
  if (!saRaw) {
    await report(false, null, 'firebase_sa_key_missing', [])
    return json({ ok: false, error: 'firebase_sa_key_missing' })
  }
  if (tokens.length === 0) {
    await report(false, null, 'no_tokens', [])
    return json({ ok: false, error: 'no_tokens' })
  }

  let projectId: string
  let accessToken: string
  try {
    projectId = (JSON.parse(saRaw) as { project_id: string }).project_id
    accessToken = await getAccessToken(saRaw)
  } catch (e) {
    const reason = String(e).slice(0, 200)
    await report(false, null, `auth_failed: ${reason}`, [])
    return json({ ok: false, error: 'auth_failed', detail: reason })
  }

  const endpoint = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`
  const dead: string[] = []
  let firstProviderId: string | null = null
  let delivered = 0
  let lastReason: string | null = null

  for (const token of tokens) {
    // data-only payload keys are strings by FCM contract; deep_link is what the
    // app navigates to so a tap opens the exact screen, never the home shell.
    const alert = payload.alert ?? null
    const ringSeconds = Number((alert?.ring_seconds as number) ?? 120)

    const data: Record<string, string> = {
      deep_link: payload.deep_link ?? '',
      event_key: payload.event_key ?? '',
      order_id: payload.order_id ?? '',
      log_id: String(logId ?? ''),
    }
    // FCM data values are strings by contract, so the whole alert travels as
    // one JSON string and Kotlin parses it back.
    if (alert) {
      data.type = 'order_alert'
      data.alert = JSON.stringify(alert)
    }

    const message = {
      message: {
        token,
        // A data-only message is what reaches onMessageReceived even when the
        // app is backgrounded or dead — which is the only way a full-screen
        // intent can be raised. An ordinary notification keeps its tray block.
        ...(alert ? {} : { notification: { title: payload.title ?? '', body: payload.body ?? '' } }),
        data,
        android: {
          priority: 'HIGH',
          ...(alert
            ? {
                // One live ring per alert: a re-ring replaces the last one
                // rather than stacking, and it expires with the ringing.
                collapse_key: `oa_${alert.alert_id ?? '0'}`,
                ttl: `${Math.max(ringSeconds * 4, 120)}s`,
                direct_boot_ok: true,
              }
            : {
                notification: { channel_id: 'medibo_default', click_action: 'FLUTTER_NOTIFICATION_CLICK' },
              }),
        },
        webpush: {
          // The browser cannot raise a full-screen intent, so a web admin gets
          // an ordinary notification carrying the same rendered words.
          ...(alert
            ? {
                headers: { Urgency: 'high' },
                notification: {
                  title: payload.title ?? '',
                  body: payload.body ?? '',
                  requireInteraction: true,
                  tag: `oa_${alert.alert_id ?? '0'}`,
                },
              }
            : {}),
          fcm_options: { link: payload.deep_link ?? '/' },
        },
      },
      ...(payload.dry_run ? { validate_only: true } : {}),
    }

    let resp: Response
    try {
      resp = await fetch(endpoint, {
        method: 'POST',
        headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(message),
      })
    } catch (e) {
      lastReason = `network: ${String(e).slice(0, 120)}`
      continue
    }

    const text = await resp.text()
    if (resp.ok) {
      delivered++
      if (!firstProviderId) {
        try { firstProviderId = (JSON.parse(text) as { name?: string }).name ?? null } catch { /* keep null */ }
      }
      continue
    }

    let code = `http_${resp.status}`
    try {
      const err = JSON.parse(text) as {
        error?: { status?: string; message?: string; details?: Array<{ errorCode?: string }> }
      }
      code = err.error?.details?.find((d) => d.errorCode)?.errorCode
        ?? err.error?.status
        ?? code
      lastReason = `${code}: ${(err.error?.message ?? '').slice(0, 160)}`
    } catch {
      lastReason = `${code}: ${text.slice(0, 160)}`
    }

    // 404 UNREGISTERED and 400 INVALID_ARGUMENT mean this device will never
    // receive again — retire the token so it stops costing a round trip.
    if (DEAD_CODES.has(code) || resp.status === 404) dead.push(token)
  }

  const ok = delivered > 0
  await report(ok, firstProviderId, ok ? null : (lastReason ?? 'push_failed'), dead)
  return json({
    ok,
    delivered,
    attempted: tokens.length,
    deactivated: dead.length,
    reason: ok ? null : lastReason,
  })
})
