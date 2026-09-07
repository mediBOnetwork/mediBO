-- CHANGE #1867 — S Leads / Routes paging + lazy rows.
--
-- The lag on Customers > S Leads (1702 rows) and Routes was never the backend
-- (get_scraped_leads 107-250 ms, route_plan_list 2 ms). It was the client:
-- 100 rich cards built eagerly per page, each with a network photo and its own
-- scrape_lead_card() RPC. This migration gives the client a cheap, fully
-- labelled page payload so a row can be drawn WITHOUT a per-row call, plus
-- cheap tab counts that never depend on a list's length.
--
-- Idempotent: every statement is CREATE OR REPLACE / ON CONFLICT DO NOTHING.

-- ── Copy (backend-owned; wording changes are an UPDATE, never a deploy) ────
insert into ui_copy(key, value) values
  ('sleads.count_one',   '"{n} lead"'::jsonb),
  ('sleads.count_many',  '"{n} leads"'::jsonb),
  ('sleads.empty',       '"0 leads match these filters"'::jsonb),
  ('sleads.end',         '"All {n} leads shown"'::jsonb),
  ('sleads.loading_more','"Loading more…"'::jsonb),
  ('sleads.open_now',    '"Open now"'::jsonb),
  ('sleads.closed_now',  '"Closed now"'::jsonb),
  ('sleads.tab_label',   '"S Leads ({n})"'::jsonb),
  ('routes.tab_label',   '"Routes ({n})"'::jsonb),
  ('routes.count_one',   '"{n} route plan"'::jsonb),
  ('routes.count_many',  '"{n} route plans"'::jsonb),
  ('routes.empty',       '"No saved route plans yet"'::jsonb),
  ('routes.end',         '"All {n} route plans shown"'::jsonb),
  ('routes.loading_more','"Loading more…"'::jsonb)
on conflict (key) do nothing;

-- ── One page of scraped leads, fully labelled ─────────────────────────────
-- Wraps get_scraped_leads(p_limit, p_offset) — the same filters, the same
-- ordering, the same total_count window — and adds the display strings the
-- compact row needs so the client never calls scrape_lead_card() to draw a
-- list row. scrape_lead_card() is now a tap-only call.
create or replace function public.sleads_page(
  p_city           text    default null,
  p_class          text    default null,
  p_targets_only   boolean default false,
  p_with_phone     boolean default false,
  p_search         text    default null,
  p_status         text    default null,
  p_open_now       boolean default false,
  p_with_email     boolean default false,
  p_limit          integer default 50,
  p_offset         integer default 0,
  p_classes        text[]  default null,
  p_include_closed boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy   jsonb;
  v_rows   jsonb := '[]'::jsonb;
  v_total  bigint := 0;
  v_n      integer := 0;
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_next   integer;
  v_more   boolean;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'sleads.%';

  with page as (
    select g.*, row_number() over () as ord
      from get_scraped_leads(p_city, p_class, p_targets_only, p_with_phone, p_search,
                             p_status, p_open_now, p_with_email, v_limit, v_offset,
                             p_classes, p_include_closed) g
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            p.id,
           'title',         p.name,
           'type_label',    nullif(btrim(coalesce(p.type_label, '')), ''),
           'rating_label',  case when p.rating is not null
                              then trim(to_char(p.rating, 'FM90.0')) || ' ★'
                                   || case when coalesce(p.user_ratings, 0) > 0
                                        then ' (' || to_char(p.user_ratings, 'FM999,999,999') || ')'
                                        else '' end
                            end,
           'open_label',    case when p.open_now is true
                                 then coalesce(v_copy->>'sleads.open_now', 'Open now')
                                 when p.open_now is false
                                 then coalesce(v_copy->>'sleads.closed_now', 'Closed now') end,
           'open_bg',       case when p.open_now is true then '#D1FAE5'
                                 when p.open_now is false then '#FEE2E2' end,
           'open_fg',       case when p.open_now is true then '#065F46'
                                 when p.open_now is false then '#991B1B' end,
           'address_label', nullif(btrim(coalesce(p.short_address, p.address, '')), ''),
           'phone_label',   nullif(btrim(coalesce(p.phone, '')), ''),
           'has_photo',     (p.photo_url is not null and p.photo_url <> '')
         ) order by p.ord), '[]'::jsonb),
         coalesce(max(p.total_count), 0),
         count(*)
    into v_rows, v_total, v_n
    from page p;

  v_next := v_offset + v_n;
  v_more := v_next < v_total;

  return jsonb_build_object(
    'ok',            true,
    'page_size',     v_limit,
    'offset',        v_offset,
    'rows',          v_rows,
    'total',         v_total,
    'count_label',   replace(case when v_total = 1
                               then coalesce(v_copy->>'sleads.count_one',  '{n} lead')
                               else coalesce(v_copy->>'sleads.count_many', '{n} leads') end,
                             '{n}', to_char(v_total, 'FM999,999,999')),
    'has_more',      v_more,
    'next_offset',   case when v_more then v_next end,
    'empty_label',   coalesce(v_copy->>'sleads.empty', '0 leads match these filters'),
    'more_label',    coalesce(v_copy->>'sleads.loading_more', 'Loading more…'),
    'end_label',     case when v_total > 0 and not v_more
                       then replace(coalesce(v_copy->>'sleads.end', 'All {n} leads shown'),
                                    '{n}', to_char(v_total, 'FM999,999,999')) end
  );
end;
$function$;

grant execute on function public.sleads_page(text,text,boolean,boolean,text,text,boolean,boolean,integer,integer,text[],boolean) to authenticated;

-- ── Paged route plans ─────────────────────────────────────────────────────
-- The old single-argument route_plan_list(p_limit) is DROPPED first: adding a
-- defaulted p_offset alongside it would make route_plan_list(10) ambiguous.
drop function if exists public.route_plan_list(integer);

create or replace function public.route_plan_list(
  p_limit  integer default 20,
  p_offset integer default 0)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy   jsonb;
  v_rows   jsonb := '[]'::jsonb;
  v_total  bigint := 0;
  v_n      integer := 0;
  v_limit  integer := least(greatest(coalesce(p_limit, 20), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_next   integer;
  v_more   boolean;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'routes.%';

  select count(*) into v_total
    from route_plans where status is distinct from 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
           'plan_id',    p.id,
           'city',       p.city,
           'title',      p.city || ' · ' || p.k || 'R · ' || p.total_leads || ' leads',
           'types',      array_to_string(p.classes, ', '),
           'when_label', to_char(p.created_at at time zone 'Asia/Kolkata', 'DD/MM/YY HH24:MI'),
           'status',     p.status) order by p.created_at desc), '[]'::jsonb),
         count(*)
    into v_rows, v_n
    from (select * from route_plans
           where status is distinct from 'cancelled'
           order by created_at desc
           limit v_limit offset v_offset) p;

  v_next := v_offset + v_n;
  v_more := v_next < v_total;

  return jsonb_build_object(
    'ok',          true,
    'page_size',   v_limit,
    'offset',      v_offset,
    'rows',        v_rows,
    'total',       v_total,
    'count_label', replace(case when v_total = 1
                            then coalesce(v_copy->>'routes.count_one',  '{n} route plan')
                            else coalesce(v_copy->>'routes.count_many', '{n} route plans') end,
                          '{n}', to_char(v_total, 'FM999,999,999')),
    'has_more',    v_more,
    'next_offset', case when v_more then v_next end,
    'empty_label', coalesce(v_copy->>'routes.empty', 'No saved route plans yet'),
    'more_label',  coalesce(v_copy->>'routes.loading_more', 'Loading more…'),
    'end_label',   case when v_total > 0 and not v_more
                     then replace(coalesce(v_copy->>'routes.end', 'All {n} route plans shown'),
                                  '{n}', to_char(v_total, 'FM999,999,999')) end
  );
end;
$function$;

grant execute on function public.route_plan_list(integer,integer) to authenticated;

-- ── Cheap tab counts — never a list length ────────────────────────────────
-- Two counts and their rendered labels. The Customers screen prints
-- sleads.label / routes.label verbatim; no Dart composes "S Leads (1702)".
create or replace function public.customers_tab_counts()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy    jsonb;
  v_sleads  bigint := 0;
  v_routes  bigint := 0;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'sleads.%' or key like 'routes.%';

  select count(*) filter (where public.lead_is_prospectable(lat, business_status, matched_kind))
    into v_sleads from scraped_leads;

  select count(*) into v_routes
    from route_plans where status is distinct from 'cancelled';

  return jsonb_build_object(
    'ok', true,
    'sleads', jsonb_build_object(
      'n', v_sleads,
      'label', replace(coalesce(v_copy->>'sleads.tab_label', 'S Leads ({n})'),
                       '{n}', to_char(v_sleads, 'FM999,999,999'))),
    'routes', jsonb_build_object(
      'n', v_routes,
      'label', replace(coalesce(v_copy->>'routes.tab_label', 'Routes ({n})'),
                       '{n}', to_char(v_routes, 'FM999,999,999')))
  );
end;
$function$;

grant execute on function public.customers_tab_counts() to authenticated;
