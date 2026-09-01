// mask-call — CHANGE #404
//
// The app sends TWO things: an order id and the role it wants to reach. It does
// not send a phone number, it never receives one, and it does not get a say in
// whether the call is allowed. Everything else is SQL:
//
//   call_mask_prepare(actor, order, target_role)
//       -> allowed? both legs resolved? a DID? a live session? all the copy?
//   call_mask_store(session, provider, sid, status)
//       -> what the provider answered
//
// so no display string and no routing decision is computed here.
//
// PROVIDER-AGNOSTIC BY CONSTRUCTION. `Provider` is an interface with exactly one
// method; Exotel is the first implementation and the stub is the one that always
// exists. Adding Plivo or Knowlarity is a second `connect()`, not a rewrite of
// this file — and NOTHING below reads an Exotel field outside the Exotel adapter.
//
// WHEN EXOTEL IS NOT PROVISIONED the stub answers instead of the function
// failing. That is deliberate: masked calling must be fully testable, and every
// screen must be fully wired, before a single rupee of telephony is bought.
// call_setup_status() is where "what is still missing" is read.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

const EXOTEL_SID = (Deno.env.get('EXOTEL_SID') ?? '').trim();
const EXOTEL_TOKEN = (Deno.env.get('EXOTEL_TOKEN') ?? '').trim();
const EXOTEL_KEY = (Deno.env.get('EXOTEL_KEY') ?? '').trim(); // optional; falls back to SID
const EXOTEL_SUBDOMAIN = (Deno.env.get('EXOTEL_SUBDOMAIN') ?? '').trim();

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

// ── the adapter seam ───────────────────────────────────────────────────────
type Leg = { role: string; phone: string; name: string };
type Prepared = {
  session_id: string;
  order_id?: string;
  provider: string;
  did: string;
  caller: Leg;
  callee: Leg;
  record_calls: boolean;
  exotel_subdomain: string | null;
  exotel_caller_id: string | null;
  copy: Record<string, string>;
};
type ConnectResult = {
  ok: boolean;
  sid: string | null;
  status: string;
  /** How the app should behave: the provider rang both legs, or the user dials the DID. */
  mode: 'provider_dials' | 'user_dials';
  detail?: unknown;
};

interface Provider {
  readonly name: string;
  configured(): boolean;
  connect(p: Prepared): Promise<ConnectResult>;
}

/// Exotel "Connect two numbers" — it rings `From` first, then bridges to `To`,
/// and both sides see `CallerId` (the ExoPhone) instead of each other. That is
/// exactly the masking contract, so the app has nothing to dial.
const exotel: Provider = {
  name: 'exotel',
  configured() {
    return !!(EXOTEL_SID && EXOTEL_TOKEN);
  },
  async connect(p: Prepared): Promise<ConnectResult> {
    const sub = (p.exotel_subdomain || EXOTEL_SUBDOMAIN || 'api.exotel.com').replace(/^https?:\/\//, '');
    const user = EXOTEL_KEY || EXOTEL_SID;
    const url = `https://${sub}/v1/Accounts/${EXOTEL_SID}/Calls/connect.json`;
    const form = new URLSearchParams({
      From: p.caller.phone,
      To: p.callee.phone,
      // The ExoPhone both legs see. The DID the session reserved is the default;
      // call_config.exotel_caller_id overrides it for accounts whose caller id
      // is not one of the pool numbers.
      CallerId: p.exotel_caller_id || p.did,
      CallType: 'trans',
      Record: p.record_calls ? 'true' : 'false',
    });
    try {
      const r = await fetch(url, {
        method: 'POST',
        headers: {
          Authorization: 'Basic ' + btoa(`${user}:${EXOTEL_TOKEN}`),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form,
      });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) {
        return { ok: false, sid: null, status: 'failed', mode: 'provider_dials', detail: body };
      }
      const sid = (body as any)?.Call?.Sid ?? null;
      return { ok: true, sid, status: 'placed', mode: 'provider_dials', detail: body };
    } catch (e) {
      return { ok: false, sid: null, status: 'failed', mode: 'provider_dials', detail: String(e) };
    }
  },
};

/// The stub places no call. It mints a sid, reports the session as live, and
/// tells the app to dial the DID itself — which is precisely what the inbound
/// webhook is built to match. So the whole chain (allow matrix -> session ->
/// DID -> inbound match -> expiry) is exercisable with no telephony account.
const stub: Provider = {
  name: 'stub',
  configured() {
    return true;
  },
  connect(p: Prepared): Promise<ConnectResult> {
    return Promise.resolve({
      ok: true,
      sid: `stub_${p.session_id}`,
      status: 'stubbed',
      mode: 'user_dials',
    });
  },
};

const PROVIDERS: Record<string, Provider> = { exotel, stub };

/// The provider the CONFIG asked for, unless it is not provisioned — in which
/// case the stub answers rather than the feature going dark. Never silently the
/// other way round: a configured Exotel is never downgraded.
function pick(requested: string): Provider {
  const p = PROVIDERS[requested] ?? stub;
  return p.configured() ? p : stub;
}

/// Who is asking? The JWT decides, never the body. A client that posts someone
/// else's id changes nothing, because the actor handed to SQL comes from the
/// token the platform verified.
async function actorFromRequest(req: Request): Promise<string | null> {
  const auth = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!auth) return null;
  const asCaller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${auth}` } },
    auth: { persistSession: false },
  });
  const { data, error } = await asCaller.auth.getUser();
  if (error) return null;
  return data?.user?.id ?? null;
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
  const targetRole = String(body?.target_role ?? '').trim().toLowerCase();
  if (!orderId || !targetRole) return reply({ ok: false, error: 'missing_params' });

  const actor = await actorFromRequest(req);
  if (!actor) return reply({ ok: false, error: 'not_authorized' }, 401);

  // 1. SQL decides everything.
  const { data: prep, error: prepErr } = await admin.rpc('call_mask_prepare', {
    p_actor: actor,
    p_order_id: orderId,
    p_target_role: targetRole,
  });
  if (prepErr) return reply({ ok: false, error: 'prepare_failed', detail: prepErr.message }, 500);
  if (!prep?.ok) return reply(prep ?? { ok: false, error: 'prepare_empty' });

  const prepared = prep as Prepared;
  const provider = pick(prepared.provider);

  // 2. The provider is the ONLY thing this function does itself.
  const res = await provider.connect(prepared);

  await admin.rpc('call_mask_store', {
    p_session_id: prepared.session_id,
    p_provider: provider.name,
    p_sid: res.sid,
    p_status: res.status,
    p_leg: 'outbound',
    p_raw: { mode: res.mode, detail: res.detail ?? null },
  });

  if (!res.ok) {
    return reply({
      ok: false,
      error: 'provider_failed',
      message: prepared.copy?.failed ?? '',
      provider: provider.name,
    });
  }

  // 3. What comes back carries a DID and never a counterparty number. `did` is
  //    the masking number — it is safe to print, which is the whole point.
  return reply({
    ok: true,
    session_id: prepared.session_id,
    order_id: prepared.order_id ?? orderId,
    provider: provider.name,
    mode: res.mode,
    did: prepared.did,
    target_role: prepared.callee.role,
    target_name: prepared.callee.name,
    expires_at: (prep as any).expires_at,
    message: res.mode === 'provider_dials'
      ? (prepared.copy?.placed ?? '')
      : (prepared.copy?.dial_hint ?? ''),
    privacy_note: prepared.copy?.privacy_note ?? '',
    stub_notice: provider.name === 'stub' ? (prepared.copy?.stub_notice ?? '') : '',
  });
});
