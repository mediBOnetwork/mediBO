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
const { classifyUnmeasured, previousUnmeasured, readOnlyRed } = require('./lib/responsive_verdict');

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
//      CMD #2186: ONE sentence per screen — the run that filed #2186 printed
//      the same sentence once per unread width.
it('a screen unreadable at every width tried fails immediately, once', () => {
  const out = classifyUnmeasured(
    [combo('cart', 320), combo('cart', 360), combo('cart', 412)],
    { cart: 3 }, { cart: 3 }, [], { plannedWidths: 3, skipped: 0 });
  assert.strictEqual(out.length, 1);
  assert.match(out[0], /cart did not load at any of the 3 widths tried/);
});

// ── CMD #2186 ── a run that stopped early is a biased sample, not evidence.
it('a truncated run fails nothing, however its unread combinations look', () => {
  const out = classifyUnmeasured(
    [combo('cart', 320), combo('cart', 360)],
    { cart: 2 }, { cart: 2 }, ['cart @320px', 'cart @360px'],
    { plannedWidths: 5, skipped: 29 });
  assert.deepStrictEqual(out, []);
});

it('a screen unread at 2 of 5 planned widths is not "down"', () => {
  const out = classifyUnmeasured(
    [combo('cart', 320), combo('cart', 360)],
    { cart: 2 }, { cart: 2 }, [], { plannedWidths: 5, skipped: 0 });
  assert.deepStrictEqual(out, []);
});

it('a complete run still fails a combination unread twice running', () => {
  const out = classifyUnmeasured(
    [combo('storefront home', 412)],
    { 'storefront home': 5 }, { 'storefront home': 1 },
    ['storefront home @412px'], { plannedWidths: 5, skipped: 0 });
  assert.strictEqual(out.length, 1);
  assert.match(out[0], /two consecutive sweeps/);
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

// ── CMD #2018 ── which reds the self-heal is allowed to re-measure.
const clean = (screen, width) => ({ screen, width, painted: true, overflow: 0, small: 0 });

it('a green verdict is never re-measured', () => {
  assert.strictEqual(readOnlyRed({ ok: true, payload: { unmeasured: [combo('cart', 360)] } }), false);
  assert.strictEqual(readOnlyRed(null), false);
});

it('a red whose reads were all clean is re-measured', () => {
  assert.strictEqual(readOnlyRed({
    ok: false,
    payload: { checked: [clean('storefront home', 360), clean('cart', 412)],
               unmeasured: [combo('storefront home', 412)], skipped: [] },
  }), true);
});

it('a budget that ran out before two screens is re-measured', () => {
  assert.strictEqual(readOnlyRed({
    ok: false,
    payload: { checked: [clean('cart', 360)], unmeasured: [], skipped: ['money @768px', 'fulfill @768px'] },
  }), true);
});

it('an overflow the app reported is left red', () => {
  assert.strictEqual(readOnlyRed({
    ok: false,
    payload: { checked: [clean('cart', 360), { screen: 'money', width: 412, painted: true, overflow: 3, small: 0 }],
               unmeasured: [combo('storefront home', 412)] },
  }), false);
});

it('a small tap target the app reported is left red', () => {
  assert.strictEqual(readOnlyRed({
    ok: false,
    payload: { checked: [{ screen: 'cart', width: 360, painted: true, overflow: 0, small: 2 }],
               unmeasured: [combo('cart', 412)] },
  }), false);
});

it('a screen that never painted is left red', () => {
  assert.strictEqual(readOnlyRed({
    ok: false,
    payload: { checked: [{ screen: 'checkout', width: 360, painted: false, overflow: 0, small: 0 }],
               skipped: ['money @768px'] },
  }), false);
});

it('a red with nothing unread in it is left red', () => {
  assert.strictEqual(readOnlyRed({
    ok: false, payload: { checked: [clean('cart', 360)], unmeasured: [], skipped: [] },
  }), false);
});

console.log(`responsive verdict rule: ${n} checks green`);
