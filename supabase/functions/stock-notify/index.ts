// CHANGE #639 PART E — stock-notify
//
// Cloned from inquiry-notify: same x-notify-secret gate, same supplier-phone
// resolution (explicit to_phone > whatsapp_no > contact_no > phone), same
// notif_should_send gate, same whatsapp_messages logging.
//
// Deliberately TEXT ONLY — the stock update is a short confirm-this-link ask,
// not a catalogue, so none of inquiry-notify's SVG/resvg image pipeline is
// carried over.
//
// Body: { supplier_name, token, to_phone? }
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const NOTIFY_SECRET = 'medibo_order_notify_2027';
const WA_TOKEN_HARDCODED = 'EAARb70T6u7sBR775DNCsEMQLBZBxQbZAVXFtOs5ZBZAAp1NezedqnFzeZAOWN4puSZCVXZBmSj5OWDHAb3ko2IwX96ocuK7HUnDcgvh2XqMwGJG1LutM4ayrN2ZCsAIlVdfZCt8Tpzof0QvWlzpIaHPFmG2qGZA6ItJODC9BLe60ZArqG3y4xzVZBjFvc2bXVtF7ZA9GjZAEmrnev4NwaCH23HZBBLN130UfCZC7hgVK2X4jM2q8VuQc7mMZBsnRpSWHoWen1qZCXBiZCRBKm2z2ZB34eqMhtc3dJ8nG06rC3XI8rXWFtSIZD';
const WA_TOKEN = ((Deno.env.get('WHATSAPP_TOKEN') ?? '').trim()) || WA_TOKEN_HARDCODED;
const PHONE_ID_RAW = (Deno.env.get('WHATSAPP_PHONE_ID') ?? '').trim();
const PHONE_ID = /^[0-9]{6,}$/.test(PHONE_ID_RAW) ? PHONE_ID_RAW : '1157319300801672';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// Config as data: the wording lives in app_settings.stock_update_wa_message.
// This literal is the fallback only, and matches the CHANGE #639 spec exactly.
const DEFAULT_TMPL = '{count} items stock update — please confirm: {link}';

function firstPhone10(s: string): string {
  const parts = String(s || '').split(/[,\/;\s]+/);
  for (const p of parts) {
    const d = p.replace(/[^0-9]/g, '');
    if (d.length >= 10) return d.slice(-10);
  }
  return '';
}

async function sendText(to: string, body: string) {
  try {
    const r = await fetch(`https://graph.facebook.com/v19.0/${PHONE_ID}/messages`, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp', recipient_type: 'individual', to,
        type: 'text', text: { preview_url: true, body },
      }),
    });
    const j = await r.json();
    return { ok: r.ok, id: j?.messages?.[0]?.id ?? null, err: r.ok ? null : j };
  } catch (e) {
    return { ok: false, id: null, err: String(e) };
  }
}

function waFailReason(sent: any): string | null {
  if (!sent?.err) return null;
  if (typeof sent.err === 'string') return sent.err;
  return sent.err?.error?.message || JSON.stringify(sent.err);
}

async function logOutbound(to: string, body: string, sent: any) {
  try {
    const wamid = sent?.id ?? null;
    await supabase.from('whatsapp_messages').insert({
      sender_phone: to, sender_type: 'supplier', direction: 'out',
      msg_type: 'text', text_body: body,
      wa_message_id: wamid,
      routed_to: sent?.ok ? 'stock_notify' : 'stock_notify_error',
      received_at: new Date().toISOString(),
      raw_payload: sent?.err ? { error: sent.err } : null,
      wa_status: wamid ? 'accepted' : 'failed',
      wa_status_at: new Date().toISOString(),
      wa_fail_reason: wamid ? null : waFailReason(sent),
    });
  } catch (_) { /* logging must never fail the send */ }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  if ((req.headers.get('x-notify-secret') || '') !== NOTIFY_SECRET) {
    return new Response('Forbidden', { status: 403 });
  }

  let body: any;
  try { body = await req.json(); } catch { return new Response('bad json', { status: 200 }); }

  const supplier = String(body?.supplier_name || '').trim();
  const token = String(body?.token || '').trim();
  if (!supplier) return new Response(JSON.stringify({ skipped: 'no_supplier' }), { status: 200 });
  if (!token) return new Response(JSON.stringify({ skipped: 'no_token' }), { status: 200 });

  // The form is the source of truth for the item count — never the caller's word.
  const { data: form } = await supabase
    .from('stock_update_forms')
    .select('items,status,supplier_name')
    .eq('token', token)
    .maybeSingle();
  if (!form) return new Response(JSON.stringify({ skipped: 'no_form' }), { status: 200 });
  const count = Array.isArray(form.items) ? form.items.length : 0;
  if (count === 0) return new Response(JSON.stringify({ skipped: 'no_items' }), { status: 200 });

  const wantPhone = firstPhone10(String(body?.to_phone || ''));
  const { data: sp } = await supabase
    .from('supplier_profiles')
    .select('whatsapp_no,contact_no,phone')
    .eq('supplier_name', supplier)
    .order('SPN', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!sp) return new Response(JSON.stringify({ skipped: 'no_supplier_profile' }), { status: 200 });

  const ph = wantPhone
    || firstPhone10(sp.whatsapp_no || '')
    || firstPhone10(sp.contact_no || '')
    || firstPhone10(sp.phone || '');
  if (ph.length !== 10) return new Response(JSON.stringify({ skipped: 'no_phone' }), { status: 200 });
  const to = '91' + ph;

  const g = await supabase.rpc('notif_should_send', {
    p_audience: 'supplier', p_action_key: 'supplier_stock_update', p_phone: ph,
  });
  if (g.data === false) return new Response(JSON.stringify({ skipped: 'notif_disabled' }), { status: 200 });

  const link = 'https://medibo.in/stock-update/' + token;

  let tmpl = '';
  try {
    const { data: t } = await supabase.from('app_settings').select('value')
      .eq('key', 'stock_update_wa_message').maybeSingle();
    if (t && typeof t.value === 'string') tmpl = t.value;
  } catch (_) { /* fall through to default */ }
  if (!tmpl || !tmpl.trim()) tmpl = DEFAULT_TMPL;

  const text = tmpl
    .replace(/\{count\}/g, String(count))
    .replace(/\{supplier\}/g, supplier)
    .replace(/\{link\}/g, link);

  const sent = await sendText(to, text);
  await logOutbound(to, text, sent);

  return new Response(
    JSON.stringify({ ok: sent.ok, to, supplier, token, items: count, link, manual: !!wantPhone, err: sent.err }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
});
