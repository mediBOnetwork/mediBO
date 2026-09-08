-- CHANGE #1016 (N) — the staff shell's visibility was the scalar-helper-scan
-- anti-pattern: _staff_visible() called admin_access()/partner_access() once
-- PER REGISTRY ROW, and each call ran the whole access_effective() matrix.
-- Measured as test.admin under load: admin_access() over the registry 4.6 s,
-- _staff_visible() 1.5 s, staff_nav() 3.0 s, staff_home('money') 7.3 s — the
-- Money home sat on its skeleton past the verifier's window. One set-based
-- pass of access_effective() is 0.2 s. So: _staff_access() resolves the login
-- the way admin_access()/partner_access() do (admin · partner · partner_user ·
-- an admin inspecting a partner) and returns the level for EVERY canonical
-- feature at once; _staff_visible() and staff_nav() join it. Same answers,
-- one scan. nav_registry()/nav_search() share the predicate and speed up too.
-- Idempotent (create or replace).

create or replace function public._staff_access()
returns table(feature_key text, level text)
language sql stable security definer set search_path to 'public'
as $fn$
  with subj as (
    select case
             when public.my_partner_id() is not null
                  and public.role_for_medibo_only() in ('admin','super_admin') then 'partner'
             when public.my_partner_user_id() is not null then 'partner_user'
             when public.my_partner_id() is not null then 'partner'
             when public.my_admin_id() is not null then 'admin'
           end as kind,
           case
             when public.my_partner_id() is not null
                  and public.role_for_medibo_only() in ('admin','super_admin') then public.my_partner_id()::text
             when public.my_partner_user_id() is not null then public.my_partner_user_id()::text
             when public.my_partner_id() is not null then public.my_partner_id()::text
             else public.my_admin_id()::text
           end as id
  )
  select e.feature_key,
         case when e.can_write then 'write' when e.can_view then 'read' else 'none' end as level
    from subj s
    cross join lateral public.access_effective(s.kind, s.id) e
   where s.kind is not null and s.id is not null
$fn$;
revoke all on function public._staff_access() from public;
grant execute on function public._staff_access() to authenticated, service_role;

create or replace function public._staff_visible()
returns table(feature_key text, label text, group_label text, icon_key text, route_key text,
              sort_order integer, category text, surface text, badge_source text, badge_noun text,
              deep_link text, description text, search_terms text, home_tab text,
              cat_sort integer, cat_label text)
language sql stable security definer set search_path to 'public'
as $fn$
  with me as (
    select coalesce(public.get_my_role(),'none') as role,
           public.my_partner_id() as partner,
           exists (select 1 from public.admins a
                    where a.id::text = public.my_admin_id()::text
                      and coalesce(a.is_super,false)) as is_super
  ), acc as (select * from public._staff_access())
  select f.feature_key, f.label, f.group_label, f.icon_key, f.route_key, f.sort_order,
         f.category, f.surface, f.badge_source, f.badge_noun, f.deep_link, f.description,
         f.search_terms, c.home_tab, c.sort_order, c.label
    from public.feature_registry f
    join public.nav_category c on c.category_key = f.category and c.is_active
    cross join me
    left join acc on acc.feature_key = coalesce(nullif(f.canonical_key,''), f.feature_key)
   where f.is_active
     and f.surface in ('dashboard','both','dev_tools')
     and coalesce(f.route_key,'') <> ''
     -- A partner login is the MATRIX's business: partner_eligible says the
     -- feature may be granted to a partner at all, the access map says it
     -- was. roles_allowed on partner-owned rows still reads {admin,
     -- super_admin} from the days partners had their own surface.
     and case when me.partner is not null
              then f.partner_eligible and coalesce(acc.level,'none') <> 'none'
              when f.surface = 'dev_tools' then me.role = 'super_admin' and me.role = any (f.roles_allowed)
              else me.role = any (f.roles_allowed)
                   and (me.is_super or coalesce(acc.level,'none') <> 'none') end
$fn$;

CREATE OR REPLACE FUNCTION public.staff_nav()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_flag    jsonb := coalesce((select value from public.app_settings where key = 'staff_layout_v1'), '{}'::jsonb);
  v_layout  text := 'v2';
  v_tabs    jsonb;
  v_redirects jsonb;
  v_super   boolean := false;
begin
  if auth.uid() is null or v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'layout', 'v2',
      'tabs', '[]'::jsonb, 'redirects', '{}'::jsonb);
  end if;

  v_super := v_partner is null and exists (select 1 from public.admins a
                where a.id::text = public.my_admin_id()::text and coalesce(a.is_super,false));

  if coalesce((v_flag->>'enabled')::boolean, false)
     and now() < coalesce((v_flag->>'expires_at')::timestamptz, now()) then
    v_layout := 'v1';
  end if;

  -- #1016 N: the access map ONCE (set-based), never admin_access() per tab.
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
             -- a tab is on the bar when the login may open it: the anchor
             -- feature's own View toggle (the rule the old five tabs used), or
             -- any feature homed under it.
             (case when s.anchor_feature is not null
                   then v_super
                        or exists (select 1 from acc a
                                     join public.feature_registry fr on fr.feature_key = s.anchor_feature
                                    where a.feature_key = coalesce(nullif(fr.canonical_key,''), fr.feature_key)
                                      and a.level <> 'none')
                   else false end
              or exists (select 1 from vis v where v.home_tab = s.tab_key)) as visible
        from public.staff_nav_tab s where s.is_active
    ) t;

  select coalesce(jsonb_object_agg(r.from_route, jsonb_build_object(
           'to', r.to_route, 'when_no_seed', r.when_no_seed)), '{}'::jsonb)
    into v_redirects
    from public.nav_redirect r
   where r.only_role is null or r.only_role = v_role;

  return jsonb_build_object(
    'ok', true,
    'role', v_role,
    'layout', v_layout,
    'layout_note', case when v_layout = 'v1' then public._c('nav.legacy_layout_note') else '' end,
    'tabs', v_tabs,
    'redirects', v_redirects);
end $function$

;
