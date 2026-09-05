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

  // ── CHANGE #635, the hostile vocabulary ────────────────────────────────
  // Every kind below exists because a variant row in test_hostile_variant
  // asks for it. The bot still decides nothing: which features get which of
  // these is `applies_when`, in SQL.

  // Replay the feature's OWN contract steps, so a hostile variant starts from
  // the state the happy path reaches instead of an empty page. `stop_after`
  // stops it part-way — that is what "mid-flow" means.
  async replay_contract(fs_, step) {
    const steps = Array.isArray(fs_.scratch.contractSteps) ? fs_.scratch.contractSteps : [];
    const stop = step.stop_after ? Math.min(step.stop_after, steps.length) : steps.length;
    for (let i = 0; i < stop; i++) {
      const s = Object.assign({}, steps[i]);
      if (s.role === '{role}') s.role = fs_.role;
      const out = await runStep(fs_, s, fs_.stepLog.length);
      if (!out.ok) {
        // The happy path itself could not be reached. That is the happy path's
        // failure, already recorded against it — the hostile variant has
        // nothing to say about a screen it never got to.
        return { ok: false, blocked: true, note: `contract step ${i + 1} (${s.kind}) did not hold: ${out.note}` };
      }
    }
    return { ok: true, note: `replayed ${stop}/${steps.length} contract step(s)` };
  },

  // Send the SAME write twice. Passing means the second one was refused with
  // the backend's own words, or was a genuine no-op. Failing means it applied
  // twice — the double-tap bug, proven rather than eyeballed.
  async rpc_twice(fs_, step) {
    const target = pickRpc(fs_, step);
    if (!target) return { ok: false, blocked: true, note: 'the contract has no user rpc to repeat' };
    const args = argsFor(fs_, target);
    let a, b;
    try { a = await api.rpc(target.fn, args, fs_.token); }
    catch (e) { return { ok: false, blocked: true, note: `first ${target.fn} did not go through: ${short(e)}` }; }
    try { b = await api.rpc(target.fn, args, fs_.token); }
    catch (e) {
      // A 4xx on the SECOND call is a refusal, which is the good outcome.
      const st = e && e.status;
      return st && st >= 400 && st < 500
        ? { ok: true, note: `${target.fn} refused the repeat with HTTP ${st}` }
        : { ok: false, note: `${target.fn} repeat blew up: ${short(e)}` };
    }
    const refused = b && typeof b === 'object' && b.ok === false;
    const same = JSON.stringify(idOf(a)) === JSON.stringify(idOf(b));
    if (refused) return { ok: true, note: `${target.fn} refused the repeat: ${msgOf(b)}` };
    if (same) return { ok: true, note: `${target.fn} was idempotent — the repeat returned the same record` };
    return { ok: false, note:
      `${target.fn} APPLIED TWICE — first ${JSON.stringify(idOf(a))}, repeat ${JSON.stringify(idOf(b))}` };
  },

  // Empty and enormous. Passing means a refusal the backend worded; failing
  // means a 5xx, which is the app crashing on input a user can type.
  async rpc_fuzz(fs_, step) {
    const target = pickRpc(fs_, step);
    if (!target) return { ok: false, blocked: true, note: 'the contract has no user rpc to fuzz' };
    const base = argsFor(fs_, target);
    let args;
    if (step.mode === 'empty') {
      args = {};
      for (const k of Object.keys(base)) args[k] = typeof base[k] === 'string' ? '' : null;
    } else {
      const big = 'A'.repeat(Math.min(step.size || 20000, 100000));
      args = Object.assign({}, base);
      for (const k of Object.keys(args)) if (typeof args[k] === 'string') args[k] = big;
      if (!Object.keys(args).length) args = { p_q: big };
    }
    try {
      const out = await api.rpc(target.fn, args, fs_.token);
      const refused = out && typeof out === 'object' && out.ok === false;
      return { ok: true, note: refused
        ? `${target.fn} refused ${step.mode} input: ${msgOf(out)}`
        : `${target.fn} accepted ${step.mode} input without erroring` };
    } catch (e) {
      const st = (e && e.status) || 0;
      if (st >= 400 && st < 500) return { ok: true, note: `${target.fn} refused ${step.mode} input with HTTP ${st}` };
      return { ok: false, note: `${target.fn} returned HTTP ${st || '?'} on ${step.mode} input: ${short(e)}` };
    }
  },

  async go_back(fs_) {
    try { await fs_.page.goBack({ waitUntil: 'domcontentloaded', timeout: 30000 }); }
    catch (e) { return { ok: false, note: `back button threw: ${short(e)}` }; }
    await fs_.page.waitForTimeout(2000);
    return { ok: true, note: 'went back one entry' };
  },

  async reload(fs_) {
    try { await fs_.page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 }); }
    catch (e) { return { ok: false, note: `reload threw: ${short(e)}` }; }
    return { ok: true, note: 'reloaded' };
  },

  // Corrupt the stored session the way an expired token looks to the app, then
  // the variant reloads. The app must land on its login surface, not a white
  // screen — which is what still_painted asserts afterwards.
  async expire_session(fs_) {
    const key = `sb-${api.PROJECT_REF}-auth-token`;
    try {
      await fs_.page.evaluate((k) => {
        try {
          const raw = localStorage.getItem(k);
          if (!raw) return;
          const j = JSON.parse(raw);
          j.expires_at = 1;
          j.access_token = String(j.access_token || '').slice(0, 12) + '.expired.signature';
          localStorage.setItem(k, JSON.stringify(j));
        } catch (_) {}
      }, key);
    } catch (e) { return { ok: false, note: `could not reach localStorage: ${short(e)}` }; }
    return { ok: true, note: 'stored session expired' };
  },

  async offline(fs_) { await fs_.ctx.setOffline(true); return { ok: true, note: 'network off' }; },
  async online(fs_)  { await fs_.ctx.setOffline(false); return { ok: true, note: 'network on' }; },

  // A write attempted with the network down. It must fail like a network
  // failure, not take the page with it.
  async rpc_offline(fs_, step) {
    const target = pickRpc(fs_, step);
    if (!target) return { ok: true, note: 'no user rpc to attempt offline' };
    try {
      await fs_.page.evaluate(async (fn) => { try { await fetch('/rest/v1/rpc/' + fn, { method: 'POST' }); } catch (_) {} }, target.fn);
    } catch (_) {}
    return { ok: true, note: `attempted ${target.fn} with the network down` };
  },

  // A pipeline stage interrupted from underneath the user. The backend owns
  // what the interruption IS (test_mode_action); the bot only asks for it and
  // reports the answer.
  async pipeline_interrupt(fs_, step) {
    const out = await api.rpc('test_hostile_interrupt', {
      p_stage: step.stage || '', p_action: step.action || '',
      p_run: fs_.runId, p_role: fs_.role }, null);
    if (!out || out.ok !== true) {
      return { ok: false, note: `interrupt ${step.stage}/${step.action}: ` + JSON.stringify(out).slice(0, 300) };
    }
    fs_.scratch.lastInterrupt = out;
    return { ok: true, note: (out.detail || JSON.stringify(out)).slice(0, 300) };
  },

  // Journey-specific steps register themselves here (see journeys/).
};

// ── helpers the hostile steps share ───────────────────────────────────────
function short(e) { return String((e && e.message) || e).slice(0, 300); }
function msgOf(o) { return String((o && (o.message || o.error)) || JSON.stringify(o)).slice(0, 240); }
// What a write returned that IDENTIFIES the thing it created. Comparing whole
// payloads would call a timestamp a duplicate.
function idOf(o) {
  if (!o || typeof o !== 'object') return o;
  const out = {};
  for (const k of ['id', 'order_id', 'payment_id', 'invoice_no', 'order_code', 'row_id', 'entry_id']) {
    if (o[k] !== undefined) out[k] = o[k];
  }
  return Object.keys(out).length ? out : (o.ok === false ? { refused: true } : null);
}
// The rpc a hostile variant means when it says use:"last_rpc" — the contract's
// own last user-token call, which is the write the happy path ends on.
function pickRpc(fs_, step) {
  if (step.fn) return { fn: step.fn, args: step.args || {} };
  const steps = Array.isArray(fs_.scratch.contractSteps) ? fs_.scratch.contractSteps : [];
  for (let i = steps.length - 1; i >= 0; i--) {
    const s = steps[i];
    if (s && s.kind === 'rpc' && s.as !== 'service') return s;
  }
  return null;
}
function argsFor(fs_, step) {
  return Object.assign({}, step.args || {},
    (fs_.scratch.rpcArgs && fs_.scratch.rpcArgs[step.fn]) || {});
}

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
  // CHANGE #635 — the three hostile end states.
  // `survives` is already decided by the steps (rpc_twice says which of
  // refused/idempotent happened); reaching here means none of them failed.
  if (expect.kind === 'survives' || expect.kind === 'graceful_refusal') {
    const bad = fs_.stepLog.filter((s) => s.ok === false);
    return bad.length
      ? { ok: false, note: bad.map((b) => `${b.kind}: ${b.note}`).join(' · ').slice(0, 400) }
      : { ok: true, note: 'the app refused or absorbed it without breaking' };
  }
  // The one thing a canvas app must never do, and the one thing that IS
  // readable from outside it: the app's own record that it is still painting.
  if (expect.kind === 'still_painted') {
    const r = await fs_.waitForRenderKey('boot_status', 'painted', expect.timeout_ms || 30000);
    if (!r.ok) {
      return { ok: false, note: `boot_status never returned to painted (saw ${r.value === undefined ? 'nothing' : r.value})` };
    }
    const fatal = fs_.consoleErrors.filter((e) => /uncaught|unhandled|null check operator|type '.*' is not a subtype/i.test(e));
    return fatal.length
      ? { ok: false, note: `still painted, but the console threw: ${fatal[0].slice(0, 240)}` }
      : { ok: true, note: 'still painted, console clean' };
  }
  return { ok: false, note: `unknown end-state kind '${expect.kind}'` };
}

module.exports = { chromium, FeatureSession, runStep, checkExpect, registerStep, STEPS, slug };
