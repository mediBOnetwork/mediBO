-- CMD #453 — HIGH severity delivery defects, batch A (feature_gaps 90–98).
-- Every statement is idempotent: a resumed worker may re-apply this file.

-- ── columns ──────────────────────────────────────────────────────────────────
alter table public.delivery_partner_registrations add column if not exists review_reason text;
alter table public.delivery_partner_registrations add column if not exists invite_code   text;
alter table public.delivery_partner_registrations add column if not exists invited_at    timestamptz;
alter table public.delivery_partner_registrations add column if not exists claimed_at    timestamptz;
create unique index if not exists delivery_partner_reg_invite_code_uidx
  on public.delivery_partner_registrations(invite_code) where invite_code is not null;

alter table public.delivery_action_log add column if not exists attempts    integer not null default 0;
alter table public.delivery_action_log add column if not exists last_result jsonb;
alter table public.delivery_action_log add column if not exists updated_at  timestamptz not null default now();

-- ── GAP 90/91 — one ownership predicate, used by every run write ─────────────
create or replace function public._delivery_run_owned(p_run_id uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public._is_admin()
      or exists (select 1
                   from delivery_runs r
                   join delivery_partner_registrations p on p.id = r.partner_id
                  where r.id = p_run_id
                    and p.user_id = auth.uid()
                    and coalesce(p.is_deleted,false) = false);
$$;

-- The sequencer itself, with no caller check: this is the INTERNAL entry point
-- that delivery_start_run uses after it has already proved ownership.
create or replace function public._delivery_optimize_run_unchecked(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_seq int := 0; v_grp int := 0; r record; v_cur_lat numeric; v_cur_lng numeric; v_partner uuid;
begin
  select partner_id into v_partner from delivery_runs where id = p_run_id;
  if v_partner is null then return jsonb_build_object('ok',false,'error','run_not_found'); end if;

  select lat, lng into v_cur_lat, v_cur_lng
    from delivery_partner_locations where partner_id = v_partner;

  update deliveries set stop_group = null, seq = null
   where run_id = p_run_id and status not in ('delivered','cancelled');

  for r in
    select id, lat, lng from deliveries
     where run_id = p_run_id and status not in ('delivered','cancelled')
     order by lat nulls last, lng
  loop
    if (select stop_group from deliveries where id = r.id) is not null then continue; end if;
    v_grp := v_grp + 1;
    update deliveries set stop_group = v_grp
     where run_id = p_run_id and stop_group is null
       and status not in ('delivered','cancelled')
       and (id = r.id
            or (r.lat is not null and lat is not null
                and public._geo_m(r.lat, r.lng, lat, lng) <= 150));
  end loop;

  if v_cur_lat is null then
    select lat, lng into v_cur_lat, v_cur_lng from deliveries
     where run_id = p_run_id and lat is not null limit 1;
  end if;

  loop
    select d.stop_group AS stop_group, min(d.lat) AS lat, min(d.lng) AS lng into r
    from deliveries d
    where d.run_id = p_run_id and d.seq is null and d.stop_group is not null
      and d.status not in ('delivered','cancelled')
    group by d.stop_group
    order by coalesce(public._geo_m(v_cur_lat, v_cur_lng, min(d.lat), min(d.lng)), 1e12), d.stop_group
    limit 1;
    exit when r.stop_group is null;
    v_seq := v_seq + 1;
    update deliveries set seq = v_seq where run_id = p_run_id and stop_group = r.stop_group;
    v_cur_lat := r.lat; v_cur_lng := r.lng;
  end loop;

  -- CHANGE #309 (10): cold-chain stops re-rank to the front of the finished route.
  with ranked as (
    select d.stop_group,
           bool_or(d.is_cold_chain) cold,
           min(d.seq) cur_seq
      from deliveries d
     where d.run_id = p_run_id and d.seq is not null
       and d.status not in ('delivered','cancelled')
     group by d.stop_group),
  renum as (
    select stop_group,
           row_number() over (order by cold desc, cur_seq) new_seq
      from ranked)
  update deliveries d
     set seq = r.new_seq
    from renum r
   where d.run_id = p_run_id and d.stop_group = r.stop_group
     and d.status not in ('delivered','cancelled');

  update delivery_runs
     set optimized_at = now(),
         total_stops = (select count(distinct stop_group) from deliveries where run_id = p_run_id)
   where id = p_run_id;

  return jsonb_build_object('ok',true,'run_id',p_run_id,'stops',v_seq,'method','nearest_neighbour');
end $$;

-- GAP 90: the PUBLIC entry point now carries the same guard delivery_apply_google
-- has always had. A run uuid is no longer a capability.
create or replace function public.delivery_optimize_run(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists(select 1 from delivery_runs where id = p_run_id) then
    return jsonb_build_object('ok',false,'error','run_not_found');
  end if;
  if not public._delivery_run_owned(p_run_id) then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public.uic('delivery.not_your_run','This trip belongs to another rider.'));
  end if;
  return public._delivery_optimize_run_unchecked(p_run_id);
end $$;

-- GAP 91a: a supplied p_run_id must belong to the caller.
create or replace function public.delivery_start_run(p_run_id uuid DEFAULT NULL::uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_run uuid; v_partner uuid; r record; v_n int := 0;
begin
  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_a_partner');
  end if;
  select coalesce(p_run_id, (select id from delivery_runs
      where partner_id=v_partner and run_date=(now() at time zone 'Asia/Kolkata')::date
        and status in ('planned','started') order by created_at desc limit 1)) into v_run;
  if v_run is null then return jsonb_build_object('ok',false,'error','no_run','message','No deliveries assigned yet.'); end if;
  if not public._delivery_run_owned(v_run) then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public.uic('delivery.not_your_run','This trip belongs to another rider.'));
  end if;

  update delivery_runs set status='started', started_at=coalesce(started_at,now()) where id=v_run;
  update deliveries set status='out_for_delivery', started_at=coalesce(started_at,now())
   where run_id=v_run and status='assigned' and accept_status='accepted';
  perform public._delivery_optimize_run_unchecked(v_run);

  for r in select id, order_id from deliveries
            where run_id = v_run and status = 'out_for_delivery'
  loop
    begin
      perform public.wa_notify_event(
        'delivery_out', null, '{}'::jsonb, null, r.order_id,
        'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
        jsonb_build_object('event','out_one','delivery_id', r.id));
      v_n := v_n + 1;
    exception when others then
      perform public._wa_log_attempt('delivery_out', r.order_id, null, 'skipped', false,
                                     'caller_error: ' || sqlerrm);
    end;
  end loop;

  return jsonb_build_object('ok',true,'run_id',v_run,'notified',v_n,'message','Trip started');
end $$;

-- GAP 91b: finishing someone else's run marked their open parcels 'rto'.
create or replace function public.delivery_finish_run(p_run_id uuid DEFAULT NULL::uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_run uuid; v_partner uuid; v_left int;
begin
  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  select coalesce(p_run_id, (select id from delivery_runs
      where partner_id=v_partner and status='started' order by created_at desc limit 1)) into v_run;
  if v_run is null then return jsonb_build_object('ok',false,'error','no_run'); end if;
  if not public._delivery_run_owned(v_run) then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public.uic('delivery.not_your_run','This trip belongs to another rider.'));
  end if;

  select count(*) into v_left from deliveries
   where run_id=v_run and status in ('assigned','out_for_delivery');
  update delivery_runs set status='completed', completed_at=now() where id=v_run;
  update deliveries set status='rto', rto_at=now()
   where run_id=v_run and status in ('assigned','out_for_delivery');

  return jsonb_build_object('ok',true,'run_id',v_run,'returned',v_left,
    'message', case when v_left=0 then 'Trip completed'
                    else 'Trip completed — ' || v_left || ' parcel(s) marked for return' end);
end $$;

revoke execute on function public.delivery_optimize_run(uuid) from anon;
revoke execute on function public.delivery_start_run(uuid)    from anon;
revoke execute on function public.delivery_finish_run(uuid)   from anon;

-- ── the in-app notification helper the delivery surface uses ────────────────
create or replace function public._delivery_inbox(
  p_user_id uuid, p_recipient text, p_event_key text,
  p_title text, p_body text, p_deep_link text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if p_user_id is null and nullif(btrim(coalesce(p_recipient,'')),'') is null then return; end if;
  insert into notification_log(event_key, recipient, channel, status, ok, user_id,
                               recipient_id, title, body, deep_link, audience, cost)
  values (p_event_key,
          coalesce(nullif(btrim(coalesce(p_recipient,'')),''), p_user_id::text),
          'inapp', 'sent', true, p_user_id, p_user_id,
          p_title, p_body, p_deep_link, 'delivery', 0);
exception when others then
  -- a notification must never roll back the write it reports on
  null;
end $$;

-- ── GAP 94 — delivery_replay: claim the key, cache only a success ───────────
-- Two concurrent retries of one client_action_id used to BOTH see an empty log
-- and BOTH execute the underlying action. The advisory lock is taken on the key
-- itself, so the second retry waits for the first to commit and then reads its
-- result instead of repeating it. And a transient ok:false is no longer frozen
-- into the log forever: only ok:true is cached, so a retry can still succeed.
create or replace function public.delivery_replay(p_client_action_id text, p_action text, p_payload jsonb DEFAULT '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_prev jsonb; v_res jsonb; v_partner uuid; v_did uuid; v_key text; v_ok boolean;
begin
  v_key := nullif(btrim(coalesce(p_client_action_id,'')),'');
  if v_key is null then
    return jsonb_build_object('ok',false,'error','client_action_id_required');
  end if;

  -- serialise every caller of THIS key for the life of this transaction
  perform pg_advisory_xact_lock(hashtext('delivery_replay:' || v_key));

  select result into v_prev from delivery_action_log
   where client_action_id = v_key and result is not null;
  if v_prev is not null then
    return v_prev || jsonb_build_object('replayed', true);
  end if;

  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and is_active and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_a_partner');
  end if;

  v_did := nullif(p_payload->>'delivery_id','')::uuid;

  v_res := case lower(coalesce(p_action,''))
    when 'scan_qr' then public.delivery_scan_qr(
        p_payload->>'token',
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric)
    when 'verify_otp' then public.delivery_verify_otp(
        v_did, p_payload->>'code',
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric,
        p_payload->>'receiver')
    when 'mark_delivered' then public.delivery_mark_delivered(
        v_did, p_payload->>'photo_path', p_payload->>'receiver',
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric)
    when 'fail' then public.delivery_fail(
        v_did, p_payload->>'reason_code', p_payload->>'note',
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric)
    when 'partial' then public.delivery_partial(
        v_did, nullif(p_payload->>'delivered_qty','')::int,
        nullif(p_payload->>'returned_qty','')::int, p_payload->>'note',
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric,
        p_payload->>'photo_path', p_payload->>'receiver')
    when 'signature' then public.delivery_attach_signature(
        v_did, p_payload->>'signature_path', p_payload->>'receiver',
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric)
    when 'shift' then public.delivery_shift(
        p_payload->>'shift_action',
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric)
    when 'location' then public.delivery_update_location(
        nullif(p_payload->>'lat','')::numeric, nullif(p_payload->>'lng','')::numeric,
        nullif(p_payload->>'heading','')::numeric, nullif(p_payload->>'accuracy','')::numeric)
    else jsonb_build_object('ok',false,'error','unknown_action','action',p_action)
  end;

  v_ok := coalesce((v_res->>'ok')::boolean, false);

  insert into delivery_action_log(client_action_id, partner_id, delivery_id, action, payload,
                                  result, last_result, attempts, updated_at)
  values (v_key, v_partner, v_did, lower(coalesce(p_action,'')), p_payload,
          case when v_ok then v_res end, v_res, 1, now())
  on conflict (client_action_id) do update
     set result      = coalesce(delivery_action_log.result, excluded.result),
         last_result = excluded.last_result,
         payload     = excluded.payload,
         attempts    = delivery_action_log.attempts + 1,
         updated_at  = now();

  return coalesce(v_res,'{}'::jsonb) || jsonb_build_object('replayed', false);
end $$;

-- ── GAP 92 — a signature is a COMPLETION method, not a note ─────────────────
drop function if exists public.delivery_attach_signature(uuid, text, text);
create or replace function public.delivery_attach_signature(
  p_delivery_id uuid, p_signature_path text, p_receiver text DEFAULT NULL::text,
  p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d deliveries%rowtype; v_res jsonb;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid())
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if nullif(btrim(coalesce(p_signature_path,'')),'') is null then
    return jsonb_build_object('ok',false,'error','signature_required',
      'message', public.uic('delivery.signature_required','Capture the signature first.'));
  end if;

  update deliveries
     set signature_path = p_signature_path,
         receiver_name  = coalesce(nullif(btrim(coalesce(p_receiver,'')),''), receiver_name)
   where id = p_delivery_id;
  insert into delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'signature',
          nullif(btrim(coalesce(p_receiver,'')),''), p_lat, p_lng,
          coalesce(auth.jwt()->>'email','rider'));

  -- the same choke point the photo and OTP methods use: custody, cold-chain and
  -- the delivered notification are all decided in there, once, for every method.
  v_res := public._delivery_complete(p_delivery_id, 'signature', p_lat, p_lng, p_receiver, null);
  return coalesce(v_res, '{}'::jsonb) || jsonb_build_object('signature_saved', true);
end $$;

-- ── GAP 96 — the review decision now carries a reason and tells the applicant ─
drop function if exists public.admin_review_registration(text, uuid, text);
create or replace function public.admin_review_registration(
  p_kind text, p_id uuid, p_status text, p_reason text DEFAULT NULL::text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_role text := coalesce(public.get_my_role(), 'none');
  v_uid uuid := auth.uid(); v_table text; v_found int; v_reason text;
  v_has_reason boolean; d delivery_partner_registrations%rowtype;
begin
  if v_role not in ('admin','super_admin') then
    raise exception 'forbidden' using hint = 'Only an admin may review a registration.';
  end if;
  v_table := case p_kind
               when 'mr' then 'mr_registrations'
               when 'company' then 'company_profiles'
               when 'delivery_partner' then 'delivery_partner_registrations'
               else null end;
  if v_table is null then raise exception 'unknown_registration_kind: %', p_kind; end if;
  v_reason := nullif(btrim(coalesce(p_reason,'')),'');

  select exists(select 1 from information_schema.columns
                 where table_schema='public' and table_name=v_table and column_name='review_reason')
    into v_has_reason;

  if v_has_reason then
    execute format(
      'update %I set status = %L, reviewed_by = %L::uuid, reviewed_at = now(), review_reason = %L where id = %L',
      v_table, p_status, v_uid, v_reason, p_id);
  else
    execute format(
      'update %I set status = %L, reviewed_by = %L::uuid, reviewed_at = now() where id = %L',
      v_table, p_status, v_uid, p_id);
  end if;
  get diagnostics v_found = row_count;
  if v_found = 0 then raise exception 'registration_not_found: %/%', p_kind, p_id; end if;

  -- tell the applicant what happened to their application
  if p_kind = 'delivery_partner' then
    select * into d from delivery_partner_registrations where id = p_id;
    perform public._delivery_inbox(
      d.user_id, coalesce(d.email, d.phone), 'delivery_partner_' || lower(coalesce(p_status,'reviewed')),
      case lower(coalesce(p_status,''))
        when 'approved' then public.uic('delivery.reg_approved_title','Your rider application is approved')
        when 'rejected' then public.uic('delivery.reg_rejected_title','Your rider application was not accepted')
        else public.uic('delivery.reg_reviewed_title','Your rider application was reviewed') end,
      coalesce(v_reason,
        case lower(coalesce(p_status,''))
          when 'approved' then public.uic('delivery.reg_approved_body','You can start taking deliveries once an admin activates you.')
          when 'rejected' then public.uic('delivery.reg_rejected_body','No reason was recorded.')
          else '' end),
      '/delivery-register');
  end if;

  return jsonb_build_object('ok', true, 'kind', p_kind, 'id', p_id::text,
    'status', p_status,
    'reason', coalesce(v_reason,''),
    'reviewed_by', coalesce(v_uid::text,''),
    'reviewed_by_email', coalesce(public.my_login_email(),''),
    'message', case lower(coalesce(p_status,''))
                 when 'approved' then public.uic('delivery.reg_approve_toast','Registration approved')
                 when 'rejected' then public.uic('delivery.reg_reject_toast','Registration rejected')
                 else public.uic('delivery.reg_reviewed_toast','Registration updated') end);
end $$;

-- GAP 96 — submitting an application now alerts every admin, and the applicant
-- gets a receipt they can read back on the status screen.
create or replace function public.delivery_partner_register(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_ocr jsonb := coalesce(p->'ocr_payload','{}'::jsonb); r record; v_name text;
begin
  if auth.uid() is not null and exists(
       select 1 from delivery_partner_registrations
        where user_id = auth.uid() and coalesce(is_deleted,false)=false
          and coalesce(status,'') <> 'rejected') then
    return jsonb_build_object('ok',false,'error','already_registered',
      'message', public.uic('delivery.reg_already','You have already applied — check the status below.'));
  end if;

  insert into delivery_partner_registrations(
    user_id, full_name, phone, email, vehicle_type, delivery_zone, address, city, state,
    id_proof_type, id_doc_type, id_doc_number, id_doc_path, ocr_payload,
    partner_type, status, is_active, submitted_at)
  values (auth.uid(),
    coalesce(nullif(btrim(coalesce(p->>'full_name','')),''), nullif(btrim(coalesce(v_ocr->>'name','')),'')),
    coalesce(nullif(btrim(coalesce(p->>'phone','')),''), nullif(btrim(coalesce(v_ocr->>'phone','')),'')),
    nullif(btrim(coalesce(p->>'email','')),''),
    nullif(btrim(coalesce(p->>'vehicle_type','')),''),
    nullif(btrim(coalesce(p->>'delivery_zone','')),''),
    coalesce(nullif(btrim(coalesce(p->>'address','')),''), nullif(btrim(coalesce(v_ocr->>'address','')),'')),
    coalesce(nullif(btrim(coalesce(p->>'city','')),''), nullif(btrim(coalesce(v_ocr->>'city','')),'')),
    coalesce(nullif(btrim(coalesce(p->>'state','')),''), nullif(btrim(coalesce(v_ocr->>'state','')),'')),
    nullif(btrim(coalesce(p->>'id_doc_type','')),''),
    nullif(btrim(coalesce(p->>'id_doc_type','')),''),
    coalesce(nullif(btrim(coalesce(p->>'id_doc_number','')),''), nullif(btrim(coalesce(v_ocr->>'id_number','')),'')),
    nullif(btrim(coalesce(p->>'id_doc_path','')),''),
    v_ocr,
    coalesce(nullif(btrim(coalesce(p->>'partner_type','')),''),'boy'),
    'pending', false, now())
  returning id, full_name into v_id, v_name;

  -- the admin alert the audit found missing: one inbox row per admin account
  for r in select a.email, u.id as uid from admins a
             left join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
  loop
    perform public._delivery_inbox(r.uid, r.email, 'delivery_partner_applied',
      public.uic('delivery.reg_admin_title','New rider application'),
      coalesce(v_name,'') , '/admin?tab=delivery');
  end loop;

  perform public._delivery_inbox(auth.uid(), null, 'delivery_partner_submitted',
    public.uic('delivery.reg_submitted_title','Application submitted'),
    public.uic('delivery.reg_submitted_body','An admin will review it and you will see the decision here.'),
    '/delivery-register');

  return jsonb_build_object('ok',true,'registration_id',v_id,
    'message', public.uic('delivery.reg_submitted_toast','Registration submitted — an admin will review it'));
end $$;

-- GAP 96 — the applicant-facing status surface. Every string is decided here.
create or replace function public.my_delivery_application()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare d delivery_partner_registrations%rowtype; v_tone text; v_status text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok',true,'has',false,'can_register',false,
      'title', public.uic('delivery.reg_title','Deliver with mediBO'),
      'signed_out', true,
      'signed_out_hint', public.uic('delivery.reg_signed_out','Sign in first, then apply to deliver.'));
  end if;

  select * into d from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false
   order by submitted_at desc limit 1;

  if d.id is null then
    return jsonb_build_object('ok',true,'has',false,'can_register',true,
      'title', public.uic('delivery.reg_title','Deliver with mediBO'),
      'invite_prompt', public.uic('delivery.invite_prompt','Added by an agency? Enter your invite code.'),
      'invite_cta', public.uic('delivery.invite_cta','Use invite code'));
  end if;

  v_status := lower(coalesce(d.status,'pending'));
  v_tone := case v_status when 'approved' then 'success'
                          when 'rejected' then 'danger'
                          else 'warning' end;

  return jsonb_build_object('ok',true,'has',true,'can_register', v_status = 'rejected',
    'title', public.uic('delivery.reg_status_title','Your rider application'),
    'status', v_status,
    'status_label', case v_status
        when 'approved' then public.uic('delivery.status_approved','Approved')
        when 'rejected' then public.uic('delivery.status_rejected','Not accepted')
        else public.uic('delivery.status_pending','Under review') end,
    'status_tone', v_tone,
    'status_message', case v_status
        when 'approved' then case when d.is_active
              then public.uic('delivery.status_approved_active','You are active — open Deliveries to see your stops.')
              else public.uic('delivery.status_approved_inactive','Approved. An admin will activate you shortly.') end
        when 'rejected' then coalesce(nullif(btrim(coalesce(d.review_reason,'')),''),
                                      public.uic('delivery.status_rejected_body','No reason was recorded.'))
        else public.uic('delivery.status_pending_body','An admin is reviewing your documents.') end,
    'name', coalesce(d.full_name,''),
    'phone', coalesce(d.phone,''),
    'partner_type', coalesce(d.partner_type,''),
    'submitted_label', public.uic('delivery.submitted_on','Submitted') || ' ' || public.ist_fmt(d.submitted_at,'date'),
    'reviewed_label', case when d.reviewed_at is null then ''
                           else public.uic('delivery.reviewed_on','Reviewed') || ' ' || public.ist_fmt(d.reviewed_at,'date') end,
    'reason', coalesce(d.review_reason,''),
    'reapply_cta', public.uic('delivery.reapply_cta','Apply again'));
end $$;

-- ── GAP 97 — an agency rider is created in the AGENCY's zone, and can log in ─
create or replace function public.agency_add_partner(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_agency delivery_partner_registrations%rowtype; v_id uuid; v_admin boolean;
  v_zone smallint; v_code text; v_phone text; v_email text; v_uid uuid; v_ph10 text;
begin
  select * into v_agency from delivery_partner_registrations
   where user_id = auth.uid() and partner_type='agency' and coalesce(is_deleted,false)=false;
  v_admin := public.get_my_role() in ('admin','super_admin');
  if v_agency.id is null and not v_admin then
    return jsonb_build_object('ok',false,'error','not_an_agency');
  end if;
  if nullif(btrim(coalesce(p->>'full_name','')),'') is null then
    return jsonb_build_object('ok',false,'error','name_required','message','Name is required');
  end if;

  -- An agency may only staff its OWN zone. The payload no longer overrides it;
  -- only an admin may place a rider in a named zone.
  v_zone := case when v_admin then coalesce((p->>'zone_id')::smallint, v_agency.zone_id)
                 else v_agency.zone_id end;

  v_phone := nullif(btrim(coalesce(p->>'phone','')),'');
  v_email := lower(nullif(btrim(coalesce(p->>'email','')),''));
  v_ph10  := right(regexp_replace(coalesce(v_phone,''), '\D', '', 'g'), 10);
  v_ph10  := nullif(v_ph10, '');
  v_code  := upper(substr(md5(gen_random_uuid()::text), 1, 8));

  -- If the rider already has a login, attach it now; otherwise the invite code
  -- below is how they attach it themselves after signing up. Either way the row
  -- stops being an account nobody can ever sign in to.
  select u.id into v_uid from auth.users u
   where (v_email is not null and lower(btrim(coalesce(u.email,''))) = v_email)
      or (v_ph10 is not null and right(regexp_replace(coalesce(u.phone,''), '\D', '', 'g'), 10) = v_ph10)
   limit 1;

  insert into delivery_partner_registrations(
    user_id, full_name, phone, email, vehicle_type, address, city, state,
    partner_type, parent_agency_id, zone_id, is_active, status,
    id_doc_type, id_doc_number, id_doc_path, ocr_payload,
    invite_code, invited_at, claimed_at, submitted_at)
  values (v_uid, btrim(p->>'full_name'), v_phone, v_email,
          nullif(btrim(coalesce(p->>'vehicle_type','')),''),
          nullif(btrim(coalesce(p->>'address','')),''), nullif(btrim(coalesce(p->>'city','')),''),
          nullif(btrim(coalesce(p->>'state','')),''),
          'boy', coalesce(v_agency.id, (p->>'parent_agency_id')::uuid),
          v_zone, true, 'approved',
          nullif(btrim(coalesce(p->>'id_doc_type','')),''),
          nullif(btrim(coalesce(p->>'id_doc_number','')),''),
          nullif(btrim(coalesce(p->>'id_doc_path','')),''),
          p->'ocr_payload',
          v_code, now(), case when v_uid is not null then now() end, now())
  returning id into v_id;

  -- the role resolver reads login_identities; register both identities we have
  if v_ph10 is not null then
    insert into login_identities(identity, kind, owner_type, owner_id)
    values (public.identity_norm(v_ph10), 'phone', 'delivery', v_id::text)
    on conflict do nothing;
  end if;
  if v_email is not null then
    insert into login_identities(identity, kind, owner_type, owner_id)
    values (public.identity_norm(v_email), 'email', 'delivery', v_id::text)
    on conflict do nothing;
  end if;

  if v_uid is not null then
    perform public._delivery_inbox(v_uid, coalesce(v_email, v_phone), 'delivery_partner_added',
      public.uic('delivery.added_title','You were added as a rider'),
      public.uic('delivery.added_body','Open Deliveries to see your stops.'), '/delivery');
  end if;

  return jsonb_build_object('ok',true,'partner_id',v_id,
    'zone_id', v_zone,
    'invite_code', v_code,
    'linked', (v_uid is not null),
    'invite_label', public.uic('delivery.invite_label','Invite code'),
    'invite_hint', case when v_uid is not null
        then public.uic('delivery.invite_linked','This rider already has a login — they can start now.')
        else public.uic('delivery.invite_unlinked','Ask the rider to sign up, open Deliver with mediBO and enter this code.') end,
    'message', public.uic('delivery.added_toast','Delivery partner added'));
end $$;

-- GAP 97 — the rider attaches their own login to the row the agency created.
create or replace function public.delivery_claim_invite(p_code text DEFAULT NULL::text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d delivery_partner_registrations%rowtype; v_code text; v_ph10 text; v_email text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok',false,'error','not_signed_in',
      'message', public.uic('delivery.invite_signin','Sign in first, then enter your invite code.'));
  end if;
  v_code := upper(nullif(btrim(coalesce(p_code,'')),''));
  v_ph10 := public.my_phone10();
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = auth.uid();

  if v_code is not null then
    select * into d from delivery_partner_registrations
     where upper(coalesce(invite_code,'')) = v_code and coalesce(is_deleted,false)=false limit 1;
  else
    select * into d from delivery_partner_registrations
     where user_id is null and coalesce(is_deleted,false)=false
       and ((v_ph10 is not null and right(regexp_replace(coalesce(phone,''), '\D','','g'),10) = v_ph10)
         or (v_email is not null and lower(btrim(coalesce(email,''))) = v_email))
     order by created_at desc limit 1;
  end if;

  if d.id is null then
    return jsonb_build_object('ok',false,'error','invite_not_found',
      'message', public.uic('delivery.invite_not_found','That code does not match any rider.'));
  end if;
  if d.user_id is not null and d.user_id <> auth.uid() then
    return jsonb_build_object('ok',false,'error','invite_taken',
      'message', public.uic('delivery.invite_taken','That code is already in use.'));
  end if;

  update delivery_partner_registrations
     set user_id = auth.uid(), claimed_at = coalesce(claimed_at, now())
   where id = d.id;

  if v_ph10 is not null then
    insert into login_identities(identity, kind, owner_type, owner_id)
    values (public.identity_norm(v_ph10), 'phone', 'delivery', d.id::text) on conflict do nothing;
  end if;
  if v_email is not null then
    insert into login_identities(identity, kind, owner_type, owner_id)
    values (public.identity_norm(v_email), 'email', 'delivery', d.id::text) on conflict do nothing;
  end if;

  return jsonb_build_object('ok',true,'partner_id',d.id,
    'message', public.uic('delivery.invite_claimed','You are linked — open Deliveries to see your stops.'));
end $$;

-- ── copy — every new string the app prints lives here, not in Dart ──────────
insert into ui_copy(key, value) values
  ('delivery.not_your_run',            to_jsonb('This trip belongs to another rider.'::text)),
  ('delivery.signature_required',      to_jsonb('Capture the signature first.'::text)),
  ('delivery.reg_approved_title',      to_jsonb('Your rider application is approved'::text)),
  ('delivery.reg_rejected_title',      to_jsonb('Your rider application was not accepted'::text)),
  ('delivery.reg_reviewed_title',      to_jsonb('Your rider application was reviewed'::text)),
  ('delivery.reg_approved_body',       to_jsonb('You can start taking deliveries once an admin activates you.'::text)),
  ('delivery.reg_rejected_body',       to_jsonb('No reason was recorded.'::text)),
  ('delivery.reg_approve_toast',       to_jsonb('Registration approved'::text)),
  ('delivery.reg_reject_toast',        to_jsonb('Registration rejected'::text)),
  ('delivery.reg_reviewed_toast',      to_jsonb('Registration updated'::text)),
  ('delivery.reg_admin_title',         to_jsonb('New rider application'::text)),
  ('delivery.reg_submitted_title',     to_jsonb('Application submitted'::text)),
  ('delivery.reg_submitted_body',      to_jsonb('An admin will review it and you will see the decision here.'::text)),
  ('delivery.reg_submitted_toast',     to_jsonb('Registration submitted — an admin will review it'::text)),
  ('delivery.reg_already',             to_jsonb('You have already applied — check the status below.'::text)),
  ('delivery.reg_title',               to_jsonb('Deliver with mediBO'::text)),
  ('delivery.reg_signed_out',          to_jsonb('Sign in first, then apply to deliver.'::text)),
  ('delivery.reg_status_title',        to_jsonb('Your rider application'::text)),
  ('delivery.status_approved',         to_jsonb('Approved'::text)),
  ('delivery.status_rejected',         to_jsonb('Not accepted'::text)),
  ('delivery.status_pending',          to_jsonb('Under review'::text)),
  ('delivery.status_approved_active',  to_jsonb('You are active — open Deliveries to see your stops.'::text)),
  ('delivery.status_approved_inactive',to_jsonb('Approved. An admin will activate you shortly.'::text)),
  ('delivery.status_rejected_body',    to_jsonb('No reason was recorded.'::text)),
  ('delivery.status_pending_body',     to_jsonb('An admin is reviewing your documents.'::text)),
  ('delivery.submitted_on',            to_jsonb('Submitted'::text)),
  ('delivery.reviewed_on',             to_jsonb('Reviewed'::text)),
  ('delivery.reapply_cta',             to_jsonb('Apply again'::text)),
  ('delivery.invite_prompt',           to_jsonb('Added by an agency? Enter your invite code.'::text)),
  ('delivery.invite_cta',              to_jsonb('Use invite code'::text)),
  ('delivery.invite_label',            to_jsonb('Invite code'::text)),
  ('delivery.invite_linked',           to_jsonb('This rider already has a login — they can start now.'::text)),
  ('delivery.invite_unlinked',         to_jsonb('Ask the rider to sign up, open Deliver with mediBO and enter this code.'::text)),
  ('delivery.invite_signin',           to_jsonb('Sign in first, then enter your invite code.'::text)),
  ('delivery.invite_not_found',        to_jsonb('That code does not match any rider.'::text)),
  ('delivery.invite_taken',            to_jsonb('That code is already in use.'::text)),
  ('delivery.invite_claimed',          to_jsonb('You are linked — open Deliveries to see your stops.'::text)),
  ('delivery.added_title',             to_jsonb('You were added as a rider'::text)),
  ('delivery.added_body',              to_jsonb('Open Deliveries to see your stops.'::text)),
  ('delivery.added_toast',             to_jsonb('Delivery partner added'::text)),
  ('notif_channel.inapp',              to_jsonb('In-app'::text))
on conflict (key) do nothing;

insert into fw_ui_label(key, value) values
  ('dlv_method_sign',    'Signature'),
  ('dlv_sign_hint',      'Ask the receiver to sign in the box.'),
  ('dlv_sign_clear',     'Clear'),
  ('dlv_sign_complete',  'Complete with signature'),
  ('dlv_reject_reason',  'Reason (shown to the applicant)'),
  ('dlv_reject_submit',  'Reject application'),
  ('dlv_offline_queued', 'Saved — will send when you are back online'),
  ('dlv_offline_pending','{n} action(s) waiting to send'),
  ('dlv_offline_sending','Sending saved actions…'),
  ('dlv_register_cta',   'Deliver with mediBO'),
  ('dlv_register_sub',   'Sign up as a delivery partner'),
  ('dlv_invite_code',    'Invite code'),
  ('dlv_invite_submit',  'Link my account')
on conflict (key) do nothing;
