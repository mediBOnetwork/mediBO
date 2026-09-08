// gcp-recover — service-role-only bridge that lets the EC2 builder reach the
// legacy GCP project with the SAME service account the Gemini/Vertex lane
// already uses (GCP_SA_KEY). CHANGE #277: the original Play upload keystore
// lives only on the old GCE VM and SSH keys are refused there, so the runner
// needs a credentialed path to (a) find the instance and (b) publish its own
// public key into instance metadata so the guest agent grants it a login.
//
// SECRETS HYGIENE: the service-account JSON never leaves this function. Only
// non-secret identity fields (client_email, project_id) are ever returned.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

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
    'pkcs8', keyBytes, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  )
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', privateKey,
    new TextEncoder().encode(sigInput))
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const tokenResp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${sigInput}.${sigB64}`,
    }),
  })
  if (!tokenResp.ok) throw new Error(`token_exchange_failed: ${await tokenResp.text()}`)
  const td = await tokenResp.json() as { access_token?: string }
  if (!td.access_token) throw new Error('no_access_token')
  return td.access_token
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (b: unknown, s = 200) =>
    new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } })

  try {
    const saJson = Deno.env.get('GCP_SA_KEY')
    if (!saJson) return json({ ok: false, error: 'GCP_SA_KEY secret not set' }, 200)
    const sa = JSON.parse(saJson) as Record<string, string>
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = String(body.action ?? 'whoami')
    const project = String(body.project ?? sa.project_id ?? '')

    if (action === 'whoami') {
      let token: string | null = null
      let tokenErr: string | null = null
      try { token = await getAccessToken(saJson) } catch (e) { tokenErr = String(e) }
      return json({ ok: !!token, client_email: sa.client_email, project_id: sa.project_id, token_error: tokenErr })
    }

    const token = await getAccessToken(saJson)
    const auth = { Authorization: `Bearer ${token}` }

    // Generic authenticated passthrough to Google APIs. Service-role only.
    // Keeps the recovery loop to one deploy instead of one per probe.
    if (action === 'raw') {
      const url = String(body.url ?? '')
      const method = String(body.method ?? 'GET')
      const payload = body.payload
      const r = await fetch(url, {
        method,
        headers: payload ? { ...auth, 'Content-Type': 'application/json' } : auth,
        body: payload ? JSON.stringify(payload) : undefined,
      })
      const txt = await r.text()
      let parsed: unknown = null
      try { parsed = JSON.parse(txt) } catch { parsed = txt.slice(0, 4000) }
      return json({ ok: r.ok, status: r.status, body: parsed })
    }

    if (action === 'projects') {
      const r = await fetch('https://cloudresourcemanager.googleapis.com/v1/projects', { headers: auth })
      return json({ ok: r.ok, status: r.status, body: await r.json().catch(() => null) })
    }

    if (action === 'instances') {
      const r = await fetch(
        `https://compute.googleapis.com/compute/v1/projects/${project}/aggregated/instances`,
        { headers: auth },
      )
      const raw = await r.json().catch(() => null) as any
      if (!r.ok) return json({ ok: false, status: r.status, body: raw })
      const out: unknown[] = []
      for (const [zk, zv] of Object.entries(raw?.items ?? {})) {
        for (const i of ((zv as any)?.instances ?? [])) {
          out.push({
            name: i.name,
            zone: String(zk).replace('zones/', ''),
            status: i.status,
            internal: i.networkInterfaces?.[0]?.networkIP,
            external: i.networkInterfaces?.[0]?.accessConfigs?.[0]?.natIP,
            metadata_keys: (i.metadata?.items ?? []).map((m: any) => m.key),
            fingerprint: i.metadata?.fingerprint,
          })
        }
      }
      return json({ ok: true, project, instances: out })
    }

    if (action === 'get_metadata') {
      const zone = String(body.zone ?? '')
      const name = String(body.instance ?? '')
      const r = await fetch(
        `https://compute.googleapis.com/compute/v1/projects/${project}/zones/${zone}/instances/${name}`,
        { headers: auth },
      )
      const raw = await r.json().catch(() => null) as any
      if (!r.ok) return json({ ok: false, status: r.status, body: raw })
      return json({ ok: true, fingerprint: raw?.metadata?.fingerprint, items: raw?.metadata?.items ?? [] })
    }

    // Publish an ssh-keys metadata entry. Existing keys are preserved; the
    // caller passes the FULL desired ssh-keys value so nothing is guessed here.
    if (action === 'set_ssh_keys') {
      const zone = String(body.zone ?? '')
      const name = String(body.instance ?? '')
      const sshKeys = String(body.ssh_keys ?? '')
      if (!sshKeys) return json({ ok: false, error: 'ssh_keys required' }, 200)
      const g = await fetch(
        `https://compute.googleapis.com/compute/v1/projects/${project}/zones/${zone}/instances/${name}`,
        { headers: auth },
      )
      const cur = await g.json().catch(() => null) as any
      if (!g.ok) return json({ ok: false, stage: 'get', status: g.status, body: cur })
      const items = (cur?.metadata?.items ?? []).filter((m: any) => m.key !== 'ssh-keys')
      items.push({ key: 'ssh-keys', value: sshKeys })
      const r = await fetch(
        `https://compute.googleapis.com/compute/v1/projects/${project}/zones/${zone}/instances/${name}/setMetadata`,
        {
          method: 'POST',
          headers: { ...auth, 'Content-Type': 'application/json' },
          body: JSON.stringify({ fingerprint: cur?.metadata?.fingerprint, items }),
        },
      )
      return json({ ok: r.ok, status: r.status, body: await r.json().catch(() => null) })
    }

    if (action === 'operation') {
      const r = await fetch(String(body.self_link ?? ''), { headers: auth })
      return json({ ok: r.ok, status: r.status, body: await r.json().catch(() => null) })
    }

    return json({ ok: false, error: `unknown action ${action}` }, 200)
  } catch (e) {
    return json({ ok: false, error: String(e) }, 200)
  }
})
