-- CMD #1914 — the document upload screen stops reading like a debug log.
--
-- Before this, the applicant's panel printed the machine's worksheet: raw check
-- names ("GSTIN format", "Document readable"), a red paragraph composed from
-- them, "Decided 10m ago · Automatic", and no sight of the file that had
-- actually been uploaded. Every one of those strings was correct and none of
-- them told a pharmacist what to do next.
--
-- What the panel says now is decided HERE, not in Dart:
--   * one chip per document — Uploaded / Checking / Verified / Rejected — with
--     `chip_busy` saying whether the spinner spins;
--   * ONE plain sentence for a rejection (`plain_reason`), chosen from the
--     failing check, never the composed check list;
--   * the raw checks move behind a link whose caption is also copy;
--   * a preview descriptor (bucket, path, mime) so the screen can show the
--     file that was uploaded and open it full;
--   * a troubleshooting block with a tel: URL and a wa.me URL that is already
--     built, already url-encoded and already carries the customer code and the
--     document type — one tap, nothing composed client-side.
--
-- Plus the read-only WhatsApp timeline row (the frontend half of #1915): a
-- `customer_event` ledger that the lifecycle sender writes to, and one builder
-- that renders it for BOTH the applicant's upload screen and the admin
-- customer page, so the two can never disagree about what went out.
--
-- Idempotent: copy inserts are `on conflict do nothing` (wording is Om's to
-- edit, never a redeploy's to overwrite), the table is `if not exists`, the
-- functions are `create or replace`.

-- ── 1. Copy ───────────────────────────────────────────────────────────────
insert into ui_copy(key, value) values
  -- the one chip
  ('kyc.chip.missing',      '"Not uploaded"'::jsonb),
  ('kyc.chip.checking',     '"Checking"'::jsonb),
  ('kyc.chip.uploaded',     '"Uploaded"'::jsonb),
  ('kyc.chip.verified',     '"Verified"'::jsonb),
  ('kyc.chip.rejected',     '"Rejected"'::jsonb),
  ('kyc.chip.expired',      '"Expired"'::jsonb),

  -- the checks, folded away
  ('kyc.checks_show',       '"See checks"'::jsonb),
  ('kyc.checks_hide',       '"Hide checks"'::jsonb),

  -- the file itself
  ('kyc.preview_view',      '"View"'::jsonb),
  ('kyc.preview_open',      '"Open file"'::jsonb),
  ('kyc.preview_error',     '"Preview unavailable"'::jsonb),
  ('kyc.preview_pdf',       '"PDF"'::jsonb),
  ('kyc.preview_none',      '"No file yet"'::jsonb),

  -- ONE sentence per rejection, keyed by the check that failed. These are the
  -- only rejection words an applicant sees; the worksheet lives behind the
  -- link. Each one names the fix, because a reason without a next step is the
  -- same dead end as the red paragraph this change removes.
  ('kyc.plain.default',        '"We could not verify this document — upload a clearer photo of the whole page."'::jsonb),
  ('kyc.plain.ocr_read',       '"We could not read the document — upload a clearer photo of the whole page."'::jsonb),
  ('kyc.plain.gstin_format',   '"GSTIN could not be read — upload a clearer photo."'::jsonb),
  ('kyc.plain.gstin_checksum', '"The GSTIN on this certificate is not a valid number — upload the correct certificate."'::jsonb),
  ('kyc.plain.gstin_state',    '"This GSTIN belongs to another state — upload the certificate for this shop."'::jsonb),
  ('kyc.plain.gstin_name',     '"The name on the certificate is not your business name — upload the certificate in your own name."'::jsonb),
  ('kyc.plain.gstin_pan',      '"The PAN on this certificate does not match your PAN card — upload the matching documents."'::jsonb),
  ('kyc.plain.pan_format',     '"The PAN could not be read — upload a clearer photo of the PAN card."'::jsonb),
  ('kyc.plain.expiry',         '"This document has expired — upload the renewed one."'::jsonb),
  ('kyc.plain.ocr_expiry',     '"The validity date on the document does not match what you entered — check the date and upload again."'::jsonb),
  ('kyc.plain.ocr_number',     '"The number on the document does not match what you entered — check it and upload again."'::jsonb),
  ('kyc.plain.ocr_name',       '"The document is not in your business name — upload the one for this shop."'::jsonb),
  ('kyc.plain.dup_dl',         '"This licence number is already registered to another account — call us and we will sort it out."'::jsonb),
  ('kyc.plain.dup_gstin',      '"This GSTIN is already registered to another account — call us and we will sort it out."'::jsonb),
  ('kyc.plain.geo',            '"The address on the document is far from your shop location — call us and we will sort it out."'::jsonb),

  -- troubleshooting
  ('kyc.help_title',        '"Stuck? We will do it for you"'::jsonb),
  ('kyc.help_note',         '"Call us, or send the photo on WhatsApp and we will upload it."'::jsonb),
  ('kyc.help_call',         '"Call {phone}"'::jsonb),
  ('kyc.help_wa',           '"WhatsApp"'::jsonb),
  ('kyc.help_wa_message',   '"Hi mediBO, I need help with my {doc}. Customer code: {code}."'::jsonb),
  ('kyc.help_wa_message_nocode', '"Hi mediBO, I need help with my {doc}."'::jsonb),

  -- the WhatsApp timeline row (frontend half of the #1915 lifecycle work)
  ('cust_wa.title',         '"WhatsApp"'::jsonb),
  ('cust_wa.empty',         '"No WhatsApp message has gone out yet."'::jsonb),
  ('cust_wa.sent',          '"WhatsApp sent: {label}"'::jsonb),
  ('cust_wa.skipped',       '"WhatsApp not sent: {label}"'::jsonb),
  ('cust_wa.failed',        '"WhatsApp failed: {label}"'::jsonb),
  ('cust_wa.reason_none',   '"No reason recorded."'::jsonb)
on conflict (key) do nothing;

-- ── 2. The help number is a setting, not a literal ────────────────────────
-- Changing who answers the phone must be an UPDATE, never a deploy.
insert into app_settings(key, value)
values ('kyc_help', '{"phone":"9329252090","display":"93292 52090","cc":"91"}'::jsonb)
on conflict (key) do nothing;

-- ── 3. customer_event — the ledger the lifecycle sender writes to ─────────
-- #1915 owns the writing. This command owns the READING, and a reader with no
-- table is a screen that can never be wired, so the table lands here. RLS is on
-- with no policy: every read goes through a SECURITY DEFINER builder that has
-- already decided the caller may see this customer.
create table if not exists public.customer_event (
  id          bigserial primary key,
  owner_kind  text        not null default 'pharmacy',
  owner_id    uuid        not null,
  kind        text        not null,
  event_key   text        not null default '',
  event_label text        not null default '',
  ok          boolean     not null default true,
  reason      text        not null default '',
  meta        jsonb       not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists customer_event_owner_idx
  on public.customer_event(owner_kind, owner_id, created_at desc);
create index if not exists customer_event_kind_idx
  on public.customer_event(kind, created_at desc);
alter table public.customer_event enable row level security;

comment on table public.customer_event is
  'CMD #1914 — per-customer lifecycle ledger. kind: wa_sent | wa_skipped | wa_failed. '
  'event_label is the human name of the lifecycle event ("Approved"); reason is the '
  'plain skip/failure sentence. Rendered by _cus_wa_timeline() for the customer page '
  'and the document upload screen. Written by the lifecycle sender (#1915).';

-- ── 4. One builder, two screens ───────────────────────────────────────────
-- The applicant's upload screen and the admin customer page print the same
-- facts, so they read the same function. `line` is the whole row pre-composed
-- ("WhatsApp sent: Approved · 2 Sep 4:12 PM") for the single-line surface;
-- title/subtitle/when are the same facts split for the timeline block that the
-- customer page already knows how to draw.
create or replace function public._cus_wa_timeline(
  p_owner_kind text, p_owner_id uuid, p_limit int default 5)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'kind',    'timeline',
    'section', 'whatsapp',
    'title',   _c('cust_wa.title'),
    'empty',   _c('cust_wa.empty'),
    'items',   coalesce(jsonb_agg(x.item order by x.created_at desc), '[]'::jsonb))
  from (
    select e.created_at,
           jsonb_build_object(
             'title', t.title,
             'subtitle', case when e.kind = 'wa_sent' then ''
                              when btrim(e.reason) = '' then _c('cust_wa.reason_none')
                              else e.reason end,
             'when', t.when_label,
             'line', t.title || ' · ' || t.when_label,
             'tone', case e.kind when 'wa_sent' then 'success'
                                 when 'wa_skipped' then 'warning'
                                 else 'danger' end) as item
      from public.customer_event e
      cross join lateral (
        select _cf(case e.kind when 'wa_sent'    then 'cust_wa.sent'
                               when 'wa_skipped' then 'cust_wa.skipped'
                               else 'cust_wa.failed' end,
                   jsonb_build_object('label',
                     coalesce(nullif(btrim(e.event_label),''), e.event_key))) as title,
               to_char(e.created_at at time zone 'Asia/Kolkata',
                       'FMDD Mon FMHH12:MI AM') as when_label) t
     where e.owner_kind = p_owner_kind
       and e.owner_id   = p_owner_id
       and e.kind in ('wa_sent','wa_skipped','wa_failed')
     order by e.created_at desc
     limit greatest(p_limit, 1)) x;
$$;

-- ── 5. The panel ──────────────────────────────────────────────────────────
create or replace function public.kyc_my_panel()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
               then btrim(d.reason)
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
end $function$;

-- ── 6. The same row on the customer page ──────────────────────────────────
create or replace function public.admin_customer_tab_profile(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role text := public._cus810_gate();
  pp pharmacy_profiles%rowtype;
  v_kyc jsonb; v_state jsonb; v_docs jsonb;
  v_can_write boolean;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if v_role = 'none' then return public._cus810_deny(false); end if;
  pp := public._cus810_row(p_customer_id);
  if pp.id is null then return public._cus810_deny(false); end if;

  v_kyc   := public._cus810_kyc(pp.id, pp.gstin, pp.gst_no);
  v_state := public.kyc_state('pharmacy', pp.id);
  v_can_write := public.kyc_can_review('write');

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(public._c('kyc.kind.'||d.kind),''),
                             initcap(replace(d.kind,'_',' '))),
           'subtitle', array_to_string(array_remove(array[
                         nullif(btrim(coalesce(d.file_name,'')),''),
                         nullif(btrim(coalesce(d.number,'')),'')], null), '  ·  '),
           'meta', array_to_string(array_remove(array[
                     nullif(replace(public._c('admin_cus2.p_uploaded'), '{age}',
                                    public._ist_age(d.submitted_at)),''),
                     case when d.valid_to is null then public._c('admin_cus2.p_no_expiry')
                          else to_char(d.valid_to,'FMDD Mon YYYY') end,
                     nullif(btrim(coalesce(d.reason,'')),'')], null), '  ·  '),
           'chip', jsonb_build_object(
             'show', true,
             'label', coalesce(nullif(public._c('kyc.status.'||d.status),''),
                               initcap(replace(d.status,'_',' '))),
             'bg',     case when d.status = 'verified' and (d.valid_to is null or d.valid_to >= v_today) then '#D1FAE5'
                            when d.status in ('rejected','verified') then '#FEE2E2'
                            when d.status = 'pending' then '#EFF6FF' else '#F3F4F6' end,
             'fg',     case when d.status = 'verified' and (d.valid_to is null or d.valid_to >= v_today) then '#065F46'
                            when d.status in ('rejected','verified') then '#991B1B'
                            when d.status = 'pending' then '#1E40AF' else '#4B5563' end,
             'border', case when d.status = 'verified' and (d.valid_to is null or d.valid_to >= v_today) then '#A7F3D0'
                            when d.status in ('rejected','verified') then '#FECACA'
                            when d.status = 'pending' then '#BFDBFE' else '#E5E7EB' end),
           'actions', case when d.status = 'pending' and v_can_write then jsonb_build_array(
               jsonb_build_object(
                 'label', public._c('kyc_review.btn_verify'),
                 'tone',  'success',
                 'rpc',   'kyc_review_set',
                 'args',  jsonb_build_object('p_doc_id', d.id, 'p_status', 'verified')),
               jsonb_build_object(
                 'label', public._c('kyc_review.btn_reject'),
                 'tone',  'danger',
                 'rpc',   'kyc_review_set',
                 'args',  jsonb_build_object('p_doc_id', d.id, 'p_status', 'rejected'),
                 'confirm', jsonb_build_object(
                   'title',        public._c('admin_cus2.p_reject_title'),
                   'body',         public._c('admin_cus2.p_reject_body'),
                   'ok',           public._c('admin_cus2.p_reject_ok'),
                   'cancel',       public._c('admin_cus2.p_reject_cancel'),
                   'needs_reason', true,
                   'reason_arg',   'p_reason',
                   'reason_hint',  public._c('kyc_review.reason_hint'),
                   'reason_error', public._c('kyc_review.err_no_reason'))))
             else '[]'::jsonb end)
         order by (d.status <> 'pending'), d.submitted_at desc nulls last), '[]'::jsonb)
    into v_docs
    from public.kyc_documents d
   where d.owner_kind in ('pharmacy','customer')
     and d.owner_id = pp.id
     and d.status <> 'superseded';

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','kv','title', public._c('admin_cus2.p_status'),
      'section','kyc',
      'chip', v_kyc->'chip',
      'rows', jsonb_build_array(
        public._cus810_kv(public._c('admin_cus2.p_state'),
                          coalesce(nullif(public._c('kyc.status.'||coalesce(v_state->>'state','')),''),
                                   v_kyc->'chip'->>'label')),
        public._cus810_kv(public._c('admin_cus2.p_licence'),
                          coalesce(nullif(v_kyc->>'licence',''),
                                   nullif(btrim(coalesce(pp.dl_20b,'')),''),
                                   nullif(btrim(coalesce(pp.dl_21b,'')),''),
                                   pp.drug_license)),
        public._cus810_kv(public._c('admin_cus2.p_expiry'),
                          coalesce(nullif(v_state->>'expiry_label',''), v_kyc->>'expiry_label')),
        public._cus810_kv(public._c('admin_cus2.p_gstin'),
                          coalesce(nullif(btrim(coalesce(pp.gstin,'')),''), pp.gst_no)))),
    jsonb_build_object('kind','list','title', public._c('admin_cus2.p_docs'),
      'section','documents',
      'empty', public._c('admin_cus2.p_docs_empty'),
      'items', v_docs),
    -- CMD #1914 — what WhatsApp actually went out, read-only, same builder as
    -- the applicant's own upload screen.
    public._cus_wa_timeline('pharmacy', pp.id, 10)));
end $function$;

grant execute on function public._cus_wa_timeline(text, uuid, int) to authenticated, service_role;
