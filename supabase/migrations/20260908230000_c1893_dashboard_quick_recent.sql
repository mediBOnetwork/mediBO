-- CMD #1893 — Dashboard: pinned Quick actions, Recently used, and the last
-- Also-here strip retired.
--
-- Three things live here, and all three are BACKEND decisions:
--   1. dashboard_home() now also prints the user's own two personal rows —
--      `quick` (their nav_pin pins) and `recent` (their last six nav_usage
--      opens). Their labels, their empty line, their column count and the
--      Pin/Unpin wording all arrive in the payload; Dart chooses none of it.
--   2. Every tile in every row carries `pinned` and the exact `pin_action_label`
--      the long-press sheet prints, so the sheet has no string of its own.
--   3. nav_dashboard_orphan_check() is the gate item 3 asks for: a feature that
--      used to hang off an "Also here" chip and has no way onto the Dashboard
--      is an orphan, and the deploy fails on it.
--
-- Idempotent: every statement is create-or-replace / on-conflict.

-- ── 1. Copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('dashboard_home.quick_label',   '"QUICK ACTIONS"'::jsonb),
  ('dashboard_home.quick_empty',   '"Long-press any tile to pin it here"'::jsonb),
  ('dashboard_home.recent_label',  '"RECENTLY USED"'::jsonb),
  ('nav_pin.pin_action',           '"Pin to Quick actions"'::jsonb),
  ('nav_pin.unpin_action',         '"Remove from Quick actions"'::jsonb),
  ('nav_pin.pinned_toast',         '"Pinned to Quick actions."'::jsonb),
  ('nav_pin.unpinned_toast',       '"Removed from Quick actions."'::jsonb),
  ('nav_pin.signin',               '"Sign in first."'::jsonb),
  ('nav_pin.not_registered',       '"That feature is not in the registry."'::jsonb)
on conflict (key) do nothing;

-- ── 2. One copy of the access rule, two views of it ─────────────────────────
-- _dashboard_visible() was the only door onto a dashboard tile, and it filtered
-- out every feature without a dashboard_section. Quick actions and Recently
-- used need the SAME access predicate over a WIDER set (a pin or an open can
-- name a feature that has no section of its own), so the body moves here once
-- and the old function becomes the p_all => false case of it. No caller of
-- _dashboard_visible() changes.
create or replace function public._dashboard_tiles(p_all boolean default false)
returns table(feature_key text, label text, icon_key text, route_key text,
              sort_order integer, category text, surface text, badge_source text,
              badge_noun text, badge_tone text, deep_link text, description text,
              dashboard_section text, tab_screen text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with me as (
    select coalesce(public.get_my_role(),'none') as role,
           public.my_partner_id() as partner,
           exists (select 1 from public.admins a
                    where a.id::text = public.my_admin_id()::text
                      and coalesce(a.is_super,false)) as is_super
  ), acc as (select * from public._staff_access())
  select f.feature_key,
         coalesce(nullif(f.dashboard_label,''), f.label) as label,
         f.icon_key, f.route_key, f.sort_order,
         f.category, f.surface, f.badge_source, f.badge_noun, f.badge_tone,
         f.deep_link, f.description, f.dashboard_section, f.tab_screen
    from public.feature_registry f
    cross join me
    left join acc on acc.feature_key = coalesce(nullif(f.canonical_key,''), f.feature_key)
   where f.is_active
     and (p_all or coalesce(f.dashboard_section,'') <> '')
     and coalesce(f.route_key,'') <> ''
     and case when me.partner is not null
              then f.partner_eligible and coalesce(acc.level,'none') <> 'none'
              when f.surface = 'dev_tools' then me.role = 'super_admin' and me.role = any (f.roles_allowed)
              else me.role = any (f.roles_allowed)
                   and (me.is_super or coalesce(acc.level,'none') <> 'none') end
$function$;

create or replace function public._dashboard_visible()
returns table(feature_key text, label text, icon_key text, route_key text,
              sort_order integer, category text, surface text, badge_source text,
              badge_noun text, badge_tone text, deep_link text, description text,
              dashboard_section text, tab_screen text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select * from public._dashboard_tiles(false)
$function$;

-- ── 3. dashboard_home(): six sections, plus the two personal rows ───────────
create or replace function public.dashboard_home()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_uid      uuid := auth.uid();
  v_role     text := coalesce(public.get_my_role(),'none');
  v_counts   jsonb := '{}'::jsonb;
  v_sections jsonb := '[]'::jsonb;
  v_quick    jsonb := '[]'::jsonb;
  v_recent   jsonb := '[]'::jsonb;
  v_n        int := 0;
  v_pin      text := public._c('nav_pin.pin_action');
  v_unpin    text := public._c('nav_pin.unpin_action');
begin
  if v_uid is null or v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object(
      'ok', false, 'error', 'not_authorized',
      'sections', '[]'::jsonb, 'items_count', 0,
      'title', public._c('dashboard_home.title'),
      'message', public._c('dashboard_home.not_authorized'),
      'empty_label', public._c('dashboard_home.empty_label'));
  end if;

  begin
    v_counts := public.dashboard_badge_counts();
  exception when others then v_counts := '{}'::jsonb;
  end;

  with src as (
    -- EVERY door this login may open, section or no section. The two personal
    -- rows read the wide set; the six sections still read the narrow one.
    select v.*,
           exists (select 1 from public.nav_pin p
                    where p.user_id = v_uid and p.feature_key = v.feature_key) as pinned,
           (select max(u.opened_at) from public.nav_usage u
             where u.user_id = v_uid and u.feature_key = v.feature_key) as last_at
      from public._dashboard_tiles(true) v
  ), tile as (
    select s.feature_key,
           s.dashboard_section as sec,
           s.sort_order,
           s.label,
           s.pinned,
           s.last_at,
           coalesce((v_counts ->> s.badge_source)::bigint, 0) as badge_count,
           jsonb_build_object(
             'feature_key', s.feature_key,
             'label',       s.label,
             'icon_key',    s.icon_key,
             'icon_letter', upper(left(s.label,1)),
             'route_key',   s.route_key,
             'deep_link',   s.deep_link,
             'tool_key',    case when s.surface = 'dev_tools' then s.route_key else null end,
             'tab_host',    case s.surface when 'customer_tab' then 'customers'
                                           when 'supplier_tab' then 'suppliers'
                                           else null end,
             'tab_key',     nullif(s.tab_screen,''),
             'description', coalesce(s.description,''),
             'badge_count', coalesce((v_counts ->> s.badge_source)::bigint, 0),
             'badge_label', case when coalesce((v_counts ->> s.badge_source)::bigint,0) > 0
                                 then (v_counts ->> s.badge_source) || ' ' ||
                                      coalesce(nullif(s.badge_noun,''), lower(s.label))
                                 else null end,
             'badge_tone',  coalesce(nullif(s.badge_tone,''),
                              case when s.dashboard_section = 'needs_now' then 'warn' else 'info' end),
             -- The long-press sheet prints THIS, verbatim. Dart never picks
             -- between "Pin" and "Unpin".
             'pinned',           s.pinned,
             'pin_action_label', case when s.pinned then v_unpin else v_pin end
           ) as js
      from src s
  ), kept as (
    select t.*, sc.section_key, sc.sort_order as sec_sort, sc.label_key, sc.show_when_empty
      from public.dashboard_section sc
      left join tile t
        on t.sec = sc.section_key
       and coalesce(t.sec,'') <> ''
       and (not sc.badged_only or t.badge_count > 0)
     where sc.is_active
  )
  select coalesce(jsonb_agg(x.sec order by x.sec_sort), '[]'::jsonb),
         coalesce(sum(x.n)::int, 0)
    into v_sections, v_n
    from (
      select k.sec_sort,
             count(k.js)::int as n,
             jsonb_build_object(
               'key',   k.section_key,
               'label', public._c(k.label_key),
               'show_when_empty', k.show_when_empty,
               'empty_label', case when k.section_key = 'needs_now'
                                   then public._c('dashboard_home.needs_now_empty')
                                   else public._c('dashboard_home.section_empty') end,
               'items', coalesce(
                  jsonb_agg(k.js order by k.badge_count desc, k.sort_order, k.label)
                    filter (where k.js is not null), '[]'::jsonb)
             ) as sec
        from kept k
       group by k.section_key, k.sec_sort, k.label_key, k.show_when_empty
    ) x;

  -- Quick actions: the pins, oldest pin first so the row does not reshuffle
  -- under the thumb every time a new one is added.
  select coalesce(jsonb_agg(q.js order by q.pinned_at, q.label), '[]'::jsonb)
    into v_quick
    from (
      select s.label,
             p.pinned_at,
             jsonb_build_object(
               'feature_key', s.feature_key, 'label', s.label,
               'icon_key', s.icon_key, 'icon_letter', upper(left(s.label,1)),
               'route_key', s.route_key, 'deep_link', s.deep_link,
               'tool_key', case when s.surface = 'dev_tools' then s.route_key else null end,
               'tab_host', case s.surface when 'customer_tab' then 'customers'
                                          when 'supplier_tab' then 'suppliers'
                                          else null end,
               'tab_key', nullif(s.tab_screen,''),
               'description', coalesce(s.description,''),
               'badge_count', coalesce((v_counts ->> s.badge_source)::bigint, 0),
               'badge_tone', coalesce(nullif(s.badge_tone,''),'info'),
               'pinned', true,
               'pin_action_label', v_unpin) as js
        from public._dashboard_tiles(true) s
        join public.nav_pin p
          on p.user_id = v_uid and p.feature_key = s.feature_key
    ) q;

  -- Recently used: the last six DISTINCT doors this login opened, newest
  -- first. nav_open() is what writes the row, so the strip is a log, not a
  -- guess.
  select coalesce(jsonb_agg(r.js order by r.last_at desc, r.label), '[]'::jsonb)
    into v_recent
    from (
      select s.feature_key,
             max(u.opened_at) as last_at, s.label,
             jsonb_build_object(
               'feature_key', s.feature_key, 'label', s.label,
               'icon_key', s.icon_key, 'icon_letter', upper(left(s.label,1)),
               'route_key', s.route_key, 'deep_link', s.deep_link,
               'tool_key', case when s.surface = 'dev_tools' then s.route_key else null end,
               'tab_host', case s.surface when 'customer_tab' then 'customers'
                                          when 'supplier_tab' then 'suppliers'
                                          else null end,
               'tab_key', nullif(s.tab_screen,''),
               'description', coalesce(s.description,''),
               'badge_count', coalesce((v_counts ->> s.badge_source)::bigint, 0),
               'badge_tone', coalesce(nullif(s.badge_tone,''),'info'),
               'pinned', exists (select 1 from public.nav_pin p
                                  where p.user_id = v_uid and p.feature_key = s.feature_key),
               'pin_action_label', case when exists (select 1 from public.nav_pin p
                                                      where p.user_id = v_uid
                                                        and p.feature_key = s.feature_key)
                                        then v_unpin else v_pin end) as js
        from public._dashboard_tiles(true) s
        join public.nav_usage u
          on u.user_id = v_uid and u.feature_key = s.feature_key
       group by s.feature_key, s.label, s.icon_key, s.route_key, s.deep_link,
                s.surface, s.tab_screen, s.description, s.badge_source, s.badge_tone
       order by max(u.opened_at) desc
       limit 6
    ) r;

  return jsonb_build_object(
    'ok', true,
    'title',            public._c('dashboard_home.title'),
    'empty_label',      public._c('dashboard_home.empty_label'),
    'needs_now_empty',  public._c('dashboard_home.needs_now_empty'),
    'pin_label',        v_pin,
    'unpin_label',      v_unpin,
    -- The two personal rows. Same shape as a section, so the widget that draws
    -- a section draws these too: key, label, empty_label, show_when_empty,
    -- items — plus `columns`, which only these rows carry.
    'quick', jsonb_build_object(
      'key', 'quick',
      'label', public._c('dashboard_home.quick_label'),
      'empty_label', public._c('dashboard_home.quick_empty'),
      'show_when_empty', true,
      'columns', 4,
      'items', v_quick),
    'recent', jsonb_build_object(
      'key', 'recent',
      'label', public._c('dashboard_home.recent_label'),
      'empty_label', '',
      'show_when_empty', false,
      'items', v_recent),
    'sections',         v_sections,
    'items_count',      v_n);
end
$function$;

-- ── 4. nav_pin_toggle(): the same wording, but out of the function body ─────
create or replace function public.nav_pin_toggle(p_feature_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_was boolean;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'message', public._c('nav_pin.signin'));
  end if;
  if not exists (select 1 from feature_registry where feature_key = p_feature_key and is_active) then
    return jsonb_build_object('ok', false, 'message', public._c('nav_pin.not_registered'));
  end if;
  select true into v_was from nav_pin where user_id = v_uid and feature_key = p_feature_key;
  if v_was then
    delete from nav_pin where user_id = v_uid and feature_key = p_feature_key;
    return jsonb_build_object('ok', true, 'pinned', false,
      'message', public._c('nav_pin.unpinned_toast'),
      'action_label', public._c('nav_pin.pin_action'));
  end if;
  insert into nav_pin (user_id, feature_key) values (v_uid, p_feature_key)
    on conflict do nothing;
  return jsonb_build_object('ok', true, 'pinned', true,
    'message', public._c('nav_pin.pinned_toast'),
    'action_label', public._c('nav_pin.unpin_action'));
end $function$;

-- ── 5. The orphan gate (spec item 3) ───────────────────────────────────────
-- An "Also here" chip was drawn by staff_home() for every feature whose
-- category is homed on customers / suppliers / fulfill, minus the tab's own
-- page. Those three strips are gone, so each of those features now has to be
-- reachable some other way. Exactly four ways count:
--   * it has a dashboard_section  → it is a Dashboard tile;
--   * it IS one of the three tabs → it is the bottom bar;
--   * surface ends in `_tab`      → it is a tab inside its own host screen;
--   * merged_into is set          → it is an alias of a door that survives.
-- Anything else is unreachable, and the build stops.
create or replace function public.nav_dashboard_orphan_check(p_strict boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb; v_n int;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key,
           'label', f.label,
           'home_tab', nc.home_tab,
           'surface', coalesce(f.surface,''),
           'route_key', coalesce(f.route_key,'')) order by f.feature_key), '[]'::jsonb),
         count(*)::int
    into v_rows, v_n
    from public.feature_registry f
    join public.nav_category nc on nc.category_key = f.category
   where f.is_active
     and nc.home_tab in ('customers','suppliers','fulfill')
     and coalesce(f.dashboard_section,'') = ''
     and coalesce(f.merged_into,'') = ''
     and coalesce(f.surface,'') not in ('customer_tab','supplier_tab','fulfill_tab','alias','both')
     and not exists (select 1 from public.staff_nav_tab t
                      where t.is_active and t.route_key = f.route_key);

  if p_strict and v_n > 0 then
    raise exception 'nav_dashboard_orphan_check: % feature(s) lost their only door when the "Also here" strip was removed: %',
      v_n, v_rows;
  end if;
  return jsonb_build_object('ok', v_n = 0, 'count', v_n, 'orphans', v_rows,
                            'checked_at', now());
end $function$;

grant execute on function public.nav_dashboard_orphan_check(boolean) to authenticated, service_role;
grant execute on function public._dashboard_tiles(boolean) to authenticated, service_role;

-- Repair before asserting: any orphan this migration finds is given the
-- section its category already implies, so the gate below can be honest.
update public.feature_registry f
   set dashboard_section = case nc.home_tab
         when 'customers' then 'field_growth'
         when 'suppliers' then 'onboarding'
         else 'my_work' end
  from public.nav_category nc
 where nc.category_key = f.category
   and f.is_active
   and nc.home_tab in ('customers','suppliers','fulfill')
   and coalesce(f.dashboard_section,'') = ''
   and coalesce(f.merged_into,'') = ''
   and coalesce(f.surface,'') not in ('customer_tab','supplier_tab','fulfill_tab','alias','both')
   and not exists (select 1 from public.staff_nav_tab t
                    where t.is_active and t.route_key = f.route_key);

do $$ begin perform public.nav_dashboard_orphan_check(true); end $$;
