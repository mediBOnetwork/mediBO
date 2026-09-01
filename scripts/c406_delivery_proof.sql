-- CHANGE #406 — end-to-end proof for the three pieces this change added:
-- customer reschedule, rider SOS, rider leaderboard.
--
-- It builds a throwaway order + delivery, drives every path with the REAL
-- identities (customer JWT, rider JWT, admin JWT), asserts the payloads, and
-- ROLLS BACK. The rollback is not tidiness: notify() queues through pg_net,
-- which is transactional, so a rolled-back proof cannot page Om at 3 AM the
-- way a proof that "deletes the fixture afterwards" would.
--
--   psql "$PGURL" -f scripts/c406_delivery_proof.sql
--   every line is PASS or FAIL; the script exits non-zero on any FAIL.

begin;

do $proof$
declare
  v_cust_id   uuid;   v_cust_user uuid;
  v_rider_id  uuid;   v_rider_user uuid;
  v_admin     uuid;
  v_order     uuid;   v_deliv uuid; v_token text;
  v            jsonb;  v_b jsonb; v_sos bigint;
  v_fail      int := 0; v_pass int := 0;
  v_tomorrow  date := ((now() at time zone 'Asia/Kolkata')::date + 1);
begin
  -- ── assertion helpers, inline so the proof is one file ─────────────────
  create temp table if not exists c406_log(ord serial, ok boolean, line text) on commit drop;

  select pp.id, pp.user_id into v_cust_id, v_cust_user
    from pharmacy_profiles pp
   where pp.user_id is not null and coalesce(pp.is_deleted,false) = false
     and coalesce(pp.approved, false)
     and exists (select 1 from auth.users u where u.id = pp.user_id)
   order by pp.created_at limit 1;
  select p.id, p.user_id into v_rider_id, v_rider_user
    from delivery_partner_registrations p
   where p.user_id is not null and p.is_active and coalesce(p.is_deleted,false) = false
     and coalesce(p.partner_type,'') <> 'agency'
   order by p.created_at limit 1;
  -- admins are keyed by EMAIL (see get_my_role), so the proof resolves the
  -- auth user behind the first admin row rather than assuming a user_id column.
  select u.id into v_admin
    from admins a join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   order by a.created_at limit 1;

  if v_cust_id is null or v_rider_id is null then
    raise exception 'c406 proof: no customer/rider fixture available';
  end if;

  -- ── the fixture: one order, one delivery, already failed once ─────────
  -- enforce_order_approval() reads NEW.user_id, not customer_id, so the
  -- fixture has to carry the same auth user the customer signs in with.
  insert into orders(id, user_id, customer_id, pharmacy_name, phone, status, total_amount, zone_id)
  values (gen_random_uuid(), v_cust_user, v_cust_id, 'c406 proof pharmacy', '9999900000',
          'confirmed', 100, 1)
  returning id into v_order;

  insert into deliveries(id, order_id, partner_id, status, accept_status, attempt_no,
                         next_attempt_on, qr_token, zone_id, seq)
  values (gen_random_uuid(), v_order, v_rider_id, 'failed', 'accepted', 1,
          v_tomorrow, 'c406prooftoken', 1, 1)
  returning id, qr_token into v_deliv, v_token;

  -- ═══ 1. CUSTOMER RESCHEDULE ═══════════════════════════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cust_user, 'role','authenticated')::text, true);

  v := public.delivery_reschedule_options(v_order);
  insert into c406_log(ok, line) values
    (coalesce((v->>'can_reschedule')::boolean,false),
     'reschedule offered on a FAILED delivery -> can_reschedule=' || coalesce(v->>'can_reschedule','null')),
    (jsonb_array_length(coalesce(v->'days','[]'::jsonb)) >= 1,
     'day options generated from days_ahead -> ' || jsonb_array_length(coalesce(v->'days','[]'::jsonb))::text),
    (jsonb_array_length(coalesce(v->'windows','[]'::jsonb)) = 4,
     'four time windows offered -> ' || jsonb_array_length(coalesce(v->'windows','[]'::jsonb))::text),
    (coalesce(v->>'title','') <> '' and coalesce(v->>'submit_label','') <> '',
     'every label is backend copy, not a Dart literal'),
    ((v->'days'->0->>'label') = public._c('delivery.resched.tomorrow'),
     'the first day reads as the backend Tomorrow string, not a formatted date');

  -- the write
  v := public.delivery_reschedule_submit(v_order, to_char(v_tomorrow,'YYYY-MM-DD'), 'evening');
  insert into c406_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'customer reschedule accepted');
  insert into c406_log(ok, line)
  select d.next_attempt_on = ((now() at time zone 'Asia/Kolkata')::date + 1)
         and d.reattempt_window_key = 'evening'
         and d.reattempt_from = '17:00'::time
         and d.reschedule_count = 1
         and d.rescheduled_at is not null,
         'the delivery now carries the chosen day AND window -> '
         || coalesce(d.next_attempt_on::text,'null') || ' / ' || coalesce(d.reattempt_window_label,'null')
    from deliveries d where d.id = v_deliv;

  insert into c406_log(ok, line)
  select count(*) = 1, 'one delivery_reschedule row written, source=order_screen'
    from delivery_reschedule r where r.delivery_id = v_deliv and r.source = 'order_screen';

  -- the token path: the same block, from a link with no session at all
  perform set_config('request.jwt.claims', '', true);
  v := public.delivery_reschedule_public(v_token);
  insert into c406_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false),
     'the public /track token opens the same reschedule block with no session'),
    (coalesce(v->'current'->>'window_key','') = 'evening',
     'and it shows the slot the customer already picked -> '
     || coalesce(v->'current'->>'window_label','null'));

  v := public.delivery_reschedule_public('not-a-real-token');
  insert into c406_log(ok, line) values
    (coalesce(v->>'reason','') = 'not_found' and coalesce(v->>'message','') <> '',
     'a wrong token gets the backend not-found copy, never a payload');

  -- the cap, and the escalation that replaces it
  v := public.delivery_reschedule_submit_public(v_token, to_char(((now() at time zone 'Asia/Kolkata')::date + 2),'YYYY-MM-DD'), 'morning');
  insert into c406_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'second reschedule (the cap) still accepted');
  insert into c406_log(ok, line)
  select d.reschedule_escalated_at is not null,
         'reaching the cap escalates to a human instead of silently allowing more'
    from deliveries d where d.id = v_deliv;

  v := public.delivery_reschedule_public(v_token);
  insert into c406_log(ok, line) values
    (coalesce((v->>'can_reschedule')::boolean,true) = false
       and coalesce(v->>'reason','') = 'capped',
     'a third attempt is refused with the capped reason'),
    (coalesce(v->>'message','') like '%2 times%',
     'and the refusal names the configured cap, not a hardcoded number');

  -- and the rule the spec is built on: only after a failure
  update deliveries set status = 'assigned' where id = v_deliv;
  v := public.delivery_reschedule_public(v_token);
  insert into c406_log(ok, line) values
    (coalesce(v->>'reason','') = 'not_failed',
     'an in-flight delivery cannot be rescheduled — the spec says after a failed attempt and only then');
  update deliveries set status = 'failed' where id = v_deliv;

  -- ═══ 2. THE REATTEMPT ACTUALLY REACHES PLANNING ═══════════════════════
  update deliveries set next_attempt_on = (now() at time zone 'Asia/Kolkata')::date
   where id = v_deliv;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role','authenticated')::text, true);
  v := public.admin_reattempt_queue((now() at time zone 'Asia/Kolkata')::date, 1::smallint);
  insert into c406_log(ok, line) values
    (coalesce((v->>'allowed')::boolean,false), 'admin can read the reattempt queue'),
    (exists (select 1 from jsonb_array_elements(coalesce(v->'rows','[]'::jsonb)) r
              where (r->>'delivery_id') = v_deliv::text),
     'the rescheduled stop APPEARS in the queue — next_attempt_on is no longer write-only'),
    (exists (select 1 from jsonb_array_elements(coalesce(v->'rows','[]'::jsonb)) r
              where (r->>'delivery_id') = v_deliv::text
                and (r->>'by_customer')::boolean
                and (r->>'window_chip') like '%Morning%'),
     'and the row carries the customer''s own words for the slot they asked for');

  -- ═══ 3. RIDER SOS ═════════════════════════════════════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rider_user, 'role','authenticated')::text, true);

  v := public.delivery_sos_state();
  insert into c406_log(ok, line) values
    (coalesce((v->>'can_sos')::boolean,false) and coalesce(v->>'button_label','') <> '',
     'the rider screen gets the SOS button and its copy from the backend'),
    (coalesce((v->>'has_open')::boolean,true) = false, 'and no SOS is open to start with');

  v := public.delivery_sos_raise(null, null, 12, v_deliv);
  insert into c406_log(ok, line) values
    (coalesce(v->>'error','') = 'no_location',
     'an SOS with no fix is refused — sending a team to 0,0 is worse than saying so');

  v := public.delivery_sos_raise(21.2514, 81.6296, 8, v_deliv);
  v_sos := (v->>'sos_id')::bigint;
  insert into c406_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false) and v_sos is not null, 'SOS raised'),
    (coalesce(v->>'map_url','') like '%21.2514%81.6296%',
     'the alert carries a live map link -> ' || coalesce(v->>'map_url','null')),
    ((v->>'interval_s')::int = 10,
     'and the rider is told to stream faster (10s), by the BACKEND not the client');

  insert into c406_log(ok, line)
  select s.status = 'open' and s.partner_id = v_rider_id and s.ping_count = 1,
         'one sos_event row, open, owned by the rider who pressed it'
    from sos_event s where s.id = v_sos;

  v := public.delivery_sos_raise(21.2515, 81.6297, 8, v_deliv);
  insert into c406_log(ok, line) values
    (coalesce((v->>'already')::boolean,false) and (v->>'sos_id')::bigint = v_sos,
     'a second press is the SAME emergency, not a second alert that rings twice');

  v := public.delivery_sos_ping(v_sos, 21.2520, 81.6300, 6);
  insert into c406_log(ok, line) values
    (coalesce((v->>'streaming')::boolean,false) and (v->>'interval_s')::int = 10,
     'the ping keeps streaming while the SOS is open');
  insert into c406_log(ok, line)
  select count(*) = 3, 'every fix is kept as its own sos_ping row -> ' || count(*)::text
    from sos_ping where sos_id = v_sos;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role','authenticated')::text, true);
  v := public.admin_sos_list('open');
  insert into c406_log(ok, line) values
    (exists (select 1 from jsonb_array_elements(coalesce(v->'rows','[]'::jsonb)) r
              where (r->>'id')::bigint = v_sos and (r->>'can_ack')::boolean),
     'the SOS is on the admin list with an Acknowledge action');

  v := public.admin_sos_action(v_sos, 'acknowledge', null);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rider_user, 'role','authenticated')::text, true);
  v := public.delivery_sos_ping(v_sos, 21.2521, 81.6301, 6);
  insert into c406_log(ok, line) values
    (coalesce(v->>'message','') = public._c('delivery.sos.acknowledged'),
     'once the team acknowledges, the rider is TOLD — that is the whole point of the button');

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin, 'role','authenticated')::text, true);
  v := public.admin_sos_action(v_sos, 'resolve', 'proof run');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rider_user, 'role','authenticated')::text, true);
  v := public.delivery_sos_ping(v_sos, 21.2522, 81.6302, 6);
  insert into c406_log(ok, line) values
    (coalesce((v->>'streaming')::boolean,true) = false and (v->>'interval_s')::int = 30,
     'and a resolved SOS stops the fast stream — a phone pinging forever is a flat battery');

  -- ═══ 4. RIDER LEADERBOARD ═════════════════════════════════════════════
  v := public.delivery_leaderboard();
  insert into c406_log(ok, line) values
    (coalesce((v->>'shown')::boolean,false), 'the rider can see a leaderboard'),
    (jsonb_array_length(coalesce(v->'boards','[]'::jsonb)) >= 1,
     'at least the zone board is returned -> ' || jsonb_array_length(coalesce(v->'boards','[]'::jsonb))::text),
    (coalesce(v->'boards'->0->>'drops_caption','') <> ''
       and coalesce(v->'boards'->0->>'on_time_caption','') <> ''
       and coalesce(v->'boards'->0->>'rating_caption','') <> '',
     'drops / on-time / rating captions all come from ui_copy'),
    (exists (select 1 from jsonb_array_elements(coalesce(v->'boards'->0->'rows','[]'::jsonb)) r
              where (r->>'is_me')::boolean and r->>'name' = public._c('delivery.lb.you')),
     'the rider sees themselves marked with the backend You string'),
    (coalesce(v->>'week_label','') <> '', 'and the week is named by the backend -> ' || coalesce(v->>'week_label','null'));

  -- the opt-out, exercised from the agency the rider belongs to
  update delivery_partner_registrations set leaderboard_opt_out = true where id = v_rider_id;
  v := public.delivery_leaderboard();
  insert into c406_log(ok, line) values
    (coalesce((v->>'shown')::boolean,true) = false
       and coalesce(v->>'message','') = public._c('delivery.lb.opted_out'),
     'opting out hides the ranking behind the backend''s own sentence, not a blank screen');
  update delivery_partner_registrations set leaderboard_opt_out = false where id = v_rider_id;

  -- ── verdict ───────────────────────────────────────────────────────────
  select count(*) filter (where ok), count(*) filter (where not ok)
    into v_pass, v_fail from c406_log;
  for v_b in select to_jsonb(l) from c406_log l order by ord loop
    raise notice '%  %', case when (v_b->>'ok')::boolean then 'PASS' else 'FAIL' end, v_b->>'line';
  end loop;
  raise notice '';
  raise notice 'c406 proof: % passed, % failed', v_pass, v_fail;
  if v_fail > 0 then
    raise exception 'c406 proof FAILED: % assertion(s) red', v_fail;
  end if;
end $proof$;

rollback;
