-- replay-target: production
-- CMD #1886 — THE CUSTOMER REGISTRATION PIPELINE.
--
-- 22 auth logins, 13 profiles. crazidkm, medibonetwork, pallavi.medicom,
-- trivenisahu478 and prateekkaushal721 signed in and vanished, because a person
-- who signs in and does not finish the form appears on NO screen anybody opens.
-- The Customers screen only ever knew two states — "pending registrations" and
-- "approved customers" — and `status` itself held three spellings of two ideas
-- ('Active', 'active', 'approved', 'pending').
--
-- This file gives the funnel a name at every step, an owner, and a next date:
--   signed_up -> details -> documents -> verified -> approved
--
-- Everything a screen prints is built here: the chip word and its tone, the
-- missing-field sentence, the WhatsApp button's label, the approve refusal and
-- the field it points at. Flutter renders; it decides nothing.

begin;

-- ── 1. the stage enum, on the profile ──────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_type where typname = 'registration_stage') then
    create type public.registration_stage as enum
      ('signed_up','details','documents','verified','approved');
  end if;
end $$;

alter table public.pharmacy_profiles
  add column if not exists registration_stage public.registration_stage,
  add column if not exists assigned_to        uuid,
  add column if not exists next_action_at     timestamptz,
  add column if not exists followup_note      text;

create index if not exists idx_pp_registration_stage on public.pharmacy_profiles (registration_stage);
create index if not exists idx_pp_next_action        on public.pharmacy_profiles (next_action_at) where next_action_at is not null;

-- ── 2. the follow-up row for a person who has no profile yet ───────────────
create table if not exists public.customer_signup_followup (
  auth_user_id   uuid primary key,
  assigned_to    uuid,
  next_action_at timestamptz,
  note           text,
  zone_id        smallint,
  nudged_at      timestamptz,
  nudge_count    integer not null default 0,
  is_synthetic   boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
alter table public.customer_signup_followup enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='customer_signup_followup'
                    and policyname='c1886_signup_followup_admin') then
    create policy c1886_signup_followup_admin on public.customer_signup_followup
      for all to authenticated
      using (public.role_for_medibo_only() in ('admin','super_admin'))
      with check (public.role_for_medibo_only() in ('admin','super_admin'));
  end if;
end $$;

-- The synthetic layer stamps this table like any other (CMD #1848's reader).
drop trigger if exists a0_synthetic_inherit on public.customer_signup_followup;
create trigger a0_synthetic_inherit before insert or update
  on public.customer_signup_followup
  for each row execute function public._synthetic_inherit();

-- ── 3. the required fields ARE DATA, not a WHERE clause ────────────────────
create table if not exists public.customer_required_field (
  field_key   text primary key,
  label       text not null,
  stage_key   text not null,          -- the stage this field is needed BY
  sort_order  integer not null default 100,
  is_active   boolean not null default true
);

insert into public.customer_required_field(field_key,label,stage_key,sort_order) values
  ('pharmacy_name','Pharmacy name','details',10),
  ('owner_name',   'Owner name',   'details',20),
  ('phone',        'Phone',        'details',30),
  ('address',      'Address',      'details',40),
  ('city',         'City',         'details',50),
  ('pincode',      'Pincode',      'details',60),
  ('zone_id',      'Zone',         'details',70),
  ('drug_license', 'Drug licence', 'documents',80),
  ('gstin',        'GSTIN',        'documents',90),
  ('dl_expiry',    'Licence expiry','documents',100)
on conflict (field_key) do update
  set label = excluded.label, stage_key = excluded.stage_key, sort_order = excluded.sort_order;

-- Which of those a given profile is still missing, in the table's own order.
create or replace function public.customer_missing_fields(p_customer_id uuid)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('field_key', f.field_key, 'label', f.label,
                                               'stage_key', f.stage_key)
                            order by f.sort_order), '[]'::jsonb)
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
      else false end;
$$;

-- ── 4. the stage a profile is ACTUALLY at, derived from its own data ────────
create or replace function public.customer_stage_of(p_customer_id uuid)
returns public.registration_stage language plpgsql stable as $$
declare pp public.pharmacy_profiles%rowtype; v_missing jsonb; v_kyc text;
begin
  select * into pp from public.pharmacy_profiles where id = p_customer_id;
  if pp.id is null then return null; end if;
  if coalesce(pp.approved,false) or lower(btrim(coalesce(pp.status,''))) in ('approved','active')
    then return 'approved'::public.registration_stage; end if;

  begin
    v_kyc := public.kyc_state('pharmacy', pp.id) ->> 'state';
  exception when others then v_kyc := null;
  end;
  if coalesce(v_kyc,'') = 'verified' then return 'verified'::public.registration_stage; end if;

  v_missing := public.customer_missing_fields(pp.id);
  if not exists (select 1 from jsonb_array_elements(v_missing) e
                  where e->>'stage_key' = 'documents')
    then return 'documents'::public.registration_stage; end if;
  if not exists (select 1 from jsonb_array_elements(v_missing) e
                  where e->>'stage_key' = 'details')
    then return 'details'::public.registration_stage; end if;
  return 'signed_up'::public.registration_stage;
end $$;

-- ── 5. status and stage never disagree again ───────────────────────────────
-- status held 'Active' / 'active' / 'approved' / 'pending' for two ideas. The
-- stage is the truth now; status is kept as its canonical shadow so that every
-- reader written before this file keeps working.
create or replace function public._c1886_stage_sync() returns trigger
language plpgsql as $$
declare v_stage public.registration_stage;
begin
  -- an explicit stage write wins, and drives status
  if tg_op = 'UPDATE' and new.registration_stage is distinct from old.registration_stage
     and new.registration_stage is not null then
    v_stage := new.registration_stage;
  else
    if coalesce(new.approved,false)
       or lower(btrim(coalesce(new.status,''))) in ('approved','active') then
      v_stage := 'approved';
    else
      -- derived stages need the row to exist; on INSERT it does not yet, so the
      -- cheap shape test runs inline and the AFTER trigger refines it.
      v_stage := case
        when nullif(btrim(coalesce(new.drug_license, new.dl_20b, new.dl_21b,'')),'') is not null
         and nullif(btrim(coalesce(new.gstin, new.gst_no,'')),'') is not null
         and new.dl_expiry is not null                                   then 'documents'
        when nullif(btrim(coalesce(new.pharmacy_name,'')),'') is not null
         and nullif(btrim(coalesce(new.city,'')),'') is not null
         and nullif(btrim(coalesce(new.pincode,'')),'') is not null
         and nullif(btrim(coalesce(new.phone, new.whatsapp_no,'')),'') is not null then 'details'
        else 'signed_up' end;
    end if;
  end if;

  new.registration_stage := v_stage;
  new.status := case v_stage when 'approved' then 'approved' else 'pending' end;
  if v_stage = 'approved' then new.approved := true; end if;
  return new;
end $$;

drop trigger if exists trg_c1886_stage_sync on public.pharmacy_profiles;
create trigger trg_c1886_stage_sync before insert or update
  on public.pharmacy_profiles
  for each row execute function public._c1886_stage_sync();

-- backfill: derive every existing row once, then let the trigger hold it.
do $$
declare r record;
begin
  for r in select id from public.pharmacy_profiles loop
    update public.pharmacy_profiles
       set registration_stage = public.customer_stage_of(r.id)
     where id = r.id;
  end loop;
end $$;

commit;
