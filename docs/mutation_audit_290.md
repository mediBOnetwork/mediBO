# Mutation audit — CHANGE #290 (23 Aug 2026 IST)

An audit that reports a pass for a test it never ran is worse than no audit.
The previous two audits did exactly that: rows 10 and 11 of `mutation_audits`
declared `backup-lands` a "safe-skip" and filed `caught=true` anyway, and row 12
credited `fast-lane-writes` with a strengthening that was never in the live
probe. This run breaks every target for real and reads the verdict.

## Harness

| function | what it does |
| --- | --- |
| `_mut_src(fn, pattern, repl)` | mutates a function's source, and RAISEs when the pattern matched nothing — a no-op mutation can never masquerade as a robust suite |
| `_mutation_recipe(journey)` | the per-journey break, hardcoded; callers cannot pass SQL in |
| `mutation_trial(journey)` | baseline probe → break → probe → subtransaction rollback |
| `mutation_trial_suite(journey)` | the same, but probes the WHOLE suite while one target is broken, and reports cross-talk |
| `mutation_audit_run(journeys, report)` | the sweep, filing `mutation_report()` per trial |

The revert is not a compensating UPDATE that could itself fail. The break and
the probes run inside one plpgsql exception block — a real subtransaction —
which is always left by `RAISE`, so Postgres rolls the mutation back. plpgsql
variables are not transactional, so the verdict escapes the rollback. Nothing
leaves residue, including a probe that dies half way.

## Results

Baseline suite: 18 passed, 1 skipped (`qa-273-47`).

| sweep | caught | escaped | undecided |
| --- | --- | --- | --- |
| pre-fix | 11 | 7 | 1 |
| post-fix | **19** | **0** | **0** |

Random pick for the single-target run (step 4): `qa-274-54`. Pre-fix it escaped
— its proof rows were deleted and all 19 journeys still read green. Post-fix it
is caught, with no collateral movement in any other journey.

## What the audit found

### 1. The journey suite was dead (not a weak assertion — a dead suite)

`dev_journeys_run` was raising `dev_queue: not authorized` and writing ZERO
`dev_journey_runs` rows, silently disarming the proof-based completion gate for
every command in every area.

`rg_collect_payloads()` impersonates each payload target with
`set_config('request.jwt.claims', …, true)` and finishes by CLEARING the claims.
`set_config(…, true)` is transaction-local, so the caller never gets its
`service_role` identity back. `dev_journeys_run` probes every journey in ONE
transaction ordered by id; journey 16 is `bug-191`, whose probe calls
`rg_check`. From that point the transaction is anonymous. Earlier in this same
command a `_dev_guard()` was added to `dev_journey_probe` — correctly, it was
EXECUTE-able by anon while doing DDL — and every probe after `bug-191` began
failing the guard.

The security fix was right and the leak was always there; together they killed
the suite. Fixed at the source: `rg_collect_payloads` now restores the caller's
claims, and `dev_journeys_run` re-asserts its own before every probe.

### 2. The fallback branch was certifying itself

`dev_journey_probe`'s `else` arm passed a journey once it had ≥2 passed runs on
record — but its own pass writes a `dev_journey_runs` row, and that row counted.

| journey | passed runs | of those, its own |
| --- | --- | --- |
| `devqueue-buttons-change-db` | 40 | **40** |
| `worker-grid-loads` | 40 | **40** |
| `qa-274-54` | 15 | 13 |
| `qa-274-57` | 14 | 12 |

Two required journeys had never been proven by anything but themselves. The
branch now counts only externally reported passes (evidence WITHOUT a `db_proof`
key — the shape `journey_report` files from a Playwright or widget run).

### 3. Seven escapes, all closed

| journey | why it escaped | strengthening |
| --- | --- | --- |
| `reply-media-live` | `images '[""]'` still "carries 1 image" | `bool_and` over the paths, like `add-media-survives` |
| `fast-lane-writes` | any non-null `ui_copy` value passed | compare the exact stored value |
| `menu-reachability` | self-certifying pass count | external passes only |
| `qa-274-54` | self-certifying pass count | external passes only |
| `qa-274-57` | no probe at all | walks the anon `storefront_home_v2` payload as a typed pricing block |
| `worker-grid-loads` | no probe at all | every settled building command must have a chip; no chip may be blank |
| `devqueue-buttons-change-db` | no probe at all | each button's RPC must write its status literal, and all four must be guarded |
| `qa-273-47` | permanently `skipped` | real privilege probe over the six cron RPCs and four cron tables |

A skipped REQUIRED journey blocks completion for its whole area exactly like a
failure, so `qa-273-47` was as broken as an escape.

### 4. Two bugs in the new probes, caught by re-running the sweep

* `qa-274-57` read `count(*) filter (…)` into BOOLEAN variables. It survived a
  clean payload only because 0 and 1 are valid boolean input; under the real
  leak the count is all 562 cards and the cast died with `invalid input syntax
  for type boolean: "562"`, recording `not_applied` instead of red. Now
  `bool_or`.
* `qa-273-47` asserted no cron RPC is EXECUTE-able by anon **or** authenticated.
  `authenticated` legitimately holds EXECUTE on `cron_health`, which guards
  itself with `_dev_guard()` and backs the super-admin Cron Health screen.
  Narrowed to anon, plus the invariant that matters: anything a signed-in role
  can execute must guard itself.

This is why the audit re-runs after strengthening instead of trusting the edit.

## Deliberate non-assertion

`qa-274-57` does **not** text-search the response for a formatted PTR token. A
whole-rupee token collides with a legitimate MRP across 500+ cards — `₹83` is a
real MRP somewhere — and that collision produced two false alarms and two wasted
debug passes before. The typed walk (ptr keys absent, `card_price.has_ptr`
false, locked note present, `display_mode = mrp_only`) is the assertion that
holds.

## Where Om sees it

`journeys_get()` appends the latest verdict to the `assertions[]` the Journey
Library already renders verbatim, so no Flutter change was needed.

**Click path:** admin menu (super-admin) → Dev Queue → header map icon →
Journey Library → any journey card → last line under "Assertions".

Wording lives in `ui_copy` (`dev_queue.journey_mutation_line`,
`…_caught`, `…_missed`), so changing it is an UPDATE and never a deploy.
