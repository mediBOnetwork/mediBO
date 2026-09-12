-- CHANGE #713 (9/9) — a WhatsApp reply lands in the order's conversation.
--
-- This is the half of the change that makes "one conversation per order" true
-- rather than aspirational. Before it, a customer answering an order
-- notification on WhatsApp wrote into whatsapp_messages and nowhere else: the
-- partner looking at the order saw silence, the ticket thread saw nothing, and
-- the SLA clock never started because, as far as every ops surface knew, the
-- customer had not spoken.
--
-- A SEPARATE trigger from trg_c425_wa_inbound on purpose. That one is the
-- radar/bill-intake bot and swallows its own exceptions; sharing it would mean
-- a bot change could silently stop attaching customer messages. Two triggers,
-- two concerns, and this one is also exception-safe: an inbound message must
-- never be rejected because a thread could not be found.

-- ── which order is this reply about ─────────────────────────────────────────
create or replace function public._c713_wa_thread_for(
  p_phone10 text, p_text text, p_reply_to text)
returns uuid language plpgsql stable security definer set search_path to 'public' as $$
declare v_cust uuid; v_order uuid; v_tid uuid; v_code text;
begin
  if coalesce(p_phone10,'') = '' then return null; end if;

  -- Only a CUSTOMER's words belong in a customer conversation. A supplier or
  -- a rider replying on the same number is another feature's inbound.
  select pp.id into v_cust from public.pharmacy_profiles pp
   where right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone,''),
               '\D','','g'), 10) = p_phone10
   order by pp.created_at limit 1;
  if v_cust is null then return null; end if;

  -- 1. A reply to one of OUR messages is about the order that message named.
  --    notification_log keeps the provider's id, so the link is exact rather
  --    than guessed.
  if coalesce(p_reply_to,'') <> '' then
    select l.order_id into v_order from public.notification_log l
     where l.provider_message_id = p_reply_to and l.order_id is not null
     order by l.created_at desc limit 1;
  end if;

  -- 2. The customer quoted an order code. Their own orders only — a code
  --    belonging to somebody else must not open somebody else's thread.
  if v_order is null and coalesce(p_text,'') <> '' then
    select o.id, o.order_code into v_order, v_code
      from public.orders o
     where o.customer_id = v_cust
       and coalesce(o.order_code,'') <> ''
       and upper(p_text) like '%' || upper(o.order_code) || '%'
     order by o.created_at desc limit 1;
  end if;

  if v_order is not null then
    return public.order_thread_ensure(v_order);
  end if;

  -- 3. Otherwise the conversation they are already having: their latest open
  --    thread. A customer answering "yes" to a notification means the order
  --    they were just told about.
  select t.id into v_tid from public.order_thread t
   where t.customer_id = v_cust and t.status <> 'closed'
   order by coalesce(t.last_message_at, t.created_at) desc limit 1;
  if v_tid is not null then return v_tid; end if;

  -- 4. They have no thread at all: their most recent order gets one.
  select o.id into v_order from public.orders o
   where o.customer_id = v_cust order by o.created_at desc limit 1;
  if v_order is not null then return public.order_thread_ensure(v_order); end if;

  return null;
end $$;

create or replace function public.trg_c713_wa_inbound_thread()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_phone text; v_tid uuid; v_body text; v_att jsonb := '[]'::jsonb; v_name text;
begin
  if coalesce(new.direction,'') <> 'in' then return new; end if;
  if coalesce(new.is_synthetic, false) then return new; end if;

  begin
    v_phone := right(regexp_replace(coalesce(new.sender_phone,''), '\D','','g'), 10);
    v_body  := coalesce(nullif(btrim(new.text_body),''), nullif(btrim(new.caption),''), '');

    -- Media arrives with the bucket and path the intake already wrote; the
    -- thread stores those, never a URL it built.
    if coalesce(new.file_path,'') <> '' then
      v_att := jsonb_build_array(jsonb_build_object(
        'bucket', coalesce(nullif(new.media_bucket,''), 'whatsapp-media'),
        'path',   new.file_path,
        'name',   coalesce(nullif(new.file_name,''), new.msg_type),
        'mime',   coalesce(new.mime_type,'')));
    end if;

    -- A message with neither words nor a file is a delivery receipt, not a
    -- thing anybody said.
    if v_body = '' and jsonb_array_length(v_att) = 0 then return new; end if;

    v_tid := public._c713_wa_thread_for(v_phone, v_body, new.reply_to_wa_id);
    if v_tid is null then return new; end if;

    select pp.pharmacy_name into v_name from public.pharmacy_profiles pp
      join public.order_thread t on t.customer_id = pp.id where t.id = v_tid;

    -- wa_message_id is unique on the message table, so a webhook replay is a
    -- silent no-op rather than the same sentence twice.
    perform public._thread_append(v_tid, v_body, 'customer', null, null,
              coalesce(v_name,''), 'whatsapp', v_att, null,
              new.wa_message_id, v_phone);
  exception when others then null;
  end;
  return new;
end $$;

drop trigger if exists c713_wa_inbound_thread_trg on public.whatsapp_messages;
create trigger c713_wa_inbound_thread_trg after insert on public.whatsapp_messages
  for each row execute function public.trg_c713_wa_inbound_thread();
