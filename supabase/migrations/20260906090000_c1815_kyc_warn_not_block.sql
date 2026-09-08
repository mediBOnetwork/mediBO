-- replay-target: production
-- Everything here is production-side: the customer's cart gate, the KYC chip
-- and the My Account profile tab. It names ui_copy and feature_registry, which
-- exist on BOTH databases, so the table-name heuristic would route it to the
-- control plane too — where public.my_customer_id() does not exist and batch
-- 596 died on it (CHANGE #637's counterexample, in the other direction).
-- CMD #1815 — KYC WARNS, IT NEVER BLOCKS ORDERING.
--
-- mediBO is in its onboarding phase: a human reads every document before an
-- account is approved, so APPROVAL is already the decision about who may
-- trade. #705 then added a second, automatic decision on top of it — a
-- verified drug-licence DOCUMENT — with a grace window that expires. On
-- Chandra Medicom's cart that surfaced as a full-width yellow card,
-- "Upload your drug licence before 17 Sep 2026 to keep ordering", counting
-- down to the day an already-approved pharmacy would stop being able to buy.
--
-- That is the wrong order of operations for a business that verifies by hand.
-- The document requirement stays — it is asked for at APPROVAL, and it is
-- shown as a warning afterwards — but it never stops an approved customer
-- from placing an order again. The rule now lives at the SOURCE (kyc_gate),
-- not only on the button, so a future caller cannot re-introduce the block by
-- reading the same function.
--
-- Idempotent: every statement is CREATE OR REPLACE or an upsert.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. COPY. The chip's words, and the route that actually exists.
-- ─────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('kyc_chip.missing',   to_jsonb('KYC missing'::text)),
  ('kyc_chip.pending',   to_jsonb('KYC in review'::text)),
  ('kyc_chip.rejected',  to_jsonb('KYC rejected'::text)),
  ('kyc_chip.expired',   to_jsonb('Licence expired'::text)),
  ('kyc_chip.action',    to_jsonb('View'::text)),
  -- #705 shipped action_route '/account/kyc', a path this app has never had a
  -- route for, so "Upload licence" opened nothing. The chip carries a
  -- structured descriptor now (route_key + tab_key + section); this string
  -- stays only so an older build has something honest to print.
  ('kyc_gate.action_route', to_jsonb('cust_account'::text)),
  ('acct.p_account',     to_jsonb('Account'::text)),
  ('acct.p_docs_title',  to_jsonb('Documents on file'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────
-- 2. kyc_gate — a pharmacy TRADING is never blocked by a document.
--
-- 'approve' is untouched: approving an account today is a NEW decision and it
-- still needs the licence on file. A SUPPLIER is untouched too — that gate
-- answers "do we ask this supplier for a quote?", which is not a customer
-- placing an order.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.kyc_gate(p_owner_kind text, p_owner_id uuid,
                                           p_action text default 'trade')
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  st jsonb := public.kyc_state(p_owner_kind, p_owner_id);
  v_state text; v_blocked boolean; v_msg text; v_kind text;
begin
  if not coalesce((st->>'ok')::boolean, false) then
    return jsonb_build_object('allowed', true, 'blocked', false, 'reason','unknown_owner',
                              'title','', 'message','', 'warn', false, 'state', st);
  end if;
  v_state := st->>'state';
  v_kind  := lower(btrim(coalesce(p_owner_kind,'')));

  if lower(coalesce(p_action,'trade')) = 'approve' then
    v_blocked := coalesce((st->>'enforce')::boolean, true) and v_state <> 'verified';
    v_msg := public._c('kyc_gate.approve_blocked');
  else
    v_msg := case v_state
               when 'pending'  then public._c('kyc_gate.block_pending')
               when 'rejected' then public._c('kyc_gate.block_rejected')
               when 'expired'  then public._c('kyc_gate.block_expired')
               else public._c('kyc_gate.block_missing') end;
    -- CMD #1815 — a PHARMACY is never blocked from trading by this gate.
    -- Approval decides that, and approval already happened by hand.
    v_blocked := (v_kind <> 'pharmacy')
                 and coalesce((st->>'enforce')::boolean, true)
                 and v_state <> 'verified'
                 and not coalesce((st->>'in_grace')::boolean, false);
  end if;

  return jsonb_build_object(
    'allowed', not v_blocked,
    'blocked', v_blocked,
    -- The document is still not clear even when nothing is blocked: `warn` is
    -- what the chip reads, and it is the ONLY thing a trading surface may act
    -- on for a pharmacy.
    'warn',    (v_state <> 'verified'),
    'reason',  case when v_blocked then 'kyc_'||v_state
                    when v_state <> 'verified' then 'warn_'||v_state
                    else 'none' end,
    'title',   case when v_blocked then public._c('kyc_gate.block_title') else '' end,
    'message', case when v_blocked then v_msg else '' end,
    'warn_message', case when v_state <> 'verified' then v_msg else '' end,
    'action_label', public._c('kyc_gate.action_label'),
    'action_route', public._c('kyc_gate.action_route'),
    -- No countdown, ever. The grace window still exists for the SUPPLIER
    -- gate's arithmetic, but nothing renders "…before <date> to keep ordering"
    -- to a customer any more.
    'grace_note', '',
    'state', st);
end
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. kyc_chip_block — the ONE small chip, used everywhere a KYC state shows.
--
-- `action` is a descriptor, not a path: route_key names the customer screen,
-- tab_key the tab inside it and section the block to land on. Every surface
-- that shows this chip lands on the SAME upload section.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.kyc_chip_block(p_customer uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare st jsonb; v_state text; v_tone text; v_label text;
begin
  -- A guest, or an id that is not a pharmacy at all, has no KYC state to
  -- report. kyc_state() answers 'missing' for a row that does not exist, so
  -- without this the cart would offer a signed-out visitor a KYC chip.
  if p_customer is null
     or not exists (select 1 from public.pharmacy_profiles where id = p_customer) then
    return jsonb_build_object('has', false, 'state', '');
  end if;
  st := public.kyc_state('pharmacy', p_customer);
  -- The chip follows the DOCUMENT STATE, not `enforce`. `enforce` was the
  -- answer to "do we BLOCK this account?", and after #1815 a pharmacy is never
  -- blocked, so reading it here would only mean a synthetic fixture's cart
  -- looked different from a real one — and the fixture carts are what the
  -- proofs are taken from.
  if not coalesce((st->>'ok')::boolean, false) then
    return jsonb_build_object('has', false, 'state', coalesce(st->>'state',''));
  end if;
  v_state := coalesce(st->>'state','');
  if v_state = 'verified' then
    return jsonb_build_object('has', false, 'state', v_state);
  end if;

  v_label := case v_state
               when 'pending'  then public._c('kyc_chip.pending')
               when 'rejected' then public._c('kyc_chip.rejected')
               when 'expired'  then public._c('kyc_chip.expired')
               else public._c('kyc_chip.missing') end;
  v_tone := case v_state when 'rejected' then 'danger'
                         when 'expired'  then 'danger'
                         when 'pending'  then 'info'
                         else 'warning' end;

  return jsonb_build_object(
    'has',   (v_label <> ''),
    'state', v_state,
    'label', v_label,
    'tone',  jsonb_build_object(
      'bg',     case v_tone when 'danger' then '#FEE2E2' when 'info' then '#EFF6FF' else '#FEF3C7' end,
      'fg',     case v_tone when 'danger' then '#991B1B' when 'info' then '#1E40AF' else '#92400E' end,
      'border', case v_tone when 'danger' then '#FECACA' when 'info' then '#BFDBFE' else '#FDE68A' end),
    'action', jsonb_build_object(
      'has',       true,
      'label',     public._c('kyc_chip.action'),
      'kind',      'customer_route',
      'route_key', 'cust_account',
      'tab_key',   'profile',
      'section',   'kyc'));
end
$function$;

-- The chip for the signed-in customer, so every other surface asks ONE
-- question and prints ONE answer.
create or replace function public.kyc_chip()
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select public.kyc_chip_block(public.my_customer_id());
$function$;

grant execute on function public.kyc_chip_block(uuid) to anon, authenticated, service_role;
grant execute on function public.kyc_chip() to anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. cart_rx_gate — the cart's answer, with the block taken out of it.
--
-- can_order is now APPROVAL's answer alone (my_session().can_place_order owns
-- that), so this returns can_order:true / blocked:false for a customer and
-- carries the licence state as information. The rx 'block' mode setting no
-- longer reaches an order either: it warns.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.cart_rx_gate(p_customer uuid, p_items jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_rx   int := 0;
  v_lic  jsonb := public.rx_licence_state(p_customer);
  v_title text := ''; v_msg text := '';
  v_kyc  jsonb;
  v_chip jsonb;
begin
  select count(*) into v_rx
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) it
    join "MEDICINE" m on m.id = (case when (it->>'product_id') ~ '^[0-9]+$'
                                    then (it->>'product_id')::bigint end)
   where upper(btrim(coalesce(m.rx_required,''))) = 'RX';

  if v_rx > 0 and not coalesce((v_lic->>'has')::boolean, false) then
    if (v_lic->>'reason') = 'expired' then
      v_title := public._c('rx.licence_expired_title');
      v_msg   := public._cf('rx.licence_expired_msg',
                   jsonb_build_object('date', to_char((v_lic->>'expiry')::date, 'DD Mon YYYY')));
    else
      v_title := public._c('rx.licence_missing_title');
      v_msg   := case when v_rx = 1
                      then public._c('rx.licence_missing_msg_one')
                      else public._cf('rx.licence_missing_msg_many',
                             jsonb_build_object('count', v_rx::text)) end;
    end if;
  end if;

  v_kyc  := public.kyc_gate('pharmacy', p_customer, 'trade');
  v_chip := public.kyc_chip_block(p_customer);

  if v_msg = '' and coalesce(v_kyc->>'warn_message','') <> '' then
    v_msg := v_kyc->>'warn_message';
  end if;

  return jsonb_build_object(
    'has',        (v_rx > 0),
    'rx_count',   v_rx,
    'rx_note',    case when v_rx = 0 then ''
                       when v_rx = 1 then public._c('rx.cart_rx_note_one')
                       else public._cf('rx.cart_rx_note_many',
                              jsonb_build_object('count', v_rx::text)) end,
    'licence',    v_lic,
    'kyc',        v_kyc,
    'chip',       v_chip,
    -- CMD #1815 — the two constants this command exists to make constant.
    'can_order',  true,
    'blocked',    false,
    'is_warning', (v_msg <> ''),
    'title',      v_title,
    'message',    v_msg,
    'tone',       case when v_msg <> '' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                       else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end);
end
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. cart_notice_block — a WARNING is a chip, never a full-width card.
--
-- The big card is reserved for something that actually stops the order. After
-- #1815 a licence never does, so the cart carries the small chip and the rx
-- record line, and nothing else.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.cart_notice_block(p_rx jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_msg    text    := coalesce(p_rx->>'message','');
  v_reason text    := coalesce(p_rx->'licence'->>'reason','');
  v_block  boolean := coalesce((p_rx->>'blocked')::boolean, false);
  v_chip   jsonb   := coalesce(p_rx->'chip', jsonb_build_object('has', false));
  v_label  text;
begin
  if not v_block then
    -- The record line ("2 prescription items in this order") stays: it is a
    -- caption, not a notice.
    return jsonb_build_object('has', false, 'blocking', false,
      'title', '', 'message', '',
      'note', coalesce(p_rx->>'rx_note',''),
      'chip', v_chip,
      'action', jsonb_build_object('has', false));
  end if;

  v_label := case when v_reason = 'expired'
                  then public._c('cart.notice_renew_licence')
                  else public._c('cart.notice_add_licence') end;

  return jsonb_build_object(
    'has',      true,
    'blocking', true,
    'kind',     'drug_licence',
    'title',    coalesce(p_rx->>'title',''),
    'message',  v_msg,
    'note',     '',
    'chip',     v_chip,
    'tone',     coalesce(p_rx->'tone', jsonb_build_object('bg','#FEE2E2','fg','#991B1B')),
    'action',   jsonb_build_object(
                  'has',       (v_label <> ''),
                  'label',     v_label,
                  'kind',      'customer_route',
                  'route_key', 'cust_account',
                  'tab_key',   'profile',
                  'section',   'kyc'));
end
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. my_account_tab_profile — ONE profile screen.
--
-- The tab used to print the shop's details READ-ONLY and then send the
-- customer to a second screen to edit the same fields. The editable form
-- (my_profile_edit / my_profile_save, driven by customer_profile_field) is now
-- embedded here and that second screen is gone. Licence numbers and GSTIN stay
-- locked with their own "contact support" note — that note is the field row's,
-- not this function's.
--
-- The documents list also read owner_kind='customer'; kyc_upload_register
-- writes 'pharmacy' (kyc_owner_for_me), so it was permanently empty.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.my_account_tab_profile()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  pp public.pharmacy_profiles%rowtype;
  v_kyc jsonb; v_zone text; v_docs jsonb;
begin
  pp := public._acct840_me();
  if pp.id is null then return public._acct840_deny(); end if;

  v_kyc  := public._cus810_kyc(pp.id, pp.gstin, pp.gst_no);
  v_zone := (select z.name from public.zones z where z.id = pp.zone_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'title',    coalesce(nullif(d.file_name,''), initcap(replace(d.kind,'_',' '))),
           'subtitle', initcap(replace(d.kind,'_',' '))
                       || case when coalesce(d.number,'') <> '' then '  ·  '||d.number else '' end,
           'meta',     case when d.valid_to is null then ''
                            else to_char(d.valid_to,'FMDD Mon YYYY') end,
           'chip',     public._acct840_chip(
                         initcap(replace(coalesce(d.status,'pending'),'_',' ')),
                         case when coalesce(d.status,'') in ('verified','approved') then
                                case when d.valid_to is not null and d.valid_to < current_date
                                     then 'danger' else 'success' end
                              when coalesce(d.status,'') in ('rejected') then 'danger'
                              else 'warning' end))
         order by d.created_at desc), '[]'::jsonb)
    into v_docs
    from public.kyc_documents d
   where d.owner_kind in ('pharmacy','customer') and d.owner_id = pp.id;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    -- The facts that are NOT editable anywhere: who this account is to us.
    jsonb_build_object('kind','kv','title', public._c('acct.p_account'),
      'section','account',
      'chip', v_kyc->'chip',
      'rows', jsonb_build_array(
        jsonb_build_object('label', public._c('acct.p_code'), 'value', public._acct840_v(pp.customer_code)),
        jsonb_build_object('label', public._c('acct.p_zone'), 'value', public._acct840_v(v_zone)),
        jsonb_build_object('label', public._c('acct.p_term'), 'value', public._acct840_v(pp.payment_term)))),
    -- THE editor. Sections, fields, locks and every validation message are
    -- my_profile_edit()/my_profile_save()'s.
    jsonb_build_object('kind','embed','widget','profile_form','section','profile'),
    jsonb_build_object('kind','list','title', public._c('acct.p_docs_title'),
                       'section','documents',
                       'empty', public._c('acct.p_docs_note'), 'items', v_docs),
    jsonb_build_object('kind','embed','widget','kyc_panel','section','kyc')));
end
$function$;

-- The duplicate entry point on the account menu is retired for good. The row
-- is already inactive; this makes it so on every environment the file reaches.
update public.customer_feature_placement cp
   set is_active = false
  from public.feature_registry f
 where f.feature_key = cp.feature_key
   and f.route_key = 'cust_profile_edit';

-- ─────────────────────────────────────────────────────────────────────────
-- 7. The journey probes that held the OLD contract down move to the new one.
--    #705's chain still proves the fence, the queue, the review and the
--    approval gate; what it no longer proves is a customer being stopped from
--    buying, because that is the behaviour this command removes.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._journey_c705_kyc_pharmacy_chain()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- CMD #1815 — an unverified pharmacy is WARNED, never blocked.
      and not coalesce((v_gate0->>'blocked')::boolean,true)
      and coalesce((v_gate0->>'can_order')::boolean,false)
      and coalesce((v_gate0->'chip'->>'has')::boolean,false)
      and coalesce(v_gate0->'chip'->'action'->>'route_key','') = 'cust_account'
      and coalesce(v_gate0->'chip'->'action'->>'section','') = 'kyc'
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
   || ' | chip='||coalesce(v_gate0->'chip'->>'label','?')
   || ' -> '||coalesce(v_gate0->'chip'->'action'->>'route_key','?')
        ||'/'||coalesce(v_gate0->'chip'->'action'->>'section','?')
   || ' | ordering blocked while pending='||coalesce(v_gate0->>'blocked','?')
   || ' -> '||coalesce(v_gate0->>'message','')
   || ' | document in the review queue='||v_in_queue::text
   || ' | verify ok='||coalesce(v_ver->>'ok','?')
   || ' state='||coalesce(v_ver->'owner_state'->>'state','?')
   || ' | approve after verification ok='||coalesce(v_appr->>'ok','?')
   || ' approved='||v_approved::text
   || ' | ordering blocked after verification='||coalesce(v_gate1->>'blocked','?')));
end
$function$;

CREATE OR REPLACE FUNCTION public._journey_c705_kyc_expiry_block()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- CMD #1815 — an expired licence warns; it does not stop an
      -- approved pharmacy from ordering.
      and not coalesce((v_gate_exp->>'blocked')::boolean,true)
      and coalesce((v_gate_exp->>'warn')::boolean,false)
      and coalesce(v_gate_exp->>'reason','') = 'warn_expired'
      and coalesce(v_gate_exp->>'grace_note','') = ''
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
$function$;

CREATE OR REPLACE FUNCTION public._journey_c705_kyc_reject_reason()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- CMD #1815 — a rejected licence warns; ordering stays open.
      and not coalesce((v_gate->>'blocked')::boolean,true)
      and coalesce(v_gate->'chip'->>'state','') = 'rejected'
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
$function$;
