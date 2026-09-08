-- ============================================================================
-- CHANGE #460 — feature_gaps 161: 55% of the catalogue has no image and the
-- rest hotlinks Tata 1mg's CDN.
--
-- Measured 2026-09-01 on 562,549 "MEDICINE" rows:
--   309,789 (55.1%) image_url_1 null/empty
--   252,760 (44.9%) https://onemg.gumlet.io/...
--         0 served from our own storage (the product-images bucket is empty)
-- And the consequence nobody had measured: refresh_storefront_feed() requires a
-- non-empty image_url_1, so 43,492 of the 75,597 BUYABLE products (57.5%) are
-- not in the storefront feed at all — not a placeholder, absent.
--
-- What lands here: our own mirror, as a self-draining queue rather than a
-- one-shot bulk copy (252,760 remote fetches cannot run inside one command),
-- plus the catalogue-quality metric the row asked for, cached so no user path
-- ever count(*)s the 562k table.
-- ============================================================================

-- ── the mirror queue ───────────────────────────────────────────────────────
create table if not exists public.medicine_image_mirror (
  product_id   bigint primary key,
  source_url   text        not null,
  status       text        not null default 'queued',   -- queued|running|done|failed|skipped
  priority     int         not null default 100,        -- lower runs first
  attempts     int         not null default 0,
  storage_path text,
  public_url   text,
  bytes        bigint,
  last_error   text,
  queued_at    timestamptz not null default now(),
  started_at   timestamptz,
  done_at      timestamptz
);

create index if not exists medicine_image_mirror_pick_idx
  on public.medicine_image_mirror (priority, product_id)
  where status = 'queued';
create index if not exists medicine_image_mirror_status_idx
  on public.medicine_image_mirror (status);

alter table public.medicine_image_mirror enable row level security;
-- No policy: the table is reached only through the SECURITY DEFINER RPCs below.

-- ── the cached metric (latency rule: never count(*) 562k on a user path) ────
create table if not exists public.catalogue_health_cache (
  id           text        primary key default 'singleton',
  data         jsonb       not null default '{}'::jsonb,
  refreshed_at timestamptz not null default now()
);
alter table public.catalogue_health_cache enable row level security;

insert into public.catalogue_health_cache (id) values ('singleton')
  on conflict (id) do nothing;

-- ── every string the screen prints ─────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('catalogue_health.title',            to_jsonb('Catalogue health'::text)),
  ('catalogue_health.subtitle',         to_jsonb('Image and classification coverage across the product catalogue.'::text)),
  ('catalogue_health.updated_prefix',   to_jsonb('Updated '::text)),
  ('catalogue_health.never_refreshed',  to_jsonb('Not measured yet — run a refresh.'::text)),
  ('catalogue_health.sec_images',       to_jsonb('Product images'::text)),
  ('catalogue_health.sec_images_note',  to_jsonb('A product with no image is left out of the storefront feed entirely, so image coverage is a browsability number, not a cosmetic one.'::text)),
  ('catalogue_health.sec_class',        to_jsonb('Classification'::text)),
  ('catalogue_health.sec_class_note',   to_jsonb('Products with no therapeutic class are browsable under the OTHERS tile; this is a data-quality number, not a reachability one.'::text)),
  ('catalogue_health.sec_mirror',       to_jsonb('Image mirror'::text)),
  ('catalogue_health.sec_mirror_note',  to_jsonb('Hotlinked images are copied into our own product-images bucket in the background, buyable products first.'::text)),
  ('catalogue_health.row_total',        to_jsonb('Products in catalogue'::text)),
  ('catalogue_health.row_buyable',      to_jsonb('Buyable products'::text)),
  ('catalogue_health.row_in_feed',      to_jsonb('Browsable in the storefront'::text)),
  ('catalogue_health.row_no_image',     to_jsonb('No image'::text)),
  ('catalogue_health.row_hotlinked',    to_jsonb('Hotlinked to an external CDN'::text)),
  ('catalogue_health.row_mirrored',     to_jsonb('Served from our own storage'::text)),
  ('catalogue_health.row_no_class',     to_jsonb('No therapeutic class'::text)),
  ('catalogue_health.row_no_salt',      to_jsonb('No salt composition'::text)),
  ('catalogue_health.row_others_bucket',to_jsonb('Reachable under the OTHERS tile'::text)),
  ('catalogue_health.row_queued',       to_jsonb('Waiting to be mirrored'::text)),
  ('catalogue_health.row_running',      to_jsonb('Being mirrored now'::text)),
  ('catalogue_health.row_done',         to_jsonb('Mirrored'::text)),
  ('catalogue_health.row_failed',       to_jsonb('Failed'::text)),
  ('catalogue_health.of_buyable',       to_jsonb('of buyable'::text)),
  ('catalogue_health.of_catalogue',     to_jsonb('of catalogue'::text)),
  ('catalogue_health.act_refresh',      to_jsonb('Re-measure now'::text)),
  ('catalogue_health.act_queue',        to_jsonb('Queue the next 20,000 images'::text)),
  ('catalogue_health.queued_toast',     to_jsonb('{n} products added to the mirror queue.'::text)),
  ('catalogue_health.refreshed_toast',  to_jsonb('Catalogue re-measured.'::text)),
  ('catalogue_health.empty_queue',      to_jsonb('Nothing waiting — every hotlinked image is queued or mirrored.'::text)),
  ('catalogue_health.not_authorized',   to_jsonb('You do not have access to catalogue health.'::text))
on conflict (key) do nothing;

create or replace function public._cat_uic(p_key text, p_default text)
returns text language sql stable as $$
  select coalesce((select value #>> '{}' from public.ui_copy where key = p_key), p_default);
$$;

-- Every number the screen shows is formatted HERE (Indian grouping), never in
-- Dart.
create or replace function public._cat_num(p_n bigint)
returns text language plpgsql immutable as $$
declare s text; head text; tail text; out text := '';
begin
  if p_n is null then return '0'; end if;
  s := abs(p_n)::text;
  if length(s) <= 3 then
    out := s;
  else
    tail := right(s, 3);
    head := left(s, length(s) - 3);
    while length(head) > 2 loop
      out := ',' || right(head, 2) || out;
      head := left(head, length(head) - 2);
    end loop;
    out := head || out || ',' || tail;
  end if;
  return case when p_n < 0 then '-' || out else out end;
end $$;

create or replace function public._cat_pct(p_part bigint, p_whole bigint)
returns text language sql immutable as $$
  select case when coalesce(p_whole,0) = 0 then '0.0%'
              else to_char(round((p_part::numeric * 100) / p_whole, 1), 'FM990.0') || '%' end;
$$;

-- ── the measurement (heavy; cron + explicit refresh only, never a user path) ─
create or replace function public.catalogue_health_refresh()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  perform set_config('statement_timeout', '120000', true);

  with m as (
    select
      count(*)::bigint                                                                      as total,
      count(*) filter (where coalesce(buyable,false))::bigint                               as buyable,
      count(*) filter (where coalesce(image_url_1,'') = '')::bigint                          as no_image,
      count(*) filter (where coalesce(buyable,false) and coalesce(image_url_1,'') = '')::bigint as buyable_no_image,
      count(*) filter (where image_url_1 ilike '%onemg.gumlet.io%')::bigint                   as hotlinked,
      count(*) filter (where coalesce(buyable,false) and image_url_1 ilike '%onemg.gumlet.io%')::bigint as buyable_hotlinked,
      count(*) filter (where image_url_1 ilike '%/storage/v1/object/public/product-images/%')::bigint   as mirrored,
      count(*) filter (where coalesce(therapeutic_class,'') = '')::bigint                    as no_class,
      count(*) filter (where coalesce(buyable,false) and coalesce(therapeutic_class,'') = '')::bigint   as buyable_no_class,
      count(*) filter (where coalesce(salt_composition,'') = '')::bigint                     as no_salt,
      count(*) filter (where coalesce(buyable,false) and coalesce(salt_composition,'') = '')::bigint    as buyable_no_salt
    from public."MEDICINE"
  ),
  q as (
    select
      count(*) filter (where status = 'queued')::bigint  as queued,
      count(*) filter (where status = 'running')::bigint as running,
      count(*) filter (where status = 'done')::bigint    as done,
      count(*) filter (where status = 'failed')::bigint  as failed
    from public.medicine_image_mirror
  ),
  f as (
    select coalesce((select total from public.storefront_feed_meta where category = 'All'), 0)::bigint as in_feed,
           coalesce((select total from public.storefront_feed_meta where lower(category) = 'others'), 0)::bigint as others_bucket
  )
  select to_jsonb(m) || to_jsonb(q) || to_jsonb(f) into v from m, q, f;

  update public.catalogue_health_cache
     set data = v, refreshed_at = now()
   where id = 'singleton';

  return v;
end $function$;

-- ── the render-ready payload ───────────────────────────────────────────────
create or replace function public.catalogue_health()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare d jsonb; ts timestamptz; g bigint; b bigint;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._cat_uic('catalogue_health.not_authorized','You do not have access to catalogue health.'));
  end if;

  select data, refreshed_at into d, ts from public.catalogue_health_cache where id = 'singleton';
  d := coalesce(d, '{}'::jsonb);
  g := coalesce((d->>'total')::bigint, 0);
  b := coalesce((d->>'buyable')::bigint, 0);

  return jsonb_build_object(
    'ok', true,
    'has_data', (g > 0),
    'title',    public._cat_uic('catalogue_health.title','Catalogue health'),
    'subtitle', public._cat_uic('catalogue_health.subtitle','Image and classification coverage across the product catalogue.'),
    'updated_label', case when g = 0
        then public._cat_uic('catalogue_health.never_refreshed','Not measured yet — run a refresh.')
        else public._cat_uic('catalogue_health.updated_prefix','Updated ') ||
             to_char(ts at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM') || ' IST' end,
    'actions', jsonb_build_array(
      jsonb_build_object('key','refresh','label', public._cat_uic('catalogue_health.act_refresh','Re-measure now')),
      jsonb_build_object('key','queue',  'label', public._cat_uic('catalogue_health.act_queue','Queue the next 20,000 images'))),
    'sections', jsonb_build_array(
      jsonb_build_object(
        'key','images',
        'title', public._cat_uic('catalogue_health.sec_images','Product images'),
        'note',  public._cat_uic('catalogue_health.sec_images_note',''),
        'rows', jsonb_build_array(
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_total','Products in catalogue'),
                             'value', public._cat_num(g), 'sub','', 'tone','neutral'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_buyable','Buyable products'),
                             'value', public._cat_num(b),
                             'sub', public._cat_pct(b, g) || ' ' || public._cat_uic('catalogue_health.of_catalogue','of catalogue'),
                             'tone','neutral'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_in_feed','Browsable in the storefront'),
                             'value', public._cat_num(coalesce((d->>'in_feed')::bigint,0)),
                             'sub', public._cat_pct(coalesce((d->>'in_feed')::bigint,0), b) || ' ' || public._cat_uic('catalogue_health.of_buyable','of buyable'),
                             'tone', case when b > 0 and coalesce((d->>'in_feed')::bigint,0) * 2 < b then 'danger' else 'neutral' end),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_no_image','No image'),
                             'value', public._cat_num(coalesce((d->>'buyable_no_image')::bigint,0)),
                             'sub', public._cat_pct(coalesce((d->>'buyable_no_image')::bigint,0), b) || ' ' || public._cat_uic('catalogue_health.of_buyable','of buyable'),
                             'tone','danger'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_hotlinked','Hotlinked to an external CDN'),
                             'value', public._cat_num(coalesce((d->>'hotlinked')::bigint,0)),
                             'sub', public._cat_pct(coalesce((d->>'hotlinked')::bigint,0), g) || ' ' || public._cat_uic('catalogue_health.of_catalogue','of catalogue'),
                             'tone','warning'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_mirrored','Served from our own storage'),
                             'value', public._cat_num(coalesce((d->>'mirrored')::bigint,0)),
                             'sub', public._cat_pct(coalesce((d->>'mirrored')::bigint,0), g) || ' ' || public._cat_uic('catalogue_health.of_catalogue','of catalogue'),
                             'tone', case when coalesce((d->>'mirrored')::bigint,0) > 0 then 'success' else 'neutral' end))),
      jsonb_build_object(
        'key','class',
        'title', public._cat_uic('catalogue_health.sec_class','Classification'),
        'note',  public._cat_uic('catalogue_health.sec_class_note',''),
        'rows', jsonb_build_array(
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_no_class','No therapeutic class'),
                             'value', public._cat_num(coalesce((d->>'no_class')::bigint,0)),
                             'sub', public._cat_pct(coalesce((d->>'no_class')::bigint,0), g) || ' ' || public._cat_uic('catalogue_health.of_catalogue','of catalogue'),
                             'tone','warning'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_no_salt','No salt composition'),
                             'value', public._cat_num(coalesce((d->>'no_salt')::bigint,0)),
                             'sub', public._cat_pct(coalesce((d->>'no_salt')::bigint,0), g) || ' ' || public._cat_uic('catalogue_health.of_catalogue','of catalogue'),
                             'tone','warning'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_others_bucket','Reachable under the OTHERS tile'),
                             'value', public._cat_num(coalesce((d->>'others_bucket')::bigint,0)),
                             'sub','', 'tone','success'))),
      jsonb_build_object(
        'key','mirror',
        'title', public._cat_uic('catalogue_health.sec_mirror','Image mirror'),
        'note',  public._cat_uic('catalogue_health.sec_mirror_note',''),
        'rows', jsonb_build_array(
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_queued','Waiting to be mirrored'),
                             'value', public._cat_num(coalesce((d->>'queued')::bigint,0)), 'sub','', 'tone','neutral'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_running','Being mirrored now'),
                             'value', public._cat_num(coalesce((d->>'running')::bigint,0)), 'sub','', 'tone','info'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_done','Mirrored'),
                             'value', public._cat_num(coalesce((d->>'done')::bigint,0)), 'sub','', 'tone','success'),
          jsonb_build_object('label', public._cat_uic('catalogue_health.row_failed','Failed'),
                             'value', public._cat_num(coalesce((d->>'failed')::bigint,0)), 'sub','', 'tone','danger')))));
end $function$;

-- ── the queue builder — buyable first, then the rest ───────────────────────
create or replace function public.catalogue_image_queue_build(p_limit int default 20000)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_added int; v_lim int := least(greatest(coalesce(p_limit,20000), 1), 20000);
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public._cat_uic('catalogue_health.not_authorized','You do not have access to catalogue health.'));
  end if;

  with cand as (
    select m.id, m.image_url_1,
           case when coalesce(m.buyable,false) then 10 else 100 end as pri
      from public."MEDICINE" m
     where m.image_url_1 ilike '%onemg.gumlet.io%'
       and not exists (select 1 from public.medicine_image_mirror q where q.product_id = m.id)
     order by case when coalesce(m.buyable,false) then 0 else 1 end,
              coalesce(m.sales_count,0) desc
     limit v_lim
  )
  insert into public.medicine_image_mirror (product_id, source_url, priority)
  select id, image_url_1, pri from cand
  on conflict (product_id) do nothing;

  get diagnostics v_added = row_count;

  return jsonb_build_object('ok', true, 'added', v_added,
    'message', case when v_added = 0
      then public._cat_uic('catalogue_health.empty_queue','Nothing waiting — every hotlinked image is queued or mirrored.')
      else replace(public._cat_uic('catalogue_health.queued_toast','{n} products added to the mirror queue.'),
                   '{n}', public._cat_num(v_added::bigint)) end);
end $function$;

-- ── the worker's two calls (service_role only) ─────────────────────────────
create or replace function public.catalogue_mirror_next(p_limit int default 20)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb; v_lim int := least(greatest(coalesce(p_limit,20), 1), 100);
begin
  if coalesce(current_setting('request.jwt.claim.role', true),
              (current_setting('request.jwt.claims', true)::jsonb->>'role'), '') <> 'service_role'
     and not public._is_super() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  -- Anything stuck 'running' for over 10 minutes goes back on the queue: a
  -- worker that died mid-fetch must not park a row forever.
  update public.medicine_image_mirror
     set status = 'queued', started_at = null
   where status = 'running' and started_at < now() - interval '10 minutes';

  with picked as (
    select product_id from public.medicine_image_mirror
     where status = 'queued'
     order by priority, product_id
     limit v_lim
     for update skip locked
  ), moved as (
    update public.medicine_image_mirror q
       set status = 'running', started_at = now(), attempts = q.attempts + 1
      from picked p where q.product_id = p.product_id
    returning q.product_id, q.source_url
  )
  select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'source_url', source_url)), '[]'::jsonb)
    into v from moved;

  return jsonb_build_object('ok', true, 'items', v, 'count', jsonb_array_length(v),
                            'bucket', 'product-images');
end $function$;

create or replace function public.catalogue_mirror_report(
  p_product_id bigint, p_ok boolean, p_public_url text default null,
  p_storage_path text default null, p_bytes bigint default null, p_error text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(current_setting('request.jwt.claim.role', true),
              (current_setting('request.jwt.claims', true)::jsonb->>'role'), '') <> 'service_role'
     and not public._is_super() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  if p_ok and coalesce(p_public_url,'') <> '' then
    update public.medicine_image_mirror
       set status = 'done', public_url = p_public_url, storage_path = p_storage_path,
           bytes = p_bytes, last_error = null, done_at = now()
     where product_id = p_product_id;
    -- The catalogue now points at OUR copy. image_src_1 keeps the provenance so
    -- the original source is never lost.
    update public."MEDICINE"
       set image_url_1 = p_public_url,
           image_src_1 = coalesce(nullif(image_src_1,''), image_url_1),
           has_image   = true
     where id = p_product_id;
  else
    update public.medicine_image_mirror
       set status = case when attempts >= 3 then 'failed' else 'queued' end,
           last_error = left(coalesce(p_error,'unknown'), 500),
           started_at = null
     where product_id = p_product_id;
  end if;

  return jsonb_build_object('ok', true);
end $function$;

revoke all on function public.catalogue_mirror_next(int) from public, anon, authenticated;
revoke all on function public.catalogue_mirror_report(bigint, boolean, text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.catalogue_health() to authenticated;
grant execute on function public.catalogue_image_queue_build(int) to authenticated;
grant execute on function public.catalogue_health_refresh() to authenticated;

-- ── the dispatcher task (never a bare */N pg_cron job — CHANGE #273) ───────
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note,
                              base_interval_s, max_interval_s, current_interval_s)
values ('catalogue_health_refresh', 940, 'poll',
        'select exists (select 1 from public.catalogue_health_cache where refreshed_at < now() - interval ''6 hours'')',
        'select public.catalogue_health_refresh()',
        120000, true,
        'CHANGE #460 / gap 161 — re-measures catalogue image + classification coverage into catalogue_health_cache. Heavy scan, so it runs at most every 6 hours and never on a user path.',
        21600, 43200, 21600)
on conflict (name) do nothing;
