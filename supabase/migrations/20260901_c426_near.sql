-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #426 — Consumer availability search: the public PWA at /near
--
-- The honesty rule this file exists to enforce: a consumer is NEVER told a
-- pharmacy HAS a medicine. Stock here is INFERRED (#424's engine), so every
-- card carries a confidence-tiered, backend-owned sentence — Likely / Possibly
-- / Ask — and a call button, because the phone call is the confirmation.
--
-- The privacy rule this file exists to enforce: an opted-in pharmacy exposes
-- AVAILABILITY ONLY. No quantity, no price, no cost, no supplier, no bill, no
-- trade data of any kind crosses into a public payload. near_search() selects
-- the columns it returns by hand for exactly that reason, and the proof asserts
-- the payload text contains no rupee figure and no quantity.
--
-- Idempotent throughout: a resumed worker re-applies this file as a no-op.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. tables ──────────────────────────────────────────────────────────────

-- Strictly OPT-IN. A pharmacy that never touches the toggle is never listed;
-- `opted_in` defaults false and there is no path that flips it on their behalf.
create table if not exists public.near_listing_config (
  pharmacy_id   uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  opted_in      boolean     not null default false,
  display_name  text,
  show_phone    boolean     not null default true,
  opted_in_at   timestamptz,
  updated_by    uuid,
  updated_at    timestamptz not null default now()
);

-- One-tap "we're out of it" from the pharmacy's own view. A row here hides the
-- SKU from /near until `until`, whatever the inference engine believes.
create table if not exists public.near_unavailable (
  pharmacy_id  uuid   not null references public.pharmacy_profiles(id) on delete cascade,
  medicine_id  bigint not null,
  until        timestamptz not null,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  primary key (pharmacy_id, medicine_id)
);
create index if not exists near_unavailable_until_idx on public.near_unavailable (until);

-- Singleton knobs. Every threshold, cap and wording switch is DATA — retuning
-- the honesty tiers or the rate limit is an UPDATE, never a deploy.
create table if not exists public.near_config (
  id              boolean primary key default true check (id),
  enabled         boolean not null default true,
  max_km          numeric not null default 8,
  max_results     integer not null default 20,
  max_medicines   integer not null default 25,
  min_confidence  numeric not null default 0.20,
  tier_high       numeric not null default 0.65,
  tier_mid        numeric not null default 0.35,
  rate_per_min    integer not null default 20,
  rate_per_hour   integer not null default 200,
  block_minutes   integer not null default 15,
  min_query_chars integer not null default 3,
  log_retain_days integer not null default 7,
  updated_at      timestamptz not null default now()
);
insert into public.near_config (id) values (true) on conflict (id) do nothing;

-- Rate-limit / bot ledger. One row per client bucket (a hash of the forwarded
-- IP + user agent — never the raw header, which is personal data we have no
-- reason to keep). Two windows so a slow crawler is caught as well as a burst.
create table if not exists public.near_rate (
  bucket        text primary key,
  minute_start  timestamptz not null default date_trunc('minute', now()),
  minute_hits   integer     not null default 0,
  hour_start    timestamptz not null default date_trunc('hour', now()),
  hour_hits     integer     not null default 0,
  blocked_until timestamptz,
  first_seen    timestamptz not null default now(),
  last_seen     timestamptz not null default now()
);
create index if not exists near_rate_last_seen_idx on public.near_rate (last_seen);

-- Abuse evidence + "what are consumers actually asking for" — the query text
-- and the bucket, never a person. Swept to `log_retain_days`.
create table if not exists public.near_search_log (
  id          bigserial primary key,
  bucket      text,
  q_norm      text,
  had_origin  boolean,
  result_count integer,
  at          timestamptz not null default now()
);
create index if not exists near_search_log_at_idx on public.near_search_log (at);

-- The counter poster: a per-pharmacy token, a QR to /near/p/<token>, and the
-- generated PDF's home in the `near-posters` bucket.
create table if not exists public.near_poster (
  pharmacy_id  uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  token        text unique not null,
  status       text not null default 'none',
  bucket       text,
  path         text,
  bytes        integer,
  error        text,
  requested_at timestamptz,
  generated_at timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.near_listing_config enable row level security;
alter table public.near_unavailable    enable row level security;
alter table public.near_config         enable row level security;
alter table public.near_rate           enable row level security;
alter table public.near_search_log     enable row level security;
alter table public.near_poster         enable row level security;

-- Zero policies, deliberately: every read and write goes through a
-- SECURITY DEFINER RPC that decides what the caller may see. A table that is
-- reachable directly from PostgREST is a table whose columns leak.

-- ── 2. backend copy ────────────────────────────────────────────────────────
-- Every word the consumer PWA prints lives here. Dart owns none of it, so the
-- honesty wording can be retuned by a product decision, not a release.

insert into public.ui_copy (key, value) values
  ('near.title',            '"Find a medicine near you"'::jsonb),
  ('near.subtitle',         '"Availability at nearby pharmacies, based on their own stock records."'::jsonb),
  ('near.search_hint',      '"Type a medicine name"'::jsonb),
  ('near.search_button',    '"Search"'::jsonb),
  ('near.locate_button',    '"Use my location"'::jsonb),
  ('near.locating',         '"Finding you…"'::jsonb),
  ('near.pincode_hint',     '"Or enter your pincode"'::jsonb),
  ('near.pincode_button',   '"Use pincode"'::jsonb),
  ('near.need_origin',      '"Share your location or enter a pincode to see nearby pharmacies."'::jsonb),
  ('near.short_query',      '"Type at least 3 letters of the medicine name."'::jsonb),
  ('near.no_results',       '"No nearby pharmacy is likely to have this right now."'::jsonb),
  ('near.no_results_hint',  '"Try the salt name, or a wider pincode."'::jsonb),
  ('near.empty',            '"Search a medicine to see which pharmacies nearby are likely to have it."'::jsonb),
  ('near.tier_high',        '"Likely available — call to confirm"'::jsonb),
  ('near.tier_mid',         '"Possibly available — call to confirm"'::jsonb),
  ('near.tier_low',         '"Ask the pharmacy"'::jsonb),
  ('near.call_button',      '"Call"'::jsonb),
  ('near.directions_button','"Directions"'::jsonb),
  ('near.disclaimer',       '"mediBO does not hold this stock. Availability is estimated from each pharmacy''s own purchase records and can be out of date — always call before you travel."'::jsonb),
  ('near.rx_note',          '"Prescription medicines are dispensed by the pharmacy at their discretion."'::jsonb),
  ('near.rate_limited',     '"Too many searches from this device. Please try again in a few minutes."'::jsonb),
  ('near.disabled',         '"Nearby search is not available right now."'::jsonb),
  ('near.results_label',    '"{n} pharmacy nearby"'::jsonb),
  ('near.results_label_p',  '"{n} pharmacies nearby"'::jsonb),
  ('near.distance_label',   '"{km} km away"'::jsonb),
  ('near.pharmacy_not_found','"This pharmacy is not listed."'::jsonb),
  ('near.listing_title',    '"Listed on mediBO Near"'::jsonb),
  -- pharmacy-side surface
  ('near.own_nav_label',    '"Nearby listing"'::jsonb),
  ('near.own_subtitle',     '"Let consumers nearby see what you are likely to have"'::jsonb),
  ('near.own_title',        '"Nearby listing"'::jsonb),
  ('near.own_opt_in',       '"List this pharmacy on mediBO Near"'::jsonb),
  ('near.own_opt_in_note',  '"Consumers searching nearby will see your name, distance and phone — and only whether an item is likely available. Your quantities, purchase prices, suppliers and bills are never shown."'::jsonb),
  ('near.own_phone_toggle', '"Show my phone number"'::jsonb),
  ('near.own_off_state',    '"You are not listed. Turn this on to appear in consumer searches nearby."'::jsonb),
  ('near.own_on_state',     '"You are listed. Consumers nearby can find you."'::jsonb),
  ('near.own_saved',        '"Saved"'::jsonb),
  ('near.own_items_title',  '"Likely available right now"'::jsonb),
  ('near.own_items_empty',  '"Nothing is listed yet — it fills in as your purchase bills are read."'::jsonb),
  ('near.own_mark_button',  '"Mark unavailable"'::jsonb),
  ('near.own_marked',       '"Hidden from nearby search"'::jsonb),
  ('near.own_marked_note',  '"Hidden until {when}"'::jsonb),
  ('near.own_undo_button',  '"Show again"'::jsonb),
  ('near.own_poster_title', '"Counter poster"'::jsonb),
  ('near.own_poster_note',  '"A printable poster with your name and a QR code that opens your listing."'::jsonb),
  ('near.own_poster_button','"Get poster"'::jsonb),
  ('near.own_poster_wait',  '"Making your poster…"'::jsonb),
  ('near.own_poster_ready', '"Poster ready"'::jsonb),
  ('near.own_poster_open',  '"Open poster"'::jsonb),
  ('near.own_poster_failed','"Could not make the poster. Try again."'::jsonb),
  ('near.own_denied',       '"Only the pharmacy owner can change the nearby listing."'::jsonb)
on conflict (key) do nothing;

-- ── 3. helpers ─────────────────────────────────────────────────────────────

create or replace function public._c426_cfg()
returns public.near_config language sql stable security definer
set search_path to 'public' as $$
  select * from public.near_config where id;
$$;

-- Great-circle km. Kept in SQL rather than PostGIS because the fence is 8 km
-- and the error at that range is metres — and because one function is cheaper
-- to reason about than an extension dependency on a 1 GB instance.
create or replace function public._c426_km(
  p_lat1 double precision, p_lng1 double precision,
  p_lat2 double precision, p_lng2 double precision)
returns numeric language sql immutable as $$
  select round((6371 * 2 * asin(sqrt(
           power(sin(radians(p_lat2 - p_lat1) / 2), 2) +
           cos(radians(p_lat1)) * cos(radians(p_lat2)) *
           power(sin(radians(p_lng2 - p_lng1) / 2), 2)
         )))::numeric, 2);
$$;

-- The client bucket. PostgREST hands us the request headers; we keep a HASH of
-- the forwarded IP + user agent and never the values themselves — enough to
-- rate-limit a device, useless as a record of a person.
create or replace function public._c426_bucket()
returns text language plpgsql stable security definer
set search_path to 'public' as $$
declare h jsonb; v text;
begin
  begin
    h := current_setting('request.headers', true)::jsonb;
  exception when others then h := null;
  end;
  v := coalesce(h->>'cf-connecting-ip',
                split_part(coalesce(h->>'x-forwarded-for',''), ',', 1),
                '') || '|' || coalesce(h->>'user-agent','');
  if btrim(v) = '|' then return 'anon'; end if;
  return md5(v);
end $$;

-- Two windows, one row. Returns the refusal payload itself when the caller has
-- had enough, so every caller refuses in the same words.
create or replace function public._c426_rate_take(p_bucket text)
returns jsonb language plpgsql security definer
set search_path to 'public' as $$
declare c public.near_config := public._c426_cfg(); r public.near_rate;
begin
  insert into public.near_rate (bucket) values (p_bucket)
  on conflict (bucket) do nothing;

  update public.near_rate n
     set minute_start = case when n.minute_start < date_trunc('minute', now())
                             then date_trunc('minute', now()) else n.minute_start end,
         minute_hits  = case when n.minute_start < date_trunc('minute', now())
                             then 1 else n.minute_hits + 1 end,
         hour_start   = case when n.hour_start < date_trunc('hour', now())
                             then date_trunc('hour', now()) else n.hour_start end,
         hour_hits    = case when n.hour_start < date_trunc('hour', now())
                             then 1 else n.hour_hits + 1 end,
         last_seen    = now()
   where n.bucket = p_bucket
  returning * into r;

  if r.blocked_until is not null and r.blocked_until > now() then
    return jsonb_build_object('ok', false,
      'retry_after_s', ceil(extract(epoch from (r.blocked_until - now())))::int);
  end if;

  if r.minute_hits > c.rate_per_min or r.hour_hits > c.rate_per_hour then
    update public.near_rate
       set blocked_until = now() + make_interval(mins => c.block_minutes)
     where bucket = p_bucket;
    return jsonb_build_object('ok', false, 'retry_after_s', c.block_minutes * 60);
  end if;

  return jsonb_build_object('ok', true);
end $$;

-- The honesty tier. Three sentences, chosen by confidence, owned by the
-- backend — the one place the wording can be softened or hardened.
create or replace function public._c426_tier(p_conf numeric)
returns jsonb language sql stable security definer
set search_path to 'public' as $$
  select case
    when coalesce(p_conf,0) >= (select tier_high from public.near_config where id)
      then jsonb_build_object('key','high','tone','success','label', public.ui_text('near.tier_high'))
    when coalesce(p_conf,0) >= (select tier_mid from public.near_config where id)
      then jsonb_build_object('key','mid','tone','warning','label', public.ui_text('near.tier_mid'))
    else jsonb_build_object('key','low','tone','info','label', public.ui_text('near.tier_low'))
  end;
$$;

create or replace function public._c426_dir_url(p_lat double precision, p_lng double precision)
returns text language sql stable security definer
set search_path to 'public' as $$
  select case when p_lat is null or p_lng is null then null else
    replace(replace(
      coalesce(nullif(public.map_config_get()->>'nav_deeplink_template',''),
               'https://www.google.com/maps/dir/?api=1&destination={lat},{lng}'),
      '{lat}', p_lat::text), '{lng}', p_lng::text)
  end;
$$;

create or replace function public._c426_token()
returns text language sql volatile as $$
  select lower(replace(encode(gen_random_bytes(9), 'base64'), '/', '_'));
$$;

-- Every opted-in pharmacy owns exactly one poster token, minted the moment it
-- opts in, so the QR on a printed poster survives a toggle off and back on.
create or replace function public._c426_ensure_token(p_shop uuid)
returns text language plpgsql security definer
set search_path to 'public' as $$
declare v text;
begin
  select token into v from public.near_poster where pharmacy_id = p_shop;
  if v is not null then return v; end if;
  loop
    v := public._c426_token();
    begin
      insert into public.near_poster (pharmacy_id, token) values (p_shop, v);
      return v;
    exception when unique_violation then
      select token into v from public.near_poster where pharmacy_id = p_shop;
      if v is not null then return v; end if;
    end;
  end loop;
end $$;

-- Internal helpers are not a public API surface.
revoke execute on function public._c426_cfg()                              from public, anon, authenticated;
revoke execute on function public._c426_rate_take(text)                    from public, anon, authenticated;
revoke execute on function public._c426_ensure_token(uuid)                 from public, anon, authenticated;

-- ── 4. the public surface (anon) ───────────────────────────────────────────

-- Everything the PWA prints before a search happens. The page has no Dart
-- strings at all, so a wording change is an UPDATE to ui_copy.
create or replace function public.near_boot()
returns jsonb language sql stable security definer
set search_path to 'public' as $$
  select jsonb_build_object(
    'ok', true,
    'enabled', (select enabled from public.near_config where id),
    'min_query_chars', (select min_query_chars from public.near_config where id),
    'copy', jsonb_build_object(
      'title',             public.ui_text('near.title'),
      'subtitle',          public.ui_text('near.subtitle'),
      'search_hint',       public.ui_text('near.search_hint'),
      'search_button',     public.ui_text('near.search_button'),
      'locate_button',     public.ui_text('near.locate_button'),
      'locating',          public.ui_text('near.locating'),
      'pincode_hint',      public.ui_text('near.pincode_hint'),
      'pincode_button',    public.ui_text('near.pincode_button'),
      'need_origin',       public.ui_text('near.need_origin'),
      'short_query',       public.ui_text('near.short_query'),
      'empty',             public.ui_text('near.empty'),
      'no_results',        public.ui_text('near.no_results'),
      'no_results_hint',   public.ui_text('near.no_results_hint'),
      'call_button',       public.ui_text('near.call_button'),
      'directions_button', public.ui_text('near.directions_button'),
      'disclaimer',        public.ui_text('near.disclaimer'),
      'rx_note',           public.ui_text('near.rx_note'),
      'disabled',          public.ui_text('near.disabled')));
$$;

-- THE consumer read. Anon, rate-limited, and hand-picked column by column:
-- availability only. There is no quantity, no price, no cost, no supplier and
-- no bill anywhere in this payload, and `near_no_trade_data_proof()` asserts it.
create or replace function public.near_search(
  p_q       text,
  p_lat     double precision default null,
  p_lng     double precision default null,
  p_pincode text default null,
  p_limit   integer default null)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $$
declare
  c public.near_config := public._c426_cfg();
  v_bucket text := public._c426_bucket();
  v_rate jsonb; v_q text; v_lat double precision := p_lat; v_lng double precision := p_lng;
  v_lim int := least(coalesce(p_limit, c.max_results), c.max_results);
  v_rows jsonb; v_n int;
begin
  if not c.enabled then
    return jsonb_build_object('ok', false, 'error', 'disabled', 'tone', 'info',
                              'message', public.ui_text('near.disabled'));
  end if;

  v_rate := public._c426_rate_take(v_bucket);
  if not (v_rate->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'tone', 'warning',
                              'retry_after_s', (v_rate->>'retry_after_s')::int,
                              'message', public.ui_text('near.rate_limited'));
  end if;

  v_q := public._norm_name(coalesce(p_q, ''));
  if length(replace(v_q, ' ', '')) < c.min_query_chars then
    return jsonb_build_object('ok', false, 'error', 'short_query', 'tone', 'info',
                              'message', public.ui_text('near.short_query'));
  end if;

  -- Pincode fallback: the centroid of the pharmacies we already know sit in it.
  -- A pincode nobody is mapped to is an honest "we cannot place you", not a
  -- silent search of the whole state.
  if v_lat is null or v_lng is null then
    select avg(p.latitude), avg(p.longitude) into v_lat, v_lng
      from public.pharmacy_profiles p
     where p.pincode = nullif(btrim(coalesce(p_pincode,'')), '')
       and p.latitude is not null and p.longitude is not null
       and coalesce(p.is_deleted, false) = false;
  end if;
  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'error', 'need_origin', 'tone', 'info',
                              'message', public.ui_text('near.need_origin'));
  end if;

  with med as (
    select m.id, m.product_name
      from public."MEDICINE" m
     where public._norm_name(m.product_name) % v_q
     order by similarity(public._norm_name(m.product_name), v_q) desc
     limit c.max_medicines
  ),
  shops as (
    select p.id, p.latitude, p.longitude, p.city, p.district, p.phone,
           coalesce(nullif(btrim(n.display_name), ''), p.pharmacy_name) as name,
           n.show_phone, t.token,
           public._c426_km(v_lat, v_lng, p.latitude, p.longitude) as km
      from public.near_listing_config n
      join public.pharmacy_profiles p on p.id = n.pharmacy_id
      left join public.near_poster   t on t.pharmacy_id = n.pharmacy_id
     where n.opted_in
       and coalesce(p.is_deleted, false) = false
       and p.latitude is not null and p.longitude is not null
       and public._c426_km(v_lat, v_lng, p.latitude, p.longitude) <= c.max_km
  ),
  live as (
    select i.pharmacy_id, i.medicine_id, max(i.confidence) as confidence
      from public.pharmacy_lot_inference i
      join shops s   on s.id  = i.pharmacy_id
      join med   mm  on mm.id = i.medicine_id
     where i.inferred_left > 0
       and i.confidence >= c.min_confidence
       and (i.expiry_on is null or i.expiry_on > current_date)
       -- A pharmacy that answered "0 left" is off this list at once, whatever
       -- the model still believes about that lot.
       and coalesce((select cc.actual_left
                       from public.pharmacy_lot_correction cc
                      where cc.lot_id = i.lot_id
                      order by cc.created_at desc
                      limit 1), 1) > 0
       -- …and so is one that tapped "mark unavailable".
       and not exists (select 1 from public.near_unavailable u
                        where u.pharmacy_id = i.pharmacy_id
                          and u.medicine_id = i.medicine_id
                          and u.until > now())
     group by 1, 2
  ),
  best as (
    select s.id, s.name, s.km, s.city, s.district, s.phone, s.show_phone,
           s.token, s.latitude, s.longitude,
           max(l.confidence) as confidence,
           (array_agg(mm.product_name order by l.confidence desc))[1] as matched
      from live l
      join shops s  on s.id  = l.pharmacy_id
      join med  mm  on mm.id = l.medicine_id
     group by s.id, s.name, s.km, s.city, s.district, s.phone, s.show_phone,
              s.token, s.latitude, s.longitude
  )
  select jsonb_agg(row_to_json(x)::jsonb order by x.rank), count(*)
    into v_rows, v_n
  from (
    select b.token as ref,
           b.name,
           b.matched as matched_label,
           coalesce(nullif(btrim(b.city), ''), nullif(btrim(b.district), '')) as area_label,
           public.ui_text_f('near.distance_label',
             jsonb_build_object('km', to_char(b.km, 'FM999990.0'))) as distance_label,
           public._c426_tier(b.confidence) as tier,
           jsonb_build_object(
             'has',   b.show_phone and coalesce(nullif(btrim(b.phone), ''), '') <> '',
             'label', public.ui_text('near.call_button'),
             'tel',   case when b.show_phone then nullif(btrim(b.phone), '') end) as call,
           jsonb_build_object(
             'has',   public._c426_dir_url(b.latitude, b.longitude) is not null,
             'label', public.ui_text('near.directions_button'),
             'url',   public._c426_dir_url(b.latitude, b.longitude)) as directions,
           -- confidence x distance decay. Ranking only; the NUMBER never
           -- reaches the consumer, only the tier sentence it chose.
           row_number() over (
             order by (b.confidence / (1 + b.km / 2)) desc, b.km asc) as rank
      from best b
     order by rank
     limit v_lim
  ) x;

  v_n := coalesce(v_n, 0);

  insert into public.near_search_log (bucket, q_norm, had_origin, result_count)
  values (v_bucket, v_q, true, v_n);

  return jsonb_build_object(
    'ok', true,
    'query', v_q,
    'count', v_n,
    'count_label', case when v_n = 1 then public.ui_text_f('near.results_label',
                            jsonb_build_object('n', v_n))
                        else public.ui_text_f('near.results_label_p',
                            jsonb_build_object('n', v_n)) end,
    'empty_label', public.ui_text('near.no_results'),
    'empty_hint',  public.ui_text('near.no_results_hint'),
    'disclaimer',  public.ui_text('near.disclaimer'),
    'rx_note',     public.ui_text('near.rx_note'),
    'rows', coalesce(v_rows, '[]'::jsonb));
end $$;

-- The QR target: one pharmacy's own public page. Same honesty, same silence
-- about trade data — it names the shop and says how to reach it, nothing more.
create or replace function public.near_pharmacy(p_token text)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $$
declare v_rate jsonb; r record;
begin
  v_rate := public._c426_rate_take(public._c426_bucket());
  if not (v_rate->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'tone', 'warning',
                              'message', public.ui_text('near.rate_limited'));
  end if;

  select coalesce(nullif(btrim(n.display_name), ''), p.pharmacy_name) as name,
         p.city, p.district, p.phone, p.latitude, p.longitude, n.show_phone
    into r
    from public.near_poster t
    join public.near_listing_config n on n.pharmacy_id = t.pharmacy_id
    join public.pharmacy_profiles   p on p.id = t.pharmacy_id
   where t.token = nullif(btrim(coalesce(p_token, '')), '')
     and n.opted_in
     and coalesce(p.is_deleted, false) = false;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'info',
                              'message', public.ui_text('near.pharmacy_not_found'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'name', r.name,
    'badge', public.ui_text('near.listing_title'),
    'area_label', coalesce(nullif(btrim(r.city), ''), nullif(btrim(r.district), '')),
    'search_hint', public.ui_text('near.search_hint'),
    'disclaimer', public.ui_text('near.disclaimer'),
    'call', jsonb_build_object(
      'has',   r.show_phone and coalesce(nullif(btrim(r.phone), ''), '') <> '',
      'label', public.ui_text('near.call_button'),
      'tel',   case when r.show_phone then nullif(btrim(r.phone), '') end),
    'directions', jsonb_build_object(
      'has',   public._c426_dir_url(r.latitude, r.longitude) is not null,
      'label', public.ui_text('near.directions_button'),
      'url',   public._c426_dir_url(r.latitude, r.longitude)));
end $$;

-- ── 5. the pharmacy's own side (owner, authenticated) ──────────────────────

create or replace function public._c426_denied()
returns jsonb language sql stable security definer
set search_path to 'public' as $$
  select jsonb_build_object('ok', false, 'error', 'denied', 'tone', 'danger',
                            'message', public.ui_text('near.own_denied'));
$$;

-- What the owner sees: the toggle, its consequence in plain words, the SKUs
-- that would be listed right now, and the poster. `is_listed`/`show_phone` are
-- flags the screen renders; it computes nothing.
create or replace function public.near_listing_get()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $$
declare v_shop uuid := public._c413_shop(); n public.near_listing_config;
        v_items jsonb; v_poster jsonb; t public.near_poster;
begin
  if v_shop is null then return public._c426_denied(); end if;

  select * into n from public.near_listing_config where pharmacy_id = v_shop;
  select * into t from public.near_poster          where pharmacy_id = v_shop;

  select jsonb_agg(row_to_json(x)::jsonb order by x.name)
    into v_items
  from (
    select i.medicine_id,
           m.product_name as name,
           public._c426_tier(max(i.confidence)) as tier,
           (u.until is not null and u.until > now()) as hidden,
           case when u.until is not null and u.until > now()
                then public.ui_text_f('near.own_marked_note',
                       jsonb_build_object('when',
                         to_char(u.until at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM')))
           end as hidden_label,
           public.ui_text('near.own_mark_button') as mark_label,
           public.ui_text('near.own_undo_button') as undo_label
      from public.pharmacy_lot_inference i
      join public."MEDICINE" m on m.id = i.medicine_id
      left join public.near_unavailable u
             on u.pharmacy_id = i.pharmacy_id and u.medicine_id = i.medicine_id
     where i.pharmacy_id = v_shop
       and i.inferred_left > 0
       and i.confidence >= (select min_confidence from public.near_config where id)
       and (i.expiry_on is null or i.expiry_on > current_date)
       and coalesce((select cc.actual_left from public.pharmacy_lot_correction cc
                      where cc.lot_id = i.lot_id order by cc.created_at desc limit 1), 1) > 0
     group by i.medicine_id, m.product_name, u.until
     limit 200
  ) x;

  v_poster := jsonb_build_object(
    'title',  public.ui_text('near.own_poster_title'),
    'note',   public.ui_text('near.own_poster_note'),
    'status', coalesce(t.status, 'none'),
    'button', case coalesce(t.status, 'none')
                when 'building' then public.ui_text('near.own_poster_wait')
                when 'ready'    then public.ui_text('near.own_poster_open')
                when 'failed'   then public.ui_text('near.own_poster_failed')
                else public.ui_text('near.own_poster_button') end,
    'can_request', coalesce(t.status, 'none') <> 'building',
    'ready',  coalesce(t.status, '') = 'ready',
    'bucket', t.bucket, 'path', t.path,
    'poll_ms', 3000);

  return jsonb_build_object(
    'ok', true,
    'title',        public.ui_text('near.own_title'),
    'opt_in_label', public.ui_text('near.own_opt_in'),
    'opt_in_note',  public.ui_text('near.own_opt_in_note'),
    'phone_label',  public.ui_text('near.own_phone_toggle'),
    'is_listed',    coalesce(n.opted_in, false),
    'show_phone',   coalesce(n.show_phone, true),
    'state_label',  case when coalesce(n.opted_in, false)
                         then public.ui_text('near.own_on_state')
                         else public.ui_text('near.own_off_state') end,
    'state_tone',   case when coalesce(n.opted_in, false) then 'success' else 'info' end,
    'public_url',   case when coalesce(n.opted_in, false) and t.token is not null
                         then 'https://medibo.in/near/p/' || t.token end,
    'items_title',  public.ui_text('near.own_items_title'),
    'items_empty',  public.ui_text('near.own_items_empty'),
    'items',        coalesce(v_items, '[]'::jsonb),
    'poster',       v_poster);
end $$;

create or replace function public.near_listing_set(
  p_opt_in boolean default null,
  p_show_phone boolean default null,
  p_display_name text default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null or not public._c413_is_owner(v_shop) then
    return public._c426_denied();
  end if;

  insert into public.near_listing_config as n
    (pharmacy_id, opted_in, show_phone, display_name, opted_in_at, updated_by, updated_at)
  values (v_shop, coalesce(p_opt_in, false), coalesce(p_show_phone, true),
          nullif(btrim(coalesce(p_display_name, '')), ''),
          case when coalesce(p_opt_in, false) then now() end, auth.uid(), now())
  on conflict (pharmacy_id) do update
    set opted_in     = coalesce(p_opt_in, n.opted_in),
        show_phone   = coalesce(p_show_phone, n.show_phone),
        display_name = coalesce(nullif(btrim(coalesce(p_display_name, '')), ''), n.display_name),
        opted_in_at  = case when coalesce(p_opt_in, n.opted_in) and n.opted_in_at is null
                            then now() else n.opted_in_at end,
        updated_by   = auth.uid(),
        updated_at   = now();

  -- The token is minted on the first opt-in and then never changes, so a
  -- poster already stuck on a counter keeps working through a toggle cycle.
  if coalesce(p_opt_in, false) then perform public._c426_ensure_token(v_shop); end if;

  return public.near_listing_get() || jsonb_build_object(
    'saved', true, 'toast', public.ui_text('near.own_saved'));
end $$;

-- One tap. This hides the SKU from consumers; it deliberately does NOT write a
-- "0 left" correction into the inference engine — "don't show this to walk-ins"
-- and "the shelf is empty" are different claims, and only the pharmacy knows
-- which one they meant.
create or replace function public.near_mark_unavailable(
  p_medicine_id bigint, p_hours integer default 24)
returns jsonb language plpgsql security definer
set search_path to 'public' as $$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null or not public._c413_is_owner(v_shop) then return public._c426_denied(); end if;
  if p_medicine_id is null then return public._c426_denied(); end if;

  insert into public.near_unavailable (pharmacy_id, medicine_id, until, created_by)
  values (v_shop, p_medicine_id,
          now() + make_interval(hours => greatest(coalesce(p_hours, 24), 1)), auth.uid())
  on conflict (pharmacy_id, medicine_id) do update
    set until = excluded.until, created_by = excluded.created_by, created_at = now();

  return public.near_listing_get() || jsonb_build_object(
    'saved', true, 'toast', public.ui_text('near.own_marked'));
end $$;

create or replace function public.near_mark_available(p_medicine_id bigint)
returns jsonb language plpgsql security definer
set search_path to 'public' as $$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null or not public._c413_is_owner(v_shop) then return public._c426_denied(); end if;
  delete from public.near_unavailable where pharmacy_id = v_shop and medicine_id = p_medicine_id;
  return public.near_listing_get() || jsonb_build_object('saved', true);
end $$;

-- ── 6. the counter poster ──────────────────────────────────────────────────

create or replace function public.near_poster_request()
returns jsonb language plpgsql security definer
set search_path to 'public' as $$
declare v_shop uuid := public._c413_shop(); v_token text;
begin
  if v_shop is null or not public._c413_is_owner(v_shop) then return public._c426_denied(); end if;
  v_token := public._c426_ensure_token(v_shop);
  update public.near_poster
     set status = 'building', error = null, requested_at = now()
   where pharmacy_id = v_shop;
  return public.near_listing_get() || jsonb_build_object('token', v_token);
end $$;

-- The edge function reports back through here; it never writes the table.
create or replace function public.near_poster_report(
  p_token text, p_bucket text default null, p_path text default null,
  p_bytes integer default null, p_error text default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $$
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'near_poster_report: service role only';
  end if;
  update public.near_poster
     set status = case when p_error is not null then 'failed' else 'ready' end,
         bucket = coalesce(p_bucket, bucket), path = coalesce(p_path, path),
         bytes  = coalesce(p_bytes, bytes),  error = p_error,
         generated_at = case when p_error is null then now() else generated_at end
   where token = p_token;
  return jsonb_build_object('ok', found);
end $$;

-- Resolves a poster job for the edge function: the token, the name to print,
-- and the URL the QR must encode. No trade data, same as every other surface.
create or replace function public.near_poster_job(p_token text)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $$
declare r record;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'near_poster_job: service role only';
  end if;
  select t.token,
         coalesce(nullif(btrim(n.display_name), ''), p.pharmacy_name) as name,
         coalesce(nullif(btrim(p.city), ''), nullif(btrim(p.district), '')) as area,
         t.pharmacy_id
    into r
    from public.near_poster t
    join public.pharmacy_profiles p on p.id = t.pharmacy_id
    left join public.near_listing_config n on n.pharmacy_id = t.pharmacy_id
   where t.token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('ok', true, 'token', r.token, 'name', r.name,
    'area', r.area, 'pharmacy_id', r.pharmacy_id,
    'url', 'https://medibo.in/near/p/' || r.token,
    'headline', public.ui_text('near.title'),
    'badge', public.ui_text('near.listing_title'),
    'bucket', 'near-posters', 'path', r.token || '.pdf');
end $$;

revoke execute on function public.near_poster_report(text, text, text, integer, text)
  from public, anon, authenticated;
revoke execute on function public.near_poster_job(text) from public, anon, authenticated;

-- ── 7. housekeeping ────────────────────────────────────────────────────────

create or replace function public.near_sweep()
returns jsonb language plpgsql security definer
set search_path to 'public' as $$
declare c public.near_config := public._c426_cfg(); a int; b int; d int;
begin
  delete from public.near_unavailable where until < now() - interval '1 day';
  get diagnostics a = row_count;
  delete from public.near_search_log where at < now() - make_interval(days => c.log_retain_days);
  get diagnostics b = row_count;
  delete from public.near_rate
   where last_seen < now() - interval '2 days'
     and (blocked_until is null or blocked_until < now());
  get diagnostics d = row_count;
  return jsonb_build_object('ok', true, 'unavailable', a, 'log', b, 'rate', d);
end $$;

insert into public.cron_task (name, ord, mode, work_sql, enabled, note, run_at_ist, dml)
values ('near-sweep', 748, 'poll', 'select public.near_sweep()', true,
        'CMD #426 - prunes the /near rate ledger, the search log and expired one-tap hides. Off-peak IST, dml.',
        time '02:23', true)
on conflict (name) do nothing;
