-- CMD #633 — the permanent journey for "a raw copy template reached a reader".
--
-- The bug: https://medibo.in/<anything-unknown>, signed out, drew the
-- storefront with a red banner reading the BACKEND TEMPLATE — "Failed to load:
-- {e}". Two defects stacked: an admin tab fetched admin data on an anonymous
-- boot (IndexedStack builds every child, so its initState ran for everyone)
-- and its error toast passed {'a': …} to a {e} template, so the placeholder
-- itself was printed.
--
-- A journey has to outlive the fix, so this asserts the CLASS from the four
-- angles the database can actually see:
--   a1  the subject still exists (a vanished function makes every count below
--       silently true, which is how a journey quietly stops asserting).
--   a2  no admin_% function is reachable by anon — an anonymous boot can only
--       ever be refused, never served, whatever a screen decides to call.
--   a3  the LIVE build's render log carries no c633_raw_placeholder key. cf()
--       writes that key whenever it has to strip a slot the caller never
--       filled, so this goes red the next time any screen renders a template
--       at a reader — not just this one screen, and not just this one toast.
--   a4  the two templates the bug was reported against still carry their {e}
--       slot, so the fix cannot be "delete the placeholder from the copy".
create or replace function public._journey_bug633()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_ok boolean;
  v_open int; v_log record; v_slots int; v_fresh boolean;
begin
  v_a1 := exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'admin_customer_screen_data');

  select count(*) into v_open
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and p.proname like 'admin\_%'
     and has_function_privilege('anon', p.oid, 'execute');
  v_a2 := v_open = 0;

  select * into v_log from public.render_log where id = 'singleton';
  -- Freshness matters more here than anywhere: "no placeholder was rendered"
  -- is trivially true of a log nobody has written to.
  v_fresh := v_log.id is not null
         and v_log.updated_at > now() - interval '3 days'
         and coalesce(v_log.build_hash,'') ~ '^[0-9a-f]{7,40}$';
  v_a3 := v_fresh and not (coalesce(v_log.data,'{}'::jsonb) ? 'c633_raw_placeholder');

  select count(*) into v_slots from public.ui_copy
   where key in ('admin_customer.failed_to_load','admin_customer.toast_failed_to_load')
     and value::text like '%{e}%';
  v_a4 := v_slots = 2;

  v_ok := v_a1 and v_a2 and v_a3 and v_a4;
  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'subject present='            || coalesce(v_a1,false)::text ||
      ' | admin_% reachable by anon=' || v_open::text ||
      ' | render log build='        || coalesce(v_log.build_hash,'(none)') ||
      ' fresh='                     || coalesce(v_fresh,false)::text ||
      ' raw_placeholder_seen='      || (coalesce(v_log.data,'{}'::jsonb) ? 'c633_raw_placeholder')::text ||
      ' | {e} still in both templates=' || coalesce(v_a4,false)::text));
end $function$;

revoke all on function public._journey_bug633() from public, anon, authenticated;

-- Wire it into the dispatcher without re-authoring the whole if-chain: take the
-- live definition, insert one branch beside its sibling, put it back. Guarded
-- on the branch already being there, so a resumed worker re-running this is a
-- silent no-op.
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';
  if v_def is null then
    raise exception 'c633: dev_journey_probe not found';
  end if;
  if position('_journey_bug633' in v_def) = 0 then
    v_def := replace(v_def,
      '  if p_name = ''bug-436'' then return public._journey_bug436(); end if;',
      '  if p_name = ''bug-436'' then return public._journey_bug436(); end if;' || E'\n' ||
      '  -- CMD #633 — a raw copy template rendered at a reader, retired as a' || E'\n' ||
      '  -- class: cf() reports every unfilled slot on the render log.' || E'\n' ||
      '  if p_name = ''bug-633'' then return public._journey_bug633(); end if;');
    if position('_journey_bug633' in v_def) = 0 then
      raise exception 'c633: could not find the bug-436 branch to insert beside';
    end if;
    execute v_def;
  end if;
end $$;

-- The journey's own row: the auto-created placeholder said "TODO: implement
-- during fix #633". Replace it with what is actually asserted.
update public.dev_journeys
   set steps = jsonb_build_array(
         'Open any unknown path on medibo.in signed out (the bug: /zzz-not-a-route and the /delivery push link both did it).',
         'Assert no admin_% function is reachable by anon, so an anonymous boot can only be refused.',
         'Read the live build''s render log and assert cf() reported no unfilled placeholder (c633_raw_placeholder).',
         'Assert the two templates still carry their {e} slot, so deleting the placeholder cannot pass for a fix.'),
       assertions = jsonb_build_array(
         'admin_customer_screen_data still exists — the subject of the class did not vanish',
         'zero admin_% functions are executable by anon',
         'the render log is fresh AND carries no c633_raw_placeholder key',
         'admin_customer.failed_to_load and admin_customer.toast_failed_to_load both still contain {e}')
 where name = 'bug-633';
