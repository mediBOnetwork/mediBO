-- CHANGE #709 (5/6) — the rate, and the moment it becomes somebody's problem.
--
-- Three cuts of the same ledger — by worker, by supplier, by product — each as
-- a RATE, because a count on its own punishes whoever handled the most stock.
-- The denominator is what that worker/supplier/product actually passed through
-- our hands in the window, taken from the order lines themselves.
--
-- Above the configured rate (and only past a floor of events, so one unlucky
-- order is never a verdict) it becomes a row on the exceptions console (#690)
-- through the SAME source function every other exception comes from.
-- Idempotent throughout.

create or replace function public.damage_report(p_days integer default 30,
                                                p_zone smallint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_zone smallint;
  v_days int := least(greatest(coalesce(p_days,30),1), 365);
  v_from timestamptz;
  v_cfg jsonb := coalesce((select value from app_settings where key='handling_damage'),'{}'::jsonb);
  v_workers jsonb; v_suppliers jsonb; v_products jsonb; v_queue jsonb;
  v_total_qty numeric := 0; v_total_n int := 0; v_amount numeric := 0;
begin
  if v_partner is not null then
    if coalesce(public.partner_access('partner.fulfil_tasks', v_partner),'none') = 'none' then
      return jsonb_build_object('ok', false, 'error','not_authorized',
        'title', _c('damage.report_title'), 'message', _c('damage.err_not_authorized'));
    end if;
    v_zone := public.partner_zone_id();
  elsif v_role in ('admin','super_admin') then
    v_zone := coalesce(p_zone, public.admin_active_zone());
  else
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', _c('damage.report_title'), 'message', _c('damage.err_not_authorized'));
  end if;

  v_from := now() - make_interval(days => v_days);

  select coalesce(sum(qty),0), count(*)::int, coalesce(sum(coalesce(amount,0)),0)
    into v_total_qty, v_total_n, v_amount
    from handling_damage
   where status = 'confirmed' and logged_at >= v_from
     and (v_zone is null or zone_id = v_zone);

  -- by worker: damaged units over units that worker's tasks touched
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.worker_label, 'label', x.worker_label,
           'reports', x.n, 'qty', x.qty,
           'handled', x.handled,
           'pct', x.pct,
           'rate_label', _cf('damage.rate_label',
                          jsonb_build_object('pct', to_char(x.pct,'FM990.9'))),
           'summary', _cf('damage.qty_summary', jsonb_build_object(
                        'qty', rtrim(rtrim(to_char(x.qty,'FM999999990.99'),'0'),'.'),
                        'n', x.n::text)),
           'amount_display', public.inr_money(x.amount),
           'tone', case when x.pct >= coalesce((v_cfg->>'rate_threshold_pct')::numeric, 2.0)
                        then 'danger' else 'neutral' end)
         order by x.pct desc, x.qty desc), '[]'::jsonb)
    into v_workers
    from (
      select coalesce(nullif(d.worker_label,''), _c('damage.none_label')) as worker_label,
             count(*)::int as n, sum(d.qty) as qty, sum(coalesce(d.amount,0)) as amount,
             coalesce((select sum(t.qty_handled) from fulfil_task t
                        where t.worker_id = d.worker_id
                          and t.assigned_at >= v_from), 0) as handled,
             round(100.0 * sum(d.qty)
                   / nullif(coalesce((select sum(t.qty_handled) from fulfil_task t
                                       where t.worker_id = d.worker_id
                                         and t.assigned_at >= v_from), 0), 0), 1) as pct
        from handling_damage d
       where d.status = 'confirmed' and d.logged_at >= v_from
         and (v_zone is null or d.zone_id = v_zone)
       group by d.worker_id, coalesce(nullif(d.worker_label,''), _c('damage.none_label'))) x;

  -- by supplier: damaged units over units that supplier delivered in the window
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.supplier, 'label', x.supplier,
           'reports', x.n, 'qty', x.qty, 'handled', x.handled, 'pct', x.pct,
           'rate_label', _cf('damage.rate_label',
                          jsonb_build_object('pct', to_char(coalesce(x.pct,0),'FM990.9'))),
           'summary', _cf('damage.qty_summary', jsonb_build_object(
                        'qty', rtrim(rtrim(to_char(x.qty,'FM999999990.99'),'0'),'.'),
                        'n', x.n::text)),
           'amount_display', public.inr_money(x.amount),
           'tone', case when coalesce(x.pct,0) >= coalesce((v_cfg->>'rate_threshold_pct')::numeric, 2.0)
                        then 'danger' else 'neutral' end)
         order by x.pct desc nulls last, x.qty desc), '[]'::jsonb)
    into v_suppliers
    from (
      select coalesce(nullif(d.supplier_name,''), _c('damage.none_label')) as supplier,
             count(*)::int as n, sum(d.qty) as qty, sum(coalesce(d.amount,0)) as amount,
             coalesce((select sum(oi.quantity) from order_items oi
                        where oi.assigned_supplier = d.supplier_name
                          and oi.created_at >= v_from), 0) as handled,
             round(100.0 * sum(d.qty)
                   / nullif(coalesce((select sum(oi.quantity) from order_items oi
                                       where oi.assigned_supplier = d.supplier_name
                                         and oi.created_at >= v_from), 0), 0), 1) as pct
        from handling_damage d
       where d.status = 'confirmed' and d.logged_at >= v_from
         and (v_zone is null or d.zone_id = v_zone)
       group by d.supplier_name, coalesce(nullif(d.supplier_name,''), _c('damage.none_label'))) x;

  -- by product
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.product_id, 'label', x.product_name,
           'reports', x.n, 'qty', x.qty,
           'summary', _cf('damage.qty_summary', jsonb_build_object(
                        'qty', rtrim(rtrim(to_char(x.qty,'FM999999990.99'),'0'),'.'),
                        'n', x.n::text)),
           'amount_display', public.inr_money(x.amount),
           'tone', 'neutral')
         order by x.qty desc), '[]'::jsonb)
    into v_products
    from (
      select d.product_id, coalesce(nullif(d.product_name,''), _c('damage.none_label')) as product_name,
             count(*)::int as n, sum(d.qty) as qty, sum(coalesce(d.amount,0)) as amount
        from handling_damage d
       where d.status = 'confirmed' and d.logged_at >= v_from
         and (v_zone is null or d.zone_id = v_zone)
       group by d.product_id, coalesce(nullif(d.product_name,''), _c('damage.none_label'))) x;

  -- what is still waiting for a partner's word
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'order_id', d.order_id,
           'order_code', coalesce(o.order_code,''),
           'product_name', coalesce(d.product_name,''),
           'qty', d.qty, 'reason', d.reason_label,
           'stage_label', coalesce(s.label, d.stage_key),
           'worker_label', coalesce(d.worker_label,''),
           'note', coalesce(d.note,''),
           'has_photo', (nullif(btrim(coalesce(d.photo_path,'')),'') is not null),
           'photo_bucket', coalesce(d.photo_bucket,''),
           'photo_path', coalesce(d.photo_path,''),
           'confirm_label', _c('damage.confirm'),
           'reject_label', _c('damage.reject'),
           'logged_at', d.logged_at)
         order by d.logged_at), '[]'::jsonb)
    into v_queue
    from handling_damage d
    left join orders o on o.id = d.order_id
    left join handling_damage_stage s on s.stage_key = d.stage_key
   where d.status = 'pending'
     and (v_zone is null or d.zone_id = v_zone);

  return jsonb_build_object(
    'ok', true,
    'title', _c('damage.report_title'),
    'empty_note', _c('damage.report_empty'),
    'window_days', v_days,
    'zone_id', v_zone,
    'threshold_pct', coalesce((v_cfg->>'rate_threshold_pct')::numeric, 2.0),
    'total_qty', v_total_qty,
    'total_reports', v_total_n,
    'total_amount_display', public.inr_money(v_amount),
    'summary', _cf('damage.qty_summary', jsonb_build_object(
                 'qty', rtrim(rtrim(to_char(v_total_qty,'FM999999990.99'),'0'),'.'),
                 'n', v_total_n::text)),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','queue',    'label', _c('damage.tab_queue'),
                         'count', jsonb_array_length(v_queue)),
      jsonb_build_object('key','worker',   'label', _c('damage.tab_worker'),
                         'count', jsonb_array_length(v_workers)),
      jsonb_build_object('key','supplier', 'label', _c('damage.tab_supplier'),
                         'count', jsonb_array_length(v_suppliers)),
      jsonb_build_object('key','product',  'label', _c('damage.tab_product'),
                         'count', jsonb_array_length(v_products))),
    'queue', v_queue,
    'worker', v_workers,
    'supplier', v_suppliers,
    'product', v_products);
end
$fn$;

revoke all on function public.damage_report(integer,smallint) from public, anon, authenticated;
grant execute on function public.damage_report(integer,smallint) to authenticated;

-- ── the exceptions console row ───────────────────────────────────────────
insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind,
   action_route, sort_rank, enabled)
select 'damage_rate_high', 'handling_damage', 3, 48, 'zone', 'route', 'damage_report',
       55, true
where not exists (select 1 from public.exception_reason where reason_code = 'damage_rate_high');

insert into public.ui_copy (key, value) values
  ('exc.reason.damage_rate_high', to_jsonb('Damage rate above threshold'::text))
on conflict (key) do nothing;

-- The source function every exception row comes from gains one branch: a
-- worker whose damage rate is above the configured threshold, and only once
-- enough events have happened for the rate to mean anything.
do $do$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = '_exception_rows';
  if v_def is not null and v_def not like '%handling_damage%' then
    v_new := replace(v_def,
      '  -- 1. Disputes nobody resolved.',
      '  -- 0. CHANGE #709 — a worker breaking more than the threshold. A RATE,
  -- past a floor of events, so one unlucky order is never a verdict.
  select ''damage_rate_high''::text, ''worker:''||coalesce(d.worker_id::text,''-''),
         d.zone_id,
         coalesce(nullif(d.worker_label,''''), ''—''),
         public._cf(''damage.rate_label'',
           jsonb_build_object(''pct'', to_char(d.pct, ''FM990.9''))),
         d.last_at,
         null::text,
         coalesce(d.worker_id::text, ''-'')
    from (
      select h.worker_id,
             max(h.worker_label) as worker_label,
             max(h.zone_id) as zone_id,
             max(h.logged_at) as last_at,
             count(*)::int as n,
             round(100.0 * sum(h.qty)
                   / nullif(coalesce((select sum(t.qty_handled) from public.fulfil_task t
                                       where t.worker_id = h.worker_id
                                         and t.assigned_at >= now() - make_interval(days =>
                                             coalesce((select (value->>''window_days'')::int
                                                         from public.app_settings
                                                        where key=''handling_damage''), 30))), 0), 0), 1) as pct
        from public.handling_damage h
       where h.status = ''confirmed''
         and h.worker_id is not null
         and h.logged_at >= now() - make_interval(days =>
               coalesce((select (value->>''window_days'')::int from public.app_settings
                          where key=''handling_damage''), 30))
       group by h.worker_id) d
   where d.pct is not null
     and d.n >= coalesce((select (value->>''min_events'')::int from public.app_settings
                           where key=''handling_damage''), 3)
     and d.pct >= coalesce((select (value->>''rate_threshold_pct'')::numeric
                              from public.app_settings where key=''handling_damage''), 2.0)

  union all
  -- 1. Disputes nobody resolved.');
    if v_new = v_def then raise exception 'c709: _exception_rows anchor missing'; end if;
    execute v_new;
  end if;
end $do$;
