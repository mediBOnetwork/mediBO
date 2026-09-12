-- CHANGE #354 — the PROOF for feature_gaps rows 86, 87, 88, 89.
--
-- Each row gets a permanent rg_behavior_tests entry rather than a screenshot: the
-- test reproduces the defect, so it was RED before the fix in this same command
-- and GREEN after, and it stays wired into rg_check() — which every
-- dev_cmd_complete and every merge-worker batch runs. A regression turns the
-- guard red and blocks the deploy that caused it, instead of waiting for the next
-- audit to notice.
--
-- Bodies roll back: rg_run_behaviors() executes each one inside a block and the
-- closing `raise exception 'RG_ROLLBACK'` is the pass marker, so every fixture
-- inserted below disappears.

insert into public.rg_behavior_tests(name, body, enabled) values
('delivery_run_map_authz', $body$
do $rg$
declare v_partner uuid; v_uid uuid; v_run uuid; v jsonb;
begin
  select id, user_id into v_partner, v_uid from delivery_partner_registrations
   where user_id is not null and coalesce(is_deleted,false)=false order by created_at limit 1;
  if v_partner is null then
    raise exception 'RG_FAIL: no delivery partner fixture exists, so delivery_run_map authorisation is untested (register row 86)';
  end if;

  insert into delivery_runs(partner_id, run_date, status)
  values (v_partner, (now() at time zone 'Asia/Kolkata')::date, 'planned')
  returning id into v_run;

  -- A signed-in user who is NOT a delivery partner and NOT an admin. This is the
  -- caller the old coalesce() guard waved through: v_partner came back NULL, so
  -- the test became partner_id <> partner_id and never fired.
  perform set_config('request.jwt.claims',
    json_build_object('sub','00000000-0000-4000-8000-000000000354','role','authenticated')::text, true);
  v := public.delivery_run_map(v_run);
  if coalesce(v->>'error','') <> 'not_authorized' then
    raise exception 'RG_FAIL: a non-partner signed-in caller read run % — every stop (pharmacy, lat/lng, status) and the rider live origin leak to anyone holding a run uuid (register row 86). Got: %',
      v_run, left(v::text, 240);
  end if;

  -- anonymous must be refused too
  perform set_config('request.jwt.claims','', true);
  v := public.delivery_run_map(v_run);
  if coalesce(v->>'error','') <> 'not_authorized' then
    raise exception 'RG_FAIL: an ANONYMOUS caller read run % (register row 86). Got: %',
      v_run, left(v::text, 240);
  end if;

  -- and the owning rider must still get their own map
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role','authenticated')::text, true);
  v := public.delivery_run_map(v_run);
  if coalesce((v->>'ok')::boolean,false) is not true or coalesce(v->>'has_run','') <> 'true' then
    raise exception 'RG_FAIL: the run owner was locked out of their own map — the guard is too tight. Got: %',
      left(v::text, 240);
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body$, true),

('delivery_mark_failed_closed', $body$
do $rg$
declare v_open text; v_partner uuid; v_oid uuid; v_did uuid; v jsonb; v_status text;
begin
  select string_agg(who, ', ') into v_open from (
    select 'anon' who where has_function_privilege('anon',
      'public.delivery_mark_failed(uuid,text,numeric,numeric)','execute')
    union all
    select 'authenticated' where has_function_privilege('authenticated',
      'public.delivery_mark_failed(uuid,text,numeric,numeric)','execute')) t;
  if v_open is not null then
    raise exception 'RG_FAIL: delivery_mark_failed is EXECUTE-able by: %. Its body carried NO authorisation at all, so anyone holding a delivery uuid could fail anyone''s delivery (register row 88). Revoke from PUBLIC too — anon inherits the default PUBLIC grant',
      v_open;
  end if;

  select id into v_partner from delivery_partner_registrations
   where coalesce(is_deleted,false)=false order by created_at limit 1;
  select id into v_oid from orders order by created_at desc limit 1;
  if v_partner is null or v_oid is null then
    raise exception 'RG_FAIL: no partner/order fixture, so the delivery_mark_failed guard is untested (register row 88)';
  end if;

  insert into deliveries(order_id, partner_id, status, accept_status)
  values (v_oid, v_partner, 'out_for_delivery', 'accepted') returning id into v_did;

  -- a stranger must not be able to fail this drop
  perform set_config('request.jwt.claims',
    json_build_object('sub','00000000-0000-4000-8000-000000000354','role','authenticated')::text, true);
  v := public.delivery_mark_failed(v_did, 'rg probe', null, null);
  select status into v_status from deliveries where id = v_did;
  if coalesce(v->>'error','') <> 'not_authorized' or v_status = 'failed' then
    raise exception 'RG_FAIL: a stranger failed delivery % (status now %, reply %) — delivery_mark_failed still has no ownership guard (register row 88)',
      v_did, v_status, left(v::text, 200);
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body$, true),

('delivery_earning_stamped', $body$
do $rg$
declare
  v_partner uuid; v_uid uuid; v_oid uuid; v_run uuid; v_did uuid;
  v_earn numeric; v_home jsonb; v_bad text;
begin
  select id, user_id into v_partner, v_uid from delivery_partner_registrations
   where user_id is not null and coalesce(is_deleted,false)=false order by created_at limit 1;
  select id into v_oid from orders order by created_at desc limit 1;
  if v_partner is null or v_oid is null then
    raise exception 'RG_FAIL: no partner/order fixture, so earning stamping is untested (register row 87)';
  end if;

  -- 87a. the STAMP. admin_payout_open cuts every line from coalesce(d.earning,0);
  -- nothing used to write that column, so every rider statement totalled zero.
  update delivery_partner_registrations set per_drop_rate = 25, is_active = true where id = v_partner;
  insert into delivery_runs(partner_id, run_date, status)
  values (v_partner, (now() at time zone 'Asia/Kolkata')::date, 'started') returning id into v_run;
  insert into deliveries(order_id, partner_id, run_id, status, accept_status, handover_at)
  values (v_oid, v_partner, v_run, 'out_for_delivery', 'accepted', now()) returning id into v_did;

  update deliveries set status = 'delivered', delivered_at = now() where id = v_did;
  select earning into v_earn from deliveries where id = v_did;
  if coalesce(v_earn, 0) <> 25 then
    raise exception 'RG_FAIL: deliveries.earning was not stamped when the drop became delivered (got %). admin_payout_open pays coalesce(d.earning,0), so every payout line would be 0.00 while the rider screen showed a real figure (register row 87)',
      coalesce(v_earn::text, 'null');
  end if;

  -- 87b. ONE SOURCE. The rider screens must SUM the stamped column, not
  -- re-derive delivered_count * rate — that drift is the whole defect.
  select string_agg(p.proname, ', ' order by p.proname) into v_bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('my_delivery_home','my_delivery_history')
     and pg_get_functiondef(p.oid) not like '%sum(%earning%';
  if v_bad is not null then
    raise exception 'RG_FAIL: % no longer sum(earning) — the rider screen and the payout statement are computing money two different ways again (register row 87)',
      v_bad;
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role','authenticated')::text, true);
  v_home := public.my_delivery_home((now() at time zone 'Asia/Kolkata')::date);
  if coalesce((v_home->>'earning_today')::numeric, -1) <> 25 then
    raise exception 'RG_FAIL: my_delivery_home earning_today is % but the stamped earning for the day is 25.00 — screen and statement disagree (register row 87)',
      coalesce(v_home->>'earning_today','null');
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body$, true),

('delivery_otp_secret_and_lockout', $body$
do $rg$
declare
  v_partner uuid; v_uid uuid; v_oid uuid; v_did uuid; v_code text;
  v jsonb; v_max int; v_i int; v_fails int; v_left text;
begin
  -- 89a. the code must not live on the row the rider can read. RLS policy
  -- deliveries_read hands the assigned rider the whole deliveries row.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.deliveries'::regclass
                    and conname  = 'deliveries_otp_code_stays_null') then
    raise exception 'RG_FAIL: the constraint keeping deliveries.otp_code NULL is gone — the plaintext OTP can drift back onto the row the assigned rider reads, and the rider can then sign for the customer (register row 89)';
  end if;
  if exists (select 1 from deliveries where otp_code is not null) then
    raise exception 'RG_FAIL: a plaintext OTP is sitting on deliveries.otp_code (register row 89)';
  end if;
  if exists (select 1 from pg_class where oid = 'public.delivery_otp'::regclass and not relrowsecurity)
     or exists (select 1 from pg_policies where schemaname='public' and tablename='delivery_otp') then
    raise exception 'RG_FAIL: delivery_otp must keep RLS ON with NO policies — a policy or disabled RLS puts the OTP back within reach of a signed-in rider (register row 89)';
  end if;
  if has_table_privilege('anon','public.delivery_otp','select')
     or has_table_privilege('authenticated','public.delivery_otp','select') then
    raise exception 'RG_FAIL: delivery_otp is SELECT-able by anon/authenticated (register row 89)';
  end if;

  select id, user_id into v_partner, v_uid from delivery_partner_registrations
   where user_id is not null and coalesce(is_deleted,false)=false order by created_at limit 1;
  select id into v_oid from orders order by created_at desc limit 1;
  if v_partner is null or v_oid is null then
    raise exception 'RG_FAIL: no partner/order fixture, so the OTP lockout is untested (register row 89)';
  end if;

  insert into deliveries(order_id, partner_id, status, accept_status, handover_at, is_cold_chain)
  values (v_oid, v_partner, 'out_for_delivery', 'accepted', now(), false) returning id into v_did;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role','authenticated')::text, true);
  v := public.delivery_send_otp(v_did);
  if coalesce((v->>'ok')::boolean,false) is not true then
    raise exception 'RG_FAIL: delivery_send_otp failed: %', left(v::text,200);
  end if;
  if (select otp_code from deliveries where id = v_did) is not null then
    raise exception 'RG_FAIL: delivery_send_otp wrote the plaintext code onto deliveries again (register row 89)';
  end if;
  select code into v_code from public.delivery_otp where delivery_id = v_did;
  if coalesce(v_code,'') !~ '^[0-9]{6}$' then
    raise exception 'RG_FAIL: no 6-digit OTP landed in delivery_otp (got %)', coalesce(v_code,'null');
  end if;

  -- 89b. the lockout. Without it a 6-digit code is one loop away.
  v_max := coalesce((public._dcfg(null)->>'otp_max_attempts')::int, 5);
  for v_i in 1..v_max loop
    v := public.delivery_verify_otp(v_did, 'X' || lpad(v_i::text,5,'0'), null, null, null);
    if v_i < v_max and coalesce(v->>'error','') <> 'wrong_otp' then
      raise exception 'RG_FAIL: wrong attempt % did not answer wrong_otp: %', v_i, left(v::text,200);
    end if;
  end loop;
  if coalesce(v->>'error','') <> 'locked' then
    raise exception 'RG_FAIL: % wrong OTP attempts did not lock the code — it is still brute-forceable (register row 89). Last reply: %',
      v_max, left(v::text,200);
  end if;
  -- the right code must be refused while locked
  v := public.delivery_verify_otp(v_did, v_code, null, null, null);
  if coalesce(v->>'error','') <> 'locked' then
    raise exception 'RG_FAIL: the lockout let a verify through: %', left(v::text,200);
  end if;
  select count(*) into v_fails from delivery_events
   where delivery_id = v_did and event = 'otp_failed';
  if v_fails < v_max then
    raise exception 'RG_FAIL: only % of % failed OTP attempts were logged to delivery_events — a brute force stays invisible (register row 89)',
      v_fails, v_max;
  end if;

  -- 89c. a fresh send clears the lock, the right code completes, and the secret dies
  v := public.delivery_send_otp(v_did);
  select code into v_code from public.delivery_otp where delivery_id = v_did;
  v := public.delivery_verify_otp(v_did, v_code, null, null, 'RG receiver');
  if coalesce((v->>'ok')::boolean,false) is not true then
    raise exception 'RG_FAIL: the correct OTP did not complete the delivery: %', left(v::text,240);
  end if;
  if exists (select 1 from public.delivery_otp where delivery_id = v_did) then
    raise exception 'RG_FAIL: the OTP survived a successful verification — a used code must stop existing (register row 89)';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$body$, true)
on conflict (name) do update set body = excluded.body, enabled = excluded.enabled;

-- Run ONE behaviour test by name. rg_run_behaviors() runs the whole suite, which
-- is right for the deploy gate and wrong for a builder who needs to see a single
-- guard go red-then-green inside a command. Additive: the suite runner is
-- untouched.
create or replace function public.rg_run_behavior(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare t record; v_ok boolean; v_err text;
begin
  select * into t from public.rg_behavior_tests bt where bt.name = p_name;
  if t.name is null then
    return jsonb_build_object('name', p_name, 'ok', false, 'error', 'no such behaviour test');
  end if;
  begin
    execute t.body;
    raise exception 'RG_NO_MARKER';
  exception when others then
    if sqlerrm = 'RG_ROLLBACK' then v_ok := true; v_err := null;
    elsif sqlerrm = 'RG_NO_MARKER' then v_ok := false; v_err := 'test body did not raise RG_ROLLBACK';
    else v_ok := false; v_err := sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims','', true);
  return jsonb_build_object('name', t.name, 'ok', v_ok, 'error', v_err);
end $function$;

revoke execute on function public.rg_run_behavior(text) from public;
revoke execute on function public.rg_run_behavior(text) from anon;
revoke execute on function public.rg_run_behavior(text) from authenticated;
grant execute on function public.rg_run_behavior(text) to service_role;
