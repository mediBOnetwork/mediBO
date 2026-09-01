-- CMD #451 · feature_gaps row 82 — the in-app notification inbox was
-- permanently empty for every customer.
--
-- Two independent faults, both fixed here:
--  1. my_phone10()'s third fallback read `pharmacy_profiles pp where pp.id =
--     auth.uid()`. pharmacy_profiles.id is the CUSTOMER id; the auth id lives
--     in pharmacy_profiles.user_id. So the fallback matched nothing, the
--     function returned NULL, and notif_inbox_list()'s
--     `l.recipient = my_phone10()` arm was dead.
--  2. notification_log.user_id was set on 4 of 735 rows, so the other arm
--     (`l.user_id = auth.uid()`) was dead too. Every writer is now covered by
--     ONE trigger rather than by editing each edge function.

create or replace function public.my_phone10()
returns text
language sql
stable security definer
set search_path to 'public'
as $function$
  select nullif(right(regexp_replace(coalesce(
           (select u.phone from auth.users u where u.id = auth.uid()),
           (select u.raw_user_meta_data->>'phone' from auth.users u where u.id = auth.uid()),
           -- the auth id lives in user_id; id is the customer id (the #451 fix)
           (select coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone)
              from pharmacy_profiles pp where pp.user_id = auth.uid() limit 1),
           -- kept as a last resort: a profile row whose id IS the auth id
           (select coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone)
              from pharmacy_profiles pp where pp.id = auth.uid() limit 1),
           ''), '\D','','g'), 10), '');
$function$;

-- Resolve a 10-digit recipient to the auth user + customer that owns it.
create or replace function public._notif_owner_for_phone(p_phone text)
returns table(user_id uuid, customer_id uuid)
language sql
stable security definer
set search_path to 'public'
as $function$
  select pp.user_id, pp.id
    from pharmacy_profiles pp
   where nullif(right(regexp_replace(
           coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone), '\D','','g'), 10), '')
         = nullif(right(regexp_replace(coalesce(p_phone,''), '\D','','g'), 10), '')
     and pp.user_id is not null
   order by pp.id
   limit 1;
$function$;

-- Every write to notification_log now carries its owner, whoever wrote it —
-- the whatsapp sender, the email sender, push, or a future channel.
create or replace function public._notif_stamp_identity()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_uid uuid; v_cid uuid;
begin
  if new.user_id is null or new.customer_id is null then
    select o.user_id, o.customer_id into v_uid, v_cid
      from public._notif_owner_for_phone(new.recipient) o;
    if new.user_id     is null then new.user_id     := v_uid; end if;
    if new.customer_id is null then new.customer_id := v_cid; end if;
  end if;

  -- an order always knows its own customer, so use it when the phone did not
  if (new.user_id is null or new.customer_id is null) and new.order_id is not null then
    select coalesce(new.user_id, o.user_id) into v_uid from orders o where o.id = new.order_id;
    if new.user_id is null then new.user_id := v_uid; end if;
  end if;
  return new;
end $function$;

drop trigger if exists _notif_stamp_identity_trg on public.notification_log;
create trigger _notif_stamp_identity_trg
before insert on public.notification_log
for each row execute function public._notif_stamp_identity();

