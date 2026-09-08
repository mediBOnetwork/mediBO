-- CHANGE #460 — design-QA gate, check 6: "errors show backend copy + Retry".
-- The three new screens set {'ok': false} with no message when the RPC THROWS
-- (a network blip), so their error branch rendered an empty centred Text — a
-- blank screen with no way back. These keys give that state words and a button;
-- they are read through c() from the boot copy, which is already in memory when
-- the screen's own RPC is the thing that failed.
insert into public.ui_copy (key, value) values
  ('cust_profile.load_failed',    to_jsonb('Could not load your details just now.'::text)),
  ('cust_profile.retry',          to_jsonb('Try again'::text)),
  ('cust_addr.load_failed',       to_jsonb('Could not load your delivery addresses just now.'::text)),
  ('cust_addr.retry',             to_jsonb('Try again'::text)),
  ('catalogue_health.load_failed',to_jsonb('Could not load catalogue health just now.'::text)),
  ('catalogue_health.retry',      to_jsonb('Try again'::text))
on conflict (key) do nothing;
