-- CMD #2207 — storefront_home_v2: 1582.86 ms mean, the worst customer RPC.
--
-- CAUSE: not the query. storefront_home_cache held exactly TWO rows, and BOTH
-- warm tasks that are supposed to keep them fresh were disabled:
--   c1895-storefront-home-warm  enabled=f  last_result=error (82.8 s)
--   storefront_home_warm        enabled=f
-- so every approved customer whose zone row was older than 10 minutes rebuilt
-- the whole 375 kB feed INLINE, on their own request: storefront_home_cache
-- recorded build_ms = 4146 for zone:1:6. Zone traffic is sparse enough that
-- nearly every such visit paid it — 41 calls, 64.9 s of database time.
--
-- Two things were wrong with the tick itself:
--   1. it warmed ONLY 'anon:%' keys, so a 'zone:N:%' row could never be
--      refreshed by anything except a customer's own request; and
--   2. `union select 100` forced a build of the 100-item variant on every run
--      — the 3.6 MB payload the item cap exists to prevent — which is what
--      timed the task out and disabled it.
--
-- FIX (the METHOD's step 3: a precomputed cache refreshed by a cron_task):
--   * the RPC NEVER rebuilds inline while any copy exists. A stale hero number
--     is worth more than a four-second wait; this is what the function's own
--     comment already says about the anonymous path, now true for every path.
--   * the cache records WHO built each row, and the tick rebuilds a stale row
--     AS THAT VIEWER. The payload is therefore byte-identical to the one that
--     viewer's own inline rebuild would have written — the tick only moves the
--     work off the request.
--   * every interval is an app_settings value, not a literal.

-- ── who built each row, so the tick can rebuild it identically ─────────────
alter table public.storefront_home_cache
  add column if not exists built_by uuid;

comment on column public.storefront_home_cache.built_by is
  'CMD #2207 — the viewer whose build this payload is. storefront_home_warm_tick() re-runs the build as this viewer, so a refreshed row is byte-identical to the inline rebuild it replaces.';

-- ── the intervals, live-settable ──────────────────────────────────────────
insert into public.app_settings (key, value) values
  ('home_cache_stale_s',   to_jsonb(600)),
  ('home_warm_stale_s',    to_jsonb(300)),
  ('home_cache_evict_s',   to_jsonb(3600)),
  ('home_warm_max_keys',   to_jsonb(24))
on conflict (key) do nothing;

-- ── the RPC: serve the cache, never rebuild inline while a copy exists ────
create or replace function public.storefront_home_v2(p_items integer default 12)
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $fn$
declare
  v_zone smallint; v_key text;
  v_n int := least(greatest(coalesce(p_items, 12), 1),
                   greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'home_items_cap'), 12), 1));
  v_cached jsonb; v_ords jsonb; v_built timestamptz; v_payload jsonb;
  v_rv jsonb; v_idx int; v_t0 timestamptz;
begin
  v_zone := public._viewer_zone_or_null();
  v_key  := coalesce('zone:' || v_zone::text, 'anon') || ':' || v_n;

  select payload, ords, built_at into v_cached, v_ords, v_built
    from public.storefront_home_cache where cache_key = v_key;

  -- CMD #2207 — the ONLY inline build left is the very first one for a key.
  -- A stale copy is served as-is and refreshed off-request by
  -- storefront_home_warm_tick(), which rebuilds it as the viewer who built it.
  if v_cached is null then
    v_t0 := clock_timestamp();
    v_payload := public._storefront_home_build(v_n);
    v_ords    := coalesce(v_payload -> '_ords', '[]'::jsonb);
    v_payload := v_payload - '_ords';
    insert into public.storefront_home_cache (cache_key, payload, ords, built_at, build_ms, built_by)
    values (v_key, v_payload, v_ords, now(),
            (extract(epoch from clock_timestamp() - v_t0) * 1000)::int, auth.uid())
    on conflict (cache_key) do update
      set payload = excluded.payload, ords = excluded.ords,
          built_at = now(), build_ms = excluded.build_ms, built_by = excluded.built_by;
  else
    v_payload := v_cached;
    -- CMD #2207 — a zone row built before this column existed carries no
    -- builder, and the tick refuses to guess one (rebuilding a zone payload
    -- as anon would change what the zone is served). Adopt the viewer who is
    -- reading it: from here the tick can refresh this key off-request.
    if v_zone is not null and auth.uid() is not null then
      update public.storefront_home_cache
         set built_by = auth.uid()
       where cache_key = v_key and built_by is null;
    end if;
  end if;

  if auth.uid() is not null then
    v_rv := public._storefront_home_recent(v_n);
    if v_rv is not null then
      select count(*) into v_idx
        from jsonb_array_elements_text(coalesce(v_ords, '[]'::jsonb)) o
       where o::int < (v_rv ->> '_ord')::int;
      v_payload := jsonb_set(v_payload, '{sections}',
        jsonb_insert(coalesce(v_payload -> 'sections', '[]'::jsonb),
                     array[v_idx::text], v_rv - '_ord'));
    end if;
  end if;

  -- CMD #2059 — the registration surface rides with the home feed, so the
  -- form is already in the app's hands before Continue is tapped. It is added
  -- AFTER the shared zone cache, because it is per-user.
  if auth.uid() is not null and not public.viewer_is_approved_customer() then
    begin
      v_payload := v_payload || jsonb_build_object(
        'registration', public.customer_registration_payload());
    exception when others then null;
    end;
  end if;

  return v_payload;
end
$fn$;

-- ── the tick: every key, as its own builder, bounded and error-isolated ───
create or replace function public.storefront_home_warm_tick()
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $fn$
declare
  v_row record; v_payload jsonb; v_ords jsonb; v_t0 timestamptz;
  v_out jsonb := '[]'::jsonb; v_n int; v_default int;
  v_stale_s  int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                        where key = 'home_warm_stale_s'), 300), 30);
  v_evict_s  int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                        where key = 'home_cache_evict_s'), 3600), 300);
  v_max      int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                        where key = 'home_warm_max_keys'), 24), 1);
  v_done int := 0;
begin
  v_default := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                   where key = 'home_items_cap'), 12), 1);

  -- The default anonymous key must always exist: it is what a first-ever
  -- visitor is served, and building it on their request is the 700 ms this
  -- change exists to remove.
  if not exists (select 1 from public.storefront_home_cache
                  where cache_key = 'anon:' || v_default) then
    perform set_config('request.jwt.claims', '', true);
    v_t0 := clock_timestamp();
    v_payload := public._storefront_home_build(v_default);
    v_ords    := coalesce(v_payload -> '_ords', '[]'::jsonb);
    v_payload := v_payload - '_ords';
    insert into public.storefront_home_cache (cache_key, payload, ords, built_at, build_ms, built_by)
    values ('anon:' || v_default, v_payload, v_ords, now(),
            (extract(epoch from clock_timestamp() - v_t0) * 1000)::int, null)
    on conflict (cache_key) do update
      set payload = excluded.payload, ords = excluded.ords,
          built_at = now(), build_ms = excluded.build_ms, built_by = excluded.built_by;
    v_out := v_out || jsonb_build_object('key', 'anon:' || v_default, 'seeded', true);
    v_done := v_done + 1;
  end if;

  -- Every key the app has actually asked for — anon AND zone — oldest first.
  for v_row in
    select c.cache_key, c.built_by
      from public.storefront_home_cache c
     where c.built_at <= now() - make_interval(secs => v_stale_s)
       -- a zone row whose builder is not known is LEFT ALONE: rebuilding it
       -- as anon would hand the zone a payload no viewer of that zone would
       -- have produced. The RPC stamps built_by on the next read of it.
       and (c.built_by is not null or c.cache_key not like 'zone:%')
     order by c.built_at asc
     limit v_max
  loop
    exit when v_done >= v_max;
    begin
      v_n := nullif(split_part(v_row.cache_key, ':', case
               when v_row.cache_key like 'zone:%' then 3 else 2 end), '')::int;
      if v_n is null or v_n < 1 or v_n > v_default then
        -- a variant the item cap no longer allows: drop it rather than build it.
        delete from public.storefront_home_cache where cache_key = v_row.cache_key;
        continue;
      end if;

      -- Rebuild AS THE VIEWER WHO BUILT IT, so the refreshed payload is the
      -- one that viewer's own inline rebuild would have written.
      if v_row.built_by is null then
        perform set_config('request.jwt.claims', '', true);
      else
        perform set_config('request.jwt.claims',
          json_build_object('sub', v_row.built_by::text, 'role', 'authenticated')::text, true);
      end if;
      -- the per-request helper memos are keyed on the credential; clear them
      -- so this key's build reads its own viewer, not the previous key's.
      perform set_config('medibo.m_vzone', '', true);
      perform set_config('medibo.m_cazone', '', true);
      perform set_config('medibo.m_cartpct', '', true);
      perform set_config('medibo.m_cartuser', '', true);
      perform set_config('medibo.m_role', '', true);
      perform set_config('medibo.viewer_approved', '', true);
      perform set_config('medibo.wish_owner', '', true);

      v_t0 := clock_timestamp();
      v_payload := public._storefront_home_build(v_n);
      v_ords    := coalesce(v_payload -> '_ords', '[]'::jsonb);
      v_payload := v_payload - '_ords';
      update public.storefront_home_cache
         set payload = v_payload, ords = v_ords, built_at = now(),
             build_ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::int
       where cache_key = v_row.cache_key;
      v_out := v_out || jsonb_build_object('key', v_row.cache_key,
                 'ms', (extract(epoch from clock_timestamp() - v_t0) * 1000)::int);
      v_done := v_done + 1;
    exception when others then
      v_out := v_out || jsonb_build_object('key', v_row.cache_key, 'error', sqlerrm);
    end;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  -- housekeeping: variants nobody asked for stay only as long as the setting
  -- says. Rows only MARKED stale (built_at = -infinity) are kept, so a stale
  -- copy is always servable.
  delete from public.storefront_home_cache
   where built_at > '-infinity'::timestamptz
     and built_at < now() - make_interval(secs => v_evict_s);

  return jsonb_build_object('ok', true, 'warmed', v_out);
end
$fn$;

-- ── the cron_task: one enabled task, generously bounded ───────────────────
update public.cron_task
   set enabled = false
 where name = 'c1895-storefront-home-warm';

insert into public.cron_task (name, ord, mode, work_sql, step_timeout_ms, enabled,
                              base_interval_s, max_interval_s, dml, note)
values ('storefront_home_warm', 120, 'poll', 'select public.storefront_home_warm_tick()',
        180000, true, 120, 600, true,
        'CMD #2207 — keeps every storefront_home_cache key fresh off-request, rebuilding each as the viewer that built it. The RPC never rebuilds inline while a copy exists.')
on conflict (name) do update
   set work_sql = excluded.work_sql,
       step_timeout_ms = excluded.step_timeout_ms,
       enabled = true,
       base_interval_s = excluded.base_interval_s,
       max_interval_s = excluded.max_interval_s,
       dml = true,
       parked_reason = null,
       fail_count = 0,
       last_error = null,
       note = excluded.note;
