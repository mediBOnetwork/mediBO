-- CMD #1935 — Customer onboarding step 2: an ADMIN-CONTROLLED document
-- checklist.
--
-- Before this, "which documents does a customer owe?" was written in three
-- places that could disagree: a VALUES list inside kyc_my_panel, a CHECK
-- constraint on kyc_documents.kind, and app_settings.kyc_gate.required_kinds.
-- Adding a document, or making one mandatory, meant a deploy. It is now ONE
-- table — customer_doc_types — and every surface reads it: the step-2
-- checklist, the upload door, the approval gate and the OCR autofill. Toggling
-- `required` or `active` is an UPDATE; nothing is rebuilt.
--
-- Idempotent by construction: `create table if not exists`, copy inserts are
-- `on conflict do nothing` (wording is Om's to edit, not a redeploy's to
-- overwrite), seeds are `on conflict do nothing` (an admin's later edit to
-- `required` survives every replay), functions are `create or replace`.

-- ── 1. The table ──────────────────────────────────────────────────────────
create table if not exists public.customer_doc_types (
  key                 text primary key,
  label               text not null,
  hint                text not null default '',
  required            boolean not null default false,
  active              boolean not null default true,
  sort_order          int not null default 100,
  -- Which field of kyc_doc_extract.fields carries this document's number.
  -- Empty = nothing to autofill (a photo, a selfie).
  ocr_field           text not null default '',
  accepts_camera_only boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

comment on table public.customer_doc_types is
  'CMD #1935 — the customer onboarding document checklist. One row per document; '
  'required/active/sort_order are admin-editable and take effect on the next read, never a deploy.';

alter table public.customer_doc_types enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='customer_doc_types'
                    and policyname='customer_doc_types_read') then
    create policy customer_doc_types_read on public.customer_doc_types
      for select using (true);
  end if;
end $$;

revoke all on public.customer_doc_types from anon;
grant select on public.customer_doc_types to authenticated;

-- Seed. `do nothing` on purpose: once Om flips `required` on a row, a replay
-- of this file must never flip it back.
insert into public.customer_doc_types(key, label, hint, required, active, sort_order, ocr_field, accepts_camera_only) values
  ('dl_20b',      'Drug Licence 20B', 'Retail licence for allopathic medicines', true,  true, 10, 'licence_number', false),
  ('dl_21b',      'Drug Licence 21B', 'Retail licence for restricted medicines', false, true, 20, 'licence_number', false),
  ('gst',         'GST Certificate',  'GSTIN registration certificate',          false, true, 30, 'gstin',          false),
  ('pan',         'PAN Card',         'PAN of the firm or the proprietor',       false, true, 40, 'pan',            false),
  ('fssai',       'FSSAI Licence',    'Only if you sell food or nutrition items', false, true, 50, 'fssai_number',  false),
  ('shop_photo',  'Shop Photo',       'The shop front with the board visible',   false, true, 60, '',               true),
  ('owner_selfie','Owner Selfie',     'A photo of the owner at the shop',        false, true, 70, '',               true)
on conflict (key) do nothing;

-- ── 2. kyc_documents accepts the new vocabulary ───────────────────────────
-- `kind` used to be a four-value CHECK. A list in DDL is exactly the deploy
-- this command exists to remove, so the constraint keeps the column honest
-- (non-blank) and customer_doc_types is what actually decides which kinds a
-- customer may upload — enforced in kyc_upload_register, where the applicant
-- reads a sentence instead of a constraint violation.
do $$ begin
  if exists (select 1 from pg_constraint
              where conrelid = 'public.kyc_documents'::regclass
                and contype = 'c'
                and pg_get_constraintdef(oid) like '%kind = ANY%') then
    execute (select 'alter table public.kyc_documents drop constraint '||quote_ident(conname)
               from pg_constraint
              where conrelid = 'public.kyc_documents'::regclass
                and contype = 'c'
                and pg_get_constraintdef(oid) like '%kind = ANY%'
              limit 1);
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_constraint
                  where conrelid='public.kyc_documents'::regclass and conname='kyc_documents_kind_nonblank') then
    alter table public.kyc_documents
      add constraint kyc_documents_kind_nonblank check (btrim(coalesce(kind,'')) <> '');
  end if;
end $$;

-- `submitted` is what a customer's own upload is (it has not been looked at by
-- anybody yet — the same meaning `pending` carries, under the word the spec
-- uses), and `not_available` is the "I don't have this" answer: a recorded
-- ANSWER, never a silent gap.
do $$
declare v_name text;
begin
  select conname into v_name from pg_constraint
   where conrelid='public.kyc_documents'::regclass and contype='c'
     and pg_get_constraintdef(oid) like '%status = ANY%' limit 1;
  if v_name is not null then
    execute 'alter table public.kyc_documents drop constraint '||quote_ident(v_name);
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid='public.kyc_documents'::regclass and conname='kyc_documents_status_chk') then
    alter table public.kyc_documents add constraint kyc_documents_status_chk
      check (status = any (array['pending','submitted','verified','rejected','superseded','not_available']));
  end if;
end $$;

-- ── 3. Copy ───────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('custdoc.title',            '"Your documents"'::jsonb),
  ('custdoc.step_label',       '"Step 2 of 2"'::jsonb),
  ('custdoc.subtitle',         '"Upload what you have. You can skip anything that does not apply."'::jsonb),
  ('custdoc.skip_label',       '"I don''t have this"'::jsonb),
  ('custdoc.required_note',    '"Required"'::jsonb),
  ('custdoc.optional_note',    '"Optional"'::jsonb),
  ('custdoc.upload_label',     '"Upload"'::jsonb),
  ('custdoc.replace_label',    '"Replace"'::jsonb),
  ('custdoc.camera_only_note', '"Take this photo with the camera"'::jsonb),
  ('custdoc.status.missing',        '"Not uploaded"'::jsonb),
  ('custdoc.status.submitted',      '"Submitted"'::jsonb),
  ('custdoc.status.pending',        '"Submitted"'::jsonb),
  ('custdoc.status.verified',       '"Verified"'::jsonb),
  ('custdoc.status.rejected',       '"Rejected"'::jsonb),
  ('custdoc.status.not_available',  '"Marked not available"'::jsonb),
  ('custdoc.status.superseded',     '"Replaced"'::jsonb),
  ('custdoc.done_title',       '"All required documents are in"'::jsonb),
  ('custdoc.done_line',        '"We will verify them and approve your account."'::jsonb),
  ('custdoc.blocked_line',     '"{n} required document still to upload."'::jsonb),
  ('custdoc.blocked_line_many','"{n} required documents still to upload."'::jsonb),
  ('custdoc.close_label',      '"Close"'::jsonb),
  ('custdoc.empty_line',       '"No documents are being collected right now."'::jsonb),
  ('custdoc.err_not_signed_in','"Sign in to upload your documents."'::jsonb),
  ('custdoc.err_no_owner',     '"Finish your business details first."'::jsonb),
  ('custdoc.err_bad_key',      '"That document is not being collected."'::jsonb),
  ('custdoc.err_required_skip','"This document is required — it cannot be skipped."'::jsonb),
  ('custdoc.skipped_toast',    '"Noted — you can upload it later."'::jsonb),
  ('custdoc.unskipped_toast',  '"Ready when you are."'::jsonb),
  -- The retake sentence. One per document that carries a number, so the
  -- customer is told WHICH read failed, and a default for the rest.
  ('custdoc.unreadable.default','"We could not read this document — upload a clearer photo."'::jsonb),
  ('custdoc.unreadable.gst',    '"GSTIN could not be read — upload a clearer photo."'::jsonb),
  ('custdoc.unreadable.pan',    '"PAN could not be read — upload a clearer photo."'::jsonb),
  ('custdoc.unreadable.dl_20b', '"The licence number could not be read — upload a clearer photo."'::jsonb),
  ('custdoc.unreadable.dl_21b', '"The licence number could not be read — upload a clearer photo."'::jsonb),
  ('custdoc.unreadable.fssai',  '"The FSSAI number could not be read — upload a clearer photo."'::jsonb),
  ('custdoc.retake_label',      '"Retake"'::jsonb),
  -- The Home banner.
  ('custreg.banner_title',     '"Complete registration"'::jsonb),
  ('custreg.banner_details',   '"Add your business details to start ordering."'::jsonb),
  ('custreg.banner_documents', '"Upload your documents to finish registration."'::jsonb),
  ('custreg.banner_cta',       '"Continue"'::jsonb),
  -- Admin.
  ('custdoc_admin.title',      '"Customer documents"'::jsonb),
  ('custdoc_admin.subtitle',   '"What every new customer is asked for. Changes are live immediately."'::jsonb),
  ('custdoc_admin.required',   '"Required"'::jsonb),
  ('custdoc_admin.active',     '"Collected"'::jsonb),
  ('custdoc_admin.camera_only','"Camera only"'::jsonb),
  ('custdoc_admin.saved',      '"Saved"'::jsonb),
  ('custdoc_admin.denied',     '"Admins only."'::jsonb),
  ('custdoc_admin.empty',      '"No document types yet."'::jsonb),
  -- The approval refusal, built here.
  ('custdoc.approve_blocked',  '"Cannot approve — {docs} not submitted yet."'::jsonb)
on conflict (key) do nothing;

-- ── 4. The checklist ──────────────────────────────────────────────────────
-- Step 2 renders THIS and nothing else. Every label, every chip, every
-- sentence is on the payload; the screen chooses nothing.
create or replace function public.kyc_doc_checklist()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_me    jsonb := public.kyc_owner_for_me();
  v_kind  text;
  v_id    uuid;
  v_rows  jsonb;
  v_left  int := 0;
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_me->>'reason',
      'title', public._c('custdoc.title'),
      'step_label', public._c('custdoc.step_label'),
      'message', case v_me->>'reason'
                   when 'not_signed_in' then public._c('custdoc.err_not_signed_in')
                   else public._c('custdoc.err_no_owner') end,
      'items', '[]'::jsonb);
  end if;
  v_kind := v_me->>'owner_kind';
  v_id   := (v_me->>'owner_id')::uuid;

  select coalesce(jsonb_agg(x order by x_ord), '[]'::jsonb) into v_rows from (
    select t.sort_order as x_ord, jsonb_build_object(
      'key',   t.key,
      'label', t.label,
      'hint',  t.hint,
      'required', t.required,
      -- A required document offers no way out; that is the whole difference
      -- between the two, and it is decided here, not by the screen.
      'can_skip', (not t.required),
      'skip_label', case when t.required then '' else public._c('custdoc.skip_label') end,
      'skipped', (coalesce(d.status,'') = 'not_available'),
      'requirement_label', case when t.required then public._c('custdoc.required_note')
                                else public._c('custdoc.optional_note') end,
      'camera_only', t.accepts_camera_only,
      'camera_only_note', case when t.accepts_camera_only
                               then public._c('custdoc.camera_only_note') else '' end,
      'has', (d.id is not null and coalesce(d.status,'') <> 'not_available'),
      'doc_id', d.id,
      'file_name', coalesce(d.file_name,''),
      'number', coalesce(d.number,''),
      'valid_to', d.valid_to,
      'status', coalesce(d.status, 'missing'),
      'status_label', public._c('custdoc.status.'||coalesce(d.status,'missing')),
      'status_tone', case
          when coalesce(d.status,'') = 'verified' then 'success'
          when coalesce(d.status,'') = 'rejected' then 'danger'
          when coalesce(d.status,'') = 'not_available' then 'neutral'
          when d.id is null then 'warning'
          else 'info' end,
      'action_label', case when d.id is null or coalesce(d.status,'') = 'not_available'
                           then public._c('custdoc.upload_label')
                           else public._c('custdoc.replace_label') end,
      -- CMD #1935 — the retake ask. The OCR ran, it finished, and the number
      -- this document is supposed to carry is still not there: say so NOW,
      -- while the customer still has the paper in their hand.
      'retake_reason', case
          when d.id is null then ''
          when coalesce(t.ocr_field,'') = '' then ''
          when x.status is null or x.status = 'running' or x.status = 'queued' then ''
          when x.status = 'done'
               and nullif(btrim(coalesce(x.fields->>t.ocr_field,'')),'') is not null then ''
          when coalesce(btrim(coalesce(d.number,'')),'') <> '' then ''
          else coalesce(nullif(public._c('custdoc.unreadable.'||t.key),''),
                        public._c('custdoc.unreadable.default')) end,
      'retake_label', public._c('custdoc.retake_label')
    ) as x
      from public.customer_doc_types t
      left join lateral (
        select * from public.kyc_documents kd
         where kd.owner_kind = v_kind and kd.owner_id = v_id and kd.kind = t.key
           and kd.status in ('pending','submitted','verified','rejected','not_available')
         order by kd.submitted_at desc nulls last, kd.created_at desc limit 1
      ) d on true
      left join lateral (
        select * from public.kyc_doc_extract e where e.doc_id = d.id
      ) x on true
     where t.active
  ) q;

  select count(*) into v_left
    from public.customer_doc_types t
   where t.active and t.required
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = v_kind and kd.owner_id = v_id
                        and kd.kind = t.key and kd.status in ('pending','submitted','verified'));

  return jsonb_build_object(
    'ok', true,
    -- WHERE the file goes is the backend's answer, exactly as it is for
    -- kyc_my_panel: upload_prefix is the folder the storage policy admits for
    -- THIS login, and it is auth.uid(), never the profile id.
    'bucket', 'kyc-docs',
    'upload_prefix', auth.uid()::text,
    'title', public._c('custdoc.title'),
    'step_label', public._c('custdoc.step_label'),
    'subtitle', public._c('custdoc.subtitle'),
    'close_label', public._c('custdoc.close_label'),
    'empty_line', public._c('custdoc.empty_line'),
    'items', v_rows,
    'item_count', jsonb_array_length(v_rows),
    'required_left', v_left,
    'done', (v_left = 0),
    'summary_title', case when v_left = 0 then public._c('custdoc.done_title') else '' end,
    'summary_line', case when v_left = 0 then public._c('custdoc.done_line')
                         when v_left = 1 then public._cf('custdoc.blocked_line',
                                                jsonb_build_object('n', v_left::text))
                         else public._cf('custdoc.blocked_line_many',
                                         jsonb_build_object('n', v_left::text)) end,
    'summary_tone', case when v_left = 0 then 'success' else 'warning' end);
end $function$;

revoke all on function public.kyc_doc_checklist() from public, anon;
grant execute on function public.kyc_doc_checklist() to authenticated, service_role;

-- ── 5. "I don't have this" ────────────────────────────────────────────────
create or replace function public.kyc_doc_skip(p_key text, p_skip boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text; v_id uuid; t public.customer_doc_types%rowtype; v_zone smallint;
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', case v_me->>'reason'
                   when 'not_signed_in' then public._c('custdoc.err_not_signed_in')
                   else public._c('custdoc.err_no_owner') end);
  end if;
  v_kind := v_me->>'owner_kind';
  v_id   := (v_me->>'owner_id')::uuid;

  select * into t from public.customer_doc_types where key = btrim(coalesce(p_key,'')) and active;
  if not found then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_bad_key'));
  end if;
  if t.required and coalesce(p_skip,true) then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_required_skip'));
  end if;

  if v_kind = 'pharmacy' then
    select zone_id into v_zone from public.pharmacy_profiles where id = v_id;
  else
    select zone_id into v_zone from public.supplier_profiles where id = v_id;
  end if;

  if coalesce(p_skip, true) then
    update public.kyc_documents set status = 'superseded', updated_at = now()
     where owner_kind = v_kind and owner_id = v_id and kind = t.key
       and status in ('pending','submitted','not_available');
    insert into public.kyc_documents(owner_kind, owner_id, kind, path, status,
                                     submitted_by, submitted_at, zone_id, source)
    values (v_kind, v_id, t.key, '', 'not_available', auth.uid(), now(), v_zone, 'app');
  else
    update public.kyc_documents set status = 'superseded', updated_at = now()
     where owner_kind = v_kind and owner_id = v_id and kind = t.key
       and status = 'not_available';
  end if;

  return jsonb_build_object('ok', true, 'tone','info',
    'message', case when coalesce(p_skip,true) then public._c('custdoc.skipped_toast')
                    else public._c('custdoc.unskipped_toast') end,
    'checklist', public.kyc_doc_checklist());
end $function$;

revoke all on function public.kyc_doc_skip(text, boolean) from public, anon;
grant execute on function public.kyc_doc_skip(text, boolean) to authenticated, service_role;

-- ── 6. The upload door speaks the table's vocabulary ──────────────────────
-- Only two things change from CMD #1914's version: which kinds are accepted
-- (the table, not a literal list) and the status a customer's own upload
-- lands in (`submitted`).
create or replace function public.kyc_upload_register(
  p_kind text, p_path text, p_file_name text default null, p_number text default null,
  p_valid_from date default null, p_valid_to date default null,
  p_mime text default null, p_bytes bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text := lower(btrim(coalesce(p_kind,'')));
  v_owner text; v_id uuid; v_zone smallint; v_doc uuid; v_conf jsonb;
  v_status text := 'pending';
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_me->>'reason', 'tone','danger',
      'message', case v_me->>'reason' when 'not_signed_in' then _c('kyc.err_not_signed_in')
                                      else _c('kyc.err_no_owner') end);
  end if;
  -- CMD #1935 — the legacy four stay valid for the supplier surfaces that
  -- still name them; everything else is whatever customer_doc_types collects.
  if v_kind not in ('drug_licence','gst_certificate','shop_photo','pan')
     and not exists (select 1 from public.customer_doc_types where key = v_kind and active) then
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

  if v_kind in ('drug_licence','dl_20b','dl_21b') then
    v_conf := public.kyc_identity_conflict('dl', p_number, v_owner, v_id::text);
  elsif v_kind in ('gst_certificate','gst') then
    v_conf := public.kyc_identity_conflict('gstin', p_number, v_owner, v_id::text);
  else
    v_conf := jsonb_build_object('has', false);
  end if;
  if coalesce((v_conf->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error','duplicate', 'tone','danger',
      'message', v_conf->>'message', 'conflict', v_conf);
  end if;

  if v_owner = 'pharmacy' then
    select zone_id into v_zone from public.pharmacy_profiles where id = v_id;
    v_status := 'submitted';
  else
    select zone_id into v_zone from public.supplier_profiles where id = v_id;
  end if;

  update public.kyc_documents set status = 'superseded', updated_at = now()
   where owner_kind = v_owner and owner_id = v_id and kind = v_kind
     and status in ('pending','submitted','verified','not_available');

  insert into public.kyc_documents(owner_kind, owner_id, kind, path, file_name, mime_type, bytes,
                            number, valid_from, valid_to, status, submitted_by, zone_id, source)
  values (v_owner, v_id, v_kind, btrim(p_path), nullif(btrim(coalesce(p_file_name,'')),''),
          nullif(btrim(coalesce(p_mime,'')),''), p_bytes,
          nullif(btrim(coalesce(p_number,'')),''), p_valid_from, p_valid_to, v_status,
          auth.uid(), v_zone, 'app')
  returning id into v_doc;

  if v_kind in ('drug_licence','dl_20b') then
    if v_owner = 'pharmacy' then
      update public.pharmacy_profiles
         set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
             dl_expiry    = coalesce(p_valid_to, dl_expiry)
       where id = v_id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'doc_id', v_doc, 'kind', v_kind, 'tone','success',
    'message', _c('kyc.upload_ok'), 'state', public.kyc_state(v_owner, v_id));
end $function$;

revoke all on function public.kyc_upload_register(text,text,text,text,date,date,text,bigint) from public, anon;
grant execute on function public.kyc_upload_register(text,text,text,text,date,date,text,bigint) to authenticated, service_role;

-- ── 7. The approval rule reads the same table ─────────────────────────────
-- kyc_state is what customer_approve_gate() and the _kyc_approval_guard
-- trigger already consult, so pointing its required list at
-- customer_doc_types is the whole of "approve only when every required doc is
-- submitted or verified". `not_available` deliberately does NOT satisfy a
-- required row: skipping is only ever offered on optional documents.
create or replace function public.kyc_required_kinds(p_owner_kind text)
returns text[]
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when lower(btrim(coalesce(p_owner_kind,''))) = 'pharmacy'
         and exists (select 1 from public.customer_doc_types where active and required)
      then (select array_agg(key order by sort_order) from public.customer_doc_types
             where active and required)
    else coalesce(
      (select array_agg(x #>> '{}')
         from jsonb_array_elements(
            coalesce((select value->'required_kinds' from public.app_settings where key='kyc_gate'),
                     '["drug_licence"]'::jsonb)) x),
      array['drug_licence'])
  end
$function$;

revoke all on function public.kyc_required_kinds(text) from public, anon;
grant execute on function public.kyc_required_kinds(text) to authenticated, service_role;

-- ── 8. kyc_state, verbatim from CMD #1815 with three edits ───────────────
-- (1) the required list comes from kyc_required_kinds, (2) a customer's own
-- upload (`submitted`) satisfies a requirement exactly as `pending` does, and
-- (3) it reads as pending, not as missing. Nothing else is touched.
create or replace function public.kyc_state(p_owner_kind text, p_owner_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cfg    jsonb := coalesce((select value from app_settings where key='kyc_gate'),
                             '{"grace_days":14,"required_kinds":["drug_licence"],"enforce":true}'::jsonb);
  v_grace  int   := coalesce((v_cfg->>'grace_days')::int, 14);
  -- CMD #1935 — the required list is a TABLE for a customer (customer_doc_types),
  -- and app_settings.kyc_gate for everyone else. Making a document mandatory is
  -- now an UPDATE; this function is what makes that update reach approval.
  v_req    text[]:= public.kyc_required_kinds(p_owner_kind);
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
       and status in ('pending','submitted','verified')
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
    elsif d.status in ('pending','submitted') then
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
$function$;

-- ── 9. OCR autofill for every document that carries a number ──────────────
-- CMD #1889 wrote the read onto the document for drug_licence and nothing
-- else, because drug_licence was the only kind with a number worth having.
-- customer_doc_types.ocr_field now names that field per document, so adding a
-- new numbered document is a row, not a branch in this function.
create or replace function public._kyc_apply_ocr_fields(p_doc_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.kyc_documents%rowtype;
  x public.kyc_doc_extract%rowtype;
  v_field text; v_num text; v_exp date;
  v_did_num boolean := false; v_did_exp boolean := false;
begin
  select * into d from public.kyc_documents where id = p_doc_id;
  if not found then return jsonb_build_object('ok', true, 'applied', false); end if;

  select coalesce(nullif(btrim(ocr_field),''), '') into v_field
    from public.customer_doc_types where key = d.kind;
  if v_field is null or v_field = '' then
    -- The legacy kind keeps its legacy field: this function served it before
    -- customer_doc_types existed and must keep serving it.
    v_field := case when d.kind = 'drug_licence' then 'licence_number' else '' end;
  end if;
  if v_field = '' then return jsonb_build_object('ok', true, 'applied', false); end if;

  select * into x from public.kyc_doc_extract where doc_id = p_doc_id;
  if not found or x.status <> 'done' then
    return jsonb_build_object('ok', true, 'applied', false);
  end if;

  v_num := nullif(btrim(coalesce(x.fields->>v_field,'')),'');
  begin v_exp := nullif(btrim(coalesce(x.fields->>'valid_to','')),'')::date;
  exception when others then v_exp := null; end;

  if v_num is not null and coalesce(btrim(coalesce(d.number,'')),'') = '' then
    update public.kyc_documents set number = v_num, updated_at = now() where id = p_doc_id;
    insert into public.kyc_doc_field_edit(doc_id, owner_kind, owner_id, field, old_value, new_value, source)
    values (p_doc_id, d.owner_kind, d.owner_id, 'number', d.number, v_num, 'ocr');
    v_did_num := true;
  end if;
  if v_exp is not null and d.valid_to is null then
    update public.kyc_documents set valid_to = v_exp, updated_at = now() where id = p_doc_id;
    insert into public.kyc_doc_field_edit(doc_id, owner_kind, owner_id, field, old_value, new_value, source)
    values (p_doc_id, d.owner_kind, d.owner_id, 'valid_to', null, v_exp::text, 'ocr');
    v_did_exp := true;
  end if;

  return jsonb_build_object('ok', true, 'applied', v_did_num or v_did_exp,
                            'number', v_did_num, 'valid_to', v_did_exp);
end $function$;

-- ── 10. The Home banner ───────────────────────────────────────────────────
-- The registration flow is never force-opened. It is ADVERTISED: while the
-- business details or the required documents are still owed, Home carries one
-- line and one button, and the backend decides which sentence and which door.
create or replace function public.customer_registration_banner()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_sess jsonb;
  v_id uuid; v_stage text; v_left int := 0; v_needs_profile boolean := false;
begin
  if auth.uid() is null then
    return jsonb_build_object('show', false);
  end if;
  begin v_sess := public.my_session(); exception when others then v_sess := '{}'::jsonb; end;
  v_needs_profile := coalesce((v_sess->>'needs_profile')::boolean, false);
  v_id := nullif(v_sess->>'customer_id','')::uuid;

  if v_needs_profile or v_id is null then
    -- No pharmacy row behind the account yet: the form is what is owed.
    if not v_needs_profile then return jsonb_build_object('show', false); end if;
    return jsonb_build_object(
      'show', true, 'stage', 'details',
      'title', public._c('custreg.banner_title'),
      'line',  public._c('custreg.banner_details'),
      'cta',   public._c('custreg.banner_cta'),
      'route', '/complete-registration');
  end if;

  select registration_stage::text into v_stage from public.pharmacy_profiles where id = v_id;
  if coalesce(v_stage,'') in ('approved','verified') then
    return jsonb_build_object('show', false);
  end if;

  select count(*) into v_left
    from public.customer_doc_types t
   where t.active and t.required
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = v_id
                        and kd.kind = t.key and kd.status in ('pending','submitted','verified'));

  if v_left = 0 then return jsonb_build_object('show', false); end if;

  return jsonb_build_object(
    'show', true, 'stage', 'documents', 'required_left', v_left,
    'title', public._c('custreg.banner_title'),
    'line',  public._c('custreg.banner_documents'),
    'cta',   public._c('custreg.banner_cta'),
    'route', '/customer/documents');
end $function$;

revoke all on function public.customer_registration_banner() from public, anon;
grant execute on function public.customer_registration_banner() to authenticated, service_role;

-- ── 11. Admin: the checklist itself is editable ───────────────────────────
create or replace function public.customer_doc_types_admin()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_rows jsonb;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('custdoc_admin.denied'),
                              'items', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.key, 'label', t.label, 'hint', t.hint,
           'required', t.required, 'active', t.active,
           'sort_order', t.sort_order, 'ocr_field', t.ocr_field,
           'camera_only', t.accepts_camera_only,
           'requirement_label', case when t.required then public._c('custdoc.required_note')
                                     else public._c('custdoc.optional_note') end
         ) order by t.sort_order), '[]'::jsonb)
    into v_rows from public.customer_doc_types t;

  return jsonb_build_object('ok', true,
    'title', public._c('custdoc_admin.title'),
    'subtitle', public._c('custdoc_admin.subtitle'),
    'required_label', public._c('custdoc_admin.required'),
    'active_label', public._c('custdoc_admin.active'),
    'camera_label', public._c('custdoc_admin.camera_only'),
    'empty_line', public._c('custdoc_admin.empty'),
    'saved_label', public._c('custdoc_admin.saved'),
    'items', v_rows, 'item_count', jsonb_array_length(v_rows));
end $function$;

create or replace function public.customer_doc_type_set(p_key text, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare t public.customer_doc_types%rowtype;
begin
  if not public.is_admin() then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc_admin.denied'));
  end if;
  select * into t from public.customer_doc_types where key = btrim(coalesce(p_key,''));
  if not found then
    return jsonb_build_object('ok', false, 'tone','danger',
                              'message', public._c('custdoc.err_bad_key'));
  end if;

  update public.customer_doc_types set
    required   = coalesce((p_patch->>'required')::boolean, required),
    active     = coalesce((p_patch->>'active')::boolean, active),
    sort_order = coalesce((p_patch->>'sort_order')::int, sort_order),
    label      = coalesce(nullif(btrim(coalesce(p_patch->>'label','')),''), label),
    hint       = coalesce(p_patch->>'hint', hint),
    accepts_camera_only = coalesce((p_patch->>'camera_only')::boolean, accepts_camera_only),
    updated_at = now()
   where key = t.key;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('custdoc_admin.saved'),
    'payload', public.customer_doc_types_admin());
end $function$;

revoke all on function public.customer_doc_types_admin() from public, anon;
revoke all on function public.customer_doc_type_set(text, jsonb) from public, anon;
grant execute on function public.customer_doc_types_admin() to authenticated, service_role;
grant execute on function public.customer_doc_type_set(text, jsonb) to authenticated, service_role;

-- ── 12. The approval refusal names the documents ──────────────────────────
-- customer_approve_gate already asks kyc_gate, which now asks
-- customer_doc_types. What it did not do was NAME the documents that are
-- missing, so an admin read "not verified" and had to go looking.
create or replace function public.customer_docs_missing_sentence(p_customer_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case when count(*) = 0 then ''
              else public._cf('custdoc.approve_blocked',
                     jsonb_build_object('docs', string_agg(t.label, ', ' order by t.sort_order)))
         end
    from public.customer_doc_types t
   where t.active and t.required
     and not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = p_customer_id
                        and kd.kind = t.key and kd.status in ('pending','submitted','verified'));
$function$;

revoke all on function public.customer_docs_missing_sentence(uuid) from public, anon;
grant execute on function public.customer_docs_missing_sentence(uuid) to authenticated, service_role;

create or replace function public.customer_approve_gate(p_customer_id uuid)
returns jsonb
language plpgsql
stable
as $function$
declare v_gate jsonb; v_missing jsonb; v_first jsonb; v_stage public.registration_stage;
        v_docs text;
begin
  select registration_stage into v_stage from public.pharmacy_profiles where id = p_customer_id;
  if v_stage = 'approved' then
    return jsonb_build_object('can', false, 'is_approved', true,
      'label', public.uic('cust_stage.approved','Approved'),
      'reason', '', 'has_fix', false);
  end if;

  v_missing := public.customer_missing_fields(p_customer_id);
  begin
    v_gate := public.kyc_gate('pharmacy', p_customer_id, 'approve');
  exception when others then v_gate := jsonb_build_object('blocked', false);
  end;
  -- CMD #1935 — which documents, by name. The gate knows it is blocked; only
  -- customer_doc_types knows what to call the rows that are missing.
  begin v_docs := public.customer_docs_missing_sentence(p_customer_id);
  exception when others then v_docs := ''; end;

  if coalesce((v_gate->>'blocked')::boolean, false) then
    v_first := (select e from jsonb_array_elements(v_missing) e
                 where e->>'stage_key' = 'documents' limit 1);
    return jsonb_build_object(
      'can', false, 'is_approved', false,
      'label',  public.uic('cust_pipeline.approve_ok','Approve'),
      'reason', coalesce(nullif(v_docs,''),
                         nullif(v_gate->>'message',''), nullif(v_gate->>'warn_message',''),
                         public.customer_missing_sentence(v_missing)),
      'has_fix', v_first is not null,
      'fix_label', public.uic('cust_pipeline.approve_fix','Fix'),
      'fix_field', coalesce(v_first->>'field_key',''),
      'fix_field_label', coalesce(v_first->>'label',''));
  end if;

  if jsonb_array_length(v_missing) > 0 then
    v_first := v_missing->0;
    return jsonb_build_object(
      'can', false, 'is_approved', false,
      'label',  public.uic('cust_pipeline.approve_ok','Approve'),
      'reason', public.customer_missing_sentence(v_missing),
      'has_fix', true,
      'fix_label', public.uic('cust_pipeline.approve_fix','Fix'),
      'fix_field', v_first->>'field_key',
      'fix_field_label', v_first->>'label');
  end if;

  return jsonb_build_object('can', true, 'is_approved', false,
    'label', public.uic('cust_pipeline.approve_ok','Approve'),
    'reason', '', 'has_fix', false);
end $function$;

create or replace function public._kyc_approval_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_kind text; v_gate jsonb; v_docs text := '';
begin
  if coalesce(new.approved,false) is not true then return new; end if;
  if tg_op = 'UPDATE' and coalesce(old.approved,false) is true then return new; end if;
  if coalesce(new.is_synthetic,false) then return new; end if;
  if not coalesce((select (value->>'enforce')::boolean from app_settings where key='kyc_gate'), true)
    then return new; end if;

  v_kind := case tg_table_name when 'pharmacy_profiles' then 'pharmacy' else 'supplier' end;
  v_gate := public.kyc_gate(v_kind, new.id, 'approve');
  if coalesce((v_gate->>'blocked')::boolean, false) then
    -- CMD #1935 — the refusal names the documents when they are a customer's.
    if v_kind = 'pharmacy' then
      begin v_docs := public.customer_docs_missing_sentence(new.id);
      exception when others then v_docs := ''; end;
    end if;
    raise exception using errcode = 'P0001',
            message = coalesce(nullif(v_docs,''), nullif(v_gate->>'message',''), 'kyc_not_verified'),
            detail  = 'kyc_not_verified',
            hint    = 'kyc_gate: '||coalesce(v_gate->'state'->>'state','');
  end if;
  return new;
end $function$;

-- ── 13. The door ──────────────────────────────────────────────────────────
-- Backend without a reachable frontend is half a feature. The admin editor
-- lives on the Customers dashboard category, and the registry is what puts it
-- there; shell_extra_routes.dart maps the route key to the screen.
-- The registry's icon is a foreign key, so the icon exists before the tile does.
insert into public.ui_icon(icon_key, label) values ('fact_check','Fact check')
on conflict (icon_key) do nothing;

insert into public.feature_registry(
  feature_key, label, group_label, icon_key, route_key, sort_order, owner,
  partner_eligible, default_access, is_active, category, surface, roles_allowed,
  deep_link, description, canonical_key, test_entry, test_roles, test_steps,
  test_expect, test_automatable)
values (
  'admin.customer_doc_types', 'Customer documents', 'Customers', 'fact_check',
  'customer_doc_types', 60, 'medibo', false, 'none', true,
  'home_customers', 'dashboard', array['admin','super_admin'],
  '/admin/go/customer_doc_types',
  'CMD #1935 — the document checklist every new customer is asked for. Required, collected and order are rows: a change is live on the customer''s next read, with no deploy.',
  'admin.customer_doc_types', '/admin/go/customer_doc_types',
  array['admin','super_admin'],
  '[{"kind":"auth","role":"{role}"},{"kind":"goto","path":"/admin/go/customer_doc_types"},{"ms":6000,"kind":"settle"}]'::jsonb,
  '{"key":"boot_status","kind":"visible","equals":"painted","source":"render_log"}'::jsonb,
  true)
on conflict (feature_key) do update
  set is_active = true,
      route_key = excluded.route_key,
      deep_link = excluded.deep_link,
      category  = excluded.category,
      surface   = excluded.surface;

-- ── 14. Approve on SUBMITTED, not only on verified ────────────────────────
-- The spec is explicit: "account can be approved only when every required doc
-- is submitted or verified". kyc_gate's approve branch demanded a fully
-- VERIFIED state, so a customer who had uploaded everything still could not be
-- approved until a reviewer had been through it — which is a different rule,
-- and not this one. A pharmacy is now blocked exactly when a required document
-- is missing, rejected or expired; a document waiting for review is not a
-- blocker. Suppliers keep the stricter rule they already had.
create or replace function public.kyc_gate(p_owner_kind text, p_owner_id uuid, p_action text default 'trade')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  st jsonb := public.kyc_state(p_owner_kind, p_owner_id);
  v_state text; v_blocked boolean; v_msg text; v_warn text; v_kind text; v_docs text := '';
begin
  if not coalesce((st->>'ok')::boolean, false) then
    return jsonb_build_object('allowed', true, 'blocked', false, 'reason','unknown_owner',
                              'title','', 'message','', 'warn', false, 'state', st);
  end if;
  v_state := st->>'state';
  v_kind  := lower(btrim(coalesce(p_owner_kind,'')));

  if lower(coalesce(p_action,'trade')) = 'approve' then
    if v_kind = 'pharmacy' then
      v_blocked := coalesce((st->>'enforce')::boolean, true)
                   and v_state not in ('verified','pending');
      begin v_docs := public.customer_docs_missing_sentence(p_owner_id);
      exception when others then v_docs := ''; end;
    else
      v_blocked := coalesce((st->>'enforce')::boolean, true) and v_state <> 'verified';
    end if;
    v_msg := coalesce(nullif(v_docs,''), public._c('kyc_gate.approve_blocked'));
  else
    v_msg := case v_state
               when 'pending'  then public._c('kyc_gate.block_pending')
               when 'rejected' then public._c('kyc_gate.block_rejected')
               when 'expired'  then public._c('kyc_gate.block_expired')
               else public._c('kyc_gate.block_missing') end;
    -- CMD #1815 — a PHARMACY is never blocked from trading by this gate.
    -- Approval decides that, and approval already happened by hand.
    v_blocked := (v_kind <> 'pharmacy')
                 and coalesce((st->>'enforce')::boolean, true)
                 and v_state <> 'verified'
                 and not coalesce((st->>'in_grace')::boolean, false);
  end if;

  v_warn := case v_state
              when 'verified' then ''
              when 'pending'  then public._c('kyc_gate.warn_pending')
              when 'rejected' then public._c('kyc_gate.warn_rejected')
              when 'expired'  then public._c('kyc_gate.warn_expired')
              else public._c('kyc_gate.warn_missing') end;

  return jsonb_build_object(
    'allowed', not v_blocked,
    'blocked', v_blocked,
    'warn',    (v_state <> 'verified'),
    'reason',  case when v_blocked then 'kyc_'||v_state
                    when v_state <> 'verified' then 'warn_'||v_state
                    else 'none' end,
    'title',   case when v_blocked then public._c('kyc_gate.block_title') else '' end,
    'message', case when v_blocked then v_msg else '' end,
    'warn_message', v_warn,
    'action_label', public._c('kyc_gate.action_label'),
    'action_route', public._c('kyc_gate.action_route'),
    'grace_note', '',
    'state', st);
end $function$;

-- ── 15. The OCR queue follows the table too ───────────────────────────────
-- The enqueue trigger named the three legacy kinds, so a dl_20b or an fssai
-- upload was never read at all — the autofill in §9 would have had nothing to
-- apply. A document is queued when customer_doc_types says it carries a number
-- (ocr_field), or when it is one of the legacy three. A skip row
-- (status not_available, no file) is never queued: there is nothing to read.
create or replace function public._kyc_ocr_enqueue()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_key text; v_enabled boolean; v_wanted boolean;
begin
  select ocr_enabled into v_enabled from kyc_verify_config where id = 1;

  if coalesce(new.status,'') = 'not_available'
     or btrim(coalesce(new.path,'')) = '' then
    return new;
  end if;

  v_wanted := new.kind in ('drug_licence','gst_certificate','pan')
              or exists (select 1 from public.customer_doc_types t
                          where t.key = new.kind
                            and btrim(coalesce(t.ocr_field,'')) <> '');
  if not v_wanted then return new; end if;

  insert into kyc_doc_extract(doc_id, owner_kind, owner_id, kind, status)
  values (new.id, new.owner_kind, new.owner_id, new.kind,
          case when coalesce(v_enabled,true) then 'queued' else 'skipped' end)
  on conflict (doc_id) do nothing;

  -- The deterministic half of verification does not wait for a picture: a wrong
  -- checksum or a duplicate licence is refused the moment it is written.
  begin perform public.kyc_verify_doc(new.id, 'upload'); exception when others then null; end;

  if coalesce(v_enabled,true) then
    begin
      select decrypted_secret into v_key from vault.decrypted_secrets
       where name = 'SERVICE_ROLE_KEY' limit 1;
      perform net.http_post(
        url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/kyc-verify',
        headers := jsonb_build_object('Content-Type','application/json',
                     'Authorization', 'Bearer '||coalesce(v_key,'')),
        body := jsonb_build_object('doc_id', new.id));
    exception when others then null;
    end;
  end if;
  return new;
end $function$;
