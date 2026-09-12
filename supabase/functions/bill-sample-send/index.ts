// CHANGE #236 — send the SAMPLE customer bill on WhatsApp, exactly the way a
// real customer receives one.
//
// It does not invent an invoice: it asks bill-render for the sample (which
// renders customer_bill_sample() through the SAME code that draws a real bill),
// then sends that PDF as a WhatsApp DOCUMENT with the same caption shape
// order-notify uses for `bill_to_customer`, and follows it with the payment-QR
// message for the sample amount through the SAME send-payment-qr function a
// customer's balance goes through.
//
// Free-form document first (that is what a customer inside the 24h service
// window gets); if Meta refuses because the window is closed, it falls back to
// the APPROVED `bill_to_customer` template with the same PDF as its document
// header — which is what a customer outside the window would receive.
//
// No order row is created, nothing is written to orders or bills. The only
// artefacts are the PDF under customer-bills/sample/ and the outbound rows in
// whatsapp_messages.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const NOTIFY_SECRET = 'medibo_order_notify_2027'
const WA_TOKEN_HARDCODED = 'EAARb70T6u7sBR775DNCsEMQLBZBxQbZAVXFtOs5ZBZAAp1NezedqnFzeZAOWN4puSZCVXZBmSj5OWDHAb3ko2IwX96ocuK7HUnDcgvh2XqMwGJG1LutM4ayrN2ZCsAIlVdfZCt8Tpzof0QvWlzpIaHPFmG2qGZA6ItJODC9BLe60ZArqG3y4xzVZBjFvc2bXVtF7ZA9GjZAEmrnev4NwaCH23HZBBLN130UfCZC7hgVK2X4jM2q8VuQc7mMZBsnRpSWHoWen1qZCXBiZCRBKm2z2ZB34eqMhtc3dJ8nG06rC3XI8rXWFtSIZD'
const WA_TOKEN = ((Deno.env.get('WHATSAPP_TOKEN') ?? '').trim()) || WA_TOKEN_HARDCODED
const PHONE_ID_RAW = (Deno.env.get('WHATSAPP_PHONE_ID') ?? '').trim()
const PHONE_ID = /^[0-9]{6,}$/.test(PHONE_ID_RAW) ? PHONE_ID_RAW : '1157319300801672'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const supabase = createClient(SUPABASE_URL, SERVICE_KEY)

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { 'Content-Type': 'application/json' } })

async function uploadMedia(bytes: Uint8Array, mime: string, fname: string): Promise<string | null> {
  try {
    const fd = new FormData()
    fd.append('messaging_product', 'whatsapp')
    fd.append('type', mime)
    fd.append('file', new Blob([bytes], { type: mime }), fname)
    const up = await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/media`, {
      method: 'POST', headers: { 'Authorization': `Bearer ${WA_TOKEN}` }, body: fd })
    return (await up.json())?.id ?? null
  } catch (_) { return null }
}

async function graph(payload: unknown) {
  const r = await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  })
  const j = await r.json()
  return { ok: r.ok, id: j?.messages?.[0]?.id ?? null, err: r.ok ? null : j }
}

function failReason(err: unknown): string | null {
  if (!err) return null
  if (typeof err === 'string') return err
  return (err as any)?.error?.message || JSON.stringify(err)
}

async function log(to: string, caption: string, sent: any, via: string, filePath: string | null, fname: string) {
  try {
    await supabase.from('whatsapp_messages').insert({
      sender_phone: to, sender_type: 'customer', direction: 'out',
      msg_type: via === 'text' ? 'text' : 'document',
      text_body: via === 'text' ? caption : null,
      caption: via === 'text' ? null : caption,
      file_path: filePath, media_bucket: filePath ? 'customer-bills' : null,
      mime_type: filePath ? 'application/pdf' : null, file_name: fname,
      wa_message_id: sent?.id ?? null,
      routed_to: sent?.ok ? 'bill_sample_to_customer' : 'bill_sample_to_customer_error',
      received_at: new Date().toISOString(),
      raw_payload: sent?.err ? { error: sent.err, via } : { via },
      wa_status: sent?.id ? 'accepted' : 'failed',
      wa_status_at: new Date().toISOString(),
      wa_fail_reason: sent?.id ? null : failReason(sent?.err),
    })
  } catch (_) { /* logging must never break the send */ }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)
  if ((req.headers.get('x-notify-secret') ?? '') !== NOTIFY_SECRET) return json({ error: 'forbidden' }, 403)

  try {
    const body = await req.json().catch(() => ({}))
    const ph10 = String(body?.phone ?? '').replace(/[^0-9]/g, '').slice(-10)
    if (ph10.length !== 10) return json({ ok: false, error: 'bad_phone' })
    const to = '91' + ph10
    const buyerName = String(body?.customer_name ?? 'Sunrise Medical Store (SAMPLE)')

    // 1. the real generator + the real renderer
    const rend = await fetch(`${SUPABASE_URL}/functions/v1/bill-render`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${SERVICE_KEY}`,
        'x-notify-secret': NOTIFY_SECRET,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ sample: true, stamp: String(body?.stamp ?? Date.now()) }),
    })
    const r = await rend.json()
    if (!r?.ok) return json({ ok: false, step: 'render', error: r?.error ?? 'render_failed' })

    const fname = String(r.name ?? 'mediBO-SAMPLE-Invoice.pdf')
    const invoiceNo = String(r.invoice_no ?? 'MB-SAMPLE-0001')
    const amount = Math.round(Number(r.remaining ?? 0))

    const { data: file, error: dlErr } = await supabase.storage.from('customer-bills').download(r.path)
    if (dlErr || !file) return json({ ok: false, step: 'download', error: dlErr?.message ?? 'no_file' })
    const bytes = new Uint8Array(await file.arrayBuffer())

    // 2. the document message — same caption shape as order-notify's bill_to_customer
    const caption = `\u{1F9FE} *Your bill — mediBO*\n\n*Order ID:* ${invoiceNo}`
    let sent: any = { ok: false, id: null, err: 'no_media_id' }
    let via = 'document'
    const mediaId = await uploadMedia(bytes, 'application/pdf', fname)
    if (mediaId) {
      sent = await graph({
        messaging_product: 'whatsapp', recipient_type: 'individual', to,
        type: 'document', document: { id: mediaId, caption, filename: fname },
      })
    }

    // 3. outside the 24h window Meta refuses free-form: fall back to the
    //    approved template, whose header IS this same PDF.
    if (!sent?.id) {
      const { data: signed } = await supabase.storage.from('customer-bills')
        .createSignedUrl(r.path, 60 * 60 * 24)
      const link = signed?.signedUrl ?? ''
      if (link) {
        via = 'template'
        sent = await graph({
          messaging_product: 'whatsapp', recipient_type: 'individual', to,
          type: 'template',
          template: {
            name: 'bill_to_customer', language: { code: 'en' },
            components: [
              { type: 'header', parameters: [{ type: 'document', document: { link, filename: fname } }] },
              { type: 'body', parameters: [{ type: 'text', text: buyerName }, { type: 'text', text: invoiceNo }] },
            ],
          },
        })
      }
    }
    await log(to, caption, sent, via, r.path, fname)

    // 4. the payment QR for the sample amount — the customer's own function
    let qr: any = { skipped: 'zero_amount' }
    if (amount > 0) {
      const qrRes = await fetch(`${SUPABASE_URL}/functions/v1/send-payment-qr`, {
        method: 'POST',
        headers: { 'x-notify-secret': NOTIFY_SECRET, 'Content-Type': 'application/json' },
        body: JSON.stringify({ phone: ph10, amount, kind: 'remaining', order_no: invoiceNo }),
      })
      qr = await qrRes.json().catch(() => ({ ok: false, error: 'bad_qr_reply' }))
    }

    return json({
      ok: !!sent?.id, to, via, invoice_no: invoiceNo, amount,
      bucket: 'customer-bills', path: r.path, name: fname, bytes: bytes.length,
      wa_message_id: sent?.id ?? null, wa_error: sent?.err ?? null, qr,
    })
  } catch (err) {
    return json({ ok: false, error: err instanceof Error ? err.message : String(err) })
  }
})
