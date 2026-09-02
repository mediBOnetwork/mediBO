-- CHANGE #643 (5/5) — the two numbers this change bought are now guarded.
--
-- Both regressions are silent and both cost money, so neither is left to
-- anyone's memory: a table put back in the publication, or a key put back on
-- the card, turns rg_check red in the command that did it.

insert into public.rg_behavior_tests (name, body, enabled, note) values
('c643_realtime_publication_small', $body$
do $b$
declare n int; v_tables text;
begin
  select count(*), string_agg(tablename, ', ' order by tablename)
    into n, v_tables
  from pg_publication_tables where pubname = 'supabase_realtime';
  if n > 8 then
    raise exception
      'C643: supabase_realtime publishes % tables (max 8): %. Realtime decodes the WAL once per published table per subscriber — set live=false in realtime_table_registry and run realtime_publication_sync().',
      n, v_tables;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$body$, true,
 'CHANGE #643: 29 published tables produced 7.44M realtime messages (149% of the 5M allowance) with zero customers online. Eight is the ceiling.'),

('c643_dev_cmd_list_payload_small', $body$
do $b$
declare n int;
begin
  select length(public.dev_cmd_list(null, null, null, 50)::text) into n;
  if n > 51200 then
    raise exception
      'C643: dev_cmd_list(limit 50) is % bytes (max 51200). A detail key has been added back to the card — put it in dev_cmd_get instead and keep it out of _dev_card_keys().',
      n;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$body$, true,
 'CHANGE #643: the list was 2.4 MB for 200 rows (build_log_tail alone was 4.2 kB per row) and 19,592 calls a day made it 12 GB of the 36 GB egress.'),

('c643_noop_updates_suppressed', $body$
do $b$
declare v_missing text;
begin
  select string_agg(pt.tablename, ', ' order by pt.tablename) into v_missing
  from pg_publication_tables pt
  where pt.pubname = 'supabase_realtime'
    and not exists (
      select 1 from pg_trigger tg
      join pg_class c on c.oid = tg.tgrelid
      join pg_namespace ns on ns.oid = c.relnamespace
      where ns.nspname = pt.schemaname and c.relname = pt.tablename
        and tg.tgname = 'zzz_c643_suppress_noop');
  if v_missing is not null then
    raise exception
      'C643: published without the no-op guard: %. Run realtime_suppress_noop_install() — an UPDATE that changes nothing must not become a WAL record and a broadcast.',
      v_missing;
  end if;
  raise exception 'RG_ROLLBACK';
end $b$;
$body$, true,
 'CHANGE #643: pharmacy_profiles took 45,550 UPDATEs across 10 rows because my_session() rewrote the binding on every poll. suppress_redundant_updates_trigger() makes that class of write free.')

on conflict (name) do update
  set body = excluded.body, enabled = excluded.enabled, note = excluded.note;
