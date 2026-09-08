-- CHANGE #291 — Razorpay dynamic UPI QR, auto-verified.
--
-- Replaces the manual flow (self-built upi:// deeplink QR -> customer sends a
-- screenshot -> OCR -> a human verifies a payment_claims row) with a Razorpay
-- QR Code per payment, credited straight into payment_claims by the webhook.
--
-- Everything that decides money or wording lives here. The two edge functions
-- (razorpay-qr-create, razorpay-webhook) are HTTP shims: one POSTs to Razorpay,
-- one verifies a signature. Neither computes an amount and neither writes a
-- display string.
--
-- Idempotent by construction: a resumed worker re-applies this file safely.

-- ── 1. payment_config: the fallback toggle ──────────────────────────────────
alter table public.payment_config
  add column if not exists razorpay_qr_enabled  boolean not null default false;
alter table public.payment_config
  add column if not exists razorpay_close_hours  integer not null default 24;

insert into public.payment_config (id) values (1) on conflict (id) do nothing;

-- ── 2. razorpay_qr ──────────────────────────────────────────────────────────
create table if not exists public.razorpay_qr (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid references public.orders(id) on delete cascade,
  rzp_qr_id     text,
  image_url     text,
  qr_string     text,
  amount        numeric not null default 0,
  kind          text    not null default 'advance',
  status        text    not null default 'active',
  closed_reason text,
  payment_id    text,
  created_at    timestamptz not null default now(),
  paid_at       timestamptz
);

create unique index if not exists razorpay_qr_rzp_qr_id_key
  on public.razorpay_qr (rzp_qr_id) where rzp_qr_id is not null;
create index if not exists razorpay_qr_order_idx
  on public.razorpay_qr (order_id, kind, status);
create index if not exists razorpay_qr_payment_idx
  on public.razorpay_qr (payment_id) where payment_id is not null;

alter table public.razorpay_qr enable row level security;

drop policy if exists razorpay_qr_read on public.razorpay_qr;
create policy razorpay_qr_read on public.razorpay_qr for select
  using (
    public.get_my_role() in ('admin','super_admin')
    or exists (
      select 1 from public.orders o
      where o.id = razorpay_qr.order_id
        and (o.user_id = any (public.my_owner_user_ids())
             or o.customer_id is not distinct from public.my_customer_id())
    )
  );

-- Writes are service-role only (the edge functions). No client-side insert.

-- The verified claim carries the Razorpay payment id in `utr`; this is what
-- makes the webhook idempotent no matter how many times Razorpay retries.
create unique index if not exists payment_claims_rzp_payment_key
  on public.payment_claims (utr) where payment_method = 'razorpay_qr';

-- ── 3. Copy — one place, never a Dart literal ───────────────────────────────
create table if not exists public.razorpay_copy (
  key   text primary key,
  value text not null
);
alter table public.razorpay_copy enable row level security;
drop policy if exists razorpay_copy_read on public.razorpay_copy;
create policy razorpay_copy_read on public.razorpay_copy for select using (true);

insert into public.razorpay_copy (key, value) values
  ('sheet_subtitle',      'Scan this QR in any UPI app. Payment confirms automatically — no screenshot needed.'),
  ('sheet_note',          'Verified by Razorpay'),
  ('loading_label',       'Preparing your QR…'),
  ('error_label',         'Could not prepare the QR right now.'),
  ('retry_label',         'Try again'),
  ('paid_label',          'Payment received ✓'),
  ('expired_label',       'This QR has expired. Tap Try again for a fresh one.'),
  ('amount_row_label',    'Amount'),
  ('nothing_due_label',   'Nothing due right now.'),
  ('admin_title',         'Payment collection mode'),
  ('admin_helper',        'Razorpay QR gives every payment its own QR and confirms it automatically. Manual UPI keeps the shared UPI ID and needs a screenshot plus a human check.'),
  ('admin_toggle_label',  'Use Razorpay auto-verified QR'),
  ('admin_on_label',      'Razorpay QR'),
  ('admin_off_label',     'Manual UPI'),
  ('admin_on_helper',     'Customers scan a Razorpay QR. Payments land verified on their own.'),
  ('admin_off_helper',    'Customers scan the shared UPI QR and send a screenshot for manual verification.'),
  ('admin_saved_label',   'Payment mode updated'),
  ('claim_reason',        'razorpay_qr_credited')
on conflict (key) do nothing;

create or replace function public._rzp_copy(p_key text)
returns text language sql stable security definer set search_path to 'public' as $$
  select value from public.razorpay_copy where key = p_key;
$$;

-- ── 4. What is actually due, in rupees, for one order + kind ────────────────
-- Mirrors customer_order_payment_panel exactly: advance = advance_pct% of the
-- MRP-basis order value minus what is already paid; balance = bill net payable
-- minus what is already paid. Money is never computed anywhere else.
create or replace function public.rzp_amount_due(p_order_id uuid, p_kind text)
returns numeric language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_mrp numeric; v_advpct numeric; v_advreq numeric;
  v_bill jsonb;  v_net numeric;   v_paid numeric;
begin
  select coalesce(sum(oi.quantity * oi.mrp),0) into v_mrp
    from order_items oi where oi.order_id = p_order_id;

  select advance_pct into v_advpct from billing_config where id = 1;
  v_advreq := round(v_mrp * coalesce(v_advpct,30) / 100, 2);

  select coalesce(sum(amount) filter (where status not in ('rejected','duplicate','need_details')),0)
    into v_paid from payment_claims where order_id = p_order_id;

  if lower(coalesce(p_kind,'advance')) = 'advance' then
    return greatest(v_advreq - least(v_paid, v_advreq), 0);
  end if;

  v_bill := public.customer_bill(p_order_id);
  v_net  := case when (v_bill->>'ready')::boolean
                 then (v_bill->'totals'->>'net_payable')::numeric end;
  if v_net is null then return 0; end if;
  return greatest(v_net - v_paid, 0);
end $$;

-- ── 5. The render-ready view of one stored QR ───────────────────────────────
create or replace function public.rzp_qr_view(p_qr_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare q public.razorpay_qr%rowtype; v_paid boolean;
begin
  select * into q from public.razorpay_qr where id = p_qr_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'qr_not_found'); end if;
  v_paid := (q.status = 'paid');

  return jsonb_build_object(
    'ok', true,
    'provider', 'razorpay_qr',
    'qr_id', q.id,
    'rzp_qr_id', q.rzp_qr_id,
    'image_url', q.image_url,
    'qr_string', q.qr_string,
    'amount', q.amount,
    'amount_label', '₹' || to_char(q.amount, 'FM99,99,99,990.00'),
    'amount_row_label', public._rzp_copy('amount_row_label'),
    'kind', q.kind,
    'status', q.status,
    'title', case when v_paid then public._rzp_copy('paid_label')
                  else case when lower(q.kind) = 'advance'
                            then 'Pay advance ₹' || to_char(q.amount,'FM99,99,99,990.00')
                            else 'Pay balance ₹'  || to_char(q.amount,'FM99,99,99,990.00') end end,
    'subtitle', case when v_paid then '' else public._rzp_copy('sheet_subtitle') end,
    'note_label', public._rzp_copy('sheet_note'),
    'paid', v_paid,
    'paid_at_label', case when q.paid_at is not null
      then to_char(q.paid_at at time zone 'Asia/Kolkata', 'FMHH12:MI am "on" DD Mon') end,
    'closed_reason', q.closed_reason
  );
end $$;

-- ── 6. Prepare — everything the edge function needs to call Razorpay ────────
-- Returns a reusable open QR when one already exists for the same order, kind
-- and amount, so a double tap never mints a second QR.
create or replace function public.rzp_qr_prepare(p_order_id uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_enabled boolean; v_hours integer; v_kind text;
  v_amount numeric;  v_code text; v_open public.razorpay_qr%rowtype;
begin
  select razorpay_qr_enabled, greatest(coalesce(razorpay_close_hours,24),1)
    into v_enabled, v_hours from payment_config where id = 1;

  if not coalesce(v_enabled,false) then
    return jsonb_build_object('ok', false, 'enabled', false, 'provider', 'upi_manual');
  end if;

  select order_code into v_code from orders where id = p_order_id;
  if v_code is null then
    return jsonb_build_object('ok', false, 'enabled', true, 'error', 'order_not_found');
  end if;

  v_kind   := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;
  v_amount := public.rzp_amount_due(p_order_id, v_kind);

  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'enabled', true, 'error', 'nothing_due',
                              'message', public._rzp_copy('nothing_due_label'));
  end if;

  select * into v_open from public.razorpay_qr
   where order_id = p_order_id and kind = v_kind and status = 'active'
     and round(amount,2) = round(v_amount,2)
     and created_at > now() - make_interval(hours => v_hours)
   order by created_at desc limit 1;

  if found then
    return jsonb_build_object('ok', true, 'enabled', true, 'reused', true,
                              'view', public.rzp_qr_view(v_open.id));
  end if;

  return jsonb_build_object(
    'ok', true, 'enabled', true, 'reused', false,
    'kind', v_kind,
    'order_code', v_code,
    'amount', v_amount,
    'amount_paise', (round(v_amount, 2) * 100)::bigint,
    'close_by', (extract(epoch from (now() + make_interval(hours => v_hours))))::bigint,
    'description', 'mediBO ' || v_code || ' — ' ||
                   case when v_kind = 'advance' then 'advance' else 'balance' end,
    'notes', jsonb_build_object('order_id', p_order_id::text, 'order_code', v_code, 'kind', v_kind)
  );
end $$;

-- ── 7. Store what Razorpay returned, then hand back the same view ───────────
create or replace function public.rzp_qr_store(
  p_order_id uuid, p_kind text, p_rzp_qr_id text,
  p_image_url text, p_qr_string text, p_amount numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_kind text;
begin
  if nullif(btrim(coalesce(p_rzp_qr_id,'')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'missing_rzp_qr_id');
  end if;
  v_kind := case when lower(coalesce(p_kind,'advance')) = 'advance' then 'advance' else 'balance' end;

  insert into public.razorpay_qr (order_id, kind, rzp_qr_id, image_url, qr_string, amount, status)
  values (p_order_id, v_kind, p_rzp_qr_id, p_image_url, p_qr_string, round(coalesce(p_amount,0),2), 'active')
  on conflict (rzp_qr_id) where rzp_qr_id is not null
  do update set image_url = excluded.image_url,
                qr_string = excluded.qr_string,
                amount    = excluded.amount
  returning id into v_id;

  return jsonb_build_object('ok', true, 'view', public.rzp_qr_view(v_id));
end $$;

-- ── 8. The webhook's whole brain ────────────────────────────────────────────
-- Called ONLY after the edge function has verified the HMAC. Idempotent on the
-- Razorpay payment id: a retried delivery updates nothing and reports ok.
create or replace function public.rzp_webhook_apply(p_event jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_event text := p_event->>'event';
  v_qr    jsonb := p_event #> '{payload,qr_code,entity}';
  v_pay   jsonb := p_event #> '{payload,payment,entity}';
  v_qrid  text  := v_qr->>'id';
  v_payid text  := v_pay->>'id';
  v_order uuid;
  v_amount numeric;
  v_row   public.razorpay_qr%rowtype;
  v_claim uuid; v_ph text; v_owner uuid;
begin
  if v_event is distinct from 'qr_code.credited' then
    return jsonb_build_object('ok', true, 'ignored', coalesce(v_event,'(none)'));
  end if;
  if nullif(btrim(coalesce(v_payid,'')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'no_payment_id');
  end if;

  -- Idempotency first: nothing below runs twice for the same payment.
  if exists (select 1 from payment_claims
              where utr = v_payid and payment_method = 'razorpay_qr') then
    return jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
  end if;

  -- notes.order_id is the match, exactly as the QR was created with.
  v_order := nullif(coalesce(v_qr #>> '{notes,order_id}', v_pay #>> '{notes,order_id}'), '')::uuid;
  select * into v_row from public.razorpay_qr where rzp_qr_id = v_qrid;
  if v_order is null then v_order := v_row.order_id; end if;
  if v_order is null then
    return jsonb_build_object('ok', false, 'error', 'unmatched_order', 'qr_id', v_qrid);
  end if;

  v_amount := round(coalesce((v_pay->>'amount')::numeric, 0) / 100.0, 2);

  update public.razorpay_qr
     set status = 'paid', payment_id = v_payid, paid_at = now(),
         closed_reason = coalesce(v_qr->>'close_reason', 'paid')
   where rzp_qr_id = v_qrid;

  select o.user_id into v_owner from orders o where o.id = v_order;
  select right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
    into v_ph from pharmacy_profiles pp
   where pp.user_id = v_owner and coalesce(pp.is_deleted,false) = false limit 1;

  insert into payment_claims (
    order_id, sender_phone, sender_type, amount, utr, txn_id, app,
    payee_name, status, verify_reason, payment_method, received_at, created_at)
  values (
    v_order, v_ph, 'customer', v_amount, v_payid, v_payid,
    coalesce(v_pay->>'method','upi'), 'Razorpay', 'verified',
    public._rzp_copy('claim_reason'), 'razorpay_qr', now(), now())
  returning id into v_claim;

  update orders
     set status = 'accepted',
         payment_id = v_payid
   where id = v_order and coalesce(status,'') <> 'accepted';

  return jsonb_build_object('ok', true, 'order_id', v_order, 'claim_id', v_claim,
                            'payment_id', v_payid, 'amount', v_amount);
exception
  when unique_violation then
    return jsonb_build_object('ok', true, 'duplicate', true, 'payment_id', v_payid);
end $$;

-- ── 9. Admin surface: read + flip the toggle ────────────────────────────────
create or replace function public.payment_mode_get()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_on boolean;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;
  select coalesce(razorpay_qr_enabled,false) into v_on from payment_config where id = 1;

  return jsonb_build_object(
    'ok', true,
    'enabled', coalesce(v_on,false),
    'title',        public._rzp_copy('admin_title'),
    'helper',       public._rzp_copy('admin_helper'),
    'toggle_label', public._rzp_copy('admin_toggle_label'),
    'mode_label',   case when v_on then public._rzp_copy('admin_on_label')
                         else public._rzp_copy('admin_off_label') end,
    'mode_tone',    case when v_on then 'ok' else 'pending' end,
    'mode_helper',  case when v_on then public._rzp_copy('admin_on_helper')
                         else public._rzp_copy('admin_off_helper') end,
    'saved_label',  public._rzp_copy('admin_saved_label'),
    'can_edit',     (public.get_my_role() = 'super_admin')
  );
end $$;

create or replace function public.payment_mode_set(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if public.get_my_role() <> 'super_admin' then
    raise exception 'Only a super admin can change the payment mode';
  end if;
  update payment_config
     set razorpay_qr_enabled = coalesce(p_enabled,false), updated_at = now()
   where id = 1;
  return public.payment_mode_get();
end $$;

grant execute on function public.payment_mode_get()            to authenticated;
grant execute on function public.payment_mode_set(boolean)     to authenticated;
grant execute on function public.rzp_qr_view(uuid)             to authenticated;
grant execute on function public.rzp_amount_due(uuid, text)    to authenticated;
grant execute on function public.rzp_qr_prepare(uuid, text)    to authenticated, service_role;
grant execute on function public.rzp_qr_store(uuid, text, text, text, text, numeric) to service_role;
grant execute on function public.rzp_webhook_apply(jsonb)      to service_role;

-- ── 10. The customer payment panel now says WHICH provider to draw ──────────
-- Decorating customer_order_payment_panel_v2 (the existing money_display
-- wrapper) keeps the 300-line v1 body untouched: this change only ADDS keys.
create or replace function public.rzp_panel_block()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_on boolean;
begin
  select coalesce(razorpay_qr_enabled,false) into v_on from payment_config where id = 1;
  return jsonb_build_object(
    'provider', case when v_on then 'razorpay_qr' else 'upi_manual' end,
    'razorpay', jsonb_build_object(
      'enabled',          coalesce(v_on,false),
      'loading_label',    public._rzp_copy('loading_label'),
      'error_label',      public._rzp_copy('error_label'),
      'retry_label',      public._rzp_copy('retry_label'),
      'note_label',       public._rzp_copy('sheet_note'),
      'amount_row_label', public._rzp_copy('amount_row_label'),
      'expired_label',    public._rzp_copy('expired_label')));
end $$;

create or replace function public.customer_order_payment_panel_v2(p_order_id uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select (d || public.money_display_block(d, array[
            'total','due','paid','amount','balance','order_total','net_payable',
            'advance_required','claimed_amount','ocr_amount']))
         || jsonb_build_object('upi',
              coalesce(d->'upi','{}'::jsonb) || public.rzp_panel_block())
  from (select public.customer_order_payment_panel(p_order_id) d) z;
$$;

grant execute on function public.rzp_panel_block() to authenticated;
grant execute on function public.customer_order_payment_panel_v2(uuid) to authenticated;

-- ── 11. payment_method now admits 'razorpay_qr' ─────────────────────────────
-- payment_claims_payment_method_check only allowed ('online','cash'), so the
-- webhook's insert failed outright. Widening it is additive — no existing row
-- changes, no value is removed.
alter table public.payment_claims drop constraint if exists payment_claims_payment_method_check;
alter table public.payment_claims add constraint payment_claims_payment_method_check
  check (payment_method = any (array['online'::text, 'cash'::text, 'razorpay_qr'::text]));

-- ...and the admin money split follows. admin_order_payment_view computed
-- online_total as `payment_method = 'online'` EXACTLY, so a razorpay_qr claim
-- would have been counted in neither cash_total nor online_total — money that
-- exists in total_received but in no column. "Online" is now "not cash", which
-- is what the column always meant.
do $$
declare d text; v_old text; v_new text;
begin
  v_old := 'coalesce(sum(amount) filter (where coalesce(payment_method,''online'')=''online''),0) as online_total';
  v_new := 'coalesce(sum(amount) filter (where coalesce(payment_method,''online'') <> ''cash''),0) as online_total';

  select pg_get_functiondef(oid) into d
    from pg_proc where oid = 'public.admin_order_payment_view(uuid)'::regprocedure;

  if position(v_new in d) > 0 then
    return;                                  -- already patched; a resume is a no-op
  end if;
  if position(v_old in d) = 0 then
    raise exception 'c291: online_total line not found in admin_order_payment_view — patch it by hand';
  end if;

  execute replace(d, v_old, v_new);
end $$;
