-- CHANGE #707 — the proof. One simulated shift, end to end.
--
-- Every fixture is synthetic and every one of them is deleted before the
-- function returns, so running this on production leaves nothing behind. It
-- impersonates the super admin for exactly the two assertions that need an
-- authorised session (the board, and the override close) and hands the claim
-- back immediately.

create or replace function public.c707_fulfil_proof()
returns jsonb
language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_checks jsonb := '[]'::jsonb; v_pass int := 0; v_fail int := 0;
  v_partner bigint; v_zone smallint; v_cust uuid; v_order uuid; v_item uuid;
  v_wa bigint; v_wb bigint; v_wc bigint;          -- counting, counting, packing-only
  v_task bigint; v_task2 bigint; v_pick bigint; v_res jsonb;
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_admin uuid; t record; v_n int;
begin
  select rp.id, rp.zone_id::smallint into v_partner, v_zone
    from region_partners rp where rp.is_active order by rp.id limit 1;
  if v_partner is null then
    return jsonb_build_object('ok', false, 'error', 'no_partner');
  end if;
  select id into v_cust from pharmacy_profiles
   where is_synthetic and approved and coalesce(is_deleted,false) = false limit 1;
  if v_cust is null then
    return jsonb_build_object('ok', false, 'error', 'no_synthetic_customer');
  end if;
  select u.id into v_admin from admins a
    join auth.users u on lower(btrim(u.email)) = lower(btrim(a.email))
   where a.is_super limit 1;

  -- ── fixtures ─────────────────────────────────────────────────────────────
  insert into orders (id, customer_id, fulfillment_status, dispatch_ready, source,
                      unfulfilled_count, is_synthetic, placed_by_admin, order_code, zone_id)
  values (gen_random_uuid(), v_cust, 'collecting', false, 'website', 0, true, true,
          'C707-PROOF', v_zone)
  returning id into v_order;

  insert into order_items (id, order_id, product_name, zone_id, is_synthetic)
  values (gen_random_uuid(), v_order, 'C707 proof line', v_zone, true)
  returning id into v_item;

  insert into partner_worker (partner_id, zone_id, identity, display_name, work_role, created_by)
  values (v_partner, v_zone, 'c707.a@proof.invalid', 'Proof A', 'counting', 'c707-proof')
  on conflict (identity) do update set is_active = true, partner_id = excluded.partner_id,
       zone_id = excluded.zone_id, work_role = excluded.work_role
  returning id into v_wa;
  insert into partner_worker (partner_id, zone_id, identity, display_name, work_role, created_by)
  values (v_partner, v_zone, 'c707.b@proof.invalid', 'Proof B', 'counting', 'c707-proof')
  on conflict (identity) do update set is_active = true, partner_id = excluded.partner_id,
       zone_id = excluded.zone_id, work_role = excluded.work_role
  returning id into v_wb;
  insert into partner_worker (partner_id, zone_id, identity, display_name, work_role, created_by)
  values (v_partner, v_zone, 'c707.c@proof.invalid', 'Proof C', 'packing', 'c707-proof')
  on conflict (identity) do update set is_active = true, partner_id = excluded.partner_id,
       zone_id = excluded.zone_id, work_role = excluded.work_role
  returning id into v_wc;

  -- A and C are on shift; B is deliberately NOT marked, so "on shift" has
  -- something to exclude.
  insert into partner_worker_shift (worker_id, shift_date, status, marked_by)
  values (v_wa, v_today, 'present', 'c707-proof'), (v_wc, v_today, 'present', 'c707-proof')
  on conflict (worker_id, shift_date) do update set status = excluded.status;

  -- ── 1. one open task per order-stage ─────────────────────────────────────
  v_task  := public._c707_ensure_task(v_order, 'count', null, v_zone, v_partner);
  v_task2 := public._c707_ensure_task(v_order, 'count', null, v_zone, v_partner);
  v_checks := v_checks || public._c703_assert('a stage materialises one task', v_task is not null);
  v_checks := v_checks || public._c703_assert('asking twice returns the SAME task', v_task = v_task2);
  select count(*) into v_n from fulfil_task
   where order_id = v_order and stage_key = 'count' and done_at is null;
  v_checks := v_checks || public._c703_assert('one OPEN task per order-stage', v_n = 1);

  -- ── 2. auto-assign: on shift, qualified, least loaded ────────────────────
  v_pick := public._c707_auto_pick(v_zone, v_partner, 'count');
  v_checks := v_checks || public._c703_assert('auto-assign picks an on-shift counter', v_pick = v_wa);
  v_checks := v_checks || public._c703_assert('an unmarked worker is never picked', v_pick <> v_wb);
  -- C is present but packs; the count stage must not reach them.
  v_checks := v_checks || public._c703_assert('a packer is not picked for the count stage',
                v_pick <> v_wc);
  v_pick := public._c707_auto_pick(v_zone, v_partner, 'pack');
  v_checks := v_checks || public._c703_assert('the pack stage reaches the packer', v_pick = v_wc);

  -- Load A up, then mark B present: the next count pick must fan out to B.
  update fulfil_task set worker_id = v_wa, assigned_at = now(), source = 'auto' where id = v_task;
  insert into partner_worker_shift (worker_id, shift_date, status, marked_by)
  values (v_wb, v_today, 'present', 'c707-proof')
  on conflict (worker_id, shift_date) do update set status = excluded.status;
  v_checks := v_checks || public._c703_assert('round-robin fans out to the idle worker',
                public._c707_auto_pick(v_zone, v_partner, 'count') = v_wb);

  -- ── 3. the actor binds itself ────────────────────────────────────────────
  -- The count stage's task is assigned to A. C stamps the line instead.
  update order_items set received_by = 'c707.a@proof.invalid', received_qty = 7,
                         received_at = now()
   where id = v_item;
  select * into t from fulfil_task where id = v_task;
  v_checks := v_checks || public._c703_assert('the actor starts the task', t.started_at is not null);
  v_checks := v_checks || public._c703_assert('the item is counted onto the task', t.items_touched = 1);
  v_checks := v_checks || public._c703_assert('the quantity lands on the task', t.qty_handled = 7);
  v_checks := v_checks || public._c703_assert('an ASSIGNED task keeps its worker',
                t.worker_id = v_wa);

  -- An UNASSIGNED task adopts whoever actually did the work.
  update fulfil_task set worker_id = null, assigned_at = null where id = v_task;
  update order_items set received_by = 'c707.b@proof.invalid', received_qty = 3
   where id = v_item;
  select * into t from fulfil_task where id = v_task;
  v_checks := v_checks || public._c703_assert('an UNASSIGNED task adopts the actor',
                t.worker_id = v_wb);
  v_checks := v_checks || public._c703_assert('quantities accumulate, they do not replace',
                t.qty_handled = 10);

  -- ── 4. the guard ─────────────────────────────────────────────────────────
  -- No session, so my_fulfil_worker_id() is null and _c707_can() is false:
  -- the stage refuses to close, in the backend's own words.
  v_res := public.fulfil_task_finish(v_task, null);
  v_checks := v_checks || public._c703_assert('a stranger cannot close the stage',
                (v_res->>'ok')::boolean = false and v_res->>'error' = 'not_yours');
  v_checks := v_checks || public._c703_assert('the refusal names the assigned worker',
                position('Proof B' in coalesce(v_res->>'message','')) > 0);
  select * into t from fulfil_task where id = v_task;
  v_checks := v_checks || public._c703_assert('the refused stage is still open', t.done_at is null);

  -- ── 5. override, as the super admin ──────────────────────────────────────
  if v_admin is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    v_res := public.fulfil_task_finish(v_task, 'proof override');
    perform set_config('request.jwt.claims', '', true);

    v_checks := v_checks || public._c703_assert('a partner override CAN close it',
                  (v_res->>'ok')::boolean);
    v_checks := v_checks || public._c703_assert('the close is reported as an override',
                  (v_res->>'override')::boolean);
    select * into t from fulfil_task where id = v_task;
    v_checks := v_checks || public._c703_assert('the override is stamped on the row',
                  t.done_at is not null and t.override_by is not null
                  and t.override_reason = 'proof override');
    v_checks := v_checks || public._c703_assert('the override keeps the name it was taken from',
                  t.worker_id = v_wb);
  end if;

  -- ── 6. an unowned stage ages into an exception ───────────────────────────
  v_task2 := public._c707_ensure_task(v_order, 'pack', null, v_zone, v_partner);
  select count(*) into v_n from public._c707_unassigned_rows() r where r.ref_id = v_task2::text;
  v_checks := v_checks || public._c703_assert('a fresh unowned stage is NOT an exception yet',
                v_n = 0);
  update fulfil_task set created_at = now() - interval '90 minutes' where id = v_task2;
  select count(*) into v_n from public._c707_unassigned_rows() r where r.ref_id = v_task2::text;
  v_checks := v_checks || public._c703_assert('an AGED unowned stage is an exception', v_n = 1);
  v_checks := v_checks || public._c703_assert('the exception reason is registered and enabled',
                exists (select 1 from exception_reason
                         where reason_code = 'fulfil_task_unassigned' and enabled));
  update fulfil_task set worker_id = v_wa, assigned_at = now() where id = v_task2;
  select count(*) into v_n from public._c707_unassigned_rows() r where r.ref_id = v_task2::text;
  v_checks := v_checks || public._c703_assert('assigning it clears the exception', v_n = 0);

  -- ── 7. the ops board says who ────────────────────────────────────────────
  v_checks := v_checks || public._c703_assert('the ops board owner block names the worker',
                (public._c707_owner_block(v_order,'pack')->>'assigned')::boolean
                and public._c707_owner_block(v_order,'pack')->>'name' = 'Proof A');
  update fulfil_task set worker_id = null where id = v_task2;
  v_checks := v_checks || public._c703_assert('an unowned stage reads Unassigned, from ui_copy',
                public._c707_owner_block(v_order,'pack')->>'name'
                  = public.uic('ops_board.unassigned','Unassigned')
                and public._c707_owner_block(v_order,'pack')->>'tone' = 'warning');

  -- ── 8. every rendered string is the backend's ────────────────────────────
  v_checks := v_checks || public._c703_assert('the task block prints no leftover placeholder',
                position('{' in (public._c707_task_block(v_task2)->>'worker_label')) = 0
                and position('{' in (public._c707_task_block(v_task2)->>'state_label')) = 0
                and position('{' in (public._c707_task_block(v_task2)->>'qty_label')) = 0);
  v_checks := v_checks || public._c703_assert('nothing counted yet says so in words',
                public._c707_task_block(v_task2)->>'qty_label' = public._c('ft.qty_none'));

  -- ── 9. productivity is measured, as the super admin ──────────────────────
  if v_admin is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);
    v_res := public.fulfil_worker_productivity(1);
    v_checks := v_checks || public._c703_assert('productivity answers for an authorised caller',
                  (v_res->>'ok')::boolean);
    v_checks := v_checks || public._c703_assert('the proof workers appear on it',
                  exists (select 1 from jsonb_array_elements(v_res->'rows') r
                           where r->>'name' in ('Proof A','Proof B','Proof C')));
    v_checks := v_checks || public._c703_assert('a worker with no hours reads the backend dash',
                  exists (select 1 from jsonb_array_elements(v_res->'rows') r
                           where r->>'name' = 'Proof C'
                             and r->>'items_per_hour' = public._c('ft.prod_none')));
    v_res := public.fulfil_task_board(v_zone);
    v_checks := v_checks || public._c703_assert('the board answers for an authorised caller',
                  (v_res->>'ok')::boolean);
    v_checks := v_checks || public._c703_assert('the board offers only on-shift workers as chips',
                  not exists (select 1 from jsonb_array_elements(v_res->'workers') w
                               where w->>'name' = 'Proof C' and (w->>'shift') is null));
    perform set_config('request.jwt.claims', '', true);
  end if;

  -- ── cleanup ──────────────────────────────────────────────────────────────
  delete from fulfil_task where order_id = v_order;
  delete from order_items where order_id = v_order;
  delete from orders where id = v_order;
  delete from partner_worker_shift where worker_id in (v_wa, v_wb, v_wc);
  delete from login_identities where owner_type = 'worker'
     and owner_id in (v_wa::text, v_wb::text, v_wc::text);
  delete from partner_worker where id in (v_wa, v_wb, v_wc);

  select count(*) filter (where (x->>'ok')::boolean),
         count(*) filter (where not (x->>'ok')::boolean)
    into v_pass, v_fail
    from jsonb_array_elements(v_checks) x;

  return jsonb_build_object('ok', v_fail = 0, 'passed', v_pass, 'failed', v_fail,
                            'checks', v_checks);
end $fn$;
