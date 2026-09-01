-- CHANGE #398 (1/4) — THE PARTNER WORK QUEUE.
--
-- partner_home() listed the features a partner is allowed to open. It answered
-- "what may I do?" and never "what is waiting for me right now?", so a partner
-- opened Collect, then Count, then Pack, guessing which one had work in it.
--
-- This is the working board: today's zone, every fulfilment stage, the count,
-- the oldest orders in that stage and the next action for each — composed
-- entirely in SQL. The screen prints it.
--
-- THE ZONE IS NEVER PICKED. partner_zone_id() resolves it from the partner's
-- own region_partners row, exactly as every other partner surface does, and a
-- stage the partner has no permission for is not in the payload at all.

-- ── The stage ladder, as DATA ───────────────────────────────────────────────
-- A stage's label, its next action and the feature it belongs to are rows, not
-- literals: re-wording the board is an UPDATE, never a deploy.
create table if not exists public.partner_queue_stage (
  stage_key    text primary key,
  sort_order   int  not null default 0,
  label        text not null default '',
  next_action  text not null default '',
  feature_key  text,                    -- null = ungated (visible to any partner)
  tone         text not null default 'neutral',
  is_active    boolean not null default true
);

insert into public.partner_queue_stage
  (stage_key, sort_order, label, next_action, feature_key, tone) values
  ('received',        10, 'Received',          'Accept and start inquiry', 'partner.inquiry',         'warning'),
  ('inquiry',         20, 'Inquiry',           'Ask the next supplier',    'partner.inquiry',         'info'),
  ('supplier_order',  30, 'Supplier order',    'Raise the supplier order', 'partner.supplier_orders', 'info'),
  ('collect',         40, 'Collect',           'Collect from the shop',    'partner.collect',         'info'),
  ('count',           50, 'Count',             'Count in at the warehouse','partner.count',           'info'),
  ('bag',             60, 'Bag',               'Allocate to a bag',        'partner.bag_mapping',     'info'),
  ('pack',            70, 'Pack',              'Pack the order',           'partner.pack',            'info'),
  ('assign_delivery', 80, 'Assign delivery',   'Assign a rider',           'partner.assign_delivery', 'success')
on conflict (stage_key) do nothing;

alter table public.partner_queue_stage enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies
                  where schemaname='public' and tablename='partner_queue_stage'
                    and policyname='partner_queue_stage_read') then
    create policy partner_queue_stage_read on public.partner_queue_stage
      for select to authenticated using (true);
  end if;
end $$;

-- The board's own copy, in the same app_settings row shape partner_home() uses.
insert into public.app_settings(key, value)
values ('partner_queue_copy', jsonb_build_object(
  'title',          'Today''s work',
  'subtitle',       'Oldest first. Tap a stage to open it.',
  'empty_title',    'Nothing waiting',
  'empty_message',  'Every order in your zone has moved on. New orders appear here the moment they land.',
  'count_one',      '{n} order',
  'count_many',     '{n} orders',
  'more_label',     '+{n} more',
  'open_label',     'Open',
  'locked_label',   'No access',
  'today_label',    'Today: {received} received · {delivered} delivered',
  'total_label',    '{n} waiting',
  'not_partner_message', 'This account is not a fulfilment partner.'))
on conflict (key) do nothing;

-- ── The board ───────────────────────────────────────────────────────────────
-- ONE query. Each open order in the zone resolves to the FIRST unmet step of
-- the fulfilment ladder; the stages then read that set. A cancelled or closed
-- order is not work, and an unfulfillable line is not work either, so both are
-- excluded from every "some line still needs X" test.
create or replace function public.partner_work_queue(p_limit int default 5)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
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

  return jsonb_build_object(
    'ok', true, 'is_partner', true,
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
end $function$;

revoke all on function public.partner_work_queue(int) from public, anon;
grant execute on function public.partner_work_queue(int) to authenticated, service_role;

-- The board is partner-native (it resolves the partner from auth.uid() itself),
-- but it is READ by a session whose get_my_role() consults partner_rpc_allow;
-- naming it there keeps that role resolution 'admin' rather than flipping to
-- 'partner' mid-screen for the other zone-clamped RPCs the same tap uses.
insert into public.partner_rpc_allow(proname, source, note)
values ('partner_work_queue','c398','partner work queue board')
on conflict (proname) do nothing;

-- ── Recorded verification ───────────────────────────────────────────────────
create or replace function public.c398_work_queue_proof()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_zone smallint; v_out jsonb;
begin
  select rp.zone_id::smallint into v_zone
    from region_partners rp where coalesce(rp.is_active,true) order by rp.id limit 1;
  select jsonb_build_object(
    'zone_id', v_zone,
    'stages_registered', (select count(*) from partner_queue_stage where is_active),
    'open_orders_in_zone', (select count(*) from orders o
        left join pharmacy_profiles pp on pp.id=o.customer_id
       where o.status <> 'cancelled' and o.closed_at is null
         and coalesce(o.zone_id, pp.zone_id) = v_zone),
    'copy_present', (select count(*) from app_settings where key='partner_queue_copy'),
    'rpc_allowed', (select count(*) from partner_rpc_allow where proname='partner_work_queue'))
  into v_out;
  return v_out;
end $function$;
grant execute on function public.c398_work_queue_proof() to service_role;
