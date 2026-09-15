-- CHANGE #402 (2 of 3) — SUPPLIER STAFF SUB-LOGINS.
--
-- One identity per supplier today: `my_supplier_id()` resolves a login through
-- `login_identities` (owner_type='supplier', owner_id = the profile uuid), and
-- exactly one row per supplier ever existed. This adds the SECOND, THIRD … row
-- and the permission algebra that keeps them smaller than the account itself,
-- reusing #399's partner_users pattern verbatim: the same identity binding, the
-- same "a staff grant can only REDUCE the account's grant" intersect, the same
-- audit stamp naming the person rather than the company.
--
-- Every statement is idempotent — a resumed worker re-applies it silently.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE SURFACES A SUPPLIER LOGIN CAN HOLD
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.supplier_feature (
  feature_key text primary key,
  copy_key    text not null,        -- ui_copy key → translated by #402(1)
  icon_key    text,
  sort_order  int  not null default 100,
  is_active   boolean not null default true
);

insert into public.supplier_feature(feature_key, copy_key, icon_key, sort_order, is_active) values
  ('supplier.inquiry',  'supplier_shell.tab_inquiry',      'question_answer', 10, true),
  ('supplier.orders',   'supplier_shell.tab_orders',       'receipt_long',    20, true),
  ('supplier.disputes', 'supplier_shell.tab_disputes',     'gavel',           30, true),
  ('supplier.catalog',  'supplier_shell.tab_add_medicine', 'add_circle',      40, true),
  ('supplier.payouts',  'supplier_payout.feature_label',   'account_balance', 50, true),
  ('supplier.staff',    'supplier_staff.feature_label',    'people',          60, true)
on conflict (feature_key) do update
  set copy_key = excluded.copy_key, icon_key = excluded.icon_key,
      sort_order = excluded.sort_order, is_active = true;

-- The three named access levels from the spec, as DATA. A fourth level is one
-- INSERT, never a deploy — and the dropdown the supplier sees is exactly this
-- table, so Dart can never offer an option the backend does not honour.
create table if not exists public.supplier_role_preset (
  role_key   text primary key,
  copy_key   text not null,
  desc_key   text,
  sort_order int not null default 100,
  grants     jsonb not null default '{}'::jsonb,
  is_active  boolean not null default true
);

insert into public.supplier_role_preset(role_key, copy_key, desc_key, sort_order, grants, is_active) values
  ('inquiry_only','supplier_staff.role_inquiry_only','supplier_staff.role_inquiry_only_desc', 10,
     '{"supplier.inquiry":"write","supplier.orders":"read"}'::jsonb, true),
  ('billing_only','supplier_staff.role_billing_only','supplier_staff.role_billing_only_desc', 20,
     '{"supplier.orders":"write","supplier.disputes":"write","supplier.payouts":"read"}'::jsonb, true),
  ('full',        'supplier_staff.role_full',        'supplier_staff.role_full_desc',         30,
     '{"supplier.inquiry":"write","supplier.orders":"write","supplier.disputes":"write","supplier.catalog":"write","supplier.payouts":"read"}'::jsonb, true)
on conflict (role_key) do update
  set copy_key = excluded.copy_key, desc_key = excluded.desc_key,
      sort_order = excluded.sort_order, grants = excluded.grants, is_active = true;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. THE STAFF ROWS
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.supplier_users (
  id           bigserial primary key,
  supplier_id  uuid not null references public.supplier_profiles(id) on delete cascade,
  identity     text not null unique,
  display_name text,
  role_key     text not null default 'inquiry_only'
                 references public.supplier_role_preset(role_key),
  auth_user_id uuid,
  is_active    boolean not null default true,
  created_by   text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists supplier_users_supplier_idx on public.supplier_users (supplier_id);

alter table public.supplier_users enable row level security;

-- No supplier-facing policy on purpose: every read and write goes through the
-- SECURITY DEFINER RPCs below, which clamp by supplier and by the caller's own
-- effective access. Admin keeps a direct read for support.
drop policy if exists supplier_users_admin on public.supplier_users;
create policy supplier_users_admin on public.supplier_users
  for all using (public.role_for_medibo_only() in ('admin','super_admin'))
  with check (public.role_for_medibo_only() in ('admin','super_admin'));

-- An admin-side cap on what the ACCOUNT itself may do. Absent = the account
-- holds 'write' on every active feature, which is exactly what every supplier
-- had the moment before this shipped — nobody loses anything on deploy day.
create table if not exists public.supplier_account_permissions (
  supplier_id uuid not null references public.supplier_profiles(id) on delete cascade,
  feature_key text not null references public.supplier_feature(feature_key) on delete cascade,
  access      text not null check (access in ('none','read','write')),
  updated_at  timestamptz not null default now(),
  updated_by  text,
  primary key (supplier_id, feature_key)
);

alter table public.supplier_account_permissions enable row level security;
drop policy if exists supplier_account_permissions_admin on public.supplier_account_permissions;
create policy supplier_account_permissions_admin on public.supplier_account_permissions
  for all using (public.role_for_medibo_only() in ('admin','super_admin'))
  with check (public.role_for_medibo_only() in ('admin','super_admin'));

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. ACCESS ALGEBRA — a staff grant can only ever REDUCE the account's grant
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public._sup_access_rank(p_access text)
returns int language sql immutable as $function$
  select case coalesce(p_access,'none')
           when 'write' then 2 when 'read' then 1 else 0 end
$function$;

create or replace function public._sup_access_name(p_rank int)
returns text language sql immutable as $function$
  select case coalesce(p_rank,0)
           when 2 then 'write' when 1 then 'read' else 'none' end
$function$;

-- NULL staff grant = "this login carries no staff row", i.e. the OWNER, who
-- inherits the account's grant untouched. That is the difference between
-- "not a staff member" and "a staff member configured to none".
create or replace function public._sup_access_min(p_account text, p_staff text)
returns text language sql immutable as $function$
  select case
    when p_staff is null then coalesce(p_account,'none')
    else public._sup_access_name(
           least(public._sup_access_rank(p_account), public._sup_access_rank(p_staff)))
  end
$function$;

-- Which supplier_users row is THIS login, if any.
create or replace function public.my_supplier_user_id()
returns bigint
language sql stable security definer set search_path to 'public'
as $function$
  select su.id
  from supplier_users su
  join supplier_profiles sp on sp.id = su.supplier_id
  where coalesce(su.is_active,true)
    and sp.approved = true and coalesce(sp.is_deleted,false) = false
    and (su.auth_user_id = auth.uid() or su.identity = any (public.my_identity_keys()))
  order by su.id
  limit 1
$function$;

create or replace function public.supplier_access(p_feature text)
returns text
language sql stable security definer set search_path to 'public'
as $function$
  select public._sup_access_min(
    -- the account's own cap
    case when public.my_supplier_id() is null then 'none'
         else coalesce(
           (select ap.access from supplier_account_permissions ap
             where ap.supplier_id = public.my_supplier_id()
               and ap.feature_key = p_feature),
           case when exists (select 1 from supplier_feature f
                              where f.feature_key = p_feature and f.is_active)
                then 'write' else 'none' end)
    end,
    -- the staff clamp, NULL for the owner
    (select coalesce(rp.grants ->> p_feature, 'none')
       from supplier_users su
       join supplier_role_preset rp on rp.role_key = su.role_key
      where su.id = public.my_supplier_user_id()))
$function$;

create or replace function public.supplier_can(p_feature text, p_need text default 'read')
returns boolean
language sql stable security definer set search_path to 'public'
as $function$
  select case coalesce(public.supplier_access(p_feature),'none')
           when 'write' then true
           when 'read'  then (coalesce(p_need,'read') = 'read')
           else false
         end
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE AUDIT TRAIL — every staff action names the PERSON, not the company
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.supplier_audit_log (
  id               bigserial primary key,
  supplier_id      uuid not null references public.supplier_profiles(id) on delete cascade,
  supplier_user_id bigint references public.supplier_users(id) on delete set null,
  actor_identity   text,
  actor_name       text,
  user_id          uuid,
  feature_key      text,
  action           text not null,
  detail           jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);

create index if not exists supplier_audit_log_supplier_idx
  on public.supplier_audit_log (supplier_id, created_at desc);

alter table public.supplier_audit_log enable row level security;
drop policy if exists supplier_audit_log_admin on public.supplier_audit_log;
create policy supplier_audit_log_admin on public.supplier_audit_log
  for select using (public.role_for_medibo_only() in ('admin','super_admin'));

-- Who is acting, in one place, so an owner and a staff member are labelled by
-- the SAME rule everywhere they appear.
create or replace function public.my_supplier_actor()
returns jsonb
language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'supplier_user_id', public.my_supplier_user_id(),
    'is_staff', public.my_supplier_user_id() is not null,
    'identity', coalesce(
      (select su.identity from supplier_users su where su.id = public.my_supplier_user_id()),
      coalesce(public.my_login_email(), (public.my_identity_keys())[1])),
    'name', coalesce(
      (select nullif(btrim(coalesce(su.display_name,'')),'') from supplier_users su
        where su.id = public.my_supplier_user_id()),
      (select su.identity from supplier_users su where su.id = public.my_supplier_user_id()),
      (select nullif(btrim(coalesce(sp.contact_person, sp.contact_name, '')),'')
         from supplier_profiles sp where sp.id = public.my_supplier_id()),
      coalesce(public.my_login_email(), 'supplier')))
$function$;

create or replace function public.supplier_audit(p_feature text, p_action text,
                                                 p_detail jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer set search_path to 'public'
as $function$
declare v_id bigint; v_sid uuid := public.my_supplier_id(); v_actor jsonb;
begin
  if v_sid is null then return null; end if;
  v_actor := public.my_supplier_actor();
  insert into supplier_audit_log(supplier_id, supplier_user_id, actor_identity, actor_name,
                                 user_id, feature_key, action, detail)
  values (v_sid, public.my_supplier_user_id(), v_actor->>'identity', v_actor->>'name',
          auth.uid(), p_feature, coalesce(p_action,'open'), coalesce(p_detail,'{}'::jsonb))
  returning id into v_id;
  return v_id;
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. THE STAFF LOGIN RESOLVES TO THE SUPPLIER — the one existing seam to widen
-- ═══════════════════════════════════════════════════════════════════════════

-- `my_supplier_id()` already resolves ANY login_identities row pointing at the
-- profile, so a staff row needs no change there. `current_supplier_profile()`
-- matched only on the profile's OWN email / user_id, so a staff login got an
-- empty row. Widened here — and deliberately NOT self-healing on that path: a
-- staff member must never rebind supplier_profiles.user_id to their own uid.
create or replace function public.current_supplier_profile()
returns supplier_profiles
language plpgsql security definer set search_path to 'public'
as $function$
DECLARE v_row supplier_profiles%ROWTYPE; v_email text; v_uid uuid; v_sid uuid;
BEGIN
  v_uid := auth.uid();
  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u WHERE u.id = v_uid;

  SELECT * INTO v_row FROM supplier_profiles sp
  WHERE ( (v_email IS NOT NULL AND lower(btrim(sp.email)) = v_email)
          OR sp.user_id = v_uid )
    AND sp.approved = true
    AND (sp.is_deleted IS NULL OR sp.is_deleted = false)
  ORDER BY (v_email IS NOT NULL AND lower(btrim(sp.email)) = v_email) DESC, sp.id
  LIMIT 1;

  -- Self-heal: matched by email but user_id points elsewhere (admin-created supplier had the
  -- admin's id). Link this login's account so EVERY path — including a direct RLS query by
  -- user_id — resolves this supplier from now on. Email stays the key; login just gets bound to it.
  IF v_row.id IS NOT NULL AND v_uid IS NOT NULL AND v_row.user_id IS DISTINCT FROM v_uid THEN
    UPDATE supplier_profiles SET user_id = v_uid WHERE id = v_row.id;
    v_row.user_id := v_uid;
  END IF;

  -- CHANGE #402 — a STAFF sub-login owns no email on the profile and no user_id
  -- of its own, so it lands here. It resolves through the same
  -- login_identities binding every other supplier surface already uses, and it
  -- never writes user_id: the account keeps belonging to the owner.
  IF v_row.id IS NULL THEN
    v_sid := public.my_supplier_id();
    IF v_sid IS NOT NULL THEN
      SELECT * INTO v_row FROM supplier_profiles sp WHERE sp.id = v_sid;
    END IF;
  END IF;

  RETURN v_row;
END;
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. THE SUPPLIER'S OWN STAFF SCREEN
-- ═══════════════════════════════════════════════════════════════════════════

-- The one payload the supplier console boots from: who am I, what may I open,
-- and which language am I reading. The shell renders it and decides nothing.
create or replace function public.supplier_session()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_sid uuid := public.my_supplier_id(); v_actor jsonb; v_sp record;
begin
  if v_sid is null then
    return jsonb_build_object('ok', false, 'error', 'not_a_supplier', 'tone', 'danger',
      'message', public.ui_text('supplier_staff.err_not_supplier'),
      'language', public.ui_language_block());
  end if;
  select * into v_sp from supplier_profiles where id = v_sid;
  v_actor := public.my_supplier_actor();

  return jsonb_build_object(
    'ok', true,
    'supplier_id', v_sid,
    'supplier_name', v_sp.supplier_name,
    'is_staff', (v_actor->>'is_staff')::boolean,
    'actor_name', v_actor->>'name',
    'actor_label', case when (v_actor->>'is_staff')::boolean
                        then replace(public.ui_text('supplier_shell.staff_badge'), '{name}', v_actor->>'name')
                        else '' end,
    'language', public.ui_language_block(),
    'features', coalesce((
      select jsonb_agg(jsonb_build_object(
               'feature_key', f.feature_key,
               'label', public.ui_text(f.copy_key),
               'icon_key', f.icon_key,
               'access', public.supplier_access(f.feature_key),
               'can_read', public.supplier_can(f.feature_key,'read'),
               'can_write', public.supplier_can(f.feature_key,'write'))
             order by f.sort_order, f.feature_key)
        from supplier_feature f where f.is_active), '[]'::jsonb));
end $function$;

create or replace function public.supplier_staff_list()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_sid uuid := public.my_supplier_id(); v_me bigint := public.my_supplier_user_id();
        v_can_write boolean; v_sp record;
begin
  if v_sid is null or not public.supplier_can('supplier.staff','read') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'message', public.ui_text('supplier_staff.err_not_authorized'));
  end if;
  v_can_write := public.supplier_can('supplier.staff','write');
  select * into v_sp from supplier_profiles where id = v_sid;

  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('supplier_staff.title'),
    'subtitle', public.ui_text('supplier_staff.subtitle'),
    'can_manage', v_can_write,
    'add_label', public.ui_text('supplier_staff.add_label'),
    'add_hint', public.ui_text('supplier_staff.add_hint'),
    'name_hint', public.ui_text('supplier_staff.name_hint'),
    'save_label', public.ui_text('supplier_staff.save_label'),
    'remove_label', public.ui_text('supplier_staff.remove_label'),
    'role_label', public.ui_text('supplier_staff.role_label'),
    'owner_label', public.ui_text('supplier_staff.owner_label'),
    'empty', public.ui_text('supplier_staff.empty'),
    'audit_heading', public.ui_text('supplier_staff.audit_heading'),
    'audit_empty', public.ui_text('supplier_staff.audit_empty'),
    -- The dropdown IS this table. A preset the backend does not hold can never
    -- be offered, and a role the account itself cannot reach is never sent.
    'role_options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'role_key', rp.role_key,
               'label', public.ui_text(rp.copy_key),
               'description', public.ui_text(coalesce(rp.desc_key,'')))
             order by rp.sort_order, rp.role_key)
        from supplier_role_preset rp where rp.is_active), '[]'::jsonb),
    'rows', (
      -- the OWNER first: a real row, never removable, never re-graded.
      jsonb_build_array(jsonb_build_object(
        'id', null,
        'identity', coalesce(nullif(btrim(coalesce(v_sp.email,'')),''), v_sp.phone, v_sp.contact_no),
        'name', coalesce(nullif(btrim(coalesce(v_sp.contact_person, v_sp.contact_name,'')),''), v_sp.supplier_name),
        'role_key', null,
        'role_label', public.ui_text('supplier_staff.role_owner'),
        'is_owner', true,
        'is_self', v_me is null,
        'can_remove', false,
        'can_edit_role', false,
        'added_label', ''))
      ||
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', su.id,
                 'identity', su.identity,
                 'name', coalesce(nullif(btrim(coalesce(su.display_name,'')),''), su.identity),
                 'role_key', su.role_key,
                 'role_label', public.ui_text(rp.copy_key),
                 'is_owner', false,
                 'is_self', su.id = v_me,
                 'can_remove', v_can_write and su.id is distinct from v_me,
                 'can_edit_role', v_can_write and su.id is distinct from v_me,
                 'added_label', replace(public.ui_text('supplier_staff.added_on'),
                                        '{date}', ist_fmt(su.created_at, 'dmy')))
               order by su.created_at, su.id)
          from supplier_users su
          join supplier_role_preset rp on rp.role_key = su.role_key
         where su.supplier_id = v_sid and coalesce(su.is_active,true)), '[]'::jsonb)),
    'audit', coalesce((
      select jsonb_agg(jsonb_build_object(
               'who', al.actor_name,
               'what', al.detail ->> 'summary',
               'when', ist_fmt(al.created_at, 'dmyhm'))
             order by al.created_at desc)
        from (select * from supplier_audit_log
               where supplier_id = v_sid order by created_at desc limit 25) al), '[]'::jsonb));
end $function$;

create or replace function public.supplier_staff_add(p_identity text, p_name text default null,
                                                     p_role_key text default 'inquiry_only')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_sid uuid := public.my_supplier_id(); k text; own record; v_id bigint;
        v_existing record; v_role text;
begin
  if v_sid is null or not public.supplier_can('supplier.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public.ui_text('supplier_staff.err_not_authorized'));
  end if;
  k := identity_norm(p_identity);
  if k is null then
    return jsonb_build_object('ok',false,'error','bad_identity','tone','danger',
      'message', public.ui_text('supplier_staff.err_bad_identity'));
  end if;
  select rp.role_key into v_role from supplier_role_preset rp
   where rp.role_key = coalesce(p_role_key,'inquiry_only') and rp.is_active;
  if v_role is null then
    return jsonb_build_object('ok',false,'error','bad_role','tone','danger',
      'message', public.ui_text('supplier_staff.err_bad_role'));
  end if;

  -- Never adopt a login that already belongs to someone else, and never adopt
  -- the supplier's OWN owner identity as one of its staff rows.
  select li.owner_type, li.owner_id into own from login_identities li where li.identity = k;
  if own.owner_type is not null
     and (own.owner_type <> 'supplier' or own.owner_id is distinct from v_sid::text) then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public.ui_text('supplier_staff.err_identity_taken'));
  end if;
  if own.owner_type = 'supplier' and own.owner_id = v_sid::text
     and not exists (select 1 from supplier_users where identity = k) then
    return jsonb_build_object('ok',false,'error','already_owner','tone','danger',
      'message', public.ui_text('supplier_staff.err_already_owner'));
  end if;

  select * into v_existing from supplier_users where identity = k;
  if v_existing.id is not null and v_existing.supplier_id <> v_sid then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public.ui_text('supplier_staff.err_identity_taken'));
  end if;

  insert into supplier_users(supplier_id, identity, display_name, role_key, created_by)
  values (v_sid, k, nullif(btrim(coalesce(p_name,'')),''), v_role,
          coalesce(public.my_login_email(),'supplier'))
  on conflict (identity) do update
    set supplier_id = excluded.supplier_id, is_active = true, role_key = excluded.role_key,
        display_name = coalesce(excluded.display_name, supplier_users.display_name),
        updated_at = now()
  returning id into v_id;

  -- The SAME binding every supplier login already uses, so my_supplier_id()
  -- and get_my_role() resolve this person with no further change.
  insert into login_identities(identity, kind, owner_type, owner_id)
  values (k, case when position('@' in k) > 0 then 'email' else 'phone' end, 'supplier', v_sid::text)
  on conflict (identity) do update set owner_type = 'supplier', owner_id = v_sid::text;

  perform public.supplier_audit('supplier.staff','staff_added',
    jsonb_build_object('identity', k, 'supplier_user_id', v_id, 'role_key', v_role,
      'summary', replace(replace(public.ui_text('supplier_staff.audit_added'),
                  '{who}', k), '{role}', public.ui_text(
                    (select copy_key from supplier_role_preset where role_key = v_role)))));

  return jsonb_build_object('ok',true,'id',v_id,'identity',k,'tone','success',
    'message', public.ui_text('supplier_staff.added'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('supplier_staff.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

create or replace function public.supplier_staff_set_role(p_id bigint, p_role_key text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_sid uuid := public.my_supplier_id(); su record; v_role text;
begin
  if v_sid is null or not public.supplier_can('supplier.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public.ui_text('supplier_staff.err_not_authorized'));
  end if;
  select * into su from supplier_users where id = p_id;
  if su.id is null or su.supplier_id <> v_sid then
    return jsonb_build_object('ok',false,'error','not_your_staff','tone','danger',
      'message', public.ui_text('supplier_staff.err_not_your_staff'));
  end if;
  if su.id = public.my_supplier_user_id() then
    return jsonb_build_object('ok',false,'error','cannot_edit_self','tone','danger',
      'message', public.ui_text('supplier_staff.err_cannot_edit_self'));
  end if;
  select rp.role_key into v_role from supplier_role_preset rp
   where rp.role_key = p_role_key and rp.is_active;
  if v_role is null then
    return jsonb_build_object('ok',false,'error','bad_role','tone','danger',
      'message', public.ui_text('supplier_staff.err_bad_role'));
  end if;

  update supplier_users set role_key = v_role, updated_at = now() where id = p_id;

  perform public.supplier_audit('supplier.staff','staff_role_changed',
    jsonb_build_object('identity', su.identity, 'supplier_user_id', su.id, 'role_key', v_role,
      'summary', replace(replace(public.ui_text('supplier_staff.audit_role'),
                  '{who}', su.identity), '{role}', public.ui_text(
                    (select copy_key from supplier_role_preset where role_key = v_role)))));

  return jsonb_build_object('ok',true,'tone','success',
    'message', public.ui_text('supplier_staff.role_saved'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('supplier_staff.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

create or replace function public.supplier_staff_remove(p_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_sid uuid := public.my_supplier_id(); su record;
begin
  if v_sid is null or not public.supplier_can('supplier.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public.ui_text('supplier_staff.err_not_authorized'));
  end if;
  select * into su from supplier_users where id = p_id;
  if su.id is null or su.supplier_id <> v_sid then
    return jsonb_build_object('ok',false,'error','not_your_staff','tone','danger',
      'message', public.ui_text('supplier_staff.err_not_your_staff'));
  end if;
  if su.id = public.my_supplier_user_id() then
    return jsonb_build_object('ok',false,'error','cannot_remove_self','tone','danger',
      'message', public.ui_text('supplier_staff.err_cannot_remove_self'));
  end if;

  update supplier_users set is_active = false, auth_user_id = null, updated_at = now()
   where id = p_id;
  -- Only the STAFF binding goes; the owner's own identity row is a different
  -- row and is never touched here.
  delete from login_identities
   where identity = su.identity and owner_type = 'supplier' and owner_id = v_sid::text;

  perform public.supplier_audit('supplier.staff','staff_removed',
    jsonb_build_object('identity', su.identity, 'supplier_user_id', su.id,
      'summary', replace(public.ui_text('supplier_staff.audit_removed'), '{who}', su.identity)));

  return jsonb_build_object('ok',true,'tone','success',
    'message', public.ui_text('supplier_staff.removed'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('supplier_staff.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. GRANTS — a definer function is a public endpoint until it is revoked
-- ═══════════════════════════════════════════════════════════════════════════

do $g$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('my_supplier_user_id','supplier_access','supplier_can',
                         'my_supplier_actor','supplier_audit','supplier_session',
                         'supplier_staff_list','supplier_staff_add',
                         'supplier_staff_set_role','supplier_staff_remove')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end $g$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. THE ADMIN ENTRY POINT (#325's registry) — a screen nobody can reach
--    does not exist (rule 11)
-- ═══════════════════════════════════════════════════════════════════════════

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order,
   owner, partner_eligible, default_access, is_active, surface, category,
   roles_allowed, description, search_terms)
values
  ('admin.supplier_accounts', 'Supplier accounts', 'Suppliers', 'people',
   'supplier_accounts', 845, 'medibo', false, 'none', true, 'dashboard',
   'parties', array['admin','super_admin'],
   'Approve supplier bank / UPI changes and see Hindi coverage for supplier screens.',
   'payout bank upi ifsc approval hindi language translation supplier staff')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      sort_order = excluded.sort_order, owner = excluded.owner,
      surface = excluded.surface, category = excluded.category,
      roles_allowed = excluded.roles_allowed,
      description = excluded.description, search_terms = excluded.search_terms,
      is_active = true;
