#!/usr/bin/env node
'use strict';
// CMD #2075 — THE FEATURE JOURNEY RUNNER.
//
//   node scripts/autotest/feature_journey.js --command <id> --lane preview|live \
//        --target <url> [--change <n>] [--commit <sha>] [--budget-s 300] [--dry]
//
// One command, one browser journey of its own (feat-<id>), declared as DATA on
// the control plane (dev_feature_journey_set) and read back here through
// dev_feature_journey_get. This script decides nothing about WHAT to test: the
// plan says open <route> → tap <Semantics identifier> → expect_nav <route> →
// expect_rpc <fn> (seen in the page's own network log) → assert_sql (a boolean
// the database answers). It runs the plan at EVERY width the rule names (360px
// and 412px) in ONE Playwright launch, inside a purging TEST MODE session
// (test_run_start / test_run_finish on production), keeps a video, the network
// log, the SQL proof and one screenshot per width, uploads them to
// dev-cmd-proofs, and records the lane's verdict with dev_feature_journey_record.
//
// Only the last line is for the caller: "feature journey feat-<id> on <lane>:
// PASSED|FAILED — <detail>". Everything else goes to stderr and the log file.
//
// Exit codes (the wrapper and the deploy lane read these, nothing else):
//   0 passed at every width          1 failed (a red step, a red assertion)
//   2 could not run (not declared, plan invalid, no identity/password, no
//     playwright)                    3 the TEST MODE session was refused
//   4 attempts exhausted for this change (max_reruns)   5 crashed mid-run
const fs = require('fs');
const path = require('path');
const https = require('https');
const api = require('./api');
const harness = require('./harness');

const argv = process.argv.slice(2);
const flag = (n) => argv.includes('--' + n);
const val = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

const CMD = parseInt(val('command', '0'), 10);
const LANE = val('lane', 'live');
const TARGET = (val('target', 'https://medibo.in')).replace(/\/+$/, '');
const CHANGE = val('change', '') ? parseInt(val('change'), 10) : null;
const COMMIT = val('commit', '') || null;
const SUMMARY_FILE = process.env.FJ_SUMMARY_FILE || '';
const HOME = process.env.HOME || '/home/ubuntu';
const t0 = Date.now();

function say(...a) { console.error('[fj] ' + a.join(' ')); }
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
// The CONTROL PLANE (medibo-dev): the journey definition and the verdict live
// there. runner.env's SUPABASE_URL/SERVICE_ROLE_KEY are that project's.
const renv = loadEnvFile(path.join(HOME, 'mediBO-runner', 'runner.env'));
const CTL_URL = process.env.MEDIBO_CTL_URL || renv.SUPABASE_URL || '';
const CTL_KEY = process.env.MEDIBO_CTL_KEY || renv.SERVICE_ROLE_KEY || '';

function ctlRpc(fn, params) {
  return new Promise((resolve, reject) => {
    if (!CTL_URL || !CTL_KEY) return reject(new Error('no control-plane credentials in ~/mediBO-runner/runner.env'));
    const u = new URL(`${CTL_URL}/rest/v1/rpc/${fn}`);
    const data = JSON.stringify(params || {});
    const req = https.request({ hostname: u.hostname, path: u.pathname, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data),
                 apikey: CTL_KEY, Authorization: `Bearer ${CTL_KEY}` } }, (res) => {
      let buf = ''; res.on('data', (d) => buf += d);
      res.on('end', () => {
        let p = buf; try { p = buf ? JSON.parse(buf) : null; } catch (_) {}
        if (res.statusCode >= 400) { const e = new Error(`${fn} -> ${res.statusCode}: ${String(buf).slice(0, 300)}`); e.status = res.statusCode; return reject(e); }
        resolve(p);
      });
    });
    req.on('error', reject);
    req.setTimeout(30000, () => req.destroy(new Error(`${fn} timed out`)));
    req.write(data); req.end();
  });
}

// PRODUCTION storage: proofs live in dev-cmd-proofs, next to every screenshot.
function upload(localFile, bucketPath, contentType) {
  return new Promise((resolve) => {
    let body; try { body = fs.readFileSync(localFile); } catch (_) { return resolve(null); }
    const u = new URL(`${api.SUPA_URL}/storage/v1/object/dev-cmd-proofs/${bucketPath}`);
    let headers;
    try { headers = api.serviceHeaders({ 'Content-Type': contentType, 'x-upsert': 'true', 'Content-Length': body.length }); }
    catch (_) { return resolve(null); }
    const req = https.request({ hostname: u.hostname, path: u.pathname, method: 'POST', headers }, (res) => {
      res.resume(); res.on('end', () => resolve(res.statusCode < 400 ? bucketPath : null));
    });
    req.on('error', () => resolve(null));
    req.setTimeout(120000, () => { req.destroy(); resolve(null); });
    req.write(body); req.end();
  });
}

let summary = { command: CMD, lane: LANE, target: TARGET, status: 'not_run', exit: 2 };
function writeSummary(obj) {
  summary = Object.assign(summary, obj, { at: new Date().toISOString(), elapsed_s: Math.round((Date.now() - t0) / 1000) });
  if (SUMMARY_FILE) { try { fs.writeFileSync(SUMMARY_FILE, JSON.stringify(summary, null, 2)); } catch (_) {} }
}
function finish(line, code) {
  writeSummary({ exit: code, line });
  console.log(line);
  process.exit(code);
}

// ── the step vocabulary, on a plain page (no FeatureSession: two contexts) ──
async function renderLog(page) {
  try {
    const raw = await page.evaluate(() => { const el = document.getElementById('medibo-render-log'); return el ? (el.textContent || '') : ''; });
    const out = {};
    for (const part of String(raw).split(/[\n;]+/)) { const i = part.indexOf('='); if (i > 0) out[part.slice(0, i).trim()] = part.slice(i + 1).trim(); }
    return out;
  } catch (_) { return {}; }
}
async function waitRenderKey(page, key, equals, ms) {
  const dl = Date.now() + ms; let last;
  while (Date.now() < dl) {
    const rl = await renderLog(page); last = rl[key];
    if (last !== undefined && (equals == null || equals === '' || String(last) === String(equals) || String(last).includes(String(equals)))) return { ok: true, value: last };
    await page.waitForTimeout(500);
  }
  return { ok: false, value: last };
}
// Flutter web: Semantics(identifier:) is the flt-semantics-identifier attribute
// (engine semantics.dart, Flutter 3.47). Older builds used the DOM id; both are
// tried, the attribute first.
function tapSelectors(id) {
  const q = String(id).replace(/"/g, '\\"');
  return [`[flt-semantics-identifier="${q}"]`, `flt-semantics[id="${q}"]`, `#${id.replace(/[^a-zA-Z0-9_-]/g, '\\$&')}`];
}
async function enableSemantics(page) {
  // The app switches its semantics tree on for ?responsive_audit=1 (CMD #1950);
  // the engine's own placeholder button is the fallback.
  try {
    await page.evaluate(() => {
      const ph = document.querySelector('flt-semantics-placeholder');
      if (ph) { try { ph.click(); } catch (_) {} }
    });
  } catch (_) {}
}
async function findTap(page, id, ms) {
  // Flutter only builds what is laid out: a section far down a lazy list has no
  // semantics node until the list is scrolled to it (lesson 340). So a node that
  // is not on the page is looked for again after each scroll of the viewport,
  // until the budget runs out.
  const dl = Date.now() + ms; const sels = tapSelectors(id); let scrolls = 0;
  while (Date.now() < dl) {
    for (const s of sels) {
      try { const n = await page.locator(s).count(); if (n > 0) return s; } catch (_) {}
    }
    await enableSemantics(page);
    if (scrolls < 12) {
      try {
        const vp = page.viewportSize() || { width: 360, height: 800 };
        await page.mouse.move(Math.round(vp.width / 2), Math.round(vp.height * 0.6));
        await page.mouse.wheel(0, Math.round(vp.height * 0.7));
      } catch (_) {}
      scrolls++;
    }
    await page.waitForTimeout(700);
  }
  return null;
}
// what the page DOES expose — printed into a failed tap's note so the next
// person knows whether semantics were off or the node was simply never built
async function semanticsDiag(page) {
  try {
    return await page.evaluate(() => {
      const all = document.querySelectorAll('flt-semantics');
      const ids = []; all.forEach((e) => { const v = e.getAttribute('flt-semantics-identifier') || e.id; if (v && ids.length < 12 && !ids.includes(v)) ids.push(v); });
      const ph = !!document.querySelector('flt-semantics-placeholder');
      return `${all.length} semantics node(s), placeholder=${ph}, identifiers: ${ids.join(', ') || 'none'}`;
    });
  } catch (e) { return 'diag failed: ' + String(e.message).slice(0, 80); }
}
function withAudit(route) {
  // keep the route's own query, add the app's semantics switch
  if (/[?&]responsive_audit=/.test(route)) return route;
  return route + (route.includes('?') ? '&' : '?') + 'responsive_audit=1';
}

async function runWidth(browser, width, plan, session, ctx0) {
  const height = 800;
  const dir = ctx0.artifactDir;
  const context = await browser.newContext({
    viewport: { width, height }, isMobile: true, hasTouch: true, deviceScaleFactor: 1,
    recordVideo: { dir, size: { width, height } }, ignoreHTTPSErrors: true
  });
  const entry = api.storageEntry(session);
  await context.addInitScript(({ key, v }) => { try { localStorage.setItem(key, v); } catch (_) {} }, { key: entry.key, v: entry.value });
  const page = await context.newPage();
  const net = []; const consoleErrors = [];
  page.on('response', (r) => {
    try {
      const u = r.url(); const m = u.match(/\/rest\/v1\/rpc\/([A-Za-z0-9_]+)/);
      net.push({ t: Date.now() - t0, method: r.request().method(), url: u.slice(0, 200), status: r.status(), fn: m ? m[1] : null });
    } catch (_) {}
  });
  page.on('requestfailed', (r) => { try { net.push({ t: Date.now() - t0, method: r.method(), url: r.url().slice(0, 200), status: 0, fn: null, error: (r.failure() || {}).errorText || 'failed' }); } catch (_) {} });
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(String(m.text()).slice(0, 300)); });

  const steps = []; let ok = true; let failed_step = null; let lastActionIdx = 0; let shot = null;
  const sqlProof = [];
  const snap = async (n, kind) => {
    const f = path.join(dir, `w${width}_${String(n).padStart(2, '0')}_${kind}.png`);
    try { await page.screenshot({ path: f, fullPage: false }); shot = f; } catch (_) {}
  };
  for (let i = 0; i < plan.length; i++) {
    const s = plan[i]; const n = i + 1; const st = Date.now(); let res = { ok: false, note: '' };
    if (Date.now() > ctx0.deadline) { res = { ok: false, note: `budget of ${ctx0.budgetS}s exhausted before step ${n}` }; }
    else try {
      switch (s.kind) {
        case 'open': {
          lastActionIdx = net.length;
          const url = TARGET + withAudit(s.route || '/');
          const r = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
          try { await page.waitForLoadState('load', { timeout: 30000 }); } catch (_) {}
          let painted = await waitRenderKey(page, 'boot_status', 'painted', 60000);
          let dl = '';
          if (painted.ok && /^\/admin\//.test(s.route || '')) {
            // An admin deep link is opened by the shell only once the session
            // has resolved to an admin. Injected sessions sometimes lose that
            // race on a cold boot (the route stays parked): wait for the app's
            // own record that it opened, and reload ONCE when it never comes.
            let opened = await waitRenderKey(page, 'c325_deep_link_opened', '', 8000);
            if (!opened.ok) {
              say(`w${width} open: deep link not opened after 8 s — reloading once`);
              try { await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 }); } catch (_) {}
              painted = await waitRenderKey(page, 'boot_status', 'painted', 60000);
              opened = await waitRenderKey(page, 'c325_deep_link_opened', '', 25000);
            }
            dl = opened.ok ? `, deep link opened (${opened.value})` : ', deep link NOT opened';
          }
          await enableSemantics(page);
          await page.waitForTimeout(1500);
          res = painted.ok ? { ok: true, note: `${url} -> ${r ? r.status() : '?'}, painted${dl}` }
                           : { ok: false, note: `${url} never painted (boot_status=${painted.value === undefined ? 'nothing' : painted.value})` };
          break;
        }
        case 'tap': {
          lastActionIdx = net.length;
          const sel = await findTap(page, s.identifier, s.timeout_ms || 25000);
          if (!sel) {
            const rl = await renderLog(page);
            res = { ok: false, note: `no semantics node "${s.identifier}" on the page — ${await semanticsDiag(page)}; deep_link_opened=${rl.c325_deep_link_opened || 'none'}` };
            break;
          }
          try { await page.locator(sel).first().click({ timeout: 10000, force: true }); }
          catch (e) {
            // an overlay node that Playwright deems not actionable still takes a DOM click
            await page.evaluate((q) => { const el = document.querySelector(q); if (el) el.click(); }, sel);
          }
          await page.waitForTimeout(1200);
          res = { ok: true, note: `tapped ${s.identifier} via ${sel}` };
          break;
        }
        case 'expect_nav': {
          const want = String(s.route || s.contains || '');
          const dl = Date.now() + (s.timeout_ms || 15000); let seen = '';
          while (Date.now() < dl) {
            if ((s.source || 'url') === 'render_log') {
              const rl = await renderLog(page); seen = String(rl[s.key || 'c325_deep_link_opened'] || '');
            } else { seen = decodeURIComponent(page.url()); }
            if (seen.includes(want)) break;
            await page.waitForTimeout(500);
          }
          res = seen.includes(want) ? { ok: true, note: `on ${seen.slice(0, 120)}` }
                                    : { ok: false, note: `expected navigation to contain "${want}", saw "${seen.slice(0, 120)}"` };
          break;
        }
        case 'expect_rpc': {
          const dl = Date.now() + (s.timeout_ms || 20000); let hit = null;
          while (Date.now() < dl && !hit) {
            hit = net.slice(lastActionIdx).find((e) => e.fn === s.fn && e.status > 0 && e.status < 400) || null;
            if (!hit) await page.waitForTimeout(500);
          }
          const any = net.slice(lastActionIdx).find((e) => e.fn === s.fn);
          res = hit ? { ok: true, note: `${s.fn} seen in the network log (HTTP ${hit.status})` }
                    : { ok: false, note: any ? `${s.fn} answered HTTP ${any.status}` : `${s.fn} never called after the last action (${net.length - lastActionIdx} calls seen)` };
          break;
        }
        case 'assert_sql': {
          let out;
          if ((s.lane || 'app') === 'dev') out = await ctlRpc('dev_journey_sql_assert', { p_command_id: CMD, p_sql: s.sql, p_run_id: ctx0.runId, p_session_id: ctx0.sessionId });
          else out = await api.rpc('test_journey_sql_assert', { p_sql: s.sql, p_run_id: ctx0.runId, p_session_id: ctx0.sessionId }, null);
          sqlProof.push({ width, n, lane: s.lane || 'app', label: s.label || '', sql: s.sql, result: out });
          res = out && out.ok === true ? { ok: true, note: `${s.label || 'sql'}: true` }
              : { ok: false, note: `${s.label || 'sql'}: ${out && out.error ? out.error : 'false'}` };
          break;
        }
        default: res = { ok: false, note: `unknown step kind "${s.kind}"` };
      }
    } catch (e) { res = { ok: false, note: String((e && e.message) || e).slice(0, 300) }; }
    await snap(n, s.kind);
    steps.push({ n, kind: s.kind, ok: res.ok, note: res.note, ms: Date.now() - st });
    say(`w${width} step ${n} ${s.kind}: ${res.ok ? 'ok' : 'FAIL'} — ${res.note}`);
    if (!res.ok) { ok = false; failed_step = `w${width} step ${n} (${s.kind}): ${res.note}`; break; }
  }
  let video = null;
  try { const v = page.video(); if (v) { const p = await v.path(); await context.close(); if (p && fs.existsSync(p)) { const f = path.join(dir, `w${width}.webm`); fs.renameSync(p, f); video = f; } } else { await context.close(); } }
  catch (_) { try { await context.close(); } catch (_) {} }
  return { width, ok, failed_step, steps, net, consoleErrors, video, shot, sqlProof };
}

async function main() {
  if (!CMD) finish('feature journey: --command <id> is required', 2);
  if (!api.hasServiceKey()) finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — no service key on this box`, 2);
  let def;
  try { def = await ctlRpc('dev_feature_journey_get', { p_command_id: CMD }); }
  catch (e) { finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — ${e.message}`, 2); }
  if (!def || def.ok !== true) finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — ${JSON.stringify(def).slice(0, 200)}`, 2);
  if (!def.needed && !def.has) finish(`feature journey feat-${CMD} on ${LANE}: SKIPPED — ${def.why}`, 0);
  if (!def.has) finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — not declared (devcmd.sh feature_journey ${CMD} derive, then set)`, 2);
  if (!def.valid) {
    try { await ctlRpc('dev_feature_journey_record', { p_command_id: CMD, p_lane: LANE, p_status: 'skipped', p_evidence: { note: 'plan invalid: ' + def.error, target: TARGET }, p_change_no: CHANGE, p_commit: COMMIT }); } catch (_) {}
    finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — plan invalid: ${def.error}`, 2);
  }
  const widths = Array.isArray(def.widths) && def.widths.length ? def.widths.map(Number) : [360, 412];
  const budgetS = parseInt(val('budget-s', String(def.budget_s || 300)), 10);
  const plan = def.plan;
  if (flag('dry')) { console.log(JSON.stringify({ def, widths, budgetS }, null, 2)); return 0; }

  const att = await ctlRpc('dev_feature_journey_attempt', { p_command_id: CMD, p_lane: LANE, p_change_no: CHANGE });
  if (att && att.allowed === false) finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — ${att.note}`, 4);
  if (!harness.chromium) finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — playwright is not installed on this box`, 2);

  // who drives it: the role's test identity (production), its password from the VM
  const role = def.role || 'super_admin';
  // A 5xx / timeout from production before the run has opened is the
  // environment, not the feature: one retry after 20 s, then NOT RUN (3) —
  // the same reading smoke_gate.sh gives a session it could not open.
  const isTransport = (e) => { const st = e && e.status; const m = String((e && e.message) || e); return (st >= 500) || !st && /timed out|ECONN|EAI_AGAIN|socket hang up|fetch failed/i.test(m); };
  async function pre(fn, params) {
    try { return await api.rpc(fn, params, null); }
    catch (e) {
      if (!isTransport(e)) throw e;
      say(`${fn}: ${String(e.message).slice(0, 120)} — retrying once in 20 s`);
      await new Promise((r) => setTimeout(r, 20000));
      try { return await api.rpc(fn, params, null); }
      catch (e2) {
        if (!isTransport(e2)) throw e2;
        finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — production did not answer ${fn} (${String(e2.message).slice(0, 100)})`, 3);
      }
    }
  }
  const idents = await pre('test_identities', {});
  const ident = (idents || []).find((r) => r.role === role);
  if (!ident || !ident.ready || !ident.identity) finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — no ready test identity for role '${role}' (${(ident && ident.note) || 'no row'})`, 2);
  const password = api.passwordFor(role);
  if (!password) finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — no AUTOTEST_PASS_${role.toUpperCase()} in ~/.medibo/autotest.env (scripts/seed_test_identities.sh sets it)`, 2);
  let session;
  try { session = await api.signIn(ident.identity, password); }
  catch (e) { finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — sign-in failed for role '${role}': ${String(e.message).slice(0, 160)}`, isTransport(e) ? 3 : 2); }

  // the purging TEST MODE session — the run is stamped and purged as a whole.
  // --no-session is a REHEARSAL of the browser steps only: no session, no run
  // row, and the lane is recorded as 'skipped' so it can never count as green.
  const noSession = flag('no-session');
  const started = noSession ? { ok: true, run_id: null, test_session_id: null } : await pre('test_run_start', {
    p_kind: 'feature_' + LANE, p_target_url: TARGET, p_commit: COMMIT, p_deploy_no: CHANGE,
    p_command_id: CMD, p_triggered_by: 'feature_journey', p_note: `feat-${CMD} ${LANE} ${att.note || ''}`.trim(), p_open_session: true
  });
  if (!started || !started.ok) {
    const why = (started && (started.message || started.error)) || 'unknown';
    try { await ctlRpc('dev_feature_journey_record', { p_command_id: CMD, p_lane: LANE, p_status: 'skipped', p_evidence: { note: 'test session refused: ' + why, target: TARGET }, p_change_no: CHANGE, p_commit: COMMIT }); } catch (_) {}
    finish(`feature journey feat-${CMD} on ${LANE}: NOT RUN — test session refused: ${why}`, 3);
  }
  const runId = started.run_id; const sessionId = started.test_session_id;
  const root = process.env.AUTOTEST_ARTIFACTS || path.join(HOME, 'mediBO-runner', 'autotest-runs');
  const artifactDir = path.join(root, `fj-${CMD}-${LANE}-${runId == null ? 'rehearsal-' + Date.now() : runId}`); fs.mkdirSync(artifactDir, { recursive: true });
  writeSummary({ status: 'running', run_id: runId, session_id: sessionId, artifacts: artifactDir });
  say(`run ${runId} · session ${sessionId} · ${role} (${ident.identity}) · ${TARGET} · widths ${widths.join('/')} · attempt ${att.attempt_no}/${att.max}`);

  const browser = await harness.chromium.launch({ headless: true });
  const results = []; let crashed = null;
  const ctx0 = { artifactDir, runId, sessionId, budgetS, deadline: t0 + budgetS * 1000 };
  try {
    for (const w of widths) results.push(await runWidth(browser, w, plan, session, ctx0));
  } catch (e) { crashed = String((e && e.message) || e).slice(0, 300); say('CRASH ' + crashed); }
  try { await browser.close(); } catch (_) {}

  const passed = results.filter((r) => r.ok).map((r) => r.width);
  const failed = results.filter((r) => !r.ok).map((r) => r.width);
  for (const w of widths) if (!results.find((r) => r.width === w)) failed.push(w);
  const allOk = !crashed && failed.length === 0 && passed.length === widths.length;
  const firstFail = results.find((r) => !r.ok);
  const consoleErrors = results.reduce((a, r) => a + r.consoleErrors.length, 0);
  const netFail = results.reduce((a, r) => a + r.net.filter((e) => e.status === 0 || e.status >= 500).length, 0);

  // the ledger files: one network log + one sql proof per lane, a video and a shot per width
  const netFile = path.join(artifactDir, 'network.json');
  fs.writeFileSync(netFile, JSON.stringify(Object.fromEntries(results.map((r) => [r.width, r.net])), null, 1));
  const sqlFile = path.join(artifactDir, 'sql_proof.json');
  fs.writeFileSync(sqlFile, JSON.stringify(results.flatMap((r) => r.sqlProof), null, 1));
  const base = `${CMD}/journey/${LANE}${CHANGE ? '/c' + CHANGE : ''}`;
  const uploaded = { videos: {}, shots: {} };
  uploaded.network_log = await upload(netFile, `${base}/network.json`, 'application/json');
  uploaded.sql_proof = await upload(sqlFile, `${base}/sql_proof.json`, 'application/json');
  for (const r of results) {
    if (r.video) uploaded.videos[r.width] = await upload(r.video, `${base}/w${r.width}.webm`, 'video/webm');
    if (r.shot) {
      const p = await upload(r.shot, `${CMD}/fj_${LANE}_${r.width}w.png`, 'image/png');
      uploaded.shots[r.width] = p;
      if (p) { try { await ctlRpc('dev_proof_note', { p_name: p, p_command_id: CMD, p_width_px: r.width }); } catch (_) {} }
    }
  }

  // close the run: the status is stated, never inferred from a results table this run never writes
  let finished = null;
  if (!noSession) try {
    finished = await api.rpc('test_run_finish', { p_run_id: runId, p_status: allOk ? 'passed' : 'failed', p_artifacts_path: artifactDir,
      p_console_errors: consoleErrors, p_network_failures: netFail, p_purge: true }, null);
  } catch (e) { say('test_run_finish failed: ' + e.message); }
  const purge = (finished && finished.purge) || {};

  const evidence = {
    target: TARGET, run_id: runId, session_id: sessionId, role, identity: ident.identity,
    widths_passed: passed, widths_failed: failed, failed_step: crashed ? 'crash: ' + crashed : (firstFail ? firstFail.failed_step : null),
    note: allOk ? `passed at ${widths.map((w) => w + 'px').join(' + ')}` : (crashed || (firstFail && firstFail.failed_step) || 'no width ran'),
    video: uploaded.videos[widths[0]] || null, videos: uploaded.videos, shots: uploaded.shots,
    network_log: uploaded.network_log, sql_proof: uploaded.sql_proof,
    steps: Object.fromEntries(results.map((r) => [r.width, r.steps])),
    console_errors: consoleErrors, network_failures: netFail,
    purge: { clean: purge.clean, residue: purge.residue, message: typeof purge.message === 'string' ? purge.message.slice(0, 200) : undefined },
    attempt: att.attempt_no, commit: COMMIT, artifacts: artifactDir,
    rehearsal: noSession || undefined
  };
  if (noSession) evidence.note = 'REHEARSAL without a test session (--no-session) — ' + evidence.note;
  let rec = null;
  try {
    rec = await ctlRpc('dev_feature_journey_record', { p_command_id: CMD, p_lane: LANE, p_status: noSession ? 'skipped' : (allOk ? 'passed' : 'failed'),
      p_evidence: evidence, p_change_no: CHANGE, p_commit: COMMIT, p_duration_ms: Date.now() - t0 });
  } catch (e) { say('record failed: ' + e.message); }
  fs.writeFileSync(path.join(artifactDir, 'run.json'), JSON.stringify({ def, evidence, finished, rec }, null, 1));
  const detail = (!noSession && rec && rec.line) ? rec.line.replace(/^feature journey [^:]+: /, '') : evidence.note;
  writeSummary({ status: allOk ? 'passed' : 'failed', widths_passed: passed, widths_failed: failed, failed_step: evidence.failed_step, green: !!(rec && rec.green), run_id: runId });
  finish(`feature journey feat-${CMD} on ${LANE}: ${allOk ? 'PASSED' : 'FAILED'} — ${detail}`, allOk ? 0 : (crashed ? 5 : 1));
}

main().catch((e) => {
  const msg = String((e && e.message) || e).slice(0, 300);
  finish(`feature journey feat-${CMD} on ${LANE}: CRASHED — ${msg}`, 5);
});
