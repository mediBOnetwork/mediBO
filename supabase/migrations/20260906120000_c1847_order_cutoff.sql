-- replay-target: production
-- CMD #1847 — Order-hours cutoff, unpaid auto-cancel and the restoration window.
--
-- Every knob Om asked for lives on the settings row that ALREADY carries his
-- auto-cancel (order_alert_config), the cutoff time lives on the per-zone table
-- that ALREADY carries order hours (order_hours), the never-auto-cancel mark
-- lives on the per-customer row that ALREADY carries the credit policy
-- (customer_credit), the cancel goes through the ONE cancel path
-- (_order_cancel_core), the hold is an order_hold row (#708), the warnings ride
-- notify()/wa_event_routes, the audit is audit_write() into audit_log, and the
-- inquiry is blocked by a sixth check inside inquiry_send_readiness().
--
-- The only genuinely new object is order_cutoff_run: per-order RUNTIME state
-- for the day's clock (when the cutoff lands for this order, which warnings
-- went, how many minutes it was extended by, when the restore window shuts, and
-- the snapshot a restore replays). That is state, not settings.

-- ── 1. CONFIG, on the rows that already exist ────────────────────────────────
alter table public.order_hours
  add column if not exists cutoff_time time;

alter table public.order_alert_config
  add column if not exists cutoff_enabled             boolean not null default true,
  add column if not exists cutoff_default_time        time    not null default '12:00',
  add column if not exists cutoff_warn1_min           int     not null default 120,
  add column if not exists cutoff_warn2_min           int     not null default 30,
  add column if not exists cutoff_cancel_after_min    int     not null default 0,
  add column if not exists cutoff_restore_min         int     not null default 20,
  add column if not exists cutoff_extend_min          int     not null default 10,
  add column if not exists cutoff_pause_outside_hours boolean not null default true,
  add column if not exists cutoff_behaviour           text    not null default 'cancel',
  add column if not exists cutoff_warn_text           text    not null default '';

alter table public.customer_credit
  add column if not exists never_auto_cancel boolean not null default false;

-- The singleton must exist for _oa_cfg() to return anything. Existing values
-- are never touched.
insert into public.order_alert_config(id) values ('singleton')
on conflict (id) do nothing;

-- ── 2. THE CLOCK (the one new object) ────────────────────────────────────────
create table if not exists public.order_cutoff_run (
  order_id           uuid primary key references public.orders(id) on delete cascade,
  zone_id            smallint,
  cutoff_on          date        not null,
  cutoff_at          timestamptz not null,
  state              text        not null default 'watching',
  extra_min          int         not null default 0,
  exempt             boolean     not null default false,
  warn1_at           timestamptz,
  warn2_at           timestamptz,
  acted_at           timestamptz,
  restore_until      timestamptz,
  restore_extra_min  int         not null default 0,
  snapshot           jsonb,
  reason             text        not null default '',
  restored_at        timestamptz,
  restored_by        text,
  updated_at         timestamptz not null default now()
);
create index if not exists order_cutoff_run_day_idx
  on public.order_cutoff_run (cutoff_on, zone_id, state);
alter table public.order_cutoff_run enable row level security;
revoke all on public.order_cutoff_run from anon, authenticated;

-- ── 3. COPY, ROUTES, REASON — every word a row, none of it a literal ─────────
insert into public.ui_copy(key, value) values
  ('order_change.reason_cutoff_passed',
   to_jsonb('Today''s order cut-off has passed — contact support to change this order.'::text))
on conflict (key) do nothing;

insert into public.order_reason_option(code, label, scope, active)
select 'unpaid_cutoff', 'Advance not paid by cut-off', 'cancel', true
where not exists (select 1 from public.order_reason_option
                   where scope = 'cancel' and code = 'unpaid_cutoff');

update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb) || jsonb_build_object(
     'section_cutoff',        'Order cut-off & auto-cancel',
     'field_cutoff_enabled',  'Cut-off rule on',
     'field_cutoff_time',     'Cut-off time (this zone)',
     'field_cutoff_default',  'Default cut-off time',
     'field_cutoff_warn1',    'First warning (minutes before)',
     'field_cutoff_warn2',    'Second warning (minutes before)',
     'field_cutoff_cancel',   'Act this many minutes after cut-off',
     'field_cutoff_restore',  'Restoration window (minutes)',
     'field_cutoff_extend',   'Extend button (+minutes)',
     'field_cutoff_pause',    'Pause outside order hours',
     'field_cutoff_behaviour','At cut-off: cancel or hold',
     'field_cutoff_warntext', 'Warning message',
     'cutoff_clock_title',    'On the clock',
     'cutoff_clock_empty',    'No order is on the cut-off clock for this zone and date.',
     'cutoff_never_label',    'Never auto-cancel this pharmacy',
     'cutoff_restore_label',  'Restore',
     'cutoff_extend_label',   'Extend window',
     'cutoff_cancel_now_label','Cancel now',
     'cutoff_exempt_label',   'Exempt this order',
     'cutoff_unexempt_label', 'Put back on the clock',
     'cutoff_saved',          'Saved.',
     'cutoff_restored',       'Order restored — items, quantities and prices are as they were.',
     'cutoff_restore_closed', 'The restoration window for this order has closed.',
     'cutoff_window_open',    'Restoration window open — the inquiry is held until it closes.',
     'cutoff_inquiry_check',  'Restoration window',
     'cutoff_state_watching', 'On the clock',
     'cutoff_state_warned',   'Warned',
     'cutoff_state_cancelled','Auto-cancelled',
     'cutoff_state_held',     'Payment pending',
     'cutoff_state_restored', 'Restored',
     'cutoff_state_exempt',   'Exempt',
     'cutoff_state_paid',     'Advance paid',
     'cutoff_behaviour_cancel','cancel',
     'cutoff_behaviour_hold', 'hold',
     'cutoff_warn_default',   'Namaste {{customer}} 🙏 Order {{order_code}} needs its advance of {{amount}} before {{cutoff}} or it will be cancelled today. Pay here: {{pay_link}}')
 where id = 'singleton';

update public.order_alert_config
   set cutoff_warn_text = coalesce(labels->>'cutoff_warn_default','')
 where id = 'singleton' and coalesce(cutoff_warn_text,'') = '';

insert into public.wa_event_routes(event_key, label, description, template_name,
       language, variable_map, enabled, audience, push_enabled, email_enabled,
       push_title, auto_manage, dedupe_minutes, marketing_guard)
select 'order_cutoff_warning',
       'Advance reminder before cut-off',
       'CMD #1847 — the first reminder that an unpaid order will be cancelled at the cut-off.',
       'order_cutoff_warning', 'en',
       '["{{customer}}", "{{order_code}}", "{{amount}}", "{{cutoff}}", "{{pay_link}}"]'::jsonb,
       true, 'customer', true, false, 'Advance pending', true, 45, false
where not exists (select 1 from public.wa_event_routes where event_key = 'order_cutoff_warning');

insert into public.wa_event_routes(event_key, label, description, template_name,
       language, variable_map, enabled, audience, push_enabled, email_enabled,
       push_title, auto_manage, dedupe_minutes, marketing_guard)
select 'order_cutoff_final_warning',
       'Final advance reminder before cut-off',
       'CMD #1847 — the last reminder before the cut-off cancels an unpaid order.',
       'order_cutoff_final_warning', 'en',
       '["{{customer}}", "{{order_code}}", "{{amount}}", "{{cutoff}}", "{{pay_link}}"]'::jsonb,
       true, 'customer', true, false, 'Last call — advance pending', true, 20, false
where not exists (select 1 from public.wa_event_routes where event_key = 'order_cutoff_final_warning');

insert into public.wa_event_routes(event_key, label, description, template_name,
       language, variable_map, enabled, audience, push_enabled, email_enabled,
       push_title, auto_manage, dedupe_minutes, marketing_guard)
select 'order_cutoff_cancelled',
       'Order cancelled at cut-off',
       'CMD #1847 — the order was cancelled because no advance was verified by the cut-off.',
       'order_cutoff_cancelled', 'en',
       '["{{customer}}", "{{order_code}}", "{{amount}}", "{{cutoff}}"]'::jsonb,
       true, 'customer', true, false, 'Order cancelled', true, 0, false
where not exists (select 1 from public.wa_event_routes where event_key = 'order_cutoff_cancelled');
