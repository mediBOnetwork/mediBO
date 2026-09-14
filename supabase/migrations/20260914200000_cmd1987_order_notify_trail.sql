-- CMD #1987 — Order WhatsApp never silently vanishes.
--
-- Order CPO140926CHA101O1 (25520698-511a-4fd0-96e8-0b2d6a61c591) proved three
-- independent holes on one order:
--   * wa_send_attempts 55247/55249 — order_placed and order_rejected came back
--     ok=true reason=already_delivered_recently deduped=true. Nothing was sent,
--     because the dedupe key was (event_key, phone) over a 45-minute window and
--     the SAME customer had placed a different order at 2:01 pm. A different
--     order is not a duplicate.
--     Worse: notify_raw then logged that swallow as a SUCCESSFUL template send
--     (path='template', ok=true), which fed the very window that suppressed it —
--     a dedupe that renews itself forever.
--   * 55246/55248/55250 — partner_order_placed, order_cutoff_pay_now and
--     order_cutoff_cancelled reported route_disabled although
--     wa_event_routes.enabled = true. Those rows carry template_name but
--     template_id IS NULL, and wa_send_event collapsed both conditions into one
--     reason, so an unbound route looked switched off and never reached push or
--     email.
--   * notification_log 43580/43582 recorded status='sent' with
--     provider_message_id NULL — the log asserting a delivery that never had a
--     provider id to point at.
--
-- Fixed forward, nothing backfilled.
--
-- Everything below is idempotent: create-or-replace functions, a drop-and-create
-- trigger, and upserted ui_copy rows.

-- ── 1 ── Honest status, derived from the send result ─────────────────────────
-- 'sent' requires a provider id. Everything else names what actually happened,
-- with the reason copied verbatim from the send result.

create or replace function public._notif_derive_status(
  p_status      text,
  p_ok          boolean,
  p_provider_id text,
  p_reason      text)
returns text
language sql
immutable
as $$
  select case
    -- Only a claim of 'sent' is ever rewritten; every other status is the
    -- caller's own word for what it did and is left alone.
    when coalesce(p_status,'') <> 'sent'                        then p_status
    when coalesce(btrim(coalesce(p_provider_id,'')),'') <> ''   then 'sent'
    when coalesce(p_reason,'') ilike '%dedup%'
      or coalesce(p_reason,'') in ('already_delivered_recently',
                                   'legacy_already_delivered')  then 'deduped'
    when coalesce(p_reason,'') in ('route_disabled','notification_off',
                                   'user_opted_out','no_phone','unknown_event',
                                   'test_mode_silenced','suppressed')
                                                                then 'skipped'
    -- Accepted by something upstream but with nothing to prove it by: held, not
    -- sent and not failed.
    when coalesce(p_ok,false)                                   then 'held'
    else 'failed'
  end;
$$;

comment on function public._notif_derive_status(text,boolean,text,text) is
  'CMD #1987 — notification_log.status derived from the send result. sent only with a provider id.';

create or replace function public._notif_status_honest()
returns trigger
language plpgsql
as $function$
declare v_prov text; v_reason text; v_new text;
begin
  v_prov   := coalesce(nullif(btrim(coalesce(new.provider_message_id,'')),''),
                       nullif(btrim(coalesce(new.provider_id,'')),''));
  v_reason := coalesce(nullif(btrim(coalesce(new.reason,'')),''),
                       nullif(btrim(coalesce(new.failure_reason,'')),''));

  v_new := public._notif_derive_status(new.status, new.ok, v_prov, v_reason);

  if v_new is distinct from new.status then
    new.status := v_new;
    -- The row keeps the reason it was written with; when it had none, say why
    -- it was rewritten rather than leaving the downgrade unexplained.
    if v_reason is null then
      new.reason := 'no_provider_id';
    end if;
  end if;

  -- ok is a mirror of status, never an independent claim.
  new.ok := (new.status = 'sent');
  if new.reason is null and v_reason is not null then
    new.reason := v_reason;
  end if;
  return new;
end $function$;

drop trigger if exists trg_notif_status_honest on public.notification_log;
create trigger trg_notif_status_honest
  before insert or update of status, ok, provider_message_id, provider_id
  on public.notification_log
  for each row execute function public._notif_status_honest();

-- ── 2 ── The email channel: a dedupe is not a failure to fall back from ──────
-- Merged into the live definition of _notif_email_after_log (CHANGE #712 era),
-- adding only the guard list. A deduped row means THIS order's message already
-- went out; a row skipped because the route is switched off or the recipient
-- opted out must not be re-sent over email either. Everything else (including
-- a route with no template bound) still falls through to email.

create or replace function public._notif_email_after_log()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record;
begin
  if new.channel not in ('push','whatsapp') then return new; end if;

  -- CMD #1987 — these are not "the message failed, try another channel".
  if new.status = 'deduped'
     or coalesce(new.reason, new.failure_reason,'') in
        ('route_disabled','notification_off','user_opted_out','test_mode_silenced',
         'already_delivered_recently','legacy_already_delivered') then
    return new;
  end if;

  select email_enabled, email_mode into r from wa_event_routes where event_key = new.event_key;
  if not found or r.email_enabled is not true or r.email_mode = 'off' then return new; end if;
  if r.email_mode = 'fallback' and coalesce(new.ok, false) is true then return new; end if;

  begin
    perform public.notif_send_email(
      p_event_key     => new.event_key,
      p_to            => case when position('@' in coalesce(new.recipient,'')) > 0
                              then new.recipient else null end,
      p_vars          => coalesce(new.vars, '{}'::jsonb),
      p_user_id       => new.recipient_id,
      p_order_id      => new.order_id,
      p_parent_log_id => new.id);
  exception when others then
    -- The email channel must never be able to roll back the send it follows.
    insert into notification_log (event_key, channel, status, ok, reason, recipient_id, parent_log_id)
    values (new.event_key, 'email', 'failed', false, left(sqlerrm, 300), new.recipient_id, new.id);
  end;
  return new;
end $function$;

-- ── 3 ── A route with no template bound is not a disabled route ─────────────
-- Merged into the live wa_send_event (CHANGE #294/#295 body kept verbatim);
-- only the guard at the top is split in two.

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
        v_hdr_fmt text; v_hdr jsonb;   -- CHANGE #294
begin
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then return jsonb_build_object('ok', false, 'reason','unknown_event'); end if;

  -- CMD #1987 — ONLY enabled=false is a disabled route. A route that is switched
  -- on but has never had a template bound (template_name set, template_id NULL —
  -- partner_order_placed, order_cutoff_pay_now, order_cutoff_cancelled on 14 Sep)
  -- reports its own reason, so the caller falls through to push/email instead of
  -- treating an unfinished setup as a deliberate silence.
  if not coalesce(r.enabled, false) then
    return jsonb_build_object('ok', false, 'reason','route_disabled');
  end if;
  if r.template_id is null then
    return jsonb_build_object('ok', false, 'reason','no_template_bound',
      'template_name', r.template_name,
      'message','"' || coalesce(r.label, p_event_key) || '" has no WhatsApp template bound yet');
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

  -- CHANGE #294 — a media HEADER must be filled per message, or Meta rejects the
  -- call. Returning here lets wa_send_event_or_fallback reach the fallback route
  -- instead of sending a header-less template.
  v_hdr_fmt := public.wa_template_needs_header_media(v_tid);
  if v_hdr_fmt is not null then
    v_hdr := public.wa_event_header_media(p_event_key, p_order_id);
    if v_hdr is null
       or (coalesce(v_hdr->>'link','') = '' and coalesce(v_hdr->>'path','') = '') then
      return jsonb_build_object('ok', false, 'reason','missing_header_media',
        'template', v_tname, 'header_format', v_hdr_fmt,
        'message','Cannot send "' || r.label || '" — its template needs a '
                  || v_hdr_fmt || ' header and there is none for this order');
    end if;
    v_hdr := v_hdr || jsonb_build_object('type', v_hdr_fmt);
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
  insert into wa_campaign_recipients(campaign_id, customer_id, phone, variables, link_code, is_event, header_media, event_key)
  values (v_cid, v_cust, v_ph, public.wa_render_vars(v_varmap, v_tok), v_code, true, v_hdr, p_event_key)
  returning id into v_rid;

  return jsonb_build_object('ok', true, 'recipient_id', v_rid, 'campaign_id', v_cid,
                            'template', v_tname, 'language', v_tlang, 'queued_for', v_ph,
                            'header_media', v_hdr,
                            'values', public.wa_render_vars(v_varmap, v_tok));
end $function$;

-- ── 4 ── Dedupe is keyed on the ORDER when there is one ──────────────────────
-- Merged into the live wa_send_event_or_fallback (Sep 5 2026 token-synthesis
-- body kept verbatim); the dedupe probe and the fallback-eligible reason list
-- are what changed.

create or replace function public.wa_send_event_or_fallback(
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
declare v jsonb; v_fb text; v2 jsonb; v_mins int; v_ph10 text;
        v_fb_tokens jsonb; v_label text; v_facts text; v_need text;
        v_hit record;
begin
  select coalesce(dedupe_minutes, 45) into v_mins
    from wa_event_routes where event_key = p_event_key;

  v_ph10 := right(regexp_replace(coalesce(p_phone,''),'\D','','g'), 10);

  -- CMD #1987 — the dedupe key is (event_key, order_id) whenever an order is in
  -- play, and only falls back to (event_key, recipient) for order-less events.
  -- A DIFFERENT order is never a duplicate, whatever the window says: on 14 Sep
  -- CPO140926CHA101O1's confirmation was swallowed because the same pharmacy had
  -- ordered 27 minutes earlier.
  -- Only a real template delivery counts as the earlier send — a row written by
  -- the swallow itself never does, which is how the old window renewed itself.
  if v_mins is not null then
    select a.id, a.created_at, a.reason into v_hit
      from wa_send_attempts a
     where a.event_key = p_event_key
       and a.ok
       and a.path in ('template','template_retry')
       and a.created_at > now() - make_interval(mins => v_mins)
       and case
             when p_order_id is not null then a.order_id = p_order_id
             else length(v_ph10) = 10
                  and right(regexp_replace(coalesce(a.phone,''),'\D','','g'),10) = v_ph10
                  and a.order_id is null
           end
     order by a.created_at desc
     limit 1;

    if v_hit.id is not null then
      return jsonb_build_object('ok', false, 'reason','already_delivered_recently',
                                'deduped', true, 'used_event', p_event_key,
                                'dedupe_key', case when p_order_id is not null
                                                   then 'order' else 'recipient' end,
                                'dedupe_of_attempt', v_hit.id,
                                'dedupe_minutes', v_mins);
    end if;
  end if;

  begin
    v := public.wa_send_event_now(p_event_key, p_customer_id, p_tokens, p_phone, p_order_id);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason', 'exception', 'message', sqlerrm);
  end;

  if coalesce((v->>'ok')::boolean, false) then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  -- 'no_template_bound' (CMD #1987) joins the list: an unbound route must reach
  -- the fallback route, and then push/email, instead of dying here.
  if coalesce(v->>'reason','') not in
     ('route_disabled','no_template_bound','template_not_approved','unknown_event',
      'missing_values','missing_header_media','exception')
  then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  -- A route the admin switched OFF is a deliberate silence: never route around it.
  if coalesce(v->>'reason','') = 'route_disabled' then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  select nullif(btrim(coalesce(fallback_event_key,'')),''), coalesce(label, p_event_key)
    into v_fb, v_label
    from wa_event_routes where event_key = p_event_key;
  if v_fb is null then
    return v || jsonb_build_object('used_event', p_event_key);
  end if;

  -- Sep 5 2026: synthesise the fallback route's tokens when the primary alert
  -- did not supply them. Every token the fallback needs but the caller did not
  -- send is filled: command_id → the alert's label, error/reason/question →
  -- "key: value" of everything the caller did send. Nothing is dropped silently.
  v_facts := (select string_agg(k || ': ' || coalesce(nullif(v_t.value,''),'—'), ' · ' order by k)
                from jsonb_each_text(coalesce(p_tokens,'{}'::jsonb)) v_t(k, value));
  v_fb_tokens := coalesce(p_tokens,'{}'::jsonb);
  for v_need in
    select regexp_replace(t, '[{}]', '', 'g')
      from wa_event_routes r, jsonb_array_elements_text(coalesce(r.variable_map,'[]'::jsonb)) t
     where r.event_key = v_fb
  loop
    if not (v_fb_tokens ? v_need) then
      v_fb_tokens := v_fb_tokens || jsonb_build_object(v_need,
        case when v_need in ('command_id','command','id') then v_label
             else coalesce(v_facts, v_label) end);
    end if;
  end loop;

  begin
    v2 := public.wa_send_event_now(v_fb, p_customer_id, v_fb_tokens, p_phone, p_order_id);
  exception when others then
    v2 := jsonb_build_object('ok', false, 'reason', 'exception', 'message', sqlerrm);
  end;

  return v2 || jsonb_build_object('used_event', v_fb,
                                  'primary_event', p_event_key,
                                  'primary_reason', v->>'reason');
end $function$;

-- ── 5 ── notify_raw: record what actually happened ──────────────────────────
-- Merged into the live notify_raw (CMD #1848 test silencing, CHANGE #712 per-user
-- switch and CHANGE #298 push-first all kept verbatim). Three edits:
--   * a dedupe swallow is logged as 'deduped', ok=false, and is NOT written to
--     wa_send_attempts as a template send;
--   * a route the admin switched off is 'skipped' and is not queued for retry;
--   * every log call carries the path that actually carried the message.

create or replace function public.notify_raw(
  p_event_key text,
  p_recipient text default null::text,
  p_vars jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'net'
as $function$
declare
  r            record;
  v            jsonb;
  v_vars       jsonb := coalesce(p_vars, '{}'::jsonb);
  v_channel    text  := coalesce(nullif(v_vars->>'channel',''), 'whatsapp');
  v_order      uuid  := nullif(v_vars->>'order_id','')::uuid;
  v_cust       uuid  := nullif(v_vars->>'customer_id','')::uuid;
  v_url        text  := nullif(v_vars->>'legacy_url','');
  v_body       jsonb := case when v_vars ? 'legacy_body' then v_vars->'legacy_body' end;
  v_force_tpl  boolean := coalesce((v_vars->>'force_template')::boolean, false);
  v_retry      bigint := nullif(v_vars->>'_retry_id','')::bigint;
  v_req        bigint;
  v_tokens     jsonb;
  v_ph         text;
  v_aud        text;
  v_win        jsonb;
  v_open       boolean;
  v_reason     text;
  v_push       jsonb;   -- CHANGE #298
  v_uid        uuid;    -- CHANGE #712 — the recipient, for the per-user switch
begin
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_order_silenced(nullif(p_vars->>'order_id','')::uuid)
     or public.test_customer_silenced(nullif(p_vars->>'customer_id','')::uuid) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  if coalesce(btrim(p_event_key),'') = '' then
    return jsonb_build_object('ok', false, 'reason','no_event_key');
  end if;

  select * into r from public.wa_event_routes where event_key = p_event_key;
  v_aud := coalesce(r.audience, 'customer');

  v_tokens := v_vars - 'order_id' - 'customer_id' - 'legacy_url' - 'legacy_body'
                     - 'channel' - 'force_template' - '_retry_id' - '_no_push';

  v_ph := nullif(right(regexp_replace(coalesce(p_recipient,''),'\D','','g'),10),'');
  if coalesce(length(v_ph),0) <> 10 and v_order is not null then
    v_ph := right(regexp_replace(coalesce(public._order_customer_phone(v_order),''),'\D','','g'),10);
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_cust is not null then
    select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),'\D','','g'),10)
      into v_ph from public.pharmacy_profiles pp where pp.id = v_cust;
  end if;
  if coalesce(length(v_ph),0) <> 10 and v_aud = 'admin' then
    v_ph := right(regexp_replace(
              coalesce((select value #>> '{}' from public.app_settings where key='admin_wa_phone'),''),
              '\D','','g'), 10);
  end if;

  -- No route at all → legacy passthrough, byte-for-byte what the caller used
  -- to post on its own, plus a ledger row.
  if r.event_key is null then
    if v_url is null then
      perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
        null, 'unknown_event', null, v_order, v_cust, v_vars);
      return jsonb_build_object('ok', false, 'reason','unknown_event');
    end if;
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'legacy',
      v_req::text, null, null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', true, 'path','legacy', 'reason','no_route',
                              'request_id', v_req);
  end if;

  if coalesce(length(v_ph),0) <> 10 then
    perform public._wa_log_attempt(p_event_key, v_order, null, 'skipped', false, 'no_phone');
    perform public.notify_log(p_event_key, null, v_channel, 'skipped', 'none',
      null, 'no_phone', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;

  if not public.notif_should_send(v_aud, p_event_key, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'notification_off');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'notification_off', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','notification_off');
  end if;

  -- CHANGE #712 · the per-user switch, honoured on the WIRE and not only in
  -- the settings screen.
  if v_uid is null then
    if v_order is not null then
      select o.user_id into v_uid from public.orders o where o.id = v_order;
    end if;
    if v_uid is null and v_cust is not null then
      select pp.user_id into v_uid from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
  end if;

  if v_uid is not null
     and not public.notif_user_allows(v_uid, v_aud, p_event_key, 'whatsapp')
     and not public.notif_phone_allowlisted(v_aud, v_ph) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, 'user_opted_out');
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'user_opted_out', null, v_order, v_cust, v_vars);
    return jsonb_build_object('ok', false, 'reason','user_opted_out');
  end if;

  v_win  := public.notify_window(v_ph);
  v_open := coalesce((v_win->>'open')::boolean, false);

  -- 0. PUSH FIRST (CHANGE #298). Free and instant, so it is tried before the
  --    paid channel. WhatsApp stays the fallback.
  if not coalesce((v_vars->>'_no_push')::boolean, false) then
    begin
      v_push := public.notif_push_send(p_event_key, v_ph, v_uid, v_order, v_tokens, v_aud);
    exception when others then
      v_push := jsonb_build_object('ok', false, 'reason', 'push_exception',
                                   'message', sqlerrm);
    end;
    if coalesce((v_push->>'ok')::boolean, false) then
      perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'push', true,
                                     coalesce(v_push->>'reason', 'push_queued'), v_push);
      return jsonb_build_object('ok', true, 'path', 'push', 'detail', v_push);
    end if;
  end if;

  -- 1. TEMPLATE FIRST. Always. This is the order_placed fix.
  begin
    v := public.wa_send_event_or_fallback(p_event_key, v_cust, v_tokens, v_ph, v_order);
  exception when others then
    v := jsonb_build_object('ok', false, 'reason','exception', 'message', sqlerrm);
  end;

  -- CMD #1987 — a dedupe swallow is not a send. It is recorded as what it is,
  -- with ok=false, so it can never become the "earlier delivery" that suppresses
  -- the next one, and the log never claims a message that never left.
  if coalesce((v->>'deduped')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'deduped', false,
                                   coalesce(v->>'reason','already_delivered_recently'), v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'deduped', 'deduped',
      null, coalesce(v->>'reason','already_delivered_recently'), null,
      v_order, v_cust, v_vars, v);
    return jsonb_build_object('ok', false, 'path','deduped', 'deduped', true,
                              'reason', coalesce(v->>'reason','already_delivered_recently'),
                              'detail', v);
  end if;

  if coalesce((v->>'ok')::boolean, false) then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'template', true,
                                   coalesce(v->>'used_event', p_event_key), v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'template',
      v->>'recipient_id', null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','template', 'window_open', v_open, 'detail', v);
  end if;

  v_reason := coalesce(v->>'reason','template_failed');

  -- CMD #1987 — a route the admin switched OFF is the one thing that is simply
  -- skipped: no free-form, no retry queue, no email. Everything else keeps
  -- falling through.
  if v_reason = 'route_disabled' then
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false,
                                   'route_disabled', v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'skipped', 'none',
      null, 'route_disabled', null, v_order, v_cust, v_vars, v);
    return jsonb_build_object('ok', false, 'path','skipped', 'reason','route_disabled');
  end if;

  -- 2. FREE-FORM, and only inside the tracked window.
  if v_url is not null and v_open and not v_force_tpl then
    select net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := coalesce(v_body,'{}'::jsonb),
      timeout_milliseconds := 20000) into v_req;
    perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'freeform', true,
                                   'window_open_no_template: ' || v_reason, v);
    perform public.notify_log(p_event_key, v_ph, v_channel, 'sent', 'freeform',
      v_req::text, null, null, v_order, v_cust, v_vars, v);
    if v_retry is not null then
      update public.notification_retry_queue set status='done', updated_at=now() where id = v_retry;
    end if;
    return jsonb_build_object('ok', true, 'path','freeform', 'window_open', true,
                              'reason', v_reason, 'request_id', v_req);
  end if;

  -- 3. Nothing legal to send right now → QUEUE it. Never a silent drop. The
  --    email channel picks this row up from notification_log (_notif_email_after_log).
  perform public._wa_log_attempt(p_event_key, v_order, v_ph, 'skipped', false, v_reason, v);
  perform public.notify_log(p_event_key, v_ph, v_channel, 'queued', 'none',
    null, v_reason, null, v_order, v_cust, v_vars, v);

  if v_retry is not null then
    update public.notification_retry_queue
       set attempts = attempts + 1, last_reason = v_reason,
           next_attempt_at = now() + public.notify_backoff(attempts + 1),
           status = case when attempts + 1 >= max_attempts then 'dead' else 'pending' end,
           updated_at = now()
     where id = v_retry;
  else
    perform public.notify_enqueue_retry(p_event_key, v_ph, v_vars, v_reason,
                                        v_order, v_cust, v_channel, v_force_tpl);
  end if;

  return jsonb_build_object('ok', false, 'path','queued', 'window_open', v_open,
                            'reason', v_reason);
end $function$;

-- ── 6 ── The trail's vocabulary lives in a table, not in a CASE ─────────────
-- Changing "Deduped" to "Duplicate — not sent" is an UPDATE, never a deploy.

create table if not exists public.notif_trail_label (
  kind       text not null,            -- 'status' | 'path' | 'reason'
  code       text not null,
  label      text not null,
  tone       text not null default 'neutral',
  note       text,
  updated_at timestamptz not null default now(),
  primary key (kind, code)
);

alter table public.notif_trail_label enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='notif_trail_label'
                    and policyname='notif_trail_label_read') then
    create policy notif_trail_label_read on public.notif_trail_label
      for select using (true);
  end if;
end $$;

insert into public.notif_trail_label(kind, code, label, tone, note) values
  ('status','sent',     'Sent',            'success', 'Handed to the provider with an id to prove it'),
  ('status','deduped',  'Duplicate',       'warning', 'Suppressed because this order already had this message'),
  ('status','held',     'Held',            'warning', 'Accepted upstream but nothing came back to prove it'),
  ('status','queued',   'Waiting',         'info',    'Nothing legal to send yet — queued for retry'),
  ('status','skipped',  'Skipped',         'neutral', 'Deliberately not sent'),
  ('status','failed',   'Failed',          'danger',  'The send was attempted and did not go'),
  ('path','template',   'WhatsApp template','success',null),
  ('path','freeform',   'WhatsApp message','success', null),
  ('path','push',       'App notification','success', null),
  ('path','email',      'Email',           'success', null),
  ('path','legacy',     'Direct post',     'info',    null),
  ('path','deduped',    'Not sent',        'warning', null),
  ('path','skipped',    'Not sent',        'neutral', null),
  ('path','none',       'No channel',      'neutral', null),
  ('reason','already_delivered_recently','Already sent for this order','warning',null),
  ('reason','legacy_already_delivered',  'Already sent for this order','warning',null),
  ('reason','route_disabled',            'This message is switched off','neutral',null),
  ('reason','no_template_bound',         'No WhatsApp template bound yet','warning',null),
  ('reason','template_not_approved',     'Template not approved by Meta','danger',null),
  ('reason','missing_values',            'A template value was missing','danger',null),
  ('reason','missing_header_media',      'The template needs an image and there was none','danger',null),
  ('reason','notification_off',          'Switched off in Notifications','neutral',null),
  ('reason','user_opted_out',            'The recipient opted out','neutral',null),
  ('reason','no_phone',                  'No phone number on the order','danger',null),
  ('reason','unknown_event',             'No route for this event','danger',null),
  ('reason','suppressed',                'The number is on the suppression list','neutral',null),
  ('reason','test_mode_silenced',        'Test session — nothing leaves the building','info',null),
  ('reason','no_provider_id',            'The provider gave nothing back','danger',null),
  ('reason','push_queued',               'Sent to the device','success',null),
  ('reason','exception',                 'The send raised an error','danger',null)
on conflict (kind, code) do update
  set label = excluded.label, tone = excluded.tone,
      note = excluded.note, updated_at = now();

create or replace function public._notif_trail_label(p_kind text, p_code text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
    (select jsonb_build_object('label', l.label, 'tone', l.tone, 'note', l.note)
       from public.notif_trail_label l
      where l.kind = p_kind and l.code = p_code),
    -- Unknown codes are shown, never swallowed: a reason nobody has worded yet
    -- is still the truth about what happened.
    case when coalesce(btrim(coalesce(p_code,'')),'') = '' then null
         else jsonb_build_object('label', p_code, 'tone','neutral', 'note', null) end);
$$;

-- ── 7 ── The per-order notification trail ───────────────────────────────────
-- Every attempt on one order: what was tried, which path carried it, and why it
-- did or did not go. Zone- and date-scoped like every other admin report —
-- admin_active_zone() (NULL = all zones for a super admin, the partner's own
-- zone for a partner) and admin_active_date() for the day list.

create or replace function public.order_notification_trail(
  p_order_id   uuid default null,
  p_order_code text default null,
  p_limit      int  default 60)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_zone  smallint := public.admin_active_zone();
  v_date  date     := public.admin_active_date();
  v_role  text     := coalesce(public.get_my_role(),'');
  v_ord   record;
  v_rows  jsonb;
  v_orders jsonb;
  v_lim   int := greatest(1, least(coalesce(p_limit, 60), 200));
  v_code  text := nullif(btrim(upper(coalesce(p_order_code,''))),'');
  v_sent  int; v_not  int;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','forbidden',
      'title','Message trail',
      'message','Only an admin can read the message trail');
  end if;

  if p_order_id is not null or v_code is not null then
    select o.id, o.order_code, o.zone_id, o.created_at, o.customer_id, o.status
      into v_ord
      from public.orders o
     where (p_order_id is not null and o.id = p_order_id)
        or (p_order_id is null and upper(o.order_code) = v_code)
     limit 1;

    if v_ord.id is null or (v_zone is not null and v_ord.zone_id is distinct from v_zone) then
      return jsonb_build_object('ok', true, 'mode','not_found',
        'title','Message trail',
        'subtitle', coalesce(v_code, p_order_id::text),
        'empty_label','No order with that code in this zone',
        'empty_hint','Check the code, or switch zone in the header picker',
        'search', jsonb_build_object('hint','Order code, e.g. CPO140926CHA101O1',
                                     'button_label','Show trail'));
    end if;

    -- One row per attempt. wa_send_attempts is what the send path tried;
    -- notification_log is what the ledger recorded. Both are shown, in time
    -- order, so a claim in one and a silence in the other is visible.
    select coalesce(jsonb_agg(t order by t_at desc), '[]'::jsonb), 
           count(*) filter (where t_status = 'sent'),
           count(*) filter (where t_status <> 'sent')
      into v_rows, v_sent, v_not
    from (
      select a.created_at as t_at,
             case when a.ok then 'sent' else coalesce(nullif(a.path,''),'skipped') end as t_status,
             jsonb_build_object(
               'id',          'a' || a.id::text,
               'source_label','Send path',
               'when_label',  to_char(a.created_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am'),
               'event_key',   a.event_key,
               'event_label', coalesce((select r.label from public.wa_event_routes r
                                         where r.event_key = a.event_key), a.event_key),
               'path',        public._notif_trail_label('path', a.path),
               'status',      public._notif_trail_label('status',
                                case when a.ok then 'sent' else
                                  case when a.path = 'deduped' then 'deduped'
                                       when a.path = 'skipped' then 'skipped'
                                       else 'failed' end end),
               'reason',      public._notif_trail_label('reason', a.reason),
               'reason_raw',  a.reason,
               'provider_label', null) as t
        from public.wa_send_attempts a
       where a.order_id = v_ord.id
      union all
      select l.created_at as t_at,
             l.status as t_status,
             jsonb_build_object(
               'id',          'l' || l.id::text,
               'source_label','Ledger',
               'when_label',  to_char(l.created_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am'),
               'event_key',   l.event_key,
               'event_label', coalesce((select r.label from public.wa_event_routes r
                                         where r.event_key = l.event_key), l.event_key),
               'path',        public._notif_trail_label('path', coalesce(nullif(l.path,''), l.channel)),
               'status',      public._notif_trail_label('status', l.status),
               'reason',      public._notif_trail_label('reason',
                                coalesce(nullif(l.reason,''), l.failure_reason)),
               'reason_raw',  coalesce(nullif(l.reason,''), l.failure_reason),
               'provider_label',
                 case when coalesce(nullif(btrim(coalesce(l.provider_message_id, l.provider_id,'')),''),'') <> ''
                      then 'Provider id ' || coalesce(l.provider_message_id, l.provider_id)
                      else 'No provider id' end) as t
        from public.notification_log l
       where l.order_id = v_ord.id
    ) s
    where t is not null
    limit v_lim;

    return jsonb_build_object(
      'ok', true,
      'mode','order',
      'title','Message trail',
      'subtitle', v_ord.order_code,
      'search', jsonb_build_object('hint','Order code, e.g. CPO140926CHA101O1',
                                   'button_label','Show trail'),
      'order', jsonb_build_object(
        'id', v_ord.id,
        'code_label', v_ord.order_code,
        'when_label', to_char(v_ord.created_at at time zone 'Asia/Kolkata','DD Mon yyyy, hh12:mi am'),
        'customer_label', coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp
                                     where pp.id = v_ord.customer_id), '—'),
        'status_label', 'Order ' || coalesce(v_ord.status,'—')),
      'summary_label', case
          when coalesce(v_sent,0) + coalesce(v_not,0) = 0 then 'No message attempts yet'
          else coalesce(v_sent,0)::text || ' sent · ' || coalesce(v_not,0)::text || ' not sent'
        end,
      'summary_tone', case when coalesce(v_sent,0) = 0 then 'warning' else 'success' end,
      'rows_label','Every attempt, newest first',
      'empty_label','No message has been attempted for this order',
      'empty_hint','Nothing has tried to notify anyone about it yet',
      'rows', coalesce(v_rows,'[]'::jsonb));
  end if;

  -- No order asked for → the active zone and the active date, so the screen is
  -- usable without knowing a code.
  select coalesce(jsonb_agg(x order by x->>'sort_at' desc), '[]'::jsonb)
    into v_orders
  from (
    select jsonb_build_object(
             'id', o.id,
             'sort_at', o.created_at,
             'code_label', o.order_code,
             'when_label', to_char(o.created_at at time zone 'Asia/Kolkata','hh12:mi am'),
             'customer_label', coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp
                                          where pp.id = o.customer_id), '—'),
             'summary_label',
               (select case when count(*) = 0 then 'No messages'
                            else count(*) filter (where l.status='sent')::text || ' sent · '
                                 || count(*) filter (where l.status<>'sent')::text || ' not sent'
                       end
                  from public.notification_log l where l.order_id = o.id),
             'tone',
               (select case when count(*) filter (where l.status='sent') > 0 then 'success'
                            when count(*) = 0 then 'neutral'
                            else 'warning' end
                  from public.notification_log l where l.order_id = o.id)) as x
      from public.orders o
     where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
       and (v_zone is null or o.zone_id = v_zone)
     order by o.created_at desc
     limit v_lim) q;

  return jsonb_build_object(
    'ok', true,
    'mode','list',
    'title','Message trail',
    'subtitle', to_char(v_date,'DD Mon yyyy')
                || case when v_zone is null then ' · all zones'
                        else ' · ' || coalesce((select z.name from public.zones z where z.id = v_zone),
                                               'zone ' || v_zone::text) end,
    'search', jsonb_build_object('hint','Order code, e.g. CPO140926CHA101O1',
                                 'button_label','Show trail'),
    'rows_label','Orders on this day',
    'empty_label','No orders on this day in this zone',
    'empty_hint','Change the date or zone in the header picker, or type an order code above',
    'orders', coalesce(v_orders,'[]'::jsonb));
end $function$;

grant execute on function public.order_notification_trail(uuid,text,int) to authenticated;
grant execute on function public._notif_trail_label(text,text) to authenticated;

comment on function public.order_notification_trail(uuid,text,int) is
  'CMD #1987 — per-order notification trail: every attempt, its path and why it did or did not go. Zone/date scoped.';

-- ── 8 ── Screen copy ────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('notif_trail.nav_label',    '"Message trail"'::jsonb),
  ('notif_trail.loading',      '"Reading the trail…"'::jsonb),
  ('notif_trail.retry',        '"Retry"'::jsonb),
  ('notif_trail.back',         '"All orders"'::jsonb),
  ('notif_trail.search_clear', '"Clear"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

insert into public.ui_copy(key, value) values
  ('admin_nav.overflow_notif_trail', '"Message trail"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 9 ── The door ───────────────────────────────────────────────────────────
-- Admin navigation is a BACKEND table (feature_registry → nav_registry()), not
-- a Dart list, so the entry point for this screen is a row. It sits in the same
-- group as WhatsApp Ops — that is where an admin already goes when a shop says
-- "I never got the confirmation". Category and icon are taken from what the
-- target database actually has, so this insert is safe on a trimmed branch as
-- well as on live.

insert into public.feature_registry(
  feature_key, label, group_label, icon_key, route_key, sort_order, owner,
  partner_eligible, default_access, is_active, category, surface,
  roles_allowed, deep_link, search_terms, description, canonical_key, tab_screen)
select
  'admin.notif_trail',
  'Message trail',
  coalesce((select group_label from public.feature_registry where feature_key='admin.wa_ops'),
           'Communication'),
  coalesce((select icon_key from public.ui_icon where icon_key='fact_check'),
           (select icon_key from public.feature_registry where feature_key='admin.wa_ops')),
  'notif_trail',
  61,
  'medibo',
  true,
  'none',
  true,
  coalesce((select category from public.feature_registry where feature_key='admin.wa_ops'),
           (select category_key from public.nav_category where category_key='more_system')),
  'dashboard',
  array['admin','super_admin']::text[],
  '/admin/go/notif_trail',
  'message trail notification whatsapp order sent deduped duplicate not sent why silent',
  'Every notification attempt on one order: the path that tried to carry it, and why it did or did not go.',
  'admin.notif_trail',
  '/admin/go/notif_trail'
on conflict (feature_key) do update
  set label        = excluded.label,
      route_key    = excluded.route_key,
      is_active    = true,
      roles_allowed= excluded.roles_allowed,
      deep_link    = excluded.deep_link,
      search_terms = excluded.search_terms,
      description  = excluded.description;
