-- CHANGE #572 (repair found while going green) — _synthetic_outbound_gate()
-- crashed on two of the three tables it guards.
--
-- The gate is one trigger function on wa_campaign_recipients,
-- notification_retry_queue and whatsapp_messages, and it read the destination
-- with a CASE over three DIFFERENT column names:
--   new.phone / new.recipient / new.sender_phone.
-- plpgsql resolves every NEW field in that expression against the row type it
-- is actually firing on, so on wa_campaign_recipients (which has `phone` and
-- no `recipient`) the statement died with
--   record "new" has no field "recipient"
-- the moment is_synthetic was true. rg_check's wa_campaign_guards and
-- wa_send_safety behaviours are exactly the two that insert a synthetic
-- recipient, which is why both were red.
--
-- The columns are unchanged; only the lookup is. to_jsonb(new)->>'…' asks the
-- row for a key instead of the compiler for a field, so a name that does not
-- exist on this table reads as NULL rather than aborting the insert.
create or replace function public._synthetic_outbound_gate()
returns trigger
language plpgsql security definer
set search_path to 'public'
as $function$
declare v_to text; v_new jsonb;
begin
  if not coalesce(new.is_synthetic,false) then return new; end if;
  v_new := to_jsonb(new);

  v_to := case tg_table_name
            when 'wa_campaign_recipients'    then v_new->>'phone'
            when 'notification_retry_queue'  then v_new->>'recipient'
            when 'whatsapp_messages'         then v_new->>'sender_phone'
          end;

  if public.synthetic_outbound_allowed(v_to) then
    return new;                              -- Om's own test number, on purpose
  end if;

  if tg_table_name = 'wa_campaign_recipients' then
    new.status      := 'skipped';
    new.skip_reason := 'synthetic_suppressed';
    return new;                              -- kept as evidence, never sent
  end if;

  if tg_table_name = 'whatsapp_messages' then
    if coalesce(v_new->>'direction','') <> 'out' then return new; end if;
    new.wa_status      := 'suppressed';
    new.wa_fail_reason := 'synthetic_suppressed';
    return new;
  end if;

  return null;                               -- retry queue: never enqueued
end $function$;
