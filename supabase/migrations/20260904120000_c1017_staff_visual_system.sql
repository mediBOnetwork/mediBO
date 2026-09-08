-- CHANGE #1017 — the staff visual system, backend half.
--
-- Om: answer-first screens, one list style, header-only zone/date, badges for
-- work only, motion for state, tablet sidebar, offline banner, view-as for the
-- super admin. Everything the shell renders below is DATA from here: the scope
-- labels, every piece of copy, the dark palette, and which tabs a previewed
-- role would see. Dart draws it; it words nothing and decides nothing.

-- ── 1. copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('staff.scope_all_zones',     to_jsonb('All zones'::text)),
  ('staff.scope_zone_locked',   to_jsonb('Your zone'::text)),
  ('staff.scope_today',         to_jsonb('Today'::text)),
  ('staff.offline_banner',      to_jsonb('Offline — {n} action(s) queued, will send when back online'::text)),
  ('staff.offline_synced',      to_jsonb('Back online — queued actions sent'::text)),
  ('staff.undo',                to_jsonb('Undo'::text)),
  ('staff.undone',              to_jsonb('Undone'::text)),
  ('staff.empty_title',         to_jsonb('Nothing here yet'::text)),
  ('staff.empty_hint',          to_jsonb('When there is work waiting it shows here first.'::text)),
  ('staff.new_work',            to_jsonb('{n} new'::text)),
  ('staff.view_as_title',       to_jsonb('View as'::text)),
  ('staff.view_as_admin',       to_jsonb('Admin'::text)),
  ('staff.view_as_partner',     to_jsonb('Partner'::text)),
  ('staff.view_as_banner',      to_jsonb('Viewing as {role} — this is what they see'::text)),
  ('staff.view_as_exit',        to_jsonb('Exit preview'::text)),
  ('staff.dark_mode',           to_jsonb('Dark mode'::text)),
  ('staff.dark_system',         to_jsonb('Follow device'::text)),
  ('staff.list_details_hint',   to_jsonb('Tap a row for details'::text))
on conflict (key) do nothing;

-- ── 2. the dark palette, as tokens (data — ui_design_set merges one level) ──
-- Same brand, same state colours (they are the only colour that carries
-- meaning); the ground and the text swap. Dart picks colors vs dark.colors by
-- brightness; nothing else in the token set changes.
select public.ui_design_set(jsonb_build_object('dark', jsonb_build_object(
  'colors', jsonb_build_object(
    'bg',            '#0F1113',
    'surface',       '#1A1D21',
    'brand',         '#2FB25A',
    'brandDark',     '#1B873F',
    'text',          '#F2F3F5',
    'textSecondary', '#A0A6AD',
    'divider',       '#2A2F35',
    'success',       '#34C759',
    'warning',       '#FF9F0A',
    'danger',        '#FF453A',
    'info',          '#409CFF'))));

-- ── 3. staff_nav(): the scope block, the copy block, and view-as ───────────
-- A defaulted argument makes the zero-arg call ambiguous, so the old signature
-- goes first. Every existing caller keeps working: p_view_as_role defaults null.
drop function if exists public.staff_nav();
create or replace function public.staff_nav(p_view_as_role text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_flag    jsonb := coalesce((select value from public.app_settings where key = 'staff_layout_v1'), '{}'::jsonb);
  v_layout  text := 'v2';
  v_tabs    jsonb;
  v_redirects jsonb;
  v_super   boolean := false;
  v_view    text := nullif(lower(btrim(coalesce(p_view_as_role,''))),'');
  v_zone    smallint;
  v_zone_label text;
  v_date_label text;
  v_scope   jsonb;
  v_copy    jsonb;
begin
  if auth.uid() is null or v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'layout', 'v2',
      'tabs', '[]'::jsonb, 'redirects', '{}'::jsonb);
  end if;

  v_super := v_partner is null and exists (select 1 from public.admins a
                where a.id::text = public.my_admin_id()::text and coalesce(a.is_super,false));

  -- CHANGE #1017 (7) — view-as is a SUPER ADMIN preview and nothing else; any
  -- other caller asking for it gets their own bar, and the payload says so.
  if v_view is not null and (not v_super or v_view not in ('admin','partner')) then
    v_view := null;
  end if;

  if coalesce((v_flag->>'enabled')::boolean, false)
     and now() < coalesce((v_flag->>'expires_at')::timestamptz, now()) then
    v_layout := 'v1';
  end if;

  -- #1016 N: the access map ONCE (set-based), never admin_access() per tab.
  -- #1017 (7): for a preview the SURFACE decides — a partner sees what is
  -- homed on the partner surface, an admin what is on the admin surface and
  -- is not super-only. The super admin's own access is never widened by this;
  -- it can only be narrowed to what the previewed role would get.
  with vis as (select * from public._staff_visible()),
       acc as (select * from public._staff_access())
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',       t.tab_key,
           'label',     public._c(t.label_key),
           'icon_key',  t.icon_key,
           'route_key', t.route_key,
           'badge_key', case when t.tab_key = 'fulfill' then 'order_alerts' else '' end,
           'visible',   t.visible)
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from (
      select s.*,
             (case
                -- #1017 (7): a preview reads the ROLE MAP — access_role_default
                -- is what a real admin / partner login is seeded with — and a
                -- tab is on their bar when a feature they may view is homed
                -- there. The super admin's own access is never widened by a
                -- preview; it can only be narrowed to the previewed role's.
                when v_view in ('admin','partner') then
                  exists (select 1 from vis v
                            join public.feature_registry fr on fr.feature_key = v.feature_key
                            join public.access_role_default d
                              on d.role = v_view and d.can_view
                             and d.feature_key = coalesce(nullif(fr.canonical_key,''), fr.feature_key)
                           where v.home_tab = s.tab_key)
                when s.anchor_feature is not null then
                  v_super
                  or exists (select 1 from acc a
                               join public.feature_registry fr on fr.feature_key = s.anchor_feature
                              where a.feature_key = coalesce(nullif(fr.canonical_key,''), fr.feature_key)
                                and a.level <> 'none')
                  or exists (select 1 from vis v where v.home_tab = s.tab_key)
                else exists (select 1 from vis v where v.home_tab = s.tab_key)
              end) as visible
        from public.staff_nav_tab s where s.is_active
    ) t;

  select coalesce(jsonb_object_agg(r.from_route, jsonb_build_object(
           'to', r.to_route, 'when_no_seed', r.when_no_seed)), '{}'::jsonb)
    into v_redirects
    from public.nav_redirect r
   where r.only_role is null or r.only_role = v_role;

  -- CHANGE #1017 (1) — the scope, once, for the header. The labels are the
  -- backend's; the pickers still write through admin_zone_scope /
  -- admin_date_scope exactly as before, then the shell re-reads this.
  begin v_zone := public.scope_zone(null); exception when others then v_zone := null; end;
  select z.name into v_zone_label from public.zones z where z.id = v_zone;
  v_date_label := to_char(public.scope_date(null), 'DD Mon');
  if public.scope_date(null) = (now() at time zone 'Asia/Kolkata')::date then
    v_date_label := public._c('staff.scope_today');
  end if;
  v_scope := jsonb_build_object(
    'zone_id',        v_zone,
    'zone_label',     coalesce(v_zone_label,
                        case when v_zone is null then public._c('staff.scope_all_zones') else '' end),
    'zone_locked',    v_partner is not null,
    'zone_locked_label', public._c('staff.scope_zone_locked'),
    'can_pick_zone',  v_partner is null,
    'can_pick_all',   v_super,
    'date',           public.scope_date(null),
    'date_label',     v_date_label,
    'can_pick_date',  true);

  v_copy := jsonb_build_object(
    'offline_banner',  public._c('staff.offline_banner'),
    'offline_synced',  public._c('staff.offline_synced'),
    'undo',            public._c('staff.undo'),
    'undone',          public._c('staff.undone'),
    'empty_title',     public._c('staff.empty_title'),
    'empty_hint',      public._c('staff.empty_hint'),
    'new_work',        public._c('staff.new_work'),
    'list_details_hint', public._c('staff.list_details_hint'),
    'dark_mode',       public._c('staff.dark_mode'),
    'dark_system',     public._c('staff.dark_system'));

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'layout', v_layout,
    'layout_note', case when v_layout = 'v1' then public._c('nav.legacy_layout_note') else '' end,
    'tabs', v_tabs,
    'redirects', v_redirects,
    'scope', v_scope,
    'copy', v_copy,
    'view_as', jsonb_build_object(
      'active',   v_view is not null,
      'role',     coalesce(v_view,''),
      'can_preview', v_super,
      'title',    public._c('staff.view_as_title'),
      'options',  case when v_super then jsonb_build_array(
                    jsonb_build_object('role','admin',   'label', public._c('staff.view_as_admin')),
                    jsonb_build_object('role','partner', 'label', public._c('staff.view_as_partner')))
                  else '[]'::jsonb end,
      'banner',   case when v_view is null then ''
                  else replace(public._c('staff.view_as_banner'), '{role}',
                         public._c('staff.view_as_' || v_view)) end,
      'exit_label', public._c('staff.view_as_exit')));
end $function$;

revoke all on function public.staff_nav(text) from public, anon;
grant execute on function public.staff_nav(text) to authenticated, service_role;
