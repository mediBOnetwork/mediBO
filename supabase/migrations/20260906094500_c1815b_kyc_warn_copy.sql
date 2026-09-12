-- replay-target: production
-- CMD #1815 (part 2) — the WARNING must not talk about ordering either.
--
-- kyc_gate's warn_message reused the block_* copy, so a chip tap on a pending
-- licence still read "Ordering opens as soon as it is verified" — a sentence
-- that is no longer true and is the exact promise #1815 exists to withdraw.
-- The block_* copy stays for the paths that CAN still block (approving an
-- account, and a supplier being asked for quotes); the warn path gets its own
-- words, none of which mention ordering at all.
--
-- Idempotent.

insert into public.ui_copy(key, value) values
  ('kyc_gate.warn_missing',  to_jsonb('Your drug licence is not on file yet. Upload it when you can — we verify it once.'::text)),
  ('kyc_gate.warn_pending',  to_jsonb('Your drug licence is with us for verification.'::text)),
  ('kyc_gate.warn_rejected', to_jsonb('Your drug licence was rejected. Please upload a corrected copy.'::text)),
  ('kyc_gate.warn_expired',  to_jsonb('Your drug licence has expired. Upload the renewed licence when you can.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function public.kyc_gate(p_owner_kind text, p_owner_id uuid,
                                           p_action text default 'trade')
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  st jsonb := public.kyc_state(p_owner_kind, p_owner_id);
  v_state text; v_blocked boolean; v_msg text; v_warn text; v_kind text;
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
    -- The BLOCK copy — "Ordering opens as soon as it is verified" — is only
    -- ever read on a path that actually blocks, which for a pharmacy is none.
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

  v_warn := case v_state
              when 'verified' then ''
              when 'pending'  then public._c('kyc_gate.warn_pending')
              when 'rejected' then public._c('kyc_gate.warn_rejected')
              when 'expired'  then public._c('kyc_gate.warn_expired')
              else public._c('kyc_gate.warn_missing') end;

  return jsonb_build_object(
    'allowed', not v_blocked,
    'blocked', v_blocked,
    'warn',    (v_state <> 'verified'),
    'reason',  case when v_blocked then 'kyc_'||v_state
                    when v_state <> 'verified' then 'warn_'||v_state
                    else 'none' end,
    'title',   case when v_blocked then public._c('kyc_gate.block_title') else '' end,
    'message', case when v_blocked then v_msg else '' end,
    'warn_message', v_warn,
    'action_label', public._c('kyc_gate.action_label'),
    'action_route', public._c('kyc_gate.action_route'),
    'grace_note', '',
    'state', st);
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
      and coalesce(v_gate->'kyc'->>'reason','') = 'warn_rejected';

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
