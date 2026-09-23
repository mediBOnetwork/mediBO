-- CMD #2175 — one 56 dp shell: header row hides on scroll, search pinned on
-- every tab, the status pill live from header_status_pill().
--
-- The backend owns every number, colour, icon and word in this command. The
-- shell reads ONE payload (shell_style()) and renders it verbatim; the search
-- bar's scope and placeholder are per-tab rows in that same payload, so adding
-- a tab or rewording a placeholder is an UPDATE, never a deploy.
--
-- Idempotent: every statement is a create-or-replace or an upsert.

-- ───────────────────────── 1. the shell's own style ─────────────────────────
-- common.height is THE height: the header row, the search bar, the banner, the
-- bottom nav rows and the floating "View cart" pill are all one number tall,
-- with one side inset, one corner radius and one gap between neighbours. Om's
-- redline is 56 / 14 / 28 / 10.
insert into public.app_settings (key, value) values ('shell.style', jsonb_build_object(
  'common', jsonb_build_object('height', 56, 'inset', 14, 'radius', 28, 'gap', 10),
  'colors', jsonb_build_object(
    'band',    '#FFFFFF',   -- the ONE white band behind header row + search
    'field',   '#F5F6F8',   -- the search field's fill
    'text',    '#111827',
    'muted',   '#6B7280',
    'divider', '#E5E7EB',
    'brand',   '#1B7A43'),
  'icons', jsonb_build_object(
    'search', 'search', 'back', 'arrow_back', 'bell', 'notifications_none',
    'clear', 'close'),
  'band', jsonb_build_object(
    -- The header row travels its own height and settles in 200 ms (Om).
    'settle_ms', 200, 'hysteresis', 40, 'trigger', 8, 'every_tab', true)
))
on conflict (key) do update set value = public.app_settings.value || excluded.value;

-- The pill's palette, per state, merged over a shared base by
-- header_status_pill(). Muted tints only — the design system's state colours.
insert into public.app_settings (key, value) values ('header.pill_style', jsonb_build_object(
  'height', 32, 'text', 14, 'radius', 16,
  'open',         jsonb_build_object('bg', '#D1FAE5', 'fg', '#065F46', 'dot', '#065F46'),
  'last_hour',    jsonb_build_object('bg', '#FEF3C7', 'fg', '#92400E', 'dot', '#92400E'),
  'closing',      jsonb_build_object('bg', '#FEF3C7', 'fg', '#92400E', 'dot', '#92400E'),
  'working',      jsonb_build_object('bg', '#EFF6FF', 'fg', '#1E40AF', 'dot', '#1E40AF'),
  'opening_soon', jsonb_build_object('bg', '#EFF6FF', 'fg', '#1E40AF', 'dot', '#1E40AF'),
  'opens_today',  jsonb_build_object('bg', '#F5F6F8', 'fg', '#6B7280', 'dot', '#6B7280'),
  'opens_tonight',jsonb_build_object('bg', '#F5F6F8', 'fg', '#6B7280', 'dot', '#6B7280'),
  'opens_tomorrow',jsonb_build_object('bg','#F5F6F8', 'fg', '#6B7280', 'dot', '#6B7280'),
  'closed_today', jsonb_build_object('bg', '#FEE2E2', 'fg', '#991B1B', 'dot', '#991B1B'),
  'idle',         jsonb_build_object('bg', '#F5F6F8', 'fg', '#6B7280', 'dot', '#6B7280')
))
on conflict (key) do update set value = public.app_settings.value || excluded.value;

-- ───────────────────────── 2. the per-tab search rows ───────────────────────
-- The placeholder is copy, so it lives in ui_copy and is reworded with an
-- UPDATE. The SCOPE is the rule: which surface the typed query is answered by.
insert into public.ui_copy (key, value) values
  ('shell.search_home',      '"Search medicines and companies"'::jsonb),
  ('shell.search_catalogue', '"Search medicines and companies"'::jsonb),
  ('shell.search_bulk',      '"Search medicines and companies"'::jsonb),
  ('shell.search_orders',    '"Search orders, items or a date"'::jsonb),
  ('shell.search_profile',   '"Search settings and features"'::jsonb)
on conflict (key) do nothing;

-- ───────────────────────── 3. header_status_pill() ──────────────────────────
-- ONE source for the pill. #2147's _order_hours_pill already words every state
-- of the zone's clock and is what the app has been showing; this makes it the
-- body of header_status_pill() rather than a second, thinner rule that would
-- disagree with it on the same screen. The palette comes from
-- app_settings['header.pill_style'] (base keys merged with the state's own),
-- and refresh_at is the wall-clock minute the text can next change.
create or replace function public.header_status_pill(p_zone smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_zone smallint := coalesce(p_zone, public.zone_effective(null), 1::smallint);
  v_open boolean;
  v_all  jsonb := coalesce((select value from app_settings where key = 'header.pill_style'), '{}'::jsonb);
  v_base jsonb;
  v_p    jsonb;
  v_pill jsonb;
  v_state text;
  v_refresh int;
begin
  begin
    v_open := public.order_hours_open_eff(v_zone);
  exception when others then v_open := false;
  end;
  v_p := coalesce(public._order_hours_pill(v_zone, v_open), '{}'::jsonb);
  v_pill := coalesce(v_p->'pill', '{}'::jsonb);
  v_state := coalesce(v_pill->>'state', 'idle');
  v_refresh := coalesce((v_pill->>'refresh_s')::int, 60);

  -- Base = every scalar key of the style (height/text/radius); the state's own
  -- block wins over it.
  v_base := (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
               from jsonb_each(v_all) as e(k, v)
              where jsonb_typeof(v) <> 'object');

  return jsonb_build_object(
    'show',  coalesce(nullif(v_pill->>'label',''), '') <> '',
    'state', v_state,
    'text',  coalesce(v_pill->>'label', ''),
    'zone_id', v_zone,
    'pulse', coalesce((v_pill->>'pulse')::boolean, false),
    'pulse_ms', coalesce((v_pill->>'pulse_ms')::int, 1600),
    'style', v_base || coalesce(v_all->v_state, coalesce(v_pill->'tone', '{}'::jsonb)),
    'refresh_s',  v_refresh,
    -- IST wall clock, so a client can re-read exactly when the words change.
    'refresh_at', to_char((public.now_eff() at time zone 'Asia/Kolkata')
                          + make_interval(secs => v_refresh), 'HH24:MI:SS'));
end $$;

-- ───────────────────────── 4. shell_style() ─────────────────────────────────
create or replace function public.shell_style()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select coalesce((select value from public.app_settings where key = 'shell.style'), '{}'::jsonb)
      || jsonb_build_object('pill', public.header_status_pill(null))
      || jsonb_build_object('search', jsonb_build_object(
           'tabs', jsonb_build_object(
             'home',      jsonb_build_object('scope', 'catalog',  'placeholder', public._c('shell.search_home')),
             'catalogue', jsonb_build_object('scope', 'catalog',  'placeholder', public._c('shell.search_catalogue')),
             'bulk',      jsonb_build_object('scope', 'catalog',  'placeholder', public._c('shell.search_bulk')),
             'orders',    jsonb_build_object('scope', 'orders',   'placeholder', public._c('shell.search_orders')),
             'profile',   jsonb_build_object('scope', 'profile',  'placeholder', public._c('shell.search_profile')))));
$$;

grant execute on function public.shell_style() to anon, authenticated;
grant execute on function public.header_status_pill(smallint) to anon, authenticated;

-- ───────────────────────── 5. Orders search matches a DATE ──────────────────
-- Om: "Orders → orders, items, any date." The existing match is order_code and
-- product_name; a typed date — '12 Sep', '12/09', '2026-09-12', 'Sep 12' — now
-- matches the order's own IST date string too. Matching is done on the
-- FORMATTED date so a shopper's own words are what is compared, never a parse
-- that can throw on free text.
create or replace function public._c2175_order_date_match(p_at timestamptz, p_q text)
returns boolean
language sql immutable set search_path to 'public'
as $$
  select case when coalesce(btrim(p_q),'') = '' or p_at is null then false else
    exists (
      select 1 from unnest(array[
        to_char(p_at at time zone 'Asia/Kolkata', 'FMDD Mon YYYY'),
        to_char(p_at at time zone 'Asia/Kolkata', 'FMDD Month YYYY'),
        to_char(p_at at time zone 'Asia/Kolkata', 'FMMon DD'),
        to_char(p_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD'),
        to_char(p_at at time zone 'Asia/Kolkata', 'DD/MM/YYYY'),
        to_char(p_at at time zone 'Asia/Kolkata', 'FMDD/FMMM'),
        to_char(p_at at time zone 'Asia/Kolkata', 'FMDay')
      ]) as s where s ilike '%'||btrim(p_q)||'%')
  end
$$;
grant execute on function public._c2175_order_date_match(timestamptz, text) to anon, authenticated;

-- The Orders list learns the date match, in place. Patched from the live
-- definition and guarded, so replaying this file is a no-op once it is in.
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'my_orders_screen_v2';
  if v_src is not null and position('_c2175_order_date_match' in v_src) = 0 then
    v_src := replace(v_src,
      'where oi.order_id = b.id and oi.product_name ilike ''%''||v_q||''%'')',
      'where oi.order_id = b.id and oi.product_name ilike ''%''||v_q||''%'')'
      || E'\n        or exists (select 1 from public.orders o'
      || E'\n                    where o.id = b.id'
      || E'\n                      and public._c2175_order_date_match(o.created_at, v_q))');
    execute v_src;
  end if;
end $do$;

-- ───────────────────────── 6. Profile search ────────────────────────────────
-- "Profile → settings and features." The tab's own payload is filtered, so
-- there is exactly one place that decides what the Profile tab contains and
-- the search can never show a row the tab itself would not.
create or replace function public.customer_profile_search(p_query text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_base jsonb := public.customer_profile_tab();
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
  v_sections jsonb;
  v_hits int := 0;
begin
  if v_q is null or coalesce((v_base->>'ok')::boolean, false) is not true then
    return v_base || jsonb_build_object('query', coalesce(v_q, ''), 'searching', false);
  end if;

  select coalesce(jsonb_agg(s2 order by ord), '[]'::jsonb) into v_sections
    from (
      select ord, jsonb_set(s, '{items}', items) as s2
        from (
          select ordinality as ord, s,
                 coalesce((select jsonb_agg(i)
                             from jsonb_array_elements(coalesce(s->'items','[]'::jsonb)) i
                            where (i->>'label')   ilike '%'||v_q||'%'
                               or (i->>'caption') ilike '%'||v_q||'%'
                               or (i->>'feature_key') ilike '%'||v_q||'%'),
                          '[]'::jsonb) as items
            from jsonb_array_elements(coalesce(v_base->'sections','[]'::jsonb))
                 with ordinality as t(s, ordinality)
        ) f
       where jsonb_array_length(items) > 0
    ) g;

  select coalesce(sum(jsonb_array_length(coalesce(s->'items','[]'::jsonb))), 0)::int
    into v_hits from jsonb_array_elements(v_sections) s;

  return v_base
      || jsonb_build_object(
           'sections', v_sections,
           'query', v_q,
           'searching', true,
           'result_count', v_hits,
           'empty_label', case when v_hits = 0
             then replace(public._c('shell.search_profile_empty'), '{q}', v_q)
             else coalesce(v_base->>'empty_label', '') end);
end $$;

grant execute on function public.customer_profile_search(text) to authenticated;
revoke execute on function public.customer_profile_search(text) from anon;

insert into public.ui_copy (key, value) values
  ('shell.search_profile_empty', '"No setting or feature matches “{q}”"'::jsonb)
on conflict (key) do nothing;

-- ───────────────────────── 7. the design tokens ─────────────────────────────
-- DESIGN CONTRACT: the app is styled from ui_boot().design. The shell's own
-- block joins it (Ds.shell) and the header numbers the existing tokens already
-- carry are moved onto Om's redline, so every consumer of them follows without
-- a second source of truth.
update public.dev_runner_config
   set value = coalesce(value, '{}'::jsonb)
     || jsonb_build_object(
          'shell', jsonb_build_object('height', 56, 'inset', 14, 'radius', 28, 'gap', 10),
          'touch', coalesce(value->'touch', '{}'::jsonb) || jsonb_build_object(
             'headerBand', 56,     -- the header ROW, and the distance it travels
             'headerTile', 40,     -- the logo tile and the bell box
             'headerTop', 8,       -- 8 + 40 + 8 = 56
             'headerGap', 10,
             'headerPill', 32,
             'headerPillText', 14,
             'headerSettleMs', 200,
             'navHideTravel', 8))
 where key = 'ui_design';

insert into public.dev_runner_config (key, value)
select 'ui_design', jsonb_build_object(
         'shell', jsonb_build_object('height', 56, 'inset', 14, 'radius', 28, 'gap', 10),
         'touch', jsonb_build_object('headerBand', 56, 'headerTile', 40, 'headerTop', 8,
                                     'headerGap', 10, 'headerPill', 32, 'headerPillText', 14,
                                     'headerSettleMs', 200, 'navHideTravel', 8))
 where not exists (select 1 from public.dev_runner_config where key = 'ui_design');
