-- CMD #1871 (fix) — the phone GROUP KEY must be a phone, not an empty string.
--
-- _phone10(null) returns '' (right(…,10) of an empty string), so a lead with no
-- phone at all produced the key '' — and 1275 phone-less leads on live grouped
-- into ONE row behind a "1275 branches" chip. The key is now a single function:
-- ten digits or nothing, so a missing / partial number can never form a group.
-- Idempotent: create-or-replace only.

create or replace function public._sleads_phone_key(p_phone10 text, p_phone text)
 returns text
 language sql
 immutable
 set search_path to 'public'
as $function$
  select case when v ~ '^[0-9]{10}$' then v end
    from (select coalesce(nullif(btrim(p_phone10), ''), public._phone10(p_phone)) as v) t;
$function$;

grant execute on function public._sleads_phone_key(text,text) to authenticated, anon, service_role;

create or replace function public.get_scraped_leads(p_city text DEFAULT NULL::text, p_class text DEFAULT NULL::text, p_targets_only boolean DEFAULT true, p_with_phone boolean DEFAULT false, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_open_now boolean DEFAULT false, p_with_email boolean DEFAULT false, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_classes text[] DEFAULT NULL::text[], p_include_closed boolean DEFAULT false, p_min_score integer DEFAULT NULL::integer, p_show_non_targets boolean DEFAULT NULL::boolean, p_show_closed boolean DEFAULT NULL::boolean, p_show_matched boolean DEFAULT NULL::boolean, p_show_stale boolean DEFAULT false, p_preset text DEFAULT NULL::text, p_collapse_branches boolean DEFAULT true)
 RETURNS TABLE(id bigint, place_id text, name text, phone text, intl_phone text, emails text[], website text, website_phones text[], address text, short_address text, area text, locality text, district text, state text, pincode text, plus_code text, lat double precision, lng double precision, photo_url text, photo_count integer, hours_text text[], open_now boolean, rating numeric, user_ratings integer, last_review_age text, review_snippets text[], payment_options jsonb, editorial_summary text, lead_class text, is_target boolean, type_label text, all_types text[], business_status text, city text, status text, maps_uri text, maps_directions_uri text, enriched boolean, scraped_at timestamp with time zone, lead_score integer, effective_class text, is_matched boolean, is_stale boolean, is_closed boolean, phone10 text, branches integer, branches_label text, branches_expandable boolean, total_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      public._sleads_phone_key(s.phone10, s.phone) as eff_phone10,
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

create or replace function public.scrape_lead_card(p_lead_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
     where public._sleads_phone_key(l.phone10, l.phone) is not null
       and public._sleads_phone_key(x.phone10, x.phone)
           = public._sleads_phone_key(l.phone10, l.phone)
       and x.status is distinct from 'archived'
       and (public.admin_active_zone() is null
            or public.zone_resolve(x.district, x.city, false) = public.admin_active_zone())
       and (x.scraped_at is null
            or (x.scraped_at at time zone 'Asia/Kolkata')::date <= public.admin_active_date())
  ) b ON true
  WHERE l.id = p_lead_id;
$function$;

create or replace function public.sleads_filters(p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_collapse boolean;   -- CMD #1871
begin
  if get_my_role() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  v_f    := public._sleads_filters_norm(p_filters);
  v_cfg  := coalesce((select value from app_settings where key='sleads_filters'), '{}'::jsonb);
  v_zone := public.admin_active_zone();
  v_asof := public.admin_active_date();
  v_stale:= coalesce((v_cfg->>'stale_years')::numeric, 3);
  v_score:= coalesce((v_f->>'min_score')::int, 0);
  -- CMD #1871 — the facet counts collapse exactly like the list does, so a
  -- chip's number is still what tapping it would give you.
  v_collapse := not coalesce((v_f->>'show_all_branches')::boolean, false);

  select coalesce(jsonb_object_agg(replace(key,'sleads.filters.',''), value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'sleads.filters.%';

  v_zone_lbl := coalesce((select z.name from zones z where z.id = v_zone),
                         v_copy->>'zone_all', 'All zones');

  -- Facet counts: every filter EXCEPT the class/preset dimension itself, so a
  -- chip's number is what tapping it would give you.
  with base0 as (
    select coalesce(nullif(btrim(s.manual_class), ''), s.lead_class, 'other') as eff_class,
           public._sleads_phone_key(s.phone10, s.phone) as ph,
           coalesce(s.lead_score, 0) as sc, s.user_ratings as ur, s.id as sid
      from scraped_leads s
     where ((v_f->>'city') is null or s.city ilike (v_f->>'city'))
       and (v_zone is null or public.zone_resolve(s.district, s.city, false) = v_zone)
       and (s.scraped_at is null
            or (s.scraped_at at time zone 'Asia/Kolkata')::date <= v_asof)
       and (v_score = 0 or coalesce(s.lead_score,0) >= v_score)
       and (not (v_f->>'with_phone')::boolean or s.phone is not null)
       and (not (v_f->>'open_now')::boolean   or s.open_now is true)
       and (not (v_f->>'with_email')::boolean or s.emails is not null)
       -- CMD #1869 — archived leads are only ever counted in the archived view.
       and (case when (v_f->>'archived')::boolean then s.status = 'archived'
                 else s.status is distinct from 'archived' end)
       and ((v_f->>'status') is null or s.status = (v_f->>'status'))
       and ((v_f->>'show_non_targets')::boolean or coalesce(s.is_target,false))
       and ((v_f->>'show_closed')::boolean
            or coalesce(s.business_status,'OPERATIONAL') = 'OPERATIONAL')
       and ((v_f->>'show_matched')::boolean
            or (s.matched_customer_id is null and s.matched_supplier_id is null))
       and ((v_f->>'show_stale')::boolean
            or not (s.phone is null
                    and coalesce(public._review_age_years(s.last_review_age), 99) >= v_stale))
  ), base as (
    select b.eff_class from (
      select base0.*,
             case when not v_collapse or base0.ph is null then 1
                  else row_number() over (partition by base0.ph
                         order by base0.sc desc, base0.ur desc nulls last, base0.sid) end as rn
        from base0) b
     where b.rn = 1
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
          'value', (v_f->>'show_stale')::boolean),
        -- CMD #1869 — Archived is a toggle like the rest, so the existing
        -- filter row draws it and a saved view can carry it.
        jsonb_build_object('key','archived',
          'label', coalesce(v_copy->>'archived','Archived'),
          'hint',  replace(coalesce(v_copy->>'archived_hint',''), '{d}',
                     greatest(1, coalesce((select value::text::int from app_settings
                                            where key='lead_archive_days'), 30))::text),
          'value', (v_f->>'archived')::boolean),
        -- CMD #1871 — off means one row per phone (the default); on means
        -- every branch of a chain is listed separately.
        jsonb_build_object('key','show_all_branches',
          'label', coalesce(v_copy->>'show_all_branches','Show all branches'),
          'hint',  coalesce(v_copy->>'show_all_branches_hint',''),
          'value', (v_f->>'show_all_branches')::boolean))),
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
