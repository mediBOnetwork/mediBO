-- CMD #2012 — RG red after #1374: the phone sweep's red said the wrong thing.
--
-- rg_runs 17:49 was red on responsive_no_overflow alone (0 diffs, 0 missing
-- critical) with the detail "storefront home @412px did not load (wrote no
-- render log) · 2 not measured inside the budget". Nothing overflowed: the
-- same sweep measured 37 of 40 combinations with overflow=0 and
-- tap_targets_small=0 at every width, and re-running that one combination
-- against the same live build passed. Every red this behaviour has produced
-- since CMD #1950 has been a read the harness could not take, yet the message
-- has always announced an overflow — which sends the next runner looking for a
-- layout bug that does not exist.
--
-- scripts/responsive_sweep.js now decides (same command): a combination it
-- could not READ is reported as unmeasured and only fails when it is still
-- unmeasured on the next sweep, or when a screen answered at none of the
-- widths tried. A number the APP reported — an overflow, a tap target under
-- the minimum, a screen that never painted — still fails on sight.
--
-- This migration only makes the exception say what the verdict actually found.
-- Idempotent: it re-upserts the one behaviour row.

insert into rg_behavior_tests (name, enabled, note, body) values (
 'responsive_no_overflow', true,
 'CMD #1950 — after every deploy scripts/responsive_sweep.js loads the top staff and customer screens at 320/360/412/480 px (plus one tablet width) and reads the render log the app writes about itself. Any Flutter overflow, an unpainted screen, or a tap target under the configured minimum makes the verdict red, and this turns rg_check red with the screen and the width named. CMD #2012 — a combination the sweep could not read is not an overflow: the verdict carries its own reason and this test prints it verbatim.',
 $t$do $b$
declare v_verdict jsonb; v_max_age int;
begin
  select to_jsonb(r) into v_verdict from rg_runner_verdict r where r.name='responsive_no_overflow';
  select coalesce((value->'mobile_first'->>'verdict_max_age_h')::int, 72)
    into v_max_age from dev_runner_config where key='worker_pool';

  -- Never measured is not a regression: the first sweep writes the verdict and
  -- every deploy after re-writes it. A timeout is not a measurement (#962).
  if v_verdict is not null then
    if not coalesce((v_verdict->>'ok')::boolean,false) then
      -- CMD #2012: the sweep names the fault (an overflow, a small tap target,
      -- a screen that never painted, or one that would not load twice running).
      -- Printing "a top screen overflows" over a read failure cost #2012 its
      -- first hour looking for a layout bug that was never there.
      raise exception 'RG_FAIL: the phone sweep is red — %',
        coalesce(v_verdict->>'detail','(no detail)');
    end if;
    if (v_verdict->>'at')::timestamptz < now() - make_interval(hours => coalesce(v_max_age,72)) then
      raise exception 'RG_FAIL: the responsive sweep has not run since % — the phone layouts are unproven',
        (v_verdict->>'at');
    end if;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;$t$)
on conflict (name) do update set body = excluded.body, note = excluded.note, enabled = true;
