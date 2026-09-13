-- CMD #1851 — THE LIVE-CHAIN CAST for a build branch.
--
-- branch_sync_schema() restores the SCHEMA and nothing else, and
-- branch_sync_config.sh then copies live's CONFIG rows. What is still missing
-- after both is the handful of ROWS the "live chain" journeys walk:
-- qa-274-57 needs anon storefront cards, qa-697-feedback needs a CLOSED order
-- owned by an approved pharmacy, qa-698-substitute needs a zone-stocked
-- substitutable pool plus one narrow-therapeutic molecule to refuse.
--
-- Lesson 302 repaired all of this by hand on #1851, #1896, #1903 and #1895.
-- This file is that repair, idempotent, so the fifth command does not.
--
-- SYNTHESISED, never copied: no live customer, order or supplier is read.
-- Run it with session_replication_role=replica — sync_marketer_to_company()
-- and the zone-master triggers abort the load otherwise.
--
-- Safe to re-run. NEVER run it against production: every row it writes is
-- marked is_synthetic and named "... - SYNTHETIC (DO NOT USE)".
begin;
set local session_replication_role = replica;

-- ── 1. THREE SUPPLIERS, synthesised from names of our own making ────────────
insert into public.supplier_profiles (id, supplier_name, status, approved,
       is_deleted, created_at, margin_points, cd_points, behaviour_points,
       ordered_medicine_points, payment_term_points, is_synthetic)
-- status must read 'active': compute_current_supplier_fx() canonicalises a PS
-- slot through supplier_profiles WHERE status ILIKE 'active', so a supplier in
-- any other state leaves inquiry.current_supplier null and the whole substitute
-- waterfall reports zero demand.
-- is_synthetic stays FALSE: _synthetic_party_guard refuses to let a real
-- inquiry name a synthetic supplier, and the substitute waterfall the journey
-- walks raises real inquiries. The names carry the warning instead.
select gen_random_uuid(), n, 'active', true, false, now(), 0, 0, 0, 0, 0, false
  from unnest(array['TST SUPPLIER A - SYNTHETIC (DO NOT USE)',
                    'TST SUPPLIER B - SYNTHETIC (DO NOT USE)',
                    'TST SUPPLIER C - SYNTHETIC (DO NOT USE)']) n
 where not exists (select 1 from public.supplier_profiles s where s.supplier_name = n);

-- ── 2. A CATALOGUE THAT PASSES THE FEED FILTER ──────────────────────────────
-- refresh_storefront_feed() keeps a row only when it is buyable, carries a
-- real image_url_1 and a numeric mrp; the fixture rows carry none of the three.
update public."MEDICINE"
   set buyable      = true,
       image_url_1  = coalesce(nullif(btrim(coalesce(image_url_1,'')),''),
                               'https://medibo.in/icons/Icon-192.png'),
       mrp          = coalesce(nullif(btrim(coalesce(mrp,'')),''), '100'),
       sales_count  = coalesce(sales_count, 10),
       z_rpr_sup    = array['TST SUPPLIER A - SYNTHETIC (DO NOT USE)',
                            'TST SUPPLIER B - SYNTHETIC (DO NOT USE)'],
       z_rpr_av     = '{}'::text[],
       z_rpr_oos    = '{}'::text[],
       z_rpr_nostock= '{}'::text[],
       supplier_count = 2,
       -- substitute_candidates() keeps a same-salt row only when its pack_type
       -- matches and its MARKETER differs. The fixture rows share one marketer
       -- (and no pack type at all), so the same-salt shelf was always empty and
       -- qa-698's "an ordinary product is allowed" could never be true.
       pack_type    = 'strip',
       pack_qty     = coalesce(nullif(btrim(coalesce(pack_qty,'')),''), '10'),
       marketer     = 'TST MARKETER ' || (id % 4)::text || ' - SYNTHETIC (DO NOT USE)'
 where id in (select id from public."MEDICINE" order by id limit 60);

-- ── 3. ONE NARROW-THERAPEUTIC MOLECULE, so the refusal has something to refuse
-- The restore leaves "MEDICINE"'s identity sequence behind the rows the
-- fixture seed inserted by id, so the next default collides on the primary key.
-- pg_get_serial_sequence answers null for this one (the sequence is quoted and
-- owned by no column), so name it outright.
select setval('public."MEDICINE_id_seq"',
              greatest((select coalesce(max(id),1) from public."MEDICINE"), 1), true)
 where to_regclass('public."MEDICINE_id_seq"') is not null;
insert into public."MEDICINE" (product_name, salt_composition, marketer, mrp,
       buyable, image_url_1, therapeutic_class, sales_count, pack_size,
       data_source, url, z_rpr_sup, z_rpr_av, z_rpr_oos, z_rpr_nostock, supplier_count)
select 'TST WARFARIN 5MG - SYNTHETIC (DO NOT USE)', 'Warfarin Sodium (5mg)',
       'TST SUPPLIER A - SYNTHETIC (DO NOT USE)', '100', true,
       'https://medibo.in/icons/Icon-192.png', 'CARDIAC', 5, 'strip of 10',
       'branch-cast', 'https://medibo.invalid/tst-warfarin',
       array['TST SUPPLIER A - SYNTHETIC (DO NOT USE)'],
       '{}'::text[], '{}'::text[], '{}'::text[], 1
 where not exists (select 1 from public."MEDICINE"
                    where salt_composition ilike '%warfarin%');

-- ── 4. PRICING, so _bill_lines_for_order() can raise a catalogue line ───────
insert into public.medicine_pricing (product_id, ptr, gst_pct, pricing_ready, pricing_source)
select m.id, 40, 12, true, 'branch-cast'
  from public."MEDICINE" m
 where not exists (select 1 from public.medicine_pricing p where p.product_id = m.id);

-- ── 5. THE CAST: one customer, one super-admin, one approved pharmacy ───────
-- A branch has no auth.users at all, and orders.user_id is an FK on it: the
-- #1821 fixture block died on orders_user_id_fkey for exactly this reason.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
       email_confirmed_at, created_at, updated_at, raw_app_meta_data,
       raw_user_meta_data, is_super_admin)
select '00000000-0000-0000-0000-000000000000'::uuid,
       '11111111-1111-4111-8111-111111111111'::uuid, 'authenticated','authenticated',
       'tst.cast.customer@medibo.invalid', crypt('not-a-real-password', gen_salt('bf')),
       now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb,
       '{}'::jsonb, false
 where not exists (select 1 from auth.users where id = '11111111-1111-4111-8111-111111111111');

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
       email_confirmed_at, created_at, updated_at, raw_app_meta_data,
       raw_user_meta_data, is_super_admin)
select '00000000-0000-0000-0000-000000000000'::uuid,
       '22222222-2222-4222-8222-222222222222'::uuid, 'authenticated','authenticated',
       'tst.cast.admin@medibo.invalid', crypt('not-a-real-password', gen_salt('bf')),
       now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb,
       '{}'::jsonb, false
 where not exists (select 1 from auth.users where id = '22222222-2222-4222-8222-222222222222');

-- admins.id IS the auth user id — there is no separate user_id column.
insert into public.admins (id, email, is_super, created_at)
select '22222222-2222-4222-8222-222222222222'::uuid, 'tst.cast.admin@medibo.invalid', true, now()
 where not exists (select 1 from public.admins a
                    where a.id = '22222222-2222-4222-8222-222222222222');

insert into public.pharmacy_profiles (id, user_id, pharmacy_name, address, city,
       pincode, is_synthetic, approved, is_deleted, zone_id, created_at)
select '33333333-3333-4333-8333-333333333333'::uuid,
       '11111111-1111-4111-8111-111111111111'::uuid,
       'TST CAST PHARMACY - SYNTHETIC (DO NOT USE)', '1 Test Road', 'Raipur',
       '492001', true, true, false, (select id from public.zones where code='rpr'), now()
 where not exists (select 1 from public.pharmacy_profiles
                    where id = '33333333-3333-4333-8333-333333333333');

-- ── 6. ONE CLOSED ORDER, not synthetic ─────────────────────────────────────
-- qa-697 picks the newest order with closed_at; qa-698 picks the newest order
-- whose is_synthetic is false and whose user_id joins an approved pharmacy.
-- One order satisfies both, so the two chains never fight over which is newest.
insert into public.orders (id, customer_id, user_id, status, fulfillment_status,
       source, is_synthetic, order_code, zone_id, closed_at, created_at,
       dispatch_ready, unfulfilled_count)
select '44444444-4444-4444-8444-444444444444'::uuid,
       '33333333-3333-4333-8333-333333333333'::uuid,
       '11111111-1111-4111-8111-111111111111'::uuid,
       'closed', 'shipped', 'website', false, 'C1851-CAST',
       (select id from public.zones where code='rpr'), now(), now(), false, 0
 where not exists (select 1 from public.orders where order_code = 'C1851-CAST');

insert into public.order_items (id, order_id, product_id, product_name, quantity,
       price, zone_id, is_synthetic, fulfillment_state, received_qty,
       at_warehouse, collect_locked, count_mismatch, received_locked, packed,
       zone_sup, zone_oos, zone_nostock, unfulfillable, created_at)
select gen_random_uuid(), o.id, m.id, m.product_name, 6, 40,
       (select id from public.zones where code='rpr'), false, 'shipped', 6,
       true, false, false, false, true,
       coalesce(m.z_rpr_sup,'{}'::text[]), '{}'::text[], '{}'::text[], false, now()
  from public.orders o
  join lateral (select id, product_name, z_rpr_sup from public."MEDICINE"
                 where salt_composition = 'Paracetamol' order by id limit 1) m on true
 where o.order_code = 'C1851-CAST'
   and not exists (select 1 from public.order_items oi where oi.order_id = o.id);

commit;
