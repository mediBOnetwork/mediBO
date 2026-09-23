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
      || jsonb_build_object('search',
           -- Om on #1521: "Add search.box_h, search.pad_y, search.text_align_v
           -- to shell_style(); Flutter reads them, nothing hardcoded." They are
           -- REPORTED from the design tokens (`ui_design.shell`, which is what
           -- ui_boot().design ships and what Ds.shell parses) rather than
           -- authored a second time here, so the row's geometry has exactly one
           -- author and `ui_design_set` still moves it with no deploy.
           coalesce((select jsonb_build_object(
                       'box_h',        value->'shell'->'box_h',
                       'pad_y',        value->'shell'->'pad_y',
                       'box_radius',   value->'shell'->'box_radius',
                       'text_align_v', value->'shell'->'text_align_v')
                       from public.dev_runner_config where key = 'ui_design'), '{}'::jsonb)
           || jsonb_build_object(
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

-- ───────────────────────── 8. the "View cart" pill's height ─────────────────
-- The pill is the fifth piece of chrome on Om's one height, and its shape is a
-- `storefront_ui_label` row (CMD #2089), so this is where 56 goes for it.
update public.storefront_ui_label set value = '56'
 where key = 'cart_pill_ui_height' and value <> '56';

-- ───────────── 9. Om on #1521 — 56 is the ROW, gaps included ────────────────
-- "56 dp is the TOTAL of each row measured outside edge to outside edge, GAPS
-- INCLUDED." The first cut read it as "the box is 56" and put the gap outside,
-- which made the search block 76 and the box look fat beside the 40 dp logo
-- tile. The row is pad_y + box_h + pad_y; the box is the tile's own 40 at
-- radius 20; the text sits on the box's true vertical centre.
-- ONE author: the numbers go into the design tokens, and shell_style() above
-- reports them back out under `search`, so the payload and the theme can never
-- disagree and `ui_design_set({'shell': {...}})` still moves both with no deploy.
update public.dev_runner_config
   set value = value || jsonb_build_object(
         'shell', coalesce(value->'shell', '{}'::jsonb) || jsonb_build_object(
            'box_h', 40, 'pad_y', 8, 'box_radius', 20, 'text_align_v', 'center'))
 where key = 'ui_design';

-- ────────── 10. Om on #1523 — the pill is the tile's size, not a chip ───────
-- "Pill is 40 dp radius 20 — same as the logo tile and the search box." The
-- three round things on the header's one row were 40 (tile), 32 (pill) and 40
-- (box); the odd one out read as a chip stuck beside the logo rather than part
-- of the same line. Both numbers are tokens (`touch.headerPill`,
-- `header.pillRadius`), so this is the whole change — the pill widget already
-- asks for them and re-sizing it again stays one `ui_design_set`.
update public.dev_runner_config
   set value = value
     || jsonb_build_object('touch',
          coalesce(value->'touch', '{}'::jsonb) || jsonb_build_object('headerPill', 40))
     || jsonb_build_object('header',
          coalesce(value->'header', '{}'::jsonb) || jsonb_build_object('pillRadius', 20))
 where key = 'ui_design';

-- ────────── 11. the pill's payload reports the SAME tokens it is drawn from ──
-- `header.pill_style` authored 32/16 of its own while `ui_design` says 40/20,
-- so `shell_style().pill.style` and the theme the pill is actually drawn with
-- disagreed on the same screen. The scalars are REPORTED from the design
-- tokens instead of authored twice — one author, and `ui_design_set` still
-- moves both with no deploy. The per-state colour blocks stay where they are.
update public.app_settings
   set value = value || coalesce((
         select jsonb_build_object(
                  'height', coalesce(value->'touch'->'headerPill', to_jsonb(40)),
                  'radius', coalesce(value->'header'->'pillRadius', to_jsonb(20)),
                  'text',   coalesce(value->'touch'->'headerPillText', to_jsonb(14)))
           from public.dev_runner_config where key = 'ui_design'), '{}'::jsonb),
       updated_at = now()
 where key = 'header.pill_style';


-- ────────── 12. Om on #1521 — the pill's SCOPE, and no Raipur default ───────
-- "Partner gets its clamped zone, admin the header picker, an APPROVED
-- customer with a zone gets that zone, and everyone else — signed out, or
-- registered but not approved — gets universal (open if any zone is open, else
-- the zone opening soonest). Flutter must not pick a zone itself and must not
-- default to Raipur."
--
-- The old pill ended in `coalesce(..., zone_effective(null), 1)`, and
-- zone_effective's own last resort is the DEFAULT zone — which is Raipur. So a
-- signed-out visitor was shown Raipur's clock as if it were their own, and
-- nothing in the payload said otherwise. The scope is explicit now and the
-- universal pick is the backend's, so the header renders a sentence it was
-- handed either way and Dart still chooses nothing.

-- 12a. The universal zone: open beats closed; among the closed, the one that
--      opens soonest from now (IST), a time already past today sorting after
--      one still to come. Active zones only; the default zone is the
--      TIE-BREAK, never the answer on its own.
create or replace function public.header_universal_zone()
returns smallint
language sql stable security definer set search_path to 'public'
as $$
  with n as (select (public.now_eff() at time zone 'Asia/Kolkata')::time as t),
  z as (
    select zo.id, zo.is_default, oh.auto_open_time,
           coalesce(public.order_hours_open_eff(zo.id), false) as open_now
      from public.zones zo
      left join public.order_hours oh on oh.zone_id = zo.id
     where zo.is_active)
  select z.id from z, n
   order by z.open_now desc,
            case when z.auto_open_time is null then 2
                 when z.auto_open_time > n.t   then 0
                 else 1 end,
            z.auto_open_time nulls last, z.is_default desc, z.id
   limit 1;
$$;
grant execute on function public.header_universal_zone() to anon, authenticated;

-- 12b. ONE resolver, in Om's own order, for every surface that shows the
--      clock. {zone, scope} — 'zone' when this viewer owns one, 'universal'
--      when nobody claims them. Each step is a CLAMP; none of them is a
--      default.
create or replace function public.header_zone_scope(p_zone smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_zone smallint := p_zone; v_role text; v_ok boolean;
begin
  if v_zone is null then
    begin v_zone := public.partner_zone_id(); exception when others then v_zone := null; end;
  end if;
  if v_zone is null then
    begin
      v_role := coalesce(public.get_my_role(), '');
      if v_role in ('admin', 'super_admin') then v_zone := public.admin_active_zone(); end if;
    exception when others then v_zone := null;
    end;
  end if;
  if v_zone is null then
    -- An APPROVED customer with a zone. Registered-but-not-approved is not a
    -- zone: they are shown the universal clock like any visitor.
    begin
      select p.zone_id, coalesce(p.approved, false) into v_zone, v_ok
        from pharmacy_profiles p where p.user_id = auth.uid() limit 1;
      if not coalesce(v_ok, false) then v_zone := null; end if;
    exception when others then v_zone := null;
    end;
  end if;
  if v_zone is not null then
    return jsonb_build_object('zone', v_zone, 'scope', 'zone');
  end if;
  begin v_zone := public.header_universal_zone(); exception when others then v_zone := null; end;
  return jsonb_build_object(
    'zone', coalesce(v_zone, (select id from zones where is_default limit 1)),
    'scope', 'universal');
end $$;
grant execute on function public.header_zone_scope(smallint) to anon, authenticated;

-- 12c. header_status_pill() — the same payload, plus `scope`, on the resolver.
create or replace function public.header_status_pill(p_zone smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_zs   jsonb := public.header_zone_scope(p_zone);
  v_zone smallint := (v_zs->>'zone')::smallint;
  v_open boolean;
  v_all  jsonb := coalesce((select value from app_settings where key = 'header.pill_style'), '{}'::jsonb);
  v_base jsonb;
  v_p    jsonb;
  v_pill jsonb;
  v_state text;
  v_refresh int;
begin
  begin v_open := public.order_hours_open_eff(v_zone);
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
    'scope', v_zs->>'scope',
    'zone_id', v_zone,
    'pulse', coalesce((v_pill->>'pulse')::boolean, false),
    'pulse_ms', coalesce((v_pill->>'pulse_ms')::int, 1600),
    'style', v_base || coalesce(v_all->v_state, coalesce(v_pill->'tone', '{}'::jsonb)),
    'refresh_s',  v_refresh,
    -- IST wall clock, so a client can re-read exactly when the words change.
    'refresh_at', to_char((public.now_eff() at time zone 'Asia/Kolkata')
                          + make_interval(secs => v_refresh), 'HH24:MI:SS'));
end $$;
grant execute on function public.header_status_pill(smallint) to anon, authenticated;

-- 12d. The pill the app actually draws is `order_hours_state().pill`, so the
--      SAME resolver answers there — one author, one answer, whichever door
--      the app knocks on. Everything else in that payload is untouched, and
--      for a partner, an admin or an approved customer the zone it resolves is
--      byte-for-byte what zone_effective() was already returning.
create or replace function public.order_hours_state(p_zone smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  h order_hours%rowtype; v_now time := (public.now_eff() at time zone 'Asia/Kolkata')::time;
  v_open boolean;
  v_mins int; v_next text; v_zone smallint; v_zname text;
  v_zs jsonb := public.header_zone_scope(p_zone);
begin
  v_zone := (v_zs->>'zone')::smallint;
  select * into h from order_hours where zone_id = v_zone;
  if h.id is null then select * into h from order_hours order by id limit 1; end if;
  select name into v_zname from zones where id = v_zone;
  v_open := public.order_hours_open_eff(v_zone);

  if v_open and h.auto_close_time is not null then
    v_mins := (extract(epoch from (h.auto_close_time - v_now)) / 60)::int;
    if v_mins < 0 then v_mins := v_mins + 1440; end if;
    v_next := 'Auto-closes in ' || (v_mins/60) || 'h ' || lpad((v_mins%60)::text,2,'0') || 'm';
  elsif (not v_open) and h.auto_open_time is not null then
    v_mins := (extract(epoch from (h.auto_open_time - v_now)) / 60)::int;
    if v_mins < 0 then v_mins := v_mins + 1440; end if;
    v_next := 'Auto-opens in ' || (v_mins/60) || 'h ' || lpad((v_mins%60)::text,2,'0') || 'm';
  end if;

  return jsonb_build_object(
    'is_open', v_open, 'can_order', v_open,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,''),
    'scope', v_zs->>'scope',
    'status_label', case when v_open then 'OPEN' else 'CLOSED' end,
    'status_since', case when v_open
      then 'Open since ' || to_char(h.last_opened_at at time zone 'Asia/Kolkata','FMHH12:MI AM')
      else 'Closed since ' || to_char(h.last_closed_at at time zone 'Asia/Kolkata','FMHH12:MI AM') end,
    'schedule_label',
      coalesce('Opens ' || to_char(h.auto_open_time,'FMHH12:MI AM'), 'No auto-open') || '  ·  ' ||
      coalesce('Closes ' || to_char(h.auto_close_time,'FMHH12:MI AM'), 'No auto-close'),
    'next_change_label', v_next,
    'auto_open_label',  to_char(h.auto_open_time,'FMHH12:MI AM'),
    'auto_close_label', to_char(h.auto_close_time,'FMHH12:MI AM'),
    'auto_open_time',   to_char(h.auto_open_time,'HH24:MI'),
    'auto_close_time',  to_char(h.auto_close_time,'HH24:MI'),
    'now_label',        to_char(public.now_eff() at time zone 'Asia/Kolkata','FMHH12:MI AM'),
    'closed_message', h.closed_message,
    'button_label',   case when v_open then 'Place Order' else 'Order hours closed' end,
    'popup_title',    case when not v_open then 'Order hours are closed' end,
    'popup_message',  case when not v_open then h.closed_message end,
    'updated_at', h.updated_at)
    || public._order_hours_pill(v_zone, v_open)
    -- The pill (and only the pill) is re-taken from the ONE pill author, so
    -- the header's chip, its palette and its refresh_at are the same object
    -- shell_style() ships.
    -- The zone is already resolved, so the pill is asked for THAT zone and
    -- wears the scope this call resolved — passing a zone in would otherwise
    -- make the pill report 'zone' to a visitor who has none.
    || jsonb_build_object('pill',
         public.header_status_pill(v_zone) || jsonb_build_object('scope', v_zs->>'scope'));
end $$;
grant execute on function public.order_hours_state(smallint) to anon, authenticated;
