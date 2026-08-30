// razorpay-checkout-create — CHANGE #304
//
// #291's QR is a scan-from-ANOTHER-device product. On this account Razorpay
// returns image_url with a NULL qr_string, so the app could only ever draw a
// picture — and a picture cannot launch PhonePe/GPay on the phone holding it.
// Five QRs, zero payments.
//
// This function mints something PAYABLE instead: a Razorpay Payment Link whose
// short_url opens Razorpay Checkout, which fires the UPI intent and hands the
// customer to their own UPI app on web AND in the Android build.
//
// It decides nothing. SQL owns all of it:
//   rzp_checkout_prepare(order, kind) -> pay_mode? amount? an OPEN attempt to
//                                        resume? the notes to carry?
//   rzp_checkout_store(...)           -> records Razorpay's reply, returns the
//                                        backend's own render-ready view
// No rupee value and no display string is computed here. A client that lies
// about the amount changes nothing — the amount is re-derived server-side.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const RZP_KEY_ID = (Deno.env.get('RAZORPAY_KEY_ID') ?? '').trim();
const RZP_KEY_SECRET = (Deno.env.get('RAZORPAY_KEY_SECRET') ?? '').trim();
const CALLBACK_URL = (Deno.env.get('RAZORPAY_CALLBACK_URL') ?? 'https://medibo.in/').trim();

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

/// The caller must be able to SEE the order before anything payable is minted
/// for it. `admin` bypasses RLS (it has to — prepare re-derives the amount), so
/// the permission question is asked on a client carrying the CALLER's own JWT
/// and the orders RLS policy is what answers.
///
/// A service-role caller is already trusted. This project has TWO valid
/// service-role credentials (the legacy JWT and the short secret key), so the
/// trust test is a CAPABILITY question the database answers, never a string
/// comparison against one of them — see #291, which cost 20 minutes to a bare
/// 403 for exactly that mistake.
interface Caller { ok: boolean; privileged: boolean; mode: string | null }

/// Resolve WHO is asking, and let the backend decide the pay mode FOR THAT
/// SESSION. This has to run on a client carrying the caller's own JWT: the
/// `admin` client below is service_role, so `rzp_pay_mode()` evaluated through
/// it would read service_role's role and acting-as — an admin acting as a
/// customer would silently be handed the self-pay flow meant for the customer.
///
/// Privilege is a CAPABILITY question the database answers, never a string
/// comparison against a service key: this project has TWO valid service-role
/// credentials (the legacy JWT and the short secret), so comparing to one of
/// them refuses the runner — the mistake that cost #291 twenty minutes.
async function resolveCaller(req: Request, orderId: string): Promise<Caller> {
  const auth = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!auth) return { ok: false, privileged: false, mode: null };
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${auth}` } },
    auth: { persistSession: false },
  });
  // payment_config is admin-only under RLS: service_role bypasses it, a
  // super-admin JWT passes the policy, everyone else reads nothing.
  const { data: cap } = await asCaller
    .from('payment_config').select('id').eq('id', 1).maybeSingle();
  const privileged = !!cap?.id;
  if (!privileged) {
    const { data, error } = await asCaller
      .from('orders').select('id').eq('id', orderId).maybeSingle();
    if (error || !data?.id) return { ok: false, privileged: false, mode: null };
  }
  const { data: mode } = await asCaller.rpc('rzp_pay_mode', { p_order_id: orderId });
  return { ok: true, privileged, mode: typeof mode === 'string' ? mode : null };
}

/// An INFRASTRUCTURE failure (keys missing, Razorpay down or refusing) must not
/// leave the customer with a dead sheet. `provider: 'upi_manual'` is the same
/// answer the toggle-off path gives, so every caller drops back to the QR/UPI
/// sheet it drew before this change. `nothing_due` is NOT one of these — that
/// is a real answer with its own message.
function fallbackToManual(error: string, detail: unknown = null) {
  return reply({ ok: false, provider: 'upi_manual', fallback: true, error, detail });
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

  const orderId = String(body?.order_id ?? '').trim();
  const kind = String(body?.kind ?? 'advance').toLowerCase();
  // The caller may ASK for a mode (the WhatsApp sender wants a link even though
  // the session is staff); the backend still validates and returns what it
  // decided. Absent => rzp_pay_mode() decides alone.
  const wantMode = String(body?.mode ?? '').trim().toLowerCase() || null;
  if (!orderId) return reply({ ok: false, error: 'missing_order_id' });

  const caller = await resolveCaller(req, orderId);
  if (!caller.ok) return reply({ ok: false, error: 'not_authorized' }, 403);

  // The mode the BACKEND chose for this session. A privileged caller (the
  // WhatsApp sender, an admin acting as a customer) may ask for a different
  // one; an ordinary customer cannot talk itself into somebody else's flow.
  const mode = (caller.privileged && wantMode) ? wantMode : caller.mode;

  // 1. Ask the backend what (if anything) to create.
  const { data: prep, error: prepErr } = await admin.rpc('rzp_checkout_prepare', {
    p_order_id: orderId,
    p_kind: kind,
    p_mode: mode,
  });
  if (prepErr) return fallbackToManual('prepare_failed', prepErr.message);
  if (!prep?.ok) return reply(prep ?? { ok: false, error: 'prepare_empty' });

  // 2. RESUME. An attempt already open for this exact order+kind+amount comes
  //    back with the SAME Razorpay link — a second tap never mints a second
  //    payable object, which is what "Resume payment" means.
  if (prep.reused) {
    return reply({ ok: true, reused: true, pay_mode: prep.pay_mode, ...prep.view });
  }

  if (!RZP_KEY_ID || !RZP_KEY_SECRET) return fallbackToManual('razorpay_not_configured');

  // 3. Create the payment link. `reference_id` is unique per link on Razorpay's
  //    side too, so even a duplicated request cannot produce two links.
  let rzp: Record<string, unknown>;
  try {
    const r = await fetch('https://api.razorpay.com/v1/payment_links', {
      method: 'POST',
      headers: { Authorization: rzpAuth(), 'Content-Type': 'application/json' },
      body: JSON.stringify({
        amount: prep.amount_paise,
        currency: 'INR',
        accept_partial: false,
        description: prep.description,
        reference_id: prep.reference_id,
        expire_by: prep.expire_by,
        reminder_enable: false,
        notify: { sms: false, email: false },
        callback_url: CALLBACK_URL,
        callback_method: 'get',
        notes: prep.notes,
      }),
    });
    rzp = await r.json();
    if (!r.ok) {
      return fallbackToManual('razorpay_error',
        (rzp as any)?.error?.description ?? r.status);
    }
  } catch (e) {
    return fallbackToManual('razorpay_unreachable', String(e));
  }

  // 4. Store it and hand back the backend's own view.
  const { data: stored, error: storeErr } = await admin.rpc('rzp_checkout_store', {
    p_attempt_id: prep.attempt_id,
    p_link_id: (rzp as any)?.id ?? null,
    p_short_url: (rzp as any)?.short_url ?? null,
    p_rzp_order_id: (rzp as any)?.order_id ?? null,
  });
  if (storeErr) return fallbackToManual('store_failed', storeErr.message);
  if (!stored?.ok) return fallbackToManual('store_empty', stored?.error ?? null);

  return reply({ ok: true, reused: false, pay_mode: prep.pay_mode, ...stored.view });
});
