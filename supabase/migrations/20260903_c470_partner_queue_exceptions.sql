-- CHANGE #470 — the partner work-queue home (#398) carries the zone's own
-- exceptions. Same source as the admin console, same words, same routes.

insert into public.ui_copy (key, value) values
  ('exc.open_all', '"Open the queue"'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

CREATE OR REPLACE FUNCTION public.partner_work_queue(p_limit integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pid   bigint := public.my_partner_id();
  v_zone  smallint;
  v_copy  jsonb := coalesce((select value from app_settings where key='partner_queue_copy'),'{}'::jsonb);
  v_lim   int := greatest(least(coalesce(p_limit,5), 25), 1);
  v_date  date := (now() at time zone 'Asia/Kolkata')::date;
  v_zname text;
  v_stages jsonb := '[]'::jsonb;
  v_total  int := 0;
  v_recv int := 0; v_deliv int := 0;
  -- CHANGE #470 — the zone's own exception queue, on the home the partner
  -- already opens. Counts and words are the exception layer's, never Dart's.
  v_exc      jsonb := '[]'::jsonb;
  v_exc_n    int   := 0;
  v_exc_late int   := 0;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'is_partner', false,
      'message', coalesce(v_copy->>'not_partner_message',''));
  end if;
  v_zone := public.partner_zone_id();
  select z.name into v_zname from zones z where z.id = v_zone;

  with live as (
    select o.id, o.order_code, o.status, o.created_at, o.total_amount,
           coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(pp.customer_name),''),
                    nullif(btrim(o.pharmacy_name),''), '') as customer
      from orders o
      left join pharmacy_profiles pp on pp.id = o.customer_id
     where o.status <> 'cancelled'
       and o.closed_at is null
       and coalesce(o.zone_id, pp.zone_id) = v_zone
  ), item as (
    select oi.order_id,
           count(*) as n_live,
           count(*) filter (where oi.assigned_supplier is null) as n_unassigned,
           count(*) filter (where oi.assigned_supplier is not null
                              and not exists (select 1 from supplier_orders so
                                               where so.order_id = oi.order_id
                                                 and btrim(lower(so.supplier_name))
                                                   = btrim(lower(oi.assigned_supplier)))) as n_no_po,
           count(*) filter (where oi.assigned_supplier is not null
                              and coalesce(oi.collect_locked,false) = false) as n_uncollected,
           count(*) filter (where coalesce(oi.collect_locked,false)
                              and oi.wh_recount_qty is null) as n_uncounted,
           count(*) filter (where oi.wh_recount_qty is not null
                              and not exists (select 1 from bag_allocations ba
                                               where ba.order_item_id = oi.id)) as n_unbagged,
           count(*) filter (where coalesce(oi.packed,false) = false) as n_unpacked
      from order_items oi
      join live l on l.id = oi.order_id
     where coalesce(oi.status,'') <> 'cancelled'
       and coalesce(oi.unfulfillable,false) = false
     group by oi.order_id
  ), staged as (
    select l.id as order_id, coalesce(l.order_code,'') as order_code, l.customer,
           coalesce(l.total_amount,0) as amount, l.created_at,
           case
             when l.status = 'pending'                 then 'received'
             when coalesce(i.n_live,0) = 0             then null
             when i.n_unassigned  > 0                  then 'inquiry'
             when i.n_no_po       > 0                  then 'supplier_order'
             when i.n_uncollected > 0                  then 'collect'
             when i.n_uncounted   > 0                  then 'count'
             when i.n_unbagged    > 0                  then 'bag'
             when i.n_unpacked    > 0                  then 'pack'
             when not exists (select 1 from deliveries d where d.order_id = l.id)
                                                       then 'assign_delivery'
             else null
           end as stage_key
      from live l left join item i on i.order_id = l.id
  ), stage as (
    select s.* from partner_queue_stage s
     where s.is_active
       and (s.feature_key is null or public.partner_access(s.feature_key, v_pid) <> 'none')
  ), per as (
    select st.sort_order, st.stage_key, st.label, st.tone, st.feature_key, st.next_action,
           (select count(*) from staged q where q.stage_key = st.stage_key)::int as n,
           coalesce((select jsonb_agg(jsonb_build_object(
                        'order_id',       q.order_id::text,
                        'order_code',     q.order_code,
                        'customer',       q.customer,
                        'amount_display', public.inr_money(q.amount),
                        'age_label',      public.ops_age_label(q.created_at),
                        'next_action',    st.next_action) order by q.created_at)
                      from (select * from staged q2
                             where q2.stage_key = st.stage_key
                             order by q2.created_at limit v_lim) q),
                    '[]'::jsonb) as rows
      from stage st
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'stage_key',   p.stage_key,
           'label',       p.label,
           'tone',        p.tone,
           'feature_key', coalesce(p.feature_key,''),
           'next_action', p.next_action,
           'count',       p.n,
           'count_label', case when p.n = 1
                               then replace(coalesce(v_copy->>'count_one',''), '{n}', p.n::text)
                               else replace(coalesce(v_copy->>'count_many',''),'{n}', p.n::text) end,
           'has_any',     p.n > 0,
           'can_open',    true,
           'open_label',  coalesce(v_copy->>'open_label',''),
           'more_count',  greatest(p.n - v_lim, 0),
           'more_label',  case when p.n > v_lim
                               then replace(coalesce(v_copy->>'more_label',''),'{n}',(p.n - v_lim)::text)
                               else '' end,
           'orders',      p.rows) order by p.sort_order), '[]'::jsonb),
         coalesce(sum(p.n),0)::int
    into v_stages, v_total
    from per p;

  select count(*) into v_recv
    from orders o left join pharmacy_profiles pp on pp.id = o.customer_id
   where coalesce(o.zone_id, pp.zone_id) = v_zone
     and (o.created_at at time zone 'Asia/Kolkata')::date = v_date;

  select count(*) into v_deliv
    from deliveries d join orders o on o.id = d.order_id
    left join pharmacy_profiles pp on pp.id = o.customer_id
   where coalesce(d.zone_id, o.zone_id, pp.zone_id) = v_zone
     and coalesce(lower(d.status),'') in ('delivered','completed')
     and (coalesce(d.delivered_at, d.created_at) at time zone 'Asia/Kolkata')::date = v_date;

  -- CHANGE #470 — the zone's stuck things, read from the SAME source the
  -- admin console reads, so the two surfaces can never disagree about what is
  -- open. Five rows and a count; the full queue is one tap away.
  with base as (
    select r.reason_code, r.ref_id, r.title, r.subtitle, r.since, r.action_ref,
           coalesce(nullif(r.stage_key,''), nullif(x.stage_key,'')) as stage_key,
           x.severity, x.sla_hours, x.action_route,
           (extract(epoch from (now() - r.since)) / 3600.0)::numeric as age_hours
      from public._exception_rows() r
      join public.exception_reason x
        on x.reason_code = r.reason_code and x.enabled
      left join public.exception_state s
        on s.reason_code = r.reason_code and s.ref_id = r.ref_id
     where coalesce(s.status,'open') <> 'closed'
       and r.zone_id = v_zone
  )
  select coalesce(jsonb_agg(j.js order by j.sort_score desc, j.since asc), '[]'::jsonb),
         (select count(*)::int from base),
         (select count(*)::int from base where age_hours > sla_hours)
    into v_exc, v_exc_n, v_exc_late
    from (
      select b.since, (b.age_hours * b.severity) as sort_score,
             jsonb_build_object(
               'id',           b.reason_code || ':' || b.ref_id,
               'reason_code',  b.reason_code,
               'reason_label', public._c('exc.reason.' || b.reason_code),
               'title',        b.title,
               'subtitle',     b.subtitle,
               'stage_chip',   case when coalesce(b.stage_key,'') = ''
                                    then public._c('exc.stage_none')
                                    else public._cf('exc.stage_prefix', jsonb_build_object(
                                           'stage', coalesce((select st.label from public.sla_stage st
                                                               where st.stage_key = b.stage_key),
                                                             b.stage_key))) end,
               'age_label',    public._cf('exc.age', jsonb_build_object(
                                 'age', public.ops_age_label(b.since))),
               'tone',         case when b.age_hours <= b.sla_hours then 'info'
                                    when b.severity >= 5 then 'bad'
                                    when b.age_hours > b.sla_hours * 3 then 'bad'
                                    else 'warn' end,
               'action_label', public._c('exc.action.' || b.reason_code),
               'route',        coalesce(nullif(b.action_route,''),
                                 (select m.route from public.exception_route_map m
                                   where m.class_key = b.action_ref),
                                 (select c.action_route from public.ops_board_class c
                                   where c.key = b.action_ref), '')) as js
        from base b
       order by (b.age_hours * b.severity) desc, b.since asc
       limit v_lim) j;

  return jsonb_build_object(
    'ok', true, 'is_partner', true,
    'exceptions', jsonb_build_object(
      'has',         v_exc_n > 0,
      'count',       v_exc_n,
      'late_count',  v_exc_late,
      'label',       public._c('exc.title'),
      'count_label', case when v_exc_n = 0 then public._c('exc.clean')
                          when v_exc_n = 1 then public._c('exc.count_one')
                          else public._cf('exc.count_many',
                                 jsonb_build_object('n', v_exc_n::text)) end,
      'tone',        case when v_exc_n = 0 then 'good'
                          when v_exc_late > 0 then 'bad' else 'warn' end,
      'open_label',  public._c('exc.open_all'),
      'route',       'exceptions',
      'empty_label', public._c('exc.empty'),
      'rows',        v_exc),
    'partner_id', v_pid,
    'zone_id', v_zone,
    'zone_label', coalesce(v_zname,''),
    'show_zone_picker', false,
    'title',    coalesce(v_copy->>'title',''),
    'subtitle', coalesce(v_copy->>'subtitle',''),
    'today_label', replace(replace(coalesce(v_copy->>'today_label',''),
                     '{received}', v_recv::text), '{delivered}', v_deliv::text),
    'total',       v_total,
    'total_label', replace(coalesce(v_copy->>'total_label',''), '{n}', v_total::text),
    'has_any',     v_total > 0,
    'empty_title',   coalesce(v_copy->>'empty_title',''),
    'empty_message', coalesce(v_copy->>'empty_message',''),
    'stages', v_stages);
end $function$

;
