import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })

  try {
    const payload = await req.json()
    // Accept both direct call and pg_net trigger payload shapes
    const record = payload.record ?? payload
    const billId: string = record.id
    const filePath: string = record.file_path
    const senderEmail: string = (record.sender_email ?? '').toLowerCase().trim()

    if (!billId || !filePath) {
      return new Response(JSON.stringify({ error: 'Missing id or file_path' }), {
        status: 400, headers: { ...cors, 'Content-Type': 'application/json' },
      })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )
    const geminiKey = Deno.env.get('GEMINI_API_KEY') ?? ''

    // ── Download file ───────────────────────────────────────────────────────
    const { data: blob, error: dlErr } = await supabase.storage
      .from('supplier-bills')
      .download(filePath)
    if (dlErr || !blob) throw new Error(`Download failed: ${dlErr?.message}`)

    const buf = await blob.arrayBuffer()
    const bytes = new Uint8Array(buf)
    // Base64 encode in chunks to avoid stack overflow
    let b64 = ''
    const chunkSize = 8192
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

    // ── Call Gemini ──────────────────────────────────────────────────────────
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

Sender email of this bill: "${senderEmail}"

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

    const geminiBody = {
      contents: [{ parts: [
        { inline_data: { mime_type: mime, data: b64 } },
        { text: prompt },
      ]}],
      generationConfig: {
        temperature: 0.1,
        maxOutputTokens: 4096,
        thinkingConfig: { thinkingBudget: 1024 },
      },
    }

    const gResp = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key=${geminiKey}`,
      { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(geminiBody) },
    )
    if (!gResp.ok) throw new Error(`Gemini HTTP ${gResp.status}: ${await gResp.text()}`)

    const gJson = await gResp.json()
    // Extract text, skipping thinking parts
    const cands = gJson.candidates ?? []
    const parts = (cands[0]?.content?.parts ?? []) as Array<{ text?: string; thought?: boolean }>
    const rawText = parts.filter(p => !p.thought).map(p => p.text ?? '').join('')

    // Parse JSON from Gemini response
    const jsonMatch = rawText.match(/\{[\s\S]*\}/)
    if (!jsonMatch) throw new Error('No JSON in Gemini response')
    const extracted = JSON.parse(jsonMatch[0])

    const verdict: string = ['real', 'needs_approval', 'fake'].includes(extracted.verdict)
      ? extracted.verdict
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
      scanned_at: new Date().toISOString(),
    }

    // ── Write verdict back to pending_bills ──────────────────────────────────
    const { error: updErr } = await supabase
      .from('pending_bills')
      .update({ verdict, scan_result: scanResult })
      .eq('id', billId)
    if (updErr) throw new Error(`DB update failed: ${updErr.message}`)

    return new Response(JSON.stringify({ success: true, verdict, billId }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    })
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[scan-bill]', msg)
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...cors, 'Content-Type': 'application/json' },
    })
  }
})
