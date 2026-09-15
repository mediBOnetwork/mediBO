-- CHANGE #349 — the RPCs behind both fixes.
--
-- `dev_tools()`  — the ONE payload the labelled tools sheet renders. A tool the
--                  registry does not list cannot appear on it; a tool the app
--                  has no screen for is dropped by the app. Two gates, same
--                  door, and neither of them is a cramped icon row.
-- `nav_icon_audit()` — every registry row whose icon_key the app cannot draw.
--                  Wired into rg_check as `nav_icons_resolve`, so a row that
--                  names a glyph nobody owns blocks the build instead of
--                  shipping an empty pale square.
--
-- Every tile payload also carries `icon_letter` now: the deterministic
-- initial-letter fallback is composed HERE, so even the fallback is backend
-- copy and Dart never derives a display string.

create or replace function public.nav_icon_audit()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with problems as (
    select 'feature_registry' as source, f.feature_key as row_key, f.label,
           coalesce(f.icon_key,'') as icon_key,
           case when coalesce(f.icon_key,'') = '' then 'missing'
                else 'unknown' end as reason
      from feature_registry f
     where f.is_active
       and (coalesce(f.icon_key,'') = ''
            or not exists (select 1 from ui_icon i where i.icon_key = f.icon_key))
    union all
    select 'nav_category', c.category_key, c.label,
           coalesce(c.icon_key,''),
           case when coalesce(c.icon_key,'') = '' then 'missing' else 'unknown' end
      from nav_category c
     where c.is_active
       and (coalesce(c.icon_key,'') = ''
            or not exists (select 1 from ui_icon i where i.icon_key = c.icon_key))
  )
  select jsonb_build_object(
    'ok', not exists (select 1 from problems),
    'title', 'Icons that do not resolve',
    'catalogue_size', (select count(*) from ui_icon),
    'registered', (select count(*) from feature_registry where is_active),
    'unresolved', (select count(*) from problems),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
                'source', p.source, 'key', p.row_key, 'label', p.label,
                'icon_key', p.icon_key, 'reason', p.reason,
                'note', case when p.reason = 'missing'
                             then 'No icon_key at all — the tile would fall back to a letter.'
                             else 'icon_key "' || p.icon_key || '" is not in ui_icon — the app cannot draw it.' end)
                order by p.source, p.row_key) from problems p), '[]'::jsonb),
    'empty_label', 'Every registered row names an icon the app can draw.'
  );
$$;

grant execute on function public.nav_icon_audit() to authenticated;

-- ── the labelled tools surface ──────────────────────────────────────────────
create or replace function public.dev_tools()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_role   text := coalesce(public.get_my_role(),'none');
  v_drafts bigint := 0;
  v_groups jsonb;
  v_count  bigint;
  v_inbox  jsonb;
begin
  if v_role <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', 'Dev Queue tools are super-admin only.',
      'groups', '[]'::jsonb, 'tool_count', 0);
  end if;

  begin
    v_inbox := public.drafts_inbox();
    v_drafts := coalesce(jsonb_array_length(v_inbox->'ready'),0)
              + coalesce(jsonb_array_length(v_inbox->'generating'),0)
              + coalesce(jsonb_array_length(v_inbox->'failed'),0);
  exception when others then v_drafts := 0;
  end;

  with tool as (
    select f.group_label, f.sort_order, f.feature_key,
           case when f.badge_source = 'dev_drafts' then v_drafts else 0 end as badge_count,
           f.label, f.description, f.icon_key, f.route_key, f.badge_noun
      from feature_registry f
     where f.is_active and f.surface = 'dev_tools'
       and v_role = any (f.roles_allowed)
  ), js as (
    select t.group_label, min(t.sort_order) as group_sort,
           jsonb_agg(jsonb_build_object(
             'feature_key',  t.feature_key,
             'tool_key',     t.route_key,
             'label',        t.label,
             'description',  coalesce(t.description,''),
             'icon_key',     t.icon_key,
             -- the deterministic fallback: the tool's own initial, so a glyph
             -- the app cannot draw still reads as this tool and never as a
             -- blank square.
             'icon_letter',  upper(left(t.label,1)),
             'badge_count',  t.badge_count,
             'badge_label',  case when t.badge_count > 0
                                  then t.badge_count::text || ' ' || coalesce(t.badge_noun, lower(t.label))
                                  else null end)
             order by t.sort_order) as items,
           count(*) as n
      from tool t group by t.group_label
  )
  select coalesce(jsonb_agg(jsonb_build_object(
             'key', group_label, 'label', group_label, 'items', items)
           order by group_sort), '[]'::jsonb),
         coalesce(sum(n),0)
    into v_groups, v_count from js;

  return jsonb_build_object(
    'ok', true,
    'title',       coalesce((select value #>> '{}' from ui_copy where key='dev_tools.title'), 'Tools'),
    'subtitle',    coalesce((select value #>> '{}' from ui_copy where key='dev_tools.subtitle'), ''),
    'search_hint', coalesce((select value #>> '{}' from ui_copy where key='dev_tools.search_hint'), ''),
    'empty_label', coalesce((select value #>> '{}' from ui_copy where key='dev_tools.empty'), ''),
    'button_label',coalesce((select value #>> '{}' from ui_copy where key='dev_tools.button'), 'Tools'),
    'groups', v_groups, 'tool_count', v_count,
    'badge_total', v_drafts);
end $$;

grant execute on function public.dev_tools() to authenticated;
