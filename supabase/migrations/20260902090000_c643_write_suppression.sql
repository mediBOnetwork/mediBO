-- CHANGE #643 (1/5) — stop the self-generated rewrite loop.
--
-- Facts that produced this migration (2026-09-02, zero customers online):
--   pharmacy_profiles : 10 live rows,  45,550 UPDATEs  (4,555 rewrites per row)
--   orders            : 34 live rows,  22,267 UPDATEs  (655 rewrites per row)
--   my_session()      : 16,096 calls, 14,872 s total exec time
-- Every one of those UPDATEs is a WAL record that Realtime decodes and
-- broadcasts to every subscriber of the table — 95.9% of the 7.44M realtime
-- messages in the last cycle were postgres_changes we generated ourselves.
--
-- The writer: my_session() -> my_session_core() -> login_sync_current_user()
-- -> login_bind_owner(). login_bind_owner ran SEVEN unconditional "clear the
-- binding" UPDATEs plus one "set the binding" UPDATE on EVERY call, so a plain
-- session read rewrote the caller's pharmacy_profiles row twice (clear, then
-- set it straight back). With several logins per pharmacy it was worse than
-- redundant: `update orders set user_id = <me>` moved every order of that
-- pharmacy to whichever login polled last, and the other login moved them all
-- back on its next poll — a permanent ping-pong across all 34 rows.
--
-- Three fixes, in order of how much they cover:
--   1. login_binding_is_current() — an early exit so a correct binding writes
--      nothing at all (the common case: every session poll of every user).
--   2. every UPDATE in login_bind_owner is conditional (IS DISTINCT FROM /
--      an exclusion of the row we are about to bind), and the orders/cart
--      migration only runs when this call actually re-bound something.
--   3. suppress_redundant_updates_trigger() on EVERY table in the
--      supabase_realtime publication, so ANY no-op UPDATE from anywhere —
--      today's writer or tomorrow's — produces no new row version, no WAL
--      record and therefore no realtime event.
-- (3) is the permanent guard; (1) and (2) are the specific bug.

-- ---------------------------------------------------------------------------
-- 1. Is the login binding already what login_bind_owner would make it?
-- ---------------------------------------------------------------------------
create or replace function public.login_binding_is_current(
  p_identity text, p_user_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare r record;
        nil uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_user_id is null or p_identity is null then return false; end if;
  select owner_type, owner_id into r from login_identities where identity = p_identity;
  if not found then return false; end if;

  -- the owner row this identity should hold
  if r.owner_type = 'customer' then
    if not exists (select 1 from pharmacy_profiles
                    where id::text = r.owner_id and user_id = p_user_id) then return false; end if;
  elsif r.owner_type = 'supplier' then
    if not exists (select 1 from supplier_profiles
                    where id::text = r.owner_id and user_id = p_user_id) then return false; end if;
  elsif r.owner_type = 'worker' then
    if not exists (select 1 from lead_workers
                    where id::text = r.owner_id and user_id = p_user_id) then return false; end if;
  elsif r.owner_type = 'mr' then
    if not exists (select 1 from mr_registrations
                    where id::text = r.owner_id and user_id = p_user_id) then return false; end if;
  elsif r.owner_type = 'delivery' then
    if not exists (select 1 from delivery_partner_registrations
                    where id::text = r.owner_id and user_id = p_user_id) then return false; end if;
  elsif r.owner_type = 'company' then
    if not exists (select 1 from company_profiles
                    where id::text = r.owner_id and user_id = p_user_id) then return false; end if;
  elsif r.owner_type = 'partner' then
    if not exists (select 1 from partner_users
                    where id::text = r.owner_id and auth_user_id = p_user_id) then return false; end if;
  else
    return false;
  end if;

  -- and NO other row anywhere still holds this auth user
  if exists (select 1 from pharmacy_profiles
              where user_id = p_user_id
                and not (r.owner_type = 'customer' and id::text = r.owner_id)) then return false; end if;
  if exists (select 1 from supplier_profiles
              where user_id = p_user_id
                and not (r.owner_type = 'supplier' and id::text = r.owner_id)) then return false; end if;
  if exists (select 1 from lead_workers
              where user_id = p_user_id
                and not (r.owner_type = 'worker' and id::text = r.owner_id)) then return false; end if;
  if exists (select 1 from mr_registrations
              where user_id = p_user_id
                and not (r.owner_type = 'mr' and id::text = r.owner_id)) then return false; end if;
  if exists (select 1 from delivery_partner_registrations
              where user_id = p_user_id
                and not (r.owner_type = 'delivery' and id::text = r.owner_id)) then return false; end if;
  if exists (select 1 from company_profiles
              where user_id = p_user_id
                and not (r.owner_type = 'company' and id::text = r.owner_id)) then return false; end if;
  if exists (select 1 from partner_users
              where auth_user_id = p_user_id
                and not (r.owner_type = 'partner' and id::text = r.owner_id)) then return false; end if;

  return true;
end $$;

grant execute on function public.login_binding_is_current(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. login_bind_owner — same contract, every write conditional
-- ---------------------------------------------------------------------------
create or replace function public.login_bind_owner(p_identity text, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r record; v_uids uuid[]; v_orders int := 0; v_cart int := 0;
        n int := 0; v_changed int := 0;
        nil uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_user_id is null then return jsonb_build_object('ok',false,'message','no user'); end if;
  select owner_type, owner_id into r from login_identities where identity = p_identity;
  if not found then return jsonb_build_object('ok',false,'message','no owner'); end if;

  -- CHANGE #643: clear this auth user off every OTHER owner row. The row we
  -- are about to bind is excluded, so the old clear-then-set-it-straight-back
  -- pair (two WAL records and two realtime broadcasts per session poll) is
  -- now zero writes when the binding is already correct.
  update pharmacy_profiles set user_id = nil
   where user_id = p_user_id
     and not (r.owner_type = 'customer' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update supplier_profiles set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'supplier' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update lead_workers set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'worker' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update mr_registrations set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'mr' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update delivery_partner_registrations set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'delivery' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update company_profiles set user_id = null
   where user_id = p_user_id
     and not (r.owner_type = 'company' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  update partner_users set auth_user_id = null
   where auth_user_id = p_user_id
     and not (r.owner_type = 'partner' and id::text = r.owner_id);
  get diagnostics n = row_count; v_changed := v_changed + n;

  -- …and bind the one that should hold it, only if it does not already.
  if    r.owner_type = 'customer' then
    update pharmacy_profiles set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'supplier' then
    update supplier_profiles set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'worker' then
    update lead_workers set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'mr' then
    update mr_registrations set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'delivery' then
    update delivery_partner_registrations set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'company' then
    update company_profiles set user_id = p_user_id
     where id::text = r.owner_id and user_id is distinct from p_user_id;
  elsif r.owner_type = 'partner' then
    update partner_users set auth_user_id = p_user_id, updated_at = now()
     where id::text = r.owner_id and auth_user_id is distinct from p_user_id;
  end if;
  get diagnostics n = row_count; v_changed := v_changed + n;

  -- CHANGE #643: the order/cart migration runs ONLY on a real re-bind.
  -- It used to run on every call, so with two logins on one pharmacy each
  -- session poll dragged all 34 orders to whoever polled last and the other
  -- login dragged them straight back — the single biggest source of orders
  -- realtime traffic. A binding that did not change moves nothing.
  if r.owner_type = 'customer' and v_changed > 0 then
    v_uids := public.owner_auth_user_ids(r.owner_type, r.owner_id);
    update orders o set user_id = p_user_id
     where o.user_id = any (v_uids) and o.user_id <> p_user_id;
    get diagnostics v_orders = row_count;
    delete from cart_items c
     where c.user_id = any (v_uids) and c.user_id <> p_user_id
       and exists (select 1 from cart_items k
                    where k.user_id = p_user_id and k.product_id = c.product_id);
    update cart_items c set user_id = p_user_id
     where c.user_id = any (v_uids) and c.user_id <> p_user_id;
    get diagnostics v_cart = row_count;
  end if;

  return jsonb_build_object('ok',true,'owner_type',r.owner_type,'owner_id',r.owner_id,
                            'orders_moved',v_orders,'cart_moved',v_cart,
                            'rows_changed',v_changed);
end $$;

-- ---------------------------------------------------------------------------
-- 3. login_sync_current_user — a session READ must not write
-- ---------------------------------------------------------------------------
create or replace function public.login_sync_current_user()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_ident text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false); end if;

  select li.identity into v_ident
  from login_identities li
  where li.identity = any (public.my_identity_keys())
  order by case li.owner_type
             when 'admin' then 1 when 'partner' then 2 when 'supplier' then 3
             when 'customer' then 4 when 'company' then 5 when 'mr' then 6 else 7 end, li.id
  limit 1;

  if v_ident is null then return jsonb_build_object('ok',false); end if;

  -- CHANGE #643: my_session() calls this on every poll. When the binding is
  -- already correct there is nothing to heal, so take the read-only exit.
  if public.login_binding_is_current(v_ident, auth.uid()) then
    return jsonb_build_object('ok',true,'noop',true);
  end if;

  return public.login_bind_owner(v_ident, auth.uid());
end $$;

-- ---------------------------------------------------------------------------
-- 4. recompute_order_fulfillment — do not rewrite an unchanged status
-- ---------------------------------------------------------------------------
create or replace function public.recompute_order_fulfillment(p_order_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  n_total int; n_pending int; n_in_transit int; n_problem int;
  n_shipped int; n_cancelled int;
  v_status text; v_closed timestamptz;
BEGIN
  SELECT closed_at, fulfillment_status INTO v_closed, v_status FROM orders WHERE id = p_order_id;
  IF v_closed IS NOT NULL THEN RETURN v_status; END IF;

  SELECT
    count(*),
    count(*) FILTER (WHERE fulfillment_state = 'pending'),
    count(*) FILTER (WHERE fulfillment_state IN ('received','short') AND at_warehouse = false),
    count(*) FILTER (WHERE fulfillment_state IN ('wrong','not_coming')),
    count(*) FILTER (WHERE fulfillment_state = 'shipped'),
    count(*) FILTER (WHERE fulfillment_state = 'cancelled')
  INTO n_total, n_pending, n_in_transit, n_problem, n_shipped, n_cancelled
  FROM order_items WHERE order_id = p_order_id;

  IF n_total = 0 THEN
    v_status := 'open';
  ELSIF n_shipped = n_total THEN
    v_status := 'shipped';
  ELSIF n_shipped > 0 THEN
    v_status := 'partially_shipped';
  ELSIF n_cancelled = n_total THEN
    v_status := 'cancelled';
  ELSIF n_pending > 0 THEN
    IF n_pending = n_total THEN v_status := 'open'; ELSE v_status := 'collecting'; END IF;
  ELSIF n_in_transit > 0 THEN
    v_status := 'in_transit';
  ELSE
    IF n_problem > 0 THEN v_status := 'partial_ready'; ELSE v_status := 'ready'; END IF;
  END IF;

  -- CHANGE #643: conditional. This is called from the order_items triggers, so
  -- an unconditional write turned every item edit into an orders broadcast too.
  UPDATE orders SET fulfillment_status = v_status
   WHERE id = p_order_id AND fulfillment_status IS DISTINCT FROM v_status;
  RETURN v_status;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. suppress_redundant_updates_trigger on every published table
-- ---------------------------------------------------------------------------
-- The permanent guard. Postgres' own BEFORE-UPDATE trigger compares the new row
-- to the old one and skips the write when they are byte-identical: no new row
-- version, no WAL record, no realtime event, no dead tuple for autovacuum.
-- Named zzz_* so it fires AFTER every other BEFORE trigger has finished
-- shaping NEW — comparing a half-built NEW would suppress the wrong things.
create or replace function public.realtime_suppress_noop_install()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare t record; n int := 0;
begin
  for t in
    select schemaname, tablename
    from pg_publication_tables
    where pubname = 'supabase_realtime'
  loop
    if not exists (
      select 1 from pg_trigger tg
      join pg_class c on c.oid = tg.tgrelid
      join pg_namespace ns on ns.oid = c.relnamespace
      where ns.nspname = t.schemaname and c.relname = t.tablename
        and tg.tgname = 'zzz_c643_suppress_noop'
    ) then
      execute format(
        'create trigger zzz_c643_suppress_noop before update on %I.%I '
        'for each row execute function suppress_redundant_updates_trigger()',
        t.schemaname, t.tablename);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

grant execute on function public.realtime_suppress_noop_install() to service_role;

select public.realtime_suppress_noop_install();
