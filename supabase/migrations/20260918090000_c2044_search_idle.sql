-- CMD #2044 — the focused search box stops answering with a blank screen.
--
-- Om: "on tapping search, the screen below goes blank — no Top sellers rail,
-- no suggestions, no history — until the user types." The rail from CMD #2010
-- existed but it lived UNDER the box inside the header, so on a phone with the
-- keyboard up it was the only thing the shopper could have seen and the page
-- behind it was the home feed pushed off screen.
--
-- The focused-and-empty state is now ONE payload and it fills the page:
-- `search_idle()` returns an ordered list of BLOCKS, each with its own kind,
-- its own title and its own rows. Flutter renders whichever blocks arrive, in
-- the order they arrive, and draws nothing for a block it does not know — so a
-- fourth block later is an INSERT here, never a deploy.
--
--   recent   — this shopper's own last searches (search_recent, keep_n rows)
--   suggest  — what the catalogue offers: the popular-brand cache when it is
--              built, else the brand roots of this zone's own top sellers
--   rail     — search_idle_rail() verbatim: last ordered, else top sellers
--
-- Every word is `uic()` copy, seeded below, so the wording is an UPDATE.

begin;

-- ── 1. the shopper's own history ───────────────────────────────────────────
-- The table and its keep_n config have existed (unused) since the search
-- rebuild; this is the first thing that writes to and reads from them.
alter table public.search_recent enable row level security;

-- Recording is an explicit call, not a side effect of every keystroke: the
-- box searches as you type, and storing four rows for "mont" would make the
-- history a log of typing rather than a list of searches. The client calls
-- this when a search is ACTED on (Enter, or a product opened from results).
create or replace function public.search_recent_add(p_q text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $fn$
declare
  v_uid   uuid := auth.uid();
  v_q     text := btrim(coalesce(p_q, ''));
  v_norm  text := lower(regexp_replace(v_q, '\s+', ' ', 'g'));
  v_keep  int  := coalesce((select keep_n from public.search_recent_config where id = 1), 6);
  v_on    boolean := coalesce((select enabled from public.search_recent_config where id = 1), true);
begin
  if v_uid is null or not v_on or length(v_norm) < 2 then
    return jsonb_build_object('ok', true, 'stored', false);
  end if;

  insert into public.search_recent(user_id, q_norm, q, last_at)
  values (v_uid, v_norm, v_q, now())
  on conflict (user_id, q_norm)
    do update set q = excluded.q, last_at = excluded.last_at;

  -- keep_n is the whole retention rule, and it is one UPDATE away.
  delete from public.search_recent r
   where r.user_id = v_uid
     and r.q_norm not in (select q_norm from public.search_recent
                           where user_id = v_uid
                           order by last_at desc
                           limit v_keep);

  return jsonb_build_object('ok', true, 'stored', true);
end
$fn$;

create or replace function public.search_recent_clear()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $fn$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('ok', true, 'cleared', 0); end if;
  delete from public.search_recent where user_id = v_uid;
  return jsonb_build_object('ok', true, 'cleared', 1,
    'toast', public.uic('search.recent_cleared', 'Recent searches cleared'));
end
$fn$;

-- ── 2. the suggestions ─────────────────────────────────────────────────────
-- The popular-brand cache is the real source on a built catalogue. Where it
-- has not been built (a fresh branch, a new zone) the same question is asked
-- of the zone's own top-selling feed, so the block is never empty for a
-- reason the shopper cannot see.
create or replace function public._search_idle_suggest(p_limit integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_n    int := least(greatest(coalesce(nullif(p_limit, 0), 8), 1), 20);
  v_zone smallint := public._viewer_zone_or_null();
  v_out  jsonb := '[]'::jsonb;
begin
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

  -- Fallback: the brand roots of what this zone actually sells most.
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
end
$fn$;

-- ── 3. the one payload the focused box renders ─────────────────────────────
create or replace function public.search_idle()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_uid     uuid := auth.uid();
  v_blocks  jsonb := '[]'::jsonb;
  v_recent  jsonb := '[]'::jsonb;
  v_sugg    jsonb := '[]'::jsonb;
  v_rail    jsonb;
begin
  if v_uid is not null
     and coalesce((select enabled from public.search_recent_config where id = 1), true) then
    select coalesce(jsonb_agg(jsonb_build_object('label', r.q, 'sub_label', '', 'q', r.q)
                              order by r.last_at desc), '[]'::jsonb)
      into v_recent
      from (select q, last_at from public.search_recent
             where user_id = v_uid
             order by last_at desc
             limit coalesce((select keep_n from public.search_recent_config where id = 1), 6)) r;
  end if;

  if jsonb_array_length(v_recent) > 0 then
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'kind',  'recent',
      'title', public.uic('search.idle_recent_title', 'Recent searches'),
      'action_label', public.uic('search.idle_recent_clear', 'Clear'),
      'action_kind',  'clear_recent',
      'chips', v_recent));
  end if;

  v_sugg := public._search_idle_suggest(
    coalesce((select (value #>> '{}')::int from public.app_settings
               where key = 'search_idle_suggest_limit'), 8));
  if jsonb_array_length(v_sugg) > 0 then
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'kind',  'suggest',
      'title', public.uic('search.idle_suggest_title', 'Popular searches'),
      'action_label', '', 'action_kind', '',
      'chips', v_sugg));
  end if;

  v_rail := public.search_idle_rail();
  if coalesce((v_rail ->> 'has')::boolean, false) then
    v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
      'kind',  'rail',
      'title', v_rail ->> 'title',
      'action_label', '', 'action_kind', '',
      'items', coalesce(v_rail -> 'items', '[]'::jsonb)));
  end if;

  return jsonb_build_object(
    'ok', true,
    'has', jsonb_array_length(v_blocks) > 0,
    'blocks', v_blocks,
    -- The one line the surface prints when a signed-out viewer has nothing:
    -- never a blank page, and never a sentence Flutter invented.
    'empty_label', public.uic('search.idle_empty',
                              'Type a medicine, salt or company name to search.'));
end
$fn$;

-- ── 4. the copy, so every word above is an UPDATE ──────────────────────────
insert into public.ui_copy(key, value) values
  ('search.idle_recent_title',  to_jsonb('Recent searches'::text)),
  ('search.idle_recent_clear',  to_jsonb('Clear'::text)),
  ('search.idle_suggest_title', to_jsonb('Popular searches'::text)),
  ('search.recent_cleared',     to_jsonb('Recent searches cleared'::text)),
  ('search.idle_empty',         to_jsonb('Type a medicine, salt or company name to search.'::text))
on conflict (key) do nothing;

insert into public.app_settings(key, value)
values ('search_idle_suggest_limit', to_jsonb(8))
on conflict (key) do nothing;

-- ── 5. grants — the storefront is public, the history is not ───────────────
revoke all on function public.search_idle() from public;
revoke all on function public._search_idle_suggest(integer) from public;
revoke all on function public.search_recent_add(text) from public;
revoke all on function public.search_recent_clear() from public;

grant execute on function public.search_idle() to anon, authenticated, service_role;
grant execute on function public._search_idle_suggest(integer) to anon, authenticated, service_role;
-- Writing history needs an identity: anon has no auth.uid() and is not granted.
grant execute on function public.search_recent_add(text) to authenticated, service_role;
grant execute on function public.search_recent_clear() to authenticated, service_role;

commit;
