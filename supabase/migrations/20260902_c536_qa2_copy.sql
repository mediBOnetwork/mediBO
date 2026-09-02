-- CHANGE #536 QA round 2 — the copy for a My Shop load that never landed.
--
-- The failure state read its wording out of the PAYLOAD (`res['empty_message']`,
-- `res['retry_label']`), and on a failed load there is no payload: `res` is null
-- by definition, so the "one-message state" rendered one empty string and one
-- empty button. A blank page with nothing to read and nothing to press.
--
-- The copy for a payload that never arrived cannot come from the payload. It
-- comes from here, so re-wording it stays an UPDATE and never a deploy.
--
-- Idempotent: re-applying this migration re-asserts the same two rows.
insert into public.ui_copy (key, value) values
  ('my_shop.load_failed',
   to_jsonb('We could not load your shop just now. Check your connection and try again.'::text)),
  ('my_shop.retry', to_jsonb('Try again'::text))
on conflict (key) do update set value = excluded.value;
