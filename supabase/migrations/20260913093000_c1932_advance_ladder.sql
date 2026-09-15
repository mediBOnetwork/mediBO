-- CMD #1932 — Advance ladder: advance % by the customer's order count, per
-- zone, FROZEN on the order at creation. Replaces the single global
-- billing_config.advance_pct that six call sites were reading directly.
--
-- Everything here is idempotent: the migration replay runs it on live once,
-- and re-running it must be a no-op.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. THE LADDER TABLE
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.advance_slabs (
  id          bigint generated always as identity primary key,
  zone_id     smallint references public.zones(id) on delete cascade,
  order_no    integer  not null check (order_no >= 1),
  pct         numeric  not null check (pct >= 0 and pct <= 100),
  active      boolean  not null default true,
  valid_from  date     not null default '2000-01-01',
  note        text,
  created_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- One rung per (zone, order_no). NULL zone_id is the all-zones ladder, so it
-- needs its own sentinel in the index or two all-zones rungs would collide.
create unique index if not exists advance_slabs_zone_order_uq
  on public.advance_slabs (coalesce(zone_id, (-1)::smallint), order_no);

create index if not exists advance_slabs_lookup_ix
  on public.advance_slabs (order_no desc, zone_id);

alter table public.advance_slabs enable row level security;
-- No policies: every read and write goes through the SECURITY DEFINER RPCs
-- below, exactly like discount_slabs and billing_config.

-- Seed the all-zones ladder. Existing rows are never overwritten — an admin
-- who has already tuned the ladder keeps their numbers on a replay.
insert into public.advance_slabs (zone_id, order_no, pct, created_by)
values (null, 1, 10, 'cmd-1932'),
       (null, 2, 15, 'cmd-1932'),
       (null, 3, 20, 'cmd-1932'),
       (null, 4, 25, 'cmd-1932'),
       (null, 5, 30, 'cmd-1932')
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. THE FROZEN COLUMNS ON THE ORDER
-- ─────────────────────────────────────────────────────────────────────────
alter table public.orders add column if not exists advance_pct      numeric;
alter table public.orders add column if not exists advance_slab_id  bigint;
alter table public.orders add column if not exists advance_order_no integer;
alter table public.orders add column if not exists advance_at       timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'orders_advance_slab_fk'
                    and conrelid = 'public.orders'::regclass) then
    alter table public.orders
      add constraint orders_advance_slab_fk
      foreign key (advance_slab_id) references public.advance_slabs(id)
      on delete set null;
  end if;
end $$;

-- Backfill: every order placed before the ladder existed keeps the flat
-- advance it was actually billed at (billing_config.advance_pct, 30 today).
update public.orders o
   set advance_pct = coalesce((select b.advance_pct from public.billing_config b where b.id = 1), 30),
       advance_at  = coalesce(o.advance_at, o.created_at)
 where o.advance_pct is null;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. COPY (ui_copy) — every string the ladder renders
-- ─────────────────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('advance.reason_label',        to_jsonb('{ord} order — {pct}% advance'::text)),
  ('advance.reason_default',      to_jsonb('Standard advance — {pct}%'::text)),
  ('advance.panel_label',         to_jsonb('Advance on this order'::text)),
  ('advance_slabs.title',         to_jsonb('Advance ladder'::text)),
  ('advance_slabs.subtitle',      to_jsonb('Advance % by how many orders the pharmacy has already paid in full'::text)),
  ('advance_slabs.empty',         to_jsonb('No rungs yet. Add one to set the advance % for a pharmacy''s nth order.'::text)),
  ('advance_slabs.add_label',     to_jsonb('Add rung'::text)),
  ('advance_slabs.col_order',     to_jsonb('Order'::text)),
  ('advance_slabs.col_pct',       to_jsonb('Advance'::text)),
  ('advance_slabs.col_zone',      to_jsonb('Zone'::text)),
  ('advance_slabs.col_status',    to_jsonb('Status'::text)),
  ('advance_slabs.zone_all',      to_jsonb('All zones'::text)),
  ('advance_slabs.rung_label',    to_jsonb('{ord} order onwards'::text)),
  ('advance_slabs.used_label',    to_jsonb('On {n} orders'::text)),
  ('advance_slabs.used_label_one', to_jsonb('On 1 order'::text)),
  ('advance_slabs.unused_label',  to_jsonb('Not used yet'::text)),
  ('advance_slabs.active_label',  to_jsonb('Active'::text)),
  ('advance_slabs.off_label',     to_jsonb('Off'::text)),
  ('advance_slabs.saved',         to_jsonb('Rung saved'::text)),
  ('advance_slabs.toggled_on',    to_jsonb('Rung turned on'::text)),
  ('advance_slabs.toggled_off',   to_jsonb('Rung turned off'::text)),
  ('advance_slabs.deleted',       to_jsonb('Rung deleted'::text)),
  ('advance_slabs.delete_refused',to_jsonb('This rung is already frozen on {n} order(s), so it cannot be deleted. Turn it off instead.'::text)),
  ('advance_slabs.zone_locked',   to_jsonb('You can only edit the ladder for your own zone.'::text)),
  ('advance_slabs.all_zones_super',to_jsonb('Only a mediBO super admin can edit the all-zones ladder.'::text)),
  ('advance_slabs.not_found',     to_jsonb('That rung no longer exists.'::text)),
  ('advance_slabs.bad_order_no',  to_jsonb('Order number must be 1 or more.'::text)),
  ('advance_slabs.bad_pct',       to_jsonb('Advance % must be between 0 and 100.'::text)),
  ('advance_slabs.duplicate',     to_jsonb('That zone already has a rung for this order number.'::text)),
  ('advance_slabs.zone_hint',     to_jsonb('A zone rung beats the all-zones rung at the same order number.'::text)),
  ('advance_slabs.nav_label',     to_jsonb('Advance ladder'::text)),
  ('advance_slabs.retry',         to_jsonb('Try again'::text)),
  ('advance_slabs.edit_label',    to_jsonb('Edit'::text)),
  ('advance_slabs.delete_label',  to_jsonb('Delete'::text)),
  ('advance_slabs.add_title',     to_jsonb('New rung'::text)),
  ('advance_slabs.edit_title',    to_jsonb('Edit rung'::text)),
  ('advance_slabs.save_label',    to_jsonb('Save rung'::text)),
  ('advance_slabs.field_order',   to_jsonb('Applies from the customer''s nth order'::text)),
  ('advance_slabs.field_pct',     to_jsonb('Advance % of MRP'::text)),
  ('advance_slabs.field_zone',    to_jsonb('Zone'::text)),
  ('advance_slabs.field_note',    to_jsonb('Note (optional)'::text)),
  ('advance_slabs.field_active',  to_jsonb('Rung is on'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. PERMISSION FEATURE KEY (the #307 matrix)
-- ─────────────────────────────────────────────────────────────────────────
-- Only keys kNavIcons can actually draw may be seeded here: the catalogue and
-- that map are held together by test/protected/nav_icon_resolve_test.dart, and
-- a key only one side knows renders as a blank square.
insert into public.ui_icon (icon_key, label) values
  ('rule','Rule'), ('percent','Percent')
on conflict (icon_key) do nothing;
-- 'system' is the column default; 'more_system' is where _feature_registry_home_guard
-- parks a staff tile whose category has no home tab (CHANGE #1160). Both already
-- exist on live — these inserts only matter on a fresh build branch.
insert into public.nav_category (category_key, label, icon_key) values
  ('system','System','rule'), ('more_system','More','rule')
on conflict (category_key) do nothing;

insert into public.feature_registry
  (feature_key, label, group_label, surface, route_key, icon_key, partner_eligible,
   sort_order, description, search_terms)
values
  ('advance_slabs', 'Advance ladder', 'Billing', 'dashboard', 'advance_slabs',
   'percent', true, 120,
   'Advance % by how many orders the pharmacy has already paid in full, per zone.',
   'advance ladder slab percent billing')
on conflict (feature_key) do update
   set label            = excluded.label,
       group_label      = excluded.group_label,
       icon_key         = excluded.icon_key,
       partner_eligible = true,
       is_active        = true,
       description      = excluded.description;

-- CHANGE #821 — the door itself. A shard arm that surface_route never
-- declared fails admin_nav_reachability_test; this row is what the generated
-- mirror (test/protected/registered_routes.dart) is regenerated from.
insert into public.surface_route (route_key, feature_key, kind, handled_by, note)
values ('advance_slabs', 'advance_slabs', 'feature', 'home_shell',
        'CMD #1932 — Advance ladder, opened from shell/shell_extra_routes.dart')
on conflict (route_key, feature_key) do update
   set handled_by = excluded.handled_by,
       kind       = excluded.kind,
       is_active  = true;

-- Role defaults: everyone with an admin/partner login can SEE the ladder that
-- applies to them; writing is off until a super admin turns it on per subject
-- in the access matrix. Super admin is unconditional inside access_can().
insert into public.access_role_default (role, feature_key, can_view, can_write)
values ('super_admin','advance_slabs', true,  true),
       ('admin',      'advance_slabs', true,  false),
       ('partner',    'advance_slabs', true,  false)
on conflict (role, feature_key) do update
   set can_view = greatest(public.access_role_default.can_view::int,
                           excluded.can_view::int)::boolean;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. RESOLVER
-- ─────────────────────────────────────────────────────────────────────────

-- English ordinal, backend-side so no Dart ever builds "2nd".
create or replace function public._advance_ordinal(p_n integer)
returns text language sql immutable as $$
  select case
    when p_n is null then ''
    when (p_n % 100) between 11 and 13 then p_n || 'th'
    when (p_n % 10) = 1 then p_n || 'st'
    when (p_n % 10) = 2 then p_n || 'nd'
    when (p_n % 10) = 3 then p_n || 'rd'
    else p_n || 'th' end;
$$;

-- "10", "12.5" — never "10." (FM990.99 leaves a bare decimal point). Every
-- advance % the app prints comes through here.
create or replace function public._advance_pct_text(p_pct numeric)
returns text language sql immutable as $$
  select rtrim(rtrim(to_char(coalesce(p_pct,0), 'FM999990.99'), '0'), '.');
$$;

-- How many orders this pharmacy has FULLY PAID. Uses the ledger's own
-- definition of an open bill (_pa_open_bills): remaining = total - paid,
-- cancelled/rejected never counts, and a zero-value order is not a bill.
create or replace function public._advance_paid_order_count(
  p_customer_id uuid, p_exclude_order uuid default null)
returns integer language sql stable security definer set search_path to 'public' as $$
  select coalesce(count(*), 0)::int
    from public.orders o
   where p_customer_id is not null
     and o.customer_id = p_customer_id
     and (p_exclude_order is null or o.id <> p_exclude_order)
     and coalesce(o.status, 'pending') not in ('rejected','cancelled')
     and coalesce(o.fulfillment_status, 'open') <> 'cancelled'
     and coalesce(o.total_amount, 0) > 0
     and round(coalesce(o.total_amount,0) - public.order_paid_amount(o.id), 2) <= 0;
$$;

-- The ladder resolver. Highest order_no <= the order this will be wins; a
-- zone rung breaks the tie against the all-zones rung; nothing matches at all
-- falls back to billing_config.advance_pct.
create or replace function public.advance_pct_for(
  p_customer_id uuid, p_zone_id smallint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_paid int; v_no int; v_row public.advance_slabs%rowtype;
  v_pct numeric; v_slab bigint; v_src text; v_label text; v_date date;
begin
  v_paid := public._advance_paid_order_count(p_customer_id);
  v_no   := v_paid + 1;
  v_date := (now() at time zone 'Asia/Kolkata')::date;

  select * into v_row
    from public.advance_slabs s
   where s.active
     and s.valid_from <= v_date
     and s.order_no <= v_no
     and (s.zone_id is null or s.zone_id = p_zone_id)
   order by s.order_no desc,
            (s.zone_id is not null) desc,
            s.valid_from desc,
            s.id desc
   limit 1;

  if found then
    v_pct := v_row.pct; v_slab := v_row.id;
    v_src := case when v_row.zone_id is null then 'all_zones' else 'zone' end;
    v_label := public._cf('advance.reason_label',
                 jsonb_build_object('ord', public._advance_ordinal(v_no),
                                    'pct', public._advance_pct_text(v_pct)));
    if coalesce(v_label,'') = '' then
      v_label := public._advance_ordinal(v_no) || ' order — '
                 || public._advance_pct_text(v_pct) || '% advance';
    end if;
  else
    v_pct := coalesce((select b.advance_pct from public.billing_config b where b.id = 1), 30);
    v_slab := null; v_src := 'billing_config';
    v_label := public._cf('advance.reason_default',
                 jsonb_build_object('pct', public._advance_pct_text(v_pct)));
    if coalesce(v_label,'') = '' then
      v_label := 'Standard advance — ' || public._advance_pct_text(v_pct) || '%';
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'pct', v_pct,
    'pct_label', public._advance_pct_text(v_pct) || '%',
    'slab_id', v_slab,
    'order_no', v_no,
    'paid_count', v_paid,
    'zone_id', p_zone_id,
    'source', v_src,
    'reason_label', v_label);
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. FREEZE AT ORDER CREATION
-- ─────────────────────────────────────────────────────────────────────────
-- Named zz_* on purpose: same-timing triggers fire in NAME order, and this one
-- must run after trg_zone_order and trg_stamp_customer_orders have put
-- zone_id and customer_id on the row.
create or replace function public._c1932_advance_freeze()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if new.advance_pct is null then
    begin
      v := public.advance_pct_for(new.customer_id, new.zone_id);
      new.advance_pct      := (v->>'pct')::numeric;
      new.advance_slab_id  := nullif(v->>'slab_id','')::bigint;
      new.advance_order_no := (v->>'order_no')::int;
    exception when others then
      -- An order is never blocked by the ladder: fall back to the flat pct.
      new.advance_pct := coalesce(
        (select b.advance_pct from public.billing_config b where b.id = 1), 30);
    end;
  end if;
  new.advance_at := coalesce(new.advance_at, now());
  return new;
end $$;

drop trigger if exists zz_c1932_advance_freeze on public.orders;
create trigger zz_c1932_advance_freeze
  before insert on public.orders
  for each row execute function public._c1932_advance_freeze();

-- ─────────────────────────────────────────────────────────────────────────
-- 7. THE FROZEN READ — the ONE place every advance display now reads from
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.order_advance_pct(p_order_id uuid)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select o.advance_pct from public.orders o where o.id = p_order_id),
    (select b.advance_pct from public.billing_config b where b.id = 1),
    30);
$$;

create or replace function public.order_advance_reason(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o public.orders%rowtype; v_pct numeric; v_label text;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then return jsonb_build_object('has', false); end if;
  v_pct := public.order_advance_pct(p_order_id);
  if o.advance_order_no is not null and o.advance_slab_id is not null then
    v_label := public._cf('advance.reason_label',
                 jsonb_build_object('ord', public._advance_ordinal(o.advance_order_no),
                                    'pct', public._advance_pct_text(v_pct)));
  else
    v_label := public._cf('advance.reason_default',
                 jsonb_build_object('pct', public._advance_pct_text(v_pct)));
  end if;
  return jsonb_build_object(
    'has', true,
    'label', public._c('advance.panel_label'),
    'pct', v_pct,
    'pct_label', public._advance_pct_text(v_pct) || '%',
    'order_no', o.advance_order_no,
    'slab_id', o.advance_slab_id,
    'reason_label', coalesce(nullif(v_label,''), public._advance_pct_text(v_pct) || '% advance'));
end $$;

-- _order_advance_state: same shape as before plus the frozen pct and its
-- label, and it no longer re-resolves the ladder.
create or replace function public._order_advance_state(p_order_id uuid)
returns jsonb language plpgsql stable as $function$
declare v_mrp numeric; v_pct numeric; v_req numeric; v_ver numeric; v_reason jsonb;
begin
  select coalesce(sum(oi.quantity * oi.mrp), 0) into v_mrp
    from public.order_items oi where oi.order_id = p_order_id;
  v_pct := public.order_advance_pct(p_order_id);
  v_req := round(v_mrp * coalesce(v_pct, 30) / 100, 2);
  select coalesce(sum(amount) filter (where status in ('received','verified')), 0)
    into v_ver from public.payment_claims where order_id = p_order_id;
  v_ver := greatest(coalesce(v_ver,0), coalesce(public.order_paid_amount(p_order_id),0));
  v_reason := public.order_advance_reason(p_order_id);
  return jsonb_build_object(
    'required', v_req, 'required_display', public.inr_money(v_req),
    'verified', v_ver, 'verified_display', public.inr_money(v_ver),
    'due', greatest(v_req - v_ver, 0),
    'due_display', public.inr_money(greatest(v_req - v_ver, 0)),
    'pct', v_pct,
    'pct_label', coalesce(v_reason->>'pct_label', public._advance_pct_text(v_pct) || '%'),
    'reason_label', coalesce(v_reason->>'reason_label',''),
    'ok', case when v_req > 0 then v_ver >= v_req else v_ver > 0 end);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. REWIRE THE REMAINING ADVANCE CONSUMERS TO THE FROZEN PCT
-- ─────────────────────────────────────────────────────────────────────────
-- Five other functions each read billing_config.advance_pct directly. They are
-- large, unrelated bodies, so this patches the ONE line in each in place
-- instead of re-stating (and possibly reverting) the whole function. Already
-- patched = no-op; pattern missing = loud failure, never a silent half-feature.
do $do$
declare
  v_patch  jsonb := jsonb_build_array(
    jsonb_build_object('fn','cust_order_panel',
      'from','SELECT advance_pct INTO v_advpct FROM billing_config WHERE id = 1;',
      'to',  'v_advpct := public.order_advance_pct(p_order_id);'),
    jsonb_build_object('fn','customer_order_payment_panel',
      'from','SELECT advance_pct INTO v_advpct FROM billing_config WHERE id = 1;',
      'to',  'v_advpct := public.order_advance_pct(p_order_id);'),
    jsonb_build_object('fn','rzp_amount_due',
      'from','select advance_pct into v_advpct from billing_config where id = 1;',
      'to',  'v_advpct := public.order_advance_pct(p_order_id);'),
    jsonb_build_object('fn','payment_claim_autolink',
      'from','coalesce((select advance_pct from billing_config where id = 1), 30)',
      'to',  'coalesce(o.advance_pct, (select advance_pct from billing_config where id = 1), 30)'),
    jsonb_build_object('fn','customer_bill',
      'from','coalesce(cfg.advance_pct,30)',
      'to',  'public.order_advance_pct(p_order_id)'),
    -- …and the two customer-facing panels also PRINT which rung the order
    -- froze, so the pharmacy sees why this order's advance is what it is.
    jsonb_build_object('fn','cust_order_panel',
      'from','''fully_paid'', (v_adv_recv >= v_adv AND v_adv > 0),',
      'to',  '''fully_paid'', (v_adv_recv >= v_adv AND v_adv > 0),
        ''reason_label'', COALESCE(public.order_advance_reason(p_order_id)->>''reason_label'',''''),'),
    jsonb_build_object('fn','customer_order_payment_panel',
      'from','''basis_label'',''Advance'',',
      'to',  '''basis_label'', COALESCE(NULLIF(public._c(''advance.panel_label''),''''),''Advance''),
      ''reason_label'', COALESCE(public.order_advance_reason(p_order_id)->>''reason_label'',''''),'),
    jsonb_build_object('fn','customer_order_payment_panel',
      'from','''advance_label'',''Advance'',',
      'to',  '''advance_label'', COALESCE(NULLIF(public._c(''advance.panel_label''),''''),''Advance''),
      ''advance_reason'', COALESCE(public.order_advance_reason(p_order_id)->>''reason_label'',''''),')
  );
  e jsonb; v_oid oid; v_def text; v_new text;
begin
  for e in select * from jsonb_array_elements(v_patch) loop
    select p.oid into v_oid
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname = (e->>'fn')
     limit 1;
    if v_oid is null then
      raise warning 'c1932: %() not present, skipped', e->>'fn';
      continue;
    end if;
    v_def := pg_get_functiondef(v_oid);
    -- The replacement text itself is the "already done" marker: one of these
    -- five does not name order_advance_pct (it reads the frozen column
    -- inline), so a shared marker would make the replay think it was missed.
    if position((e->>'to') in v_def) > 0 then
      continue;                                  -- already rewired
    end if;
    if position((e->>'from') in v_def) = 0 then
      raise exception 'c1932: advance pattern not found in %() — refusing to leave it on the flat pct', e->>'fn';
    end if;
    v_new := replace(v_def, e->>'from', e->>'to');
    execute v_new;
  end loop;
end $do$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. RPCs — render-ready, zone- and date-scoped, permission-enforced
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._advance_slab_can_write(p_zone_id smallint)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_zone smallint; v_super boolean;
begin
  if not public.access_can('advance_slabs','write') then
    return public.access_denied('advance_slabs','write');
  end if;
  v_super := coalesce((public.access_subject()->>'role') = 'super_admin', false);
  if v_super then return jsonb_build_object('ok', true); end if;
  if p_zone_id is null then
    return jsonb_build_object('ok', false, 'error','all_zones_super',
      'message', coalesce(nullif(public._c('advance_slabs.all_zones_super'),''),
                          'Only a mediBO super admin can edit the all-zones ladder.'));
  end if;
  v_zone := public.admin_active_zone();
  if v_zone is null or v_zone <> p_zone_id then
    return jsonb_build_object('ok', false, 'error','zone_locked',
      'message', coalesce(nullif(public._c('advance_slabs.zone_locked'),''),
                          'You can only edit the ladder for your own zone.'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.advance_slabs_list()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_zone smallint; v_date date; v_super boolean; v_write boolean;
  v_rows jsonb; v_zones jsonb;
begin
  if not public.access_can('advance_slabs','read') then
    return public.access_denied('advance_slabs','read')
           || jsonb_build_object('retry_label',
                coalesce(nullif(public._c('advance_slabs.retry'),''),'Try again'));
  end if;
  v_zone  := public.admin_active_zone();      -- NULL = all zones (super admin)
  v_date  := public.admin_active_date();
  v_super := coalesce((public.access_subject()->>'role') = 'super_admin', false);
  v_write := public.access_can('advance_slabs','write');

  select coalesce(jsonb_agg(r order by r->>'sort_key'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'id', s.id,
      'sort_key', case when s.zone_id is null then '0000' else lpad(s.zone_id::text, 4, '0') end
                  || '-' || lpad(s.order_no::text, 4, '0'),
      'order_no', s.order_no,
      'order_label', replace(coalesce(nullif(public._c('advance_slabs.rung_label'),''), '{ord} order onwards'),
                             '{ord}', public._advance_ordinal(s.order_no)),
      'pct', s.pct,
      'pct_label', public._advance_pct_text(s.pct) || '%',
      'zone_id', s.zone_id,
      'zone_label', coalesce(z.name, nullif(public._c('advance_slabs.zone_all'),''), 'All zones'),
      'active', s.active,
      'status_label', case when s.active
                           then coalesce(nullif(public._c('advance_slabs.active_label'),''),'Active')
                           else coalesce(nullif(public._c('advance_slabs.off_label'),''),'Off') end,
      'status_tone', case when s.active then 'good' else 'warn' end,
      'in_force', (s.active and s.valid_from <= v_date),
      'valid_from', s.valid_from,
      'note', coalesce(s.note,''),
      'used_count', u.n,
      'used_label', case
        when u.n = 1 then coalesce(nullif(public._c('advance_slabs.used_label_one'),''),'On 1 order')
        when u.n > 1 then replace(coalesce(nullif(public._c('advance_slabs.used_label'),''),'On {n} orders'), '{n}', u.n::text)
        else coalesce(nullif(public._c('advance_slabs.unused_label'),''),'Not used yet') end,
      'can_edit', (v_write and (v_super or (s.zone_id is not null and s.zone_id = v_zone))),
      'can_delete', (v_write and u.n = 0 and (v_super or (s.zone_id is not null and s.zone_id = v_zone)))
    ) r
    from public.advance_slabs s
    left join public.zones z on z.id = s.zone_id
    cross join lateral (
      select count(*)::int n from public.orders o where o.advance_slab_id = s.id
    ) u
    where v_zone is null or s.zone_id is null or s.zone_id = v_zone
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'label', z.name) order by z.name), '[]'::jsonb)
    into v_zones
    from public.zones z
   where coalesce(z.is_active, true)
     and (v_zone is null or z.id = v_zone);

  return jsonb_build_object(
    'ok', true,
    'title',    coalesce(nullif(public._c('advance_slabs.title'),''),'Advance ladder'),
    'subtitle', public._c('advance_slabs.subtitle'),
    'hint',     public._c('advance_slabs.zone_hint'),
    'add_label',coalesce(nullif(public._c('advance_slabs.add_label'),''),'Add rung'),
    'empty_text', public._c('advance_slabs.empty'),
    'can_write', v_write,
    'can_add_all_zones', v_super,
    'zone_id', v_zone,
    'zone_label', coalesce((select z.name from public.zones z where z.id = v_zone),
                           nullif(public._c('advance_slabs.zone_all'),''), 'All zones'),
    'all_zones_label', coalesce(nullif(public._c('advance_slabs.zone_all'),''),'All zones'),
    'active_date', to_char(v_date, 'DD Mon YYYY'),
    'columns', jsonb_build_array(
      jsonb_build_object('key','order_label','label', coalesce(nullif(public._c('advance_slabs.col_order'),''),'Order'),'align','left'),
      jsonb_build_object('key','pct_label',  'label', coalesce(nullif(public._c('advance_slabs.col_pct'),''),'Advance'),'align','right'),
      jsonb_build_object('key','zone_label', 'label', coalesce(nullif(public._c('advance_slabs.col_zone'),''),'Zone'),'align','left'),
      jsonb_build_object('key','status_label','label', coalesce(nullif(public._c('advance_slabs.col_status'),''),'Status'),'align','left')),
    'retry_label', coalesce(nullif(public._c('advance_slabs.retry'),''),'Try again'),
    'edit_label',  coalesce(nullif(public._c('advance_slabs.edit_label'),''),'Edit'),
    'delete_label',coalesce(nullif(public._c('advance_slabs.delete_label'),''),'Delete'),
    'form', jsonb_build_object(
      'add_title',    coalesce(nullif(public._c('advance_slabs.add_title'),''),'New rung'),
      'edit_title',   coalesce(nullif(public._c('advance_slabs.edit_title'),''),'Edit rung'),
      'save_label',   coalesce(nullif(public._c('advance_slabs.save_label'),''),'Save rung'),
      'order_label',  coalesce(nullif(public._c('advance_slabs.field_order'),''),'Applies from the customer''s nth order'),
      'pct_label',    coalesce(nullif(public._c('advance_slabs.field_pct'),''),'Advance % of MRP'),
      'zone_label',   coalesce(nullif(public._c('advance_slabs.field_zone'),''),'Zone'),
      'note_label',   coalesce(nullif(public._c('advance_slabs.field_note'),''),'Note (optional)'),
      'active_label', coalesce(nullif(public._c('advance_slabs.field_active'),''),'Rung is on')),
    'zones', v_zones,
    'rows', v_rows);
end $$;

create or replace function public.advance_slab_save(p jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint; v_zone smallint; v_order_no int; v_pct numeric;
  v_active boolean; v_from date; v_note text; v_gate jsonb; v_old public.advance_slabs%rowtype;
begin
  v_id       := nullif(p->>'id','')::bigint;
  v_zone     := nullif(p->>'zone_id','')::smallint;
  v_order_no := nullif(p->>'order_no','')::int;
  v_pct      := nullif(p->>'pct','')::numeric;
  v_active   := coalesce((p->>'active')::boolean, true);
  v_from     := coalesce(nullif(p->>'valid_from','')::date, '2000-01-01'::date);
  v_note     := nullif(btrim(coalesce(p->>'note','')),'');

  if v_id is not null then
    select * into v_old from public.advance_slabs where id = v_id;
    if not found then
      return jsonb_build_object('ok', false, 'error','not_found',
        'message', coalesce(nullif(public._c('advance_slabs.not_found'),''),'That rung no longer exists.'));
    end if;
    v_zone := coalesce(v_zone, v_old.zone_id);
    -- A non-super caller may not move a rung out of the zone they own.
    v_gate := public._advance_slab_can_write(v_old.zone_id);
    if not (v_gate->>'ok')::boolean then return v_gate; end if;
  end if;

  v_gate := public._advance_slab_can_write(v_zone);
  if not (v_gate->>'ok')::boolean then return v_gate; end if;

  if v_order_no is null or v_order_no < 1 then
    return jsonb_build_object('ok', false, 'error','bad_order_no',
      'message', coalesce(nullif(public._c('advance_slabs.bad_order_no'),''),'Order number must be 1 or more.'));
  end if;
  if v_pct is null or v_pct < 0 or v_pct > 100 then
    return jsonb_build_object('ok', false, 'error','bad_pct',
      'message', coalesce(nullif(public._c('advance_slabs.bad_pct'),''),'Advance % must be between 0 and 100.'));
  end if;

  begin
    if v_id is null then
      insert into public.advance_slabs (zone_id, order_no, pct, active, valid_from, note, created_by)
      values (v_zone, v_order_no, v_pct, v_active, v_from, v_note,
              coalesce(public.access_subject()->>'id',''))
      returning id into v_id;
    else
      update public.advance_slabs
         set zone_id = v_zone, order_no = v_order_no, pct = v_pct,
             active = v_active, valid_from = v_from, note = v_note, updated_at = now()
       where id = v_id;
    end if;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error','duplicate',
      'message', coalesce(nullif(public._c('advance_slabs.duplicate'),''),
                          'That zone already has a rung for this order number.'));
  end;

  return jsonb_build_object('ok', true, 'id', v_id,
    'message', coalesce(nullif(public._c('advance_slabs.saved'),''),'Rung saved'));
end $$;

create or replace function public.advance_slab_toggle(p_id bigint, p_active boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_row public.advance_slabs%rowtype; v_gate jsonb;
begin
  select * into v_row from public.advance_slabs where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', coalesce(nullif(public._c('advance_slabs.not_found'),''),'That rung no longer exists.'));
  end if;
  v_gate := public._advance_slab_can_write(v_row.zone_id);
  if not (v_gate->>'ok')::boolean then return v_gate; end if;

  update public.advance_slabs
     set active = coalesce(p_active, not v_row.active), updated_at = now()
   where id = p_id;

  return jsonb_build_object('ok', true, 'id', p_id, 'active', coalesce(p_active, not v_row.active),
    'message', case when coalesce(p_active, not v_row.active)
      then coalesce(nullif(public._c('advance_slabs.toggled_on'),''),'Rung turned on')
      else coalesce(nullif(public._c('advance_slabs.toggled_off'),''),'Rung turned off') end);
end $$;

create or replace function public.advance_slab_delete(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_row public.advance_slabs%rowtype; v_gate jsonb; v_used int;
begin
  select * into v_row from public.advance_slabs where id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', coalesce(nullif(public._c('advance_slabs.not_found'),''),'That rung no longer exists.'));
  end if;
  v_gate := public._advance_slab_can_write(v_row.zone_id);
  if not (v_gate->>'ok')::boolean then return v_gate; end if;

  select count(*)::int into v_used from public.orders o where o.advance_slab_id = p_id;
  if v_used > 0 then
    return jsonb_build_object('ok', false, 'error','in_use', 'used_count', v_used,
      'message', replace(coalesce(nullif(public._c('advance_slabs.delete_refused'),''),
                   'This rung is already frozen on {n} order(s), so it cannot be deleted. Turn it off instead.'),
                 '{n}', v_used::text));
  end if;

  delete from public.advance_slabs where id = p_id;
  return jsonb_build_object('ok', true, 'id', p_id,
    'message', coalesce(nullif(public._c('advance_slabs.deleted'),''),'Rung deleted'));
end $$;

revoke all on function public.advance_slabs_list() from public;
revoke all on function public.advance_slab_save(jsonb) from public;
revoke all on function public.advance_slab_toggle(bigint, boolean) from public;
revoke all on function public.advance_slab_delete(bigint) from public;
grant execute on function public.advance_slabs_list() to authenticated;
grant execute on function public.advance_slab_save(jsonb) to authenticated;
grant execute on function public.advance_slab_toggle(bigint, boolean) to authenticated;
grant execute on function public.advance_slab_delete(bigint) to authenticated;
grant execute on function public.advance_pct_for(uuid, smallint) to authenticated;
grant execute on function public.order_advance_reason(uuid) to authenticated;
grant execute on function public.order_advance_pct(uuid) to authenticated;
