// vm-control — start / stop / read the builder VM.
//
// CHANGE #224: the VM moved from GCP Compute to AWS EC2, so this function is now
// CLOUD-AWARE rather than GCP-only. Which cloud it drives is a config row
// (`dev_runner_config.vm_identity.cloud`), never a code branch Om has to ask for
// — a future move is an UPDATE, not a deploy.
//
// AWS credentials are read from the Supabase Vault via `secret_get_runner`
// (this function holds the service key, which that RPC requires), so Om saves
// them in the app's own Secrets screen — no Supabase dashboard, no redeploy.
// Deno.env is the fallback, and it is the live path today: the keys are saved
// as Edge Function secrets (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
// AWS_REGION). The reply reports `cred_source` — which STORE answered, never
// the value.
//
// CHANGE #224 follow-up — "start does nothing". Two real defects, both fixed
// here rather than in Dart:
//   1. the no-op check ("it's already running, skip the call") ran in the app
//      against a CACHED vm_status row. Nothing refreshes that row while the box
//      is off, so a stale 'running' silently swallowed every START. The check
//      now runs here, against a DescribeInstances read taken microseconds ago.
//   2. an IAM refusal came back as the generic "couldn't reach the cloud". It
//      now names the exact missing action (`iam_action`, e.g.
//      ec2:StartInstances) inside backend copy.
// The reply also carries `settled` + `poll_after_ms`, so the chip chases
// pending/stopping to a real resting state instead of printing a guess.
//
// Every human-facing string comes from `ui_copy`. This function returns copy the
// client prints verbatim; it never words anything itself.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { "Content-Type": "application/json" } });

// ── small crypto/encoding helpers ───────────────────────────────────────────
const enc = new TextEncoder();
function b64url(s: string) { return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
function b64urlBytes(b: Uint8Array) { let s = ""; for (const x of b) s += String.fromCharCode(x); return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
function pemToDer(pem: string) { const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""); const raw = atob(body); const der = new Uint8Array(raw.length); for (let i = 0; i < raw.length; i++) der[i] = raw.charCodeAt(i); return der.buffer; }
function jwtRole(auth: string): string | null { try { const tok = auth.replace(/^Bearer\s+/i, ""); const p = tok.split(".")[1]; return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/"))).role ?? null; } catch (_) { return null; } }

function hex(b: ArrayBuffer) { return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join(""); }
async function sha256Hex(s: string) { return hex(await crypto.subtle.digest("SHA-256", enc.encode(s))); }
async function hmac(key: ArrayBuffer | Uint8Array, msg: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key as BufferSource, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(msg));
}

// ── AWS SigV4, POST form-encoded to the EC2 Query API ───────────────────────
// Deliberately hand-rolled: pulling an AWS SDK into an edge function for three
// EC2 calls costs cold-start seconds the toggle would pay on every tap.
async function ec2Call(
  region: string,
  akid: string,
  secret: string,
  token: string | null,
  params: Record<string, string>,
): Promise<{ ok: boolean; status: number; body: string }> {
  const host = `ec2.${region}.amazonaws.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, ""); // 20260817T075900Z
  const dateStamp = amzDate.slice(0, 8);
  const body = new URLSearchParams({ Version: "2016-11-15", ...params }).toString();

  const payloadHash = await sha256Hex(body);
  const signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date" + (token ? ";x-amz-security-token" : "");
  const canonicalHeaders =
    "content-type:application/x-www-form-urlencoded; charset=utf-8\n" +
    `host:${host}\n` +
    `x-amz-content-sha256:${payloadHash}\n` +
    `x-amz-date:${amzDate}\n` +
    (token ? `x-amz-security-token:${token}\n` : "");
  const canonicalRequest = ["POST", "/", "", canonicalHeaders, signedHeaders, payloadHash].join("\n");

  const scope = `${dateStamp}/${region}/ec2/aws4_request`;
  const stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256Hex(canonicalRequest)].join("\n");

  let k: ArrayBuffer | Uint8Array = enc.encode(`AWS4${secret}`);
  for (const part of [dateStamp, region, "ec2", "aws4_request"]) k = await hmac(k, part);
  const signature = hex(await hmac(k, stringToSign));

  const headers: Record<string, string> = {
    "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
    "X-Amz-Content-Sha256": payloadHash,
    "X-Amz-Date": amzDate,
    Authorization: `AWS4-HMAC-SHA256 Credential=${akid}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`,
  };
  if (token) headers["X-Amz-Security-Token"] = token;

  const r = await fetch(`https://${host}/`, { method: "POST", headers, body });
  return { ok: r.ok, status: r.status, body: await r.text() };
}

// EC2 returns XML. We need exactly one field out of it, so a targeted match
// beats dragging in a parser.
function xmlTag(xml: string, tag: string): string | null {
  const m = xml.match(new RegExp(`<${tag}>([^<]*)</${tag}>`));
  return m ? m[1] : null;
}
// The state name is ambiguous on its own — DescribeInstances carries several
// <name> tags. Scope to the wrapper element first, then read <name> inside it.
function xmlStateName(xml: string, wrapper: string): string | null {
  const m = xml.match(new RegExp(`<${wrapper}>([\\s\\S]*?)</${wrapper}>`));
  return m ? xmlTag(m[1], "name") : null;
}
function ec2Error(xml: string): string | null {
  const code = xmlTag(xml, "Code");
  const msg = xmlTag(xml, "Message");
  return code || msg ? `${code ?? ""}${code && msg ? ": " : ""}${msg ?? ""}` : null;
}
// An IAM refusal must never surface as a generic "couldn't reach the cloud" —
// Om has to know WHICH action to add to the policy. AWS says "UnauthorizedOperation"
// (and, on some paths, AccessDenied) without naming the action, so we name it
// from the call we just made.
function iamDenied(xml: string): boolean {
  const code = (xmlTag(xml, "Code") ?? "").toLowerCase();
  return code.includes("unauthorizedoperation") || code.includes("accessdenied");
}

// EC2 instance state → the four states the app's chip knows.
const AWSMAP: Record<string, string> = {
  running: "running",
  stopped: "stopped",
  stopping: "stopping",
  "shutting-down": "stopping",
  terminated: "stopped",
  pending: "starting",
};
const GMAP: Record<string, string> = {
  RUNNING: "running", TERMINATED: "stopped", STOPPING: "stopping",
  PROVISIONING: "starting", STAGING: "starting", SUSPENDED: "stopped", REPAIRING: "starting",
};

// ── GCP (kept for either-cloud correctness / rollback) ──────────────────────
async function mintGcpToken(sa: any) {
  const now = Math.floor(Date.now() / 1000);
  const input = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${b64url(JSON.stringify({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/cloud-platform", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }))}`;
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(sa.private_key), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(input));
  const jwt = `${input}.${b64urlBytes(new Uint8Array(sig))}`;
  const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}` });
  const b = await r.json();
  if (!b.access_token) throw new Error("token mint failed: " + JSON.stringify(b));
  return b.access_token as string;
}

Deno.serve(async (req) => {
  try {
    const body = await req.json().catch(() => ({}));
    const action = (body.action ?? "status").toString();
    if (!["start", "stop", "status", "preflight"].includes(action)) return json({ error: "bad_action" }, 400);
    const auth = req.headers.get("Authorization") ?? "";

    let ok = jwtRole(auth) === "service_role" || auth.includes(SVC);
    if (!ok) {
      const caller = createClient(URL, ANON, { global: { headers: { Authorization: auth } } });
      const { data } = await caller.rpc("am_i_super");
      ok = data === true;
    }
    if (!ok) return json({ error: "not_authorized" }, 403);

    const admin = createClient(URL, SVC);

    // Every string this function hands back is a ui_copy row.
    const { data: copyRows } = await admin.from("ui_copy").select("key,value")
      .in("key", ["dev_queue.ctl_vm_no_key", "dev_queue.ctl_vm_stop_queued",
                  "dev_queue.ctl_vm_start_sent", "dev_queue.ctl_edge_failed",
                  "dev_queue.ctl_vm_stop_no_key", "dev_queue.ctl_vm_on_toast",
                  "dev_queue.ctl_vm_off_toast", "dev_queue.ctl_vm_iam_denied",
                  "dev_queue.ctl_vm_aws_error", "dev_queue.ctl_vm_preflight_ok",
                  "dev_queue.ctl_vm_preflight_bad"]);
    const copy = (k: string) =>
      String((copyRows ?? []).find((r: any) => r.key === k)?.value ?? "").replace(/^"|"$/g, "");
    const copyf = (k: string, vars: Record<string, string>) =>
      Object.entries(vars).reduce((s, [n, v]) => s.split(`{${n}}`).join(v), copy(k));

    const { data: idRow } = await admin.from("dev_runner_config").select("value").eq("key", "vm_identity").single();
    const id = idRow?.value ?? {};
    const cloud = (id.cloud ?? "gcp").toString();

    // Polling cadence is config, not a Dart constant: the client chases a
    // transitional state on the interval THIS row names.
    const { data: pollRow } = await admin.from("dev_runner_config").select("value").eq("key", "vm_poll").single();
    const poll = pollRow?.value ?? {};
    const pollAfterMs = Number(poll.interval_ms ?? 6000);
    const pollMax = Number(poll.max_polls ?? 20);
    // running/stopped are the only resting states; everything else is in flight.
    const settledOf = (s: string) => s === "running" || s === "stopped";

    const writeStatus = async (status: string, operation: string | null, source: string) =>
      admin.from("dev_runner_config").upsert({
        key: "vm_status",
        value: { status, operation, source, last_checked: new Date().toISOString() },
      });

    // ── AWS EC2 ─────────────────────────────────────────────────────────────
    if (cloud === "aws") {
      const instanceId = (id.instance_id ?? "").toString();

      // Vault first (Om's Secrets screen), project env as a fallback — Om has
      // saved these as Edge Function secrets, so the env half is load-bearing,
      // not decoration.
      const vault = async (name: string): Promise<string | null> => {
        const { data, error } = await admin.rpc("secret_get_runner", { p_name: name });
        return error ? null : (data ? String(data) : null);
      };
      const vaultAkid = await vault("AWS_ACCESS_KEY_ID");
      const akid = vaultAkid ?? Deno.env.get("AWS_ACCESS_KEY_ID") ?? null;
      const secret = (await vault("AWS_SECRET_ACCESS_KEY")) ?? Deno.env.get("AWS_SECRET_ACCESS_KEY") ?? null;
      const sessTok = (await vault("AWS_SESSION_TOKEN")) ?? Deno.env.get("AWS_SESSION_TOKEN") ?? null;
      // Which STORE the credential came from — never the credential itself.
      const credSource = vaultAkid ? "vault" : (Deno.env.get("AWS_ACCESS_KEY_ID") ? "env" : "none");

      // Region: the instance's own identity row wins, then the AWS_REGION
      // secret Om saved alongside the key. Both name ap-south-1 today; reading
      // the secret too means a region move needs no config edit.
      const region = ((id.region ?? "").toString())
        || (await vault("AWS_REGION")) || Deno.env.get("AWS_REGION") || "";
      if (!region || !instanceId) return json({ error: "vm_identity_incomplete", message: copy("dev_queue.ctl_edge_failed") }, 500);

      if (!akid || !secret) {
        // No credential. STOP still works: the box powers itself off when the
        // supervisor sees desired_state.vm='off' (it is running, by definition,
        // if it can be asked to stop). START is the only half that needs a key.
        //
        // But that makes a keyless stop a ONE-WAY DOOR — a stopped instance
        // cannot start itself, so the app could strand its own builder. Say so
        // in the same breath as confirming the stop.
        if (action === "stop") {
          await writeStatus("stopping", null, "self_stop");
          return json({
            status: "stopping",
            operation: null,
            message: copy("dev_queue.ctl_vm_stop_no_key"),
            needs_key: true,
            one_way: true,
            // Nothing to poll: without a key we cannot read EC2 back, and
            // chasing it would just be a queue of 503s.
            settled: true,
          });
        }
        return json({ error: "aws_key_missing", status: "unknown", settled: true, message: copy("dev_queue.ctl_vm_no_key"), needs_key: true }, 503);
      }

      // One shape for every AWS refusal, so an IAM gap is never swallowed by a
      // generic "couldn't reach the cloud".
      const awsFailure = async (r: { status: number; body: string }, iamAction: string) => {
        const detail = ec2Error(r.body) ?? `HTTP ${r.status}`;
        const denied = iamDenied(r.body);
        await writeStatus("unknown", null, "edge");
        return json({
          error: denied ? "aws_iam_denied" : "aws_error",
          detail,
          iam_action: denied ? iamAction : null,
          instance_id: instanceId,
          status: "unknown",
          settled: false,
          message: denied
            ? copyf("dev_queue.ctl_vm_iam_denied", { action: iamAction, instance: instanceId })
            : copyf("dev_queue.ctl_vm_aws_error", { detail }),
          cloud: "aws",
        }, 502);
      };

      // The live instance state, straight from EC2. This is the ONLY source of
      // truth in this function — nothing below infers a state from the action.
      const describe = async (): Promise<{ ok: boolean; status: string; raw: { status: number; body: string } }> => {
        const d = await ec2Call(region, akid, secret, sessTok, { Action: "DescribeInstances", "InstanceId.1": instanceId });
        if (!d.ok) return { ok: false, status: "unknown", raw: d };
        const name = xmlStateName(d.body, "instanceState");
        return { ok: true, status: (name && AWSMAP[name]) || "unknown", raw: d };
      };

      // ── preflight: does the saved key actually hold the three permissions? ─
      // EC2's DryRun flag answers this from AWS itself and changes nothing:
      // "DryRunOperation" means the call WOULD have succeeded (permission held),
      // "UnauthorizedOperation" means it is missing. That matters because the
      // only other way to prove ec2:StopInstances is to stop the builder — which
      // is the machine the build runs on.
      if (action === "preflight") {
        const wanted: Array<[string, string]> = [
          ["DescribeInstances", "ec2:DescribeInstances"],
          ["StartInstances", "ec2:StartInstances"],
          ["StopInstances", "ec2:StopInstances"],
        ];
        const checks: Array<{ action: string; allowed: boolean; code: string }> = [];
        for (const [op, iam] of wanted) {
          const r = await ec2Call(region, akid, secret, sessTok,
            { Action: op, "InstanceId.1": instanceId, DryRun: "true" });
          const code = xmlTag(r.body, "Code") ?? (r.ok ? "Ok" : `HTTP ${r.status}`);
          checks.push({ action: iam, allowed: code === "DryRunOperation" || r.ok, code });
        }
        const missing = checks.filter((x) => !x.allowed).map((x) => x.action);
        return json({
          checks,
          ok_count: checks.length - missing.length,
          missing,
          cred_source: credSource, region, instance_id: instanceId, cloud: "aws",
          settled: true,
          message: missing.length === 0
            ? copyf("dev_queue.ctl_vm_preflight_ok", {
                total: String(checks.length),
                list: checks.map((x) => x.action).join(", "),
                instance: instanceId,
                region,
              })
            : copyf("dev_queue.ctl_vm_preflight_bad", {
                missing: missing.join(", "),
                instance: instanceId,
              }),
        }, missing.length === 0 ? 200 : 502);
      }

      // ── 1. read the TRUE state BEFORE deciding anything ──────────────────
      // The old code let Dart decide "it's already running, skip the call" from
      // a cached config row. Nothing refreshes that cache while the box is off,
      // so a stale 'running' silently ate every START. The no-op check belongs
      // here, against a reading taken one line ago.
      const before = await describe();
      if (!before.ok) return await awsFailure(before.raw, "ec2:DescribeInstances");

      let status = before.status;
      let operation: string | null = null;
      let changed = false;

      if ((action === "start" && before.status === "running") ||
          (action === "stop" && before.status === "stopped")) {
        await writeStatus(status, null, "edge");
        return json({
          status, operation: null, changed: false, settled: true,
          poll_after_ms: pollAfterMs, poll_max: pollMax,
          cred_source: credSource, region, instance_id: instanceId, cloud: "aws",
          message: action === "start" ? copy("dev_queue.ctl_vm_on_toast") : copy("dev_queue.ctl_vm_off_toast"),
        });
      }

      // ── 2. act ────────────────────────────────────────────────────────────
      if (action === "start" || action === "stop") {
        const op = action === "start" ? "StartInstances" : "StopInstances";
        const r = await ec2Call(region, akid, secret, sessTok, { Action: op, "InstanceId.1": instanceId });
        if (!r.ok) return await awsFailure(r, `ec2:${op}`);
        changed = true;
        operation = xmlTag(r.body, "requestId");
        // currentState from the mutation itself: pending / stopping.
        status = AWSMAP[xmlStateName(r.body, "currentState") ?? ""] ?? status;

        // ── 3. read the truth back, so the chip never shows an optimistic label
        const after = await describe();
        if (after.ok) status = after.status;
      }

      await writeStatus(status, operation, "edge");
      const msg = !changed ? ""
        : action === "start" ? copy("dev_queue.ctl_vm_start_sent")
        : copy("dev_queue.ctl_vm_stop_queued");
      return json({
        status, operation, changed,
        // pending/stopping => the client keeps calling 'status' on this cadence
        // until EC2 itself says running/stopped.
        settled: settledOf(status),
        poll_after_ms: pollAfterMs, poll_max: pollMax,
        cred_source: credSource, region, instance_id: instanceId,
        message: msg, cloud: "aws",
      });
    }

    // ── GCP Compute (legacy path, config-selected) ───────────────────────────
    if (!id.project || !id.zone || !id.name) return json({ error: "vm_identity missing" }, 500);
    const saRaw = Deno.env.get("GCP_SA_KEY");
    if (!saRaw) return json({ error: "GCP_SA_KEY_missing", message: copy("dev_queue.ctl_edge_failed") }, 503);

    let token: string;
    try { token = await mintGcpToken(JSON.parse(saRaw)); }
    catch (e) { return json({ error: "token_mint_failed", detail: String(e) }, 502); }

    const base = `https://compute.googleapis.com/compute/v1/projects/${id.project}/zones/${id.zone}/instances/${id.name}`;
    let status = "unknown"; let operation: string | null = null; let gcpError: unknown = null;

    if (action === "start" || action === "stop") {
      const r = await fetch(`${base}/${action}`, { method: "POST", headers: { Authorization: `Bearer ${token}` } });
      const b = await r.json().catch(() => ({}));
      if (!r.ok) gcpError = b?.error ?? b;
      operation = b?.name ?? null;
      status = action === "start" ? "starting" : "stopping";
    }

    const g = await fetch(base, { headers: { Authorization: `Bearer ${token}` } });
    const gb = await g.json().catch(() => ({}));
    if (!g.ok) gcpError = gb?.error ?? gb;
    if (gb.status) status = GMAP[gb.status] ?? status;

    await writeStatus(status, operation, "edge");
    if (gcpError) return json({ status, operation, gcp_error: gcpError, message: copy("dev_queue.ctl_edge_failed") }, 502);
    return json({ status, operation, cloud: "gcp" });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
