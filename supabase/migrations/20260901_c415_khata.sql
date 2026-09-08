-- CMD #415 — the patient khata (udhaar) ledger, and the collector that works it.
--
-- Every pharmacy in Chhattisgarh already runs this book; it is a paper diary by
-- the till with a patient's name, a doctor's name, and a running figure nobody
-- reconciles. This is that diary, with two things paper cannot do: it knows how
-- OLD each balance is, and it can ask for the money by itself.
--
-- Shape follows POS (#411) exactly, because khata IS a POS payment mode:
--   * pos_shop() = my_customer_id() is the pharmacy. Every RPC gates on it.
--   * RLS ON with ZERO policies. Nothing reaches these tables except the
--     SECURITY DEFINER RPCs below, and each one filters to the caller's own
--     pharmacy. That is the PII fence the spec asks for: a patient's name and
--     phone belong to the pharmacy that wrote them down, not to mediBO. There
--     is deliberately NO admin RPC that returns a ledger row — khata_admin_
--     overview() counts and sums, and cannot name a patient.
--   * Every rupee, every label, every reminder sentence is composed here and
--     rendered verbatim. Dart computes nothing.
--
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ── 1. the account: one per patient or doctor, per pharmacy ────────────────
create table if not exists public.khata_account (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  kind           text not null default 'patient',   -- patient | doctor
  name           text not null,
  phone          text,                              -- 10 digits, or null
  limit_amount   numeric,                           -- optional credit ceiling
  balance        numeric not null default 0,        -- running, maintained below
  note           text,
  is_active      boolean not null default true,
  -- the collector's own state, reset by any payment
  reminder_stage    integer not null default 0,
  last_reminder_on  date,
  reminders_paused  boolean not null default false,
  oldest_due_on     date,        -- when the CURRENT unpaid run started ageing
  last_entry_at     timestamptz,
  last_payment_at   timestamptz,
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint khata_account_kind_ck check (kind in ('patient','doctor'))
);

create unique index if not exists khata_account_phone_uq
  on public.khata_account (pharmacy_id, phone) where phone is not null;
create index if not exists khata_account_shop_ix
  on public.khata_account (pharmacy_id, is_active, balance desc);
create index if not exists khata_account_name_ix
  on public.khata_account (pharmacy_id, lower(name));

-- ── 2. the entries: the diary lines themselves ─────────────────────────────
-- amount is SIGNED the way the book reads: a credit sale ADDS to what is owed,
-- a payment SUBTRACTS. balance_after is stamped at write time under a row lock,
-- so a statement never has to re-add the column to print a running figure.
create table if not exists public.khata_entry (
  id               uuid primary key default gen_random_uuid(),
  pharmacy_id      uuid not null references public.pharmacy_profiles(id) on delete cascade,
  account_id       uuid not null references public.khata_account(id) on delete cascade,
  entry_type       text not null,                 -- sale | payment | adjust
  amount           numeric not null,              -- +owed / -paid
  balance_after    numeric not null,
  entry_on         date not null default (now() at time zone 'Asia/Kolkata')::date,
  sale_id          uuid references public.pos_sales(id) on delete set null,
  method           text,                          -- payments: cash | upi | other
  note             text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  client_action_id uuid,
  constraint khata_entry_type_ck check (entry_type in ('sale','payment','adjust'))
);

create unique index if not exists khata_entry_action_uq
  on public.khata_entry (client_action_id) where client_action_id is not null;
create unique index if not exists khata_entry_sale_uq
  on public.khata_entry (sale_id) where sale_id is not null;
create index if not exists khata_entry_acct_ix
  on public.khata_entry (account_id, created_at desc);
create index if not exists khata_entry_shop_ix
  on public.khata_entry (pharmacy_id, entry_on desc);

-- ── 3. the collector's settings, per pharmacy ──────────────────────────────
create table if not exists public.khata_settings (
  pharmacy_id     uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  enabled         boolean not null default false,  -- opt-in: never message a
                                                   -- patient before the shop says so
  gentle_days     integer not null default 7,      -- N — the soft nudge
  firm_days       integer not null default 15,     -- M — the firmer one
  final_days      integer not null default 30,     -- the last, still polite
  min_balance     numeric not null default 100,    -- never chase small change
  cycle_days      integer not null default 7,      -- at most ONE per cycle
  quiet_dow       integer[] not null default '{0}',-- 0=Sunday, quiet by default
  daily_cap       integer not null default 25,     -- per pharmacy, per day
  updated_at      timestamptz not null default now()
);

-- ── 4. reminder wording — platform default + the pharmacy's own edit ───────
-- pharmacy_id null = the approved platform wording. A pharmacy may edit within
-- it; khata_template_save() rejects anything that drops the required tokens or
-- adds a threat, so "editable within approved wording" is enforced, not hoped.
create table if not exists public.khata_template (
  id           bigint generated always as identity primary key,
  pharmacy_id  uuid references public.pharmacy_profiles(id) on delete cascade,
  stage        integer not null,                  -- 1 gentle | 2 firm | 3 final
  body         text not null,
  updated_by   uuid,
  updated_at   timestamptz not null default now()
);
create unique index if not exists khata_template_uq
  on public.khata_template (coalesce(pharmacy_id, '00000000-0000-0000-0000-000000000000'::uuid), stage);

-- ── 5. what was actually sent — the frequency cap's evidence ───────────────
create table if not exists public.khata_reminder_log (
  id            bigint generated always as identity primary key,
  pharmacy_id   uuid not null,
  account_id    uuid not null references public.khata_account(id) on delete cascade,
  stage         integer not null,
  balance_at    numeric not null,
  age_days      integer,
  sent_on       date not null default (now() at time zone 'Asia/Kolkata')::date,
  dedupe_key    text not null,
  channel       text,
  detail        jsonb,
  created_at    timestamptz not null default now()
);
create unique index if not exists khata_reminder_dedupe_uq
  on public.khata_reminder_log (dedupe_key);
create index if not exists khata_reminder_acct_ix
  on public.khata_reminder_log (account_id, sent_on desc);

-- ── 6. the statement PDF, one per account per render ───────────────────────
create table if not exists public.khata_statement (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null,
  account_id    uuid not null references public.khata_account(id) on delete cascade,
  status        text not null default 'queued',   -- queued | ready | failed
  bucket        text, path text, file_name text, bytes integer, error text,
  requested_at  timestamptz not null default now(),
  ready_at      timestamptz
);
create index if not exists khata_statement_acct_ix
  on public.khata_statement (account_id, requested_at desc);

-- ── 7. the fence ───────────────────────────────────────────────────────────
-- RLS on, no policies: the tables are unreachable except through the RPCs.
alter table public.khata_account       enable row level security;
alter table public.khata_entry         enable row level security;
alter table public.khata_settings      enable row level security;
alter table public.khata_template      enable row level security;
alter table public.khata_reminder_log  enable row level security;
alter table public.khata_statement     enable row level security;

revoke all on public.khata_account, public.khata_entry, public.khata_settings,
              public.khata_template, public.khata_reminder_log, public.khata_statement
  from anon, authenticated;

-- ── 8. the pharmacy's OWN UPI address ──────────────────────────────────────
-- Money in a khata reminder must land in the PHARMACY's account, never in a
-- mediBO account — this is the shop's own book and mediBO is not a party to it.
-- `verified` here means the owner typed it, saw the name it resolves to, and
-- confirmed it; there is no PSP name-lookup on this plan, so an unconfirmed VPA
-- simply never ships in a reminder rather than shipping unverified.
alter table public.pharmacy_profiles
  add column if not exists upi_vpa           text,
  add column if not exists upi_vpa_name      text,
  add column if not exists upi_verified_at   timestamptz,
  add column if not exists upi_verified_by   uuid;


-- == CMD #415 - the khata functions, as applied ==========================
-- Dumped from the live schema after the acceptance proof went 7/7 green, so
-- this file and the database say the same thing.

CREATE OR REPLACE FUNCTION public._khata_acct_json(a khata_account, s khata_settings)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_age int := case when a.oldest_due_on is null then null
                    else (public._khata_today() - a.oldest_due_on) end;
  v_tone text;
  v_over boolean := a.limit_amount is not null and a.balance > a.limit_amount;
begin
  v_tone := case
    when coalesce(a.balance,0) <= 0 then 'success'
    when v_age is null then 'info'
    when v_age >= s.final_days then 'danger'
    when v_age >= s.firm_days  then 'warning'
    else 'info' end;

  return jsonb_build_object(
    'id', a.id,
    'name', a.name,
    'kind', a.kind,
    'kind_label', public.ui_text('khata.kind_' || a.kind),
    'phone', a.phone,
    'phone_display', coalesce(a.phone, public.ui_text('khata.no_phone')),
    'has_phone', a.phone is not null,
    'balance', a.balance,
    'balance_display', public.inr_money(a.balance),
    'settled', coalesce(a.balance,0) <= 0,
    'tone', v_tone,
    'age_days', v_age,
    'age_label', case
        when coalesce(a.balance,0) <= 0 then public.ui_text('khata.settled_label')
        when v_age is null then ''
        when v_age = 0 then public.ui_text('khata.age_today')
        else public.khata_fmt('khata.age_days', jsonb_build_object('n', v_age::text)) end,
    'has_limit', a.limit_amount is not null,
    'limit_amount', a.limit_amount,
    'limit_display', case when a.limit_amount is null then null
                          else public.inr_money(a.limit_amount) end,
    'over_limit', v_over,
    'limit_warning', case when v_over then public.khata_fmt('khata.over_limit',
        jsonb_build_object('limit', public.inr_money(a.limit_amount),
                           'balance', public.inr_money(a.balance))) else null end,
    'reminder_stage', a.reminder_stage,
    'stage_label', case when a.reminder_stage > 0
        then public.khata_fmt('khata.stage_sent', jsonb_build_object('n', a.reminder_stage::text))
        else null end,
    'reminders_paused', a.reminders_paused,
    'last_payment_label', case when a.last_payment_at is null then null
        else public.khata_fmt('khata.last_paid', jsonb_build_object(
               'date', to_char(a.last_payment_at at time zone 'Asia/Kolkata', 'DD Mon'))) end,
    'note', a.note);
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_body(p_shop uuid, p_stage integer)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  select body from public.khata_template
   where stage = p_stage and (pharmacy_id = p_shop or pharmacy_id is null)
   order by (pharmacy_id is not null) desc limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public._khata_collector_card(p_shop uuid, s khata_settings, pp pharmacy_profiles)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_upi boolean := coalesce(nullif(btrim(coalesce(pp.upi_vpa,'')),''), '') <> ''
                   and pp.upi_verified_at is not null;
  v_sent int;
begin
  select count(*) into v_sent from public.khata_reminder_log
   where pharmacy_id = p_shop and sent_on = public._khata_today();

  return jsonb_build_object(
    'title', public.ui_text('khata.collector_title'),
    'enabled', s.enabled,
    'toggle_label', public.ui_text('khata.collector_toggle'),
    'status_label', case
        when not s.enabled then public.ui_text('khata.collector_off')
        when not v_upi     then public.ui_text('khata.collector_no_upi')
        else public.khata_fmt('khata.collector_on', jsonb_build_object(
               'gentle', s.gentle_days::text, 'firm', s.firm_days::text,
               'final', s.final_days::text)) end,
    'status_tone', case when not s.enabled then 'info'
                        when not v_upi then 'warning' else 'success' end,
    'blocked', s.enabled and not v_upi,
    'sent_today_label', public.khata_fmt('khata.sent_today',
                          jsonb_build_object('n', v_sent::text)),
    'upi', jsonb_build_object(
      'has', v_upi,
      'vpa', pp.upi_vpa,
      'name', pp.upi_vpa_name,
      'verified', pp.upi_verified_at is not null,
      'label', public.ui_text('khata.upi_label'),
      'hint',  public.ui_text('khata.upi_hint'),
      'set_label', public.ui_text('khata.upi_set'),
      'confirm_label', public.ui_text('khata.upi_confirm')),
    'ladder', jsonb_build_array(
      jsonb_build_object('stage', 1, 'days', s.gentle_days,
        'label', public.khata_fmt('khata.ladder_1', jsonb_build_object('n', s.gentle_days::text))),
      jsonb_build_object('stage', 2, 'days', s.firm_days,
        'label', public.khata_fmt('khata.ladder_2', jsonb_build_object('n', s.firm_days::text))),
      jsonb_build_object('stage', 3, 'days', s.final_days,
        'label', public.khata_fmt('khata.ladder_3', jsonb_build_object('n', s.final_days::text)))),
    'quiet_label', public.ui_text('khata.quiet_sunday'),
    'cap_label', public.khata_fmt('khata.cap_label',
                   jsonb_build_object('n', s.cycle_days::text)));
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_compose(p_shop uuid, p_account_id uuid, p_stage integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a public.khata_account%rowtype; s public.khata_settings%rowtype;
  pp public.pharmacy_profiles%rowtype;
  v_age int; v_stage int; v_upi jsonb; v_body text;
begin
  select * into a from public.khata_account where id = p_account_id and pharmacy_id = p_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('khata.err_not_found'));
  end if;
  s := public._khata_settings(p_shop);
  select * into pp from public.pharmacy_profiles where id = p_shop;
  v_age := coalesce(public._khata_today() - a.oldest_due_on, 0);
  v_stage := coalesce(p_stage, greatest(least(
      case when v_age >= s.final_days then 3
           when v_age >= s.firm_days  then 2
           else 1 end, 3), 1));
  v_upi := public._khata_upi_link(p_shop, greatest(a.balance,0),
             public.khata_fmt('khata.upi_note', jsonb_build_object(
               'shop', coalesce(pp.pharmacy_name, pp.customer_name, ''))));

  v_body := public.khata_fmt_body(public._khata_body(p_shop, v_stage), jsonb_build_object(
    'patient',  a.name,
    'shop',     coalesce(pp.pharmacy_name, pp.customer_name, ''),
    'amount',   public.inr_money(greatest(a.balance,0)),
    'days',     v_age::text,
    'pay_link', coalesce(v_upi->>'url', '')));

  return jsonb_build_object('ok', true, 'stage', v_stage,
    'stage_label', public.ui_text('khata.ladder_' || v_stage),
    'body', v_body, 'upi', v_upi, 'to', a.phone,
    'can_send', a.phone is not null and a.balance > 0
                and coalesce((v_upi->>'has')::boolean,false),
    'blocked_reason', case
        when a.phone is null then public.ui_text('khata.blocked_no_phone')
        when a.balance <= 0 then public.ui_text('khata.blocked_settled')
        when not coalesce((v_upi->>'has')::boolean,false) then public.ui_text('khata.collector_no_upi')
        else null end,
    'preview_label', public.ui_text('khata.preview_label'));
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_denied()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('khata.err_denied'));
$function$
;

CREATE OR REPLACE FUNCTION public._khata_post(p_shop uuid, p_account uuid, p_type text, p_amount numeric, p_note text DEFAULT NULL::text, p_method text DEFAULT NULL::text, p_sale uuid DEFAULT NULL::uuid, p_action uuid DEFAULT NULL::uuid, p_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a public.khata_account%rowtype;
  v_signed numeric; v_after numeric; v_id uuid;
  v_exist public.khata_entry%rowtype;
begin
  if p_sale is not null then
    select * into v_exist from public.khata_entry where sale_id = p_sale;
    if found then
      return jsonb_build_object('ok', true, 'replayed', true,
        'entry_id', v_exist.id, 'account_id', v_exist.account_id,
        'balance', v_exist.balance_after);
    end if;
  end if;
  if p_action is not null then
    select * into v_exist from public.khata_entry where client_action_id = p_action;
    if found then
      return jsonb_build_object('ok', true, 'replayed', true,
        'entry_id', v_exist.id, 'account_id', v_exist.account_id,
        'balance', v_exist.balance_after);
    end if;
  end if;

  select * into a from public.khata_account
   where id = p_account and pharmacy_id = p_shop for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('khata.err_not_found'));
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('ok', false, 'error', 'bad_amount',
      'message', public.ui_text('khata.err_bad_amount'));
  end if;

  v_signed := case when p_type = 'payment' then -p_amount else p_amount end;
  v_after  := round(coalesce(a.balance, 0) + v_signed, 2);

  insert into public.khata_entry(
    pharmacy_id, account_id, entry_type, amount, balance_after, entry_on,
    sale_id, method, note, created_by, client_action_id)
  values (p_shop, a.id, p_type, v_signed, v_after,
          coalesce(p_on, public._khata_today()),
          p_sale, nullif(btrim(coalesce(p_method,'')),''),
          nullif(btrim(coalesce(p_note,'')),''), auth.uid(), p_action)
  returning id into v_id;

  update public.khata_account
     set balance = v_after,
         last_entry_at = now(),
         last_payment_at = case when p_type = 'payment' then now() else last_payment_at end,
         oldest_due_on = case
             when v_after <= 0 then null
             when coalesce(a.balance, 0) <= 0 then public._khata_today()
             else coalesce(a.oldest_due_on, public._khata_today()) end,
         reminder_stage = case
             when v_after <= 0 then 0
             when p_type = 'payment' then 0
             else reminder_stage end,
         last_reminder_on = case
             when v_after <= 0 or p_type = 'payment' then null
             else last_reminder_on end,
         updated_at = now()
   where id = a.id;

  return jsonb_build_object('ok', true, 'replayed', false, 'entry_id', v_id,
    'account_id', a.id, 'balance', v_after,
    'balance_display', public.inr_money(v_after));
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_post_sale(p_shop uuid, p_sale uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s public.pos_sales%rowtype; v_acct uuid;
begin
  select * into s from public.pos_sales where id = p_sale and pharmacy_id = p_shop;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  v_acct := public._khata_resolve(p_shop, s.patient_name, s.patient_phone, 'patient');
  if v_acct is null then return jsonb_build_object('ok', false, 'error', 'no_patient'); end if;
  return public._khata_post(
    p_shop, v_acct, 'sale', s.net_amount,
    public.khata_fmt('khata.sale_note', jsonb_build_object('invoice', s.invoice_no)),
    null, s.id, null, s.sold_on);
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_required_tokens()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$ select array['{{amount}}','{{pay_link}}']::text[]; $function$
;

CREATE OR REPLACE FUNCTION public._khata_resolve(p_shop uuid, p_name text, p_phone text, p_kind text DEFAULT 'patient'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ph text := nullif(right(regexp_replace(coalesce(p_phone,''), '\D', '', 'g'), 10), '');
  v_nm text := nullif(btrim(coalesce(p_name, '')), '');
  v_id uuid;
begin
  if coalesce(length(v_ph), 0) <> 10 then v_ph := null; end if;
  if v_ph is null and v_nm is null then return null; end if;

  if v_ph is not null then
    select id into v_id from public.khata_account
     where pharmacy_id = p_shop and phone = v_ph limit 1;
    if v_id is not null then
      update public.khata_account
         set name = case when coalesce(btrim(name),'') = '' then coalesce(v_nm, name) else name end,
             updated_at = now()
       where id = v_id;
      return v_id;
    end if;
  end if;

  if v_nm is not null then
    select id into v_id from public.khata_account
     where pharmacy_id = p_shop and lower(name) = lower(v_nm)
       and (phone is null or v_ph is null or phone = v_ph)
     order by (phone is not null) desc limit 1;
    if v_id is not null then
      update public.khata_account
         set phone = coalesce(phone, v_ph), updated_at = now()
       where id = v_id;
      return v_id;
    end if;
  end if;

  insert into public.khata_account(pharmacy_id, kind, name, phone, created_by)
  values (p_shop,
          case when p_kind in ('patient','doctor') then p_kind else 'patient' end,
          coalesce(v_nm, v_ph), v_ph, auth.uid())
  returning id into v_id;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_send(p_shop uuid, p_account uuid, p_stage integer, p_manual boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a public.khata_account%rowtype; s public.khata_settings%rowtype;
  v_msg jsonb; v_key text; v_age int; v_sent int; v_res jsonb; v_log bigint;
begin
  select * into a from public.khata_account where id = p_account and pharmacy_id = p_shop for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  s := public._khata_settings(p_shop);

  if a.reminders_paused then return jsonb_build_object('ok', false, 'reason', 'paused'); end if;
  if coalesce(a.balance,0) <= 0 then return jsonb_build_object('ok', false, 'reason', 'settled'); end if;
  if a.phone is null then return jsonb_build_object('ok', false, 'reason', 'no_phone'); end if;

  if a.last_reminder_on is not null
     and public._khata_today() - a.last_reminder_on < s.cycle_days then
    return jsonb_build_object('ok', false, 'reason', 'too_soon',
      'message', public.khata_fmt('khata.too_soon',
        jsonb_build_object('n', (s.cycle_days - (public._khata_today() - a.last_reminder_on))::text)));
  end if;

  select count(*) into v_sent from public.khata_reminder_log
   where pharmacy_id = p_shop and sent_on = public._khata_today();
  if v_sent >= s.daily_cap then
    return jsonb_build_object('ok', false, 'reason', 'daily_cap');
  end if;

  v_msg := public._khata_compose(p_shop, p_account, p_stage);
  if coalesce(v_msg->>'ok','false') <> 'true'
     or not coalesce((v_msg->>'can_send')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', coalesce(v_msg->>'error','cannot_send'),
      'message', v_msg->>'blocked_reason');
  end if;

  v_age := coalesce(public._khata_today() - a.oldest_due_on, 0);

  insert into public.khata_reminder_log(
      pharmacy_id, account_id, stage, balance_at, age_days, dedupe_key, channel, detail)
  values (p_shop, a.id, p_stage, a.balance, v_age,
          a.id::text || ':' || p_stage::text || ':' || coalesce(a.oldest_due_on::text,'none'),
          'whatsapp',
          jsonb_build_object('manual', p_manual, 'body', v_msg->>'body', 'status', 'claimed'))
  on conflict (dedupe_key) do nothing
  returning id into v_log;

  if v_log is null then
    return jsonb_build_object('ok', false, 'reason', 'already_sent',
      'message', public.ui_text('khata.already_sent'));
  end if;

  update public.khata_account
     set reminder_stage = greatest(reminder_stage, p_stage),
         last_reminder_on = public._khata_today(),
         updated_at = now()
   where id = a.id;

  v_key := 'khata_reminder_' || p_stage;
  v_res := public.notify(v_key, a.phone, jsonb_build_object(
    'patient',  a.name,
    'shop',     v_msg->'upi'->>'payee',
    'amount',   public.inr_money(greatest(a.balance,0)),
    'days',     v_age::text,
    'pay_link', coalesce(v_msg->'upi'->>'url',''),
    'channel',  'whatsapp'));

  update public.khata_reminder_log
     set detail = detail || jsonb_build_object('notify', v_res, 'status', 'sent')
   where id = v_log;

  return jsonb_build_object('ok', true, 'stage', p_stage, 'notify', v_res,
    'message', public.khata_fmt('khata.reminder_sent',
                 jsonb_build_object('name', a.name)));
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_settings(p_shop uuid)
 RETURNS khata_settings
 LANGUAGE plpgsql
 STABLE
AS $function$
declare s public.khata_settings%rowtype;
begin
  select * into s from public.khata_settings where pharmacy_id = p_shop;
  if not found then
    s.pharmacy_id := p_shop; s.enabled := false;
    s.gentle_days := 7; s.firm_days := 15; s.final_days := 30;
    s.min_balance := 100; s.cycle_days := 7;
    s.quiet_dow := '{0}'::integer[]; s.daily_cap := 25;
  end if;
  return s;
end $function$
;

CREATE OR REPLACE FUNCTION public._khata_today()
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$ select (now() at time zone 'Asia/Kolkata')::date; $function$
;

CREATE OR REPLACE FUNCTION public._khata_upi_link(p_shop uuid, p_amount numeric, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare pp public.pharmacy_profiles%rowtype; v_pa text; v_pn text;
begin
  select * into pp from public.pharmacy_profiles where id = p_shop;
  v_pa := nullif(btrim(coalesce(pp.upi_vpa,'')), '');
  if v_pa is null or pp.upi_verified_at is null then
    return jsonb_build_object('has', false,
      'reason', case when v_pa is null then 'no_vpa' else 'not_verified' end);
  end if;
  v_pn := coalesce(nullif(btrim(coalesce(pp.upi_vpa_name,'')),''),
                   pp.pharmacy_name, pp.customer_name, '');
  return jsonb_build_object(
    'has', true,
    'vpa', v_pa,
    'payee', v_pn,
    'amount_display', public.inr_money(p_amount),
    'label', public.ui_text('khata.pay_now'),
    'url', 'upi://pay?pa=' || v_pa
           || '&pn=' || replace(replace(v_pn, '&', ' '), '#', ' ')
           || '&am=' || to_char(round(greatest(p_amount, 0), 2), 'FM9999999990.00')
           || '&cu=INR&tn=' || replace(replace(coalesce(p_note,''), '&', ' '), '#', ' '));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_account_detail(p_account_id uuid, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.khata_shop();
  a public.khata_account%rowtype;
  s public.khata_settings%rowtype;
  pp public.pharmacy_profiles%rowtype;
  v_lines jsonb; v_total int; v_lim int := least(greatest(coalesce(p_limit,100),1), 300);
begin
  if v_shop is null then return public._khata_denied(); end if;
  select * into a from public.khata_account
   where id = p_account_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('khata.err_not_found'));
  end if;
  s := public._khata_settings(v_shop);
  select * into pp from public.pharmacy_profiles where id = v_shop;

  select count(*) into v_total from public.khata_entry where account_id = a.id;

  select coalesce(jsonb_agg(x order by x_ord), '[]'::jsonb) into v_lines
  from (
    select row_number() over (order by e.created_at desc) x_ord,
      jsonb_build_object(
        'id', e.id,
        'type', e.entry_type,
        'type_label', public.ui_text('khata.entry_' || e.entry_type),
        'date_label', to_char(e.entry_on, 'DD Mon YYYY'),
        'amount', e.amount,
        'amount_display', (case when e.amount < 0 then '- ' else '+ ' end)
                          || public.inr_money(abs(e.amount)),
        'tone', case when e.amount < 0 then 'success' else 'info' end,
        'balance_display', public.inr_money(e.balance_after),
        'note', e.note,
        'method_label', case when e.method is null then null
                             else public.ui_text('khata.method_' || e.method) end,
        'invoice_no', (select ps.invoice_no from public.pos_sales ps where ps.id = e.sale_id)
      ) x
      from public.khata_entry e
     where e.account_id = a.id
     order by e.created_at desc
     limit v_lim offset greatest(coalesce(p_offset,0),0)
  ) q;

  return jsonb_build_object(
    'ok', true,
    'account', public._khata_acct_json(a, s),
    'labels', jsonb_build_object(
      'statement',      public.ui_text('khata.statement_title'),
      'date',           public.ui_text('khata.col_date'),
      'particulars',    public.ui_text('khata.col_particulars'),
      'amount',         public.ui_text('khata.col_amount'),
      'balance',        public.ui_text('khata.col_balance'),
      'record_payment', public.ui_text('khata.record_payment'),
      'statement_btn',  public.ui_text('khata.statement_button'),
      'send_wa',        public.ui_text('khata.send_wa'),
      'remind',         public.ui_text('khata.remind_now'),
      'edit',           public.ui_text('khata.edit_account')),
    'lines', v_lines,
    'has_more', greatest(coalesce(p_offset,0),0) + v_lim < v_total,
    'next_offset', greatest(coalesce(p_offset,0),0) + v_lim,
    'empty', jsonb_build_object('title', public.ui_text('khata.no_entries')),
    'upi', public._khata_upi_link(v_shop, greatest(a.balance, 0),
             public.khata_fmt('khata.upi_note',
               jsonb_build_object('shop', coalesce(pp.pharmacy_name, pp.customer_name, '')))),
    'can_remind', a.balance > 0 and a.phone is not null,
    'methods', jsonb_build_array(
      jsonb_build_object('key','cash','label', public.ui_text('khata.method_cash')),
      jsonb_build_object('key','upi', 'label', public.ui_text('khata.method_upi')),
      jsonb_build_object('key','other','label', public.ui_text('khata.method_other'))));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_account_upsert(p_id uuid DEFAULT NULL::uuid, p_name text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_kind text DEFAULT 'patient'::text, p_limit numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text, p_is_active boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.khata_shop();
  v_nm text := nullif(btrim(coalesce(p_name,'')), '');
  v_ph text := nullif(right(regexp_replace(coalesce(p_phone,''), '\D','','g'), 10), '');
  a public.khata_account%rowtype; s public.khata_settings%rowtype; v_id uuid;
begin
  if v_shop is null then return public._khata_denied(); end if;
  if coalesce(length(v_ph),0) <> 10 then v_ph := null; end if;
  if p_id is null and v_nm is null then
    return jsonb_build_object('ok', false, 'error', 'no_name',
      'message', public.ui_text('khata.err_no_name'));
  end if;
  if v_ph is not null and exists (
       select 1 from public.khata_account
        where pharmacy_id = v_shop and phone = v_ph
          and (p_id is null or id <> p_id)) then
    return jsonb_build_object('ok', false, 'error', 'phone_taken',
      'message', public.ui_text('khata.err_phone_taken'));
  end if;

  if p_id is null then
    insert into public.khata_account(pharmacy_id, kind, name, phone, limit_amount, note, created_by)
    values (v_shop, case when p_kind in ('patient','doctor') then p_kind else 'patient' end,
            v_nm, v_ph, p_limit, nullif(btrim(coalesce(p_note,'')),''), auth.uid())
    returning id into v_id;
  else
    update public.khata_account
       set name = coalesce(v_nm, name),
           phone = case when p_phone is null then phone else v_ph end,
           kind = case when p_kind in ('patient','doctor') then p_kind else kind end,
           limit_amount = case when p_limit is null then limit_amount else p_limit end,
           note = case when p_note is null then note
                       else nullif(btrim(p_note),'') end,
           is_active = coalesce(p_is_active, is_active),
           updated_at = now()
     where id = p_id and pharmacy_id = v_shop
    returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'not_found',
        'message', public.ui_text('khata.err_not_found'));
    end if;
  end if;

  select * into a from public.khata_account where id = v_id;
  s := public._khata_settings(v_shop);
  return jsonb_build_object('ok', true, 'account', public._khata_acct_json(a, s),
    'message', public.ui_text('khata.saved_toast'));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_admin_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb;
begin
  if not public.am_i_super() then
    return jsonb_build_object('ok', false, 'error', 'denied');
  end if;
  select coalesce(jsonb_agg(x order by (x->>'outstanding')::numeric desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'pharmacy', coalesce(pp.pharmacy_name, pp.customer_name),
      'accounts', count(a.*),
      'due_accounts', count(*) filter (where a.balance > 0),
      'outstanding', coalesce(sum(a.balance) filter (where a.balance > 0), 0),
      'outstanding_display', public.inr_money(coalesce(sum(a.balance) filter (where a.balance > 0), 0))) x
      from public.khata_account a
      join public.pharmacy_profiles pp on pp.id = a.pharmacy_id
     group by pp.id, pp.pharmacy_name, pp.customer_name
  ) q;
  return jsonb_build_object('ok', true, 'title', public.ui_text('khata.admin_title'),
    'note', public.ui_text('khata.admin_note'), 'rows', v_rows);
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_collector_tick(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record; v_sent int := 0; v_seen int := 0; v_skipped int := 0; v_res jsonb;
  v_dow int := extract(dow from (now() at time zone 'Asia/Kolkata'))::int;
begin
  for r in
    select a.id, a.pharmacy_id,
           case when (public._khata_today() - a.oldest_due_on) >= s.final_days then 3
                when (public._khata_today() - a.oldest_due_on) >= s.firm_days  then 2
                else 1 end as want_stage,
           a.reminder_stage
      from public.khata_account a
      join public.khata_settings s on s.pharmacy_id = a.pharmacy_id
      join public.pharmacy_profiles pp on pp.id = a.pharmacy_id
     where s.enabled
       and a.is_active
       and not a.reminders_paused
       and a.phone is not null
       and a.balance > s.min_balance
       and a.oldest_due_on is not null
       and (public._khata_today() - a.oldest_due_on) >= s.gentle_days
       and coalesce(nullif(btrim(coalesce(pp.upi_vpa,'')),''),'') <> ''
       and pp.upi_verified_at is not null
       -- quiet days are the shop's own list; Sunday by default
       and not (v_dow = any (s.quiet_dow))
       and (a.last_reminder_on is null
            or public._khata_today() - a.last_reminder_on >= s.cycle_days)
     order by a.oldest_due_on
     limit greatest(coalesce(p_limit, 200), 1)
  loop
    v_seen := v_seen + 1;
    -- only ever a rung we have not already sent for THIS debt
    if r.want_stage <= r.reminder_stage then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_res := public._khata_send(r.pharmacy_id, r.id, r.want_stage, false);
    if coalesce((v_res->>'ok')::boolean, false) then v_sent := v_sent + 1;
    else v_skipped := v_skipped + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'seen', v_seen, 'sent', v_sent,
                            'skipped', v_skipped, 'dow', v_dow);
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_entry_add(p_account_id uuid, p_type text, p_amount numeric, p_method text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_client_action_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.khata_shop();
  v_res jsonb; a public.khata_account%rowtype; s public.khata_settings%rowtype;
begin
  if v_shop is null then return public._khata_denied(); end if;
  if coalesce(p_type,'') not in ('payment','adjust','sale') then
    return jsonb_build_object('ok', false, 'error', 'bad_type',
      'message', public.ui_text('khata.err_bad_type'));
  end if;

  v_res := public._khata_post(v_shop, p_account_id, p_type, p_amount,
                              p_note, p_method, null, p_client_action_id, null);
  if coalesce(v_res->>'ok','false') <> 'true' then return v_res; end if;

  select * into a from public.khata_account where id = p_account_id;
  s := public._khata_settings(v_shop);
  return v_res || jsonb_build_object(
    'account', public._khata_acct_json(a, s),
    'message', case when p_type = 'payment'
                    then public.khata_fmt('khata.payment_toast',
                           jsonb_build_object('amount', public.inr_money(p_amount)))
                    else public.ui_text('khata.saved_toast') end);
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_fmt(p_key text, p_vars jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
declare v_out text := public.ui_text(p_key); k text;
begin
  if coalesce(v_out,'') = '' then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{{' || k || '}}', coalesce(p_vars->>k, ''));
  end loop;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_fmt_body(p_body text, p_vars jsonb)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare v_out text := coalesce(p_body,''); k text;
begin
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{{' || k || '}}', coalesce(p_vars->>k, ''));
  end loop;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_home(p_q text DEFAULT NULL::text, p_filter text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.khata_shop();
  s public.khata_settings%rowtype;
  v_rows jsonb; v_out numeric; v_n int; v_due int;
  pp public.pharmacy_profiles%rowtype;
  v_q text := nullif(btrim(coalesce(p_q,'')), '');
  v_f text := coalesce(nullif(btrim(coalesce(p_filter,'')),''), 'due');
begin
  if v_shop is null then return public._khata_denied(); end if;
  s := public._khata_settings(v_shop);
  select * into pp from public.pharmacy_profiles where id = v_shop;

  select coalesce(sum(a.balance) filter (where a.balance > 0), 0),
         count(*) filter (where a.is_active),
         count(*) filter (where a.balance > 0)
    into v_out, v_n, v_due
    from public.khata_account a where a.pharmacy_id = v_shop;

  select coalesce(jsonb_agg(public._khata_acct_json(a, s)
           order by (a.balance > 0) desc, a.oldest_due_on nulls last, a.balance desc), '[]'::jsonb)
    into v_rows
    from public.khata_account a
   where a.pharmacy_id = v_shop
     and a.is_active
     and (v_f <> 'due' or a.balance > 0)
     and (v_q is null or a.name ilike '%'||v_q||'%' or coalesce(a.phone,'') like '%'||v_q||'%');

  return jsonb_build_object(
    'ok', true,
    'shop_name', coalesce(pp.pharmacy_name, pp.customer_name),
    'labels', jsonb_build_object(
      'title',         public.ui_text('khata.title'),
      'subtitle',      public.ui_text('khata.subtitle'),
      'search_hint',   public.ui_text('khata.search_hint'),
      'outstanding',   public.ui_text('khata.outstanding_label'),
      'accounts',      public.ui_text('khata.accounts_label'),
      'add',           public.ui_text('khata.add_account'),
      'record_payment',public.ui_text('khata.record_payment'),
      'statement',     public.ui_text('khata.statement_button'),
      'send_wa',       public.ui_text('khata.send_wa'),
      'remind',        public.ui_text('khata.remind_now'),
      'settings',      public.ui_text('khata.settings_title'),
      'name',          public.ui_text('khata.name_label'),
      'phone',         public.ui_text('khata.phone_label'),
      'limit',         public.ui_text('khata.limit_label'),
      'amount',        public.ui_text('khata.amount_label'),
      'method',        public.ui_text('khata.method_label'),
      'note',          public.ui_text('khata.note_label'),
      'save',          public.ui_text('khata.save'),
      'retry',         public.ui_text('khata.retry')),
    'filters', jsonb_build_array(
      jsonb_build_object('key','due', 'label', public.ui_text('khata.filter_due'),  'selected', v_f = 'due'),
      jsonb_build_object('key','all', 'label', public.ui_text('khata.filter_all'),  'selected', v_f = 'all')),
    'totals', jsonb_build_object(
      'outstanding', v_out,
      'outstanding_display', public.inr_money(v_out),
      'accounts_label', public.khata_fmt('khata.accounts_count',
                          jsonb_build_object('n', v_n::text)),
      'due_label', public.khata_fmt('khata.due_count',
                          jsonb_build_object('n', v_due::text)),
      'has_any', v_n > 0),
    'collector', public._khata_collector_card(v_shop, s, pp),
    'accounts', v_rows,
    'empty', jsonb_build_object(
      'title', public.ui_text('khata.empty_title'),
      'hint',  public.ui_text('khata.empty_hint')),
    'methods', jsonb_build_array(
      jsonb_build_object('key','cash','label', public.ui_text('khata.method_cash')),
      jsonb_build_object('key','upi', 'label', public.ui_text('khata.method_upi')),
      jsonb_build_object('key','other','label', public.ui_text('khata.method_other'))),
    'kinds', jsonb_build_array(
      jsonb_build_object('key','patient','label', public.ui_text('khata.kind_patient')),
      jsonb_build_object('key','doctor', 'label', public.ui_text('khata.kind_doctor'))));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_nav_entry()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.khata_shop(); v_due numeric;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select coalesce(sum(balance) filter (where balance > 0), 0) into v_due
    from public.khata_account where pharmacy_id = v_shop;
  return jsonb_build_object(
    'ok', true, 'show', true,
    'route_key', 'khata',
    'icon_key', 'menu_book',
    'label', public.ui_text('khata.nav_label'),
    'sub_label', case when v_due > 0
        then public.khata_fmt('khata.nav_due', jsonb_build_object('amount', public.inr_money(v_due)))
        else public.ui_text('khata.subtitle') end);
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_proof_c415()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid; v_acct uuid; v_res jsonb; v_msg jsonb;
  v_bal numeric; v_stage int; v_steps jsonb := '[]'::jsonb;
  o_vpa text; o_name text; o_ver timestamptz; o_set public.khata_settings%rowtype;
  o_had boolean; v_pass boolean := true; v_ok boolean;
begin
  select id into v_shop from public.pharmacy_profiles order by created_at limit 1;
  if v_shop is null then return jsonb_build_object('ok', false, 'error', 'no_pharmacy'); end if;

  select upi_vpa, upi_vpa_name, upi_verified_at into o_vpa, o_name, o_ver
    from public.pharmacy_profiles where id = v_shop;
  select * into o_set from public.khata_settings where pharmacy_id = v_shop;
  o_had := found;

  delete from public.khata_account where pharmacy_id = v_shop and phone = '9999900415';
  insert into public.khata_account(pharmacy_id, kind, name, phone)
  values (v_shop, 'patient', 'C415 Proof Patient', '9999900415')
  returning id into v_acct;

  -- 1 — a credit sale becomes a debt, and starts the ageing clock today
  v_res := public._khata_post(v_shop, v_acct, 'sale', 1250.00, 'proof credit sale');
  select balance, oldest_due_on is not null into v_bal, v_ok
    from public.khata_account where id = v_acct;
  v_ok := v_ok and coalesce((v_res->>'ok')::boolean,false) and v_bal = 1250.00;
  v_steps := v_steps || jsonb_build_object('step','1 credit sale -> balance, clock starts',
    'pass', v_ok, 'balance_display', public.inr_money(v_bal));
  v_pass := v_pass and v_ok;

  update public.pharmacy_profiles
     set upi_vpa='c415proof@upi', upi_vpa_name='C415 Proof Pharmacy', upi_verified_at=now()
   where id = v_shop;
  insert into public.khata_settings(pharmacy_id, enabled, quiet_dow)
  values (v_shop, true, '{}'::integer[])
  on conflict (pharmacy_id) do update set enabled=true, quiet_dow='{}'::integer[];

  -- 2 — at 3 days the ladder is still on its gentle rung
  update public.khata_account set oldest_due_on = current_date - 3 where id = v_acct;
  v_msg := public._khata_compose(v_shop, v_acct, null);
  v_ok := (v_msg->>'stage') = '1';
  v_steps := v_steps || jsonb_build_object('step','2 young debt picks the gentle rung',
    'pass', v_ok, 'stage', v_msg->>'stage');
  v_pass := v_pass and v_ok;

  -- 3 — at 20 days it has climbed to firm, and carries a real UPI deeplink
  update public.khata_account set oldest_due_on = current_date - 20 where id = v_acct;
  v_msg := public._khata_compose(v_shop, v_acct, null);
  v_ok := (v_msg->>'stage') = '2'
          and coalesce((v_msg->>'can_send')::boolean,false)
          and (v_msg->'upi'->>'url') like 'upi://pay?pa=c415proof@upi%'
          and position('1,250' in coalesce(v_msg->>'body','')) > 0
          and position('20 days' in coalesce(v_msg->>'body','')) > 0;
  v_steps := v_steps || jsonb_build_object('step','3 aged debt climbs to firm, with UPI link',
    'pass', v_ok, 'stage', v_msg->>'stage', 'body', v_msg->>'body',
    'upi_url', v_msg->'upi'->>'url');
  v_pass := v_pass and v_ok;

  -- 4 — the collector itself sends it (no auth context, exactly like cron)
  v_res := public.khata_collector_tick(50);
  select reminder_stage into v_stage from public.khata_account where id = v_acct;
  v_ok := (v_res->>'sent')::int >= 1 and v_stage = 2;
  v_steps := v_steps || jsonb_build_object('step','4 collector tick sends the firm rung',
    'pass', v_ok, 'stage', v_stage, 'tick', v_res);
  v_pass := v_pass and v_ok;

  -- 5 — a second tick in the same cycle sends nothing
  v_res := public.khata_collector_tick(50);
  v_ok := coalesce((v_res->>'sent')::int, 0) = 0;
  v_steps := v_steps || jsonb_build_object('step','5 frequency cap holds on the next tick',
    'pass', v_ok, 'tick', v_res);
  v_pass := v_pass and v_ok;

  -- 6 — the payment closes the loop and resets the ladder
  v_res := public._khata_post(v_shop, v_acct, 'payment', 1250.00, 'proof payment', 'upi');
  select balance, reminder_stage into v_bal, v_stage from public.khata_account where id = v_acct;
  v_ok := v_bal = 0 and v_stage = 0;
  v_steps := v_steps || jsonb_build_object('step','6 payment -> balance 0, ladder reset',
    'pass', v_ok, 'balance', v_bal, 'stage', v_stage);
  v_pass := v_pass and v_ok;

  -- 7 — and the collector no longer sees it, however old the original debt was
  v_res := public.khata_collector_tick(50);
  v_ok := coalesce((v_res->>'sent')::int, 0) = 0
          and not exists (select 1 from public.khata_account a
                 join public.khata_settings s on s.pharmacy_id = a.pharmacy_id
                where a.id = v_acct and a.balance > s.min_balance);
  v_steps := v_steps || jsonb_build_object('step','7 escalation stopped by the payment',
    'pass', v_ok, 'tick', v_res);
  v_pass := v_pass and v_ok;

  delete from public.khata_reminder_log where account_id = v_acct;
  delete from public.khata_account where id = v_acct;
  update public.pharmacy_profiles
     set upi_vpa = o_vpa, upi_vpa_name = o_name, upi_verified_at = o_ver
   where id = v_shop;
  if o_had then
    update public.khata_settings set enabled = o_set.enabled, quiet_dow = o_set.quiet_dow
     where pharmacy_id = v_shop;
  else
    delete from public.khata_settings where pharmacy_id = v_shop;
  end if;

  return jsonb_build_object('ok', v_pass, 'steps', v_steps,
    'summary', case when v_pass
      then 'credit sale -> ageing -> gentle/firm ladder -> reminder+UPI -> payment -> escalation stopped'
      else 'one or more steps failed' end);
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_remind_now(p_account_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.khata_shop(); v_res jsonb;
        a public.khata_account%rowtype; s public.khata_settings%rowtype;
begin
  if v_shop is null then return public._khata_denied(); end if;
  select * into a from public.khata_account where id = p_account_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('khata.err_not_found'));
  end if;
  s := public._khata_settings(v_shop);
  v_res := public._khata_send(v_shop, p_account_id,
             greatest(least(a.reminder_stage + 1, 3), 1), true);
  select * into a from public.khata_account where id = p_account_id;
  return v_res || jsonb_build_object('account', public._khata_acct_json(a, s));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_reminder_compose(p_account_id uuid, p_stage integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.khata_shop();
begin
  if v_shop is null then return public._khata_denied(); end if;
  return public._khata_compose(v_shop, p_account_id, p_stage);
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_settings_save(p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.khata_shop(); s public.khata_settings%rowtype;
        pp public.pharmacy_profiles%rowtype;
begin
  if v_shop is null then return public._khata_denied(); end if;
  s := public._khata_settings(v_shop);

  insert into public.khata_settings(pharmacy_id, enabled, gentle_days, firm_days,
                                    final_days, min_balance, cycle_days, quiet_dow, daily_cap)
  values (v_shop,
    coalesce((p_patch->>'enabled')::boolean, s.enabled),
    greatest(coalesce((p_patch->>'gentle_days')::int, s.gentle_days), 1),
    greatest(coalesce((p_patch->>'firm_days')::int, s.firm_days), 2),
    greatest(coalesce((p_patch->>'final_days')::int, s.final_days), 3),
    greatest(coalesce((p_patch->>'min_balance')::numeric, s.min_balance), 0),
    greatest(coalesce((p_patch->>'cycle_days')::int, s.cycle_days), 1),
    coalesce((select array_agg(v::int) from jsonb_array_elements_text(p_patch->'quiet_dow') v),
             s.quiet_dow),
    greatest(coalesce((p_patch->>'daily_cap')::int, s.daily_cap), 1))
  on conflict (pharmacy_id) do update set
    enabled = excluded.enabled, gentle_days = excluded.gentle_days,
    firm_days = excluded.firm_days, final_days = excluded.final_days,
    min_balance = excluded.min_balance, cycle_days = excluded.cycle_days,
    quiet_dow = excluded.quiet_dow, daily_cap = excluded.daily_cap,
    updated_at = now();

  s := public._khata_settings(v_shop);
  select * into pp from public.pharmacy_profiles where id = v_shop;
  return jsonb_build_object('ok', true,
    'collector', public._khata_collector_card(v_shop, s, pp),
    'message', public.ui_text('khata.settings_saved'));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_shop()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$ select public.pos_shop(); $function$
;

CREATE OR REPLACE FUNCTION public.khata_template_save(p_stage integer, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.khata_shop();
  v_body text := btrim(coalesce(p_body,''));
  t text; v_bad text;
begin
  if v_shop is null then return public._khata_denied(); end if;
  if p_stage not in (1,2,3) then
    return jsonb_build_object('ok', false, 'error', 'bad_stage',
      'message', public.ui_text('khata.err_bad_stage'));
  end if;
  if length(v_body) < 20 or length(v_body) > 700 then
    return jsonb_build_object('ok', false, 'error', 'bad_length',
      'message', public.ui_text('khata.err_tpl_length'));
  end if;
  foreach t in array public._khata_required_tokens() loop
    if position(t in v_body) = 0 then
      return jsonb_build_object('ok', false, 'error', 'missing_token',
        'message', public.khata_fmt('khata.err_tpl_token',
                     jsonb_build_object('token', t)));
    end if;
  end loop;
  -- A collection message may be firm. It may not threaten.
  select w into v_bad from unnest(array['police','court','case','legal action','fir',
                                        'goons','shame','defam','blacklist']) w
   where position(w in lower(v_body)) > 0 limit 1;
  if v_bad is not null then
    return jsonb_build_object('ok', false, 'error', 'not_allowed',
      'message', public.khata_fmt('khata.err_tpl_threat',
                   jsonb_build_object('word', v_bad)));
  end if;

  insert into public.khata_template(pharmacy_id, stage, body, updated_by)
  values (v_shop, p_stage, v_body, auth.uid())
  on conflict (coalesce(pharmacy_id, '00000000-0000-0000-0000-000000000000'::uuid), stage)
  do update set body = excluded.body, updated_by = excluded.updated_by, updated_at = now();

  return jsonb_build_object('ok', true, 'stage', p_stage, 'body', v_body,
    'message', public.ui_text('khata.tpl_saved'));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_upi_confirm(p_vpa text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.khata_shop(); pp public.pharmacy_profiles%rowtype;
begin
  if v_shop is null then return public._khata_denied(); end if;
  select * into pp from public.pharmacy_profiles where id = v_shop;
  if coalesce(pp.upi_vpa,'') = '' or lower(btrim(coalesce(p_vpa,''))) <> pp.upi_vpa then
    return jsonb_build_object('ok', false, 'error', 'vpa_mismatch',
      'message', public.ui_text('khata.err_vpa_mismatch'));
  end if;
  update public.pharmacy_profiles
     set upi_verified_at = now(), upi_verified_by = auth.uid()
   where id = v_shop;
  return jsonb_build_object('ok', true, 'verified', true,
    'message', public.ui_text('khata.upi_verified'));
end $function$
;

CREATE OR REPLACE FUNCTION public.khata_upi_save(p_vpa text, p_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.khata_shop(); v_vpa text;
begin
  if v_shop is null then return public._khata_denied(); end if;
  v_vpa := lower(btrim(coalesce(p_vpa,'')));
  if v_vpa !~ '^[a-z0-9._-]{2,64}@[a-z][a-z0-9.-]{1,32}$' then
    return jsonb_build_object('ok', false, 'error', 'bad_vpa',
      'message', public.ui_text('khata.err_bad_vpa'));
  end if;
  update public.pharmacy_profiles
     set upi_vpa = v_vpa,
         upi_vpa_name = nullif(btrim(coalesce(p_name,'')),''),
         upi_verified_at = null, upi_verified_by = null
   where id = v_shop;
  return jsonb_build_object('ok', true, 'vpa', v_vpa,
    'verified', false,
    'confirm_prompt', public.khata_fmt('khata.upi_confirm_prompt',
                        jsonb_build_object('vpa', v_vpa)),
    'message', public.ui_text('khata.upi_saved'));
end $function$
;
