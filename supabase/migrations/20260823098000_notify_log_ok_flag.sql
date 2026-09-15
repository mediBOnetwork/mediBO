-- CHANGE — #297 part 1: notify_log() also fills the columns parts 2 and 3
-- added to notification_log (ok, audience). `ok` matters beyond bookkeeping:
-- _notif_stamp_cost() charges a conversation unless the row says the send did
-- not go out, and a 'queued' row means nothing left the building. Without this
-- every queued send would be billed as if Meta had delivered it.
create or replace function public.notify_log(
  p_event_key text, p_recipient text, p_channel text, p_status text,
  p_path text default null, p_provider_message_id text default null,
  p_failure_reason text default null, p_cost numeric default null,
  p_order_id uuid default null, p_customer_id uuid default null,
  p_vars jsonb default '{}'::jsonb, p_detail jsonb default null)
returns bigint language sql security definer set search_path to 'public' as $$
  insert into public.notification_log(
    event_key, recipient, channel, status, path, provider_message_id,
    failure_reason, cost, order_id, customer_id, vars, detail,
    ok, reason, audience, recipient_id)
  values (p_event_key, coalesce(p_recipient,'unknown'), coalesce(p_channel,'whatsapp'),
          p_status, p_path, p_provider_message_id, p_failure_reason, p_cost,
          p_order_id, p_customer_id,
          coalesce(p_vars,'{}'::jsonb) - 'legacy_url' - 'legacy_body' - '_retry_id',
          p_detail,
          (p_status = 'sent'),
          p_failure_reason,
          (select audience from public.wa_event_routes where event_key = p_event_key),
          p_customer_id)
  returning id;
$$;
