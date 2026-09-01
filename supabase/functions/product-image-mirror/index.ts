// CHANGE #460 / feature_gaps 161 — product-image-mirror
//
// Every product card, the cart pill, the wishlist and the reorder list were
// rendering https://onemg.gumlet.io/... — Tata 1mg's image CDN. 252,760 rows,
// zero images of our own. This worker copies them into our `product-images`
// bucket, a batch at a time, buyable products first.
//
// It owns no policy: `catalogue_mirror_next` decides WHAT to fetch (and
// re-queues anything a dead worker left 'running'), `catalogue_mirror_report`
// decides what a success or a failure MEANS. This function only fetches bytes
// and uploads them.
//
// Body: { limit?: number }   Auth: Authorization: Bearer <service-role key>.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
// AUTH — CHANGE #460 QA round 1, finding 1.
// This worker drives privileged RPCs and storage writes, so it must never be
// callable by anyone who can read the repo. It used to fall back to a literal
// shared secret that was committed in this file AND in two migrations AND in
// cron_task.work_sql, which made that value a public credential: a POST from
// the open internet, with no apikey and no JWT, did real work.
//
// There is now exactly ONE accepted credential, the platform-injected
// service-role key, which is never in git. MIRROR_SECRET stays as an optional
// break-glass override for a future caller that cannot hold that key; it is
// UNSET today, and an unset/short value grants nothing. No fallback literal —
// if nothing is configured, the function fails closed and refuses everyone.
const ACCEPTED: string[] = [
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
  Deno.env.get('MIRROR_SECRET') ?? '',
].map((v) => v.trim()).filter((v) => v.length >= 20);

// Constant-time compare so a caller cannot walk the credential byte by byte.
function credentialMatches(presented: string): boolean {
  if (presented.length < 20 || ACCEPTED.length === 0) return false;
  let hit = false;
  for (const good of ACCEPTED) {
    let diff = presented.length ^ good.length;
    for (let i = 0; i < presented.length; i++) {
      diff |= presented.charCodeAt(i) ^ good.charCodeAt(i % good.length);
    }
    if (diff === 0) hit = true;
  }
  return hit;
}

// A project has TWO service-role credentials — the legacy signed JWT and the
// newer opaque `sb_secret_...` string — and the platform injects only one of
// them here. Byte-equality against the injected value therefore refuses the
// OTHER perfectly legitimate form, which is what happened on the first attempt
// at this fix: the cron's own key came back not_authorized.
//
// So authorise by CAPABILITY, not by string identity. This function is
// deployed with verify_jwt=true, so the Supabase gateway has already checked
// the signature and expiry of anything that reaches this line — an attacker
// cannot mint or edit a token. All that is left for us to decide is WHICH
// verified caller is allowed, and that is the role claim.
function roleFromVerifiedJwt(token: string): string | null {
  const parts = token.split('.');
  if (parts.length !== 3) return null;              // not a JWT (opaque key)
  try {
    const b64 = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    const payload = JSON.parse(atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4)));
    return typeof payload?.role === 'string' ? payload.role : null;
  } catch (_) {
    return null;
  }
}

function isAuthorized(token: string): boolean {
  if (!token) return false;
  if (roleFromVerifiedJwt(token) === 'service_role') return true;  // signed by the gateway
  return credentialMatches(token);                                  // opaque injected key
}
const BUCKET = 'product-images';
const MAX_BYTES = 10 * 1024 * 1024;          // the bucket's own limit
const FETCH_TIMEOUT_MS = 15000;

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// Browser-invoked? No — but a preflight costs nothing and an admin screen may
// call it later. (CORS is mandatory on anything the web app can reach.)
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function extFor(contentType: string, url: string): string {
  const ct = (contentType || '').toLowerCase();
  if (ct.includes('png')) return 'png';
  if (ct.includes('webp')) return 'webp';
  if (ct.includes('gif')) return 'gif';
  if (ct.includes('jpeg') || ct.includes('jpg')) return 'jpg';
  const m = /\.(png|webp|gif|jpe?g)(\?|$)/i.exec(url || '');
  return m ? m[1].toLowerCase().replace('jpeg', 'jpg') : 'jpg';
}

async function fetchImage(url: string): Promise<{ bytes: Uint8Array; ct: string }> {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, { signal: ac.signal, redirect: 'follow' });
    if (!r.ok) throw new Error(`source ${r.status}`);
    const ct = r.headers.get('content-type') ?? '';
    if (!ct.toLowerCase().startsWith('image/')) throw new Error(`not an image (${ct || 'no content-type'})`);
    const buf = new Uint8Array(await r.arrayBuffer());
    if (buf.byteLength === 0) throw new Error('empty body');
    if (buf.byteLength > MAX_BYTES) throw new Error(`too large (${buf.byteLength} b)`);
    return { bytes: buf, ct };
  } finally {
    clearTimeout(t);
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const auth = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!isAuthorized(auth)) {
    return new Response(JSON.stringify({ ok: false, error: 'not_authorized' }),
      { status: 401, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }

  let limit = 20;
  try {
    const body = await req.json();
    if (Number.isFinite(body?.limit)) limit = Math.max(1, Math.min(100, Number(body.limit)));
  } catch (_) { /* no body is fine */ }

  const { data: batch, error: nextErr } = await supabase.rpc('catalogue_mirror_next', { p_limit: limit });
  if (nextErr) {
    return new Response(JSON.stringify({ ok: false, error: String(nextErr.message ?? nextErr) }),
      { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
  if (!batch?.ok) {
    return new Response(JSON.stringify(batch ?? { ok: false, error: 'no_reply' }),
      { status: 403, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }

  const items: Array<{ product_id: number; source_url: string }> = batch.items ?? [];
  let done = 0, failed = 0;

  for (const it of items) {
    try {
      const { bytes, ct } = await fetchImage(it.source_url);
      const path = `${it.product_id}.${extFor(ct, it.source_url)}`;
      const { error: upErr } = await supabase.storage.from(BUCKET).upload(path, bytes, {
        contentType: ct || 'image/jpeg',
        upsert: true,
        cacheControl: '31536000',
      });
      if (upErr) throw new Error(`upload: ${upErr.message}`);

      const publicUrl = `${SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${path}`;
      await supabase.rpc('catalogue_mirror_report', {
        p_product_id: it.product_id, p_ok: true,
        p_public_url: publicUrl, p_storage_path: `${BUCKET}/${path}`,
        p_bytes: bytes.byteLength, p_error: null,
      });
      done++;
    } catch (e) {
      // A failure is the queue's business, not this function's: report it and
      // let catalogue_mirror_report decide retry vs give-up (3 attempts).
      await supabase.rpc('catalogue_mirror_report', {
        p_product_id: it.product_id, p_ok: false,
        p_public_url: null, p_storage_path: null, p_bytes: null,
        p_error: String((e as Error)?.message ?? e),
      });
      failed++;
    }
  }

  return new Response(JSON.stringify({ ok: true, picked: items.length, done, failed }),
    { headers: { ...CORS, 'Content-Type': 'application/json' } });
});
