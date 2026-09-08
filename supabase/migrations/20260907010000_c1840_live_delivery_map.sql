-- CMD #1840 — Live delivery map for the customer.
--
-- The backend half. Everything the two customer tracking surfaces (the Track
-- popup in Orders and the public /track/<token> page) need in order to draw a
-- persistent map, a moving rider, a trustworthy staleness line and a rider +
-- vehicle card — all of it decided, worded, coloured and thresholded HERE.
--
-- Five things land:
--   1. vehicle_name / vehicle_number on delivery_partner_registrations, and the
--      config knobs the map + trust line read (heights, the "updating" cutoff,
--      whether a WhatsApp affordance is offered at all).
--   2. _c1840_map_block()    — the map's own presentation contract: the two
--      heights, the expand/collapse words, and whether live tiles are allowed
--      while collapsed. The app never picks a height or writes a label.
--   3. _c1840_trust_block()  — the ONE answer to "can I believe this pin":
--      live / arriving / updating / stale / offline / done, its label, its
--      tone, its last-updated sentence, and `stream` — the backend telling the
--      client to CLOSE the location subscription the moment the stop is over.
--   4. _c1840_rider_card()   — rider name, verified face, vehicle name and
--      number, the masked call action, a WhatsApp affordance the backend
--      decides on, and "stops before you".
--   5. delivery_google_budget() + delivery_google_call — the cost gate. Exactly
--      ONE google-route call per trip, and one more after a reassignment,
--      enforced by a unique key in the database rather than by a comment in
--      Dart. ETA recomputes read the stored per-leg road minutes
--      (delivery_recompute_eta), which calls no API at all.
--
-- Idempotent: every statement is add-if-absent / create-or-replace / upsert.

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SCHEMA
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.delivery_partner_registrations
  add column if not exists vehicle_name   text,
  add column if not exists vehicle_number text;

comment on column public.delivery_partner_registrations.vehicle_name is
  'CMD #1840 — the vehicle as a buyer would name it ("Honda Activa"). Shown on the customer rider card.';
comment on column public.delivery_partner_registrations.vehicle_number is
  'CMD #1840 — registration plate, shown to the buyer so they can identify the vehicle at the door.';

alter table public.delivery_config
  add column if not exists live_updating_after_s int,
  add column if not exists map_collapsed_h       int,
  add column if not exists map_expanded_h        int,
  add column if not exists map_live_when         text,
  add column if not exists customer_wa_enabled   boolean;

update public.delivery_config
   set live_updating_after_s = coalesce(live_updating_after_s, 90),
       map_collapsed_h       = coalesce(map_collapsed_h, 180),
       map_expanded_h        = coalesce(map_expanded_h, 420),
       map_live_when         = coalesce(map_live_when, 'always'),
       customer_wa_enabled   = coalesce(customer_wa_enabled, true)
 where id = 1;

-- The Google cost ledger. One row per (run, route signature); the signature
-- changes when the trip starts and when a stop is reassigned, and nothing else.
create table if not exists public.delivery_google_call (
  run_id      uuid        not null,
  route_sig   text        not null,
  reason      text        not null default 'trip_start',
  called_at   timestamptz not null default now(),
  actor       uuid,
  primary key (run_id, route_sig)
);

comment on table public.delivery_google_call is
  'CMD #1840 — one row per Google route call actually permitted for a run. The primary key IS the budget: a second call for the same route signature cannot be inserted, so it is never made.';

alter table public.delivery_google_call enable row level security;

-- No policy: the table is written only through delivery_google_budget(), which
-- is SECURITY DEFINER. RLS on with no policy is the fence, deliberately.

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. COPY — every word this feature shows. _cf() substitutes SINGLE braces.
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.ui_copy (key, value) values
  ('delivery.map_heading',        '"Live location"'::jsonb),
  ('delivery.map_expand',         '"Expand map"'::jsonb),
  ('delivery.map_collapse',       '"Shrink map"'::jsonb),
  ('delivery.map_updated_at',     '"Updated {time}"'::jsonb),
  ('delivery.map_arriving_now',   '"Arriving now"'::jsonb),
  ('delivery.map_updating',       '"Location updating…"'::jsonb),
  ('delivery.map_stale_note',     '"The last fix is a few minutes old."'::jsonb),
  ('delivery.rider_card_heading', '"Your delivery partner"'::jsonb),
  ('delivery.vehicle_label',      '"Vehicle"'::jsonb),
  ('delivery.wa_button',          '"WhatsApp"'::jsonb),
  ('delivery.wa_rider_msg',       '"Hi, this is about my mediBO order {order}."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. _c1840_map_block — the map's presentation contract.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._c1840_map_block(p_status text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare c record;
begin
  select map_collapsed_h, map_expanded_h, map_live_when
    into c from public.delivery_config where id = 1;

  return jsonb_build_object(
    'has', true,
    'heading',           public._c('delivery.map_heading'),
    'collapsed_height',  coalesce(c.map_collapsed_h, 180),
    'expanded_height',   coalesce(c.map_expanded_h, 420),
    'expand_label',      public._c('delivery.map_expand'),
    'collapse_label',    public._c('delivery.map_collapse'),
    -- 'always' keeps live tiles at both sizes (the widget is never re-created,
    -- so there is no second Google load to save). 'expanded' freezes the
    -- collapsed state WITHOUT unmounting anything.
    'live_when',         coalesce(nullif(c.map_live_when,''), 'always'),
    'starts_expanded',   false);
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. _c1840_trust_block — can this pin be believed, and should the client keep
--    listening at all.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._c1840_trust_block(
  p_updated_at timestamptz,
  p_status     text,
  p_arrival    jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  c record; v_age numeric; v_min int; v_time text;
  v_updated text; v_arr text;
begin
  select live_stale_live_s, live_stale_offline_s, live_updating_after_s
    into c from public.delivery_config where id = 1;

  v_updated := case when p_updated_at is null then ''
    else public._cf('delivery.map_updated_at', jsonb_build_object(
           'time', trim(to_char(p_updated_at at time zone 'Asia/Kolkata', 'HH12:MI am')))) end;

  -- A finished stop is history, not a feed. The client is TOLD to close the
  -- subscription here rather than working out for itself that it may stop.
  if coalesce(p_status,'') not in ('assigned','out_for_delivery') then
    return jsonb_build_object(
      'has', false, 'state', 'done', 'label', '', 'tone', 'muted',
      'age_s', null, 'pin_stale', false, 'updated_label', v_updated,
      'updated_at', p_updated_at, 'stream', 'stop');
  end if;

  -- Inside the geofence the question stops being "is the fix fresh" and
  -- becomes "are they here". The ring was crossed server-side (#703); this
  -- reads its answer, it does not compare a coordinate.
  v_arr := coalesce(p_arrival->>'state','');
  if v_arr in ('here','approaching') then
    return jsonb_build_object(
      'has', true, 'state', 'arriving', 'label', public._c('delivery.map_arriving_now'),
      'tone', 'success',
      'age_s', case when p_updated_at is null then null
                    else round(extract(epoch from (now() - p_updated_at))) end,
      'pin_stale', false, 'updated_label', v_updated,
      'updated_at', p_updated_at, 'stream', 'open');
  end if;

  if p_updated_at is null then
    return jsonb_build_object(
      'has', false, 'state', 'none', 'label', public._c('delivery.live_none'),
      'tone', 'muted', 'age_s', null, 'pin_stale', true,
      'updated_label', '', 'updated_at', null, 'stream', 'open');
  end if;

  v_age := extract(epoch from (now() - p_updated_at));

  if v_age <= coalesce(c.live_stale_live_s, 45) then
    return jsonb_build_object(
      'has', true, 'state', 'live', 'label', public._c('delivery.live_now'),
      'tone', 'success', 'age_s', round(v_age), 'pin_stale', false,
      'updated_label', v_updated, 'updated_at', p_updated_at, 'stream', 'open');
  end if;

  -- The cutoff the spec asks for: past this the pin is NOT presented as the
  -- rider's current position — the line says the location is updating.
  if v_age <= coalesce(c.live_updating_after_s, 90) then
    return jsonb_build_object(
      'has', true, 'state', 'updating', 'label', public._c('delivery.map_updating'),
      'tone', 'info', 'age_s', round(v_age), 'pin_stale', true,
      'updated_label', v_updated, 'updated_at', p_updated_at, 'stream', 'open');
  end if;

  if v_age >= coalesce(c.live_stale_offline_s, 300) then
    return jsonb_build_object(
      'has', true, 'state', 'offline', 'label', public._c('delivery.live_offline'),
      'tone', 'danger', 'age_s', round(v_age), 'pin_stale', true,
      'updated_label', v_updated, 'updated_at', p_updated_at, 'stream', 'open');
  end if;

  v_min := floor(v_age / 60.0)::int;
  return jsonb_build_object(
    'has', true, 'state', 'stale',
    'label', case
               when v_min <= 0 then public._c('delivery.live_seconds')
               when v_min = 1  then public._c('delivery.live_one_minute')
               else public._cf('delivery.live_minutes', jsonb_build_object('n', v_min))
             end,
    'tone', 'warning', 'age_s', round(v_age), 'pin_stale', true,
    'note', public._c('delivery.map_stale_note'),
    'updated_label', v_updated, 'updated_at', p_updated_at, 'stream', 'open');
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. _c1840_rider_card — who is bringing it, on what, and how to reach them.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._c1840_rider_card(
  p_delivery_id uuid,
  p_eta         jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  d public.deliveries%rowtype; r record; v_code text;
  v_wa_on boolean; v_mask_on boolean; v_phone text; v_wa jsonb; v_ahead text;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null or d.partner_id is null then
    return jsonb_build_object('has', false);
  end if;

  select full_name, vehicle_name, vehicle_number, vehicle_type, phone
    into r from public.delivery_partner_registrations where id = d.partner_id;
  if r is null then return jsonb_build_object('has', false); end if;

  select coalesce(customer_wa_enabled, true) into v_wa_on
    from public.delivery_config where id = 1;
  select coalesce(enabled,false) into v_mask_on from public.call_config where id;
  select coalesce(order_code,'') into v_code from public.orders where id = d.order_id;

  -- WhatsApp opens a chat, and a chat cannot be masked. So when the masking
  -- layer is ON, the rider's number is not disclosed through this door either
  -- — the affordance is simply absent, which is the masking layer working, not
  -- a missing feature. The whole URL is built here; the app only opens it.
  v_phone := regexp_replace(coalesce(r.phone,''), '[^0-9]', '', 'g');
  if length(v_phone) = 10 then v_phone := '91' || v_phone; end if;

  v_wa := case
    when coalesce(v_wa_on,true) and not coalesce(v_mask_on,false)
         and length(v_phone) >= 11
         and d.status in ('assigned','out_for_delivery')
    then jsonb_build_object(
           'has', true,
           'label', public._c('delivery.wa_button'),
           'url', 'https://wa.me/' || v_phone || '?text=' ||
                  replace(replace(public._cf('delivery.wa_rider_msg',
                            jsonb_build_object('order', v_code)), ' ', '%20'), '#', '%23'))
    else jsonb_build_object('has', false) end;

  v_ahead := coalesce(p_eta->>'stops_ahead_label','');

  return jsonb_build_object(
    'has',      true,
    'heading',  public._c('delivery.rider_card_heading'),
    'name',     coalesce(nullif(r.full_name,''), ''),
    'photo',    public._rider_photo_block(d.partner_id, d.status),
    'vehicle',  jsonb_build_object(
                  'has',    (coalesce(nullif(r.vehicle_name,''),
                                      nullif(r.vehicle_type,'')) is not null
                             or nullif(r.vehicle_number,'') is not null),
                  'label',  public._c('delivery.vehicle_label'),
                  'name',   coalesce(nullif(r.vehicle_name,''), nullif(r.vehicle_type,''), ''),
                  'number', coalesce(nullif(r.vehicle_number,''), '')),
    'call',     public._call_action_block('customer','delivery', d.order_id),
    'whatsapp', v_wa,
    'stops_before', jsonb_build_object(
                  'has',   (v_ahead <> ''),
                  'label', v_ahead));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. delivery_google_budget — the cost gate, enforced by a unique key.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._c1840_route_sig(p_run_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $fn$
  -- The trip's identity for costing purposes: when it started, and which rider
  -- holds which stop. A reassignment changes it (a new call is allowed); a stop
  -- being COMPLETED does not (no new call — the ETA rebases from stored legs).
  select md5(
    coalesce((select started_at::text from public.delivery_runs where id = p_run_id), '-')
    || '|' ||
    coalesce((select string_agg(d.id::text || ':' || coalesce(d.partner_id::text,'-')
                                || ':' || coalesce(d.assigned_at::text,'-'), ','
                                order by d.id)
                from public.deliveries d
               where d.run_id = p_run_id
                 and coalesce(d.status,'') not in ('delivered','cancelled')), '-'));
$fn$;

create or replace function public.delivery_google_budget(
  p_run_id uuid,
  p_reason text default 'trip_start'
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_sig text; v_ins int;
begin
  if p_run_id is null then
    return jsonb_build_object('ok', false, 'allow', false, 'reason', 'no_run');
  end if;

  v_sig := public._c1840_route_sig(p_run_id);

  insert into public.delivery_google_call (run_id, route_sig, reason, actor)
  values (p_run_id, v_sig, coalesce(nullif(p_reason,''), 'trip_start'), auth.uid())
  on conflict (run_id, route_sig) do nothing;

  get diagnostics v_ins = row_count;

  return jsonb_build_object(
    'ok', true,
    'allow', (v_ins = 1),
    'route_sig', v_sig,
    'reason', case when v_ins = 1 then coalesce(nullif(p_reason,''),'trip_start')
                   else 'already_routed' end,
    'calls_for_run', (select count(*) from public.delivery_google_call
                       where run_id = p_run_id));
end $fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. GRANTS — a new function is granted to PUBLIC by Postgres, and anon
--    inherits that. Every one of these is fenced explicitly (lesson #197).
-- ─────────────────────────────────────────────────────────────────────────────

revoke all on function public._c1840_map_block(text)                     from public, anon;
revoke all on function public._c1840_trust_block(timestamptz, text, jsonb) from public, anon;
revoke all on function public._c1840_rider_card(uuid, jsonb)             from public, anon;
revoke all on function public._c1840_route_sig(uuid)                     from public, anon;
revoke all on function public.delivery_google_budget(uuid, text)         from public, anon;

grant execute on function public._c1840_map_block(text)                     to authenticated, service_role;
grant execute on function public._c1840_trust_block(timestamptz, text, jsonb) to authenticated, service_role;
grant execute on function public._c1840_rider_card(uuid, jsonb)             to authenticated, service_role;
grant execute on function public._c1840_route_sig(uuid)                     to authenticated, service_role;
grant execute on function public.delivery_google_budget(uuid, text)         to authenticated, service_role;

commit;
