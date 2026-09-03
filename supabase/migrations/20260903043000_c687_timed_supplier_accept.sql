-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #687 — Timed supplier accept with auto-reassign (feature_gaps #68)
--
-- The gap, measured: there was no working clock anywhere in the waterfall.
--   * `asked_at` was NULL on all 160 live inquiry rows, so nothing had a
--     dispatch stamp and therefore nothing could ever be "late".
--   * `sweep_inquiry_timeouts()` did its whole advance inside
--     `IF public.inquiry_any_locked()`, so with both zones unlocked the branch
--     was dead code: 8 runs / 21,689 skips and zero advances, ever.
--   * The 10-minute window was a literal in three places, so it could not be
--     tuned per zone without a deploy.
--   * supplier_orders carried accept_state/accepted_at/decline_reason (#527)
--     but nothing expired a `pending` one — a silent supplier held the line
--     open forever with nothing visible to anyone.
--
-- What lands here (all backend-owned, all rendered verbatim by Flutter):
--   1. A configurable, per-zone response deadline + a finished countdown block.
--   2. asked_at stamped the moment a PENDING form goes out (trigger).
--   3. inquiry_timeout_advance() — the advance, off the lock gate, on the
--      cron dispatcher, logging and notifying.
--   4. An accept deadline on supplier_orders + a sweep that reassigns a
--      timed-out order down the same cascade a decline uses.
--   5. supplier_response_log + supplier_response_stats() feeding the scorecard.
--
-- Every statement is idempotent: a resumed worker re-applies this file as a
-- silent no-op.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────
-- 1. CONFIG — the window is data, not a literal
-- ─────────────────────────────────────────────────────────────────────────
insert into public.app_settings(key, value) values
  ('inquiry_response_deadline_minutes', '{"default": 10, "zones": {}}'::jsonb),
  ('supplier_accept_deadline_minutes',  '{"default": 45, "zones": {}}'::jsonb)
on conflict (key) do nothing;

insert into public.ui_copy(key, value) values
  ('deadline.reply_in',             '"Reply in"'::jsonb),
  ('deadline.overdue_by',           '"Overdue by"'::jsonb),
  ('deadline.expired',              '"Time up"'::jsonb),
  ('deadline.by_prefix',            '"Reply by"'::jsonb),
  ('inquiry.deadline_title',        '"Response deadline"'::jsonb),
  ('inquiry.deadline_expired_note', '"Time up — this item moves to the next supplier"'::jsonb),
  ('inquiry.no_response_answer',    '"No response"'::jsonb),
  ('supplier_po.deadline_title',    '"Reply deadline"'::jsonb),
  ('supplier_po.state_timeout',     '"No reply — sent to the next supplier"'::jsonb),
  ('supplier_po.timeout_reason',    '"No reply before the deadline"'::jsonb),
  ('supplier_po.deadline_expired_note',
                                    '"Time up — this order went to the next supplier"'::jsonb),
  ('spn.response_title',            '"Response record"'::jsonb),
  ('spn.response_rate_label',       '"Answered in time"'::jsonb),
  ('spn.response_median_label',     '"Typical reply time"'::jsonb),
  ('spn.response_asked_label',      '"Asked"'::jsonb),
  ('spn.response_none',             '"No inquiries yet"'::jsonb),
  ('admin_inquiry.no_response_chip','"No response"'::jsonb),
  ('admin_inquiry.deadline_label',  '"Deadline"'::jsonb)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. SCHEMA — the response ledger and the accept clock
-- ─────────────────────────────────────────────────────────────────────────
create table if not exists public.supplier_response_log (
  id                bigserial primary key,
  supplier_name     text        not null,
  kind              text        not null,   -- inquiry_asked | inquiry_answered
                                            -- inquiry_timeout | po_accepted
                                            -- po_partial | po_declined | po_timeout
  outcome           text        not null,   -- responded | no_response | accepted
                                            -- partial | declined
  inquiry_id        bigint,
  product_id        bigint,
  supplier_order_id uuid,
  order_code        text,
  zone_id           smallint,
  asked_at          timestamptz,
  deadline_at       timestamptz,
  responded_at      timestamptz,
  response_seconds  integer,
  reason            text,
  detail            jsonb       not null default '{}'::jsonb,
  created_at        timestamptz not null default now()
);

create index if not exists supplier_response_log_supplier_idx
  on public.supplier_response_log (lower(btrim(supplier_name)), created_at desc);
create index if not exists supplier_response_log_created_idx
  on public.supplier_response_log (created_at desc);
create index if not exists supplier_response_log_inquiry_idx
  on public.supplier_response_log (inquiry_id) where inquiry_id is not null;

alter table public.supplier_response_log enable row level security;

-- The accept clock. NULL on every row that existed before this change, and the
-- sweep only ever looks at rows that HAVE one — 48 historical `pending` orders
-- must never be mass-cascaded by switching this on.
alter table public.supplier_orders
  add column if not exists accept_due_at timestamptz;

comment on column public.supplier_orders.accept_due_at is
  'CHANGE #687 — when the supplier must have answered by. Stamped on insert '
  'from supplier_accept_deadline_minutes for the order zone. NULL = no clock '
  '(pre-#687 rows), which the timeout sweep skips.';

-- ─────────────────────────────────────────────────────────────────────────
-- 3. THE WINDOW + THE FINISHED COUNTDOWN STRING
--    Flutter prints value_label / deadline_label verbatim and re-fetches on
--    the backend's own refresh_s. No duration maths in Dart, ever.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.fmt_duration_short(p_seconds integer)
returns text
language sql
immutable
as $function$
  select case
    when p_seconds is null then ''
    when abs(p_seconds) < 60   then abs(p_seconds)::text || 's'
    when abs(p_seconds) < 3600 then (abs(p_seconds) / 60)::text || 'm '
                                    || to_char((abs(p_seconds) % 60), 'FM00') || 's'
    else (abs(p_seconds) / 3600)::text || 'h '
         || to_char(((abs(p_seconds) % 3600) / 60), 'FM00') || 'm'
  end;
$function$;

create or replace function public.inquiry_deadline_minutes(p_zone smallint default null)
returns integer
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cfg as (
    select value as v from app_settings where key = 'inquiry_response_deadline_minutes'
  )
  select greatest(1, coalesce(
    (select (v #>> array['zones', coalesce(p_zone, -1)::text])::int from cfg),
    (select (v #>> '{default}')::int from cfg),
    coalesce((select (value #>> '{}')::int from app_settings
               where key = 'inquiry_form_ttl_minutes'), 10)));
$function$;

create or replace function public.supplier_accept_deadline_minutes(p_zone smallint default null)
returns integer
language sql
stable
security definer
set search_path to 'public'
as $function$
  with cfg as (
    select value as v from app_settings where key = 'supplier_accept_deadline_minutes'
  )
  select greatest(1, coalesce(
    (select (v #>> array['zones', coalesce(p_zone, -1)::text])::int from cfg),
    (select (v #>> '{default}')::int from cfg),
    45));
$function$;

-- The one countdown block every surface renders. p_kind selects the copy set
-- so the supplier tab, the link page, the admin tab and the PO card all print
-- their own wording without a single string living in Dart.
create or replace function public.deadline_block(
  p_started    timestamptz,
  p_deadline   timestamptz,
  p_kind       text default 'inquiry',
  p_settled    boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_left int; v_expired boolean; v_title text; v_note text;
begin
  if p_deadline is null or coalesce(p_settled, false) then
    return jsonb_build_object('has', false);
  end if;

  v_left    := floor(extract(epoch from (p_deadline - now())))::int;
  v_expired := (v_left <= 0);

  v_title := case when p_kind = 'po'
                  then public.uic('supplier_po.deadline_title', 'Reply deadline')
                  else public.uic('inquiry.deadline_title', 'Response deadline') end;
  v_note  := case when p_kind = 'po'
                  then public.uic('supplier_po.deadline_expired_note', '')
                  else public.uic('inquiry.deadline_expired_note', '') end;

  return jsonb_build_object(
    'has',            true,
    'kind',           p_kind,
    'title',          v_title,
    'asked_at',       p_started,
    'deadline_at',    p_deadline,
    'seconds_left',   v_left,
    'expired',        v_expired,
    'label',          case when v_expired
                           then public.uic('deadline.overdue_by', 'Overdue by')
                           else public.uic('deadline.reply_in', 'Reply in') end,
    'value_label',    case when v_expired and v_left = 0
                           then public.uic('deadline.expired', 'Time up')
                           else public.fmt_duration_short(abs(v_left)) end,
    'deadline_label', public.uic('deadline.by_prefix', 'Reply by') || ' '
                      || to_char(p_deadline at time zone 'Asia/Kolkata', 'FMHH12:MI AM'),
    'expired_note',   case when v_expired then v_note else '' end,
    'tone',           case when v_expired then 'danger'
                           when v_left <= 120 then 'warning'
                           else 'info' end,
    -- How often the surface should re-ask. Tight near the wire, lazy when
    -- there is nothing to watch — the backend decides the poll, not the app.
    'refresh_s',      case when v_expired then 60
                           when v_left <= 120 then 10
                           when v_left <= 600 then 30
                           else 60 end);
end $function$;

-- Deadline for ONE inquiry row.
create or replace function public.inquiry_deadline_at(p_inquiry_id bigint)
returns timestamptz
language sql
stable
security definer
set search_path to 'public'
as $function$
  select i.asked_at + make_interval(mins => public.inquiry_deadline_minutes(i.zone_id))
    from inquiry i where i.id = p_inquiry_id;
$function$;

-- The nearest live deadline across everything a supplier has been asked. This
-- is what the supplier tab, the link page and the admin row all show.
create or replace function public.inquiry_supplier_deadline(p_supplier text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_started timestamptz; v_due timestamptz;
begin
  if coalesce(btrim(p_supplier), '') = '' then
    return jsonb_build_object('has', false);
  end if;
  select i.asked_at,
         i.asked_at + make_interval(mins => public.inquiry_deadline_minutes(i.zone_id))
    into v_started, v_due
  from inquiry i
  where lower(btrim(i.current_supplier)) = lower(btrim(p_supplier))
    and i.asked_at is not null
    and coalesce(i.current_status, '') <> 'Available'
    and coalesce(i.inquiry_phase, 'draft') in ('draft', 'sent')
  order by i.asked_at asc
  limit 1;

  return public.deadline_block(v_started, v_due, 'inquiry', false);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. asked_at IS STAMPED WHEN THE LINK ACTUALLY GOES OUT
--    A 'pending' inquiry_forms row IS the dispatch: it is written by
--    start_inquiry_for_suppliers (link + WhatsApp) and by the timeout advance.
--    A 'draft' row is not a dispatch and deliberately stamps nothing.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._c687_stamp_asked_at()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(new.status, '') <> 'pending' then
    return new;
  end if;
  update inquiry i
     set asked_at = coalesce(i.asked_at, coalesce(new.last_sent_at, now())),
         inquiry_phase = 'sent'
   where lower(btrim(i.current_supplier)) = lower(btrim(new.supplier_name))
     and i.asked_at is null
     and coalesce(i.inquiry_phase, 'draft') in ('draft', 'sent');

  insert into supplier_response_log
    (supplier_name, kind, outcome, inquiry_id, product_id, zone_id,
     asked_at, deadline_at, detail)
  select new.supplier_name, 'inquiry_asked', 'asked', i.id, i.product_id, i.zone_id,
         i.asked_at,
         i.asked_at + make_interval(mins => public.inquiry_deadline_minutes(i.zone_id)),
         jsonb_build_object('via', 'form_sent')
    from inquiry i
   where lower(btrim(i.current_supplier)) = lower(btrim(new.supplier_name))
     and i.asked_at is not null
     and coalesce(i.current_status, '') <> 'Available'
     and not exists (
       select 1 from supplier_response_log l
        where l.inquiry_id = i.id
          and l.kind = 'inquiry_asked'
          and lower(btrim(l.supplier_name)) = lower(btrim(new.supplier_name))
          and l.asked_at = i.asked_at);
  return new;
end $function$;

drop trigger if exists trg_c687_stamp_asked_at on public.inquiry_forms;
create trigger trg_c687_stamp_asked_at
  after insert or update of last_sent_at, status on public.inquiry_forms
  for each row execute function public._c687_stamp_asked_at();

-- ─────────────────────────────────────────────────────────────────────────
-- 5. THE ADVANCE THAT ACTUALLY FIRES
--    Named for the gap it closes. No lock gate: the clock is asked_at, and a
--    row with no asked_at has no clock, so running this unconditionally is
--    safe by construction.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.inquiry_timeout_advance()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r_inq inquiry%rowtype;
  v_id bigint; v_old text; v_slot int; i int; ps_val text; as_val text;
  v_due timestamptz; v_advanced int := 0; v_sups text[] := '{}';
  v_new_cur text; v_no_answer text := public.uic('inquiry.no_response_answer', 'No response');
begin
  for v_id in
    select i2.id from inquiry i2
     where i2.current_supplier is not null
       and i2.asked_at is not null
       and coalesce(i2.current_status, '') <> 'Available'
       and coalesce(i2.inquiry_phase, 'draft') in ('draft', 'sent')
       and i2.asked_at < now()
           - make_interval(mins => public.inquiry_deadline_minutes(i2.zone_id))
     order by i2.asked_at asc
     limit 500
  loop
    select * into r_inq from inquiry where id = v_id;
    continue when r_inq.current_supplier is null;
    v_old := r_inq.current_supplier;
    -- #401: a shop that closed while we waited is moved on with no answer and
    -- therefore no penalty. That path stays exactly as it was.
    continue when public.supplier_closed_now(v_old);

    v_due := r_inq.asked_at
             + make_interval(mins => public.inquiry_deadline_minutes(r_inq.zone_id));

    -- Find the current supplier's slot and only write into an EMPTY answer.
    v_slot := null; as_val := null;
    for i in 1..30 loop
      execute format('select ($1).%I, ($1).%I', 'PS' || i, 'AS' || i)
        into ps_val, as_val using r_inq;
      if ps_val = v_old then v_slot := i; exit; end if;
      as_val := null;
    end loop;
    continue when v_slot is null or as_val is not null;

    execute format('update inquiry set %I = $1 where id = $2', 'AS' || v_slot)
      using v_no_answer, v_id;
    begin
      perform public.inquiry_log_answer(v_old, r_inq.product_id, v_no_answer);
    exception when others then null;
    end;

    insert into supplier_response_log
      (supplier_name, kind, outcome, inquiry_id, product_id, zone_id,
       asked_at, deadline_at, response_seconds, reason, detail)
    values (v_old, 'inquiry_timeout', 'no_response', v_id, r_inq.product_id,
            r_inq.zone_id, r_inq.asked_at, v_due,
            floor(extract(epoch from (now() - r_inq.asked_at)))::int,
            v_no_answer,
            jsonb_build_object('product_name', r_inq.product_name,
                               'inquiry_code', r_inq.inquiry_code));

    perform public.advance_to_next_supplier(v_id);

    select current_supplier into v_new_cur from inquiry where id = v_id;
    if v_new_cur is not null then
      insert into inquiry_forms (supplier_name, last_sent_at, expires_at, status,
                                 token, link_secret)
      values (v_new_cur, now(),
              now() + make_interval(mins => public.inquiry_deadline_minutes(r_inq.zone_id)),
              'pending', replace(gen_random_uuid()::text, '-', ''),
              public.gen_link_secret())
      on conflict on constraint inquiry_forms_supplier_name_key do update set
        last_sent_at = now(),
        expires_at   = now() + make_interval(
                         mins => public.inquiry_deadline_minutes(r_inq.zone_id)),
        status       = 'pending';
    end if;

    v_advanced := v_advanced + 1;
    if not (v_old = any(v_sups)) then v_sups := v_sups || v_old; end if;
  end loop;

  -- One notification per silent supplier per pass, never one per line.
  if array_length(v_sups, 1) is not null then
    begin
      perform public.notify('supplier_no_response', null,
        jsonb_build_object(
          'supplier_name', array_to_string(v_sups, ', '),
          'line_count',    v_advanced::text,
          'window_label',  public.fmt_duration_short(
                             public.inquiry_deadline_minutes(null) * 60)));
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'advanced', v_advanced,
                            'suppliers', to_jsonb(v_sups));
end $function$;

-- The existing sweep keeps its closed-shop pass and its form cleanup, and now
-- delegates the advance to the function above — OFF the inquiry_any_locked()
-- gate that made it dead code.
create or replace function public.sweep_inquiry_timeouts()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_old_sup text;
begin
  for v_old_sup in
    select distinct i2.current_supplier from inquiry i2
     where i2.current_supplier is not null
       and public.supplier_closed_now(i2.current_supplier)
  loop
    perform public._inquiry_advance_past_closed(v_old_sup);
  end loop;

  perform public.inquiry_timeout_advance();

  delete from inquiry_forms
   where status not in ('responded', 'partially_responded')
     and expires_at is not null and expires_at < now();
  delete from inquiry_forms f
   where f.status not in ('responded', 'partially_responded')
     and not exists (select 1 from inquiry i where i.current_supplier = f.supplier_name);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 6. THE ACCEPT CLOCK ON supplier_orders
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public._c687_stamp_accept_due()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.accept_due_at is null then
    new.accept_due_at := coalesce(new.auto_order_sent_at, new.created_at, now())
      + make_interval(mins => public.supplier_accept_deadline_minutes(new.zone_id));
  end if;
  return new;
end $function$;

drop trigger if exists trg_c687_accept_due on public.supplier_orders;
drop trigger if exists zz_c687_accept_due on public.supplier_orders;
create trigger zz_c687_accept_due
  before insert on public.supplier_orders
  for each row execute function public._c687_stamp_accept_due();

create or replace function public.supplier_po_deadline_block(
  p_due timestamptz, p_state text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select public.deadline_block(
    null, p_due, 'po',
    coalesce(nullif(p_state, ''), 'pending') <> 'pending');
$function$;

-- 'timeout' joins the state set. Everything else about this block is #527's.
create or replace function public.supplier_po_accept_block(
  p_state text, p_packed boolean, p_declined_reason text default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
    'state', coalesce(nullif(p_state,''),'pending'),
    'label', case coalesce(nullif(p_state,''),'pending')
               when 'accepted' then public.uic('supplier_po.state_accepted','Accepted')
               when 'partial'  then public.uic('supplier_po.state_partial','Partly accepted')
               when 'declined' then public.uic('supplier_po.state_declined','Declined')
               when 'timeout'  then public.uic('supplier_po.state_timeout',
                                               'No reply — sent to the next supplier')
               else public.uic('supplier_po.state_pending','Awaiting your reply') end,
    'tone', case coalesce(nullif(p_state,''),'pending')
              when 'accepted' then 'success'
              when 'partial'  then 'warning'
              when 'declined' then 'danger'
              when 'timeout'  then 'danger'
              else 'info' end,
    'title', public.uic('supplier_po.ack_title','Can you supply this order?'),
    'hint',  public.uic('supplier_po.ack_hint',''),
    'reason', nullif(btrim(coalesce(p_declined_reason,'')),''),
    'reason_label', public.uic('supplier_po.decline_reason',''),
    'needs_reply', (coalesce(nullif(p_state,''),'pending') = 'pending'),
    'actions', case when coalesce(nullif(p_state,''),'pending') = 'pending'
      then jsonb_build_array(
        jsonb_build_object('action','accept',
          'label', public.uic('supplier_po.action_accept','Accept order'), 'tone','brand'),
        jsonb_build_object('action','partial',
          'label', public.uic('supplier_po.action_partial','Accept part'), 'tone','neutral'),
        jsonb_build_object('action','decline',
          'label', public.uic('supplier_po.action_decline','Can''t supply'), 'tone','danger'))
      else '[]'::jsonb end,
    'can_pack', (coalesce(nullif(p_state,''),'pending') in ('accepted','partial')),
    'pack_blocked_reason',
      case when coalesce(nullif(p_state,''),'pending') in ('accepted','partial') then null
           when coalesce(nullif(p_state,''),'pending') = 'timeout'
             then public.uic('supplier_po.state_timeout',
                             'No reply — sent to the next supplier')
           else public.uic('supplier_po.pack_blocked',
                           'Accept the order before you mark it packed') end);
$function$;

-- The sweep. Only rows that HAVE a clock, so pre-#687 orders are untouched.
create or replace function public.supplier_accept_timeout_sweep()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row supplier_orders%rowtype; it jsonb; v_pid bigint; v_inq bigint;
  v_reassigned int := 0; v_orders int := 0; v_sups text[] := '{}';
  v_reason text := public.uic('supplier_po.timeout_reason', 'No reply before the deadline');
begin
  for v_row in
    select * from supplier_orders so
     where coalesce(so.accept_state, 'pending') = 'pending'
       and so.accept_due_at is not null
       and so.accept_due_at < now()
       and coalesce(so.packed, false) = false
       and coalesce(so.status, '') not in ('closed', 'cancelled')
     order by so.accept_due_at asc
     limit 100
  loop
    for it in select * from jsonb_array_elements(coalesce(v_row.items, '[]'::jsonb)) loop
      v_pid := nullif(it->>'product_id', '')::bigint;
      continue when v_pid is null;
      select i.id into v_inq from inquiry i
       where i.supplier_order_id = v_row.id and i.product_id = v_pid
       order by i.id desc limit 1;
      begin
        if v_inq is not null then
          perform public._inquiry_cascade_remainder(v_inq, v_row.supplier_name, 0,
                                                    'po_timeout');
        else
          perform public._reinquiry_exclude_and_advance(v_pid, v_row.supplier_name);
        end if;
        v_reassigned := v_reassigned + 1;
      exception when others then null;
      end;
    end loop;

    update supplier_orders
       set accept_state = 'timeout', accepted_at = now(), accepted_by = 'system',
           decline_reason = v_reason, status = 'closed',
           total_amount = 0, trade_total = 0
     where id = v_row.id;

    insert into supplier_response_log
      (supplier_name, kind, outcome, supplier_order_id, order_code, zone_id,
       asked_at, deadline_at, response_seconds, reason, detail)
    values (v_row.supplier_name, 'po_timeout', 'no_response', v_row.id,
            v_row.order_code, v_row.zone_id,
            coalesce(v_row.auto_order_sent_at, v_row.created_at), v_row.accept_due_at,
            floor(extract(epoch from (now()
              - coalesce(v_row.auto_order_sent_at, v_row.created_at))))::int,
            v_reason,
            jsonb_build_object('lines', coalesce(jsonb_array_length(v_row.items), 0)));

    v_orders := v_orders + 1;
    if not (v_row.supplier_name = any(v_sups)) then
      v_sups := v_sups || v_row.supplier_name;
    end if;
  end loop;

  if array_length(v_sups, 1) is not null then
    begin
      perform public.notify('supplier_no_response', null,
        jsonb_build_object('supplier_name', array_to_string(v_sups, ', '),
                           'line_count', v_reassigned::text,
                           'window_label', public.fmt_duration_short(
                             public.supplier_accept_deadline_minutes(null) * 60)));
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'orders', v_orders,
                            'reassigned', v_reassigned, 'suppliers', to_jsonb(v_sups));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 7. THE LEDGER GETS THE HUMAN ANSWERS TOO
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.supplier_response_note(
  p_supplier text, p_kind text, p_outcome text,
  p_supplier_order_id uuid default null, p_order_code text default null,
  p_inquiry_id bigint default null, p_product_id bigint default null,
  p_zone smallint default null, p_asked_at timestamptz default null,
  p_deadline_at timestamptz default null, p_reason text default null,
  p_detail jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path to 'public'
as $function$
  insert into supplier_response_log
    (supplier_name, kind, outcome, supplier_order_id, order_code, inquiry_id,
     product_id, zone_id, asked_at, deadline_at, responded_at, response_seconds,
     reason, detail)
  select coalesce(nullif(btrim(p_supplier), ''), 'unknown'), p_kind, p_outcome,
         p_supplier_order_id, p_order_code, p_inquiry_id, p_product_id, p_zone,
         p_asked_at, p_deadline_at, now(),
         case when p_asked_at is null then null
              else floor(extract(epoch from (now() - p_asked_at)))::int end,
         nullif(btrim(coalesce(p_reason, '')), ''), coalesce(p_detail, '{}'::jsonb);
$function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 8. THE SCORECARD INPUTS — response rate + median reply time
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.supplier_response_stats(
  p_supplier text default null, p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_asked int; v_answered int; v_missed int; v_median numeric; v_rate numeric;
  v_since timestamptz := now() - make_interval(days => greatest(1, coalesce(p_days, 30)));
begin
  select count(*) filter (where l.kind in ('inquiry_asked')),
         count(*) filter (where l.outcome in ('responded','accepted','partial','declined')),
         count(*) filter (where l.outcome = 'no_response'),
         percentile_cont(0.5) within group (
           order by l.response_seconds)
           filter (where l.response_seconds is not null
                     and l.outcome in ('responded','accepted','partial','declined'))
    into v_asked, v_answered, v_missed, v_median
  from supplier_response_log l
  where l.created_at >= v_since
    and (p_supplier is null
         or lower(btrim(l.supplier_name)) = lower(btrim(p_supplier)));

  v_asked    := coalesce(v_asked, 0);
  v_answered := coalesce(v_answered, 0);
  v_missed   := coalesce(v_missed, 0);
  v_rate := case when (v_answered + v_missed) = 0 then null
                 else round(100.0 * v_answered / (v_answered + v_missed), 0) end;

  return jsonb_build_object(
    'ok', true,
    'has',             ((v_answered + v_missed) > 0),
    'supplier',        coalesce(p_supplier, ''),
    'window_days',     greatest(1, coalesce(p_days, 30)),
    'title',           public.uic('spn.response_title', 'Response record'),
    'empty_label',     public.uic('spn.response_none', 'No inquiries yet'),
    'asked',           v_asked,
    'asked_label',     public.uic('spn.response_asked_label', 'Asked'),
    'asked_value',     (v_answered + v_missed)::text,
    'answered',        v_answered,
    'missed',          v_missed,
    'rate_label',      public.uic('spn.response_rate_label', 'Answered in time'),
    'rate_value',      case when v_rate is null then '—'
                            else to_char(v_rate, 'FM990') || '%' end,
    'rate_tone',       case when v_rate is null then 'info'
                            when v_rate >= 80 then 'success'
                            when v_rate >= 50 then 'warning'
                            else 'danger' end,
    'median_label',    public.uic('spn.response_median_label', 'Typical reply time'),
    'median_seconds',  case when v_median is null then null else round(v_median)::int end,
    'median_value',    case when v_median is null then '—'
                            else public.fmt_duration_short(round(v_median)::int) end);
end $function$;

create or replace function public.supplier_scorecard()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  sp     public.supplier_profiles%rowtype;
  v_id   uuid := public.my_supplier_id();
  v_rank int;
  v_of   int;
  v_act  boolean;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_supplier',
      'message', public._c('spn.not_supplier'));
  end if;
  select * into sp from public.supplier_profiles where id = v_id;

  v_act := (lower(btrim(coalesce(sp.status,''))) = 'active');

  if sp.zone_id is not null then
    select r.rnk, r.n into v_rank, v_of from (
      select s.id,
             rank() over (order by coalesce(s."SPN",0) desc)::int as rnk,
             count(*) over ()::int                                as n
        from public.supplier_profiles s
       where s.zone_id = sp.zone_id
         and s.approved = true
         and coalesce(s.is_deleted,false) = false
    ) r where r.id = sp.id;
  end if;

  return jsonb_build_object(
    'ok',        true,
    'title',     public._c('spn.title'),
    'subtitle',  public._c('spn.subtitle'),
    'spn', jsonb_build_object(
      'value', coalesce(sp."SPN",0),
      'label', public._c('spn.value_label'),
      'value_label', to_char(coalesce(sp."SPN",0), 'FM999,999,999')),
    'status', jsonb_build_object(
      'is_active', v_act,
      'label',     coalesce(nullif(btrim(coalesce(sp.status,'')),''), ''),
      'note',      case when v_act then public._c('spn.active_note')
                        else public._c('spn.inactive_note') end,
      'tone',      case when v_act then 'success' else 'warning' end),
    'rank', jsonb_build_object(
      'has',       (v_rank is not null),
      'label',     public._c('spn.rank_label'),
      'value',     coalesce(v_rank,0),
      'value_label', case when v_rank is null then ''
                          else '#' || v_rank::text end,
      'of_label',  case when v_of is null then public._c('spn.no_rank')
                        else replace(public._c('spn.rank_of'), '{n}', v_of::text) end),
    -- CHANGE #687: the response record is an SPN INPUT, shown to the supplier
    -- next to the points it will feed.
    'response',  public.supplier_response_stats(sp.supplier_name, 30),
    'components_label', public._c('spn.components_label'),
    'components', jsonb_build_array(
      jsonb_build_object('key','margin','label', public._c('spn.component_margin'),
        'points', coalesce(sp.margin_points,0),
        'points_label', to_char(coalesce(sp.margin_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.margin::text,'')),''),'')),
      jsonb_build_object('key','behaviour','label', public._c('spn.component_behaviour'),
        'points', coalesce(sp.behaviour_points,0),
        'points_label', to_char(coalesce(sp.behaviour_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.behaviour::text,'')),''),'')),
      jsonb_build_object('key','cd_condition','label', public._c('spn.component_cd_condition'),
        'points', coalesce(sp.cd_points,0),
        'points_label', to_char(coalesce(sp.cd_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.cd_condition::text,'')),''),'')),
      jsonb_build_object('key','payment_term','label', public._c('spn.component_payment_term'),
        'points', coalesce(sp.payment_term_points,0),
        'points_label', to_char(coalesce(sp.payment_term_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.payment_term::text,'')),''),'')),
      jsonb_build_object('key','ordered_medicine','label', public._c('spn.component_ordered_medicine'),
        'points', coalesce(sp.ordered_medicine_points,0),
        'points_label', to_char(coalesce(sp.ordered_medicine_points,0),'FM999,999,999'),
        'choice_label', '')));
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 9. deadline_at ON EVERY INQUIRY RPC
--    Three wrappers already sit in front of every inquiry payload, so the
--    countdown reaches the supplier tab, the public link page and the admin
--    inquiry tab without touching any of the cores.
-- ─────────────────────────────────────────────────────────────────────────

-- (a) per ITEM — #687 adds deadline_at/deadline; everything else is unchanged.
create or replace function public._inquiry_decorate_items(p_items jsonb, p_supplier text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_zone smallint; v_out jsonb;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return coalesce(p_items, '[]'::jsonb);
  end if;
  select sp.zone_id into v_zone from supplier_profiles sp
   where lower(btrim(sp.supplier_name)) = lower(btrim(coalesce(p_supplier,'')))
     and not coalesce(sp.is_deleted,false) limit 1;

  select jsonb_agg(
           e || jsonb_build_object(
             'company',  coalesce(m.marketer, e->>'company', ''),
             'category', coalesce(m.therapeutic_class, e->>'category', ''),
             'prestate', case when st.s = 'av' then 'Available' end,
             'editable', true,
             'asked_at', inq.asked_at,
             'deadline_at', inq.due_at,
             'deadline', public.deadline_block(inq.asked_at, inq.due_at, 'inquiry',
                                               coalesce(inq.settled, false)))
           order by lower(coalesce(m.marketer, e->>'company', 'zzz')),
                    lower(coalesce(m.therapeutic_class, e->>'category', 'zzz')),
                    lower(coalesce(m.product_name, e->>'product_name', ''))
         )
    into v_out
  from jsonb_array_elements(p_items) e
  left join lateral (
    select coalesce(
      nullif(e->>'product_id','')::bigint,
      (select i.product_id from inquiry i where i.id = nullif(e->>'inquiry_id','')::bigint)
    ) as pid) p on true
  left join "MEDICINE" m on m.id = p.pid
  left join lateral (select public.medicine_zone_state(p.pid, v_zone, p_supplier) as s) st on true
  left join lateral (
    select i.asked_at,
           i.asked_at + make_interval(mins => public.inquiry_deadline_minutes(i.zone_id))
             as due_at,
           (coalesce(i.current_status,'') = 'Available'
            or coalesce(i.inquiry_phase,'draft') not in ('draft','sent')) as settled
      from inquiry i
     where i.id = nullif(e->>'inquiry_id','')::bigint
     limit 1) inq on true;

  return coalesce(v_out, p_items);
end $function$;

-- (b) per PAYLOAD — the supplier tab's own header countdown.
create or replace function public._inquiry_decorate_payload(p jsonb, p_supplier text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare k text; v jsonb; e0 jsonb; arr jsonb; i int; el jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return p; end if;
  for k in select jsonb_object_keys(p) loop
    v := p->k;
    if jsonb_typeof(v) = 'array' and jsonb_array_length(v) > 0 then
      e0 := v->0;
      if jsonb_typeof(e0) = 'object' and (e0 ? 'inquiry_id' or e0 ? 'product_id') then
        p := jsonb_set(p, array[k], public._inquiry_decorate_items(v, p_supplier));
      elsif jsonb_typeof(e0) = 'object' and e0 ? 'items'
            and jsonb_typeof(e0->'items') = 'array' then
        arr := '[]'::jsonb;
        for i in 0..jsonb_array_length(v)-1 loop
          el := v->i;
          el := jsonb_set(el, '{items}', public._inquiry_decorate_items(el->'items', p_supplier));
          arr := arr || el;
        end loop;
        p := jsonb_set(p, array[k], arr);
      end if;
    end if;
  end loop;
  -- CHANGE #687: one countdown for the whole screen, the nearest live deadline.
  p := p || jsonb_build_object('deadline', public.inquiry_supplier_deadline(p_supplier));
  return p;
end $function$;

-- (c) the PUBLIC LINK PAGE.
create or replace function public.get_inquiry_form(p_token text, p_secret text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  v := public._get_inquiry_form_core(p_token, p_secret);
  if v ? 'items' and v ? 'supplier_name' then
    v := jsonb_set(v, '{items}', public._inquiry_decorate_items(v->'items', v->>'supplier_name'));
    v := jsonb_set(v, '{items}', public._inquiry_partial_qty_items(v->'items'));
    v := v || jsonb_build_object(
                'deadline', public.inquiry_supplier_deadline(v->>'supplier_name'));
  end if;
  return v;
end $function$;

drop function if exists public.get_supplier_inquiry_overview();

-- (d) the ADMIN inquiry tab — one row per supplier, each with its own clock
--     and its own "no response" count from the ledger.
create or replace function public.get_supplier_inquiry_overview()
returns table(supplier_name text, current_count bigint, next_count bigint, token text,
              form_status text, expires_at timestamp with time zone, inquiry_code text,
              rnk integer, is_open boolean, can_send boolean, needs_auto_send boolean,
              send_button jsonb, deadline jsonb, response jsonb)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_suppliers text[]; v_sup text; v_current_count bigint; v_row inquiry%rowtype;
  v_slotidx int; v_ps text; v_as text; v_token text; v_fstatus text;
  v_expires timestamptz; v_code text; v_wa_sent timestamptz;
  v_engine boolean; v_lock boolean; v_auto boolean;
  v_ranked jsonb; v_rnk int; v_isopen boolean; v_cansend boolean; v_needsauto boolean;
begin
  v_engine := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_engine_mode'), false);
  v_lock   := public.inquiry_locked();
  v_auto   := COALESCE((SELECT (value #>> '{}')::boolean FROM app_settings WHERE key='inquiry_auto_meta'), false);

  SELECT jsonb_object_agg(rs.supplier_name, jsonb_build_object('rnk',rs.rnk,'is_open',rs.is_open))
    INTO v_ranked FROM inquiry_engine_ranked_suppliers() rs;
  v_ranked := COALESCE(v_ranked, '{}'::jsonb);

  select array_agg(distinct inq.current_supplier) into v_suppliers
  from inquiry inq where inq.current_supplier is not null;
  if v_suppliers is null then return; end if;

  foreach v_sup in array v_suppliers loop
    v_current_count := 0;
    for v_row in select * from inquiry inq where inq.current_supplier = v_sup loop
      if inquiry_demand_qty(v_row.product_id, v_sup, true) <= 0 then continue; end if;
      if public.inq_is_ordered(v_row.supplier_order_id, v_row.batch_date) then continue; end if;
      for v_slotidx in 1..30 loop
        execute format('select ($1).%I, ($1).%I', 'PS'||v_slotidx, 'AS'||v_slotidx)
          into v_ps, v_as using v_row;
        if v_ps = v_sup then
          if v_as is null or btrim(v_as) = '' then v_current_count := v_current_count + 1; end if;
          exit;
        end if;
        v_as := null;
      end loop;
    end loop;
    if v_current_count = 0 then continue; end if;

    select f.token, f.status, f.expires_at, f.auto_wa_sent_at
      into v_token, v_fstatus, v_expires, v_wa_sent
    from inquiry_forms f where f.supplier_name = v_sup;
    if v_fstatus = 'expired' or (v_expires is not null and v_expires < now()) then
      v_token := null; v_fstatus := null; v_expires := null;
    end if;

    select i.inquiry_code into v_code from inquiry i
    where i.current_supplier = v_sup and i.inquiry_code is not null
      and btrim(i.inquiry_code) <> '' order by i.id limit 1;

    v_rnk    := (v_ranked -> v_sup ->> 'rnk')::int;
    v_isopen := COALESCE((v_ranked -> v_sup ->> 'is_open')::boolean, false);
    v_cansend := CASE
      WHEN NOT v_engine THEN true
      WHEN v_lock AND v_isopen THEN true
      ELSE false
    END;
    v_needsauto := (v_engine AND v_auto AND v_lock AND v_isopen
                    AND COALESCE(v_fstatus,'') = 'pending' AND v_wa_sent IS NULL);

    return query select v_sup, v_current_count, 0::bigint, v_token, v_fstatus, v_expires,
                        v_code, v_rnk, v_isopen, v_cansend, v_needsauto,
                        public._sup_inquiry_send_state(v_code),
                        public.inquiry_supplier_deadline(v_sup),
                        public.supplier_response_stats(v_sup, 30);
  end loop;
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 10. THE HUMAN ANSWERS GET LOGGED TOO — accept / partial / decline
--     Same body as #527's, with the ledger write and nothing else changed.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.supplier_respond_order(
  p_order_code text, p_action text, p_reason text default null, p_lines jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_self text; v_is_admin boolean; v_row supplier_orders%rowtype;
  v_res jsonb; v_started timestamptz;
begin
  select * into v_row from supplier_orders
   where order_code = p_order_code or id::text = p_order_code limit 1;

  v_res := public._c687_respond_order_core(p_order_code, p_action, p_reason, p_lines);

  if coalesce((v_res->>'ok')::boolean, false) and v_row.id is not null
     and p_action in ('accept','partial','decline') then
    select sp.supplier_name into v_self from current_supplier_profile() sp;
    v_started := coalesce(v_row.auto_order_sent_at, v_row.created_at);
    perform public.supplier_response_note(
      coalesce(v_row.supplier_name, v_self),
      'po_' || p_action,
      case p_action when 'decline' then 'declined' else p_action end,
      v_row.id, v_row.order_code, null, null, v_row.zone_id,
      v_started, v_row.accept_due_at,
      case when p_action = 'decline' then p_reason end,
      jsonb_build_object('cascaded', coalesce(v_res->'cascaded', to_jsonb(0)),
                         'on_time', (v_row.accept_due_at is null
                                     or now() <= v_row.accept_due_at)));
  end if;

  return v_res;
end $function$;

-- The #527 body, verbatim, moved behind a name so #687 can wrap it with the
-- response ledger without forking the logic.
CREATE OR REPLACE FUNCTION public._c687_respond_order_core(p_order_code text, p_action text, p_reason text DEFAULT NULL::text, p_lines jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_self text; v_is_admin boolean; v_row supplier_orders%rowtype;
  it jsonb; v_items jsonb := '[]'::jsonb; v_kept numeric; v_ask numeric;
  v_inq bigint; v_cascaded int := 0; v_split jsonb; v_splits jsonb := '[]'::jsonb;
  v_state text; v_actor text; v_pid bigint; v_line jsonb;
begin
  if p_action not in ('accept','partial','decline') then
    return jsonb_build_object('ok', false, 'error', 'bad_action',
      'message', public.uic('supplier_po.err_action','Choose accept, part accept or decline'));
  end if;

  select sp.supplier_name into v_self from current_supplier_profile() sp;
  v_is_admin := get_my_role() in ('admin','super_admin');

  select * into v_row from supplier_orders
   where order_code = p_order_code or id::text = p_order_code limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.uic('supplier_po.err_not_found','That order is not on your account.'));
  end if;

  if not v_is_admin and lower(btrim(v_row.supplier_name)) <> lower(btrim(coalesce(v_self,''))) then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', public.uic('supplier_po.err_not_found','That order is not on your account.'));
  end if;

  if v_row.accept_state = 'declined' then
    return jsonb_build_object('ok', false, 'error', 'already_declined',
      'message', public.uic('supplier_po.err_declined','This order was already declined'));
  end if;

  -- CHANGE #687: a timed-out order has already been reassigned down the
  -- cascade. Answering it now would double-supply the line.
  if v_row.accept_state = 'timeout' then
    return jsonb_build_object('ok', false, 'error', 'accept_timeout',
      'accept', public.supplier_po_accept_block('timeout', false, v_row.decline_reason),
      'message', public.uic('supplier_po.state_timeout',
                            'No reply — sent to the next supplier'));
  end if;

  v_actor := coalesce(v_self, get_my_role(), 'supplier');

  if p_action = 'accept' then
    update supplier_orders
       set accept_state = 'accepted', accepted_at = now(), accepted_by = v_actor,
           decline_reason = null
     where id = v_row.id;
    return jsonb_build_object('ok', true, 'order_code', v_row.order_code,
      'accept', public.supplier_po_accept_block('accepted', coalesce(v_row.packed,false)),
      'cascaded', 0,
      'message', public.uic('supplier_po.accepted_toast','Order accepted'));
  end if;

  if p_action = 'decline' then
    for it in select * from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) loop
      v_pid := nullif(it->>'product_id','')::bigint;
      if v_pid is null then continue; end if;
      select i.id into v_inq from inquiry i
       where i.supplier_order_id = v_row.id and i.product_id = v_pid
       order by i.id desc limit 1;
      if v_inq is not null then
        v_split := public._inquiry_cascade_remainder(v_inq, v_row.supplier_name, 0, 'po_declined');
      else
        perform public._reinquiry_exclude_and_advance(v_pid, v_row.supplier_name);
        v_split := jsonb_build_object('ok', true, 'product_id', v_pid, 'via', 'reinquiry');
      end if;
      v_splits := v_splits || jsonb_build_array(v_split);
      v_cascaded := v_cascaded + 1;
    end loop;

    update supplier_orders
       set accept_state = 'declined', accepted_at = now(), accepted_by = v_actor,
           decline_reason = nullif(btrim(coalesce(p_reason,'')),''),
           status = 'closed', total_amount = 0, trade_total = 0
     where id = v_row.id;

    return jsonb_build_object('ok', true, 'order_code', v_row.order_code,
      'accept', public.supplier_po_accept_block('declined', false, p_reason),
      'cascaded', v_cascaded, 'splits', v_splits,
      'message', public.uic('supplier_po.declined_toast','Order declined — sent to the next supplier'));
  end if;

  if p_lines is null or jsonb_array_length(coalesce(p_lines,'[]'::jsonb)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_lines',
      'message', public.uic('supplier_po.err_no_lines','Enter the quantity you can supply for at least one item'));
  end if;

  for it in select * from jsonb_array_elements(coalesce(v_row.items,'[]'::jsonb)) loop
    v_pid := nullif(it->>'product_id','')::bigint;
    v_ask := coalesce(nullif(it->>'quantity','')::numeric, 0);

    v_line := null;
    select l.value into v_line from jsonb_array_elements(p_lines) l
     where nullif(l.value->>'product_id','')::bigint = v_pid limit 1;

    if v_line is null then
      v_items := v_items || jsonb_build_array(it);
      continue;
    end if;

    v_kept := greatest(least(coalesce(nullif(v_line->>'accepted_qty','')::numeric, v_ask), v_ask), 0);

    if v_kept > 0 then
      v_items := v_items || jsonb_build_array(
        it || jsonb_build_object('quantity', v_kept, 'asked_qty', v_ask,
                                 'partial', (v_kept < v_ask)));
    end if;

    if v_kept < v_ask and v_pid is not null then
      select i.id into v_inq from inquiry i
       where i.supplier_order_id = v_row.id and i.product_id = v_pid
       order by i.id desc limit 1;
      if v_inq is not null then
        v_split := public._inquiry_cascade_remainder(v_inq, v_row.supplier_name, v_kept, 'po_partial_accept');
      else
        perform public._reinquiry_exclude_and_advance(v_pid, v_row.supplier_name);
        v_split := jsonb_build_object('ok', true, 'product_id', v_pid, 'via', 'reinquiry');
      end if;
      v_splits := v_splits || jsonb_build_array(v_split);
      v_cascaded := v_cascaded + 1;
    end if;
  end loop;

  v_state := case when jsonb_array_length(v_items) = 0 then 'declined'
                  when v_cascaded > 0 then 'partial'
                  else 'accepted' end;

  update supplier_orders
     set items = case when v_state='declined' then v_row.items else v_items end,
         accept_state = v_state, accepted_at = now(), accepted_by = v_actor,
         decline_reason = case when v_state='declined' then nullif(btrim(coalesce(p_reason,'')),'') end,
         status = case when v_state='declined' then 'closed' else status end,
         total_amount = case when v_state='declined' then 0 else total_amount end
   where id = v_row.id;
  if v_state <> 'declined' then perform public.po_retotal(v_row.id); end if;

  return jsonb_build_object('ok', true, 'order_code', v_row.order_code,
    'accept', public.supplier_po_accept_block(v_state, coalesce(v_row.packed,false), p_reason),
    'cascaded', v_cascaded, 'splits', v_splits,
    'message', case when v_state = 'declined'
      then public.uic('supplier_po.declined_toast','Order declined — sent to the next supplier')
      else public.uicf('supplier_po.partial_toast', jsonb_build_object('n', v_cascaded::text),
             'Part accepted — {n} item(s) sent to the next supplier') end);
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 11. THE PO CARD GETS THE CLOCK
--     supplier_my_orders keeps its shape; `accept` grows a `deadline` block.
-- ─────────────────────────────────────────────────────────────────────────
create or replace function public.supplier_my_orders(p_supplier_id uuid default null)
returns table(order_id uuid, order_no integer, created_at timestamp with time zone,
              status text, total_amount numeric, item_count integer, items jsonb,
              order_code text, packed boolean, packed_via text, pack_button jsonb,
              pricing jsonb, accept jsonb, line_details jsonb)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_name text;
begin
  if p_supplier_id is null then
    select sp.supplier_name into v_name from current_supplier_profile() sp;
  else
    if get_my_role() <> 'super_admin' then RETURN; end if;
    select sp.supplier_name into v_name from supplier_profiles sp where sp.id = p_supplier_id;
  end if;
  if v_name is null then return; end if;

  return query
  select so.id, so.order_no, so.created_at, so.status, so.total_amount,
         coalesce(jsonb_array_length(so.items),0) as item_count,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'product_id',        it->>'product_id',
                    'product_name',      it->>'product_name',
                    'quantity',          (it->>'quantity')::numeric,
                    'asked_qty',         it->'asked_qty',
                    'partial',           coalesce((it->>'partial')::boolean, false),
                    'pack_type',         nullif(btrim(med.pack_type),''),
                    'image_url',         nullif(btrim(med.image_url_1),''),
                    'therapeutic_class', nullif(btrim(med.therapeutic_class),''),
                    'company',           nullif(btrim(med.marketer),''),
                    'rate',              it->'rate',
                    'rate_source',       it->>'rate_source',
                    'rate_display',      it->>'rate_display',
                    'mrp_display',       it->>'mrp_display',
                    'line_total',        it->'line_total',
                    'line_total_display', it->>'line_total_display',
                    'price_basis_label', it->>'price_basis_label',
                    'batch_no',          d.batch_no,
                    'expiry',            d.expiry,
                    'hsn',               d.hsn
                  ) order by it->>'product_name')
           from jsonb_array_elements(so.items) it
           left join "MEDICINE" med on med.id = (it->>'product_id')::bigint
           left join public.supplier_order_line_detail d
                  on d.supplier_order_id = so.id
                 and d.product_id = (it->>'product_id')::bigint
         ), '[]'::jsonb) as items,
         so.order_code,
         coalesce(so.packed,false) as packed,
         so.packed_via,
         jsonb_build_object(
           'label',       case when coalesce(so.packed,false) then 'Packed ✓' else 'Mark Packed' end,
           'next_packed', not coalesce(so.packed,false),
           'enabled',     (coalesce(so.accept_state,'pending') in ('accepted','partial')),
           'blocked_reason',
             case when coalesce(so.accept_state,'pending') in ('accepted','partial') then null
                  else public.uic('supplier_po.pack_blocked','Accept the order before you mark it packed') end,
           'bg',          case when coalesce(so.packed,false) then '#E1F5EE' else '#1B7A43' end,
           'fg',          case when coalesce(so.packed,false) then '#0F6E56' else '#FFFFFF' end
         ) as pack_button,
         public.po_pricing_block(so.id) as pricing,
         -- CHANGE #687: the same accept block, plus the countdown the supplier
         -- is racing. Absent clock (pre-#687 rows) => has:false => nothing draws.
         (public.supplier_po_accept_block(coalesce(so.accept_state,'pending'),
                                          coalesce(so.packed,false), so.decline_reason)
          || jsonb_build_object('deadline',
               public.supplier_po_deadline_block(so.accept_due_at,
                                                 coalesce(so.accept_state,'pending')))) as accept,
         jsonb_build_object(
           'title',        public.uic('supplier_po.details_title','Batch & expiry'),
           'hint',         public.uic('supplier_po.details_hint','Required on the purchase bill'),
           'batch_label',  public.uic('supplier_po.batch_label','Batch no.'),
           'expiry_label', public.uic('supplier_po.expiry_label','Expiry (MM/YY)'),
           'hsn_label',    public.uic('supplier_po.hsn_label','HSN'),
           'save_label',   public.uic('supplier_po.save_details','Save batch & expiry'),
           'status_label',
             case when exists (select 1 from public.supplier_order_line_detail d
                                where d.supplier_order_id = so.id
                                  and d.batch_no is not null and d.expiry is not null)
                  then public.uic('supplier_po.details_done','Batch and expiry filled')
                  else public.uic('supplier_po.details_missing','Batch and expiry not filled') end,
           'complete',
             not exists (select 1 from jsonb_array_elements(coalesce(so.items,'[]'::jsonb)) it2
                          where not exists (select 1 from public.supplier_order_line_detail d2
                                             where d2.supplier_order_id = so.id
                                               and d2.product_id = (it2->>'product_id')::bigint
                                               and d2.batch_no is not null
                                               and d2.expiry is not null))
         ) as line_details
  from supplier_orders so
  where so.supplier_name = v_name
  order by so.created_at desc, so.order_no desc;
end $function$;

-- ─────────────────────────────────────────────────────────────────────────
-- 12. THE ADMIN/PARTNER NOTIFICATION ROUTE
--     notify() is fully defensive: no Meta template just queues the message,
--     it never raises. Push and email are on so the alert lands today.
-- ─────────────────────────────────────────────────────────────────────────
insert into public.wa_event_routes
  (event_key, label, description, audience, enabled, auto_manage, marketing_guard,
   dedupe_minutes, language, push_enabled, email_enabled, email_mode, wa_category,
   push_title, push_body, email_subject, email_body)
values
  ('supplier_no_response',
   'Supplier did not answer in time',
   'CHANGE #687 — raised when the response deadline passes and the line (or the '
   'whole supplier order) is auto-advanced to the next ranked supplier.',
   'admin', true, false, true, 15, 'en', true, true, 'always', 'utility',
   'Supplier did not reply',
   '{{supplier_name}} did not answer {{line_count}} item(s) within {{window_label}} — moved to the next supplier.',
   'Supplier did not reply in time',
   '{{supplier_name}} did not answer {{line_count}} item(s) within {{window_label}}. '
   'They have been moved to the next ranked supplier automatically.')
on conflict (event_key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────
-- 13. THE CRON DISPATCHER — the gate now uses the CONFIGURED window
--     (the old one hard-coded 10 minutes, so retuning the deadline could not
--     open the gate that runs the advance).
-- ─────────────────────────────────────────────────────────────────────────
update public.cron_task set
  gate_sql = $gate$
select exists (select 1 from public.inquiry i
        where i.current_supplier is not null and i.asked_at is not null
          and coalesce(i.current_status,'') <> 'Available'
          and coalesce(i.inquiry_phase,'draft') in ('draft','sent')
          and i.asked_at < now()
              - make_interval(mins => public.inquiry_deadline_minutes(i.zone_id)))
    or exists (select 1 from public.inquiry_forms
        where status not in ('responded','partially_responded')
          and expires_at is not null and expires_at < now())
    or exists (select 1 from public.inquiry_forms f
        where f.status not in ('responded','partially_responded')
          and not exists (select 1 from public.inquiry i
                          where i.current_supplier = f.supplier_name))
    or exists (select 1 from public.inquiry i2
        where i2.current_supplier is not null
          and public.supplier_closed_now(i2.current_supplier))
$gate$,
  note = 'Timeout advance + expiring the supplier form. CHANGE #687: the window '
         'is inquiry_deadline_minutes(zone), not a 10-minute literal, and the '
         'advance no longer sits behind inquiry_any_locked() — which is why it '
         'had never fired.',
  enabled = true
where name = 'inquiry_sweep_timeouts';

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, enabled, note, dml)
values (
  'supplier_accept_timeout', 35, 'poll',
  $gate$
select exists (select 1 from public.supplier_orders so
        where coalesce(so.accept_state,'pending') = 'pending'
          and so.accept_due_at is not null and so.accept_due_at < now()
          and coalesce(so.packed,false) = false
          and coalesce(so.status,'') not in ('closed','cancelled'))
$gate$,
  'select public.supplier_accept_timeout_sweep()',
  true,
  'CHANGE #687 — a supplier order nobody answered before accept_due_at is '
  'reassigned down the same cascade a decline uses. Only rows that HAVE a '
  'clock are considered, so pre-#687 orders are never swept.',
  true)
on conflict (name) do update set
  gate_sql = excluded.gate_sql,
  work_sql = excluded.work_sql,
  enabled  = excluded.enabled,
  note     = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────
-- 14. GRANTS — the public link page is anon, the rest is role-gated inside
--      the SECURITY DEFINER bodies exactly as before.
-- ─────────────────────────────────────────────────────────────────────────
grant execute on function public.fmt_duration_short(integer)                to anon, authenticated;
grant execute on function public.deadline_block(timestamptz, timestamptz, text, boolean)
                                                                            to anon, authenticated;
grant execute on function public.inquiry_deadline_minutes(smallint)         to anon, authenticated;
grant execute on function public.supplier_accept_deadline_minutes(smallint) to anon, authenticated;
grant execute on function public.inquiry_deadline_at(bigint)                to anon, authenticated;
grant execute on function public.inquiry_supplier_deadline(text)            to anon, authenticated;
grant execute on function public.supplier_response_stats(text, integer)     to authenticated;
grant execute on function public.supplier_po_deadline_block(timestamptz, text)
                                                                            to anon, authenticated;
grant execute on function public.get_supplier_inquiry_overview()
                                                                            to anon, authenticated;
