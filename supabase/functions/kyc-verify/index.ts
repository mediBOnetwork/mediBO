// CHANGE #706 — read a KYC document, then hand the fields back to the database.
//
// This function decides NOTHING. It downloads one private document, asks the
// one Vertex model mediBO uses (through gemini-ocr, which is the single place a
// model, an endpoint and a credential are named), geocodes the address that was
// printed on it, and posts both back to kyc_ocr_ingest(). Every comparison,
// every threshold and every verdict is SQL.
//
// It is idempotent and bounded by design: kyc_ocr_claim() only hands out a
// document whose extract row is still queued and under three attempts, so a
// repeated call is a no-op rather than a repeated model bill.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const SUPA = Deno.env.get('SUPABASE_URL') ?? ''
const OCR_EDGE_FN = `${SUPA}/functions/v1/gemini-ocr`
const NOMINATIM = 'https://nominatim.openstreetmap.org/search'

// VERBATIM-ONLY CONTRACT. The extractor copies what is printed and nothing
// else: no expansion of an abbreviated firm name, no "correcting" a licence
// number to a plausible one, no world knowledge about who owns whom. A field
// it cannot read is an empty string, never a guess — an empty field is handled
// (the check is skipped and a person looks), an invented one is a false pass.
const RULES = `
PURE EXTRACTION CONTRACT — read before anything else:
Copy text exactly as printed. You are a camera, not a database.
FORBIDDEN:
  x Expanding or normalising a business name (write what the paper says)
  x Correcting, completing or reformatting a licence / GSTIN / PAN number
  x Substituting a parent, group, acquirer or successor company
  x Any world knowledge about the holder
If a field is not visible, return "" for it. An empty field is correct; a guess is not.
Return ONLY a JSON object, no markdown, no fences, no commentary.`

const PROMPTS: Record<string, string> = {
  drug_licence: `This image is an Indian retail/wholesale DRUG LICENCE (Form 20/21/20B/21B or a state equivalent).
Return this exact JSON shape:
{"licence_number":"","licensee_name":"","address":"","valid_from":"","valid_to":"","issuing_authority":"","confidence":"high|medium|low"}
- licence_number: the licence number exactly as printed, separators included.
- licensee_name: the name of the firm/person the licence is issued to, verbatim.
- address: the premises address as printed, on one line.
- valid_from / valid_to: ISO yyyy-mm-dd, or "" if not printed.` + RULES,

  gst_certificate: `This image is an Indian GST REGISTRATION CERTIFICATE (Form GST REG-06).
Return this exact JSON shape:
{"gstin":"","legal_name":"","trade_name":"","address":"","valid_from":"","valid_to":"","confidence":"high|medium|low"}
- gstin: the 15-character GSTIN exactly as printed.
- legal_name: "Legal Name" field, verbatim. trade_name: "Trade Name", verbatim ("" if absent).
- address: the principal place of business, on one line.
- valid_from / valid_to: ISO yyyy-mm-dd, or "" if not printed.` + RULES,

  pan: `This image is an Indian PAN card.
Return this exact JSON shape:
{"pan":"","name":"","father_name":"","dob":"","confidence":"high|medium|low"}
- pan: the 10-character permanent account number exactly as printed.` + RULES,
}

function b64(bytes: Uint8Array): string {
  let out = ''
  const chunk = 8190 // divisible by 3, so btoa never pads mid-string
  for (let i = 0; i < bytes.length; i += chunk) {
    out += btoa(String.fromCharCode(...bytes.subarray(i, i + chunk)))
  }
  return out
}

function mimeOf(path: string, declared: string): string {
  if (declared) return declared
  const ext = path.split('.').pop()?.toLowerCase() ?? ''
  const map: Record<string, string> = {
    pdf: 'application/pdf', jpg: 'image/jpeg', jpeg: 'image/jpeg',
    png: 'image/png', webp: 'image/webp', heic: 'image/heic',
  }
  return map[ext] ?? 'image/jpeg'
}

// The address printed on the document, turned into a point. Keyless on purpose:
// map_config carries browser and native Google keys, both referrer-restricted,
// and neither may be used server-side. The `source` travels with the answer so
// a fallback is never mistaken for an authoritative pin.
async function geocode(address: string): Promise<Record<string, unknown>> {
  const q = address.trim()
  if (q.length < 12) return { source: 'none', reason: 'address_too_short' }
  try {
    const url = `${NOMINATIM}?format=json&limit=1&countrycodes=in&q=${encodeURIComponent(q)}`
    const res = await fetch(url, { headers: { 'User-Agent': 'mediBO/1.0 (medibo.in)' } })
    if (!res.ok) return { source: 'none', reason: `http_${res.status}` }
    const rows = await res.json() as Array<{ lat?: string; lon?: string; display_name?: string }>
    if (!rows?.length || !rows[0].lat || !rows[0].lon) return { source: 'none', reason: 'no_match' }
    return {
      source: 'osm',
      lat: Number(rows[0].lat),
      lng: Number(rows[0].lon),
      matched: rows[0].display_name ?? '',
      query: q,
    }
  } catch (e) {
    return { source: 'none', reason: e instanceof Error ? e.message : String(e) }
  }
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  const supabase = createClient(SUPA, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  let docId = ''

  try {
    const body = await req.json().catch(() => ({})) as { doc_id?: string; record?: { id?: string } }
    const wanted = body.doc_id ?? body.record?.id ?? null

    // Claiming IS the guard. A document already read, already running, or past
    // three attempts is simply not handed out.
    const { data: claim, error: claimErr } = await supabase
      .rpc('kyc_ocr_claim', { p_doc_id: wanted })
    if (claimErr) throw new Error(`claim failed: ${claimErr.message}`)
    if (!claim?.ok) {
      return new Response(JSON.stringify({ skipped: true, reason: claim?.error ?? 'none_queued' }), {
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    docId = claim.doc_id as string
    const kind = claim.kind as string
    const prompt = PROMPTS[kind]
    if (!prompt) {
      await supabase.rpc('kyc_ocr_ingest', {
        p_doc_id: docId, p_status: 'skipped', p_error: `no prompt for kind ${kind}`,
      })
      return new Response(JSON.stringify({ skipped: true, reason: 'unsupported_kind' }), {
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    const { data: blob, error: dlErr } = await supabase.storage
      .from(claim.bucket as string)
      .download(claim.path as string)
    if (dlErr || !blob) throw new Error(`download failed: ${dlErr?.message ?? 'empty'}`)

    const bytes = new Uint8Array(await blob.arrayBuffer())
    const mime = mimeOf(claim.path as string, (claim.mime_type as string) ?? '')

    const ocrRes = await fetch(OCR_EDGE_FN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ image_base64: b64(bytes), mime_type: mime, prompt }),
    })
    if (!ocrRes.ok) throw new Error(`ocr http ${ocrRes.status}: ${(await ocrRes.text()).slice(0, 300)}`)
    const raw = ((await ocrRes.json()) as { text?: string }).text ?? ''
    const match = raw.match(/\{[\s\S]*\}/)
    if (!match) throw new Error(`no JSON in model reply: ${raw.slice(0, 200)}`)
    const fields = JSON.parse(match[0]) as Record<string, unknown>

    // The address ON THE DOCUMENT is what the geo check is about. The account's
    // own address proves nothing — it is the thing being checked.
    const printed = String(fields.address ?? '').trim()
    const geo = printed ? await geocode(printed) : { source: 'none', reason: 'no_address' }

    const { data: ingest, error: ingErr } = await supabase.rpc('kyc_ocr_ingest', {
      p_doc_id: docId,
      p_status: 'done',
      p_fields: fields,
      p_geo: geo,
      p_raw: raw.slice(0, 8000),
      p_model: 'gemini-3.5-flash',
    })
    if (ingErr) throw new Error(`ingest failed: ${ingErr.message}`)

    return new Response(JSON.stringify({ ok: true, doc_id: docId, verdict: ingest?.verdict ?? null }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    // A failed read is not a silent hole: the extract row records the failure,
    // the attempt is counted, and kyc_ocr_sweep files the document into the
    // manual queue once it has genuinely given up.
    if (docId) {
      try {
        await supabase.rpc('kyc_ocr_ingest', {
          p_doc_id: docId, p_status: 'failed', p_error: msg.slice(0, 500),
        })
      } catch (_e) { /* the sweep will retry */ }
    }
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
