-- CHANGE #305 step 2 — close the two CRITICAL "RLS Disabled in Public" findings.
--
-- supplier_number_backup_20260823 holds real supplier phone numbers and
-- notification_email_config holds the platform's sending identity. Both sat in
-- the `public` schema with RLS off, which means PostgREST served them to any
-- authenticated token. Neither is read by the app: the only reader is the
-- email-send edge function, and that uses the service_role client, which
-- bypasses RLS. So the correct policy set is the empty one — RLS on, no policy,
-- deny by default — plus an explicit admin read on the config row so the
-- sending identity stays inspectable from the admin surface without reopening
-- the table to every logged-in customer.

alter table public.supplier_number_backup_20260823 enable row level security;
alter table public.notification_email_config       enable row level security;

drop policy if exists notification_email_config_admin_read on public.notification_email_config;
create policy notification_email_config_admin_read
  on public.notification_email_config
  for select
  using (public.is_admin());
