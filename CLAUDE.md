# mediBO — agent rules

## WHY THIS FILE IS SHORT (CMD #1885)

Everything that used to be written out here is in **RULES.md**, which the line at
the bottom of this file loads into every session anyway. Keeping a second copy
here did not make the rules any more binding — it made every command pay for
them twice, in every window, forever. Turn 1 of a build was 153,000 input tokens
before a single line of the spec had been read.

So the rules live in exactly one place now:

| where | what is in it |
|---|---|
| `RULES.md` | the WORKING SET — every rule that causes damage when it is not in the window (deploy, verification, the backend contract, OCR/company naming, Gemini, the `dart:html` import ban, boot resilience, the design token gate, the runner's status/failure/forbidden discipline). Loaded automatically. |
| `RULES.full.md` | all 46 rules in full, byte for byte — the git-committed offline fallback, and what the reference rules' bodies are read from. |
| `devcmd.sh rule <name>` | one rule's body, on demand (`devcmd.sh rule playstore`). `devcmd.sh rule` with no argument lists them. |
| `devcmd.sh lessons_get <area>` | the standing lessons for an area, as titles; `devcmd.sh lesson <id>` for a body. |

Both rules files are regenerated from Supabase `agent_memory` on every session by
`memory_render.sh` — edit a rule in the mediBO app (Dev Queue → Memory) or via
the memory MCP server, never by hand here.

## THE FOUR THAT ARE NOT NEGOTIABLE

Repeated here, and only these four, because forgetting one of them costs a
production outage rather than a rework:

1. **Deploy is `bash ~/deploy.sh`.** One command, one `wrangler pages deploy`,
   never Netlify, never a second upload call, never skipping `flutter clean`.
2. **Proof is `bash scripts/verify_live.sh` plus the render-log** — never a JS
   bundle grep, never Puppeteer/CDP on a Flutter canvas, and never asking Om to
   go and look. Live verification is Claude Code's job.
3. **Maximum backend.** Every string, total, label, format and decision lives in
   Supabase; Dart renders payloads verbatim. A display string written in Dart is
   a bug, not a shortcut.
4. **`flutter test test/protected/` before every deploy**, and a protected test
   is only ever changed when the CHANGE deliberately changes that behaviour.


<!-- BEGIN agent_memory -->
<!-- AUTO-GENERATED pointer for claude. Do not edit inside these markers. -->
# Portable agent memory (claude)
@RULES.md
# ^ The full, current rules live in RULES.md (regenerated from Supabase each
#   session by memory_render.sh). If RULES.md is missing, run that script.
#
# The line above MUST stay '@RULES.md'. It was '@import RULES.md' from #182
# until #194, which is not the import syntax any agent understands: Claude Code
# and Gemini CLI both resolve a bare '@<path>', so '@import' was read as a
# missing file called 'import' and RULES.md was NEVER loaded into a session.
# Agents ran purely on CLAUDE.md's hand-written body and every rule stored in
# agent_memory was inert. Proof (#194): a headless 'claude -p' asked whether a
# phrase unique to RULES.md was in its startup context answered NO before this
# fix and YES after. Re-run that probe if you ever touch this block.
<!-- END agent_memory -->
