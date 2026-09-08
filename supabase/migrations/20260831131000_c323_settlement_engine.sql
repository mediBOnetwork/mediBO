-- ============================================================================
-- CHANGE #323 (part 2) — the engine.
--
-- Three jobs, in this order, and nothing else:
--   SNAPSHOT   the deal onto the order at bill time,
--   COST       the order from the cost types that were live when it was billed,
--   SETTLE     the period the order falls in, on the period TOTAL.
--
-- The rule that shapes every function below: WHAT WAS AGREED IS FROZEN, WHAT
-- WAS MEASURED KEEPS ARRIVING. So an order_costs row stamps the basis and the
-- two rates it was created with — change how delivery is charged tomorrow and
-- an already-billed order keeps the terms it was billed under — while the
-- DRIVER (road km, box count, order value) is refreshed until the period
-- closes, because those numbers genuinely land after the bill does.
--
-- Idempotent by construction (#233).
-- ============================================================================

-- The terms an order was costed under, frozen on the line itself.
alter table public.order_costs add column if not exists basis      text;
alter table public.order_costs add column if not exists base_value numeric not null default 0;
alter table public.order_costs add column if not exists rate_value numeric not null default 0;

-- ── Copy helpers ────────────────────────────────────────────────────────────
create or replace function public._stl_c(p_key text)
returns text language sql stable as $$
  select coalesce((select label from public.settlement_label where key = p_key), '')
$$;

create or replace function public._stl_tone(p_key text)
returns text language sql stable as $$
  select (select tone from public.settlement_label where key = p_key)
$$;

-- A plain number for a label: 12.40 -> '12.4', 2.00 -> '2'.
create or replace function public._stl_num(v numeric)
returns text language sql immutable as $$
  select trim(trailing '.' from trim(trailing '0' from to_char(coalesce(v,0), 'FM9999999990.00')))
$$;

-- ── What an order actually measured ─────────────────────────────────────────
-- The road distance the delivery route builder already computed for this drop.
-- max(), not sum(): a re-attempted stop is the same journey planned twice, and
-- an order must never be charged for the retry as if it were extra distance.
create or replace function public._stl_order_km(p_order_id uuid)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select round(coalesce(max(d.leg_km), 0), 2)
    from public.deliveries d
   where d.order_id = p_order_id
$$;

-- The boxes the order was actually bagged into, from the bagging ledger.
create or replace function public._stl_order_boxes(p_order_id uuid)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce(count(distinct a.bag_no), 0)::numeric
    from public.bag_allocations a
   where a.order_id = p_order_id
     and a.bag_no is not null
$$;

-- ── One formula, four drivers ───────────────────────────────────────────────
-- amount = base + rate x driver. The driver is what the BASIS points at, which
-- is why adding a fifth way to charge is one more branch here and a row in
-- settlement_label — never a new column and never a new screen.
create or replace function public._stl_driver(p_basis text, p_km numeric,
                                              p_boxes numeric, p_revenue numeric)
returns numeric language sql immutable as $$
  select case p_basis
           when 'per_km'       then coalesce(p_km, 0)
           when 'per_box'      then coalesce(p_boxes, 0)
           when 'pct_of_order' then coalesce(p_revenue, 0) / 100
           else 0
         end
$$;

create or replace function public._stl_driver_label(p_basis text, p_driver numeric,
                                                    p_rate numeric)
returns text language sql stable as $$
  select case p_basis
           when 'per_km'       then format(public._stl_c('driver.per_km'),  public._stl_num(p_driver))
           when 'per_box'      then format(public._stl_c('driver.per_box'), public._stl_num(p_driver))
           when 'pct_of_order' then format(public._stl_c('driver.pct_of_order'), public._stl_num(p_rate) || '%')
           else public._stl_c('driver.flat')
         end
$$;

-- ── 1. THE SNAPSHOT ─────────────────────────────────────────────────────────
-- Stamped once. `on conflict do nothing` is the entire guarantee: renegotiate
-- the split next month and every already-billed order still settles on the
-- terms that were live when its bill was raised.
create or replace function public.settlement_snapshot_order(p_order_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.order_fulfilment_snapshot
    (order_id, zone_id, mode, partner_id, partner_name, split_pct, source)
  select o.id,
         o.zone_id,
         coalesce(m.mode, 'self'),
         case when coalesce(m.mode,'self') = 'partner' then m.partner_id end,
         case when coalesce(m.mode,'self') = 'partner' then rp.partner_name end,
         case when coalesce(m.mode,'self') = 'partner' then coalesce(m.split_pct, 0) else 0 end,
         'bill'
    from public.orders o
    left join public.zone_fulfilment_mode m on m.zone_id = o.zone_id
    left join public.region_partners rp     on rp.id = m.partner_id
   where o.id = p_order_id
  on conflict (order_id) do nothing;
end $$;

-- ── 2. THE COST LINES ───────────────────────────────────────────────────────
-- p_force rebuilds the terms too — that is the admin's explicit "Recalculate",
-- and it is refused on a period that has already been closed, because a closed
-- statement is a printed number.
create or replace function public.settlement_cost_lines_build(p_order_id uuid,
                                                              p_force boolean default false)
returns int language plpgsql security definer set search_path to 'public' as $$
declare
  v_km      numeric := public._stl_order_km(p_order_id);
  v_boxes   numeric := public._stl_order_boxes(p_order_id);
  v_revenue numeric := coalesce((select revenue from public.pnl_order_v where order_id = p_order_id), 0);
  v_frozen  boolean := exists (
    select 1 from public.partner_settlements s
      join public.partner_settlement_periods p on p.id = s.period_id
     where s.order_id = p_order_id and p.status <> 'open');
  v_n int := 0;
begin
  if v_frozen then
    return 0;
  end if;

  -- New lines take today's terms. This is where "a basis change applies to
  -- future orders" is actually enforced: an order that already has its line
  -- keeps the basis and rates stamped on it.
  insert into public.order_costs
    (order_id, cost_type, basis, base_value, rate_value,
     computed_amount, driver_value, driver_label, source)
  select p_order_id, ct.slug, ct.basis, ct.default_value, ct.rate_value,
         round(ct.default_value + ct.rate_value
               * public._stl_driver(ct.basis, v_km, v_boxes, v_revenue), 2),
         public._stl_driver(ct.basis, v_km, v_boxes, v_revenue),
         public._stl_driver_label(ct.basis,
               public._stl_driver(ct.basis, v_km, v_boxes, v_revenue), ct.rate_value),
         'auto'
    from public.cost_types ct
   where ct.active
  on conflict (order_id, cost_type) do nothing;
  get diagnostics v_n = row_count;

  if p_force then
    -- Recalculate: re-take the terms from the cost types as they stand now.
    update public.order_costs oc
       set basis = ct.basis, base_value = ct.default_value, rate_value = ct.rate_value,
           driver_value = public._stl_driver(ct.basis, v_km, v_boxes, v_revenue),
           driver_label = public._stl_driver_label(ct.basis,
                            public._stl_driver(ct.basis, v_km, v_boxes, v_revenue), ct.rate_value),
           computed_amount = round(ct.default_value + ct.rate_value
                            * public._stl_driver(ct.basis, v_km, v_boxes, v_revenue), 2),
           updated_at = now()
      from public.cost_types ct
     where ct.slug = oc.cost_type and oc.order_id = p_order_id;
  else
    -- The routine refresh: the TERMS stay frozen, only the measurements move,
    -- because km, boxes and order value genuinely land after the bill does.
    update public.order_costs oc
       set driver_value = public._stl_driver(oc.basis, v_km, v_boxes, v_revenue),
           driver_label = public._stl_driver_label(oc.basis,
                            public._stl_driver(oc.basis, v_km, v_boxes, v_revenue), oc.rate_value),
           computed_amount = round(oc.base_value + oc.rate_value
                            * public._stl_driver(oc.basis, v_km, v_boxes, v_revenue), 2),
           updated_at = now()
     where oc.order_id = p_order_id;
  end if;

  return v_n;
end $$;

-- What an order's costs come to. The override wins the money; the computed
-- figure stays on the row so the edit reads as a deviation, not a replacement.
create or replace function public._stl_cost_total(p_order_id uuid)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select round(coalesce(sum(coalesce(oc.override_amount, oc.computed_amount)), 0), 2)
    from public.order_costs oc
   where oc.order_id = p_order_id
$$;

-- ── 3. PERIOD BOUNDARIES ────────────────────────────────────────────────────
-- One place that knows what a cadence means, so the closer, the builder and
-- the screens can never disagree about which day belongs to which statement.
create or replace function public.settlement_period_bounds(p_cadence text, p_date date)
returns table (period_start date, period_end date, due_on date)
language sql immutable as $$
  select case p_cadence
           when 'weekly'  then date_trunc('week',  p_date)::date
           when 'monthly' then date_trunc('month', p_date)::date
           else p_date end,
         case p_cadence
           when 'weekly'  then (date_trunc('week',  p_date) + interval '6 days')::date
           when 'monthly' then (date_trunc('month', p_date) + interval '1 month - 1 day')::date
           else p_date end,
         case p_cadence
           when 'weekly'  then (date_trunc('week',  p_date) + interval '6 days')::date
           when 'monthly' then (date_trunc('month', p_date) + interval '1 month - 1 day')::date
           when 't_plus_2' then p_date + 2
           else p_date end
$$;

-- ── 4. ONE ORDER'S SETTLEMENT ROW ───────────────────────────────────────────
-- The DETAIL, not the money. partner_share here is this order's arithmetic
-- share, printed so a statement can be read line by line; what is actually
-- transferred is the PERIOD row, because that is where a loss nets off.
create or replace function public.settlement_order_row(p_order_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  v public.pnl_order_v%rowtype;
  s public.order_fulfilment_snapshot%rowtype;
  v_costs numeric;
  v_dist  numeric;
  v_open  boolean;
begin
  select * into v from public.pnl_order_v where order_id = p_order_id;
  if not found then return; end if;

  perform public.settlement_snapshot_order(p_order_id);
  select * into s from public.order_fulfilment_snapshot where order_id = p_order_id;
  if not found then return; end if;

  -- A row already carried by a closed statement is never restated.
  select coalesce(bool_and(p.status = 'open'), true) into v_open
    from public.partner_settlements ps
    left join public.partner_settlement_periods p on p.id = ps.period_id
   where ps.order_id = p_order_id;
  if not v_open then return; end if;

  perform public.settlement_cost_lines_build(p_order_id, false);
  v_costs := public._stl_cost_total(p_order_id);
  v_dist  := round(coalesce(v.gross_margin, 0) - v_costs, 2);

  insert into public.partner_settlements
    (order_id, partner_id, zone_id, order_code, order_date, mode, split_pct,
     revenue, goods_cost, gross_margin, cost_total, distributable,
     partner_share, medibo_share, computed_at)
  values
    (p_order_id, s.partner_id, coalesce(s.zone_id, v.zone_id), v.order_code, v.order_date,
     s.mode, s.split_pct,
     coalesce(v.revenue,0), coalesce(v.goods_cost,0), coalesce(v.gross_margin,0),
     v_costs, v_dist,
     round(v_dist * s.split_pct / 100, 2),
     round(v_dist - round(v_dist * s.split_pct / 100, 2), 2),
     now())
  on conflict (order_id) do update set
     partner_id    = excluded.partner_id,
     zone_id       = excluded.zone_id,
     order_code    = excluded.order_code,
     order_date    = excluded.order_date,
     mode          = excluded.mode,
     split_pct     = excluded.split_pct,
     revenue       = excluded.revenue,
     goods_cost    = excluded.goods_cost,
     gross_margin  = excluded.gross_margin,
     cost_total    = excluded.cost_total,
     distributable = excluded.distributable,
     partner_share = excluded.partner_share,
     medibo_share  = excluded.medibo_share,
     computed_at   = now();
end $$;

-- ── 5. ATTACH EVERY UNSETTLED ORDER TO ITS PERIOD ───────────────────────────
-- Self zones are settled by definition — 100% stays with mediBO — so they get
-- their detail row and no period. Only partner orders create a statement.
create or replace function public.settlement_build(p_from date default null,
                                                   p_to   date default null)
returns int language plpgsql security definer set search_path to 'public' as $$
declare
  r        record;
  v_from   date := coalesce(p_from, (now() at time zone 'Asia/Kolkata')::date - 45);
  v_to     date := coalesce(p_to,   (now() at time zone 'Asia/Kolkata')::date);
  v_cad    text;
  b        record;
  v_period bigint;
  v_n      int := 0;
begin
  for r in
    select v.order_id
      from public.pnl_order_v v
     where v.order_date between v_from and v_to
       and not exists (
             select 1 from public.partner_settlements ps
               join public.partner_settlement_periods p on p.id = ps.period_id
              where ps.order_id = v.order_id and p.status <> 'open')
  loop
    perform public.settlement_order_row(r.order_id);
    v_n := v_n + 1;
  end loop;

  -- Bucket every partner order that is not already inside a closed statement.
  for r in
    select ps.* from public.partner_settlements ps
      left join public.partner_settlement_periods p on p.id = ps.period_id
     where ps.mode = 'partner' and ps.partner_id is not null
       and ps.order_date between v_from and v_to
       and (p.id is null or p.status = 'open')
  loop
    -- The cadence LIVE NOW decides which future period this order lands in;
    -- once that period closes it keeps the cadence it was written under.
    select coalesce(m.cadence, sc.default_cadence, 'same_day') into v_cad
      from public.settlement_config sc
      left join public.zone_fulfilment_mode m on m.zone_id = r.zone_id
     where sc.id = 1;

    select * into b from public.settlement_period_bounds(coalesce(v_cad,'same_day'), r.order_date);

    insert into public.partner_settlement_periods
      (partner_id, zone_id, period_start, period_end, cadence, due_on, split_pct)
    values (r.partner_id, r.zone_id, b.period_start, b.period_end,
            coalesce(v_cad,'same_day'), b.due_on, r.split_pct)
    on conflict (partner_id, cadence, period_start, period_end, split_pct) do nothing;

    select id into v_period from public.partner_settlement_periods
     where partner_id = r.partner_id and cadence = coalesce(v_cad,'same_day')
       and period_start = b.period_start and period_end = b.period_end
       and split_pct = r.split_pct;

    if v_period is not null and coalesce(r.period_id, -1) <> v_period then
      update public.partner_settlements set period_id = v_period where id = r.id;
    end if;
  end loop;

  perform public.settlement_period_totals(p.id)
     from public.partner_settlement_periods p
    where p.status = 'open' and p.period_end between v_from - 31 and v_to;

  return v_n;
end $$;

-- ── 6. THE PERIOD TOTAL ─────────────────────────────────────────────────────
-- Sum the margin, sum the costs, THEN split — never the other way round. This
-- is the whole of Om's loss rule: a negative order pulls the total down and
-- disappears into it, instead of being settled on its own.
create or replace function public.settlement_period_totals(p_period_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  p public.partner_settlement_periods%rowtype;
  t record;
  v_share numeric;
  v_net   numeric;
begin
  select * into p from public.partner_settlement_periods where id = p_period_id;
  if not found or p.status = 'settled' then return; end if;

  select count(*) n,
         coalesce(sum(revenue),0)      rev,
         coalesce(sum(goods_cost),0)   goods,
         coalesce(sum(gross_margin),0) gross,
         coalesce(sum(cost_total),0)   costs
    into t
    from public.partner_settlements where period_id = p_period_id;

  v_share := round((t.gross - t.costs) * p.split_pct / 100, 2);
  v_net   := round(v_share + coalesce(p.brought_forward, 0), 2);

  update public.partner_settlement_periods set
    orders_count  = t.n,
    revenue       = t.rev,
    goods_cost    = t.goods,
    gross_margin  = t.gross,
    cost_total    = t.costs,
    distributable = round(t.gross - t.costs, 2),
    partner_share = v_share,
    medibo_share  = round((t.gross - t.costs) - v_share, 2),
    net_due       = v_net,
    -- A period under water transfers NOTHING and hands the shortfall on. The
    -- partner is never asked to pay money back.
    payable       = greatest(v_net, 0),
    carry_forward = least(v_net, 0),
    computed_at   = now()
  where id = p_period_id;
end $$;

-- ── 7. CLOSING, AUTOMATICALLY ───────────────────────────────────────────────
-- Oldest first, because the brought-forward chain is an ORDER: a period can
-- only inherit a shortfall that has already been decided.
create or replace function public.settlement_close_due()
returns int language plpgsql security definer set search_path to 'public' as $$
declare
  cfg public.settlement_config%rowtype;
  r   record;
  v_bf   numeric;
  v_n    int := 0;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  select * into cfg from public.settlement_config where id = 1;
  if not coalesce(cfg.auto_close, true) then return 0; end if;

  for r in
    select * from public.partner_settlement_periods
     where status = 'open' and due_on <= v_today
     order by period_end, id
  loop
    -- The shortfall this period inherits: the carry of the LAST already-closed
    -- period for the same partner. One hop, not a running sum, because each
    -- closed period already folded its own inheritance into its carry.
    select coalesce((
             select p2.carry_forward from public.partner_settlement_periods p2
              where p2.partner_id = r.partner_id and p2.status <> 'open'
                and p2.period_end < r.period_start
              order by p2.period_end desc, p2.id desc limit 1), 0)
      into v_bf;

    update public.partner_settlement_periods
       set brought_forward = v_bf
     where id = r.id;

    perform public.settlement_period_totals(r.id);

    update public.partner_settlement_periods
       set status = 'due', closed_at = now()
     where id = r.id;

    -- Automatic lane: the transfer is queued the moment the period closes, so
    -- nobody has to remember to pay. It shows as pending on the statement
    -- until Route reports the transfer id back.
    if coalesce(cfg.route_mode,'manual') = 'automatic' then
      insert into public.partner_settlement_payments
        (period_id, amount, method, status, note, recorded_by)
      select r.id, p.payable, 'razorpay_route', 'queued',
             public._stl_c('route.automatic_note'), 'settlement_close'
        from public.partner_settlement_periods p
       where p.id = r.id and p.payable > 0
         and not exists (select 1 from public.partner_settlement_payments x
                          where x.period_id = r.id and x.method = 'razorpay_route');
    end if;

    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

-- The one entry point the dispatcher calls.
create or replace function public.settlement_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_built int; v_closed int;
begin
  v_built  := public.settlement_build(null, null);
  v_closed := public.settlement_close_due();
  return jsonb_build_object('ok', true, 'built', v_built, 'closed', v_closed);
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end $$;

-- ── 8. THE STAMP HAPPENS AT BILL TIME ───────────────────────────────────────
-- Its own trigger, in its own exception block: a fault in this feature must
-- never be able to stop a bill from being raised.
create or replace function public._trg_stl_bill_job()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.settlement_snapshot_order(new.order_id);
    perform public.settlement_cost_lines_build(new.order_id, false);
  exception when others then
    null;
  end;
  return new;
end $$;

drop trigger if exists stl_bill_job_snapshot on public.bill_jobs;
create trigger stl_bill_job_snapshot
  after insert on public.bill_jobs
  for each row execute function public._trg_stl_bill_job();

-- ── 9. THE MONTHLY ROLLUP ───────────────────────────────────────────────────
-- Reporting only. The settlement UNIT stays the period Om chose; this view
-- just adds the months up so a year reads on one screen.
create or replace view public.partner_settlement_month_v as
select p.partner_id,
       rp.partner_name,
       to_char(p.period_end, 'YYYY-MM')          as month,
       count(*)                                  as periods,
       sum(p.orders_count)                       as orders_count,
       sum(p.revenue)                            as revenue,
       sum(p.goods_cost)                         as goods_cost,
       sum(p.gross_margin)                       as gross_margin,
       sum(p.cost_total)                         as cost_total,
       sum(p.distributable)                      as distributable,
       sum(p.partner_share)                      as partner_share,
       sum(p.medibo_share)                       as medibo_share,
       sum(p.payable)                            as payable,
       coalesce(sum((select sum(x.amount) from public.partner_settlement_payments x
                      where x.period_id = p.id and x.status = 'paid')), 0) as transferred
  from public.partner_settlement_periods p
  left join public.region_partners rp on rp.id = p.partner_id
 where p.status <> 'open'
 group by p.partner_id, rp.partner_name, to_char(p.period_end, 'YYYY-MM');

revoke all on public.partner_settlement_month_v from public, anon, authenticated;

-- ── 10. THE SCHEDULER — the ONE dispatcher, never a new pg_cron job ─────────
-- CHANGE #305 cut 57 pg_cron jobs down to a single dispatcher. This registers a
-- gated task on it: the gate is cheap and false almost always, so the tick
-- costs nothing on a day with nothing to close.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, dml, note)
values (
  'settlement_close', 210, 'poll',
  $g$select exists (
       select 1 from public.partner_settlement_periods
        where status = 'open'
          and due_on <= (now() at time zone 'Asia/Kolkata')::date)
     or exists (
       select 1 from public.partner_settlements ps
        where ps.mode = 'partner' and ps.period_id is null)$g$,
  'select public.settlement_tick()',
  true, true,
  'CHANGE #323 - closes each due partner settlement period, writes the statement and (on the automatic Route lane) queues the transfer. Gated, so it does no work on a day with nothing due.'
)
on conflict (name) do update
  set gate_sql = excluded.gate_sql,
      work_sql = excluded.work_sql,
      enabled  = true,
      dml      = true,
      note     = excluded.note;
