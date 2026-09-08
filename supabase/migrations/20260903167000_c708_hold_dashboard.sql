-- CHANGE #708 (6/6b) — the count of parked orders, where the ops team looks.
--
-- The board header already renders `chips[]` generically — tone, count and a
-- finished label per chip — so the count of held orders is a FOURTH CHIP and
-- needs no Dart at all. order_hold_count() serves the same number to any other
-- tile that wants it later.
--
-- Deliberately NOT a dashboard_metric row: the strip is fed from
-- dashboard_daily columns, and a live count of parked orders is not a daily
-- aggregate — it would have meant a new column, a new backfill and a number
-- that is only correct at midnight.
-- Idempotent.

do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'ops_board';
  if v_def is not null and v_def not like '%order_hold_count%' then
    v_new := replace(v_def,
      '      jsonb_build_object(''tone'', ''green'', ''count'', v_green,
        ''label'', replace(public.uic(''ops_board.chip_green'', ''On time {n}''), ''{n}'', v_green::text))),',
      '      jsonb_build_object(''tone'', ''green'', ''count'', v_green,
        ''label'', replace(public.uic(''ops_board.chip_green'', ''On time {n}''), ''{n}'', v_green::text)))
      -- CHANGE #708 — a fourth chip, only when something IS parked. The header
      -- renders chips[] generically, so the count needs no client change.
      || case when coalesce((public.order_hold_count(v_zone)->>''count'')::int, 0) > 0
              then jsonb_build_array(jsonb_build_object(
                     ''tone'', ''amber'',
                     ''count'', (public.order_hold_count(v_zone)->>''count'')::int,
                     ''label'', public.order_hold_count(v_zone)->>''badge''))
              else ''[]''::jsonb end,
    ''hold_count'', public.order_hold_count(v_zone),');
    if v_new = v_def then raise exception 'c708: ops_board chips anchor missing'; end if;
    execute v_new;
  end if;
end $do$;
