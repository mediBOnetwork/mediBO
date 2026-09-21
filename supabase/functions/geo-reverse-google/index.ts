// supabase/functions/geo-reverse-google — CMD #2135
//
// Google reverse geocode with a SERVER key (GOOGLE_GEOCODING_KEY). The browser
// key in map_config is referrer-restricted, and Google refuses a referrer key
// on the Geocoding web service (REQUEST_DENIED) — so the pin's address has to
// be read here, server side, never with Nominatim.
//
// Called by public.geo_reverse() over pgsql-http, synchronously. It answers
// with Google's own body UNTOUCHED: parsing (address, area, city, pincode,
// state, district) and the match to the official district list live in SQL
// (geo_reverse_parse / geo_district_pick), so a wording change is an UPDATE.
//
// Gate by CAPABILITY, not string equality: two different service-role
// credentials are valid for this project. The caller's token must be able to
// run geo_proxy_ok(), which is granted to service_role only.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

async function isServiceRole(token: string): Promise<boolean> {
  const base = Deno.env.get('SUPABASE_URL') ?? ''
  if (!token || !base) return false
  try {
    const r = await fetch(`${base}/rest/v1/rpc/geo_proxy_ok`, {
      method: 'POST',
      headers: { apikey: token, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: '{}',
    })
    return r.ok && (await r.text()).trim() === 'true'
  } catch {
    return false
  }
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const token = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim()
  if (!(await isServiceRole(token))) return json({ status: 'FORBIDDEN' }, 403)

  const key = Deno.env.get('GOOGLE_GEOCODING_KEY') ?? ''
  if (!key) return json({ status: 'NO_KEY' }, 503)

  const u = new URL(req.url)
  let lat = u.searchParams.get('lat') ?? ''
  let lng = u.searchParams.get('lng') ?? ''
  if ((!lat || !lng) && req.method === 'POST') {
    try {
      const b = await req.json() as { lat?: number | string; lng?: number | string }
      lat = String(b.lat ?? ''); lng = String(b.lng ?? '')
    } catch { /* fall through to the range check */ }
  }
  const la = Number(lat), ln = Number(lng)
  if (!Number.isFinite(la) || !Number.isFinite(ln) || Math.abs(la) > 90 || Math.abs(ln) > 180) {
    return json({ status: 'INVALID_POINT' }, 400)
  }

  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), 7000)
  try {
    const g = await fetch(
      `https://maps.googleapis.com/maps/api/geocode/json?latlng=${la},${ln}` +
        `&region=in&language=en&key=${encodeURIComponent(key)}`,
      { signal: ctrl.signal },
    )
    const body = await g.text()
    return new Response(body, { status: g.status, headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (e) {
    return json({ status: 'UPSTREAM_ERROR', error: String((e as Error)?.message ?? e).slice(0, 120) }, 502)
  } finally {
    clearTimeout(t)
  }
})
