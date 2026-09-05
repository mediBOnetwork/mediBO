#!/usr/bin/env node
'use strict';
// CHANGE #637 — the VISUAL REGRESSION lane.
//
//   node scripts/autotest/visual.js [--target prod|<url>] [--feature k] [--role r]
//                                   [--limit n] [--command <id>] [--if-requested]
//
// Every registered screen, per role, at every active width: drive the feature's
// own declared contract steps, wait for the app to say it painted, photograph
// it, upload it to the private bucket, measure it against the APPROVED baseline
// and hand the four numbers to visual_shot_report(). It decides nothing — the
// thresholds, the verdicts, the words and the findings are the backend's.
//
// A screen with no approved baseline is NEW, never a failure: the first pass
// fills the review queue and Om approves it in one tap.
const fs = require('fs');
const path = require('path');
const api = require('./api');
const harness = require('./harness');
const lane = require('./lane');
const diff = require('./imagediff');
const store = require('./artifacts');

const argv = process.argv.slice(2);
const flag = (n) => argv.includes('--' + n);
const val = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

function resolveTarget() {
  const t = val('target', 'prod');
  if (/^https?:\/\//.test(t)) return { url: t.replace(/\/+$/, ''), kind: 'visual' };
  if (t === 'preview' && process.env.MEDIBO_PREVIEW_URL) {
    return { url: process.env.MEDIBO_PREVIEW_URL.replace(/\/+$/, ''), kind: 'visual' };
  }
  return { url: 'https://medibo.in', kind: 'visual' };
}

async function main() {
  if (!api.hasServiceKey()) {
    console.error('visual: no service key — put AUTOTEST_SERVICE_KEY in ~/.medibo/autotest.env');
    return 3;
  }
  if (!lane.chromium) { console.error('visual: playwright is not installed on this box'); return 3; }
  if (!diff.available()) { console.error('visual: pngjs is not installed on this box'); return 3; }

  let request = null;
  if (flag('if-requested')) {
    const claimed = await api.rpc('test_run_request_claim',
      { p_worker: process.env.DEVCMD_AGENT || require('os').hostname() }, null);
    if (!claimed || !claimed.has) { console.log('[visual] no run requested'); return 0; }
    if (claimed.kind !== 'visual') {
      // Somebody else's lane. Put it back by closing it untouched is wrong, so
      // this simply reports and exits: the claimer for that kind will ask again.
      await api.rpc('test_run_request_close',
        { p_request: claimed.request_id, p_status: 'skipped', p_run_id: null,
          p_note: `visual lane declined kind '${claimed.kind}'` }, null);
      console.log(`[visual] request ${claimed.request_id} is '${claimed.kind}', not visual`);
      return 0;
    }
    request = claimed;
    const a = claimed.args || {};
    if (a.limit && !argv.includes('--limit')) argv.push('--limit', String(a.limit));
    if (a.feature && !argv.includes('--feature')) argv.push('--feature', String(a.feature));
  }

  const target = resolveTarget();
  const manifest = await api.rpc('visual_manifest', {
    p_feature: val('feature', null), p_role: val('role', null),
    p_limit: parseInt(val('limit', '0'), 10)
  }, null);
  const screens = (manifest && manifest.screens) || [];
  const viewports = (manifest && manifest.viewports) || [];
  if (flag('dry')) { console.log(JSON.stringify({ target, screens: screens.length, viewports }, null, 2)); return 0; }

  const identities = await api.rpc('test_identities', {}, null);
  const idByRole = {};
  for (const r of identities || []) idByRole[r.role] = r;

  const started = await api.rpc('test_run_start', {
    p_kind: 'visual', p_target_url: target.url,
    p_commit: val('commit', null),
    p_deploy_no: val('deploy', null) ? parseInt(val('deploy'), 10) : null,
    p_command_id: val('command', null) ? parseInt(val('command'), 10) : null,
    p_triggered_by: val('triggered-by', 'vm'),
    p_note: 'visual regression',
    // No test session: this lane signs in and LOOKS. It places no order and
    // writes no business row, so opening (and purging) a #573 session would be
    // ceremony with a cost.
    p_open_session: false
  }, null);
  if (!started || !started.ok) { console.error('visual: could not open a run'); return 1; }
  const runId = started.run_id;

  const artifactDir = path.join(
    process.env.AUTOTEST_ARTIFACTS ||
      path.join(process.env.HOME || '/home/ubuntu', 'mediBO-runner', 'autotest-runs'),
    `visual-${runId}`);
  fs.mkdirSync(artifactDir, { recursive: true });
  console.log(`[visual] run ${runId} · ${target.url} · ${screens.length} screen(s) × ${viewports.length} width(s)`);

  const browser = await lane.chromium.launch({ headless: true });
  const sessionCache = {};
  const shots = [];
  let consoleErrors = 0, networkFailures = 0;

  for (const s of screens) {
    const ident = idByRole[s.role];
    const password = api.passwordFor(s.role);
    if (!ident || !ident.ready || !ident.identity || !password) {
      console.log(`[visual] SKIP    ${s.feature_key} (${s.role}) — no usable test identity`);
      continue;
    }
    if (!sessionCache[s.role]) {
      try { sessionCache[s.role] = await api.signIn(ident.identity, password); }
      catch (e) { console.log(`[visual] SKIP    ${s.feature_key} (${s.role}) — ${e.message}`); continue; }
    }

    for (const vp of viewports) {
      const fsn = new lane.LaneSession({
        browser, baseUrl: target.url, artifactDir,
        feature: s.feature_key, role: s.role, runId, viewport: vp
      });
      let rendered = false;
      try {
        await fsn.open(sessionCache[s.role]);
        // Getting there is not evidence; the ONE settled frame is.
        fsn.quiet = true;
        const steps = Array.isArray(s.steps) ? s.steps : [];
        for (let i = 0; i < steps.length; i++) {
          const step = Object.assign({}, steps[i]);
          if (step.role === '{role}') step.role = s.role;
          // A photograph is the point; a step that refuses is recorded and the
          // picture is still taken, because "it did not get there" is exactly
          // what the reviewer needs to see.
          if (step.kind === 'rpc') continue;
          await harness.runStep(fsn, step, i);
        }
        rendered = await fsn.painted(20000);
        await fsn.page.waitForTimeout(1500);   // let the last frame settle
        fsn.quiet = false;
        const file = await fsn.shot('screen');
        consoleErrors += fsn.consoleErrors.length;
        networkFailures += fsn.networkFailures.length;
        if (!file) { await fsn.close(); continue; }

        // The approved picture, fetched once per screen×role×viewport.
        let baseFile = null;
        const b = (s.baselines || {})[vp.key];
        if (b && b.path) {
          baseFile = path.join(artifactDir, `baseline_${lane.slug(s.feature_key)}_${lane.slug(s.role)}_${vp.key}.png`);
          baseFile = await store.download(b.path, baseFile);
        }
        const diffFile = path.join(artifactDir,
          `diff_${lane.slug(s.feature_key)}_${lane.slug(s.role)}_${vp.key}.png`);
        const m = diff.measure(file, baseFile, baseFile ? diffFile : null);

        const objPath = store.objectPath(runId, s.feature_key, s.role, `${vp.key}.png`);
        await store.upload(file, objPath, 'image/png');
        let diffPath = null;
        if (baseFile && fs.existsSync(diffFile) && m.diff_pct > 0) {
          diffPath = store.objectPath(runId, s.feature_key, s.role, `${vp.key}-diff.png`);
          await store.upload(diffFile, diffPath, 'image/png');
        }

        shots.push({
          feature_key: s.feature_key, role: s.role, viewport: vp.key,
          bucket: store.BUCKET, path: objPath, diff_path: diffPath,
          fingerprint: m.fingerprint, width: m.width, height: m.height,
          diff_pct: m.diff_pct, blank_pct: m.blank_pct,
          edge_ink_pct: m.edge_ink_pct, rendered
        });
        console.log(`[visual] SHOT    ${s.feature_key} (${s.role}/${vp.key})` +
          ` diff=${m.diff_pct}% blank=${m.blank_pct}% edge=${m.edge_ink_pct}%` +
          (rendered ? '' : ' NOT PAINTED'));
      } catch (e) {
        console.log(`[visual] ERROR   ${s.feature_key} (${s.role}/${vp.key}) — ${String(e.message).slice(0, 160)}`);
      } finally {
        await fsn.close();
      }
    }
  }

  await browser.close();

  let totals = {};
  for (let i = 0; i < shots.length; i += 20) {
    totals = await api.rpc('visual_shot_report',
      { p_run_id: runId, p_shots: shots.slice(i, i + 20) }, null);
  }
  const finished = await api.rpc('test_run_finish', {
    p_run_id: runId, p_status: null, p_artifacts_path: artifactDir,
    p_console_errors: consoleErrors, p_network_failures: networkFailures,
    p_purge: false
  }, null);

  fs.writeFileSync(path.join(artifactDir, 'run.json'),
    JSON.stringify({ run_id: runId, target, shots, totals, finished }, null, 2));
  if (request) {
    await api.rpc('test_run_request_close', {
      p_request: request.request_id, p_status: 'done', p_run_id: runId,
      p_note: JSON.stringify((finished && finished.totals) || {}).slice(0, 300)
    }, null);
  }
  // Old pictures go LAST, and only the ones the backend names: no approved
  // baseline is ever in that list.
  try {
    const prune = await api.rpc('visual_prune', { p_keep: 5 }, null);
    const gone = await store.remove((prune && prune.paths) || []);
    if (gone) console.log(`[visual] pruned ${gone} old artifact(s) from ${store.BUCKET}`);
  } catch (e) {
    console.log(`[visual] prune skipped — ${String(e.message).slice(0, 120)}`);
  }

  console.log(`[visual] ${shots.length} shot(s) · ` + JSON.stringify(totals));
  console.log('[visual] review them at Dev Queue ▸ Tools ▸ Visual baselines');
  return 0;
}

main().then((c) => process.exit(c)).catch((e) => {
  console.error('[visual] fatal:', (e && e.message) || e);
  process.exit(2);
});
