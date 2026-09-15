-- replay-target: production
-- CMD #2053 — "Order cut-off" becomes "Auto cancel", and the screen stops crashing.
--
-- 1. THE CRASH. More ▸ Orders ▸ Order cut-off died with
--    `function public._oa_item(mode.order_alert) does not exist` (42883). The
--    cause is not a missing function: _oa_item(public.order_alert) is right
--    where it always was. It is that `mode` — the test-mode view schema that
--    mode_views_refresh() builds — carries its OWN composite type per view, so
--    `select public._oa_item(a) from mode.order_alert a` hands the function a
--    `mode.order_alert` and no overload exists. Two functions do exactly that:
--    order_alert_settings() (which order_cutoff_screen() reads for the rule's
--    knobs, hence the dead screen) and order_alert_reconcile() (the ring poll).
--    An overload on mode.order_alert would be the wrong repair: that type is
--    dropped and rebuilt every time mode_views_refresh() falls back to
--    `drop view cascade`, and the crash would come back on its own. So the
--    CALLERS are patched to pass row(a.*)::public.order_alert, in place, by
--    rewriting the live definition — never by re-applying a snapshot over a
--    function a concurrent command may have changed.
--
-- 2. THE NAME. The feature is called Auto cancel everywhere a human can read
--    it — the More tile, the screen, the settings group, the audit and the
--    automation pill — and nowhere in Dart. Internal names (order_cutoff_*,
--    cutoff_enabled) are untouched.
--
-- 3. ONE FLAG, TWO DOORS. order_alert_config.cutoff_enabled is the only flag.
--    It is now an automation pill on the Dashboard AND a pill at the top of
--    the Auto cancel screen, and BOTH call dashboard_automation_set(), so the
--    two can never disagree.
--
-- 4/5. OFF = order_cutoff_tick() does nothing at all (it already returns
--    skipped:disabled — the guard is pinned by the rg behaviour below). ON =
--    the existing rule, with pause-outside-hours no longer optional: nothing
--    is auto-cancelled while the shop is open.

-- ── 1. The 42883 crash — every caller that passes a mode.* row ──────────────
do $c2053_fix$
declare
  r     record;
  v_def text;
  v_new text;
  n     int := 0;
begin
  if to_regclass('public.order_alert') is null then
    return;
  end if;

  for r in
    select distinct p.oid, p.proname, m[1] as alias
      from pg_proc p
      join pg_namespace n2 on n2.oid = p.pronamespace
      cross join lateral regexp_matches(p.prosrc, 'from\s+mode\.order_alert\s+([a-z][a-z0-9_]*)', 'g') m
     where n2.nspname = 'public'
       and m[1] not in ('where','order','group','limit','join','left','right',
                        'cross','on','union','having','offset','for','loop')
  loop
    v_def := pg_get_functiondef(r.oid);
    -- Only a BARE alias is rewritten. A call already carrying the row()/cast
    -- form no longer matches, which is what makes this migration idempotent.
    v_new := regexp_replace(
               v_def,
               '(public\._oa_[a-z0-9_]+)\(\s*' || r.alias || '\s*\)',
               '\1(row(' || r.alias || '.*)::public.order_alert)',
               'g');
    if v_new is distinct from v_def then
      execute v_new;
      n := n + 1;
      raise notice 'CMD #2053: patched %() — mode.order_alert row now cast for _oa_* callees', r.proname;
    end if;
  end loop;
  raise notice 'CMD #2053: % function(s) repaired', n;
end
$c2053_fix$;

-- ── 2. Pause outside shop hours is no longer a setting — it is the rule ─────
do $c2053_pause$
declare v_def text; v_new text;
begin
  if to_regprocedure('public.order_cutoff_tick()') is null then return; end if;
  v_def := pg_get_functiondef('public.order_cutoff_tick()'::regprocedure);
  v_new := replace(v_def,
             'if coalesce(cfg.cutoff_pause_outside_hours, true) then',
             'if true then  -- CMD #2053: pause outside shop hours is always on');
  if v_new is distinct from v_def then
    execute v_new;
    raise notice 'CMD #2053: order_cutoff_tick() now always pauses outside shop hours';
  end if;
end
$c2053_pause$;

-- ── 3. The words ────────────────────────────────────────────────────────────
-- oa_label() reads order_alert_config.labels. Merged key by key so a label a
-- later command added is never dropped.
insert into public.order_alert_config (id) values ('singleton')
on conflict (id) do nothing;

update public.order_alert_config
   set labels = coalesce(labels, '{}'::jsonb) || jsonb_build_object(
     'cutoff_screen_title',    'Auto cancel',
     'cutoff_screen_subtitle', 'Unpaid orders are warned and then cancelled after the cut-off. Every value on this screen is live.',
     'cutoff_toggle_label',    'Auto cancel',
     'cutoff_off_note',        'Auto cancel is off.',
     'cutoff_on_note',         'Auto cancel is on. Unpaid orders are warned and cancelled only outside shop hours — while the shop is open nothing is auto-cancelled.',
     'cutoff_sec_settings',    'Auto cancel settings',
     'section_cutoff',         'Auto cancel',
     'field_cutoff_enabled',   'Auto cancel on',
     'cutoff_audit_order_alert_settings_set', 'Auto cancel setting changed'),
       updated_at = now()
 where id = 'singleton';

insert into public.ui_copy(key, value) values
  ('admin_supplier.auto_cancel',              '"Auto cancel"'::jsonb),
  ('admin_supplier.auto_cancel_toast_on',     '"Auto cancel is on. Unpaid orders are cancelled only outside shop hours."'::jsonb),
  ('admin_supplier.auto_cancel_toast_off',    '"Auto cancel is off. No order will be cancelled automatically."'::jsonb),
  ('admin_supplier.settings_auto_cancel_title','"Auto cancel"'::jsonb),
  ('admin_supplier.settings_auto_cancel_body',
   '"When it is on, an unpaid order is warned and then cancelled after the cut-off — but only while the shop is closed. While the shop is open nothing is auto-cancelled. When it is off nothing is warned, held or cancelled: an unpaid order stays pending until an admin acts."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- The notification the customer gets is unchanged; what is renamed is the
-- ADMIN-facing name of each event in the notification console.
update public.wa_event_routes
   set label = 'Auto cancel — advance reminder'
 where event_key = 'order_cutoff_warning';
update public.wa_event_routes
   set label = 'Auto cancel — final advance reminder'
 where event_key = 'order_cutoff_final_warning';
update public.wa_event_routes
   set label = 'Auto cancel — order cancelled'
 where event_key = 'order_cutoff_cancelled';

-- The More tile / nav / search row.
update public.feature_registry
   set label        = 'Auto cancel',
       description  = 'Unpaid orders are warned and then cancelled after the cut-off, outside shop hours only.',
       search_terms = 'auto cancel autocancel cutoff cut-off order hours unpaid advance restore restoration window payment pending'
 where feature_key = 'admin.order_cutoff';

-- ── 4. ONE flag, exposed as an automation pill ──────────────────────────────
create or replace function public._dashboard_auto_cancel_chip()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_on boolean;
begin
  select coalesce(cutoff_enabled,false) into v_on
    from public.order_alert_config where id = 'singleton';
  v_on := coalesce(v_on, false);
  return jsonb_build_object(
    'key',         'auto_cancel',
    'setting_key', 'cutoff_enabled',
    'label',       public._c('admin_supplier.auto_cancel'),
    'on',          v_on,
    'state_label', case when v_on then public._c('admin_supplier.toggle_on')
                        else public._c('admin_supplier.toggle_off') end,
    'tone',        case when v_on then 'on' else 'off' end);
end $$;

comment on function public._dashboard_auto_cancel_chip() is
  'CMD #2053 — the Auto cancel pill, built from the ONE flag (order_alert_config.cutoff_enabled). Read by _dashboard_automation() and by order_cutoff_screen(), so the Dashboard chip and the screen''s own pill can never disagree.';

-- Spliced into the existing pill list rather than re-applied over it.
do $c2053_chip$
declare v_def text; v_new text;
begin
  if to_regprocedure('public._dashboard_automation()') is null then return; end if;
  v_def := pg_get_functiondef('public._dashboard_automation()'::regprocedure);
  if v_def like '%_dashboard_auto_cancel_chip%' then return; end if;
  v_new := replace(v_def,
             E'\'items\', jsonb_build_array(\n',
             E'\'items\', jsonb_build_array(\n      public._dashboard_auto_cancel_chip(),\n');
  if v_new is distinct from v_def then
    execute v_new;
    raise notice 'CMD #2053: Auto cancel pill added to the Dashboard automation row';
  else
    raise exception 'CMD #2053: could not splice the Auto cancel pill into _dashboard_automation()';
  end if;
end
$c2053_chip$;

-- The ONE writer. Both pills call dashboard_automation_set('auto_cancel', …).
do $c2053_set$
declare v_def text; v_new text;
begin
  if to_regprocedure('public.dashboard_automation_set(text,boolean)') is null then return; end if;
  v_def := pg_get_functiondef('public.dashboard_automation_set(text,boolean)'::regprocedure);
  if v_def like '%auto_cancel%' then return; end if;
  v_new := replace(v_def,
    E'  else\n    return jsonb_build_object(\'ok\', false, \'error\', \'unknown_toggle\',',
    E'  elsif p_key = \'auto_cancel\' then\n'
    || E'    -- CMD #2053 — the ONE Auto cancel flag. The Dashboard pill and the pill\n'
    || E'    -- at the top of the Auto cancel screen are the same write.\n'
    || E'    insert into public.order_alert_config (id) values (\'singleton\')\n'
    || E'      on conflict (id) do nothing;\n'
    || E'    update public.order_alert_config\n'
    || E'       set cutoff_enabled = coalesce(p_on,false), updated_at = now(),\n'
    || E'           updated_by = coalesce(auth.uid()::text, updated_by)\n'
    || E'     where id = \'singleton\';\n'
    || E'    perform public.audit_write(\'order_alert_settings_set\',\'order_alert_config\',\'singleton\',\n'
    || E'              null, jsonb_build_object(\'cutoff_enabled\', coalesce(p_on,false)));\n'
    || E'    v_toast := case when coalesce(p_on,false)\n'
    || E'                    then public._c(\'admin_supplier.auto_cancel_toast_on\')\n'
    || E'                    else public._c(\'admin_supplier.auto_cancel_toast_off\') end;\n'
    || E'\n'
    || E'  else\n    return jsonb_build_object(\'ok\', false, \'error\', \'unknown_toggle\',');
  if v_new is distinct from v_def then
    execute v_new;
    raise notice 'CMD #2053: dashboard_automation_set() now writes cutoff_enabled';
  else
    raise exception 'CMD #2053: could not splice the auto_cancel branch into dashboard_automation_set()';
  end if;
end
$c2053_set$;

-- ── 5. The screen: one read, now carrying its own pill ──────────────────────
create or replace function public.order_cutoff_screen(p_zone smallint default null,
                                                      p_date date default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_settings jsonb; v_group jsonb; v_keys text[]; v_fields jsonb;
  v_console jsonb; v_never jsonb; v_audit jsonb; cfg public.order_alert_config;
  v_zone smallint; v_date date; v_on boolean;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  cfg    := public._oa_cfg();
  v_on   := coalesce(cfg.cutoff_enabled, false);
  v_zone := coalesce(public.partner_zone_id(), p_zone, public.admin_active_zone());
  v_date := coalesce(p_date, public.admin_active_date());

  -- The rule's own knobs — the cutoff group of the screen that already saves
  -- them. CMD #2053 drops two of them from the list: cutoff_enabled is the
  -- pill at the top of this screen (one flag, never a second control), and
  -- cutoff_pause_outside_hours is no longer a choice.
  v_settings := public.order_alert_settings();
  select g into v_group
    from jsonb_array_elements(coalesce(v_settings->'groups','[]'::jsonb)) g
   where g->>'key' = 'cutoff' limit 1;
  select coalesce(array_agg(x #>> '{}'), '{}'::text[]) into v_keys
    from jsonb_array_elements(coalesce(v_group->'fields','[]'::jsonb)) x
   where (x #>> '{}') not in ('cutoff_enabled','cutoff_pause_outside_hours');
  select coalesce(jsonb_agg(f order by ord), '[]'::jsonb) into v_fields
    from (select f, array_position(v_keys, f->>'key') ord
            from jsonb_array_elements(coalesce(v_settings->'fields','[]'::jsonb)) f
           where (f->>'key') = any(v_keys)) s;

  v_console := public.order_cutoff_console(v_zone, v_date);

  select coalesce(jsonb_agg(jsonb_build_object(
           'customer_id', pp.id,
           'name',        coalesce(nullif(btrim(pp.pharmacy_name),''),
                                   nullif(btrim(pp.customer_name),''), ''),
           'note',        coalesce(cc.note,''),
           'by_label',    coalesce(cc.updated_by,''),
           'remove_label',public.oa_label('cutoff_never_remove'))
           order by coalesce(nullif(btrim(pp.pharmacy_name),''), pp.customer_name)), '[]'::jsonb)
    into v_never
    from public.customer_credit cc
    join public.pharmacy_profiles pp on pp.id = cc.customer_id
   where cc.never_auto_cancel = true
     and coalesce(pp.is_deleted,false) = false
     and public.scope_zone_ok(pp.zone_id, v_zone);

  -- The audit the engine already writes. Order events are clamped to the zone
  -- and date on the picker; a settings change is global, so it always shows.
  select coalesce(jsonb_agg(public._order_cutoff_audit_row(a) order by a.at desc), '[]'::jsonb)
    into v_audit
    from (select l.* from public.audit_log l
           where l.action in ('order_alert_settings_set','customer_credit_set',
                              'order_cutoff_cancel','order_cutoff_hold',
                              'order_cutoff_restore','order_cutoff_extend',
                              'order_cutoff_extend_window','order_cutoff_cancel_now',
                              'order_cutoff_exempt','order_cutoff_unexempt',
                              'order_cutoff_pay_now')
             and (l.entity_type <> 'order'
                  or exists (select 1 from public.order_cutoff_run r
                              where r.order_id::text = l.entity_id
                                and r.cutoff_on = v_date
                                and (v_zone is null or r.zone_id = v_zone)))
           order by l.at desc limit 40) a;

  return jsonb_build_object(
    'ok', true,
    'title',        public.oa_label('cutoff_screen_title'),
    'subtitle',     public.oa_label('cutoff_screen_subtitle'),
    'zone_id',      v_zone,
    'date',         v_date,
    'date_label',   to_char(v_date,'DD/MM/YYYY'),
    'enabled',      v_on,
    -- CMD #2053 — the pill. Same shape as a Dashboard automation chip, same
    -- writer (dashboard_automation_set), same flag.
    'toggle',       public._dashboard_auto_cancel_chip()
                      || jsonb_build_object('note',
                           case when v_on then public.oa_label('cutoff_on_note')
                                else public.oa_label('cutoff_off_note') end),
    'off_note',     case when v_on then '' else public.oa_label('cutoff_off_note') end,
    'on_note',      case when v_on then public.oa_label('cutoff_on_note') else '' end,
    'saved_label',  public.oa_label('saved'),
    'sections',     jsonb_build_object(
                      'settings', public.oa_label('cutoff_sec_settings'),
                      'clock',    public.oa_label('cutoff_sec_clock'),
                      'never',    public.oa_label('cutoff_sec_never'),
                      'audit',    public.oa_label('cutoff_sec_audit')),
    'fields',       coalesce(v_fields,'[]'::jsonb),
    'clock',        v_console,
    'never',        jsonb_build_object(
                      'hint',         public.oa_label('cutoff_never_hint'),
                      'empty_label',  public.oa_label('cutoff_never_empty'),
                      'add_label',    public.oa_label('cutoff_never_add'),
                      'search_label', public.oa_label('cutoff_never_search'),
                      'items',        coalesce(v_never,'[]'::jsonb)),
    'audit',        jsonb_build_object(
                      'hint',        public.oa_label('cutoff_audit_hint'),
                      'empty_label', public.oa_label('cutoff_audit_empty'),
                      'items',       coalesce(v_audit,'[]'::jsonb)));
end $$;

comment on function public.order_cutoff_screen(smallint, date) is
  'CMD #1934 / #2053 — the whole Auto cancel screen in one read: the pill for the ONE flag (cutoff_enabled, written through dashboard_automation_set), the remaining knobs, the clock (order_cutoff_console), the never-auto-cancel pharmacies and the audit. Zone and date come from admin_active_zone()/admin_active_date().';

-- ── 6. Grants — a definer function is a public endpoint until it is revoked ──
do $c2053_grants$
declare r record;
begin
  for r in select p.oid::regprocedure::text as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('_dashboard_auto_cancel_chip','order_cutoff_screen',
                                'dashboard_automation_set','_dashboard_automation')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end
$c2053_grants$;

-- ── 7. The rg behaviour that opens the screen ───────────────────────────────
insert into public.rg_behavior_tests(name, body, enabled, note) values (
'cmd2053_auto_cancel_screen_opens',
$rg$
do $c2053rg$
declare v_bad text; v_j jsonb;
begin
  -- 1. The 42883 class: no function may hand a bare mode.order_alert row to a
  --    _oa_* function that takes public.order_alert. This is what killed the
  --    screen; the check is a PATTERN so a new caller cannot re-introduce it.
  select string_agg(distinct d.proname, ', ') into v_bad
    from (
      select p.proname, p.prosrc, m[1] as alias
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        cross join lateral regexp_matches(p.prosrc, 'from\s+mode\.order_alert\s+([a-z][a-z0-9_]*)', 'g') m
       where n.nspname = 'public'
         and m[1] not in ('where','order','group','limit','join','left','right',
                          'cross','on','union','having','offset','for','loop')
    ) d
   where d.prosrc ~ ('public\._oa_[a-z0-9_]+\(\s*' || d.alias || '\s*\)');
  if v_bad is not null then
    raise exception 'RG_FAIL: % passes a mode.order_alert row to a public.order_alert function — the Auto cancel screen will 42883', v_bad;
  end if;

  -- 2. The screen itself opens. Called with no admin session it must still
  --    RETURN (the refusal object), never raise.
  begin
    v_j := public.order_cutoff_screen(null, null);
  exception when others then
    raise exception 'RG_FAIL: order_cutoff_screen() raised % — %', sqlstate, sqlerrm;
  end;
  if v_j is null or not (v_j ? 'ok') then
    raise exception 'RG_FAIL: order_cutoff_screen() returned no ok field';
  end if;

  -- 3. And the read it depends on plans against the mode view.
  begin
    perform coalesce(jsonb_agg(public._oa_item(row(a.*)::public.order_alert)), '[]'::jsonb)
      from mode.order_alert a where a.state = 'ringing';
  exception
    when undefined_table then null;   -- mode views not built on this database
    when others then
      raise exception 'RG_FAIL: _oa_item over mode.order_alert raised % — %', sqlstate, sqlerrm;
  end;

  -- 4. ONE flag: cutoff_enabled and nothing beside it.
  if (select count(*) from information_schema.columns
       where table_schema='public' and table_name='order_alert_config'
         and column_name in ('auto_cancel_enabled','autocancel_enabled','cutoff_on')) > 0 then
    raise exception 'RG_FAIL: a second Auto cancel flag was added — cutoff_enabled is the only one';
  end if;

  -- 5. Both doors are the same writer, and the words exist.
  if to_regprocedure('public._dashboard_auto_cancel_chip()') is null then
    raise exception 'RG_FAIL: the Auto cancel pill builder is missing';
  end if;
  if coalesce(public.oa_label('cutoff_off_note'),'') = ''
     or coalesce(public.oa_label('cutoff_on_note'),'') = ''
     or coalesce(public.oa_label('cutoff_toggle_label'),'') = '' then
    raise exception 'RG_FAIL: an Auto cancel label is empty — the screen would print nothing';
  end if;

  -- 6. OFF means the tick does nothing.
  if position('skipped' in pg_get_functiondef('public.order_cutoff_tick()'::regprocedure)) = 0 then
    raise exception 'RG_FAIL: order_cutoff_tick() no longer short-circuits when Auto cancel is off';
  end if;

  raise exception 'RG_ROLLBACK';
end
$c2053rg$;
$rg$,
true,
'CMD #2053 — opens the Auto cancel screen and pins the 42883 class that killed it: a mode.order_alert row handed to a public.order_alert function. Also pins one-flag-only and OFF = the tick does nothing.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;
