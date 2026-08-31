-- CHANGE #394 — PART 2 of 3: granular admin roles.
--
-- Admin access was BINARY: admins.is_super and nothing else. Every admin who
-- was not super saw the same everything, and the only way to keep an accounts
-- person out of Dev Queue was to hope they did not look.
--
-- This is deliberately the SAME shape already built for partners — the
-- feature_registry rows are shared, admin_permissions mirrors
-- partner_permissions, and admin_access() mirrors partner_access(). A new
-- screen therefore defaults to 'none' for admins exactly as it already does
-- for partners: nobody sees a feature because it shipped, they see it because
-- somebody granted it.
--
-- is_super stays the override that always sees everything.

-- ── the audit screen is itself a feature, so it can be granted ─────────────
insert into public.feature_registry(
  feature_key, label, group_label, icon_key, route_key, sort_order, owner,
  partner_eligible, default_access, is_active, category, surface,
  roles_allowed, deep_link, search_terms, description)
values (
  'admin.audit_log', 'Audit trail', 'Admin & System', 'history', 'audit_log', 925,
  'medibo', false, 'none', true, 'system', 'dashboard',
  array['admin','super_admin']::text[], '/admin/go/audit_log',
  'audit log history who changed what trail',
  'Every consequential change, with who made it and what it looked like before.')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      surface = excluded.surface, category = excluded.category,
      roles_allowed = excluded.roles_allowed, is_active = true;

-- ── the grants ─────────────────────────────────────────────────────────────
create table if not exists public.admin_permissions (
  admin_id    uuid    not null references public.admins(id) on delete cascade,
  feature_key text    not null references public.feature_registry(feature_key) on delete cascade,
  access      text    not null check (access in ('none','read','write')),
  updated_at  timestamptz not null default now(),
  updated_by  text,
  primary key (admin_id, feature_key)
);

create index if not exists admin_permissions_feature_idx
  on public.admin_permissions (feature_key);

alter table public.admin_permissions enable row level security;
drop policy if exists admin_permissions_super_read on public.admin_permissions;
create policy admin_permissions_super_read on public.admin_permissions
  for select using (public._is_super());
revoke all on public.admin_permissions from anon, authenticated;
grant select on public.admin_permissions to authenticated;

-- Part 1 could not attach its trigger to a table that did not exist yet.
drop trigger if exists zz_audit_row on public.admin_permissions;
create trigger zz_audit_row
  after insert or update or delete on public.admin_permissions
  for each row execute function public.audit_row_trg();

-- ── presets: the four jobs people actually do here ─────────────────────────
create table if not exists public.admin_role_preset (
  preset_key  text primary key,
  label       text not null,
  description text not null default '',
  sort_order  int  not null default 100,
  is_active   boolean not null default true
);

create table if not exists public.admin_role_preset_feature (
  preset_key  text not null references public.admin_role_preset(preset_key) on delete cascade,
  feature_key text not null references public.feature_registry(feature_key) on delete cascade,
  access      text not null check (access in ('none','read','write')),
  primary key (preset_key, feature_key)
);

insert into public.admin_role_preset(preset_key, label, description, sort_order) values
  ('accounts',  'Accounts',  'Billing, GST, settlements and payment verification. Read-only on the parties behind them.', 10),
  ('ops',       'Operations','Orders, fulfilment, bags and delivery. No money screens.',                                  20),
  ('catalogue', 'Catalogue', 'Medicines, companies, pricing coverage and discount slabs.',                                30),
  ('full',      'Full admin','Every admin screen except the super-admin system tools.',                                   40)
on conflict (preset_key) do update
  set label = excluded.label, description = excluded.description,
      sort_order = excluded.sort_order, is_active = true;

-- The preset CONTENT is derived from feature_registry's own grouping rather
-- than a hand-typed list, so a feature added to "Money" tomorrow is part of
-- the accounts preset without anyone editing this migration.
delete from public.admin_role_preset_feature;

insert into public.admin_role_preset_feature(preset_key, feature_key, access)
select 'accounts', f.feature_key,
       case when f.group_label = 'Money' then 'write' else 'read' end
  from public.feature_registry f
 where f.is_active and f.owner = 'medibo' and f.feature_key like 'admin.%'
   and f.group_label in ('Money','Customers & Suppliers')
on conflict do nothing;

insert into public.admin_role_preset_feature(preset_key, feature_key, access)
select 'ops', f.feature_key,
       case when f.group_label in ('Orders & Fulfilment','Delivery') then 'write' else 'read' end
  from public.feature_registry f
 where f.is_active and f.owner = 'medibo' and f.feature_key like 'admin.%'
   and f.group_label in ('Orders & Fulfilment','Delivery','Customers & Suppliers')
on conflict do nothing;

insert into public.admin_role_preset_feature(preset_key, feature_key, access)
select 'catalogue', f.feature_key,
       case when f.group_label = 'Catalogue & Pricing' then 'write' else 'read' end
  from public.feature_registry f
 where f.is_active and f.owner = 'medibo' and f.feature_key like 'admin.%'
   and f.group_label in ('Catalogue & Pricing','Customers & Suppliers')
on conflict do nothing;

insert into public.admin_role_preset_feature(preset_key, feature_key, access)
select 'full', f.feature_key, 'write'
  from public.feature_registry f
 where f.is_active and f.owner = 'medibo' and f.feature_key like 'admin.%'
   and f.feature_key not in ('admin.dev_queue','admin.manage_admins','admin.audit_log')
on conflict do nothing;

-- ── who am I ───────────────────────────────────────────────────────────────
create or replace function public.my_admin_id()
returns uuid
language sql
stable
security definer
set search_path to 'public', 'auth'
as $$
  select a.id
    from public.admins a
   where a.id = auth.uid()
      or lower(btrim(a.email)) = public.my_login_email()
   order by a.id
   limit 1
$$;

-- ── the access answer, and the only place it is computed ───────────────────
-- Mirrors partner_access(): 'none' | 'read' | 'write', never null. A super
-- admin is 'write' on everything, always — that is the override the spec
-- keeps. A caller may only ask about ANOTHER admin if it is itself super.
create or replace function public.admin_access(p_feature text, p_admin uuid default null)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  with who as (
    select case when p_admin is not null and public._is_super()
                then p_admin else public.my_admin_id() end as admin_id
  )
  select case
    when exists (select 1 from public.admins a, who w
                  where a.id = w.admin_id and coalesce(a.is_super,false)) then 'write'
    else coalesce(
      (select ap.access
         from public.admin_permissions ap
         join public.feature_registry fr on fr.feature_key = ap.feature_key
        where ap.admin_id = (select w.admin_id from who w)
          and ap.feature_key = p_feature
          and fr.is_active and fr.owner = 'medibo'),
      (select fr.default_access from public.feature_registry fr
        where fr.feature_key = p_feature and fr.is_active and fr.owner = 'medibo'
          and fr.default_access = 'read'),
      'none')
  end
$$;

create or replace function public.admin_can(p_feature text, p_need text default 'read')
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(auth.jwt() ->> 'role','') = 'service_role'
      or case coalesce(public.admin_access(p_feature), 'none')
           when 'write' then true
           when 'read'  then coalesce(p_need,'read') = 'read'
           else false
         end
$$;

create or replace function public.admin_require(p_feature text, p_need text default 'read')
returns void
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if not public.admin_can(p_feature, p_need) then
    raise exception 'not_authorized'
      using detail = p_feature, hint = coalesce(p_need,'read');
  end if;
end $$;

-- The RPC → feature map. Extending enforcement to another RPC is one INSERT
-- here plus one admin_require() line in that RPC, never a schema change.
create table if not exists public.admin_rpc_feature (
  proname     text primary key,
  feature_key text not null references public.feature_registry(feature_key) on delete cascade,
  need        text not null default 'write' check (need in ('read','write')),
  note        text not null default ''
);

insert into public.admin_rpc_feature(proname, feature_key, need, note) values
  ('admin_discount_slabs',           'admin.discount_slabs', 'read',  'slab list'),
  ('admin_discount_slab_save',       'admin.discount_slabs', 'write', 'price/slab change'),
  ('admin_discount_slab_delete',     'admin.discount_slabs', 'write', 'price/slab change'),
  ('admin_discount_slab_set_active', 'admin.discount_slabs', 'write', 'price/slab change'),
  ('admin_bill_pipeline_action',     'admin.bill_pipeline',  'write', 'bill edit / re-run'),
  ('admin_claim_decide',             'admin.delivery_ops',   'write', 'payment claim decision'),
  ('admin_payout_pay',               'admin.settlement',     'write', 'partner/rider payment'),
  ('admin_customer_action',          'admin.customers',      'write', 'customer approve/suspend/delete'),
  ('admin_audit_screen',             'admin.audit_log',      'read',  'the audit trail itself'),
  ('admin_audit_entity',             'admin.audit_log',      'read',  'one entity history')
on conflict (proname) do update
  set feature_key = excluded.feature_key, need = excluded.need, note = excluded.note;

create or replace function public.admin_guard(p_proname text)
returns void
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare m public.admin_rpc_feature;
begin
  select * into m from public.admin_rpc_feature where proname = p_proname;
  if m.proname is null then return; end if;
  perform public.admin_require(m.feature_key, m.need);
end $$;

-- ── the nav now asks admin_access() the same question it asks partners ─────
-- This is the one line that turns "every admin sees every tile" into "an
-- admin sees the tiles somebody granted".
create or replace function public.nav_registry()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_uid     uuid := auth.uid();
  v_partner bigint := public.my_partner_id();
  v_counts  jsonb := public.nav_badge_counts();
  v_tiles   jsonb; v_actions jsonb; v_pinned jsonb; v_profile jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
      'message', 'Sign in to see your dashboard.');
  end if;

  with visible as (
    select f.*, (v_counts ->> f.badge_source)::bigint as badge_count,
           (p.feature_key is not null) as pinned, coalesce(u.opens, 0) as opens
      from feature_registry f
      left join nav_pin p on p.feature_key = f.feature_key and p.user_id = v_uid
      left join (select feature_key, count(*) as opens from nav_usage
                  where user_id = v_uid and opened_at > now() - interval '30 days'
                  group by 1) u on u.feature_key = f.feature_key
     where f.is_active and f.route_key <> '' and f.surface = 'dashboard'
       and v_role = any (f.roles_allowed)
       and case when v_partner is not null
                then f.partner_eligible
                     and coalesce(public.partner_access(f.feature_key, v_partner),'none') <> 'none'
                else f.feature_key like 'admin.%'
                     and coalesce(public.admin_access(f.feature_key),'none') <> 'none' end
  ), tile as (
    select v.category, v.feature_key, v.sort_order, v.pinned, v.opens,
           jsonb_build_object(
             'feature_key', v.feature_key, 'label', v.label,
             'icon_key', v.icon_key,
             'icon_letter', upper(left(v.label,1)),
             'route_key', v.route_key,
             'deep_link', v.deep_link, 'badge_count', v.badge_count,
             'badge_label', case when coalesce(v.badge_count,0) > 0
                                 then v.badge_count::text || ' ' || coalesce(v.badge_noun, lower(v.label))
                                 else null end,
             'pinned', v.pinned, 'opens', v.opens) as js
      from visible v
  )
  select
    coalesce((select jsonb_agg(sec order by sec_sort) from (
        select c.sort_order as sec_sort,
               jsonb_build_object('category_key', c.category_key, 'label', c.label,
                 'icon_key', c.icon_key, 'icon_letter', upper(left(c.label,1)),
                 'items', jsonb_agg(t.js order by t.pinned desc, t.opens desc, t.sort_order)) as sec
          from nav_category c join tile t on t.category = c.category_key
         where c.is_active
         group by c.category_key, c.label, c.icon_key, c.sort_order) s), '[]'::jsonb),
    coalesce((select jsonb_agg(t.js order by (t.js->>'badge_count')::bigint desc, t.sort_order)
                from tile t where coalesce((t.js->>'badge_count')::bigint,0) > 0), '[]'::jsonb),
    coalesce((select jsonb_agg(t.js order by t.sort_order) from tile t where t.pinned), '[]'::jsonb)
  into v_tiles, v_actions, v_pinned;

  select coalesce(jsonb_agg(jsonb_build_object(
           'feature_key', f.feature_key, 'label', f.label, 'icon_key', f.icon_key,
           'icon_letter', upper(left(f.label,1)),
           'route_key', f.route_key, 'deep_link', f.deep_link,
           'tone', case when f.feature_key = 'identity.logout' then 'danger' else 'neutral' end
         ) order by f.sort_order), '[]'::jsonb)
    into v_profile from feature_registry f
   where f.is_active and f.surface in ('profile','both') and v_role = any (f.roles_allowed);

  return jsonb_build_object('ok', true, 'role', v_role, 'sections', v_tiles,
    'action_tiles', v_actions, 'pinned', v_pinned, 'profile_menu', v_profile,
    'labels', (select coalesce(jsonb_object_agg(
                 replace(k.key, 'nav.', ''), k.value #>> '{}'), '{}'::jsonb)
                 from ui_copy k where k.key like 'nav.%'));
end $function$;

comment on table public.admin_permissions is
  'CHANGE #394 — per-admin, per-feature access (none|read|write). Mirrors '
  'partner_permissions. is_super overrides everything; an ungranted feature '
  'is none, including every screen shipped after this migration.';
