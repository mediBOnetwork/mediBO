'use strict';
// CHANGE #637 — the exploratory agent's one call to a model.
//
// GEMINI RULE (CLAUDE.md, absolute): every AI feature in mediBO is
// gemini-3.5-flash on Vertex AI's global endpoint with GCP_SA_KEY auth, and the
// `gemini-ocr` edge function is the ONE place that model, endpoint and
// credential are named. It already takes {images[], prompt} and returns {text},
// so this lane calls THAT rather than minting a second Vertex client on a VM
// that has no service-account key at all.
//
// The prompt is not written here either: test_explore_brief() renders it from
// the explore_prompt table. This file transports bytes and parses JSON.
const fs = require('fs');
const https = require('https');
const api = require('./api');

const TIMEOUT_MS = parseInt(process.env.AUTOTEST_JUDGE_TIMEOUT_MS || '90000', 10);

function post(url, body, headers) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const data = Buffer.from(JSON.stringify(body));
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
      headers: Object.assign(
        { 'Content-Type': 'application/json', 'Content-Length': data.length }, headers)
    }, (res) => {
      let buf = '';
      res.on('data', (d) => { buf += d; });
      res.on('end', () => {
        let parsed = buf;
        try { parsed = buf ? JSON.parse(buf) : null; } catch (_) { /* text */ }
        if (res.statusCode >= 400) {
          const e = new Error(`judge -> ${res.statusCode}: ` +
            (typeof parsed === 'string' ? parsed.slice(0, 300) : JSON.stringify(parsed).slice(0, 300)));
          e.status = res.statusCode;
          return reject(e);
        }
        resolve(parsed);
      });
    });
    req.on('error', reject);
    // A model call that never answers must not hang the lane: the #634 lesson
    // (a node request with no setTimeout waits forever) applies here too.
    req.setTimeout(TIMEOUT_MS, () => req.destroy(new Error(`judge timed out after ${TIMEOUT_MS}ms`)));
    req.write(data);
    req.end();
  });
}

/// The model sometimes wraps JSON in a fence however firmly it is asked not to.
/// Recovering the object is transport; inventing one would not be.
function parseVerdict(text) {
  const raw = String(text || '').trim();
  const fenced = raw.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/i, '');
  const start = fenced.indexOf('{');
  const end = fenced.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try { return JSON.parse(fenced.slice(start, end + 1)); } catch (_) { return null; }
}

/// prompt + up to `images` screenshots -> the agent's judgement, or a reason.
async function judge(prompt, imageFiles) {
  const images = [];
  for (const f of imageFiles || []) {
    try { images.push({ base64: fs.readFileSync(f).toString('base64'), mime_type: 'image/png' }); }
    catch (_) { /* a shot that never got taken is simply not sent */ }
  }
  if (images.length === 0) {
    return { ok: false, error: 'no screenshots to judge' };
  }
  let out;
  try {
    out = await post(`${api.SUPA_URL}/functions/v1/gemini-ocr`,
      { images, prompt }, api.serviceHeaders());
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e).slice(0, 300) };
  }
  if (out && out.error) return { ok: false, error: String(out.error).slice(0, 300) };
  const parsed = parseVerdict(out && out.text);
  if (!parsed) {
    return { ok: false, error: 'the model did not answer with JSON',
             raw: String((out && out.text) || '').slice(0, 400) };
  }
  return {
    ok: true,
    verdict: typeof parsed.verdict === 'string' ? parsed.verdict : 'unclear',
    summary: typeof parsed.summary === 'string' ? parsed.summary.slice(0, 500) : '',
    findings: Array.isArray(parsed.findings) ? parsed.findings.slice(0, 10) : []
  };
}

module.exports = { judge, parseVerdict };
