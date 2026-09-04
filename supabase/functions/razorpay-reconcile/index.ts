// razorpay-reconcile — CHANGE #474
//
// The failure drill for "Razorpay webhook missed" had nothing to prove: #304
// made a payment attempt resumable and rzp_webhook_apply() exactly-once on the
// provider event id, but BOTH of those assume the webhook arrives. Nothing in
// this system ever asked Razorpay "did that one get paid?". A webhook lost in
// transit left the customer's money gone and the order reading unpaid until a
// human noticed.
//
// This function is that question, asked on a schedule. It decides nothing:
//   rzp_reconcile_due()   -> which attempts are overdue, and how overdue
//   Razorpay              -> what actually happened to each one
//   rzp_webhook_apply()   -> the SAME door the webhook posts through, so a late
//                            webhook and a poll carrying one payment can never
//                            both credit an order
//
// No rupee value, no status word and no display string is computed here.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const RZP_KEY_ID = (Deno.env.get('RAZORPAY_KEY_ID') ?? '').trim();
const RZP_KEY_SECRET = (Deno.env.get('RAZORPAY_KEY_SECRET') ?? '').trim();

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const JSON_HEADERS = { ...CORS, 'Content-Type': 'application/json' };

const admin = createClient(SUPABASE_URL, SERVICE_KEY);

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function auth(): string {
  return 'Basic ' + btoa(`${RZP_KEY_ID}:${RZP_KEY_SECRET}`);
}

async function rzpGet(path: string): Promise<Record<string, unknown> | null> {
  try {
    const r = await fetch(`https://api.razorpay.com/v1${path}`, {
      headers: { Authorization: auth() },
    });
    if (!r.ok) return null;
    return await r.json();
  } catch {
    return null;
  }
}

/// Razorpay's answer, reshaped into the event body its own webhook would have
/// delivered. The event id is derived from the payment so that a poll and the
/// webhook that finally shows up collide on rzp_webhook_apply's replay guard
/// instead of crediting the order twice.
function asPaymentEvent(payment: Record<string, unknown>, link: unknown) {
  return {
    id: `recon_${payment.id}`,
    event: 'payment.captured',
    payload: {
      payment: { entity: payment },
      ...(link ? { payment_link: { entity: link } } : {}),
    },
  };
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return reply({ ok: false, error: 'method' }, 405);

  if (!RZP_KEY_ID || !RZP_KEY_SECRET) {
    return reply({ ok: false, error: 'razorpay_keys_not_configured' }, 503);
  }

  const { data: due, error } = await admin.rpc('rzp_reconcile_due', { p_limit: null });
  if (error) return reply({ ok: false, error: 'due_failed', detail: error.message }, 500);

  const rows = (due?.due ?? []) as Array<Record<string, string>>;
  let asked = 0, reconciled = 0, skipped = 0;
  const results: unknown[] = [];

  for (const row of rows) {
    // A synthetic attempt never reaches Razorpay. The database already refuses
    // to let a test row touch the live gateway (_synthetic_rzp_guard); this is
    // the same rule one layer out, so a drill can never spend a real API call.
    if (String(row.is_synthetic) === 'true') { skipped++; continue; }

    const linkId = row.rzp_link_id;
    const orderId = row.rzp_order_id;
    if (!linkId && !orderId) { skipped++; continue; }

    asked++;
    let payment: Record<string, unknown> | null = null;
    let link: unknown = null;

    if (linkId) {
      link = await rzpGet(`/payment_links/${linkId}`);
      const l = link as Record<string, unknown> | null;
      const payments = (l?.payments ?? []) as Array<Record<string, unknown>>;
      payment = payments.find((p) => p.status === 'captured') ?? null;
    }
    if (!payment && orderId) {
      const o = await rzpGet(`/orders/${orderId}/payments`);
      const items = ((o?.items ?? []) as Array<Record<string, unknown>>);
      payment = items.find((p) => p.status === 'captured') ?? null;
    }
    if (!payment) continue;   // still genuinely unpaid — nothing to reconcile

    const { data, error: applyErr } = await admin.rpc('rzp_webhook_apply', {
      p_event: asPaymentEvent(payment, link),
    });
    if (applyErr) {
      results.push({ attempt_id: row.attempt_id, ok: false, detail: applyErr.message });
      continue;
    }
    reconciled++;
    results.push({ attempt_id: row.attempt_id, ok: true, applied: data });
  }

  return reply({
    ok: true,
    due: rows.length,
    due_count: due?.due_count ?? null,
    asked,
    reconciled,
    skipped,
    results,
  });
});
