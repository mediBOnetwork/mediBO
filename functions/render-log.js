// Cloudflare Pages Function — GET /render-log
// Proxies to Supabase render_log table and returns plain text.
// Cloudflare Pages Functions take precedence over _redirects rules.
// Usage: curl https://medibo.in/render-log

const SUPABASE_URL = 'https://swojhmarmaijkshsbeih.supabase.co';
const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ';

export async function onRequest(context) {
  try {
    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/render_log?id=eq.singleton&select=*`,
      {
        headers: {
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
        },
      }
    );
    const rows = await res.json();
    const row = rows[0];

    if (!row) {
      return new Response(
        'render_log=empty\nnote=no data yet — open medibo.in with test.admin@medibo.in and navigate to a supplier Companies panel\n',
        { headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
      );
    }

    const data = row.data || {};
    const lines = [
      `build=${row.build_hash || 'unknown'}`,
      `updated_at=${row.updated_at || 'unknown'}`,
    ];
    for (const [k, v] of Object.entries(data)) {
      lines.push(`${k}=${v}`);
    }
    lines.push('');

    return new Response(lines.join('\n'), {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store',
      },
    });
  } catch (e) {
    return new Response(`error=${e.message}\n`, {
      status: 500,
      headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    });
  }
}
