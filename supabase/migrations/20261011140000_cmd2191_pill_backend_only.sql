-- CMD #2191 (Om, mid-build) — THE PILL PRINTS THE BACKEND, AND ONLY THE BACKEND.
--
-- Om: "the pill renders ONLY what header_status_pill() returns. Nothing else."
-- lines[0..2] verbatim, in that order, one at a time; no English word for the
-- pill anywhere in Dart; no fallback string, no default label, no null-coalesce
-- to a literal; colours, height, radius, text, max_w, min_w, pad_x, dot_size
-- from style{}; hold_ms and roll_ms from the response. Empty lines[] or a
-- failed RPC renders NOTHING.
--
-- The widget could only obey that if the payload were COMPLETE, and one
-- geometry value was missing from it: the gap between the dot and the words.
-- Dart was computing it (`Ds.space.x4 + Ds.space.x4 / 2`), which is a dp in
-- Dart — so it moves here, where every other pill dimension already lives.
-- 6.0 is exactly what that expression produced, so the pill does not move.
--
-- `pill.copy.style` is the author of the geometry; `header.pill_style` is the
-- legacy mirror its own note says to keep equal — both get the key, so a
-- caller on either door sees the same pill. Idempotent: re-running only
-- re-asserts dot_gap and never disturbs a value an admin has since tuned.

do $$
declare
  v_style jsonb;
begin
  -- The author.
  select value->'style' into v_style from public.app_settings where key = 'pill.copy';
  if v_style is not null and not (v_style ? 'dot_gap') then
    update public.app_settings
       set value = jsonb_set(value, '{style,dot_gap}', '6'::jsonb, true)
     where key = 'pill.copy';
  end if;

  -- The legacy mirror, kept equal.
  select value into v_style from public.app_settings where key = 'header.pill_style';
  if v_style is not null and not (v_style ? 'dot_gap') then
    update public.app_settings
       set value = jsonb_set(value, '{dot_gap}', '6'::jsonb, true)
     where key = 'header.pill_style';
  end if;
end $$;
