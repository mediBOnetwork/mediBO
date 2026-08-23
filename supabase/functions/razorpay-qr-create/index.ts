// razorpay-qr-create — CHANGE #291
//
// The ONLY thing this function decides is "did Razorpay answer?". Everything
// else — whether the Razorpay path is on at all, how much is due, what the
// sheet says — comes from SQL:
//
//   rzp_qr_prepare(order, kind)  -> enabled? amount? reusable QR? notes?
//   rzp_qr_store(...)            -> stores the Razorpay reply, returns the view
//
// so no rupee value and no display string is ever computed here. A client that
// lies about the amount changes nothing: the amount is re-derived server-side.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

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

/// The caller must be able to SEE the order before a QR is minted for it.
/// `admin` bypasses RLS (it has to — rzp_qr_prepare re-derives the amount), so
/// the permission check runs on a client carrying the CALLER's own JWT and lets
/// the orders RLS policy answer. A service-role caller (send-payment-qr) is
/// already trusted and skips the round trip.
async function callerMaySeeOrder(req: Request, orderId: string): Promise<boolean> {
  const auth = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!auth) return false;
  if (auth === SERVICE_KEY) return true;
  // Anon key + the caller's JWT => PostgREST resolves the role from the JWT and
  // the orders RLS policy is what answers.
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${auth}` } },
    auth: { persistSession: false },
  });
  const { data, error } = await asCaller
    .from('orders').select('id').eq('id', orderId).maybeSingle();
  return !error && !!data?.id;
}

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

/** Basic auth against the Razorpay REST API. */
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

  const orderId = String(body?.order_id ?? '').trim();
  const kind = String(body?.kind ?? 'advance').toLowerCase();
  if (!orderId) return reply({ ok: false, error: 'missing_order_id' });

  if (!(await callerMaySeeOrder(req, orderId))) {
    return reply({ ok: false, error: 'not_authorized' }, 403);
  }

  // 1. Ask the backend what (if anything) to create.
  const { data: prep, error: prepErr } = await admin.rpc('rzp_qr_prepare', {
    p_order_id: orderId,
    p_kind: kind,
  });
  if (prepErr) return reply({ ok: false, error: 'prepare_failed', detail: prepErr.message });
  if (!prep?.ok) return reply(prep ?? { ok: false, error: 'prepare_empty' });

  // Already have an open QR for this exact amount — hand back the same one.
  if (prep.reused) return reply({ ok: true, reused: true, ...prep.view });

  if (!RZP_KEY_ID || !RZP_KEY_SECRET) {
    return reply({ ok: false, error: 'razorpay_not_configured' });
  }

  // 2. Create the dynamic QR on Razorpay.
  let rzp: Record<string, unknown>;
  try {
    const r = await fetch('https://api.razorpay.com/v1/payments/qr_codes', {
      method: 'POST',
      headers: { Authorization: rzpAuth(), 'Content-Type': 'application/json' },
      body: JSON.stringify({
        type: 'upi_qr',
        name: 'mediBO',
        usage: 'single_use',
        fixed_amount: true,
        payment_amount: prep.amount_paise,
        description: prep.description,
        close_by: prep.close_by,
        notes: prep.notes,
      }),
    });
    rzp = await r.json();
    if (!r.ok) {
      return reply({
        ok: false,
        error: 'razorpay_error',
        status: r.status,
        detail: (rzp as any)?.error?.description ?? null,
      });
    }
  } catch (e) {
    return reply({ ok: false, error: 'razorpay_unreachable', detail: String(e) });
  }

  // 3. Store it and return the backend's own render-ready view.
  const { data: stored, error: storeErr } = await admin.rpc('rzp_qr_store', {
    p_order_id: orderId,
    p_kind: prep.kind,
    p_rzp_qr_id: rzp?.id ?? null,
    p_image_url: rzp?.image_url ?? null,
    p_qr_string: (rzp as any)?.qr_string ?? null,
    p_amount: prep.amount,
  });
  if (storeErr) return reply({ ok: false, error: 'store_failed', detail: storeErr.message });
  if (!stored?.ok) return reply(stored ?? { ok: false, error: 'store_empty' });

  return reply({ ok: true, reused: false, ...stored.view });
});
