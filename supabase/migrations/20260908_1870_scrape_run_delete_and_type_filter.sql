-- CMD #1870 — Scrape runs: delete a mistaken run (archiving all of its leads)
-- and make the Include chips a HARD filter at scrape time.
--
-- Two things this fixes, both of which used to live in the wrong place:
--
--   1. "Delete this run" hard-DELETEd rows out of scraped_leads. A mis-typed
--      city was therefore unrecoverable, and the checkbox that decided it
--      ("also delete the N leads") was a client-side choice. It is now the
--      SAME archive lane CMD #1869 built: status='archived', archived_at set,
--      Restore from the Archived filter, auto-purged after
--      app_settings.lead_archive_days. The run itself is soft-deleted, so a
--      purge cannot orphan it and the audit trail survives.
--
--   2. The Include / Exclude chips only ever chose which Google types were
--      SEARCHED. Google answers a pharmacy search with hospitals, clinics and
--      plain "store" rows anyway, and every one of them was stored. The chips
--      are now a hard filter applied in lead_scrape_finish_cell() BEFORE the
--      insert: a place whose primaryType/types do not match the chosen chips
--      never reaches scraped_leads, and the run counts what it kept and what
--      it dropped so the card can say so.
--
-- Every string below lives here, not in Dart. Idempotent: safe to replay.

-- ── 1. Run columns: the soft delete and the kept/dropped counters ──────────
alter table public.lead_scrape_runs
  add column if not exists deleted_at    timestamptz,
  add column if not exists deleted_by    uuid,
  add column if not exists leads_kept    integer not null default 0,
  add column if not exists leads_dropped integer not null default 0,
  add column if not exists exclude_types text[]  not null default '{}',
  add column if not exists include_keys  text[]  not null default '{}',
  add column if not exists exclude_keys  text[]  not null default '{}';

-- scrape_runs_list() counts a run's leads (50 runs at a time) and delete
-- archives them by run_id; both were sequential scans until now.
create index if not exists scraped_leads_run_id_idx
  on public.scraped_leads (run_id);

create index if not exists lead_scrape_runs_live_idx
  on public.lead_scrape_runs (created_at desc)
  where deleted_at is null;

-- Runs that predate this change kept everything they found.
update public.lead_scrape_runs
   set leads_kept = coalesce(leads_found, 0)
 where leads_kept = 0 and coalesce(leads_found, 0) > 0;

-- ── 2. The rules, as data ─────────────────────────────────────────────────
-- drop_untyped: what to do with a place Google returned with NO type at all.
-- Default false — a place we cannot judge is kept rather than silently lost;
-- flip it with one UPDATE if a scrape ever proves otherwise.
insert into public.app_settings (key, value)
values ('scrape_type_filter',
        '{"enabled": true, "drop_untyped": false}'::jsonb)
on conflict (key) do nothing;

-- ── 3. Copy ───────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('sleads.run.delete',              '"Delete this run"'::jsonb),
  ('sleads.run.delete_title',        '"Delete this scrape run?"'::jsonb),
  ('sleads.run.delete_body_many',    '"Its {n} leads move to Archived. Restore them from the Archived filter within {d} days."'::jsonb),
  ('sleads.run.delete_body_one',     '"Its 1 lead moves to Archived. Restore it from the Archived filter within {d} days."'::jsonb),
  ('sleads.run.delete_body_none',    '"This run has no leads in the active zone and date. The run itself is removed."'::jsonb),
  ('sleads.run.delete_ok',           '"Delete run"'::jsonb),
  ('sleads.run.delete_cancel',       '"Cancel"'::jsonb),
  ('sleads.run.deleted_one',         '"Run deleted — 1 lead archived, restore it from Archived within {d} days"'::jsonb),
  ('sleads.run.deleted_many',        '"Run deleted — {n} leads archived, restore them from Archived within {d} days"'::jsonb),
  ('sleads.run.deleted_none',        '"Run deleted"'::jsonb),
  ('sleads.run.not_found',           '"That run is already gone"'::jsonb),
  ('sleads.run.kept_dropped',        '"{kept} kept · {dropped} dropped by your chips"'::jsonb),
  ('sleads.run.kept_only',           '"{kept} kept"'::jsonb),
  ('sleads.run.filter_hint',         '"Only the categories in Include are stored. Everything else Google returns is dropped and never saved."'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ── 4. Chips -> Google types (the resolution Dart used to do) ──────────────
-- Picking a top category implies all of its sub-categories UNLESS specific
-- subs of that category were chosen; a sub with no types of its own inherits
-- its parent's. This is _effectiveGoogleTypes() from the Flutter screen,
-- moved to where the rest of the decisions live.
create or replace function public.scrape_types_for_keys(p_keys text[])
returns text[]
language sql
stable
security definer
set search_path = public
as $fn$
  with keys as (select coalesce(p_keys, '{}'::text[]) k),
  top as (
    select c.key, c.google_types
    from public.lead_categories c, keys
    where c.parent_key is null and c.active and c.use_for_scrape
  ),
  sub as (
    select s.key, s.parent_key, s.google_types
    from public.lead_categories s, keys
    where s.parent_key is not null and s.active and s.use_for_scrape
  ),
  chosen_sub as (
    select sub.parent_key,
           case when coalesce(array_length(sub.google_types, 1), 0) > 0
                then sub.google_types
                else (select t.google_types from top t where t.key = sub.parent_key) end as gt
    from sub, keys
    where sub.key = any(keys.k)
  ),
  chosen_top as (
    select top.key,
           coalesce(top.google_types, '{}'::text[])
           || coalesce((select coalesce(array_agg(g), '{}'::text[])
                        from sub, unnest(coalesce(sub.google_types,'{}'::text[])) g
                        where sub.parent_key = top.key), '{}'::text[]) as gt
    from top, keys
    where top.key = any(keys.k)
      and not exists (select 1 from chosen_sub cs where cs.parent_key = top.key)
  )
  select coalesce(array_agg(distinct lower(g)), '{}'::text[])
  from (select gt from chosen_sub union all select gt from chosen_top) z,
       unnest(coalesce(z.gt, '{}'::text[])) g
  where coalesce(btrim(g), '') <> '';
$fn$;

grant execute on function public.scrape_types_for_keys(text[]) to authenticated;

-- ── 5. Does ONE place match the chips? ────────────────────────────────────
-- Pure, so the rule can be read (and argued with) in one place. Exclude wins
-- over Include, exactly as scrape_form_options() already promises in its hint.
create or replace function public.scrape_place_type_match(
  p_place        jsonb,
  p_types        text[],
  p_exclude      text[] default '{}',
  p_drop_untyped boolean default false)
returns boolean
language plpgsql
immutable
as $fn$
declare
  v_seen text[];
begin
  -- No chips resolved => no filter (never silently store nothing).
  if coalesce(array_length(p_types, 1), 0) = 0 then
    return true;
  end if;

  select coalesce(array_agg(distinct lower(t)), '{}'::text[])
    into v_seen
  from (
    select nullif(btrim(p_place->>'primaryType'), '') as t
    union all
    select jsonb_array_elements_text(
             case when jsonb_typeof(p_place->'types') = 'array'
                  then p_place->'types' else '[]'::jsonb end)
  ) s
  where nullif(btrim(s.t), '') is not null;

  -- Google told us nothing about this place: the chips cannot judge it.
  if coalesce(array_length(v_seen, 1), 0) = 0 then
    return not coalesce(p_drop_untyped, false);
  end if;

  if coalesce(array_length(p_exclude, 1), 0) > 0 and v_seen && p_exclude then
    return false;
  end if;

  return v_seen && p_types;
end;
$fn$;

grant execute on function public.scrape_place_type_match(jsonb, text[], text[], boolean) to authenticated;

-- ── 6. The insert lane: filter first, then store, then count both sides ───
create or replace function public.lead_scrape_finish_cell(
  p_cell_id bigint, p_places jsonb default '[]'::jsonb, p_error text default null)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
DECLARE
  MAX_DEPTH  constant int := 4;
  v_cell     lead_scrape_cells%ROWTYPE;
  v_run      lead_scrape_runs%ROWTYPE;
  v_found    int := 0;
  v_kept     int := 0;
  v_dropped  int := 0;
  v_new      int := 0;
  v_upserted int := 0;
  v_sat      boolean := false;
  v_side_m   numeric;
  v_child_r  int;
  v_off_lat  double precision;
  v_off_lng  double precision;
  v_type     text;
  v_cfg      jsonb;
  v_on       boolean;
  v_drop_unt boolean;
BEGIN
  SELECT * INTO v_cell FROM lead_scrape_cells WHERE id = p_cell_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO v_run FROM lead_scrape_runs WHERE id = v_cell.run_id;
  v_type := COALESCE(v_run.types[1], 'pharmacy');

  IF p_error IS NOT NULL THEN
    UPDATE lead_scrape_cells
       SET status='error', error=p_error, processed_at=now()
     WHERE id = p_cell_id;
    UPDATE lead_scrape_runs
       SET cells_done = cells_done + 1, api_calls = api_calls + 1
     WHERE id = v_cell.run_id;
    RETURN;
  END IF;

  v_found := COALESCE(jsonb_array_length(p_places), 0);

  v_cfg      := COALESCE((SELECT value FROM app_settings WHERE key = 'scrape_type_filter'),
                         '{}'::jsonb);
  v_on       := COALESCE((v_cfg->>'enabled')::boolean, true);
  v_drop_unt := COALESCE((v_cfg->>'drop_untyped')::boolean, false);

  IF v_found > 0 THEN
    -- CMD #1870 — the chips are a HARD filter. A place that does not match
    -- them is counted and thrown away here; it is never inserted, so it can
    -- never appear in the list, an export or a route.
    WITH raw AS (
      SELECT DISTINCT ON (p->>'id') p
      FROM jsonb_array_elements(p_places) p
      WHERE COALESCE(p->>'id','') <> ''
    ), judged AS (
      SELECT raw.p,
             (NOT v_on) OR public.scrape_place_type_match(
                raw.p, v_run.types, v_run.exclude_types, v_drop_unt) AS keep
      FROM raw
    ), src AS (
      SELECT p FROM judged WHERE keep
    ), ins AS (
      INSERT INTO scraped_leads (
        place_id, name, phone, address, lat, lng, rating, user_ratings,
        business_status, primary_type, maps_uri, lead_type, city, run_id
      )
      SELECT
        p->>'id',
        NULLIF(p->'displayName'->>'text',''),
        NULLIF(p->>'nationalPhoneNumber',''),
        NULLIF(COALESCE(p->>'formattedAddress', p->>'shortFormattedAddress'),''),
        NULLIF(p->'location'->>'latitude','')::double precision,
        NULLIF(p->'location'->>'longitude','')::double precision,
        NULLIF(p->>'rating','')::numeric,
        NULLIF(p->>'userRatingCount','')::int,
        NULLIF(p->>'businessStatus',''),
        NULLIF(p->>'primaryType',''),
        NULLIF(p->>'googleMapsUri',''),
        v_type, v_run.city, v_run.id
      FROM src
      ON CONFLICT (place_id) DO UPDATE SET
        name            = COALESCE(EXCLUDED.name, scraped_leads.name),
        phone           = COALESCE(EXCLUDED.phone, scraped_leads.phone),
        address         = COALESCE(EXCLUDED.address, scraped_leads.address),
        lat             = COALESCE(EXCLUDED.lat, scraped_leads.lat),
        lng             = COALESCE(EXCLUDED.lng, scraped_leads.lng),
        rating          = COALESCE(EXCLUDED.rating, scraped_leads.rating),
        user_ratings    = COALESCE(EXCLUDED.user_ratings, scraped_leads.user_ratings),
        business_status = COALESCE(EXCLUDED.business_status, scraped_leads.business_status),
        primary_type    = COALESCE(EXCLUDED.primary_type, scraped_leads.primary_type),
        maps_uri        = COALESCE(EXCLUDED.maps_uri, scraped_leads.maps_uri),
        scraped_at      = now()
      RETURNING (xmax = 0) AS is_new
    ), counted AS (
      SELECT count(*) AS n, count(*) FILTER (WHERE is_new) AS n_new FROM ins
    )
    SELECT counted.n, counted.n_new,
           (SELECT count(*) FROM judged WHERE NOT keep)
      INTO v_upserted, v_new, v_dropped
    FROM counted;

    v_kept := v_upserted;
  END IF;

  -- Saturation is judged on what Google returned, not on what we kept: the
  -- cell is still crowded even when the chips threw most of it away.
  IF v_found >= 20 AND v_cell.depth < MAX_DEPTH THEN
    v_sat     := true;
    v_side_m  := v_cell.radius_m / 0.75;
    v_child_r := GREATEST(round(0.75 * v_side_m / 2), 30);
    v_off_lat := (v_side_m / 4) / 110574.0;
    v_off_lng := (v_side_m / 4) / (111320.0 * cos(radians(v_cell.lat)));

    INSERT INTO lead_scrape_cells (run_id, lat, lng, radius_m, depth)
    SELECT v_cell.run_id,
           v_cell.lat + dlat * v_off_lat,
           v_cell.lng + dlng * v_off_lng,
           v_child_r,
           v_cell.depth + 1
    FROM (VALUES (1,1),(1,-1),(-1,1),(-1,-1)) AS q(dlat,dlng);

    UPDATE lead_scrape_runs SET cells_total = cells_total + 4 WHERE id = v_cell.run_id;
  END IF;

  UPDATE lead_scrape_cells
     SET status='done', found=v_found, saturated=v_sat, processed_at=now()
   WHERE id = p_cell_id;

  UPDATE lead_scrape_runs
     SET cells_done    = cells_done + 1,
         api_calls     = api_calls + 1,
         leads_found   = leads_found + v_upserted,
         leads_new     = leads_new + v_new,
         leads_kept    = leads_kept + v_kept,
         leads_dropped = leads_dropped + v_dropped
   WHERE id = v_cell.run_id;

  IF NOT EXISTS (
    SELECT 1 FROM lead_scrape_cells
    WHERE run_id = v_cell.run_id AND status IN ('pending','running')
  ) THEN
    UPDATE lead_scrape_runs
       SET status='done', finished_at=now()
     WHERE id = v_cell.run_id AND status <> 'done';
  END IF;
END;
$fn$;

-- ── 7. Starting a scrape: Flutter sends the chips, nothing else ───────────
-- The old signature took p_ui_types, which meant the Flutter screen had to
-- resolve include-minus-exclude into ui_types before it could call. It now
-- sends the two chip lists exactly as the trays hold them.
drop function if exists public.lead_scrape_start(text, text, text[], numeric, integer);

create or replace function public.lead_scrape_start(
  p_name      text,
  p_level     text    default 'city',
  p_include   text[]  default '{}',
  p_exclude   text[]  default '{}',
  p_cell_km   numeric default null,
  p_max_calls integer default 800)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
DECLARE
  v_run     uuid;
  v_cell    numeric;
  v_inc     text[];
  v_exc     text[];
  v_gtypes  text[];
  v_uitypes text[];
BEGIN
  IF role_for_medibo_only() NOT IN ('admin','super_admin') THEN RAISE EXCEPTION 'not_authorized'; END IF;
  IF coalesce(btrim(p_name),'') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF p_level NOT IN ('city','district') THEN RAISE EXCEPTION 'level_must_be_city_or_district'; END IF;

  IF EXISTS (SELECT 1 FROM lead_scrape_runs WHERE status IN ('planning','running')) THEN
    RAISE EXCEPTION 'a_scrape_is_already_running';
  END IF;

  v_inc := public.scrape_types_for_keys(p_include);
  v_exc := public.scrape_types_for_keys(p_exclude);

  -- Exclude beats Include, and what is left is what Google is asked for AND
  -- what the hard filter will accept back.
  SELECT coalesce(array_agg(DISTINCT g), '{}'::text[]) INTO v_gtypes
  FROM unnest(v_inc) g WHERE NOT (g = ANY(v_exc));

  -- Fallback for a caller that still speaks ui_types (and for a category tree
  -- that has no google_types of its own).
  IF coalesce(array_length(v_gtypes,1),0) = 0 THEN
    SELECT coalesce(array_agg(DISTINCT g), '{}'::text[]) INTO v_gtypes
    FROM lead_type_map m, unnest(m.google_types) g
    WHERE m.ui_type = ANY(coalesce(p_include,'{}'::text[])) AND m.active;
  END IF;

  IF coalesce(array_length(v_gtypes,1),0) = 0 THEN
    RAISE EXCEPTION 'no_valid_store_type_selected';
  END IF;

  SELECT coalesce(array_agg(DISTINCT m.ui_type), '{}'::text[]) INTO v_uitypes
  FROM lead_type_map m
  WHERE m.active AND m.google_types && v_gtypes;

  IF coalesce(array_length(v_uitypes,1),0) = 0 THEN
    v_uitypes := coalesce(p_include, '{}'::text[]);
  END IF;

  v_cell := COALESCE(p_cell_km, CASE WHEN p_level='district' THEN 5 ELSE 2 END);

  INSERT INTO lead_scrape_runs (
    city, level, ui_types, types, exclude_types, include_keys, exclude_keys,
    cell_km, max_calls, status)
  VALUES (btrim(p_name), p_level, v_uitypes, v_gtypes, v_exc,
          coalesce(p_include,'{}'::text[]), coalesce(p_exclude,'{}'::text[]),
          v_cell, GREATEST(p_max_calls,1), 'planning')
  RETURNING id INTO v_run;

  PERFORM public.lead_scrape_call(jsonb_build_object('action','plan','run_id',v_run));
  RETURN v_run;
END;
$fn$;

grant execute on function public.lead_scrape_start(text, text, text[], text[], numeric, integer) to authenticated;

-- A client still holding the previous bundle during the deploy window keeps
-- working: same name, different argument names, so a named call is never
-- ambiguous.
create or replace function public.lead_scrape_start_ui(
  p_name text, p_level text, p_ui_types text[], p_cell_km numeric, p_max_calls integer)
returns uuid
language sql
security definer
set search_path = public
as $fn$
  select public.lead_scrape_start(p_name, p_level, p_ui_types, '{}'::text[], p_cell_km, p_max_calls);
$fn$;

grant execute on function public.lead_scrape_start_ui(text, text, text[], numeric, integer) to authenticated;

-- ── 8. Delete a run = archive its leads + soft-delete the run ─────────────
drop function if exists public.scrape_run_delete(uuid, boolean);

create or replace function public.scrape_run_delete(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_copy jsonb;
  v_days int;
  v_zone smallint := public.admin_active_zone();
  v_asof date     := public.admin_active_date();
  v_n    int := 0;
  v_msg  text;
  v_run  lead_scrape_runs%ROWTYPE;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from public.ui_copy where key like 'sleads.%';

  v_days := greatest(1, coalesce(
    (select value::text::int from public.app_settings where key = 'lead_archive_days'), 30));

  select * into v_run from public.lead_scrape_runs
   where id = p_run_id and deleted_at is null;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'run_not_found',
      'message', coalesce(v_copy->>'sleads.run.not_found', 'That run is already gone'));
  end if;

  -- The SAME archive lane as leads_bulk_set_status(): status, archived_at and
  -- archived_by, so Restore and the 30-day purge already know what to do.
  -- Zone and date are the header's, never the caller's.
  with upd as (
    update public.scraped_leads s
       set status      = 'archived',
           archived_at = now(),
           archived_by = auth.uid()
     where s.run_id = p_run_id
       and s.status is distinct from 'archived'
       and (v_zone is null or public.zone_resolve(s.district, s.city, false) = v_zone)
       and (s.scraped_at is null
            or (s.scraped_at at time zone 'Asia/Kolkata')::date <= v_asof)
    returning s.id
  )
  select count(*) into v_n from upd;

  update public.lead_scrape_runs
     set deleted_at = now(), deleted_by = auth.uid()
   where id = p_run_id;

  if v_n = 0 then
    v_msg := coalesce(v_copy->>'sleads.run.deleted_none', 'Run deleted');
  else
    v_msg := replace(replace(
      case when v_n = 1
           then coalesce(v_copy->>'sleads.run.deleted_one',
                         'Run deleted — 1 lead archived')
           else coalesce(v_copy->>'sleads.run.deleted_many',
                         'Run deleted — {n} leads archived')
      end, '{n}', to_char(v_n, 'FM999,999,999')), '{d}', v_days::text);
  end if;

  return jsonb_build_object(
    'ok', true, 'run_id', p_run_id, 'archived', v_n,
    'archive_days', v_days, 'message', v_msg,
    'undo_action', case when v_n > 0 then 'restore' end);
end;
$fn$;

grant execute on function public.scrape_run_delete(uuid) to authenticated;

-- ── 9. The run list: deleted runs are gone, kept/dropped is printed here ──
create or replace function public.scrape_runs_list(p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  with cfg as (
    select
      coalesce((select jsonb_object_agg(key, value) from public.ui_copy
                 where key like 'sleads.run.%'), '{}'::jsonb) as copy,
      greatest(1, coalesce((select value::text::int from public.app_settings
                             where key = 'lead_archive_days'), 30))        as days,
      public.admin_active_zone()                                           as zone,
      public.admin_active_date()                                           as asof
  ),
  runs as (
    select r.*
    from public.lead_scrape_runs r
    where r.deleted_at is null
    order by r.created_at desc
    limit greatest(p_limit, 1)
  ),
  scoped as (
    -- What "delete this run" would actually archive: the run's leads inside
    -- the header's zone and date, never the whole table.
    select r.id as run_id, count(*) as n
    from runs r
    join public.scraped_leads sl on sl.run_id = r.id
    cross join cfg
    where sl.status is distinct from 'archived'
      and (cfg.zone is null or public.zone_resolve(sl.district, sl.city, false) = cfg.zone)
      and (sl.scraped_at is null
           or (sl.scraped_at at time zone 'Asia/Kolkata')::date <= cfg.asof)
    group by r.id
  )
  select coalesce(jsonb_agg(x order by created_at desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'run_id', r.id, 'city', r.city, 'level', r.level, 'status', r.status,
      'status_colors', case r.status
        when 'done'    then jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')
        when 'running' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
        when 'error'   then jsonb_build_object('bg','#FBE9E7','fg','#B42318')
        else jsonb_build_object('bg','#F3F4F6','fg','#6B7280') end,
      'types', to_jsonb(r.ui_types),
      'types_label', array_to_string(r.ui_types, ', '),
      -- The chips this run was started with, so a re-scrape can replay them.
      'include_keys', to_jsonb(coalesce(r.include_keys, '{}'::text[])),
      'exclude_keys', to_jsonb(coalesce(r.exclude_keys, '{}'::text[])),
      'created_at', r.created_at, 'finished_at', r.finished_at,
      'cells_total', r.cells_total, 'cells_done', r.cells_done,
      'api_calls', r.api_calls, 'max_calls', r.max_calls,
      'leads_found', coalesce(r.leads_found,0), 'leads_new', coalesce(r.leads_new,0),
      'error', r.error,
      'summary_label', coalesce(r.leads_new,0)::text || ' new · ' ||
                       coalesce(r.leads_found,0)::text || ' found · ' ||
                       coalesce(r.api_calls,0)::text || ' API calls',
      -- CMD #1870 — what the Include chips kept and what they threw away.
      'leads_kept', coalesce(r.leads_kept,0),
      'leads_dropped', coalesce(r.leads_dropped,0),
      'kept_dropped_label', case
        when coalesce(r.leads_dropped,0) > 0
          then replace(replace(coalesce(cfg.copy->>'sleads.run.kept_dropped',
                                        '{kept} kept · {dropped} dropped by your chips'),
                       '{kept}',    to_char(coalesce(r.leads_kept,0),    'FM999,999,999')),
                       '{dropped}', to_char(coalesce(r.leads_dropped,0), 'FM999,999,999'))
        when coalesce(r.leads_kept,0) > 0
          then replace(coalesce(cfg.copy->>'sleads.run.kept_only', '{kept} kept'),
                       '{kept}', to_char(coalesce(r.leads_kept,0), 'FM999,999,999'))
        else null end,
      'breakdown', (select coalesce(jsonb_agg(jsonb_build_object(
                        'type', coalesce(t.type_label,'Unknown'), 'count', t.n,
                        'with_phone', t.ph, 'with_photo', t.pho) order by t.n desc), '[]'::jsonb)
                    from (select sl.type_label, count(*) as n,
                                 count(*) filter (where sl.phone10 is not null) as ph,
                                 count(*) filter (where sl.photo_url is not null) as pho
                          from public.scraped_leads sl where sl.run_id = r.id
                          group by sl.type_label) t),
      'lead_count', coalesce(sc.n, 0),
      'can_delete', true,
      -- The whole confirm dialog, written here. Flutter prints it.
      'delete', jsonb_build_object(
        'label',  coalesce(cfg.copy->>'sleads.run.delete',       'Delete this run'),
        'title',  coalesce(cfg.copy->>'sleads.run.delete_title', 'Delete this scrape run?'),
        'body',   case
          when coalesce(sc.n,0) = 0
            then coalesce(cfg.copy->>'sleads.run.delete_body_none',
                          'This run has no leads in the active zone and date.')
          when sc.n = 1
            then replace(coalesce(cfg.copy->>'sleads.run.delete_body_one',
                                  'Its 1 lead moves to Archived.'), '{d}', cfg.days::text)
          else replace(replace(coalesce(cfg.copy->>'sleads.run.delete_body_many',
                                        'Its {n} leads move to Archived.'),
                       '{n}', to_char(sc.n, 'FM999,999,999')), '{d}', cfg.days::text)
        end,
        'ok',     coalesce(cfg.copy->>'sleads.run.delete_ok',     'Delete run'),
        'cancel', coalesce(cfg.copy->>'sleads.run.delete_cancel', 'Cancel'),
        'count',  coalesce(sc.n, 0))
    ) as x, r.created_at
    from runs r
    cross join cfg
    left join scoped sc on sc.run_id = r.id
  ) z;
$fn$;

grant execute on function public.scrape_runs_list(integer) to authenticated;

-- ── 10. The scrape form: a deleted run is not a re-scrape source ──────────
create or replace function public.scrape_form_options()
returns jsonb
language sql
stable
security definer
set search_path = public
as $fn$
  select jsonb_build_object(
    'title','Scrape new leads',
    'modes', jsonb_build_array(
      jsonb_build_object('key','fresh','label','Fresh scrape',
        'hint','Search Google Places for new shops in this area'),
      jsonb_build_object('key','rescrape','label','Re-scrape a saved run',
        'hint','Refresh the shops from a previous scrape without spending new search calls')),
    'levels', jsonb_build_array(
      jsonb_build_object('key','city','label','City'),
      jsonb_build_object('key','district','label','District')),
    'categories', public.lead_category_tree('scrape'),
    'selection', jsonb_build_object(
      'mode','include_exclude',
      'include_label','Include',
      'exclude_label','Exclude',
      'hint', coalesce((select value #>> '{}' from public.ui_copy
                         where key = 'sleads.run.filter_hint'),
                       'Only the categories in Include are stored.')),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object(
                   'run_id', r.id,
                   'label', coalesce(r.city,'?') || ' · ' ||
                            to_char(r.created_at at time zone 'Asia/Kolkata','DD/MM/YYYY') || ' · ' ||
                            coalesce(r.leads_found,0)::text || ' leads',
                   'lead_count', (select count(*) from public.scraped_leads sl
                                   where sl.run_id = r.id))
                 order by r.created_at desc), '[]'::jsonb)
                from public.lead_scrape_runs r
                where coalesce(r.leads_found,0) > 0 and r.deleted_at is null),
    'max_calls', jsonb_build_object('label','Max API calls','default',800,'min',50,'max',5000),
    'quota', (select to_jsonb(q) from public.lead_scrape_month_usage() q),
    'submit_label','Scrape',
    'result_actions', jsonb_build_array(
      jsonb_build_object('key','keep','label','Keep selected'),
      jsonb_build_object('key','remove','label','Remove selected'))
  );
$fn$;

grant execute on function public.scrape_form_options() to authenticated;

-- ── 11. Exports never carry a deleted run ─────────────────────────────────
comment on column public.lead_scrape_runs.deleted_at is
  'CMD #1870 — set by scrape_run_delete(); the run leaves scrape_runs_list() and the re-scrape source picker, and its leads are archived (restorable for app_settings.lead_archive_days).';
