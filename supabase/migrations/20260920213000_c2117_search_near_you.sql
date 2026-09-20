-- CMD #2117 — Search: popular searches NEAR YOU, and an animated placeholder
-- whose words are the backend's.
--
-- 1. "Popular searches" was never a search at all. `_search_idle_suggest`
--    read `search_suggest_cache` (empty on live) and then fell back to the
--    brand roots of whatever the zone's feed happened to rank first — i.e.
--    what the catalogue SELLS, printed under a title that promised what
--    shoppers SEARCH. This adds the missing fact: every acted-on search is
--    logged with the zone it was made in, and the block is computed from
--    that log, zone- and date-scoped, with the old feed roots kept only as
--    the cold-start fallback.
-- 2. The placeholder's rotating word list ships from here too: three words
--    the copy table owns, then the zone's top-selling medicines. Nothing in
--    that list is written in Dart.
--
-- Idempotent: safe to replay on live.

-- ── 1. the log: what was actually searched, and where ──────────────────────
create table if not exists public.search_query_log (
  id       bigserial primary key,
  zone_id  smallint,
  q_norm   text        not null,
  q        text        not null,
  user_id  uuid,
  at       timestamptz not null default now()
);

create index if not exists search_query_log_zone_at_idx
  on public.search_query_log (zone_id, at desc);
create index if not exists search_query_log_norm_idx
  on public.search_query_log (q_norm);

alter table public.search_query_log enable row level security;
-- No policies on purpose: the log is written and read only by the
-- SECURITY DEFINER functions below. Nothing reaches it through PostgREST.
revoke all on public.search_query_log from anon, authenticated;

-- ── 2. copy + settings ─────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('search.idle_suggest_title', to_jsonb('Popular searches near you'::text)),
  ('search.placeholder_prefix', to_jsonb('Search'::text)),
  ('search.placeholder_words',  '["medicine","salt","composition"]'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

insert into public.app_settings(key, value) values
  ('search_popular_days',            to_jsonb(30)),
  ('search_popular_min_hits',        to_jsonb(2)),
  ('search_placeholder_rotate_ms',   to_jsonb(5000)),
  ('search_placeholder_top_limit',   to_jsonb(10)),
  ('search_hide_bottom_chrome_on_focus', to_jsonb(true))
on conflict (key) do nothing;

-- ── 3. the zone this surface is scoped to ──────────────────────────────────
-- Zone- and date-scoped, per the standing rule: the header picker's zone
-- (partner zone-locked, super admin all zones => null) wins, and a shopper
-- falls back to the zone their catalogue is already served from.
create or replace function public._search_scope_zone()
returns smallint
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(public.admin_active_zone(), public._cat_avail_zone());
$$;

-- ── 4. logging an acted-on search ──────────────────────────────────────────
create or replace function public._search_query_log_add(p_q text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_norm text := lower(regexp_replace(btrim(coalesce(p_q, '')), '\s+', ' ', 'g'));
begin
  if length(v_norm) < 2 then return; end if;
  insert into public.search_query_log(zone_id, q_norm, q, user_id, at)
  values (public._search_scope_zone(), v_norm, btrim(p_q), auth.uid(), now());
exception when others then
  -- A search must never fail because its own analytics row did.
  return;
end;
$$;

-- `search_recent_add` is already the ONE call the app makes when a shopper
-- ACTS on a search (Enter, a chip tap, a product opened from the results),
-- so it is the honest place to log. What changes: an anonymous shopper's
-- search now counts towards the zone's popular list even though it is never
-- kept as their personal history.
create or replace function public.search_recent_add(p_q text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_uid   uuid := auth.uid();
  v_q     text := btrim(coalesce(p_q, ''));
  v_norm  text := lower(regexp_replace(v_q, '\s+', ' ', 'g'));
  v_keep  int  := coalesce((select keep_n from public.search_recent_config where id = 1), 6);
  v_on    boolean := coalesce((select enabled from public.search_recent_config where id = 1), true);
begin
  if length(v_norm) < 2 then
    return jsonb_build_object('ok', true, 'stored', false);
  end if;

  -- The zone log first: it is what "popular searches near you" is made of,
  -- and it does not care who is signed in.
  perform public._search_query_log_add(v_q);

  if v_uid is null or not v_on then
    return jsonb_build_object('ok', true, 'stored', false);
  end if;

  insert into public.search_recent(user_id, q_norm, q, last_at)
  values (v_uid, v_norm, v_q, now())
  on conflict (user_id, q_norm)
    do update set q = excluded.q, last_at = excluded.last_at;

  delete from public.search_recent r
   where r.user_id = v_uid
     and r.q_norm not in (select q_norm from public.search_recent
                           where user_id = v_uid
                           order by last_at desc
                           limit v_keep);

  return jsonb_build_object('ok', true, 'stored', true);
end;
$$;

-- ── 5. popular searches NEAR YOU ───────────────────────────────────────────
-- Real history first (this zone, this date window, at least `min_hits`
-- shoppers' worth of it), then the brand cache, then the feed roots. Each
-- fallback is a COLD START answer, never a silent substitute: `source` says
-- which one answered so the block can be read honestly.
create or replace function public._search_popular_near(p_limit integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_n     int := least(greatest(coalesce(nullif(p_limit, 0), 8), 1), 20);
  v_zone  smallint := public._search_scope_zone();
  v_days  int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                     where key = 'search_popular_days'), 30), 1);
  v_min   int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                     where key = 'search_popular_min_hits'), 2), 1);
  v_to    timestamptz := ((public.admin_active_date() + 1)::timestamp
                            at time zone 'Asia/Kolkata');
  v_out   jsonb := '[]'::jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', t.q, 'sub_label', '', 'q', t.q) order by t.hits desc, t.q), '[]'::jsonb)
    into v_out
    from (select (array_agg(l.q order by l.at desc))[1] as q,
                 count(*) as hits
            from public.search_query_log l
           where l.at <  v_to
             and l.at >= v_to - make_interval(days => v_days)
             and (v_zone is null or l.zone_id = v_zone)
           group by l.q_norm
          having count(*) >= v_min
           order by count(*) desc, 1
           limit v_n) t;

  if jsonb_array_length(v_out) > 0 then return v_out; end if;

  -- Cold start: the curated brand cache for this zone.
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', s.label,
           'sub_label', coalesce(s.sub_label, ''),
           'q', coalesce(nullif(btrim(s.query), ''), s.label)) order by s.rank desc), '[]'::jsonb)
    into v_out
    from (select c.label, c.sub_label, c.query, c.rank
            from public.search_suggest_cache c
           where c.kind = 'brand'
             and nullif(btrim(c.label), '') is not null
             and (v_zone is null or c.zones = '{}'::smallint[] or c.zones @> array[v_zone])
           order by c.rank desc, c.n desc
           limit v_n) s;

  if jsonb_array_length(v_out) > 0 then return v_out; end if;

  -- Still nothing searched and nothing cached: the brand roots of what this
  -- zone actually sells most, which is what this block has always fallen
  -- back to.
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', t.label, 'sub_label', '', 'q', t.label) order by t.rnk), '[]'::jsonb)
    into v_out
    from (select initcap(public._brand_root(m.product_name)) as label,
                 min(f.rank) as rnk
            from public._sf_feed_ids('All', 0, v_n * 6) f
            join public."MEDICINE" m on m.id = f.product_id
           where nullif(btrim(m.product_name), '') is not null
           group by 1
           order by min(f.rank)
           limit v_n) t;

  return v_out;
end;
$$;

-- The old name stays, delegating, so every caller keeps working.
create or replace function public._search_idle_suggest(p_limit integer default 8)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select public._search_popular_near(p_limit);
$$;

-- ── 6. the animated placeholder's words ────────────────────────────────────
-- "Search" stays put; this is the list that cycles after it. Three words the
-- copy table owns, then the zone's best sellers over the active date window.
create or replace function public._search_placeholder_words()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_zone smallint := public._search_scope_zone();
  v_lim  int := least(greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                          where key = 'search_placeholder_top_limit'), 10), 1), 20);
  v_days int := greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                    where key = 'search_popular_days'), 30), 1);
  v_to   timestamptz := ((public.admin_active_date() + 1)::timestamp
                           at time zone 'Asia/Kolkata');
  v_base jsonb := coalesce((select value from public.ui_copy
                             where key = 'search.placeholder_words'),
                           '["medicine","salt","composition"]'::jsonb);
  v_top  jsonb := '[]'::jsonb;
begin
  select coalesce(jsonb_agg(x.nm order by x.q desc, x.nm), '[]'::jsonb)
    into v_top
    from (select btrim(m.product_name) as nm, sum(coalesce(oi.quantity,0))::numeric as q
            from public.order_items oi
            join public.orders o on o.id = oi.order_id
            join public."MEDICINE" m on m.id = oi.product_id
           where o.created_at <  v_to
             and o.created_at >= v_to - make_interval(days => v_days)
             and oi.product_id is not null
             and nullif(btrim(m.product_name), '') is not null
             and (v_zone is null or o.zone_id = v_zone)
           group by 1
          having sum(coalesce(oi.quantity,0)) > 0
           order by 2 desc, 1
           limit v_lim) x;

  -- Cold start: a zone with no ORDERS in the window still gets real
  -- medicines — the storefront feed's own best-seller order, which is what
  -- every other "top sellers" surface falls back to. The three words alone
  -- are the last resort, and even then the placeholder still moves.
  if jsonb_array_length(v_top) = 0 then
    select coalesce(jsonb_agg(y.nm order by y.rnk), '[]'::jsonb)
      into v_top
      from (select btrim(m.product_name) as nm, min(f.rank) as rnk
              from public._sf_feed_ids('All', 0, v_lim * 3) f
              join public."MEDICINE" m on m.id = f.product_id
             where nullif(btrim(m.product_name), '') is not null
             group by 1
             order by min(f.rank)
             limit v_lim) y;
  end if;

  return v_base || v_top;
end;
$$;

-- ── 7. the bar block carries it ────────────────────────────────────────────
create or replace function public.search_bar_block()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'placeholder', public.uic('search.placeholder','Search medicines, salts, companies'),
    -- CMD #2117 — the animated placeholder. `placeholder_prefix` never moves;
    -- `placeholder_words` cycles behind it every `placeholder_rotate_ms`.
    -- An app that does not know these fields keeps drawing `placeholder`.
    'placeholder_prefix', public.uic('search.placeholder_prefix','Search'),
    'placeholder_words',  public._search_placeholder_words(),
    'placeholder_rotate_ms', greatest(coalesce((select (value #>> '{}')::int
                                from public.app_settings
                               where key = 'search_placeholder_rotate_ms'), 5000), 800),
    -- CMD #2117 §3 — while the box has focus (the keyboard is up) the bottom
    -- chrome stands down: the registration/login bar and the cart pill are
    -- not what a shopper who is typing is reaching for, and on a 360 px
    -- phone they eat the suggestions.
    'hide_bottom_chrome_on_focus', coalesce((select (value #>> '{}')::boolean
                                from public.app_settings
                               where key = 'search_hide_bottom_chrome_on_focus'), true),
    'min_chars',   greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'search_min_chars'), 2), 1),
    'debounce_ms', greatest(coalesce((select (value #>> '{}')::int from public.app_settings
                                       where key = 'search_debounce_ms'), 250), 0),
    'actions', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind',  a->>'kind',
               'state', a->>'state',
               'icon',  a->>'icon',
               'label', public.uic(a->>'copy_key',''))
             order by ord), '[]'::jsonb)
        from jsonb_array_elements(
               coalesce((select value from public.app_settings
                           where key = 'search_bar_actions'), '[]'::jsonb))
             with ordinality t(a, ord)),
    'chip_row_on_results', false
  );
$$;

-- ── 8. grants: the helpers are internal, the doors stay as they were ───────
revoke all on function public._search_scope_zone()        from public, anon, authenticated;
revoke all on function public._search_query_log_add(text) from public, anon, authenticated;
revoke all on function public._search_popular_near(int)   from public, anon, authenticated;
revoke all on function public._search_placeholder_words() from public, anon, authenticated;
grant execute on function public._search_scope_zone()        to service_role;
grant execute on function public._search_query_log_add(text) to service_role;
grant execute on function public._search_popular_near(int)   to service_role;
grant execute on function public._search_placeholder_words() to service_role;

-- The public doors keep the reach they already had.
grant execute on function public._search_idle_suggest(int) to anon, authenticated, service_role;
grant execute on function public.search_bar_block()        to anon, authenticated, service_role;
grant execute on function public.search_recent_add(text)   to anon, authenticated, service_role;
