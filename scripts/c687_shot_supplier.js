#!/usr/bin/env node
/**
 * c687_shot_supplier.js — pixel proof for an AUTHED SUPPLIER route.
 *
 * render_verify.js can drive the logged-in ADMIN to a route (--admin-path) and
 * capture it; shot.sh can capture a public URL. Neither can photograph a screen
 * that only a SUPPLIER can reach, and the #687 countdown lives on two of those:
 * the supplier's inquiry tab and the Accept / Decline card on his purchase
 * order. This does exactly that and nothing else — sign in as the documented
 * supplier test credential, wait for Flutter to paint, optionally send the
 * wheel (Flutter draws its own scroller, so window.scrollTo does nothing), and
 * save the pixels.
 *
 *   node scripts/c687_shot_supplier.js --out proof.png [--wheel 600]
 *       [--width 430] [--height 1200] [--wait-key inq.src.mode]
 *
 * Exit 0 on a capture, 1 on anything else. It never writes to the database.
 */
'use strict';
const { chromium } = require('playwright');
const https = require('https');

const PROJECT_REF  = 'swojhmarmaijkshsbeih';
const SUPABASE_URL = `https://${PROJECT_REF}.supabase.co`;
const ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ';
const STORAGE_KEY  = `sb-${PROJECT_REF}-auth-token`;
const TARGET       = process.env.MEDIBO_URL || 'https://medibo.in';
const EMAIL = process.env.MEDIBO_SUP_EMAIL || 'test.sup1@medibo.in';
const PASS  = process.env.MEDIBO_SUP_PASS  || 'TestSup1#26';

const argv = process.argv.slice(2);
const val = (f, d) => {
  const i = argv.indexOf(f);
  return i !== -1 && argv[i + 1] ? argv[i + 1] : d;
};

function post(url, headers, body) {
  return new Promise((res, rej) => {
    const data = JSON.stringify(body);
    const u = new URL(url);
    const req = https.request(
      { hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
        headers: { ...headers, 'Content-Length': Buffer.byteLength(data) } },
      (r) => { let b = ''; r.on('data', (c) => (b += c));
               r.on('end', () => { try { res(JSON.parse(b)); } catch (e) { rej(e); } }); });
    req.on('error', rej);
    req.write(data);
    req.end();
  });
}

(async () => {
  const out    = val('--out');
  const wheel  = parseInt(val('--wheel', '0'), 10);
  const width  = parseInt(val('--width', '430'), 10);
  const height = parseInt(val('--height', '1200'), 10);
  const waitKey = val('--wait-key', '');
  const path   = val('--path', '');
  if (!out) { console.error('c687_shot_supplier: --out <file.png> is required'); process.exit(1); }

  console.log(`Authenticating ${EMAIL}...`);
  const session = await post(`${SUPABASE_URL}/auth/v1/token?grant_type=password`,
    { apikey: ANON_KEY, 'Content-Type': 'application/json' },
    { email: EMAIL, password: PASS });
  if (!session.access_token) {
    console.error(`auth failed: ${JSON.stringify(session).slice(0, 200)}`);
    process.exit(1);
  }
  console.log(`  session for ${session.user && session.user.email}`);

  const distro = '/usr/bin/chromium';
  const opts = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
  if (require('fs').existsSync(distro)) opts.executablePath = distro;
  const browser = await chromium.launch(opts);
  try {
    const ctx = await browser.newContext({ viewport: { width, height } });
    await ctx.addInitScript(({ k, v }) => localStorage.setItem(k, v),
      { k: STORAGE_KEY, v: JSON.stringify(session) });
    const page = await ctx.newPage();
    await page.goto(TARGET + path, { waitUntil: 'domcontentloaded', timeout: 40000 });

    // Flutter paints into a canvas; the render-log element is the only honest
    // "it is up" signal there is.
    const deadline = Date.now() + 45000;
    let log = '';
    while (Date.now() < deadline) {
      log = await page.evaluate(() => {
        const el = document.getElementById('medibo-render-log');
        return el ? el.textContent : '';
      });
      if (log && (!waitKey || log.includes(waitKey))) break;
      await page.waitForTimeout(1000);
    }
    console.log(`  render-log: ${log ? log.slice(0, 400) : '<empty>'}`);

    if (wheel) {
      await page.mouse.move(Math.round(width / 2), Math.round(height / 2));
      let done = 0;
      while (done < wheel) {
        const step = Math.min(400, wheel - done);
        await page.mouse.wheel(0, step);
        done += step;
        await page.waitForTimeout(150);
      }
      await page.waitForTimeout(500);
    }

    await page.screenshot({ path: out, fullPage: false });
    console.log(out);
    await browser.close();
    process.exit(0);
  } catch (e) {
    console.error(`c687_shot_supplier: ${e.message}`);
    try { await browser.close(); } catch (_) {}
    process.exit(1);
  }
})();
