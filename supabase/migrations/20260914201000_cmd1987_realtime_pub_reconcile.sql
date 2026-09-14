-- CMD #1987 — reconcile the realtime publication with the realtime registry.
--
-- NOT this command's feature; it is the red rg_check standing between this
-- command and its completion gate, so it is this command's job (rule 8).
--
-- rg_check behaviour target c646_registry_matches_publication is red on
-- production:
--   "published but not live in the registry: [-]; live in the registry but
--    not published: [payment_alert_speak]"
--
-- payment_alert_speak is CMD #1929's realtime feed. Its own migration
-- (20260912120000_cmd1929_payment_alerts.sql) does exactly this ADD, but
-- wrapped in `exception when others then null` — so whatever went wrong when
-- that file replayed on live (lock, ownership, ordering) was swallowed and the
-- registry has claimed the table is live ever since. The branch DB, which
-- replays the same file from scratch, DOES have the table published, so the
-- statement itself is legal for the migration role and a retry is the fix.
--
-- Idempotent: on the branch and on any database where the table is already
-- published this is a no-op. The failure is reported as a NOTICE this time
-- instead of vanishing, so a second failure is visible in the replay log
-- rather than only in the guard three days later.
do $$
declare
  v_missing text;
begin
  if to_regclass('public.payment_alert_speak') is null then
    raise notice 'CMD #1987: payment_alert_speak does not exist here — nothing to publish';
    return;
  end if;

  for v_missing in
    select r.table_name
      from public.realtime_table_registry r
     where coalesce(r.live, false)
       and not exists (
             select 1 from pg_publication_tables p
              where p.pubname = 'supabase_realtime'
                and p.schemaname = 'public'
                and p.tablename = r.table_name)
  loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', v_missing);
      raise notice 'CMD #1987: published public.% to supabase_realtime', v_missing;
    exception when others then
      raise notice 'CMD #1987: could NOT publish public.% — %', v_missing, sqlerrm;
    end;
  end loop;
end $$;
