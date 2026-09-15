'use strict';
// CHANGE #637 — the pixels, and ONLY the pixels.
//
// This file measures. It never decides: "2% differs" is a fact, "that is a
// regression" is a threshold, and every threshold in this lane lives in the
// visual_rule table. A node script that carried its own idea of "broken" would
// be a second product nobody can edit without a deploy.
//
// pngjs is already on the box (the journey runner's tree). No pixelmatch, no
// sharp, no new dependency for four numbers and a nearest-neighbour resize.
const fs = require('fs');
const path = require('path');

let PNG = null;
for (const p of ['pngjs', path.join(process.env.HOME || '/home/ubuntu', 'node_modules', 'pngjs')]) {
  try { ({ PNG } = require(p)); break; } catch (_) { /* keep looking */ }
}

function read(file) {
  if (!PNG) throw new Error('pngjs is not installed on this box');
  return PNG.sync.read(fs.readFileSync(file));
}

function px(img, x, y) {
  const i = (img.width * y + x) << 2;
  return [img.data[i], img.data[i + 1], img.data[i + 2]];
}

// Nearest neighbour, on purpose: this is for comparing and for keeping an
// upload small, never for showing somebody a picture.
function sample(img, w, h) {
  const out = new Uint8Array(w * h * 3);
  for (let y = 0; y < h; y++) {
    const sy = Math.min(img.height - 1, Math.floor((y * img.height) / h));
    for (let x = 0; x < w; x++) {
      const sx = Math.min(img.width - 1, Math.floor((x * img.width) / w));
      const [r, g, b] = px(img, sx, sy);
      const o = (y * w + x) * 3;
      out[o] = r; out[o + 1] = g; out[o + 2] = b;
    }
  }
  return out;
}

/// A 64-bit average hash, hex. Two screenshots of the same screen taken a
/// second apart are not byte-identical (a clock, an animation frame), so a file
/// hash would call every run a change. This says "the same picture".
function fingerprint(img) {
  const s = sample(img, 8, 8);
  const grey = [];
  for (let i = 0; i < 64; i++) {
    grey.push(0.299 * s[i * 3] + 0.587 * s[i * 3 + 1] + 0.114 * s[i * 3 + 2]);
  }
  const avg = grey.reduce((a, b) => a + b, 0) / grey.length;
  let hex = '';
  for (let n = 0; n < 64; n += 4) {
    let nib = 0;
    for (let k = 0; k < 4; k++) if (grey[n + k] > avg) nib |= (1 << k);
    hex += nib.toString(16);
  }
  return hex;
}

/// How much of the picture is one flat colour, and how much ink sits on the
/// bottom edge. A blank tile and a row cut in half are both invisible to an
/// assertion and obvious in these two numbers.
function shape(img) {
  const w = Math.min(img.width, 240);
  const h = Math.min(img.height, 480);
  const s = sample(img, w, h);
  const bins = new Map();
  for (let i = 0; i < w * h; i++) {
    const k = ((s[i * 3] >> 4) << 8) | ((s[i * 3 + 1] >> 4) << 4) | (s[i * 3 + 2] >> 4);
    bins.set(k, (bins.get(k) || 0) + 1);
  }
  let topKey = 0, topN = 0;
  for (const [k, n] of bins) if (n > topN) { topN = n; topKey = k; }
  const blankPct = (100 * topN) / (w * h);

  // The last 3% of the height. Ink that is NOT the page colour sitting on the
  // very bottom row is content the layout ran out of room for.
  const band = Math.max(1, Math.round(h * 0.03));
  let ink = 0, seen = 0;
  for (let y = h - band; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      const k = ((s[i * 3] >> 4) << 8) | ((s[i * 3 + 1] >> 4) << 4) | (s[i * 3 + 2] >> 4);
      seen++;
      if (k !== topKey) ink++;
    }
  }
  return {
    blank_pct: Math.round(blankPct * 100) / 100,
    edge_ink_pct: seen ? Math.round((10000 * ink) / seen) / 100 : 0
  };
}

/// Percentage of the picture that differs from the baseline, plus a diff image
/// (changed pixels in red over a faded copy) so a human sees WHERE.
/// Different sizes are compared at the smaller common grid rather than called
/// a 100% change — a viewport that reported one pixel less is not a redesign.
function compare(currentFile, baselineFile, diffOut) {
  const a = read(currentFile);
  const b = read(baselineFile);
  const w = Math.min(a.width, b.width);
  const h = Math.min(a.height, b.height);
  const sa = sample(a, w, h);
  const sb = sample(b, w, h);
  const out = PNG ? new PNG({ width: w, height: h }) : null;
  let changed = 0;
  for (let i = 0; i < w * h; i++) {
    const d = Math.abs(sa[i * 3] - sb[i * 3]) +
              Math.abs(sa[i * 3 + 1] - sb[i * 3 + 1]) +
              Math.abs(sa[i * 3 + 2] - sb[i * 3 + 2]);
    const hit = d > 45;                       // ~15 per channel: anti-aliasing is not a change
    if (hit) changed++;
    if (out) {
      const o = i << 2;
      out.data[o]     = hit ? 220 : Math.round(255 - (255 - sa[i * 3]) * 0.25);
      out.data[o + 1] = hit ? 38  : Math.round(255 - (255 - sa[i * 3 + 1]) * 0.25);
      out.data[o + 2] = hit ? 38  : Math.round(255 - (255 - sa[i * 3 + 2]) * 0.25);
      out.data[o + 3] = 255;
    }
  }
  if (out && diffOut) {
    try { fs.writeFileSync(diffOut, PNG.sync.write(out)); } catch (_) { /* a missing diff is not a failure */ }
  }
  const total = w * h;
  return {
    diff_pct: total ? Math.round((10000 * changed) / total) / 100 : 0,
    size_mismatch: a.width !== b.width || a.height !== b.height
  };
}

/// The whole measurement of one screenshot, baseline optional.
function measure(file, baselineFile, diffOut) {
  const img = read(file);
  const m = Object.assign(
    { width: img.width, height: img.height, fingerprint: fingerprint(img) },
    shape(img));
  if (baselineFile && fs.existsSync(baselineFile)) {
    const c = compare(file, baselineFile, diffOut);
    m.diff_pct = c.diff_pct;
    m.size_mismatch = c.size_mismatch;
    m.has_baseline = true;
  } else {
    m.diff_pct = 0;
    m.has_baseline = false;
  }
  return m;
}

/// A copy no wider than [maxW], written beside the original. The judge reads
/// screenshots over HTTP; a 1440-wide PNG per step is a payload nobody needs.
function downscale(file, maxW, outFile) {
  const img = read(file);
  if (img.width <= maxW) return file;
  const w = maxW;
  const h = Math.max(1, Math.round((img.height * maxW) / img.width));
  const s = sample(img, w, h);
  const out = new PNG({ width: w, height: h });
  for (let i = 0; i < w * h; i++) {
    const o = i << 2;
    out.data[o] = s[i * 3]; out.data[o + 1] = s[i * 3 + 1];
    out.data[o + 2] = s[i * 3 + 2]; out.data[o + 3] = 255;
  }
  fs.writeFileSync(outFile, PNG.sync.write(out));
  return outFile;
}

module.exports = { available: () => Boolean(PNG), measure, compare, fingerprint, downscale };
