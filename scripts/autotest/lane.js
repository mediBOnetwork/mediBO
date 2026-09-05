'use strict';
// CHANGE #637 — a browser session at a CHOSEN width.
//
// #634's FeatureSession is fixed at one desktop viewport, which is right for a
// functional run and useless for a lane whose whole question is "what does this
// screen look like at 390 px". This is the same session — the same real role
// token in localStorage, the same console/network capture, the same render-log
// reader — with the width as an argument, and it deliberately implements the
// interface `harness.runStep` expects so both lanes drive a feature's declared
// contract steps through the ONE step vocabulary rather than a second copy.
const fs = require('fs');
const path = require('path');
const api = require('./api');

let chromium = null;
try { ({ chromium } = require('playwright')); } catch (_) {
  try { ({ chromium } = require(path.join(process.env.HOME || '/home/ubuntu', 'node_modules', 'playwright'))); }
  catch (_) { chromium = null; }
}

const slug = (s) => String(s).replace(/[^a-zA-Z0-9._-]+/g, '_');

class LaneSession {
  constructor(opts) {
    this.browser = opts.browser;
    this.baseUrl = String(opts.baseUrl || '').replace(/\/+$/, '');
    this.artifactDir = opts.artifactDir;
    this.feature = opts.feature;
    this.role = opts.role;
    this.runId = opts.runId;
    this.viewport = opts.viewport || { key: 'desktop', width: 1280, height: 900 };
    this.consoleErrors = [];
    this.networkFailures = [];
    this.shots = [];
    this.stepLog = [];
    this.token = null;
    this.userId = null;
    this.ctx = null;
    this.page = null;
    this.scratch = {};
    // The visual lane drives a feature's contract steps only to GET somewhere,
    // and harness.runStep photographs every step it runs. Four extra PNGs per
    // screen per role per width is hundreds of megabytes a night for pictures
    // nobody opens — and a full disk on this box breaks more than this lane.
    // While `quiet` is set, a step's screenshot is simply not taken.
    this.quiet = false;
  }

  async open(session) {
    this.ctx = await this.browser.newContext({
      viewport: { width: this.viewport.width, height: this.viewport.height },
      deviceScaleFactor: 1,
      ignoreHTTPSErrors: true
    });
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
    if (!this.page || this.quiet) return null;
    const file = path.join(this.artifactDir,
      `${slug(this.feature)}__${slug(this.role || 'anon')}__${slug(this.viewport.key)}__` +
      `${String(this.shots.length + 1).padStart(2, '0')}_${slug(name)}.png`);
    try {
      await this.page.screenshot({ path: file, fullPage: false });
      this.shots.push(path.basename(file));
      return file;
    } catch (_) { return null; }
  }

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

  // Polls across navigations for the same reason #634's does: index.html
  // reloads once per session and destroys the execution context mid-boot.
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

  /// Did the app actually paint? Both lanes need this and neither may assume
  /// it: a spinner photographed at 99.97% one flat colour is exactly the
  /// "blank tile" the visual lane exists to catch, and judging a spinner
  /// against a feature's spec would be judging nothing.
  async painted(timeoutMs) {
    const r = await this.waitForRenderKey('boot_status', 'painted', timeoutMs || 45000);
    return r.ok;
  }

  async close() {
    try { await this.ctx.close(); } catch (_) {}
  }
}

module.exports = { chromium, LaneSession, slug };
