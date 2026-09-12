-- CHANGE #1676 — the regression guard went red the moment Om switched the
-- platform to incognito, and stayed red.
--
-- Four probes (delivery_earning_stamped, delivery_mark_failed_closed,
-- delivery_otp_secret_and_lockout, inquiry_timeout_gate_fires) build a fixture
-- that names a REAL rider or a REAL supplier and then roll the whole thing back
-- at RG_ROLLBACK. While test session #49 was live, _synthetic_inherit stamped
-- those doomed inserts is_synthetic=true, and _synthetic_rider_guard /
-- _synthetic_party_guard correctly refused a synthetic row that names a real
-- party. The guards are right; the stamp was wrong — a probe is not test data.
--
-- The fifth (confirm_balance_gate) picked its fixture as "the newest order line
-- that is not shipped/cancelled", which after the session was the synthetic
-- TST supplier — whose only two open lines are an issue line and a not_coming
-- line, both of which auto-raise their own dispute. The equation therefore
-- balanced, confirm returned ok, and the probe read that as the product letting
-- an unbalanced line through.
--
-- Nothing here is rebaselined: all five are behaviour failures.

CREATE OR REPLACE FUNCTION public._synthetic_inherit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_key text; v_hit boolean; v_sess bigint; v_j jsonb; v_parent bigint;
        v_scope text; v_uid uuid;
begin
  -- Once synthetic, always synthetic: only the purge removes these rows.
  if tg_op = 'UPDATE' and coalesce(old.is_synthetic,false) then
    new.is_synthetic := true;
    return new;
  end if;

  -- An ambient TEST SESSION stamps everything CREATED while it is live. This
  -- is the whole point of Om's scope change: he never picks an account and
  -- never ticks a box, he just switches the platform to incognito.
  --
  -- INSERT ONLY, and that is a safety rule, not a shortcut. On UPDATE the
  -- ambient stamp would convert a REAL row that merely got touched during the
  -- session into a synthetic one — and the session purge would then delete it.
  -- c573b_proof check 7 (business data byte-identical before vs after) caught
  -- exactly that. A session may create test data; it may never adopt live data.
  --
  -- The lookup is INLINE rather than a call to _test_session_ambient(), and it
  -- is guarded by tg_op first. This trigger now sits on 57 tables, several of
  -- them hot (order_items, whatsapp_messages, notification_log,
  -- stock_movement), so the no-session path has to cost one index probe on the
  -- partial unique index and nothing else — no SECURITY DEFINER call per row.
  --
  -- CHANGE #1676: ...and a REGRESSION-GUARD PROBE is not a test session's
  -- creation either. Every rg_behavior_tests body ends in RG_ROLLBACK, so
  -- nothing it inserts survives the run — but while an ambient session was
  -- live the stamp landed first, and _synthetic_rider_guard /
  -- _synthetic_party_guard then refused the probe's own fixture ("delivery
  -- (is_synthetic=t) cannot be assigned to rider ..."). Four probes went red
  -- and filed a critical the moment Om switched the platform to incognito.
  -- rg_run_behaviors sets this flag for the length of the battery; the
  -- explicit is_synthetic below and the parent-inherit rules still apply, so
  -- a probe that MEANS to write synthetic data still can.
  if tg_op = 'INSERT'
     and coalesce(current_setting('medibo.rg_probe', true), '') <> 'on' then
    -- CHANGE #468: a canary session owns its rows for the purge but never
    -- stamps ambiently, or the daily heartbeat would adopt (and then
    -- delete) any real order created in the same second.
    select id, scope into v_sess, v_scope from public.test_sessions
     where status = 'live' and ended_at is null and now() < expires_at
       and coalesce(scope,'global') <> 'canary' limit 1;
    if v_sess is not null then
      begin v_uid := auth.uid(); exception when others then v_uid := null; end;
      if v_uid is not null and exists (
           select 1 from public.test_session_exempt e where e.user_id = v_uid) then
        v_sess := null;                    -- the escape hatch wins over the session
      elsif v_scope = 'actors' and (v_uid is null or not exists (
           select 1 from public.test_session_actor a
            where a.session_id = v_sess and a.user_id = v_uid)) then
        v_sess := null;
      end if;
    end if;
  end if;
  if v_sess is not null then
    new.is_synthetic := true;
    v_j := to_jsonb(new);
    if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
      new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_sess));
    end if;
    return new;
  end if;

  if coalesce(new.is_synthetic,false) then return new; end if;

  -- A legacy explicit run context (part 1) still stamps.
  if coalesce(current_setting('medibo.synthetic', true),'') = 'on' then
    new.is_synthetic := true;
    return new;
  end if;

  for r in select * from public.synthetic_inherit_rule
            where child_table = tg_table_name loop
    v_key := to_jsonb(new) ->> r.child_col;
    continue when v_key is null;
    execute format(
      'select p.is_synthetic, p.test_session_id from public.%I p where p.%I = $1::%s limit 1',
      r.parent_table, r.parent_col, r.parent_type)
      into v_hit, v_parent using v_key;
    if coalesce(v_hit,false) then
      new.is_synthetic := true;
      -- A child of a synthetic parent joins the parent's session, so a purge
      -- of that session takes it too.
      if v_parent is not null then
        v_j := to_jsonb(new);
        if v_j ? 'test_session_id' and v_j->>'test_session_id' is null then
          new := jsonb_populate_record(new, v_j || jsonb_build_object('test_session_id', v_parent));
        end if;
      end if;
      return new;
    end if;
  end loop;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.rg_run_behaviors()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t record; res jsonb := '[]'::jsonb; v_ok boolean; v_err text;
  v_state text; v_skipped boolean;
  v_caller_claims text := current_setting('request.jwt.claims', true);
  v_caller_claim  text := current_setting('request.jwt.claim',  true);
  v_deadline timestamptz; v_remain_ms int;
begin
  -- rg_check publishes its own deadline; without one the loop is unbounded and
  -- a single slow behaviour can carry the whole run past its 90 s budget.
  begin
    v_deadline := nullif(current_setting('medibo.rg_deadline', true), '')::timestamptz;
  exception when others then v_deadline := null;
  end;

  -- CHANGE #1676 — A PROBE IS NOT TEST DATA. Every body below ends in
  -- RG_ROLLBACK, so nothing the battery writes ever survives it. While one of
  -- Om's incognito test sessions was live, _synthetic_inherit stamped those
  -- doomed rows is_synthetic=true anyway, and the synthetic party guards then
  -- refused the probe's OWN fixture — four probes went red and filed a
  -- critical for the duration of the session (run 7177 onwards, 2026-09-05).
  -- The flag is transaction-local and set OUTSIDE the loop on purpose: a
  -- probe's subtransaction abort must not clear it for the next probe.
  perform set_config('medibo.rg_probe', 'on', true);

  for t in select * from rg_behavior_tests bt where bt.enabled order by bt.name loop
    if v_deadline is not null and clock_timestamp() > v_deadline then
      res := res || jsonb_build_object('name', t.name, 'ok', true, 'skipped', true,
                                       'error', null,
                                       'note', 'not run — rg_check budget spent (CHANGE #647)');
      continue;
    end if;
    v_skipped := false;
    -- CHANGE #1055 — the deadline was only a gate on STARTING a probe; the
    -- body then ran unbounded and carried the run past its budget (run 3782:
    -- 122 s against a 90 s budget). Each body now gets exactly the time the
    -- run has left, so an over-running probe is one skipped probe instead of
    -- a timed-out run.
    if v_deadline is not null then
      v_remain_ms := greatest((extract(epoch from (v_deadline - clock_timestamp())) * 1000)::int, 1000);
      execute format('set local statement_timeout = %s', v_remain_ms);
    end if;
    -- One behaviour's impersonation must never be the next one's context.
    perform set_config('request.jwt.claims', coalesce(v_caller_claims, ''), true);
    perform set_config('request.jwt.claim',  coalesce(v_caller_claim,  ''), true);
    begin
      execute t.body;
      raise exception 'RG_NO_MARKER';
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      if sqlerrm = 'RG_ROLLBACK' then v_ok := true; v_err := null;
      elsif sqlerrm = 'RG_NO_MARKER' then v_ok := false; v_err := 'test body did not raise RG_ROLLBACK';
      -- CHANGE #962 — A PROBE THAT NEVER RAN IS NOT A FAILING PROBE.
      -- lock_not_available (55P03), a deadlock, or a statement cancelled while
      -- waiting on a lock says the FLEET is busy, not that the product is
      -- broken: five runners writing at once is the normal state of this box.
      -- Four c704 probes reported "canceling statement due to lock timeout"
      -- and the run filed a critical bug row for it, which is the same mistake
      -- rg_watch already refuses to make for a budget timeout ("a timeout is
      -- not a measurement") and for a busy short-circuit ("record nothing,
      -- decide nothing"). Skipped, exactly like a budget-exhausted probe: the
      -- next run measures it.
      elsif v_state in ('55P03','40P01')
         or sqlerrm ilike '%due to lock timeout%'
         or sqlerrm ilike '%deadlock detected%' then
        v_ok := true; v_skipped := true; v_err := null;
      else v_ok := false; v_err := sqlerrm; end if;
    end;
    -- The two objects are MERGED and then appended as ONE element. Without the
    -- parentheses `res || a || b` appends both, and the battery reports 140
    -- results for 70 tests.
    res := res || (jsonb_build_object('name', t.name, 'ok', v_ok, 'error', v_err)
                   || case when v_skipped
                           then jsonb_build_object('skipped', true,
                                  'note', 'not run — could not take a lock; the fleet was writing (CHANGE #962)')
                           else '{}'::jsonb end);
  end loop;
  -- Restore a flat bound rather than 0, so the caller's remaining work is
  -- still capped once the probe battery has spent the budget.
  if v_deadline is not null then execute 'set local statement_timeout = 20000'; end if;
  perform set_config('medibo.rg_probe', '', true);
  perform set_config('request.jwt.claims', coalesce(v_caller_claims, ''), true);
  perform set_config('request.jwt.claim',  coalesce(v_caller_claim,  ''), true);
  return res;
end
$function$;

update public.rg_behavior_tests set body = $c1676$

do $t$
declare v_sup text; v_date date; v_id uuid; r1 jsonb; r2 jsonb; r3 jsonb; v_locked int; v_mode int; v_pre jsonb;
begin
  perform set_config('request.jwt.claims',
    (select json_build_object('sub', u.id, 'email', u.email, 'role','authenticated')::text
       from auth.users u join admins a on lower(a.email)=lower(u.email) limit 1), true);

  select oi.assigned_supplier, (o.created_at at time zone 'Asia/Kolkata')::date
    into v_sup, v_date
    from order_items oi join orders o on o.id = oi.order_id
   where oi.fulfillment_state not in ('shipped','cancelled')
     and not coalesce(oi.received_locked,false)
     and coalesce(oi.assigned_supplier,'') <> ''
     and not coalesce(o.is_synthetic,false)
     and not coalesce(oi.is_synthetic,false)
   order by o.created_at desc limit 1;
  if v_sup is null then raise exception 'RG_ROLLBACK'; end if;

  -- fresh cycle: nothing submitted, nothing disputed, everything counted in full
  update order_items oi set collect_locked=false, shop_qty=oi.quantity
    from orders o where o.id=oi.order_id and oi.assigned_supplier=v_sup
     and (o.created_at at time zone 'Asia/Kolkata')::date=v_date;
  delete from supplier_count_mode where assigned_supplier=v_sup and mode_date=v_date;
  delete from supplier_disputes d using order_items oi join orders o on o.id=oi.order_id
    where d.order_item_id=oi.id and oi.assigned_supplier=v_sup
      and (o.created_at at time zone 'Asia/Kolkata')::date=v_date;

  -- make ONE line short by 1 with no dispute
  select oi.id into v_id from order_items oi join orders o on o.id=oi.order_id
   where oi.assigned_supplier=v_sup and (o.created_at at time zone 'Asia/Kolkata')::date=v_date
     and oi.quantity > 1 and coalesce(oi.count_issue,'')=''
     and oi.fulfillment_state <> 'not_coming'
   order by oi.quantity desc limit 1;
  if v_id is null then raise exception 'RG_ROLLBACK'; end if;
  update order_items set shop_qty = quantity - 1 where id = v_id;

  -- RULE: ordered = counted + disputed. Unbalanced must be REFUSED and must write nothing.
  r1 := fw_confirm_counting(v_sup, v_date);
  if coalesce(r1->>'error','') <> 'unbalanced' then
    raise exception 'confirm accepted an unbalanced line (ordered <> counted + dispute): %', r1;
  end if;
  if coalesce(r1->'popup'->>'reason','') <> 'unbalanced' then
    raise exception 'no unbalanced popup returned to the client';
  end if;
  select count(*) into v_locked from order_items oi join orders o on o.id=oi.order_id
   where oi.assigned_supplier=v_sup and (o.created_at at time zone 'Asia/Kolkata')::date=v_date and oi.collect_locked;
  select count(*) into v_mode from supplier_count_mode where assigned_supplier=v_sup and mode_date=v_date;
  if v_locked > 0 or v_mode > 0 then
    raise exception 'refused confirm still wrote state: locked=% mode_rows=%', v_locked, v_mode;
  end if;

  -- one-tap dispute path balances the equation, then submits
  r2 := fw_confirm_counting(v_sup, v_date, true);
  if coalesce(r2->>'status','') <> 'ok' then raise exception 'dispute_and_confirm failed: %', r2; end if;
  v_pre := fw_confirm_preflight(v_sup, v_date);
  if not coalesce((v_pre->>'can_submit')::boolean,false) then
    raise exception 'still unbalanced after raising shorts: %', v_pre->>'reason';
  end if;
  if coalesce(r2->'banner'->>'label','') <> 'Counted and sent to warehouse' then
    raise exception 'confirm banner wrong: %', r2->'banner'->>'label';
  end if;

  -- uncounted lines can never pass, even on the dispute path
  update order_items oi set shop_qty=null, collect_locked=false
    from orders o where o.id=oi.order_id and oi.assigned_supplier=v_sup
     and (o.created_at at time zone 'Asia/Kolkata')::date=v_date and oi.id=v_id;
  delete from supplier_count_mode where assigned_supplier=v_sup and mode_date=v_date;
  r3 := fw_confirm_counting(v_sup, v_date, true);
  if coalesce(r3->>'error','') <> 'uncounted_items' then
    raise exception 'uncounted line was allowed through: %', r3;
  end if;

  -- warehouse button keeps its own banner
  r3 := fw_count_in_warehouse(v_sup, v_date);
  if coalesce(r3->'banner'->>'label','') <> 'Collected and sent to warehouse' then
    raise exception 'warehouse banner wrong: %', r3->'banner'->>'label';
  end if;

  raise exception 'RG_ROLLBACK';
end $t$;
$c1676$ where name = 'confirm_balance_gate';

update public.rg_behavior_tests set body = $c1676$

do $rg$
declare
  v_partner uuid; v_uid uuid; v_oid uuid; v_run uuid; v_did uuid;
  v_earn numeric; v_home jsonb; v_bad text;
begin
  select id, user_id into v_partner, v_uid from delivery_partner_registrations
   where user_id is not null and coalesce(is_deleted,false)=false
     and not coalesce(is_synthetic,false) order by created_at limit 1;
  select id into v_oid from orders where coalesce(is_synthetic,false) = false order by created_at desc limit 1;
  if v_partner is null or v_oid is null then
    raise exception 'RG_FAIL: no partner/order fixture, so earning stamping is untested (register row 87)';
  end if;

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
$c1676$ where name = 'delivery_earning_stamped';

update public.rg_behavior_tests set body = $c1676$

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
   where coalesce(is_deleted,false)=false
     and not coalesce(is_synthetic,false) order by created_at limit 1;
  select id into v_oid from orders where coalesce(is_synthetic,false) = false order by created_at desc limit 1;
  if v_partner is null or v_oid is null then
    raise exception 'RG_FAIL: no partner/order fixture, so the delivery_mark_failed guard is untested (register row 88)';
  end if;

  insert into deliveries(order_id, partner_id, status, accept_status)
  values (v_oid, v_partner, 'out_for_delivery', 'accepted') returning id into v_did;

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
$c1676$ where name = 'delivery_mark_failed_closed';

update public.rg_behavior_tests set body = $c1676$

do $rg$
declare
  v_partner uuid; v_uid uuid; v_oid uuid; v_did uuid; v_code text;
  v jsonb; v_max int; v_i int; v_fails int;
begin
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
   where user_id is not null and coalesce(is_deleted,false)=false
     and not coalesce(is_synthetic,false) order by created_at limit 1;
  select id into v_oid from orders where coalesce(is_synthetic,false) = false order by created_at desc limit 1;
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
$c1676$ where name = 'delivery_otp_secret_and_lockout';

update public.rg_behavior_tests set body = $c1676$

do $rg$
declare v_id bigint; v_gate text; v_open boolean; v_sup text;
begin
  select gate_sql into v_gate from cron_task where name = 'inquiry_timeout_advance';
  if v_gate is null then raise exception 'RG_FAIL: cron_task inquiry_timeout_advance is gone (#34)'; end if;

  -- trg_inq_rebuild_spo re-enters inquiry_engine_sync() on ANY inquiry write, and
  -- that function blanks asked_at on every row while no zone is locked. Its own
  -- re-entrancy flag is the supported way to write one probe row without the
  -- engine immediately recomputing the whole board underneath the test.
  perform set_config('medibo.spo_rebuilding','on', true);

  select current_supplier into v_sup from inquiry
   where current_supplier is not null and not coalesce(is_synthetic,false) limit 1;
  insert into inquiry (product_id, product_name, quantity, "PS1", current_supplier,
                       inquiry_phase, asked_at, batch_date)
  values (null, 'RG TIMEOUT PROBE', 1, coalesce(v_sup,'RG SUPPLIER'), coalesce(v_sup,'RG SUPPLIER'),
          'sent', now() - interval '30 minutes',
          (now() at time zone 'Asia/Kolkata')::date)
  returning id into v_id;

  -- a dispatched, unanswered inquiry: the gate MUST be true or the task can
  -- never run at all (it had runs=0 / skips=17,883 when this was written).
  execute v_gate into v_open;
  if v_open is not true then
    raise exception 'RG_FAIL: the inquiry_timeout_advance gate is FALSE for an inquiry dispatched 30 minutes ago and never answered — the task can never run (#34). gate: %', v_gate;
  end if;

  -- the body must select that same row
  if not exists (select 1 from inquiry
                  where id = v_id
                    and current_supplier is not null
                    and asked_at is not null
                    and asked_at < now() - interval '10 minutes'
                    and coalesce(current_status,'') <> 'Available'
                    and coalesce(inquiry_phase,'draft') in ('draft','sent')) then
    raise exception 'RG_FAIL: timeout_advance''s own predicate skips a timed-out dispatched inquiry (#34)';
  end if;

  -- and a row that was never dispatched (asked_at NULL) is still never swept
  update inquiry set asked_at = null where id = v_id;
  execute 'select exists (select 1 from public.inquiry
        where id = ' || v_id || ' and current_supplier is not null
          and asked_at is not null
          and asked_at < now() - interval ''10 minutes'')' into v_open;
  if v_open is true then
    raise exception 'RG_FAIL: an undispatched inquiry (asked_at NULL) is being swept (#34)';
  end if;

  -- the dispatch path must still stamp both halves of the clock
  if (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname='public' and p.proname='start_inquiry_for_suppliers') not like '%inquiry_phase = ''sent''%' then
    raise exception 'RG_FAIL: the dispatch path no longer stamps inquiry_phase=''sent'' (#34)';
  end if;

  raise exception 'RG_ROLLBACK';
end $rg$;
$c1676$ where name = 'inquiry_timeout_gate_fires';
