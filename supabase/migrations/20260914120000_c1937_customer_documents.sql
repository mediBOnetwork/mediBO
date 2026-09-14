-- replay-target: production
-- CMD #1937 — Customer Documents: ONE render-ready payload, three surfaces.
--
-- The KYC backend built by #705/#706/#1889/#1935/#1936 had NO Flutter surface
-- at all: kyc_documents, customer_doc_types, kyc_review_set and
-- customer_approve_gate all worked and nobody could see or tap any of them.
-- This file adds the payload the app renders and the two writes it needs, and
-- nothing else — approve/reject stays kyc_review_set (which already fires
-- kyc_document_rejected over WhatsApp), the account gate stays
-- customer_approve_gate (the #1935 rule).
--
--   customer_documents_screen(p_customer_id)  -- null = my own documents
--   customer_doc_upload_path(p_customer_id, p_kind, p_ext)
--   customer_doc_upload_register(...)          -- admin/partner, source='partner'
--
-- Zone/date scope: a reviewer reads admin_active_zone() / admin_active_date()
-- exactly like kyc_review_queue does, so the picker in the header is the only
-- place scope lives. A partner is pinned to their own zone by
-- admin_active_zone() itself.

-- ════════════════════ 1. copy ════════════════════
-- Every string the three surfaces print. Changing wording is an UPDATE here,
-- never a deploy.
insert into public.ui_copy (key, value) values
  ('custdoc.admin_title',      to_jsonb('Documents'::text)),
  ('custdoc.admin_subtitle',   to_jsonb('Licence and KYC documents for this shop.'::text)),
  ('custdoc.my_title',         to_jsonb('Licence & documents'::text)),
  ('custdoc.my_subtitle',      to_jsonb('We verify these before your account can trade.'::text)),
  ('custdoc.empty',            to_jsonb('No document types are configured yet.'::text)),
  ('custdoc.err_not_authorized', to_jsonb('You do not have access to these documents.'::text)),
  ('custdoc.err_no_customer',  to_jsonb('That shop could not be found in your zone.'::text)),
  ('custdoc.err_not_signed_in', to_jsonb('Sign in to see your documents.'::text)),
  ('custdoc.summary',          to_jsonb('{n} of {total} verified'::text)),
  ('custdoc.summary_missing',  to_jsonb('{docs} missing'::text)),
  ('custdoc.summary_all',      to_jsonb('All documents verified'::text)),
  ('custdoc.summary_sep',      to_jsonb(' · '::text)),
  ('custdoc.approve_account',  to_jsonb('Approve account'::text)),
  ('custdoc.status.skipped',   to_jsonb('Not available'::text)),
  ('custdoc.status.pending',   to_jsonb('Submitted'::text)),
  ('custdoc.status.submitted', to_jsonb('Submitted'::text)),
  ('custdoc.status.verified',  to_jsonb('Verified'::text)),
  ('custdoc.status.rejected',  to_jsonb('Rejected'::text)),
  ('custdoc.status.expired',   to_jsonb('Expired'::text)),
  ('custdoc.number_label',     to_jsonb('No. {n}'::text)),
  ('custdoc.number_none',      to_jsonb('Number not read yet'::text)),
  ('custdoc.valid_till',       to_jsonb('Valid till {d}'::text)),
  ('custdoc.valid_none',       to_jsonb('No expiry recorded'::text)),
  ('custdoc.reason_prefix',    to_jsonb('Rejected: {reason}'::text)),
  ('custdoc.required_note',    to_jsonb('Required'::text)),
  ('custdoc.optional_note',    to_jsonb('Optional'::text)),
  ('custdoc.act_approve',      to_jsonb('Approve'::text)),
  ('custdoc.act_reject',       to_jsonb('Reject'::text)),
  ('custdoc.act_replace',      to_jsonb('Replace'::text)),
  ('custdoc.act_upload',       to_jsonb('Upload'::text)),
  ('custdoc.act_view',         to_jsonb('View'::text)),
  ('custdoc.viewer_title',     to_jsonb('Document'::text)),
  ('custdoc.viewer_close',     to_jsonb('Close'::text)),
  ('custdoc.reject_title',     to_jsonb('Why is it rejected?'::text)),
  ('custdoc.reject_hint',      to_jsonb('The shop sees this sentence, so say what to fix.'::text)),
  ('custdoc.reject_label',     to_jsonb('Reason'::text)),
  ('custdoc.reject_submit',    to_jsonb('Reject document'::text)),
  ('custdoc.reject_cancel',    to_jsonb('Cancel'::text)),
  ('custdoc.upload_title',     to_jsonb('Add {label}'::text)),
  ('custdoc.replace_title',    to_jsonb('Replace {label}'::text)),
  ('custdoc.on_behalf_anon',   to_jsonb('Added at the shop by mediBO staff'::text)),
  ('custdoc.upload_camera',    to_jsonb('Take a photo'::text)),
  ('custdoc.upload_file',      to_jsonb('Choose a file'::text)),
  ('custdoc.upload_number',    to_jsonb('Number printed on it'::text)),
  ('custdoc.upload_valid_to',  to_jsonb('Valid till'::text)),
  ('custdoc.upload_submit',    to_jsonb('Save document'::text)),
  ('custdoc.upload_busy',      to_jsonb('Uploading…'::text)),
  ('custdoc.ok_verified',      to_jsonb('Marked verified.'::text)),
  ('custdoc.ok_rejected',      to_jsonb('Marked rejected. The shop has been told.'::text)),
  ('custdoc.ok_uploaded',      to_jsonb('Document saved.'::text)),
  ('custdoc.err_upload',       to_jsonb('That file could not be saved. Try again.'::text)),
  ('custdoc.err_no_path',      to_jsonb('No file was chosen.'::text)),
  ('custdoc.err_bad_kind',     to_jsonb('That document type is not collected any more.'::text)),
  ('custdoc.retry',            to_jsonb('Retry'::text)),
  ('custdoc.tab_label',        to_jsonb('Documents'::text)),
  ('custdoc.on_behalf_note',   to_jsonb('Added at the shop by {who}'::text))
on conflict (key) do nothing;

-- The five chips of the spec, settled: Missing / Not available / Submitted /
-- Verified / Rejected. #1935 seeded 'missing' as "Not uploaded"; one word for a
-- state reads better beside "Not available", and both surfaces now agree.
insert into public.ui_copy (key, value) values
  ('custdoc.status.missing', to_jsonb('Missing'::text))
on conflict (key) do update set value = excluded.value;

-- The one sentence customer_approve_gate already prints. #1935 seeded it; kept
-- here so a fresh database has it too.
-- #1935 seeded this as "Cannot approve — {docs} not submitted yet." The header
-- summary prints it after "3 of 7 verified · ", where the long form reads as a
-- second sentence. One short clause serves both that strip and the approve
-- gate's own reason, so the wording is settled here rather than re-worded in
-- Dart. Copy, so it is an UPDATE — never a deploy.
insert into public.ui_copy (key, value) values
  ('custdoc.approve_blocked', to_jsonb('{docs} missing'::text))
on conflict (key) do update set value = excluded.value;

-- ════════════════════ 1b. source = partner ════════════════════
-- kyc_documents.source accepted app / token / admin only, so a document the
-- zone partner photographed at the counter was indistinguishable from one the
-- shop uploaded itself. 'partner' is added; every existing value stays legal.
alter table public.kyc_documents drop constraint if exists kyc_documents_source_check;
alter table public.kyc_documents add constraint kyc_documents_source_check
  check (source = any (array['app'::text,'token'::text,'admin'::text,'partner'::text]));

-- ════════════════════ 2. the payload ════════════════════
create or replace function public.customer_documents_screen(p_customer_id uuid default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  v_uid      uuid := auth.uid();
  v_is_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_can_read boolean := public.kyc_can_review('read');
  v_can_write boolean := public.kyc_can_review('write');
  v_zone     int  := public.admin_active_zone();
  v_date     date := public.admin_active_date();
  v_end      timestamptz;
  v_target   uuid;
  v_self     boolean := false;
  v_name     text := '';
  v_cust_zone int;
  v_rows     jsonb;
  v_total    int := 0;
  v_verified int := 0;
  v_missing  text := '';
  v_gate     jsonb;
  v_today    date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in', 'tone','danger',
      'title', public._c('custdoc.admin_title'),
      'message', public._c('custdoc.err_not_signed_in'));
  end if;

  v_end := case when v_date is null then null
                else ((v_date + 1)::timestamp at time zone 'Asia/Kolkata') end;

  -- Who am I looking at? No argument means "me", and that path needs no
  -- reviewer role at all — it is the customer's own My Profile page.
  if p_customer_id is null then
    select id into v_target from public.pharmacy_profiles
     where user_id = v_uid and not coalesce(is_deleted,false) limit 1;
    v_self := v_target is not null;
    if v_target is null then
      return jsonb_build_object('ok', false, 'error','no_owner', 'tone','danger',
        'title', public._c('custdoc.my_title'),
        'message', public._c('custdoc.err_no_customer'));
    end if;
  else
    v_target := p_customer_id;
    select id into v_target from public.pharmacy_profiles
     where id = p_customer_id and user_id = v_uid and not coalesce(is_deleted,false);
    v_self := v_target is not null;
    if not v_self then
      if not v_can_read then
        return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
          'title', public._c('custdoc.admin_title'),
          'message', public._c('custdoc.err_not_authorized'));
      end if;
      v_target := p_customer_id;
    end if;
  end if;

  select coalesce(nullif(btrim(pharmacy_name),''),''), zone_id
    into v_name, v_cust_zone
    from public.pharmacy_profiles where id = v_target;

  if v_name is null then
    return jsonb_build_object('ok', false, 'error','no_customer', 'tone','danger',
      'title', public._c('custdoc.admin_title'),
      'message', public._c('custdoc.err_no_customer'));
  end if;

  -- Zone scope, for a reviewer only. A partner's own zone wins inside
  -- admin_active_zone(); a super admin with no zone picked sees every zone.
  if not v_self and v_zone is not null and coalesce(v_cust_zone, -1) <> v_zone then
    return jsonb_build_object('ok', false, 'error','no_customer', 'tone','danger',
      'title', public._c('custdoc.admin_title'),
      'message', public._c('custdoc.err_no_customer'));
  end if;

  -- One row per configured document type, latest submission attached.
  with types as (
    select t.key, t.label, coalesce(t.hint,'') as hint, t.required,
           t.sort_order, coalesce(t.accepts_camera_only,false) as camera_only
      from public.customer_doc_types t
     where t.active
  ), latest as (
    select distinct on (d.kind) d.*
      from public.kyc_documents d
     where d.owner_kind = 'pharmacy' and d.owner_id = v_target
       and (v_end is null or d.created_at < v_end)
     order by d.kind, d.created_at desc
  ), joined as (
    select ty.*, d.id as doc_id, d.bucket, d.path, d.file_name, d.mime_type,
           d.number, d.valid_to, d.status, d.reason, d.source,
           d.submitted_at, d.verified_at,
           coalesce(
             (select nullif(btrim(split_part(coalesce(u.email,''),'@',1)),'')
                from auth.users u where u.id = d.submitted_by),
             '') as by_name,
           (select nullif(btrim(coalesce(x.fields->>ty.ocr, '')),'')
              from public.kyc_doc_extract x where x.doc_id = d.id) as ocr_val,
           case
             when d.id is null then 'missing'
             when d.status = 'skipped' then 'skipped'
             when d.status = 'verified' and d.valid_to is not null and d.valid_to < v_today then 'expired'
             else d.status end as eff_status
      from (select t.*, tt.ocr_field as ocr from types t
             join public.customer_doc_types tt on tt.key = t.key) ty
      left join latest d on d.kind = ty.key
  )
  select coalesce(jsonb_agg(r order by so), '[]'::jsonb),
         count(*)::int,
         count(*) filter (where eff = 'verified')::int
    into v_rows, v_total, v_verified
  from (
    select j.sort_order as so, j.eff_status as eff,
      jsonb_build_object(
        'kind', j.key,
        'label', j.label,
        'hint', j.hint,
        'required', j.required,
        'requirement_label', case when j.required then public._c('custdoc.required_note')
                                  else public._c('custdoc.optional_note') end,
        'has_file', (j.doc_id is not null and nullif(btrim(coalesce(j.path,'')),'') is not null),
        'doc_id', j.doc_id,
        'bucket', coalesce(j.bucket,'kyc-docs'),
        'path', coalesce(j.path,''),
        'file_name', coalesce(j.file_name,''),
        'is_image', coalesce(j.mime_type,'') like 'image/%',
        'camera_only', j.camera_only,
        'number', coalesce(nullif(btrim(coalesce(j.number,'')),''), coalesce(j.ocr_val,''), ''),
        'number_line', case
            when coalesce(nullif(btrim(coalesce(j.number,'')),''), j.ocr_val) is null
              then case when j.doc_id is null then '' else public._c('custdoc.number_none') end
            else public._cf('custdoc.number_label',
                   jsonb_build_object('n', coalesce(nullif(btrim(coalesce(j.number,'')),''), j.ocr_val))) end,
        'valid_to', j.valid_to,
        'valid_line', case when j.doc_id is null then ''
                           when j.valid_to is null then public._c('custdoc.valid_none')
                           else public._cf('custdoc.valid_till',
                                  jsonb_build_object('d', to_char(j.valid_to,'FMDD Mon YYYY'))) end,
        'status', j.eff_status,
        'status_label', public._c('custdoc.status.'||j.eff_status),
        'status_tone', case j.eff_status
                         when 'verified' then 'success'
                         when 'rejected' then 'danger'
                         when 'expired'  then 'danger'
                         when 'missing'  then case when j.required then 'warning' else 'neutral' end
                         when 'skipped'  then 'neutral'
                         else 'info' end,
        'reason', coalesce(j.reason,''),
        'reason_line', case when j.eff_status = 'rejected' and nullif(btrim(coalesce(j.reason,'')),'') is not null
                            then public._cf('custdoc.reason_prefix',
                                   jsonb_build_object('reason', btrim(j.reason)))
                            else '' end,
        'sheet_title', public._cf(
                         case when j.doc_id is null then 'custdoc.upload_title'
                              else 'custdoc.replace_title' end,
                         jsonb_build_object('label', j.label)),
        -- Who stood at the counter with the camera. A name we cannot resolve
        -- is not a blank line: the shop is still told a person from mediBO
        -- added it, which is the part that matters to them.
        'source_line', case when coalesce(j.source,'') = 'partner'
                            then case when coalesce(j.by_name,'') = ''
                                      then public._c('custdoc.on_behalf_anon')
                                      else public._cf('custdoc.on_behalf_note',
                                             jsonb_build_object('who', j.by_name)) end
                            else '' end,
        -- What THIS viewer may do with THIS row, in the order they are drawn.
        'actions', (
          select coalesce(jsonb_agg(a order by ord), '[]'::jsonb) from (
            select 1 as ord, jsonb_build_object(
                     'key','approve', 'label', public._c('custdoc.act_approve'),
                     'tone','success', 'style','filled') as a
             where v_can_write and not v_self and j.doc_id is not null
               and j.eff_status in ('pending','submitted','rejected','expired')
            union all
            select 2, jsonb_build_object(
                     'key','reject', 'label', public._c('custdoc.act_reject'),
                     'tone','danger', 'style','outlined')
             where v_can_write and not v_self and j.doc_id is not null
               and j.eff_status in ('pending','submitted','verified','expired')
            union all
            select 3, jsonb_build_object(
                     'key','replace', 'label', public._c('custdoc.act_replace'),
                     'tone','neutral', 'style','outlined')
             where j.doc_id is not null and (v_self or (v_can_write and not v_self))
            union all
            select 4, jsonb_build_object(
                     'key','upload', 'label', public._c('custdoc.act_upload'),
                     'tone','brand', 'style','filled')
             where j.doc_id is null and (v_self or (v_can_write and not v_self))
          ) acts)
      ) as r
      from joined j
  ) x;

  begin v_missing := coalesce(public.customer_docs_missing_sentence(v_target), '');
  exception when others then v_missing := ''; end;

  begin v_gate := public.customer_approve_gate(v_target);
  exception when others then v_gate := jsonb_build_object('can', false, 'reason',''); end;

  return jsonb_build_object(
    'ok', true,
    'customer_id', v_target,
    'customer_name', v_name,
    'is_self', v_self,
    'can_review', (v_can_write and not v_self),
    'can_upload', (v_self or (v_can_write and not v_self)),
    'title',    case when v_self then public._c('custdoc.my_title')
                     else public._c('custdoc.admin_title') end,
    'subtitle', case when v_self then public._c('custdoc.my_subtitle')
                     else public._c('custdoc.admin_subtitle') end,
    'tab_label', public._c('custdoc.tab_label'),
    'empty_note', public._c('custdoc.empty'),
    'retry_label', public._c('custdoc.retry'),
    'summary_label', public._cf('custdoc.summary',
                       jsonb_build_object('n', v_verified, 'total', v_total)),
    'summary_detail', case when nullif(v_missing,'') is not null then v_missing
                           when v_total > 0 and v_verified = v_total
                             then public._c('custdoc.summary_all')
                           else '' end,
    'summary_tone', case when nullif(v_missing,'') is not null then 'warning'
                         when v_total > 0 and v_verified = v_total then 'success'
                         else 'info' end,
    'summary_line', public._cf('custdoc.summary',
                       jsonb_build_object('n', v_verified, 'total', v_total))
                     || case
                          when nullif(v_missing,'') is not null
                            then public._c('custdoc.summary_sep') || v_missing
                          when v_total > 0 and v_verified = v_total
                            then public._c('custdoc.summary_sep') || public._c('custdoc.summary_all')
                          else '' end,
    'verified_count', v_verified,
    'total_count', v_total,
    -- The account gate (#1935), with ONE change: its caption. Both
    -- customer_approve_gate and a document row call their button "Approve", and
    -- two buttons reading the same word on one screen — one that verifies a
    -- photo, one that lets a shop trade — is the kind of ambiguity a reviewer
    -- pays for once. The gate's own `reason` is untouched and still verbatim.
    'approve', case when coalesce((v_gate->>'is_approved')::boolean, false)
                    then v_gate
                    else v_gate || jsonb_build_object(
                           'label', public._c('custdoc.approve_account')) end,
    'viewer_title', public._c('custdoc.viewer_title'),
    'viewer_close', public._c('custdoc.viewer_close'),
    'view_label', public._c('custdoc.act_view'),
    'reject_title', public._c('custdoc.reject_title'),
    'reject_hint', public._c('custdoc.reject_hint'),
    'reject_label', public._c('custdoc.reject_label'),
    'reject_submit', public._c('custdoc.reject_submit'),
    'reject_cancel', public._c('custdoc.reject_cancel'),
    'upload_title', public._c('custdoc.upload_title'),
    'upload_camera', public._c('custdoc.upload_camera'),
    'upload_file', public._c('custdoc.upload_file'),
    'upload_number', public._c('custdoc.upload_number'),
    'upload_valid_to', public._c('custdoc.upload_valid_to'),
    'upload_submit', public._c('custdoc.upload_submit'),
    'upload_busy', public._c('custdoc.upload_busy'),
    'rows', v_rows);
end $fn$;

comment on function public.customer_documents_screen(uuid) is
  'CMD #1937 — the ONE render-ready Documents payload. NULL customer = my own (no reviewer role needed); another customer needs kyc_can_review(read) and passes admin_active_zone()/admin_active_date().';

-- ════════════════════ 3. upload on the shop''s behalf ════════════════════
-- The reviewer photographs the licence at the counter. The file goes into the
-- UPLOADER''s storage folder (kyc_docs_owner_write only ever allows that), and
-- the kyc_documents row is stamped source='partner'.
create or replace function public.customer_doc_upload_path(
  p_customer_id uuid, p_kind text, p_ext text default 'jpg')
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  v_uid uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_kind,'')));
  v_ext text := lower(regexp_replace(coalesce(nullif(btrim(p_ext),''),'jpg'), '[^a-z0-9]', '', 'g'));
  v_self boolean;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in', 'tone','danger',
      'message', public._c('custdoc.err_not_signed_in'));
  end if;
  if not exists (select 1 from public.customer_doc_types where key = v_kind and active) then
    return jsonb_build_object('ok', false, 'error','bad_kind', 'tone','danger',
      'message', public._c('custdoc.err_bad_kind'));
  end if;
  v_self := exists (select 1 from public.pharmacy_profiles
                     where id = p_customer_id and user_id = v_uid);
  if not v_self and not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('custdoc.err_not_authorized'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'bucket', 'kyc-docs',
    'path', v_uid::text || '/' || coalesce(p_customer_id::text,'self') || '/' || v_kind
            || '-' || to_char(now(), 'YYYYMMDDHH24MISS') || '.' || coalesce(nullif(v_ext,''),'jpg'));
end $fn$;

comment on function public.customer_doc_upload_path(uuid, text, text) is
  'CMD #1937 — where the app PUTs the file. Always under the uploader''s own uid folder, which is the only shape kyc_docs_owner_write accepts.';

create or replace function public.customer_doc_upload_register(
  p_customer_id uuid,
  p_kind text,
  p_path text,
  p_file_name text default null,
  p_number text default null,
  p_valid_to date default null,
  p_mime text default null,
  p_bytes bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_uid uuid := auth.uid();
  v_kind text := lower(btrim(coalesce(p_kind,'')));
  v_self boolean;
  v_zone smallint;
  v_doc uuid;
  v_source text;
  v_status text := 'submitted';
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in', 'tone','danger',
      'message', public._c('custdoc.err_not_signed_in'));
  end if;
  if nullif(btrim(coalesce(p_path,'')),'') is null then
    return jsonb_build_object('ok', false, 'error','no_path', 'tone','danger',
      'message', public._c('custdoc.err_no_path'));
  end if;
  if not exists (select 1 from public.customer_doc_types where key = v_kind and active) then
    return jsonb_build_object('ok', false, 'error','bad_kind', 'tone','danger',
      'message', public._c('custdoc.err_bad_kind'));
  end if;

  v_self := exists (select 1 from public.pharmacy_profiles
                     where id = p_customer_id and user_id = v_uid
                       and not coalesce(is_deleted,false));
  if not v_self and not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('custdoc.err_not_authorized'));
  end if;

  select zone_id into v_zone from public.pharmacy_profiles where id = p_customer_id;
  if v_zone is null and not v_self then
    return jsonb_build_object('ok', false, 'error','no_customer', 'tone','danger',
      'message', public._c('custdoc.err_no_customer'));
  end if;

  -- A reviewer may only write into their own zone, exactly as kyc_review_set
  -- refuses a document outside it.
  if not v_self and public.admin_active_zone() is not null
     and coalesce(v_zone, -1) <> public.admin_active_zone() then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('custdoc.err_not_authorized'));
  end if;

  v_source := case when v_self then 'app' else 'partner' end;

  insert into public.kyc_documents(
      owner_kind, owner_id, kind, bucket, path, file_name, mime_type, bytes,
      number, valid_to, status, submitted_by, submitted_at, source, zone_id)
  values ('pharmacy', p_customer_id, v_kind, 'kyc-docs', p_path,
          nullif(btrim(coalesce(p_file_name,'')),''), nullif(btrim(coalesce(p_mime,'')),''),
          p_bytes, nullif(btrim(coalesce(p_number,'')),''), p_valid_to,
          v_status, v_uid, now(), v_source, v_zone)
  returning id into v_doc;

  return jsonb_build_object('ok', true, 'doc_id', v_doc, 'tone','success',
    'message', public._c('custdoc.ok_uploaded'));
end $fn$;

comment on function public.customer_doc_upload_register(uuid, text, text, text, text, date, text, bigint) is
  'CMD #1937 — records a document the reviewer captured at the counter (source=partner) or the shop uploaded itself (source=self). Approve/reject stays kyc_review_set.';

-- ════════════════════ 4. a reviewer may read the file ════════════════════
-- kyc_docs_owner_read only ever allowed the owner and get_my_role() in
-- (admin, super_admin) — so a zone partner with partner.kyc_review could
-- approve a document they were unable to LOOK at. The policy now names the
-- same capability the review RPC does. It is a widening for reviewers only;
-- every other caller is refused exactly as before.
drop policy if exists kyc_docs_owner_read on storage.objects;
create policy kyc_docs_owner_read on storage.objects
  for select to authenticated
  using (bucket_id = 'kyc-docs'
         and ((storage.foldername(name))[1] = auth.uid()::text
              or public.get_my_role() in ('admin','super_admin')
              or public.kyc_can_review('read')));

-- ════════════════════ 5. grants ════════════════════
-- Nothing here is public: every function reads auth.uid() and refuses without
-- one, and anon is revoked explicitly so a future default grant cannot leak it.
revoke all on function public.customer_documents_screen(uuid) from public, anon;
revoke all on function public.customer_doc_upload_path(uuid, text, text) from public, anon;
revoke all on function public.customer_doc_upload_register(uuid, text, text, text, text, date, text, bigint) from public, anon;
grant execute on function public.customer_documents_screen(uuid) to authenticated;
grant execute on function public.customer_doc_upload_path(uuid, text, text) to authenticated;
grant execute on function public.customer_doc_upload_register(uuid, text, text, text, text, date, text, bigint) to authenticated;

-- ════════════════════ 6. the tab, on both pages ════════════════════
-- admin_customer_tab is the registry BOTH customer pages read: `label`/`rpc`/
-- `sort_order` for the page an admin or a zone partner opens, and `cust_label`/
-- `cust_rpc`/`cust_sort` for the shop's own My Account. One row therefore puts
-- Documents on both, pointing at the same payload — which is the whole point of
-- spec item 5: a status word cannot read one way for the reviewer and another
-- for the shop.
--
-- sort_order 18 sits it straight after Profile & KYC (15), where a reviewer
-- looks next. feature_key partner.kyc_review is what makes the tab appear for a
-- zone partner who holds that capability and stay hidden for one who does not —
-- the same capability kyc_can_review() and the RPC itself check.
insert into public.admin_customer_tab
  (tab_key, label, feature_key, sort_order, icon_key, audience,
   rpc, cust_label, cust_rpc, cust_sort, is_active)
values
  ('documents', 'Documents', 'partner.kyc_review', 18, 'folder',
   array['admin','customer']::text[],
   'customer_documents_screen', 'Licence & documents',
   'customer_documents_screen', 20, true)
on conflict (tab_key) do update
  set label       = excluded.label,
      feature_key = excluded.feature_key,
      sort_order  = excluded.sort_order,
      icon_key    = coalesce(nullif(admin_customer_tab.icon_key,''), excluded.icon_key),
      audience    = (select array_agg(distinct a order by a)
                       from unnest(coalesce(admin_customer_tab.audience, '{}'::text[])
                                   || array['admin','customer']::text[]) a),
      rpc         = excluded.rpc,
      cust_label  = coalesce(nullif(admin_customer_tab.cust_label,''), excluded.cust_label),
      cust_rpc    = excluded.cust_rpc,
      cust_sort   = coalesce(admin_customer_tab.cust_sort, excluded.cust_sort),
      is_active   = true;
