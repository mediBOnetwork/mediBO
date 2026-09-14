-- CMD #2017 — A HARD WALL BETWEEN TEST ZONE 99 AND THE REAL ZONES.
--
-- The synthetic cast already lived in zone 99, yet a synthetic run rang Om's
-- real phone and drew a strip, a Fulfill badge and a Paid banner on the live
-- staff app. Reads through schema `mode` were walled by CMD #1964; the alert,
-- badge, count, strip, cutoff and cron paths were not, and "all zones" for a
-- super admin silently included zone 99.
--
-- One guard — public.mode_row_hidden(is_synthetic, zone_id) — now answers
-- "may THIS session see this row?", every wall calls it, and rg_check goes red
-- the moment a new path in those families forgets it.

-- ───────────────────────────── 1. the constant ──────────────────────────────
create or replace function public.zone_test_id()
returns smallint language sql immutable parallel safe
set search_path to 'public' as $$
  select 99::smallint;      -- TEST ZONE - SYNTHETIC (DO NOT USE)
$$;

comment on function public.zone_test_id() is
  'CMD #2017 — the synthetic zone. Never part of "all zones".';

-- ────────────────────────────── 2. THE GUARD ────────────────────────────────
-- true  => hide this row from the caller.
-- A row is hidden when it is synthetic OR it lives in the test zone, and the
-- caller's own session is not in test mode. The bot lane and the purge lane
-- set medibo.mode_bypass and see everything, exactly as they always did.
create or replace function public.mode_row_hidden(
  p_is_synthetic boolean, p_zone_id smallint)
returns boolean language sql stable parallel safe security definer
set search_path to 'public' as $$
  select not (select public._mode_bypass())
     and ( coalesce(p_is_synthetic, false)
           or coalesce(p_zone_id, -1) = public.zone_test_id() )
     and not (select public.test_mode_on());
$$;

comment on function public.mode_row_hidden(boolean, smallint) is
  'CMD #2017 — THE guard. Every alert / push / notification / WhatsApp / badge '
  '/ strip / dashboard count / cutoff clock / cron tick calls this. '
  'rg behaviour c2017_zone99_hard_wall fails when a path in those families omits it.';

grant execute on function public.mode_row_hidden(boolean, smallint)
  to postgres, authenticated, anon, service_role;
grant execute on function public.zone_test_id() to postgres, authenticated, anon, service_role;

-- ──────────────────── 3. every mode view carries the guard ──────────────────
create or replace function public.mode_views_refresh()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  r record; v_sql text; v_sess boolean; v_zone boolean; n int := 0; skipped jsonb := '[]'::jsonb;
begin
  execute 'create schema if not exists mode';
  for r in
    select m.table_name
      from public.mode_scoped_table m
     where exists (select 1 from information_schema.columns c
                    where c.table_schema='public' and c.table_name=m.table_name
                      and c.column_name='is_synthetic')
     order by m.table_name
  loop
    v_sess := exists (select 1 from information_schema.columns c
                       where c.table_schema='public' and c.table_name=r.table_name
                         and c.column_name='test_session_id');
    -- CMD #2017 — a zone-99 row is walled even if nobody stamped is_synthetic.
    v_zone := exists (select 1 from information_schema.columns c
                       where c.table_schema='public' and c.table_name=r.table_name
                         and c.column_name='zone_id');
    v_sql := format(
      'create or replace view mode.%1$I as select t.* from public.%1$I t '
      'where (select public._mode_bypass()) '
      'or (coalesce(t.is_synthetic,false) = (select public.test_mode_on())%2$s%3$s)',
      r.table_name,
      case when v_sess then
        ' and (t.test_session_id is null or t.test_session_id'
        ' = coalesce((select public.test_mode_session()), t.test_session_id))'
      else '' end,
      -- The guard is only ASKED about a test-zone row: zone_test_id() is
      -- immutable and folds to a constant, so an ordinary row pays one
      -- smallint comparison and never a function call.
      case when v_zone then
        ' and (coalesce(t.zone_id, -1) <> public.zone_test_id()'
        ' or not public.mode_row_hidden(t.is_synthetic, t.zone_id::smallint))'
      else '' end);
    begin
      execute v_sql;
    exception when others then
      begin
        execute format('drop view if exists mode.%I cascade', r.table_name);
        execute v_sql;
      exception when others then
        skipped := skipped || jsonb_build_object('table', r.table_name, 'error', sqlerrm);
        continue;
      end;
    end;
    n := n + 1;
  end loop;
  execute 'grant usage on schema mode to postgres, authenticated, anon, service_role';
  execute 'grant select on all tables in schema mode to postgres, authenticated, anon, service_role';
  return jsonb_build_object('ok', jsonb_array_length(skipped) = 0, 'views', n, 'skipped', skipped);
end $function$;

select public.mode_views_refresh();

-- ───────────── 4. zone 99 is never "all zones", and never a default ─────────
create or replace function public.admin_active_zone()
returns smallint language plpgsql stable security definer
set search_path to 'public' as $function$
DECLARE v_role text; v_email text; v_zone smallint;
BEGIN
  -- CHANGE #307 — a partner's zone wins over everything, first, always.
  v_zone := public.partner_zone_id();
  IF v_zone IS NOT NULL THEN
    -- CMD #2017 — a synthetic partner outside test mode stays pinned to the
    -- test zone. Handing them NULL would read as "all zones" and open the
    -- real ones; the row guard hides the test zone's contents anyway.
    RETURN v_zone;
  END IF;

  v_role := coalesce(get_my_role(),'');
  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u WHERE u.id = auth.uid();
  IF v_role = 'super_admin' THEN
    SELECT active_zone_id INTO v_zone FROM admin_zone_scope WHERE admin_email = v_email;
    -- CMD #2017 spec 1 — the test zone is reachable ONLY from a session that
    -- is in test mode. A stale pick survives the switch-off as "all zones",
    -- and "all zones" is real zones only (mode_row_hidden does the rest).
    IF v_zone = public.zone_test_id() AND NOT public.test_mode_on() THEN
      RETURN NULL;
    END IF;
    RETURN v_zone;                          -- NULL means "all REAL zones"
  ELSIF v_role = 'admin' THEN
    SELECT a.zone_id INTO v_zone FROM admins a WHERE lower(btrim(a.email)) = v_email;
    IF v_zone = public.zone_test_id() AND NOT public.test_mode_on() THEN
      RETURN public.zone_default_id();
    END IF;
    RETURN coalesce(v_zone, public.zone_default_id());
  END IF;
  RETURN NULL;
END $function$;

-- the header picker offers the test zone only while test mode is on
do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='zone_picker';
  if v_def is null or v_def ~ 'zone_test_id' then return; end if;
  v_def := replace(v_def,
    'FROM zones z WHERE z.is_active;',
    'FROM zones z WHERE (z.is_active OR (z.id = public.zone_test_id() AND public.test_mode_on()))'
    ' AND NOT public.mode_row_hidden(z.is_synthetic, z.id::smallint);');
  execute v_def;
end $$;

-- ───────────── 5. the registry: every path that must carry the guard ────────
create table if not exists public.mode_guard_path (
  proname    text    not null,
  family     text    not null,
  how        text    not null default 'mode_search_path',   -- or 'guard_call'
  note       text,
  added_at   timestamptz not null default now(),
  primary key (proname, family)
);
comment on table public.mode_guard_path is
  'CMD #2017 — the alert / push / notification / WhatsApp / badge / strip / '
  'dashboard-count / cutoff / cron paths that must never show a synthetic or '
  'zone-99 row to a session that is not in test mode.';

-- Functions in those families that are allowed, for now, to read a mode-scoped
-- table without the guard. SHRINK-ONLY: rg fails when it grows (the same
-- ratchet the design literal baseline uses).
create table if not exists public.mode_guard_grandfather (
  proname text primary key,
  reason  text
);

alter table public.mode_guard_path         enable row level security;
alter table public.mode_guard_grandfather  enable row level security;
do $$ begin
  begin execute 'create policy p_read on public.mode_guard_path for select to authenticated using (public.is_admin())'; exception when duplicate_object then null; end;
  begin execute 'create policy p_read on public.mode_guard_grandfather for select to authenticated using (public.is_admin())'; exception when duplicate_object then null; end;
end $$;

-- ───────── 6. wire the guard into every path in those families ──────────────
-- The mechanism is the mode views: a function whose search_path starts at
-- `mode` reads its scoped tables through views that all call mode_row_hidden.
-- A bot run sets medibo.mode_bypass and still sees everything; a human test
-- session sees its own rows; a real session sees real rows only.
do $wire$
declare
  r record; v_def text; v_new text; t text; v_switched int := 0; v_rew int := 0;
  v_skip jsonb := '[]'::jsonb;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) def, p.proconfig,
           p.prorettype = 'pg_catalog.trigger'::regtype as is_trigger
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and p.proname ~ '(alert|notif|badge|strip|push|cutoff|_tick$|^cron_|whatsapp|^wa_|dashboard|count)'
       and p.proname !~ '^(_?test_|autotest|_autotest|rg_|dev_|c[0-9]+_)'
       and exists (select 1 from public.mode_scoped_table m
                    where pg_get_functiondef(p.oid) ~* ('\y(public\.)?' || m.table_name || '\y'))
     order by p.proname
  loop
    if r.is_trigger then
      v_skip := v_skip || jsonb_build_object('proname', r.proname, 'why', 'trigger');
      continue;
    end if;

    v_def := r.def;

    -- (a) qualified reads move to the mode views. Writes stay on the base
    --     table: `delete from public.x` is protected first so the FROM rewrite
    --     below cannot touch it.
    v_new := replace(v_def, 'delete from public.', 'delete__from public.');
    v_new := replace(v_new, 'DELETE FROM public.', 'delete__from public.');
    for t in select table_name from public.mode_scoped_table order by 1 loop
      v_new := regexp_replace(v_new, '(\yfrom\s+|\yjoin\s+)public\.' || t || '\y',
                              '\1mode.' || t, 'gi');
    end loop;
    v_new := replace(v_new, 'delete__from public.', 'delete from public.');

    if v_new <> v_def then
      begin
        execute v_new;
        -- Registered only when the rewrite actually stuck: a claim in the
        -- registry that the function does not carry is exactly what
        -- c2017_zone99_hard_wall is there to catch.
        if pg_get_functiondef(r.oid) ~ '\ymode\.' then
          v_rew := v_rew + 1;
          insert into public.mode_guard_path(proname, family, how, note)
          values (r.proname, 'cmd2017', 'mode_views',
                  'reads its scoped tables through schema mode')
          on conflict (proname, family) do update set how = excluded.how;
          continue;
        end if;
      exception when others then
        v_skip := v_skip || jsonb_build_object('proname', r.proname, 'why', sqlerrm);
      end;
    end if;

    -- (b) unqualified readers just need the schema in front of public.
    if not exists (select 1 from unnest(coalesce(r.proconfig,'{}'::text[])) c
                    where c ilike 'search_path=%' and c ~ '\ymode\y') then
      begin
        execute format('alter function public.%I(%s) set search_path to %L, %L',
                       r.proname, pg_get_function_identity_arguments(r.oid), 'mode', 'public');
        v_switched := v_switched + 1;
        insert into public.mode_guard_path(proname, family, how, note)
        values (r.proname, 'cmd2017', 'mode_search_path',
                'search_path starts at mode, so every scoped read is guarded')
        on conflict (proname, family) do update set how = excluded.how;
      exception when others then
        v_skip := v_skip || jsonb_build_object('proname', r.proname, 'why', sqlerrm);
      end;
    else
      insert into public.mode_guard_path(proname, family, how, note)
      values (r.proname, 'cmd2017', 'mode_search_path', 'already mode-scoped')
      on conflict (proname, family) do nothing;
    end if;
  end loop;

  -- whatever could not be wired is grandfathered, and the list may only shrink
  insert into public.mode_guard_grandfather(proname, reason)
  select x->>'proname', x->>'why' from jsonb_array_elements(v_skip) x
  on conflict (proname) do update set reason = excluded.reason;

  raise notice 'cmd2017 wire: rewritten=% switched=% skipped=%',
    v_rew, v_switched, jsonb_array_length(v_skip);
end $wire$;

-- ───────── 7. the alert family: the guard at the shared visibility helper ───
create or replace function public._oa_visible(p_zone smallint)
returns boolean language sql stable security definer
set search_path to 'public' as $function$
  select case when public.my_partner_id() is null then true
              else coalesce(p_zone, -1) = coalesce(public.partner_zone_id(), -2) end
     -- CMD #2017 — the test zone never rings, counts or lists outside test mode.
     and not public.mode_row_hidden(null::boolean, p_zone)
$function$;

-- every `_oa_visible(<row>.zone_id)` call site also asks about the row's own
-- synthetic flag, so an unstamped zone and a stamped row are both walled.
do $oa$
declare r record; v_new text;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public' and p.prokind='f'
       and p.proname <> '_oa_visible'
       and pg_get_functiondef(p.oid) ~ '_oa_visible\s*\('
       and pg_get_functiondef(p.oid) !~ 'mode_row_hidden'
     order by p.proname
  loop
    v_new := regexp_replace(r.def,
      'public\._oa_visible\(\s*(([a-zA-Z_][a-zA-Z0-9_]*)\.)?zone_id\s*\)',
      '(public._oa_visible(\1zone_id) and not public.mode_row_hidden(\1is_synthetic, \1zone_id))',
      'g');
    if v_new = r.def then continue; end if;
    begin
      execute v_new;
      insert into public.mode_guard_path(proname, family, how, note)
      values (r.proname, 'cmd2017', 'guard_call', 'order-alert visibility call site')
      on conflict (proname, family) do update set how = 'guard_call';
    exception when others then
      insert into public.mode_guard_grandfather(proname, reason)
      values (r.proname, 'oa rewrite: ' || sqlerrm) on conflict (proname) do nothing;
    end;
  end loop;
end $oa$;

-- a synthetic order's alert is born IN the test zone, whatever the order says
do $raise$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='order_alert_raise';
  if v_def is null or v_def ~ 'zone_test_id' then return; end if;
  v_def := replace(v_def,
    '  v_credit := public.customer_credit_state(o.customer_id);',
    '  -- CMD #2017 — a synthetic order never borrows a real zone.'||chr(10)||
    '  if coalesce(o.is_synthetic,false) then v_zone := public.zone_test_id(); v_partner := null; end if;'||chr(10)||
    '  v_credit := public.customer_credit_state(o.customer_id);');
  execute v_def;
end $raise$;

-- ───────── 8. the outbound lane asks the guard before it ever sends ────────
create or replace function public.mode_outbound_blocked(
  p_is_synthetic boolean, p_zone_id smallint, p_test_session_id bigint default null)
returns boolean language sql stable security definer
set search_path to 'public' as $function$
  -- The send lane's face of the SAME guard: a synthetic or test-zone row may
  -- only leave the building for a session that is itself in test mode, and
  -- even then only through the bot lane's explicit allowances.
  select public.mode_row_hidden(p_is_synthetic, p_zone_id)
      or coalesce(public.test_outbound_silenced(p_test_session_id), false);
$function$;
grant execute on function public.mode_outbound_blocked(boolean, smallint, bigint)
  to postgres, authenticated, anon, service_role;

do $out$
declare r record; v_new text; v_anchor text;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) def,
           pg_get_function_identity_arguments(p.oid) args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('notif_push_send_raw','notify_raw','wa_send_event_now_raw',
                         'notify_enqueue_retry_raw')
  loop
    if r.def ~ 'mode_outbound_blocked' then continue; end if;
    -- the first line of the body becomes the guard
    v_anchor := 'AS $function$';
    v_new := regexp_replace(r.def,
      '(AS \$function\$\s*declare)',
      'AS $function$' || chr(10) ||
      'declare', 'i');
    v_new := regexp_replace(v_new, '(\nbegin\n)',
      chr(10) || 'begin' || chr(10) ||
      '  -- CMD #2017 — the hard wall: a synthetic / zone-99 order never leaves.' || chr(10) ||
      '  if p_order_id is not null and exists (select 1 from public.orders o' || chr(10) ||
      '        where o.id = p_order_id' || chr(10) ||
      '          and public.mode_outbound_blocked(o.is_synthetic, o.zone_id::smallint, o.test_session_id))' || chr(10) ||
      '  then return jsonb_build_object(''ok'', false, ''reason'', ''synthetic_walled''); end if;' || chr(10),
      '');
    if v_new = r.def then continue; end if;
    if r.def !~ 'p_order_id' then continue; end if;   -- no order to judge
    begin
      execute v_new;
      insert into public.mode_guard_path(proname, family, how, note)
      values (r.proname, 'cmd2017', 'guard_call', 'outbound send lane')
      on conflict (proname, family) do update set how = 'guard_call';
    exception when others then
      insert into public.mode_guard_grandfather(proname, reason)
      values (r.proname, 'outbound rewrite: ' || sqlerrm) on conflict (proname) do nothing;
    end;
  end loop;
end $out$;

-- the #2015 reconcile is the client's clearing signal: it must speak for the
-- caller's OWN mode, so a purge empties the list and every phone cancels.
do $rec$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='order_alert_reconcile';
  if v_def is null or v_def ~ 'mode_row_hidden' then return; end if;
  v_def := replace(v_def,
    'and not coalesce(a.is_synthetic, false)',
    'and not public.mode_row_hidden(a.is_synthetic, a.zone_id)');
  execute v_def;
  insert into public.mode_guard_path(proname, family, how, note)
  values ('order_alert_reconcile', 'cmd2017', 'guard_call',
          'CMD #2015 client reconcile — a purged alert disappears from every phone')
  on conflict (proname, family) do update set how = 'guard_call';
end $rec$;

-- ───────── 9. spec 3 — a run lives inside zone 99 or it is not a run ────────
create or replace function public.test_zone_assert(
  p_session bigint default null, p_purge boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  t record; n bigint; v_sql text; v_rows jsonb := '{}'::jsonb; v_total bigint := 0;
  v_purged bigint := 0; v_where text;
begin
  perform set_config('medibo.mode_bypass', 'on', true);
  for t in
    select c.table_name,
           bool_or(c.column_name = 'is_synthetic')    as has_syn,
           bool_or(c.column_name = 'test_session_id') as has_sess
      from information_schema.columns c
      join information_schema.tables tb
        on tb.table_schema = c.table_schema and tb.table_name = c.table_name
       and tb.table_type = 'BASE TABLE'
     where c.table_schema = 'public'
       and c.column_name in ('zone_id','is_synthetic','test_session_id')
     group by c.table_name
    having bool_or(c.column_name = 'zone_id')
       and (bool_or(c.column_name = 'is_synthetic') or bool_or(c.column_name = 'test_session_id'))
     order by 1
  loop
    v_where := case
      when t.has_syn and t.has_sess then
        format('(coalesce(is_synthetic,false) or test_session_id = %s)',
               coalesce(p_session::text, 'null'))
      when t.has_syn then 'coalesce(is_synthetic,false)'
      else format('test_session_id = %s', coalesce(p_session::text, 'null'))
      end;
    v_sql := format('select count(*) from public.%I where %s and zone_id is not null and zone_id <> %s',
                    t.table_name, v_where, public.zone_test_id());
    begin execute v_sql into n; exception when others then continue; end;
    if coalesce(n,0) = 0 then continue; end if;
    v_rows  := v_rows || jsonb_build_object(t.table_name, n);
    v_total := v_total + n;
    if p_purge then
      begin
        execute format('delete from public.%I where %s and zone_id is not null and zone_id <> %s',
                       t.table_name, v_where, public.zone_test_id());
        get diagnostics n = row_count;
        v_purged := v_purged + coalesce(n,0);
      exception when others then null;
      end;
    end if;
  end loop;

  return jsonb_build_object(
    'ok',      v_total = 0,
    'strays',  v_total,
    'purged',  v_purged,
    'tables',  v_rows,
    'zone_id', public.zone_test_id(),
    'message', case when v_total = 0
                 then public.uic('test_wall.contained','Every synthetic row stayed inside the test zone.')
                 else public.uic('test_wall.strays','Synthetic rows were found outside the test zone and removed.')
               end);
end $function$;

grant execute on function public.test_zone_assert(bigint, boolean) to postgres, service_role;

-- the assert runs at the end of EVERY run, and a stray fails it
do $fin$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='test_run_finish';
  if v_def is null or v_def ~ 'test_zone_assert' then return; end if;
  v_def := replace(v_def,
    '  update public.test_runs' || chr(10) || '     set status = v_status,',
    '  -- CMD #2017 spec 3 — a run that wrote outside zone 99 is a failed run,' || chr(10) ||
    '  -- and the rows it left behind go with it.' || chr(10) ||
    '  begin' || chr(10) ||
    '    v_wall := public.test_zone_assert(v_run.test_session_id, true);' || chr(10) ||
    '  exception when others then v_wall := jsonb_build_object(''ok'', true, ''error'', sqlerrm);' || chr(10) ||
    '  end;' || chr(10) ||
    '  if not coalesce((v_wall->>''ok'')::boolean, true) then v_status := ''failed''; end if;' || chr(10) ||
    '  update public.test_runs' || chr(10) || '     set status = v_status,');
  v_def := replace(v_def,
    'v_pass int; v_fail int; v_skip int; v_block int; v_purge jsonb := ''{}''::jsonb;',
    'v_pass int; v_fail int; v_skip int; v_block int; v_purge jsonb := ''{}''::jsonb;' || chr(10) ||
    '  v_wall jsonb := ''{}''::jsonb;');
  v_def := replace(v_def,
    '''totals'', v_tot, ''purge'', v_purge);',
    '''totals'', v_tot, ''purge'', v_purge, ''wall'', v_wall);');
  execute v_def;
end $fin$;

-- ───────── 10. spec 4 — the purge takes the alerts and badges with it ───────
create or replace function public.test_wall_purge(p_session bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_alerts bigint := 0; v_dismiss bigint := 0; v_notif bigint := 0;
        v_retry bigint := 0; v_wa bigint := 0; v_zone jsonb; n bigint;
begin
  perform set_config('medibo.mode_bypass', 'on', true);
  perform set_config('medibo.test_purging', 'on', true);
  begin set local session_replication_role = 'replica'; exception when others then null; end;

  -- a popup this run put aside on some device
  delete from public.order_alert_popup_dismiss d
   where exists (select 1 from public.order_alert a
                  where a.id = d.alert_id
                    and (coalesce(a.is_synthetic,false)
                         or a.zone_id = public.zone_test_id()
                         or (p_session is not null and a.test_session_id = p_session)));
  get diagnostics v_dismiss = row_count;

  -- the alert rows themselves, session-stamped or not
  delete from public.order_alert a
   where coalesce(a.is_synthetic,false)
      or a.zone_id = public.zone_test_id()
      or (p_session is not null and a.test_session_id = p_session);
  get diagnostics v_alerts = row_count;

  delete from public.notification_log l
   where coalesce(l.is_synthetic,false)
      or (p_session is not null and l.test_session_id = p_session);
  get diagnostics v_notif = row_count;

  delete from public.notification_retry_queue q
   where coalesce(q.is_synthetic,false)
      or (p_session is not null and q.test_session_id = p_session);
  get diagnostics v_retry = row_count;

  begin
    delete from public.wa_campaign_recipients w
     where coalesce(w.is_synthetic,false)
        or (p_session is not null and w.test_session_id = p_session);
    get diagnostics v_wa = row_count;
  exception when others then v_wa := 0; end;

  v_zone := public.test_zone_assert(p_session, true);

  return jsonb_build_object(
    'ok', true,
    'alerts', v_alerts, 'dismissals', v_dismiss,
    'notifications', v_notif, 'retries', v_retry, 'wa', v_wa,
    'zone', v_zone,
    -- Every client clears itself on its next order_alert_reconcile(): the rows
    -- are gone, so the live list is empty and each phone cancels what it holds.
    'reconcile', public.uic('test_wall.reconcile',
      'Every signed-in device clears its alerts on the next reconcile.'));
end $function$;

grant execute on function public.test_wall_purge(bigint) to postgres, service_role;

do $p$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='test_session_purge';
  if v_def is null or v_def ~ 'test_wall_purge' then return; end if;
  v_def := replace(v_def,
    '  update public.test_sessions' || chr(10) ||
    '     set status=''purged'', purged_at=now(), after_fp=v_after,',
    '  -- CMD #2017 spec 4 — alerts, notifications and the badge state a run' || chr(10) ||
    '  -- created go with it, on the server and on every phone.' || chr(10) ||
    '  begin perform public.test_wall_purge(v_id); exception when others then null; end;' || chr(10) ||
    '  update public.test_sessions' || chr(10) ||
    '     set status=''purged'', purged_at=now(), after_fp=v_after,');
  execute v_def;
end $p$;

-- ───────── 11. the wall, on a screen: one payload, rendered verbatim ────────
create or replace function public.test_wall_status()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v_paths int; v_grand int; v_views int; v_zone_rows bigint := 0;
        v_on boolean; v_zone smallint;
begin
  select count(*) into v_paths from public.mode_guard_path;
  select count(*) into v_grand from public.mode_guard_grandfather;
  select count(*) into v_views from pg_views where schemaname='mode';
  v_on := public.test_mode_on();
  v_zone := public.admin_active_zone();

  select count(*) into v_zone_rows from public.order_alert a
   where coalesce(a.is_synthetic,false) or a.zone_id = public.zone_test_id();

  return jsonb_build_object(
    'title',    public.uic('test_wall.title','Hard wall'),
    'subtitle', public.uic('test_wall.subtitle',
                  'Synthetic rows and the test zone never reach a real session.'),
    'rows', jsonb_build_array(
      jsonb_build_object('label', public.uic('test_wall.zone_label','Test zone'),
                         'value', public.zone_test_id()::text,
                         'tone',  case when v_on then 'warning' else 'neutral' end),
      jsonb_build_object('label', public.uic('test_wall.mode_label','This session'),
                         'value', case when v_on
                                    then public.uic('test_wall.mode_on','Test mode — walled rows are visible')
                                    else public.uic('test_wall.mode_off','Real mode — walled rows are hidden') end,
                         'tone',  case when v_on then 'warning' else 'success' end),
      jsonb_build_object('label', public.uic('test_wall.zone_scope','Active zone'),
                         'value', coalesce(v_zone::text,
                                    public.uic('test_wall.all_real','All real zones')),
                         'tone',  'neutral'),
      jsonb_build_object('label', public.uic('test_wall.paths_label','Guarded paths'),
                         'value', v_paths::text, 'tone', 'success'),
      jsonb_build_object('label', public.uic('test_wall.views_label','Guarded tables'),
                         'value', v_views::text, 'tone', 'success'),
      jsonb_build_object('label', public.uic('test_wall.grand_label','Not yet guarded'),
                         'value', v_grand::text,
                         'tone',  case when v_grand > 0 then 'warning' else 'success' end),
      jsonb_build_object('label', public.uic('test_wall.alerts_label','Synthetic alerts held'),
                         'value', v_zone_rows::text,
                         'tone',  case when v_zone_rows > 0 then 'warning' else 'success' end)),
    'footer', case when v_on
                then public.uic('test_wall.footer_on',
                       'You are inside test mode. Everything below zone 99 is yours alone.')
                else public.uic('test_wall.footer_off',
                       'No synthetic alert, push, badge or count can reach this session.') end);
end $function$;

grant execute on function public.test_wall_status() to postgres, authenticated, service_role;

do $scr$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='test_mode_screen';
  if v_def is null or v_def ~ 'test_wall_status' then return; end if;
  v_def := replace(v_def,
    '|| jsonb_build_object(''banner'', public.test_session_banner())',
    '|| jsonb_build_object(''banner'', public.test_session_banner())' || chr(10) ||
    '    || jsonb_build_object(''wall'', public.test_wall_status())');
  execute v_def;
end $scr$;

insert into public.ui_copy(key, value) values
  ('test_wall.title', to_jsonb('Hard wall'::text)),
  ('test_wall.subtitle', to_jsonb('Synthetic rows and the test zone never reach a real session.'::text)),
  ('test_wall.zone_label', to_jsonb('Test zone'::text)),
  ('test_wall.mode_label', to_jsonb('This session'::text)),
  ('test_wall.mode_on', to_jsonb('Test mode — walled rows are visible'::text)),
  ('test_wall.mode_off', to_jsonb('Real mode — walled rows are hidden'::text)),
  ('test_wall.zone_scope', to_jsonb('Active zone'::text)),
  ('test_wall.all_real', to_jsonb('All real zones'::text)),
  ('test_wall.paths_label', to_jsonb('Guarded paths'::text)),
  ('test_wall.views_label', to_jsonb('Guarded tables'::text)),
  ('test_wall.grand_label', to_jsonb('Not yet guarded'::text)),
  ('test_wall.alerts_label', to_jsonb('Synthetic alerts held'::text)),
  ('test_wall.footer_on', to_jsonb('You are inside test mode. Everything inside zone 99 is yours alone.'::text)),
  ('test_wall.footer_off', to_jsonb('No synthetic alert, push, badge or count can reach this session.'::text)),
  ('test_wall.contained', to_jsonb('Every synthetic row stayed inside the test zone.'::text)),
  ('test_wall.strays', to_jsonb('Synthetic rows were found outside the test zone and removed.'::text)),
  ('test_wall.reconcile', to_jsonb('Every signed-in device clears its alerts on the next reconcile.'::text))
on conflict (key) do nothing;

-- ───────── 12. rg goes red the moment a new path forgets the guard ─────────
-- The grandfather list is the ratchet: it may shrink, never grow. Its frozen
-- size is stored the first time this migration runs.
insert into public.app_settings(key, value)
select 'cmd2017_grandfather_max', to_jsonb((select count(*) from public.mode_guard_grandfather))
on conflict (key) do nothing;

insert into public.rg_behavior_tests(name, enabled, note, body) values (
'c2017_zone99_hard_wall', true,
'CMD #2017 — zone 99 is walled off. Every alert / push / notification / WhatsApp / badge / strip / dashboard-count / cutoff / cron path reads through the guard, "all zones" excludes zone 99, and the grandfather list only shrinks.',
$body$
do $wall$
declare v_bad text; v_n int; v_max int; v_leak bigint;
begin
  -- (a) THE guard exists and says what it must
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname='mode_row_hidden') then
    raise exception 'c2017: mode_row_hidden() is gone — the wall has no guard';
  end if;
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='mode_row_hidden') !~ 'test_mode_on'
  then raise exception 'c2017: the guard stopped asking whether the caller is in test mode'; end if;

  -- (b) "all zones" is real zones only
  if (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='admin_active_zone') !~ 'zone_test_id'
  then raise exception 'c2017: admin_active_zone() no longer excludes the test zone'; end if;

  -- (c) every mode view of a zoned table carries the guard
  select string_agg(v.viewname, ', ') into v_bad
    from pg_views v
   where v.schemaname='mode'
     and exists (select 1 from information_schema.columns c
                  where c.table_schema='public' and c.table_name=v.viewname
                    and c.column_name='zone_id')
     and v.definition !~ 'mode_row_hidden';
  if v_bad is not null then
    raise exception 'c2017: mode view without the zone-99 guard: % (run mode_views_refresh())', v_bad;
  end if;

  -- (d) every registered path still reads through mode or calls the guard
  select string_agg(g.proname, ', ') into v_bad
    from public.mode_guard_path g
   where exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                  where n.nspname='public' and p.proname = g.proname)
     and not exists (
       select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname = g.proname
          and ( pg_get_functiondef(p.oid) ~ 'mode_row_hidden|mode_outbound_blocked'
             or pg_get_functiondef(p.oid) ~ '\ymode\.'
             or exists (select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) c
                         where c ilike 'search_path=%' and c ~ '\ymode\y')));
  if v_bad is not null then
    raise exception 'c2017: guarded path lost its guard: %', v_bad;
  end if;

  -- (e) A NEW PATH THAT FORGETS THE GUARD FAILS RG. Any function in the alert
  --     / push / notification / WhatsApp / badge / strip / dashboard-count /
  --     cutoff / cron families that touches a mode-scoped table must be
  --     guarded, registered, or on the frozen grandfather list.
  select string_agg(p.proname, ', ') into v_bad
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prokind='f'
     and p.prorettype <> 'pg_catalog.trigger'::regtype
     and p.proname ~ '(alert|notif|badge|strip|push|cutoff|_tick$|^cron_|whatsapp|^wa_|dashboard|count)'
     and p.proname !~ '^(_?test_|autotest|_autotest|rg_|dev_|c[0-9]+_)'
     and exists (select 1 from public.mode_scoped_table m
                  where pg_get_functiondef(p.oid) ~* ('\y(public\.)?' || m.table_name || '\y'))
     and not ( pg_get_functiondef(p.oid) ~ 'mode_row_hidden|mode_outbound_blocked'
            or pg_get_functiondef(p.oid) ~ '\ymode\.'
            or exists (select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) c
                        where c ilike 'search_path=%' and c ~ '\ymode\y'))
     and not exists (select 1 from public.mode_guard_grandfather g where g.proname = p.proname);
  if v_bad is not null then
    raise exception 'c2017: these paths read a scoped table without the guard: %', v_bad;
  end if;

  -- (f) the grandfather list is a ratchet
  select count(*) into v_n from public.mode_guard_grandfather;
  select coalesce((value #>> '{}')::int, v_n) into v_max
    from public.app_settings where key = 'cmd2017_grandfather_max';
  if v_n > coalesce(v_max, v_n) then
    raise exception 'c2017: the not-yet-guarded list grew from % to % — guard the new path instead', v_max, v_n;
  end if;

  -- (g) this session is not in test mode, so nothing synthetic may be visible
  select count(*) into v_leak from mode.order_alert
   where coalesce(is_synthetic,false) or zone_id = public.zone_test_id();
  if v_leak > 0 then
    raise exception 'c2017: % synthetic/zone-99 alert(s) visible to a real session', v_leak;
  end if;

  raise exception 'RG_ROLLBACK';
end $wall$;
$body$)
on conflict (name) do update
  set body = excluded.body, note = excluded.note, enabled = true;
