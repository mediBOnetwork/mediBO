// vm-snapshot — the weekly disk snapshot of the builder VM's boot volume.
//
// CHANGE #289. The old path was `mediBO-runner/gcp_snapshot.sh`, which shells
// out to `gcloud compute snapshots`. That box no longer exists: the builder
// moved to AWS EC2 (`vm_identity.cloud = "aws"`), there is no gcloud on the new
// machine, no IAM instance profile, and — deliberately — no AWS credential on
// disk anywhere on the VM. So the snapshot cannot be taken BY the machine being
// snapshotted; it is taken from here, where the AWS key already lives for
// `vm-control` (Vault first, Edge Function secrets as the live fallback).
//
// Running it here also fixes the reliability half. The VM powers itself off
// when the queue is idle, so anything scheduled ON the box silently skips a
// week whenever the box is down. This function is reachable from pg_cron, which
// is up as long as the database is.
//
// Actions:
//   preflight — DryRun every EC2 call this function makes. Changes nothing and
//               names the exact missing IAM action, so a permission gap is a
//               sentence Om can act on rather than a stack trace.
//   run       — create this week's snapshot, then prune. Idempotent PER ISO
//               WEEK (tag `medibo-week`): a second run in the same week creates
//               nothing, so the pg_cron schedule and the Dev Queue's weekly
//               "Scheduled: Weekly disk snapshot" command can both fire without
//               ever paying for two snapshots. `force: true` overrides.
//   list      — read the kept snapshots back, no mutation.
//
// Retention is config, not a literal: `dev_runner_config.vm_snapshot` holds
// {keep, max_age_days, tag}. Keep the newest `keep`, and drop anything older
// than `max_age_days` — the two agree at 4 weekly snapshots over 28 days, and
// either one alone would leave the other's edge case behind.
//
// Every human-facing string is a `ui_copy` row. This function never words
// anything itself.
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

// ── AWS SigV4 against the EC2 Query API (same shape vm-control uses) ────────
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
// <item> nests (a snapshot's tagSet is a list of <item>s of its own), so a
// non-greedy regex would cut every snapshot short at its first tag. Walk the
// string and only return items at depth 0.
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

// ── dates ───────────────────────────────────────────────────────────────────
// Operations are IST, so the snapshot is named for the Indian calendar day it
// was taken on, not UTC's.
function istParts(d: Date) {
  const f = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Kolkata", year: "numeric", month: "2-digit", day: "2-digit",
  });
  return f.format(d); // YYYY-MM-DD
}
// ISO week of the IST calendar day — the idempotency key.
function isoWeek(ymd: string): string {
  const [y, m, d] = ymd.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  const day = dt.getUTCDay() || 7;
  dt.setUTCDate(dt.getUTCDate() + 4 - day);
  const yearStart = new Date(Date.UTC(dt.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((dt.getTime() - yearStart.getTime()) / 86400000 + 1) / 7);
  return `${dt.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const action = (body.action ?? "run").toString();
    if (!["run", "preflight", "list"].includes(action)) return json({ error: "bad_action" }, 400);
    const force = body.force === true;
    const auth = req.headers.get("Authorization") ?? "";

    let ok = jwtRole(auth) === "service_role" || auth.includes(SVC);
    if (!ok) {
      const caller = createClient(URL_, ANON, { global: { headers: { Authorization: auth } } });
      const { data } = await caller.rpc("am_i_super");
      ok = data === true;
    }
    if (!ok) return json({ error: "not_authorized" }, 403);

    const admin = createClient(URL_, SVC);

    const { data: copyRows } = await admin.from("ui_copy").select("key,value").like("key", "dev_queue.snap_%");
    const copy = (k: string) =>
      String((copyRows ?? []).find((r: any) => r.key === k)?.value ?? "").replace(/^"|"$/g, "");
    const copyf = (k: string, vars: Record<string, string>) =>
      Object.entries(vars).reduce((s, [n, v]) => s.split(`{${n}}`).join(v), copy(k));

    const cfgRow = async (key: string) => {
      const { data } = await admin.from("dev_runner_config").select("value").eq("key", key).maybeSingle();
      return (data?.value ?? {}) as Record<string, any>;
    };
    const id = await cfgRow("vm_identity");
    const pol = await cfgRow("vm_snapshot");
    const keep = Number(pol.keep ?? 4);
    const maxAgeDays = Number(pol.max_age_days ?? 28);
    const tagKey = String(pol.tag_key ?? "medibo-snapshot");
    const tagVal = String(pol.tag_value ?? "weekly-boot");
    const prefix = String(pol.name_prefix ?? "medibo-boot");

    if ((id.cloud ?? "gcp").toString() !== "aws")
      return json({ error: "not_aws", cloud: id.cloud ?? null, message: copy("dev_queue.snap_not_aws") }, 400);

    const instanceId = (id.instance_id ?? "").toString();
    const vault = async (name: string): Promise<string | null> => {
      const { data, error } = await admin.rpc("secret_get_runner", { p_name: name });
      return error ? null : (data ? String(data) : null);
    };
    const vaultAkid = await vault("AWS_ACCESS_KEY_ID");
    const akid = vaultAkid ?? Deno.env.get("AWS_ACCESS_KEY_ID") ?? null;
    const secret = (await vault("AWS_SECRET_ACCESS_KEY")) ?? Deno.env.get("AWS_SECRET_ACCESS_KEY") ?? null;
    const sessTok = (await vault("AWS_SESSION_TOKEN")) ?? Deno.env.get("AWS_SESSION_TOKEN") ?? null;
    const credSource = vaultAkid ? "vault" : (Deno.env.get("AWS_ACCESS_KEY_ID") ? "env" : "none");
    const region = ((id.region ?? "").toString()) || (await vault("AWS_REGION")) || Deno.env.get("AWS_REGION") || "";

    if (!region || !instanceId) return json({ error: "vm_identity_incomplete" }, 500);
    if (!akid || !secret)
      return json({ error: "aws_key_missing", needs_key: true, message: copy("dev_queue.snap_no_key") }, 503);

    const fail = async (r: { status: number; body: string }, iamAction: string) => {
      const detail = ec2Error(r.body) ?? `HTTP ${r.status}`;
      const denied = iamDenied(r.body);
      await admin.rpc("backup_report", {
        p_kind: "vm_snapshot", p_location: "", p_size_mb: 0, p_ok: false,
        p_note: `${iamAction}: ${detail}`,
      });
      return json({
        error: denied ? "aws_iam_denied" : "aws_error",
        detail, iam_action: denied ? iamAction : null, instance_id: instanceId, region,
        message: denied
          ? copyf("dev_queue.snap_iam_denied", { action: iamAction, instance: instanceId })
          : copyf("dev_queue.snap_aws_error", { detail }),
      }, 502);
    };

    // The boot volume, read from EC2 rather than remembered in config: a resized
    // or replaced root volume must not send the snapshot at a stale id.
    const bootVolume = async (): Promise<{ ok: boolean; volumeId: string; raw: any }> => {
      const d = await ec2Call(region, akid, secret, sessTok,
        { Action: "DescribeInstances", "InstanceId.1": instanceId });
      if (!d.ok) return { ok: false, volumeId: "", raw: d };
      const root = xmlTag(d.body, "rootDeviceName") ?? "";
      const maps = topItems(section(d.body, "blockDeviceMapping"));
      let vol = "";
      for (const m of maps) {
        const dev = xmlTag(m, "deviceName");
        const v = xmlTag(m, "volumeId");
        if (v && (dev === root || !vol)) { vol = v; if (dev === root) break; }
      }
      return { ok: vol !== "", volumeId: vol, raw: d };
    };

    // Every snapshot this feature owns, newest first. Owner=self keeps public
    // and shared snapshots out; the tag keeps anything hand-made out.
    const listSnaps = async (): Promise<{ ok: boolean; rows: any[]; raw: any }> => {
      const r = await ec2Call(region, akid, secret, sessTok, {
        Action: "DescribeSnapshots", "Owner.1": "self",
        "Filter.1.Name": `tag:${tagKey}`, "Filter.1.Value.1": tagVal,
      });
      if (!r.ok) return { ok: false, rows: [], raw: r };
      const rows = topItems(section(r.body, "snapshotSet")).map((it) => {
        const tags = tagsOf(it);
        return {
          snapshot_id: xmlTag(it, "snapshotId") ?? "",
          name: tags["Name"] ?? (xmlTag(it, "snapshotId") ?? ""),
          week: tags["medibo-week"] ?? "",
          started_at: xmlTag(it, "startTime") ?? "",
          size_gb: Number(xmlTag(it, "volumeSize") ?? "0"),
          state: xmlTag(it, "status") ?? "",
          progress: xmlTag(it, "progress") ?? "",
        };
      }).sort((a, b) => (a.started_at < b.started_at ? 1 : -1));
      return { ok: true, rows, raw: r };
    };

    // ── preflight ───────────────────────────────────────────────────────────
    if (action === "preflight") {
      // A placeholder id must be WELL FORMED or EC2 rejects the shape before it
      // ever reaches the authorization check — "InvalidSnapshotID.Malformed"
      // says nothing at all about the permission, and reading it as a pass is
      // how a preflight lies.
      const wanted: Array<[string, string, Record<string, string>]> = [
        ["DescribeInstances", "ec2:DescribeInstances", { "InstanceId.1": instanceId }],
        ["DescribeSnapshots", "ec2:DescribeSnapshots", { "Owner.1": "self" }],
        ["CreateSnapshot", "ec2:CreateSnapshot", {}],
        ["DeleteSnapshot", "ec2:DeleteSnapshot", { SnapshotId: "snap-0123456789abcdef0" }],
        ["CreateTags", "ec2:CreateTags", {
          "ResourceId.1": "snap-0123456789abcdef0",
          "Tag.1.Key": "Name", "Tag.1.Value": "preflight",
        }],
      ];
      const bv = await bootVolume();
      const checks: Array<{ action: string; allowed: boolean; denied: boolean; code: string }> = [];
      for (const [op, iam, extra] of wanted) {
        const p: Record<string, string> = { Action: op, DryRun: "true", ...extra };
        if (op === "CreateSnapshot") p["VolumeId"] = bv.volumeId || "vol-0123456789abcdef0";
        const r = await ec2Call(region, akid, secret, sessTok, p);
        const code = xmlTag(r.body, "Code") ?? (r.ok ? "Ok" : `HTTP ${r.status}`);
        // Only two codes are evidence: DryRunOperation (AWS authorized it and
        // stopped) and an explicit refusal. Anything else is reported as-is
        // rather than counted either way.
        const allowed = code === "DryRunOperation" || r.ok;
        checks.push({ action: iam, allowed, denied: iamDenied(r.body), code });
      }
      const missing = checks.filter((x) => x.denied).map((x) => x.action);
      const unclear = checks.filter((x) => !x.allowed && !x.denied).map((x) => `${x.action} (${x.code})`);
      return json({
        checks, ok_count: checks.filter((x) => x.allowed).length, missing, unclear,
        cred_source: credSource, region, instance_id: instanceId,
        boot_volume: bv.volumeId || null,
        message: missing.length === 0
          ? copyf("dev_queue.snap_preflight_ok", {
              total: String(checks.length), list: checks.map((x) => x.action).join(", "),
              instance: instanceId, region,
            })
          : copyf("dev_queue.snap_preflight_bad", { missing: missing.join(", "), instance: instanceId }),
      }, missing.length === 0 ? 200 : 502);
    }

    // ── list ────────────────────────────────────────────────────────────────
    if (action === "list") {
      const l = await listSnaps();
      if (!l.ok) return await fail(l.raw, "ec2:DescribeSnapshots");
      return json({ ok: true, kept: l.rows, keep, max_age_days: maxAgeDays, region });
    }

    // ── run ─────────────────────────────────────────────────────────────────
    const now = new Date();
    const ymd = istParts(now);
    const week = isoWeek(ymd);
    const name = `${prefix}-${ymd}`;

    const before = await listSnaps();
    if (!before.ok) return await fail(before.raw, "ec2:DescribeSnapshots");

    const already = before.rows.find((s) => s.week === week && s.state !== "error");
    let created: any = null;
    let skipped = false;

    if (already && !force) {
      skipped = true;
    } else {
      const bv = await bootVolume();
      if (!bv.ok) return await fail(bv.raw, "ec2:DescribeInstances");
      const c = await ec2Call(region, akid, secret, sessTok, {
        Action: "CreateSnapshot",
        VolumeId: bv.volumeId,
        Description: `${name} — weekly boot-disk snapshot of ${instanceId}`,
        "TagSpecification.1.ResourceType": "snapshot",
        "TagSpecification.1.Tag.1.Key": "Name",
        "TagSpecification.1.Tag.1.Value": name,
        "TagSpecification.1.Tag.2.Key": tagKey,
        "TagSpecification.1.Tag.2.Value": tagVal,
        "TagSpecification.1.Tag.3.Key": "medibo-week",
        "TagSpecification.1.Tag.3.Value": week,
      });
      if (!c.ok) return await fail(c, "ec2:CreateSnapshot");
      created = {
        snapshot_id: xmlTag(c.body, "snapshotId") ?? "",
        name, week,
        size_gb: Number(xmlTag(c.body, "volumeSize") ?? "0"),
        volume_id: bv.volumeId,
        state: xmlTag(c.body, "status") ?? "pending",
        started_at: xmlTag(c.body, "startTime") ?? now.toISOString(),
      };
    }

    // ── prune: keep the newest `keep`, and drop anything past `max_age_days` ─
    const after = await listSnaps();
    if (!after.ok) return await fail(after.raw, "ec2:DescribeSnapshots");
    const cutoff = Date.now() - maxAgeDays * 86400000;
    const doomed = after.rows.filter((s, i) => {
      if (created && s.snapshot_id === created.snapshot_id) return false; // never the one just taken
      const aged = s.started_at ? Date.parse(s.started_at) < cutoff : false;
      return i >= keep || aged;
    });
    const pruned: string[] = []; const prune_failed: string[] = [];
    for (const s of doomed) {
      const d = await ec2Call(region, akid, secret, sessTok,
        { Action: "DeleteSnapshot", SnapshotId: s.snapshot_id });
      if (d.ok) pruned.push(s.name || s.snapshot_id);
      else prune_failed.push(`${s.name || s.snapshot_id}: ${ec2Error(d.body) ?? d.status}`);
    }

    const kept = after.rows.filter((s) => !doomed.some((d) => d.snapshot_id === s.snapshot_id));
    const sizeGb = created?.size_gb ?? (kept[0]?.size_gb ?? 0);

    const headline = skipped
      ? copyf("dev_queue.snap_exists", { name: already.name, week })
      : copyf("dev_queue.snap_created", { name: created.name, id: created.snapshot_id, size: `${sizeGb} GB` });
    const pruneLine = pruned.length > 0
      ? copyf("dev_queue.snap_pruned", {
          n: String(pruned.length), list: pruned.join(", "),
          keep: String(keep), days: String(maxAgeDays), kept: String(kept.length),
        })
      : copyf("dev_queue.snap_pruned_none", {
          keep: String(keep), days: String(maxAgeDays), kept: String(kept.length),
        });
    const message = `${headline} ${pruneLine}`.trim();

    await admin.from("dev_runner_config").upsert({
      key: "vm_snapshot_state",
      value: {
        last_run_at: now.toISOString(), week,
        last_name: skipped ? already.name : created.name,
        last_snapshot_id: skipped ? already.snapshot_id : created.snapshot_id,
        created: !skipped, kept, pruned, prune_failed,
        keep, max_age_days: maxAgeDays, region, instance_id: instanceId,
        message,
      },
    });
    await admin.rpc("backup_report", {
      p_kind: "vm_snapshot",
      p_location: `${region}:${skipped ? already.snapshot_id : created.snapshot_id}`,
      p_size_mb: sizeGb * 1024,
      p_ok: prune_failed.length === 0,
      p_note: message,
    });

    return json({
      ok: true, created: !skipped, skipped,
      snapshot: skipped ? already : created,
      name: skipped ? already.name : created.name,
      week, kept, pruned, prune_failed,
      keep, max_age_days: maxAgeDays, region, instance_id: instanceId,
      cred_source: credSource, message,
    });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
