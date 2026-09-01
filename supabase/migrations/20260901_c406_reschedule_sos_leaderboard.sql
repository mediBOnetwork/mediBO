-- CHANGE #406 — three verified-absent pieces on the delivery surface:
--   1. the CUSTOMER's half of a failed delivery (delivery_respond is the
--      rider's accept/reject; the customer had nothing at all),
--   2. a rider SOS button,
--   3. a rider leaderboard.
--
-- Gap check first (rule 11), against the live catalog on 2026-09-01:
--   * no reschedule / reattempt / wave RPC of any kind exists;
--   * `deliveries.next_attempt_on` is WRITTEN by delivery_fail() and READ BY
--     NOTHING — admin_delivery_queue() is scoped to orders created on the
--     chosen date, so a stop failed on Monday for Tuesday never reappears.
--     A reschedule that only writes that column would be a no-op with a
--     confirmation toast, so this change also makes the column feed planning;
--   * no sos table, function or notify route;
--   * no leaderboard, and no per-agency ranking flag.
--
-- Everything user-visible is backend copy (ui_copy, read through _c/_cf) and
-- every rule is a config row, so a window, a cap or a label changes with an
-- UPDATE rather than a deploy.

-- ═════════════════════════════════════════════════════════════════════════
-- PART 1 — CUSTOMER RESCHEDULE
-- ═════════════════════════════════════════════════════════════════════════

create table if not exists public.delivery_reschedule_config (
  id                smallint primary key default 1,
  enabled           boolean not null default true,
  max_per_delivery  int     not null default 2,
  days_ahead        int     not null default 3,
  updated_at        timestamptz not null default now(),
  constraint delivery_reschedule_config_singleton check (id = 1)
);
insert into public.delivery_reschedule_config(id) values (1) on conflict (id) do nothing;

create table if not exists public.delivery_reschedule_window (
  key        text primary key,
  label      text not null,
  from_time  time,
  to_time    time,
  sort       int  not null default 0,
  active     boolean not null default true
);

insert into public.delivery_reschedule_window(key, label, from_time, to_time, sort) values
  ('morning',   'Morning · 9 AM – 1 PM',    '09:00', '13:00', 10),
  ('afternoon', 'Afternoon · 1 PM – 5 PM',  '13:00', '17:00', 20),
  ('evening',   'Evening · 5 PM – 8 PM',    '17:00', '20:00', 30),
  ('anytime',   'Any time that day',        null,    null,    40)
on conflict (key) do update
  set label = excluded.label, from_time = excluded.from_time,
      to_time = excluded.to_time, sort = excluded.sort;

create table if not exists public.delivery_reschedule (
  id             bigserial primary key,
  delivery_id    uuid not null references public.deliveries(id) on delete cascade,
  order_id       uuid,
  customer_id    uuid,
  requested_date date not null,
  window_key     text,
  window_label   text,
  source         text not null default 'order_screen',
  created_by     uuid,
  created_at     timestamptz not null default now()
);
create index if not exists delivery_reschedule_delivery_idx
  on public.delivery_reschedule(delivery_id, created_at desc);

-- The delivery carries the ANSWER, so planning reads one row and never joins.
alter table public.deliveries add column if not exists reattempt_window_key   text;
alter table public.deliveries add column if not exists reattempt_window_label text;
alter table public.deliveries add column if not exists reattempt_from         time;
alter table public.deliveries add column if not exists reattempt_to           time;
alter table public.deliveries add column if not exists reschedule_count       int not null default 0;
alter table public.deliveries add column if not exists reschedule_escalated_at timestamptz;
alter table public.deliveries add column if not exists rescheduled_at         timestamptz;

alter table public.delivery_reschedule_config enable row level security;
alter table public.delivery_reschedule_config force  row level security;
alter table public.delivery_reschedule_window enable row level security;
alter table public.delivery_reschedule_window force  row level security;
alter table public.delivery_reschedule        enable row level security;
alter table public.delivery_reschedule        force  row level security;
revoke all on table public.delivery_reschedule_config from public, anon, authenticated;
revoke all on table public.delivery_reschedule_window from public, anon, authenticated;
revoke all on table public.delivery_reschedule        from public, anon, authenticated;
grant  all on table public.delivery_reschedule_config to service_role;
grant  all on table public.delivery_reschedule_window to service_role;
grant  all on table public.delivery_reschedule        to service_role;
grant  usage, select on sequence public.delivery_reschedule_id_seq to service_role;

-- Every string on the three reschedule surfaces. Changing the wording is an
-- UPDATE here, never a deploy.
insert into public.ui_copy(key, value) values
  ('delivery.resched.title',        '"Reschedule this delivery"'::jsonb),
  ('delivery.resched.subtitle',     '"Your last delivery attempt did not succeed. Pick a day and a time that suits you."'::jsonb),
  ('delivery.resched.cta',          '"Choose a new time"'::jsonb),
  ('delivery.resched.submit',       '"Confirm this slot"'::jsonb),
  ('delivery.resched.day_label',    '"Which day?"'::jsonb),
  ('delivery.resched.window_label', '"What time?"'::jsonb),
  ('delivery.resched.tomorrow',     '"Tomorrow"'::jsonb),
  ('delivery.resched.used',         '"{used} of {max} reschedules used"'::jsonb),
  ('delivery.resched.done_title',   '"Rescheduled"'::jsonb),
  ('delivery.resched.done',         '"We will try again on {date}, {window}."'::jsonb),
  ('delivery.resched.not_failed',   '"This delivery has not failed an attempt, so there is nothing to reschedule yet."'::jsonb),
  ('delivery.resched.delivered',    '"This order has already been delivered."'::jsonb),
  ('delivery.resched.off',          '"Rescheduling is currently switched off. Our team will contact you."'::jsonb),
  ('delivery.resched.capped',       '"You have already rescheduled this delivery {max} times, so our team is taking it from here. We will call you."'::jsonb),
  ('delivery.resched.escalated',    '"Our team has been notified and will call you to arrange delivery."'::jsonb),
  ('delivery.resched.bad_day',      '"That day is no longer available. Please pick another."'::jsonb),
  ('delivery.resched.bad_window',   '"That time slot is no longer available. Please pick another."'::jsonb),
  ('delivery.resched.not_found',    '"We could not find that delivery."'::jsonb),
  ('delivery.resched.retry',        '"Try again"'::jsonb),
  ('delivery.resched.queue_title',  '"Reattempts due"'::jsonb),
  ('delivery.resched.queue_empty',  '"No reattempts are due for this date."'::jsonb),
  ('delivery.resched.queue_chip',   '"Customer asked for {window}"'::jsonb),
  ('delivery.resched.queue_auto',   '"Auto-scheduled after a failed attempt"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- One builder for all three surfaces. The customer's order screen, the public
-- /track page and the confirmation all read THE SAME block, so an option that
-- is offered on one is offered on every one of them.
create or replace function public._reschedule_block(p_delivery_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare d public.deliveries%rowtype; cfg public.delivery_reschedule_config%rowtype;
        v_days jsonb; v_windows jsonb; v_used int; v_can boolean; v_reason text; v_msg text;
        v_today date;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then
    return jsonb_build_object('ok', false, 'can_reschedule', false,
      'reason', 'not_found', 'message', public._c('delivery.resched.not_found'));
  end if;

  select * into cfg from public.delivery_reschedule_config where id = 1;
  v_today := (now() at time zone 'Asia/Kolkata')::date;
  v_used  := coalesce(d.reschedule_count, 0);

  -- The order of these checks is the order the customer experiences them.
  if not coalesce(cfg.enabled, false) then
    v_can := false; v_reason := 'disabled'; v_msg := public._c('delivery.resched.off');
  elsif d.status = 'delivered' then
    v_can := false; v_reason := 'delivered'; v_msg := public._c('delivery.resched.delivered');
  elsif d.status <> 'failed' then
    -- "After a failed attempt (and only then)."
    v_can := false; v_reason := 'not_failed'; v_msg := public._c('delivery.resched.not_failed');
  elsif v_used >= cfg.max_per_delivery then
    v_can := false; v_reason := 'capped';
    v_msg := public._cf('delivery.resched.capped',
               jsonb_build_object('max', cfg.max_per_delivery::text));
  else
    v_can := true; v_reason := ''; v_msg := public._c('delivery.resched.subtitle');
  end if;

  -- Days are generated, never stored: tomorrow through days_ahead, in IST.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   to_char(dt, 'YYYY-MM-DD'),
           'date',  dt,
           'label', case when dt = v_today + 1 then public._c('delivery.resched.tomorrow')
                         else to_char(dt, 'FMDay, FMDD FMMon') end
         ) order by dt), '[]'::jsonb)
    into v_days
  from generate_series(v_today + 1, v_today + coalesce(cfg.days_ahead, 3), interval '1 day') g(dt);

  select coalesce(jsonb_agg(jsonb_build_object('key', w.key, 'label', w.label) order by w.sort, w.key),
                  '[]'::jsonb)
    into v_windows
  from public.delivery_reschedule_window w where w.active;

  return jsonb_build_object(
    'ok', true,
    'delivery_id',    d.id,
    'order_id',       d.order_id,
    'can_reschedule', v_can,
    'reason',         v_reason,
    'title',          public._c('delivery.resched.title'),
    'message',        v_msg,
    'cta',            public._c('delivery.resched.cta'),
    'submit_label',   public._c('delivery.resched.submit'),
    'day_label',      public._c('delivery.resched.day_label'),
    'window_label',   public._c('delivery.resched.window_label'),
    'days',           case when v_can then v_days     else '[]'::jsonb end,
    'windows',        case when v_can then v_windows  else '[]'::jsonb end,
    'used',           v_used,
    'max',            cfg.max_per_delivery,
    'used_label',     public._cf('delivery.resched.used',
                        jsonb_build_object('used', v_used::text,
                                           'max',  cfg.max_per_delivery::text)),
    'escalated',      (d.reschedule_escalated_at is not null),
    'escalated_message', case when d.reschedule_escalated_at is not null
                              then public._c('delivery.resched.escalated') end,
    'current',        case when d.next_attempt_on is null then null else jsonb_build_object(
                        'date',         d.next_attempt_on,
                        'date_label',   to_char(d.next_attempt_on, 'FMDay, FMDD FMMon'),
                        'window_key',   d.reattempt_window_key,
                        'window_label', coalesce(d.reattempt_window_label,
                                                 public._c('delivery.resched.queue_auto'))) end);
end $fn$;

-- The write, shared by the signed-in and the token path. p_by is null for the
-- token path — a tracking link proves the order, not a person.
create or replace function public._reschedule_apply(
  p_delivery_id uuid, p_day text, p_window text, p_source text, p_by uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare d public.deliveries%rowtype; cfg public.delivery_reschedule_config%rowtype;
        w public.delivery_reschedule_window%rowtype; v_block jsonb; v_date date; v_today date;
        v_cust_phone text;
begin
  v_block := public._reschedule_block(p_delivery_id);
  if not coalesce((v_block->>'ok')::boolean, false)
     or not coalesce((v_block->>'can_reschedule')::boolean, false) then
    return v_block || jsonb_build_object('ok', false);
  end if;

  select * into d   from public.deliveries where id = p_delivery_id;
  select * into cfg from public.delivery_reschedule_config where id = 1;
  v_today := (now() at time zone 'Asia/Kolkata')::date;

  begin
    v_date := p_day::date;
  exception when others then
    v_date := null;
  end;
  if v_date is null or v_date < v_today + 1 or v_date > v_today + coalesce(cfg.days_ahead,3) then
    return jsonb_build_object('ok', false, 'error', 'bad_day',
      'message', public._c('delivery.resched.bad_day'));
  end if;

  select * into w from public.delivery_reschedule_window
   where key = coalesce(nullif(btrim(p_window),''), 'anytime') and active;
  if w.key is null then
    return jsonb_build_object('ok', false, 'error', 'bad_window',
      'message', public._c('delivery.resched.bad_window'));
  end if;

  update public.deliveries
     set next_attempt_on        = v_date,
         reattempt_window_key   = w.key,
         reattempt_window_label = w.label,
         reattempt_from         = w.from_time,
         reattempt_to           = w.to_time,
         reschedule_count       = coalesce(reschedule_count,0) + 1,
         rescheduled_at         = now()
   where id = p_delivery_id;

  insert into public.delivery_reschedule(delivery_id, order_id, customer_id,
                                         requested_date, window_key, window_label,
                                         source, created_by)
  select p_delivery_id, d.order_id, o.customer_id, v_date, w.key, w.label,
         coalesce(nullif(p_source,''), 'order_screen'), p_by
    from public.orders o where o.id = d.order_id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
  values (p_delivery_id, d.order_id, d.partner_id, 'rescheduled',
          to_char(v_date,'YYYY-MM-DD') || ' · ' || w.label,
          coalesce(nullif(p_source,''), 'order_screen'));

  -- Tell the customer in their own words, and tell the rider's side by moving
  -- the stop; the escalation below is what tells a human.
  perform public.notify('delivery_rescheduled', null,
    jsonb_build_object('order_id', d.order_id,
                       'date',   to_char(v_date, 'FMDD FMMon'),
                       'window', w.label));

  -- The cap is the point where a machine stops guessing and a person calls.
  if coalesce(d.reschedule_count,0) + 1 >= cfg.max_per_delivery then
    update public.deliveries set reschedule_escalated_at = now()
     where id = p_delivery_id and reschedule_escalated_at is null;
    perform public.notify('delivery_reschedule_escalated', null,
      jsonb_build_object('order_id', d.order_id,
                         'count',  (coalesce(d.reschedule_count,0) + 1)::text,
                         'date',   to_char(v_date, 'FMDD FMMon'),
                         'window', w.label));
  end if;

  return jsonb_build_object('ok', true,
    'title',   public._c('delivery.resched.done_title'),
    'message', public._cf('delivery.resched.done',
                 jsonb_build_object('date', to_char(v_date, 'FMDD FMMon'), 'window', w.label)),
    'state',   public._reschedule_block(p_delivery_id));
end $fn$;

-- ── the four public doors ────────────────────────────────────────────────
-- Signed-in customer, from the order screen.
create or replace function public.delivery_reschedule_options(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_id uuid;
begin
  select d.id into v_id
    from public.deliveries d
    join public.orders o on o.id = d.order_id
    join public.pharmacy_profiles pp on pp.id = o.customer_id
   where d.order_id = p_order_id
     and (pp.user_id = auth.uid() or public._is_admin());
  if v_id is null then
    return jsonb_build_object('ok', false, 'can_reschedule', false,
      'reason', 'not_found', 'message', public._c('delivery.resched.not_found'));
  end if;
  return public._reschedule_block(v_id);
end $fn$;

create or replace function public.delivery_reschedule_submit(
  p_order_id uuid, p_day text, p_window text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare v_id uuid;
begin
  select d.id into v_id
    from public.deliveries d
    join public.orders o on o.id = d.order_id
    join public.pharmacy_profiles pp on pp.id = o.customer_id
   where d.order_id = p_order_id
     and (pp.user_id = auth.uid() or public._is_admin());
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public._c('delivery.resched.not_found'));
  end if;
  return public._reschedule_apply(v_id, p_day, p_window, 'order_screen', auth.uid());
end $fn$;

-- The public /track page. Gated exactly like delivery_track_public: the
-- delivery's own qr_token, which is the link we sent that customer.
create or replace function public.delivery_reschedule_public(p_token text)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_id uuid;
begin
  select id into v_id from public.deliveries
   where qr_token = btrim(coalesce(p_token,'')) and btrim(coalesce(p_token,'')) <> '';
  if v_id is null then
    return jsonb_build_object('ok', false, 'can_reschedule', false,
      'reason', 'not_found', 'message', public._c('delivery.resched.not_found'));
  end if;
  return public._reschedule_block(v_id);
end $fn$;

create or replace function public.delivery_reschedule_submit_public(
  p_token text, p_day text, p_window text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare v_id uuid;
begin
  select id into v_id from public.deliveries
   where qr_token = btrim(coalesce(p_token,'')) and btrim(coalesce(p_token,'')) <> '';
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public._c('delivery.resched.not_found'));
  end if;
  return public._reschedule_apply(v_id, p_day, p_window, 'track_link', null);
end $fn$;

-- The helpers are internals: no client role calls them directly.
revoke all on function public._reschedule_block(uuid)                 from public, anon, authenticated;
revoke all on function public._reschedule_apply(uuid,text,text,text,uuid) from public, anon, authenticated;
grant execute on function public._reschedule_block(uuid)                 to service_role;
grant execute on function public._reschedule_apply(uuid,text,text,text,uuid) to service_role;

revoke all on function public.delivery_reschedule_options(uuid)            from public, anon;
revoke all on function public.delivery_reschedule_submit(uuid,text,text)   from public, anon;
grant execute on function public.delivery_reschedule_options(uuid)          to authenticated, service_role;
grant execute on function public.delivery_reschedule_submit(uuid,text,text) to authenticated, service_role;

-- These two ARE tokenless on purpose — the tracking link is opened from a
-- WhatsApp message with no session, exactly like delivery_track_public.
revoke all on function public.delivery_reschedule_public(text)                    from public;
revoke all on function public.delivery_reschedule_submit_public(text,text,text)   from public;
grant execute on function public.delivery_reschedule_public(text)                  to anon, authenticated, service_role;
grant execute on function public.delivery_reschedule_submit_public(text,text,text) to anon, authenticated, service_role;

-- ── the reattempt queue: what makes next_attempt_on mean something ───────
-- admin_delivery_queue() is scoped to orders CREATED on the chosen date, so a
-- stop failed on Monday for Tuesday was invisible on Tuesday and the column
-- delivery_fail() had been writing since day one was decoration. This is the
-- read side, and it is deliberately its OWN rpc rather than an edit to
-- admin_delivery_queue: the assignment queue answers "what came in today",
-- this answers "what did we promise to try again", and they are different
-- questions with different empty states.
create or replace function public.admin_reattempt_queue(p_date date, p_zone smallint)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_date date; v_zone smallint; v_rows jsonb;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false, 'rows', '[]'::jsonb);
  end if;
  v_date := public.scope_date(p_date);
  v_zone := public.scope_zone(p_zone);

  select coalesce(jsonb_agg(x order by x->>'window_sort', x->>'pharmacy_name'), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'delivery_id',   d.id,
      'order_id',      d.order_id,
      'order_code',    coalesce(o.order_code,''),
      'pharmacy_name', coalesce(o.pharmacy_name, pp.pharmacy_name, ''),
      'address',       coalesce(pp.address,''),
      'phone',         coalesce(nullif(btrim(o.phone),''), nullif(btrim(pp.phone),''), ''),
      'attempt_no',    coalesce(d.attempt_no, 0),
      'fail_reason',   coalesce(d.fail_reason,''),
      'due_on',        d.next_attempt_on,
      'is_overdue',    (d.next_attempt_on < v_date),
      -- The customer's own words when they chose, the auto line when they did
      -- not. Never a blank chip.
      'window_label',  coalesce(d.reattempt_window_label,
                                public._c('delivery.resched.queue_auto')),
      'window_chip',   case when d.reattempt_window_label is null
                            then public._c('delivery.resched.queue_auto')
                            else public._cf('delivery.resched.queue_chip',
                                   jsonb_build_object('window', d.reattempt_window_label)) end,
      'by_customer',   (d.rescheduled_at is not null),
      'escalated',     (d.reschedule_escalated_at is not null),
      'window_sort',   coalesce(to_char(d.reattempt_from,'HH24MI'), '9999')
    ) as x
    from public.deliveries d
    join public.orders o on o.id = d.order_id
    left join public.pharmacy_profiles pp on pp.id = o.customer_id
   where d.status = 'failed'
     and d.next_attempt_on is not null
     and d.next_attempt_on <= v_date
     and coalesce(o.status,'') <> 'cancelled'
     and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id, pp.zone_id), v_zone)
  ) s;

  return jsonb_build_object(
    'allowed',     true,
    'the_date',    v_date,
    'zone_id',     v_zone,
    'title',       public._c('delivery.resched.queue_title'),
    'empty_label', public._c('delivery.resched.queue_empty'),
    'count',       jsonb_array_length(v_rows),
    'rows',        v_rows);
end $fn$;

revoke all on function public.admin_reattempt_queue(date, smallint) from public, anon;
grant execute on function public.admin_reattempt_queue(date, smallint) to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════
-- PART 2 — RIDER SOS
-- One button on the active run. No telephony, nothing new to install: it
-- writes a row, fires the URGENT notify() route with a map link, and then
-- keeps the rider's location arriving faster than the normal ping until a
-- human resolves it.
-- ═════════════════════════════════════════════════════════════════════════

create table if not exists public.sos_config (
  id               smallint primary key default 1,
  enabled          boolean not null default true,
  stream_seconds   int     not null default 10,   -- while an SOS is open
  normal_seconds   int     not null default 30,   -- the ordinary run ping
  auto_close_min   int     not null default 180,  -- an untouched SOS stops streaming
  map_url_template text    not null default 'https://www.google.com/maps?q={lat},{lng}',
  updated_at       timestamptz not null default now(),
  constraint sos_config_singleton check (id = 1)
);
insert into public.sos_config(id) values (1) on conflict (id) do nothing;

create table if not exists public.sos_event (
  id              bigserial primary key,
  partner_id      uuid not null,
  partner_name    text,
  run_id          uuid,
  delivery_id     uuid,
  order_id        uuid,
  zone_id         smallint,
  lat             numeric,
  lng             numeric,
  accuracy        numeric,
  map_url         text,
  status          text not null default 'open',   -- open | acknowledged | resolved
  created_at      timestamptz not null default now(),
  acknowledged_at timestamptz,
  acknowledged_by uuid,
  resolved_at     timestamptz,
  resolved_by     uuid,
  resolve_note    text,
  last_ping_at    timestamptz,
  ping_count      int not null default 0
);
create index if not exists sos_event_open_idx on public.sos_event(status, created_at desc);
create index if not exists sos_event_partner_idx on public.sos_event(partner_id, created_at desc);

create table if not exists public.sos_ping (
  id       bigserial primary key,
  sos_id   bigint not null references public.sos_event(id) on delete cascade,
  lat      numeric,
  lng      numeric,
  accuracy numeric,
  at       timestamptz not null default now()
);
create index if not exists sos_ping_sos_idx on public.sos_ping(sos_id, at desc);

alter table public.sos_config enable row level security;
alter table public.sos_config force  row level security;
alter table public.sos_event  enable row level security;
alter table public.sos_event  force  row level security;
alter table public.sos_ping   enable row level security;
alter table public.sos_ping   force  row level security;
revoke all on table public.sos_config from public, anon, authenticated;
revoke all on table public.sos_event  from public, anon, authenticated;
revoke all on table public.sos_ping   from public, anon, authenticated;
grant  all on table public.sos_config to service_role;
grant  all on table public.sos_event  to service_role;
grant  all on table public.sos_ping   to service_role;
grant  usage, select on sequence public.sos_event_id_seq to service_role;
grant  usage, select on sequence public.sos_ping_id_seq  to service_role;

insert into public.ui_copy(key, value) values
  ('delivery.sos.button',       '"SOS"'::jsonb),
  ('delivery.sos.hint',         '"Hold for help"'::jsonb),
  ('delivery.sos.confirm_title','"Send an emergency alert?"'::jsonb),
  ('delivery.sos.confirm_body', '"Your live location goes to the mediBO team straight away and keeps updating until they close it."'::jsonb),
  ('delivery.sos.confirm_yes',  '"Send SOS"'::jsonb),
  ('delivery.sos.confirm_no',   '"Cancel"'::jsonb),
  ('delivery.sos.sent_title',   '"Help is on the way"'::jsonb),
  ('delivery.sos.sent_body',    '"The team has your location and is being alerted now. Stay where it is safe."'::jsonb),
  ('delivery.sos.active',       '"SOS active — the team can see you"'::jsonb),
  ('delivery.sos.acknowledged', '"The team has seen your alert"'::jsonb),
  ('delivery.sos.resolved',     '"Your SOS has been closed."'::jsonb),
  ('delivery.sos.off',          '"Emergency alerts are switched off right now."'::jsonb),
  ('delivery.sos.no_location',  '"We could not read your location. Try again once the map has a fix."'::jsonb),
  ('delivery.sos.not_rider',    '"Only a delivery partner can raise an SOS."'::jsonb),
  ('delivery.sos.already',      '"You already have an SOS open — the team is on it."'::jsonb),
  ('delivery.sos.admin_title',  '"Rider SOS"'::jsonb),
  ('delivery.sos.admin_empty',  '"No SOS alerts. Riders are safe."'::jsonb),
  ('delivery.sos.admin_ack',    '"Acknowledge"'::jsonb),
  ('delivery.sos.admin_resolve','"Close this SOS"'::jsonb),
  ('delivery.sos.admin_map',    '"Open the map"'::jsonb),
  ('delivery.sos.open_label',   '"Open"'::jsonb),
  ('delivery.sos.ack_label',    '"Acknowledged"'::jsonb),
  ('delivery.sos.done_label',   '"Closed"'::jsonb),
  ('delivery.sos.wa',           '"SOS from {rider} — {map}"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- The URGENT route. bypass_send_window + push is the same path #306/#398 use
-- for a new-order alert, which is the one notification Om is already known to
-- receive at any hour.
insert into public.wa_event_routes(event_key, label, description, audience,
                                   enabled, bypass_send_window, push_enabled,
                                   push_title, push_body)
values
  ('rider_sos', 'Rider SOS',
   'A delivery partner pressed the SOS button on their active run. Carries the live map link.',
   'admin', true, true, true,
   'SOS · {{rider}}', '{{rider}} needs help — tap to open the live location'),
  ('rider_sos_resolved', 'Rider SOS closed',
   'An SOS was closed by the team.', 'admin', true, true, false, null, null),
  ('delivery_rescheduled', 'Delivery rescheduled by the customer',
   'The customer picked a new day and time after a failed attempt.',
   'customer', true, false, true,
   'Delivery rescheduled', 'We will try again on {{date}}, {{window}}'),
  ('delivery_reschedule_escalated', 'Reschedule cap reached',
   'A customer has used every reschedule on one delivery; a person needs to call them.',
   'admin', true, true, true,
   'Reschedule cap reached', 'This delivery has been rescheduled {{count}} times — call the customer')
on conflict (event_key) do update
  set label = excluded.label, description = excluded.description,
      audience = excluded.audience, enabled = true,
      bypass_send_window = excluded.bypass_send_window,
      push_enabled = excluded.push_enabled,
      push_title = coalesce(excluded.push_title, wa_event_routes.push_title),
      push_body  = coalesce(excluded.push_body,  wa_event_routes.push_body);

-- ── the rider's three calls ──────────────────────────────────────────────
create or replace function public.delivery_sos_raise(
  p_lat numeric, p_lng numeric, p_accuracy numeric, p_delivery_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare p public.delivery_partner_registrations%rowtype; cfg public.sos_config%rowtype;
        v_id bigint; v_open bigint; v_run uuid; v_order uuid; v_map text; v_admin text;
begin
  select * into cfg from public.sos_config where id = 1;
  if not coalesce(cfg.enabled, false) then
    return jsonb_build_object('ok', false, 'error', 'disabled',
      'message', public._c('delivery.sos.off'));
  end if;

  select * into p from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false;
  if p.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_rider',
      'message', public._c('delivery.sos.not_rider'));
  end if;

  -- A location is the whole point of the alert. Refusing here is kinder than
  -- sending a team to 0,0.
  if p_lat is null or p_lng is null then
    return jsonb_build_object('ok', false, 'error', 'no_location',
      'message', public._c('delivery.sos.no_location'));
  end if;

  -- One open SOS per rider: a second press is the same emergency, and two
  -- rows would ring twice and be closed once.
  select id into v_open from public.sos_event
   where partner_id = p.id and status in ('open','acknowledged')
   order by created_at desc limit 1;
  if v_open is not null then
    update public.sos_event
       set lat = p_lat, lng = p_lng, accuracy = p_accuracy,
           last_ping_at = now(), ping_count = ping_count + 1
     where id = v_open;
    insert into public.sos_ping(sos_id, lat, lng, accuracy) values (v_open, p_lat, p_lng, p_accuracy);
    return jsonb_build_object('ok', true, 'sos_id', v_open, 'already', true,
      'title', public._c('delivery.sos.sent_title'),
      'message', public._c('delivery.sos.already'),
      'interval_s', cfg.stream_seconds);
  end if;

  select r.id into v_run from public.delivery_runs r
   where r.partner_id = p.id and r.status <> 'completed'
   order by r.run_date desc limit 1;
  select d.order_id into v_order from public.deliveries d where d.id = p_delivery_id;

  v_map := replace(replace(cfg.map_url_template, '{lat}', p_lat::text), '{lng}', p_lng::text);

  insert into public.sos_event(partner_id, partner_name, run_id, delivery_id, order_id,
                               zone_id, lat, lng, accuracy, map_url,
                               last_ping_at, ping_count)
  values (p.id, coalesce(p.full_name,''), v_run, p_delivery_id, v_order,
          p.zone_id, p_lat, p_lng, p_accuracy, v_map, now(), 1)
  returning id into v_id;
  insert into public.sos_ping(sos_id, lat, lng, accuracy) values (v_id, p_lat, p_lng, p_accuracy);

  select value #>> '{}' into v_admin from public.app_settings where key = 'admin_wa_phone';
  perform public.notify('rider_sos', v_admin,
    jsonb_build_object('rider', coalesce(p.full_name,'A delivery partner'),
                       'phone', coalesce(p.phone,''),
                       'map',   v_map,
                       'sos_id', v_id::text,
                       'order_id', v_order));

  return jsonb_build_object('ok', true, 'sos_id', v_id, 'already', false,
    'title',      public._c('delivery.sos.sent_title'),
    'message',    public._c('delivery.sos.sent_body'),
    'active_label', public._c('delivery.sos.active'),
    'interval_s', cfg.stream_seconds,
    'map_url',    v_map);
end $fn$;

-- The faster stream. The rider's app calls this on the interval the BACKEND
-- last handed it, and stops when the backend says to stop — the client never
-- decides how long an emergency lasts.
create or replace function public.delivery_sos_ping(
  p_sos_id bigint, p_lat numeric, p_lng numeric, p_accuracy numeric)
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare s public.sos_event%rowtype; cfg public.sos_config%rowtype; v_mine boolean;
begin
  select * into cfg from public.sos_config where id = 1;
  select * into s from public.sos_event where id = p_sos_id;
  if s.id is null then
    return jsonb_build_object('ok', false, 'streaming', false, 'interval_s', cfg.normal_seconds);
  end if;
  select exists (select 1 from public.delivery_partner_registrations
                  where id = s.partner_id and user_id = auth.uid()) into v_mine;
  if not coalesce(v_mine,false) and not public._is_admin() then
    return jsonb_build_object('ok', false, 'streaming', false, 'interval_s', cfg.normal_seconds);
  end if;

  if s.status = 'resolved' then
    return jsonb_build_object('ok', true, 'streaming', false,
      'interval_s', cfg.normal_seconds,
      'message', public._c('delivery.sos.resolved'));
  end if;

  -- An SOS nobody closed still stops streaming eventually: a phone that pings
  -- every 10s forever is a flat battery, which is the opposite of safe.
  if s.created_at < now() - make_interval(mins => cfg.auto_close_min) then
    return jsonb_build_object('ok', true, 'streaming', false,
      'interval_s', cfg.normal_seconds);
  end if;

  if p_lat is not null and p_lng is not null then
    insert into public.sos_ping(sos_id, lat, lng, accuracy)
    values (p_sos_id, p_lat, p_lng, p_accuracy);
    update public.sos_event
       set lat = p_lat, lng = p_lng, accuracy = p_accuracy,
           last_ping_at = now(), ping_count = ping_count + 1
     where id = p_sos_id;
  end if;

  return jsonb_build_object('ok', true, 'streaming', true,
    'interval_s', cfg.stream_seconds,
    'status', s.status,
    'message', case when s.status = 'acknowledged'
                    then public._c('delivery.sos.acknowledged')
                    else public._c('delivery.sos.active') end);
end $fn$;

-- What the rider's screen renders: the button, or the live banner.
create or replace function public.delivery_sos_state()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare p public.delivery_partner_registrations%rowtype; cfg public.sos_config%rowtype;
        s public.sos_event%rowtype;
begin
  select * into cfg from public.sos_config where id = 1;
  select * into p from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false;
  if p.id is null then
    return jsonb_build_object('ok', true, 'can_sos', false, 'has_open', false);
  end if;

  select * into s from public.sos_event
   where partner_id = p.id and status in ('open','acknowledged')
     and created_at > now() - make_interval(mins => cfg.auto_close_min)
   order by created_at desc limit 1;

  return jsonb_build_object(
    'ok', true,
    'can_sos',        coalesce(cfg.enabled, false),
    'button_label',   public._c('delivery.sos.button'),
    'hint',           public._c('delivery.sos.hint'),
    'confirm_title',  public._c('delivery.sos.confirm_title'),
    'confirm_body',   public._c('delivery.sos.confirm_body'),
    'confirm_yes',    public._c('delivery.sos.confirm_yes'),
    'confirm_no',     public._c('delivery.sos.confirm_no'),
    'disabled_message', case when not coalesce(cfg.enabled,false)
                             then public._c('delivery.sos.off') end,
    'has_open',       (s.id is not null),
    'sos_id',         s.id,
    'interval_s',     case when s.id is not null then cfg.stream_seconds else cfg.normal_seconds end,
    'active_label',   case when s.id is null then null
                           when s.status = 'acknowledged'
                                then public._c('delivery.sos.acknowledged')
                           else public._c('delivery.sos.active') end);
end $fn$;

-- ── the admin side: see it, own it, close it ─────────────────────────────
create or replace function public.admin_sos_list(p_status text)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_rows jsonb; v_filter text := lower(coalesce(nullif(btrim(p_status),''),'open'));
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false, 'rows', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            s.id,
           'rider',         coalesce(nullif(s.partner_name,''), 'Delivery partner'),
           'phone',         coalesce(p.phone,''),
           'status',        s.status,
           'status_label',  case s.status
                              when 'open'         then public._c('delivery.sos.open_label')
                              when 'acknowledged' then public._c('delivery.sos.ack_label')
                              else public._c('delivery.sos.done_label') end,
           'status_colors', case s.status
                              when 'open'         then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
                              when 'acknowledged' then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                              else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end,
           'map_url',       coalesce(s.map_url,''),
           'map_label',     public._c('delivery.sos.admin_map'),
           'ack_label',     public._c('delivery.sos.admin_ack'),
           'resolve_label', public._c('delivery.sos.admin_resolve'),
           'can_ack',       (s.status = 'open'),
           'can_resolve',   (s.status in ('open','acknowledged')),
           'raised_label',  to_char(s.created_at at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM'),
           'last_seen_label', case when s.last_ping_at is null then ''
                                   else to_char(s.last_ping_at at time zone 'Asia/Kolkata',
                                                'DD Mon, HH12:MI AM') end,
           'ping_count',    s.ping_count,
           'order_id',      s.order_id,
           'resolve_note',  coalesce(s.resolve_note,'')
         ) order by
             case s.status when 'open' then 0 when 'acknowledged' then 1 else 2 end,
             s.created_at desc), '[]'::jsonb)
    into v_rows
  from public.sos_event s
  left join public.delivery_partner_registrations p on p.id = s.partner_id
  where case when v_filter = 'all' then true
             when v_filter = 'resolved' then s.status = 'resolved'
             else s.status in ('open','acknowledged') end;

  return jsonb_build_object(
    'allowed',     true,
    'title',       public._c('delivery.sos.admin_title'),
    'empty_label', public._c('delivery.sos.admin_empty'),
    'filter',      v_filter,
    'open_count',  (select count(*) from public.sos_event where status in ('open','acknowledged')),
    'count',       jsonb_array_length(v_rows),
    'rows',        v_rows);
end $fn$;

create or replace function public.admin_sos_action(p_id bigint, p_action text, p_note text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare s public.sos_event%rowtype; v_act text := lower(coalesce(btrim(p_action),''));
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  select * into s from public.sos_event where id = p_id;
  if s.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if v_act = 'acknowledge' then
    update public.sos_event
       set status = 'acknowledged', acknowledged_at = now(), acknowledged_by = auth.uid()
     where id = p_id and status = 'open';
  elsif v_act = 'resolve' then
    update public.sos_event
       set status = 'resolved', resolved_at = now(), resolved_by = auth.uid(),
           resolve_note = nullif(btrim(coalesce(p_note,'')),'')
     where id = p_id and status in ('open','acknowledged');
    perform public.notify('rider_sos_resolved', null,
      jsonb_build_object('rider', coalesce(s.partner_name,''), 'sos_id', p_id::text));
  else
    return jsonb_build_object('ok', false, 'error', 'bad_action');
  end if;

  return jsonb_build_object('ok', true, 'state', public.admin_sos_list('open'));
end $fn$;

revoke all on function public.delivery_sos_raise(numeric,numeric,numeric,uuid) from public, anon;
revoke all on function public.delivery_sos_ping(bigint,numeric,numeric,numeric) from public, anon;
revoke all on function public.delivery_sos_state()                              from public, anon;
revoke all on function public.admin_sos_list(text)                              from public, anon;
revoke all on function public.admin_sos_action(bigint,text,text)                from public, anon;
grant execute on function public.delivery_sos_raise(numeric,numeric,numeric,uuid) to authenticated, service_role;
grant execute on function public.delivery_sos_ping(bigint,numeric,numeric,numeric) to authenticated, service_role;
grant execute on function public.delivery_sos_state()                              to authenticated, service_role;
grant execute on function public.admin_sos_list(text)                              to authenticated, service_role;
grant execute on function public.admin_sos_action(bigint,text,text)                to authenticated, service_role;

-- ═════════════════════════════════════════════════════════════════════════
-- PART 3 — RIDER LEADERBOARD
-- Riders never saw their own standing. Computed from the SAME numbers
-- admin_delivery_dashboard already shows the office — _sla_block() for on-time,
-- delivery_ratings over 90 days for the star, delivered stops for the count —
-- so the rider and the office are never looking at two different truths.
-- ═════════════════════════════════════════════════════════════════════════

-- An agency that does not want its team ranked switches it off for its own
-- riders. Rider rows inherit the flag from their parent agency.
alter table public.delivery_partner_registrations
  add column if not exists leaderboard_opt_out boolean not null default false;

insert into public.ui_copy(key, value) values
  ('delivery.lb.title',        '"Leaderboard"'::jsonb),
  ('delivery.lb.subtitle',     '"This week, in your zone"'::jsonb),
  ('delivery.lb.tab',          '"Leaderboard"'::jsonb),
  ('delivery.lb.zone_title',   '"Your zone"'::jsonb),
  ('delivery.lb.agency_title', '"Your team"'::jsonb),
  ('delivery.lb.rank',         '"#{rank} of {total}"'::jsonb),
  ('delivery.lb.you',          '"You"'::jsonb),
  ('delivery.lb.drops',        '"Drops"'::jsonb),
  ('delivery.lb.on_time',      '"On time"'::jsonb),
  ('delivery.lb.rating',       '"Rating"'::jsonb),
  ('delivery.lb.no_rating',    '"—"'::jsonb),
  ('delivery.lb.empty',        '"No deliveries yet this week. Your first drop puts you on the board."'::jsonb),
  ('delivery.lb.opted_out',    '"Your agency has turned ranking off for its team."'::jsonb),
  ('delivery.lb.not_rider',    '"Only a delivery partner has a standing."'::jsonb),
  ('delivery.lb.week_label',   '"{from} – {to}"'::jsonb),
  ('delivery.lb.optout_title', '"Show the leaderboard to my team"'::jsonb),
  ('delivery.lb.optout_on',    '"Your riders can see their ranking."'::jsonb),
  ('delivery.lb.optout_off',   '"Ranking is hidden from your riders."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function public.delivery_leaderboard()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare me public.delivery_partner_registrations%rowtype;
        v_from date; v_to date; v_zone jsonb; v_agency jsonb;
        v_opt boolean; v_agency_id uuid;
begin
  select * into me from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false;
  if me.id is null then
    return jsonb_build_object('ok', false, 'shown', false,
      'message', public._c('delivery.lb.not_rider'));
  end if;

  -- A rider inherits the flag from the agency they ride for; an agency owner
  -- carries their own.
  v_agency_id := coalesce(me.parent_agency_id, case when me.partner_type = 'agency' then me.id end);
  select coalesce(bool_or(a.leaderboard_opt_out), false) into v_opt
    from public.delivery_partner_registrations a where a.id = v_agency_id;
  v_opt := coalesce(v_opt, false) or coalesce(me.leaderboard_opt_out, false);
  if v_opt then
    return jsonb_build_object('ok', true, 'shown', false,
      'title', public._c('delivery.lb.title'),
      'message', public._c('delivery.lb.opted_out'));
  end if;

  -- The week is Monday..today in IST, so "this week" means the same thing to
  -- a rider at 11 PM as it does to the office at 9 AM.
  v_to   := (now() at time zone 'Asia/Kolkata')::date;
  v_from := v_to - ((extract(isodow from v_to)::int) - 1);

  with scored as (
    select p.id, coalesce(p.full_name,'') as name, p.zone_id, p.parent_agency_id,
           count(*) filter (where d.status = 'delivered')::int as drops,
           count(*) filter (where sb.state = 'on_time')::int  as on_time,
           count(*) filter (where sb.state in ('on_time','breached'))::int as measured
      from public.delivery_partner_registrations p
      left join public.deliveries d
             on d.partner_id = p.id
            and (d.delivered_at at time zone 'Asia/Kolkata')::date between v_from and v_to
      left join lateral (select public._sla_block(d) as b) sl on true
      left join lateral (select sl.b->>'state' as state) sb on true
     where p.is_active and coalesce(p.is_deleted,false) = false
       and coalesce(p.partner_type,'rider') <> 'agency'
       and coalesce(p.leaderboard_opt_out,false) = false
     group by p.id, p.full_name, p.zone_id, p.parent_agency_id
  ), rated as (
    select s.*,
           (select round(avg(dr.stars)::numeric, 1) from public.delivery_ratings dr
             where dr.partner_id = s.id and dr.created_at > now() - interval '90 days') as stars,
           case when s.measured = 0 then null
                else round(100.0 * s.on_time / s.measured) end as on_time_pct
      from scored s
  )
  select
    public._lb_block(
      (select jsonb_agg(to_jsonb(r) order by r.drops desc, r.on_time_pct desc nulls last, r.name)
         from rated r where r.zone_id is not distinct from me.zone_id),
      me.id, public._c('delivery.lb.zone_title')),
    case when v_agency_id is null then null else
      public._lb_block(
        (select jsonb_agg(to_jsonb(r) order by r.drops desc, r.on_time_pct desc nulls last, r.name)
           from rated r where r.parent_agency_id = v_agency_id),
        me.id, public._c('delivery.lb.agency_title')) end
    into v_zone, v_agency;

  return jsonb_build_object(
    'ok', true, 'shown', true,
    'title',      public._c('delivery.lb.title'),
    'subtitle',   public._c('delivery.lb.subtitle'),
    'week_label', public._cf('delivery.lb.week_label',
                    jsonb_build_object('from', to_char(v_from,'FMDD FMMon'),
                                       'to',   to_char(v_to,  'FMDD FMMon'))),
    'empty_label', public._c('delivery.lb.empty'),
    'boards',     (case when v_agency is null then jsonb_build_array(v_zone)
                        else jsonb_build_array(v_zone, v_agency) end));
end $fn$;

-- One board, rendered. Kept separate so the zone board and the agency board
-- can never drift into two different shapes on the same screen.
create or replace function public._lb_block(p_rows jsonb, p_me uuid, p_title text)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_rows jsonb; v_total int; v_my_rank int;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank',          ord,
           'partner_id',    r->>'id',
           'name',          case when (r->>'id') = p_me::text
                                 then public._c('delivery.lb.you')
                                 else coalesce(nullif(r->>'name',''), '—') end,
           'is_me',         ((r->>'id') = p_me::text),
           'drops',         coalesce((r->>'drops')::int, 0),
           'on_time_label', case when r->>'on_time_pct' is null
                                 then public._c('delivery.lb.no_rating')
                                 else (r->>'on_time_pct') || '%' end,
           'rating_label',  case when r->>'stars' is null
                                 then public._c('delivery.lb.no_rating')
                                 else (r->>'stars') end
         ) order by ord), '[]'::jsonb),
         count(*)::int,
         min(ord) filter (where (r->>'id') = p_me::text)
    into v_rows, v_total, v_my_rank
  from (select row_number() over ()::int as ord, e as r
          from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) e) z;

  return jsonb_build_object(
    'title',       p_title,
    'total',       v_total,
    'my_rank',     v_my_rank,
    'has_rank',    (v_my_rank is not null),
    'rank_label',  case when v_my_rank is null then public._c('delivery.lb.no_rating')
                        else public._cf('delivery.lb.rank',
                               jsonb_build_object('rank', v_my_rank::text,
                                                  'total', v_total::text)) end,
    'drops_caption',   public._c('delivery.lb.drops'),
    'on_time_caption', public._c('delivery.lb.on_time'),
    'rating_caption',  public._c('delivery.lb.rating'),
    'rows',        v_rows);
end $fn$;

-- The agency's own switch. An agency owner may set it for their agency; an
-- admin may set it for anyone.
create or replace function public.delivery_leaderboard_optout_set(p_opt_out boolean)
returns jsonb language plpgsql security definer set search_path to 'public'
as $fn$
declare me public.delivery_partner_registrations%rowtype;
begin
  select * into me from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false;
  if me.id is null or coalesce(me.partner_type,'') <> 'agency' then
    return jsonb_build_object('ok', false, 'error', 'not_agency');
  end if;
  update public.delivery_partner_registrations
     set leaderboard_opt_out = coalesce(p_opt_out, false)
   where id = me.id;
  return jsonb_build_object('ok', true,
    'opt_out', coalesce(p_opt_out,false),
    'title',   public._c('delivery.lb.optout_title'),
    'message', case when coalesce(p_opt_out,false)
                    then public._c('delivery.lb.optout_off')
                    else public._c('delivery.lb.optout_on') end);
end $fn$;

-- What the agency's own panel renders before anything is toggled.
create or replace function public.delivery_leaderboard_optout_get()
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $fn$
declare me public.delivery_partner_registrations%rowtype;
begin
  select * into me from public.delivery_partner_registrations
   where user_id = auth.uid() and coalesce(is_deleted,false) = false;
  if me.id is null or coalesce(me.partner_type,'') <> 'agency' then
    return jsonb_build_object('ok', true, 'is_agency', false);
  end if;
  return jsonb_build_object('ok', true, 'is_agency', true,
    'opt_out', coalesce(me.leaderboard_opt_out,false),
    'title',   public._c('delivery.lb.optout_title'),
    'message', case when coalesce(me.leaderboard_opt_out,false)
                    then public._c('delivery.lb.optout_off')
                    else public._c('delivery.lb.optout_on') end);
end $fn$;

revoke all on function public._lb_block(jsonb,uuid,text) from public, anon, authenticated;
grant execute on function public._lb_block(jsonb,uuid,text) to service_role;
revoke all on function public.delivery_leaderboard()                    from public, anon;
revoke all on function public.delivery_leaderboard_optout_set(boolean)  from public, anon;
revoke all on function public.delivery_leaderboard_optout_get()         from public, anon;
grant execute on function public.delivery_leaderboard()                   to authenticated, service_role;
grant execute on function public.delivery_leaderboard_optout_set(boolean) to authenticated, service_role;
grant execute on function public.delivery_leaderboard_optout_get()        to authenticated, service_role;
