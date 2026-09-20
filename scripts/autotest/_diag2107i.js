const api = require('./api');
const { chromium } = require('./harness');
const WANT = 'c1891_tile_admin.cust_tab.routes_today';
const URL0 = 'https://medibo.in/admin/dashboard?responsive_audit=1';
async function findTap(page, ms) {
  const dl = Date.now() + ms; let scrolls = 0;
  const sels = [`[flt-semantics-identifier="${WANT}"]`];
  while (Date.now() < dl) {
    for (const s of sels) { try { if (await page.locator(s).count() > 0) return scrolls; } catch (_) {} }
    await page.evaluate(() => { const ph = document.querySelector('flt-semantics-placeholder'); if (ph) try { ph.click(); } catch (_) {} });
    if (scrolls < 12) { const vp = page.viewportSize(); await page.mouse.move(vp.width/2, vp.height*0.6); await page.mouse.wheel(0, Math.round(vp.height*0.7)); scrolls++; }
    await page.waitForTimeout(700);
  }
  return null;
}
(async () => {
  const s = await api.signIn('test.super@medibo.in', api.passwordFor('super_admin'));
  const b = await chromium.launch({ headless: true });
  for (const mode of ['reload (engine today)', 'goto original (proposed)', 'no second navigation']) {
    const ctx = await b.newContext({ viewport: { width: 360, height: 800 }, isMobile: true, hasTouch: true, deviceScaleFactor: 1, ignoreHTTPSErrors: true });
    const e = api.storageEntry(s);
    await ctx.addInitScript(({ key, v }) => { try { localStorage.setItem(key, v); } catch (_) {} }, { key: e.key, v: e.value });
    const p = await ctx.newPage();
    await p.goto(URL0, { waitUntil: 'domcontentloaded', timeout: 60000 });
    try { await p.waitForLoadState('load', { timeout: 30000 }); } catch (_) {}
    await p.waitForTimeout(8000);
    if (mode.startsWith('reload')) { await p.reload({ waitUntil: 'domcontentloaded', timeout: 60000 }); await p.waitForTimeout(6000); }
    if (mode.startsWith('goto')) { await p.goto(URL0, { waitUntil: 'domcontentloaded', timeout: 60000 }); await p.waitForTimeout(6000); }
    const r = await findTap(p, 40000);
    console.log(mode, '=>', r === null ? 'NOT FOUND' : `FOUND after ${r} scrolls`);
    await ctx.close();
  }
  await b.close();
})().catch(x => { console.error('ERR', x.message); process.exit(1); });
