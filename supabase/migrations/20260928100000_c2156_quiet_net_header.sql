-- CMD #2156 (Om) — customer app on slow internet: one quiet pill, no
-- technical text, and one shared header with a constant 40dp logo tile.
--
-- 1. ui_copy: the green "back online" pill and the one small card a part
--    shows only if it still fails after the quiet retries.
-- 2. ui_design touch: the header band is the 64dp logo row (12 · 40 · 12),
--    plus the header's own measurements (tile, word, pill …). MERGED onto
--    whatever touch already holds — never replacing the block.
--
-- Idempotent: replayed on live once at deploy.

insert into public.ui_copy(key, value) values
  ('net.back_online', to_jsonb('Back online'::text)),
  ('net.load_failed', to_jsonb('Couldn''t load this. Check your internet.'::text)),
  ('net.try_again',   to_jsonb('Try again'::text))
on conflict (key) do nothing;

do $$
declare _touch jsonb;
begin
  if to_regprocedure('public.ui_design_set(jsonb)') is null then return; end if;
  select coalesce(value -> 'touch', '{}'::jsonb) into _touch
    from public.dev_runner_config where key = 'ui_design';
  perform public.ui_design_set(jsonb_build_object('touch',
    coalesce(_touch, '{}'::jsonb) || jsonb_build_object(
      'headerBand', 64,
      'headerTile', 40, 'headerTileRadius', 11, 'headerTileMark', 28,
      'headerTop', 12, 'headerWord', 29, 'headerWordGap', 6,
      'headerGap', 10, 'headerPill', 36, 'headerPillText', 14)));
end $$;
