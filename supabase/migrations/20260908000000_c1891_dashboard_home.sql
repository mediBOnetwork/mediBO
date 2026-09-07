-- CMD #1891 — the Dashboard becomes the ONE home for every door that used to
-- hide in the "Also here" strip above Customers, Suppliers and Fulfill.
--
-- The strip (staff_home('customers'|'suppliers'|'fulfill')) was a horizontal
-- scroller of chips: a door you had to already know about to find. Every one
-- of those doors now lands on the Dashboard, in six named sections, and the
-- sections themselves are DATA — feature_registry.dashboard_section says which
-- section a feature belongs to, dashboard_section says what a section is
-- called and in which order it prints. Moving a tile is an UPDATE, never a
-- deploy.
--
-- Idempotent end to end: the merge worker replays this file on live once, and
-- a re-run must be a no-op.

begin;

-- ── 1. the registry learns which dashboard section a feature belongs to ─────
alter table public.feature_registry
  add column if not exists dashboard_section text;
alter table public.feature_registry
  add column if not exists badge_tone text;

do $$
begin
  alter table public.feature_registry
    add constraint feature_registry_dashboard_section_ck
    check (dashboard_section is null or dashboard_section in
      ('needs_now','onboarding','field_growth','delivery','returns_issues','my_work'));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.feature_registry
    add constraint feature_registry_badge_tone_ck
    check (badge_tone is null or badge_tone in ('good','warn','bad','info'));
exception when duplicate_object then null;
end $$;

create index if not exists feature_registry_dashboard_idx
  on public.feature_registry (dashboard_section, sort_order)
  where is_active and dashboard_section is not null;

-- ── 2. the sections are rows, not a CASE in a function ──────────────────────
create table if not exists public.dashboard_section (
  section_key text primary key,
  label_key   text    not null,
  sort_order  int     not null default 100,
  -- needs_now prints ONLY tiles carrying work: a zero badge is not a queue.
  badged_only boolean not null default false,
  -- ...and it is the one section that still prints when it is empty, because
  -- "nothing needs you right now" is an answer. The others simply go away.
  show_when_empty boolean not null default false,
  is_active   boolean not null default true
);

alter table public.dashboard_section
  add column if not exists show_when_empty boolean not null default false;

insert into public.dashboard_section
  (section_key, label_key, sort_order, badged_only, show_when_empty) values
  ('needs_now',      'dashboard_home.section_needs_now',      10, true,  true),
  ('onboarding',     'dashboard_home.section_onboarding',     20, false, false),
  ('field_growth',   'dashboard_home.section_field_growth',   30, false, false),
  ('delivery',       'dashboard_home.section_delivery',       40, false, false),
  ('returns_issues', 'dashboard_home.section_returns_issues', 50, false, false),
  ('my_work',        'dashboard_home.section_my_work',        60, false, false)
on conflict (section_key) do update
  set label_key       = excluded.label_key,
      sort_order      = excluded.sort_order,
      badged_only     = excluded.badged_only,
      show_when_empty = excluded.show_when_empty,
      is_active       = true;

alter table public.dashboard_section enable row level security;
do $$
begin
  create policy dashboard_section_read on public.dashboard_section
    for select to authenticated using (true);
exception when duplicate_object then null;
end $$;
grant select on public.dashboard_section to authenticated, service_role;

-- ── 3. every word on the screen is a row in ui_copy ─────────────────────────
-- `do nothing`: a wording edit made in the app must survive a replay.
insert into public.ui_copy (key, value) values
  ('dashboard_home.section_needs_now',      '"NEEDS YOU NOW"'::jsonb),
  ('dashboard_home.section_onboarding',     '"ONBOARDING"'::jsonb),
  ('dashboard_home.section_field_growth',   '"FIELD & GROWTH"'::jsonb),
  ('dashboard_home.section_delivery',       '"DELIVERY"'::jsonb),
  ('dashboard_home.section_returns_issues', '"RETURNS & ISSUES"'::jsonb),
  ('dashboard_home.section_my_work',        '"MY WORK"'::jsonb),
  ('dashboard_home.title',                  '"All your work"'::jsonb),
  ('dashboard_home.empty_label',            '"Nothing is open to you here yet."'::jsonb),
  ('dashboard_home.needs_now_empty',        '"Nothing needs you right now."'::jsonb),
  ('dashboard_home.section_empty',          '"Nothing here for this login."'::jsonb),
  ('dashboard_home.not_authorized',         '"This console is for staff logins."'::jsonb)
on conflict (key) do nothing;

-- ── 4. which door goes in which section ────────────────────────────────────
-- Every "Also here" entry of Customers / Suppliers / Fulfill, plus the four
-- sub-tabs the spec named (Pending approval x2, Items to review, Ops board,
-- Exceptions, Leads, S Leads, Routes), each with the Dart sub-tab it opens.
update public.feature_registry f
   set dashboard_section = v.section,
       badge_tone        = coalesce(nullif(v.tone,''), f.badge_tone),
       tab_screen        = coalesce(nullif(v.tab, ''), f.tab_screen)
  from (values
    -- 1. needs_now
    ('fulfill.ops_board',           'needs_now',      'warn', ''),
    ('fulfill.exceptions',          'needs_now',      'bad',  ''),
    ('admin.ops_queues',            'needs_now',      'warn', ''),
    ('admin.order_alerts',          'needs_now',      'bad',  ''),
    ('fulfill.order_timeline',      'needs_now',      'info', ''),
    ('admin.cust_tab.pending',      'needs_now',      'warn', 'pendingRegistrations'),
    ('admin.sup_tab.pending',       'needs_now',      'warn', 'pending'),
    ('partner.kyc_review',          'needs_now',      'warn', ''),
    ('admin.sup_tab.staging',       'needs_now',      'warn', 'staging'),
    -- 2. onboarding
    ('admin.add_customer',          'onboarding',     'info', ''),
    ('admin.add_supplier',          'onboarding',     'info', ''),
    ('admin.mr',                    'onboarding',     'info', ''),
    ('admin.companies',             'onboarding',     'info', ''),
    ('admin.unmapped_companies',    'onboarding',     'info', ''),
    ('admin.deletion_requests',     'onboarding',     'warn', ''),
    ('admin.supplier_accounts',     'onboarding',     'info', ''),
    -- 3. field_growth
    ('admin.cust_tab.leads',        'field_growth',   'info', 'leads'),
    ('admin.cust_tab.s_leads',      'field_growth',   'info', 'sLeads'),
    ('admin.cust_tab.routes',       'field_growth',   'info', 'routes'),
    ('partner.workers',             'field_growth',   'info', ''),
    ('partner.staff',               'field_growth',   'info', ''),
    ('admin.reorder',               'field_growth',   'info', ''),
    -- 4. delivery
    ('admin.delivery_partners',     'delivery',       'info', ''),
    ('admin.delivery_waves',        'delivery',       'info', ''),
    ('admin.delivery_ops',          'delivery',       'info', ''),
    ('admin.delivery_extras',       'delivery',       'info', ''),
    ('admin.bags',                  'delivery',       'info', ''),
    -- 5. returns_issues
    ('partner.damage_report',       'returns_issues', 'warn', ''),
    ('admin.returns_refunds',       'returns_issues', 'warn', ''),
    ('partner.supplier_returns',    'returns_issues', 'warn', ''),
    ('admin.order_closure',         'returns_issues', 'warn', ''),
    -- 6. my_work
    ('partner.fulfil_tasks',        'my_work',        'info', ''),
    ('worker.my_tasks',             'my_work',        'info', ''),
    ('partner.documents',           'my_work',        'info', ''),
    ('admin.customer_360',          'my_work',        'info', '')
  ) as v(feature_key, section, tone, tab)
 where f.feature_key = v.feature_key;

-- The other customer / supplier sub-tabs are not dashboard tiles, but the
-- shell still needs the sub-tab name when one is opened from anywhere else.
update public.feature_registry f
   set tab_screen = v.tab
  from (values
    ('admin.cust_tab.customers', 'approvedCustomers'),
    ('admin.cust_tab.cart',      'cartNotOrdered'),
    ('admin.sup_tab.suppliers',  'suppliers'),
    ('admin.sup_tab.leads',      'leads')
  ) as v(feature_key, tab)
 where f.feature_key = v.feature_key
   and coalesce(f.tab_screen,'') = '';

-- ── 5. the badges needs_now runs on ────────────────────────────────────────
-- A needs_now tile with no badge source can never print, by design: the
-- section is the queue, not the menu.
update public.feature_registry f
   set badge_source = v.src,
       badge_noun   = coalesce(nullif(f.badge_noun,''), v.noun)
  from (values
    ('fulfill.ops_board',      'dash_ops_board',    'open orders'),
    ('fulfill.exceptions',     'dash_exceptions',   'count exceptions'),
    ('admin.ops_queues',       'dash_stuck_work',   'stuck'),
    ('admin.cust_tab.pending', 'pending_customers', 'to approve'),
    ('admin.sup_tab.pending',  'dash_sup_pending',  'to approve'),
    ('partner.kyc_review',     'dash_kyc_review',   'to verify'),
    ('admin.sup_tab.staging',  'dash_items_review', 'to review'),
    ('admin.order_closure',    'pending_orders',    'to close')
  ) as v(feature_key, src, noun)
 where f.feature_key = v.feature_key
   and coalesce(f.badge_source,'') is distinct from v.src;

update public.feature_registry
   set badge_noun = 'to delete'
 where feature_key = 'admin.deletion_requests' and coalesce(badge_noun,'') = '';

-- ── 6. the counts, in the caller's own zone and as of the header's date ────
create or replace function public.dashboard_badge_counts()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  -- The header picker is the ONLY place zone and date live. NULL zone is a
  -- super admin looking at every zone; the date is an "as of" ceiling, so a
  -- back-dated header never counts work that did not exist yet.
  v_zone smallint := public.admin_active_zone();
  v_date date     := public.admin_active_date();
  v_end  timestamptz;
  v_base jsonb := '{}'::jsonb;
begin
  v_end := case when v_date is null then null
                else ((v_date + 1)::timestamp at time zone 'Asia/Kolkata') end;
  begin
    v_base := public.nav_badge_counts();
  exception when others then v_base := '{}'::jsonb;
  end;

  return v_base || jsonb_build_object(
    'dash_ops_board', (
      select count(*) from public.orders o
       where o.closed_at is null
         and (v_zone is null or o.zone_id = v_zone)
         and (v_end is null or o.created_at < v_end)),
    'dash_exceptions', (
      select count(*) from public.order_items oi
       where oi.count_diff is not null and oi.count_diff <> 0
         and (v_zone is null or oi.zone_id = v_zone)
         and (v_end is null or oi.created_at < v_end)),
    'dash_stuck_work', (
      select count(*) from public.pending_bills pb
       where pb.scan_status = 'error'
         and (v_end is null or pb.created_at < v_end)),
    'order_alerts', (
      select count(*) from public.order_alert a
       where a.actioned_at is null
         and (v_zone is null or a.zone_id = v_zone)
         and (v_end is null or a.created_at < v_end)),
    'pending_customers', (
      select count(*) from public.pharmacy_profiles p
       where coalesce(p.approved,false) = false
         and (v_zone is null or p.zone_id = v_zone)
         and (v_end is null or p.created_at < v_end)),
    'dash_sup_pending', (
      select count(*) from public.supplier_profiles s
       where coalesce(s.approved,false) = false
         and coalesce(s.is_deleted,false) = false
         and (v_zone is null or s.zone_id = v_zone)
         and (v_end is null or s.created_at < v_end)),
    'dash_kyc_review', (
      select count(*) from public.kyc_documents k
       where k.status = 'pending'
         and (v_zone is null or k.zone_id = v_zone)
         and (v_end is null or k.created_at < v_end)),
    'dash_items_review',
      (select count(*) from public.supplier_pending_companies c
        where c.status = 'pending' and (v_end is null or c.created_at < v_end))
      + (select count(*) from public.supplier_pending_medicines m
          where m.status = 'pending' and (v_end is null or m.created_at < v_end))
  );
end
$function$;

grant execute on function public.dashboard_badge_counts() to authenticated, service_role;

-- ── 7. what THIS login may see ─────────────────────────────────────────────
-- _staff_visible() only ever answers for the three dashboard surfaces; the
-- Dashboard also draws sub-tabs of Customers, Suppliers and Fulfill, so the
-- fence is repeated here over every surface instead of widened there (the
-- strip and the tabs still read the old one, unchanged).
create or replace function public._dashboard_visible()
returns table(
  feature_key text, label text, icon_key text, route_key text, sort_order integer,
  category text, surface text, badge_source text, badge_noun text, badge_tone text,
  deep_link text, description text, dashboard_section text, tab_screen text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with me as (
    select coalesce(public.get_my_role(),'none') as role,
           public.my_partner_id() as partner,
           exists (select 1 from public.admins a
                    where a.id::text = public.my_admin_id()::text
                      and coalesce(a.is_super,false)) as is_super
  ), acc as (select * from public._staff_access())
  select f.feature_key, f.label, f.icon_key, f.route_key, f.sort_order,
         f.category, f.surface, f.badge_source, f.badge_noun, f.badge_tone,
         f.deep_link, f.description, f.dashboard_section, f.tab_screen
    from public.feature_registry f
    cross join me
    left join acc on acc.feature_key = coalesce(nullif(f.canonical_key,''), f.feature_key)
   where f.is_active
     and coalesce(f.dashboard_section,'') <> ''
     and coalesce(f.route_key,'') <> ''
     -- A partner login is the MATRIX's business: partner_eligible says the
     -- feature MAY be granted to a partner, the access map says it WAS.
     and case when me.partner is not null
              then f.partner_eligible and coalesce(acc.level,'none') <> 'none'
              when f.surface = 'dev_tools' then me.role = 'super_admin' and me.role = any (f.roles_allowed)
              else me.role = any (f.roles_allowed)
                   and (me.is_super or coalesce(acc.level,'none') <> 'none') end
$function$;

grant execute on function public._dashboard_visible() to authenticated, service_role;

-- ── 8. dashboard_home() — the six sections, written ───────────────────────
create or replace function public.dashboard_home()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_uid      uuid := auth.uid();
  v_role     text := coalesce(public.get_my_role(),'none');
  v_counts   jsonb := '{}'::jsonb;
  v_sections jsonb := '[]'::jsonb;
  v_n        int := 0;
begin
  if v_uid is null or v_role not in ('admin','super_admin','partner') then
    return jsonb_build_object(
      'ok', false, 'error', 'not_authorized',
      'sections', '[]'::jsonb, 'items_count', 0,
      'title', public._c('dashboard_home.title'),
      'message', public._c('dashboard_home.not_authorized'),
      'empty_label', public._c('dashboard_home.empty_label'));
  end if;

  begin
    v_counts := public.dashboard_badge_counts();
  exception when others then v_counts := '{}'::jsonb;
  end;

  with tile as (
    select v.dashboard_section as sec,
           v.sort_order,
           v.label,
           coalesce((v_counts ->> v.badge_source)::bigint, 0) as badge_count,
           jsonb_build_object(
             'feature_key', v.feature_key,
             'label',       v.label,
             'icon_key',    v.icon_key,
             'icon_letter', upper(left(v.label,1)),
             'route_key',   v.route_key,
             'deep_link',   v.deep_link,
             'tool_key',    case when v.surface = 'dev_tools' then v.route_key else null end,
             -- The sub-tab a Customers / Suppliers tile opens, and the page
             -- that hosts it. Both are the registry's answer: a tile that
             -- moves to another host is an UPDATE.
             'tab_host',    case v.surface when 'customer_tab' then 'customers'
                                           when 'supplier_tab' then 'suppliers'
                                           else null end,
             'tab_key',     nullif(v.tab_screen,''),
             'description', coalesce(v.description,''),
             'badge_count', coalesce((v_counts ->> v.badge_source)::bigint, 0),
             'badge_label', case when coalesce((v_counts ->> v.badge_source)::bigint,0) > 0
                                 then (v_counts ->> v.badge_source) || ' ' ||
                                      coalesce(nullif(v.badge_noun,''), lower(v.label))
                                 else null end,
             'badge_tone',  coalesce(nullif(v.badge_tone,''),
                              case when v.dashboard_section = 'needs_now' then 'warn' else 'info' end)
           ) as js
      from public._dashboard_visible() v
  ), kept as (
    select t.*, s.section_key, s.sort_order as sec_sort, s.label_key, s.show_when_empty
      from public.dashboard_section s
      left join tile t
        on t.sec = s.section_key
       and (not s.badged_only or t.badge_count > 0)
     where s.is_active
  )
  -- ALL six sections, always, in their own order: the section list is the
  -- contract. `items` may be empty; `show_when_empty` says whether that
  -- section still prints, and it is a row in dashboard_section, not a rule
  -- in Dart.
  select coalesce(jsonb_agg(x.sec order by x.sec_sort), '[]'::jsonb),
         coalesce(sum(x.n)::int, 0)
    into v_sections, v_n
    from (
      select k.sec_sort,
             count(k.js)::int as n,
             jsonb_build_object(
               'key',   k.section_key,
               'label', public._c(k.label_key),
               'show_when_empty', k.show_when_empty,
               'empty_label', case when k.section_key = 'needs_now'
                                   then public._c('dashboard_home.needs_now_empty')
                                   else public._c('dashboard_home.section_empty') end,
               'items', coalesce(
                  jsonb_agg(k.js order by k.badge_count desc, k.sort_order, k.label)
                    filter (where k.js is not null), '[]'::jsonb)
             ) as sec
        from kept k
       group by k.section_key, k.sec_sort, k.label_key, k.show_when_empty
    ) x;

  return jsonb_build_object(
    'ok', true,
    'title',            public._c('dashboard_home.title'),
    'empty_label',      public._c('dashboard_home.empty_label'),
    'needs_now_empty',  public._c('dashboard_home.needs_now_empty'),
    'sections',         v_sections,
    'items_count',      v_n);
end
$function$;

grant execute on function public.dashboard_home() to authenticated, service_role;

commit;
