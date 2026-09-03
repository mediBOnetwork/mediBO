-- CHANGE #704 — design-QA follow-up on the agency dispatch board.
--
-- The board shipped with two states it could not describe: a bare spinner while
-- it loaded, and — if agency_dispatch_board() itself threw (offline, a dropped
-- session) — a BLANK page, because the "not allowed" branch printed
-- board['message'] and a payload that never arrived has no message. A blank
-- screen with no words and no way back is the one state a dispatcher cannot act
-- on, so the screen now paints a skeleton while it loads and, on a failure,
-- prints these sentences with a Retry.
--
-- They live in ui_copy rather than in the failure payload on purpose: the
-- failure is the payload not arriving, so the words for it must already be on
-- the device (ui_boot caches ui_copy). Idempotent: re-running this is a no-op.

insert into public.ui_copy(key, value) values
  ('agency.load_error',   to_jsonb('Could not load your dispatch board. Check the connection and try again.'::text)),
  ('agency.retry',        to_jsonb('Try again'::text)),
  ('agency.assign_error', to_jsonb('Could not send that stop to your rider. Try again.'::text))
on conflict (key) do nothing;
