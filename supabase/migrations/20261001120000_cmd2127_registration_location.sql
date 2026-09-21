-- CMD #2127 — Registration step 2 · Location: a Google map with a pin that
-- FILLS the address, instead of five boxes a shop had to type from memory.
--
-- What #2126 left here was the address section of the old form with the map
-- pin (#1888) sitting in the middle of it, and the map itself never drew:
-- AdaptiveMap treats "no pins" as "nothing to plot" and printed map_config's
-- empty sentence INSTEAD of the map, so the picker was a grey box with a
-- current-location button under it. The approved design (Image A · Step 2) is
-- the opposite shape: the map is the screen, the pin is the input, and the
-- address is an ANSWER the backend writes, shown in a card the person may
-- correct.
--
-- Everything here is backend: the reverse geocode, the card's title and its
-- second line, every label, the Edit sheet and the footer's "Confirm
-- location". Dart draws what this returns and sends back what was typed.
--
-- Zone/date: nothing here lists, counts or reports — it resolves ONE point for
-- the signed-in shop. The document block on step 3 keeps reading
-- admin_active_zone() exactly as #2112 left it.
--
-- Idempotent: add-column IF NOT EXISTS, ON CONFLICT DO NOTHING for copy, a
-- targeted jsonb rewrite of the location step (so a config Om edited keeps its
-- other steps), CREATE OR REPLACE for every function.
begin;

-- ── 1. Landmark is a column, not a sentence squeezed into address ────────
alter table public.pharmacy_profiles add column if not exists landmark text;
comment on column public.pharmacy_profiles.landmark is
  'CMD #2127 — the "near X" line, written by the reverse geocode of the map pin and editable by the shop. Never part of address.';

insert into public.customer_form_field
  (key, section_key, label, hint, field_type, required, sort_order, half_width, contexts, is_active)
values
  ('landmark', 'address', 'Landmark', 'Near…', 'text', false, 85, false,
   array['admin','signup']::text[], true)
on conflict (key) do nothing;

-- ── 2. Copy ──────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('custreg.loc_use_my_location', to_jsonb('Use my location'::text)),
  ('custreg.loc_locating',        to_jsonb('Finding your location…'::text)),
  ('custreg.loc_denied',          to_jsonb('Location is off — drag the map to place the pin.'::text)),
  ('custreg.loc_drag_hint',       to_jsonb('Drag the map to put the pin on your shop door'::text)),
  ('custreg.loc_edit',            to_jsonb('Edit'::text)),
  ('custreg.loc_card_empty_title',to_jsonb('Place the pin on your shop'::text)),
  ('custreg.loc_card_empty_line', to_jsonb('The address fills in from the map.'::text)),
  ('custreg.loc_edit_title',      to_jsonb('Edit address'::text)),
  ('custreg.loc_edit_save',       to_jsonb('Save'::text)),
  ('custreg.loc_edit_cancel',     to_jsonb('Cancel'::text)),
  ('custreg.loc_confirm',         to_jsonb('Confirm location'::text)),
  ('custreg.loc_reading',         to_jsonb('Reading the address…'::text)),
  ('custreg.loc_read_ok',         to_jsonb('Address filled from the map — tap Edit to correct it'::text)),
  ('custreg.loc_read_failed',     to_jsonb('Could not read the address here — tap Edit and type it'::text)),
  ('custreg.loc_map_unavailable', to_jsonb('The map cannot open on this device — tap Edit and type the address'::text))
on conflict (key) do nothing;

-- ── 3. The location step becomes the MAP step ────────────────────────────
-- Only this step's object is rewritten, and only the keys this command owns.
update public.app_settings a
   set value = jsonb_set(a.value, '{steps}', (
         select jsonb_agg(
                  case when s->>'key' = 'location'
                       then s
                            || jsonb_build_object(
                                 'map', true,
                                 'continue_label_key', 'custreg.loc_confirm',
                                 'fields', jsonb_build_array(
                                    'address','landmark','city','state','pincode'))
                       else s end
                  order by o)
           from jsonb_array_elements(a.value->'steps') with ordinality t(s, o)))
 where a.key = 'custreg_wizard'
   and a.value ? 'steps'
   and exists (select 1 from jsonb_array_elements(a.value->'steps') s
                where s->>'key' = 'location'
                  and coalesce((s->>'map')::boolean, false) is not true);

-- Settings the reverse geocoder reads. A key added to geo.reverse_google_key
-- switches the whole lookup to Google with no deploy.
insert into public.app_settings(key, value) values
  ('geo.reverse_endpoint',   to_jsonb('https://nominatim.openstreetmap.org/reverse'::text)),
  ('geo.reverse_google_url', to_jsonb('https://maps.googleapis.com/maps/api/geocode/json'::text)),
  ('geo.reverse_google_key', to_jsonb(''::text)),
  ('geo.reverse_wait_ms',    to_jsonb(6000)),
  ('geo.reverse_cache_days', to_jsonb(180))
on conflict (key) do nothing;

-- ── 4. The reverse geocode ───────────────────────────────────────────────
create extension if not exists http with schema extensions;

create table if not exists public.geo_reverse_cache (
  lat_key    numeric(9,4) not null,
  lng_key    numeric(9,4) not null,
  result     jsonb not null default '{}'::jsonb,
  provider   text,
  fetched_at timestamptz not null default now(),
  primary key (lat_key, lng_key)
);
comment on table public.geo_reverse_cache is
  'CMD #2127 — one answer per ~11 m square (4 decimal places). A shop nudging the pin costs the geocoder nothing after the first read.';

alter table public.geo_reverse_cache enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='geo_reverse_cache'
                    and policyname='geo_reverse_cache_service') then
    create policy geo_reverse_cache_service on public.geo_reverse_cache
      for all to service_role using (true) with check (true);
  end if;
end $$;

-- Pull the pieces out of whatever the provider answered. Verbatim text only —
-- no expansion, no world knowledge, no renaming of a place.
create or replace function public.geo_reverse_parse(p_provider text, p_body jsonb)
returns jsonb
language plpgsql
immutable
set search_path to 'public'
as $function$
declare
  v_a jsonb; v_c jsonb; v_out jsonb := '{}'::jsonb;
  v_addr text; v_land text; v_city text; v_state text; v_pin text; v_dist text;
  v_house text; v_road text;
begin
  if p_body is null or jsonb_typeof(p_body) <> 'object' then return '{}'::jsonb; end if;

  if p_provider = 'google' then
    v_c := p_body->'results'->0->'address_components';
    if v_c is null then return '{}'::jsonb; end if;
    select max(case when c->'types' ? 'street_number' then c->>'long_name' end),
           max(case when c->'types' ? 'route' then c->>'long_name' end),
           max(case when c->'types' ? 'sublocality' or c->'types' ? 'sublocality_level_1'
                     or c->'types' ? 'neighborhood' then c->>'long_name' end),
           max(case when c->'types' ? 'locality' or c->'types' ? 'postal_town'
                    then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_1' then c->>'long_name' end),
           max(case when c->'types' ? 'postal_code' then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_2' then c->>'long_name' end)
      into v_house, v_road, v_land, v_city, v_state, v_pin, v_dist
      from jsonb_array_elements(v_c) c;
    v_addr := nullif(btrim(concat_ws(', ', v_house, v_road)), '');
    if v_addr is null then
      v_addr := nullif(btrim(coalesce(p_body->'results'->0->>'formatted_address','')), '');
    end if;
  else
    v_a := p_body->'address';
    if v_a is null then return '{}'::jsonb; end if;
    v_house := nullif(btrim(coalesce(v_a->>'house_number','')),'');
    v_road  := coalesce(nullif(btrim(coalesce(v_a->>'road','')),''),
                        nullif(btrim(coalesce(v_a->>'pedestrian','')),''),
                        nullif(btrim(coalesce(v_a->>'residential','')),''));
    v_land  := coalesce(nullif(btrim(coalesce(v_a->>'neighbourhood','')),''),
                        nullif(btrim(coalesce(v_a->>'suburb','')),''),
                        nullif(btrim(coalesce(v_a->>'quarter','')),''),
                        nullif(btrim(coalesce(v_a->>'village','')),''));
    v_city  := coalesce(nullif(btrim(coalesce(v_a->>'city','')),''),
                        nullif(btrim(coalesce(v_a->>'town','')),''),
                        nullif(btrim(coalesce(v_a->>'municipality','')),''),
                        nullif(btrim(coalesce(v_a->>'village','')),''));
    v_state := nullif(btrim(coalesce(v_a->>'state','')),'');
    v_pin   := nullif(btrim(coalesce(v_a->>'postcode','')),'');
    v_dist  := coalesce(nullif(btrim(coalesce(v_a->>'state_district','')),''),
                        nullif(btrim(coalesce(v_a->>'county','')),''));
    v_addr := nullif(btrim(concat_ws(', ', v_house, v_road)), '');
    if v_addr is null then
      v_addr := nullif(btrim(coalesce(p_body->>'display_name','')), '');
    end if;
  end if;

  v_out := jsonb_strip_nulls(jsonb_build_object(
    'address',  v_addr,
    'landmark', v_land,
    'city',     v_city,
    'state',    v_state,
    'pincode',  nullif(regexp_replace(coalesce(v_pin,''), '[^0-9]', '', 'g'), ''),
    'district', v_dist));
  return v_out;
end $function$;

-- The synchronous answer for ONE point: cache, then the configured provider
-- (Google when a key is set, otherwise the endpoint #1888 already uses), then
-- the deterministic pincode centroid table as a last enrichment. Never raises:
-- a geocoder that is down leaves the shop typing, it does not break the step.
create or replace function public.geo_reverse(p_lat numeric, p_lng numeric)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_lat numeric(9,4) := round(p_lat, 4);
  v_lng numeric(9,4) := round(p_lng, 4);
  v_days int := coalesce((select (value #>> '{}')::int from app_settings where key='geo.reverse_cache_days'), 180);
  v_wait int := coalesce((select (value #>> '{}')::int from app_settings where key='geo.reverse_wait_ms'), 6000);
  v_on   boolean := coalesce((select (value)::boolean from app_settings where key='geo.geocode_enabled'), true);
  v_gkey text := nullif(btrim(coalesce((select value #>> '{}' from app_settings where key='geo.reverse_google_key'),'')),'');
  v_prov text; v_url text; v_body jsonb; v_out jsonb := '{}'::jsonb;
  v_status int; v_pc_district text; v_pc_state text;
begin
  if p_lat is null or p_lng is null
     or p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 then
    return jsonb_build_object('ok', false, 'source', 'invalid');
  end if;

  select result, provider into v_out, v_prov
    from geo_reverse_cache
   where lat_key = v_lat and lng_key = v_lng
     and fetched_at > now() - make_interval(days => v_days);
  if v_out is not null and v_out <> '{}'::jsonb then
    return v_out || jsonb_build_object('ok', true, 'source', 'cache', 'provider', v_prov);
  end if;
  v_out := '{}'::jsonb;

  if v_on then
    if v_gkey is not null then
      v_prov := 'google';
      v_url := coalesce((select value #>> '{}' from app_settings where key='geo.reverse_google_url'),
                        'https://maps.googleapis.com/maps/api/geocode/json')
            || '?latlng=' || v_lat::text || ',' || v_lng::text
            || '&region=in&key=' || v_gkey;
    else
      v_prov := 'nominatim';
      v_url := coalesce((select value #>> '{}' from app_settings where key='geo.reverse_endpoint'),
                        'https://nominatim.openstreetmap.org/reverse')
            || '?format=jsonv2&addressdetails=1&zoom=18&lat=' || v_lat::text
            || '&lon=' || v_lng::text;
    end if;

    -- pgsql-http, not pg_net: pg_net only DISPATCHES a request after the
    -- calling transaction commits, so a poll inside the same RPC can never see
    -- its own answer (measured — 40 polls, status still null). This call is
    -- synchronous, bounded by the timeout below, and every failure path leaves
    -- the shop typing instead of breaking the step.
    begin
      perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', least(v_wait, 8000)::text);
      select r.status,
             case when r.content is null then null
                  else nullif(btrim(r.content), '')::jsonb end
        into v_status, v_body
        from extensions.http(('GET', v_url,
               array[extensions.http_header('User-Agent', 'mediBO/1.0 (medibo.in)'),
                     extensions.http_header('Accept', 'application/json')],
               null, null)::extensions.http_request) r;
    exception when others then
      v_status := null; v_body := null;
    end;

    if v_status = 200 and v_body is not null then
      v_out := public.geo_reverse_parse(v_prov, v_body);
    end if;
  end if;

  -- Deterministic enrichment: the pincode table fills what the provider left
  -- blank, and a pincode with no city still names its district and state.
  if coalesce(v_out->>'pincode','') <> '' then
    -- SELECT INTO with no row sets the target to NULL, which is how an
    -- unknown pincode would have thrown away a perfectly good answer.
    select pc.district, pc.state into v_pc_district, v_pc_state
      from public.geo_pincode pc
     where pc.pincode = (v_out->>'pincode');
    if v_pc_district is not null or v_pc_state is not null then
      v_out := jsonb_strip_nulls(v_out || jsonb_build_object(
                 'city',  coalesce(nullif(v_out->>'city',''),  v_pc_district),
                 'state', coalesce(nullif(v_out->>'state',''), v_pc_state)));
    end if;
  end if;

  if v_out <> '{}'::jsonb then
    insert into geo_reverse_cache(lat_key, lng_key, result, provider)
    values (v_lat, v_lng, v_out, v_prov)
    on conflict (lat_key, lng_key)
      do update set result = excluded.result, provider = excluded.provider, fetched_at = now();
    return v_out || jsonb_build_object('ok', true, 'source', 'lookup', 'provider', v_prov);
  end if;

  return jsonb_build_object('ok', false, 'source', 'none', 'provider', v_prov);
end $function$;

revoke all on function public.geo_reverse(numeric, numeric) from public, anon;
grant execute on function public.geo_reverse(numeric, numeric) to authenticated, service_role;
revoke all on function public.geo_reverse_parse(text, jsonb) from public, anon;
grant execute on function public.geo_reverse_parse(text, jsonb) to authenticated, service_role;

-- ── 5. The address card, composed here ───────────────────────────────────
-- Title, second line, the boxed fields and their labels. The step renders it
-- verbatim; it never joins two values with a comma of its own.
create or replace function public.custreg_location_card(p_values jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_vals jsonb := coalesce(p_values, '{}'::jsonb);
  v_lab  jsonb;
  v_title text; v_line text; v_fields jsonb;
  v_has  boolean;
begin
  select coalesce(jsonb_object_agg(f.key, coalesce(f.label, f.key)), '{}'::jsonb) into v_lab
    from public.customer_form_field f
   where f.key in ('address','landmark','city','state','pincode');

  v_title := nullif(btrim(coalesce(v_vals->>'address','')), '');
  v_line  := nullif(btrim(concat_ws(', ',
               nullif(btrim(coalesce(v_vals->>'landmark','')), ''),
               nullif(btrim(coalesce(v_vals->>'city','')), ''))), '');
  v_has   := v_title is not null or v_line is not null
             or nullif(btrim(coalesce(v_vals->>'pincode','')),'') is not null;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   k,
           'label', coalesce(v_lab->>k, k),
           'value', coalesce(nullif(btrim(coalesce(v_vals->>k,'')), ''), '')) order by o), '[]'::jsonb)
    into v_fields
    from unnest(array['city','state','pincode']) with ordinality t(k, o);

  return jsonb_build_object(
    'has',         v_has,
    'title',       coalesce(v_title, public._c('custreg.loc_card_empty_title')),
    'line',        coalesce(v_line, public._c('custreg.loc_card_empty_line')),
    'is_empty',    not v_has,
    'edit_label',  public._c('custreg.loc_edit'),
    'fields',      v_fields);
end $function$;

revoke all on function public.custreg_location_card(jsonb) from public, anon;
grant execute on function public.custreg_location_card(jsonb) to authenticated, service_role;

-- The ONE call the step makes: a point moved (reverse geocode, then the card)
-- or an edit saved (no lookup, same card). The values it returns are the
-- values the step keeps — including the maps link, which the shop used to be
-- asked to paste and almost never did.
create or replace function public.custreg_location_resolve(
  p_lat numeric default null,
  p_lng numeric default null,
  p_values jsonb default '{}'::jsonb,
  p_geocode boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_vals jsonb := coalesce(p_values, '{}'::jsonb);
  v_geo  jsonb := '{}'::jsonb;
  v_tmpl text;
  v_note text := '';
  v_tone text := 'neutral';
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;

  if p_lat is not null and p_lng is not null then
    v_vals := v_vals
           || jsonb_build_object('latitude',  round(p_lat, 6)::text,
                                 'longitude', round(p_lng, 6)::text);
    select nullif(btrim(coalesce(point_deeplink,'')),'') into v_tmpl
      from public.map_config order by id limit 1;
    if nullif(btrim(coalesce(v_tmpl,'')),'') is not null then
      v_vals := v_vals || jsonb_build_object('store_location_link',
                  replace(replace(v_tmpl, '{lat}', round(p_lat,6)::text),
                          '{lng}', round(p_lng,6)::text));
    end if;

    if coalesce(p_geocode, true) then
      begin v_geo := public.geo_reverse(p_lat, p_lng);
      exception when others then v_geo := jsonb_build_object('ok', false); end;
      if coalesce((v_geo->>'ok')::boolean, false) then
        -- The pin is the answer: what it reads REPLACES what was there, and
        -- Edit is how a shop disagrees with it.
        v_vals := v_vals || jsonb_strip_nulls(jsonb_build_object(
          'address',  nullif(btrim(coalesce(v_geo->>'address','')), ''),
          'landmark', nullif(btrim(coalesce(v_geo->>'landmark','')), ''),
          'city',     nullif(btrim(coalesce(v_geo->>'city','')), ''),
          'state',    nullif(btrim(coalesce(v_geo->>'state','')), ''),
          'district', nullif(btrim(coalesce(v_geo->>'district','')), ''),
          'pincode',  nullif(btrim(coalesce(v_geo->>'pincode','')), '')));
        v_note := public._c('custreg.loc_read_ok');
        v_tone := 'success';
      else
        v_note := public._c('custreg.loc_read_failed');
        v_tone := 'warning';
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'ok',     true,
    'values', v_vals,
    'card',   public.custreg_location_card(v_vals),
    'note',   v_note,
    'tone',   v_tone,
    'source', coalesce(v_geo->>'source', 'edit'));
end $function$;

revoke all on function public.custreg_location_resolve(numeric, numeric, jsonb, boolean) from public, anon;
grant execute on function public.custreg_location_resolve(numeric, numeric, jsonb, boolean) to authenticated, service_role;

-- ── 6. The step carries its own map block ────────────────────────────────
-- The 7-argument form #2126 created was superseded live by the p_seen one
-- (a tick may not appear before the step has been reached). Two candidates
-- with a defaulted 8th argument make every 7-argument call ambiguous, so the
-- old one goes and the live shape is what this command extends.
drop function if exists public.customer_registration_wizard(jsonb, jsonb, jsonb, boolean, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.customer_registration_wizard(p_schema jsonb, p_values jsonb, p_docs jsonb, p_needs boolean, p_stage text, p_step text, p_prefill jsonb DEFAULT '{}'::jsonb, p_seen integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cfg    jsonb := coalesce((select value from public.app_settings where key = 'custreg_wizard'), '{}'::jsonb);
  v_fields jsonb := coalesce(p_schema->'fields', '[]'::jsonb);
  v_vals   jsonb := coalesce(p_values, '{}'::jsonb);
  v_steps  jsonb := '[]'::jsonb;
  v_total  int;
  v_step   jsonb; v_keys jsonb; v_f jsonb; v_k text;
  v_missing jsonb; v_i int := 0; v_resume int := -1; v_first_open int := -1;
  v_complete boolean; v_known text[] := '{}';
  v_by_key jsonb := '{}'::jsonb; v_done_map jsonb := '{}'::jsonb;
  v_docs_ok boolean; v_lic_any boolean; v_approved boolean;
  v_check jsonb; v_notes jsonb := '{}'::jsonb; v_seen int := greatest(coalesce(p_seen,0),0);
  v_map jsonb;
begin
  if coalesce((v_cfg->>'enabled')::boolean, false) is not true
     or jsonb_array_length(coalesce(v_cfg->'steps','[]'::jsonb)) = 0 then
    return jsonb_build_object('enabled', false);
  end if;

  select coalesce(jsonb_object_agg(f->>'key', f), '{}'::jsonb) into v_by_key
    from jsonb_array_elements(v_fields) f;
  select coalesce(array_agg(x #>> '{}'), '{}') into v_known
    from jsonb_array_elements(v_cfg->'steps') s, jsonb_array_elements(s->'fields') x;
  v_total := jsonb_array_length(v_cfg->'steps');

  for v_step in select value from jsonb_array_elements(v_cfg->'steps') loop
    -- The step's own list, in config order, kept to what the schema carries…
    select coalesce(jsonb_agg(x order by o), '[]'::jsonb) into v_keys
      from jsonb_array_elements_text(coalesce(v_step->'fields','[]'::jsonb)) with ordinality t(x, o)
     where v_by_key ? x;
    -- …plus any REQUIRED signup field no step names, on the step that owns
    -- its section — a new mandatory field can never fall off the flow.
    select v_keys || coalesce(jsonb_agg(f->>'key' order by (f->>'sort_order')::int), '[]'::jsonb)
      into v_keys
      from jsonb_array_elements(v_fields) f
     where coalesce((f->>'required')::boolean, false)
       and not ((f->>'key') = any (v_known))
       and (v_step->'sections') ? (f->>'section');

    v_missing := '[]'::jsonb;
    for v_k in select jsonb_array_elements_text(v_keys) loop
      v_f := v_by_key->v_k;
      if coalesce((v_f->>'required')::boolean, false) then
        if (v_f->>'type') = 'geo' then
          if nullif(btrim(coalesce(v_vals->>'latitude','')),'') is null
             or nullif(btrim(coalesce(v_vals->>'longitude','')),'') is null then
            v_missing := v_missing || to_jsonb(v_f->>'label');
          end if;
        elsif nullif(btrim(coalesce(v_vals->>v_k,'')),'') is null then
          v_missing := v_missing || to_jsonb(v_f->>'label');
        end if;
      end if;
    end loop;
    -- Filled is one thing; BEEN THROUGH is another. The checklist reads the
    -- raw answer (v_done_map); the bar's tick — and a forward jump — need the
    -- step to have been reached, or a step with no required field at all wears
    -- a tick before anybody has opened it.
    v_complete := jsonb_array_length(v_missing) = 0;
    v_done_map := v_done_map || jsonb_build_object(v_step->>'key', v_complete);
    v_complete := v_complete and v_i <= v_seen;
    if not v_complete and v_first_open < 0 then v_first_open := v_i; end if;
    if p_step is not null and (v_step->>'key') = p_step then v_resume := v_i; end if;

    -- CMD #2127 — the map step. Everything the map, the card and the Edit
    -- sheet print lives in this block; the step draws it and composes nothing.
    v_map := null;
    if coalesce((v_step->>'map')::boolean, false) then
      v_map := coalesce(p_schema->'geo', '{}'::jsonb)
            || jsonb_build_object(
                 'use_my_location_label', public._c('custreg.loc_use_my_location'),
                 'locating_label',        public._c('custreg.loc_locating'),
                 'denied_label',          public._c('custreg.loc_denied'),
                 'drag_hint',             public._c('custreg.loc_drag_hint'),
                 'reading_label',         public._c('custreg.loc_reading'),
                 'unavailable_label',     public._c('custreg.loc_map_unavailable'),
                 'card',                  public.custreg_location_card(v_vals),
                 'edit', jsonb_build_object(
                   'title',        public._c('custreg.loc_edit_title'),
                   'save_label',   public._c('custreg.loc_edit_save'),
                   'cancel_label', public._c('custreg.loc_edit_cancel'),
                   'fields', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                              'key',       k,
                              'label',     coalesce(v_by_key->k->>'label', k),
                              'hint',      coalesce(v_by_key->k->>'hint', ''),
                              'multiline', coalesce(v_by_key->k->>'type','') = 'textarea',
                              'numeric',   coalesce(v_by_key->k->>'type','') = 'number',
                              'value',     coalesce(nullif(btrim(coalesce(v_vals->>k,'')),''), ''))
                              order by o), '[]'::jsonb)
                       from unnest(array['address','landmark','city','state','pincode'])
                            with ordinality t(k, o)
                      where v_by_key ? k)));
    end if;

    v_steps := v_steps || jsonb_strip_nulls(jsonb_build_object(
      'key',      v_step->>'key',
      'n',        v_i + 1,
      'label',    public._cf('custreg.wiz_step_label',
                    jsonb_build_object('n', v_i + 1, 'label', public._c(v_step->>'label_key'))),
      'done_label', public._cf('custreg.wiz_step_done_label',
                    jsonb_build_object('n', v_i + 1, 'label', public._c(v_step->>'label_key'))),
      'title',    public._c(v_step->>'title_key'),
      'subtitle', coalesce(public._c(v_step->>'sub_key'), ''),
      'step_of',  public._cf('custreg.wiz_step_of',
                    jsonb_build_object('n', v_i + 1, 'total', v_total)),
      'fields',   v_keys,
      'docs',     coalesce((v_step->>'docs')::boolean, false),
      'map',      v_map,
      'continue_label', case when nullif(btrim(coalesce(v_step->>'continue_label_key','')),'') is not null
                             then public._c(v_step->>'continue_label_key') end,
      'complete', v_complete,
      'missing',  v_missing));
    v_i := v_i + 1;
  end loop;

  -- Resume where the person left (the step saved with the draft); a fresh
  -- start opens on step 1 — never mid-flow on an unsaved guess.
  if v_resume < 0 then v_resume := 0; end if;

  v_docs_ok := coalesce((p_docs->>'required_left')::int, 0) = 0;
  v_lic_any := coalesce(nullif(btrim(coalesce(v_vals->>'dl_20b','')),''),
                        nullif(btrim(coalesce(v_vals->>'dl_21b','')),''),
                        nullif(btrim(coalesce(v_vals->>'gstin','')),'')) is not null;
  v_approved := coalesce(p_stage,'') = 'approved' and not coalesce(p_needs,false);
  -- A licence counts once its number is typed or its paper is on file.
  v_lic_any := v_lic_any or exists (
    select 1 from jsonb_array_elements(coalesce(p_docs->'rows','[]'::jsonb)) r
     where r->>'key' in ('dl_20b','dl_21b') and coalesce((r->>'has_file')::boolean,false));

  -- Done checklist: the shop, its location, the licences, then every other
  -- paper the zone asks for — each Done or Add later.
  v_check := jsonb_build_array(
    jsonb_build_object('key','shop',     'label', public._c('custreg.done_part_shop'),
      'done', coalesce((v_done_map->>'shop')::boolean, false)),
    jsonb_build_object('key','location', 'label', public._c('custreg.done_part_location'),
      'done', coalesce((v_done_map->>'location')::boolean, false)),
    jsonb_build_object('key','licences', 'label', public._c('custreg.done_part_licences'),
      'done', v_lic_any));
  select v_check || coalesce(jsonb_agg(jsonb_build_object(
           'key', r->>'key', 'label', r->>'label',
           'done', coalesce((r->>'has_file')::boolean, false))), '[]'::jsonb)
    into v_check
    from jsonb_array_elements(coalesce(p_docs->'rows','[]'::jsonb)) r
   where coalesce(r->>'key','') not in ('dl_20b','dl_21b');

  -- "Pre-filled from your login" sits under WhatsApp only while the number
  -- on screen is the one the login gave us.
  if nullif(btrim(coalesce(p_prefill->>'whatsapp_no','')),'') is not null
     and btrim(coalesce(p_prefill->>'whatsapp_no','')) = btrim(coalesce(v_vals->>'whatsapp_no','')) then
    v_notes := jsonb_build_object('whatsapp_no', public._c('custreg.wiz_prefilled_note'));
  end if;

  return jsonb_build_object(
    'enabled',        true,
    'steps',          v_steps,
    'total',          v_total,
    'resume_step',    v_resume,
    'first_open',     greatest(v_first_open, 0),
    'continue_label', public._c('custreg.wiz_continue'),
    'back_label',     public._c('custreg.wiz_back'),
    'saving_label',   public._c('custreg.wiz_saving'),
    'submit_label',   public._c('custreg.submit_label'),
    'submitting_label', public._c('custreg.submitting_label'),
    'saved_label',    public._c('custreg.wiz_saved'),
    'chips',          coalesce(v_cfg->'chips', '{}'::jsonb),
    'field_notes',    v_notes,
    'done', jsonb_build_object(
      'title', case when v_approved then public._c('custreg.done_title')
                    else public._c('custreg.done_submitted_title') end,
      'line',  case when v_approved then public._c('custreg.done_line')
                    else public._c('custreg.done_submitted_line') end,
      'checklist', v_check,
      'done_label',  public._c('custreg.done_item_done'),
      'later_label', public._c('custreg.done_item_later'),
      'cta_label',   public._c('custreg.done_browse'),
      'cta_route',   coalesce(v_cfg->>'browse_route', '/')));
end $function$;

revoke all on function public.customer_registration_wizard(jsonb, jsonb, jsonb, boolean, text, text, jsonb, integer) from public, anon, authenticated;
grant execute on function public.customer_registration_wizard(jsonb, jsonb, jsonb, boolean, text, text, jsonb, integer) to service_role;

-- ── 7. Landmark is a column the form may write ───────────────────────────
-- Everything else in this function is #2112's, unchanged: the allowlist gains
-- one key, and submit_registration keeps being handed only the keys it knows.
CREATE OR REPLACE FUNCTION public.customer_registration_submit(p_values jsonb DEFAULT '{}'::jsonb, p_skips jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_cid uuid;
  v_sess jsonb;
  v_allowed text[] := array['pharmacy_name','customer_name','owner_name','phone','whatsapp_no',
                            'other_contact_no','email','address','address_local','city','district',
                            'state','pincode','gstin','gst_no','drug_license','dl_20b','dl_21b',
                            'dl_expiry','store_type','store_location_link','latitude','longitude',
                            'landmark'];
  v_key text; v_sets text[] := '{}'; v_rejected text[] := '{}';
  v_sub jsonb; v_skip text; v_zone smallint;
  v_missing text := ''; v_stage public.registration_stage;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object' or p_values = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','no_values',
                              'message', public._c('custreg.err_no_values'));
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  if v_cid is null then
    -- New shop: the same guarded door every other registration kind uses. It
    -- sets user_id, status and approved itself and refuses a privilege key.
    v_sub := public.submit_registration('pharmacy', p_values - 'dl_expiry' - 'latitude' - 'longitude' - 'landmark');
    v_cid := nullif(v_sub->>'id','')::uuid;
    v_rejected := coalesce((select array_agg(x #>> '{}') from jsonb_array_elements(v_sub->'rejected_keys') x), '{}');
  end if;

  if v_cid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','save_failed',
                              'message', public._c('custreg.err_save'));
  end if;

  -- An imported shop already had a row: the form UPDATES it, and only the
  -- columns the form is allowed to write. Approval state is never among them.
  for v_key in select jsonb_object_keys(p_values) loop
    if v_key = any (v_allowed) then
      if v_key = 'dl_expiry' then
        v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::date', v_key, p_values->>v_key);
      elsif v_key in ('latitude','longitude') then
        v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::numeric', v_key, p_values->>v_key);
      else
        v_sets := v_sets || format('%I = coalesce(nullif(btrim(%L),''''), %I)', v_key, p_values->>v_key, v_key);
      end if;
    else
      v_rejected := v_rejected || v_key;
    end if;
  end loop;

  if array_length(v_sets, 1) is not null then
    execute format('update public.pharmacy_profiles set %s, updated_at = now() where id = %L and user_id = %L',
                   array_to_string(v_sets, ', '), v_cid, v_uid);
    -- A brand-new row was just inserted by submit_registration under this
    -- user, so the user_id guard above always matches. An imported row whose
    -- identity was claimed at login matches too; anything else writes nothing.
  end if;

  select zone_id into v_zone from public.pharmacy_profiles where id = v_cid;

  -- "I don't have this" — recorded on the document ledger with the ledger's
  -- own vocabulary, so every reader (the form, the admin page, the reminder
  -- ladder) sees one truth. It is NOT a submission: the paper is still owed.
  if p_skips is not null and jsonb_typeof(p_skips) = 'array' then
    for v_skip in select x #>> '{}' from jsonb_array_elements(p_skips) x loop
      continue when coalesce(btrim(v_skip),'') = '';
      continue when coalesce(public.custdoc_mode_for(v_zone, v_skip), 'off') = 'off';
      if not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = v_cid
                        and kd.kind = v_skip
                        and kd.status in ('pending','submitted','verified')) then
        insert into public.kyc_documents(owner_kind, owner_id, kind, bucket, path,
                                         status, submitted_by, submitted_at, source, zone_id)
        values ('pharmacy', v_cid, btrim(v_skip), 'kyc-docs', '',
                'not_available', v_uid, now(), 'app', v_zone);
      end if;
    end loop;
  end if;

  begin v_missing := coalesce(public.customer_docs_missing_labels(v_cid), '');
  exception when others then v_missing := ''; end;

  -- The stage the account lands in. A starred paper still out is
  -- "documents" — Docs pending — and customer_approve_gate refuses from there.
  select registration_stage into v_stage from public.pharmacy_profiles where id = v_cid;
  if coalesce(v_stage::text,'') not in ('approved','verified') then
    update public.pharmacy_profiles
       set registration_stage = case when v_missing = '' then 'verified'::public.registration_stage
                                     else 'documents'::public.registration_stage end,
           updated_at = now()
     where id = v_cid;
  end if;

  begin perform public.customer_reg_draft_clear('signup'); exception when others then null; end;

  return jsonb_build_object(
    'ok', true, 'tone', case when v_missing = '' then 'success' else 'warning' end,
    'customer_id', v_cid,
    'message', case when v_missing = '' then public._c('custreg.saved_message')
                    else public._cf('custreg.pending_line', jsonb_build_object('docs', v_missing)) end,
    'docs_pending', (v_missing <> ''),
    'docs_missing', v_missing,
    'rejected_keys', to_jsonb(v_rejected),
    'payload', public.customer_registration_payload());
end $function$;

commit;
