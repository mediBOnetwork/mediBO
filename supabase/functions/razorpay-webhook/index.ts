// razorpay-webhook — CHANGE #291, hardened by #293
//
// Razorpay calls this when a QR is credited. This function does exactly two
// things: prove the delivery is genuine (HMAC-SHA256 over the RAW body with
// RAZORPAY_WEBHOOK_SECRET), then hand the event to rzp_webhook_apply(), which
// owns all of the matching, the payment_claims row and the order update.
//
// No secret configured => 503 and nothing is recorded. An unverified webhook
// could be forged to mark any order paid, so "no secret" is never "trust it".
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = (Deno.env.get('RAZORPAY_WEBHOOK_SECRET') ?? '').trim();

const admin = createClient(SUPABASE_URL, SERVICE_KEY);
const JSON_HEADERS = { 'Content-Type': 'application/json' };

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function toHex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** Length-safe, value-safe comparison — never a plain ===. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacHex(secret: string, raw: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return toHex(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw)));
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply({ ok: false, error: 'method' }, 405);

  // The raw body is the signed payload — read it as TEXT and never re-serialise
  // it before verifying, or the bytes (and the digest) change.
  const raw = await req.text();
  const sig = (req.headers.get('x-razorpay-signature') ?? '').trim();

  if (!WEBHOOK_SECRET) {
    return reply({ ok: false, error: 'webhook_secret_not_configured' }, 503);
  }
  // #293 — the spec's contract: an unverifiable delivery is a BAD REQUEST.
  // 400 (not 401) is also what keeps Razorpay from treating this as an auth
  // challenge it should retry against.
  if (!sig) return reply({ ok: false, error: 'missing_signature' }, 400);

  let expected: string;
  try {
    expected = await hmacHex(WEBHOOK_SECRET, raw);
  } catch (e) {
    return reply({ ok: false, error: 'hmac_failed', detail: String(e) }, 500);
  }
  if (!timingSafeEqual(expected, sig.toLowerCase())) {
    return reply({ ok: false, error: 'bad_signature' }, 400);
  }

  let event: unknown;
  try {
    event = JSON.parse(raw);
  } catch {
    return reply({ ok: false, error: 'bad_json' }, 400);
  }

  const { data, error } = await admin.rpc('rzp_webhook_apply', { p_event: event });
  if (error) {
    // 500 so Razorpay retries — rzp_webhook_apply is idempotent on the payment
    // id, so a retry after a partial failure is safe.
    return reply({ ok: false, error: 'apply_failed', detail: error.message }, 500);
  }
  return reply(data ?? { ok: true });
});
