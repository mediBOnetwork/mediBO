-- CMD #1869 — S Leads: bulk archive with a 30-day undo window, Restore,
-- auto-purge, and tap-to-reclassify.
--
-- Every label, rule and message below lives here, not in Dart. Flutter renders
-- lead_leads_summary().bulk verbatim and calls exactly two mutation RPCs:
-- leads_bulk_set_status() and leads_bulk_set_class().
--
-- Idempotent: safe to replay on live.

-- ── 1. Archive columns ─────────────────────────────────────────────────────
alter table public.scraped_leads
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid;

create index if not exists scraped_leads_archived_idx
  on public.scraped_leads (archived_at)
  where status = 'archived';

-- ── 2. Settings (the rules, as data) ───────────────────────────────────────
-- Spec-named key: how many days an archived lead survives before the purge.
insert into public.app_settings (key, value)
values ('lead_archive_days', '30'::jsonb)
on conflict (key) do nothing;

-- Everything else the archive lane needs, in one object.
insert into public.app_settings (key, value)
values ('sleads_archive', jsonb_build_object(
          'restore_status', 'new',
          'actions',        jsonb_build_array('archive','reclassify','restore')))
on conflict (key) do nothing;

-- The pickable classes, in display order. Labels come from ui_copy so wording
-- is an UPDATE, never a deploy.
insert into public.app_settings (key, value)
values ('sleads_classes', '["medical_store","chain","wholesaler","clinic","hospital","lab","alt_med","other"]'::jsonb)
on conflict (key) do nothing;

-- ── 3. Copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('sleads.bulk.select_hint',        '"Long-press a lead to select"'::jsonb),
  ('sleads.bulk.selected_one',       '"1 selected"'::jsonb),
  ('sleads.bulk.selected_many',      '"{n} selected"'::jsonb),
  ('sleads.bulk.select_all',         '"Select all"'::jsonb),
  ('sleads.bulk.clear',              '"Clear"'::jsonb),
  ('sleads.bulk.archive',            '"Archive {n}"'::jsonb),
  ('sleads.bulk.reclassify',         '"Reclassify {n}"'::jsonb),
  ('sleads.bulk.restore',            '"Restore {n}"'::jsonb),
  ('sleads.bulk.archive_confirm',    '"Archive {n} leads?"'::jsonb),
  ('sleads.bulk.archive_body',       '"They leave the list but stay in Archived for {d} days, where Restore brings them back. After {d} days they are deleted."'::jsonb),
  ('sleads.bulk.archive_ok',         '"Archive"'::jsonb),
  ('sleads.bulk.cancel',             '"Cancel"'::jsonb),
  ('sleads.bulk.archived_one',       '"1 lead archived — Restore it from Archived within {d} days"'::jsonb),
  ('sleads.bulk.archived_many',      '"{n} leads archived — Restore them from Archived within {d} days"'::jsonb),
  ('sleads.bulk.restored_one',       '"1 lead restored"'::jsonb),
  ('sleads.bulk.restored_many',      '"{n} leads restored"'::jsonb),
  ('sleads.bulk.reclassified_one',   '"1 lead moved to {c}"'::jsonb),
  ('sleads.bulk.reclassified_many',  '"{n} leads moved to {c}"'::jsonb),
  ('sleads.bulk.none_changed',       '"Nothing changed — those leads are outside the active zone or date"'::jsonb),
  ('sleads.bulk.class_title',        '"Move to class"'::jsonb),
  ('sleads.bulk.row_reclassify',     '"Reclassify"'::jsonb),
  ('sleads.bulk.row_restore',        '"Restore"'::jsonb),
  ('sleads.bulk.bad_status',         '"That is not an archive action"'::jsonb),
  ('sleads.bulk.bad_class',          '"That is not a lead class"'::jsonb),
  ('sleads.bulk.empty_selection',    '"Select at least one lead first"'::jsonb),
  ('sleads.filters.archived',        '"Archived"'::jsonb),
  ('sleads.filters.archived_hint',   '"Archived leads are deleted after {d} days"'::jsonb),
  ('sleads.archived_empty',          '"Nothing archived"'::jsonb)
on conflict (key) do nothing;

-- ── 4. The bulk UI payload (labels + rules, one block) ─────────────────────
create or replace function public.sleads_bulk_block()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_copy    jsonb;
  v_days    int;
  v_classes jsonb;
  v_arch    bigint;
  v_zone    smallint := public.admin_active_zone();
  v_asof    date     := public.admin_active_date();
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from public.ui_copy where key like 'sleads.%';

  v_days := greatest(1, coalesce(
    (select value::text::int from public.app_settings where key = 'lead_archive_days'), 30));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   x,
           'label', coalesce(v_copy->>('sleads.filters.class_' || x), initcap(replace(x, '_', ' '))))
         order by ord), '[]'::jsonb)
    into v_classes
    from (select x, ordinality as ord
            from jsonb_array_elements_text(coalesce(
                   (select value from public.app_settings where key = 'sleads_classes'),
                   '[]'::jsonb)) with ordinality as t(x, ordinality)) q;

  select count(*) into v_arch
    from public.scraped_leads s
   where s.status = 'archived'
     and (v_zone is null or public.zone_resolve(s.district, s.city, false) = v_zone)
     and (s.scraped_at is null
          or (s.scraped_at at time zone 'Asia/Kolkata')::date <= v_asof);

  return jsonb_build_object(
    'archive_days',    v_days,
    'select_hint',     coalesce(v_copy->>'sleads.bulk.select_hint', 'Long-press a lead to select'),
    'select_all_label',coalesce(v_copy->>'sleads.bulk.select_all', 'Select all'),
    'clear_label',     coalesce(v_copy->>'sleads.bulk.clear', 'Clear'),
    'selected_one',    coalesce(v_copy->>'sleads.bulk.selected_one', '1 selected'),
    'selected_many',   coalesce(v_copy->>'sleads.bulk.selected_many', '{n} selected'),
    'archive_label',   coalesce(v_copy->>'sleads.bulk.archive', 'Archive {n}'),
    'reclassify_label',coalesce(v_copy->>'sleads.bulk.reclassify', 'Reclassify {n}'),
    'restore_label',   coalesce(v_copy->>'sleads.bulk.restore', 'Restore {n}'),
    'confirm_title',   replace(coalesce(v_copy->>'sleads.bulk.archive_confirm', 'Archive {n} leads?'), '{d}', v_days::text),
    'confirm_body',    replace(coalesce(v_copy->>'sleads.bulk.archive_body', ''), '{d}', v_days::text),
    'confirm_ok',      coalesce(v_copy->>'sleads.bulk.archive_ok', 'Archive'),
    'confirm_cancel',  coalesce(v_copy->>'sleads.bulk.cancel', 'Cancel'),
    'empty_selection', coalesce(v_copy->>'sleads.bulk.empty_selection', 'Select at least one lead first'),
    'class_title',     coalesce(v_copy->>'sleads.bulk.class_title', 'Move to class'),
    'row_reclassify',  coalesce(v_copy->>'sleads.bulk.row_reclassify', 'Reclassify'),
    'row_restore',     coalesce(v_copy->>'sleads.bulk.row_restore', 'Restore'),
    'classes',         v_classes,
    'archived_label',  coalesce(v_copy->>'sleads.filters.archived', 'Archived'),
    'archived_hint',   replace(coalesce(v_copy->>'sleads.filters.archived_hint', ''), '{d}', v_days::text),
    'archived_empty',  coalesce(v_copy->>'sleads.archived_empty', 'Nothing archived'),
    'archived_count',  v_arch,
    'archived_chip',   replace(coalesce(v_copy->>'sleads.filters.archived', 'Archived') || ' ({n})',
                               '{n}', to_char(v_arch, 'FM999,999,999'))
  );
end;
$fn$;

grant execute on function public.sleads_bulk_block() to authenticated;

-- ── 5. Bulk status (archive / restore) ─────────────────────────────────────
create or replace function public.leads_bulk_set_status(p_ids bigint[], p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_copy    jsonb;
  v_days    int;
  v_action  text := lower(btrim(coalesce(p_status, '')));
  v_restore text;
  v_zone    smallint := public.admin_active_zone();
  v_asof    date     := public.admin_active_date();
  v_ids     bigint[];
  v_n       int := 0;
  v_msg     text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from public.ui_copy where key like 'sleads.%';

  v_days := greatest(1, coalesce(
    (select value::text::int from public.app_settings where key = 'lead_archive_days'), 30));
  v_restore := coalesce(
    (select value->>'restore_status' from public.app_settings where key = 'sleads_archive'), 'new');

  -- 'active' is accepted as a synonym so an older client cannot break.
  if v_action in ('active','restore','unarchive') then v_action := 'restore'; end if;

  if v_action not in ('archive','restore') then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', coalesce(v_copy->>'sleads.bulk.bad_status', 'That is not an archive action'));
  end if;

  v_ids := (select coalesce(array_agg(distinct x), '{}'::bigint[])
              from unnest(coalesce(p_ids, '{}'::bigint[])) x where x is not null);

  if coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty_selection',
      'message', coalesce(v_copy->>'sleads.bulk.empty_selection', 'Select at least one lead first'));
  end if;

  -- Zone and date are the header's, never the caller's: a lead outside the
  -- active scope is not touched even when its id is passed.
  with upd as (
    update public.scraped_leads s
       set status      = case when v_action = 'archive' then 'archived' else v_restore end,
           archived_at = case when v_action = 'archive' then now() else null end,
           archived_by = case when v_action = 'archive' then auth.uid() else null end
     where s.id = any(v_ids)
       and s.status is distinct from (case when v_action = 'archive' then 'archived' else v_restore end)
       and (v_action = 'restore') = (s.status = 'archived')
       and (v_zone is null or public.zone_resolve(s.district, s.city, false) = v_zone)
       and (s.scraped_at is null
            or (s.scraped_at at time zone 'Asia/Kolkata')::date <= v_asof)
    returning s.id
  )
  select count(*) into v_n from upd;

  if v_n = 0 then
    v_msg := coalesce(v_copy->>'sleads.bulk.none_changed',
                      'Nothing changed — those leads are outside the active zone or date');
  elsif v_action = 'archive' then
    v_msg := replace(replace(case when v_n = 1
               then coalesce(v_copy->>'sleads.bulk.archived_one',  '1 lead archived')
               else coalesce(v_copy->>'sleads.bulk.archived_many', '{n} leads archived') end,
             '{n}', to_char(v_n, 'FM999,999,999')), '{d}', v_days::text);
  else
    v_msg := replace(case when v_n = 1
               then coalesce(v_copy->>'sleads.bulk.restored_one',  '1 lead restored')
               else coalesce(v_copy->>'sleads.bulk.restored_many', '{n} leads restored') end,
             '{n}', to_char(v_n, 'FM999,999,999'));
  end if;

  return jsonb_build_object(
    'ok', v_n > 0, 'action', v_action, 'n', v_n,
    'archive_days', v_days, 'message', v_msg,
    'undo_action', case when v_action = 'archive' then 'restore' end,
    'ids', to_jsonb(v_ids));
end;
$fn$;

grant execute on function public.leads_bulk_set_status(bigint[], text) to authenticated;

-- ── 6. Bulk reclassify ─────────────────────────────────────────────────────
create or replace function public.leads_bulk_set_class(p_ids bigint[], p_class text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_copy  jsonb;
  v_class text := lower(btrim(coalesce(p_class, '')));
  v_zone  smallint := public.admin_active_zone();
  v_asof  date     := public.admin_active_date();
  v_ids   bigint[];
  v_n     int := 0;
  v_label text;
  v_msg   text;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from public.ui_copy where key like 'sleads.%';

  if not exists (
        select 1
          from jsonb_array_elements_text(coalesce(
                 (select value from public.app_settings where key = 'sleads_classes'),
                 '[]'::jsonb)) x
         where x = v_class) then
    return jsonb_build_object('ok', false, 'error', 'bad_class',
      'message', coalesce(v_copy->>'sleads.bulk.bad_class', 'That is not a lead class'));
  end if;

  v_ids := (select coalesce(array_agg(distinct x), '{}'::bigint[])
              from unnest(coalesce(p_ids, '{}'::bigint[])) x where x is not null);

  if coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty_selection',
      'message', coalesce(v_copy->>'sleads.bulk.empty_selection', 'Select at least one lead first'));
  end if;

  v_label := coalesce(v_copy->>('sleads.filters.class_' || v_class),
                      initcap(replace(v_class, '_', ' ')));

  -- manual_class only: trg_classify_scraped_lead recomputes lead_class and
  -- is_target from it. Nothing here duplicates that logic.
  with upd as (
    update public.scraped_leads s
       set manual_class = v_class
     where s.id = any(v_ids)
       and coalesce(s.manual_class, '') is distinct from v_class
       and (v_zone is null or public.zone_resolve(s.district, s.city, false) = v_zone)
       and (s.scraped_at is null
            or (s.scraped_at at time zone 'Asia/Kolkata')::date <= v_asof)
    returning s.id
  )
  select count(*) into v_n from upd;

  if v_n = 0 then
    v_msg := coalesce(v_copy->>'sleads.bulk.none_changed',
                      'Nothing changed — those leads are outside the active zone or date');
  else
    v_msg := replace(replace(case when v_n = 1
               then coalesce(v_copy->>'sleads.bulk.reclassified_one',  '1 lead moved to {c}')
               else coalesce(v_copy->>'sleads.bulk.reclassified_many', '{n} leads moved to {c}') end,
             '{n}', to_char(v_n, 'FM999,999,999')), '{c}', v_label);
  end if;

  return jsonb_build_object('ok', v_n > 0, 'n', v_n, 'class', v_class,
                            'class_label', v_label, 'message', v_msg);
end;
$fn$;

grant execute on function public.leads_bulk_set_class(bigint[], text) to authenticated;

-- ── 7. Auto-purge (cron only; the UI can never hard-delete) ────────────────
create or replace function public.leads_archive_purge()
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_days int;
  v_n    int := 0;
begin
  v_days := greatest(1, coalesce(
    (select value::text::int from public.app_settings where key = 'lead_archive_days'), 30));

  with gone as (
    delete from public.scraped_leads s
     where s.status = 'archived'
       and s.archived_at is not null
       and s.archived_at < now() - make_interval(days => v_days)
    returning s.id
  )
  select count(*) into v_n from gone;

  return jsonb_build_object('ok', true, 'purged', v_n, 'days', v_days);
end;
$fn$;

-- Runs inside the cron dispatcher (never its own per-minute pg_cron job).
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, base_interval_s,
                              max_interval_s, dml, enabled, note)
values ('c1869-lead-archive-purge', 785, 'poll',
        $g$select (now() at time zone 'Asia/Kolkata')::time >= time '02:20'
              and (now() at time zone 'Asia/Kolkata')::time <  time '03:20'$g$,
        'select public.leads_archive_purge()',
        3600, 3600, false, true,
        'CMD #1869 — archived S Leads are deleted after app_settings.lead_archive_days.')
on conflict (name) do update
   set gate_sql        = excluded.gate_sql,
       work_sql        = excluded.work_sql,
       base_interval_s = excluded.base_interval_s,
       enabled         = true,
       note            = excluded.note;

-- ── 8. Archived rows leave the default list ────────────────────────────────
-- Body-only replace: the header below is the LIVE signature verbatim (every
-- OUT column name included), so no caller and no baseline moves.
CREATE OR REPLACE FUNCTION public.get_scraped_leads(p_city text DEFAULT NULL::text, p_class text DEFAULT NULL::text, p_targets_only boolean DEFAULT true, p_with_phone boolean DEFAULT false, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_open_now boolean DEFAULT false, p_with_email boolean DEFAULT false, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_classes text[] DEFAULT NULL::text[], p_include_closed boolean DEFAULT false, p_min_score integer DEFAULT NULL::integer, p_show_non_targets boolean DEFAULT NULL::boolean, p_show_closed boolean DEFAULT NULL::boolean, p_show_matched boolean DEFAULT NULL::boolean, p_show_stale boolean DEFAULT false, p_preset text DEFAULT NULL::text)
 RETURNS TABLE(id bigint, place_id text, name text, phone text, intl_phone text, emails text[], website text, website_phones text[], address text, short_address text, area text, locality text, district text, state text, pincode text, plus_code text, lat double precision, lng double precision, photo_url text, photo_count integer, hours_text text[], open_now boolean, rating numeric, user_ratings integer, last_review_age text, review_snippets text[], payment_options jsonb, editorial_summary text, lead_class text, is_target boolean, type_label text, all_types text[], business_status text, city text, status text, maps_uri text, maps_directions_uri text, enriched boolean, scraped_at timestamp with time zone, lead_score integer, effective_class text, is_matched boolean, is_stale boolean, is_closed boolean, total_count bigint)
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

-- ── 9. The tab's one read carries the bulk block ───────────────────────────
CREATE OR REPLACE FUNCTION public.lead_leads_summary(p_city text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select jsonb_build_object(
    'total',      count(*) filter (where public.lead_is_prospectable(lat, business_status, matched_kind)
                                     and status is distinct from 'archived'),
    'total_raw',  count(*),
    'with_phone', count(*) filter (where phone is not null
                    and public.lead_is_prospectable(lat, business_status, matched_kind)
                    and status is distinct from 'archived'),
    'targets',    count(*) filter (where public.lead_is_prospectable(lat, business_status, matched_kind)
                                     and status is distinct from 'archived'),
    'excluded',   jsonb_build_object(
                    'closed',       count(*) filter (where coalesce(business_status,'OPERATIONAL') <> 'OPERATIONAL'),
                    'already_ours', count(*) filter (where matched_kind is not null),
                    'no_coords',    count(*) filter (where lat is null)),
    'by_class',   coalesce((
        select jsonb_agg(jsonb_build_object('class', lead_class, 'n', n, 'with_phone', wp,
                                            'n_raw', n_raw) order by n desc)
        from (select lead_class,
                     count(*) filter (where public.lead_is_prospectable(lat, business_status, matched_kind)) as n,
                     count(*) filter (where phone is not null
                       and public.lead_is_prospectable(lat, business_status, matched_kind)) as wp,
                     count(*) as n_raw
              from scraped_leads
              where (p_city is null or city ilike p_city)
                and status is distinct from 'archived'
              group by lead_class) q
      ), '[]'::jsonb),
    'cities',     coalesce((
        select jsonb_agg(jsonb_build_object('city', city, 'n', n) order by n desc)
        from (select city, count(*) n from scraped_leads
              where public.lead_is_prospectable(lat, business_status, matched_kind)
                and status is distinct from 'archived'
              group by city) c
      ), '[]'::jsonb),
    -- CMD #1869 — every label and rule the S Leads bulk toolbar renders.
    'bulk',       public.sleads_bulk_block()
  ) into v
  from scraped_leads
  where (p_city is null or city ilike p_city);
  return v;
end;
$function$;


-- ── 10. CMD #1868's filter lane learns the Archived view ───────────────────
-- Archived is a filter-state key, so it normalises, pages, counts and saves
-- into a view exactly like every other filter — and the existing filter row
-- draws its toggle with no client change.
CREATE OR REPLACE FUNCTION public._sleads_filters_norm(p_filters jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
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
    'show_stale',       coalesce(((select v->>'show_stale' from f))::boolean, false)
  );
$function$;

CREATE OR REPLACE FUNCTION public.sleads_page(p_city text DEFAULT NULL::text, p_class text DEFAULT NULL::text, p_targets_only boolean DEFAULT true, p_with_phone boolean DEFAULT false, p_search text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_open_now boolean DEFAULT false, p_with_email boolean DEFAULT false, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0, p_classes text[] DEFAULT NULL::text[], p_include_closed boolean DEFAULT false, p_filters jsonb DEFAULT NULL::jsonb)
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
             p_preset           => v_f->>'preset') g
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
           'archived',      (p.status = 'archived')
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
$function$;

CREATE OR REPLACE FUNCTION public.sleads_count(p_filters jsonb DEFAULT '{}'::jsonb)
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

CREATE OR REPLACE FUNCTION public.sleads_filters(p_filters jsonb DEFAULT '{}'::jsonb)
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
          'value', (v_f->>'archived')::boolean))),
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
