-- CMD #2191 (Om, mid-build) — ONE WORDING THAT FITS THE PHONE.
--
-- 20261011160000 retired the narrow tier so the pill prints ONE set of words
-- at every width — Om: "pill should show exact what backend gives". That made
-- the FULL wording the only wording, so the full wording now has to fit a
-- phone whole, which is what the narrow tier used to be for.
--
-- Measured with the app's own font (DM Sans 600 @ style.text = 14) against the
-- room the header row actually leaves a 360 dp phone — page padding 14·2, the
-- wordmark 49, gap_after_word 10 and 40 for the bell — i.e. 233 px of pill,
-- padding and dot included. Twenty-nine of the thirty-two lines already fit.
-- Three did not, and only those three are reworded here:
--
--   Ordering opens in {n} minutes  237.4  ->  Ordering opens in {n} min   207.7
--   We are accepting your orders   237.2  ->  We are accepting orders     203.7
--   We are packing today's orders  241.8  ->  We are packing orders       189.2
--
-- 'Ordering opens in 1 minute' fitted at 217.4 but is the same sentence one
-- number down, so it moves with its family rather than leaving the pill saying
-- "min" at 45 and "minute" at 1.
--
-- c2191_pill_width_test.dart measures every one of these on the VM, so the
-- next edit to this copy is caught in the suite instead of on a phone.
--
-- Idempotent: each key is set only while it still holds the long form.

do $$
declare
  v jsonb;
begin
  select value into v from public.app_settings where key = 'pill.copy';
  if v is null then return; end if;

  if v #>> '{time,opens_in_minutes}' = 'Ordering opens in {n} minutes' then
    v := jsonb_set(v, '{time,opens_in_minutes}', '"Ordering opens in {n} min"');
  end if;
  if v #>> '{time,opens_in_minute}' = 'Ordering opens in 1 minute' then
    v := jsonb_set(v, '{time,opens_in_minute}', '"Ordering opens in 1 min"');
  end if;

  -- The activity words live under whichever block names them; both the
  -- stage map and any state default are rewritten by value, so a key that
  -- moves between releases still lands.
  v := replace(v::text, 'We are accepting your orders', 'We are accepting orders')::jsonb;
  v := replace(v::text, 'We are packing today''s orders', 'We are packing orders')::jsonb;
  v := replace(v::text, 'We are packing today’s orders', 'We are packing orders')::jsonb;

  update public.app_settings set value = v where key = 'pill.copy' and value is distinct from v;
end $$;

-- The same three sentences wherever else the backend authors them, so the
-- pill and every other surface keep saying the same thing.
do $$
declare r record; nv jsonb;
begin
  for r in
    select key, value from public.app_settings
     where value::text like '%We are packing today%orders%'
        or value::text like '%We are accepting your orders%'
        or value::text like '%Ordering opens in {n} minutes%'
  loop
    nv := replace(replace(replace(replace(r.value::text,
            'We are accepting your orders', 'We are accepting orders'),
            'We are packing today''s orders', 'We are packing orders'),
            'We are packing today’s orders', 'We are packing orders'),
            'Ordering opens in {n} minutes', 'Ordering opens in {n} min')::jsonb;
    update public.app_settings set value = nv where key = r.key and value is distinct from nv;
  end loop;
end $$;
