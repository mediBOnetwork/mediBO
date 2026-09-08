// CHANGE #473 — sentry-crashes
//
// Pulls the last 24 hours of Sentry issues for the mediBO project and writes
// the per-release counts into `crash_release_stat`, which is what the Dev Queue
// Crashes card reads. The card NEVER calls Sentry itself: a browser cannot hold
// an org auth token, and the card must render identically whether or not Sentry
// is connected.
//
// It is inert and honest until the secrets exist. With no SENTRY_API_TOKEN (or
// no org/project slug) it returns `{ok:false, reason:'not_configured'}` with a
// plain sentence, writes nothing, and logs nothing — the "Sentry not connected"
// state the card already renders from crash_config.
//
// Secrets: read from the vault via `secret_get_runner` (service-role only), the
// same door every other runner secret uses. Nothing here is ever echoed into a
// response, a log line, or an error message.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// Browser-invoked (the card's Refresh), so the preflight must be answered or it
// fails in the app while working perfectly from curl.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

/// One vault read. Returns '' when the secret does not exist — an absent
/// secret is a state, not an error.
async function secret(name: string): Promise<string> {
  try {
    const { data, error } = await supabase.rpc('secret_get_runner', {
      p_name: name,
    });
    if (error) return '';
    return String(data ?? '').trim();
  } catch (_) {
    return '';
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  // The org/project slugs are config, not secrets — they live on crash_config
  // beside every other crash-reporting answer.
  const { data: cfgRow } = await supabase
    .from('crash_config')
    .select('org_slug, project_slug, environment, token_secret_name')
    .eq('id', 1)
    .maybeSingle();

  const org = String(cfgRow?.org_slug ?? '').trim();
  const project = String(cfgRow?.project_slug ?? '').trim();
  const token = await secret(
    String(cfgRow?.token_secret_name ?? 'SENTRY_API_TOKEN'),
  );

  if (!token || !org || !project) {
    return json({
      ok: false,
      reason: 'not_configured',
      message:
        'Sentry is not connected yet. Save SENTRY_API_TOKEN in the vault and set the org and project slugs on crash_config.',
    });
  }

  // Sentry's issues endpoint, last 24h, sorted by frequency. `query=''` means
  // every issue rather than only unresolved ones — a crash Om has already
  // triaged still happened on that release.
  const url =
    `https://sentry.io/api/0/projects/${org}/${project}/issues/` +
    `?statsPeriod=24h&query=&limit=100`;

  let issues: unknown[] = [];
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) {
      // The STATUS, never the body: a Sentry error body can echo the request.
      return json({ ok: false, reason: 'sentry_http', status: res.status }, 200);
    }
    issues = await res.json();
  } catch (_) {
    return json({ ok: false, reason: 'sentry_unreachable' }, 200);
  }

  // Group by release. Sentry reports a firstRelease/lastRelease per issue; the
  // one that matters for "which change is crashing" is the LAST one seen.
  const byRelease = new Map<
    string,
    { event_count: number; user_count: number; last_seen: string }
  >();

  for (const raw of issues as Array<Record<string, unknown>>) {
    const rel =
      String(
        (raw?.lastRelease as Record<string, unknown> | undefined)?.version ??
          (raw?.firstRelease as Record<string, unknown> | undefined)?.version ??
          'unknown',
      ) || 'unknown';
    const events = Number(raw?.count ?? 0) || 0;
    const users = Number(raw?.userCount ?? 0) || 0;
    const seen = String(raw?.lastSeen ?? '');

    const cur = byRelease.get(rel) ??
      { event_count: 0, user_count: 0, last_seen: '' };
    cur.event_count += events;
    cur.user_count += users;
    if (seen > cur.last_seen) cur.last_seen = seen;
    byRelease.set(rel, cur);
  }

  const rows = [...byRelease.entries()].map(([release, v]) => ({
    release,
    event_count: v.event_count,
    user_count: v.user_count,
    last_seen: v.last_seen,
  }));

  const { error } = await supabase.rpc('crash_stats_upsert', { p_rows: rows });
  if (error) return json({ ok: false, reason: 'upsert_failed' }, 200);

  return json({ ok: true, releases: rows.length });
});
