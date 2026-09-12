-- CHANGE #326 — the partner home's two missing states, worded in the backend.
--
-- 1. partner_home() failing left the screen drawing an empty card: the widget's
--    catch-all set an empty payload, is_partner read false, and the empty state
--    printed two empty strings. Nothing to read, nothing to tap.
-- 2. A partner had NO way to sign out at all: the home is a bare Scaffold with
--    no app bar and no profile menu, and a partner never reaches the customer
--    shell that owns the logout item.
--
-- These four strings live in ui_copy (not partner_home_copy) on purpose: the
-- error state has to render when partner_home() itself is what failed, and
-- ui_copy is already cached at boot. Idempotent.
insert into ui_copy (key, value) values
  ('partner.error_title',    to_jsonb('Could not load your partner home'::text)),
  ('partner.error_message',  to_jsonb('Check your connection and try again.'::text)),
  ('partner.retry_label',    to_jsonb('Retry'::text)),
  ('partner.sign_out_label', to_jsonb('Sign out'::text))
on conflict (key) do nothing;
