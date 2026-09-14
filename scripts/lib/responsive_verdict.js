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
function classifyUnmeasured(unmeasured, tried, dead, prev) {
  const was = new Set((prev || []).filter(Boolean));
  const t = tried || {};
  const d = dead || {};
  const failures = [];
  for (const u of unmeasured || []) {
    if (was.has(u.combo)) {
      failures.push(`${u.combo} did not load on two consecutive sweeps (${u.why})`);
    } else if ((t[u.screen] || 0) > 1 && d[u.screen] === t[u.screen]) {
      failures.push(`${u.screen} did not load at any of the ${t[u.screen]} widths tried (${u.why})`);
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

module.exports = { classifyUnmeasured, previousUnmeasured };
