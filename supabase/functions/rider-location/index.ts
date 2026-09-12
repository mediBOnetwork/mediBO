// CHANGE #700 — rider-location
//
// The rider's position enters mediBO here, and this is the only place a fix is
// ever road-snapped. It exists because the snap has to happen BEFORE the
// broadcast, and Postgres cannot make a synchronous HTTP call: pg_net only
// dispatches a request once the calling transaction has committed, so an
// in-database snapper would always publish the raw point and correct it later.
//
// Flow, one fix:
//   1. delivery_snap_lookup(lat,lng)  — service role. Cheap and network-free.
//      Answers: is snapping on, is the circuit breaker closed, do we already
//      know this 15-metre square, and if not exactly which OSRM URL to call.
//      The endpoint never leaves the server: that RPC is service-role only.
//   2. On a cache miss, fetch OSRM /nearest with the configured timeout, and
//      report the outcome with delivery_snap_report() so the cache fills and
//      the breaker counts. A snap failure is NEVER fatal here.
//   3. delivery_update_location(...) — as the RIDER, with the caller's own JWT,
//      so auth.uid() still resolves to the rider and every existing rule
//      (geofence arrival, accuracy gate, partner check) applies unchanged.
//      That RPC stores raw + snapped, appends the run trail, and publishes the
//      broadcast on run:<run_id>.
//
// Called by the Android foreground service (which keeps running while the app
// is backgrounded or the screen is locked) and by the web/iOS in-app fallback.
// Browser-invoked, so it answers the OPTIONS preflight and sends CORS headers.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })

/** One RPC call, as whoever the Authorization header says. */
async function rpc(fn: string, args: unknown, auth: string, apikey: string) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'apikey': apikey,
      'Authorization': auth,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args ?? {}),
  })
  const text = await r.text()
  let parsed: any = null
  try { parsed = text ? JSON.parse(text) : null } catch { parsed = text }
  return { ok: r.ok, status: r.status, body: parsed }
}

const svc = (fn: string, args: unknown) => rpc(fn, args, `Bearer ${SERVICE_KEY}`, SERVICE_KEY)

function num(v: unknown): number | null {
  const n = typeof v === 'number' ? v : parseFloat(String(v ?? ''))
  return Number.isFinite(n) ? n : null
}

/**
 * Resolve the road-snapped twin of a raw fix. Returns nulls whenever snapping
 * is off, the breaker is open, OSRM does not answer inside its timeout, or the
 * nearest road is further away than max_dist_m (a rider genuinely off-road —
 * inside a market, a compound — must not be yanked onto a street they are not
 * on). Every one of those is a normal outcome, not an error: the caller
 * publishes the raw point and the payload says so.
 */
async function snap(lat: number, lng: number) {
  const none = { snap_lat: null as number | null, snap_lng: null as number | null, dist: null as number | null, why: '' }
  try {
    const look = await svc('delivery_snap_lookup', { p_lat: lat, p_lng: lng })
    const l = look.body
    if (!look.ok || !l || l.snap !== true) return { ...none, why: l?.reason ?? 'lookup_failed' }
    if (l.hit === true) {
      return { snap_lat: num(l.snap_lat), snap_lng: num(l.snap_lng), dist: num(l.dist_m), why: 'cache' }
    }

    const ctl = new AbortController()
    const timer = setTimeout(() => ctl.abort(), Math.max(200, Number(l.timeout_ms) || 1200))
    let res: Response
    try {
      res = await fetch(String(l.url), { signal: ctl.signal })
    } finally {
      clearTimeout(timer)
    }
    if (!res.ok) {
      await svc('delivery_snap_report', { p_ok: false, p_error: `http_${res.status}` })
      return { ...none, why: `http_${res.status}` }
    }
    const j = await res.json()
    const wp = j?.waypoints?.[0]
    const loc = wp?.location
    if (j?.code !== 'Ok' || !Array.isArray(loc) || loc.length < 2) {
      await svc('delivery_snap_report', { p_ok: false, p_error: `code_${j?.code ?? 'none'}` })
      return { ...none, why: 'no_waypoint' }
    }

    const sLng = num(loc[0]), sLat = num(loc[1]), dist = num(wp?.distance)
    const maxDist = Number(l.max_dist_m) || 60
    if (sLat === null || sLng === null) {
      await svc('delivery_snap_report', { p_ok: false, p_error: 'bad_location' })
      return { ...none, why: 'bad_location' }
    }
    // OSRM answered — the breaker closes even when we choose not to use the
    // point, because the endpoint is demonstrably alive.
    await svc('delivery_snap_report', {
      p_ok: true, p_gx: l.gx, p_gy: l.gy,
      p_snap_lat: sLat, p_snap_lng: sLng, p_dist_m: dist,
    })
    if (dist !== null && dist > maxDist) return { ...none, why: 'too_far' }
    return { snap_lat: sLat, snap_lng: sLng, dist, why: 'osrm' }
  } catch (e) {
    const why = String(e).includes('AbortError') ? 'timeout' : String(e).slice(0, 120)
    try { await svc('delivery_snap_report', { p_ok: false, p_error: why }) } catch { /* breaker is best-effort */ }
    return { ...none, why }
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ ok: false, error: 'method_not_allowed' }, 405)

  // The rider's own JWT. Without it delivery_update_location cannot resolve
  // auth.uid() and correctly refuses as not_a_partner — this function never
  // writes a position on somebody's behalf with the service key.
  const auth = req.headers.get('Authorization') ?? ''
  if (!auth) return json({ ok: false, error: 'no_auth' }, 401)

  let body: any = {}
  try { body = await req.json() } catch { /* empty body handled below */ }

  const lat = num(body?.lat), lng = num(body?.lng)
  if (lat === null || lng === null) return json({ ok: false, error: 'bad_fix' }, 400)

  const s = await snap(lat, lng)

  const res = await rpc('delivery_update_location', {
    p_lat: lat,
    p_lng: lng,
    p_heading: num(body?.heading),
    p_accuracy: num(body?.accuracy),
    p_snap_lat: s.snap_lat,
    p_snap_lng: s.snap_lng,
    p_snap_dist_m: s.dist,
    p_battery: num(body?.battery) === null ? null : Math.round(num(body?.battery)!),
    p_source: String(body?.source ?? 'app').slice(0, 24),
  }, auth, ANON_KEY)

  if (!res.ok) return json({ ok: false, error: 'update_failed', detail: res.body }, res.status)
  // snap_why is diagnostic only — no screen renders it. The user-facing
  // sentence for an unsnapped point is `note`, which the RPC supplies.
  return json({ ...(res.body ?? {}), snap_why: s.why })
})
