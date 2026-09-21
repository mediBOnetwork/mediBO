-- CMD #2141 — Documents step, final rules (Om, 22 Sep 2026).
--  • Mandatory means mandatory: customer "Submit registration" stays off until
--    every Mandatory paper is in; this is the one line printed above it.
--  • The rest of the round is frontend over the live backend (dont_have.show,
--    required_complete, row.sub, row.edit, custreg_doc_read_save/_edit).
-- Idempotent: an existing wording is never overwritten by a replay.

insert into public.ui_copy(key, value) values
  ('custreg.v4_submit_gate', to_jsonb('Add the mandatory papers to submit'::text))
on conflict (key) do nothing;
