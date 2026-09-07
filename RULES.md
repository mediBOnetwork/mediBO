# mediBO — Portable Agent Rules (canonical, auto-generated)
# Source of truth: Supabase agent_memory. Edit in the mediBO app
# (Dev Queue -> Memory) or via the memory MCP server. Regenerated every
# session by memory_render.sh. This file is the OFFLINE git fallback: if both
# Supabase and the MCP server are down, agents still boot from this committed copy.

<!-- BEGIN agent_memory -->
<!-- AUTO-GENERATED from Supabase agent_memory. Edit rules in the mediBO
     Dev Queue → Memory screen, or via the MCP memory server. Do NOT hand-edit
     this block; it is rewritten on every session start. Target: generic -->

# Agent memory (generic) — 46 rules
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


## PROJECT · step_progress  (priority 61, v1)

## 17. STEP PROGRESS MUST TICK ITSELF (permanent — CHANGE #350)

The card's checklist is Om's only live answer to "where is this build?". #340 sat at "Step 0 of 7" with 550K tokens spent and a change already promoted: the agent worked the whole time and never called the step RPC, so the one thing Om could see was a lie.

1. **Mark it the moment it lands.** `devcmd.sh steps_set <ID> '["…","…"]' <branch>` before you code; `devcmd.sh step_done <ID> <n> <commit> "<what landed>"` the instant each step is on the branch — never a catch-up pass before `complete`.
2. **Re-planning REWRITES the list.** A hostile-QA round, a bigger spec, a dropped approach — call `steps_set` again with the plan you are ACTUALLY following. Same title at the same number keeps its done mark. Abandoning the plan at 0 while you work a different one is the failure this change ends.
3. **Derived ticks.** Every heartbeat `step_autotick.sh` reports the facts it can observe by itself (a commit touching `supabase/migrations/`, a commit touching `lib/**.dart`, a green test run, `queue_push`, the change going live) and `dev_cmd_step_autotick()` ticks whichever pending step each fact satisfies. The fact-to-step mapping is DATA in `dev_step_fact_rule` — a new detectable fact is one INSERT, not a deploy. It covers mechanical steps only; a decision or a QA fix is still yours to mark.
4. **Backstop.** `dev_cmd_watchdog()` compares tokens spent against steps reported. Checklist frozen past `worker_pool.steps_watchdog.stale_min` while at least `min_tokens` were spent => it writes a STEP SYNC nudge into the live session (the same channel Om replies ride, injected by `build_bridge.sh`) and sets `steps_stale_flagged`, which the card renders as "Steps not being reported — checklist may be stale ({age})". Any real tick — agent or derived — clears the flag immediately. Getting a nudge means the card has been lying for at least 12 minutes: sync it now.


## PROJECT · runner_status  (priority 62, v2)


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



## PROJECT · runner_context  (priority 66, v1)

## CONTEXT ECONOMY (CHANGE #1197)
The window is a budget, and re-reading is how it is wasted.
- Your prompt file carries the SPEC and the STATE only. The rules and the business context are in
  CLAUDE.md / RULES.md and are ALREADY in your context — never re-read them, and never open
  `standing_preamble.md`.
- `~/mediBO-runner/work/cmd-<id>.state.md` is written for you after every `steps_set`,
  `step_done`, `spec_done`, `log_decision` and `mig_note`. On ANY resume (compact, clear,
  restart, retry, auto-heal) that file — as a <=200-word brief, `devcmd.sh resume_brief <id>` —
  is all you are handed. Do not go back to the prompt file.
- A session past `worker_pool.context_compact_pct` (70%) is COMPACTED, not cleared; `/clear` is
  only the fallback when `/compact` fails. `devcmd.sh ctx` reads the window.
- Output you will not read still costs the whole window. Use `devcmd.sh tests` (one summary line
  + failures only), `logtail` (40 lines), `migs` (filenames), `cat` (refuses >300 lines),
  `rgcheck` (the diff table only). Never `bash -x` a devcmd call, and never `cat` a big file —
  `grep -n` and `sed -n <from>,<to>p` instead.
- An xlarge spec with more than 8 numbered items is SPLIT at add time into chained parts of at
  most 6. Write "single command" in a spec to opt out.


## PROJECT · runner_recording  (priority 66, v2)


Recording — the registry is the memory.

`result_summary` FORMAT (mandatory every time):
- Bullet points only. Each bullet = **Title** — short description, clearly separated.
- MAX 10 lines. Each line MAX 5 words. Whole result MAX 50 words. No paragraphs.
- Keep the deploy #, tests pass/fail and decisions count as their own short bullets.
- Example: • Change no — CHANGE #707 live. • Built — result banner + pill. • Backend — title auto-derived server-side. • Tests — protected 283 green. • Decisions — 2 logged.

Also: capture 2–3 screenshots of the changed screens into the `dev-cmd-proofs` bucket (`~/mediBO-runner/shot.sh <url> <out.png>`), state the exact click path, and BEFORE building read the spec fully plus related completed rows (`dev_cmd_list '{"p_status":"completed","p_limit":500}'`) so you never undo a previous command's work.

`kind='gcp'` commands additionally write `p_plain_summary` (2–4 non-technical sentences) and put every copyable follow-up in `p_result_actions`.



## PROJECT · runner_finish  (priority 67, v1)

## FINISHED MEANS EXIT (CHANGE #369)
Every heartbeat the harness asks `dev_cmd_finish_state(<ID>)`. When every condition is observed —
steps N/N, QA passed where required, required journeys green, screenshot proof in
`dev-cmd-proofs`, the change deployed and promoted, `rg_check` green, no open question — the
BACKEND completes the row itself and interrupts your turn.
- Mark the last step the MOMENT it lands: it is the trigger, not bookkeeping.
- `complete` returning `already: true` is SUCCESS. Do not retry, do not look for a bug.
- A turn interrupted right after everything landed is the feature working.
- `devcmd.sh finish_state <ID>` names what is still holding the row open, in the backend's words.
It cannot fire early: no step plan, an unanswered question, a pending QA verdict, a red journey,
no proof, no promoted deploy or a red `rg_check` all block it.


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


Frontend is the finish line. Backend alone is HALF a feature — a feature Om cannot see and tap in the deployed app DOES NOT EXIST. Backend built with the frontend forgotten or unwired is a FAILED command, even if every RPC works.

Mandatory for every build/change/update:
1. GAP CHECK FIRST — does the backend exist? Logic missing, or logic sitting in the frontend, is a gap. Build the backend first, then wire.
2. FRONTEND WIRING IS COMPULSORY — every backend feature ships in the SAME command with a visible, reachable entry point (menu item, button, chip, card, screen) wired to the new RPCs, rendering payloads verbatim.
3. REACHABILITY PROOF — after deploy, verify on the LIVE site that the right role can navigate to and use the change. Screenshot it. State the exact click path in the result. "Deployed but not visible/reachable" = incomplete; fix the wiring before completing.
4. NO ORPHANS EITHER WAY — no backend without frontend access, no frontend without backend logic. Both, always, in one command.

Definition of done = backend built + frontend wired + deployed + reachable + click path reported + screenshot proof.



## PROJECT · runner_completion  (priority 68, v1)

## COMPLETION INTEGRITY (CHANGE #571) — three rules that are no longer yours to get wrong
1. **A finished build always registers as finished.** `devcmd.sh complete` is two idempotent
   writes (`dev_cmd_complete_fast` + `dev_cmd_result_write`), spooled to disk and retried with
   backoff. `spooled:true` means the completion is ON DISK and every heartbeat replays it until
   it lands. Do NOT loop on `complete` and do NOT "fix" a timeout by failing the row.
   `already:true` is success.
2. **WAITING IS NOT FAILING.** Only a failing ARTIFACT — a red test, a broken build, a red
   `rg_check`, a QA verdict of failed — may fail a command. A lease you cannot get, a merge-queue
   eviction, an RPC timeout, a busy DB are WAIT states: `dev_cmd_fail` classifies the text
   (`dev_fail_rule`) and PARKS the row instead. Park deliberately with
   `devcmd.sh park <ID> <lease|merge|db|rpc> "<reason>"`. Land everything you CAN land first.
3. **THE SPEC IS A CHECKLIST, AND IT GATES THE FINISH.** Every enumerated spec becomes
   `dev_command_spec_item` rows. `devcmd.sh spec <ID>` shows them; an OPEN item blocks
   `dev_cmd_complete`. Close each as it lands (`spec_done <ID> <n> "<evidence>"`), drop it with a
   reason (`spec_drop`), or replace the derived list with your accurate one (`spec_set`).
   Silence is the one thing that is not allowed.


## PROJECT · deploy  (priority 70, v3)


Deploy = `bash ~/deploy.sh <N>` — ONE command, always. `~/deploy.sh` is a thin wrapper (CHANGE #583); the real script is versioned at `~/mediBO/scripts/deploy.sh` so deploy logic ships with the code it deploys. It does `flutter clean` → build → fingerprints the bundle → ONE `npx wrangler pages deploy build/web` (Direct Upload to Cloudflare Pages project "medibo", branch "main"), bypassing the Cloudflare git-build queue that caused 30+ min delays. Live in ~30s after upload.

ABSOLUTES:
- NEVER deploy to Netlify. Netlify is permanently abandoned. No netlify CLI command, ever.
- NEVER add a second `wrangler pages deploy` call. Exactly one per run.
- NEVER skip `flutter clean` — skipping it produces corrupt dart2js bundles that boot-hang even with identical source (proven 2026-07-03).
- `git push` runs in the BACKGROUND after wrangler succeeds — history/rollback only. It NEVER gates the deploy. Do not wait on it, do not add a second deploy step.
- The Cloudflare token lives in `~/.medibo/cf.env` (chmod 600, never committed); deploy.sh sources it.
- There is no local preview step. Every change goes straight to production via deploy.sh.

Built-in guards you should not fight: a pull-first guard (never build/commit/push on a stale local, CHANGE #424); auto-increment of the CHANGE # from web/version.json when no N is passed (CHANGE #57 fallback); a bundle-size assert (>1.5 MB or it aborts as corrupt); version.json + `<meta name="build-commit">` stamping; and a per-edge-node retry when polling https://medibo.in/version.json (CHANGE #604), because version.json propagates per node.



## PROJECT · runner_waiting  (priority 74, v1)

## WAITING COSTS NOTHING — IT IS A SHELL SLEEP (CHANGE #1817)

#1812 finished its code at 11/11, queued behind deploy batch 594, and spent 159,555 tokens polling the lane and re-thinking between polls. The batch took 17 minutes and cost nothing. The DB backstop killed the row — which is the problem: the backstop should never be the thing that notices.

The moment you are queued behind ANYTHING you cannot hurry — the merge lane, a batch, a file lease, a busy DB, an RPC that is timing out — you do not poll and you do not think. You run the waiter:

    devcmd.sh wait <id> merge <entry-id>      # straight after queue_push
    devcmd.sh wait <id> lease <path>...       # a file another command holds
    devcmd.sh wait <id> db|rpc|other "<why>"  # anything only time heals

It BLOCKS inside the Bash tool — sleep, check, sleep — so your turn is suspended for the whole of it and there is no turn in which to summarise, re-plan or narrate. It prints exactly ONE line, written by the backend.

- **Exit 0** — the blocker is gone. The line names the next step; carry on from it. Do not re-read the spec, the state file or the prompt.
- **Exit 75** — still busy. Run the IDENTICAL command again (the line hands it back to you, copy-pasteable). Nothing else in between. A Claude Code Bash call is capped at ten minutes, so a long wait is CHUNKED on purpose; dev_wait_begin is re-entrant, so the row stays asleep across chunks and the burn that is measured is the burn of the WHOLE wait.
- Knobs live in worker_pool.wait_gate (poll_s 60, max_wait_s 540, turn_tokens 2000) — change them with pool_set(), never in a script.

A model turn taken while the row is waiting is a BUG, and it is now visible: dev_context_event kind wait_turn records the token delta, _wait_burn_check writes them from the backstop side too, and the Context economy panel prints 'Waiting — 17m asleep · 340 tokens · N wake-ups · target 0' in danger tone the moment N is not zero. waiting_token_grace (150,000) still kills the row; after #1817 it should never fire again.

devcmd.sh wait_state <id> is the one cheap read that says what a row is waiting on. The journey qa-1817-wait-sleeps holds the whole state machine down.


## PROJECT · deploy_lane  (priority 75, v6)

## 3. DEPLOY IS DIRECT — ONE COMMAND, ONE BRANCH, ONE LOCK HOLD (CMD #1859)

The merge lane (CHANGE #324) is OFF: `worker_pool.merge_lane.enabled=false`
(the default; `pool_set` flips it) and `medibo-merge.service` is stopped and
disabled. Over 3 days it ran 135 batches for 176 entries (1.3 per batch), 51
failed, ~12 minutes each, and every eviction or park/resume it caused re-read a
whole context. Batching cost more than it saved. Each command now deploys ITS
OWN branch under `deploy_lock`, and nothing is ever evicted.

1. **Rebase speculatively while you work, never inside a lock.** The moment you
   start coding: `~/mediBO-runner/spec_rebase.sh <your-branch> &`. Stop it with
   `spec_rebase.sh --stop` before you deploy.
2. **Test what you touched, on your own checkout.**
   `bash scripts/affected_tests.sh`. The FULL protected suite runs once more
   on the merged tree inside the direct deploy — a red suite there fails the
   deploy and names the failures.
3. **Schema changed?** `devcmd.sh rebaseline`, then `devcmd.sh rgcheck` must
   print `true` BEFORE you deploy.
4. **Name your branch.** Every runner shares ONE checkout and the deploy
   worktree (`~/medibo-direct`) is cut from the same `.git`, so a local branch
   is already visible: `git branch -f <your-branch> HEAD`. Nothing to push
   (GitHub's key is not authorised here; `origin` is history only).
5. **Deploy it — one call, then sleep on it:**
   `devcmd.sh deploy_direct <cmd-id> <agent> "<title>" <your-branch>`
   It starts `direct_deploy.sh` DETACHED and drops you into the wait door
   (kind `deploy`). The script does, in order: `deploy_lock_try` (busy → holds
   in place, polling every 60 s, never exits) → worktree on the LIVE base +
   your branch merged (the rebase) → `flutter test test/protected/` → live
   migration replay → `deploy_claim_number` → `deploy.sh N` (clean, build,
   smoke gate, stamp version.json, upload) → `verify_live.sh` → `deployed`/`main`
   advanced, `preview_mark(promoted)`, `rg_check` → `deploy_lock_release`.
   Every phase lands on `deploy_direct` (the card draws it) and in
   `~/mediBO-runner/direct_deploy.journal`.
6. **Exit 75 = still deploying.** Run the IDENTICAL `devcmd.sh deploy_wait
   <cmd-id>` again — nothing else, no summary, no re-read. Exit 0 prints
   `CHANGE #N is live (commit …) — complete with p_deploy_no N`. Use THAT
   number in `dev_cmd_complete`; it came from `deploy_claim_number` and is
   already on the row (`web_deploy_no`). A FAILED line names the phase and the
   reason (red test, merge conflict with the live base, smoke, verify): fix it
   on your branch, `git branch -f`, run `deploy_direct` again. It never batches
   with anyone, so nothing is ever evicted.
7. **Watch the lane any time:** `devcmd.sh queue_status` (Dev Queue → Cron
   health → Deploy lane) — `mode_label` reads `DIRECT (deploy_lock)`, and
   `direct[]` lists the recent direct deploys with their phase lines.

`queue_push` / `wait <id> merge` still work: with the lane off they start (or
sleep on) the direct deploy instead, so an old habit lands in the right place.
Flip `worker_pool.merge_lane.enabled=true` and start `medibo-merge.service` to
batch again — the worker code is untouched, only gated.


What the lane proved and the direct path KEEPS: the base is the furthest
fast-forward of `deployed` / `main` / `merge-lane` that still CONTAINS what is
live (never a ref behind production — the CHANGE #983 rewind); this branch's
migration files are replayed on live once, idempotent and ledgered
(`scripts/migration_replay.sh`); the critical-path smoke gate runs on a preview
before the upload (CHANGE #1823, verdict recorded on `deploy_direct`);
`verify_live.sh` with self-load retries is the verdict; `deployed` and `main`
advance only after it; every hold records `wait_s` vs `hold_s`. The lock is
renewed every 60 s (`deploy_lock_touch`) and `deploy_lane_sweep()` still frees
an orphaned lock past its TTL.

`devcmd.sh lane_mode` prints on|off. `devcmd.sh queue_status` → `mode_label`
reads `DIRECT (deploy_lock)`; when it reads `MERGE QUEUE` the switch is on and
the old queue_push → merge worker → batch flow applies (`merge_worker.sh` is
untouched, only gated on the same switch).



## PROJECT · deploy_traps  (priority 78, v1)

Deploy traps — hours lost to each of these at least once. Read before diagnosing a "broken" deploy.

- **Dead shell vs live shell.** `lib/screens/admin/admin_shell.dart` is a legacy surface; the live shell is `lib/screens/home_shell.dart` (it imports admin_shell for the wide-viewport link row only). Editing the admin shell and seeing no change on a phone is this trap — a phone had no way into that row at all. Wire new admin entry points through `home_shell.dart` / `admin_nav_entries.dart`.
- **render_verify.js can read stale/misleading state.** It self-loads medibo.in headless and reads `#medibo-render-log`, but a cached page or a not-yet-repainted key makes it look like a failure that is not one. `scripts/verify_live.sh` is the REAL signal — it asserts the fingerprinted bundle is 200 and full-size, then version.json, then the render-log.
- **Self-waiter noise (exit 144 class).** Background/self-waiting steps in the deploy chain can exit non-zero without the deploy having failed. Judge the deploy by verify_live.sh's exit code (0 verified / 1 broken / 2 deployed-but-unconfirmed), not by a stray non-zero from a helper.
- **Commit mismatch is normal, briefly.** deploy.sh amends the git commit with the fingerprinted artifacts AFTER building, and version.json propagates per edge node. A mismatch in the first seconds, or on one node, is propagation — retry (the script already polls with a cache-buster) instead of redeploying.
- **A partial bundle response is not a broken build.** Immediately after a deploy an edge node can serve a truncated body (#601 read 71,561 b for a 7,873,501 b bundle). verify_live.sh retries 6×; a verifier that fails on healthy deploys trains you to ignore it.
- **Exit 2 is not failure.** It means the deploy landed but no browser has visited yet. Self-load with render_verify.js and re-run — never end a task saying "the render log is stale / needs a real visit".


## PROJECT · design  (priority 80, v3)


The app is styled 100% from backend design tokens: `ui_boot().design` → `Ds.*` (lib/design_tokens.dart) → `buildTheme()`. Change a token via `ui_design_set(patch)` and the WHOLE app recolours on next boot with ZERO code change and no deploy. `ui_design_get()` reads current tokens.

Hardcoded style literals in a screen are a FAILED command:
- NO `Color(0x…)` — use `Ds.c.*` (brand, bg, surface, text, textSecondary, divider, success/warning/danger/info + `*Soft` tints).
- NO `fontSize:` / raw `TextStyle` sizes — use `Ds.t.*` (display/title/subtitle/body/caption) or the theme text slots.
- NO bare numeric `EdgeInsets`/`SizedBox`/`BorderRadius`/`BoxShadow` — use `Ds.space.*`, `Ds.r.r*`, `Ds.elevation.e1/e2`.
- One `Ds.c.brand` primary action per screen; red only destructive; ≤3 hues.

Only `lib/design_tokens.dart` and `lib/theme.dart` may hold style literals — they DEFINE the tokens. The gate `test/protected/design_literal_gate_test.dart` runs before every deploy: a NEW literal in a screen, or an increase over that file's frozen baseline, FAILS the build. Baselines ratchet DOWN only — every polish batch lowers `test/protected/design_literal_baseline.json`, never raises it. After migrating a file, run `dart run tool/design_baseline.dart --write` and commit the new baseline. Follow DESIGN.md.



## PROJECT · design_qa  (priority 84, v2)


Design QA gate — run before `dev_cmd_complete` on ANY command that touches UI. Self-review the changed screens; if a check fails, FIX and re-check before completing. Write "Design QA: passed (N checks)" into result_summary.

1. Spacing rhythm — only 4/8/12/16/24/32/48; unrelated blocks ≥24 apart.
2. Colour discipline — one brand primary; red only destructive; ≤3 hues.
3. Hierarchy — ≤3 type sizes; a real title; captions in textSecondary.
4. Components — cards radius16 + e1; primary button full-width ≥44; sheets over dialogs.
5. Touch — every tap target ≥44×44.
6. States — empty state has one-line guidance; loading is a skeleton, not a bare spinner; errors show backend copy + Retry.
7. Tokens — zero new style literals (gate green); everything via Ds/theme.



## PROJECT · verification  (priority 85, v3)


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


Proof-based completion (CHANGE #129 — bug-loop prevention). Completion is EVIDENCE, never a claim; `dev_cmd_complete` enforces this when `worker_pool.bugloop.enforce=true`.

Non-negotiable for every UI-touching command:
1. **Journeys.** After deploy (to preview when the preview lane is live) run the command's area journeys plus global → `journey_report(cmd, results[])`. Every `required=true` journey for the area MUST pass. A journey only becomes required after passing GREEN TWICE — never on first sight, never by hand to turn a red command green.
2. **QA (L2).** A separate hostile QA agent tests the preview and files `qa_report(cmd, 'passed'|'failed', findings[])`. The gate needs `passed` or an explicit PIN-gated `qa_waive`. Failed → back to the builder (max 2 rounds), then `needs_input` with the findings summary. Skip QA only for docs-only / gcp / mutation commands (`qa_required=false`).
3. **Screenshot.** ≥1 screenshot of the changed screen in `dev-cmd-proofs`, plus the exact click path in `result_summary`.
4. **Bugs become journeys.** Every `bug_report` finding creates a permanent linked journey; the fix cannot complete until that journey passes — that retires a CLASS of bug instead of one screenshot at a time.

Surfaces: the chip row per command (`qa_chip`, `preview_chip`, `journey_chip`) and the detail screen's QA & Journeys section render this verbatim from `dev_cmd_list` / `dev_cmd_qa_detail`. Om-facing entries: "Report a bug" in the Dev Queue header and the Journey Library (header map icon).

NEVER flip `bugloop.enforce=true` until the full chain (preview → journeys → QA → promote) is rehearsed end-to-end on a harmless command — flipping it early blocks every future completion.



## PROJECT · dart_imports  (priority 92, v2)


Defensive import rule — prevents dart2js static-init crashes.

NEVER add `import 'dart:html'`, `import 'dart:js'`, or any `dart:*` web-only library to a file that is imported by the widget tree (view_as_state.dart, app_state.dart, user_state.dart, any model or notifier). These cause static-initialization ordering crashes in dart2js -O4 release builds and white-screen the ENTIRE app.

Only `main.dart` (the entry point) may import `dart:html` — it loads last. If a feature needs localStorage/sessionStorage, use the `shared_preferences` package instead.



## PROJECT · boot_resilience  (priority 94, v2)


Boot resilience rule (permanent). `main.dart` MUST always wrap startup in `runZonedGuarded`. `Supabase.initialize` and every other init step MUST be individually try/caught. `_AppRoot` MUST remain a StatefulWidget with a hard 5-second boot timeout that forces HomeShell if auth never resolves. `FlutterError.onError` MUST be set at boot.

Never revert these patterns — a feature crash MUST NOT white-screen the app.



## PROJECT · gemini  (priority 96, v2)


GEMINI RULE (absolute). Every AI/OCR feature uses ONLY `gemini-3.5-flash` on Vertex AI, global endpoint: `aiplatform.googleapis.com`, `locations/global`, `thinkingLevel='low'`, GCP_SA_KEY auth.

NEVER gemini-2.5 / 2.0 / 1.5. NEVER `generativelanguage.googleapis.com`. NEVER API-key auth. Before writing any Gemini code, copy the exact pattern from the `gemini-ocr` edge function.

ENTITY IDENTITY RULE (never remove): `official_name` = the formal legal name of EXACTLY the entity on the card. NEVER substitute a parent, acquirer, group or successor. Expanding the same entity's abbreviation is allowed (ALKEM → Alkem Laboratories Ltd.); replacing a distinct entity is forbidden (Aventis → Sanofi India Ltd. ✗, German Remedies → Zydus Lifesciences Ltd. ✗, Cipla Diagnostics → Cipla Ltd. ✗). When in doubt, keep `visible_name` verbatim as `official_name` with confidence=low.



## PROJECT · naming  (priority 98, v2)


OCR NAMING RULE (absolute, permanent). All OCR in mediBO returns VERBATIM text exactly as printed — never official names, never expansions, never corrections, never parent/group companies, never world knowledge. The review modal and stored records carry verbatim seen text only. Run `scripts/test_ocr_verbatim.sh` after every gemini-ocr change; the deploy fails if it fails. Never remove this rule or that script.

COMPANY NAMING RULE (absolute). Gemini never generates or normalizes company names — it extracts verbatim text only (the `seen` field). The review modal pre-fills the editable name field with that verbatim text. Import stores whatever the admin leaves in the field (default = verbatim). No resolution, no fuzzy matching, no expansion anywhere in the import path.



## PROJECT · regression_guard  (priority 106, v1)

Regression guard — the schema safety net.

Run `rg_check()` (`devcmd.sh rgcheck` → must print `true`) after EVERY migration and before every `dev_cmd_complete`; the completion RPC itself raises if the guard is red. It compares the live schema/RPC surface against a stored baseline, so a dropped column or a silently changed function signature is caught in the same command that caused it.

`rg_baseline_all()` (`devcmd.sh rebaseline`) is ONLY run AFTER you have verified the new state is correct — re-baselining a red guard just blesses the regression. Order is: migrate → verify the new state is what you intended → rebaseline → rgcheck green → deploy.


## RULES HELD OUT OF THE WINDOW (CMD #1885)

These are reference, not working set: the heading and the hook are here so
you know the rule exists, and the body is one cheap call away — the whole
point is that it is read by the one command in fifty that needs it, not
carried by the other forty-nine.

    devcmd.sh rule <name>        # e.g. devcmd.sh rule playstore
    ~/mediBO/RULES.full.md       # all of them, in full, git-committed

- **PROJECT · db_lane  (priority 76, v1)** — 15. DB WORK LANE (permanent — CHANGE #301)
- **PROJECT · build_lane  (priority 77, v1)** — 16. BUILD LANE — NOTHING WAITS ON A FILE (CHANGE #327)
- **PROJECT · design_system  (priority 82, v2)** — DESIGN SYSTEM (apply to all UI work)
- **PROJECT · protected_tests  (priority 90, v13)** — PROTECTED TEST SUITE (CHANGE #635 — never remove)
- **PROJECT · latency  (priority 100, v2)** — Latency lessons — every one of these cost hours. Check them BEFORE proposing hardware.
- **PROJECT · vm_traps  (priority 102, v1)** — VM traps — the environment, not the code.
- **PROJECT · integrations  (priority 104, v1)** — External integrations — the facts that stop key-hunting.
- **PROJECT · parallel_workers  (priority 108, v2)** — 13. PARALLEL WORKERS (permanent — CHANGE #74)
- **PROJECT · gcp  (priority 110, v2)** — 10. GCP COMMANDS (kind='gcp')
- **PROJECT · playstore  (priority 112, v1)** — Play Store / Android.

