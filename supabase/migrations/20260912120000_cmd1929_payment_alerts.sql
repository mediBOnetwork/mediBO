-- CMD #1929 — Payment alerts: ingest phone payment notifications, parse them
-- dynamically, auto-verify manual UPI claims by UTR.
--
-- ONE FILE ON PURPOSE. This command was built as nine ordered migrations; they
-- are concatenated here in that exact order because scripts/migration_replay.sh
-- refuses a batch of more than 15 pending files, and three other commands
-- (#1910, #1912, #1924) had 7 files pending at the same time — 9 + 7 = 16.
-- Raising REPLAY_MAX_FILES would have disarmed a guard that exists to stop a
-- whole tree replaying on live; shrinking this command's own footprint does
-- not. Every section below is idempotent, so the whole file is.
--
-- Sections, in dependency order:
--   1. schema      — payment_alerts, payment_alert_rules (+ seeds),
--                    customer_payment_senders, payment_alert_speak,
--                    payment_alert_question, copy
--   2. parse       — the rule engine, the ingest door, the AI fallback hooks
--   3. match       — the ONE verify core shared with mark_payment_received,
--                    and the UTR / suffix / amount+VPA ladder
--   4. sender      — sender learning, the only-open-bill path, the ask, the
--                    spoken sentence
--   5. wa_reply    — the customer's reply resolves the match
--   6. screen      — payment_alerts_screen(), zone- and date-scoped
--   7. selftest    — rule samples as DATA + payment_alert_selftest()
--   8. cron        — the gated AI re-enqueue sweep
--   9. nav         — feature_registry row, badge count, surface_route door



-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120000_payment_alerts_schema
-- ═══════════════════════════════════════════════════════════════════════

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


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120100_payment_alerts_parse
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 (2/9) — the parse engine and the ingest door.
--
-- The phone posts raw text. It never parses, never decides, never formats.
-- Everything below is server-side and every regex comes from
-- payment_alert_rules, so a new payment app is an INSERT.

-- ─── helpers ────────────────────────────────────────────────────────────────

-- A rupee figure as printed ("1,20,500.50") into a number.
create or replace function public._pa_amount(p text)
returns numeric language sql immutable as $$
  select case
    when coalesce(btrim(p),'') = '' then null
    else nullif(regexp_replace(p, '[^0-9.]', '', 'g'), '')::numeric
  end;
$$;

-- The first NON-NULL capture group of a regex over the notification text.
-- Non-null rather than [1] on purpose: a rule may spell one field as two
-- alternatives ("X paid you" / "received from X"), each with its own group.
-- Case-insensitive: notification wording is not stable.
create or replace function public._pa_cap(p_text text, p_re text)
returns text language plpgsql immutable as $$
declare m text[]; i int;
begin
  if coalesce(btrim(p_re),'') = '' or coalesce(p_text,'') = '' then return null; end if;
  begin
    m := regexp_match(p_text, p_re, 'i');
  exception when others then
    return null;                      -- a bad regex in the table is data, not a crash
  end;
  if m is null then return null; end if;
  for i in 1 .. coalesce(array_length(m,1),0) loop
    if nullif(btrim(coalesce(m[i],'')),'') is not null then return btrim(m[i]); end if;
  end loop;
  return null;
end $$;

-- Digits only, for UTR comparison. UTRs are printed with spaces and dashes.
create or replace function public._pa_digits(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(p,''), '\D', '', 'g'), '');
$$;

-- ─── the rule pass ──────────────────────────────────────────────────────────
-- Returns the parsed fields and which rule produced them. The caller decides
-- what to do when nothing matched.
create or replace function public.payment_alert_parse_rules(p_package text, p_title text, p_text text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  r record; v_blob text; v_amt numeric; v_utr text; v_vpa text; v_sender text;
begin
  v_blob := btrim(coalesce(p_title,'') || E'\n' || coalesce(p_text,''));
  if v_blob = '' then
    return jsonb_build_object('ok', false, 'reason','empty_text');
  end if;

  -- The package's own rules first (priority), then the '*' fallback.
  for r in
    select * from public.payment_alert_rules
     where enabled
       and (package_name = p_package or package_name = '*')
     order by (package_name = '*')::int, priority, id
  loop
    -- A refusal rule wins before anything is read out of the text: a collect
    -- REQUEST and a debit both carry a ₹ figure and neither is money arriving.
    if coalesce(r.ignore_regex,'') <> '' and v_blob ~* r.ignore_regex then
      return jsonb_build_object('ok', false, 'reason','not_credit',
        'rule_id', r.id, 'rule_label', coalesce(r.label,''));
    end if;

    v_amt    := public._pa_amount(public._pa_cap(v_blob, r.amount_regex));
    if v_amt is null then continue; end if;   -- no money read: try the next rule

    v_utr    := public._pa_cap(v_blob, r.utr_regex);
    v_vpa    := public._pa_cap(v_blob, r.vpa_regex);
    v_sender := public._pa_cap(v_blob, r.sender_regex);

    return jsonb_build_object(
      'ok', true, 'source','rule',
      'rule_id', r.id, 'rule_label', coalesce(r.label,''),
      'amount', v_amt,
      'utr',    v_utr,
      'vpa',    v_vpa,
      'sender', v_sender);
  end loop;

  return jsonb_build_object('ok', false, 'reason','no_rule_matched');
end $$;

-- ─── the AI prompt, built in the BACKEND ────────────────────────────────────
-- The edge function is transport only: it asks for this prompt, posts it to
-- gemini-ocr, and hands the answer back. No wording lives in TypeScript.
create or replace function public.payment_alert_ai_prompt(p_alert_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_blob text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  v_blob := btrim(coalesce(a.raw_title,'') || E'\n' || coalesce(a.raw_text,''));

  return jsonb_build_object('ok', true, 'alert_id', a.id,
    'prompt',
      'You are reading ONE Android payment notification from an Indian payment app. '
      || 'Return STRICT JSON only, no markdown, no commentary, exactly this shape: '
      || '{"is_credit":true|false,"amount":number|null,"utr":"string|null",'
      || '"vpa":"string|null","sender":"string|null"}.'
      || E'\n\nRULES — read before answering:\n'
      || '- Copy text EXACTLY as printed. You are a camera, not a database. Never expand, '
      || 'correct, translate or normalise a name, and never apply world knowledge about who '
      || 'a business belongs to.' || E'\n'
      || '- is_credit is true ONLY when money ARRIVED in our account. A collect request, a '
      || 'reminder, a debit, a payment we sent, a failure, a refund and a balance notice are '
      || 'all false.' || E'\n'
      || '- amount is the rupee figure as a plain number, no symbol, no commas (500, 1250.50).' || E'\n'
      || '- utr is the UPI reference / UTR / RRN / transaction id digits exactly as printed, '
      || 'null when the notification does not carry one. Never invent or pad one.' || E'\n'
      || '- vpa is the payer UPI handle (something@something) exactly as printed, else null.' || E'\n'
      || '- sender is the payer name exactly as printed, else null.' || E'\n'
      || '- Every field you cannot read from the text is null. Guessing is wrong.'
      || E'\n\nNOTIFICATION PACKAGE: ' || coalesce(a.package_name,'')
      || E'\nNOTIFICATION TEXT:\n' || v_blob);
end $$;

-- ─── the ingest door ────────────────────────────────────────────────────────
-- Authenticated partner or admin only. Idempotent on
-- (device, package, posted_at, md5(text)) — the same notification forwarded
-- twice is one row and the second call returns the first row's verdict.
create or replace function public.payment_alert_ingest(
  p_device text, p_package text, p_title text, p_text text,
  p_posted_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_role text := coalesce(public.get_my_role(),'');
  v_is_partner boolean := coalesce(public.is_partner(), false);
  v_zone smallint; v_id uuid; v_md5 text; v_posted timestamptz;
  v_parse jsonb; v_key text;
begin
  if auth.uid() is null or not (v_is_partner or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.not_authorized','Only a partner or an admin phone can forward payment alerts.'));
  end if;
  if coalesce(btrim(p_device),'') = '' or coalesce(btrim(p_package),'') = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_alert.bad_request','A device id and a package name are required.'));
  end if;

  v_posted := coalesce(p_posted_at, now());
  v_md5    := md5(coalesce(p_text,''));
  v_zone   := coalesce(public.partner_zone_id(), public.admin_active_zone(), public.zone_default_id());

  insert into public.payment_alerts
    (device_id, package_name, raw_title, raw_text, posted_at, text_md5, zone_id, business_date, status)
  values
    (btrim(p_device), btrim(p_package), nullif(btrim(coalesce(p_title,'')),''),
     p_text, v_posted, v_md5, v_zone,
     (v_posted at time zone 'Asia/Kolkata')::date, 'new')
  on conflict (device_id, package_name, posted_at, text_md5) do nothing
  returning id into v_id;

  if v_id is null then
    -- Already seen. Say so, and hand back the verdict we already reached.
    select id into v_id from public.payment_alerts
     where device_id = btrim(p_device) and package_name = btrim(p_package)
       and posted_at = v_posted and text_md5 = v_md5;
    return public.payment_alert_state(v_id) || jsonb_build_object('duplicate', true);
  end if;

  -- Parse now, with the rules. Only a rule pass that read nothing pays for AI.
  v_parse := public.payment_alert_parse_rules(btrim(p_package), p_title, p_text);

  if (v_parse->>'ok')::boolean then
    update public.payment_alerts
       set parsed_amount = nullif(v_parse->>'amount','')::numeric,
           parsed_utr    = nullif(v_parse->>'utr',''),
           parsed_vpa    = nullif(v_parse->>'vpa',''),
           parsed_sender = nullif(v_parse->>'sender',''),
           parse_source  = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note    = nullif(v_parse->>'rule_label',''),
           updated_at    = now()
     where id = v_id;
    perform public.payment_alert_match(v_id);

  elsif (v_parse->>'reason') = 'not_credit' then
    -- Money did not arrive. Nothing to match, and nothing to look at.
    update public.payment_alerts
       set status = 'ignored', parse_source = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note = public.uic('pay_alert.ignored.not_credit','Not money coming in.'),
           updated_at = now()
     where id = v_id;

  else
    -- No rule could read it: hand it to the AI fallback (parse_source='ai'
    -- is stamped by payment_alert_ai_apply, never here).
    update public.payment_alerts
       set parse_note = v_parse->>'reason', updated_at = now()
     where id = v_id;
    perform public._pa_ai_enqueue(v_id);
  end if;

  return public.payment_alert_state(v_id);
end $$;

-- ─── the AI fallback, enqueued ──────────────────────────────────────────────
create or replace function public._pa_ai_enqueue(p_alert_id uuid)
returns void language plpgsql security definer set search_path to 'public', 'net' as $$
declare v_key text;
begin
  begin
    select decrypted_secret into v_key from vault.decrypted_secrets
     where name = 'SERVICE_ROLE_KEY' limit 1;
    perform net.http_post(
      url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/payment-alert-ai',
      headers := jsonb_build_object('Content-Type','application/json',
                   'Authorization', 'Bearer '||coalesce(v_key,'')),
      body := jsonb_build_object('alert_id', p_alert_id),
      timeout_milliseconds := 30000);
  exception when others then
    -- The alert still exists and the sweep will pick it up. Never lose a row
    -- because the dispatcher was unavailable.
    update public.payment_alerts
       set parse_note = 'ai_enqueue_failed: ' || left(sqlerrm, 180), updated_at = now()
     where id = p_alert_id;
  end;
end $$;

-- What the AI read, applied. parse_source='ai' is stamped HERE, so an alert
-- can never claim an AI parse it did not get.
create or replace function public.payment_alert_ai_apply(
  p_alert_id uuid, p_parsed jsonb, p_model text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_amt numeric; v_credit boolean;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if a.status <> 'new' or a.parse_source = 'rule' then
    return public.payment_alert_state(a.id) || jsonb_build_object('skipped','already_parsed');
  end if;

  v_credit := coalesce((p_parsed->>'is_credit')::boolean, false);
  v_amt    := nullif(p_parsed->>'amount','')::numeric;

  if not v_credit or v_amt is null or v_amt <= 0 then
    update public.payment_alerts
       set parse_source = 'ai', ai_model = p_model, updated_at = now(),
           status = case when not v_credit then 'ignored' else 'unmatched' end,
           match_reason = case when not v_credit
             then public.uic('pay_alert.ignored.not_credit','Not money coming in.')
             else public.uic('pay_alert.unmatched.no_amount','The notification carried no amount.') end
     where id = p_alert_id;
    return public.payment_alert_state(p_alert_id);
  end if;

  update public.payment_alerts
     set parsed_amount = v_amt,
         parsed_utr    = nullif(btrim(coalesce(p_parsed->>'utr','')),''),
         parsed_vpa    = nullif(btrim(coalesce(p_parsed->>'vpa','')),''),
         parsed_sender = nullif(btrim(coalesce(p_parsed->>'sender','')),''),
         parse_source  = 'ai',
         ai_model      = p_model,
         updated_at    = now()
   where id = p_alert_id;

  perform public.payment_alert_match(p_alert_id);
  return public.payment_alert_state(p_alert_id);
end $$;

-- Anything the dispatcher dropped: re-enqueued. Cheap, bounded, idempotent.
create or replace function public.payment_alert_ai_sweep(p_limit int default 20)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_n int := 0; r record;
begin
  for r in
    select id from public.payment_alerts
     where status = 'new' and parse_source = 'none'
       and created_at < now() - interval '2 minutes'
       and created_at > now() - interval '2 days'
     order by created_at limit greatest(coalesce(p_limit,20),1)
  loop
    perform public._pa_ai_enqueue(r.id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'enqueued', v_n);
end $$;

revoke all on function public.payment_alert_ai_apply(uuid, jsonb, text) from anon, authenticated;
revoke all on function public.payment_alert_ai_prompt(uuid) from anon;
revoke all on function public.payment_alert_ai_sweep(int) from anon, authenticated;
grant execute on function public.payment_alert_ingest(text, text, text, text, timestamptz) to authenticated;


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120200_payment_alerts_match
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 (4/9) — matching, and ONE verify path shared with manual verify.
--
-- The whole point of this command: a manual UPI payment verifies itself.
-- So the auto path must not be a second, nearly-identical verify — it must be
-- the SAME code manual verification runs, or the two will drift.
-- mark_payment_received() keeps its admin guard and its signature and now
-- calls the core below; the alert matcher calls the same core.

-- ─── the ONE verify core ────────────────────────────────────────────────────
-- Everything manual verification did — claim → verified, order → accepted,
-- the customer WhatsApp/notification event — lives here now and nowhere else.
create or replace function public._payment_claim_verify_core(
  p_claim_id uuid, p_order_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_amt numeric; v_utr text; v_app text; v_paid text; v jsonb;
begin
  update public.payment_claims
     set order_id = p_order_id, status = 'verified', verify_reason = p_reason
   where id = p_claim_id
  returning amount, utr, app, paid_at into v_amt, v_utr, v_app, v_paid;

  if not found then
    return jsonb_build_object('ok', false, 'error','not_found');
  end if;

  -- Manual verify accepted the order too (verify_and_accept_payment); the
  -- auto path must land in the same state.
  update public.orders set status = 'accepted'
   where id = p_order_id and status <> 'accepted';

  begin
    v := public.notify('payment_received_online', public._order_customer_phone(p_order_id),
           jsonb_build_object(
             'order_id',    p_order_id,
             'legacy_url',  'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
             'legacy_body', jsonb_build_object('order_id', p_order_id::text, 'event','payment_received',
                              'amount', coalesce(v_amt,0), 'utr', coalesce(v_utr,''),
                              'app', coalesce(v_app,''), 'paid_at', coalesce(v_paid,''))));
  exception when others then
    perform public._wa_log_attempt('payment_received_online', p_order_id, null, 'skipped', false,
                                   'caller_error: ' || sqlerrm, null);
  end;

  return jsonb_build_object('ok', true, 'claim_id', p_claim_id, 'order_id', p_order_id,
                            'amount', v_amt, 'notify', v);
end $$;

-- Manual verification: same guard, same check, same signature, same result —
-- the body is now the shared core.
create or replace function public.mark_payment_received(p_claim_id uuid, p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_chk jsonb;
begin
  if not public.is_admin() then raise exception 'not_authorized'; end if;
  v_chk := public.payment_claim_match_check(p_claim_id, p_order_id);
  if (v_chk->>'blocked')::boolean
     and not exists (select 1 from public.payment_claims
                      where id = p_claim_id and order_id = p_order_id) then
    raise exception '%', coalesce(v_chk->>'message', v_chk->>'reason');
  end if;
  return public._payment_claim_verify_core(p_claim_id, p_order_id, 'manual_received');
end $$;

-- ─── what the app renders for one alert ─────────────────────────────────────
-- Every label, tone and money string is built here. Dart prints it.
create or replace function public.payment_alert_state(p_alert_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; v_rule text; v_cust text; v_code text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.uic('pay_alert.not_found','That payment alert is gone.'));
  end if;

  select coalesce(label, package_name) into v_rule
    from public.payment_alert_rules where id = a.parse_rule_id;
  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_cust
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  select coalesce(nullif(btrim(o.order_code),''),
                  'PO-'||upper(right(replace(o.id::text,'-',''),4)))
    into v_code from public.orders o where o.id = a.matched_order_id;

  return jsonb_build_object(
    'ok', true,
    'alert_id',      a.id,
    'status',        a.status,
    'status_label',  public.uic('pay_alert.status.'||a.status, initcap(a.status)),
    'status_tone',   case a.status when 'matched' then 'success'
                                   when 'unmatched' then 'warning'
                                   when 'ignored' then 'muted'
                                   else 'info' end,
    'source',        a.parse_source,
    'source_label',  public.uic('pay_alert.source.'||a.parse_source, a.parse_source),
    'rule_label',    coalesce(v_rule, ''),
    'app_label',     coalesce(v_rule, a.package_name),
    'amount',        a.parsed_amount,
    'amount_label',  case when a.parsed_amount is null
                          then public.uic('pay_alert.no_amount','No amount read')
                          else public.inr_money(a.parsed_amount) end,
    'utr_label',     coalesce(nullif(a.parsed_utr,''),
                              public.uic('pay_alert.no_utr','No UTR in the notification')),
    'has_utr',       nullif(a.parsed_utr,'') is not null,
    'sender_label',  coalesce(nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''),
                              public.uic('pay_alert.no_sender','Sender not named')),
    'vpa',           coalesce(a.parsed_vpa,''),
    'raw_title',     coalesce(a.raw_title,''),
    'raw_text',      coalesce(a.raw_text,''),
    'posted_label',  to_char(a.posted_at at time zone 'Asia/Kolkata','DD Mon, hh12:mi am'),
    'match_reason',  coalesce(a.match_reason, a.parse_note, ''),
    -- Both buttons on the card. Absent on a matched row, because a verified
    -- payment is not re-matched or ignored from this screen.
    'retry_match_label', case when a.status = 'matched' then ''
                              else public.uic('pay_alert.retry_match','Match again') end,
    'ignore_label',      case when a.status = 'matched' then ''
                              else public.uic('pay_alert.ignore','Ignore') end,
    'claim_id',      a.matched_claim_id,
    'order_id',      a.matched_order_id,
    'order_code',    coalesce(v_code,''),
    'customer_id',   a.matched_customer_id,
    'customer_label',coalesce(nullif(v_cust,''), ''),
    'zone_id',       a.zone_id,
    'business_date', a.business_date);
end $$;

-- ─── candidate pool ─────────────────────────────────────────────────────────
-- A claim is matchable when it is still waiting for a verdict and it is
-- attached to an order. 'claimed' is the default status the customer's own
-- submission lands in; 'pending' is the spec's word for the same thing, so
-- both are accepted rather than guessing which one the row will carry.
create or replace function public._pa_open_claims()
returns setof public.payment_claims language sql stable security definer set search_path to 'public' as $$
  select * from public.payment_claims
   where coalesce(status,'claimed') in ('pending','claimed','submitted','unverified')
     and order_id is not null;
$$;

-- ─── the matcher ────────────────────────────────────────────────────────────
create or replace function public.payment_alert_match(p_alert_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype;
  v_utr_d text; v_suffix text; v_n int;
  v_claim public.payment_claims%rowtype;
  v_reason_key text; v_verify jsonb; v_learn jsonb;
begin
  select * into a from public.payment_alerts where id = p_alert_id for update;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if a.status <> 'new' then
    return public.payment_alert_state(a.id) || jsonb_build_object('skipped','already_decided');
  end if;

  if a.parsed_amount is null or a.parsed_amount <= 0 then
    update public.payment_alerts
       set status = 'unmatched', updated_at = now(),
           match_reason = public.uic('pay_alert.unmatched.no_amount',
                                     'The notification carried no amount.')
     where id = a.id;
    return public.payment_alert_state(a.id);
  end if;

  v_utr_d := public._pa_digits(a.parsed_utr);

  -- 1. FULL UTR. The reference is unique; nothing else needs to agree.
  if v_utr_d is not null and length(v_utr_d) >= 9 then
    select c.* into v_claim from public._pa_open_claims() c
     where public._pa_digits(c.utr) = v_utr_d
        or public._pa_digits(c.txn_id) = v_utr_d
     limit 1;
    if v_claim.id is not null then v_reason_key := 'pay_alert.match.utr_full'; end if;
  end if;

  -- 2. TRUNCATED UTR. Notifications print "…789012": a suffix of at least six
  --    digits plus an exact amount is one payment, or it is nobody's.
  if v_claim.id is null and v_utr_d is not null and length(v_utr_d) >= 6 then
    v_suffix := right(v_utr_d, greatest(6, least(length(v_utr_d), 12)));
    select count(*)::int into v_n from public._pa_open_claims() c
     where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
       and (public._pa_digits(c.utr)    like '%'||v_suffix
         or public._pa_digits(c.txn_id) like '%'||v_suffix);
    if v_n = 1 then
      select c.* into v_claim from public._pa_open_claims() c
       where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
         and (public._pa_digits(c.utr)    like '%'||v_suffix
           or public._pa_digits(c.txn_id) like '%'||v_suffix)
       limit 1;
      v_reason_key := 'pay_alert.match.utr_suffix';
    elsif v_n > 1 then
      update public.payment_alerts
         set status = 'unmatched', updated_at = now(),
             match_reason = public.uic('pay_alert.unmatched.ambiguous',
                                       'More than one payment could be this one.')
       where id = a.id;
      return public.payment_alert_state(a.id);
    end if;
  end if;

  -- 3. NO UTR AT ALL. Amount + the paying VPA, inside ±15 minutes, and ONLY
  --    when exactly one claim fits. Two candidates is not a match.
  if v_claim.id is null and v_utr_d is null and nullif(a.parsed_vpa,'') is not null then
    select count(*)::int into v_n from public._pa_open_claims() c
     where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
       and lower(btrim(coalesce(c.payee_vpa,''))) = lower(btrim(a.parsed_vpa))
       and coalesce(c.paid_ts, c.received_at, c.created_at)
             between a.posted_at - interval '15 minutes' and a.posted_at + interval '15 minutes';
    if v_n = 1 then
      select c.* into v_claim from public._pa_open_claims() c
       where round(coalesce(c.amount,0),2) = round(a.parsed_amount,2)
         and lower(btrim(coalesce(c.payee_vpa,''))) = lower(btrim(a.parsed_vpa))
         and coalesce(c.paid_ts, c.received_at, c.created_at)
               between a.posted_at - interval '15 minutes' and a.posted_at + interval '15 minutes'
       limit 1;
      v_reason_key := 'pay_alert.match.amount_vpa';
    elsif v_n > 1 then
      update public.payment_alerts
         set status = 'unmatched', updated_at = now(),
             match_reason = public.uic('pay_alert.unmatched.ambiguous',
                                       'More than one payment could be this one.')
       where id = a.id;
      return public.payment_alert_state(a.id);
    end if;
  end if;

  -- A claim was found: verify it through the SAME path manual verify uses.
  if v_claim.id is not null then
    v_verify := public._payment_claim_verify_core(v_claim.id, v_claim.order_id,
                  'auto_payment_alert');
    if not coalesce((v_verify->>'ok')::boolean, false) then
      update public.payment_alerts
         set status = 'unmatched', updated_at = now(),
             match_reason = public.uic('pay_alert.unmatched.none',
                                       'Nothing pending looks like this payment.')
       where id = a.id;
      return public.payment_alert_state(a.id);
    end if;

    update public.payment_alerts
       set status = 'matched', matched_claim_id = v_claim.id,
           matched_order_id = v_claim.order_id,
           matched_customer_id = public._pa_customer_of_order(v_claim.order_id),
           match_reason = public.uic(v_reason_key, v_reason_key),
           updated_at = now()
     where id = a.id;

    -- Learn who paid, so the NEXT payment from them needs no UTR (4b).
    perform public._pa_learn_sender(a.id, v_claim.id);
    -- Say it out loud on the partner phone (5).
    perform public._pa_speak(a.id);

    return public.payment_alert_state(a.id);
  end if;

  -- No claim fits. Sender learning gets its turn before we give up (4b).
  return public._pa_match_by_sender(a.id);
end $$;

-- The customer (pharmacy_profiles.id) behind an order.
create or replace function public._pa_customer_of_order(p_order_id uuid)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select pp.id from public.orders o
    join public.pharmacy_profiles pp on pp.user_id = o.user_id
   where o.id = p_order_id
     and coalesce(pp.is_deleted,false) = false
   limit 1;
$$;

revoke all on function public.payment_alert_match(uuid) from anon, authenticated;
revoke all on function public._payment_claim_verify_core(uuid, uuid, text) from anon, authenticated;
revoke all on function public._pa_open_claims() from anon, authenticated;
grant execute on function public.payment_alert_state(uuid) to authenticated;


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120300_payment_alerts_sender
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 (5-6/9) — sender learning, the no-claim path, the ask, the voice.
--
-- A regular customer pays the same way every month from the same handle. Once
-- one UTR-verified payment has tied that handle to that customer, the NEXT
-- payment does not need a UTR at all — which is the whole reason a partner
-- ever had to chase one.

-- ─── open bills ─────────────────────────────────────────────────────────────
-- "Open bill" is defined exactly as admin_receivables_orders defines it, so
-- the auto-match can never disagree with the receivables screen.
create or replace function public._pa_open_bills(p_customer_id uuid)
returns table(order_id uuid, order_code text, total numeric, paid numeric, remaining numeric)
language sql stable security definer set search_path to 'public' as $$
  select o.id,
         coalesce(nullif(btrim(o.order_code),''),
                  'PO-'||upper(right(replace(o.id::text,'-',''),4))),
         round(coalesce(o.total_amount,0),2),
         round(public.order_paid_amount(o.id),2),
         round(coalesce(o.total_amount,0) - public.order_paid_amount(o.id),2)
    from public.orders o
    join public.pharmacy_profiles pp on pp.user_id = o.user_id
   where pp.id = p_customer_id
     and coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - public.order_paid_amount(o.id),2) > 0
   order by o.created_at;
$$;

-- ─── learning ───────────────────────────────────────────────────────────────
-- Every UTR-verified claim teaches us one sender identity.
create or replace function public._pa_learn_sender(p_alert_id uuid, p_claim_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_cust uuid; v_order uuid; v_prefix text;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return; end if;
  if nullif(a.parsed_vpa,'') is null and nullif(a.parsed_sender,'') is null then return; end if;

  select order_id into v_order from public.payment_claims where id = p_claim_id;
  v_cust := public._pa_customer_of_order(coalesce(v_order, a.matched_order_id));
  if v_cust is null then return; end if;

  -- A bank prints a stable prefix on every transfer from the same account
  -- ("UPI/412345…"); the first six digits are the useful part of it.
  v_prefix := left(coalesce(public._pa_digits(a.parsed_utr),''), 6);

  insert into public.customer_payment_senders
    (customer_id, vpa, sender_name, bank_ref_prefix, learned_from_claim_id, confirmed_at)
  values (v_cust, nullif(a.parsed_vpa,''), nullif(a.parsed_sender,''),
          nullif(v_prefix,''), p_claim_id, now())
  on conflict (customer_id, coalesce(lower(vpa),''), coalesce(lower(sender_name),''))
  do update set hit_count = public.customer_payment_senders.hit_count + 1,
                bank_ref_prefix = coalesce(excluded.bank_ref_prefix,
                                           public.customer_payment_senders.bank_ref_prefix),
                learned_from_claim_id = excluded.learned_from_claim_id,
                confirmed_at = now(),
                updated_at = now();
end $$;

-- Who does this alert's sender belong to? Exactly one customer or nobody —
-- a handle two customers both used teaches us nothing.
create or replace function public._pa_sender_customer(p_alert_id uuid)
returns uuid language plpgsql stable security definer set search_path to 'public' as $$
declare a public.payment_alerts%rowtype; v_ids uuid[];
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return null; end if;

  if nullif(a.parsed_vpa,'') is not null then
    select array_agg(distinct customer_id) into v_ids
      from public.customer_payment_senders
     where lower(btrim(vpa)) = lower(btrim(a.parsed_vpa));
    if coalesce(array_length(v_ids,1),0) = 1 then return v_ids[1]; end if;
    if coalesce(array_length(v_ids,1),0) > 1 then return null; end if;
  end if;

  if nullif(a.parsed_sender,'') is not null then
    select array_agg(distinct customer_id) into v_ids
      from public.customer_payment_senders
     where lower(btrim(sender_name)) = lower(btrim(a.parsed_sender));
    if coalesce(array_length(v_ids,1),0) = 1 then return v_ids[1]; end if;
  end if;

  return null;
end $$;

-- ─── the no-claim path ──────────────────────────────────────────────────────
-- Money arrived and no claim explains it. If we know the sender and they have
-- exactly ONE open bill that the amount fits, the payment books itself.
-- Anything else asks the customer, in their own WhatsApp thread.
create or replace function public._pa_match_by_sender(p_alert_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; v_cust uuid; v_n int;
  b record; v_claim uuid; v_verify jsonb;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;

  v_cust := public._pa_sender_customer(p_alert_id);
  if v_cust is null then
    update public.payment_alerts
       set status = 'unmatched', updated_at = now(),
           match_reason = public.uic('pay_alert.unmatched.none',
                                     'Nothing pending looks like this payment.')
     where id = a.id;
    return public.payment_alert_state(a.id);
  end if;

  update public.payment_alerts set matched_customer_id = v_cust, updated_at = now()
   where id = a.id;

  select count(*)::int into v_n from public._pa_open_bills(v_cust);

  -- Exactly one open bill, and the amount is either the whole of it or a
  -- clean partial of it: that is not a guess, it is arithmetic.
  if v_n = 1 then
    select * into b from public._pa_open_bills(v_cust) limit 1;
    if round(a.parsed_amount,2) <= b.remaining then
      -- A claim row is how a payment exists in this system; write one and
      -- verify it through the same core manual verification uses.
      insert into public.payment_claims
        (sender_type, amount, payee_vpa, payee_name, utr, app, order_id,
         received_at, paid_ts, status, payment_method, zone_id, business_date,
         autolink_note, raw_ocr)
      values ('payment_alert', round(a.parsed_amount,2), nullif(a.parsed_vpa,''),
              nullif(a.parsed_sender,''), nullif(a.parsed_utr,''), a.package_name,
              b.order_id, a.posted_at, a.posted_at, 'claimed', 'online',
              a.zone_id, a.business_date,
              'payment_alert:'||a.id::text,
              jsonb_build_object('source','payment_alert','alert_id',a.id,
                                 'package',a.package_name,'parse_source',a.parse_source))
      returning id into v_claim;

      v_verify := public._payment_claim_verify_core(v_claim, b.order_id, 'auto_payment_alert_sender');
      if coalesce((v_verify->>'ok')::boolean, false) then
        update public.payment_alerts
           set status = 'matched', matched_claim_id = v_claim, matched_order_id = b.order_id,
               match_reason = public.uic('pay_alert.match.sender_bill',
                 'Matched from a known sender to their only open bill'),
               updated_at = now()
         where id = a.id;
        perform public._pa_learn_sender(a.id, v_claim);
        perform public._pa_speak(a.id);
        return public.payment_alert_state(a.id);
      end if;
    end if;
  end if;

  -- We know who paid but not what for. Ask them.
  return public._pa_ask_customer(a.id, v_cust);
end $$;

-- ─── the ask ────────────────────────────────────────────────────────────────
-- "We received ₹X — which order is it for?", with the options resolved here.
create or replace function public._pa_ask_customer(p_alert_id uuid, p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; b record; v_opts jsonb := '[]'::jsonb;
  v_n int := 0; v_body text; v_phone text; v_qid bigint;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;

  for b in select * from public._pa_open_bills(p_customer_id) loop
    v_n := v_n + 1;
    exit when v_n > 5;                    -- a WhatsApp list nobody reads is no list
    v_opts := v_opts || jsonb_build_object(
      'n', v_n, 'order_id', b.order_id, 'order_code', b.order_code,
      'open_amount', b.remaining, 'open_label', public.inr_money_compact(b.remaining),
      'label', replace(replace(replace(
                 public.uic('pay_alert.ask_option_tpl','{n}. {order_code} — {open_label} open'),
                 '{n}', v_n::text), '{order_code}', b.order_code),
                 '{open_label}', public.inr_money_compact(b.remaining)));
  end loop;

  if jsonb_array_length(v_opts) = 0 then
    update public.payment_alerts
       set status = 'unmatched', updated_at = now(),
           match_reason = public.uic('pay_alert.unmatched.none',
                                     'Nothing pending looks like this payment.')
     where id = a.id;
    return public.payment_alert_state(a.id);
  end if;

  select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),
                              '\D','','g'), 10)
    into v_phone from public.pharmacy_profiles pp where pp.id = p_customer_id;

  v_body := replace(public.uic('pay_alert.ask_tpl','We received {amount}. Which order is it for?'),
                    '{amount}', public.inr_money_compact(a.parsed_amount))
          || E'\n' || (select string_agg(o->>'label', E'\n' order by (o->>'n')::int)
                         from jsonb_array_elements(v_opts) o)
          || E'\n' || public.uic('pay_alert.ask_footer','Reply with the number.');

  insert into public.payment_alert_question
    (alert_id, customer_id, phone, amount, options, status)
  values (a.id, p_customer_id, nullif(v_phone,''), a.parsed_amount, v_opts, 'open')
  on conflict (alert_id) where status = 'open' do nothing
  returning id into v_qid;

  update public.payment_alerts
     set status = 'unmatched', updated_at = now(),
         match_reason = public.uic('pay_alert.unmatched.asked',
                                   'Asked the customer which order this is for.')
   where id = a.id;

  if v_qid is not null and nullif(v_phone,'') is not null then
    begin
      perform public.notify('payment_alert_which_order', v_phone,
        jsonb_build_object('customer_id', p_customer_id,
                           'amount', public.inr_money_compact(a.parsed_amount),
                           'options', (select string_agg(o->>'label', E'\n' order by (o->>'n')::int)
                                         from jsonb_array_elements(v_opts) o),
                           'body', v_body,
                           'legacy_url','https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
                           'legacy_body', jsonb_build_object('event','payment_alert_which_order',
                                            'phone', v_phone, 'text', v_body)));
    exception when others then
      perform public._wa_log_attempt('payment_alert_which_order', null, v_phone, 'skipped', false,
                                     'caller_error: ' || sqlerrm, null);
    end;
  end if;

  return public.payment_alert_state(a.id)
    || jsonb_build_object('asked', v_qid is not null, 'options', v_opts, 'ask_body', v_body);
end $$;

-- ─── the reply resolves the match ───────────────────────────────────────────
-- Called from the inbound WhatsApp path BEFORE the assistant classifies, the
-- same way wa_assistant_intent.defer_to hands a question to its owner.
-- Returns ok:false untouched when this feature has no open question, so the
-- assistant carries on exactly as before.
create or replace function public.payment_alert_answer_try(p_phone text, p_text text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  q public.payment_alert_question%rowtype; a public.payment_alerts%rowtype;
  v_ph text; v_pick int; v_opt jsonb; v_claim uuid; v_verify jsonb; v_reply text;
begin
  v_ph := right(regexp_replace(coalesce(p_phone,''), '\D','','g'), 10);
  if coalesce(length(v_ph),0) <> 10 then
    return jsonb_build_object('ok', false, 'reason','no_phone');
  end if;

  select * into q from public.payment_alert_question
   where phone = v_ph and status = 'open'
     and asked_at > now() - interval '3 days'
   order by asked_at desc limit 1;
  if q.id is null then return jsonb_build_object('ok', false, 'reason','no_open_question'); end if;

  -- The reply is a number from the list, or an order code from it.
  v_pick := nullif(regexp_replace(coalesce(p_text,''), '\D','','g'), '')::int;
  if v_pick is not null then
    select o into v_opt from jsonb_array_elements(q.options) o
     where (o->>'n')::int = v_pick limit 1;
  end if;
  if v_opt is null then
    select o into v_opt from jsonb_array_elements(q.options) o
     where coalesce(p_text,'') ilike '%'||(o->>'order_code')||'%' limit 1;
  end if;

  if v_opt is null then
    return jsonb_build_object('ok', false, 'reason','not_an_option',
      'handled', true, 'question_id', q.id,
      'reply', public.uic('pay_alert.ask_badnumber',
        'That number is not on the list. Please reply with one of the numbers above.'));
  end if;

  select * into a from public.payment_alerts where id = q.alert_id;
  if a.id is null then
    update public.payment_alert_question set status='cancelled' where id = q.id;
    return jsonb_build_object('ok', false, 'reason','alert_gone');
  end if;

  insert into public.payment_claims
    (sender_type, amount, payee_vpa, payee_name, utr, app, order_id,
     received_at, paid_ts, status, payment_method, zone_id, business_date,
     autolink_note, raw_ocr)
  values ('payment_alert', round(coalesce(a.parsed_amount, q.amount),2), nullif(a.parsed_vpa,''),
          nullif(a.parsed_sender,''), nullif(a.parsed_utr,''), a.package_name,
          (v_opt->>'order_id')::uuid, a.posted_at, a.posted_at, 'claimed', 'online',
          a.zone_id, a.business_date, 'payment_alert:'||a.id::text,
          jsonb_build_object('source','payment_alert_reply','alert_id',a.id,
                             'question_id',q.id,'package',a.package_name))
  returning id into v_claim;

  v_verify := public._payment_claim_verify_core(v_claim, (v_opt->>'order_id')::uuid,
                'auto_payment_alert_reply');
  if not coalesce((v_verify->>'ok')::boolean, false) then
    delete from public.payment_claims where id = v_claim;
    return jsonb_build_object('ok', false, 'reason','verify_failed', 'handled', true,
      'question_id', q.id,
      'reply', public.uic('pay_alert.ask_badnumber',
        'That number is not on the list. Please reply with one of the numbers above.'));
  end if;

  update public.payment_alert_question
     set status='answered', answered_at = now(), answer_text = left(coalesce(p_text,''),200),
         chosen_order_id = (v_opt->>'order_id')::uuid
   where id = q.id;

  update public.payment_alerts
     set status = 'matched', matched_claim_id = v_claim,
         matched_order_id = (v_opt->>'order_id')::uuid,
         matched_customer_id = coalesce(q.customer_id, matched_customer_id),
         match_reason = public.uic('pay_alert.match.customer_reply',
                                   'Matched by the customer''s own reply'),
         updated_at = now()
   where id = a.id;

  perform public._pa_learn_sender(a.id, v_claim);
  perform public._pa_speak(a.id);

  v_reply := replace(replace(
    public.uic('pay_alert.ask_thanks_tpl','Thank you — {amount} is now recorded against {order_code}.'),
    '{amount}', public.inr_money_compact(coalesce(a.parsed_amount, q.amount))),
    '{order_code}', coalesce(v_opt->>'order_code',''));

  return jsonb_build_object('ok', true, 'handled', true, 'question_id', q.id,
    'alert_id', a.id, 'claim_id', v_claim, 'order_id', (v_opt->>'order_id')::uuid,
    'reply', v_reply);
end $$;

-- ─── the voice ──────────────────────────────────────────────────────────────
-- The sentence the partner phone speaks is built HERE. Dart plays a string.
-- inr_money_compact, not inr_money: a voice saying "five hundred rupees and
-- zero zero paise" is worse than one saying "five hundred rupees", and the
-- spec's own example is "₹500 received from Pooja Medical".
create or replace function public._pa_speak(p_alert_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  a public.payment_alerts%rowtype; v_msg text; v_sender text; v_pid bigint;
begin
  select * into a from public.payment_alerts where id = p_alert_id;
  if a.id is null or a.parsed_amount is null then return; end if;

  -- The customer's own name beats the handle the bank printed.
  select coalesce(nullif(btrim(pp.pharmacy_name),''), '') into v_sender
    from public.pharmacy_profiles pp where pp.id = a.matched_customer_id;
  v_sender := coalesce(nullif(v_sender,''), nullif(a.parsed_sender,''), nullif(a.parsed_vpa,''));

  if nullif(v_sender,'') is null then
    v_msg := replace(public.uic('pay_alert.speak_tpl_nosender','{amount} received'),
                     '{amount}', public.inr_money_compact(a.parsed_amount));
  else
    v_msg := replace(replace(
               public.uic('pay_alert.speak_tpl','{amount} received from {sender}'),
               '{amount}', public.inr_money_compact(a.parsed_amount)),
               '{sender}', v_sender);
  end if;

  select p.id into v_pid from public.region_partners p
   where p.zone_id = a.zone_id order by p.id limit 1;

  insert into public.payment_alert_speak
    (alert_id, claim_id, order_id, customer_id, zone_id, partner_id, message, amount)
  values (a.id, a.matched_claim_id, a.matched_order_id, a.matched_customer_id,
          a.zone_id, v_pid, v_msg, a.parsed_amount);
end $$;

-- What the partner app pulls (or receives over realtime) and speaks.
create or replace function public.payment_alert_speak_pull(p_limit int default 5)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_zone smallint; v_rows jsonb; v_ids bigint[];
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false) or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  v_zone := coalesce(public.partner_zone_id(), public.admin_active_zone());

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'message', s.message,
           'amount_label', public.inr_money(s.amount),
           'alert_id', s.alert_id, 'order_id', s.order_id,
           'at_label', to_char(s.created_at at time zone 'Asia/Kolkata','hh12:mi am')
         ) order by s.created_at), '[]'::jsonb),
       array_agg(s.id)
    into v_rows, v_ids
  from (select * from public.payment_alert_speak
         where spoken_at is null
           and (v_zone is null or zone_id = v_zone)
           and created_at > now() - interval '6 hours'
         order by created_at limit greatest(coalesce(p_limit,5),1)) s;

  if coalesce(array_length(v_ids,1),0) > 0 then
    update public.payment_alert_speak set spoken_at = now() where id = any(v_ids);
  end if;

  return jsonb_build_object('ok', true, 'rows', coalesce(v_rows,'[]'::jsonb),
                            'count', coalesce(array_length(v_ids,1),0));
end $$;

-- The WhatsApp route for the ask. Disabled-by-default routes are how every
-- other event ships; the copy lives in ui_copy either way.
insert into public.wa_event_routes (event_key, label, description, audience, enabled)
values ('payment_alert_which_order',
        'Payment received — which order?',
        'Sent when money arrives from a known sender and more than one of their bills could be it.',
        'customer', true)
on conflict (event_key) do update set
  label = excluded.label, description = excluded.description,
  audience = excluded.audience, updated_at = now();

revoke all on function public.payment_alert_answer_try(text, text) from anon, authenticated;
revoke all on function public._pa_match_by_sender(uuid) from anon, authenticated;
revoke all on function public._pa_ask_customer(uuid, uuid) from anon, authenticated;
grant execute on function public.payment_alert_speak_pull(int) to authenticated;


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120400_payment_alert_wa_reply
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 (5/9) — the customer's WhatsApp reply resolves the payment match.
--
-- wa_assistant_handle is re-created with ONE block added, at the top of the
-- inbound path, before the assistant classifies. Everything else in the
-- function is byte-for-byte what it was: a phone with no open payment
-- question takes exactly the old path.

CREATE OR REPLACE FUNCTION public.wa_assistant_handle(p_message_id uuid, p_classify jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m record; v_phone10 text; v_text text; v_tid uuid; v_order uuid; v_cust uuid;
  v_zone smallint; v_cfg record; v_intent record; v_facts jsonb;
  v_cls jsonb; v_intent_key text; v_conf numeric; v_sent text;
  v_reply text; v_reason text; v_outcome text := 'skipped';
  v_unanswered int; v_sla text;
  v_pa jsonb;   -- CMD #1929
begin
  select * into m from public.whatsapp_messages where id = p_message_id;
  if not found then return jsonb_build_object('ok', false, 'error','no_message'); end if;
  if coalesce(m.direction,'') <> 'in' then
    return jsonb_build_object('ok', true, 'outcome','skipped', 'reason','outbound');
  end if;

  v_phone10 := right(regexp_replace(coalesce(m.sender_phone,''), '\D','','g'), 10);
  v_text := coalesce(nullif(btrim(m.text_body),''), nullif(btrim(m.caption),''), '');
  if v_text = '' then
    return jsonb_build_object('ok', true, 'outcome','skipped', 'reason','no_text');
  end if;

  -- CMD #1929 — a payment question THIS feature asked is answered by this
  -- feature, before the assistant classifies anything. Same principle as
  -- wa_assistant_intent.defer_to: two replies to one question is worse than
  -- the slower one on its own. Nothing else in this function changes, and a
  -- phone with no open payment question takes the old path untouched.
  begin
    v_pa := public.payment_alert_answer_try(v_phone10, v_text);
  exception when others then v_pa := null;
  end;
  if coalesce((v_pa->>'handled')::boolean, false) then
    if coalesce(v_pa->>'reply','') <> '' then
      begin
        perform public.wa_notify_customer_event('wa_assistant_reply',
          nullif(v_pa->>'order_id','')::uuid, v_phone10,
          'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
          jsonb_build_object('to', v_phone10, 'tag','payment_alert',
                             'text', v_pa->>'reply'),
          jsonb_build_object('text', v_pa->>'reply'));
      exception when others then null;
      end;
    end if;
    insert into public.wa_assistant_reply (message_id, wa_message_id, phone,
      customer_id, order_id, inbound_text, intent, outcome, reason, reply_text)
    values (m.id, m.wa_message_id, v_phone10,
            nullif(v_pa->>'customer_id','')::uuid, nullif(v_pa->>'order_id','')::uuid,
            left(v_text, 500), 'payment_alert_which_order',
            case when coalesce((v_pa->>'ok')::boolean, false) then 'answered' else 'handoff' end,
            'payment_alert_' || coalesce(v_pa->>'reason','answered'),
            left(coalesce(v_pa->>'reply',''), 1000));
    return jsonb_build_object('ok', true, 'outcome','answered',
      'reason','payment_alert_which_order', 'reply', coalesce(v_pa->>'reply',''),
      'payment_alert', v_pa);
  end if;

  v_tid := public._c713_wa_thread_for(v_phone10, v_text, m.reply_to_wa_id);
  select t.customer_id, t.order_id into v_cust, v_order
    from public.order_thread t where t.id = v_tid;
  select o.zone_id into v_zone from public.orders o where o.id = v_order;

  select * into v_cfg from public.wa_assistant_config
   where zone_id = coalesce(v_zone, 0::smallint);
  if not found then
    select * into v_cfg from public.wa_assistant_config where zone_id = 0::smallint;
  end if;
  if not coalesce(v_cfg.enabled, false) then
    insert into public.wa_assistant_reply (message_id, wa_message_id, phone, zone_id,
      customer_id, order_id, thread_id, inbound_text, outcome, reason)
    values (m.id, m.wa_message_id, v_phone10, v_zone, v_cust, v_order, v_tid,
            left(v_text, 500), 'skipped', 'assistant_off');
    return jsonb_build_object('ok', true, 'outcome','skipped', 'reason','assistant_off');
  end if;

  v_cls := coalesce(p_classify, '{}'::jsonb);
  v_intent_key := coalesce(nullif(v_cls->>'intent',''), 'other');
  v_conf := coalesce((v_cls->>'confidence')::numeric, 0);
  v_sent := coalesce(nullif(v_cls->>'sentiment',''), 'neutral');
  if coalesce((v_cls->>'ok')::boolean, false) is not true then
    v_intent_key := 'other'; v_conf := 0;
    v_reason := 'classifier_' || coalesce(v_cls->>'reason', 'unavailable');
  end if;

  select * into v_intent from public.wa_assistant_intent where key = v_intent_key;

  -- Another feature owns this question. Log it and say nothing: two replies to
  -- one question is worse than the slower one on its own.
  if v_intent.defer_to is not null then
    insert into public.wa_assistant_reply (message_id, wa_message_id, phone, zone_id,
      customer_id, order_id, thread_id, inbound_text, intent, confidence, sentiment,
      outcome, reason, model)
    values (m.id, m.wa_message_id, v_phone10, v_zone, v_cust, v_order, v_tid,
            left(v_text,500), v_intent_key, v_conf, v_sent, 'skipped',
            'deferred_to_' || v_intent.defer_to, nullif(v_cls->>'model',''));
    return jsonb_build_object('ok', true, 'outcome','skipped',
      'reason','deferred_to_' || v_intent.defer_to, 'intent', v_intent_key);
  end if;

  -- The customer has come back this many times since the assistant last
  -- answered them and a person last stepped in.
  select count(*)::int into v_unanswered
    from public.wa_assistant_reply r
   where r.phone = v_phone10
     and r.created_at > now() - interval '6 hours'
     and r.outcome = 'answered';

  v_reason := coalesce(v_reason,
    case
      when v_intent is null                          then 'unknown_intent'
      when not coalesce(v_intent.enabled, false)     then 'intent_disabled'
      when coalesce(v_intent.always_handoff, false)  then 'intent_always_handoff'
      when v_sent = 'negative'                       then 'negative_sentiment'
      when v_conf < coalesce(v_cfg.min_confidence, 0.75) then 'low_confidence'
      when v_unanswered >= coalesce(v_cfg.max_unanswered, 2) then 'unanswered_followups'
      when coalesce(v_intent.needs_order, true) and v_order is null then 'no_order'
      else null
    end);

  if v_reason is not null then
    v_sla := coalesce(nullif(v_cfg.handoff_sla_label,''),
                      public.uic('wa_asst.sla_default','shortly'));
    v_reply := replace(public.uic('wa_asst.handoff',''), '{sla}', v_sla);
    v_outcome := 'handoff';
    if v_tid is not null then
      begin
        perform public._thread_append(v_tid,
          replace(public.uic('wa_asst.thread_note',''), '{reason}', v_reason),
          'system', null, null, '', 'assistant', '[]'::jsonb, null, null);
      exception when others then null; end;
    end if;
    begin
      perform public.notify('wa_assistant_handoff', v_phone10,
        jsonb_build_object('reason', v_reason, 'order_code',
                           coalesce((select order_code from public.orders where id = v_order), '')));
    exception when others then null; end;
  else
    v_facts := public._c714_order_facts(v_order);
    v_reply := public.uic(v_intent.copy_key, '');
    v_reply := replace(v_reply, '{code}',             coalesce(v_facts->>'code',''));
    v_reply := replace(v_reply, '{status}',           coalesce(v_facts->>'status',''));
    v_reply := replace(v_reply, '{eta}',              coalesce(v_facts->>'eta',''));
    v_reply := replace(v_reply, '{amount}',           coalesce(v_facts->>'amount',''));
    v_reply := replace(v_reply, '{bill_note}',        coalesce(v_facts->>'bill_note',''));
    v_reply := replace(v_reply, '{payment}',          coalesce(v_facts->>'payment',''));
    v_reply := replace(v_reply, '{payment_note}',     coalesce(v_facts->>'payment_note',''));
    v_reply := replace(v_reply, '{return_status}',    coalesce(v_facts->>'return_status',''));
    v_reply := replace(v_reply, '{unavailable}',      coalesce(v_facts->>'unavailable',''));
    v_reply := replace(v_reply, '{unavailable_note}', coalesce(v_facts->>'unavailable_note',''));
    -- An empty token must not leave doubled or dangling punctuation behind,
    -- but the sentence keeps its own full stop. (The first attempt at this
    -- swallowed the closing '.' of every reply.)
    v_reply := regexp_replace(v_reply, '\s+', ' ', 'g');
    v_reply := replace(v_reply, ' .', '.');
    v_reply := regexp_replace(v_reply, '\.{2,}', '.', 'g');
    v_reply := regexp_replace(v_reply, '[—:-]\s*$', '', 'g');
    v_reply := btrim(v_reply);
    v_outcome := case when v_reply = '' then 'handoff' else 'answered' end;
    if v_outcome = 'handoff' then v_reason := 'empty_template'; end if;
  end if;

  if coalesce(v_reply,'') <> '' then
    begin
      perform public.wa_notify_customer_event('wa_assistant_reply', v_order, v_phone10,
        'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/wa-reply',
        jsonb_build_object('to', v_phone10, 'tag', 'wa_assistant', 'text', v_reply),
        jsonb_build_object('text', v_reply));
    exception when others then
      v_outcome := 'handoff'; v_reason := coalesce(v_reason,'send_failed');
    end;
  end if;

  insert into public.wa_assistant_reply (message_id, wa_message_id, phone, zone_id,
    customer_id, order_id, thread_id, inbound_text, intent, confidence, sentiment,
    outcome, reason, reply_text, model)
  values (m.id, m.wa_message_id, v_phone10, v_zone, v_cust, v_order, v_tid,
          left(v_text, 500), v_intent_key, v_conf, v_sent, v_outcome, v_reason,
          left(coalesce(v_reply,''), 1000), nullif(v_cls->>'model',''));

  return jsonb_build_object('ok', true, 'outcome', v_outcome, 'intent', v_intent_key,
    'confidence', v_conf, 'sentiment', v_sent, 'reason', v_reason,
    'reply', coalesce(v_reply,''), 'order_id', v_order, 'thread_id', v_tid);
end $function$;


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120500_payment_alerts_screen
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 (7/9) — the one RPC the Payment alerts screen renders.
--
-- Zone- and date-scoped through admin_active_zone() / admin_active_date():
-- a partner is locked to their own zone, a super admin with no zone chosen
-- sees every zone. Zone and date live in the header picker and NOWHERE else —
-- this RPC takes neither as a parameter, on purpose.

create or replace function public.payment_alerts_screen(
  p_status text default null, p_limit int default 60)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_role  text := coalesce(public.get_my_role(),'');
  v_part  boolean := coalesce(public.is_partner(), false);
  v_zone  smallint;
  v_date  date;
  v_rows  jsonb;
  v_counts jsonb;
  v_total int;
  v_lim   int := least(greatest(coalesce(p_limit,60),1), 200);
  v_status text := nullif(btrim(lower(coalesce(p_status,''))),'');
begin
  if auth.uid() is null or not (v_part or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.screen_denied',
                            'Payment alerts are visible to a partner or an admin.'));
  end if;
  if v_status is not null and v_status not in ('new','matched','unmatched','ignored') then
    v_status := null;
  end if;

  v_zone := public.admin_active_zone();     -- NULL = every zone (super admin)
  v_date := public.admin_active_date();

  select coalesce(jsonb_agg(public.payment_alert_state(x.id) order by x.posted_at desc), '[]'::jsonb),
         count(*)::int
    into v_rows, v_total
  from (
    select a.id, a.posted_at from public.payment_alerts a
     where (v_zone is null or a.zone_id = v_zone)
       and (v_date is null or a.business_date = v_date)
       and (v_status is null or a.status = v_status)
     order by a.posted_at desc
     limit v_lim
  ) x;

  select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) into v_counts
    from (select a.status as s, count(*)::int as n from public.payment_alerts a
           where (v_zone is null or a.zone_id = v_zone)
             and (v_date is null or a.business_date = v_date)
           group by a.status) q;

  return jsonb_build_object(
    'ok', true,
    'title',        public.uic('pay_alert.title','Payment alerts'),
    'subtitle',     public.uic('pay_alert.subtitle',
                      'Payment notifications forwarded from the partner phone'),
    'empty_label',  public.uic('pay_alert.empty',
                      'No payment notifications for this zone and date yet.'),
    'empty_hint',   public.uic('pay_alert.empty_hint',
                      'Alerts appear here the moment the partner phone forwards one.'),
    'retry_label',  public.uic('pay_alert.error_retry','Retry'),
    'count_label',  case
                      when v_total = 0 then public.uic('pay_alert.count_zero','No alerts')
                      when v_total = 1 then public.uic('pay_alert.count_one','1 alert')
                      else replace(public.uic('pay_alert.count_tpl','{n} alerts'),
                                   '{n}', v_total::text) end,
    -- The chip's whole caption is built here: Dart must not join a label to
    -- a count, or the wording of that join stops being an UPDATE.
    'filters',      (select jsonb_agg(jsonb_build_object(
                        'key',   f.key,
                        'label', f.label,
                        'count', f.n,
                        'chip_label', replace(replace(
                           public.uic('pay_alert.filter.chip_tpl','{label} {count}'),
                           '{label}', f.label), '{count}', f.n::text))
                       order by f.ord)
                     from (
                       select 0 as ord, '' as key,
                              public.uic('pay_alert.filter.all','All') as label,
                              (select coalesce(sum((value)::int),0) from jsonb_each_text(v_counts)) as n
                       union all select 1, 'new',       public.uic('pay_alert.status.new','New'),           coalesce((v_counts->>'new')::int,0)
                       union all select 2, 'matched',   public.uic('pay_alert.status.matched','Matched'),   coalesce((v_counts->>'matched')::int,0)
                       union all select 3, 'unmatched', public.uic('pay_alert.status.unmatched','Needs a look'), coalesce((v_counts->>'unmatched')::int,0)
                       union all select 4, 'ignored',   public.uic('pay_alert.status.ignored','Ignored'),   coalesce((v_counts->>'ignored')::int,0)
                     ) f),
    'active_filter', coalesce(v_status,''),
    'zone_id',       v_zone,
    'date',          v_date,
    'rows',          coalesce(v_rows,'[]'::jsonb));
end $$;

-- An unmatched alert an admin recognises: re-run the matcher, or set it aside.
create or replace function public.payment_alert_set_status(p_alert_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  if p_status not in ('new','unmatched','ignored') then
    return jsonb_build_object('ok', false, 'error','bad_status');
  end if;
  update public.payment_alerts
     set status = p_status, match_reason = null, updated_at = now()
   where id = p_alert_id and status <> 'matched';   -- a verified payment is not undone here
  if p_status = 'new' then perform public.payment_alert_match(p_alert_id); end if;
  return public.payment_alert_state(p_alert_id);
end $$;

grant execute on function public.payment_alerts_screen(text, int) to authenticated;
grant execute on function public.payment_alert_set_status(uuid, text) to authenticated;


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120600_payment_alerts_selftest
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 (8/9) — the tests.
--
-- Two shapes, on purpose:
--  * payment_alert_rule_sample is DATA. A new payment app is an INSERT of a
--    rule plus an INSERT of one sample notification, and the test below covers
--    it from then on with no code change. That is the only way "parsing is
--    dynamic" stays true a year from now.
--  * payment_alert_selftest() builds its own fixture, asserts, and deletes
--    every row it made. It is safe to run on live and leaves nothing behind.

-- ─── the ingest guard, split from the ingest work ───────────────────────────
-- The door checks who is knocking; the core does the work. The selftest and
-- the AI sweep use the core, so the guard can be tested as a guard.
create or replace function public._pa_ingest_core(
  p_device text, p_package text, p_title text, p_text text,
  p_posted_at timestamptz, p_zone smallint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_md5 text; v_posted timestamptz; v_parse jsonb;
begin
  if coalesce(btrim(p_device),'') = '' or coalesce(btrim(p_package),'') = '' then
    return jsonb_build_object('ok', false, 'error','bad_request',
      'message', public.uic('pay_alert.bad_request','A device id and a package name are required.'));
  end if;

  v_posted := coalesce(p_posted_at, now());
  v_md5    := md5(coalesce(p_text,''));

  insert into public.payment_alerts
    (device_id, package_name, raw_title, raw_text, posted_at, text_md5, zone_id, business_date, status)
  values
    (btrim(p_device), btrim(p_package), nullif(btrim(coalesce(p_title,'')),''),
     p_text, v_posted, v_md5, p_zone,
     (v_posted at time zone 'Asia/Kolkata')::date, 'new')
  on conflict (device_id, package_name, posted_at, text_md5) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.payment_alerts
     where device_id = btrim(p_device) and package_name = btrim(p_package)
       and posted_at = v_posted and text_md5 = v_md5;
    return public.payment_alert_state(v_id) || jsonb_build_object('duplicate', true);
  end if;

  v_parse := public.payment_alert_parse_rules(btrim(p_package), p_title, p_text);

  if (v_parse->>'ok')::boolean then
    update public.payment_alerts
       set parsed_amount = nullif(v_parse->>'amount','')::numeric,
           parsed_utr    = nullif(v_parse->>'utr',''),
           parsed_vpa    = nullif(v_parse->>'vpa',''),
           parsed_sender = nullif(v_parse->>'sender',''),
           parse_source  = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note    = nullif(v_parse->>'rule_label',''),
           updated_at    = now()
     where id = v_id;
    perform public.payment_alert_match(v_id);

  elsif (v_parse->>'reason') = 'not_credit' then
    update public.payment_alerts
       set status = 'ignored', parse_source = 'rule',
           parse_rule_id = nullif(v_parse->>'rule_id','')::bigint,
           parse_note = public.uic('pay_alert.ignored.not_credit','Not money coming in.'),
           updated_at = now()
     where id = v_id;

  else
    update public.payment_alerts
       set parse_note = v_parse->>'reason', updated_at = now()
     where id = v_id;
    perform public._pa_ai_enqueue(v_id);
  end if;

  return public.payment_alert_state(v_id);
end $$;

create or replace function public.payment_alert_ingest(
  p_device text, p_package text, p_title text, p_text text,
  p_posted_at timestamptz default now())
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_role text := coalesce(public.get_my_role(),'');
begin
  if auth.uid() is null
     or not (coalesce(public.is_partner(),false) or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.not_authorized',
                            'Only a partner or an admin phone can forward payment alerts.'));
  end if;
  return public._pa_ingest_core(p_device, p_package, p_title, p_text, p_posted_at,
           coalesce(public.partner_zone_id(), public.admin_active_zone(), public.zone_default_id()));
end $$;
grant execute on function public.payment_alert_ingest(text, text, text, text, timestamptz) to authenticated;
revoke all on function public._pa_ingest_core(text, text, text, text, timestamptz, smallint) from anon, authenticated;

-- ─── rule samples are DATA ──────────────────────────────────────────────────
create table if not exists public.payment_alert_rule_sample (
  id             bigserial primary key,
  rule_label     text not null,
  package_name   text not null,
  raw_title      text,
  raw_text       text not null,
  expect_credit  boolean not null default true,
  expect_amount  numeric,
  expect_utr     text,
  expect_vpa     text,
  expect_sender  text,
  note           text
);
create unique index if not exists payment_alert_rule_sample_uidx
  on public.payment_alert_rule_sample (rule_label, md5(raw_text));
alter table public.payment_alert_rule_sample enable row level security;

insert into public.payment_alert_rule_sample
  (rule_label, package_name, raw_title, raw_text, expect_credit, expect_amount, expect_utr, expect_vpa, expect_sender, note)
values
 ('Google Pay','com.google.android.apps.nbu.paisa.user','You received ₹500',
  'Pooja Medical paid you ₹500. UPI transaction ID: 412345678901',
  true, 500, '412345678901', null, 'Pooja Medical', 'name before the verb'),
 ('PhonePe','com.phonepe.app','₹1,250.50 received',
  'Received ₹1,250.50 from Sharma Pharma (sharma@ybl). UTR: 523456789012',
  true, 1250.50, '523456789012', 'sharma@ybl', 'Sharma Pharma', 'amount with comma and paise'),
 ('Paytm','net.one97.paytm','Payment received',
  'Received ₹2,000 in your Paytm account from Ravi Kumar. UPI Ref No 634567890123',
  true, 2000, '634567890123', null, 'Ravi Kumar', 'name must not swallow "UPI Ref No"'),
 ('BHIM','in.org.npci.upiapp','Money received',
  'You have received Rs. 750 from anita@okaxis. UPI Transaction ID 745678901234',
  true, 750, '745678901234', 'anita@okaxis', null, 'handle only, no printed name'),
 ('SBI YONO','com.sbi.lotusintouch','SBI Alert',
  'Your A/c XX1234 is credited by Rs.3,499.00 on 12-09-26 trf from POOJA MEDICAL Ref No 856789012345',
  true, 3499.00, '856789012345', null, 'POOJA MEDICAL', '"by Rs." must not read as the sender'),
 ('HDFC Bank','com.snapwork.hdfc','HDFC Bank',
  'Rs.1200.00 credited to a/c XX9876 on 12-09-26 by a/c linked to VPA pooja@oksbi (UPI Ref No 123412341234)',
  true, 1200.00, '123412341234', 'pooja@oksbi', null, 'bank credit naming only the VPA'),
 ('ICICI iMobile','com.icicibank.pockets','ICICI Bank',
  'ICICI Bank Acct XX123 credited with Rs 4,100.00 on 12-Sep-26 from NEHA MEDICALS. UPI Ref No 111122223333',
  true, 4100.00, '111122223333', null, 'NEHA MEDICALS', null),
 ('Axis Bank','com.axis.mobile','Axis Bank',
  'INR 2,150.00 credited to A/c no. XX4321 on 12-09-26 trf from AGARWAL MEDICAL Ref No 444455556666',
  true, 2150.00, '444455556666', null, 'AGARWAL MEDICAL', null),
 ('Kotak 811','com.msf.kbank.mobile','Kotak Bank',
  'Rs.980.00 credited to your Kotak Bank A/c XX2211 by UPI from gupta.medico@paytm. RRN 777788889999',
  true, 980.00, '777788889999', 'gupta.medico@paytm', null, null),
 ('Bank of Baroda','com.bankofbaroda.mconnect','BOB Alert',
  'Rs.1,500.00 credited to A/c XX7788 on 12-09-26 trf from VERMA PHARMA Ref No 222233334444',
  true, 1500.00, '222233334444', null, 'VERMA PHARMA', null),
 ('PNB One','com.infrasofttech.PNBOne','PNB Alert',
  'Rs.650.00 credited to A/c XX3344 on 12-09-26 trf from SINGH MEDICOS Ref No 555566667777',
  true, 650.00, '555566667777', null, 'SINGH MEDICOS', null),
 ('ICICI iMobile Pay','com.csam.icici.bank.imobile','ICICI Bank',
  'Acct XX5566 credited with Rs 3,000.00 on 12-Sep-26 from JAIN DRUG HOUSE. UPI Ref No 888899990000',
  true, 3000.00, '888899990000', null, 'JAIN DRUG HOUSE', null),
 ('WhatsApp Pay','com.whatsapp','Payment received',
  '₹300 received from Neha Medicals. UPI transaction ID 998877665544',
  true, 300, '998877665544', null, 'Neha Medicals', null),
 ('Generic UPI credit','com.some.unknown.bank','Credit alert',
  'INR 899 credited. RRN 123456789012 from MEDIPLUS',
  true, 899, '123456789012', null, 'MEDIPLUS', 'unknown package falls to the * rule'),
 -- Money that is NOT arriving. Each of these carries a ₹ figure and must
 -- still be refused before anything is read out of it.
 ('PhonePe','com.phonepe.app','Payment sent','You paid ₹500 to Ravi. UTR 912345678901',
  false, null, null, null, null, 'an outgoing payment'),
 ('Google Pay','com.google.android.apps.nbu.paisa.user','Payment request','Ravi is requesting ₹500',
  false, null, null, null, null, 'a collect request'),
 ('Axis Bank','com.axis.mobile','Axis Bank','Rs.900 debited from a/c XX1111 on 12-09-26. Avl Bal Rs.5000',
  false, null, null, null, null, 'a debit'),
 ('Paytm','net.one97.paytm','Cashback','You received ₹20 cashback on your last order',
  false, null, null, null, null, 'cashback is not a customer payment')
on conflict (rule_label, md5(raw_text)) do nothing;

-- ─── the self-test ──────────────────────────────────────────────────────────
create or replace function public.payment_alert_selftest()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_pass int := 0; v_fail int := 0;
  v_dev text := 'selftest-1929';
  v_zone smallint := 1;
  v_cust uuid; v_uid uuid; v_order uuid; v_order2 uuid;
  v_claim uuid; v_claim2 uuid;
  v_alert uuid; v_st jsonb; v_r jsonb; s record;
  v_parse jsonb; v_repl boolean := false; v_now timestamptz := now();
  v_speak text; v_n int; v_q bigint;

  procedure_note text;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin')
     and auth.uid() is not null then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  -- Triggers off for the fixture only: this must not raise an order-placed
  -- alert, a WhatsApp message or an invoice on live.
  begin
    set local session_replication_role = replica;
    v_repl := true;
  exception when others then v_repl := false;
  end;

  -- ── fixture ───────────────────────────────────────────────────────────────
  v_uid  := '11111111-1111-4111-8111-191919291929'::uuid;
  v_cust := '22222222-2222-4222-8222-191919291929'::uuid;
  insert into public.pharmacy_profiles
    (id, user_id, pharmacy_name, phone, whatsapp_no, zone_id, address, city, pincode)
  values (v_cust, v_uid, 'Selftest Pharma 1929', '9000019290', '9000019290', v_zone,
          'Selftest address', 'Selftest city', '000000')
  on conflict (id) do update set pharmacy_name = excluded.pharmacy_name,
                                 user_id = excluded.user_id, zone_id = excluded.zone_id;

  insert into public.orders (id, user_id, status, total_amount, zone_id, created_at, order_code)
  values ('33333333-3333-4333-8333-191919291929'::uuid, v_uid, 'pending', 5000, v_zone, v_now, 'ST1929A')
  on conflict (id) do update set status='pending', total_amount=5000, user_id=excluded.user_id
  returning id into v_order;
  insert into public.orders (id, user_id, status, total_amount, zone_id, created_at, order_code)
  values ('44444444-4444-4444-8444-191919291929'::uuid, v_uid, 'pending', 7000, v_zone, v_now, 'ST1929B')
  on conflict (id) do update set status='pending', total_amount=7000, user_id=excluded.user_id
  returning id into v_order2;

  -- ── 1. every seeded rule, from the sample table ───────────────────────────
  for s in select * from public.payment_alert_rule_sample order by id loop
    v_parse := public.payment_alert_parse_rules(s.package_name, s.raw_title, s.raw_text);
    if not s.expect_credit then
      if coalesce((v_parse->>'ok')::boolean,false) = false
         and coalesce(v_parse->>'reason','') = 'not_credit' then
        v_pass := v_pass + 1;
        v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label||' (refused)','ok',true);
      else
        v_fail := v_fail + 1;
        v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label||' (refused)','ok',false,
                            'got', v_parse);
      end if;
    elsif coalesce((v_parse->>'ok')::boolean,false)
      and round(coalesce((v_parse->>'amount')::numeric,-1),2) = round(s.expect_amount,2)
      and coalesce(public._pa_digits(v_parse->>'utr'),'') = coalesce(public._pa_digits(s.expect_utr),'')
      and lower(coalesce(v_parse->>'vpa','')) = lower(coalesce(s.expect_vpa,''))
      and lower(coalesce(v_parse->>'sender','')) = lower(coalesce(s.expect_sender,'')) then
      v_pass := v_pass + 1;
      v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label,'ok',true);
    else
      v_fail := v_fail + 1;
      v_out := v_out || jsonb_build_object('case','rule:'||s.rule_label,'ok',false,
                 'expected', jsonb_build_object('amount',s.expect_amount,'utr',s.expect_utr,
                               'vpa',s.expect_vpa,'sender',s.expect_sender),
                 'got', v_parse);
    end if;
  end loop;

  -- ── 2. full round trip: claim with a UTR → alert → verified ───────────────
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, payee_name, utr, app, order_id, received_at, paid_ts,
     status, payment_method, zone_id)
  values ('selftest', 500, 'pooja@okhdfcbank', 'Pooja Medical', '412345678901',
          'gpay', v_order, v_now, v_now, 'claimed', 'online', v_zone)
  returning id into v_claim;

  v_st := public._pa_ingest_core(v_dev, 'com.google.android.apps.nbu.paisa.user',
            'You received ₹500',
            'Pooja Medical paid you ₹500. UPI transaction ID: 412345678901',
            v_now, v_zone);
  v_alert := (v_st->>'alert_id')::uuid;

  if v_st->>'status' = 'matched'
     and (select status from public.payment_claims where id = v_claim) = 'verified'
     and (select status from public.orders where id = v_order) = 'accepted'
     and (v_st->>'claim_id')::uuid = v_claim then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','roundtrip:utr_full','ok',true);
  else
    v_fail := v_fail + 1;
    v_out := v_out || jsonb_build_object('case','roundtrip:utr_full','ok',false,'got',v_st,
               'claim_status',(select status from public.payment_claims where id = v_claim),
               'order_status',(select status from public.orders where id = v_order));
  end if;

  -- the spoken sentence, built in SQL
  select message into v_speak from public.payment_alert_speak
   where alert_id = v_alert order by id desc limit 1;
  if v_speak = public.inr_money_compact(500) || ' received from Selftest Pharma 1929' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','speak:sentence','ok',true,'message',v_speak);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','speak:sentence','ok',false,'message',coalesce(v_speak,'<none>'));
  end if;

  -- the sender was learned off that verified claim
  if exists (select 1 from public.customer_payment_senders
              where customer_id = v_cust and lower(sender_name) = lower('Pooja Medical')) then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','learn:sender','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','learn:sender','ok',false);
  end if;

  -- ── 3. idempotency: the same notification again is ONE row ────────────────
  v_st := public._pa_ingest_core(v_dev, 'com.google.android.apps.nbu.paisa.user',
            'You received ₹500',
            'Pooja Medical paid you ₹500. UPI transaction ID: 412345678901',
            v_now, v_zone);
  select count(*)::int into v_n from public.payment_alerts where device_id = v_dev
   and text_md5 = md5('Pooja Medical paid you ₹500. UPI transaction ID: 412345678901');
  if coalesce((v_st->>'duplicate')::boolean,false) and v_n = 1 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ingest:idempotent','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ingest:idempotent','ok',false,'rows',v_n,'got',v_st);
  end if;

  -- ── 4. truncated UTR + amount ─────────────────────────────────────────────
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, utr, app, order_id, received_at, paid_ts, status,
     payment_method, zone_id)
  values ('selftest', 1234.50, 'sharma@ybl', '900011223344', 'phonepe', v_order2,
          v_now, v_now, 'claimed', 'online', v_zone)
  returning id into v_claim2;

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', '₹1,234.50 received',
            'Received ₹1,234.50 from Sharma Pharma. UTR: 223344', v_now, v_zone);
  if v_st->>'status' = 'matched'
     and (v_st->>'claim_id')::uuid = v_claim2
     and (select status from public.payment_claims where id = v_claim2) = 'verified' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','match:utr_suffix','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','match:utr_suffix','ok',false,'got',v_st);
  end if;

  -- ── 5. no UTR at all: amount + payee VPA inside ±15 min ───────────────────
  update public.orders set status='pending' where id = v_order2;
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, app, order_id, received_at, paid_ts, status,
     payment_method, zone_id)
  values ('selftest', 640, 'novutr@okicici', 'phonepe', v_order2, v_now, v_now,
          'claimed', 'online', v_zone)
  returning id into v_claim2;

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹640 from novutr@okicici', v_now, v_zone);
  if v_st->>'status' = 'matched' and (v_st->>'claim_id')::uuid = v_claim2 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','match:amount_vpa_15min','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','match:amount_vpa_15min','ok',false,'got',v_st);
  end if;

  -- ── 6. ambiguous is never guessed ─────────────────────────────────────────
  update public.orders set status='pending' where id in (v_order, v_order2);
  insert into public.payment_claims
    (sender_type, amount, payee_vpa, app, order_id, received_at, paid_ts, status, payment_method, zone_id)
  values ('selftest', 777, 'twins@okaxis', 'phonepe', v_order,  v_now, v_now, 'claimed','online',v_zone),
         ('selftest', 777, 'twins@okaxis', 'phonepe', v_order2, v_now, v_now, 'claimed','online',v_zone);

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹777 from twins@okaxis', v_now, v_zone);
  if v_st->>'status' = 'unmatched'
     and v_st->>'match_reason' = public.uic('pay_alert.unmatched.ambiguous','') then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','match:ambiguous_refused','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','match:ambiguous_refused','ok',false,'got',v_st);
  end if;

  -- ── 7. a debit is ignored, not matched ────────────────────────────────────
  v_st := public._pa_ingest_core(v_dev, 'com.axis.mobile', 'Axis Bank',
            'Rs.900 debited from a/c XX1111 on 12-09-26. Avl Bal Rs.5000', v_now, v_zone);
  if v_st->>'status' = 'ignored' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ingest:debit_ignored','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ingest:debit_ignored','ok',false,'got',v_st);
  end if;

  -- ── 8. the AI fallback, without paying Vertex ─────────────────────────────
  -- No rule can read this, so it must land unparsed and waiting.
  v_st := public._pa_ingest_core(v_dev, 'com.brand.new.wallet', 'Credit',
            'Paisa aaya: five hundred only, ref XYZ', v_now, v_zone);
  v_alert := (v_st->>'alert_id')::uuid;
  if v_st->>'source' = 'none' and v_st->>'status' = 'new' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:falls_through_to_ai','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:falls_through_to_ai','ok',false,'got',v_st);
  end if;
  -- the prompt is the backend's
  v_r := public.payment_alert_ai_prompt(v_alert);
  if coalesce((v_r->>'ok')::boolean,false)
     and v_r->>'prompt' like '%Paisa aaya%' and v_r->>'prompt' like '%is_credit%' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:prompt_from_backend','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:prompt_from_backend','ok',false);
  end if;
  -- and what it read gets matched exactly like a rule parse
  update public.orders set status='pending' where id = v_order;
  insert into public.payment_claims
    (sender_type, amount, utr, app, order_id, received_at, paid_ts, status, payment_method, zone_id)
  values ('selftest', 500, '505050505050', 'wallet', v_order, v_now, v_now, 'claimed','online',v_zone)
  returning id into v_claim2;
  v_st := public.payment_alert_ai_apply(v_alert,
            jsonb_build_object('is_credit',true,'amount',500,'utr','505050505050',
                               'vpa',null,'sender','Paisa Wallet'),
            'gemini-3.5-flash');
  if v_st->>'source' = 'ai' and v_st->>'status' = 'matched'
     and (v_st->>'claim_id')::uuid = v_claim2 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:apply_matches','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:apply_matches','ok',false,'got',v_st);
  end if;
  -- an AI answer that says "not a credit" is ignored, never matched
  v_st := public._pa_ingest_core(v_dev, 'com.brand.new.wallet', 'Credit',
            'Kuch hua hai, dekh lo', v_now, v_zone);
  v_st := public.payment_alert_ai_apply((v_st->>'alert_id')::uuid,
            jsonb_build_object('is_credit',false), 'gemini-3.5-flash');
  if v_st->>'status' = 'ignored' and v_st->>'source' = 'ai' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ai:not_credit_ignored','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ai:not_credit_ignored','ok',false,'got',v_st);
  end if;

  -- ── 9. sender learning books a no-claim payment to the only open bill ─────
  -- Close everything except ONE open bill, then send money with no UTR from a
  -- handle we have already learned.
  update public.orders set status='accepted', total_amount = 0 where id = v_order2;
  update public.orders set status='pending', total_amount = 2500 where id = v_order;
  delete from public.payment_claims where sender_type in ('selftest','payment_alert')
    and order_id in (v_order, v_order2);
  insert into public.customer_payment_senders (customer_id, vpa, sender_name, confirmed_at)
  values (v_cust, 'known@okhdfcbank', 'Known Payer', now())
  on conflict (customer_id, coalesce(lower(vpa),''), coalesce(lower(sender_name),''))
  do update set confirmed_at = now();

  select count(*)::int into v_n from public._pa_open_bills(v_cust);
  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹2,500 from known@okhdfcbank', v_now + interval '1 second', v_zone);
  if v_n = 1 and v_st->>'status' = 'matched'
     and v_st->>'match_reason' = public.uic('pay_alert.match.sender_bill','')
     and (v_st->>'order_id')::uuid = v_order then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','sender:only_open_bill','ok',true);
  else
    v_fail := v_fail + 1;
    v_out := v_out || jsonb_build_object('case','sender:only_open_bill','ok',false,
               'open_bills', v_n, 'got', v_st);
  end if;

  -- ── 10. two open bills → the customer is asked, and their reply resolves ──
  update public.orders set status='pending', total_amount = 3000 where id = v_order;
  update public.orders set status='pending', total_amount = 4000 where id = v_order2;
  delete from public.payment_claims where autolink_note like 'payment_alert:%'
    and order_id in (v_order, v_order2);
  delete from public.payment_claims where sender_type = 'selftest'
    and order_id in (v_order, v_order2);

  v_st := public._pa_ingest_core(v_dev, 'com.phonepe.app', 'Payment received',
            'Received ₹1,000 from known@okhdfcbank', v_now + interval '2 seconds', v_zone);
  v_alert := (v_st->>'alert_id')::uuid;
  select id into v_q from public.payment_alert_question where alert_id = v_alert and status='open';
  if v_st->>'status' = 'unmatched'
     and v_st->>'match_reason' = public.uic('pay_alert.unmatched.asked','')
     and v_q is not null
     and jsonb_array_length((select options from public.payment_alert_question where id = v_q)) = 2 then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:two_bills_asks','ok',true);
  else
    v_fail := v_fail + 1;
    v_out := v_out || jsonb_build_object('case','ask:two_bills_asks','ok',false,'got',v_st,
               'question', (select options from public.payment_alert_question where id = v_q));
  end if;

  -- a reply that is not on the list is refused, with the backend's own words
  v_r := public.payment_alert_answer_try('9000019290', 'maybe 9');
  if coalesce((v_r->>'handled')::boolean,false)
     and coalesce((v_r->>'ok')::boolean,true) = false
     and v_r->>'reply' = public.uic('pay_alert.ask_badnumber','') then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:bad_choice_refused','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ask:bad_choice_refused','ok',false,'got',v_r);
  end if;

  -- "1" books it against the first option and says thank you
  v_r := public.payment_alert_answer_try('9000019290', '1');
  if coalesce((v_r->>'ok')::boolean,false)
     and (v_r->>'order_id')::uuid = v_order
     and (select status from public.payment_alerts where id = v_alert) = 'matched'
     and (select status from public.payment_alert_question where id = v_q) = 'answered'
     and v_r->>'reply' like '%'||public.inr_money_compact(1000)||'%' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:reply_resolves','ok',true,'reply',v_r->>'reply');
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ask:reply_resolves','ok',false,'got',v_r);
  end if;

  -- a phone with nothing open is left entirely alone
  v_r := public.payment_alert_answer_try('9000019290', '1');
  if coalesce((v_r->>'ok')::boolean,true) = false
     and v_r->>'reason' = 'no_open_question'
     and coalesce((v_r->>'handled')::boolean,false) = false then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ask:no_question_untouched','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ask:no_question_untouched','ok',false,'got',v_r);
  end if;

  -- ── 11. the ingest door refuses a stranger ────────────────────────────────
  v_r := public.payment_alert_ingest(v_dev, 'com.phonepe.app', 'x', 'Received ₹1 from x@y', v_now);
  if coalesce((v_r->>'ok')::boolean,true) = false and v_r->>'error' = 'not_authorized' then
    v_pass := v_pass + 1; v_out := v_out || jsonb_build_object('case','ingest:guard_refuses','ok',true);
  else
    v_fail := v_fail + 1; v_out := v_out || jsonb_build_object('case','ingest:guard_refuses','ok',false,'got',v_r);
  end if;

  -- ── cleanup: nothing this test made survives it ───────────────────────────
  delete from public.payment_alert_speak
   where alert_id in (select id from public.payment_alerts where device_id = v_dev);
  delete from public.payment_alert_question
   where alert_id in (select id from public.payment_alerts where device_id = v_dev);
  delete from public.payment_alerts where device_id = v_dev;
  delete from public.customer_payment_senders where customer_id = v_cust;
  delete from public.payment_claims
   where order_id in (v_order, v_order2)
     and (sender_type in ('selftest','payment_alert') or autolink_note like 'payment_alert:%');
  delete from public.orders where id in (v_order, v_order2);
  delete from public.pharmacy_profiles where id = v_cust;

  return jsonb_build_object(
    'ok', v_fail = 0,
    'passed', v_pass, 'failed', v_fail,
    'triggers_bypassed', v_repl,
    'cases', v_out);
end $$;

revoke all on function public.payment_alert_selftest() from anon;
grant execute on function public.payment_alert_selftest() to authenticated;


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120700_payment_alerts_cron
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 (9/9) — the one scheduled job this feature needs.
--
-- The AI fallback is dispatched inline by net.http_post at ingest. That call
-- can fail (the dispatcher is down, the function cold-starts past its
-- timeout), and an alert nobody parsed is money nobody matched — so a sweep
-- re-enqueues it.
--
-- The gate matters more than the schedule here: pg_cron starving the 60
-- connection cap is a real outage this project has already had, so this task
-- does nothing at all unless an unparsed alert actually exists.
insert into public.cron_task (name, ord, mode, gate_sql, work_sql, base_interval_s, enabled, note)
values (
  'payment_alert_ai_sweep', 35, 'poll',
  $g$select exists (
       select 1 from public.payment_alerts
        where status = 'new' and parse_source = 'none'
          and created_at < now() - interval '2 minutes'
          and created_at > now() - interval '2 days')$g$,
  $w$select public.payment_alert_ai_sweep(20)$w$,
  300, true,
  'Re-enqueues the Gemini fallback for a forwarded payment notification whose inline dispatch did not land. Gated: no unparsed alert, no work.')
on conflict (name) do update set
  gate_sql = excluded.gate_sql,
  work_sql = excluded.work_sql,
  base_interval_s = excluded.base_interval_s,
  mode = excluded.mode,
  note = excluded.note,
  enabled = excluded.enabled;


-- ═══════════════════════════════════════════════════════════════════════
-- SECTION: 20260912120800_payment_alerts_nav
-- ═══════════════════════════════════════════════════════════════════════

-- CMD #1929 — the entry point, registered in the BACKEND.
--
-- The admin nav is nav_registry() over feature_registry (the Dart list this
-- command first appended to was deleted on the live base, correctly: a nav row
-- is data). So the Payment alerts row is an INSERT, its badge is one more key
-- in nav_badge_counts(), and neither needs a deploy to change again.

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   badge_source, badge_noun, roles_allowed, description, search_terms)
values
  ('admin.payment_alerts',
   'Payment alerts',
   'Money',
   'phonelink_ring',
   'payment_alerts',
   45,                              -- sits with Payment UPI (40) under Money
   'medibo',
   true,                            -- the partner's own phone is what feeds it
   'none',
   true,
   'home_money',
   'dashboard',
   'payment_alerts_unmatched',
   'to check',
   array['admin','super_admin']::text[],
   'Payment notifications forwarded from the partner phone, and what each one was matched to.',
   'payment alert notification upi utr gpay phonepe paytm bhim bank credit unmatched')
on conflict (feature_key) do update set
  label            = excluded.label,
  group_label      = excluded.group_label,
  icon_key         = excluded.icon_key,
  route_key        = excluded.route_key,
  sort_order       = excluded.sort_order,
  owner            = excluded.owner,
  partner_eligible = excluded.partner_eligible,
  is_active        = excluded.is_active,
  category         = excluded.category,
  surface          = excluded.surface,
  badge_source     = excluded.badge_source,
  badge_noun       = excluded.badge_noun,
  roles_allowed    = excluded.roles_allowed,
  description      = excluded.description,
  search_terms     = excluded.search_terms;

-- The badge counts what a human still has to look at, in the caller's own
-- zone, using the SAME zone rule the screen uses — so the badge can never
-- promise work the screen then hides.
create or replace function public._pa_badge_count()
returns bigint language sql stable security definer set search_path to 'public' as $$
  select count(*)
    from public.payment_alerts a
   where a.status = 'unmatched'
     and (public.admin_active_zone() is null or a.zone_id = public.admin_active_zone());
$$;

create or replace function public.nav_badge_counts()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'pending_orders',     (select count(*) from orders where status = 'pending'),
    'flagged_bills',      (select count(*) from pending_bills where verdict in ('needs_approval','fake')),
    'pending_customers',  (select count(*) from pharmacy_profiles where coalesce(approved,false) = false),
    'deletion_requests',  (select count(*) from account_deletion_requests where status = 'pending'),
    'order_alerts',       (select count(*) from order_alert where actioned_at is null),
    'disputes',           (select count(*) from supplier_disputes where coalesce(status,'open') = 'open'),
    'contact_inquiries',  (select count(*) from contact_inquiries),
    -- CHANGE #713 — customer messages waiting on an answer, in the caller's
    -- own zone (all zones for the office). The count is the same clamp the
    -- inbox uses, so the badge can never promise work the screen then hides.
    'customer_threads',   public._thread_badge_count(),
    -- CHANGE #696 -- partner issues waiting on the caller's OWN side: a
    -- partner sees the ones the office handed back to them, the office
    -- sees every partner's. Same clamp as partner_ticket_list(), so the
    -- badge can never promise work the screen then hides.
    'partner_issues',     public._pt_badge_count(),
    -- CMD #1929 — forwarded payments nobody has matched yet.
    'payment_alerts_unmatched', public._pa_badge_count()
  );
$$;

-- The DOOR is declared too. surface_route is what rg_check's c821_shell_doors
-- target reads, and a tile whose route nothing opens is exactly what it
-- exists to catch. handled_by='home_shell' is the shell's router as a whole:
-- this key's arm is in shell/shell_extra_routes.dart, which the shell's own
-- `case _ when shellExtraRouteScreen(route) != null` lookup dispatches — the
-- same half 'feedback' and 'triage' are registered through.
insert into public.surface_route (route_key, feature_key, kind, handled_by, is_active, note)
values ('payment_alerts', 'admin.payment_alerts', 'feature', 'home_shell', true,
        'Payment alerts — opened by shellExtraRouteScreen in shell/shell_extra_routes.dart (CMD #1929).')
on conflict (route_key, feature_key) do update set
  kind        = excluded.kind,
  handled_by  = excluded.handled_by,
  is_active   = excluded.is_active,
  note        = excluded.note,
  updated_at  = now();
