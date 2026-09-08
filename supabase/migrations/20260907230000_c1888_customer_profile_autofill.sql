-- CHANGE #1888 — Customer profile auto-fill.
--
-- The data this fixes (measured on live before the change): latitude/longitude
-- null on 10 of 12 shops, store_location_link null on 11, district null on 8,
-- gst null on 9 with no way to say "I don't have one", payment_term null on 4.
--
-- Every one of those is a field a HUMAN was expected to type, and nobody did.
-- After this change none of them is typed:
--   • the pin is PICKED on a map (mandatory on self-signup, and the backend
--     refuses a save without it);
--   • an import with no coordinates is GEOCODED by the backend;
--   • store_location_link and district are DERIVED by a trigger from lat/lng
--     and pincode, and recomputed whenever either changes — they are not
--     writable fields any more, whatever anybody puts in them;
--   • "no GST" is an explicit answer (gst_status='none'), not a null;
--   • payment_term defaults to Cash on Delivery, and Advance is a logged
--     decision with a reason.
--
-- Idempotent: safe to replay on live.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. Columns and the GST status enum
-- ─────────────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'public' and t.typname = 'gst_status_kind') then
    create type public.gst_status_kind as enum ('none','pending','verified');
  end if;
end $$;

alter table public.pharmacy_profiles
  add column if not exists gst_status      public.gst_status_kind,
  add column if not exists location_source text,
  add column if not exists located_at      timestamptz,
  add column if not exists geo_status      text;

comment on column public.pharmacy_profiles.gst_status IS
  'CHANGE #1888 — explicit: none = the shop said it has no GSTIN, pending = a GSTIN was given and is not verified yet, verified = KYC verified it. Null only on rows nobody has answered for yet.';
comment on column public.pharmacy_profiles.location_source IS
  'CHANGE #1888 — how latitude/longitude got here: pin (picked on the map), geocoded (backend geocoded the address), lead (copied from the converted lead).';
comment on column public.pharmacy_profiles.store_location_link IS
  'CHANGE #1888 — DERIVED from latitude/longitude by trg_a1_c1888_derive. Never typed; anything written here is overwritten.';
comment on column public.pharmacy_profiles.district IS
  'CHANGE #1888 — DERIVED from pincode via geo_pincode by trg_a1_c1888_derive whenever the pincode is known. Never typed.';

-- payment_term defaults to COD from here on.
alter table public.pharmacy_profiles
  alter column payment_term set default 'Cash on Delivery';

-- ─────────────────────────────────────────────────────────────────────────
-- 2. pincode -> district / state / centroid, and the async lookup queue
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.geo_pincode (
  pincode    text primary key,
  district   text,
  state      text,
  lat        double precision,
  lng        double precision,
  source     text        not null default 'seed',
  updated_at timestamptz not null default now()
);

create table if not exists public.geo_lookup_queue (
  id          bigserial primary key,
  kind        text        not null,              -- 'pincode' | 'address'
  ref_id      text,                              -- pharmacy_profiles.id for 'address'
  query       text        not null,
  request_id  bigint,
  status      text        not null default 'queued',  -- queued|sent|done|error
  note        text,
  created_at  timestamptz not null default now(),
  done_at     timestamptz
);
create index if not exists geo_lookup_queue_open_idx
  on public.geo_lookup_queue (status, created_at) where status in ('queued','sent');

alter table public.geo_pincode       enable row level security;
alter table public.geo_lookup_queue  enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public'
                   and tablename='geo_pincode' and policyname='geo_pincode_read') then
    create policy geo_pincode_read on public.geo_pincode for select using (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public'
                   and tablename='geo_lookup_queue' and policyname='geo_lookup_queue_admin') then
    create policy geo_lookup_queue_admin on public.geo_lookup_queue
      for select using (public.is_admin());
  end if;
end $$;

grant select on public.geo_pincode to anon, authenticated;

-- Seed the lookup from the data mediBO already holds. Every shop and every
-- scraped lead that carries a pincode WITH a district is one row of truth.
insert into public.geo_pincode (pincode, district, state, lat, lng, source)
select pin,
       mode() within group (order by d)  filter (where d is not null),
       mode() within group (order by st) filter (where st is not null),
       avg(la) filter (where la is not null),
       avg(ln) filter (where ln is not null),
       'seed'
from (
  select regexp_replace(coalesce(pp.pincode,''), '\D', '', 'g') as pin,
         public.norm_district(pp.district) as d,
         nullif(btrim(coalesce(pp.state,'')),'') as st,
         pp.latitude as la, pp.longitude as ln
    from public.pharmacy_profiles pp
   where coalesce(pp.is_deleted,false) = false
  union all
  select regexp_replace(coalesce(sl.pincode,''), '\D', '', 'g'),
         public.norm_district(sl.district),
         nullif(btrim(coalesce(sl.state,'')),''),
         sl.lat, sl.lng
    from public.scraped_leads sl
) s
where pin ~ '^[0-9]{6}$'
group by pin
having mode() within group (order by d) filter (where d is not null) is not null
on conflict (pincode) do update
  set district   = coalesce(public.geo_pincode.district, excluded.district),
      state      = coalesce(public.geo_pincode.state, excluded.state),
      lat        = coalesce(public.geo_pincode.lat, excluded.lat),
      lng        = coalesce(public.geo_pincode.lng, excluded.lng),
      updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────
-- 3. The derivations — the two fields nobody types
-- ─────────────────────────────────────────────────────────────────────────
-- The maps link is a TEMPLATE in app_settings, so changing it (or moving to
-- another map host) is an UPDATE, never a deploy.
insert into public.app_settings (key, value) values
  ('geo.maps_link_template', '"https://www.google.com/maps?q={lat},{lng}"'::jsonb),
  ('geo.geocode_endpoint',   '"https://nominatim.openstreetmap.org/search"'::jsonb),
  ('geo.geocode_enabled',    'true'::jsonb)
on conflict (key) do nothing;

create or replace function public.geo_maps_link(p_lat double precision, p_lng double precision)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case when p_lat is null or p_lng is null then null
              else replace(replace(
                     coalesce((select value #>> '{}' from app_settings where key = 'geo.maps_link_template'),
                              'https://www.google.com/maps?q={lat},{lng}'),
                     '{lat}', trim(to_char(p_lat, 'FM999990.999999'))),
                     '{lng}', trim(to_char(p_lng, 'FM999990.999999'))) end;
$function$;

grant execute on function public.geo_maps_link(double precision, double precision) to authenticated, service_role;

create or replace function public.geo_pincode_row(p_pin text)
returns public.geo_pincode
language sql
stable
security definer
set search_path to 'public'
as $function$
  select gp.* from geo_pincode gp
   where gp.pincode = regexp_replace(coalesce(p_pin,''), '\D', '', 'g')
   limit 1;
$function$;

grant execute on function public.geo_pincode_row(text) to authenticated, service_role;

-- Minimal percent-encoder: the query goes into a URL, and a shop name with a
-- '&' in it must not become two query parameters.
create or replace function public.geo_url_encode(p text)
returns text
language sql
immutable
as $function$
  select coalesce((
    select string_agg(
             case when ch ~ '^[A-Za-z0-9_.~-]$' then ch
                  when ch = ' ' then '+'
                  else (select string_agg('%' || upper(hx), '')
                          from regexp_split_to_table(encode(convert_to(ch,'UTF8'),'hex'), '(?<=..)(?=..)') hx)
             end, '' order by ord)
      from regexp_split_to_table(coalesce(p,''), '') with ordinality as s(ch, ord)
  ), '');
$function$;

-- Queue one address (or one bare pincode) for the fallback geocoder. pg_net is
-- asynchronous by nature, so this records the request and geo_collect() applies
-- the answer. Never raises: a geocoder that is down must not block a save.
create or replace function public.geo_enqueue(p_kind text, p_query text, p_ref text default null)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id  bigint;
  v_url text;
  v_req bigint;
  v_on  boolean := coalesce((select (value)::boolean from app_settings where key='geo.geocode_enabled'), true);
  v_ep  text := coalesce((select value #>> '{}' from app_settings where key='geo.geocode_endpoint'),
                         'https://nominatim.openstreetmap.org/search');
begin
  if nullif(btrim(coalesce(p_query,'')),'') is null then return null; end if;

  -- One open request per query is enough.
  select id into v_id from geo_lookup_queue
   where query = btrim(p_query) and status in ('queued','sent') limit 1;
  if v_id is not null then return v_id; end if;

  insert into geo_lookup_queue (kind, ref_id, query, status)
  values (p_kind, p_ref, btrim(p_query), 'queued')
  returning id into v_id;

  if not v_on then return v_id; end if;

  v_url := v_ep
        || '?format=jsonv2&addressdetails=1&limit=1&countrycodes=in&q='
        || public.geo_url_encode(btrim(p_query));

  begin
    select net.http_get(
             url := v_url,
             headers := jsonb_build_object(
               'User-Agent', 'mediBO/1.0 (medibo.in)',
               'Accept', 'application/json'),
             timeout_milliseconds := 8000)
      into v_req;
    update geo_lookup_queue set request_id = v_req, status = 'sent' where id = v_id;
  exception when others then
    update geo_lookup_queue set status = 'error', note = left(sqlerrm, 200), done_at = now()
     where id = v_id;
  end;

  return v_id;
end $function$;

grant execute on function public.geo_enqueue(text, text, text) to service_role;

-- geo_collect() — drain whatever the geocoder answered and APPLY it. Called
-- opportunistically before every geocode, and by the cron dispatcher.
create or replace function public.geo_collect()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  q       record;
  body    jsonb;
  hit     jsonb;
  v_lat   double precision;
  v_lng   double precision;
  v_dist  text;
  v_state text;
  v_pin   text;
  n_ok    int := 0;
  n_err   int := 0;
begin
  for q in select * from geo_lookup_queue
            where status = 'sent' and request_id is not null
            order by id limit 50 loop
    body := null;
    begin
      select case when jsonb_typeof(r.content::jsonb) = 'array' then r.content::jsonb end
        into body
        from net._http_response r
       where r.id = q.request_id and r.status_code between 200 and 299;
    exception when others then
      body := null;
    end;

    if body is null then
      -- Not answered yet (or unparseable). Give up after an hour.
      if q.created_at < now() - interval '1 hour' then
        update geo_lookup_queue set status='error', note='no usable response', done_at=now() where id=q.id;
        n_err := n_err + 1;
      end if;
      continue;
    end if;

    hit := body -> 0;
    if hit is null then
      update geo_lookup_queue set status='error', note='no match', done_at=now() where id=q.id;
      n_err := n_err + 1;
      continue;
    end if;

    v_lat   := nullif(hit->>'lat','')::double precision;
    v_lng   := nullif(hit->>'lon','')::double precision;
    v_dist  := public.norm_district(coalesce(
                 hit#>>'{address,state_district}',
                 hit#>>'{address,county}',
                 hit#>>'{address,district}'));
    v_state := nullif(btrim(coalesce(hit#>>'{address,state}','')),'');
    v_pin   := nullif(regexp_replace(coalesce(hit#>>'{address,postcode}',''), '\D', '', 'g'),'');

    if v_pin ~ '^[0-9]{6}$' then
      insert into geo_pincode (pincode, district, state, lat, lng, source)
      values (v_pin, v_dist, v_state, v_lat, v_lng, 'geocoder')
      on conflict (pincode) do update
        set district   = coalesce(excluded.district, geo_pincode.district),
            state      = coalesce(excluded.state, geo_pincode.state),
            lat        = coalesce(geo_pincode.lat, excluded.lat),
            lng        = coalesce(geo_pincode.lng, excluded.lng),
            source     = 'geocoder',
            updated_at = now();
    end if;

    if q.kind = 'address' and q.ref_id is not null and v_lat is not null then
      update pharmacy_profiles
         set latitude        = coalesce(latitude, v_lat),
             longitude       = coalesce(longitude, v_lng),
             location_source = coalesce(location_source, 'geocoded'),
             located_at      = coalesce(located_at, now()),
             geo_status      = 'geocoded'
       where id = q.ref_id::uuid
         and coalesce(is_deleted,false) = false;
    end if;

    update geo_lookup_queue set status='done', done_at=now(),
           note = coalesce(v_dist,'') || case when v_lat is null then '' else ' @' || v_lat || ',' || v_lng end
     where id = q.id;
    n_ok := n_ok + 1;
  end loop;

  return jsonb_build_object('ok', true, 'applied', n_ok, 'failed', n_err);
end $function$;

grant execute on function public.geo_collect() to service_role;

-- geo_geocode() — the synchronous answer. Deterministic first (the pincode
-- lookup mediBO already owns); the network is only the fallback, and it fills
-- the lookup so the next shop in that pincode never needs it.
create or replace function public.geo_geocode(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_pin  text := nullif(regexp_replace(coalesce(p->>'pincode',''), '\D', '', 'g'), '');
  r      public.geo_pincode;
  v_q    text;
begin
  perform public.geo_collect();

  if v_pin ~ '^[0-9]{6}$' then
    r := public.geo_pincode_row(v_pin);
  end if;

  v_q := nullif(btrim(concat_ws(', ',
           nullif(btrim(coalesce(p->>'address','')),''),
           nullif(btrim(coalesce(p->>'city','')),''),
           nullif(btrim(coalesce(p->>'state','')),''),
           v_pin, 'India')), '');

  if r.lat is not null and r.lng is not null then
    -- Known pincode centroid. Still queue the full address so the pin lands on
    -- the shop rather than the middle of the postal area.
    if v_q is not null then perform public.geo_enqueue('address', v_q, p->>'ref_id'); end if;
    return jsonb_build_object(
      'ok', true, 'lat', r.lat, 'lng', r.lng,
      'district', r.district, 'state', r.state,
      'source', 'geocoded', 'via', 'pincode_centroid');
  end if;

  if v_q is not null then perform public.geo_enqueue('address', v_q, p->>'ref_id'); end if;

  return jsonb_build_object(
    'ok', false, 'lat', null, 'lng', null,
    'district', r.district, 'state', r.state,
    'source', null, 'via', 'queued');
end $function$;

grant execute on function public.geo_geocode(jsonb) to service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The trigger: store_location_link and district are DERIVED, never typed
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._c1888_profile_derive()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_pin  text;
  r      public.geo_pincode;
  v_moved boolean;
begin
  NEW.pincode := coalesce(nullif(regexp_replace(coalesce(NEW.pincode,''), '\D', '', 'g'), ''), NEW.pincode);
  v_pin := nullif(regexp_replace(coalesce(NEW.pincode,''), '\D', '', 'g'), '');

  v_moved := TG_OP = 'INSERT'
          or NEW.latitude  is distinct from OLD.latitude
          or NEW.longitude is distinct from OLD.longitude
          or coalesce(NEW.pincode,'') is distinct from coalesce(OLD.pincode,'');

  -- The two derived fields are recomputed on EVERY write, not only when the
  -- coordinates move: "never typed by anyone" has to hold against a direct
  -- UPDATE that puts a hand-written link back into the column.
  -- (a) the maps link is the coordinates, formatted. Nothing else.
  NEW.store_location_link := public.geo_maps_link(NEW.latitude, NEW.longitude);

  -- (b) the district is the pincode, looked up.
  if v_pin ~ '^[0-9]{6}$' then
    r := public.geo_pincode_row(v_pin);
    if r.district is not null then
      NEW.district := r.district;
    end if;
    if NEW.state is null or btrim(NEW.state) = '' then
      NEW.state := coalesce(r.state, NEW.state);
    end if;
    if r.district is null and v_moved then
      -- Unknown pincode: ask the fallback, and let geo_collect() fill it in.
      NEW.geo_status := coalesce(NEW.geo_status, 'pincode_unknown');
      perform public.geo_enqueue('pincode', v_pin || ', India', NEW.id::text);
    end if;
  end if;

  -- A district still normalises even when the pincode could not answer, so a
  -- typed "bhilai" never becomes a district of its own.
  NEW.district := public.norm_district(NEW.district);

  if NEW.latitude is not null and NEW.longitude is not null then
    NEW.located_at      := coalesce(NEW.located_at, now());
    NEW.location_source := coalesce(NEW.location_source, 'pin');
    NEW.geo_status      := 'located';
  end if;

  -- The zone follows the district, so let the zone trigger re-decide.
  if TG_OP = 'UPDATE' and NEW.district is distinct from OLD.district then
    NEW.zone_id := null;
  end if;

  return NEW;
end $function$;

drop trigger if exists trg_a1_c1888_derive on public.pharmacy_profiles;
create trigger trg_a1_c1888_derive
  before insert or update on public.pharmacy_profiles
  for each row execute function public._c1888_profile_derive();

-- ─────────────────────────────────────────────────────────────────────────
-- 5. GST — "none" is an answer, and a GSTIN that is typed must be a GSTIN
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.gst_apply(p_gstin text, p_none boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_g text := upper(nullif(regexp_replace(coalesce(p_gstin,''), '\s', '', 'g'), ''));
begin
  if coalesce(p_none,false) then
    return jsonb_build_object('gstin', null, 'gst_status', 'none');
  end if;
  if v_g is null then
    return jsonb_build_object('gstin', null, 'gst_status', null);
  end if;
  if not public.kyc_gstin_checksum_ok(v_g) then
    raise exception '%', public._c('customer_form.gst_invalid');
  end if;
  return jsonb_build_object('gstin', v_g, 'gst_status', 'pending');
end $function$;

grant execute on function public.gst_apply(text, boolean) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. payment_term — COD by default, Advance is a logged decision
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.customer_payment_term_log (
  id          bigserial primary key,
  customer_id uuid not null references public.pharmacy_profiles(id) on delete cascade,
  zone_id     smallint,
  from_term   text,
  to_term     text not null,
  reason      text not null,
  changed_by  uuid,
  changed_at  timestamptz not null default now()
);
create index if not exists customer_payment_term_log_cust_idx
  on public.customer_payment_term_log (customer_id, changed_at desc);

alter table public.customer_payment_term_log enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public'
                   and tablename='customer_payment_term_log' and policyname='cptl_admin_read') then
    create policy cptl_admin_read on public.customer_payment_term_log
      for select using (public.is_admin());
  end if;
end $$;

-- The one write. Zone-scoped: a partner may only re-term a shop in its own
-- zone, a super admin with no zone picked may re-term any. A reason is not
-- optional — that is the whole point of the log.
create or replace function public.customer_set_payment_term(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id     uuid := nullif(btrim(p->>'customer_id'),'')::uuid;
  v_term   text := nullif(btrim(p->>'payment_term'),'');
  v_reason text := nullif(btrim(p->>'reason'),'');
  v_zone   smallint := public.admin_active_zone();
  v_allowed jsonb := public.customer_form_options()->'payment_term';
  r        record;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;
  if v_id is null then raise exception 'customer_id is required'; end if;
  if v_term is null or not (v_allowed ? v_term) then
    raise exception '%', public._c('customer_form.term_invalid');
  end if;
  if v_reason is null or length(v_reason) < 3 then
    raise exception '%', public._c('customer_form.term_reason_required');
  end if;

  select id, zone_id, payment_term into r
    from pharmacy_profiles
   where id = v_id and coalesce(is_deleted,false) = false;
  if not found then raise exception 'customer_not_found'; end if;
  if v_zone is not null and coalesce(r.zone_id, -1) <> v_zone then
    raise exception '%', public._c('customer_form.term_out_of_zone');
  end if;

  update pharmacy_profiles set payment_term = v_term where id = v_id;

  insert into customer_payment_term_log (customer_id, zone_id, from_term, to_term, reason, changed_by)
  values (v_id, r.zone_id, r.payment_term, v_term, v_reason, auth.uid());

  return jsonb_build_object(
    'ok', true, 'customer_id', v_id,
    'payment_term', v_term,
    'message', public._c('customer_form.term_saved'));
end $function$;

grant execute on function public.customer_set_payment_term(jsonb) to authenticated, service_role;

-- What the payment-term sheet renders. Zone- and date-scoped like every list.
create or replace function public.customer_payment_term_panel(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_id   uuid := nullif(btrim(p->>'customer_id'),'')::uuid;
  v_zone smallint := public.admin_active_zone();
  v_day  date := public.admin_active_date();
  r      record;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;

  select pp.id, pp.zone_id, pp.pharmacy_name, pp.payment_term into r
    from pharmacy_profiles pp
   where pp.id = v_id and coalesce(pp.is_deleted,false) = false
     and (v_zone is null or pp.zone_id = v_zone);

  if not found then
    return jsonb_build_object('ok', false, 'title', public._c('customer_form.term_out_of_zone'),
                              'options', '[]'::jsonb, 'history', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'ok', true,
    'customer_id', r.id,
    'title',           public._c('customer_form.term_title'),
    'subtitle',        public._c('customer_form.term_subtitle'),
    'reason_label',    public._c('customer_form.term_reason_label'),
    'reason_hint',     public._c('customer_form.term_reason_hint'),
    'save_label',      public._c('customer_form.term_save'),
    'history_label',   public._c('customer_form.term_history'),
    'empty_label',     public._c('customer_form.term_history_empty'),
    'current',         coalesce(r.payment_term, 'Cash on Delivery'),
    'current_label',   coalesce(r.payment_term, 'Cash on Delivery'),
    'options',         public.customer_form_options()->'payment_term',
    'as_of',           to_char(v_day, 'DD Mon YYYY'),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
               'line', coalesce(l.from_term, '—') || ' → ' || l.to_term,
               'reason', l.reason,
               'when', to_char(l.changed_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM'))
             order by l.changed_at desc)
        from customer_payment_term_log l
       where l.customer_id = r.id
         and l.changed_at < ((v_day + 1)::timestamp at time zone 'Asia/Kolkata')), '[]'::jsonb));
end $function$;

grant execute on function public.customer_payment_term_panel(jsonb) to authenticated, service_role;

insert into public.ui_copy (key, value) values
  ('customer_form.gst_invalid',          '"That GSTIN is not valid. Check it, or tick \"I don''t have GST\"."'::jsonb),
  ('customer_form.gst_none_label',       '"I don''t have GST"'::jsonb),
  ('customer_form.gst_required',         '"Enter the GSTIN, or tick \"I don''t have GST\"."'::jsonb),
  ('customer_form.pin_required',         '"Drop the pin on your shop before saving."'::jsonb),
  ('customer_form.pin_label',            '"Shop location"'::jsonb),
  ('customer_form.pin_hint',             '"Drag the map so the pin sits on your shop door."'::jsonb),
  ('customer_form.pin_use_device',       '"Use my current location"'::jsonb),
  ('customer_form.pin_locating',         '"Finding you…"'::jsonb),
  ('customer_form.pin_denied',           '"Location is off. Drag the map to your shop instead."'::jsonb),
  ('customer_form.pin_set',              '"Pin set"'::jsonb),
  ('customer_form.pin_none',             '"No pin yet"'::jsonb),
  ('customer_form.term_title',           '"Payment term"'::jsonb),
  ('customer_form.term_subtitle',        '"Cash on Delivery unless there is a reason to change it."'::jsonb),
  ('customer_form.term_reason_label',    '"Reason"'::jsonb),
  ('customer_form.term_reason_hint',     '"Why this shop pays differently"'::jsonb),
  ('customer_form.term_save',            '"Save payment term"'::jsonb),
  ('customer_form.term_history',         '"Changes"'::jsonb),
  ('customer_form.term_history_empty',   '"Never changed."'::jsonb),
  ('customer_form.term_saved',           '"Payment term saved."'::jsonb),
  ('customer_form.term_invalid',         '"Pick one of the listed payment terms."'::jsonb),
  ('customer_form.term_reason_required', '"Give a reason before changing the payment term."'::jsonb),
  ('customer_form.term_out_of_zone',     '"That shop is not in your zone."'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. The ONE field list gains a map pin and a GST answer, and loses the three
--    fields nobody may type any more
-- ─────────────────────────────────────────────────────────────────────────
alter table public.customer_form_field
  add column if not exists required_in text[];

comment on column public.customer_form_field.required_in IS
  'CHANGE #1888 — contexts in which this field is REQUIRED. Null falls back to the flat `required` flag. The map pin is required on self-signup and geocoded on import, which one boolean could not say.';

-- The pin, and the explicit GST answer.
insert into public.customer_form_field
  (key, section_key, label, field_type, options_key, required, required_in,
   sort_order, half_width, max_lines, contexts, hint, default_value) values
  ('store_pin', 'address', 'Shop location', 'geo', null, false, array['signup'],
   125, false, 1, array['admin','signup'], 'Drag the map so the pin sits on your shop door.', null),
  ('gst_none',  'statutory', 'I don''t have GST', 'checkbox', null, false, null,
   175, false, 1, array['admin','signup'], null, null)
on conflict (key) do update
  set section_key   = excluded.section_key,
      label         = excluded.label,
      field_type    = excluded.field_type,
      required      = excluded.required,
      required_in   = excluded.required_in,
      sort_order    = excluded.sort_order,
      half_width    = excluded.half_width,
      contexts      = excluded.contexts,
      hint          = excluded.hint,
      is_active     = true;

-- Derived fields are not typed. They come back on the customer CARD, not in
-- the form.
update public.customer_form_field
   set is_active = false
 where key in ('district','store_location_link','latitude','longitude');

-- Cash on Delivery is what a new shop gets unless somebody decides otherwise.
update public.customer_form_field
   set default_value = 'Cash on Delivery'
 where key = 'payment_term';

create or replace function public.customer_form_schema(p_context text default 'admin')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_ctx  text := case lower(btrim(coalesce(p_context,'admin')))
                   when 'signup'       then 'signup'
                   when 'lead_convert' then 'admin'
                   else 'admin' end;
  v_raw  text := lower(btrim(coalesce(p_context,'admin')));
  v_opts jsonb := public.customer_form_options();
  v_map  jsonb := public.map_config_get();
  v_fields jsonb;
  v_sections jsonb;
begin
  select coalesce(jsonb_agg(f order by (f->>'sort_order')::int), '[]'::jsonb)
    into v_fields
  from (
    select jsonb_build_object(
             'key',         cf.key,
             'section',     cf.section_key,
             'label',       cf.label,
             'hint',        cf.hint,
             'type',        cf.field_type,
             'required',    case when cf.required_in is not null
                                 then v_ctx = any (cf.required_in)
                                 else cf.required end,
             'sort_order',  cf.sort_order,
             'half_width',  cf.half_width,
             'max_lines',   cf.max_lines,
             'default',     cf.default_value,
             'options',     case when cf.options_key is null then '[]'::jsonb
                                 else coalesce(v_opts->cf.options_key, '[]'::jsonb) end
           ) as f
    from public.customer_form_field cf
    where cf.is_active and v_ctx = any (cf.contexts)
  ) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', cs.key, 'title', cs.title,
           'fields', coalesce((
             select jsonb_agg(x order by (x->>'sort_order')::int)
             from jsonb_array_elements(v_fields) x
             where x->>'section' = cs.key), '[]'::jsonb))
         order by cs.sort_order), '[]'::jsonb)
    into v_sections
  from public.customer_form_section cs
  where cs.is_active
    and exists (select 1 from jsonb_array_elements(v_fields) x where x->>'section' = cs.key);

  return jsonb_build_object(
    'ok', true,
    'context', v_raw,
    'title', case v_raw
               when 'signup'       then public._c('customer_form.title_signup')
               when 'lead_convert' then public._c('customer_form.title_lead_convert')
               else public._c('customer_form.title_admin') end,
    'subtitle',        public._c('customer_form.subtitle'),
    'required_suffix', public._c('customer_form.required_suffix'),
    'loading_label',   public._c('customer_form.loading'),
    'flag_label',      public._c('customer_form.flag_check_this'),
    'missing_required_message', public._c('customer_form.missing_required'),
    'save_label',      public._c('customer_form.btn_save'),
    'cancel_label',    public._c('customer_form.btn_cancel'),
    -- CHANGE #1888 — everything the map pin renders. The picker writes
    -- latitude/longitude; it decides nothing else.
    'geo', jsonb_build_object(
      'lat_key',        'latitude',
      'lng_key',        'longitude',
      'use_device_label', public._c('customer_form.pin_use_device'),
      'locating_label', public._c('customer_form.pin_locating'),
      'denied_label',   public._c('customer_form.pin_denied'),
      'set_label',      public._c('customer_form.pin_set'),
      'none_label',     public._c('customer_form.pin_none'),
      'missing_message', public._c('customer_form.pin_required'),
      'default_center', v_map->'default_center',
      'default_zoom',   coalesce(v_map->'default_zoom', to_jsonb(14))),
    'gst', jsonb_build_object(
      'none_key',       'gst_none',
      'gstin_key',      'gstin',
      'invalid_message', public._c('customer_form.gst_invalid'),
      'missing_message', public._c('customer_form.gst_required')),
    'sections',        v_sections,
    'fields',          v_fields,
    'required_fields', coalesce((select jsonb_agg(x->>'key')
                                   from jsonb_array_elements(v_fields) x
                                  where (x->>'required')::boolean), '[]'::jsonb)
  );
end $function$;

grant execute on function public.customer_form_schema(text) to anon, authenticated, service_role;

-- customer_form_options().required_fields must agree with the per-context flag.
create or replace function public.customer_form_options()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_core int; v_ext int; v_marg int;
begin
  select coalesce(core_km,25), coalesce(ext_km,60), coalesce(marg_km,120)
    into v_core, v_ext, v_marg
  from lead_hub order by updated_at desc nulls last limit 1;
  v_core := coalesce(v_core,25); v_ext := coalesce(v_ext,60); v_marg := coalesce(v_marg,120);

  return jsonb_build_object(
    'store_type', jsonb_build_array(
      'Retail Pharmacy','Hospital Pharmacy','Clinic','Medical Store','Wholesaler','Nursing Home','Other'),
    'payment_term', jsonb_build_array(
      'Cash on Delivery','Advance Payment','Credit 7 days','Credit 15 days','Credit 30 days'),
    'range_zone', jsonb_build_array(
      'Local (0–' || v_core || ' km)',
      'Extended (' || v_core || '–' || v_ext || ' km)',
      'Outer (' || v_ext || '–' || v_marg || ' km)',
      'Outstation (' || v_marg || '+ km)'),
    'single_select', coalesce((select jsonb_agg(key order by sort_order)
                                 from customer_form_field
                                where is_active and field_type = 'select'), '[]'::jsonb),
    'hidden_fields', jsonb_build_array('customer_code','address_local'),
    'required_fields', coalesce((select jsonb_agg(key order by sort_order)
                                   from customer_form_field
                                  where is_active
                                    and (case when required_in is not null
                                              then 'signup' = any(required_in) else required end)), '[]'::jsonb));
end $function$;

grant execute on function public.customer_form_options() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. The two save paths
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.admin_import_customer(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_id    uuid;
  v_uid   uuid := nullif(btrim(p->>'user_id'), '')::uuid;
  v_made_login boolean := false;
  v_name  text := nullif(btrim(p->>'pharmacy_name'), '');
  v_owner text := nullif(btrim(p->>'customer_name'), '');
  v_phone text := nullif(public._phone10(coalesce(p->>'phone','')), '');
  v_wa    text := nullif(public._phone10(coalesce(p->>'whatsapp_no','')), '');
  v_other text := nullif(public._phone10(coalesce(p->>'other_contact_no','')), '');
  v_code  text := nullif(btrim(p->>'customer_code'), '');
  v_addr  text := nullif(btrim(p->>'address'), '');
  v_city  text := nullif(btrim(p->>'city'), '');
  v_pin   text := nullif(regexp_replace(coalesce(p->>'pincode',''), '\D', '', 'g'), '');
  v_lat   double precision := nullif(btrim(coalesce(p->>'latitude','')),'')::double precision;
  v_lng   double precision := nullif(btrim(coalesce(p->>'longitude','')),'')::double precision;
  v_zone  text := nullif(btrim(p->>'range_zone'), '');
  v_src   text := nullif(btrim(p->>'location_source'), '');
  v_geo   jsonb;
  v_gst   jsonb;
  v_term  text := coalesce(nullif(btrim(p->>'payment_term'),''), 'Cash on Delivery');
  v_stage public.registration_stage;
  v_dupe  record;
  v_req   text[];
  k       text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'not_authorized'; END IF;

  -- Required set is the SAME data the one field list marks required, for THIS
  -- context, so the form and the write can never disagree. The map pin is not
  -- in it: an import with no coordinates is geocoded below, not refused.
  select coalesce(array_agg(key order by sort_order), '{}')
    into v_req
    from customer_form_field
   where is_active and 'admin' = any(contexts)
     and field_type not in ('geo','checkbox')
     and (case when required_in is not null then 'admin' = any(required_in) else required end);

  foreach k in array v_req loop
    if nullif(btrim(coalesce(p->>k,'')),'') is null then
      raise exception '% is required',
        coalesce((select label from customer_form_field where key = k), k);
    end if;
  end loop;

  IF v_wa IS NULL OR length(v_wa) <> 10 THEN
    RAISE EXCEPTION 'a valid 10-digit WhatsApp number is required';
  END IF;
  IF v_pin IS NOT NULL AND length(v_pin) <> 6 THEN
    RAISE EXCEPTION 'pincode must be 6 digits, got %', v_pin;
  END IF;

  -- CHANGE #1888 — GST is an explicit answer, never a silent null.
  v_gst := public.gst_apply(coalesce(p->>'gstin', p->>'gst_no'),
                            coalesce((p->>'gst_none')::boolean, false));

  SELECT pharmacy_name, customer_code INTO v_dupe
    FROM pharmacy_profiles
   WHERE coalesce(is_deleted,false) = false
     AND public._phone10(coalesce(whatsapp_no, phone,'')) IN (coalesce(v_wa,'~'), coalesce(v_phone,'~'))
   LIMIT 1;
  IF v_dupe.pharmacy_name IS NOT NULL THEN
    RAISE EXCEPTION 'this number already belongs to % (%)', v_dupe.pharmacy_name, v_dupe.customer_code;
  END IF;

  IF v_uid IS NULL THEN
    v_uid := public.auth_user_for_whatsapp(v_wa, jsonb_build_object('pharmacy_name', v_name));
    v_made_login := true;
  ELSIF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid) THEN
    RAISE EXCEPTION 'user_id % does not exist in auth.users', v_uid;
  END IF;

  IF EXISTS (SELECT 1 FROM pharmacy_profiles pp
              WHERE pp.user_id = v_uid AND coalesce(pp.is_deleted,false) = false) THEN
    RAISE EXCEPTION 'this login already has a customer profile';
  END IF;

  IF v_code IS NULL THEN
    v_code := public.next_customer_code(v_name);
  ELSIF public.is_customer_code_taken(v_code) THEN
    RAISE EXCEPTION 'customer_code % already taken', v_code;
  END IF;

  -- CHANGE #1888 — no pin on an import? The backend geocodes the address it
  -- was given rather than storing a shop with no location.
  IF v_lat IS NULL OR v_lng IS NULL THEN
    v_geo := public.geo_geocode(jsonb_build_object(
               'address', v_addr, 'city', v_city,
               'state', nullif(btrim(p->>'state'),''), 'pincode', v_pin));
    IF (v_geo->>'ok')::boolean THEN
      v_lat := (v_geo->>'lat')::double precision;
      v_lng := (v_geo->>'lng')::double precision;
      v_src := coalesce(v_src, 'geocoded');
    END IF;
  ELSE
    v_src := coalesce(v_src, 'pin');
  END IF;

  IF v_zone IS NULL AND v_lat IS NOT NULL AND v_lng IS NOT NULL THEN
    v_zone := public.range_zone_for(v_lat, v_lng)->>'range_zone';
  END IF;

  INSERT INTO pharmacy_profiles (
    user_id, pharmacy_name, customer_name, owner_name,
    phone, whatsapp_no, other_contact_no, email,
    address, address_local, city, state, pincode,
    latitude, longitude, location_source,
    store_type, range_zone, payment_term,
    gstin, gst_no, gst_status, drug_license, dl_20b, dl_21b, dl_expiry,
    customer_code, approved, is_deleted
  ) VALUES (
    v_uid, v_name, v_owner, v_owner,
    coalesce(v_phone, v_wa), v_wa, v_other, nullif(btrim(p->>'email'),''),
    v_addr, v_addr, coalesce(v_city,''), nullif(btrim(p->>'state'),''), coalesce(v_pin,''),
    v_lat, v_lng, v_src,
    nullif(btrim(p->>'store_type'),''), v_zone, v_term,
    v_gst->>'gstin', v_gst->>'gstin', (v_gst->>'gst_status')::public.gst_status_kind,
    nullif(concat_ws(' / ', nullif(btrim(p->>'dl_20b'),''), nullif(btrim(p->>'dl_21b'),'')),''),
    nullif(btrim(p->>'dl_20b'),''), nullif(btrim(p->>'dl_21b'),''),
    nullif(btrim(coalesce(p->>'dl_expiry','')),'')::date,
    v_code, false, false
  )
  RETURNING id, registration_stage INTO v_id, v_stage;

  -- Still no coordinates? Ask the fallback geocoder for THIS shop, so
  -- geo_collect() drops the pin on it without anybody typing.
  IF v_lat IS NULL AND v_addr IS NOT NULL THEN
    PERFORM public.geo_enqueue('address',
      concat_ws(', ', v_addr, v_city, nullif(btrim(p->>'state'),''), v_pin, 'India'),
      v_id::text);
    UPDATE pharmacy_profiles SET geo_status = 'geocode_queued' WHERE id = v_id;
  END IF;

  UPDATE login_identities
     SET kind = 'whatsapp'
   WHERE identity = public.identity_norm(v_wa)
     AND owner_type = 'customer' AND owner_id = v_id::text;

  RETURN jsonb_build_object(
    'status','ok', 'ok', true,
    'customer', (SELECT to_jsonb(pp) FROM pharmacy_profiles pp WHERE pp.id = v_id),
    'customer_id', v_id,
    'customer_code', v_code,
    'user_id', v_uid,
    'login_created', v_made_login,
    'range_zone', v_zone,
    'approved', false,
    'geocoded', (v_lat is not null and coalesce(v_src,'') = 'geocoded'),
    'location_source', v_src,
    'registration_stage', v_stage,
    'stage_label', coalesce(public.customer_stage_chip(v_stage)->>'label', v_stage::text),
    'message', public._c('customer_form.saved_message'));
END $function$;

-- Self-signup: the pin is MANDATORY. The backend refuses the save without it,
-- so a shop can never reach the catalogue without a location.
create or replace function public.save_customer_profile(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id   uuid := public.my_customer_id();
  v_uid  uuid := auth.uid();
  v_addr text := coalesce(nullif(btrim(coalesce(p->>'address','')),''),
                          nullif(btrim(coalesce(p->>'address_local','')),''));
  v_wa   text := nullif(btrim(coalesce(p->>'whatsapp_no','')),'');
  v_ph   text := coalesce(nullif(btrim(coalesce(p->>'phone','')),''), v_wa);
  v_lat  double precision := nullif(btrim(coalesce(p->>'latitude','')),'')::double precision;
  v_lng  double precision := nullif(btrim(coalesce(p->>'longitude','')),'')::double precision;
  v_has  boolean := false;
  v_gst  jsonb;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  if v_id is not null then
    select latitude is not null and longitude is not null into v_has
      from pharmacy_profiles where id = v_id;
  end if;

  -- CHANGE #1888 — mandatory GPS pin. Refused here, not merely starred in the
  -- form, so no client can skip it.
  if (v_lat is null or v_lng is null) and not coalesce(v_has,false) then
    raise exception '%', public._c('customer_form.pin_required');
  end if;

  v_gst := public.gst_apply(coalesce(p->>'gstin', p->>'gst_no'),
                            coalesce((p->>'gst_none')::boolean, false));

  if v_id is null then
    insert into pharmacy_profiles (
      user_id, customer_name, owner_name, pharmacy_name, store_type, range_zone,
      address, address_local, city, state, pincode,
      latitude, longitude, location_source,
      phone, whatsapp_no, other_contact_no, email, dl_20b, dl_21b, dl_expiry,
      gst_no, gstin, gst_status, payment_term, customer_code)
    values (
      v_uid,
      nullif(btrim(coalesce(p->>'customer_name','')),''),
      nullif(btrim(coalesce(p->>'customer_name','')),''),
      nullif(btrim(coalesce(p->>'pharmacy_name','')),''),
      nullif(btrim(coalesce(p->>'store_type','')),''),
      nullif(btrim(coalesce(p->>'range_zone','')),''),
      coalesce(v_addr,''), coalesce(v_addr,''),
      coalesce(nullif(btrim(coalesce(p->>'city','')),''),''),
      nullif(btrim(coalesce(p->>'state','')),''),
      coalesce(nullif(regexp_replace(coalesce(p->>'pincode',''), '\D', '', 'g'),''),''),
      v_lat, v_lng, 'pin',
      v_ph, v_wa,
      nullif(btrim(coalesce(p->>'other_contact_no','')),''),
      nullif(btrim(coalesce(p->>'email','')),''),
      nullif(btrim(coalesce(p->>'dl_20b','')),''),
      nullif(btrim(coalesce(p->>'dl_21b','')),''),
      nullif(btrim(coalesce(p->>'dl_expiry','')),'')::date,
      v_gst->>'gstin', v_gst->>'gstin', (v_gst->>'gst_status')::public.gst_status_kind,
      coalesce(nullif(btrim(coalesce(p->>'payment_term','')),''), 'Cash on Delivery'),
      nullif(btrim(coalesce(p->>'customer_code','')),''))
    returning id into v_id;
  else
    update pharmacy_profiles set
      customer_name       = coalesce(nullif(btrim(coalesce(p->>'customer_name','')),''), customer_name),
      owner_name          = coalesce(nullif(btrim(coalesce(p->>'customer_name','')),''), owner_name),
      pharmacy_name       = coalesce(nullif(btrim(coalesce(p->>'pharmacy_name','')),''), pharmacy_name),
      store_type          = coalesce(nullif(btrim(coalesce(p->>'store_type','')),''), store_type),
      range_zone          = coalesce(nullif(btrim(coalesce(p->>'range_zone','')),''), range_zone),
      address             = coalesce(v_addr, address),
      address_local       = coalesce(v_addr, address_local),
      city                = coalesce(nullif(btrim(coalesce(p->>'city','')),''), city),
      state               = coalesce(nullif(btrim(coalesce(p->>'state','')),''), state),
      pincode             = coalesce(nullif(regexp_replace(coalesce(p->>'pincode',''), '\D','','g'),''), pincode),
      latitude            = coalesce(v_lat, latitude),
      longitude           = coalesce(v_lng, longitude),
      location_source     = case when v_lat is not null then 'pin' else location_source end,
      phone               = coalesce(v_ph, phone),
      whatsapp_no         = coalesce(v_wa, whatsapp_no),
      other_contact_no    = coalesce(nullif(btrim(coalesce(p->>'other_contact_no','')),''), other_contact_no),
      email               = coalesce(nullif(btrim(coalesce(p->>'email','')),''), email),
      dl_20b              = coalesce(nullif(btrim(coalesce(p->>'dl_20b','')),''), dl_20b),
      dl_21b              = coalesce(nullif(btrim(coalesce(p->>'dl_21b','')),''), dl_21b),
      dl_expiry           = coalesce(nullif(btrim(coalesce(p->>'dl_expiry','')),'')::date, dl_expiry),
      gst_no              = case when p ? 'gst_none' or p ? 'gstin' or p ? 'gst_no'
                                 then v_gst->>'gstin' else gst_no end,
      gstin               = case when p ? 'gst_none' or p ? 'gstin' or p ? 'gst_no'
                                 then v_gst->>'gstin' else gstin end,
      gst_status          = case when p ? 'gst_none' or p ? 'gstin' or p ? 'gst_no'
                                 then (v_gst->>'gst_status')::public.gst_status_kind else gst_status end,
      payment_term        = coalesce(nullif(btrim(coalesce(p->>'payment_term','')),''), payment_term, 'Cash on Delivery'),
      customer_code       = coalesce(nullif(btrim(coalesce(p->>'customer_code','')),''), customer_code)
    where id = v_id;
  end if;

  return public.my_session();
end $function$;

grant execute on function public.save_customer_profile(jsonb) to authenticated, service_role;

-- Lead conversion keeps the lead's own pin, and says so.
create or replace function public.lead_convert_to_customer(p_lead_id bigint, p_owner_name text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare L scraped_leads%rowtype; v jsonb; v_id uuid;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then raise exception 'not_authorized'; end if;

  select * into L from scraped_leads where id = p_lead_id;
  if not found then return jsonb_build_object('error','lead_not_found'); end if;
  if L.matched_customer_id is not null then
    return jsonb_build_object('error','already_a_customer','customer_id',L.matched_customer_id);
  end if;

  v := public.admin_import_customer(jsonb_build_object(
         'pharmacy_name',       L.name,
         'customer_name',       p_owner_name,
         'whatsapp_no',         coalesce(L.phone10, L.phone),
         'phone',               coalesce(L.phone10, L.phone),
         'email',               L.emails[1],
         'address',             coalesce(nullif(btrim(L.address),''), nullif(btrim(L.short_address),'')),
         'city',                coalesce(nullif(btrim(L.locality),''), nullif(btrim(L.city),'')),
         'state',               coalesce(nullif(btrim(L.state),''),'Chhattisgarh'),
         'pincode',             nullif(regexp_replace(coalesce(L.pincode,''), '\D','','g'),''),
         'latitude',            L.lat::text,
         'longitude',           L.lng::text,
         'location_source',     case when L.lat is not null then 'lead' end));

  v_id := (v->>'customer_id')::uuid;

  update scraped_leads
     set status='converted', matched_kind='customer', matched_customer_id=v_id,
         match_reason='converted from lead', lead_score=0
   where id = p_lead_id;

  return jsonb_build_object('ok',true,'customer_id',v_id,
                            'customer_code', v->>'customer_code',
                            'registration_stage', v->>'registration_stage',
                            'location_source', v->>'location_source',
                            'pharmacy_name', L.name,
                            'note', v->>'message');
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. Backfill — run 2 and 3 over every shop already in the table
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.geo_backfill_customers(p_limit int default 500)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r        record;
  v_geo    jsonb;
  n_geo    int := 0;
  n_queued int := 0;
  n_derived int := 0;
  n_term   int := 0;
  n_gst    int := 0;
begin
  -- (a) payment_term: a shop with no term is Cash on Delivery.
  update pharmacy_profiles
     set payment_term = 'Cash on Delivery'
   where coalesce(is_deleted,false) = false
     and nullif(btrim(coalesce(payment_term,'')),'') is null;
  get diagnostics n_term = row_count;

  -- (b) gst_status: a GSTIN already on file is pending verification; a shop
  --     with no GSTIN keeps a null answer until somebody answers it — "none"
  --     is a statement, and this backfill may not make it on their behalf.
  update pharmacy_profiles
     set gst_status = 'pending'
   where coalesce(is_deleted,false) = false
     and gst_status is null
     and nullif(btrim(coalesce(gstin, gst_no, '')),'') is not null;
  get diagnostics n_gst = row_count;

  -- (c) geocode every shop with no pin.
  for r in select id, address, city, state, pincode
             from pharmacy_profiles
            where coalesce(is_deleted,false) = false
              and (latitude is null or longitude is null)
            order by created_at nulls last
            limit p_limit loop
    v_geo := public.geo_geocode(jsonb_build_object(
               'address', r.address, 'city', r.city, 'state', r.state,
               'pincode', r.pincode, 'ref_id', r.id::text));
    if (v_geo->>'ok')::boolean then
      update pharmacy_profiles
         set latitude = (v_geo->>'lat')::double precision,
             longitude = (v_geo->>'lng')::double precision,
             location_source = coalesce(location_source, 'geocoded'),
             located_at = coalesce(located_at, now())
       where id = r.id;
      n_geo := n_geo + 1;
    else
      n_queued := n_queued + 1;
    end if;
  end loop;

  -- (d) force the derivation over every row: the trigger only fires on a
  --     write, and these rows were written before it existed.
  update pharmacy_profiles
     set store_location_link = public.geo_maps_link(latitude, longitude),
         district = coalesce(
           (select gp.district from geo_pincode gp
             where gp.pincode = regexp_replace(coalesce(pharmacy_profiles.pincode,''), '\D','','g')),
           public.norm_district(district))
   where coalesce(is_deleted,false) = false
     and (store_location_link is distinct from public.geo_maps_link(latitude, longitude)
          or district is distinct from coalesce(
               (select gp.district from geo_pincode gp
                 where gp.pincode = regexp_replace(coalesce(pharmacy_profiles.pincode,''), '\D','','g')),
               public.norm_district(district)));
  get diagnostics n_derived = row_count;

  return jsonb_build_object('ok', true,
    'geocoded', n_geo, 'queued', n_queued, 'derived', n_derived,
    'payment_term_set', n_term, 'gst_status_set', n_gst);
end $function$;

grant execute on function public.geo_backfill_customers(int) to service_role;

do $$
declare v jsonb;
begin
  v := public.geo_backfill_customers(500);
  raise notice 'c1888 backfill: %', v;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 10. What the admin sees: how complete the customer book actually is
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.customer_autofill_status(p jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_zone smallint := public.admin_active_zone();
  v_day  date := public.admin_active_date();
  v_tot  int; v_pin int; v_link int; v_dist int; v_gst int; v_term int;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;

  select count(*),
         count(*) filter (where latitude is not null and longitude is not null),
         count(*) filter (where store_location_link is not null),
         count(*) filter (where district is not null),
         count(*) filter (where gst_status is not null),
         count(*) filter (where payment_term is not null)
    into v_tot, v_pin, v_link, v_dist, v_gst, v_term
    from pharmacy_profiles
   where coalesce(is_deleted,false) = false
     and (v_zone is null or zone_id = v_zone)
     and created_at::date <= v_day;

  return jsonb_build_object(
    'ok', true,
    'title', public._c('customer_form.autofill_title'),
    'as_of', to_char(v_day, 'DD Mon YYYY'),
    'total', v_tot,
    'rows', jsonb_build_array(
      jsonb_build_object('label', public._c('customer_form.autofill_pin'),
                         'value', v_pin || ' / ' || v_tot,
                         'tone', case when v_pin = v_tot then 'success' else 'warning' end),
      jsonb_build_object('label', public._c('customer_form.autofill_link'),
                         'value', v_link || ' / ' || v_tot,
                         'tone', case when v_link = v_tot then 'success' else 'warning' end),
      jsonb_build_object('label', public._c('customer_form.autofill_district'),
                         'value', v_dist || ' / ' || v_tot,
                         'tone', case when v_dist = v_tot then 'success' else 'warning' end),
      jsonb_build_object('label', public._c('customer_form.autofill_gst'),
                         'value', v_gst || ' / ' || v_tot,
                         'tone', case when v_gst = v_tot then 'success' else 'warning' end),
      jsonb_build_object('label', public._c('customer_form.autofill_term'),
                         'value', v_term || ' / ' || v_tot,
                         'tone', case when v_term = v_tot then 'success' else 'warning' end)));
end $function$;

grant execute on function public.customer_autofill_status(jsonb) to authenticated, service_role;

insert into public.ui_copy (key, value) values
  ('customer_form.autofill_title',    '"Customer book completeness"'::jsonb),
  ('customer_form.autofill_pin',      '"Shops with a GPS pin"'::jsonb),
  ('customer_form.autofill_link',     '"Shops with a maps link"'::jsonb),
  ('customer_form.autofill_district', '"Shops with a district"'::jsonb),
  ('customer_form.autofill_gst',      '"Shops with a GST answer"'::jsonb),
  ('customer_form.autofill_term',     '"Shops with a payment term"'::jsonb)
on conflict (key) do update set value = excluded.value;
