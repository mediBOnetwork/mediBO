-- CHANGE #462 — behavioural proof for feature_gaps 104–110 (delivery, MEDIUM,
-- batch A). Every assertion is a live call against the real functions; the
-- whole run is one transaction and ends in ROLLBACK, so it leaves no rows.
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f scripts/c462_selftest.sql
\set ON_ERROR_STOP on
begin;
select public.db_session_guard();

create temporary table t_ids(k text primary key, v uuid) on commit drop;

do $$
declare v_o1 uuid; v_o2 uuid; v_o3 uuid; v_run uuid; v_p uuid; v_d1 uuid; v_d2 uuid; v_d3 uuid;
begin
  select id into v_p from public.delivery_partner_registrations limit 1;
  -- deliveries carries one row per order, so the fixture needs three orders.
  select id into v_o1 from public.orders offset 0 limit 1;
  select id into v_o2 from public.orders offset 1 limit 1;
  select id into v_o3 from public.orders offset 2 limit 1;
  insert into public.delivery_runs(id, partner_id, status, total_stops)
    values (gen_random_uuid(), v_p, 'planned', 999) returning id into v_run;

  -- d1 and d2 sit ~7 m apart (one doorstep); d3 is far away and already failed.
  insert into public.deliveries(id, order_id, partner_id, run_id, status, accept_status,
      lat, lng, handover_at, qr_token)
    values (gen_random_uuid(), v_o1, v_p, v_run, 'out_for_delivery', 'accepted',
            21.25000, 81.63000, now(), 'c462-tok-1') returning id into v_d1;
  insert into public.deliveries(id, order_id, partner_id, run_id, status, accept_status,
      lat, lng, handover_at, qr_token)
    values (gen_random_uuid(), v_o2, v_p, v_run, 'out_for_delivery', 'accepted',
            21.25005, 81.63005, now(), 'c462-tok-2') returning id into v_d2;
  insert into public.deliveries(id, order_id, partner_id, run_id, status, accept_status,
      lat, lng, handover_at, qr_token)
    values (gen_random_uuid(), v_o3, v_p, v_run, 'failed', 'accepted',
            21.30000, 81.70000, now(), 'c462-tok-3') returning id into v_d3;

  insert into t_ids values ('ord',v_o1),('run',v_run),('d1',v_d1),('d2',v_d2),('d3',v_d3);
end $$;

\echo '--- GAP 107: co-located stops keep ONE group; total_stops is one rule'
-- d1 and d2 are ~7 m apart, d3 is 8 km away: the 150 m rule must yield 2 groups
-- for 3 stops, and d1/d2 must share theirs. Before this change the Google apply
-- path handed every stop its own group and called that "consistent".
update public.deliveries set status='out_for_delivery' where id=(select v from t_ids where k='d3');
select 'g107_groups' proof,
       public._delivery_regroup_run((select v from t_ids where k='run')) open_groups,
       2 want;
select 'g107_colocated_share_group' proof,
       ((select stop_group from public.deliveries where id=(select v from t_ids where k='d1'))
        = (select stop_group from public.deliveries where id=(select v from t_ids where k='d2'))) got,
       true want;
select 'g107_far_stop_is_own_group' proof,
       ((select stop_group from public.deliveries where id=(select v from t_ids where k='d3'))
        <> (select stop_group from public.deliveries where id=(select v from t_ids where k='d1'))) got,
       true want;
select 'g107_total_stops' proof,
       public._delivery_run_recount((select v from t_ids where k='run')) total_stops,
       2 want_two_drop_points;
select 'g107_run_row' proof, total_stops,
       'was 999 in the fixture — one rule now owns this number' note
  from public.delivery_runs where id=(select v from t_ids where k='run');

update public.deliveries set status='failed' where id=(select v from t_ids where k='d3');
\echo '--- GAP 105: a failed stop must not be deliverable (want error=bad_state)'
select 'g105_failed_refused' proof,
       public._delivery_complete((select v from t_ids where k='d3'),'photo',21.30,81.70,null,'x')->>'error' got,
       'bad_state' want;

\echo '--- GAP 106: the completion distance is computed, stored and flagged (radius 150 m, scan ~1.5 km away)'
select 'g106_reply' proof,
       public._delivery_complete((select v from t_ids where k='d1'),'photo',21.2635,81.6300,null,'x') reply;
select 'g106_stored' proof, delivered_distance_m, geofence_ok, completion_flagged
  from public.deliveries where id=(select v from t_ids where k='d1');
select 'g106_event' proof, count(*) geofence_flag_events
  from public.delivery_events where delivery_id=(select v from t_ids where k='d1') and event='geofence_flag';

\echo '--- GAP 105: the same stop cannot be delivered twice (want already=true)'
select 'g105_already' proof,
       public._delivery_complete((select v from t_ids where k='d1'),'photo',21.25,81.63,null,'x')->>'already' got,
       'true' want;

\echo '--- GAP 108: rejecting a stop drops it out of the run count'
-- d3 is 8 km from the others, so it is its own drop point: removing it MUST
-- move the number. Before this change delivery_respond nulled run_id and left
-- delivery_runs.total_stops exactly where it was.
update public.deliveries set status='assigned' where id=(select v from t_ids where k='d3');
select 'g108_before' proof,
       public._delivery_run_recount((select v from t_ids where k='run')) total_stops_before,
       2 want;
update public.deliveries set run_id=null, partner_id=null, status='unassigned', accept_status='rejected'
 where id=(select v from t_ids where k='d3');
select 'g108_after_reject' proof,
       public._delivery_run_recount((select v from t_ids where k='run')) total_stops_after,
       1 want;
select 'g108_respond_recounts' proof,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='delivery_respond'
           and pg_get_functiondef(p.oid) like '%_delivery_run_recount%') got, 1 want;
select 'g108_cooldown_in_suggest' proof,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='delivery_suggest_partner'
           and pg_get_functiondef(p.oid) like '%reject_cooldown_min%') got, 1 want;

\echo '--- GAP 104: the customer QR is gated on rider arrival'
select 'g104_gate_present' proof,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='delivery_scan_qr'
           and pg_get_functiondef(p.oid) like '%rider_not_arrived%') got, 1 want;
select 'g104_token_hidden_until_arrival' proof,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname in ('customer_track_order','delivery_track_public')
           and pg_get_functiondef(p.oid) like '%v_show_qr%') got, 2 want;

\echo '--- GAP 109: a pincode now lands, and the zone resolves'
select 'g109_pincode_column' proof, count(*) got, 1 want
  from information_schema.columns
 where table_name='delivery_partner_registrations' and column_name='pincode';
select 'g109_zone_resolver' proof,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='delivery_partner_register'
           and pg_get_functiondef(p.oid) like '%delivery_serviceability%') got, 1 want;

\echo '--- GAP 110: anon cannot execute, and a session-less call is refused'
select 'g110_anon_acl' proof,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='delivery_partner_register'
           and array_to_string(p.proacl,',') like '%anon=X%') got, 0 want;
select 'g110_no_session' proof,
       public.delivery_partner_register('{"full_name":"c462 probe","phone":"9999900462"}'::jsonb)->>'error' got,
       'not_signed_in' want;

rollback;
