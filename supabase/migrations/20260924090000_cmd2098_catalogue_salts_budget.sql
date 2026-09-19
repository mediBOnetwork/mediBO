-- CMD #2098 — the regression guard is red on c747_catalogue_budget.
--
-- WHY THIS FILE EXISTS TWICE OVER: #2097 diagnosed the same failure and wrote
-- the right fix, but that command completed with web_deploy_no NULL, so its
-- migration file never reached the merge lane and was never replayed on live
-- (migration_replay_ledger has no row for it). Live still runs the old
-- catalogue_salts, the guard has been red for five consecutive runs, and the
-- measured cost on production data is 328-536 ms against a 300 ms budget.
-- The rewritten body, run inline against production, measures 70-74 ms.
--
-- Both of #2097's fixes are re-issued here, unchanged in behaviour, so that
-- ONE deploy number carries them to live. Everything is CREATE OR REPLACE and
-- re-runnable.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. catalogue_salts — page through ONE index per group, not the whole zone
--
-- The old page ordered by `case when <no letter picked> then null else label
-- end, n desc, facet_key`. No index can serve a CASE, so a 40-row page read
-- every salt row in the zone (107,619) and top-N sorted them: 301 ms of the
-- 545 ms that blew the c747 budget. Companies (18,563 rows) survived on size
-- alone. Each group now orders and caps itself — biggest-first straight off
-- (facet, zone_id, n DESC, facet_key) when no letter is picked, A→Z inside
-- the letter when one is — and only those few rows are merged and paged.
-- The payload is unchanged, field for field.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.catalogue_salts(
  p_letter text default null::text,
  p_q text default null::text,
  p_offset integer default 0,
  p_limit integer default 40,
  p_zone boolean default true)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with z as (select public._cat_count_zone(p_zone) as cz),
  az as (select public._cat_avail_zone() as az),
  lim as (select least(greatest(coalesce(p_limit,40),1),100) as n,
                 greatest(coalesce(p_offset,0),0) as off),
  lt as (select nullif(upper(btrim(coalesce(p_letter,''))),'') as l),
  qq as (select nullif(btrim(coalesce(p_q,'')),'') as q),
  -- in zone, no letter picked — index-ordered, capped
  p0n as (
    select c.facet_key, c.label, c.n, c.letter, 0::smallint as grp
      from public.catalogue_facet_count c
     where (select l from lt) is null
       and c.facet = 'salt'
       and c.zone_id = coalesce((select az from az), (select cz from z))
       and ((select q from qq) is null
            or lower(c.label) like '%' || lower((select q from qq)) || '%')
     order by c.n desc, c.facet_key
     limit (select off from lim) + (select n from lim) + 1
  ),
  -- in zone, a letter is picked — A→Z inside that one letter
  p0l as (
    select c.facet_key, c.label, c.n, c.letter, 0::smallint as grp
      from public.catalogue_facet_count c
     where (select l from lt) is not null
       and c.facet = 'salt'
       and c.zone_id = coalesce((select az from az), (select cz from z))
       and c.letter = (select l from lt)
       and ((select q from qq) is null
            or lower(c.label) like '%' || lower((select q from qq)) || '%')
     order by c.label, c.n desc, c.facet_key
     limit (select off from lim) + (select n from lim) + 1
  ),
  -- out of zone (only when the zone has availability counts of its own)
  p1n as (
    select c.facet_key, c.label, c.n, c.letter, 1::smallint as grp
      from public.catalogue_facet_count c
     where (select az from az) is not null
       and (select l from lt) is null
       and c.facet = 'salt' and c.zone_id = (select cz from z)
       and not exists (select 1 from public.catalogue_facet_count a
                        where a.facet = 'salt' and a.facet_key = c.facet_key
                          and a.zone_id = (select az from az))
       and ((select q from qq) is null
            or lower(c.label) like '%' || lower((select q from qq)) || '%')
     order by c.n desc, c.facet_key
     limit (select off from lim) + (select n from lim) + 1
  ),
  p1l as (
    select c.facet_key, c.label, c.n, c.letter, 1::smallint as grp
      from public.catalogue_facet_count c
     where (select az from az) is not null
       and (select l from lt) is not null
       and c.facet = 'salt' and c.zone_id = (select cz from z)
       and c.letter = (select l from lt)
       and not exists (select 1 from public.catalogue_facet_count a
                        where a.facet = 'salt' and a.facet_key = c.facet_key
                          and a.zone_id = (select az from az))
       and ((select q from qq) is null
            or lower(c.label) like '%' || lower((select q from qq)) || '%')
     order by c.label, c.n desc, c.facet_key
     limit (select off from lim) + (select n from lim) + 1
  ),
  -- Whole-group totals, for the count line and the group headings. Referenced
  -- only when a search/letter narrows the count or when the zone split is on,
  -- so the default page never pays for them.
  grp_n as (
    select 0::smallint as grp,
           (select count(*) from public.catalogue_facet_count c
             where c.facet = 'salt'
               and c.zone_id = coalesce((select az from az), (select cz from z))
               and ((select l from lt) is null or c.letter = (select l from lt))
               and ((select q from qq) is null
                    or lower(c.label) like '%' || lower((select q from qq)) || '%')) as n
    union all
    select 1::smallint,
           (select count(*) from public.catalogue_facet_count c
             where (select az from az) is not null
               and c.facet = 'salt' and c.zone_id = (select cz from z)
               and ((select l from lt) is null or c.letter = (select l from lt))
               and not exists (select 1 from public.catalogue_facet_count a
                                where a.facet = 'salt' and a.facet_key = c.facet_key
                                  and a.zone_id = (select az from az))
               and ((select q from qq) is null
                    or lower(c.label) like '%' || lower((select q from qq)) || '%'))
  ),
  -- The zone group always comes first; biggest first is the salt list's own
  -- order, a picked letter reads A→Z.
  page as (
    select u.* from (
      select * from p0n union all select * from p0l
      union all
      select * from p1n union all select * from p1l) u
     order by u.grp,
              case when (select l from lt) is null then null else u.label end nulls last,
              u.n desc, u.facet_key
     offset (select off from lim) limit (select n from lim) + 1
  ),
  shown as (select p.*, row_number() over (
                     partition by p.grp
                     order by case when (select l from lt) is null then null else p.label end nulls last,
                              p.n desc, p.facet_key) as rn
              from (select * from page
                     order by grp,
                              case when (select l from lt) is null then null else label end nulls last,
                              n desc, facet_key
                     limit (select n from lim)) p)
  select jsonb_build_object(
    'ok', true,
    'title', public.uic('catalogue.salts_title','Salts'),
    'zone', public.catalogue_zone_switch(p_zone),
    'letter', nullif(upper(btrim(coalesce(p_letter,''))),''),
    'q', nullif(btrim(coalesce(p_q,'')),''),
    'all_label', public.uic('catalogue.letter_all','All'),
    'trail', public.catalogue_trail('salts', '{}'::text[], null, null, null),
    'rail', public._cat_rail('salt', (select cz from z), null),
    'search_hint', public.uic('catalogue.salt_search_hint','Search a salt, e.g. Paracetamol'),
    'lead_label', public.uic('catalogue.salts_lead','Biggest salts first — search to narrow.'),
    'empty_label', public.uic('catalogue.salts_empty','No salt matches this search.'),
    'count_label', to_char(case when nullif(btrim(coalesce(p_q,'')),'') is null
                                 and (select l from lt) is null
                                then public._cat_meta(public._cat_tile_zone(), 'salts')
                                else coalesce((select n from grp_n where grp = 0), 0) end,
                           'FM9,99,99,999') || ' '
                   || public.uic('catalogue.salts_word','salts'),
    'offset', (select off from lim),
    'next_offset', (select off from lim) + (select count(*) from shown),
    'has_more', (select count(*) from page) > (select n from lim),
    'more_label', public.uic('catalogue.load_more','Load more'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
              'key', s.facet_key, 'label', s.label, 'n', s.n, 'letter', s.letter,
              'count_label', public.cat_count_label(s.n),
              'group', s.grp,
              'group_label', case when s.rn = 1 and (select az from az) is not null
                                  then public.cat_group_label(
                                         case when s.grp = 0 then 'in' else 'out' end,
                                         (select g.n from grp_n g where g.grp = s.grp))
                                  else '' end)
              order by s.grp,
                       case when (select l from lt) is null then null else s.label end nulls last,
                       s.n desc, s.facet_key)
              from shown s), '[]'::jsonb));
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. delivery_run_map — decide authorisation before any row is read
--
-- The refusal used to depend on the run being VISIBLE: the function reads
-- through the `mode` overlay (search_path mode, public), which hides every
-- delivery run from a session carrying no claims at all, so an anonymous
-- caller fell past the guard and got ok:true / has_run:false while a
-- signed-in stranger got not_authorized. Authorisation now comes first, from
-- _delivery_run_owned() (which reads the real table), so who is asking
-- decides the answer and the overlay only decides what is read. The owner
-- and admin paths are untouched; the p_run_id-less path is untouched.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.delivery_run_map(p_run_id uuid default null::uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'mode', 'public'
as $function$
declare
  v_run delivery_runs%rowtype; v_partner uuid; v_loc delivery_partner_locations%rowtype;
  v_pts jsonb; v_wave jsonb; v_wave_id uuid;
begin
  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and is_active and coalesce(is_deleted,false)=false limit 1;

  -- CMD #2097: a named run is authorised on the real table BEFORE it is read
  -- through the mode overlay. Every stop (pharmacy, lat/lng, status) and the
  -- rider's live origin hang off this call, so the refusal must not depend on
  -- whether the overlay happened to show the row.
  if p_run_id is not null and not public._delivery_run_owned(p_run_id) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  -- The default run is picked by scope_date(), NOT by now() — the flow scope
  -- contract (stage 15, "Runs") requires it, and for a rider (who is not an
  -- admin) scope_date() returns today anyway.
  if p_run_id is not null then
    select * into v_run from delivery_runs where id = p_run_id;
  else
    select * into v_run from delivery_runs
     where partner_id = v_partner
       and run_date = public.scope_date(null::date)
     order by created_at desc limit 1;
  end if;
  if v_run.id is null then return jsonb_build_object('ok',true,'has_run',false); end if;

  if not (v_partner is not null and v_run.partner_id = v_partner)
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select * into v_loc from delivery_partner_locations where partner_id = v_run.partner_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'delivery_id', d.id, 'seq', d.seq, 'lat', d.lat, 'lng', d.lng,
           'label', coalesce(o.pharmacy_name,''),
           'status', d.status,
           'pin_color', case d.status when 'delivered' then '#1B7A43'
                                      when 'failed' then '#B42318'
                                      when 'rto' then '#B42318' else '#F59E0B' end,
           'wave_reason', s.reason,
           -- The pin's tooltip, composed HERE so the run map can show WHY this
           -- rider has this stop without the panel concatenating anything.
           'map_title', coalesce(o.pharmacy_name,'') ||
             case when coalesce(s.reason,'') = '' then ''
                  else ' — ' || s.reason end,
           'leg_km', d.leg_km, 'cum_km', d.cum_km, 'eta_min', d.eta_min,
           -- CHANGE #702: the admin run map shows the SAME window the
           -- customer is reading, and says when a stop is predicted to
           -- miss its promise — both from the one block that words it.
           'eta', public._delivery_eta_block(d.id))
         order by d.seq nulls last), '[]'::jsonb)
    into v_pts
  from deliveries d
  join orders o on o.id = d.order_id
  left join delivery_wave_stop s on s.delivery_id = d.id
  where d.run_id = v_run.id and d.status not in ('cancelled')
    and d.lat is not null and d.lng is not null;

  select d.wave_id into v_wave_id from deliveries d
   where d.run_id = v_run.id and d.wave_id is not null limit 1;

  if v_wave_id is not null then
    select jsonb_build_object(
             'heading','Why these stops',
             'label', w.window_label || ' • ' || to_char(w.wave_date,'DD Mon'),
             'mode_label', case w.mode when 'auto' then 'Assigned automatically'
                                       when 'suggest' then 'Planned by the engine, approved by an admin'
                                       else 'Assigned by an admin' end,
             'decisions', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'label', x.reason,
                        'at_label', to_char(x.created_at at time zone 'Asia/Kolkata','HH24:MI'))
                      order by x.created_at desc)
                 from (select * from delivery_wave_decision
                        where wave_id = w.id order by created_at desc limit 12) x), '[]'::jsonb))
      into v_wave from delivery_wave w where w.id = v_wave_id;
  end if;

  return jsonb_build_object(
    'ok', true, 'has_run', true, 'run_id', v_run.id,
    'run_status', v_run.status,
    'google_optimized', v_run.google_optimized,
    'road_polyline', v_run.road_polyline,
    'total_km', v_run.total_km, 'total_min', v_run.total_min,
    'total_label', case when v_run.total_km is null then null
                        else v_run.total_km::text || ' km' ||
                             coalesce(' • ' || v_run.total_min::text || ' min','') end,
    'origin_lat', v_loc.lat, 'origin_lng', v_loc.lng,
    'wave', v_wave,
    'waypoints', v_pts);
end $function$;
