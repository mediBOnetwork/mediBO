#!/usr/bin/env node
/**
 * boot_check.js — the deploy lane's boot gate.
 *
 *   node ~/boot_check.js <build-dir>        # e.g. build/web
 *
 * WHY THIS EXISTS
 * A dart2js bundle can compile cleanly and still boot-hang in a browser — the
 * exact failure CLAUDE.md's "NEVER skip flutter clean" rule was written for
 * (2026-07-03: identical source, corrupt bundle, white screen). `flutter build`
 * exiting 0 proves nothing about that; only loading the artifact does.
 *
 * WHY IT WAS WRITTEN AGAIN (CHANGE #173)
 * scripts/deploy.sh has called `node ~/boot_check.js "$WEB"` at this gate for a
 * long time, but the file existed only in the home directory of a box that no
 * longer exists — the same unversioned-script death the GCP→EC2 move caused for
 * render_verify.js (#187/#192). On this builder the gate did not "pass", it
 * crashed with MODULE_NOT_FOUND, and deploy.sh reported "BOOT GATE FAILED —
 * bundle would hang on load" for every deploy regardless of the bundle. So the
 * gate is now versioned here, next to render_verify.js, with a thin shim at
 * ~/boot_check.js. Do not move the logic back into the home directory.
 *
 * WHAT IT ASSERTS (all of it real — a gate that cannot fail is worse than none)
 *   1. The built index.html actually loads over HTTP from the build directory.
 *   2. The bundle parses and runs: no uncaught exception before first paint.
 *   3. Flutter reaches first paint — either the app's own render-log reports a
 *      boot_status, or Flutter's host element is in the DOM. A hang (the corrupt
 *      -bundle signature) never reaches either, so it times out and FAILS.
 *
 * Exit 0 = safe to deploy. Exit 1 = do not deploy. Exit 2 = the gate itself
 * could not run (missing browser/dir) — also non-zero, because an unverifiable
 * bundle must never be treated as a verified one.
 */
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');

const BUILD_DIR = path.resolve(process.argv[2] || 'build/web');
const TIMEOUT_MS = parseInt(process.env.BOOT_CHECK_TIMEOUT_MS || '60000', 10);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.map': 'application/json; charset=utf-8',
};

function fail(code, msg) {
  console.error(`[boot-gate] ${msg}`);
  process.exit(code);
}

// A static server for the built directory. Unknown paths fall back to
// index.html so the app's own client-side routes resolve, exactly as the
// Cloudflare _redirects rule does in production.
function serve(dir) {
  const server = http.createServer((req, res) => {
    const urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
    let filePath = path.join(dir, urlPath);
    if (!filePath.startsWith(dir)) return res.writeHead(403).end(); // traversal
    if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
      const indexed = path.join(filePath, 'index.html');
      filePath = fs.existsSync(indexed) ? indexed : path.join(dir, 'index.html');
    }
    if (!fs.existsSync(filePath)) return res.writeHead(404).end();
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream',
      // The service worker and any cache header would only confuse a one-shot
      // check; the gate must read THIS build, never a cached earlier one.
      'Cache-Control': 'no-store',
    });
    fs.createReadStream(filePath).pipe(res);
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

function launchBrowser() {
  // Same resolution order as render_verify.js: never hardcode a box-specific
  // binary path — that is what broke the verifier on the EC2 cutover (#187).
  const distro = '/usr/bin/chromium';
  const opts = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
  if (fs.existsSync(distro)) opts.executablePath = distro;
  try {
    return require('playwright').chromium.launch(opts);
  } catch (_) {
    return require('puppeteer').launch(opts);
  }
}

(async () => {
  if (!fs.existsSync(path.join(BUILD_DIR, 'index.html'))) {
    fail(2, `no index.html in ${BUILD_DIR} — nothing to validate.`);
  }

  const { server, port } = await serve(BUILD_DIR);
  const target = `http://127.0.0.1:${port}/`;
  console.log(`[boot-gate] serving ${BUILD_DIR} → ${target}`);

  let browser;
  try {
    browser = await launchBrowser();
  } catch (e) {
    server.close();
    fail(2, `cannot launch a browser: ${e.message}\n            install one: (cd ~ && npm install puppeteer)`);
  }

  const pageErrors = [];
  let verdict = null;

  try {
    const page = await browser.newPage();
    page.on('pageerror', (e) => pageErrors.push(String(e && e.message ? e.message : e)));
    page.on('console', (m) => {
      if (m.type() === 'error') pageErrors.push(m.text());
    });

    await page.goto(target, { waitUntil: 'domcontentloaded', timeout: 30000 });

    // Poll for first paint. Either signal is proof the bundle ran: the app's
    // own render-log (what CLAUDE.md verifies against in production) or the
    // Flutter host element it paints into.
    const deadline = Date.now() + TIMEOUT_MS;
    while (Date.now() < deadline && !verdict) {
      const state = await page.evaluate(() => {
        const el = document.getElementById('medibo-render-log');
        const log = el ? (el.textContent || el.innerText || '') : '';
        const painted = !!(
          document.querySelector('flt-glass-pane') ||
          document.querySelector('flutter-view') ||
          document.querySelector('flt-scene-host')
        );
        return { log, painted };
      });
      if (state.log.includes('boot_status')) verdict = `render-log reported ${state.log.match(/boot_status=[^\s;,]*/)[0]}`;
      else if (state.painted) verdict = 'Flutter host element painted';
      else await new Promise((r) => setTimeout(r, 1000));
    }
  } catch (e) {
    pageErrors.push(`navigation failed: ${e.message}`);
  } finally {
    if (browser) await browser.close().catch(() => {});
    server.close();
  }

  // Errors are reported either way — a bundle that paints but throws is still
  // worth seeing in the deploy log — but only a missing first paint blocks.
  if (pageErrors.length) {
    console.log(`[boot-gate] ${pageErrors.length} console/page error(s) during boot:`);
    for (const e of pageErrors.slice(0, 5)) console.log(`             • ${e.slice(0, 200)}`);
  }

  if (!verdict) {
    fail(1, `bundle never reached first paint within ${TIMEOUT_MS / 1000}s — this is the corrupt-bundle / boot-hang signature.`);
  }

  console.log(`[boot-gate] first paint confirmed — ${verdict}`);
  process.exit(0);
})().catch((e) => fail(2, `gate crashed: ${e && e.stack ? e.stack : e}`));
