-- CMD #1889 — Customer documents: the drug-licence EXPIRY becomes a real date.
--
-- Before this, dl_expiry was null on every profile, so kyc_expiry_sweep had
-- nothing to sweep. The date now arrives three ways and only three ways:
--   1. OCR reads valid_to off the licence and fills the document when it is blank
--   2. a reviewer confirms or corrects it in KYC review — a correction needs a reason
--   3. whatever lands on the DOCUMENT is mirrored onto the owner's profile by a
--      trigger, so no caller has to remember to do it
-- Every string below is backend copy; Flutter renders it.

-- ── the audit of a hand-typed date ─────────────────────────────────────────
create table if not exists public.kyc_doc_field_edit (
  id          bigserial primary key,
  doc_id      uuid not null references public.kyc_documents(id) on delete cascade,
  owner_kind  text not null,
  owner_id    uuid,
  field       text not null,
  old_value   text,
  new_value   text,
  source      text not null default 'manual',
  reason      text,
  actor       uuid,
  created_at  timestamptz not null default now()
);
create index if not exists kyc_doc_field_edit_doc_idx on public.kyc_doc_field_edit(doc_id, created_at desc);
alter table public.kyc_doc_field_edit enable row level security;

-- where the profile's date came from, so the review screen can say so
alter table public.pharmacy_profiles add column if not exists dl_expiry_source text;
alter table public.supplier_profiles add column if not exists dl_expiry_source text;

-- ── the mirror: document valid_to -> profile dl_expiry ─────────────────────
create or replace function public._kyc_sync_owner_expiry(p_owner_kind text, p_owner_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare v_exp date; v_src text; v_kind text := lower(btrim(coalesce(p_owner_kind,'')));
begin
  if p_owner_id is null then return; end if;
  -- the licence that is actually in force: a verified one wins over a pending
  -- one, and the most recently submitted wins within each.
  select d.valid_to,
         case when d.status = 'verified' then 'document' else 'document_pending' end
    into v_exp, v_src
    from public.kyc_documents d
   where d.owner_kind = v_kind and d.owner_id = p_owner_id
     and d.kind = 'drug_licence'
     and d.status in ('verified','pending')
     and d.valid_to is not null
   order by (d.status = 'verified') desc, d.submitted_at desc nulls last
   limit 1;
  if v_exp is null then return; end if;      -- never erase a date we cannot better
  if v_kind = 'pharmacy' then
    update public.pharmacy_profiles
       set dl_expiry = v_exp, dl_expiry_source = v_src
     where id = p_owner_id
       and (dl_expiry is distinct from v_exp or dl_expiry_source is distinct from v_src);
  elsif v_kind = 'supplier' then
    update public.supplier_profiles
       set dl_expiry = v_exp, dl_expiry_source = v_src
     where id = p_owner_id
       and (dl_expiry is distinct from v_exp or dl_expiry_source is distinct from v_src);
  end if;
end $fn$;

create or replace function public._kyc_doc_expiry_mirror_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if new.kind = 'drug_licence' then
    perform public._kyc_sync_owner_expiry(new.owner_kind, new.owner_id);
  end if;
  return null;
end $fn$;

drop trigger if exists kyc_doc_expiry_mirror on public.kyc_documents;
create trigger kyc_doc_expiry_mirror
  after insert or update of valid_to, status on public.kyc_documents
  for each row execute function public._kyc_doc_expiry_mirror_trg();

-- ── OCR fills a BLANK document; it never overwrites a human ────────────────
create or replace function public._kyc_apply_ocr_fields(p_doc_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  d public.kyc_documents%rowtype;
  x public.kyc_doc_extract%rowtype;
  v_num text; v_exp date; v_did_num boolean := false; v_did_exp boolean := false;
begin
  select * into d from public.kyc_documents where id = p_doc_id;
  if not found or d.kind <> 'drug_licence' then
    return jsonb_build_object('ok', true, 'applied', false);
  end if;
  select * into x from public.kyc_doc_extract where doc_id = p_doc_id;
  if not found or x.status <> 'done' then
    return jsonb_build_object('ok', true, 'applied', false);
  end if;

  v_num := nullif(btrim(coalesce(x.fields->>'licence_number','')),'');
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
end $fn$;

-- kyc_ocr_ingest, unchanged except that a finished read now FILLS the document
-- before the checks are re-run — so the reviewer sees a date, not a blank.
create or replace function public.kyc_ocr_ingest(p_doc_id uuid, p_status text,
  p_fields jsonb default '{}'::jsonb, p_geo jsonb default '{}'::jsonb,
  p_raw text default null, p_model text default null, p_error text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_status text := lower(btrim(coalesce(p_status,'done')));
begin
  if not exists (select 1 from kyc_documents where id = p_doc_id) then
    return jsonb_build_object('ok', false, 'error','no_doc');
  end if;
  if v_status not in ('running','done','failed','skipped') then v_status := 'done'; end if;

  insert into kyc_doc_extract(doc_id, owner_kind, owner_id, kind, status, fields, geo,
                              raw_text, model, error, attempts, completed_at, updated_at)
  select p_doc_id, d.owner_kind, d.owner_id, d.kind, v_status,
         coalesce(p_fields,'{}'::jsonb), coalesce(p_geo,'{}'::jsonb),
         left(coalesce(p_raw,''), 8000), p_model, p_error, 1,
         case when v_status in ('done','failed','skipped') then now() end, now()
    from kyc_documents d where d.id = p_doc_id
  on conflict (doc_id) do update
     set status = excluded.status,
         fields = case when excluded.status = 'done' then excluded.fields
                       else kyc_doc_extract.fields end,
         geo    = case when excluded.status = 'done' then excluded.geo
                       else kyc_doc_extract.geo end,
         raw_text = coalesce(excluded.raw_text, kyc_doc_extract.raw_text),
         model  = coalesce(excluded.model, kyc_doc_extract.model),
         error  = excluded.error,
         attempts = kyc_doc_extract.attempts + 1,
         completed_at = excluded.completed_at,
         updated_at = now();

  if v_status = 'running' then
    return jsonb_build_object('ok', true, 'status', v_status);
  end if;

  -- CMD #1889 — the read is only useful once it is ON the document.
  if v_status = 'done' then
    begin perform public._kyc_apply_ocr_fields(p_doc_id); exception when others then null; end;
  end if;

  return public.kyc_verify_doc(p_doc_id, 'ocr');
end $fn$;

-- ── the reviewer's own hand ────────────────────────────────────────────────
-- Confirming what OCR read needs no reason. Typing a DIFFERENT date, or typing
-- one where the machine read nothing, is a manual entry and the reason is
-- mandatory — the backend says so, the form does not decide it.
create or replace function public.kyc_doc_expiry_set(
  p_doc_id uuid, p_expiry date, p_number text default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  d public.kyc_documents%rowtype;
  x public.kyc_doc_extract%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_num    text := nullif(btrim(coalesce(p_number,'')),'');
  v_ocr_exp date; v_ocr_num text; v_manual boolean;
  v_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_zone  int := public.partner_zone_id();
begin
  if not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('kyc_review.err_not_authorized'));
  end if;
  select * into d from public.kyc_documents where id = p_doc_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_doc', 'tone','danger',
      'message', public._c('kyc_review.err_no_doc'));
  end if;
  if not v_admin and v_zone is not null and coalesce(d.zone_id,-1) <> v_zone then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('kyc_review.err_not_authorized'));
  end if;
  if p_expiry is null then
    return jsonb_build_object('ok', false, 'error','no_expiry', 'tone','danger',
      'message', public._c('kyc_expiry.err_no_expiry'));
  end if;
  if p_expiry < (now() at time zone 'Asia/Kolkata')::date - 3650 then
    return jsonb_build_object('ok', false, 'error','bad_expiry', 'tone','danger',
      'message', public._c('kyc_expiry.err_bad_expiry'));
  end if;

  select * into x from public.kyc_doc_extract where doc_id = p_doc_id;
  begin v_ocr_exp := nullif(btrim(coalesce(x.fields->>'valid_to','')),'')::date;
  exception when others then v_ocr_exp := null; end;
  v_ocr_num := nullif(btrim(coalesce(x.fields->>'licence_number','')),'');

  v_manual := (v_ocr_exp is null or v_ocr_exp <> p_expiry)
              or (v_num is not null and v_ocr_num is distinct from v_num);
  if v_manual and v_reason is null then
    return jsonb_build_object('ok', false, 'error','no_reason', 'tone','danger',
      'message', public._c('kyc_expiry.err_no_reason'));
  end if;

  insert into public.kyc_doc_field_edit(doc_id, owner_kind, owner_id, field,
                                        old_value, new_value, source, reason, actor)
  values (p_doc_id, d.owner_kind, d.owner_id, 'valid_to',
          d.valid_to::text, p_expiry::text,
          case when v_manual then 'manual' else 'confirm' end, v_reason, auth.uid());
  if v_num is not null and v_num is distinct from d.number then
    insert into public.kyc_doc_field_edit(doc_id, owner_kind, owner_id, field,
                                          old_value, new_value, source, reason, actor)
    values (p_doc_id, d.owner_kind, d.owner_id, 'number', d.number, v_num,
            case when v_manual then 'manual' else 'confirm' end, v_reason, auth.uid());
  end if;

  update public.kyc_documents
     set valid_to = p_expiry,
         number   = coalesce(v_num, number),
         updated_at = now()
   where id = p_doc_id;

  return jsonb_build_object('ok', true, 'tone','success',
    'doc_id', p_doc_id,
    'valid_to', p_expiry,
    'manual', v_manual,
    'message', case when v_manual then public._c('kyc_expiry.saved_manual')
                    else public._c('kyc_expiry.saved_confirm') end,
    'owner_state', public.kyc_state(d.owner_kind, d.owner_id));
end $fn$;

revoke all on function public.kyc_doc_expiry_set(uuid, date, text, text) from public;
grant execute on function public.kyc_doc_expiry_set(uuid, date, text, text) to authenticated;
revoke all on function public._kyc_apply_ocr_fields(uuid) from public;
revoke all on function public._kyc_sync_owner_expiry(text, uuid) from public;

-- one pass over what is already on file, so today's documents stop lying
do $$
declare r record;
begin
  for r in select distinct owner_kind, owner_id from public.kyc_documents
            where kind = 'drug_licence' and valid_to is not null
  loop
    perform public._kyc_sync_owner_expiry(r.owner_kind, r.owner_id);
  end loop;
end $$;
