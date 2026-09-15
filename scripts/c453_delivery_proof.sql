\set ON_ERROR_STOP on
set lock_timeout='20s';
begin;
do $$
declare
  v_ok boolean; v_res jsonb; v_n int;
  v_p1 uuid; v_u1 uuid; v_p2 uuid; v_u2 uuid; v_run uuid; v_key text; v_st text;
  v_admin_email text;
begin
  -- ═══ FIXTURE: two riders, each with their own run ═════════════════════════
  select id, user_id into v_p1, v_u1 from delivery_partner_registrations
   where user_id is not null and coalesce(is_deleted,false)=false limit 1;
  select u.id into v_u2 from auth.users u where u.id <> v_u1 limit 1;
  insert into delivery_partner_registrations(user_id, full_name, phone, partner_type, status, is_active)
  values (v_u2, 'C453 proof rider', '9000000453', 'boy', 'approved', true) returning id into v_p2;
  insert into delivery_runs(partner_id, status) values (v_p1, 'planned') returning id into v_run;

  -- ═══ GAP 90 — sequencing someone else's live run ═════════════════════════
  -- BEFORE: delivery_optimize_run only looked the run up; any caller holding
  -- the uuid could reset stop_group and seq mid-trip.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_u2::text, 'role','authenticated')::text, true);
  v_res := public.delivery_optimize_run(v_run);
  raise notice '% gap90 rider B cannot re-sequence rider A''s run -> % / %',
    case when (v_res->>'error') = 'not_authorized' then 'PASS' else 'FAIL' end,
    v_res->>'error', v_res->>'message';

  -- the owner is unaffected
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_u1::text, 'role','authenticated')::text, true);
  v_res := public.delivery_optimize_run(v_run);
  raise notice '% gap90 the OWNER still sequences their own run -> ok=%',
    case when (v_res->>'ok') = 'true' then 'PASS' else 'FAIL' end, v_res->>'ok';

  select bool_and(not has_function_privilege('anon', p.oid, 'execute'))
    into v_ok from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in ('delivery_optimize_run','delivery_start_run','delivery_finish_run');
  raise notice '% gap90 anon can no longer execute any of the three run RPCs',
    case when v_ok then 'PASS' else 'FAIL' end;

  -- ═══ GAP 91 — starting / finishing someone else's run ════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_u2::text, 'role','authenticated')::text, true);
  v_res := public.delivery_start_run(v_run);
  raise notice '% gap91 rider B cannot START rider A''s run -> %',
    case when (v_res->>'error') = 'not_authorized' then 'PASS' else 'FAIL' end, v_res->>'error';
  select status into v_st from delivery_runs where id = v_run;
  raise notice '% gap91 the run was NOT flipped by the refusal (status=%)',
    case when v_st = 'planned' then 'PASS' else 'FAIL' end, v_st;

  v_res := public.delivery_finish_run(v_run);
  raise notice '% gap91 rider B cannot FINISH rider A''s run -> %',
    case when (v_res->>'error') = 'not_authorized' then 'PASS' else 'FAIL' end, v_res->>'error';
  select status into v_st from delivery_runs where id = v_run;
  raise notice '% gap91 no parcel was marked rto by the refusal (status=%)',
    case when v_st = 'planned' then 'PASS' else 'FAIL' end, v_st;

  -- ═══ GAP 94 — the replay key ═════════════════════════════════════════════
  -- rider B is a real, active partner, so we get past the auth check and
  -- exercise the caching rule itself.
  v_key := 'c453-proof-' || gen_random_uuid()::text;
  v_res := public.delivery_replay(v_key, 'mark_delivered',
             jsonb_build_object('delivery_id', gen_random_uuid()));
  raise notice '% gap94 attempt 1 returns the real failure (ok=%, replayed=%)',
    case when (v_res->>'ok') = 'false' and (v_res->>'replayed') = 'false' then 'PASS' else 'FAIL' end,
    v_res->>'ok', v_res->>'replayed';
  select count(*) into v_n from delivery_action_log where client_action_id = v_key and result is not null;
  raise notice '% gap94 an ok:false result is NOT frozen into result (cached=%)',
    case when v_n = 0 then 'PASS' else 'FAIL' end, v_n;
  select count(*) into v_n from delivery_action_log where client_action_id = v_key and last_result is not null;
  raise notice '% gap94 the failure is still auditable in last_result (rows=%)',
    case when v_n = 1 then 'PASS' else 'FAIL' end, v_n;

  v_res := public.delivery_replay(v_key, 'mark_delivered',
             jsonb_build_object('delivery_id', gen_random_uuid()));
  raise notice '% gap94 a retry RE-EXECUTES instead of replaying the frozen failure (replayed=%)',
    case when (v_res->>'replayed') = 'false' then 'PASS' else 'FAIL' end, v_res->>'replayed';
  select attempts into v_n from delivery_action_log where client_action_id = v_key;
  raise notice '% gap94 both attempts are counted on the one key (attempts=%)',
    case when v_n = 2 then 'PASS' else 'FAIL' end, v_n;

  -- a SUCCESS is cached, and the second call replays it rather than repeating it
  v_key := 'c453-proof-ok-' || gen_random_uuid()::text;
  v_res := public.delivery_replay(v_key, 'location',
             jsonb_build_object('lat', 21.25, 'lng', 81.63));
  raise notice '% gap94 a successful action is cached (ok=%)',
    case when (v_res->>'ok') = 'true' then 'PASS' else 'FAIL' end, v_res->>'ok';
  v_res := public.delivery_replay(v_key, 'location',
             jsonb_build_object('lat', 21.25, 'lng', 81.63));
  raise notice '% gap94 the retry of a SUCCESS replays instead of re-running (replayed=%)',
    case when (v_res->>'replayed') = 'true' then 'PASS' else 'FAIL' end, v_res->>'replayed';
  select bool_and(pg_get_functiondef(p.oid) ilike '%pg_advisory_xact_lock%')
    into v_ok from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='delivery_replay';
  raise notice '% gap94 concurrent retries of one key are serialised by an advisory lock',
    case when v_ok then 'PASS' else 'FAIL' end;

  -- ═══ GAP 92 — signature is a completion method ═══════════════════════════
  select pg_get_functiondef(p.oid) ilike '%_delivery_complete%'
    into v_ok from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='delivery_attach_signature';
  raise notice '% gap92 delivery_attach_signature ends in _delivery_complete',
    case when v_ok then 'PASS' else 'FAIL' end;
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='delivery_attach_signature';
  raise notice '% gap92 exactly one overload (=%), so PostgREST cannot be ambiguous',
    case when v_n = 1 then 'PASS' else 'FAIL' end, v_n;
  v_res := public.delivery_attach_signature(gen_random_uuid(), 'x/y.png', 'Receiver', 21.2, 81.6);
  raise notice '% gap92 an unknown stop is refused, not silently signed -> %',
    case when (v_res->>'error') = 'not_found' then 'PASS' else 'FAIL' end, v_res->>'error';
  select pg_get_functiondef(p.oid) ilike '%''signature''%'
    into v_ok from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='delivery_replay';
  raise notice '% gap92/93 the offline replay path routes action=signature',
    case when v_ok then 'PASS' else 'FAIL' end;

  -- ═══ GAP 96 — approval workflow ══════════════════════════════════════════
  select exists(select 1 from information_schema.columns
                 where table_name='delivery_partner_registrations' and column_name='review_reason') into v_ok;
  raise notice '% gap96 review_reason column exists', case when v_ok then 'PASS' else 'FAIL' end;
  select pg_get_function_identity_arguments(p.oid) ilike '%p_reason%'
    into v_ok from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='admin_review_registration';
  raise notice '% gap96 admin_review_registration now takes a reason',
    case when v_ok then 'PASS' else 'FAIL' end;

  -- the applicant can read their own application back
  v_res := public.my_delivery_application();
  raise notice '% gap96 an existing rider sees their own application (%, %)',
    case when (v_res->>'has') = 'true' then 'PASS' else 'FAIL' end,
    v_res->>'status_label', v_res->>'status_tone';

  -- an admin rejects WITH a reason, and the applicant sees it
  select a.email into v_admin_email from admins a
    join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email)) limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub', (select u.id from auth.users u
                               where lower(btrim(u.email)) = lower(btrim(v_admin_email)))::text,
                      'email', v_admin_email, 'role','authenticated')::text, true);
  v_res := public.admin_review_registration('delivery_partner', v_p2, 'rejected', 'Documents unreadable');
  raise notice '% gap96 reject carries the reason back -> %',
    case when (v_res->>'reason') = 'Documents unreadable' then 'PASS' else 'FAIL' end, v_res->>'message';
  select review_reason into v_st from delivery_partner_registrations where id = v_p2;
  raise notice '% gap96 the reason is stored on the row (%)',
    case when v_st = 'Documents unreadable' then 'PASS' else 'FAIL' end, coalesce(v_st,'<null>');
  select count(*) into v_n from notification_log
   where user_id = v_u2 and event_key = 'delivery_partner_rejected';
  raise notice '% gap96 the APPLICANT is told (inbox rows=%)',
    case when v_n >= 1 then 'PASS' else 'FAIL' end, v_n;

  perform set_config('request.jwt.claims',
    json_build_object('sub', v_u2::text, 'role','authenticated')::text, true);
  v_res := public.my_delivery_application();
  raise notice '% gap96 the applicant reads the decision + reason back -> % / %',
    case when (v_res->>'status') = 'rejected'
          and (v_res->>'status_message') = 'Documents unreadable' then 'PASS' else 'FAIL' end,
    v_res->>'status_label', v_res->>'status_message';

  select pg_get_functiondef(p.oid) ilike '%_delivery_inbox%'
    into v_ok from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='delivery_partner_register';
  raise notice '% gap96 a new application alerts every admin',
    case when v_ok then 'PASS' else 'FAIL' end;

  -- ═══ GAP 97 — agency riders ══════════════════════════════════════════════
  -- make rider B an agency in zone 1 and have it try to plant a rider in zone 9
  update delivery_partner_registrations set partner_type='agency', zone_id=1 where id = v_p2;
  v_res := public.agency_add_partner(jsonb_build_object(
             'full_name','C453 agency rider','phone','9000000454','zone_id', 9));
  raise notice '% gap97 the agency created a rider (ok=%)',
    case when (v_res->>'ok') = 'true' then 'PASS' else 'FAIL' end, v_res->>'ok';
  raise notice '% gap97 the payload zone_id was IGNORED — rider lands in the agency zone (zone=%)',
    case when (v_res->>'zone_id') = '1' then 'PASS' else 'FAIL' end, v_res->>'zone_id';
  select count(*) into v_n from login_identities
   where owner_type='delivery' and owner_id = (v_res->>'partner_id');
  raise notice '% gap97 the rider now has a login identity (rows=%)',
    case when v_n >= 1 then 'PASS' else 'FAIL' end, v_n;
  raise notice '% gap97 and an invite code to attach their own account (%)',
    case when length(coalesce(v_res->>'invite_code','')) = 8 then 'PASS' else 'FAIL' end,
    v_res->>'invite_code';

  -- a rider with a login claims the invite and becomes reachable by user_id
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_u1::text, 'role','authenticated')::text, true);
  v_res := public.delivery_claim_invite(v_res->>'invite_code');
  raise notice '% gap97 the rider claims the invite -> %',
    case when (v_res->>'ok') = 'true' then 'PASS' else 'FAIL' end, v_res->>'message';
  select count(*) into v_n from delivery_partner_registrations
   where id = (v_res->>'partner_id')::uuid and user_id = v_u1;
  raise notice '% gap97 user_id is now set, so my_delivery_home resolves them (rows=%)',
    case when v_n = 1 then 'PASS' else 'FAIL' end, v_n;
  v_res := public.delivery_claim_invite('ZZZZZZZZ');
  raise notice '% gap97 a bogus code is refused with backend copy -> %',
    case when (v_res->>'error') = 'invite_not_found' then 'PASS' else 'FAIL' end, v_res->>'message';
end $$;
rollback;
