-- ============================================================================
-- CHANGE #173 — B2B repeat-buying / reorder suite (ONE shared cadence engine)
-- Max-backend: all cadence math, cart building, display strings live here.
-- Flutter only requests + renders. Money INR, timestamps IST for display.
-- ============================================================================

-- ─── Tables ─────────────────────────────────────────────────────────────────

create table if not exists public.reorder_subscriptions (
  id              uuid primary key default gen_random_uuid(),
  customer_id     uuid not null,                 -- pharmacy_profiles.id (account)
  source_order_id uuid,                           -- orders.id it was seeded from
  cadence_days    int  not null default 30,
  items           jsonb not null default '[]'::jsonb,  -- [{product_id,qty,name}]
  status          text not null default 'active',      -- active|paused|cancelled
  next_run_date   date not null default (current_date + 30),
  last_run_at     timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists idx_reorder_subs_cust on public.reorder_subscriptions(customer_id);
create index if not exists idx_reorder_subs_due  on public.reorder_subscriptions(next_run_date) where status='active';

create table if not exists public.reorder_prefs (
  customer_id  uuid not null,
  product_id   text not null,
  shelf_level  int,                     -- optional manual reorder threshold (units)
  notify       boolean not null default true,
  updated_at   timestamptz not null default now(),
  primary key (customer_id, product_id)
);

create table if not exists public.reorder_pending (
  id              uuid primary key default gen_random_uuid(),
  customer_id     uuid not null,
  kind            text not null,          -- predictive|subscription|lowstock
  subscription_id uuid,
  items           jsonb not null default '[]'::jsonb,
  amount          numeric,
  status          text not null default 'open',  -- open|confirmed|skipped|expired
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz
);
create index if not exists idx_reorder_pending_open on public.reorder_pending(customer_id) where status='open';

-- ─── RLS: a customer sees only their own; admins see all ─────────────────────
alter table public.reorder_subscriptions enable row level security;
alter table public.reorder_prefs         enable row level security;
alter table public.reorder_pending       enable row level security;

do $$
begin
  -- subscriptions
  if not exists (select 1 from pg_policies where tablename='reorder_subscriptions' and policyname='reorder_subs_owner') then
    create policy reorder_subs_owner on public.reorder_subscriptions
      for select using (
        customer_id = public.my_customer_id()
        or public.get_my_role() = any(array['admin','super_admin']));
  end if;
  -- prefs
  if not exists (select 1 from pg_policies where tablename='reorder_prefs' and policyname='reorder_prefs_owner') then
    create policy reorder_prefs_owner on public.reorder_prefs
      for select using (
        customer_id = public.my_customer_id()
        or public.get_my_role() = any(array['admin','super_admin']));
  end if;
  -- pending
  if not exists (select 1 from pg_policies where tablename='reorder_pending' and policyname='reorder_pending_owner') then
    create policy reorder_pending_owner on public.reorder_pending
      for select using (
        customer_id = public.my_customer_id()
        or public.get_my_role() = any(array['admin','super_admin']));
  end if;
end $$;

-- ─── Small display helpers ───────────────────────────────────────────────────
create or replace function public._reorder_uic(p_key text, p_default text)
returns text language sql stable as $$
  select coalesce((select value #>> '{}' from public.ui_copy where key = p_key), p_default);
$$;

create or replace function public._reorder_money(p_v numeric)
returns text language sql immutable as $$
  select '₹' || trim(to_char(round(coalesce(p_v,0), 2), 'FM999999990.00'));
$$;

-- ============================================================================
-- THE ONE ENGINE — per-customer purchase cadence from real order history.
-- Every one of the five features reads from here; nothing else computes cadence.
-- ============================================================================
create or replace function public._reorder_cadence(p_customer uuid)
returns table (
  product_id     text,
  name           text,
  marketer       text,
  pack_size      text,
  image_url      text,
  buy_count      int,
  usual_qty      int,
  last_qty       int,
  first_date     date,
  last_date      date,
  days_since_last int,
  avg_gap_days   numeric,
  predicted_next date,
  due            boolean,
  supplier_count int,
  mrp            numeric,
  gst_percent    int
)
language sql stable security definer set search_path to 'public' as $$
  with lines as (
    select oi.product_id::text                       as pid,
           coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date) as odate,
           oi.quantity::numeric                       as qty,
           oi.created_at                              as ots
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where o.customer_id = p_customer
       and coalesce(o.status,'') not in ('cancelled','rejected')
       and coalesce(oi.unfulfillable,false) = false
       and oi.product_id is not null
  ),
  agg as (
    select pid,
           count(*)::int                              as buy_count,
           round(avg(qty))::int                        as usual_qty,
           min(odate)                                  as first_date,
           max(odate)                                  as last_date,
           (current_date - max(odate))::int            as days_since_last,
           (array_agg(qty order by odate desc, ots desc))[1]::int as last_qty
      from lines
     group by pid
  )
  select a.pid,
         coalesce(m.product_name, a.pid)              as name,
         coalesce(m.marketer,'')                       as marketer,
         coalesce(m.pack_size,'')                      as pack_size,
         coalesce(m.image_url_1,'')                    as image_url,
         a.buy_count,
         greatest(a.usual_qty,1)                       as usual_qty,
         greatest(a.last_qty,1)                        as last_qty,
         a.first_date,
         a.last_date,
         a.days_since_last,
         case when a.buy_count >= 2
              then round((a.last_date - a.first_date)::numeric / nullif(a.buy_count-1,0), 1)
              else null end                            as avg_gap_days,
         case when a.buy_count >= 2
              then a.last_date + (round((a.last_date - a.first_date)::numeric / nullif(a.buy_count-1,0)))::int
              else null end                            as predicted_next,
         case when a.buy_count >= 2
              then (a.last_date + (round((a.last_date - a.first_date)::numeric / nullif(a.buy_count-1,0)))::int)
                   <= (current_date + 2)
              else false end                           as due,
         coalesce(m.supplier_count,0)                  as supplier_count,
         nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp,
         nullif(regexp_replace(coalesce(m.gst_percent::text,''),'\D','','g'),'')::int  as gst_percent
    from agg a
    left join "MEDICINE" m on m.id::text = a.pid;
$$;

-- ============================================================================
-- FEATURE 1 — PREDICTIVE AUTO-REORDER: reorder_suggestions() render-ready
-- ============================================================================
create or replace function public.reorder_suggestions()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cust uuid; v_items jsonb; v_due int;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object(
      'ok', true, 'has_history', false, 'items', '[]'::jsonb,
      'due_count', 0, 'has_due', false,
      'title', public._reorder_uic('reorder.title','Reorder'),
      'empty_title', public._reorder_uic('reorder.empty_title','No reorder history yet'),
      'empty_note',  public._reorder_uic('reorder.empty_note','Your regular items will appear here once you have ordered a few times.'));
  end if;

  select coalesce(jsonb_agg(row order by row_order), '[]'::jsonb),
         coalesce(sum(case when (row->>'due')::boolean then 1 else 0 end),0)
    into v_items, v_due
  from (
    select jsonb_build_object(
             'product_id', c.product_id,
             'name', c.name,
             'marketer', c.marketer,
             'pack_size', c.pack_size,
             'image_url', c.image_url,
             'usual_qty', c.usual_qty,
             'qty_label', public._reorder_uic('reorder.usual_prefix','Usual: ') || c.usual_qty::text,
             'days_since_last', c.days_since_last,
             'since_label', c.days_since_last::text || ' ' || public._reorder_uic('reorder.days_ago','days ago'),
             'due', c.due,
             'due_label', case when c.due then public._reorder_uic('reorder.due_now','Due now') else '' end,
             'predicted_label', case when c.predicted_next is not null
                    then public._reorder_uic('reorder.next_prefix','Next ~ ') ||
                         to_char(c.predicted_next,'DD Mon') else '' end,
             'price_display', public._reorder_money(c.mrp),
             'can_add', (c.supplier_count >= 1),
             'unavailable_label', case when c.supplier_count >= 1 then ''
                    else public._reorder_uic('reorder.unavailable','Currently unavailable') end
           ) as row,
           -- due first, then most-overdue, then most-frequent
           (case when c.due then 0 else 1 end)::text ||
           lpad((100000 - least(c.days_since_last,99999))::text,6,'0') ||
           lpad((100000 - c.buy_count)::text,6,'0') as row_order
      from public._reorder_cadence(v_cust) c
  ) s;

  return jsonb_build_object(
    'ok', true, 'has_history', (jsonb_array_length(v_items) > 0),
    'items', v_items,
    'due_count', v_due,
    'has_due', (v_due > 0),
    'title', public._reorder_uic('reorder.title','Reorder'),
    'due_title', public._reorder_uic('reorder.due_title','Due for reorder'),
    'all_title', public._reorder_uic('reorder.all_title','Your regular items'),
    'add_all_label', public._reorder_uic('reorder.add_all','Add all due to cart'),
    'add_label', public._reorder_uic('reorder.add','Add'),
    'manage_label', public._reorder_uic('reorder.manage','Manage auto-reorders'),
    'generic_error', public._reorder_uic('reorder.add_generic_error','Something went wrong'),
    'empty_title', public._reorder_uic('reorder.empty_title','No reorder history yet'),
    'empty_note',  public._reorder_uic('reorder.empty_note','Your regular items will appear here once you have ordered a few times.'));
end $$;

-- Build a cart from suggestions (given product_ids, else all "due"), usual qty.
create or replace function public.reorder_build_cart(p_product_ids text[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cust uuid; r record; v_added int := 0;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  for r in
    select * from public._reorder_cadence(v_cust) c
     where c.supplier_count >= 1
       and ( (p_product_ids is not null and c.product_id = any(p_product_ids))
             or (p_product_ids is null and c.due) )
  loop
    perform public.cart_set_item(r.product_id, r.usual_qty, null);
    v_added := v_added + 1;
  end loop;
  return jsonb_build_object(
    'ok', true, 'added', v_added,
    'message', v_added::text || ' ' || public._reorder_uic('reorder.added_suffix','items added to cart'),
    'cart', public.cart_render(null));
end $$;

-- ============================================================================
-- FEATURE 4 — SMART BASKET DIFF: reorder_diff(order_id) + reorder_apply_diff
-- Reconciles a past order against the current catalog/availability. Never
-- silently changes price or qty — it reports every delta for the customer.
-- ============================================================================
create or replace function public.reorder_diff(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cust uuid; v_ord record; v_lines jsonb; v_avail int; v_removed int;
        v_up int; v_down int;
begin
  v_cust := public.my_customer_id();
  select o.id, o.order_code, o.customer_id into v_ord
    from public.orders o where o.id = p_order_id;
  if v_ord.id is null or (v_cust is not null and v_ord.customer_id <> v_cust
        and public.get_my_role() not in ('admin','super_admin')) then
    return jsonb_build_object('ok', false,
      'message', public._reorder_uic('reorder.order_not_found','Order not found'));
  end if;

  select coalesce(jsonb_agg(line order by nm), '[]'::jsonb),
         coalesce(sum(case when avail then 1 else 0 end),0),
         coalesce(sum(case when not avail and swap_id is null then 1 else 0 end),0),
         coalesce(sum(case when delta > 0 then 1 else 0 end),0),
         coalesce(sum(case when delta < 0 then 1 else 0 end),0)
    into v_lines, v_avail, v_removed, v_up, v_down
  from (
    select oi.product_name as nm,
           (coalesce(m.supplier_count,0) >= 1) as avail,
           s.swap_id,
           round(coalesce(cur.mrp,0) - coalesce(oi.price,0),2) as delta,
           jsonb_build_object(
             'product_id', oi.product_id::text,
             'name', coalesce(m.product_name, oi.product_name),
             'last_qty', oi.quantity::int,
             'last_price_display', public._reorder_money(oi.price),
             'now_price_display', case when m.id is not null then public._reorder_money(cur.mrp) else '' end,
             'price_delta', round(coalesce(cur.mrp,0) - coalesce(oi.price,0),2),
             'price_delta_label', case
                 when m.id is null then ''
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) > 0
                      then '↑ ' || public._reorder_money(coalesce(cur.mrp,0)-coalesce(oi.price,0))
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) < 0
                      then '↓ ' || public._reorder_money(coalesce(oi.price,0)-coalesce(cur.mrp,0))
                 else public._reorder_uic('reorder.same_price','Same price') end,
             'price_tone', case
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) > 0 then 'warning'
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) < 0 then 'success'
                 else 'neutral' end,
             'status', case when m.id is null then 'discontinued'
                            when coalesce(m.supplier_count,0) >= 1 then 'available'
                            else 'out_of_stock' end,
             'status_label', case when m.id is null then public._reorder_uic('reorder.discontinued','No longer listed')
                            when coalesce(m.supplier_count,0) >= 1 then public._reorder_uic('reorder.in_stock','Available')
                            else public._reorder_uic('reorder.oos','Out of stock') end,
             'can_add', (coalesce(m.supplier_count,0) >= 1),
             'swap', case when coalesce(m.supplier_count,0) < 1 and sw.id is not null
                          then jsonb_build_object(
                                 'product_id', sw.id::text,
                                 'name', sw.product_name,
                                 'price_display', public._reorder_money(
                                     nullif(regexp_replace(coalesce(sw.mrp::text,''),'[^0-9.]','','g'),'')::numeric),
                                 'reason', public._reorder_uic('reorder.swap_reason','Same maker, in stock'))
                          else null end
           ) as line
      from public.order_items oi
      left join "MEDICINE" m on m.id = oi.product_id
      left join lateral (
        select nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp
      ) cur on true
      left join lateral (
        select sw2.id as swap_id from "MEDICINE" sw2
         where coalesce(m.supplier_count,0) < 1
           and sw2.id <> coalesce(m.id,-1)
           and sw2.supplier_count >= 1
           and ( (m.marketer is not null and sw2.marketer = m.marketer)
                 or (m.therapeutic_class is not null and sw2.therapeutic_class = m.therapeutic_class) )
         order by (case when sw2.marketer = m.marketer then 0 else 1 end), sw2.supplier_count desc
         limit 1
      ) s on true
      left join "MEDICINE" sw on sw.id = s.swap_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable,false) = false
  ) q;

  return jsonb_build_object(
    'ok', true,
    'order_code', coalesce(v_ord.order_code,''),
    'title', public._reorder_uic('reorder.diff_title','Reorder this order'),
    'lines', v_lines,
    'summary', jsonb_build_object(
       'total_lines', jsonb_array_length(v_lines),
       'available', v_avail,
       'removed', v_removed,
       'price_up', v_up,
       'price_down', v_down,
       'removed_label', case when v_removed > 0
            then v_removed::text || ' ' || public._reorder_uic('reorder.removed_suffix','item(s) unavailable — skipped')
            else '' end,
       'changes_label', case when (v_up+v_down) > 0
            then (v_up+v_down)::text || ' ' || public._reorder_uic('reorder.price_changed_suffix','price change(s) since last time')
            else '' end),
    'cta_label', public._reorder_uic('reorder.add_available','Add available items to cart'),
    'repeat_label', public._reorder_uic('reorder.repeat_toggle','Repeat this order automatically'),
    'repeat_note', public._reorder_uic('reorder.repeat_note','Every 30 days — we confirm on WhatsApp before dispatch'),
    'manage_label', public._reorder_uic('reorder.manage','Manage auto-reorders'),
    'generic_error', public._reorder_uic('reorder.add_generic_error','Something went wrong'),
    'add_count', v_avail);
end $$;

create or replace function public.reorder_apply_diff(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cust uuid; r record; v_added int := 0; v_pid text; v_qty int;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  for r in
    select oi.product_id, oi.quantity, coalesce(m.supplier_count,0) as sc
      from public.order_items oi
      left join "MEDICINE" m on m.id = oi.product_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable,false) = false
  loop
    if r.sc >= 1 then
      v_pid := r.product_id::text; v_qty := greatest(r.quantity::int,1);
      perform public.cart_set_item(v_pid, v_qty, null);
      v_added := v_added + 1;
    end if;
  end loop;
  return jsonb_build_object(
    'ok', true, 'added', v_added,
    'message', v_added::text || ' ' || public._reorder_uic('reorder.added_suffix','items added to cart'),
    'cart', public.cart_render(null));
end $$;

-- ============================================================================
-- FEATURE 2 — SUBSCRIPTION / STANDING ORDER
-- ============================================================================
create or replace function public.reorder_subscription_set(
  p_order_id uuid, p_cadence_days int default 30, p_enabled boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cust uuid; v_items jsonb; v_id uuid; v_cad int;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  v_cad := greatest(coalesce(p_cadence_days,30), 1);

  if not p_enabled then
    update public.reorder_subscriptions
       set status='cancelled', updated_at=now()
     where customer_id=v_cust and source_order_id=p_order_id and status<>'cancelled';
    return jsonb_build_object('ok', true, 'enabled', false,
      'message', public._reorder_uic('reorder.sub_off','Auto-reorder turned off'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id', oi.product_id::text,
           'qty', oi.quantity::int,
           'name', coalesce(m.product_name, oi.product_name))), '[]'::jsonb)
    into v_items
    from public.order_items oi
    left join "MEDICINE" m on m.id = oi.product_id
   where oi.order_id = p_order_id
     and coalesce(oi.unfulfillable,false) = false;

  if v_items = '[]'::jsonb then
    return jsonb_build_object('ok', false,
      'message', public._reorder_uic('reorder.sub_no_items','Nothing to subscribe on this order'));
  end if;

  update public.reorder_subscriptions
     set cadence_days=v_cad, items=v_items, status='active',
         next_run_date=current_date + v_cad, updated_at=now()
   where customer_id=v_cust and source_order_id=p_order_id
   returning id into v_id;

  if v_id is null then
    insert into public.reorder_subscriptions(customer_id, source_order_id, cadence_days, items, next_run_date)
    values (v_cust, p_order_id, v_cad, v_items, current_date + v_cad)
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'enabled', true, 'id', v_id,
    'message', public._reorder_uic('reorder.sub_on_prefix','Auto-reorder set — every ') || v_cad::text
               || ' ' || public._reorder_uic('reorder.days','days'));
end $$;

create or replace function public.reorder_subscription_list()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cust uuid; v_rows jsonb;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', true, 'items', '[]'::jsonb, 'has_any', false,
      'title', public._reorder_uic('reorder.subs_title','Auto-reorders'),
      'empty_title', public._reorder_uic('reorder.subs_empty','No auto-reorders yet'),
      'empty_note', public._reorder_uic('reorder.subs_empty_note','Turn on “repeat this order” from any past order to save it here.'));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id,
           'status', s.status,
           'status_label', case s.status when 'active' then public._reorder_uic('reorder.sub_active','Active')
                                         when 'paused' then public._reorder_uic('reorder.sub_paused','Paused')
                                         else public._reorder_uic('reorder.sub_cancelled','Cancelled') end,
           'status_tone', case s.status when 'active' then 'success' when 'paused' then 'warning' else 'neutral' end,
           'cadence_label', public._reorder_uic('reorder.every','Every ') || s.cadence_days::text || ' '
                            || public._reorder_uic('reorder.days','days'),
           'next_run_label', case when s.status='active'
                            then public._reorder_uic('reorder.next_run','Next: ') || to_char(s.next_run_date,'DD Mon YYYY')
                            else '' end,
           'item_count', jsonb_array_length(s.items),
           'items_label', jsonb_array_length(s.items)::text || ' ' || public._reorder_uic('reorder.items','items'),
           'can_pause', (s.status='active'), 'can_resume', (s.status='paused'),
           'can_cancel', (s.status<>'cancelled'),
           'pause_label', public._reorder_uic('reorder.pause','Pause'),
           'resume_label', public._reorder_uic('reorder.resume','Resume'),
           'cancel_label', public._reorder_uic('reorder.cancel','Cancel'))
           order by (s.status='active') desc, s.next_run_date), '[]'::jsonb)
    into v_rows
    from public.reorder_subscriptions s
   where s.customer_id = v_cust and s.status <> 'cancelled';
  return jsonb_build_object('ok', true, 'items', v_rows,
    'has_any', (jsonb_array_length(v_rows) > 0),
    'title', public._reorder_uic('reorder.subs_title','Auto-reorders'),
    'empty_title', public._reorder_uic('reorder.subs_empty','No auto-reorders yet'),
    'empty_note', public._reorder_uic('reorder.subs_empty_note','Turn on “repeat this order” from any past order to save it here.'));
end $$;

create or replace function public.reorder_subscription_update(p_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cust uuid; v_new text;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  v_new := case lower(coalesce(p_action,''))
             when 'pause' then 'paused' when 'resume' then 'active'
             when 'cancel' then 'cancelled' else null end;
  if v_new is null then
    return jsonb_build_object('ok', false, 'message', 'bad_action');
  end if;
  update public.reorder_subscriptions
     set status=v_new, updated_at=now(),
         next_run_date = case when v_new='active' then current_date + cadence_days else next_run_date end
   where id=p_id and customer_id=v_cust;
  if not found then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.sub_not_found','Auto-reorder not found'));
  end if;
  return public.reorder_subscription_list();
end $$;

-- ============================================================================
-- FEATURE 3 — LOW-STOCK: reorder_prefs_set + cadence-inferred nudge
-- ============================================================================
create or replace function public.reorder_prefs_set(
  p_product_id text, p_shelf_level int default null, p_notify boolean default true)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_cust uuid;
begin
  v_cust := public.my_customer_id();
  if v_cust is null then
    return jsonb_build_object('ok', false, 'message', public._reorder_uic('reorder.login','Please log in'));
  end if;
  insert into public.reorder_prefs(customer_id, product_id, shelf_level, notify, updated_at)
  values (v_cust, p_product_id, p_shelf_level, coalesce(p_notify,true), now())
  on conflict (customer_id, product_id) do update
    set shelf_level=excluded.shelf_level, notify=excluded.notify, updated_at=now();
  return jsonb_build_object('ok', true,
    'message', public._reorder_uic('reorder.pref_saved','Reorder reminder saved'));
end $$;

-- ============================================================================
-- FEATURE 5 wiring + FEATURES 2/3 crons — draft as reorder_pending, confirm-first
-- ============================================================================

-- Create an open pending nudge for a customer (dedup: one open per kind/source).
create or replace function public._reorder_open_pending(
  p_cust uuid, p_kind text, p_items jsonb, p_sub uuid default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_amt numeric;
begin
  if exists (select 1 from public.reorder_pending
              where customer_id=p_cust and status='open'
                and kind=p_kind and coalesce(subscription_id,'00000000-0000-0000-0000-000000000000')
                    = coalesce(p_sub,'00000000-0000-0000-0000-000000000000')) then
    return null;
  end if;
  select coalesce(sum( (e->>'qty')::numeric *
           coalesce(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,0) ),0)
    into v_amt
  from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) e
  left join "MEDICINE" m on m.id::text = (e->>'product_id');
  insert into public.reorder_pending(customer_id, kind, subscription_id, items, amount)
  values (p_cust, p_kind, p_sub, coalesce(p_items,'[]'::jsonb), v_amt)
  returning id into v_id;
  return v_id;
end $$;

-- Daily: materialize due subscriptions into a pending draft + WhatsApp confirm.
create or replace function public.reorder_subscription_run()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare s record; v_pid uuid; n int := 0;
begin
  for s in
    select * from public.reorder_subscriptions
     where status='active' and next_run_date <= current_date
  loop
    v_pid := public._reorder_open_pending(s.customer_id, 'subscription', s.items, s.id);
    if v_pid is not null then
      perform public.wa_send_event('reorder_due', s.customer_id,
                 jsonb_build_object(), null, null);
      n := n + 1;
    end if;
    update public.reorder_subscriptions
       set next_run_date = current_date + cadence_days, last_run_at = now(), updated_at = now()
     where id = s.id;
  end loop;
  return n;
end $$;

-- Daily: cadence/shelf-level low-stock nudge for opted-in customers.
create or replace function public.reorder_lowstock_check()
returns integer language plpgsql security definer set search_path to 'public' as $$
declare p record; c record; v_items jsonb; v_pid uuid; n int := 0;
begin
  for p in
    select distinct customer_id from public.reorder_prefs where notify = true
  loop
    -- items that are due by cadence (predicted next date reached) and opted-in
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', cd.product_id, 'qty', cd.usual_qty, 'name', cd.name)), '[]'::jsonb)
      into v_items
      from public._reorder_cadence(p.customer_id) cd
      join public.reorder_prefs rp
        on rp.customer_id = p.customer_id and rp.product_id = cd.product_id and rp.notify = true
     where cd.due and cd.supplier_count >= 1;
    if v_items <> '[]'::jsonb then
      v_pid := public._reorder_open_pending(p.customer_id, 'lowstock', v_items, null);
      if v_pid is not null then
        perform public.wa_send_event('reorder_due', p.customer_id, jsonb_build_object(), null, null);
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;

-- Inbound "YES" → build the pending cart for that customer (normal order flow).
create or replace function public.reorder_confirm_pending(p_cust uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare pend record; e jsonb; v_added int := 0; v_uid uuid;
begin
  select * into pend from public.reorder_pending
   where customer_id=p_cust and status='open' order by created_at limit 1;
  if pend.id is null then
    return jsonb_build_object('ok', false, 'reason','no_pending');
  end if;
  select user_id into v_uid from public.pharmacy_profiles where id=p_cust;
  for e in select * from jsonb_array_elements(pend.items) loop
    insert into public.cart_items(user_id, customer_id, product_id, product_name, price, mrp,
                                  quantity, gst_percent, added_by)
    select v_uid, p_cust, (e->>'product_id'), coalesce(m.product_name, e->>'name'),
           nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
           nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
           greatest((e->>'qty')::int,1),
           nullif(regexp_replace(coalesce(m.gst_percent::text,''),'\D','','g'),'')::int, 'reorder'
      from "MEDICINE" m where m.id::text = (e->>'product_id') and coalesce(m.supplier_count,0) >= 1
    on conflict (user_id, product_id) do update
       set quantity=excluded.quantity, removed_by_admin=false, updated_at=now();
    v_added := v_added + 1;
  end loop;
  update public.reorder_pending set status='confirmed', resolved_at=now() where id=pend.id;
  return jsonb_build_object('ok', true, 'added', v_added, 'pending_id', pend.id);
end $$;

create or replace function public.reorder_skip_pending(p_cust uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  update public.reorder_pending set status='skipped', resolved_at=now()
   where customer_id=p_cust and status='open';
  return jsonb_build_object('ok', true);
end $$;

-- ─── WhatsApp routes (auto-managed templates like every other route) ─────────
insert into public.wa_event_routes(event_key, label, description, enabled, auto_manage, audience)
values
 ('reorder_due','Reorder due','Monthly reorder nudge to a customer',true,true,'customer'),
 ('reorder_confirmed','Reorder confirmed','Confirmation that a reorder cart was built',true,true,'customer')
on conflict (event_key) do nothing;

-- ─── Inbound quick-reply actions: seed YES/SKIP reorder intents ──────────────
do $$
declare v jsonb; acts jsonb;
begin
  select value into v from app_settings where key='wa_quick_reply_actions';
  if v is null then
    v := jsonb_build_object('enabled', true, 'actions', '[]'::jsonb);
  end if;
  acts := coalesce(v->'actions','[]'::jsonb);
  if not exists (select 1 from jsonb_array_elements(acts) a where a->>'action'='reorder_confirm') then
    acts := acts || jsonb_build_array(
      jsonb_build_object('match','reorder yes','action','reorder_confirm','reply_en','Great — we have rebuilt your order. Our team will confirm shortly.'),
      jsonb_build_object('match','reorder skip','action','reorder_skip','reply_en','No problem — we have skipped this reorder.'));
  end if;
  insert into app_settings(key, value) values ('wa_quick_reply_actions', jsonb_build_object('enabled',true,'actions',acts))
  on conflict (key) do update set value=excluded.value;
end $$;

-- ─── ui_copy seeds (idempotent) ──────────────────────────────────────────────
insert into public.ui_copy(key, value) values
 ('reorder.title', to_jsonb('Reorder'::text)),
 ('reorder.due_title', to_jsonb('Due for reorder'::text)),
 ('reorder.all_title', to_jsonb('Your regular items'::text)),
 ('reorder.usual_prefix', to_jsonb('Usual: '::text)),
 ('reorder.days_ago', to_jsonb('days ago'::text)),
 ('reorder.due_now', to_jsonb('Due now'::text)),
 ('reorder.next_prefix', to_jsonb('Next ~ '::text)),
 ('reorder.unavailable', to_jsonb('Currently unavailable'::text)),
 ('reorder.add_all', to_jsonb('Add all due to cart'::text)),
 ('reorder.add', to_jsonb('Add'::text)),
 ('reorder.added_suffix', to_jsonb('items added to cart'::text)),
 ('reorder.empty_title', to_jsonb('No reorder history yet'::text)),
 ('reorder.empty_note', to_jsonb('Your regular items will appear here once you have ordered a few times.'::text)),
 ('reorder.diff_title', to_jsonb('Reorder this order'::text)),
 ('reorder.order_not_found', to_jsonb('Order not found'::text)),
 ('reorder.discontinued', to_jsonb('No longer listed'::text)),
 ('reorder.in_stock', to_jsonb('Available'::text)),
 ('reorder.oos', to_jsonb('Out of stock'::text)),
 ('reorder.same_price', to_jsonb('Same price'::text)),
 ('reorder.swap_reason', to_jsonb('Same maker, in stock'::text)),
 ('reorder.removed_suffix', to_jsonb('item(s) unavailable — skipped'::text)),
 ('reorder.price_changed_suffix', to_jsonb('price change(s) since last time'::text)),
 ('reorder.add_available', to_jsonb('Add available items to cart'::text)),
 ('reorder.login', to_jsonb('Please log in'::text)),
 ('reorder.sub_off', to_jsonb('Auto-reorder turned off'::text)),
 ('reorder.sub_no_items', to_jsonb('Nothing to subscribe on this order'::text)),
 ('reorder.sub_on_prefix', to_jsonb('Auto-reorder set — every '::text)),
 ('reorder.days', to_jsonb('days'::text)),
 ('reorder.subs_title', to_jsonb('Auto-reorders'::text)),
 ('reorder.subs_empty', to_jsonb('No auto-reorders yet'::text)),
 ('reorder.subs_empty_note', to_jsonb('Turn on “repeat this order” from any past order to save it here.'::text)),
 ('reorder.sub_active', to_jsonb('Active'::text)),
 ('reorder.sub_paused', to_jsonb('Paused'::text)),
 ('reorder.sub_cancelled', to_jsonb('Cancelled'::text)),
 ('reorder.every', to_jsonb('Every '::text)),
 ('reorder.next_run', to_jsonb('Next: '::text)),
 ('reorder.items', to_jsonb('items'::text)),
 ('reorder.pause', to_jsonb('Pause'::text)),
 ('reorder.resume', to_jsonb('Resume'::text)),
 ('reorder.cancel', to_jsonb('Cancel'::text)),
 ('reorder.sub_not_found', to_jsonb('Auto-reorder not found'::text)),
 ('reorder.pref_saved', to_jsonb('Reorder reminder saved'::text)),
 ('reorder.repeat_toggle', to_jsonb('Repeat this order automatically'::text)),
 ('reorder.entry_due', to_jsonb('Due for reorder'::text)),
 ('reorder.entry_open', to_jsonb('View your regular items'::text)),
 ('reorder.order_button', to_jsonb('Reorder'::text)),
 ('reorder.cart_go', to_jsonb('Go to cart'::text))
on conflict (key) do nothing;
