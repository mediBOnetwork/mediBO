-- CHANGE #304 — Razorpay Checkout for self-pay: replace the QR-only flow that
-- can never open a UPI app on the payer's own phone.
--
-- #291 shipped the QR Codes API. Razorpay returns image_url and (on this
-- account) a NULL qr_string, so the app could only ever DRAW a picture — and a
-- picture cannot launch PhonePe/GPay on the phone that is displaying it. All 5
-- QRs ever minted are still status='active'; nothing has ever been paid
-- through them. A QR is a scan-from-ANOTHER-device product.
--
-- The fix is a payable URL. Everything here is backend truth:
--   rzp_pay_mode()          — sdk | qr | manual, decided from placed_by_admin /
--                             source / collection_mode. Flutter never chooses.
--   rzp_checkout_prepare()  — what (if anything) to create, or the SAME open
--                             attempt to resume. Never a duplicate.
--   rzp_checkout_store()    — records Razorpay's reply, returns the render view
--   rzp_checkout_state()    — the poll: the state machine's current word
-- The attempt table is the state machine: pending -> attempted -> paid|failed.

-- ── 1. The attempt row — one per (order, kind) payable object ───────────────
create table if not exists public.rzp_payment_attempt (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  kind           text not null default 'advance',
  mode           text not null default 'sdk',          -- sdk | qr
  amount         numeric(12,2) not null,
  -- Razorpay's own identifiers. rzp_link_id is a payment link (plink_…),
  -- rzp_order_id the order it created, rzp_payment_id the captured payment.
  rzp_link_id    text,
  rzp_order_id   text,
  rzp_payment_id text,
  reference_id   text,                                 -- unique per link
  short_url      text,
  status         text not null default 'pending',      -- pending|attempted|paid|failed|expired
  failure_reason text,
  expires_at     timestamptz,
  created_at     timestamptz not null default now(),
  attempted_at   timestamptz,
  paid_at        timestamptz
);

alter table public.rzp_payment_attempt
  drop constraint if exists rzp_payment_attempt_status_chk;
alter table public.rzp_payment_attempt
  add constraint rzp_payment_attempt_status_chk
  check (status in ('pending','attempted','paid','failed','expired'));

create unique index if not exists rzp_payment_attempt_link_uk
  on public.rzp_payment_attempt (rzp_link_id) where rzp_link_id is not null;
create unique index if not exists rzp_payment_attempt_ref_uk
  on public.rzp_payment_attempt (reference_id) where reference_id is not null;
create index if not exists rzp_payment_attempt_order_ix
  on public.rzp_payment_attempt (order_id, kind, status);
create index if not exists rzp_payment_attempt_rzporder_ix
  on public.rzp_payment_attempt (rzp_order_id) where rzp_order_id is not null;

alter table public.rzp_payment_attempt enable row level security;
drop policy if exists rzp_attempt_owner_read on public.rzp_payment_attempt;
create policy rzp_attempt_owner_read on public.rzp_payment_attempt
  for select using (
    exists (select 1 from public.orders o
             where o.id = rzp_payment_attempt.order_id
               and (o.user_id = any (public.my_owner_user_ids())
                 or o.customer_id is not distinct from public.my_customer_id()
                 or public.get_my_role() in ('admin','super_admin'))));

-- ── 2. Copy — every word the checkout path prints lives in razorpay_copy ────
insert into public.razorpay_copy (key, value) values
  ('sdk_button_label',     'Pay now'),
  ('sdk_resume_label',     'Resume payment'),
  ('sdk_sheet_title',      'Pay securely with UPI'),
  ('sdk_sheet_subtitle',   'Opens PhonePe, Google Pay, Paytm or any UPI app. Come back here when you are done — we confirm the payment ourselves.'),
  ('sdk_opening_label',    'Opening your UPI app…'),
  ('sdk_waiting_label',    'Waiting for your payment to be confirmed'),
  ('sdk_waiting_hint',     'Finished paying? Keep this open — confirmation usually lands within a few seconds.'),
  ('sdk_open_failed_label','Could not open the payment page. Tap Retry, or use the link below.'),
  ('sdk_link_row_label',   'Payment link'),
  ('sdk_failed_label',     'That payment did not go through.'),
  ('sdk_expired_label',    'This payment link has expired. Start a new one.'),
  ('link_wa_intro',        'Tap the link below to pay securely by UPI:'),
  ('claim_reason_sdk',     'razorpay_checkout_captured'),
  ('mode_manual_label',    'Pay by UPI and send the screenshot'),
  ('attempt_status_pending',   'Not started'),
  ('attempt_status_attempted', 'Payment in progress'),
  ('attempt_status_paid',      'Paid'),
  ('attempt_status_failed',    'Payment failed'),
  ('attempt_status_expired',   'Link expired')
on conflict (key) do nothing;

-- ── 3. pay_mode — the ONE decision, made here and nowhere else ──────────────
-- sdk    : a real customer paying for their OWN order on the device in hand.
-- qr      : the payer is on a DIFFERENT phone — an admin acting as a customer,
--           or a WhatsApp-sourced order. A picture is the right tool there.
-- manual  : the gateway is off entirely; the shared UPI + screenshot path.
create or replace function public.rzp_pay_mode(p_order_id uuid default null)
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_mode text := public.payment_collection_mode();
  v_act  uuid := public.my_acting_as();
  v_role text := coalesce(public.get_my_role(),'none');
  v_admin boolean; v_source text;
begin
  if v_mode is distinct from 'gateway' then return 'manual'; end if;
  -- A staff session, or a session acting as somebody else, is never the payer.
  if v_act is not null or v_role in ('admin','super_admin','worker') then
    return 'qr';
  end if;
  if p_order_id is not null then
    select coalesce(o.placed_by_admin,false), lower(coalesce(o.source,''))
      into v_admin, v_source from orders o where o.id = p_order_id;
    if coalesce(v_admin,false) then return 'qr'; end if;
    if v_source in ('whatsapp','wa') then return 'qr'; end if;
  end if;
  return 'sdk';
end $$;

-- ── 4. The attempt state machine, in words the app prints verbatim ──────────
create or replace function public._rzp_attempt_view(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare a public.rzp_payment_attempt%rowtype;
begin
  select * into a from public.rzp_payment_attempt where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error','attempt_not_found'); end if;
  return jsonb_build_object(
    'ok', true,
    'provider',      'razorpay_checkout',
    'attempt_id',    a.id,
    'mode',          a.mode,
    'kind',          a.kind,
    'status',        a.status,
    'status_label',  public._rzp_copy('attempt_status_' || a.status),
    'paid',          (a.status = 'paid'),
    'resumable',     (a.status in ('pending','attempted')
                      and coalesce(a.expires_at, now() + interval '1 day') > now()),
    'pay_url',       a.short_url,
    'rzp_link_id',   a.rzp_link_id,
    'rzp_order_id',  a.rzp_order_id,
    'amount',        a.amount,
    'amount_label',  '₹' || to_char(a.amount, 'FM99,99,99,990.00'),
    'amount_row_label', public._rzp_copy('amount_row_label'),
    'title',         case when a.status = 'paid' then public._rzp_copy('paid_label')
                          else public._rzp_copy('sdk_sheet_title') end,
    'subtitle',      case when a.status = 'paid' then ''
                          else public._rzp_copy('sdk_sheet_subtitle') end,
    'link_row_label',public._rzp_copy('sdk_link_row_label'),
    'button_label',  case
                       when a.status = 'paid' then ''
                       when a.status = 'attempted' then public._rzp_copy('sdk_resume_label')
                       else public._rzp_copy('sdk_button_label') end,
    'failure_label', case when a.status = 'failed' then public._rzp_copy('sdk_failed_label')
                          when a.status = 'expired' then public._rzp_copy('sdk_expired_label')
                          else '' end,
    'paid_at_label', case when a.paid_at is not null
      then to_char(a.paid_at at time zone 'Asia/Kolkata', 'FMHH12:MI am "on" DD Mon') end);
end $$;

-- ── 5. Prepare — reuse before you create, ALWAYS ────────────────────────────
create or replace function public.rzp_checkout_prepare(
  p_order_id uuid, p_kind text default 'advance', p_mode text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_mode text; v_kind text; v_amount numeric; v_code text; v_hours integer;
  v_open public.rzp_payment_attempt%rowtype; v_ref text;
begin
  select order_code into v_code from orders where id = p_order_id;
  if v_code is null then
    return jsonb_build_object('ok', false, 'error','order_not_found');
  end if;

  v_mode := coalesce(nullif(btrim(coalesce(p_mode,'')),''), public.rzp_pay_mode(p_order_id));
  if v_mode = 'manual' then
    return jsonb_build_object('ok', false, 'pay_mode','manual', 'provider','upi_manual');
  end if;

  v_kind   := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;
  v_amount := public.rzp_amount_due(p_order_id, v_kind);
  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'error','nothing_due',
                              'message', public._rzp_copy('nothing_due_label'));
  end if;

  select greatest(coalesce(razorpay_close_hours,24),1) into v_hours
    from payment_config where id = 1;
  v_hours := coalesce(v_hours, 24);

  -- RESUME, never duplicate: an attempt that is still open for this exact
  -- order+kind+amount is handed straight back with the SAME Razorpay link.
  select * into v_open from public.rzp_payment_attempt
   where order_id = p_order_id and kind = v_kind
     and status in ('pending','attempted')
     and round(amount,2) = round(v_amount,2)
     and coalesce(expires_at, created_at + make_interval(hours => v_hours)) > now()
     and short_url is not null
   order by created_at desc limit 1;
  if found then
    return jsonb_build_object('ok', true, 'reused', true, 'pay_mode', v_mode,
                              'view', public._rzp_attempt_view(v_open.id));
  end if;

  -- A stale open attempt for a DIFFERENT amount is closed, not left dangling.
  update public.rzp_payment_attempt
     set status = 'expired', failure_reason = 'superseded'
   where order_id = p_order_id and kind = v_kind
     and status in ('pending','attempted');

  v_ref := v_code || ':' || v_kind || ':' || to_char(now(),'YYYYMMDDHH24MISS');
  insert into public.rzp_payment_attempt (order_id, kind, mode, amount, reference_id,
                                          expires_at)
  values (p_order_id, v_kind, v_mode, v_amount, v_ref,
          now() + make_interval(hours => v_hours))
  returning * into v_open;

  return jsonb_build_object(
    'ok', true, 'reused', false, 'pay_mode', v_mode,
    'attempt_id', v_open.id,
    'kind', v_kind,
    'order_code', v_code,
    'amount', v_amount,
    'amount_paise', (round(v_amount, 2) * 100)::bigint,
    'reference_id', v_ref,
    'expire_by', (extract(epoch from v_open.expires_at))::bigint,
    'description', 'mediBO ' || v_code || ' — ' || v_kind,
    'notes', jsonb_build_object('order_id', p_order_id::text, 'order_code', v_code,
                                'kind', v_kind, 'attempt_id', v_open.id::text));
end $$;

-- ── 6. Store Razorpay's reply ───────────────────────────────────────────────
create or replace function public.rzp_checkout_store(
  p_attempt_id uuid, p_link_id text, p_short_url text,
  p_rzp_order_id text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.rzp_payment_attempt%rowtype;
begin
  update public.rzp_payment_attempt
     set rzp_link_id  = coalesce(nullif(btrim(coalesce(p_link_id,'')),''), rzp_link_id),
         short_url    = coalesce(nullif(btrim(coalesce(p_short_url,'')),''), short_url),
         rzp_order_id = coalesce(nullif(btrim(coalesce(p_rzp_order_id,'')),''), rzp_order_id),
         status       = case when status = 'pending' then 'attempted' else status end,
         attempted_at = coalesce(attempted_at, now())
   where id = p_attempt_id
  returning * into a;
  if not found then return jsonb_build_object('ok', false, 'error','attempt_not_found'); end if;
  return jsonb_build_object('ok', true, 'view', public._rzp_attempt_view(a.id));
end $$;

-- ── 7. Mark an attempt failed (client-observed dismissal, never "paid") ─────
create or replace function public.rzp_checkout_failed(p_attempt_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.rzp_payment_attempt%rowtype;
begin
  -- A PAID attempt is read-only here. The client may only ever report failure,
  -- and never after the webhook has already said the money landed.
  update public.rzp_payment_attempt
     set status = case when status = 'paid' then 'paid' else 'failed' end,
         failure_reason = case when status = 'paid' then failure_reason
                               else left(coalesce(p_reason,'dismissed'), 200) end
   where id = p_attempt_id
  returning * into a;
  if not found then return jsonb_build_object('ok', false, 'error','attempt_not_found'); end if;
  return jsonb_build_object('ok', true, 'view', public._rzp_attempt_view(a.id));
end $$;
