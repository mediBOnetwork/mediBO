-- CMD #1924 — Restore the Payment and Partner entry point.
--
-- WHY IT VANISHED: CHANGE #325 deleted the hand-written admin rows from the
-- profile dropdown (and the desktop "More" popup) and made `feature_registry`
-- the only source of a nav row. It also CHECK-constrains surface='profile' to
-- View Profile and Logout, so the door Om had always used is closed ON PURPOSE
-- and must not be reopened. `admin.payment_upi` survived the move, but only as
-- the 4th tile inside Money > "Bills & payments" — and with dashboard_section
-- NULL it never became a Dashboard tile, which #1891 made the designated home
-- for every door the old strips carried. Result: the screen was reachable in
-- theory (deep link /admin/go/payment_upi opens it) and unfindable in practice.
--
-- The fix is data, not code: one named Dashboard section on the FIRST screen a
-- super admin lands on, carrying the same registry row the Money tab draws.
-- Idempotent — safe to replay.

insert into public.ui_copy (key, value)
values ('dashboard_home.section_money_partners', '"MONEY & PARTNERS"'::jsonb)
on conflict (key) do update set value = excluded.value;

insert into public.dashboard_section (section_key, sort_order, label_key, show_when_empty)
values ('money_partners', 45, 'dashboard_home.section_money_partners', false)
on conflict (section_key) do update
  set sort_order      = excluded.sort_order,
      label_key       = excluded.label_key,
      show_when_empty = excluded.show_when_empty;

-- The section list is a closed CHECK on feature_registry, so a seventh named
-- section is admitted explicitly rather than by widening the column to anything.
alter table public.feature_registry
  drop constraint if exists feature_registry_dashboard_section_ck;
alter table public.feature_registry
  add constraint feature_registry_dashboard_section_ck
  check (dashboard_section is null or dashboard_section = any (array[
    'needs_now','onboarding','field_growth','delivery','returns_issues',
    'my_work','money_partners']));

update public.feature_registry
   set dashboard_section = 'money_partners'
 where feature_key = 'admin.payment_upi'
   and coalesce(dashboard_section, '') is distinct from 'money_partners';
