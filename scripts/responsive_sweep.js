#!/usr/bin/env node
'use strict';
// CMD #1950 — MOBILE-FIRST: the post-deploy responsive sweep.
//
// 99% of mediBO users are on phones, so after every deploy the top staff and
// customer screens are opened at every phone width the backend names, plus one
// tablet width, and the app is asked what it saw. Flutter web paints to canvas
// — a browser cannot read a clipped row or a small tap target from outside —
// so nothing here measures pixels. The app measures itself (RenderLog +
// lib/utils/responsive_audit.dart) and this script reads the numbers back and
// writes ONE verdict:
//
//   rg_runner_verdict_write('responsive_no_overflow', ok, detail, payload)
//   rg_runner_verdict_write('mobile_first_prompt',    ok, detail, payload)
//
// rg_check's behaviour tests assert those verdicts, so a phone layout that
// overflows turns the guard red with the screen and the width named.
//
// Everything about the policy — which widths, which screens, the touch minimum
// — comes from dev_runner_config.build_rules.mobile_first. Nothing is decided
// in this file.
//
//   node scripts/responsive_sweep.js [--target https://medibo.in] [--quiet]

const { chromium } = require('playwright');

const argVal = (flag, dflt) => {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
};
const TARGET = (argVal('--target', process.env.MEDIBO_TARGET || 'https://medibo.in')).replace(/\/$/, '');
const QUIET = process.argv.includes('--quiet');
const say = (...a) => { if (!QUIET) console.log(...a); };

// deploy.sh runs this with a bare environment, so the runner's env file is the
// fallback — CHANGE #1322 shipped with the sweep exiting before it opened a
// single page because neither variable was set.
function fromRunnerEnv(name) {
  try {
    const fs = require('fs');
    const path = require('path');
    const file = path.join(process.env.MEDIBO_RUNNER_DIR || `${process.env.HOME}/mediBO-runner`, 'runner.env');
    const line = fs.readFileSync(file, 'utf8').split('\n')
      .find((l) => l.trim().startsWith(`${name}=`));
    if (!line) return undefined;
    return line.slice(line.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '');
  } catch (_) { return undefined; }
}

const SUPABASE_URL = process.env.PROD_SUPABASE_URL || process.env.SUPABASE_URL
  || fromRunnerEnv('PROD_SUPABASE_URL') || fromRunnerEnv('SUPABASE_URL');
const SERVICE_KEY  = process.env.PROD_SERVICE_ROLE_KEY || process.env.SERVICE_ROLE_KEY
  || fromRunnerEnv('PROD_SERVICE_ROLE_KEY') || fromRunnerEnv('SERVICE_ROLE_KEY');

async function rpc(fn, body) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body || {}),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${text.slice(0, 200)}`);
  try { return JSON.parse(text); } catch (_) { return text; }
}

// The screens the rule names. Public routes only: the sweep must be able to run
// unattended after every deploy, and an authed capture needs a login the deploy
// lane does not hold. The staff screens are covered by the admin sweep the
// runner drives with render_verify.js --admin-width.
const SCREENS = [
  ['storefront home', '/'],
  ['product page',    '/shop'],
  ['cart',            '/cart'],
  ['checkout',        '/checkout'],
  ['dashboard',       '/dashboard'],
  ['customers',       '/customers'],
  ['fulfill',         '/fulfill'],
  ['money',           '/money'],
];

// Timings. The rule owns them (dev_runner_config.build_rules.mobile_first);
// these are only the fallback for a config that has not named them yet, so a
// flaky edge is retuned with one pool_set and no deploy.
let READ_RETRIES    = 8;      // evaluate attempts across a navigation
let PAINT_BUDGET_MS = 30000;  // how long to wait for boot_status=painted
let SETTLE_MS       = 6000;   // let the audit re-measure once the RPC lands
let NAV_QUIET_MS    = 2500;   // no main-frame navigation for this long = settled
// The whole sweep has a budget. post_deploy_checks.sh wraps it in `timeout`,
// and a killed sweep writes NO verdict at all — the guard then keeps asserting
// a stale one. Stop STARTING combinations before that happens and publish what
// was measured. Widths are walked phone-first, so a short budget always covers
// the phone before the tablet.
let BUDGET_MS       = 720000; // 12 min, inside post_deploy_checks' timeout

// CMD #2009 — a destroyed execution context is NOT a measurement.
// Every staff route sends an anonymous visitor to the storefront, and the
// Flutter bootstrap itself re-navigates once while it installs. Both tear the
// page's execution context down underneath page.evaluate, and the sweep booked
// that as "did not load": 8 of 40 combinations in CHANGE #1371, while all 32 it
// DID read reported overflow=0 and tap_targets_small=0. Read through the
// navigation instead — only an exhausted budget is a failure.
const NAV_RACE = /Execution context was destroyed|Execution context is not available|Target closed|frame was detached|page has been closed/i;

async function evalRenderLog(page) {
  return page.evaluate(() => {
    const el = document.getElementById('medibo-render-log');
    return el ? (el.textContent || el.innerText || '') : '';
  });
}

function parseRenderLog(text) {
  if (!text || !text.trim()) return null;
  const out = {};
  for (const line of text.split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
  }
  return Object.keys(out).length ? out : null;
}

// One read that survives a navigation: re-evaluate against the new document.
async function readRenderLog(page, tries) {
  const n = Math.max(1, Number(tries) || READ_RETRIES);
  for (let i = 0; i < n; i++) {
    try {
      return parseRenderLog(await evalRenderLog(page));
    } catch (e) {
      if (!NAV_RACE.test(String(e && e.message))) throw e;
      try { await page.waitForLoadState('domcontentloaded', { timeout: 15000 }); } catch (_) {}
      try { await page.waitForTimeout(500); } catch (_) { return null; }
    }
  }
  return null;
}

// Wait for the app to say it painted rather than sleeping a fixed amount: a
// 320px cold load on a slow edge takes longer than a 480px warm one, and a
// blank page read too early is indistinguishable from a broken one.
async function waitForPaint(page, budgetMs) {
  const deadline = Date.now() + budgetMs;
  while (Date.now() < deadline) {
    const log = await readRenderLog(page);
    if (log && String(log.boot_status || '') === 'painted') return log;
    try { await page.waitForTimeout(1000); } catch (_) { break; }
  }
  return readRenderLog(page);
}

// Let the redirect flap finish AND the audit re-measure while the screen's RPC
// lands, then read. `nav` is the last main-frame navigation timestamp.
async function settle(page, nav, settleMs, quietMs) {
  const deadline = Date.now() + settleMs + quietMs;
  try { await page.waitForTimeout(settleMs); } catch (_) { return; }
  while (Date.now() < deadline && Date.now() - nav.at < quietMs) {
    try { await page.waitForTimeout(500); } catch (_) { return; }
  }
}

(async () => {
  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error('responsive_sweep: PROD_SUPABASE_URL / PROD_SERVICE_ROLE_KEY are not set');
    process.exit(2);
  }

  // 1 ── the rule decides the widths and the touch minimum, not this file.
  const rules = await rpc('dev_build_rules', {}).catch(() => null);
  const mf = (rules && rules.mobile_first) || {};
  const widths = (mf.sweep_widths && mf.sweep_widths.length ? mf.sweep_widths : [320, 360, 412, 480])
    .concat([mf.tablet_width || 768]);
  const minTouch = mf.min_touch_px || 44;
  READ_RETRIES    = Number(mf.sweep_read_retries)   || READ_RETRIES;
  PAINT_BUDGET_MS = Number(mf.sweep_paint_budget_ms) || PAINT_BUDGET_MS;
  SETTLE_MS       = Number(mf.sweep_settle_ms)      || SETTLE_MS;
  NAV_QUIET_MS    = Number(mf.sweep_nav_quiet_ms)   || NAV_QUIET_MS;
  BUDGET_MS       = Number(mf.sweep_budget_ms)      || BUDGET_MS;
  const deadline  = Date.now() + BUDGET_MS;
  say(`responsive sweep · ${TARGET} · widths ${widths.join('/')} · min touch ${minTouch}px`);

  const failures = [];
  const seen = [];
  const skipped = [];
  const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-gpu'] });

  try {
    for (const width of widths) {
      for (const [label, route] of SCREENS) {
        if (Date.now() >= deadline) { skipped.push(`${label} @${width}px`); continue; }
        const ctx = await browser.newContext({
          viewport: { width, height: 900 },
          isMobile: width < 900,
          hasTouch: width < 900,
          deviceScaleFactor: 1,
        });
        const page = await ctx.newPage();
        // The staff routes bounce an anonymous visitor to the storefront, and
        // the bounce is what used to kill the read. Track it instead: the last
        // main-frame navigation says when the page stopped moving, and the URL
        // we actually measured is recorded with the numbers.
        const nav = { at: Date.now(), count: 0 };
        page.on('framenavigated', (f) => {
          if (f === page.mainFrame()) { nav.at = Date.now(); nav.count += 1; }
        });
        let log = null;
        let err = null;
        try {
          const sep = route.includes('?') ? '&' : '?';
          await page.goto(`${TARGET}${route}${sep}responsive_audit=1&min_touch=${minTouch}`,
            { waitUntil: 'domcontentloaded', timeout: 45000 });
          // Wait for the app's own "painted", let the redirect flap finish and
          // the audit re-measure while the screen's RPC lands, then read.
          await waitForPaint(page, PAINT_BUDGET_MS);
          await settle(page, nav, SETTLE_MS, NAV_QUIET_MS);
          log = await readRenderLog(page);
        } catch (e) {
          err = String(e && e.message).slice(0, 80);
          // A navigation race is not a verdict — one last look once the page
          // has stopped moving.
          if (NAV_RACE.test(String(e && e.message))) {
            try { await page.waitForLoadState('domcontentloaded', { timeout: 15000 }); } catch (_) {}
            try {
              await settle(page, nav, 2000, NAV_QUIET_MS);
              log = await readRenderLog(page);
            } catch (_) { /* the page is gone; the missing log is the failure */ }
          }
        }
        let finalUrl = null;
        try { finalUrl = page.url(); } catch (_) { /* context already closed */ }
        await ctx.close();
        if (!log) {
          failures.push(`${label} @${width}px did not load (${err || 'wrote no render log'})`);
          continue;
        }
        const overflow = Number(log.overflow_errors || 0);
        const small    = Number(log.tap_targets_small || 0);
        const painted  = String(log.boot_status || '') === 'painted';
        seen.push({ screen: label, width, overflow, small, painted,
                    build: log.build || null, viewport_w: log.viewport_w || null,
                    url: finalUrl, navs: nav.count });
        if (!painted) failures.push(`${label} @${width}px never painted (boot_status=${log.boot_status || 'none'})`);
        if (overflow > 0) {
          failures.push(`${label} @${width}px overflowed ${overflow}x — ${log.overflow_first || 'no detail'}`);
        }
        if (small > 0) {
          failures.push(`${label} @${width}px has ${small} tap target(s) under ${minTouch}px — ${log.tap_target_worst || 'no detail'}`);
        }
        say(`  ${String(width).padStart(4)}px  ${label.padEnd(16)} ${painted ? 'painted' : 'BLANK'}  overflow=${overflow}  small_taps=${small}`);
      }
    }
  } finally {
    await browser.close();
  }

  // An unmeasured combination is not a regression (the behaviour test says the
  // same about a verdict that has never been written) — it is reported, not
  // failed, so the budget can never turn the guard red on its own.
  const ok = failures.length === 0;
  const tail = skipped.length ? ` · ${skipped.length} not measured inside the budget` : '';
  const detail = (ok
    ? `${seen.length} screen/width combinations clean at ${widths.join('/')}px`
    : failures.slice(0, 6).join(' · ')) + tail;
  const build = (seen.find((s) => s.build) || {}).build || null;

  await rpc('rg_runner_verdict_write', {
    p_name: 'responsive_no_overflow', p_ok: ok, p_detail: detail,
    p_payload: { widths, min_touch_px: minTouch, checked: seen, failures, skipped },
    p_build_hash: build,
  });

  say(ok ? `VERDICT ok — ${detail}` : `VERDICT RED — ${detail}`);
  process.exit(ok ? 0 : 1);
})().catch((e) => { console.error('responsive_sweep:', e.message); process.exit(2); });
