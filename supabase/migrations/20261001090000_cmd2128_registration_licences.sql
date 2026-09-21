-- CMD #2128 — Registration STEP 3 · Licences.
--
-- Step 3 used to be the same flat document list every other surface draws.
-- The approved design asks for three groups (Needs your attention, Required
-- with a live counter, Optional), a status line per row that names the number
-- that was read, a thumbnail, an upload SHEET with four ways in, and a
-- full-screen in-app viewer. Every one of those is a STRING or a FLAG here:
-- the screen composes nothing, not the counter, not the tick, not the word
-- "pages", not the sheet's own title.
--
-- Nothing about which papers exist changes — custdoc_list(zone) is still the
-- only answer to that, so a document switched Off in Settings is simply
-- absent, and the zone the person belongs to is still the only zone read.

begin;

-- ── 1. copy ────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('custreg.lic_scan_title',    '"Scan a licence"'::jsonb),
  ('custreg.lic_scan_sub',      '"We fill the numbers for you"'::jsonb),
  ('custreg.lic_group_required','"Required"'::jsonb),
  ('custreg.lic_group_optional','"Optional"'::jsonb),
  ('custreg.lic_group_attention','"Needs your attention"'::jsonb),
  ('custreg.lic_counter',       '"{done} of {total} done"'::jsonb),
  ('custreg.lic_uploaded',      '"Uploaded"'::jsonb),
  ('custreg.lic_needed',        '"Needed"'::jsonb),
  ('custreg.lic_added_later',   '"Adding it later"'::jsonb),
  ('custreg.lic_rejected',      '"Rejected — {reason}"'::jsonb),
  ('custreg.lic_rejected_plain','"Rejected — please retake"'::jsonb),
  ('custreg.lic_tap_view',      '"tap to view"'::jsonb),
  ('custreg.lic_pages',         '"{n} pages"'::jsonb),
  ('custreg.lic_tick',          '"✓ "'::jsonb),
  ('custreg.lic_sep',           '" · "'::jsonb),
  ('custreg.lic_dont_have',     '"Don''t have"'::jsonb),
  ('custreg.lic_dont_have_undo','"Undo"'::jsonb),
  ('custreg.lic_footnote',      '"Missing a required paper? Tap \"Don''t have\" — you can still submit and add it later."'::jsonb),
  ('custreg.lic_sheet_title',   '"Add {doc}"'::jsonb),
  ('custreg.lic_sheet_sub',     '"Photo or PDF · clear, all four corners visible"'::jsonb),
  ('custreg.lic_opt_scan',      '"Scan document"'::jsonb),
  ('custreg.lic_opt_scan_sub',  '"Auto-crops and straightens the page"'::jsonb),
  ('custreg.lic_opt_scan_badge','"BEST"'::jsonb),
  ('custreg.lic_opt_camera',    '"Take photo"'::jsonb),
  ('custreg.lic_opt_camera_sub','"Open camera"'::jsonb),
  ('custreg.lic_opt_gallery',   '"Gallery"'::jsonb),
  ('custreg.lic_opt_gallery_sub','"Pick a photo you already have"'::jsonb),
  ('custreg.lic_opt_files',     '"Files"'::jsonb),
  ('custreg.lic_opt_files_sub', '"PDF or image from phone storage"'::jsonb),
  ('custreg.lic_pdf_badge',     '"PDF"'::jsonb),
  ('custreg.lic_view_zoom',     '"Pinch to zoom · uploaded {when}"'::jsonb),
  ('custreg.lic_view_zoom_new', '"Pinch to zoom · not uploaded yet"'::jsonb),
  ('custreg.lic_view_retake',   '"Retake"'::jsonb),
  ('custreg.lic_view_keep',     '"Keep"'::jsonb),
  ('custreg.lic_view_remove',   '"Remove"'::jsonb),
  ('custreg.lic_view_close',    '"Close"'::jsonb),
  ('custreg.lic_view_page',     '"Page {n} of {total}"'::jsonb),
  ('custreg.lic_removed',       '"Removed. You can add it again any time."'::jsonb),
  ('custreg.lic_remove_failed', '"Could not remove that file. Try again."'::jsonb),
  ('custreg.lic_scan_reading',  '"Reading your licence…"'::jsonb),
  ('custreg.lic_scan_review',   '"Check these numbers"'::jsonb),
  ('custreg.lic_scan_line',     '"We read this from your photo. Fix anything that looks wrong."'::jsonb),
  ('custreg.lic_scan_confirm',  '"Use these"'::jsonb),
  ('custreg.lic_scan_cancel',   '"Cancel"'::jsonb),
  ('custreg.lic_scan_none',     '"Could not read that photo. Try again in better light."'::jsonb),
  ('custreg.lic_scan_saved',    '"Saved. Check the boxes above."'::jsonb),
  ('custreg.lic_empty',         '"No papers are asked for in your area."'::jsonb)
on conflict (key) do nothing;

-- ── 2. a page count is a FACT about the file, like its size ────────────────
alter table public.kyc_documents add column if not exists pages int;

-- The old signature is dropped before the new one is created: two overloads
-- that differ only by a defaulted tail are ambiguous to every caller.
drop function if exists public.customer_doc_upload_register(uuid, text, text, text, text, date, text, bigint);

create or replace function public.customer_doc_upload_register(
  p_customer_id uuid, p_kind text, p_path text,
  p_file_name text default null, p_number text default null,
  p_valid_to date default null, p_mime text default null,
  p_bytes bigint default null, p_pages int default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
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
  if not exists (select 1 where coalesce(public.custdoc_mode_for(public.custdoc_zone_for_owner('pharmacy', p_customer_id), v_kind), 'off') <> 'off') then
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

  if not v_self and public.admin_active_zone() is not null
     and coalesce(v_zone, -1) <> public.admin_active_zone() then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('custdoc.err_not_authorized'));
  end if;

  v_source := case when v_self then 'app' else 'partner' end;

  insert into public.kyc_documents(
      owner_kind, owner_id, kind, bucket, path, file_name, mime_type, bytes, pages,
      number, valid_to, status, submitted_by, submitted_at, source, zone_id)
  values ('pharmacy', p_customer_id, v_kind, 'kyc-docs', p_path,
          nullif(btrim(coalesce(p_file_name,'')),''), nullif(btrim(coalesce(p_mime,'')),''),
          p_bytes, nullif(greatest(coalesce(p_pages,0),0),0),
          nullif(btrim(coalesce(p_number,'')),''), p_valid_to,
          v_status, v_uid, now(), v_source, v_zone)
  returning id into v_doc;

  return jsonb_build_object('ok', true, 'doc_id', v_doc, 'tone','success',
    'message', public._c('custdoc.ok_uploaded'));
end $$;

revoke all on function public.customer_doc_upload_register(uuid,text,text,text,text,date,text,bigint,int) from public, anon;
grant execute on function public.customer_doc_upload_register(uuid,text,text,text,text,date,text,bigint,int) to authenticated, service_role;

commit;

-- ── 3. the block the Licences step renders, verbatim ───────────────────────
begin;

create or replace function public.custreg_lic_options()
returns jsonb
language sql stable security definer set search_path to 'public' as $$
  -- The four ways in, in the approved order. `needs` names the platform
  -- capability the option requires; an app that cannot scan drops that one
  -- row and shows the other three — it never rewrites the list.
  select jsonb_build_array(
    jsonb_build_object('key','scan',    'label', public._c('custreg.lic_opt_scan'),
                       'hint', public._c('custreg.lic_opt_scan_sub'),
                       'badge', public._c('custreg.lic_opt_scan_badge'),
                       'icon','scan', 'recommended', true, 'needs','scanner'),
    jsonb_build_object('key','camera',  'label', public._c('custreg.lic_opt_camera'),
                       'hint', public._c('custreg.lic_opt_camera_sub'),
                       'badge','', 'icon','camera', 'recommended', false, 'needs',''),
    jsonb_build_object('key','gallery', 'label', public._c('custreg.lic_opt_gallery'),
                       'hint', public._c('custreg.lic_opt_gallery_sub'),
                       'badge','', 'icon','gallery', 'recommended', false, 'needs',''),
    jsonb_build_object('key','files',   'label', public._c('custreg.lic_opt_files'),
                       'hint', public._c('custreg.lic_opt_files_sub'),
                       'badge','', 'icon','files', 'recommended', false, 'needs','files'));
$$;

create or replace function public.custreg_licences_block(
  p_zone smallint default null, p_owner_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_rows jsonb := '[]'::jsonb;
  v_req_total int := 0;
  v_req_done  int := 0;
  v_opts jsonb := public.custreg_lic_options();
  v_tick text := public._c('custreg.lic_tick');
  v_sep  text := public._c('custreg.lic_sep');
begin
  with types as (
    select l.key, l.label, coalesce(l.hint,'') as hint, l.mode, l.sort_order,
           coalesce(l.camera_only,false) as camera_only, coalesce(l.ocr_field,'') as ocr_field
      from public.custdoc_list(p_zone) l
     where coalesce(l.mode,'off') <> 'off'
  ), latest as (
    select distinct on (d.kind) d.*
      from public.kyc_documents d
     where p_owner_id is not null
       and d.owner_kind = 'pharmacy' and d.owner_id = p_owner_id
     order by d.kind, d.created_at desc
  ), joined as (
    select t.*,
           d.id as doc_id,
           coalesce(d.path,'') as path,
           coalesce(d.bucket,'kyc-docs') as bucket,
           coalesce(d.file_name,'') as file_name,
           coalesce(d.mime_type,'') as mime,
           coalesce(d.number,'') as number,
           coalesce(d.pages, 0) as pages,
           coalesce(d.reason,'') as reason,
           d.submitted_at,
           coalesce(d.status,'') as status,
           (d.id is not null
            and coalesce(d.status,'') <> 'superseded'
            and nullif(btrim(coalesce(d.path,'')),'') is not null) as has_file,
           (coalesce(d.status,'') = 'not_available') as skipped,
           (coalesce(d.status,'') = 'rejected') as rejected
      from types t
      left join latest d on d.kind = t.key
  ), shaped as (
    select j.sort_order as so, j.mode, j.has_file, j.rejected,
      case when j.rejected then 'rejected'
           when j.has_file then 'uploaded'
           when j.skipped  then 'skipped'
           else 'needed' end as state,
      j.key
      from joined j
  )
  select
    coalesce(jsonb_agg(r order by so), '[]'::jsonb),
    count(*) filter (where mode = 'mandatory')::int,
    count(*) filter (where mode = 'mandatory' and state = 'uploaded')::int
    into v_rows, v_req_total, v_req_done
  from (
    select s.so, s.mode, s.state,
      jsonb_build_object(
        'key',       j.key,
        'label',     j.label,
        'hint',      j.hint,
        'required',  (j.mode = 'mandatory'),
        'ocr_field', j.ocr_field,
        'camera_only', j.camera_only,
        -- Which of the three lists this row belongs to. A rejected paper
        -- leaves its list and joins "Needs your attention" — that move is
        -- decided HERE, never by the screen.
        'group',     case when s.state = 'rejected' then 'attention'
                          when j.mode = 'mandatory' then 'required'
                          else 'optional' end,
        'state',     s.state,
        'status_label',
                     case s.state
                       when 'rejected' then
                         case when nullif(btrim(j.reason),'') is null
                              then public._c('custreg.lic_rejected_plain')
                              else public._cf('custreg.lic_rejected',
                                     jsonb_build_object('reason', j.reason)) end
                       when 'uploaded' then
                         v_tick ||
                         case when nullif(btrim(j.number),'') is not null
                              then public._c('custreg.lic_uploaded') || v_sep || j.number
                              when j.pages > 1
                              then public._cf('custreg.lic_pages',
                                     jsonb_build_object('n', j.pages))
                                   || v_sep || public._c('custreg.lic_tap_view')
                              else public._c('custreg.lic_uploaded') || v_sep
                                   || public._c('custreg.lic_tap_view') end
                       when 'skipped' then public._c('custreg.lic_added_later')
                       else public._c('custreg.lic_needed') end,
        'status_tone',
                     case s.state when 'rejected' then 'danger'
                                  when 'uploaded' then 'success'
                                  when 'skipped'  then 'neutral'
                                  else 'warning' end,
        -- The trailing control. One shape, three readings.
        'action',    jsonb_build_object(
                       'kind', case when s.state = 'rejected' then 'retake'
                                    when s.state = 'uploaded' then 'done'
                                    else 'upload' end,
                       'icon', case when s.state = 'rejected' then 'retry'
                                    when s.state = 'uploaded' then 'check'
                                    else 'upload' end,
                       'tone', case when s.state = 'rejected' then 'danger'
                                    when s.state = 'uploaded' then 'success'
                                    else 'brand' end),
        'can_view',  (s.state in ('uploaded','rejected') and j.has_file),
        'thumb',     jsonb_build_object(
                       'kind', case when not j.has_file then 'none'
                                    when j.mime = 'application/pdf'
                                      or lower(right(j.path, 4)) = '.pdf' then 'pdf'
                                    else 'image' end,
                       'bucket', j.bucket,
                       'path',   case when j.has_file then j.path else '' end,
                       'badge',  public._c('custreg.lic_pdf_badge'),
                       'pages',  j.pages),
        'dont_have', jsonb_build_object(
                       'show',  (s.state in ('needed','skipped','rejected')),
                       'on',    (s.state = 'skipped'),
                       'label', public._c('custreg.lic_dont_have'),
                       'undo_label', public._c('custreg.lic_dont_have_undo')),
        -- The sheet is the ROW's, so its title already names the paper.
        'sheet',     jsonb_build_object(
                       'title',    public._cf('custreg.lic_sheet_title',
                                     jsonb_build_object('doc', j.label)),
                       'subtitle', public._c('custreg.lic_sheet_sub'),
                       'options',  v_opts),
        'viewer',    jsonb_build_object(
                       'title',        j.label,
                       'close_label',  public._c('custreg.lic_view_close'),
                       'retake_label', public._c('custreg.lic_view_retake'),
                       'keep_label',   public._c('custreg.lic_view_keep'),
                       'remove_label', public._c('custreg.lic_view_remove'),
                       'hint',         case when j.submitted_at is null
                                            then public._c('custreg.lic_view_zoom_new')
                                            else public._cf('custreg.lic_view_zoom',
                                                   jsonb_build_object('when',
                                                     to_char(j.submitted_at at time zone 'Asia/Kolkata',
                                                             'DD Mon, HH12:MI am'))) end,
                       'page_label',   public._c('custreg.lic_view_page'))
      ) as r
      from shaped s join joined j on j.key = s.key
  ) x;

  return jsonb_build_object(
    'show',      (jsonb_array_length(v_rows) > 0),
    'empty_label', public._c('custreg.lic_empty'),
    'zone_id',   p_zone,
    'scan',      jsonb_build_object(
                   'show',     exists (select 1 from jsonb_array_elements(v_rows) e
                                        where coalesce(e->>'ocr_field','') <> ''),
                   'title',    public._c('custreg.lic_scan_title'),
                   'subtitle', public._c('custreg.lic_scan_sub'),
                   'reading_label', public._c('custreg.lic_scan_reading'),
                   'none_label',    public._c('custreg.lic_scan_none')),
    'groups',    jsonb_build_array(
      jsonb_build_object(
        'key','attention', 'title', public._c('custreg.lic_group_attention'),
        'counter_label','', 'counter_tone','',
        'rows', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_rows) e
                           where e->>'group' = 'attention'), '[]'::jsonb)),
      jsonb_build_object(
        'key','required', 'title', public._c('custreg.lic_group_required'),
        'counter_label', case when v_req_total > 0
                              then public._cf('custreg.lic_counter',
                                     jsonb_build_object('done', v_req_done, 'total', v_req_total))
                              else '' end,
        'counter_tone',  case when v_req_total > 0 and v_req_done >= v_req_total
                              then 'success' else 'warning' end,
        'rows', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_rows) e
                           where e->>'group' = 'required'), '[]'::jsonb)),
      jsonb_build_object(
        'key','optional', 'title', public._c('custreg.lic_group_optional'),
        'counter_label','', 'counter_tone','',
        'rows', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_rows) e
                           where e->>'group' = 'optional'), '[]'::jsonb))),
    'footnote',  public._c('custreg.lic_footnote'),
    'required_total', v_req_total,
    'required_done',  v_req_done);
end $$;

revoke all on function public.custreg_licences_block(smallint, uuid) from public, anon;
grant execute on function public.custreg_licences_block(smallint, uuid) to authenticated, service_role;
revoke all on function public.custreg_lic_options() from public, anon;
grant execute on function public.custreg_lic_options() to authenticated, service_role;

commit;

-- ── 4. the step's own door, and the two writes it needs ────────────────────
begin;

-- The Licences step asks ONE question and gets the whole screen back. It
-- resolves who is in front of it exactly as customer_registration_payload
-- does, so the zone read here is the zone that person belongs to.
create or replace function public.custreg_licences_step()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_sess jsonb;
  v_cid uuid;
  v_zone smallint;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'show', false,
      'message', public._c('custdoc.err_not_signed_in'));
  end if;
  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_cid := nullif(v_sess->>'customer_id','')::uuid;
  if v_cid is not null then
    select zone_id into v_zone from public.pharmacy_profiles where id = v_cid;
  end if;
  if v_zone is null then v_zone := public.admin_active_zone(); end if;
  return jsonb_build_object('ok', true, 'customer_id', v_cid)
         || public.custreg_licences_block(v_zone, v_cid);
end $$;

revoke all on function public.custreg_licences_step() from public, anon;
grant execute on function public.custreg_licences_step() to authenticated, service_role;

-- Remove, from inside the viewer. The paper goes back to "Needed" — the row
-- never disappears, because the zone still asks for it.
create or replace function public.custreg_doc_remove(p_kind text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_sess jsonb; v_cid uuid; v_zone smallint; v_kind text := btrim(coalesce(p_kind,''));
  v_n int := 0;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_not_signed_in'));
  end if;
  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_cid := nullif(v_sess->>'customer_id','')::uuid;
  if v_cid is null then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_no_owner'));
  end if;
  if not exists (select 1 from public.pharmacy_profiles
                  where id = v_cid and user_id = auth.uid()
                    and not coalesce(is_deleted,false)) then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_not_authorized'));
  end if;

  update public.kyc_documents
     set status = 'superseded', updated_at = now()
   where owner_kind = 'pharmacy' and owner_id = v_cid and kind = v_kind
     and coalesce(status,'') in ('pending','submitted','rejected','not_available');
  get diagnostics v_n = row_count;

  select zone_id into v_zone from public.pharmacy_profiles where id = v_cid;
  return jsonb_build_object(
    'ok', (v_n > 0), 'tone', case when v_n > 0 then 'success' else 'danger' end,
    'message', case when v_n > 0 then public._c('custreg.lic_removed')
                    else public._c('custreg.lic_remove_failed') end,
    'block', public.custreg_licences_block(v_zone, v_cid));
end $$;

revoke all on function public.custreg_doc_remove(text) from public, anon;
grant execute on function public.custreg_doc_remove(text) to authenticated, service_role;

commit;

-- ── 5. Scan a licence — what the model read, in the form's own words ───────
begin;

-- The extractor is verbatim-only (licence-ocr, the same Vertex model and the
-- same contract kyc-verify uses). This function is the only place its fields
-- become FORM fields: the mapping, the labels and every caption are SQL.
create or replace function public.custreg_licence_scan_review(p_fields jsonb default '{}'::jsonb)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_f jsonb := coalesce(p_fields, '{}'::jsonb);
  v_vals jsonb := '{}'::jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_lic text := nullif(btrim(coalesce(v_f->>'licence_number','')), '');
  v_20b text := nullif(btrim(coalesce(v_f->>'licence_20b','')), '');
  v_21b text := nullif(btrim(coalesce(v_f->>'licence_21b','')), '');
  v_gst text := nullif(btrim(coalesce(v_f->>'gstin','')), '');
  v_to  text := nullif(btrim(coalesce(v_f->>'valid_to','')), '');
  v_type text := lower(btrim(coalesce(v_f->>'doc_type','')));
begin
  -- A drug licence that names neither form is still a 20B: it is the one
  -- every retail pharmacy holds, and the person confirms it before it lands.
  if v_20b is null and v_lic is not null and v_type in ('drug_licence','dl','licence') then
    v_20b := v_lic;
  end if;

  if v_20b is not null then v_vals := v_vals || jsonb_build_object('dl_20b', v_20b); end if;
  if v_21b is not null then v_vals := v_vals || jsonb_build_object('dl_21b', v_21b); end if;
  if v_gst is not null then v_vals := v_vals || jsonb_build_object('gstin',  v_gst); end if;
  if v_to  is not null then
    begin v_vals := v_vals || jsonb_build_object('dl_expiry', (v_to::date)::text);
    exception when others then null; end;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'field', e.key,
           'label', coalesce(f.label, e.key),
           'value', e.value #>> '{}') order by coalesce(f.sort_order, 999)), '[]'::jsonb)
    into v_rows
    from jsonb_each(v_vals) e
    left join public.customer_form_field f on f.key = e.key;

  return jsonb_build_object(
    'ok',            (jsonb_array_length(v_rows) > 0),
    'title',         public._c('custreg.lic_scan_review'),
    'line',          public._c('custreg.lic_scan_line'),
    'empty_label',   public._c('custreg.lic_scan_none'),
    'confirm_label', public._c('custreg.lic_scan_confirm'),
    'cancel_label',  public._c('custreg.lic_scan_cancel'),
    'confidence',    coalesce(v_f->>'confidence',''),
    'rows',          v_rows,
    'values',        v_vals);
end $$;

revoke all on function public.custreg_licence_scan_review(jsonb) from public, anon;
grant execute on function public.custreg_licence_scan_review(jsonb) to authenticated, service_role;

-- Confirmed. The values are saved with the draft (so a refresh keeps them)
-- and handed back so the boxes on screen fill immediately.
create or replace function public.custreg_licence_scan_apply(p_values jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_in jsonb := coalesce(p_values, '{}'::jsonb);
  v_keep jsonb := '{}'::jsonb;
  k text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'tone','danger',
      'message', public._c('custdoc.err_not_signed_in'));
  end if;
  -- Only the four statutory boxes may be written this way.
  foreach k in array array['dl_20b','dl_21b','gstin','dl_expiry'] loop
    if nullif(btrim(coalesce(v_in->>k,'')),'') is not null then
      v_keep := v_keep || jsonb_build_object(k, btrim(v_in->>k));
    end if;
  end loop;
  if v_keep = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'tone','warning',
      'message', public._c('custreg.lic_scan_none'), 'values', '{}'::jsonb);
  end if;

  begin
    perform public.customer_reg_draft_save(v_keep, 'signup');
  exception when others then null; end;

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('custreg.lic_scan_saved'),
    'values',  v_keep);
end $$;

revoke all on function public.custreg_licence_scan_apply(jsonb) from public, anon;
grant execute on function public.custreg_licence_scan_apply(jsonb) to authenticated, service_role;

commit;
