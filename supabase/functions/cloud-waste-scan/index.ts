// cloud-waste-scan — the monthly read-only sweep for cloud resources that cost
// money and do nothing.
//
// cmd #433. `mediBO-runner/gcp_waste_scan.sh` shelled out to `gcloud compute
// disks list`. There is no gcloud on this box, no GCP project behind it and
// `.gcp_capability_off` is present, so for months the "Scheduled: Monthly waste
// scan" command printed "Google setup pending" and reported nothing — the same
// hole CHANGE #289 found in the weekly snapshot, in a second job.
//
// It lives here for the same two reasons vm-snapshot does: the AWS key lives
// here and deliberately nowhere on the VM, and the VM powers itself off when
// the queue is idle, so anything scheduled ON the box silently skips whichever
// month it happened to be down for.
//
// This function READS. It calls three Describe* actions and nothing else —
// there is no code path in this file that deletes, detaches or releases
// anything, by contract with the spec.
//
// Actions:
//   preflight — DryRun each Describe call. Names the exact missing IAM action
//               instead of a stack trace.
//   run       — read the facts, hand them to cloud_waste_compose(), return the
//               rendered payload. Every rupee and every word is composed in
//               SQL from `cloud_waste_rates` and `ui_copy`; this file words
//               nothing and prices nothing.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SVC = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
};
const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const enc = new TextEncoder();
function hex(b: ArrayBuffer) { return [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join(""); }
async function sha256Hex(s: string) { return hex(await crypto.subtle.digest("SHA-256", enc.encode(s))); }
async function hmac(key: ArrayBuffer | Uint8Array, msg: string): Promise<ArrayBuffer> {
  const k = await crypto.subtle.importKey("raw", key as BufferSource, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(msg));
}
function jwtRole(auth: string): string | null {
  try {
    const p = auth.replace(/^Bearer\s+/i, "").split(".")[1];
    return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/"))).role ?? null;
  } catch (_) { return null; }
}

// ── AWS SigV4 against the EC2 Query API (the shape vm-control/vm-snapshot use)
async function ec2Call(
  region: string, akid: string, secret: string, token: string | null,
  params: Record<string, string>,
): Promise<{ ok: boolean; status: number; body: string }> {
  const host = `ec2.${region}.amazonaws.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const body = new URLSearchParams({ Version: "2016-11-15", ...params }).toString();
  const payloadHash = await sha256Hex(body);
  const signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date" + (token ? ";x-amz-security-token" : "");
  const canonicalHeaders =
    "content-type:application/x-www-form-urlencoded; charset=utf-8\n" +
    `host:${host}\n` + `x-amz-content-sha256:${payloadHash}\n` + `x-amz-date:${amzDate}\n` +
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

function xmlTag(xml: string, tag: string): string | null {
  const m = xml.match(new RegExp(`<${tag}>([^<]*)</${tag}>`));
  return m ? m[1] : null;
}
function ec2Error(xml: string): string | null {
  const code = xmlTag(xml, "Code"); const msg = xmlTag(xml, "Message");
  return code || msg ? `${code ?? ""}${code && msg ? ": " : ""}${msg ?? ""}` : null;
}
function iamDenied(xml: string): boolean {
  const code = (xmlTag(xml, "Code") ?? "").toLowerCase();
  return code.includes("unauthorizedoperation") || code.includes("accessdenied");
}
// <item> nests — a volume's attachmentSet and tagSet are lists of <item>s of
// their own — so a non-greedy regex would cut every record short at its first
// nested tag. Walk the string and only return items at depth 0.
function topItems(xml: string): string[] {
  const out: string[] = []; let depth = 0; let start = -1; let i = 0;
  while (i < xml.length) {
    if (xml.startsWith("<item>", i)) {
      if (depth === 0) start = i + 6;
      depth++; i += 6; continue;
    }
    if (xml.startsWith("</item>", i)) {
      depth--;
      if (depth === 0 && start >= 0) { out.push(xml.slice(start, i)); start = -1; }
      i += 7; continue;
    }
    i++;
  }
  return out;
}
function section(xml: string, wrapper: string): string {
  const m = xml.match(new RegExp(`<${wrapper}>([\\s\\S]*?)</${wrapper}>`));
  return m ? m[1] : "";
}
function tagsOf(itemXml: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const t of topItems(section(itemXml, "tagSet"))) {
    const k = xmlTag(t, "key"); const v = xmlTag(t, "value");
    if (k) out[k] = v ?? "";
  }
  return out;
}
const ageDays = (iso: string): number =>
  iso ? Math.max(0, Math.floor((Date.now() - Date.parse(iso)) / 86400000)) : 0;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const action = (body.action ?? "run").toString();
    if (!["run", "preflight"].includes(action)) return json({ error: "bad_action" }, 400);
    const auth = req.headers.get("Authorization") ?? "";

    let ok = jwtRole(auth) === "service_role" || auth.includes(SVC);
    if (!ok) {
      const caller = createClient(URL_, ANON, { global: { headers: { Authorization: auth } } });
      const { data } = await caller.rpc("am_i_super");
      ok = data === true;
    }
    if (!ok) return json({ error: "not_authorized" }, 403);

    const admin = createClient(URL_, SVC);
    const { data: idRow } = await admin.from("dev_runner_config")
      .select("value").eq("key", "vm_identity").maybeSingle();
    const id = (idRow?.value ?? {}) as Record<string, any>;
    const cloud = (id.cloud ?? "gcp").toString();

    const vault = async (name: string): Promise<string | null> => {
      const { data, error } = await admin.rpc("secret_get_runner", { p_name: name });
      return error ? null : (data ? String(data) : null);
    };
    const akid = (await vault("AWS_ACCESS_KEY_ID")) ?? Deno.env.get("AWS_ACCESS_KEY_ID") ?? null;
    const secret = (await vault("AWS_SECRET_ACCESS_KEY")) ?? Deno.env.get("AWS_SECRET_ACCESS_KEY") ?? null;
    const sessTok = (await vault("AWS_SESSION_TOKEN")) ?? Deno.env.get("AWS_SESSION_TOKEN") ?? null;
    const region = ((id.region ?? "").toString()) || Deno.env.get("AWS_REGION") || "";

    // The three reads this function is allowed to make. Nothing mutating is
    // listed here, and nothing mutating is called anywhere in this file.
    const READS: Array<[string, string]> = [
      ["DescribeVolumes", "ec2:DescribeVolumes"],
      ["DescribeAddresses", "ec2:DescribeAddresses"],
      ["DescribeSnapshots", "ec2:DescribeSnapshots"],
    ];

    // ── preflight ───────────────────────────────────────────────────────────
    if (action === "preflight") {
      if (!akid || !secret) return json({ error: "aws_key_missing", needs_key: true }, 503);
      const checks: Array<{ action: string; allowed: boolean; denied: boolean; code: string }> = [];
      for (const [op, iam] of READS) {
        const p: Record<string, string> = { Action: op, DryRun: "true" };
        if (op === "DescribeSnapshots") p["Owner.1"] = "self";
        const r = await ec2Call(region, akid, secret, sessTok, p);
        const code = xmlTag(r.body, "Code") ?? (r.ok ? "Ok" : `HTTP ${r.status}`);
        // Only two codes are evidence: DryRunOperation (AWS authorized it and
        // stopped) and an explicit refusal. Anything else is reported as-is.
        checks.push({ action: iam, allowed: code === "DryRunOperation" || r.ok, denied: iamDenied(r.body), code });
      }
      const missing = checks.filter((x) => x.denied).map((x) => x.action);
      return json({
        ok: missing.length === 0, checks, missing, region,
        iam_statement: {
          Effect: "Allow", Action: READS.map(([, iam]) => iam), Resource: "*",
        },
      }, missing.length === 0 ? 200 : 502);
    }

    // ── run ─────────────────────────────────────────────────────────────────
    // Every category degrades on its own. A denied DescribeVolumes must not
    // cost us the bucket list, and no credential at all must not cost us the
    // storage half — the scan is more useful partial than absent.
    const denied: string[] = [];
    const errors: string[] = [];
    const facts: Record<string, unknown> = {
      cloud, region, key_present: Boolean(akid && secret),
      volumes: [], addresses: [], snapshots: [],
    };

    const read = async (op: string, iam: string, extra: Record<string, string> = {}) => {
      const r = await ec2Call(region, akid!, secret!, sessTok, { Action: op, ...extra });
      if (r.ok) return r.body;
      if (iamDenied(r.body)) denied.push(iam);
      else errors.push(`${iam}: ${ec2Error(r.body) ?? `HTTP ${r.status}`}`);
      return null;
    };

    if (cloud === "aws" && akid && secret && region) {
      // Unattached disks: `status=available` IS the unattached state in EC2 —
      // a volume in use reads `in-use`. Filtering server-side keeps a large
      // account's whole volume list off this function's heap.
      const vx = await read("DescribeVolumes", "ec2:DescribeVolumes",
        { "Filter.1.Name": "status", "Filter.1.Value.1": "available" });
      if (vx) {
        facts.volumes = topItems(section(vx, "volumeSet")).map((it) => ({
          id: xmlTag(it, "volumeId") ?? "",
          size_gb: Number(xmlTag(it, "size") ?? "0"),
          zone: xmlTag(it, "availabilityZone") ?? "",
          created_at: xmlTag(it, "createTime") ?? "",
          name: tagsOf(it)["Name"] ?? "",
        }));
      }

      // An Elastic IP is billed while it is reserved and attached to nothing.
      // "Attached to nothing" is the ABSENCE of an association id — an address
      // bound to an instance or a network interface has one.
      const ax = await read("DescribeAddresses", "ec2:DescribeAddresses");
      if (ax) {
        facts.addresses = topItems(section(ax, "addressesSet"))
          .filter((it) => !xmlTag(it, "associationId") && !xmlTag(it, "instanceId"))
          .map((it) => ({
            ip: xmlTag(it, "publicIp") ?? "",
            allocation_id: xmlTag(it, "allocationId") ?? "",
            domain: xmlTag(it, "domain") ?? "",
          }));
      }

      // Owner=self keeps public and shared snapshots out. Newest first, so the
      // keep rule in cloud_waste_compose lands on the same rows vm-snapshot
      // would prune.
      const sx = await read("DescribeSnapshots", "ec2:DescribeSnapshots", { "Owner.1": "self" });
      if (sx) {
        facts.snapshots = topItems(section(sx, "snapshotSet")).map((it) => {
          const started = xmlTag(it, "startTime") ?? "";
          return {
            id: xmlTag(it, "snapshotId") ?? "",
            name: tagsOf(it)["Name"] ?? "",
            size_gb: Number(xmlTag(it, "volumeSize") ?? "0"),
            started_at: started,
            age_days: ageDays(started),
          };
        }).sort((a, b) => (a.started_at < b.started_at ? 1 : -1));
      }
    }

    facts.denied = denied;
    facts.errors = errors;

    // SQL owns every rupee and every sentence. This function hands over facts.
    const { data: payload, error } = await admin.rpc("cloud_waste_compose", { p_aws: facts });
    if (error) return json({ error: "compose_failed", detail: error.message }, 500);

    const p = (payload ?? {}) as Record<string, any>;
    const lines: string[] = [];
    for (const g of (p.groups ?? []) as Array<Record<string, any>>) {
      const rows = (g.rows ?? []) as Array<Record<string, any>>;
      lines.push(`${g.title}: ${rows.length === 0 ? g.empty_label : g.subtotal_display}`);
      for (const r of rows) lines.push(`  - ${r.label} — ${r.amount_display}`);
      if (g.note) lines.push(`  ${g.note}`);
    }
    const message = [p.total_display, ...lines, p.blocked, p.warning, p.footer]
      .filter((x) => typeof x === "string" && x.length > 0).join("\n");

    return json({ ok: true, deleted: 0, read_only: true, ...p, message });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
