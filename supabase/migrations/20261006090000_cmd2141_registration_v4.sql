-- CMD #2141 — Registration v4, shared by customer registration AND staff Add customer.
--  • General: owner (Mr/Ms) first, then pharmacy, store type, WhatsApp + email REQUIRED
--    with a live format + uniqueness check (custreg_contact_check), no OTP.
--  • Top bar: labels without ✓; the docs step is complete only when its papers are.
--  • Location: one banner at a time, street-level zoom, no plus codes, precise pincode.
--  • Documents: one progress card; every row has one circle (↑ ✓ ✎ ↻) and one sub-line.
-- Idempotent: every function patch is guarded, every insert is an upsert.

-- ── 1. Owner salutation ───────────────────────────────────────────────────
alter table public.pharmacy_profiles add column if not exists owner_salutation text;

insert into public.customer_form_field(key, section_key, label, hint, field_type, required, sort_order,
                                       half_width, max_lines, contexts, default_value, is_active)
values ('owner_salutation', 'business', 'Title', '', 'select', false, 5, false, 1,
        array['admin','signup'], 'Mr', true)
on conflict (key) do update set default_value = excluded.default_value, field_type = excluded.field_type,
                                contexts = excluded.contexts, is_active = true;

-- Owner name first, both contacts required on the registration context (signup
-- is also the context staff Add customer renders).
update public.customer_form_field set sort_order = 8,  hint = 'Full name', required_in = array['signup']
 where key = 'customer_name';
update public.customer_form_field set hint = 'Shop name' where key = 'pharmacy_name';
update public.customer_form_field set hint = '10-digit number' where key = 'whatsapp_no';
update public.customer_form_field set hint = 'name@gmail.com', required_in = array['signup'] where key = 'email';

-- The writers learn the new column (text patches, applied once).
do $$
declare d text;
begin
  select pg_get_functiondef('public.customer_registration_submit'::regproc) into d;
  if position('owner_salutation' in d) = 0 then
    execute replace(d, '''landmark''];', '''landmark'',''owner_salutation''];');
  end if;

  select pg_get_functiondef('public.addcust_save'::regproc) into d;
  if position('owner_salutation' in d) = 0 then
    execute replace(d, '''''), landmark)',
      '''''), landmark),' || chr(10) ||
      '         owner_salutation = coalesce(nullif(btrim(v->>''owner_salutation''),''''), owner_salutation)');
  end if;

  select pg_get_functiondef('public.customer_registration_payload'::regproc) into d;
  if position('owner_salutation' in d) = 0 then
    d := replace(d, 'phone, whatsapp_no, email, coalesce(address',
                    'phone, whatsapp_no, email, owner_salutation, coalesce(address');
    d := replace(d, '''email'',               nullif(btrim(coalesce(v_row.email,'''')),''''),',
                    '''email'',               nullif(btrim(coalesce(v_row.email,'''')),''''),' || chr(10) ||
                    '      ''owner_salutation'',    nullif(btrim(coalesce(v_row.owner_salutation,'''')),''''),');
    execute d;
  end if;
end $$;

-- ── 2. Copy ───────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('custreg.wiz_step_done_label', to_jsonb('{label}'::text)),
  ('custreg.wiz_title_shop',      to_jsonb('Your shop details'::text)),
  ('custreg.wiz_title_location',  to_jsonb('Where is your shop?'::text)),
  ('custreg.wiz_title_licences',  to_jsonb('Upload your papers'::text)),
  ('custreg.wiz_sub_shop',        to_jsonb(''::text)),
  ('custreg.wiz_sub_location',    to_jsonb(''::text)),
  ('custreg.wiz_sub_licences',    to_jsonb(''::text)),
  ('custreg.wiz_prefilled_note',  to_jsonb(''::text)),
  ('customer_form.required_suffix', to_jsonb(' *'::text)),
  ('custreg.v4_required',         to_jsonb('Required'::text)),
  ('custreg.v4_ok',               to_jsonb('✓'::text)),
  ('custreg.v4_counter',          to_jsonb('{n} / {total}'::text)),
  ('custreg.v4_invalid',          to_jsonb('Invalid'::text)),
  ('custreg.v4_checking',         to_jsonb('Checking…'::text)),
  ('custreg.v4_taken',            to_jsonb('Already registered'::text)),
  ('custreg.v4_taken_phone',      to_jsonb('This number has an account'::text)),
  ('custreg.v4_taken_email',      to_jsonb('This email has an account'::text)),
  ('custreg.v4_login',            to_jsonb('Login'::text)),
  -- Location: one banner at a time.
  ('custreg.loc_read_ok',         to_jsonb('✓ Found you — check the address'::text)),
  ('custreg.loc_read_failed',     to_jsonb('Couldn''t read this spot — type the address'::text)),
  ('custreg.loc_reading',         to_jsonb('Finding the address…'::text)),
  ('custreg.loc_denied',          to_jsonb('Location is off — drag the pin or type the address'::text)),
  ('custreg.loc_turn_on',         to_jsonb('Turn on'::text)),
  ('custreg.loc_zoomed',          to_jsonb('Zoomed to you'::text)),
  ('custreg.loc_drag_hint',       to_jsonb('Drag to your shop door'::text)),
  ('custreg.v3_filled_note',      to_jsonb(''::text)),
  -- Documents: one progress card, one sub-line per row.
  ('custreg.v4_progress_title',   to_jsonb('Required papers'::text)),
  ('custreg.v4_progress_count',   to_jsonb('{done} of {total} done'::text)),
  ('custreg.v4_still_needed',     to_jsonb('Still needed: {list}'::text)),
  ('custreg.v4_all_added',        to_jsonb('All required papers added'::text)),
  ('custreg.v4_attention_title',  to_jsonb('Needs your attention'::text)),
  ('custreg.v4_attention_one',    to_jsonb('1 paper'::text)),
  ('custreg.v4_attention_many',   to_jsonb('{n} papers'::text)),
  ('custreg.v4_needed',           to_jsonb('Needed'::text)),
  ('custreg.v4_optional',         to_jsonb('Optional'::text)),
  ('custreg.v4_uploaded',         to_jsonb('Uploaded'::text)),
  ('custreg.v4_dont_have',        to_jsonb('Don''t have'::text)),
  ('custreg.v4_num_till',         to_jsonb('{number} · till {date}'::text)),
  ('custreg.v3_saved_note',       to_jsonb(''::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 3. Wizard config: order, Mr/Ms prefix, autofill, live checks ──────────
update public.app_settings
   set value = jsonb_set(value, '{steps}', (select jsonb_agg(
         case s->>'key'
           when 'shop' then s || jsonb_build_object('fields',
                jsonb_build_array('customer_name','pharmacy_name','store_type','whatsapp_no','email'))
           else s end order by o)
       from jsonb_array_elements(value->'steps') with ordinality t(s, o)))
       || jsonb_build_object(
            'layout', 'v4',
            'street_zoom', 18,
            'check_debounce_ms', 400,
            'prefix', jsonb_build_object('customer_name', jsonb_build_object(
                'key', 'owner_salutation', 'default', 'Mr',
                'options', jsonb_build_array(
                   jsonb_build_object('label','Mr','value','Mr'),
                   jsonb_build_object('label','Ms','value','Ms')))),
            'autofill', jsonb_build_object(
                'customer_name', 'name', 'pharmacy_name', 'organizationName',
                'whatsapp_no', 'telephoneNumberNational', 'email', 'email'),
            'checks', jsonb_build_object('whatsapp_no', 'phone', 'email', 'email'),
            'phone_digits', 10)
 where key = 'custreg_wizard';

-- ── 4. Wizard payload: the new blocks + a docs step that is done only when its papers are
do $$
declare d text;
begin
  select pg_get_functiondef('public.customer_registration_wizard'::regproc) into d;
  if position('required_label' in d) = 0 then
    d := replace(d, 'v_complete := v_complete and v_i <= v_seen;',
      'v_complete := v_complete and v_i <= v_seen' || chr(10) ||
      '      and (not coalesce((v_step->>''docs'')::boolean, false)' || chr(10) ||
      '           or coalesce((p_docs->>''required_left'')::int, 0) = 0);');
    d := replace(d, '''field_notes'',    v_notes,',
      '''field_notes'',    v_notes,' || chr(10) ||
      '    ''layout'',         coalesce(v_cfg->>''layout'', ''v3''),' || chr(10) ||
      '    ''prefix'',         coalesce(v_cfg->''prefix'', ''{}''::jsonb),' || chr(10) ||
      '    ''autofill'',       coalesce(v_cfg->''autofill'', ''{}''::jsonb),' || chr(10) ||
      '    ''checks'',         coalesce(v_cfg->''checks'', ''{}''::jsonb),' || chr(10) ||
      '    ''check_debounce_ms'', coalesce((v_cfg->>''check_debounce_ms'')::int, 400),' || chr(10) ||
      '    ''required_label'', public._c(''custreg.v4_required''),');
    d := replace(d, '''drag_hint'',             public._c(''custreg.loc_drag_hint''),',
      '''drag_hint'',             public._c(''custreg.loc_drag_hint''),' || chr(10) ||
      '                 ''street_zoom'',           coalesce((v_cfg->>''street_zoom'')::numeric, 18),' || chr(10) ||
      '                 ''zoomed_label'',          public._c(''custreg.loc_zoomed''),' || chr(10) ||
      '                 ''turn_on_label'',         public._c(''custreg.loc_turn_on''),');
    execute d;
  end if;
end $$;

-- ── 5. Live contact check (no OTP) ─────────────────────────────────────────
-- One verdict per keystroke pause: what to print at the end of the box, its
-- tone, whether Continue may go, and — when the value belongs to another
-- account — the card with Login (customer) or the plain line (staff).
create or replace function public.custreg_contact_check(p_field text, p_value text,
                                                        p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid   uuid := auth.uid();
  v_staff boolean := coalesce(public.is_admin(), false);
  v_kind  text := case when p_field = 'email' then 'email' else 'phone' end;
  v_raw   text := btrim(coalesce(p_value, ''));
  v_n     text; v_own uuid; v_taken boolean := false; v_dom text;
  v_total int := coalesce((select (value->>'phone_digits')::int from app_settings where key = 'custreg_wizard'), 10);
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'state', 'not_signed_in', 'blocks', false);
  end if;
  if v_raw = '' then
    return jsonb_build_object('ok', true, 'field', p_field, 'state', 'empty', 'blocks', false,
                              'suffix', '', 'tone', 'neutral');
  end if;
  -- The caller's own row: a customer's own number is never "already registered".
  if not v_staff then
    select id into v_own from public.pharmacy_profiles
     where user_id = v_uid and coalesce(is_deleted,false) = false
     order by created_at desc limit 1;
  else
    v_own := p_customer_id;
  end if;

  if v_kind = 'phone' then
    v_n := regexp_replace(v_raw, '\D', '', 'g');
    if length(v_n) > v_total and left(v_n, 2) = '91' then v_n := substr(v_n, 3); end if;
    if length(v_n) > v_total and left(v_n, 1) = '0' then v_n := substr(v_n, 2); end if;
    if length(v_n) < v_total then
      return jsonb_build_object('ok', true, 'field', p_field, 'state', 'typing', 'blocks', true,
        'suffix', public._cf('custreg.v4_counter', jsonb_build_object('n', length(v_n), 'total', v_total)),
        'tone', 'neutral');
    end if;
    if length(v_n) <> v_total or v_n !~ '^[6-9]' then
      return jsonb_build_object('ok', true, 'field', p_field, 'state', 'invalid', 'blocks', true,
        'suffix', public._c('custreg.v4_invalid'), 'tone', 'danger');
    end if;
    -- Staff: the Add customer verdict under the box (addcust_number_check)
    -- already judges an existing shop with its own actions — say only "valid".
    if not v_staff then
      v_dom := coalesce(public.login_signup_cfg()->>'internal_email_domain', 'wa.medibo.in');
      v_taken := exists (select 1 from public.pharmacy_profiles pp
                          where coalesce(pp.is_deleted,false) = false
                            and pp.id is distinct from v_own
                            and pp.user_id is distinct from v_uid
                            and public._phone10(coalesce(pp.whatsapp_no, pp.phone, '')) = v_n)
              or exists (select 1 from auth.users u
                          where u.id <> v_uid
                            and (right(regexp_replace(coalesce(u.phone,''),'\D','','g'), 10) = v_n
                                 or lower(coalesce(u.email,'')) = v_n || '@' || v_dom));
    end if;
  else
    v_n := lower(v_raw);
    if v_n !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then
      return jsonb_build_object('ok', true, 'field', p_field, 'state', 'invalid', 'blocks', true,
        'suffix', public._c('custreg.v4_invalid'), 'tone', 'danger');
    end if;
    v_taken := exists (select 1 from public.pharmacy_profiles pp
                        where coalesce(pp.is_deleted,false) = false
                          and pp.id is distinct from v_own
                          and (v_staff or pp.user_id is distinct from v_uid)
                          and lower(btrim(coalesce(pp.email,''))) = v_n)
            or (not v_staff and exists (select 1 from auth.users u
                                         where u.id <> v_uid and lower(coalesce(u.email,'')) = v_n));
  end if;

  if v_taken then
    return jsonb_build_object('ok', true, 'field', p_field, 'state', 'taken', 'blocks', true,
      'suffix', public._c('custreg.v4_taken'), 'tone', 'warning',
      'card', jsonb_build_object(
        'line', public._c(case when v_kind = 'phone' then 'custreg.v4_taken_phone' else 'custreg.v4_taken_email' end),
        'login_label', case when v_staff then '' else public._c('custreg.v4_login') end,
        'login_number', case when v_kind = 'phone' and not v_staff then v_n else '' end));
  end if;
  return jsonb_build_object('ok', true, 'field', p_field, 'state', 'ok', 'blocks', false,
    'suffix', public._c('custreg.v4_ok'), 'tone', 'success', 'value', v_n);
end $$;
revoke all on function public.custreg_contact_check(text, text, uuid) from public, anon;
grant execute on function public.custreg_contact_check(text, text, uuid) to authenticated;

-- ── 6. Documents block v4 (full definition) ──
CREATE OR REPLACE FUNCTION public.custreg_licences_block(p_zone smallint DEFAULT NULL::smallint, p_owner_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           d.valid_to,
           coalesce(d.read_state,'') as read_state,
           coalesce(d.read_fields,'{}'::jsonb) as read_fields,
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
        -- CMD #2141 — v4: ONE sub-line and ONE circle per row.
        'sub', case
                 when s.state = 'rejected' then jsonb_build_object('tone','danger', 'text',
                      case when nullif(btrim(j.reason),'') is null then public._c('custreg.lic_rejected_plain')
                           else public._cf('custreg.lic_rejected', jsonb_build_object('reason', j.reason)) end)
                 when s.state = 'uploaded' and j.ocr_field <> '' and nullif(btrim(j.number),'') is null
                      then jsonb_build_object('tone','warning', 'text', public._c('custreg.v3_unreadable'))
                 when s.state = 'uploaded' and j.ocr_field <> '' and j.valid_to is not null
                      then jsonb_build_object('tone','neutral', 'text', public._cf('custreg.v4_num_till',
                             jsonb_build_object('number', btrim(j.number), 'date', to_char(j.valid_to, 'DD Mon YYYY'))))
                 when s.state = 'uploaded' and j.ocr_field <> ''
                      then jsonb_build_object('tone','neutral', 'text', btrim(j.number))
                 when s.state = 'uploaded' then jsonb_build_object('tone','success', 'text', public._c('custreg.v4_uploaded'))
                 when s.state = 'skipped' then jsonb_build_object('tone','neutral', 'text', public._c('custreg.v4_dont_have'))
                 when j.mode = 'mandatory' then jsonb_build_object('tone','warning', 'text', public._c('custreg.v4_needed'))
                 else jsonb_build_object('tone','neutral', 'text', public._c('custreg.v4_optional')) end,
        'circle', case
                 when s.state = 'rejected' then jsonb_build_object('icon','retry','tone','danger','filled',false,'tap','retake')
                 when s.state = 'uploaded' and j.ocr_field <> '' and nullif(btrim(j.number),'') is null
                      then jsonb_build_object('icon','edit','tone','warning','filled',false,'tap','edit')
                 when s.state = 'uploaded' and j.ocr_field <> ''
                      then jsonb_build_object('icon','check','tone','success','filled',true,'tap','edit')
                 when s.state = 'uploaded' then jsonb_build_object('icon','check','tone','success','filled',true,'tap','view')
                 else jsonb_build_object('icon','upload','tone','brand','filled',false,'tap','upload') end,
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
      ) || public._custreg_doc_row_v3(j.key, j.label, j.ocr_field, s.state, j.has_file,
                                        j.number, j.valid_to, j.read_state, j.read_fields, j.reason) as r
      from shaped s join joined j on j.key = s.key
  ) x;

  return jsonb_build_object(
    'show',      (jsonb_array_length(v_rows) > 0),
    'empty_label', public._c('custreg.lic_empty'),
    'zone_id',   p_zone,
    -- CMD #2135 — v3 rows (number on the row + Edit) and no Scan card: every
    -- upload is read by itself, so a separate scan is one tap too many.
    'layout',        'v4',
    -- CMD #2141 — the ONE progress card at the top of the step.
    'progress', case
      when exists (select 1 from jsonb_array_elements(v_rows) e where e->>'group' = 'attention') then
        jsonb_build_object('key','attention', 'tone','danger', 'bar', false,
          'title', public._c('custreg.v4_attention_title'),
          'count_label', (select case when count(*) = 1 then public._c('custreg.v4_attention_one')
                                      else public._cf('custreg.v4_attention_many', jsonb_build_object('n', count(*))) end
                            from jsonb_array_elements(v_rows) e where e->>'group' = 'attention'),
          'line', '', 'line_tone', 'neutral', 'fraction', 0)
      when v_req_total > 0 then
        jsonb_build_object('key','required', 'tone', case when v_req_done >= v_req_total then 'success' else 'brand' end,
          'bar', true,
          'title', public._c('custreg.v4_progress_title'),
          'count_label', public._cf('custreg.v4_progress_count',
                           jsonb_build_object('done', v_req_done, 'total', v_req_total)),
          'fraction', round(least(v_req_done::numeric / v_req_total, 1), 3),
          'line', case when v_req_done >= v_req_total then public._c('custreg.v4_all_added')
                       else public._cf('custreg.v4_still_needed', jsonb_build_object('list',
                              (select string_agg(e->>'label', ', ' order by ord)
                                 from jsonb_array_elements(v_rows) with ordinality t(e, ord)
                                where (e->>'required')::boolean and e->>'state' <> 'uploaded'))) end,
          'line_tone', case when v_req_done >= v_req_total then 'success' else 'neutral' end)
      else null end,
    'required_complete', (v_req_done >= v_req_total),
    'reading_label', public._c('custreg.v3_reading'),
    'saved_note',    case when exists (select 1 from jsonb_array_elements(v_rows) e
                                        where coalesce((e->>'can_view')::boolean,false))
                          then public._c('custreg.v3_saved_note') else '' end,
    'upload_failed_label', public._c('custreg.v3_upload_failed'),
    'scan',      jsonb_build_object(
                   'show',     false,
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
        'counter_label', '',
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
end $function$;

-- ── 7. Reverse geocode: never a plus code, the most precise pincode ─────────
-- Google's results run most-precise first, and results[0] is often the
-- PLUS CODE ("7JX2+XX Raipur"), which then became the shop's address and
-- carried no pincode. Now: components from the first result that is not a
-- plus code, the pincode from the first (most precise) result that has one,
-- and any plus-code token scrubbed from the line.
create or replace function public.geo_reverse_parse(p_provider text, p_body jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  v_a jsonb; v_c jsonb; v_best jsonb; r jsonb;
  v_addr text; v_land text; v_city text; v_state text; v_pin text; v_dist text; v_dist3 text;
  v_house text; v_road text; v_prem text; v_sub2 text;
  v_pc constant text := '\m[23456789CFGHJMPQRVWX]{4,8}\+[23456789CFGHJMPQRVWX]{2,3}\M,?\s*';
begin
  if p_body is null or jsonb_typeof(p_body) <> 'object' then return '{}'::jsonb; end if;

  if p_provider = 'google' then
    for r in select value from jsonb_array_elements(coalesce(p_body->'results','[]'::jsonb)) loop
      continue when coalesce(r->'types','[]'::jsonb) ? 'plus_code';
      v_best := r; exit;
    end loop;
    if v_best is null then v_best := p_body->'results'->0; end if;
    v_c := v_best->'address_components';
    if v_c is null then return '{}'::jsonb; end if;
    select max(case when c->'types' ? 'street_number' then c->>'long_name' end),
           max(case when c->'types' ? 'premise' or c->'types' ? 'subpremise'
                     or c->'types' ? 'establishment' then c->>'long_name' end),
           max(case when c->'types' ? 'route' then c->>'long_name' end),
           coalesce(max(case when c->'types' ? 'sublocality_level_1' then c->>'long_name' end),
                    max(case when c->'types' ? 'neighborhood' then c->>'long_name' end)),
           max(case when c->'types' ? 'sublocality_level_2' then c->>'long_name' end),
           max(case when c->'types' ? 'locality' or c->'types' ? 'postal_town'
                    then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_1' then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_2' then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_3' then c->>'long_name' end)
      into v_house, v_prem, v_road, v_land, v_sub2, v_city, v_state, v_dist, v_dist3
      from jsonb_array_elements(v_c) c
     where not (c->'types' ? 'plus_code');
    -- The pincode of the most precise result that carries one.
    select c->>'long_name' into v_pin
      from jsonb_array_elements(coalesce(p_body->'results','[]'::jsonb)) with ordinality t(res, o),
           jsonb_array_elements(coalesce(res->'address_components','[]'::jsonb)) c
     where c->'types' ? 'postal_code'
     order by o limit 1;
    v_addr := nullif(btrim(concat_ws(', ', v_prem, v_house, v_road, v_sub2)), '');
    if v_addr is null then
      v_addr := nullif(btrim(split_part(coalesce(v_best->>'formatted_address',''),
                                        ', ' || coalesce(v_city, '~'), 1)), '');
    end if;
    v_addr := nullif(btrim(regexp_replace(coalesce(v_addr,''), v_pc, '', 'g'), ' ,'), '');
    -- A line that is only the city (all a plus code left behind) is no address.
    if v_addr is not null and lower(v_addr) = lower(coalesce(v_city,'')) then v_addr := null; end if;
  else
    v_a := p_body->'address';
    if v_a is null then return '{}'::jsonb; end if;
    v_house := nullif(btrim(coalesce(v_a->>'house_number','')),'');
    v_road  := coalesce(nullif(btrim(coalesce(v_a->>'road','')),''),
                        nullif(btrim(coalesce(v_a->>'pedestrian','')),''),
                        nullif(btrim(coalesce(v_a->>'residential','')),''));
    v_land  := coalesce(nullif(btrim(coalesce(v_a->>'neighbourhood','')),''),
                        nullif(btrim(coalesce(v_a->>'suburb','')),''),
                        nullif(btrim(coalesce(v_a->>'quarter','')),''),
                        nullif(btrim(coalesce(v_a->>'village','')),''));
    v_city  := coalesce(nullif(btrim(coalesce(v_a->>'city','')),''),
                        nullif(btrim(coalesce(v_a->>'town','')),''),
                        nullif(btrim(coalesce(v_a->>'municipality','')),''),
                        nullif(btrim(coalesce(v_a->>'village','')),''));
    v_state := nullif(btrim(coalesce(v_a->>'state','')),'');
    v_pin   := nullif(btrim(coalesce(v_a->>'postcode','')),'');
    v_dist  := coalesce(nullif(btrim(coalesce(v_a->>'state_district','')),''),
                        nullif(btrim(coalesce(v_a->>'county','')),''));
    v_addr := nullif(btrim(concat_ws(', ', v_house, v_road)), '');
    if v_addr is null then
      v_addr := nullif(btrim(coalesce(p_body->>'display_name','')), '');
    end if;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'address',      v_addr,
    'landmark',     v_land,
    'city',         v_city,
    'state',        v_state,
    'pincode',      nullif(regexp_replace(coalesce(v_pin,''), '[^0-9]', '', 'g'), ''),
    'district',     v_dist,
    'district_alt', v_dist3,
    'parse',        'v4'));
end $$;

-- Cached reads from the old parser (plus codes, wrong pincodes) are not reused.
do $$
declare d text;
begin
  select pg_get_functiondef('public.geo_reverse'::regproc) into d;
  if position('''parse'' = ''v4''' in d) = 0 then
    execute replace(d, 'v_out ? ''district_matched'' then',
                       'v_out ? ''district_matched'' and v_out->>''parse'' = ''v4'' then');
  end if;
end $$;

-- ── 8. OCR fix: a drug licence number the model filed as the generic
-- "document_number" still lands on the 20B / 21B row.
do $$
declare d text;
begin
  select pg_get_functiondef('public.custreg_doc_read_save'::regproc) into d;
  if position('CMD2141' in d) = 0 then
    d := replace(d, 'when ''dl_20b'' then coalesce(nullif(v_o->>''licence_20b'',''''), v_o->>''licence_number'')',
                    'when ''dl_20b'' then coalesce(nullif(v_o->>''licence_20b'',''''), nullif(v_o->>''licence_number'',''''), v_o->>''document_number'') /* CMD2141 */');
    d := replace(d, 'when ''dl_21b'' then coalesce(nullif(v_o->>''licence_21b'',''''), v_o->>''licence_number'')',
                    'when ''dl_21b'' then coalesce(nullif(v_o->>''licence_21b'',''''), nullif(v_o->>''licence_number'',''''), v_o->>''document_number'')');
    execute d;
  end if;
end $$;

-- ── 9. The two live-check words the box prints before the backend answers.
do $$
declare d text;
begin
  select pg_get_functiondef('public.customer_registration_wizard'::regproc) into d;
  if position('checking_label' in d) = 0 then
    execute replace(d, '''required_label'', public._c(''custreg.v4_required''),',
      '''required_label'', public._c(''custreg.v4_required''),' || chr(10) ||
      '    ''checking_label'', public._c(''custreg.v4_checking''),' || chr(10) ||
      '    ''phone_prefix'',   coalesce(v_cfg->>''phone_prefix'', ''+91''),');
  end if;
end $$;
