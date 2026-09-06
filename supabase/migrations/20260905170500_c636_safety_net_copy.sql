-- CHANGE #636 — the safety net's words.
--
-- Split out of the main migration on purpose: this is the ONE part that names
-- a control-plane table, so the replay routes it to both databases while the
-- schema itself stays production-only. Wording is an UPDATE, never a deploy.

insert into public.ui_copy (key, value) values
  ('safety_net.title',        to_jsonb('Safety net'::text)),
  ('safety_net.subtitle',     to_jsonb('Tests the system generates for itself — nobody writes these cases.'::text)),
  ('safety_net.run_label',    to_jsonb('Run the safety net'::text)),
  ('safety_net.running_label',to_jsonb('Running…'::text)),
  ('safety_net.never_label',  to_jsonb('Never run yet'::text)),
  ('safety_net.never_sub',    to_jsonb('Run it once to generate the matrix, the fuzz corpus and the oracle baseline.'::text)),
  ('safety_net.auth_title',   to_jsonb('Auth matrix'::text)),
  ('safety_net.fuzz_title',   to_jsonb('Property fuzzing'::text)),
  ('safety_net.inv_title',    to_jsonb('Invariant oracles'::text)),
  ('safety_net.empty_row',    to_jsonb('Nothing to answer for.'::text)),
  ('safety_net.footnote',     to_jsonb('Every case is a pure function of its seed, so a failure replays byte for byte. Nothing a case does survives it — each call runs in a subtransaction that is always rolled back.'::text))
on conflict (key) do update set value = excluded.value;
