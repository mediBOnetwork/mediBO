-- CHANGE #643 (2/5) — the publication is DATA, not a deploy.
--
-- supabase_realtime carried 29 tables. Realtime decodes the WAL once per
-- published table per subscriber, so a table that is published but whose
-- changes nobody needs instantly is pure cost: 7.44M realtime messages last
-- cycle (149% of the 5M allowance), 95.9% of them postgres_changes.
--
-- The fix is not a shorter hard-coded list in Dart — it is a registry the
-- BACKEND owns. realtime_table_registry says, per table, whether the client may
-- open a live channel or must poll and how often; realtime_plan() hands that to
-- the app, which renders it verbatim (lib/services/live_feed.dart); and
-- realtime_publication_sync() makes the publication match the registry.
-- Trimming further, or putting a table back, is one UPDATE — never a deploy.

create table if not exists public.realtime_table_registry (
  table_name      text primary key,
  live            boolean     not null default false,
  filter_required boolean     not null default false,
  poll_seconds    integer     not null default 30,
  surface         text        not null default '',
  reason          text        not null default '',
  updated_at      timestamptz not null default now()
);

alter table public.realtime_table_registry enable row level security;

drop policy if exists rtr_read on public.realtime_table_registry;
create policy rtr_read on public.realtime_table_registry for select using (true);

comment on table public.realtime_table_registry is
  'CHANGE #643: which tables the app may open a postgres_changes channel on. '
  'live=false means the surface polls every poll_seconds instead. '
  'realtime_publication_sync() makes supabase_realtime match live=true.';

-- ---------------------------------------------------------------------------
-- Seed. live=true is reserved for surfaces where a human is waiting on the
-- change and a 30 s delay would be a bug — live counting, live chat, the
-- cart the same buyer has open on two devices, and an instant sign-out.
-- Everything else — every admin list feed — polls.
-- ---------------------------------------------------------------------------
insert into public.realtime_table_registry
  (table_name, live, filter_required, poll_seconds, surface, reason) values
  ('whatsapp_messages',   true,  false, 30, 'wa_chat/wa_home',
     'Live inbound chat: a reply must land while the operator is typing.'),
  ('auth_force_logout',   true,  true,  30, 'user_state',
     'Instant sign-out. Always filtered to one user_id by the backend payload.'),
  ('cart_items',          true,  true,  30, 'cart_model/checkout',
     'One buyer, two devices: the cart must agree instantly.'),
  ('order_items',         true,  false, 30, 'fulfil/counting',
     'Warehouse counting is cross-device by design; item state is the ledger.'),
  ('bag_item_counts',     true,  false, 30, 'fulfil/bags',
     'Counting into a bag on one device must show on the packing device.'),
  ('supplier_count_mode', true,  false, 30, 'fulfil/collect',
     'Shop-vs-warehouse stage flips have to be seen by the other device.'),
  ('bags',                true,  false, 30, 'fulfil/bags',
     'Bag full/empty and arrivals_confirmed drive what the next scan may do.'),
  ('pharmacy_profiles',   true,  true,  30, 'user_state',
     'Approval flip unlocks ordering. Filtered to the signed-in account id.')
on conflict (table_name) do update
  set live            = excluded.live,
      filter_required = excluded.filter_required,
      poll_seconds    = excluded.poll_seconds,
      surface         = excluded.surface,
      reason          = excluded.reason,
      updated_at      = now();

-- Everything the app subscribes to today that is NOT in the eight above.
-- These become 30 s polls; delivery tracking keeps a tighter 15 s.
insert into public.realtime_table_registry
  (table_name, live, filter_required, poll_seconds, surface, reason) values
  ('orders',                          false, false, 30, 'admin/orders/fulfil',
     'High-churn admin feed. Polled: a list refresh 30 s later is not a bug.'),
  ('inquiry',                         false, false, 30, 'admin/supplier', 'High-churn admin feed.'),
  ('inquiry_forms',                   false, false, 30, 'admin/supplier', 'High-churn admin feed.'),
  ('supplier_orders',                 false, false, 30, 'admin/supplier', 'Admin list feed.'),
  ('supplier_disputes',               false, false, 30, 'supplier/disputes', 'List feed.'),
  ('supplier_profiles',               false, false, 30, 'admin/supplier', 'Admin list feed.'),
  ('payment_claims',                  false, false, 30, 'admin/customer', 'Admin list feed.'),
  ('pending_orders',                  false, false, 30, 'admin/customer', 'Admin list feed.'),
  ('pending_bills',                   false, false, 30, 'admin/billing', 'No subscriber in the app.'),
  ('route_plans',                     false, false, 30, 'admin/customer', 'Admin list feed.'),
  ('lead_scrape_runs',                false, false, 30, 'admin/customer', 'Admin list feed.'),
  ('admin_date_scope',                false, false, 30, 'admin/date scope', 'One row, changes rarely.'),
  ('order_hours',                     false, false, 30, 'order hours', 'One row, changes rarely.'),
  ('deliveries',                      false, false, 30, 'delivery', 'No subscriber in the app.'),
  ('delivery_partner_locations',      false, false, 15, 'delivery/tracking',
     'Rider position. 15 s polling is inside the useful resolution of a road move.'),
  ('voice_clip_mentions',             false, false, 30, 'fulfil/voice', 'Refetched with the window.'),
  ('bag_sessions',                    false, false, 30, 'fulfil/bags', 'Derived from bags/bag_item_counts.'),
  ('bag_supplier_usage',              false, false, 30, 'fulfil/bags', 'Derived from bags/bag_item_counts.'),
  ('bag_allocations',                 false, false, 30, 'fulfil/bags', 'No subscriber in the app.'),
  ('bulk_ocr_jobs',                   false, false, 30, 'admin/bulk upload', 'No subscriber in the app.'),
  ('user_profiles',                   false, false, 30, '-', 'No subscriber in the app.'),
  ('order_alert',                     false, false, 30, 'admin/alerts', 'Never published; the channel got nothing.'),
  ('supplier_leads',                  false, false, 30, 'admin/supplier', 'Never published; the channel got nothing.'),
  ('company_profiles',                false, false, 30, 'admin/alerts', 'Never published; the channel got nothing.'),
  ('mr_registrations',                false, false, 30, 'admin/alerts', 'Never published; the channel got nothing.'),
  ('delivery_partner_registrations',  false, false, 30, 'admin/alerts', 'Never published; the channel got nothing.')
on conflict (table_name) do update
  set live            = excluded.live,
      filter_required = excluded.filter_required,
      poll_seconds    = excluded.poll_seconds,
      surface         = excluded.surface,
      reason          = excluded.reason,
      updated_at      = now();

-- ---------------------------------------------------------------------------
-- Make the publication match the registry, then (re)install the no-op guard.
-- ---------------------------------------------------------------------------
create or replace function public.realtime_publication_sync()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r record; v_added text[] := '{}'; v_dropped text[] := '{}'; v_trg int;
begin
  -- drop anything published that the registry does not mark live
  for r in
    select pt.tablename
    from pg_publication_tables pt
    left join public.realtime_table_registry g on g.table_name = pt.tablename
    where pt.pubname = 'supabase_realtime'
      and pt.schemaname = 'public'
      and coalesce(g.live, false) = false
  loop
    execute format('alter publication supabase_realtime drop table public.%I', r.tablename);
    v_dropped := v_dropped || r.tablename;
  end loop;

  -- add anything the registry marks live that is not published yet
  for r in
    select g.table_name
    from public.realtime_table_registry g
    where g.live
      and to_regclass('public.' || quote_ident(g.table_name)) is not null
      and not exists (
        select 1 from pg_publication_tables pt
        where pt.pubname = 'supabase_realtime'
          and pt.schemaname = 'public' and pt.tablename = g.table_name)
  loop
    execute format('alter publication supabase_realtime add table public.%I', r.table_name);
    v_added := v_added || r.table_name;
  end loop;

  v_trg := public.realtime_suppress_noop_install();

  return jsonb_build_object(
    'ok', true,
    'added', to_jsonb(v_added),
    'dropped', to_jsonb(v_dropped),
    'noop_triggers_added', v_trg,
    'published', (select count(*) from pg_publication_tables
                   where pubname = 'supabase_realtime'));
end $$;

grant execute on function public.realtime_publication_sync() to service_role;

-- ---------------------------------------------------------------------------
-- realtime_plan() — what the client is allowed to do, rendered verbatim.
-- ---------------------------------------------------------------------------
create or replace function public.realtime_plan()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ok', true,
    'max_live', 8,
    'default_poll_seconds', 30,
    'live_count', (select count(*) from public.realtime_table_registry where live),
    'tables', coalesce((
      select jsonb_object_agg(g.table_name, jsonb_build_object(
        'mode', case when g.live then 'live' else 'poll' end,
        'filter_required', g.filter_required,
        'poll_seconds', g.poll_seconds,
        'surface', g.surface,
        'reason', g.reason))
      from public.realtime_table_registry g), '{}'::jsonb));
$$;

grant execute on function public.realtime_plan() to anon, authenticated, service_role;

select public.realtime_publication_sync();
