// CMD #438 — reachability proof for /customer/staff (CHANGE #408's screen).
//
// render_verify.js drives the ADMIN session; customer_staff_list() answers
// not_authorized for an admin by design, so this drives the CUSTOMER session to
// the deep link, reads the render-log THERE, asserts the screen's own key is
// present, and saves the pixels.
//
//   node scripts/c438_shot.js [path[,path...]] [out.png] [required-key]
//
// Exits non-zero when the key is absent — a screenshot of a screen that never
// painted is not proof.
'use strict';
const { chromium } = require('playwright');
const https = require('https');

const REF = 'swojhmarmaijkshsbeih';
const SUPABASE_URL = `https://${REF}.supabase.co`;
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ';
const KEY = `sb-${REF}-auth-token`;
const TARGET = process.env.MEDIBO_URL || 'https://medibo.in';
const PATHS = (process.argv[2] || '/customer/staff').split(',');
const OUT = process.argv[3] || 'c438_staff.png';
const NEED = process.argv[4] || 'c408_staff_rows';
const EMAIL = process.env.MEDIBO_EMAIL || 'test.cust1@medibo.in';
const PASSWORD = process.env.MEDIBO_PASSWORD || 'TestCust1#26';

function post(url, headers, body) {
  return new Promise((res, rej) => {
    const data = JSON.stringify(body);
    const u = new URL(url);
    const req = https.request({ hostname: u.hostname, path: u.pathname + u.search,
      method: 'POST', headers: { ...headers, 'Content-Length': Buffer.byteLength(data) } },
      (r) => { let b = ''; r.on('data', (c) => b += c); r.on('end', () => { try { res(JSON.parse(b)); } catch (_) { res(null); } }); });
    req.on('error', rej); req.write(data); req.end();
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const s = await post(`${SUPABASE_URL}/auth/v1/token?grant_type=password`,
    { apikey: ANON, 'Content-Type': 'application/json' },
    { email: EMAIL, password: PASSWORD });
  if (!s || !s.access_token) { console.error('auth failed', s); process.exit(1); }
  console.log('authenticated as', s.user && s.user.email);

  const browser = await chromium.launch({ args: ['--no-sandbox'] });
  const ctx = await browser.newContext({ viewport: { width: 430, height: 932 } });
  await ctx.addInitScript(({ key, val }) => localStorage.setItem(key, val),
    { key: KEY, val: JSON.stringify(s) });
  const page = await ctx.newPage();

  await page.goto(TARGET, { waitUntil: 'domcontentloaded', timeout: 45000 });
  await sleep(9000);              // let the shell boot and resolve auth

  let log = '';
  let i = 0;
  for (const p of PATHS) {
    await page.goto(`${TARGET}${p}`, { waitUntil: 'domcontentloaded', timeout: 45000 });
    await sleep(9000);
    const out = i === 0 ? OUT : OUT.replace(/\.png$/, `_${i}.png`);
    await page.screenshot({ path: out });
    console.log('shot', p, '->', out);
    log = await page.evaluate(() => {
      const el = document.querySelector('#medibo-render-log');
      return el ? el.textContent : '';
    });
    i++;
  }

  console.log('── render log ──');
  console.log(log || '(no render log element)');
  await browser.close();

  if (!log || log.indexOf(NEED) === -1) {
    console.error(`MISSING render-log key: ${NEED}`);
    process.exit(2);
  }
  console.log(`OK — ${NEED} present`);
})();
