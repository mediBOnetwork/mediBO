#!/usr/bin/env node
'use strict';
// CHANGE #637 — the EXPLORATORY lane: the tester that can be WRONG.
//
//   node scripts/autotest/explore.js [--target prod|<url>] [--feature k]
//        [--role r] [--limit n] [--command <id>] [--if-requested] [--dry]
//
// An assertion answers the question it was written to ask. This lane asks a
// different one: an agent is given the feature's own specification (its
// registry row and its declared contract, composed by explore_spec_text) and
// the screenshots of the screen a real signed-in role just drove, and judges
// whether the screen does what the spec says.
//
// Three rules hold it honest:
//   • Every WORD it is given comes from the backend (test_explore_brief →
//     explore_prompt). This file writes no prompt and no finding text.
//   • Its answers are OPINIONS. They never fail a build; they land as
//     feature_gaps rows typed opportunity/partial, open, for Om to accept or
//     reject — with the screenshot and the spec line they contradict attached.
//   • It only judges a screen the app SAID it painted. Judging a spinner
//     against a specification produces confident nonsense.
const fs = require('fs');
const path = require('path');
const api = require('./api');
const harness = require('./harness');
const lane = require('./lane');
const diff = require('./imagediff');
const store = require('./artifacts');
const judge = require('./judge');

const argv = process.argv.slice(2);
const flag = (n) => argv.includes('--' + n);
const val = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

function resolveTarget() {
  const t = val('target', 'prod');
  if (/^https?:\/\//.test(t)) return t.replace(/\/+$/, '');
  if (t === 'preview' && process.env.MEDIBO_PREVIEW_URL) return process.env.MEDIBO_PREVIEW_URL.replace(/\/+$/, '');
  return 'https://medibo.in';
}

/// What the agent is told the screen DID. The step notes carry the backend's
/// own payloads verbatim — which is where a "₹0.00" rendered as a real amount
/// is visible in words as well as in pixels.
function traceOf(stepLog, extra) {
  const lines = stepLog.map((s) =>
    `${s.n}. ${s.kind}: ${s.ok ? 'ok' : 'FAILED'} — ${String(s.note || '').slice(0, 400)}`);
  for (const e of extra || []) lines.push(e);
  return lines.join('\n').slice(0, 6000);
}

async function main() {
  if (!api.hasServiceKey()) {
    console.error('explore: no service key — put AUTOTEST_SERVICE_KEY in ~/.medibo/autotest.env');
    return 3;
  }
  if (!lane.chromium) { console.error('explore: playwright is not installed on this box'); return 3; }

  let request = null;
  if (flag('if-requested')) {
    const claimed = await api.rpc('test_run_request_claim',
      { p_worker: process.env.DEVCMD_AGENT || require('os').hostname() }, null);
    if (!claimed || !claimed.has) { console.log('[explore] no run requested'); return 0; }
    if (claimed.kind !== 'explore') {
      await api.rpc('test_run_request_close',
        { p_request: claimed.request_id, p_status: 'skipped', p_run_id: null,
          p_note: `explore lane declined kind '${claimed.kind}'` }, null);
      console.log(`[explore] request ${claimed.request_id} is '${claimed.kind}', not explore`);
      return 0;
    }
    request = claimed;
    const a = claimed.args || {};
    if (a.limit && !argv.includes('--limit')) argv.push('--limit', String(a.limit));
    if (a.feature && !argv.includes('--feature')) argv.push('--feature', String(a.feature));
  }

  const targetUrl = resolveTarget();
  const manifest = await api.rpc('test_explore_manifest', {
    p_feature: val('feature', null), p_role: val('role', null),
    p_limit: parseInt(val('limit', '0'), 10)
  }, null);
  if (!manifest || manifest.is_active === false) {
    console.log('[explore] the exploratory lane is switched off in explore_config');
    return 0;
  }
  const features = (manifest && manifest.features) || [];
  const vp = manifest.viewport || { key: 'phone', width: 390, height: 844 };
  const maxShots = parseInt(manifest.max_shots || 5, 10);
  const maxSteps = parseInt(manifest.max_steps || 6, 10);
  if (flag('dry')) {
    console.log(JSON.stringify({ targetUrl, features: features.length, vp, maxShots, maxSteps }, null, 2));
    return 0;
  }

  const identities = await api.rpc('test_identities', {}, null);
  const idByRole = {};
  for (const r of identities || []) idByRole[r.role] = r;

  const started = await api.rpc('test_run_start', {
    p_kind: 'explore', p_target_url: targetUrl,
    p_commit: val('commit', null),
    p_deploy_no: val('deploy', null) ? parseInt(val('deploy'), 10) : null,
    p_command_id: val('command', null) ? parseInt(val('command'), 10) : null,
    p_triggered_by: val('triggered-by', 'vm'),
    p_note: 'exploratory judgement — findings are opinions, never auto-approved',
    // A test session, unlike the visual lane: this one runs the contract's own
    // steps, and a contract step may WRITE (cust.orders clears a cart). #573's
    // ambient stamping is what keeps a synthetic row from becoming a real one,
    // and test_run_finish purges it.
    p_open_session: true
  }, null);
  if (!started || !started.ok) { console.error('explore: could not open a run'); return 1; }
  const runId = started.run_id;

  const artifactDir = path.join(
    process.env.AUTOTEST_ARTIFACTS ||
      path.join(process.env.HOME || '/home/ubuntu', 'mediBO-runner', 'autotest-runs'),
    `explore-${runId}`);
  fs.mkdirSync(artifactDir, { recursive: true });
  console.log(`[explore] run ${runId} · ${targetUrl} · ${features.length} feature/role pair(s) · ${manifest.model_note}`);

  const browser = await lane.chromium.launch({ headless: true });
  const sessionCache = {};
  let gaps = 0, looked = 0;

  for (const f of features) {
    const ident = idByRole[f.role];
    const password = api.passwordFor(f.role);
    const t0 = Date.now();
    if (!ident || !ident.ready || !ident.identity || !password) {
      await api.rpc('test_explore_report', {
        p_run_id: runId, p_feature: f.feature_key, p_role: f.role,
        p_verdict: 'blocked', p_summary: `no usable test identity for '${f.role}'`,
        p_findings: [], p_steps: [], p_artifacts: {}, p_duration_ms: 0 }, null);
      continue;
    }
    if (!sessionCache[f.role]) {
      try { sessionCache[f.role] = await api.signIn(ident.identity, password); }
      catch (e) {
        await api.rpc('test_explore_report', {
          p_run_id: runId, p_feature: f.feature_key, p_role: f.role,
          p_verdict: 'blocked', p_summary: String(e.message).slice(0, 300),
          p_findings: [], p_steps: [], p_artifacts: {}, p_duration_ms: 0 }, null);
        continue;
      }
    }

    const fsn = new lane.LaneSession({
      browser, baseUrl: targetUrl, artifactDir,
      feature: f.feature_key, role: f.role, runId, viewport: vp
    });
    let verdict = 'unclear', summary = '', findings = [];
    const uploaded = {};
    try {
      await fsn.open(sessionCache[f.role]);
      const steps = (Array.isArray(f.steps) ? f.steps : []).slice(0, maxSteps);
      for (let i = 0; i < steps.length; i++) {
        const step = Object.assign({}, steps[i]);
        if (step.role === '{role}') step.role = f.role;
        await harness.runStep(fsn, step, i);
      }
      const painted = await fsn.painted(20000);
      if (!painted) {
        await fsn.shot('never_painted');
        verdict = 'blocked';
        summary = 'the app never reported a painted frame on this screen, so there was nothing to judge';
      } else {
        // Explore: read the screen the way a person does — top, then further
        // down, bounded by the backend's own shot budget.
        await fsn.page.waitForTimeout(1500);
        await fsn.shot('top');
        for (let k = 1; k < maxShots && k < 4; k++) {
          try {
            await fsn.page.mouse.wheel(0, Math.round(vp.height * 0.8));
            await fsn.page.waitForTimeout(900);
          } catch (_) { break; }
          await fsn.shot(`scroll_${k}`);
        }

        // Small copies for the model: a 1440-wide PNG per step is a payload
        // nobody needs, and the judgement is about layout, not about grain.
        const files = fsn.shots.map((n) => path.join(artifactDir, n));
        const small = [];
        for (const file of files.slice(0, maxShots)) {
          try {
            const out = file.replace(/\.png$/, '.small.png');
            small.push(diff.available() ? diff.downscale(file, 720, out) : file);
          } catch (_) { small.push(file); }
        }

        const brief = await api.rpc('test_explore_brief', {
          p_feature: f.feature_key, p_role: f.role,
          p_trace: traceOf(fsn.stepLog, [
            `Screenshots, in order: ${fsn.shots.join(', ')}`,
            `Console errors seen: ${fsn.consoleErrors.length}`,
            `Failed network calls: ${fsn.networkFailures.length}`
          ])
        }, null);
        if (!brief || !brief.ok) {
          verdict = 'error';
          summary = 'the backend did not render a brief for this feature';
        } else {
          const out = await judge.judge(brief.prompt, small);
          if (!out.ok) {
            verdict = 'error';
            summary = out.error || 'the judge did not answer';
          } else {
            verdict = out.verdict;
            summary = out.summary;
            findings = out.findings;
            looked++;
          }
        }

        // The picture every finding points at goes to the private bucket, and
        // only the ones a finding names: an unreferenced screenshot is storage
        // nobody will ever open.
        const named = new Set(findings.map((x) => String((x && x.shot) || '').trim()).filter(Boolean));
        if (findings.length && named.size === 0 && fsn.shots.length) named.add(fsn.shots[0]);
        for (const name of named) {
          const local = path.join(artifactDir, name);
          if (!fs.existsSync(local)) continue;
          const objPath = store.objectPath(runId, f.feature_key, f.role, name);
          try { await store.upload(local, objPath, 'image/png'); uploaded[name] = objPath; }
          catch (_) { /* a finding without its picture is still a finding */ }
        }
      }
    } catch (e) {
      verdict = 'error';
      summary = String((e && e.message) || e).slice(0, 400);
    } finally {
      await fsn.close();
    }

    // The shot name each finding carries is rewritten to the object path it was
    // actually stored at, so the row's artifact_path is openable.
    const reported = findings.map((x) => Object.assign({}, x, {
      shot: uploaded[String((x && x.shot) || '').trim()] || null
    }));
    const out = await api.rpc('test_explore_report', {
      p_run_id: runId, p_feature: f.feature_key, p_role: f.role,
      p_verdict: verdict, p_summary: summary,
      p_findings: reported,
      p_steps: fsn.stepLog,
      p_artifacts: { bucket: store.BUCKET, prefix: '', shots: fsn.shots },
      p_duration_ms: Date.now() - t0
    }, null);
    gaps += (out && out.gaps) || 0;
    console.log(`[explore] ${String(verdict).toUpperCase().padEnd(16)} ${f.feature_key} (${f.role})` +
      ` — ${(out && out.gaps) || 0} finding(s)` + (summary ? ` · ${summary.slice(0, 120)}` : ''));
  }

  await browser.close();

  const finished = await api.rpc('test_run_finish', {
    p_run_id: runId, p_status: null, p_artifacts_path: artifactDir,
    p_console_errors: 0, p_network_failures: 0, p_purge: true
  }, null);
  fs.writeFileSync(path.join(artifactDir, 'run.json'),
    JSON.stringify({ run_id: runId, targetUrl, looked, gaps, finished }, null, 2));
  if (request) {
    await api.rpc('test_run_request_close', {
      p_request: request.request_id, p_status: 'done', p_run_id: runId,
      p_note: `${gaps} finding(s) from ${looked} screen(s)`
    }, null);
  }
  console.log(`[explore] ${gaps} finding(s) filed from ${looked} judged screen(s) — ` +
    'they are OPEN opinions: Admin ▸ More ▸ Feature gaps, source "Exploratory bot"');
  return 0;
}

main().then((c) => process.exit(c)).catch((e) => {
  console.error('[explore] fatal:', (e && e.message) || e);
  process.exit(2);
});
