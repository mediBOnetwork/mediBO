-- CMD #1960 — Command detail: Lessons, QA and Journeys become collapsed
-- dropdowns so the conversation sits within a thumb's reach on a phone.
--
-- The three headers and the count chip are backend strings like every other
-- label on this screen: re-wording "Journeys" or turning the chip into
-- "4 items" is an UPDATE here, never a deploy.
--
-- `dev_queue.qa_section_title` ("QA & Journeys") stays untouched — it is the
-- old combined heading and other surfaces may still read it.
insert into ui_copy(key, value) values
  ('dev_queue.section_qa',          '"QA"'::jsonb),
  ('dev_queue.section_journeys',    '"Journeys"'::jsonb),
  ('dev_queue.section_count_chip',  '"{n}"'::jsonb),
  ('dev_queue.section_expand',      '"Show"'::jsonb),
  ('dev_queue.section_collapse',    '"Hide"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();
