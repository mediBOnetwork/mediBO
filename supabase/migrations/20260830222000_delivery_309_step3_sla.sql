-- CHANGE #309 step 3 — PROMISED DELIVERY TIME (SLA).
--
-- The audit found no promised_at anywhere, which means nobody could answer the
-- two questions that matter most about a delivery operation: "when will it come"
-- (asked by the customer) and "did we keep our word" (asked by Om). Measuring
-- lateness needs a promise recorded BEFORE the outcome is known — computing it
-- afterwards from the delivery time would always score 100%.
--
-- The promise is stamped once, when the stop is assigned to a rider, from the
-- zone's configured window. It is never recomputed: a promise that moves is not
-- a promise. sla_state is derived, never stored, so a stop that is late RIGHT
-- NOW reads as late without a cron job having to notice.

alter table public.deliveries
  add column if not exists promised_at    timestamptz,
  add column if not exists promise_min    integer,
  add column if not exists arrived_at     timestamptz,     -- step 9 (geofence)
  add column if not exists arrived_lat    numeric,
  add column if not exists arrived_lng    numeric,
  add column if not exists arrival_notified_at timestamptz;

create index if not exists idx_deliveries_promised
  on public.deliveries(promised_at) where status in ('assigned','out_for_delivery');

-- ── Stamp the promise at assignment ─────────────────────────────────────────
-- A trigger rather than an edit to delivery_assign(), because a stop can also
-- be created by delivery_reassign(), by the offline replay path and by an admin
-- backfill. One rule at the table means none of those can forget it.
create or replace function public.trg_delivery_stamp_promise()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_win integer;
begin
  if new.promised_at is null and new.partner_id is not null then
    v_win := coalesce((public._dcfg(new.zone_id)->>'promise_window_min')::int, 240);
    new.promise_min := v_win;
    new.promised_at := coalesce(new.assigned_at, now()) + make_interval(mins => v_win);
  end if;
  return new;
end $function$;

drop trigger if exists trg_delivery_stamp_promise on public.deliveries;
create trigger trg_delivery_stamp_promise
  before insert or update of partner_id on public.deliveries
  for each row execute function public.trg_delivery_stamp_promise();

-- ── The one place lateness is decided ───────────────────────────────────────
-- Returns the render-ready block: the label the customer sees, the chip the
-- admin sees, and the tone. Nothing downstream re-derives any of it, so "late"
-- means the same thing on the rider's phone, the customer's tracking page and
-- the dashboard.
create or replace function public._sla_block(d public.deliveries)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_grace int := coalesce((public._dcfg(d.zone_id)->>'on_time_grace_min')::int, 15);
  v_due timestamptz := d.promised_at;
  v_end timestamptz;
  v_state text; v_chip text; v_tone jsonb; v_late_min int;
begin
  if v_due is null then
    return jsonb_build_object(
      'has', false,
      'label', public._c('delivery.promise_none'),
      'state', 'none');
  end if;

  v_end := v_due + make_interval(mins => v_grace);

  if d.status = 'delivered' then
    v_state := case when d.delivered_at <= v_end then 'on_time' else 'breached' end;
    v_late_min := greatest(0, ceil(extract(epoch from (d.delivered_at - v_due))/60))::int;
  elsif d.status in ('failed','rto','cancelled') then
    v_state := 'closed';
    v_late_min := 0;
  elsif now() > v_end then
    v_state := 'breached';
    v_late_min := ceil(extract(epoch from (now() - v_due))/60)::int;
  elsif now() > v_due - interval '30 minutes' then
    v_state := 'due_soon';
    v_late_min := 0;
  else
    v_state := 'pending';
    v_late_min := 0;
  end if;

  v_chip := case v_state
              when 'on_time'  then public._c('delivery.promise_ontime_chip')
              when 'breached' then public._c('delivery.promise_breached_chip')
              when 'due_soon' then public._c('delivery.promise_due_soon_chip')
              else '' end;

  -- Muted state colours, straight off the design system.
  v_tone := case v_state
              when 'on_time'  then jsonb_build_object('bg','#D1FAE5','fg','#065F46')
              when 'breached' then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
              when 'due_soon' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
              else jsonb_build_object('bg','#EFF6FF','fg','#1E40AF') end;

  return jsonb_build_object(
    'has', true,
    'state', v_state,
    'promised_at', v_due,
    'promise_label', public._c('delivery.promise_label'),
    'promised_label', to_char(v_due at time zone 'Asia/Kolkata','DD Mon, hh12:MI am'),
    'promised_time_label', to_char(v_due at time zone 'Asia/Kolkata','hh12:MI am'),
    'chip', v_chip,
    'chip_colors', v_tone,
    'late_minutes', v_late_min,
    'is_breached', (v_state = 'breached'));
end $function$;

-- ── Backfill the promise for stops already in flight ────────────────────────
-- Without this the dashboard would report every live stop as "no promise" for
-- the first four hours after the deploy, which reads as a broken feature.
update public.deliveries d
   set promise_min = coalesce((public._dcfg(d.zone_id)->>'promise_window_min')::int, 240),
       promised_at = coalesce(d.assigned_at, d.created_at)
                     + make_interval(mins => coalesce((public._dcfg(d.zone_id)->>'promise_window_min')::int, 240))
 where d.promised_at is null
   and d.partner_id is not null;
