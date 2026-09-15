-- CMD #2052 — the header moves on the FINGER, and it never stops half open.
--
-- #2030 made the band a distance that follows the list 1:1; #2038 filtered the
-- deltas that no finger produced. Both read the SCROLL OFFSET, and the offset
-- is exactly what jumps backwards when a page of products is inserted, when the
-- list re-measures, when the keyboard opens or when something scrolls the view
-- programmatically. Every one of those backward jumps read as "the finger went
-- up" and flashed the header back mid-scroll.
--
-- The driver (lib/screens/shell/shell_mobile_chrome.dart) is now fed by the
-- POINTER delta while the finger is down and by nothing else, so an offset that
-- moves on its own moves the header by zero. Two numbers are worth tuning, so
-- both are design tokens, like the band's own height:
--
--   touch.headerHysteresis — how far the finger must travel in the NEW
--     direction before the band is allowed to turn around. 40 px: #2038's 8 was
--     measured on the list's own deltas; on the pointer it is a twitch.
--   touch.headerSettleMs — how long the band takes to finish itself off after
--     the finger leaves, so it is fully shown or fully hidden, never half open.
--
-- Retuning either is one ui_design_set() and no deploy.
--
-- ui_design_set merges its TOP level only, so `touch` arrives whole. The whole
-- object is therefore read back from the live row first and the two numbers are
-- folded into it: every other touch token (minTarget, listRowMinHeight,
-- bottomBarGap, headerBand) survives, and a later change's token survives too
-- because nothing here spells the object out. Idempotent — re-running writes
-- the same object.

do $$
declare
  _touch jsonb;
begin
  if to_regprocedure('public.ui_design_set(jsonb)') is null then
    raise notice 'c2052: ui_design_set absent - the Dart defaults (40 / 180) stand';
    return;
  end if;
  if not exists (select 1 from public.dev_runner_config where key = 'ui_design') then
    raise notice 'c2052: no ui_design row here - the Dart defaults (40 / 180) stand';
    return;
  end if;

  select coalesce(value -> 'touch', '{}'::jsonb)
    into _touch
    from public.dev_runner_config
   where key = 'ui_design';

  perform public.ui_design_set(jsonb_build_object(
    'touch',
    _touch
      -- the header's height AND the distance it travels (#2030 / #2037)
      || jsonb_build_object('headerBand', coalesce(_touch -> 'headerBand', to_jsonb(64)))
      -- CMD #2052 - a deliberate 40 px of FINGER travel turns the band around
      || jsonb_build_object('headerHysteresis', 40)
      -- CMD #2052 - and the band finishes itself off in 180 ms
      || jsonb_build_object('headerSettleMs', 180)
  ));
end $$;
