-- CMD #1941 — the Order cut-off tile and the Automation toggles move to the
-- Dashboard tab.
--
-- Why: `admin.order_cutoff` (CMD #1934 / CHANGE #1309) was homed on the Fulfill
-- tab, and on the mobile PWA the Fulfill tab renders only its sub-tab chips —
-- the staff_home('fulfill') "Also here" tile strip never draws there, so the
-- screen had no door on a phone. The Dashboard grid IS the strip that draws
-- everywhere, so the door moves onto it, in its own ORDERS section.
--
-- The AutoFlow / Bundle strip (CHANGE #1890) sat under the Supplier inquiry
-- and Supplier orders sub-tabs — the same two sub-tabs a phone cannot scroll
-- to comfortably. It becomes ONE AUTOMATION block at the top of the Dashboard
-- grid, carrying every toggle both sub-tabs held. Same settings, same effect;
-- the frontend still decides nothing — the labels, the ON/OFF words, the tone
-- and the toast are all built here.
--
-- Idempotent: every statement is an upsert or a create-or-replace.

begin;

-- ── 1. Copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('dashboard_home.section_orders',      '"ORDERS"'::jsonb),
  ('dashboard_home.section_automation',  '"AUTOMATION"'::jsonb),
  -- Both sub-tabs called their toggle "AutoFlow". Side by side in one strip
  -- that is two identical pills, so each says which flow it drives. The
  -- long-press sheet keeps its own fuller wording (settings_*_title).
  ('admin_supplier.autoflow_inquiry',    '"Inquiry AutoFlow"'::jsonb),
  ('admin_supplier.autoflow_orders',     '"Orders AutoFlow"'::jsonb),
  ('dashboard_home.automation_failed',   '"Could not change that. Nothing was switched."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 2. The ORDERS section on the Dashboard grid ─────────────────────────────
-- 35 puts it between FIELD & GROWTH (30) and DELIVERY (40): an order is taken
-- before it is delivered, and the grid now reads in that order.
insert into public.dashboard_section(section_key, label_key, sort_order, badged_only, is_active, show_when_empty)
values ('orders', 'dashboard_home.section_orders', 35, false, true, false)
on conflict (section_key) do update
  set label_key       = excluded.label_key,
      sort_order      = excluded.sort_order,
      badged_only     = excluded.badged_only,
      is_active       = excluded.is_active,
      show_when_empty = excluded.show_when_empty;

-- ── 2b. The section list lives in ONE place ─────────────────────────────────
-- feature_registry.dashboard_section was fenced by a CHECK carrying the seven
-- section keys as literals, so adding a section meant editing a constraint —
-- and forgetting to is a migration that fails halfway. The fence becomes a
-- foreign key onto the table that already IS the list, so a new section is one
-- INSERT and nothing else.
alter table public.feature_registry
  drop constraint if exists feature_registry_dashboard_section_ck;
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'feature_registry_dashboard_section_fk'
                    and conrelid = 'public.feature_registry'::regclass) then
    alter table public.feature_registry
      add constraint feature_registry_dashboard_section_fk
      foreign key (dashboard_section) references public.dashboard_section(section_key)
      on update cascade;
  end if;
end $$;

-- ── 3. Move the cut-off door onto the Dashboard tab ─────────────────────────
-- category drives staff_home's home_tab (nav_category.home_tab), dashboard_section
-- drives which block of the Dashboard grid the tile prints in.
update public.feature_registry
   set category          = 'home_dashboard',
       dashboard_section = 'orders',
       surface           = 'dashboard'
 where feature_key = 'admin.order_cutoff';

-- ── 4. The Automation block ─────────────────────────────────────────────────
-- One list, both sub-tabs' toggles, in the order they are used: the inquiry
-- goes out, it is bundled, the resulting orders go out.
create or replace function public._dashboard_automation()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_auto  boolean;
  v_order boolean;
  v_alloc text;
  v_on    text := public._c('admin_supplier.toggle_on');
  v_off   text := public._c('admin_supplier.toggle_off');
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    -- Same permission as supplier_toggle_chips(): a partner login sees no
    -- block at all rather than a disabled one.
    return jsonb_build_object(
      'key', 'automation',
      'label', public._c('dashboard_home.section_automation'),
      'show', false,
      'items', '[]'::jsonb);
  end if;

  select coalesce((value #>> '{}')::boolean, false) into v_auto
    from public.app_settings where key = 'inquiry_auto_meta';
  select coalesce((value #>> '{}')::boolean, false) into v_order
    from public.app_settings where key = 'supplier_order_auto_meta';
  select coalesce(value #>> '{}', 'first_available') into v_alloc
    from public.app_settings where key = 'allocation_mode';

  v_auto  := coalesce(v_auto,  false);
  v_order := coalesce(v_order, false);
  v_alloc := coalesce(v_alloc, 'first_available');

  return jsonb_build_object(
    'key',   'automation',
    'label', public._c('dashboard_home.section_automation'),
    'hint',  public._c('admin_supplier.automation_hint'),
    'show',  true,
    'items', jsonb_build_array(
      jsonb_build_object(
        'key', 'auto_meta',
        'setting_key', 'inquiry_auto_meta',
        'label', public._c('admin_supplier.autoflow_inquiry'),
        'on', v_auto,
        'state_label', case when v_auto then v_on else v_off end,
        'tone', case when v_auto then 'on' else 'off' end),
      jsonb_build_object(
        'key', 'bundle',
        'setting_key', 'allocation_mode',
        'label', public._c('admin_supplier.bundle'),
        'on', (v_alloc = 'fewest_baskets'),
        'state_label', case when v_alloc = 'fewest_baskets' then v_on else v_off end,
        'tone', case when v_alloc = 'fewest_baskets' then 'on' else 'off' end,
        'action_label', public._c('admin_supplier.re_optimize_bundles')),
      jsonb_build_object(
        'key', 'order_auto_meta',
        'setting_key', 'supplier_order_auto_meta',
        'label', public._c('admin_supplier.autoflow_orders'),
        'on', v_order,
        'state_label', case when v_order then v_on else v_off end,
        'tone', case when v_order then 'on' else 'off' end)));
end
$function$;

-- One tap on a pill. The screen sends the chip's own key and the value it is
-- moving to; everything else — which setting that is, what the toast says and
-- what the strip looks like afterwards — is decided here.
create or replace function public.dashboard_automation_set(p_key text, p_on boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_res    jsonb;
  v_detail jsonb;
  v_toast  text;
begin
  if coalesce(public.get_my_role(),'none') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'message', public._c('access.denied_view'));
  end if;

  if p_key = 'auto_meta' then
    perform public.set_app_setting('inquiry_auto_meta', to_jsonb(coalesce(p_on,false)));
    v_toast := case when coalesce(p_on,false)
                    then public._c('admin_supplier.auto_meta_toast_on')
                    else public._c('admin_supplier.auto_meta_toast_off') end;

  elsif p_key = 'order_auto_meta' then
    perform public.set_app_setting('supplier_order_auto_meta', to_jsonb(coalesce(p_on,false)));
    v_toast := case when coalesce(p_on,false)
                    then public._c('admin_supplier.auto_meta_toast_on')
                    else public._c('admin_supplier.auto_meta_toast_off') end;

  elsif p_key = 'bundle' then
    v_res := public.apply_allocation_mode(
               case when coalesce(p_on,false) then 'fewest_baskets' else 'first_available' end);
    if coalesce(v_res->>'status','') <> 'ok' then
      return jsonb_build_object('ok', false,
        'error', coalesce(v_res->>'error','unknown'),
        'message', public._cf('admin_supplier.error_detail',
                     jsonb_build_object('a', coalesce(v_res->>'error','unknown'))),
        'automation', public._dashboard_automation());
    end if;
    if coalesce(p_on,false) then
      v_detail := coalesce(v_res->'detail','{}'::jsonb);
      v_toast  := public._cf('admin_supplier.bundled_items', jsonb_build_object(
                    'a', coalesce(v_detail->>'items_assigned','0'),
                    'b', coalesce(v_detail->>'baskets','0')));
    else
      v_toast := public._c('admin_supplier.back_to_first_available');
    end if;

  else
    return jsonb_build_object('ok', false, 'error', 'unknown_toggle',
                              'message', public._c('dashboard_home.automation_failed'),
                              'automation', public._dashboard_automation());
  end if;

  return jsonb_build_object('ok', true, 'toast', v_toast,
                            'automation', public._dashboard_automation());
end
$function$;

-- ── 5. dashboard_home() carries the block ───────────────────────────────────
-- Unchanged but for one key: the same payload the grid already reads now
-- also names the automation strip, so the Dashboard is still ONE read.
CREATE OR REPLACE FUNCTION public.dashboard_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- CMD #1941 — the AutoFlow / Bundle toggles, at the top of the grid.
    -- Same settings the two Supplier sub-tabs held, same permission; a
    -- login that may not switch them gets show:false and no items.
    'automation',       public._dashboard_automation(),
    'sections',         v_sections,
    'items_count',      v_n);
end
$function$;

revoke all on function public._dashboard_automation()                    from public, anon;
revoke all on function public.dashboard_automation_set(text, boolean)    from public, anon;
grant execute on function public._dashboard_automation()                 to authenticated, service_role;
grant execute on function public.dashboard_automation_set(text, boolean) to authenticated, service_role;

commit;
