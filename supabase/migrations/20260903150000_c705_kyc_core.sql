-- CHANGE #705 (1/5) — KYC parity: the documents themselves.
--
-- Verified in the database before this change: riders carry full KYC (OTP,
-- selfie, ID document, three expiries, training) on delivery_partner_
-- registrations. Pharmacies and suppliers carried TYPED TEXT and nothing else —
-- of 10 approved pharmacies 3 had no drug licence at all, 10 had no dl_expiry
-- and 8 had no GSTIN; of 36 approved suppliers, 36 had no licence, no expiry
-- and no GSTIN. There was no document anywhere, no verification state, no
-- expiry sweep. #810 and #753 already draw a KYC state CHIP for both from that
-- typed text; this change gives that chip something real to read.
--
-- partner_document / supplier_document are NOT this: they are generated-report
-- queues (kind/ref_key/bucket/path/status='queued'), nothing to do with KYC.
--
-- Everything here is idempotent — a resumed worker re-applies it as a no-op.

-- ── the table ──────────────────────────────────────────────────────────────
create table if not exists public.kyc_documents (
  id            uuid primary key default gen_random_uuid(),
  owner_kind    text not null check (owner_kind in ('pharmacy','supplier')),
  owner_id      uuid not null,
  kind          text not null check (kind in ('drug_licence','gst_certificate','shop_photo','pan')),
  bucket        text not null default 'kyc-docs',
  path          text not null,
  file_name     text,
  mime_type     text,
  bytes         bigint,
  number        text,
  valid_from    date,
  valid_to      date,
  status        text not null default 'pending' check (status in ('pending','verified','rejected','superseded')),
  reason        text,
  submitted_by  uuid,
  submitted_at  timestamptz not null default now(),
  verified_by   uuid,
  verified_at   timestamptz,
  source        text not null default 'app' check (source in ('app','token','admin')),
  zone_id       smallint,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

comment on table public.kyc_documents is
  'CHANGE #705 — one uploaded KYC document for a pharmacy or a supplier. '
  'owner_kind+owner_id points at pharmacy_profiles.id or supplier_profiles.id. '
  'Exactly one row per (owner, kind) may be status=verified or pending; older '
  'ones are superseded, never deleted, so the audit trail survives a re-upload.';

create index if not exists kyc_documents_owner_idx
  on public.kyc_documents (owner_kind, owner_id, kind, status);
create index if not exists kyc_documents_queue_idx
  on public.kyc_documents (status, submitted_at desc)
  where status = 'pending';
create index if not exists kyc_documents_expiry_idx
  on public.kyc_documents (valid_to)
  where status = 'verified' and valid_to is not null;
create index if not exists kyc_documents_zone_idx
  on public.kyc_documents (zone_id, status, submitted_at desc);

-- Only ONE live document per (owner, kind). A re-upload supersedes.
create unique index if not exists kyc_documents_live_uk
  on public.kyc_documents (owner_kind, owner_id, kind)
  where status in ('pending','verified');

alter table public.kyc_documents enable row level security;

-- The owner sees their own documents; nobody writes through the table (every
-- write goes through a SECURITY DEFINER RPC that decides who may do it).
drop policy if exists kyc_documents_owner_read on public.kyc_documents;
create policy kyc_documents_owner_read on public.kyc_documents
  for select to authenticated
  using (
    public.get_my_role() in ('admin','super_admin')
    or (owner_kind = 'pharmacy'
        and owner_id in (select id from public.pharmacy_profiles where user_id = auth.uid()))
    or (owner_kind = 'supplier'
        and owner_id in (select id from public.supplier_profiles where user_id = auth.uid()))
  );

-- ── the private bucket ─────────────────────────────────────────────────────
insert into storage.buckets (id, name, public)
values ('kyc-docs', 'kyc-docs', false)
on conflict (id) do nothing;

-- An applicant may put a file into their OWN folder and read it back; nobody
-- else reaches it without a signed URL minted for a reviewer.
drop policy if exists kyc_docs_owner_write on storage.objects;
create policy kyc_docs_owner_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'kyc-docs' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists kyc_docs_owner_read on storage.objects;
create policy kyc_docs_owner_read on storage.objects
  for select to authenticated
  using (bucket_id = 'kyc-docs'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or public.get_my_role() in ('admin','super_admin')));

-- ── configuration (data, not code) ─────────────────────────────────────────
insert into public.app_settings (key, value)
values ('kyc_gate', jsonb_build_object(
          'grace_days', 14,           -- existing approved accounts keep working this long
          'enforced_from', '2026-09-03',  -- the day the requirement started existing
          'remind_days', jsonb_build_array(30, 7, 1),
          'required_kinds', jsonb_build_array('drug_licence'),
          'enforce', true))
on conflict (key) do nothing;

-- ── the copy. Every sentence the applicant, the reviewer or the gate shows ──
insert into public.ui_copy (key, value) values
  ('kyc.title',              to_jsonb('Licence & documents'::text)),
  ('kyc.subtitle',           to_jsonb('Upload your drug licence and GST certificate. We verify them before your account can trade.'::text)),
  ('kyc.kind.drug_licence',  to_jsonb('Drug licence'::text)),
  ('kyc.kind.gst_certificate', to_jsonb('GST certificate'::text)),
  ('kyc.kind.shop_photo',    to_jsonb('Shop photo'::text)),
  ('kyc.kind.pan',           to_jsonb('PAN card'::text)),
  ('kyc.status.pending',     to_jsonb('Awaiting verification'::text)),
  ('kyc.status.verified',    to_jsonb('Verified'::text)),
  ('kyc.status.rejected',    to_jsonb('Rejected'::text)),
  ('kyc.status.missing',     to_jsonb('Not uploaded'::text)),
  ('kyc.status.expired',     to_jsonb('Expired'::text)),
  ('kyc.btn_upload',         to_jsonb('Upload'::text)),
  ('kyc.btn_replace',        to_jsonb('Replace'::text)),
  ('kyc.btn_renew',          to_jsonb('Renew'::text)),
  ('kyc.required_note',      to_jsonb('Required'::text)),
  ('kyc.optional_note',      to_jsonb('Optional'::text)),
  ('kyc.expiry_label',       to_jsonb('Valid till {d}'::text)),
  ('kyc.no_expiry_label',    to_jsonb('No expiry recorded'::text)),
  ('kyc.number_label',       to_jsonb('Number'::text)),
  ('kyc.rejected_prefix',    to_jsonb('Rejected: {reason}'::text)),
  ('kyc.saved_toast',        to_jsonb('Uploaded. We will verify it shortly.'::text)),
  ('kyc.empty_note',         to_jsonb('Nothing uploaded yet. Add your drug licence to start trading.'::text)),
  ('kyc.err_not_signed_in',  to_jsonb('Please sign in first.'::text)),
  ('kyc.err_no_owner',       to_jsonb('This login is not linked to a pharmacy or supplier account.'::text)),
  ('kyc.err_bad_kind',       to_jsonb('That document type is not accepted.'::text)),
  ('kyc.err_no_path',        to_jsonb('The file did not upload. Please try again.'::text)),
  ('kyc.err_expiry_past',    to_jsonb('That expiry date has already passed.'::text))
on conflict (key) do nothing;

-- ── who is asking ──────────────────────────────────────────────────────────
-- A read that derives its owner from auth.uid() cannot be proven from cron or
-- from an acceptance test, so the OWNER is a parameter everywhere below and
-- this is the only place that answers "who is asking".
create or replace function public.kyc_owner_for_me()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then
    return jsonb_build_object('has', false, 'reason', 'not_signed_in');
  end if;
  select id into v_id from pharmacy_profiles
   where user_id = v_uid and not coalesce(is_deleted,false) limit 1;
  if v_id is not null then
    return jsonb_build_object('has', true, 'owner_kind','pharmacy', 'owner_id', v_id);
  end if;
  select id into v_id from supplier_profiles
   where user_id = v_uid and not coalesce(is_deleted,false) limit 1;
  if v_id is not null then
    return jsonb_build_object('has', true, 'owner_kind','supplier', 'owner_id', v_id);
  end if;
  return jsonb_build_object('has', false, 'reason', 'no_owner');
end
$fn$;

-- ── the one source of truth for "is this account KYC-clear?" ───────────────
create or replace function public.kyc_state(p_owner_kind text, p_owner_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_cfg    jsonb := coalesce((select value from app_settings where key='kyc_gate'),
                             '{"grace_days":14,"required_kinds":["drug_licence"],"enforce":true}'::jsonb);
  v_grace  int   := coalesce((v_cfg->>'grace_days')::int, 14);
  v_req    text[]:= coalesce((select array_agg(x #>> '{}')
                                from jsonb_array_elements(coalesce(v_cfg->'required_kinds','[]'::jsonb)) x),
                             array['drug_licence']);
  v_today  date  := (now() at time zone 'Asia/Kolkata')::date;
  v_kind   text  := lower(btrim(coalesce(p_owner_kind,'')));
  d        record;
  v_state  text;
  v_missing text[] := '{}';
  v_expired text[] := '{}';
  v_pending text[] := '{}';
  v_rejected text[] := '{}';
  v_soonest date;
  v_approved_at timestamptz;
  v_approved boolean := false;
  v_from date := coalesce((v_cfg->>'enforced_from')::date, date '2026-09-03');
  v_in_grace boolean := false;
  v_grace_until date;
  v_synthetic boolean := false;
  k text;
begin
  if v_kind = 'pharmacy' then
    select approved_at, coalesce(approved,false), coalesce(is_synthetic,false)
      into v_approved_at, v_approved, v_synthetic
      from pharmacy_profiles where id = p_owner_id;
  elsif v_kind = 'supplier' then
    select approved_at, coalesce(approved,false), coalesce(is_synthetic,false)
      into v_approved_at, v_approved, v_synthetic
      from supplier_profiles where id = p_owner_id;
  else
    return jsonb_build_object('ok', false, 'error','bad_owner_kind');
  end if;

  foreach k in array v_req loop
    select * into d from kyc_documents
     where owner_kind = v_kind and owner_id = p_owner_id and kind = k
       and status in ('pending','verified')
     order by submitted_at desc limit 1;
    if not found then
      -- a rejection still counts as "not clear", but says so differently
      if exists (select 1 from kyc_documents
                  where owner_kind = v_kind and owner_id = p_owner_id
                    and kind = k and status = 'rejected') then
        v_rejected := v_rejected || k;
      else
        v_missing := v_missing || k;
      end if;
    elsif d.status = 'pending' then
      v_pending := v_pending || k;
    elsif d.valid_to is not null and d.valid_to < v_today then
      v_expired := v_expired || k;
    else
      v_soonest := least(v_soonest, d.valid_to);
    end if;
  end loop;

  v_state := case
    when array_length(v_expired,1)  is not null then 'expired'
    when array_length(v_rejected,1) is not null then 'rejected'
    when array_length(v_missing,1)  is not null then 'missing'
    when array_length(v_pending,1)  is not null then 'pending'
    else 'verified' end;

  -- Grace exists because the REQUIREMENT is new, not because the account is:
  -- every account that was already approved when this shipped keeps trading for
  -- grace_days from enforced_from, and then the block applies. An account
  -- approved after that date already had to pass the approve gate, and an
  -- account that is not approved at all has nothing to keep. approved_at is
  -- NULL on most of these rows (36/36 suppliers), so it is a filter, never the
  -- clock — reading the clock off it gave 36 suppliers no grace at all.
  -- ...but grace never covers an EXPIRED document. Grace answers "we only
  -- started asking for this today"; an account that uploaded a licence and let
  -- it lapse has had its own 30/7/1-day warnings and its own deadline, and
  -- letting the launch window excuse that would make kyc_expiry_sweep's block
  -- do nothing for its first fortnight.
  v_grace_until := case when v_approved then v_from + v_grace else null end;
  v_in_grace := v_state not in ('verified','expired')
                and v_approved
                and (v_approved_at is null or (v_approved_at at time zone 'Asia/Kolkata')::date <= v_from)
                and v_today <= v_grace_until;

  return jsonb_build_object(
    'ok', true,
    'owner_kind', v_kind,
    'owner_id', p_owner_id,
    'state', v_state,
    'clear', (v_state = 'verified'),
    -- A SYNTHETIC account is a fixture, not a customer: the QA logins the
    -- protected suite and the journey probes trade with, and the throwaway
    -- shops c419/c420/c424/c427 create and delete inside one call. They carry
    -- is_synthetic (an applicant can never set it — it is not on
    -- submit_registration's allow-list), every money report already excludes
    -- them (#857), and asking a fixture for a drug licence would have blocked
    -- the fleet's own proofs rather than a single real pharmacy.
    'enforce', (coalesce((v_cfg->>'enforce')::boolean, true) and not v_synthetic),
    'synthetic', v_synthetic,
    'in_grace', v_in_grace,
    'grace_days', v_grace,
    'grace_until', v_grace_until,
    'expiry', v_soonest,
    'expiry_label', case when v_soonest is null then _c('kyc.no_expiry_label')
                         else _cf('kyc.expiry_label',
                                jsonb_build_object('d', to_char(v_soonest,'FMDD Mon YYYY'))) end,
    'missing', to_jsonb(v_missing),
    'expired', to_jsonb(v_expired),
    'pending', to_jsonb(v_pending),
    'rejected', to_jsonb(v_rejected),
    'required_kinds', to_jsonb(v_req));
end
$fn$;

-- ── the applicant's own panel — render-ready, one RPC ──────────────────────
create or replace function public.kyc_my_panel()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text; v_id uuid; v_state jsonb; v_rows jsonb;
  v_cfg jsonb := coalesce((select value from app_settings where key='kyc_gate'), '{}'::jsonb);
  v_req text[] := coalesce((select array_agg(x #>> '{}')
                              from jsonb_array_elements(coalesce(v_cfg->'required_kinds','[]'::jsonb)) x),
                           array['drug_licence']);
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_me->>'reason',
      'title', _c('kyc.title'),
      'message', case v_me->>'reason' when 'not_signed_in' then _c('kyc.err_not_signed_in')
                                      else _c('kyc.err_no_owner') end);
  end if;
  v_kind := v_me->>'owner_kind';
  v_id   := (v_me->>'owner_id')::uuid;
  v_state := public.kyc_state(v_kind, v_id);

  select coalesce(jsonb_agg(r order by r_ord), '[]'::jsonb) into v_rows from (
    select t.ord as r_ord, jsonb_build_object(
      'kind', t.kind,
      'label', _c('kyc.kind.'||t.kind),
      'required', (t.kind = any(v_req)),
      'requirement_label', case when t.kind = any(v_req) then _c('kyc.required_note')
                                else _c('kyc.optional_note') end,
      'has', (d.id is not null),
      'doc_id', d.id,
      'bucket', d.bucket,
      'path', d.path,
      'file_name', coalesce(d.file_name,''),
      'number', coalesce(d.number,''),
      'number_label', _c('kyc.number_label'),
      'valid_to', d.valid_to,
      'expiry_label', case when d.id is null then ''
                           when d.valid_to is null then _c('kyc.no_expiry_label')
                           else _cf('kyc.expiry_label',
                                  jsonb_build_object('d', to_char(d.valid_to,'FMDD Mon YYYY'))) end,
      'status', coalesce(d.status, 'missing'),
      'status_label', case
          when d.id is null then _c('kyc.status.missing')
          when d.status = 'verified' and d.valid_to is not null
               and d.valid_to < (now() at time zone 'Asia/Kolkata')::date then _c('kyc.status.expired')
          else _c('kyc.status.'||d.status) end,
      'status_tone', case
          when d.id is null then 'warning'
          when d.status = 'rejected' then 'danger'
          when d.status = 'verified' and d.valid_to is not null
               and d.valid_to < (now() at time zone 'Asia/Kolkata')::date then 'danger'
          when d.status = 'verified' then 'success'
          else 'info' end,
      'reason_line', case when coalesce(d.reason,'') = '' then ''
                          else _cf('kyc.rejected_prefix', jsonb_build_object('reason', d.reason)) end,
      'button_label', case
          when d.id is null then _c('kyc.btn_upload')
          when d.status = 'verified' and d.valid_to is not null
               and d.valid_to < (now() at time zone 'Asia/Kolkata')::date then _c('kyc.btn_renew')
          else _c('kyc.btn_replace') end
    ) as r
    from (values ('drug_licence',1),('gst_certificate',2),('shop_photo',3),('pan',4))
           as t(kind, ord)
    left join lateral (
      select * from kyc_documents k
       where k.owner_kind = v_kind and k.owner_id = v_id and k.kind = t.kind
         and k.status in ('pending','verified','rejected')
       order by case k.status when 'verified' then 0 when 'pending' then 1 else 2 end,
                k.submitted_at desc
       limit 1) d on true
  ) x;

  return jsonb_build_object(
    'ok', true,
    'title', _c('kyc.title'),
    'subtitle', _c('kyc.subtitle'),
    'empty_note', _c('kyc.empty_note'),
    'bucket', 'kyc-docs',
    'owner_kind', v_kind,
    'owner_id', v_id,
    'state', v_state,
    'items', v_rows);
end
$fn$;

-- ── the applicant's write ──────────────────────────────────────────────────
-- The FILE is put into storage by the client (owner-scoped policy above); this
-- registers it, supersedes whatever it replaces, and returns the fresh panel.
create or replace function public.kyc_upload_register(
  p_kind text, p_path text, p_file_name text default null,
  p_number text default null, p_valid_from date default null, p_valid_to date default null,
  p_mime text default null, p_bytes bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text := lower(btrim(coalesce(p_kind,'')));
  v_owner text; v_id uuid; v_zone smallint; v_doc uuid;
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_me->>'reason', 'tone','danger',
      'message', case v_me->>'reason' when 'not_signed_in' then _c('kyc.err_not_signed_in')
                                      else _c('kyc.err_no_owner') end);
  end if;
  if v_kind not in ('drug_licence','gst_certificate','shop_photo','pan') then
    return jsonb_build_object('ok', false, 'error','bad_kind', 'tone','danger',
      'message', _c('kyc.err_bad_kind'));
  end if;
  if nullif(btrim(coalesce(p_path,'')),'') is null then
    return jsonb_build_object('ok', false, 'error','no_path', 'tone','danger',
      'message', _c('kyc.err_no_path'));
  end if;
  if p_valid_to is not null and p_valid_to < (now() at time zone 'Asia/Kolkata')::date then
    return jsonb_build_object('ok', false, 'error','expiry_past', 'tone','danger',
      'message', _c('kyc.err_expiry_past'));
  end if;

  v_owner := v_me->>'owner_kind';
  v_id    := (v_me->>'owner_id')::uuid;
  if v_owner = 'pharmacy' then
    select zone_id into v_zone from pharmacy_profiles where id = v_id;
  else
    select zone_id into v_zone from supplier_profiles where id = v_id;
  end if;

  update kyc_documents set status = 'superseded', updated_at = now()
   where owner_kind = v_owner and owner_id = v_id and kind = v_kind
     and status in ('pending','verified');

  insert into kyc_documents(owner_kind, owner_id, kind, path, file_name, mime_type, bytes,
                            number, valid_from, valid_to, submitted_by, zone_id, source)
  values (v_owner, v_id, v_kind, btrim(p_path), nullif(btrim(coalesce(p_file_name,'')),''),
          nullif(btrim(coalesce(p_mime,'')),''), p_bytes,
          nullif(btrim(coalesce(p_number,'')),''), p_valid_from, p_valid_to,
          auth.uid(), v_zone, 'app')
  returning id into v_doc;

  -- Keep the typed columns #810/#753 already read in step with the document.
  if v_kind = 'drug_licence' then
    if v_owner = 'pharmacy' then
      update pharmacy_profiles
         set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
             dl_expiry    = coalesce(p_valid_to, dl_expiry)
       where id = v_id;
    else
      update supplier_profiles
         set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
             dl_expiry    = coalesce(p_valid_to, dl_expiry)
       where id = v_id;
    end if;
  elsif v_kind = 'gst_certificate' then
    if v_owner = 'pharmacy' then
      update pharmacy_profiles
         set gstin = coalesce(nullif(btrim(coalesce(p_number,'')),''), gstin)
       where id = v_id;
    else
      update supplier_profiles
         set gstin        = coalesce(nullif(btrim(coalesce(p_number,'')),''), gstin),
             gstin_expiry = coalesce(p_valid_to, gstin_expiry)
       where id = v_id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'tone','success', 'doc_id', v_doc,
    'message', _c('kyc.saved_toast'),
    'panel', public.kyc_my_panel());
end
$fn$;

grant execute on function public.kyc_my_panel() to authenticated;
grant execute on function public.kyc_upload_register(text,text,text,text,date,date,text,bigint) to authenticated;
grant execute on function public.kyc_owner_for_me() to authenticated;
grant execute on function public.kyc_state(text,uuid) to authenticated;
