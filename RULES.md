# mediBO — Portable Agent Rules (canonical, auto-generated)
# Source of truth: Supabase agent_memory. Edit in the mediBO app
# (Dev Queue -> Memory) or via the memory MCP server. Regenerated every
# session by memory_render.sh. This file is the OFFLINE git fallback: if both
# Supabase and the MCP server are down, agents still boot from this committed copy.

<!-- BEGIN agent_memory -->
<!-- AUTO-GENERATED from Supabase agent_memory. Edit rules in the mediBO
     Dev Queue → Memory screen, or via the MCP memory server. Do NOT hand-edit
     this block; it is rewritten on every session start. Target: generic -->

# Agent memory (generic) — 40 rules
# Canonical fallback: see RULES.md in the repo root (git-committed).

## GLOBAL · style  (priority 10, v2)

Answer in 10 lines max. Each line = title + short description, max 5 words per line, 50 words per response total. Bullet points only (**Title** — description). No preamble, no closing offer.

Interactive sessions: wait for the instruction, do the thing asked, and do NOT auto-suggest next steps. In the autonomous runner loop the opposite applies to questions only — never ask, decide and log (see rules).


## GLOBAL · pricing  (priority 20, v2)

All money in INR (₹), India market. All timestamps IST for display. Never quote USD. Road distances from self-hosted OSRM only — never Google Distance/Route Matrix APIs.

Prices, totals, discounts, GST and every ₹ string are computed and formatted in the backend and rendered verbatim; Dart never does money arithmetic or currency formatting.


## GLOBAL · rules  (priority 30, v2)

Never flag — fix. A problem you can fix yourself is unfinished work, not a finding. Decide, don't ask: pick the recommended option and execute; ask only for irreversible data loss (DROP/TRUNCATE/DELETE of rows you did not create), auth/RLS weakening, or payment config changes.

Forbidden outputs: "flagged for review", "needs manual attention", "please check", "recommend Om looks at". A blocker you hit (missing column, broken RPC, failing build, stale data, config gap) is part of the job: repair it, log the repair, continue. Never output "paste this SQL" or "add this to Flutter" — run it, write it. Every choice you make alone gets logged as a decision {question, options, picked, reason}.


## GLOBAL · backend  (priority 40, v2)

Maximum backend. Everything computed, decided, formatted and worded in the backend. The frontend does exactly two things: render what the backend returns, and send user input back. No display strings, totals, role branches, routes, or formatting in Dart. On a clash, backend wins.

A display string written in Dart is a bug — put it in `ui_copy` (read via `c()` / `cf()`) or the feature's own table. Labels, empty states, toasts, button captions, status chips, plural forms and error copy all arrive in the payload. Changing wording must be an UPDATE, not a deploy.

GAP CHECK FIRST: before wiring anything, check whether its backend exists. Any logic currently missing, or any logic sitting in the frontend, is a gap — build the backend first (tables, RPCs, strings, rules), then wire.


## GLOBAL · offline  (priority 50, v2)

Fast on slow/no internet. Cache the last payload, render it instantly with the backend's own staleness string, refetch in background, re-render. The cache is a render fallback, never an authority. Queue writes, send, await, render — no optimistic state.


## PROJECT · business  (priority 55, v2)

## 9. KNOW THE BUSINESS BEFORE YOU BUILD
- Before starting EVERY command: read the business context doc —
  legal_get_page('about') — plus the spec, fully.
- mediBO decisions must match its real business model as written there
  (who it serves, how pricing/billing actually works, roles, flows).
  If your general assumption conflicts with the context doc, the
  context doc WINS. Wrong-model builds are failed commands.
- If the context doc is missing or thin, improve it from the codebase
  truth as part of your command — do not build on guesses.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Know the business before you build. Before starting EVERY command, read the business context doc — `legal_get_page('about')` — plus the spec, fully.

mediBO decisions must match its real business model as written there (who it serves, how pricing/billing actually works, roles, flows). If a general assumption conflicts with the context doc, the CONTEXT DOC WINS. Wrong-model builds are failed commands. If the context doc is missing or thin, improve it from codebase truth as part of your command — never build on guesses.



## PROJECT · behaviour  (priority 56, v1)

## Behaviour
- Wait for user instruction
- Do NOT auto-suggest next steps



## PROJECT · runner_prime  (priority 57, v1)

# ═══════════════════════════════════════════════
# DEV QUEUE RUNNER — PERMANENT RULES (NON-NEGOTIABLE)
# Claude: these rules override everything except safety.
# Re-read this block before EVERY command you claim.
# ═══════════════════════════════════════════════

## PRIME DIRECTIVE
You are an autonomous runner. Your job: claim → build → deploy → verify → record → next.
You NEVER stop, NEVER wait for a human, NEVER leave a row half-updated.



## PROJECT · runner_questions  (priority 58, v1)

## 1. NEVER ASK QUESTIONS
- If a choice arises: pick the recommended/safest option, KEEP BUILDING.
- Log every choice via the decisions helper: {question, options, picked, reason}.
- ONLY exception — truly destructive/irreversible actions:
  dropping tables/columns with data, deleting user data, auth/RLS weakening,
  payment config changes. For these: call dev_cmd_ask(id, question),
  then IMMEDIATELY claim the next command. Never idle.



## PROJECT · token_efficiency  (priority 59, v1)

Token discipline (CHANGE #198). Five levers, all config-driven from dev_runner_config.worker_pool — change a knob with pool_set(), no deploy.

1. **Read REPO_MAP.md first, never scan the repo.** `~/mediBO/REPO_MAP.md` is a one-line-per-file index (path → purpose → exports → RPCs it calls) of every screen, service, migration, edge function, script and protected test. deploy.sh regenerates it every deploy via `scripts/gen_repo_map.sh`, so it is never stale. Find the ≤5 files your command touches and open ONLY those. A `grep -r`/`rg` across all of `lib/` was costing 200-400k input tokens on jobs that changed one widget — it is allowed ONLY when a map lookup genuinely fails, and you must say so in the build log.

2. **A debug pass is EVIDENCE, not habit.** `_dev_auto_debug_trg` creates a "Debug pass — verify & fix #N" twin only when qa_status='failed', a linked dev_journey_runs row came back red, or Om explicitly asked (dev_cmd_request_debug). QA passed = done, debug_status='not_needed', no twin. Never re-enable blanket twinning: measured at the time, 17 of 92 rows were twins burning 25% of ALL tokens spent.

3. **Routing is three lanes, not one.** `_route_detect` returns (route, area, size_class, reason): haiku for <400-char single-file jobs, sonnet under 2000 chars with no schema/migration/payment/auth marker, opus only for genuinely multi-system work. Keep `opus_markers` narrow — it once contained 'rpc'/'engine'/'pipeline'/'end-to-end'/'realtime', which matched 91 of 92 specs and forced everything to Opus. Every row stores `route_reason`, rendered verbatim on the command detail screen so a misroute is visible.

4. **Standard effort is the default.** `_dev_effort_for()` returns 'standard'; the backend escalates to 'high' by itself only on a retry, on size_class='xlarge', or when the spec literally says "effort: high". Do not silently work harder than the row asked for.

5. **Batch the small stuff.** `devcmd.sh claim_batch <agent> [routes] [area] [max]` → `dev_cmd_claim_batch` claims up to worker_pool.batch_max SMALL commands from the SAME area: one worker boot, one repo read, one deploy-lane pass. Finish every row with its own complete/fail — a failing sub-item is failed alone and never sinks its siblings.


## PROJECT · workflow  (priority 60, v2)

mediBO Dev Queue runner loop: check switch → claim → build → deploy → verify → record → next. Never ask, never idle, never leave a row building.

1. Switch: `devcmd.sh rpc dev_ctl_get` → `.desired_state.workflow`. "off" → wait ~20s and re-check, claim nothing. Re-check between commands so Om's Stop lands after the current command, never mid-build.
2. Claim: `devcmd.sh claim <worker-id> <routes-csv> [prefer_area]`. Read the lane FRESH before every claim from `~/mediBO-runner/.effective_lane_$(tmux display-message -p '#S')`, falling back to $LANE. Pass the area you just finished as the third arg — warm affinity hands you same-area work.
3. Standing lessons: the moment you own the row run `devcmd.sh lessons_get <area>` and treat every lesson as a HARD constraint. When a retry resolves a non-obvious failure, record it with `devcmd.sh lessons_add "<title>" "<lesson>" <area> <id>` (never secrets). Cite the lesson id when it saved you.
4. Thin spec: if route != 'fast' and length(spec) < `enrich_min_chars`, spend 60–90s writing an enriched plan (exact files, RPCs, acceptance bullets) and save it with `devcmd.sh enrich <id> <file>` BEFORE coding.
5. Media: if `messages[]` carry images/attachments, run `devcmd.sh thread <id>` and Read every "OPEN: <path>" file BEFORE writing code. Reply media lives on the MESSAGES, not the row's own `images`.
6. Follow-ups: `is_followup:true` means the command already completed and Om replied — work ONLY `followup[]` as a delta on the existing result, treating `focus` as your instruction. Never re-run the original spec from scratch.
7. Mid-build steering: `medibo-bridge.service` injects Om's replies live as `[Om — live reply on building #<id>]`. Act on it now, same command.

All guarded RPCs (dev_cmd_*, deploy_*, rg_*, dev_ctl_*) go through `~/mediBO-runner/devcmd.sh` — it carries the service_role key. Never use MCP for these; MCP has no JWT and the guard rejects it.


## PROJECT · runner_status  (priority 62, v2)

## 2. STATUS DISCIPLINE (every row, every time)
- Claim ONLY via dev_cmd_claim (SKIP LOCKED). Never SELECT+UPDATE manually.
- Heartbeat via dev_cmd_heartbeat every 60s with log tail + tokens. A silent
  runner is treated as crashed at 15 min — do not go silent.
- ETA (CHANGE #68): estimate total build seconds right after reading the spec;
  send eta_total_s + eta_left_s on the FIRST heartbeat and honest re-estimates of
  eta_left_s on every beat (it shrinks). On any problem, set eta_note to a plain
  one-liner and grow eta_left_s/eta_total_s; clear the note when resolved. Never
  fake a countdown from elapsed time.
- Finish EVERY command with exactly one of: dev_cmd_complete / dev_cmd_fail /
  dev_cmd_ask. A row left in 'building' is a bug you caused.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Status discipline — every row, every time.

- Claim ONLY via `dev_cmd_claim` (SKIP LOCKED). Never SELECT+UPDATE manually.
- Your FIRST heartbeat becomes the command's title: write it as `building #<id>: <clean short title of what you are building>` — the backend derives the title from that line. Not "investigating", not "deploying".
- Heartbeat every 60s with a log tail + tokens. A silent runner is treated as crashed at 15 min. NOTE: the wrapper reads arg 2 as a FILE PATH (`jq -Rs < file`) — write the tail to a temp file first; a raw string errors "No such file".
- ETA: estimate total build seconds right after reading the spec. Send `eta_total_s` + `eta_left_s` on the FIRST heartbeat (wrapper positional args 8/9/10) and re-estimate `eta_left_s` from what is ACTUALLY LEFT on every beat — never fake a countdown from elapsed time; it should shrink. The moment a problem appears (failing test, broken RPC, retry, rebase conflict) set `eta_note` to a plain one-liner ("fixing 2 failing tests, +3 min") and ADD that time to eta_left_s/eta_total_s. Clear the note once resolved.
- Tokens: `medibo-bridge.service` reports tokens live while a command builds. Only if the bridge is down run `report_session_tokens.sh <id> <the row's exact started_at, verbatim from the DB incl. microseconds+offset>` — a mismatched start string makes a NEW state key and DOUBLE-COUNTS. Never complete with 0 tokens.
- Finish EVERY command with exactly one of `dev_cmd_complete` / `dev_cmd_fail` / `dev_cmd_ask`. A row left in 'building' is a bug you caused.



## PROJECT · runner_build  (priority 63, v1)

## 4. BUILD RULES
- Max-backend: logic, strings, labels, formatting live in Supabase.
  Flutter renders payloads verbatim. If you write a display string in Dart,
  you are wrong — move it to the backend.
- Backend AND frontend both belong to you. Never output "paste this SQL" —
  run it. Never output "add this to Flutter" — write it.
- All money in INR. All timestamps IST for display.
- Never touch test/protected/ tests to make them pass. Fix the code.
- Never edit another agent's in-flight branch. Your branch, your command only.



## PROJECT · runner_failure  (priority 64, v2)

## 6. FAILURE RULES
- Any error: attempt reasonable fix ONCE within the command. If still broken:
  dev_cmd_fail with the full error. Auto-retry is handled by the system —
  do not loop yourself.
- NEVER mark complete with red tests, failed rg_check, or unverified deploy.
- NEVER fabricate results, deploy numbers, or screenshots.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Failure rules.

- Any error: attempt ONE reasonable fix inside the command. Still broken → `dev_cmd_fail` with the FULL error. Auto-retry is handled by the system — never loop yourself.
- NEVER mark complete with red tests, a failed `rg_check`, or an unverified deploy.
- NEVER fabricate results, deploy numbers, or screenshots.
- The ONLY thing you may hand back is `dev_cmd_ask` for the destructive list (dropping tables/columns holding data, deleting user data, weakening auth/RLS, payment config). After asking, IMMEDIATELY claim the next command — never idle.
- Never touch `test/protected/` tests to make them pass. Fix the code.
- Never edit another agent's or worker's in-flight branch.



## PROJECT · runner_forbidden  (priority 65, v1)

## 7. FORBIDDEN — INSTANT VIOLATIONS
✗ Asking the human anything except via dev_cmd_ask
✗ Idling/waiting when pending commands exist
✗ Merging to main while deploy lock is held by another agent
✗ Reusing or guessing a change number
✗ Hardcoding display strings in Flutter
✗ Leaving a row in 'building' at exit
✗ Skipping heartbeat, tests, rg_check, or live verification



## PROJECT · runner_recording  (priority 66, v2)

## 5. RECORDING (the registry is the memory)
- result_summary FORMAT — Om's rule, mandatory every time:
  - Bullet points only. Each bullet = **Title** — short description.
  - Title and description clearly separate.
  - MAX 10 lines. Each line MAX 5 words. Whole result MAX 50 words.
  - No paragraphs, no walls of text. Keep the deploy #, tests pass/fail,
    and decisions count as their own short bullets.
  - Example:
    • Change no — CHANGE #707 live.
    • Built — result banner + pill.
    • Backend — title auto-derived server-side.
    • Tests — protected 283 green.
    • Decisions — 2 logged.
- Capture 2–3 screenshots of changed screens → dev-cmd-proofs bucket.
- Before building: read the spec fully + check dev_commands for related
  completed rows so you never undo a previous command's work.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Recording — the registry is the memory.

`result_summary` FORMAT (mandatory every time):
- Bullet points only. Each bullet = **Title** — short description, clearly separated.
- MAX 10 lines. Each line MAX 5 words. Whole result MAX 50 words. No paragraphs.
- Keep the deploy #, tests pass/fail and decisions count as their own short bullets.
- Example: • Change no — CHANGE #707 live. • Built — result banner + pill. • Backend — title auto-derived server-side. • Tests — protected 283 green. • Decisions — 2 logged.

Also: capture 2–3 screenshots of the changed screens into the `dev-cmd-proofs` bucket (`~/mediBO-runner/shot.sh <url> <out.png>`), state the exact click path, and BEFORE building read the spec fully plus related completed rows (`dev_cmd_list '{"p_status":"completed","p_limit":500}'`) so you never undo a previous command's work.

`kind='gcp'` commands additionally write `p_plain_summary` (2–4 non-technical sentences) and put every copyable follow-up in `p_result_actions`.



## PROJECT · runner_solve  (priority 67, v1)

## 8. SOLVE, DON'T FLAG
- You NEVER report a problem and stop. Finding an issue = you fix it
  in the same command, then record what you fixed in result_summary.
- "Flagged for review", "needs manual attention", "please check",
  "recommend Om looks at" — these phrases are FORBIDDEN outputs.
- Blockers you hit (missing column, broken RPC, failing build, stale
  data, config gap) are part of the job: repair them, log the repair,
  continue. The human gives zero manual input.
- The ONLY thing you may hand back is a dev_cmd_ask for the destructive
  list in Rule 1. Everything else you solve yourself.



## PROJECT · frontend_wiring  (priority 68, v2)

## 11. FRONTEND IS THE FINISH LINE (100% BACKEND + MANDATORY FRONTEND WIRING)

The app is 100% backend-driven: every piece of logic, computation,
string, label, format, decision, and state lives in the BACKEND.
The frontend has exactly TWO permissions: REQUEST the backend and
RENDER what it returns. Nothing else. A display string written in
Dart, a calculation done in Flutter, a hardcoded label — all wrong;
move it to the backend.

But backend alone is HALF a feature. A feature Om cannot see and
tap in the deployed app DOES NOT EXIST. Multiple times backend was
built and the frontend was forgotten or left unwired — that is a
FAILED command, even if every RPC works.

MANDATORY for every build / change / update:
1. GAP CHECK FIRST: before wiring anything, check whether the
   backend for it exists. Any logic currently missing, or any
   logic sitting in the frontend, is a gap — BUILD THE BACKEND
   FIRST (tables, RPCs, strings, rules), then wire.
2. FRONTEND WIRING IS COMPULSORY: every backend feature you build
   or change MUST ship in the SAME command with its frontend:
   a visible, reachable entry point (menu item, button, chip,
   card, or screen), wired to the new RPCs, rendering their
   payloads verbatim.
3. REACHABILITY PROOF: after deploy, verify on the LIVE site that
   a super-admin (or the right role) can actually navigate to and
   use the change. Screenshot it. State the exact click path in
   the result. "Deployed but not visible/reachable" = incomplete
   = do NOT mark complete; fix the wiring first.
4. NO ORPHANS EITHER WAY: no backend without frontend access; no
   frontend without backend logic. Both, always, in one command.

Definition of done = backend built + frontend wired + deployed +
reachable + click path reported + screenshot proof.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Frontend is the finish line. Backend alone is HALF a feature — a feature Om cannot see and tap in the deployed app DOES NOT EXIST. Backend built with the frontend forgotten or unwired is a FAILED command, even if every RPC works.

Mandatory for every build/change/update:
1. GAP CHECK FIRST — does the backend exist? Logic missing, or logic sitting in the frontend, is a gap. Build the backend first, then wire.
2. FRONTEND WIRING IS COMPULSORY — every backend feature ships in the SAME command with a visible, reachable entry point (menu item, button, chip, card, screen) wired to the new RPCs, rendering payloads verbatim.
3. REACHABILITY PROOF — after deploy, verify on the LIVE site that the right role can navigate to and use the change. Screenshot it. State the exact click path in the result. "Deployed but not visible/reachable" = incomplete; fix the wiring before completing.
4. NO ORPHANS EITHER WAY — no backend without frontend access, no frontend without backend logic. Both, always, in one command.

Definition of done = backend built + frontend wired + deployed + reachable + click path reported + screenshot proof.



## PROJECT · deploy  (priority 70, v3)

## Deploy Rules
- NEVER deploy anything to Netlify. Netlify is permanently abandoned.
- NEVER use netlify deploy or any netlify CLI command.
- Deploy = `bash ~/deploy.sh` — ONE command, always. It builds Flutter, fingerprints the
  bundle, then does ONE `npx wrangler pages deploy build/web` (Direct Upload to Cloudflare
  Pages project "medibo", branch "main"). This bypasses the Cloudflare git-build queue
  that was causing 30+ min delays. Live in ~30s after upload.
- `git push` runs in the BACKGROUND after wrangler succeeds — it is history/rollback only
  and NEVER gates the deploy. Do NOT wait on it. Do NOT add a second deploy step.
- Token lives in ~/.medibo/cf.env (chmod 600, never committed). deploy.sh sources it.
- NEVER add a second `wrangler pages deploy` call. Exactly one per run.

## After every code change:
Run ~/deploy.sh — does `flutter clean` then build + wrangler Direct Upload → live in ~3min on medibo.in.
NEVER skip `flutter clean`: skipping it produces corrupt dart2js bundles that boot-hang even with identical source (proven 2026-07-03).

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Deploy = `bash ~/deploy.sh <N>` — ONE command, always. `~/deploy.sh` is a thin wrapper (CHANGE #583); the real script is versioned at `~/mediBO/scripts/deploy.sh` so deploy logic ships with the code it deploys. It does `flutter clean` → build → fingerprints the bundle → ONE `npx wrangler pages deploy build/web` (Direct Upload to Cloudflare Pages project "medibo", branch "main"), bypassing the Cloudflare git-build queue that caused 30+ min delays. Live in ~30s after upload.

ABSOLUTES:
- NEVER deploy to Netlify. Netlify is permanently abandoned. No netlify CLI command, ever.
- NEVER add a second `wrangler pages deploy` call. Exactly one per run.
- NEVER skip `flutter clean` — skipping it produces corrupt dart2js bundles that boot-hang even with identical source (proven 2026-07-03).
- `git push` runs in the BACKGROUND after wrangler succeeds — history/rollback only. It NEVER gates the deploy. Do not wait on it, do not add a second deploy step.
- The Cloudflare token lives in `~/.medibo/cf.env` (chmod 600, never committed); deploy.sh sources it.
- There is no local preview step. Every change goes straight to production via deploy.sh.

Built-in guards you should not fight: a pull-first guard (never build/commit/push on a stale local, CHANGE #424); auto-increment of the CHANGE # from web/version.json when no N is passed (CHANGE #57 fallback); a bundle-size assert (>1.5 MB or it aborts as corrupt); version.json + `<meta name="build-commit">` stamping; and a per-edge-node retry when polling https://medibo.in/version.json (CHANGE #604), because version.json propagates per node.



## PROJECT · deploy_lane  (priority 75, v5)

## 3. DEPLOY LANE — IT IS A MERGE QUEUE (CHANGE #324)

You do NOT take the deploy lock. You push a branch and leave; ONE merge worker
(`medibo-merge.service`, `~/mediBO-runner/merge_worker.sh`) batches everything
waiting, runs the FULL protected suite ONCE on the merged tree and deploys ONCE.
Ten commands become one test run and one deploy.

Why it changed: the lane was a mutex held across test + build + deploy + verify
with a 25-minute TTL, and each command claimed it two or three times (#309 took
changes 820/821/823; #312 took 822/824; #307 took 819/825; #319 took 827/828).
Five runners generated fifteen queue slots, so a 20-minute build took over an
hour — of queueing, not building.

Your whole interaction with the lane:
1. `~/mediBO-runner/spec_rebase.sh <branch> &` the moment you start coding —
   speculative rebase onto origin/main WHILE you work, never inside a lock.
   `spec_rebase.sh --stop` before you push.
2. `bash scripts/affected_tests.sh` — only the tests your change can break (its
   own `*_test.dart` plus the protected tests that reference the files you
   changed). The full 573 run once, on the batch. It falls back to the whole
   protected suite when it cannot tell what a change touches.
3. Schema changed? `devcmd.sh rebaseline` then `devcmd.sh rgcheck` = `true`,
   BEFORE you push. The merge worker will not fix a red guard for you.
4. `git branch -f <branch> HEAD` — every runner shares ONE checkout and the merge worker's worktree is cut from the same .git, so a local branch is already visible to it. Nothing to push: GitHub's key is not authorised on this box and `origin` is history only.
5. `devcmd.sh queue_push <cmd-id> <agent> "<title>" <branch> <commit>` →
   `entry_id`. Then go straight back to building.
6. `devcmd.sh queue_wait <entry_id> 1800` only when you need the change number
   for `dev_cmd_complete`. `evicted` means your branch broke the batch: fix it,
   push, `queue_push` again.
7. `devcmd.sh queue_status` shows the lane any time — the same payload the app
   draws at Dev Queue → Cron health → Deploy lane.

ONE CLAIM PER COMMAND (enforced by a partial unique index on `deploy_queue`).
A design-QA fix, a route marker and a promote go on the SAME branch and re-use
the SAME queue slot — `queue_push` updates the entry the command already holds
instead of taking a second one.

The lane is held only for merge + deploy: 5-minute TTL, target hold under 60s,
never across a test or a build. The merge worker works in its OWN git worktree
(`~/medibo-merge`, `MEDIBO_REPO`), never in the `~/mediBO` checkout five runners
are editing. A red suite is BISECTED — the offending branch is evicted and the
rest of the batch still ships. Nothing deploys unverified: full protected suite
+ `verify_live.sh` before `deployed_at` is ever stamped.

Instrumentation: `deploy_lock_release` and `merge_batch_finish` stamp
`deployed_at` (the old code only stamped it when `p_status='deployed'` while
every caller passed `'success'`, so all 177 rows read NULL and hold time was
unmeasurable). Every claim records `wait_s` (queued → batched) vs `hold_s` (lock
held), so you can see whether time goes to queueing or building.
`deploy_lane_sweep()` rides the cron dispatcher, auto-expires any claim silent
past its TTL, frees an orphaned lock, requeues a dead batch and raises an
`rg_alerts` row.

Persistent build cache: `~/mediBO-runner/cache.env` pins `PUB_CACHE`,
`GRADLE_USER_HOME`, `FLUTTER_ROOT` and the Dart cache outside the repo, so the
mandatory `flutter clean` cannot cold-start them. `scripts/warm_cache.sh` warms
them after a VM restart.

Legacy fallback ONLY when `queue_status` reports `mode_label: "MUTEX (legacy)"`
(merge_queue.enabled = false): deploy_lock_try → rebase → protected suite →
deploy_claim_number → stamp version.json → `bash ~/deploy.sh <N>` →
`verify_live.sh` → deploy_lock_release, with a short TTL.


## PROJECT · db_lane  (priority 76, v1)

## 15. DB WORK LANE (permanent — CHANGE #301)

The 1 GB instance does not choke on one slow query — it chokes when several
agents run HEAVY database work in the same moment (23 Aug 12:53–13:43 UTC: 40
statement timeouts, cron reporting "job startup timeout", trivial SETs taking
15 s, a manual restart). So CLASSIFY every DB step before you run it and take
the matching lane. Ordinary reads and small writes take NO lock and stay fully
parallel; coding, `flutter test`, `flutter build` and the deploy NEVER take one.

- **exclusive (1 slot)** — DDL/migration, a bulk UPDATE/INSERT/DELETE over
  ~20k rows, VACUUM, an index build. Excludes every other lane.
- **heavy_read (2 slots)** — a scan or audit over a big table
  (`whatsapp_messages` history, `"MEDICINE"`).
- **no lock** — everything else. Do not take one "to be safe": that is exactly
  how a parallel fleet becomes a queue.

Protocol, the deploy lane's shape:
1. `devcmd.sh dblock <agent> <exclusive|heavy_read> "<title>" [ttl] [cmd_id]`.
   `ok:false reason=busy` → wait `retry_after_seconds` (45 s) and retry, and
   keep coding/testing/building meanwhile — only this one step waits.
2. Run ONLY the heavy step. Never hold the lock across a build, a deploy or a
   think. Locks self-expire in 10 min and the expiry is alerted to `rg_alerts`.
3. `devcmd.sh dbunlock <token>` the moment it is done.
`devcmd.sh dbstatus` prints the lane (`db_lock_status()`).

Session guardrails — `devcmd.sh dbguard`, or `select db_session_guard();` in a
psql/management session, before any heavy DB work: statement_timeout 55 s,
lock_timeout 5 s, idle_in_transaction_session_timeout 30 s. Bulk writes run in
batches of at most 20 000 rows, each batch its own transaction — never one giant
transaction. `call db_bulk_batch('<sql with one %s where the batch size goes>')`
does the batching and the per-batch COMMIT for you.

Heavy scheduled audits and any 30-day log scan belong in the 21:00–02:00 UTC
window (02:30–07:30 IST) unless the row explicitly says urgent. Never add a cron
job on a bare `* * * * *` or `*/N` schedule — register a row in `cron_task` and
let the one dispatcher (CHANGE #273) run it.

The watchdog `db_watchdog_tick()` rides that dispatcher every minute and raises
`rg_alerts` when connections pass 45 of 60, a transaction stays open past 2 min,
or more than 10 statement timeouts land inside 5 min. Om reads it at
Dev Queue → Cron health → **Database lane**.


## PROJECT · deploy_traps  (priority 78, v1)

Deploy traps — hours lost to each of these at least once. Read before diagnosing a "broken" deploy.

- **Dead shell vs live shell.** `lib/screens/admin/admin_shell.dart` is a legacy surface; the live shell is `lib/screens/home_shell.dart` (it imports admin_shell for the wide-viewport link row only). Editing the admin shell and seeing no change on a phone is this trap — a phone had no way into that row at all. Wire new admin entry points through `home_shell.dart` / `admin_nav_entries.dart`.
- **render_verify.js can read stale/misleading state.** It self-loads medibo.in headless and reads `#medibo-render-log`, but a cached page or a not-yet-repainted key makes it look like a failure that is not one. `scripts/verify_live.sh` is the REAL signal — it asserts the fingerprinted bundle is 200 and full-size, then version.json, then the render-log.
- **Self-waiter noise (exit 144 class).** Background/self-waiting steps in the deploy chain can exit non-zero without the deploy having failed. Judge the deploy by verify_live.sh's exit code (0 verified / 1 broken / 2 deployed-but-unconfirmed), not by a stray non-zero from a helper.
- **Commit mismatch is normal, briefly.** deploy.sh amends the git commit with the fingerprinted artifacts AFTER building, and version.json propagates per edge node. A mismatch in the first seconds, or on one node, is propagation — retry (the script already polls with a cache-buster) instead of redeploying.
- **A partial bundle response is not a broken build.** Immediately after a deploy an edge node can serve a truncated body (#601 read 71,561 b for a 7,873,501 b bundle). verify_live.sh retries 6×; a verifier that fails on healthy deploys trains you to ignore it.
- **Exit 2 is not failure.** It means the deploy landed but no browser has visited yet. Self-load with render_verify.js and re-run — never end a task saying "the render log is stale / needs a real visit".


## PROJECT · design  (priority 80, v3)

## 12. DESIGN CONTRACT (permanent — CHANGE #66)

The app is styled 100% from backend design tokens. `ui_boot().design` →
`Ds.*` (lib/design_tokens.dart) → `buildTheme()`. Change a token via
`ui_design_set(patch)` and the WHOLE app recolours on next boot with ZERO code
change — no deploy. `ui_design_get()` reads current tokens.

Every screen build or change MUST follow **DESIGN.md** (repo root) and use the
tokens. Hardcoded style literals in a screen are a FAILED command:
- NO `Color(0x…)` — use `Ds.c.*` (brand, bg, surface, text, textSecondary,
  divider, success/warning/danger/info + `*Soft` tints).
- NO `fontSize:` / raw `TextStyle` sizes — use `Ds.t.*` (display/title/subtitle/
  body/caption) or the theme text slots.
- NO bare numeric `EdgeInsets`/`SizedBox`/`BorderRadius`/`BoxShadow` — use
  `Ds.space.*`, `Ds.r.r*`, `Ds.elevation.e1/e2`.
- One `Ds.c.brand` primary action per screen; red only destructive; ≤3 hues.

Only `lib/design_tokens.dart` and `lib/theme.dart` may hold style literals
(they DEFINE the tokens). The literal gate `test/protected/design_literal_gate_test.dart`
runs before every deploy: a NEW literal in a screen, or an increase over a
file's frozen baseline, FAILS the build. Baselines ratchet DOWN only — every
polish batch lowers `test/protected/design_literal_baseline.json`, never raises
it. To legitimately reduce a baseline after migrating a file: run
`dart run tool/design_baseline.dart --write` and commit the new baseline.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

The app is styled 100% from backend design tokens: `ui_boot().design` → `Ds.*` (lib/design_tokens.dart) → `buildTheme()`. Change a token via `ui_design_set(patch)` and the WHOLE app recolours on next boot with ZERO code change and no deploy. `ui_design_get()` reads current tokens.

Hardcoded style literals in a screen are a FAILED command:
- NO `Color(0x…)` — use `Ds.c.*` (brand, bg, surface, text, textSecondary, divider, success/warning/danger/info + `*Soft` tints).
- NO `fontSize:` / raw `TextStyle` sizes — use `Ds.t.*` (display/title/subtitle/body/caption) or the theme text slots.
- NO bare numeric `EdgeInsets`/`SizedBox`/`BorderRadius`/`BoxShadow` — use `Ds.space.*`, `Ds.r.r*`, `Ds.elevation.e1/e2`.
- One `Ds.c.brand` primary action per screen; red only destructive; ≤3 hues.

Only `lib/design_tokens.dart` and `lib/theme.dart` may hold style literals — they DEFINE the tokens. The gate `test/protected/design_literal_gate_test.dart` runs before every deploy: a NEW literal in a screen, or an increase over that file's frozen baseline, FAILS the build. Baselines ratchet DOWN only — every polish batch lowers `test/protected/design_literal_baseline.json`, never raises it. After migrating a file, run `dart run tool/design_baseline.dart --write` and commit the new baseline. Follow DESIGN.md.



## PROJECT · design_system  (priority 82, v2)

## DESIGN SYSTEM (apply to all UI work)

Apply these rules automatically to every frontend/UI change in this Flutter web app — no reminder needed. Target visual language: 1mg / PharmEasy / Apollo Pharmacy — professional, clean, trusted Indian pharma.

### COLORS
- Primary brand green: `#1B7A43` — one dominant green, no rainbow palette
- Backgrounds: `#F5F6F8` page, `#FFFFFF` cards/surfaces
- Primary text: `#111827` — Secondary text / labels: `#6B7280`
- Borders / dividers: `#E5E7EB` (1 px, used sparingly)
- State colors — muted, not vivid:
  - Success / active: `#D1FAE5` bg · `#065F46` text
  - Pending / warning: `#FEF3C7` bg · `#92400E` text
  - Error / cancelled: `#FEE2E2` bg · `#991B1B` text
  - Info / neutral: `#EFF6FF` bg · `#1E40AF` text
- Never use purple gradients, neon accents, or decorative multi-color fills

### SPACING
- Scale: 4 · 8 · 12 · 16 · 24 · 32 px — no arbitrary values
- Generous whitespace inside cards and between sections; never cram content
- Group related items tightly (8–12 px gap); separate unrelated blocks (24–32 px)
- Card internal padding: 16–20 px; page horizontal padding: 16 px mobile, 24–32 px desktop

### TYPOGRAPHY
- Hierarchy (max 3 sizes per screen):
  - Screen / section titles: `FontWeight.w700`, ~20–22 px, `#111827`
  - Body / primary data: `FontWeight.w500`, ~15–16 px, `#111827`
  - Captions / labels / hints: `FontWeight.w400`, ~13 px, `#6B7280`
- Left-align all prose and labels; right-align all numbers, prices, quantities
- Never bold entire paragraphs; use weight contrast for emphasis only

### COMPONENTS
- **Cards**: `BorderRadius.circular(12–16)`, background `#FFFFFF`, border `1px #E5E7EB` only when needed, shadow `BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: Offset(0,2))`
- **Primary button**: filled `#1B7A43`, white label, radius 8–10 px, height 44–48 px
- **Secondary button**: outlined `#1B7A43` border + text, same size, no fill
- **Inputs / dropdowns**: light fill `#F5F6F8`, border `#E5E7EB`, focus border `#1B7A43`, radius 8 px, height 44–48 px, clear placeholder in `#9CA3AF`
- **Chips / badges**: small radius (20 px), muted state colors above, `FontWeight.w500` ~12 px
- **Dividers**: `#E5E7EB`, hairline (0.5–1 px); prefer whitespace over heavy lines

### TABLES & LISTS
- Columns on a strict grid — never ragged
- Consistent row height (48–56 px for data rows, 40 px for compact)
- Alternate rows with `#F9FAFB` zebra OR use 1 px `#E5E7EB` dividers — pick one, not both
- Numbers / prices: right-aligned, `₹` prefix, 2 decimal places max, `FontWeight.w600`
- Column headers: `#6B7280`, `FontWeight.w600`, ~13 px, uppercase or title-case — consistent

### RESPONSIVE
- Use `LayoutBuilder` / `MediaQuery` — proportional/flexible widths, never hard-coded pixel widths
- Test breakpoints: 360 px · 390 px · 414 px (mobile), 768 px (tablet), 1280 px+ (desktop)
- Text must never squish, truncate, or overflow while space remains — use `Flexible`/`Expanded`/`FittedBox` as needed
- Touch targets minimum 44×44 px on mobile

### RULES — ALWAYS
- No purple, no gradients on primary surfaces, no decorative icons as space-fillers
- No "AI slop" look: no oversized emoji in UI, no confetti illustrations, no generic card-with-icon grids
- Every screen must have clear visual hierarchy: one focal element, supporting data, then metadata
- Alignment is non-negotiable — every element must sit on the grid
- Prefer clarity and breathing room over information density

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Visual language target: 1mg / PharmEasy / Apollo Pharmacy — professional, clean, trusted Indian pharma. Apply automatically to every UI change.

COLORS — primary brand green `#1B7A43` (one dominant green, no rainbow palette). Backgrounds `#F5F6F8` page, `#FFFFFF` cards. Text `#111827` primary, `#6B7280` secondary. Borders `#E5E7EB` (1 px, sparingly). Muted state colors: success/active `#D1FAE5` bg + `#065F46` text; pending/warning `#FEF3C7` + `#92400E`; error/cancelled `#FEE2E2` + `#991B1B`; info `#EFF6FF` + `#1E40AF`. Never purple gradients, neon accents, or decorative multi-color fills.

SPACING — 4 · 8 · 12 · 16 · 24 · 32 px only, no arbitrary values. Related items 8–12 px apart, unrelated blocks 24–32 px. Card padding 16–20 px; page padding 16 px mobile, 24–32 px desktop.

TYPOGRAPHY — max 3 sizes per screen. Titles w700 ~20–22 px `#111827`; body/primary data w500 ~15–16 px; captions/labels w400 ~13 px `#6B7280`. Left-align prose, right-align numbers/prices/quantities. Never bold whole paragraphs.

COMPONENTS — cards radius 12–16, white, 1 px `#E5E7EB` only when needed, shadow black 6% blur 8 offset (0,2). Primary button filled `#1B7A43`, white label, radius 8–10, height 44–48. Secondary outlined, same size, no fill. Inputs/dropdowns fill `#F5F6F8`, border `#E5E7EB`, focus `#1B7A43`, radius 8, height 44–48, placeholder `#9CA3AF`. Chips radius 20, muted state colors, w500 ~12 px. Dividers hairline `#E5E7EB` — prefer whitespace over lines.

TABLES & LISTS — strict column grid, never ragged. Row height 48–56 px (40 compact). Zebra `#F9FAFB` OR 1 px dividers — pick one, not both. Numbers right-aligned, `₹` prefix, ≤2 decimals, w600. Headers `#6B7280` w600 ~13 px, consistent casing.

RESPONSIVE — `LayoutBuilder`/`MediaQuery`, proportional widths, never hard-coded pixel widths. Breakpoints 360/390/414 (mobile), 768 (tablet), 1280+ (desktop). Text must never squish or overflow while space remains — `Flexible`/`Expanded`/`FittedBox`. Touch targets ≥44×44.

ALWAYS — no "AI slop": no oversized emoji, no confetti illustrations, no generic card-with-icon grids, no decorative icons as space-fillers. One focal element per screen, then supporting data, then metadata. Alignment is non-negotiable.



## PROJECT · design_qa  (priority 84, v2)

### DESIGN QA GATE (runner — after ANY command that touches UI)
Before `dev_cmd_complete` on a UI command, self-review the changed screens
against this checklist; if any check fails, FIX and re-check before completing.
Write "Design QA: passed (N checks)" into result_summary.
1. Spacing rhythm — only 4/8/12/16/24/32/48; unrelated blocks ≥24 apart.
2. Colour discipline — one brand primary; red only destructive; ≤3 hues.
3. Hierarchy — ≤3 type sizes; a real title; captions in textSecondary.
4. Components — cards radius16+e1; primary button full-width ≥44; sheets>dialogs.
5. Touch — every tap target ≥44×44.
6. States — empty state has one-line guidance; loading is a skeleton not a bare
   spinner; errors show backend copy + Retry.
7. Tokens — zero new style literals (gate green); everything via Ds/theme.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Design QA gate — run before `dev_cmd_complete` on ANY command that touches UI. Self-review the changed screens; if a check fails, FIX and re-check before completing. Write "Design QA: passed (N checks)" into result_summary.

1. Spacing rhythm — only 4/8/12/16/24/32/48; unrelated blocks ≥24 apart.
2. Colour discipline — one brand primary; red only destructive; ≤3 hues.
3. Hierarchy — ≤3 type sizes; a real title; captions in textSecondary.
4. Components — cards radius16 + e1; primary button full-width ≥44; sheets over dialogs.
5. Touch — every tap target ≥44×44.
6. States — empty state has one-line guidance; loading is a skeleton, not a bare spinner; errors show backend copy + Retry.
7. Tokens — zero new style literals (gate green); everything via Ds/theme.



## PROJECT · verification  (priority 85, v3)

## HEADLESS SELF-VERIFICATION RULE (PERMANENT — overrides all prior habits)
- After every deploy, ~/deploy.sh runs `node ~/render_verify.js --keys boot_status` automatically.
- For feature-specific keys, run: `node ~/render_verify.js --keys key1,key2,...`
- render_verify.js loads medibo.in as admin (headless Chromium), reads #medibo-render-log from the DOM, and asserts build-hash match + all required keys.
- NEVER end a task with "render-log is stale / needs a real visit" — that is a FAILURE, not a pass. The script self-loads the page; stale render-log cannot happen.
- NEVER substitute a DB-count check or source-code check for actual render-log verification. DB check is ADDITIONAL only.
- If render_verify.js exits non-zero: fix the Flutter code and redeploy. Do not declare success.
There is no local preview step. Every change goes straight to production via deploy.sh.

## VERIFICATION RULE (mandatory)
Flutter web renders to canvas — automated browser tools (Puppeteer/CDP) CANNOT read Flutter UI. Never install Puppeteer or attempt browser-click verification for Flutter.

### Deploy verification (every deploy)
1. `curl https://medibo.in/version.json` → confirm commit matches just-built hash
2. For DB changes: Supabase MCP `execute_sql` confirming expected rows

### UI VERIFICATION (canvas app — replaces JS-grep PERMANENTLY)
NEVER grep the JS bundle to prove a widget rendered. String-in-bundle is NOT proof — it only proves the code compiled, not that the widget rendered.

After deploy, have the test user open the relevant screen. Then:

**Step 1 — confirm live build:**
```
curl https://medibo.in/version.json
```
Note the commit hash.

**Step 2 — read real render counts:**
```
curl https://medibo.in/render-log
```
Or via Supabase MCP:
```sql
SELECT build_hash, data FROM render_log WHERE id = 'singleton';
```

**Proof criteria:**
- `build` field matches the version.json commit → you're reading the live build
- The relevant count > 0 (e.g. `spn_buttons` > 0, `company_rows` matches expected supplier)
- If count = 0 or build hash doesn't match → the widget did NOT render — keep fixing

**After every UI feature deploy:** run the curl commands above. Do not report success until `build` matches and the relevant count confirms the widget rendered.

Visual verification = the USER checks the live site on their device using the matching test credential:
- admin change → test.admin@medibo.in / TestAdmin#26
- supplier change → test.sup1@medibo.in / TestSup1#26
- customer change → test.cust1@medibo.in / TestCust1#26

Report the commit hash and the matching test credential. Never install Puppeteer. Never attempt CDP/canvas clicking.

## VERIFICATION RULE (mandatory — never skip)
NEVER use CDP/Puppeteer/incognito automation — Flutter canvas is unreadable by browser tools.
NEVER report success from source code or JS bundle grep alone — string-in-bundle ≠ widget rendered.

After EVERY deploy, run the autonomous verifier FIRST:
```
bash scripts/verify_live.sh
```
- Exit 0 = VERIFIED (version.json matches + render-log shows boot_status=painted).
- Exit 1 = BROKEN (HTTP check failed — diagnose and redeploy before reporting anything).
- Exit 2 = DEPLOYED BUT UNCONFIRMED (deploy landed; no browser has visited yet). In this
  case report the commit hash + ask Om to open medibo.in — then re-run the script.

For UI feature verification also confirm the specific render count:
1. `curl https://medibo.in/render-log` — `build` must match commit AND relevant count > 0

If count = 0 → widget did NOT render → keep fixing.
This rule overrides everything else.

## LIVE VERIFICATION IS CLAUDE CODE'S JOB — NEVER OM'S
Claude Code MUST run `bash scripts/verify_live.sh` after every deploy and report the result.
NEVER say "please check the site", "please open medibo.in", or "let me know if it works".
The only time Om's eyes are needed is for subjective UI review (layout, colours) — not for
proving the app boots or a feature works. That proof comes from render-log.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Flutter web renders to canvas — Puppeteer/CDP CANNOT read Flutter UI. Never install Puppeteer, never attempt CDP/canvas clicking, never grep the JS bundle to prove a widget rendered. String-in-bundle proves the code compiled, NOT that the widget rendered.

Live verification is Claude Code's job, NEVER Om's. Never say "please check the site", "please open medibo.in", or "let me know if it works". Om's eyes are needed only for subjective UI review (layout, colours) — never to prove the app boots or a feature works.

After EVERY deploy, in order:
1. `bash scripts/verify_live.sh` — exit 0 = VERIFIED (fingerprinted bundle 200 + full size, version.json matches, render-log boot_status=painted). Exit 1 = BROKEN — diagnose and redeploy before reporting anything. Exit 2 = DEPLOYED BUT UNCONFIRMED — no browser has visited; run `node ~/render_verify.js --keys boot_status` to self-load, then re-run.
2. `curl https://medibo.in/version.json` — commit/change must match what you just built.
3. For a UI feature: `curl https://medibo.in/render-log` (or `SELECT build_hash, data FROM render_log WHERE id='singleton'`). The `build` field must match version.json AND the relevant count must be > 0 (e.g. `spn_buttons` > 0, `company_rows` matches the expected supplier). Count = 0 or hash mismatch → the widget did NOT render → keep fixing.
4. For DB changes, additionally confirm expected rows via Supabase `execute_sql`. A DB count is ADDITIONAL — never a substitute for the render-log check.

Feature-specific keys: `node ~/render_verify.js --keys key1,key2,…`.



## PROJECT · test_accounts  (priority 87, v1)

Live test credentials — report the commit hash plus the credential that matches the change, so a visual review uses the right role:

- admin change → test.admin@medibo.in / TestAdmin#26
- supplier change → test.sup1@medibo.in / TestSup1#26
- customer change → test.cust1@medibo.in / TestCust1#26

These exist for subjective visual review only. Functional proof always comes from verify_live.sh + the render-log, never from asking someone to look.


## PROJECT · proof_completion  (priority 88, v2)

## 14. PROOF-BASED COMPLETION (permanent — CHANGE #129, Bug-Loop Prevention)

Completion is EVIDENCE, never a claim. A command is done when it is proven done,
not when the runner says so. The backend enforces this gate inside
`dev_cmd_complete` when `worker_pool.bugloop.enforce=true`.

Non-negotiable for every UI-touching command:
1. **Journeys.** After deploy (to preview when the preview lane is live), run the
   command's area journeys (+ global) → `journey_report(cmd, results[])`. Every
   `required=true` journey for the area MUST pass. A journey only becomes
   `required=true` after it has passed GREEN TWICE — never on first sight, never
   by hand to make a red command go green.
2. **QA (L2).** A separate hostile QA agent tests the preview and files
   `qa_report(cmd, 'passed'|'failed', findings[])`. The gate needs `passed` or an
   explicit PIN-gated `qa_waive`. Failed → back to the builder (max 2 rounds),
   then `needs_input` with the findings summary. Skip QA only for
   docs-only / gcp / mutation commands (`qa_required=false`).
3. **Screenshot.** ≥1 screenshot of the changed screen in `dev-cmd-proofs`, plus
   the exact click path in `result_summary`. Backend without a reachable,
   proven frontend is a FAILED command (§11).
4. **Bugs become journeys.** Every `bug_report` finding creates a permanent
   linked journey; the fix cannot complete until that journey passes. This is
   how a class of bug is retired forever instead of one screenshot at a time.

The chip row on each command (`qa_chip`, `preview_chip`, `journey_chip`) and the
detail screen's QA & Journeys section render this proof verbatim from
`dev_cmd_list` / `dev_cmd_qa_detail`. "Report a bug" (Dev Queue header) and the
Journey Library screen (header map icon) are the Om-facing surfaces.

NEVER flip `bugloop.enforce=true` until the full chain (preview → journeys → QA →
promote) is rehearsed end-to-end on a harmless command — flipping it early blocks
every future completion.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Proof-based completion (CHANGE #129 — bug-loop prevention). Completion is EVIDENCE, never a claim; `dev_cmd_complete` enforces this when `worker_pool.bugloop.enforce=true`.

Non-negotiable for every UI-touching command:
1. **Journeys.** After deploy (to preview when the preview lane is live) run the command's area journeys plus global → `journey_report(cmd, results[])`. Every `required=true` journey for the area MUST pass. A journey only becomes required after passing GREEN TWICE — never on first sight, never by hand to turn a red command green.
2. **QA (L2).** A separate hostile QA agent tests the preview and files `qa_report(cmd, 'passed'|'failed', findings[])`. The gate needs `passed` or an explicit PIN-gated `qa_waive`. Failed → back to the builder (max 2 rounds), then `needs_input` with the findings summary. Skip QA only for docs-only / gcp / mutation commands (`qa_required=false`).
3. **Screenshot.** ≥1 screenshot of the changed screen in `dev-cmd-proofs`, plus the exact click path in `result_summary`.
4. **Bugs become journeys.** Every `bug_report` finding creates a permanent linked journey; the fix cannot complete until that journey passes — that retires a CLASS of bug instead of one screenshot at a time.

Surfaces: the chip row per command (`qa_chip`, `preview_chip`, `journey_chip`) and the detail screen's QA & Journeys section render this verbatim from `dev_cmd_list` / `dev_cmd_qa_detail`. Om-facing entries: "Report a bug" in the Dev Queue header and the Journey Library (header map icon).

NEVER flip `bugloop.enforce=true` until the full chain (preview → journeys → QA → promote) is rehearsed end-to-end on a harmless command — flipping it early blocks every future completion.



## PROJECT · protected_tests  (priority 90, v2)

## PROTECTED TEST SUITE (CHANGE #635 — never remove)
Before EVERY deploy, run `flutter test test/protected/` in addition to the
change's own focused test. A protected test may only be modified when the CHANGE
explicitly changes that protected behaviour — never to make an unrelated change
pass. New fragile flows get a new file here.

Current files and what they hold down:
- `recorder_policy_test.dart` — voice window lifecycle: Stop opens no new window,
  the sub-2s stop artifact is never submitted, silence is not an error toast.
- `barcode_count_test.dart` — scan/stage/commit: backend strings verbatim, tap
  zones, qty 0 keeps the item and writes nothing, Pack never crosses into the
  supplier ledger.
- `supplier_shop_state_test.dart` — fw_get_state: qty_label/status_label/
  status_tone rendered verbatim, count_locked (not a client-side OR) blocks entry.
- `pack_screen_test.dart` — pack_get_queue chips + can_mark_ready verbatim,
  pack_button (from pack_list_orders) verbatim, hold-to-undo's RPC contract.
- `product_detail_test.dart` — the product page is ONE RPC printed verbatim:
  headings come from the storefront_ui_label table (not Dart literals), absence
  is explicit (has_mrp/has_gst/has_supplier_label/my_history.has), ok:false
  renders the backend's not-found page instead of throwing.
- `company_notify_test.dart` — company page renders label/count_label verbatim
  and pages by offset while the BACKEND says has_more (appending never
  duplicates); company_not_found is an empty state; an out-of-stock card offers
  Notify, whose toast and subscribed state come only from the RPC; the
  back-in-stock strip reports exactly the ids it showed; and the PDP price is
  pricing.price_display — the same block every card reads.
- `home_sections_test.dart` — the home feed is one RPC rendered in payload
  order: unknown layouts and empty sections are skipped silently (forward
  compat), the green accent is located inside the title rather than guessed,
  and taps carry the backend's own key (category) / label (company search).
- `compact_card_test.dart` — the compact card computes nothing: price, struck
  MRP, ribbon and ADD label are backend strings, a ribbon appears only when the
  payload sent one, out-of-stock is can_add:false (never a stock number), and
  the grid extent stays derived from the card's own constants.

- `stock_update_form_test.dart` — the public /stock-update/<token> page renders
  items in payload order (fixture is deliberately non-alphabetical), draws the
  two buttons from buttons[] with still_oos LEFT / back_in_stock RIGHT and
  their own tones, keeps one answer per item, and submits
  [{product_id, back_in_stock}] for ANSWERED items only — an untouched item is
  omitted, never defaulted to "still out of stock". Expired renders the
  backend's copy instead of throwing.
- `inquiry_prestate_test.dart` — the auto-tick, on the ONE widget all three
  inquiry surfaces share: prestate 'Available' arrives pre-selected AND stays
  editable, prestate null arrives unselected, a submitted answer outranks the
  tick and a live tap outranks both, and items render in payload order (no
  client sort).
- `cart_unavailable_test.dart` — the cart's red state is the backend's flag:
  per-line unavailable/qty_locked are carried through untouched,
  unavailable_badge prints verbatim (never pluralised in Dart), the badge is
  absent at count 0, re-rendering after a removal clears both because the
  SERVER recomputed them, and CartOrderRefusal treats only
  error:'unavailable_in_cart' as that refusal, keeping its message verbatim.

The suite runs on the Dart VM in ~2s. Keep it that way: no network, no goldens,
no Supabase, no camera — mock RPC payloads inline. If a widget resists mocking,
extract its decisions into a pure class and test that.
(Set `RenderLog.flushEnabled = false` in setUpAll for any test that renders a
widget calling RenderLog.write — its 800 ms debounce is a real Timer and would
otherwise outlive the test and try to reach Supabase.)

---

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Protected test suite (CHANGE #635 — never remove). Before EVERY deploy run `flutter test test/protected/` in addition to the change's own focused test. A protected test may be modified ONLY when the CHANGE explicitly changes that protected behaviour — never to make an unrelated change pass. New fragile flows get a new file here.

What each file holds down:
- `recorder_policy_test.dart` — voice window lifecycle: Stop opens no new window, the sub-2s stop artifact is never submitted, silence is not an error toast.
- `barcode_count_test.dart` — scan/stage/commit: backend strings verbatim, tap zones, qty 0 keeps the item and writes nothing, Pack never crosses into the supplier ledger.
- `supplier_shop_state_test.dart` — fw_get_state: qty_label/status_label/status_tone rendered verbatim, count_locked (not a client-side OR) blocks entry.
- `pack_screen_test.dart` — pack_get_queue chips + can_mark_ready verbatim, pack_button (from pack_list_orders) verbatim, hold-to-undo's RPC contract.
- `product_detail_test.dart` — the product page is ONE RPC printed verbatim: headings come from the storefront_ui_label table (not Dart literals), absence is explicit (has_mrp/has_gst/has_supplier_label/my_history.has), ok:false renders the backend's not-found page instead of throwing.
- `company_notify_test.dart` — company page renders label/count_label verbatim and pages by offset while the BACKEND says has_more (appending never duplicates); company_not_found is an empty state; an out-of-stock card offers Notify, whose toast and subscribed state come only from the RPC; the back-in-stock strip reports exactly the ids it showed; the PDP price is pricing.price_display — the same block every card reads.
- `home_sections_test.dart` — the home feed is one RPC rendered in payload order: unknown layouts and empty sections are skipped silently (forward compat), the green accent is located inside the title rather than guessed, taps carry the backend's own key (category) / label (company search).
- `compact_card_test.dart` — the compact card computes nothing: price, struck MRP, ribbon and ADD label are backend strings, a ribbon appears only when the payload sent one, out-of-stock is can_add:false (never a stock number), the grid extent stays derived from the card's own constants.
- `stock_update_form_test.dart` — the public /stock-update/<token> page renders items in payload order (fixture is deliberately non-alphabetical), draws the two buttons from buttons[] with still_oos LEFT / back_in_stock RIGHT and their own tones, keeps one answer per item, and submits [{product_id, back_in_stock}] for ANSWERED items only — an untouched item is omitted, never defaulted to "still out of stock". Expired renders the backend's copy instead of throwing.
- `inquiry_prestate_test.dart` — the auto-tick on the ONE widget all three inquiry surfaces share: prestate 'Available' arrives pre-selected AND stays editable, prestate null arrives unselected, a submitted answer outranks the tick and a live tap outranks both, items render in payload order (no client sort).
- `cart_unavailable_test.dart` — the cart's red state is the backend's flag: per-line unavailable/qty_locked carried through untouched, unavailable_badge printed verbatim (never pluralised in Dart), absent at count 0, cleared on re-render because the SERVER recomputed them, and CartOrderRefusal treats only error:'unavailable_in_cart' as that refusal, keeping its message verbatim.
- `design_literal_gate_test.dart` — the style-literal baseline gate (see design).

The suite runs on the Dart VM in ~2s. Keep it that way: no network, no goldens, no Supabase, no camera — mock RPC payloads inline. If a widget resists mocking, extract its decisions into a pure class and test that. Set `RenderLog.flushEnabled = false` in setUpAll for any test rendering a widget that calls RenderLog.write — its 800 ms debounce is a real Timer that would otherwise outlive the test and try to reach Supabase.



## PROJECT · dart_imports  (priority 92, v2)

## DEFENSIVE IMPORT RULE (prevents dart2js static-init crashes)
NEVER add `import 'dart:html'`, `import 'dart:js'`, or any `dart:*` web-only library to files
that are imported by the widget tree (e.g. view_as_state.dart, app_state.dart, user_state.dart,
any model or notifier). These libraries cause static-initialization ordering crashes in
dart2js -O4 release builds, white-screening the entire app.

Only `main.dart` (the entry point) may import `dart:html` — it is loaded last.
If a feature needs localStorage/sessionStorage, use the `shared_preferences` package instead.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Defensive import rule — prevents dart2js static-init crashes.

NEVER add `import 'dart:html'`, `import 'dart:js'`, or any `dart:*` web-only library to a file that is imported by the widget tree (view_as_state.dart, app_state.dart, user_state.dart, any model or notifier). These cause static-initialization ordering crashes in dart2js -O4 release builds and white-screen the ENTIRE app.

Only `main.dart` (the entry point) may import `dart:html` — it loads last. If a feature needs localStorage/sessionStorage, use the `shared_preferences` package instead.



## PROJECT · boot_resilience  (priority 94, v2)

## BOOT RESILIENCE RULE (permanent)
main.dart MUST always wrap startup in `runZonedGuarded`. Supabase.initialize and every other
init step MUST be individually try/caught. `_AppRoot` MUST remain a StatefulWidget with a
hard 5-second boot timeout that forces HomeShell if auth never resolves. FlutterError.onError
MUST be set at boot. Never revert these patterns — a feature crash MUST NOT white-screen the app.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Boot resilience rule (permanent). `main.dart` MUST always wrap startup in `runZonedGuarded`. `Supabase.initialize` and every other init step MUST be individually try/caught. `_AppRoot` MUST remain a StatefulWidget with a hard 5-second boot timeout that forces HomeShell if auth never resolves. `FlutterError.onError` MUST be set at boot.

Never revert these patterns — a feature crash MUST NOT white-screen the app.



## PROJECT · gemini  (priority 96, v2)

## GEMINI RULE (ABSOLUTE)
Every AI/OCR feature uses ONLY gemini-3.5-flash on Vertex AI global endpoint (aiplatform.googleapis.com, locations/global, thinkingLevel='low', GCP_SA_KEY auth). NEVER gemini-2.5/2.0/1.5, NEVER generativelanguage.googleapis.com, NEVER API-key auth. Before writing any Gemini code, copy the exact pattern from the gemini-ocr edge function.

### GEMINI ENTITY IDENTITY RULE (never remove)
official_name = formal legal name of EXACTLY the entity on the card. NEVER substitute a parent, acquirer, group, or successor. Expanding the same entity's abbreviation is allowed (ALKEM→Alkem Laboratories Ltd.); replacing a distinct entity is forbidden (Aventis→Sanofi India Ltd. ✗, German Remedies→Zydus Lifesciences Ltd. ✗, Cipla Diagnostics→Cipla Ltd. ✗). When in doubt, keep visible_name verbatim as official_name with confidence=low.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

GEMINI RULE (absolute). Every AI/OCR feature uses ONLY `gemini-3.5-flash` on Vertex AI, global endpoint: `aiplatform.googleapis.com`, `locations/global`, `thinkingLevel='low'`, GCP_SA_KEY auth.

NEVER gemini-2.5 / 2.0 / 1.5. NEVER `generativelanguage.googleapis.com`. NEVER API-key auth. Before writing any Gemini code, copy the exact pattern from the `gemini-ocr` edge function.

ENTITY IDENTITY RULE (never remove): `official_name` = the formal legal name of EXACTLY the entity on the card. NEVER substitute a parent, acquirer, group or successor. Expanding the same entity's abbreviation is allowed (ALKEM → Alkem Laboratories Ltd.); replacing a distinct entity is forbidden (Aventis → Sanofi India Ltd. ✗, German Remedies → Zydus Lifesciences Ltd. ✗, Cipla Diagnostics → Cipla Ltd. ✗). When in doubt, keep `visible_name` verbatim as `official_name` with confidence=low.



## PROJECT · naming  (priority 98, v2)

## COMPANY NAMING RULE (ABSOLUTE)
Gemini never generates or normalizes company names — it extracts verbatim text only (`seen` field). The review modal pre-fills the editable name field with the verbatim seen text. Import stores whatever the admin leaves in the field (default = verbatim). No resolution, no fuzzy matching, no expansion in the import path.

## OCR NAMING RULE (ABSOLUTE, PERMANENT)
All OCR in mediBO returns VERBATIM text exactly as printed — never official names, never expansions, never corrections, never parent/group companies, never world knowledge. The review modal and stored records carry verbatim seen text only. Run scripts/test_ocr_verbatim.sh after every gemini-ocr change; deploy fails if it fails. NEVER remove this rule or the script.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

OCR NAMING RULE (absolute, permanent). All OCR in mediBO returns VERBATIM text exactly as printed — never official names, never expansions, never corrections, never parent/group companies, never world knowledge. The review modal and stored records carry verbatim seen text only. Run `scripts/test_ocr_verbatim.sh` after every gemini-ocr change; the deploy fails if it fails. Never remove this rule or that script.

COMPANY NAMING RULE (absolute). Gemini never generates or normalizes company names — it extracts verbatim text only (the `seen` field). The review modal pre-fills the editable name field with that verbatim text. Import stores whatever the admin leaves in the field (default = verbatim). No resolution, no fuzzy matching, no expansion anywhere in the import path.



## PROJECT · latency  (priority 100, v2)

Latency lessons — every one of these cost hours. Check them BEFORE proposing hardware.

- **Dirty-flag feedback loops.** When a flag marks rows as needing recompute, audit EVERY trigger that sets it. One trigger that re-dirties rows the recompute just cleaned turns a bounded job into a permanent loop that pins the DB. Fix the trigger, not the worker.
- **Scalar-helper-scan anti-pattern.** A per-row scalar helper called inside a SELECT re-scans a big table once per row. Resolve set-based in a CTE and JOIN the result. On `MEDICINE` (≈563 k rows) this is the difference between milliseconds and minutes.
- **MEDICINE visibility map / autovacuum.** The big `MEDICINE` table (quoted, uppercase) goes slow when its visibility map is stale — index-only scans stop being index-only. VACUUM (and healthy autovacuum settings for that table) is the fix; more compute is not.
- **Count caches exist — use them.** `medicine_count_cache` and `medicine_category_counts_cache` hold the counts. Never `count(*)` the 563 k-row table on a user path; read the cache and refresh it on a schedule/trigger.
- **~1 GB RAM constraint.** The database instance is small on purpose. Do NOT propose a Supabase compute upgrade as the fix for a slow query — every latency problem so far has been a query, an index, a trigger loop, or a stale visibility map. Fix the SQL.

- **Connection exhaustion is a real outage mode — max_connections is 60.** On 2026-08-18 the site served Cloudflare 520/522 for 29 minutes (02:00:27–02:29:27 UTC). Nothing crashed and Postgres never restarted: 35 of the 60 active pg_cron jobs were scheduled on minute 0 (15 on `* * * * *`, 10 on `*/5`, 4 on `*/10`, 3 on `*/15`, plus `*/2`, `*/30` and the hourly jobs — every bare step expression collides on minute 0). The burst plus the PostgREST/GoTrue/realtime/storage pools took every slot; Postgres logged "remaining connection slots are reserved for roles with the SUPERUSER attribute", Kong could not reach ANY upstream, and pg_cron recorded the per-minute jobs as `job startup timeout` for 19m30s. Fixed by phase-shifting the schedules (same frequency, different offsets — see migration `20260818023000_cron_stagger_outage_fix.sql`); worst-case simultaneous starts went 35 → ~20. **Never add a recurring cron job with a bare `*/N` schedule — always give it an offset (`7-59/10`).** Diagnose this with `cron.job_run_details` (look for `job startup timeout`) and `select count(*) from pg_stat_activity` vs `max_connections`; the management API's `execute_sql` times out too, so a total blackout across REST + auth + admin SQL means slot starvation, not a dead instance.
- **`rg_check` baselines cron schedules.** Changing any `cron.alter_job` schedule turns the guard red under `diffs.cron`. Verify the new schedules are what you intended, then `devcmd.sh rebaseline` → `rgcheck` true. That is expected, not a regression.


## PROJECT · vm_traps  (priority 102, v1)

VM traps — the environment, not the code.

- **Disk full breaks the Claude auto-update.** Symptoms look like a broken CLI or a mysterious install failure. Run `df -h` FIRST on any "claude is broken" symptom; free space, then retry.
- **`hash -r` before reinstalling.** After replacing a binary, bash's command hash still points at the old path and you "reinstall" into a stale lookup. `hash -r`, then verify with `which`/`--version`.
- **The session-list picker is not an error.** Launching into a session picker means it found multiple sessions, not that anything failed. Pick or pass the session explicitly.
- **Two supervisors share `runner-N` ids.** Never run the GCP and EC2 supervisors at once: both use agent ids `runner-1..N`, so the second box's workers adopt the first box's in-flight rows on resume. Migration is a SEQUENTIAL handoff — drain and stop one box before starting the other.
- **`active_host` gates the handoff.** `supervisor.sh` reads `worker_pool.active_host`; a non-designated host stays standby (no claim/spawn/heartbeat). A cutover = flip `active_host` AND stop the old box's supervisor AND its looping claude sessions — sessions claim independently of the supervisor.


## PROJECT · integrations  (priority 104, v1)

External integrations — the facts that stop key-hunting.

- **Google: separate keys, separate blast radius.** There are three distinct Google API keys plus a service account (SA) — a browser key, server-side keys, and the SA used for Vertex/Gemini (`GCP_SA_KEY`). One misconfigured key must never take out unrelated surfaces; that is exactly why map provider/key selection was centralised in `map_config_get()` → `lib/services/map_config.dart` (CHANGE #634). Nothing in Dart picks a provider, tile server, key, centre or zoom.
- **Keyless deep links keep working when the JS API dies.** `navDeeplinkTemplate` / `pointDeeplinkTemplate` open the Google Maps app directly and never touch the Maps JavaScript API — that is why Directions kept working while tiles were failing. Diagnose tiles and directions separately.
- **Silent OSM geocode fallback.** Geocoding can silently fall back to OSM/Nominatim and still return a plausible result. ALWAYS check the `source` field on the response before trusting coordinates or blaming the caller — a "wrong" pin is usually a fallback, not a bug in the screen.
- **Road distances come from the self-hosted OSRM only** — never Google Distance Matrix / Route Matrix.
- **CORS is required on any browser-invoked edge function.** An edge function called from the Flutter web app must answer the OPTIONS preflight and send the CORS headers, or it fails in the browser while working perfectly from curl. Copy the header block from an existing browser-invoked function.


## PROJECT · regression_guard  (priority 106, v1)

Regression guard — the schema safety net.

Run `rg_check()` (`devcmd.sh rgcheck` → must print `true`) after EVERY migration and before every `dev_cmd_complete`; the completion RPC itself raises if the guard is red. It compares the live schema/RPC surface against a stored baseline, so a dropped column or a silently changed function signature is caught in the same command that caused it.

`rg_baseline_all()` (`devcmd.sh rebaseline`) is ONLY run AFTER you have verified the new state is correct — re-baselining a red guard just blesses the regression. Order is: migrate → verify the new state is what you intended → rebaseline → rgcheck green → deploy.


## PROJECT · parallel_workers  (priority 108, v2)

## 13. PARALLEL WORKERS (permanent — CHANGE #74)

The VM runs a WORKER POOL, not a single builder. The supervisor
(`mediBO-runner/supervisor.sh`) is the orchestrator: every 20s it reads
`desired_state` + `worker_pool` config (`pool_get`/`pool_set`) + queue depth,
scales tmux worker sessions `claude-1..claude-N` (agents `runner-1..N`; slot 1
is the visible primary Om attaches to), and publishes a render-ready snapshot
via `pool_status_write` that the app draws verbatim (`dev_ctl_get().pool`).

Rules every worker follows, in order:
1. **Plan → lease → build.** Before editing anything, list the EXACT repo files
   you will create/edit and call `lease_try_all(command_id, worker_id, paths)`.
   All-or-nothing, race-safe. NEVER edit an unleased file.
2. **Conflict → next command, don't block.** `ok:false` → heartbeat a one-line
   note (`waiting: <file> leased by #x`), lease nothing, and immediately claim
   the NEXT pending command instead. Re-attempt the blocked one only when
   re-claimed. Mid-build new file → single-path `lease_try_all` first; conflict
   you can't route around → finish what you can, note it, `dev_cmd_fail`.
3. **Leases free themselves.** `complete`/`fail`/`ask`/`cancel`/watchdog and the
   `lease_sweep` cron all auto-release. Call nothing extra.
4. **Build semaphore.** At most `build_semaphore` (default 2) concurrent
   `flutter build` (flock `mediBO-runner/.build.sem`); coding is unlimited.
5. **Deploy lane stays serialized** (deploy lock). Batching: when the lane frees
   and ≥2 workers hold ready branches, merge in one lane pass → one CHANGE #;
   each completed row names the shared number.
6. **Backend-only command → skip the build.** Touched zero frontend files →
   no `flutter build`, deploy nothing, `complete` with `p_deploy_no NULL` and
   say so in `plain_summary`.
7. **One worker per command.** Never edit another worker's in-flight branch.

Guards (supervisor enforces): `billing_mode=max_subscription` AND Claude usage
≥ `quota_shrink_pct` → pool shrinks to 1 (`shrink_reason=quota`); loadavg >
`cpu_load_max` → shrink by one (`cpu`); `workflow=off` or frozen → 0 claims
(sessions may stay alive idle). Idle ≥ `idle_shutdown_min` with an empty queue →
VM powers off. The primary session is never killed while it is building.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

Parallel workers (CHANGE #74). The VM runs a WORKER POOL, not a single builder. `mediBO-runner/supervisor.sh` is the orchestrator: every 20s it reads `desired_state` + `worker_pool` config (`pool_get`/`pool_set`) + queue depth, scales tmux sessions `claude-1..claude-N` (agents `runner-1..N`; slot 1 is the visible primary Om attaches to), and publishes a render-ready snapshot via `pool_status_write` that the app draws verbatim (`dev_ctl_get().pool`).

Rules every worker follows, in order:
1. **Plan → lease → build.** Before editing anything, list the EXACT repo files you will create/edit and call `lease_try_all(command_id, worker_id, paths)`. All-or-nothing, race-safe. NEVER edit an unleased file.
2. **Conflict → next command, don't block.** `ok:false` → heartbeat a one-line note (`waiting: <file> leased by #x`), lease nothing, and immediately claim the NEXT pending command. Re-attempt the blocked one only when re-claimed. Mid-build new file → single-path `lease_try_all` first; a conflict you cannot route around → finish what you can, note it, `dev_cmd_fail`.
3. **Leases free themselves.** complete/fail/ask/cancel/watchdog and the `lease_sweep` cron all auto-release. Call nothing extra.
4. **Build semaphore.** At most `build_semaphore` concurrent `flutter build` (flock `mediBO-runner/.build.sem`); coding is unlimited.
5. **Deploy lane stays serialized** (deploy lock), with batching when ≥2 workers hold ready branches.
6. **Backend-only command → skip the build**, deploy nothing, complete with `p_deploy_no NULL`, say so in `plain_summary`.
7. **One worker per command.** Never edit another worker's in-flight branch.

Supervisor guards: `billing_mode=max_subscription` AND Claude usage ≥ `quota_shrink_pct` → pool shrinks to 1 (`shrink_reason=quota`); loadavg > `cpu_load_max` → shrink by one (`cpu`); `workflow=off` or frozen → 0 claims (sessions may stay alive idle). Idle ≥ `idle_shutdown_min` with an empty queue → the VM powers off. The primary session is never killed while it is building.



## PROJECT · gcp  (priority 110, v2)

## 10. GCP COMMANDS (kind='gcp')
- A claimed `kind='gcp'` row does NOT use the web deploy lane: no flutter build,
  no version.json, complete with `p_deploy_no NULL`.
- On runner start, `gcp_bootstrap.sh` activates gcloud from the Vault secret
  `GCP_SA_KEY`. If absent → capability OFF: any gcp command completes with a
  plain "Google setup pending" summary + copy-chip result_actions (the Cloud
  Shell one-liner, the secret name `GCP_SA_KEY`) and `dev_cmd_ask` so it resumes
  after Om saves the key and replies done. NEVER put key material in logs,
  results, or build_log; key files are chmod 600.
- Loop: goal → plan gcloud steps → PREFLIGHT with read-only calls (verify
  roles/APIs); missing → one-line plain_summary + result_actions [copy: exact
  grant/enable command] + `dev_cmd_ask`. Then run→read→fix→rerun until met.
  Destructive steps use the is_danger ask path (backend PIN-gates the "yes").
- PLAIN-LANGUAGE MANDATE: every gcp completion writes `p_plain_summary` (2-4
  short non-technical sentences: what was done, what it means, what's left) and
  puts any copyable follow-up (commands, names, links) in `p_result_actions`.
  Technical output stays in build_log only.
- Status: `gcp_status.sh` writes VM state/disk/IP/APIs/region via
  `dev_gcp_status_write` on boot + every 10 min (systemd timer). Billing is
  best-effort — no billing role → `billing:{available:false}`, no error spam.
- Backups: `gcp_backup.sh` (01:30 IST timer) pg_dumps the DB + git-bundles the
  repo to the private `db-backups` bucket, `backup_report()` each. Needs
  `SUPABASE_DB_URL` in the Vault; absent → one plain setup card, then auto-runs.
- Secrets hygiene: never dump env; key files 600; results/build_log never
  contain secret values. Preflight before every mutate. Freeze (`sec_freeze`)
  stops all claims/adds; unlock with PIN.

---
_Retained from previous agent_memory (extra runner-learned detail not present in CLAUDE.md):_

GCP commands (`kind='gcp'`). A claimed gcp row does NOT use the web deploy lane: no flutter build, no version.json, complete with `p_deploy_no NULL`.

On runner start `gcp_bootstrap.sh` activates gcloud from the Vault secret `GCP_SA_KEY`. If absent → capability OFF: any gcp command completes with a plain "Google setup pending" summary + copy-chip `result_actions` (the Cloud Shell one-liner, the secret name `GCP_SA_KEY`) and a `dev_cmd_ask` so it resumes after Om saves the key and replies done.

Loop: goal → plan gcloud steps → PREFLIGHT with read-only calls (verify roles/APIs); missing → one-line `plain_summary` + `result_actions` [copy: the exact grant/enable command] + `dev_cmd_ask`. Then run → read → fix → rerun until met. Destructive steps use the `is_danger` ask path (the backend PIN-gates the "yes").

PLAIN-LANGUAGE MANDATE: every gcp completion writes `p_plain_summary` (2–4 short non-technical sentences: what was done, what it means, what's left) and puts every copyable follow-up (commands, names, links) in `p_result_actions`. Technical output stays in `build_log` only.

Status: `gcp_status.sh` writes VM state/disk/IP/APIs/region via `dev_gcp_status_write` on boot and every 10 min (systemd timer). Billing is best-effort — no billing role → `billing:{available:false}`, no error spam. Backups: `gcp_backup.sh` (01:30 IST timer) pg_dumps the DB and git-bundles the repo to the private `db-backups` bucket, `backup_report()` each; it needs `SUPABASE_DB_URL` in the Vault — absent → one plain setup card, then it auto-runs.

SECRETS HYGIENE: never dump env; key files are chmod 600; results/build_log never contain secret values. Preflight before every mutate. `sec_freeze` stops all claims/adds; unlock with the PIN.



## PROJECT · playstore  (priority 112, v1)

Play Store / Android.

- Package name is `in.medibo.app` (`android/app/build.gradle.kts` → `applicationId`). It is permanent — changing it means a NEW listing, not an update.
- 16 KB page-size support is an open TODO: newer Android devices require native libs aligned to a 16 KB page size. Until the Flutter/NDK toolchain used for the release build produces 16 KB-aligned libs, expect a Play Console warning on upload — plan the toolchain bump rather than repackaging by hand.
- Upload certificate: the upload key/cert is fixed for this listing. Play App Signing re-signs with its own key, so the upload cert fingerprint you see in the console is NOT the app-signing fingerprint — read the right one before wiring any SHA-1/SHA-256 into a Google API restriction, or the API silently rejects the app.
- Android build state is tracked per command (`android_status`, `android_build_type`, `android_artifact_url`); a web-only command leaves them `not_requested`.


<!-- END agent_memory -->
