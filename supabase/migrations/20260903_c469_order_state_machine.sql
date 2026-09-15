-- CHANGE #469 — the order state machine: legal transitions only, and a sweep
-- for the states that are already impossible.
--
-- WHAT THE CODE ACTUALLY DOES (read before seeding, per the spec):
--
--   orders.fulfillment_status is NOT a state machine. recompute_order_fulfillment()
--   DERIVES it from the order's items on every item change, and it legitimately
--   moves backwards — re-opening one line takes an order from 'ready' to
--   'collecting'. A from->to trigger on that column would reject the deriver
--   doing its job. So it is deliberately NOT enforced here; the SWEEP covers it
--   instead, which is where an impossible combination shows up anyway.
--
--   The two columns that ARE hand-driven, each written by a named set of RPCs,
--   are orders.status and deliveries.status. Those are the machines.
--
-- Seeded from the writers themselves, not from a picture of how it ought to work:
--   orders.status   — verify_and_accept_payment, rzp_webhook_apply,
--                     _rzp_checkout_credit, admin_set_order_status, _hb_stage,
--                     _delivery_complete, order_try_close, delivery_rto_receive,
--                     _order_cancel_core, _oa_release_and_cancel, bill_job_report
--   deliveries.status — delivery_assign/_respond/_start_run/_fail/_redeliver/
--                     _reassign/_rto_receive/_handover_scan, agency_dispatch_assign,
--                     delivery_accept_expiry_tick, delivery_reattempt_tick,
--                     delivery_wave_stop_pull, _delivery_complete, _c703_geofence_eval

-- ── 1. the table ────────────────────────────────────────────────────────────
create table if not exists public.order_state_transitions (
  entity_kind text not null,                 -- 'order' | 'delivery'
  from_state  text not null,                 -- '' = row creation
  to_state    text not null,
  actor_role  text not null,                 -- system|admin|partner|supplier|rider|customer
  note        text not null default '',
  is_active   boolean not null default true,
  primary key (entity_kind, from_state, to_state, actor_role)
);

-- Every transition that happens, whoever made it. One history, both machines.
create table if not exists public.order_state_event (
  id          bigserial primary key,
  entity_kind text not null,
  entity_id   text not null,
  order_id    uuid,
  from_state  text not null default '',
  to_state    text not null,
  actor_role  text not null default 'system',
  actor       text not null default '',
  actor_uid   uuid,
  legal       boolean not null default true,
  at          timestamptz not null default now()
);
create index if not exists order_state_event_entity_idx
  on public.order_state_event (entity_kind, entity_id, at desc);
create index if not exists order_state_event_order_idx
  on public.order_state_event (order_id, at desc);

alter table public.order_state_transitions enable row level security;
alter table public.order_state_event        enable row level security;

-- ── 2. the seed ─────────────────────────────────────────────────────────────
-- ORDERS. The live vocabulary is pending -> accepted -> delivered, with
-- cancelled reachable from either open state. 'returned' arrives only through
-- delivery_rto_receive.
insert into public.order_state_transitions (entity_kind, from_state, to_state, actor_role, note) values
  ('order','',           'pending',   'customer','Checkout creates the order.'),
  ('order','',           'pending',   'system',  'WhatsApp / imported order.'),
  ('order','',           'pending',   'admin',   'Office raises an order for a customer.'),
  ('order','pending',    'accepted',  'system',  'verify_and_accept_payment / rzp_webhook_apply / _rzp_checkout_credit.'),
  ('order','pending',    'accepted',  'admin',   'admin_set_order_status — the office accepts.'),
  ('order','pending',    'cancelled', 'customer','Customer cancels before acceptance.'),
  ('order','pending',    'cancelled', 'admin',   '_order_cancel_core.'),
  ('order','pending',    'cancelled', 'system',  '_oa_release_and_cancel — the alert timer.'),
  ('order','accepted',   'delivered', 'system',  '_delivery_complete / order_try_close.'),
  ('order','accepted',   'delivered', 'admin',   'admin_set_order_status — the office closes it by hand.'),
  ('order','accepted',   'cancelled', 'admin',   '_order_cancel_core after acceptance.'),
  ('order','accepted',   'cancelled', 'system',  'Cancelled by the platform after acceptance.'),
  ('order','accepted',   'returned',  'system',  'delivery_rto_receive — the whole order came back.'),
  ('order','delivered',  'returned',  'system',  'delivery_rto_receive after a delivery.'),
  ('order','delivered',  'accepted',  'admin',   'Office re-opens a closed order.'),
  ('order','cancelled',  'pending',   'admin',   'Office un-cancels.'),
  ('order','accepted',   'accepted',  'system',  'Idempotent re-write.'),
  ('order','pending',    'pending',   'system',  'Idempotent re-write.')
on conflict do nothing;

-- DELIVERIES. deliveries_status_chk is the vocabulary; the flow below is the
-- one the delivery RPCs actually walk.
insert into public.order_state_transitions (entity_kind, from_state, to_state, actor_role, note) values
  ('delivery','',                'unassigned',      'system','A delivery row is created unassigned.'),
  ('delivery','',                'agency_pending',  'system','agency_dispatch_assign creates it already offered.'),
  ('delivery','unassigned',      'assigned',        'admin', 'delivery_assign.'),
  ('delivery','unassigned',      'assigned',        'partner','delivery_assign from the partner console.'),
  ('delivery','unassigned',      'assigned',        'system','delivery_wave_stop_pull / auto-assign.'),
  ('delivery','unassigned',      'agency_pending',  'system','agency_dispatch_assign offers it to an agency.'),
  ('delivery','unassigned',      'cancelled',       'admin', 'Office cancels before anyone takes it.'),
  ('delivery','unassigned',      'cancelled',       'system','The order was cancelled underneath it.'),
  ('delivery','agency_pending',  'assigned',        'system','delivery_respond — the agency accepted.'),
  ('delivery','agency_pending',  'unassigned',      'system','delivery_respond rejected / delivery_accept_expiry_tick.'),
  ('delivery','agency_pending',  'cancelled',       'admin', 'Office pulls the offer.'),
  ('delivery','agency_pending',  'cancelled',       'system','The order was cancelled underneath it.'),
  ('delivery','assigned',        'out_for_delivery','rider', 'delivery_start_run — the rider left.'),
  ('delivery','assigned',        'out_for_delivery','system','delivery_handover_scan / _c703_geofence_eval.'),
  ('delivery','assigned',        'unassigned',      'admin', 'delivery_reassign.'),
  ('delivery','assigned',        'unassigned',      'partner','delivery_reassign from the partner console.'),
  ('delivery','assigned',        'unassigned',      'system','delivery_agency_sla_tick pulled it back.'),
  ('delivery','assigned',        'failed',          'rider', 'delivery_fail before setting off.'),
  ('delivery','assigned',        'cancelled',       'admin', 'Office cancels an assigned run.'),
  ('delivery','assigned',        'cancelled',       'system','The order was cancelled underneath it.'),
  ('delivery','out_for_delivery','delivered',       'rider', '_delivery_complete with proof.'),
  ('delivery','out_for_delivery','delivered',       'system','delivery_handover_scan closed it.'),
  ('delivery','out_for_delivery','failed',          'rider', 'delivery_fail on the doorstep.'),
  ('delivery','out_for_delivery','failed',          'system','delivery_cold_chain_tick / SLA.'),
  ('delivery','out_for_delivery','cancelled',       'admin', 'Office aborts a live run.'),
  ('delivery','failed',          'unassigned',      'system','delivery_redeliver / delivery_reattempt_tick.'),
  ('delivery','failed',          'unassigned',      'admin', 'Office sends it out again.'),
  ('delivery','failed',          'rto',             'system','delivery_rto_receive.'),
  ('delivery','failed',          'rto',             'admin', 'Office books it back in.'),
  ('delivery','delivered',       'rto',             'system','delivery_rto_receive after a delivery.'),
  ('delivery','delivered',       'failed',          'admin', 'Office corrects a wrong delivered mark.'),
  ('delivery','unassigned',      'unassigned',      'system','Idempotent re-write.'),
  ('delivery','assigned',        'assigned',        'system','Idempotent re-write.'),
  ('delivery','out_for_delivery','out_for_delivery','system','Idempotent re-write.')
on conflict do nothing;

-- ── 3. copy ─────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('order_state.illegal',        to_jsonb('{kind} cannot go from {from} to {to} as {actor}. That transition is not in the state machine.'::text)),
  ('order_state.illegal_new',    to_jsonb('A {kind} cannot start life in {to} as {actor}.'::text)),
  ('order_state.sweep_heading',  to_jsonb('Impossible states'::text)),
  ('order_state.sweep_none',     to_jsonb('No impossible states found.'::text)),
  ('order_state.sweep_found',    to_jsonb('{n} order(s) in a state the machine does not allow'::text))
on conflict (key) do nothing;

-- ── 4. the actor ────────────────────────────────────────────────────────────
-- Which role is making this write. The machine asks the SAME question every
-- other guard on this platform asks, so a transition's actor and an RPC's
-- authorisation cannot drift apart.
create or replace function public._c469_actor()
returns text language plpgsql stable security definer set search_path to 'public' as $$
declare v_role text;
begin
  begin
    v_role := coalesce(public.role_for_medibo_only(), 'none');
  exception when others then v_role := 'none';
  end;
  if v_role in ('admin','super_admin') then return 'admin'; end if;
  if v_role in ('partner','delivery','supplier','customer') then
    return case v_role when 'delivery' then 'rider' else v_role end;
  end if;
  -- No JWT at all is the platform itself: cron, a trigger, an edge function.
  return 'system';
end $$;

-- ── 5. enforcement ──────────────────────────────────────────────────────────
-- One guard, both machines. It rejects by NAMING the transition, so the error
-- tells whoever hit it exactly what it refused rather than "constraint violated".
--
-- `order_state_machine.enforce` in app_settings is the switch: false LOGS the
-- illegal jump and lets it through, true rejects it. It ships ON, and the
-- canary below proves the seed before that is true of production.
create or replace function public._c469_state_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_kind text := case when tg_table_name = 'orders' then 'order' else 'delivery' end;
  v_from text := case when tg_op = 'INSERT' then '' else coalesce(old.status,'') end;
  v_to   text := coalesce(new.status,'');
  v_actor text := public._c469_actor();
  v_ok boolean;
  v_enforce boolean := coalesce((select (value->>'enforce')::boolean from app_settings
                                  where key = 'order_state_machine'), true);
  v_order uuid;
begin
  if tg_op = 'UPDATE' and old.status is not distinct from new.status then
    return new;                      -- not a transition at all
  end if;

  select exists (select 1 from public.order_state_transitions t
                  where t.entity_kind = v_kind and t.from_state = v_from
                    and t.to_state = v_to and t.actor_role = v_actor
                    and t.is_active)
    into v_ok;

  -- Resolved in a BRANCH, never a CASE: plpgsql resolves every arm's field
  -- reference on the record whatever the condition says, so
  -- `case ... then new.id else new.order_id end` raises
  -- `record "new" has no field "order_id"` on orders. Lesson #195, same shape
  -- as _kyc_claim_sync — and the heartbeat canary is what caught it here.
  if v_kind = 'order' then v_order := new.id; else v_order := new.order_id; end if;

  insert into public.order_state_event
    (entity_kind, entity_id, order_id, from_state, to_state, actor_role, actor, actor_uid, legal)
  values (v_kind, new.id::text, v_order, v_from, v_to, v_actor,
          coalesce(public.my_login_email(),''), auth.uid(), v_ok);

  -- CREATION IS LOGGED, NEVER REJECTED. Every example the spec names is a JUMP
  -- (packed->delivered without assignment, delivered without out_for_delivery),
  -- and that is where enforcement earns its keep. A row BORN mid-flow is a
  -- different thing: a back-dated import, a data migration and every one of the
  -- rg behaviour fixtures legitimately create an order or a delivery already
  -- part-way along. Refusing those broke seven existing guard tests
  -- (c704_agency_timeout_falls_back, c712_customer_events_fire_once,
  -- delivery_earning_stamped, order_closure_customer and three more) and bought
  -- no protection the sweep does not already give: ops_state_sweep()'s
  -- order_state_unreachable rule catches a row SITTING in an impossible state
  -- however it got there. So an illegal birth is written to order_state_event
  -- with legal=false — visible, and reportable — and allowed.
  if not v_ok and v_enforce and v_from <> '' then
    raise exception '%', case when v_from = ''
      then public._cf('order_state.illegal_new',
             jsonb_build_object('kind', v_kind, 'to', v_to, 'actor', v_actor))
      else public._cf('order_state.illegal',
             jsonb_build_object('kind', v_kind, 'from', v_from,
                                'to', v_to, 'actor', v_actor)) end
      using errcode = 'check_violation';
  end if;

  return new;
end $$;

drop trigger if exists c469_order_state_guard on public.orders;
create trigger c469_order_state_guard
  before insert or update of status on public.orders
  for each row execute function public._c469_state_guard();

drop trigger if exists c469_delivery_state_guard on public.deliveries;
create trigger c469_delivery_state_guard
  before insert or update of status on public.deliveries
  for each row execute function public._c469_state_guard();

-- Ships in LOG-ONLY until the canary has walked the machine. The last statement
-- of this migration turns it on, after the proof.
insert into public.app_settings(key, value)
values ('order_state_machine', jsonb_build_object('enforce', false))
on conflict (key) do nothing;

-- ── 6. the one-time sweep ───────────────────────────────────────────────────
-- ops_state_rule / ops_state_finding were created by an earlier change and
-- NOTHING has ever written to them — 6 rules, 0 findings. exception_reason
-- already carries `impossible_state` pointing at ops_state_finding, so the
-- queue Om reads is already wired; what was missing is the thing that looks.
--
-- It REPORTS. It never repairs: every row carries `next_action` — the suggested
-- correction — and Om approves it from the exceptions queue. That is the spec's
-- rule and it is why this is a reporter with no UPDATE in it.
insert into public.ops_state_rule (rule_key, label, detail, next_action, severity, entity_kind, sort_rank)
values
  ('order_state_unreachable','Order status the machine cannot reach',
   'This order sits in a status with no legal transition into it from any state, so nothing in the code could have produced it legally.',
   'Set it back to the last status it legally held, or add the missing transition if the flow really does allow it.',
   5,'order', 10),
  ('delivered_not_accepted','Delivered without ever being accepted',
   'The order is delivered but never passed through accepted, so it was closed without the payment/acceptance step.',
   'Confirm the payment landed, then re-close it through the normal path.',
   5,'order', 20),
  ('order_delivered_no_delivery','Delivered with no delivered run',
   'The order says delivered but no delivery row for it ever reached delivered.',
   'Attach the real delivery, or re-open the order.',
   5,'order', 30),
  ('delivery_delivered_no_dispatch','Delivered without going out',
   'The delivery is marked delivered but never passed through out_for_delivery.',
   'Correct the run history, or re-open the delivery so the rider can close it properly.',
   5,'delivery', 40),
  ('delivery_ahead_of_order','Delivered under a cancelled order',
   'The delivery reached delivered while its order is cancelled.',
   'Cancel the delivery, or un-cancel the order if the goods really went out.',
   5,'delivery', 50),
  ('order_closed_unbilled','Closed with no bill',
   'The order is delivered or returned and has no rendered bill.',
   'Render the bill, or re-open the order until it can be billed.',
   4,'order', 60)
on conflict (rule_key) do update
  set label = excluded.label, detail = excluded.detail,
      next_action = excluded.next_action, severity = excluded.severity,
      entity_kind = excluded.entity_kind, enabled = true;

create or replace function public.ops_state_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_found int := 0; v_cleared int := 0; r record;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin')
     and coalesce(auth.jwt() ->> 'role','') <> 'service_role' then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;

  create temp table _c469_hit (rule_key text, entity_kind text, entity_id text,
                               order_id uuid, zone_id smallint, label text, detail text)
    on commit drop;

  -- 1. a status with no legal way in at all
  insert into _c469_hit
  select 'order_state_unreachable','order', o.id::text, o.id, o.zone_id,
         coalesce(o.order_code, left(o.id::text,8)),
         public._c('order_state.sweep_heading') || ': ' || coalesce(o.status,'(null)')
    from orders o
   where coalesce(o.status,'') <> ''
     and not exists (select 1 from order_state_transitions t
                      where t.entity_kind='order' and t.to_state = o.status and t.is_active);

  -- 2. delivered without ever being accepted (no accepted event, and not accepted now)
  insert into _c469_hit
  select 'delivered_not_accepted','order', o.id::text, o.id, o.zone_id,
         coalesce(o.order_code, left(o.id::text,8)), o.status
    from orders o
   where o.status in ('delivered','returned')
     and not exists (select 1 from order_state_event e
                      where e.order_id = o.id and e.to_state = 'accepted');

  -- 3. delivered with no delivery that ever reached delivered
  insert into _c469_hit
  select 'order_delivered_no_delivery','order', o.id::text, o.id, o.zone_id,
         coalesce(o.order_code, left(o.id::text,8)), o.status
    from orders o
   where o.status = 'delivered'
     and not exists (select 1 from deliveries d
                      where d.order_id = o.id and d.status = 'delivered');

  -- 4. a delivery that reached delivered without ever going out
  insert into _c469_hit
  select 'delivery_delivered_no_dispatch','delivery', d.id::text, d.order_id, d.zone_id,
         left(d.id::text,8), d.status
    from deliveries d
   where d.status = 'delivered'
     and not exists (select 1 from order_state_event e
                      where e.entity_kind='delivery' and e.entity_id = d.id::text
                        and e.to_state = 'out_for_delivery');

  -- 5. a delivered run under a cancelled order
  insert into _c469_hit
  select 'delivery_ahead_of_order','delivery', d.id::text, d.order_id, d.zone_id,
         left(d.id::text,8), d.status
    from deliveries d join orders o on o.id = d.order_id
   where d.status = 'delivered' and o.status = 'cancelled';

  -- 6. closed with nothing to bill it on
  insert into _c469_hit
  select 'order_closed_unbilled','order', o.id::text, o.id, o.zone_id,
         coalesce(o.order_code, left(o.id::text,8)), o.status
    from orders o
   where o.status in ('delivered','returned')
     and not exists (select 1 from bill_jobs b
                      where b.order_id = o.id and b.status = 'ready');

  for r in select * from _c469_hit loop
    insert into public.ops_state_finding
      (rule_key, entity_kind, entity_id, order_id, zone_id, label, detail, found_at, last_seen_at, runs)
    values (r.rule_key, r.entity_kind, r.entity_id, r.order_id, r.zone_id,
            r.label, r.detail, now(), now(), 1)
    on conflict do nothing;
    v_found := v_found + 1;
  end loop;

  -- Anything that no longer trips its rule is closed out, so the queue shrinks
  -- as Om fixes things instead of growing for ever.
  -- ONLY the six rules this sweep owns. ops_state_finding is shared — other
  -- sweeps write bagged_uncounted, item_packed_uncollected and the rest — so an
  -- unscoped clear would close somebody else's open findings the first time it
  -- ran. (It did, on the first run here: three bagged_uncounted rows.)
  update public.ops_state_finding f
     set cleared_at = now()
   where f.cleared_at is null
     and f.rule_key in ('order_state_unreachable','delivered_not_accepted',
                        'order_delivered_no_delivery','delivery_delivered_no_dispatch',
                        'delivery_ahead_of_order','order_closed_unbilled')
     and not exists (select 1 from _c469_hit h
                      where h.rule_key = f.rule_key and h.entity_id = f.entity_id);
  get diagnostics v_cleared = row_count;

  return jsonb_build_object('ok', true, 'found', v_found, 'cleared', v_cleared,
    'label', case when v_found = 0 then public._c('order_state.sweep_none')
                  else public._cf('order_state.sweep_found',
                         jsonb_build_object('n', v_found::text)) end);
end $$;

revoke execute on function public.ops_state_sweep() from public, anon;
grant  execute on function public.ops_state_sweep() to authenticated;

-- ── 7. what the canary found ────────────────────────────────────────────────
-- The spec's rule: if the heartbeat trips the trigger, the SEED is wrong. It
-- tripped on four transitions, all of them real and all of them the office
-- acting for someone else:
--   • a delivery row created already assigned (the office assigns at creation),
--   • assigned -> out_for_delivery and out_for_delivery -> delivered driven by an
--     ADMIN, which is how a run is closed for a rider who has no app,
--   • an order created directly as accepted (an office-raised, already-paid order).
-- The trigger was right to refuse them; the table simply did not know them yet.
insert into public.order_state_transitions (entity_kind, from_state, to_state, actor_role, note) values
  ('order',   '',                'accepted',        'admin','Office raises an order that is already paid for.'),
  ('delivery','',                'assigned',        'admin','Office creates the run already assigned.'),
  ('delivery','',                'assigned',        'partner','Partner creates the run already assigned.'),
  ('delivery','assigned',        'out_for_delivery','admin','Office starts the run for a rider with no app.'),
  ('delivery','assigned',        'out_for_delivery','partner','Partner starts the run from the console.'),
  ('delivery','out_for_delivery','delivered',       'admin','Office closes the run for a rider with no app.'),
  ('delivery','out_for_delivery','delivered',       'partner','Partner closes the run from the console.'),
  ('delivery','',                'delivered',       'system','Back-dated import of a completed run.')
on conflict do nothing;

-- The seed now covers the whole canary path, so the machine is armed.
insert into public.app_settings(key, value)
values ('order_state_machine', jsonb_build_object('enforce', true))
on conflict (key) do update set value = excluded.value;


-- Undo the over-broad clear the first run of ops_state_sweep() performed before
-- the scope above existed: three bagged_uncounted findings that belong to
-- another sweep were closed by mistake. Re-open exactly those.
update public.ops_state_finding
   set cleared_at = null
 where rule_key not in ('order_state_unreachable','delivered_not_accepted',
                        'order_delivered_no_delivery','delivery_delivered_no_dispatch',
                        'delivery_ahead_of_order','order_closed_unbilled')
   and cleared_at is not null
   and cleared_at > now() - interval '2 hours';

-- ── 8. the agency lane (CHANGE #704), which the first seed under-read ───────
-- rg's own behaviour guards walk it, and they refused three transitions that
-- are entirely real: a delivery AGENCY accepts an offer under its own login
-- (which authorises as 'supplier'), the office accepts on the agency's behalf,
-- and an agency run closes straight from assigned to delivered — an agency has
-- no rider tapping "start run", so it never passes through out_for_delivery.
-- Same rule as the canary: the machine was right to refuse what it had not been
-- told; the table is what was wrong.
insert into public.order_state_transitions (entity_kind, from_state, to_state, actor_role, note) values
  ('delivery','agency_pending','assigned', 'supplier','delivery_respond — the agency accepted under its own login.'),
  ('delivery','agency_pending','assigned', 'admin',   'Office accepts on the agency''s behalf.'),
  ('delivery','agency_pending','assigned', 'partner', 'Partner accepts on the agency''s behalf.'),
  ('delivery','agency_pending','unassigned','supplier','The agency declined.'),
  ('delivery','assigned',      'delivered','system',  'agency_dispatch chain — an agency run has no rider start_run, so it closes straight from assigned.'),
  ('delivery','assigned',      'delivered','supplier','The agency reports the drop itself.'),
  ('delivery','assigned',      'failed',   'supplier','The agency reports a failed attempt.'),
  ('delivery','assigned',      'failed',   'system',  'Agency SLA expired on an accepted run.'),
  ('delivery','out_for_delivery','delivered','supplier','The agency closes a run it had started.'),
  ('delivery','assigned',        'out_for_delivery','supplier','The agency marks its own run as gone out.'),
  -- agency_dispatch_assign moves a RUNNING stop to another of the agency's own
  -- riders — custody is personal, so the stop drops back to 'assigned' and the
  -- previous rider's handover is cleared. A mid-run reassignment is the one
  -- place this machine legitimately steps backwards.
  ('delivery','out_for_delivery','assigned','supplier','agency_dispatch_assign — reassigned mid-run to another of the agency''s riders.'),
  ('delivery','out_for_delivery','assigned','admin',   'Office reassigns a running stop.'),
  ('delivery','out_for_delivery','assigned','partner', 'Partner reassigns a running stop.'),
  ('delivery','out_for_delivery','assigned','system',  'A wave or SLA tick moved a running stop.'),
  ('delivery','out_for_delivery','unassigned','supplier','The agency handed the stop back.'),
  ('delivery','failed',          'assigned','supplier','The agency sends its own failed stop out again.'),
  ('delivery','failed',          'assigned','admin',   'Office re-assigns a failed stop directly.'),
  ('delivery','failed',          'assigned','system',  'delivery_reattempt_tick re-assigns without unassigning first.')
on conflict do nothing;
