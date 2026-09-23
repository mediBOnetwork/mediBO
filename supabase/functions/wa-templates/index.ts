import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// CMD #2180 — the hardcoded fallback token that used to live here expired on
// 2026-06-26 and is gone. WHATSAPP_TOKEN is the only source; without it every
// Graph call is refused with the backend's own sentence instead of a 190.
const WA_TOKEN     = (Deno.env.get('WHATSAPP_TOKEN') ?? '').trim();
const PHONE_ID_RAW = (Deno.env.get('WHATSAPP_PHONE_ID') ?? '').trim();
const PHONE_ID     = /^[0-9]{6,}$/.test(PHONE_ID_RAW) ? PHONE_ID_RAW : '1157319300801672';
const WABA_ENV     = (Deno.env.get('WHATSAPP_WABA_ID') ?? '').trim();
const INTERNAL_SECRET = 'medibo_order_notify_2027';
const GRAPH = 'https://graph.facebook.com/v21.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')!;
const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-notify-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

let WABA_CACHE: string | null = WABA_ENV || null;
async function wabaId(): Promise<{ id: string | null; err: any }> {
  if (WABA_CACHE) return { id: WABA_CACHE, err: null };
  const r = await fetch(`${GRAPH}/${PHONE_ID}?fields=whatsapp_business_account{id}`, {
    headers: { Authorization: `Bearer ${WA_TOKEN}` },
  });
  const j = await r.json();
  const id = j?.whatsapp_business_account?.id ?? null;
  if (id) WABA_CACHE = id;
  return { id, err: id ? null : j };
}

function metaErr(j: any) {
  const e = j?.error ?? {};
  return {
    message: e.error_user_msg ?? e.message ?? 'Meta rejected the request',
    title: e.error_user_title ?? null,
    code: e.code ?? null,
    subcode: e.error_subcode ?? null,
    raw: j,
  };
}

// Meta requires example.header_handle on media headers (IMAGE / DOCUMENT / VIDEO).
// The app saves components without it; the uploaded sample handle lives in
// wa_templates.header_handle. Inject it here so Submit never fails on
// "component of type HEADER is missing expected field(s) (example)".
function withHeaderExample(components: any[], headerHandle: string | null): any[] {
  if (!Array.isArray(components)) return components;
  return components.map((c: any) => {
    if (!c || String(c.type ?? '').toUpperCase() !== 'HEADER') return c;
    const fmt = String(c.format ?? '').toUpperCase();
    if (!['IMAGE', 'DOCUMENT', 'VIDEO'].includes(fmt)) return c;
    const has = Array.isArray(c?.example?.header_handle) && c.example.header_handle.length > 0;
    if (has || !headerHandle) return c;
    return { ...c, example: { ...(c.example ?? {}), header_handle: [headerHandle] } };
  });
}

// CMD #2180 — Meta's own words for "you may not change the category this way".
// An APPROVED template is frozen (subcode 3835031); a draft or rejected one may
// be re-categorised, but only on some accounts. Detected so submit can fall back
// to delete-and-recreate instead of leaving the template stuck in the wrong
// category for ever, which is what kept customer_imported MARKETING through
// three rejections.
function isCategoryRefusal(j: any): boolean {
  const e = j?.error ?? {};
  const sub = Number(e.error_subcode ?? 0);
  const txt = `${e.error_user_msg ?? ''} ${e.message ?? ''} ${e.error_user_title ?? ''}`.toLowerCase();
  return sub === 3835031 || (txt.includes('categor') && (txt.includes('cannot') || txt.includes('not allowed') || txt.includes('can not')));
}

async function syncFromMeta(): Promise<any> {
  const w = await wabaId();
  if (!w.id) return { ok: false, synced: 0, err: metaErr(w.err) };
  let url =
    `${GRAPH}/${w.id}/message_templates?limit=200&fields=id,name,language,category,status,components,rejected_reason,quality_score`;
  let synced = 0; const errors: any[] = []; const seen: string[] = [];
  for (let page = 0; page < 10 && url; page++) {
    const r = await fetch(url, { headers: { Authorization: `Bearer ${WA_TOKEN}` } });
    const j = await r.json();
    if (!r.ok) return { ok: false, synced, err: metaErr(j) };
    for (const t of j?.data ?? []) {
      const row: any = {
        meta_id: String(t.id),
        name: t.name,
        language: t.language ?? 'en',
        category: (t.category ?? 'UTILITY').toUpperCase(),
        status: (t.status ?? 'PENDING').toUpperCase(),
        components: t.components ?? [],
        rejected_reason: t.rejected_reason ?? null,
        quality_score: typeof t.quality_score === 'object' ? (t.quality_score?.score ?? null) : (t.quality_score ?? null),
        last_synced_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      seen.push(`${row.name}/${row.language}/${row.category}/${row.status}`);
      const { data: existing } = await supabase
        .from('wa_templates').select('id').eq('name', row.name).eq('language', row.language).maybeSingle();
      if (existing?.id) {
        const { error } = await supabase.from('wa_templates').update(row).eq('id', existing.id);
        if (error) errors.push({ name: row.name, op: 'update', error: error.message }); else synced++;
      } else {
        const { error } = await supabase.from('wa_templates').insert(row);
        if (error) errors.push({ name: row.name, op: 'insert', error: error.message, row }); else synced++;
      }
    }
    url = j?.paging?.next ?? '';
  }
  return { ok: errors.length === 0, synced, errors, seen };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST')   return json({ error: 'method_not_allowed' }, 405);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'bad_json' }, 400); }
  const action = String(body.action ?? '').trim();

  const internal = req.headers.get('x-notify-secret') === INTERNAL_SECRET;
  if (!internal) {
    const authHeader = req.headers.get('Authorization') ?? '';
    const userClient = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user?.email) return json({ error: 'not_authenticated' }, 401);
    const { data: adminRow } = await supabase.from('admins').select('email').ilike('email', user.email.trim().toLowerCase()).maybeSingle();
    if (!adminRow) return json({ error: 'not_authorized' }, 403);
  }

  if (!WA_TOKEN) return json({ error: 'wa_token_missing', meta: { message: 'WHATSAPP_TOKEN is not set on this function' } }, 502);

  if (action === 'sync') {
    const s = await syncFromMeta();
    return json({ status: s.ok ? 'ok' : 'partial', synced: s.synced, errors: s.errors ?? [], seen: s.seen ?? [], meta_error: s.err ?? null });
  }

  if (action === 'submit') {
    const id = String(body.id ?? '');
    const { data: t } = await supabase.from('wa_templates').select('*').eq('id', id).maybeSingle();
    if (!t) return json({ error: 'not_found' }, 404);

    const w = await wabaId();
    if (!w.id) return json({ error: 'waba_unresolved', meta: metaErr(w.err) }, 502);

    const components = withHeaderExample(t.components ?? [], t.header_handle ?? null);
    const category = String(t.category ?? 'UTILITY').toUpperCase();

    // CMD #2180 — a template that is not APPROVED is re-submitted to CHANGE
    // something, and INCORRECT_CATEGORY is the commonest reason, so the edit
    // carries the category the row now holds. Only an APPROVED template sends
    // components alone: Meta freezes its category (3835031) and would refuse
    // the whole edit. The status is read as "not APPROVED" rather than
    // "REJECTED" because _wa_rejected_edit_requeue flips a rejected row to
    // DRAFT the moment its components are edited — reading REJECTED here is
    // how the category silently stayed MARKETING through three resubmissions.
    const isEdit = !!t.meta_id;

    // CMD #2180 — Meta refuses subcode 3835031 ("cannot update an approved
    // template category") for the mere PRESENCE of `category` on an edit, even
    // when the template is REJECTED and even when the value is identical. So the
    // category is only ever sent when Meta's own copy really is in a different
    // one — read here rather than guessed from the row, whose category is
    // whatever the admin last chose.
    let metaCategory: string | null = null;
    if (isEdit) {
      const cr = await fetch(`${GRAPH}/${t.meta_id}?fields=category,status`, {
        headers: { Authorization: `Bearer ${WA_TOKEN}` } });
      const cj = await cr.json();
      if (cr.ok && cj?.category) metaCategory = String(cj.category).toUpperCase();
    }
    const sendCategoryOnEdit = isEdit && metaCategory !== null && metaCategory !== category;

    async function post(url: string, payload: any) {
      const r = await fetch(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      return { ok: r.ok, j: await r.json() };
    }

    const createPayload = { name: t.name, language: t.language, category, components };
    let res = isEdit
      ? await post(`${GRAPH}/${t.meta_id}`, sendCategoryOnEdit ? { category, components } : { components })
      : await post(`${GRAPH}/${w.id}/message_templates`, createPayload);

    // CMD #2180 — the self-heal: Meta refused the category change on an edit, so
    // the only way to move the template into the right category is to delete it
    // at Meta and create it again under the same name. The ROW is kept (unlike
    // action:'delete'), so the route binding, token_map and history survive.
    let recreated = false;
    const firstErr = res.ok ? null : metaErr(res.j);
    if (!res.ok && isEdit && sendCategoryOnEdit && isCategoryRefusal(res.j)) {
      const del = await fetch(
        `${GRAPH}/${w.id}/message_templates?name=${encodeURIComponent(t.name)}&hsm_id=${encodeURIComponent(t.meta_id)}`,
        { method: 'DELETE', headers: { Authorization: `Bearer ${WA_TOKEN}` } });
      const delJ = await del.json();
      if (!del.ok) return json({ error: 'submit_failed', meta: metaErr(delJ), first_error: firstErr, phase: 'delete_before_recreate' }, 502);
      res = await post(`${GRAPH}/${w.id}/message_templates`, createPayload);
      recreated = true;
    }

    const j = res.j;
    if (!res.ok) {
      await supabase.from('wa_templates')
        .update({ last_error: metaErr(j), updated_at: new Date().toISOString() }).eq('id', id);
      return json({ error: 'submit_failed', meta: metaErr(j), first_error: firstErr, recreated }, 502);
    }

    await supabase.from('wa_templates').update({
      meta_id: j?.id ? String(j.id) : t.meta_id,
      status: (j?.status ?? 'PENDING').toUpperCase(),
      category: (j?.category ?? category).toUpperCase(),
      submitted_at: new Date().toISOString(),
      last_synced_at: new Date().toISOString(),
      rejected_reason: null,
      last_error: null,
      updated_at: new Date().toISOString(),
    }).eq('id', id);

    return json({ status: 'ok', meta_id: j?.id ?? t.meta_id, recreated, template_status: (j?.status ?? 'PENDING').toUpperCase() });
  }

  // CMD #2180 — when Meta will neither re-categorise an existing template nor
  // let this token delete it, the remaining move is a NEW template under a new
  // name in the right category, bound to the SAME row (so the route, token_map
  // and history follow it). name/category default to the row's own.
  if (action === 'create_new') {
    const id = String(body.id ?? '');
    const { data: t } = await supabase.from('wa_templates').select('*').eq('id', id).maybeSingle();
    if (!t) return json({ error: 'not_found' }, 404);
    const w = await wabaId();
    if (!w.id) return json({ error: 'waba_unresolved', meta: metaErr(w.err) }, 502);

    const name = String(body.name ?? t.name).trim().toLowerCase();
    const category = String(body.category ?? t.category ?? 'UTILITY').toUpperCase();
    const components = withHeaderExample(t.components ?? [], t.header_handle ?? null);
    const r = await fetch(`${GRAPH}/${w.id}/message_templates`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${WA_TOKEN}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, language: t.language, category, components }),
    });
    const j = await r.json();
    if (!r.ok) {
      await supabase.from('wa_templates')
        .update({ last_error: metaErr(j), updated_at: new Date().toISOString() }).eq('id', id);
      return json({ error: 'create_failed', meta: metaErr(j) }, 502);
    }
    await supabase.from('wa_templates').update({
      name,
      meta_id: String(j.id),
      status: (j?.status ?? 'PENDING').toUpperCase(),
      category: (j?.category ?? category).toUpperCase(),
      submitted_at: new Date().toISOString(),
      last_synced_at: new Date().toISOString(),
      rejected_reason: null,
      last_error: null,
      updated_at: new Date().toISOString(),
    }).eq('id', id);
    return json({ status: 'ok', name, meta_id: String(j.id), template_status: (j?.status ?? 'PENDING').toUpperCase() });
  }

  if (action === 'delete') {
    const id = String(body.id ?? '');
    const { data: t } = await supabase.from('wa_templates').select('*').eq('id', id).maybeSingle();
    if (!t) return json({ error: 'not_found' }, 404);
    if (!t.meta_id) { await supabase.from('wa_templates').delete().eq('id', id); return json({ status: 'ok', deleted: 'local' }); }

    const w = await wabaId();
    if (!w.id) return json({ error: 'waba_unresolved', meta: metaErr(w.err) }, 502);
    const r = await fetch(`${GRAPH}/${w.id}/message_templates?name=${encodeURIComponent(t.name)}&hsm_id=${encodeURIComponent(t.meta_id)}`,
      { method: 'DELETE', headers: { Authorization: `Bearer ${WA_TOKEN}` } });
    const j = await r.json();

    // CMD #2182 — Meta refuses (#100) "Need permission on either WhatsApp
    // Business Account or owner/shared business" for every delete this token
    // asks for, which made Delete a dead button for any template that had ever
    // reached Meta. Retiring is the rest of the action: the row goes and the
    // name joins wa_template_retired, so no sync can put it back on the screen.
    // Meta's own copy is left alone — this function has no way to remove it.
    if (!r.ok) {
      const refusal = metaErr(j);
      const { data: ret, error: retErr } = await supabase.rpc('wa_template_retire', {
        p_id: id,
        p_reason: `Deleted from the Templates screen; Meta refused: ${refusal.message}`,
      });
      if (retErr || !ret?.ok) {
        return json({ error: 'delete_failed', meta: refusal,
                      retire_error: retErr?.message ?? ret?.message ?? ret?.error ?? null }, 502);
      }
      return json({ status: 'ok', deleted: 'retired', message: ret.message,
                    meta_refusal: refusal.message });
    }

    await supabase.from('wa_templates').delete().eq('id', id);
    return json({ status: 'ok', deleted: 'meta' });
  }

  return json({ error: 'bad_action', allowed: ['submit', 'create_new', 'delete', 'sync'] }, 400);
});
