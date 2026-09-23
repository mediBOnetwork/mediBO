'use strict';
// CMD #2012 — what a phone sweep is allowed to call a failure.
//
// The responsive sweep reads two very different things and used to treat them
// as one. A NUMBER the app reported about itself (overflow_errors,
// tap_targets_small, boot_status) is evidence: it fails on sight. A READ the
// harness failed to take is not evidence of anything — the run that filed
// #2012 measured 37 of 40 combinations clean and called the whole guard red
// over the 38th, which passed on a re-run against the same live build minutes
// later.
//
// So an unmeasured combination is reported, and becomes a failure only when it
// stops looking like noise:
//   · it was unmeasured on the PREVIOUS sweep too — it is not transient; or
//   · the screen answered at NONE of the widths it was tried at — it is down.
//
// Kept in its own file so scripts/test_responsive_verdict.js can hold the rule
// down without opening a browser.

// unmeasured: [{combo, screen, width, why}]
// tried/dead:  {screen: count} — combinations started / that answered nothing
// prev:        combo strings from the previous verdict's payload.unmeasured
// run:         {plannedWidths, skipped} — the shape of the run that produced
//              this sample. CMD #2186: a sweep that ran out of budget measured
//              a BIASED sample and cannot be evidence about what it never
//              reached. The run that filed #2186 started 11 of 40 combinations,
//              reached cart at two widths, could not read either, and called
//              the screen down — while cart painted clean at 360px and 412px
//              on the same live build minutes later. A truncated run reports
//              its unread combinations and fails nothing.
function classifyUnmeasured(unmeasured, tried, dead, prev, run) {
  const was = new Set((prev || []).filter(Boolean));
  const t = tried || {};
  const d = dead || {};
  const r = run || {};
  const skipped = Number(r.skipped || 0);
  if (skipped > 0) return [];               // truncated run — a biased sample
  // A screen is only "down" when it was tried at EVERY width the run planned
  // and answered at none of them; anything less is a corner of the plan.
  const planned = Number(r.plannedWidths || 0);
  const failures = [];
  const downSaid = new Set();               // one sentence per screen, not per combo
  for (const u of unmeasured || []) {
    const triedN = t[u.screen] || 0;
    const allWidths = triedN > 1 && d[u.screen] === triedN
      && (!planned || triedN === planned);
    if (allWidths) {
      if (downSaid.has(u.screen)) continue;
      downSaid.add(u.screen);
      failures.push(`${u.screen} did not load at any of the ${triedN} widths tried (${u.why})`);
    } else if (was.has(u.combo)) {
      failures.push(`${u.combo} did not load on two consecutive sweeps (${u.why})`);
    }
  }
  return failures;
}

// The previous verdict, as the sweep gets it back from rg_runner_verdict_read:
// the whole row, or null the first time it ever runs.
function previousUnmeasured(verdictRow) {
  const list = ((verdictRow && verdictRow.payload) || {}).unmeasured;
  if (!Array.isArray(list)) return [];
  return list.map((u) => (typeof u === 'string' ? u : (u && u.combo))).filter(Boolean);
}

// CMD #2018 — is a RED verdict one the harness failed to read, or one the app
// reported a number for?
//
// The guard went red after CHANGE #1375 for four and a half hours on a verdict
// written before #2012's rule reached live. Nothing re-runs the phone sweep
// except a deploy, so a verdict that has already been superseded in fact
// stands until the next one — three commands in a row (#2009, #2012, #2018)
// were filed on the same stale red. The heal (scripts/responsive_sweep_heal.js,
// on a timer) re-runs the sweep for exactly ONE kind of red and no other: one
// where every screen the sweep DID read was clean, and the only thing wrong was
// a read it could not take. An overflow, an undersized tap target or a screen
// that never painted is a number the app reported about itself — that red is a
// layout bug and it must stand until somebody fixes the layout.
//
// Structural, not a string match: the failure sentences are copy and change.
function readOnlyRed(verdictRow) {
  const v = verdictRow || {};
  if (v.ok !== false) return false;                     // green, or never written
  const p = v.payload || {};
  const unmeasured = Array.isArray(p.unmeasured) ? p.unmeasured : [];
  const skipped    = Array.isArray(p.skipped)    ? p.skipped    : [];
  // A red with nothing unread in it can only have come from a number.
  if (!unmeasured.length && !skipped.length) return false;
  for (const c of (Array.isArray(p.checked) ? p.checked : [])) {
    if (c && c.painted === false) return false;
    if (Number((c || {}).overflow || 0) > 0) return false;
    if (Number((c || {}).small || 0) > 0) return false;
  }
  return true;
}

module.exports = { classifyUnmeasured, previousUnmeasured, readOnlyRed };
