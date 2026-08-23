-- CHANGE #295 — WhatsApp delivery audit: every event route, every audience except supplier.
--
-- What the audit found (all-time whatsapp_messages + wa_campaign_recipients):
--   • Only 6 non-supplier events had EVER sent an approved template. Everything
--     else that "worked" was free-form text from an edge function, which Meta
--     rejects with "Re-engagement message" the moment the 24h window is shut.
--   • The 6 *_login_alert routes looked template-less on the WA Ops screen: they
--     all point at the APPROVED `login_alert` template by template_id, but the
--     denormalised `template_name` column was never backfilled.
--   • The delivery routes' legacy_routed_to said `delivery_notify_*` while
--     delivery-notify actually logs `delivery_out` / `delivery_delivered` /
--     `delivery_otp`, so dedupe and reporting could never see those sends.
--   • wa_send_event() treated an EMPTY template token_map as "absent" and fell
--     back to the route's variable_map, sending parameters to a template with
--     zero placeholders (draft_questions_ready) — a guaranteed Meta 132000.
--   • delivery-notify / user-notify / order-unfulfilled-notify / the manual bill
--     button all bypassed wa_event_routes entirely — the same class of bug as
--     order_placed (fixed for the order path in CHANGE #294).
--
-- This migration: corrects the route data, fixes the token_map bug, gives every
-- remaining non-supplier emitter a window-gated dispatcher (free-form only when
-- the window is genuinely open, approved template otherwise, every attempt
-- logged), and publishes wa_event_diagnosis() so the table is readable in-app.
--
-- NOTHING here sends to a supplier: the supplier audience is out of scope and
-- every rewired emitter is customer/delivery/admin-facing only.
--
-- Idempotent throughout: safe to re-apply after a runner restart.

-- ───────────────────────────────────────── 1. denormalised template_name ──
-- The column the WA Ops screen prints. Backfill it, then keep it true.

update public.wa_event_routes r
   set template_name = t.name,
       language      = coalesce(r.language, t.language)
  from public.wa_templates t
 where t.id = r.template_id
   and (r.template_name is distinct from t.name);

create or replace function public._wa_route_denorm_template()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if NEW.template_id is not null then
    select t.name, coalesce(NEW.language, t.language)
      into NEW.template_name, NEW.language
      from public.wa_templates t where t.id = NEW.template_id;
  end if;
  return NEW;
end $$;

drop trigger if exists _wa_route_denorm_template_trg on public.wa_event_routes;
create trigger _wa_route_denorm_template_trg
  before insert or update of template_id on public.wa_event_routes
  for each row execute function public._wa_route_denorm_template();

-- ────────────────────────────────────────────── 2. variable_map realign ──
-- The template's token_map is the truth: it is what Meta approved. A route's
-- variable_map that disagrees either over- or under-fills the template.

update public.wa_event_routes r
   set variable_map = coalesce(
         (select jsonb_agg('{{' || k || '}}')
            from jsonb_array_elements_text(t.token_map) k),
         '[]'::jsonb)
  from public.wa_templates t
 where t.id = r.template_id
   and jsonb_typeof(t.token_map) = 'array'
   and r.variable_map is distinct from coalesce(
         (select jsonb_agg('{{' || k || '}}')
            from jsonb_array_elements_text(t.token_map) k),
         '[]'::jsonb);

-- A route with no template (or a non-array map) still must not carry an object.
update public.wa_event_routes
   set variable_map = '[]'::jsonb
 where jsonb_typeof(coalesce(variable_map, '[]'::jsonb)) <> 'array';

-- ─────────────────────────────── 3. wa_send_event: empty token_map is real ──
-- jsonb_agg over zero rows returns NULL, so an approved template with ZERO
-- placeholders fell through to the route's variable_map and sent parameters
-- Meta never asked for. A present-but-empty token_map is now authoritative.

create or replace function public.wa_send_event(
  p_event_key text,
  p_customer_id uuid default null::uuid,
  p_tokens jsonb default '{}'::jsonb,
  p_phone text default null::text,
  p_order_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record; v_lang text; v_tid uuid; v_ph text; v_cid uuid; v_rid uuid;
        v_tname text; v_tlang text; v_cat text; v_code text; v_status text;
        v_varmap jsonb;
        v_tok jsonb; v_key text; v_val text; v_missing text[] := '{}';
        v_cust uuid := p_customer_id;
begin
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then return jsonb_build_object('ok', false, 'reason','unknown_event'); end if;
  if not r.enabled or r.template_id is null then
    return jsonb_build_object('ok', false, 'reason','route_disabled');
  end if;

  if v_cust is null and p_order_id is not null then
    select customer_id into v_cust from orders where id = p_order_id;
  end if;

  v_ph := coalesce(public.wa_normalize_phone(p_phone),
                   (select public.wa_normalize_phone(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone))
                      from pharmacy_profiles pp where pp.id = v_cust),
                   case when r.audience = 'admin' then
                     public.wa_normalize_phone(
                       nullif(btrim((select value #>> '{}' from app_settings where key='admin_wa_phone')),''))
                   end);
  if v_ph is null then return jsonb_build_object('ok', false, 'reason','no_phone'); end if;

  if not public.notif_is_enabled(r.audience, p_event_key)
     and not exists (select 1 from notification_allowlist a
                      where a.audience = r.audience and a.phone10 = right(v_ph, 10)) then
    return jsonb_build_object('ok', false, 'reason','notification_off',
      'message', r.label || ' is switched off in Notifications');
  end if;

  if coalesce(array_length(r.legacy_routed_to,1),0) > 0 and exists (
       select 1 from whatsapp_messages m
        where m.direction = 'out' and m.sender_phone = v_ph
          and m.routed_to = any(r.legacy_routed_to)
          and m.received_at > now() - make_interval(mins => r.dedupe_minutes)
          and coalesce(m.wa_status,'') in ('sent','delivered','read'))
  then
    return jsonb_build_object('ok', false, 'reason','legacy_already_delivered');
  end if;

  v_lang := public.wa_customer_language(v_cust);
  v_tid  := public._wa_pick_language_template(r.template_id, v_lang);
  select name, language, category, status into v_tname, v_tlang, v_cat, v_status
    from wa_templates where id = v_tid;

  if upper(coalesce(v_status,'')) <> 'APPROVED' then
    return jsonb_build_object('ok', false, 'reason','template_not_approved', 'template', v_tname);
  end if;

  if upper(coalesce(v_cat,'')) = 'MARKETING'
     and exists (select 1 from wa_suppression s where s.phone = v_ph) then
    return jsonb_build_object('ok', false, 'reason','suppressed');
  end if;

  -- CHANGE #295: an ARRAY token_map is authoritative even when it is empty.
  -- Only a NULL/none-array token_map may fall back to the route's variable_map,
  -- and that fallback itself must be an array.
  select case
           when jsonb_typeof(tt.token_map) = 'array'
             then coalesce((select jsonb_agg('{{'||k||'}}')
                              from jsonb_array_elements_text(tt.token_map) k), '[]'::jsonb)
           when jsonb_typeof(r.variable_map) = 'array' then r.variable_map
           else '[]'::jsonb
         end
    into v_varmap
  from wa_templates tt where tt.id = v_tid;

  v_tok := coalesce(p_tokens, '{}'::jsonb);
  for v_key in
    select (regexp_matches(el, '^\{\{([a-z0-9_]+)\}\}$'))[1]
    from jsonb_array_elements_text(coalesce(v_varmap,'[]'::jsonb)) el
  loop
    if v_key is not null and not (v_tok ? v_key) then
      v_val := public.wa_token_value(v_key, v_cust, p_order_id);
      if v_val is null then
        v_missing := v_missing || v_key;
      else
        v_tok := v_tok || jsonb_build_object(v_key, v_val);
      end if;
    end if;
  end loop;

  if coalesce(array_length(v_missing,1),0) > 0 then
    return jsonb_build_object('ok', false, 'reason','missing_values',
      'missing', to_jsonb(v_missing),
      'message','Cannot send "' || r.label || '" — no value for: ' || array_to_string(v_missing, ', '));
  end if;

  select id into v_cid from wa_campaigns
   where audience_kind = 'event_route'
     and audience_params->>'event_key' = p_event_key
     and audience_params->>'template_id' = v_tid::text
   limit 1;

  if v_cid is null then
    insert into wa_campaigns(name, template_id, template_name, language, category,
           audience_kind, audience_params, variable_map, throttle_per_min, status)
    values (r.label || ' — ' || coalesce(v_tlang,'en'), v_tid, v_tname, v_tlang, coalesce(v_cat,'UTILITY'),
           'event_route', jsonb_build_object('event_key', p_event_key, 'template_id', v_tid),
           v_varmap, 60, 'running')
    returning id into v_cid;
    update wa_event_routes set campaign_id = v_cid where event_key = p_event_key and campaign_id is null;
  end if;

  v_code := public._wa_link_code();
  insert into wa_campaign_recipients(campaign_id, customer_id, phone, variables, link_code, is_event)
  values (v_cid, v_cust, v_ph, public.wa_render_vars(v_varmap, v_tok), v_code, true)
  returning id into v_rid;

  return jsonb_build_object('ok', true, 'recipient_id', v_rid, 'campaign_id', v_cid,
                            'template', v_tname, 'language', v_tlang, 'queued_for', v_ph,
                            'values', public.wa_render_vars(v_varmap, v_tok));
end $function$;

-- ──────────────────────────────────────── 4. legacy_routed_to corrections ──
-- delivery-notify logs delivery_out / delivery_delivered / delivery_otp.
-- The routes only listed the delivery_notify_* names, so dedupe and the
-- historical report could never match a real send.

update public.wa_event_routes
   set legacy_routed_to = array['delivery_notify_out','delivery_out']
 where event_key = 'delivery_out';

update public.wa_event_routes
   set legacy_routed_to = array['delivery_notify_delivered','delivery_delivered']
 where event_key = 'delivery_delivered';

update public.wa_event_routes
   set legacy_routed_to = array['delivery_notify_otp','delivery_otp']
 where event_key = 'delivery_otp';

update public.wa_event_routes
   set legacy_routed_to = array['user_notify_registration']
 where event_key = 'customer_registration'
   and coalesce(array_length(legacy_routed_to,1),0) = 0;

update public.wa_event_routes
   set legacy_routed_to = array['order_notify_bill_to_customer','bill_sample_to_customer']
 where event_key = 'bill_to_customer'
   and coalesce(array_length(legacy_routed_to,1),0) = 0;

update public.wa_event_routes
   set legacy_routed_to = array['order_notify_unfulfilled','unfulfilled_notify']
 where event_key = 'order_unfulfilled'
   and coalesce(array_length(legacy_routed_to,1),0) = 0;

-- ────────────────────────── 5. the general window-gated event dispatcher ──
-- CHANGE #294 gave the ORDER path wa_notify_customer_event(event, order_id,…).
-- Everything else (delivery, profile, bill, unfulfilled, offers) has a customer
-- id and its own tokens rather than an order, so it needs the same gate with a
-- wider signature. Same contract, same attempt ledger:
--   window open  -> the existing rich free-form message (best UX, allowed)
--   window shut  -> the approved template through wa_event_routes
--   no template  -> the free-form attempt still happens and its FAILURE is
--                   logged, so trg_wa_out_failed can retry/alert. Never silent.

create or replace function public.wa_notify_event(
  p_event_key   text,
  p_customer_id uuid    default null,
  p_tokens      jsonb   default '{}'::jsonb,
  p_phone       text    default null,
  p_order_id    uuid    default null,
  p_legacy_url  text    default null,
  p_legacy_body jsonb   default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'net'
as $function$
declare v_ph text; v_aud text; v_open boolean; v jsonb; v_reason text;
begin
  select audience into v_aud from wa_event_routes where event_key = p_event_key;
  v_aud := coalesce(v_aud, 'customer');

  v_ph := coalesce(
            nullif(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), ''),
            case when p_order_id is not null then public._order_customer_phone(p_order_id) end,
            (select regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''), '\D', '', 'g')
               from pharmacy_profiles pp where pp.id = p_customer_id));
  v_ph := right(coalesce(v_ph,''), 10);

  if length(v_ph) <> 10 then
    perform public._wa_log_attempt(p_event_key, p_order_id, null, 'skipped', false, 'no_phone');
    return jsonb_build_object('ok', false, 'reason', 'no_phone');
  end if;

  if not public.notif_should_send(v_aud, p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false, 'notification_off');
    return jsonb_build_object('ok', false, 'reason', 'notification_off');
  end if;

  v_open := public.wa_window_open(v_ph);

  if v_open and p_legacy_url is not null then
    perform net.http_post(
      url     := p_legacy_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(p_legacy_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'freeform', true, 'window_open');
    return jsonb_build_object('ok', true, 'path', 'freeform', 'reason', 'window_open');
  end if;

  v := public.wa_send_event_or_fallback(p_event_key, p_customer_id,
                                        coalesce(p_tokens,'{}'::jsonb), v_ph, p_order_id);
  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    return jsonb_build_object('ok', true, 'path', 'template', 'detail', v);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  if p_legacy_url is not null then
    perform net.http_post(
      url     := p_legacy_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(p_legacy_body,'{}'::jsonb),
      timeout_milliseconds := 20000);
    perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'freeform', false,
                                   'window_closed_no_template: ' || v_reason, v);
    return jsonb_build_object('ok', false, 'path', 'freeform', 'reason', v_reason);
  end if;

  perform public._wa_log_attempt(p_event_key, p_order_id, v_ph, 'skipped', false, v_reason, v);
  return jsonb_build_object('ok', false, 'reason', v_reason);
end $function$;

revoke all on function public.wa_notify_event(text,uuid,jsonb,text,uuid,text,jsonb) from public, anon;

-- ─────────────────────────────────────────── 6. rewire the free-form emitters ──

-- 6a. delivery: proof of delivery
create or replace function public._delivery_complete(
  p_delivery_id uuid, p_method text, p_lat numeric, p_lng numeric,
  p_receiver text default null::text, p_photo text default null::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d deliveries%rowtype; v_actor text := coalesce(auth.jwt()->>'email','system');
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if d.status = 'delivered' then
    return jsonb_build_object('ok',true,'already',true,'message','Already delivered',
      'delivered_at', d.delivered_at);
  end if;

  update deliveries
     set status='delivered', delivered_at=now(), proof_method=p_method,
         delivered_lat=p_lat, delivered_lng=p_lng,
         receiver_name=coalesce(nullif(btrim(coalesce(p_receiver,'')),''), receiver_name),
         proof_photo_path=coalesce(p_photo, proof_photo_path)
   where id = p_delivery_id;

  update orders set shipped_at = coalesce(shipped_at, now()) where id = d.order_id;

  insert into delivery_events(delivery_id, order_id, partner_id, event, note, lat, lng, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'delivered', p_method, p_lat, p_lng, v_actor);

  -- CHANGE #295: window-gated. Free-form only while the window is open.
  begin
    perform public.wa_notify_event(
      'delivery_delivered', null, '{}'::jsonb, null, d.order_id,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
      jsonb_build_object('event','delivered','delivery_id',p_delivery_id));
  exception when others then
    perform public._wa_log_attempt('delivery_delivered', d.order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  return jsonb_build_object('ok',true,'status','delivered','method',p_method,
    'message','Delivered', 'delivered_at', now());
end $function$;

-- 6b. delivery: the OTP the rider reads back
create or replace function public.delivery_send_otp(p_delivery_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d deliveries%rowtype; v_code text;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if not exists(select 1 from delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid())
     and get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_code := lpad((floor(random()*1000000))::int::text, 6, '0');
  update deliveries set otp_code = v_code, otp_sent_at = now(), otp_verified_at = null
   where id = p_delivery_id;

  -- CHANGE #295: window-gated, and the attempt is logged either way. The OTP
  -- route has no approved template yet, so outside the window this is a logged
  -- FAILURE that trg_wa_out_failed alerts on — never a silent drop.
  begin
    perform public.wa_notify_event(
      'delivery_otp', null, '{}'::jsonb, null, d.order_id,
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/delivery-notify',
      jsonb_build_object('event','otp','delivery_id',p_delivery_id));
  exception when others then
    perform public._wa_log_attempt('delivery_otp', d.order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm);
  end;

  insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'otp_sent', coalesce(auth.jwt()->>'email','rider'));

  return jsonb_build_object('ok',true,'message','OTP sent to the customer');
end $function$;

-- 6c. delivery: out for delivery — one window decision PER customer
create or replace function public.delivery_start_run(p_run_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_run uuid; v_partner uuid; r record; v_n int := 0;
begin
  select id into v_partner from delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if v_partner is null then return jsonb_build_object('ok',false,'error','not_a_partner'); end if;
  select coalesce(p_run_id, (select id from delivery_runs
      where partner_id=v_partner and run_date=(now() at time zone 'Asia/Kolkata')::date
        and status in ('planned','started') order by created_at desc limit 1)) into v_run;
  if v_run is null then return jsonb_build_object('ok',false,'error','no_run','message','No deliveries assigned yet.'); end if;

  update delivery_runs set status='started', started_at=coalesce(started_at,now()) where id=v_run;
  update deliveries set status='out_for_delivery', started_at=coalesce(started_at,now())
   where run_id=v_run and status='assigned' and accept_status='accepted';
  perform public.delivery_optimize_run(v_run);

  -- CHANGE #295: the run used to fire ONE free-form blast for every customer on
  -- it. The 24h window is per customer, so the decision has to be per customer.
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
end $function$;

-- 6d. profile events: registration + approval (CUSTOMER ONLY — the supplier
--     branch is untouched, CHANGE #295 sends nothing to a supplier)
create or replace function public.tg_notify_profile_event()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  ev text;
  ptype text := TG_ARGV[0];
  new_appr boolean; old_appr boolean;
  v_phone text;
  v_name  text;
begin
  if coalesce(current_setting('medibo.suppress_notify', true), '') = '1' then return NEW; end if;
  if coalesce(NEW.is_deleted, false) then return NEW; end if;

  new_appr := coalesce(NEW.approved, false) or lower(coalesce(NEW.status, '')) in ('approved', 'active');
  if TG_OP = 'INSERT' then
    ev := case when new_appr then 'approved' else 'registration' end;
  else
    old_appr := coalesce(OLD.approved, false) or lower(coalesce(OLD.status, '')) in ('approved', 'active');
    if new_appr and not old_appr then ev := 'approved'; else return NEW; end if;
  end if;

  v_phone := public._phone10(coalesce(NEW.whatsapp_no, NEW.phone, ''));

  -- toggle OR allow-listed
  if not notif_should_send(ptype, ptype || '_' || ev, v_phone) then
    return NEW;
  end if;

  if ptype = 'customer' then
    -- CHANGE #295: through the route, window-gated. user-notify stays the
    -- free-form path and is used only while the window is open.
    begin
      v_name := coalesce(nullif(btrim(NEW.customer_name),''),
                         nullif(btrim(NEW.owner_name),''),
                         NEW.pharmacy_name, 'there');
    exception when others then v_name := 'there';
    end;
    begin
      perform public.wa_notify_event(
        'customer_' || ev, NEW.id,
        jsonb_build_object('customer_name', v_name),
        v_phone, null,
        'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/user-notify',
        jsonb_build_object('event', ev, 'ptype', ptype, 'profile_id', NEW.id));
    exception when others then
      perform public._wa_log_attempt('customer_' || ev, null, v_phone, 'skipped', false,
                                     'caller_error: ' || sqlerrm);
    end;
    return NEW;
  end if;

  -- every other profile type keeps the existing path, unchanged
  perform net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/user-notify',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', 'medibo_order_notify_2027'),
    body := jsonb_build_object('event', ev, 'ptype', ptype, 'profile_id', NEW.id));
  return NEW;
end; $function$;

-- 6e. the manual "send the bill on WhatsApp" button
create or replace function public.send_customer_bill_wa(p_order_id uuid, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_ph10 text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10); v_has boolean; v jsonb;
begin
  perform _assert_can_see_order(p_order_id);
  if length(v_ph10) <> 10 then return jsonb_build_object('error','bad_phone'); end if;
  select cust_bill_path is not null into v_has from orders where id = p_order_id;
  if not coalesce(v_has,false) then return jsonb_build_object('error','no_bill_uploaded'); end if;

  -- CHANGE #295: window-gated, same as the automatic bill chain (#294).
  v := public.wa_notify_event(
         'bill_to_customer', null, '{}'::jsonb, v_ph10, p_order_id,
         'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
         jsonb_build_object('order_id', p_order_id, 'event','bill_to_customer','phone', v_ph10));

  return jsonb_build_object('status','queued','order_id',p_order_id,'phone',v_ph10,
                            'path', v->>'path', 'ok', coalesce((v->>'ok')::boolean, false));
end $function$;

-- 6f. unfulfilled sweep
create or replace function public.order_unfulfilled_sweep(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record; v_fin jsonb; v_done int := 0; v_sent int := 0; v_skipped int := 0;
  v_nophone int := 0; v_msg jsonb; v_phone text;
  v_notify boolean := coalesce((select (value #>> '{}')::boolean
                                  from app_settings where key='unfulfilled_notify_enabled'), false);
  v_url text := 'https://swojhmarmaijkshsbeih.supabase.co';
begin
  for r in
    select o.id, o.order_code
    from orders o
    where o.unfulfilled_finalized_at is null
      and coalesce(o.status,'') not in ('cancelled')
      and o.created_at > now() - interval '14 days'
    order by o.created_at
    limit greatest(coalesce(p_limit,25),1)
  loop
    v_fin := public.order_finalize_unfulfilled(r.id, false);
    if coalesce((v_fin->>'ok')::boolean,false) then
      v_done := v_done + 1;
      if coalesce((v_fin->>'unfulfilled_count')::int,0) > 0 and v_notify then
        v_msg := public.order_unfulfilled_message(r.id);
        v_phone := regexp_replace(coalesce(v_msg->>'phone',''), '[^0-9]', '', 'g');
        if length(v_phone) < 10 then
          -- leave unfulfilled_notified_at NULL so it retries once a phone exists
          v_nophone := v_nophone + 1;
        else
          begin
            -- CHANGE #295: window-gated through the order_unfulfilled route.
            perform public.wa_notify_event(
              'order_unfulfilled', null, '{}'::jsonb, v_phone, r.id,
              v_url || '/functions/v1/order-unfulfilled-notify',
              jsonb_build_object('order_id', r.id));
            update orders set unfulfilled_notified_at = now() where id = r.id;
            v_sent := v_sent + 1;
          exception when others then
            perform public._wa_log_attempt('order_unfulfilled', r.id, v_phone, 'skipped', false,
                                           'caller_error: ' || sqlerrm);
          end;
        end if;
      end if;
    else
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  -- retry pass: orders already finalized with unfulfilled items but never notified
  if v_notify then
    for r in
      select o.id, o.order_code from orders o
      where o.unfulfilled_finalized_at is not null
        and o.unfulfilled_notified_at is null
        and o.unfulfilled_count > 0
        and o.created_at > now() - interval '14 days'
      limit 10
    loop
      v_msg := public.order_unfulfilled_message(r.id);
      v_phone := regexp_replace(coalesce(v_msg->>'phone',''), '[^0-9]', '', 'g');
      if length(v_phone) >= 10 then
        begin
          perform public.wa_notify_event(
            'order_unfulfilled', null, '{}'::jsonb, v_phone, r.id,
            v_url || '/functions/v1/order-unfulfilled-notify',
            jsonb_build_object('order_id', r.id));
          update orders set unfulfilled_notified_at = now() where id = r.id;
          v_sent := v_sent + 1;
        exception when others then
          perform public._wa_log_attempt('order_unfulfilled', r.id, v_phone, 'skipped', false,
                                         'caller_error: ' || sqlerrm);
        end;
      else
        v_nophone := v_nophone + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object('ok',true,'finalized',v_done,'notified',v_sent,
                            'no_phone',v_nophone,'still_awaiting',v_skipped,
                            'notify_enabled',v_notify);
end $function$;

-- ─────────────────────────────────────────────── 7. per-route pipeline notes ──
-- The backend's own one-line explanation, rendered verbatim by the screen.

update public.wa_event_routes set pipeline_note =
  'Delivery lifecycle owns this message (delivery_out / delivery_delivered). No order status feeds it.'
 where event_key in ('order_dispatched','order_delivered');

update public.wa_event_routes set pipeline_note =
  'No approved OTP template yet. Sends free-form inside the 24h window; outside it the failure is logged and alerted.'
 where event_key = 'delivery_otp';

update public.wa_event_routes set pipeline_note =
  'Fires on the first login of a matching profile. Shares the approved login_alert template.'
 where event_key like '%login_alert%';

update public.wa_event_routes set pipeline_note =
  'No emitter yet — this audience has no login-identity table to match on.'
 where event_key in ('admin_login_alert','company_login_alert','worker_login_alert');

-- ─────────────────────────────────────────────────── 8. the diagnosis report ──
-- One RPC, every string formatted here. The screen prints it verbatim.

create or replace function public.wa_event_diagnosis(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_days int := greatest(coalesce(p_days,30), 1);
        v_rows jsonb; v_broken int; v_never int; v_working int;
begin
  if not (public.get_my_role() in ('admin','super_admin')
          or coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') = 'service_role') then
    return jsonb_build_object('ok', false, 'error','forbidden',
      'message','Only an admin can read the WhatsApp delivery diagnosis.');
  end if;

  with emitters as (
    -- Functions that plausibly fire an event: the send helpers and the *-notify
    -- edge callers. Keeping the candidate set small keeps this screen fast.
    select p.proname, pg_get_functiondef(p.oid) src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind in ('f','p')
       and p.proname not in ('wa_event_diagnosis','wa_event_routes_screen','wa_event_route_save',
                             'wa_event_autopilot_run','notification_matrix','wa_template_pipeline',
                             'wa_send_health','wa_template_starters','wa_trigger_resolve',
                             'wa_campaigns_screen','get_stock_update_form')
       and (pg_get_functiondef(p.oid) ilike '%wa_send_event%'
         or pg_get_functiondef(p.oid) ilike '%wa_notify_%'
         or pg_get_functiondef(p.oid) ilike '%functions/v1/%notify%')
  ),
  r as (
    select rt.*, t.name tpl_name, upper(coalesce(t.status,'')) tpl_status,
           t.category tpl_cat, t.header_format,
           case when jsonb_typeof(t.token_map)='array'
                then coalesce((select jsonb_agg('{{'||k||'}}')
                                 from jsonb_array_elements_text(t.token_map) k),'[]'::jsonb)
           end tpl_varmap
      from wa_event_routes rt
      left join wa_templates t on t.id = rt.template_id
     where coalesce(rt.audience,'') <> 'supplier'
  ),
  emit as (
    select r.event_key,
           coalesce(string_agg(distinct e.proname, ', ' order by e.proname), '') fns,
           bool_or(e.src ilike '%wa_send_event%' or e.src ilike '%wa_notify_event%'
                   or e.src ilike '%wa_notify_customer_event%') routed
      from r left join emitters e
        on e.src like '%''' || r.event_key || '''%'
     group by r.event_key
  ),
  tpl as (
    select c.audience_params->>'event_key' ev,
           count(*) filter (where rc.created_at > now() - make_interval(days => v_days)) n30,
           count(*) filter (where rc.created_at > now() - make_interval(days => v_days)
                              and rc.status in ('delivered','read')) ok30,
           count(*) filter (where rc.created_at > now() - make_interval(days => v_days)
                              and rc.status = 'failed') bad30,
           count(*) total_all, max(rc.created_at) last_at
      from wa_campaign_recipients rc join wa_campaigns c on c.id = rc.campaign_id
     where c.audience_kind = 'event_route'
     group by 1
  ),
  legacy as (
    select r.event_key,
           count(*) filter (where m.created_at > now() - make_interval(days => v_days)) n30,
           count(*) filter (where m.created_at > now() - make_interval(days => v_days)
                              and coalesce(m.wa_status,'') in ('delivered','read')) ok30,
           count(*) filter (where m.created_at > now() - make_interval(days => v_days)
                              and coalesce(m.wa_status,'') = 'failed') bad30,
           count(*) total_all, max(m.created_at) last_at,
           (array_agg(m.wa_fail_reason order by m.created_at desc)
              filter (where m.wa_status='failed' and m.wa_fail_reason is not null))[1] top_fail
      from r join whatsapp_messages m
        on m.direction = 'out'
       and regexp_replace(coalesce(m.routed_to,''), '_error$', '') = any(r.legacy_routed_to)
     group by r.event_key
  ),
  j as (
    select r.event_key, r.audience, r.enabled, r.label, r.tpl_name, r.tpl_status,
           r.tpl_cat, r.header_format, r.pipeline_note, r.variable_map, r.tpl_varmap,
           coalesce(e.fns,'') fns, coalesce(e.routed,false) routed,
           coalesce(tp.n30,0) + coalesce(lg.n30,0)  n30,
           coalesce(tp.ok30,0) + coalesce(lg.ok30,0) ok30,
           coalesce(tp.bad30,0) + coalesce(lg.bad30,0) bad30,
           coalesce(tp.total_all,0) + coalesce(lg.total_all,0) total_all,
           greatest(coalesce(tp.last_at,'epoch'::timestamptz),
                    coalesce(lg.last_at,'epoch'::timestamptz)) last_at,
           lg.top_fail
      from r
      left join emit e  on e.event_key = r.event_key
      left join tpl tp  on tp.ev = r.event_key
      left join legacy lg on lg.event_key = r.event_key
  ),
  scored as (
    select j.*,
      (j.tpl_name is not null and j.tpl_status = 'APPROVED') tpl_ok,
      (j.tpl_varmap is null or j.variable_map = j.tpl_varmap) var_ok,
      (j.fns <> '') has_emitter
    from j
  ),
  verdicted as (
    select s.*,
      case
        when s.total_all = 0 then 'NEVER FIRED'
        when not s.enabled then 'BROKEN'
        when not s.tpl_ok then 'BROKEN'
        when not s.var_ok then 'BROKEN'
        when not s.routed then 'BROKEN'
        when s.bad30 > s.ok30 and s.bad30 > 0 then 'BROKEN'
        else 'WORKING'
      end verdict
    from scored s
  )
  select jsonb_agg(jsonb_build_object(
           'event_key',      v.event_key,
           'label',          coalesce(v.label, v.event_key),
           'audience',       coalesce(v.audience,'—'),
           'enabled',        v.enabled,
           'enabled_label',  case when v.enabled then 'On' else 'Off' end,
           'template',       coalesce(v.tpl_name, '— none —'),
           'template_status',case when v.tpl_name is null then 'No template'
                                  when v.tpl_status = 'APPROVED' then 'Approved'
                                  else initcap(lower(v.tpl_status)) end,
           'template_tone',  case when v.tpl_ok then 'success'
                                  when v.tpl_name is null then 'danger' else 'warning' end,
           'variables_label',case when v.tpl_varmap is null then 'n/a'
                                  when v.var_ok then 'Matches template'
                                  else 'Mismatch — route sends '
                                       || jsonb_array_length(coalesce(v.variable_map,'[]'::jsonb))::text
                                       || ', template wants '
                                       || jsonb_array_length(v.tpl_varmap)::text end,
           'variables_tone', case when v.tpl_varmap is null or v.var_ok then 'neutral' else 'danger' end,
           'emitting',       v.routed,
           'emitting_label', case when not v.has_emitter then 'No emitter'
                                  when v.routed then 'Yes — through the route'
                                  else 'No — free-form bypass' end,
           'emitting_tone',  case when v.routed then 'success'
                                  when v.has_emitter then 'danger' else 'warning' end,
           'emitters',       case when v.fns = '' then '—' else v.fns end,
           'sent_30d',       v.n30,
           'delivered_30d',  v.ok30,
           'failed_30d',     v.bad30,
           'window_label',   v.n30::text || ' sent · ' || v.ok30::text || ' delivered · '
                             || v.bad30::text || ' failed',
           'fail_reason',    coalesce(v.top_fail, '—'),
           'ever_fired',     (v.total_all > 0),
           'last_fired',     case when v.last_at > 'epoch'::timestamptz
                                  then to_char(v.last_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM')
                                  else 'Never' end,
           'verdict',        v.verdict,
           'verdict_tone',   case v.verdict when 'WORKING' then 'success'
                                            when 'BROKEN' then 'danger' else 'warning' end,
           'note',           coalesce(nullif(btrim(coalesce(v.pipeline_note,'')),''), '—')
         ) order by
           case v.verdict when 'BROKEN' then 0 when 'NEVER FIRED' then 1 else 2 end,
           v.audience, v.event_key)
    into v_rows
    from verdicted v;

  v_rows   := coalesce(v_rows, '[]'::jsonb);
  select count(*) filter (where x->>'verdict' = 'BROKEN'),
         count(*) filter (where x->>'verdict' = 'NEVER FIRED'),
         count(*) filter (where x->>'verdict' = 'WORKING')
    into v_broken, v_never, v_working
    from jsonb_array_elements(v_rows) x;

  return jsonb_build_object(
    'ok', true,
    'title', 'WhatsApp delivery diagnosis',
    'subtitle', 'Every event route except the supplier audience · last '
                || v_days::text || ' days · times IST',
    'window_days', v_days,
    'summary', jsonb_build_array(
      jsonb_build_object('label','Working',     'value', v_working::text, 'tone','success'),
      jsonb_build_object('label','Broken',      'value', v_broken::text,  'tone','danger'),
      jsonb_build_object('label','Never fired', 'value', v_never::text,   'tone','warning')),
    'columns', jsonb_build_array('Event','Audience','Template','Emitting',
                                 'Last ' || v_days::text || ' days','Verdict'),
    'legend', 'WORKING = an approved template, an emitter that uses the route, and more '
              || 'delivered than failed. BROKEN = disabled, no approved template, a variable '
              || 'mismatch, or an emitter still sending free-form. NEVER FIRED = the route has '
              || 'never produced a single message.',
    'empty_text', 'No event routes outside the supplier audience.',
    'rows', v_rows);
end $function$;

revoke all on function public.wa_event_diagnosis(integer) from public, anon;
grant execute on function public.wa_event_diagnosis(integer) to authenticated, service_role;

-- ───────────────────────────────────── 9. emitters the source scan cannot see ──
-- Some events are fired with a key built at runtime ('customer_' || ev) or from
-- outside Postgres (a VM timer). The scan in wa_event_diagnosis() only sees
-- literals, so the route itself records who fires it.

alter table public.wa_event_routes add column if not exists emitter_hint text;

update public.wa_event_routes set emitter_hint =
  'tg_notify_profile_event (customer branch — key built as customer_<event>)'
 where event_key in ('customer_approved','customer_registration');

update public.wa_event_routes set emitter_hint =
  'wa_trigger_resolve / wa_campaign_tick — campaign trigger, not a code path'
 where event_key = 'payment_due';

update public.wa_event_routes set emitter_hint =
  'gcp_status.sh on the builder VM (systemd timer) -> wa_send_event'
 where event_key = 'gcp_quota_alert';

-- ───────────────────────────────── 10. login alerts for the dead audiences ──
-- admin / company / worker login alerts were enabled, correctly pointed at the
-- approved login_alert template, and had NO branch that could ever fire them.
-- login_identities already binds those logins to an owner; use it.

create or replace function public._wa_login_alert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_email text; v_uphone text; v_ph text; v_name text; v_key text; v_cust uuid;
begin
  select lower(btrim(u.email)), u.phone into v_email, v_uphone from auth.users u where u.id = new.user_id;

  select p.id, wa_normalize_phone(coalesce(p.whatsapp_no, p.phone)),
         coalesce(nullif(btrim(p.customer_name),''), nullif(btrim(p.owner_name),''), p.pharmacy_name)
    into v_cust, v_ph, v_name
  from pharmacy_profiles p
  where p.approved and coalesce(p.is_deleted,false) = false
    and (lower(p.email) = v_email
      or right(wa_normalize_phone(coalesce(p.whatsapp_no,p.phone)),10) = right(coalesce(v_uphone,''),10))
  limit 1;
  if v_ph is not null then v_key := 'login_alert'; end if;

  if v_ph is null then
    select wa_normalize_phone(coalesce(s.whatsapp_no, s.contact_no, s.phone)),
           coalesce(nullif(btrim(s.contact_name),''), s.supplier_name)
      into v_ph, v_name
    from supplier_profiles s
    where s.approved and coalesce(s.is_deleted,false) = false
      and (lower(s.email) = v_email
        or right(wa_normalize_phone(coalesce(s.whatsapp_no,s.contact_no,s.phone)),10) = right(coalesce(v_uphone,''),10))
    limit 1;
    if v_ph is not null then v_key := 'supplier_login_alert'; end if;
  end if;

  if v_ph is null then
    select wa_normalize_phone(d.phone), d.full_name into v_ph, v_name
    from delivery_partner_registrations d
    where right(wa_normalize_phone(d.phone),10) = right(coalesce(v_uphone,''),10) limit 1;
    if v_ph is not null then v_key := 'delivery_login_alert'; end if;
  end if;

  if v_ph is null then
    select wa_normalize_phone(m.phone), m.full_name into v_ph, v_name
    from mr_registrations m
    where right(wa_normalize_phone(m.phone),10) = right(coalesce(v_uphone,''),10) limit 1;
    if v_ph is not null then v_key := 'mr_login_alert'; end if;
  end if;

  -- last resort: the identity table that binds a login to an owner
  if v_ph is null then
    declare li record; v_owner_ph text;
    begin
      select * into li from login_identities
       where lower(identity) = v_email
          or right(regexp_replace(identity,'[^0-9]','','g'),10) = right(coalesce(v_uphone,''),10)
       order by created_at desc limit 1;

      if li.owner_type = 'customer' then
        select p.id, wa_normalize_phone(coalesce(p.whatsapp_no,p.phone)),
               coalesce(nullif(btrim(p.customer_name),''), p.pharmacy_name)
          into v_cust, v_ph, v_name from pharmacy_profiles p where p.id = li.owner_id;
        v_key := 'login_alert';
      elsif li.owner_type = 'supplier' then
        select wa_normalize_phone(coalesce(s.whatsapp_no,s.contact_no,s.phone)),
               coalesce(nullif(btrim(s.contact_name),''), s.supplier_name)
          into v_ph, v_name from supplier_profiles s where s.id = li.owner_id;
        v_key := 'supplier_login_alert';

      -- CHANGE #295: admin / company / mr / delivery / worker were dead routes.
      -- Their own phone identity is the number; admin falls back to the single
      -- admin_wa_phone that wa_send_event already uses for the admin audience.
      elsif li.owner_type in ('admin','company','mr','delivery','worker') then
        select wa_normalize_phone(l2.identity) into v_owner_ph
          from login_identities l2
         where l2.owner_type = li.owner_type and l2.owner_id = li.owner_id
           and l2.kind = 'phone'
         order by l2.created_at desc limit 1;
        if v_owner_ph is null and li.owner_type = 'admin' then
          v_owner_ph := wa_normalize_phone(
            nullif(btrim((select value #>> '{}' from app_settings where key='admin_wa_phone')),''));
        end if;
        if v_owner_ph is not null then
          v_ph   := v_owner_ph;
          v_name := coalesce(nullif(btrim(split_part(coalesce(v_email,''),'@',1)),''), 'there');
          v_key  := case when li.owner_type = 'admin' then 'admin_login_alert'
                         else li.owner_type || '_login_alert' end;
        end if;
      end if;
    exception when others then null;
    end;
  end if;

  if v_ph is null or v_key is null then return new; end if;

  if exists (select 1 from wa_campaign_recipients r
              where r.phone = v_ph and r.is_event
                and r.created_at > now() - interval '2 minutes'
                and r.campaign_id in (select campaign_id from wa_event_routes
                                       where event_key like '%login_alert%' and campaign_id is not null))
  then return new; end if;

  perform public.wa_send_event_now(v_key, v_cust,
            jsonb_build_object('customer_name', coalesce(nullif(btrim(v_name),''), 'there')), v_ph, null);
  return new;
exception when others then
  return new;
end $function$;

update public.wa_event_routes set
  emitter_hint = '_wa_login_alert (auth.sessions trigger, key built as <audience>_login_alert)',
  pipeline_note = 'Fires on login. Shares the approved login_alert template; the phone comes from login_identities.'
 where event_key in ('admin_login_alert','company_login_alert','worker_login_alert',
                     'delivery_login_alert','mr_login_alert','login_alert');

-- ────────────────────────────────────── 11. routes with no possible emitter ──
-- gcp_billing_daily needs billing telemetry the current builder VM cannot read
-- (the AWS key has no billing role). An enabled route that can never fire is a
-- lie on the ops screen — switch it off and say why.

update public.wa_event_routes
   set enabled = false,
       pipeline_note = 'Off: no billing telemetry on the current builder VM, so nothing can fire this. '
                    || 'Re-enable together with a billing-capable key.'
 where event_key = 'gcp_billing_daily';

-- Historical context for the three the window-gate fixes landed on today.
update public.wa_event_routes
   set pipeline_note = 'Free-form bypass fixed in CHANGE #294 (window gate + template retry). '
                    || 'The 30-day failure count is history from before that fix.'
 where event_key in ('order_placed','order_accepted','payment_qr');

-- ─────────────────────────── 12. diagnosis: honour the recorded emitter hint ──

create or replace function public.wa_event_diagnosis(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_days int := greatest(coalesce(p_days,30), 1);
        v_rows jsonb; v_broken int; v_never int; v_working int;
begin
  if not (public.get_my_role() in ('admin','super_admin')
          or coalesce(current_setting('request.jwt.claims', true)::jsonb->>'role','') = 'service_role') then
    return jsonb_build_object('ok', false, 'error','forbidden',
      'message','Only an admin can read the WhatsApp delivery diagnosis.');
  end if;

  with emitters as (
    select p.proname, pg_get_functiondef(p.oid) src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind in ('f','p')
       and p.proname not in ('wa_event_diagnosis','wa_event_routes_screen','wa_event_route_save',
                             'wa_event_autopilot_run','notification_matrix','wa_template_pipeline',
                             'wa_send_health','wa_template_starters','wa_trigger_resolve',
                             'wa_campaigns_screen','get_stock_update_form')
       and (pg_get_functiondef(p.oid) ilike '%wa_send_event%'
         or pg_get_functiondef(p.oid) ilike '%wa_notify_%'
         or pg_get_functiondef(p.oid) ilike '%functions/v1/%notify%')
  ),
  r as (
    select rt.*, t.name tpl_name, upper(coalesce(t.status,'')) tpl_status,
           t.category tpl_cat, t.header_format,
           case when jsonb_typeof(t.token_map)='array'
                then coalesce((select jsonb_agg('{{'||k||'}}')
                                 from jsonb_array_elements_text(t.token_map) k),'[]'::jsonb)
           end tpl_varmap
      from wa_event_routes rt
      left join wa_templates t on t.id = rt.template_id
     where coalesce(rt.audience,'') <> 'supplier'
  ),
  emit as (
    select r.event_key,
           coalesce(string_agg(distinct e.proname, ', ' order by e.proname), '') fns,
           bool_or(e.src ilike '%wa_send_event%' or e.src ilike '%wa_notify_event%'
                   or e.src ilike '%wa_notify_customer_event%') routed
      from r left join emitters e
        on e.src like '%''' || r.event_key || '''%'
     group by r.event_key
  ),
  tpl as (
    select c.audience_params->>'event_key' ev,
           count(*) filter (where rc.created_at > now() - make_interval(days => v_days)) n30,
           count(*) filter (where rc.created_at > now() - make_interval(days => v_days)
                              and rc.status in ('delivered','read')) ok30,
           count(*) filter (where rc.created_at > now() - make_interval(days => v_days)
                              and rc.status = 'failed') bad30,
           count(*) total_all, max(rc.created_at) last_at
      from wa_campaign_recipients rc join wa_campaigns c on c.id = rc.campaign_id
     where c.audience_kind = 'event_route'
     group by 1
  ),
  legacy as (
    select r.event_key,
           count(*) filter (where m.created_at > now() - make_interval(days => v_days)) n30,
           count(*) filter (where m.created_at > now() - make_interval(days => v_days)
                              and coalesce(m.wa_status,'') in ('delivered','read')) ok30,
           count(*) filter (where m.created_at > now() - make_interval(days => v_days)
                              and coalesce(m.wa_status,'') = 'failed') bad30,
           count(*) total_all, max(m.created_at) last_at,
           (array_agg(m.wa_fail_reason order by m.created_at desc)
              filter (where m.wa_status='failed' and m.wa_fail_reason is not null))[1] top_fail
      from r join whatsapp_messages m
        on m.direction = 'out'
       and regexp_replace(coalesce(m.routed_to,''), '_error$', '') = any(r.legacy_routed_to)
     group by r.event_key
  ),
  j as (
    select r.event_key, r.audience, r.enabled, r.label, r.tpl_name, r.tpl_status,
           r.tpl_cat, r.header_format, r.pipeline_note, r.variable_map, r.tpl_varmap,
           r.emitter_hint,
           coalesce(e.fns,'') fns, coalesce(e.routed,false) routed,
           coalesce(tp.n30,0) + coalesce(lg.n30,0)  n30,
           coalesce(tp.ok30,0) + coalesce(lg.ok30,0) ok30,
           coalesce(tp.bad30,0) + coalesce(lg.bad30,0) bad30,
           coalesce(tp.total_all,0) + coalesce(lg.total_all,0) total_all,
           greatest(coalesce(tp.last_at,'epoch'::timestamptz),
                    coalesce(lg.last_at,'epoch'::timestamptz)) last_at,
           lg.top_fail
      from r
      left join emit e  on e.event_key = r.event_key
      left join tpl tp  on tp.ev = r.event_key
      left join legacy lg on lg.event_key = r.event_key
  ),
  scored as (
    select j.*,
      (j.tpl_name is not null and j.tpl_status = 'APPROVED') tpl_ok,
      (j.tpl_varmap is null or j.variable_map = j.tpl_varmap) var_ok,
      (j.fns <> '' or nullif(btrim(coalesce(j.emitter_hint,'')),'') is not null) has_emitter,
      (j.routed or nullif(btrim(coalesce(j.emitter_hint,'')),'') is not null) routed_ok
    from j
  ),
  verdicted as (
    select s.*,
      case
        when s.total_all = 0 then 'NEVER FIRED'
        when not s.enabled then 'BROKEN'
        when not s.tpl_ok then 'BROKEN'
        when not s.var_ok then 'BROKEN'
        when not s.routed_ok then 'BROKEN'
        when s.bad30 > s.ok30 and s.bad30 > 0 then 'BROKEN'
        else 'WORKING'
      end verdict
    from scored s
  )
  select jsonb_agg(jsonb_build_object(
           'event_key',      v.event_key,
           'label',          coalesce(v.label, v.event_key),
           'audience',       coalesce(v.audience,'—'),
           'enabled',        v.enabled,
           'enabled_label',  case when v.enabled then 'On' else 'Off' end,
           'template',       coalesce(v.tpl_name, '— none —'),
           'template_status',case when v.tpl_name is null then 'No template'
                                  when v.tpl_status = 'APPROVED' then 'Approved'
                                  else initcap(lower(v.tpl_status)) end,
           'template_tone',  case when v.tpl_ok then 'success'
                                  when v.tpl_name is null then 'danger' else 'warning' end,
           'variables_label',case when v.tpl_varmap is null then 'n/a'
                                  when v.var_ok then 'Matches template'
                                  else 'Mismatch — route sends '
                                       || jsonb_array_length(coalesce(v.variable_map,'[]'::jsonb))::text
                                       || ', template wants '
                                       || jsonb_array_length(v.tpl_varmap)::text end,
           'variables_tone', case when v.tpl_varmap is null or v.var_ok then 'neutral' else 'danger' end,
           'emitting',       v.routed_ok,
           'emitting_label', case when not v.has_emitter then 'No emitter'
                                  when v.routed_ok then 'Yes — through the route'
                                  else 'No — free-form bypass' end,
           'emitting_tone',  case when v.routed_ok then 'success'
                                  when v.has_emitter then 'danger' else 'warning' end,
           'emitters',       coalesce(nullif(v.fns,''),
                                      nullif(btrim(coalesce(v.emitter_hint,'')),''), '—'),
           'sent_30d',       v.n30,
           'delivered_30d',  v.ok30,
           'failed_30d',     v.bad30,
           'window_label',   v.n30::text || ' sent · ' || v.ok30::text || ' delivered · '
                             || v.bad30::text || ' failed',
           'fail_reason',    coalesce(v.top_fail, '—'),
           'ever_fired',     (v.total_all > 0),
           'last_fired',     case when v.last_at > 'epoch'::timestamptz
                                  then to_char(v.last_at at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM')
                                  else 'Never' end,
           'verdict',        v.verdict,
           'verdict_tone',   case v.verdict when 'WORKING' then 'success'
                                            when 'BROKEN' then 'danger' else 'warning' end,
           'note',           coalesce(nullif(btrim(coalesce(v.pipeline_note,'')),''), '—')
         ) order by
           case v.verdict when 'BROKEN' then 0 when 'NEVER FIRED' then 1 else 2 end,
           v.audience, v.event_key)
    into v_rows
    from verdicted v;

  v_rows   := coalesce(v_rows, '[]'::jsonb);
  select count(*) filter (where x->>'verdict' = 'BROKEN'),
         count(*) filter (where x->>'verdict' = 'NEVER FIRED'),
         count(*) filter (where x->>'verdict' = 'WORKING')
    into v_broken, v_never, v_working
    from jsonb_array_elements(v_rows) x;

  return jsonb_build_object(
    'ok', true,
    'title', 'WhatsApp delivery diagnosis',
    'subtitle', 'Every event route except the supplier audience · last '
                || v_days::text || ' days · times IST',
    'window_days', v_days,
    'summary', jsonb_build_array(
      jsonb_build_object('label','Working',     'value', v_working::text, 'tone','success'),
      jsonb_build_object('label','Broken',      'value', v_broken::text,  'tone','danger'),
      jsonb_build_object('label','Never fired', 'value', v_never::text,   'tone','warning')),
    'columns', jsonb_build_array('Event','Audience','Template','Emitting',
                                 'Last ' || v_days::text || ' days','Verdict'),
    'legend', 'WORKING = an approved template, an emitter that uses the route, and more '
              || 'delivered than failed. BROKEN = disabled, no approved template, a variable '
              || 'mismatch, or an emitter still sending free-form. NEVER FIRED = the route has '
              || 'never produced a single message.',
    'empty_text', 'No event routes outside the supplier audience.',
    'rows', v_rows);
end $function$;

revoke all on function public.wa_event_diagnosis(integer) from public, anon;
grant execute on function public.wa_event_diagnosis(integer) to authenticated, service_role;
