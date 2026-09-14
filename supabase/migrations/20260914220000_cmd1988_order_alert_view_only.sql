-- CMD #1988 — the new-order alert becomes VIEW-ONLY and SINGLE-SURFACE.
--
-- Om, 14 Sep, order CPO140926CHA101O1: a lock-screen alert WITH Accept/Reject,
-- a SECOND in-app centre dialog on the admin screen that would not go silent,
-- and the whole thing arrived late. Every one of those is fixed here, in the
-- backend, because every one of them is a backend decision:
--
--  1. ONE surface      — the app no longer draws a centre dialog. The strip it
--                        draws instead is order_alert_strip(), below.
--  2. VIEW-ONLY        — the push payload no longer carries an action token or
--                        the accept/reject labels, so the Android notification
--                        (which gates its buttons on exactly those two fields)
--                        offers nothing but "open the order". A decision is
--                        taken on the order screen, next to the items.
--  3. PREPAID RINGS    — a paid order used to be born 'accepted' with ring
--                        false and was never heard. It rings now, same tone,
--                        same channel. Only quiet hours / a snoozed device
--                        silence it, and a silenced alert still LANDS.
--  4. STOP ON OPEN     — opening the order anywhere stamps opened_at, which
--                        suppresses every further ring until rering_after_s
--                        has passed with the order still unactioned.
--  5. ON INSERT        — the trigger pushes immediately instead of waiting for
--                        the next poller tick past ring_delay_s (now 0).
--  6. PER-DEVICE MUTE  — order_alert_device rows are per (user, device), so a
--                        snooze on one phone is not a global mute.
--
-- Idempotent: every object is create-if-missing / create-or-replace.

-- ── 1. SCHEMA ───────────────────────────────────────────────────────────────

alter table public.order_alert
  add column if not exists opened_at     timestamptz,
  add column if not exists opened_by     uuid,
  add column if not exists opened_source text,
  add column if not exists silenced_for  jsonb not null default '{}'::jsonb;

create index if not exists order_alert_opened_idx
  on public.order_alert (opened_at) where state = 'ringing';

-- Per-DEVICE snooze, stored per user. Not a global mute: the row is keyed by
-- the device that asked for quiet, so the admin's other phone still rings.
create table if not exists public.order_alert_device (
  user_id      uuid        not null,
  device_id    text        not null,
  device_label text,
  snooze_until timestamptz,
  updated_at   timestamptz not null default now(),
  primary key (user_id, device_id)
);

alter table public.order_alert_device enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='order_alert_device'
                    and policyname='order_alert_device_own') then
    create policy order_alert_device_own on public.order_alert_device
      for all to authenticated
      using (user_id = auth.uid()) with check (user_id = auth.uid());
  end if;
end $$;

revoke all on public.order_alert_device from anon;

-- The config singleton must exist before a label can be merged into it.
insert into public.order_alert_config (id) values ('singleton')
on conflict (id) do nothing;

-- Item 5: the customer alert waits for nothing.
update public.order_alert_config
   set ring_delay_s = 0
 where id = 'singleton' and coalesce(ring_delay_s, 0) <> 0;

-- ── 2. LABELS ───────────────────────────────────────────────────────────────
-- Merged, never replaced: a label this build does not know about survives.

update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb) || jsonb_build_object(
     'strip_title_one',  'New order awaiting you',
     'strip_title_many', '{{count}} new orders awaiting you',
     'strip_subtitle',   '{{customer}} · {{amount}} · {{items}} · {{age}}',
     'strip_action',     'Open order',
     'strip_more',       '+{{count}} more',
     'open_label',       'Open order',
     'items_one',        '1 item',
     'items_many',       '{{count}} items',
     'items_none',       'No items',
     'push_view_only_note', 'Open the order to accept or reject it',
     'quiet_title',      'Quiet hours',
     'quiet_subtitle',   'Alerts still arrive during these hours — they just do not ring.',
     'quiet_from_label', 'Quiet from',
     'quiet_to_label',   'Quiet until',
     'quiet_off_label',  'Quiet hours are off',
     'quiet_saved',      'Quiet hours saved',
     'snooze_title',     'Snooze this device',
     'snooze_subtitle',  'Silences alerts on this device only. Your other devices still ring.',
     'snooze_active',    'This device is snoozed until {{until}}',
     'snooze_off',       'This device is not snoozed',
     'snooze_saved',     'This device is snoozed until {{until}}',
     'snooze_cleared',   'This device will ring again',
     'snooze_30',        '30 minutes',
     'snooze_60',        '1 hour',
     'snooze_240',       '4 hours',
     'snooze_clear',     'Ring again now',
     'seen_toast',       'Alert cleared — this order is open',
     'strip_prepaid',    'Paid',
     'strip_unpaid',     'Unpaid')
 where id = 'singleton';

-- ── 3. HELPERS ──────────────────────────────────────────────────────────────

-- How many lines this order has. One number, one place.
create or replace function public._oa_item_count(p_order_id uuid)
returns integer language sql stable security definer set search_path to 'public'
as $$
  select coalesce((select count(*)::int from public.order_items oi
                    where oi.order_id = p_order_id), 0)
$$;

create or replace function public._oa_items_label(p_order_id uuid)
returns text language sql stable security definer set search_path to 'public'
as $$
  select case
    when public._oa_item_count(p_order_id) = 0 then public.oa_label('items_none')
    when public._oa_item_count(p_order_id) = 1 then public.oa_label('items_one')
    else public.oa_label('items_many',
           jsonb_build_object('count', public._oa_item_count(p_order_id)::text))
  end
$$;

-- Is this alert currently suppressed for this user/device?
--   * quiet hours  → still delivered, never rings
--   * device snooze→ still delivered, never rings on THAT device
create or replace function public._oa_silent_for(p_user_id uuid, p_device_id text default null)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select public.notif_user_in_quiet(p_user_id)
      or coalesce((select d.snooze_until > now()
                     from public.order_alert_device d
                    where d.user_id = p_user_id
                      and (p_device_id is null or d.device_id = p_device_id)
                    order by d.snooze_until desc nulls last
                    limit 1), false)
$$;

-- Stop-on-open: an alert opened less than rering_after_s ago is quiet.
create or replace function public._oa_open_quiet(a public.order_alert)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select a.opened_at is not null
     and a.actioned_at is null
     and now() - a.opened_at < make_interval(secs => greatest(
           coalesce((select rering_after_s from public.order_alert_config
                      where id='singleton'), 120), 15))
$$;

-- ── 4. RAISE — prepaid rings too, and the ring starts on INSERT ─────────────

create or replace function public.order_alert_raise(p_order_id uuid)
returns bigint language plpgsql security definer set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; o public.orders%rowtype;
  v_credit jsonb; v_id bigint; v_name text; v_zone smallint; v_partner bigint;
  v_paid boolean;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled, false) then return null; end if;

  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''),
                  nullif(btrim(o.pharmacy_name),''), ''),
         coalesce(o.zone_id, pp.zone_id)
    into v_name, v_zone
    from public.pharmacy_profiles pp where pp.id = o.customer_id;
  v_name := coalesce(nullif(btrim(coalesce(v_name, o.pharmacy_name, '')),''), o.pharmacy_name, '');
  v_zone := coalesce(v_zone, o.zone_id);

  select rp.id into v_partner from public.region_partners rp
   where rp.zone_id = v_zone and coalesce(rp.is_active,true) order by rp.id limit 1;

  v_credit := public.customer_credit_state(o.customer_id);
  v_paid   := public.order_is_paid(o.id);

  -- CMD #1988 — a paid order is no longer born 'accepted' and silent. Money in
  -- the account is not the same as an order somebody has looked at, and the
  -- whole point of the alert is that somebody looks. Same state, same ring,
  -- same channel for both; `risk` still says which is which.
  insert into public.order_alert
    (order_id, order_code, customer_id, customer_name, amount, risk, state, stage,
     credit_blocked, credit_note, expires_at, ring, zone_id, partner_id, audience)
  values
    (o.id, coalesce(o.order_code, o.payment_id, ''), o.customer_id, v_name,
     coalesce(o.total_amount, 0),
     case when v_paid then 'prepaid' else 'unpaid' end,
     'ringing', 'new',
     coalesce((v_credit->>'blocked')::boolean, false) and not v_paid,
     case when v_paid then null else nullif(v_credit->>'message','') end,
     now() + make_interval(mins => greatest(cfg.autocancel_after_min, 1)),
     true,
     v_zone, v_partner,
     case when v_partner is not null and coalesce(cfg.partner_ring_first,true)
          then 'partner' else 'admin' end)
  on conflict (order_id) do nothing
  returning id into v_id;

  return v_id;
end $function$;

create or replace function public.trg_order_alert_raise()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_id bigint;
begin
  -- An alert must never be able to fail an order placement.
  begin
    v_id := public.order_alert_raise(new.id);
    -- CMD #1988 item 5 — FIRE ON INSERT. The first ring used to wait for the
    -- next order_alert_tick() past ring_delay_s, which is why Om's alert was
    -- late. pg_net's http_post only enqueues, so this costs the INSERT nothing.
    if v_id is not null then
      perform public.order_alert_push(v_id, 'new');
    end if;
  exception when others then null;
  end;
  return null;
end $function$;

-- ── 5. ITEM — one card shape, ring no longer excludes prepaid ──────────────

create or replace function public._oa_item(a public.order_alert)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare cfg public.order_alert_config; v_credit jsonb; v_paid boolean; v_age text;
begin
  cfg    := public._oa_cfg();
  v_paid := public.order_is_paid(a.order_id);
  v_credit := public.customer_credit_state(a.customer_id);
  v_age  := public._oa_age_label(a.created_at);

  return jsonb_build_object(
    'alert_id',        a.id,
    'order_id',        a.order_id,
    'order_code',      coalesce(a.order_code,''),
    'customer',        coalesce(a.customer_name,''),
    'amount_display',  public.inr_money(a.amount),
    'age_label',       v_age,
    'item_count',      public._oa_item_count(a.order_id),
    'items_label',     public._oa_items_label(a.order_id),
    'state',           a.state,
    'state_label',     public.oa_label('state_' || a.state),
    'stage',           a.stage,
    'stage_label',     public.oa_label('stage_' || a.stage),
    'risk',            case when v_paid then 'prepaid' else 'unpaid' end,
    'risk_label',      public.oa_label(case when v_paid then 'risk_prepaid' else 'risk_unpaid' end),
    'paid',            v_paid,
    -- CMD #1988 — prepaid rings. What silences a ring now is the admin's own
    -- quiet hours, their device's snooze, or the order already being open.
    'ring',            a.ring and a.state = 'ringing'
                         and not public._oa_open_quiet(a)
                         and not public._oa_silent_for(auth.uid(), null),
    'opened',          a.opened_at is not null,
    'critical',        a.stage = 'critical',
    'banner',          case
                         when v_paid then public.oa_label('banner_prepaid')
                         when a.stage = 'critical'
                           then public.oa_label('banner_critical', jsonb_build_object('age', v_age))
                         else public.oa_label('banner_unpaid') end,
    'credit_blocked',  coalesce((v_credit->>'blocked')::boolean,false) and not v_paid,
    'credit_note',     case when v_paid then '' else coalesce(v_credit->>'message','') end,
    'credit',          v_credit,
    'can_accept',      a.state = 'ringing'
                         and not (coalesce((v_credit->>'blocked')::boolean,false) and not v_paid),
    'can_reject',      a.state = 'ringing',
    'accept_label',    public.oa_label('accept_label'),
    'reject_label',    public.oa_label('reject_label'),
    'dismiss_label',   public.oa_label('dismiss_label'),
    'view_label',      public.oa_label('view_label'),
    'open_label',      public.oa_label('open_label'),
    'accept_note',     case when coalesce((v_credit->>'blocked')::boolean,false) and not v_paid
                            then public.oa_label('accept_note_blocked')
                            else public.oa_label('accept_note') end,
    'reject_note',     public.oa_label('reject_note'),
    'override_label',  public.oa_label('override_label'),
    'override_hint',   public.oa_label('override_hint'),
    'actioned_by',     coalesce(a.actioned_by_label,''),
    'push_count',      a.push_count);
end $function$;

-- ── 6. THE SLIM STRIP — the ONLY in-app surface for an unactioned order ────
-- Every string is decided here. The app draws the strip and nothing else: no
-- centre dialog, no second interrupt, no client-side plural or arithmetic.

create or replace function public.order_alert_strip()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare cfg public.order_alert_config; a public.order_alert%rowtype;
        v_count int; v_paid boolean; v_age text; v_ring boolean;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'show', false, 'count', 0);
  end if;
  cfg := public._oa_cfg();

  select count(*)::int into v_count
    from public.order_alert al
   where al.state = 'ringing' and public._oa_visible(al.zone_id);

  if v_count = 0 then
    return jsonb_build_object('ok', true, 'show', false, 'count', 0,
                              'ring', false, 'poll_s', 20);
  end if;

  select * into a from public.order_alert al
   where al.state = 'ringing' and public._oa_visible(al.zone_id)
   order by al.created_at asc limit 1;

  v_paid := public.order_is_paid(a.order_id);
  v_age  := public._oa_age_label(a.created_at);
  v_ring := a.ring
              and not public._oa_open_quiet(a)
              and not public._oa_silent_for(auth.uid(), null);

  return jsonb_build_object(
    'ok',           true,
    'show',         true,
    'count',        v_count,
    'alert_id',     a.id,
    'order_id',     a.order_id,
    'order_code',   coalesce(a.order_code,''),
    'title',        case when v_count = 1 then public.oa_label('strip_title_one')
                         else public.oa_label('strip_title_many',
                                jsonb_build_object('count', v_count::text)) end,
    'subtitle',     public.oa_label('strip_subtitle', jsonb_build_object(
                      'customer', coalesce(a.customer_name,''),
                      'amount',   public.inr_money(a.amount),
                      'items',    public._oa_items_label(a.order_id),
                      'age',      v_age)),
    'action_label', public.oa_label('strip_action'),
    'more_label',   case when v_count > 1
                         then public.oa_label('strip_more',
                                jsonb_build_object('count', (v_count-1)::text))
                         else '' end,
    'risk',         case when v_paid then 'prepaid' else 'unpaid' end,
    'risk_label',   public.oa_label(case when v_paid then 'strip_prepaid' else 'strip_unpaid' end),
    'paid',         v_paid,
    'age_label',    v_age,
    'tone',         case when a.stage = 'critical' then 'danger'
                         when v_paid then 'info' else 'warning' end,
    'ring',         v_ring,
    'ring_seconds', cfg.ring_seconds,
    'opened',       a.opened_at is not null,
    'poll_s',       20);
end $function$;

-- ── 7. STOP ON OPEN ────────────────────────────────────────────────────────
-- The moment ANY device or surface opens the order, the ring stops and the
-- alert clears everywhere. It is one stamp on one row, so "everywhere" is free.

create or replace function public.order_alert_seen(p_order_id uuid,
                                                   p_source text default 'app')
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare a public.order_alert%rowtype;
begin
  if public.get_my_role() not in ('admin','super_admin','partner') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select * into a from public.order_alert where order_id = p_order_id;
  if a.id is null or not public._oa_visible(a.zone_id) then
    return jsonb_build_object('ok', true, 'cleared', false, 'strip',
                              public.order_alert_strip());
  end if;
  if a.opened_at is null then
    update public.order_alert
       set opened_at = now(), opened_by = auth.uid(),
           opened_source = coalesce(nullif(btrim(p_source),''),'app')
     where id = a.id;
  end if;
  return jsonb_build_object(
    'ok', true, 'cleared', true, 'alert_id', a.id,
    'message', public.oa_label('seen_toast'),
    'strip',   public.order_alert_strip());
end $function$;

-- ── 8. PER-DEVICE SNOOZE + PER-USER QUIET HOURS ───────────────────────────
-- Stored per user, keyed by device. Never one global mute.

create or replace function public.order_alert_my_prefs(p_device_id text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare q public.user_notify_quiet%rowtype; d public.order_alert_device%rowtype;
        v_snoozed boolean; v_until text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in');
  end if;
  select * into q from public.user_notify_quiet where user_id = auth.uid();
  if p_device_id is not null then
    select * into d from public.order_alert_device
     where user_id = auth.uid() and device_id = p_device_id;
  end if;
  v_snoozed := d.snooze_until is not null and d.snooze_until > now();
  v_until   := case when v_snoozed
                    then to_char(d.snooze_until at time zone 'Asia/Kolkata', 'HH12:MI AM')
                    else '' end;

  return jsonb_build_object(
    'ok', true,
    'quiet', jsonb_build_object(
      'title',      public.oa_label('quiet_title'),
      'subtitle',   public.oa_label('quiet_subtitle'),
      'from_label', public.oa_label('quiet_from_label'),
      'to_label',   public.oa_label('quiet_to_label'),
      'off_label',  public.oa_label('quiet_off_label'),
      'enabled',    q.quiet_from is not null and q.quiet_to is not null,
      'from',       coalesce(to_char(q.quiet_from, 'HH24:MI'), ''),
      'to',         coalesce(to_char(q.quiet_to,   'HH24:MI'), ''),
      'active_now', public.notif_user_in_quiet(auth.uid())),
    'snooze', jsonb_build_object(
      'title',      public.oa_label('snooze_title'),
      'subtitle',   public.oa_label('snooze_subtitle'),
      'active',     v_snoozed,
      'until',      v_until,
      'status',     case when v_snoozed
                         then public.oa_label('snooze_active', jsonb_build_object('until', v_until))
                         else public.oa_label('snooze_off') end,
      'options',    jsonb_build_array(
        jsonb_build_object('minutes', 30,  'label', public.oa_label('snooze_30')),
        jsonb_build_object('minutes', 60,  'label', public.oa_label('snooze_60')),
        jsonb_build_object('minutes', 240, 'label', public.oa_label('snooze_240')),
        jsonb_build_object('minutes', 0,   'label', public.oa_label('snooze_clear')))));
end $function$;

create or replace function public.order_alert_snooze_set(p_device_id text,
                                                         p_minutes int,
                                                         p_device_label text default null)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_until timestamptz; v_label text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in');
  end if;
  if coalesce(btrim(p_device_id),'') = '' then
    return jsonb_build_object('ok', false, 'error','no_device');
  end if;
  v_until := case when coalesce(p_minutes,0) > 0
                  then now() + make_interval(mins => least(p_minutes, 720))
                  else null end;
  insert into public.order_alert_device (user_id, device_id, device_label, snooze_until, updated_at)
  values (auth.uid(), btrim(p_device_id), nullif(btrim(p_device_label),''), v_until, now())
  on conflict (user_id, device_id) do update
    set snooze_until = excluded.snooze_until,
        device_label = coalesce(excluded.device_label, public.order_alert_device.device_label),
        updated_at   = now();

  v_label := case when v_until is null then public.oa_label('snooze_cleared')
                  else public.oa_label('snooze_saved', jsonb_build_object(
                         'until', to_char(v_until at time zone 'Asia/Kolkata','HH12:MI AM'))) end;
  return jsonb_build_object('ok', true, 'message', v_label,
                            'prefs', public.order_alert_my_prefs(p_device_id));
end $function$;

create or replace function public.order_alert_quiet_set(p_from text, p_to text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_from time; v_to time;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in');
  end if;
  v_from := nullif(btrim(coalesce(p_from,'')),'')::time;
  v_to   := nullif(btrim(coalesce(p_to,'')),'')::time;
  if v_from is null or v_to is null then
    delete from public.user_notify_quiet where user_id = auth.uid();
  else
    insert into public.user_notify_quiet (user_id, quiet_from, quiet_to, updated_at)
    values (auth.uid(), v_from, v_to, now())
    on conflict (user_id) do update
      set quiet_from = excluded.quiet_from, quiet_to = excluded.quiet_to,
          updated_at = now();
  end if;
  return jsonb_build_object('ok', true,
                            'message', public.oa_label('quiet_saved'),
                            'prefs',   public.order_alert_my_prefs(null));
end $function$;

-- ── 9. THE PUSH — VIEW-ONLY, and silent (never absent) in quiet hours ──────
--
-- The Android notification builds its Accept / Reject buttons ONLY when the
-- payload carries both `action_token` and `action_url` (OrderAlert.kt). Those
-- two fields are gone from here, so the alert on the phone Om is holding right
-- now — no Play release needed — offers one thing: open the order.

create or replace function public.order_alert_push_raw(p_alert_id bigint,
                                                       p_kind text default 'new',
                                                       p_audience text default null)
returns jsonb language plpgsql security definer set search_path to 'public', 'net'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype; u record;
  v_vars jsonb; v_title text; v_body text; v_count int;
  v_log bigint; v_req bigint; v_sent int := 0; v_alert jsonb; v_ongoing text;
  v_aud text; v_deep text; v_uids uuid[]; v_paid boolean; v_silent boolean;
  v_items text; v_icount int; v_silenced int := 0;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', false, 'reason','alerts_disabled');
  end if;
  select * into a from public.order_alert where id = p_alert_id;
  if a.id is null then return jsonb_build_object('ok', false, 'reason','no_alert'); end if;
  -- CMD #1848 — a human test session's rows never leave the building.
  if public.test_outbound_silenced(a.test_session_id) or public.test_order_silenced(a.order_id) then
    return jsonb_build_object('ok', false, 'reason','test_mode_silenced');
  end if;
  if a.state <> 'ringing' or not a.ring then
    return jsonb_build_object('ok', false, 'reason','not_ringing');
  end if;
  -- CMD #1988 item 4 — somebody has the order open. Nothing is sent until the
  -- re-ring window has passed with the order still unactioned.
  if public._oa_open_quiet(a) then
    return jsonb_build_object('ok', true, 'reason','opened_elsewhere', 'devices', 0);
  end if;

  v_aud := coalesce(nullif(btrim(p_audience),''), public._oa_audience(a));
  v_deep := case when v_aud = 'partner' then '/partner' else '/admin/order-alerts' end;
  if v_aud = 'partner' then
    v_uids := public._oa_partner_user_ids(a.partner_id);
    if coalesce(array_length(v_uids,1),0) = 0 then
      v_aud := 'admin';
      v_deep := '/admin/order-alerts';
    end if;
  end if;

  v_paid   := public.order_is_paid(a.order_id);
  v_icount := public._oa_item_count(a.order_id);
  v_items  := public._oa_items_label(a.order_id);

  v_count := (select count(*)::int from public.order_alert al
               where al.state = 'ringing'
                 and (v_aud <> 'partner' or al.partner_id = a.partner_id));
  v_vars := jsonb_build_object(
    'customer',   coalesce(a.customer_name,''),
    'order_code', coalesce(a.order_code,''),
    'amount',     public.inr_money(a.amount),
    'age',        public._oa_age_label(a.created_at),
    'items',      v_items,
    'count',      v_count::text);

  v_title := public.oa_label(case when p_kind='critical' then 'push_title_critical'
                                  else 'push_title' end, v_vars);
  v_body  := public.oa_label(case when p_kind='critical' then 'push_body_critical'
                                  else 'push_body' end, v_vars);
  v_ongoing := case when v_count = 1 then public.oa_label('ongoing_title_one', v_vars)
                    else public.oa_label('ongoing_title', v_vars) end;

  for u in
    select t.user_id, min(t.phone10) as phone10, jsonb_agg(distinct t.token) tokens
      from public.push_tokens t
     where t.is_active and t.user_id is not null
       and ( (v_aud = 'partner' and t.user_id = any (v_uids))
          or (v_aud <> 'partner' and t.role in ('admin','super_admin')) )
     group by t.user_id
  loop
    -- CMD #1988 item 3 + 6 — quiet hours and a snoozed device SILENCE the
    -- alert for this recipient. They never withhold it: it still lands, it
    -- still opens the order, it just does not make a sound.
    v_silent := public._oa_silent_for(u.user_id, null);
    if v_silent then v_silenced := v_silenced + 1; end if;

    insert into public.notification_log
      (event_key, recipient, channel, status, ok, audience, recipient_id, user_id,
       order_id, customer_id, title, body, deep_link, language, vars, payload, path)
    values
      ('order_alert_new',
       coalesce(nullif(btrim(u.phone10),''), u.user_id::text),
       'push', 'queued', null, v_aud, u.user_id, u.user_id,
       a.order_id, a.customer_id, v_title, v_body, v_deep, 'en',
       v_vars, jsonb_build_object('alert_id', a.id, 'kind', p_kind, 'audience', v_aud,
                                  'silent', v_silent, 'view_only', true), 'push')
    returning id into v_log;

    v_alert := jsonb_build_object(
      'kind',                'order_alert',
      'alert_id',            a.id,
      'push_title',          v_title,
      'push_body',           v_body,
      'order_id',            a.order_id,
      'order_code',          coalesce(a.order_code,''),
      'customer',            coalesce(a.customer_name,''),
      'amount',              public.inr_money(a.amount),
      'item_count',          v_icount,
      'items_label',         v_items,
      'age_label',           public._oa_age_label(a.created_at),
      'paid',                v_paid,
      'risk',                case when v_paid then 'prepaid' else 'unpaid' end,
      'risk_label',          public.oa_label(case when v_paid then 'strip_prepaid'
                                                  else 'strip_unpaid' end),
      'critical',            (p_kind = 'critical'),
      'credit_note',         coalesce(a.credit_note,''),
      'credit_blocked',      a.credit_blocked,
      'audience',            v_aud,
      -- ONE action, and it only opens the order. No accept_label, no
      -- reject_label, no action_token, no action_url — a decision is never
      -- taken from a notification (CMD #1988 item 2).
      'view_only',           true,
      'open_label',          public.oa_label('open_label'),
      'view_only_note',      public.oa_label('push_view_only_note'),
      'deep_link',           v_deep,
      'channel_id',          'medibo_order_alert',
      'channel_name',        public.oa_label('channel_name'),
      'channel_description', public.oa_label('channel_description'),
      'silent',              v_silent,
      'ring_seconds',        case when v_silent then 0 else cfg.ring_seconds end,
      'full_screen',         true,
      'pending_count',       v_count,
      'ongoing_title',       v_ongoing,
      'ongoing_body',        public.oa_label('ongoing_body'));

    select net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/push-send',
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('log_id', v_log, 'tokens', u.tokens,
                                    'title', v_title, 'body', v_body,
                                    'deep_link', v_deep,
                                    'event_key', 'order_alert_new',
                                    'order_id', a.order_id,
                                    'alert', v_alert),
      timeout_milliseconds := 20000) into v_req;
    v_sent := v_sent + 1;
  end loop;

  update public.order_alert
     set push_count    = push_count + 1,
         last_push_at  = now(),
         first_push_at = coalesce(first_push_at, now()),
         audience      = v_aud,
         partner_push_count = partner_push_count + case when v_aud='partner' then 1 else 0 end,
         partner_first_push_at = case when v_aud='partner'
                                      then coalesce(partner_first_push_at, now())
                                      else partner_first_push_at end
   where id = a.id;

  if v_sent = 0 then
    return jsonb_build_object('ok', false, 'audience', v_aud,
      'reason', case when v_aud='partner' then 'no_partner_device' else 'no_admin_device' end);
  end if;
  return jsonb_build_object('ok', true, 'devices', v_sent, 'silenced', v_silenced,
                            'view_only', true, 'kind', p_kind, 'audience', v_aud);
end $function$;

-- ── 10. THE TICK — prepaid keeps ringing, an open order does not ───────────

create or replace function public.order_alert_tick()
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  cfg public.order_alert_config; a public.order_alert%rowtype;
  v_age int; v_paid int := 0; v_rang int := 0; v_wa int := 0;
  v_crit int := 0; v_cancel int := 0; v_esc int := 0; v_partner int := 0;
  v_quiet int := 0;
  v_phone text; v_mail text; v_vars jsonb; v_res jsonb;
begin
  cfg := public._oa_cfg();
  if not coalesce(cfg.enabled,false) then
    return jsonb_build_object('ok', true, 'skipped','disabled');
  end if;

  for a in select * from public.order_alert where state = 'ringing' order by created_at
  loop
    v_age := greatest(extract(epoch from (now() - a.created_at))::int, 0);

    -- CMD #1988 — a paid order is NO LONGER auto-accepted here. Payment is not
    -- a decision; somebody still has to look at the order. It rings like any
    -- other until a human opens it and accepts or rejects it on the order
    -- screen. What payment DOES buy it is safety from the auto-cancel below.

    -- An alert that does not ring (the pre-#306 backfill) is excluded from
    -- every ringing rung below.
    if not a.ring then continue; end if;

    -- CMD #1988 item 4 — STOP ON OPEN. Somebody has this order open on some
    -- device: no ring, no escalation, no WhatsApp, until the re-ring window
    -- has passed with the order still unactioned.
    if public._oa_open_quiet(a) then
      v_quiet := v_quiet + 1;
      continue;
    end if;

    -- Out of time — cancel and release whatever it was holding. Never for an
    -- order the customer has already paid for.
    if a.expires_at is not null and now() >= a.expires_at then
      if public.order_is_paid(a.order_id) then
        v_paid := v_paid + 1;
      else
        update public.order_alert
           set state='auto_cancelled', ring=false, actioned_at=now(),
               actioned_by_label='auto', action_source='auto',
               action_reason='autocancel_window'
         where id = a.id;
        perform public._oa_release_and_cancel(a.order_id,
          public.oa_label('auto_cancel_reason',
            jsonb_build_object('window', cfg.autocancel_after_min::text)),
          'order_alert_auto');
        v_cancel := v_cancel + 1;
        continue;
      end if;
    end if;

    -- First ring. ring_delay_s is 0 now and the trigger already fired on
    -- insert, so this rung only catches an alert whose insert-time push failed.
    if a.push_count = 0 then
      if v_age >= coalesce(cfg.ring_delay_s, 0) then
        v_res := public.order_alert_push(a.id, 'new');
        if coalesce(v_res->>'audience','') = 'partner' then v_partner := v_partner + 1; end if;
        v_rang := v_rang + 1;
      end if;
      continue;
    end if;

    -- ESCALATION. The partner was rung and nobody accepted inside the window,
    -- so the admin becomes the audience from here on.
    if a.audience = 'partner' and a.escalated_at is null
       and v_age >= greatest(coalesce(cfg.ring_delay_s,0),0) + greatest(cfg.partner_escalate_after_s,15) then
      update public.order_alert set escalated_at = now(), audience = 'admin' where id = a.id;
      perform public.order_alert_push(a.id,
        case when a.stage = 'critical' then 'critical' else 'new' end, 'admin');
      v_esc := v_esc + 1;
      continue;
    end if;

    -- Critical.
    if v_age >= cfg.critical_after_s and a.stage <> 'critical' then
      update public.order_alert set stage='critical', critical_at=now() where id = a.id;
      perform public.order_alert_push(a.id, 'critical');
      v_crit := v_crit + 1;
      continue;
    end if;

    -- Reach the admin off-device: WhatsApp and email, neither able to break
    -- the tick. An order that is already paid for is not chased off-device.
    if v_age >= cfg.wa_after_s and a.wa_sent_at is null
       and not public.order_is_paid(a.order_id) then
      v_vars := jsonb_build_object(
        'customer',   coalesce(a.customer_name,''),
        'order_code', coalesce(a.order_code,''),
        'amount',     public.inr_money(a.amount),
        'age',        public._oa_age_label(a.created_at),
        'order_id',   a.order_id::text,
        '_no_push',   true);
      foreach v_phone in array coalesce(public._oa_admin_phones(), '{}'::text[])
      loop
        begin
          perform public.notify('order_alert_escalation', v_phone, v_vars);
        exception when others then null;
        end;
      end loop;
      foreach v_mail in array coalesce(public._oa_admin_emails(), '{}'::text[])
      loop
        begin
          perform public.notif_send_email('order_alert_escalation', v_mail,
                    v_vars - '_no_push', null, a.order_id);
        exception when others then null;
        end;
      end loop;
      update public.order_alert set wa_sent_at=now(), stage='whatsapp' where id = a.id;
      v_wa := v_wa + 1;
      continue;
    end if;

    -- Keep ringing — this is also the re-ring an opened-but-unactioned order
    -- gets once its quiet window above has expired.
    if a.last_push_at is not null
       and now() - a.last_push_at >= make_interval(secs => greatest(cfg.rering_after_s,15))
       and a.push_count < 30 then
      perform public.order_alert_push(a.id,
        case when a.stage = 'critical' then 'critical' else 'new' end);
      if a.stage = 'new' then
        update public.order_alert set stage='rering' where id = a.id;
      end if;
      v_rang := v_rang + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'paid_held', v_paid, 'rang', v_rang,
                            'partner_rings', v_partner, 'escalated', v_esc,
                            'open_quiet', v_quiet,
                            'whatsapp', v_wa, 'critical', v_crit,
                            'auto_cancelled', v_cancel);
end $function$;

-- ── 11. GRANTS — a new SECURITY DEFINER function inherits PUBLIC EXECUTE ──
-- (standing lesson 122: revoke by pattern, not by name). None of these is
-- public: every one of them answers for the signed-in admin or nobody.

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'order_alert%' or p.proname like '\_oa\_%')
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;
