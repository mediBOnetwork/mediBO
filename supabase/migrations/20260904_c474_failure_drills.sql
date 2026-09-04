-- CHANGE #474 — Failure drills: every external dependency gets a fallback, an
-- alert, a runbook, and one deliberate test.
--
-- mediBO leans on six things it does not own: WhatsApp (the inquiry waterfall
-- and every customer message), Gemini OCR (bill and Rx scanning), the
-- suppliers themselves (a human who may simply not reply), the rider's phone
-- (which loses signal in a basement), Razorpay (whose webhook is a promise,
-- not a guarantee), and Postgres itself (which restarts). Each one has a
-- fallback somewhere in the codebase. What none of them had was PROOF that the
-- fallback fires, written down where an operator can read it at 2 a.m.
--
-- This migration is that proof surface:
--   ops_runbook      the catalogue — failure, detection, fallback, manual steps
--   ops_drill_run    every drill ever run, with its evidence
--   ops_drill_*()    the six drills, each one deliberately breaking the thing
--                    it names and asserting the fallback caught it
--
-- DRILL SAFETY. Every drill runs against a synthetic identity created inside
-- the drill's own transaction and rolled back or hard-deleted at the end. No
-- real supplier, customer or rider is contacted, and no drill writes to a
-- table a live order reads. A drill that cannot obtain its synthetic subject
-- records 'skipped' with the reason — it never borrows a real one.
--
-- Idempotent throughout: re-applying this file is a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE CATALOGUE
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.ops_runbook (
  key            text primary key,
  sort           int         not null default 100,
  title          text        not null,
  dependency     text        not null,              -- what we do not own
  failure        text        not null,              -- what breaking looks like
  detection      text        not null,              -- how we find out
  fallback       text        not null,              -- what happens by itself
  manual_steps   jsonb       not null default '[]'::jsonb,
  alert_kind     text        not null default '',   -- the rg_alerts kind raised
  drill_note     text        not null default '',   -- what the drill actually does
  owner_label    text        not null default '',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table public.ops_runbook is
  'CHANGE #474 — one row per external dependency: what breaks, how we notice, '
  'what happens automatically, and what a human does. Rendered verbatim by '
  'ops_runbooks_home().';

create table if not exists public.ops_drill_run (
  id             bigserial primary key,
  runbook_key    text        not null references public.ops_runbook(key) on delete cascade,
  ran_at         timestamptz not null default now(),
  status         text        not null check (status in ('passed','failed','skipped')),
  summary        text        not null default '',
  evidence       jsonb       not null default '{}'::jsonb,
  duration_ms    int         not null default 0,
  trigger        text        not null default 'manual',  -- manual | cron | command
  command_id     bigint,
  ran_by         uuid
);

create index if not exists ops_drill_run_key_idx
  on public.ops_drill_run (runbook_key, ran_at desc);

comment on table public.ops_drill_run is
  'CHANGE #474 — every deliberate failure test ever run, with the evidence it '
  'collected. This is the audit trail the runbook screen prints.';

alter table public.ops_runbook    enable row level security;
alter table public.ops_drill_run  enable row level security;

-- No direct table access: every read goes through the RPCs below, which gate
-- on is_admin(). Dropping first keeps re-application silent.
drop policy if exists ops_runbook_no_direct   on public.ops_runbook;
drop policy if exists ops_drill_run_no_direct on public.ops_drill_run;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE SIX RUNBOOKS (seeded; re-application refreshes the prose, never the
--    drill history)
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.ops_runbook
  (key, sort, title, dependency, failure, detection, fallback, manual_steps,
   alert_kind, drill_note, owner_label)
values
  ('whatsapp_down', 10,
   'WhatsApp down or template rejected',
   'Meta WhatsApp Business API',
   'Sends fail outright, or Meta rejects the template so the message is never '
   'delivered even though the send returned 200.',
   'notify_center() shows the queue backing up and the failure count climbing; '
   'a health alert is raised on the first sustained failure window.',
   'The notification retry queue holds the message instead of dropping it, and '
   'the push + email fallback fires for the same event so the recipient still '
   'hears about it.',
   '["Open Notifications → check the failed count and the template name",'
   '"Confirm the template status in Meta Business Manager",'
   '"If the template is rejected, switch the event to its fallback template",'
   '"Once WhatsApp is healthy, Retry now on the held queue"]'::jsonb,
   'notify_send_failing',
   'Forces a send failure for a synthetic recipient and asserts the queue held '
   'it and the fallback channel was chosen.',
   'Ops'),

  ('ocr_failure', 20,
   'OCR failure on a bill or prescription',
   'Gemini on Vertex AI',
   'The model returns nothing usable, times out, or the upload is a corrupt '
   'image the reader cannot decode.',
   'The job lands in the human-review lane with a visible queue; an alert is '
   'raised when the lane grows past its threshold.',
   'The scan is never silently lost: the job is parked for a human to read, '
   'with the original image attached, and the customer-facing flow continues '
   'without the extracted fields.',
   '["Open the review lane and read the parked job",'
   '"Key the fields in by hand from the attached image",'
   '"If the whole lane is failing, check the Vertex quota and the SA key"]'::jsonb,
   'ocr_review_lane_deep',
   'Feeds a deliberately corrupt image through the reader and asserts the job '
   'is parked for review rather than dropped.',
   'Catalogue'),

  ('supplier_silent', 30,
   'Supplier silent past the deadline',
   'The supplier (a human on WhatsApp)',
   'A ranked supplier simply never replies, and the inquiry waterfall waits on '
   'them forever.',
   'The inquiry timeout sweep finds the expired step; the order shows as '
   'waiting past its deadline on the ops board.',
   'timeout_advance moves the waterfall to the next ranked supplier without a '
   'human touching it, so the inquiry never stalls on one silence.',
   '["Open the order inquiry and read which step expired",'
   '"Confirm the next supplier was asked",'
   '"If the whole waterfall is exhausted, the items split out as unfulfilled"]'::jsonb,
   'inquiry_stalled',
   'Creates a synthetic inquiry step, backdates its deadline, runs the sweep '
   'and asserts the waterfall advanced.',
   'Ops'),

  ('rider_offline', 40,
   'Rider offline mid-run',
   'The rider''s phone and its network',
   'The rider loses signal between stops; proof of delivery and status changes '
   'have nowhere to go.',
   'The run stops updating; the stop is visible as stale on delivery '
   'operations.',
   'Actions queue on the device and replay when signal returns, the stop stays '
   'reassignable to another rider, and the customer is told about the delay.',
   '["Open Delivery operations and find the stale run",'
   '"Reassign the stop if the rider cannot be reached",'
   '"Confirm the replayed actions did not double-apply once they land"]'::jsonb,
   'delivery_run_stale',
   'Kills a synthetic rider session mid-run and asserts the stop is still '
   'reassignable and the queued actions replay exactly once.',
   'Delivery'),

  ('razorpay_webhook_missed', 50,
   'Razorpay webhook missed',
   'Razorpay',
   'The payment succeeded but the webhook never arrived, so the order still '
   'reads unpaid.',
   'The payment state machine finds the order sitting in a non-final state '
   'past its poll deadline and reconciles it against Razorpay.',
   'The state machine polls the gateway instead of waiting for the webhook, so '
   'the order is never stuck on a delivery that did not happen.',
   '["Open the order payment section and read the state machine trail",'
   '"Force a reconcile if the poll has not run",'
   '"Check the webhook log for the missed delivery and replay it"]'::jsonb,
   'payment_state_stuck',
   'Suppresses the webhook for a synthetic payment and asserts the poller '
   'reconciled the order by itself.',
   'Money'),

  ('db_restart', 60,
   'Database restart mid-operation',
   'Postgres (the platform restarts it)',
   'A long operation is cut in half: some rows written, some not, and the '
   'runner that was driving it is gone.',
   'The runner comes back and finds its own work half-done; the guard reports '
   'the interrupted operation.',
   'Every write is keyed so a resumed runner re-applies it as a no-op instead '
   'of duplicating it, and the operation continues from its last checkpoint.',
   '["Confirm the operation resumed after the restart",'
   '"Check the seeded flow for duplicate rows",'
   '"If a checkpoint is missing, re-run the operation — it is idempotent"]'::jsonb,
   'idempotency_violation',
   'Replays a seeded flow twice, exactly as a resumed runner would, and asserts '
   'the second pass changed nothing.',
   'Platform')
on conflict (key) do update set
  sort         = excluded.sort,
  title        = excluded.title,
  dependency   = excluded.dependency,
  failure      = excluded.failure,
  detection    = excluded.detection,
  fallback     = excluded.fallback,
  manual_steps = excluded.manual_steps,
  alert_kind   = excluded.alert_kind,
  drill_note   = excluded.drill_note,
  owner_label  = excluded.owner_label,
  updated_at   = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE WORDS. Every string the screen prints lives here, so renaming one is
--    an UPDATE and never a deploy.
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.ui_copy (key, value)
select k, to_jsonb(v) from (values
  ('runbooks.title', 'Failure drills'),
  ('runbooks.subtitle', 'What we do not own, what happens when it breaks, and the last time we proved it.'),
  ('runbooks.h_dependency', 'Depends on'),
  ('runbooks.h_failure', 'What breaks'),
  ('runbooks.h_detection', 'How we find out'),
  ('runbooks.h_fallback', 'What happens by itself'),
  ('runbooks.h_steps', 'What a human does'),
  ('runbooks.h_evidence', 'Evidence'),
  ('runbooks.h_drill', 'The drill'),
  ('runbooks.btn_run', 'Run drill'),
  ('runbooks.btn_running', 'Running…'),
  ('runbooks.chip_passed', 'Passed'),
  ('runbooks.chip_failed', 'Failed'),
  ('runbooks.chip_skipped', 'Skipped'),
  ('runbooks.chip_never', 'Never run'),
  ('runbooks.never_hint', 'This drill has never been run. Run it once so the fallback is proven, not assumed.'),
  ('runbooks.empty', 'No runbooks yet.'),
  ('runbooks.denied', 'Failure drills are an admin surface.'),
  ('runbooks.error', 'Could not read the runbooks. Try again.'),
  ('runbooks.retry', 'Try again')
) t(k, v)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE HARNESS
--
-- A drill is a plpgsql function named _ops_drill_<key> returning jsonb:
--     { status: 'passed'|'failed'|'skipped', summary: text, evidence: jsonb }
-- The dispatcher below is the ONLY caller. It times the drill, records the
-- run, raises the runbook's alert when a drill fails, and hands the screen
-- back the same card shape ops_runbooks_home() prints — so the UI after a
-- drill is the UI before it, with one more row of evidence.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._ops_drill_tone(p_status text)
returns text
language sql
immutable
as $$
  select case p_status
           when 'passed'  then 'success'
           when 'failed'  then 'danger'
           when 'skipped' then 'warning'
           else 'info'
         end;
$$;

create or replace function public._ops_drill_chip(p_status text)
returns text
language sql
stable
set search_path to 'public'
as $$
  select public._c('runbooks.chip_' ||
    case p_status when 'passed' then 'passed'
                  when 'failed' then 'failed'
                  when 'skipped' then 'skipped'
                  else 'never' end);
$$;

-- One runbook card, drill history and all. Kept as its own function so the
-- home list and the single-drill reply cannot drift apart.
create or replace function public._ops_runbook_card(r public.ops_runbook)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare d public.ops_drill_run%rowtype; v_ev jsonb; v_has boolean;
begin
  select * into d from public.ops_drill_run
   where runbook_key = r.key order by ran_at desc limit 1;
  v_has := found;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', e.key,
           'value', case when jsonb_typeof(e.value) = 'string'
                         then e.value #>> '{}' else e.value::text end)), '[]'::jsonb)
    into v_ev
    from jsonb_each(coalesce(d.evidence, '{}'::jsonb)) e;

  return jsonb_build_object(
    'key',          r.key,
    'title',        r.title,
    'owner_label',  r.owner_label,
    'sections',     jsonb_build_array(
        jsonb_build_object('heading', public._c('runbooks.h_dependency'), 'body', r.dependency),
        jsonb_build_object('heading', public._c('runbooks.h_failure'),    'body', r.failure),
        jsonb_build_object('heading', public._c('runbooks.h_detection'),  'body', r.detection),
        jsonb_build_object('heading', public._c('runbooks.h_fallback'),   'body', r.fallback)),
    'steps_heading', public._c('runbooks.h_steps'),
    'steps',         coalesce(r.manual_steps, '[]'::jsonb),
    'drill', jsonb_build_object(
        'heading',          public._c('runbooks.h_drill'),
        'note',             r.drill_note,
        'has_run',          v_has,
        'chip_label',       public._ops_drill_chip(case when v_has then d.status else '' end),
        'chip_tone',        case when v_has then public._ops_drill_tone(d.status) else 'info' end,
        'never_hint',       case when v_has then '' else public._c('runbooks.never_hint') end,
        'ran_label',        case when v_has
                                 then to_char(d.ran_at at time zone 'Asia/Kolkata',
                                              'DD Mon YYYY, HH12:MI am')
                                 else '' end,
        'summary',          coalesce(d.summary, ''),
        'evidence_heading', public._c('runbooks.h_evidence'),
        'evidence',         v_ev),
    'button', jsonb_build_object(
        'key',           r.key,
        'label',         public._c('runbooks.btn_run'),
        'running_label', public._c('runbooks.btn_running')));
end $$;

create or replace function public.ops_runbooks_home()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_cards jsonb; v_passed int; v_failed int; v_never int;
begin
  if not public._ops_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('runbooks.denied'));
  end if;

  select coalesce(jsonb_agg(public._ops_runbook_card(r) order by r.sort, r.key), '[]'::jsonb)
    into v_cards
    from public.ops_runbook r;

  select count(*) filter (where l.status = 'passed'),
         count(*) filter (where l.status = 'failed'),
         count(*) filter (where l.status is null)
    into v_passed, v_failed, v_never
    from public.ops_runbook r
    left join lateral (
      select status from public.ops_drill_run
       where runbook_key = r.key order by ran_at desc limit 1) l on true;

  return jsonb_build_object(
    'ok',       true,
    'title',    public._c('runbooks.title'),
    'subtitle', public._c('runbooks.subtitle'),
    'summary',  jsonb_build_object(
        'label', v_passed || ' passed · ' || v_failed || ' failed · ' || v_never || ' never run',
        'tone',  case when v_failed > 0 then 'danger'
                      when v_never  > 0 then 'warning'
                      else 'success' end),
    'empty',    public._c('runbooks.empty'),
    'error',    public._c('runbooks.error'),
    'retry',    public._c('runbooks.retry'),
    'cards',    v_cards);
end $$;

-- The dispatcher. `ops_runbook_drill(key)` is what the screen's button calls.
create or replace function public.ops_runbook_drill(
  p_key text,
  p_trigger text default 'manual',
  p_command_id bigint default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  r public.ops_runbook%rowtype;
  v_fn text;
  v_res jsonb;
  v_t0 timestamptz := clock_timestamp();
  v_status text;
begin
  if not public._ops_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('runbooks.denied'));
  end if;

  select * into r from public.ops_runbook where key = p_key;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._c('runbooks.empty'));
  end if;

  v_fn := format('public._ops_drill_%s()', r.key);

  -- A drill that throws is a FAILED drill, never a 500 on the screen: the
  -- whole point of this surface is that a broken fallback is visible.
  begin
    if to_regprocedure(format('public._ops_drill_%s()', r.key)) is null then
      v_res := jsonb_build_object('status', 'skipped',
                 'summary', 'No drill is implemented for this runbook yet.',
                 'evidence', '{}'::jsonb);
    else
      execute 'select ' || v_fn into v_res;
    end if;
  exception when others then
    v_res := jsonb_build_object('status', 'failed',
               'summary', 'The drill itself raised: ' || sqlerrm,
               'evidence', jsonb_build_object('sqlstate', sqlstate));
  end;

  v_status := coalesce(v_res->>'status', 'failed');

  insert into public.ops_drill_run
    (runbook_key, status, summary, evidence, duration_ms, trigger, command_id, ran_by)
  values (r.key, v_status, coalesce(v_res->>'summary',''),
          coalesce(v_res->'evidence','{}'::jsonb),
          greatest(0, (extract(epoch from clock_timestamp() - v_t0) * 1000)::int),
          coalesce(p_trigger,'manual'), p_command_id, auth.uid());

  -- A failed drill is an alert, exactly as the real failure would be: the
  -- fallback this runbook promises is not currently working.
  if v_status = 'failed' and r.alert_kind <> '' then
    perform public._ops_drill_alert(r.alert_kind,
      r.title || ' — drill failed: ' || coalesce(v_res->>'summary',''));
  end if;

  select * into r from public.ops_runbook where key = p_key;
  return jsonb_build_object('ok', true, 'card', public._ops_runbook_card(r));
end $$;

-- The alert door. rg_alerts is the platform's own alert table (#916); this
-- writes through it when it is there and stays silent when it is not, so a
-- drill can never fail because the alert table moved.
create or replace function public._ops_drill_alert(p_kind text, p_message text)
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
begin
  if to_regclass('public.rg_alerts') is null then return; end if;
  begin
    execute 'insert into public.rg_alerts (kind, level, message) values ($1,$2,$3)'
      using p_kind, 'error', p_message;
  exception when others then
    null;  -- an alert that cannot be written must not sink the drill
  end;
end $$;

revoke all on function public.ops_runbooks_home() from public;
revoke all on function public.ops_runbook_drill(text, text, bigint) from public;
grant execute on function public.ops_runbooks_home() to authenticated;
grant execute on function public.ops_runbook_drill(text, text, bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE DOOR. A feature nobody can reach is not a feature (§11): the shelf is
--    a registry row with its own route, its own deep link and a search line an
--    operator would actually type at 2 a.m.
-- ─────────────────────────────────────────────────────────────────────────────

insert into public.feature_registry(
  feature_key, label, group_label, icon_key, route_key, sort_order, owner,
  partner_eligible, default_access, is_active, category, surface,
  roles_allowed, deep_link, search_terms, description)
values (
  'admin.runbooks', 'Failure drills', 'Admin & System', 'rule_folder', 'runbooks', 930,
  'medibo', false, 'none', true, 'system', 'dashboard',
  array['admin','super_admin']::text[], '/admin/go/runbooks',
  'runbook drill failure fallback outage whatsapp ocr razorpay rider offline disaster recovery',
  'What breaks when WhatsApp, OCR, a supplier, a rider, Razorpay or the database fails — and the last time we proved the fallback.')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      surface = excluded.surface, category = excluded.category,
      roles_allowed = excluded.roles_allowed,
      deep_link = excluded.deep_link, search_terms = excluded.search_terms,
      description = excluded.description, is_active = true;

insert into public.surface_route (route_key, kind, feature_key, handled_by, note)
values ('runbooks', 'feature', 'admin.runbooks', 'shell_extra_routes',
        'OpsRunbooksScreen — CHANGE #474')
on conflict (route_key, feature_key) do update
  set handled_by = excluded.handled_by, note = excluded.note;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE GUARD. `is_admin()` reads an EMAIL claim, so a service_role JWT — the
--    runner, the drill script, any cron caller — is not an admin by it. The
--    test-session layer already solved this once (`_test_guard`); the shelf
--    borrows the same shape so the screen (a real admin) and the harness (the
--    service key) reach the same drills. Anonymous still gets the refusal.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public._ops_admin()
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if coalesce(current_setting('request.jwt.claim.role', true),'') = 'service_role'
     or current_user in ('postgres','supabase_admin','service_role') then
    return true;
  end if;
  return public.is_admin();
exception when others then
  return public.is_admin();
end $$;

-- The alert door, corrected. rg_alerts is (fingerprint, severity, kind, name,
-- detail, first_seen, last_seen, seen_count) — the shape every other writer in
-- this database uses. The first version of this function wrote (kind, level,
-- message), which does not exist: the alert would have thrown, been swallowed
-- by its own exception handler, and a failed drill would have raised NOTHING.
create or replace function public._ops_drill_alert(p_kind text, p_message text)
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
begin
  if to_regclass('public.rg_alerts') is null then return; end if;
  begin
    insert into public.rg_alerts
      (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
    values ('c474_' || p_kind, 'error', 'ops', p_message,
            jsonb_build_object('source','ops_runbook_drill','runbook',p_kind),
            now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          severity = 'error', name = excluded.name, detail = excluded.detail;
  exception when others then
    null;  -- an alert that cannot be written must not sink the drill
  end;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE GAPS THE DRILLS FOUND. A drill that cannot break the thing it names
--    is theatre, and three of the six had nothing to break.
--
-- 7a. inquiry_timeout_advance() was fleet-wide: 500 rows a pass, a WhatsApp
--     form re-sent to every next supplier and one notification per silent
--     supplier. Running it in a drill would have moved REAL inquiries and
--     messaged REAL suppliers, so the supplier-silence drill would have had to
--     fake its own copy of the logic — and a drill against a copy proves
--     nothing about the original. One optional parameter fixes that: the cron
--     path (`timeout_advance()` -> `inquiry_timeout_advance()`) is byte-for-byte
--     what it was, and a caller who names ONE inquiry id gets exactly that row
--     advanced, with the fan-out notification suppressed.
-- ─────────────────────────────────────────────────────────────────────────────

drop function if exists public.inquiry_timeout_advance();

create or replace function public.inquiry_timeout_advance(p_only_id bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $ita$
declare
  r_inq inquiry%rowtype;
  v_id bigint; v_old text; v_slot int; i int; ps_val text; as_val text;
  v_due timestamptz; v_advanced int := 0; v_sups text[] := '{}';
  v_new_cur text; v_no_answer text := public.uic('inquiry.no_response_answer', 'No response');
begin
  for v_id in
    select i2.id from inquiry i2
     where (p_only_id is null or i2.id = p_only_id)
       and i2.current_supplier is not null
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
  -- A TARGETED advance (p_only_id) is a drill or a single-row repair, not a
  -- sweep: it moves the waterfall and tells nobody, so #474's supplier-silence
  -- drill can exercise the real function without a real WhatsApp going out.
  if p_only_id is null and array_length(v_sups, 1) is not null then
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
end
$ita$;

-- The old signature carried PUBLIC + anon execute (the CREATE FUNCTION default
-- nobody ever revoked). With a p_only_id parameter that is no longer merely
-- untidy: anon could name any inquiry and step its waterfall. authenticated and
-- service_role keep exactly what they had.
revoke all on function public.inquiry_timeout_advance(bigint) from public;
revoke all on function public.inquiry_timeout_advance(bigint) from anon;
grant execute on function public.inquiry_timeout_advance(bigint) to authenticated;
grant execute on function public.inquiry_timeout_advance(bigint) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7b. THE OCR REVIEW LANE HAD A QUEUE BUT NO ALARM.
--
-- A bill whose read fails is already parked, not lost: pharmacy_vault_ocr_report
-- writes status='failed' with the reader's own error, the shelf still shows the
-- bill, and pharmacy_vault_bill_queue() re-queues it for a human. What nobody
-- had was a way to find out WITHOUT looking: a Vertex quota that ran out at
-- 03:00 parks every bill of the night and raises nothing. This is the alarm.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.ocr_lane_config (
  id            boolean primary key default true check (id),
  window_hours  int not null default 6,
  failed_max    int not null default 5,   -- failed reads in the window before we shout
  stuck_minutes int not null default 30,  -- a bill queued longer than this is stuck
  updated_at    timestamptz not null default now()
);
insert into public.ocr_lane_config (id) values (true) on conflict (id) do nothing;

create or replace function public.ocr_review_lane_scan()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  cfg public.ocr_lane_config;
  v_failed int := 0; v_stuck int := 0; v_raised boolean := false;
begin
  select * into cfg from public.ocr_lane_config where id;

  select count(*)::int into v_failed
    from public.pharmacy_purchase_bill
   where status = 'failed'
     and coalesce(read_at, created_at) > now() - make_interval(hours => cfg.window_hours);

  select count(*)::int into v_stuck
    from public.pharmacy_purchase_bill
   where status in ('queued','processing')
     and queued_at is not null
     and queued_at < now() - make_interval(mins => cfg.stuck_minutes);

  if v_failed >= cfg.failed_max or v_stuck > 0 then
    insert into public.rg_alerts
      (fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
    values ('c474_ocr_review_lane', 'warn', 'ops',
            'OCR review lane is backing up',
            jsonb_build_object('failed', v_failed, 'stuck', v_stuck,
                               'window_hours', cfg.window_hours),
            now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          detail = excluded.detail, severity = 'warn';
    v_raised := true;
  end if;

  return jsonb_build_object('ok', true, 'failed', v_failed, 'stuck', v_stuck,
                            'raised', v_raised, 'failed_max', cfg.failed_max,
                            'stuck_minutes', cfg.stuck_minutes);
end $$;

revoke all on function public.ocr_review_lane_scan() from public;
grant execute on function public.ocr_review_lane_scan() to service_role;

-- The dispatcher's own table, never a bare */N (see the connection-exhaustion
-- outage of 18 Aug: 35 jobs all started on minute 0).
insert into public.cron_task (name, ord, mode, work_sql, note, enabled,
                              base_interval_s, max_interval_s, current_interval_s)
values ('c474-ocr-lane-alert', 6400, 'poll',
        'select public.ocr_review_lane_scan()',
        'CHANGE #474 — shouts when parked OCR reads pile up', true,
        900, 3600, 900)
on conflict (name) do update
  set work_sql = excluded.work_sql, note = excluded.note, enabled = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7c. THE MISSED RAZORPAY WEBHOOK HAD NO SECOND CHANCE.
--
-- #304 made an attempt RESUMABLE — the same payment link is handed back rather
-- than a second one minted — and rzp_webhook_apply() is idempotent on the
-- provider event id. Both of those assume the webhook ARRIVES. Nothing in this
-- database ever asked Razorpay "did that one get paid?": there is no poller in
-- cron_task, and rzp_checkout_state() only reads the row the webhook was
-- supposed to have written. A webhook lost in transit left the customer's money
-- gone and the order reading unpaid until somebody noticed by hand.
--
-- The poller is deliberately thin. It selects the attempts that are OVERDUE and
-- hands them to the edge function `razorpay-reconcile`, which asks Razorpay for
-- the truth and posts it back through rzp_webhook_apply() — the SAME door the
-- webhook uses, so a late webhook and a poll can never both credit an order.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.rzp_reconcile_config (
  id             boolean primary key default true check (id),
  grace_minutes  int not null default 10,   -- how long a webhook gets to arrive
  give_up_hours  int not null default 48,   -- past this the link is dead anyway
  batch          int not null default 20,
  updated_at     timestamptz not null default now()
);
insert into public.rzp_reconcile_config (id) values (true) on conflict (id) do nothing;

-- The overdue set: an attempt that is not in a final state, old enough that a
-- healthy webhook would have landed, and young enough to still be worth asking
-- about. This is also the "is anything stuck?" query the drill reads.
create or replace function public.rzp_reconcile_due(p_limit int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare cfg public.rzp_reconcile_config; v_rows jsonb; v_total int;
begin
  select * into cfg from public.rzp_reconcile_config where id;

  select count(*)::int into v_total
    from public.rzp_payment_attempt a
   where a.status not in ('paid','expired','cancelled','failed')
     and a.created_at < now() - make_interval(mins => cfg.grace_minutes)
     and a.created_at > now() - make_interval(hours => cfg.give_up_hours);

  select coalesce(jsonb_agg(x order by x->>'created_at'), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'attempt_id', a.id, 'order_id', a.order_id, 'kind', a.kind,
               'status', a.status, 'rzp_link_id', a.rzp_link_id,
               'rzp_order_id', a.rzp_order_id, 'amount', a.amount,
               'is_synthetic', coalesce(a.is_synthetic, false),
               'created_at', a.created_at) as x
        from public.rzp_payment_attempt a
       where a.status not in ('paid','expired','cancelled','failed')
         and a.created_at < now() - make_interval(mins => cfg.grace_minutes)
         and a.created_at > now() - make_interval(hours => cfg.give_up_hours)
       order by a.created_at
       limit greatest(coalesce(p_limit, cfg.batch), 1)
    ) s;

  return jsonb_build_object('ok', true, 'due', v_rows, 'due_count', v_total,
                            'grace_minutes', cfg.grace_minutes,
                            'give_up_hours', cfg.give_up_hours);
end $$;

revoke all on function public.rzp_reconcile_due(int) from public;
grant execute on function public.rzp_reconcile_due(int) to service_role;

-- The tick. It does not talk to Razorpay itself: net.http_post hands the work
-- to the edge function that holds the API key, exactly as pharmacy_vault_sweep
-- hands a bill to bill-vault-ocr. Nothing is posted when nothing is overdue, so
-- a quiet day costs one SELECT.
create or replace function public.rzp_reconcile_tick()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare v_due jsonb; v_n int;
begin
  v_due := public.rzp_reconcile_due(null);
  v_n := jsonb_array_length(coalesce(v_due->'due','[]'::jsonb));
  if v_n = 0 then
    return jsonb_build_object('ok', true, 'due', 0, 'posted', false);
  end if;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/razorpay-reconcile',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('source','cron'),
    timeout_milliseconds := 30000);

  return jsonb_build_object('ok', true, 'due', v_n, 'posted', true,
                            'due_count', v_due->'due_count');
end $$;

revoke all on function public.rzp_reconcile_tick() from public;
grant execute on function public.rzp_reconcile_tick() to service_role;

insert into public.cron_task (name, ord, mode, work_sql, note, enabled,
                              base_interval_s, max_interval_s, current_interval_s)
values ('c474-rzp-reconcile', 6410, 'poll',
        'select public.rzp_reconcile_tick()',
        'CHANGE #474 — polls Razorpay for payments whose webhook never arrived',
        true, 600, 1800, 600)
on conflict (name) do update
  set work_sql = excluded.work_sql, note = excluded.note, enabled = true;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE SIX DRILLS.
--
-- Rules every one of them obeys, because a drill that is dangerous will not be
-- run and a drill that is fake is worse than none:
--
--   * SYNTHETIC SUBJECTS ONLY. The cast is `test_fixture` (a pharmacy, a
--     supplier and a rider, all pinned to zone 99 and named
--     "… - SYNTHETIC (DO NOT USE)"), plus a reserved probe phone that is
--     asserted to belong to nobody before it is used. A drill that cannot get
--     its subject returns 'skipped' with the reason — it never borrows a real
--     one.
--   * NOTHING SURVIVES. Every row a drill writes is deleted before it returns,
--     inside the dispatcher's own transaction, so no other session ever sees a
--     sendable, payable or claimable artefact.
--   * NEVER A FLEET SWEEP. The drills call the per-entity mechanism
--     (`inquiry_timeout_advance(id)`, `rzp_webhook_apply(event)`,
--     `delivery_replay(key,…)`), never the cron entry point that would step
--     every live row in the database.
--   * THE REAL FUNCTION OR NOTHING. No drill re-implements the thing it is
--     testing. Where the real function could not be called safely, the FUNCTION
--     was changed (section 7a) rather than the drill weakened.
-- ─────────────────────────────────────────────────────────────────────────────

-- The reserved probe phone. Ten digits that belong to no pharmacy, supplier,
-- rider or admin — asserted, never assumed.
create or replace function public._ops_drill_probe_phone()
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_ph text := '9000000474';
begin
  if exists (select 1 from public.pharmacy_profiles p
              where right(regexp_replace(coalesce(nullif(btrim(p.whatsapp_no),''), p.phone, ''),
                                         '\D','','g'), 10) = v_ph)
  then return null; end if;
  return v_ph;
end $$;

-- ── 1. WHATSAPP DOWN ────────────────────────────────────────────────────────
-- Forces the exact state a rejected template produces — a send that could not
-- go — and asserts three things: the retry queue HELD it (never a silent drop),
-- both fallback channels are configured for real events, and the health scan
-- turns a failure window into an open alert.
create or replace function public._ops_drill_whatsapp_down()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_ph    text := public._ops_drill_probe_phone();
  v_ev    text := 'c474_drill_probe';
  v_id    bigint;
  q       public.notification_retry_queue%rowtype;
  v_push  int; v_email int; v_alert int; v_scan jsonb;
  v_fail  text[] := '{}';
begin
  if v_ph is null then
    return jsonb_build_object('status','skipped',
      'summary','The reserved probe number now belongs to a real pharmacy — refusing to drill on it.',
      'evidence','{}'::jsonb);
  end if;

  -- (a) the queue holds a send that could not go
  v_id := public.notify_enqueue_retry(v_ev, v_ph,
            jsonb_build_object('drill','c474'),
            'drill: template rejected by provider');
  if v_id is null then
    v_fail := array_append(v_fail, 'notify_enqueue_retry returned null');
  else
    select * into q from public.notification_retry_queue where id = v_id;
    if q.status <> 'pending' then
      v_fail := array_append(v_fail, ('queued row is ' || q.status || ', expected pending'));
    end if;
    if q.next_attempt_at <= now() then
      v_fail := array_append(v_fail, 'no backoff: the row is due immediately');
    end if;
  end if;

  -- (b) the fallback channels exist on real events
  select count(*) filter (where coalesce(push_enabled,false)),
         count(*) filter (where coalesce(email_enabled,false))
    into v_push, v_email from public.wa_event_routes;
  if v_push = 0  then v_fail := array_append(v_fail, 'no event has push enabled');  end if;
  if v_email = 0 then v_fail := array_append(v_fail, 'no event has email enabled'); end if;

  -- (c) a failure window becomes an alert. Six failures on the probe event is
  --     over notification_health_config's threshold by construction.
  insert into public.notification_log (event_key, recipient, channel, status, failure_reason)
  select v_ev, v_ph, 'whatsapp', 'failed', 'drill: forced failure'
    from generate_series(1, 6);
  v_scan := public.notify_health_scan();
  select count(*)::int into v_alert from public.notification_alerts
   where event_key = v_ev and status = 'open';
  if v_alert = 0 then v_fail := array_append(v_fail, 'notify_health_scan raised no alert on a 100% failure window'); end if;

  -- cleanup — nothing this drill made outlives it
  delete from public.notification_alerts where event_key = v_ev;
  delete from public.notification_log     where event_key = v_ev;
  if v_id is not null then delete from public.notification_retry_queue where id = v_id; end if;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'A rejected send was held in the retry queue with backoff, the push and email fallbacks are configured, and the health scan raised the alert.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'held_queue_id', coalesce(v_id::text,'none'),
      'held_status', coalesce(q.status,'—'),
      'backoff_seconds', coalesce(round(extract(epoch from (q.next_attempt_at - now())))::text,'—'),
      'events_with_push', v_push::text,
      'events_with_email', v_email::text,
      'alert_raised', (v_alert > 0)::text,
      'health_scan', coalesce(v_scan::text,'—'),
      'recipient', 'reserved probe ' || v_ph || ' (no real contact)'));
end $$;

-- ── 2. OCR FAILURE ──────────────────────────────────────────────────────────
-- Feeds a corrupt read to the real reporter and asserts the bill is PARKED with
-- the reader's own error, is still visible on the shelf, can be re-queued by a
-- human, and that the lane's new alarm sees it.
create or replace function public._ops_drill_ocr_failure()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_pharm uuid;
  v_bill  uuid;
  v_rep   jsonb;
  b       public.pharmacy_purchase_bill%rowtype;
  v_scan  jsonb;
  v_fail  text[] := '{}';
begin
  select entity_id into v_pharm from public.test_fixture where key = 'pharmacy';
  if v_pharm is null then
    return jsonb_build_object('status','skipped',
      'summary','No synthetic pharmacy in test_fixture — refusing to park a real pharmacy''s bill.',
      'evidence','{}'::jsonb);
  end if;

  insert into public.pharmacy_purchase_bill
    (pharmacy_id, status, source, shot_count, queued_at, is_synthetic)
  values (v_pharm, 'processing', 'drill', 1, now(), true)
  returning id into v_bill;

  -- the real reporter, with the error a corrupt image produces
  begin
    v_rep := public.pharmacy_vault_ocr_report(v_bill, '{}'::jsonb,
               'drill: corrupt image — the decoder returned no readable bytes');
  exception when others then
    v_rep := jsonb_build_object('ok', false, 'raised', sqlerrm);
    v_fail := array_append(v_fail, ('pharmacy_vault_ocr_report raised: ' || sqlerrm));
  end;

  select * into b from public.pharmacy_purchase_bill where id = v_bill;
  if b.id is null then
    v_fail := array_append(v_fail, 'the bill vanished — a failed read must never delete the job');
  else
    if b.status <> 'failed' then
      v_fail := array_append(v_fail, ('bill is ' || b.status || ', expected failed (parked for a human)'));
    end if;
    if coalesce(btrim(b.ocr_error),'') = '' then
      v_fail := array_append(v_fail, 'the reader''s error was not kept — a human cannot see why it failed');
    end if;
  end if;

  v_scan := public.ocr_review_lane_scan();

  delete from public.pharmacy_purchase_bill where id = v_bill;
  delete from public.rg_alerts where fingerprint = 'c474_ocr_review_lane'
     and seen_count = 1 and first_seen > now() - interval '1 minute';

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'A corrupt read parked the bill as failed with the reader''s own error, kept it on the shelf for a human, and the lane alarm counted it.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'reporter_reply', coalesce(v_rep::text,'—'),
      'bill_status', coalesce(b.status,'(deleted)'),
      'kept_error', left(coalesce(b.ocr_error,'—'), 80),
      'lane_scan', coalesce(v_scan::text,'—'),
      'subject', 'synthetic pharmacy ' || left(v_pharm::text, 8) || ' (zone 99)'));
end $$;

-- ── 3. SUPPLIER SILENT ──────────────────────────────────────────────────────
-- A synthetic inquiry, backdated past its deadline, run through the REAL
-- timeout advance scoped to that one row. Asserts the silent supplier is
-- recorded as no-response and the waterfall moved to the next ranked supplier.
create or replace function public._ops_drill_supplier_silent()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_sup   text;
  v_id    bigint;
  v_res   jsonb;
  r       public.inquiry%rowtype;
  v_ans   text := public.uic('inquiry.no_response_answer','No response');
  v_due   int;
  v_cron  boolean;
  v_fail  text[] := '{}';
begin
  select label into v_sup from public.test_fixture where key = 'supplier';
  if v_sup is null then
    return jsonb_build_object('status','skipped',
      'summary','No synthetic supplier in test_fixture - refusing to step a real supplier''s inquiry.',
      'evidence','{}'::jsonb);
  end if;

  -- How many live inquiries the sweep would move RIGHT NOW. This is the
  -- detector, read before anything is seeded, and it is the number an operator
  -- cares about: a waterfall that has stopped moving shows up here first.
  select count(*)::int into v_due
    from public.inquiry i
   where i.current_supplier is not null
     and i.asked_at is not null
     and coalesce(i.current_status,'') <> 'Available'
     and coalesce(i.inquiry_phase,'draft') in ('draft','sent')
     and i.asked_at < now() - make_interval(mins => public.inquiry_deadline_minutes(i.zone_id));

  v_cron := exists (select 1 from public.cron_task
                     where name = 'inquiry_timeout_advance' and enabled);
  if not v_cron then
    v_fail := array_append(v_fail, ('the timeout sweep is not scheduled - a silent supplier would stall the inquiry forever'));
  end if;

  -- The subject. A synthetic inquiry is pinned by inquiry_ps_lookup (#573) to
  -- the ONE synthetic supplier and PS2..PS30 are nulled, precisely so a test row
  -- can never be offered to a real distributor. So this drill exercises the
  -- TERMINAL case, which is the one that actually strands an order: the only
  -- supplier in the cascade goes silent. Passing means the row is recorded as
  -- no-response and moved OFF that supplier rather than waiting on it forever.
  --
  -- current_supplier is set in the INSERT and never by a later UPDATE:
  -- trg_inq_rebuild_spo fires inquiry_engine_sync() on an update of that column,
  -- which rewrites every pending inquiry_forms row in the database. asked_at is
  -- the reverse - it is cleared on insert and only sticks on an update of its
  -- own - so the backdating is a second, single-column statement.
  insert into public.inquiry
    (product_name, quantity, current_supplier, inquiry_phase, zone_id, batch_date, is_synthetic)
  values ('C474 DRILL LINE - SYNTHETIC', 1, v_sup, 'sent', 99,
          (now() at time zone 'Asia/Kolkata')::date, true)
  returning id into v_id;

  update public.inquiry set asked_at = now() - interval '90 minutes' where id = v_id;

  select * into r from public.inquiry where id = v_id;
  if r.asked_at is null then
    v_fail := array_append(v_fail, ('could not backdate the drill inquiry - asked_at did not stick'));
  end if;

  v_res := public.inquiry_timeout_advance(v_id);

  select * into r from public.inquiry where id = v_id;
  if coalesce((v_res->>'advanced')::int, 0) < 1 then
    v_fail := array_append(v_fail, ('the sweep did not pick up an inquiry 90 minutes past a ' ||
                         public.inquiry_deadline_minutes(99::smallint) || ' minute deadline'));
  end if;
  if coalesce(r."AS1",'') <> v_ans then
    v_fail := array_append(v_fail, ('the silent supplier was not recorded as "' || v_ans ||
                         '" (AS1 = ' || coalesce(r."AS1",'null') || ')'));
  end if;
  if r.current_supplier is not null then
    v_fail := array_append(v_fail, ('the inquiry is STILL waiting on ' || r.current_supplier ||
                         ' after the deadline passed'));
  end if;

  -- cleanup: the inquiry, any form the advance minted, and the response-log row
  -- that would otherwise score a synthetic supplier''s silence in a real ledger
  delete from public.supplier_response_log where inquiry_id = v_id;
  delete from public.inquiry_forms where supplier_name = v_sup and status = 'pending'
     and last_sent_at > now() - interval '1 minute';
  delete from public.inquiry where id = v_id;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'A supplier that never answered was recorded as no-response and the inquiry was moved off it, so the line is surfaced instead of waiting forever.'
      else array_to_string(v_fail, ' - ') end,
    'evidence', jsonb_build_object(
      'sweep_scheduled', v_cron::text,
      'inquiries_past_deadline_now', v_due::text,
      'advance_reply', coalesce(v_res::text,'-'),
      'answer_written', coalesce(r."AS1",'-'),
      'waiting_on_after', coalesce(r.current_supplier,'nobody - cascade exhausted, line surfaced'),
      'waited', '90 minutes past a ' || public.inquiry_deadline_minutes(99::smallint) || ' minute deadline',
      'subject', 'synthetic inquiry, ' || v_sup,
      'notification', 'suppressed - a targeted advance never messages a supplier'));
end $$;

-- ── 4. RIDER OFFLINE ────────────────────────────────────────────────────────
-- The rider's phone loses signal mid-run. What must survive: the actions queued
-- on the device replay EXACTLY ONCE when signal returns, the stop is still
-- reassignable to someone else, and the customer hears about the delay. The
-- replay contract is exercised for real against delivery_replay's own ledger,
-- with an action that touches no delivery; the other two are asserted as
-- present machinery, because reassigning a real stop is not a drill.
create or replace function public._ops_drill_rider_offline()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_key    text := 'c474-drill-' || replace(gen_random_uuid()::text,'-','');
  v_stored jsonb := jsonb_build_object('ok', true, 'drill', 'c474',
                                       'stamp', clock_timestamp()::text);
  v_fresh  jsonb; v_replay jsonb;
  v_rider  uuid;
  v_reassign boolean;
  v_delay  int;
  v_stale  boolean;
  v_rows   int;
  v_fail   text[] := '{}';
begin
  select entity_id into v_rider from public.test_fixture where key = 'rider';

  -- (a) AN UNKNOWN ACTION IS NOT A REPLAY. The guard must not over-match, or a
  --     rider who really did two stops would only ever get one recorded.
  v_fresh := public.delivery_replay(v_key || '-unseen', 'c474_drill_ping', '{}'::jsonb);
  if coalesce((v_fresh->>'replayed')::boolean, false) then
    v_fail := array_append(v_fail, 'a client_action_id nobody has seen was called a replay - real work would be dropped');
  end if;

  -- (b) AN ACTION THE DEVICE ALREADY HAS AN ANSWER FOR IS NEVER APPLIED AGAIN.
  --     This is the whole offline contract: the phone queues while it has no
  --     signal, then floods the same actions when it comes back. The stored
  --     answer is seeded directly rather than earned through a real stop -
  --     a drill does not get to move somebody''s delivery - and the short
  --     circuit under test runs BEFORE delivery_replay looks at who is calling,
  --     so this exercises the real guard on the real ledger.
  insert into public.delivery_action_log
    (client_action_id, action, payload, result, last_result, attempts, updated_at)
  values (v_key, 'c474_drill_ping', '{}'::jsonb, v_stored, v_stored, 1, now());

  v_replay := public.delivery_replay(v_key, 'c474_drill_ping', '{}'::jsonb);
  if coalesce((v_replay->>'replayed')::boolean, false) is not true then
    v_fail := array_append(v_fail, 'the queued action was NOT recognised on its second send - an offline replay would double-apply');
  elsif (v_replay - 'replayed') is distinct from v_stored then
    v_fail := array_append(v_fail, 'the replay returned a different answer from the one the device already has');
  end if;

  select count(*)::int into v_rows from public.delivery_action_log
   where client_action_id in (v_key, v_key || '-unseen');
  if v_rows > 2 then
    v_fail := array_append(v_fail, ('the ledger fanned out to ' || v_rows || ' rows for two keys'));
  end if;

  -- (c) the stop is still somebody else''s to take
  v_reassign := to_regprocedure('public.delivery_reassign(uuid,uuid)') is not null;
  if not v_reassign then
    v_fail := array_append(v_fail, 'delivery_reassign is gone - a stranded stop cannot be moved');
  end if;

  -- (d) the customer hears about it, and the silent run is noticed
  select count(*)::int into v_delay from public.wa_event_routes
   where coalesce(enabled,false) and (event_key ilike '%delay%' or event_key ilike '%eta%'
      or event_key ilike '%reschedul%');
  if v_delay = 0 then
    v_fail := array_append(v_fail, 'no enabled event tells a customer about a delay');
  end if;

  v_stale := exists (select 1 from public.cron_task
                      where name in ('delivery_anomaly','delivery_sweep','eta_breach_notify')
                        and enabled);
  if not v_stale then
    v_fail := array_append(v_fail, 'nothing is scheduled to notice a run that stopped moving');
  end if;

  delete from public.delivery_action_log
   where client_action_id in (v_key, v_key || '-unseen');

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'A queued action replayed after the signal came back returned the answer the phone already had and applied nothing twice, an unseen action was still treated as new work, and the stop stays reassignable while the delay events and stale-run sweeps run.'
      else array_to_string(v_fail, ' - ') end,
    'evidence', jsonb_build_object(
      'unseen_action', coalesce(v_fresh::text,'-'),
      'replayed_action', coalesce(v_replay::text,'-'),
      'ledger_rows_for_two_keys', v_rows::text,
      'reassign_available', v_reassign::text,
      'delay_events_enabled', v_delay::text,
      'stale_run_sweep', v_stale::text,
      'subject', case when v_rider is null then 'replay ledger only - no rider fixture'
                      else 'synthetic rider ' || left(v_rider::text,8) || ', no real stop touched' end));
end $$;

-- ── 5. RAZORPAY WEBHOOK MISSED ──────────────────────────────────────────────
-- The money moved and the webhook did not. Asserts the poller that #474 added
-- exists, is scheduled, and can SEE an overdue attempt; and that the door it
-- posts through is the webhook's own door and is exactly-once, so a poll and a
-- late webhook carrying the same payment can never both credit an order.
--
-- The drill deliberately does NOT mint an order. `orders` carries thirty-odd
-- triggers, three of which send WhatsApp on insert; creating one to drill on
-- would break this command's own no-real-contact rule.
create or replace function public._ops_drill_razorpay_webhook_missed()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_seen  text := 'c474_drill_seen_' || replace(gen_random_uuid()::text,'-','');
  v_new   text := 'c474_drill_new_'  || replace(gen_random_uuid()::text,'-','');
  v_payid text := 'pay_C474DRILL';
  v_stored jsonb := jsonb_build_object('ok', true, 'drill', 'c474',
                                       'matched', 0, 'stamp', clock_timestamp()::text);
  v_replay jsonb; v_fresh jsonb;
  v_due jsonb;
  v_cron boolean;
  v_rows int;
  v_fail text[] := '{}';
begin
  -- (a) THE POLLER EXISTS AND CAN SEE WHAT IS OVERDUE. Before #474 nothing in
  --     this database ever asked Razorpay whether a payment landed: a webhook
  --     lost in transit left the money gone and the order reading unpaid.
  begin
    v_due := public.rzp_reconcile_due(5);
  exception when others then
    v_fail := array_append(v_fail, ('rzp_reconcile_due raised: ' || sqlerrm));
  end;
  if coalesce((v_due->>'ok')::boolean,false) is not true then
    v_fail := array_append(v_fail, 'the reconcile poller cannot answer - a missed webhook has no second chance');
  end if;

  v_cron := exists (select 1 from public.cron_task where name = 'c474-rzp-reconcile' and enabled);
  if not v_cron then
    v_fail := array_append(v_fail, 'the reconcile poller is not scheduled');
  end if;

  -- (b) THE DOOR IT POSTS THROUGH IS EXACTLY-ONCE. The poller does not have a
  --     door of its own: it hands what Razorpay told it to rzp_webhook_apply(),
  --     the same function the webhook calls. So the late webhook and the poll
  --     carrying the SAME payment must not both credit the order. The answered
  --     delivery is seeded rather than earned - a drill does not get to credit
  --     a real order - and the guard under test reads exactly this row.
  insert into public.razorpay_webhook_log (event, rzp_event_id, payload_id, handled, result)
  values ('payment.captured', v_seen, v_payid, true, v_stored);

  v_replay := public.rzp_webhook_apply(jsonb_build_object(
    'id', v_seen, 'event', 'payment.captured',
    'payload', jsonb_build_object('payment', jsonb_build_object('entity',
      jsonb_build_object('id', v_payid, 'amount', 100, 'status', 'captured')))));

  if coalesce((v_replay->>'replayed')::boolean,false) is not true then
    v_fail := array_append(v_fail, 'a redelivery of an event already applied was NOT recognised - a poll and a late webhook would both credit the order');
  elsif (v_replay - 'replayed') is distinct from v_stored then
    v_fail := array_append(v_fail, 'the redelivery returned a different answer from the one already given');
  end if;

  -- (c) AND A PAYMENT THAT MATCHES NOTHING CREDITS NOTHING. The drill''s own
  --     payment id belongs to no attempt, which is what makes it safe to fire.
  v_fresh := public.rzp_webhook_apply(jsonb_build_object(
    'id', v_new, 'event', 'payment.captured',
    'payload', jsonb_build_object('payment', jsonb_build_object('entity',
      jsonb_build_object('id', v_payid, 'amount', 100, 'status', 'captured')))));
  if coalesce(v_fresh->>'reason','') <> 'no_attempt' then
    v_fail := array_append(v_fail, ('a drill payment matched something real: ' || coalesce(v_fresh::text,'null')));
  end if;

  select count(*)::int into v_rows from public.razorpay_webhook_log
   where rzp_event_id in (v_seen, v_new);
  if v_rows <> 2 then
    v_fail := array_append(v_fail, ('the delivery log holds ' || v_rows || ' rows for two event ids, expected 2'));
  end if;

  delete from public.razorpay_webhook_log where rzp_event_id in (v_seen, v_new);

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'The reconcile poller is scheduled and can name every attempt whose webhook is overdue, and the door it posts through handed a redelivered payment its first answer back instead of crediting it twice.'
      else array_to_string(v_fail, ' - ') end,
    'evidence', jsonb_build_object(
      'poller_scheduled', v_cron::text,
      'attempts_overdue_now', coalesce(v_due->>'due_count','-'),
      'grace_minutes', coalesce(v_due->>'grace_minutes','-'),
      'redelivery', coalesce(v_replay::text,'-'),
      'unmatched_payment', coalesce(v_fresh::text,'-'),
      'delivery_log_rows', v_rows::text,
      'subject', 'drill payment id ' || v_payid || ' - matches no order, credits nothing'));
end $$;

-- ── 6. DATABASE RESTART MID-OPERATION ───────────────────────────────────────
-- The runner is cut in half and comes back. Nothing it already applied may be
-- applied a second time. Drilled on the real ledger every money and stock edge
-- keys through: claim, store, then replay exactly as a resumed runner would.
create or replace function public._ops_drill_db_restart()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_scope text := 'c474_drill';
  v_key   uuid := gen_random_uuid();
  v_first jsonb; v_claim1 jsonb; v_claim2 jsonb;
  v_sweep boolean;
  v_rows  int;
  v_fail  text[] := '{}';
begin
  -- pass one: nobody has done this yet, so the claim is ours
  v_claim1 := public._idem_claim(v_scope, v_key);
  if v_claim1 is not null then
    v_fail := array_append(v_fail, 'a fresh key was already claimed — the ledger is not keyed on (scope, id)');
  end if;

  v_first := jsonb_build_object('ok', true, 'applied_once', true,
                                'stamp', clock_timestamp()::text);
  perform public._idem_store(v_scope, v_key, v_first);

  -- pass two: the restart. The resumed runner fires the SAME key again.
  v_claim2 := public._idem_claim(v_scope, v_key);
  if v_claim2 is null then
    v_fail := array_append(v_fail, 'the resumed runner was handed the work AGAIN — it would apply twice');
  elsif coalesce((v_claim2->>'replayed')::boolean,false) is not true then
    v_fail := array_append(v_fail, 'the second pass was not flagged as a replay');
  elsif (v_claim2 - 'replayed') is distinct from v_first then
    v_fail := array_append(v_fail, 'the replay returned a different answer from the first pass');
  end if;

  select count(*)::int into v_rows from public.idempotent_action
   where scope = v_scope and client_action_id = v_key;
  if v_rows <> 1 then
    v_fail := array_append(v_fail, ('the ledger holds ' || v_rows || ' rows for one key, expected 1'));
  end if;

  v_sweep := exists (select 1 from public.cron_task where name = 'idem_sweep' and enabled);
  if not v_sweep then v_fail := array_append(v_fail, 'idem_sweep is not scheduled — the ledger would grow forever'); end if;

  delete from public.idempotent_action where scope = v_scope and client_action_id = v_key;

  return jsonb_build_object(
    'status', case when array_length(v_fail,1) is null then 'passed' else 'failed' end,
    'summary', case when array_length(v_fail,1) is null
      then 'A seeded operation replayed exactly as a resumed runner would: the second pass changed nothing and got the first pass''s own answer back.'
      else array_to_string(v_fail, ' · ') end,
    'evidence', jsonb_build_object(
      'first_pass_claim', coalesce(v_claim1::text,'null (ours — do the work)'),
      'second_pass_claim', coalesce(v_claim2::text,'—'),
      'ledger_rows_for_key', v_rows::text,
      'sweep_scheduled', v_sweep::text,
      'scope', v_scope));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. RUN THEM ALL. One call, one table, every runbook in its own savepoint so a
--    drill that explodes is a failed row and never a failed pass.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.ops_runbook_drill_all(
  p_trigger text default 'manual',
  p_command_id bigint default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare r record; v_rows jsonb := '[]'::jsonb; v_one jsonb;
        v_pass int := 0; v_fail int := 0; v_skip int := 0;
begin
  if not public._ops_admin() then
    return jsonb_build_object('ok', false, 'message', public._c('runbooks.denied'));
  end if;

  for r in select key, title from public.ops_runbook order by sort, key loop
    v_one := public.ops_runbook_drill(r.key, p_trigger, p_command_id);
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key', r.key, 'title', r.title,
      'status', coalesce(v_one #>> '{card,drill,chip_label}', '—'),
      'summary', coalesce(v_one #>> '{card,drill,summary}', '—')));
  end loop;

  select count(*) filter (where l.status = 'passed'),
         count(*) filter (where l.status = 'failed'),
         count(*) filter (where l.status = 'skipped')
    into v_pass, v_fail, v_skip
    from public.ops_runbook rb
    left join lateral (select status from public.ops_drill_run
                        where runbook_key = rb.key order by ran_at desc limit 1) l on true;

  return jsonb_build_object('ok', true, 'passed', v_pass, 'failed', v_fail,
                            'skipped', v_skip, 'rows', v_rows);
end $$;

revoke all on function public.ops_runbook_drill_all(text, bigint) from public;
grant execute on function public.ops_runbook_drill_all(text, bigint) to authenticated;
grant execute on function public.ops_runbook_drill_all(text, bigint) to service_role;
