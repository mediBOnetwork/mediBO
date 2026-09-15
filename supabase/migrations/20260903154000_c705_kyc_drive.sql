-- CHANGE #705 (5/5) — the backfill drive.
--
-- Ten approved pharmacies and thirty-six approved suppliers are trading today
-- with no document on file. They are not going to install an app to fix that,
-- so each one gets ONE WhatsApp message with a link they can open in the
-- WhatsApp browser and upload from: /kyc-upload/<token>, PUBLIC and anonymous
-- exactly like /stock-update/<token> — the token IS the authorisation.
--
-- The deadline in the message is the grace date the gate already enforces, so
-- the message and the block can never disagree. Admin sees one progress card.
-- Idempotent throughout.

create table if not exists public.kyc_upload_token (
  token       text primary key,
  owner_kind  text not null check (owner_kind in ('pharmacy','supplier')),
  owner_id    uuid not null,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  opened_at   timestamptz,
  used_at     timestamptz,
  expires_at  timestamptz not null default now() + interval '30 days'
);

create index if not exists kyc_upload_token_owner_idx
  on public.kyc_upload_token (owner_kind, owner_id, created_at desc);

comment on table public.kyc_upload_token is
  'CHANGE #705 — one public upload link per pharmacy/supplier in the backfill '
  'drive. Anonymous by design: the token in the URL is the authorisation, the '
  'same contract /stock-update/<token> and /feedback/<token> already have.';

alter table public.kyc_upload_token enable row level security;

insert into public.ui_copy (key, value) values
  ('kyc_token.title',       to_jsonb('Upload your licence'::text)),
  ('kyc_token.subtitle',    to_jsonb('mediBO needs a copy of your drug licence to keep your account trading.'::text)),
  ('kyc_token.for_label',   to_jsonb('For {name}'::text)),
  ('kyc_token.deadline',    to_jsonb('Please upload before {d}.'::text)),
  ('kyc_token.number_hint', to_jsonb('Licence number as printed'::text)),
  ('kyc_token.expiry_hint', to_jsonb('Valid until (as printed)'::text)),
  ('kyc_token.file_hint',   to_jsonb('Photo or PDF of the licence'::text)),
  ('kyc_token.submit',      to_jsonb('Submit'::text)),
  ('kyc_token.done_title',  to_jsonb('Thank you'::text)),
  ('kyc_token.done_body',   to_jsonb('We have your licence. We will verify it and let you know on WhatsApp.'::text)),
  ('kyc_token.err_unknown', to_jsonb('This link is not valid. Please ask mediBO for a new one.'::text)),
  ('kyc_token.err_expired', to_jsonb('This link has expired. Please ask mediBO for a new one.'::text)),
  ('kyc_token.err_used',    to_jsonb('This link has already been used. Thank you.'::text)),
  ('kyc_drive.title',       to_jsonb('Licence backfill'::text)),
  ('kyc_drive.subtitle',    to_jsonb('Approved accounts trading without a verified drug licence.'::text)),
  ('kyc_drive.btn_send',    to_jsonb('Send upload links'::text)),
  ('kyc_drive.sent_toast',  to_jsonb('{n} link(s) sent.'::text)),
  ('kyc_drive.progress',    to_jsonb('{done} of {total} verified'::text)),
  ('kyc_drive.pending_label', to_jsonb('{n} waiting for review'::text)),
  ('kyc_drive.deadline_label', to_jsonb('Blocks from {d}'::text)),
  ('kyc_drive.err_not_authorized', to_jsonb('Only an admin may run the backfill drive.'::text))
on conflict (key) do nothing;

insert into public.wa_event_routes (event_key, label, description, audience, enabled,
                                    push_enabled, push_title, push_body)
values
  ('kyc_backfill_request', 'KYC backfill request',
   'One message to an approved pharmacy or supplier that has no drug licence on file, carrying its own upload link and the deadline.',
   'customer', true, true, 'Upload your drug licence',
   'mediBO needs a copy of {{name}}''s drug licence to keep your account trading. Upload it here: {{link}} — before {{d}}.')
on conflict (event_key) do nothing;

-- ── the public page ────────────────────────────────────────────────────────
create or replace function public.kyc_token_form(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare t kyc_upload_token%rowtype; v_name text; v_state jsonb;
begin
  select * into t from kyc_upload_token where token = btrim(coalesce(p_token,''));
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown',
      'title', _c('kyc_token.title'), 'message', _c('kyc_token.err_unknown'));
  end if;
  if t.expires_at < now() then
    return jsonb_build_object('ok', false, 'error','expired',
      'title', _c('kyc_token.title'), 'message', _c('kyc_token.err_expired'));
  end if;

  if t.owner_kind = 'pharmacy' then
    select pharmacy_name into v_name from pharmacy_profiles where id = t.owner_id;
  else
    select supplier_name into v_name from supplier_profiles where id = t.owner_id;
  end if;

  update kyc_upload_token set opened_at = coalesce(opened_at, now()) where token = t.token;
  v_state := public.kyc_state(t.owner_kind, t.owner_id);

  return jsonb_build_object(
    'ok', true,
    'token', t.token,
    'title', _c('kyc_token.title'),
    'subtitle', _c('kyc_token.subtitle'),
    'for_line', _cf('kyc_token.for_label', jsonb_build_object('name', coalesce(v_name,''))),
    'deadline_line', case when (v_state->>'grace_until') is null then ''
                          else _cf('kyc_token.deadline', jsonb_build_object(
                                 'd', to_char((v_state->>'grace_until')::date,'FMDD Mon YYYY'))) end,
    'kind', 'drug_licence',
    'kind_label', _c('kyc.kind.drug_licence'),
    'number_label', _c('kyc.number_label'),
    'number_hint', _c('kyc_token.number_hint'),
    'expiry_hint', _c('kyc_token.expiry_hint'),
    'file_hint', _c('kyc_token.file_hint'),
    'submit_label', _c('kyc_token.submit'),
    'done_title', _c('kyc_token.done_title'),
    'done_body', _c('kyc_token.done_body'),
    'bucket', 'kyc-docs',
    'upload_prefix', 'token/'||t.token,
    'already_done', (t.used_at is not null),
    'used_message', _c('kyc_token.err_used'),
    'state', v_state);
end
$fn$;

create or replace function public.kyc_token_submit(
  p_token text, p_path text, p_number text default null,
  p_valid_to date default null, p_file_name text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare t kyc_upload_token%rowtype; v_zone smallint; v_doc uuid;
begin
  select * into t from kyc_upload_token where token = btrim(coalesce(p_token,''));
  if not found then
    return jsonb_build_object('ok', false, 'error','unknown', 'tone','danger',
      'message', _c('kyc_token.err_unknown'));
  end if;
  if t.expires_at < now() then
    return jsonb_build_object('ok', false, 'error','expired', 'tone','danger',
      'message', _c('kyc_token.err_expired'));
  end if;
  if nullif(btrim(coalesce(p_path,'')),'') is null then
    return jsonb_build_object('ok', false, 'error','no_path', 'tone','danger',
      'message', _c('kyc.err_no_path'));
  end if;
  if p_valid_to is not null and p_valid_to < (now() at time zone 'Asia/Kolkata')::date then
    return jsonb_build_object('ok', false, 'error','expiry_past', 'tone','danger',
      'message', _c('kyc.err_expiry_past'));
  end if;

  if t.owner_kind = 'pharmacy' then
    select zone_id into v_zone from pharmacy_profiles where id = t.owner_id;
  else
    select zone_id into v_zone from supplier_profiles where id = t.owner_id;
  end if;

  update kyc_documents set status = 'superseded', updated_at = now()
   where owner_kind = t.owner_kind and owner_id = t.owner_id
     and kind = 'drug_licence' and status in ('pending','verified');

  insert into kyc_documents(owner_kind, owner_id, kind, path, file_name, number,
                            valid_to, zone_id, source)
  values (t.owner_kind, t.owner_id, 'drug_licence', btrim(p_path),
          nullif(btrim(coalesce(p_file_name,'')),''),
          nullif(btrim(coalesce(p_number,'')),''), p_valid_to, v_zone, 'token')
  returning id into v_doc;

  if t.owner_kind = 'pharmacy' then
    update pharmacy_profiles
       set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
           dl_expiry    = coalesce(p_valid_to, dl_expiry)
     where id = t.owner_id;
  else
    update supplier_profiles
       set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
           dl_expiry    = coalesce(p_valid_to, dl_expiry)
     where id = t.owner_id;
  end if;

  update kyc_upload_token set used_at = now() where token = t.token;

  return jsonb_build_object('ok', true, 'tone','success', 'doc_id', v_doc,
    'title', _c('kyc_token.done_title'), 'message', _c('kyc_token.done_body'));
end
$fn$;

-- The public page is opened from a WhatsApp browser with no session. Same
-- contract as /stock-update/<token> and /feedback/<token>.
grant execute on function public.kyc_token_form(text) to anon, authenticated;
grant execute on function public.kyc_token_submit(text,text,text,date,text) to anon, authenticated;

-- Anonymous upload goes into the token's own folder and nowhere else.
drop policy if exists kyc_docs_token_write on storage.objects;
create policy kyc_docs_token_write on storage.objects
  for insert to anon
  with check (bucket_id = 'kyc-docs'
              and (storage.foldername(name))[1] = 'token'
              and exists (select 1 from public.kyc_upload_token t
                           where t.token = (storage.foldername(name))[2]
                             and t.expires_at > now()));

-- ── the drive ──────────────────────────────────────────────────────────────
create or replace function public.kyc_drive_card()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_cfg jsonb := coalesce((select value from app_settings where key='kyc_gate'), '{}'::jsonb);
  v_deadline date := coalesce((v_cfg->>'enforced_from')::date, date '2026-09-03')
                     + coalesce((v_cfg->>'grace_days')::int, 14);
  v_rows jsonb; v_total int; v_done int; v_pending int; v_sent int;
begin
  if not public.kyc_can_review('read') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'title', _c('kyc_drive.title'), 'message', _c('kyc_drive.err_not_authorized'));
  end if;

  with pop as (
    select 'pharmacy'::text as owner_kind, p.id, p.pharmacy_name as name,
           coalesce(nullif(p.whatsapp_no,''), p.phone) as phone
      from pharmacy_profiles p
     where coalesce(p.approved,false) and not coalesce(p.is_deleted,false)
    union all
    select 'supplier', s.id, s.supplier_name, coalesce(nullif(s.whatsapp_no,''), s.phone)
      from supplier_profiles s
     where coalesce(s.approved,false) and not coalesce(s.is_deleted,false)
  ), st as (
    select pop.*, public.kyc_state(pop.owner_kind, pop.id) as k,
           (select max(sent_at) from kyc_upload_token t
             where t.owner_kind = pop.owner_kind and t.owner_id = pop.id) as last_sent
      from pop
  )
  select count(*)::int,
         count(*) filter (where k->>'state' = 'verified')::int,
         count(*) filter (where k->>'state' = 'pending')::int,
         count(*) filter (where last_sent is not null)::int,
         coalesce(jsonb_agg(jsonb_build_object(
            'owner_kind', owner_kind, 'owner_id', id,
            'name', coalesce(name,''), 'has_phone', (coalesce(phone,'') <> ''),
            'state', k->>'state',
            'state_label', _c('kyc.status.'||case k->>'state' when 'verified' then 'verified'
                                                              when 'pending' then 'pending'
                                                              when 'rejected' then 'rejected'
                                                              when 'expired' then 'expired'
                                                              else 'missing' end),
            'state_tone', case k->>'state' when 'verified' then 'success'
                                           when 'pending' then 'info'
                                           else 'warning' end,
            'link_sent', (last_sent is not null))
            order by (k->>'state' = 'verified'), owner_kind, name)
           filter (where k->>'state' <> 'verified'), '[]'::jsonb)
    into v_total, v_done, v_pending, v_sent, v_rows
  from st;

  return jsonb_build_object(
    'ok', true,
    'title', _c('kyc_drive.title'),
    'subtitle', _c('kyc_drive.subtitle'),
    'send_label', _c('kyc_drive.btn_send'),
    'can_send', (public.role_for_medibo_only() in ('admin','super_admin')),
    'progress_label', _cf('kyc_drive.progress',
                        jsonb_build_object('done', v_done, 'total', v_total)),
    'pending_label', _cf('kyc_drive.pending_label', jsonb_build_object('n', v_pending)),
    'deadline_label', _cf('kyc_drive.deadline_label',
                        jsonb_build_object('d', to_char(v_deadline,'FMDD Mon YYYY'))),
    'total', v_total, 'verified', v_done, 'pending', v_pending, 'links_sent', v_sent,
    'outstanding', v_total - v_done,
    'rows', v_rows);
end
$fn$;

create or replace function public.kyc_drive_send(p_owner_kind text default null,
                                                 p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_cfg jsonb := coalesce((select value from app_settings where key='kyc_gate'), '{}'::jsonb);
  v_deadline date := coalesce((v_cfg->>'enforced_from')::date, date '2026-09-03')
                     + coalesce((v_cfg->>'grace_days')::int, 14);
  r record; v_token text; v_sent int := 0; v_skipped int := 0;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('kyc_drive.err_not_authorized'));
  end if;

  for r in
    select 'pharmacy'::text as owner_kind, p.id, p.pharmacy_name as name,
           coalesce(nullif(p.whatsapp_no,''), p.phone) as phone
      from pharmacy_profiles p
     where coalesce(p.approved,false) and not coalesce(p.is_deleted,false)
       and (p_owner_kind is null or p_owner_kind = 'pharmacy')
    union all
    select 'supplier', s.id, s.supplier_name, coalesce(nullif(s.whatsapp_no,''), s.phone)
      from supplier_profiles s
     where coalesce(s.approved,false) and not coalesce(s.is_deleted,false)
       and (p_owner_kind is null or p_owner_kind = 'supplier')
    limit greatest(coalesce(p_limit,100),1)
  loop
    if coalesce((public.kyc_state(r.owner_kind, r.id)->>'state'),'') = 'verified' then
      continue;                                   -- already clear: no message
    end if;
    if coalesce(r.phone,'') = '' then
      v_skipped := v_skipped + 1; continue;       -- nowhere to send it
    end if;

    -- One live link per account: reuse an unused, unexpired one rather than
    -- flooding a pharmacy with a new URL every time an admin taps the button.
    select token into v_token from kyc_upload_token
     where owner_kind = r.owner_kind and owner_id = r.id
       and used_at is null and expires_at > now()
     order by created_at desc limit 1;

    if v_token is null then
      v_token := replace(gen_random_uuid()::text, '-', '');
      insert into kyc_upload_token(token, owner_kind, owner_id)
      values (v_token, r.owner_kind, r.id);
    end if;

    begin
      perform public.wa_send_event('kyc_backfill_request',
        case when r.owner_kind = 'pharmacy' then r.id else null end,
        jsonb_build_object('name', coalesce(r.name,''),
                           'link', 'https://medibo.in/kyc-upload/'||v_token,
                           'd', to_char(v_deadline,'DD/MM/YYYY')),
        r.phone, null);
    exception when others then null;
    end;

    update kyc_upload_token set sent_at = now() where token = v_token;
    v_sent := v_sent + 1;
  end loop;

  return jsonb_build_object('ok', true, 'tone','success',
    'sent', v_sent, 'skipped_no_phone', v_skipped,
    'message', _cf('kyc_drive.sent_toast', jsonb_build_object('n', v_sent)),
    'card', public.kyc_drive_card());
end
$fn$;

grant execute on function public.kyc_drive_card() to authenticated;
grant execute on function public.kyc_drive_send(text,integer) to authenticated;
