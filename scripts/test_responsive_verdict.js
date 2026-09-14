#!/usr/bin/env node
'use strict';
// CMD #2012 — the rule the phone sweep uses to decide what a failure is.
//
//   node scripts/test_responsive_verdict.js
//
// No browser, no network, no database: it asserts the decision, which is the
// part that was wrong. The guard went red after CHANGE #1374 on
// responsive_no_overflow with 0 diffs and 0 missing critical, over one
// combination the harness could not read while the other 37 reported
// overflow=0 and tap_targets_small=0.

const assert = require('assert');
const { classifyUnmeasured, previousUnmeasured } = require('./lib/responsive_verdict');

const combo = (screen, width, why) => ({ combo: `${screen} @${width}px`, screen, width, why: why || 'wrote no render log' });
let n = 0;
const it = (what, fn) => { fn(); n += 1; console.log(`  ok  ${what}`); };

// 1 ── the #2012 shape: one screen unreadable at one width, fine at the others.
it('a single transient unreadable combination is reported, not failed', () => {
  const out = classifyUnmeasured(
    [combo('storefront home', 412)],
    { 'storefront home': 5 }, { 'storefront home': 1 }, []);
  assert.deepStrictEqual(out, []);
});

// 2 ── the same combination twice running is not noise any more.
it('the same combination unreadable on the previous sweep fails', () => {
  const out = classifyUnmeasured(
    [combo('storefront home', 412)],
    { 'storefront home': 5 }, { 'storefront home': 1 },
    ['storefront home @412px']);
  assert.strictEqual(out.length, 1);
  assert.match(out[0], /storefront home @412px did not load on two consecutive sweeps/);
});

// 3 ── a screen that answers at no width at all is down, on the first sweep.
it('a screen unreadable at every width tried fails immediately', () => {
  const out = classifyUnmeasured(
    [combo('cart', 320), combo('cart', 360), combo('cart', 412)],
    { cart: 3 }, { cart: 3 }, []);
  assert.strictEqual(out.length, 3);
  assert.match(out[0], /cart did not load at any of the 3 widths tried/);
});

// 4 ── one width tried is never enough to call a screen down.
it('a screen tried at one width only is never "down at every width"', () => {
  const out = classifyUnmeasured([combo('money', 768)], { money: 1 }, { money: 1 }, []);
  assert.deepStrictEqual(out, []);
});

// 5 ── a combination that was unreadable before but reads now says nothing.
it('yesterday\'s unreadable combination does not fail a sweep that read it', () => {
  const out = classifyUnmeasured([], {}, {}, ['storefront home @412px']);
  assert.deepStrictEqual(out, []);
});

// 6 ── the previous verdict, in both shapes it can arrive in.
it('previousUnmeasured reads objects, strings, and nothing at all', () => {
  assert.deepStrictEqual(previousUnmeasured(null), []);
  assert.deepStrictEqual(previousUnmeasured({ payload: {} }), []);
  assert.deepStrictEqual(
    previousUnmeasured({ payload: { unmeasured: [combo('cart', 360), 'money @768px', null] } }),
    ['cart @360px', 'money @768px']);
});

console.log(`responsive verdict rule: ${n} checks green`);
