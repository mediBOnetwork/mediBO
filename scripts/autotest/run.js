#!/usr/bin/env node
'use strict';
// CHANGE #634 — the CLI. `node scripts/autotest/run.js [--flags]`
//
//   --target preview|prod|<url>   default preview (falls back to prod when no
//                                 preview URL is configured — it says which)
//   --feature <key>               one feature only
//   --role <role>                 one role only
//   --command <id>                the dev-queue command this run belongs to
//   --commit <sha> --deploy <n>   what is being tested
//   --triggered-by <who>          vm | dispatcher | admin
//   --limit <n>                   cap features (a smoke run)
//   --if-requested                claim a run the #305 dispatcher asked for;
//                                 exits 0 doing nothing when none is waiting
//   --no-purge                    keep the test session (debugging only)
//   --dry                         print the manifest and exit, open nothing
//
// It decides nothing: test_manifest() says what to test, test_identities()
// says who can drive it, and the contract's own steps say how.
const fs = require('fs');
const path = require('path');
const api = require('./api');
const harness = require('./harness');

const argv = process.argv.slice(2);
const flag = (n) => argv.includes('--' + n);
const val = (n, d) => { const i = argv.indexOf('--' + n); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

const TARGETS = {
  prod: 'https://medibo.in',
  preview: process.env.MEDIBO_PREVIEW_URL || ''
};

function resolveTarget() {
  const t = val('target', 'preview');
  if (/^https?:\/\//.test(t)) return { url: t.replace(/\/+$/, ''), kind: 'preview' };
  if (t === 'prod') return { url: TARGETS.prod, kind: 'prod_smoke' };
  if (TARGETS.preview) return { url: TARGETS.preview.replace(/\/+$/, ''), kind: 'preview' };
  // Being explicit beats silently smoke-testing production while the log says
  // "preview" — the #634 spec asks for preview BY DEFAULT and prod ON DEMAND,
  // so a missing preview lane is stated, not hidden.
  return { url: TARGETS.prod, kind: 'prod_smoke',
           note: 'no MEDIBO_PREVIEW_URL configured — ran the production smoke instead' };
}

async function main() {
  // The dispatcher lane. cron_task 'autotest_nightly' inserts a request; this
  // claims it with SKIP LOCKED so two workers never run the same one. No
  // request waiting is a normal, quiet exit — not a failure.
  let request = null;
  if (flag('if-requested')) {
    if (!api.hasServiceKey()) { console.error('autotest: no service key'); process.exit(3); }
    const claimed = await api.rpc('test_run_request_claim',
      { p_worker: process.env.DEVCMD_AGENT || require('os').hostname() }, null);
    if (!claimed || !claimed.has) { console.log('[autotest] no run requested'); return 0; }
    request = claimed;
    if (claimed.kind && !argv.includes('--target')) { argv.push('--target', claimed.kind === 'prod_smoke' ? 'prod' : 'preview'); }
    const a = claimed.args || {};
    if (a.limit && !argv.includes('--limit')) argv.push('--limit', String(a.limit));
    if (a.feature && !argv.includes('--feature')) argv.push('--feature', String(a.feature));
    console.log(`[autotest] claimed request ${claimed.request_id} (${claimed.kind})`);
  }

  const target = resolveTarget();
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const artifactRoot = process.env.AUTOTEST_ARTIFACTS ||
    path.join(process.env.HOME || '/home/ubuntu', 'mediBO-runner', 'autotest-runs');

  if (!api.hasServiceKey()) {
    console.error('autotest: no service key — put AUTOTEST_SERVICE_KEY in ~/.medibo/autotest.env');
    process.exit(3);
  }

  const manifest = await api.rpc('test_manifest', {
    p_role: val('role', null),
    p_feature: val('feature', null),
    p_include_manual: false
  }, null);
  let features = (manifest && manifest.features) || [];
  const limit = parseInt(val('limit', '0'), 10);
  if (limit > 0) features = features.slice(0, limit);

  const identities = await api.rpc('test_identities', {}, null);
  const idByRole = {};
  for (const r of identities || []) idByRole[r.role] = r;

  if (flag('dry')) {
    console.log(JSON.stringify({ target, features: features.length, identities }, null, 2));
    return 0;
  }

  if (!harness.chromium) {
    console.error('autotest: playwright is not installed on this box');
    process.exit(3);
  }

  const started = await api.rpc('test_run_start', {
    p_kind: target.kind,
    p_target_url: target.url,
    p_commit: val('commit', null),
    p_deploy_no: val('deploy', null) ? parseInt(val('deploy'), 10) : null,
    p_command_id: val('command', null) ? parseInt(val('command'), 10) : null,
    p_triggered_by: val('triggered-by', 'vm'),
    p_note: target.note || null,
    p_open_session: true
  }, null);
  if (!started || !started.ok) {
    console.error('autotest: could not open a run:', JSON.stringify(started));
    process.exit(1);
  }
  const runId = started.run_id;
  const artifactDir = path.join(artifactRoot, `run-${runId}-${stamp}`);
  fs.mkdirSync(artifactDir, { recursive: true });
  console.log(`[autotest] run ${runId} · ${target.kind} · ${target.url} · session ${started.test_session_id}`);
  console.log(`[autotest] artifacts -> ${artifactDir}`);

  const browser = await harness.chromium.launch({ headless: true });
  require('./journeys/customer_order').register(harness);

  const results = [];
  let consoleErrors = 0;
  let networkFailures = 0;
  const sessionCache = {};

  for (const f of features) {
    for (const role of (f.roles && f.roles.length ? f.roles : [''])) {
      if (val('role', null) && role !== val('role')) continue;
      const ident = idByRole[role];

      // A role nobody can sign in as is BLOCKED, with the backend's own words —
      // never a pass, never a silent skip, and never a failure of the feature.
      if (!ident || !ident.ready || !ident.identity) {
        results.push({ feature_key: f.feature_key, role, scenario: 'happy_path',
          verdict: 'blocked', duration_ms: 0,
          error: (ident && ident.note) || `no test identity for role '${role}'` });
        continue;
      }
      const password = api.passwordFor(role);
      if (!password) {
        results.push({ feature_key: f.feature_key, role, scenario: 'happy_path',
          verdict: 'blocked', duration_ms: 0,
          error: `no password for role '${role}' — add AUTOTEST_PASS_${role.toUpperCase()} to ~/.medibo/autotest.env` });
        continue;
      }

      const t0 = Date.now();
      const fsn = new harness.FeatureSession({
        browser, baseUrl: target.url, artifactDir,
        feature: f.feature_key, role, runId
      });
      let verdict = 'passed';
      let error = null;
      try {
        if (!sessionCache[role]) sessionCache[role] = await api.signIn(ident.identity, password);
        await fsn.open(sessionCache[role]);
        const steps = Array.isArray(f.steps) ? f.steps : [];
        for (let i = 0; i < steps.length; i++) {
          const step = Object.assign({}, steps[i]);
          if (step.role === '{role}') step.role = role;
          const out = await harness.runStep(fsn, step, i);
          if (!out.ok) { verdict = 'failed'; error = `step ${i + 1} (${step.kind}): ${out.note}`; break; }
        }
        if (verdict === 'passed') {
          const end = await harness.checkExpect(fsn, f.expect);
          fsn.stepLog.push({ n: fsn.stepLog.length + 1, kind: 'expect', ok: end.ok, note: end.note });
          if (!end.ok) { verdict = 'failed'; error = `end state: ${end.note}`; }
        }
      } catch (e) {
        verdict = 'failed';
        error = String((e && e.message) || e).slice(0, 500);
      }
      const video = await fsn.close();
      consoleErrors += fsn.consoleErrors.length;
      networkFailures += fsn.networkFailures.length;
      results.push({
        feature_key: f.feature_key, role, scenario: 'happy_path', verdict,
        duration_ms: Date.now() - t0,
        steps: fsn.stepLog,
        artifacts: { video, shots: fsn.shots,
                     console: fsn.consoleErrors.slice(0, 20),
                     network: fsn.networkFailures.slice(0, 20) },
        error
      });
      console.log(`[autotest] ${verdict.toUpperCase().padEnd(7)} ${f.feature_key} (${role})` +
                  (error ? ` — ${error.slice(0, 160)}` : ''));
    }
  }

  await browser.close();

  // Report in pages: one enormous body is how a long run loses its record.
  for (let i = 0; i < results.length; i += 25) {
    await api.rpc('test_result_report',
      { p_run_id: runId, p_results: results.slice(i, i + 25) }, null);
  }
  const finished = await api.rpc('test_run_finish', {
    p_run_id: runId,
    p_status: null,
    p_artifacts_path: artifactDir,
    p_console_errors: consoleErrors,
    p_network_failures: networkFailures,
    p_purge: !flag('no-purge')
  }, null);

  fs.writeFileSync(path.join(artifactDir, 'run.json'),
    JSON.stringify({ run_id: runId, target, results, finished }, null, 2));
  if (request) {
    await api.rpc('test_run_request_close', {
      p_request: request.request_id,
      p_status: (finished && finished.status === 'passed') ? 'done' : 'failed',
      p_run_id: runId,
      p_note: JSON.stringify((finished && finished.totals) || {}).slice(0, 300)
    }, null);
  }
  console.log('[autotest] ' + JSON.stringify(finished && finished.totals));
  console.log('[autotest] purge: ' + JSON.stringify((finished && finished.purge && finished.purge.message) || finished && finished.purge));
  return (finished && finished.status === 'passed') ? 0 : 1;
}

main().then((c) => process.exit(c)).catch((e) => {
  console.error('[autotest] fatal:', (e && e.message) || e);
  process.exit(2);
});
