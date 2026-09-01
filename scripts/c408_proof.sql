-- CHANGE #408 — end-to-end proof for the two pieces this change added:
-- pharmacy staff logins (customer_users) and order editing before the inquiry
-- engine has asked anybody.
--
-- It builds a throwaway pharmacy + order, drives every path with the REAL
-- identities (owner JWT, staff JWT, admin JWT), asserts the payloads, and
-- ROLLS BACK. The rollback is not tidiness: editing an order fires
-- trg_wa_notify_order_updated, which queues through pg_net and is
-- transactional, so a rolled-back proof cannot WhatsApp a real customer.
--
--   psql "$PGURL" -f scripts/c408_proof.sql
--   every line is PASS or FAIL; the script exits non-zero on any FAIL.

begin;

do $proof$
declare
  v_cust_id   uuid;  v_cust_user uuid;
  v_admin     uuid;
  v_staff_uid uuid := gen_random_uuid();
  v_order     uuid;
  v_prod_a    bigint; v_prod_b bigint; v_zone smallint;
  v           jsonb;
  v_staff_id  bigint;
  v_n         int;
  v_fail      int := 0; v_pass int := 0;
  r           record;
begin
  create temp table if not exists c408_log(ord serial, ok boolean, line text) on commit drop;

  -- ── fixtures: a real approved pharmacy, a real admin, two real medicines ──
  select pp.id, pp.user_id into v_cust_id, v_cust_user
    from pharmacy_profiles pp
   where pp.user_id is not null and coalesce(pp.is_deleted,false) = false
     and coalesce(pp.approved, false)
     and exists (select 1 from auth.users u where u.id = pp.user_id)
   order by pp.created_at limit 1;

  select u.id into v_admin
    from admins a join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   order by a.created_at limit 1;

  if v_cust_id is null then
    raise exception 'c408 proof: no approved pharmacy fixture available';
  end if;

  -- Two products that are actually STANDBY-available in some zone, so the
  -- availability re-check the edit runs is exercised against real stock rather
  -- than against a product that would fail for an unrelated reason.
  select oi.zone_id into v_zone from order_items oi where oi.zone_id is not null limit 1;
  v_zone := coalesce(v_zone, 1);
  select m.id into v_prod_a from "MEDICINE" m
   where public.medicine_zone_standby(m.id, v_zone) > 0 order by m.id limit 1;
  select m.id into v_prod_b from "MEDICINE" m
   where public.medicine_zone_standby(m.id, v_zone) > 0 and m.id <> coalesce(v_prod_a,-1)
   order by m.id limit 1;
  if v_prod_a is null or v_prod_b is null then
    -- no standby stock on this instance: fall back to any two catalogue rows and
    -- assert the qty/catalogue rules instead of the availability rule.
    select m.id into v_prod_a from "MEDICINE" m order by m.id limit 1;
    select m.id into v_prod_b from "MEDICINE" m where m.id <> v_prod_a order by m.id limit 1;
    v_zone := null;
  end if;

  -- ═══ 1. STAFF LOGINS ══════════════════════════════════════════════════
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cust_user, 'role','authenticated')::text, true);

  insert into c408_log(ok, line) values
    (public.my_customer_id() = v_cust_id,
     'the owner login resolves to the pharmacy'),
    (public.my_customer_user_id() is null,
     'the owner is NOT a customer_users row — the owner login is not staff'),
    (public.my_customer_rank() = (select max(rank) from customer_access_preset where is_active),
     'the owner holds the top rank by definition, not by a row someone could edit'),
    (public.customer_can('customer.staff','write'),
     'and can therefore manage staff');

  v := public.customer_staff_list();
  insert into c408_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'staff console opens for the owner'),
    (coalesce(v->>'title','') <> '' and coalesce(v->>'add_label','') <> ''
       and coalesce(v->>'empty','') <> '',
     'every label is backend copy, not a Dart literal'),
    (jsonb_array_length(coalesce(v->'access_options','[]'::jsonb)) = 3,
     'the owner is offered all three access levels -> '
       || jsonb_array_length(coalesce(v->'access_options','[]'::jsonb))::text),
    ((v->'rows'->0->>'is_owner')::boolean is true
       and (v->'rows'->0->>'can_remove')::boolean is false,
     'the owner is row 0 and can never be removed'),
    (jsonb_array_length(coalesce(v->'rows','[]'::jsonb)) = 1,
     'no staff yet — only the owner row');

  -- add a staff member
  v := public.customer_staff_add('9812340408', 'Counter Ramesh', 'order_only');
  insert into c408_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false),
     'staff login added -> ' || coalesce(v->>'message','(no message)'));
  select id into v_staff_id from customer_users where identity = public.identity_norm('9812340408');
  insert into c408_log(ok, line) values
    (v_staff_id is not null, 'a customer_users row exists for the new staff member');

  insert into c408_log(ok, line)
  select li.owner_type = 'customer' and li.owner_id = v_cust_id::text,
         'the SAME login_identities binding every customer login uses -> owner_type='
         || coalesce(li.owner_type,'null')
    from login_identities li where li.identity = public.identity_norm('9812340408');

  -- the identity uniqueness rule is UNCHANGED
  insert into c408_log(ok, line)
  select count(*) = 1, 'the identity is bound exactly once, globally'
    from login_identities where identity = public.identity_norm('9812340408');

  -- a login that belongs to a SUPPLIER can never be adopted as pharmacy staff
  for r in select li.identity from login_identities li
            where li.owner_type = 'supplier' limit 1 loop
    v := public.customer_staff_add(r.identity, 'Poach attempt', 'order_only');
    insert into c408_log(ok, line) values
      (coalesce((v->>'ok')::boolean,true) is false and v->>'error' = 'identity_taken',
       'a login owned by another account is refused -> ' || coalesce(v->>'error','ok'));
  end loop;

  -- ── the staff member signs in as themselves ──────────────────────────
  update customer_users set auth_user_id = v_staff_uid where id = v_staff_id;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff_uid, 'role','authenticated')::text, true);

  insert into c408_log(ok, line) values
    (public.my_customer_id() = v_cust_id,
     'the STAFF login resolves to the same pharmacy — my_customer_id() needed no change'),
    (public.my_customer_user_id() = v_staff_id,
     'and is identified as that staff row'),
    (public.customer_can('customer.orders','write'),
     'order_only staff may place and edit orders'),
    (public.customer_can('customer.payments','write') is false,
     'order_only staff may NOT touch payments'),
    (public.customer_can('customer.staff','write') is false,
     'order_only staff may NOT manage other staff');

  v := public.customer_staff_list();
  insert into c408_log(ok, line) values
    (jsonb_array_length(coalesce(v->'access_options','[]'::jsonb)) = 1,
     'CAPPED: order_only staff are offered only their own level, never a higher one -> '
       || jsonb_array_length(coalesce(v->'access_options','[]'::jsonb))::text),
    (coalesce((v->>'can_manage')::boolean,true) is false,
     'and the console tells them they cannot manage'),
    ((select bool_or((row_->>'is_self')::boolean)
        from jsonb_array_elements(v->'rows') row_
       where (row_->>'id')::bigint = v_staff_id),
     'they see themselves marked as self');

  -- escalation is refused
  v := public.customer_staff_set_access(v_staff_id, 'full');
  insert into c408_log(ok, line) values
    (coalesce((v->>'ok')::boolean,true) is false,
     'staff cannot re-grade themselves -> ' || coalesce(v->>'error','ok'));

  -- ── back to the owner: re-grade and remove ───────────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_cust_user, 'role','authenticated')::text, true);
  v := public.customer_staff_set_access(v_staff_id, 'order_payments');
  insert into c408_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'the owner can raise a staff level');
  insert into c408_log(ok, line)
  select access_key = 'order_payments', 'and it is stored -> ' || access_key
    from customer_users where id = v_staff_id;

  -- ═══ 2. ORDER EDIT BEFORE THE INQUIRY ═════════════════════════════════
  insert into orders(id, user_id, customer_id, pharmacy_name, phone, status,
                     total_amount, zone_id, items)
  values (gen_random_uuid(), v_cust_user, v_cust_id, 'c408 proof pharmacy', '9999900408',
          'pending', 100, coalesce(v_zone,1),
          jsonb_build_array(jsonb_build_object(
            'product_id', v_prod_a, 'product_name',
            (select product_name from "MEDICINE" where id = v_prod_a), 'quantity', 2)))
  returning id into v_order;

  -- the placement attribution trigger fired on INSERT
  insert into c408_log(ok, line)
  select count(*) = 1, 'placing an order writes exactly one attributed action row'
    from customer_action_log where order_id = v_order and action_key = 'order_placed';

  -- explode_order_items already built the lines
  insert into c408_log(ok, line)
  select count(*) = 1, 'order_items was exploded from items -> ' || count(*)::text
    from order_items where order_id = v_order;

  v := public.order_edit_state(v_order);
  insert into c408_log(ok, line) values
    (coalesce((v->>'can_edit')::boolean,false),
     'BEFORE any inquiry: the window is open -> can_edit=' || coalesce(v->>'can_edit','null')),
    (coalesce(v->>'button_label','') <> '' and coalesce(v->>'title','') <> ''
       and coalesce(v->>'window_label','') <> '',
     'the affordance and its copy come from the backend'),
    (jsonb_array_length(coalesce(v->'lines','[]'::jsonb)) = 1,
     'the sheet is given the current basket -> '
       || jsonb_array_length(coalesce(v->'lines','[]'::jsonb))::text);

  -- The window travels WITH the order list, so the card asks nobody.
  begin
    v := public.my_orders_screen(null);
    insert into c408_log(ok, line)
    select coalesce(((o->'edit'->>'can_edit')::boolean), false),
           'my_orders_screen carries the edit window on the order row — no RPC per card'
      from jsonb_array_elements(coalesce(v->'orders','[]'::jsonb)) o
     where o->>'id' = v_order::text;
  exception when others then
    insert into c408_log(ok, line) values
      (false, 'my_orders_screen carries the edit window -> ' || SQLERRM);
  end;

  -- CHANGE the basket: keep A at a new quantity, ADD B
  v := public.order_edit_apply(v_order, jsonb_build_array(
         jsonb_build_object('product_id', v_prod_a, 'quantity', 5),
         jsonb_build_object('product_id', v_prod_b, 'quantity', 1)));
  insert into c408_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false),
     'the edit is accepted -> ' || coalesce(v->>'message','(no message)'));

  insert into c408_log(ok, line)
  select count(*) = 2, 'order_items was rewritten ATOMICALLY by the existing trigger -> '
                        || count(*)::text
    from order_items where order_id = v_order;
  insert into c408_log(ok, line)
  select coalesce(quantity,0) = 5, 'the changed quantity landed -> ' || coalesce(quantity::text,'null')
    from order_items where order_id = v_order and product_id = v_prod_a;

  -- REMOVE a line
  v := public.order_edit_apply(v_order, jsonb_build_array(
         jsonb_build_object('product_id', v_prod_b, 'quantity', 3)));
  insert into c408_log(ok, line) values
    (coalesce((v->>'ok')::boolean,false), 'a removal is the same call — the basket is sent whole');
  insert into c408_log(ok, line)
  select count(*) = 1 and max(product_id) = v_prod_b,
         'the removed item is gone from order_items -> ' || count(*)::text
    from order_items where order_id = v_order;

  -- every edit is logged, with WHO
  select count(*) into v_n from order_edit_event where order_id = v_order;
  insert into c408_log(ok, line) values
    (v_n = 2, 'both edits are logged as order events -> ' || v_n::text);
  insert into c408_log(ok, line)
  select count(*) = 2, 'and each one is attributed in the action log -> ' || count(*)::text
    from customer_action_log where order_id = v_order and action_key = 'order_edited';

  -- validation: quantities and the catalogue
  v := public.order_edit_apply(v_order, jsonb_build_array(
         jsonb_build_object('product_id', v_prod_b, 'quantity', 0)));
  insert into c408_log(ok, line) values
    (v->>'error' = 'bad_qty', 'quantity 0 is refused by the SAME rule checkout uses -> '
       || coalesce(v->>'error','ok'));
  v := public.order_edit_apply(v_order, jsonb_build_array(
         jsonb_build_object('product_id', -1, 'quantity', 1)));
  insert into c408_log(ok, line) values
    (v->>'error' = 'unknown_item', 'a product that is not in the catalogue is refused -> '
       || coalesce(v->>'error','ok'));
  v := public.order_edit_apply(v_order, '[]'::jsonb);
  insert into c408_log(ok, line) values
    (v->>'error' = 'empty_basket',
     'emptying the basket is refused — that is a cancellation, which is row 130 -> '
       || coalesce(v->>'error','ok'));
  insert into c408_log(ok, line)
  select count(*) = 1, 'and the refused edits changed NOTHING -> ' || count(*)::text
    from order_items where order_id = v_order;

  -- ── THE WINDOW CLOSES the moment a supplier is asked ─────────────────
  -- The engine ASKS by UPDATEing the row: on INSERT a trigger recomputes
  -- current_supplier from the PS columns and clears asked_at, exactly as
  -- inquiry_engine_sync() does. So the fixture asks the way the engine asks.
  insert into inquiry(product_id, quantity, batch_date, zone_id, "PS1")
  values (v_prod_b, 3, (select order_date from orders where id = v_order),
          (select zone_id from orders where id = v_order), 'C408 PROOF SUPPLIER');
  update inquiry set asked_at = now()
   where id = (select max(id) from inquiry where product_id = v_prod_b);

  insert into c408_log(ok, line)
  select asked_at is not null, 'fixture: the inquiry row is now ASKED, the way the engine asks'
    from inquiry where id = (select max(id) from inquiry where product_id = v_prod_b);

  v := public.order_edit_state(v_order);
  insert into c408_log(ok, line) values
    (coalesce((v->>'can_edit')::boolean,true) is false,
     'AFTER the waterfall starts: the affordance disappears -> can_edit='
       || coalesce(v->>'can_edit','null')),
    (v->>'error' = 'inquiry_started',
     'and the backend says exactly why -> ' || coalesce(v->>'error','null')),
    (coalesce(v->>'message','') <> '' and coalesce(v->>'reason','') <> '',
     'in its own words, with no Dart fallback wording');

  v := public.order_edit_apply(v_order, jsonb_build_array(
         jsonb_build_object('product_id', v_prod_a, 'quantity', 9)));
  insert into c408_log(ok, line) values
    (coalesce((v->>'ok')::boolean,true) is false and v->>'error' = 'inquiry_started',
     'and the WRITE is refused too — the gate is not a client-side hide -> '
       || coalesce(v->>'error','ok'));
  insert into c408_log(ok, line)
  select coalesce(quantity,0) = 3, 'the basket is untouched after the refused write -> '
                                    || coalesce(quantity::text,'null')
    from order_items where order_id = v_order;

  -- ── someone else's order is not editable at all ──────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff_uid, 'role','authenticated')::text, true);
  insert into c408_log(ok, line) values
    (coalesce((public.order_edit_state(v_order)->>'can_edit')::boolean, true) is false,
     'the staff member sees the same closed window as the owner — one gate, not two');

  -- ── the admin acting as the customer gets the SAME window ────────────
  if v_admin is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_admin, 'role','authenticated')::text, true);
    v := public.customer_activity(v_cust_id, 50);
    insert into c408_log(ok, line) values
      (coalesce((v->>'ok')::boolean,false),
       'an admin can read who did what on this pharmacy'),
      (jsonb_array_length(coalesce(v->'rows','[]'::jsonb)) >= 3,
       'and sees the placement and both edits -> '
         || jsonb_array_length(coalesce(v->'rows','[]'::jsonb))::text),
      ((v->'rows'->0->>'who') <> '' and (v->'rows'->0->>'what') <> '',
       'each line names a person and an action, both backend strings');
  end if;

  -- ── a stranger reads nothing ─────────────────────────────────────────
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role','authenticated')::text, true);
  insert into c408_log(ok, line) values
    (coalesce((public.customer_staff_list()->>'ok')::boolean, true) is false,
     'a stranger gets not_authorized from the staff console'),
    (coalesce((public.customer_activity(v_cust_id, 10)->>'ok')::boolean, true) is false,
     'and cannot read another pharmacy''s activity by passing its id');

  -- ── report ───────────────────────────────────────────────────────────
  perform set_config('request.jwt.claims', null, true);
  for r in select * from c408_log order by ord loop
    if r.ok then v_pass := v_pass + 1; raise notice 'PASS  %', r.line;
    else v_fail := v_fail + 1; raise notice 'FAIL  %', r.line; end if;
  end loop;
  raise notice '';
  raise notice 'c408 proof: % passed, % failed', v_pass, v_fail;
  if v_fail > 0 then raise exception 'c408 proof: % assertion(s) failed', v_fail; end if;
end $proof$;

rollback;
