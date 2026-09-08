-- replay-target: production
-- (wa_event_routes is a production table; the control plane has no send path.)
-- CHANGE #637 — the two admin journeys this command was blocked behind stop
-- waiting on a hand-inserted production row.
--
-- CHANGE #1803 moved every app journey onto the build branch, and a build
-- branch is `pg_dump --schema-only` of live: the SCHEMA arrives, the seeded
-- CONFIG does not. So `_journey_c450_live_event_keys` (qa-450-250) and
-- `_journey_c450_admin_actions` (qa-450-251) report
--
--   admin_claim_ask_utr        -> payment_utr_request
--   admin_customer_churn_nudge -> reorder_due
--   admin_receivables_chase    -> payment_due
--
-- as "in no row of wa_event_routes" — not because an admin action names a dead
-- event, but because nobody has cast the play on that database yet.
--
-- Two of those three keys ARE seeded by a migration already
-- (20260901_c450_qa_round1.sql for payment_utr_request, 20260816090000_
-- reorder_suite.sql for reorder_due) and only reach a branch if the branch
-- replays history, which it does not. The third, `payment_due`, is seeded by NO
-- migration at all: #450 built the receivables chase on top of it with the note
-- "the chase has a real route already: payment_due, enabled, with a template",
-- and that route exists on production because a human inserted it. A route that
-- three admin actions send through, that no migration can rebuild, is one
-- restore away from gone.
--
-- So: assert all three from a migration, idempotently. On production every row
-- is already there and `do nothing` makes this a no-op that touches no label,
-- no template binding and no enabled flag. On any database built from
-- migrations — a build branch, a restore, a fresh environment — the three
-- routes now exist, and the journeys judge the CODE instead of reporting a
-- fixture gap.
--
-- Deliberately NOT enabled: a cast must never arm a live send path. payment_due
-- and reorder_due are inserted disabled and auto_manage off, and production
-- (where they are already enabled) keeps its own values untouched.

begin;

insert into public.wa_event_routes
  (event_key, label, description, audience, auto_manage, enabled, bypass_send_window)
values
  ('payment_due',
   'Payment due',
   'CHANGE #637 cast — the receivables chase (admin_receivables_chase) and the '
   || 'payment-QR fallback both send through this key. Registered by migration so '
   || 'a schema-only clone is not missing it; left OFF here, production keeps its own row.',
   'customer', false, false, false),
  ('payment_utr_request',
   'Ask the customer for the UTR',
   'CHANGE #450 (feature_gaps #18) — sent from the payment verification queue when '
   || 'a claim arrives with no bank reference. Without the UTR the payment cannot be '
   || 'matched to the statement.',
   'customer', false, false, true),
  ('reorder_due',
   'Reorder due',
   'Monthly reorder nudge to a customer (admin_customer_churn_nudge).',
   'customer', false, false, false)
on conflict (event_key) do nothing;

-- NOT cast here: `_journey_c1016_staff_ia`. Its first leg is the same shape (six
-- staff_nav_tab rows a branch never replays), but staff_nav_tab.icon_key is a
-- foreign key into ui_icon, which is empty on a branch for the same reason, and
-- the journey's remaining assertions read the whole feature_registry /
-- nav_category catalogue. That is a catalogue cast, not a config row, and it
-- belongs to #1803's scripts/branch_seed.sql rather than to this command.

commit;
