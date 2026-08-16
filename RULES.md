# mediBO — Portable Agent Rules (canonical, auto-generated)
# Source of truth: Supabase agent_memory. Edit in the mediBO app
# (Dev Queue -> Memory) or via the memory MCP server. Regenerated every
# session by memory_render.sh. This file is the OFFLINE git fallback: if both
# Supabase and the MCP server are down, agents still boot from this committed copy.

<!-- BEGIN agent_memory -->
<!-- AUTO-GENERATED from Supabase agent_memory. Edit rules in the mediBO
     Dev Queue → Memory screen, or via the MCP memory server. Do NOT hand-edit
     this block; it is rewritten on every session start. Target: generic -->

# Agent memory (generic) — 10 rules
# Canonical fallback: see RULES.md in the repo root (git-committed).

## GLOBAL · style  (priority 10, v1)

Answer in 10 lines max. Each line = title + short description, max 5 words per line, 50 words per response total. Bullet points only (**Title** — description). No preamble, no closing offer.


## GLOBAL · pricing  (priority 20, v1)

All money in INR (₹), India market. All timestamps IST for display. Never quote USD. Road distances from self-hosted OSRM only — never Google Distance/Route Matrix APIs.


## GLOBAL · rules  (priority 30, v1)

Never flag — fix. A problem you can fix yourself is unfinished work, not a finding. Decide, don't ask: pick the recommended option and execute; ask only for irreversible data loss (DROP/TRUNCATE/DELETE of rows you did not create).


## GLOBAL · backend  (priority 40, v1)

Maximum backend. Everything computed, decided, formatted and worded in the backend. The frontend does exactly two things: render what the backend returns, and send user input back. No display strings, totals, role branches, routes, or formatting in Dart. On a clash, backend wins.


## GLOBAL · offline  (priority 50, v1)

Fast on slow/no internet. Cache the last payload, render it instantly with the backend's own staleness string, refetch in background, re-render. The cache is a render fallback, never an authority. Queue writes, send, await, render — no optimistic state.


## PROJECT · workflow  (priority 60, v1)

mediBO Dev Queue runner loop: claim → build → deploy → verify → record → next. Never ask, never idle, never leave a row building. Finish every command with dev_cmd_complete / dev_cmd_fail / dev_cmd_ask. Heartbeat every 60s with ETA. First heartbeat becomes the command title.


## PROJECT · deploy  (priority 70, v1)

Deploy = bash ~/deploy.sh (flutter clean + build + ONE wrangler Pages Direct Upload to project "medibo" branch main). NEVER Netlify. NEVER a second wrangler call. git push is background history only. After deploy run bash scripts/verify_live.sh (exit 0 verified).


## PROJECT · deploy_lane  (priority 75, v1)

Deploy lane exact order: deploy_lock_try → git rebase onto origin/main → flutter test test/protected/ → (schema? rebaseline + rgcheck green) → deploy_claim_number → stamp web/version.json → deploy.sh N → verify_live.sh → deploy_lock_release. Skip any step = failed command.


## PROJECT · design  (priority 80, v1)

App is styled 100% from backend design tokens (ui_boot().design → Ds.*). No Color(0x..), no raw fontSize/TextStyle, no bare EdgeInsets/BorderRadius numbers in screens — use Ds.c/Ds.t/Ds.space/Ds.r/Ds.elevation. One brand-green primary per screen; red only destructive; ≤3 hues. Follow DESIGN.md.


## PROJECT · verification  (priority 85, v1)

Flutter web renders to canvas — Puppeteer/CDP cannot read it. Never install Puppeteer. Proof = version.json commit matches build AND render-log count > 0. String-in-bundle is not proof. Live verification is Claude Code's job, never Om's.


<!-- END agent_memory -->
