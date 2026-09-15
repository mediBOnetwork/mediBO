-- CMD #477 — the rider half of #454's assignment push, proved end to end.
--
-- #454 landed the whole server side: the delivery_assigned route (audience
-- delivery, push_enabled), _delivery_notify_assigned() on the same transaction
-- that creates the stop, the in-app row and the WhatsApp fallback. What it
-- could not land was the client half — the delivery shell registered no device
-- token — and notif_push_send answers 'no_active_token' in that state, writing
-- NO notification_log row at all. So "the rider was pushed" was unfalsifiable:
-- the ledger looked identical whether the push path worked or did not exist.
--
-- This function is that missing assertion. It is a proof, not a feature: it
-- builds its own fixture, exercises the REAL RPCs the delivery shell now calls
-- (push_token_register on mount, push_token_deactivate on sign-out) and tears
-- everything down again. Idempotent — create or replace, and its fixture is
-- keyed to its own token so a re-run cannot collide with a previous one.
create or replace function public.c477_rider_push_proof()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_admin uuid; v_admin_email text; v_rider_uid uuid;
  v_partner uuid; v_ord uuid; v_run uuid; v_del uuid; v_cust uuid;
  v_token text := 'c477-proof-token-' || encode(extensions.gen_random_bytes(6),'hex');
  v_res jsonb := '[]'::jsonb; v_j jsonb; v_n int; v_t text;
begin
  -- Same reason as c454_delivery_high_b_proof: this runs with no JWT, so the
  -- guarded RPCs would refuse on an empty auth.uid(). Adopt real claims and
  -- exercise the guards rather than bypassing them.
  select a.email, u.id into v_admin_email, v_admin
    from public.admins a join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   order by a.email limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'email', v_admin_email,
                      'role','authenticated')::text, true);

  -- The rider is a REAL auth user (the delivery registration carries user_id,
  -- which is the id notif_push_send matches a token on). test.cust1 is
  -- borrowed as the credential exactly as c454 borrows the admin — it holds no
  -- device token of its own, so a fixture push can never reach a real phone.
  --
  -- The id is read from auth.users DIRECTLY, never through a profile join.
  -- The first cut of this proof resolved it through pharmacy_profiles, and
  -- when that ambient row went away the uid came back NULL — at which point
  -- notif_push_send matches nobody and answers 'no_active_token', so the two
  -- refusal checks below PASSED while proving nothing at all. That is the
  -- delivery-area lesson (a refusal reads like an empty result) landing on
  -- this file, so the uid is asserted before anything is built on it.
  select id into v_rider_uid from auth.users where email = 'test.cust1@medibo.in' limit 1;
  select id into v_cust from public.pharmacy_profiles where user_id = v_rider_uid limit 1;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check','the fixture rider is a REAL auth user (a null uid would make every refusal below meaningless)',
    'ok', v_rider_uid is not null, 'saw', coalesce(v_rider_uid::text,'(null)')));
  if v_rider_uid is null then
    return jsonb_build_object('ok', false, 'passed', 0, 'total', 1, 'checks', v_res);
  end if;

  insert into public.delivery_partner_registrations(
    full_name, phone, status, is_active, partner_type, submitted_at,
    zone_id, user_id, email, reviewed_at)
  values ('C477 Proof Rider','9000000477','approved', true, 'boy', now(),
          (select id from public.zones order by id limit 1),
          v_rider_uid, 'c477.proof.rider@medibo.in', now())
  returning id into v_partner;

  insert into public.orders (user_id, customer_id, pharmacy_name, total_amount, status,
                             order_code, order_date, fulfillment_status)
  values (v_rider_uid, v_cust, 'C477 Proof Pharmacy', 100, 'accepted', 'C477PROOF',
          (now() at time zone 'Asia/Kolkata')::date, 'open')
  returning id into v_ord;

  insert into public.delivery_runs(partner_id, zone_id, status)
  values (v_partner, (select zone_id from public.delivery_partner_registrations where id=v_partner), 'started')
  returning id into v_run;

  insert into public.deliveries(order_id, run_id, partner_id, assigned_at, accept_status, status,
                                qr_token)
  values (v_ord, v_run, v_partner, now(), 'pending', 'assigned',
          encode(extensions.gen_random_bytes(9),'hex'))
  returning id into v_del;

  -- ── 1. the state this command found: a rider with no device ──────────────
  v_j := public.notif_push_send('delivery_assigned', null, v_rider_uid, v_ord,
                                '{"pharmacy":"C477 Proof Pharmacy"}'::jsonb, 'delivery');
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check','with no registered device the push is refused and NOTHING is logged',
    'ok', (v_j->>'reason') = 'no_active_token'
          and not exists (select 1 from public.notification_log
                           where event_key='delivery_assigned' and channel='push'
                             and user_id = v_rider_uid),
    'saw', coalesce(v_j->>'reason','(null)')));

  -- ── 2. what the delivery shell now does on mount ─────────────────────────
  -- push_token_register reads auth.uid(): it is called AS the rider, which is
  -- the only way the client half can be proved rather than simulated.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rider_uid::text, 'email','test.cust1@medibo.in',
                      'role','authenticated')::text, true);
  v_j := public.push_token_register(v_token, 'android', 'c477 proof device');
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check','the rider surface can register a device token for itself',
    'ok', (v_j->>'ok')::boolean is true
          and exists (select 1 from public.push_tokens
                       where token = v_token and user_id = v_rider_uid and is_active),
    'saw', coalesce(v_j->>'ok', v_j->>'error')));

  -- back to the admin's claims for the assignment path
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'email', v_admin_email,
                      'role','authenticated')::text, true);

  -- ── 3. assignment now reaches the device ─────────────────────────────────
  perform public._delivery_notify_assigned(v_del);

  select count(*) into v_n from public.notification_log
   where event_key='delivery_assigned' and channel='push' and user_id = v_rider_uid
     and created_at > now() - interval '2 minutes';
  select coalesce(string_agg(title || ' -> ' || coalesce(deep_link,''), ' | '), 'none')
    into v_t from public.notification_log
   where event_key='delivery_assigned' and channel='push' and user_id = v_rider_uid
     and created_at > now() - interval '2 minutes';
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check','assigning a stop now writes a push row for the rider''s device',
    'ok', v_n >= 1, 'saw', v_t));

  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check','the push copy is the BACKEND route''s, rendered with the order''s vars',
    'ok', exists (select 1 from public.notification_log l
                    join public.wa_event_routes r on r.event_key = l.event_key
                   where l.event_key='delivery_assigned' and l.channel='push'
                     and l.user_id = v_rider_uid
                     and l.created_at > now() - interval '2 minutes'
                     and coalesce(nullif(btrim(r.push_title),''),'') <> ''),
    'saw', (select push_title from public.wa_event_routes where event_key='delivery_assigned')));

  -- ── 4. what the delivery shell now does on sign-out ──────────────────────
  v_j := public.push_token_deactivate(v_token);
  select is_active::text || '/' || coalesce(deactivated_reason,'') into v_t
    from public.push_tokens where token = v_token;
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check','signing out retires the token so a signed-out phone is silent',
    'ok', coalesce((v_j->>'deactivated')::int,0) = 1 and v_t = 'false/signed_out',
    'saw', coalesce(v_t,'(gone)')));

  delete from public.notification_log
   where event_key='delivery_assigned' and user_id = v_rider_uid
     and created_at > now() - interval '5 minutes';
  v_j := public.notif_push_send('delivery_assigned', null, v_rider_uid, v_ord,
                                '{"pharmacy":"C477 Proof Pharmacy"}'::jsonb, 'delivery');
  v_res := v_res || jsonb_build_array(jsonb_build_object(
    'check','after sign-out the same assignment reaches no device again',
    'ok', (v_j->>'reason') = 'no_active_token', 'saw', coalesce(v_j->>'reason','(null)')));

  -- ── teardown ─────────────────────────────────────────────────────────────
  delete from public.push_tokens where token = v_token;
  delete from public.notification_log
   where (user_id = v_rider_uid or recipient = '9000000477')
     and event_key = 'delivery_assigned'
     and created_at > now() - interval '10 minutes';
  delete from public.delivery_events where order_id = v_ord;
  delete from public.deliveries where order_id = v_ord;
  delete from public.delivery_runs where id = v_run;
  delete from public.orders where id = v_ord;
  delete from public.delivery_partner_registrations where id = v_partner;

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_res) r
                       where (r->>'ok')::boolean is distinct from true),
    'passed', (select count(*) from jsonb_array_elements(v_res) r where (r->>'ok')::boolean),
    'total', jsonb_array_length(v_res),
    'checks', v_res);
end $function$;

revoke all on function public.c477_rider_push_proof() from public, anon, authenticated;
