import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const WA_TOKEN_HARDCODED = 'EAARb70T6u7sBR775DNCsEMQLBZBxQbZAVXFtOs5ZBZAAp1NezedqnFzeZAOWN4puSZCVXZBmSj5OWDHAb3ko2IwX96ocuK7HUnDcgvh2XqMwGJG1LutM4ayrN2ZCsAIlVdfZCt8Tpzof0QvWlzpIaHPFmG2qGZA6ItJODC9BLe60ZArqG3y4xzVZBjFvc2bXVtF7ZA9GjZAEmrnev4NwaCH23HZBBLN130UfCZC7hgVK2X4jM2q8VuQc7mMZBsnRpSWHoWen1qZCXBiZCRBKm2z2ZB34eqMhtc3dJ8nG06rC3XI8rXWFtSIZD';
const WA_TOKEN     = ((Deno.env.get('WHATSAPP_TOKEN') ?? '').trim()) || WA_TOKEN_HARDCODED;
const PHONE_ID_RAW = (Deno.env.get('WHATSAPP_PHONE_ID') ?? '').trim();
const PHONE_ID     = /^[0-9]{6,}$/.test(PHONE_ID_RAW) ? PHONE_ID_RAW : '1157319300801672';
const INTERNAL_SECRET = 'medibo_order_notify_2027';
const GRAPH = 'https://graph.facebook.com/v21.0';
const SHORT_BASE = 'https://medibo.in/r/';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')!;
const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-notify-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

// CHANGE #294 — a template whose HEADER is IMAGE/DOCUMENT/VIDEO must be sent WITH
// that media, per message; Meta rejects the call otherwise. `header_media` is
// written on the recipient by wa_send_event: either a public {link}, or a
// {bucket, path} in a PRIVATE bucket that we sign here, at send time.
async function headerComponent(hm: any): Promise<any | null> {
  if (!hm || typeof hm !== 'object') return null;
  const kind = String(hm.type ?? '').toLowerCase();
  if (!['image', 'document', 'video'].includes(kind)) return null;

  let link = String(hm.link ?? '').trim();
  if (!link && hm.path) {
    const { data } = await supabase.storage
      .from(String(hm.bucket ?? 'customer-bills'))
      .createSignedUrl(String(hm.path), 3600);
    link = data?.signedUrl ?? '';
  }
  if (!link) return null;

  const media: any = { link };
  if (kind === 'document' && hm.filename) media.filename = String(hm.filename);
  return { type: 'header', parameters: [{ type: kind, [kind]: media }] };
}

async function sendTemplate(
  to: string, name: string, lang: string, vars: string[], linkCode: string | null,
  headerMedia: any = null,
) {
  const components: any[] = [];
  const hdr = await headerComponent(headerMedia);
  if (hdr) components.push(hdr);
  if (vars.length) {
    components.push({ type: 'body', parameters: vars.map((v) => ({ type: 'text', text: String(v ?? '') })) });
  }
  if (linkCode) {
    // URL button suffix: template URL must end with {{1}}
    components.push({ type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: linkCode }] });
  }
  const payload: any = {
    messaging_product: 'whatsapp',
    recipient_type: 'individual',
    to,
    type: 'template',
    template: { name, language: { code: lang }, ...(components.length ? { components } : {}) },
  };
  const r = await fetch(`${GRAPH}/${PHONE_ID}/messages`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const j = await r.json();
  return { ok: r.ok, id: j?.messages?.[0]?.id ?? null, err: r.ok ? null : (j?.error?.error_user_msg ?? j?.error?.message ?? JSON.stringify(j)) };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST')   return json({ error: 'method_not_allowed' }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'bad_json' }, 400); }

  const internal = req.headers.get('x-notify-secret') === INTERNAL_SECRET;
  if (!internal) {
    const authHeader = req.headers.get('Authorization') ?? '';
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user?.email) return json({ error: 'not_authenticated' }, 401);
    const { data: adminRow } = await supabase.from('admins').select('email').ilike('email', user.email.trim().toLowerCase()).maybeSingle();
    if (!adminRow) return json({ error: 'not_authorized' }, 403);
  }

  // TEST SEND (#9): send one template to an arbitrary number without touching a campaign
  if (body.test_to) {
    const s = await sendTemplate(String(body.test_to), String(body.template_name), String(body.language ?? 'en'),
                                 Array.isArray(body.variables) ? body.variables : [], null,
                                 body.header_media ?? null);
    return s.ok ? json({ status: 'ok', wamid: s.id }) : json({ error: 'send_failed', detail: s.err }, 502);
  }

  const rid = String(body.recipient_id ?? '');
  if (!rid) return json({ error: 'missing_recipient_id' }, 400);

  const { data: r } = await supabase.from('wa_campaign_recipients').select('*').eq('id', rid).maybeSingle();
  if (!r) return json({ error: 'recipient_not_found' }, 404);
  if (r.status !== 'pending') return json({ status: 'skipped', reason: 'not_pending' });

  const { data: c } = await supabase.from('wa_campaigns').select('*').eq('id', r.campaign_id).maybeSingle();
  if (!c) return json({ error: 'campaign_not_found' }, 404);
  if (!['running', 'scheduled'].includes(c.status)) return json({ status: 'skipped', reason: 'campaign_' + c.status });

  // last-second suppression re-check (customer may have replied STOP mid-campaign)
  const { data: sup } = await supabase.from('wa_suppression').select('phone').eq('phone', r.phone).maybeSingle();
  if (sup) {
    await supabase.from('wa_campaign_recipients').update({ status: 'skipped', skip_reason: 'suppressed' }).eq('id', rid);
    return json({ status: 'skipped', reason: 'suppressed' });
  }

  const vars: string[] = Array.isArray(r.variables) ? r.variables : [];
  const s = await sendTemplate(r.phone, c.template_name, c.language ?? 'en', vars,
                               c.link_target ? r.link_code : null, r.header_media ?? null);

  if (!s.ok) {
    await supabase.from('wa_campaign_recipients')
      .update({ status: 'failed', error: String(s.err).slice(0, 400) }).eq('id', rid);
    return json({ error: 'send_failed', detail: s.err }, 502);
  }

  await supabase.from('wa_campaign_recipients')
    .update({ status: 'sent', wamid: s.id, sent_at: new Date().toISOString(), error: null }).eq('id', rid);

  await supabase.from('whatsapp_messages').insert({
    sender_phone: r.phone, sender_type: 'customer', direction: 'out', msg_type: 'template',
    text_body: `[campaign] ${c.name} -> ${c.template_name}`,
    wa_message_id: s.id, routed_to: 'campaign', received_at: new Date().toISOString(),
  });

  return json({ status: 'ok', wamid: s.id, short_link: c.link_target ? SHORT_BASE + r.link_code : null });
});
