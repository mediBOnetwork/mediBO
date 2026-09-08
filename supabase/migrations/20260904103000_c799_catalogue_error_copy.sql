-- CHANGE #799 — the catalogue's error state is the BACKEND's sentence.
--
-- The widget's own docstring already promised "the BACKEND's copy plus Retry —
-- never a Dart apology", but it was handed e.toString(): a live anon visit on
-- 4 Sep painted
--   "PostgrestException(message: canceling statement due to statement timeout,
--    code: 57014, details: , hint: null)"
-- across the middle of the catalogue. These two keys are what it prints now;
-- the exception goes to the render log only.
insert into public.ui_copy (key, value) values
  ('catalogue.load_error', '"The catalogue didn''t load. Check your connection and try again."'::jsonb),
  ('catalogue.retry',      '"Retry"'::jsonb)
on conflict (key) do update set value = excluded.value
  where public.ui_copy.key = 'catalogue.load_error';
