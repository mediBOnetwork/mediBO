-- CHANGE #425 — EXPIRY RADAR, part 2: WhatsApp is the app.
--
-- The desktop-less pharmacy never opens a dashboard. So every loop in this
-- command has to close over WhatsApp alone: we ask, they tap, the shelf moves.
-- Four loops, all on the existing WABA and the #297 window rules:
--   1. urgent ping   — the single most expensive batch, with the ask attached
--   2. one-tap answer — a number comes back, the lot is corrected, velocity gets
--                       its ground truth
--   3. bill intake   — a forwarded photo becomes a vault bill, read, confirmed
--   4. monthly digest — bills captured, stock value, money at risk
--
-- GUARD, and it is a hard one: during the build phase _c425_may_send() admits
-- ONLY the numbers listed in app_settings.expiry_radar.test_numbers, and never
-- a supplier number in any phase. The scan cannot reach a real pharmacy even
-- if someone points it at one.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE ONE SEND DOOR
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c425_phone(p_shop uuid)
returns text language sql stable set search_path to 'public' as $$
  select nullif(right(regexp_replace(
           coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''), '\D','','g'), 10), '')
    from public.pharmacy_profiles pp where pp.id = p_shop;
$$;

-- Send one radar message. Returns the reason it did NOT go, when it did not:
-- nothing here fails silently, and nothing here bypasses the guard.
create or replace function public._c425_send(
  p_shop uuid, p_kind text, p_dedupe text, p_event_key text,
  p_text text, p_vars jsonb, p_needs_optin boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare
  v_cfg   public.pharmacy_radar_config := public._c425_config(p_shop);
  v_phone text := public._c425_phone(p_shop);
  v_win   jsonb; v_open boolean; v_res jsonb; v_req bigint;
begin
  if p_needs_optin and not v_cfg.opt_in then
    return jsonb_build_object('ok', false, 'reason','not_opted_in');
  end if;
  if v_phone is null then
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;
  if not public._c425_may_send(v_phone) then
    return jsonb_build_object('ok', false, 'reason','send_guard');
  end if;
  if public._c425_week_count(p_shop) >= v_cfg.max_msgs_per_week then
    return jsonb_build_object('ok', false, 'reason','weekly_cap');
  end if;
  if exists (select 1 from public.pharmacy_radar_send_log
              where pharmacy_id = p_shop and kind = p_kind and dedupe_key = p_dedupe) then
    return jsonb_build_object('ok', false, 'reason','duplicate');
  end if;

  insert into public.pharmacy_radar_send_log (pharmacy_id, kind, dedupe_key, detail)
  values (p_shop, p_kind, p_dedupe,
          jsonb_build_object('text', p_text, 'vars', coalesce(p_vars,'{}'::jsonb)))
  on conflict do nothing;

  v_win  := public.notify_window(v_phone);
  v_open := coalesce((v_win->>'open')::boolean, false);

  -- Inside the 24-hour service window a free-form reply is legal and instant.
  -- Outside it, only an approved template may go — notify() owns that decision
  -- and queues when there is nothing legal to send.
  if v_open then
    select net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body    := jsonb_build_object('to', v_phone, 'tag', p_kind, 'text', p_text),
      timeout_milliseconds := 20000) into v_req;
    v_res := jsonb_build_object('ok', true, 'path','freeform', 'request_id', v_req);
  else
    v_res := public.notify(p_event_key, v_phone,
               coalesce(p_vars,'{}'::jsonb) || jsonb_build_object('customer_id', p_shop::text));
  end if;

  update public.pharmacy_radar_send_log
     set detail = detail || jsonb_build_object('result', v_res, 'window_open', v_open)
   where pharmacy_id = p_shop and kind = p_kind and dedupe_key = p_dedupe;

  return jsonb_build_object('ok', coalesce((v_res->>'ok')::boolean, false),
                            'window_open', v_open, 'detail', v_res);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE URGENT PING — one shop, one message, the most expensive mistake
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_radar_scan(p_limit integer default 40)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  sh record; r public.c425_radar_row; v_cfg public.pharmacy_radar_config;
  v_g jsonb := public._c425_cfg();
  v_sent integer := 0; v_skipped integer := 0; v_asks integer := 0;
  v_ask_id uuid; a public.pharmacy_radar_ask; v_text text; v_res jsonb;
  v_batch text; v_reasons jsonb := '{}'::jsonb;
begin
  if not coalesce((v_g->>'enabled')::boolean, false) then
    return jsonb_build_object('ok', true, 'skipped','disabled');
  end if;

  for sh in
    select pp.id, pp.pharmacy_name
      from public.pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false and coalesce(pp.approved,false)
       and exists (select 1 from public.pharmacy_stock s
                    where s.pharmacy_id = pp.id and coalesce(s.qty,0) > 0)
     order by pp.id
     limit greatest(coalesce(p_limit,40),1)
  loop
    v_cfg := public._c425_config(sh.id);
    if not v_cfg.urgent_enabled then
      v_skipped := v_skipped + 1; continue;
    end if;

    -- The most expensive MISTAKE this shop is about to make, above its own
    -- floor. Two ways to still act on it: the supplier will take it back
    -- (window open), or there is enough time left to sell it down
    -- (alert_days). A closed window is not a reason to stay quiet — it is
    -- exactly when the shop has to push the stock itself.
    select * into r from public._c425_rows(sh.id) x
     where x.expected_loss >= v_cfg.min_expected_loss
       and x.days_to_expiry >= 0
       and (x.window_state = 'open'
            or x.days_to_expiry <= coalesce((v_g->>'alert_days')::int, 60))
     order by x.expected_loss desc, x.days_to_expiry
     limit 1;

    if r.stock_id is null then
      v_skipped := v_skipped + 1; continue;
    end if;

    -- The ask rides WITH the alert: the pharmacy answers the question that the
    -- alert itself raised, and the answer lands straight in the truth loop.
    if v_cfg.ask_corrections then
      v_ask_id := public._c425_ask_open(sh.id, r.stock_id, 'whatsapp');
      if v_ask_id is not null then v_asks := v_asks + 1; end if;
    end if;

    v_batch := case when coalesce(btrim(coalesce(r.batch_no,'')),'') = ''
                    then public.ui_text('phradar.no_batch')
                    else public.ui_fmt('phradar.batch_label',
                           jsonb_build_object('batch', r.batch_no)) end;

    v_text := public.ui_fmt('phradar.wa_urgent', jsonb_build_object(
      'product',    coalesce(r.product_name,''),
      'batch_word', v_batch,
      'date',       to_char(r.expiry_on, 'DD/MM/YY'),
      'value',      public.inr_money(r.expected_loss),
      'days',       greatest(coalesce(r.days_to_close, r.days_to_expiry), 0)::text));

    v_res := public._c425_send(sh.id, 'radar_urgent',
      r.stock_id::text || ':' || to_char(public._c413_today(), 'IYYY-"W"IW'),
      'pharmacy_radar_urgent', v_text,
      jsonb_build_object('product', coalesce(r.product_name,''),
                         'batch', v_batch,
                         'date', to_char(r.expiry_on, 'DD/MM/YY'),
                         'value', public.inr_money(r.expected_loss),
                         'days', greatest(coalesce(r.days_to_close, r.days_to_expiry),0)::text));

    if coalesce((v_res->>'ok')::boolean, false) then
      v_sent := v_sent + 1;
    else
      v_skipped := v_skipped + 1;
      v_reasons := v_reasons || jsonb_build_object(
        coalesce(v_res->>'reason', v_res#>>'{detail,reason}', 'unknown'),
        coalesce((v_reasons->>coalesce(v_res->>'reason', v_res#>>'{detail,reason}','unknown'))::int,0) + 1);
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'sent', v_sent, 'skipped', v_skipped,
                            'asks', v_asks, 'reasons', v_reasons);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE MONTHLY DIGEST — purchases captured, expiry risk, stock value
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_radar_month_scan(p_limit integer default 40)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  sh record; v_cfg public.pharmacy_radar_config;
  v_month text := to_char(public._c413_today(), 'YYYY-MM');
  v_bills integer; v_stock numeric; v_risk numeric; v_items integer;
  v_text text; v_res jsonb; v_sent integer := 0; v_skipped integer := 0;
begin
  for sh in
    select pp.id, pp.pharmacy_name from public.pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false and coalesce(pp.approved,false)
     order by pp.id limit greatest(coalesce(p_limit,40),1)
  loop
    v_cfg := public._c425_config(sh.id);
    if not v_cfg.monthly_digest then v_skipped := v_skipped + 1; continue; end if;

    select count(*) into v_bills from public.pharmacy_purchase_bill
     where pharmacy_id = sh.id
       and created_at >= date_trunc('month', now() at time zone 'Asia/Kolkata');

    select coalesce(sum(coalesce(qty,0)*coalesce(unit_cost,0)),0) into v_stock
      from public.pharmacy_stock where pharmacy_id = sh.id and coalesce(qty,0) > 0;

    select count(*), coalesce(sum(expected_loss),0) into v_items, v_risk
      from public._c425_rows(sh.id)
     where bucket_key in ('expired','d30','d60','d90') and expected_loss > 0;

    if v_bills = 0 and v_risk = 0 then v_skipped := v_skipped + 1; continue; end if;

    v_text := public.ui_fmt('phradar.wa_digest', jsonb_build_object(
      'shop',  coalesce(sh.pharmacy_name,''),
      'bills', v_bills::text,
      'stock', public.inr_money(v_stock),
      'value', public.inr_money(v_risk),
      'items', v_items::text));

    v_res := public._c425_send(sh.id, 'radar_month', v_month,
      'pharmacy_radar_month', v_text,
      jsonb_build_object('shop', coalesce(sh.pharmacy_name,''),
                         'bills', v_bills::text,
                         'stock', public.inr_money(v_stock),
                         'value', public.inr_money(v_risk),
                         'items', v_items::text));
    if coalesce((v_res->>'ok')::boolean, false)
      then v_sent := v_sent + 1; else v_skipped := v_skipped + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'month', v_month,
                            'sent', v_sent, 'skipped', v_skipped);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE ONE-TAP ANSWER COMING BACK
--
-- Same shape as #173's reorder gate: we only read a number as an answer when
-- WE asked. A "2" typed in an ordinary chat is never a stock correction.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.app_settings(key, value) values
 ('radar_wa_inbound', jsonb_build_object(
    'enabled', true,
    'zero_words', jsonb_build_array('0','zero','none','nil','khatam','khatm',
                                    'finished','over','sab bik gaya','nothing','no stock')))
on conflict (key) do nothing;

create or replace function public.radar_wa_inbound(p_phone text, p_text text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_cfg jsonb; v_norm text; v_ph text; v_shop uuid;
  a public.pharmacy_radar_ask; v_qty numeric; v_res jsonb;
begin
  select value into v_cfg from public.app_settings where key = 'radar_wa_inbound';
  if not coalesce((v_cfg->>'enabled')::boolean, false) then
    return jsonb_build_object('handled', false, 'reason','disabled');
  end if;

  v_norm := btrim(regexp_replace(lower(coalesce(p_text,'')), '[^a-z0-9 ]', '', 'g'));
  v_norm := regexp_replace(v_norm, '\s+', ' ', 'g');
  if v_norm = '' then return jsonb_build_object('handled', false, 'reason','empty'); end if;

  v_ph := public.wa_normalize_phone(p_phone);
  select id into v_shop from public.pharmacy_profiles
   where public.wa_normalize_phone(coalesce(nullif(btrim(whatsapp_no),''), phone)) = v_ph
     and coalesce(is_deleted,false) = false
   limit 1;
  if v_shop is null then
    return jsonb_build_object('handled', false, 'reason','unknown_pharmacy');
  end if;

  -- THE GATE: an open ask, or this is not an answer at all.
  select * into a from public.pharmacy_radar_ask
   where pharmacy_id = v_shop and status = 'open'
   order by created_at desc limit 1;
  if a.id is null then
    return jsonb_build_object('handled', false, 'reason','no_open_ask');
  end if;

  if exists (select 1 from jsonb_array_elements_text(coalesce(v_cfg->'zero_words','[]'::jsonb)) t
              where t = v_norm) then
    v_qty := 0;
  elsif v_norm ~ '^[0-9]{1,5}$' then
    v_qty := v_norm::numeric;
  elsif v_norm ~ '^[0-9]{1,5} ' then           -- "4 left", "2 bache"
    v_qty := (regexp_match(v_norm, '^([0-9]{1,5}) '))[1]::numeric;
  else
    return jsonb_build_object('handled', false, 'reason','not_a_number');
  end if;

  v_res := public._c425_apply_answer(a.id, v_qty, 'whatsapp');
  return jsonb_build_object('handled', coalesce((v_res->>'ok')::boolean, false),
    'action','radar_answer', 'phone', v_ph, 'pharmacy_id', v_shop,
    'ask_id', a.id, 'qty', v_qty, 'reply', v_res->>'message');
end $$;

grant execute on function public.radar_wa_inbound(text, text) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. BILL BY WHATSAPP — a forwarded photo becomes a vault bill
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.radar_wa_bill_intake(p_message_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  m public.whatsapp_messages; v_ph text; v_shop uuid;
  v_cfg public.pharmacy_radar_config; v_bill uuid; v_no integer;
  v_bucket text; v_path text; v_intake uuid;
begin
  select * into m from public.whatsapp_messages where id = p_message_id;
  if not found then return jsonb_build_object('ok', false, 'reason','no_message'); end if;
  if coalesce(m.direction,'') <> 'in' then
    return jsonb_build_object('ok', false, 'reason','not_inbound');
  end if;
  if coalesce(m.msg_type,'') not in ('image','document') then
    return jsonb_build_object('ok', false, 'reason','not_media');
  end if;

  v_bucket := coalesce(nullif(btrim(coalesce(m.media_bucket,'')),''), 'whatsapp-media');
  v_path   := nullif(btrim(coalesce(m.file_path,'')), '');
  if v_path is null then return jsonb_build_object('ok', false, 'reason','no_path'); end if;

  v_ph := public.wa_normalize_phone(m.sender_phone);
  select id into v_shop from public.pharmacy_profiles
   where public.wa_normalize_phone(coalesce(nullif(btrim(whatsapp_no),''), phone)) = v_ph
     and coalesce(is_deleted,false) = false
   limit 1;

  if v_shop is null then
    insert into public.pharmacy_wa_intake (message_id, phone, bucket, path, status, reason)
    values (p_message_id, v_ph, v_bucket, v_path, 'ignored', 'unknown_pharmacy')
    on conflict (message_id) do nothing;
    return jsonb_build_object('ok', false, 'reason','unknown_pharmacy');
  end if;

  v_cfg := public._c425_config(v_shop);
  -- The registered number only, the shop's own switch, and — while the build
  -- phase is on — Om's test numbers only. A real pharmacy's chat is untouched.
  if not v_cfg.wa_intake or not public._c425_may_send(v_ph) then
    insert into public.pharmacy_wa_intake (pharmacy_id, message_id, phone, bucket, path, status, reason)
    values (v_shop, p_message_id, v_ph, v_bucket, v_path, 'ignored',
            case when v_cfg.wa_intake then 'send_guard' else 'intake_off' end)
    on conflict (message_id) do nothing;
    return jsonb_build_object('ok', false, 'reason','guarded');
  end if;

  insert into public.pharmacy_wa_intake (pharmacy_id, message_id, phone, bucket, path, status)
  values (v_shop, p_message_id, v_ph, v_bucket, v_path, 'received')
  on conflict (message_id) do nothing
  returning id into v_intake;
  if v_intake is null then
    return jsonb_build_object('ok', false, 'reason','already_taken');
  end if;

  -- The vault's own row shape (#423), created service-side because WhatsApp
  -- carries no auth session.
  v_bill := gen_random_uuid();
  insert into public.pharmacy_purchase_bill (
    id, pharmacy_id, source, status, bucket, path, shot_count)
  values (v_bill, v_shop, 'whatsapp', 'draft', v_bucket, v_path, 0);

  select coalesce(max(shot_no),0) + 1 into v_no
    from public.pharmacy_bill_shot where bill_id = v_bill;
  insert into public.pharmacy_bill_shot (bill_id, shot_no, bucket, path)
  values (v_bill, v_no, v_bucket, v_path)
  on conflict (bill_id, shot_no) do nothing;

  update public.pharmacy_purchase_bill
     set shot_count = 1, status = 'queued', queued_at = now()
   where id = v_bill;

  update public.pharmacy_wa_intake
     set bill_id = v_bill, status = 'queued' where id = v_intake;

  perform public._phv_dispatch(v_bill);

  return jsonb_build_object('ok', true, 'intake_id', v_intake, 'bill_id', v_bill,
    'pharmacy_id', v_shop, 'phone', v_ph,
    'reply', public.ui_text('phradar.wa_received'));
end $$;

grant execute on function public.radar_wa_bill_intake(uuid) to service_role;

-- What we read, sent back. It runs as a sweep rather than inside #423's OCR
-- report, so the vault owns its own pipeline and this command owns its own
-- messages — neither has to know about the other.
create or replace function public.pharmacy_radar_bill_confirm_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  i record; b public.pharmacy_purchase_bill; v_text text; v_res jsonb;
  v_sent integer := 0; v_failed integer := 0;
begin
  for i in
    select * from public.pharmacy_wa_intake
     where status in ('received','queued') and read_notified_at is null
       and bill_id is not null
     order by created_at limit 20
  loop
    select * into b from public.pharmacy_purchase_bill where id = i.bill_id;
    if not found then continue; end if;

    if b.status in ('review','confirmed','applied') then
      v_text := case when coalesce(b.unreadable_count,0) > 0
        then public.ui_fmt('phradar.wa_read_partial',
               jsonb_build_object('lines', coalesce(b.line_count,0)::text))
        else public.ui_fmt('phradar.wa_read', jsonb_build_object(
               'supplier', coalesce(nullif(btrim(coalesce(b.supplier_name,'')),''), '-'),
               'invoice',  coalesce(nullif(btrim(coalesce(b.invoice_no,'')),''), '-'),
               'lines',    coalesce(b.line_count,0)::text,
               'total',    public.inr_money(coalesce(b.total_amount,0)))) end;
      v_res := public._c425_send(i.pharmacy_id, 'radar_bill_read', i.id::text,
        'pharmacy_bill_read', v_text,
        jsonb_build_object('supplier', coalesce(b.supplier_name,'-'),
                           'invoice', coalesce(b.invoice_no,'-'),
                           'lines', coalesce(b.line_count,0)::text,
                           'total', public.inr_money(coalesce(b.total_amount,0))),
        false);
      update public.pharmacy_wa_intake
         set status = 'read', read_notified_at = now(),
             detail = detail || jsonb_build_object('send', v_res)
       where id = i.id;
      v_sent := v_sent + 1;

    elsif b.status = 'failed' then
      v_res := public._c425_send(i.pharmacy_id, 'radar_bill_failed', i.id::text,
        'pharmacy_bill_read', public.ui_text('phradar.wa_failed'),
        jsonb_build_object('reason', coalesce(b.ocr_error,'')), false);
      update public.pharmacy_wa_intake
         set status = 'failed', read_notified_at = now(), reason = b.ocr_error,
             detail = detail || jsonb_build_object('send', v_res)
       where id = i.id;
      v_failed := v_failed + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'read', v_sent, 'failed', v_failed);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE INBOUND TRIGGER — one row per message, never blocking the message
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.trg_c425_wa_inbound()
returns trigger language plpgsql security definer set search_path to 'public','net' as $$
declare v_res jsonb; v_reply text := null; v_to text := null;
begin
  if coalesce(new.direction,'') <> 'in' then return new; end if;

  if coalesce(new.msg_type,'') in ('image','document') then
    v_res := public.radar_wa_bill_intake(new.id);
    if coalesce((v_res->>'ok')::boolean, false) then
      v_reply := v_res->>'reply'; v_to := v_res->>'phone';
    end if;
  elsif coalesce(new.msg_type,'') in ('text','button','interactive')
        and coalesce(btrim(new.text_body),'') <> '' then
    v_res := public.radar_wa_inbound(new.sender_phone, new.text_body);
    if coalesce((v_res->>'handled')::boolean, false) then
      v_reply := v_res->>'reply'; v_to := v_res->>'phone';
    end if;
  end if;

  if coalesce(v_reply,'') <> '' and coalesce(v_to,'') <> ''
     and public._c425_may_send(v_to) then
    perform net.http_post(
      url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027'),
      body := jsonb_build_object('to', v_to, 'tag','radar_reply', 'text', v_reply));
  end if;
  return new;
exception when others then
  return new;   -- a radar failure must NEVER block an inbound message
end $$;

drop trigger if exists c425_wa_inbound_trg on public.whatsapp_messages;
create trigger c425_wa_inbound_trg after insert on public.whatsapp_messages
for each row execute function public.trg_c425_wa_inbound();

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. EVENT ROUTES (template path) and the dispatcher registrations
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.wa_event_routes (event_key, label, description, audience,
  enabled, auto_manage, wa_category, bypass_send_window, dedupe_minutes,
  marketing_guard, variable_map)
values
 ('pharmacy_radar_urgent', 'Pharmacy expiry radar — urgent',
  'CMD #425 — the single batch with the highest EXPECTED LOSS, with the one-tap quantity question attached.',
  'customer', true, true, 'utility', true, 45, true, '{}'::jsonb),
 ('pharmacy_radar_month', 'Pharmacy monthly stock digest',
  'CMD #425 — once a month: bills captured, stock value, money at risk of expiring.',
  'customer', true, true, 'utility', true, 45, true, '{}'::jsonb),
 ('pharmacy_bill_read', 'Pharmacy bill read from WhatsApp',
  'CMD #425 — what the vault read out of a bill photo the pharmacy forwarded.',
  'customer', true, true, 'utility', true, 45, true, '{}'::jsonb)
on conflict (event_key) do nothing;

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled,
                              base_interval_s, note)
values
 ('pharmacy_radar_watch', 425, 'poll',
  'select exists (select 1 from public.pharmacy_stock where coalesce(qty,0) > 0) and exists (select 1 from public.pharmacy_radar_config where opt_in)',
  'select public.pharmacy_radar_scan(40)', true, 3600,
  'CMD #425 — urgent expected-loss ping with the one-tap ask attached.'),
 ('pharmacy_radar_month', 426, 'poll',
  'select (extract(day from (now() at time zone ''Asia/Kolkata''))::int = coalesce((public._c425_cfg()->>''digest_dom'')::int, 1)) and exists (select 1 from public.pharmacy_radar_config where opt_in and monthly_digest)',
  'select public.pharmacy_radar_month_scan(40)', true, 3600,
  'CMD #425 — monthly stock digest over WhatsApp.'),
 ('pharmacy_radar_bill_confirm', 427, 'poll',
  'select exists (select 1 from public.pharmacy_wa_intake where status in (''received'',''queued'') and read_notified_at is null)',
  'select public.pharmacy_radar_bill_confirm_sweep()', true, 120,
  'CMD #425 — tell the pharmacy what we read out of the bill they forwarded.'),
 ('pharmacy_radar_rebind', 428, 'poll',
  'select coalesce((select source from public.pharmacy_radar_binding where id), ''recorded'') = ''recorded''',
  'select public.pharmacy_radar_rebind()', true, 900,
  'CMD #425 — bind the radar to #424''s inference the moment it exists.')
on conflict (name) do nothing;

grant execute on function public.pharmacy_radar_scan(integer) to service_role;
grant execute on function public.pharmacy_radar_month_scan(integer) to service_role;
grant execute on function public.pharmacy_radar_bill_confirm_sweep() to service_role;
