-- CHANGE #293 — 360 audit of #291 (Razorpay). Part A: schema.
--
-- What #291 left open, proven against the live DB:
--   * payment_config had a BOOLEAN razorpay_qr_enabled, not the specced
--     two-option collection_mode selector.
--   * no razorpay_webhook_log — inbound events were not recorded at all.
--   * payment_claims carried no zone / business date, so a zone-wise and
--     date-wise collection summary was impossible.
--   * nowhere to hold "where the money lands" for the gateway.
-- Everything here is idempotent: a resumed worker re-applies it as a no-op.

-- ── 1. payment_config: ONE switch, plus where the gateway money lands ──────
alter table public.payment_config add column if not exists collection_mode text;

update public.payment_config
   set collection_mode = case when coalesce(razorpay_qr_enabled,false)
                              then 'gateway' else 'manual_upi' end
 where collection_mode is null;

alter table public.payment_config alter column collection_mode set default 'manual_upi';
update public.payment_config set collection_mode = 'manual_upi' where collection_mode is null;
alter table public.payment_config alter column collection_mode set not null;

do $$ begin
  alter table public.payment_config
    add constraint payment_config_collection_mode_chk
    check (collection_mode in ('manual_upi','gateway'));
exception when duplicate_object then null; end $$;

alter table public.payment_config
  add column if not exists rzp_account_name      text,
  add column if not exists rzp_settlement_bank   text,
  add column if not exists rzp_settlement_last4  text,
  add column if not exists rzp_settlement_cycle  text,
  add column if not exists rzp_account_synced_at timestamptz;

-- The legacy boolean stays as a MIRROR of collection_mode, in BOTH directions,
-- so "no second toggle anywhere" is true by construction: any reader still on
-- razorpay_qr_enabled cannot disagree with the selector, and any writer still
-- flipping the boolean moves the selector with it.
create or replace function public._trg_payment_config_mode_mirror()
returns trigger
language plpgsql
as $function$
begin
  if TG_OP = 'UPDATE'
     and NEW.razorpay_qr_enabled is distinct from OLD.razorpay_qr_enabled
     and NEW.collection_mode is not distinct from OLD.collection_mode then
    NEW.collection_mode := case when NEW.razorpay_qr_enabled
                                then 'gateway' else 'manual_upi' end;
  end if;
  NEW.collection_mode    := case when NEW.collection_mode = 'gateway'
                                 then 'gateway' else 'manual_upi' end;
  NEW.razorpay_qr_enabled := (NEW.collection_mode = 'gateway');
  return NEW;
end $function$;

drop trigger if exists trg_payment_config_mode_mirror on public.payment_config;
create trigger trg_payment_config_mode_mirror
before insert or update on public.payment_config
for each row execute function public._trg_payment_config_mode_mirror();

-- The one place anything asks "which collection mode are we in?".
create or replace function public.payment_collection_mode()
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((select collection_mode from public.payment_config where id = 1),
                  'manual_upi');
$function$;

-- ── 2. payment_claims: stamp zone + business date on every collection ─────
alter table public.payment_claims
  add column if not exists zone_id       smallint,
  add column if not exists business_date date;

create index if not exists payment_claims_scope_idx
  on public.payment_claims (business_date, zone_id);

-- The order is the authority for both. A claim that arrives unlinked still
-- gets a business date (IST day of receipt) so it can never fall out of the
-- date-scoped summary; autolink later restamps it with the order's own scope.
create or replace function public._trg_payment_claim_scope()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_zone smallint; v_date date;
begin
  if NEW.order_id is not null then
    select o.zone_id, o.order_date into v_zone, v_date
      from public.orders o where o.id = NEW.order_id;
  end if;
  NEW.zone_id       := coalesce(v_zone, NEW.zone_id);
  NEW.business_date := coalesce(v_date, NEW.business_date,
    (coalesce(NEW.received_at, NEW.created_at, now()) at time zone 'Asia/Kolkata')::date);
  return NEW;
end $function$;

drop trigger if exists trg_payment_claim_scope on public.payment_claims;
create trigger trg_payment_claim_scope
before insert or update of order_id on public.payment_claims
for each row execute function public._trg_payment_claim_scope();

-- Backfill (plain column update — does not re-enter the trigger above).
update public.payment_claims pc
   set zone_id = o.zone_id, business_date = o.order_date
  from public.orders o
 where o.id = pc.order_id
   and (pc.zone_id is distinct from o.zone_id
     or pc.business_date is distinct from o.order_date);

update public.payment_claims
   set business_date = (coalesce(received_at, created_at) at time zone 'Asia/Kolkata')::date
 where business_date is null;

-- ── 3. razorpay_webhook_log — every inbound event, handled or not ─────────
create table if not exists public.razorpay_webhook_log (
  id            bigserial primary key,
  received_at   timestamptz not null default now(),
  event         text,
  rzp_event_id  text,
  payload_id    text,
  handled       boolean not null default false,
  result        jsonb
);
create index if not exists razorpay_webhook_log_received_idx
  on public.razorpay_webhook_log (received_at desc);
create index if not exists razorpay_webhook_log_event_idx
  on public.razorpay_webhook_log (event);

alter table public.razorpay_webhook_log enable row level security;
do $$ begin
  create policy razorpay_webhook_log_admin_read on public.razorpay_webhook_log
    for select using (public.get_my_role() = any (array['admin','super_admin']));
exception when duplicate_object then null; end $$;

-- ── 4. copy — every new display string lives in the backend ───────────────
insert into public.razorpay_copy (key, value) values
  ('mode_manual_label',    'Manual UPI'),
  ('mode_manual_helper',   'Customers scan the shared UPI QR and send a screenshot. An admin verifies each payment by hand.'),
  ('mode_gateway_label',   'Payment Gateway'),
  ('mode_gateway_helper',  'Every payment gets its own Razorpay QR and confirms itself. No screenshot, no manual check.'),
  ('lands_title',          'Where the money lands'),
  ('lands_manual_caption', 'Collected into the active UPI account'),
  ('lands_gateway_caption','Collected by Razorpay and settled to your bank'),
  ('lands_vpa_label',      'UPI ID'),
  ('lands_payee_label',    'Payee name'),
  ('lands_account_label',  'Razorpay account'),
  ('lands_bank_label',     'Settlement bank'),
  ('lands_cycle_label',    'Settlement cycle'),
  ('lands_missing',        'Not set yet'),
  ('lands_no_vpa',         'No active UPI account. Add one below.'),
  ('collection_title',     'Collected'),
  ('collection_empty',     'No payments collected in this zone on this date.'),
  ('collection_total_label',   'Total collected'),
  ('collection_orders_label',  'Orders'),
  ('collection_verified_label','Verified'),
  ('collection_pending_label', 'Pending'),
  ('collection_mode_gateway',  'Payment Gateway'),
  ('collection_mode_manual',   'Manual UPI'),
  ('collection_mode_cash',     'Cash'),
  ('checkout_btn_place',   'Place Order'),
  ('checkout_btn_pay',     'Pay & Place Order'),
  ('checkout_pay_title',   'Pay to confirm your order'),
  ('checkout_actingas_note','Order placed. The payment QR has been sent to the customer on WhatsApp.'),
  ('checkout_paid_toast',  'Payment received — order confirmed'),
  ('closed_label',         'This QR was closed before it was paid.')
on conflict (key) do nothing;
