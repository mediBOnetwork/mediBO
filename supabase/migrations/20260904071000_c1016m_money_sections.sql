-- CHANGE #1016 (M) — Money drew two "Money" sections and two "Books"; Suppliers
-- still had a section literally called "Partner". Two causes, both fixed here:
--  1. features registered AFTER the #1016 baseline landed under the legacy
--     'money' category (#694 partner.zone_pnl, #471 admin.recon), and
--     admin.zone_pnl kept the pre-#1016 group "Money" — a group named Money
--     inside Money is exactly what the spec banned. Re-homed into Books.
--     partner.documents' section "Partner" is the dissolved group's name
--     surviving as a section label — it is the partner's documents, so: Documents.
--  2. staff_home() keyed sections by category:group, so the same label under
--     two categories homed on one tab drew twice. Sections are now one per
--     label per tab (More stays one per category). Idempotent.
begin;
update public.feature_registry set category = 'home_money', group_label = 'Books', sort_order = 225
 where feature_key = 'partner.zone_pnl' and (category <> 'home_money' or group_label is distinct from 'Books');
update public.feature_registry set category = 'home_money', group_label = 'Books'
 where feature_key = 'admin.recon' and (category <> 'home_money' or group_label is distinct from 'Books');
update public.feature_registry set group_label = 'Books'
 where feature_key = 'admin.zone_pnl' and group_label is distinct from 'Books';
update public.feature_registry set group_label = 'Documents'
 where feature_key = 'partner.documents' and group_label is distinct from 'Documents';

CREATE OR REPLACE FUNCTION public.staff_home(p_tab text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid     uuid := auth.uid();
  v_role    text := coalesce(public.get_my_role(),'none');
  v_tab     record;
  v_counts  jsonb := '{}'::jsonb;
  v_sections jsonb;
  v_recents jsonb := '[]'::jsonb;
  v_stats   jsonb := '[]'::jsonb;
  v_n       int := 0;
  v_dash    jsonb;
begin
  if v_uid is null or v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'sections', '[]'::jsonb,
      'items_count', 0, 'empty_label', public._c('staff_home.empty_label'));
  end if;
  select * into v_tab from public.staff_nav_tab where tab_key = p_tab and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown_tab', 'sections', '[]'::jsonb,
      'items_count', 0, 'empty_label', public._c('staff_home.empty_label'));
  end if;
  begin
    v_counts := public.nav_badge_counts();
  exception when others then v_counts := '{}'::jsonb;
  end;

  with vis as (
    select v.*, (v_counts ->> v.badge_source)::bigint as badge_count,
           coalesce(u.opens, 0) as opens, u.last_at
      from public._staff_visible() v
      left join (select feature_key, count(*) as opens, max(opened_at) as last_at
                   from public.nav_usage
                  where user_id = v_uid and opened_at > now() - interval '30 days'
                  group by 1) u on u.feature_key = v.feature_key
     where v.home_tab = p_tab
       -- the tab's own page is not a tile inside itself
       and v.route_key <> v_tab.route_key
  ), tile as (
    select v.cat_sort, v.category, v.cat_label, v.group_label, v.sort_order, v.opens, v.last_at,
           jsonb_build_object(
             'feature_key', v.feature_key, 'label', v.label, 'icon_key', v.icon_key,
             'icon_letter', upper(left(v.label,1)),
             'route_key', v.route_key, 'deep_link', v.deep_link,
             'tool_key', case when v.surface = 'dev_tools' then v.route_key else null end,
             'description', coalesce(v.description,''),
             'badge_count', coalesce(v.badge_count,0),
             'badge_label', case when coalesce(v.badge_count,0) > 0
                                 then v.badge_count::text || ' ' || coalesce(v.badge_noun, lower(v.label))
                                 else null end,
             'opens', v.opens) as js
      from vis v
  )
  select coalesce((select jsonb_agg(sec order by cat_sort, grp_sort) from (
           select min(t.cat_sort) as cat_sort, min(t.sort_order) as grp_sort,
                  jsonb_build_object(
                    'key',   t.sec_key,
                    'label', t.sec_label,
                    'sublabel', '',
                    'items', jsonb_agg(t.js order by t.group_label, t.sort_order)) as sec
             -- More: one section per category (the sub-groups order the items);
             -- every other home: one section per group LABEL across every
             -- category homed on the tab. A feature registered after the
             -- baseline under a legacy category ('money' + Books) joins the
             -- tab's own Books section instead of opening a second one with
             -- the same name (#1016 M: Money drew "Books | Money | Money | Books").
             from (select *,
                          case when p_tab = 'more' then category || ':'
                               else p_tab || ':' || coalesce(group_label,'') end as sec_key,
                          case when p_tab = 'more' then cat_label
                               else coalesce(nullif(group_label,''), cat_label) end as sec_label
                     from tile) t
            group by t.sec_key, t.sec_label) s), '[]'::jsonb),
         (select count(*)::int from tile),
         -- recents: the tiles this login actually opened, newest first.
         coalesce((select jsonb_agg(r.js order by r.last_at desc) from (
           select * from tile where opens > 0 order by last_at desc limit 6) r), '[]'::jsonb)
    into v_sections, v_n, v_recents;

  -- Money's "right now" line: the counts the old dashboard overview carried,
  -- worded here so the app prints them verbatim.
  if p_tab = 'money' and v_role in ('admin','super_admin') then
    begin
      v_dash := public.admin_dashboard_counts();
      v_stats := jsonb_build_array(
        jsonb_build_object('key','pending_bills',
          'label', public._c('staff_home.pending_bills'),
          'value_label', coalesce(v_dash->>'pending_bills','0'),
          'tone', case when coalesce((v_dash->>'pending_bills')::int,0) > 0 then 'warn' else 'good' end,
          'route_key', 'bill_pipeline'));
      if coalesce((v_dash->>'unresolved_bills')::int,0) > 0 then
        v_stats := v_stats || jsonb_build_object('key','unresolved_bills',
          'label', coalesce(v_dash->>'unresolved_bills_label',''),
          'value_label', v_dash->>'unresolved_bills',
          'tone', 'warn', 'route_key', 'bill_pipeline');
      end if;
    exception when others then v_stats := '[]'::jsonb;
    end;
  end if;

  return jsonb_build_object(
    'ok', true,
    'tab_key', p_tab,
    'title', coalesce(nullif(public._c('staff_home.' || p_tab || '_title'),''), public._c(v_tab.label_key)),
    'subtitle', public._c('staff_home.' || p_tab || '_subtitle'),
    'search_hint', public._c('staff_home.search_hint'),
    'search_empty', public._c('staff_home.search_empty'),
    'recents_label', public._c('staff_home.recents_label'),
    'strip_label', public._c('staff_home.strip_label'),
    'stats_label', public._c('staff_home.stats_label'),
    'empty_label', public._c('staff_home.empty_label'),
    'unused_report_label', case when v_role = 'super_admin' then public._c('staff_home.unused_report') else '' end,
    'sections', v_sections,
    'items_count', v_n,
    'recents', v_recents,
    'stats', v_stats);
end $function$

;
commit;
