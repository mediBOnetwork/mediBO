-- CMD #1873 — a zone-locked ADMIN could not see today's route at all.
--
-- #1872's _c1872_zone_match compares the app zone's NAME to the route plan's
-- city, exactly: lower(z.name) = lower(pp.city). On live those two spellings
-- do not agree — zones.name is 'Raipur Zone' and route_plans.city is 'Raipur'
-- — so routes_today() returned zero routes for every admin with a zone, and
-- the whole Routes tab (and now the stop check-in on it) was reachable only
-- by a super admin sitting on "All zones". Proven on the live build 471d7873:
-- routes_today() as test.admin -> count 0, as the super identity -> count 1,
-- same route, same date.
--
-- The comparison now drops a trailing ' zone' (and any punctuation/whitespace
-- noise) from BOTH sides before comparing, so 'Raipur Zone' and 'Raipur' are
-- the same place and 'Bengaluru' still is not. Nothing else about the match
-- changes: a NULL zone is still "all zones", and the lead-cluster city is
-- still the second thing tried.
--
-- Idempotent: CREATE OR REPLACE only.

create or replace function public._c1873_place_key(p_text text)
returns text
language sql
immutable
as $function$
  select nullif(
           regexp_replace(
             regexp_replace(lower(btrim(coalesce(p_text, ''))), '\s+zone\s*$', ''),
             '[^a-z0-9]', '', 'g'),
           '');
$function$;

create or replace function public._c1872_zone_match(
  p_zone smallint, p_plan_city text, p_lead_zone bigint)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p_zone is null
      or exists (
           select 1 from zones z
            where z.id = p_zone
              and (public._c1873_place_key(z.name) = public._c1873_place_key(p_plan_city)
                or public._c1873_place_key(z.name) = public._c1873_place_key(
                     (select lz.city from lead_zones lz where lz.id = p_lead_zone))));
$function$;

grant execute on function public._c1873_place_key(text) to authenticated;
grant execute on function public._c1872_zone_match(smallint, text, bigint) to authenticated;
