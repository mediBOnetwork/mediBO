-- CMD #1927 — RG red after CHANGE #1304: the letter rail was the whole budget.
--
-- rg_runs said c747_catalogue_budget blown (limit 300ms): catalogue_salts 2095ms,
-- catalogue_companies 316ms, plus a 57014 collection timeout on the payload
-- c747_catalogue_salts_top. All three were ONE line: _cat_rail grouped by
-- public._cat_letter(c.label), a per-row function call over 129,680 salt rows,
-- so the rail read the heap and ignored idx_cat_facet_rail_letter entirely
-- (measured on live: _cat_rail('salt',0,null) = 1943ms of the 2105ms RPC,
--  _cat_rail('company',0,null) = 263ms of the 320ms RPC).
--
-- catalogue_facet_count.letter is the SAME value, stored: it is NOT NULL and
-- catalogue_cache_tick writes it as _cat_letter(<label>) for every facet the
-- rail is called with (company / salt / therapeutic / chemical / action — the
-- only callers are catalogue_companies, catalogue_salts, catalogue_tree).
-- Verified on live at write time: 0 rows where letter is distinct from
-- _cat_letter(label), 0 nulls. Grouping the stored column turns the scan into
-- an index-only scan on (facet, zone_id, letter) INCLUDE (parent_key) — the
-- index whose name says it was built for exactly this query — and the same
-- sargable shape catalogue_salts already relies on for its letter range.
-- Measured: 1943ms -> 7.6ms.
--
-- Idempotent: CREATE OR REPLACE only, no DDL on data.

create or replace function public._cat_rail(
  p_facet text,
  p_zone_count smallint,
  p_parent text default null::text
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with have as (
    -- The stored letter, never _cat_letter(label): the column carries the
    -- identical value and lets this stay an index-only scan.
    select c.letter as key, count(*)::bigint as n
      from public.catalogue_facet_count c
     where c.facet = p_facet
       and c.zone_id = coalesce(p_zone_count, 0::smallint)
       and (p_parent is null or c.parent_key = p_parent)
     group by 1
  ),
  track as (
    select l.key,
           case when l.key = '#' then public.uic('catalogue.rail_other','#') else l.key end as label,
           coalesce(h.n, 0) as n
      from (select chr(64 + generate_series(1,26)) as key
            union all select '#') l
      left join have h on h.key = l.key
  )
  select jsonb_build_object(
    'label', public.uic('catalogue.rail_label','Jump to a letter'),
    'all_label', public.uic('catalogue.letter_all','All'),
    'letters', case when not exists (select 1 from have) then '[]'::jsonb
               else coalesce((select jsonb_agg(jsonb_build_object(
                  'key', t.key, 'label', t.label, 'n', t.n, 'enabled', t.n > 0)
                  order by (t.key = '#'), t.key) from track t), '[]'::jsonb) end);
$function$;

-- The index this rewrite depends on. It already exists on live (and is in the rg
-- baseline); IF NOT EXISTS makes the replay a no-op there and guarantees any
-- other database that replays this file gets the index-only scan too, instead of
-- silently falling back to the seq scan this change exists to remove.
create index if not exists idx_cat_facet_rail_letter
  on public.catalogue_facet_count using btree (facet, zone_id, letter) include (parent_key);

-- Make the invariant the rewrite reads TRUE rather than merely observed. Live is
-- already clean (0 of 155,399 rows disagree), so this is a no-op there; a
-- branch/fixture row seeded with a blank letter would otherwise render an
-- all-zero letter track, which is the one way this change could be wrong.
-- Idempotent by construction: the predicate is empty once it has run.
update public.catalogue_facet_count
   set letter = public._cat_letter(label)
 where facet in ('company','salt','therapeutic','chemical','action')
   and letter is distinct from public._cat_letter(label);
