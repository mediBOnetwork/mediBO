-- CMD #2080 — the storefront bottom nav hides on scroll-down and returns on
-- scroll-up, exactly as the collapsing header does.
--
-- The BEHAVIOUR is a backend switch, not a Dart constant: the app asks
-- `ui_copy` whether the shell may hide its bar, so turning it off for every
-- phone in the field is one UPDATE and no deploy.
--
--   update public.ui_copy set value = to_jsonb(false)
--    where key = 'shell.nav_hide_on_scroll';
--
-- Default ON, and `do nothing` on conflict so re-running this file can never
-- switch a deliberately-off shell back on.
--
-- The TIMING is not here on purpose. The bar travels on the header band's own
-- driver (`Ds.touch.headerBand` / `headerHysteresis` / `headerSettleMs`, all
-- already backend design tokens), so "same animation timing as the header" is
-- a fact of the code rather than a second number kept equal to the first.

insert into public.ui_copy (key, value)
values ('shell.nav_hide_on_scroll', to_jsonb(true))
on conflict (key) do nothing;
