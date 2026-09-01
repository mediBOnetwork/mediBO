-- CMD #417 — the repeat-sales engine: patient refills, the pharmacy's own
-- WhatsApp storefront, and the AI counter that answers from its shelf.
--
-- Three loops, one spine. All of it sits on work that already exists:
--   * POS (#411) gives the sale, the patient name/phone and pos_shop().
--   * khata (#415) gives the patient identity and the opt-in discipline.
--   * pharmacy_stock gives what is actually on the shelf right now.
--   * notify() (#297) gives the ONE outbound door, with the 24h service window
--     already tracked in wa_service_window — nothing here re-derives it.
--
-- Boundaries this file will not cross:
--   * A patient is messaged only when the PHARMACY opted that patient in, the
--     shop's engine is enabled, the frequency cap allows it and the day is not
--     a quiet day. Three independent gates, checked in the backend.
--   * Patient-facing surfaces (storefront page, AI counter) see MRP and
--     availability ONLY. unit_cost, PTR, supplier and margin never leave the
--     pharmacy side — the storefront RPCs are the fence.
--   * The AI counter answers from `storefront_ai_context()` and nothing else.
--     No stock match => it hands the conversation to the pharmacy. It has
--     exactly one write action: reserve.
--   * Every string is composed here and rendered verbatim. Dart computes
--     nothing.
--
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE CHRONIC LIST — admin-editable, never hardcoded in Dart or in a WHERE
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.refill_chronic_rule (
  id           bigserial primary key,
  label        text    not null,
  match_kind   text    not null default 'class',   -- class | molecule | name
  match_value  text    not null,
  dose_per_day numeric not null default 1,
  is_active    boolean not null default true,
  sort         integer not null default 100,
  updated_by   uuid,
  updated_at   timestamptz not null default now(),
  constraint refill_rule_kind_ck check (match_kind in ('class','molecule','name')),
  constraint refill_rule_dose_ck check (dose_per_day > 0)
);
create unique index if not exists refill_chronic_rule_uq
  on public.refill_chronic_rule (match_kind, lower(match_value));

insert into public.refill_chronic_rule(label, match_kind, match_value, dose_per_day, sort) values
  ('Blood pressure',      'class',    'antihypertensive',        1, 10),
  ('Blood pressure',      'molecule', 'telmisartan',             1, 11),
  ('Blood pressure',      'molecule', 'amlodipine',              1, 12),
  ('Blood pressure',      'molecule', 'losartan',                1, 13),
  ('Diabetes',            'class',    'anti diabetic',           2, 20),
  ('Diabetes',            'molecule', 'metformin',               2, 21),
  ('Diabetes',            'molecule', 'glimepiride',             1, 22),
  ('Thyroid',             'molecule', 'thyroxine',               1, 30),
  ('Cholesterol',         'molecule', 'atorvastatin',            1, 40),
  ('Cholesterol',         'molecule', 'rosuvastatin',            1, 41),
  ('Heart',               'molecule', 'clopidogrel',             1, 50),
  ('Acidity (long term)', 'molecule', 'pantoprazole',            1, 60),
  ('Asthma / COPD',       'class',    'respiratory',             1, 70),
  ('Epilepsy',            'molecule', 'levetiracetam',           2, 80)
on conflict do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. THE PHARMACY'S SETTINGS — opt-in, lead time, and the caps
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.refill_settings (
  pharmacy_id   uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  enabled       boolean not null default false,  -- the shop says so, or nobody is messaged
  lead_days     integer not null default 3,      -- nudge this many days before run-out
  min_gap_days  integer not null default 20,     -- frequency cap, per patient
  daily_cap     integer not null default 30,     -- per shop, per day
  quiet_dow     integer[] not null default '{0}',-- 0 = Sunday
  ai_enabled    boolean not null default true,
  updated_at    timestamptz not null default now()
);

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE PATIENT — one identity per phone per pharmacy. PII stays with the
--    pharmacy that wrote it down: RLS on, zero policies, definer RPCs only.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.refill_patient (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  phone         text not null,                    -- 10 digits
  name          text,
  opted_in      boolean not null default false,
  opted_in_at   timestamptz,
  opted_out_at  timestamptz,
  source        text not null default 'pos',      -- pos | khata | storefront
  last_nudge_on date,
  nudge_count   integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists refill_patient_uq
  on public.refill_patient (pharmacy_id, phone);
create index if not exists refill_patient_shop_ix
  on public.refill_patient (pharmacy_id, opted_in, updated_at desc);

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE SCHEDULE — one per patient per item. days_supply is pack units ×
--    packs ÷ dose, and BOTH inputs are editable per patient (the spec's
--    "dose assumption, editable per patient").
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.refill_schedule (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  patient_id     uuid not null references public.refill_patient(id) on delete cascade,
  medicine_id    bigint,
  item_key       text not null,                   -- lower(product_name) when no id
  product_name   text not null,
  pack_label     text,
  rule_label     text,
  pack_units     numeric not null default 10,
  dose_per_day   numeric not null default 1,
  qty_packs      numeric not null default 1,
  days_supply    integer not null default 30,
  last_sold_on   date    not null,
  last_sale_id   uuid,
  runs_out_on    date    not null,
  status         text    not null default 'active',  -- active | paused | done
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint refill_schedule_status_ck check (status in ('active','paused','done')),
  constraint refill_schedule_dose_ck check (dose_per_day > 0),
  constraint refill_schedule_units_ck check (pack_units > 0)
);
create unique index if not exists refill_schedule_uq
  on public.refill_schedule (pharmacy_id, patient_id, item_key);
create index if not exists refill_schedule_due_ix
  on public.refill_schedule (pharmacy_id, status, runs_out_on);

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. THE OFFER — the state behind "reply 1 to reserve". A reply is only ever
--    read as a refill when THIS shop asked this phone, recently.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.refill_offer (
  id           uuid primary key default gen_random_uuid(),
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  patient_id   uuid not null references public.refill_patient(id) on delete cascade,
  schedule_id  uuid references public.refill_schedule(id) on delete set null,
  phone        text not null,
  status       text not null default 'open',      -- open | accepted | declined | expired
  expires_at   timestamptz not null default (now() + interval '7 days'),
  reservation_id uuid,
  created_at   timestamptz not null default now(),
  answered_at  timestamptz,
  constraint refill_offer_status_ck check (status in ('open','accepted','declined','expired'))
);
create index if not exists refill_offer_open_ix
  on public.refill_offer (phone, status, created_at desc);

create table if not exists public.refill_nudge_log (
  id          bigserial primary key,
  pharmacy_id uuid not null,
  patient_id  uuid,
  schedule_id uuid,
  offer_id    uuid,
  sent_on     date not null default (now() at time zone 'Asia/Kolkata')::date,
  dedupe_key  text unique,
  channel     text not null default 'whatsapp',
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists refill_nudge_shop_ix
  on public.refill_nudge_log (pharmacy_id, sent_on desc);

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. THE RESERVATION — what both loops produce and the counter hands over.
--    Deliberately NOT a pos_sales row: an invoice number is claimed when the
--    medicine is actually handed over, never when a patient says "hold it".
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.pos_reservation (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  source        text not null default 'refill',   -- refill | storefront | counter_ai
  patient_id    uuid references public.refill_patient(id) on delete set null,
  patient_name  text,
  patient_phone text,
  lines         jsonb not null default '[]'::jsonb,
  note          text,
  status        text not null default 'open',     -- open | billed | cancelled
  sale_id       uuid references public.pos_sales(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  billed_at     timestamptz,
  constraint pos_reservation_status_ck check (status in ('open','billed','cancelled')),
  constraint pos_reservation_source_ck check (source in ('refill','storefront','counter_ai'))
);
create index if not exists pos_reservation_queue_ix
  on public.pos_reservation (pharmacy_id, status, created_at desc);

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. THE STOREFRONT — one share token per pharmacy, and the phone→pharmacy
--    binding the AI counter needs (one WABA number serves every pharmacy, so
--    the token in the first message is what says WHOSE shelf to answer from).
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.pharmacy_storefront (
  pharmacy_id   uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  token         text not null unique,
  is_active     boolean not null default true,
  display_name  text,
  greeting      text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.storefront_session (
  phone        text primary key,
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  source       text not null default 'link',
  bound_at     timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);

create table if not exists public.storefront_request (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  source        text not null default 'link',      -- link | counter_ai
  patient_name  text,
  phone         text,
  items         jsonb not null default '[]'::jsonb,
  note          text,
  status        text not null default 'new',       -- new | reserved | cancelled
  reservation_id uuid references public.pos_reservation(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists storefront_request_shop_ix
  on public.storefront_request (pharmacy_id, status, created_at desc);

create table if not exists public.storefront_conversation (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  phone         text not null,
  started_at    timestamptz not null default now(),
  last_at       timestamptz not null default now(),
  message_count integer not null default 0,
  handoff       boolean not null default false
);
create unique index if not exists storefront_conversation_uq
  on public.storefront_conversation (pharmacy_id, phone);

create table if not exists public.storefront_message (
  id              bigserial primary key,
  conversation_id uuid not null references public.storefront_conversation(id) on delete cascade,
  pharmacy_id     uuid not null,
  phone           text not null,
  direction       text not null,                  -- in | out
  body            text not null default '',
  intent          text,                           -- availability | price | reserve | handoff | other
  grounded        boolean not null default true,
  detail          jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  constraint storefront_message_dir_ck check (direction in ('in','out'))
);
create index if not exists storefront_message_conv_ix
  on public.storefront_message (conversation_id, created_at desc);

-- RLS on, zero policies: nothing reaches these tables except the SECURITY
-- DEFINER RPCs below, each of which filters to one pharmacy. Same PII fence
-- khata (#415) draws.
do $$
declare t text;
begin
  foreach t in array array['refill_chronic_rule','refill_settings','refill_patient',
                           'refill_schedule','refill_offer','refill_nudge_log',
                           'pos_reservation','pharmacy_storefront','storefront_session',
                           'storefront_request','storefront_conversation','storefront_message']
  loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. THE COPY. Every word a pharmacy, a patient or an admin reads is here.
--    Changing wording is an UPDATE, never a deploy.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy(key, value) values
 ('refill.title',            to_jsonb('Refills & counter'::text)),
 ('refill.tab_due',          to_jsonb('Due soon'::text)),
 ('refill.tab_patients',     to_jsonb('Patients'::text)),
 ('refill.tab_requests',     to_jsonb('Requests'::text)),
 ('refill.tab_counter',      to_jsonb('AI counter'::text)),
 ('refill.engine_title',     to_jsonb('Refill reminders'::text)),
 ('refill.engine_toggle',    to_jsonb('Send refill reminders'::text)),
 ('refill.engine_off',       to_jsonb('Off — no patient is messaged'::text)),
 ('refill.engine_on',        to_jsonb('On — reminder goes out {lead} days before a patient runs out'::text)),
 ('refill.cap_label',        to_jsonb('At most one reminder per patient every {gap} days'::text)),
 ('refill.daily_label',      to_jsonb('At most {n} reminders a day'::text)),
 ('refill.quiet_label',      to_jsonb('Nothing goes out on Sunday'::text)),
 ('refill.sent_today',       to_jsonb('{n} sent today'::text)),
 ('refill.optin_on',         to_jsonb('Reminders on'::text)),
 ('refill.optin_off',        to_jsonb('Reminders off'::text)),
 ('refill.optin_hint',       to_jsonb('Ask the patient at the counter before you turn this on.'::text)),
 ('refill.runs_out_on',      to_jsonb('Runs out {date}'::text)),
 ('refill.ran_out_on',       to_jsonb('Ran out {date}'::text)),
 ('refill.runs_out_today',   to_jsonb('Runs out today'::text)),
 ('refill.days_left',        to_jsonb('{n} days left'::text)),
 ('refill.dose_label',       to_jsonb('{n} a day'::text)),
 ('refill.pack_label',       to_jsonb('{n} per pack'::text)),
 ('refill.last_bought',      to_jsonb('Last bought {date}'::text)),
 ('refill.nudge_label',      to_jsonb('Send reminder'::text)),
 ('refill.nudge_sent',       to_jsonb('Reminder sent to {name}'::text)),
 ('refill.err_not_found',    to_jsonb('Not found'::text)),
 ('refill.err_denied',       to_jsonb('Only the pharmacy can open this'::text)),
 ('refill.err_optin',        to_jsonb('This patient has not opted in'::text)),
 ('refill.err_engine_off',   to_jsonb('Turn refill reminders on first'::text)),
 ('refill.err_no_phone',     to_jsonb('No WhatsApp number on this patient'::text)),
 ('refill.err_too_soon',     to_jsonb('Already reminded — next reminder allowed in {n} days'::text)),
 ('refill.err_daily_cap',    to_jsonb('Daily reminder limit reached'::text)),
 ('refill.err_quiet',        to_jsonb('Quiet day — nothing goes out today'::text)),
 ('refill.empty_due',        to_jsonb('No refill is due yet. Bill a chronic medicine and a schedule builds itself.'::text)),
 ('refill.empty_patients',   to_jsonb('No patients yet. Every POS bill with a phone number becomes one.'::text)),
 ('refill.empty_requests',   to_jsonb('No requests yet. Share your storefront link and they land here.'::text)),
 ('refill.empty_counter',    to_jsonb('No conversations yet. Patients who message your link start one.'::text)),
 ('refill.scan_label',       to_jsonb('Rebuild from bills'::text)),
 ('refill.scan_done',        to_jsonb('{n} refill schedules updated'::text)),
 ('refill.rules_title',      to_jsonb('Chronic medicines'::text)),
 ('refill.rules_hint',       to_jsonb('A bill line matching any of these builds a refill schedule.'::text)),
 -- the patient-facing sentence, template-shaped
 ('refill.wa_body',          to_jsonb('Namaste {patient}, your {product} from {shop} runs out on {date}. Reply 1 and we will keep it ready for pickup. Reply STOP to stop these reminders.'::text)),
 ('refill.wa_reserved',      to_jsonb('Done — {shop} has reserved {product} for you. Please collect it at the counter.'::text)),
 ('refill.wa_nothing',       to_jsonb('You have no refill waiting right now.'::text)),
 ('refill.wa_stopped',       to_jsonb('Stopped. You will not get refill reminders from this pharmacy again.'::text)),
 -- storefront
 ('storefront.title',        to_jsonb('WhatsApp storefront'::text)),
 ('storefront.hint',         to_jsonb('Share this link or QR. Patients see what you have in stock and ask you to keep it ready.'::text)),
 ('storefront.link_label',   to_jsonb('Your storefront link'::text)),
 ('storefront.copy_label',   to_jsonb('Copy link'::text)),
 ('storefront.active_label', to_jsonb('Storefront open'::text)),
 ('storefront.closed_label', to_jsonb('Storefront closed'::text)),
 ('storefront.ai_label',     to_jsonb('Answer patient messages automatically'::text)),
 ('storefront.ai_hint',      to_jsonb('Answers only from your stock. Anything else is handed to you.'::text)),
 ('storefront.search_hint',  to_jsonb('Search medicines'::text)),
 ('storefront.in_stock',     to_jsonb('In stock'::text)),
 ('storefront.mrp_label',    to_jsonb('MRP {amount}'::text)),
 ('storefront.add_label',    to_jsonb('Add'::text)),
 ('storefront.added_label',  to_jsonb('Added'::text)),
 ('storefront.cart_label',   to_jsonb('{n} item request'::text)),
 ('storefront.name_hint',    to_jsonb('Your name'::text)),
 ('storefront.phone_hint',   to_jsonb('WhatsApp number'::text)),
 ('storefront.note_hint',    to_jsonb('Anything else? (optional)'::text)),
 ('storefront.submit_label', to_jsonb('Ask the pharmacy to keep it ready'::text)),
 ('storefront.thanks_title', to_jsonb('Request sent'::text)),
 ('storefront.thanks_body',  to_jsonb('{shop} will keep your items ready. You will get a WhatsApp when they are.'::text)),
 ('storefront.closed_body',  to_jsonb('This storefront is closed right now. Please call the pharmacy.'::text)),
 ('storefront.not_found',    to_jsonb('This link is not valid any more.'::text)),
 ('storefront.empty',        to_jsonb('Nothing in stock matches that.'::text)),
 ('storefront.err_phone',    to_jsonb('Please enter a 10-digit WhatsApp number'::text)),
 ('storefront.err_items',    to_jsonb('Add at least one medicine'::text)),
 ('storefront.req_new',      to_jsonb('New request'::text)),
 ('storefront.req_reserved', to_jsonb('Reserved'::text)),
 ('storefront.req_cancelled',to_jsonb('Cancelled'::text)),
 ('storefront.reserve_label',to_jsonb('Keep ready'::text)),
 ('storefront.cancel_label', to_jsonb('Cancel'::text)),
 ('storefront.reserved_toast', to_jsonb('Reserved — it is in the counter queue'::text)),
 -- AI counter
 ('counter.greeting',        to_jsonb('Namaste! This is {shop} on mediBO. Ask me about a medicine and I will tell you what we have in stock.'::text)),
 ('counter.handoff',         to_jsonb('Let me pass this to {shop} — someone from the pharmacy will reply shortly.'::text)),
 ('counter.not_stocked',     to_jsonb('Sorry, {shop} does not have that in stock right now. The pharmacy will confirm.'::text)),
 ('counter.reserved',        to_jsonb('Reserved at {shop}. Please collect at the counter.'::text)),
 ('counter.title',           to_jsonb('Conversations'::text)),
 ('counter.msg_count',       to_jsonb('{n} messages'::text)),
 ('counter.handoff_label',   to_jsonb('Handed to you'::text)),
 ('counter.auto_label',      to_jsonb('Answered automatically'::text)),
 ('reservation.title',       to_jsonb('Reserved for pickup'::text)),
 ('reservation.queue_label', to_jsonb('{n} waiting'::text)),
 ('reservation.bill_label',  to_jsonb('Bill it'::text)),
 ('reservation.source_refill',    to_jsonb('Refill reminder'::text)),
 ('reservation.source_storefront',to_jsonb('Storefront'::text)),
 ('reservation.source_counter_ai',to_jsonb('AI counter'::text)),
 ('reservation.empty',       to_jsonb('Nothing reserved right now.'::text))
on conflict (key) do nothing;

alter table public.refill_schedule
  add column if not exists dose_edited boolean not null default false;

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. HELPERS
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.refill_shop()
returns uuid language sql stable security definer set search_path to 'public'
as $$ select public.pos_shop(); $$;

create or replace function public._c417_today()
returns date language sql stable
as $$ select (now() at time zone 'Asia/Kolkata')::date; $$;

create or replace function public._c417_denied()
returns jsonb language sql stable security definer set search_path to 'public'
as $$ select jsonb_build_object('ok', false, 'error', 'not_authorized',
        'message', public.ui_text('refill.err_denied')); $$;

create or replace function public._c417_fmt(p_key text, p_vars jsonb)
returns text language sql stable security definer set search_path to 'public'
as $$ select public.ui_fmt(p_key, p_vars); $$;

-- settings, created on first read so a shop never sees a null card
create or replace function public._c417_settings(p_shop uuid)
returns public.refill_settings language plpgsql security definer
set search_path to 'public' as $$
declare s public.refill_settings%rowtype;
begin
  select * into s from public.refill_settings where pharmacy_id = p_shop;
  if not found then
    insert into public.refill_settings(pharmacy_id) values (p_shop)
    on conflict (pharmacy_id) do nothing;
    select * into s from public.refill_settings where pharmacy_id = p_shop;
  end if;
  return s;
end $$;

-- how many units are in one pack. MEDICINE.pack_qty when it is a number,
-- else the first number printed on the pack label, else ten.
create or replace function public._c417_pack_units(p_medicine bigint, p_pack text)
returns numeric language plpgsql stable security definer
set search_path to 'public' as $$
declare v text; v_n numeric;
begin
  if p_medicine is not null then
    select pack_qty into v from public."MEDICINE" where id = p_medicine;
    v_n := nullif(regexp_replace(coalesce(v,''), '\D', '', 'g'), '')::numeric;
    if coalesce(v_n,0) > 0 then return least(v_n, 500); end if;
  end if;
  v_n := nullif(regexp_replace(coalesce(p_pack,''), '\D', '', 'g'), '')::numeric;
  if coalesce(v_n,0) > 0 then return least(v_n, 500); end if;
  return 10;
end $$;

-- the chronic list, applied. Returns the winning rule or nothing at all.
create or replace function public._c417_rule(p_medicine bigint, p_name text)
returns public.refill_chronic_rule language plpgsql stable security definer
set search_path to 'public' as $$
declare r public.refill_chronic_rule%rowtype; m public."MEDICINE"%rowtype;
begin
  if p_medicine is not null then
    select * into m from public."MEDICINE" where id = p_medicine;
  end if;
  select * into r from public.refill_chronic_rule c
   where c.is_active
     and ((c.match_kind = 'name'
            and coalesce(p_name, m.product_name, '') ilike '%'||c.match_value||'%')
       or (c.match_kind = 'molecule'
            and coalesce(m.salt_composition,'') ilike '%'||c.match_value||'%')
       or (c.match_kind = 'class'
            and coalesce(m.therapeutic_class,'') ilike '%'||c.match_value||'%'))
   order by c.sort, c.id
   limit 1;
  return r;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. THE SCAN — bills become schedules. Runs on demand and nightly.
--     A dose the pharmacy edited is never overwritten by a later bill.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._c417_scan_shop(p_shop uuid, p_days integer default 180)
returns integer language plpgsql security definer set search_path to 'public' as $$
declare
  v_row record; r public.refill_chronic_rule%rowtype;
  v_patient uuid; v_units numeric; v_dose numeric; v_days integer;
  v_key text; v_n integer := 0; v_ph text;
begin
  for v_row in
    select s.id sale_id, s.sold_on, s.patient_name, s.patient_phone,
           l.medicine_id, l.product_name, l.pack_label, l.qty
      from public.pos_sales s
      join public.pos_sale_lines l on l.sale_id = s.id
     where s.pharmacy_id = p_shop
       and coalesce(s.status,'final') <> 'cancelled'
       and s.sold_on >= public._c417_today() - p_days
       and length(regexp_replace(coalesce(s.patient_phone,''), '\D', '', 'g')) >= 10
     order by s.sold_on
  loop
    r := public._c417_rule(v_row.medicine_id, v_row.product_name);
    if r.id is null then continue; end if;

    v_ph := right(regexp_replace(v_row.patient_phone, '\D', '', 'g'), 10);

    insert into public.refill_patient(pharmacy_id, phone, name, source)
    values (p_shop, v_ph, nullif(btrim(coalesce(v_row.patient_name,'')),''), 'pos')
    on conflict (pharmacy_id, phone) do update
      set name = coalesce(public.refill_patient.name, excluded.name),
          updated_at = now()
    returning id into v_patient;
    if v_patient is null then
      select id into v_patient from public.refill_patient
       where pharmacy_id = p_shop and phone = v_ph;
    end if;

    v_units := public._c417_pack_units(v_row.medicine_id, v_row.pack_label);
    v_dose  := r.dose_per_day;
    v_key   := coalesce(v_row.medicine_id::text, lower(btrim(v_row.product_name)));
    v_days  := greatest(1, floor(v_units * greatest(coalesce(v_row.qty,1),1) / v_dose)::int);

    insert into public.refill_schedule(
        pharmacy_id, patient_id, medicine_id, item_key, product_name, pack_label,
        rule_label, pack_units, dose_per_day, qty_packs, days_supply,
        last_sold_on, last_sale_id, runs_out_on, status)
    values (p_shop, v_patient, v_row.medicine_id, v_key, v_row.product_name,
            v_row.pack_label, r.label, v_units, v_dose,
            greatest(coalesce(v_row.qty,1),1), v_days,
            v_row.sold_on, v_row.sale_id, v_row.sold_on + v_days, 'active')
    on conflict (pharmacy_id, patient_id, item_key) do update
      set product_name = excluded.product_name,
          pack_label   = excluded.pack_label,
          rule_label   = excluded.rule_label,
          medicine_id  = coalesce(excluded.medicine_id, public.refill_schedule.medicine_id),
          -- an edited dose or pack size is the pharmacy's, not the catalogue's
          pack_units   = case when public.refill_schedule.dose_edited
                              then public.refill_schedule.pack_units else excluded.pack_units end,
          dose_per_day = case when public.refill_schedule.dose_edited
                              then public.refill_schedule.dose_per_day else excluded.dose_per_day end,
          qty_packs    = excluded.qty_packs,
          days_supply  = greatest(1, floor(
                           (case when public.refill_schedule.dose_edited
                                 then public.refill_schedule.pack_units else excluded.pack_units end)
                           * excluded.qty_packs /
                           (case when public.refill_schedule.dose_edited
                                 then public.refill_schedule.dose_per_day else excluded.dose_per_day end))::int),
          last_sold_on = greatest(public.refill_schedule.last_sold_on, excluded.last_sold_on),
          last_sale_id = excluded.last_sale_id,
          runs_out_on  = greatest(public.refill_schedule.last_sold_on, excluded.last_sold_on)
                         + greatest(1, floor(
                             (case when public.refill_schedule.dose_edited
                                   then public.refill_schedule.pack_units else excluded.pack_units end)
                             * excluded.qty_packs /
                             (case when public.refill_schedule.dose_edited
                                   then public.refill_schedule.dose_per_day else excluded.dose_per_day end))::int),
          status       = case when public.refill_schedule.status = 'paused' then 'paused' else 'active' end,
          updated_at   = now()
     where public.refill_schedule.last_sold_on <= excluded.last_sold_on;

    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.refill_scan(p_days integer default 180)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.refill_shop(); v_n integer;
begin
  if v_shop is null then return public._c417_denied(); end if;
  v_n := public._c417_scan_shop(v_shop, coalesce(p_days,180));
  return jsonb_build_object('ok', true, 'updated', v_n,
    'message', public._c417_fmt('refill.scan_done', jsonb_build_object('n', v_n::text)));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 11. THE OUTBOUND ROUTE. notify() is the only door — it already knows the
--     24h service window (#297) and prefers the approved template over
--     free-form, which is exactly the "approved wording only" rule.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.wa_event_template_seeds(name, category, language, components, token_map) values
 ('refill_due', 'UTILITY', 'en',
  jsonb_build_array(
    jsonb_build_object('type','BODY',
      'text','Namaste {{1}}, your {{2}} from {{3}} runs out on {{4}}. Reply 1 and we will keep it ready for pickup.',
      'example', jsonb_build_object('body_text', jsonb_build_array(
                   jsonb_build_array('Ramesh','Telma 40','Jai Medical Store','Thursday, 04 Sep')))),
    jsonb_build_object('type','FOOTER','text','Reply STOP to stop these reminders')),
  jsonb_build_array('patient','product','shop','date')),
 ('refill_reserved', 'UTILITY', 'en',
  jsonb_build_array(
    jsonb_build_object('type','BODY',
      'text','Done — {{1}} has reserved {{2}} for you. Please collect it at the counter.',
      'example', jsonb_build_object('body_text', jsonb_build_array(
                   jsonb_build_array('Jai Medical Store','Telma 40')))),
    jsonb_build_object('type','FOOTER','text','mediBO')),
  jsonb_build_array('shop','product'))
on conflict (name) do nothing;

insert into public.wa_event_routes(event_key, label, description, language, variable_map,
                                   enabled, auto_template_name, auto_manage, wa_category,
                                   dedupe_minutes, marketing_guard, audience)
values
 ('refill_due', 'Refill reminder',
  'CMD #417 — the pharmacy''s chronic-refill reminder to its own patient. Reply 1 reserves it.',
  'en', jsonb_build_array('{{patient}}','{{product}}','{{shop}}','{{date}}'),
  true, 'refill_due', true, 'utility', 1440, true, 'customer'),
 ('refill_reserved', 'Refill reserved',
  'CMD #417 — confirmation that the pharmacy is holding the item for pickup.',
  'en', jsonb_build_array('{{shop}}','{{product}}'),
  true, 'refill_reserved', true, 'utility', 60, true, 'customer')
on conflict (event_key) do update
  set enabled = true, variable_map = excluded.variable_map,
      description = excluded.description, wa_category = excluded.wa_category;

-- ═══════════════════════════════════════════════════════════════════════════
-- 12. THE SEND. Three gates before a patient is ever messaged: the shop's
--     engine, the patient's opt-in, and the caps (gap, daily, quiet day).
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._c417_shop_name(p_shop uuid)
returns text language sql stable security definer set search_path to 'public'
as $$ select coalesce(nullif(btrim(sf.display_name),''),
                      nullif(btrim(p.pharmacy_name),''),
                      nullif(btrim(p.customer_name),''), 'your pharmacy')
       from public.pharmacy_profiles p
       left join public.pharmacy_storefront sf on sf.pharmacy_id = p.id
      where p.id = p_shop; $$;

create or replace function public._c417_send(p_shop uuid, p_schedule uuid,
                                             p_manual boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  sc public.refill_schedule%rowtype; pt public.refill_patient%rowtype;
  s public.refill_settings%rowtype; v_sent int; v_key text; v_log bigint;
  v_offer uuid; v_res jsonb; v_shop_name text; v_date text;
begin
  select * into sc from public.refill_schedule
   where id = p_schedule and pharmacy_id = p_shop for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason','not_found',
      'message', public.ui_text('refill.err_not_found'));
  end if;
  s := public._c417_settings(p_shop);
  select * into pt from public.refill_patient where id = sc.patient_id;

  if not s.enabled then
    return jsonb_build_object('ok', false, 'reason','engine_off',
      'message', public.ui_text('refill.err_engine_off'));
  end if;
  if not coalesce(pt.opted_in,false) then
    return jsonb_build_object('ok', false, 'reason','not_opted_in',
      'message', public.ui_text('refill.err_optin'));
  end if;
  if length(coalesce(pt.phone,'')) <> 10 then
    return jsonb_build_object('ok', false, 'reason','no_phone',
      'message', public.ui_text('refill.err_no_phone'));
  end if;
  if sc.status <> 'active' then
    return jsonb_build_object('ok', false, 'reason','paused');
  end if;
  if not p_manual
     and extract(dow from public._c417_today())::int = any (s.quiet_dow) then
    return jsonb_build_object('ok', false, 'reason','quiet_day',
      'message', public.ui_text('refill.err_quiet'));
  end if;
  if pt.last_nudge_on is not null
     and public._c417_today() - pt.last_nudge_on < s.min_gap_days then
    return jsonb_build_object('ok', false, 'reason','too_soon',
      'message', public._c417_fmt('refill.err_too_soon', jsonb_build_object(
        'n', (s.min_gap_days - (public._c417_today() - pt.last_nudge_on))::text)));
  end if;
  select count(*) into v_sent from public.refill_nudge_log
   where pharmacy_id = p_shop and sent_on = public._c417_today();
  if v_sent >= s.daily_cap then
    return jsonb_build_object('ok', false, 'reason','daily_cap',
      'message', public.ui_text('refill.err_daily_cap'));
  end if;

  v_key := sc.id::text || ':' || sc.runs_out_on::text;
  insert into public.refill_nudge_log(pharmacy_id, patient_id, schedule_id,
                                      dedupe_key, detail)
  values (p_shop, pt.id, sc.id, v_key,
          jsonb_build_object('manual', p_manual, 'status','claimed'))
  on conflict (dedupe_key) do nothing
  returning id into v_log;
  if v_log is null then
    return jsonb_build_object('ok', false, 'reason','already_sent');
  end if;

  -- close any older open offer for this schedule, then open exactly one
  update public.refill_offer set status = 'expired', answered_at = now()
   where phone = pt.phone and status = 'open';
  insert into public.refill_offer(pharmacy_id, patient_id, schedule_id, phone)
  values (p_shop, pt.id, sc.id, pt.phone)
  returning id into v_offer;

  update public.refill_patient
     set last_nudge_on = public._c417_today(),
         nudge_count = nudge_count + 1, updated_at = now()
   where id = pt.id;

  -- the storefront binding: this phone is now talking to THIS pharmacy
  insert into public.storefront_session(phone, pharmacy_id, source)
  values (pt.phone, p_shop, 'refill')
  on conflict (phone) do update
    set pharmacy_id = excluded.pharmacy_id, last_seen_at = now();

  v_shop_name := public._c417_shop_name(p_shop);
  v_date := to_char(sc.runs_out_on, 'FMDay, DD Mon');

  v_res := public.notify('refill_due', pt.phone, jsonb_build_object(
    'patient', coalesce(pt.name, ''),
    'product', sc.product_name,
    'shop',    v_shop_name,
    'date',    v_date,
    'channel', 'whatsapp'));

  update public.refill_nudge_log
     set offer_id = v_offer,
         detail = detail || jsonb_build_object('notify', v_res, 'status','sent',
                    'body', public._c417_fmt('refill.wa_body', jsonb_build_object(
                      'patient', coalesce(pt.name,''), 'product', sc.product_name,
                      'shop', v_shop_name, 'date', v_date)))
   where id = v_log;

  return jsonb_build_object('ok', true, 'offer_id', v_offer, 'notify', v_res,
    'message', public._c417_fmt('refill.nudge_sent',
                 jsonb_build_object('name', coalesce(pt.name, pt.phone))));
end $$;

create or replace function public.refill_nudge_now(p_schedule_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.refill_shop();
begin
  if v_shop is null then return public._c417_denied(); end if;
  return public._c417_send(v_shop, p_schedule_id, true);
end $$;

-- the nightly sweep: every shop that asked for it, every schedule inside the
-- lead window, one at a time, all caps honoured.
create or replace function public.refill_send_due(p_limit integer default 200)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_row record; v_res jsonb; v_sent int := 0; v_seen int := 0;
begin
  for v_row in
    select sc.id, sc.pharmacy_id
      from public.refill_schedule sc
      join public.refill_settings s on s.pharmacy_id = sc.pharmacy_id and s.enabled
      join public.refill_patient p on p.id = sc.patient_id and p.opted_in
     where sc.status = 'active'
       and sc.runs_out_on <= public._c417_today() + s.lead_days
       and sc.runs_out_on >= public._c417_today() - 14
       and not (extract(dow from public._c417_today())::int = any (s.quiet_dow))
     order by sc.runs_out_on
     limit greatest(coalesce(p_limit,200), 1)
  loop
    v_seen := v_seen + 1;
    v_res := public._c417_send(v_row.pharmacy_id, v_row.id, false);
    if coalesce((v_res->>'ok')::boolean,false) then v_sent := v_sent + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'considered', v_seen, 'sent', v_sent);
end $$;

-- the nightly rebuild, for every shop with the engine on
create or replace function public.refill_scan_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_row record; v_n int := 0; v_shops int := 0;
begin
  for v_row in select pharmacy_id from public.refill_settings where enabled loop
    v_shops := v_shops + 1;
    v_n := v_n + public._c417_scan_shop(v_row.pharmacy_id, 180);
  end loop;
  return jsonb_build_object('ok', true, 'shops', v_shops, 'lines', v_n);
end $$;

insert into public.cron_task(name, ord, mode, work_sql, enabled, note,
                             base_interval_s, max_interval_s, run_at_ist, dml)
values
 ('c417-refill-scan', 660, 'poll', 'select public.refill_scan_sweep()', true,
  'CMD #417 — rebuilds chronic refill schedules from POS bills for every pharmacy that turned reminders on.',
  3600, 21600, '05:40', true),
 ('c417-refill-send', 661, 'poll', 'select public.refill_send_due(200)', true,
  'CMD #417 — sends the refill reminder to patients inside the lead window. Caps and quiet days are enforced in the RPC.',
  3600, 21600, '10:20', true)
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = true, note = excluded.note,
      base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      run_at_ist = excluded.run_at_ist;

-- ═══════════════════════════════════════════════════════════════════════════
-- 13. THE RESERVATION — one writer, used by all three loops.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._c417_stock_line(p_shop uuid, p_medicine bigint,
                                                   p_name text, p_qty numeric)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v record;
begin
  select st.medicine_id, st.product_name, st.pack_label,
         sum(st.qty) qty, max(st.mrp) mrp
    into v
    from public.pharmacy_stock st
   where st.pharmacy_id = p_shop
     and st.qty > 0
     and ((p_medicine is not null and st.medicine_id = p_medicine)
       or (p_medicine is null and st.product_name ilike '%'||coalesce(p_name,'')||'%'))
   group by st.medicine_id, st.product_name, st.pack_label
   order by sum(st.qty) desc
   limit 1;
  if v.product_name is null then return null; end if;
  return jsonb_build_object(
    'medicine_id', v.medicine_id,
    'product_name', v.product_name,
    'pack_label', v.pack_label,
    'qty', greatest(coalesce(p_qty,1),1),
    'mrp', v.mrp,
    'mrp_display', case when v.mrp is null then null else public.inr_money(v.mrp) end,
    'in_stock', v.qty > 0);
end $$;

create or replace function public._c417_reserve(p_shop uuid, p_patient uuid, p_phone text,
                                                p_name text, p_lines jsonb,
                                                p_source text, p_note text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  insert into public.pos_reservation(pharmacy_id, source, patient_id, patient_name,
                                     patient_phone, lines, note)
  values (p_shop, p_source, p_patient, nullif(btrim(coalesce(p_name,'')),''),
          nullif(right(regexp_replace(coalesce(p_phone,''), '\D','','g'),10),''),
          coalesce(p_lines,'[]'::jsonb), nullif(btrim(coalesce(p_note,'')),''))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public._c417_reservation_json(r public.pos_reservation)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'id', r.id,
    'source', r.source,
    'source_label', public.ui_text('reservation.source_' || r.source),
    'patient_name', coalesce(r.patient_name, r.patient_phone, ''),
    'patient_phone', r.patient_phone,
    'note', r.note,
    'status', r.status,
    'lines', r.lines,
    'line_count', jsonb_array_length(coalesce(r.lines,'[]'::jsonb)),
    'items_label', (select string_agg(
                      (l->>'product_name') ||
                      case when coalesce((l->>'qty')::numeric,1) > 1
                           then ' × ' || (l->>'qty') else '' end, ', ')
                     from jsonb_array_elements(coalesce(r.lines,'[]'::jsonb)) l),
    'age_label', public._c417_fmt('reservation.queue_label',
                   jsonb_build_object('n','1')),
    'created_label', to_char(r.created_at at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM'),
    'bill_label', public.ui_text('reservation.bill_label'),
    'cancel_label', public.ui_text('storefront.cancel_label'));
$$;

-- the POS-side queue. Rendered by the counter, billed with one tap.
create or replace function public.pos_reservations(p_status text default 'open')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := public.refill_shop(); v_rows jsonb; v_n int;
begin
  if v_shop is null then return public._c417_denied(); end if;
  select coalesce(jsonb_agg(public._c417_reservation_json(r) order by r.created_at desc), '[]'::jsonb),
         count(*)
    into v_rows, v_n
    from public.pos_reservation r
   where r.pharmacy_id = v_shop
     and r.status = coalesce(nullif(p_status,''), 'open');
  return jsonb_build_object('ok', true,
    'title', public.ui_text('reservation.title'),
    'count', v_n,
    'count_label', public._c417_fmt('reservation.queue_label', jsonb_build_object('n', v_n::text)),
    'empty_label', public.ui_text('reservation.empty'),
    'rows', v_rows);
end $$;

-- "Bill it" — the counter gets the lines back, priced by the POS itself.
create or replace function public.pos_reservation_take(p_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.refill_shop(); r public.pos_reservation%rowtype;
begin
  if v_shop is null then return public._c417_denied(); end if;
  select * into r from public.pos_reservation
   where id = p_id and pharmacy_id = v_shop for update;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.ui_text('refill.err_not_found'));
  end if;
  return jsonb_build_object('ok', true, 'id', r.id,
    'patient', jsonb_build_object('name', r.patient_name, 'phone', r.patient_phone),
    'lines', r.lines);
end $$;

create or replace function public.pos_reservation_close(p_id uuid, p_status text,
                                                        p_sale_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.refill_shop(); r public.pos_reservation%rowtype;
begin
  if v_shop is null then return public._c417_denied(); end if;
  if coalesce(p_status,'') not in ('billed','cancelled') then
    return jsonb_build_object('ok', false, 'error','bad_status');
  end if;
  update public.pos_reservation
     set status = p_status, sale_id = coalesce(p_sale_id, sale_id),
         billed_at = case when p_status = 'billed' then now() else billed_at end,
         updated_at = now()
   where id = p_id and pharmacy_id = v_shop
  returning * into r;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.ui_text('refill.err_not_found'));
  end if;
  update public.storefront_request set status = 'reserved'
   where reservation_id = r.id and status = 'new';
  return jsonb_build_object('ok', true, 'row', public._c417_reservation_json(r));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 14. THE WHATSAPP STOREFRONT. One token per pharmacy. The patient side sees
--     MRP and availability and NOTHING else — no unit_cost, no PTR, no
--     supplier, no margin. This RPC is that fence.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._c417_storefront(p_shop uuid)
returns public.pharmacy_storefront language plpgsql security definer
set search_path to 'public' as $$
declare sf public.pharmacy_storefront%rowtype;
begin
  select * into sf from public.pharmacy_storefront where pharmacy_id = p_shop;
  if not found then
    insert into public.pharmacy_storefront(pharmacy_id, token)
    values (p_shop, encode(gen_random_bytes(9), 'hex'))
    on conflict (pharmacy_id) do nothing;
    select * into sf from public.pharmacy_storefront where pharmacy_id = p_shop;
  end if;
  return sf;
end $$;

create or replace function public._c417_base_url()
returns text language sql stable security definer set search_path to 'public'
as $$ select coalesce(nullif((select value #>> '{}' from public.app_settings
                               where key = 'public_base_url'), ''), 'https://medibo.in'); $$;

create or replace function public.storefront_page(p_token text, p_q text default null,
                                                  p_limit integer default 40,
                                                  p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare sf public.pharmacy_storefront%rowtype; v_name text;
        v_rows jsonb; v_total int; v_lim int := least(greatest(coalesce(p_limit,40),1), 60);
begin
  select * into sf from public.pharmacy_storefront
   where token = btrim(coalesce(p_token,''));
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.ui_text('storefront.not_found'));
  end if;
  v_name := public._c417_shop_name(sf.pharmacy_id);
  if not sf.is_active then
    return jsonb_build_object('ok', false, 'error','closed', 'shop', v_name,
      'message', public.ui_text('storefront.closed_body'));
  end if;

  select count(*) into v_total
    from (select 1 from public.pharmacy_stock st
           where st.pharmacy_id = sf.pharmacy_id and st.qty > 0
             and (coalesce(btrim(p_q),'') = ''
                  or st.product_name ilike '%'||btrim(p_q)||'%')
           group by coalesce(st.medicine_id::text, lower(st.product_name))) x;

  select coalesce(jsonb_agg(r order by r.product_name), '[]'::jsonb) into v_rows
    from (
      select coalesce(st.medicine_id::text, lower(st.product_name)) key,
             min(st.product_name) product_name,
             min(st.pack_label) pack_label,
             max(st.medicine_id) medicine_id,
             max(st.mrp) mrp
        from public.pharmacy_stock st
       where st.pharmacy_id = sf.pharmacy_id and st.qty > 0
         and (coalesce(btrim(p_q),'') = ''
              or st.product_name ilike '%'||btrim(p_q)||'%')
       group by coalesce(st.medicine_id::text, lower(st.product_name))
       order by min(st.product_name)
       limit v_lim offset greatest(coalesce(p_offset,0),0)) g,
      lateral (select jsonb_build_object(
         'key', g.key,
         'medicine_id', g.medicine_id,
         'product_name', g.product_name,
         'pack_label', g.pack_label,
         'stock_label', public.ui_text('storefront.in_stock'),
         'has_mrp', g.mrp is not null,
         'mrp_display', case when g.mrp is null then null
                             else public._c417_fmt('storefront.mrp_label',
                                    jsonb_build_object('amount', public.inr_money(g.mrp))) end,
         'add_label', public.ui_text('storefront.add_label'),
         'added_label', public.ui_text('storefront.added_label')) r,
         g.product_name) r;

  return jsonb_build_object('ok', true,
    'token', sf.token,
    'shop', v_name,
    'greeting', coalesce(nullif(btrim(coalesce(sf.greeting,'')),''),
                         public._c417_fmt('counter.greeting', jsonb_build_object('shop', v_name))),
    'search_hint', public.ui_text('storefront.search_hint'),
    'empty_label', public.ui_text('storefront.empty'),
    'name_hint', public.ui_text('storefront.name_hint'),
    'phone_hint', public.ui_text('storefront.phone_hint'),
    'note_hint', public.ui_text('storefront.note_hint'),
    'submit_label', public.ui_text('storefront.submit_label'),
    'cart_label_key', 'storefront.cart_label',
    'total', v_total,
    'has_more', greatest(coalesce(p_offset,0),0) + v_lim < v_total,
    'items', v_rows);
end $$;

create or replace function public.storefront_cart_label(p_n integer)
returns text language sql stable security definer set search_path to 'public'
as $$ select public._c417_fmt('storefront.cart_label',
                jsonb_build_object('n', greatest(coalesce(p_n,0),0)::text)); $$;

create or replace function public.storefront_request_submit(
  p_token text, p_name text, p_phone text, p_items jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare sf public.pharmacy_storefront%rowtype; v_ph text; v_lines jsonb := '[]'::jsonb;
        it jsonb; v_line jsonb; v_res uuid; v_req uuid; v_patient uuid; v_name text;
begin
  select * into sf from public.pharmacy_storefront where token = btrim(coalesce(p_token,''));
  if not found or not sf.is_active then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.ui_text('storefront.not_found'));
  end if;
  v_ph := right(regexp_replace(coalesce(p_phone,''), '\D','','g'), 10);
  if length(v_ph) <> 10 then
    return jsonb_build_object('ok', false, 'error','bad_phone',
      'message', public.ui_text('storefront.err_phone'));
  end if;
  if coalesce(jsonb_array_length(coalesce(p_items,'[]'::jsonb)),0) = 0 then
    return jsonb_build_object('ok', false, 'error','no_items',
      'message', public.ui_text('storefront.err_items'));
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    v_line := public._c417_stock_line(sf.pharmacy_id,
                nullif(it->>'medicine_id','')::bigint,
                it->>'product_name',
                coalesce(nullif(it->>'qty','')::numeric, 1));
    if v_line is not null then v_lines := v_lines || jsonb_build_array(v_line); end if;
  end loop;
  if jsonb_array_length(v_lines) = 0 then
    return jsonb_build_object('ok', false, 'error','no_items',
      'message', public.ui_text('storefront.err_items'));
  end if;

  insert into public.refill_patient(pharmacy_id, phone, name, source)
  values (sf.pharmacy_id, v_ph, nullif(btrim(coalesce(p_name,'')),''), 'storefront')
  on conflict (pharmacy_id, phone) do update
    set name = coalesce(excluded.name, public.refill_patient.name), updated_at = now()
  returning id into v_patient;

  insert into public.storefront_session(phone, pharmacy_id, source)
  values (v_ph, sf.pharmacy_id, 'link')
  on conflict (phone) do update
    set pharmacy_id = excluded.pharmacy_id, last_seen_at = now();

  v_res := public._c417_reserve(sf.pharmacy_id, v_patient, v_ph, p_name, v_lines,
                                'storefront', p_note);
  insert into public.storefront_request(pharmacy_id, source, patient_name, phone,
                                        items, note, status, reservation_id)
  values (sf.pharmacy_id, 'link', nullif(btrim(coalesce(p_name,'')),''), v_ph,
          v_lines, nullif(btrim(coalesce(p_note,'')),''), 'new', v_res)
  returning id into v_req;

  v_name := public._c417_shop_name(sf.pharmacy_id);
  return jsonb_build_object('ok', true, 'request_id', v_req, 'reservation_id', v_res,
    'title', public.ui_text('storefront.thanks_title'),
    'message', public._c417_fmt('storefront.thanks_body',
                 jsonb_build_object('shop', v_name)));
end $$;

grant execute on function public.storefront_page(text, text, integer, integer) to anon, authenticated;
grant execute on function public.storefront_cart_label(integer) to anon, authenticated;
grant execute on function public.storefront_request_submit(text, text, text, jsonb, text) to anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 15. THE AI COUNTER.
--
-- Grounding is structural, not a prompt instruction: the model NEVER writes
-- the sentence a patient reads. It classifies the message (intent + which of
-- the stock rows we handed it) and this file composes the answer from
-- ui_copy plus that pharmacy's own pharmacy_stock. A message that matches no
-- stock row, or that the model is unsure about, is handed to the pharmacy.
-- The model has exactly one write action, and even that is executed here.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy(key, value) values
 ('counter.available',  to_jsonb('{product} — {mrp}. In stock at {shop}. Reply RESERVE and we will keep it ready for pickup.'::text)),
 ('counter.available_many', to_jsonb('At {shop} right now: {list}. Reply RESERVE with the name and we will keep it ready.'::text)),
 ('counter.reserve_ask', to_jsonb('Which one should we keep ready? {list}'::text)),
 ('counter.stop',       to_jsonb('Stopped. You will not get messages from this pharmacy again.'::text))
on conflict (key) do nothing;

create or replace function public._c417_is_b2b_number(p_phone10 text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.pharmacy_profiles p
                  where right(regexp_replace(coalesce(p.whatsapp_no, p.phone,''),'\D','','g'),10) = p_phone10
                    and coalesce(p.is_deleted,false) = false)
      or exists (select 1 from public.whatsapp_allowed_senders s
                  where right(regexp_replace(coalesce(s.phone,''),'\D','','g'),10) = p_phone10
                    and coalesce(s.active,true));
$$;

-- what the model is allowed to know: this pharmacy's shelf, nothing else.
create or replace function public.storefront_ai_context(p_phone text, p_text text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_ph text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10);
        v_shop uuid; v_name text; v_rows jsonb; v_words text[];
begin
  select pharmacy_id into v_shop from public.storefront_session where phone = v_ph;
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error','no_session');
  end if;
  if not coalesce((select ai_enabled from public.refill_settings where pharmacy_id = v_shop), true) then
    return jsonb_build_object('ok', false, 'error','ai_off');
  end if;
  v_name := public._c417_shop_name(v_shop);

  v_words := array(select w from unnest(
      regexp_split_to_array(lower(regexp_replace(coalesce(p_text,''),'[^a-zA-Z0-9 ]',' ','g')), '\s+')) w
      where length(w) >= 3);

  select coalesce(jsonb_agg(x order by x->>'product_name'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'key', coalesce(st.medicine_id::text, lower(min(st.product_name))),
               'medicine_id', max(st.medicine_id),
               'product_name', min(st.product_name),
               'pack_label', min(st.pack_label),
               'qty', sum(st.qty),
               'mrp', max(st.mrp),
               'mrp_display', case when max(st.mrp) is null then null
                                   else public.inr_money(max(st.mrp)) end) x
        from public.pharmacy_stock st
       where st.pharmacy_id = v_shop and st.qty > 0
         and exists (select 1 from unnest(v_words) w where st.product_name ilike '%'||w||'%')
       group by coalesce(st.medicine_id::text, lower(st.product_name))
       limit 6) y;

  return jsonb_build_object('ok', true, 'shop', v_name, 'phone', v_ph,
    'matches', v_rows,
    'match_count', jsonb_array_length(v_rows),
    'intents', jsonb_build_array('availability','price','reserve','other'),
    'message', coalesce(p_text,''));
end $$;

-- the model's verdict comes back here; the SENTENCE is composed here too.
create or replace function public.storefront_ai_reply(p_phone text, p_text text,
                                                      p_intent text, p_keys jsonb,
                                                      p_qty numeric default 1)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_ph text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10);
  v_shop uuid; v_name text; v_conv uuid; v_reply text; v_intent text;
  v_rows jsonb := '[]'::jsonb; v_row jsonb; k text; v_list text; v_res uuid;
  v_patient uuid; v_grounded boolean := true; v_lines jsonb := '[]'::jsonb;
begin
  select pharmacy_id into v_shop from public.storefront_session where phone = v_ph;
  if v_shop is null then return jsonb_build_object('ok', false, 'error','no_session'); end if;
  v_name := public._c417_shop_name(v_shop);
  v_intent := coalesce(nullif(btrim(coalesce(p_intent,'')),''), 'other');

  -- resolve every key the model chose back to a REAL stock row. A key that is
  -- not on this shelf is dropped — that is the grounding, enforced in SQL.
  for k in select value #>> '{}' from jsonb_array_elements(coalesce(p_keys,'[]'::jsonb)) loop
    v_row := public._c417_stock_line(v_shop,
               case when k ~ '^\d+$' then k::bigint else null end,
               case when k ~ '^\d+$' then null else k end,
               coalesce(p_qty,1));
    if v_row is not null then v_rows := v_rows || jsonb_build_array(v_row); end if;
  end loop;

  insert into public.storefront_conversation(pharmacy_id, phone)
  values (v_shop, v_ph)
  on conflict (pharmacy_id, phone) do update set last_at = now()
  returning id into v_conv;
  if v_conv is null then
    select id into v_conv from public.storefront_conversation
     where pharmacy_id = v_shop and phone = v_ph;
  end if;

  insert into public.storefront_message(conversation_id, pharmacy_id, phone, direction,
                                        body, intent, grounded)
  values (v_conv, v_shop, v_ph, 'in', coalesce(p_text,''), v_intent, true);

  if jsonb_array_length(v_rows) = 0 or v_intent = 'other' then
    v_grounded := false;
    v_reply := case when v_intent = 'other'
      then public._c417_fmt('counter.handoff', jsonb_build_object('shop', v_name))
      else public._c417_fmt('counter.not_stocked', jsonb_build_object('shop', v_name)) end;
    update public.storefront_conversation set handoff = true, last_at = now(),
           message_count = message_count + 2 where id = v_conv;
  elsif v_intent = 'reserve' then
    select id into v_patient from public.refill_patient
     where pharmacy_id = v_shop and phone = v_ph;
    if v_patient is null then
      insert into public.refill_patient(pharmacy_id, phone, source)
      values (v_shop, v_ph, 'storefront') returning id into v_patient;
    end if;
    v_res := public._c417_reserve(v_shop, v_patient, v_ph, null, v_rows, 'counter_ai', null);
    insert into public.storefront_request(pharmacy_id, source, phone, items, status, reservation_id)
    values (v_shop, 'counter_ai', v_ph, v_rows, 'new', v_res);
    v_reply := public._c417_fmt('counter.reserved', jsonb_build_object('shop', v_name));
    update public.storefront_conversation set last_at = now(),
           message_count = message_count + 2 where id = v_conv;
  else
    if jsonb_array_length(v_rows) = 1 then
      v_row := v_rows->0;
      v_reply := public._c417_fmt('counter.available', jsonb_build_object(
        'product', v_row->>'product_name',
        'mrp', coalesce(v_row->>'mrp_display', ''),
        'shop', v_name));
    else
      select string_agg((r->>'product_name') ||
               case when coalesce(r->>'mrp_display','') = '' then ''
                    else ' (' || (r->>'mrp_display') || ')' end, ', ')
        into v_list from jsonb_array_elements(v_rows) r;
      v_reply := public._c417_fmt('counter.available_many',
                   jsonb_build_object('shop', v_name, 'list', v_list));
    end if;
    update public.storefront_conversation set last_at = now(),
           message_count = message_count + 2 where id = v_conv;
  end if;

  insert into public.storefront_message(conversation_id, pharmacy_id, phone, direction,
                                        body, intent, grounded, detail)
  values (v_conv, v_shop, v_ph, 'out', v_reply, v_intent, v_grounded,
          jsonb_build_object('matches', v_rows, 'reservation_id', v_res));

  return jsonb_build_object('ok', true, 'reply', v_reply, 'phone', v_ph,
    'intent', v_intent, 'grounded', v_grounded, 'reservation_id', v_res,
    'handoff', not v_grounded);
end $$;
