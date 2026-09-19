-- CMD #2093 (c) — the Payment alerts screen payload grows three blocks:
-- the app picker, the "Look for UTR" switch and the collection-mode header.
-- All three are rendered verbatim; none of them is computed in Dart.

insert into public.ui_copy(key, value) values
  ('pay_alert.mode_manual',  to_jsonb('Manual UPI'::text)),
  ('pay_alert.mode_gateway', to_jsonb('Payment gateway'::text))
on conflict (key) do nothing;

-- ── 1. The UTR switch ───────────────────────────────────────────────────────
create or replace function public.payment_alert_utr_set(p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.apps_denied',
                            'Only an admin can change which apps are listened to.'));
  end if;
  insert into public.payment_listener_config (id) values (true) on conflict (id) do nothing;
  update public.payment_listener_config
     set look_for_utr = coalesce(p_on, true), updated_at = now()
   where id;
  return jsonb_build_object('ok', true,
    'toast', public.uic('pay_alert.utr_saved','Saved.'),
    'look_for_utr', coalesce(p_on, true));
end $$;

grant execute on function public.payment_alert_utr_set(boolean) to authenticated;

-- ── 2. Turning ONE app on or off ────────────────────────────────────────────
-- Still payment_alert_rule_save, still the same patch shape. The only change
-- is who may send the on/off half of it: switching an app off is an everyday
-- operational call, editing a regex is not.
create or replace function public.payment_alert_rule_save(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_id bigint := nullif(p_patch->>'id','')::bigint;
  v_pkg text := btrim(coalesce(p_patch->>'package_name',''));
  v_lab text := btrim(coalesce(p_patch->>'label',''));
  v_amt text := btrim(coalesce(p_patch->>'amount_regex',''));
  v_role text := coalesce(public.get_my_role(),'');
  v_toggle boolean := (v_id is not null and p_patch ? 'enabled'
                       and not (p_patch ? 'package_name'));
  k text; v text;
begin
  if v_toggle then
    if v_role not in ('admin','super_admin') then
      return jsonb_build_object('ok', false, 'error','not_authorized',
        'message', public.uic('pay_alert.apps_denied',
                              'Only an admin can change which apps are listened to.'));
    end if;
    update public.payment_alert_rules
       set enabled = (p_patch->>'enabled')::boolean, updated_at = now()
     where id = v_id;
    -- A super admin gets the parser screen back, as it always did. An admin
    -- gets an acknowledgement; the alerts screen reloads itself.
    return (case when v_role = 'super_admin'
                 then public.payment_alert_rules_screen() else '{}'::jsonb end)
           || jsonb_build_object('ok', true,
                                 'toast', public.uic('pay_rule.saved','Rule saved.'),
                                 'saved_id', v_id);
  end if;

  if v_role <> 'super_admin' then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_rule.denied',
                            'Only a super admin can edit the payment parser.'));
  end if;

  if v_pkg = '' or v_lab = '' or v_amt = '' then
    return jsonb_build_object('ok', false, 'error','incomplete',
      'message', public.uic('pay_rule.incomplete',
                            'A rule needs a name, an app package and an amount pattern.'));
  end if;

  foreach k in array array['amount_regex','utr_regex','vpa_regex','sender_regex','ignore_regex'] loop
    v := btrim(coalesce(p_patch->>k,''));
    if v <> '' then
      begin
        perform 'probe' ~* v;
      exception when others then
        return jsonb_build_object('ok', false, 'error','bad_regex', 'field', k,
          'message', replace(public.uic('pay_rule.bad_regex','{f} is not a valid pattern.'),
                             '{f}', k));
      end;
    end if;
  end loop;

  if v_id is null then
    insert into public.payment_alert_rules
      (package_name, label, amount_regex, utr_regex, vpa_regex, sender_regex,
       ignore_regex, priority, enabled, note, updated_at)
    values (v_pkg, v_lab, v_amt,
            nullif(btrim(coalesce(p_patch->>'utr_regex','')),''),
            nullif(btrim(coalesce(p_patch->>'vpa_regex','')),''),
            nullif(btrim(coalesce(p_patch->>'sender_regex','')),''),
            nullif(btrim(coalesce(p_patch->>'ignore_regex','')),''),
            coalesce(nullif(p_patch->>'priority','')::int, 100),
            coalesce((p_patch->>'enabled')::boolean, true),
            nullif(btrim(coalesce(p_patch->>'note','')),''), now())
    returning id into v_id;
  else
    update public.payment_alert_rules
       set package_name = v_pkg, label = v_lab, amount_regex = v_amt,
           utr_regex    = nullif(btrim(coalesce(p_patch->>'utr_regex','')),''),
           vpa_regex    = nullif(btrim(coalesce(p_patch->>'vpa_regex','')),''),
           sender_regex = nullif(btrim(coalesce(p_patch->>'sender_regex','')),''),
           ignore_regex = nullif(btrim(coalesce(p_patch->>'ignore_regex','')),''),
           priority     = coalesce(nullif(p_patch->>'priority','')::int, priority),
           enabled      = coalesce((p_patch->>'enabled')::boolean, enabled),
           note         = nullif(btrim(coalesce(p_patch->>'note','')),''),
           updated_at   = now()
     where id = v_id;
  end if;

  return public.payment_alert_rules_screen()
         || jsonb_build_object('toast', public.uic('pay_rule.saved','Rule saved.'),
                               'saved_id', v_id);
end $$;

-- ── 3. The blocks the screen draws ──────────────────────────────────────────
-- One helper, so the alerts screen and any later surface print the same words.
create or replace function public._pa_apps_block()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_rows jsonb; v_n int; v_on int; v_can boolean;
begin
  v_can := coalesce(public.get_my_role(),'') in ('admin','super_admin');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            r.id,
           'label',         coalesce(nullif(btrim(r.label),''), r.package_name),
           'package_name',  r.package_name,
           'kind',          coalesce(r.app_kind,'consumer'),
           'kind_label',    public.uic('pay_alert.kind.'||coalesce(r.app_kind,'consumer'),
                                       coalesce(r.app_kind,'consumer')),
           'enabled',       r.enabled,
           'state_label',   case when r.enabled then public.uic('pay_alert.app_on','On')
                                                else public.uic('pay_alert.app_off','Off') end,
           'state_tone',    case when r.enabled then 'success' else 'muted' end,
           'can_edit',      v_can)
         -- Business first, then banks, then the personal apps that announce
         -- ads and chats. The order is the backend's, never a Dart sort.
         order by case coalesce(r.app_kind,'consumer')
                    when 'business' then 0 when 'bank' then 1 else 2 end,
                  r.priority, lower(coalesce(r.label, r.package_name))), '[]'::jsonb),
       count(*)::int, count(*) filter (where r.enabled)::int
    into v_rows, v_n, v_on
  from public.payment_alert_rules r
  -- The '*' catch-all is not an app and is never offered as one.
  where r.package_name <> '*';

  return jsonb_build_object(
    'title',       public.uic('pay_alert.apps_title','Which apps to listen to'),
    'hint',        public.uic('pay_alert.apps_hint',''),
    'empty_label', public.uic('pay_alert.apps_empty','No payment apps configured yet.'),
    'count_label', replace(replace(
                     public.uic('pay_alert.apps_count_tpl','{on} of {n} apps on'),
                     '{on}', coalesce(v_on,0)::text), '{n}', coalesce(v_n,0)::text),
    'can_edit',    v_can,
    'rows',        coalesce(v_rows,'[]'::jsonb));
end $$;

create or replace function public._pa_utr_block()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_on boolean;
begin
  select coalesce(c.look_for_utr, true) into v_on
    from public.payment_listener_config c where c.id;
  v_on := coalesce(v_on, true);
  return jsonb_build_object(
    'title', public.uic('pay_alert.utr_title','Look for UTR'),
    'on',    v_on,
    'hint',  case when v_on then public.uic('pay_alert.utr_hint_on','')
                            else public.uic('pay_alert.utr_hint_off','') end,
    'can_edit', coalesce(public.get_my_role(),'') in ('admin','super_admin'));
end $$;

create or replace function public._pa_header_block()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_mode text; v_vpa text; v_name text;
begin
  v_mode := public.payment_collection_mode();
  select a.pa, a.pn into v_vpa, v_name
    from public.payment_upi_accounts a where a.is_active limit 1;
  return jsonb_build_object(
    'title',      public.uic('pay_alert.header_title','How money is collected'),
    -- The mode's own words, from the same copy the Money screen prints; the
    -- uic fallback is there so a database that has not seen the Razorpay copy
    -- still names the mode instead of showing a blank chip.
    'mode_label', case when v_mode = 'gateway'
                       then coalesce(nullif(public._rzp_copy('mode_gateway_label'),''),
                                     public.uic('pay_alert.mode_gateway','Payment gateway'))
                       else coalesce(nullif(public._rzp_copy('mode_manual_label'),''),
                                     public.uic('pay_alert.mode_manual','Manual UPI')) end,
    'mode_tone',  case when v_mode = 'gateway' then 'info' else 'success' end,
    'upi_label',  public.uic('pay_alert.header_upi','UPI ID'),
    'upi_value',  coalesce(nullif(btrim(coalesce(v_vpa,'')),''),
                           public.uic('pay_alert.header_upi_none','No UPI ID is active')),
    'upi_name',   coalesce(nullif(btrim(coalesce(v_name,'')),''), ''),
    'has_upi',    nullif(btrim(coalesce(v_vpa,'')),'') is not null);
end $$;

-- ── 4. The screen ───────────────────────────────────────────────────────────
create or replace function public.payment_alerts_screen(p_status text DEFAULT NULL,
                                                        p_limit integer DEFAULT 60)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_role  text := coalesce(public.get_my_role(),'');
  v_part  boolean := coalesce(public.is_partner(), false);
  v_zone  smallint;
  v_date  date;
  v_rows  jsonb;
  v_counts jsonb;
  v_total int;
  v_lim   int := least(greatest(coalesce(p_limit,60),1), 200);
  v_status text := nullif(btrim(lower(coalesce(p_status,''))),'');
begin
  if auth.uid() is null or not (v_part or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('pay_alert.screen_denied',
                            'Payment alerts are visible to a partner or an admin.'));
  end if;
  if v_status is not null and v_status not in ('new','matched','unmatched','ignored') then
    v_status := null;
  end if;

  v_zone := public.admin_active_zone();     -- NULL = every zone (super admin)
  v_date := public.admin_active_date();

  -- Newest first, and said twice on purpose: the inner window picks the newest
  -- v_lim rows, the aggregate keeps them in that order.
  select coalesce(jsonb_agg(public.payment_alert_state(x.id) order by x.posted_at desc), '[]'::jsonb),
         count(*)::int
    into v_rows, v_total
  from (
    select a.id, a.posted_at from public.payment_alerts a
     where (v_zone is null or a.zone_id = v_zone)
       and (v_date is null or a.business_date = v_date)
       and (v_status is null or a.status = v_status)
     order by a.posted_at desc
     limit v_lim
  ) x;

  select coalesce(jsonb_object_agg(s, n), '{}'::jsonb) into v_counts
    from (select a.status as s, count(*)::int as n from public.payment_alerts a
           where (v_zone is null or a.zone_id = v_zone)
             and (v_date is null or a.business_date = v_date)
           group by a.status) q;

  return jsonb_build_object(
    'ok', true,
    'title',        public.uic('pay_alert.title','Payment alerts'),
    'subtitle',     public.uic('pay_alert.subtitle',
                      'Payment notifications forwarded from the partner phone'),
    'empty_label',  public.uic('pay_alert.empty',
                      'No payment notifications for this zone and date yet.'),
    'empty_hint',   public.uic('pay_alert.empty_hint',
                      'Alerts appear here the moment the partner phone forwards one.'),
    'retry_label',  public.uic('pay_alert.error_retry','Retry'),
    'count_label',  case
                      when v_total = 0 then public.uic('pay_alert.count_zero','No alerts')
                      when v_total = 1 then public.uic('pay_alert.count_one','1 alert')
                      else replace(public.uic('pay_alert.count_tpl','{n} alerts'),
                                   '{n}', v_total::text) end,
    'filters',      (select jsonb_agg(jsonb_build_object(
                        'key',   f.key,
                        'label', f.label,
                        'count', f.n,
                        'chip_label', replace(replace(
                           public.uic('pay_alert.filter.chip_tpl','{label} {count}'),
                           '{label}', f.label), '{count}', f.n::text))
                       order by f.ord)
                     from (
                       select 0 as ord, '' as key,
                              public.uic('pay_alert.filter.all','All') as label,
                              (select coalesce(sum((value)::int),0) from jsonb_each_text(v_counts)) as n
                       union all select 1, 'new',       public.uic('pay_alert.status.new','New'),           coalesce((v_counts->>'new')::int,0)
                       union all select 2, 'matched',   public.uic('pay_alert.status.matched','Matched'),   coalesce((v_counts->>'matched')::int,0)
                       union all select 3, 'unmatched', public.uic('pay_alert.status.unmatched','Needs a look'), coalesce((v_counts->>'unmatched')::int,0)
                       union all select 4, 'ignored',   public.uic('pay_alert.status.ignored','Ignored'),   coalesce((v_counts->>'ignored')::int,0)
                     ) f),
    'active_filter', coalesce(v_status,''),
    'zone_id',       v_zone,
    'date',          v_date,
    'header',        public._pa_header_block(),
    'utr',           public._pa_utr_block(),
    'apps',          public._pa_apps_block(),
    'rows',          coalesce(v_rows,'[]'::jsonb));
end $$;
