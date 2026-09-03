-- CHANGE #706 — Smart verification for KYC documents.
--
-- #705 gave pharmacies and suppliers a document. A human still had to read it.
-- This makes the machine read it first: the licence and the GST certificate are
-- OCR'd with the SAME Vertex gemini-3.5-flash pattern every other extraction in
-- mediBO uses, the extracted fields are stored BESIDE the typed ones, and a
-- deterministic check engine (GSTIN checksum, embedded PAN, state code, name
-- similarity, pin-vs-address distance, cross-account uniqueness) decides one of
-- three outcomes: clear -> auto-verify (and auto-approve, per-kind switch),
-- mismatch -> the manual queue with the mismatch list highlighted, hard fail
-- (checksum / duplicate / expired) -> auto-reject with a reason and a re-upload
-- path. Every automatic decision is written with its inputs, and an admin can
-- override any of it with a note.
--
-- Idempotent: every object is create-if-not-exists / create-or-replace, every
-- seed is on-conflict, so a resumed worker re-applying this file is a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CONFIG — thresholds and switches, editable without a deploy
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.kyc_verify_config (
  id                        smallint primary key default 1,
  ocr_enabled               boolean  not null default true,
  geo_max_metres            integer  not null default 500,
  name_similarity_min       numeric  not null default 0.42,
  field_similarity_min      numeric  not null default 0.72,
  default_gst_state_code    text     not null default '22',
  auto_verify_pharmacy      boolean  not null default true,
  auto_verify_supplier      boolean  not null default true,
  auto_approve_pharmacy     boolean  not null default true,
  auto_approve_supplier     boolean  not null default true,
  updated_at                timestamptz not null default now(),
  updated_by                uuid,
  constraint kyc_verify_config_singleton check (id = 1)
);
insert into public.kyc_verify_config(id) values (1) on conflict (id) do nothing;
-- Enabling RLS a second time is a no-op that still wants ACCESS EXCLUSIVE,
-- which is how a re-apply on a busy database dies instead of doing nothing.
do $c706$ begin
  if not (select relrowsecurity from pg_class
           where oid = 'public.kyc_verify_config'::regclass) then
    alter table public.kyc_verify_config enable row level security;
  end if;
end $c706$;

-- The zone carries the GST state code the licence must belong to. Chhattisgarh
-- is 22; a zone that has never been told keeps the config default.
--
-- `add column if not exists` still takes an ACCESS EXCLUSIVE lock on zones to
-- discover it has nothing to do, and zones is read by nearly every RPC — so a
-- re-apply on a busy database died on a lock timeout rather than being the
-- silent no-op a resumed worker needs. Ask the catalogue first; take the lock
-- only when there is genuinely a column to add.
do $c706$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'zones'
                    and column_name = 'gst_state_code') then
    alter table public.zones add column gst_state_code text;
  end if;
end $c706$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. OCR EXTRACT — what the machine read, stored beside what was typed
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.kyc_doc_extract (
  doc_id        uuid primary key references public.kyc_documents(id) on delete cascade,
  owner_kind    text not null,
  owner_id      uuid not null,
  kind          text not null,
  status        text not null default 'queued',
  attempts      smallint not null default 0,
  model         text,
  fields        jsonb not null default '{}'::jsonb,
  geo           jsonb not null default '{}'::jsonb,
  raw_text      text,
  error         text,
  requested_at  timestamptz not null default now(),
  completed_at  timestamptz,
  updated_at    timestamptz not null default now(),
  constraint kyc_doc_extract_status_check
    check (status in ('queued','running','done','failed','skipped'))
);
create index if not exists kyc_doc_extract_queue_idx
  on public.kyc_doc_extract(status, requested_at)
  where status in ('queued','running');
-- Enabling RLS a second time is a no-op that still wants ACCESS EXCLUSIVE,
-- which is how a re-apply on a busy database dies instead of doing nothing.
do $c706$ begin
  if not (select relrowsecurity from pg_class
           where oid = 'public.kyc_doc_extract'::regclass) then
    alter table public.kyc_doc_extract enable row level security;
  end if;
end $c706$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. IDENTITY CLAIMS — one DL and one GSTIN per account, platform-wide
--    owner_id is text because region_partners.id is a bigint while the two
--    profile tables are uuid; the registry spans all three.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.kyc_identity_claim (
  id_kind     text not null,
  norm_value  text not null,
  owner_kind  text not null,
  owner_id    text not null,
  raw_value   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (id_kind, norm_value),
  constraint kyc_identity_claim_kind_check  check (id_kind in ('dl','gstin')),
  constraint kyc_identity_claim_owner_check check (owner_kind in ('pharmacy','supplier','partner'))
);
create index if not exists kyc_identity_claim_owner_idx
  on public.kyc_identity_claim(owner_kind, owner_id);
-- Enabling RLS a second time is a no-op that still wants ACCESS EXCLUSIVE,
-- which is how a re-apply on a busy database dies instead of doing nothing.
do $c706$ begin
  if not (select relrowsecurity from pg_class
           where oid = 'public.kyc_identity_claim'::regclass) then
    alter table public.kyc_identity_claim enable row level security;
  end if;
end $c706$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. AUDIT — every decision, automatic or human, with the inputs it read
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.kyc_verify_run (
  id          uuid primary key default gen_random_uuid(),
  doc_id      uuid references public.kyc_documents(id) on delete cascade,
  owner_kind  text not null,
  owner_id    uuid not null,
  kind        text not null,
  verdict     text not null,
  tier        text not null,
  checks      jsonb not null default '[]'::jsonb,
  inputs      jsonb not null default '{}'::jsonb,
  reason      text,
  applied     boolean not null default false,
  approved_account boolean not null default false,
  actor       text not null default 'auto',
  actor_id    uuid,
  note        text,
  trigger_by  text,
  created_at  timestamptz not null default now(),
  -- The upload-time run and the OCR run land in the SAME transaction, so
  -- created_at ties and "the latest run" was whichever the planner returned
  -- first. The sequence is the order things actually happened in.
  seq         bigint generated by default as identity,
  constraint kyc_verify_run_verdict_check
    check (verdict in ('auto_verified','manual','auto_rejected','awaiting','override')),
  constraint kyc_verify_run_tier_check
    check (tier in ('clear','review','hard_fail','awaiting','override'))
);
create index if not exists kyc_verify_run_doc_idx  on public.kyc_verify_run(doc_id, created_at desc);
create index if not exists kyc_verify_run_doc_seq_idx on public.kyc_verify_run(doc_id, seq desc);
create index if not exists kyc_verify_run_owner_idx on public.kyc_verify_run(owner_kind, owner_id, created_at desc);
-- Enabling RLS a second time is a no-op that still wants ACCESS EXCLUSIVE,
-- which is how a re-apply on a busy database dies instead of doing nothing.
do $c706$ begin
  if not (select relrowsecurity from pg_class
           where oid = 'public.kyc_verify_run'::regclass) then
    alter table public.kyc_verify_run enable row level security;
  end if;
end $c706$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. PURE HELPERS — normalisation, checksum, similarity, distance
-- ─────────────────────────────────────────────────────────────────────────────

-- A licence number is compared without its separators: CG/RPR/20B/1234 and
-- CG-RPR-20B-1234 are the same licence and must collide in the registry.
create or replace function public.kyc_norm_id(p text)
returns text language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9]', '', 'g')), '');
$$;

-- GSTIN checksum: 14 payload characters over base-36, alternating weights 1/2,
-- each product folded (quotient + remainder), the 15th character is
-- (36 - sum mod 36) mod 36. No network call, no API key, no third party.
create or replace function public.kyc_gstin_checksum_ok(p_gstin text)
returns boolean language plpgsql immutable as $$
declare
  v text := public.gst_norm_gstin(p_gstin);
  alphabet constant text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  v_sum int := 0; v_i int; v_val int; v_prod int; v_check int;
begin
  if v is null or length(v) <> 15 then return false; end if;
  for v_i in 1..14 loop
    v_val := position(substr(v, v_i, 1) in alphabet) - 1;
    if v_val < 0 then return false; end if;
    v_prod := v_val * (case when v_i % 2 = 1 then 1 else 2 end);
    v_sum := v_sum + (v_prod / 36) + (v_prod % 36);
  end loop;
  v_check := (36 - (v_sum % 36)) % 36;
  return substr(alphabet, v_check + 1, 1) = substr(v, 15, 1);
end $$;

-- Characters 3–12 of a GSTIN are the holder's PAN.
create or replace function public.kyc_pan_of_gstin(p_gstin text)
returns text language sql immutable as $$
  select case when public.gst_norm_gstin(p_gstin) is null then null
              else substr(public.gst_norm_gstin(p_gstin), 3, 10) end;
$$;

create or replace function public.kyc_pan_format_ok(p_pan text)
returns boolean language sql immutable as $$
  select coalesce(public.kyc_norm_id(p_pan) ~ '^[A-Z]{5}[0-9]{4}[A-Z]$', false);
$$;

-- Trade names carry noise that similarity should not be punished for:
-- "M/s Sharma Medical Stores Pvt. Ltd." and "SHARMA MEDICAL STORES" are the
-- same shop. Strip punctuation and the legal/trade tokens, then compare.
create or replace function public.kyc_name_key(p text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           regexp_replace(
             regexp_replace(lower(coalesce(p,'')), '[^a-z0-9 ]', ' ', 'g'),
             '\y(m s|ms|mr|mrs|the|and|pvt|private|ltd|limited|llp|co|company|inc|corp|opc|huf|firm|enterprises|enterprise|agencies|agency|stores|store|medical|medicals|medico|medicos|pharma|pharmacy|pharmaceuticals|pharmaceutical|surgical|surgicals|distributors|distributor|traders|trader)\y',
             ' ', 'g'),
           '\s+', ' ', 'g'));
$$;

create or replace function public.kyc_name_similarity(a text, b text)
returns numeric language sql stable as $$
  select case
    when coalesce(public.kyc_name_key(a),'') = '' or coalesce(public.kyc_name_key(b),'') = ''
      then null
    when public.kyc_name_key(a) = public.kyc_name_key(b) then 1.0
    else round(greatest(
           similarity(public.kyc_name_key(a), public.kyc_name_key(b)),
           similarity(lower(coalesce(a,'')), lower(coalesce(b,''))))::numeric, 3)
  end;
$$;

-- Free text vs free text (a licence number read off a photo vs the one typed).
create or replace function public.kyc_field_similarity(a text, b text)
returns numeric language sql stable as $$
  select case
    when coalesce(btrim(a),'') = '' or coalesce(btrim(b),'') = '' then null
    when public.kyc_norm_id(a) = public.kyc_norm_id(b) then 1.0
    else round(similarity(lower(btrim(a)), lower(btrim(b)))::numeric, 3)
  end;
$$;

-- Straight-line metres. This is a sanity check on a pin, not a road distance —
-- road distance comes from OSRM and is not what "is the shop where the licence
-- says it is" asks.
create or replace function public.kyc_geo_metres(
  a_lat double precision, a_lng double precision,
  b_lat double precision, b_lng double precision)
returns integer language sql immutable as $$
  select case
    when a_lat is null or a_lng is null or b_lat is null or b_lng is null then null
    else round(6371000 * 2 * asin(sqrt(
           power(sin(radians(b_lat - a_lat) / 2), 2)
           + cos(radians(a_lat)) * cos(radians(b_lat))
             * power(sin(radians(b_lng - a_lng) / 2), 2))))::int
  end;
$$;

-- Metres are a number; the sentence a human reads is the backend's.
create or replace function public.kyc_metres_label(p_m integer)
returns text language sql stable as $$
  select case
    when p_m is null then ''
    when p_m < 1000 then p_m::text || ' m'
    else to_char(round(p_m / 1000.0, 1), 'FM999990.0') || ' km'
  end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. UNIQUENESS — the registry, its conflict reader, and the write guard
-- ─────────────────────────────────────────────────────────────────────────────

-- Who else holds this number? Returns the conflicting account so the admin sees
-- it by name, never just "duplicate".
create or replace function public.kyc_identity_conflict(
  p_id_kind text, p_value text, p_owner_kind text, p_owner_id text)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_norm text := public.kyc_norm_id(p_value);
  c kyc_identity_claim%rowtype;
  v_name text; v_city text;
begin
  if v_norm is null or length(v_norm) < 4 then
    return jsonb_build_object('has', false);
  end if;
  select * into c from kyc_identity_claim
   where id_kind = lower(p_id_kind) and norm_value = v_norm;
  if not found then return jsonb_build_object('has', false); end if;
  if c.owner_kind = lower(coalesce(p_owner_kind,'')) and c.owner_id = coalesce(p_owner_id,'') then
    return jsonb_build_object('has', false, 'self', true);
  end if;

  if c.owner_kind = 'pharmacy' then
    select pharmacy_name, city into v_name, v_city
      from pharmacy_profiles where id::text = c.owner_id;
  elsif c.owner_kind = 'supplier' then
    select supplier_name, city into v_name, v_city
      from supplier_profiles where id::text = c.owner_id;
  else
    select partner_name, district into v_name, v_city
      from region_partners where id::text = c.owner_id;
  end if;

  return jsonb_build_object(
    'has', true,
    'id_kind', c.id_kind,
    'value', c.norm_value,
    'owner_kind', c.owner_kind,
    'owner_id', c.owner_id,
    'owner_name', coalesce(v_name, ''),
    'owner_city', coalesce(v_city, ''),
    'owner_label', _c('kyc.owner_kind.'||c.owner_kind),
    'message', _cf('kyc_verify.dup_'||lower(p_id_kind),
                 jsonb_build_object('name', coalesce(nullif(v_name,''), _c('kyc_verify.dup_unnamed')))));
end $$;

-- Claim (or move) a number for an account. Refuses when another account holds
-- it; that refusal carries the backend's own sentence and the conflicting row.
create or replace function public.kyc_identity_claim_set(
  p_id_kind text, p_value text, p_owner_kind text, p_owner_id text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_norm text := public.kyc_norm_id(p_value);
  v_kind text := lower(btrim(coalesce(p_id_kind,'')));
  v_conf jsonb;
begin
  if v_norm is null or length(v_norm) < 4 then
    return jsonb_build_object('ok', true, 'skipped', 'too_short');
  end if;
  v_conf := public.kyc_identity_conflict(v_kind, v_norm, p_owner_kind, p_owner_id);
  if coalesce((v_conf->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'duplicate_'||v_kind,
      'tone', 'danger', 'conflict', v_conf, 'message', v_conf->>'message');
  end if;

  -- One number per account per kind: moving a licence to a new number releases
  -- the old one, so a corrected typo does not permanently burn a value.
  delete from kyc_identity_claim
   where id_kind = v_kind and owner_kind = lower(p_owner_kind)
     and owner_id = p_owner_id and norm_value <> v_norm;

  insert into kyc_identity_claim(id_kind, norm_value, owner_kind, owner_id, raw_value)
  values (v_kind, v_norm, lower(p_owner_kind), p_owner_id, btrim(coalesce(p_value,'')))
  on conflict (id_kind, norm_value) do update
    set owner_kind = excluded.owner_kind,
        owner_id   = excluded.owner_id,
        raw_value  = excluded.raw_value,
        updated_at = now()
   where kyc_identity_claim.owner_kind = excluded.owner_kind
     and kyc_identity_claim.owner_id   = excluded.owner_id;

  return jsonb_build_object('ok', true, 'value', v_norm);
end $$;

-- The registry is fed by the profile tables themselves, so a number that never
-- passes through a KYC upload is still unique platform-wide. A conflict here
-- never blocks the profile write (an admin editing an address must not be
-- stopped by someone else's licence); the CLAIM is simply not moved, and
-- kyc_identity_conflict() is what the verification engine and the write RPCs
-- read to refuse.
create or replace function public._kyc_claim_sync()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_owner text; v_dl text; v_gst text;
begin
  if tg_table_name = 'pharmacy_profiles' then
    v_owner := 'pharmacy'; v_dl := new.drug_license; v_gst := new.gstin;
  elsif tg_table_name = 'supplier_profiles' then
    v_owner := 'supplier'; v_dl := new.drug_license; v_gst := new.gstin;
  else
    v_owner := 'partner';  v_dl := new.dl_20b;       v_gst := new.gstin;
  end if;

  if v_owner <> 'partner' and coalesce(new.is_deleted, false) then
    delete from kyc_identity_claim
     where owner_kind = v_owner and owner_id = new.id::text;
    return new;
  end if;

  perform public.kyc_identity_claim_set('dl',    v_dl,  v_owner, new.id::text);
  perform public.kyc_identity_claim_set('gstin', v_gst, v_owner, new.id::text);
  return new;
end $$;

drop trigger if exists kyc_claim_sync_pharmacy on public.pharmacy_profiles;
create trigger kyc_claim_sync_pharmacy after insert or update of drug_license, gstin, is_deleted
  on public.pharmacy_profiles for each row execute function public._kyc_claim_sync();
drop trigger if exists kyc_claim_sync_supplier on public.supplier_profiles;
create trigger kyc_claim_sync_supplier after insert or update of drug_license, gstin, is_deleted
  on public.supplier_profiles for each row execute function public._kyc_claim_sync();
drop trigger if exists kyc_claim_sync_partner on public.region_partners;
create trigger kyc_claim_sync_partner after insert or update of dl_20b, gstin
  on public.region_partners for each row execute function public._kyc_claim_sync();

-- Backfill: every number already on file becomes a claim. First writer wins;
-- a pre-existing duplicate leaves the second account unclaimed and the engine
-- reports it as the conflict it is.
insert into public.kyc_identity_claim(id_kind, norm_value, owner_kind, owner_id, raw_value)
select k, v, o, i, r from (
  select 'dl' k, public.kyc_norm_id(drug_license) v, 'pharmacy' o, id::text i, drug_license r,
         row_number() over (partition by public.kyc_norm_id(drug_license) order by created_at) rn
    from pharmacy_profiles where coalesce(is_deleted,false) = false
      and length(coalesce(public.kyc_norm_id(drug_license),'')) >= 4
) x where rn = 1
on conflict (id_kind, norm_value) do nothing;

insert into public.kyc_identity_claim(id_kind, norm_value, owner_kind, owner_id, raw_value)
select 'dl', public.kyc_norm_id(drug_license), 'supplier', id::text, drug_license
  from supplier_profiles where coalesce(is_deleted,false) = false
   and length(coalesce(public.kyc_norm_id(drug_license),'')) >= 4
on conflict (id_kind, norm_value) do nothing;

insert into public.kyc_identity_claim(id_kind, norm_value, owner_kind, owner_id, raw_value)
select 'dl', public.kyc_norm_id(dl_20b), 'partner', id::text, dl_20b
  from region_partners where length(coalesce(public.kyc_norm_id(dl_20b),'')) >= 4
on conflict (id_kind, norm_value) do nothing;

insert into public.kyc_identity_claim(id_kind, norm_value, owner_kind, owner_id, raw_value)
select 'gstin', public.kyc_norm_id(gstin), 'pharmacy', id::text, gstin
  from pharmacy_profiles where coalesce(is_deleted,false) = false
   and length(coalesce(public.kyc_norm_id(gstin),'')) >= 4
on conflict (id_kind, norm_value) do nothing;

insert into public.kyc_identity_claim(id_kind, norm_value, owner_kind, owner_id, raw_value)
select 'gstin', public.kyc_norm_id(gstin), 'supplier', id::text, gstin
  from supplier_profiles where coalesce(is_deleted,false) = false
   and length(coalesce(public.kyc_norm_id(gstin),'')) >= 4
on conflict (id_kind, norm_value) do nothing;

insert into public.kyc_identity_claim(id_kind, norm_value, owner_kind, owner_id, raw_value)
select 'gstin', public.kyc_norm_id(gstin), 'partner', id::text, gstin
  from region_partners where length(coalesce(public.kyc_norm_id(gstin),'')) >= 4
on conflict (id_kind, norm_value) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. COPY — every sentence this feature shows a human lives here, not in Dart
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('kyc.owner_kind.pharmacy',   to_jsonb('Pharmacy'::text)),
  ('kyc.owner_kind.supplier',   to_jsonb('Supplier'::text)),
  ('kyc.owner_kind.partner',    to_jsonb('Region partner'::text)),

  ('kyc_verify.dup_unnamed',    to_jsonb('another account'::text)),
  ('kyc_verify.dup_dl',         to_jsonb('This drug licence number is already registered to {name}.'::text)),
  ('kyc_verify.dup_gstin',      to_jsonb('This GSTIN is already registered to {name}.'::text)),

  ('kyc_verify.title',          to_jsonb('Automatic checks'::text)),
  ('kyc_verify.subtitle',       to_jsonb('We read the document and compared it with what you entered.'::text)),
  ('kyc_verify.none_yet',       to_jsonb('No checks have run on this document yet.'::text)),
  ('kyc_verify.reading',        to_jsonb('Reading the document…'::text)),
  ('kyc_verify.reading_note',   to_jsonb('This usually takes under a minute. You can close this page.'::text)),

  ('kyc_verify.res.pass',       to_jsonb('OK'::text)),
  ('kyc_verify.res.warn',       to_jsonb('Check'::text)),
  ('kyc_verify.res.fail',       to_jsonb('Failed'::text)),
  ('kyc_verify.res.skip',       to_jsonb('Not checked'::text)),

  ('kyc_verify.tier.clear',     to_jsonb('All checks passed'::text)),
  ('kyc_verify.tier.review',    to_jsonb('Needs a human look'::text)),
  ('kyc_verify.tier.hard_fail', to_jsonb('Rejected automatically'::text)),
  ('kyc_verify.tier.awaiting',  to_jsonb('Reading the document'::text)),
  ('kyc_verify.tier.override',  to_jsonb('Decided by an admin'::text)),

  ('kyc_verify.verdict.auto_verified', to_jsonb('Verified automatically'::text)),
  ('kyc_verify.verdict.manual',        to_jsonb('Sent for manual review'::text)),
  ('kyc_verify.verdict.auto_rejected', to_jsonb('Rejected automatically'::text)),
  ('kyc_verify.verdict.awaiting',      to_jsonb('Waiting for the document to be read'::text)),
  ('kyc_verify.verdict.override',      to_jsonb('Overridden by an admin'::text)),

  ('kyc_verify.approved_account',  to_jsonb('Account approved automatically.'::text)),
  ('kyc_verify.reupload_label',    to_jsonb('Upload a corrected document'::text)),
  ('kyc_verify.mismatch_heading',  to_jsonb('What did not match'::text)),
  ('kyc_verify.mismatch_count',    to_jsonb('{n} to check'::text)),
  ('kyc_verify.conflict_heading',  to_jsonb('Already registered to'::text)),
  ('kyc_verify.typed_label',       to_jsonb('You entered'::text)),
  ('kyc_verify.read_label',        to_jsonb('We read'::text)),
  ('kyc_verify.rerun_label',       to_jsonb('Run the checks again'::text)),
  ('kyc_verify.override_label',    to_jsonb('Override this decision'::text)),
  ('kyc_verify.override_note_label', to_jsonb('Why are you overriding?'::text)),
  ('kyc_verify.override_note_hint', to_jsonb('This note is kept with the decision.'::text)),
  ('kyc_verify.err_no_note',       to_jsonb('Add a note before overriding.'::text)),
  ('kyc_verify.override_toast',    to_jsonb('Decision overridden.'::text)),
  ('kyc_verify.rerun_toast',       to_jsonb('Checks re-run.'::text)),
  ('kyc_verify.err_no_doc',        to_jsonb('That document no longer exists.'::text)),
  ('kyc_verify.err_not_authorized',to_jsonb('You are not allowed to review documents.'::text)),
  ('kyc_verify.auto_badge',        to_jsonb('Automatic'::text)),
  ('kyc_verify.decided_label',     to_jsonb('Decided {age}'::text)),

  ('kyc_verify.chk.expiry',          to_jsonb('Validity'::text)),
  ('kyc_verify.chk.dup_dl',          to_jsonb('Licence used elsewhere'::text)),
  ('kyc_verify.chk.dup_gstin',       to_jsonb('GSTIN used elsewhere'::text)),
  ('kyc_verify.chk.ocr_number',      to_jsonb('Number on the document'::text)),
  ('kyc_verify.chk.ocr_name',        to_jsonb('Name on the document'::text)),
  ('kyc_verify.chk.ocr_expiry',      to_jsonb('Validity on the document'::text)),
  ('kyc_verify.chk.ocr_gstin',       to_jsonb('GSTIN on the certificate'::text)),
  ('kyc_verify.chk.ocr_read',        to_jsonb('Document readable'::text)),
  ('kyc_verify.chk.gstin_format',    to_jsonb('GSTIN format'::text)),
  ('kyc_verify.chk.gstin_checksum',  to_jsonb('GSTIN check digit'::text)),
  ('kyc_verify.chk.gstin_pan',       to_jsonb('PAN inside the GSTIN'::text)),
  ('kyc_verify.chk.gstin_state',     to_jsonb('GSTIN state code'::text)),
  ('kyc_verify.chk.gstin_name',      to_jsonb('Legal name'::text)),
  ('kyc_verify.chk.pan_format',      to_jsonb('PAN format'::text)),
  ('kyc_verify.chk.geo',             to_jsonb('Address vs map pin'::text)),

  ('kyc_verify.det.expiry_ok',       to_jsonb('Valid till {d}.'::text)),
  ('kyc_verify.det.expiry_none',     to_jsonb('No expiry date was entered.'::text)),
  ('kyc_verify.det.expiry_past',     to_jsonb('This document expired on {d}.'::text)),
  ('kyc_verify.det.dup_none',        to_jsonb('Not used by any other account.'::text)),
  ('kyc_verify.det.dup_hit',         to_jsonb('Already registered to {name} ({kind}).'::text)),
  ('kyc_verify.det.num_match',       to_jsonb('The number on the document matches what you entered.'::text)),
  ('kyc_verify.det.num_diff',        to_jsonb('You entered {typed}; the document reads {read}.'::text)),
  ('kyc_verify.det.num_absent',      to_jsonb('No number could be read from the document.'::text)),
  ('kyc_verify.det.name_match',      to_jsonb('{read} matches the business name on file.'::text)),
  ('kyc_verify.det.name_diff',       to_jsonb('The document is in the name of {read}; the account is {typed}.'::text)),
  ('kyc_verify.det.date_match',      to_jsonb('The validity on the document matches {d}.'::text)),
  ('kyc_verify.det.date_diff',       to_jsonb('You entered {typed}; the document reads {read}.'::text)),
  ('kyc_verify.det.ocr_ok',          to_jsonb('The document was read successfully.'::text)),
  ('kyc_verify.det.ocr_failed',      to_jsonb('The document could not be read. A person will check it.'::text)),
  ('kyc_verify.det.ocr_off',         to_jsonb('Automatic reading is switched off.'::text)),
  ('kyc_verify.det.ocr_waiting',     to_jsonb('The document is still being read.'::text)),
  ('kyc_verify.det.gstin_ok',        to_jsonb('{v} is a valid GSTIN.'::text)),
  ('kyc_verify.det.gstin_bad',       to_jsonb('{v} is not a valid GSTIN format.'::text)),
  ('kyc_verify.det.gstin_none',      to_jsonb('No GSTIN was entered.'::text)),
  ('kyc_verify.det.checksum_ok',     to_jsonb('The check digit is correct.'::text)),
  ('kyc_verify.det.checksum_bad',    to_jsonb('The check digit of {v} is wrong — this number cannot exist.'::text)),
  ('kyc_verify.det.pan_ok',          to_jsonb('The PAN inside the GSTIN matches the PAN card.'::text)),
  ('kyc_verify.det.pan_diff',        to_jsonb('The GSTIN contains PAN {read}; the PAN card says {typed}.'::text)),
  ('kyc_verify.det.pan_absent',      to_jsonb('No PAN card was uploaded, so this was not compared.'::text)),
  ('kyc_verify.det.pan_format_ok',   to_jsonb('{v} is a valid PAN format.'::text)),
  ('kyc_verify.det.pan_format_bad',  to_jsonb('{v} is not a valid PAN format.'::text)),
  ('kyc_verify.det.state_ok',        to_jsonb('State code {v} matches this zone.'::text)),
  ('kyc_verify.det.state_diff',      to_jsonb('State code {read} is not this zone''s state ({typed}).'::text)),
  ('kyc_verify.det.legal_ok',        to_jsonb('The legal name on the certificate matches the business name.'::text)),
  ('kyc_verify.det.legal_diff',      to_jsonb('The certificate is in the name of {read}; the account is {typed}.'::text)),
  ('kyc_verify.det.geo_ok',          to_jsonb('The map pin is {d} from the address on the document.'::text)),
  ('kyc_verify.det.geo_far',         to_jsonb('The map pin is {d} from the address on the document — further than {max}.'::text)),
  ('kyc_verify.det.geo_absent',      to_jsonb('There is no map pin or no readable address to compare.'::text)),

  ('kyc_verify.reason.prefix',       to_jsonb('Automatically rejected: {list}.'::text)),
  ('kyc_verify.reason.expiry',       to_jsonb('the document has expired'::text)),
  ('kyc_verify.reason.dup_dl',       to_jsonb('this licence number belongs to another account'::text)),
  ('kyc_verify.reason.dup_gstin',    to_jsonb('this GSTIN belongs to another account'::text)),
  ('kyc_verify.reason.gstin_format', to_jsonb('the GSTIN is not a valid format'::text)),
  ('kyc_verify.reason.gstin_checksum', to_jsonb('the GSTIN check digit is wrong'::text)),
  ('kyc_verify.reason.suffix',       to_jsonb('Upload a corrected document to try again.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE CHECK ENGINE
-- ─────────────────────────────────────────────────────────────────────────────

-- One check, rendered. The screen prints label/status_label/detail verbatim and
-- decides nothing.
create or replace function public._kyc_chk(
  p_key text, p_status text, p_detail_key text default null,
  p_params jsonb default '{}'::jsonb, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object(
    'key', p_key,
    'label', _c('kyc_verify.chk.'||p_key),
    'status', p_status,
    'status_label', _c('kyc_verify.res.'||p_status),
    'tone', case p_status when 'pass' then 'success'
                          when 'warn' then 'warning'
                          when 'fail' then 'danger'
                          else 'info' end,
    'detail', case when p_detail_key is null then ''
                   else _cf('kyc_verify.det.'||p_detail_key, p_params) end
  ) || coalesce(p_extra, '{}'::jsonb);
$$;

-- Read the document, the account and the extract; return the checks, the tier
-- and the verdict. Pure: it decides, it never writes.
create or replace function public.kyc_verify_evaluate(p_doc_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  d          kyc_documents%rowtype;
  x          kyc_doc_extract%rowtype;
  cfg        kyc_verify_config%rowtype;
  v_checks   jsonb := '[]'::jsonb;
  v_name     text; v_lat double precision; v_lng double precision;
  v_zone_state text;
  v_today    date := (now() at time zone 'Asia/Kolkata')::date;
  v_typed    text; v_read text; v_sim numeric; v_conf jsonb;
  v_gstin    text; v_pan_doc text; v_pan_in text;
  v_m        integer; v_ocr_ready boolean := false; v_ocr_state text := 'none';
  v_read_date date;
  v_tier     text; v_verdict text; v_reasons text[] := '{}';
  v_needs_ocr boolean;
begin
  select * into d from kyc_documents where id = p_doc_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_doc'); end if;
  select * into cfg from kyc_verify_config where id = 1;
  select * into x from kyc_doc_extract where doc_id = p_doc_id;

  if d.owner_kind = 'pharmacy' then
    select pharmacy_name, latitude, longitude into v_name, v_lat, v_lng
      from pharmacy_profiles where id = d.owner_id;
  else
    select supplier_name, lat, lng into v_name, v_lat, v_lng
      from supplier_profiles where id = d.owner_id;
  end if;
  select coalesce(nullif(z.gst_state_code,''), cfg.default_gst_state_code)
    into v_zone_state from zones z where z.id = d.zone_id;
  v_zone_state := coalesce(v_zone_state, cfg.default_gst_state_code);

  v_needs_ocr := cfg.ocr_enabled and d.kind in ('drug_licence','gst_certificate','pan');
  v_ocr_state := coalesce(x.status, case when v_needs_ocr then 'queued' else 'skipped' end);
  v_ocr_ready := (v_ocr_state = 'done');

  -- ── readability ───────────────────────────────────────────────────────────
  if not v_needs_ocr then
    null;                                    -- a shop photo has nothing to read
  elsif v_ocr_state = 'done' then
    v_checks := v_checks || public._kyc_chk('ocr_read','pass','ocr_ok');
  elsif v_ocr_state = 'failed' then
    v_checks := v_checks || public._kyc_chk('ocr_read','warn','ocr_failed');
  elsif not cfg.ocr_enabled then
    v_checks := v_checks || public._kyc_chk('ocr_read','skip','ocr_off');
  else
    v_checks := v_checks || public._kyc_chk('ocr_read','skip','ocr_waiting');
  end if;

  -- ── validity ──────────────────────────────────────────────────────────────
  if d.valid_to is null then
    if d.kind = 'drug_licence' then
      v_checks := v_checks || public._kyc_chk('expiry','warn','expiry_none');
    end if;
  elsif d.valid_to < v_today then
    v_checks := v_checks || public._kyc_chk('expiry','fail','expiry_past',
                  jsonb_build_object('d', to_char(d.valid_to,'FMDD Mon YYYY')));
    v_reasons := v_reasons || _c('kyc_verify.reason.expiry');
  else
    v_checks := v_checks || public._kyc_chk('expiry','pass','expiry_ok',
                  jsonb_build_object('d', to_char(d.valid_to,'FMDD Mon YYYY')));
  end if;

  -- ── drug licence ──────────────────────────────────────────────────────────
  if d.kind = 'drug_licence' then
    v_typed := coalesce(nullif(btrim(coalesce(d.number,'')),''), null);
    v_conf := public.kyc_identity_conflict('dl', v_typed, d.owner_kind, d.owner_id::text);
    if coalesce((v_conf->>'has')::boolean, false) then
      v_checks := v_checks || public._kyc_chk('dup_dl','fail','dup_hit',
                    jsonb_build_object('name', v_conf->>'owner_name', 'kind', v_conf->>'owner_label'),
                    jsonb_build_object('conflict', v_conf));
      v_reasons := v_reasons || _c('kyc_verify.reason.dup_dl');
    elsif v_typed is not null then
      v_checks := v_checks || public._kyc_chk('dup_dl','pass','dup_none');
    end if;

    if v_ocr_ready then
      v_read := nullif(btrim(coalesce(x.fields->>'licence_number','')),'');
      v_sim  := public.kyc_field_similarity(v_typed, v_read);
      if v_read is null then
        v_checks := v_checks || public._kyc_chk('ocr_number','warn','num_absent');
      elsif coalesce(v_sim,0) >= cfg.field_similarity_min then
        v_checks := v_checks || public._kyc_chk('ocr_number','pass','num_match',
                      '{}'::jsonb, jsonb_build_object('score', v_sim));
      else
        v_checks := v_checks || public._kyc_chk('ocr_number','warn','num_diff',
                      jsonb_build_object('typed', coalesce(v_typed,''), 'read', v_read),
                      jsonb_build_object('score', v_sim));
      end if;

      v_read := nullif(btrim(coalesce(x.fields->>'licensee_name','')),'');
      v_sim  := public.kyc_name_similarity(v_name, v_read);
      if v_read is null then
        v_checks := v_checks || public._kyc_chk('ocr_name','skip','num_absent');
      elsif coalesce(v_sim,0) >= cfg.name_similarity_min then
        v_checks := v_checks || public._kyc_chk('ocr_name','pass','name_match',
                      jsonb_build_object('read', v_read), jsonb_build_object('score', v_sim));
      else
        v_checks := v_checks || public._kyc_chk('ocr_name','warn','name_diff',
                      jsonb_build_object('read', v_read, 'typed', coalesce(v_name,'')),
                      jsonb_build_object('score', v_sim));
      end if;

      v_read_date := null;
      begin v_read_date := nullif(x.fields->>'valid_to','')::date; exception when others then v_read_date := null; end;
      if v_read_date is not null and d.valid_to is not null then
        if v_read_date = d.valid_to then
          v_checks := v_checks || public._kyc_chk('ocr_expiry','pass','date_match',
                        jsonb_build_object('d', to_char(d.valid_to,'FMDD Mon YYYY')));
        else
          v_checks := v_checks || public._kyc_chk('ocr_expiry','warn','date_diff',
                        jsonb_build_object('typed', to_char(d.valid_to,'FMDD Mon YYYY'),
                                           'read',  to_char(v_read_date,'FMDD Mon YYYY')));
        end if;
      end if;
    end if;
  end if;

  -- ── GST certificate ───────────────────────────────────────────────────────
  if d.kind = 'gst_certificate' then
    v_typed := nullif(btrim(coalesce(d.number,'')),'');
    v_gstin := public.gst_norm_gstin(v_typed);
    if v_typed is null then
      v_checks := v_checks || public._kyc_chk('gstin_format','fail','gstin_none');
      v_reasons := v_reasons || _c('kyc_verify.reason.gstin_format');
    elsif v_gstin is null then
      v_checks := v_checks || public._kyc_chk('gstin_format','fail','gstin_bad',
                    jsonb_build_object('v', v_typed));
      v_reasons := v_reasons || _c('kyc_verify.reason.gstin_format');
    else
      v_checks := v_checks || public._kyc_chk('gstin_format','pass','gstin_ok',
                    jsonb_build_object('v', v_gstin));
      if public.kyc_gstin_checksum_ok(v_gstin) then
        v_checks := v_checks || public._kyc_chk('gstin_checksum','pass','checksum_ok');
      else
        v_checks := v_checks || public._kyc_chk('gstin_checksum','fail','checksum_bad',
                      jsonb_build_object('v', v_gstin));
        v_reasons := v_reasons || _c('kyc_verify.reason.gstin_checksum');
      end if;

      -- the PAN card, if one was uploaded, must be the PAN inside the GSTIN
      select public.kyc_norm_id(k.number) into v_pan_doc
        from kyc_documents k
       where k.owner_kind = d.owner_kind and k.owner_id = d.owner_id and k.kind = 'pan'
         and k.status in ('pending','verified') and coalesce(k.number,'') <> ''
       order by k.submitted_at desc limit 1;
      v_pan_in := public.kyc_pan_of_gstin(v_gstin);
      if v_pan_doc is null then
        v_checks := v_checks || public._kyc_chk('gstin_pan','skip','pan_absent');
      elsif v_pan_doc = v_pan_in then
        v_checks := v_checks || public._kyc_chk('gstin_pan','pass','pan_ok');
      else
        v_checks := v_checks || public._kyc_chk('gstin_pan','warn','pan_diff',
                      jsonb_build_object('read', v_pan_in, 'typed', v_pan_doc));
      end if;

      if left(v_gstin,2) = v_zone_state then
        v_checks := v_checks || public._kyc_chk('gstin_state','pass','state_ok',
                      jsonb_build_object('v', v_zone_state));
      else
        v_checks := v_checks || public._kyc_chk('gstin_state','warn','state_diff',
                      jsonb_build_object('read', left(v_gstin,2), 'typed', v_zone_state));
      end if;

      v_conf := public.kyc_identity_conflict('gstin', v_gstin, d.owner_kind, d.owner_id::text);
      if coalesce((v_conf->>'has')::boolean, false) then
        v_checks := v_checks || public._kyc_chk('dup_gstin','fail','dup_hit',
                      jsonb_build_object('name', v_conf->>'owner_name', 'kind', v_conf->>'owner_label'),
                      jsonb_build_object('conflict', v_conf));
        v_reasons := v_reasons || _c('kyc_verify.reason.dup_gstin');
      else
        v_checks := v_checks || public._kyc_chk('dup_gstin','pass','dup_none');
      end if;
    end if;

    if v_ocr_ready then
      v_read := public.gst_norm_gstin(coalesce(x.fields->>'gstin',''));
      if v_read is null then
        v_checks := v_checks || public._kyc_chk('ocr_gstin','warn','num_absent');
      elsif v_read = v_gstin then
        v_checks := v_checks || public._kyc_chk('ocr_gstin','pass','num_match');
      else
        v_checks := v_checks || public._kyc_chk('ocr_gstin','warn','num_diff',
                      jsonb_build_object('typed', coalesce(v_gstin, coalesce(v_typed,'')), 'read', v_read));
      end if;

      v_read := nullif(btrim(coalesce(x.fields->>'legal_name','')),'');
      v_sim  := public.kyc_name_similarity(v_name, v_read);
      if v_read is null then
        v_checks := v_checks || public._kyc_chk('gstin_name','skip','num_absent');
      elsif coalesce(v_sim,0) >= cfg.name_similarity_min then
        v_checks := v_checks || public._kyc_chk('gstin_name','pass','legal_ok',
                      '{}'::jsonb, jsonb_build_object('score', v_sim));
      else
        v_checks := v_checks || public._kyc_chk('gstin_name','warn','legal_diff',
                      jsonb_build_object('read', v_read, 'typed', coalesce(v_name,'')),
                      jsonb_build_object('score', v_sim));
      end if;
    end if;
  end if;

  -- ── PAN card ──────────────────────────────────────────────────────────────
  if d.kind = 'pan' then
    v_typed := nullif(btrim(coalesce(d.number,'')),'');
    if v_typed is null then
      v_checks := v_checks || public._kyc_chk('pan_format','skip','num_absent');
    elsif public.kyc_pan_format_ok(v_typed) then
      v_checks := v_checks || public._kyc_chk('pan_format','pass','pan_format_ok',
                    jsonb_build_object('v', public.kyc_norm_id(v_typed)));
    else
      v_checks := v_checks || public._kyc_chk('pan_format','warn','pan_format_bad',
                    jsonb_build_object('v', v_typed));
    end if;
    if v_ocr_ready then
      v_read := nullif(btrim(coalesce(x.fields->>'pan','')),'');
      if v_read is null then
        v_checks := v_checks || public._kyc_chk('ocr_number','warn','num_absent');
      elsif public.kyc_norm_id(v_read) = public.kyc_norm_id(v_typed) then
        v_checks := v_checks || public._kyc_chk('ocr_number','pass','num_match');
      else
        v_checks := v_checks || public._kyc_chk('ocr_number','warn','num_diff',
                      jsonb_build_object('typed', coalesce(v_typed,''), 'read', v_read));
      end if;
    end if;
  end if;

  -- ── geo: the pin against the address printed on the document ──────────────
  if d.kind in ('drug_licence','gst_certificate') then
    v_m := public.kyc_geo_metres(v_lat, v_lng,
             nullif(x.geo->>'lat','')::double precision,
             nullif(x.geo->>'lng','')::double precision);
    if v_m is null then
      if v_ocr_ready then
        v_checks := v_checks || public._kyc_chk('geo','skip','geo_absent');
      end if;
    elsif v_m <= cfg.geo_max_metres then
      v_checks := v_checks || public._kyc_chk('geo','pass','geo_ok',
                    jsonb_build_object('d', public.kyc_metres_label(v_m)),
                    jsonb_build_object('metres', v_m, 'geo', x.geo));
    else
      v_checks := v_checks || public._kyc_chk('geo','warn','geo_far',
                    jsonb_build_object('d', public.kyc_metres_label(v_m),
                                       'max', public.kyc_metres_label(cfg.geo_max_metres)),
                    jsonb_build_object('metres', v_m, 'geo', x.geo));
    end if;
  end if;

  -- ── tier ──────────────────────────────────────────────────────────────────
  if exists (select 1 from jsonb_array_elements(v_checks) c where c->>'status' = 'fail') then
    v_tier := 'hard_fail'; v_verdict := 'auto_rejected';
  elsif v_needs_ocr and not v_ocr_ready and v_ocr_state not in ('failed','skipped') then
    v_tier := 'awaiting'; v_verdict := 'awaiting';
  elsif exists (select 1 from jsonb_array_elements(v_checks) c where c->>'status' = 'warn') then
    v_tier := 'review'; v_verdict := 'manual';
  else
    v_tier := 'clear'; v_verdict := 'auto_verified';
  end if;

  return jsonb_build_object(
    'ok', true,
    'doc_id', d.id,
    'owner_kind', d.owner_kind,
    'owner_id', d.owner_id,
    'kind', d.kind,
    'tier', v_tier,
    'tier_label', _c('kyc_verify.tier.'||v_tier),
    'verdict', v_verdict,
    'verdict_label', _c('kyc_verify.verdict.'||v_verdict),
    'tone', case v_tier when 'clear' then 'success' when 'hard_fail' then 'danger'
                        when 'review' then 'warning' else 'info' end,
    'checks', v_checks,
    'ocr_status', v_ocr_state,
    'mismatch_count', (select count(*) from jsonb_array_elements(v_checks) c
                        where c->>'status' in ('warn','fail')),
    'reason', case when array_length(v_reasons,1) is null then null
                   else _cf('kyc_verify.reason.prefix',
                          jsonb_build_object('list', array_to_string(v_reasons, '; ')))
                        || ' ' || _c('kyc_verify.reason.suffix') end,
    'inputs', jsonb_build_object(
                'typed_number', coalesce(d.number,''),
                'typed_valid_to', d.valid_to,
                'account_name', coalesce(v_name,''),
                'pin', jsonb_build_object('lat', v_lat, 'lng', v_lng),
                'zone_state', v_zone_state,
                'extract', coalesce(x.fields, '{}'::jsonb),
                'extract_geo', coalesce(x.geo, '{}'::jsonb),
                'config', jsonb_build_object(
                            'geo_max_metres', cfg.geo_max_metres,
                            'name_similarity_min', cfg.name_similarity_min,
                            'field_similarity_min', cfg.field_similarity_min)));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. THE ORCHESTRATOR — evaluate, write the audit row, apply the tier
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.kyc_verify_doc(p_doc_id uuid, p_trigger text default 'auto')
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  d        kyc_documents%rowtype;
  cfg      kyc_verify_config%rowtype;
  v_eval   jsonb;
  v_tier   text; v_verdict text;
  v_auto_verify boolean; v_auto_approve boolean;
  v_applied boolean := false; v_approved boolean := false;
  v_state  jsonb; v_phone text; v_name text;
begin
  select * into d from kyc_documents where id = p_doc_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_doc', 'tone','danger',
      'message', _c('kyc_verify.err_no_doc'));
  end if;
  select * into cfg from kyc_verify_config where id = 1;
  v_eval := public.kyc_verify_evaluate(p_doc_id);
  if not coalesce((v_eval->>'ok')::boolean, false) then return v_eval; end if;

  v_tier    := v_eval->>'tier';
  v_verdict := v_eval->>'verdict';
  v_auto_verify  := case d.owner_kind when 'pharmacy' then cfg.auto_verify_pharmacy
                                      else cfg.auto_verify_supplier end;
  v_auto_approve := case d.owner_kind when 'pharmacy' then cfg.auto_approve_pharmacy
                                      else cfg.auto_approve_supplier end;

  -- A document a HUMAN has ruled on is never re-decided by the machine; the
  -- checks still run and are still shown, they just do not move the status.
  -- An automatic rejection (verified_by is null) stays the machine's own, so a
  -- re-run refreshes its reason instead of leaving the applicant reading a
  -- sentence the current checks no longer produce.
  if d.status = 'pending'
     or (d.status = 'rejected' and d.verified_by is null) then
    if v_tier = 'hard_fail' then
      update kyc_documents
         set status = 'rejected', reason = v_eval->>'reason',
             verified_by = null, verified_at = now(), updated_at = now()
       where id = p_doc_id;
      v_applied := true;
    elsif v_tier = 'clear' and v_auto_verify then
      update kyc_documents
         set status = 'verified', reason = null,
             verified_by = null, verified_at = now(), updated_at = now()
       where id = p_doc_id;
      v_applied := true;

      -- the document is clear; is the ACCOUNT now clear too?
      if v_auto_approve then
        v_state := public.kyc_state(d.owner_kind, d.owner_id);
        if coalesce((v_state->>'clear')::boolean, false) then
          begin
            if d.owner_kind = 'pharmacy' then
              update pharmacy_profiles
                 set approved = true, status = 'approved',
                     approved_at = coalesce(approved_at, now()), approved_by = 'auto:kyc'
               where id = d.owner_id and coalesce(approved,false) = false;
            else
              update supplier_profiles
                 set approved = true, status = 'approved',
                     approved_at = coalesce(approved_at, now()), approved_by = 'auto:kyc'
               where id = d.owner_id and coalesce(approved,false) = false;
            end if;
            v_approved := found;
          exception when others then
            -- the KYC approval guard had the last word; that is not an error,
            -- it is the gate doing its job. The document stays verified.
            v_approved := false;
          end;
        end if;
      end if;
    end if;
  end if;

  -- The number is claimed only once the document is believed: a rejected or
  -- still-pending upload must not lock a licence number away from its owner.
  if v_applied and v_tier = 'clear' then
    if d.kind = 'drug_licence' then
      perform public.kyc_identity_claim_set('dl', d.number, d.owner_kind, d.owner_id::text);
    elsif d.kind = 'gst_certificate' then
      perform public.kyc_identity_claim_set('gstin', d.number, d.owner_kind, d.owner_id::text);
    end if;
  end if;

  insert into kyc_verify_run(doc_id, owner_kind, owner_id, kind, verdict, tier,
                             checks, inputs, reason, applied, approved_account,
                             actor, trigger_by)
  values (p_doc_id, d.owner_kind, d.owner_id, d.kind, v_verdict, v_tier,
          v_eval->'checks', v_eval->'inputs', v_eval->>'reason', v_applied, v_approved,
          'auto', coalesce(nullif(btrim(coalesce(p_trigger,'')),''), 'auto'));

  -- Tell the applicant, exactly the way a human verdict does. A missing route
  -- never holds up a decision.
  if v_applied then
    begin
      if d.owner_kind = 'pharmacy' then
        select coalesce(nullif(whatsapp_no,''), phone), pharmacy_name into v_phone, v_name
          from pharmacy_profiles where id = d.owner_id;
      else
        select coalesce(nullif(whatsapp_no,''), phone), supplier_name into v_phone, v_name
          from supplier_profiles where id = d.owner_id;
      end if;
      perform public.wa_send_event(
        case when v_tier = 'clear' then 'kyc_document_verified' else 'kyc_document_rejected' end,
        case when d.owner_kind = 'pharmacy' then d.owner_id else null end,
        jsonb_build_object('label', _c('kyc.kind.'||d.kind),
                           'reason', coalesce(v_eval->>'reason',''),
                           'name', coalesce(v_name,''), 'link', 'https://medibo.in/'),
        v_phone, null);
    exception when others then null;
    end;
  end if;

  return v_eval || jsonb_build_object('applied', v_applied, 'approved_account', v_approved,
    'approved_label', case when v_approved then _c('kyc_verify.approved_account') else '' end);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. OCR — the queue row, the dispatch, and the ingest the edge function calls
-- ─────────────────────────────────────────────────────────────────────────────

-- Every new document queues its own extract and pokes the reader. The trigger
-- lives on the table, so the app path, the WhatsApp token path and an admin
-- upload all behave identically.
create or replace function public._kyc_ocr_enqueue()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_key text; v_enabled boolean;
begin
  select ocr_enabled into v_enabled from kyc_verify_config where id = 1;
  if new.kind not in ('drug_licence','gst_certificate','pan') then return new; end if;

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
end $$;

drop trigger if exists kyc_ocr_enqueue on public.kyc_documents;
create trigger kyc_ocr_enqueue after insert on public.kyc_documents
  for each row execute function public._kyc_ocr_enqueue();

-- What the edge function calls back with. It carries the fields the model read
-- and, when it could geocode the printed address, the point it resolved to.
create or replace function public.kyc_ocr_ingest(
  p_doc_id uuid, p_status text, p_fields jsonb default '{}'::jsonb,
  p_geo jsonb default '{}'::jsonb, p_raw text default null,
  p_model text default null, p_error text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
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
  return public.kyc_verify_doc(p_doc_id, 'ocr');
end $$;

-- What the edge function asks for: one queued document, with the bucket and
-- path it must download and the account it must be compared against. Claiming
-- is a state move, so two readers can never work the same document.
create or replace function public.kyc_ocr_claim(p_doc_id uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare d kyc_documents%rowtype; x kyc_doc_extract%rowtype; v_addr text; v_name text;
begin
  if p_doc_id is not null then
    update kyc_doc_extract set status = 'running', updated_at = now()
     where doc_id = p_doc_id and status in ('queued','failed') and attempts < 3
     returning * into x;
  else
    update kyc_doc_extract set status = 'running', updated_at = now()
     where doc_id = (select doc_id from kyc_doc_extract
                      where status = 'queued' and attempts < 3
                      order by requested_at limit 1 for update skip locked)
     returning * into x;
  end if;
  if x.doc_id is null then return jsonb_build_object('ok', false, 'error','none_queued'); end if;

  select * into d from kyc_documents where id = x.doc_id;
  if d.owner_kind = 'pharmacy' then
    select pharmacy_name, concat_ws(', ', nullif(address,''), nullif(city,''),
                                    nullif(district,''), nullif(state,''), nullif(pincode,''))
      into v_name, v_addr from pharmacy_profiles where id = d.owner_id;
  else
    select supplier_name, concat_ws(', ', nullif(coalesce(street_address, address),''),
                                    nullif(city,''), nullif(district,''),
                                    nullif(state,''), nullif(coalesce(pin_code, pincode),''))
      into v_name, v_addr from supplier_profiles where id = d.owner_id;
  end if;

  return jsonb_build_object('ok', true, 'doc_id', d.id, 'kind', d.kind,
    'bucket', d.bucket, 'path', d.path, 'mime_type', coalesce(d.mime_type,''),
    'account_name', coalesce(v_name,''), 'account_address', coalesce(v_addr,''),
    'attempts', x.attempts);
end $$;

-- The sweep: anything queued that the poke never reached, and anything that has
-- been "running" for longer than a read can take, goes back on the queue. It
-- rides the one cron dispatcher — never its own schedule.
create or replace function public.kyc_ocr_sweep()
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_key text; v_n int := 0; r record;
begin
  update kyc_doc_extract set status = 'queued', updated_at = now()
   where status = 'running' and updated_at < now() - interval '10 minutes' and attempts < 3;

  -- Anything the reader gave up on stops being invisible: three failed attempts
  -- is a document a person must look at, so it is evaluated (which files it into
  -- the manual queue with "could not be read") rather than left queued forever.
  for r in select doc_id from kyc_doc_extract
            where status = 'failed' and attempts >= 3
              and not exists (select 1 from kyc_verify_run v
                               where v.doc_id = kyc_doc_extract.doc_id and v.tier <> 'awaiting')
  loop
    begin perform public.kyc_verify_doc(r.doc_id, 'sweep'); exception when others then null; end;
  end loop;

  select decrypted_secret into v_key from vault.decrypted_secrets
   where name = 'SERVICE_ROLE_KEY' limit 1;
  for r in select doc_id from kyc_doc_extract
            where status = 'queued' and attempts < 3
            order by requested_at limit 5
  loop
    begin
      perform net.http_post(
        url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/kyc-verify',
        headers := jsonb_build_object('Content-Type','application/json',
                     'Authorization', 'Bearer '||coalesce(v_key,'')),
        body := jsonb_build_object('doc_id', r.doc_id));
      v_n := v_n + 1;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'dispatched', v_n);
end $$;

insert into public.cron_task(name, ord, mode, work_sql, base_interval_s, max_interval_s, note)
values ('kyc_ocr_sweep', 640, 'poll', 'select public.kyc_ocr_sweep()', 180, 1800,
        'CHANGE #706 — re-dispatch KYC document reads the upload poke never reached.')
on conflict (name) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. THE WRITE GUARD — a duplicate never reaches the queue
-- ─────────────────────────────────────────────────────────────────────────────

-- The profile tables are the last line: a registration, an admin edit or an
-- import that tries to take a number another account already holds is refused
-- with the backend's own sentence. (The KYC RPCs below refuse it earlier, and
-- more kindly, with a structured reply.)
create or replace function public._kyc_identity_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_owner text; v_dl text; v_gst text; v_old_dl text; v_old_gst text; v_conf jsonb;
begin
  if tg_table_name = 'pharmacy_profiles' then
    v_owner := 'pharmacy'; v_dl := new.drug_license; v_gst := new.gstin;
    v_old_dl := case when tg_op = 'UPDATE' then old.drug_license end;
    v_old_gst := case when tg_op = 'UPDATE' then old.gstin end;
    if coalesce(new.is_deleted,false) then return new; end if;
  elsif tg_table_name = 'supplier_profiles' then
    v_owner := 'supplier'; v_dl := new.drug_license; v_gst := new.gstin;
    v_old_dl := case when tg_op = 'UPDATE' then old.drug_license end;
    v_old_gst := case when tg_op = 'UPDATE' then old.gstin end;
    if coalesce(new.is_deleted,false) then return new; end if;
  else
    v_owner := 'partner'; v_dl := new.dl_20b; v_gst := new.gstin;
    v_old_dl := case when tg_op = 'UPDATE' then old.dl_20b end;
    v_old_gst := case when tg_op = 'UPDATE' then old.gstin end;
  end if;

  -- Only a CHANGE is judged. A row that already carried a number keeps trading
  -- while its conflict is sorted out; blocking every future edit to that row
  -- would punish the wrong thing.
  if public.kyc_norm_id(v_dl) is distinct from public.kyc_norm_id(v_old_dl) then
    v_conf := public.kyc_identity_conflict('dl', v_dl, v_owner, new.id::text);
    if coalesce((v_conf->>'has')::boolean, false) then
      raise exception using errcode = 'P0001',
        message = v_conf->>'message', detail = 'duplicate_dl',
        hint = 'kyc_identity: '||coalesce(v_conf->>'owner_kind','')||'/'||coalesce(v_conf->>'owner_id','');
    end if;
  end if;
  if public.kyc_norm_id(v_gst) is distinct from public.kyc_norm_id(v_old_gst) then
    v_conf := public.kyc_identity_conflict('gstin', v_gst, v_owner, new.id::text);
    if coalesce((v_conf->>'has')::boolean, false) then
      raise exception using errcode = 'P0001',
        message = v_conf->>'message', detail = 'duplicate_gstin',
        hint = 'kyc_identity: '||coalesce(v_conf->>'owner_kind','')||'/'||coalesce(v_conf->>'owner_id','');
    end if;
  end if;
  return new;
end $$;

drop trigger if exists kyc_identity_guard_pharmacy on public.pharmacy_profiles;
create trigger kyc_identity_guard_pharmacy before insert or update of drug_license, gstin
  on public.pharmacy_profiles for each row execute function public._kyc_identity_guard();
drop trigger if exists kyc_identity_guard_supplier on public.supplier_profiles;
create trigger kyc_identity_guard_supplier before insert or update of drug_license, gstin
  on public.supplier_profiles for each row execute function public._kyc_identity_guard();
drop trigger if exists kyc_identity_guard_partner on public.region_partners;
create trigger kyc_identity_guard_partner before insert or update of dl_20b, gstin
  on public.region_partners for each row execute function public._kyc_identity_guard();

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. THE READ SURFACE — one block both screens print verbatim
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.kyc_verify_panel(p_doc_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare r kyc_verify_run%rowtype; x kyc_doc_extract%rowtype; v_mis int;
begin
  select * into r from kyc_verify_run
   where doc_id = p_doc_id order by seq desc limit 1;
  select * into x from kyc_doc_extract where doc_id = p_doc_id;

  if r.id is null then
    return jsonb_build_object(
      'has', false,
      'title', _c('kyc_verify.title'),
      'empty_note', case when coalesce(x.status,'') in ('queued','running')
                         then _c('kyc_verify.reading') else _c('kyc_verify.none_yet') end,
      'ocr_status', coalesce(x.status,''),
      'checks', '[]'::jsonb);
  end if;

  select count(*) into v_mis from jsonb_array_elements(r.checks) c
   where c->>'status' in ('warn','fail');

  return jsonb_build_object(
    'has', true,
    'title', _c('kyc_verify.title'),
    'subtitle', _c('kyc_verify.subtitle'),
    'run_id', r.id,
    'tier', r.tier,
    'tier_label', _c('kyc_verify.tier.'||r.tier),
    'verdict', r.verdict,
    'verdict_label', _c('kyc_verify.verdict.'||r.verdict),
    'tone', case r.tier when 'clear' then 'success' when 'hard_fail' then 'danger'
                        when 'review' then 'warning' else 'info' end,
    'actor', r.actor,
    'actor_label', case when r.actor = 'auto' then _c('kyc_verify.auto_badge') else '' end,
    'note', coalesce(r.note,''),
    'reason', coalesce(r.reason,''),
    'applied', r.applied,
    'approved_account', r.approved_account,
    'approved_label', case when r.approved_account then _c('kyc_verify.approved_account') else '' end,
    'decided_label', _cf('kyc_verify.decided_label',
                       jsonb_build_object('age', _ist_age(r.created_at))),
    'ocr_status', coalesce(x.status,''),
    'reading_note', case when coalesce(x.status,'') in ('queued','running')
                         then _c('kyc_verify.reading_note') else '' end,
    'mismatch_count', v_mis,
    'mismatch_heading', _c('kyc_verify.mismatch_heading'),
    'mismatch_label', case when v_mis = 0 then ''
                           else _cf('kyc_verify.mismatch_count',
                                  jsonb_build_object('n', v_mis)) end,
    'conflict_heading', _c('kyc_verify.conflict_heading'),
    'conflict', coalesce((select c->'conflict' from jsonb_array_elements(r.checks) c
                           where c ? 'conflict' limit 1), 'null'::jsonb),
    'reupload_label', case when r.tier = 'hard_fail' then _c('kyc_verify.reupload_label') else '' end,
    'checks', r.checks);
end $$;

-- The applicant's panel now carries, per document, exactly what the machine saw.
create or replace function public.kyc_my_panel()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text; v_id uuid; v_state jsonb; v_rows jsonb;
  v_cfg jsonb := coalesce((select value from app_settings where key='kyc_gate'), '{}'::jsonb);
  v_req text[] := coalesce((select array_agg(x #>> '{}')
                              from jsonb_array_elements(coalesce(v_cfg->'required_kinds','[]'::jsonb)) x),
                           array['drug_licence']);
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
      -- CHANGE #706 — ONE rejection sentence. The checks block below prints
      -- the machine's reason WITH the checks that produced it, so repeating it
      -- as a bare line above is the same sentence twice. A human reviewer's
      -- reason has no block to live in and still prints here.
      'reason_line', case
          when coalesce(d.reason,'') = '' then ''
          when coalesce(v.blk->>'reason','') = d.reason then ''
          else _cf('kyc.rejected_prefix', jsonb_build_object('reason', d.reason)) end,
      'button_label', case
          when d.id is null then _c('kyc.btn_upload')
          when d.status = 'verified' and d.valid_to is not null
               and d.valid_to < (now() at time zone 'Asia/Kolkata')::date then _c('kyc.btn_renew')
          else _c('kyc.btn_replace') end,
      -- CHANGE #706: what the automatic checks made of this document.
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
  ) x;

  return jsonb_build_object(
    'ok', true,
    'title', _c('kyc.title'),
    'subtitle', _c('kyc.subtitle'),
    'empty_note', _c('kyc.empty_note'),
    'bucket', 'kyc-docs',
    'upload_prefix', auth.uid()::text,
    'owner_kind', v_kind,
    'owner_id', v_id,
    'state', v_state,
    'verify_title', _c('kyc_verify.title'),
    'items', v_rows);
end $$;

-- The review console gets the same block, plus the mismatch list it is meant to
-- work from and the conflicting account by name.
create or replace function public.kyc_review_queue(
  p_status text default 'pending', p_owner_kind text default null,
  p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_status text := lower(coalesce(nullif(p_status,''),'pending'));
  v_kind   text := nullif(lower(btrim(coalesce(p_owner_kind,''))),'');
  v_admin  boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_zone   int := public.partner_zone_id();
  v_lim    int := least(greatest(coalesce(p_limit,50),1), 200);
  v_off    int := greatest(coalesce(p_offset,0),0);
  v_rows jsonb; v_total int; v_pending int; v_auto int;
begin
  if not public.kyc_can_review('read') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'title', _c('kyc_review.title'),
      'message', _c('kyc_review.err_not_authorized'));
  end if;

  with scoped as (
    select d.*,
           case d.owner_kind when 'pharmacy' then p.pharmacy_name else s.supplier_name end as owner_name,
           case d.owner_kind when 'pharmacy' then p.phone         else s.phone         end as owner_phone,
           case d.owner_kind when 'pharmacy' then p.city          else s.city          end as owner_city
      from kyc_documents d
      left join pharmacy_profiles p on d.owner_kind = 'pharmacy' and p.id = d.owner_id
      left join supplier_profiles s on d.owner_kind = 'supplier' and s.id = d.owner_id
     where d.status = v_status
       and (v_kind is null or d.owner_kind = v_kind)
       and (v_admin or v_zone is null or coalesce(d.zone_id, -1) = v_zone)
  )
  select coalesce(jsonb_agg(r order by ord), '[]'::jsonb), max(n_total)
    into v_rows, v_total
  from (
    select row_number() over (order by submitted_at desc) as ord,
           count(*) over () as n_total,
           jsonb_build_object(
             'doc_id', id,
             'owner_kind', owner_kind,
             'owner_id', owner_id,
             'owner_name', coalesce(owner_name,''),
             'owner_city', coalesce(owner_city,''),
             'kind', kind,
             'kind_label', _c('kyc.kind.'||kind),
             'number', coalesce(number,''),
             'number_label', _c('kyc.number_label'),
             'valid_to', valid_to,
             'expiry_label', case when valid_to is null then _c('kyc.no_expiry_label')
                                  else _cf('kyc.expiry_label',
                                         jsonb_build_object('d', to_char(valid_to,'FMDD Mon YYYY'))) end,
             'bucket', bucket,
             'path', path,
             'file_name', coalesce(file_name,''),
             'status', status,
             'status_label', _c('kyc.status.'||status),
             'status_tone', case status when 'verified' then 'success'
                                        when 'rejected' then 'danger' else 'info' end,
             'reason', coalesce(reason,''),
             'submitted_label', _cf('kyc_review.submitted_label',
                                  jsonb_build_object('age', _ist_age(submitted_at))),
             'view_label', _c('kyc_review.btn_view'),
             'verify_label', _c('kyc_review.btn_verify'),
             'reject_label', _c('kyc_review.btn_reject'),
             -- CHANGE #706
             'verify', public.kyc_verify_panel(id)) as r
      from scoped
     order by submitted_at desc
     limit v_lim offset v_off
  ) x;

  select count(*) into v_pending from kyc_documents d
   where d.status = 'pending' and (v_admin or v_zone is null or coalesce(d.zone_id,-1) = v_zone);

  select count(*) into v_auto from kyc_documents d
   where d.status = 'pending' and (v_admin or v_zone is null or coalesce(d.zone_id,-1) = v_zone)
     and exists (select 1 from kyc_verify_run v where v.doc_id = d.id and v.tier = 'review');

  return jsonb_build_object(
    'ok', true,
    'title', _c('kyc_review.title'),
    'subtitle', _c('kyc_review.subtitle'),
    'empty_note', _c('kyc_review.empty'),
    'can_write', public.kyc_can_review('write'),
    'reason_label', _c('kyc_review.reason_label'),
    'reason_hint', _c('kyc_review.reason_hint'),
    'count_label', _cf('kyc_review.count_label', jsonb_build_object('n', v_pending)),
    'pending_count', v_pending,
    'flagged_count', v_auto,
    'flagged_label', case when v_auto = 0 then ''
                          else _cf('kyc_verify.mismatch_count', jsonb_build_object('n', v_auto)) end,
    'override_label', _c('kyc_verify.override_label'),
    'override_note_label', _c('kyc_verify.override_note_label'),
    'override_note_hint', _c('kyc_verify.override_note_hint'),
    'rerun_label', _c('kyc_verify.rerun_label'),
    'verify_title', _c('kyc_verify.title'),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','pending',  'label', _c('kyc_review.tab_pending')),
      jsonb_build_object('key','verified', 'label', _c('kyc_review.tab_verified')),
      jsonb_build_object('key','rejected', 'label', _c('kyc_review.tab_rejected'))),
    'status', v_status,
    'offset', v_off,
    'has_more', (v_off + v_lim) < coalesce(v_total, 0),
    'total', coalesce(v_total, 0),
    'rows', v_rows);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. THE HUMAN'S LAST WORD — override with a note, and re-run
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.kyc_verify_override(
  p_doc_id uuid, p_status text, p_note text)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  d kyc_documents%rowtype;
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_status text := lower(btrim(coalesce(p_status,'')));
  v_prev jsonb; v_set jsonb;
begin
  if not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('kyc_verify.err_not_authorized'));
  end if;
  if v_note is null then
    return jsonb_build_object('ok', false, 'error','no_note', 'tone','danger',
      'message', _c('kyc_verify.err_no_note'));
  end if;
  select * into d from kyc_documents where id = p_doc_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_doc', 'tone','danger',
      'message', _c('kyc_verify.err_no_doc'));
  end if;

  select jsonb_build_object('previous_status', d.status, 'previous_reason', coalesce(d.reason,''),
                            'previous_verdict', coalesce(r.verdict,''), 'previous_tier', coalesce(r.tier,''))
    into v_prev
    from (select * from kyc_verify_run where doc_id = p_doc_id
           order by seq desc limit 1) r
   right join (select 1) one on true;

  -- The verdict itself is written by the one door that already tells the
  -- applicant and re-reads the account state.
  v_set := public.kyc_review_set(p_doc_id, v_status, v_note);
  if not coalesce((v_set->>'ok')::boolean, false) then return v_set; end if;

  -- An overridden document that is now verified owns its number.
  if v_status = 'verified' then
    if d.kind = 'drug_licence' then
      perform public.kyc_identity_claim_set('dl', d.number, d.owner_kind, d.owner_id::text);
    elsif d.kind = 'gst_certificate' then
      perform public.kyc_identity_claim_set('gstin', d.number, d.owner_kind, d.owner_id::text);
    end if;
  end if;

  insert into kyc_verify_run(doc_id, owner_kind, owner_id, kind, verdict, tier,
                             checks, inputs, reason, applied, actor, actor_id, note, trigger_by)
  values (p_doc_id, d.owner_kind, d.owner_id, d.kind, 'override', 'override',
          coalesce((select checks from kyc_verify_run where doc_id = p_doc_id
                     and tier <> 'override' order by seq desc limit 1), '[]'::jsonb),
          coalesce(v_prev,'{}'::jsonb) || jsonb_build_object('new_status', v_status),
          v_note, true, 'admin', auth.uid(), v_note, 'override');

  return jsonb_build_object('ok', true, 'tone','success',
    'message', _c('kyc_verify.override_toast'),
    'doc_id', p_doc_id, 'status', v_status,
    'verify', public.kyc_verify_panel(p_doc_id),
    'owner_state', public.kyc_state(d.owner_kind, d.owner_id));
end $$;

create or replace function public.kyc_verify_rerun(p_doc_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', _c('kyc_verify.err_not_authorized'));
  end if;
  v := public.kyc_verify_doc(p_doc_id, 'admin_rerun');
  if not coalesce((v->>'ok')::boolean, false) then return v; end if;
  return jsonb_build_object('ok', true, 'tone','success',
    'message', _c('kyc_verify.rerun_toast'),
    'doc_id', p_doc_id, 'verify', public.kyc_verify_panel(p_doc_id));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. THE WRITE RPCs — a duplicate is refused before a row is ever created
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.kyc_upload_register(
  p_kind text, p_path text, p_file_name text default null, p_number text default null,
  p_valid_from date default null, p_valid_to date default null,
  p_mime text default null, p_bytes bigint default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare
  v_me jsonb := public.kyc_owner_for_me();
  v_kind text := lower(btrim(coalesce(p_kind,'')));
  v_owner text; v_id uuid; v_zone smallint; v_doc uuid; v_conf jsonb;
begin
  if not coalesce((v_me->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', v_me->>'reason', 'tone','danger',
      'message', case v_me->>'reason' when 'not_signed_in' then _c('kyc.err_not_signed_in')
                                      else _c('kyc.err_no_owner') end);
  end if;
  if v_kind not in ('drug_licence','gst_certificate','shop_photo','pan') then
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

  -- CHANGE #706 — one licence, one GSTIN, one account. Refused here so the
  -- applicant reads a sentence instead of a database error, and so no row is
  -- created for a number that can never be verified.
  if v_kind = 'drug_licence' then
    v_conf := public.kyc_identity_conflict('dl', p_number, v_owner, v_id::text);
  elsif v_kind = 'gst_certificate' then
    v_conf := public.kyc_identity_conflict('gstin', p_number, v_owner, v_id::text);
  else
    v_conf := jsonb_build_object('has', false);
  end if;
  if coalesce((v_conf->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error','duplicate', 'tone','danger',
      'message', v_conf->>'message', 'conflict', v_conf);
  end if;

  if v_owner = 'pharmacy' then
    select zone_id into v_zone from pharmacy_profiles where id = v_id;
  else
    select zone_id into v_zone from supplier_profiles where id = v_id;
  end if;

  update kyc_documents set status = 'superseded', updated_at = now()
   where owner_kind = v_owner and owner_id = v_id and kind = v_kind
     and status in ('pending','verified');

  insert into kyc_documents(owner_kind, owner_id, kind, path, file_name, mime_type, bytes,
                            number, valid_from, valid_to, submitted_by, zone_id, source)
  values (v_owner, v_id, v_kind, btrim(p_path), nullif(btrim(coalesce(p_file_name,'')),''),
          nullif(btrim(coalesce(p_mime,'')),''), p_bytes,
          nullif(btrim(coalesce(p_number,'')),''), p_valid_from, p_valid_to,
          auth.uid(), v_zone, 'app')
  returning id into v_doc;

  if v_kind = 'drug_licence' then
    if v_owner = 'pharmacy' then
      update pharmacy_profiles
         set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
             dl_expiry    = coalesce(p_valid_to, dl_expiry)
       where id = v_id;
    else
      update supplier_profiles
         set drug_license = coalesce(nullif(btrim(coalesce(p_number,'')),''), drug_license),
             dl_expiry    = coalesce(p_valid_to, dl_expiry)
       where id = v_id;
    end if;
  elsif v_kind = 'gst_certificate' then
    if v_owner = 'pharmacy' then
      update pharmacy_profiles
         set gstin = coalesce(nullif(btrim(coalesce(p_number,'')),''), gstin)
       where id = v_id;
    else
      update supplier_profiles
         set gstin        = coalesce(nullif(btrim(coalesce(p_number,'')),''), gstin),
             gstin_expiry = coalesce(p_valid_to, gstin_expiry)
       where id = v_id;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'tone','success', 'doc_id', v_doc,
    'message', _c('kyc.saved_toast'),
    'verify', public.kyc_verify_panel(v_doc),
    'panel', public.kyc_my_panel());
end $$;

create or replace function public.kyc_token_submit(
  p_token text, p_path text, p_number text default null,
  p_valid_to date default null, p_file_name text default null)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare t kyc_upload_token%rowtype; v_zone smallint; v_doc uuid; v_conf jsonb;
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

  v_conf := public.kyc_identity_conflict('dl', p_number, t.owner_kind, t.owner_id::text);
  if coalesce((v_conf->>'has')::boolean, false) then
    return jsonb_build_object('ok', false, 'error','duplicate', 'tone','danger',
      'message', v_conf->>'message', 'conflict', v_conf);
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
    'title', _c('kyc_token.done_title'), 'message', _c('kyc_token.done_body'),
    'verify', public.kyc_verify_panel(v_doc));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 15. CONFIG READ/WRITE + grants
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.kyc_verify_config_get()
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare c kyc_verify_config%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select * into c from kyc_verify_config where id = 1;
  return jsonb_build_object('ok', true, 'config', to_jsonb(c));
end $$;

create or replace function public.kyc_verify_config_set(p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare c kyc_verify_config%rowtype;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  update kyc_verify_config set
    ocr_enabled            = coalesce((p_patch->>'ocr_enabled')::boolean, ocr_enabled),
    geo_max_metres         = coalesce((p_patch->>'geo_max_metres')::int, geo_max_metres),
    name_similarity_min    = coalesce((p_patch->>'name_similarity_min')::numeric, name_similarity_min),
    field_similarity_min   = coalesce((p_patch->>'field_similarity_min')::numeric, field_similarity_min),
    default_gst_state_code = coalesce(nullif(p_patch->>'default_gst_state_code',''), default_gst_state_code),
    auto_verify_pharmacy   = coalesce((p_patch->>'auto_verify_pharmacy')::boolean, auto_verify_pharmacy),
    auto_verify_supplier   = coalesce((p_patch->>'auto_verify_supplier')::boolean, auto_verify_supplier),
    auto_approve_pharmacy  = coalesce((p_patch->>'auto_approve_pharmacy')::boolean, auto_approve_pharmacy),
    auto_approve_supplier  = coalesce((p_patch->>'auto_approve_supplier')::boolean, auto_approve_supplier),
    updated_at = now(), updated_by = auth.uid()
  where id = 1 returning * into c;
  return jsonb_build_object('ok', true, 'config', to_jsonb(c));
end $$;

grant execute on function public.kyc_verify_panel(uuid)                      to authenticated;
grant execute on function public.kyc_verify_evaluate(uuid)                   to authenticated;
grant execute on function public.kyc_verify_override(uuid, text, text)       to authenticated;
grant execute on function public.kyc_verify_rerun(uuid)                      to authenticated;
grant execute on function public.kyc_verify_config_get()                     to authenticated;
grant execute on function public.kyc_verify_config_set(jsonb)                to authenticated;
grant execute on function public.kyc_identity_conflict(text, text, text, text) to authenticated;
grant execute on function public.kyc_gstin_checksum_ok(text)                 to authenticated, anon;
grant execute on function public.kyc_pan_of_gstin(text)                      to authenticated;
grant execute on function public.kyc_metres_label(integer)                   to authenticated;
grant execute on function public.kyc_verify_doc(uuid, text)                  to service_role;
grant execute on function public.kyc_ocr_ingest(uuid, text, jsonb, jsonb, text, text, text) to service_role;
grant execute on function public.kyc_ocr_claim(uuid)                         to service_role;
grant execute on function public.kyc_ocr_sweep()                             to service_role;

-- The applicant reads their own verification; nobody writes these tables from a
-- client. Every write goes through the SECURITY DEFINER functions above.
drop policy if exists kyc_doc_extract_read on public.kyc_doc_extract;
create policy kyc_doc_extract_read on public.kyc_doc_extract for select to authenticated
  using (exists (select 1 from kyc_documents d where d.id = kyc_doc_extract.doc_id
                  and (public.get_my_role() = any (array['admin','super_admin'])
                       or (d.owner_kind = 'pharmacy' and d.owner_id in
                             (select id from pharmacy_profiles where user_id = auth.uid()))
                       or (d.owner_kind = 'supplier' and d.owner_id in
                             (select id from supplier_profiles where user_id = auth.uid())))));

drop policy if exists kyc_verify_run_read on public.kyc_verify_run;
create policy kyc_verify_run_read on public.kyc_verify_run for select to authenticated
  using (exists (select 1 from kyc_documents d where d.id = kyc_verify_run.doc_id
                  and (public.get_my_role() = any (array['admin','super_admin'])
                       or (d.owner_kind = 'pharmacy' and d.owner_id in
                             (select id from pharmacy_profiles where user_id = auth.uid()))
                       or (d.owner_kind = 'supplier' and d.owner_id in
                             (select id from supplier_profiles where user_id = auth.uid())))));

drop policy if exists kyc_identity_claim_admin on public.kyc_identity_claim;
create policy kyc_identity_claim_admin on public.kyc_identity_claim for select to authenticated
  using (public.get_my_role() = any (array['admin','super_admin']));

drop policy if exists kyc_verify_config_admin on public.kyc_verify_config;
create policy kyc_verify_config_admin on public.kyc_verify_config for select to authenticated
  using (public.get_my_role() = any (array['admin','super_admin']));
