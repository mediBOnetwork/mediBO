// paper-sale-ocr — CMD #429, the handwriting reader behind the paper sale pad.
//
// Same shape as #423's bill-vault-ocr, and deliberately so: the prompt lives in
// ui_copy (`paper429.prompt`), the model and the Vertex endpoint are decided
// only inside gemini-ocr, and this function neither repairs a bad read nor
// writes a single unit of stock. It reads pages and reports lines; a human
// confirms, and only then does anything leave a shelf.
//
// IN-APP ONLY. There is no WhatsApp ingress here and none is planned — Om was
// explicit. The only caller is paper_sale_queue() via pg_net.
//
// MULTI-PAGE. Every photo of the pad is handed over together, in shot order, so
// the model reads a multi-page pad as one document and keeps the written order.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const OCR_FN       = `${SUPABASE_URL}/functions/v1/gemini-ocr`

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

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  const db = createClient(SUPABASE_URL, SERVICE_KEY)
  let sheetId = ''

  const fail = async (message: string, status = 500) => {
    if (sheetId) {
      await db.rpc('paper_sale_ocr_report', {
        p_sheet_id: sheetId, p_payload: {}, p_error: message,
      })
    }
    return new Response(JSON.stringify({ ok: false, error: message }), {
      status, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }

  try {
    const body = await req.json() as { sheet_id?: string }
    sheetId = body.sheet_id ?? ''
    if (!sheetId) return await fail('sheet_id required', 400)

    const { data: input, error: inErr } =
      await db.rpc('paper_sale_ocr_input', { p_sheet_id: sheetId })
    if (inErr) return await fail(inErr.message)
    if (!input?.ok) return await fail('sheet not found', 404)

    const shots = (input.shots ?? []) as Array<{ shot_no: number; bucket: string; path: string }>
    if (shots.length === 0) return await fail('no photos on this page', 400)

    const images: Array<{ base64: string; mime_type: string }> = []
    for (const s of shots) {
      const { data: file, error: dlErr } = await db.storage.from(s.bucket).download(s.path)
      if (dlErr || !file) {
        // One unopenable frame must not sink the pad: the rest is still a pad,
        // and the missing page shows up as lines that were never read.
        await db.from('pharmacy_sale_shot')
          .update({ status: 'unreadable', note: dlErr?.message ?? 'not found' })
          .eq('sheet_id', sheetId).eq('shot_no', s.shot_no)
        continue
      }
      images.push({
        base64: b64(new Uint8Array(await file.arrayBuffer())),
        mime_type: file.type || 'image/jpeg',
      })
      await db.from('pharmacy_sale_shot')
        .update({ status: 'read' }).eq('sheet_id', sheetId).eq('shot_no', s.shot_no)
    }
    if (images.length === 0) return await fail('none of the photos could be opened')

    const res = await fetch(OCR_FN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${SERVICE_KEY}` },
      body: JSON.stringify({ images, prompt: input.prompt }),
    })
    if (!res.ok) return await fail(`ocr ${res.status}: ${(await res.text()).slice(0, 300)}`)

    const { text, error } = await res.json() as { text?: string; error?: string }
    if (error) return await fail(error)

    const payload = parseObject(text ?? '')
    if (!payload) return await fail('that page could not be read as a sale list')

    // A struck-through line was cancelled at the counter. It is dropped HERE,
    // where the model's own flag says so — never guessed at later.
    if (Array.isArray(payload.lines)) {
      payload.lines = (payload.lines as Array<Record<string, unknown>>)
        .filter((l) => l?.struck !== true)
    }

    const { data: report, error: repErr } = await db.rpc('paper_sale_ocr_report', {
      p_sheet_id: sheetId, p_payload: payload, p_error: null,
    })
    if (repErr) return await fail(repErr.message)

    return new Response(JSON.stringify({ ok: true, ...(report ?? {}) }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return await fail(err instanceof Error ? err.message : String(err))
  }
})
