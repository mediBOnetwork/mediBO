-- CMD #2164 — header exact redline (undo CHANGE #1494 sizes).
-- Idempotent: merges the redline numbers into ui_design.touch and writes the
-- new ui_design.header block. Re-running yields the same row.
UPDATE dev_runner_config
   SET value = jsonb_set(
         jsonb_set(value, '{touch}',
           coalesce(value->'touch','{}'::jsonb) || jsonb_build_object(
             'headerWord', 26, 'headerWordGap', 8, 'headerGap', 10,
             'headerPill', 32, 'headerPillText', 14, 'headerTile', 40,
             'headerTileRadius', 11, 'headerTileMark', 28, 'headerTop', 12,
             'headerBand', 64)),
         '{header}',
         coalesce(value->'header','{}'::jsonb) || jsonb_build_object(
           'tile', '#1B8A3E', 'wordMedi', '#1B7A43', 'wordBo', '#2FA24F',
           'line', '#EEF0EE', 'searchBorder', '#E5E7EB', 'placeholder', '#6B7280',
           'wordNarrow', 22, 'narrowBelow', 360, 'wordSpacing', -0.4,
           'markWeight', 900, 'wordWeight', 800, 'pillRadius', 16,
           'search', 48, 'searchRadius', 24, 'searchCompactRadius', 20,
           'searchBorderWidth', 1.5, 'searchText', 16, 'searchIcon', 22,
           'searchPad', 16, 'iconGap', 12, 'bellIcon', 24, 'lineWidth', 1,
           'fadeMs', 200))
 WHERE key = 'ui_design';
