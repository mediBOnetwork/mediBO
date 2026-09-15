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
      'value_label', trim_scale(v_val)::text || coalesce(v_m.value_suffix,''),
      'target_label',trim_scale(s.threshold)::text || coalesce(v_m.value_suffix,''),
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
           'hit_label',  trim_scale(e.metric_value)::text
                         || coalesce(m.value_suffix,'') || ' / '
                         || trim_scale(e.threshold)::text
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
-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 3 — the agency's tax paperwork.
-- The payout says what we owe. The invoice is what the ledger, the auditor and
-- the agency's own accountant read — and until now it did not exist.
-- The PDF rides the CHANGE #403 generic document pipeline: renderDoc() names
-- nothing, so a fourth document kind is SQL and no edge-function deploy.
-- ═══════════════════════════════════════════════════════════════════════════

-- Build (or refresh) the invoice for one payout period.
create or replace function public.agency_invoice_generate(p_period_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_p public.delivery_payout_periods%rowtype;
  r   public.delivery_partner_registrations%rowtype;
  v_cfg jsonb; v_rate numeric; v_hsn text; v_prefix text;
  v_seller text; v_gstin text; v_sp jsonb;
  v_taxable numeric; v_no text; v_id uuid; v_date date; v_inv public.agency_invoices%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into v_p from public.delivery_payout_periods where id = p_period_id;
  if v_p.id is null then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public._c('agency_invoice.err_no_period'));
  end if;
  select * into r from public.delivery_partner_registrations where id = v_p.partner_id;

  select agency_gst_pct, agency_hsn, agency_invoice_prefix
    into v_rate, v_hsn, v_prefix from public.delivery_config where id = 1;
  select seller_gstin into v_seller from public.billing_config where id = 1;
  v_gstin := public.gst_norm_gstin(r.gstin);

  -- The invoice is raised on what the payout actually contains: drops, the
  -- bonus that rode with them, and any adjustment already approved.
  v_taxable := round(coalesce(v_p.gross_amount,0) + coalesce(v_p.bonus_amount,0)
                     + coalesce(v_p.adjustments,0), 2);
  v_sp   := public.gst_split(v_taxable, v_rate, v_seller, v_gstin);
  v_date := v_p.period_end;

  select * into v_inv from public.agency_invoices where period_id = p_period_id;
  v_no := coalesce(v_inv.invoice_no,
            v_prefix || '/' || to_char(v_date,'YYYYMM') || '/' ||
            upper(left(replace(v_p.partner_id::text,'-',''), 6)));

  insert into public.agency_invoices(
      period_id, partner_id, invoice_no, invoice_date, tax_period,
      agency_name, legal_name, agency_gstin,
      drop_count, drops_amount, bonus_amount, taxable, rate,
      cgst, sgst, igst, total_tax, total,
      is_interstate, gstin_missing, place_of_supply, hsn, created_by)
  values (p_period_id, v_p.partner_id, v_no, v_date, date_trunc('month', v_date)::date,
      coalesce(r.full_name,''), r.legal_name, v_gstin,
      coalesce(v_p.drop_count,0), coalesce(v_p.gross_amount,0), coalesce(v_p.bonus_amount,0),
      v_taxable, v_rate,
      (v_sp->>'cgst')::numeric, (v_sp->>'sgst')::numeric, (v_sp->>'igst')::numeric,
      (v_sp->>'total_tax')::numeric, round(v_taxable + (v_sp->>'total_tax')::numeric, 2),
      (v_sp->>'is_interstate')::boolean, (v_sp->>'gstin_missing')::boolean,
      v_sp->>'place_of_supply', v_hsn, auth.uid())
  on conflict (period_id) do update set
      invoice_date = excluded.invoice_date, tax_period = excluded.tax_period,
      agency_name = excluded.agency_name, legal_name = excluded.legal_name,
      agency_gstin = excluded.agency_gstin,
      drop_count = excluded.drop_count, drops_amount = excluded.drops_amount,
      bonus_amount = excluded.bonus_amount, taxable = excluded.taxable,
      rate = excluded.rate, cgst = excluded.cgst, sgst = excluded.sgst,
      igst = excluded.igst, total_tax = excluded.total_tax, total = excluded.total,
      is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
      place_of_supply = excluded.place_of_supply, hsn = excluded.hsn,
      updated_at = now()
  returning id into v_id;

  perform public.agency_invoice_reconcile(v_id);
  return public.agency_invoice_get(v_id);
end $$;

-- Invoice vs payout, in one place. A mismatch is a FLAG on the row, never a
-- refusal to show the document: the admin needs to see both numbers to fix it.
create or replace function public.agency_invoice_reconcile(p_invoice_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  i public.agency_invoices%rowtype; v_p public.delivery_payout_periods%rowtype;
  v_expected numeric; v_diff numeric; v_status text; v_note text; v_tol numeric := 1.00;
begin
  select * into i from public.agency_invoices where id = p_invoice_id;
  if i.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  select * into v_p from public.delivery_payout_periods where id = i.period_id;

  v_expected := round(coalesce(v_p.net_amount,0), 2);
  v_diff     := round(coalesce(i.taxable,0) - v_expected, 2);

  if abs(v_diff) > v_tol then
    v_status := 'mismatch';
    v_note   := public._cf('agency_invoice.recon_mismatch',
                  jsonb_build_object('invoice', public.inr_money(i.taxable),
                                     'payout',  public.inr_money(v_expected),
                                     'diff',    public.inr_money(abs(v_diff))));
  elsif coalesce(i.signed_path,'') = '' then
    v_status := 'awaiting_signed';
    v_note   := public._c('agency_invoice.recon_awaiting');
  elsif i.signed_total is not null and abs(round(i.signed_total - i.total, 2)) > v_tol then
    v_status := 'mismatch';
    v_diff   := round(i.signed_total - i.total, 2);
    v_note   := public._cf('agency_invoice.recon_signed_mismatch',
                  jsonb_build_object('signed', public.inr_money(i.signed_total),
                                     'ours',   public.inr_money(i.total),
                                     'diff',   public.inr_money(abs(v_diff))));
  else
    v_status := 'matched';
    v_note   := public._c('agency_invoice.recon_matched');
  end if;

  update public.agency_invoices
     set recon_status = v_status, recon_diff = v_diff, recon_note = v_note,
         recon_at = now(), updated_at = now()
   where id = p_invoice_id;

  return jsonb_build_object('ok',true,'recon_status',v_status,'recon_note',v_note,
                            'recon_diff', v_diff);
end $$;

-- One invoice, finished, for the admin card and the agency's own screen.
create or replace function public.agency_invoice_get(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare i public.agency_invoices%rowtype; v_mine boolean;
begin
  select * into i from public.agency_invoices where id = p_invoice_id;
  if i.id is null then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public._c('agency_invoice.err_not_found'));
  end if;
  v_mine := exists (select 1 from public.delivery_partner_registrations
                     where id = i.partner_id and user_id = auth.uid());
  if public.role_for_medibo_only() not in ('admin','super_admin') and not v_mine then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  return jsonb_build_object('ok',true,
    'invoice_id', i.id, 'period_id', i.period_id, 'partner_id', i.partner_id,
    'invoice_no', i.invoice_no,
    'invoice_no_label', public._c('agency_invoice.lbl_invoice_no'),
    'date_label',    to_char(i.invoice_date,'DD Mon YYYY'),
    'period_label',  to_char(i.tax_period,'Mon YYYY'),
    'agency_name',   i.agency_name,
    'gstin_label',   coalesce(nullif(i.agency_gstin,''), public._c('agency_invoice.no_gstin')),
    'has_gstin',     (coalesce(i.agency_gstin,'') <> ''),
    'drop_count_label', i.drop_count || ' × ' || public._c('agency_invoice.lbl_drop'),
    'rows', jsonb_build_array(
      jsonb_build_object('label', public._c('agency_invoice.lbl_drops'),   'value', public.inr_money(i.drops_amount)),
      jsonb_build_object('label', public._c('agency_invoice.lbl_bonus'),   'value', public.inr_money(i.bonus_amount)),
      jsonb_build_object('label', public._c('agency_invoice.lbl_taxable'), 'value', public.inr_money(i.taxable)),
      jsonb_build_object('label', trim_scale(i.rate)::text || '% '
                                  || case when i.is_interstate then public._c('agency_invoice.lbl_igst')
                                          else public._c('agency_invoice.lbl_cgst_sgst') end,
                         'value', public.inr_money(i.total_tax)),
      jsonb_build_object('label', public._c('agency_invoice.lbl_total'),
                         'value', public.inr_money(i.total), 'bold', true)),
    'recon_status', i.recon_status,
    'recon_label',  coalesce(i.recon_note,''),
    'recon_tone',   case i.recon_status when 'matched' then 'success'
                                        when 'mismatch' then 'danger' else 'warning' end,
    'has_signed',   (coalesce(i.signed_path,'') <> ''),
    'signed_name',  coalesce(i.signed_name,''),
    'signed_bucket','partner-receipts',
    'signed_path',  coalesce(i.signed_path,''),
    'signed_label', public._c('agency_invoice.lbl_signed'),
    'upload_label', public._c('agency_invoice.upload_btn'),
    'download_label', public._c('agency_invoice.download_btn'),
    'can_upload',   (v_mine or public.role_for_medibo_only() in ('admin','super_admin')));
end $$;

-- ── The PDF, on the #403 pipeline ──────────────────────────────────────────
create or replace function public._agency_invoice_doc_payload(p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  i public.agency_invoices%rowtype; v_seller text; v_rows jsonb;
begin
  select * into i from public.agency_invoices where id = p_invoice_id;
  if i.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  select seller_gstin into v_seller from public.billing_config where id = 1;

  select coalesce(jsonb_agg(jsonb_build_object(
           'date_label', to_char(l.delivered_at at time zone 'Asia/Kolkata','DD/MM/YYYY'),
           'ref', coalesce(o.order_code,''),
           'detail', coalesce(o.pharmacy_name,''),
           'amount', public.inr_money(l.amount)) order by l.delivered_at), '[]'::jsonb)
    into v_rows
  from public.delivery_payout_lines l
  left join public.orders o on o.id = l.order_id
  where l.period_id = i.period_id;

  return jsonb_build_object('ok', true,
    'stamp', md5(i.total::text || coalesce(i.agency_gstin,'') || i.drop_count::text
                 || coalesce(i.recon_status,'')),
    'file_name', regexp_replace(i.invoice_no, '[^0-9A-Za-z_-]', '-', 'g') || '.pdf',
    'doc', jsonb_build_object(
      'title', public._cf('agency_invoice.doc_title', jsonb_build_object('no', i.invoice_no)),
      'subtitle', public._cf('agency_invoice.doc_subtitle',
                    jsonb_build_object('at', public.ist_fmt(now(),'dmy_hm'))),
      'brand', public._c('agency_invoice.doc_brand'),
      'header', jsonb_build_array(
        jsonb_build_object('label', public._c('agency_invoice.lbl_agency'),   'value', coalesce(nullif(i.legal_name,''), i.agency_name)),
        jsonb_build_object('label', public._c('agency_invoice.lbl_gstin'),    'value', coalesce(nullif(i.agency_gstin,''), public._c('agency_invoice.no_gstin'))),
        jsonb_build_object('label', public._c('agency_invoice.lbl_recipient'),'value', coalesce(v_seller,'')),
        jsonb_build_object('label', public._c('agency_invoice.lbl_invoice_no'),'value', i.invoice_no),
        jsonb_build_object('label', public._c('agency_invoice.lbl_date'),     'value', to_char(i.invoice_date,'DD/MM/YYYY')),
        jsonb_build_object('label', public._c('agency_invoice.lbl_pos'),      'value', coalesce(i.place_of_supply,'')),
        jsonb_build_object('label', public._c('agency_invoice.lbl_sac'),      'value', coalesce(i.hsn,''))),
      'sections', jsonb_build_array(jsonb_build_object(
        'heading', public._c('agency_invoice.doc_lines_heading'),
        'columns', jsonb_build_array(
          jsonb_build_object('key','date_label','label',public._c('agency_invoice.col_date'),'align','left','width',90),
          jsonb_build_object('key','ref','label',public._c('agency_invoice.col_ref'),'align','left','width',170),
          jsonb_build_object('key','detail','label',public._c('agency_invoice.col_detail'),'align','left','width',200),
          jsonb_build_object('key','amount','label',public._c('agency_invoice.col_amount'),'align','right','width',100)),
        'rows', v_rows,
        'empty_label', public._c('agency_invoice.doc_lines_empty'))),
      'totals', jsonb_build_array(
        jsonb_build_object('label', public._c('agency_invoice.lbl_drops'),   'value', public.inr_money(i.drops_amount)),
        jsonb_build_object('label', public._c('agency_invoice.lbl_bonus'),   'value', public.inr_money(i.bonus_amount)),
        jsonb_build_object('label', public._c('agency_invoice.lbl_taxable'), 'value', public.inr_money(i.taxable)),
        jsonb_build_object('label', 'CGST', 'value', public.inr_money(i.cgst)),
        jsonb_build_object('label', 'SGST', 'value', public.inr_money(i.sgst)),
        jsonb_build_object('label', 'IGST', 'value', public.inr_money(i.igst)),
        jsonb_build_object('label', public._c('agency_invoice.lbl_total'),
                           'value', public.inr_money(i.total), 'bold', true)),
      'notes', jsonb_build_array(public._c('agency_invoice.doc_note')),
      'footer', public._c('agency_invoice.doc_footer')));
end $$;

-- #403's render_input, taught one more kind. The branch is additive: an
-- agency invoice names its own payload builder, its own bucket and its own
-- path; every existing supplier kind takes the identical path it always took.
create or replace function public.supplier_doc_render_input(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d public.supplier_document%rowtype; pay jsonb;
begin
  select * into d from public.supplier_document where id = p_doc_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'doc_not_found'); end if;

  update public.supplier_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  if d.kind = 'agency_invoice' then
    pay := public._agency_invoice_doc_payload(d.ref_key::uuid);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
    end if;
    return jsonb_build_object('ok', true,
      'doc_id', d.id,
      'bucket', 'partner-receipts',
      'path', 'da' || d.supplier_id::text || '/invoice/' ||
              regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
      'file_name', coalesce(nullif(d.file_name,''), 'invoice.pdf'),
      'document', pay->'doc');
  end if;

  pay := public._c403_doc_payload(d.supplier_id, d.kind, d.ref_key);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'supplier-docs',
    'path', d.supplier_id::text || '/' || d.kind || '/' ||
            regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'document.pdf'),
    'document', pay->'doc');
end $$;
-- ── PART 3b — asking for the PDF, the agency's signed copy, and the ledger.

create or replace function public.agency_invoice_doc_request(p_invoice_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public', 'net' as $$
declare
  i public.agency_invoices%rowtype; pay jsonb; d public.supplier_document%rowtype;
  v_id uuid; v_mine boolean;
begin
  select * into i from public.agency_invoices where id = p_invoice_id;
  if i.id is null then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public._c('agency_invoice.err_not_found'));
  end if;
  v_mine := exists (select 1 from public.delivery_partner_registrations
                     where id = i.partner_id and user_id = auth.uid());
  if public.role_for_medibo_only() not in ('admin','super_admin') and not v_mine then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  pay := public._agency_invoice_doc_payload(p_invoice_id);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok',false,'error',coalesce(pay->>'error','no_payload'),
      'message', public._c('agency_invoice.err_not_found'));
  end if;

  select * into d from public.supplier_document
   where supplier_id = i.partner_id and kind = 'agency_invoice' and ref_key = p_invoice_id::text;

  -- Nothing changed since the last render: serve the file that already exists.
  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok',true,'status','ready','doc_id',d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('agency_invoice.doc_ready'));
  end if;

  insert into public.supplier_document(
      supplier_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (i.partner_id, 'agency_invoice', p_invoice_id::text,
          pay->'doc'->>'title', pay->>'file_name', 'queued', 0,
          pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (supplier_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  update public.agency_invoices set doc_id = v_id, updated_at = now() where id = p_invoice_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('supplier_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok',true,'status','building','doc_id',v_id,
    'poll_ms', 1500, 'message', public._c('agency_invoice.doc_building'));
end $$;

create or replace function public.agency_invoice_doc_status(p_doc_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare d public.supplier_document%rowtype; v_mine boolean;
begin
  select * into d from public.supplier_document where id = p_doc_id and kind = 'agency_invoice';
  if not found then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public._c('agency_invoice.err_not_found'));
  end if;
  v_mine := exists (select 1 from public.delivery_partner_registrations
                     where id = d.supplier_id and user_id = auth.uid());
  if public.role_for_medibo_only() not in ('admin','super_admin') and not v_mine then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if d.status = 'ready' and coalesce(d.path,'') <> '' then
    return jsonb_build_object('ok',true,'status','ready','doc_id',d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('agency_invoice.doc_ready'));
  end if;
  if d.status = 'failed' then
    return jsonb_build_object('ok',false,'status','failed','doc_id',d.id,
      'error','render_failed', 'message', public._c('agency_invoice.doc_failed'));
  end if;
  return jsonb_build_object('ok',true,'status','building','doc_id',d.id,
    'poll_ms',1500,'message', public._c('agency_invoice.doc_building'));
end $$;

-- Where the agency's OWN signed copy goes. The path is the backend's, so the
-- client never invents a folder — and the folder is what the storage policy
-- checks.
create or replace function public.agency_invoice_signed_path(p_invoice_id uuid, p_ext text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare i public.agency_invoices%rowtype; v_mine boolean; v_ext text;
begin
  select * into i from public.agency_invoices where id = p_invoice_id;
  if i.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  v_mine := exists (select 1 from public.delivery_partner_registrations
                     where id = i.partner_id and user_id = auth.uid());
  if public.role_for_medibo_only() not in ('admin','super_admin') and not v_mine then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  v_ext := lower(regexp_replace(coalesce(nullif(p_ext,''),'pdf'), '[^a-z0-9]', '', 'g'));
  return jsonb_build_object('ok',true,'bucket','partner-receipts',
    'path','da' || i.partner_id::text || '/invoice/' || i.id::text || '-signed.' || v_ext);
end $$;

create or replace function public.agency_invoice_signed_record(
  p_invoice_id uuid, p_path text, p_name text, p_total numeric default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare i public.agency_invoices%rowtype; v_mine boolean;
begin
  select * into i from public.agency_invoices where id = p_invoice_id;
  if i.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  v_mine := exists (select 1 from public.delivery_partner_registrations
                     where id = i.partner_id and user_id = auth.uid());
  if public.role_for_medibo_only() not in ('admin','super_admin') and not v_mine then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  update public.agency_invoices
     set signed_path = p_path, signed_name = coalesce(nullif(p_name,''),'signed.pdf'),
         signed_total = p_total, signed_at = now(), signed_by = auth.uid(),
         updated_at = now()
   where id = p_invoice_id;

  perform public.agency_invoice_reconcile(p_invoice_id);
  return public.agency_invoice_get(p_invoice_id);
end $$;

-- ── The GST ledger input-credit row. Only a GST-registered agency generates
-- input credit, so an invoice with no GSTIN is simply absent from the ledger
-- rather than a zero row that looks like a claim.
create or replace function public.gst_ledger_build_agency_invoices(p_from date, p_to date)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare v_n int;
begin
  insert into public.gst_ledger (
    direction, source, source_id, line_ref, tax_period,
    invoice_no, invoice_date, invoice_date_text,
    counterparty_id, counterparty_name, counterparty_gstin,
    hsn, product_name, qty, taxable, rate,
    cgst, sgst, igst, is_interstate, gstin_missing, place_of_supply)
  select 'input', 'agency_invoice', i.id, '1', date_trunc('month', i.invoice_date)::date,
         i.invoice_no, i.invoice_date, to_char(i.invoice_date,'DD/MM/YYYY'),
         i.partner_id::text, i.agency_name, i.agency_gstin,
         coalesce(nullif(i.hsn,''), '996813'),
         public._c('agency_invoice.ledger_line'), i.drop_count, i.taxable, i.rate,
         i.cgst, i.sgst, i.igst, i.is_interstate, i.gstin_missing, i.place_of_supply
    from public.agency_invoices i
   where i.invoice_date >= p_from and i.invoice_date < p_to
     and coalesce(i.agency_gstin,'') <> ''
  on conflict (direction, source, source_id, line_ref) do update set
    tax_period = excluded.tax_period, invoice_no = excluded.invoice_no,
    invoice_date = excluded.invoice_date, invoice_date_text = excluded.invoice_date_text,
    counterparty_id = excluded.counterparty_id, counterparty_name = excluded.counterparty_name,
    counterparty_gstin = excluded.counterparty_gstin, hsn = excluded.hsn,
    product_name = excluded.product_name, qty = excluded.qty,
    taxable = excluded.taxable, rate = excluded.rate,
    cgst = excluded.cgst, sgst = excluded.sgst, igst = excluded.igst,
    is_interstate = excluded.is_interstate, gstin_missing = excluded.gstin_missing,
    place_of_supply = excluded.place_of_supply, built_at = now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.gst_ledger_rebuild(p_months integer default 24)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_started timestamptz := now();
  v_from date := (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
                  - make_interval(months => greatest(coalesce(p_months,24),1) - 1))::date;
  v_to   date := (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
                  + interval '1 month')::date;
  v_in int; v_out int; v_cn int; v_ag int; v_stale int;
begin
  perform public._gst_assert_admin();

  v_in  := public.gst_ledger_build_input(v_from, v_to);
  v_out := public.gst_ledger_build_output(v_from, v_to);
  v_cn  := public.gst_ledger_build_credit_notes(v_from, v_to);
  v_ag  := public.gst_ledger_build_agency_invoices(v_from, v_to);

  delete from public.gst_ledger g
   where g.tax_period >= v_from and g.tax_period < v_to
     and g.built_at < v_started;
  get diagnostics v_stale = row_count;

  return jsonb_build_object(
    'ok', true,
    'from', v_from, 'to', v_to,
    'input_rows', v_in, 'output_rows', v_out,
    'credit_note_rows', v_cn, 'agency_invoice_rows', v_ag,
    'removed_rows', v_stale,
    'message', public._c('gst.rebuilt'));
end $$;

-- ── Storage: the agency reads and writes its OWN folder, and nothing else.
-- This is an ADDITIVE grant on a folder keyed to the reader's own registration
-- id; it takes nothing away from the admin clause that was already there.
do $$ begin
  if not exists (select 1 from pg_policy where polname = 'partner_receipts_agency_own') then
    execute $p$
      create policy partner_receipts_agency_own on storage.objects for select
      using (bucket_id = 'partner-receipts'
             and exists (select 1 from public.delivery_partner_registrations r
                          where r.user_id = auth.uid()
                            and (storage.foldername(name))[1] = 'da' || r.id::text))$p$;
  end if;
  if not exists (select 1 from pg_policy where polname = 'partner_receipts_agency_write') then
    execute $p$
      create policy partner_receipts_agency_write on storage.objects for insert
      with check (bucket_id = 'partner-receipts'
             and exists (select 1 from public.delivery_partner_registrations r
                          where r.user_id = auth.uid()
                            and (storage.foldername(name))[1] = 'da' || r.id::text))$p$;
  end if;
end $$;
-- ── PART 3c — every word the invoice prints.
insert into public.ui_copy(key, value) values
  ('agency_invoice.doc_title',      to_jsonb('TAX INVOICE {no}'::text)),
  ('agency_invoice.doc_subtitle',   to_jsonb('Generated {at} IST'::text)),
  ('agency_invoice.doc_brand',      to_jsonb('mediBO · Jai Mahakal Medical And Surgical'::text)),
  ('agency_invoice.doc_lines_heading', to_jsonb('Deliveries in this period'::text)),
  ('agency_invoice.doc_lines_empty',to_jsonb('No deliveries in this period.'::text)),
  ('agency_invoice.doc_note',       to_jsonb('Delivery service supplied by the agency to mediBO. Reverse charge: No.'::text)),
  ('agency_invoice.doc_footer',     to_jsonb('Computer generated from the payout statement for this period.'::text)),
  ('agency_invoice.col_date',       to_jsonb('Date'::text)),
  ('agency_invoice.col_ref',        to_jsonb('Order'::text)),
  ('agency_invoice.col_detail',     to_jsonb('Pharmacy'::text)),
  ('agency_invoice.col_amount',     to_jsonb('Amount'::text)),
  ('agency_invoice.lbl_agency',     to_jsonb('Supplier of service'::text)),
  ('agency_invoice.lbl_gstin',      to_jsonb('Agency GSTIN'::text)),
  ('agency_invoice.lbl_recipient',  to_jsonb('Recipient GSTIN'::text)),
  ('agency_invoice.lbl_invoice_no', to_jsonb('Invoice no.'::text)),
  ('agency_invoice.lbl_date',       to_jsonb('Invoice date'::text)),
  ('agency_invoice.lbl_pos',        to_jsonb('Place of supply'::text)),
  ('agency_invoice.lbl_sac',        to_jsonb('SAC'::text)),
  ('agency_invoice.lbl_drop',       to_jsonb('deliveries'::text)),
  ('agency_invoice.lbl_drops',      to_jsonb('Delivery charges'::text)),
  ('agency_invoice.lbl_bonus',      to_jsonb('Incentive bonus'::text)),
  ('agency_invoice.lbl_taxable',    to_jsonb('Taxable value'::text)),
  ('agency_invoice.lbl_igst',       to_jsonb('IGST'::text)),
  ('agency_invoice.lbl_cgst_sgst',  to_jsonb('CGST + SGST'::text)),
  ('agency_invoice.lbl_total',      to_jsonb('Invoice total'::text)),
  ('agency_invoice.lbl_signed',     to_jsonb('Signed copy'::text)),
  ('agency_invoice.no_gstin',       to_jsonb('Not registered'::text)),
  ('agency_invoice.upload_btn',     to_jsonb('Upload signed copy'::text)),
  ('agency_invoice.download_btn',   to_jsonb('Open invoice PDF'::text)),
  ('agency_invoice.doc_ready',      to_jsonb('Invoice ready.'::text)),
  ('agency_invoice.doc_building',   to_jsonb('Building the invoice…'::text)),
  ('agency_invoice.doc_failed',     to_jsonb('The invoice could not be built. Try again.'::text)),
  ('agency_invoice.err_not_found',  to_jsonb('That invoice no longer exists.'::text)),
  ('agency_invoice.err_no_period',  to_jsonb('That payout period no longer exists.'::text)),
  ('agency_invoice.recon_matched',  to_jsonb('Invoice matches the payout statement.'::text)),
  ('agency_invoice.recon_awaiting', to_jsonb('Matches the payout. Waiting for the agency''s signed copy.'::text)),
  ('agency_invoice.recon_mismatch', to_jsonb('Invoice {invoice} does not match the payout {payout} — off by {diff}.'::text)),
  ('agency_invoice.recon_signed_mismatch', to_jsonb('The signed copy says {signed}; this invoice says {ours} — off by {diff}.'::text)),
  ('agency_invoice.ledger_line',    to_jsonb('Delivery service — agency'::text))
on conflict (key) do nothing;
-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 4 — the training gate.
-- Same shape as the document block in _delivery_assign_core (#309): a state
-- function answers "may this rider be handed a stop", the assign core asks it,
-- and the refusal carries the BACKEND's own title and message.
-- The cut-off is config, exactly like handover_enforced_from: a gate switched
-- on today must not strand a rider who was approved and working last week.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.delivery_config
  add column if not exists training_enforced_from timestamptz;

update public.delivery_config
   set training_enforced_from = coalesce(training_enforced_from, now())
 where id = 1;

create or replace function public.delivery_training_state(p_partner_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  r public.delivery_partner_registrations%rowtype;
  v_from timestamptz; v_gated boolean; v_rows jsonb; v_pending int;
begin
  select * into r from public.delivery_partner_registrations where id = p_partner_id;
  if r.id is null then
    return jsonb_build_object('blocks_assignment', false, 'modules', '[]'::jsonb);
  end if;
  select training_enforced_from into v_from from public.delivery_config where id = 1;

  -- Approved before the gate existed, or overridden by an admin on the record:
  -- the modules still show, they simply do not block.
  v_gated := (v_from is not null
              and coalesce(r.reviewed_at, r.created_at, r.submitted_at) >= v_from
              and r.training_override_at is null);

  select coalesce(jsonb_agg(jsonb_build_object(
           'module_id', m.id,
           'slug',      m.slug,
           'title',     m.title,
           'required',  m.is_required,
           'pass_mark_label', m.pass_mark || '%',
           'passed',    coalesce(c.passed, false),
           'score_label', case when c.id is null then ''
                               else trim_scale(c.score_pct)::text || '%' end,
           'status_label', case when coalesce(c.passed,false)
                                then public._c('training.status_passed')
                                when c.id is not null then public._c('training.status_failed')
                                else public._c('training.status_todo') end,
           'tone', case when coalesce(c.passed,false) then 'success'
                        when c.id is not null then 'danger' else 'warning' end)
           order by m.sort_order, m.title), '[]'::jsonb),
         count(*) filter (where m.is_required and not coalesce(c.passed,false))
    into v_rows, v_pending
    from public.sop_modules m
    left join public.sop_completions c on c.module_id = m.id and c.partner_id = p_partner_id
   where m.active;

  return jsonb_build_object(
    'blocks_assignment', (v_gated and coalesce(v_pending,0) > 0),
    'pending_count',     coalesce(v_pending,0),
    'is_gated',          v_gated,
    'override_at',       r.training_override_at,
    'override_reason',   coalesce(r.training_override_reason,''),
    'block_title',   public._c('training.block_title'),
    'block_message', public._cf('training.block_message',
                       jsonb_build_object('n', coalesce(v_pending,0)::text,
                                          'name', coalesce(r.full_name,''))),
    'title',       public._c('training.title'),
    'empty_note',  public._c('training.empty'),
    'modules', v_rows);
end $$;

-- The assign core, with the training check sitting immediately after the
-- document check it is modelled on.
create or replace function public._delivery_assign_core(p_order_ids uuid[], p_partner_id uuid, p_actor text default 'engine'::text, p_wave_id uuid default null::uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r record; v_ok int := 0; v_blocked jsonb := '[]'::jsonb; v_elig jsonb;
  v_partner delivery_partner_registrations%rowtype; v_run uuid; v_did uuid;
  v_ozone smallint; v_docs jsonb; v_train jsonb;
begin
  select * into v_partner from delivery_partner_registrations
   where id = p_partner_id and is_active and coalesce(is_deleted,false)=false;
  if v_partner.id is null then
    return jsonb_build_object('ok',false,'error','partner_not_found',
      'message','That delivery partner is not active.');
  end if;

  -- CHANGE #309 (6): an expired licence, insurance or RC blocks assignment.
  v_docs := public.delivery_doc_state(p_partner_id);
  if coalesce((v_docs->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','docs_expired',
      'title',   v_docs->>'block_title',
      'message', v_docs->>'block_message',
      'docs',    v_docs->'docs');
  end if;

  -- CMD #407: an unfinished required SOP module blocks assignment the same way.
  v_train := public.delivery_training_state(p_partner_id);
  if coalesce((v_train->>'blocks_assignment')::boolean, false) then
    return jsonb_build_object('ok',false,'error','training_pending',
      'title',   v_train->>'block_title',
      'message', v_train->>'block_message',
      'modules', v_train->'modules');
  end if;

  select id into v_run from delivery_runs
   where partner_id = p_partner_id
     and run_date = (now() at time zone 'Asia/Kolkata')::date
     and status in ('planned','started')
   order by created_at desc limit 1;
  if v_run is null then
    insert into delivery_runs(partner_id, zone_id) values (p_partner_id, v_partner.zone_id)
    returning id into v_run;
  end if;

  for r in select unnest(p_order_ids) as oid loop
    select coalesce(o.zone_id, pp.zone_id) into v_ozone
    from orders o left join pharmacy_profiles pp on pp.id=o.customer_id where o.id = r.oid;

    -- a delivery may never cross a zone boundary
    if v_partner.zone_id is not null and v_ozone is not null
       and v_partner.zone_id <> v_ozone then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason','Different zone — this partner works another zone');
      continue;
    end if;

    v_elig := public.delivery_eligibility(r.oid);
    if coalesce((v_elig->>'can_assign')::boolean,false) is not true then
      v_blocked := v_blocked || jsonb_build_object('order_id', r.oid,
                     'reason', v_elig->>'blocked_label');
      continue;
    end if;

    insert into deliveries(order_id, run_id, partner_id, assigned_by, assigned_at,
                           accept_status, status, qr_token, lat, lng, zone_id, wave_id)
    select r.oid, v_run, p_partner_id, auth.uid(), now(), 'pending', 'assigned',
           encode(gen_random_bytes(9),'hex'), pp.latitude, pp.longitude, v_ozone,
           p_wave_id
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
    where o.id = r.oid
    on conflict (order_id) do update
      set run_id = excluded.run_id, partner_id = excluded.partner_id,
          assigned_by = excluded.assigned_by, assigned_at = now(),
          accept_status = 'pending', status = 'assigned',
          rejected_at = null, reject_reason = null,
          qr_token = coalesce(deliveries.qr_token, excluded.qr_token),
          lat = excluded.lat, lng = excluded.lng, zone_id = excluded.zone_id,
          wave_id = coalesce(excluded.wave_id, deliveries.wave_id)
    returning id into v_did;

    insert into delivery_events(delivery_id, order_id, partner_id, event, actor)
    values (v_did, r.oid, p_partner_id, 'assigned', p_actor);
    v_ok := v_ok + 1;
  end loop;

  update delivery_runs set total_stops =
    (select count(distinct coalesce(stop_group, 0)) from deliveries where run_id = v_run)
   where id = v_run;

  return jsonb_build_object('ok', true, 'assigned', v_ok, 'run_id', v_run,
    'delivery_id', v_did,
    'partner_name', coalesce(v_partner.full_name,''),
    'blocked', v_blocked,
    'title', 'Assigned ' || v_ok || case when v_ok = 1 then ' order' else ' orders' end);
end $$;

-- The override is a RECORD, not a switch: who, when and why, on the row and in
-- the audit log.
create or replace function public.admin_training_override(p_partner_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b public.delivery_partner_registrations%rowtype;
        a public.delivery_partner_registrations%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if btrim(coalesce(p_reason,'')) = '' then
    return jsonb_build_object('ok',false,'error','reason_required',
      'message', public._c('training.err_reason'));
  end if;
  select * into b from public.delivery_partner_registrations where id = p_partner_id;
  if b.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  update public.delivery_partner_registrations
     set training_override_at = now(), training_override_by = auth.uid(),
         training_override_reason = btrim(p_reason)
   where id = p_partner_id
  returning * into a;

  perform public.audit_write('training.override','delivery_partner', p_partner_id::text,
            to_jsonb(b), to_jsonb(a));

  return jsonb_build_object('ok',true,'message', public._c('training.override_done'),
    'state', public.delivery_training_state(p_partner_id));
end $$;

-- ── The rider's side ───────────────────────────────────────────────────────
create or replace function public.my_training()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare p public.delivery_partner_registrations%rowtype;
begin
  select * into p from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if p.id is null then
    return jsonb_build_object('has', false, 'modules','[]'::jsonb,
      'empty_note', public._c('training.not_a_rider'));
  end if;
  return public.delivery_training_state(p.id) || jsonb_build_object('has', true);
end $$;

create or replace function public.sop_module_open(p_module_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare m public.sop_modules%rowtype; v_q jsonb;
begin
  select * into m from public.sop_modules where id = p_module_id and active;
  if m.id is null then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public._c('training.err_no_module'));
  end if;
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','not_authorized'); end if;

  -- The correct answer NEVER leaves the database.
  select coalesce(jsonb_agg(jsonb_build_object(
           'question_id', q.id, 'prompt', q.prompt, 'options', q.options)
           order by q.sort_order, q.id), '[]'::jsonb)
    into v_q from public.sop_questions q where q.module_id = m.id and q.active;

  return jsonb_build_object('ok',true,
    'module_id', m.id, 'title', m.title, 'body', m.body,
    'media_path', coalesce(m.media_path,''),
    'pass_mark_label', m.pass_mark || '%',
    'quiz_heading', public._c('training.quiz_heading'),
    'submit_label', public._c('training.submit_btn'),
    'questions', v_q);
end $$;

create or replace function public.sop_quiz_submit(p_module_id uuid, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  p public.delivery_partner_registrations%rowtype; m public.sop_modules%rowtype;
  v_total int; v_right int; v_pct numeric; v_pass boolean;
begin
  select * into p from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false)=false limit 1;
  if p.id is null then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  select * into m from public.sop_modules where id = p_module_id and active;
  if m.id is null then
    return jsonb_build_object('ok',false,'error','not_found',
      'message', public._c('training.err_no_module'));
  end if;

  select count(*) into v_total from public.sop_questions where module_id = m.id and active;
  if v_total = 0 then
    return jsonb_build_object('ok',false,'error','no_questions',
      'message', public._c('training.err_no_questions'));
  end if;

  select count(*) into v_right
    from public.sop_questions q
    join lateral (select (a->>'choice')::int choice
                    from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a
                   where (a->>'question_id') = q.id::text limit 1) x on true
   where q.module_id = m.id and q.active and x.choice = q.correct_index;

  v_pct  := round(100.0 * coalesce(v_right,0) / v_total, 2);
  v_pass := v_pct >= m.pass_mark;

  insert into public.sop_completions(module_id, partner_id, attempts, score_pct,
                                     passed, passed_at, last_attempt_at)
  values (m.id, p.id, 1, v_pct, v_pass, case when v_pass then now() end, now())
  on conflict (module_id, partner_id) do update set
    attempts = public.sop_completions.attempts + 1,
    score_pct = excluded.score_pct,
    passed = public.sop_completions.passed or excluded.passed,
    passed_at = coalesce(public.sop_completions.passed_at, excluded.passed_at),
    last_attempt_at = now();

  return jsonb_build_object('ok',true,'passed',v_pass,
    'score_label', trim_scale(v_pct)::text || '%',
    'right_label', coalesce(v_right,0) || ' / ' || v_total,
    'message', case when v_pass then public._c('training.pass_message')
                    else public._cf('training.fail_message',
                           jsonb_build_object('mark', m.pass_mark::text)) end,
    'tone', case when v_pass then 'success' else 'danger' end,
    'state', public.delivery_training_state(p.id));
end $$;

-- ── Admin edits the modules; the quiz is data, never a Dart list ───────────
create or replace function public.sop_module_save(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_slug text; v_id uuid; cur public.sop_modules%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  v_id := nullif(p_patch->>'id','')::uuid;
  if v_id is not null then select * into cur from public.sop_modules where id = v_id; end if;
  v_slug := trim(both '_' from lower(regexp_replace(
              coalesce(nullif(p_patch->>'slug',''), cur.slug, p_patch->>'title',''),
              '[^a-zA-Z0-9]+','_','g')));
  if v_slug = '' or btrim(coalesce(p_patch->>'title', coalesce(cur.title,''))) = '' then
    return jsonb_build_object('ok',false,'error','title_required',
      'message', public._c('training.err_title'));
  end if;

  insert into public.sop_modules(id, slug, title, body, media_path, pass_mark,
                                 is_required, sort_order, active, updated_at, updated_by)
  values (coalesce(v_id, gen_random_uuid()), v_slug,
          coalesce(nullif(p_patch->>'title',''), cur.title),
          coalesce(p_patch->>'body', cur.body, ''),
          coalesce(nullif(p_patch->>'media_path',''), cur.media_path),
          coalesce(nullif(p_patch->>'pass_mark','')::int, cur.pass_mark, 70),
          coalesce((p_patch->>'is_required')::boolean, cur.is_required, true),
          coalesce(nullif(p_patch->>'sort_order','')::int, cur.sort_order, 100),
          coalesce((p_patch->>'active')::boolean, cur.active, true),
          now(), coalesce(auth.jwt() ->> 'email','admin'))
  on conflict (id) do update set
    slug = excluded.slug, title = excluded.title, body = excluded.body,
    media_path = excluded.media_path, pass_mark = excluded.pass_mark,
    is_required = excluded.is_required, sort_order = excluded.sort_order,
    active = excluded.active, updated_at = now(), updated_by = excluded.updated_by
  returning id into v_id;

  return jsonb_build_object('ok',true,'module_id',v_id,'message', public._c('training.saved'));
end $$;

create or replace function public.sop_question_save(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; cur public.sop_questions%rowtype; v_mod uuid;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  v_id := nullif(p_patch->>'id','')::uuid;
  if v_id is not null then select * into cur from public.sop_questions where id = v_id; end if;
  v_mod := coalesce(nullif(p_patch->>'module_id','')::uuid, cur.module_id);
  if v_mod is null or btrim(coalesce(p_patch->>'prompt', coalesce(cur.prompt,''))) = '' then
    return jsonb_build_object('ok',false,'error','prompt_required',
      'message', public._c('training.err_prompt'));
  end if;

  insert into public.sop_questions(id, module_id, prompt, options, correct_index, sort_order, active)
  values (coalesce(v_id, gen_random_uuid()), v_mod,
          coalesce(nullif(p_patch->>'prompt',''), cur.prompt),
          coalesce(p_patch->'options', cur.options, '[]'::jsonb),
          coalesce(nullif(p_patch->>'correct_index','')::int, cur.correct_index, 0),
          coalesce(nullif(p_patch->>'sort_order','')::int, cur.sort_order, 100),
          coalesce((p_patch->>'active')::boolean, cur.active, true))
  on conflict (id) do update set
    module_id = excluded.module_id, prompt = excluded.prompt, options = excluded.options,
    correct_index = excluded.correct_index, sort_order = excluded.sort_order,
    active = excluded.active
  returning id into v_id;

  return jsonb_build_object('ok',true,'question_id',v_id,'message', public._c('training.saved'));
end $$;

-- ── Copy ───────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('training.title',          to_jsonb('Training'::text)),
  ('training.empty',          to_jsonb('No training modules are published yet.'::text)),
  ('training.not_a_rider',    to_jsonb('This login is not a delivery account.'::text)),
  ('training.status_passed',  to_jsonb('Passed'::text)),
  ('training.status_failed',  to_jsonb('Retry'::text)),
  ('training.status_todo',    to_jsonb('Not started'::text)),
  ('training.block_title',    to_jsonb('Training not finished'::text)),
  ('training.block_message',  to_jsonb('{name} still has {n} required training module(s) to pass before stops can be assigned.'::text)),
  ('training.quiz_heading',   to_jsonb('Quiz'::text)),
  ('training.submit_btn',     to_jsonb('Submit answers'::text)),
  ('training.pass_message',   to_jsonb('Passed. You can be assigned stops.'::text)),
  ('training.fail_message',   to_jsonb('Not passed — you need {mark}% to clear this module. Read it again and retry.'::text)),
  ('training.saved',          to_jsonb('Saved.'::text)),
  ('training.override_done',  to_jsonb('Training requirement overridden and logged.'::text)),
  ('training.err_reason',     to_jsonb('Write why this rider is being let through.'::text)),
  ('training.err_no_module',  to_jsonb('That module is no longer published.'::text)),
  ('training.err_no_questions', to_jsonb('This module has no quiz yet.'::text)),
  ('training.err_title',      to_jsonb('A module needs a title.'::text)),
  ('training.err_prompt',     to_jsonb('A question needs a prompt.'::text))
on conflict (key) do nothing;
-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 5 — the vehicle ledger, and what it is FOR.
-- delivery_config.default_cost_per_drop is a configured guess. Once fuel and
-- maintenance are recorded against a vehicle, cost-per-drop can be measured:
-- rider earnings + bonus + running cost, over the drops actually made.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public._my_delivery_partner() returns uuid
language sql stable security definer set search_path to 'public' as $$
  select r.id from public.delivery_partner_registrations r
   where r.user_id = auth.uid() and coalesce(r.is_deleted,false) = false
   order by r.is_active desc, r.created_at limit 1;
$$;

create or replace function public.my_vehicles(p_limit int default 30)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_p uuid := public._my_delivery_partner(); v_v jsonb; v_e jsonb; v_k jsonb; v_sum numeric;
begin
  if v_p is null then
    return jsonb_build_object('has', false, 'empty_note', public._c('training.not_a_rider'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'vehicle_id', v.id, 'reg_number', v.reg_number,
           'type_label', v.vehicle_type, 'make_model', coalesce(v.make_model,''),
           'active', v.active) order by v.active desc, v.reg_number), '[]'::jsonb)
    into v_v from public.delivery_vehicles v where v.partner_id = v_p;

  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', k.slug, 'label', k.label,
           'needs_odometer', k.needs_odometer, 'needs_litres', k.needs_litres)
           order by k.sort_order), '[]'::jsonb)
    into v_k from public.delivery_expense_kinds k where k.active;

  select coalesce(jsonb_agg(x.row order by x.ord), '[]'::jsonb), coalesce(sum(x.amt),0)
    into v_e, v_sum
    from (select e.spend_date ord, e.amount amt,
                 jsonb_build_object(
                   'expense_id', e.id,
                   'kind_label', coalesce(k.label, e.kind),
                   'amount_label', public.inr_money(e.amount),
                   'date_label', to_char(e.spend_date,'DD Mon YYYY'),
                   'vehicle_label', coalesce(v.reg_number, ''),
                   'odometer_label', case when e.odometer_km is null then ''
                        else trim_scale(e.odometer_km)::text || ' km' end,
                   'litres_label', case when e.litres is null then ''
                        else trim_scale(e.litres)::text || ' L' end,
                   'has_receipt', (coalesce(e.receipt_path,'') <> ''),
                   'receipt_bucket', 'partner-receipts',
                   'receipt_path', coalesce(e.receipt_path,''),
                   'note', coalesce(e.note,'')) row
            from public.delivery_vehicle_expenses e
            left join public.delivery_expense_kinds k on k.slug = e.kind
            left join public.delivery_vehicles v on v.id = e.vehicle_id
           where e.partner_id = v_p
           order by e.spend_date desc, e.created_at desc
           limit greatest(coalesce(p_limit,30),1)) x;

  return jsonb_build_object('has', true,
    'title',            public._c('vehicle.title'),
    'vehicles_heading', public._c('vehicle.vehicles_heading'),
    'expenses_heading', public._c('vehicle.expenses_heading'),
    'add_vehicle_label',public._c('vehicle.add_vehicle'),
    'add_expense_label',public._c('vehicle.add_expense'),
    'empty_vehicles',   public._c('vehicle.empty_vehicles'),
    'empty_expenses',   public._c('vehicle.empty_expenses'),
    'total_label',      public._c('vehicle.total_label'),
    'total_value',      public.inr_money(coalesce(v_sum,0)),
    'kinds', v_k, 'vehicles', v_v, 'expenses', v_e);
end $$;

create or replace function public.vehicle_save(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_p uuid; v_id uuid; cur public.delivery_vehicles%rowtype; v_reg text;
begin
  v_p := coalesce(nullif(p_patch->>'partner_id','')::uuid, public._my_delivery_partner());
  if v_p is null then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  if v_p is distinct from public._my_delivery_partner()
     and public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_reg := upper(regexp_replace(coalesce(p_patch->>'reg_number',''), '\s+', '', 'g'));
  v_id  := nullif(p_patch->>'vehicle_id','')::uuid;
  if v_id is not null then select * into cur from public.delivery_vehicles where id = v_id; end if;
  if v_reg = '' then v_reg := coalesce(cur.reg_number,''); end if;
  if v_reg = '' then
    return jsonb_build_object('ok',false,'error','reg_required',
      'message', public._c('vehicle.err_reg'));
  end if;

  insert into public.delivery_vehicles(id, partner_id, reg_number, vehicle_type, make_model, active, updated_at)
  values (coalesce(v_id, gen_random_uuid()), v_p, v_reg,
          coalesce(nullif(p_patch->>'vehicle_type',''), cur.vehicle_type, ''),
          coalesce(nullif(p_patch->>'make_model',''), cur.make_model),
          coalesce((p_patch->>'active')::boolean, cur.active, true), now())
  on conflict (partner_id, reg_number) do update set
    vehicle_type = excluded.vehicle_type, make_model = excluded.make_model,
    active = excluded.active, updated_at = now()
  returning id into v_id;

  return jsonb_build_object('ok',true,'vehicle_id',v_id,'message', public._c('vehicle.saved'));
end $$;

create or replace function public.vehicle_receipt_path(p_ext text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_p uuid := public._my_delivery_partner(); v_ext text;
begin
  if v_p is null then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_ext := lower(regexp_replace(coalesce(nullif(p_ext,''),'jpg'), '[^a-z0-9]', '', 'g'));
  return jsonb_build_object('ok',true,'bucket','partner-receipts',
    'path','da' || v_p::text || '/expense/' || replace(gen_random_uuid()::text,'-','') || '.' || v_ext);
end $$;

create or replace function public.vehicle_expense_add(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_p uuid := public._my_delivery_partner(); v_kind text; v_amt numeric; v_id uuid;
  v_vehicle uuid;
begin
  if v_p is null then return jsonb_build_object('ok',false,'error','not_authorized'); end if;
  v_kind := coalesce(nullif(p_patch->>'kind',''),'');
  if not exists (select 1 from public.delivery_expense_kinds where slug = v_kind and active) then
    return jsonb_build_object('ok',false,'error','bad_kind',
      'message', public._c('vehicle.err_kind'));
  end if;
  v_amt := coalesce(nullif(p_patch->>'amount','')::numeric, 0);
  if v_amt <= 0 then
    return jsonb_build_object('ok',false,'error','bad_amount',
      'message', public._c('vehicle.err_amount'));
  end if;

  v_vehicle := nullif(p_patch->>'vehicle_id','')::uuid;
  if v_vehicle is not null and not exists (
       select 1 from public.delivery_vehicles where id = v_vehicle and partner_id = v_p) then
    return jsonb_build_object('ok',false,'error','bad_vehicle',
      'message', public._c('vehicle.err_vehicle'));
  end if;

  insert into public.delivery_vehicle_expenses(
      vehicle_id, partner_id, kind, amount, odometer_km, litres,
      spend_date, receipt_path, note, created_by)
  values (v_vehicle, v_p, v_kind, round(v_amt,2),
          nullif(p_patch->>'odometer_km','')::numeric,
          nullif(p_patch->>'litres','')::numeric,
          coalesce(nullif(p_patch->>'spend_date','')::date,
                   (now() at time zone 'Asia/Kolkata')::date),
          nullif(p_patch->>'receipt_path',''), nullif(p_patch->>'note',''), auth.uid())
  returning id into v_id;

  return jsonb_build_object('ok',true,'expense_id',v_id,
    'message', public._c('vehicle.expense_saved'), 'state', public.my_vehicles());
end $$;

-- ── Cost per drop, configured NEXT TO measured. ────────────────────────────
create or replace function public.admin_delivery_cost_report(
  p_from date default null, p_to date default null, p_zone smallint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_to date := coalesce(p_to, (now() at time zone 'Asia/Kolkata')::date);
  v_from date := coalesce(p_from, v_to - 29);
  v_rows jsonb; v_drops int; v_earn numeric; v_bonus numeric; v_exp numeric;
  v_cfg numeric; v_actual numeric;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  with d as (
    select dl.partner_id,
           count(*) drops,
           coalesce(sum(dl.earning),0) earn
      from public.deliveries dl
      join public.delivery_partner_registrations r on r.id = dl.partner_id
     where dl.status = 'delivered'
       and (dl.delivered_at at time zone 'Asia/Kolkata')::date between v_from and v_to
       and (p_zone is null or dl.zone_id = p_zone)
     group by dl.partner_id),
  b as (
    select e.partner_id, coalesce(sum(e.amount),0) bonus
      from public.incentive_earnings e
     where e.earn_date between v_from and v_to
     group by e.partner_id),
  x as (
    select ex.partner_id, coalesce(sum(ex.amount),0) spend
      from public.delivery_vehicle_expenses ex
     where ex.spend_date between v_from and v_to
     group by ex.partner_id)
  select coalesce(jsonb_agg(jsonb_build_object(
           'partner_id',   r.id,
           'partner_name', coalesce(r.full_name,''),
           'zone_label',   coalesce((select z.name from public.zones z where z.id = r.zone_id),''),
           'drops_label',  coalesce(d.drops,0)::text,
           'earn_label',   public.inr_money(coalesce(d.earn,0)),
           'bonus_label',  public.inr_money(coalesce(b.bonus,0)),
           'spend_label',  public.inr_money(coalesce(x.spend,0)),
           'configured_label', public.inr_money(
               coalesce((public._dcfg(r.zone_id)->>'cost_per_drop')::numeric, 0)),
           'actual_label', case when coalesce(d.drops,0) = 0
                                then public._c('cost_report.no_drops')
                                else public.inr_money(round(
                                  (coalesce(d.earn,0) + coalesce(b.bonus,0) + coalesce(x.spend,0))
                                  / d.drops, 2)) end,
           'variance_label', case when coalesce(d.drops,0) = 0 then ''
                else public.inr_money(round(
                  (coalesce(d.earn,0) + coalesce(b.bonus,0) + coalesce(x.spend,0)) / d.drops
                  - coalesce((public._dcfg(r.zone_id)->>'cost_per_drop')::numeric, 0), 2)) end,
           'tone', case when coalesce(d.drops,0) = 0 then 'muted'
                        when (coalesce(d.earn,0) + coalesce(b.bonus,0) + coalesce(x.spend,0)) / d.drops
                             > coalesce((public._dcfg(r.zone_id)->>'cost_per_drop')::numeric, 0)
                        then 'danger' else 'success' end)
           order by coalesce(d.drops,0) desc, r.full_name), '[]'::jsonb)
    into v_rows
    from public.delivery_partner_registrations r
    left join d on d.partner_id = r.id
    left join b on b.partner_id = r.id
    left join x on x.partner_id = r.id
   where coalesce(r.is_deleted,false) = false
     and (p_zone is null or r.zone_id = p_zone)
     and (coalesce(d.drops,0) > 0 or coalesce(x.spend,0) > 0 or coalesce(b.bonus,0) > 0);

  select count(*), coalesce(sum(earning),0) into v_drops, v_earn
    from public.deliveries
   where status = 'delivered'
     and (delivered_at at time zone 'Asia/Kolkata')::date between v_from and v_to
     and (p_zone is null or zone_id = p_zone);
  select coalesce(sum(amount),0) into v_bonus from public.incentive_earnings
   where earn_date between v_from and v_to;
  select coalesce(sum(amount),0) into v_exp from public.delivery_vehicle_expenses
   where spend_date between v_from and v_to;

  v_cfg    := coalesce((public._dcfg(p_zone)->>'cost_per_drop')::numeric, 0);
  v_actual := case when coalesce(v_drops,0) = 0 then null
                   else round((v_earn + v_bonus + v_exp) / v_drops, 2) end;

  return jsonb_build_object('ok', true,
    'title', public._c('cost_report.title'),
    'range_label', to_char(v_from,'DD Mon') || ' – ' || to_char(v_to,'DD Mon YYYY'),
    'from', v_from, 'to', v_to,
    'summary', jsonb_build_array(
      jsonb_build_object('label', public._c('cost_report.drops'),      'value', coalesce(v_drops,0)::text),
      jsonb_build_object('label', public._c('cost_report.earnings'),   'value', public.inr_money(v_earn)),
      jsonb_build_object('label', public._c('cost_report.bonus'),      'value', public.inr_money(v_bonus)),
      jsonb_build_object('label', public._c('cost_report.running'),    'value', public.inr_money(v_exp)),
      jsonb_build_object('label', public._c('cost_report.configured'), 'value', public.inr_money(v_cfg)),
      jsonb_build_object('label', public._c('cost_report.actual'),
        'value', case when v_actual is null then public._c('cost_report.no_drops')
                      else public.inr_money(v_actual) end, 'bold', true)),
    'columns', jsonb_build_array(
      public._c('cost_report.col_partner'), public._c('cost_report.col_drops'),
      public._c('cost_report.col_earn'),    public._c('cost_report.col_bonus'),
      public._c('cost_report.col_spend'),   public._c('cost_report.col_configured'),
      public._c('cost_report.col_actual')),
    'empty_note', public._c('cost_report.empty'),
    'rows', v_rows);
end $$;

insert into public.ui_copy(key, value) values
  ('vehicle.title',            to_jsonb('Vehicle & running cost'::text)),
  ('vehicle.vehicles_heading', to_jsonb('My vehicles'::text)),
  ('vehicle.expenses_heading', to_jsonb('Recent expenses'::text)),
  ('vehicle.add_vehicle',      to_jsonb('Add vehicle'::text)),
  ('vehicle.add_expense',      to_jsonb('Add expense'::text)),
  ('vehicle.empty_vehicles',   to_jsonb('No vehicle recorded yet. Add the number and type you ride.'::text)),
  ('vehicle.empty_expenses',   to_jsonb('No fuel or maintenance recorded yet.'::text)),
  ('vehicle.total_label',      to_jsonb('Recorded so far'::text)),
  ('vehicle.saved',            to_jsonb('Vehicle saved.'::text)),
  ('vehicle.expense_saved',    to_jsonb('Expense recorded.'::text)),
  ('vehicle.err_reg',          to_jsonb('Enter the vehicle number.'::text)),
  ('vehicle.err_kind',         to_jsonb('Pick what the expense was for.'::text)),
  ('vehicle.err_amount',       to_jsonb('Enter an amount greater than zero.'::text)),
  ('vehicle.err_vehicle',      to_jsonb('That vehicle is not yours.'::text)),
  ('cost_report.title',        to_jsonb('Cost per drop — configured vs actual'::text)),
  ('cost_report.drops',        to_jsonb('Deliveries'::text)),
  ('cost_report.earnings',     to_jsonb('Rider earnings'::text)),
  ('cost_report.bonus',        to_jsonb('Incentive bonus'::text)),
  ('cost_report.running',      to_jsonb('Fuel & maintenance'::text)),
  ('cost_report.configured',   to_jsonb('Configured per drop'::text)),
  ('cost_report.actual',       to_jsonb('Actual per drop'::text)),
  ('cost_report.no_drops',     to_jsonb('No deliveries'::text)),
  ('cost_report.col_partner',  to_jsonb('Partner'::text)),
  ('cost_report.col_drops',    to_jsonb('Drops'::text)),
  ('cost_report.col_earn',     to_jsonb('Earnings'::text)),
  ('cost_report.col_bonus',    to_jsonb('Bonus'::text)),
  ('cost_report.col_spend',    to_jsonb('Running'::text)),
  ('cost_report.col_configured', to_jsonb('Configured'::text)),
  ('cost_report.col_actual',   to_jsonb('Actual'::text)),
  ('cost_report.empty',        to_jsonb('No deliveries or expenses in this range.'::text))
on conflict (key) do nothing;
-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 6 — ONE admin screen, four tabs, and the tab list is the
-- BACKEND's (supplier_records_home's shape): a tab this build has never heard
-- of renders an empty body instead of throwing.
-- ═══════════════════════════════════════════════════════════════════════════

-- A template an admin edits and switches on. It ships INACTIVE on purpose:
-- an incentive is a payable, and nothing here may start paying without an
-- admin turning it on.
insert into public.incentive_schemes(slug, label, scope, metric, threshold, bonus_amount, active, sort_order, note)
select 'daily_12_drops', 'Daily target — 12 deliveries', 'all', 'drops_per_day', 12, 100, false, 10,
       'Template. Set the target and the bonus, then switch it on.'
where not exists (select 1 from public.incentive_schemes where slug = 'daily_12_drops');

-- The starter SOP, so the gate has something to gate on.
do $$
declare v_m uuid;
begin
  insert into public.sop_modules(slug, title, body, pass_mark, is_required, sort_order)
  select 'delivery_basics', 'Delivery basics — proof, cold chain and cash',
$b$Every stop ends with proof. Take the OTP the customer reads out, or a photo of the handover, or a signature — one of the three, before you mark the stop delivered.

Cold-chain orders travel in the cold bag and are photographed at handover. If the bag is warm or the seal is broken, do not hand it over — mark the stop failed with the reason and call the desk.

Never accept cash that is not on the stop card. If the customer wants to pay differently, mark it and let the desk settle it. Money you take off-app is money nobody can trace back to the order.

If a pharmacy is shut, do not leave medicines with a neighbour. Mark the attempt, pick the reschedule window the app offers, and move to the next stop.$b$,
         70, true, 10
  where not exists (select 1 from public.sop_modules where slug = 'delivery_basics');

  select id into v_m from public.sop_modules where slug = 'delivery_basics';

  insert into public.sop_questions(module_id, prompt, options, correct_index, sort_order)
  select v_m, 'A customer cannot find the OTP. What ends the stop?',
         '["Mark it delivered anyway","A handover photo or a signature","Ask a neighbour to confirm","Leave the parcel at the door"]'::jsonb,
         1, 10
  where not exists (select 1 from public.sop_questions where module_id = v_m and sort_order = 10);

  insert into public.sop_questions(module_id, prompt, options, correct_index, sort_order)
  select v_m, 'The cold bag is warm when you reach the pharmacy. You:',
         '["Hand it over and mention it","Fail the stop with the reason and call the desk","Put it back and try tomorrow without telling anyone","Buy ice and continue"]'::jsonb,
         1, 20
  where not exists (select 1 from public.sop_questions where module_id = v_m and sort_order = 20);

  insert into public.sop_questions(module_id, prompt, options, correct_index, sort_order)
  select v_m, 'A pharmacy offers cash that the stop card does not ask for. You:',
         '["Take it and hand it in later","Take it and adjust it yourself","Refuse it and let the desk settle it","Take it only if it is the exact amount"]'::jsonb,
         2, 30
  where not exists (select 1 from public.sop_questions where module_id = v_m and sort_order = 30);
end $$;

-- ── Admin: incentives ──────────────────────────────────────────────────────
create or replace function public.admin_incentive_schemes()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb; v_metrics jsonb; v_zones jsonb; v_agencies jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', m.slug, 'label', m.label, 'value_suffix', m.value_suffix,
           'target_hint', m.target_hint) order by m.sort_order), '[]'::jsonb)
    into v_metrics from public.incentive_metrics m where m.active;

  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'label', z.name) order by z.id), '[]'::jsonb)
    into v_zones from public.zones z;

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'label', coalesce(r.full_name,''))
           order by r.full_name), '[]'::jsonb)
    into v_agencies from public.delivery_partner_registrations r
   where r.partner_type = 'agency' and coalesce(r.is_deleted,false) = false;

  select coalesce(jsonb_agg(jsonb_build_object(
           'scheme_id', s.id, 'slug', s.slug, 'label', s.label,
           'scope', s.scope,
           'scope_label', case s.scope
             when 'zone'   then public._cf('incentive.scope_zone',
                                  jsonb_build_object('zone', coalesce((select z.name from public.zones z where z.id = s.zone_id),'')))
             when 'agency' then public._cf('incentive.scope_agency',
                                  jsonb_build_object('agency', coalesce((select r2.full_name from public.delivery_partner_registrations r2 where r2.id = s.agency_id),'')))
             else public._c('incentive.scope_all') end,
           'zone_id', s.zone_id, 'agency_id', s.agency_id,
           'metric', s.metric,
           'metric_label', coalesce((select m.label from public.incentive_metrics m where m.slug = s.metric), s.metric),
           'target_label', trim_scale(s.threshold)::text
                           || coalesce((select m.value_suffix from public.incentive_metrics m where m.slug = s.metric),''),
           'threshold', s.threshold,
           'bonus', s.bonus_amount,
           'bonus_label', public.inr_money(s.bonus_amount),
           'window_label', case when s.window_start is null and s.window_end is null
                                then public._c('incentive.window_always')
                                else coalesce(to_char(s.window_start,'DD Mon YYYY'), '…')
                                     || ' – ' || coalesce(to_char(s.window_end,'DD Mon YYYY'), '…') end,
           'window_start', s.window_start, 'window_end', s.window_end,
           'active', s.active,
           'status_label', case when s.active then public._c('incentive.on') else public._c('incentive.off') end,
           'tone', case when s.active then 'success' else 'muted' end,
           'paid_label', public.inr_money(coalesce((select sum(e.amount) from public.incentive_earnings e where e.scheme_id = s.id),0)),
           'note', coalesce(s.note,''))
           order by s.sort_order, s.label), '[]'::jsonb)
    into v_rows from public.incentive_schemes s;

  return jsonb_build_object('ok',true,
    'title', public._c('incentive.admin_title'),
    'empty_note', public._c('incentive.admin_empty'),
    'add_label', public._c('incentive.add_btn'),
    'save_label', public._c('incentive.save_btn'),
    'run_label', public._c('incentive.run_btn'),
    'scope_options', jsonb_build_array(
      jsonb_build_object('slug','all',   'label', public._c('incentive.scope_all')),
      jsonb_build_object('slug','zone',  'label', public._c('incentive.scope_zone_opt')),
      jsonb_build_object('slug','agency','label', public._c('incentive.scope_agency_opt'))),
    'metrics', v_metrics, 'zones', v_zones, 'agencies', v_agencies, 'rows', v_rows);
end $$;

create or replace function public.incentive_scheme_save(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; cur public.incentive_schemes%rowtype; v_slug text; v_scope text; v_metric text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  v_id := nullif(p_patch->>'scheme_id','')::uuid;
  if v_id is not null then select * into cur from public.incentive_schemes where id = v_id; end if;

  v_slug := trim(both '_' from lower(regexp_replace(
              coalesce(nullif(p_patch->>'slug',''), cur.slug, p_patch->>'label',''),
              '[^a-zA-Z0-9]+','_','g')));
  if v_slug = '' or btrim(coalesce(p_patch->>'label', coalesce(cur.label,''))) = '' then
    return jsonb_build_object('ok',false,'error','label_required',
      'message', public._c('incentive.err_label'));
  end if;
  v_scope  := coalesce(nullif(p_patch->>'scope',''), cur.scope, 'all');
  if v_scope not in ('all','zone','agency') then
    return jsonb_build_object('ok',false,'error','bad_scope',
      'message', public._c('incentive.err_scope'));
  end if;
  v_metric := coalesce(nullif(p_patch->>'metric',''), cur.metric, '');
  if not exists (select 1 from public.incentive_metrics where slug = v_metric and active) then
    return jsonb_build_object('ok',false,'error','bad_metric',
      'message', public._c('incentive.err_metric'));
  end if;

  insert into public.incentive_schemes(id, slug, label, scope, zone_id, agency_id, metric,
      threshold, bonus_amount, window_start, window_end, active, sort_order, note,
      updated_at, updated_by)
  values (coalesce(v_id, gen_random_uuid()), v_slug,
      coalesce(nullif(p_patch->>'label',''), cur.label), v_scope,
      case when v_scope = 'zone'   then nullif(p_patch->>'zone_id','')::smallint end,
      case when v_scope = 'agency' then nullif(p_patch->>'agency_id','')::uuid end,
      v_metric,
      coalesce(nullif(p_patch->>'threshold','')::numeric, cur.threshold, 0),
      coalesce(nullif(p_patch->>'bonus_amount','')::numeric, cur.bonus_amount, 0),
      coalesce(nullif(p_patch->>'window_start','')::date, cur.window_start),
      coalesce(nullif(p_patch->>'window_end','')::date, cur.window_end),
      coalesce((p_patch->>'active')::boolean, cur.active, false),
      coalesce(nullif(p_patch->>'sort_order','')::int, cur.sort_order, 100),
      coalesce(p_patch->>'note', cur.note),
      now(), coalesce(auth.jwt() ->> 'email','admin'))
  on conflict (id) do update set
    slug = excluded.slug, label = excluded.label, scope = excluded.scope,
    zone_id = excluded.zone_id, agency_id = excluded.agency_id, metric = excluded.metric,
    threshold = excluded.threshold, bonus_amount = excluded.bonus_amount,
    window_start = excluded.window_start, window_end = excluded.window_end,
    active = excluded.active, sort_order = excluded.sort_order, note = excluded.note,
    updated_at = now(), updated_by = excluded.updated_by
  returning id into v_id;

  return jsonb_build_object('ok',true,'scheme_id',v_id,'message', public._c('incentive.saved'));
end $$;

-- ── Admin: agency invoices ─────────────────────────────────────────────────
create or replace function public.admin_agency_invoices(p_limit int default 40)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce(jsonb_agg(x.row order by x.ord desc), '[]'::jsonb) into v_rows
  from (
    select p.period_end ord, jsonb_build_object(
      'period_id',    p.id,
      'invoice_id',   i.id,
      'has_invoice',  (i.id is not null),
      'partner_name', coalesce(r.full_name,''),
      'partner_type', coalesce(r.partner_type,''),
      'period_label', to_char(p.period_start,'DD Mon') || ' – ' || to_char(p.period_end,'DD Mon YYYY'),
      'payout_label', public.inr_money(p.net_amount),
      'payout_status_label', case when p.status = 'paid'
                                  then public._c('admin.delivery.payout_paid_chip')
                                  else public._c('admin.delivery.payout_unpaid_chip') end,
      'invoice_no',   coalesce(i.invoice_no,''),
      'invoice_total_label', case when i.id is null then '' else public.inr_money(i.total) end,
      'gstin_label',  coalesce(nullif(i.agency_gstin,''), coalesce(nullif(r.gstin,''), public._c('agency_invoice.no_gstin'))),
      'recon_label',  coalesce(i.recon_note, public._c('agency_invoice.recon_none')),
      'recon_tone',   case coalesce(i.recon_status,'none')
                        when 'matched' then 'success'
                        when 'mismatch' then 'danger'
                        when 'awaiting_signed' then 'warning' else 'muted' end,
      'has_signed',   (coalesce(i.signed_path,'') <> ''),
      'generate_label', case when i.id is null then public._c('agency_invoice.generate_btn')
                             else public._c('agency_invoice.regenerate_btn') end) row
    from public.delivery_payout_periods p
    join public.delivery_partner_registrations r on r.id = p.partner_id
    left join public.agency_invoices i on i.period_id = p.id
    order by p.period_end desc
    limit greatest(coalesce(p_limit,40),1)) x;

  return jsonb_build_object('ok',true,
    'title', public._c('agency_invoice.admin_title'),
    'empty_note', public._c('agency_invoice.admin_empty'),
    'rows', v_rows);
end $$;

-- ── Admin: training modules ────────────────────────────────────────────────
create or replace function public.admin_sop_modules()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'module_id', m.id, 'slug', m.slug, 'title', m.title, 'body', m.body,
      'pass_mark', m.pass_mark, 'pass_mark_label', m.pass_mark || '%',
      'is_required', m.is_required,
      'required_label', case when m.is_required then public._c('training.required')
                             else public._c('training.optional') end,
      'active', m.active,
      'status_label', case when m.active then public._c('incentive.on') else public._c('incentive.off') end,
      'tone', case when m.active then 'success' else 'muted' end,
      'question_count_label', (select count(*) from public.sop_questions q where q.module_id = m.id and q.active)
                              || ' ' || public._c('training.questions_word'),
      'passed_label', (select count(*) from public.sop_completions c where c.module_id = m.id and c.passed)
                              || ' ' || public._c('training.riders_word'),
      'questions', (select coalesce(jsonb_agg(jsonb_build_object(
            'question_id', q.id, 'prompt', q.prompt, 'options', q.options,
            'correct_index', q.correct_index, 'active', q.active)
            order by q.sort_order), '[]'::jsonb)
          from public.sop_questions q where q.module_id = m.id))
      order by m.sort_order, m.title), '[]'::jsonb)
    into v_rows from public.sop_modules m;

  return jsonb_build_object('ok',true,
    'title', public._c('training.admin_title'),
    'empty_note', public._c('training.admin_empty'),
    'add_label', public._c('training.add_btn'),
    'save_label', public._c('incentive.save_btn'),
    'rows', v_rows);
end $$;

-- ── The one screen RPC. The TAB LIST is the backend's. ─────────────────────
create or replace function public.admin_delivery_extras(
  p_tab text default null, p_args jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_tabs jsonb; v_tab text; v_body jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized',
      'message', public._c('extras.not_authorized'));
  end if;

  v_tabs := jsonb_build_array(
    jsonb_build_object('tab_key','incentives', 'label', public._c('extras.tab_incentives')),
    jsonb_build_object('tab_key','invoices',   'label', public._c('extras.tab_invoices')),
    jsonb_build_object('tab_key','training',   'label', public._c('extras.tab_training')),
    jsonb_build_object('tab_key','cost',       'label', public._c('extras.tab_cost')));

  v_tab := coalesce(nullif(p_tab,''), v_tabs->0->>'tab_key');

  if    v_tab = 'incentives' then v_body := public.admin_incentive_schemes();
  elsif v_tab = 'invoices'   then v_body := public.admin_agency_invoices();
  elsif v_tab = 'training'   then v_body := public.admin_sop_modules();
  elsif v_tab = 'cost'       then v_body := public.admin_delivery_cost_report(
          nullif(p_args->>'from','')::date, nullif(p_args->>'to','')::date,
          nullif(p_args->>'zone','')::smallint);
  else  v_body := null;   -- a tab this build has never heard of renders nothing
  end if;

  return jsonb_build_object('ok',true,
    'title', public._c('extras.title'),
    'tabs', v_tabs, 'tab_key', v_tab, 'body', v_body);
end $$;

insert into public.ui_copy(key, value) values
  ('extras.title',            to_jsonb('Delivery programme'::text)),
  ('extras.tab_incentives',   to_jsonb('Incentives'::text)),
  ('extras.tab_invoices',     to_jsonb('Agency invoices'::text)),
  ('extras.tab_training',     to_jsonb('Training'::text)),
  ('extras.tab_cost',         to_jsonb('Cost per drop'::text)),
  ('extras.not_authorized',   to_jsonb('This screen is for admins.'::text)),
  ('incentive.admin_title',   to_jsonb('Incentive schemes'::text)),
  ('incentive.admin_empty',   to_jsonb('No incentive scheme yet. Add one and switch it on.'::text)),
  ('incentive.add_btn',       to_jsonb('New scheme'::text)),
  ('incentive.save_btn',      to_jsonb('Save'::text)),
  ('incentive.run_btn',       to_jsonb('Score today'::text)),
  ('incentive.on',            to_jsonb('On'::text)),
  ('incentive.off',           to_jsonb('Off'::text)),
  ('incentive.scope_all',     to_jsonb('All riders'::text)),
  ('incentive.scope_zone_opt',to_jsonb('One zone'::text)),
  ('incentive.scope_agency_opt', to_jsonb('One agency'::text)),
  ('incentive.scope_zone',    to_jsonb('Zone: {zone}'::text)),
  ('incentive.scope_agency',  to_jsonb('Agency: {agency}'::text)),
  ('incentive.window_always', to_jsonb('Always on'::text)),
  ('incentive.saved',         to_jsonb('Scheme saved.'::text)),
  ('incentive.err_label',     to_jsonb('A scheme needs a name.'::text)),
  ('incentive.err_scope',     to_jsonb('Pick who the scheme covers.'::text)),
  ('incentive.err_metric',    to_jsonb('Pick what the scheme measures.'::text)),
  ('agency_invoice.admin_title', to_jsonb('Agency invoices'::text)),
  ('agency_invoice.admin_empty', to_jsonb('No payout period has been opened yet.'::text)),
  ('agency_invoice.recon_none',  to_jsonb('No invoice raised for this period yet.'::text)),
  ('agency_invoice.generate_btn',to_jsonb('Generate invoice'::text)),
  ('agency_invoice.regenerate_btn', to_jsonb('Rebuild invoice'::text)),
  ('training.admin_title',    to_jsonb('Training modules'::text)),
  ('training.admin_empty',    to_jsonb('No module yet. Add one so new riders have something to pass.'::text)),
  ('training.add_btn',        to_jsonb('New module'::text)),
  ('training.required',       to_jsonb('Required'::text)),
  ('training.optional',       to_jsonb('Optional'::text)),
  ('training.questions_word', to_jsonb('questions'::text)),
  ('training.riders_word',    to_jsonb('riders passed'::text))
on conflict (key) do nothing;
-- ── PART 7 — grants. Nothing added by this command is reachable anonymously;
-- every one of these RPCs already checks the caller, this just makes anon a
-- 404 instead of a refusal (CHANGE #404/#405 hygiene).
do $$
declare f text;
begin
  for f in
    select p.oid::regprocedure::text
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'incentive_evaluate_day','incentive_schemes_for','_incentive_metric_value',
         'my_incentive_progress','admin_incentive_schemes','incentive_scheme_save',
         'agency_invoice_generate','agency_invoice_reconcile','agency_invoice_get',
         '_agency_invoice_doc_payload','agency_invoice_doc_request','agency_invoice_doc_status',
         'agency_invoice_signed_path','agency_invoice_signed_record',
         'gst_ledger_build_agency_invoices','admin_agency_invoices',
         'delivery_training_state','admin_training_override','my_training',
         'sop_module_open','sop_quiz_submit','sop_module_save','sop_question_save',
         'admin_sop_modules','_my_delivery_partner','my_vehicles','vehicle_save',
         'vehicle_receipt_path','vehicle_expense_add','admin_delivery_cost_report',
         'admin_delivery_extras')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
-- ── PART 8 — the ledger's own source list learns the fourth source.
-- CHANGE #320 fixed three; the agency invoice is a real input-credit document
-- and belongs in the same enum rather than in a parallel table.
alter table public.gst_ledger drop constraint if exists gst_ledger_source_check;
alter table public.gst_ledger add constraint gst_ledger_source_check
  check (source = any (array['supplier_bill','customer_bill','credit_note','agency_invoice']));
-- ── PART 9 — the two labels the admin screen needs and the backend had not
-- yet supplied. A button caption is never a Dart literal, not even a toggle.
create or replace function public.admin_incentive_schemes()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb; v_metrics jsonb; v_zones jsonb; v_agencies jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', m.slug, 'label', m.label, 'value_suffix', m.value_suffix,
           'target_hint', m.target_hint) order by m.sort_order), '[]'::jsonb)
    into v_metrics from public.incentive_metrics m where m.active;

  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'label', z.name) order by z.id), '[]'::jsonb)
    into v_zones from public.zones z;

  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'label', coalesce(r.full_name,''))
           order by r.full_name), '[]'::jsonb)
    into v_agencies from public.delivery_partner_registrations r
   where r.partner_type = 'agency' and coalesce(r.is_deleted,false) = false;

  select coalesce(jsonb_agg(jsonb_build_object(
           'scheme_id', s.id, 'slug', s.slug, 'label', s.label,
           'scope', s.scope,
           'scope_label', case s.scope
             when 'zone'   then public._cf('incentive.scope_zone',
                                  jsonb_build_object('zone', coalesce((select z.name from public.zones z where z.id = s.zone_id),'')))
             when 'agency' then public._cf('incentive.scope_agency',
                                  jsonb_build_object('agency', coalesce((select r2.full_name from public.delivery_partner_registrations r2 where r2.id = s.agency_id),'')))
             else public._c('incentive.scope_all') end,
           'zone_id', s.zone_id, 'agency_id', s.agency_id,
           'metric', s.metric,
           'metric_label', coalesce((select m.label from public.incentive_metrics m where m.slug = s.metric), s.metric),
           'target_label', trim_scale(s.threshold)::text
                           || coalesce((select m.value_suffix from public.incentive_metrics m where m.slug = s.metric),''),
           'threshold', s.threshold,
           'bonus', s.bonus_amount,
           'bonus_label', public.inr_money(s.bonus_amount),
           'window_label', case when s.window_start is null and s.window_end is null
                                then public._c('incentive.window_always')
                                else coalesce(to_char(s.window_start,'DD Mon YYYY'), '…')
                                     || ' – ' || coalesce(to_char(s.window_end,'DD Mon YYYY'), '…') end,
           'window_start', s.window_start, 'window_end', s.window_end,
           'active', s.active,
           'status_label', case when s.active then public._c('incentive.on') else public._c('incentive.off') end,
           'tone', case when s.active then 'success' else 'muted' end,
           'toggle_label', case when s.active then public._c('incentive.turn_off')
                                else public._c('incentive.turn_on') end,
           'toggle_tone',  case when s.active then 'muted' else 'success' end,
           'paid_label', public.inr_money(coalesce((select sum(e.amount) from public.incentive_earnings e where e.scheme_id = s.id),0)),
           'note', coalesce(s.note,''))
           order by s.sort_order, s.label), '[]'::jsonb)
    into v_rows from public.incentive_schemes s;

  return jsonb_build_object('ok',true,
    'title', public._c('incentive.admin_title'),
    'empty_note', public._c('incentive.admin_empty'),
    'add_label', public._c('incentive.add_btn'),
    'save_label', public._c('incentive.save_btn'),
    'run_label', public._c('incentive.run_btn'),
    'scope_options', jsonb_build_array(
      jsonb_build_object('slug','all',   'label', public._c('incentive.scope_all')),
      jsonb_build_object('slug','zone',  'label', public._c('incentive.scope_zone_opt')),
      jsonb_build_object('slug','agency','label', public._c('incentive.scope_agency_opt'))),
    'metrics', v_metrics, 'zones', v_zones, 'agencies', v_agencies, 'rows', v_rows);
end $$;

create or replace function public.admin_agency_invoices(p_limit int default 40)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  select coalesce(jsonb_agg(x.row order by x.ord desc), '[]'::jsonb) into v_rows
  from (
    select p.period_end ord, jsonb_build_object(
      'period_id',    p.id,
      'invoice_id',   i.id,
      'has_invoice',  (i.id is not null),
      'partner_name', coalesce(r.full_name,''),
      'partner_type', coalesce(r.partner_type,''),
      'period_label', to_char(p.period_start,'DD Mon') || ' – ' || to_char(p.period_end,'DD Mon YYYY'),
      'payout_label', public.inr_money(p.net_amount),
      'payout_status_label', case when p.status = 'paid'
                                  then public._c('admin.delivery.payout_paid_chip')
                                  else public._c('admin.delivery.payout_unpaid_chip') end,
      'invoice_no',   coalesce(i.invoice_no,''),
      'invoice_total_label', case when i.id is null then '' else public.inr_money(i.total) end,
      'gstin_label',  coalesce(nullif(i.agency_gstin,''), coalesce(nullif(r.gstin,''), public._c('agency_invoice.no_gstin'))),
      'recon_label',  coalesce(i.recon_note, public._c('agency_invoice.recon_none')),
      'recon_tone',   case coalesce(i.recon_status,'none')
                        when 'matched' then 'success'
                        when 'mismatch' then 'danger'
                        when 'awaiting_signed' then 'warning' else 'muted' end,
      'has_signed',   (coalesce(i.signed_path,'') <> ''),
      'generate_label', case when i.id is null then public._c('agency_invoice.generate_btn')
                             else public._c('agency_invoice.regenerate_btn') end) row
    from public.delivery_payout_periods p
    join public.delivery_partner_registrations r on r.id = p.partner_id
    left join public.agency_invoices i on i.period_id = p.id
    order by p.period_end desc
    limit greatest(coalesce(p_limit,40),1)) x;

  return jsonb_build_object('ok',true,
    'title', public._c('agency_invoice.admin_title'),
    'empty_note', public._c('agency_invoice.admin_empty'),
    'open_label', public._c('agency_invoice.download_btn'),
    'rows', v_rows);
end $$;

insert into public.ui_copy(key, value) values
  ('incentive.turn_on',  to_jsonb('Switch on'::text)),
  ('incentive.turn_off', to_jsonb('Switch off'::text))
on conflict (key) do nothing;

do $$
declare f text;
begin
  for f in select p.oid::regprocedure::text from pg_proc p
             join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public' and p.proname in ('admin_incentive_schemes','admin_agency_invoices')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 10 — reachability. A feature Om cannot tap does not exist.
-- The tile, the category, the search terms and the deep link are all DATA:
-- feature_registry is the only list, and nav_registry() renders it.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.feature_registry(
    feature_key, label, group_label, icon_key, route_key, sort_order, owner,
    partner_eligible, default_access, is_active, category, surface,
    roles_allowed, deep_link, search_terms, description)
select 'admin.delivery_extras', 'Delivery programme', 'Delivery',
       'trending_up', 'delivery_extras', 830, 'medibo',
       false, 'none', true, 'delivery', 'dashboard',
       array['admin','super_admin'], '/admin/go/delivery_extras',
       'incentive bonus target rider agency invoice gst training sop quiz vehicle fuel cost per drop',
       'Rider incentive schemes, agency GST invoices, the training gate and measured cost per drop.'
where not exists (select 1 from public.feature_registry where feature_key = 'admin.delivery_extras');

-- ── The rider's home carries the programme, so the panel renders and asks
-- nothing extra. Same payload, three new keys.
create or replace function public.my_delivery_home(p_date date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  p delivery_partner_registrations%rowtype; v_date date; v_rate numeric;
  v_del int; v_fail int; v_pend int; v_km numeric; v_on boolean; v_since timestamptz;
  v_earn numeric; v_train jsonb;
begin
  select * into p from delivery_partner_registrations
   where user_id = auth.uid() and is_active and coalesce(is_deleted,false)=false limit 1;
  if p.id is null then
    return jsonb_build_object('allowed',false,'is_partner',false,
      'empty_title','Not a delivery account',
      'empty_note','This login is not an active delivery partner.');
  end if;
  v_date := coalesce(p_date,(now() at time zone 'Asia/Kolkata')::date);
  v_rate := public._delivery_drop_rate(p.id);

  select count(*) filter (where d.status='delivered'),
         count(*) filter (where d.status='failed'),
         count(*) filter (where d.status in ('assigned','out_for_delivery')),
         round(coalesce(sum(d.leg_km),0),1),
         round(coalesce(sum(d.earning) filter (where d.status='delivered'),0),2)
    into v_del, v_fail, v_pend, v_km, v_earn
  from deliveries d join delivery_runs r on r.id = d.run_id
  where d.partner_id = p.id and r.run_date = v_date;

  select (s.ended_at is null), s.started_at into v_on, v_since
  from delivery_partner_shifts s
  where s.partner_id = p.id and s.shift_date = v_date
  order by s.started_at desc limit 1;

  v_train := public.delivery_training_state(p.id);

  return jsonb_build_object(
    'allowed', true, 'is_partner', true,
    'partner_id', p.id, 'partner_name', coalesce(p.full_name,''),
    'partner_type', p.partner_type, 'is_agency', (p.partner_type='agency'),
    'zone_id', p.zone_id,
    'zone_label', coalesce((select z.name from zones z where z.id=p.zone_id),''),
    'the_date', v_date,
    'on_shift', coalesce(v_on,false),
    'shift_since', v_since,
    'shift_button_label', case when coalesce(v_on,false) then 'End shift' else 'Start shift' end,
    'shift_action', case when coalesce(v_on,false) then 'end' else 'start' end,
    'tiles', jsonb_build_array(
       jsonb_build_object('key','delivered','label','Delivered','value',coalesce(v_del,0),
                          'colors', jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')),
       jsonb_build_object('key','pending','label','Pending','value',coalesce(v_pend,0),
                          'colors', jsonb_build_object('bg','#FEF3C7','fg','#92400E')),
       jsonb_build_object('key','failed','label','Failed','value',coalesce(v_fail,0),
                          'colors', jsonb_build_object('bg','#FBE9E7','fg','#B42318')),
       jsonb_build_object('key','distance','label','Distance','value',coalesce(v_km,0),
                          'display', coalesce(v_km,0)::text || ' km',
                          'colors', jsonb_build_object('bg','#E6F1FB','fg','#0C447C'))),
    'earning_today', coalesce(v_earn,0),
    'earning_today_display', public.inr_money(coalesce(v_earn,0)),
    'per_drop_display', public.inr_money(v_rate) || ' per delivery',
    -- CMD #407 — the programme, on the payload the home already reads.
    'incentives', public.my_incentive_progress(v_date),
    'training_pending', coalesce((v_train->>'pending_count')::int, 0),
    'extras', jsonb_build_object(
      'training_label', public._c('training.title'),
      'vehicle_label',  public._c('vehicle.title'),
      'training_note',  case when coalesce((v_train->>'blocks_assignment')::boolean,false)
                             then v_train->>'block_message' else '' end,
      'training_tone',  case when coalesce((v_train->>'blocks_assignment')::boolean,false)
                             then 'danger' else 'info' end));
end $$;
-- ── PART 11 — the registry's deep link points at the direct route.
-- /admin/go/<key> parks the key for the shell's route table; the delivery
-- programme also has a route of its own in main.dart, which needs no shell
-- frame at all, so that is the address a notification or a pasted link uses.
update public.feature_registry
   set deep_link = '/admin/delivery-programme'
 where feature_key = 'admin.delivery_extras';
-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #407 · PART 12 — design QA on the live screen.
-- The first live frame showed two unlabelled numbers: a rupee amount sitting
-- opposite a sentence, and a bare ₹0.00 with nothing to say what it was. A
-- number with no caption is a number the reader has to guess at — and the
-- caption belongs here, not in Dart.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy(key, value) values
  ('incentive.bonus_caption',   to_jsonb('Bonus each time it is hit'::text)),
  ('incentive.paid_caption',    to_jsonb('Paid out so far'::text)),
  ('cost_report.variance_caption', to_jsonb('Against the configured rate'::text)),
  ('agency_invoice.lbl_period', to_jsonb('Period'::text)),
  ('agency_invoice.lbl_payout', to_jsonb('Payout'::text))
on conflict (key) do nothing;

do $$
declare v_src text;
begin
  -- Add the two captions to every scheme row without restating the function.
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='admin_incentive_schemes';

  v_src := replace(v_src,
    E'           \'bonus_label\', public.inr_money(s.bonus_amount),',
    E'           \'bonus_label\', public.inr_money(s.bonus_amount),\n'
    '           ''bonus_caption'', public._c(''incentive.bonus_caption''),\n'
    '           ''paid_caption'',  public._c(''incentive.paid_caption''),');
  execute v_src;
end $$;

do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='admin_delivery_cost_report';

  v_src := replace(v_src,
    E'           \'partner_name\', coalesce(r.full_name,\'\'),',
    E'           \'partner_name\', coalesce(r.full_name,\'\'),\n'
    '           ''variance_caption'', public._c(''cost_report.variance_caption''),');
  execute v_src;
end $$;

do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='admin_agency_invoices';

  v_src := replace(v_src,
    E'      \'period_label\', to_char(p.period_start,\'DD Mon\') || \' – \' || to_char(p.period_end,\'DD Mon YYYY\'),',
    E'      \'period_caption\', public._c(\'agency_invoice.lbl_period\'),\n'
    '      ''payout_caption'', public._c(''agency_invoice.lbl_payout''),\n'
    '      ''period_label'', to_char(p.period_start,''DD Mon'') || '' – '' || to_char(p.period_end,''DD Mon YYYY''),');
  execute v_src;
end $$;
