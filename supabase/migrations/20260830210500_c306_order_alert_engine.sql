-- ============================================================================
-- CHANGE #306 — the alert engine.
--
-- Every word this feature says lives in order_alert_config.labels and is
-- rendered HERE. Flutter and Kotlin receive finished strings.
--
-- The prepaid/unpaid split is a matter of TIMING, not of intent: at INSERT no
-- order is paid yet — a gateway customer pays seconds later and the webhook
-- credits it. So the phone does not ring the instant an order lands; it rings
-- `ring_delay_s` later, and only if the money still has not arrived. An order
-- that pays inside that window closes its own alert as auto-accepted and was
-- never heard from. That is exactly "prepaid orders auto-accept as they do
-- today, no popup, no ringing".
-- ============================================================================

alter table public.order_alert
  add column if not exists ring boolean not null default true;

-- ── Config accessors ────────────────────────────────────────────────────────
create or replace function public._oa_cfg()
returns public.order_alert_config
language sql stable security definer set search_path to 'public' as $$
  select * from public.order_alert_config where id = 'singleton'
$$;

create or replace function public.oa_label(p_key text, p_vars jsonb default '{}'::jsonb)
returns text
language sql stable security definer set search_path to 'public' as $$
  select public.notif_render(
           coalesce((select labels->>p_key from public.order_alert_config where id='singleton'), ''),
           coalesce(p_vars, '{}'::jsonb))
$$;

-- ── Money already collected against an order ────────────────────────────────
-- A verified payment claim is money in the bank. A Razorpay QR and a Razorpay
-- attempt describe the SAME rupee when both exist, so the QR wins and the
-- attempt is only read when there is no QR — never both.
create or replace function public.order_paid_amount(p_order_id uuid)
returns numeric
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select sum(pc.amount) from public.payment_claims pc
                    where pc.order_id = p_order_id and pc.status = 'verified'), 0)
       + coalesce(
           case when exists (select 1 from public.razorpay_qr q
                              where q.order_id = p_order_id and q.status = 'paid')
                then (select sum(q.amount) from public.razorpay_qr q
                       where q.order_id = p_order_id and q.status = 'paid')
                else (select sum(a.amount) from public.rzp_payment_attempt a
                       where a.order_id = p_order_id and a.status in ('paid','captured'))
           end, 0)
$$;

-- Paid = the platform's own acceptance (verify_and_accept_payment / the
-- Razorpay credit both set orders.status='accepted'), or money that covers the
-- order. Anything else is unpaid, and unpaid is what carries the risk.
create or replace function public.order_is_paid(p_order_id uuid)
returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.orders o
                  where o.id = p_order_id and o.status = 'accepted')
      or coalesce(public.order_paid_amount(p_order_id), 0)
         >= coalesce((select o.total_amount from public.orders o where o.id = p_order_id), 0)
         and coalesce((select o.total_amount from public.orders o where o.id = p_order_id), 0) > 0
$$;

-- ── Per-customer credit ─────────────────────────────────────────────────────
-- Outstanding = everything this customer has ordered and not yet paid for,
-- across open orders. An explicit customer_credit row is a named admin's
-- decision and always wins; without one, a customer who has paid for at least
-- `established_min_paid_orders` orders gets the established limit and a brand
-- new customer gets prepaid-only, exactly as the spec asks.
create or replace function public.customer_credit_state(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  cfg public.order_alert_config; cc public.customer_credit;
  v_out numeric := 0; v_paid_orders int := 0;
  v_limit numeric; v_prepaid boolean; v_blocked boolean; v_name text;
begin
  cfg := public._oa_cfg();
  if p_customer_id is null then
    return jsonb_build_object('ok', false, 'known', false, 'blocked', false,
                              'outstanding', 0, 'limit', 0);
  end if;

  select * into cc from public.customer_credit where customer_id = p_customer_id;
  select coalesce(pp.pharmacy_name, pp.customer_name, '') into v_name
    from public.pharmacy_profiles pp where pp.id = p_customer_id;

  select coalesce(sum(greatest(o.total_amount - public.order_paid_amount(o.id), 0)), 0)
    into v_out
    from public.orders o
   where o.customer_id = p_customer_id
     and o.status not in ('cancelled','rejected')
     and o.closed_at is null;

  select count(*) into v_paid_orders
    from public.orders o
   where o.customer_id = p_customer_id and public.order_is_paid(o.id);

  if cc.customer_id is not null then
    v_limit   := cc.credit_limit;
    v_prepaid := cc.prepaid_only;
  elsif v_paid_orders >= greatest(cfg.established_min_paid_orders, 1) then
    v_limit   := cfg.established_credit_limit;
    v_prepaid := false;
  else
    v_limit   := 0;
    v_prepaid := cfg.new_customer_prepaid_only;
  end if;

  v_blocked := cfg.enforce_credit_block and (v_prepaid or v_out > v_limit);

  return jsonb_build_object(
    'ok', true,
    'known', cc.customer_id is not null,
    'customer_id', p_customer_id,
    'customer_name', coalesce(v_name,''),
    'prepaid_only', v_prepaid,
    'limit', v_limit,
    'limit_display', public.inr_money(v_limit),
    'outstanding', v_out,
    'outstanding_display', public.inr_money(v_out),
    'paid_orders', v_paid_orders,
    'blocked', v_blocked,
    'reason', case when not cfg.enforce_credit_block then 'enforcement_off'
                   when v_prepaid then 'prepaid_only'
                   when v_out > v_limit then 'over_limit'
                   else 'within_limit' end,
    'message', case
      when not cfg.enforce_credit_block then ''
      when v_prepaid then public.oa_label('credit_prepaid_only',
             jsonb_build_object('customer', coalesce(v_name,''),
                                'outstanding', public.inr_money(v_out)))
      when v_out > v_limit then public.oa_label('credit_over_limit',
             jsonb_build_object('customer', coalesce(v_name,''),
                                'outstanding', public.inr_money(v_out),
                                'limit', public.inr_money(v_limit)))
      else '' end);
end $$;

-- ── Raising an alert ────────────────────────────────────────────────────────
create or replace function public.order_alert_raise(p_order_id uuid)
returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare
  cfg public.order_alert_config; o public.orders%rowtype;
  v_credit jsonb; v_id bigint; v_name text;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled, false) then return null; end if;

  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''),
                  nullif(btrim(o.pharmacy_name),''), '')
    into v_name
    from public.pharmacy_profiles pp where pp.id = o.customer_id;
  v_name := coalesce(nullif(btrim(coalesce(v_name, o.pharmacy_name, '')),''), o.pharmacy_name, '');

  v_credit := public.customer_credit_state(o.customer_id);

  insert into public.order_alert
    (order_id, order_code, customer_id, customer_name, amount, risk, state, stage,
     credit_blocked, credit_note, expires_at, ring)
  values
    (o.id, coalesce(o.order_code, o.payment_id, ''), o.customer_id, v_name,
     coalesce(o.total_amount, 0),
     case when public.order_is_paid(o.id) then 'prepaid' else 'unpaid' end,
     case when public.order_is_paid(o.id) then 'accepted' else 'ringing' end,
     'new',
     coalesce((v_credit->>'blocked')::boolean, false),
     nullif(v_credit->>'message',''),
     now() + make_interval(mins => greatest(cfg.autocancel_after_min, 1)),
     not public.order_is_paid(o.id))
  on conflict (order_id) do nothing
  returning id into v_id;

  return v_id;
end $$;

create or replace function public.trg_order_alert_raise()
returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  -- An alert must never be able to fail an order placement.
  begin
    perform public.order_alert_raise(new.id);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists order_alert_raise_trg on public.orders;
create trigger order_alert_raise_trg
after insert on public.orders
for each row execute function public.trg_order_alert_raise();
