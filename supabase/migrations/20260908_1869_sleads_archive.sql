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
