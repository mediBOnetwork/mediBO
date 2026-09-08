-- CHANGE #399 — Partner self-service.
--
-- Three gaps in the partner interface, all zone-scoped, permission-gated and
-- audit-stamped:
--   1. the partner manages its OWN staff logins, and each staff member's
--      permissions are a SUBSET of what the partner itself was granted;
--   2. the partner records supplier payments through the SAME writer the admin
--      path uses, so one statement is fed by both;
--   3. the partner files an expense against an order in its zone, with a
--      receipt, straight into #323's order_costs and therefore into that day's
--      settlement.
--
-- Every statement here is idempotent: a resumed worker re-applies it silently.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. ACCESS ALGEBRA — a staff grant can only ever REDUCE the partner's grant
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public._partner_access_rank(p_access text)
returns int language sql immutable as $$
  select case coalesce(p_access,'none')
           when 'write' then 2 when 'read' then 1 else 0 end
$$;

create or replace function public._partner_access_name(p_rank int)
returns text language sql immutable as $$
  select case coalesce(p_rank,0)
           when 2 then 'write' when 1 then 'read' else 'none' end
$$;

-- The intersect. A NULL staff grant means "this login carries no per-user row",
-- which INHERITS the partner's access — that is what every partner login did
-- before this change, so nobody loses access the moment this ships.
create or replace function public._partner_access_min(p_partner_access text, p_staff_access text)
returns text language sql immutable as $$
  select case
    when p_staff_access is null then coalesce(p_partner_access,'none')
    else public._partner_access_name(
           least(public._partner_access_rank(p_partner_access),
                 public._partner_access_rank(p_staff_access)))
  end
$$;

create table if not exists public.partner_user_permissions (
  partner_user_id bigint not null references public.partner_users(id) on delete cascade,
  feature_key     text   not null,
  access          text   not null check (access in ('none','read','write')),
  updated_at      timestamptz not null default now(),
  updated_by      text,
  primary key (partner_user_id, feature_key)
);

create index if not exists partner_user_permissions_user_idx
  on public.partner_user_permissions (partner_user_id);

alter table public.partner_user_permissions enable row level security;

-- No partner-facing policy on purpose: every read and write goes through the
-- SECURITY DEFINER RPCs below, which clamp by partner and by the caller's own
-- effective access. Admin keeps a direct read for support.
drop policy if exists partner_user_permissions_admin on public.partner_user_permissions;
create policy partner_user_permissions_admin on public.partner_user_permissions
  for all using (public.role_for_medibo_only() in ('admin','super_admin'))
  with check (public.role_for_medibo_only() in ('admin','super_admin'));

-- The one behavioural change to an existing function: partner_access now
-- intersects the partner's grant with the CALLER's per-user grant. Admin
-- answering for some other partner (p_partner passed by an admin screen) is
-- never clamped — that path has no partner_user at all.
create or replace function public.partner_access(p_feature text, p_partner bigint default null)
returns text
language sql stable security definer set search_path to 'public'
as $function$
  select public._partner_access_min(
    coalesce(
      (select pp.access
         from partner_permissions pp
         join feature_registry fr on fr.feature_key = pp.feature_key
        where pp.partner_id = case
                when p_partner is null then public.my_partner_id()
                when public.role_for_medibo_only() in ('admin','super_admin') then p_partner
                else public.my_partner_id()
              end
          and pp.feature_key = p_feature
          and fr.is_active and fr.partner_eligible and fr.owner = 'partner'),
      'none'),
    (select pup.access
       from partner_user_permissions pup
      where pup.partner_user_id = public.my_partner_user_id()
        and pup.feature_key = p_feature
        and (p_partner is null or p_partner = public.my_partner_id()))
  )
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. THE TWO NEW FEATURES + their copy
-- ═══════════════════════════════════════════════════════════════════════════

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order,
   owner, partner_eligible, default_access, is_active)
values
  ('partner.staff',    'My staff', 'Partner', 'people', 'partner_staff',    100, 'partner', true, 'none', true),
  ('partner.expenses', 'Expenses', 'Money',   'receipt','partner_expenses',  95, 'partner', true, 'none', true)
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      sort_order = excluded.sort_order, owner = excluded.owner,
      partner_eligible = excluded.partner_eligible, is_active = true;

insert into public.app_settings(key, value)
values ('partner_selfservice_copy', $c399copy${
  "staff_title": "My staff",
  "staff_subtitle": "Logins that work inside your zone. Each one sees only what you allow.",
  "staff_add_label": "Add staff login",
  "staff_add_hint": "Email or 10-digit mobile",
  "staff_name_hint": "Name (optional)",
  "staff_save_label": "Add",
  "staff_remove_label": "Remove",
  "staff_empty": "No staff logins yet. Add one and they sign in with the same OTP or Google login you use.",
  "staff_added": "Staff login added",
  "staff_removed": "Staff login removed",
  "staff_perm_title": "What this login can do",
  "staff_perm_note": "You can only give a staff member access you hold yourself.",
  "staff_perm_saved": "Access updated",
  "staff_status_linked": "Signed in",
  "staff_status_wait": "Waiting for first login",
  "staff_self_label": "This is you",
  "err_not_authorized": "You do not have permission to manage staff",
  "err_bad_identity": "Enter a valid email or 10-digit mobile number",
  "err_identity_taken": "That login already belongs to another account",
  "err_not_your_staff": "That login is not part of your team",
  "err_cannot_remove_self": "You cannot remove your own login",
  "err_above_your_access": "You cannot give access you do not hold yourself",
  "err_feature_unknown": "That is not a partner feature",
  "err_failed": "Could not save: {detail}",
  "pay_title": "Supplier payment",
  "pay_subtitle": "Record what you paid a supplier. It lands on the same supplier statement the office sees.",
  "pay_order_label": "Supplier order",
  "pay_amount_label": "Amount paid",
  "pay_kind_label": "Payment type",
  "pay_mode_label": "Method",
  "pay_ref_label": "UTR / reference",
  "pay_note_label": "Note",
  "pay_proof_label": "Payment proof photo",
  "pay_pick_label": "Choose photo",
  "pay_save_label": "Record payment",
  "pay_saved": "Payment recorded",
  "pay_empty": "No supplier orders in your zone yet.",
  "pay_readonly": "You can view supplier payments but not record them. Ask the office for full access.",
  "pay_paid_label": "Paid",
  "pay_due_label": "Due",
  "err_bad_amount": "Enter an amount greater than zero",
  "err_order_not_found": "That supplier order no longer exists",
  "err_out_of_zone": "That supplier order is not in your zone",
  "err_duplicate_utr": "That UTR has already been recorded",
  "err_duplicate_txn": "That transaction id has already been recorded",
  "exp_title": "Expenses",
  "exp_subtitle": "Costs you paid on an order. These join that day's settlement automatically.",
  "exp_order_label": "Order",
  "exp_type_label": "Cost type",
  "exp_amount_label": "Amount",
  "exp_note_label": "Note",
  "exp_receipt_label": "Receipt photo",
  "exp_pick_label": "Choose photo",
  "exp_save_label": "Save expense",
  "exp_saved": "Expense saved",
  "exp_empty": "No orders in your zone yet.",
  "exp_readonly": "You can view expenses but not add them. Ask the office for full access.",
  "exp_frozen": "That order's settlement is already closed",
  "exp_existing_label": "On this order",
  "err_no_cost_type": "Pick a cost type",
  "err_upload_failed": "Could not attach that photo. The expense was not saved.",
  "cancel_label": "Cancel",
  "generic_error": "Something went wrong. Please try again."
}$c399copy$::jsonb)
on conflict (key) do update set value = excluded.value;

create or replace function public._pss_c(p_key text)
returns text language sql stable set search_path to 'public' as $$
  select coalesce(
    (select value ->> p_key from app_settings where key = 'partner_selfservice_copy'),
    '')
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. RECEIPTS / PROOF BUCKET — private, partner-writable, admin-readable
-- ═══════════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public)
values ('partner-receipts','partner-receipts', false)
on conflict (id) do nothing;

drop policy if exists partner_receipts_select on storage.objects;
create policy partner_receipts_select on storage.objects for select
  using (bucket_id = 'partner-receipts'
         and (public.role_for_medibo_only() in ('admin','super_admin')
              or (public.my_partner_id() is not null
                  and (storage.foldername(name))[1] = 'p' || public.my_partner_id()::text)));

drop policy if exists partner_receipts_insert on storage.objects;
create policy partner_receipts_insert on storage.objects for insert
  with check (bucket_id = 'partner-receipts'
              and (public.role_for_medibo_only() in ('admin','super_admin')
                   or (public.my_partner_id() is not null
                       and (storage.foldername(name))[1] = 'p' || public.my_partner_id()::text)));

alter table public.order_costs add column if not exists receipt_path   text;
alter table public.order_costs add column if not exists receipt_bucket text;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. THE PARTNER MANAGES ITS OWN STAFF
-- ═══════════════════════════════════════════════════════════════════════════

-- The grantable set: every partner feature the CALLER actually holds. This is
-- the ceiling for every grant below, which is why a staff member can never be
-- handed something the person handing it out does not have.
create or replace function public._pss_grantable()
returns table (feature_key text, label text, group_label text, sort_order int, my_access text)
language sql stable security definer set search_path to 'public'
as $$
  select fr.feature_key, fr.label, fr.group_label, fr.sort_order,
         public.partner_access(fr.feature_key)
    from feature_registry fr
   where fr.is_active and fr.owner = 'partner' and fr.partner_eligible
     and public.partner_access(fr.feature_key) <> 'none'
   order by fr.sort_order
$$;

create or replace function public.partner_staff_console()
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  v_pid  bigint := public.my_partner_id();
  v_me   bigint := public.my_partner_user_id();
  v_acc  text;
  v_users jsonb; v_feats jsonb; v_audit jsonb;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error', 'not_partner',
      'message', public._pss_c('err_not_authorized'));
  end if;
  v_acc := public.partner_access('partner.staff');
  if v_acc = 'none' then
    return jsonb_build_object('ok', false, 'error', 'no_access', 'access', 'none',
      'message', public._pss_c('err_not_authorized'));
  end if;

  select jsonb_agg(jsonb_build_object(
           'feature_key', g.feature_key, 'label', g.label,
           'group_label', g.group_label, 'my_access', g.my_access)
         order by g.sort_order)
    into v_feats
  from public._pss_grantable() g;

  select jsonb_agg(u order by (u->>'id')::bigint) into v_users from (
    select jsonb_build_object(
      'id', pu.id,
      'identity', pu.identity,
      'display_name', coalesce(nullif(btrim(pu.display_name),''), pu.identity),
      'is_self', (pu.id = v_me),
      'self_label', case when pu.id = v_me then public._pss_c('staff_self_label') else '' end,
      'linked', (pu.auth_user_id is not null),
      'status_label', case when pu.auth_user_id is not null
                           then public._pss_c('staff_status_linked')
                           else public._pss_c('staff_status_wait') end,
      'status_tone', case when pu.auth_user_id is not null then 'success' else 'warning' end,
      'added_label', to_char(pu.created_at at time zone 'Asia/Kolkata','dd Mon yyyy'),
      'can_remove', (v_acc = 'write' and pu.id <> v_me),
      'can_edit',   (v_acc = 'write' and pu.id <> v_me),
      'permissions', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'feature_key', g.feature_key,
                 'label', g.label,
                 -- what this login ACTUALLY has: the partner's grant clamped by
                 -- its own row (absent row = inherits the partner's grant).
                 'access', public._partner_access_min(g.my_access, pup.access),
                 'inherited', (pup.access is null),
                 'options', (
                   select jsonb_agg(jsonb_build_object(
                            'value', o.v,
                            'label', case o.v when 'none' then 'No access'
                                              when 'read' then 'View only'
                                              else 'Full access' end,
                            'selected', o.v = public._partner_access_min(g.my_access, pup.access))
                          order by o.r)
                     from (values ('none',0),('read',1),('write',2)) o(v,r)
                    where o.r <= public._partner_access_rank(g.my_access)))
               order by g.sort_order)
          from public._pss_grantable() g
          left join partner_user_permissions pup
                 on pup.partner_user_id = pu.id and pup.feature_key = g.feature_key
      ), '[]'::jsonb)) as u
    from partner_users pu
   where pu.partner_id = v_pid and coalesce(pu.is_active,true)
  ) s;

  select jsonb_agg(jsonb_build_object(
           'id', al.id,
           'action', al.action,
           'feature_key', coalesce(al.feature_key,''),
           'detail_label', coalesce(al.detail->>'summary',''),
           'at_label', to_char(al.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'))
         order by al.id desc)
    into v_audit
  from (select * from partner_audit_log
         where partner_id = v_pid and feature_key = 'partner.staff'
         order by created_at desc limit 20) al;

  return jsonb_build_object(
    'ok', true,
    'access', v_acc,
    'can_write', (v_acc = 'write'),
    'partner_id', v_pid,
    'zone_id', public.partner_zone_id(),
    'title',       public._pss_c('staff_title'),
    'subtitle',    public._pss_c('staff_subtitle'),
    'add_label',   public._pss_c('staff_add_label'),
    'add_hint',    public._pss_c('staff_add_hint'),
    'name_hint',   public._pss_c('staff_name_hint'),
    'save_label',  public._pss_c('staff_save_label'),
    'cancel_label',public._pss_c('cancel_label'),
    'remove_label',public._pss_c('staff_remove_label'),
    'empty_text',  public._pss_c('staff_empty'),
    'perm_title',  public._pss_c('staff_perm_title'),
    'perm_note',   public._pss_c('staff_perm_note'),
    'readonly_text', case when v_acc = 'write' then '' else public._pss_c('err_not_authorized') end,
    'features', coalesce(v_feats,'[]'::jsonb),
    'users',    coalesce(v_users,'[]'::jsonb),
    'audit',    coalesce(v_audit,'[]'::jsonb));
end $function$;

create or replace function public.partner_staff_add(p_identity text, p_name text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_pid bigint := public.my_partner_id(); k text; own record; v_id bigint; v_existing record;
begin
  if v_pid is null or not public.partner_can('partner.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pss_c('err_not_authorized'));
  end if;
  k := identity_norm(p_identity);
  if k is null then
    return jsonb_build_object('ok',false,'error','bad_identity','tone','danger',
      'message', public._pss_c('err_bad_identity'));
  end if;

  select li.owner_type, li.owner_id into own from login_identities li where li.identity = k;
  if own.owner_type is not null and own.owner_type <> 'partner' then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public._pss_c('err_identity_taken'));
  end if;

  -- Never adopt a login that belongs to a DIFFERENT partner.
  select * into v_existing from partner_users where identity = k;
  if v_existing.id is not null and v_existing.partner_id <> v_pid then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public._pss_c('err_identity_taken'));
  end if;

  insert into partner_users(partner_id, identity, display_name, created_by)
  values (v_pid, k, nullif(btrim(coalesce(p_name,'')),''), coalesce(public.my_login_email(),'partner'))
  on conflict (identity) do update
    set partner_id = excluded.partner_id, is_active = true,
        display_name = coalesce(excluded.display_name, partner_users.display_name),
        updated_at = now()
  returning id into v_id;

  insert into login_identities(identity, kind, owner_type, owner_id)
  values (k, case when position('@' in k) > 0 then 'email' else 'phone' end, 'partner', v_id::text)
  on conflict (identity) do update set owner_type = 'partner', owner_id = v_id::text;

  -- A NEW staff login starts with nothing. (A login that pre-dates this change
  -- has no rows at all and keeps inheriting the partner's grant — that is the
  -- difference between "not configured yet" and "configured to none".)
  insert into partner_user_permissions(partner_user_id, feature_key, access, updated_by)
  select v_id, fr.feature_key, 'none', coalesce(public.my_login_email(),'partner')
    from feature_registry fr
   where fr.is_active and fr.owner = 'partner' and fr.partner_eligible
  on conflict (partner_user_id, feature_key) do nothing;

  perform public.partner_audit('partner.staff','staff_added',
    jsonb_build_object('identity', k, 'partner_user_id', v_id,
                       'summary', 'Added ' || k));

  return jsonb_build_object('ok',true,'id',v_id,'identity',k,'tone','success',
    'message', public._pss_c('staff_added'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public._pss_c('err_failed'), '{detail}', SQLERRM), 'sqlstate', SQLSTATE);
end $function$;

create or replace function public.partner_staff_remove(p_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_pid bigint := public.my_partner_id(); pu record;
begin
  if v_pid is null or not public.partner_can('partner.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pss_c('err_not_authorized'));
  end if;
  select * into pu from partner_users where id = p_id;
  if pu.id is null or pu.partner_id <> v_pid then
    return jsonb_build_object('ok',false,'error','not_your_staff','tone','danger',
      'message', public._pss_c('err_not_your_staff'));
  end if;
  if pu.id = public.my_partner_user_id() then
    return jsonb_build_object('ok',false,'error','cannot_remove_self','tone','danger',
      'message', public._pss_c('err_cannot_remove_self'));
  end if;

  update partner_users set is_active = false, auth_user_id = null, updated_at = now()
   where id = p_id;
  delete from login_identities where owner_type = 'partner' and owner_id = p_id::text;

  perform public.partner_audit('partner.staff','staff_removed',
    jsonb_build_object('identity', pu.identity, 'partner_user_id', pu.id,
                       'summary', 'Removed ' || pu.identity));

  return jsonb_build_object('ok',true,'tone','success',
    'message', public._pss_c('staff_removed'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public._pss_c('err_failed'), '{detail}', SQLERRM), 'sqlstate', SQLSTATE);
end $function$;

create or replace function public.partner_staff_access_set(
  p_user_id bigint, p_feature_key text, p_access text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_pid bigint := public.my_partner_id(); pu record; v_ceiling text;
begin
  if v_pid is null or not public.partner_can('partner.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pss_c('err_not_authorized'));
  end if;
  if coalesce(p_access,'') not in ('none','read','write') then
    return jsonb_build_object('ok',false,'error','bad_access','tone','danger',
      'message', public._pss_c('err_above_your_access'));
  end if;
  select * into pu from partner_users where id = p_user_id;
  if pu.id is null or pu.partner_id <> v_pid or not coalesce(pu.is_active,true) then
    return jsonb_build_object('ok',false,'error','not_your_staff','tone','danger',
      'message', public._pss_c('err_not_your_staff'));
  end if;
  -- Editing your own row would be self-escalation: a staff member holding
  -- partner.staff write could lift itself to the partner's ceiling.
  if pu.id = public.my_partner_user_id() then
    return jsonb_build_object('ok',false,'error','cannot_edit_self','tone','danger',
      'message', public._pss_c('err_cannot_remove_self'));
  end if;
  if not exists (select 1 from feature_registry fr
                  where fr.feature_key = p_feature_key
                    and fr.is_active and fr.owner = 'partner' and fr.partner_eligible) then
    return jsonb_build_object('ok',false,'error','feature_unknown','tone','danger',
      'message', public._pss_c('err_feature_unknown'));
  end if;

  -- THE SUBSET RULE. The ceiling is the CALLER's own effective access, which is
  -- itself already clamped — so a restricted staff member cannot hand out more
  -- than it holds either.
  v_ceiling := public.partner_access(p_feature_key);
  if public._partner_access_rank(p_access) > public._partner_access_rank(v_ceiling) then
    perform public.partner_audit('partner.staff','staff_access_denied',
      jsonb_build_object('partner_user_id', p_user_id, 'feature', p_feature_key,
                         'wanted', p_access, 'ceiling', v_ceiling,
                         'summary', 'Refused ' || p_access || ' on ' || p_feature_key));
    return jsonb_build_object('ok',false,'error','above_your_access','tone','danger',
      'ceiling', v_ceiling, 'message', public._pss_c('err_above_your_access'));
  end if;

  insert into partner_user_permissions(partner_user_id, feature_key, access, updated_at, updated_by)
  values (p_user_id, p_feature_key, p_access, now(), coalesce(public.my_login_email(),'partner'))
  on conflict (partner_user_id, feature_key) do update
    set access = excluded.access, updated_at = now(), updated_by = excluded.updated_by;

  perform public.partner_audit('partner.staff','staff_access_set',
    jsonb_build_object('partner_user_id', p_user_id, 'feature', p_feature_key,
                       'access', p_access,
                       'summary', pu.identity || ' → ' || p_feature_key || ' = ' || p_access));

  return jsonb_build_object('ok',true,'tone','success','access',p_access,
    'message', public._pss_c('staff_perm_saved'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public._pss_c('err_failed'), '{detail}', SQLERRM), 'sqlstate', SQLSTATE);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. SUPPLIER PAYMENT — ONE WRITER, TWO DOORS
-- ═══════════════════════════════════════════════════════════════════════════
-- The admin path and the partner path must not drift, so the insert lives in
-- exactly one place. sup_record_payment keeps its signature and its
-- super_admin gate; it now delegates the write. partner_sup_record_payment
-- applies the partner gates and delegates to the SAME writer, so both doors
-- produce identical supplier_payments rows and one supplier statement.

create or replace function public._sup_record_payment_write(
  p_supplier_order_id uuid, p_kind text, p_amount numeric, p_mode text,
  p_note text, p_screenshot_path text, p_screenshot_bucket text,
  p_ocr jsonb, p_created_by text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_id uuid; v_name text; v_utr text; v_txn text;
begin
  select supplier_name into v_name from supplier_orders where id = p_supplier_order_id;
  if v_name is null then return jsonb_build_object('ok',false,'error','order_not_found'); end if;
  if coalesce(p_amount,0) <= 0 then return jsonb_build_object('ok',false,'error','bad_amount'); end if;
  v_utr := nullif(upper(regexp_replace(coalesce(p_ocr->>'utr',''),'\s','','g')),'');
  v_txn := nullif(upper(regexp_replace(coalesce(p_ocr->>'txn_id',''),'\s','','g')),'');
  if v_utr is not null and exists (select 1 from supplier_payments where utr=v_utr) then
    return jsonb_build_object('ok',false,'error','duplicate_utr','utr',v_utr);
  end if;
  if v_txn is not null and exists (select 1 from supplier_payments where txn_id=v_txn) then
    return jsonb_build_object('ok',false,'error','duplicate_txn','txn_id',v_txn);
  end if;
  insert into supplier_payments(supplier_order_id, supplier_name, amount, mode, note, created_by,
    kind, payee_name, payee_vpa, utr, txn_id, app, paid_at, screenshot_path, screenshot_bucket, raw_ocr)
  values (p_supplier_order_id, v_name, p_amount, coalesce(nullif(p_mode,''),'online'), p_note,
    coalesce(nullif(p_created_by,''),'admin'),
    coalesce(nullif(p_kind,''),'advance'), p_ocr->>'payee_name', p_ocr->>'payee_vpa', v_utr, v_txn,
    p_ocr->>'app', p_ocr->>'paid_at', p_screenshot_path, p_screenshot_bucket, p_ocr)
  returning id into v_id;
  return jsonb_build_object('ok',true,'id',v_id);
end $function$;

create or replace function public.sup_record_payment(
  p_supplier_order_id uuid, p_kind text, p_amount numeric,
  p_mode text default 'online', p_note text default null,
  p_screenshot_path text default null, p_screenshot_bucket text default null,
  p_ocr jsonb default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
begin
  if get_my_role() <> 'super_admin' then raise exception 'forbidden: super_admin required'; end if;
  return public._sup_record_payment_write(p_supplier_order_id, p_kind, p_amount, p_mode,
           p_note, p_screenshot_path, p_screenshot_bucket, p_ocr, 'admin');
end $function$;

-- The partner door. Same writer, three extra gates: the feature grant (already
-- clamped to the staff subset), the ORDER's zone, and the supplier's zone.
create or replace function public.partner_sup_record_payment(
  p_supplier_order_id uuid, p_kind text, p_amount numeric,
  p_mode text default 'online', p_note text default null,
  p_screenshot_path text default null, p_screenshot_bucket text default null,
  p_ocr jsonb default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_zone smallint := public.partner_zone_id(); so record; v_res jsonb;
begin
  if public.my_partner_id() is null or not public.partner_can('partner.supplier_payment','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pss_c('err_not_authorized'));
  end if;
  select * into so from supplier_orders where id = p_supplier_order_id;
  if so.id is null then
    return jsonb_build_object('ok',false,'error','order_not_found','tone','danger',
      'message', public._pss_c('err_order_not_found'));
  end if;
  if v_zone is null or so.zone_id is null or so.zone_id::smallint <> v_zone
     or coalesce(public.partner_supplier_zone(so.supplier_name), -1) <> v_zone then
    perform public.partner_audit('partner.supplier_payment','payment_denied_zone',
      jsonb_build_object('supplier_order_id', p_supplier_order_id,
                         'order_zone', so.zone_id, 'my_zone', v_zone,
                         'summary', 'Refused: out of zone'));
    return jsonb_build_object('ok',false,'error','out_of_zone','tone','danger',
      'message', public._pss_c('err_out_of_zone'));
  end if;
  if coalesce(p_amount,0) <= 0 then
    return jsonb_build_object('ok',false,'error','bad_amount','tone','danger',
      'message', public._pss_c('err_bad_amount'));
  end if;

  v_res := public._sup_record_payment_write(p_supplier_order_id, p_kind, p_amount, p_mode,
             p_note, p_screenshot_path, p_screenshot_bucket, p_ocr,
             'partner:' || coalesce(public.my_login_email(), public.my_partner_user_id()::text));

  if coalesce((v_res->>'ok')::boolean, false) then
    perform public.partner_audit('partner.supplier_payment','payment_recorded',
      jsonb_build_object('supplier_order_id', p_supplier_order_id,
                         'payment_id', v_res->>'id', 'amount', p_amount, 'kind', p_kind,
                         'summary', public.inr_money(p_amount) || ' → ' || coalesce(so.supplier_name,'')));
    return v_res || jsonb_build_object('tone','success','message', public._pss_c('pay_saved'));
  end if;

  return v_res || jsonb_build_object('tone','danger','message',
    case v_res->>'error'
      when 'duplicate_utr' then public._pss_c('err_duplicate_utr')
      when 'duplicate_txn' then public._pss_c('err_duplicate_txn')
      when 'bad_amount'    then public._pss_c('err_bad_amount')
      when 'order_not_found' then public._pss_c('err_order_not_found')
      else public._pss_c('generic_error') end);
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public._pss_c('err_failed'), '{detail}', SQLERRM), 'sqlstate', SQLSTATE);
end $function$;

create or replace function public.partner_supplier_payment_console(p_limit int default 40)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_zone smallint := public.partner_zone_id(); v_acc text; v_rows jsonb;
begin
  if public.my_partner_id() is null then
    return jsonb_build_object('ok',false,'error','not_partner',
      'message', public._pss_c('err_not_authorized'));
  end if;
  v_acc := public.partner_access('partner.supplier_payment');
  if v_acc = 'none' then
    perform public.partner_audit('partner.supplier_payment','open_denied','{}'::jsonb);
    return jsonb_build_object('ok',false,'error','no_access','access','none',
      'message', public._pss_c('err_not_authorized'));
  end if;

  select jsonb_agg(r order by (r->>'sort') desc) into v_rows from (
    select jsonb_build_object(
      'supplier_order_id', so.id,
      'sort', to_char(so.created_at,'YYYYMMDDHH24MISS'),
      'supplier_name', coalesce(so.supplier_name,''),
      'order_label', coalesce(nullif(so.order_code,''), nullif(so.order_no::text,''), ''),
      'date_label', to_char(so.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'),
      'total_text', public.inr_money(coalesce(so.trade_total, so.total_amount, 0)),
      'paid_label', public._pss_c('pay_paid_label'),
      'paid_text',  public.inr_money(coalesce(p.paid,0)),
      'due_label',  public._pss_c('pay_due_label'),
      'due_text',   public.inr_money(greatest(coalesce(so.trade_total, so.total_amount, 0) - coalesce(p.paid,0), 0)),
      'due_tone',   case when coalesce(so.trade_total, so.total_amount, 0) - coalesce(p.paid,0) > 0
                         then 'warning' else 'success' end,
      'can_record', (v_acc = 'write')) as r
      from supplier_orders so
      left join lateral (select sum(sp.amount) paid from supplier_payments sp
                          where sp.supplier_order_id = so.id) p on true
     where so.zone_id is not null and so.zone_id::smallint = v_zone
     order by so.created_at desc
     limit greatest(coalesce(p_limit,40), 1)
  ) s;

  perform public.partner_audit('partner.supplier_payment','open',
    jsonb_build_object('access', v_acc));

  return jsonb_build_object(
    'ok', true, 'access', v_acc, 'can_write', (v_acc='write'),
    'zone_id', v_zone,
    'title',        public._pss_c('pay_title'),
    'subtitle',     public._pss_c('pay_subtitle'),
    'order_label',  public._pss_c('pay_order_label'),
    'amount_label', public._pss_c('pay_amount_label'),
    'kind_label',   public._pss_c('pay_kind_label'),
    'mode_label',   public._pss_c('pay_mode_label'),
    'ref_label',    public._pss_c('pay_ref_label'),
    'note_label',   public._pss_c('pay_note_label'),
    'proof_label',  public._pss_c('pay_proof_label'),
    'pick_label',   public._pss_c('pay_pick_label'),
    'save_label',   public._pss_c('pay_save_label'),
    'cancel_label', public._pss_c('cancel_label'),
    'empty_text',   public._pss_c('pay_empty'),
    'readonly_text',case when v_acc='write' then '' else public._pss_c('pay_readonly') end,
    'proof_bucket', 'partner-receipts',
    'kind_options', jsonb_build_array(
      jsonb_build_object('value','advance','label','Advance','selected',true),
      jsonb_build_object('value','balance','label','Balance','selected',false)),
    'mode_options', jsonb_build_array(
      jsonb_build_object('value','online','label','Online / UPI','selected',true),
      jsonb_build_object('value','cash','label','Cash','selected',false)),
    'rows', coalesce(v_rows,'[]'::jsonb));
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. PARTNER EXPENSE ENTRY — straight into #323's order_costs
-- ═══════════════════════════════════════════════════════════════════════════

-- One upload path helper for both surfaces. The 'p<partner_id>/' prefix is the
-- same string the storage policy checks, so a partner physically cannot write
-- into another partner's folder.
create or replace function public.partner_upload_path(p_kind text, p_key text, p_ext text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_pid bigint := public.my_partner_id(); v_ext text;
begin
  if v_pid is null then
    return jsonb_build_object('ok',false,'error','not_partner',
      'message', public._pss_c('err_not_authorized'));
  end if;
  v_ext := lower(regexp_replace(coalesce(nullif(p_ext,''),'jpg'), '[^a-z0-9]', '', 'g'));
  if v_ext not in ('jpg','jpeg','png','webp','pdf') then v_ext := 'jpg'; end if;
  return jsonb_build_object(
    'ok', true,
    'bucket', 'partner-receipts',
    'path', 'p' || v_pid::text || '/' ||
            regexp_replace(coalesce(nullif(p_kind,''),'misc'), '[^a-zA-Z0-9_-]', '', 'g') || '/' ||
            regexp_replace(coalesce(nullif(p_key,''),'x'), '[^a-zA-Z0-9_-]', '', 'g') || '-' ||
            to_char(now() at time zone 'Asia/Kolkata','YYYYMMDDHH24MISS') || '-' ||
            substr(md5(random()::text), 1, 8) || '.' || v_ext);
end $function$;

create or replace function public.partner_expense_console(p_limit int default 40)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_zone smallint := public.partner_zone_id(); v_acc text; v_rows jsonb; v_types jsonb;
begin
  if public.my_partner_id() is null then
    return jsonb_build_object('ok',false,'error','not_partner',
      'message', public._pss_c('err_not_authorized'));
  end if;
  v_acc := public.partner_access('partner.expenses');
  if v_acc = 'none' then
    perform public.partner_audit('partner.expenses','open_denied','{}'::jsonb);
    return jsonb_build_object('ok',false,'error','no_access','access','none',
      'message', public._pss_c('err_not_authorized'));
  end if;

  select jsonb_agg(jsonb_build_object('value', ct.slug, 'label', ct.label)
         order by ct.sort_order, ct.slug)
    into v_types
  from cost_types ct where ct.active;

  select jsonb_agg(r order by (r->>'sort') desc) into v_rows from (
    select jsonb_build_object(
      'order_id', o.id,
      'sort', to_char(o.created_at,'YYYYMMDDHH24MISS'),
      'order_label', coalesce(nullif(o.order_code,''), left(o.id::text, 8)),
      'customer_label', coalesce(o.pharmacy_name,''),
      'date_label', to_char(o.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'),
      'total_text', public.inr_money(coalesce(o.total_amount,0)),
      'frozen', exists (select 1 from partner_settlements s
                          join partner_settlement_periods pp on pp.id = s.period_id
                         where s.order_id = o.id and pp.status <> 'open'),
      'can_add', (v_acc = 'write'),
      'existing_label', public._pss_c('exp_existing_label'),
      'existing', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'cost_type', oc.cost_type,
                 'label', ct.label,
                 'value_text', public.inr_money(coalesce(oc.override_amount, oc.computed_amount)),
                 'source', oc.source,
                 'note', coalesce(oc.note,''),
                 'has_receipt', (oc.receipt_path is not null))
               order by ct.sort_order, oc.cost_type)
          from order_costs oc join cost_types ct on ct.slug = oc.cost_type
         where oc.order_id = o.id and oc.source = 'manual'), '[]'::jsonb)) as r
      from orders o
     where o.zone_id is not null and o.zone_id::smallint = v_zone
     order by o.created_at desc
     limit greatest(coalesce(p_limit,40), 1)
  ) s;

  perform public.partner_audit('partner.expenses','open', jsonb_build_object('access', v_acc));

  return jsonb_build_object(
    'ok', true, 'access', v_acc, 'can_write', (v_acc='write'),
    'zone_id', v_zone,
    'title',         public._pss_c('exp_title'),
    'subtitle',      public._pss_c('exp_subtitle'),
    'order_label',   public._pss_c('exp_order_label'),
    'type_label',    public._pss_c('exp_type_label'),
    'amount_label',  public._pss_c('exp_amount_label'),
    'note_label',    public._pss_c('exp_note_label'),
    'receipt_label', public._pss_c('exp_receipt_label'),
    'pick_label',    public._pss_c('exp_pick_label'),
    'save_label',    public._pss_c('exp_save_label'),
    'cancel_label',  public._pss_c('cancel_label'),
    'empty_text',    public._pss_c('exp_empty'),
    'frozen_text',   public._pss_c('exp_frozen'),
    'readonly_text', case when v_acc='write' then '' else public._pss_c('exp_readonly') end,
    'receipt_bucket','partner-receipts',
    'cost_types', coalesce(v_types,'[]'::jsonb),
    'rows', coalesce(v_rows,'[]'::jsonb));
end $function$;

create or replace function public.partner_expense_save(
  p_order_id uuid, p_cost_type text, p_amount numeric,
  p_note text default null, p_receipt_path text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_zone smallint := public.partner_zone_id(); o record; v_frozen boolean;
begin
  if public.my_partner_id() is null or not public.partner_can('partner.expenses','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public._pss_c('err_not_authorized'));
  end if;
  select id, zone_id into o from orders where id = p_order_id;
  if o.id is null or v_zone is null or o.zone_id is null or o.zone_id::smallint <> v_zone then
    perform public.partner_audit('partner.expenses','expense_denied_zone',
      jsonb_build_object('order_id', p_order_id, 'order_zone', o.zone_id, 'my_zone', v_zone,
                         'summary', 'Refused: out of zone'));
    return jsonb_build_object('ok',false,'error','out_of_zone','tone','danger',
      'message', public._pss_c('err_out_of_zone'));
  end if;
  if not exists (select 1 from cost_types where slug = p_cost_type and active) then
    return jsonb_build_object('ok',false,'error','no_cost_type','tone','danger',
      'message', public._pss_c('err_no_cost_type'));
  end if;
  if coalesce(p_amount,0) <= 0 then
    return jsonb_build_object('ok',false,'error','bad_amount','tone','danger',
      'message', public._pss_c('err_bad_amount'));
  end if;
  -- A receipt that did not land in OUR folder is not our receipt.
  if p_receipt_path is not null
     and p_receipt_path not like 'p' || public.my_partner_id()::text || '/%' then
    return jsonb_build_object('ok',false,'error','bad_receipt','tone','danger',
      'message', public._pss_c('err_upload_failed'));
  end if;

  select exists (select 1 from partner_settlements s
                   join partner_settlement_periods p on p.id = s.period_id
                  where s.order_id = p_order_id and p.status <> 'open') into v_frozen;
  if v_frozen then
    return jsonb_build_object('ok',false,'error','frozen','tone','danger',
      'message', public._pss_c('exp_frozen'));
  end if;

  -- Same path the admin screen takes: build the day's lines, then override one.
  perform public.settlement_cost_lines_build(p_order_id, false);

  update public.order_costs
     set override_amount = p_amount,
         source          = 'manual',
         note            = p_note,
         edited_by       = 'partner:' || coalesce(public.my_login_email(), public.my_partner_user_id()::text),
         receipt_path    = coalesce(p_receipt_path, receipt_path),
         receipt_bucket  = case when p_receipt_path is null then receipt_bucket else 'partner-receipts' end,
         updated_at      = now()
   where order_id = p_order_id and cost_type = p_cost_type;

  perform public.settlement_order_row(p_order_id);
  perform public.settlement_period_totals(s.period_id)
     from public.partner_settlements s
    where s.order_id = p_order_id and s.period_id is not null;

  perform public.partner_audit('partner.expenses','expense_saved',
    jsonb_build_object('order_id', p_order_id, 'cost_type', p_cost_type,
                       'amount', p_amount, 'has_receipt', (p_receipt_path is not null),
                       'summary', p_cost_type || ' ' || public.inr_money(p_amount)));

  return jsonb_build_object('ok',true,'tone','success',
    'message', public._pss_c('exp_saved'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public._pss_c('err_failed'), '{detail}', SQLERRM), 'sqlstate', SQLSTATE);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. THE FENCE — these RPCs are reachable by a partner login, nothing else is
-- ═══════════════════════════════════════════════════════════════════════════

insert into public.partner_rpc_allow(proname, source, note)
values
  ('partner_staff_console',            'c399','Partner manages its own staff'),
  ('partner_staff_add',                'c399','Partner manages its own staff'),
  ('partner_staff_remove',             'c399','Partner manages its own staff'),
  ('partner_staff_access_set',         'c399','Subset-clamped staff permissions'),
  ('partner_supplier_payment_console', 'c399','Supplier payments in the partner zone'),
  ('partner_sup_record_payment',       'c399','Zone-scoped door onto sup_record_payment'),
  ('partner_expense_console',          'c399','Manual order_costs for the partner zone'),
  ('partner_expense_save',             'c399','Manual order_costs for the partner zone'),
  ('partner_upload_path',              'c399','Receipt/proof upload path in partner-receipts')
on conflict (proname) do nothing;

-- The two features this change creates are the partner's own house-keeping, so
-- an active partner holds them from the moment they exist. Supplier payment is
-- an existing feature and stays exactly as the office configured it.
insert into public.partner_permissions(partner_id, feature_key, access, updated_at, updated_by)
select rp.id, f.k, 'write', now(), 'change_399'
  from region_partners rp
 cross join (values ('partner.staff'), ('partner.expenses')) f(k)
 where coalesce(rp.is_active, true)
on conflict (partner_id, feature_key) do nothing;

grant execute on function public.partner_staff_console()                     to authenticated;
grant execute on function public.partner_staff_add(text, text)               to authenticated;
grant execute on function public.partner_staff_remove(bigint)                to authenticated;
grant execute on function public.partner_staff_access_set(bigint, text, text) to authenticated;
grant execute on function public.partner_supplier_payment_console(int)       to authenticated;
grant execute on function public.partner_sup_record_payment(uuid, text, numeric, text, text, text, text, jsonb) to authenticated;
grant execute on function public.partner_expense_console(int)                to authenticated;
grant execute on function public.partner_expense_save(uuid, text, numeric, text, text) to authenticated;
grant execute on function public.partner_upload_path(text, text, text)       to authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. THE PROOF — a partner cannot act outside its zone or its permission subset
-- ═══════════════════════════════════════════════════════════════════════════
-- Not an assertion about the code: it builds a throwaway partner in a second
-- zone, becomes that login by setting the JWT claim the whole partner stack
-- reads, calls the REAL RPCs the way a hostile client would, and asserts each
-- one refused AND wrote nothing. Everything it created is removed again, and
-- the row counts it took before and after must match.


create or replace function public.c399_partner_fence_proof()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_claims text := coalesce(current_setting('request.jwt.claims', true), '');
  v_boss_uid  uuid := gen_random_uuid();
  v_staff_uid uuid := gen_random_uuid();
  v_zone  smallint;
  v_pid   bigint; v_boss bigint; v_staff bigint;
  v_pay_before bigint; v_pay_after bigint;
  v_cost_before bigint; v_cost_after bigint;
  v_foreign_so uuid; v_foreign_order uuid;
  r jsonb; checks jsonb := '[]'::jsonb; v_ok boolean := true;

begin
  select count(*) into v_pay_before  from supplier_payments;
  select count(*) into v_cost_before from order_costs;

  -- Live rows to aim at, and a zone the fixture partner is NOT in.
  select so.id into v_foreign_so from supplier_orders so
   where so.zone_id is not null order by so.created_at desc limit 1;
  select o.id into v_foreign_order from orders o
   where o.zone_id is not null order by o.created_at desc limit 1;
  select z.id::smallint into v_zone from zones z
   where z.id::smallint not in (
     coalesce((select so.zone_id::smallint from supplier_orders so where so.id = v_foreign_so),-1),
     coalesce((select o.zone_id::smallint  from orders o        where o.id = v_foreign_order),-1))
   order by z.id limit 1;

  insert into region_partners(district, partner_name, zone_id, is_active)
  values ('c399-proof', 'CHANGE 399 fence proof', v_zone, true)
  returning id into v_pid;

  -- The partner holds FULL access on payment and expenses, and only READ on
  -- settlement. Anything refused below is therefore refused by the ZONE or by
  -- the SUBSET rule — never by the partner simply lacking the feature.
  insert into partner_permissions(partner_id, feature_key, access, updated_by)
  values (v_pid,'partner.staff','write','c399_proof'),
         (v_pid,'partner.expenses','write','c399_proof'),
         (v_pid,'partner.supplier_payment','write','c399_proof'),
         (v_pid,'partner.settlement','read','c399_proof');

  insert into partner_users(partner_id, identity, display_name, auth_user_id, created_by)
  values (v_pid, 'c399-proof-boss@example.invalid', 'Proof boss', v_boss_uid, 'c399_proof')
  returning id into v_boss;
  insert into partner_users(partner_id, identity, display_name, auth_user_id, created_by)
  values (v_pid, 'c399-proof-staff@example.invalid','Proof staff', v_staff_uid,'c399_proof')
  returning id into v_staff;
  -- The staff login is configured to NONE on everything.
  insert into partner_user_permissions(partner_user_id, feature_key, access, updated_by)
  select v_staff, fr.feature_key, 'none', 'c399_proof'
    from feature_registry fr
   where fr.is_active and fr.owner='partner' and fr.partner_eligible;

  -- ── as the PARTNER itself ────────────────────────────────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_boss_uid::text, 'role','authenticated')::text, true);

  r := public.partner_supplier_payment_console(5);
  checks := checks || jsonb_build_object('check','partner holds write on supplier payment',
    'expected','can_write=true', 'got', coalesce(r->>'can_write','?'),
    'pass', coalesce((r->>'can_write')::boolean,false));
  v_ok := v_ok and coalesce((r->>'can_write')::boolean,false);

  r := public.partner_sup_record_payment(v_foreign_so,'advance',100,'online','c399 proof',null,null,null);
  checks := checks || jsonb_build_object('check','record a payment on a supplier order in another zone',
    'expected','out_of_zone', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'out_of_zone'));
  v_ok := v_ok and (r->>'error' = 'out_of_zone');

  r := public.partner_expense_save(v_foreign_order,'delivery',250,'c399 proof',null);
  checks := checks || jsonb_build_object('check','file an expense on an order in another zone',
    'expected','out_of_zone', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'out_of_zone'));
  v_ok := v_ok and (r->>'error' = 'out_of_zone');

  r := public.partner_staff_access_set(v_staff,'partner.settlement','write');
  checks := checks || jsonb_build_object('check','grant staff MORE than the partner holds (read → write)',
    'expected','above_your_access', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'above_your_access'));
  v_ok := v_ok and (r->>'error' = 'above_your_access');

  r := public.partner_staff_access_set(v_staff,'partner.settlement','read');
  checks := checks || jsonb_build_object('check','grant staff exactly what the partner holds (read)',
    'expected','allowed', 'got', coalesce(r->>'error','ok'),
    'pass', coalesce((r->>'ok')::boolean,false));
  v_ok := v_ok and coalesce((r->>'ok')::boolean,false);

  r := public.partner_staff_remove(
         (select pu.id from partner_users pu
           where pu.partner_id <> v_pid and coalesce(pu.is_active,true) order by pu.id limit 1));
  checks := checks || jsonb_build_object('check','remove a staff login belonging to another partner',
    'expected','not_your_staff', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'not_your_staff'));
  v_ok := v_ok and (r->>'error' = 'not_your_staff');

  r := public.partner_upload_path('expense','proof','jpg');
  checks := checks || jsonb_build_object('check','upload path is always inside the partner''s own folder',
    'expected','p' || v_pid::text || '/…', 'got', coalesce(r->>'path','')
    , 'pass', (coalesce(r->>'path','') like 'p' || v_pid::text || '/%'
               and r->>'bucket' = 'partner-receipts'));
  v_ok := v_ok and (coalesce(r->>'path','') like 'p' || v_pid::text || '/%');

  -- ── as a STAFF login of the SAME partner, configured to none ─────────────
  -- Same partner, same zone, same features granted to the partner. Everything
  -- below is refused purely because the per-user subset says none.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff_uid::text, 'role','authenticated')::text, true);

  r := public.partner_expense_console(5);
  checks := checks || jsonb_build_object('check','staff subset: expenses console while the partner holds write',
    'expected','no_access', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'no_access'));
  v_ok := v_ok and (r->>'error' = 'no_access');

  r := public.partner_expense_save(v_foreign_order,'delivery',250,'c399 proof',null);
  checks := checks || jsonb_build_object('check','staff subset: save an expense',
    'expected','not_authorized', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'not_authorized'));
  v_ok := v_ok and (r->>'error' = 'not_authorized');

  r := public.partner_sup_record_payment(v_foreign_so,'advance',100,'online','c399 proof',null,null,null);
  checks := checks || jsonb_build_object('check','staff subset: record a supplier payment',
    'expected','not_authorized', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'not_authorized'));
  v_ok := v_ok and (r->>'error' = 'not_authorized');

  r := public.partner_staff_console();
  checks := checks || jsonb_build_object('check','staff subset: the staff screen itself',
    'expected','no_access', 'got', coalesce(r->>'error','ok'),
    'pass', (r->>'error' = 'no_access'));
  v_ok := v_ok and (r->>'error' = 'no_access');

  -- ── back to whoever we were, then remove every fixture row ───────────────
  perform set_config('request.jwt.claims', v_claims, true);

  select count(*) into v_pay_after  from supplier_payments;
  select count(*) into v_cost_after from order_costs;

  delete from partner_user_permissions where updated_by = 'c399_proof';
  delete from partner_users       where partner_id = v_pid;
  delete from partner_audit_log   where partner_id = v_pid;
  delete from partner_permissions where partner_id = v_pid;
  delete from region_partners     where id = v_pid;

  checks := checks || jsonb_build_object('check','not one supplier_payments row was written',
    'expected', v_pay_before, 'got', v_pay_after, 'pass', (v_pay_before = v_pay_after));
  v_ok := v_ok and (v_pay_before = v_pay_after);
  checks := checks || jsonb_build_object('check','not one order_costs row was written',
    'expected', v_cost_before, 'got', v_cost_after, 'pass', (v_cost_before = v_cost_after));
  v_ok := v_ok and (v_cost_before = v_cost_after);

  return jsonb_build_object('ok', v_ok, 'change', 399,
    'title', 'Partner fence: zone scope and permission subset',
    'passed', (select count(*) from jsonb_array_elements(checks) c where (c->>'pass')::boolean),
    'total',  jsonb_array_length(checks),
    'checks', checks);
exception when others then
  perform set_config('request.jwt.claims', v_claims, true);
  delete from partner_user_permissions where updated_by = 'c399_proof';
  delete from partner_users       where partner_id = v_pid;
  delete from partner_audit_log   where partner_id = v_pid;
  delete from partner_permissions where partner_id = v_pid;
  delete from region_partners     where id = v_pid;
  return jsonb_build_object('ok', false, 'change', 399, 'error', SQLERRM, 'sqlstate', SQLSTATE,
                            'checks', checks);
end $function$;

grant execute on function public.c399_partner_fence_proof() to service_role;

-- The label a screen needs when its OWN RPC never answered. It cannot live in
-- that RPC's payload for the obvious reason, so it rides ui_copy, which the app
-- already has cached from boot — alongside partner.error_title and
-- partner.error_message, which were already there waiting for a screen to use
-- them.
insert into public.ui_copy(key, value) values
  ('partner.retry_label', to_jsonb('Try again'::text))
on conflict (key) do update set value = excluded.value;
