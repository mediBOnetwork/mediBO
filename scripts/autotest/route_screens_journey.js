#!/usr/bin/env node
'use strict';
// CMD #2107 — THE FOUR FIELD & GROWTH DOORS, OPENED AND WATCHED.
//
//   node scripts/autotest/route_screens_journey.js [--target https://medibo.in]
//                                                  [--widths 360,412] [--dwell 5000]
//
// Route builder / View routes (Routes) / Assign route / Today's visits are one
// screen behind four Dashboard tiles. The bug this journey retires is that
// tapping them "did nothing, opened then closed, or closed the whole app".
//
// So it does exactly, and only, what the report describes: for each tile, at
// each phone width, it TAPS THE TILE and then WATCHES FOR FIVE SECONDS. A door
// passes when, five seconds after the tap:
//
//   • the Flutter view is still attached (the app did not die), and
//   • the app's own render log says which section it landed on
//     (c2056_routes_section, or c1872_today_view for the plain Routes tile),
//     and
//   • the guard did NOT fire (c2107_screen_guard absent) — an exception inside
//     the screen now renders an error state instead of a blank page, and that
//     error state is a FAILED door here even though the app survived it.
//
// The tile is found by its Semantics identifier — c1891_tile_<feature_key>,
// the same identity the tap reports to nav_open() — never by its label: the
// label is a ui_copy row and may be reworded without a deploy.
//
// Exit 0 = every door opened and stayed open at every width. Exit 1 = at least
// one did not. Exit 2 = could not run (no identity, no playwright).

const fs = require('fs');
const path = require('path');
const https = require('https');

const argv = process.argv.slice(2);
const val = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };
const TARGET = val('target', 'https://medibo.in').replace(/\/+$/, '');
const WIDTHS = val('widths', '360,412').split(',').map((s) => parseInt(s.trim(), 10)).filter(Boolean);
const DWELL = parseInt(val('dwell', '5000'), 10);
const HOME = process.env.HOME || '/home/ubuntu';
const OUT = val('out', path.join('/tmp', 'route_screens_journey'));

// The four doors, as feature_registry holds them. Each names the render-log key
// that proves it LANDED — the app's own record, not a screenshot.
const DOORS = [
  { key: 'admin.cust_tab.routes_today',   name: "Today's visits", proof: 'c2056_routes_section', want: 'today' },
  { key: 'admin.cust_tab.routes_builder', name: 'Route builder',  proof: 'c2056_routes_section', want: 'all_plans' },
  { key: 'admin.cust_tab.routes_assign',  name: 'Assign route',   proof: 'c2056_routes_section', want: 'past_plans' },
  // The plain Routes tile names no section, so its proof is the landing view
  // itself: routes_today() answers ok for an admin and _loadScreen lands the
  // tab on 'today', which is what writes this key.
  { key: 'admin.cust_tab.routes',         name: 'Routes',         proof: 'c1872_today_view',    want: '1' },
];

// The project's PUBLIC anon key and URL — the same pair scripts/autotest/api.js
// already carries. Nothing secret lives in this file; the super-admin password
// is read from ~/.medibo/verify_super.env (chmod 600) at run time.
const api = require('./api');
const SB = api.SUPA_URL;
const REF = api.PROJECT_REF;
const ANON = api.ANON_KEY;
const STORAGE_KEY = `sb-${REF}-auth-token`;

function say(...a) { console.error('[routes] ' + a.join(' ')); }

function loadEnvFile(file) {
  const out = {};
  try {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
      if (m) out[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, '');
    }
  } catch (_) {}
  return out;
}

function post(url, headers, body) {
  return new Promise((res, rej) => {
    const d = JSON.stringify(body);
    const r = https.request(url, { method: 'POST', headers: { ...headers, 'Content-Length': Buffer.byteLength(d) } }, (x) => {
      let s = ''; x.on('data', (c) => (s += c)); x.on('end', () => { try { res(JSON.parse(s)); } catch (_) { res(s); } });
    });
    r.on('error', rej); r.write(d); r.end();
  });
}

async function signIn() {
  const env = loadEnvFile(path.join(HOME, '.medibo', 'verify_super.env'));
  const email = env.VERIFY_SUPER_EMAIL, pass = env.VERIFY_SUPER_PASS;
  if (!email || !pass || !ANON) return null;
  const s = await post(`${SB}/auth/v1/token?grant_type=password`, { apikey: ANON, 'Content-Type': 'application/json' }, { email, password: pass });
  return s && s.access_token ? s : null;
}

async function renderLog(page) {
  try {
    const raw = await page.evaluate(() => (document.querySelector('#medibo-render-log') || {}).textContent || '');
    const out = {};
    for (const line of String(raw).split('\n')) {
      const m = /^\s*([A-Za-z0-9_]+)\s*=\s*(.*)$/.exec(line);
      if (m) out[m[1]] = m[2].trim();
    }
    return out;
  } catch (_) { return {}; }
}

async function enableSemantics(page) {
  try {
    await page.evaluate(() => {
      const ph = document.querySelector('flt-semantics-placeholder');
      if (ph) { try { ph.click(); } catch (_) {} }
    });
  } catch (_) {}
}

/// The tile, by identifier. Flutter only builds what is laid out, so a tile far
/// down the Dashboard has no semantics node until the page is scrolled to it.
async function findTile(page, key, width, budgetMs) {
  const sel = `[flt-semantics-identifier="c1891_tile_${key}"]`;
  const deadline = Date.now() + budgetMs;
  let scrolls = 0;
  while (Date.now() < deadline) {
    try { if (await page.locator(sel).count() > 0) return sel; } catch (_) {}
    await enableSemantics(page);
    if (scrolls < 60) {
      try {
        await page.mouse.move(Math.round(width / 2), 400);
        await page.mouse.wheel(0, 600);
      } catch (_) {}
      scrolls++;
    }
    await page.waitForTimeout(500);
  }
  return null;
}

async function runWidth(chromium, session, width, results) {
  const browser = await chromium.launch({
    args: ['--no-sandbox'],
    ...(fs.existsSync('/usr/bin/chromium') ? { executablePath: '/usr/bin/chromium' } : {}),
  });
  const ctx = await browser.newContext({ viewport: { width, height: 780 }, deviceScaleFactor: 2 });
  await ctx.addInitScript(({ k, v }) => {
    localStorage.setItem(k, v);
    localStorage.setItem('MEDIBO_SUPER', '1');
  }, { k: STORAGE_KEY, v: JSON.stringify(session) });

  const page = await ctx.newPage();
  let died = false;
  page.on('crash', () => { died = true; });

  const boot = async () => {
    await page.goto(`${TARGET}/admin/dashboard?responsive_audit=1`, { waitUntil: 'domcontentloaded', timeout: 60000 });
    for (let i = 0; i < 60; i++) {
      if ((await renderLog(page)).boot_status === 'painted') break;
      await page.waitForTimeout(1000);
    }
    await page.waitForTimeout(5000);
    await enableSemantics(page);
    await page.waitForTimeout(1200);
  };

  await boot();

  for (const door of DOORS) {
    const t0 = Date.now();
    const sel = await findTile(page, door.key, width, 45000);
    if (!sel) {
      results.push({ width, door: door.name, ok: false, why: 'the tile was never built on the Dashboard' });
      await boot();
      continue;
    }
    try { await page.locator(sel).first().click({ timeout: 10000, force: true }); }
    catch (_) { try { await page.evaluate((q) => { const el = document.querySelector(q); if (el) el.click(); }, sel); } catch (_) {} }

    // THE FIVE SECONDS. Nothing is asked of the app while it waits — the whole
    // question is whether it is still standing at the end of them.
    await page.waitForTimeout(DWELL);

    const log = await renderLog(page);
    const alive = !died && await page.evaluate(() => !!document.querySelector('flutter-view') || !!document.querySelector('flt-glass-pane')).catch(() => false);
    const seen = log[door.proof] || '';
    const guarded = log.c2107_screen_guard !== undefined;

    let ok = true, why = '';
    if (!alive) { ok = false; why = 'the app was gone five seconds after the tap'; }
    else if (guarded) { ok = false; why = 'the screen threw — the guard caught it, but the door is broken'; }
    else if (seen !== door.want) { ok = false; why = `expected ${door.proof}=${door.want}, the app recorded "${seen || 'nothing'}"`; }

    try {
      fs.mkdirSync(OUT, { recursive: true });
      await page.screenshot({ path: path.join(OUT, `w${width}_${door.key.replace(/[^a-z0-9]+/gi, '_')}.png`) });
    } catch (_) {}

    results.push({ width, door: door.name, ok, why, ms: Date.now() - t0 });
    say(`w${width} ${door.name}: ${ok ? 'open after ' + DWELL + 'ms' : 'FAILED — ' + why}`);
    await boot();
  }

  await browser.close();
}

(async () => {
  let chromium;
  try { ({ chromium } = require(path.join(HOME, 'node_modules', 'playwright'))); }
  catch (_) {
    try { ({ chromium } = require('playwright')); }
    catch (_) { console.log('route screens journey: SKIPPED — playwright is not installed'); process.exit(2); }
  }
  const session = await signIn();
  if (!session) { console.log('route screens journey: SKIPPED — no super-admin identity on this box'); process.exit(2); }

  const results = [];
  for (const w of WIDTHS) await runWidth(chromium, session, w, results);

  const bad = results.filter((r) => !r.ok);
  const line = bad.length === 0
    ? `route screens journey: PASSED — ${results.length} doors opened and stayed open for ${DWELL}ms at ${WIDTHS.join('/')}px`
    : `route screens journey: FAILED — ${bad.map((b) => `w${b.width} ${b.door} (${b.why})`).join('; ')}`;
  console.log(line);
  process.exit(bad.length === 0 ? 0 : 1);
})().catch((e) => {
  console.log('route screens journey: FAILED — ' + String((e && e.message) || e).slice(0, 300));
  process.exit(1);
});
