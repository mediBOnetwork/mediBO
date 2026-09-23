#!/usr/bin/env node
'use strict';
// CMD #2018 — the phone sweep's self-heal.
//
// rg_check's responsive_no_overflow behaviour asserts one row:
// rg_runner_verdict('responsive_no_overflow'). Only scripts/responsive_sweep.js
// writes it, and only post_deploy_checks.sh runs that — so a verdict stands
// until the next DEPLOY, however wrong it has become. CHANGE #1375 shipped the
// rule that would have made the red at 18:20 UTC green, and the guard still
// stayed red for three more scheduled runs because nothing re-measured. That is
// the whole content of commands #2009, #2012 and #2018.
//
// This closes the window for the one red that can legitimately be re-measured:
// a red where every screen the sweep READ was clean and the only thing wrong
// was a read it could not take (scripts/lib/responsive_verdict.js readOnlyRed).
// An overflow, a small tap target or a screen that never painted is a number
// the app reported about itself — it is left alone and stays red until the
// layout is fixed. Re-running the sweep cannot make one of those go away.
//
//   node scripts/responsive_sweep_heal.js [--target https://medibo.in] [--dry-run]
//
// Exit 0 — nothing to do, or the sweep was re-run and the verdict is green.
// Exit 1 — the sweep was re-run and the verdict is still red.
// Exit 2 — could not read the verdict (no credentials, RPC down).

const { spawnSync } = require('child_process');
const path = require('path');
const { readOnlyRed } = require('./lib/responsive_verdict');

const argVal = (flag, dflt) => {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
};
const TARGET  = argVal('--target', process.env.MEDIBO_TARGET || 'https://medibo.in');
const DRY_RUN = process.argv.includes('--dry-run');
// A post-deploy sweep takes up to 12 minutes and writes the verdict at the END.
// Never start a second browser on top of one that is still running.
const MIN_AGE_MIN = Number(process.env.MEDIBO_HEAL_MIN_AGE_MIN || 20);

// Same resolution as the sweep: the timer runs with a bare environment.
function fromRunnerEnv(name) {
  try {
    const fs = require('fs');
    const file = path.join(process.env.MEDIBO_RUNNER_DIR || `${process.env.HOME}/mediBO-runner`, 'runner.env');
    const line = fs.readFileSync(file, 'utf8').split('\n')
      .find((l) => l.trim().startsWith(`${name}=`));
    if (!line) return undefined;
    return line.slice(line.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '');
  } catch (_) { return undefined; }
}
const SUPABASE_URL = process.env.PROD_SUPABASE_URL || process.env.SUPABASE_URL
  || fromRunnerEnv('PROD_SUPABASE_URL') || fromRunnerEnv('SUPABASE_URL');
const SERVICE_KEY  = process.env.PROD_SERVICE_ROLE_KEY || process.env.SERVICE_ROLE_KEY
  || fromRunnerEnv('PROD_SERVICE_ROLE_KEY') || fromRunnerEnv('SERVICE_ROLE_KEY');

async function rpc(fn, body) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body || {}),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`${fn}: ${r.status} ${text.slice(0, 200)}`);
  try { return JSON.parse(text); } catch (_) { return text; }
}

(async () => {
  if (!SUPABASE_URL || !SERVICE_KEY) {
    console.error('responsive_sweep_heal: PROD_SUPABASE_URL / PROD_SERVICE_ROLE_KEY are not set');
    process.exit(2);
  }
  const verdict = await rpc('rg_runner_verdict_read', { p_name: 'responsive_no_overflow' });
  if (!verdict) { console.log('heal: no verdict yet — the next deploy writes the first one'); return; }
  if (verdict.ok !== false) { console.log('heal: verdict is green — nothing to do'); return; }

  if (!readOnlyRed(verdict)) {
    console.log(`heal: red is a number the app reported — leaving it: ${verdict.detail || '(no detail)'}`);
    return;
  }
  const ageMin = (Date.now() - Date.parse(verdict.at || 0)) / 60000;
  if (!(ageMin >= MIN_AGE_MIN)) {
    console.log(`heal: verdict is ${Math.round(ageMin)}m old — a sweep may still be running, waiting`);
    return;
  }
  console.log(`heal: re-measuring — the red is an unread screen, not a layout: ${verdict.detail || ''}`);
  if (DRY_RUN) { console.log('heal: --dry-run, not sweeping'); return; }

  const r = spawnSync(process.execPath, [path.join(__dirname, 'responsive_sweep.js'), '--quiet', '--target', TARGET],
    { stdio: 'inherit', cwd: path.join(__dirname, '..'), timeout: 900000 });
  process.exit(r.status === 0 ? 0 : 1);
})().catch((e) => { console.error('responsive_sweep_heal:', e.message); process.exit(2); });
