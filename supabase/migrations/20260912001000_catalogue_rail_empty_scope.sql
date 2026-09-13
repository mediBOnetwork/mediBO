-- CMD #1908 (follow-up) — an A–Z index over NOTHING is furniture.
--
-- A leaf class ("Catalogue › Category › ANTI INFECTIVES › CEPHALOSPORINS") has
-- no children, so the strip drew 27 greyed-out letters nobody can tap. The
-- frontend already hides a rail with no letters; the backend simply has to stop
-- sending one for a scope with no rows behind any letter.
--
-- This is a SECOND file on purpose. scripts/migration_replay.sh ledgers by FILE
-- name: 20260912000000_catalogue_nav_trail_rail.sql had already been replayed on
-- live, so editing it in place changed nothing on production. A follow-up schema
-- change always needs a new file with a later version prefix.
create or replace function public._cat_rail(
  p_facet text,
  p_zone_count smallint,
  p_parent text default null
) returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with have as (
    select public._cat_letter(c.label) as key, count(*)::bigint as n
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
$$;

grant execute on function public._cat_rail(text, smallint, text) to anon, authenticated, service_role;
