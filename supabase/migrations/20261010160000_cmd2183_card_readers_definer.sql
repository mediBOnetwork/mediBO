-- CMD #2183 — debug pass on #2167, finding 1: the card readers answer the
-- public API with the WRONG numbers.
--
-- `card_layout()` and `card_style()` are published to the app but left
-- SECURITY INVOKER, and `app_settings` carries RLS whose only policy is
-- admin-all. So the `select value from public.app_settings` inside each reader
-- returns NOTHING for every non-admin caller and the coalesce falls through to
-- the hardcoded default. Proven on this build's branch before the fix:
--
--   update app_settings set value = value || '{"radius":28}' where key='card.layout';
--   card_layout()->>'radius'  as postgres = 28
--   card_layout()->>'radius'  as anon     = 16     <-- the admin's value, ignored
--
-- That is spec item 4 of #2167 ("change one value on dev, reload, it changes
-- with no deploy") failing for every caller that reads the block directly.
-- The RENDERED card was never affected — that path reads the blocks through
-- `_product_card_chrome()`, which is already definer — but a reader that
-- answers wrong is worse than one that refuses.
--
-- #2167's own QA round 1 wrote this fix as
-- 20261010100000_cmd2167_card_readers_definer.sql and it never reached live:
-- the commit was authored AFTER the branch had been merged into the deploy
-- lane, so CHANGE #1512 shipped the pre-QA tree. That file is not replayed
-- here, because it restates a `create or replace` body that predates CMD
-- #2169 and would silently drop `wish_icon` / `wish_tap` from the defaults.
--
-- ALTER, not CREATE OR REPLACE: the body stays exactly whatever is live, only
-- the security attribute changes. `card_show()` and `card_layout_screens()`
-- are already definer; restating them costs nothing and makes this file whole
-- on a fresh replay. Idempotent, no data touched, no grant widened —
-- `card_style()` stays closed to anon exactly as it is today.

alter function public.card_layout()         security definer;
alter function public.card_style()          security definer;
alter function public.card_show()           security definer;
alter function public.card_layout_screens() security definer;

-- A definer function must pin its search_path. All four already do; restated
-- so a fresh database cannot end up with a definer reader on a loose path.
alter function public.card_layout()         set search_path to 'public';
alter function public.card_style()          set search_path to 'public';
alter function public.card_show()           set search_path to 'public';
alter function public.card_layout_screens() set search_path to 'public';
