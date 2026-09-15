// email-send — CHANGE (cmd #299), PART 3 of the notification rebuild.
//
// The THIRD channel of notify(): push → WhatsApp → email. This function is a
// dumb transport on purpose. Every display string (subject, body, from-name,
// language) is composed in Postgres by notify() and arrives here fully
// rendered — nothing about the message is decided in TypeScript.
//
// Transport: Resend. RESEND_API_KEY lives in edge secrets. medibo.in is the
// domain verified in Resend (us-east-1) — DKIM at resend._domainkey, DMARC
// p=quarantine. send.medibo.in is the subdomain Resend provisions for the
// bounce/return path, NOT a From domain: Resend refuses a From on it with
// "The send.medibo.in domain is not verified". This function never touches
// DNS and never invents a From domain — it falls back to the DB's
// notification_email_config row, never to a literal here.
//
// Auth: verify_jwt is ON (notify() calls it with the service-role bearer) AND
// the shared secret x-notify-secret must match — the same double check
// bill-render uses.
//
// Contract
//   POST { to, subject, html, text?, from?, reply_to?, log_id?, event_key?,
//          tags?, dry_run? }
//   200  { ok:true,  id:"<resend id>", log_id }
//   200  { ok:false, error:"<slug>", log_id }
// Failure is reported as ok:false with a slug, never as a thrown 500 — the
// caller logs the attempt either way, so a dead mailbox is evidence, not a gap.

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-notify-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const NOTIFY_SECRET = 'medibo_order_notify_2027';
const RESEND_ENDPOINT = 'https://api.resend.com/emails';

type Json = Record<string, unknown>;

function reply(body: Json, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function admin() {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );
}

// The log row is the permanent record of the attempt. notify() creates it
// BEFORE calling us (so a crash here still leaves evidence); we only close it.
async function closeLog(
  log_id: number | null,
  ok: boolean,
  providerId: string | null,
  reason: string | null,
  detail: Json,
) {
  if (!log_id) return;
  try {
    await admin().rpc('notif_log_close', {
      p_id: log_id,
      p_ok: ok,
      p_provider_id: providerId,
      p_reason: reason,
      p_detail: detail,
    });
  } catch (e) {
    console.error('[email-send] closeLog failed', String(e));
  }
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reply({ ok: false, error: 'method_not_allowed' }, 405);

  if (req.headers.get('x-notify-secret') !== NOTIFY_SECRET) {
    return reply({ ok: false, error: 'forbidden' }, 403);
  }

  let body: Json;
  try {
    body = await req.json();
  } catch {
    return reply({ ok: false, error: 'bad_json' }, 400);
  }

  const log_id = (body.log_id as number | null) ?? null;
  const to = String(body.to ?? '').trim();
  const subject = String(body.subject ?? '').trim();
  const html = String(body.html ?? '');
  const text = body.text ? String(body.text) : undefined;

  if (!to || !to.includes('@')) {
    await closeLog(log_id, false, null, 'no_email', { to });
    return reply({ ok: false, error: 'no_email', log_id });
  }
  if (!subject || !html) {
    await closeLog(log_id, false, null, 'empty_template', { subject_len: subject.length });
    return reply({ ok: false, error: 'empty_template', log_id });
  }

  // From/reply-to are backend-owned. notify() normally passes them; when it does
  // not we read the same config row it reads, so there is exactly ONE place the
  // sending identity is defined and it is not this file.
  let from = String(body.from ?? '').trim();
  let replyTo = body.reply_to ? String(body.reply_to) : '';
  if (!from) {
    try {
      const { data } = await admin()
        .from('notification_email_config')
        .select('from_display, reply_to')
        .eq('id', 'singleton')
        .maybeSingle();
      from = String(data?.from_display ?? '');
      if (!replyTo) replyTo = String(data?.reply_to ?? '');
    } catch (e) {
      console.error('[email-send] config read failed', String(e));
    }
  }
  if (!from) {
    await closeLog(log_id, false, null, 'no_from_configured', {});
    return reply({ ok: false, error: 'no_from_configured', log_id });
  }

  const apiKey = Deno.env.get('RESEND_API_KEY') ?? '';
  if (!apiKey) {
    await closeLog(log_id, false, null, 'resend_key_missing', {});
    return reply({ ok: false, error: 'resend_key_missing', log_id });
  }

  // dry_run renders and validates everything above but never reaches Resend.
  // This is how the admin preview proves a template without mailing a soul.
  if (body.dry_run === true) {
    await closeLog(log_id, true, null, 'dry_run', { from, to, subject });
    return reply({ ok: true, dry_run: true, from, to, subject, log_id });
  }

  const payload: Json = { from, to: [to], subject, html };
  if (text) payload.text = text;
  if (replyTo) payload.reply_to = replyTo;
  if (Array.isArray(body.tags)) payload.tags = body.tags;

  try {
    const res = await fetch(RESEND_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
    const raw = await res.text();
    let parsed: Json = {};
    try { parsed = JSON.parse(raw); } catch { parsed = { raw: raw.slice(0, 500) }; }

    if (!res.ok) {
      const reason = String(parsed.name ?? `http_${res.status}`);
      await closeLog(log_id, false, null, reason, { status: res.status, body: parsed });
      return reply({ ok: false, error: reason, status: res.status, detail: parsed, log_id });
    }

    const id = String(parsed.id ?? '');
    await closeLog(log_id, true, id || null, null, { id });
    return reply({ ok: true, id, log_id });
  } catch (e) {
    const msg = String(e);
    await closeLog(log_id, false, null, 'network_error', { error: msg.slice(0, 500) });
    return reply({ ok: false, error: 'network_error', detail: msg.slice(0, 300), log_id });
  }
});
