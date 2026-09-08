-- CHANGE #309 step 5 — RIDER PAYOUT RUN.
--
-- deliveries.earning already computed what each drop earns, but there was no
-- payout table, so "what do we owe Ravi this week" was a query somebody ran by
-- hand and "have we already paid it" was unanswerable. That second question is
-- the whole design constraint here: NOTHING MAY BE PAID TWICE.
--
-- How double payment is actually prevented — three locks, not a promise:
--   1. A delivery joins at most ONE payout line, enforced by a UNIQUE index on
--      delivery_id. A second run that tries to sweep the same drop cannot
--      insert the row; it is not a check that can be forgotten, it is the
--      table refusing.
--   2. Collection only ever picks up drops with payout_line_id IS NULL, and
--      stamps that column in the same statement.
--   3. Marking a period paid is a one-way transition guarded on the CURRENT
--      status inside the UPDATE's own WHERE clause, so two admins tapping
--      "Mark paid" at the same moment produce one payment, not two.

create table if not exists public.delivery_payout_periods (
  id           uuid primary key default gen_random_uuid(),
  partner_id   uuid not null references public.delivery_partner_registrations(id) on delete cascade,
  period_start date not null,
  period_end   date not null,
  status       text not null default 'unpaid' check (status in ('unpaid','paid','void')),

  drop_count   integer      not null default 0,
  gross_amount numeric(12,2) not null default 0,
  adjustments  numeric(12,2) not null default 0,
  net_amount   numeric(12,2) not null default 0,

  paid_at      timestamptz,
  paid_by      uuid,
  paid_ref     text,                       -- UTR / cheque no
  note         text,
  created_at   timestamptz not null default now(),
  created_by   uuid,

  -- One period per rider per window. A second "open period" for the same dates
  -- is refused by the database rather than by a code path.
  unique (partner_id, period_start, period_end)
);

create table if not exists public.delivery_payout_lines (
  id          uuid primary key default gen_random_uuid(),
  period_id   uuid not null references public.delivery_payout_periods(id) on delete cascade,
  delivery_id uuid not null references public.deliveries(id) on delete restrict,
  order_id    uuid,
  amount      numeric(10,2) not null default 0,
  delivered_at timestamptz,
  created_at  timestamptz not null default now()
);

-- LOCK 1 — the structural guarantee that a drop is paid at most once, ever.
create unique index if not exists uq_payout_line_delivery
  on public.delivery_payout_lines(delivery_id);
create index if not exists idx_payout_lines_period
  on public.delivery_payout_lines(period_id);

alter table public.deliveries
  add column if not exists payout_line_id uuid;

create index if not exists idx_deliveries_unpaid
  on public.deliveries(partner_id, delivered_at)
  where status = 'delivered' and payout_line_id is null;

-- ── Open a period and sweep every unpaid drop into it ───────────────────────
create or replace function public.admin_payout_open(
  p_partner_id uuid,
  p_start date default null,
  p_end   date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_days int := coalesce((public._dcfg(null)->>'payout_period_days')::int, 7);
  v_end   date := coalesce(p_end, (now() at time zone 'Asia/Kolkata')::date);
  v_start date := coalesce(p_start, v_end - (v_days - 1));
  v_id uuid; v_n int; v_gross numeric;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if not exists (select 1 from public.delivery_partner_registrations where id = p_partner_id) then
    return jsonb_build_object('ok',false,'error','no_such_partner');
  end if;

  insert into public.delivery_payout_periods(partner_id, period_start, period_end, created_by)
  values (p_partner_id, v_start, v_end, auth.uid())
  on conflict (partner_id, period_start, period_end) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.delivery_payout_periods
     where partner_id = p_partner_id and period_start = v_start and period_end = v_end;
    -- A PAID period is closed for good; sweeping more drops into it would pay
    -- them without anyone approving the larger amount.
    if (select status from public.delivery_payout_periods where id = v_id) = 'paid' then
      return jsonb_build_object('ok',false,'error','period_paid',
        'message', public._c('admin.delivery.payout_already_paid'));
    end if;
  end if;

  -- LOCK 2 — only drops that belong to no line yet, claimed and stamped in one
  -- statement so a concurrent run cannot pick up the same delivery.
  with pick as (
    select d.id, d.order_id, d.delivered_at, coalesce(d.earning,0) amount
      from public.deliveries d
     where d.partner_id   = p_partner_id
       and d.status       = 'delivered'
       and d.payout_line_id is null
       and (d.delivered_at at time zone 'Asia/Kolkata')::date between v_start and v_end
     for update skip locked),
  ins as (
    insert into public.delivery_payout_lines(period_id, delivery_id, order_id, amount, delivered_at)
    select v_id, p.id, p.order_id, p.amount, p.delivered_at from pick p
    on conflict (delivery_id) do nothing
    returning id, delivery_id, amount)
  update public.deliveries d
     set payout_line_id = i.id
    from ins i where d.id = i.delivery_id;

  select count(*), coalesce(sum(amount),0) into v_n, v_gross
    from public.delivery_payout_lines where period_id = v_id;

  update public.delivery_payout_periods
     set drop_count = v_n, gross_amount = v_gross,
         net_amount = v_gross + coalesce(adjustments,0)
   where id = v_id;

  return jsonb_build_object('ok',true,'period_id',v_id,
    'drop_count',v_n,'gross_amount',v_gross,
    'gross_label', public.inr_money(v_gross),
    'period_label', to_char(v_start,'DD Mon') || ' – ' || to_char(v_end,'DD Mon YYYY'));
end $function$;

-- ── Pay it, exactly once ────────────────────────────────────────────────────
create or replace function public.admin_payout_pay(
  p_period_id uuid, p_ref text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_rows int; v_p public.delivery_payout_periods%rowtype;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  -- LOCK 3 — the transition is guarded inside the UPDATE itself. Two admins
  -- tapping at once: one updates a row, the other updates none.
  update public.delivery_payout_periods
     set status='paid', paid_at=now(), paid_by=auth.uid(),
         paid_ref=nullif(btrim(coalesce(p_ref,'')),''),
         note=coalesce(nullif(btrim(coalesce(p_note,'')),''), note)
   where id = p_period_id and status = 'unpaid';
  get diagnostics v_rows = row_count;

  select * into v_p from public.delivery_payout_periods where id = p_period_id;
  if v_p.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if v_rows = 0 then
    return jsonb_build_object('ok',false,'error','already_paid','status',v_p.status,
      'message', public._c('admin.delivery.payout_already_paid'),
      'paid_at', v_p.paid_at);
  end if;

  return jsonb_build_object('ok',true,'period_id',p_period_id,'status','paid',
    'paid_at', v_p.paid_at,
    'amount_label', public.inr_money(v_p.net_amount));
end $function$;

-- ── The statement a rider is shown / an admin prints ────────────────────────
create or replace function public.admin_payout_statement(p_period_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_p public.delivery_payout_periods%rowtype; v_lines jsonb; v_name text;
begin
  select * into v_p from public.delivery_payout_periods where id = p_period_id;
  if v_p.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if public.get_my_role() not in ('admin','super_admin')
     and not exists (select 1 from public.delivery_partner_registrations
                      where id = v_p.partner_id and user_id = auth.uid()) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select full_name into v_name from public.delivery_partner_registrations where id = v_p.partner_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'order_code', coalesce(o.order_code,''),
           'pharmacy',   coalesce(o.pharmacy_name,''),
           'delivered_label', to_char(l.delivered_at at time zone 'Asia/Kolkata','DD Mon, hh12:MI am'),
           'amount_label', public.inr_money(l.amount)) order by l.delivered_at), '[]'::jsonb)
    into v_lines
  from public.delivery_payout_lines l
  left join public.orders o on o.id = l.order_id
  where l.period_id = p_period_id;

  return jsonb_build_object('ok',true,
    'title', public._c('admin.delivery.payout_statement_title'),
    'partner_name', coalesce(v_name,''),
    'period_label', to_char(v_p.period_start,'DD Mon') || ' – ' || to_char(v_p.period_end,'DD Mon YYYY'),
    'status', v_p.status,
    'status_chip', case when v_p.status='paid' then public._c('admin.delivery.payout_paid_chip')
                        else public._c('admin.delivery.payout_unpaid_chip') end,
    'status_colors', case when v_p.status='paid'
                          then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
                          else jsonb_build_object('bg','#FEF3C7','fg','#92400E') end,
    'drop_count', v_p.drop_count,
    'drop_count_label', v_p.drop_count || ' drop' || case when v_p.drop_count = 1 then '' else 's' end,
    'gross_label', public.inr_money(v_p.gross_amount),
    'net_label',   public.inr_money(v_p.net_amount),
    'paid_ref',    coalesce(v_p.paid_ref,''),
    'paid_at',     v_p.paid_at,
    'can_pay',     (v_p.status = 'unpaid' and public.get_my_role() in ('admin','super_admin')),
    'pay_label',   public._c('admin.delivery.payout_pay_btn'),
    'lines', v_lines);
end $function$;

alter table public.delivery_payout_periods enable row level security;
alter table public.delivery_payout_lines   enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where tablename='delivery_payout_periods' and policyname='payout_periods_read') then
    create policy payout_periods_read on public.delivery_payout_periods
      for select to authenticated
      using (public.get_my_role() in ('admin','super_admin')
             or exists (select 1 from public.delivery_partner_registrations
                         where id = delivery_payout_periods.partner_id and user_id = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies
                  where tablename='delivery_payout_lines' and policyname='payout_lines_read') then
    create policy payout_lines_read on public.delivery_payout_lines
      for select to authenticated
      using (exists (select 1 from public.delivery_payout_periods p
                      where p.id = delivery_payout_lines.period_id
                        and (public.get_my_role() in ('admin','super_admin')
                             or exists (select 1 from public.delivery_partner_registrations r
                                         where r.id = p.partner_id and r.user_id = auth.uid()))));
  end if;
end $$;

grant select on public.delivery_payout_periods, public.delivery_payout_lines to authenticated;
grant execute on function public.admin_payout_open(uuid,date,date) to authenticated;
grant execute on function public.admin_payout_pay(uuid,text,text) to authenticated;
grant execute on function public.admin_payout_statement(uuid) to authenticated;
