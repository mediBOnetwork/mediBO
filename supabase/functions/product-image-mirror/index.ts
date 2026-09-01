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
// Body: { limit?: number }   Auth: x-mirror-secret, or a service-role JWT.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MIRROR_SECRET = (Deno.env.get('MIRROR_SECRET') ?? 'medibo_image_mirror_2027').trim();
const BUCKET = 'product-images';
const MAX_BYTES = 10 * 1024 * 1024;          // the bucket's own limit
const FETCH_TIMEOUT_MS = 15000;

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// Browser-invoked? No — but a preflight costs nothing and an admin screen may
// call it later. (CORS is mandatory on anything the web app can reach.)
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-mirror-secret',
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
  const secret = (req.headers.get('x-mirror-secret') ?? '').trim();
  if (secret !== MIRROR_SECRET && auth !== SUPABASE_KEY) {
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
