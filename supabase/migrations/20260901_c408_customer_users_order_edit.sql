-- CHANGE #408 — pharmacy staff logins + order editing before the inquiry starts.
--
-- Two verified-absent customer features, both built on patterns that already
-- work elsewhere in this codebase rather than on anything new:
--
--   1. STAFF LOGINS. `partner_users` (#307) and `supplier_users` (#402) already
--      link extra identities to one business through `login_identities`. The
--      pharmacy owner had no such object, so an owner who wanted a counter
--      person to place orders handed over their own login. `customer_users` is
--      the same table for `pharmacy_profiles`, bound the same way, so
--      `my_customer_id()` resolves a staff member to the pharmacy with NO
--      change to the resolver: it already accepts any identity whose
--      login_identities row says owner_type='customer'.
--
--   2. ORDER EDIT BEFORE INQUIRY. Placing an order is not the point of no
--      return — asking a supplier is. Between the two there is a window in
--      which changing the basket costs nobody anything, and the customer had
--      no way to use it. The window closes on `inquiry.asked_at`, which is the
--      engine's OWN marker for "this product has been put to a supplier"; it is
--      never a client-side guess.
--
-- The edit itself is one UPDATE of `orders.items`, because two triggers already
-- do the hard parts atomically and correctly:
--   `explode_order_items`      rewrites order_items from the new items array
--   `trg_wa_notify_order_updated`  re-fires the WhatsApp summary, and is
--                              already gated `WHEN (new.items IS DISTINCT FROM old.items)`
-- so the "atomic rewrite" and the "re-fire the summary" the spec asks for are
-- the existing, proven paths — not a second implementation of them.
--
-- Idempotent throughout: a resumed worker re-applies this file as a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. ACCESS PRESETS — the dropdown IS this table.
--    A level the backend does not hold can never be offered, and `rank` is what
--    makes "capped at the owner account's own capabilities" a comparison
--    instead of a hardcoded list of who-may-grant-what.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.customer_access_preset (
  access_key  text primary key,
  copy_key    text not null,
  desc_key    text,
  rank        integer not null,
  sort_order  integer not null default 0,
  is_active   boolean not null default true
);

insert into public.customer_access_preset(access_key, copy_key, desc_key, rank, sort_order) values
  ('order_only',     'customer_staff.role_order_only',     'customer_staff.role_order_only_desc',     10, 1),
  ('order_payments', 'customer_staff.role_order_payments', 'customer_staff.role_order_payments_desc', 20, 2),
  ('full',           'customer_staff.role_full',           'customer_staff.role_full_desc',           30, 3)
on conflict (access_key) do update
  set copy_key = excluded.copy_key, desc_key = excluded.desc_key,
      rank = excluded.rank, sort_order = excluded.sort_order, is_active = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. customer_users — the same shape as supplier_users, for the same reason.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.customer_users (
  id            bigserial primary key,
  customer_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  identity      text not null unique,
  display_name  text,
  access_key    text not null default 'order_only'
                  references public.customer_access_preset(access_key),
  auth_user_id  uuid,
  is_active     boolean not null default true,
  created_by    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists customer_users_customer_idx on public.customer_users(customer_id);

alter table public.customer_users enable row level security;
-- No policy: every read and write goes through the SECURITY DEFINER RPCs below,
-- exactly as supplier_users does. RLS on with no policy means the anon and
-- authenticated roles see nothing directly.
revoke all on public.customer_users from anon, authenticated;
revoke all on public.customer_access_preset from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. ATTRIBUTION — who did what, on the row and in a log.
--    The order carries the acting staff member so the owner sees it on the
--    order itself; the log carries every action so the owner and an admin can
--    read a history that outlives any one order row.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.orders
  add column if not exists acted_customer_user_id bigint,
  add column if not exists acted_identity text;

create table if not exists public.customer_action_log (
  id               bigserial primary key,
  customer_id      uuid,
  customer_user_id bigint,
  identity         text,
  action_key       text not null,
  order_id         uuid,
  detail           jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);
create index if not exists customer_action_log_cust_idx  on public.customer_action_log(customer_id, created_at desc);
create index if not exists customer_action_log_order_idx on public.customer_action_log(order_id);
alter table public.customer_action_log enable row level security;
revoke all on public.customer_action_log from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. ORDER EDIT EVENTS — the spec asks for an order event on every edit. It is
--    its own table so the before/after basket is inspectable, which an audit
--    row of the whole `orders` tuple is not.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.order_edit_event (
  id               bigserial primary key,
  order_id         uuid not null,
  customer_id      uuid,
  customer_user_id bigint,
  identity         text,
  acting_as_admin  boolean not null default false,
  items_before     jsonb,
  items_after      jsonb,
  lines_before     integer,
  lines_after      integer,
  total_before     numeric,
  total_after      numeric,
  created_at       timestamptz not null default now()
);
create index if not exists order_edit_event_order_idx on public.order_edit_event(order_id, created_at desc);
alter table public.order_edit_event enable row level security;
revoke all on public.order_edit_event from anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. COPY — every string this change renders. Nothing below is written in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('customer_staff.title',                    to_jsonb('Staff logins'::text)),
  ('customer_staff.subtitle',                 to_jsonb('People at your pharmacy who can sign in with their own number or email.'::text)),
  ('customer_staff.tile_label',               to_jsonb('Staff logins'::text)),
  ('customer_staff.tile_hint',                to_jsonb('Let counter staff sign in with their own login'::text)),
  ('customer_staff.add_label',                to_jsonb('Add staff'::text)),
  ('customer_staff.add_hint',                 to_jsonb('Phone number or email'::text)),
  ('customer_staff.name_hint',                to_jsonb('Name (optional)'::text)),
  ('customer_staff.save_label',               to_jsonb('Add'::text)),
  ('customer_staff.remove_label',             to_jsonb('Remove'::text)),
  ('customer_staff.access_label',             to_jsonb('Access'::text)),
  ('customer_staff.owner_label',              to_jsonb('Owner'::text)),
  ('customer_staff.role_owner',               to_jsonb('Owner · full access'::text)),
  ('customer_staff.role_you',                 to_jsonb('You'::text)),
  ('customer_staff.empty',                    to_jsonb('No staff logins yet. Only the owner account can sign in.'::text)),
  ('customer_staff.added_on',                 to_jsonb('Added {date}'::text)),
  ('customer_staff.activity_heading',         to_jsonb('Recent activity'::text)),
  ('customer_staff.activity_empty',           to_jsonb('Nothing yet. Orders and payments will show who did them.'::text)),
  ('customer_staff.role_order_only',          to_jsonb('Orders only'::text)),
  ('customer_staff.role_order_only_desc',     to_jsonb('Place and edit orders. Cannot see or record payments.'::text)),
  ('customer_staff.role_order_payments',      to_jsonb('Orders and payments'::text)),
  ('customer_staff.role_order_payments_desc', to_jsonb('Everything above, plus bills and recording a payment.'::text)),
  ('customer_staff.role_full',                to_jsonb('Full access'::text)),
  ('customer_staff.role_full_desc',           to_jsonb('Everything, including managing staff logins.'::text)),
  ('customer_staff.err_not_authorized',       to_jsonb('Only the pharmacy owner can manage staff logins.'::text)),
  ('customer_staff.err_bad_identity',         to_jsonb('Enter a valid phone number or email address.'::text)),
  ('customer_staff.err_bad_access',           to_jsonb('That access level is not available.'::text)),
  ('customer_staff.err_above_own',            to_jsonb('You cannot give someone more access than you have yourself.'::text)),
  ('customer_staff.err_identity_taken',       to_jsonb('That login already belongs to another account.'::text)),
  ('customer_staff.err_already_owner',        to_jsonb('That is the owner login for this pharmacy.'::text)),
  ('customer_staff.err_not_found',            to_jsonb('That staff login is no longer on this pharmacy.'::text)),
  ('customer_staff.err_self',                 to_jsonb('You cannot change your own access.'::text)),
  ('customer_staff.err_failed',               to_jsonb('Could not save that: {detail}'::text)),
  ('customer_staff.added',                    to_jsonb('Staff login added.'::text)),
  ('customer_staff.removed',                  to_jsonb('Staff login removed.'::text)),
  ('customer_staff.access_saved',             to_jsonb('Access updated.'::text)),
  ('customer_staff.act_order_placed',         to_jsonb('placed an order'::text)),
  ('customer_staff.act_order_edited',         to_jsonb('edited an order'::text)),
  ('customer_staff.act_payment_marked',       to_jsonb('marked an order paid'::text)),

  ('order_edit.title',                        to_jsonb('Edit this order'::text)),
  ('order_edit.subtitle',                     to_jsonb('You can still change this basket — we have not asked a supplier yet.'::text)),
  ('order_edit.button',                       to_jsonb('Edit order'::text)),
  ('order_edit.save_label',                   to_jsonb('Save changes'::text)),
  ('order_edit.add_label',                    to_jsonb('Add item'::text)),
  ('order_edit.search_hint',                  to_jsonb('Search medicines to add'::text)),
  ('order_edit.remove_label',                 to_jsonb('Remove'::text)),
  ('order_edit.qty_label',                    to_jsonb('Qty'::text)),
  ('order_edit.window_open',                  to_jsonb('Editable until we ask a supplier'::text)),
  ('order_edit.empty_basket',                 to_jsonb('An order needs at least one item. Remove the order instead of emptying it.'::text)),
  ('order_edit.no_change',                    to_jsonb('Nothing changed.'::text)),
  ('order_edit.saved',                        to_jsonb('Order updated. We have sent you the new summary.'::text)),
  ('order_edit.err_not_authorized',           to_jsonb('This order is not yours to edit.'::text)),
  ('order_edit.err_not_found',                to_jsonb('That order no longer exists.'::text)),
  ('order_edit.err_inquiry_started',          to_jsonb('We have already started asking suppliers for this order, so it can no longer be changed. Contact us and we will help.'::text)),
  ('order_edit.err_closed',                   to_jsonb('This order is closed.'::text)),
  ('order_edit.err_bad_qty',                  to_jsonb('Quantity must be a whole number of 1 or more.'::text)),
  ('order_edit.err_unknown_item',             to_jsonb('One of those items is not in the catalogue any more.'::text)),
  ('order_edit.err_unavailable',              to_jsonb('Some items are not available right now. Remove them and save again.'::text)),
  ('order_edit.err_failed',                   to_jsonb('Could not save the changes: {detail}'::text)),
  ('order_edit.reason_inquiry_started',       to_jsonb('Suppliers have been asked'::text)),
  ('order_edit.reason_closed',                to_jsonb('Order closed'::text)),
  ('order_edit.reason_not_pending',           to_jsonb('Already being fulfilled'::text)),
  ('order_edit.edited_badge',                 to_jsonb('Edited {count}×'::text)),
  ('order_edit.by_label',                     to_jsonb('by {who}'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. RESOLVERS — who am I, and what may I do.
--    my_customer_id() already resolves a staff identity to the pharmacy: it
--    looks at login_identities, which customer_staff_add writes. Nothing in the
--    session layer changes.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.my_customer_user_id()
returns bigint language sql stable security definer set search_path to 'public' as $$
  select cu.id
  from customer_users cu
  join pharmacy_profiles pp on pp.id = cu.customer_id
  where coalesce(cu.is_active, true)
    and coalesce(pp.is_deleted, false) = false
    and (cu.auth_user_id = auth.uid() or cu.identity = any (public.my_identity_keys()))
  order by cu.id
  limit 1
$$;

-- The rank the CURRENT caller holds on their own pharmacy. The owner login is
-- the top of the table by definition; a staff login is whatever it was graded.
-- An admin acting as a customer gets the owner rank, because that is the whole
-- point of acting as them.
create or replace function public.my_customer_rank()
returns integer language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select p.rank
       from customer_users cu
       join customer_access_preset p on p.access_key = cu.access_key
      where cu.id = public.my_customer_user_id()),
    -- not a staff row => the owner login (or an admin acting as them)
    (select max(rank) from customer_access_preset where is_active))
$$;

-- One gate for every customer feature. `p_need` is the rank a feature costs.
create or replace function public.customer_can(p_feature text, p_need text default 'read')
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare v_rank integer;
begin
  if public.my_customer_id() is null then return false; end if;
  v_rank := public.my_customer_rank();
  return case p_feature
    when 'customer.orders'   then v_rank >= 10
    when 'customer.payments' then v_rank >= 20
    when 'customer.staff'    then v_rank >= 30
    else false
  end;
end $$;

-- The stamp every attributed action calls. Returns the log row id so a caller
-- can reference it; never raises — attribution must not be able to fail a sale.
create or replace function public.customer_action_stamp(
  p_action_key text, p_order_id uuid default null, p_detail jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_cu bigint; v_ident text;
begin
  v_cu := public.my_customer_user_id();
  select coalesce((select identity from customer_users where id = v_cu),
                  public.my_login_email())
    into v_ident;
  insert into customer_action_log(customer_id, customer_user_id, identity, action_key, order_id, detail)
  values (public.my_customer_id(), v_cu, v_ident, p_action_key, p_order_id, coalesce(p_detail,'{}'::jsonb))
  returning id into v_id;
  return v_id;
exception when others then
  return null;
end $$;

-- How a staff member is NAMED wherever an action is shown. One place, so the
-- owner's order list, the activity list and the admin view never disagree.
create or replace function public.customer_actor_label(p_user_id bigint, p_identity text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    nullif(btrim(coalesce((select display_name from customer_users where id = p_user_id), '')), ''),
    nullif(btrim(coalesce(p_identity, '')), ''),
    (select identity from customer_users where id = p_user_id),
    public.ui_text('customer_staff.role_owner'))
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. STAFF MANAGEMENT RPCs — supplier_staff_* , for the customer side.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.customer_staff_list()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cid uuid := public.my_customer_id();
        v_me  bigint := public.my_customer_user_id();
        v_rank integer; v_can_write boolean; pp record;
begin
  if v_cid is null then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'tone', 'danger',
      'message', public.ui_text('customer_staff.err_not_authorized'));
  end if;
  v_can_write := public.customer_can('customer.staff','write');
  v_rank := public.my_customer_rank();
  select * into pp from pharmacy_profiles where id = v_cid;

  return jsonb_build_object(
    'ok', true,
    'title',            public.ui_text('customer_staff.title'),
    'subtitle',         public.ui_text('customer_staff.subtitle'),
    'can_manage',       v_can_write,
    'add_label',        public.ui_text('customer_staff.add_label'),
    'add_hint',         public.ui_text('customer_staff.add_hint'),
    'name_hint',        public.ui_text('customer_staff.name_hint'),
    'save_label',       public.ui_text('customer_staff.save_label'),
    'remove_label',     public.ui_text('customer_staff.remove_label'),
    'access_label',     public.ui_text('customer_staff.access_label'),
    'empty',            public.ui_text('customer_staff.empty'),
    'activity_heading', public.ui_text('customer_staff.activity_heading'),
    'activity_empty',   public.ui_text('customer_staff.activity_empty'),
    -- CAPPED AT THE CALLER'S OWN LEVEL. A rank above the caller's is not
    -- disabled in the UI — it is never sent, so it cannot be picked at all.
    'access_options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'access_key', p.access_key,
               'label',       public.ui_text(p.copy_key),
               'description', public.ui_text(coalesce(p.desc_key,'')))
             order by p.sort_order, p.access_key)
        from customer_access_preset p
       where p.is_active and p.rank <= v_rank), '[]'::jsonb),
    'rows',
      -- the OWNER first: a real row, never removable, never re-graded.
      jsonb_build_array(jsonb_build_object(
        'id', null,
        'identity',    coalesce(nullif(btrim(coalesce(pp.email,'')),''), pp.phone),
        'name',        coalesce(nullif(btrim(coalesce(pp.owner_name,'')),''), pp.pharmacy_name),
        'access_key',  null,
        'access_label', public.ui_text('customer_staff.role_owner'),
        'is_owner',    true,
        'is_self',     v_me is null,
        'can_remove',  false,
        'can_edit_access', false,
        'added_label', ''))
      ||
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id',            cu.id,
                 'identity',      cu.identity,
                 'name',          coalesce(nullif(btrim(coalesce(cu.display_name,'')),''), cu.identity),
                 'access_key',    cu.access_key,
                 'access_label',  public.ui_text(p.copy_key),
                 'is_owner',      false,
                 'is_self',       cu.id = v_me,
                 -- you can never remove or re-grade yourself, and never touch
                 -- someone graded above you.
                 'can_remove',      v_can_write and cu.id is distinct from v_me and p.rank <= v_rank,
                 'can_edit_access', v_can_write and cu.id is distinct from v_me and p.rank <= v_rank,
                 'added_label',   replace(public.ui_text('customer_staff.added_on'),
                                          '{date}', public.ist_fmt(cu.created_at, 'dmy')))
               order by cu.created_at, cu.id)
          from customer_users cu
          join customer_access_preset p on p.access_key = cu.access_key
         where cu.customer_id = v_cid and coalesce(cu.is_active, true)), '[]'::jsonb),
    'activity', coalesce((
      select jsonb_agg(jsonb_build_object(
               'when',  public.ist_fmt(l.created_at, 'dmy_hm'),
               'who',   public.customer_actor_label(l.customer_user_id, l.identity),
               'what',  public.ui_text('customer_staff.act_' || l.action_key),
               'order_code', coalesce((select o.order_code from orders o where o.id = l.order_id), ''))
             order by l.created_at desc)
        from (select * from customer_action_log
               where customer_id = v_cid order by created_at desc limit 20) l), '[]'::jsonb));
end $$;

create or replace function public.customer_staff_add(
  p_identity text, p_name text default null, p_access_key text default 'order_only')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cid uuid := public.my_customer_id(); k text; own record; v_id bigint;
        v_existing record; v_rank integer; v_want integer;
begin
  if v_cid is null or not public.customer_can('customer.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public.ui_text('customer_staff.err_not_authorized'));
  end if;
  k := public.identity_norm(p_identity);
  if k is null then
    return jsonb_build_object('ok',false,'error','bad_identity','tone','danger',
      'message', public.ui_text('customer_staff.err_bad_identity'));
  end if;

  select rank into v_want from customer_access_preset
   where access_key = coalesce(p_access_key,'order_only') and is_active;
  if v_want is null then
    return jsonb_build_object('ok',false,'error','bad_access','tone','danger',
      'message', public.ui_text('customer_staff.err_bad_access'));
  end if;
  v_rank := public.my_customer_rank();
  if v_want > v_rank then
    return jsonb_build_object('ok',false,'error','above_own','tone','danger',
      'message', public.ui_text('customer_staff.err_above_own'));
  end if;

  -- Global identity uniqueness is UNCHANGED: a login that already belongs to
  -- anyone else — any role — is never adopted.
  select li.owner_type, li.owner_id into own from login_identities li where li.identity = k;
  if own.owner_type is not null
     and (own.owner_type <> 'customer' or own.owner_id is distinct from v_cid::text) then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public.ui_text('customer_staff.err_identity_taken'));
  end if;
  if own.owner_type = 'customer' and own.owner_id = v_cid::text
     and not exists (select 1 from customer_users where identity = k) then
    return jsonb_build_object('ok',false,'error','already_owner','tone','danger',
      'message', public.ui_text('customer_staff.err_already_owner'));
  end if;

  select * into v_existing from customer_users where identity = k;
  if v_existing.id is not null and v_existing.customer_id <> v_cid then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public.ui_text('customer_staff.err_identity_taken'));
  end if;

  insert into customer_users(customer_id, identity, display_name, access_key, created_by)
  values (v_cid, k, nullif(btrim(coalesce(p_name,'')),''), coalesce(p_access_key,'order_only'),
          coalesce(public.my_login_email(),'customer'))
  on conflict (identity) do update
    set customer_id = excluded.customer_id, is_active = true,
        access_key  = excluded.access_key,
        display_name = coalesce(excluded.display_name, customer_users.display_name),
        updated_at = now()
  returning id into v_id;

  -- The SAME binding every customer login already uses, so my_customer_id()
  -- and get_my_role() resolve this person with no further change.
  insert into login_identities(identity, kind, owner_type, owner_id)
  values (k, case when position('@' in k) > 0 then 'email' else 'phone' end, 'customer', v_cid::text)
  on conflict (identity) do update set owner_type = 'customer', owner_id = v_cid::text;

  return jsonb_build_object('ok',true,'id',v_id,'identity',k,'tone','success',
    'message', public.ui_text('customer_staff.added'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('customer_staff.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $$;

create or replace function public.customer_staff_remove(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cid uuid := public.my_customer_id(); r record; v_rank integer; v_their integer;
begin
  if v_cid is null or not public.customer_can('customer.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public.ui_text('customer_staff.err_not_authorized'));
  end if;
  select * into r from customer_users where id = p_id and customer_id = v_cid;
  if r.id is null then
    return jsonb_build_object('ok',false,'error','not_found','tone','danger',
      'message', public.ui_text('customer_staff.err_not_found'));
  end if;
  if r.id = public.my_customer_user_id() then
    return jsonb_build_object('ok',false,'error','self','tone','danger',
      'message', public.ui_text('customer_staff.err_self'));
  end if;
  v_rank := public.my_customer_rank();
  select rank into v_their from customer_access_preset where access_key = r.access_key;
  if coalesce(v_their,0) > v_rank then
    return jsonb_build_object('ok',false,'error','above_own','tone','danger',
      'message', public.ui_text('customer_staff.err_above_own'));
  end if;

  delete from customer_users where id = r.id;
  -- The binding goes with it, or the removed person still resolves to the
  -- pharmacy on their next login. That was the whole vulnerability.
  delete from login_identities
   where identity = r.identity and owner_type = 'customer' and owner_id = v_cid::text;

  return jsonb_build_object('ok',true,'tone','success',
    'message', public.ui_text('customer_staff.removed'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('customer_staff.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $$;

create or replace function public.customer_staff_set_access(p_id bigint, p_access_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cid uuid := public.my_customer_id(); r record;
        v_rank integer; v_want integer; v_their integer;
begin
  if v_cid is null or not public.customer_can('customer.staff','write') then
    return jsonb_build_object('ok',false,'error','not_authorized','tone','danger',
      'message', public.ui_text('customer_staff.err_not_authorized'));
  end if;
  select * into r from customer_users where id = p_id and customer_id = v_cid;
  if r.id is null then
    return jsonb_build_object('ok',false,'error','not_found','tone','danger',
      'message', public.ui_text('customer_staff.err_not_found'));
  end if;
  if r.id = public.my_customer_user_id() then
    return jsonb_build_object('ok',false,'error','self','tone','danger',
      'message', public.ui_text('customer_staff.err_self'));
  end if;
  select rank into v_want  from customer_access_preset where access_key = p_access_key and is_active;
  select rank into v_their from customer_access_preset where access_key = r.access_key;
  if v_want is null then
    return jsonb_build_object('ok',false,'error','bad_access','tone','danger',
      'message', public.ui_text('customer_staff.err_bad_access'));
  end if;
  v_rank := public.my_customer_rank();
  if v_want > v_rank or coalesce(v_their,0) > v_rank then
    return jsonb_build_object('ok',false,'error','above_own','tone','danger',
      'message', public.ui_text('customer_staff.err_above_own'));
  end if;

  update customer_users set access_key = p_access_key, updated_at = now() where id = r.id;
  return jsonb_build_object('ok',true,'tone','success',
    'message', public.ui_text('customer_staff.access_saved'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('customer_staff.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE EDIT WINDOW.
--    One gate, used by the read RPC and the write RPC, so what the button says
--    and what the save enforces can never drift apart. The window closes on
--    `inquiry.asked_at` — the engine's own marker for "a supplier has been
--    asked" — plus the ordinary closed / already-being-fulfilled cases.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._order_edit_gate(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o record; v_cid uuid := public.my_customer_id(); v_asked boolean; v_moved boolean;
begin
  select * into o from orders where id = p_order_id;
  if o.id is null then
    return jsonb_build_object('can_edit', false, 'error', 'not_found',
      'message', public.ui_text('order_edit.err_not_found'));
  end if;

  -- Ownership: your own order, or an admin acting as this customer. Acting-as
  -- gets exactly the same window, per the spec.
  if not (o.customer_id is not distinct from v_cid
          or public.get_my_role() in ('admin','super_admin')) then
    return jsonb_build_object('can_edit', false, 'error', 'not_authorized',
      'message', public.ui_text('order_edit.err_not_authorized'));
  end if;

  if o.closed_at is not null
     or lower(coalesce(o.status,'')) in ('cancelled','canceled','rejected','delivered','completed') then
    return jsonb_build_object('can_edit', false, 'error', 'closed',
      'reason', public.ui_text('order_edit.reason_closed'),
      'message', public.ui_text('order_edit.err_closed'));
  end if;

  -- HAS A SUPPLIER BEEN ASKED? Two independent signals, either one closes the
  -- window: the item carries an inquiry row that was asked, or a live inquiry
  -- row for the same product/date/zone was asked. `supplier_order_id` covers a
  -- row that was already converted into a supplier order.
  select exists (
    select 1
      from order_items oi
      left join lateral (
        select q.* from inquiry q
         where q.id = oi.inquiry_id
            or (oi.inquiry_id is null
                and q.product_id = oi.product_id
                and q.batch_date = oi.order_date
                and (q.zone_id is not distinct from oi.zone_id or q.zone_id is null))
         order by (q.id = oi.inquiry_id) desc, q.id desc
         limit 1) i on true
     where oi.order_id = p_order_id
       and (i.asked_at is not null or i.supplier_order_id is not null)
  ) into v_asked;

  if v_asked then
    return jsonb_build_object('can_edit', false, 'error', 'inquiry_started',
      'reason', public.ui_text('order_edit.reason_inquiry_started'),
      'message', public.ui_text('order_edit.err_inquiry_started'));
  end if;

  -- Physical fulfilment having started is the same closed door by another
  -- route: something has been counted, received, bagged or packed.
  select exists (
    select 1 from order_items oi
     where oi.order_id = p_order_id
       and (coalesce(oi.fulfillment_state,'pending') <> 'pending'
            or coalesce(oi.received_qty,0) > 0
            or coalesce(oi.at_warehouse,false)
            or coalesce(oi.packed,false)
            or oi.bag_no is not null)
  ) into v_moved;

  if v_moved or coalesce(o.fulfillment_status,'open') <> 'open' then
    return jsonb_build_object('can_edit', false, 'error', 'not_pending',
      'reason', public.ui_text('order_edit.reason_not_pending'),
      'message', public.ui_text('order_edit.err_closed'));
  end if;

  return jsonb_build_object('can_edit', true,
    'window_label', public.ui_text('order_edit.window_open'));
end $$;

-- The screen asks ONE question and renders the answer. `can_edit` is the flag
-- the affordance is drawn from — never a status string Dart interprets.
create or replace function public.order_edit_state(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare g jsonb; o record; v_lines jsonb; v_edits integer;
begin
  g := public._order_edit_gate(p_order_id);
  select * into o from orders where id = p_order_id;

  select count(*) into v_edits from order_edit_event where order_id = p_order_id;

  if (g->>'can_edit')::boolean is not true then
    return jsonb_build_object(
      'ok', true, 'order_id', p_order_id,
      'can_edit', false,
      'error',   g->>'error',
      'reason',  coalesce(g->>'reason',''),
      'message', coalesce(g->>'message',''),
      'edited_count', v_edits,
      'edited_badge', case when v_edits > 0
                           then replace(public.ui_text('order_edit.edited_badge'), '{count}', v_edits::text)
                           else '' end);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',   oi.product_id,
           'product_name', oi.product_name,
           'quantity',     coalesce(oi.quantity, 0)::int,
           'qty_label',    coalesce(oi.quantity, 0)::int::text,
           'mrp',          oi.mrp,
           'line_label',   coalesce(oi.product_name,''),
           'remove_label', public.ui_text('order_edit.remove_label'))
         order by oi.created_at, oi.id), '[]'::jsonb)
    into v_lines
    from order_items oi where oi.order_id = p_order_id;

  return jsonb_build_object(
    'ok', true, 'order_id', p_order_id,
    'can_edit',     true,
    'title',        public.ui_text('order_edit.title'),
    'subtitle',     public.ui_text('order_edit.subtitle'),
    'button_label', public.ui_text('order_edit.button'),
    'save_label',   public.ui_text('order_edit.save_label'),
    'add_label',    public.ui_text('order_edit.add_label'),
    'search_hint',  public.ui_text('order_edit.search_hint'),
    'qty_label',    public.ui_text('order_edit.qty_label'),
    'remove_label', public.ui_text('order_edit.remove_label'),
    'window_label', coalesce(g->>'window_label',''),
    'empty_message', public.ui_text('order_edit.empty_basket'),
    'lines',        v_lines,
    'edited_count', v_edits,
    'edited_badge', case when v_edits > 0
                         then replace(public.ui_text('order_edit.edited_badge'), '{count}', v_edits::text)
                         else '' end);
end $$;

-- The write. `p_lines` is [{product_id, quantity}] — the WHOLE basket the
-- customer wants, not a delta, so add / remove / change quantity are one call
-- and one transaction. The items array is rewritten in place; the existing
-- explode_order_items trigger rebuilds order_items atomically, and the existing
-- trg_wa_notify_order_updated re-fires the WhatsApp summary.
create or replace function public.order_edit_apply(p_order_id uuid, p_lines jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare g jsonb; o record; v_cid uuid := public.my_customer_id();
        v_items jsonb; v_total numeric; v_before jsonb; v_bad int;
        v_unavail jsonb; v_cnt int; v_log bigint; v_cu bigint;
begin
  g := public._order_edit_gate(p_order_id);
  if (g->>'can_edit')::boolean is not true then
    return jsonb_build_object('ok', false, 'error', g->>'error', 'tone','danger',
      'message', coalesce(g->>'message',''));
  end if;
  if not public.customer_can('customer.orders','write')
     and public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('order_edit.err_not_authorized'));
  end if;

  select * into o from orders where id = p_order_id for update;
  v_before := o.items;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    return jsonb_build_object('ok', false, 'error','empty_basket','tone','danger',
      'message', public.ui_text('order_edit.empty_basket'));
  end if;

  -- SAME VALIDATION AS CHECKOUT, in the same order.
  -- (a) every quantity a whole number >= 1
  select count(*) into v_bad from jsonb_array_elements(p_lines) l
   where coalesce((l->>'quantity')::numeric, 0) < 1
      or (l->>'quantity')::numeric <> floor((l->>'quantity')::numeric);
  if v_bad > 0 then
    return jsonb_build_object('ok', false, 'error','bad_qty','tone','danger',
      'message', public.ui_text('order_edit.err_bad_qty'));
  end if;

  -- (b) every product still in the catalogue
  select count(*) into v_bad from jsonb_array_elements(p_lines) l
   where not exists (select 1 from "MEDICINE" m where m.id = (l->>'product_id')::bigint);
  if v_bad > 0 then
    return jsonb_build_object('ok', false, 'error','unknown_item','tone','danger',
      'message', public.ui_text('order_edit.err_unknown_item'));
  end if;

  -- (c) availability — the SAME question the cart asks before checkout.
  -- _cart_unavailable_lines() reads medicine_zone_standby(pid, zone) <= 0, so
  -- that is exactly what is asked here, against the ORDER's own zone. A second
  -- definition of "available" is how a cart and an order start disagreeing.
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id', m.id, 'product_name', m.product_name)), '[]'::jsonb)
    into v_unavail
    from jsonb_array_elements(p_lines) l
    join "MEDICINE" m on m.id = (l->>'product_id')::bigint
   where o.zone_id is not null
     and public.medicine_zone_standby(m.id, o.zone_id) <= 0;
  if jsonb_array_length(v_unavail) > 0 then
    return jsonb_build_object('ok', false, 'error','unavailable','tone','danger',
      'items', v_unavail, 'count', jsonb_array_length(v_unavail),
      'message', public.ui_text('order_edit.err_unavailable'));
  end if;

  -- (d) serviceability — checkout_action() asks delivery_serviceability_check()
  -- for the delivery pincode and lets `can_order=false` be the ONLY blocker.
  -- The edit window honours the same rule rather than a stricter one.
  begin
    if (select coalesce((public.delivery_serviceability_check(
           (select pp.pincode from pharmacy_profiles pp where pp.id = o.customer_id)
         )->>'can_order')::boolean, true)) is false then
      return jsonb_build_object('ok', false, 'error','not_serviceable','tone','danger',
        'message', coalesce(
          (public.delivery_serviceability_check(
             (select pp.pincode from pharmacy_profiles pp where pp.id = o.customer_id))->>'message'),
          public.ui_text('order_edit.err_failed')));
    end if;
  end;

  -- Rebuild the items array in the SHAPE explode_order_items already reads,
  -- carrying the catalogue's own name/mrp/gst so nothing is invented here.
  select jsonb_agg(jsonb_build_object(
           'product_id',   m.id,
           'product_name', m.product_name,
           'quantity',     (l->>'quantity')::numeric,
           'mrp',          m.mrp,
           'gst_percent',  m.gst_percent)
         order by m.product_name)
    into v_items
    from jsonb_array_elements(p_lines) l
    join "MEDICINE" m on m.id = (l->>'product_id')::bigint;

  if v_items is not distinct from v_before then
    return jsonb_build_object('ok', false, 'error','no_change','tone','info',
      'message', public.ui_text('order_edit.no_change'));
  end if;

  select coalesce(sum(coalesce((it->>'mrp')::numeric,0) * coalesce((it->>'quantity')::numeric,0)), 0)
    into v_total from jsonb_array_elements(v_items) it;

  v_cu := public.my_customer_user_id();

  -- ONE update. The triggers do the rest: order_items is rewritten atomically
  -- and the WhatsApp summary is re-fired because `items` changed.
  update orders
     set items = v_items,
         total_amount = v_total,
         acted_customer_user_id = v_cu,
         acted_identity = coalesce((select identity from customer_users where id = v_cu),
                                   public.my_login_email())
   where id = p_order_id;

  select count(*) into v_cnt from jsonb_array_elements(v_items);

  -- (e) slab estimate — the basket changed, so the discount slab the order sits
  -- in may have changed with it. Re-snapshot rather than leave a stale slab.
  begin
    perform public.order_slab_snapshot(p_order_id, true);
  exception when others then null;
  end;

  insert into order_edit_event(order_id, customer_id, customer_user_id, identity,
                               acting_as_admin, items_before, items_after,
                               lines_before, lines_after, total_before, total_after)
  values (p_order_id, o.customer_id, v_cu,
          coalesce((select identity from customer_users where id = v_cu), public.my_login_email()),
          (public.my_acting_as() is not null),
          v_before, v_items,
          coalesce(jsonb_array_length(v_before), 0), v_cnt,
          o.total_amount, v_total);

  v_log := public.customer_action_stamp('order_edited', p_order_id,
             jsonb_build_object('lines_before', coalesce(jsonb_array_length(v_before),0),
                                'lines_after', v_cnt));

  return jsonb_build_object('ok', true, 'tone','success',
    'order_id', p_order_id,
    'line_count', v_cnt,
    'total', v_total,
    'total_display', public.inr_money(v_total),
    'message', public.ui_text('order_edit.saved'));
exception when others then
  return jsonb_build_object('ok', false, 'error','exception','tone','danger',
    'message', replace(public.ui_text('order_edit.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. ATTRIBUTION ON THE OTHER TWO ACTIONS.
--    The edit stamps itself above. Placement and the payment action are
--    existing functions, so they are wrapped rather than rewritten: a trigger
--    stamps the order row on INSERT, and the payment RPC gets one extra call.
--    Attribution must never be able to fail the action it describes, so both
--    paths swallow their own errors.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c408_stamp_order_actor()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_cu bigint;
begin
  begin
    v_cu := public.my_customer_user_id();
    NEW.acted_customer_user_id := v_cu;
    NEW.acted_identity := coalesce((select identity from customer_users where id = v_cu),
                                   public.my_login_email());
  exception when others then null;
  end;
  return NEW;
end $$;

drop trigger if exists c408_stamp_order_actor on public.orders;
create trigger c408_stamp_order_actor
  before insert on public.orders
  for each row execute function public._c408_stamp_order_actor();

-- The placement log entry. A trigger, so it covers EVERY path that creates an
-- order (storefront, bulk upload, an admin acting as the customer), not just
-- the one RPC the spec happened to name.
create or replace function public._c408_log_order_placed()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  begin
    perform public.customer_action_stamp('order_placed', NEW.id,
      jsonb_build_object('order_code', coalesce(NEW.order_code,'')));
  exception when others then null;
  end;
  return NEW;
end $$;

drop trigger if exists c408_log_order_placed on public.orders;
create trigger c408_log_order_placed
  after insert on public.orders
  for each row execute function public._c408_log_order_placed();

-- The payment action. rzp_order_paid() is the customer's "I have paid" tap;
-- it is wrapped so the acting staff member is recorded without touching the
-- money path itself.
do $wrap$
declare v_src text;
begin
  select pg_get_functiondef(oid) into v_src
    from pg_proc where proname = 'rzp_order_paid' and pronamespace = 'public'::regnamespace;
  if v_src is null then return; end if;               -- not on this instance: nothing to wrap
  if v_src like '%customer_action_stamp%' then return; end if;  -- already wrapped: idempotent

  execute 'alter function public.rzp_order_paid(uuid) rename to _c408_rzp_order_paid_inner';
  execute $fn$
    create or replace function public.rzp_order_paid(p_order_id uuid)
    returns jsonb language plpgsql security definer set search_path to 'public' as $inner$
    declare v_out jsonb;
    begin
      v_out := public._c408_rzp_order_paid_inner(p_order_id);
      begin
        perform public.customer_action_stamp('payment_marked', p_order_id, '{}'::jsonb);
      exception when others then null;
      end;
      return v_out;
    end $inner$
  $fn$;
end $wrap$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. WHO DID WHAT — one reader, two audiences.
--     The owner passes nothing and gets their own pharmacy. An admin passes a
--     customer id and gets that one. Neither renders a single string in Dart.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.customer_activity(p_customer_id uuid default null, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cid uuid; v_admin boolean := public.get_my_role() in ('admin','super_admin');
begin
  v_cid := case when v_admin and p_customer_id is not null then p_customer_id
                else public.my_customer_id() end;
  if v_cid is null then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('customer_staff.err_not_authorized'));
  end if;
  -- A non-admin may only ever read their OWN pharmacy, whatever they passed.
  if not v_admin and v_cid is distinct from public.my_customer_id() then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('customer_staff.err_not_authorized'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'heading', public.ui_text('customer_staff.activity_heading'),
    'empty',   public.ui_text('customer_staff.activity_empty'),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'when',       public.ist_fmt(l.created_at, 'dmy_hm'),
               'who',        public.customer_actor_label(l.customer_user_id, l.identity),
               'what',       public.ui_text('customer_staff.act_' || l.action_key),
               'is_owner',   l.customer_user_id is null,
               'order_code', coalesce((select o.order_code from orders o where o.id = l.order_id), ''))
             order by l.created_at desc)
        from (select * from customer_action_log
               where customer_id = v_cid
               order by created_at desc
               limit greatest(1, least(coalesce(p_limit,50), 200))) l), '[]'::jsonb));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 11. GRANTS. Every one of these is SECURITY DEFINER and checks the caller
--     itself; anon gets none of them, because none of these is a public page.
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on function public.customer_staff_list()                          from public, anon;
revoke all on function public.customer_staff_add(text, text, text)           from public, anon;
revoke all on function public.customer_staff_remove(bigint)                  from public, anon;
revoke all on function public.customer_staff_set_access(bigint, text)        from public, anon;
revoke all on function public.customer_activity(uuid, integer)               from public, anon;
revoke all on function public.order_edit_state(uuid)                         from public, anon;
revoke all on function public.order_edit_apply(uuid, jsonb)                  from public, anon;
revoke all on function public.customer_action_stamp(text, uuid, jsonb)       from public, anon;
revoke all on function public.customer_can(text, text)                       from public, anon;
revoke all on function public.my_customer_user_id()                          from public, anon;
revoke all on function public.my_customer_rank()                             from public, anon;
revoke all on function public._order_edit_gate(uuid)                         from public, anon;

grant execute on function public.customer_staff_list()                    to authenticated;
grant execute on function public.customer_staff_add(text, text, text)     to authenticated;
grant execute on function public.customer_staff_remove(bigint)            to authenticated;
grant execute on function public.customer_staff_set_access(bigint, text)  to authenticated;
grant execute on function public.customer_activity(uuid, integer)         to authenticated;
grant execute on function public.order_edit_state(uuid)                   to authenticated;
grant execute on function public.order_edit_apply(uuid, jsonb)            to authenticated;
grant execute on function public.customer_can(text, text)                 to authenticated;
grant execute on function public.my_customer_user_id()                    to authenticated;
grant execute on function public.my_customer_rank()                       to authenticated;
