-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1868 — S Leads filters: class chips, hidden-by-default groups,
-- score cut-off, header zone, saved views.
--
-- The backend decides EVERY chip, label, default, count and toggle.
-- Flutter renders sleads_filters() verbatim and echoes the filter jsonb back.
-- Idempotent: safe to replay on live.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Config + copy (a wording change is an UPDATE, never a deploy) ───────

insert into app_settings(key, value)
values ('sleads_filters', jsonb_build_object(
  'min_score', jsonb_build_object('default', 0, 'min', 0, 'max', 100, 'step', 5),
  'stale_years', 3,
  'page_size', 100
))
on conflict (key) do nothing;

insert into ui_copy(key, value) values
  ('sleads.filters.classes_label',      '"Class"'::jsonb),
  ('sleads.filters.all_classes',        '"All"'::jsonb),
  ('sleads.filters.preset_non_pharmacy','"Non-pharmacy"'::jsonb),
  ('sleads.filters.class_medical_store','"Medical store"'::jsonb),
  ('sleads.filters.class_chain',        '"Chain"'::jsonb),
  ('sleads.filters.class_wholesaler',   '"Wholesaler"'::jsonb),
  ('sleads.filters.class_hospital',     '"Hospital"'::jsonb),
  ('sleads.filters.class_clinic',       '"Clinic"'::jsonb),
  ('sleads.filters.class_lab',          '"Lab"'::jsonb),
  ('sleads.filters.class_alt_med',      '"Alt-med"'::jsonb),
  ('sleads.filters.class_other',        '"Other"'::jsonb),
  ('sleads.filters.hidden_label',       '"Hidden by default"'::jsonb),
  ('sleads.filters.show_non_targets',   '"Show non-targets"'::jsonb),
  ('sleads.filters.show_non_targets_hint','"Leads mediBO does not sell to"'::jsonb),
  ('sleads.filters.show_closed',        '"Show closed"'::jsonb),
  ('sleads.filters.show_closed_hint',   '"Permanently or temporarily closed on Maps"'::jsonb),
  ('sleads.filters.show_matched',       '"Show matched"'::jsonb),
  ('sleads.filters.show_matched_hint',  '"Already a customer or supplier"'::jsonb),
  ('sleads.filters.show_stale',         '"Show stale"'::jsonb),
  ('sleads.filters.show_stale_hint',    '"No recent review and no phone"'::jsonb),
  ('sleads.filters.score_label',        '"Minimum score"'::jsonb),
  ('sleads.filters.score_value',        '"Score {n}+"'::jsonb),
  ('sleads.filters.score_any',          '"Any score"'::jsonb),
  ('sleads.filters.zone_label',         '"Zone"'::jsonb),
  ('sleads.filters.zone_all',           '"All zones"'::jsonb),
  ('sleads.filters.zone_hint',          '"Set in the header zone picker"'::jsonb),
  ('sleads.filters.views_label',        '"Saved views"'::jsonb),
  ('sleads.filters.views_empty',        '"No saved views yet — set filters, then Save view"'::jsonb),
  ('sleads.filters.view_save',          '"Save view"'::jsonb),
  ('sleads.filters.view_name_hint',     '"Name this view"'::jsonb),
  ('sleads.filters.view_saved',         '"View saved"'::jsonb),
  ('sleads.filters.view_applied',       '"View applied"'::jsonb),
  ('sleads.filters.view_deleted',       '"View deleted"'::jsonb),
  ('sleads.filters.view_delete',        '"Delete"'::jsonb),
  ('sleads.filters.view_name_required', '"Give the view a name"'::jsonb),
  ('sleads.filters.view_not_found',     '"That view is gone"'::jsonb),
  ('sleads.filters.reset',              '"Reset filters"'::jsonb),
  ('sleads.filters.count_chip',         '"S Leads ({n})"'::jsonb)
on conflict (key) do nothing;

-- ── 2. Saved views ────────────────────────────────────────────────────────

create table if not exists public.lead_views (
  id          bigserial primary key,
  owner_id    uuid        not null default auth.uid(),
  name        text        not null,
  filters     jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index if not exists lead_views_owner_name_uq
  on public.lead_views (owner_id, lower(btrim(name)));

alter table public.lead_views enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='lead_views'
                    and policyname='lead_views_own') then
    create policy lead_views_own on public.lead_views
      for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
  end if;
end $$;

revoke all on public.lead_views from anon;

-- ── 3. Filter normaliser — ONE canonical shape, used by every RPC ─────────
-- A saved view stores exactly this jsonb, so save → apply is a round-trip
-- with nothing recomputed in Dart.

create or replace function public._sleads_filters_norm(p_filters jsonb)
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  with cfg as (
    select coalesce((select value from app_settings where key='sleads_filters'), '{}'::jsonb) as v
  ), f as (
    select coalesce(p_filters, '{}'::jsonb) as v
  )
  select jsonb_build_object(
    'classes', coalesce(
       (select jsonb_agg(x) from jsonb_array_elements_text((select v->'classes' from f)) x
         where btrim(x) <> ''), '[]'::jsonb),
    'preset',       nullif(btrim(coalesce((select v->>'preset' from f), '')), ''),
    'city',         nullif(btrim(coalesce((select v->>'city' from f), '')), ''),
    'search',       nullif(btrim(coalesce((select v->>'search' from f), '')), ''),
    'status',       nullif(btrim(coalesce((select v->>'status' from f), '')), ''),
    'min_score',    greatest(0, coalesce(
                      ((select v->>'min_score' from f))::int,
                      ((select v->'min_score'->>'default' from cfg))::int, 0)),
    'with_phone',       coalesce(((select v->>'with_phone' from f))::boolean, false),
    'open_now',         coalesce(((select v->>'open_now' from f))::boolean, false),
    'with_email',       coalesce(((select v->>'with_email' from f))::boolean, false),
    'show_non_targets', coalesce(((select v->>'show_non_targets' from f))::boolean, false),
    'show_closed',      coalesce(((select v->>'show_closed' from f))::boolean, false),
    'show_matched',     coalesce(((select v->>'show_matched' from f))::boolean, false),
    'show_stale',       coalesce(((select v->>'show_stale' from f))::boolean, false)
  );
$function$;

-- ── 4. get_scraped_leads — extended ───────────────────────────────────────
-- The old 12-arg signature is DROPPED first: adding defaulted arguments to a
-- live function creates a second overload and every existing positional call
-- becomes ambiguous (the trap that cost CMD #1739 a whole build).

drop function if exists public.get_scraped_leads(text, text, boolean, boolean, text, text, boolean, boolean, integer, integer, text[], boolean);
drop function if exists public.get_scraped_leads(text, text, boolean, boolean, text, text, boolean, boolean, integer, integer, text[], boolean, integer, boolean, boolean, boolean, boolean, text);

create or replace function public.get_scraped_leads(
  p_city             text    default null,
  p_class            text    default null,
  p_targets_only     boolean default true,
  p_with_phone       boolean default false,
  p_search           text    default null,
  p_status           text    default null,
  p_open_now         boolean default false,
  p_with_email       boolean default false,
  p_limit            integer default 100,
  p_offset           integer default 0,
  p_classes          text[]  default null,
  p_include_closed   boolean default false,
  p_min_score        integer default null,
  p_show_non_targets boolean default null,
  p_show_closed      boolean default null,
  p_show_matched     boolean default null,
  p_show_stale       boolean default false,
  p_preset           text    default null)
returns table(
  id bigint, place_id text, name text, phone text, intl_phone text, emails text[],
  website text, website_phones text[], address text, short_address text, area text,
  locality text, district text, state text, pincode text, plus_code text,
  lat double precision, lng double precision, photo_url text, photo_count integer,
  hours_text text[], open_now boolean, rating numeric, user_ratings integer,
  last_review_age text, review_snippets text[], payment_options jsonb,
  editorial_summary text, lead_class text, is_target boolean, type_label text,
  all_types text[], business_status text, city text, status text, maps_uri text,
  maps_directions_uri text, enriched boolean, scraped_at timestamp with time zone,
  lead_score integer, effective_class text, is_matched boolean, is_stale boolean,
  is_closed boolean, total_count bigint)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_classes    text[];
  v_q          text;
  v_dm         text[];
  v_fuzzy      boolean;
  v_zone       smallint;
  v_asof       date;
  v_stale_yrs  numeric;
  v_min_score  integer;
  v_non_target boolean;
  v_closed     boolean;
  v_matched    boolean;
  v_stale      boolean;
  v_preset     text;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  -- Zone and date are NEVER parameters: they live in the header picker only.
  v_zone := public.admin_active_zone();          -- NULL = all zones
  v_asof := public.admin_active_date();

  v_stale_yrs := coalesce(
    (select (value->>'stale_years')::numeric from app_settings where key='sleads_filters'), 3);

  v_classes := coalesce(p_classes,
    case when p_class is null or btrim(p_class) = '' then null
         else (select array_agg(btrim(x)) from unnest(string_to_array(p_class, ',')) x
                where btrim(x) <> '') end);
  v_classes := case when coalesce(array_length(v_classes,1),0) = 0 then null else v_classes end;

  v_preset := nullif(btrim(coalesce(p_preset,'')), '');

  -- Legacy callers keep working: p_targets_only/p_include_closed still mean
  -- what they always meant when the explicit show_* flags are absent.
  v_non_target := coalesce(p_show_non_targets, not coalesce(p_targets_only, true));
  v_closed     := coalesce(p_show_closed,      coalesce(p_include_closed, false));
  v_matched    := coalesce(p_show_matched,     coalesce(p_include_closed, false));
  v_stale      := coalesce(p_show_stale, false);
  v_min_score  := greatest(0, coalesce(p_min_score, 0));

  v_q     := nullif(btrim(coalesce(p_search,'')), '');
  v_dm    := case when v_q is not null then public._name_dm(v_q) end;
  v_fuzzy := v_q is not null and length(replace(v_q,' ','')) >= 4;

  return query
  with f as (
    select s.*,
      coalesce(nullif(btrim(s.manual_class), ''), s.lead_class, 'other') as eff_class,
      (s.matched_customer_id is not null or s.matched_supplier_id is not null) as f_matched,
      (coalesce(s.business_status,'OPERATIONAL') <> 'OPERATIONAL')            as f_closed,
      (s.phone is null
        and coalesce(public._review_age_years(s.last_review_age), 99) >= v_stale_yrs) as f_stale,
      case
        when v_q is null                             then 0
        when s.name ilike v_q || '%'                 then 5
        when s.name ilike '%'||v_q||'%'              then 4
        when v_dm is not null and s.name_dm && v_dm  then 3
        when v_fuzzy and word_similarity(v_q, s.name) >= 0.4 then 2
        else 1
      end as match_rank
    from scraped_leads s
    where (p_city is null or s.city ilike p_city)
      -- header zone: NULL = all zones
      and (v_zone is null or public.zone_resolve(s.district, s.city, false) = v_zone)
      -- header date: the list is as-of the active date
      and (s.scraped_at is null
           or (s.scraped_at at time zone 'Asia/Kolkata')::date <= v_asof)
      and (v_min_score = 0 or coalesce(s.lead_score, 0) >= v_min_score)
      and (not p_with_phone or s.phone is not null)
      and (not p_open_now   or s.open_now is true)
      and (not p_with_email or s.emails is not null)
      and (p_status is null or s.status = p_status)
      and (
        v_q is null
        or s.name    ilike '%'||v_q||'%'
        or s.address ilike '%'||v_q||'%'
        or s.phone   ilike '%'||v_q||'%'
        or s.pincode ilike '%'||v_q||'%'
        or s.area    ilike '%'||v_q||'%'
        or (v_dm is not null and s.name_dm && v_dm)
        or (v_fuzzy and word_similarity(v_q, s.name) >= 0.4)
      )
  ), g as (
    select f.* from f
    where (v_classes is null or f.eff_class = any(v_classes))
      and (v_preset is null
           or (v_preset = 'non_pharmacy'
               and f.eff_class not in ('medical_store','chain','wholesaler')))
      -- the four hidden-by-default groups, each with its own switch
      and (v_non_target or coalesce(f.is_target, false))
      and (v_closed     or not f.f_closed)
      and (v_matched    or not f.f_matched)
      and (v_stale      or not f.f_stale)
  )
  select g.id, g.place_id, g.name, g.phone, g.intl_phone, g.emails, g.website, g.website_phones,
         g.address, g.short_address, g.area, g.locality, g.district, g.state, g.pincode, g.plus_code,
         g.lat, g.lng, g.photo_url, coalesce(array_length(g.photo_refs,1),0)::int,
         g.hours_text, g.open_now, g.rating, g.user_ratings, g.last_review_age, g.review_snippets,
         g.payment_options, g.editorial_summary, g.lead_class, g.is_target, g.type_label, g.all_types,
         g.business_status, g.city, g.status, g.maps_uri, g.maps_directions_uri,
         (g.raw_details is not null), g.scraped_at,
         coalesce(g.lead_score, 0)::int, g.eff_class, g.f_matched, g.f_stale, g.f_closed,
         count(*) over () as total_count
  from g
  order by g.match_rank desc,
           (g.phone is null), (g.photo_url is null),
           g.user_ratings desc nulls last, g.id
  limit least(coalesce(p_limit, 100), 300) offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

revoke all on function public.get_scraped_leads(text,text,boolean,boolean,text,text,boolean,boolean,integer,integer,text[],boolean,integer,boolean,boolean,boolean,boolean,text) from public, anon;
grant execute on function public.get_scraped_leads(text,text,boolean,boolean,text,text,boolean,boolean,integer,integer,text[],boolean,integer,boolean,boolean,boolean,boolean,text) to authenticated, service_role;

-- ── 5/6. Count chip — the SAME function, so it can never drift ───────────

create or replace function public.sleads_count(p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_f     jsonb;
  v_total bigint := 0;
  v_tpl   text;
  v_cls   text[];
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  v_f := public._sleads_filters_norm(p_filters);
  select coalesce(array_agg(x), null) into v_cls
    from jsonb_array_elements_text(v_f->'classes') x;

  select coalesce(max(r.total_count), 0) into v_total
    from public.get_scraped_leads(
      p_city             => v_f->>'city',
      p_class            => null,
      p_targets_only     => true,
      p_with_phone       => (v_f->>'with_phone')::boolean,
      p_search           => v_f->>'search',
      p_status           => v_f->>'status',
      p_open_now         => (v_f->>'open_now')::boolean,
      p_with_email       => (v_f->>'with_email')::boolean,
      p_limit            => 1,
      p_offset           => 0,
      p_classes          => v_cls,
      p_include_closed   => false,
      p_min_score        => (v_f->>'min_score')::int,
      p_show_non_targets => (v_f->>'show_non_targets')::boolean,
      p_show_closed      => (v_f->>'show_closed')::boolean,
      p_show_matched     => (v_f->>'show_matched')::boolean,
      p_show_stale       => (v_f->>'show_stale')::boolean,
      p_preset           => v_f->>'preset') r;

  v_tpl := coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.count_chip'),
                    'S Leads ({n})');

  return jsonb_build_object(
    'ok',         true,
    'total',      v_total,
    'count_chip', replace(v_tpl, '{n}', to_char(v_total, 'FM999,999,999')),
    'filters',    v_f);
end;
$function$;

revoke all on function public.sleads_count(jsonb) from public, anon;
grant execute on function public.sleads_count(jsonb) to authenticated, service_role;

-- ── 7. Saved-view RPCs ────────────────────────────────────────────────────

create or replace function public._lead_views_json()
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'label', v.name, 'filters', v.filters)
         order by lower(v.name)), '[]'::jsonb)
    from lead_views v where v.owner_id = auth.uid();
$function$;

create or replace function public.lead_view_list()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  return jsonb_build_object(
    'ok',    true,
    'label', coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.views_label'),'Saved views'),
    'empty', coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.views_empty'),''),
    'views', public._lead_views_json());
end;
$function$;

create or replace function public.lead_view_save(p_name text, p_filters jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_name text; v_id bigint;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  v_name := nullif(btrim(coalesce(p_name,'')), '');
  if v_name is null then
    return jsonb_build_object('ok', false,
      'message', coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.view_name_required'),
                          'Give the view a name'),
      'views', public._lead_views_json());
  end if;

  insert into lead_views(owner_id, name, filters)
  values (auth.uid(), v_name, public._sleads_filters_norm(p_filters))
  on conflict (owner_id, lower(btrim(name)))
  do update set filters = excluded.filters, name = excluded.name, updated_at = now()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id,
    'message', coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.view_saved'),'View saved'),
    'views', public._lead_views_json());
end;
$function$;

create or replace function public.lead_view_apply(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb; v_name text;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  select filters, name into v, v_name
    from lead_views where id = p_id and owner_id = auth.uid();
  if v is null then
    return jsonb_build_object('ok', false,
      'message', coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.view_not_found'),
                          'That view is gone'),
      'views', public._lead_views_json());
  end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'label', v_name,
    'filters', public._sleads_filters_norm(v),
    'message', coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.view_applied'),'View applied'));
end;
$function$;

create or replace function public.lead_view_delete(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;
  delete from lead_views where id = p_id and owner_id = auth.uid();
  return jsonb_build_object('ok', true,
    'message', coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.view_deleted'),'View deleted'),
    'views', public._lead_views_json());
end;
$function$;

revoke all on function public.lead_view_list()            from public, anon;
revoke all on function public.lead_view_save(text, jsonb) from public, anon;
revoke all on function public.lead_view_apply(bigint)     from public, anon;
revoke all on function public.lead_view_delete(bigint)    from public, anon;
grant execute on function public.lead_view_list()            to authenticated, service_role;
grant execute on function public.lead_view_save(text, jsonb) to authenticated, service_role;
grant execute on function public.lead_view_apply(bigint)     to authenticated, service_role;
grant execute on function public.lead_view_delete(bigint)    to authenticated, service_role;

-- ── 8. sleads_filters() — the whole filter row, rendered verbatim ─────────

create or replace function public.sleads_filters(p_filters jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_f        jsonb;
  v_cfg      jsonb;
  v_copy     jsonb;
  v_zone     smallint;
  v_zone_lbl text;
  v_stale    numeric;
  v_counts   jsonb;
  v_asof     date;
  v_score    integer;
  v_chips    jsonb;
  v_total    bigint;
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  v_f    := public._sleads_filters_norm(p_filters);
  v_cfg  := coalesce((select value from app_settings where key='sleads_filters'), '{}'::jsonb);
  v_zone := public.admin_active_zone();
  v_asof := public.admin_active_date();
  v_stale:= coalesce((v_cfg->>'stale_years')::numeric, 3);
  v_score:= coalesce((v_f->>'min_score')::int, 0);

  select coalesce(jsonb_object_agg(replace(key,'sleads.filters.',''), value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'sleads.filters.%';

  v_zone_lbl := coalesce((select z.name from zones z where z.id = v_zone),
                         v_copy->>'zone_all', 'All zones');

  -- Facet counts: every filter EXCEPT the class/preset dimension itself, so a
  -- chip's number is what tapping it would give you.
  with base as (
    select coalesce(nullif(btrim(s.manual_class), ''), s.lead_class, 'other') as eff_class
      from scraped_leads s
     where ((v_f->>'city') is null or s.city ilike (v_f->>'city'))
       and (v_zone is null or public.zone_resolve(s.district, s.city, false) = v_zone)
       and (s.scraped_at is null
            or (s.scraped_at at time zone 'Asia/Kolkata')::date <= v_asof)
       and (v_score = 0 or coalesce(s.lead_score,0) >= v_score)
       and (not (v_f->>'with_phone')::boolean or s.phone is not null)
       and (not (v_f->>'open_now')::boolean   or s.open_now is true)
       and (not (v_f->>'with_email')::boolean or s.emails is not null)
       and ((v_f->>'status') is null or s.status = (v_f->>'status'))
       and ((v_f->>'show_non_targets')::boolean or coalesce(s.is_target,false))
       and ((v_f->>'show_closed')::boolean
            or coalesce(s.business_status,'OPERATIONAL') = 'OPERATIONAL')
       and ((v_f->>'show_matched')::boolean
            or (s.matched_customer_id is null and s.matched_supplier_id is null))
       and ((v_f->>'show_stale')::boolean
            or not (s.phone is null
                    and coalesce(public._review_age_years(s.last_review_age), 99) >= v_stale))
  )
  select coalesce(jsonb_object_agg(eff_class, n), '{}'::jsonb), coalesce(sum(n), 0)
    into v_counts, v_total
    from (select eff_class, count(*) as n from base group by eff_class) t;

  -- Chip list: order and labels are DATA, never a Dart list.
  select jsonb_agg(chip order by ord) into v_chips from (
    select 1 as ord, jsonb_build_object(
      'key', 'all', 'kind', 'all',
      'label', coalesce(v_copy->>'all_classes','All'),
      'count', v_total,
      'count_label', to_char(v_total,'FM999,999,999'),
      'selected', (jsonb_array_length(v_f->'classes') = 0 and (v_f->>'preset') is null)) as chip
    union all
    select 2, jsonb_build_object(
      'key', 'non_pharmacy', 'kind', 'preset',
      'label', coalesce(v_copy->>'preset_non_pharmacy','Non-pharmacy'),
      'count', c.n, 'count_label', to_char(c.n,'FM999,999,999'),
      'selected', ((v_f->>'preset') is not distinct from 'non_pharmacy'))
      from (select coalesce(sum((v_counts->>k)::bigint),0) as n
              from (select jsonb_object_keys(v_counts) as k) kk
             where k not in ('medical_store','chain','wholesaler')) c
    union all
    select 2 + t.ord, jsonb_build_object(
      'key', t.key, 'kind', 'class',
      'label', coalesce(v_copy->>('class_'||t.key), initcap(replace(t.key,'_',' '))),
      'count', coalesce((v_counts->>t.key)::bigint, 0),
      'count_label', to_char(coalesce((v_counts->>t.key)::bigint,0),'FM999,999,999'),
      'selected', (v_f->'classes') ? t.key)
      from (values ('medical_store',1),('chain',2),('wholesaler',3),('hospital',4),
                   ('clinic',5),('lab',6),('alt_med',7),('other',8)) t(key, ord)
  ) chips;

  return jsonb_build_object(
    'ok', true,
    'filters', v_f,
    'classes', jsonb_build_object(
      'label', coalesce(v_copy->>'classes_label','Class'),
      'chips', coalesce(v_chips,'[]'::jsonb)),
    'hidden', jsonb_build_object(
      'label', coalesce(v_copy->>'hidden_label','Hidden by default'),
      'toggles', jsonb_build_array(
        jsonb_build_object('key','show_non_targets',
          'label', coalesce(v_copy->>'show_non_targets','Show non-targets'),
          'hint',  coalesce(v_copy->>'show_non_targets_hint',''),
          'value', (v_f->>'show_non_targets')::boolean),
        jsonb_build_object('key','show_closed',
          'label', coalesce(v_copy->>'show_closed','Show closed'),
          'hint',  coalesce(v_copy->>'show_closed_hint',''),
          'value', (v_f->>'show_closed')::boolean),
        jsonb_build_object('key','show_matched',
          'label', coalesce(v_copy->>'show_matched','Show matched'),
          'hint',  coalesce(v_copy->>'show_matched_hint',''),
          'value', (v_f->>'show_matched')::boolean),
        jsonb_build_object('key','show_stale',
          'label', coalesce(v_copy->>'show_stale','Show stale'),
          'hint',  coalesce(v_copy->>'show_stale_hint',''),
          'value', (v_f->>'show_stale')::boolean))),
    'score', jsonb_build_object(
      'label', coalesce(v_copy->>'score_label','Minimum score'),
      'min',   coalesce((v_cfg->'min_score'->>'min')::int, 0),
      'max',   coalesce((v_cfg->'min_score'->>'max')::int, 100),
      'step',  coalesce((v_cfg->'min_score'->>'step')::int, 5),
      'default', coalesce((v_cfg->'min_score'->>'default')::int, 0),
      'value', v_score,
      'value_label', case when v_score = 0
                       then coalesce(v_copy->>'score_any','Any score')
                       else replace(coalesce(v_copy->>'score_value','Score {n}+'),
                                    '{n}', v_score::text) end),
    'zone', jsonb_build_object(
      'label', coalesce(v_copy->>'zone_label','Zone'),
      'zone_id', v_zone,
      'value_label', v_zone_lbl,
      'hint', coalesce(v_copy->>'zone_hint','')),
    'views', jsonb_build_object(
      'label',       coalesce(v_copy->>'views_label','Saved views'),
      'empty',       coalesce(v_copy->>'views_empty',''),
      'save_label',  coalesce(v_copy->>'view_save','Save view'),
      'name_hint',   coalesce(v_copy->>'view_name_hint','Name this view'),
      'delete_label',coalesce(v_copy->>'view_delete','Delete'),
      'items',       public._lead_views_json()),
    'reset_label', coalesce(v_copy->>'reset','Reset filters'),
    'count_chip',  replace(coalesce(v_copy->>'count_chip','S Leads ({n})'),
                           '{n}', to_char(v_total,'FM999,999,999')),
    'total', v_total);
end;
$function$;

revoke all on function public.sleads_filters(jsonb) from public, anon;
grant execute on function public.sleads_filters(jsonb) to authenticated, service_role;
