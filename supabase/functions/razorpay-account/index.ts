// razorpay-account — CHANGE #293
//
// The gateway half of "where the money lands". Razorpay's merchant key exposes
// far less than the dashboard does — /v1/account answers 200 with an EMPTY body
// for a non-partner key, and a fresh live account has no settlements yet — so
// this function syncs what IS knowable (the live key id, and the latest
// settlement once one exists) and leaves the rest to the super-admin's own
// entry via payment_gateway_details_set().
//
// action:'webhook_test' is the endpoint self-check: it signs a harmless,
// unhandled event with the REAL RAZORPAY_WEBHOOK_SECRET and posts it to the
// live webhook. A 200 proves three things at once — the endpoint is public
// (verify_jwt off), a good signature is accepted, and an event that is not
// qr_code.credited is acknowledged instead of retried. The secret never leaves
// the edge runtime.
//
// It decides no display strings: payment_money_lands() in SQL builds every word
// the admin reads.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const RZP_KEY_ID = (Deno.env.get('RAZORPAY_KEY_ID') ?? '').trim();
const RZP_KEY_SECRET = (Deno.env.get('RAZORPAY_KEY_SECRET') ?? '').trim();
const WEBHOOK_SECRET = (Deno.env.get('RAZORPAY_WEBHOOK_SECRET') ?? '').trim();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const JSON_HEADERS = { ...CORS, 'Content-Type': 'application/json' };
const admin = createClient(SUPABASE_URL, SERVICE_KEY);

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}
function rzpAuth(): string {
  return 'Basic ' + btoa(`${RZP_KEY_ID}:${RZP_KEY_SECRET}`);
}
async function get(path: string) {
  try {
    const r = await fetch(`https://api.razorpay.com${path}`, {
      headers: { Authorization: rzpAuth() },
    });
    const j = await r.json().catch(() => null);
    return { ok: r.ok, status: r.status, body: j as Record<string, unknown> | null };
  } catch (_e) {
    return { ok: false, status: 0, body: null };
  }
}

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}
async function hmacHex(secret: string, raw: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'],
  );
  return toHex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)));
}

// Capability, never string equality: this project has TWO valid service-role
// keys (a legacy JWT and a 41-char secret), so the gate asks "can this caller
// read payment_config?" and lets RLS answer. service_role bypasses RLS; a
// super-admin JWT passes the admin policy; anyone else is refused.
async function mayConfigure(bearer: string): Promise<boolean> {
  if (!bearer) return false;
  const c = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${bearer}` } },
    auth: { persistSession: false },
  });
  const { data, error } = await c.from('payment_config').select('id').eq('id', 1).maybeSingle();
  return !error && !!data;
}

async function webhookTest() {
  if (!WEBHOOK_SECRET) return { ok: false, error: 'webhook_secret_not_configured' };
  const url = `${SUPABASE_URL}/functions/v1/razorpay-webhook`;
  const out: Record<string, unknown> = {};

  // A real Razorpay event name that this integration deliberately ignores.
  const body = JSON.stringify({
    event: 'payment.authorized',
    account_id: 'acc_selftest',
    contains: ['payment'],
    payload: { payment: { entity: { id: 'pay_selftest_293', amount: 0 } } },
  });

  const good = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json',
               'x-razorpay-signature': await hmacHex(WEBHOOK_SECRET, body) },
    body,
  });
  out.signed_status = good.status;
  out.signed_body = await good.text();

  const bad = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-razorpay-signature': 'deadbeef' },
    body,
  });
  out.forged_status = bad.status;
  out.forged_body = await bad.text();

  out.ok = good.status === 200 && bad.status === 400;
  return out;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const bearer = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!(await mayConfigure(bearer))) return reply({ ok: false, error: 'not_authorized' }, 403);

  let action = 'sync';
  try {
    const b = await req.json();
    action = String((b as Record<string, unknown>)?.action ?? 'sync');
  } catch (_e) { /* empty body means sync */ }

  if (action === 'webhook_test') return reply(await webhookTest());

  if (!RZP_KEY_ID || !RZP_KEY_SECRET) {
    return reply({ ok: false, error: 'razorpay_not_configured' });
  }

  const settlements = await get('/v1/settlements?count=1');
  const latest = (settlements.body?.items as Array<Record<string, unknown>> | undefined)?.[0] ?? null;

  const patch: Record<string, unknown> = { key_id: RZP_KEY_ID };
  if (latest) {
    patch.last_settlement = {
      id: latest.id ?? null,
      amount: latest.amount ?? null,
      status: latest.status ?? null,
      created_at: latest.created_at ?? null,
    };
  }

  const { error } = await admin.rpc('payment_gateway_sync', { p_patch: patch });
  if (error) return reply({ ok: false, error: 'sync_failed', detail: error.message });

  const { data: lands } = await admin.rpc('payment_money_lands');
  return reply({ ok: true, synced: patch, money_lands: lands });
});
