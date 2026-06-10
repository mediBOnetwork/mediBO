import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const OCR_EDGE_FN = 'https://svojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr'

/** Extract bare email from "Display Name <email@example.com>" or plain "email@example.com" */
function extractEmail(raw: string): string {
  const trimmed = (raw ?? '').trim()
  const match = trimmed.match(/<([^>]+)>/)
  return (match ? match[1] : trimmed).toLowerCase().trim()
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  let billId = ''
  try {
    const payload = await req.json()
    const record = payload.record ?? payload
    billId = record.id
    const filePath: string = record.file_path
    const senderEmail: string = extractEmail(record.sender_email ?? '')

    if (!billId || !filePath) {
      return new Response(JSON.stringify({ error: 'Missing id or file_path' }), {
        status: 400, headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    // ── Idempotency: skip rows already done ──────────────────────────────────
    const { data: existing } = await supabase
      .from('pending_bills')
      .select('scan_status')
      .eq('id', billId)
      .single()

    if (existing?.scan_status === 'done') {
      return new Response(JSON.stringify({ skipped: true, reason: 'already_done' }), {
        headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    // ── Mark scanning ────────────────────────────────────────────────────────
    await supabase
      .from('pending_bills')
      .update({ scan_status: 'scanning' })
      .eq('id', billId)

    // ── Download file ────────────────────────────────────────────────────────
    const { data: blob, error: dlErr } = await supabase.storage
      .from('supplier-bills')
      .download(filePath)
    if (dlErr || !blob) throw new Error(`Download failed: ${dlErr?.message}`)

    const buf = await blob.arrayBuffer()
    const bytes = new Uint8Array(buf)
    let b64 = ''
    const chunkSize = 8190 // divisible by 3 so btoa() never adds mid-string padding
    for (let i = 0; i < bytes.length; i += chunkSize) {
      b64 += btoa(String.fromCharCode(...bytes.subarray(i, i + chunkSize)))
    }

    const ext = filePath.split('.').pop()?.toLowerCase() ?? ''
    const mimeMap: Record<string, string> = {
      pdf: 'application/pdf',
      jpg: 'image/jpeg', jpeg: 'image/jpeg',
      png: 'image/png', webp: 'image/webp',
      gif: 'image/gif',
    }
    const mime = mimeMap[ext] ?? 'application/pdf'

    // ── Fetch known suppliers ────────────────────────────────────────────────
    const { data: suppliers } = await supabase.from('suppliers').select('id,name,gst,dl,emails')
    const suppListJson = JSON.stringify(suppliers ?? [])

    // ── Build prompt ─────────────────────────────────────────────────────────
    const prompt = `You are a supplier invoice verification system for an Indian B2B pharmacy platform.

Analyse the attached bill/invoice image or PDF and return ONLY a valid JSON object (no markdown, no fences).

Extract:
- supplier_name: the seller/supplier company name (string, empty string if not found)
- gst: GST number of the supplier (string, 15-char alphanumeric, empty if not found)
- dl: Drug Licence number of the supplier (string, empty if not found)
- total: invoice grand total as a number (null if not found)
- line_items: array of {name, qty, rate, amount} objects
- reasoning: brief explanation of your matching decision

Known suppliers in our system:
${suppListJson}

Sender email of this bill (already extracted, no display name): "${senderEmail}"

Matching rules:
1. Compare extracted gst and dl (case-insensitive, trimmed) against each supplier.
2. verdict = "real" if:
   - extracted gst OR dl matches a known supplier's gst/dl
   - AND sender_email is in that supplier's emails array (case-insensitive)
3. verdict = "needs_approval" if:
   - extracted gst OR dl matches a known supplier
   - BUT sender_email is NOT in that supplier's emails array
4. verdict = "fake" if:
   - no supplier matches by gst or dl
   - (mismatch on name alone is not sufficient — gst/dl must fail)

Also include:
- matched_supplier_id: the id of the matched supplier (null if fake)
- matched_supplier_name: name of matched supplier (null if fake)

Return exactly this JSON shape:
{
  "supplier_name": "",
  "gst": "",
  "dl": "",
  "total": null,
  "line_items": [],
  "matched_supplier_id": null,
  "matched_supplier_name": null,
  "verdict": "fake",
  "reasoning": ""
}`

    // ── Call OCR edge function ────────────────────────────────────────────────
    const ocrResp = await fetch(OCR_EDGE_FN, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ image_base64: b64, mime_type: mime, prompt }),
    })
    if (!ocrResp.ok) {
      const errText = await ocrResp.text()
      throw new Error(`OCR function HTTP ${ocrResp.status}: ${errText}`)
    }
    const ocrData = await ocrResp.json() as { text?: string }
    const rawText = ocrData.text ?? ''
    if (!rawText) throw new Error('Empty response from OCR function')

    // ── Parse response ───────────────────────────────────────────────────────
    const jsonMatch = rawText.match(/\{[\s\S]*\}/)
    if (!jsonMatch) throw new Error(`No JSON in OCR response. Raw: ${rawText.slice(0, 200)}`)
    const extracted = JSON.parse(jsonMatch[0]) as Record<string, unknown>

    const verdict: string = ['real', 'needs_approval', 'fake'].includes(extracted.verdict as string)
      ? (extracted.verdict as string)
      : 'fake'

    const scanResult = {
      supplier_name: extracted.supplier_name ?? '',
      gst: extracted.gst ?? '',
      dl: extracted.dl ?? '',
      total: extracted.total ?? null,
      line_items: extracted.line_items ?? [],
      matched_supplier_id: extracted.matched_supplier_id ?? null,
      matched_supplier_name: extracted.matched_supplier_name ?? null,
      reasoning: extracted.reasoning ?? '',
      sender_email_used: senderEmail,
      scanned_at: new Date().toISOString(),
    }

    // ── Write verdict + mark done ────────────────────────────────────────────
    const { error: updErr } = await supabase
      .from('pending_bills')
      .update({ verdict, scan_result: scanResult, scan_status: 'done' })
      .eq('id', billId)
    if (updErr) throw new Error(`DB update failed: ${updErr.message}`)

    console.log(`[scan-bill] Done: billId=${billId} verdict=${verdict}`)
    return new Response(JSON.stringify({ success: true, verdict, billId }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[scan-bill] error:', msg)
    if (billId) {
      try {
        await supabase
          .from('pending_bills')
          .update({ scan_status: 'error', scan_result: { error: msg, scanned_at: new Date().toISOString() } })
          .eq('id', billId)
      } catch (_) { /* best-effort */ }
    }
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
