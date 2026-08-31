-- CHANGE #350 — step progress must tick itself.
--
-- #340 sat at "Step 0 of 7" with 550K tokens spent and a change already
-- promoted: the agent worked, but nothing ever called dev_cmd_step_done, so the
-- card showed a dead checklist and Om could not tell where the build was. Three
-- layers here, none of which depend on an agent remembering:
--
--   1. DERIVED TICKS  — dev_cmd_step_autotick(): the runner harness observes a
--      FACT (migration applied, tests green, branch queued, change deployed) and
--      the backend decides which step that fact satisfies, from data
--      (dev_step_fact_rule), not from Dart and not from the agent's memory.
--   2. A BACKSTOP     — the existing dev_cmd_watchdog() gains a rule: tokens
--      climbing while steps_done stands still => nudge the agent through the
--      same message channel Om's replies use, and FLAG the card so a stale
--      checklist reads as untrusted instead of silently wrong.
--   3. HONEST COPY    — every string below lives in ui_copy; the card renders
--      it verbatim.
--
-- Nothing is backfilled: this applies to rows that are building from now on.

-- ── 1. the flag the card renders, and the watchdog's own snapshot ───────────
alter table dev_commands add column if not exists steps_stale_flagged boolean not null default false;
alter table dev_commands add column if not exists steps_stale_at   timestamptz;
alter table dev_commands add column if not exists steps_nudge_count int not null default 0;
alter table dev_commands add column if not exists steps_nudged_at  timestamptz;
-- The step clock is its OWN snapshot, deliberately separate from guard_snap_*:
-- the zombie guard may restart its clock for a reason (an ETA moved) that says
-- nothing about whether the checklist is being reported.
alter table dev_commands add column if not exists steps_snap_at     timestamptz;
alter table dev_commands add column if not exists steps_snap_done   int;
alter table dev_commands add column if not exists steps_snap_tokens bigint;
alter table dev_commands add column if not exists steps_auto_count  int not null default 0;

-- ── 2. which observed fact satisfies which step — DATA, not code ────────────
-- A new detectable fact, or a new way of wording a step, is one INSERT here.
create table if not exists dev_step_fact_rule (
  fact    text    not null,
  pattern text    not null,              -- case-insensitive regex over the step TITLE
  note    text    not null default '',   -- what the auto-tick writes into the step
  ord     int     not null default 100,
  enabled boolean not null default true,
  primary key (fact, pattern)
);
comment on table dev_step_fact_rule is
  'CHANGE #350 — maps an OBSERVED build fact to the step title it satisfies, so progress does not depend on the agent remembering to report it.';

insert into dev_step_fact_rule (fact, pattern, note, ord) values
  ('migration', '(migration|schema|column|table|backend|rpc|sql|trigger|function|policy)', 'auto: migration applied', 10),
  ('rgcheck',   '(rg_?check|regression guard|baseline|guard green)',                        'auto: rg_check green',    20),
  ('frontend',  '(flutter|dart|screen|widget|frontend|wire|chip|card|ui\b)',                'auto: Dart change committed', 30),
  ('tests',     '(test|suite|green|qa\b)',                                                  'auto: tests green',       40),
  ('queue_push','(queue|deploy|push|merge|ship|release|promote)',                           'auto: branch queued for deploy', 50),
  ('deployed',  '(deploy|verify|live|promote|ship|release)',                                'auto: change deployed live',     60)
on conflict (fact, pattern) do update
  set note = excluded.note, ord = excluded.ord, enabled = true;

-- ── 3. every string the surfaces show ───────────────────────────────────────
insert into ui_copy (key, value) values
  ('dev_queue.steps_stale_chip',
   '"Steps not being reported — checklist may be stale ({age})"'::jsonb),
  ('dev_queue.steps_stale_hint',
   '"This checklist has not moved while the build kept spending. Treat it as untrusted until the worker syncs it."'::jsonb),
  ('dev_queue.steps_nudge_noplan',
   '"⚠ STEP SYNC — #{id} has NO step plan published and has already spent {tokens} tokens. Publish it now: devcmd.sh steps_set {id} ''[\"step one\",\"step two\"]'' <branch> — then mark every step the moment it lands with devcmd.sh step_done {id} <n> <commit> \"<what landed>\"."'::jsonb),
  ('dev_queue.steps_nudge_stale',
   '"⚠ STEP SYNC — #{id} still reads Step {done} of {total} after {age} and {tokens} tokens. Mark what has landed now: devcmd.sh step_done {id} <n> <commit> \"<what landed>\". If the plan changed, REWRITE it with devcmd.sh steps_set {id} — never leave it stranded at the old plan."'::jsonb),
  ('dev_queue.steps_auto_note',
   '"{n} step(s) ticked automatically from observed facts"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ── 4. the knobs (no deploy needed to retune) ───────────────────────────────
update dev_runner_config
   set value = value || jsonb_build_object('steps_watchdog', jsonb_build_object(
         'enabled',    true,
         'stale_min',  12,      -- checklist frozen this long …
         'min_tokens', 40000,   -- … while at least this many tokens were spent
         'renudge_min', 12,     -- never nudge the same row more often than this
         'nudge_max',  3,       -- and never more than this many times per build
         'autotick',   true))
 where key = 'worker_pool'
   and not (value ? 'steps_watchdog');
