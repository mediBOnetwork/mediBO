-- CMD #1873 — Route stops: check in with Visited / Closed / Not interested /
-- Converted, a note, a photo proof, and a write-back to the lead.
--
-- Before this, the only way to close a stop was record_visit(), the GPS
-- correction engine: it REQUIRES a fix within 500 m, owns eight statuses of
-- its own and knows nothing about route_plan_stops. A rep walking a planned
-- route had no way to mark THE STOP done, so route_plan_stops carried no
-- outcome at all and routes_today()'s progress line could only infer one from
-- a lead_visits row someone happened to file.
--
-- This adds the outcome to the stop itself (visit_status / visited_at /
-- visited_by / note / photo_url), one RPC to write it, and ONE trigger that
-- pushes it back onto scraped_leads. Every string below is backend-owned and
-- printed verbatim by Flutter.
--
-- Idempotent: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, ON CONFLICT DO
-- NOTHING, DROP TRIGGER IF EXISTS + CREATE.

-- ── 1. The stop carries its own outcome ───────────────────────────────────
alter table public.route_plan_stops
  add column if not exists visit_status text,
  add column if not exists visited_at   timestamptz,
  add column if not exists visited_by   uuid,
  add column if not exists note         text,
  add column if not exists photo_url    text;

create index if not exists route_plan_stops_visit_status_idx
  on public.route_plan_stops (route_id, visit_status);

-- ── 2. Settings + copy (wording is an UPDATE, never a deploy) ─────────────
insert into app_settings(key, value) values
  ('lead_revisit_days',    '30'::jsonb),
  ('storage_public_base',  '"https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public"'::jsonb)
on conflict (key) do nothing;

insert into ui_copy(key, value) values
  ('route_stop.title',            '"Check in"'::jsonb),
  ('route_stop.subtitle',         '"Stop {seq} · {name}"'::jsonb),
  ('route_stop.opt_visited',      '"Visited"'::jsonb),
  ('route_stop.opt_closed',       '"Closed"'::jsonb),
  ('route_stop.opt_not_interested','"Not interested"'::jsonb),
  ('route_stop.opt_converted',    '"Converted"'::jsonb),
  ('route_stop.hint_visited',     '"Met the shop, nothing more to record."'::jsonb),
  ('route_stop.hint_closed',      '"Shutter down right now — try another day."'::jsonb),
  ('route_stop.hint_not_interested','"Says no. Parked for {days} days."'::jsonb),
  ('route_stop.hint_converted',   '"Signed up — this shop is now a customer."'::jsonb),
  ('route_stop.note_label',       '"Note"'::jsonb),
  ('route_stop.note_hint',        '"What happened at this shop? (optional)"'::jsonb),
  ('route_stop.photo_label',      '"Photo proof"'::jsonb),
  ('route_stop.photo_take',       '"Take photo"'::jsonb),
  ('route_stop.photo_retake',     '"Retake"'::jsonb),
  ('route_stop.photo_open',       '"View photo"'::jsonb),
  ('route_stop.submit',           '"Save check-in"'::jsonb),
  ('route_stop.submitting',       '"Saving…"'::jsonb),
  ('route_stop.cancel',           '"Cancel"'::jsonb),
  ('route_stop.pick_first',       '"Pick an outcome first."'::jsonb),
  ('route_stop.saved',            '"{name} — {status}."'::jsonb),
  ('route_stop.saved_revisit',    '"{name} — {status}. Back on a route after {date}."'::jsonb),
  ('route_stop.not_found',        '"That stop is no longer on this route."'::jsonb),
  ('route_stop.not_authorized',   '"You cannot check in on this route."'::jsonb),
  ('route_stop.bad_status',       '"Unknown outcome."'::jsonb),
  ('route_stop.stops_title',      '"Stops"'::jsonb),
  ('route_stop.stops_one',        '"1 stop"'::jsonb),
  ('route_stop.stops_many',       '"{n} stops"'::jsonb),
  ('route_stop.stops_empty',      '"No stops on this route yet."'::jsonb),
  ('route_stop.stops_locked',     '"This route is not in the active zone or date."'::jsonb),
  ('route_stop.checkin_action',   '"Check in"'::jsonb),
  ('route_stop.redo_action',      '"Change"'::jsonb),
  ('route_stop.skip_action',      '"Skip"'::jsonb),
  ('route_stop.closed_at_eta',    '"Closed at ETA"'::jsonb),
  ('route_stop.eta',              '"ETA {eta}"'::jsonb),
  ('route_stop.note_line',        '"Note: {note}"'::jsonb),
  ('route_stop.done_at',          '"{status} · {time}"'::jsonb),
  ('route_stop.pending',          '"Not checked in"'::jsonb)
on conflict (key) do nothing;

create or replace function public._c1873_revisit_days()
returns integer
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- app_settings.lead_revisit_days is a jsonb number; a string ("30") and a
  -- missing row both fall back to 30 rather than raising inside a trigger.
  select coalesce(
    nullif(regexp_replace((select value #>> '{}' from app_settings where key='lead_revisit_days'), '[^0-9]', '', 'g'), '')::int,
    30);
$function$;

-- ── 3. One place that knows the four outcomes ─────────────────────────────
-- Label, tone and hint per status, built from ui_copy. Every surface (the
-- sheet's buttons, the stop row's chip, the toast) reads THIS, so a wording
-- change is one UPDATE on ui_copy and nothing else.
create or replace function public._c1873_status_meta(p_status text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case p_status
    when 'visited' then jsonb_build_object(
      'key','visited','tone','success',
      'label', coalesce((select value #>> '{}' from ui_copy where key='route_stop.opt_visited'), 'Visited'),
      'hint',  coalesce((select value #>> '{}' from ui_copy where key='route_stop.hint_visited'), ''))
    when 'closed' then jsonb_build_object(
      'key','closed','tone','warning',
      'label', coalesce((select value #>> '{}' from ui_copy where key='route_stop.opt_closed'), 'Closed'),
      'hint',  coalesce((select value #>> '{}' from ui_copy where key='route_stop.hint_closed'), ''))
    when 'not_interested' then jsonb_build_object(
      'key','not_interested','tone','danger',
      'label', coalesce((select value #>> '{}' from ui_copy where key='route_stop.opt_not_interested'), 'Not interested'),
      'hint',  replace(coalesce((select value #>> '{}' from ui_copy where key='route_stop.hint_not_interested'), ''),
                       '{days}', public._c1873_revisit_days()::text))
    when 'converted' then jsonb_build_object(
      'key','converted','tone','brand',
      'label', coalesce((select value #>> '{}' from ui_copy where key='route_stop.opt_converted'), 'Converted'),
      'hint',  coalesce((select value #>> '{}' from ui_copy where key='route_stop.hint_converted'), ''))
    else null end;
$function$;

-- ── 4. The write-back trigger ─────────────────────────────────────────────
-- The stop is the record; the lead learns from it. visit_count only ever
-- moves when the OUTCOME changes (re-saving the same status re-stamps the
-- time and the note but does not inflate the count), so a rep fixing a typo
-- in his note cannot make a shop look visited twice.
create or replace function public._c1873_stop_writeback()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_days int := public._c1873_revisit_days();
begin
  if new.visit_status is null then return new; end if;
  if tg_op = 'UPDATE' and old.visit_status is not distinct from new.visit_status then
    return new;
  end if;
  if new.lead_id is null then return new; end if;

  update scraped_leads set
    visit_count       = coalesce(visit_count, 0) + 1,
    last_visit_at     = coalesce(new.visited_at, now()),
    last_visit_status = new.visit_status,
    revisit_after     = case when new.visit_status = 'not_interested'
                          then ((now() at time zone 'Asia/Kolkata')::date + v_days)
                          else revisit_after end
  where id = new.lead_id;

  return new;
end;
$function$;

drop trigger if exists _c1873_stop_writeback_trg on public.route_plan_stops;
create trigger _c1873_stop_writeback_trg
  after insert or update of visit_status on public.route_plan_stops
  for each row execute function public._c1873_stop_writeback();

-- ── 5. Photo bucket ───────────────────────────────────────────────────────
-- lead-photos is public-read so the proof opens from the stop row with no
-- signing round-trip. Policy creation is wrapped: on a database where the
-- migration runner does not own storage.objects the bucket still lands and
-- the deploy is not taken down by a permission error.
insert into storage.buckets (id, name, public)
values ('lead-photos', 'lead-photos', true)
on conflict (id) do nothing;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='c1873 lead-photos read') then
    execute $p$create policy "c1873 lead-photos read" on storage.objects
              for select using (bucket_id = 'lead-photos')$p$;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='c1873 lead-photos write') then
    execute $p$create policy "c1873 lead-photos write" on storage.objects
              for insert to authenticated with check (bucket_id = 'lead-photos')$p$;
  end if;
  if not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='c1873 lead-photos update') then
    execute $p$create policy "c1873 lead-photos update" on storage.objects
              for update to authenticated using (bucket_id = 'lead-photos')$p$;
  end if;
exception when insufficient_privilege then
  raise notice 'c1873: storage.objects policies skipped (not owner)';
end $$;

-- ── 6. May this caller work this route? ───────────────────────────────────
-- Admin/super admin: any route whose assignment is on admin_active_date() and
-- whose city matches admin_active_zone(). A lead worker: only his OWN route,
-- same date and zone rules. Zone and date live in the header picker and are
-- read here — never passed in from Dart.
create or replace function public._c1873_route_ok(p_route_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
      from route_plan_routes rr
      join route_plans      pp on pp.id = rr.plan_id
      join lead_assignments aa on aa.id = rr.assignment_id
     where rr.id = p_route_id
       and aa.for_date = public.admin_active_date()
       and public._c1872_zone_match(public.admin_active_zone(), pp.city, aa.zone_id)
       and (get_my_role() in ('admin','super_admin')
            or rr.worker_id = public.my_worker_id()));
$function$;

-- ── 7. The stop list a route card expands into ────────────────────────────
create or replace function public.route_stops_today(p_route_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy  jsonb;
  v_rows  jsonb := '[]'::jsonb;
  v_n     integer := 0;
  r       record;
  v_meta  jsonb;
  v_shut  boolean;
  v_acts  jsonb;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  if not public._c1873_route_ok(p_route_id) then
    return jsonb_build_object(
      'ok', false, 'route_id', p_route_id, 'stops', '[]'::jsonb,
      'title',       coalesce(v_copy->>'route_stop.stops_title', 'Stops'),
      'count_label', '',
      'empty_label', coalesce(v_copy->>'route_stop.stops_locked',
                              'This route is not in the active zone or date.'));
  end if;

  for r in
    select st.id as stop_id, st.lead_id, st.seq, st.eta_min, st.open_at_eta,
           st.visit_status, st.visited_at, st.note, st.photo_url,
           l.name, coalesce(nullif(btrim(l.short_address), ''), l.address) as addr,
           pp.start_min
      from route_plan_stops st
      join scraped_leads    l  on l.id = st.lead_id
      join route_plan_routes rr on rr.id = st.route_id
      join route_plans      pp on pp.id = rr.plan_id
     where st.route_id = p_route_id and st.included
     order by st.seq
  loop
    v_meta := public._c1873_status_meta(r.visit_status);
    -- "Closed at ETA" is a WARNING about the shop's hours, not an outcome:
    -- it disappears the moment the stop has one, so a rep who checked in
    -- anyway is never told the shop was shut.
    v_shut := (r.open_at_eta is false) and r.visit_status is null;

    v_acts := '[]'::jsonb;
    v_acts := v_acts || jsonb_build_object(
      'key',   'checkin',
      'label', case when r.visit_status is null
                 then coalesce(v_copy->>'route_stop.checkin_action', 'Check in')
                 else coalesce(v_copy->>'route_stop.redo_action', 'Change') end,
      'tone',  'brand');
    if v_shut then
      -- One tap: the Skip button posts THIS status to route_stop_checkin.
      -- Dart never decides what skipping means.
      v_acts := v_acts || jsonb_build_object(
        'key',    'skip',
        'label',  coalesce(v_copy->>'route_stop.skip_action', 'Skip'),
        'status', 'closed',
        'tone',   'warning');
    end if;

    v_rows := v_rows || jsonb_build_object(
      'stop_id',      r.stop_id,
      'lead_id',      r.lead_id,
      'seq',          r.seq,
      'name',         coalesce(r.name, ''),
      'address',      coalesce(r.addr, ''),
      'eta_label',    case when r.eta_min is not null then
                        replace(coalesce(v_copy->>'route_stop.eta', 'ETA {eta}'), '{eta}',
                          to_char((time '00:00' + make_interval(
                            mins => coalesce(r.start_min, 0) + r.eta_min))::time,
                            'FMHH12:MI AM')) end,
      'closed_label', case when v_shut then
                        coalesce(v_copy->>'route_stop.closed_at_eta', 'Closed at ETA') end,
      'is_closed_at_eta', v_shut,
      'status_key',   r.visit_status,
      'status_label', case when v_meta is not null then
                        replace(replace(
                          coalesce(v_copy->>'route_stop.done_at', '{status} · {time}'),
                          '{status}', v_meta->>'label'),
                          '{time}', to_char(r.visited_at at time zone 'Asia/Kolkata', 'FMHH12:MI AM'))
                      else coalesce(v_copy->>'route_stop.pending', 'Not checked in') end,
      'status_tone',  coalesce(v_meta->>'tone', 'neutral'),
      'note_label',   case when nullif(btrim(coalesce(r.note, '')), '') is not null then
                        replace(coalesce(v_copy->>'route_stop.note_line', 'Note: {note}'),
                                '{note}', btrim(r.note)) end,
      'photo_url',    r.photo_url,
      'photo_label',  case when r.photo_url is not null then
                        coalesce(v_copy->>'route_stop.photo_open', 'View photo') end,
      'actions',      v_acts
    );
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object(
    'ok',          true,
    'route_id',    p_route_id,
    'title',       coalesce(v_copy->>'route_stop.stops_title', 'Stops'),
    'count_label', case when v_n = 1
                     then coalesce(v_copy->>'route_stop.stops_one', '1 stop')
                     else replace(coalesce(v_copy->>'route_stop.stops_many', '{n} stops'),
                                  '{n}', v_n::text) end,
    'count',       v_n,
    'stops',       v_rows,
    'empty_label', case when v_n = 0 then
                     coalesce(v_copy->>'route_stop.stops_empty',
                              'No stops on this route yet.') end);
end;
$function$;

-- ── 8. The sheet's own payload ────────────────────────────────────────────
create or replace function public.route_stop_sheet(p_stop_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy jsonb;
  v_st   record;
  v_opts jsonb := '[]'::jsonb;
  v_key  text;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  select s.id, s.route_id, s.seq, s.visit_status, s.note, s.photo_url, l.name
    into v_st
    from route_plan_stops s
    join scraped_leads l on l.id = s.lead_id
   where s.id = p_stop_id;

  if not found then
    return jsonb_build_object('ok', false, 'can_check_in', false,
      'blocked_label', coalesce(v_copy->>'route_stop.not_found',
                                'That stop is no longer on this route.'));
  end if;

  if not public._c1873_route_ok(v_st.route_id) then
    return jsonb_build_object('ok', false, 'can_check_in', false,
      'blocked_label', coalesce(v_copy->>'route_stop.not_authorized',
                                'You cannot check in on this route.'));
  end if;

  foreach v_key in array array['visited','closed','not_interested','converted'] loop
    v_opts := v_opts || public._c1873_status_meta(v_key);
  end loop;

  return jsonb_build_object(
    'ok',           true,
    'can_check_in', true,
    'stop_id',      v_st.id,
    'title',        coalesce(v_copy->>'route_stop.title', 'Check in'),
    'subtitle',     replace(replace(
                      coalesce(v_copy->>'route_stop.subtitle', 'Stop {seq} · {name}'),
                      '{seq}',  v_st.seq::text),
                      '{name}', coalesce(v_st.name, '')),
    'options',      v_opts,
    'selected',     v_st.visit_status,
    'note',         jsonb_build_object(
                      'label', coalesce(v_copy->>'route_stop.note_label', 'Note'),
                      'hint',  coalesce(v_copy->>'route_stop.note_hint', ''),
                      'value', coalesce(v_st.note, '')),
    'photo',        jsonb_build_object(
                      'label',        coalesce(v_copy->>'route_stop.photo_label', 'Photo proof'),
                      'bucket',       'lead-photos',
                      'take_label',   coalesce(v_copy->>'route_stop.photo_take', 'Take photo'),
                      'retake_label', coalesce(v_copy->>'route_stop.photo_retake', 'Retake'),
                      'open_label',   coalesce(v_copy->>'route_stop.photo_open', 'View photo'),
                      'url',          v_st.photo_url),
    'submit_label',     coalesce(v_copy->>'route_stop.submit', 'Save check-in'),
    'submitting_label', coalesce(v_copy->>'route_stop.submitting', 'Saving…'),
    'cancel_label',     coalesce(v_copy->>'route_stop.cancel', 'Cancel'),
    'pick_label',       coalesce(v_copy->>'route_stop.pick_first', 'Pick an outcome first.'));
end;
$function$;

-- ── 9. The write ──────────────────────────────────────────────────────────
-- p_photo is a PATH inside lead-photos; the public URL is assembled here so
-- no Dart ever builds a storage URL. The lead_visits row keeps the existing
-- visit ledger (and routes_today()'s progress line) honest — the write-back
-- to scraped_leads is the trigger's job, never this function's, so both
-- entry points agree.
create or replace function public.route_stop_checkin(
  p_stop_id uuid,
  p_status  text,
  p_note    text default null,
  p_photo   text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy   jsonb;
  v_st     record;
  v_meta   jsonb;
  v_url    text;
  v_base   text;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
  v_worker uuid := public.my_worker_id();
  v_lead   scraped_leads%rowtype;
  v_msg    text;
begin
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
    into v_copy from ui_copy where key like 'route_stop.%';

  v_meta := public._c1873_status_meta(p_status);
  if v_meta is null then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', coalesce(v_copy->>'route_stop.bad_status', 'Unknown outcome.'));
  end if;

  select s.id, s.route_id, s.lead_id, rr.assignment_id, l.name
    into v_st
    from route_plan_stops s
    join route_plan_routes rr on rr.id = s.route_id
    join scraped_leads     l  on l.id = s.lead_id
   where s.id = p_stop_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'stop_not_found',
      'message', coalesce(v_copy->>'route_stop.not_found',
                          'That stop is no longer on this route.'));
  end if;

  if not public._c1873_route_ok(v_st.route_id) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', coalesce(v_copy->>'route_stop.not_authorized',
                          'You cannot check in on this route.'));
  end if;

  if nullif(btrim(coalesce(p_photo, '')), '') is not null then
    v_base := coalesce((select value #>> '{}' from app_settings where key='storage_public_base'),
                       'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public');
    v_url  := v_base || '/lead-photos/' || btrim(p_photo);
  end if;

  update route_plan_stops set
    visit_status = p_status,
    visited_at   = now(),
    visited_by   = auth.uid(),
    note         = v_note,
    photo_url    = coalesce(v_url, photo_url)
  where id = p_stop_id;

  insert into lead_visits (lead_id, worker_id, assignment_id, status, note,
                           photo_url, verified, suspicious)
  values (v_st.lead_id, v_worker, v_st.assignment_id, p_status, v_note,
          v_url, true, false);

  select * into v_lead from scraped_leads where id = v_st.lead_id;

  if p_status = 'not_interested' and v_lead.revisit_after is not null then
    v_msg := replace(replace(replace(
               coalesce(v_copy->>'route_stop.saved_revisit',
                        '{name} — {status}. Back on a route after {date}.'),
               '{name}',   coalesce(v_st.name, '')),
               '{status}', v_meta->>'label'),
               '{date}',   to_char(v_lead.revisit_after, 'FMDD Mon YYYY'));
  else
    v_msg := replace(replace(
               coalesce(v_copy->>'route_stop.saved', '{name} — {status}.'),
               '{name}',   coalesce(v_st.name, '')),
               '{status}', v_meta->>'label');
  end if;

  return jsonb_build_object(
    'ok',            true,
    'stop_id',       p_stop_id,
    'lead_id',       v_st.lead_id,
    'status',        p_status,
    'status_label',  v_meta->>'label',
    'status_tone',   v_meta->>'tone',
    'photo_url',     v_url,
    'visit_count',   v_lead.visit_count,
    'revisit_after', v_lead.revisit_after,
    'message',       v_msg);
end;
$function$;

grant execute on function public._c1873_revisit_days() to authenticated;
grant execute on function public._c1873_status_meta(text) to authenticated;
grant execute on function public._c1873_route_ok(uuid) to authenticated;
grant execute on function public.route_stops_today(uuid) to authenticated;
grant execute on function public.route_stop_sheet(uuid) to authenticated;
grant execute on function public.route_stop_checkin(uuid, text, text, text) to authenticated;
