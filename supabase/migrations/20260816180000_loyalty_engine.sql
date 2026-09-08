-- CHANGE #176 — B2B loyalty / rewards engine.
--
-- Five programs (tier, points, target slabs, streak, referral) sharing ONE
-- engine, with EVERY rule stored in config tables the engine reads at runtime.
-- Nothing is hardcoded: thresholds, rewards, earn/redeem rates, windows, which
-- order statuses even count, and every display string are rows Om edits from the
-- Loyalty admin screen. Changing a number applies on the next read — no rebuild,
-- no deploy.
--
-- Max-backend: Flutter receives finished strings (tier_label, progress_label,
-- points_label, ₹ already formatted by inr_money) and renders them verbatim.

-- ── CONFIG ──────────────────────────────────────────────────────────────────

create table if not exists loyalty_program (
  key          text primary key
                 check (key in ('tier','points','target','streak','referral')),
  label        text        not null default '',
  enabled      boolean     not null default false,
  starts_at    timestamptz,
  ends_at      timestamptz,
  -- program-specific numbers. points: earn_per_inr, inr_per_point,
  -- min_redeem_points, expiry_days. all programs: qualifying_statuses.
  config       jsonb       not null default '{}'::jsonb,
  updated_at   timestamptz not null default now()
);

create table if not exists loyalty_tier (
  id             bigserial primary key,
  name           text    not null,
  sort_order     int     not null default 0,
  window_days    int     not null default 90,
  threshold_kind text    not null default 'amount' check (threshold_kind in ('amount','orders')),
  threshold_value numeric not null default 0,
  benefit_kind   text    not null default 'discount_pct'
                   check (benefit_kind in ('margin_pct','discount_pct','scheme_access')),
  benefit_value  numeric not null default 0,
  enabled        boolean not null default true,
  created_at     timestamptz not null default now()
);

create table if not exists loyalty_slab (
  id              bigserial primary key,
  name            text    not null,
  window_days     int     not null default 30,
  threshold_amount numeric not null default 0,
  reward_kind     text    not null default 'credit'
                    check (reward_kind in ('cashback','credit','pct_off_next','points')),
  reward_value    numeric not null default 0,
  enabled         boolean not null default true,
  starts_at       timestamptz,
  ends_at         timestamptz,
  created_at      timestamptz not null default now()
);

create table if not exists loyalty_streak_step (
  id            bigserial primary key,
  step_no       int     not null,
  interval_days int     not null default 30,
  reward_kind   text    not null default 'points'
                  check (reward_kind in ('cashback','credit','pct_off_next','points')),
  reward_value  numeric not null default 0,
  enabled       boolean not null default true,
  unique (step_no)
);

create table if not exists loyalty_referral_rule (
  id                     int primary key default 1 check (id = 1),
  referrer_reward_kind   text    not null default 'credit'
                           check (referrer_reward_kind in ('cashback','credit','pct_off_next','points')),
  referrer_reward_value  numeric not null default 0,
  referee_reward_kind    text    not null default 'credit'
                           check (referee_reward_kind in ('cashback','credit','pct_off_next','points')),
  referee_reward_value   numeric not null default 0,
  min_first_order_amount numeric not null default 0,
  enabled                boolean not null default false,
  updated_at             timestamptz not null default now()
);

-- ── LEDGER + REFERRALS ──────────────────────────────────────────────────────

-- idem_key is what makes accrual safe to retry: the engine derives it from
-- (customer, program, order/window), so re-running an accrual is a no-op
-- instead of double-crediting.
create table if not exists loyalty_ledger (
  id          bigserial primary key,
  customer_id uuid    not null references pharmacy_profiles(id) on delete cascade,
  kind        text    not null check (kind in
                ('points_earned','points_redeemed','credit','cashback','pct_off_next','referral','streak','slab','tier')),
  points      numeric not null default 0,
  amount_inr  numeric not null default 0,
  order_id    uuid,
  note        text    not null default '',
  idem_key    text    not null unique,
  created_at  timestamptz not null default now()
);
create index if not exists loyalty_ledger_cust_idx on loyalty_ledger(customer_id, created_at desc);

create table if not exists loyalty_referral (
  id                   bigserial primary key,
  code                 text not null unique,
  referrer_customer_id uuid not null references pharmacy_profiles(id) on delete cascade,
  referee_customer_id  uuid references pharmacy_profiles(id) on delete set null,
  status               text not null default 'issued'
                         check (status in ('issued','joined','qualified')),
  qualified_at         timestamptz,
  created_at           timestamptz not null default now()
);
create unique index if not exists loyalty_referral_one_code_per_customer
  on loyalty_referral(referrer_customer_id) where referee_customer_id is null;
create index if not exists loyalty_referral_referee_idx on loyalty_referral(referee_customer_id);

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- Every read path is a SECURITY DEFINER RPC, so these policies are the floor:
-- config is admin-only, a customer can see only their own ledger and referrals.

alter table loyalty_program        enable row level security;
alter table loyalty_tier           enable row level security;
alter table loyalty_slab           enable row level security;
alter table loyalty_streak_step    enable row level security;
alter table loyalty_referral_rule  enable row level security;
alter table loyalty_ledger         enable row level security;
alter table loyalty_referral       enable row level security;

do $$
declare t text;
begin
  foreach t in array array['loyalty_program','loyalty_tier','loyalty_slab',
                           'loyalty_streak_step','loyalty_referral_rule'] loop
    execute format('drop policy if exists %I on %I', t||'_admin_all', t);
    execute format($f$create policy %I on %I for all
                       using (public.get_my_role() in ('admin','super_admin'))
                       with check (public.get_my_role() in ('admin','super_admin'))$f$,
                   t||'_admin_all', t);
  end loop;
end $$;

drop policy if exists loyalty_ledger_own on loyalty_ledger;
create policy loyalty_ledger_own on loyalty_ledger for select
  using (customer_id = public.my_customer_id()
         or public.get_my_role() in ('admin','super_admin'));

drop policy if exists loyalty_referral_own on loyalty_referral;
create policy loyalty_referral_own on loyalty_referral for select
  using (referrer_customer_id = public.my_customer_id()
         or referee_customer_id = public.my_customer_id()
         or public.get_my_role() in ('admin','super_admin'));

-- ── SEED: programs exist but ship OFF, so nothing changes until Om turns it on.
insert into loyalty_program(key, label, enabled, config) values
  ('tier',     'Tiered status', false,
     '{"qualifying_statuses":["accepted","delivered","completed","paid"]}'::jsonb),
  ('points',   'Points to credit', false,
     '{"qualifying_statuses":["accepted","delivered","completed","paid"],
       "earn_per_inr":0,"inr_per_point":0,"min_redeem_points":0,"expiry_days":0}'::jsonb),
  ('target',   'Volume targets', false,
     '{"qualifying_statuses":["accepted","delivered","completed","paid"]}'::jsonb),
  ('streak',   'Streak rewards', false,
     '{"qualifying_statuses":["accepted","delivered","completed","paid"]}'::jsonb),
  ('referral', 'Referrals', false,
     '{"qualifying_statuses":["accepted","delivered","completed","paid"]}'::jsonb)
on conflict (key) do nothing;

insert into loyalty_referral_rule(id) values (1) on conflict (id) do nothing;

-- Every customer-visible string. Om edits these; Flutter never invents one.
insert into app_settings(key, value) values ('loyalty_copy', '{
  "screen_title":"Rewards",
  "admin_title":"Loyalty",
  "entry_title":"Rewards",
  "entry_note":"Your tier, points and offers",
  "admin_entry_title":"Loyalty",
  "admin_entry_note":"Tiers, points, targets, streaks, referrals",
  "off_title":"Rewards are not running yet",
  "off_note":"When mediBO starts a rewards programme it will appear here.",
  "tier_title":"Your status",
  "tier_none":"No tier yet",
  "tier_progress":"{amount} more to reach {next}",
  "tier_top":"You are at the highest tier",
  "points_title":"Points",
  "points_balance":"{points} points",
  "points_worth":"Worth {amount}",
  "points_min":"Redeem from {points} points",
  "points_redeem":"Redeem",
  "points_none":"Earn points on every order",
  "target_title":"Targets",
  "target_progress":"{done} of {goal}",
  "target_hit":"Target reached",
  "streak_title":"Streak",
  "streak_count":"{n} in a row",
  "streak_next":"Order within {days} days to keep it",
  "streak_none":"Order regularly to start a streak",
  "referral_title":"Refer a pharmacy",
  "referral_code":"Your code",
  "referral_note":"Both of you get rewarded on their first qualifying order.",
  "empty_note":"Nothing here yet."
}'::jsonb)
on conflict (key) do update set value = excluded.value;
