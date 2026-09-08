-- CHANGE #668 (live proof round) — the login must land on the SEEDED shop.
--
-- 20260905170500 gave test.cust1@medibo.in its own pharmacy and filled it: five
-- shelf lots, an expiring batch, a return window and two khata accounts. On the
-- build branch every screen read them. On LIVE the same login read an EMPTY
-- shop — render-log on CHANGE #1146: c412_stock_home=1 with c412_stock_rows=0,
-- no refusal in sight, which is the worst shape a gap can take: it looks like a
-- working feature with nothing in it.
--
-- The cause is CHANGE #536's fixture, which is still on live and predates this
-- command: it bound test.cust1 as STAFF (customer_users.auth_user_id) on the
-- OLDEST synthetic pharmacy, 'TST TEST PHARMACY - SYNTHETIC (DO NOT USE)'.
-- my_customer_id() honours the owner path AND the staff path and then does
--   order by pp.id limit 1
-- so with two matching synthetic shops the winner is whichever uuid sorts
-- lower. It was the #536 one — the empty one. Nothing was wrong with the seed;
-- the resolver was answering a different question.
--
-- The fix re-points that binding at the shop this command seeds rather than
-- deleting it: the staff-login path #536 exists to exercise stays exercised,
-- both resolution paths name the SAME pharmacy, and uuid ordering stops being
-- load-bearing. It lives inside test_customer_shop_ensure() so the nightly
-- cron_task repairs it after any test_purge(), exactly like the shelf.
--
-- Idempotent: re-applying is a no-op, and the function is create-or-replace.

create or replace function public.test_customer_shop_ensure()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c668$
declare
  v_email text := 'test.cust1@medibo.in';
  v_ident text := public.identity_norm('test.cust1@medibo.in');
  v_name  text := 'TST CUSTOMER TEST SHOP - SYNTHETIC (DO NOT USE)';
  v_seed  text := 'SYNTHETIC SEED (#668)';
  v_uid   uuid;
  v_ph    uuid;
  v_zone  smallint := public._test_zone();
  -- access_key is FK'd to customer_access_preset, and a database that has not
  -- been seeded with the presets has none: read the widest ACTIVE one instead
  -- of hardcoding 'full', and skip creating a staff row when there is none.
  v_ak    text := (select cap.access_key from public.customer_access_preset cap
                    where coalesce(cap.is_active, true)
                    order by cap.rank desc nulls last limit 1);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_lots  int := 0;
  v_kh    int := 0;
  r       record;
begin
  if not public._test_guard() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  select u.id into v_uid from auth.users u
   where lower(u.email) = v_email
   order by u.created_at
   limit 1;
  if v_uid is null then
    -- Not a failure of this migration: the auth user is created in the
    -- dashboard, not in SQL. Say so and change nothing.
    return jsonb_build_object('ok', false, 'error', 'no_auth_user', 'email', v_email);
  end if;

  -- ── the shop ───────────────────────────────────────────────────
  select p.id into v_ph
    from public.pharmacy_profiles p
   where p.is_synthetic and p.pharmacy_name = v_name
   limit 1;

  -- _login_identities_sync raises identity_taken if this email is mapped to a
  -- different owner. Clear a stale mapping first; it is this account's own.
  delete from public.login_identities li
   where li.identity = v_ident
     and not (li.owner_type = 'customer' and li.owner_id = coalesce(v_ph::text, '-'));

  if v_ph is null then
    insert into public.pharmacy_profiles
      (user_id, pharmacy_name, customer_name, owner_name,
       phone, whatsapp_no, email,
       address, address_local, city, district, state, pincode,
       approved, status, zone_id, store_type, payment_term,
       is_synthetic, test_session_id)
    values
      (v_uid, v_name, v_name, 'TEST OWNER (SYNTHETIC)',
       '9000000668', '9000000668', v_email,
       'Synthetic Test Lane, Shop 668', 'Synthetic Test Lane',
       'Raipur', 'Raipur', 'Chhattisgarh', '492001',
       true, 'approved', v_zone, 'retail', 'credit',
       true, null)
    returning id into v_ph;
  else
    update public.pharmacy_profiles
       set user_id      = v_uid,
           email        = v_email,
           customer_name= v_name,
           address      = 'Synthetic Test Lane, Shop 668',
           city         = 'Raipur',
           state        = 'Chhattisgarh',
           pincode      = '492001',
           approved     = true,
           status       = 'approved',
           zone_id      = coalesce(zone_id, v_zone),
           is_deleted   = false,
           latitude     = null,
           longitude    = null,
           is_synthetic = true
     where id = v_ph;
  end if;

  -- ── the login that must land on THIS shop ──────────────────────
  -- See the header: #536's staff binding pointed at the older, empty synthetic
  -- pharmacy and won my_customer_id()'s `order by pp.id limit 1`. Re-point it,
  -- never delete it, and make sure no OTHER binding for this login survives to
  -- reintroduce the tie.
  update public.customer_users cu
     set customer_id  = v_ph,
         auth_user_id = v_uid,
         is_active    = true,
         updated_at   = now()
   where (cu.auth_user_id = v_uid
          or lower(coalesce(cu.identity,'')) = v_email
          or cu.identity = v_ident)
     and cu.customer_id is distinct from v_ph;

  if v_ak is not null
     and not exists (select 1 from public.customer_users cu
                      where cu.customer_id = v_ph and cu.auth_user_id = v_uid) then
    insert into public.customer_users
      (customer_id, identity, display_name, access_key, auth_user_id,
       is_active, created_by)
    values
      (v_ph, v_email, 'mediBO test pharmacy login', v_ak, v_uid,
       true, 'CHANGE #668')
    on conflict (identity) do update
       set customer_id  = excluded.customer_id,
           auth_user_id = excluded.auth_user_id,
           access_key   = excluded.access_key,
           is_active    = true;
  end if;


  -- ── the return window the expiry screen reads ──────────────────
  -- _c413_window() returns NO ROW when nothing matches, and a cross join
  -- lateral on no row drops every line: without this the expiry screen is
  -- empty for reasons that have nothing to do with the shelf.
  insert into public.pharmacy_return_window
    (pharmacy_id, supplier_key, supplier_name, opens_days, closes_days, note)
  values (v_ph, '*', null, 180, 90, 'synthetic seed (#668)')
  on conflict (pharmacy_id, supplier_key) where pharmacy_id is not null
  do update set opens_days = excluded.opens_days,
                closes_days = excluded.closes_days;

  -- ── the shelf ──────────────────────────────────────────────────
  -- days_to_expiry is re-derived on every call, so a lot cannot age out of
  -- the window and silently take the badge with it.
  --   C668-A at +100d  -> return window OPEN, closes in 10 days  -> badge
  --   C668-B at  +45d  -> the expiring batch the buckets are drawn from
  --   the rest are ordinary shelf, one of them deliberately low.
  for r in
    select * from (values
      ('Paracetamol 650 Tablet',   '10 tablets',    'C668-A', 100, 40::numeric,  8.20::numeric, 12.50::numeric),
      ('Amoxycillin 500 Capsule',  '10 capsules',   'C668-B',  45, 12::numeric, 46.00::numeric, 68.00::numeric),
      ('Pantoprazole 40 Tablet',   '15 tablets',    'C668-C', 420, 60::numeric, 21.40::numeric, 32.00::numeric),
      ('ORS Orange Powder',        '21.8 g sachet', 'C668-D', 300, 25::numeric, 14.00::numeric, 21.00::numeric),
      ('Cetirizine 10 Tablet',     '10 tablets',    'C668-E', 560,  4::numeric,  6.10::numeric,  9.50::numeric)
    ) as t(nm, pk, batch, days, qty, cost, mrp)
  loop
    update public.pharmacy_stock s
       set expiry     = to_char(v_today + r.days, 'MM/YYYY'),
           expiry_on  = v_today + r.days,
           qty        = r.qty,
           unit_cost  = r.cost,
           mrp        = r.mrp,
           updated_at = now()
     where s.pharmacy_id = v_ph and s.batch_no = r.batch;
    if not found then
      insert into public.pharmacy_stock
        (pharmacy_id, medicine_id, product_name, pack_label, item_key,
         batch_no, expiry, expiry_on, qty, unit_cost, mrp,
         source_kind, supplier_label, received_on, is_synthetic, test_session_id)
      values
        (v_ph, null, r.nm, r.pk, 'n:' || public._norm_name(r.nm),
         r.batch, to_char(v_today + r.days, 'MM/YYYY'), v_today + r.days,
         r.qty, r.cost, r.mrp,
         'opening', v_seed, v_today - 20, true, null);
    end if;
    v_lots := v_lots + 1;
  end loop;

  -- ── the khata book ─────────────────────────────────────────────
  for r in
    select * from (values
      ('patient', 'TEST KHATA PATIENT (SYNTHETIC)', '9000000661', 1250.00::numeric, 5000::numeric, 12),
      ('doctor',  'TEST KHATA DOCTOR (SYNTHETIC)',  '9000000662',  640.00::numeric, 3000::numeric, 31)
    ) as t(kind, nm, phone, bal, lim, due_days)
  loop
    insert into public.khata_account
      (pharmacy_id, kind, name, phone, balance, limit_amount, note,
       oldest_due_on, last_entry_at, is_active, is_synthetic, test_session_id)
    values
      (v_ph, r.kind, r.nm, r.phone, r.bal, r.lim, 'synthetic seed (#668)',
       v_today - r.due_days, now(), true, true, null)
    on conflict (pharmacy_id, phone) where phone is not null
    do update set balance       = excluded.balance,
                  limit_amount  = excluded.limit_amount,
                  oldest_due_on = excluded.oldest_due_on,
                  is_active     = true,
                  is_synthetic  = true,
                  updated_at    = now();
    v_kh := v_kh + 1;
  end loop;

  return jsonb_build_object(
    'ok', true, 'pharmacy_id', v_ph, 'user_id', v_uid, 'zone_id', v_zone,
    'lots', v_lots, 'khata_accounts', v_kh, 'email', v_email,
    -- The whole point of the follow-up: say which shop the login resolves to,
    -- so a nightly run that silently drifts back is readable in cron history.
    'login_shop', (select cu.customer_id from public.customer_users cu
                    where cu.auth_user_id = v_uid limit 1));
end
$c668$;

-- A new function is EXECUTE-able by PUBLIC until it is revoked, and this one
-- writes. Only the control plane calls it.
revoke all on function public.test_customer_shop_ensure() from public;
revoke all on function public.test_customer_shop_ensure() from anon;
revoke all on function public.test_customer_shop_ensure() from authenticated;
grant execute on function public.test_customer_shop_ensure() to service_role;

-- ── APP-SCHEMA WORK, and only where the app schema lives ─────────────────
-- CHANGE #1802 replays every migration file on the CONTROL PLANE (medibo-dev)
-- as well as production, and medibo-dev is a dev-queue clone: it carries
-- dev_commands, deploy_queue and cron_task but NOT the storefront schema. An
-- earlier copy of this file ran its seed unguarded there and died on
--   ERROR: function public.identity_norm(unknown) does not exist
-- which failed the whole batch AFTER production had already taken the file.
-- So everything below is fenced behind one sentinel, and a control plane that
-- an unguarded copy already wrote a cron row into is cleaned up rather than
-- left with a task pointing at a function it does not have.
do $c668app$
declare v jsonb;
begin
  if to_regprocedure('public.identity_norm(text)') is null
     or to_regclass('public.pharmacy_profiles') is null then
    if to_regclass('public.cron_task') is not null then
      delete from public.cron_task where name = 'c668_test_customer_shop';
    end if;
    raise notice 'c668: app schema absent here (control plane) — nothing to seed';
    return;
  end if;

  -- Nightly by default, so a test_purge() that empties the synthetic shelf
  -- repairs itself instead of quietly retiring the proof. One dispatcher, one
  -- offset minute — never a bare */N (the connection-exhaustion outage was 35
  -- jobs on minute 0). run_at_ist is deliberately NOT in the update list:
  -- 20260905210000 turns this into a poll task and a replay of this file must
  -- not drag it back to a daily pin.
  insert into public.cron_task
    (name, ord, mode, work_sql, run_at_ist, dml, enabled, note, step_timeout_ms)
  values
    ('c668_test_customer_shop', 640, 'poll',
     'select public.test_customer_shop_ensure()',
     '03:17', true, true,
     'CHANGE #668 — keeps test.cust1 shop, shelf, expiry window and khata alive',
     20000)
  on conflict (name) do update
    set work_sql = excluded.work_sql,
        dml      = excluded.dml,
        enabled  = true,
        note     = excluded.note;

  -- Run it now, on this deploy.
  v := public.test_customer_shop_ensure();
  raise notice 'c668 seed: %', v;
end
$c668app$;
