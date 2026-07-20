import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'

// voice-receive v25: WINDOWED SESSIONS + REGION FALLBACK.
// Continuous voice counting (mediBO CHANGE: continuous-voice-counting) slices a long
// recording into overlapping ~30s windows on the client and calls this function once per
// window instead of once for a whole 10-20min clip. That keeps every single call small and
// fast, which is what makes 'minimal' thinking + a tighter 45s timeout safe here (v24 used
// 'low' + 30s for single, long, single-shot clips). Region fallback (global -> us-central1)
// mirrors the pattern already proven in gemini-ocr v42.
//
// Fully backward compatible: session_key/recording_seq/window_offset_sec/stage are optional.
// Callers that omit them (the pre-windowing single-shot flow) get byte-identical behavior to
// v24 — mention timestamps stay clip-relative and nothing about matching/filtering changes.
// When window_offset_sec IS provided, mention t_start/t_end are shifted to be absolute on the
// session clock (window_offset_sec + gemini_t) before being returned, so the caller never has
// to duplicate that arithmetic. session_key/recording_seq/stage are echoed back unchanged for
// the caller's own idempotency bookkeeping — this function still does not write to the DB.
//
// v8 PHANTOM GUARD (unchanged): a blank/near-empty transcript forces items=[] and mentions=[];
// each mention carries a confidence and is dropped below min_confidence; a mention is kept
// ONLY if its product also survived the vetted items filter.

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const MODEL = 'gemini-3.5-flash'
const REGIONS = ['global', 'us-central1']
const VERTEX_CALL_TIMEOUT_MS = 45_000
const ATTEMPTS_PER_REGION = 2
const CONF_MIN_DEFAULT = 0.75
const FUZZY_MIN = 0.82
const RETRYABLE_STATUS = new Set([429, 500, 502, 503, 504])

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const jitter = (base: number) => base + Math.floor(Math.random() * 400)

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
    iat: now, exp: now + 3600,
  }))
  const sigInput = `${header}.${payload}`
  const keyPem = sa.private_key
    .replace('-----BEGIN PRIVATE KEY-----', '').replace('-----END PRIVATE KEY-----', '').replace(/\s/g, '')
  const keyBytes = Uint8Array.from(atob(keyPem), (c) => c.charCodeAt(0))
  const privateKey = await crypto.subtle.importKey(
    'pkcs8', keyBytes, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  )
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', privateKey, new TextEncoder().encode(sigInput))
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_')
  const jwt = `${sigInput}.${sigB64}`
  const tokenResp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
  })
  if (!tokenResp.ok) throw new Error(`Token exchange failed: ${await tokenResp.text()}`)
  const td = await tokenResp.json() as { access_token?: string }
  if (!td.access_token) throw new Error('No access_token in response')
  return td.access_token
}

function buildEndpoint(projectId: string, region: string): string {
  const host = region === 'global' ? 'aiplatform.googleapis.com' : `${region}-aiplatform.googleapis.com`
  return `https://${host}/v1/projects/${projectId}/locations/${region}` +
    `/publishers/google/models/${MODEL}:generateContent`
}

// Region-fallback caller (pattern proven in gemini-ocr v42's callVertex): tries each region
// in turn, retrying transient errors within a region before advancing to the next.
async function callVertex(projectId: string, accessToken: string, payload: unknown): Promise<string> {
  let lastErr = ''
  for (let ri = 0; ri < REGIONS.length; ri++) {
    const region = REGIONS[ri]
    const endpoint = buildEndpoint(projectId, region)
    let advanceRegion = false

    for (let attempt = 1; attempt <= ATTEMPTS_PER_REGION; attempt++) {
      const ctrl = new AbortController()
      const timer = setTimeout(() => ctrl.abort(), VERTEX_CALL_TIMEOUT_MS)
      let res: Response
      try {
        res = await fetch(endpoint, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${accessToken}` },
          body: JSON.stringify(payload),
          signal: ctrl.signal,
        })
      } catch (e) {
        const aborted = (e as Error)?.name === 'AbortError'
        lastErr = aborted ? `timeout(${region}) after ${VERTEX_CALL_TIMEOUT_MS}ms` : `network(${region}): ${String((e as Error)?.message || e)}`
        console.error('[voice-receive]', lastErr)
        if (attempt < ATTEMPTS_PER_REGION) { await sleep(jitter(600 * attempt)); continue }
        advanceRegion = true; break
      } finally { clearTimeout(timer) }

      if (!res.ok) {
        const bodyTxt = (await res.text()).slice(0, 300)
        lastErr = `Vertex ${region} ${res.status}: ${bodyTxt}`
        console.error('[voice-receive]', lastErr)
        if (RETRYABLE_STATUS.has(res.status)) {
          const ra = Number(res.headers.get('retry-after'))
          const wait = res.status === 429
            ? Math.max((Number.isFinite(ra) ? ra : 0) * 1000, 3000) + jitter(600)
            : jitter(700 * attempt)
          if (attempt < ATTEMPTS_PER_REGION) { await sleep(wait); continue }
          advanceRegion = true; break
        }
        if (res.status === 404 || res.status === 400) { advanceRegion = true; break }
        throw new Error(lastErr)
      }

      const data = await res.json() as { candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }> }
      const text = data.candidates?.[0]?.content?.parts?.[0]?.text ?? ''
      if (!text) {
        lastErr = `empty_candidates(${region})`
        if (attempt < ATTEMPTS_PER_REGION) { await sleep(jitter(600)); continue }
        advanceRegion = true; break
      }
      return text
    }

    if (advanceRegion && ri < REGIONS.length - 1) {
      console.error(`[voice-receive] region ${region} exhausted -> falling back to ${REGIONS[ri + 1]}`)
    }
  }
  throw new Error(lastErr || 'vertex_failed')
}

type Expected = { name?: string; ordered_qty?: number | null; unit?: string | null }

function normName(s: string): string {
  return String(s ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
}
function levenshtein(a: string, b: string): number {
  if (a === b) return 0
  const al = a.length, bl = b.length
  if (al === 0) return bl
  if (bl === 0) return al
  let prev = new Array(bl + 1)
  let cur = new Array(bl + 1)
  for (let j = 0; j <= bl; j++) prev[j] = j
  for (let i = 1; i <= al; i++) {
    cur[0] = i
    const ca = a.charCodeAt(i - 1)
    for (let j = 1; j <= bl; j++) {
      const cost = ca === b.charCodeAt(j - 1) ? 0 : 1
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    }
    const tmp = prev; prev = cur; cur = tmp
  }
  return prev[bl]
}
function similarity(a: string, b: string): number {
  const na = normName(a), nb = normName(b)
  if (!na.length || !nb.length) return 0
  if (na === nb) return 1
  const d = levenshtein(na, nb)
  const maxLen = Math.max(na.length, nb.length)
  return 1 - d / maxLen
}
function firstToken(s: string): string {
  const n = normName(s)
  const sp = n.indexOf(' ')
  return sp === -1 ? n : n.slice(0, sp)
}
function bestMatch(heard: string, names: string[]): string | null {
  const h = normName(heard)
  if (!h.length || !names.length) return null
  let best: string | null = null
  let bestScore = 0
  const hTok = firstToken(heard)
  for (const nm of names) {
    const whole = similarity(heard, nm)
    const tok = hTok && firstToken(nm) ? similarity(hTok, firstToken(nm)) : 0
    const score = Math.max(whole, 0.6 * whole + 0.4 * tok)
    if (score > bestScore) { bestScore = score; best = nm }
  }
  return bestScore >= FUZZY_MIN ? best : null
}

const PREAMBLE =
  `You are transcribing audio from a pharmacy warehouse goods-receiving session in India. ` +
  `A staff member reads aloud each pharmaceutical product received and the quantity in hand RIGHT NOW, e.g. ` +
  `\"Telma 40 two strips\", \"Pan D one box\". Stock arrives mixed, so the spoken quantity is a PARTIAL count ` +
  `(often 1, 2 or 3) and may be less than what was ordered — that is normal and expected. ` +
  `The speaker uses Indian-accented English and Indian pharma BRAND names (proper nouns). ` +
  `Transcribe brand names exactly as spoken; do NOT translate, expand, or \"correct\" them into ordinary ` +
  `English words (keep \"Pan D\", never \"pan dee\"). Convert spoken numbers to integers (\"two\" -> 2). ` +
  `Normalize unit to one of box, strip, bottle, pack, vial, piece (or null).`

const ANTI_HALLUCINATION =
  `\n\nCRITICAL RULES (follow exactly):\n` +
  `1. Transcribe the audio FIRST. Only report a product if you can ACTUALLY HEAR its name spoken in this audio.\n` +
  `2. If the audio is silence, breathing, background noise, music, distant/unclear chatter, or has no clear ` +
  `pharmaceutical product name, return {\"items\":[],\"mentions\":[],\"transcript\":\"\"}. An empty list is correct and expected. ` +
  `Do NOT emit any item or mention when the transcript is empty.\n` +
  `3. NEVER add a product just because it is on the ORDERED LIST. The list is ONLY a spelling reference for ` +
  `products you genuinely heard. It is NOT a checklist to complete. Do not fill it in.\n` +
  `4. Do not guess or infer. If you are not confident a product name was actually spoken, leave it out entirely.\n` +
  `5. MANDATORY NAME+QUANTITY PAIR: report a product ONLY when the speaker said BOTH its name AND a spoken ` +
  `number for it in the same utterance. received_qty = exactly the integer the speaker SAID (a partial count ` +
  `like 1, 2 or 3 is valid — do NOT round up to the ordered quantity, do NOT default to the ordered quantity). ` +
  `If a product name was heard but NO number was clearly spoken for it, DROP that product entirely. ` +
  `NEVER invent a quantity: if you did not clearly hear a number, do not output the product at all.\n` +
  `6. confidence = how sure you are this exact product name was actually, clearly spoken close to the mic ` +
  `(1.0 = crystal clear and near; lower for faint/distant/overlapping speech). Be strict.`

const MENTIONS_RULES =
  `\n\nADDITIONALLY return a \"mentions\" array. Unlike \"items\" (which sums each product once), \"mentions\" ` +
  `lists EVERY SEPARATE TIME the speaker said a product together with a number — in the order spoken, NOT ` +
  `collapsed. Example: \"Aptimust two\" early, then \"Aptimust four\" later, then \"Aptimust two\" again = THREE ` +
  `separate mentions (2, 4, 2). For EACH mention provide:\n` +
  `  - heard = the exact words the speaker said for THIS mention (the raw product words as you heard them).\n` +
  `  - confidence = 0.0-1.0, how sure you are that THIS product name AND its number were actually, clearly ` +
  `spoken in the audio (be strict; silence/noise/faint/guessed = low, below 0.5).\n` +
  `  - t_start = the time in SECONDS from the very start of THIS audio clip at which the speaker BEGINS saying ` +
  `that product's name (a decimal, e.g. 3.2).\n` +
  `  - t_end = the time in SECONDS at which the speaker FINISHES saying that product+number (e.g. 4.9). ` +
  `t_end MUST be greater than t_start.\n` +
  `If you genuinely cannot determine a time, set it to null. Only include a mention when BOTH a product name ` +
  `AND a number were spoken together. ord = 0-based index of the mention in spoken order.`

const MATCHING_RULES =
  `\n\nMATCHING (important): For every product you heard WITH a number, match it to the CLOSEST item on the ` +
  `ORDERED LIST by name. Indian brand names are often mis-heard by one or two letters or vowels — be GENEROUS: ` +
  `if what you heard sounds close to a list item, MATCH IT and use that list item's exact spelling. ` +
  `For example heard \"Comforte\" should match list item \"Camforte 0.25mg Tablet\"; heard \"Telmaa\" matches ` +
  `\"Telma 40\". Only set matched_name to null if NOTHING on the list is reasonably close. Prefer matching over null.`

function buildReconcilePrompt(expected: Expected[]): string {
  const lines = expected.slice(0, 400).map((e) => {
    const q = (e.ordered_qty ?? null)
    const u = e.unit ? ` ${e.unit}` : ''
    return `- \"${String(e.name ?? '').replace(/\"/g, '')}\" (ordered: ${q ?? '?'}${u})`
  }).join('\n')
  return PREAMBLE + ANTI_HALLUCINATION + MENTIONS_RULES + MATCHING_RULES +
    `\n\nIf a product you heard is clearly NOT on the list, set matched_name to null and status \"not_on_order\".\n\n` +
    `ORDERED LIST:\n${lines}\n\n` +
    `Return ONLY strict JSON, no markdown:\n` +
    `{\"items\":[{\"heard\":\"<exact words spoken>\",\"matched_name\":\"<exact name from list, or null>\",` +
    `\"ordered_qty\":<int|null>,\"received_qty\":<int>,\"unit\":\"<box|strip|bottle|pack|vial|piece|null>\",` +
    `\"confidence\":<0.0-1.0>,\"status\":\"ok|short|over|not_on_order\"}],` +
    `\"mentions\":[{\"heard\":\"<exact words spoken>\",\"matched_name\":\"<name from list, or null>\",\"qty\":<int>,\"confidence\":<0.0-1.0>,\"t_start\":<seconds|null>,\"t_end\":<seconds|null>,\"ord\":<int>}],` +
    `\"transcript\":\"<full raw transcript>\"}\n\n` +
    `received_qty MUST be the spoken integer (never null). status rules: ok = received equals ordered; ` +
    `short = received < ordered; over = received > ordered; not_on_order = product not on the ordered list. ` +
    `Every item MUST have a non-empty \"heard\" value. If nothing intelligible with a number was spoken: ` +
    `{\"items\":[],\"mentions\":[],\"transcript\":\"\"}.`
}

function buildSimplePrompt(hintNames?: string[]): string {
  let p = PREAMBLE + ANTI_HALLUCINATION + MENTIONS_RULES + `\n\nReturn ONLY strict JSON, no markdown:\n` +
    `{\"items\":[{\"name\":\"<product as heard>\",\"quantity\":<int>,\"unit\":\"<box|strip|bottle|pack|vial|piece|null>\",` +
    `\"confidence\":<0.0-1.0>}],` +
    `\"mentions\":[{\"heard\":\"<product as heard>\",\"name\":\"<product as heard>\",\"qty\":<int>,\"confidence\":<0.0-1.0>,\"t_start\":<seconds|null>,\"t_end\":<seconds|null>,\"ord\":<int>}],` +
    `\"transcript\":\"<full raw transcript>\"}\nOne items entry per distinct product actually spoken ` +
    `WITH a number. quantity MUST be the spoken integer (never null). ` +
    `If nothing intelligible with a number: {\"items\":[],\"mentions\":[],\"transcript\":\"\"}.`
  if (hintNames && hintNames.length) {
    const list = hintNames.slice(0, 400).map((n) => `\"${String(n).replace(/\"/g, '')}\"`).join(', ')
    p += `\n\nSPELLING REFERENCE -- when what you hear is close to one of these, prefer its exact spelling ` +
      `(but only if you actually heard it with a number): [${list}].`
  }
  return p
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  try {
    const saJson = Deno.env.get('GCP_SA_KEY')
    if (!saJson) throw new Error('GCP_SA_KEY secret not set')

    const body = await req.json() as {
      audio_base64?: string
      mime_type?: string
      expected?: Expected[]
      hint_names?: string[]
      min_confidence?: number
      session_key?: string
      recording_seq?: number
      window_offset_sec?: number
      stage?: string
    }
    const audio = body.audio_base64 ?? ''
    const mime = body.mime_type ?? 'audio/webm'
    const confMin = typeof body.min_confidence === 'number' ? body.min_confidence : CONF_MIN_DEFAULT
    if (!audio) {
      return new Response(JSON.stringify({ error: 'audio_base64 required' }), {
        status: 400, headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }
    const windowOffset = typeof body.window_offset_sec === 'number' && Number.isFinite(body.window_offset_sec)
      ? body.window_offset_sec
      : null

    const hasExpected = Array.isArray(body.expected) && body.expected.length > 0
    const mode = hasExpected ? 'reconcile' : 'simple'
    const prompt = hasExpected ? buildReconcilePrompt(body.expected!) : buildSimplePrompt(body.hint_names)
    const expectedNames: string[] = hasExpected
      ? body.expected!.map((e) => String(e.name ?? '')).filter((s) => s.length > 0)
      : (Array.isArray(body.hint_names) ? body.hint_names.map((s) => String(s)).filter((s) => s.length > 0) : [])

    const sa = JSON.parse(saJson) as Record<string, string>
    const projectId = sa.project_id
    if (!projectId) throw new Error('project_id missing from GCP_SA_KEY')

    const accessToken = await getAccessToken(saJson)

    const payload = {
      contents: [{ role: 'user', parts: [
        { inlineData: { mimeType: mime, data: audio } },
        { text: prompt },
      ] }],
      generationConfig: {
        temperature: 0,
        maxOutputTokens: 8192,
        thinkingConfig: { thinkingLevel: 'minimal' },
        responseMimeType: 'application/json',
      },
    }

    const raw = await callVertex(projectId, accessToken, payload)

    let parsed: { items?: unknown; mentions?: unknown; transcript?: unknown } = {}
    try {
      const cleaned = raw.trim().replace(/^```json\s*/i, '').replace(/^```\s*/i, '').replace(/```$/i, '').trim()
      parsed = JSON.parse(cleaned)
    } catch {
      parsed = { items: [], mentions: [], transcript: raw }
    }
    let items = Array.isArray(parsed.items) ? parsed.items : []
    let mentions = Array.isArray(parsed.mentions) ? parsed.mentions : []
    const transcript = typeof parsed.transcript === 'string' ? parsed.transcript : raw

    // PHANTOM GUARD (a): a blank / near-empty transcript means nothing was actually spoken.
    // Force everything empty regardless of what the model put in items/mentions.
    const transcriptClean = (typeof transcript === 'string' ? transcript : '').replace(/[^a-z0-9]/gi, '')
    const blankTranscript = transcriptClean.length < 2
    if (blankTranscript) { items = []; mentions = [] }

    let fuzzy_filled = 0
    let dropped_no_qty = 0
    let dropped_low_conf = 0

    items = items.filter((it) => {
      const o = (it ?? {}) as Record<string, unknown>
      const heard = typeof o.heard === 'string' ? o.heard.trim()
        : (typeof o.name === 'string' ? o.name.trim() : '')
      const conf = typeof o.confidence === 'number' ? o.confidence : 1
      const qRaw = (o.received_qty ?? o.quantity)
      const qty = typeof qRaw === 'number' ? qRaw : Number(qRaw)
      if (!heard.length) return false
      if (conf < confMin) { dropped_low_conf++; return false }
      if (!Number.isFinite(qty) || qty <= 0) { dropped_no_qty++; return false }
      return true
    }).map((it) => {
      const o = (it ?? {}) as Record<string, unknown>
      const heard = typeof o.heard === 'string' ? o.heard
        : (typeof o.name === 'string' ? o.name : '')
      const mn = typeof o.matched_name === 'string' ? o.matched_name.trim() : ''
      if ((!mn || mn.length === 0) && expectedNames.length) {
        const m = bestMatch(heard, expectedNames)
        if (m) { o.matched_name = m; if (o.status === 'not_on_order') o.status = 'ok'; fuzzy_filled++ }
      }
      return o
    })

    // Vetted product names that survived the strict items filter above.
    const okNames = new Set<string>(
      items.map((it) => {
        const o = (it ?? {}) as Record<string, unknown>
        return normName(String((o.matched_name ?? o.name) ?? ''))
      }).filter((s) => s.length > 0),
    )

    const num = (v: unknown): number | null => {
      if (typeof v === 'number' && Number.isFinite(v) && v >= 0) return v
      if (typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v)) && Number(v) >= 0) return Number(v)
      return null
    }
    let dropped_phantom_mention = 0
    mentions = mentions
      .map((m, i) => {
        const o = (m ?? {}) as Record<string, unknown>
        let name = typeof o.matched_name === 'string' ? o.matched_name
          : (typeof o.name === 'string' ? o.name : null)
        const heard = typeof o.heard === 'string' ? o.heard
          : (typeof o.name === 'string' ? o.name : '')
        if ((!name || String(name).trim().length === 0) && expectedNames.length) {
          const best = bestMatch(heard, expectedNames)
          if (best) { name = best; fuzzy_filled++ }
        }
        const qRaw = o.qty
        const qty = typeof qRaw === 'number' ? qRaw : Number(qRaw)
        const conf = typeof o.confidence === 'number' ? o.confidence : null
        let tStart = num(o.t_start)
        let tEnd = num(o.t_end)
        if (tStart !== null && tEnd !== null && tEnd <= tStart) tEnd = null
        // Shift to the session clock when this call is one window of a longer continuous
        // recording, so the caller never has to duplicate this arithmetic (§1 of the build spec).
        if (windowOffset !== null) {
          if (tStart !== null) tStart += windowOffset
          if (tEnd !== null) tEnd += windowOffset
        }
        const ord = typeof o.ord === 'number' ? o.ord : i
        return { matched_name: name, heard, qty, conf, t_start: tStart, t_end: tEnd, ord }
      })
      .filter((m) => {
        // qty must be a real positive number
        if (!Number.isFinite(m.qty) || (m.qty as number) <= 0) return false
        // PHANTOM GUARD (b): drop mentions the model was not confident about
        if (typeof m.conf === 'number' && m.conf < confMin) { dropped_phantom_mention++; return false }
        // PHANTOM GUARD (c): a mention may only exist for a product that survived the
        // vetted items filter (or, in no-hint simple mode, that has a real heard name).
        const nm = normName(String(m.matched_name ?? ''))
        if (!nm.length) { dropped_phantom_mention++; return false }
        if (okNames.size > 0) {
          if (!okNames.has(nm)) { dropped_phantom_mention++; return false }
        }
        return true
      })
      .map((m) => ({ matched_name: m.matched_name, heard: m.heard, qty: m.qty, t_start: m.t_start, t_end: m.t_end, ord: m.ord }))

    return new Response(JSON.stringify({
      mode, items, mentions, transcript,
      conf_min: confMin, blank_transcript: blankTranscript,
      dropped_no_qty, dropped_low_conf, dropped_phantom_mention, fuzzy_filled,
      // echoed back unchanged for the caller's own idempotency/session bookkeeping
      session_key: body.session_key ?? null,
      recording_seq: typeof body.recording_seq === 'number' ? body.recording_seq : null,
      window_offset_sec: windowOffset,
      stage: body.stage ?? null,
    }), { headers: { ...cors, 'Content-Type': 'application/json' } })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[voice-receive] FAILED:', msg)
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
