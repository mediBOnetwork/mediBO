-- CHANGE #289 — weekly boot-disk snapshot, moved from gcloud to AWS EC2.
--
-- The scheduled "Weekly disk snapshot" job still pointed at gcp_snapshot.sh,
-- which shells out to `gcloud compute snapshots create` on a GCP instance that
-- no longer exists (vm_identity.cloud = 'aws' since CHANGE #224). The builder
-- has no gcloud, no AWS CLI and no IAM instance profile — by design — so the
-- snapshot is now taken by the `vm-snapshot` edge function, where the AWS key
-- already lives for vm-control.
--
-- This migration is the backend half: the retention policy as config, every
-- human-facing string as ui_copy, and an offset weekly cron so the snapshot
-- happens even on a week the VM never powers on.
--
-- Idempotent throughout: re-running it is a no-op.

-- 1. Retention policy — config, never a literal in the function.
insert into dev_runner_config (key, value) values (
  'vm_snapshot',
  jsonb_build_object(
    'keep', 4,
    'max_age_days', 28,
    'tag_key', 'medibo-snapshot',
    'tag_value', 'weekly-boot',
    'name_prefix', 'medibo-boot',
    'note', 'Keep the newest 4 weekly snapshots; delete anything older than 28 days.'
  )
) on conflict (key) do update set value = excluded.value;

-- 2. Copy. The edge function words nothing itself.
insert into ui_copy (key, value) values
  ('dev_queue.snap_created',
   to_jsonb('Snapshot {name} ({id}) was taken of the builder VM boot disk, {size}.'::text)),
  ('dev_queue.snap_exists',
   to_jsonb('This week already has a snapshot ({name}, week {week}), so nothing new was created.'::text)),
  ('dev_queue.snap_pruned',
   to_jsonb('Removed {n} old snapshot(s): {list}. {kept} kept — the newest {keep}, nothing older than {days} days.'::text)),
  ('dev_queue.snap_pruned_none',
   to_jsonb('Nothing needed removing — {kept} snapshot(s) kept, all inside the newest {keep} and under {days} days old.'::text)),
  ('dev_queue.snap_no_key',
   to_jsonb('AWS access key not saved yet. Add AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY under Secrets so the weekly snapshot can run.'::text)),
  ('dev_queue.snap_iam_denied',
   to_jsonb('AWS refused this. The saved access key is missing the IAM permission {action} on instance {instance}. Add that action to the key''s IAM policy, then run the snapshot again.'::text)),
  ('dev_queue.snap_aws_error',
   to_jsonb('AWS rejected the snapshot request: {detail}'::text)),
  ('dev_queue.snap_preflight_ok',
   to_jsonb('The saved AWS key holds all {total} snapshot permissions ({list}) on instance {instance} in {region}.'::text)),
  ('dev_queue.snap_preflight_bad',
   to_jsonb('AWS key is missing {missing}. Add {missing} to the IAM policy for instance {instance}, then check again.'::text)),
  ('dev_queue.snap_not_aws',
   to_jsonb('The builder VM is not on AWS right now, so the AWS snapshot path was skipped.'::text))
on conflict (key) do update set value = excluded.value;

-- 3. The weekly kick. pg_cron is up whenever the database is, so a week where
--    the VM never powers on still gets its snapshot. The edge function is
--    idempotent per ISO week, so this and the Dev Queue's own weekly command
--    can both fire without ever taking two snapshots.
create or replace function public.vm_snapshot_kick()
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare k text; req bigint;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name='SERVICE_ROLE_KEY';
  if k is null then raise exception 'vm_snapshot_kick: SERVICE_ROLE_KEY missing from the vault'; end if;
  select net.http_post(
    url := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/vm-snapshot',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'Authorization','Bearer '||k),
    body := jsonb_build_object('action','run'),
    timeout_milliseconds := 55000
  ) into req;
  return req;
end $fn$;

revoke all on function public.vm_snapshot_kick() from public, anon, authenticated;

-- Offset minute on purpose: every bare */N and every :00 job collided on
-- minute 0 and starved the 60-connection cap on 2026-08-18. 21:37 UTC Saturday
-- = 03:07 IST Sunday, seven minutes behind the Dev Queue's own 03:00 schedule.
do $$
begin
  perform cron.unschedule('vm_snapshot_weekly');
exception when others then null;
end $$;
select cron.schedule('vm_snapshot_weekly', '37 21 * * 6', $$select public.vm_snapshot_kick();$$);
