-- CHANGE #470 — the state-machine sweep, and auto-resolve.
--
-- Two ticks, both on the #305 dispatcher (cron_task rows — no new pg_cron job,
-- and no bare */N schedule; the dispatcher owns the clock).
--
--  ops_state_machine_sweep()   finds states that cannot legally exist and
--                              writes each one as an ops_state_finding, which
--                              _exception_rows() reads as 'impossible_state'.
--                              The SAME pass clears a finding whose state is
--                              gone, so nothing is resolved by hand.
--  exceptions_autoresolve_sweep()  closes the exception_state row of an
--                              exception whose underlying thing has MOVED.
--                              The queue is derived, so such a row already
--                              vanishes from the console; this keeps the
--                              recorded history honest instead of leaving a
--                              half-worked row open forever.

insert into public.exception_outcome
  (outcome_code, applies_to, affects, weight, is_success, sort_rank, enabled)
values ('auto_resolved', 'all', 'none', 0, true, 0, true)
on conflict (outcome_code) do update set enabled = true;

insert into public.ui_copy (key, value) values
  ('exc.outcome.auto_resolved', '"Resolved by itself"'::jsonb),
  ('exc.status.resolved',       '"Resolved"'::jsonb),
  ('exc.status.acknowledged',   '"Acknowledged"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── the state machine ────────────────────────────────────────────────────────
create or replace function public.ops_state_machine_sweep(p_limit integer default 200)
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_lim   int := greatest(least(coalesce(p_limit, 200), 1000), 1);
  v_found int := 0;
  v_clear int := 0;
begin
  -- Every rule produces (rule_key, entity_id, order_id, zone_id, label, detail)
  -- into one temp set. One pass writes the new ones and clears the gone ones,
  -- so a finding can never outlive the state that justified it.
  create temp table _c470_live on commit drop as
    -- 1. Packed without the shop collection ever being locked.
    select 'item_packed_uncollected'::text as rule_key, oi.id::text as entity_id,
           oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)) as label,
           coalesce(nullif(oi.assigned_supplier,''), '—') as detail
      from public.order_items oi
     where coalesce(oi.packed, false)
       and coalesce(oi.collect_locked, false) = false
       and coalesce(oi.status,'') <> 'cancelled'
       and coalesce(oi.unfulfillable, false) = false
    union all
    -- 2. Recounted at the warehouse without ever being collected.
    select 'item_counted_uncollected', oi.id::text, oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)),
           coalesce(nullif(oi.assigned_supplier,''), '—')
      from public.order_items oi
     where oi.wh_recount_qty is not null
       and coalesce(oi.collect_locked, false) = false
       and coalesce(oi.status,'') <> 'cancelled'
    union all
    -- 3. In a bag with no warehouse count behind it.
    select 'bagged_uncounted', oi.id::text, oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)),
           coalesce(nullif(oi.assigned_supplier,''), '—')
      from public.order_items oi
     where oi.wh_recount_qty is null
       and coalesce(oi.status,'') <> 'cancelled'
       and exists (select 1 from public.bag_allocations ba where ba.order_item_id = oi.id)
    union all
    -- 4. A line no supplier could fill, packed into the order anyway.
    select 'unfulfillable_packed', oi.id::text, oi.order_id, oi.zone_id,
           coalesce(nullif(oi.product_name,''), 'Line ' || left(oi.id::text,8)),
           coalesce(nullif(oi.unfulfillable_reason,''), '—')
      from public.order_items oi
     where coalesce(oi.unfulfillable, false)
       and coalesce(oi.packed, false)
    union all
    -- 5. A stop closed with no proof of any kind.
    select 'delivered_no_proof', d.id::text, d.order_id, d.zone_id,
           coalesce(nullif(o.order_code,''), 'Stop ' || left(d.id::text,8)),
           coalesce(nullif(d.proof_method,''), '—')
      from public.deliveries d
      left join public.orders o on o.id = d.order_id
     where lower(coalesce(d.status,'')) in ('delivered','completed')
       and d.otp_verified_at is null
       and coalesce(d.proof_photo_path,'') = ''
       and coalesce(d.signature_path,'') = ''
    union all
    -- 6. An order closed while lines are still live.
    select 'closed_with_live_items', o.id::text, o.id, o.zone_id,
           coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)),
           coalesce(nullif(o.pharmacy_name,''), '—')
      from public.orders o
     where o.closed_at is not null
       and exists (select 1 from public.order_items oi
                    where oi.order_id = o.id
                      and coalesce(oi.status,'') <> 'cancelled'
                      and coalesce(oi.unfulfillable, false) = false
                      and coalesce(oi.packed, false) = false);

  -- New findings, and a heartbeat on the ones still true.
  with ins as (
    insert into public.ops_state_finding
      (rule_key, entity_kind, entity_id, order_id, zone_id, label, detail)
    select l.rule_key, r.entity_kind, l.entity_id, l.order_id, l.zone_id,
           l.label, l.detail
      from _c470_live l
      join public.ops_state_rule r on r.rule_key = l.rule_key and r.enabled
     order by l.rule_key, l.entity_id
     limit v_lim
    on conflict (rule_key, entity_id) where cleared_at is null
    do update set last_seen_at = now(),
                  runs  = public.ops_state_finding.runs + 1,
                  label = excluded.label,
                  detail = excluded.detail
    returning (xmax = 0) as inserted)
  select count(*) filter (where inserted) into v_found from ins;

  -- Gone from the live set = the state was corrected. Clear it.
  with cl as (
    update public.ops_state_finding f
       set cleared_at = now()
     where f.cleared_at is null
       and not exists (select 1 from _c470_live l
                        where l.rule_key = f.rule_key and l.entity_id = f.entity_id)
    returning 1)
  select count(*) into v_clear from cl;

  return jsonb_build_object('ok', true, 'opened', v_found, 'cleared', v_clear,
                            'open_total', (select count(*) from public.ops_state_finding
                                            where cleared_at is null));
end $function$;

-- ── auto-resolve ─────────────────────────────────────────────────────────────
create or replace function public.exceptions_autoresolve_sweep()
returns jsonb
language plpgsql security definer set search_path to 'public' as $function$
declare v_n int := 0;
begin
  with live as (select reason_code, ref_id from public._exception_rows()),
  cl as (
    update public.exception_state s
       set status       = 'closed',
           outcome_code = coalesce(nullif(s.outcome_code,''), 'auto_resolved'),
           closed_at    = now(),
           closed_by    = 'auto',
           updated_at   = now()
     where s.status <> 'closed'
       and not exists (select 1 from live l
                        where l.reason_code = s.reason_code and l.ref_id = s.ref_id)
    returning 1)
  select count(*) into v_n from cl;

  return jsonb_build_object('ok', true, 'auto_resolved', v_n);
end $function$;

-- ── the #305 dispatcher owns the clock. No new pg_cron job. ──────────────────
insert into public.cron_task (name, ord, mode, work_sql, enabled, dml,
                              base_interval_s, max_interval_s, note)
values
  ('c470-state-machine-sweep', 470, 'poll',
   'select public.ops_state_machine_sweep(200)', true, true, 600, 1800,
   'CHANGE #470 — impossible states become exceptions; corrected ones clear themselves.'),
  ('c470-exception-autoresolve', 471, 'poll',
   'select public.exceptions_autoresolve_sweep()', true, true, 600, 1800,
   'CHANGE #470 — an exception whose underlying thing moved closes itself.')
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = excluded.enabled,
      dml = excluded.dml, base_interval_s = excluded.base_interval_s,
      max_interval_s = excluded.max_interval_s, note = excluded.note;
