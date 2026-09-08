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
//   --smoke                       CHANGE #635: the critical path only, the run
//                                 the merge worker gates promote on
//   --scenarios happy,deny,hostile,pipeline   default all four
//   --no-hostile / --no-deny      drop one lane (a fast triage run)
//   --budget-s <n>                stop starting new work after n seconds
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

// CHANGE #1823 — the exit code is the merge worker's whole reading of this
// run, so each number means ONE thing:
//   0  ran, every journey that could run passed
//   1  ran, at least one journey FAILED (a red critical path)
//   2  could not run — no service key, no playwright, no test account for the
//      role(s), no run opened. Forgiven by the gate: an environment gap is not
//      a product failure.
//   3  CRASHED mid-run — an exception after the run opened (a reporting RPC
//      that raised, a browser that died). This used to share 2 with "could
//      not run" and the gate forgave it; batches 600-602 each found two real
//      reds, crashed on a duplicate-key in test_result_report, and shipped.
// AUTOTEST_SUMMARY_FILE, when set, receives one JSON object with the verdict,
// the exit code, the totals and the names of what went red or was blocked —
// the merge worker records THAT on the deploy batch, not a grep of this log.
const SUMMARY_FILE = process.env.AUTOTEST_SUMMARY_FILE || '';
let lastSummary = null;
function summary(obj) {
  lastSummary = Object.assign({ at: new Date().toISOString() }, lastSummary || {}, obj);
  if (!SUMMARY_FILE) return;
  try { fs.writeFileSync(SUMMARY_FILE, JSON.stringify(lastSummary, null, 2)); } catch (_) {}
}

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
    if (!api.hasServiceKey()) { console.error('autotest: no service key'); summary({ status: 'not_run', exit: 2, note: 'no service key' }); process.exit(2); }
    // CHANGE #636 — --kinds narrows the claim. A timer that must only ever run
    // ONE job cannot use the unfiltered claim: the head of the queue may be
    // #634's 'full' request, the entire hostile suite against production.
    const kinds = (val('kinds', '') || '').split(',').map(k => k.trim()).filter(Boolean);
    const claimed = kinds.length
      ? await api.rpc('test_run_request_claim_kind',
          { p_worker: process.env.DEVCMD_AGENT || require('os').hostname(), p_kinds: kinds }, null)
      : await api.rpc('test_run_request_claim',
          { p_worker: process.env.DEVCMD_AGENT || require('os').hostname() }, null);
    if (!claimed || !claimed.has) { console.log('[autotest] no run requested'); return 0; }
    request = claimed;
    // 'full' is the nightly suite the #305 dispatcher asks for: production,
    // every feature, every role, every hostile variant, and the pipeline.
    // 'prod_smoke' is the deploy gate. Anything else is a preview run.
    if (claimed.kind && !argv.includes('--target')) {
      argv.push('--target', (claimed.kind === 'prod_smoke' || claimed.kind === 'full') ? 'prod' : 'preview');
    }
    if (claimed.kind === 'smoke' && !argv.includes('--smoke')) argv.push('--smoke');
    const a = claimed.args || {};
    if (a.limit && !argv.includes('--limit')) argv.push('--limit', String(a.limit));
    if (a.feature && !argv.includes('--feature')) argv.push('--feature', String(a.feature));
    if (a.hostile === false) argv.push('--no-hostile');
    if (a.budget_s && !argv.includes('--budget-s')) argv.push('--budget-s', String(a.budget_s));
    console.log(`[autotest] claimed request ${claimed.request_id} (${claimed.kind})`);
    // CHANGE #636 — the safety net is not a browser suite. It is one SQL call
    // that takes minutes, which is exactly why #1808 had to disable its cron:
    // run from cron_dispatch() it cancelled at the 15 s dblink budget and took
    // every other scheduled task down with it. So the cron only ENQUEUES and
    // this lane runs it, off the dispatcher's tick, where nothing is waiting on
    // a budget. Handled here and returned: none of the harness below applies.
    if (claimed.kind === 'safety_net') {
      const a = claimed.args || {};
      const t0 = Date.now();
      // A throw here used to leave the request 'claimed' for ever — the run
      // that found the safeupdate bug did exactly that. Close it either way:
      // a request nobody ever closes is a lie about what the lane did.
      let out = null;
      try {
        out = await api.rpc('autotest_safety_net_run', {
          p_label: a.label || 'nightly safety net',
          p_seed: a.seed == null ? null : Number(a.seed),
          p_fuzz_rpcs: a.fuzz_rpcs == null ? 150 : Number(a.fuzz_rpcs),
          p_variants: a.variants == null ? 2 : Number(a.variants)
        }, null);
      } catch (e) {
        out = { ok: false, error: (e && e.message) || String(e) };
      }
      const ok = !!(out && out.ok);
      console.log(`[autotest] safety net ${ok ? 'ran' : 'FAILED'} in ${Math.round((Date.now() - t0) / 1000)}s · `
        + JSON.stringify(out && (out.gaps !== undefined ? { run_id: out.run_id, gaps: out.gaps } : out)).slice(0, 300));
      await api.rpc('test_run_request_close', {
        p_request: claimed.request_id,
        p_status: ok ? 'done' : 'failed',
        p_run_id: null,
        p_note: JSON.stringify(out || {}).slice(0, 300)
      }, null);
      return ok ? 0 : 1;
    }
  }

  const target = resolveTarget();
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const artifactRoot = process.env.AUTOTEST_ARTIFACTS ||
    path.join(process.env.HOME || '/home/ubuntu', 'mediBO-runner', 'autotest-runs');

  if (!api.hasServiceKey()) {
    console.error('autotest: no service key — put AUTOTEST_SERVICE_KEY in ~/.medibo/autotest.env');
    summary({ status: 'not_run', exit: 2, note: 'no service key on this box' });
    process.exit(2);
  }

  const manifest = await api.rpc('test_manifest', {
    p_role: val('role', null),
    p_feature: val('feature', null),
    p_include_manual: false
  }, null);
  let features = (manifest && manifest.features) || [];

  // The smoke's feature list is the BACKEND's (feature_registry.test_critical),
  // never a list in this file: changing what the 3-minute gate covers must be
  // one UPDATE, not a deploy of the bot.
  if (flag('smoke')) {
    const sm = await api.rpc('test_smoke_manifest', {}, null);
    const keys = new Set(((sm && sm.features) || []).map(String));
    features = features.filter((f) => keys.has(f.feature_key));
    console.log(`[autotest] smoke: ${features.length} critical-path feature(s)`);
  }
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
    summary({ status: 'not_run', exit: 2, note: 'playwright is not installed on this box' });
    process.exit(2);
  }

  const started = await api.rpc('test_run_start', {
    p_kind: flag('smoke') ? 'smoke' : target.kind,
    p_target_url: target.url,
    p_commit: val('commit', null),
    p_deploy_no: val('deploy', null) ? parseInt(val('deploy'), 10) : null,
    p_command_id: val('command', null) ? parseInt(val('command'), 10) : null,
    p_triggered_by: val('triggered-by', 'vm'),
    p_note: target.note || null,
    p_open_session: true
  }, null);
  if (!started || !started.ok) {
    // CHANGE #1821 — A REFUSED SESSION IS A SKIP, NEVER A FAILURE AND NEVER A
    // PASS. test_run_start() now refuses to open a run it cannot scope to
    // itself: a person has test mode on (human_session_live), or somebody
    // else's session is already open (session_busy). Before this the bot took
    // the platform's GLOBAL session for its own three-minute run — which is
    // the loop Om reported. Exit 3 is the merge worker's "could not run" code,
    // so the promote is recorded as not_run instead of as a green smoke.
    const why = (started && started.error) || 'unknown';
    if (why === 'human_session_live' || why === 'session_busy') {
      console.log(`[autotest] SKIPPED — ${(started && started.message) || why}`);
      process.exit(3);
    }
    console.error('autotest: could not open a run:', JSON.stringify(started));
    // The card prints this sentence verbatim (deploy_lane_status().smoke), so
    // it carries the backend's own message when there is one, not a JSON dump.
    summary({ status: 'not_run', exit: 2, note: 'could not open a run: ' + (((started && started.message) || JSON.stringify(started)) + '').slice(0, 200) });
    process.exit(2);
  }
  const runId = started.run_id;
  summary({ status: 'running', run_id: runId, target: target.url });
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

  // WHICH SCENARIOS. The four lanes the #635 spec asks for; each one can be
  // dropped for a triage run, and the smoke drops all but the first.
  const wanted = new Set(
    (val('scenarios', flag('smoke') ? 'happy,pipeline' : 'happy,deny,hostile,pipeline'))
      .split(',').map((x) => x.trim()).filter(Boolean));
  if (flag('no-hostile')) wanted.delete('hostile');
  if (flag('no-deny')) wanted.delete('deny');

  // A budget, because a suite that runs past its window is a suite nobody
  // waits for. The smoke's is three minutes — the spec's number.
  const budgetS = parseInt(val('budget-s', flag('smoke') ? '180' : '0'), 10);
  const deadline = budgetS > 0 ? Date.now() + budgetS * 1000 : Infinity;
  let overBudget = false;
  const outOfTime = () => {
    if (Date.now() < deadline) return false;
    overBudget = true;
    return true;
  };

  // Sign a role in once and keep it. A role with no identity, or no password
  // on this box, is BLOCKED with the backend's own note — never a pass, never
  // a silent skip, and never counted as a failure of the feature.
  const blockedRole = {};
  async function sessionFor(role) {
    if (sessionCache[role]) return sessionCache[role];
    if (blockedRole[role]) throw new Error(blockedRole[role]);
    const ident = idByRole[role];
    if (!ident || !ident.ready || !ident.identity) {
      blockedRole[role] = (ident && ident.note) || `no test identity for role '${role}'`;
      throw new Error(blockedRole[role]);
    }
    const password = api.passwordFor(role);
    if (!password) {
      blockedRole[role] = `no password for role '${role}' — add AUTOTEST_PASS_${role.toUpperCase()} to ~/.medibo/autotest.env`;
      throw new Error(blockedRole[role]);
    }
    try {
      sessionCache[role] = await api.signIn(ident.identity, password);
    } catch (e) {
      blockedRole[role] = `sign-in failed for role '${role}': ${String((e && e.message) || e).slice(0, 200)}`;
      throw new Error(blockedRole[role]);
    }
    return sessionCache[role];
  }

  // ONE journey = one feature, one role, one scenario. Everything below is a
  // different `steps` list handed to the same runner, so a hostile variant and
  // a happy path are recorded, screenshotted and gap-filed identically.
  async function drive(f, role, scenario, steps, expect) {
    const t0 = Date.now();
    const fsn = new harness.FeatureSession({
      browser, baseUrl: target.url, artifactDir,
      feature: f.feature_key, role, runId
    });
    fsn.scratch.contractSteps = Array.isArray(f.steps) ? f.steps : [];
    let verdict = 'passed';
    let error = null;
    try {
      const session = await sessionFor(role);
      await fsn.open(session);
      for (let i = 0; i < steps.length; i++) {
        const step = Object.assign({}, steps[i]);
        if (step.role === '{role}') step.role = role;
        const out = await harness.runStep(fsn, step, fsn.stepLog.length);
        if (!out.ok) {
          verdict = out.blocked ? 'blocked' : 'failed';
          error = `step ${i + 1} (${step.kind}): ${out.note}`;
          break;
        }
      }
      if (verdict === 'passed') {
        const end = await harness.checkExpect(fsn, expect);
        fsn.stepLog.push({ n: fsn.stepLog.length + 1, kind: 'expect', ok: end.ok, note: end.note });
        if (!end.ok) { verdict = 'failed'; error = `end state: ${end.note}`; }
      }
    } catch (e) {
      const msg = String((e && e.message) || e).slice(0, 500);
      // A role nobody can sign in as blocks the journey; it does not fail it.
      verdict = blockedRole[role] === msg ? 'blocked' : 'failed';
      error = msg;
    }
    const video = await (fsn.ctx ? fsn.close() : Promise.resolve(null));
    consoleErrors += fsn.consoleErrors.length;
    networkFailures += fsn.networkFailures.length;
    results.push({
      feature_key: f.feature_key, role, scenario, verdict,
      duration_ms: Date.now() - t0,
      steps: fsn.stepLog,
      artifacts: { video, shots: fsn.shots,
                   console: fsn.consoleErrors.slice(0, 20),
                   network: fsn.networkFailures.slice(0, 20) },
      error
    });
    console.log(`[autotest] ${verdict.toUpperCase().padEnd(7)} ${f.feature_key} (${role}/${scenario})` +
                (error ? ` — ${error.slice(0, 160)}` : ''));
    return verdict;
  }

  // A DENY journey. It never opens a browser: the question is whether the
  // ROLE's own token gets through, and the token is the whole test. Passing
  // means the backend refused; failing means a role the registry says has no
  // business here reached it — the #570 class of bug, caught by assertion
  // rather than by somebody noticing.
  async function driveDeny(f, role) {
    const probe = f.deny_probe || {};
    const t0 = Date.now();
    const log = [];
    let verdict = 'passed';
    let error = null;
    try {
      const session = await sessionFor(role);
      if (probe.kind === 'rpc_refused') {
        try {
          const out = await api.rpc(probe.fn, probe.args || {}, session.access_token);
          const refused = out && typeof out === 'object' && out.ok === false;
          log.push({ n: 1, kind: 'deny_rpc', ok: refused, note: `${probe.fn} -> ` + JSON.stringify(out).slice(0, 240) });
          if (!refused) {
            verdict = 'failed';
            error = `${probe.fn} answered role '${role}', which the registry does not allow here`;
          }
        } catch (e) {
          const st = (e && e.status) || 0;
          const ok = st === 401 || st === 403 || (st >= 400 && st < 500);
          log.push({ n: 1, kind: 'deny_rpc', ok, note: `${probe.fn} -> HTTP ${st || '?'}` });
          if (!ok) { verdict = 'failed'; error = `${probe.fn} returned HTTP ${st} for role '${role}'`; }
        }
      } else {
        // A route probe. The app must not paint THIS screen for this role; it
        // may paint a refusal, so boot_status alone proves nothing and the
        // route the app actually opened is what is read.
        const fsn = new harness.FeatureSession({
          browser, baseUrl: target.url, artifactDir,
          feature: f.feature_key, role, runId
        });
        await fsn.open(session);
        await harness.runStep(fsn, { kind: 'goto', path: probe.path || '/' }, 0);
        await harness.runStep(fsn, { kind: 'settle', ms: 4000 }, 1);
        const rl = await fsn.renderLog();
        const opened = String(rl.c325_deep_link || '');
        const leaked = opened && f.route_key && opened.includes(f.route_key);
        log.push(...fsn.stepLog, { n: fsn.stepLog.length + 1, kind: 'deny_route',
          ok: !leaked, note: `opened '${opened || 'nothing'}' for route_key '${f.route_key || ''}'` });
        if (leaked) { verdict = 'failed'; error = `role '${role}' opened ${f.route_key}`; }
        await fsn.close();
        consoleErrors += fsn.consoleErrors.length;
      }
    } catch (e) {
      const msg = String((e && e.message) || e).slice(0, 500);
      verdict = blockedRole[role] === msg ? 'blocked' : 'failed';
      error = msg;
    }
    results.push({
      feature_key: f.feature_key, role, scenario: 'deny', verdict,
      duration_ms: Date.now() - t0, steps: log, artifacts: {}, error
    });
    console.log(`[autotest] ${verdict.toUpperCase().padEnd(7)} ${f.feature_key} (${role}/deny)` +
                (error ? ` — ${error.slice(0, 160)}` : ''));
  }

  // CHANGE #1823 — the backend's transient-refusal config (test_config.pipeline:
  // which refusals, how many attempts, the wait, the words) is read ONCE, before
  // any journey, and handed to the api layer so EVERY rpc of the run gets the
  // retry — not only test_pipeline_run. Batch 615 was sunk by a lock timeout
  // arriving through test_assert_pipeline; batch 620 by PGRST002 (PostgREST
  // reloading its schema cache after the migrate phase) through test_result_report.
  let pcfg = {};
  try { pcfg = (await api.rpc('test_config_get', { p_key: 'pipeline' }, null)) || {}; }
  catch (_) { pcfg = {}; }
  api.setTransientRetry(pcfg);

  const onlyRole = val('role', null);
  for (const f of features) {
    if (outOfTime()) break;

    // 1 · HAPPY PATH, once per role that SHOULD reach it.
    if (wanted.has('happy')) {
      for (const role of (f.roles && f.roles.length ? f.roles : [''])) {
        if (onlyRole && role !== onlyRole) continue;
        if (outOfTime()) break;
        await drive(f, role, 'happy_path', Array.isArray(f.steps) ? f.steps : [], f.expect);
      }
    }

    // 2 · DENY, once per role the registry says must NOT reach it.
    if (wanted.has('deny')) {
      for (const role of (f.deny_roles || [])) {
        if (onlyRole && role !== onlyRole) continue;
        if (outOfTime()) break;
        await driveDeny(f, role);
      }
    }

    // 3 · HOSTILE VARIANTS, as the FIRST allowed role — the variants are about
    // the flow, not about who is driving it, so running each one nine times
    // would buy nothing and cost the nightly window.
    if (wanted.has('hostile')) {
      const driver = onlyRole || (f.roles && f.roles[0]);
      if (driver) {
        for (const v of (f.hostile || [])) {
          if (outOfTime()) break;
          await drive(f, driver, `hostile:${v.key}`, v.steps || [], v.expect);
        }
      }
    }
  }

  // 4 · THE FLAGSHIP. All nine stages on a synthetic order, driven by the
  // BACKEND so the order of the stages is never a second copy in this file.
  // It runs even when the feature loop was cut short: a suite that skips the
  // order pipeline has not tested mediBO.
  if (wanted.has('pipeline')) {
    const t0 = Date.now();
    let out = null;
    // How a transport timeout is reported is the BACKEND's decision, in the
    // backend's words (test_config.pipeline). CHANGE #635: batch 575 held two
    // unrelated commands back from promote because one POST went unanswered for
    // 25 s twice while the box was mid-deploy. A database that could not answer
    // is the same class of fact as a role with no login — the environment could
    // not meet the precondition — and this was the one place run.js did not say
    // so. An unreadable config leaves the old behaviour exactly as it was.
    let timedOut = false;
    // The retry on a transient database refusal lives in api.rpc (CHANGE #1823,
    // batches 615 and 620): every rpc of the run gets it, this one included.
    try {
      out = await api.rpc('test_pipeline_run', { p_run_id: runId, p_order_id: null }, null);
    } catch (e) {
      const msg = String((e && e.message) || e);
      timedOut = !(e && e.status) && !!pcfg.timeout_match && msg.includes(pcfg.timeout_match);
      out = { ok: false, detail: (timedOut ? pcfg.timeout_note : msg).slice(0, 400) };
    }
    const stages = (out && out.stages) || [];
    // A stage the ENVIRONMENT could not meet (no buyable catalogue on this
    // database, test mode off) is BLOCKED, exactly like a role with no login:
    // not a pass, not a product failure, and never a silent skip.
    const verdict = out && out.ok ? 'passed'
                  : (timedOut && pcfg.timeout_verdict) ? pcfg.timeout_verdict
                  : (out && out.blocked ? 'blocked' : 'failed');
    results.push({
      feature_key: 'devtool.order_pipeline', role: 'admin', scenario: 'pipeline',
      verdict,
      duration_ms: Date.now() - t0,
      steps: stages.map((s, i) => ({ n: i + 1, kind: `stage:${s.stage_key}`, ok: s.ok, note: s.detail })),
      artifacts: {},
      error: verdict === 'passed' ? null : (out && out.detail) ||
             `pipeline stopped at ${(out && out.failed_stage) || '?'}`
    });
    console.log(`[autotest] ${verdict.toUpperCase().padEnd(7)} order pipeline — ` +
                `${(out && out.stages_passed) || 0}/${(out && out.stages_total) || 9} stages` +
                (verdict === 'passed' ? '' : ` — ${(out && out.detail) || ''}`));
  }

  if (overBudget) {
    console.log(`[autotest] budget of ${budgetS}s reached — stopped starting new journeys`);
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
  // #573's `clean` is residue AND an unchanged business fingerprint across 47
  // tables. On a PRODUCTION smoke that second half is about the whole platform,
  // not about the bot: real customers order while the run is in the browser, so
  // it moves whatever the bot did or did not do. Print the two facts apart —
  // "my session left nothing" is the one this bot can be held to — and keep the
  // backend's own sentence verbatim beside them rather than in place of them.
  const pg = (finished && finished.purge) || {};
  const res = pg.residue || {};
  console.log(`[autotest] purge: residue ${res.total || 0} row(s), ${res.files || 0} file(s)`
    + ` · business fingerprint ${pg.business_unchanged === false ? 'moved' : 'unchanged'}`
    + ` — ${JSON.stringify(pg.message || pg)}`);
  const tot = (finished && finished.totals) || {};
  const names = (v) => results.filter((r) => r.verdict === v)
    .map((r) => `${r.feature_key} (${r.role}/${r.scenario})`);
  const exitCode = (tot.failed || 0) > 0 ? 1
                 : (finished && finished.status === 'passed') ? 0
                 : 2;   // nothing passed and nothing failed: the roles were blocked, or nothing ran
  summary({
    status: exitCode === 0 ? 'passed' : exitCode === 1 ? 'failed'
          : ((tot.blocked || 0) > 0 ? 'blocked' : 'not_run'),
    exit: exitCode,
    run_id: runId,
    target: target.url,
    totals: tot,
    failed: names('failed'),
    blocked: names('blocked'),
    note: exitCode === 2
      ? ((tot.blocked || 0) > 0
          ? `${tot.blocked} journey(s) blocked, none could run — ` +
            Object.values(blockedRole).filter((v, i, a) => a.indexOf(v) === i).join('; ').slice(0, 300)
          : 'no journey ran')
      : null
  });
  return exitCode;
}

main().then((c) => process.exit(c)).catch((e) => {
  const msg = String((e && e.message) || e);
  console.error('[autotest] fatal:', msg);
  // A run that opened and then died is a CRASH (3), never "could not run" (2):
  // the gate must fail the batch on it. Before the run opened there was nothing
  // to crash out of, and that is the environment's 2.
  const opened = lastSummary && lastSummary.run_id != null;
  summary({ status: opened ? 'crashed' : 'not_run', exit: opened ? 3 : 2, note: 'fatal: ' + msg.slice(0, 400) });
  process.exit(opened ? 3 : 2);
});
