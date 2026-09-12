-- CMD #1929 — Payment alerts: ingest phone payment notifications, parse them
-- dynamically, auto-verify manual UPI claims by UTR.
--
-- The partner's Android phone forwards EVERY payment notification it sees
-- (GPay/PhonePe/Paytm/BHIM/bank apps). Everything after that is server-side:
-- the app posts raw_title + raw_text and renders whatever comes back.
--
-- Idempotent: safe to replay on live.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. payment_alerts — one row per forwarded notification.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.payment_alerts (
  id                  uuid primary key default gen_random_uuid(),
  device_id           text not null,
  package_name        text not null,
  raw_title           text,
  raw_text            text,
  posted_at           timestamptz not null default now(),
  text_md5            text not null,
  parsed_amount       numeric,
  parsed_utr          text,
  parsed_vpa          text,
  parsed_sender       text,
  parse_source        text not null default 'none',
  parse_rule_id       bigint,
  parse_note          text,
  ai_model            text,
  matched_claim_id    uuid,
  matched_order_id    uuid,
  matched_customer_id uuid,
  match_reason        text,
  status              text not null default 'new',
  zone_id             smallint,
  business_date       date,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- Columns are added defensively so a partially-applied earlier run heals.
alter table public.payment_alerts add column if not exists parse_rule_id       bigint;
alter table public.payment_alerts add column if not exists parse_note          text;
alter table public.payment_alerts add column if not exists ai_model            text;
alter table public.payment_alerts add column if not exists matched_order_id    uuid;
alter table public.payment_alerts add column if not exists matched_customer_id uuid;
alter table public.payment_alerts add column if not exists match_reason        text;
alter table public.payment_alerts add column if not exists business_date       date;
alter table public.payment_alerts add column if not exists updated_at          timestamptz not null default now();

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payment_alerts_parse_source_chk') then
    alter table public.payment_alerts add constraint payment_alerts_parse_source_chk
      check (parse_source in ('rule','ai','none'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_alerts_status_chk') then
    alter table public.payment_alerts add constraint payment_alerts_status_chk
      check (status in ('new','matched','unmatched','ignored'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payment_alerts_claim_fk') then
    alter table public.payment_alerts add constraint payment_alerts_claim_fk
      foreign key (matched_claim_id) references public.payment_claims(id) on delete set null;
  end if;
end $$;

-- Idempotency key of the ingest RPC: the same notification forwarded twice
-- (retry, app restart, two listeners) is ONE row.
create unique index if not exists payment_alerts_dedupe_uidx
  on public.payment_alerts (device_id, package_name, posted_at, text_md5);
create index if not exists payment_alerts_status_idx    on public.payment_alerts (status, posted_at desc);
create index if not exists payment_alerts_zone_date_idx on public.payment_alerts (zone_id, business_date desc);
create index if not exists payment_alerts_utr_idx       on public.payment_alerts (parsed_utr) where parsed_utr is not null;
create index if not exists payment_alerts_claim_idx     on public.payment_alerts (matched_claim_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. payment_alert_rules — parsing is DATA, never a Dart or SQL literal.
--    A new payment app is an INSERT, not a deploy.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.payment_alert_rules (
  id            bigserial primary key,
  package_name  text not null,
  label         text,
  amount_regex  text,
  utr_regex     text,
  vpa_regex     text,
  sender_regex  text,
  ignore_regex  text,
  priority      int  not null default 100,
  enabled       boolean not null default true,
  note          text,
  updated_at    timestamptz not null default now()
);
alter table public.payment_alert_rules add column if not exists sender_regex text;
alter table public.payment_alert_rules add column if not exists ignore_regex text;
alter table public.payment_alert_rules add column if not exists priority int not null default 100;
alter table public.payment_alert_rules add column if not exists label text;
alter table public.payment_alert_rules add column if not exists note text;

create unique index if not exists payment_alert_rules_pkg_label_uidx
  on public.payment_alert_rules (package_name, coalesce(label,''));
create index if not exists payment_alert_rules_lookup_idx
  on public.payment_alert_rules (package_name, priority) where enabled;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. customer_payment_senders — who pays us from which VPA.
--    Learned from every UTR-verified claim, so the NEXT payment from that
--    sender needs no UTR at all.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.customer_payment_senders (
  id                   bigserial primary key,
  customer_id          uuid not null,
  vpa                  text,
  sender_name          text,
  bank_ref_prefix      text,
  learned_from_claim_id uuid,
  confirmed_at         timestamptz,
  hit_count            int not null default 1,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
alter table public.customer_payment_senders add column if not exists hit_count int not null default 1;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'customer_payment_senders_customer_fk') then
    alter table public.customer_payment_senders add constraint customer_payment_senders_customer_fk
      foreign key (customer_id) references public.pharmacy_profiles(id) on delete cascade;
  end if;
end $$;

-- One learned identity per (customer, vpa, name) — repeats bump hit_count.
create unique index if not exists customer_payment_senders_uidx
  on public.customer_payment_senders (customer_id, coalesce(lower(vpa),''), coalesce(lower(sender_name),''));
create index if not exists customer_payment_senders_vpa_idx
  on public.customer_payment_senders (lower(vpa)) where vpa is not null;
create index if not exists customer_payment_senders_name_idx
  on public.customer_payment_senders (lower(sender_name)) where sender_name is not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. payment_alert_speak — the realtime feed the partner app subscribes to
--    for the SPOKEN alert. The sentence is built here, never in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.payment_alert_speak (
  id          bigserial primary key,
  alert_id    uuid,
  claim_id    uuid,
  order_id    uuid,
  customer_id uuid,
  zone_id     smallint,
  partner_id  bigint,
  message     text not null,
  amount      numeric,
  spoken_at   timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists payment_alert_speak_pull_idx
  on public.payment_alert_speak (zone_id, created_at desc) where spoken_at is null;

do $$ begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public'
       and tablename = 'payment_alert_speak') then
    execute 'alter publication supabase_realtime add table public.payment_alert_speak';
  end if;
exception when others then null;   -- no realtime on this branch is not an error
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. payment_alert_question — "We received ₹X — which order is it for?"
--    The options are resolved and stored here; the customer's WhatsApp reply
--    closes the row and completes the match.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.payment_alert_question (
  id               bigserial primary key,
  alert_id         uuid not null,
  customer_id      uuid,
  phone            text,
  amount           numeric,
  options          jsonb not null default '[]'::jsonb,
  asked_at         timestamptz not null default now(),
  answered_at      timestamptz,
  answer_text      text,
  chosen_order_id  uuid,
  status           text not null default 'open',
  created_at       timestamptz not null default now()
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'payment_alert_question_status_chk') then
    alter table public.payment_alert_question add constraint payment_alert_question_status_chk
      check (status in ('open','answered','expired','cancelled'));
  end if;
end $$;
create index if not exists payment_alert_question_open_idx
  on public.payment_alert_question (phone, asked_at desc) where status = 'open';
create unique index if not exists payment_alert_question_alert_uidx
  on public.payment_alert_question (alert_id) where status = 'open';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. RLS — every one of these is read and written through SECURITY DEFINER
--    RPCs only. No anon/authenticated policy is granted on purpose.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.payment_alerts             enable row level security;
alter table public.payment_alert_rules        enable row level security;
alter table public.customer_payment_senders   enable row level security;
alter table public.payment_alert_speak        enable row level security;
alter table public.payment_alert_question     enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Seed rules. Regexes are deliberately tolerant: notification wording
--    changes without notice, so each one anchors on the one token that never
--    moves (the ₹ figure, the 12-digit UPI reference, the @handle).
-- ─────────────────────────────────────────────────────────────────────────────
-- NOTE ON REGEX DIALECT: Postgres ARE spells a word boundary \y, NOT \b
-- (\b is a backspace here). A stop-word list written with \b silently never
-- matches, which is how "credited by Rs.3,499" first read a sender of "Rs".
with k as (
  select
    -- The rupee figure. Every app prints one and it never moves.
    $$(?:₹|Rs\.?|INR)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)$$ as amount_re,
    -- The UPI reference under any of its printed names. Six digits is the
    -- floor, not nine: a notification that prints only the TAIL of the UTR
    -- ('UTR: 223344') must still be captured — the matcher, not the regex,
    -- is what decides a short reference may only match with the amount.
    $$(?:UTR|UPI\s*(?:transaction\s*)?(?:Ref(?:erence)?|ID)|UPI\s*Ref(?:erence)?\s*(?:No\.?)?|Ref\s*No\.?|RRN|Transaction\s*ID|Txn\s*ID|Order\s*ID)[:\s#-]*([0-9]{6,22}|[A-Za-z0-9]{12,22})$$ as utr_re,
    -- The payer handle.
    $$([A-Za-z0-9._-]{2,64}@[A-Za-z]{2,32})$$ as vpa_re,
    -- The payer NAME as printed, in either word order ("X paid you" /
    -- "received from X"). A run of name words, each one refused if it is a
    -- banking stop-word, so the capture stops at the sentence and never
    -- swallows "Ref No 8567...". Never expanded, never corrected — verbatim.
    $$(?:^|[:.\s])((?!(?:on|via|to|using|ref|utr|upi|txn|rrn|at|for|dated|your|the|account|rs|inr|you|money|payment|received|credited)\y)[A-Za-z][A-Za-z&'()-]*(?:\s+(?!(?:on|via|to|using|ref|utr|upi|txn|rrn|at|for|dated|your|the|account|rs|inr|you|has|paid)\y)[A-Za-z][A-Za-z&'()-]*){0,4})\s+(?:paid\s+you|sent\s+you)|(?:received\s+from|trf\s+from|from|by)\s+((?![A-Za-z0-9._-]*@)(?!(?:on|via|to|using|ref|utr|upi|txn|rrn|a|at|for|dated|your|the|account|rs|inr)\y)[A-Za-z][A-Za-z&'()-]*(?:\s+(?!(?:on|via|to|using|ref|utr|upi|txn|rrn|a|at|for|dated|your|the|account|rs|inr)\y)[A-Za-z][A-Za-z&'()-]*){0,4})$$ as sender_re,
    -- Money that is NOT arriving. Checked before anything is read out of the
    -- text, because a collect request and a debit both carry a ₹ figure.
    $$(?:requesting|requested|collect\s*request|reminder|you\s+paid|sent\s+to|payment\s+of\b.*\bto\b|debited|withdrawn|failed|declined|cancelled|reversed|refund|cashback|wallet\s*top)$$ as ignore_upi,
    $$(?:debited|withdrawn|you\s+paid|failed|declined|reversed|reminder|cancelled)$$ as ignore_bank
),
seed(package_name, label, priority, kind, note) as (values
  ('com.google.android.apps.nbu.paisa.user', 'Google Pay',      10, 'upi',  'GPay: "Pooja Medical paid you ₹500. UPI transaction ID: 4123…"'),
  ('com.phonepe.app',                        'PhonePe',         10, 'upi',  'PhonePe: "₹1,250.50 received from Sharma Pharma. UTR: 5234…"'),
  ('net.one97.paytm',                        'Paytm',           10, 'upi',  'Paytm: "Received ₹2,000 in your Paytm account from Ravi Kumar"'),
  ('in.org.npci.upiapp',                     'BHIM',            10, 'upi',  'BHIM / NPCI reference app'),
  ('com.whatsapp',                           'WhatsApp Pay',    30, 'upi',  'WhatsApp payments notification'),
  ('com.sbi.lotusintouch',                   'SBI YONO',        20, 'bank', 'SBI: "A/c XX1234 is credited by Rs.3,499 trf from POOJA MEDICAL"'),
  ('com.snapwork.hdfc',                      'HDFC Bank',       20, 'bank', 'HDFC MobileBanking credit alert'),
  ('com.icicibank.pockets',                  'ICICI iMobile',   20, 'bank', 'ICICI iMobile credit alert'),
  ('com.axis.mobile',                        'Axis Bank',       20, 'bank', 'Axis Mobile credit alert'),
  ('com.msf.kbank.mobile',                   'Kotak 811',       20, 'bank', 'Kotak credit alert'),
  ('com.bankofbaroda.mconnect',              'Bank of Baroda',  20, 'bank', 'BoB M-Connect credit alert'),
  ('com.infrasofttech.PNBOne',               'PNB One',         20, 'bank', 'PNB One credit alert'),
  ('com.csam.icici.bank.imobile',            'ICICI iMobile Pay',20,'bank', 'ICICI iMobile Pay credit alert'),
  -- Catch-all: an unknown package still gets a rule pass before AI is paid for.
  ('*',                                      'Generic UPI credit',900,'upi','Fallback rule for a package with no rule of its own')
)
insert into public.payment_alert_rules
  (package_name, label, amount_regex, utr_regex, vpa_regex, sender_regex, ignore_regex, priority, note)
select s.package_name, s.label, k.amount_re, k.utr_re, k.vpa_re, k.sender_re,
       case when s.kind = 'bank' then k.ignore_bank else k.ignore_upi end,
       s.priority, s.note
  from seed s cross join k
on conflict (package_name, coalesce(label,'')) do update
  set amount_regex = excluded.amount_regex,
      utr_regex    = excluded.utr_regex,
      vpa_regex    = excluded.vpa_regex,
      sender_regex = excluded.sender_regex,
      ignore_regex = excluded.ignore_regex,
      priority     = excluded.priority,
      note         = excluded.note,
      updated_at   = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Copy. Every string this feature shows lives here (uic), never in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('pay_alert.title', to_jsonb('Payment alerts'::text)),
  ('pay_alert.subtitle', to_jsonb('Payment notifications forwarded from the partner phone'::text)),
  ('pay_alert.empty', to_jsonb('No payment notifications for this zone and date yet.'::text)),
  ('pay_alert.empty_hint', to_jsonb('Alerts appear here the moment the partner phone forwards one.'::text)),
  ('pay_alert.error_retry', to_jsonb('Retry'::text)),
  ('pay_alert.status.new', to_jsonb('New'::text)),
  ('pay_alert.status.matched', to_jsonb('Matched'::text)),
  ('pay_alert.status.unmatched', to_jsonb('Needs a look'::text)),
  ('pay_alert.status.ignored', to_jsonb('Ignored'::text)),
  ('pay_alert.source.rule', to_jsonb('Rule'::text)),
  ('pay_alert.source.ai', to_jsonb('AI'::text)),
  ('pay_alert.source.none', to_jsonb('Not parsed'::text)),
  ('pay_alert.no_amount', to_jsonb('No amount read'::text)),
  ('pay_alert.no_utr', to_jsonb('No UTR in the notification'::text)),
  ('pay_alert.no_sender', to_jsonb('Sender not named'::text)),
  ('pay_alert.match.utr_full', to_jsonb('Matched on the full UTR'::text)),
  ('pay_alert.match.utr_suffix', to_jsonb('Matched on the UTR ending and the amount'::text)),
  ('pay_alert.match.amount_vpa', to_jsonb('Matched on the amount and the paying UPI ID'::text)),
  ('pay_alert.match.sender_bill', to_jsonb('Matched from a known sender to their only open bill'::text)),
  ('pay_alert.match.customer_reply', to_jsonb('Matched by the customer''s own reply'::text)),
  ('pay_alert.unmatched.no_amount', to_jsonb('The notification carried no amount.'::text)),
  ('pay_alert.unmatched.ambiguous', to_jsonb('More than one payment could be this one.'::text)),
  ('pay_alert.unmatched.none', to_jsonb('Nothing pending looks like this payment.'::text)),
  ('pay_alert.unmatched.asked', to_jsonb('Asked the customer which order this is for.'::text)),
  ('pay_alert.ignored.not_credit', to_jsonb('Not money coming in.'::text)),
  ('pay_alert.speak_tpl', to_jsonb('{amount} received from {sender}'::text)),
  ('pay_alert.speak_tpl_nosender', to_jsonb('{amount} received'::text)),
  ('pay_alert.ask_tpl', to_jsonb('We received {amount}. Which order is it for?'::text)),
  ('pay_alert.ask_option_tpl', to_jsonb('{n}. {order_code} — {open_label} open'::text)),
  ('pay_alert.ask_footer', to_jsonb('Reply with the number.'::text)),
  ('pay_alert.ask_thanks_tpl', to_jsonb('Thank you — {amount} is now recorded against {order_code}.'::text)),
  ('pay_alert.ask_badnumber', to_jsonb('That number is not on the list. Please reply with one of the numbers above.'::text)),
  ('pay_alert.filter.all', to_jsonb('All'::text)),
  ('pay_alert.filter.chip_tpl', to_jsonb('{label} {count}'::text)),
  ('pay_alert.retry_match', to_jsonb('Match again'::text)),
  ('pay_alert.ignore', to_jsonb('Ignore'::text)),
  ('pay_alert.screen_denied', to_jsonb('Payment alerts are visible to a partner or an admin.'::text)),
  ('pay_alert.count_tpl', to_jsonb('{n} alerts'::text)),
  ('pay_alert.count_one', to_jsonb('1 alert'::text)),
  ('pay_alert.count_zero', to_jsonb('No alerts'::text))
on conflict (key) do nothing;

-- NOTE: this feature's nav LABEL is not here. The admin nav is nav_registry()
-- over feature_registry, so the row and its label are registered in
-- 20260912120800_payment_alerts_nav.sql — one source, no ui_copy twin.
