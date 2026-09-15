// stock-ocr — CMD #412, the photo door into opening stock.
//
// A pharmacy joining mediBO already keeps a stock register: a ledger book, a
// printed sheet, an old software export they photograph. This reads one page of
// it into DRAFT rows that a human confirms before anything touches the shelf.
// The camera is not a database — nothing here writes stock, it only proposes.
//
// The prompt is NOT in this file: it lives in ui_copy under
// `phstock.ocr_prompt`, handed over by pharmacy_stock_import_ocr_input(), so it
// can be tuned with an UPDATE instead of a redeploy. It carries the OCR naming
// rule verbatim — read what is printed, expand nothing, correct nothing, never
// use world knowledge about medicine names.
//
// Gemini is reached through the shared gemini-ocr function, which is the ONE
// place the model, the endpoint and the GCP_SA_KEY auth live (gemini-3.5-flash
// on the Vertex global endpoint). Nothing about the model is decided here.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const OCR_FN       = `${SUPABASE_URL}/functions/v1/gemini-ocr`

/** Gemini answers with JSON; a stray code fence or a sentence around it must not
 *  turn a good read into a failed import. Pull the array out and parse that. */
function parseRows(text: string): Array<Record<string, unknown>> {
  const cleaned = (text ?? '').replace(/```json/gi, '').replace(/```/g, '').trim()
  const start = cleaned.indexOf('[')
  const end = cleaned.lastIndexOf(']')
  if (start < 0 || end <= start) return []
  const parsed = JSON.parse(cleaned.slice(start, end + 1))
  return Array.isArray(parsed) ? parsed : []
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
  let importId = ''

  // Every failure below reports itself back onto the import row, so the screen
  // shows the backend's own words instead of spinning forever.
  const fail = async (message: string, status = 500) => {
    if (importId) {
      await db.rpc('pharmacy_stock_import_ocr_report', {
        p_import_id: importId, p_rows: [], p_error: message,
      })
    }
    return new Response(JSON.stringify({ ok: false, error: message }), {
      status, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }

  try {
    const body = await req.json() as { import_id?: string }
    importId = body.import_id ?? ''
    if (!importId) return await fail('import_id required', 400)

    const { data: input, error: inErr } =
      await db.rpc('pharmacy_stock_import_ocr_input', { p_import_id: importId })
    if (inErr) return await fail(inErr.message)
    if (!input?.ok) return await fail('import not found', 404)
    if (!input.bucket || !input.path) return await fail('no photo on this import', 400)

    const { data: file, error: dlErr } =
      await db.storage.from(input.bucket).download(input.path)
    if (dlErr || !file) return await fail(dlErr?.message ?? 'could not read the photo')

    const bytes = new Uint8Array(await file.arrayBuffer())
    const res = await fetch(OCR_FN, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${SERVICE_KEY}`,
      },
      body: JSON.stringify({
        image_base64: b64(bytes),
        mime_type: file.type || 'image/jpeg',
        prompt: input.prompt,
      }),
    })
    if (!res.ok) return await fail(`ocr ${res.status}: ${(await res.text()).slice(0, 300)}`)

    const { text, error } = await res.json() as { text?: string; error?: string }
    if (error) return await fail(error)

    let rows: Array<Record<string, unknown>>
    try {
      rows = parseRows(text ?? '')
    } catch (_e) {
      return await fail('the photo could not be read as a stock list')
    }
    if (rows.length === 0) return await fail('no stock lines were found on that page')

    // Straight into the DRAFT table. The apply step is a separate, human one.
    const { data: report, error: repErr } =
      await db.rpc('pharmacy_stock_import_ocr_report', {
        p_import_id: importId, p_rows: rows, p_error: null,
      })
    if (repErr) return await fail(repErr.message)

    return new Response(JSON.stringify({ ok: true, rows: report?.rows ?? rows.length }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return await fail(err instanceof Error ? err.message : String(err))
  }
})
