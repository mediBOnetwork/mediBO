-- CHANGE #705 (8/8) — the journeys, spec item 7.
--
-- Four probes, one per flow the spec names, and each one runs the REAL chain
-- against real functions and rolls every write back: a pharmacy that registers
-- through submit_registration, uploads, is refused approval, is verified and is
-- then approved; a rejection that must carry a reason and that reaches the
-- applicant's own panel; a licence that is reminded about at 30/7/1 and then
-- blocks by expiring; and the supplier side over the PUBLIC token page, ending
-- in the inquiry engine's own answer. Nothing here asserts a string this
-- command wrote into Dart, because nothing here reads Dart.
--
-- It also ends the dispatcher edit: a journey named c705-kyc-expiry-block is
-- answered by _journey_c705_kyc_expiry_block() by CONVENTION, so registering a
-- journey is an INSERT from here on, never a 640-line function replace.
-- Idempotent throughout.

-- ── the convention ─────────────────────────────────────────────────────────
create or replace function public._dev_journey_by_convention(p_name text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_fn text := '_journey_' || regexp_replace(lower(coalesce(p_name,'')), '[^a-z0-9]+', '_', 'g');
  v_out jsonb;
begin
  -- the transformed name must be a plain identifier, and the function must
  -- actually exist; anything else falls through to the hand-written branches.
  if v_fn !~ '^_journey_[a-z0-9_]+$' then return null; end if;
  if to_regprocedure('public.' || quote_ident(v_fn) || '()') is null then return null; end if;
  execute format('select public.%I()', v_fn) into v_out;
  return v_out;
end
$fn$;

comment on function public._dev_journey_by_convention(text) is
  'CHANGE #705 — dev_journey_probe asks this first: a journey named '
  'c705-kyc-reject-reason is answered by _journey_c705_kyc_reject_reason(). '
  'Returns NULL when no such function exists, so every hand-written branch in '
  'the dispatcher keeps its behaviour unchanged.';

do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'dev_journey_probe';
  if v_def is not null and v_def not like '%_dev_journey_by_convention%' then
    v_new := replace(v_def, 'perform public._dev_guard();',
      'perform public._dev_guard();' || chr(10) || chr(10) ||
      '  -- CHANGE #705 — by convention first: a journey whose name maps to a' || chr(10) ||
      '  -- probe function needs no branch in this dispatcher at all.' || chr(10) ||
      '  v_chk := public._dev_journey_by_convention(p_name);' || chr(10) ||
      '  if v_chk is not null then return v_chk; end if;' || chr(10));
    if v_new = v_def then raise exception 'c705: probe dispatcher patch did not apply'; end if;
    execute v_new;
  end if;
end $do$;

-- ── 1. new pharmacy -> upload -> verify -> approve ─────────────────────────
create or replace function public._journey_c705_kyc_pharmacy_chain()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_uid uuid := gen_random_uuid(); v_zone smallint;
  v_reg jsonb; v_ph uuid; v_panel0 jsonb; v_panel1 jsonb; v_up jsonb; v_doc uuid;
  v_ver jsonb; v_appr jsonb; v_gate0 jsonb; v_gate1 jsonb; v_queue jsonb;
  v_in_queue boolean := false; v_early_block boolean := false; v_early_msg text := '';
  v_approved boolean := false; v_chain text := 'not run';
  v_anon_write boolean; v_anon_token boolean; v_live_uk boolean; v_trg int;
  v_refused_approved boolean := false; v_ok boolean;
begin
  perform public._dev_guard();

  -- The fence: the applicant's own writes are authenticated-only, the token
  -- page is the ONE anonymous door, and the review RPCs are neither.
  v_anon_write := has_function_privilege('anon',
        'public.kyc_upload_register(text,text,text,text,date,date,text,bigint)','execute')
    or has_function_privilege('anon','public.kyc_review_set(uuid,text,text)','execute')
    or has_function_privilege('anon','public.kyc_review_queue(text,text,integer,integer)','execute')
    or has_function_privilege('anon','public.kyc_drive_send(text,integer)','execute');
  v_anon_token := has_function_privilege('anon','public.kyc_token_form(text)','execute')
              and has_function_privilege('anon','public.kyc_token_submit(text,text,text,date,text)','execute');
  v_live_uk := exists (select 1 from pg_indexes
                        where schemaname='public' and tablename='kyc_documents'
                          and indexname='kyc_documents_live_uk');
  select count(*) into v_trg from pg_trigger
   where not tgisinternal
     and tgname in ('trg_kyc_approval_guard_pharmacy','trg_kyc_approval_guard_supplier');

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      -- the applicant registers through the SAME door every other kind uses
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_reg := public.submit_registration('pharmacy', jsonb_build_object(
                 'pharmacy_name','C705 PROBE PHARMACY','customer_name','C705 PROBE',
                 'phone','9000000705','whatsapp_no','9000000705','address','Probe Lane',
                 'city','Raipur','state','Chhattisgarh','pincode','492001',
                 'approved', true));                    -- must be REFUSED, not applied
      v_ph := nullif(v_reg->>'id','')::uuid;
      v_refused_approved := coalesce(v_reg->'rejected_keys','[]'::jsonb) ? 'approved'
                        and not coalesce((select approved from pharmacy_profiles where id = v_ph), false);
      update pharmacy_profiles set zone_id = v_zone where id = v_ph;
      v_panel0 := public.kyc_my_panel();

      -- an admin cannot approve it yet
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      begin
        perform public.admin_review_registration('pharmacy', v_ph, 'approved');
      exception when others then
        v_early_block := true; v_early_msg := left(sqlerrm, 160);
      end;

      -- upload
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_up := public.kyc_upload_register('drug_licence',
                'pharmacy/'||v_ph::text||'/dl.pdf', 'dl.pdf', 'CG-20B-C705',
                null, ((now() at time zone 'Asia/Kolkata')::date + 365));
      v_doc := nullif(v_up->>'doc_id','')::uuid;
      v_panel1 := public.kyc_my_panel();
      v_gate0 := public.cart_rx_gate(v_ph, '[]'::jsonb);

      -- review, then approve
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_queue := public.kyc_review_queue('pending', 'pharmacy', 50, 0);
      v_in_queue := exists (select 1
        from jsonb_array_elements(coalesce(v_queue->'rows','[]'::jsonb)) r
       where r->>'doc_id' = v_doc::text);
      v_ver  := public.kyc_review_set(v_doc, 'verified', null);
      v_appr := public.admin_review_registration('pharmacy', v_ph, 'approved');
      select coalesce(approved,false) into v_approved from pharmacy_profiles where id = v_ph;
      v_gate1 := public.cart_rx_gate(v_ph, '[]'::jsonb);
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := not v_anon_write and v_anon_token and v_live_uk and v_trg = 2
      and v_chain = 'ran'
      and v_refused_approved
      and coalesce(v_panel0->'state'->>'state','') = 'missing'
      and v_early_block
      and v_early_msg ilike '%drug licence%'
      and coalesce((v_up->>'ok')::boolean,false)
      and coalesce(v_panel1->'state'->>'state','') = 'pending'
      and coalesce((v_gate0->>'blocked')::boolean,false)
      and v_in_queue
      and coalesce((v_ver->>'ok')::boolean,false)
      and coalesce(v_ver->'owner_state'->>'state','') = 'verified'
      and coalesce((v_appr->>'ok')::boolean,false)
      and v_approved
      and not coalesce((v_gate1->>'blocked')::boolean,true);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | anon can write KYC='||coalesce(v_anon_write,false)::text||' (must be false)'
   || ' | anon token page open='||coalesce(v_anon_token,false)::text
   || ' | one live doc per kind (unique index)='||coalesce(v_live_uk,false)::text
   || ' | approval triggers='||v_trg::text
   || ' | applicant could not set approved itself='||v_refused_approved::text
   || ' | panel before upload='||coalesce(v_panel0->'state'->>'state','?')
   || ' | approval before verification refused='||v_early_block::text
   || ' -> '||coalesce(nullif(v_early_msg,''),'<no message>')
   || ' | upload ok='||coalesce(v_up->>'ok','?')
   || ' | panel after upload='||coalesce(v_panel1->'state'->>'state','?')
   || ' | ordering blocked while pending='||coalesce(v_gate0->>'blocked','?')
   || ' -> '||coalesce(v_gate0->>'message','')
   || ' | document in the review queue='||v_in_queue::text
   || ' | verify ok='||coalesce(v_ver->>'ok','?')
   || ' state='||coalesce(v_ver->'owner_state'->>'state','?')
   || ' | approve after verification ok='||coalesce(v_appr->>'ok','?')
   || ' approved='||v_approved::text
   || ' | ordering blocked after verification='||coalesce(v_gate1->>'blocked','?')));
end
$fn$;

-- ── 2. reject with a reason -> the applicant sees it ───────────────────────
create or replace function public._journey_c705_kyc_reject_reason()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_uid uuid := gen_random_uuid(); v_zone smallint;
  v_reason text := 'The licence photo is cut off - page 2 is missing.';
  v_reg jsonb; v_ph uuid; v_up jsonb; v_doc uuid; v_no_reason jsonb; v_rej jsonb;
  v_panel jsonb; v_item jsonb; v_gate jsonb; v_chain text := 'not run';
  v_route_on boolean; v_route_has_reason boolean; v_ok boolean;
begin
  perform public._dev_guard();

  -- the applicant is told over WhatsApp too, and the template carries the
  -- reason itself rather than "contact support"
  select coalesce(enabled,false),
         coalesce(push_body,'') like '%{{reason}}%'
    into v_route_on, v_route_has_reason
    from wa_event_routes where event_key = 'kyc_document_rejected';

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_reg := public.submit_registration('pharmacy', jsonb_build_object(
                 'pharmacy_name','C705 PROBE REJECT','customer_name','C705 PROBE',
                 'phone','9000000706','address','Probe Lane','city','Raipur',
                 'state','Chhattisgarh','pincode','492001'));
      v_ph := nullif(v_reg->>'id','')::uuid;
      update pharmacy_profiles set zone_id = v_zone where id = v_ph;
      v_up := public.kyc_upload_register('drug_licence',
                'pharmacy/'||v_ph::text||'/dl.jpg', 'dl.jpg', 'CG-20B-706',
                null, ((now() at time zone 'Asia/Kolkata')::date + 200));
      v_doc := nullif(v_up->>'doc_id','')::uuid;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_no_reason := public.kyc_review_set(v_doc, 'rejected', null);   -- refused
      v_rej       := public.kyc_review_set(v_doc, 'rejected', v_reason);

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_panel := public.kyc_my_panel();
      select r into v_item from jsonb_array_elements(coalesce(v_panel->'items','[]'::jsonb)) r
       where r->>'kind' = 'drug_licence';
      v_gate := public.cart_rx_gate(v_ph, '[]'::jsonb);
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_route_on,false) and coalesce(v_route_has_reason,false)
      and not coalesce((v_no_reason->>'ok')::boolean, true)
      and coalesce(v_no_reason->>'error','') = 'no_reason'
      and coalesce((v_rej->>'ok')::boolean,false)
      and coalesce(v_item->>'status','') = 'rejected'
      and coalesce(v_item->>'reason_line','') like '%page 2 is missing%'
      and coalesce(v_item->>'status_tone','') = 'danger'
      and coalesce((v_gate->>'blocked')::boolean,false)
      and coalesce(v_gate->'kyc'->>'reason','') = 'kyc_rejected';

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | WhatsApp route kyc_document_rejected enabled='||coalesce(v_route_on,false)::text
   || ' carries the reason='||coalesce(v_route_has_reason,false)::text
   || ' | rejection with no reason refused='||coalesce(v_no_reason->>'error','?')
   || ' | rejection with a reason ok='||coalesce(v_rej->>'ok','?')
   || ' | applicant panel status='||coalesce(v_item->>'status','?')
   || ' tone='||coalesce(v_item->>'status_tone','?')
   || ' | the reason the applicant reads='||coalesce(nullif(v_item->>'reason_line',''),'<empty>')
   || ' | ordering blocked='||coalesce(v_gate->>'blocked','?')
   || ' reason='||coalesce(v_gate->'kyc'->>'reason','?')));
end
$fn$;

-- ── 3. expiry -> reminder at 30/7/1 -> block -> renew ──────────────────────
create or replace function public._journey_c705_kyc_expiry_block()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_uid uuid := gen_random_uuid(); v_zone smallint;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_reg jsonb; v_ph uuid; v_up jsonb; v_doc uuid; v_ver jsonb;
  v_sweep1 jsonb; v_sweep2 jsonb; v_sweep3 jsonb;
  v_b7 int := 0; v_b7_again int := 0; v_bexp int := 0;
  v_state_exp text := ''; v_gate_exp jsonb; v_renew jsonb; v_state_renew text := '';
  v_ver2 jsonb; v_gate_after jsonb; v_chain text := 'not run';
  v_cron_on boolean; v_cron_at time; v_ok boolean;
begin
  perform public._dev_guard();

  select coalesce(enabled,false), run_at_ist into v_cron_on, v_cron_at
    from cron_task where name = 'kyc-expiry-sweep';

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_reg := public.submit_registration('pharmacy', jsonb_build_object(
                 'pharmacy_name','C705 PROBE EXPIRY','customer_name','C705 PROBE',
                 'phone','9000000707','whatsapp_no','9000000707','address','Probe Lane',
                 'city','Raipur','state','Chhattisgarh','pincode','492001'));
      v_ph := nullif(v_reg->>'id','')::uuid;
      update pharmacy_profiles set zone_id = v_zone where id = v_ph;
      -- a licence that expires in six days: the 7-day bucket, not the 30
      v_up := public.kyc_upload_register('drug_licence',
                'pharmacy/'||v_ph::text||'/dl.pdf', 'dl.pdf', 'CG-20B-707',
                null, v_today + 6);
      v_doc := nullif(v_up->>'doc_id','')::uuid;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_ver := public.kyc_review_set(v_doc, 'verified', null);

      v_sweep1 := public.kyc_expiry_sweep();
      select count(*) into v_b7 from kyc_expiry_reminder
       where owner_id = v_ph and bucket_days = 7;
      v_sweep2 := public.kyc_expiry_sweep();               -- must be silent
      select count(*) into v_b7_again from kyc_expiry_reminder
       where owner_id = v_ph and bucket_days = 7;

      -- the day it lapses (the only clock a probe may move is the document's)
      update kyc_documents set valid_to = v_today - 1 where id = v_doc;
      v_sweep3 := public.kyc_expiry_sweep();
      select count(*) into v_bexp from kyc_expiry_reminder
       where owner_id = v_ph and bucket_days = -1;
      v_state_exp := public.kyc_state('pharmacy', v_ph) ->> 'state';
      v_gate_exp  := public.kyc_gate('pharmacy', v_ph, 'trade');

      -- renew: the ordinary upload path, and the block lifts on its own
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_renew := public.kyc_upload_register('drug_licence',
                   'pharmacy/'||v_ph::text||'/dl-renewed.pdf', 'dl-renewed.pdf',
                   'CG-20B-707R', null, v_today + 400);
      v_state_renew := public.kyc_state('pharmacy', v_ph) ->> 'state';
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_ver2 := public.kyc_review_set(nullif(v_renew->>'doc_id','')::uuid, 'verified', null);
      v_gate_after := public.kyc_gate('pharmacy', v_ph, 'trade');
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_cron_on,false) and v_cron_at is not null
      and v_b7 = 1 and v_b7_again = 1
      and v_bexp = 1
      and v_state_exp = 'expired'
      and coalesce((v_gate_exp->>'blocked')::boolean,false)
      and coalesce(v_gate_exp->>'reason','') = 'kyc_expired'
      and coalesce((v_renew->>'ok')::boolean,false)
      and v_state_renew = 'pending'
      and coalesce((v_ver2->>'ok')::boolean,false)
      and not coalesce((v_gate_after->>'blocked')::boolean,true);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | cron_task kyc-expiry-sweep enabled='||coalesce(v_cron_on,false)::text
   || ' at '||coalesce(v_cron_at::text,'<none>')||' IST'
   || ' | 7-day reminder rows after one sweep='||v_b7::text
   || ' after two='||v_b7_again::text||' (a re-run must be silent)'
   || ' | sweep1 reminded='||coalesce(v_sweep1->>'reminded','?')
   || ' sweep2 reminded='||coalesce(v_sweep2->>'reminded','?')
   || ' | on expiry: reminder rows='||v_bexp::text
   || ' expired='||coalesce(v_sweep3->>'expired','?')
   || ' blocked='||coalesce(v_sweep3->>'blocked','?')
   || ' | state='||coalesce(nullif(v_state_exp,''),'?')
   || ' gate blocked='||coalesce(v_gate_exp->>'blocked','?')
   || ' -> '||coalesce(v_gate_exp->>'message','')
   || ' | renew upload ok='||coalesce(v_renew->>'ok','?')
   || ' state='||coalesce(nullif(v_state_renew,''),'?')
   || ' | after re-verification blocked='||coalesce(v_gate_after->>'blocked','?')));
end
$fn$;

-- ── 4. the supplier side, over the public token page ───────────────────────
create or replace function public._journey_c705_kyc_supplier_token()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_admin uuid; v_zone smallint; v_sup uuid; v_name text := 'C705 PROBE SUPPLIER';
  v_token text := 'c705probe' || replace(gen_random_uuid()::text,'-','');
  v_blocked0 boolean; v_blocked1 boolean; v_form jsonb; v_sub jsonb; v_doc uuid;
  v_early_block boolean := false; v_early_msg text := '';
  v_ver jsonb; v_appr jsonb; v_approved boolean := false; v_chain text := 'not run';
  v_engine_reads_gate boolean; v_card jsonb; v_ok boolean;
begin
  perform public._dev_guard();

  -- the inquiry engine asks the gate itself; the waterfall is where a blocked
  -- supplier has to disappear, not the console
  select coalesce(p.prosrc,'') like '%kyc_supplier_blocked%' into v_engine_reads_gate
    from pg_proc p where p.pronamespace='public'::regnamespace
     and p.proname='start_inquiry_for_suppliers' limit 1;

  select u.id into v_admin from auth.users u
    join admins a on lower(btrim(a.email)) = lower(btrim(u.email))
   where coalesce(a.is_super,false) limit 1;
  select id into v_zone from zones order by id limit 1;

  if v_admin is not null then
    begin
      insert into supplier_profiles (supplier_name, contact_name, phone, whatsapp_no,
                                     city, state, address, zone_id, approved, status)
      values (v_name, 'C705 PROBE', '9000000708', '9000000708', 'Raipur',
              'Chhattisgarh', 'Probe Lane', v_zone, false, 'pending')
      returning id into v_sup;
      v_blocked0 := public.kyc_supplier_blocked(v_name);

      -- an admin cannot approve it yet
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      begin
        perform public.admin_review_registration('supplier', v_sup, 'approved');
      exception when others then
        v_early_block := true; v_early_msg := left(sqlerrm,160);
      end;
      v_card := public.kyc_drive_card();

      -- the backfill link, opened in a WhatsApp browser with no session
      insert into kyc_upload_token(token, owner_kind, owner_id)
      values (v_token, 'supplier', v_sup);
      perform set_config('request.jwt.claims',
        json_build_object('role','anon')::text, true);
      v_form := public.kyc_token_form(v_token);
      v_sub  := public.kyc_token_submit(v_token, 'token/'||v_token||'/dl.jpg',
                  'CG-21B-708', ((now() at time zone 'Asia/Kolkata')::date + 300), 'dl.jpg');
      v_doc  := nullif(v_sub->>'doc_id','')::uuid;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_admin::text, 'role','authenticated')::text, true);
      v_ver  := public.kyc_review_set(v_doc, 'verified', null);
      v_appr := public.admin_review_registration('supplier', v_sup, 'approved');
      select coalesce(approved,false) into v_approved from supplier_profiles where id = v_sup;
      v_blocked1 := public.kyc_supplier_blocked(v_name);
      v_chain := 'ran';
      raise exception using errcode='ZZ705', message='c705 journey rollback';
    exception
      when sqlstate 'ZZ705' then null;
      when others then
        if v_chain = 'not run' then v_chain := 'error: '||left(sqlerrm,160); end if;
    end;
  end if;
  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_chain = 'ran'
      and coalesce(v_engine_reads_gate,false)
      and coalesce(v_blocked0,false)
      and v_early_block and v_early_msg ilike '%drug licence%'
      and coalesce((v_form->>'ok')::boolean,false)
      and coalesce(v_form->>'title','') <> ''
      and coalesce((v_sub->>'ok')::boolean,false)
      and coalesce((v_ver->>'ok')::boolean,false)
      and coalesce((v_appr->>'ok')::boolean,false)
      and v_approved
      and not coalesce(v_blocked1,true)
      and coalesce((v_card->>'ok')::boolean,false);

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'chain='||v_chain
   || ' | the inquiry waterfall reads the gate='||coalesce(v_engine_reads_gate,false)::text
   || ' | supplier not asked while unverified='||coalesce(v_blocked0,false)::text
   || ' | approval before verification refused='||v_early_block::text
   || ' -> '||coalesce(nullif(v_early_msg,''),'<no message>')
   || ' | anonymous token page ok='||coalesce(v_form->>'ok','?')
   || ' title='||coalesce(v_form->>'title','?')
   || ' | anonymous upload ok='||coalesce(v_sub->>'ok','?')
   || ' | verify ok='||coalesce(v_ver->>'ok','?')
   || ' | approve after verification ok='||coalesce(v_appr->>'ok','?')
   || ' approved='||v_approved::text
   || ' | supplier asked again after verification='||(not coalesce(v_blocked1,true))::text
   || ' | drive card='||coalesce(v_card->>'progress_label', v_card->>'ok', '?')));
end
$fn$;

-- ── register them ──────────────────────────────────────────────────────────
-- required=false on purpose: a journey earns `required` by passing GREEN TWICE
-- (dev_journeys_run promotes it), never by being declared important.
insert into public.dev_journeys (name, area, kind, steps, assertions, required, enabled)
values
  ('c705-kyc-pharmacy-chain','pharmacy','api',
   jsonb_build_array('register through submit_registration(pharmacy)',
                     'approval refused with no verified licence',
                     'upload the drug licence',
                     'ordering blocked while it is pending',
                     'admin verifies it from the review queue',
                     'approval now succeeds and ordering opens'),
   jsonb_build_array('_journey_c705_kyc_pharmacy_chain'), false, true),
  ('c705-kyc-reject-reason','pharmacy','api',
   jsonb_build_array('a rejection with no reason is refused',
                     'a rejection with a reason is recorded',
                     'the applicant panel prints that reason',
                     'the WhatsApp template carries it too'),
   jsonb_build_array('_journey_c705_kyc_reject_reason'), false, true),
  ('c705-kyc-expiry-block','pharmacy','api',
   jsonb_build_array('a licence six days out sends the 7-day reminder once',
                     'a second sweep is silent',
                     'on expiry the sweep reports it and the gate blocks',
                     'the renewal upload lifts the block'),
   jsonb_build_array('_journey_c705_kyc_expiry_block'), false, true),
  ('c705-kyc-supplier-token','pharmacy','api',
   jsonb_build_array('an unverified supplier is not asked',
                     'approval is refused',
                     'the public token page uploads with no session',
                     'verify then approve, and the waterfall asks it again'),
   jsonb_build_array('_journey_c705_kyc_supplier_token'), false, true)
on conflict (name) do update
  set area = excluded.area, steps = excluded.steps,
      assertions = excluded.assertions, enabled = true;
