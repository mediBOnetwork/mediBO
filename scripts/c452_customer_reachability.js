// CMD #452 — reachability proof for the customer self-service surfaces.
//
// The Orders screen is where feature_gaps #130, #131 and #132 became visible:
// the action row (Cancel order / Return items / Need help with this order?) and
// the Help requests entry tile. render_verify.js's customer phase deep-links to
// a CATEGORY page, which is a different screen, so this proves the one that
// changed.
//
// It reads pixels and the #medibo-render-log DOM node exactly the way
// render_verify.js does. It never drives the Flutter canvas — no CDP clicking,
// no canvas reading — and it writes nothing to production.
//
//   node scripts/c452_customer_reachability.js [--shot <dir>]
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const TARGET = process.env.MEDIBO_URL || 'https://medibo.in';
const SUPABASE_URL = 'https://swojhmarmaijkshsbeih.supabase.co';
const PROJECT_REF = SUPABASE_URL.split('//')[1].split('.')[0];
const STORAGE_KEY = `sb-${PROJECT_REF}-auth-token`;
const ANON_KEY = fs
  .readFileSync(path.join(__dirname, '..', 'lib', 'supabase_config.dart'), 'utf8')
  .match(/'([A-Za-z0-9._-]{40,})'/)[1];

const EMAIL = process.env.MEDIBO_CUST_EMAIL || 'test.cust1@medibo.in';
const PASS = process.env.MEDIBO_CUST_PASS || 'TestCust1#26';

// The keys this command's widgets write when they actually render.
const WANT = ['c452_order_actions'];

const shotDir = process.argv.includes('--shot')
  ? process.argv[process.argv.indexOf('--shot') + 1]
  : null;

async function login() {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: EMAIL, password: PASS }),
  });
  const s = await res.json();
  if (!s.access_token) throw new Error(`auth failed: ${JSON.stringify(s)}`);
  return s;
}

function parseLog(text) {
  const out = {};
  for (const line of (text || '').split('\n')) {
    const i = line.indexOf('=');
    if (i > 0) out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return out;
}

async function readRenderLog(page) {
  return page.evaluate(() => {
    const el = document.getElementById('medibo-render-log');
    return el ? el.textContent : '';
  });
}

(async () => {
  const session = await login();
  console.log(`✓ signed in as ${session.user?.email}`);

  const distro = '/usr/bin/chromium';
  const opts = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
  if (fs.existsSync(distro)) opts.executablePath = distro;
  const browser = await chromium.launch(opts);

  let ok = false;
  let log = {};
  try {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 1000 } });
    await ctx.addInitScript(
      ({ key, val }) => localStorage.setItem(key, val),
      { key: STORAGE_KEY, val: JSON.stringify(session) },
    );
    const page = await ctx.newPage();
    page.on('console', () => {});

    await page.goto(`${TARGET}/orders`, {
      waitUntil: 'domcontentloaded',
      timeout: 45000,
    });

    // Poll for the action row's own key rather than a fixed sleep: the orders
    // list is one RPC, and the row only exists once it lands.
    for (let waited = 0; waited <= 60; waited += 2) {
      log = parseLog(await readRenderLog(page));
      if (WANT.every((k) => k in log)) break;
      await page.waitForTimeout(2000);
    }

    const version = await (await fetch(`${TARGET}/version.json`)).json();
    const hashOk = log['build'] === version.commit;
    const missing = WANT.filter((k) => !(k in log));
    const actionCount = parseInt(log['c452_order_actions'] || '0', 10);

    console.log(`  build hash : got=${log['build']} want=${version.commit} → ${hashOk ? '✓' : '✗'}`);
    console.log(`  boot       : ${log['boot_status']}`);
    console.log(`  keys       : ${missing.length ? 'MISSING ' + missing.join(', ') : 'all present'}`);
    console.log(`  actions    : c452_order_actions=${log['c452_order_actions']}`);

    if (shotDir) {
      fs.mkdirSync(shotDir, { recursive: true });
      await page.screenshot({ path: path.join(shotDir, 'c452-orders-actions.png'), fullPage: false });
      console.log(`  shot       : ${path.join(shotDir, 'c452-orders-actions.png')}`);

      // #182 — the cart line for a product with NO MRP on record. It must show
      // the backend's own note, never ₹0.00.
      await page.goto(`${TARGET}/cart`, { waitUntil: 'domcontentloaded', timeout: 45000 });
      await page.waitForTimeout(8000);
      await page.screenshot({ path: path.join(shotDir, 'c452-cart-no-mrp.png'), fullPage: false });
      console.log(`  shot       : ${path.join(shotDir, 'c452-cart-no-mrp.png')}`);
    }

    ok = hashOk && missing.length === 0 && actionCount > 0;
  } finally {
    await browser.close();
  }

  console.log(ok ? '\n✅ REACHABLE — the action row rendered on the live build'
                 : '\n❌ NOT PROVEN');
  process.exit(ok ? 0 : 1);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
