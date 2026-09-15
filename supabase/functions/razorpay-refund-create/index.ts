// razorpay-refund-create — CHANGE #395
//
// Money could leave mediBO and never come back: there was no path from a
// cancelled or returned order to an actual payout. This is that path for the
// Razorpay half of it (a manual UPI refund is recorded by refund_mark_manual
// and never touches this function).
//
// It decides NOTHING. SQL owns all of it, exactly as razorpay-checkout-create
// does for the inbound leg:
//   refund_prepare(refund_id) -> is it ours to send? which payment? how many
//                                paise? which notes? and it flips the row to
//                                'processing' so a second click cannot ask
//                                Razorpay for the same refund twice.
//   refund_store(...)         -> records Razorpay's reply (or its refusal).
// The AMOUNT is re-derived server-side and capped at what was actually
// collected on the order, so a client that lies about it changes nothing.
//
// 'processed' is never claimed here. A Razorpay refund settles asynchronously;
// the refund.processed webhook is what marks it paid (rzp_webhook_apply ->
// _rzp_refund_apply).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { outboundPaymentGate } from '../_shared/outbound_gate.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const RZP_KEY_ID = (Deno.env.get('RAZORPAY_KEY_ID') ?? '').trim();
const RZP_KEY_SECRET = (Deno.env.get('RAZORPAY_KEY_SECRET') ?? '').trim();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-notify-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const JSON_HEADERS = { ...CORS, 'Content-Type': 'application/json' };

const admin = createClient(SUPABASE_URL, SERVICE_KEY);

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

/// Refunding is an ADMIN capability, never a customer one. Privilege is a
/// question the database answers (payment_config is admin-only under RLS), not
/// a string comparison against a service key — this project has two valid
/// service-role credentials and comparing to one of them locks out the other.
async function isPrivileged(req: Request): Promise<boolean> {
  const auth = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!auth) return false;
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${auth}` } },
    auth: { persistSession: false },
  });
  const { data } = await asCaller
    .from('payment_config').select('id').eq('id', 1).maybeSingle();
  return !!data?.id;
}

function rzpAuth(): string {
  return 'Basic ' + btoa(`${RZP_KEY_ID}:${RZP_KEY_SECRET}`);
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return reply({ ok: false, error: 'method' }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply({ ok: false, error: 'bad_json' });
  }

  const refundId = String(body?.refund_id ?? '').trim();
  if (!refundId) return reply({ ok: false, error: 'missing_refund_id' });

  if (!(await isPrivileged(req))) return reply({ ok: false, error: 'not_authorized' }, 403);

  // CMD #1849 — refund_prepare below already refuses a stamped row, but it runs
  // on the service-role client and so never sees the CALLER's session header.
  // This asks the same dispatcher with that header forwarded.
  const gate = await outboundPaymentGate(SUPABASE_URL, SERVICE_KEY, req, 'refund.create');
  if (!gate.allowed) {
    return reply({ ok: false, error: 'test_mode_outbound_blocked', message: gate.message });
  }

  // 1. Ask the backend what to send. This also takes the row out of 'pending',
  //    so a double click cannot mint a second refund at Razorpay.
  const { data: prep, error: prepErr } = await admin.rpc('refund_prepare', {
    p_refund_id: refundId,
  });
  if (prepErr) return reply({ ok: false, error: 'prepare_failed', detail: prepErr.message });
  if (!prep?.ok) return reply(prep ?? { ok: false, error: 'prepare_empty' });

  if (!RZP_KEY_ID || !RZP_KEY_SECRET) {
    await admin.rpc('refund_store', {
      p_refund_id: refundId, p_error: 'razorpay_not_configured',
    });
    return reply({ ok: false, error: 'razorpay_not_configured' });
  }

  // 2. Send it. Razorpay's own idempotency is the refund's reference in notes;
  //    ours is refund_prepare having already left 'pending'.
  let rzp: Record<string, unknown>;
  try {
    const r = await fetch(
      `https://api.razorpay.com/v1/payments/${encodeURIComponent(prep.payment_id)}/refund`,
      {
        method: 'POST',
        headers: { Authorization: rzpAuth(), 'Content-Type': 'application/json' },
        body: JSON.stringify({
          amount: prep.amount_paise,
          speed: 'normal',
          notes: prep.notes,
        }),
      },
    );
    rzp = await r.json();
    if (!r.ok) {
      const detail = (rzp as any)?.error?.description ?? `http_${r.status}`;
      await admin.rpc('refund_store', { p_refund_id: refundId, p_error: String(detail) });
      return reply({ ok: false, error: 'razorpay_error', detail });
    }
  } catch (e) {
    await admin.rpc('refund_store', { p_refund_id: refundId, p_error: String(e) });
    return reply({ ok: false, error: 'razorpay_unreachable', detail: String(e) });
  }

  // 3. Record the reply and hand back the backend's own answer.
  const { data: stored, error: storeErr } = await admin.rpc('refund_store', {
    p_refund_id: refundId,
    p_provider_refund_id: (rzp as any)?.id ?? null,
    p_provider_status: (rzp as any)?.status ?? null,
  });
  if (storeErr) return reply({ ok: false, error: 'store_failed', detail: storeErr.message });

  return reply({ ...(stored ?? { ok: true }), provider_refund_id: (rzp as any)?.id ?? null });
});
