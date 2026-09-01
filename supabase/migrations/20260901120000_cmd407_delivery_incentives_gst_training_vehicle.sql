-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 1 — the four tables the delivery build was missing.
-- Incentives, the agency's tax paperwork, the training gate, and the vehicle
-- ledger that turns cost-per-drop from a configured guess into a measurement.
-- Every migration here is idempotent: a resumed worker re-runs it as a no-op.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1A · INCENTIVES ────────────────────────────────────────────────────────
-- The metric list is DATA, exactly like cost_types.basis: a new target metric
-- is one INSERT here plus one branch in _incentive_metric_value(), never a
-- dropdown edited in Dart.
create table if not exists public.incentive_metrics (
  slug          text primary key,
  label         text not null,
  value_suffix  text not null default '',
  target_hint   text not null default '',
  sort_order    int  not null default 100,
  active        boolean not null default true
);

insert into public.incentive_metrics(slug,label,value_suffix,target_hint,sort_order) values
  ('drops_per_day','Deliveries in a day',' drops',
   'Pays once for every day the rider reaches the count.',10),
  ('on_time_pct','On-time %','%',
   'Share of the day''s deliveries inside the promise window.',20),
  ('streak_days','Delivery streak',' days',
   'Consecutive days, ending on the day scored, with a delivery.',30)
on conflict (slug) do nothing;

create table if not exists public.incentive_schemes (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  label         text not null,
  scope         text not null default 'all',
  zone_id       smallint,
  agency_id     uuid references public.delivery_partner_registrations(id) on delete cascade,
  metric        text not null references public.incentive_metrics(slug),
  threshold     numeric not null default 0,
  bonus_amount  numeric not null default 0,
  window_start  date,
  window_end    date,
  active        boolean not null default true,
  sort_order    int not null default 100,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    text
);

do $$ begin
  alter table public.incentive_schemes
    add constraint incentive_schemes_scope_ck check (scope in ('all','zone','agency'));
exception when duplicate_object then null; end $$;

-- One row per (scheme, rider, day). The unique key is what makes the engine
-- safe to re-run: a second evaluation of the same day updates, never doubles.
create table if not exists public.incentive_earnings (
  id            uuid primary key default gen_random_uuid(),
  scheme_id     uuid not null references public.incentive_schemes(id) on delete cascade,
  partner_id    uuid not null references public.delivery_partner_registrations(id) on delete cascade,
  earn_date     date not null,
  metric        text not null,
  metric_value  numeric not null default 0,
  threshold     numeric not null default 0,
  amount        numeric not null default 0,
  payout_period_id uuid references public.delivery_payout_periods(id) on delete set null,
  created_at    timestamptz not null default now(),
  unique (scheme_id, partner_id, earn_date)
);
create index if not exists incentive_earnings_partner_date_idx
  on public.incentive_earnings(partner_id, earn_date);
create index if not exists incentive_earnings_unclaimed_idx
  on public.incentive_earnings(partner_id, earn_date) where payout_period_id is null;

-- ── 1B · AGENCY GST INVOICE ────────────────────────────────────────────────
-- The GSTIN belongs on the registration: it is the agency's identity, not a
-- per-invoice field an admin retypes every period.
alter table public.delivery_partner_registrations
  add column if not exists gstin           text,
  add column if not exists pan             text,
  add column if not exists legal_name      text,
  add column if not exists billing_address text,
  add column if not exists training_override_at     timestamptz,
  add column if not exists training_override_by     uuid,
  add column if not exists training_override_reason text;

-- The tax rate, HSN/SAC and invoice prefix are config, not literals.
alter table public.delivery_config
  add column if not exists agency_gst_pct         numeric not null default 18,
  add column if not exists agency_hsn             text    not null default '996813',
  add column if not exists agency_invoice_prefix  text    not null default 'MB-DA';

create table if not exists public.agency_invoices (
  id            uuid primary key default gen_random_uuid(),
  period_id     uuid not null unique references public.delivery_payout_periods(id) on delete cascade,
  partner_id    uuid not null references public.delivery_partner_registrations(id) on delete cascade,
  invoice_no    text not null unique,
  invoice_date  date not null,
  tax_period    date not null,
  agency_name   text not null default '',
  legal_name    text,
  agency_gstin  text,
  drop_count    int     not null default 0,
  drops_amount  numeric not null default 0,
  bonus_amount  numeric not null default 0,
  taxable       numeric not null default 0,
  rate          numeric not null default 0,
  cgst          numeric not null default 0,
  sgst          numeric not null default 0,
  igst          numeric not null default 0,
  total_tax     numeric not null default 0,
  total         numeric not null default 0,
  is_interstate boolean not null default false,
  gstin_missing boolean not null default true,
  place_of_supply text,
  hsn           text,
  doc_id        uuid,
  signed_path   text,
  signed_name   text,
  signed_total  numeric,
  signed_at     timestamptz,
  signed_by     uuid,
  recon_status  text not null default 'pending',
  recon_diff    numeric,
  recon_note    text,
  recon_at      timestamptz,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now()
);
create index if not exists agency_invoices_partner_idx on public.agency_invoices(partner_id, tax_period);

-- ── 1C · TRAINING (SOP) ────────────────────────────────────────────────────
create table if not exists public.sop_modules (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  title       text not null,
  body        text not null default '',
  media_path  text,
  pass_mark   int  not null default 70,
  is_required boolean not null default true,
  sort_order  int  not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  text
);

create table if not exists public.sop_questions (
  id            uuid primary key default gen_random_uuid(),
  module_id     uuid not null references public.sop_modules(id) on delete cascade,
  prompt        text not null,
  options       jsonb not null default '[]'::jsonb,
  correct_index int not null default 0,
  sort_order    int not null default 100,
  active        boolean not null default true
);
create index if not exists sop_questions_module_idx on public.sop_questions(module_id, sort_order);

create table if not exists public.sop_completions (
  id              uuid primary key default gen_random_uuid(),
  module_id       uuid not null references public.sop_modules(id) on delete cascade,
  partner_id      uuid not null references public.delivery_partner_registrations(id) on delete cascade,
  attempts        int not null default 0,
  score_pct       numeric not null default 0,
  passed          boolean not null default false,
  passed_at       timestamptz,
  last_attempt_at timestamptz,
  unique (module_id, partner_id)
);

-- ── 1D · VEHICLE & FUEL LOG ────────────────────────────────────────────────
create table if not exists public.delivery_expense_kinds (
  slug           text primary key,
  label          text not null,
  needs_odometer boolean not null default false,
  needs_litres   boolean not null default false,
  sort_order     int not null default 100,
  active         boolean not null default true
);

insert into public.delivery_expense_kinds(slug,label,needs_odometer,needs_litres,sort_order) values
  ('fuel','Fuel',true,true,10),
  ('maintenance','Maintenance / service',true,false,20),
  ('tyre','Tyres',false,false,30),
  ('insurance','Insurance / permit',false,false,40),
  ('other','Other',false,false,90)
on conflict (slug) do nothing;

create table if not exists public.delivery_vehicles (
  id           uuid primary key default gen_random_uuid(),
  partner_id   uuid not null references public.delivery_partner_registrations(id) on delete cascade,
  reg_number   text not null,
  vehicle_type text not null default '',
  make_model   text,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (partner_id, reg_number)
);

create table if not exists public.delivery_vehicle_expenses (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid references public.delivery_vehicles(id) on delete set null,
  partner_id  uuid not null references public.delivery_partner_registrations(id) on delete cascade,
  kind        text not null references public.delivery_expense_kinds(slug),
  amount      numeric not null default 0,
  odometer_km numeric,
  litres      numeric,
  spend_date  date not null default (now() at time zone 'Asia/Kolkata')::date,
  receipt_path text,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create index if not exists delivery_vehicle_expenses_partner_idx
  on public.delivery_vehicle_expenses(partner_id, spend_date);

-- ── 1E · RLS — the house pattern: read for the people who own the row,
-- every write through a SECURITY DEFINER RPC. ──────────────────────────────
alter table public.incentive_metrics          enable row level security;
alter table public.incentive_schemes          enable row level security;
alter table public.incentive_earnings         enable row level security;
alter table public.agency_invoices            enable row level security;
alter table public.sop_modules                enable row level security;
alter table public.sop_questions              enable row level security;
alter table public.sop_completions            enable row level security;
alter table public.delivery_expense_kinds     enable row level security;
alter table public.delivery_vehicles          enable row level security;
alter table public.delivery_vehicle_expenses  enable row level security;

do $$
declare
  v_mine text := '(exists (select 1 from public.delivery_partner_registrations r '
              || 'where r.id = %I.partner_id and r.user_id = auth.uid()))';
begin
  -- admin-everything + owner-read, one pair per table.
  if not exists (select 1 from pg_policy where polname='incentive_metrics_read') then
    execute 'create policy incentive_metrics_read on public.incentive_metrics for select using (auth.uid() is not null)';
  end if;
  if not exists (select 1 from pg_policy where polname='incentive_schemes_read') then
    execute 'create policy incentive_schemes_read on public.incentive_schemes for select using (auth.uid() is not null)';
  end if;
  if not exists (select 1 from pg_policy where polname='incentive_earnings_read') then
    execute format('create policy incentive_earnings_read on public.incentive_earnings for select using '
      || '(public.is_admin() or ' || v_mine || ')', 'incentive_earnings');
  end if;
  if not exists (select 1 from pg_policy where polname='agency_invoices_read') then
    execute format('create policy agency_invoices_read on public.agency_invoices for select using '
      || '(public.is_admin() or ' || v_mine || ')', 'agency_invoices');
  end if;
  if not exists (select 1 from pg_policy where polname='sop_modules_read') then
    execute 'create policy sop_modules_read on public.sop_modules for select using (auth.uid() is not null)';
  end if;
  if not exists (select 1 from pg_policy where polname='sop_questions_read') then
    execute 'create policy sop_questions_read on public.sop_questions for select using (public.is_admin())';
  end if;
  if not exists (select 1 from pg_policy where polname='sop_completions_read') then
    execute format('create policy sop_completions_read on public.sop_completions for select using '
      || '(public.is_admin() or ' || v_mine || ')', 'sop_completions');
  end if;
  if not exists (select 1 from pg_policy where polname='delivery_expense_kinds_read') then
    execute 'create policy delivery_expense_kinds_read on public.delivery_expense_kinds for select using (auth.uid() is not null)';
  end if;
  if not exists (select 1 from pg_policy where polname='delivery_vehicles_read') then
    execute format('create policy delivery_vehicles_read on public.delivery_vehicles for select using '
      || '(public.is_admin() or ' || v_mine || ')', 'delivery_vehicles');
  end if;
  if not exists (select 1 from pg_policy where polname='delivery_vehicle_expenses_read') then
    execute format('create policy delivery_vehicle_expenses_read on public.delivery_vehicle_expenses for select using '
      || '(public.is_admin() or ' || v_mine || ')', 'delivery_vehicle_expenses');
  end if;
end $$;
-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 2 — the incentive ENGINE, and the payout run that pays it.
-- A bonus that does not land in the payout is a number on a screen; the whole
-- point is that it rides out with the earnings the rider already gets.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.delivery_payout_periods
  add column if not exists bonus_amount numeric not null default 0;

-- One metric, one day, one rider. Everything the engine knows how to score
-- lives here; incentive_metrics is the list the ADMIN sees, this is the list
-- the engine can compute — they are kept in step by _incentive_metric_value
-- returning null for a metric it has never heard of (an unknown metric never
-- pays, it just never fires).
create or replace function public._incentive_metric_value(
  p_partner uuid, p_date date, p_metric text) returns numeric
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_del int; v_on int; v_grace int; v_streak int := 0; v_d date;
begin
  if p_metric = 'drops_per_day' then
    select count(*) into v_del from public.deliveries d
     where d.partner_id = p_partner and d.status = 'delivered'
       and (d.delivered_at at time zone 'Asia/Kolkata')::date = p_date;
    return coalesce(v_del,0);

  elsif p_metric = 'on_time_pct' then
    v_grace := coalesce((public._dcfg(null)->>'on_time_grace_min')::int, 0);
    select count(*),
           count(*) filter (where d.promised_at is not null
                              and d.delivered_at <= d.promised_at + make_interval(mins => v_grace))
      into v_del, v_on
      from public.deliveries d
     where d.partner_id = p_partner and d.status = 'delivered'
       and (d.delivered_at at time zone 'Asia/Kolkata')::date = p_date;
    if coalesce(v_del,0) = 0 then return 0; end if;
    return round(100.0 * v_on / v_del, 2);

  elsif p_metric = 'streak_days' then
    v_d := p_date;
    loop
      exit when not exists (
        select 1 from public.deliveries d
         where d.partner_id = p_partner and d.status = 'delivered'
           and (d.delivered_at at time zone 'Asia/Kolkata')::date = v_d);
      v_streak := v_streak + 1;
      v_d := v_d - 1;
      exit when v_streak >= 366;
    end loop;
    return v_streak;
  end if;
  return null;
end $$;

-- Which schemes apply to this rider on this day. Scope is data: 'all', the
-- rider's zone, or the agency the rider belongs to (an agency scheme covers
-- the agency row itself AND every rider parented to it).
create or replace function public.incentive_schemes_for(p_partner uuid, p_date date)
returns setof public.incentive_schemes
language sql stable security definer set search_path to 'public' as $$
  select s.* from public.incentive_schemes s
  join public.delivery_partner_registrations r on r.id = p_partner
  where s.active
    and (s.window_start is null or p_date >= s.window_start)
    and (s.window_end   is null or p_date <= s.window_end)
    and (s.scope = 'all'
      or (s.scope = 'zone'   and s.zone_id is not distinct from r.zone_id)
      or (s.scope = 'agency' and s.agency_id in (r.id, r.parent_agency_id)))
  order by s.sort_order, s.label;
$$;

-- The engine. Idempotent by (scheme, partner, day): re-running a day corrects
-- it, never doubles it — and an earning already swept into a payout period is
-- left alone, because that amount has been approved at that number.
create or replace function public.incentive_evaluate_day(
  p_date date default null, p_partner uuid default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  r record; s record; v_val numeric; v_hit int := 0; v_miss int := 0;
  v_amount numeric := 0; v_riders int := 0;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin')
     and current_setting('request.jwt.claim.role', true) is distinct from 'service_role'
     and auth.uid() is not null then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  for r in select id from public.delivery_partner_registrations
            where is_active and coalesce(is_deleted,false) = false
              and (p_partner is null or id = p_partner)
  loop
    v_riders := v_riders + 1;
    for s in select * from public.incentive_schemes_for(r.id, v_date) loop
      v_val := public._incentive_metric_value(r.id, v_date, s.metric);
      if v_val is null then continue; end if;

      if v_val >= s.threshold and s.threshold > 0 then
        insert into public.incentive_earnings(
            scheme_id, partner_id, earn_date, metric, metric_value, threshold, amount)
        values (s.id, r.id, v_date, s.metric, v_val, s.threshold, s.bonus_amount)
        on conflict (scheme_id, partner_id, earn_date) do update
          set metric_value = excluded.metric_value,
              threshold    = excluded.threshold,
              amount       = excluded.amount
          where public.incentive_earnings.payout_period_id is null;
        v_hit := v_hit + 1;
        v_amount := v_amount + s.bonus_amount;
      else
        -- The rider fell back below the target on a re-run of the same day.
        delete from public.incentive_earnings e
         where e.scheme_id = s.id and e.partner_id = r.id and e.earn_date = v_date
           and e.payout_period_id is null;
        v_miss := v_miss + 1;
      end if;
    end loop;
  end loop;

  return jsonb_build_object('ok',true,'the_date',v_date,
    'riders',v_riders,'earned',v_hit,'missed',v_miss,
    'amount',v_amount,'amount_label', public.inr_money(v_amount));
end $$;

-- Nightly, on the ONE dispatcher, inside the quiet window. Never a bare */N.
insert into public.cron_task(name, ord, mode, work_sql, step_timeout_ms, enabled, note,
                             base_interval_s, run_at_ist, dml)
select 'incentive_evaluate_yesterday', 566, 'poll',
       'select public.incentive_evaluate_day(((now() at time zone ''Asia/Kolkata'')::date - 1));',
       30000, true, 'Scores yesterday''s rider incentives into incentive_earnings.',
       3600, time '02:10', true
where not exists (select 1 from public.cron_task where name = 'incentive_evaluate_yesterday');

-- ── The rider's own progress, finished. Nothing on this payload is a number
-- Dart has to compare, format or pluralise. ────────────────────────────────
create or replace function public.my_incentive_progress(p_date date default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  p public.delivery_partner_registrations%rowtype;
  v_date date; s record; v_val numeric; v_rows jsonb := '[]'::jsonb;
  v_m public.incentive_metrics%rowtype; v_pct numeric; v_earned numeric := 0;
begin
  select * into p from public.delivery_partner_registrations
   where user_id = auth.uid() and is_active and coalesce(is_deleted,false)=false limit 1;
  if p.id is null then
    return jsonb_build_object('has', false, 'rows', '[]'::jsonb);
  end if;
  v_date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);

  for s in select * from public.incentive_schemes_for(p.id, v_date) loop
    v_val := public._incentive_metric_value(p.id, v_date, s.metric);
    if v_val is null then continue; end if;
    select * into v_m from public.incentive_metrics where slug = s.metric;
    v_pct := case when coalesce(s.threshold,0) <= 0 then 0
                  else least(1.0, round(v_val / s.threshold, 4)) end;
    v_rows := v_rows || jsonb_build_object(
      'scheme_id', s.id,
      'label',       s.label,
      'metric_label',coalesce(v_m.label, s.metric),
      'value_label', trim(to_char(v_val,'FM999999990.99')) || coalesce(v_m.value_suffix,''),
      'target_label',trim(to_char(s.threshold,'FM999999990.99')) || coalesce(v_m.value_suffix,''),
      'progress',    v_pct,
      'bonus_label', public.inr_money(s.bonus_amount),
      'earned',      (v_val >= s.threshold and s.threshold > 0),
      'status_label', case when (v_val >= s.threshold and s.threshold > 0)
                           then public._c('delivery.incentive.earned')
                           else public._c('delivery.incentive.in_progress') end,
      'tone',         case when (v_val >= s.threshold and s.threshold > 0)
                           then 'success' else 'warning' end);
    if v_val >= s.threshold and s.threshold > 0 then
      v_earned := v_earned + s.bonus_amount;
    end if;
  end loop;

  return jsonb_build_object(
    'has', jsonb_array_length(v_rows) > 0,
    'title',      public._c('delivery.incentive.title'),
    'empty_note', public._c('delivery.incentive.empty'),
    'the_date',   v_date,
    'earned_today_label', public.inr_money(v_earned),
    'earned_caption',     public._c('delivery.incentive.earned_today'),
    'rows', v_rows);
end $$;
-- ── PART 2b — the payout run now sweeps bonuses the same way it sweeps drops.
create or replace function public.admin_payout_open(p_partner_id uuid, p_start date default null, p_end date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_days int := coalesce((public._dcfg(null)->>'payout_period_days')::int, 7);
  v_end   date := coalesce(p_end, (now() at time zone 'Asia/Kolkata')::date);
  v_start date := coalesce(p_start, v_end - (v_days - 1));
  v_id uuid; v_n int; v_gross numeric; v_bonus numeric; v_bn int;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
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

  -- CMD #407 — the same sweep, for the incentive the rider already earned.
  -- An earning is claimed exactly once: `payout_period_id is null` is the
  -- guard, and the row keeps the number that was approved.
  update public.incentive_earnings e
     set payout_period_id = v_id
   where e.partner_id = p_partner_id
     and e.payout_period_id is null
     and e.earn_date between v_start and v_end;

  select count(*), coalesce(sum(amount),0) into v_n, v_gross
    from public.delivery_payout_lines where period_id = v_id;
  select count(*), coalesce(sum(amount),0) into v_bn, v_bonus
    from public.incentive_earnings where payout_period_id = v_id;

  update public.delivery_payout_periods
     set drop_count = v_n, gross_amount = v_gross, bonus_amount = v_bonus,
         net_amount = v_gross + v_bonus + coalesce(adjustments,0)
   where id = v_id;

  return jsonb_build_object('ok',true,'period_id',v_id,
    'drop_count',v_n,'gross_amount',v_gross,
    'gross_label', public.inr_money(v_gross),
    'bonus_count', v_bn,
    'bonus_label', public.inr_money(v_bonus),
    'net_label',   public.inr_money(v_gross + v_bonus),
    'period_label', to_char(v_start,'DD Mon') || ' – ' || to_char(v_end,'DD Mon YYYY'));
end $$;

create or replace function public.admin_payout_statement(p_period_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_p public.delivery_payout_periods%rowtype; v_lines jsonb; v_bonus jsonb; v_name text;
begin
  select * into v_p from public.delivery_payout_periods where id = p_period_id;
  if v_p.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if public.role_for_medibo_only() not in ('admin','super_admin')
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

  -- CMD #407 — bonuses ride on the same statement, as their own block, so the
  -- agency reconciling this page sees exactly what the transfer contains.
  select coalesce(jsonb_agg(jsonb_build_object(
           'label',      s.label,
           'date_label', to_char(e.earn_date,'DD Mon'),
           'hit_label',  trim(to_char(e.metric_value,'FM999999990.99'))
                         || coalesce(m.value_suffix,'') || ' / '
                         || trim(to_char(e.threshold,'FM999999990.99'))
                         || coalesce(m.value_suffix,''),
           'amount_label', public.inr_money(e.amount)) order by e.earn_date), '[]'::jsonb)
    into v_bonus
  from public.incentive_earnings e
  join public.incentive_schemes s on s.id = e.scheme_id
  left join public.incentive_metrics m on m.slug = e.metric
  where e.payout_period_id = p_period_id;

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
    'bonus_label', public.inr_money(coalesce(v_p.bonus_amount,0)),
    'bonus_caption', public._c('admin.delivery.payout_bonus_caption'),
    'has_bonus', (jsonb_array_length(v_bonus) > 0),
    'bonus_lines', v_bonus,
    'net_label',   public.inr_money(v_p.net_amount),
    'paid_ref',    coalesce(v_p.paid_ref,''),
    'paid_at',     v_p.paid_at,
    'can_pay',     (v_p.status = 'unpaid' and public.role_for_medibo_only() in ('admin','super_admin')),
    'pay_label',   public._c('admin.delivery.payout_pay_btn'),
    'lines', v_lines);
end $$;

-- ── Copy. Every string the four surfaces print lives here, so wording is an
-- UPDATE, not a deploy.
insert into public.ui_copy(key, value) values
  ('delivery.incentive.title',        to_jsonb('Today''s targets'::text)),
  ('delivery.incentive.empty',        to_jsonb('No incentive is running for you today.'::text)),
  ('delivery.incentive.earned',       to_jsonb('Earned'::text)),
  ('delivery.incentive.in_progress',  to_jsonb('In progress'::text)),
  ('delivery.incentive.earned_today', to_jsonb('Bonus earned today'::text)),
  ('admin.delivery.payout_bonus_caption', to_jsonb('Incentive bonus'::text))
on conflict (key) do nothing;
