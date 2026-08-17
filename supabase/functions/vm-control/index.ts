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
// Deno.env is only a fallback for a hand-set project secret.
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
    if (!["start", "stop", "status"].includes(action)) return json({ error: "bad_action" }, 400);
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
                  "dev_queue.ctl_vm_start_sent", "dev_queue.ctl_edge_failed"]);
    const copy = (k: string) =>
      String((copyRows ?? []).find((r: any) => r.key === k)?.value ?? "").replace(/^"|"$/g, "");

    const { data: idRow } = await admin.from("dev_runner_config").select("value").eq("key", "vm_identity").single();
    const id = idRow?.value ?? {};
    const cloud = (id.cloud ?? "gcp").toString();

    const writeStatus = async (status: string, operation: string | null, source: string) =>
      admin.from("dev_runner_config").upsert({
        key: "vm_status",
        value: { status, operation, source, last_checked: new Date().toISOString() },
      });

    // ── AWS EC2 ─────────────────────────────────────────────────────────────
    if (cloud === "aws") {
      const region = (id.region ?? "").toString();
      const instanceId = (id.instance_id ?? "").toString();
      if (!region || !instanceId) return json({ error: "vm_identity_incomplete", message: copy("dev_queue.ctl_edge_failed") }, 500);

      // Vault first (Om's Secrets screen), project env as a fallback.
      const vault = async (name: string): Promise<string | null> => {
        const { data, error } = await admin.rpc("secret_get_runner", { p_name: name });
        return error ? null : (data ? String(data) : null);
      };
      const akid = (await vault("AWS_ACCESS_KEY_ID")) ?? Deno.env.get("AWS_ACCESS_KEY_ID") ?? null;
      const secret = (await vault("AWS_SECRET_ACCESS_KEY")) ?? Deno.env.get("AWS_SECRET_ACCESS_KEY") ?? null;
      const sessTok = (await vault("AWS_SESSION_TOKEN")) ?? Deno.env.get("AWS_SESSION_TOKEN") ?? null;

      if (!akid || !secret) {
        // No credential. STOP still works: the box powers itself off when the
        // supervisor sees desired_state.vm='off' (it is running, by definition,
        // if it can be asked to stop). START is the only half that needs a key.
        if (action === "stop") {
          await writeStatus("stopping", null, "self_stop");
          return json({ status: "stopping", operation: null, message: copy("dev_queue.ctl_vm_stop_queued"), needs_key: false });
        }
        return json({ error: "aws_key_missing", status: "unknown", message: copy("dev_queue.ctl_vm_no_key"), needs_key: true }, 503);
      }

      let status = "unknown";
      let operation: string | null = null;

      if (action === "start" || action === "stop") {
        const op = action === "start" ? "StartInstances" : "StopInstances";
        const r = await ec2Call(region, akid, secret, sessTok, { Action: op, "InstanceId.1": instanceId });
        const err = r.ok ? null : (ec2Error(r.body) ?? `HTTP ${r.status}`);
        if (err) {
          await writeStatus("unknown", null, "edge");
          return json({ error: "aws_error", detail: err, status: "unknown", message: copy("dev_queue.ctl_edge_failed") }, 502);
        }
        operation = xmlTag(r.body, "requestId");
        status = AWSMAP[xmlStateName(r.body, "currentState") ?? ""] ?? "";
        if (!status) status = action === "start" ? "starting" : "stopping";
      }

      // Always read the truth back.
      const d = await ec2Call(region, akid, secret, sessTok, { Action: "DescribeInstances", "InstanceId.1": instanceId });
      if (d.ok) {
        const name = xmlStateName(d.body, "instanceState");
        if (name && AWSMAP[name]) status = AWSMAP[name];
      }

      await writeStatus(status, operation, "edge");
      const msg = action === "start" ? copy("dev_queue.ctl_vm_start_sent")
        : action === "stop" ? copy("dev_queue.ctl_vm_stop_queued") : "";
      return json({ status, operation, message: msg, cloud: "aws" });
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
