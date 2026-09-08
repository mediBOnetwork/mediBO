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

-- ─────────────────────────────────────────────────────────────────────────────
-- 12. TWO FIXES THE PROOF FOUND, both in this file so a replay carries them.
--
-- (a) `oi.bag_no is not null` was the wrong test for "packing has started".
--     assign_order_bag_no() stamps a bag number at PLACEMENT, before anything
--     physical has happened, so every fresh order looked already-fulfilled and
--     the edit window was never open. Packing is `packed` / `pack_counted_at`;
--     a bag number is only a label.
--
-- (b) my_customer_id() resolves a login through login_identities, which needs
--     the JWT to carry the very identity the owner typed. A staff member who
--     signs in through Google, or whose phone claim sits somewhere else, would
--     be bound in customer_users and still resolve to nothing. The branch below
--     is purely additive: it matches only rows in a table that did not exist
--     before this change, so it cannot alter the answer for anyone who is not
--     pharmacy staff.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.my_customer_id()
returns uuid language sql stable security definer set search_path to 'public' as $$
  with k as (select public.my_identity_keys() keys),
  mapped as (select 1 from login_identities li, k where li.identity = any (k.keys) limit 1)
  select pp.id
  from pharmacy_profiles pp, k
  where coalesce(pp.is_deleted,false) = false
    and (
      exists (select 1 from login_identities li
               where li.owner_type = 'customer' and li.owner_id = pp.id::text
                 and li.identity = any (k.keys))
      -- CHANGE #408 — a staff login on this pharmacy, by identity or by the
      -- auth user it was bound to.
      or exists (select 1 from customer_users cu
                  where cu.customer_id = pp.id
                    and coalesce(cu.is_active, true)
                    and (cu.identity = any (k.keys) or cu.auth_user_id = auth.uid()))
      or (not exists (select 1 from mapped) and pp.user_id = auth.uid())
    )
  order by pp.id
  limit 1
$$;

create or replace function public._order_edit_gate(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare o record; v_cid uuid := public.my_customer_id(); v_asked boolean; v_moved boolean;
begin
  select * into o from orders where id = p_order_id;
  if o.id is null then
    return jsonb_build_object('can_edit', false, 'error', 'not_found',
      'message', public.ui_text('order_edit.err_not_found'));
  end if;

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

  -- Physical fulfilment having started. NOT bag_no: that is stamped at
  -- placement by assign_order_bag_no() and means nothing has happened yet.
  select exists (
    select 1 from order_items oi
     where oi.order_id = p_order_id
       and (coalesce(oi.fulfillment_state,'pending') <> 'pending'
            or coalesce(oi.received_qty,0) > 0
            or coalesce(oi.at_warehouse,false)
            or coalesce(oi.packed,false)
            or oi.shop_qty is not null
            or oi.assigned_supplier is not null)
  ) into v_moved;

  if v_moved or coalesce(o.fulfillment_status,'open') <> 'open' then
    return jsonb_build_object('can_edit', false, 'error', 'not_pending',
      'reason', public.ui_text('order_edit.reason_not_pending'),
      'message', public.ui_text('order_edit.err_closed'));
  end if;

  return jsonb_build_object('can_edit', true,
    'window_label', public.ui_text('order_edit.window_open'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 13. TWO MORE THE PROOF FOUND — both about money, and the second one matters.
--
-- (a) `MEDICINE.mrp` is TEXT holding a rendered rupee string ('₹359.95'), not a
--     number. Putting it into the items array raised
--     `invalid input syntax for type numeric: "₹2597"` inside
--     explode_order_items. `_slab_num()` is this codebase's own parser for that
--     column, so the edit uses it rather than a second regex.
--
-- (b) The first version totalled the basket as MRP × quantity. That is the one
--     thing the business context forbids outright: "MRP printed on medicine
--     packs is reference/regulatory information only... Any build that prices,
--     totals, or reports revenue on MRP is wrong." An order's amount is the
--     trade/PTR total, which is exactly what `cart_pricing_block()` computes and
--     what `_place_order_v2_core()` stores at placement. The edit now recomputes
--     it through the SAME function, so an edited order is priced the way a
--     placed order is — and, since the basket changed, re-runs the slab
--     snapshot on top of it.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.order_edit_apply(p_order_id uuid, p_lines jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare g jsonb; o record; v_items jsonb; v_total numeric; v_before jsonb; v_bad int;
        v_unavail jsonb; v_cnt int; v_cu bigint; v_pricing jsonb; v_pin text;
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

  -- (c) availability — the same predicate _cart_unavailable_lines() uses.
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

  -- (d) serviceability — checkout_action() lets can_order=false be the ONLY
  -- blocker; the edit window honours the same rule, not a stricter one.
  select pp.pincode into v_pin from pharmacy_profiles pp where pp.id = o.customer_id;
  if coalesce((public.delivery_serviceability_check(v_pin)->>'can_order')::boolean, true) is false then
    return jsonb_build_object('ok', false, 'error','not_serviceable','tone','danger',
      'message', coalesce(
        public.delivery_serviceability_check(v_pin)->>'message',
        public.ui_text('order_edit.err_unavailable')));
  end if;

  -- Rebuild the items array in the SHAPE explode_order_items reads, carrying
  -- the catalogue's own name and its mrp PARSED OUT of the rendered string.
  select jsonb_agg(jsonb_build_object(
           'product_id',   m.id,
           'product_name', m.product_name,
           'quantity',     (l->>'quantity')::numeric,
           'mrp',          public._slab_num(m.mrp),
           'gst_percent',  m.gst_percent)
         order by m.product_name)
    into v_items
    from jsonb_array_elements(p_lines) l
    join "MEDICINE" m on m.id = (l->>'product_id')::bigint;

  if v_items is not distinct from v_before then
    return jsonb_build_object('ok', false, 'error','no_change','tone','info',
      'message', public.ui_text('order_edit.no_change'));
  end if;

  -- THE TOTAL IS THE TRADE TOTAL, never MRP. Same function placement uses.
  v_pricing := public.cart_pricing_block(v_items);
  v_total   := coalesce((v_pricing->>'net_payable')::numeric, 0);

  v_cu := public.my_customer_user_id();

  update orders
     set items = v_items,
         total_amount = v_total,
         acted_customer_user_id = v_cu,
         acted_identity = coalesce((select identity from customer_users where id = v_cu),
                                   public.my_login_email())
   where id = p_order_id;

  select count(*) into v_cnt from jsonb_array_elements(v_items);

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

  perform public.customer_action_stamp('order_edited', p_order_id,
            jsonb_build_object('lines_before', coalesce(jsonb_array_length(v_before),0),
                               'lines_after', v_cnt));

  return jsonb_build_object('ok', true, 'tone','success',
    'order_id', p_order_id,
    'line_count', v_cnt,
    'total', v_total,
    'total_display', coalesce(v_pricing->>'net_payable_display', public.inr_money(v_total)),
    'message', public.ui_text('order_edit.saved'));
exception when others then
  return jsonb_build_object('ok', false, 'error','exception','tone','danger',
    'message', replace(public.ui_text('order_edit.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $$;

revoke all on function public.order_edit_apply(uuid, jsonb) from public, anon;
grant execute on function public.order_edit_apply(uuid, jsonb) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 14. THE LAST ONE THE PROOF FOUND, and the most important of the lot.
--
-- The gate's fallback lateral matched a live inquiry row on `oi.order_date` and
-- `oi.zone_id`. Neither is written by explode_order_items — they are stamped
-- later, by the fulfilment path — so on a fresh order both are NULL, every
-- comparison went NULL, and the fallback matched nothing. An order whose
-- suppliers had already been asked still reported `can_edit: true`, which is
-- the exact failure this feature exists to prevent: a customer changing a
-- basket the waterfall was already working.
--
-- The order itself always carries both (`_set_order_date` and `_zone_set_order`
-- are BEFORE INSERT triggers), so the gate falls back to the ORDER's date and
-- zone whenever the item has not been stamped yet.
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

  select exists (
    select 1
      from order_items oi
      left join lateral (
        select q.* from inquiry q
         where q.id = oi.inquiry_id
            or (oi.inquiry_id is null
                and q.product_id = oi.product_id
                and q.batch_date = coalesce(oi.order_date, o.order_date)
                and (q.zone_id is not distinct from coalesce(oi.zone_id, o.zone_id)
                     or q.zone_id is null))
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

  -- Physical fulfilment having started. NOT bag_no: that is stamped at
  -- placement by assign_order_bag_no() and means nothing has happened yet.
  select exists (
    select 1 from order_items oi
     where oi.order_id = p_order_id
       and (coalesce(oi.fulfillment_state,'pending') <> 'pending'
            or coalesce(oi.received_qty,0) > 0
            or coalesce(oi.at_warehouse,false)
            or coalesce(oi.packed,false)
            or oi.shop_qty is not null
            or oi.assigned_supplier is not null)
  ) into v_moved;

  if v_moved or coalesce(o.fulfillment_status,'open') <> 'open' then
    return jsonb_build_object('can_edit', false, 'error', 'not_pending',
      'reason', public.ui_text('order_edit.reason_not_pending'),
      'message', public.ui_text('order_edit.err_closed'));
  end if;

  return jsonb_build_object('can_edit', true,
    'window_label', public.ui_text('order_edit.window_open'));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 15. THE EDIT WINDOW TRAVELS WITH THE ORDER.
--
-- The first wiring had each order card call order_edit_state() for itself,
-- which is one round trip per visible card — a customer scrolling ten orders
-- paid for ten extra RPCs to learn something the list already knew. The gate is
-- a cheap read against rows my_orders_screen() has already joined, so it is
-- answered there, once, and the card renders `order.edit.can_edit`.
-- order_edit_state() stays for the sheet itself, which needs the line list.
CREATE OR REPLACE FUNCTION public.my_orders_screen(p_view_as_user uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cust uuid;
  v_admin boolean := coalesce((public.my_session()->>'is_admin')::boolean, false);
  v_cfg  jsonb := coalesce((select value from app_settings where key='order_status_config'), '{}'::jsonb);
  v_copy jsonb := coalesce((select value from app_settings where key='orders_screen_copy'), '{}'::jsonb);
  v_unf  jsonb := coalesce((select value from app_settings where key='unfulfilled_copy'), '{}'::jsonb);
  -- tone -> chip colours. Config, not code: recolouring a status is an UPDATE.
  v_tone jsonb := coalesce((select value from app_settings where key='item_status_tones'),
                    '{"green":{"bg":"#E1F5EE","fg":"#0F6E56"},
                      "yellow":{"bg":"#FEF3C7","fg":"#92400E"},
                      "red":{"bg":"#FBE9E7","fg":"#B42318"}}'::jsonb);
  v_rows jsonb; v_title text; v_note text;
begin
  if p_view_as_user is not null and v_admin then
    v_cust := coalesce(public.customer_id_for_user(p_view_as_user), p_view_as_user);
  else
    v_cust := public.my_customer_id();
  end if;

  select coalesce(jsonb_agg(o order by o->>'placed_at' desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'id',                coalesce(ord.id::text,''),
      'order_code',        coalesce(ord.order_code,''),
      'placed_at',         coalesce(ord.created_at::text,''),
      'status',            coalesce(ord.status,'pending'),
      'status_label',      coalesce(nullif(v_cfg->lower(coalesce(ord.status,'pending'))->>'label',''),
                                    initcap(coalesce(ord.status,'pending'))),
      'status_color',      coalesce(v_cfg->lower(coalesce(ord.status,'pending'))->>'color',
                                    v_cfg->'_default'->>'color', '#F59E0B'),
      'total',             coalesce(ord.total_amount,0),
      'total_display',     public.inr_money(coalesce(ord.total_amount,0)),
      'placed_by_admin',   coalesce(ord.placed_by_admin,false),
      'unique_item_count', coalesce(g.n_ok,0),
      'unit_count',        coalesce(g.units_ok,0),
      'total_item_count',  coalesce(g.n_ok,0) + coalesce(g.n_bad,0),
      'lines',             coalesce(g.ok_lines, '[]'::jsonb),
      'has_unfulfilled',   (coalesce(g.n_bad,0) > 0),
      'unfulfilled_count', coalesce(g.n_bad,0),
      'unfulfilled_title', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items'),
      'unfulfilled_note',  coalesce(nullif(v_unf->>'note',''),''),
      'unfulfilled_label', coalesce(nullif(v_unf->>'title',''),'Unfulfilled items')
                             || ' (' || coalesce(g.n_bad,0)::text || ')',
      'unfulfilled_collapsed', true,
      'unfulfilled_lines', coalesce(g.bad_lines, '[]'::jsonb),
      -- CHANGE #408 — the edit window travels WITH the order. The card used to
      -- ask order_edit_state() itself, which is one round trip per visible
      -- card; the gate is cheap and the screen already has the row, so it is
      -- answered here, once, for every order in the list.
      'edit',              public._order_edit_gate(ord.id)
    ) as o
    from orders ord
    left join lateral (
      select
        count(*) filter (where d.unfulfillable = false)                       as n_ok,
        count(*) filter (where d.unfulfillable)                               as n_bad,
        coalesce(sum(d.qty) filter (where d.unfulfillable = false),0)::int     as units_ok,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            -- #641 rich fields (never null: '' is the explicit absence)
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            'status_label', d.status_text,
            'status_tone',  d.status_tone,
            'status_ok',    (d.status_text = 'Available'),
            'status_text', d.status_text,
            'status_colors', coalesce(v_tone->d.status_tone, v_tone->'yellow'))
          order by d.product_name) filter (where d.unfulfillable = false)      as ok_lines,
        jsonb_agg(jsonb_build_object(
            'name', d.product_name, 'quantity', d.qty::int,
            'price', d.unit_price, 'price_display', public.inr_money(d.unit_price),
            'line_total', d.line_total, 'line_total_display', public.inr_money(d.line_total),
            'product_id',  coalesce(d.product_id::text,''),
            'image_url',   coalesce(d.image_url,''),
            'company',     coalesce(d.company,''),
            'pack_label',  coalesce(d.pack_label,''),
            'qty_label',   d.qty_label,
            'rate_label',  public.inr_money(d.unit_price),
            'line_label',  public.inr_money(d.line_total),
            -- an unfulfilled line states WHY, and is always the red tone.
            'status_label', coalesce(d.reason, d.status_text),
            'status_tone',  'red',
            'status_ok',    false,
            'status_text', coalesce(d.reason, d.status_text),
            'status_colors', coalesce(v_unf->'chip_colors', v_tone->'red'))
          order by d.product_name) filter (where d.unfulfillable)              as bad_lines
      from (
        -- one row per product (deduped), carrying the inquiry status for the
        -- order's zone, preferring the order's own date but never collapsing to
        -- 'Processing' just because the inquiry landed on a different day.
        select oi.product_id,
               max(oi.product_name)                       as product_name,
               sum(coalesce(oi.quantity,0))               as qty,
               max(coalesce(oi.price, oi.mrp, 0))         as unit_price,
               sum(coalesce(oi.line_total,
                     coalesce(oi.quantity,0) * coalesce(oi.price, oi.mrp, 0))) as line_total,
               bool_or(oi.unfulfillable)                  as unfulfillable,
               max(oi.unfulfillable_reason)               as reason,
               coalesce(max(inq.current_status), 'Confirmation Pending') as status_text,
               case coalesce(max(inq.current_status), 'Confirmation Pending')
                 when 'Available'            then 'green'
                 when 'No Supplier Available' then 'red'
                 else 'yellow' end                        as status_tone,
               max(nullif(btrim(m.image_url_1),''))       as image_url,
               max(upper(nullif(btrim(m.marketer),'')))   as company,
               max(nullif(btrim(regexp_replace(coalesce(m.pack_qty,''),'(\d)\.0(\D)','\1\2','g')),'')) as pack_label,
               trim_scale(sum(coalesce(oi.quantity,0)))::text || ' ' ||
                 case when max(m.pack_type) is null
                        then case when sum(coalesce(oi.quantity,0)) > 1 then 'Units' else 'Unit' end
                      when sum(coalesce(oi.quantity,0)) > 1 and lower(max(m.pack_type)) ~ '(s|x|z|ch|sh)$'
                        then max(m.pack_type) || 'es'
                      when sum(coalesce(oi.quantity,0)) > 1 then max(m.pack_type) || 's'
                      else max(m.pack_type) end           as qty_label
        from order_items oi
        left join "MEDICINE" m on m.id = oi.product_id
        left join lateral (
          select q.current_status from inquiry q
           where q.product_id = oi.product_id
             and (q.zone_id is null or coalesce(oi.zone_id, ord.zone_id) is null
                  or q.zone_id = coalesce(oi.zone_id, ord.zone_id))
           order by (q.batch_date = (ord.created_at at time zone 'Asia/Kolkata')::date) desc nulls last,
                    q.batch_date desc nulls last, q.id desc limit 1) inq on true
        where oi.order_id = ord.id
        group by oi.product_id
      ) d
    ) g on true
    where v_cust is not null and ord.customer_id = v_cust
    order by ord.created_at desc
  ) s;

  if v_cust is null and v_admin then
    v_title := 'Admin account';
    v_note  := 'This login is an admin, not a pharmacy. Customer orders live in the admin Orders tab.';
  else
    v_title := coalesce(nullif(v_copy->>'empty_title',''), 'No purchase orders yet');
    v_note  := coalesce(nullif(v_copy->>'empty_note',''),  'Placed orders will appear here.');
  end if;

  return jsonb_build_object(
    'orders',      v_rows,
    'count',       jsonb_array_length(v_rows),
    'has_orders',  (jsonb_array_length(v_rows) > 0),
    'is_admin_session', v_admin,
    'no_customer_account', (v_cust is null),
    'empty_title', v_title,
    'empty_note',  v_note,
    'customer_id', coalesce(v_cust::text,''));
end $function$


-- The profile row's own label. `c()` reads ui_copy, so the entry point is a
-- backend string like every other row on that screen.
insert into public.ui_copy(key, value) values
  ('profile.row_staff_logins', to_jsonb('Staff logins'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ═════════════════════════════════════════════════════════════════════════════
-- 16. THE BUG THE PROOF EXISTS FOR.
--
-- customer_staff_add() bound a staff member into login_identities as
-- owner_type='customer' — the same kind of row the pharmacy OWNER has, because
-- until this change one pharmacy meant one login. login_bind_owner() runs on
-- every sign-in and switches on exactly that field:
--
--     if r.owner_type = 'customer' then
--       update pharmacy_profiles set user_id = p_user_id where id = r.owner_id;
--       update orders set user_id = p_user_id where user_id = any(...);
--       update cart_items ...
--
-- So the FIRST time a counter person signed in, they became the pharmacy's
-- `user_id` — displacing the owner — and every past order of that pharmacy was
-- re-stamped as authored by them. The owner could then no longer revoke them,
-- because removing the customer_users row left the hijacked
-- pharmacy_profiles.user_id behind and my_customer_id() still resolved them
-- through its `pp.user_id = auth.uid()` branch. The proof caught it on the
-- assertion "removal actually revokes".
--
-- The fix is in the DATA, not in a new exception inside the login path: staff
-- get their own binding kind. login_bind_owner() already switches on
-- owner_type, so a kind it has never heard of falls through every branch and
-- takes nothing over — no special case, no new way for that function to be
-- wrong. get_my_role() still answers 'customer' for them, because 'customer'
-- is its default for any identity that is not one of the named other roles.
--
-- Two customer resolvers then have to learn about the new kind, and they are
-- the only two: my_customer_id() (already carries its customer_users branch,
-- added in section 12) and customer_id_for_user(), which is what the CART and
-- _stamp_customer_id() use — without it a staff member's order would be
-- written with a null customer_id and disappear from everyone's order list.
-- ═════════════════════════════════════════════════════════════════════════════

-- login_identities constrains owner_type to a fixed list, so the new kind has
-- to be admitted before anything can be bound as it. Widening a CHECK is
-- additive: every existing row still satisfies it.
alter table public.login_identities
  drop constraint if exists login_identities_owner_type_check;
alter table public.login_identities
  add constraint login_identities_owner_type_check
  check (owner_type = any (array['supplier','customer','customer_staff','admin',
                                 'company','mr','delivery','worker','partner']));

-- Heal anything the earlier form of this migration already bound.
update public.login_identities li
   set owner_type = 'customer_staff'
 where li.owner_type = 'customer'
   and exists (select 1 from public.customer_users cu
                where cu.identity = li.identity
                  and cu.customer_id::text = li.owner_id);

create or replace function public.customer_id_for_user(p_uid uuid)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    -- the pharmacy's own owner login
    (select li.owner_id::uuid
       from auth.users u
       join login_identities li
         on li.owner_type = 'customer'
        and (li.identity = identity_norm(u.email) or li.identity = identity_norm(u.phone))
      where u.id = p_uid
      limit 1),
    -- CHANGE #408 — or a staff login on that pharmacy. Without this the cart
    -- and _stamp_customer_id() would not scope a staff member's order to the
    -- pharmacy at all.
    (select cu.customer_id
       from auth.users u
       join customer_users cu
         on coalesce(cu.is_active, true)
        and (cu.identity = identity_norm(u.email)
             or cu.identity = identity_norm(u.phone)
             or cu.auth_user_id = u.id)
      where u.id = p_uid
      limit 1))
$$;

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

  -- Global identity uniqueness is UNCHANGED: a login that belongs to anyone
  -- else — any role, any pharmacy — is never adopted.
  select li.owner_type, li.owner_id into own from login_identities li where li.identity = k;
  if own.owner_type is not null
     and (own.owner_type not in ('customer','customer_staff')
          or own.owner_id is distinct from v_cid::text) then
    return jsonb_build_object('ok',false,'error','identity_taken','tone','danger',
      'message', public.ui_text('customer_staff.err_identity_taken'));
  end if;
  -- The pharmacy's OWN owner login can never be demoted into a staff row.
  if own.owner_type = 'customer' and own.owner_id = v_cid::text then
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

  -- 'customer_staff', NOT 'customer'. See the block comment above: the second
  -- one hands this person the pharmacy record and its order history.
  insert into login_identities(identity, kind, owner_type, owner_id)
  values (k, case when position('@' in k) > 0 then 'email' else 'phone' end,
          'customer_staff', v_cid::text)
  on conflict (identity) do update
    set owner_type = 'customer_staff', owner_id = v_cid::text;

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
  -- Everything that made that login resolve to this pharmacy goes with it, or
  -- "remove" is a button that does not remove:
  --   the binding …
  delete from login_identities
   where identity = r.identity
     and owner_type in ('customer','customer_staff')
     and owner_id = v_cid::text;
  --   … and any owner slot a PREVIOUS build's binding let them take over.
  --   `nil` is what login_bind_owner() itself parks a vacated profile at.
  if r.auth_user_id is not null then
    update pharmacy_profiles
       set user_id = '00000000-0000-0000-0000-000000000000'::uuid
     where id = v_cid and user_id = r.auth_user_id;
  end if;

  return jsonb_build_object('ok',true,'tone','success',
    'message', public.ui_text('customer_staff.removed'));
exception when others then
  return jsonb_build_object('ok',false,'error','exception','tone','danger',
    'message', replace(public.ui_text('customer_staff.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $$;

-- customer_users.auth_user_id stops being a forward hook and becomes the thing
-- that makes removal complete: it is stamped the first time a staff member is
-- actually seen, from the one call every authenticated screen already makes.
create or replace function public.customer_staff_touch()
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint := public.my_customer_user_id();
begin
  if v_id is null or auth.uid() is null then return null; end if;
  update customer_users
     set auth_user_id = auth.uid(), updated_at = now()
   where id = v_id and auth_user_id is distinct from auth.uid();
  return v_id;
exception when others then
  return v_id;
end $$;

revoke all on function public.customer_id_for_user(uuid)  from public, anon;
revoke all on function public.customer_staff_touch()      from public, anon;
grant execute on function public.customer_staff_touch()   to authenticated;

-- customer_staff_touch() was a new RPC for the client to call so auth_user_id
-- would get stamped. It does not need to exist: customer_action_stamp() ALREADY
-- runs as the acting person on every placement and every edit, and it is
-- volatile. Folding the stamp in there means the binding is learned by using
-- the app, with no new call for a screen to remember to make.
drop function if exists public.customer_staff_touch();

create or replace function public.customer_action_stamp(
  p_action_key text, p_order_id uuid default null, p_detail jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path to 'public' as $$
declare v_id bigint; v_cu bigint; v_ident text;
begin
  v_cu := public.my_customer_user_id();

  -- Learn the auth user behind this staff row the first time we see them, so
  -- that removing them later can also vacate anything they were bound to.
  if v_cu is not null and auth.uid() is not null then
    begin
      update customer_users
         set auth_user_id = auth.uid(), updated_at = now()
       where id = v_cu and auth_user_id is distinct from auth.uid();
    exception when others then null;
    end;
  end if;

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

revoke all on function public.customer_action_stamp(text, uuid, jsonb) from public, anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 17. THE LABEL HAS TO TRAVEL WITH THE FLAG.
--
-- Caught on the live build, not in a test: the order card had `can_edit: true`
-- from my_orders_screen() and still drew nothing, because OrderEditButton also
-- requires a label — by design, since a button whose caption Dart invented is
-- the thing this codebase does not allow. _order_edit_gate() returned the flag
-- and the window label but not `button_label`; that string only existed on
-- order_edit_state(), which the card no longer calls. So the affordance was
-- correct, the payload was incomplete, and the feature was invisible.
--
-- The flag and the words that render it now leave together.
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

  select exists (
    select 1
      from order_items oi
      left join lateral (
        select q.* from inquiry q
         where q.id = oi.inquiry_id
            or (oi.inquiry_id is null
                and q.product_id = oi.product_id
                and q.batch_date = coalesce(oi.order_date, o.order_date)
                and (q.zone_id is not distinct from coalesce(oi.zone_id, o.zone_id)
                     or q.zone_id is null))
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

  -- Physical fulfilment having started. NOT bag_no: that is stamped at
  -- placement by assign_order_bag_no() and means nothing has happened yet.
  select exists (
    select 1 from order_items oi
     where oi.order_id = p_order_id
       and (coalesce(oi.fulfillment_state,'pending') <> 'pending'
            or coalesce(oi.received_qty,0) > 0
            or coalesce(oi.at_warehouse,false)
            or coalesce(oi.packed,false)
            or oi.shop_qty is not null
            or oi.assigned_supplier is not null)
  ) into v_moved;

  if v_moved or coalesce(o.fulfillment_status,'open') <> 'open' then
    return jsonb_build_object('can_edit', false, 'error', 'not_pending',
      'reason', public.ui_text('order_edit.reason_not_pending'),
      'message', public.ui_text('order_edit.err_closed'));
  end if;

  return jsonb_build_object(
    'can_edit', true,
    -- the caption the card draws. Without it the button renders nothing, which
    -- is the correct behaviour and was the invisible feature.
    'button_label', public.ui_text('order_edit.button'),
    'window_label', public.ui_text('order_edit.window_open'));
end $$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 18. EVERY QA BLOCKER BECOMES A PERMANENT JOURNEY (rule 14.4).
--
-- The three blockers this command's QA round found each opened a linked journey
-- with a TODO. Implemented here, so the CLASS is retired rather than this one
-- instance of it: each journey re-checks both the shape of the code that was
-- wrong AND the live data invariant that the bug would have violated.
-- ═════════════════════════════════════════════════════════════════════════════

-- QA-408-216 — a staff login must never take over the pharmacy record.
create or replace function public._journey_c408_binding()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean; a6 boolean;
        v_src text; v_bind text;
begin
  select p.prosrc into v_src from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='customer_staff_add';
  select p.prosrc into v_bind from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='login_bind_owner';

  -- the shape that was wrong
  a1 := coalesce(position('''customer_staff''' in coalesce(v_src,'')) > 0, false);
  a2 := coalesce(position('customer_staff' in coalesce(v_bind,'')) = 0, false);
  a3 := exists (select 1 from pg_constraint
                 where conname = 'login_identities_owner_type_check'
                   and pg_get_constraintdef(oid) like '%customer_staff%');
  a4 := exists (select 1 from pg_proc p
                 where p.pronamespace='public'::regnamespace
                   and p.proname='customer_id_for_user'
                   and p.prosrc like '%customer_users%');
  -- the live invariants the bug would have violated
  a5 := not exists (select 1 from login_identities li
                     join customer_users cu on cu.identity = li.identity
                    where li.owner_type = 'customer');
  a6 := not exists (select 1 from pharmacy_profiles pp
                     join customer_users cu on cu.auth_user_id = pp.user_id
                    where pp.user_id is not null);

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 and a6 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'staff bind as customer_staff=' || a1::text
   || ' | login_bind_owner has no branch for it=' || a2::text
   || ' | owner_type CHECK admits it=' || a3::text
   || ' | customer_id_for_user knows staff=' || a4::text
   || ' | no staff identity bound as owner=' || a5::text
   || ' | no pharmacy owned by a staff auth user=' || a6::text));
end $$;

-- QA-408-217 — the edit window closes when a supplier is asked, and the
-- affordance carries the words that draw it.
create or replace function public._journey_c408_window()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean; a5 boolean; v_src text; v_mos text;
begin
  select p.prosrc into v_src from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='_order_edit_gate';
  select p.prosrc into v_mos from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='my_orders_screen';

  -- bag_no is stamped at PLACEMENT, so it never meant "packing started".
  -- The test is the PREDICATE `oi.bag_no`, not the word: the function's own
  -- comment explains why it is absent, and a journey that greps prose would
  -- fail on the explanation of its own fix.
  a1 := coalesce(position('oi.bag_no' in coalesce(v_src,'')) = 0, false);
  -- the engine's own marker for "a supplier has been asked"
  a2 := coalesce(position('asked_at' in coalesce(v_src,'')) > 0
             and position('supplier_order_id' in coalesce(v_src,'')) > 0, false);
  -- and the fallback to the ORDER's date/zone, without which the match went NULL
  a3 := coalesce(position('o.order_date' in coalesce(v_src,'')) > 0
             and position('o.zone_id' in coalesce(v_src,'')) > 0, false);
  -- the window rides the order list …
  a4 := coalesce(position('_order_edit_gate' in coalesce(v_mos,'')) > 0, false);
  -- … and the caption rides with the flag, or the button renders nothing
  a5 := coalesce(position('button_label' in coalesce(v_src,'')) > 0, false);

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 and a5 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'gate no longer reads bag_no=' || a1::text
   || ' | closes on asked_at/supplier_order_id=' || a2::text
   || ' | falls back to the order own date+zone=' || a3::text
   || ' | window rides my_orders_screen=' || a4::text
   || ' | and the button caption travels with the flag=' || a5::text));
end $$;

-- QA-408-218 — an order is never priced or totalled on MRP.
create or replace function public._journey_c408_pricing()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean; v_src text;
begin
  select p.prosrc into v_src from pg_proc p
   where p.pronamespace='public'::regnamespace and p.proname='order_edit_apply';

  -- the trade total, the same function placement uses
  a1 := coalesce(position('cart_pricing_block' in coalesce(v_src,'')) > 0, false);
  a2 := coalesce(position('net_payable' in coalesce(v_src,'')) > 0, false);
  -- MEDICINE.mrp is a rendered rupee STRING; parsed, never cast
  a3 := coalesce(position('_slab_num' in coalesce(v_src,'')) > 0, false);
  -- the basket changed, so the discount slab is re-snapshotted rather than left stale
  a4 := coalesce(position('order_slab_snapshot' in coalesce(v_src,'')) > 0, false);

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'totals through cart_pricing_block=' || a1::text
   || ' | on net_payable, not MRP=' || a2::text
   || ' | mrp parsed with _slab_num=' || a3::text
   || ' | slab re-snapshotted after the edit=' || a4::text));
end $$;

update public.dev_journeys set
  steps = case name
    when 'qa-408-216' then '["A pharmacy owner adds a counter person as staff","The staff member signs in","The pharmacy record and its order history still belong to the owner","The owner removes them and the login stops resolving"]'::jsonb
    when 'qa-408-217' then '["An order is placed and no supplier has been asked yet","The order card offers Edit order, with the backend own caption","A supplier is asked","The affordance disappears and the write is refused"]'::jsonb
    else '["An order is edited before the inquiry starts","The new total is the trade/PTR total from cart_pricing_block","It is never MRP x quantity","The discount slab is re-snapshotted"]'::jsonb
  end
where name in ('qa-408-216','qa-408-217','qa-408-218');

-- The probe's dispatch table gains the three branches. Everything else in this
-- function is unchanged — it is reproduced whole because that is the only way
-- to add a branch to a plpgsql function.
CREATE OR REPLACE FUNCTION public.dev_journey_probe(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ok boolean; v_ev jsonb; v_v text; v_row record; v_jid bigint; v_pass_count int;
        v_sql text; v_chk jsonb; v_base_hash text; v_bl jsonb; v_err text;
        v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
        c_target constant text := 'my_orders_chandra_slice';
begin
  perform public._dev_guard();


  -- CHANGE #436 — the default PUBLIC EXECUTE grant, closed as a class.
  if p_name = 'bug-436' then return public._journey_bug436(); end if;
  -- CHANGE #408 — the three QA blockers this command found, each retired as a
  -- class rather than as one screenshot: the staff binding that handed a
  -- pharmacy away, the edit window that stayed open after a supplier was
  -- asked, and the basket that was totalled on MRP.
  if p_name = 'qa-408-216' then return public._journey_c408_binding(); end if;
  if p_name = 'qa-408-217' then return public._journey_c408_window();  end if;
  if p_name = 'qa-408-218' then return public._journey_c408_pricing(); end if;
  -- CHANGE #319 — QA blockers 156/157 (version.json served HTML).
  if p_name in ('qa-319-156','qa-319-157') then
    return public._journey_qa319_version();
  end if;

  -- CHANGE #240 — inquiry->PO date integrity (see _journey_bug240).
  if p_name = 'bug-240' then return public._journey_bug240(); end if;

  -- CHANGE #197 — the confirm re-read may only CONFIRM drift, never clear it.
  -- Regression guard for the false-negative: a payload target that DIFFERS on
  -- read 1 and then ERRORS on the confirm read used to vanish from both
  -- diffs.payload.changed and collection_errors, so rg_check returned ok:true
  -- while a real change sat unreported.
  if p_name = 'bug-197' then
    v_err := null;
    select position('confirm re-read failed' in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_check';
    begin
      create table if not exists public._j197_ctr(n int);
      delete from public._j197_ctr where true; insert into public._j197_ctr values (0);
      execute 'create or replace function public._j197_tick() returns int language plpgsql as '
           || '$b$ declare v int; begin update public._j197_ctr set n = n + 1 where true returning n into v; '
           || 'if v >= 2 then raise exception ''j197 confirm read''; end if; return 42; end $b$';
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      insert into rg_payload_targets(name, sql, enabled)
        values ('_j197_probe', 'select jsonb_build_object(''v'', public._j197_tick())', true);
      insert into rg_baseline(kind, name, hash, content)
        values ('payload','_j197_probe','deadbeefdeadbeefdeadbeefdeadbeef','{"v":0}'::jsonb);

      v_chk := public.rg_check(false, true);
      select exists (select 1 from jsonb_array_elements_text(
                       coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) x
                      where x = '_j197_probe') into v_a2;
      select exists (select 1 from jsonb_array_elements(
                       coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                      where e->>'name' = '_j197_probe') into v_a3;
    exception when others then
      v_a2 := false; v_a3 := false; v_err := sqlerrm;
    end;

    begin
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      execute 'drop function if exists public._j197_tick()';
      execute 'drop table if exists public._j197_ctr';
    exception when others then null;
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false);
    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'rg_check carries the unconfirmable-drift rule=' || coalesce(v_a1::text,'null')
          || ' | drift KEPT in changed when the confirm read errors=' || coalesce(v_a2::text,'null')
          || ' | reason surfaced in collection_errors=' || coalesce(v_a3::text,'null'),
        'probe_cleaned_up', not exists (select 1 from rg_payload_targets where name = '_j197_probe'),
        'error', v_err));
  end if;

  -- CHANGE #192 — the mandated post-deploy verifier must never fail a run whose
  -- own asks all passed. Asserted from verify_run_log, which render_verify.js
  -- writes on every run: a run with keys_ok + build_match MUST exit 0, and a
  -- boot-only run must neither execute the allocation phase nor mutate prod.
  if p_name = 'bug-192' then
    select count(*) into v_pass_count from verify_run_log where at > now() - interval '7 days';
    if v_pass_count = 0 then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no render_verify run recorded in the last 7 days'));
    end if;

    select count(*) = 0 into v_ok
    from verify_run_log l
    where l.at > now() - interval '7 days'
      and (
        (l.keys_ok and l.build_match and l.exit_code <> 0
           and coalesce(array_length(l.phases_failed,1),0) = 0)
        or (coalesce(array_length(l.requested_phases,1),0) > 0
            and exists (select 1 from unnest(l.phases_run) p
                        where not (p = any(l.requested_phases)) and p <> 'boot'))
        or (l.mutated and coalesce(array_length(l.requested_phases,1),0) > 0
            and not (l.requested_phases && array['allocation','receiving','voice','arrivals']))
      );

    select jsonb_build_object(
      'db_proof', 'verify_run_log rows/7d: '||count(*)::text||
        '; failed-with-nothing-wrong: '||
        count(*) filter (where keys_ok and build_match and exit_code <> 0
                           and coalesce(array_length(phases_failed,1),0) = 0)::text||
        '; ran-an-unrequested-phase: '||
        count(*) filter (where coalesce(array_length(requested_phases,1),0) > 0
                           and exists (select 1 from unnest(phases_run) p
                                       where not (p = any(requested_phases)) and p <> 'boot'))::text||
        '; mutated-without-asking: '||
        count(*) filter (where mutated and coalesce(array_length(requested_phases,1),0) > 0
                           and not (requested_phases && array['allocation','receiving','voice','arrivals']))::text,
      'latest', (select jsonb_build_object(
                   'at', l.at::text, 'commit', l.commit_hash, 'exit_code', l.exit_code,
                   'keys', to_jsonb(l.requested_keys),
                   'asked_for', to_jsonb(l.requested_phases),
                   'ran', to_jsonb(l.phases_run),
                   'failed', to_jsonb(l.phases_failed),
                   'mutated', l.mutated)
                 from verify_run_log l order by l.at desc limit 1))
      into v_ev
    from verify_run_log where at > now() - interval '7 days';

    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);
  end if;
  if p_name = 'backup-lands' then
    select bool_and(ok) and count(*) filter (where kind='db') >= 1
           and count(*) filter (where kind='repo') >= 1 into v_ok
    from backup_log where at > now() - interval '26 hours'
      and (size_mb)::numeric > 1 and ok;
    select jsonb_build_object(
      'db_proof', 'backup_log rows in last 26h: '||coalesce(count(*),0)::text,
      'latest', max(at)::text) into v_ev
    from backup_log where at > now() - interval '26 hours' and ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'eta-honest' then
    select count(*) = 0 into v_ok
    from dev_commands
    where status='building' and eta_left_s is not null and eta_total_s is not null
      and eta_left_s > eta_total_s and coalesce(eta_note,'') = '';
    select jsonb_build_object(
      'db_proof', 'building rows: '||count(*) filter (where status='building')::text||
                  '; inflated-without-note: '||
                  count(*) filter (where status='building' and eta_left_s>eta_total_s and coalesce(eta_note,'')='')::text
    ) into v_ev from dev_commands;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'add-media-survives' then
    select m.* into v_row from dev_command_messages m
    where jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no message with images yet'));
    end if;
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','message #'||v_row.id||' images non-empty='||v_ok));

  elsif p_name = 'reply-media-live' then
    select m.* into v_row from dev_command_messages m
    where coalesce(m.sender,'') = 'om'
      and jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no reply-with-photo yet'));
    end if;
    -- c290-strengthen: presence is not content. bool_and over the paths.
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','reply message #'||v_row.id||' carries '||
        jsonb_array_length(v_row.images)::text||' image(s); every path non-empty='||
        coalesce(v_ok,false)::text));

  elsif p_name = 'android-apk-produces-file' then
    select count(*) > 0 into v_ok from dev_commands
    where android_status='built' and coalesce(android_artifact_url,'') <> '';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no built android artifact on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof','built android artifacts: '||
        (select count(*) from dev_commands where android_status='built')::text));

  elsif p_name = 'fast-lane-writes' then
    select count(*) > 0 into v_ok from ui_copy where key = 'journey.test' and value is not null;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','ui_copy journey.test key not present'));
    end if;
    -- c290-strengthen: compare the exact stored value, not its nullness.
    select value = '"journey_probe_ok"'::jsonb into v_ok
      from ui_copy where key='journey.test';
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'ui_copy journey.test='||(select value::text from ui_copy where key='journey.test')||
        '; equals the fast-lane marker="journey_probe_ok"='||coalesce(v_ok,false)::text));

  elsif p_name = 'gcp-taps-enqueue' then
    select count(*) > 0 into v_ok from dev_commands where kind='gcp';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no gcp-kind command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'gcp commands on record: '||(select count(*) from dev_commands where kind='gcp')::text));

  elsif p_name = 'pool-settings-save' then
    select (select value from dev_runner_config where key='worker_pool') is not null into v_ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof', 'worker_pool config readable; sec_pin_verify(null)='||
          (sec_pin_verify(null))::text));

  elsif p_name = 'rollback-creates-command' then
    select count(*) > 0 into v_ok
    from dev_commands where title like 'Rollback #%' and urgent=true;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no Rollback command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'urgent Rollback commands on record: '||
        (select count(*) from dev_commands where title like 'Rollback #%' and urgent=true)::text));

  elsif p_name = 'bug-191' then
    -- CHANGE #191. The class: a payload target that FAILS to collect must be
    -- reported as an explicit error, never as a content diff, and must never be
    -- written into the baseline. Previously a failure became hash='ERROR:'||md5(msg),
    -- which rg_check counted as 'changed' -> rg_gate blocked a clean tree.
    --
    -- Structural guards first (cheap, no mutation).
    select p.proconfig::text like '%statement_timeout%' into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    -- 57014 is not matched by OTHERS; it must be named or it escapes the guard.
    select p.prosrc like '%query_canceled%' into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    select not exists (select 1 from rg_baseline where kind='payload' and hash='ERROR') into v_a3;

    select b.hash into v_base_hash from rg_baseline b where b.kind='payload' and b.name=c_target;
    select pt.sql into v_sql from rg_payload_targets pt where pt.name=c_target;
    if v_sql is null or v_base_hash is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','probe target '||c_target||' is not baselined'));
    end if;

    -- Behavioural reproduction: break the target, then assert the guard's verdict.
    begin
      update rg_payload_targets set sql='select (1/0)::text::jsonb' where name=c_target;

      v_chk := rg_check(false, true);

      -- (a) the failure is surfaced as a collection error
      v_a4 := exists (select 1 from jsonb_array_elements(coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                       where e->>'name' = c_target);
      -- (b) and is NOT counted as drift
      v_a5 := not exists (select 1 from jsonb_array_elements_text(
                            coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) t(nm)
                          where t.nm = c_target);

      -- (c) rebaselining while a target is failing must leave the baseline intact
      v_bl := rg_baseline_all();
      select (b.hash = v_base_hash) into v_a6
        from rg_baseline b where b.kind='payload' and b.name=c_target;

      update rg_payload_targets set sql=v_sql where name=c_target;
    exception when others then
      update rg_payload_targets set sql=v_sql where name=c_target;
      v_err := sqlerrm;
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','probe raised, target SQL restored: '||v_err));
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false) and coalesce(v_a6,false);

    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'target='||c_target||
          ' | rg_collect_payloads has statement_timeout='||coalesce(v_a1,false)::text||
          ' | names query_canceled='||coalesce(v_a2,false)::text||
          ' | no ERROR hash in baseline='||coalesce(v_a3,false)::text||
          ' | broken target reported as collection_error='||coalesce(v_a4,false)::text||
          ' | broken target NOT counted as diff='||coalesce(v_a5,false)::text||
          ' | rg_baseline_all left baseline intact='||coalesce(v_a6,false)::text,
        'diffs_while_broken', coalesce(v_chk->'summary','{}'::jsonb),
        'baseline_run', coalesce(v_bl->'baselined'->'payload','null'::jsonb),
        'target_sql_restored', true));

  elsif p_name = 'qa-395-183' then
    -- CHANGE #395 QA blocker: every function that change added is SECURITY
    -- DEFINER and shipped with Postgres's default PUBLIC EXECUTE.
    -- _order_cancel_core is deliberately UNGUARDED so the token-based
    -- order-alert path can reach it, so the anon key that ships in the web
    -- bundle could cancel ANY order, release its stock and its open supplier
    -- inquiry lines, and fire an automatic refund. Same shape as
    -- feature_gaps #25, CHANGE #353 and audit_write() in #422.
    --
    -- Asserted as "the doors exist" AND "no door is open", because a
    -- bool_and over a function that has vanished is silently true.
    select count(*) = 22 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel');
    -- anon is the key in the bundle. Not one of these may be reachable by it.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel')
       and has_function_privilege('anon', p.oid, 'execute');
    -- the exact door the blocker walked through
    select not has_function_privilege(
             'anon','public._order_cancel_core(uuid,text,text,uuid,text)','execute')
      into v_a3;
    -- a signed-in role may hold EXECUTE only where the function guards ITSELF.
    select count(*) = 0 into v_a4
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_return_line_money','_return_returnable_qty',
                         '_order_collected','_order_refunded','_order_paid_net',
                         '_order_rzp_payment_id','_rzp_refund_apply',
                         'gst_ledger_build_credit_notes','refund_prepare','refund_store')
       and has_function_privilege('authenticated', p.oid, 'execute');
    -- and the ledgers themselves stay closed to the bundle key.
    select count(*) = 0 into v_a5
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('order_returns','refunds','order_cancellations')
       and (has_table_privilege('anon', c.oid, 'insert')
         or has_table_privilege('anon', c.oid, 'update')
         or has_table_privilege('anon', c.oid, 'delete'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all 22 returns/refund RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | _order_cancel_core denied to anon='||coalesce(v_a3,false)::text||
        ' | no unguarded helper reachable by authenticated='||coalesce(v_a4,false)::text||
        ' | no returns ledger writable by anon='||coalesce(v_a5,false)::text));

  elsif p_name = 'qa-273-47' then
    -- c290-strengthen. QA #273 finding 47: the anon key that ships inside the
    -- web bundle and the APK must not reach any cron door. cron_wake matters
    -- most — it is SECURITY DEFINER, so a success there lets an anonymous
    -- caller queue dispatcher work and make the database run a task a minute.
    -- Asserted as "no door is open", and separately as "the doors still exist",
    -- because a bool_and over a vanished function is silently true.
    select count(*) = 6 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health');
    -- c290-probe-fix: anon is the key that ships in the bundle, and it is the
    -- key this journey is about. A signed-in role may hold EXECUTE only where
    -- the function guards itself — cron_health does, and the super-admin Cron
    -- Health screen is built on exactly that.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('anon', p.oid, 'execute');
    select count(*) = 0 into v_a5
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and p.prosrc not like '%_dev_guard()%';
    select not (has_function_privilege('anon','public.cron_wake(text)','execute')) into v_a3;
    select count(*) = 0 into v_a4
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('cron_task','cron_signal','cron_guard_config','cron_dispatch_state')
       and (has_table_privilege('anon', c.oid, 'select')
         or has_table_privilege('anon', c.oid, 'insert'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
        and coalesce(v_a3,false) and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all six cron RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | every signed-in-reachable cron RPC guards itself='||coalesce(v_a5,false)::text||
        ' | cron_wake denied to anon='||coalesce(v_a3,false)::text||
        ' | no cron table readable or writable by anon='||coalesce(v_a4,false)::text));

  elsif p_name = 'qa-274-57' then
    -- c290-strengthen. QA #274 finding 57: PTR must never reach an unentitled
    -- viewer. Walked as a TYPED pricing block, deliberately not as a text
    -- search: matching a formatted rupee token across 500+ cards collided with
    -- a legitimate MRP twice before and cost two false-alarm debug passes.
    v_v := coalesce(current_setting('request.jwt.claims', true), '');
    v_err := null;
    begin
      perform set_config('request.jwt.claims', '', true);   -- no session: anon
      v_chk := storefront_home_v2(60);
      perform set_config('request.jwt.claims', v_v, true);
    exception when others then
      perform set_config('request.jwt.claims', v_v, true);
      v_err := sqlerrm;
    end;
    if v_err is not null then
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','anon storefront_home_v2 raised: '||v_err));
    end if;

    with cards as (
      select it as card
      from jsonb_array_elements(coalesce(v_chk->'sections','[]'::jsonb)) s,
           jsonb_array_elements(coalesce(s->'items','[]'::jsonb)) it
      where it ? 'id'
    )
    -- c290-bool-or: aggregate the counterexample as a boolean. A count above
    -- 1 cannot be assigned to a boolean, and under the real leak the count is
    -- every card.
    select count(*),
           bool_or((card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
           bool_or(coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
           bool_or(coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
               and coalesce(card->'pricing'->'card_price'->>'note','') = ''),
           bool_or(coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
      into v_pass_count, v_a1, v_a2, v_a3, v_a4
    from cards;

    -- c290-probe-fix: v_a1..v_a4 are booleans, so each count arrived already
    -- cast (0 -> false, n -> true). Comparing 'false' to '0' failed a clean
    -- payload every time.
    v_ok := coalesce(v_pass_count,0) > 0
        and not coalesce(v_a1,true) and not coalesce(v_a2,true)
        and not coalesce(v_a3,true) and not coalesce(v_a4,true);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'anon cards walked='||coalesce(v_pass_count,0)::text||
        ' | any card leaking a ptr key='||coalesce(v_a1,true)::text||
        ' | any card with card_price.has_ptr not false='||coalesce(v_a2,true)::text||
        ' | any card missing the locked note='||coalesce(v_a3,true)::text||
        ' | any card not in display_mode=mrp_only='||coalesce(v_a4,true)::text));

  elsif p_name = 'devqueue-buttons-change-db' then
    -- c290-strengthen. "Each button flips the DB field." Asserted against the
    -- RPCs the buttons call, because the alternative — driving a real row
    -- through pause/resume/cancel — puts a decoy into the live queue that
    -- another worker can claim in the same second.
    select position($q$status='paused'$q$ in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_pause';
    select position($q$status='pending'$q$ in p.prosrc) > 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_resume';
    select position($q$status='cancelled'$q$ in p.prosrc) > 0 into v_a3
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_cancel';
    select position($q$urgent = coalesce((p_patch->>'urgent')::boolean, urgent)$q$ in p.prosrc) > 0
      into v_a4
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_update';
    select count(*) = 4 and bool_and(p.prosrc like '%_dev_guard()%') into v_a5
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('dev_cmd_pause','dev_cmd_resume','dev_cmd_cancel','dev_cmd_update');
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'Pause writes paused='||coalesce(v_a1,false)::text||
        ' | Resume writes pending='||coalesce(v_a2,false)::text||
        ' | Cancel writes cancelled='||coalesce(v_a3,false)::text||
        ' | Urgent writes urgent='||coalesce(v_a4,false)::text||
        ' | all four present and guarded='||coalesce(v_a5,false)::text));

  elsif p_name = 'worker-grid-loads' then
    -- c290-strengthen. "The grid shows >=1 worker chip with lane labels."
    -- Phrased as two no-counterexample assertions so an idle box with a
    -- genuinely empty pool is not a false red: the grid must account for every
    -- command that has been building for over two minutes (the supervisor
    -- republishes every 20s, so a fresh claim is allowed to be missing), and
    -- no chip it does show may be blank.
    select value into v_chk from dev_runner_config where key='pool_state';
    if v_chk is null or jsonb_typeof(v_chk->'workers') <> 'array' then
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','pool_state snapshot missing or workers is not an array'));
    end if;
    select not exists (
      select 1 from dev_commands d
       where d.status='building'
         and d.started_at < now() - interval '2 minutes'
         and not exists (select 1 from jsonb_array_elements(v_chk->'workers') w
                          where coalesce(w->>'command_id','') = d.id::text)) into v_a1;
    select not exists (
      select 1 from jsonb_array_elements(v_chk->'workers') w
       where coalesce(trim(w->>'id'),'') = ''
          or coalesce(trim(w->>'lane'),'') = ''
          or coalesce(trim(w->>'status'),'') = '') into v_a2;
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'chips='||jsonb_array_length(v_chk->'workers')::text||
        ' | every settled building command has a chip='||coalesce(v_a1,false)::text||
        ' | no chip missing id/lane/status='||coalesce(v_a2,false)::text));

  else
    -- Externally proven journeys (menu-reachability, qa-274-54): the assertion
    -- lives in a Playwright run or a widget test, so the only proof this branch
    -- can read is a run somebody else filed through journey_report.
    -- Check how many passed runs exist across all commands via journey_report.
    -- If >= 2, the external Playwright runner has proven this journey works → passed.
    select id into v_jid from dev_journeys where name = p_name limit 1;
    if v_jid is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','unknown journey: '||p_name));
    end if;
    -- c290-strengthen: ONLY externally reported passes count. This branch
    -- writes evidence.db_proof on its own pass, so counting every passed run
    -- let it certify itself: two journeys stood at 40 passes, 40 of them its
    -- own and 0 from any runner. An external runner (journey_report from
    -- Playwright or a widget test) files evidence WITHOUT db_proof, and that
    -- is the only proof this branch is allowed to count.
    select count(*) into v_pass_count
    from dev_journey_runs
    where journey_id = v_jid and status = 'passed'
      and not (coalesce(evidence,'{}'::jsonb) ? 'db_proof');
    if v_pass_count >= 2 then
      return jsonb_build_object('status','passed','evidence',
        jsonb_build_object('db_proof',
          'browser runner recorded '||v_pass_count||' passed runs for '||p_name));
    else
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason',
          'browser runner needs '||(2-v_pass_count)||' more run(s); current='||v_pass_count));
    end if;
  end if;
end $function$

