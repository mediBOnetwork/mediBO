'use strict';
// CHANGE #634 — the harness. Playwright drives the REAL deployed web app.
//
// What it may honestly assert, and why it is shaped this way:
// mediBO's UI is drawn to a canvas, so no browser tool can read a Flutter
// widget — CLAUDE.md forbids pretending otherwise, permanently. Two things ARE
// readable from the outside and both are written by the app itself:
//   • #medibo-render-log — the app's own record of what it painted, including
//     c325_deep_link (the route it actually opened) and boot_status.
//   • flt-semantics[id="…"] — the accessibility node Flutter emits for a
//     Semantics(identifier:) widget, once the semantics tree is switched on.
// Everything else the bot does, it does as a signed-in user through the same
// RPCs the app calls. That is a real end-to-end, not a mime of one.
//
// Per run it keeps: a video per feature, a screenshot per step, every console
// error, every failed network call, and the test session id the run owns.
const fs = require('fs');
const path = require('path');
const api = require('./api');

let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (_) {
  try {
    ({ chromium } = require(path.join(process.env.HOME || '/home/ubuntu', 'node_modules', 'playwright')));
  } catch (e) {
    chromium = null;
  }
}

const DEFAULT_VIEWPORT = { width: 1280, height: 900 };

function slug(s) { return String(s).replace(/[^a-zA-Z0-9._-]+/g, '_'); }

class FeatureSession {
  constructor(opts) {
    this.browser = opts.browser;
    this.baseUrl = opts.baseUrl;
    this.artifactDir = opts.artifactDir;
    this.feature = opts.feature;
    this.role = opts.role;
    this.runId = opts.runId;
    this.consoleErrors = [];
    this.networkFailures = [];
    this.shots = [];
    this.stepLog = [];
    this.token = null;
    this.userId = null;
    this.ctx = null;
    this.page = null;
    this.scratch = {};          // journey scripts park what they picked here
  }

  async open(session) {
    const ctxOpts = {
      viewport: DEFAULT_VIEWPORT,
      recordVideo: { dir: this.artifactDir, size: DEFAULT_VIEWPORT },
      ignoreHTTPSErrors: true
    };
    this.ctx = await this.browser.newContext(ctxOpts);
    if (session) {
      const entry = api.storageEntry(session);
      await this.ctx.addInitScript(({ key, val }) => {
        try { localStorage.setItem(key, val); } catch (_) {}
      }, { key: entry.key, val: entry.value });
      this.token = session.access_token;
      this.userId = session.user && session.user.id;
    }
    this.page = await this.ctx.newPage();
    this.page.on('console', (m) => {
      if (m.type() === 'error') this.consoleErrors.push(String(m.text()).slice(0, 500));
    });
    this.page.on('requestfailed', (r) => {
      this.networkFailures.push({ url: String(r.url()).slice(0, 300),
                                  error: (r.failure() && r.failure().errorText) || 'failed' });
    });
    this.page.on('response', (r) => {
      if (r.status() >= 500) {
        this.networkFailures.push({ url: String(r.url()).slice(0, 300), error: 'HTTP ' + r.status() });
      }
    });
  }

  async shot(name) {
    if (!this.page) return null;
    const file = path.join(this.artifactDir,
      `${slug(this.feature)}__${slug(this.role || 'anon')}__${String(this.shots.length + 1).padStart(2, '0')}_${slug(name)}.png`);
    try {
      await this.page.screenshot({ path: file, fullPage: false });
      this.shots.push(path.basename(file));
      return file;
    } catch (_) { return null; }
  }

  // The app's own render log, parsed. It is a hidden DOM node the app writes,
  // which is why it is readable when the pixels are not.
  async renderLog() {
    try {
      const raw = await this.page.evaluate(() => {
        const el = document.getElementById('medibo-render-log');
        return el ? (el.textContent || '') : '';
      });
      const out = {};
      for (const part of String(raw).split(/[\n;]+/)) {
        const i = part.indexOf('=');
        if (i > 0) out[part.slice(0, i).trim()] = part.slice(i + 1).trim();
      }
      out.__raw = String(raw).slice(0, 4000);
      return out;
    } catch (_) { return { __raw: '' }; }
  }

  // Polls ACROSS navigations on purpose. index.html reloads the page once per
  // session (the PWA freshness guard), which destroys the execution context
  // mid-boot: a reader that treated that as an error would call every deep
  // link broken. renderLog() swallows it, this keeps asking.
  async waitForRenderKey(key, equals, timeoutMs) {
    const deadline = Date.now() + (timeoutMs || 45000);
    let last = {};
    while (Date.now() < deadline) {
      last = await this.renderLog();
      const v = last[key];
      if (v !== undefined && (equals === undefined || equals === null || equals === '' || String(v) === String(equals))) {
        return { ok: true, value: v };
      }
      await this.page.waitForTimeout(500);
    }
    return { ok: false, value: last[key], raw: (last.__raw || '').slice(0, 400) };
  }

  async close() {
    let video = null;
    try {
      if (this.page && this.page.video()) {
        const p = await this.page.video().path();
        video = p ? path.basename(p) : null;
      }
    } catch (_) {}
    try { await this.ctx.close(); } catch (_) {}
    return video;
  }
}

// ── the step vocabulary ───────────────────────────────────────────────────
// A contract's steps[] is data. Every kind here is one thing the harness knows
// how to do; a kind it does not know is reported, never guessed at.
const STEPS = {
  async auth(fs_, step) {
    return { ok: true, note: `signed in as ${fs_.role}` };
  },

  async goto(fs_, step) {
    const url = fs_.baseUrl.replace(/\/+$/, '') + (step.path || '/');
    const res = await fs_.page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    try { await fs_.page.waitForLoadState('load', { timeout: 30000 }); } catch (_) { /* the reload guard */ }
    return { ok: true, note: `${url} -> ${res ? res.status() : 'no response'}` };
  },

  async settle(fs_, step) {
    await fs_.page.waitForTimeout(Math.min(step.ms || 4000, 30000));
    try { await fs_.page.waitForLoadState('load', { timeout: 15000 }); } catch (_) {}
    return { ok: true };
  },

  async expect_render(fs_, step) {
    const r = await fs_.waitForRenderKey(step.key, step.equals, step.timeout_ms || 45000);
    return r.ok
      ? { ok: true, note: `${step.key}=${r.value}` }
      : { ok: false, note: `${step.key} never became ${step.equals} (saw ${r.value === undefined ? 'nothing' : r.value})` };
  },

  // A Semantics(identifier:) target. Only used where the app actually exposes
  // one — never a coordinate, never a canvas guess.
  async tap(fs_, step) {
    const sel = `flt-semantics[id="${step.identifier}"]`;
    try {
      await fs_.page.waitForSelector(sel, { timeout: step.timeout_ms || 10000 });
      await fs_.page.click(sel);
      return { ok: true, note: `tapped ${step.identifier}` };
    } catch (e) {
      return { ok: false, note: `no semantics node ${step.identifier}: ${String(e.message).slice(0, 160)}` };
    }
  },

  // Act as the signed-in user through the same RPC the app calls.
  async rpc(fs_, step) {
    const args = Object.assign({}, step.args || {}, fs_.scratch.rpcArgs && fs_.scratch.rpcArgs[step.fn] || {});
    const asService = step.as === 'service';
    const out = await api.rpc(step.fn, args, asService ? null : fs_.token);
    fs_.scratch.lastRpc = out;
    const refused = out && typeof out === 'object' && out.ok === false;
    return { ok: !refused, note: `${step.fn} -> ` + JSON.stringify(out).slice(0, 240) };
  },

  // Journey-specific steps register themselves here (see journeys/).
};

function registerStep(kind, fn) { STEPS[kind] = fn; }

async function runStep(fs_, step, index) {
  const started = Date.now();
  const handler = STEPS[step.kind];
  let res;
  if (!handler) {
    res = { ok: false, note: `unknown step kind '${step.kind}' — the harness does not guess` };
  } else {
    try {
      res = await handler(fs_, step);
    } catch (e) {
      res = { ok: false, note: String(e && e.message || e).slice(0, 400) };
    }
  }
  const shot = await fs_.shot(`${index + 1}_${step.kind}`);
  const entry = Object.assign({ n: index + 1, kind: step.kind }, res,
    { ms: Date.now() - started, shot: shot ? path.basename(shot) : null });
  fs_.stepLog.push(entry);
  return entry;
}

// Check the contract's ONE end-state assertion, last.
async function checkExpect(fs_, expect) {
  if (!expect || !expect.kind) return { ok: true, note: 'no end state declared' };
  if (expect.kind === 'visible') {
    if (expect.source === 'render_log') {
      const r = await fs_.waitForRenderKey(expect.key, expect.equals, expect.timeout_ms || 45000);
      return r.ok
        ? { ok: true, note: `render-log ${expect.key}=${r.value}` }
        : { ok: false, note: `render-log ${expect.key} never became ${expect.equals} (saw ${r.value === undefined ? 'nothing' : r.value})` };
    }
    if (expect.identifier) {
      try {
        await fs_.page.waitForSelector(`flt-semantics[id="${expect.identifier}"]`, { timeout: 15000 });
        return { ok: true, note: `semantics ${expect.identifier} present` };
      } catch (e) { return { ok: false, note: `semantics ${expect.identifier} never appeared` }; }
    }
    return { ok: false, note: `visible assertion with no source the harness knows` };
  }
  if (expect.kind === 'db') {
    // The assertion itself is a backend function. The harness never writes SQL
    // and never decides what "placed an order" means.
    const out = await api.rpc(expect.rpc, { p_run_id: fs_.runId }, null);
    return { ok: Boolean(out && out.ok),
             note: (out && (out.detail || JSON.stringify(out))) || 'no answer' };
  }
  return { ok: false, note: `unknown end-state kind '${expect.kind}'` };
}

module.exports = { chromium, FeatureSession, runStep, checkExpect, registerStep, STEPS, slug };
