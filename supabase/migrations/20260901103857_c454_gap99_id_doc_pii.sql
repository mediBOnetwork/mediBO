-- CMD #454 — feature_gaps #99
-- "Aadhaar and DL numbers are stored unmasked, plus the whole OCR payload"
--
-- delivery_partner_register stored id_doc_number verbatim from the scan AND the
-- entire ocr_payload map, alongside the raw document image path, with no
-- masking, no hash, no retention rule. For an Aadhaar number that is a
-- compliance exposure, not hygiene.
--
-- The fix keeps everything the business actually needs — a display suffix and a
-- de-duplication key — and stops keeping what it does not: the full number and
-- the raw OCR text it was read out of.
-- Idempotent: every statement is if-not-exists / or-replace / guarded.

alter table public.delivery_partner_registrations
  add column if not exists id_doc_last4 text,
  add column if not exists id_doc_hash  text,
  add column if not exists id_doc_purged_at timestamptz;

comment on column public.delivery_partner_registrations.id_doc_number is
  'Masked. Never the full number — see _pii_mask_doc(). Full value is not stored anywhere.';
comment on column public.delivery_partner_registrations.id_doc_hash is
  'sha256 of the normalised full number. De-duplication key only; not reversible.';

create index if not exists dpr_id_doc_hash_idx
  on public.delivery_partner_registrations (id_doc_hash)
  where id_doc_hash is not null;

-- retention window for the raw document image + the hash
alter table public.delivery_config
  add column if not exists id_doc_retain_days integer;
update public.delivery_config set id_doc_retain_days = 365
 where id = 1 and id_doc_retain_days is null;

-- ── the three primitives ─────────────────────────────────────────────────────

-- Digits only, upper-cased — so "1234 5678 9012" and "123456789012" hash alike.
create or replace function public._pii_norm_doc(p text)
returns text language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9]', '', 'g')), '');
$$;

-- The only form of the number we keep in a column: last 4, masked ahead of it.
create or replace function public._pii_mask_doc(p text)
returns text language sql immutable as $$
  select case
    when public._pii_norm_doc(p) is null then null
    when length(public._pii_norm_doc(p)) <= 4 then repeat('•', length(public._pii_norm_doc(p)))
    else repeat('•', length(public._pii_norm_doc(p)) - 4)
         || right(public._pii_norm_doc(p), 4)
  end;
$$;

create or replace function public._pii_hash_doc(p text)
returns text language sql immutable as $$
  select case when public._pii_norm_doc(p) is null then null
         else encode(sha256(convert_to(public._pii_norm_doc(p), 'UTF8')), 'hex') end;
$$;

-- Strip identity numbers out of a free-form OCR map before it is ever stored.
-- Two passes, because an OCR payload hides the number in two places: its own
-- key (id_number / aadhaar / dl_no / uid …) and inside raw text blocks.
create or replace function public._pii_redact_ocr(p jsonb)
returns jsonb language plpgsql immutable as $$
declare k text; v jsonb; out_j jsonb := '{}'::jsonb; s text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return '{}'::jsonb; end if;
  for k, v in select key, value from jsonb_each(p) loop
    if k ~* '(aadhaar|aadhar|uid|id_?num|doc_?num|dl_?no|licen[cs]e_?no|pan|number)' then
      out_j := out_j || jsonb_build_object(k, to_jsonb(coalesce(public._pii_mask_doc(v #>> '{}'), '')));
    elsif jsonb_typeof(v) = 'string' then
      s := v #>> '{}';
      -- any 8-to-16 digit run in free text is an identity number here
      s := regexp_replace(s, '[0-9][0-9 -]{6,}[0-9]', '[redacted]', 'g');
      out_j := out_j || jsonb_build_object(k, to_jsonb(s));
    elsif jsonb_typeof(v) = 'object' then
      out_j := out_j || jsonb_build_object(k, public._pii_redact_ocr(v));
    else
      out_j := out_j || jsonb_build_object(k, v);
    end if;
  end loop;
  return out_j;
end $$;

-- ── the write path ───────────────────────────────────────────────────────────
-- A trigger, not just a patched RPC: any future writer (an admin edit, an
-- import, a second registration path) is redacted by the table itself.
create or replace function public._trg_dpr_redact_pii()
returns trigger language plpgsql as $$
declare v_raw text;
begin
  v_raw := coalesce(new.id_doc_number, '');
  -- already masked (a re-save of a stored row) → leave it alone
  if v_raw <> '' and v_raw !~ '•' then
    new.id_doc_hash  := coalesce(new.id_doc_hash, public._pii_hash_doc(v_raw));
    new.id_doc_last4 := right(public._pii_norm_doc(v_raw), 4);
    new.id_doc_number := public._pii_mask_doc(v_raw);
  end if;

  -- The DL number is the same class of identity number and was equally open.
  -- dl_expiry (what the doc-block engine actually reads) is untouched.
  if coalesce(new.dl_number,'') <> '' and new.dl_number !~ '•' then
    new.dl_number := public._pii_mask_doc(new.dl_number);
  end if;
  new.ocr_payload := public._pii_redact_ocr(new.ocr_payload);
  return new;
end $$;

drop trigger if exists trg_dpr_redact_pii on public.delivery_partner_registrations;
create trigger trg_dpr_redact_pii
  before insert or update of id_doc_number, ocr_payload, dl_number
  on public.delivery_partner_registrations
  for each row execute function public._trg_dpr_redact_pii();

-- ── backfill: redact what is already stored ──────────────────────────────────
-- Small table (single-digit rows); no batching lane needed.
update public.delivery_partner_registrations
   set id_doc_number = id_doc_number   -- the trigger does the work
 where (id_doc_number is not null and id_doc_number !~ '•')
    or (dl_number     is not null and dl_number     !~ '•')
    or (ocr_payload is not null and ocr_payload <> '{}'::jsonb);

-- ── retention: the raw document image does not live forever ──────────────────
create or replace function public.delivery_id_doc_purge_tick()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_days int; v_paths text[]; v_n int := 0;
begin
  select coalesce(id_doc_retain_days, 365) into v_days from public.delivery_config where id = 1;

  select coalesce(array_agg(id_doc_path), '{}')
    into v_paths
    from public.delivery_partner_registrations
   where id_doc_path is not null
     and id_doc_purged_at is null
     and coalesce(status,'') in ('rejected')
     and coalesce(reviewed_at, submitted_at, created_at) < now() - make_interval(days => v_days);

  if array_length(v_paths, 1) is null then
    return jsonb_build_object('ok', true, 'purged', 0, 'retain_days', v_days);
  end if;

  delete from storage.objects
   where bucket_id = 'partner-docs' and name = any(v_paths);

  update public.delivery_partner_registrations
     set id_doc_path = null, id_doc_hash = null, id_doc_purged_at = now()
   where id_doc_path = any(v_paths);
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'purged', v_n, 'retain_days', v_days);
end $$;

insert into public.cron_task(name, ord, mode, work_sql, enabled, note, run_at_ist)
values ('delivery_id_doc_purge', 940, 'poll',
        'select public.delivery_id_doc_purge_tick()', true,
        'CMD #454 gap#99 — drops the raw ID image and hash for registrations rejected past delivery_config.id_doc_retain_days.',
        '01:20:00')
on conflict (name) do update
  set work_sql = excluded.work_sql, mode = excluded.mode,
      note = excluded.note, run_at_ist = excluded.run_at_ist, enabled = true;
