#!/usr/bin/env node
// CHANGE #229 — reachability proof for the Order closure screen.
//
// CLAUDE.md bans CDP/canvas clicking, so "an admin can reach this screen"
// cannot be proved by driving the nav. It CAN be proved by giving the screen a
// real URL and loading it with a real admin session: the screen writes
// c229_order_closure_screen / c229_order_closure_rows into the render-log, and
// the render-log is the only accepted proof that a Flutter widget rendered.
//
//   node scripts/verify_order_closure.js [--shot out.png] [--timeout 60]
//
// Exit 0 = the screen rendered on the live build (build hash matches and the
// key is present). Exit 1 = it did not — the wiring is broken, keep fixing.
'use strict';
const { chromium } = require('playwright');
const https = require('https');

const PROJECT_REF  = 'swojhmarmaijkshsbeih';
const SUPABASE_URL = `https://${PROJECT_REF}.supabase.co`;
const ANON_KEY     = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ';
const STORAGE_KEY  = `sb-${PROJECT_REF}-auth-token`;
const ADMIN_EMAIL  = 'test.admin@medibo.in';
const ADMIN_PASS   = 'TestAdmin#26';
const TARGET       = process.env.MEDIBO_URL || 'https://medibo.in';
const ROUTE        = '/admin/order-closure';
const KEY          = 'c229_order_closure_screen';
const ROWS_KEY     = 'c229_order_closure_rows';
const MAX_RETRIES  = 3;

const argv = process.argv.slice(2);
const argVal = (f) => {
  const i = argv.findIndex(a => a === f);
  if (i !== -1 && argv[i + 1]) return argv[i + 1];
  const p = argv.find(a => a.startsWith(f + '='));
  return p ? p.split('=').slice(1).join('=') : null;
};
const timeoutSec = parseInt(argVal('--timeout') || '60', 10);
const shotPath   = argVal('--shot');

function httpsPost(url, headers, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
      headers: { ...headers, 'Content-Length': Buffer.byteLength(data) },
    }, res => {
      let out = '';
      res.on('data', c => out += c);
      res.on('end', () => { try { resolve(JSON.parse(out)); } catch { resolve(out); } });
    });
    req.on('error', reject);
    req.write(data); req.end();
  });
}
function httpsGet(url) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    https.get({ hostname: u.hostname, path: u.pathname + u.search }, res => {
      let out = '';
      res.on('data', c => out += c);
      res.on('end', () => { try { resolve(JSON.parse(out)); } catch { resolve(out); } });
    }).on('error', reject);
  });
}
const parseLog = (t) => Object.fromEntries(
  (t || '').split('\n').map(l => l.trim()).filter(Boolean)
    .map(l => { const i = l.indexOf('='); return i === -1 ? null : [l.slice(0, i), l.slice(i + 1)]; })
    .filter(Boolean));
const readRenderLog = (page) => page.evaluate(() => {
  const el = document.getElementById('medibo-render-log');
  return el ? (el.textContent || el.innerText || '') : '';
});

async function main() {
  console.log(`\n🔍 verify_order_closure — ${TARGET}${ROUTE}`);
  const version = await httpsGet(`${TARGET}/version.json`);
  const expectedHash = typeof version === 'object' ? version.commit : String(version).trim();
  console.log(`📌 Expected build hash: ${expectedHash} (change ${version.change})`);

  const session = await httpsPost(
    `${SUPABASE_URL}/auth/v1/token?grant_type=password`,
    { apikey: ANON_KEY, 'Content-Type': 'application/json' },
    { email: ADMIN_EMAIL, password: ADMIN_PASS });
  if (!session.access_token) throw new Error(`Auth failed: ${JSON.stringify(session)}`);
  console.log(`🔐 Session for ${session.user?.email}`);

  const distro = '/usr/bin/chromium';
  const opts = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
  if (require('fs').existsSync(distro)) opts.executablePath = distro;
  const browser = await chromium.launch(opts);

  let passed = false;
  for (let attempt = 1; attempt <= MAX_RETRIES && !passed; attempt++) {
    console.log(`\n  Attempt ${attempt}/${MAX_RETRIES}`);
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    await ctx.addInitScript(({ key, val }) => localStorage.setItem(key, val),
      { key: STORAGE_KEY, val: JSON.stringify(session) });
    const page = await ctx.newPage();
    page.on('console', () => {});
    try {
      await page.goto(`${TARGET}${ROUTE}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
      const deadline = Date.now() + timeoutSec * 1000;
      let log = {};
      while (Date.now() < deadline) {
        await page.waitForTimeout(1500);
        log = parseLog(await readRenderLog(page));
        if (log[KEY] !== undefined) break;
      }
      await page.waitForTimeout(4000);
      log = parseLog(await readRenderLog(page));

      const hashOk = log['build'] === expectedHash;
      const keyOk  = log[KEY] !== undefined;
      console.log(`  Build hash : got=${log['build']} want=${expectedHash} → ${hashOk ? '✓' : '✗'}`);
      console.log(`  ${KEY} : ${keyOk ? `✓ ${log[KEY]}` : '✗ MISSING — the screen did not render'}`);
      console.log(`  ${ROWS_KEY} : ${log[ROWS_KEY] === undefined ? '(not written)' : log[ROWS_KEY]}`);
      if (shotPath && keyOk) {
        await page.screenshot({ path: shotPath, fullPage: false });
        console.log(`  Screenshot : ${shotPath}`);
      }
      passed = hashOk && keyOk;
    } catch (err) {
      console.error(`  Error: ${err.message}`);
    } finally {
      await ctx.close();
    }
  }
  await browser.close();
  console.log(passed ? '\n✅ Order closure screen VERIFIED on the live build'
                     : '\n❌ Order closure screen did NOT render');
  process.exit(passed ? 0 : 1);
}
main().catch(e => { console.error(e); process.exit(1); });
