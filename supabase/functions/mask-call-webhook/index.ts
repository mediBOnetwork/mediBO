// mask-call-webhook — CHANGE #404
//
// Somebody dialled one of our DIDs. This function's entire job is to ask SQL
// "which live session is that?" and hand the provider back the answer in the
// shape that provider understands.
//
//   call_inbound_match(from, did) -> connect to <number>, or reject
//   call_leg_log(sid, status, duration, recording) -> the call log
//
// It resolves NOTHING itself: not the session, not who to connect to, not the
// refusal wording. An expired session is refused with the backend's own copy.
//
// verify_jwt is FALSE here — a telephony provider cannot carry a Supabase JWT.
// The webhook is instead gated on a shared secret (MASK_CALL_WEBHOOK_SECRET)
// when one is set, and the only thing an unauthenticated caller could learn
// without it is whether a (number, DID) pair is currently live.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = (Deno.env.get('MASK_CALL_WEBHOOK_SECRET') ?? '').trim();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-webhook-secret',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};
const JSON_HEADERS = { ...CORS, 'Content-Type': 'application/json' };

const admin = createClient(SUPABASE_URL, SERVICE_KEY);

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

/// Providers post form bodies, JSON bodies, or nothing at all with everything on
/// the query string. Read all three rather than making the provider adapt to us.
async function params(req: Request): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const [k, v] of new URL(req.url).searchParams) out[k] = v;
  const ct = (req.headers.get('content-type') ?? '').toLowerCase();
  try {
    if (ct.includes('application/json')) {
      const j = await req.json();
      for (const [k, v] of Object.entries(j ?? {})) out[k] = String(v ?? '');
    } else if (ct.includes('form')) {
      const f = await req.formData();
      for (const [k, v] of f) out[k] = String(v);
    }
  } catch { /* an unreadable body is a missing body, not an error */ }
  return out;
}

/// Exotel sends From/CallTo/CallSid; a generic provider sends from/did/sid.
/// Both are read here so neither shape is privileged in SQL.
function pick(p: Record<string, string>, ...keys: string[]): string {
  for (const k of keys) {
    const v = (p[k] ?? '').trim();
    if (v) return v;
  }
  return '';
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const p = await params(req);

  if (WEBHOOK_SECRET) {
    const given = (req.headers.get('x-webhook-secret') ?? p['secret'] ?? '').trim();
    if (given !== WEBHOOK_SECRET) return reply({ ok: false, error: 'not_authorized' }, 401);
  }

  const from = pick(p, 'From', 'from', 'CallFrom', 'caller');
  const did = pick(p, 'To', 'did', 'CallTo', 'DialWhomNumber', 'ExophoneNumber', 'CallerId');
  const sid = pick(p, 'CallSid', 'sid', 'Sid') || null;
  const event = pick(p, 'event', 'Status', 'CallStatus', 'status').toLowerCase();

  // A terminal status callback is a LOG, not a routing question.
  if (['completed', 'no-answer', 'busy', 'failed', 'canceled', 'cancelled'].includes(event)) {
    const durRaw = pick(p, 'DialCallDuration', 'ConversationDuration', 'duration', 'Duration');
    const { data, error } = await admin.rpc('call_leg_log', {
      p_sid: sid,
      p_status: event,
      p_duration_s: durRaw ? Number(durRaw) || null : null,
      p_recording_url: pick(p, 'RecordingUrl', 'recording_url') || null,
      p_raw: p,
    });
    if (error) return reply({ ok: false, error: 'log_failed', detail: error.message }, 500);
    return reply({ ok: true, logged: true, ...(data ?? {}) });
  }

  if (!from || !did) return reply({ ok: false, action: 'reject', error: 'missing_params' });

  const { data, error } = await admin.rpc('call_inbound_match', {
    p_from: from,
    p_did: did,
    p_sid: sid,
    p_raw: p,
  });
  if (error) return reply({ ok: false, action: 'reject', error: 'match_failed', detail: error.message }, 500);

  // `data` already IS the connect instruction (or the refusal, with the
  // backend's own message). It is returned verbatim, plus the one field Exotel's
  // "Connect Applet" reads off a passthru response.
  const out = (data ?? { ok: false, action: 'reject' }) as Record<string, unknown>;
  return reply({
    ...out,
    // Exotel's passthru contract: the number to bridge to, echoed under the
    // name its applet looks for. Same value, no second decision.
    destination: out['action'] === 'connect' ? out['connect_to'] : null,
  });
});
