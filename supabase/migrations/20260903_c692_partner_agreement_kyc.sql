-- CHANGE #692 — Partner onboarding: agreement e-sign + KYC documents, and the
-- go-live gate that keeps an unsigned / unverified partner out of the order flow.
--
-- What existed before this: partner_onboarding_step/state (a checklist an ADMIN
-- ticked), region_partners' own gstin / dl_20b / dl_21b / agreement_doc_path
-- columns, partner_licence_card + partner_licence_expiry_sweep (expiry dates),
-- and partner_set_active's "missing_count > 0 needs an override reason" gate.
-- What did NOT exist: any agreement a partner actually SIGNS, any document a
-- partner UPLOADS themselves, any verification verdict, and any gate stopping a
-- zone from being handed to a partner who has signed nothing.
--
-- Everything below is data-driven on purpose: a new required document is one
-- INSERT into partner_kyc_doc_type, a new agreement is one row in
-- partner_agreement_version, and every word on both screens is a ui_copy key.

-- ── 1. the agreement, versioned ─────────────────────────────────────────────
create table if not exists public.partner_agreement_version (
  id             bigserial primary key,
  version        int not null unique,
  title          text not null default '',
  body           text not null default '',
  effective_from date not null default current_date,
  is_published   boolean not null default false,
  published_at   timestamptz,
  created_at     timestamptz not null default now(),
  created_by     text not null default ''
);

-- One acceptance per partner per version. A version bump therefore leaves the
-- old signature in place as history and makes the partner unsigned AGAIN,
-- which is the whole point of versioning the text.
create table if not exists public.partner_agreement_signature (
  id            bigserial primary key,
  partner_id    bigint not null,
  version_id    bigint not null references public.partner_agreement_version(id),
  version       int not null,
  status        text not null default 'pending',   -- pending | signed
  signer_name   text not null default '',
  signer_phone  text not null default '',
  body_snapshot text not null default '',          -- the text as it stood when signed
  code_hash     text,
  sent_at       timestamptz,
  expires_at    timestamptz,
  attempts      int not null default 0,
  locked_until  timestamptz,
  signed_at     timestamptz,
  signed_by     uuid,
  signed_ip     text not null default '',
  signed_agent  text not null default '',
  doc_id        uuid,
  doc_bucket    text not null default '',
  doc_path      text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (partner_id, version_id)
);
create index if not exists partner_agreement_signature_partner_idx
  on public.partner_agreement_signature (partner_id, status);

-- ── 2. the KYC documents ────────────────────────────────────────────────────
-- The CATALOGUE is data. `licence_kind` is how a verified document with an
-- expiry lands back on region_partners, so partner_licence_card and
-- partner_licence_expiry_sweep keep working with nothing added to them.
create table if not exists public.partner_kyc_doc_type (
  doc_key      text primary key,
  label        text not null,
  hint         text not null default '',
  is_required  boolean not null default true,
  wants_number boolean not null default false,
  wants_expiry boolean not null default false,
  licence_kind text,               -- gstin | dl_20b | dl_21b (partner_licence_card)
  path_field   text,               -- region_partners doc-path column kept in sync
  num_field    text,               -- region_partners number column kept in sync
  onboard_step text,               -- partner_onboarding_step.step_key it satisfies
  sort_order   int not null default 100,
  is_active    boolean not null default true
);

create table if not exists public.partner_kyc_doc (
  id            bigserial primary key,
  partner_id    bigint not null,
  doc_key       text not null,
  bucket        text not null default 'partner-receipts',
  path          text not null default '',
  file_name     text not null default '',
  number        text not null default '',
  expiry        date,
  status        text not null default 'pending',   -- pending | verified | rejected
  reject_reason text not null default '',
  uploaded_at   timestamptz not null default now(),
  uploaded_by   text not null default '',
  reviewed_at   timestamptz,
  reviewed_by   text not null default '',
  updated_at    timestamptz not null default now(),
  unique (partner_id, doc_key)
);
create index if not exists partner_kyc_doc_status_idx
  on public.partner_kyc_doc (status, partner_id);

-- One reminder per partner per day, so the sweep can run on the dispatcher
-- without spamming a partner who is simply slow.
create table if not exists public.partner_kyc_reminder (
  partner_id bigint not null,
  kind       text not null,
  sent_on    date not null,
  primary key (partner_id, kind, sent_on)
);

alter table public.partner_agreement_version  enable row level security;
alter table public.partner_agreement_signature enable row level security;
alter table public.partner_kyc_doc_type       enable row level security;
alter table public.partner_kyc_doc            enable row level security;
alter table public.partner_kyc_reminder       enable row level security;
-- No policies: every read and write goes through the SECURITY DEFINER RPCs
-- below, which is how every other partner table on this platform is reached.

-- ── the document catalogue ──────────────────────────────────────────────────
insert into public.partner_kyc_doc_type
  (doc_key, label, hint, is_required, wants_number, wants_expiry,
   licence_kind, path_field, num_field, onboard_step, sort_order)
values
  ('dl_20b','Drug Licence 20B','Wholesale drug licence, Form 20B',
   true, true, true, 'dl_20b','dl20b_doc_path','dl_20b','dl_20b',10),
  ('dl_21b','Drug Licence 21B','Wholesale drug licence, Form 21B',
   true, true, true, 'dl_21b','dl21b_doc_path','dl_21b','dl_21b',20),
  ('gst','GST certificate','Registration certificate showing the GSTIN',
   true, true, false, 'gstin','gst_doc_path','gstin','gst',30),
  ('pan','PAN card','PAN of the firm named on the licence',
   true, true, false, null, null, null, null, 40),
  ('bank_proof','Cancelled cheque or bank letter','Proof of the settlement account',
   true, false, false, null, null, null, null, 50),
  ('shop_photo','Shop photo','Storefront with the board visible',
   false, false, false, null, null, null, null, 60)
on conflict (doc_key) do nothing;

-- ── copy (every visible word) ───────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('partner_agree.heading',        to_jsonb('Partner agreement'::text)),
  ('partner_agree.sub',            to_jsonb('Read the agreement, then sign it with the code we send on WhatsApp.'::text)),
  ('partner_agree.signed_label',   to_jsonb('Signed'::text)),
  ('partner_agree.unsigned_label', to_jsonb('Not signed'::text)),
  ('partner_agree.resign_label',   to_jsonb('Re-signature required'::text)),
  ('partner_agree.version_label',  to_jsonb('Version {v} · effective {d}'::text)),
  ('partner_agree.signed_by',      to_jsonb('Signed by {name} on {d}'::text)),
  ('partner_agree.signed_ip',      to_jsonb('From {ip}'::text)),
  ('partner_agree.sign_label',     to_jsonb('Sign the agreement'::text)),
  ('partner_agree.resign_cta',     to_jsonb('Sign the new version'::text)),
  ('partner_agree.name_hint',      to_jsonb('Full name of the person signing'::text)),
  ('partner_agree.phone_hint',     to_jsonb('WhatsApp number for the code'::text)),
  ('partner_agree.send_label',     to_jsonb('Send code'::text)),
  ('partner_agree.verify_label',   to_jsonb('Verify and sign'::text)),
  ('partner_agree.code_hint',      to_jsonb('6-digit code'::text)),
  ('partner_agree.otp_sent',       to_jsonb('Code sent on WhatsApp.'::text)),
  ('partner_agree.signed_toast',   to_jsonb('Agreement signed. Thank you.'::text)),
  ('partner_agree.doc_label',      to_jsonb('Signed copy (PDF)'::text)),
  ('partner_agree.doc_building',   to_jsonb('Preparing the signed copy…'::text)),
  ('partner_agree.none_published', to_jsonb('No agreement has been published yet.'::text)),
  ('partner_agree.err_no_partner', to_jsonb('That partner does not exist.'::text)),
  ('partner_agree.err_not_authorized', to_jsonb('You do not have access to the partner agreement.'::text)),
  ('partner_agree.err_no_name',    to_jsonb('Enter the name of the person signing.'::text)),
  ('partner_agree.err_bad_phone',  to_jsonb('Enter a valid 10-digit WhatsApp number.'::text)),
  ('partner_agree.err_too_soon',   to_jsonb('Code already sent — wait a moment before asking again.'::text)),
  ('partner_agree.err_expired',    to_jsonb('That code has expired — ask for a new one.'::text)),
  ('partner_agree.err_bad_code',   to_jsonb('That code is not right.'::text)),
  ('partner_agree.err_locked',     to_jsonb('Too many wrong codes. Try again later.'::text)),
  ('partner_agree.err_no_pending', to_jsonb('Ask for a code first.'::text)),
  ('partner_agree.already_signed', to_jsonb('This version is already signed.'::text)),
  ('partner_agree.admin_heading',  to_jsonb('Agreement versions'::text)),
  ('partner_agree.admin_new',      to_jsonb('New version'::text)),
  ('partner_agree.admin_publish',  to_jsonb('Publish'::text)),
  ('partner_agree.admin_saved',    to_jsonb('Agreement version saved.'::text)),
  ('partner_agree.admin_published',to_jsonb('Version {v} published. Every partner must sign it again.'::text)),
  ('partner_agree.draft_label',    to_jsonb('Draft'::text)),
  ('partner_agree.published_label',to_jsonb('Published'::text)),
  ('partner_agree.signed_count',   to_jsonb('{n} of {t} partners signed'::text)),
  ('partner_agree.err_body',       to_jsonb('The agreement text cannot be empty.'::text)),
  ('partner_kyc.heading',          to_jsonb('My documents'::text)),
  ('partner_kyc.sub',              to_jsonb('Upload each document once. We verify them before your zone goes live.'::text)),
  ('partner_kyc.upload_label',     to_jsonb('Upload'::text)),
  ('partner_kyc.replace_label',    to_jsonb('Replace'::text)),
  ('partner_kyc.view_label',       to_jsonb('View'::text)),
  ('partner_kyc.required_label',   to_jsonb('Required'::text)),
  ('partner_kyc.optional_label',   to_jsonb('Optional'::text)),
  ('partner_kyc.missing_label',    to_jsonb('Not uploaded'::text)),
  ('partner_kyc.pending_label',    to_jsonb('Awaiting verification'::text)),
  ('partner_kyc.verified_label',   to_jsonb('Verified'::text)),
  ('partner_kyc.rejected_label',   to_jsonb('Rejected'::text)),
  ('partner_kyc.rejected_because', to_jsonb('Rejected: {why}'::text)),
  ('partner_kyc.number_hint',      to_jsonb('Number as printed'::text)),
  ('partner_kyc.expiry_hint',      to_jsonb('Valid until'::text)),
  ('partner_kyc.expiry_label',     to_jsonb('Valid until {d}'::text)),
  ('partner_kyc.saved_toast',      to_jsonb('Document uploaded. We will verify it shortly.'::text)),
  ('partner_kyc.progress',         to_jsonb('{done} of {total} verified'::text)),
  ('partner_kyc.all_done',         to_jsonb('All required documents verified.'::text)),
  ('partner_kyc.outstanding',      to_jsonb('{n} document(s) still outstanding'::text)),
  ('partner_kyc.err_bad_doc',      to_jsonb('That is not a document we ask for.'::text)),
  ('partner_kyc.err_no_file',      to_jsonb('Attach the document file first.'::text)),
  ('partner_kyc.err_number',       to_jsonb('Enter the number printed on the document.'::text)),
  ('partner_kyc.err_expiry',       to_jsonb('Enter the date this document is valid until.'::text)),
  ('partner_kyc.err_not_authorized', to_jsonb('You do not have access to partner documents.'::text)),
  ('partner_kyc.review_heading',   to_jsonb('Documents'::text)),
  ('partner_kyc.verify_label',     to_jsonb('Verify'::text)),
  ('partner_kyc.reject_label',     to_jsonb('Reject'::text)),
  ('partner_kyc.reject_hint',      to_jsonb('Why is it being rejected?'::text)),
  ('partner_kyc.err_reason',       to_jsonb('A rejection needs a reason the partner can act on.'::text)),
  ('partner_kyc.verified_toast',   to_jsonb('Document verified.'::text)),
  ('partner_kyc.rejected_toast',   to_jsonb('Document rejected — the partner has been told why.'::text)),
  ('partner_kyc.uploaded_on',      to_jsonb('Uploaded {d}'::text)),
  ('partner_kyc.reminder_title',   to_jsonb('Documents pending'::text)),
  ('partner_kyc.reminder_body',    to_jsonb('{partner}: {n} document(s) still needed before your zone can go live.'::text)),
  ('partner_golive.heading',       to_jsonb('Go-live'::text)),
  ('partner_golive.ready_label',   to_jsonb('Ready to take orders'::text)),
  ('partner_golive.blocked_label', to_jsonb('Not ready to take orders'::text)),
  ('partner_golive.blocked_reason',to_jsonb('This partner cannot be given orders yet: {why}'::text)),
  ('partner_golive.b_agreement',   to_jsonb('the partner agreement is not signed'::text)),
  ('partner_golive.b_agreement_old', to_jsonb('a newer agreement version is unsigned'::text)),
  ('partner_golive.b_kyc',         to_jsonb('{n} required document(s) are not verified'::text)),
  ('partner_golive.b_onboarding',  to_jsonb('{n} onboarding item(s) are outstanding'::text)),
  ('partner_golive.and',           to_jsonb(' and '::text)),
  ('partner_golive.err_no_partner',to_jsonb('That partner does not exist.'::text))
on conflict (key) do nothing;

-- WhatsApp / push routes for the three new events. `partner_licence_expiry` is
-- added with them: partner_licence_expiry_sweep() has been emitting it since
-- #657 with no route to land on, so every one of those reminders was silently
-- swallowed by the sweep's own exception handler.
insert into public.wa_event_routes
  (event_key, label, description, enabled, bypass_send_window, dedupe_minutes,
   marketing_guard, audience, push_enabled, email_enabled, push_title, push_body,
   deep_link_kind, email_mode, wa_category)
values
  ('partner_kyc_pending','Partner · documents pending',
   'Required onboarding documents this partner has not uploaded or that were rejected.',
   true, true, 1440, true, 'partner', true, false,
   'Documents pending','{n} document(s) still needed','/partner','fallback','utility'),
  ('partner_kyc_verified','Partner · document verified',
   'A document this partner uploaded has been verified.',
   true, true, 45, true, 'partner', true, false,
   'Document verified','{label} is verified','/partner','fallback','utility'),
  ('partner_kyc_rejected','Partner · document rejected',
   'A document this partner uploaded was rejected, with the reason.',
   true, true, 45, true, 'partner', true, false,
   'Document rejected','{label}: {why}','/partner','fallback','utility'),
  ('partner_agreement_pending','Partner · agreement unsigned',
   'The current partner agreement version has not been signed by this partner.',
   true, true, 1440, true, 'partner', true, false,
   'Agreement not signed','Sign version {v} to go live','/partner','fallback','utility'),
  ('partner_licence_expiry','Partner · licence expiring',
   'A licence, GST registration or agreement on this partner is expiring.',
   true, true, 1440, true, 'partner', true, false,
   'Licence expiring','{label} expires {d}','/partner','fallback','utility')
on conflict (event_key) do nothing;

-- ── 3. helpers ──────────────────────────────────────────────────────────────
-- Who this call is about. An admin may name a partner; a partner user always
-- gets their own row and can never name another.
create or replace function public._c692_pid(p_partner_id bigint)
returns bigint language sql stable security definer set search_path to 'public' as $$
  select case when public.role_for_medibo_only() in ('admin','super_admin')
              then coalesce(p_partner_id, public.my_partner_id())
              else public.my_partner_id() end
$$;

create or replace function public._c692_admin()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select public.role_for_medibo_only() in ('admin','super_admin')
$$;

-- The published agreement a partner is measured against: the highest published
-- version whose effective date has arrived. Nothing published = nothing to sign,
-- and the gate below says so rather than blocking on a version that never was.
create or replace function public._c692_current_version()
returns public.partner_agreement_version
language sql stable security definer set search_path to 'public' as $$
  select * from public.partner_agreement_version
   where is_published and effective_from <= current_date
   order by version desc limit 1
$$;

-- Word-wrap for the PDF snapshot. The renderer clips a cell to its column, so
-- the paragraph has to arrive already broken into lines — in SQL, like every
-- other string this platform prints.
create or replace function public._c692_wrap(p_text text, p_width int default 108)
returns text[] language plpgsql immutable as $$
declare v_out text[] := '{}'; v_para text; v_line text; v_word text;
begin
  foreach v_para in array regexp_split_to_array(coalesce(p_text,''), E'\n') loop
    if btrim(v_para) = '' then v_out := v_out || ''::text; continue; end if;
    v_line := '';
    foreach v_word in array regexp_split_to_array(btrim(v_para), '\s+') loop
      if v_line = '' then
        v_line := v_word;
      elsif length(v_line) + 1 + length(v_word) <= p_width then
        v_line := v_line || ' ' || v_word;
      else
        v_out := v_out || v_line; v_line := v_word;
      end if;
    end loop;
    if v_line <> '' then v_out := v_out || v_line; end if;
  end loop;
  return v_out;
end $$;

-- ── 4. the agreement, partner-facing ────────────────────────────────────────
create or replace function public.partner_agreement_card(p_partner_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(p_partner_id);
  rp public.region_partners%rowtype;
  cur public.partner_agreement_version%rowtype;
  sig public.partner_agreement_signature%rowtype;
  last_sig public.partner_agreement_signature%rowtype;
  v_can_sign boolean;
  v_status text; v_tone text; v_label text;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  select * into rp from region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;

  cur := public._c692_current_version();
  select * into last_sig from partner_agreement_signature
   where partner_id = v_pid and status = 'signed' order by version desc limit 1;
  if cur.id is not null then
    select * into sig from partner_agreement_signature
     where partner_id = v_pid and version_id = cur.id;
  end if;

  -- A partner user may sign only with write on their own documents feature; an
  -- admin may always countersign on their behalf (an office-signed paper deal).
  v_can_sign := v_admin or public.partner_can('partner.documents','write');

  if cur.id is null then
    v_status := 'none'; v_tone := 'neutral';
    v_label := public._c('partner_agree.none_published');
  elsif sig.id is not null and sig.status = 'signed' then
    v_status := 'signed'; v_tone := 'success';
    v_label := public._c('partner_agree.signed_label');
  elsif last_sig.id is not null then
    v_status := 'resign'; v_tone := 'warning';
    v_label := public._c('partner_agree.resign_label');
  else
    v_status := 'unsigned'; v_tone := 'warning';
    v_label := public._c('partner_agree.unsigned_label');
  end if;

  return jsonb_build_object('ok', true,
    'partner_id', v_pid,
    'partner_name', coalesce(rp.partner_name,''),
    'heading', public._c('partner_agree.heading'),
    'sub',     public._c('partner_agree.sub'),
    'has_version', cur.id is not null,
    'version', cur.version,
    'version_label', case when cur.id is null then ''
      else public._cf('partner_agree.version_label', jsonb_build_object(
             'v', cur.version::text, 'd', to_char(cur.effective_from,'DD/MM/YYYY'))) end,
    'title', coalesce(cur.title,''),
    'body',  coalesce(cur.body,''),
    'status', v_status, 'status_label', v_label, 'status_tone', v_tone,
    'is_signed', v_status = 'signed',
    'needs_signature', v_status in ('unsigned','resign'),
    'can_sign', v_can_sign and v_status in ('unsigned','resign'),
    'sign_label', case when v_status = 'resign' then public._c('partner_agree.resign_cta')
                       else public._c('partner_agree.sign_label') end,
    'name_hint',   public._c('partner_agree.name_hint'),
    'phone_hint',  public._c('partner_agree.phone_hint'),
    'code_hint',   public._c('partner_agree.code_hint'),
    'send_label',  public._c('partner_agree.send_label'),
    'verify_label',public._c('partner_agree.verify_label'),
    'awaiting_code', sig.id is not null and sig.status = 'pending'
                     and sig.code_hash is not null and coalesce(sig.expires_at, now()) > now(),
    'signed_line', case when sig.id is null or sig.status <> 'signed' then ''
      else public._cf('partner_agree.signed_by', jsonb_build_object(
             'name', sig.signer_name, 'd', public.ist_fmt(sig.signed_at,'dmy_hm'))) end,
    'signed_ip_line', case when sig.id is null or sig.status <> 'signed'
                                or coalesce(sig.signed_ip,'') = '' then ''
      else public._cf('partner_agree.signed_ip', jsonb_build_object('ip', sig.signed_ip)) end,
    'doc_label', public._c('partner_agree.doc_label'),
    'has_doc', sig.id is not null and coalesce(sig.doc_path,'') <> '',
    'doc_bucket', coalesce(sig.doc_bucket,''),
    'doc_path',   coalesce(sig.doc_path,''),
    'doc_id',     sig.doc_id,
    'doc_building', sig.id is not null and sig.status = 'signed'
                    and coalesce(sig.doc_path,'') = '',
    'doc_building_label', public._c('partner_agree.doc_building'),
    'prev_signed_version', last_sig.version);
end $$;

-- Step one of the e-sign: who is signing, and the WhatsApp code that proves it.
create or replace function public.partner_agreement_sign_start(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(nullif(p->>'partner_id','')::bigint);
  cur public.partner_agreement_version%rowtype;
  sig public.partner_agreement_signature%rowtype;
  v_name text := nullif(btrim(coalesce(p->>'signer_name','')),'');
  v_phone text; v_code text;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  if not (v_admin or public.partner_can('partner.documents','write')) then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  cur := public._c692_current_version();
  if cur.id is null then
    return jsonb_build_object('ok', false, 'error','no_version', 'tone','danger',
      'message', public._c('partner_agree.none_published'));
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false, 'error','no_name', 'tone','danger',
      'message', public._c('partner_agree.err_no_name'));
  end if;
  v_phone := public.identity_norm(coalesce(p->>'phone',''));
  if v_phone is null then
    return jsonb_build_object('ok', false, 'error','bad_phone', 'tone','danger',
      'message', public._c('partner_agree.err_bad_phone'));
  end if;

  select * into sig from partner_agreement_signature
   where partner_id = v_pid and version_id = cur.id;
  if sig.id is not null and sig.status = 'signed' then
    return jsonb_build_object('ok', false, 'error','already_signed', 'tone','info',
      'message', public._c('partner_agree.already_signed'),
      'card', public.partner_agreement_card(v_pid));
  end if;
  if sig.locked_until is not null and sig.locked_until > now() then
    return jsonb_build_object('ok', false, 'error','locked', 'tone','danger',
      'message', public._c('partner_agree.err_locked'));
  end if;
  if sig.sent_at is not null and sig.sent_at > now() - interval '30 seconds' then
    return jsonb_build_object('ok', false, 'error','too_soon', 'tone','warning',
      'message', public._c('partner_agree.err_too_soon'));
  end if;

  v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');

  insert into partner_agreement_signature as t
    (partner_id, version_id, version, status, signer_name, signer_phone,
     body_snapshot, code_hash, sent_at, expires_at, attempts, locked_until, updated_at)
  values (v_pid, cur.id, cur.version, 'pending', v_name, v_phone,
          cur.body, md5(v_phone || ':' || v_code), now(), now() + interval '10 minutes',
          0, null, now())
  on conflict (partner_id, version_id) do update
    set signer_name = excluded.signer_name, signer_phone = excluded.signer_phone,
        body_snapshot = excluded.body_snapshot, code_hash = excluded.code_hash,
        sent_at = excluded.sent_at, expires_at = excluded.expires_at,
        attempts = 0, locked_until = null, updated_at = now();

  -- The transport every other OTP on this platform already uses.
  perform net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/login-otp',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-login-secret','medibo_login_otp_2027'),
    body := jsonb_build_object('mode','send','phone', v_phone, 'code', v_code));

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (v_pid, auth.uid(), 'partner.documents', 'agreement_otp_sent',
          jsonb_build_object('version', cur.version, 'signer', v_name,
            'summary', 'Agreement e-sign code sent to ' || v_name));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_agree.otp_sent'),
    'card', public.partner_agreement_card(v_pid));
end $$;

-- Step two: the code, and with it the signature — name, IP, timestamp and an
-- immutable snapshot of the text as it stood.
create or replace function public.partner_agreement_sign_verify(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(nullif(p->>'partner_id','')::bigint);
  cur public.partner_agreement_version%rowtype;
  sig public.partner_agreement_signature%rowtype;
  v_code text := btrim(coalesce(p->>'code',''));
  v_ip text := left(btrim(coalesce(p->>'ip','')), 64);
  v_agent text := left(btrim(coalesce(p->>'user_agent','')), 240);
  v_doc jsonb;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  if not (v_admin or public.partner_can('partner.documents','write')) then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  cur := public._c692_current_version();
  if cur.id is null then
    return jsonb_build_object('ok', false, 'error','no_version', 'tone','danger',
      'message', public._c('partner_agree.none_published'));
  end if;
  select * into sig from partner_agreement_signature
   where partner_id = v_pid and version_id = cur.id;

  if sig.id is null or sig.code_hash is null then
    return jsonb_build_object('ok', false, 'error','no_pending', 'tone','warning',
      'message', public._c('partner_agree.err_no_pending'));
  end if;
  if sig.status = 'signed' then
    return jsonb_build_object('ok', false, 'error','already_signed', 'tone','info',
      'message', public._c('partner_agree.already_signed'),
      'card', public.partner_agreement_card(v_pid));
  end if;
  if sig.locked_until is not null and sig.locked_until > now() then
    return jsonb_build_object('ok', false, 'error','locked', 'tone','danger',
      'message', public._c('partner_agree.err_locked'));
  end if;
  if coalesce(sig.expires_at, now()) <= now() then
    return jsonb_build_object('ok', false, 'error','expired', 'tone','danger',
      'message', public._c('partner_agree.err_expired'));
  end if;

  if sig.code_hash <> md5(coalesce(sig.signer_phone,'') || ':' || v_code) then
    update partner_agreement_signature
       set attempts = attempts + 1,
           locked_until = case when attempts + 1 >= 5
                               then now() + interval '15 minutes' else locked_until end,
           updated_at = now()
     where id = sig.id;
    return jsonb_build_object('ok', false, 'error','bad_code', 'tone','danger',
      'message', public._c('partner_agree.err_bad_code'),
      'card', public.partner_agreement_card(v_pid));
  end if;

  update partner_agreement_signature
     set status = 'signed', signed_at = now(), signed_by = auth.uid(),
         signed_ip = v_ip, signed_agent = v_agent,
         code_hash = null, attempts = 0, locked_until = null, updated_at = now()
   where id = sig.id;

  -- The onboarding checklist and the licence card both read the partner row, so
  -- the signature lands there too rather than becoming a second truth.
  update region_partners
     set agreement_doc_path = coalesce(nullif(agreement_doc_path,''),
                                       'signature:' || sig.id::text),
         updated_at = now()
   where id = v_pid;
  insert into partner_onboarding_state(partner_id, step_key, done, value, updated_by)
  values (v_pid, 'agreement', true, 'v' || cur.version::text,
          coalesce(public.my_login_email(),'partner'))
  on conflict (partner_id, step_key) do update
    set done = true, value = excluded.value, updated_at = now(),
        updated_by = excluded.updated_by;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (v_pid, auth.uid(), 'partner.documents', 'agreement_signed',
          jsonb_build_object('version', cur.version, 'signer', sig.signer_name,
            'ip', v_ip,
            'summary', 'Agreement v' || cur.version::text || ' signed by ' || sig.signer_name));

  -- The signed copy, drawn by the SAME renderer every other partner document
  -- uses. A failure here must never unsign an agreement that is signed.
  begin
    v_doc := public.partner_doc_request('agreement', sig.id::text);
  exception when others then v_doc := null;
  end;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_agree.signed_toast'),
    'doc', v_doc,
    'card', public.partner_agreement_card(v_pid),
    'golive', public.partner_golive_state(v_pid));
end $$;

-- ── 5. the agreement, super-admin side ──────────────────────────────────────
create or replace function public.partner_agreement_versions()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb; v_total int;
begin
  if public.role_for_medibo_only() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  select count(*) into v_total from region_partners where coalesce(is_active,false);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'version', v.version, 'title', v.title, 'body', v.body,
           'effective_from', v.effective_from,
           'is_published', v.is_published,
           'status_label', case when v.is_published then public._c('partner_agree.published_label')
                                else public._c('partner_agree.draft_label') end,
           'status_tone', case when v.is_published then 'success' else 'neutral' end,
           'version_label', public._cf('partner_agree.version_label', jsonb_build_object(
              'v', v.version::text, 'd', to_char(v.effective_from,'DD/MM/YYYY'))),
           'signed_count', (select count(*) from partner_agreement_signature s
                             where s.version_id = v.id and s.status = 'signed'),
           'signed_label', public._cf('partner_agree.signed_count', jsonb_build_object(
              'n', (select count(*) from partner_agreement_signature s
                     where s.version_id = v.id and s.status='signed')::text,
              't', v_total::text))
         ) order by v.version desc), '[]'::jsonb)
    into v_rows from partner_agreement_version v;

  return jsonb_build_object('ok', true,
    'heading', public._c('partner_agree.admin_heading'),
    'new_label', public._c('partner_agree.admin_new'),
    'publish_label', public._c('partner_agree.admin_publish'),
    'rows', v_rows,
    'partner_total', v_total,
    'current_version', (public._c692_current_version()).version);
end $$;

-- A version is never edited once it is published — publishing it is what makes
-- every partner unsigned again, so mutating the text under a signature would
-- make the snapshot a lie. A published version can only be superseded.
create or replace function public.partner_agreement_version_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p->>'id','')::bigint;
  v_body text := btrim(coalesce(p->>'body',''));
  v_title text := btrim(coalesce(p->>'title',''));
  v_eff date := coalesce(nullif(p->>'effective_from','')::date, current_date);
  v_publish boolean := coalesce((p->>'publish')::boolean, false);
  v_ver int; row public.partner_agreement_version%rowtype;
begin
  if public.role_for_medibo_only() <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_agree.err_not_authorized'));
  end if;
  if v_body = '' then
    return jsonb_build_object('ok', false, 'error','no_body', 'tone','danger',
      'message', public._c('partner_agree.err_body'));
  end if;

  if v_id is not null then
    select * into row from partner_agreement_version where id = v_id;
    if not found or row.is_published then
      v_id := null;                       -- published text is frozen; make a new one
    end if;
  end if;

  if v_id is null then
    select coalesce(max(version),0) + 1 into v_ver from partner_agreement_version;
    insert into partner_agreement_version(version, title, body, effective_from,
             is_published, published_at, created_by)
    values (v_ver, v_title, v_body, v_eff, v_publish,
            case when v_publish then now() end, coalesce(public.my_login_email(),'admin'))
    returning * into row;
  else
    update partner_agreement_version
       set title = v_title, body = v_body, effective_from = v_eff,
           is_published = v_publish,
           published_at = case when v_publish then coalesce(published_at, now()) end
     where id = v_id returning * into row;
  end if;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', case when row.is_published
      then public._cf('partner_agree.admin_published',
             jsonb_build_object('v', row.version::text))
      else public._c('partner_agree.admin_saved') end,
    'state', public.partner_agreement_versions());
end $$;

-- The signed copy, in the generic document shape bill-render already draws.
create or replace function public._c692_agreement_doc_payload(p_sig_id bigint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  s public.partner_agreement_signature%rowtype;
  rp public.region_partners%rowtype;
  v_lines text[]; v_rows jsonb;
begin
  select * into s from partner_agreement_signature where id = p_sig_id;
  if not found or s.status <> 'signed' then
    return jsonb_build_object('ok', false, 'error','not_signed');
  end if;
  select * into rp from region_partners where id = s.partner_id;

  v_lines := public._c692_wrap(s.body_snapshot, 108);
  select coalesce(jsonb_agg(jsonb_build_object('t', l) order by i), '[]'::jsonb)
    into v_rows from unnest(v_lines) with ordinality as u(l, i);

  return jsonb_build_object('ok', true, 'doc', jsonb_build_object(
    'title', coalesce(nullif((select title from partner_agreement_version
                              where id = s.version_id), ''),
                      public._c('partner_agree.heading')),
    'brand', 'mediBO',
    'subtitle', public._cf('partner_agree.version_label', jsonb_build_object(
        'v', s.version::text,
        'd', to_char((select effective_from from partner_agreement_version
                       where id = s.version_id),'DD/MM/YYYY'))),
    'header', jsonb_build_array(
      jsonb_build_object('label','Partner', 'value', coalesce(rp.partner_name,'')),
      jsonb_build_object('label','District','value', coalesce(rp.district,'')),
      jsonb_build_object('label','GSTIN',   'value', coalesce(rp.gstin,'')),
      jsonb_build_object('label','Signed by','value', s.signer_name),
      jsonb_build_object('label','Signed on','value', public.ist_fmt(s.signed_at,'dmy_hm')),
      jsonb_build_object('label','Mobile',  'value', coalesce(s.signer_phone,''))),
    'sections', jsonb_build_array(jsonb_build_object(
      'heading', '',
      'columns', jsonb_build_array(
        jsonb_build_object('key','t','label','','width', 523)),
      'rows', v_rows,
      'empty_label', '')),
    'totals', '[]'::jsonb,
    'notes', jsonb_build_array(
      public._cf('partner_agree.signed_by', jsonb_build_object(
        'name', s.signer_name, 'd', public.ist_fmt(s.signed_at,'dmy_hm'))),
      case when coalesce(s.signed_ip,'') = '' then null
           else public._cf('partner_agree.signed_ip',
                  jsonb_build_object('ip', s.signed_ip)) end,
      'Accepted electronically with a one-time code sent to '
        || coalesce(s.signer_phone,'') || ' on WhatsApp.'),
    'footer', 'mediBO · Jai Mahakal Medical And Surgical'));
end $$;

-- ── 6. KYC documents ────────────────────────────────────────────────────────
create or replace function public.partner_kyc_card(p_partner_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(p_partner_id);
  rp public.region_partners%rowtype;
  v_can_write boolean; v_rows jsonb;
  v_done int; v_req int; v_out int;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  select * into rp from region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  v_can_write := v_admin or public.partner_can('partner.documents','write');

  select coalesce(jsonb_agg(jsonb_build_object(
      'doc_key', t.doc_key,
      'label',   t.label,
      'hint',    t.hint,
      'required', t.is_required,
      'required_label', case when t.is_required then public._c('partner_kyc.required_label')
                             else public._c('partner_kyc.optional_label') end,
      'wants_number', t.wants_number,
      'wants_expiry', t.wants_expiry,
      'number_hint', public._c('partner_kyc.number_hint'),
      'expiry_hint', public._c('partner_kyc.expiry_hint'),
      'status', coalesce(d.status, 'missing'),
      'status_label', case coalesce(d.status,'missing')
          when 'verified' then public._c('partner_kyc.verified_label')
          when 'rejected' then public._c('partner_kyc.rejected_label')
          when 'pending'  then public._c('partner_kyc.pending_label')
          else public._c('partner_kyc.missing_label') end,
      'status_tone', case coalesce(d.status,'missing')
          when 'verified' then 'success'
          when 'rejected' then 'danger'
          when 'pending'  then 'warning'
          else 'neutral' end,
      'has_file', coalesce(d.path,'') <> '',
      'bucket', coalesce(d.bucket,''),
      'path',   coalesce(d.path,''),
      'file_name', coalesce(d.file_name,''),
      'number', coalesce(d.number,''),
      'expiry_iso', d.expiry,
      'expiry_label', case when d.expiry is null then ''
        else public._cf('partner_kyc.expiry_label',
               jsonb_build_object('d', to_char(d.expiry,'DD/MM/YYYY'))) end,
      'uploaded_label', case when d.uploaded_at is null then ''
        else public._cf('partner_kyc.uploaded_on',
               jsonb_build_object('d', public.ist_fmt(d.uploaded_at,'dmy'))) end,
      'reject_reason', coalesce(d.reject_reason,''),
      'reject_line', case when coalesce(d.status,'') <> 'rejected' then ''
        else public._cf('partner_kyc.rejected_because',
               jsonb_build_object('why', coalesce(nullif(d.reject_reason,''),'—'))) end,
      'can_upload', v_can_write and coalesce(d.status,'missing') <> 'verified',
      'upload_label', case when coalesce(d.path,'') = ''
                           then public._c('partner_kyc.upload_label')
                           else public._c('partner_kyc.replace_label') end,
      'view_label', public._c('partner_kyc.view_label'),
      'can_review', v_admin and coalesce(d.path,'') <> '',
      'verify_label', public._c('partner_kyc.verify_label'),
      'reject_label', public._c('partner_kyc.reject_label'),
      'reject_hint',  public._c('partner_kyc.reject_hint')
    ) order by t.sort_order), '[]'::jsonb)
    into v_rows
    from partner_kyc_doc_type t
    left join partner_kyc_doc d on d.partner_id = v_pid and d.doc_key = t.doc_key
   where t.is_active;

  select count(*) filter (where (e->>'required')::boolean and e->>'status' = 'verified'),
         count(*) filter (where (e->>'required')::boolean),
         count(*) filter (where (e->>'required')::boolean and e->>'status' <> 'verified')
    into v_done, v_req, v_out
    from jsonb_array_elements(v_rows) e;

  return jsonb_build_object('ok', true,
    'partner_id', v_pid,
    'partner_name', coalesce(rp.partner_name,''),
    'heading', public._c('partner_kyc.heading'),
    'sub',     public._c('partner_kyc.sub'),
    'review_heading', public._c('partner_kyc.review_heading'),
    'can_write', v_can_write,
    'is_admin', v_admin,
    'rows', v_rows,
    'verified_count', v_done, 'required_count', v_req, 'outstanding_count', v_out,
    'progress_label', public._cf('partner_kyc.progress',
        jsonb_build_object('done', v_done::text, 'total', v_req::text)),
    'summary_label', case when v_out = 0 then public._c('partner_kyc.all_done')
        else public._cf('partner_kyc.outstanding', jsonb_build_object('n', v_out::text)) end,
    'summary_tone', case when v_out = 0 then 'success' else 'warning' end,
    'all_verified', v_out = 0);
end $$;

-- Where a partner's document file goes. Same bucket and same `p<id>/` prefix
-- the partner storage policy already grants, so nothing new is opened up.
create or replace function public.partner_kyc_upload_path(p_doc_key text, p_ext text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_pid bigint := public._c692_pid(null); v_ext text;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','not_partner',
      'message', public._c('partner_kyc.err_not_authorized'));
  end if;
  if not exists (select 1 from partner_kyc_doc_type where doc_key = p_doc_key and is_active) then
    return jsonb_build_object('ok', false, 'error','bad_doc',
      'message', public._c('partner_kyc.err_bad_doc'));
  end if;
  v_ext := lower(regexp_replace(coalesce(nullif(p_ext,''),'jpg'), '[^a-z0-9]', '', 'g'));
  if v_ext not in ('jpg','jpeg','png','webp','pdf') then v_ext := 'jpg'; end if;
  return jsonb_build_object('ok', true,
    'bucket', 'partner-receipts',
    'path', 'p' || v_pid::text || '/kyc/' ||
            regexp_replace(p_doc_key, '[^a-zA-Z0-9_-]', '', 'g') || '-' ||
            to_char(now() at time zone 'Asia/Kolkata','YYYYMMDDHH24MISS') || '-' ||
            substr(md5(random()::text), 1, 8) || '.' || v_ext);
end $$;

-- The partner records what they uploaded. Every upload lands as PENDING, even a
-- replacement of a verified document — a re-uploaded licence is a new claim.
create or replace function public.partner_kyc_submit(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_admin boolean := public._c692_admin();
  v_pid bigint := public._c692_pid(nullif(p->>'partner_id','')::bigint);
  t public.partner_kyc_doc_type%rowtype;
  v_path text := btrim(coalesce(p->>'path',''));
  v_bucket text := coalesce(nullif(btrim(coalesce(p->>'bucket','')),''),'partner-receipts');
  v_name text := left(btrim(coalesce(p->>'file_name','')), 160);
  v_num text := btrim(coalesce(p->>'number',''));
  v_exp date := nullif(p->>'expiry','')::date;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner', 'tone','danger',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  if not (v_admin or public.partner_can('partner.documents','write')) then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_kyc.err_not_authorized'));
  end if;
  select * into t from partner_kyc_doc_type where doc_key = p->>'doc_key' and is_active;
  if not found then
    return jsonb_build_object('ok', false, 'error','bad_doc', 'tone','danger',
      'message', public._c('partner_kyc.err_bad_doc'));
  end if;
  if v_path = '' then
    return jsonb_build_object('ok', false, 'error','no_file', 'tone','danger',
      'message', public._c('partner_kyc.err_no_file'));
  end if;
  if t.wants_number and v_num = '' then
    return jsonb_build_object('ok', false, 'error','no_number', 'tone','danger',
      'message', public._c('partner_kyc.err_number'));
  end if;
  if t.wants_expiry and v_exp is null then
    return jsonb_build_object('ok', false, 'error','no_expiry', 'tone','danger',
      'message', public._c('partner_kyc.err_expiry'));
  end if;

  insert into partner_kyc_doc(partner_id, doc_key, bucket, path, file_name, number,
             expiry, status, reject_reason, uploaded_at, uploaded_by, updated_at)
  values (v_pid, t.doc_key, v_bucket, v_path, v_name, v_num, v_exp, 'pending', '',
          now(), coalesce(public.my_login_email(),'partner'), now())
  on conflict (partner_id, doc_key) do update
    set bucket = excluded.bucket, path = excluded.path, file_name = excluded.file_name,
        number = excluded.number, expiry = excluded.expiry,
        status = 'pending', reject_reason = '',
        uploaded_at = now(), uploaded_by = excluded.uploaded_by,
        reviewed_at = null, reviewed_by = '', updated_at = now();

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (v_pid, auth.uid(), 'partner.documents', 'kyc_uploaded',
          jsonb_build_object('doc_key', t.doc_key,
            'summary', t.label || ' uploaded'));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_kyc.saved_toast'),
    'card', public.partner_kyc_card(v_pid),
    'golive', public.partner_golive_state(v_pid));
end $$;

-- The office's verdict. A verified document with an expiry writes that date onto
-- region_partners, which is where partner_licence_card and
-- partner_licence_expiry_sweep already look — so expiry tracking joins the sweep
-- that exists instead of growing a second one.
create or replace function public.partner_kyc_review_set(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_pid bigint := nullif(p->>'partner_id','')::bigint;
  t public.partner_kyc_doc_type%rowtype;
  d public.partner_kyc_doc%rowtype;
  v_status text := lower(btrim(coalesce(p->>'status','')));
  v_why text := btrim(coalesce(p->>'reason',''));
begin
  if not public._c692_admin() then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('partner_kyc.err_not_authorized'));
  end if;
  if v_status not in ('verified','rejected','pending') then
    return jsonb_build_object('ok', false, 'error','bad_status', 'tone','danger',
      'message', public._c('partner_kyc.err_bad_doc'));
  end if;
  select * into t from partner_kyc_doc_type where doc_key = p->>'doc_key';
  if not found then
    return jsonb_build_object('ok', false, 'error','bad_doc', 'tone','danger',
      'message', public._c('partner_kyc.err_bad_doc'));
  end if;
  if v_status = 'rejected' and v_why = '' then
    return jsonb_build_object('ok', false, 'error','no_reason', 'tone','danger',
      'message', public._c('partner_kyc.err_reason'));
  end if;
  select * into d from partner_kyc_doc where partner_id = v_pid and doc_key = t.doc_key;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found', 'tone','danger',
      'message', public._c('partner_kyc.err_no_file'));
  end if;

  update partner_kyc_doc
     set status = v_status,
         reject_reason = case when v_status = 'rejected' then v_why else '' end,
         reviewed_at = now(), reviewed_by = coalesce(public.my_login_email(),'admin'),
         updated_at = now()
   where id = d.id;

  if v_status = 'verified' then
    -- the number and doc path onto the partner row the rest of the platform reads
    if t.path_field is not null then
      execute format('update region_partners set %I = $1, updated_at = now() where id = $2',
                     t.path_field) using d.path, v_pid;
    end if;
    if t.num_field is not null and coalesce(d.number,'') <> '' then
      execute format('update region_partners set %I = $1, updated_at = now() where id = $2',
                     t.num_field) using d.number, v_pid;
    end if;
    -- the expiry onto the column partner_licence_card / the sweep already read
    if t.licence_kind is not null and d.expiry is not null then
      perform public.partner_licence_set(v_pid, t.licence_kind, d.expiry);
    end if;
    if t.onboard_step is not null then
      insert into partner_onboarding_state(partner_id, step_key, done, value, doc_path, updated_by)
      values (v_pid, t.onboard_step, true, d.number, d.path,
              coalesce(public.my_login_email(),'admin'))
      on conflict (partner_id, step_key) do update
        set done = true, value = coalesce(nullif(excluded.value,''), partner_onboarding_state.value),
            doc_path = coalesce(nullif(excluded.doc_path,''), partner_onboarding_state.doc_path),
            updated_at = now(), updated_by = excluded.updated_by;
    end if;
  end if;

  begin
    perform public.notify_partner(
      case when v_status = 'rejected' then 'partner_kyc_rejected'
           else 'partner_kyc_verified' end,
      jsonb_build_object('partner_id', v_pid::text, 'label', t.label, 'why', v_why));
  exception when others then null;
  end;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (v_pid, auth.uid(), 'partner.documents', 'kyc_' || v_status,
          jsonb_build_object('doc_key', t.doc_key, 'reason', v_why,
            'summary', t.label || ' ' || v_status));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', case when v_status = 'rejected' then public._c('partner_kyc.rejected_toast')
                    else public._c('partner_kyc.verified_toast') end,
    'card', public.partner_kyc_card(v_pid),
    'golive', public.partner_golive_state(v_pid));
end $$;

-- ── 7. the go-live gate ─────────────────────────────────────────────────────
-- ONE answer to "may this partner be given orders?", and one sentence saying
-- why not. Every caller below reads it; none of them re-derives it.
create or replace function public.partner_golive_state(p_partner_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_pid bigint := coalesce(p_partner_id, public.my_partner_id());
  rp public.region_partners%rowtype;
  cur public.partner_agreement_version%rowtype;
  v_signed boolean := false; v_ever boolean := false;
  v_kyc_out int := 0; v_ob_missing int := 0;
  v_blocks jsonb := '[]'::jsonb; v_texts text[] := '{}';
  v_ready boolean; v_why text := '';
begin
  if v_pid is null or not exists (select 1 from region_partners where id = v_pid) then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_golive.err_no_partner'));
  end if;
  select * into rp from region_partners where id = v_pid;
  cur := public._c692_current_version();

  if cur.id is not null then
    select exists (select 1 from partner_agreement_signature s
                    where s.partner_id = v_pid and s.version_id = cur.id
                      and s.status = 'signed') into v_signed;
    select exists (select 1 from partner_agreement_signature s
                    where s.partner_id = v_pid and s.status = 'signed') into v_ever;
  else
    v_signed := true;   -- nothing published to sign; the gate does not invent one
  end if;

  select count(*) into v_kyc_out
    from partner_kyc_doc_type t
    left join partner_kyc_doc d on d.partner_id = v_pid and d.doc_key = t.doc_key
   where t.is_active and t.is_required and coalesce(d.status,'missing') <> 'verified';

  v_ob_missing := coalesce((public.partner_onboarding_get(v_pid)->>'missing_count')::int, 0);

  if not v_signed then
    v_texts := v_texts || (case when v_ever then public._c('partner_golive.b_agreement_old')
                                else public._c('partner_golive.b_agreement') end);
    v_blocks := v_blocks || jsonb_build_object('key','agreement',
      'text', case when v_ever then public._c('partner_golive.b_agreement_old')
                   else public._c('partner_golive.b_agreement') end,
      'tone','danger');
  end if;
  if v_kyc_out > 0 then
    v_texts := v_texts || public._cf('partner_golive.b_kyc',
                            jsonb_build_object('n', v_kyc_out::text));
    v_blocks := v_blocks || jsonb_build_object('key','kyc',
      'text', public._cf('partner_golive.b_kyc', jsonb_build_object('n', v_kyc_out::text)),
      'count', v_kyc_out, 'tone','warning');
  end if;
  if v_ob_missing > 0 then
    v_texts := v_texts || public._cf('partner_golive.b_onboarding',
                            jsonb_build_object('n', v_ob_missing::text));
    v_blocks := v_blocks || jsonb_build_object('key','onboarding',
      'text', public._cf('partner_golive.b_onboarding',
                jsonb_build_object('n', v_ob_missing::text)),
      'count', v_ob_missing, 'tone','warning');
  end if;

  v_ready := array_length(v_texts, 1) is null;
  if not v_ready then
    v_why := public._cf('partner_golive.blocked_reason', jsonb_build_object(
               'why', array_to_string(v_texts, public._c('partner_golive.and'))));
  end if;

  return jsonb_build_object('ok', true,
    'partner_id', v_pid,
    'partner_name', coalesce(rp.partner_name,''),
    'heading', public._c('partner_golive.heading'),
    'ready', v_ready,
    'status_label', case when v_ready then public._c('partner_golive.ready_label')
                         else public._c('partner_golive.blocked_label') end,
    'status_tone', case when v_ready then 'success' else 'warning' end,
    'blocking_reason', v_why,
    'blockers', v_blocks,
    'agreement_signed', v_signed,
    'agreement_version', cur.version,
    'kyc_outstanding', v_kyc_out,
    'onboarding_missing', v_ob_missing);
end $$;

-- The activation gate grows the two new conditions. The override door stays
-- exactly where #657 put it: an admin with a REASON may still switch a partner
-- on, and the reason is stored and audited.
create or replace function public.partner_set_active(p_partner_id bigint, p_active boolean,
                                                     p_override_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_state jsonb; v_gl jsonb; v_missing int;
        v_reason text := nullif(btrim(coalesce(p_override_reason,'')),'');
begin
  if not public.is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pop_c('ob.err_not_authorized'));
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok',false,'error','no_partner','tone','danger',
      'message', public._pop_c('ob.err_no_partner'));
  end if;

  if p_active then
    v_state := public.partner_onboarding_get(p_partner_id);
    v_gl    := public.partner_golive_state(p_partner_id);
    v_missing := coalesce((v_state->>'missing_count')::int, 0);
    if coalesce((v_gl->>'ready')::boolean, false) = false and v_reason is null then
      return jsonb_build_object('ok',false,'error','golive_blocked','tone','danger',
        'message', coalesce(nullif(v_gl->>'blocking_reason',''),
                            public._pop_c('ob.err_incomplete')),
        'missing_count', v_missing, 'state', v_state, 'golive', v_gl);
    end if;
  end if;

  update region_partners
     set is_active = p_active,
         activated_at = case when p_active then now() else null end,
         activated_by = case when p_active then coalesce(public.my_login_email(),'admin') else null end,
         activation_override_reason = case when p_active then v_reason else null end,
         updated_at = now()
   where id = p_partner_id;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), 'partner.onboarding',
          case when p_active then 'partner_activated' else 'partner_deactivated' end,
          jsonb_build_object('override_reason', v_reason,
            'missing_count', coalesce(v_missing,0),
            'golive_ready', coalesce((v_gl->>'ready')::boolean, null),
            'summary', case when p_active then
                 case when v_reason is null then 'Activated partner ' || p_partner_id
                      else replace(public._pop_c('ob.override_note'),'{reason}', v_reason) end
                 else 'Deactivated partner ' || p_partner_id end));

  return jsonb_build_object('ok',true,'tone','success',
    'message', case when p_active then public._pop_c('ob.activated')
                    else public._pop_c('ob.deactivated') end,
    'state', public.partner_onboarding_get(p_partner_id),
    'golive', public.partner_golive_state(p_partner_id));
end $$;

-- Handing a ZONE to a partner is the other door onto the same fact: from that
-- moment the partner is the one fulfilling every order in it.
create or replace function public.settlement_zone_set(p_zone_id smallint, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_mode    text;
  v_partner bigint;
  v_split   numeric;
  v_cadence text;
  v_gl      jsonb;
  cur public.zone_fulfilment_mode%rowtype;
begin
  if not public.is_admin() then return public._stl_denied(); end if;
  select * into cur from public.zone_fulfilment_mode where zone_id = p_zone_id;
  if not found and not exists (select 1 from public.zones where id = p_zone_id) then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_zone'));
  end if;

  v_mode    := coalesce(p_patch->>'mode', cur.mode, 'self');
  v_partner := coalesce(nullif(p_patch->>'partner_id','')::bigint, cur.partner_id);
  v_split   := coalesce(nullif(p_patch->>'split_pct','')::numeric, cur.split_pct, 0);
  v_cadence := coalesce(p_patch->>'cadence', cur.cadence, 'same_day');

  if v_mode = 'partner' and v_partner is null then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.no_partner'));
  end if;
  if v_split < 0 or v_split > 100 then
    return jsonb_build_object('ok', false, 'message', public._stl_c('err.bad_split'));
  end if;
  if v_cadence not in ('same_day','t_plus_2','weekly','monthly') then
    v_cadence := 'same_day';
  end if;
  if v_mode = 'self' then v_split := 0; v_partner := null; end if;

  -- CHANGE #692 — the go-live gate. A partner who has not signed the current
  -- agreement, or whose required documents are not verified, cannot be given a
  -- zone's orders. The refusal is the gate's own sentence, not one written here.
  if v_mode = 'partner' and v_partner is distinct from cur.partner_id then
    v_gl := public.partner_golive_state(v_partner);
    if coalesce((v_gl->>'ready')::boolean, false) = false then
      return jsonb_build_object('ok', false, 'error','golive_blocked',
        'message', coalesce(nullif(v_gl->>'blocking_reason',''),
                            public._c('partner_golive.blocked_label')),
        'golive', v_gl, 'zones', public.settlement_zones());
    end if;
  end if;

  insert into public.zone_fulfilment_mode (zone_id, mode, partner_id, split_pct, cadence, updated_at, updated_by)
  values (p_zone_id, v_mode, v_partner, v_split, v_cadence, now(),
          coalesce(auth.jwt() ->> 'email', 'admin'))
  on conflict (zone_id) do update set
    mode = excluded.mode, partner_id = excluded.partner_id,
    split_pct = excluded.split_pct, cadence = excluded.cadence,
    updated_at = now(), updated_by = excluded.updated_by;

  return jsonb_build_object('ok', true, 'message', public._stl_c('ui.saved'),
                            'zones', public.settlement_zones());
end $$;

-- ── 8. reminders ────────────────────────────────────────────────────────────
-- One WhatsApp/push nudge a day per partner while anything is outstanding, on
-- the same notify_partner route every other partner message rides.
create or replace function public.partner_kyc_reminder_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_gl jsonb; v_sent int := 0; v_seen int := 0;
begin
  for r in select rp.id, rp.partner_name from region_partners rp
            where coalesce(rp.suspended_at, null) is null
  loop
    v_gl := public.partner_golive_state(r.id);
    if coalesce((v_gl->>'ready')::boolean, true) then continue; end if;
    v_seen := v_seen + 1;

    if coalesce((v_gl->>'kyc_outstanding')::int,0) > 0
       and not exists (select 1 from partner_kyc_reminder m
                        where m.partner_id = r.id and m.kind = 'kyc'
                          and m.sent_on = (now() at time zone 'Asia/Kolkata')::date) then
      begin
        perform public.notify_partner('partner_kyc_pending', jsonb_build_object(
          'partner_id', r.id::text, 'partner', r.partner_name,
          'n', (v_gl->>'kyc_outstanding'),
          'title', public._c('partner_kyc.reminder_title'),
          'body', public._cf('partner_kyc.reminder_body', jsonb_build_object(
                    'partner', r.partner_name, 'n', (v_gl->>'kyc_outstanding')))));
      exception when others then null;
      end;
      insert into partner_kyc_reminder(partner_id, kind, sent_on)
      values (r.id, 'kyc', (now() at time zone 'Asia/Kolkata')::date)
      on conflict do nothing;
      v_sent := v_sent + 1;
    end if;

    if coalesce((v_gl->>'agreement_signed')::boolean, true) = false
       and not exists (select 1 from partner_kyc_reminder m
                        where m.partner_id = r.id and m.kind = 'agreement'
                          and m.sent_on = (now() at time zone 'Asia/Kolkata')::date) then
      begin
        perform public.notify_partner('partner_agreement_pending', jsonb_build_object(
          'partner_id', r.id::text, 'partner', r.partner_name,
          'v', coalesce(v_gl->>'agreement_version','')));
      exception when others then null;
      end;
      insert into partner_kyc_reminder(partner_id, kind, sent_on)
      values (r.id, 'agreement', (now() at time zone 'Asia/Kolkata')::date)
      on conflict do nothing;
      v_sent := v_sent + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'blocked_partners', v_seen, 'reminded', v_sent);
end $$;

-- ── 9. the one screen payload ───────────────────────────────────────────────
-- The partner console's "My documents" and the admin's "Partner details" both
-- draw this. One call, three blocks, every word already decided.
create or replace function public.partner_documents_screen(p_partner_id bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_pid bigint := public._c692_pid(p_partner_id); v_kyc jsonb;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_agree.err_no_partner'));
  end if;
  v_kyc := public.partner_kyc_card(v_pid);
  if coalesce((v_kyc->>'ok')::boolean,false) = false then return v_kyc; end if;
  return jsonb_build_object('ok', true,
    'partner_id', v_pid,
    'partner_name', v_kyc->>'partner_name',
    'title', public._c('partner_kyc.heading'),
    'golive',    public.partner_golive_state(v_pid),
    'agreement', public.partner_agreement_card(v_pid),
    'kyc',       v_kyc,
    'licence',   public.partner_licence_card(v_pid));
end $$;

-- ── 10. the signed copy joins the existing document pipeline ────────────────
-- partner_doc_request only knew 'statement'. The agreement snapshot is drawn by
-- the SAME bill-render renderDoc() the statement uses, so this is a second kind
-- and not a second renderer.
create or replace function public.partner_doc_request(p_kind text, p_ref text)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare
  v_pid bigint := public.my_partner_id();
  v_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_period bigint; v_sig bigint; pay jsonb; d public.partner_document%rowtype; v_id uuid;
  s public.partner_agreement_signature%rowtype;
begin
  if coalesce(p_kind,'') = 'agreement' then
    v_sig := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
    select * into s from public.partner_agreement_signature where id = v_sig;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', public._c('partner_doc.err_not_found'));
    end if;
    if v_pid is null and v_admin then v_pid := s.partner_id; end if;
    if v_pid is distinct from s.partner_id and not v_admin then
      return jsonb_build_object('ok', false, 'error','not_partner',
        'message', public._c('partner_doc.err_not_partner'));
    end if;
    v_pid := s.partner_id;

    pay := public._c692_agreement_doc_payload(v_sig);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
        'message', public._c('partner_doc.err_not_found'));
    end if;

    select * into d from public.partner_document
     where partner_id = v_pid and kind = 'agreement' and ref_key = v_sig::text;
    if found and d.status = 'ready' and coalesce(d.path,'') <> '' then
      return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
        'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
        'expires_s', 300, 'message', public._c('partner_doc.ready_message'));
    end if;

    insert into public.partner_document(
        partner_id, kind, ref_key, title, file_name, status, attempts,
        source_stamp, requested_by, requested_at, started_at, last_error)
    values (v_pid, 'agreement', v_sig::text,
            coalesce(pay#>>'{doc,title}',''),
            'agreement-v' || s.version::text || '.pdf',
            'queued', 0, 'sig' || v_sig::text, auth.uid(), now(), null, null)
    on conflict (partner_id, kind, ref_key) do update
      set status = 'queued', attempts = 0, requested_at = now(),
          started_at = null, last_error = null
    returning id into v_id;

    update public.partner_agreement_signature set doc_id = v_id, updated_at = now()
     where id = v_sig;

    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('supplier_doc_id', v_id),
      timeout_milliseconds := 20000);

    return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
      'poll_ms', 1500, 'message', public._c('partner_doc.building_message'));
  end if;

  if v_pid is null and v_admin then
    select p.partner_id into v_pid from partner_settlement_periods p
     where p.id = nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  end if;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','not_partner',
      'message', public._c('partner_doc.err_not_partner'));
  end if;
  if coalesce(p_kind,'') <> 'statement' then
    return jsonb_build_object('ok', false, 'error','unknown_kind',
      'message', public._c('partner_doc.err_unknown_kind'));
  end if;

  v_period := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  if v_period is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('partner_doc.err_not_found'));
  end if;

  pay := public._c466_statement_payload(v_pid, v_period);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
      'message', public._c('partner_doc.err_not_found'));
  end if;

  select * into d from public.partner_document
   where partner_id = v_pid and kind = p_kind and ref_key = v_period::text;

  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('partner_doc.ready_message'),
      'gst', pay->'gst');
  end if;

  insert into public.partner_document(
      partner_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (v_pid, p_kind, v_period::text, pay->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (partner_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('supplier_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
    'poll_ms', 1500, 'message', public._c('partner_doc.building_message'),
    'gst', pay->'gst');
end $$;

create or replace function public.partner_doc_render_input(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare d public.partner_document%rowtype; pay jsonb;
begin
  select * into d from public.partner_document where id = p_doc_id;
  if not found then return jsonb_build_object('ok', false, 'error','doc_not_found'); end if;

  update public.partner_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  if d.kind = 'agreement' then
    pay := public._c692_agreement_doc_payload(d.ref_key::bigint);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
    end if;
    return jsonb_build_object('ok', true,
      'doc_id', d.id,
      'bucket', 'partner-receipts',
      'path', 'p' || d.partner_id::text || '/agreement/' ||
              regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
      'file_name', coalesce(nullif(d.file_name,''), 'agreement.pdf'),
      'document', pay->'doc');
  end if;

  pay := public._c466_statement_payload(d.partner_id, d.ref_key::bigint);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'partner-receipts',
    'path', 'p' || d.partner_id::text || '/statement/' ||
            regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'statement.pdf'),
    'document', pay->'doc');
end $$;

-- The signed copy's path lands back on the signature row when the render reports.
create or replace function public._c692_doc_ready_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.kind = 'agreement' and new.status = 'ready' and coalesce(new.path,'') <> '' then
    update public.partner_agreement_signature
       set doc_bucket = new.bucket, doc_path = new.path, updated_at = now()
     where id = nullif(regexp_replace(new.ref_key, '\D', '', 'g'),'')::bigint;
  end if;
  return new;
end $$;

drop trigger if exists c692_doc_ready on public.partner_document;
create trigger c692_doc_ready after insert or update on public.partner_document
  for each row execute function public._c692_doc_ready_trg();

-- ── 11. the doors ───────────────────────────────────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, description)
values
  ('partner.documents','My documents','Partner','fact_check','partner_documents',
   5,'partner', true, 'none', true, 'system','dashboard',
   'The partner agreement to sign and the KYC documents to upload.')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      owner = excluded.owner, partner_eligible = excluded.partner_eligible,
      is_active = true;

insert into public.surface_route(route_key, feature_key, kind, handled_by, note, is_active)
values ('partner_documents','partner.documents','feature','home_shell',
        'CHANGE #692 - the partner''s own agreement + KYC documents; opened by home_shell''s own route switch (case ''partner_documents'') in lib/screens/home_shell.dart, which builds PartnerDocumentsPage.',
        true)
on conflict (route_key, feature_key) do update
  set kind = excluded.kind, handled_by = excluded.handled_by,
      note = excluded.note, is_active = true;

-- The daily nudge rides the ONE cron dispatcher, at an offset, never a bare */N.
insert into public.cron_task(name, ord, mode, work_sql, step_timeout_ms, enabled,
                             note, base_interval_s, run_at_ist, dml)
values ('partner-kyc-reminder', 572, 'poll',
        'select public.partner_kyc_reminder_sweep();', 30000, true,
        'CHANGE #692 - one daily nudge per blocked partner. Offset minute on purpose: never a bare */N and never minute 0.',
        3600, time '10:23', true)
on conflict (name) do update
  set work_sql = excluded.work_sql, mode = excluded.mode,
      step_timeout_ms = excluded.step_timeout_ms, enabled = true,
      note = excluded.note, base_interval_s = excluded.base_interval_s,
      run_at_ist = excluded.run_at_ist, dml = excluded.dml;

grant execute on function public.partner_agreement_card(bigint) to authenticated;
grant execute on function public.partner_agreement_sign_start(jsonb) to authenticated;
grant execute on function public.partner_agreement_sign_verify(jsonb) to authenticated;
grant execute on function public.partner_agreement_versions() to authenticated;
grant execute on function public.partner_agreement_version_save(jsonb) to authenticated;
grant execute on function public.partner_kyc_card(bigint) to authenticated;
grant execute on function public.partner_kyc_upload_path(text, text) to authenticated;
grant execute on function public.partner_kyc_submit(jsonb) to authenticated;
grant execute on function public.partner_kyc_review_set(jsonb) to authenticated;
grant execute on function public.partner_golive_state(bigint) to authenticated;
grant execute on function public.partner_documents_screen(bigint) to authenticated;

-- A partner may always see and act on their OWN documents — that is the whole
-- point of the console card. The office sees them; only a super-admin verifies.
insert into public.access_role_default(role, feature_key, can_view, can_write) values
  ('partner',    'partner.documents', true,  true),
  ('admin',      'partner.documents', true,  false),
  ('super_admin','partner.documents', true,  true)
on conflict (role, feature_key) do update
  set can_view = excluded.can_view, can_write = excluded.can_write;

-- ── 12. version 1 of the agreement ──────────────────────────────────────────
-- Seeded once so the gate has something real to measure against on day one. A
-- super-admin edits it, or supersedes it, from the Agreement screen; this insert
-- never fires again.
insert into public.partner_agreement_version
  (version, title, body, effective_from, is_published, published_at, created_by)
select 1, 'mediBO zone partner agreement',
'1. Parties
This agreement is between Jai Mahakal Medical And Surgical, operating the mediBO platform ("mediBO"), and the fulfilment partner named above ("the Partner").

2. What the Partner does
The Partner fulfils orders placed on mediBO within the zone assigned to it: sourcing stock from ranked suppliers, counting it in, packing it, and handing it to delivery, in the sequence the platform sets out.

3. Licences
The Partner holds and keeps current a wholesale drug licence in Forms 20B and 21B, a GST registration, and every other approval its state requires to trade in pharmaceutical goods. Copies are uploaded to mediBO and re-uploaded before each expires. A lapsed licence suspends the Partner until it is renewed.

4. Pricing and money
Line prices are trade rates from supplier quotes and the catalogue, adjusted by discounts and scheme offers, with GST applied per item. MRP is regulatory reference information and is never the selling price. Settlement is per the split percentage and cadence configured for the zone. All amounts are in Indian Rupees.

5. Records
The Partner keeps purchase and sale records as the Drugs and Cosmetics Rules require, and makes them available to mediBO or to an inspector on request.

6. Conduct
The Partner does not sell outside the assigned zone through mediBO, does not substitute a product without the customer''s consent recorded in the app, and does not contact a mediBO customer to route an order off the platform.

7. Data
Customer, supplier and pricing data seen through mediBO is confidential and is used only to fulfil orders placed on the platform.

8. Suspension and exit
mediBO may suspend the Partner where a licence lapses, where documents are not verified, or where conduct above is breached. Either party may end this agreement with thirty days'' written notice; orders already accepted are fulfilled and settled first.

9. Changes
mediBO may publish a new version of this agreement. The Partner signs the new version before continuing to receive orders.

10. Governing law
This agreement is governed by the laws of India, and the courts of Chhattisgarh have jurisdiction.',
  current_date, true, now(), 'system'
where not exists (select 1 from public.partner_agreement_version);

-- ── 13. auto-solved: _kyc_claim_sync() raised on every region_partners write ─
-- The trigger fires on region_partners (UPDATE OF dl_20b, gstin) and its very
-- first statement reads `new.is_deleted`. region_partners has no such column, so
-- plpgsql raised `record "new" has no field "is_deleted"` — the `v_owner <>
-- 'partner' and ...` conjunction does not stop the field from being resolved.
-- Every write to a partner's drug licence number or GSTIN therefore failed,
-- including partner_onboarding_set('gst'/'dl_20b') and save_region_partner.
-- Found by CHANGE #692's own verify path; the column test moves into its own IF.
create or replace function public._kyc_claim_sync()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_owner text; v_dl text; v_gst text;
begin
  if tg_table_name = 'pharmacy_profiles' then
    v_owner := 'pharmacy'; v_dl := new.drug_license; v_gst := new.gstin;
  elsif tg_table_name = 'supplier_profiles' then
    v_owner := 'supplier'; v_dl := new.drug_license; v_gst := new.gstin;
  else
    v_owner := 'partner';  v_dl := new.dl_20b;       v_gst := new.gstin;
  end if;

  -- `new.is_deleted` is read ONLY on the two tables that have the column.
  if v_owner <> 'partner' then
    if coalesce(new.is_deleted, false) then
      delete from kyc_identity_claim
       where owner_kind = v_owner and owner_id = new.id::text;
      return new;
    end if;
  end if;

  perform public.kyc_identity_claim_set('dl',    v_dl,  v_owner, new.id::text);
  perform public.kyc_identity_claim_set('gstin', v_gst, v_owner, new.id::text);
  return new;
end $$;

-- ── 14. auto-solved: an admin RPC was anon-executable ───────────────────────
-- admin_partner_scorecards() shipped without the #436 revoke, so the anon key
-- that rides inside the web bundle and the APK could call an admin surface.
-- rg_check's privileged_rpcs_are_not_anon guard was red on it; the fix is the
-- same two lines every other admin_* function carries.
revoke execute on function public.admin_partner_scorecards(date) from public, anon;
grant  execute on function public.admin_partner_scorecards(date) to authenticated;

-- The same lock on everything CHANGE #692 added. None of these has a tokenless
-- caller: a partner or the office is always signed in.
revoke execute on function public.partner_agreement_card(bigint) from public, anon;
revoke execute on function public.partner_agreement_sign_start(jsonb) from public, anon;
revoke execute on function public.partner_agreement_sign_verify(jsonb) from public, anon;
revoke execute on function public.partner_agreement_versions() from public, anon;
revoke execute on function public.partner_agreement_version_save(jsonb) from public, anon;
revoke execute on function public.partner_kyc_card(bigint) from public, anon;
revoke execute on function public.partner_kyc_upload_path(text, text) from public, anon;
revoke execute on function public.partner_kyc_submit(jsonb) from public, anon;
revoke execute on function public.partner_kyc_review_set(jsonb) from public, anon;
revoke execute on function public.partner_golive_state(bigint) from public, anon;
revoke execute on function public.partner_documents_screen(bigint) from public, anon;
revoke execute on function public.partner_kyc_reminder_sweep() from public, anon;
