-- CHANGE #668 — test.cust1@medibo.in gets a real shop.
--
-- CLAUDE.md names test.cust1@medibo.in as THE customer-side credential, but the
-- account had no pharmacy_profiles row: my_customer_id() returned null, so
-- pos_home(), pharmacy_stock_home(), pharmacy_expiry_home() and khata_home()
-- all answered with their refusal. #536 proved the deep links route; nothing
-- could prove a pharmacy feature WORKS through the login the rules mandate
-- (live render-log on CHANGE #979: c411_pos_denied=1, c412_stock_denied=1).
--
-- The shop is is_synthetic, which the sibling migration
-- 20260905170000_c668_hide_synthetic_from_real_surfaces.sql keeps off every
-- discovery surface, and which _synthetic_outbound_gate already keeps off
-- WhatsApp. It carries no latitude/longitude on purpose: a shop with no pin
-- cannot be drawn on a map even by a surface nobody has audited yet.
--
-- The seed is a FUNCTION, not a one-shot INSERT, for one reason: test_purge()
-- deletes `pharmacy_stock where is_synthetic`, so a routine test run would
-- quietly empty the shelf this command exists to fill. The function re-dates
-- its own lots on every call and a nightly cron_task calls it, so the proof
-- stays true tomorrow instead of only on the day it was taken.

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
    'lots', v_lots, 'khata_accounts', v_kh, 'email', v_email);
end
$c668$;

-- A new function is EXECUTE-able by PUBLIC until it is revoked, and this one
-- writes. Only the control plane calls it.
revoke all on function public.test_customer_shop_ensure() from public;
revoke all on function public.test_customer_shop_ensure() from anon;
revoke all on function public.test_customer_shop_ensure() from authenticated;
grant execute on function public.test_customer_shop_ensure() to service_role;

-- Nightly, so a test_purge() that empties the synthetic shelf repairs itself
-- instead of quietly retiring the proof. One dispatcher, one offset minute —
-- never a bare */N (the connection-exhaustion outage was 35 jobs on minute 0).
insert into public.cron_task
  (name, ord, mode, work_sql, run_at_ist, dml, enabled, note, step_timeout_ms)
values
  ('c668_test_customer_shop', 640, 'poll',
   'select public.test_customer_shop_ensure()',
   '03:17', true, true,
   'CHANGE #668 — keeps test.cust1 shop, shelf, expiry window and khata alive',
   20000)
on conflict (name) do update
  set work_sql   = excluded.work_sql,
      run_at_ist = excluded.run_at_ist,
      dml        = excluded.dml,
      enabled    = true,
      note       = excluded.note;

-- Run it now, on this deploy.
do $c668run$
declare v jsonb;
begin
  v := public.test_customer_shop_ensure();
  raise notice 'c668 seed: %', v;
end
$c668run$;
