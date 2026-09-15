// bill-vault-ocr — CMD #423, the reader behind all three vault doors.
//
// A Tier-0 pharmacy has no software and no export. It has a drawer of bills.
// This function turns a photographed bill into DRAFT lines a human confirms —
// it never writes a lot, never invents a value, and never decides a model.
//
// THREE THINGS IT DELIBERATELY DOES NOT DO:
//   * It does not hold the prompt. That lives in ui_copy
//     (`phvault.prompt_bill` / `phvault.prompt_shelf`), handed over by
//     pharmacy_vault_ocr_input(), so a hostile-photo lesson — "this is thermal
//     paper", "the middle column may be a carbon smear" — is an UPDATE and not
//     a redeploy.
//   * It does not choose a model or an endpoint. gemini-ocr is the ONE place
//     gemini-3.5-flash, the Vertex global endpoint and GCP_SA_KEY auth live.
//   * It does not repair a bad read. A line the model could not read comes back
//     `readable: false` and is stored that way. Flagging is the feature.
//
// MULTI-SHOT. Every shot of one bill is downloaded and handed over TOGETHER, in
// shot order, as one document — which is the only way a metre of thermal roll
// or a creased carbon copy reads correctly.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const OCR_FN       = `${SUPABASE_URL}/functions/v1/gemini-ocr`

/** Gemini answers with JSON; a stray fence or a sentence around it must not turn
 *  a good read into a failed bill. Pull the object out and parse that. */
function parseObject(text: string): Record<string, unknown> | null {
  const cleaned = (text ?? '').replace(/```json/gi, '').replace(/```/g, '').trim()
  const start = cleaned.indexOf('{')
  const end = cleaned.lastIndexOf('}')
  if (start < 0 || end <= start) return null
  try {
    const parsed = JSON.parse(cleaned.slice(start, end + 1))
    return (parsed && typeof parsed === 'object') ? parsed as Record<string, unknown> : null
  } catch (_e) {
    return null
  }
}

function b64(bytes: Uint8Array): string {
  let s = ''
  const chunk = 0x8000
  for (let i = 0; i < bytes.length; i += chunk) {
    s += String.fromCharCode(...bytes.subarray(i, i + chunk))
  }
  return btoa(s)
}

// deno-lint-ignore no-explicit-any
async function callOcr(payload: Record<string, unknown>): Promise<any> {
  const res = await fetch(OCR_FN, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${SERVICE_KEY}` },
    body: JSON.stringify(payload),
  })
  if (!res.ok) throw new Error(`ocr ${res.status}: ${(await res.text()).slice(0, 300)}`)
  return await res.json()
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  const db = createClient(SUPABASE_URL, SERVICE_KEY)
  let billId = ''

  // Every failure reports itself onto the bill row, so the screen shows the
  // backend's own words instead of a spinner that never stops.
  const fail = async (message: string, status = 500) => {
    if (billId) {
      await db.rpc('pharmacy_vault_ocr_report', {
        p_bill_id: billId, p_payload: {}, p_error: message,
      })
    }
    return new Response(JSON.stringify({ ok: false, error: message }), {
      status, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }

  try {
    const body = await req.json() as { bill_id?: string; mode?: string }

    // ── MODE: EMBED ─────────────────────────────────────────────────────────
    // The lazy vector backfill. Names only — never a price, never a pharmacy.
    if (body.mode === 'embed') {
      const { data: input, error: inErr } = await db.rpc('pharmacy_vault_embed_input')
      if (inErr) throw new Error(inErr.message)
      const rows = (input?.rows ?? []) as Array<{ text_key: string; text: string; medicine_id: number | null }>
      if (rows.length === 0) {
        return new Response(JSON.stringify({ ok: true, embedded: 0 }), {
          headers: { ...cors, 'Content-Type': 'application/json' },
        })
      }
      let out: { vectors?: number[][]; model?: string }
      try {
        out = await callOcr({ mode: 'embed', texts: rows.map((r) => r.text) })
      } catch (e) {
        await db.rpc('pharmacy_vault_embed_report', {
          p_rows: [], p_error: e instanceof Error ? e.message : String(e),
        })
        throw e
      }
      const vectors = out.vectors ?? []
      const stored = rows
        .map((r, i) => ({ ...r, embedding: vectors[i] }))
        .filter((r) => Array.isArray(r.embedding) && r.embedding.length > 0)
        .map((r) => ({
          text_key: r.text_key,
          text: r.text,
          medicine_id: r.medicine_id,
          embedding: `[${(r.embedding as number[]).join(',')}]`,
          model: out.model ?? 'gemini-embedding-001',
        }))
      const { data: rep, error: repErr } =
        await db.rpc('pharmacy_vault_embed_report', { p_rows: stored, p_error: null })
      if (repErr) throw new Error(repErr.message)
      return new Response(JSON.stringify({ ok: true, embedded: rep?.stored ?? 0 }), {
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    // ── MODE: READ A BILL ───────────────────────────────────────────────────
    billId = body.bill_id ?? ''
    if (!billId) return await fail('bill_id required', 400)

    const { data: input, error: inErr } =
      await db.rpc('pharmacy_vault_ocr_input', { p_bill_id: billId })
    if (inErr) return await fail(inErr.message)
    if (!input?.ok) return await fail('bill not found', 404)

    const shots = (input.shots ?? []) as Array<{ shot_no: number; bucket: string; path: string }>
    if (shots.length === 0) return await fail('no photos on this bill', 400)

    // Every shot, in order, as ONE document.
    const images: Array<{ base64: string; mime_type: string }> = []
    for (const s of shots) {
      const { data: file, error: dlErr } = await db.storage.from(s.bucket).download(s.path)
      if (dlErr || !file) {
        // A single unreadable frame must not sink the whole bill: the others
        // are still a bill, and the missing section shows up as flagged lines.
        await db.from('pharmacy_bill_shot')
          .update({ status: 'unreadable', note: dlErr?.message ?? 'not found' })
          .eq('bill_id', billId).eq('shot_no', s.shot_no)
        continue
      }
      images.push({
        base64: b64(new Uint8Array(await file.arrayBuffer())),
        mime_type: file.type || 'image/jpeg',
      })
      await db.from('pharmacy_bill_shot')
        .update({ status: 'read' }).eq('bill_id', billId).eq('shot_no', s.shot_no)
    }
    if (images.length === 0) return await fail('none of the photos could be opened')

    const { text, error } = await callOcr({ images, prompt: input.prompt }) as
      { text?: string; error?: string }
    if (error) return await fail(error)

    const payload = parseObject(text ?? '')
    if (!payload) return await fail('the photos could not be read as a bill')

    const { data: report, error: repErr } = await db.rpc('pharmacy_vault_ocr_report', {
      p_bill_id: billId, p_payload: payload, p_error: null,
    })
    if (repErr) return await fail(repErr.message)

    return new Response(JSON.stringify({ ok: true, ...(report ?? {}) }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return await fail(err instanceof Error ? err.message : String(err))
  }
})
