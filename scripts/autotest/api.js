'use strict';
// CHANGE #634 — the harness's ONLY door to the backend.
//
// Two identities, deliberately separate:
//   • service  — records the run (test_run_start / test_result_report /
//                test_run_finish). Never used to drive a feature.
//   • a ROLE   — a real signed-in user, exactly what a customer's browser
//                holds. Every step that acts as somebody uses this token, so
//                RLS and every role guard are being tested, not bypassed.
//
// Nothing here decides anything. The manifest, the identities, the assertions
// and every string come from the database.
const https = require('https');
const fs = require('fs');
const path = require('path');

const SUPA_URL = process.env.MEDIBO_SUPA_URL || 'https://swojhmarmaijkshsbeih.supabase.co';
const ANON_KEY = process.env.MEDIBO_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ';
const PROJECT_REF = (() => {
  try { return new URL(SUPA_URL).hostname.split('.')[0]; } catch (_) { return ''; }
})();

// The service key and the role passwords live on the VM, chmod 600, and are
// never committed, never logged and never put in a run record.
function loadEnvFile(file) {
  const out = {};
  try {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
      if (!m) continue;
      out[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '');
    }
  } catch (_) { /* absent file is a capability that is simply off */ }
  return out;
}

const HOME = process.env.HOME || '/home/ubuntu';
const secrets = Object.assign(
  {},
  loadEnvFile(path.join(HOME, '.medibo', 'autotest.env')),
  loadEnvFile(path.join(HOME, 'mediBO-runner', 'runner.env')),
  process.env
);

const SERVICE_KEY = secrets.AUTOTEST_SERVICE_KEY || secrets.SERVICE_ROLE_KEY ||
                    secrets.SUPABASE_SERVICE_ROLE_KEY || '';

/// CHANGE #637 — the ONE place the service key turns into headers.
///
/// artifacts.js read `process.env.AUTOTEST_SERVICE_KEY` for itself and fell
/// back to the anon key when it came up empty — and it is ALWAYS empty, because
/// the key lives in ~/.medibo/autotest.env, a file only this module parses. So
/// the visual lane uploaded every screenshot as `anon`, storage answered "new
/// row violates row-level security policy" once per shot, and the run still
/// exited 0 reporting "0 shot(s)". A missing key is a capability that is OFF.
/// It is never a quieter key: refuse, in the same words the RPC path already
/// refuses in, so the reason is on screen the first time instead of eight 403s.
function serviceHeaders(extra) {
  if (!SERVICE_KEY) {
    throw new Error(
      'autotest: no service key. Put AUTOTEST_SERVICE_KEY in ~/.medibo/autotest.env (chmod 600).');
  }
  return Object.assign(
    { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }, extra || {});
}

// Every call is bounded and retried once. The 1 GB database goes busy under
// load and a POST can sit unanswered: a bot that hangs forever is worse than a
// bot that reports a slow backend, because nobody ever sees its verdict.
const REQUEST_TIMEOUT_MS = parseInt(process.env.AUTOTEST_HTTP_TIMEOUT_MS || '25000', 10);

function requestOnce(method, url, body, headers) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = body === undefined ? null : JSON.stringify(body);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method,
      headers: Object.assign(
        { 'Content-Type': 'application/json' },
        data ? { 'Content-Length': Buffer.byteLength(data) } : {},
        headers || {})
    }, (res) => {
      let buf = '';
      res.on('data', (d) => { buf += d; });
      res.on('end', () => {
        let parsed = buf;
        try { parsed = buf ? JSON.parse(buf) : null; } catch (_) { /* text */ }
        if (res.statusCode >= 400) {
          const err = new Error(`${method} ${u.pathname} -> ${res.statusCode}: ` +
            (typeof parsed === 'string' ? parsed.slice(0, 300) : JSON.stringify(parsed).slice(0, 300)));
          err.status = res.statusCode; err.body = parsed;
          return reject(err);
        }
        resolve(parsed);
      });
    });
    req.on('error', reject);
    req.setTimeout(REQUEST_TIMEOUT_MS, () => {
      req.destroy(new Error(`${method} ${u.pathname} timed out after ${REQUEST_TIMEOUT_MS}ms`));
    });
    if (data) req.write(data);
    req.end();
  });
}

async function request(method, url, body, headers) {
  try {
    return await requestOnce(method, url, body, headers);
  } catch (e) {
    // A 4xx/5xx is an ANSWER and must not be retried into a different story.
    // Only a dead socket or a timeout gets a second chance.
    if (e && e.status) throw e;
    await new Promise((r) => setTimeout(r, 2000));
    return requestOnce(method, url, body, headers);
  }
}

function rpc(fn, params, token) {
  const key = token ? ANON_KEY : SERVICE_KEY;
  const bearer = token || SERVICE_KEY;
  if (!bearer) {
    return Promise.reject(new Error(
      'autotest: no service key. Put AUTOTEST_SERVICE_KEY in ~/.medibo/autotest.env (chmod 600).'));
  }
  return request('POST', `${SUPA_URL}/rest/v1/rpc/${fn}`, params || {},
    { apikey: key, Authorization: `Bearer ${bearer}` });
}

// Sign a role in for real. Returns the session the Flutter app itself stores,
// so the browser boots already logged in as that user.
async function signIn(email, password) {
  const s = await request('POST', `${SUPA_URL}/auth/v1/token?grant_type=password`,
    { email, password }, { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` });
  if (!s || !s.access_token) throw new Error(`sign-in failed for ${email}`);
  return s;
}

// The exact localStorage entry supabase_flutter reads on boot.
function storageEntry(session) {
  return {
    key: `sb-${PROJECT_REF}-auth-token`,
    value: JSON.stringify({
      access_token: session.access_token,
      token_type: 'bearer',
      expires_in: session.expires_in,
      expires_at: Math.floor(Date.now() / 1000) + (session.expires_in || 3600),
      refresh_token: session.refresh_token,
      user: session.user
    })
  };
}

// Password for a role. The DB owns WHO (identity); the VM owns the secret.
function passwordFor(role) {
  const k = 'AUTOTEST_PASS_' + String(role || '').toUpperCase();
  return secrets[k] || DEFAULT_PASSWORDS[role] || '';
}

// The three published test logins (they are already documented in CLAUDE.md,
// so they are a default rather than a secret). Anything else must come from
// ~/.medibo/autotest.env.
const DEFAULT_PASSWORDS = {
  customer: 'TestCust1#26',
  admin: 'TestAdmin#26',
  supplier: 'TestSup1#26'
};

module.exports = {
  SUPA_URL, ANON_KEY, PROJECT_REF,
  hasServiceKey: () => Boolean(SERVICE_KEY), serviceHeaders,
  rpc, signIn, storageEntry, passwordFor, request
};
