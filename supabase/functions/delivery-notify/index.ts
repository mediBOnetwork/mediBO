import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Delivery messages to the customer: OTP, out-for-delivery with a tracking link,
// and the proof-of-delivery receipt. Separate function so nothing here can affect
// order-notify or order-unfulfilled-notify.
//
// CHANGE #295 — this function is now the FREE-FORM path only. Every caller goes
// through wa_notify_event() first, which sends the approved template unless the
// customer's 24h window is genuinely open. `out_one` exists because the 24h
// window is per customer: the run-level blast made one decision for everybody.
//
// CHANGE #354 (register row 89) — the OTP no longer lives on deliveries.otp_code.
// That column is readable by the assigned rider (RLS deliveries_read grants the
// rider the whole row), so the rider could read the customer's code and sign for
// them. The code now lives in delivery_otp, a table with RLS on and no policies:
// only the service role (this function) and SECURITY DEFINER functions can read
// it. Never put the code back on the deliveries row — a CHECK constraint on
// deliveries.otp_code enforces that from the database side.

const NOTIFY_SECRET = 'medibo_order_notify_2027';
const WA_TOKEN_HARDCODED='EAARb70T6u7sBR775DNCsEMQLBZBxQbZAVXFtOs5ZBZAAp1NezedqnFzeZAOWN4puSZCVXZBmSj5OWDHAb3ko2IwX96ocuK7HUnDcgvh2XqMwGJG1LutM4ayrN2ZCsAIlVdfZCt8Tpzof0QvWlzpIaHPFmG2qGZA6ItJODC9BLe60ZArqG3y4xzVZBjFvc2bXVtF7ZA9GjZAEmrnev4NwaCH23HZBBLN130UfCZC7hgVK2X4jM2q8VuQc7mMZBsnRpSWHoWen1qZCXBiZCRBKm2z2ZB34eqMhtc3dJ8nG06rC3XI8rXWFtSIZD';
const WA_TOKEN = ((Deno.env.get('WHATSAPP_TOKEN') ?? '').trim()) || WA_TOKEN_HARDCODED;
const PHONE_ID_RAW = (Deno.env.get('WHATSAPP_PHONE_ID') ?? '').trim();
const PHONE_ID = /^[0-9]{6,}$/.test(PHONE_ID_RAW) ? PHONE_ID_RAW : '1157319300801672';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
const SITE = 'https://medibo.in';

function phone10(s: string): string {
  const parts = String(s || '').split(/[,\/;\s]+/);
  for (const p of parts) { const d = p.replace(/[^0-9]/g, ''); if (d.length >= 10) return d.slice(-10); }
  return '';
}

async function sendText(to: string, body: string) {
  try {
    const r = await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ messaging_product: 'whatsapp', recipient_type: 'individual', to,
                             type: 'text', text: { preview_url: true, body } }),
    });
    const j = await r.json();
    return { ok: r.ok, id: j?.messages?.[0]?.id ?? null, err: r.ok ? null : j };
  } catch (e) { return { ok: false, id: null, err: String(e) }; }
}

function waFailReason(sent: any): string | null {
  if (!sent?.err) return null;
  if (typeof sent.err === 'string') return sent.err;
  return sent.err?.error?.message || JSON.stringify(sent.err);
}

async function log(to: string, body: string, sent: any, routed: string) {
  try {
    await supabase.from('whatsapp_messages').insert({
      sender_phone: to, sender_type: 'customer', direction: 'out', msg_type: 'text',
      text_body: body, wa_message_id: sent?.id ?? null,
      routed_to: sent?.ok ? routed : routed + '_error',
      received_at: new Date().toISOString(),
      wa_status: sent?.id ? 'accepted' : 'failed',
      wa_status_at: new Date().toISOString(),
      // CHANGE #295: a failure with no reason is a failure nobody can retry.
      wa_fail_reason: sent?.id ? null : waFailReason(sent),
      raw_payload: sent?.err ? { error: sent.err } : null,
    });
  } catch (_) { /* logging must never break a send */ }
}

async function tmpl(key: string, fallback: string): Promise<string> {
  try {
    const { data } = await supabase.from('app_settings').select('value').eq('key', key).maybeSingle();
    if (data && typeof data.value === 'string' && data.value.trim()) return data.value;
  } catch (_) {}
  return fallback;
}

// one delivery -> { phone, pharmacy, order_code, qr_token, rider }
async function loadDelivery(id: string) {
  const { data: d } = await supabase.from('deliveries')
    .select('id, order_id, qr_token, delivered_at, proof_method, partner_id')
    .eq('id', id).maybeSingle();
  if (!d) return null;
  const { data: o } = await supabase.from('orders')
    .select('id, order_code, pharmacy_name, phone, customer_id').eq('id', d.order_id).maybeSingle();
  let ph = phone10(String(o?.phone ?? ''));
  if (!ph && o?.customer_id) {
    const { data: pp } = await supabase.from('pharmacy_profiles')
      .select('phone, pharmacy_name').eq('id', o.customer_id).maybeSingle();
    ph = phone10(String(pp?.phone ?? ''));
  }
  let rider = '';
  if (d.partner_id) {
    const { data: rp } = await supabase.from('delivery_partner_registrations')
      .select('full_name, phone').eq('id', d.partner_id).maybeSingle();
    rider = String(rp?.full_name ?? '');
  }
  return { d, o, phone: ph, rider };
}

// CHANGE #354 (row 89): the code, read from the protected side table. Only the
// service role can see this — the rider cannot, which is the entire point.
async function loadOtp(deliveryId: string): Promise<string> {
  const { data } = await supabase.from('delivery_otp')
    .select('code').eq('delivery_id', deliveryId).maybeSingle();
  return String(data?.code ?? '');
}

async function sendOutForDelivery(ctx: any, body: string): Promise<boolean> {
  const link = `${SITE}/track/${ctx.d.qr_token ?? ''}`;
  const text = body.replace(/\{pharmacy\}/g, String(ctx.o?.pharmacy_name ?? ''))
                   .replace(/\{code\}/g, String(ctx.o?.order_code ?? ''))
                   .replace(/\{rider\}/g, ctx.rider)
                   .replace(/\{link\}/g, link);
  const sent = await sendText('91' + ctx.phone, text);
  await log('91' + ctx.phone, text, sent, 'delivery_out');
  return !!sent.ok;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  if ((req.headers.get('x-notify-secret') || '') !== NOTIFY_SECRET)
    return new Response('Forbidden', { status: 403 });

  let body: any;
  try { body = await req.json(); } catch { return new Response('bad json', { status: 200 }); }
  const event = String(body?.event || '').trim();

  // ---------- OTP ----------
  if (event === 'otp') {
    const ctx = await loadDelivery(String(body?.delivery_id || ''));
    if (!ctx) return new Response(JSON.stringify({ skipped: 'not_found' }), { status: 200 });
    if (!ctx.phone) return new Response(JSON.stringify({ skipped: 'no_phone' }), { status: 200 });
    const otp = await loadOtp(ctx.d.id);
    if (!otp) return new Response(JSON.stringify({ skipped: 'no_otp' }), { status: 200 });
    const t = await tmpl('delivery_otp_message',
      'Namaste {pharmacy}, aapke order {code} ki delivery ke liye OTP hai: *{otp}*\n\nYe OTP sirf delivery partner ko batayein.');
    const text = t.replace(/\{pharmacy\}/g, String(ctx.o?.pharmacy_name ?? ''))
                  .replace(/\{code\}/g, String(ctx.o?.order_code ?? ''))
                  .replace(/\{otp\}/g, otp)
                  .replace(/\{rider\}/g, ctx.rider);
    const sent = await sendText('91' + ctx.phone, text);
    await log('91' + ctx.phone, text, sent, 'delivery_otp');
    return new Response(JSON.stringify({ ok: sent.ok, event, to: ctx.phone }), { status: 200 });
  }

  // ---------- proof of delivery ----------
  if (event === 'delivered') {
    const ctx = await loadDelivery(String(body?.delivery_id || ''));
    if (!ctx) return new Response(JSON.stringify({ skipped: 'not_found' }), { status: 200 });
    if (!ctx.phone) return new Response(JSON.stringify({ skipped: 'no_phone' }), { status: 200 });
    const t = await tmpl('delivery_delivered_message',
      '✅ *Delivered*\n\n{pharmacy}, aapka order {code} deliver ho gaya hai.\n\nDhanyavaad — mediBO');
    const text = t.replace(/\{pharmacy\}/g, String(ctx.o?.pharmacy_name ?? ''))
                  .replace(/\{code\}/g, String(ctx.o?.order_code ?? ''))
                  .replace(/\{rider\}/g, ctx.rider);
    const sent = await sendText('91' + ctx.phone, text);
    await log('91' + ctx.phone, text, sent, 'delivery_delivered');
    return new Response(JSON.stringify({ ok: sent.ok, event, to: ctx.phone }), { status: 200 });
  }

  // ---------- out for delivery: ONE customer (CHANGE #295) ----------
  // delivery_start_run now asks wa_notify_event() per delivery, so the window is
  // judged per customer and this endpoint only ever writes the free-form copy.
  if (event === 'out_one') {
    const ctx = await loadDelivery(String(body?.delivery_id || ''));
    if (!ctx) return new Response(JSON.stringify({ skipped: 'not_found' }), { status: 200 });
    if (!ctx.phone) return new Response(JSON.stringify({ skipped: 'no_phone' }), { status: 200 });
    const t = await tmpl('delivery_out_message',
      '🚚 *Out for delivery*\n\n{pharmacy}, aapka order {code} raaste mein hai.\nDelivery partner: {rider}\n\nLive track: {link}');
    const ok = await sendOutForDelivery(ctx, t);
    return new Response(JSON.stringify({ ok, event, to: ctx.phone }), { status: 200 });
  }

  // ---------- out for delivery: every customer on the run (legacy) ----------
  if (event === 'out_for_delivery') {
    const runId = String(body?.run_id || '');
    if (!runId) return new Response(JSON.stringify({ skipped: 'no_run' }), { status: 200 });
    const { data: rows } = await supabase.from('deliveries')
      .select('id').eq('run_id', runId).eq('status', 'out_for_delivery');
    let sentN = 0, skipped = 0;
    const t = await tmpl('delivery_out_message',
      '🚚 *Out for delivery*\n\n{pharmacy}, aapka order {code} raaste mein hai.\nDelivery partner: {rider}\n\nLive track: {link}');
    for (const r of (rows ?? [])) {
      const ctx = await loadDelivery(r.id);
      if (!ctx || !ctx.phone) { skipped++; continue; }
      if (await sendOutForDelivery(ctx, t)) sentN++; else skipped++;
    }
    return new Response(JSON.stringify({ ok: true, event, sent: sentN, skipped }), { status: 200 });
  }

  return new Response(JSON.stringify({ skipped: 'unknown_event', event }), { status: 200 });
});
