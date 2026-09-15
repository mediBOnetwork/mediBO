-- CMD #2038 — the storefront header stops flickering on scroll.
--
-- #2030 made the header band a DISTANCE that follows the finger 1:1. It moves
-- on every delta the scroll view reports, and a scroll view reports more than
-- the finger: a tremor mid-drag, the bounce at either end, the snap-back that
-- follows it, and the correction that arrives when a collapsing band hands its
-- own height to the viewport. Each of those is a delta in the WRONG direction,
-- and 1:1 obeyed every one of them — which is the pop-in/pop-out Om sees while
-- scrolling down with no reversal of his own.
--
-- The fix is in the driver (lib/screens/shell/shell_mobile_chrome.dart): only
-- the part of a delta that happened INSIDE the list drives the band, a
-- ballistic phase is locked to the direction it started in, and a reversal has
-- to earn its turn by travelling a threshold in the new direction first.
--
-- That threshold is the one number worth tuning, so it is a DESIGN TOKEN, like
-- the band's own height (#2030) — `touch.headerHysteresis`, in logical pixels.
-- Retuning the flicker guard is one ui_design_set() and no deploy.
--
-- ui_design_set merges ONE level, so the whole `touch` object is sent back with
-- the two header numbers folded in. Idempotent: re-running writes the same
-- object, and any other touch token a later change adds survives because the
-- object is read from ui_design_get() rather than spelled out here.

do $$
begin
  if to_regprocedure('public.ui_design_set(jsonb)') is null then
    raise notice 'c2038: ui_design_set absent - the Dart default (8) stands';
    return;
  end if;
  -- The design row is dev_runner_config.ui_design and ui_design_set merges ONE
  -- level, so sending `touch` folds these two in and leaves every other touch
  -- token alone. Re-running writes the same numbers: idempotent.
  if not exists (select 1 from public.dev_runner_config where key = 'ui_design') then
    raise notice 'c2038: no ui_design row here - the Dart default (8) stands';
    return;
  end if;
  perform public.ui_design_set(jsonb_build_object(
    'touch', jsonb_build_object(
      -- the header's height AND the distance it travels (#2030 / #2037)
      'headerBand', 64,
      -- CMD #2038 - how far a reversal must travel before it is believed
      'headerHysteresis', 8
    )
  ));
end $$;
