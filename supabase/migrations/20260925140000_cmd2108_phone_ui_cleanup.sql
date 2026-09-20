-- CMD #2108 — supplier & customer phone UI cleanup (backend half).
--
-- 1) The supplier bottom nav wrapped "Add Medicine" onto two lines and spilled
--    below the bar on a 360px phone. The bar draws ONE line per tab now, and
--    the short word it draws is backend copy, not a Dart substring: the long
--    label stays for the desktop tab bar, which has the room.
-- 2) The supplier header's "Hello, …" greeting and the standalone logout icon
--    are gone; the full name is the kebab sheet's first (non-tappable) line and
--    Logout is a row inside it. Both words come from here.
-- 3) kyc_my_panel(): a HUMAN reviewer's rejection reason reached the card
--    verbatim, so a reviewer who typed "no" produced a card whose entire
--    explanation was the word "no". It carries the same 'Rejected: {reason}'
--    prefix `reason_line` has always used — the applicant reads a sentence, and
--    the reviewer's own words are still inside it, untouched.
--
-- Idempotent: upserts + CREATE OR REPLACE only.

insert into public.ui_copy (key, value) values
  ('supplier_shell.tab_home_short',     to_jsonb('Home'::text)),
  ('supplier_shell.tab_add_short',      to_jsonb('Add'::text)),
  ('supplier_shell.tab_inquiry_short',  to_jsonb('Requests'::text)),
  ('supplier_shell.tab_orders_short',   to_jsonb('Orders'::text)),
  ('supplier_shell.tab_disputes_short', to_jsonb('Disputes'::text)),
  ('supplier_shell.menu_logout',   to_jsonb('Logout'::text)),
  ('supplier_shell.menu_account_hint', to_jsonb('Signed in'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

CREATE OR REPLACE FUNCTION public.kyc_my_panel()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text; v_id uuid; v_state jsonb; v_rows jsonb;
  v_cfg jsonb := coalesce((select value from app_settings where key='kyc_gate'), '{}'::jsonb);
  v_req text[] := coalesce((select array_agg(x #>> '{}')
                              from jsonb_array_elements(coalesce(v_cfg->'required_kinds','[]'::jsonb)) x),
                           array['drug_licence']);
  v_help jsonb := coalesce((select value from app_settings where key='kyc_help'), '{}'::jsonb);
  v_code text := '';
  v_help_doc text := '';
  v_msg text;
  v_phone text := coalesce(nullif(v_help->>'phone',''), '9329252090');
  v_cc    text := coalesce(nullif(v_help->>'cc',''), '91');
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

  -- The code the support desk asks for on the phone. Its absence is not an
  -- error: the message simply drops that sentence.
  if v_kind = 'pharmacy' then
    select btrim(coalesce(customer_code,'')) into v_code from pharmacy_profiles where id = v_id;
  else
    select btrim(coalesce(supplier_code,'')) into v_code from supplier_profiles where id = v_id;
  end if;
  v_code := coalesce(v_code, '');

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
      -- CMD #1914 — the ONE chip. Four words for four states, plus the two the
      -- applicant still has to be told about (nothing uploaded, expired).
      -- `chip_busy` is the spinner: it spins while the checks are actually
      -- running, and stops the moment there is a verdict to read.
      'chip_state', s.st,
      'chip_label', _c('kyc.chip.'||s.st),
      'chip_tone',  case s.st when 'verified' then 'success'
                              when 'rejected' then 'danger'
                              when 'expired'  then 'danger'
                              when 'checking' then 'info'
                              when 'uploaded' then 'info'
                              else 'warning' end,
      'chip_busy',  (s.st = 'checking'),
      -- CMD #1914 — ONE sentence, and it is chosen here. A human reviewer's
      -- reason is already written for the applicant, so it wins verbatim. An
      -- automatic rejection is translated from the check that failed; the
      -- worksheet that produced it goes behind the link.
      -- `verified_by is null` is this schema's own signal for "the machine
      -- decided it" (kyc_verify_doc sets it null, kyc_review_set sets the
      -- reviewer). A person's reason is written FOR the applicant — the review
      -- console tells the reviewer they see it word for word — so it wins
      -- verbatim. A machine reason is a composed check list and never reaches
      -- the surface: it is translated from the check that failed, and an
      -- untranslated check still yields a sentence rather than a worksheet.
      'plain_reason', case
          when coalesce(d.status,'') <> 'rejected' then ''
          when d.verified_by is not null and btrim(coalesce(d.reason,'')) <> ''
               then _cf('kyc.rejected_prefix',
                        jsonb_build_object('reason', btrim(d.reason)))
          when nullif(_c('kyc.plain.'||coalesce(f.key,'')),'') is not null
               then _c('kyc.plain.'||f.key)
          else _c('kyc.plain.default') end,
      -- The raw rows still exist; they are just no longer the first thing a
      -- pharmacist reads. Empty caption = nothing to fold away.
      'checks_show_label', case when coalesce((v.blk->>'has')::boolean, false)
                                 and jsonb_array_length(coalesce(v.blk->'checks','[]'::jsonb)) > 0
                                then _c('kyc.checks_show') else '' end,
      'checks_hide_label', _c('kyc.checks_hide'),
      'checks_count', jsonb_array_length(coalesce(v.blk->'checks','[]'::jsonb)),
      -- CMD #1914 — the file that was actually uploaded. The screen signs the
      -- path under the applicant's own session; WHICH object, and whether it is
      -- a picture at all, is answered here.
      'preview', case when d.id is null then null else jsonb_build_object(
          'bucket', d.bucket,
          'path', d.path,
          'file_name', coalesce(d.file_name,''),
          'mime', coalesce(d.mime_type,''),
          'is_pdf', (coalesce(d.mime_type,'') ilike '%pdf%'
                     or lower(coalesce(d.path,'')) like '%.pdf'),
          'pdf_label', _c('kyc.preview_pdf'),
          'view_label', _c('kyc.preview_view'),
          'open_label', _c('kyc.preview_open'),
          'error_label', _c('kyc.preview_error')) end,
      'preview_empty_label', _c('kyc.preview_none'),
      -- CMD #1914 — the card's second line, JOINED HERE. The screen prints one
      -- string; which facts belong on it, in what order and with what
      -- separator is a backend decision like every other display decision.
      'meta_line', array_to_string(array_remove(array[
          nullif(case when t.kind = any(v_req) then _c('kyc.required_note')
                      else _c('kyc.optional_note') end, ''),
          case when d.id is null then nullif(_c('kyc.preview_none'),'')
               else nullif(btrim(coalesce(d.file_name,'')),'') end,
          case when coalesce(d.number,'') = '' then null
               else _c('kyc.number_label')||': '||d.number end,
          nullif(case when d.id is null then ''
                      when d.valid_to is null then _c('kyc.no_expiry_label')
                      else _cf('kyc.expiry_label',
                             jsonb_build_object('d', to_char(d.valid_to,'FMDD Mon YYYY'))) end,
                 '')], null), '  ·  '),
      'reason_line', case
          when coalesce(d.reason,'') = '' then ''
          when coalesce(v.blk->>'reason','') = d.reason then ''
          else _cf('kyc.rejected_prefix', jsonb_build_object('reason', d.reason)) end,
      'button_label', case
          when d.id is null then _c('kyc.btn_upload')
          when d.status = 'verified' and d.valid_to is not null
               and d.valid_to < (now() at time zone 'Asia/Kolkata')::date then _c('kyc.btn_renew')
          else _c('kyc.btn_replace') end,
      'verify', coalesce(v.blk, 'null'::jsonb)
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
    left join lateral (
      select case when d.id is null then null
                  else public.kyc_verify_panel(d.id) end as blk) v on true
    -- The check that decides the sentence: a hard failure first, then a warning.
    left join lateral (
      select c->>'key' as key
        from jsonb_array_elements(coalesce(v.blk->'checks','[]'::jsonb)) c
       where c->>'status' in ('fail','warn')
       order by case c->>'status' when 'fail' then 0 else 1 end
       limit 1) f on true
    left join lateral (
      select case
        when d.id is null then 'missing'
        when d.status = 'verified' and d.valid_to is not null
             and d.valid_to < (now() at time zone 'Asia/Kolkata')::date then 'expired'
        when d.status = 'verified' then 'verified'
        when d.status = 'rejected' then 'rejected'
        when coalesce((v.blk->>'has')::boolean, false) = false
             or coalesce(v.blk->>'tier','') = 'awaiting'
             or coalesce(v.blk->>'ocr_status','') in ('queued','running') then 'checking'
        else 'uploaded' end as st) s on true
  ) x;

  -- Which document the WhatsApp message names: the one that is actually in the
  -- applicant's way. A rejection first, then a required document with nothing
  -- on file, then whatever is first.
  select coalesce(
    (select i->>'label' from jsonb_array_elements(v_rows) i
      where i->>'chip_state' = 'rejected' limit 1),
    (select i->>'label' from jsonb_array_elements(v_rows) i
      where i->>'chip_state' = 'missing' and (i->>'required')::boolean limit 1),
    (select i->>'label' from jsonb_array_elements(v_rows) i limit 1),
    '')
  into v_help_doc;

  v_msg := case when v_code = ''
    then _cf('kyc.help_wa_message_nocode', jsonb_build_object('doc', v_help_doc))
    else _cf('kyc.help_wa_message',
             jsonb_build_object('doc', v_help_doc, 'code', v_code)) end;

  return jsonb_build_object(
    'ok', true,
    'title', _c('kyc.title'),
    'subtitle', _c('kyc.subtitle'),
    'empty_note', _c('kyc.empty_note'),
    'bucket', 'kyc-docs',
    'upload_prefix', auth.uid()::text,
    'owner_kind', v_kind,
    'owner_id', v_id,
    'customer_code', v_code,
    'state', v_state,
    'verify_title', _c('kyc_verify.title'),
    -- CMD #1914 — one tap each. Both URLs are finished here: the app launches
    -- the string it was handed and composes nothing.
    'help', jsonb_build_object(
      'title', _c('kyc.help_title'),
      'note',  _c('kyc.help_note'),
      'call_label', _cf('kyc.help_call',
                      jsonb_build_object('phone',
                        coalesce(nullif(v_help->>'display',''), v_phone))),
      'call_url', 'tel:+'||v_cc||v_phone,
      'wa_label', _c('kyc.help_wa'),
      'wa_message', v_msg,
      'wa_url', 'https://wa.me/'||v_cc||v_phone||'?text='||public._url_encode(v_msg)),
    'wa_timeline', public._cus_wa_timeline(v_kind, v_id, 5),
    'items', v_rows);
end $function$

;

-- Grant posture, restated rather than assumed. CREATE OR REPLACE keeps the ACL
-- a function already had, and live already denies anon here (probed: 42501) —
-- but a branch that was cut before the lockdown has a NULL acl, i.e. PUBLIC
-- EXECUTE, so the branch and live must be told the same thing (lesson 122).
revoke execute on function public.kyc_my_panel() from public;
revoke execute on function public.kyc_my_panel() from anon;
grant  execute on function public.kyc_my_panel() to authenticated;
grant  execute on function public.kyc_my_panel() to service_role;
