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

const SUPABASE_URL = process.env.PROD_SUPABASE_URL || process.env.SUPABASE_URL;
const SERVICE_KEY  = process.env.PROD_SERVICE_ROLE_KEY || process.env.SERVICE_ROLE_KEY;

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

async function readRenderLog(page) {
  return page.evaluate(() => {
    try {
      const el = document.getElementById('medibo-render-log');
      if (el && el.textContent) return JSON.parse(el.textContent);
      if (window.__mediboRenderLog) return window.__mediboRenderLog;
    } catch (_) {}
    return null;
  });
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
  say(`responsive sweep · ${TARGET} · widths ${widths.join('/')} · min touch ${minTouch}px`);

  const failures = [];
  const seen = [];
  const browser = await chromium.launch({ args: ['--no-sandbox', '--disable-gpu'] });

  try {
    for (const width of widths) {
      for (const [label, route] of SCREENS) {
        const ctx = await browser.newContext({
          viewport: { width, height: 900 },
          isMobile: width < 900,
          hasTouch: width < 900,
          deviceScaleFactor: 1,
        });
        const page = await ctx.newPage();
        let log = null;
        try {
          const sep = route.includes('?') ? '&' : '?';
          await page.goto(`${TARGET}${route}${sep}responsive_audit=1&min_touch=${minTouch}`,
            { waitUntil: 'domcontentloaded', timeout: 45000 });
          // The audit re-measures for ~16s after boot; give the screen its RPC.
          await page.waitForTimeout(9000);
          log = await readRenderLog(page);
        } catch (e) {
          failures.push(`${label} @${width}px did not load (${String(e.message).slice(0, 80)})`);
        }
        await ctx.close();
        if (!log) {
          if (!failures.some((f) => f.startsWith(`${label} @${width}px`))) {
            failures.push(`${label} @${width}px wrote no render log`);
          }
          continue;
        }
        const overflow = Number(log.overflow_errors || 0);
        const small    = Number(log.tap_targets_small || 0);
        const painted  = String(log.boot_status || '') === 'painted';
        seen.push({ screen: label, width, overflow, small, painted,
                    build: log.build || null, viewport_w: log.viewport_w || null });
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

  const ok = failures.length === 0;
  const detail = ok
    ? `${seen.length} screen/width combinations clean at ${widths.join('/')}px`
    : failures.slice(0, 6).join(' · ');
  const build = (seen.find((s) => s.build) || {}).build || null;

  await rpc('rg_runner_verdict_write', {
    p_name: 'responsive_no_overflow', p_ok: ok, p_detail: detail,
    p_payload: { widths, min_touch_px: minTouch, checked: seen, failures },
    p_build_hash: build,
  });

  say(ok ? `VERDICT ok — ${detail}` : `VERDICT RED — ${detail}`);
  process.exit(ok ? 0 : 1);
})().catch((e) => { console.error('responsive_sweep:', e.message); process.exit(2); });
