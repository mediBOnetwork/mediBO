-- CMD #1929 (7/9) — the one RPC the Payment alerts screen renders.
--
-- Zone- and date-scoped through admin_active_zone() / admin_active_date():
-- a partner is locked to their own zone, a super admin with no zone chosen
-- sees every zone. Zone and date live in the header picker and NOWHERE else —
-- this RPC takes neither as a parameter, on purpose.

create or replace function public.payment_alerts_screen(
  p_status text default null, p_limit int default 60)
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
    -- The chip's whole caption is built here: Dart must not join a label to
    -- a count, or the wording of that join stops being an UPDATE.
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
    'rows',          coalesce(v_rows,'[]'::jsonb));
end $$;

-- An unmatched alert an admin recognises: re-run the matcher, or set it aside.
create or replace function public.payment_alert_set_status(p_alert_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  if p_status not in ('new','unmatched','ignored') then
    return jsonb_build_object('ok', false, 'error','bad_status');
  end if;
  update public.payment_alerts
     set status = p_status, match_reason = null, updated_at = now()
   where id = p_alert_id and status <> 'matched';   -- a verified payment is not undone here
  if p_status = 'new' then perform public.payment_alert_match(p_alert_id); end if;
  return public.payment_alert_state(p_alert_id);
end $$;

grant execute on function public.payment_alerts_screen(text, int) to authenticated;
grant execute on function public.payment_alert_set_status(uuid, text) to authenticated;
