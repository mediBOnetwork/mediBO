-- CMD #409 — FAST ORDERING TRIO
--   1) barcode scan-to-cart on the storefront search bar
--   2) customer voice search through the counting STT path
--   3) recently viewed (a capped ring per customer) as a backend-composed rail
--
-- Everything a customer reads here is a backend string: the RPC payloads carry
-- their own title/message/hint, and the Dart chrome reads ui_copy through c().
-- Idempotent end to end — a resumed worker re-applies this file as a no-op.

-- One reader for every storefront string this command adds. `storefront_ui_label`
-- is the table the storefront RPCs already render their own copy from; a
-- missing key renders as an empty string, never as a Dart fallback word.
create or replace function public.sf_label(p_key text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((select value from public.storefront_ui_label where key = p_key), '');
$function$;

grant execute on function public.sf_label(text) to anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. BARCODE SCAN-TO-CART
-- ═══════════════════════════════════════════════════════════════════════════

-- The catalogue gap ledger. A scan that resolves to nothing is the ONLY signal
-- that the catalogue is missing that code, so it is kept (one row per
-- normalised code, counted) rather than logged and lost.
create table if not exists public.catalog_barcode_miss (
  barcode_norm text primary key,
  sample_raw   text        not null default '',
  code_type    text        not null default 'plain',
  miss_count   int         not null default 0,
  first_seen   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  last_user    uuid
);
alter table public.catalog_barcode_miss enable row level security;
-- Deliberately no policy: this table is reached ONLY through the
-- SECURITY DEFINER functions below, never from a client.

comment on table public.catalog_barcode_miss is
  'CMD #409 — every customer barcode scan the catalogue could not resolve, '
  'counted per normalised code. Surfaced on the admin ops board as '
  'catalog_barcode_gap and self-clears the moment the code is attached to a product.';

create index if not exists catalog_barcode_miss_last_seen_idx
  on public.catalog_barcode_miss (last_seen desc);

-- MEDICINE holds no barcode rows today, so the partial index is empty and
-- free to build; it is what keeps the resolver O(1) once the admin barcode
-- import starts filling the column.
create index if not exists medicine_barcode_norm_idx
  on public."MEDICINE" (public._norm_barcode(barcode))
  where barcode is not null and btrim(barcode) <> '';

create index if not exists product_barcode_norm_idx
  on public.product_barcode (public._norm_barcode(barcode));

-- Customer-safe barcode resolution.
--
-- The counting resolver (barcode_lookup) is admin-only and answers a DIFFERENT
-- question — "how many of this are still to be counted on this supplier's
-- order today". This one answers "which buyable product is this, and can I put
-- it in my cart". It reuses the SAME normalisation and the SAME GS1 parse, so
-- a code that counts also scans.
create or replace function public.storefront_barcode_resolve(p_barcode text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_raw   text := btrim(coalesce(p_barcode, ''));
  v_gs1   jsonb := public.gs1_parse(p_barcode);
  v_norm  text;
  v_try   text;
  v_id    bigint;
  v_buyable boolean;
  v_name  text;
  v_card  jsonb;
  v_lbl   text;
begin
  v_norm := public._norm_barcode(coalesce(v_gs1->>'gtin', p_barcode));

  if v_norm = '' then
    return jsonb_build_object(
      'ok', false, 'error', 'empty',
      'title',   public.sf_label('scan_empty_title'),
      'message', public.sf_label('scan_empty_message'));
  end if;

  -- Leading-zero variants, exactly as the counting resolver tries them: an
  -- EAN-13 printed on a carton and a UPC-A in the catalogue are the same code.
  foreach v_try in array (
    select array_agg(distinct c)
      from unnest(array[v_norm, ltrim(v_norm, '0'), '0' || v_norm]) c
     where c <> '')
  loop
    select m.id,
           lower(coalesce(m.buyable::text, '')) in ('true', 't'),
           m.product_name
      into v_id, v_buyable, v_name
      from public."MEDICINE" m
     where m.barcode is not null and btrim(m.barcode) <> ''
       and public._norm_barcode(m.barcode) = v_try
     limit 1;
    exit when v_id is not null;

    -- Second source: the codes staff have taught the catalogue one scan at a
    -- time. A customer scan must see those too.
    select m.id,
           lower(coalesce(m.buyable::text, '')) in ('true', 't'),
           m.product_name
      into v_id, v_buyable, v_name
      from public.product_barcode pb
      join public."MEDICINE" m on m.id = pb.product_id
     where public._norm_barcode(pb.barcode) = v_try
     limit 1;
    exit when v_id is not null;
  end loop;

  if v_id is null then
    -- The catalogue gap ledger. Counted, not appended: the same unknown strip
    -- scanned forty times is one gap worth forty scans, not forty rows.
    insert into public.catalog_barcode_miss as t
      (barcode_norm, sample_raw, code_type, miss_count, first_seen, last_seen, last_user)
    values (v_norm, left(v_raw, 120),
            coalesce(v_gs1->>'code_type', 'plain'), 1, now(), now(), auth.uid())
    on conflict (barcode_norm) do update
      set miss_count = t.miss_count + 1,
          last_seen  = now(),
          last_user  = coalesce(auth.uid(), t.last_user),
          sample_raw = case when t.sample_raw = '' then left(v_raw, 120) else t.sample_raw end;

    return jsonb_build_object(
      'ok', false, 'error', 'unknown_barcode',
      'barcode', v_raw,
      'title',   public.sf_label('scan_unknown_title'),
      'message', public.sf_label('scan_unknown_message'),
      'hint',    public.sf_label('scan_unknown_hint'));
  end if;

  -- Found, but not on sale in this storefront. Same zone/availability rule
  -- every other customer surface uses — `buyable` — never a stock number.
  if not coalesce(v_buyable, false) then
    return jsonb_build_object(
      'ok', false, 'error', 'not_available',
      'barcode', v_raw, 'product_id', v_id,
      'title',   public.sf_label('scan_unavailable_title'),
      'message', replace(public.sf_label('scan_unavailable_message'),
                         '{name}', coalesce(nullif(btrim(v_name), ''), '')));
  end if;

  v_card := public._sf_cards(array[v_id]);
  if jsonb_array_length(coalesce(v_card, '[]'::jsonb)) = 0 then
    return jsonb_build_object(
      'ok', false, 'error', 'not_available',
      'barcode', v_raw, 'product_id', v_id,
      'title',   public.sf_label('scan_unavailable_title'),
      'message', replace(public.sf_label('scan_unavailable_message'),
                         '{name}', coalesce(nullif(btrim(v_name), ''), '')));
  end if;

  v_lbl := public.sf_label('scan_found_title');
  return jsonb_build_object(
    'ok', true,
    'barcode', v_raw,
    'product_id', v_id,
    'title', v_lbl,
    'message', replace(public.sf_label('scan_found_message'),
                       '{name}', coalesce(nullif(btrim(v_name), ''), '')),
    'code_type', coalesce(v_gs1->>'code_type', 'plain'),
    'card', v_card->0);
end
$function$;

revoke all on function public.storefront_barcode_resolve(text) from public;
grant execute on function public.storefront_barcode_resolve(text) to anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. CUSTOMER VOICE SEARCH
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The audio path is the counting one: the `voice-receive` edge function on
-- Vertex gemini-3.5-flash, called with mode 'search'. What it hands back is a
-- RAW transcript. This function is the second half — it applies the SAME
-- medicine vocabulary the counting flow was taught (voice_vocab for spoken
-- forms/units, voice_brand_alias for the brand names staff kept correcting)
-- and returns the query string that goes into the ordinary search flow.
create or replace function public.voice_search_resolve(
  p_transcript text,
  p_lang       text default 'en')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_raw    text := btrim(coalesce(p_transcript, ''));
  v_flat   text;
  v_tokens text[];
  v_q      text;
  v_hit    int := 0;
begin
  if v_raw = '' then
    return jsonb_build_object(
      'ok', false, 'error', 'blank', 'query', '',
      'title',   public.sf_label('voice_blank_title'),
      'message', public.sf_label('voice_blank_message'));
  end if;

  -- Punctuation only: Devanagari survives, and so does the "40" in Telma 40 —
  -- a strength is part of the product name, not a spoken quantity.
  v_flat := btrim(regexp_replace(
              regexp_replace(lower(v_raw), '[[:punct:]]+', ' ', 'g'),
              '\s+', ' ', 'g'));
  v_tokens := string_to_array(v_flat, ' ');

  -- Token-wise, never regex-over-user-text: drop the counting vocabulary
  -- (pack forms, units, fillers) and apply the brand corrections the counting
  -- flow was already taught. "Telma 40 do strip" searches for "telma 40".
  with t as (
    select ord, tok from unnest(v_tokens) with ordinality u(tok, ord)
     where tok <> ''
  ),
  mapped as (
    select t.ord,
           (select lower(ba.spoken_as) from public.voice_brand_alias ba
             where lower(ba.heard) = t.tok limit 1) as alias,
           t.tok
      from t
     where not exists (
       select 1 from public.voice_vocab vv
        where vv.kind in ('form', 'unit', 'filler') and lower(vv.word) = t.tok)
  )
  select string_agg(coalesce(alias, tok), ' ' order by ord),
         count(*) filter (where alias is not null)
    into v_q, v_hit
    from mapped;

  v_q := btrim(coalesce(v_q, ''));

  if v_q = '' then
    return jsonb_build_object(
      'ok', false, 'error', 'blank', 'query', '', 'transcript', v_raw,
      'title',   public.sf_label('voice_blank_title'),
      'message', public.sf_label('voice_blank_message'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'query', v_q,
    'transcript', v_raw,
    'lang', case when lower(coalesce(p_lang, 'en')) like 'hi%' then 'hi' else 'en' end,
    'corrections', v_hit,
    'heard_label', replace(public.sf_label('voice_heard_label'), '{text}', v_raw),
    'title', public.sf_label('voice_found_title'));
end
$function$;

revoke all on function public.voice_search_resolve(text, text) from public;
grant execute on function public.voice_search_resolve(text, text) to anon, authenticated, service_role;

-- The mic's whole vocabulary+copy contract in one read, so the sheet decides
-- nothing: which language to ask Vertex for, and every word it prints.
create or replace function public.voice_search_config()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'ok', true,
    'lang', coalesce((select value #>> '{}' from public.app_settings
                       where key = 'voice_search_lang'), 'en-IN'),
    'max_seconds', coalesce((select (value #>> '{}')::int from public.app_settings
                              where key = 'voice_search_max_seconds'), 8),
    'title',        public.sf_label('voice_sheet_title'),
    'hint',         public.sf_label('voice_sheet_hint'),
    'listening',    public.sf_label('voice_listening'),
    'working',      public.sf_label('voice_working'),
    'stop_label',   public.sf_label('voice_stop_label'),
    'cancel_label', public.sf_label('voice_cancel_label'),
    'denied_title',   public.sf_label('voice_denied_title'),
    'denied_message', public.sf_label('voice_denied_message'),
    'error_message',  public.sf_label('voice_error_message'));
$function$;

grant execute on function public.voice_search_config() to anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. RECENTLY VIEWED
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.recently_viewed (
  user_id    uuid   not null,
  product_id bigint not null,
  viewed_at  timestamptz not null default now(),
  view_count int    not null default 1,
  primary key (user_id, product_id)
);
alter table public.recently_viewed enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'recently_viewed'
                    and policyname = 'recently_viewed_own') then
    create policy recently_viewed_own on public.recently_viewed
      for select using (user_id = auth.uid());
  end if;
end $$;

create index if not exists recently_viewed_user_time_idx
  on public.recently_viewed (user_id, viewed_at desc);

comment on table public.recently_viewed is
  'CMD #409 — a capped ring of product opens per customer (cap in '
  'app_settings.recently_viewed_cap). Written by recently_viewed_record(), '
  'read back as a rail by recently_viewed_rail() and by storefront_home_v2().';

insert into public.app_settings (key, value)
values ('recently_viewed_cap', to_jsonb(50))
on conflict (key) do nothing;

insert into public.app_settings (key, value)
values ('voice_search_lang', to_jsonb('en-IN'::text))
on conflict (key) do nothing;

insert into public.app_settings (key, value)
values ('voice_search_max_seconds', to_jsonb(8))
on conflict (key) do nothing;

-- One product open. Anonymous viewers keep no history — there is no id to
-- keep it under, and inventing a device id would be tracking a customer who
-- has not signed in.
create or replace function public.recently_viewed_record(p_product_id bigint)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_cap int  := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                    where key = 'recently_viewed_cap'), 50), 1);
  v_n   int;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'anon', 'recorded', false);
  end if;
  if p_product_id is null or not exists (
        select 1 from public."MEDICINE" where id = p_product_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'recorded', false);
  end if;

  insert into public.recently_viewed as r (user_id, product_id, viewed_at, view_count)
  values (v_uid, p_product_id, now(), 1)
  on conflict (user_id, product_id) do update
    set viewed_at  = now(),
        view_count = r.view_count + 1;

  -- The ring. Trim only when it is actually over the cap, so the common write
  -- is one upsert and nothing else.
  select count(*) into v_n from public.recently_viewed where user_id = v_uid;
  if v_n > v_cap then
    delete from public.recently_viewed
     where user_id = v_uid
       and product_id in (
         select product_id from public.recently_viewed
          where user_id = v_uid
          order by viewed_at desc
          offset v_cap);
  end if;

  return jsonb_build_object('ok', true, 'recorded', true,
                            'product_id', p_product_id, 'kept', least(v_n, v_cap));
end
$function$;

revoke all on function public.recently_viewed_record(bigint) from public;
grant execute on function public.recently_viewed_record(bigint) to authenticated, service_role;

-- The rail, composed exactly like every other storefront rail: the cards come
-- from _sf_cards (which is where `buyable` — the zone/availability rule — is
-- applied, at RENDER time, so a product that went off-sale since it was viewed
-- simply is not in the rail).
create or replace function public.recently_viewed_rail(p_limit integer default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_uid   uuid := auth.uid();
  v_n     int  := least(greatest(coalesce(p_limit, 12), 1), 50);
  v_ids   bigint[];
  v_items jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('ok', true, 'has', false, 'items', '[]'::jsonb,
                              'title', '', 'subtitle', '', 'accent_word', '');
  end if;

  select array_agg(product_id order by viewed_at desc) into v_ids
    from (select product_id, viewed_at from public.recently_viewed
           where user_id = v_uid order by viewed_at desc limit v_n) t;

  v_items := case when v_ids is null then '[]'::jsonb else public._sf_cards(v_ids) end;

  return jsonb_build_object(
    'ok', true,
    'has', jsonb_array_length(v_items) > 0,
    'title',       public.sf_label('recent_title'),
    'accent_word', public.sf_label('recent_accent_word'),
    'subtitle',    public.sf_label('recent_subtitle'),
    'items', v_items);
end
$function$;

revoke all on function public.recently_viewed_rail(integer) from public;
grant execute on function public.recently_viewed_rail(integer) to anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE STRINGS — every word the three features print
-- ═══════════════════════════════════════════════════════════════════════════
-- storefront_ui_label: strings the RPCs render into their own payloads.
insert into public.storefront_ui_label (key, value, note) values
  ('scan_empty_title',        'Nothing scanned',                  'CMD #409 barcode scan'),
  ('scan_empty_message',      'No barcode was read. Hold the pack steady inside the frame.', 'CMD #409 barcode scan'),
  ('scan_unknown_title',      'Not in the catalogue yet',         'CMD #409 barcode scan'),
  ('scan_unknown_message',    'We could not match this barcode to a product. It has been reported so the catalogue can be updated.', 'CMD #409 barcode scan'),
  ('scan_unknown_hint',       'Search the product by name instead.', 'CMD #409 barcode scan'),
  ('scan_unavailable_title',  'Not available right now',          'CMD #409 barcode scan'),
  ('scan_unavailable_message','{name} is not on sale in your area at the moment.', 'CMD #409 barcode scan'),
  ('scan_found_title',        'Found it',                         'CMD #409 barcode scan'),
  ('scan_found_message',      '{name}',                           'CMD #409 barcode scan'),
  ('voice_blank_title',       'Did not catch that',               'CMD #409 voice search'),
  ('voice_blank_message',     'We could not hear a product name. Tap the mic and say the medicine name.', 'CMD #409 voice search'),
  ('voice_found_title',       'Searching',                        'CMD #409 voice search'),
  ('voice_heard_label',       'Heard: {text}',                    'CMD #409 voice search'),
  ('voice_sheet_title',       'Speak the medicine name',          'CMD #409 voice search'),
  ('voice_sheet_hint',        'Say the brand name — quantity and pack words are ignored.', 'CMD #409 voice search'),
  ('voice_listening',         'Listening…',                       'CMD #409 voice search'),
  ('voice_working',           'Working on it…',                   'CMD #409 voice search'),
  ('voice_stop_label',        'Stop',                             'CMD #409 voice search'),
  ('voice_cancel_label',      'Cancel',                           'CMD #409 voice search'),
  ('voice_denied_title',      'Microphone blocked',               'CMD #409 voice search'),
  ('voice_denied_message',    'Allow microphone access in your browser to search by voice.', 'CMD #409 voice search'),
  ('voice_error_message',     'Voice search did not work. Type the name instead.', 'CMD #409 voice search'),
  ('recent_title',            'Recently viewed',                  'CMD #409 recently viewed'),
  ('recent_accent_word',      'Recently',                         'CMD #409 recently viewed'),
  ('recent_subtitle',         'PICK UP WHERE YOU LEFT OFF',       'CMD #409 recently viewed')
on conflict (key) do nothing;

-- ui_copy: the strings the Flutter chrome prints through c(). Values are
-- JSONB — a plain text value inserted with to_jsonb, exactly as UiCopy reads.
insert into public.ui_copy (key, value) values
  ('storefront.scan_button',        to_jsonb('Scan barcode'::text)),
  ('storefront.scan_sheet_title',   to_jsonb('Scan a pack'::text)),
  ('storefront.scan_sheet_hint',    to_jsonb('Point the camera at the barcode on the strip or box.'::text)),
  ('storefront.scan_close',         to_jsonb('Close'::text)),
  ('storefront.scan_camera_error',  to_jsonb('Camera unavailable. Allow camera access, or search by name.'::text)),
  ('storefront.scan_again',         to_jsonb('Scan again'::text)),
  ('storefront.mic_button',         to_jsonb('Search by voice'::text)),
  ('storefront.recent_empty',       to_jsonb(''::text))
on conflict (key) do update set value = excluded.value;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. THE HOME RAIL — one section row, rendered by storefront_home_v2
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.storefront_home_section
  (id, kind, layout, ord, active, title, accent_word, subtitle, band_key,
   accent, item_count, max_items, page_size, infinite, category)
values
  ('recently_viewed', 'recently_viewed', 'rail', 15, true,
   'Recently viewed', 'Recently', 'PICK UP WHERE YOU LEFT OFF',
   'band_sky', '#12874F', 12, 12, 0, false, '')
on conflict (id) do nothing;

-- storefront_home_v2 gains ONE branch. Everything else is byte-identical to
-- the shipped function: a new section kind must not change the feed a viewer
-- with no history sees.
create or replace function public.storefront_home_v2(p_items integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_sections    jsonb := '[]'::jsonb;
  v_ids         bigint[];
  v_see_all     text;
  v_see_fmt     text;
  v_label       text;
  v_search_hint text;
  v_theme       jsonb;
  v_title       text;
  v_accentw     text;
  v_subtitle    text;
  v_n           int;
  v_total       int;
  v_cap         int;
  v_cards       jsonb;
  s             record;
begin
  select public.storefront_theme() into v_theme;
  v_see_all := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_label'), 'See all products');
  v_see_fmt := coalesce((select value from public.storefront_ui_label
                          where key = 'see_all_count_label'), '');
  v_search_hint := coalesce((select value from public.storefront_ui_label
                              where key = 'search_hint'), '');

  for s in
    select * from public.storefront_home_section where active order by ord
  loop
    v_n := least(s.item_count, greatest(coalesce(p_items, 100), 1));

    if s.kind = 'feed' then
      select array_agg(product_id order by rank) into v_ids
      from (select product_id, rank from public.storefront_feed
             where lower(category) = lower(s.category)
             order by rank limit v_n) t;
      continue when v_ids is null;

      v_title    := case when s.title <> '' then s.title
                         else initcap(lower(s.category)) end;
      v_accentw  := case when s.accent_word <> '' then s.accent_word
                         else split_part(initcap(lower(s.category)), ' ', 1) end;
      v_subtitle := case when s.subtitle <> '' then s.subtitle
                         else 'TOP PICKS IN ' || s.category end;

      v_total := public.get_storefront_count(s.category);
      v_cap   := case when s.max_items > 0 then least(v_total, s.max_items)
                      else v_total end;
      v_label := case when v_see_fmt <> ''
                      then replace(v_see_fmt, '{n}', to_char(v_total, 'FM999,999'))
                      else v_see_all end;

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', s.layout,
        'title', v_title, 'accent_word', v_accentw, 'subtitle', v_subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'see_all_label', v_label,
        'see_all', jsonb_build_object('type','category','key', s.category),
        'infinite', s.infinite,
        'next_offset', coalesce(array_length(v_ids, 1), 0),
        'page_size', s.page_size,
        'total', v_cap,
        'items', public._sf_cards(v_ids));

    -- CMD #409 — the recently-viewed rail. It is a section like any other, so
    -- it renders through the SAME rail the app already paints and the app
    -- learns nothing new. A viewer with no history (or one who is signed out)
    -- produces no ids and the section is skipped entirely — an empty rail is
    -- never sent. Availability is applied by _sf_cards at RENDER time, so a
    -- product that went off-sale since it was viewed silently drops out.
    elsif s.kind = 'recently_viewed' then
      continue when auth.uid() is null;

      select array_agg(product_id order by viewed_at desc) into v_ids
      from (select product_id, viewed_at from public.recently_viewed
             where user_id = auth.uid()
             order by viewed_at desc limit v_n) t;
      continue when v_ids is null;

      v_cards := public._sf_cards(v_ids);
      continue when jsonb_array_length(v_cards) = 0;

      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', s.layout,
        'title',       case when s.title <> '' then s.title
                            else public.sf_label('recent_title') end,
        'accent_word', case when s.accent_word <> '' then s.accent_word
                            else public.sf_label('recent_accent_word') end,
        'subtitle',    case when s.subtitle <> '' then s.subtitle
                            else public.sf_label('recent_subtitle') end,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'see_all_label', '',
        'see_all', jsonb_build_object('type','','key',''),
        'infinite', false,
        'next_offset', 0,
        'page_size', 0,
        'total', jsonb_array_length(v_cards),
        'items', v_cards);

    elsif s.kind = 'icon_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'icon_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', initcap(lower(fm.category)),
            'count_label', to_char(fm.total,'FM999,999') || ' products',
            'key', fm.category) order by fm.total desc), '[]'::jsonb)
          from (select category, total from public.storefront_feed_meta
                 where category <> 'All' and total > 0
                 order by total desc limit s.item_count) fm));

    elsif s.kind = 'brand_grid' then
      v_sections := v_sections || jsonb_build_object(
        'id', s.id, 'layout', 'brand_grid',
        'title', s.title, 'accent_word', s.accent_word, 'subtitle', s.subtitle,
        'band', coalesce(v_theme->>s.band_key, ''),
        'accent', s.accent,
        'infinite', false, 'next_offset', 0, 'page_size', 0, 'total', 0,
        'items', (select coalesce(jsonb_agg(jsonb_build_object(
            'label', mc.display,
            'count_label', to_char(mc.buyable_count,'FM999,999') || ' products',
            'key', mc.canon) order by mc.buyable_count desc), '[]'::jsonb)
          from (select display, canon, buyable_count from public.medicine_company
                 where buyable_count > 0 order by buyable_count desc
                 limit s.item_count) mc));

    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'generated_for', 'home',
    'theme', v_theme,
    'header', jsonb_build_object(
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'fg',        '#FFFFFF',
      'accent',    v_theme->>'accent',
      'search_hint', v_search_hint),
    'hero', jsonb_build_object(
      'show',    true,
      'eyebrow', coalesce((select value from public.storefront_ui_label where key = 'hero_eyebrow'), ''),
      'title',   coalesce((select value from public.storefront_ui_label where key = 'hero_title'), ''),
      'cta',     coalesce((select value from public.storefront_ui_label where key = 'hero_cta'), ''),
      'bg_top',    v_theme->>'deep',
      'bg_bottom', v_theme->>'deep_alt',
      'accent',    v_theme->>'accent',
      'props', jsonb_build_array(
        jsonb_build_object('icon','inventory','label',
          to_char(public.storefront_viewer_count(),'FM9,99,99,999') || '+ products'),
        jsonb_build_object('icon','truck','label',coalesce((select value from public.storefront_ui_label where key='delivery_time'),'Same-day delivery')),
        jsonb_build_object('icon','verified','label','Licensed distributors'))),
    'sections', v_sections);
end
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. ADMIN VISIBILITY — the catalogue gaps land on the ops board
-- ═══════════════════════════════════════════════════════════════════════════
-- The board is data-driven (ops_board_class) plus one branch per source, and
-- the admin dashboard already renders it verbatim. So a scanned code with no
-- product becomes a queue Om can see, with a route to the screen that fixes
-- it, and NOT one line of Dart.
insert into public.ops_board_class
  (key, title, stage_label, owner_label, action_label, action_route,
   unit_one, unit_many, sla_hours, rank, enabled)
values
  ('catalog_barcode_gap', 'Barcodes customers scanned that we cannot match',
   'Scanned, no product', 'Admin',
   'Open Add medicine and attach the code to its product', 'add_medicine',
   'barcode', 'barcodes', 24, 70, true)
on conflict (key) do nothing;

-- One UNION branch, in the same shape as every other source: which class,
-- which object, what to call it, since when. A gap disappears from the board
-- the moment the code resolves — there is no "mark done" for an admin to
-- forget, because attaching the barcode IS the fix.
create or replace function public.admin_ops_board(p_top integer default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_top    int := least(greatest(coalesce(p_top,3),1), 10);
  v_rows   jsonb;
  v_total  int;
  v_over   int;
  v_worst  text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', 'Not authorised', 'items', '[]'::jsonb);
  end if;

  with items as (
    select 'orders_open'::text class_key, o.id::text item_id,
           coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)) item_label,
           coalesce(nullif(o.pharmacy_name,''), '—') item_sub,
           o.created_at since
      from public.orders o
     where o.closed_at is null

    union all
    select 'supplier_unsettled', so.id::text,
           coalesce(nullif(so.order_code,''), 'SO ' || left(so.id::text,8)),
           coalesce(nullif(so.supplier_name,''), '—'),
           so.created_at
      from public.supplier_orders so
     where so.settled_at is null

    union all
    select 'inquiry_pending', i.id::text,
           coalesce(nullif(i.product_name,''), 'Inquiry ' || i.id::text),
           coalesce(nullif(i.current_status,''), '—'),
           coalesce(i.asked_at, i.created_at)
      from public.inquiry i
     where i.current_status = 'Confirmation Pending'

    union all
    select 'bills_pending', pb.id::text,
           coalesce(nullif(pb.file_name,''), 'Bill ' || left(pb.id::text,8)),
           coalesce(nullif(pb.supplier_name,''), '—'),
           coalesce(pb.received_at, pb.created_at)
      from public.pending_bills pb
     where pb.status = 'pending'

    union all
    select 'bill_scan_error', pb.id::text,
           coalesce(nullif(pb.file_name,''), 'Scan ' || left(pb.id::text,8)),
           coalesce(nullif(pb.supplier_name,''), '—'),
           coalesce(pb.received_at, pb.created_at)
      from public.pending_bills pb
     where pb.scan_status = 'error'

    union all
    select 'claims_unverified', pc.id::text,
           coalesce(nullif(pc.utr,''), 'Claim ' || left(pc.id::text,8)),
           coalesce(nullif(pc.payee_name,''), coalesce(nullif(pc.sender_phone,''),'—')),
           coalesce(pc.paid_ts, pc.received_at, pc.created_at)
      from public.payment_claims pc
     where coalesce(pc.status,'') not in ('verified','rejected')

    union all
    select 'stock_followup_overdue', q.id::text,
           coalesce(nullif(m.product_name,''), 'Product ' || q.product_id::text),
           coalesce(nullif(q.supplier_name,''), '—'),
           q.due_at
      from public.stock_update_queue q
      left join "MEDICINE" m on m.id = q.product_id
     where q.resolved_at is null and q.due_at < now()

    union all
    -- CMD #409 — a customer scanned a barcode the catalogue could not match.
    select 'catalog_barcode_gap', b.barcode_norm,
           coalesce(nullif(b.sample_raw,''), b.barcode_norm),
           b.miss_count || case when b.miss_count = 1 then ' scan' else ' scans' end
             || ', no product',
           b.first_seen
      from public.catalog_barcode_miss b
     where not exists (
             select 1 from "MEDICINE" m
              where m.barcode is not null and btrim(m.barcode) <> ''
                and public._norm_barcode(m.barcode) = b.barcode_norm)
       and not exists (
             select 1 from public.product_barcode pb
              where public._norm_barcode(pb.barcode) = b.barcode_norm)

    union all
    select 'wa_send_blocked', a.id::text,
           a.reason,
           coalesce(nullif(a.event_key,''), '—'),
           a.created_at
      from public.wa_send_attempts a
     where a.ok = false
       and a.created_at >= now() - interval '7 days'
       and coalesce(a.phone,'') not like '9000000%'
       and exists (select 1 from public.wa_send_fault_rule f
                    where f.enabled and f.is_blocking
                      and ((f.match_kind = 'exact' and a.reason = f.match_text)
                        or (f.match_kind = 'ilike' and a.reason ilike f.match_text)))
  ),
  scoped as (
    select i.*, c.title, c.stage_label, c.owner_label, c.action_label,
           c.action_route, c.unit_one, c.unit_many, c.sla_hours, c.rank,
           extract(epoch from (now() - i.since)) / 3600.0 as age_hours
      from items i
      join public.ops_board_class c on c.key = i.class_key and c.enabled
  ),
  agg as (
    select class_key, title, stage_label, owner_label, action_label, action_route,
           unit_one, unit_many, sla_hours, rank,
           count(*)::int n,
           count(*) filter (where age_hours > sla_hours)::int n_over,
           max(age_hours) max_age_hours,
           min(since) oldest_since
      from scoped
     group by 1,2,3,4,5,6,7,8,9,10
  ),
  topn as (
    select s.class_key,
           jsonb_agg(jsonb_build_object(
             'id',         s.item_id,
             'label',      s.item_label,
             'sub_label',  s.item_sub,
             'age_label',  public.ops_age_label(s.since),
             'over_sla',   s.age_hours > s.sla_hours
           ) order by s.since) as sample
      from (select *, row_number() over (partition by class_key order by since) rn
              from scoped) s
     where s.rn <= v_top
     group by s.class_key
  )
  select jsonb_agg(jsonb_build_object(
           'key',           a.class_key,
           'title',         a.title,
           'stage_label',   a.stage_label,
           'owner_label',   'Waiting on: ' || a.owner_label,
           'action_label',  a.action_label,
           'action_route',  a.action_route,
           'count',         a.n,
           'count_label',   a.n || ' ' || case when a.n = 1 then a.unit_one else a.unit_many end,
           'age_label',     'oldest ' || public.ops_age_label(a.oldest_since),
           'oldest_label',  public.ops_age_label(a.oldest_since),
           'over_sla',      a.n_over,
           'over_sla_label',case when a.n_over = 0
                                 then 'all within ' || round(a.sla_hours)::int || 'h'
                                 else a.n_over || ' past ' || round(a.sla_hours)::int || 'h' end,
           'tone',          case when a.max_age_hours > a.sla_hours * 3 then 'bad'
                                 when a.max_age_hours > a.sla_hours     then 'warn'
                                 else 'good' end,
           'breach_ratio',  round((a.max_age_hours / nullif(a.sla_hours,0))::numeric, 2),
           'items',         coalesce(t.sample, '[]'::jsonb)
         ) order by (a.max_age_hours / nullif(a.sla_hours,0)) desc nulls last, a.rank desc)
    into v_rows
    from agg a
    left join topn t on t.class_key = a.class_key;

  select coalesce(sum((r->>'count')::int),0),
         coalesce(sum((r->>'over_sla')::int),0),
         (select r2->>'title' from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) r2 limit 1)
    into v_total, v_over, v_worst
    from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) r;

  return jsonb_build_object(
    'ok', true,
    'title', 'What is stuck right now',
    'subtitle', case when coalesce(v_total,0) = 0
                     then 'Nothing is waiting past its deadline.'
                     else v_total || ' items waiting, ' || v_over || ' past their deadline' end,
    'headline_count', coalesce(v_total,0),
    'over_sla_count', coalesce(v_over,0),
    'headline_label', case when coalesce(v_total,0) = 0 then 'All clear'
                           else coalesce(v_over,0) || ' overdue' end,
    'headline_tone', case when coalesce(v_over,0) = 0 then 'good'
                          when coalesce(v_over,0) < 10 then 'warn' else 'bad' end,
    'worst_label', case when v_worst is null then '' else 'Worst: ' || v_worst end,
    'empty_label', 'Nothing is stuck. Every queue is inside its deadline.',
    'checked_label', 'Read ' || to_char(now() at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
    'items', coalesce(v_rows, '[]'::jsonb),
    'note', 'Worst-first is measured against each queue''s own deadline, not raw age — a claim one day past a 24-hour deadline outranks a bill one day past a 48-hour one.'
  );
end
$function$;
