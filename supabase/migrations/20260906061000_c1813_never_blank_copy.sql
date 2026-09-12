-- CMD #1813 — the words and the numbers behind "never a blank screen".
--
-- Every string the new never-blank layer prints, and every timing it obeys,
-- lives here. Changing how hard the app retries, how long it waits before it
-- admits it is slow, or what it says while it does, is an UPDATE to this table
-- — not a deploy.
insert into public.ui_copy (key, value) values
  -- Status lines. Quiet on purpose: the customer still has a working screen.
  ('net.updating',      to_jsonb('Updating…'::text)),
  ('net.saved_copy',    to_jsonb('Showing your last saved copy — still trying'::text)),
  ('net.first_try',     to_jsonb('Loading…'::text)),
  ('net.first_retry',   to_jsonb('Still connecting — trying again'::text)),
  ('storefront_screen.search_failed',
                        to_jsonb('That search did not come back — trying again'::text)),

  -- Behaviour the backend owns.
  -- Backoff between automatic retries, in ms; the last entry is the ceiling.
  ('net.retry_backoff_ms', to_jsonb('1000,2000,4000,8000,15000,30000'::text)),
  -- How long a refresh may run before the quiet line appears. Below this, a
  -- normal refresh says nothing at all and nothing flickers.
  ('net.slow_after_ms',    to_jsonb('2500'::text)),
  -- How long ONE attempt may run before the backoff takes over. Deliberately
  -- well under the ~15 s at which the app used to give up and blank the body:
  -- on 2026-09-06 every RPC stalled together at ~13.9 s, which was just inside
  -- the old timeout, so the customer waited the full fifteen seconds to be
  -- shown nothing.
  ('net.rpc_timeout_ms',   to_jsonb('9000'::text))
on conflict (key) do update set value = excluded.value;
