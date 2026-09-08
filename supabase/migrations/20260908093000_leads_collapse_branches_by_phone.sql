-- CMD #1871 — S Leads: collapse duplicate leads sharing a phone into one row
-- with a branch count.
--
-- Leads scraped from Maps list every branch of a chain separately, but a chain
-- publishes ONE phone. So a phone that appears on N leads is N branches of the
-- same business, and the list was showing the same shop N times.
--
-- The backend groups; Flutter renders. No table change: phone10 already exists
-- (same_phone_count is a batch column refreshed by lead_group_brands(), so the
-- grouping below counts LIVE off phone10 instead of trusting a stale integer).
-- Idempotent: every object is dropped-if-exists and recreated, and the copy
-- rows are upserted.

-- ── Copy: every string this feature prints lives in ui_copy ───────────────
insert into public.ui_copy (key, value) values
  ('sleads.branches_n',         '"{n} branches"'::jsonb),
  ('sleads.branch_of_n',        '"1 of {n} branches"'::jsonb),
  ('sleads.branches_title',     '"Branches on this phone"'::jsonb),
  ('sleads.branch_primary',     '"Shown in list"'::jsonb),
  ('sleads.branches_none',      '"No other branches"'::jsonb),
  ('admin_customer.leads_show_all_branches', '"Show all branches"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── get_scraped_leads: one row per phone10 when collapsing is on ──────────
-- The return type gains three columns, so every overload is dropped first
-- (a defaulted parameter added beside a surviving old signature is the
-- ambiguous-overload trap).
do $drop$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_scraped_leads'
  loop
    execute 'drop function if exists ' || r.sig::text;
  end loop;
end
$drop$;

create function public.get_scraped_leads(
  p_city text default null, p_class text default null,
  p_targets_only boolean default true, p_with_phone boolean default false,
  p_search text default null, p_status text default null,
  p_open_now boolean default false, p_with_email boolean default false,
  p_limit integer default 100, p_offset integer default 0,
  p_classes text[] default null, p_include_closed boolean default false,
  p_min_score integer default null, p_show_non_targets boolean default null,
  p_show_closed boolean default null, p_show_matched boolean default null,
  p_show_stale boolean default false, p_preset text default null,
  p_collapse_branches boolean default true)
returns table(id bigint, place_id text, name text, phone text, intl_phone text,
  emails text[], website text, website_phones text[], address text,
  short_address text, area text, locality text, district text, state text,
  pincode text, plus_code text, lat double precision, lng double precision,
  photo_url text, photo_count integer, hours_text text[], open_now boolean,
  rating numeric, user_ratings integer, last_review_age text,
  review_snippets text[], payment_options jsonb, editorial_summary text,
  lead_class text, is_target boolean, type_label text, all_types text[],
  business_status text, city text, status text, maps_uri text,
  maps_directions_uri text, enriched boolean,
  scraped_at timestamp with time zone, lead_score integer,
  effective_class text, is_matched boolean, is_stale boolean, is_closed boolean,
  phone10 text, branches integer, branches_label text,
  branches_expandable boolean, total_count bigint)
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
  v_status     text;   -- CMD #1869
  v_collapse   boolean; -- CMD #1871
  v_tpl_n      text;
  v_tpl_of     text;
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
  v_status := nullif(btrim(coalesce(p_status,'')), '');

  -- Legacy callers keep working: p_targets_only/p_include_closed still mean
  -- what they always meant when the explicit show_* flags are absent.
  v_non_target := coalesce(p_show_non_targets, not coalesce(p_targets_only, true));
  v_closed     := coalesce(p_show_closed,      coalesce(p_include_closed, false));
  v_matched    := coalesce(p_show_matched,     coalesce(p_include_closed, false));
  v_stale      := coalesce(p_show_stale, false);
  v_min_score  := greatest(0, coalesce(p_min_score, 0));
  v_collapse   := coalesce(p_collapse_branches, true);   -- CMD #1871

  v_tpl_n  := coalesce(nullif(public._c('sleads.branches_n'),  ''), '{n} branches');
  v_tpl_of := coalesce(nullif(public._c('sleads.branch_of_n'), ''), '1 of {n} branches');

  v_q     := nullif(btrim(coalesce(p_search,'')), '');
  v_dm    := case when v_q is not null then public._name_dm(v_q) end;
  v_fuzzy := v_q is not null and length(replace(v_q,' ','')) >= 4;

  return query
  with f as (
    select s.*,
      coalesce(nullif(btrim(s.phone10), ''), public._phone10(s.phone)) as eff_phone10,
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
      -- CMD #1869: archived leads leave the default list. Asking for them
      -- by name is the ONLY way to see them.
      and (case when v_status is null then s.status is distinct from 'archived'
                else s.status = v_status end)
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
  ), h as (
    -- CMD #1871 — branches are counted over the SAME filtered set the list
    -- shows, so "3 branches" and the 3 rows the toggle reveals always agree.
    select g.*,
      case when g.eff_phone10 is null then 1
           else count(*) over (partition by g.eff_phone10) end as grp_n,
      case when g.eff_phone10 is null or not v_collapse then 1
           else row_number() over (partition by g.eff_phone10
                  order by coalesce(g.lead_score,0) desc,
                           g.user_ratings desc nulls last,
                           (g.photo_url is null), g.id) end as grp_rn
    from g
  ), k as (
    select h.* from h where h.grp_rn = 1
  )
  select k.id, k.place_id, k.name, k.phone, k.intl_phone, k.emails, k.website, k.website_phones,
         k.address, k.short_address, k.area, k.locality, k.district, k.state, k.pincode, k.plus_code,
         k.lat, k.lng, k.photo_url, coalesce(array_length(k.photo_refs,1),0)::int,
         k.hours_text, k.open_now, k.rating, k.user_ratings, k.last_review_age, k.review_snippets,
         k.payment_options, k.editorial_summary, k.lead_class, k.is_target, k.type_label, k.all_types,
         k.business_status, k.city, k.status, k.maps_uri, k.maps_directions_uri,
         (k.raw_details is not null), k.scraped_at,
         coalesce(k.lead_score, 0)::int, k.eff_class, k.f_matched, k.f_stale, k.f_closed,
         k.eff_phone10,
         k.grp_n::int,
         case when k.grp_n > 1
              then replace(case when v_collapse then v_tpl_n else v_tpl_of end,
                           '{n}', k.grp_n::text) end,
         (k.grp_n > 1 and v_collapse),
         count(*) over () as total_count
  from k
  order by k.match_rank desc,
           (k.phone is null), (k.photo_url is null),
           k.user_ratings desc nulls last, k.id
  limit least(coalesce(p_limit, 100), 300) offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

grant execute on function public.get_scraped_leads(text,text,boolean,boolean,text,text,
  boolean,boolean,integer,integer,text[],boolean,integer,boolean,boolean,boolean,
  boolean,text,boolean) to authenticated, anon, service_role;

-- ── scrape_lead_card: the branch list for this lead's phone ───────────────
create or replace function public.scrape_lead_card(p_lead_id bigint)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  SELECT jsonb_build_object(
    'lead_id', l.id,
    'photo_url', nullif(btrim(l.photo_url),''),
    'photos', CASE WHEN nullif(btrim(l.photo_url),'') IS NOT NULL
                   THEN jsonb_build_array(btrim(l.photo_url)) ELSE '[]'::jsonb END,
    'photos_available', coalesce(array_length(l.photo_refs,1),0),
    'name', coalesce(nullif(btrim(l.name),''),'Unnamed shop'),
    'type_label', coalesce(nullif(btrim(l.type_label),''), nullif(btrim(l.lead_type),''), 'Unknown'),
    'category', l.category,
    'rating', l.rating,
    'ratings_count', l.user_ratings,
    'rating_label', CASE WHEN l.rating IS NOT NULL
                         THEN l.rating::text || ' (' || coalesce(l.user_ratings,0)::text || ')' END,
    'open_now', l.open_now,
    'open_label', CASE WHEN l.open_now IS TRUE THEN 'Open now'
                       WHEN l.open_now IS FALSE THEN 'Closed'
                       ELSE 'Hours unknown' END,
    'open_colors', CASE WHEN l.open_now IS TRUE THEN jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
                        WHEN l.open_now IS FALSE THEN jsonb_build_object('bg','#FBE9E7','fg','#B42318')
                        ELSE jsonb_build_object('bg','#F3F4F6','fg','#6B7280') END,
    'hours_label', CASE WHEN l.hours_text IS NOT NULL AND array_length(l.hours_text,1) > 0
                        THEN l.hours_text[1] END,
    'address', coalesce(nullif(btrim(l.short_address),''), nullif(btrim(l.address),'')),
    'locality', l.locality, 'pincode', l.pincode, 'city', l.city,
    'phone', l.phone10,
    'phone_display', CASE WHEN l.phone10 IS NOT NULL
                          THEN '0' || substr(l.phone10,1,5) || ' ' || substr(l.phone10,6,5) END,
    'score', l.lead_score, 'score_label', coalesce(l.lead_score,0)::text || '/100',
    'class', l.lead_class,
    'review_label', CASE WHEN l.last_review_age IS NOT NULL
                         THEN 'Last review: ' || l.last_review_age END,
    'review_stale', (coalesce(l.last_review_age,'') ILIKE '%year%'
                     AND coalesce(nullif(regexp_replace(l.last_review_age,'\D','','g'),'')::int,0) >= 4),
    'already_customer', (l.matched_customer_id IS NOT NULL),
    'visit_count', coalesce(l.visit_count,0),
    'call_uri',     CASE WHEN l.phone10 IS NOT NULL THEN 'tel:+91' || l.phone10 END,
    'whatsapp_uri', CASE WHEN l.phone10 IS NOT NULL THEN 'https://wa.me/91' || l.phone10 END,
    'map_uri',      nullif(btrim(l.maps_uri),''),
    'directions_uri', coalesce(nullif(btrim(l.maps_directions_uri),''),
                        CASE WHEN l.lat IS NOT NULL THEN
                          'https://www.google.com/maps/dir/?api=1&destination='||l.lat||','||l.lng END),
    'website_uri',  nullif(btrim(l.website),''),
    'email_uri',    CASE WHEN l.emails IS NOT NULL AND array_length(l.emails,1) > 0
                         THEN 'mailto:' || l.emails[1] END,
    -- ── CMD #1871: the branches that share this lead's phone ─────────────
    'branches_title', coalesce(nullif(public._c('sleads.branches_title'),''),
                               'Branches on this phone'),
    'branches_empty', coalesce(nullif(public._c('sleads.branches_none'),''),
                               'No other branches'),
    'branch_count', coalesce(b.n, 1),
    'branches_label', CASE WHEN coalesce(b.n,1) > 1
      THEN replace(coalesce(nullif(public._c('sleads.branches_n'),''), '{n} branches'),
                   '{n}', b.n::text) END,
    'branches', coalesce(b.rows, '[]'::jsonb),
    'actions', jsonb_build_array(
      jsonb_build_object('key','call','label','Call','enabled',(l.phone10 IS NOT NULL)),
      jsonb_build_object('key','whatsapp','label','WhatsApp','enabled',(l.phone10 IS NOT NULL)),
      jsonb_build_object('key','map','label','Map','enabled',(nullif(btrim(l.maps_uri),'') IS NOT NULL)),
      jsonb_build_object('key','directions','label','Directions','enabled',(l.lat IS NOT NULL)),
      jsonb_build_object('key','website','label','Website','enabled',(nullif(btrim(l.website),'') IS NOT NULL)),
      jsonb_build_object('key','email','label','Email','enabled',
        (l.emails IS NOT NULL AND array_length(l.emails,1) > 0)),
      jsonb_build_object('key','import','label','Import customer','enabled',(l.matched_customer_id IS NULL))),
    'disabled_reason', jsonb_strip_nulls(jsonb_build_object(
      'call',     CASE WHEN l.phone10 IS NULL THEN 'No phone number' END,
      'whatsapp', CASE WHEN l.phone10 IS NULL THEN 'No phone number' END,
      'website',  CASE WHEN nullif(btrim(l.website),'') IS NULL THEN 'No website listed' END,
      'email',    CASE WHEN l.emails IS NULL OR array_length(l.emails,1)=0 THEN 'No email found' END,
      'import',   CASE WHEN l.matched_customer_id IS NOT NULL THEN 'Already a customer' END))
  )
  FROM scraped_leads l
  LEFT JOIN LATERAL (
    -- Same zone / as-of-date scoping as the list, so the expanded branches and
    -- the "N branches" chip can never disagree with the rows behind them.
    select count(*)::int as n,
           jsonb_agg(jsonb_build_object(
             'lead_id',      x.id,
             'name',         coalesce(nullif(btrim(x.name),''),'Unnamed shop'),
             'address',      coalesce(nullif(btrim(x.short_address),''), nullif(btrim(x.address),'')),
             'locality',     nullif(btrim(coalesce(x.locality, x.area, '')), ''),
             'score_label',  coalesce(x.lead_score,0)::text || '/100',
             'rating_label', case when x.rating is not null
                                  then x.rating::text || ' (' || coalesce(x.user_ratings,0)::text || ')' end,
             'is_primary',   (x.id = l.id),
             'badge_label',  case when x.id = l.id
                                  then coalesce(nullif(public._c('sleads.branch_primary'),''),
                                                'Shown in list') end,
             'map_uri',      nullif(btrim(x.maps_uri),'')
           ) order by (x.id = l.id) desc, coalesce(x.lead_score,0) desc,
                      x.user_ratings desc nulls last, x.id) as rows
      from scraped_leads x
     where coalesce(nullif(btrim(l.phone10),''), public._phone10(l.phone)) is not null
       and coalesce(nullif(btrim(x.phone10),''), public._phone10(x.phone))
           = coalesce(nullif(btrim(l.phone10),''), public._phone10(l.phone))
       and x.status is distinct from 'archived'
       and (public.admin_active_zone() is null
            or public.zone_resolve(x.district, x.city, false) = public.admin_active_zone())
       and (x.scraped_at is null
            or (x.scraped_at at time zone 'Asia/Kolkata')::date <= public.admin_active_date())
  ) b ON true
  WHERE l.id = p_lead_id;
$function$;

-- ── sleads_page / _sleads_filters_norm: the same collapse switch ──────────
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
    -- CMD #1869 — the Archived view is a filter, so it saves into a view,
    -- pages and counts exactly like every other filter.
    'archived',     coalesce(((select v->>'archived' from f))::boolean, false),
    'min_score',    greatest(0, coalesce(
                      ((select v->>'min_score' from f))::int,
                      ((select v->'min_score'->>'default' from cfg))::int, 0)),
    'with_phone',       coalesce(((select v->>'with_phone' from f))::boolean, false),
    'open_now',         coalesce(((select v->>'open_now' from f))::boolean, false),
    'with_email',       coalesce(((select v->>'with_email' from f))::boolean, false),
    'show_non_targets', coalesce(((select v->>'show_non_targets' from f))::boolean, false),
    'show_closed',      coalesce(((select v->>'show_closed' from f))::boolean, false),
    'show_matched',     coalesce(((select v->>'show_matched' from f))::boolean, false),
    'show_stale',       coalesce(((select v->>'show_stale' from f))::boolean, false),
    -- CMD #1871 — off means one row per phone; on means every branch.
    'show_all_branches',coalesce(((select v->>'show_all_branches' from f))::boolean, false)
  );
$function$;

-- sleads_page (backend list surface) carries the same chip and switch.
create or replace function public.sleads_page(p_city text DEFAULT NULL::text, p_class text DEFAULT NULL::text, p_targets_only boolean DEFAULT true, p_with_phone boolean DEFAULT false, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_open_now boolean DEFAULT false, p_with_email boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_classes text[] DEFAULT NULL::text[], p_include_closed boolean DEFAULT false, p_filters jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy   jsonb;
  v_rows   jsonb := '[]'::jsonb;
  v_total  bigint := 0;
  v_n      integer := 0;
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_next   integer;
  v_more   boolean;
  v_f      jsonb;
  v_cls    text[];
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'sleads.%';

  -- One filter shape, whichever way the caller spelled it.
  v_f := case
           when p_filters is not null then public._sleads_filters_norm(p_filters)
           else public._sleads_filters_norm(jsonb_build_object(
                  'city', p_city,
                  'search', p_search,
                  'status', p_status,
                  'with_phone', coalesce(p_with_phone,false),
                  'open_now', coalesce(p_open_now,false),
                  'with_email', coalesce(p_with_email,false),
                  'show_non_targets', not coalesce(p_targets_only, true),
                  'show_closed', coalesce(p_include_closed,false),
                  'show_matched', coalesce(p_include_closed,false),
                  'classes', case when coalesce(p_classes, case when nullif(btrim(coalesce(p_class,'')),'') is null
                                                            then null
                                                            else string_to_array(p_class, ',') end) is null
                               then '[]'::jsonb
                               else to_jsonb(coalesce(p_classes, string_to_array(p_class, ','))) end))
         end;

  select coalesce(array_agg(x), null) into v_cls
    from jsonb_array_elements_text(v_f->'classes') x;

  with page as (
    select g.*, row_number() over () as ord
      from public.get_scraped_leads(
             p_city             => v_f->>'city',
             p_class            => null,
             p_targets_only     => true,
             p_with_phone       => (v_f->>'with_phone')::boolean,
             p_search           => v_f->>'search',
             -- CMD #1869
      p_status           => case when (v_f->>'archived')::boolean
                             then 'archived' else v_f->>'status' end,
             p_open_now         => (v_f->>'open_now')::boolean,
             p_with_email       => (v_f->>'with_email')::boolean,
             p_limit            => v_limit,
             p_offset           => v_offset,
             p_classes          => v_cls,
             p_include_closed   => false,
             p_min_score        => (v_f->>'min_score')::int,
             p_show_non_targets => (v_f->>'show_non_targets')::boolean,
             p_show_closed      => (v_f->>'show_closed')::boolean,
             p_show_matched     => (v_f->>'show_matched')::boolean,
             p_show_stale       => (v_f->>'show_stale')::boolean,
             p_preset           => v_f->>'preset',
             -- CMD #1871
             p_collapse_branches => not coalesce((v_f->>'show_all_branches')::boolean, false)) g
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
           'has_photo',     (p.photo_url is not null and p.photo_url <> ''),
           -- CMD #1869 — the class chip and the Restore button, per row.
           'class_key',     p.effective_class,
           'class_label',   coalesce(v_copy->>('sleads.filters.class_' || p.effective_class),
                                     initcap(replace(p.effective_class, '_', ' '))),
           'archived',      (p.status = 'archived'),
           -- CMD #1871 — the branch chip travels with the row.
           'branches',            p.branches,
           'branches_label',      p.branches_label,
           'branches_expandable', p.branches_expandable
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
    'filters',       v_f,
    'count_chip',    replace(coalesce(v_copy->>'sleads.filters.count_chip','S Leads ({n})'),
                             '{n}', to_char(v_total, 'FM999,999,999')),
    'count_label',   replace(case when v_total = 1
                               then coalesce(v_copy->>'sleads.count_one',  '{n} lead')
                               else coalesce(v_copy->>'sleads.count_many', '{n} leads') end,
                             '{n}', to_char(v_total, 'FM999,999,999')),
    'has_more',      v_more,
    'next_offset',   case when v_more then v_next end,
    -- CMD #1869 — the bulk toolbar's labels and rules travel with the page.
    'bulk',          public.sleads_bulk_block(),
    'empty_label',   case when (v_f->>'archived')::boolean
                       then coalesce(v_copy->>'sleads.archived_empty', 'Nothing archived')
                       else coalesce(v_copy->>'sleads.empty', '0 leads match these filters') end,
    'more_label',    coalesce(v_copy->>'sleads.loading_more', 'Loading more…'),
    'end_label',     case when v_total > 0 and not v_more
                       then replace(coalesce(v_copy->>'sleads.end', 'All {n} leads shown'),
                                    '{n}', to_char(v_total, 'FM999,999,999')) end
  );
end;
$function$

;

-- sleads_count honours the same switch, so chip and list never disagree.
create or replace function public.sleads_count(p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- CMD #1869
      p_status           => case when (v_f->>'archived')::boolean
                             then 'archived' else v_f->>'status' end,
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
      p_preset           => v_f->>'preset',
      -- CMD #1871
      p_collapse_branches => not coalesce((v_f->>'show_all_branches')::boolean, false)) r;

  v_tpl := coalesce((select value #>> '{}' from ui_copy where key='sleads.filters.count_chip'),
                    'S Leads ({n})');

  return jsonb_build_object(
    'ok',         true,
    'total',      v_total,
    'count_chip', replace(v_tpl, '{n}', to_char(v_total, 'FM999,999,999')),
    'filters',    v_f);
end;
$function$

;
