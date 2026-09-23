-- CMD #2187 (Om, live on CHANGE #1527) — the pill is 32/16, and it is 270 wide.
--
-- Two things Om measured on the live header:
--
--   ALIGNMENT. The logo PNG is 65.2% artwork and 34.8% white, so a 40 dp tile
--   shows only 26 dp of GREEN. The row is aligned on the green, not the tile:
--   the tile is 49 (49 × 0.652 = 32), the bell glyph is 32 in a 40 tap box —
--   and the PILL is 32 tall with a 16 corner, in header.pill_style AND in
--   every state of pill.copy, so no state can drift off that centre line.
--
--   TRUNCATION. At 412 px there are 380 usable; logo 49 + gap 10 + bell 40
--   leaves 281 free. The cap was max_w 210, whose text area is 171 — and the
--   old 22-character label needed ~176, so it ellipsised ("Opens tonig…") with
--   281 px sitting unused. max_w becomes 270. With lines[] the longest line
--   anywhere is 19 characters, so it cannot truncate down to 320 px either.
--
-- Idempotent: jsonb_set on keys that already exist, and a full re-write of the
-- states block, so re-running lands the same row.

-- The shared geometry.
update public.app_settings
   set value = value
             || jsonb_build_object('style',
                  coalesce(value->'style', '{}'::jsonb)
                  || jsonb_build_object('height', 32, 'radius', 16, 'max_w', 270))
 where key = 'pill.copy';

-- …and the same two numbers on every state, so a state override can never put
-- the pill back off the row's centre line.
update public.app_settings
   set value = jsonb_set(value, '{states}',
         (select coalesce(jsonb_object_agg(k, v || jsonb_build_object('height', 32, 'radius', 16)), '{}'::jsonb)
            from jsonb_each(value->'states') as e(k, v)))
 where key = 'pill.copy'
   and jsonb_typeof(value->'states') = 'object';

-- The palette row #2175 seeded carries the base height/radius too.
update public.app_settings
   set value = value || jsonb_build_object('height', 32, 'radius', 16)
 where key = 'header.pill_style';
