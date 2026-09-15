-- CMD #2061 — ONE registration form.
--
-- Registration was two screens: /complete-registration filled the business
-- details, then /customer/documents asked for the licences. A shop that got
-- through the first screen and closed the app was "registered" with no papers
-- behind it, and the Customer-documents rules #2060 added — Mandatory /
-- Optional / Off, per zone — reached neither screen.
--
-- Now there is ONE form. The documents live INSIDE it, drawn from
-- custdoc_list(zone), so an admin flipping a document to Mandatory in
-- Settings changes what the next signup sees with no deploy. Self-signup and
-- an imported customer open the SAME form; the imported one arrives with its
-- row already in the fields and fills only what is blank.
--
-- Skipping a mandatory document never blocks Submit. The profile saves, the
-- account lands in "Docs pending", it cannot be approved until the paper
-- arrives, and the #1936 reminder ladder keeps asking.
--
-- Idempotent: create-or-replace everywhere, ui_copy ON CONFLICT DO NOTHING so
-- live wording is never reset.

-- ── 1. The customer form loses three admin-side settings ────────────────────
-- Other contact, Delivery range and Payment term are decided by the office,
-- not typed by the shop. They stay on the admin form; they leave the signup
-- context. This is DATA, so putting one back is an UPDATE.
update public.customer_form_field
   set contexts = array_remove(contexts, 'signup')
 where key in ('other_contact_no', 'range_zone', 'payment_term')
   and 'signup' = any (contexts);

-- A field left with no context at all would vanish from the admin form too.
update public.customer_form_field
   set contexts = array['admin']
 where key in ('other_contact_no', 'range_zone', 'payment_term')
   and coalesce(array_length(contexts, 1), 0) = 0;

-- ── 2. Copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('custreg.form_title',        '"Register your pharmacy"'::jsonb),
  ('custreg.form_subtitle',     '"One form. Fill what applies and submit — you can add papers later."'::jsonb),
  ('custreg.submit_label',      '"Submit registration"'::jsonb),
  ('custreg.submitting_label',  '"Submitting…"'::jsonb),
  ('custreg.saved_message',     '"Registration submitted."'::jsonb),
  ('custreg.imported_note',     '"We already have your shop on file — check what is here and fill in the rest."'::jsonb),
  ('custreg.docs_title',        '"Documents"'::jsonb),
  ('custreg.docs_subtitle',     '"Starred papers are needed before your account can be approved."'::jsonb),
  ('custreg.docs_none',         '"No documents are needed in your area."'::jsonb),
  ('custreg.doc_upload',        '"Upload"'::jsonb),
  ('custreg.doc_replace',       '"Replace"'::jsonb),
  ('custreg.doc_skip',          '"I don''t have this"'::jsonb),
  ('custreg.doc_skipped',       '"You said you don''t have this"'::jsonb),
  ('custreg.doc_undo_skip',     '"Undo"'::jsonb),
  ('custreg.doc_required_star', '" *"'::jsonb),
  ('custreg.doc_required_note', '"Required"'::jsonb),
  ('custreg.doc_optional_note', '"Optional"'::jsonb),
  ('custreg.doc_uploaded',      '"Added"'::jsonb),
  ('custreg.docs_skip_note',    '"Skipping a starred paper is fine — you can submit now and add it later."'::jsonb),
  ('custreg.pending_title',     '"Docs pending"'::jsonb),
  ('custreg.pending_line',      '"Docs pending: {docs}"'::jsonb),
  ('custreg.pending_cta',       '"Resume"'::jsonb),
  ('custreg.pending_done',      '"All your documents are in."'::jsonb),
  ('custreg.err_not_signed_in', '"Sign in first."'::jsonb),
  ('custreg.err_no_values',     '"Fill the form before submitting."'::jsonb),
  ('custreg.err_save',          '"We could not save that. Try once more."'::jsonb),
  ('custreg.retry',             '"Try again"'::jsonb),
  ('custreg.close_label',       '"Close"'::jsonb),
  ('custreg.done_title',        '"You are registered"'::jsonb),
  ('custreg.done_line',         '"Nothing else is pending."'::jsonb),
  ('custdoc.status.not_available', '"Not available"'::jsonb),
  ('cust_pipeline.col_docs',    '"Documents"'::jsonb),
  ('cust_pipeline.docs_ok',     '"All in"'::jsonb),
  ('cust_pipeline.docs_missing', '"Missing: {docs}"'::jsonb),
  ('cust_pipeline.approve_blocked_docs', '"Cannot approve — missing {docs}."'::jsonb)
on conflict (key) do nothing;

-- ── 3. The documents section, as a payload ──────────────────────────────────
-- ONE function draws the block for every surface that shows it: the signup
-- form, the imported-customer form, and the standalone documents page. It
-- reads custdoc_list(zone) — so Off is absent, Optional is a plain card and
-- Mandatory is the same card with a star — and attaches whatever the owner
-- has already sent. An owner that does not exist yet (a brand new signup) is
-- simply an owner with nothing attached.
create or replace function public.custdoc_form_block(
  p_zone smallint default null,
  p_owner_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_rows jsonb;
  v_req  int := 0;
  v_left int := 0;
begin
  with types as (
    select l.key, l.label, coalesce(l.hint,'') as hint, l.mode,
           l.sort_order, coalesce(l.camera_only,false) as camera_only
      from public.custdoc_list(p_zone) l
     where coalesce(l.mode,'off') <> 'off'
  ), latest as (
    select distinct on (d.kind) d.*
      from public.kyc_documents d
     where p_owner_id is not null
       and d.owner_kind = 'pharmacy' and d.owner_id = p_owner_id
     order by d.kind, d.created_at desc
  ), joined as (
    select t.*, d.id as doc_id, coalesce(d.path,'') as path,
           coalesce(d.file_name,'') as file_name, d.status,
           (d.id is not null and nullif(btrim(coalesce(d.path,'')),'') is not null) as has_file,
           (coalesce(d.status,'') = 'not_available') as skipped
      from types t
      left join latest d on d.kind = t.key
  )
  select coalesce(jsonb_agg(r order by so), '[]'::jsonb),
         count(*) filter (where mode = 'mandatory')::int,
         count(*) filter (where mode = 'mandatory'
                            and not coalesce(status,'') = any (array['pending','submitted','verified']))::int
    into v_rows, v_req, v_left
  from (
    select j.sort_order as so, j.mode, j.status,
      jsonb_build_object(
        'key',            j.key,
        'label',          j.label,
        'hint',           j.hint,
        'mode',           j.mode,
        'required',       (j.mode = 'mandatory'),
        -- The star is a STRING the backend sends, not a character Dart adds.
        'star',           case when j.mode = 'mandatory'
                               then public._c('custreg.doc_required_star') else '' end,
        'requirement_label', case when j.mode = 'mandatory'
                                  then public._c('custreg.doc_required_note')
                                  else public._c('custreg.doc_optional_note') end,
        'requirement_tone', case when j.mode = 'mandatory' then 'warning' else 'neutral' end,
        'camera_only',    j.camera_only,
        'has_file',       j.has_file,
        'file_name',      j.file_name,
        'skipped',        j.skipped,
        'state',          case when j.has_file then 'uploaded'
                               when j.skipped  then 'skipped'
                               else 'empty' end,
        'state_label',    case when j.has_file then public._c('custreg.doc_uploaded')
                               when j.skipped  then public._c('custreg.doc_skipped')
                               else '' end,
        'state_tone',     case when j.has_file then 'success'
                               when j.skipped  then 'neutral'
                               else 'neutral' end,
        -- Both words for both buttons, always. The card flips between them
        -- on what the person just tapped, and never composes one itself.
        'upload_label',   case when j.has_file then public._c('custreg.doc_replace')
                               else public._c('custreg.doc_upload') end,
        'add_label',      public._c('custreg.doc_upload'),
        'replace_label',  public._c('custreg.doc_replace'),
        'skip_label',     public._c('custreg.doc_skip'),
        'undo_label',     public._c('custreg.doc_undo_skip'),
        'bucket',         'kyc-docs'
      ) as r
    from joined j
  ) x;

  return jsonb_build_object(
    'show',        (jsonb_array_length(coalesce(v_rows,'[]'::jsonb)) > 0),
    'title',       public._c('custreg.docs_title'),
    'subtitle',    public._c('custreg.docs_subtitle'),
    'empty_label', public._c('custreg.docs_none'),
    'skip_note',   public._c('custreg.docs_skip_note'),
    'zone_id',     p_zone,
    'required_count', v_req,
    'required_left',  v_left,
    'rows',        coalesce(v_rows, '[]'::jsonb));
end $function$;

revoke all on function public.custdoc_form_block(smallint, uuid) from public, anon;
grant execute on function public.custdoc_form_block(smallint, uuid) to authenticated, service_role;

-- ── 4. Missing mandatory documents count as missing registration fields ─────
-- customers_needs_attention, customer_approve_gate and the Fix button all read
-- customer_missing_fields(). Adding the documents here is what puts a
-- docs-pending shop on the admin's list and keeps it off the approve path,
-- with one list of names that every surface prints verbatim.
create or replace function public.customer_missing_fields(p_customer_id uuid)
returns jsonb
language sql
stable
as $function$
  select coalesce(jsonb_agg(e order by ord, lbl), '[]'::jsonb) from (
    -- the profile fields, exactly as before
    select f.sort_order as ord, f.label as lbl,
           jsonb_build_object('field_key', f.field_key, 'label', f.label,
                              'stage_key', f.stage_key) as e
      from public.customer_required_field f
      join public.pharmacy_profiles pp on pp.id = p_customer_id
     where f.is_active
       and case f.field_key
         when 'pharmacy_name' then nullif(btrim(coalesce(pp.pharmacy_name,'')),'') is null
         when 'owner_name'    then nullif(btrim(coalesce(pp.owner_name, pp.customer_name,'')),'') is null
         when 'phone'         then nullif(btrim(coalesce(nullif(btrim(coalesce(pp.phone,'')),''),
                                                         pp.whatsapp_no,'')),'') is null
         when 'address'       then nullif(btrim(coalesce(nullif(btrim(coalesce(pp.address,'')),''),
                                                         pp.address_local,'')),'') is null
         when 'city'          then nullif(btrim(coalesce(pp.city,'')),'') is null
         when 'pincode'       then nullif(btrim(coalesce(pp.pincode,'')),'') is null
         when 'zone_id'       then pp.zone_id is null
         when 'drug_license'  then nullif(btrim(coalesce(nullif(btrim(coalesce(pp.drug_license,'')),''),
                                                         pp.dl_20b, pp.dl_21b,'')),'') is null
         when 'gstin'         then nullif(btrim(coalesce(nullif(btrim(coalesce(pp.gstin,'')),''),
                                                         pp.gst_no,'')),'') is null
         when 'dl_expiry'     then pp.dl_expiry is null
         else false end
    union all
    -- CMD #2061 — every MANDATORY document with nothing usable behind it. The
    -- key is namespaced so a document can never collide with a column name,
    -- and the stage is 'documents', which is the stage the Fix button opens.
    select 1000 + t.sort_order, t.label,
           jsonb_build_object('field_key', 'doc:' || t.key, 'label', t.label,
                              'stage_key', 'documents')
      from public.custdoc_list(public.custdoc_zone_for_owner('pharmacy', p_customer_id)) t
     where t.mode = 'mandatory'
       and not exists (select 1 from public.kyc_documents kd
                        where kd.owner_kind = 'pharmacy' and kd.owner_id = p_customer_id
                          and kd.kind = t.key
                          and kd.status in ('pending','submitted','verified'))
  ) s;
$function$;

-- ── 5. The whole registration surface, in ONE payload ───────────────────────
-- No steps. One form, one submit, the documents inside it. `stage` is only
-- ever 'form' (still owed) or 'done'.
create or replace function public.customer_registration_payload()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_sess jsonb; v_needs_profile boolean := false; v_cid uuid;
  v_stage text; v_zone smallint;
  v_schema jsonb := '{}'::jsonb; v_draft jsonb := '{}'::jsonb;
  v_map jsonb; v_pre jsonb := '{}'::jsonb; v_u record; v_row record;
  v_docs jsonb; v_route text; v_needs boolean;
  v_missing text := ''; v_imported boolean := false;
begin
  if auth.uid() is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', false);
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_needs_profile := coalesce((v_sess->>'needs_profile')::boolean, false);
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  -- Staff and suppliers are not half-registered pharmacies.
  if not v_needs_profile and v_cid is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', true);
  end if;

  v_route := coalesce(public.login_signup_cfg()->>'signup_form_route',
                      public.login_signup_cfg()->>'signup_route',
                      '/complete-registration');

  begin v_schema := public.customer_form_schema('signup');
  exception when others then v_schema := '{}'::jsonb; end;
  v_draft := public.customer_reg_draft_get('signup');

  -- Who is in front of us. An imported shop already has its row: every value
  -- on it becomes a prefill, so the person fills only what is blank.
  if v_cid is not null then
    select registration_stage::text as stage, zone_id,
           pharmacy_name, coalesce(owner_name, customer_name) as owner_name,
           phone, whatsapp_no, email, coalesce(address, address_local) as address,
           city, district, state, pincode, store_type, store_location_link,
           coalesce(gstin, gst_no) as gstin, dl_20b, dl_21b, dl_expiry,
           coalesce(drug_license,'') as drug_license, source
      into v_row
      from public.pharmacy_profiles where id = v_cid;
    v_stage := v_row.stage;
    v_zone  := v_row.zone_id;
    v_imported := coalesce(lower(btrim(coalesce(v_row.source,''))) in ('import','admin','admin_import'), false);
    v_pre := jsonb_strip_nulls(jsonb_build_object(
      'pharmacy_name',       nullif(btrim(coalesce(v_row.pharmacy_name,'')),''),
      'customer_name',       nullif(btrim(coalesce(v_row.owner_name,'')),''),
      'phone',               nullif(btrim(coalesce(v_row.phone,'')),''),
      'whatsapp_no',         nullif(btrim(coalesce(v_row.whatsapp_no,'')),''),
      'email',               nullif(btrim(coalesce(v_row.email,'')),''),
      'address',             nullif(btrim(coalesce(v_row.address,'')),''),
      'city',                nullif(btrim(coalesce(v_row.city,'')),''),
      'district',            nullif(btrim(coalesce(v_row.district,'')),''),
      'state',               nullif(btrim(coalesce(v_row.state,'')),''),
      'pincode',             nullif(btrim(coalesce(v_row.pincode,'')),''),
      'store_type',          nullif(btrim(coalesce(v_row.store_type,'')),''),
      'store_location_link', nullif(btrim(coalesce(v_row.store_location_link,'')),''),
      'gstin',               nullif(btrim(coalesce(v_row.gstin,'')),''),
      'dl_20b',              nullif(btrim(coalesce(v_row.dl_20b, v_row.drug_license,'')),''),
      'dl_21b',              nullif(btrim(coalesce(v_row.dl_21b,'')),''),
      'dl_expiry',           case when v_row.dl_expiry is null then null
                                  else to_char(v_row.dl_expiry,'YYYY-MM-DD') end));
  else
    -- Brand-new signup: the only thing known is the identity they logged in
    -- with, and WHICH field each identity value lands in is data.
    v_map := coalesce((select value from public.app_settings where key = 'signup_prefill_map'),
                      jsonb_build_object('name','customer_name','email','email','whatsapp','whatsapp_no'));
    select coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name','')),''),
                    nullif(btrim(coalesce(u.raw_user_meta_data->>'name','')),''),
                    '') as nm,
           case when lower(coalesce(u.email,'')) like
                     ('%@' || coalesce(public.login_signup_cfg()->>'internal_email_domain','wa.medibo.in'))
                then '' else coalesce(u.email,'') end as em,
           coalesce(nullif(right(regexp_replace(coalesce(u.phone,''),'\D','','g'),10),''),
                    coalesce(u.raw_user_meta_data->>'phone','')) as ph
      into v_u
      from auth.users u where u.id = auth.uid();
    v_pre := jsonb_strip_nulls(jsonb_build_object(
      coalesce(v_map->>'name','customer_name'),   nullif(coalesce(v_u.nm,''),''),
      coalesce(v_map->>'email','email'),          nullif(coalesce(v_u.em,''),''),
      coalesce(v_map->>'whatsapp','whatsapp_no'), nullif(coalesce(v_u.ph,''),'')));
    v_zone := public.admin_active_zone();
  end if;

  v_docs := public.custdoc_form_block(v_zone, v_cid);

  if v_cid is not null then
    begin v_missing := coalesce(public.customer_docs_missing_labels(v_cid), '');
    exception when others then v_missing := ''; end;
  end if;

  -- Owed while there is no profile at all, or while a mandatory paper is out.
  v_needs := (v_cid is null)
             or coalesce(v_needs_profile, false)
             or (coalesce(v_stage,'') not in ('approved','verified') and v_missing <> '');

  return jsonb_build_object(
    'signed_in',   true,
    'needs',       v_needs,
    -- CMD #2061 — one form. 'documents' is no longer a stage of its own.
    'stage',       case when v_needs then 'form' else 'done' end,
    'route',       v_route,
    'customer_id', v_cid,
    'title',       public._c('custreg.form_title'),
    'subtitle',    public._c('custreg.form_subtitle'),
    'submit_label',     public._c('custreg.submit_label'),
    'submitting_label', public._c('custreg.submitting_label'),
    'error_label',      public._c('custreg.err_save'),
    'retry_label',      public._c('custreg.retry'),
    'close_label',      public._c('custreg.close_label'),
    'done_title',       public._c('custreg.done_title'),
    'done_line',        public._c('custreg.done_line'),
    'imported',    jsonb_build_object(
                     'is',   v_imported,
                     'note', case when v_imported then public._c('custreg.imported_note') else '' end),
    'schema',      v_schema,
    'prefill',     v_pre,
    'draft',       v_draft,
    'has_draft',   (v_draft <> '{}'::jsonb),
    'draft_note',  case when v_draft <> '{}'::jsonb then public._c('custreg.draft_resumed') else '' end,
    'autosave',    jsonb_build_object(
                     'enabled', true, 'debounce_ms', 800,
                     'saving_label', public._c('custreg.draft_saving'),
                     'saved_label',  public._c('custreg.draft_saved')),
    'documents',   v_docs,
    -- The one line the customer sees once a starred paper was skipped.
    'docs_pending', jsonb_build_object(
                     'show',  (v_missing <> ''),
                     'title', public._c('custreg.pending_title'),
                     'line',  case when v_missing = '' then public._c('custreg.pending_done')
                                   else public._cf('custreg.pending_line',
                                          jsonb_build_object('docs', v_missing)) end,
                     'docs',  v_missing,
                     'cta',   public._c('custreg.pending_cta'),
                     'route', v_route,
                     'anchor','documents',
                     'tone',  case when v_missing = '' then 'success' else 'warning' end),
    -- Kept so anything still reading the old shape renders nothing rather
    -- than throwing. There are no steps any more.
    'steps',       '[]'::jsonb,
    'step',        jsonb_build_object('n', 1, 'total', 1, 'done', case when v_needs then 0 else 1 end,
                                      'label', '', 'progress_label', '', 'ratio', 0),
    'required_left', coalesce((v_docs->>'required_left')::int, 0),
    'sheet', jsonb_build_object(
               'title',        public._c('custreg.sheet_title'),
               'line',         public._c('custreg.sheet_line'),
               'close_label',  public._c('custreg.sheet_close'),
               'done_message', public._c('custreg.sheet_done')));
end $function$;

-- ── 6. The banner: Docs pending: <names>, with Resume ───────────────────────
create or replace function public.customer_registration_banner()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_reg jsonb; v_pend jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('show', false); end if;
  v_reg := public.customer_registration_payload();
  if coalesce((v_reg->>'needs')::boolean, false) is not true then
    return jsonb_build_object('show', false);
  end if;
  v_pend := coalesce(v_reg->'docs_pending', '{}'::jsonb);

  -- Two banners, one shape. A shop with no profile is asked to register; a
  -- shop that registered and skipped a starred paper is told exactly which
  -- paper, and Resume reopens the form at the documents section.
  if coalesce((v_pend->>'show')::boolean, false) then
    return jsonb_build_object(
      'show',  true,
      'stage', 'documents',
      'tone',  'warning',
      'title', v_pend->>'title',
      'line',  v_pend->>'line',
      'docs',  v_pend->>'docs',
      'cta',   v_pend->>'cta',
      'route', v_pend->>'route',
      'anchor', v_pend->>'anchor',
      'required_left', coalesce((v_reg->>'required_left')::int, 0),
      'steps', '[]'::jsonb, 'step', '{}'::jsonb);
  end if;

  return jsonb_build_object(
    'show',  true,
    'stage', 'form',
    'tone',  'info',
    'title', public._c('custreg.banner_title'),
    'line',  public._c('custreg.banner_details'),
    'docs',  '',
    'cta',   public._c('custreg.banner_cta'),
    'route', v_reg->>'route',
    'anchor', '',
    'required_left', coalesce((v_reg->>'required_left')::int, 0),
    'steps', '[]'::jsonb, 'step', '{}'::jsonb);
end $function$;

-- ── 7. ONE Submit — profile, documents and skips in a single call ───────────
-- p_values is the form's own map (only keys the schema listed).
-- p_skips  is ["dl_20b", …] — the papers the person said they do not have.
-- Uploads have already registered themselves through
-- customer_doc_upload_register; this call is what makes them, the profile and
-- the skips one atomic answer.
create or replace function public.customer_registration_submit(
  p_values jsonb default '{}'::jsonb,
  p_skips  jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_cid uuid;
  v_sess jsonb;
  v_allowed text[] := array['pharmacy_name','customer_name','owner_name','phone','whatsapp_no',
                            'other_contact_no','email','address','address_local','city','district',
                            'state','pincode','gstin','gst_no','drug_license','dl_20b','dl_21b',
                            'dl_expiry','store_type','store_location_link','latitude','longitude'];
  v_key text; v_sets text[] := '{}'; v_rejected text[] := '{}';
  v_sub jsonb; v_skip text; v_zone smallint;
  v_missing text := ''; v_stage public.registration_stage;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object' or p_values = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','no_values',
                              'message', public._c('custreg.err_no_values'));
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  if v_cid is null then
    -- New shop: the same guarded door every other registration kind uses. It
    -- sets user_id, status and approved itself and refuses a privilege key.
    v_sub := public.submit_registration('pharmacy', p_values - 'dl_expiry' - 'latitude' - 'longitude');
    v_cid := nullif(v_sub->>'id','')::uuid;
    v_rejected := coalesce((select array_agg(x #>> '{}') from jsonb_array_elements(v_sub->'rejected_keys') x), '{}');
  end if;

  if v_cid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','save_failed',
                              'message', public._c('custreg.err_save'));
  end if;

  -- An imported shop already had a row: the form UPDATES it, and only the
  -- columns the form is allowed to write. Approval state is never among them.
  for v_key in select jsonb_object_keys(p_values) loop
    if v_key = any (v_allowed) then
      if v_key = 'dl_expiry' then
        v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::date', v_key, p_values->>v_key);
      elsif v_key in ('latitude','longitude') then
        v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::numeric', v_key, p_values->>v_key);
      else
        v_sets := v_sets || format('%I = coalesce(nullif(btrim(%L),''''), %I)', v_key, p_values->>v_key, v_key);
      end if;
    else
      v_rejected := v_rejected || v_key;
    end if;
  end loop;

  if array_length(v_sets, 1) is not null then
    execute format('update public.pharmacy_profiles set %s, updated_at = now() where id = %L and user_id = %L',
                   array_to_string(v_sets, ', '), v_cid, v_uid);
    -- A brand-new row was just inserted by submit_registration under this
    -- user, so the user_id guard above always matches. An imported row whose
    -- identity was claimed at login matches too; anything else writes nothing.
  end if;

  select zone_id into v_zone from public.pharmacy_profiles where id = v_cid;

  -- "I don't have this" — recorded on the document ledger with the ledger's
  -- own vocabulary, so every reader (the form, the admin page, the reminder
  -- ladder) sees one truth. It is NOT a submission: the paper is still owed.
  if p_skips is not null and jsonb_typeof(p_skips) = 'array' then
    for v_skip in select x #>> '{}' from jsonb_array_elements(p_skips) x loop
      continue when coalesce(btrim(v_skip),'') = '';
      continue when coalesce(public.custdoc_mode_for(v_zone, v_skip), 'off') = 'off';
      if not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = v_cid
                        and kd.kind = v_skip
                        and kd.status in ('pending','submitted','verified')) then
        insert into public.kyc_documents(owner_kind, owner_id, kind, bucket, path,
                                         status, submitted_by, submitted_at, source, zone_id)
        values ('pharmacy', v_cid, btrim(v_skip), 'kyc-docs', '',
                'not_available', v_uid, now(), 'app', v_zone);
      end if;
    end loop;
  end if;

  begin v_missing := coalesce(public.customer_docs_missing_labels(v_cid), '');
  exception when others then v_missing := ''; end;

  -- The stage the account lands in. A starred paper still out is
  -- "documents" — Docs pending — and customer_approve_gate refuses from there.
  select registration_stage into v_stage from public.pharmacy_profiles where id = v_cid;
  if coalesce(v_stage::text,'') not in ('approved','verified') then
    update public.pharmacy_profiles
       set registration_stage = case when v_missing = '' then 'verified'::public.registration_stage
                                     else 'documents'::public.registration_stage end,
           updated_at = now()
     where id = v_cid;
  end if;

  begin perform public.customer_reg_draft_clear('signup'); exception when others then null; end;

  return jsonb_build_object(
    'ok', true, 'tone', case when v_missing = '' then 'success' else 'warning' end,
    'customer_id', v_cid,
    'message', case when v_missing = '' then public._c('custreg.saved_message')
                    else public._cf('custreg.pending_line', jsonb_build_object('docs', v_missing)) end,
    'docs_pending', (v_missing <> ''),
    'docs_missing', v_missing,
    'rejected_keys', to_jsonb(v_rejected),
    'payload', public.customer_registration_payload());
end $function$;

revoke all on function public.customer_registration_submit(jsonb, jsonb) from public, anon;
grant execute on function public.customer_registration_submit(jsonb, jsonb) to authenticated, service_role;

-- ── 8. Approval refuses, by name ────────────────────────────────────────────
-- customer_approve_gate already says WHY on the screen. This is the door
-- itself: an approve that arrives anyway is refused with the same list, so a
-- second surface (or a retry) cannot approve a shop with papers outstanding.
create or replace function public.admin_customer_action(p_customer_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text := coalesce(public.role_for_medibo_only(), 'none');
  v_who  text;
  v_cfg  jsonb := coalesce((select value from app_settings where key='customer_status_values'), '{}'::jsonb);
  v_act  text := lower(btrim(coalesce(p_action,'')));
  v_docs text := '';
  pp pharmacy_profiles%rowtype;
  bb pharmacy_profiles%rowtype;
begin
  if v_role not in ('admin','super_admin')
     or not public.admin_can('admin.customers','write') then
    raise exception 'forbidden' using hint = 'Only an admin may change customer status.';
  end if;

  if v_act = 'block'   then v_act := 'suspend'; end if;
  if v_act = 'unblock' then v_act := 'reactivate'; end if;

  select * into pp from pharmacy_profiles where id = p_customer_id;
  if not found then raise exception 'customer_not_found'; end if;
  bb := pp;

  v_who := coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown');

  if v_act = 'approve' then
    -- CMD #2061 — Docs pending cannot be approved. The names come from the
    -- zone's own document config; nothing here is worded in Dart.
    begin v_docs := coalesce(public.customer_docs_missing_labels(p_customer_id), '');
    exception when others then v_docs := ''; end;
    if v_docs <> '' then
      return jsonb_build_object(
        'ok', false, 'action', v_act, 'refused', 'docs_pending',
        'customer_id', coalesce(pp.id::text,''),
        'pharmacy_name', coalesce(pp.pharmacy_name,''),
        'docs_missing', v_docs,
        'tone', 'warning',
        'message', public._cf('cust_pipeline.approve_blocked_docs',
                              jsonb_build_object('docs', v_docs)));
    end if;
    update pharmacy_profiles set
      approved = true, status = coalesce(v_cfg->>'approved','approved'),
      registration_stage = 'approved'::public.registration_stage,
      approved_at = now(), approved_by = v_who
    where id = p_customer_id;

  elsif v_act = 'reject' then
    update pharmacy_profiles set
      approved = false, status = coalesce(v_cfg->>'rejected','rejected')
    where id = p_customer_id;

  elsif v_act = 'suspend' then
    update pharmacy_profiles set status = coalesce(v_cfg->>'suspended','suspended')
    where id = p_customer_id;

  elsif v_act = 'reactivate' then
    update pharmacy_profiles set status = coalesce(v_cfg->>'approved','approved')
    where id = p_customer_id;

  elsif v_act = 'delete' then
    update pharmacy_profiles set
      is_deleted = true, deleted_at = now(), deleted_by = v_who,
      deleted_snapshot = to_jsonb(pp)
    where id = p_customer_id;

  elsif v_act = 'restore' then
    update pharmacy_profiles set
      is_deleted = false, deleted_at = null, deleted_by = null, deleted_snapshot = null
    where id = p_customer_id;

  else
    raise exception 'unknown_action: %', p_action;
  end if;

  select * into pp from pharmacy_profiles where id = p_customer_id;

  perform public.audit_write('customer.' || v_act, 'customer', p_customer_id::text,
            jsonb_build_object('approved', bb.approved, 'status', bb.status,
                               'is_deleted', bb.is_deleted),
            jsonb_build_object('approved', pp.approved, 'status', pp.status,
                               'is_deleted', pp.is_deleted));

  return jsonb_build_object(
    'ok', true, 'action', v_act,
    'customer_id',   coalesce(pp.id::text,''),
    'pharmacy_name', coalesce(pp.pharmacy_name,''),
    'user_id',       coalesce(pp.user_id::text,''),
    'email',         coalesce(pp.email,''),
    'approved',      coalesce(pp.approved,false),
    'status',        coalesce(pp.status,''),
    'is_deleted',    coalesce(pp.is_deleted,false),
    'acted_by',      v_who);
end $function$;

-- ── 9. The admin list names the papers that are out ─────────────────────────
create or replace function public.customers_needs_attention()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint := public.admin_active_zone();
  v_end  timestamptz := (public.ist_day_bounds(public.admin_active_date())->>'end_utc')::timestamptz;
  v_rows jsonb;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'allowed', false,
      'message', public.uic('cust_pipeline.not_authorized','This screen is for the office team.'));
  end if;

  select coalesce(jsonb_agg(r order by (r->>'stage_ord')::int, r->>'name'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'customer_id', pp.id,
      'name', coalesce(nullif(btrim(coalesce(pp.pharmacy_name,'')),''),
                       nullif(btrim(coalesce(pp.owner_name,'')),''),
                       public.uic('cust_pipeline.no_name','(no name given)')),
      'contact', coalesce(nullif(btrim(coalesce(pp.phone,'')),''), coalesce(pp.whatsapp_no,''), coalesce(pp.email,'')),
      'stage_chip', public.customer_stage_chip(pp.registration_stage),
      'stage_ord', array_position(array['signed_up','details','documents','verified','approved'],
                                  coalesce(pp.registration_stage::text,'signed_up')),
      'missing', m.missing,
      'missing_label', public.customer_missing_sentence(m.missing),
      -- CMD #2061 — the documents, named, on the row itself.
      'docs_missing', coalesce(d.docs,''),
      'docs_label', case when coalesce(d.docs,'') = ''
                         then public.uic('cust_pipeline.docs_ok','All in')
                         else public._cf('cust_pipeline.docs_missing',
                                         jsonb_build_object('docs', d.docs)) end,
      'docs_tone', case when coalesce(d.docs,'') = '' then 'success' else 'warning' end,
      'assigned_to', pp.assigned_to,
      'assigned_label', coalesce(nullif(btrim(coalesce(au.email,'')),''),
                                 public.uic('cust_pipeline.unassigned','Unassigned')),
      'next_action_at', pp.next_action_at,
      'next_action_label', public._c1886_followup_label(pp.next_action_at),
      'next_action_tone', public._c1886_followup_tone(pp.next_action_at),
      'approve', public.customer_approve_gate(pp.id)
    ) as r
    from public.pharmacy_profiles pp
    cross join lateral (select public.customer_missing_fields(pp.id) as missing) m
    cross join lateral (select public.customer_docs_missing_labels(pp.id) as docs) d
    left join auth.users au on au.id = pp.assigned_to
    where coalesce(pp.is_deleted,false) = false
      and not coalesce(pp.is_synthetic,false)
      and pp.created_at < v_end
      and (v_zone is null or pp.zone_id = v_zone)
      and jsonb_array_length(m.missing) > 0
  ) t;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'title', public.uic('cust_pipeline.tab_needs','Needs attention'),
    'empty_label', public.uic('cust_pipeline.empty_needs',''),
    'count', jsonb_array_length(v_rows),
    'columns', jsonb_build_array(
      jsonb_build_object('key','name',    'label', public.uic('cust_pipeline.col_person','Person')),
      jsonb_build_object('key','stage',   'label', public.uic('cust_pipeline.col_stage','Stage')),
      jsonb_build_object('key','missing', 'label', public.uic('cust_pipeline.col_missing','Missing')),
      jsonb_build_object('key','docs',    'label', public.uic('cust_pipeline.col_docs','Documents')),
      jsonb_build_object('key','owner',   'label', public.uic('cust_pipeline.col_owner','Owner')),
      jsonb_build_object('key','action',  'label', public.uic('cust_pipeline.col_action','Action'))),
    'actions', public._c1886_actions(),
    'rows', v_rows);
end $function$;
