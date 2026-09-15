'use strict';
// CHANGE #637 — the private artifact store.
//
// A finding without its picture is an assertion nobody can check. Every
// screenshot a lane wants to keep is uploaded to the PRIVATE `test-artifacts`
// bucket and the finding carries only bucket + path; the app signs a URL for it
// under the reader's own session, exactly the way it already reads a payment
// proof. Nothing here is ever made public.
const fs = require('fs');
const https = require('https');
const api = require('./api');

const BUCKET = process.env.AUTOTEST_BUCKET || 'test-artifacts';
const TIMEOUT_MS = parseInt(process.env.AUTOTEST_HTTP_TIMEOUT_MS || '25000', 10);

// api.request JSON-encodes its body, and a PNG is bytes. This is the same
// bounded, retried-once shape with the encoding left alone.
function putOnce(url, buf, headers) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'POST',
      headers: Object.assign({ 'Content-Length': buf.length }, headers)
    }, (res) => {
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => {
        if (res.statusCode >= 400) {
          const e = new Error(`upload -> ${res.statusCode}: ${body.slice(0, 200)}`);
          e.status = res.statusCode;
          return reject(e);
        }
        resolve(body);
      });
    });
    req.on('error', reject);
    req.setTimeout(TIMEOUT_MS, () => req.destroy(new Error(`upload timed out after ${TIMEOUT_MS}ms`)));
    req.write(buf);
    req.end();
  });
}

/// Upload one file. Returns {bucket, path} — never a URL: a URL that outlives
/// this process would be either public or expired, and both are wrong.
async function upload(localFile, objectPath, contentType) {
  const buf = fs.readFileSync(localFile);
  const url = `${api.SUPA_URL}/storage/v1/object/${BUCKET}/${objectPath}`;
  // The bucket is private and its write policy is admin/super_admin only, so
  // this is the service role or it is nothing — see api.serviceHeaders.
  const headers = api.serviceHeaders({
    'Content-Type': contentType || 'image/png',
    'x-upsert': 'true'
  });
  try {
    await putOnce(url, buf, headers);
  } catch (e) {
    if (e && e.status) throw e;
    await new Promise((r) => setTimeout(r, 2000));
    await putOnce(url, buf, headers);
  }
  return { bucket: BUCKET, path: objectPath };
}

/// Download an approved baseline so this run can diff against it.
function download(objectPath, outFile) {
  const headers = api.serviceHeaders();
  return new Promise((resolve, reject) => {
    const u = new URL(`${api.SUPA_URL}/storage/v1/object/${BUCKET}/${objectPath}`);
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'GET',
      headers
    }, (res) => {
      if (res.statusCode >= 400) { res.resume(); return resolve(null); }
      const chunks = [];
      res.on('data', (d) => chunks.push(d));
      res.on('end', () => {
        try { fs.writeFileSync(outFile, Buffer.concat(chunks)); resolve(outFile); }
        catch (e) { reject(e); }
      });
    });
    req.on('error', () => resolve(null));
    req.setTimeout(TIMEOUT_MS, () => { req.destroy(); resolve(null); });
    req.end();
  });
}

/// Delete exactly the objects the BACKEND named (visual_prune). This never
/// chooses what to delete — a bot that decided which evidence to destroy is a
/// different and much worse tool.
function remove(paths) {
  const list = (paths || []).filter(Boolean);
  if (list.length === 0) return Promise.resolve(0);
  return new Promise((resolve) => {
    const u = new URL(`${api.SUPA_URL}/storage/v1/object/${BUCKET}`);
    const data = Buffer.from(JSON.stringify({ prefixes: list }));
    const req = https.request({
      hostname: u.hostname, path: u.pathname + u.search, method: 'DELETE',
      headers: api.serviceHeaders({
        'Content-Type': 'application/json',
        'Content-Length': data.length
      })
    }, (res) => { res.resume(); res.on('end', () => resolve(list.length)); });
    req.on('error', () => resolve(0));
    req.setTimeout(TIMEOUT_MS, () => { req.destroy(); resolve(0); });
    req.write(data);
    req.end();
  });
}

/// run-<id>/<feature>/<role>/<viewport>.png — readable at a glance in the
/// bucket browser, and unique per run so an approved baseline is never
/// overwritten by the next pass.
function objectPath(runId, feature, role, name) {
  const slug = (s) => String(s || '').replace(/[^a-zA-Z0-9._-]+/g, '_');
  return `run-${runId}/${slug(feature)}/${slug(role || 'anon')}/${slug(name)}`;
}

module.exports = { BUCKET, upload, download, remove, objectPath };
