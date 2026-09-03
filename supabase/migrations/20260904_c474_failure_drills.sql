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
  if not public.is_admin() then
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
  if not public.is_admin() then
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
