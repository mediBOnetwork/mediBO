// notify-new-registration — Supabase Edge Function
// Triggered by a DB webhook on pharmacy_profiles INSERT.
// Sends FCM web-push to all stored admin tokens.
//
// SETUP REQUIRED:
//   Set Supabase secret: supabase secrets set FCM_SERVER_KEY=<your-server-key>
//   OR use Firebase Admin SDK service account (see comments below).
//
//   FCM_SERVER_KEY: Project Settings → Cloud Messaging → Server key (legacy)
//   Or use the HTTP v1 API with a service account JWT (preferred).
//
// Trigger this function via:
//   Supabase Dashboard → Database → Webhooks → New webhook
//   Table: pharmacy_profiles   Event: INSERT
//   URL: <your-project-ref>.functions.supabase.co/notify-new-registration

import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const body = await req.json();
    // Accept both direct payload and Supabase webhook envelope
    const record: Record<string, unknown> = body.record ?? body;

    const approved = record['approved'] as boolean ?? false;
    const status   = (record['status']  as string  ?? '').toLowerCase();
    if (approved || (status !== 'pending' && status !== '')) {
      return new Response(JSON.stringify({ skipped: 'not a pending registration' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const regId       = record['id']           as string ?? '';
    const pharmacyName= record['pharmacy_name'] as string ?? 'New pharmacy';
    const city        = record['city']          as string ?? '';
    const state       = record['state']         as string ?? '';
    const location    = [city, state].filter(Boolean).join(', ');

    // ── Get all admin FCM tokens ─────────────────────────────────────────
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { data: tokenRows, error: tokenErr } = await supabase
      .from('admin_push_tokens')
      .select('token');

    if (tokenErr) throw new Error(`Token fetch: ${tokenErr.message}`);
    if (!tokenRows || tokenRows.length === 0) {
      return new Response(JSON.stringify({ sent: 0, reason: 'no tokens stored' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const tokens = tokenRows.map((r: { token: string }) => r.token).filter(Boolean);

    // ── Send via FCM legacy HTTP API ─────────────────────────────────────
    // Replace with HTTP v1 (OAuth2) if preferred.
    const fcmKey = Deno.env.get('FCM_SERVER_KEY') ?? '';
    if (!fcmKey || fcmKey === '') {
      console.warn('[notify-new-reg] FCM_SERVER_KEY not set — push skipped');
      return new Response(JSON.stringify({ sent: 0, reason: 'FCM_SERVER_KEY not configured' }),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const notifBody = location
      ? `${pharmacyName} — ${location}`
      : pharmacyName;

    const results = await Promise.allSettled(tokens.map(async (token: string) => {
      const res = await fetch('https://fcm.googleapis.com/fcm/send', {
        method: 'POST',
        headers: {
          'Authorization': `key=${fcmKey}`,
          'Content-Type':  'application/json',
        },
        body: JSON.stringify({
          to: token,
          notification: {
            title: '🏥 New mediBO Registration',
            body:  notifBody,
            icon:  'https://medibo.in/icons/Icon-192.png',
            click_action: 'https://medibo.in?tab=pending',
          },
          data: {
            type:  'new_registration',
            regId,
            title: '🏥 New mediBO Registration',
            body:  notifBody,
          },
          webpush: {
            headers:      { TTL: '86400' },
            notification: { requireInteraction: true, renotify: false },
          },
        }),
      });
      const json = await res.json();
      if (json.failure > 0) {
        // Remove invalid/expired tokens
        const results = json.results as Array<{ error?: string }>;
        for (let i = 0; i < results.length; i++) {
          if (results[i].error === 'NotRegistered' ||
              results[i].error === 'InvalidRegistration') {
            await supabase.from('admin_push_tokens').delete().eq('token', tokens[i]);
          }
        }
      }
      return json;
    }));

    const sent = results.filter(r => r.status === 'fulfilled').length;
    return new Response(
      JSON.stringify({ sent, total: tokens.length, regId }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    console.error('[notify-new-reg] error:', msg);
    return new Response(JSON.stringify({ error: msg }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
