-- CHANGE #465 — MEDIUM defects · supplier batch B (register rows 49, 51, 63, 64, 65).
-- Batch A (#464) owns rows 32-48; nothing here touches them.
--
-- ── GAP 49 · Bundle mode ranks suppliers by MRP ─────────────────────────────
-- Reproduced in the live definition of inquiry_engine_ranked_suppliers():
--     ORDER BY CASE WHEN v_bundle THEN p.top_mrp
--                   ELSE COALESCE(sp."SPN",0)::numeric END DESC, p.sup
-- where top_mrp is max(COALESCE(i.mrp,0)) over the supplier's pending lines.
--
-- MRP is the printed regulatory ceiling. The business context is explicit:
-- "MRP ... is the legal ceiling and a display field, never the selling price.
-- Any build that prices, totals, or reports revenue on MRP is wrong." Ranking
-- the waterfall on it means the supplier asked first in bundle mode is the one
-- who happens to hold the most expensively PRINTED pack — a fact about a
-- manufacturer's carton, not about that supplier's price, performance or how
-- much of the basket they can actually serve.
--
-- What bundle mode is FOR is asking the supplier who can fill the most of the
-- basket in one go. So it ranks on the basket, and WHICH measure of the basket
-- is a setting:
--   inquiry_bundle_rank_by = 'trade_value_then_lines'  (default)
--                          | 'line_count'
--                          | 'spn'                      (bundle mode off, effectively)
--
-- Honest note on trade value: medicine_pricing carries a PTR for 4 products
-- today, so 'trade_value_then_lines' behaves as line_count in practice right
-- now and starts ranking on real trade value the moment pricing fills in — no
-- deploy needed. That is deliberate: line count is the honest signal available
-- today, and the value key is already in place for when it is not.
--
-- Also cheaper than what it replaces: inquiry_demand_qty() was called once in
-- the WHERE and would have been called a second time to total the basket. The
-- lateral evaluates it ONCE per row and both the filter and the sum read it
-- (the scalar-helper-scan trap, CHANGE #301's latency lessons).
--
-- NOT changed here: the `p.sup` alphabetical tiebreak. That is register row 48,
-- which belongs to batch A (#464) — two commands must not rewrite one ORDER BY.

insert into app_settings (key, value) values
  ('inquiry_bundle_rank_by', '"trade_value_then_lines"'::jsonb)
on conflict (key) do nothing;

create or replace function public.inquiry_engine_ranked_suppliers()
returns table(supplier_name text, spn integer, pending_items integer, rnk integer, is_open boolean)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_bundle boolean;
  v_by     text;
begin
  v_bundle := coalesce((select (value #>> '{}')::boolean from app_settings where key='inquiry_bundle_mode'), false);
  v_by     := coalesce((select (value #>> '{}')    from app_settings where key='inquiry_bundle_rank_by'),
                       'trade_value_then_lines');
  -- 'spn' is the escape hatch: it turns bundle ranking off without touching the
  -- bundle-mode flag every other caller reads.
  if v_by = 'spn' then v_bundle := false; end if;

  return query
  with pend as (
    select i.current_supplier as sup,
           i.zone_id          as zid,
           count(*)::int      as pend_items,
           -- The basket, in money, where a trade rate is known. NEVER mrp.
           coalesce(sum(d.qty * coalesce(mp.ptr, 0)), 0)::numeric as bundle_value
    from inquiry i
    cross join lateral (
      select inquiry_demand_qty(i.product_id, i.current_supplier, true) as qty
    ) d
    left join medicine_pricing mp on mp.product_id = i.product_id
    where i.current_supplier is not null and btrim(i.current_supplier) <> ''
      and i.supplier_order_id is null
      and coalesce(i.current_status,'') <> 'Available'
      and d.qty > 0
    group by i.current_supplier, i.zone_id
  ),
  ranked as (
    select p.sup, p.zid,
           coalesce(sp."SPN",0)::int as spn_val,
           p.pend_items,
           row_number() over (
             partition by p.zid
             order by
               -- primary key: the basket in money when bundle mode wants that,
               -- otherwise SPN. Never MRP, in either branch.
               case when v_bundle and v_by = 'trade_value_then_lines' then p.bundle_value
                    when v_bundle and v_by = 'line_count'             then 0
                    else coalesce(sp."SPN",0)::numeric end desc,
               -- secondary key: how much of the basket they can serve. It is
               -- the whole ranking under 'line_count', and the tiebreak under
               -- 'trade_value_then_lines' — which is what makes an unpriced
               -- catalog rank sensibly instead of ranking on zero.
               case when v_bundle then p.pend_items else 0 end desc,
               p.sup)::int as rnk_val
    from pend p
    left join supplier_profiles sp
           on sp.supplier_name = p.sup
          and sp.zone_id is not distinct from p.zid
  )
  select r.sup, r.spn_val, r.pend_items, r.rnk_val, (r.rnk_val = 1)
  from ranked r order by r.zid, r.rnk_val;
end;
$function$;

-- ── GAP 64 · The supplier cannot see their own SPN or rank ──────────────────
-- Reproduced: supplier_profiles."SPN" is GENERATED ALWAYS as
--   (margin_points + behaviour_points + cd_points + payment_term_points
--    + ordered_medicine_points) * (status='active')
-- and inquiry_engine_ranked_suppliers() orders the whole waterfall by it, yet
-- every spn RPC (spn_options_list, sup_number_ranking, admin_supplier_spn_row)
-- is admin-side. The number that decides whether a supplier is asked first or
-- never was invisible to the supplier it describes.
--
-- Read-only by construction: the RPC resolves my_supplier_id() itself, takes no
-- supplier argument, and returns one payload with every string already worded.
-- Nothing here lets a supplier change their own points.

insert into ui_copy (key, value) values
  ('spn.title',              '"Your supplier number"'::jsonb),
  ('spn.subtitle',           '"This is the number that decides who mediBO asks first."'::jsonb),
  ('spn.value_label',        '"SPN"'::jsonb),
  ('spn.rank_label',         '"Rank in your zone"'::jsonb),
  ('spn.rank_of',            '"of {n} suppliers"'::jsonb),
  ('spn.inactive_note',      '"Your account is not active, so your SPN counts as zero and you are not asked."'::jsonb),
  ('spn.active_note',        '"Your account is active."'::jsonb),
  ('spn.components_label',   '"What makes it up"'::jsonb),
  ('spn.component_margin',           '"Margin"'::jsonb),
  ('spn.component_behaviour',        '"Behaviour"'::jsonb),
  ('spn.component_cd_condition',     '"Cash discount"'::jsonb),
  ('spn.component_payment_term',     '"Payment term"'::jsonb),
  ('spn.component_ordered_medicine', '"Ordered medicines"'::jsonb),
  ('spn.not_supplier',       '"This login is not a supplier account."'::jsonb),
  ('spn.no_rank',            '"You are not in a zone yet, so there is no rank to show."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function public.supplier_scorecard()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  sp     public.supplier_profiles%rowtype;
  v_id   uuid := public.my_supplier_id();
  v_rank int;
  v_of   int;
  v_act  boolean;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_supplier',
      'message', public._c('spn.not_supplier'));
  end if;
  select * into sp from public.supplier_profiles where id = v_id;

  v_act := (lower(btrim(coalesce(sp.status,''))) = 'active');

  -- Rank among the suppliers this one actually competes with: the same zone,
  -- approved, not deleted. Ties share nothing clever here — this is a mirror of
  -- the ranking, not a second implementation of it.
  if sp.zone_id is not null then
    select r.rnk, r.n into v_rank, v_of from (
      select s.id,
             rank() over (order by coalesce(s."SPN",0) desc)::int as rnk,
             count(*) over ()::int                                as n
        from public.supplier_profiles s
       where s.zone_id = sp.zone_id
         and s.approved = true
         and coalesce(s.is_deleted,false) = false
    ) r where r.id = sp.id;
  end if;

  return jsonb_build_object(
    'ok',        true,
    'title',     public._c('spn.title'),
    'subtitle',  public._c('spn.subtitle'),
    'spn', jsonb_build_object(
      'value', coalesce(sp."SPN",0),
      'label', public._c('spn.value_label'),
      'value_label', to_char(coalesce(sp."SPN",0), 'FM999,999,999')),
    'status', jsonb_build_object(
      'is_active', v_act,
      'label',     coalesce(nullif(btrim(coalesce(sp.status,'')),''), ''),
      'note',      case when v_act then public._c('spn.active_note')
                        else public._c('spn.inactive_note') end,
      'tone',      case when v_act then 'success' else 'warning' end),
    'rank', jsonb_build_object(
      'has',       (v_rank is not null),
      'label',     public._c('spn.rank_label'),
      'value',     coalesce(v_rank,0),
      'value_label', case when v_rank is null then ''
                          else '#' || v_rank::text end,
      'of_label',  case when v_of is null then public._c('spn.no_rank')
                        else replace(public._c('spn.rank_of'), '{n}', v_of::text) end),
    'components_label', public._c('spn.components_label'),
    'components', jsonb_build_array(
      jsonb_build_object('key','margin','label', public._c('spn.component_margin'),
        'points', coalesce(sp.margin_points,0),
        'points_label', to_char(coalesce(sp.margin_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.margin::text,'')),''),'')),
      jsonb_build_object('key','behaviour','label', public._c('spn.component_behaviour'),
        'points', coalesce(sp.behaviour_points,0),
        'points_label', to_char(coalesce(sp.behaviour_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.behaviour::text,'')),''),'')),
      jsonb_build_object('key','cd_condition','label', public._c('spn.component_cd_condition'),
        'points', coalesce(sp.cd_points,0),
        'points_label', to_char(coalesce(sp.cd_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.cd_condition::text,'')),''),'')),
      jsonb_build_object('key','payment_term','label', public._c('spn.component_payment_term'),
        'points', coalesce(sp.payment_term_points,0),
        'points_label', to_char(coalesce(sp.payment_term_points,0),'FM999,999,999'),
        'choice_label', coalesce(nullif(btrim(coalesce(sp.payment_term::text,'')),''),'')),
      jsonb_build_object('key','ordered_medicine','label', public._c('spn.component_ordered_medicine'),
        'points', coalesce(sp.ordered_medicine_points,0),
        'points_label', to_char(coalesce(sp.ordered_medicine_points,0),'FM999,999,999'),
        'choice_label', '')));
end $fn$;

revoke all on function public.supplier_scorecard() from public;
grant execute on function public.supplier_scorecard() to authenticated, service_role;

-- ── GAP 65 · Logged-in suppliers get no in-app notification ─────────────────
-- Reproduced from notification_log: audience='supplier' has 35 rows and every
-- one is channel='whatsapp'. audience='admin' has channel='push' rows, so the
-- machinery works — suppliers were simply never wired to it. The 7 suppliers
-- with a login open the app and are told nothing about a new inquiry, a new PO
-- or a dispute waiting on them.
--
-- Deliberately NOT done with triggers on inquiry / supplier_orders /
-- supplier_disputes. Those are hot tables that other in-flight commands are
-- editing, and a trigger on each is three new failure modes on the write path
-- of the order pipeline. A sweep on the existing cron dispatcher mints the same
-- rows, cannot slow a write down, and is idempotent by a unique index rather
-- than by hoping each trigger fires exactly once.
--
-- The BADGES are not stored at all: they are counted live from the same tables
-- the tabs already read, so a badge can never drift from what the tab shows.
-- Only the inbox ITEMS are rows, because an item is a thing that happened.

create unique index if not exists notification_log_in_app_once
  on public.notification_log (event_key, recipient_id, (payload->>'entity'))
  where channel = 'in_app';

insert into ui_copy (key, value) values
  ('sup_inbox.title',        '"Notifications"'::jsonb),
  ('sup_inbox.empty',        '"Nothing new right now."'::jsonb),
  ('sup_inbox.empty_note',   '"New inquiries, orders and disputes appear here."'::jsonb),
  ('sup_inbox.mark_all',     '"Mark all read"'::jsonb),
  ('sup_inbox.inquiry_title','"New inquiry to answer"'::jsonb),
  ('sup_inbox.inquiry_body', '"A buyer is asking what you have. Open the Inquiry tab to answer."'::jsonb),
  ('sup_inbox.order_title',  '"New purchase order"'::jsonb),
  ('sup_inbox.order_body',   '"An order has been raised on you. Open the Orders tab."'::jsonb),
  ('sup_inbox.dispute_title','"A dispute needs your answer"'::jsonb),
  ('sup_inbox.dispute_body', '"A short or wrong item was reported. Open the Disputes tab."'::jsonb),
  ('sup_inbox.not_supplier', '"This login is not a supplier account."'::jsonb)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- The sweep. One INSERT ... SELECT per source, each guarded by the unique index
-- above, so re-running it is a no-op and a missed run simply catches up.
create or replace function public.supplier_notify_sweep()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '55s'
as $fn$
declare v_inq int := 0; v_ord int := 0; v_dis int := 0;
begin
  -- 1. A form the admin actually SENT is the moment a supplier owes an answer.
  with src as (
    select sp.id as sup_id, sp.supplier_name as who, f.token, f.last_sent_at
      from public.inquiry_forms f
      join public.supplier_profiles sp
        on sp.supplier_name = f.supplier_name
       and sp.user_id is not null
       and coalesce(sp.is_deleted,false) = false
     where f.status = 'pending'
       and f.last_sent_at > now() - interval '30 days'
  ), ins as (
    insert into public.notification_log
      (event_key, audience, recipient_id, recipient, channel, status, title, body, deep_link, payload, created_at)
    select 'supplier.inquiry', 'supplier', s.sup_id, s.who, 'in_app', 'sent',
           public._c('sup_inbox.inquiry_title'), public._c('sup_inbox.inquiry_body'),
           '/supplier/inquiry', jsonb_build_object('entity', s.token, 'kind', 'inquiry'),
           coalesce(s.last_sent_at, now())
      from src s
    on conflict do nothing
    returning 1)
  select count(*)::int into v_inq from ins;

  -- 2. A purchase order raised on them.
  with src as (
    select so.supplier_id as sup_id, sp.supplier_name as who, so.id::text as entity, so.created_at
      from public.supplier_orders so
      join public.supplier_profiles sp
        on sp.id = so.supplier_id
       and sp.user_id is not null
       and coalesce(sp.is_deleted,false) = false
     where so.created_at > now() - interval '30 days'
  ), ins as (
    insert into public.notification_log
      (event_key, audience, recipient_id, recipient, channel, status, title, body, deep_link, payload, created_at)
    select 'supplier.order', 'supplier', s.sup_id, s.who, 'in_app', 'sent',
           public._c('sup_inbox.order_title'), public._c('sup_inbox.order_body'),
           '/supplier/orders', jsonb_build_object('entity', s.entity, 'kind', 'order'),
           s.created_at
      from src s
    on conflict do nothing
    returning 1)
  select count(*)::int into v_ord from ins;

  -- 3. A dispute waiting on them.
  with src as (
    select sp.id as sup_id, sp.supplier_name as who, d.id::text as entity, d.created_at
      from public.supplier_disputes d
      join public.supplier_profiles sp
        on sp.supplier_name = d.assigned_supplier
       and sp.user_id is not null
       and coalesce(sp.is_deleted,false) = false
     where d.created_at > now() - interval '30 days'
       and coalesce(d.status,'') not in ('resolved','closed','cancelled')
  ), ins as (
    insert into public.notification_log
      (event_key, audience, recipient_id, recipient, channel, status, title, body, deep_link, payload, created_at)
    select 'supplier.dispute', 'supplier', s.sup_id, s.who, 'in_app', 'sent',
           public._c('sup_inbox.dispute_title'), public._c('sup_inbox.dispute_body'),
           '/supplier/disputes', jsonb_build_object('entity', s.entity, 'kind', 'dispute'),
           s.created_at
      from src s
    on conflict do nothing
    returning 1)
  select count(*)::int into v_dis from ins;

  return jsonb_build_object('ok', true, 'inquiry', v_inq, 'order', v_ord, 'dispute', v_dis);
end $fn$;

revoke all on function public.supplier_notify_sweep() from public;
grant execute on function public.supplier_notify_sweep() to service_role;

-- On the ONE dispatcher, with an offset schedule — never a bare */N (the
-- connection-exhaustion outage of 18 Aug was 35 jobs all starting on minute 0).
insert into cron_task (name, ord, mode, gate_sql, work_sql, enabled, note,
                       base_interval_s, max_interval_s, current_interval_s)
values ('supplier_inapp_notify', 950, 'poll', null,
        'select public.supplier_notify_sweep()', true,
        'CHANGE #465 gap 65 — mints in-app notifications for the 7 suppliers who can log in.',
        300, 1800, 300)
on conflict (name) do nothing;

-- The inbox the shell reads. Badges are counted live; items are the rows.
create or replace function public.supplier_inbox(p_limit int default 30)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $fn$
declare
  v_id    uuid := public.my_supplier_id();
  v_name  text;
  v_items jsonb;
  v_unread int;
  v_orders int;
  v_disp   int;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_supplier',
      'message', public._c('sup_inbox.not_supplier'));
  end if;
  select supplier_name into v_name from public.supplier_profiles where id = v_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',         n.id,
           'kind',       coalesce(n.payload->>'kind',''),
           'title',      coalesce(n.title,''),
           'body',       coalesce(n.body,''),
           'deep_link',  coalesce(n.deep_link,''),
           'is_read',    (n.read_at is not null),
           'when_label', public._ist_stamp(n.created_at))
         order by n.created_at desc), '[]'::jsonb),
         count(*) filter (where n.read_at is null)::int
    into v_items, v_unread
  from (select * from public.notification_log
         where channel = 'in_app' and audience = 'supplier' and recipient_id = v_id
         order by created_at desc limit greatest(coalesce(p_limit,30), 1)) n;

  select count(*)::int into v_orders from public.supplier_orders so
   where so.supplier_id = v_id and coalesce(so.accept_state,'pending') = 'pending';
  select count(*)::int into v_disp from public.supplier_disputes d
   where d.assigned_supplier = v_name
     and coalesce(d.status,'') not in ('resolved','closed','cancelled');

  return jsonb_build_object(
    'ok',        true,
    'title',     public._c('sup_inbox.title'),
    'empty',     public._c('sup_inbox.empty'),
    'empty_note',public._c('sup_inbox.empty_note'),
    'mark_all',  public._c('sup_inbox.mark_all'),
    'unread',    coalesce(v_unread,0),
    -- The tab badges. Counted from the same tables the tabs read, so a badge
    -- can never disagree with the screen it sits on.
    'badges', jsonb_build_object(
      'inquiry',  coalesce(public.supplier_pending_inquiry_count(), 0),
      'orders',   coalesce(v_orders,0),
      'disputes', coalesce(v_disp,0)),
    'items',     v_items);
end $fn$;

revoke all on function public.supplier_inbox(int) from public;
grant execute on function public.supplier_inbox(int) to authenticated, service_role;

create or replace function public.supplier_inbox_mark_read(p_ids bigint[] default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_id uuid := public.my_supplier_id(); n int;
begin
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_supplier',
      'message', public._c('sup_inbox.not_supplier'));
  end if;
  update public.notification_log
     set read_at = now()
   where channel = 'in_app' and audience = 'supplier'
     and recipient_id = v_id and read_at is null
     and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'marked', n);
end $fn$;

revoke all on function public.supplier_inbox_mark_read(bigint[]) from public;
grant execute on function public.supplier_inbox_mark_read(bigint[]) to authenticated, service_role;
