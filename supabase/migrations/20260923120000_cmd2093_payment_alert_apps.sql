-- CMD #2093 — PAYMENT ALERTS: WHICH APPS, WHICH CREDITS, AND SAYING SO.
--
-- ₹50,000 turned out to be a PhonePe ad and ₹5 a PhonePe chat. Both were read
-- as money because every payment app on the phone was allowed to speak, and
-- because a "credit" with no reference number was still a credit. This change
-- gives an admin the two switches that stop both, and makes an accepted credit
-- actually announce itself:
--
--   1. an on/off picker over EVERY app rule (business apps first) — off means
--      the device is never handed that package, so it is dropped on the phone;
--   2. "Look for UTR" — on (the default), a notification with no UTR/Ref/RRN
--      is dropped with the note 'no_utr' and never reaches the queue;
--   3. every ACCEPTED credit speaks and posts a phone notification, matched or
--      not (before today only a credit that found an order ever spoke);
--   4. the queue is newest first;
--   5. a header card naming the collection mode and the active UPI id.
--
-- Every label, every default and every order below is backend data.

-- ── 1. Schema ───────────────────────────────────────────────────────────────
alter table public.payment_alert_rules
  add column if not exists app_kind text;

alter table public.payment_listener_config
  add column if not exists look_for_utr boolean not null default true,
  add column if not exists c2093_defaults_applied boolean not null default false;

insert into public.payment_listener_config (id) values (true)
on conflict (id) do nothing;

-- ── 2. The 16 apps, seeded only where that package has no rule at all ───────
-- Live already carries all sixteen (the three merchant apps were added by hand,
-- with no migration file, so their exact package names are not knowable from a
-- branch). Seeding per-package with a NOT EXISTS guard leaves every live row
-- untouched and brings a fresh database to the same list.
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
seed(package_name, label, priority, kind, app_kind, note) as (values
  ('com.phonepe.business.app',    'PhonePe for Business',   5, 'upi',  'business', 'Merchant app: the one that hears a real shop payment'),
  ('net.one97.paytm.merchant',    'Paytm for Business',     5, 'upi',  'business', 'Paytm merchant credit alert'),
  ('com.google.android.apps.nbu.paisa.merchant',
                                  'Google Pay for Business',5, 'upi',  'business', 'GPay for Business credit alert'),
  ('com.google.android.apps.nbu.paisa.user', 'Google Pay',      10, 'upi',  'consumer', 'GPay: "Pooja Medical paid you ₹500. UPI transaction ID: 4123…"'),
  ('com.phonepe.app',                        'PhonePe',         10, 'upi',  'consumer', 'PhonePe: "₹1,250.50 received from Sharma Pharma. UTR: 5234…"'),
  ('net.one97.paytm',                        'Paytm',           10, 'upi',  'consumer', 'Paytm: "Received ₹2,000 in your Paytm account from Ravi Kumar"'),
  ('in.org.npci.upiapp',                     'BHIM',            10, 'upi',  'consumer', 'BHIM / NPCI reference app'),
  ('com.whatsapp',                           'WhatsApp Pay',    30, 'upi',  'consumer', 'WhatsApp payments notification'),
  ('com.sbi.lotusintouch',                   'SBI YONO',        20, 'bank', 'bank', 'SBI: "A/c XX1234 is credited by Rs.3,499 trf from POOJA MEDICAL"'),
  ('com.snapwork.hdfc',                      'HDFC Bank',       20, 'bank', 'bank', 'HDFC MobileBanking credit alert'),
  ('com.icicibank.pockets',                  'ICICI iMobile',   20, 'bank', 'bank', 'ICICI iMobile credit alert'),
  ('com.axis.mobile',                        'Axis Bank',       20, 'bank', 'bank', 'Axis Mobile credit alert'),
  ('com.msf.kbank.mobile',                   'Kotak 811',       20, 'bank', 'bank', 'Kotak credit alert'),
  ('com.bankofbaroda.mconnect',              'Bank of Baroda',  20, 'bank', 'bank', 'BoB M-Connect credit alert'),
  ('com.infrasofttech.PNBOne',               'PNB One',         20, 'bank', 'bank', 'PNB One credit alert'),
  ('com.csam.icici.bank.imobile',            'ICICI iMobile Pay',20,'bank', 'bank', 'ICICI iMobile Pay credit alert'),
  ('*',                                      'Generic UPI credit',900,'upi','any',  'Fallback rule for a package with no rule of its own')
)
insert into public.payment_alert_rules
  (package_name, label, app_kind, amount_regex, utr_regex, vpa_regex, sender_regex,
   ignore_regex, priority, enabled, note)
select s.package_name, s.label, s.app_kind, k.amount_re, k.utr_re, k.vpa_re, k.sender_re,
       case when s.kind = 'bank' then k.ignore_bank else k.ignore_upi end,
       s.priority, (s.app_kind in ('business','bank')), s.note
  from seed s cross join k
 where not exists (select 1 from public.payment_alert_rules r
                    where r.package_name = s.package_name);

-- ── 3. Every rule gets a kind ───────────────────────────────────────────────
-- Classified from what the row already says about itself, so a package added
-- by hand on live is classified the same way a seeded one is.
update public.payment_alert_rules r
   set app_kind = case
     when r.package_name = '*' then 'any'
     when r.package_name ilike '%business%' or r.package_name ilike '%merchant%'
       or r.label        ilike '%business%' or r.label        ilike '%merchant%'
       then 'business'
     when r.package_name in (
       'com.sbi.lotusintouch','com.snapwork.hdfc','com.icicibank.pockets',
       'com.axis.mobile','com.msf.kbank.mobile','com.bankofbaroda.mconnect',
       'com.infrasofttech.PNBOne','com.csam.icici.bank.imobile')
       or r.label ilike '%bank%' or r.label ilike '%yono%' or r.label ilike '%kotak%'
       then 'bank'
     else 'consumer' end
 where r.app_kind is null;

-- ── 4. The defaults, applied exactly once ───────────────────────────────────
-- Business + banks on, consumer off, and the catch-all off so a package with
-- no rule of its own is ignored instead of guessed at. Guarded by a flag: an
-- admin who later turns an app back on must not have that undone by a replay.
update public.payment_alert_rules
   set enabled = (app_kind in ('business','bank')), updated_at = now()
 where not (select c2093_defaults_applied from public.payment_listener_config where id);

update public.payment_listener_config
   set c2093_defaults_applied = true, updated_at = now()
 where id and not c2093_defaults_applied;
