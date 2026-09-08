-- CMD #1916 — the regression guard went red with two CRITICAL behaviour
-- failures, both raising the same error:
--
--     record "new" has no field "created_by_admin"
--
--       c472_delivery_complete_fired_twice
--       c472_refund_request_fired_twice
--
-- Neither is a drift and neither is rebaselineable: the run carried ZERO
-- schema diffs (report.summary = {"diffs":0,"critical":2}), and a behaviour
-- failure is never blessed into a baseline. It is also not CHANGE #1286
-- (command #1896, the PDP redesign) — that deploy is simply what the guard
-- happened to run after.
--
-- THE CAUSE
-- Trigger `customer_event_log` on public.pharmacy_profiles runs
-- public._customer_event_log(), and on the INSERT branch that function reads
-- `new.created_by_admin`. pharmacy_profiles has no such column — it is in no
-- migration, on no branch of this repo, and in no other function on the
-- instance. plpgsql resolves a record field at RUN time, not at CREATE time,
-- so the function was installed cleanly and then raised on the first row.
--
-- Both failing probes insert a pharmacy_profiles row before they can test the
-- edge they are actually about, so the guard was reporting the real damage:
-- EVERY insert into pharmacy_profiles was failing in production — customer
-- self-registration (save_customer_profile) and admin import
-- (admin_import_customer) alike.
--
-- THE FIX
-- Keep the author's intent — an imported customer must not be sent the
-- "welcome, you registered" WhatsApp that event_key 'customer_registration'
-- is routed to — but read that intent from something that exists:
--
--   1. to_jsonb(new)->>'created_by_admin' — NULL, never an error, while the
--      column is absent, and the column's own value the day it is added;
--   2. else is_admin(), which is exactly the gate admin_import_customer
--      demands (`IF NOT is_admin() THEN RAISE 'not_authorized'`) and which a
--      self-registering customer's session never passes.
--
-- And, following tg_notify_profile_event() on this same table, the emit is
-- wrapped so that a NOTIFICATION-OUTBOX trigger can never again refuse a
-- customer registration: a failure is logged to the wa attempt log and the
-- row is still written. The field reference stays OUTSIDE that handler, so
-- the c472 behaviours keep their teeth — this class of bug still turns the
-- guard red instead of being swallowed.
--
-- Idempotent: create or replace only. The trigger itself is untouched.

create or replace function public._customer_event_log()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_key      text;
  v_payload  jsonb := '{}'::jsonb;
  v_by_admin boolean;
begin
  if tg_op = 'INSERT' then
    -- The column if it exists, the admin gate if it does not. Reading it off
    -- to_jsonb(new) is what makes this survive a table that has never carried
    -- the field: a missing key is NULL, not an exception.
    v_by_admin := coalesce(
      (to_jsonb(new) ->> 'created_by_admin')::boolean,
      public.is_admin(),
      false);
    v_key := case when v_by_admin then 'customer_imported' else 'customer_registration' end;
  elsif tg_op = 'UPDATE' then
    if coalesce(new.approved,false) and not coalesce(old.approved,false) then
      v_key := 'customer_approved';
    elsif coalesce(new.status,'') = 'rejected' and coalesce(old.status,'') <> 'rejected' then
      v_key := 'customer_rejected';
    end if;
  end if;

  if v_key is null then return new; end if;

  begin
    v_payload := jsonb_build_object('shop', coalesce(new.pharmacy_name, new.customer_name),
                                    'code', new.customer_code);
    insert into customer_event(customer_id, event_key, payload)
    values (new.id, v_key, v_payload)
    on conflict do nothing;
  exception when others then
    -- Same contract as tg_notify_profile_event: the notification is dropped
    -- and recorded, the customer row still lands.
    begin
      perform public._wa_log_attempt(v_key, new.id, null, 'skipped', false,
                                     'caller_error: ' || sqlerrm);
    exception when others then null;
    end;
  end;

  return new;
end $function$;
