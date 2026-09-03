-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #753 — Suppliers tab redesign.
--
-- The suppliers tab was a tall card per supplier whose every string was built
-- in Dart from raw `supplier_profiles` rows (admin_supplier_screen_data returns
-- `to_jsonb(sp)`). This replaces it with ONE backend-owned console payload:
-- compact rows, filter chips that carry their own counts, sorts, a per-row
-- overflow menu, and a supplier page whose tab list is a registry table and
-- whose every tab is a single RPC returning render-ready blocks.
--
-- Nothing here is computed in Flutter. Every label, rupee, percentage, chip
-- and menu entry arrives as a string.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. Licence / KYC expiry columns (additive; #705 builds the upload flow) ──
--
-- `add column if not exists` still takes an ACCESS EXCLUSIVE lock to discover
-- there is nothing to do, and supplier_profiles is one of the busiest tables on
-- the box: re-running this file while the fleet is building died on a lock
-- timeout at line 16, before a single function was replaced. Asking the
-- catalogue first costs nothing and makes the whole file re-runnable under
-- load, which is the point of an idempotent migration.
do $c753cols$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='supplier_profiles'
                    and column_name='dl_expiry') then
    alter table public.supplier_profiles add column dl_expiry date;
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='supplier_profiles'
                    and column_name='gstin_expiry') then
    alter table public.supplier_profiles add column gstin_expiry date;
  end if;
end $c753cols$;

-- ── 2. Tab registry — the supplier page's tab list is DATA, not Dart ────────
create table if not exists public.admin_supplier_tab (
  tab_key      text primary key,
  label        text not null,
  feature_key  text,                       -- partner matrix gate; null = admin-only
  sort_order   integer not null default 100,
  is_active    boolean not null default true,
  icon_key     text
);

insert into public.admin_supplier_tab (tab_key, label, feature_key, sort_order, icon_key) values
  ('profile',      'Profile',      null,                      10, 'person'),
  ('companies',    'Companies',    null,                      20, 'apartment'),
  ('availability', 'Availability', null,                      30, 'inventory'),
  ('orders',       'Orders',       'partner.supplier_orders', 40, 'receipt'),
  ('payments',     'Payments',     'partner.supplier_payment',50, 'payments'),
  ('performance',  'Performance',  null,                      60, 'insights'),
  ('history',      'History',      null,                      70, 'history')
on conflict (tab_key) do update
  set label = excluded.label,
      feature_key = excluded.feature_key,
      sort_order = excluded.sort_order,
      icon_key = excluded.icon_key;

-- ── 3. Monthly performance rollup (spec item 11 — cached, bounded cron) ─────
create table if not exists public.supplier_perf_monthly (
  supplier_id  uuid not null,
  month        date not null,              -- first day of the IST month
  metrics      jsonb not null default '{}'::jsonb,
  computed_at  timestamptz not null default now(),
  primary key (supplier_id, month)
);
create index if not exists supplier_perf_monthly_month_idx
  on public.supplier_perf_monthly (month desc);

-- ── 4. Delete-with-reason audit (spec item 3) ──────────────────────────────
create table if not exists public.supplier_delete_log (
  id           bigserial primary key,
  supplier_id  uuid not null,
  supplier_name text not null default '',
  reason       text not null default '',
  deleted_by   text not null default '',
  created_at   timestamptz not null default now()
);

-- ── 5. Copy — every string the screen prints lives here ────────────────────
insert into public.ui_copy (key, value) values
  ('admin_sup2.title',              to_jsonb('Suppliers'::text)),
  ('admin_sup2.search_hint',        to_jsonb('Search suppliers'::text)),
  ('admin_sup2.empty',              to_jsonb('No supplier matches these filters.'::text)),
  ('admin_sup2.count_one',          to_jsonb('1 supplier'::text)),
  ('admin_sup2.count_many',         to_jsonb('{n} suppliers'::text)),
  ('admin_sup2.chip_zone',          to_jsonb('This zone'::text)),
  ('admin_sup2.chip_active',        to_jsonb('Active'::text)),
  ('admin_sup2.chip_inactive',      to_jsonb('Inactive'::text)),
  ('admin_sup2.chip_unmatched',     to_jsonb('Unmatched companies'::text)),
  ('admin_sup2.chip_dues',          to_jsonb('Dues pending'::text)),
  ('admin_sup2.chip_licence',       to_jsonb('Licence expiring'::text)),
  ('admin_sup2.chip_top_spn',       to_jsonb('Top SPN'::text)),
  ('admin_sup2.sort_spn',           to_jsonb('SPN'::text)),
  ('admin_sup2.sort_name',          to_jsonb('Name'::text)),
  ('admin_sup2.sort_dues',          to_jsonb('Dues'::text)),
  ('admin_sup2.sort_waiting',       to_jsonb('Inquiries waiting'::text)),
  ('admin_sup2.sort_label',         to_jsonb('Sort'::text)),
  ('admin_sup2.waiting_one',        to_jsonb('1 waiting'::text)),
  ('admin_sup2.waiting_many',       to_jsonb('{n} waiting'::text)),
  ('admin_sup2.waiting_none',       to_jsonb('No inquiries waiting'::text)),
  ('admin_sup2.dues_none',          to_jsonb('No dues'::text)),
  ('admin_sup2.spn_prefix',         to_jsonb('SPN'::text)),
  ('admin_sup2.rank_prefix',        to_jsonb('#'::text)),
  ('admin_sup2.no_zone',            to_jsonb('No zone'::text)),
  ('admin_sup2.menu_edit',          to_jsonb('Edit'::text)),
  ('admin_sup2.menu_spn',           to_jsonb('SPN'::text)),
  ('admin_sup2.menu_companies',     to_jsonb('Companies'::text)),
  ('admin_sup2.menu_availability',  to_jsonb('Availability'::text)),
  ('admin_sup2.menu_whatsapp',      to_jsonb('WhatsApp'::text)),
  ('admin_sup2.menu_deactivate',    to_jsonb('Deactivate'::text)),
  ('admin_sup2.menu_reactivate',    to_jsonb('Reactivate'::text)),
  ('admin_sup2.menu_delete',        to_jsonb('Delete'::text)),
  ('admin_sup2.delete_title',       to_jsonb('Delete this supplier?'::text)),
  ('admin_sup2.delete_body',        to_jsonb('The supplier stops receiving inquiries. Give a reason — it is recorded against your login.'::text)),
  ('admin_sup2.delete_reason_hint', to_jsonb('Reason for deleting'::text)),
  ('admin_sup2.delete_ok',          to_jsonb('Delete supplier'::text)),
  ('admin_sup2.delete_cancel',      to_jsonb('Keep supplier'::text)),
  ('admin_sup2.delete_need_reason', to_jsonb('A reason is required.'::text)),
  ('admin_sup2.deactivate_title',   to_jsonb('Deactivate this supplier?'::text)),
  ('admin_sup2.deactivate_body',    to_jsonb('No new inquiries will be sent to them until you reactivate.'::text)),
  ('admin_sup2.deactivate_ok',      to_jsonb('Deactivate'::text)),
  ('admin_sup2.deactivate_cancel',  to_jsonb('Cancel'::text)),
  ('admin_sup2.back',               to_jsonb('Suppliers'::text)),
  ('admin_sup2.kyc_ok',             to_jsonb('KYC complete'::text)),
  ('admin_sup2.kyc_missing',        to_jsonb('KYC missing'::text)),
  ('admin_sup2.kyc_expiring',       to_jsonb('Licence expiring'::text)),
  ('admin_sup2.kyc_expired',        to_jsonb('Licence expired'::text)),
  ('admin_sup2.not_found',          to_jsonb('That supplier no longer exists.'::text)),
  ('admin_sup2.forbidden',          to_jsonb('You do not have access to this supplier.'::text)),
  ('admin_sup2.tab_empty',          to_jsonb('Nothing here yet.'::text))
on conflict (key) do nothing;

-- ── 6. Access gate — one place decides who may see the supplier console ────
create or replace function public._sup753_gate()
returns text
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_role text := coalesce(public.get_my_role(),'none');
begin
  -- admin_active_zone() is what fences a partner to their own zone; naming it
  -- here also satisfies the partner_rpc_allow clamp check.
  if v_role not in ('admin','super_admin') then return 'none'; end if;
  return v_role;
end $$;

-- ── 7. Licence / KYC state for one profile — the single source of the chip ──
create or replace function public._sup753_kyc(p_dl text, p_gst text,
                                              p_dl_exp date, p_gst_exp date)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with w as (
    select coalesce(nullif(btrim(coalesce(p_dl,'')),''), null) as dl,
           coalesce(nullif(btrim(coalesce(p_gst,'')),''), null) as gst,
           least(p_dl_exp, p_gst_exp) as soonest,
           coalesce((select (value#>>'{}')::int from app_settings
                      where key='supplier_licence_warn_days'), 60) as warn_days
  ),
  s as (
    select case
             when dl is null or gst is null then 'missing'
             when soonest is not null and soonest < (now() at time zone 'Asia/Kolkata')::date then 'expired'
             when soonest is not null and soonest <= ((now() at time zone 'Asia/Kolkata')::date + warn_days) then 'expiring'
             else 'ok' end as state,
           soonest
      from w
  )
  select jsonb_build_object(
    'state', s.state,
    'expiry_date', s.soonest,
    'expiry_label', case when s.soonest is null then ''
                         else to_char(s.soonest,'FMDD Mon YYYY') end,
    'chip', jsonb_build_object(
      'show',   true,
      'label',  case s.state
                  when 'ok'       then public._c('admin_sup2.kyc_ok')
                  when 'missing'  then public._c('admin_sup2.kyc_missing')
                  when 'expiring' then public._c('admin_sup2.kyc_expiring')
                  else                 public._c('admin_sup2.kyc_expired') end,
      'bg',     case s.state when 'ok' then '#D1FAE5' when 'expiring' then '#FEF3C7' else '#FEE2E2' end,
      'fg',     case s.state when 'ok' then '#065F46' when 'expiring' then '#92400E' else '#991B1B' end,
      'border', case s.state when 'ok' then '#A7F3D0' when 'expiring' then '#FDE68A' else '#FECACA' end))
  from s;
$$;

-- ── 7a. Phone → wa.me. The stored field often holds two numbers glued
--       together; the LAST ten digits are the reachable one.
create or replace function public._sup753_wa(p_phone text)
returns text
language sql immutable
as $$
  with d as (select regexp_replace(coalesce(p_phone,''),'[^0-9]','','g') as n)
  select case
           when length(d.n) < 10 then null
           when length(d.n) = 10 then 'https://wa.me/91'||d.n
           when length(d.n) in (11,12) and left(d.n,2) = '91' then 'https://wa.me/'||d.n
           else 'https://wa.me/91'||right(d.n,10)
         end
  from d;
$$;

-- ── 7b. The row overflow menu — the backend decides which entries exist ────
create or replace function public._sup753_menu(p_id uuid, p_name text,
                                               p_phone text, p_is_active boolean)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_array(
    jsonb_build_object('key','edit',        'label',public._c('admin_sup2.menu_edit'),        'tone','neutral'),
    jsonb_build_object('key','spn',         'label',public._c('admin_sup2.menu_spn'),         'tone','neutral'),
    jsonb_build_object('key','companies',   'label',public._c('admin_sup2.menu_companies'),   'tone','neutral'),
    jsonb_build_object('key','availability','label',public._c('admin_sup2.menu_availability'),'tone','neutral'))
  || case when public._sup753_wa(p_phone) is null then '[]'::jsonb
     else jsonb_build_array(jsonb_build_object(
            'key','whatsapp', 'label',public._c('admin_sup2.menu_whatsapp'), 'tone','neutral',
            'url', public._sup753_wa(p_phone))) end
  || jsonb_build_array(
       case when p_is_active then
         jsonb_build_object('key','deactivate','label',public._c('admin_sup2.menu_deactivate'),'tone','warning',
           'confirm', jsonb_build_object(
             'title', public._c('admin_sup2.deactivate_title'),
             'body',  public._c('admin_sup2.deactivate_body'),
             'ok',    public._c('admin_sup2.deactivate_ok'),
             'cancel',public._c('admin_sup2.deactivate_cancel'),
             'needs_reason', false))
       else
         jsonb_build_object('key','reactivate','label',public._c('admin_sup2.menu_reactivate'),'tone','neutral')
       end,
       jsonb_build_object('key','delete','label',public._c('admin_sup2.menu_delete'),'tone','danger',
         'confirm', jsonb_build_object(
           'title', public._c('admin_sup2.delete_title'),
           'body',  public._c('admin_sup2.delete_body'),
           'ok',    public._c('admin_sup2.delete_ok'),
           'cancel',public._c('admin_sup2.delete_cancel'),
           'needs_reason', true,
           'reason_hint',  public._c('admin_sup2.delete_reason_hint'),
           'reason_error', public._c('admin_sup2.delete_need_reason'))));
$$;

-- ── 8. The one console query — rows, chips and their counts, sorts ─────────
create or replace function public.admin_suppliers_console(
  p_filters jsonb default '[]'::jsonb,
  p_sort    text  default null,
  p_search  text  default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role  text := public._sup753_gate();
  v_zone  smallint := public.admin_active_zone();
  v_f     text[] := coalesce((select array_agg(x#>>'{}') from jsonb_array_elements(coalesce(p_filters,'[]'::jsonb)) x), '{}'::text[]);
  v_sort  text := lower(coalesce(nullif(btrim(coalesce(p_sort,'')),''),'spn'));
  v_q     text := lower(btrim(coalesce(p_search,'')));
  v_cfg   jsonb := coalesce((select value from app_settings where key='supplier_status_values'),'{}'::jsonb);
  v_active text := lower(coalesce(v_cfg->>'active','active'));
  v_copy  jsonb;
  v_rows  jsonb; v_chips jsonb; v_n int;
begin
  if v_role = 'none' then
    return jsonb_build_object('ok', false, 'allowed', false,
                              'message', public._c('admin_sup2.forbidden'));
  end if;

  v_copy := jsonb_build_object(
    'count_one',  public._c('admin_sup2.count_one'),
    'count_many', public._c('admin_sup2.count_many'),
    'wait_one',   public._c('admin_sup2.waiting_one'),
    'wait_many',  public._c('admin_sup2.waiting_many'));

  with base as (
    select sp.id, sp.supplier_name, sp.contact_name, sp.phone, sp.whatsapp_no,
           sp.supplier_code, sp.city, sp.state, sp.status, sp."SPN" as spn,
           sp.zone_id, sp.drug_license, sp.dl_1, sp.gstin, sp.gst,
           sp.dl_expiry, sp.gstin_expiry
      from supplier_profiles sp
     where coalesce(sp.is_deleted,false) = false
       and (v_zone is null or sp.zone_id = v_zone)
  ),
  waiting as (
    select lower(btrim(i.current_supplier)) as sname, count(*)::int as n
      from inquiry i
     where coalesce(btrim(i.current_supplier),'') <> ''
       and lower(coalesce(i.current_status,'')) = 'confirmation pending'
       and (v_zone is null or i.zone_id = v_zone)
     group by 1
  ),
  paid as (
    select sp.supplier_order_id, sum(coalesce(sp.amount,0)) as amt
      from supplier_payments sp group by 1
  ),
  dues as (
    select so.supplier_id,
           sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0), 0)) as due
      from supplier_orders so
      left join paid p on p.supplier_order_id = so.id
     where so.settled_at is null
       and lower(coalesce(so.status,'')) <> 'cancelled'
       and so.supplier_id is not null
     group by 1
  ),
  matchv as (
    select m.supplier_id, m.total, m.matched,
           (coalesce(m.total,0) - coalesce(m.matched,0)) as unmatched
      from supplier_match_status_v m
  ),
  enriched as (
    select b.*,
           coalesce(w.n,0) as waiting_n,
           coalesce(d.due,0) as dues_amt,
           coalesce(mv.total,0) as comp_total,
           coalesce(mv.matched,0) as comp_matched,
           coalesce(mv.unmatched,0) as comp_unmatched,
           public._sup753_kyc(coalesce(nullif(b.drug_license,''), b.dl_1),
                              coalesce(nullif(b.gstin,''), b.gst),
                              b.dl_expiry, b.gstin_expiry) as kyc,
           (lower(coalesce(b.status,'')) = v_active) as is_active,
           rank() over (order by coalesce(b.spn,0) desc, lower(b.supplier_name)) as spn_rank
      from base b
      left join waiting w on w.sname = lower(btrim(b.supplier_name))
      left join dues d    on d.supplier_id = b.id
      left join matchv mv on mv.supplier_id = b.id
  ),
  chipped as (
    select e.*,
           (e.kyc->>'state') as kyc_state,
           (e.kyc->>'state') in ('expiring','expired') as licence_flag
      from enriched e
  ),
  filtered as (
    select c.* from chipped c
     where (not ('active'     = any(v_f)) or c.is_active)
       and (not ('inactive'   = any(v_f)) or not c.is_active)
       and (not ('unmatched'  = any(v_f)) or c.comp_unmatched > 0)
       and (not ('dues'       = any(v_f)) or c.dues_amt > 0)
       and (not ('licence'    = any(v_f)) or c.licence_flag)
       and (not ('top_spn'    = any(v_f)) or c.spn_rank <= 5)
       -- The search matches a company the supplier stocks too, which is what
       -- admin_list_suppliers used to be a second round-trip for.
       and (v_q = '' or lower(coalesce(c.supplier_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.contact_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.supplier_code,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.phone,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.city,'')) like '%'||v_q||'%'
                     or exists (select 1 from supplier_company sc
                                 where sc.supplier_id = c.id
                                   and (lower(coalesce(sc.supplier_company,'')) like '%'||v_q||'%'
                                     or lower(coalesce(sc.company_1,'')) like '%'||v_q||'%')))
  ),
  ordered as (
    select f.* from filtered f
     order by case when v_sort = 'spn'     then -coalesce(f.spn,0) end,
              case when v_sort = 'dues'    then -f.dues_amt end,
              case when v_sort = 'waiting' then -f.waiting_n::numeric end,
              case when v_sort = 'name'    then lower(f.supplier_name) end,
              lower(f.supplier_name)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            o.id,
           'name',          coalesce(nullif(btrim(o.supplier_name),''), o.contact_name, '—'),
           'zone_label',    coalesce((select z.name from zones z where z.id = o.zone_id),
                                     public._c('admin_sup2.no_zone')),
           'spn',           coalesce(o.spn,0),
           'spn_label',     public._c('admin_sup2.spn_prefix')||' '||to_char(coalesce(o.spn,0),'FM999,999,999'),
           'rank_label',    public._c('admin_sup2.rank_prefix')||o.spn_rank::text,
           'waiting_count', o.waiting_n,
           'has_waiting',   (o.waiting_n > 0),
           'waiting_label', case when o.waiting_n = 0 then public._c('admin_sup2.waiting_none')
                                 else public.count_label(v_copy,'wait_one','wait_many',o.waiting_n) end,
           'dues_amount',   o.dues_amt,
           'has_dues',      (o.dues_amt > 0),
           'dues_label',    case when o.dues_amt > 0 then public.inr_money(o.dues_amt)
                                 else public._c('admin_sup2.dues_none') end,
           'kyc_chip',      o.kyc->'chip',
           'kyc_state',     o.kyc_state,
           'status_chip',   public.status_chip('supplier_status', o.status),
           'is_active',     o.is_active,
           'menu',          public._sup753_menu(o.id, coalesce(o.supplier_name,''),
                                                coalesce(nullif(o.whatsapp_no,''), o.phone),
                                                o.is_active)
         )), '[]'::jsonb), count(*)
    into v_rows, v_n
    from ordered o;

  -- Chip counts are computed over the SAME zone-scoped base, ignoring the
  -- chips themselves, so a count never depends on what is already selected.
  with base as (
    select sp.id, sp.supplier_name, sp.status, sp."SPN" as spn, sp.zone_id,
           sp.drug_license, sp.dl_1, sp.gstin, sp.gst, sp.dl_expiry, sp.gstin_expiry
      from supplier_profiles sp
     where coalesce(sp.is_deleted,false) = false
       and (v_zone is null or sp.zone_id = v_zone)
  ),
  paid as (select sp.supplier_order_id, sum(coalesce(sp.amount,0)) amt from supplier_payments sp group by 1),
  dues as (
    select so.supplier_id, sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0),0)) due
      from supplier_orders so left join paid p on p.supplier_order_id = so.id
     where so.settled_at is null and lower(coalesce(so.status,'')) <> 'cancelled'
       and so.supplier_id is not null
     group by 1
  ),
  e as (
    select b.*, coalesce(d.due,0) dues_amt,
           (coalesce(m.total,0) - coalesce(m.matched,0)) unmatched,
           (public._sup753_kyc(coalesce(nullif(b.drug_license,''),b.dl_1),
                               coalesce(nullif(b.gstin,''),b.gst),
                               b.dl_expiry, b.gstin_expiry)->>'state') kyc_state,
           (lower(coalesce(b.status,'')) = v_active) is_active,
           rank() over (order by coalesce(b.spn,0) desc, lower(b.supplier_name)) spn_rank
      from base b
      left join dues d on d.supplier_id = b.id
      left join supplier_match_status_v m on m.supplier_id = b.id
  )
  select jsonb_build_array(
    jsonb_build_object('key','active',   'label',public._c('admin_sup2.chip_active'),
                       'count',(select count(*) from e where e.is_active)),
    jsonb_build_object('key','inactive', 'label',public._c('admin_sup2.chip_inactive'),
                       'count',(select count(*) from e where not e.is_active)),
    jsonb_build_object('key','unmatched','label',public._c('admin_sup2.chip_unmatched'),
                       'count',(select count(*) from e where e.unmatched > 0)),
    jsonb_build_object('key','dues',     'label',public._c('admin_sup2.chip_dues'),
                       'count',(select count(*) from e where e.dues_amt > 0)),
    jsonb_build_object('key','licence',  'label',public._c('admin_sup2.chip_licence'),
                       'count',(select count(*) from e where e.kyc_state in ('expiring','expired'))),
    jsonb_build_object('key','top_spn',  'label',public._c('admin_sup2.chip_top_spn'),
                       'count',(select count(*) from e where e.spn_rank <= 5)))
    into v_chips;

  -- Mark the active ones; the zone chip is the scope itself, never toggled off.
  select jsonb_agg(c || jsonb_build_object('active', (c->>'key') = any(v_f)))
    into v_chips from jsonb_array_elements(v_chips) c;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'role', v_role,
    'zone_id', v_zone,
    'zone_chip', jsonb_build_object(
       'key','zone', 'locked', true,
       'label', coalesce((select z.name from zones z where z.id = v_zone),
                         public._c('admin_sup2.chip_zone'))),
    'title', public._c('admin_sup2.title'),
    'search_hint', public._c('admin_sup2.search_hint'),
    'empty_label', public._c('admin_sup2.empty'),
    'sort_label', public._c('admin_sup2.sort_label'),
    'chips', coalesce(v_chips,'[]'::jsonb),
    'sorts', jsonb_build_array(
       jsonb_build_object('key','spn',    'label',public._c('admin_sup2.sort_spn'),    'active', v_sort='spn'),
       jsonb_build_object('key','name',   'label',public._c('admin_sup2.sort_name'),   'active', v_sort='name'),
       jsonb_build_object('key','dues',   'label',public._c('admin_sup2.sort_dues'),   'active', v_sort='dues'),
       jsonb_build_object('key','waiting','label',public._c('admin_sup2.sort_waiting'),'active', v_sort='waiting')),
    'rows', v_rows,
    'count', v_n,
    'count_label', public.count_label(v_copy,'count_one','count_many',v_n));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE SUPPLIER PAGE
-- Every tab is ONE rpc returning `blocks[]`. Flutter has one renderer per
-- block kind and decides nothing: kv | chips | list | tiles | table |
-- timeline | note. An unknown kind is skipped silently (forward compat).
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 9. Load + fence one supplier. Returns null when out of the caller's zone.
create or replace function public._sup753_row(p_supplier_id uuid)
returns supplier_profiles
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_zone smallint := public.admin_active_zone(); sp supplier_profiles%rowtype;
begin
  select * into sp from supplier_profiles where id = p_supplier_id;
  if not found then return null; end if;
  if v_zone is not null and coalesce(sp.zone_id,-1) <> v_zone then return null; end if;
  return sp;
end $$;

create or replace function public._sup753_deny(p_found boolean)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object('ok', false, 'blocks', '[]'::jsonb,
    'message', case when p_found then public._c('admin_sup2.forbidden')
                    else public._c('admin_sup2.not_found') end);
$$;

-- ── 10. The page shell: header + the tab list from the registry ────────────
create or replace function public.admin_supplier_page(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.tab_key, 'label', t.label, 'icon', coalesce(t.icon_key,''))
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from admin_supplier_tab t
   where t.is_active
     and (t.feature_key is null
          or public.my_partner_id() is null
          or public.partner_can(t.feature_key,'read'));

  return jsonb_build_object(
    'ok', true,
    'supplier_id', sp.id,
    'title', coalesce(nullif(btrim(sp.supplier_name),''), sp.contact_name, '—'),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(sp.supplier_code,'')),''),
        nullif(btrim(coalesce(sp.phone,'')),''),
        nullif(btrim(coalesce(sp.city,'')),'')], null), '  ·  '),
    'back_label', public._c('admin_sup2.back'),
    'chips', jsonb_build_array(
       public.status_chip('supplier_status', sp.status),
       v_kyc->'chip'),
    'spn_label', public._c('admin_sup2.spn_prefix')||' '||to_char(coalesce(sp."SPN",0),'FM999,999,999'),
    'zone_label', coalesce((select z.name from zones z where z.id = sp.zone_id),
                           public._c('admin_sup2.no_zone')),
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key','profile'),
    'empty_label', public._c('admin_sup2.tab_empty'));
end $$;

-- ── 11. Profile tab ────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_sup2.p_business',   to_jsonb('Business'::text)),
  ('admin_sup2.p_contact',    to_jsonb('Contact'::text)),
  ('admin_sup2.p_trade',      to_jsonb('Trade terms'::text)),
  ('admin_sup2.p_kyc',        to_jsonb('Licences & KYC'::text)),
  ('admin_sup2.p_docs',       to_jsonb('Documents'::text)),
  ('admin_sup2.p_docs_empty', to_jsonb('No documents generated yet.'::text)),
  ('admin_sup2.f_name',       to_jsonb('Supplier'::text)),
  ('admin_sup2.f_code',       to_jsonb('Code'::text)),
  ('admin_sup2.f_type',       to_jsonb('Stockist type'::text)),
  ('admin_sup2.f_zone',       to_jsonb('Zone'::text)),
  ('admin_sup2.f_status',     to_jsonb('Status'::text)),
  ('admin_sup2.f_person',     to_jsonb('Contact person'::text)),
  ('admin_sup2.f_phone',      to_jsonb('Phone'::text)),
  ('admin_sup2.f_whatsapp',   to_jsonb('WhatsApp'::text)),
  ('admin_sup2.f_email',      to_jsonb('Email'::text)),
  ('admin_sup2.f_address',    to_jsonb('Address'::text)),
  ('admin_sup2.f_city',       to_jsonb('City'::text)),
  ('admin_sup2.f_payment',    to_jsonb('Payment term'::text)),
  ('admin_sup2.f_margin',     to_jsonb('Margin'::text)),
  ('admin_sup2.f_cd',         to_jsonb('CD condition'::text)),
  ('admin_sup2.f_deal',       to_jsonb('Deal'::text)),
  ('admin_sup2.f_dl',         to_jsonb('Drug licence'::text)),
  ('admin_sup2.f_dl_exp',     to_jsonb('Drug licence expiry'::text)),
  ('admin_sup2.f_gst',        to_jsonb('GSTIN'::text)),
  ('admin_sup2.f_gst_exp',    to_jsonb('GSTIN expiry'::text)),
  ('admin_sup2.f_kyc_state',  to_jsonb('KYC state'::text)),
  ('admin_sup2.f_approved',   to_jsonb('Approved'::text)),
  ('admin_sup2.f_created',    to_jsonb('Added'::text)),
  ('admin_sup2.not_set',      to_jsonb('Not set'::text))
on conflict (key) do nothing;

create or replace function public._sup753_kv(p_label text, p_value text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'label', p_label,
    'value', case when coalesce(btrim(coalesce(p_value,'')),'') = ''
                  then public._c('admin_sup2.not_set') else btrim(p_value) end,
    'muted', (coalesce(btrim(coalesce(p_value,'')),'') = ''));
$$;

create or replace function public.admin_supplier_tab_profile(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype; v_kyc jsonb; v_docs jsonb;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'title', coalesce(nullif(d.title,''), d.file_name, d.kind),
           'subtitle', coalesce(public.ist_fmt(d.ready_at,'day_mon_year'), ''),
           'chip', public.status_chip('doc_status', d.status))
         order by d.requested_at desc), '[]'::jsonb)
    into v_docs
    from supplier_document d
   where d.supplier_id = sp.id;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_business'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_name'),   sp.supplier_name),
      public._sup753_kv(public._c('admin_sup2.f_code'),   sp.supplier_code),
      public._sup753_kv(public._c('admin_sup2.f_type'),   coalesce(nullif(sp.stockist_type,''), sp.store_type)),
      public._sup753_kv(public._c('admin_sup2.f_zone'),   (select z.name from zones z where z.id = sp.zone_id)),
      public._sup753_kv(public._c('admin_sup2.f_status'), sp.status),
      public._sup753_kv(public._c('admin_sup2.f_approved'), public.ist_fmt(sp.approved_at,'day_mon_year')),
      public._sup753_kv(public._c('admin_sup2.f_created'),  public.ist_fmt(sp.created_at,'day_mon_year')))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_contact'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_person'),   coalesce(nullif(sp.contact_person,''), sp.contact_name)),
      public._sup753_kv(public._c('admin_sup2.f_phone'),    coalesce(nullif(sp.phone,''), sp.contact_no)),
      public._sup753_kv(public._c('admin_sup2.f_whatsapp'), sp.whatsapp_no),
      public._sup753_kv(public._c('admin_sup2.f_email'),    sp.email),
      public._sup753_kv(public._c('admin_sup2.f_address'),  coalesce(nullif(sp.address,''), sp.street_address)),
      public._sup753_kv(public._c('admin_sup2.f_city'),
        array_to_string(array_remove(array[nullif(btrim(coalesce(sp.city,'')),''),
                                           nullif(btrim(coalesce(sp.state,'')),'')], null), ', ')))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_trade'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_payment'), coalesce(nullif(sp.payment_term,''), sp.payment_type)),
      public._sup753_kv(public._c('admin_sup2.f_margin'),  sp.margin),
      public._sup753_kv(public._c('admin_sup2.f_cd'),      sp.cd_condition),
      public._sup753_kv(public._c('admin_sup2.f_deal'),    sp.deal))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_kyc'),
      'chip', v_kyc->'chip', 'rows', jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_dl'),     coalesce(nullif(sp.drug_license,''), sp.dl_1)),
      public._sup753_kv(public._c('admin_sup2.f_dl_exp'),
        case when sp.dl_expiry is null then '' else to_char(sp.dl_expiry,'FMDD Mon YYYY') end),
      public._sup753_kv(public._c('admin_sup2.f_gst'),    coalesce(nullif(sp.gstin,''), sp.gst)),
      public._sup753_kv(public._c('admin_sup2.f_gst_exp'),
        case when sp.gstin_expiry is null then '' else to_char(sp.gstin_expiry,'FMDD Mon YYYY') end),
      public._sup753_kv(public._c('admin_sup2.f_kyc_state'), v_kyc->'chip'->>'label'))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.p_docs'),
      'empty', public._c('admin_sup2.p_docs_empty'), 'items', v_docs)));
end $$;

-- ── 12. Companies tab ──────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_sup2.c_title',    to_jsonb('Companies stocked'::text)),
  ('admin_sup2.c_empty',    to_jsonb('No companies mapped for this supplier yet.'::text)),
  ('admin_sup2.c_all',      to_jsonb('All'::text)),
  ('admin_sup2.c_mapped',   to_jsonb('Mapped'::text)),
  ('admin_sup2.c_unmapped', to_jsonb('Unmapped'::text)),
  ('admin_sup2.c_match',    to_jsonb('Match'::text)),
  ('admin_sup2.c_unmap',    to_jsonb('Unmap'::text)),
  ('admin_sup2.c_map',      to_jsonb('Map'::text)),
  ('admin_sup2.c_map_hint', to_jsonb('Catalogue company name'::text)),
  ('admin_sup2.c_map_title',to_jsonb('Map this company'::text)),
  ('admin_sup2.c_map_ok',   to_jsonb('Save mapping'::text)),
  ('admin_sup2.c_cancel',   to_jsonb('Cancel'::text)),
  ('admin_sup2.c_unmapped_row', to_jsonb('Not mapped to the catalogue'::text))
on conflict (key) do nothing;

create or replace function public.admin_supplier_tab_companies(
  p_supplier_id uuid, p_filter text default 'all')
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_f text := lower(coalesce(nullif(btrim(coalesce(p_filter,'')),''),'all'));
  v_total int; v_mapped int; v_items jsonb; v_pct numeric;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  select count(*), count(*) filter (where coalesce(btrim(coalesce(sc.company_1,'')),'') <> '')
    into v_total, v_mapped
    from supplier_company sc where sc.supplier_id = sp.id;

  v_pct := case when coalesce(v_total,0) = 0 then 0
                else round((v_mapped::numeric * 100) / v_total, 1) end;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'title', x.raw,
           'subtitle', case when x.is_mapped then x.mapped_name
                            else public._c('admin_sup2.c_unmapped_row') end,
           'chip', jsonb_build_object('show', true,
             'label', case when x.is_mapped then public._c('admin_sup2.c_mapped')
                           else public._c('admin_sup2.c_unmapped') end,
             'bg',     case when x.is_mapped then '#D1FAE5' else '#FEF3C7' end,
             'fg',     case when x.is_mapped then '#065F46' else '#92400E' end,
             'border', case when x.is_mapped then '#A7F3D0' else '#FDE68A' end),
           'actions', case when x.is_mapped then jsonb_build_array(
                jsonb_build_object('key','unmap','label',public._c('admin_sup2.c_unmap'),
                  'tone','danger','rpc','admin_supplier_company_map',
                  'args', jsonb_build_object('p_id', x.id, 'p_company', '')))
              else jsonb_build_array(
                jsonb_build_object('key','map','label',public._c('admin_sup2.c_map'),
                  'tone','brand','rpc','admin_supplier_company_map',
                  'args', jsonb_build_object('p_id', x.id),
                  'prompt', jsonb_build_object(
                    'title', public._c('admin_sup2.c_map_title'),
                    'hint',  public._c('admin_sup2.c_map_hint'),
                    'ok',    public._c('admin_sup2.c_map_ok'),
                    'cancel',public._c('admin_sup2.c_cancel'),
                    'arg',   'p_company'))) end)
         order by lower(x.raw)), '[]'::jsonb)
    into v_items
    from (
      select sc.id,
             coalesce(nullif(btrim(coalesce(sc.supplier_company,'')),''),'—') as raw,
             btrim(coalesce(sc.company_1,'')) as mapped_name,
             (coalesce(btrim(coalesce(sc.company_1,'')),'') <> '') as is_mapped
        from supplier_company sc
       where sc.supplier_id = sp.id
    ) x
   where (v_f = 'all')
      or (v_f = 'mapped'   and x.is_mapped)
      or (v_f = 'unmapped' and not x.is_mapped);

  return jsonb_build_object('ok', true, 'filter', v_f, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label', public._c('admin_sup2.c_all'),      'value', v_total::text,  'tone','neutral'),
      jsonb_build_object('label', public._c('admin_sup2.c_mapped'),   'value', v_mapped::text, 'tone','success'),
      jsonb_build_object('label', public._c('admin_sup2.c_unmapped'), 'value', (v_total - v_mapped)::text,
                         'tone', case when v_total - v_mapped > 0 then 'warning' else 'neutral' end),
      jsonb_build_object('label', public._c('admin_sup2.c_match'),    'value', to_char(v_pct,'FM990.0')||'%', 'tone','info'))),
    jsonb_build_object('kind','chips','key','filter','arg','p_filter','chips', jsonb_build_array(
      jsonb_build_object('key','all',     'label',public._c('admin_sup2.c_all'),     'count',v_total,           'active',v_f='all'),
      jsonb_build_object('key','mapped',  'label',public._c('admin_sup2.c_mapped'),  'count',v_mapped,          'active',v_f='mapped'),
      jsonb_build_object('key','unmapped','label',public._c('admin_sup2.c_unmapped'),'count',v_total - v_mapped,'active',v_f='unmapped'))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.c_title'),
      'empty', public._c('admin_sup2.c_empty'), 'items', v_items)));
end $$;

-- Map / unmap in one call. An empty company unmaps and returns the row to the
-- matcher's review queue; a name maps it and marks the match done.
create or replace function public.admin_supplier_company_map(p_id uuid, p_company text default '')
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_role text := public._sup753_gate(); v_name text := btrim(coalesce(p_company,''));
        v_sid uuid;
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  select sc.supplier_id into v_sid from supplier_company sc where sc.id = p_id;
  if v_sid is null then raise exception 'company_row_not_found'; end if;
  if (public._sup753_row(v_sid)).id is null then raise exception 'not_authorized_zone'; end if;

  update supplier_company
     set company_1 = nullif(v_name,''),
         match_state = case when v_name = '' then 'needs_review' else 'done' end,
         matched_at = case when v_name = '' then null else now() end
   where id = p_id;

  return jsonb_build_object('ok', true, 'id', p_id::text, 'company', v_name);
end $$;

-- ── 13. Availability tab ───────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_sup2.a_title',   to_jsonb('Products answered'::text)),
  ('admin_sup2.a_empty',   to_jsonb('This supplier has not answered on any product in this zone yet.'::text)),
  ('admin_sup2.a_zone',    to_jsonb('Zone'::text)),
  ('admin_sup2.a_shop',    to_jsonb('Shop'::text)),
  ('admin_sup2.a_last',    to_jsonb('Last answered'::text)),
  ('admin_sup2.a_times_one',  to_jsonb('asked once'::text)),
  ('admin_sup2.a_times_many', to_jsonb('asked {n} times'::text)),
  ('admin_sup2.a_set_available', to_jsonb('Available'::text)),
  ('admin_sup2.a_set_oos',       to_jsonb('Out of stock'::text)),
  ('admin_sup2.a_set_dont',      to_jsonb('Does not stock'::text))
on conflict (key) do nothing;

create or replace function public.admin_supplier_tab_availability(
  p_supplier_id uuid, p_zone_id smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_scope smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype;
  v_zone smallint; v_zones jsonb; v_items jsonb; v_copy jsonb;
  v_avail text := 'Available'; v_oos text := 'Out of Stock';
  v_dont text := 'We don''t stock this product';
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_zone := coalesce(p_zone_id, v_scope, sp.zone_id);
  v_copy := jsonb_build_object('one', public._c('admin_sup2.a_times_one'),
                               'many', public._c('admin_sup2.a_times_many'));

  -- ①②③④⑤ — the circled numeral belongs to the zone, and it is the BACKEND
  -- that draws it, so a sixth zone tomorrow is a data row, not a deploy.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', z.id::text,
           'value', z.id,
           'label', case z.id when 1 then '①' when 2 then '②' when 3 then '③'
                              when 4 then '④' when 5 then '⑤'
                              else '('||z.id::text||')' end || ' ' || z.name,
           'count', (select count(*) from supplier_item_memory m
                      join catalogue_zone_avail cz
                        on cz.product_id = m.product_id and cz.zone_id = z.id
                     where lower(btrim(m.supplier_name)) = lower(btrim(sp.supplier_name))),
           'active', (z.id = v_zone))
         order by z.id), '[]'::jsonb)
    into v_zones
    from zones z
   where (v_scope is null or z.id = v_scope);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.product_id,
           'title', coalesce(nullif(btrim(coalesce(md.product_name,'')),''), '#'||m.product_id::text),
           'subtitle', public.count_label(v_copy,'one','many',coalesce(m.times_answered,0)),
           'meta', case when m.last_answered_at is null then ''
                        else public._c('admin_sup2.a_last')||': '||public.ist_fmt(m.last_answered_at,'day_mon_year') end,
           'chip', jsonb_build_object('show', true, 'label', coalesce(m.last_answer,''),
             'bg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#D1FAE5'
                            when 'out of stock' then '#FEE2E2' else '#EFF6FF' end,
             'fg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#065F46'
                            when 'out of stock' then '#991B1B' else '#1E40AF' end,
             'border', case lower(coalesce(m.last_answer,'')) when 'available' then '#A7F3D0'
                            when 'out of stock' then '#FECACA' else '#BFDBFE' end),
           'actions', jsonb_build_array(
             jsonb_build_object('key','available','label',public._c('admin_sup2.a_set_available'),
               'tone','success','selected',(m.last_answer = v_avail),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_avail)),
             jsonb_build_object('key','oos','label',public._c('admin_sup2.a_set_oos'),
               'tone','danger','selected',(m.last_answer = v_oos),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_oos)),
             jsonb_build_object('key','dont','label',public._c('admin_sup2.a_set_dont'),
               'tone','info','selected',(m.last_answer = v_dont),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_dont))))
         order by m.last_answered_at desc nulls last), '[]'::jsonb)
    into v_items
    from supplier_item_memory m
    left join "MEDICINE" md on md.id = m.product_id
   where lower(btrim(m.supplier_name)) = lower(btrim(sp.supplier_name))
     and (v_zone is null
          or exists (select 1 from catalogue_zone_avail cz
                      where cz.product_id = m.product_id and cz.zone_id = v_zone));

  return jsonb_build_object('ok', true, 'zone_id', v_zone, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','chips','key','zone','arg','p_zone_id','arg_type','int',
                       'title',public._c('admin_sup2.a_zone'),'chips',v_zones),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.a_title'),
      'empty', public._c('admin_sup2.a_empty'), 'items', v_items)));
end $$;

create or replace function public.admin_supplier_availability_set(
  p_supplier_id uuid, p_product_id bigint, p_state text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_role text := public._sup753_gate(); sp supplier_profiles%rowtype;
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then raise exception 'not_authorized_zone'; end if;
  if coalesce(btrim(coalesce(p_state,'')),'') = '' then raise exception 'state_required'; end if;

  insert into supplier_item_memory (supplier_name, product_id, last_answer, last_answered_at, times_answered)
  values (sp.supplier_name, p_product_id, btrim(p_state), now(), 1)
  on conflict (supplier_name, product_id) do update
    set last_answer = excluded.last_answer,
        last_answered_at = now();

  insert into supplier_audit_log (supplier_id, actor_identity, feature_key, action, detail)
  values (sp.id, coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown'),
          'admin.supplier.availability', 'set_state',
          jsonb_build_object('product_id', p_product_id, 'state', btrim(p_state)));

  return jsonb_build_object('ok', true, 'product_id', p_product_id, 'state', btrim(p_state));
end $$;

-- ── 14. Orders tab ─────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_sup2.o_title',   to_jsonb('Purchase orders'::text)),
  ('admin_sup2.o_empty',   to_jsonb('No purchase order for this supplier yet.'::text)),
  ('admin_sup2.o_all',     to_jsonb('All'::text)),
  ('admin_sup2.o_open',    to_jsonb('Open'::text)),
  ('admin_sup2.o_packed',  to_jsonb('Packed'::text)),
  ('admin_sup2.o_settled', to_jsonb('Settled'::text)),
  ('admin_sup2.o_cancelled', to_jsonb('Cancelled'::text)),
  ('admin_sup2.o_orders',  to_jsonb('Orders'::text)),
  ('admin_sup2.o_value',   to_jsonb('Total value'::text)),
  ('admin_sup2.o_items_one',  to_jsonb('1 item'::text)),
  ('admin_sup2.o_items_many', to_jsonb('{n} items'::text)),
  ('admin_sup2.o_more',    to_jsonb('Load more'::text))
on conflict (key) do nothing;

create or replace function public.admin_supplier_tab_orders(
  p_supplier_id uuid, p_status text default 'all',
  p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_f text := lower(coalesce(nullif(btrim(coalesce(p_status,'')),''),'all'));
  v_lim int := least(greatest(coalesce(p_limit,50),1),200);
  v_off int := greatest(coalesce(p_offset,0),0);
  v_copy jsonb; v_items jsonb; v_total int; v_amt numeric;
  v_c_all int; v_c_open int; v_c_packed int; v_c_settled int; v_c_cancelled int;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_copy := jsonb_build_object('one', public._c('admin_sup2.o_items_one'),
                               'many', public._c('admin_sup2.o_items_many'));

  select count(*),
         count(*) filter (where so.settled_at is null and not coalesce(so.packed,false)
                            and lower(coalesce(so.status,'')) <> 'cancelled'),
         count(*) filter (where coalesce(so.packed,false)),
         count(*) filter (where so.settled_at is not null),
         count(*) filter (where lower(coalesce(so.status,'')) = 'cancelled')
    into v_c_all, v_c_open, v_c_packed, v_c_settled, v_c_cancelled
    from supplier_orders so where so.supplier_id = sp.id;

  with f as (
    select so.* from supplier_orders so
     where so.supplier_id = sp.id
       and (v_f = 'all'
            or (v_f = 'open'      and so.settled_at is null and not coalesce(so.packed,false)
                                  and lower(coalesce(so.status,'')) <> 'cancelled')
            or (v_f = 'packed'    and coalesce(so.packed,false))
            or (v_f = 'settled'   and so.settled_at is not null)
            or (v_f = 'cancelled' and lower(coalesce(so.status,'')) = 'cancelled'))
  ),
  page as (select * from f order by created_at desc limit v_lim offset v_off)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id,
           'title', coalesce(nullif(p.order_code,''), '#'||coalesce(p.order_no,0)::text),
           'subtitle', public.count_label(v_copy,'one','many',coalesce(jsonb_array_length(p.items),0)),
           'meta', public.ist_fmt(coalesce(p.created_at, p.order_date::timestamptz),'day_mon_year'),
           'trailing', public.inr_money(coalesce(p.total_amount,0)),
           'chip', public.status_chip('supplier_status', p.status),
           'link', jsonb_build_object('tab','payments','copy', coalesce(p.order_code,''),
                     'toast', case when coalesce(p.order_code,'') = '' then ''
                                   else replace(public._c('admin_sup2.h_copied'),'{code}', p.order_code) end))
         order by p.created_at desc), '[]'::jsonb)
    into v_items from page p;

  select count(*), coalesce(sum(coalesce(so.total_amount,0)),0)
    into v_total, v_amt
    from supplier_orders so
   where so.supplier_id = sp.id
     and (v_f = 'all'
          or (v_f = 'open'      and so.settled_at is null and not coalesce(so.packed,false)
                                and lower(coalesce(so.status,'')) <> 'cancelled')
          or (v_f = 'packed'    and coalesce(so.packed,false))
          or (v_f = 'settled'   and so.settled_at is not null)
          or (v_f = 'cancelled' and lower(coalesce(so.status,'')) = 'cancelled'));

  return jsonb_build_object('ok', true, 'filter', v_f,
    'offset', v_off, 'limit', v_lim,
    'has_more', (v_off + v_lim < v_total),
    'more_label', public._c('admin_sup2.o_more'),
    'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label',public._c('admin_sup2.o_orders'),'value',v_total::text,'tone','neutral'),
      jsonb_build_object('label',public._c('admin_sup2.o_value'), 'value',public.inr_money(v_amt),'tone','info'))),
    jsonb_build_object('kind','chips','key','status','arg','p_status','chips', jsonb_build_array(
      jsonb_build_object('key','all',      'label',public._c('admin_sup2.o_all'),      'count',v_c_all,      'active',v_f='all'),
      jsonb_build_object('key','open',     'label',public._c('admin_sup2.o_open'),     'count',v_c_open,     'active',v_f='open'),
      jsonb_build_object('key','packed',   'label',public._c('admin_sup2.o_packed'),   'count',v_c_packed,   'active',v_f='packed'),
      jsonb_build_object('key','settled',  'label',public._c('admin_sup2.o_settled'),  'count',v_c_settled,  'active',v_f='settled'),
      jsonb_build_object('key','cancelled','label',public._c('admin_sup2.o_cancelled'),'count',v_c_cancelled,'active',v_f='cancelled'))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.o_title'),
      'empty', public._c('admin_sup2.o_empty'), 'items', v_items)));
end $$;

-- ── 15. Payments tab ───────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_sup2.y_billed',    to_jsonb('Billed'::text)),
  ('admin_sup2.y_paid',      to_jsonb('Paid'::text)),
  ('admin_sup2.y_pending',   to_jsonb('Pending'::text)),
  ('admin_sup2.y_debits',    to_jsonb('Debit notes'::text)),
  ('admin_sup2.y_bills',     to_jsonb('Bills'::text)),
  ('admin_sup2.y_bills_empty', to_jsonb('No bill received from this supplier yet.'::text)),
  ('admin_sup2.y_pay_title', to_jsonb('Payments made'::text)),
  ('admin_sup2.y_pay_empty', to_jsonb('No payment recorded yet.'::text)),
  ('admin_sup2.y_debit_title', to_jsonb('Debit notes & credit adjustments'::text)),
  ('admin_sup2.y_debit_empty', to_jsonb('No debit note against this supplier.'::text)),
  ('admin_sup2.y_export',    to_jsonb('Export statement (CSV)'::text)),
  ('admin_sup2.y_unbilled',  to_jsonb('No bill file'::text))
on conflict (key) do nothing;

create or replace function public.admin_supplier_tab_payments(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_billed numeric; v_paid numeric; v_pending numeric; v_debit numeric;
  v_bills jsonb; v_pays jsonb; v_debits jsonb;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  select coalesce(sum(coalesce(so.total_amount,0)),0) into v_billed
    from supplier_orders so
   where so.supplier_id = sp.id and lower(coalesce(so.status,'')) <> 'cancelled';

  select coalesce(sum(coalesce(pm.amount,0)),0) into v_paid
    from supplier_payments pm
    join supplier_orders so on so.id = pm.supplier_order_id
   where so.supplier_id = sp.id;

  select coalesce(sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0),0)),0)
    into v_pending
    from supplier_orders so
    left join (select supplier_order_id, sum(coalesce(amount,0)) amt
                 from supplier_payments group by 1) p on p.supplier_order_id = so.id
   where so.supplier_id = sp.id and so.settled_at is null
     and lower(coalesce(so.status,'')) <> 'cancelled';

  select coalesce(sum(coalesce(d.adj_amount,0)),0) into v_debit
    from supplier_disputes d
   where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(sp.supplier_name));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id,
           'title', coalesce(nullif(b.file_name,''), public._c('admin_sup2.y_unbilled')),
           'subtitle', coalesce(public.ist_fmt(b.received_at,'day_mon_year'),''),
           'chip', public.status_chip('bill_status', coalesce(b.status,'')))
         order by b.received_at desc), '[]'::jsonb)
    into v_bills
    from pending_bills b
   where lower(btrim(coalesce(b.supplier_name,''))) = lower(btrim(sp.supplier_name));

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', pm.id,
           'title', public.inr_money(coalesce(pm.amount,0)),
           'subtitle', array_to_string(array_remove(array[
               nullif(btrim(coalesce(pm.mode,'')),''),
               nullif(btrim(coalesce(pm.utr,'')),'')], null), '  ·  '),
           'meta', coalesce(public.ist_fmt(pm.created_at,'day_mon_year'),''),
           'trailing', coalesce(so.order_code,''))
         order by pm.created_at desc), '[]'::jsonb)
    into v_pays
    from supplier_payments pm
    join supplier_orders so on so.id = pm.supplier_order_id
   where so.supplier_id = sp.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'title', coalesce(nullif(d.product_name,''), d.dispute_code, '—'),
           'subtitle', coalesce(nullif(d.kind,''),''),
           'meta', coalesce(public.ist_fmt(d.created_at,'day_mon_year'),''),
           'trailing', public.inr_money(coalesce(d.adj_amount,0)),
           'trailing_tone', 'danger',
           'chip', public.status_chip('dispute_status', coalesce(d.status,'')))
         order by d.created_at desc), '[]'::jsonb)
    into v_debits
    from supplier_disputes d
   where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(sp.supplier_name));

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label',public._c('admin_sup2.y_billed'), 'value',public.inr_money(v_billed), 'tone','neutral'),
      jsonb_build_object('label',public._c('admin_sup2.y_paid'),   'value',public.inr_money(v_paid),   'tone','success'),
      jsonb_build_object('label',public._c('admin_sup2.y_pending'),'value',public.inr_money(v_pending),
                         'tone', case when v_pending > 0 then 'warning' else 'neutral' end),
      jsonb_build_object('label',public._c('admin_sup2.y_debits'), 'value',public.inr_money(v_debit),
                         'tone', case when v_debit > 0 then 'danger' else 'neutral' end))),
    jsonb_build_object('kind','buttons','buttons', jsonb_build_array(
      jsonb_build_object('key','export','label',public._c('admin_sup2.y_export'),'tone','brand',
        'export', true, 'rpc','admin_supplier_statement_csv',
        'args', jsonb_build_object('p_supplier_id', sp.id)))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.y_bills'),
      'empty', public._c('admin_sup2.y_bills_empty'), 'items', v_bills),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.y_pay_title'),
      'empty', public._c('admin_sup2.y_pay_empty'), 'items', v_pays),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.y_debit_title'),
      'empty', public._c('admin_sup2.y_debit_empty'), 'items', v_debits)));
end $$;

-- The statement export. The CSV is BUILT in the backend; Flutter only saves
-- the bytes it is handed.
create or replace function public.admin_supplier_statement_csv(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype; v_csv text;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  select 'Date,Order,Status,Billed (INR),Paid (INR),Balance (INR)' || E'\n' ||
         coalesce(string_agg(
           to_char(coalesce(so.order_date, (so.created_at at time zone 'Asia/Kolkata')::date),'DD/MM/YYYY')
           ||','|| coalesce(replace(so.order_code,',',' '),'')
           ||','|| coalesce(replace(so.status,',',' '),'')
           ||','|| to_char(coalesce(so.total_amount,0),'FM9999999990.00')
           ||','|| to_char(coalesce(p.amt,0),'FM9999999990.00')
           ||','|| to_char(greatest(coalesce(so.total_amount,0)-coalesce(p.amt,0),0),'FM9999999990.00'),
           E'\n' order by so.created_at), '')
    into v_csv
    from supplier_orders so
    left join (select supplier_order_id, sum(coalesce(amount,0)) amt
                 from supplier_payments group by 1) p on p.supplier_order_id = so.id
   where so.supplier_id = sp.id;

  return jsonb_build_object('ok', true,
    'file_name', 'statement-'||regexp_replace(lower(coalesce(sp.supplier_name,'supplier')),'[^a-z0-9]+','-','g')
                 ||'-'||to_char((now() at time zone 'Asia/Kolkata')::date,'YYYY-MM-DD')||'.csv',
    'mime', 'text/csv',
    'content', coalesce(v_csv,''));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- PERFORMANCE — computed from tables that already exist (spec item 11).
-- No new data entry anywhere: the inquiry log, supplier orders, disputes and
-- the response log are the only inputs. Rolled up per calendar month (IST)
-- into supplier_perf_monthly and refreshed by the bounded cron dispatcher.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 16. SPN history — who changed the score, and when ─────────────────────
create or replace function public.trg_753_spn_history()
returns trigger
language plpgsql security definer set search_path to 'public'
as $$
begin
  if coalesce(new."SPN",-1) is distinct from coalesce(old."SPN",-1) then
    insert into supplier_audit_log (supplier_id, actor_identity, feature_key, action, detail)
    values (new.id,
            coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'system'),
            'admin.supplier.spn', 'spn_changed',
            jsonb_build_object('from', old."SPN", 'to', new."SPN"));
  end if;
  return new;
end $$;

-- Same lock story as the columns above: dropping and recreating a trigger takes
-- ACCESS EXCLUSIVE on supplier_profiles, and re-running this file while the
-- fleet is building timed out here too. Skip the churn when the trigger is
-- already the one we want.
do $c753trg$
begin
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.supplier_profiles'::regclass
                    and tgname = 'trg_753_spn_history'
                    and not tgisinternal) then
    drop trigger if exists trg_753_spn_history on public.supplier_profiles;
    create trigger trg_753_spn_history
      after update of "SPN" on public.supplier_profiles
      for each row execute function public.trg_753_spn_history();
  end if;
end $c753trg$;

-- ── 17. One month of metrics for one supplier ─────────────────────────────
create or replace function public._sup753_metrics(p_supplier_id uuid, p_month date)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_name text; v_from timestamptz; v_to timestamptz;
  v_asked int; v_responded int; v_median numeric;
  v_inq_asked int; v_inq_avail int;
  v_orders int; v_short int; v_disputes int;
  v_due int; v_ontime int; v_returns int; v_returns_ok boolean := false;
begin
  select supplier_name into v_name from supplier_profiles where id = p_supplier_id;
  if v_name is null then return '{}'::jsonb; end if;

  v_from := (p_month::timestamp at time zone 'Asia/Kolkata');
  v_to   := ((p_month + interval '1 month')::timestamp at time zone 'Asia/Kolkata');

  select count(*) filter (where l.kind = 'inquiry_asked'),
         count(*) filter (where l.kind = 'inquiry_asked' and l.responded_at is not null),
         percentile_cont(0.5) within group (
           order by l.response_seconds) filter (where l.response_seconds is not null)
    into v_asked, v_responded, v_median
    from supplier_response_log l
   where lower(btrim(coalesce(l.supplier_name,''))) = lower(btrim(v_name))
     and l.asked_at >= v_from and l.asked_at < v_to;

  select count(*),
         count(*) filter (where lower(coalesce(i.current_status,'')) = 'available')
    into v_inq_asked, v_inq_avail
    from inquiry i
   where lower(btrim(coalesce(i.current_supplier,''))) = lower(btrim(v_name))
     and coalesce(i.asked_at, i.created_at) >= v_from
     and coalesce(i.asked_at, i.created_at) <  v_to;

  select count(*),
         count(*) filter (where so.accept_due_at is not null),
         count(*) filter (where so.accepted_at is not null and so.accept_due_at is not null
                            and so.accepted_at <= so.accept_due_at)
    into v_orders, v_due, v_ontime
    from supplier_orders so
   where so.supplier_id = p_supplier_id
     and so.created_at >= v_from and so.created_at < v_to;

  select count(*),
         count(*) filter (where lower(coalesce(d.kind,'')) like '%short%'
                            or coalesce(d.short_qty,0) > 0)
    into v_disputes, v_short
    from supplier_disputes d
   where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(v_name))
     and d.created_at >= v_from and d.created_at < v_to;

  -- #710's returns table may not exist yet; the metric says so instead of
  -- printing a zero that looks like a fact.
  if to_regclass('public.supplier_returns') is not null then
    v_returns_ok := true;
    execute format(
      'select count(*) from public.supplier_returns r
        where lower(btrim(coalesce(r.supplier_name,%L))) = lower(btrim(%L))
          and r.created_at >= %L and r.created_at < %L', '', v_name, v_from, v_to)
      into v_returns;
  end if;

  return jsonb_build_object(
    'asked', coalesce(v_asked,0),
    'responded', coalesce(v_responded,0),
    'response_rate', case when coalesce(v_asked,0) = 0 then null
                          else round((v_responded::numeric*100)/v_asked, 1) end,
    'median_response_s', case when v_median is null then null else round(v_median) end,
    'inq_asked', coalesce(v_inq_asked,0),
    'inq_available', coalesce(v_inq_avail,0),
    'fill_rate', case when coalesce(v_inq_asked,0) = 0 then null
                      else round((v_inq_avail::numeric*100)/v_inq_asked, 1) end,
    'orders', coalesce(v_orders,0),
    'short_rate', case when coalesce(v_orders,0) = 0 then null
                       else round((v_short::numeric*100)/v_orders, 1) end,
    'dispute_rate', case when coalesce(v_orders,0) = 0 then null
                         else round((v_disputes::numeric*100)/v_orders, 1) end,
    'on_time_rate', case when coalesce(v_due,0) = 0 then null
                         else round((v_ontime::numeric*100)/v_due, 1) end,
    'returns_available', v_returns_ok,
    'returns', case when v_returns_ok then coalesce(v_returns,0) else null end,
    'returns_rate', case when not v_returns_ok or coalesce(v_orders,0) = 0 then null
                         else round((coalesce(v_returns,0)::numeric*100)/v_orders, 1) end);
end $$;

-- ── 18. Bounded rollup — at most p_max suppliers per pass ─────────────────
create or replace function public.supplier_perf_rollup(
  p_months integer default 12, p_max integer default 40, p_supplier uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_months int := least(greatest(coalesce(p_months,12),1),24);
  v_max int := least(greatest(coalesce(p_max,40),1),200);
  v_n int := 0; r record; m date;
begin
  for r in
    select sp.id from supplier_profiles sp
     where coalesce(sp.is_deleted,false) = false
       and (p_supplier is null or sp.id = p_supplier)
     order by sp.supplier_name
     limit v_max
  loop
    for m in
      select (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
              - (i || ' months')::interval)::date
        from generate_series(0, v_months - 1) i
    loop
      insert into supplier_perf_monthly (supplier_id, month, metrics, computed_at)
      values (r.id, m, public._sup753_metrics(r.id, m), now())
      on conflict (supplier_id, month) do update
        set metrics = excluded.metrics, computed_at = now();
    end loop;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'suppliers', v_n, 'months', v_months);
end $$;

insert into public.cron_task (name, ord, mode, work_sql, note, enabled,
                              base_interval_s, max_interval_s, dml)
values ('supplier_perf_rollup', 780, 'poll',
        'select public.supplier_perf_rollup(12, 40)',
        'CHANGE #753 — monthly supplier performance rollup, bounded to 40 suppliers a pass',
        true, 21600, 86400, true)
on conflict (name) do update
  set work_sql = excluded.work_sql, note = excluded.note, enabled = true;

-- ── 19. Performance tab ────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('admin_sup2.pf_resp',    to_jsonb('Response rate'::text)),
  ('admin_sup2.pf_median',  to_jsonb('Median response'::text)),
  ('admin_sup2.pf_fill',    to_jsonb('Fill rate'::text)),
  ('admin_sup2.pf_short',   to_jsonb('Short supply'::text)),
  ('admin_sup2.pf_disp',    to_jsonb('Count disputes'::text)),
  ('admin_sup2.pf_ontime',  to_jsonb('On-time collect'::text)),
  ('admin_sup2.pf_returns', to_jsonb('Returns'::text)),
  ('admin_sup2.pf_trend',   to_jsonb('Last 12 months'::text)),
  ('admin_sup2.pf_month',   to_jsonb('Month'::text)),
  ('admin_sup2.pf_spn',     to_jsonb('SPN history'::text)),
  ('admin_sup2.pf_spn_empty', to_jsonb('No SPN change recorded yet.'::text)),
  ('admin_sup2.pf_export',  to_jsonb('Export performance (CSV)'::text)),
  ('admin_sup2.pf_na',      to_jsonb('—'::text)),
  ('admin_sup2.pf_no_returns', to_jsonb('Returns not tracked yet'::text)),
  ('admin_sup2.pf_spn_row', to_jsonb('SPN {from} → {to}'::text)),
  ('admin_sup2.pf_window',  to_jsonb('This month'::text))
on conflict (key) do nothing;

create or replace function public._sup753_pct(p numeric)
returns text
language sql stable security definer set search_path to 'public'
as $$ select case when p is null then public._c('admin_sup2.pf_na')
                  else to_char(p,'FM990.0')||'%' end $$;

create or replace function public.admin_supplier_tab_performance(p_supplier_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_this date := date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date;
  v_now jsonb; v_trend jsonb; v_spn jsonb; v_ret_ok boolean;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  -- The current month is always live; the eleven behind it come from the cache
  -- the cron keeps warm.
  v_now := public._sup753_metrics(sp.id, v_this);
  insert into supplier_perf_monthly (supplier_id, month, metrics, computed_at)
  values (sp.id, v_this, v_now, now())
  on conflict (supplier_id, month) do update
    set metrics = excluded.metrics, computed_at = now();

  v_ret_ok := coalesce((v_now->>'returns_available')::boolean, false);

  select coalesce(jsonb_agg(jsonb_build_array(
           jsonb_build_object('text', to_char(m.month,'Mon YY'), 'align','left'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'response_rate')::numeric), 'align','right'),
           jsonb_build_object('text', case when m.metrics->>'median_response_s' is null
                                           then public._c('admin_sup2.pf_na')
                                           else public.fmt_duration_short((m.metrics->>'median_response_s')::int) end,
                              'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'fill_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'short_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'dispute_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'on_time_rate')::numeric), 'align','right'))
         order by m.month desc), '[]'::jsonb)
    into v_trend
    from supplier_perf_monthly m
   where m.supplier_id = sp.id
     and m.month > (v_this - interval '12 months')::date;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id,
           'title', replace(replace(public._c('admin_sup2.pf_spn_row'),
                     '{from}', coalesce(a.detail->>'from','—')),
                     '{to}',   coalesce(a.detail->>'to','—')),
           'subtitle', coalesce(a.actor_identity,''),
           'meta', coalesce(public.ist_fmt(a.created_at,'day_mon_year'),''))
         order by a.created_at desc), '[]'::jsonb)
    into v_spn
    from supplier_audit_log a
   where a.supplier_id = sp.id and a.action = 'spn_changed';

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','title',public._c('admin_sup2.pf_window'),'tiles', jsonb_build_array(
      jsonb_build_object('label',public._c('admin_sup2.pf_resp'),
        'value',public._sup753_pct((v_now->>'response_rate')::numeric),'tone','info'),
      jsonb_build_object('label',public._c('admin_sup2.pf_median'),
        'value', case when v_now->>'median_response_s' is null then public._c('admin_sup2.pf_na')
                      else public.fmt_duration_short((v_now->>'median_response_s')::int) end,'tone','neutral'),
      jsonb_build_object('label',public._c('admin_sup2.pf_fill'),
        'value',public._sup753_pct((v_now->>'fill_rate')::numeric),'tone','success'),
      jsonb_build_object('label',public._c('admin_sup2.pf_short'),
        'value',public._sup753_pct((v_now->>'short_rate')::numeric),'tone','warning'),
      jsonb_build_object('label',public._c('admin_sup2.pf_disp'),
        'value',public._sup753_pct((v_now->>'dispute_rate')::numeric),'tone','warning'),
      jsonb_build_object('label',public._c('admin_sup2.pf_ontime'),
        'value',public._sup753_pct((v_now->>'on_time_rate')::numeric),'tone','info'),
      jsonb_build_object('label',public._c('admin_sup2.pf_returns'),
        'value', case when v_ret_ok then public._sup753_pct((v_now->>'returns_rate')::numeric)
                      else public._c('admin_sup2.pf_no_returns') end,
        'tone', case when v_ret_ok then 'neutral' else 'muted' end))),
    jsonb_build_object('kind','table','title',public._c('admin_sup2.pf_trend'),
      'columns', jsonb_build_array(
        jsonb_build_object('label',public._c('admin_sup2.pf_month'), 'align','left'),
        jsonb_build_object('label',public._c('admin_sup2.pf_resp'),  'align','right'),
        jsonb_build_object('label',public._c('admin_sup2.pf_median'),'align','right'),
        jsonb_build_object('label',public._c('admin_sup2.pf_fill'),  'align','right'),
        jsonb_build_object('label',public._c('admin_sup2.pf_short'), 'align','right'),
        jsonb_build_object('label',public._c('admin_sup2.pf_disp'),  'align','right'),
        jsonb_build_object('label',public._c('admin_sup2.pf_ontime'),'align','right')),
      'rows', v_trend),
    jsonb_build_object('kind','buttons','buttons', jsonb_build_array(
      jsonb_build_object('key','export_perf','label',public._c('admin_sup2.pf_export'),'tone','brand',
        'export', true, 'rpc','admin_supplier_performance_csv',
        'args', jsonb_build_object('p_supplier_id', sp.id)))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.pf_spn'),
      'empty', public._c('admin_sup2.pf_spn_empty'), 'items', v_spn)));
end $$;

create or replace function public.admin_supplier_performance_csv(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_role text := public._sup753_gate(); sp supplier_profiles%rowtype; v_csv text;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  select 'Month,Asked,Responded,Response rate %,Median response s,Inquiries,Available,Fill rate %,Orders,Short supply %,Dispute %,On-time %' || E'\n' ||
         coalesce(string_agg(
           to_char(m.month,'YYYY-MM')
           ||','||coalesce(m.metrics->>'asked','0')
           ||','||coalesce(m.metrics->>'responded','0')
           ||','||coalesce(m.metrics->>'response_rate','')
           ||','||coalesce(m.metrics->>'median_response_s','')
           ||','||coalesce(m.metrics->>'inq_asked','0')
           ||','||coalesce(m.metrics->>'inq_available','0')
           ||','||coalesce(m.metrics->>'fill_rate','')
           ||','||coalesce(m.metrics->>'orders','0')
           ||','||coalesce(m.metrics->>'short_rate','')
           ||','||coalesce(m.metrics->>'dispute_rate','')
           ||','||coalesce(m.metrics->>'on_time_rate',''),
           E'\n' order by m.month desc), '')
    into v_csv from supplier_perf_monthly m where m.supplier_id = sp.id;

  return jsonb_build_object('ok', true,
    'file_name','performance-'||regexp_replace(lower(coalesce(sp.supplier_name,'supplier')),'[^a-z0-9]+','-','g')||'.csv',
    'mime','text/csv', 'content', coalesce(v_csv,''));
end $$;

-- ── 20. History tab — ONE timeline over every table that touches a supplier ─
insert into public.ui_copy (key, value) values
  ('admin_sup2.h_title',  to_jsonb('Timeline'::text)),
  ('admin_sup2.h_empty',  to_jsonb('Nothing happened with this supplier in this month.'::text)),
  ('admin_sup2.h_month',  to_jsonb('Month'::text)),
  ('admin_sup2.h_inq_asked',  to_jsonb('Inquiry sent'::text)),
  ('admin_sup2.h_inq_ans',    to_jsonb('Inquiry answered'::text)),
  ('admin_sup2.h_inq_adv',    to_jsonb('Inquiry moved on'::text)),
  ('admin_sup2.h_order',      to_jsonb('Purchase order'::text)),
  ('admin_sup2.h_dispute',    to_jsonb('Count dispute'::text)),
  ('admin_sup2.h_bill',       to_jsonb('Bill received'::text)),
  ('admin_sup2.h_payment',    to_jsonb('Payment made'::text)),
  ('admin_sup2.h_debit',      to_jsonb('Debit note'::text)),
  ('admin_sup2.h_avail',      to_jsonb('Availability changed'::text)),
  ('admin_sup2.h_spn',        to_jsonb('SPN changed'::text)),
  ('admin_sup2.h_closure',    to_jsonb('Shop closed'::text)),
  ('admin_sup2.h_reopen',     to_jsonb('Shop reopened'::text)),
  ('admin_sup2.h_deleted',    to_jsonb('Supplier deleted'::text))
on conflict (key) do nothing;

create or replace function public.admin_supplier_tab_history(
  p_supplier_id uuid, p_month text default null, p_limit integer default 200)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_this date := date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date;
  v_m date; v_from timestamptz; v_to timestamptz;
  v_lim int := least(greatest(coalesce(p_limit,200),1),500);
  v_months jsonb; v_items jsonb;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_m := coalesce(to_date(nullif(btrim(coalesce(p_month,'')),''),'YYYY-MM'), v_this);
  v_from := (v_m::timestamp at time zone 'Asia/Kolkata');
  v_to   := ((v_m + interval '1 month')::timestamp at time zone 'Asia/Kolkata');

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', to_char(mm,'YYYY-MM'),
           'label', to_char(mm,'Mon YY'),
           'active', (mm = v_m)) order by mm desc), '[]'::jsonb)
    into v_months
    from (select (v_this - (i||' months')::interval)::date as mm
            from generate_series(0,11) i) g;

  with ev as (
    select l.asked_at as at, public._c('admin_sup2.h_inq_asked') as title,
           coalesce(i.product_name,'') as subtitle, 'info' as tone, 'inquiry' as icon,
           ''::text as route, ''::text as arg
      from supplier_response_log l
      left join inquiry i on i.id = l.inquiry_id
     where lower(btrim(coalesce(l.supplier_name,''))) = lower(btrim(sp.supplier_name))
       and l.kind = 'inquiry_asked' and l.asked_at >= v_from and l.asked_at < v_to
    union all
    select l.responded_at, public._c('admin_sup2.h_inq_ans'),
           coalesce(l.outcome,''), 'success', 'inquiry', '', ''
      from supplier_response_log l
     where lower(btrim(coalesce(l.supplier_name,''))) = lower(btrim(sp.supplier_name))
       and l.responded_at is not null and l.responded_at >= v_from and l.responded_at < v_to
    union all
    select l.asked_at, public._c('admin_sup2.h_inq_adv'),
           coalesce(l.reason,''), 'warning', 'inquiry', '', ''
      from supplier_response_log l
     where lower(btrim(coalesce(l.supplier_name,''))) = lower(btrim(sp.supplier_name))
       and l.kind = 'po_timeout' and l.asked_at >= v_from and l.asked_at < v_to
    union all
    select so.created_at, public._c('admin_sup2.h_order'),
           coalesce(so.order_code,'')||'  ·  '||public.inr_money(coalesce(so.total_amount,0)),
           'neutral', 'order', 'orders', coalesce(so.order_code,'')
      from supplier_orders so
     where so.supplier_id = sp.id and so.created_at >= v_from and so.created_at < v_to
    union all
    select d.created_at,
           case when coalesce(d.adj_amount,0) > 0 then public._c('admin_sup2.h_debit')
                else public._c('admin_sup2.h_dispute') end,
           coalesce(d.product_name,''), 'danger', 'dispute', 'payments', coalesce(d.dispute_code,'')
      from supplier_disputes d
     where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(sp.supplier_name))
       and d.created_at >= v_from and d.created_at < v_to
    union all
    select b.received_at, public._c('admin_sup2.h_bill'),
           coalesce(b.file_name,''), 'neutral', 'bill', 'payments', coalesce(b.file_name,'')
      from pending_bills b
     where lower(btrim(coalesce(b.supplier_name,''))) = lower(btrim(sp.supplier_name))
       and b.received_at >= v_from and b.received_at < v_to
    union all
    select pm.created_at, public._c('admin_sup2.h_payment'),
           public.inr_money(coalesce(pm.amount,0))||'  ·  '||coalesce(pm.mode,''),
           'success', 'payment', 'payments', coalesce(so.order_code,'')
      from supplier_payments pm
      join supplier_orders so on so.id = pm.supplier_order_id
     where so.supplier_id = sp.id and pm.created_at >= v_from and pm.created_at < v_to
    union all
    select a.created_at,
           case a.action when 'spn_changed' then public._c('admin_sup2.h_spn')
                         else public._c('admin_sup2.h_avail') end,
           coalesce(a.actor_identity,''), 'info', 'audit', '', ''
      from supplier_audit_log a
     where a.supplier_id = sp.id and a.created_at >= v_from and a.created_at < v_to
    union all
    select c.starts_at, public._c('admin_sup2.h_closure'),
           coalesce(c.reason,''), 'warning', 'closure', '', ''
      from supplier_closure c
     where lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(sp.supplier_name))
       and c.starts_at >= v_from and c.starts_at < v_to
    union all
    select c.reopened_at, public._c('admin_sup2.h_reopen'),
           '', 'success', 'closure', '', ''
      from supplier_closure c
     where lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(sp.supplier_name))
       and c.reopened_at is not null and c.reopened_at >= v_from and c.reopened_at < v_to
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'when', public.ist_fmt(e.at,'day_mon_time12'),
           'title', e.title, 'subtitle', e.subtitle,
           'tone', e.tone, 'icon', e.icon,
           'link', case when coalesce(e.route,'') = '' then null
                        else jsonb_build_object(
                               'tab', e.route,
                               'copy', coalesce(e.arg,''),
                               'toast', case when coalesce(e.arg,'') = '' then ''
                                             else replace(public._c('admin_sup2.h_copied'),'{code}', e.arg) end) end)
         order by e.at desc), '[]'::jsonb)
    into v_items
    from (select * from ev where at is not null order by at desc limit v_lim) e;

  return jsonb_build_object('ok', true, 'month', to_char(v_m,'YYYY-MM'),
    'blocks', jsonb_build_array(
    jsonb_build_object('kind','chips','key','month','arg','p_month',
                       'title',public._c('admin_sup2.h_month'),'chips',v_months),
    jsonb_build_object('kind','timeline','title',public._c('admin_sup2.h_title'),
      'empty', public._c('admin_sup2.h_empty'), 'items', v_items)));
end $$;

-- ── 21. Delete with a reason. Confirmed in the UI, RECORDED here. ──────────
create or replace function public.admin_supplier_delete_with_reason(
  p_supplier_id uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_reason text := btrim(coalesce(p_reason,''));
  v_who text;
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  if v_reason = '' then
    return jsonb_build_object('ok', false, 'error','reason_required',
      'message', public._c('admin_sup2.delete_need_reason'));
  end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('admin_sup2.not_found'));
  end if;

  v_who := coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown');

  insert into supplier_delete_log (supplier_id, supplier_name, reason, deleted_by)
  values (sp.id, coalesce(sp.supplier_name,''), v_reason, v_who);

  insert into supplier_audit_log (supplier_id, actor_identity, feature_key, action, detail)
  values (sp.id, v_who, 'admin.supplier.delete', 'deleted',
          jsonb_build_object('reason', v_reason, 'supplier_name', sp.supplier_name));

  update supplier_profiles
     set is_deleted = true, deleted_at = now(), deleted_by = v_who,
         deleted_snapshot = coalesce(deleted_snapshot,'{}'::jsonb)
                            || jsonb_build_object('delete_reason', v_reason)
   where id = sp.id;

  return jsonb_build_object('ok', true, 'id', sp.id::text, 'reason', v_reason);
end $$;

-- ── 22. Partners may reach the console read RPCs; every one of them fences
--       itself on admin_active_zone(), which is what the clamp check reads.
insert into public.partner_rpc_allow (proname, source, note) values
  ('admin_suppliers_console',           'change_753','supplier console list'),
  ('admin_supplier_page',               'change_753','supplier page shell'),
  ('admin_supplier_tab_profile',        'change_753','supplier page tab'),
  ('admin_supplier_tab_companies',      'change_753','supplier page tab'),
  ('admin_supplier_tab_availability',   'change_753','supplier page tab'),
  ('admin_supplier_tab_orders',         'change_753','supplier page tab'),
  ('admin_supplier_tab_payments',       'change_753','supplier page tab'),
  ('admin_supplier_tab_performance',    'change_753','supplier page tab'),
  ('admin_supplier_tab_history',        'change_753','supplier page tab'),
  ('admin_supplier_statement_csv',      'change_753','supplier statement export'),
  ('admin_supplier_performance_csv',    'change_753','supplier performance export')
on conflict (proname) do nothing;

select public.partner_rpc_allow_refresh();

-- ── 23. The frontend must construct NOTHING: the tab list carries its own
--       rpc name, and every chip group carries the parameter it sets.
insert into public.ui_copy (key, value) values
  ('admin_sup2.h_copied', to_jsonb('{code} copied'::text))
on conflict (key) do nothing;

alter table public.admin_supplier_tab add column if not exists rpc text;
update public.admin_supplier_tab set rpc = 'admin_supplier_tab_'||tab_key
 where coalesce(rpc,'') = '';

create or replace function public.admin_supplier_page(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.tab_key, 'label', t.label,
           'icon', coalesce(t.icon_key,''),
           'rpc', coalesce(nullif(t.rpc,''), 'admin_supplier_tab_'||t.tab_key))
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from admin_supplier_tab t
   where t.is_active
     and (t.feature_key is null
          or public.my_partner_id() is null
          or public.partner_can(t.feature_key,'read'));

  return jsonb_build_object(
    'ok', true,
    'supplier_id', sp.id,
    'title', coalesce(nullif(btrim(sp.supplier_name),''), sp.contact_name, '—'),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(sp.supplier_code,'')),''),
        nullif(btrim(coalesce(sp.phone,'')),''),
        nullif(btrim(coalesce(sp.city,'')),'')], null), '  ·  '),
    'back_label', public._c('admin_sup2.back'),
    'chips', jsonb_build_array(
       public.status_chip('supplier_status', sp.status),
       v_kyc->'chip'),
    'spn_label', public._c('admin_sup2.spn_prefix')||' '||to_char(coalesce(sp."SPN",0),'FM999,999,999'),
    'zone_label', coalesce((select z.name from zones z where z.id = sp.zone_id),
                           public._c('admin_sup2.no_zone')),
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key','profile'),
    'empty_label', public._c('admin_sup2.tab_empty'));
end $$;

-- ── 24. Lock the new RPCs to signed-in callers (#436's rule) ───────────────
-- Every SECURITY DEFINER function inherits Postgres's default GRANT TO PUBLIC,
-- and the anon key ships inside the web bundle and the APK. These read a whole
-- supplier's trade history: revoke PUBLIC, re-grant the signed-in roles.
do $c753grants$
declare f record;
begin
  for f in
    select p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'admin_suppliers_console','admin_supplier_page',
         'admin_supplier_tab_profile','admin_supplier_tab_companies',
         'admin_supplier_tab_availability','admin_supplier_tab_orders',
         'admin_supplier_tab_payments','admin_supplier_tab_performance',
         'admin_supplier_tab_history','admin_supplier_statement_csv',
         'admin_supplier_performance_csv','admin_supplier_availability_set',
         'admin_supplier_company_map','admin_supplier_delete_with_reason',
         'supplier_perf_rollup','_sup753_gate','_sup753_kyc','_sup753_menu',
         '_sup753_wa','_sup753_row','_sup753_deny','_sup753_kv','_sup753_pct',
         '_sup753_metrics')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $c753grants$;

-- ═══════════════════════════════════════════════════════════════════════════
-- #753 REVISION — Om rejected the first layout (3 Sep, 12:34 IST):
--
--   "This is a supplier INFO list, not an orders tab."
--
-- The list carried eight filter chips, a Sort block, and a row crammed with a
-- waiting count, a rupee amount, a KYC badge and an overflow menu. It is now
-- the plainest thing that can answer "which supplier?": a search box, ONE
-- horizontally scrollable row of five chips, and a row that is a NAME with
-- city · code · a status dot under it. Every number and every action moved to
-- the supplier page, which is where you go when you have picked one.
--
-- The zone chip is gone entirely: the header's zone picker already says which
-- zone you are in, and printing it twice was the app answering a question the
-- shell had already answered.
-- ═══════════════════════════════════════════════════════════════════════════

insert into public.ui_copy (key, value) values
  ('admin_sup2.sort_sheet_title', to_jsonb('Sort suppliers'::text)),
  ('admin_sup2.filters_label',    to_jsonb('Filters'::text)),
  ('admin_sup2.call_label',       to_jsonb('Call'::text)),
  ('admin_sup2.wa_label',         to_jsonb('WhatsApp'::text)),
  ('admin_sup2.i_waiting',        to_jsonb('Inquiries waiting'::text)),
  ('admin_sup2.i_dues',           to_jsonb('Dues pending'::text)),
  ('admin_sup2.i_kyc',            to_jsonb('KYC / licence'::text)),
  ('admin_sup2.i_at_a_glance',    to_jsonb('At a glance'::text)),
  ('admin_sup2.tab_info',         to_jsonb('Info'::text))
on conflict (key) do nothing;

update public.admin_supplier_tab set label = public._c('admin_sup2.tab_info')
 where tab_key = 'profile';

create or replace function public.admin_suppliers_console(
  p_filters jsonb default '[]'::jsonb,
  p_sort    text  default null,
  p_search  text  default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role  text := public._sup753_gate();
  v_zone  smallint := public.admin_active_zone();
  v_f     text[] := coalesce((select array_agg(x#>>'{}') from jsonb_array_elements(coalesce(p_filters,'[]'::jsonb)) x), '{}'::text[]);
  -- A–Z is the default now. You scan this list for a NAME.
  v_sort  text := lower(coalesce(nullif(btrim(coalesce(p_sort,'')),''),'name'));
  v_q     text := lower(btrim(coalesce(p_search,'')));
  v_cfg   jsonb := coalesce((select value from app_settings where key='supplier_status_values'),'{}'::jsonb);
  v_active text := lower(coalesce(v_cfg->>'active','active'));
  v_copy  jsonb;
  v_rows  jsonb; v_chips jsonb; v_n int;
begin
  if v_role = 'none' then
    return jsonb_build_object('ok', false, 'allowed', false,
                              'message', public._c('admin_sup2.forbidden'));
  end if;

  v_copy := jsonb_build_object(
    'count_one',  public._c('admin_sup2.count_one'),
    'count_many', public._c('admin_sup2.count_many'));

  with base as (
    select sp.id, sp.supplier_name, sp.contact_name, sp.phone, sp.supplier_code,
           sp.city, sp.state, sp.status, sp."SPN" as spn, sp.zone_id,
           sp.drug_license, sp.dl_1, sp.gstin, sp.gst, sp.dl_expiry, sp.gstin_expiry
      from supplier_profiles sp
     where coalesce(sp.is_deleted,false) = false
       and (v_zone is null or sp.zone_id = v_zone)
  ),
  paid as (select sp.supplier_order_id, sum(coalesce(sp.amount,0)) amt
             from supplier_payments sp group by 1),
  dues as (
    select so.supplier_id,
           sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0), 0)) as due
      from supplier_orders so
      left join paid p on p.supplier_order_id = so.id
     where so.settled_at is null
       and lower(coalesce(so.status,'')) <> 'cancelled'
       and so.supplier_id is not null
     group by 1
  ),
  e as (
    select b.*,
           coalesce(d.due,0) as dues_amt,
           (coalesce(m.total,0) - coalesce(m.matched,0)) as unmatched,
           (public._sup753_kyc(coalesce(nullif(b.drug_license,''), b.dl_1),
                               coalesce(nullif(b.gstin,''), b.gst),
                               b.dl_expiry, b.gstin_expiry)->>'state') as kyc_state,
           (lower(coalesce(b.status,'')) = v_active) as is_active
      from base b
      left join dues d on d.supplier_id = b.id
      left join supplier_match_status_v m on m.supplier_id = b.id
  ),
  filtered as (
    select c.* from e c
     where (not ('active'    = any(v_f)) or c.is_active)
       and (not ('inactive'  = any(v_f)) or not c.is_active)
       and (not ('unmatched' = any(v_f)) or c.unmatched > 0)
       and (not ('dues'      = any(v_f)) or c.dues_amt > 0)
       and (not ('licence'   = any(v_f)) or c.kyc_state in ('expiring','expired'))
       and (v_q = '' or lower(coalesce(c.supplier_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.contact_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.supplier_code,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.phone,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.city,'')) like '%'||v_q||'%'
                     or exists (select 1 from supplier_company sc
                                 where sc.supplier_id = c.id
                                   and (lower(coalesce(sc.supplier_company,'')) like '%'||v_q||'%'
                                     or lower(coalesce(sc.company_1,'')) like '%'||v_q||'%')))
  ),
  ordered as (
    select f.* from filtered f
     order by case when v_sort = 'spn'  then -coalesce(f.spn,0) end,
              case when v_sort = 'dues' then -f.dues_amt end,
              lower(f.supplier_name)
  )
  -- The row is a NAME and one quiet line under it. Nothing else: no rupees, no
  -- counts, no badge, no menu — those all live on the page you tap through to.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',        o.id,
           'name',      coalesce(nullif(btrim(o.supplier_name),''), o.contact_name, '—'),
           'subtitle',  array_to_string(array_remove(array[
                          nullif(btrim(coalesce(o.city,'')),''),
                          nullif(btrim(coalesce(o.supplier_code,'')),'')], null), '  ·  '),
           'status_label', coalesce(o.status,''),
           'status_tone',  case when o.is_active then 'success' else 'muted' end
         )), '[]'::jsonb), count(*)
    into v_rows, v_n
    from ordered o;

  with e as (
      select b.id,
             (lower(coalesce(b.status,'')) = v_active) as is_active,
             (coalesce(m.total,0) - coalesce(m.matched,0)) as unmatched,
             coalesce(d.due,0) as dues_amt,
             (public._sup753_kyc(coalesce(nullif(b.drug_license,''), b.dl_1),
                                 coalesce(nullif(b.gstin,''), b.gst),
                                 b.dl_expiry, b.gstin_expiry)->>'state') as kyc_state
        from supplier_profiles b
        left join (select so.supplier_id,
                          sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0),0)) due
                     from supplier_orders so
                     left join (select supplier_order_id, sum(coalesce(amount,0)) amt
                                  from supplier_payments group by 1) p
                       on p.supplier_order_id = so.id
                    where so.settled_at is null
                      and lower(coalesce(so.status,'')) <> 'cancelled'
                      and so.supplier_id is not null
                    group by 1) d on d.supplier_id = b.id
        left join supplier_match_status_v m on m.supplier_id = b.id
       where coalesce(b.is_deleted,false) = false
         and (v_zone is null or b.zone_id = v_zone)
  )
  select jsonb_build_array(
    jsonb_build_object('key','active',   'label',public._c('admin_sup2.chip_active'),
                       'count',(select count(*) from e where e.is_active)),
    jsonb_build_object('key','inactive', 'label',public._c('admin_sup2.chip_inactive'),
                       'count',(select count(*) from e where not e.is_active)),
    jsonb_build_object('key','unmatched','label',public._c('admin_sup2.chip_unmatched'),
                       'count',(select count(*) from e where e.unmatched > 0)),
    jsonb_build_object('key','dues',     'label',public._c('admin_sup2.chip_dues'),
                       'count',(select count(*) from e where e.dues_amt > 0)),
    jsonb_build_object('key','licence',  'label',public._c('admin_sup2.chip_licence'),
                       'count',(select count(*) from e where e.kyc_state in ('expiring','expired'))))
    into v_chips;

  select jsonb_agg(c || jsonb_build_object('active', (c->>'key') = any(v_f)))
    into v_chips from jsonb_array_elements(v_chips) c;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'role', v_role,
    'zone_id', v_zone,
    'title', public._c('admin_sup2.title'),
    'search_hint', public._c('admin_sup2.search_hint'),
    'empty_label', public._c('admin_sup2.empty'),
    'filters_label', public._c('admin_sup2.filters_label'),
    'sort_sheet_title', public._c('admin_sup2.sort_sheet_title'),
    'chips', coalesce(v_chips,'[]'::jsonb),
    -- Sorting lives behind the filter icon now; A–Z is what the list opens on.
    'sorts', jsonb_build_array(
       jsonb_build_object('key','name', 'label',public._c('admin_sup2.sort_name'), 'active', v_sort='name'),
       jsonb_build_object('key','spn',  'label',public._c('admin_sup2.sort_spn'),  'active', v_sort='spn'),
       jsonb_build_object('key','dues', 'label',public._c('admin_sup2.sort_dues'), 'active', v_sort='dues')),
    'sort', v_sort,
    'rows', v_rows,
    'count', v_n,
    'count_label', public.count_label(v_copy,'count_one','count_many',v_n));
end $$;

-- The page is where a supplier's numbers and actions live now. The header
-- carries the identity + the two ways to reach them; the ⋮ carries Edit, SPN,
-- Deactivate and Delete-with-reason, which used to sit on every list row.
create or replace function public.admin_supplier_page(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_zone smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb; v_rank int; v_active text;
  v_phone text; v_wa text;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_active := lower(coalesce((select value->>'active' from app_settings
                               where key='supplier_status_values'),'active'));
  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);

  select r into v_rank from (
    select x.id, rank() over (order by coalesce(x."SPN",0) desc, lower(x.supplier_name)) r
      from supplier_profiles x
     where coalesce(x.is_deleted,false) = false
       and (v_zone is null or x.zone_id = v_zone)) q(id, r)
   where q.id = sp.id;

  v_phone := coalesce(nullif(btrim(coalesce(sp.phone,'')),''), nullif(btrim(coalesce(sp.contact_no,'')),''));
  v_wa    := public._sup753_wa(coalesce(nullif(sp.whatsapp_no,''), v_phone));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.tab_key, 'label', t.label,
           'icon', coalesce(t.icon_key,''),
           'rpc', coalesce(nullif(t.rpc,''), 'admin_supplier_tab_'||t.tab_key))
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from admin_supplier_tab t
   where t.is_active
     and (t.feature_key is null
          or public.my_partner_id() is null
          or public.partner_can(t.feature_key,'read'));

  return jsonb_build_object(
    'ok', true,
    'supplier_id', sp.id,
    'title', coalesce(nullif(btrim(sp.supplier_name),''), sp.contact_name, '—'),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(sp.supplier_code,'')),''),
        nullif(btrim(coalesce(sp.city,'')),''),
        nullif(btrim(coalesce(sp.state,'')),'')], null), '  ·  '),
    'phone', coalesce(v_phone,''),
    'contacts', (case when coalesce(v_phone,'') = '' then '[]'::jsonb
                 else jsonb_build_array(
                   jsonb_build_object('key','call','label',public._c('admin_sup2.call_label'),
                                      'url','tel:'||regexp_replace(v_phone,'[^0-9+]','','g'))) end)
                || (case when v_wa is null then '[]'::jsonb
                    else jsonb_build_array(
                      jsonb_build_object('key','whatsapp','label',public._c('admin_sup2.wa_label'),
                                         'url', v_wa)) end),
    'back_label', public._c('admin_sup2.back'),
    'chips', jsonb_build_array(
       public.status_chip('supplier_status', sp.status),
       v_kyc->'chip'),
    'spn_label', public._c('admin_sup2.spn_prefix')||' '||to_char(coalesce(sp."SPN",0),'FM999,999,999'),
    'rank_label', public._c('admin_sup2.rank_prefix')||coalesce(v_rank,0)::text,
    'zone_label', coalesce((select z.name from zones z where z.id = sp.zone_id),
                           public._c('admin_sup2.no_zone')),
    'menu', public._sup753_menu(sp.id, coalesce(sp.supplier_name,''),
                                coalesce(nullif(sp.whatsapp_no,''), v_phone),
                                (lower(coalesce(sp.status,'')) = v_active)),
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key','profile'),
    'empty_label', public._c('admin_sup2.tab_empty'));
end $$;

-- Info gains the three facts the list stopped showing.
create or replace function public.admin_supplier_tab_profile(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_zone smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype; v_kyc jsonb; v_docs jsonb;
  v_waiting int; v_dues numeric; v_copy jsonb;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);
  v_copy := jsonb_build_object('one', public._c('admin_sup2.waiting_one'),
                               'many', public._c('admin_sup2.waiting_many'));

  select count(*)::int into v_waiting
    from inquiry i
   where lower(btrim(coalesce(i.current_supplier,''))) = lower(btrim(sp.supplier_name))
     and lower(coalesce(i.current_status,'')) = 'confirmation pending'
     and (v_zone is null or i.zone_id = v_zone);

  select coalesce(sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0),0)),0)
    into v_dues
    from supplier_orders so
    left join (select supplier_order_id, sum(coalesce(amount,0)) amt
                 from supplier_payments group by 1) p on p.supplier_order_id = so.id
   where so.supplier_id = sp.id and so.settled_at is null
     and lower(coalesce(so.status,'')) <> 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'title', coalesce(nullif(d.title,''), d.file_name, d.kind),
           'subtitle', coalesce(public.ist_fmt(d.ready_at,'day_mon_year'), ''),
           'chip', public.status_chip('doc_status', d.status))
         order by d.requested_at desc), '[]'::jsonb)
    into v_docs
    from supplier_document d
   where d.supplier_id = sp.id;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','title',public._c('admin_sup2.i_at_a_glance'),'tiles', jsonb_build_array(
      jsonb_build_object('label',public._c('admin_sup2.i_waiting'),
        'value', case when v_waiting = 0 then '0'
                      else public.count_label(v_copy,'one','many',v_waiting) end,
        'tone', case when v_waiting > 0 then 'warning' else 'neutral' end),
      jsonb_build_object('label',public._c('admin_sup2.i_dues'),
        'value', public.inr_money(v_dues),
        'tone', case when v_dues > 0 then 'danger' else 'neutral' end),
      jsonb_build_object('label',public._c('admin_sup2.i_kyc'),
        'value', v_kyc->'chip'->>'label',
        'tone', case v_kyc->>'state' when 'ok' then 'success'
                                     when 'expiring' then 'warning' else 'danger' end))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_business'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_name'),   sp.supplier_name),
      public._sup753_kv(public._c('admin_sup2.f_code'),   sp.supplier_code),
      public._sup753_kv(public._c('admin_sup2.f_type'),   coalesce(nullif(sp.stockist_type,''), sp.store_type)),
      public._sup753_kv(public._c('admin_sup2.f_zone'),   (select z.name from zones z where z.id = sp.zone_id)),
      public._sup753_kv(public._c('admin_sup2.f_status'), sp.status),
      public._sup753_kv(public._c('admin_sup2.f_approved'), public.ist_fmt(sp.approved_at,'day_mon_year')),
      public._sup753_kv(public._c('admin_sup2.f_created'),  public.ist_fmt(sp.created_at,'day_mon_year')))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_contact'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_person'),   coalesce(nullif(sp.contact_person,''), sp.contact_name)),
      public._sup753_kv(public._c('admin_sup2.f_phone'),    coalesce(nullif(sp.phone,''), sp.contact_no)),
      public._sup753_kv(public._c('admin_sup2.f_whatsapp'), sp.whatsapp_no),
      public._sup753_kv(public._c('admin_sup2.f_email'),    sp.email),
      public._sup753_kv(public._c('admin_sup2.f_address'),  coalesce(nullif(sp.address,''), sp.street_address)),
      public._sup753_kv(public._c('admin_sup2.f_city'),
        array_to_string(array_remove(array[nullif(btrim(coalesce(sp.city,'')),''),
                                           nullif(btrim(coalesce(sp.state,'')),'')], null), ', ')))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_trade'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_payment'), coalesce(nullif(sp.payment_term,''), sp.payment_type)),
      public._sup753_kv(public._c('admin_sup2.f_margin'),  sp.margin),
      public._sup753_kv(public._c('admin_sup2.f_cd'),      sp.cd_condition),
      public._sup753_kv(public._c('admin_sup2.f_deal'),    sp.deal))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_kyc'),
      'chip', v_kyc->'chip', 'rows', jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_dl'),     coalesce(nullif(sp.drug_license,''), sp.dl_1)),
      public._sup753_kv(public._c('admin_sup2.f_dl_exp'),
        case when sp.dl_expiry is null then '' else to_char(sp.dl_expiry,'FMDD Mon YYYY') end),
      public._sup753_kv(public._c('admin_sup2.f_gst'),    coalesce(nullif(sp.gstin,''), sp.gst)),
      public._sup753_kv(public._c('admin_sup2.f_gst_exp'),
        case when sp.gstin_expiry is null then '' else to_char(sp.gstin_expiry,'FMDD Mon YYYY') end),
      public._sup753_kv(public._c('admin_sup2.f_kyc_state'), v_kyc->'chip'->>'label'))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.p_docs'),
      'empty', public._c('admin_sup2.p_docs_empty'), 'items', v_docs)));
end $$;

-- Grants again for the two functions just replaced.
do $c753g2$
declare f record;
begin
  for f in select p.oid::regprocedure::text as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public'
              and p.proname in ('admin_suppliers_console','admin_supplier_page',
                                'admin_supplier_tab_profile')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $c753g2$;

-- ═══════════════════════════════════════════════════════════════════════════
-- #753 REVISION 2 — the SPN factor editor (Om, 3 Sep 12:48 IST).
--
-- Tapping "SPN" on the old supplier card opened the four-factor editor. The
-- card is gone, so the editor moved to the page: the SPN chip in the header
-- and an "SPN factors" card at the top of Info both open it. The formula is
-- untouched — margin/cd_condition/behaviour/payment_term still carry their own
-- points, supplier_spn_propagate() still re-ranks on save. What changes is
-- only where you tap.
--
-- The four field NAMES were Dart constants (spnFieldDisplayLabel). They are
-- copy rows now, so renaming "CD Condition" is an UPDATE.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy (key, value) values
  ('admin_sup2.spn_title',   to_jsonb('SPN factors'::text)),
  ('admin_sup2.spn_edit',    to_jsonb('Edit SPN factors'::text)),
  ('admin_sup2.spn_save',    to_jsonb('Save'::text)),
  ('admin_sup2.spn_cancel',  to_jsonb('Cancel'::text)),
  ('admin_sup2.spn_total',   to_jsonb('SPN total'::text)),
  ('admin_sup2.spn_rank',    to_jsonb('Rank in zone'::text)),
  ('admin_sup2.spn_saved',   to_jsonb('SPN updated'::text)),
  ('admin_sup2.spn_unset',   to_jsonb('Not set'::text)),
  ('admin_sup2.spn_pts',     to_jsonb('{n} pts'::text)),
  ('admin_sup2.spn_f_margin',       to_jsonb('Margin'::text)),
  ('admin_sup2.spn_f_cd_condition', to_jsonb('CD condition'::text)),
  ('admin_sup2.spn_f_behaviour',    to_jsonb('Behaviour'::text)),
  ('admin_sup2.spn_f_payment_term', to_jsonb('Payment term'::text))
on conflict (key) do nothing;

-- One place decides the four factors, their columns and their current values.
-- The editor renders it; it does not know what an SPN factor is.
create or replace function public._sup753_spn_block(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  sp supplier_profiles%rowtype;
  v_zone smallint := public.admin_active_zone();
  v_rank int;
begin
  select * into sp from supplier_profiles where id = p_supplier_id;
  if not found then return '{}'::jsonb; end if;

  select r into v_rank from (
    select x.id, rank() over (order by coalesce(x."SPN",0) desc, lower(x.supplier_name)) r
      from supplier_profiles x
     where coalesce(x.is_deleted,false) = false
       and (v_zone is null or x.zone_id = v_zone)) q(id, r)
   where q.id = sp.id;

  return jsonb_build_object(
    'kind',  'spn',
    'title', public._c('admin_sup2.spn_title'),
    'edit_label',   public._c('admin_sup2.spn_edit'),
    'save_label',   public._c('admin_sup2.spn_save'),
    'cancel_label', public._c('admin_sup2.spn_cancel'),
    'saved_label',  public._c('admin_sup2.spn_saved'),
    'unset_label',  public._c('admin_sup2.spn_unset'),
    'points_format',public._c('admin_sup2.spn_pts'),
    'total_label',  public._c('admin_sup2.spn_total'),
    'total_value',  to_char(coalesce(sp."SPN",0),'FM999,999,999'),
    'rank_label',   public._c('admin_sup2.spn_rank'),
    'rank_value',   public._c('admin_sup2.rank_prefix')||coalesce(v_rank,0)::text,
    'supplier_id',  sp.id,
    -- field = the spn_options key; col / points_col are exactly what
    -- admin_set_supplier_spn(p_id, p_field) expects back.
    'factors', jsonb_build_array(
      jsonb_build_object('field','margin','label',public._c('admin_sup2.spn_f_margin'),
        'col','margin','points_col','margin_points',
        'value', coalesce(nullif(btrim(coalesce(sp.margin,'')),''), null),
        'points', coalesce(sp.margin_points,0)),
      jsonb_build_object('field','cd_condition','label',public._c('admin_sup2.spn_f_cd_condition'),
        'col','cd_condition','points_col','cd_points',
        'value', coalesce(nullif(btrim(coalesce(sp.cd_condition,'')),''), null),
        'points', coalesce(sp.cd_points,0)),
      jsonb_build_object('field','behaviour','label',public._c('admin_sup2.spn_f_behaviour'),
        'col','behaviour','points_col','behaviour_points',
        'value', coalesce(nullif(btrim(coalesce(sp.behaviour,'')),''), null),
        'points', coalesce(sp.behaviour_points,0)),
      jsonb_build_object('field','payment_term','label',public._c('admin_sup2.spn_f_payment_term'),
        'col','payment_type','points_col','payment_term_points',
        'value', coalesce(nullif(btrim(coalesce(sp.payment_type,'')),''), null),
        'points', coalesce(sp.payment_term_points,0))));
end $$;

-- Info opens with the SPN card, then the three numbers the list stopped
-- carrying, then the detail.
create or replace function public.admin_supplier_tab_profile(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_zone smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype; v_kyc jsonb; v_docs jsonb;
  v_waiting int; v_dues numeric; v_copy jsonb;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);
  v_copy := jsonb_build_object('one', public._c('admin_sup2.waiting_one'),
                               'many', public._c('admin_sup2.waiting_many'));

  select count(*)::int into v_waiting
    from inquiry i
   where lower(btrim(coalesce(i.current_supplier,''))) = lower(btrim(sp.supplier_name))
     and lower(coalesce(i.current_status,'')) = 'confirmation pending'
     and (v_zone is null or i.zone_id = v_zone);

  select coalesce(sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0),0)),0)
    into v_dues
    from supplier_orders so
    left join (select supplier_order_id, sum(coalesce(amount,0)) amt
                 from supplier_payments group by 1) p on p.supplier_order_id = so.id
   where so.supplier_id = sp.id and so.settled_at is null
     and lower(coalesce(so.status,'')) <> 'cancelled';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'title', coalesce(nullif(d.title,''), d.file_name, d.kind),
           'subtitle', coalesce(public.ist_fmt(d.ready_at,'day_mon_year'), ''),
           'chip', public.status_chip('doc_status', d.status))
         order by d.requested_at desc), '[]'::jsonb)
    into v_docs
    from supplier_document d
   where d.supplier_id = sp.id;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    public._sup753_spn_block(sp.id),
    jsonb_build_object('kind','tiles','title',public._c('admin_sup2.i_at_a_glance'),'tiles', jsonb_build_array(
      jsonb_build_object('label',public._c('admin_sup2.i_waiting'),
        'value', case when v_waiting = 0 then '0'
                      else public.count_label(v_copy,'one','many',v_waiting) end,
        'tone', case when v_waiting > 0 then 'warning' else 'neutral' end),
      jsonb_build_object('label',public._c('admin_sup2.i_dues'),
        'value', public.inr_money(v_dues),
        'tone', case when v_dues > 0 then 'danger' else 'neutral' end),
      jsonb_build_object('label',public._c('admin_sup2.i_kyc'),
        'value', v_kyc->'chip'->>'label',
        'tone', case v_kyc->>'state' when 'ok' then 'success'
                                     when 'expiring' then 'warning' else 'danger' end))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_business'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_name'),   sp.supplier_name),
      public._sup753_kv(public._c('admin_sup2.f_code'),   sp.supplier_code),
      public._sup753_kv(public._c('admin_sup2.f_type'),   coalesce(nullif(sp.stockist_type,''), sp.store_type)),
      public._sup753_kv(public._c('admin_sup2.f_zone'),   (select z.name from zones z where z.id = sp.zone_id)),
      public._sup753_kv(public._c('admin_sup2.f_status'), sp.status),
      public._sup753_kv(public._c('admin_sup2.f_approved'), public.ist_fmt(sp.approved_at,'day_mon_year')),
      public._sup753_kv(public._c('admin_sup2.f_created'),  public.ist_fmt(sp.created_at,'day_mon_year')))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_contact'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_person'),   coalesce(nullif(sp.contact_person,''), sp.contact_name)),
      public._sup753_kv(public._c('admin_sup2.f_phone'),    coalesce(nullif(sp.phone,''), sp.contact_no)),
      public._sup753_kv(public._c('admin_sup2.f_whatsapp'), sp.whatsapp_no),
      public._sup753_kv(public._c('admin_sup2.f_email'),    sp.email),
      public._sup753_kv(public._c('admin_sup2.f_address'),  coalesce(nullif(sp.address,''), sp.street_address)),
      public._sup753_kv(public._c('admin_sup2.f_city'),
        array_to_string(array_remove(array[nullif(btrim(coalesce(sp.city,'')),''),
                                           nullif(btrim(coalesce(sp.state,'')),'')], null), ', ')))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_trade'),'rows',jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_payment'), coalesce(nullif(sp.payment_term,''), sp.payment_type)),
      public._sup753_kv(public._c('admin_sup2.f_margin'),  sp.margin),
      public._sup753_kv(public._c('admin_sup2.f_cd'),      sp.cd_condition),
      public._sup753_kv(public._c('admin_sup2.f_deal'),    sp.deal))),
    jsonb_build_object('kind','kv','title',public._c('admin_sup2.p_kyc'),
      'chip', v_kyc->'chip', 'rows', jsonb_build_array(
      public._sup753_kv(public._c('admin_sup2.f_dl'),     coalesce(nullif(sp.drug_license,''), sp.dl_1)),
      public._sup753_kv(public._c('admin_sup2.f_dl_exp'),
        case when sp.dl_expiry is null then '' else to_char(sp.dl_expiry,'FMDD Mon YYYY') end),
      public._sup753_kv(public._c('admin_sup2.f_gst'),    coalesce(nullif(sp.gstin,''), sp.gst)),
      public._sup753_kv(public._c('admin_sup2.f_gst_exp'),
        case when sp.gstin_expiry is null then '' else to_char(sp.gstin_expiry,'FMDD Mon YYYY') end),
      public._sup753_kv(public._c('admin_sup2.f_kyc_state'), v_kyc->'chip'->>'label'))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.p_docs'),
      'empty', public._c('admin_sup2.p_docs_empty'), 'items', v_docs)));
end $$;

-- The header's SPN chip opens the same editor, so the page carries the block.
create or replace function public.admin_supplier_page(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_zone smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb; v_rank int; v_active text;
  v_phone text; v_wa text;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_active := lower(coalesce((select value->>'active' from app_settings
                               where key='supplier_status_values'),'active'));
  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);

  select r into v_rank from (
    select x.id, rank() over (order by coalesce(x."SPN",0) desc, lower(x.supplier_name)) r
      from supplier_profiles x
     where coalesce(x.is_deleted,false) = false
       and (v_zone is null or x.zone_id = v_zone)) q(id, r)
   where q.id = sp.id;

  v_phone := coalesce(nullif(btrim(coalesce(sp.phone,'')),''), nullif(btrim(coalesce(sp.contact_no,'')),''));
  v_wa    := public._sup753_wa(coalesce(nullif(sp.whatsapp_no,''), v_phone));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.tab_key, 'label', t.label,
           'icon', coalesce(t.icon_key,''),
           'rpc', coalesce(nullif(t.rpc,''), 'admin_supplier_tab_'||t.tab_key))
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from admin_supplier_tab t
   where t.is_active
     and (t.feature_key is null
          or public.my_partner_id() is null
          or public.partner_can(t.feature_key,'read'));

  return jsonb_build_object(
    'ok', true,
    'supplier_id', sp.id,
    'title', coalesce(nullif(btrim(sp.supplier_name),''), sp.contact_name, '—'),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(sp.supplier_code,'')),''),
        nullif(btrim(coalesce(sp.city,'')),''),
        nullif(btrim(coalesce(sp.state,'')),'')], null), '  ·  '),
    'phone', coalesce(v_phone,''),
    'contacts', (case when coalesce(v_phone,'') = '' then '[]'::jsonb
                 else jsonb_build_array(
                   jsonb_build_object('key','call','label',public._c('admin_sup2.call_label'),
                                      'url','tel:'||regexp_replace(v_phone,'[^0-9+]','','g'))) end)
                || (case when v_wa is null then '[]'::jsonb
                    else jsonb_build_array(
                      jsonb_build_object('key','whatsapp','label',public._c('admin_sup2.wa_label'),
                                         'url', v_wa)) end),
    'back_label', public._c('admin_sup2.back'),
    'chips', jsonb_build_array(
       public.status_chip('supplier_status', sp.status),
       v_kyc->'chip'),
    'spn_label', public._c('admin_sup2.spn_prefix')||' '||to_char(coalesce(sp."SPN",0),'FM999,999,999'),
    'rank_label', public._c('admin_sup2.rank_prefix')||coalesce(v_rank,0)::text,
    -- The chip is tappable because the block is here; no chip, no editor.
    'spn_block', public._sup753_spn_block(sp.id),
    'zone_label', coalesce((select z.name from zones z where z.id = sp.zone_id),
                           public._c('admin_sup2.no_zone')),
    'menu', public._sup753_menu(sp.id, coalesce(sp.supplier_name,''),
                                coalesce(nullif(sp.whatsapp_no,''), v_phone),
                                (lower(coalesce(sp.status,'')) = v_active)),
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key','profile'),
    'empty_label', public._c('admin_sup2.tab_empty'));
end $$;

do $c753g3$
declare f record;
begin
  for f in select p.oid::regprocedure::text as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public'
              and p.proname in ('admin_supplier_page','admin_supplier_tab_profile',
                                '_sup753_spn_block')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $c753g3$;

-- ═══════════════════════════════════════════════════════════════════════════
-- #753 REVISION 3 — the Companies tab (Om, 3 Sep 12:51 IST).
--
-- "Unmap works, Map does nothing." The first cut mapped by typing a name into
-- a prompt, which is not a workflow — you cannot type 18,663 catalogue names
-- from memory. And it wrote company_1 ONLY, which quietly threw away the whole
-- point of the thirty slots: one supplier company legitimately maps to MANY
-- catalogue companies ("Sun Pharma" → Sun Pharma Laboratories AND Sun
-- Pharmaceutical Industries).
--
-- So: Map opens a SEARCH over the catalogue with map_supplier_companies()'s
-- auto-match suggestions pinned on top; picking one appends into the first
-- free slot; every mapped catalogue company shows as its own removable chip.
--
-- Propagation stays incremental (#678). refresh_company_suppliers_trg already
-- repoints only the touched company keys; this adds the zone_resync_queue rows
-- for exactly those keys, the same shape _supplier_zone_incremental() uses.
-- Nothing here calls resync_company_suppliers() or zone_full_rebuild().
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy (key, value) values
  ('admin_sup2.c_add',        to_jsonb('Add company'::text)),
  ('admin_sup2.c_add_title',  to_jsonb('Add a supplier company'::text)),
  ('admin_sup2.c_add_hint',   to_jsonb('Name as the supplier writes it'::text)),
  ('admin_sup2.c_add_ok',     to_jsonb('Add'::text)),
  ('admin_sup2.c_automatch',  to_jsonb('Auto-match all'::text)),
  ('admin_sup2.c_search_title', to_jsonb('Map to catalogue company'::text)),
  ('admin_sup2.c_search_hint',  to_jsonb('Search catalogue companies'::text)),
  ('admin_sup2.c_suggested',  to_jsonb('Suggested'::text)),
  ('admin_sup2.c_all_companies', to_jsonb('All companies'::text)),
  ('admin_sup2.c_no_matches', to_jsonb('No catalogue company matches that.'::text)),
  ('admin_sup2.c_rename',     to_jsonb('Rename'::text)),
  ('admin_sup2.c_rename_title', to_jsonb('Rename supplier company'::text)),
  ('admin_sup2.c_delete',     to_jsonb('Delete'::text)),
  ('admin_sup2.c_delete_title', to_jsonb('Delete this supplier company?'::text)),
  ('admin_sup2.c_delete_body',  to_jsonb('It stops counting towards this supplier''s coverage. Mapped catalogue companies are unaffected.'::text)),
  ('admin_sup2.c_delete_ok',  to_jsonb('Delete'::text)),
  ('admin_sup2.c_mapped_ok',  to_jsonb('Mapped to {name}'::text)),
  ('admin_sup2.c_unmapped_ok',to_jsonb('{name} removed'::text)),
  ('admin_sup2.c_added_ok',   to_jsonb('{name} added'::text)),
  ('admin_sup2.c_automatch_ok', to_jsonb('{n} mapped automatically'::text)),
  ('admin_sup2.c_full',       to_jsonb('This company already fills all 30 slots.'::text))
on conflict (key) do nothing;

-- Every catalogue name currently on one supplier_company row.
create or replace function public._sup753_mapped(p_id uuid)
returns text[]
language sql stable security definer set search_path to 'public'
as $$
  select coalesce(array_agg(v order by g), '{}'::text[])
    from generate_series(1,30) g
    cross join lateral (
      select nullif(btrim(coalesce(to_jsonb(sc)->>('company_'||g),'')),'') as v
        from supplier_company sc where sc.id = p_id) x
   where x.v is not null;
$$;

-- Enqueue ONLY the company keys this write touched (#678). The zone resync
-- drain picks them up; nothing rebuilds a zone.
create or replace function public._sup753_zone_enqueue(p_names text[])
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare v_names text[] := (select array_agg(distinct lower(btrim(n)))
                             from unnest(coalesce(p_names,'{}'::text[])) n
                            where btrim(coalesce(n,'')) <> '');
begin
  if v_names is null or array_length(v_names,1) is null then return; end if;
  if to_regclass('public.zone_resync_queue') is null
     or to_regclass('public.zone_company_lookup') is null then return; end if;

  insert into public.zone_resync_queue (zone_id, company_key)
  select l.zone_id, l.key
    from public.zone_company_lookup l
   where lower(btrim(l.key)) = any(v_names)
  on conflict (zone_id, company_key) do update set enqueued_at = now();
end $$;

-- The first cut of this function took two arguments and wrote company_1 only.
-- Replacing it with the three-argument version below leaves BOTH signatures
-- resolvable, and PostgREST cannot choose between them ("is not unique"), so
-- the old one goes. It is a function this same change created minutes ago and
-- holds no data.
drop function if exists public.admin_supplier_company_map(uuid, text);

-- MAP: append into the first free slot. Never overwrites an existing mapping.
create or replace function public.admin_supplier_company_map(
  p_id uuid, p_company text default '', p_learn boolean default true)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_name text := btrim(coalesce(p_company,''));
  v_sid uuid; v_raw text; v_slot int; v_stem text;
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  select sc.supplier_id, sc.supplier_company into v_sid, v_raw
    from supplier_company sc where sc.id = p_id;
  if v_sid is null then raise exception 'company_row_not_found'; end if;
  if (public._sup753_row(v_sid)).id is null then raise exception 'not_authorized_zone'; end if;
  if v_name = '' then raise exception 'company_required'; end if;

  -- Already mapped to this one: a no-op, not a duplicate slot.
  if lower(v_name) = any (select lower(x) from unnest(public._sup753_mapped(p_id)) x) then
    return jsonb_build_object('ok', true, 'id', p_id::text, 'company', v_name,
      'message', replace(public._c('admin_sup2.c_mapped_ok'),'{name}', v_name));
  end if;

  select g into v_slot from generate_series(1,30) g
   where nullif(btrim(coalesce((select to_jsonb(sc)->>('company_'||g)
                                  from supplier_company sc where sc.id = p_id),'')),'') is null
   order by g limit 1;
  if v_slot is null then
    return jsonb_build_object('ok', false, 'error','no_slot',
      'message', public._c('admin_sup2.c_full'));
  end if;

  execute format('update supplier_company set %I = $1, match_state = ''done'', '
                 'matched_at = now() where id = $2', 'company_'||v_slot)
    using v_name, p_id;

  -- Learn the alias so the next import of this raw name resolves itself.
  if coalesce(p_learn,true) and to_regclass('public.company_alias') is not null then
    begin
      v_stem := public.company_stem(v_raw);
      if v_stem is not null then
        insert into public.company_alias(variant_canonical, group_key, note)
        values (v_stem, v_name, 'admin map #753')
        on conflict (variant_canonical) do update set group_key = excluded.group_key;
      end if;
    exception when others then null;
    end;
  end if;

  perform public._sup753_zone_enqueue(array[v_name]);

  return jsonb_build_object('ok', true, 'id', p_id::text, 'company', v_name,
    'slot', v_slot,
    'message', replace(public._c('admin_sup2.c_mapped_ok'),'{name}', v_name));
end $$;

-- UNMAP one chip by name, then compact the slots so slot 1 is never a hole.
create or replace function public.admin_supplier_company_unmap(
  p_id uuid, p_company text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_name text := btrim(coalesce(p_company,''));
  v_sid uuid; v_keep text[]; i int;
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  select sc.supplier_id into v_sid from supplier_company sc where sc.id = p_id;
  if v_sid is null then raise exception 'company_row_not_found'; end if;
  if (public._sup753_row(v_sid)).id is null then raise exception 'not_authorized_zone'; end if;

  select coalesce(array_agg(x order by ord), '{}'::text[]) into v_keep
    from unnest(public._sup753_mapped(p_id)) with ordinality t(x, ord)
   where lower(btrim(x)) <> lower(v_name);

  for i in 1..30 loop
    execute format('update supplier_company set %I = $1 where id = $2', 'company_'||i)
      using (case when i <= coalesce(array_length(v_keep,1),0) then v_keep[i] else null end),
            p_id;
  end loop;

  update supplier_company
     set match_state = case when coalesce(array_length(v_keep,1),0) = 0
                            then 'needs_review' else 'done' end,
         matched_at  = case when coalesce(array_length(v_keep,1),0) = 0
                            then null else now() end
   where id = p_id;

  perform public._sup753_zone_enqueue(array[v_name]);

  return jsonb_build_object('ok', true, 'id', p_id::text,
    'message', replace(public._c('admin_sup2.c_unmapped_ok'),'{name}', v_name));
end $$;

-- The search behind Map: auto-match suggestions first, then the catalogue.
create or replace function public.admin_supplier_company_search(
  p_id uuid, p_q text default '', p_limit integer default 40)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_sid uuid; v_raw text; v_q text := lower(btrim(coalesce(p_q,'')));
  v_lim int := least(greatest(coalesce(p_limit,40),1),100);
  v_sug jsonb; v_all jsonb; v_mapped text[];
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  select sc.supplier_id, sc.supplier_company into v_sid, v_raw
    from supplier_company sc where sc.id = p_id;
  if v_sid is null then return public._sup753_deny(false); end if;
  if (public._sup753_row(v_sid)).id is null then return public._sup753_deny(false); end if;

  v_mapped := public._sup753_mapped(p_id);

  -- The suggestions the matcher would have picked, minus anything already on
  -- the row. Only when the admin has not started typing.
  if v_q = '' then
    select coalesce(jsonb_agg(jsonb_build_object('name', m)), '[]'::jsonb)
      into v_sug
      from (select unnest(matches) m
              from public.map_supplier_companies(v_sid)
             where sc_id = p_id
             limit 1) s
     where lower(btrim(s.m)) <> all (select lower(btrim(x)) from unnest(v_mapped) x);
  else
    v_sug := '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('name', c.company_name)
                  order by c.company_name), '[]'::jsonb)
    into v_all
    from (select c.company_name from company c
           where (v_q = '' or lower(c.company_name) like '%'||v_q||'%')
             and lower(btrim(c.company_name)) <> all
                 (select lower(btrim(x)) from unnest(v_mapped) x)
           order by (case when lower(c.company_name) like v_q||'%' then 0 else 1 end),
                    c.company_name
           limit v_lim) c;

  return jsonb_build_object('ok', true,
    'row_id', p_id, 'supplier_company', coalesce(v_raw,''),
    'title', public._c('admin_sup2.c_search_title'),
    'hint',  public._c('admin_sup2.c_search_hint'),
    'cancel', public._c('admin_sup2.c_cancel'),
    'suggested_label', public._c('admin_sup2.c_suggested'),
    'all_label', public._c('admin_sup2.c_all_companies'),
    'empty', public._c('admin_sup2.c_no_matches'),
    'suggested', coalesce(v_sug,'[]'::jsonb),
    'companies', v_all);
end $$;

create or replace function public.admin_supplier_company_delete(p_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_role text := public._sup753_gate(); v_sid uuid; v_names text[];
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  select sc.supplier_id into v_sid from supplier_company sc where sc.id = p_id;
  if v_sid is null then raise exception 'company_row_not_found'; end if;
  if (public._sup753_row(v_sid)).id is null then raise exception 'not_authorized_zone'; end if;

  v_names := public._sup753_mapped(p_id);
  delete from supplier_company where id = p_id;
  perform public._sup753_zone_enqueue(v_names);
  return jsonb_build_object('ok', true, 'id', p_id::text);
end $$;

create or replace function public.admin_supplier_company_automatch(p_supplier_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate(); sp supplier_profiles%rowtype;
  r record; v_n int := 0; v_names text[] := '{}';
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then raise exception 'not_authorized_zone'; end if;

  -- Only rows that have NO mapping yet, and only when the matcher is certain
  -- enough to have produced exactly one candidate. Anything ambiguous stays
  -- for a human — an auto-match that guesses is worse than none.
  for r in
    select m.sc_id, m.matches[1] as name
      from public.map_supplier_companies(p_supplier_id) m
      join supplier_company sc on sc.id = m.sc_id
     where coalesce(array_length(m.matches,1),0) = 1
       and coalesce(array_length(public._sup753_mapped(m.sc_id),1),0) = 0
  loop
    execute format('update supplier_company set company_1 = $1, match_state = ''done'', '
                   'matched_at = now() where id = $2') using r.name, r.sc_id;
    v_names := v_names || r.name;
    v_n := v_n + 1;
  end loop;

  perform public._sup753_zone_enqueue(v_names);

  return jsonb_build_object('ok', true, 'mapped', v_n,
    'message', replace(public._c('admin_sup2.c_automatch_ok'),'{n}', v_n::text));
end $$;

-- The tab: unmapped first (they are the work), every mapped catalogue company
-- as its own removable chip, and the three row actions.
create or replace function public.admin_supplier_tab_companies(
  p_supplier_id uuid, p_filter text default 'all')
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  v_f text := lower(coalesce(nullif(btrim(coalesce(p_filter,'')),''),'all'));
  v_total int; v_mapped int; v_items jsonb; v_pct numeric;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  select count(*),
         count(*) filter (where coalesce(array_length(public._sup753_mapped(sc.id),1),0) > 0)
    into v_total, v_mapped
    from supplier_company sc where sc.supplier_id = sp.id;

  v_pct := case when coalesce(v_total,0) = 0 then 0
                else round((v_mapped::numeric * 100) / v_total, 1) end;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', x.id,
           'title', x.raw,
           'subtitle', case when x.is_mapped then ''
                            else public._c('admin_sup2.c_unmapped_row') end,
           'chip', jsonb_build_object('show', true,
             'label', case when x.is_mapped then public._c('admin_sup2.c_mapped')
                           else public._c('admin_sup2.c_unmapped') end,
             'bg',     case when x.is_mapped then '#D1FAE5' else '#FEF3C7' end,
             'fg',     case when x.is_mapped then '#065F46' else '#92400E' end,
             'border', case when x.is_mapped then '#A7F3D0' else '#FDE68A' end),
           -- One chip per mapped catalogue company, each removable. This is
           -- the thirty slots finally showing up in the UI.
           'chips', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'label', m,
                       'remove', jsonb_build_object(
                         'rpc','admin_supplier_company_unmap',
                         'args', jsonb_build_object('p_id', x.id, 'p_company', m))))
                from unnest(x.mapped) m), '[]'::jsonb),
           'actions', jsonb_build_array(
             jsonb_build_object('key','map','label',public._c('admin_sup2.c_map'),
               'tone','brand', 'picker', jsonb_build_object(
                 'search_rpc','admin_supplier_company_search',
                 'search_args', jsonb_build_object('p_id', x.id),
                 'apply_rpc','admin_supplier_company_map',
                 'apply_args', jsonb_build_object('p_id', x.id),
                 'apply_key','p_company')),
             jsonb_build_object('key','rename','label',public._c('admin_sup2.c_rename'),
               'tone','neutral','rpc','admin_supplier_company_update',
               'args', jsonb_build_object('p_id', x.id),
               'prompt', jsonb_build_object(
                 'title', public._c('admin_sup2.c_rename_title'),
                 'hint',  public._c('admin_sup2.c_add_hint'),
                 'ok',    public._c('admin_sup2.c_map_ok'),
                 'cancel',public._c('admin_sup2.c_cancel'),
                 'arg',   'p_patch', 'arg_shape','supplier_company',
                 'value', x.raw)),
             jsonb_build_object('key','delete','label',public._c('admin_sup2.c_delete'),
               'tone','danger','rpc','admin_supplier_company_delete',
               'args', jsonb_build_object('p_id', x.id),
               'confirm', jsonb_build_object(
                 'title', public._c('admin_sup2.c_delete_title'),
                 'body',  public._c('admin_sup2.c_delete_body'),
                 'ok',    public._c('admin_sup2.c_delete_ok'),
                 'cancel',public._c('admin_sup2.c_cancel'),
                 'needs_reason', false))))
         -- Unmapped first: they are the queue. Then A–Z inside each group.
         order by x.is_mapped, lower(x.raw)), '[]'::jsonb)
    into v_items
    from (
      select sc.id,
             coalesce(nullif(btrim(coalesce(sc.supplier_company,'')),''),'—') as raw,
             public._sup753_mapped(sc.id) as mapped,
             (coalesce(array_length(public._sup753_mapped(sc.id),1),0) > 0) as is_mapped
        from supplier_company sc
       where sc.supplier_id = sp.id
    ) x
   where (v_f = 'all')
      or (v_f = 'mapped'   and x.is_mapped)
      or (v_f = 'unmapped' and not x.is_mapped);

  return jsonb_build_object('ok', true, 'filter', v_f, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label', public._c('admin_sup2.c_all'),      'value', v_total::text,  'tone','neutral'),
      jsonb_build_object('label', public._c('admin_sup2.c_mapped'),   'value', v_mapped::text, 'tone','success'),
      jsonb_build_object('label', public._c('admin_sup2.c_unmapped'), 'value', (v_total - v_mapped)::text,
                         'tone', case when v_total - v_mapped > 0 then 'warning' else 'neutral' end),
      jsonb_build_object('label', public._c('admin_sup2.c_match'),    'value', to_char(v_pct,'FM990.0')||'%', 'tone','info'))),
    jsonb_build_object('kind','buttons','buttons', jsonb_build_array(
      jsonb_build_object('key','add','label',public._c('admin_sup2.c_add'),'tone','brand',
        'rpc','admin_supplier_company_add',
        'args', jsonb_build_object('p_supplier_id', sp.id,
                                   'p_supplier_name', coalesce(sp.supplier_name,'')),
        'prompt', jsonb_build_object(
          'title', public._c('admin_sup2.c_add_title'),
          'hint',  public._c('admin_sup2.c_add_hint'),
          'ok',    public._c('admin_sup2.c_add_ok'),
          'cancel',public._c('admin_sup2.c_cancel'),
          'arg',   'p_company')),
      jsonb_build_object('key','automatch','label',public._c('admin_sup2.c_automatch'),'tone','neutral',
        'rpc','admin_supplier_company_automatch',
        'args', jsonb_build_object('p_supplier_id', sp.id)),
      -- Bulk link: the paste is split in SQL, so "one per line or comma
      -- separated" stays a backend rule rather than a Dart regex.
      jsonb_build_object('key','bulk','label',public._c('admin_sup2.c_bulk'),'tone','neutral',
        'rpc','admin_supplier_company_bulk_add',
        'args', jsonb_build_object('p_supplier_id', sp.id),
        'prompt', jsonb_build_object(
          'title', public._c('admin_sup2.c_bulk_title'),
          'hint',  public._c('admin_sup2.c_bulk_hint'),
          'ok',    public._c('admin_sup2.c_bulk_ok'),
          'cancel',public._c('admin_sup2.c_cancel'),
          'multiline', true,
          'arg',   'p_text')))),
    jsonb_build_object('kind','chips','key','filter','arg','p_filter','chips', jsonb_build_array(
      jsonb_build_object('key','all',     'label',public._c('admin_sup2.c_all'),     'count',v_total,           'active',v_f='all'),
      jsonb_build_object('key','unmapped','label',public._c('admin_sup2.c_unmapped'),'count',v_total - v_mapped,'active',v_f='unmapped'),
      jsonb_build_object('key','mapped',  'label',public._c('admin_sup2.c_mapped'),  'count',v_mapped,          'active',v_f='mapped'))),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.c_title'),
      'empty', public._c('admin_sup2.c_empty'), 'items', v_items)));
end $$;

do $c753g4$
declare f record;
begin
  for f in select p.oid::regprocedure::text as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public'
              and p.proname in ('admin_supplier_tab_companies','admin_supplier_company_map',
                                'admin_supplier_company_unmap','admin_supplier_company_search',
                                'admin_supplier_company_delete','admin_supplier_company_automatch',
                                '_sup753_mapped','_sup753_zone_enqueue')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $c753g4$;

insert into public.partner_rpc_allow (proname, source, note) values
  ('admin_supplier_company_search','change_753','company mapping search')
on conflict (proname) do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- #753 REVISION 4 — PARITY (Om, 3 Sep 12:55 IST).
--
-- "Nothing the OLD Suppliers card could do may be lost in the new layout."
-- The old card carried, besides what is already rebuilt: a status dropdown, a
-- matched X/Y progress chip, the shop open/closed control that the old
-- "Availability" button opened, a bulk company link, and an Edit dialog whose
-- fourteen fields were a Dart constant. All of it lands here, and the Edit
-- form becomes DATA — its field list, labels, types and options are rows, so
-- adding "district" tomorrow is an INSERT, not a deploy.
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.ui_copy (key, value) values
  ('admin_sup2.st_label',    to_jsonb('Status'::text)),
  ('admin_sup2.st_saved',    to_jsonb('Status updated'::text)),
  ('admin_sup2.match_label', to_jsonb('Matched {a}/{b}'::text)),
  ('admin_sup2.e_title',     to_jsonb('Edit supplier'::text)),
  ('admin_sup2.e_save',      to_jsonb('Save changes'::text)),
  ('admin_sup2.e_cancel',    to_jsonb('Cancel'::text)),
  ('admin_sup2.e_saved',     to_jsonb('Supplier updated'::text)),
  ('admin_sup2.e_required',  to_jsonb('{label} is required.'::text)),
  ('admin_sup2.e_bad_upi',   to_jsonb('That is not a valid UPI address.'::text)),
  ('admin_sup2.e_open',      to_jsonb('Edit details'::text)),
  ('admin_sup2.c_bulk',      to_jsonb('Bulk link'::text)),
  ('admin_sup2.c_bulk_title',to_jsonb('Paste company names'::text)),
  ('admin_sup2.c_bulk_hint', to_jsonb('One per line, or comma separated'::text)),
  ('admin_sup2.c_bulk_ok',   to_jsonb('Link them'::text)),
  ('admin_sup2.c_bulk_done', to_jsonb('{n} linked'::text)),
  ('admin_sup2.a_set_none',  to_jsonb('Clear'::text)),
  ('admin_sup2.a_none',      to_jsonb('No answer yet'::text)),
  ('admin_sup2.a_shop',      to_jsonb('Shop'::text))
on conflict (key) do nothing;

-- ── The Edit form, as data ────────────────────────────────────────────────
create table if not exists public.admin_supplier_edit_field (
  col        text primary key,
  label      text not null,
  kind       text not null default 'text',    -- text | zone | status
  sort_order integer not null default 100,
  required   boolean not null default false,
  is_active  boolean not null default true,
  validate   text                             -- 'upi' | null
);

insert into public.admin_supplier_edit_field (col, label, kind, sort_order, required, validate) values
  ('supplier_name',   'Supplier name',        'text',   10, true,  null),
  ('supplier_code',   'Supplier code',        'text',   20, false, null),
  ('stockist_type',   'Stockist type',        'text',   30, false, null),
  ('zone_id',         'Zone',                 'zone',   40, false, null),
  ('status',          'Status',               'status', 50, false, null),
  ('contact_person',  'Contact person',       'text',   60, false, null),
  ('contact_name',    'Contact name',         'text',   70, false, null),
  ('phone',           'Phone',                'text',   80, false, null),
  ('whatsapp_no',     'WhatsApp no.',         'text',   90, false, null),
  ('email',           'Email',                'text',  100, false, null),
  ('street_address',  'Address',              'text',  110, false, null),
  ('city',            'City',                 'text',  120, false, null),
  ('district',        'District',             'text',  130, false, null),
  ('state',           'State',                'text',  140, false, null),
  ('pincode',         'PIN code',             'text',  150, false, null),
  ('drug_license',    'Drug licence',         'text',  160, false, null),
  ('dl_expiry',       'Drug licence expiry',  'date',  170, false, null),
  ('gstin',           'GSTIN',                'text',  180, false, null),
  ('gstin_expiry',    'GSTIN expiry',         'date',  190, false, null),
  ('payment_term',    'Payment term',         'text',  200, false, null),
  ('payment_address', 'Payment address (UPI)','text',  210, false, 'upi'),
  ('notes',           'Notes',                'text',  220, false, null)
on conflict (col) do update
  set label = excluded.label, kind = excluded.kind,
      sort_order = excluded.sort_order, required = excluded.required,
      validate = excluded.validate, is_active = true;

create or replace function public.admin_supplier_edit_form(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype; v_row jsonb; v_fields jsonb;
  v_cfg jsonb := coalesce((select value from app_settings where key='supplier_status_values'),'{}'::jsonb);
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;
  v_row := to_jsonb(sp);

  select coalesce(jsonb_agg(jsonb_build_object(
           'col', f.col, 'label', f.label, 'kind', f.kind,
           'required', f.required,
           'value', coalesce(v_row->>f.col,''),
           'options', case f.kind
             when 'zone' then coalesce((select jsonb_agg(jsonb_build_object(
                                          'value', z.id::text, 'label', z.name) order by z.id)
                                         from zones z), '[]'::jsonb)
             when 'status' then coalesce((select jsonb_agg(jsonb_build_object(
                                            'value', v, 'label', v))
                                           from (select distinct x from jsonb_each_text(v_cfg) e(k,x)) s(v)),
                                         '[]'::jsonb)
             else '[]'::jsonb end)
         order by f.sort_order), '[]'::jsonb)
    into v_fields
    from admin_supplier_edit_field f where f.is_active;

  return jsonb_build_object('ok', true,
    'supplier_id', sp.id,
    'title', public._c('admin_sup2.e_title'),
    'save_label', public._c('admin_sup2.e_save'),
    'cancel_label', public._c('admin_sup2.e_cancel'),
    'required_format', public._c('admin_sup2.e_required'),
    'fields', v_fields);
end $$;

create or replace function public.admin_supplier_edit_save(
  p_supplier_id uuid, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  sp supplier_profiles%rowtype;
  f record; v_val text; v_sets text[] := '{}';
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then raise exception 'not_authorized_zone'; end if;

  for f in select * from admin_supplier_edit_field where is_active order by sort_order loop
    if not (coalesce(p_patch,'{}'::jsonb) ? f.col) then continue; end if;
    v_val := nullif(btrim(coalesce(p_patch->>f.col,'')),'');

    if f.required and v_val is null then
      return jsonb_build_object('ok', false, 'error','required',
        'message', replace(public._c('admin_sup2.e_required'),'{label}', f.label));
    end if;
    if f.validate = 'upi' and v_val is not null
       and v_val !~ '^[0-9A-Za-z._\-]{2,}@[A-Za-z]{2,}$' then
      return jsonb_build_object('ok', false, 'error','bad_upi',
        'message', public._c('admin_sup2.e_bad_upi'));
    end if;

    if f.kind = 'zone' then
      v_sets := v_sets || format('%I = %L::smallint', f.col, v_val);
    elsif f.kind = 'date' then
      v_sets := v_sets || format('%I = %L::date', f.col, v_val);
    else
      v_sets := v_sets || format('%I = %L', f.col, v_val);
    end if;
  end loop;

  if array_length(v_sets,1) is null then
    return jsonb_build_object('ok', true, 'changed', 0);
  end if;

  execute format('update supplier_profiles set %s where id = %L',
                 array_to_string(v_sets,', '), p_supplier_id);

  return jsonb_build_object('ok', true, 'changed', array_length(v_sets,1),
    'message', public._c('admin_sup2.e_saved'));
end $$;

-- ── Bulk link: the split happens in SQL, not in Dart ──────────────────────
create or replace function public.admin_supplier_company_bulk_add(
  p_supplier_id uuid, p_text text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate(); sp supplier_profiles%rowtype;
  v_rows jsonb; v_res jsonb;
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then raise exception 'not_authorized_zone'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'supplier_id', sp.id,
           'supplier_name', coalesce(sp.supplier_name,''),
           'supplier_company', n)), '[]'::jsonb)
    into v_rows
    from (select distinct btrim(t) n
            from regexp_split_to_table(coalesce(p_text,''), '[\n,;]+') t
           where btrim(t) <> '') s;

  v_res := public.admin_supplier_company_bulk_link(v_rows);
  return jsonb_build_object('ok', true, 'linked', coalesce(v_res->>'linked','0')::int,
    'message', replace(public._c('admin_sup2.c_bulk_done'),'{n}',
                       coalesce(v_res->>'linked','0')));
end $$;

-- ── Header parity: the status dropdown, the matched X/Y, the Edit entry ────
create or replace function public.admin_supplier_page(p_supplier_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_zone smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb; v_rank int; v_active text;
  v_phone text; v_wa text; v_cfg jsonb; v_total int; v_matched int;
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_cfg := coalesce((select value from app_settings where key='supplier_status_values'),'{}'::jsonb);
  v_active := lower(coalesce(v_cfg->>'active','active'));
  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);

  select r into v_rank from (
    select x.id, rank() over (order by coalesce(x."SPN",0) desc, lower(x.supplier_name)) r
      from supplier_profiles x
     where coalesce(x.is_deleted,false) = false
       and (v_zone is null or x.zone_id = v_zone)) q(id, r)
   where q.id = sp.id;

  select count(*),
         count(*) filter (where coalesce(array_length(public._sup753_mapped(sc.id),1),0) > 0)
    into v_total, v_matched
    from supplier_company sc where sc.supplier_id = sp.id;

  v_phone := coalesce(nullif(btrim(coalesce(sp.phone,'')),''), nullif(btrim(coalesce(sp.contact_no,'')),''));
  v_wa    := public._sup753_wa(coalesce(nullif(sp.whatsapp_no,''), v_phone));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', t.tab_key, 'label', t.label,
           'icon', coalesce(t.icon_key,''),
           'rpc', coalesce(nullif(t.rpc,''), 'admin_supplier_tab_'||t.tab_key))
         order by t.sort_order), '[]'::jsonb)
    into v_tabs
    from admin_supplier_tab t
   where t.is_active
     and (t.feature_key is null
          or public.my_partner_id() is null
          or public.partner_can(t.feature_key,'read'));

  return jsonb_build_object(
    'ok', true,
    'supplier_id', sp.id,
    'title', coalesce(nullif(btrim(sp.supplier_name),''), sp.contact_name, '—'),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(sp.supplier_code,'')),''),
        nullif(btrim(coalesce(sp.city,'')),''),
        nullif(btrim(coalesce(sp.state,'')),'')], null), '  ·  '),
    'phone', coalesce(v_phone,''),
    'contacts', (case when coalesce(v_phone,'') = '' then '[]'::jsonb
                 else jsonb_build_array(
                   jsonb_build_object('key','call','label',public._c('admin_sup2.call_label'),
                                      'url','tel:'||regexp_replace(v_phone,'[^0-9+]','','g'))) end)
                || (case when v_wa is null then '[]'::jsonb
                    else jsonb_build_array(
                      jsonb_build_object('key','whatsapp','label',public._c('admin_sup2.wa_label'),
                                         'url', v_wa)) end),
    'back_label', public._c('admin_sup2.back'),
    'chips', jsonb_build_array(v_kyc->'chip'),
    -- The status dropdown the old card carried, same RPC, options from the
    -- same app_settings row the rest of the app reads.
    'status', jsonb_build_object(
      'label', public._c('admin_sup2.st_label'),
      'value', coalesce(sp.status,''),
      'rpc', 'admin_set_supplier_status_value',
      'args', jsonb_build_object('p_id', sp.id),
      'arg', 'p_status',
      'saved_label', public._c('admin_sup2.st_saved'),
      'options', coalesce((select jsonb_agg(jsonb_build_object('value', v, 'label', v))
                             from (select distinct x v from jsonb_each_text(v_cfg) e(k,x)) s),
                          '[]'::jsonb)),
    'match_label', replace(replace(public._c('admin_sup2.match_label'),
                     '{a}', v_matched::text), '{b}', v_total::text),
    'spn_label', public._c('admin_sup2.spn_prefix')||' '||to_char(coalesce(sp."SPN",0),'FM999,999,999'),
    'rank_label', public._c('admin_sup2.rank_prefix')||coalesce(v_rank,0)::text,
    'spn_block', public._sup753_spn_block(sp.id),
    'edit', jsonb_build_object(
      'label', public._c('admin_sup2.e_open'),
      'form_rpc','admin_supplier_edit_form',
      'save_rpc','admin_supplier_edit_save',
      'args', jsonb_build_object('p_supplier_id', sp.id),
      'arg', 'p_patch'),
    'zone_label', coalesce((select z.name from zones z where z.id = sp.zone_id),
                           public._c('admin_sup2.no_zone')),
    'menu', public._sup753_menu(sp.id, coalesce(sp.supplier_name,''),
                                coalesce(nullif(sp.whatsapp_no,''), v_phone),
                                (lower(coalesce(sp.status,'')) = v_active)),
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key','profile'),
    'empty_label', public._c('admin_sup2.tab_empty'));
end $$;

-- ── Availability parity: the fourth state (clear) and the shop open/closed
--    control that the old "Availability" button actually opened. ───────────
create or replace function public.admin_supplier_availability_set(
  p_supplier_id uuid, p_product_id bigint, p_state text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_role text := public._sup753_gate(); sp supplier_profiles%rowtype;
        v_state text := btrim(coalesce(p_state,''));
begin
  if v_role = 'none' then raise exception 'forbidden'; end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then raise exception 'not_authorized_zone'; end if;

  -- An empty state CLEARS the memory: "no answer yet" is a real state, and
  -- writing a blank string in its place would look like an answer.
  if v_state = '' then
    delete from supplier_item_memory
     where lower(btrim(supplier_name)) = lower(btrim(sp.supplier_name))
       and product_id = p_product_id;
  else
    insert into supplier_item_memory (supplier_name, product_id, last_answer,
                                      last_answered_at, times_answered)
    values (sp.supplier_name, p_product_id, v_state, now(), 1)
    on conflict (supplier_name, product_id) do update
      set last_answer = excluded.last_answer, last_answered_at = now();
  end if;

  insert into supplier_audit_log (supplier_id, actor_identity, feature_key, action, detail)
  values (sp.id, coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown'),
          'admin.supplier.availability', 'set_state',
          jsonb_build_object('product_id', p_product_id, 'state', v_state));

  return jsonb_build_object('ok', true, 'product_id', p_product_id, 'state', v_state);
end $$;

create or replace function public.admin_supplier_tab_availability(
  p_supplier_id uuid, p_zone_id smallint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_role text := public._sup753_gate();
  v_scope smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype;
  v_zone smallint; v_zones jsonb; v_items jsonb; v_copy jsonb; v_shop jsonb;
  v_avail text := 'Available'; v_oos text := 'Out of Stock';
  v_dont text := 'We don''t stock this product';
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_zone := coalesce(p_zone_id, v_scope, sp.zone_id);
  v_copy := jsonb_build_object('one', public._c('admin_sup2.a_times_one'),
                               'many', public._c('admin_sup2.a_times_many'));

  -- The shop open/closed panel — this is what the old card's "Availability"
  -- button opened, and it is the same _supplier_closure_panel the supplier's
  -- own portal renders.
  v_shop := public._supplier_closure_panel(sp.supplier_name, 'admin');

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', z.id::text,
           'value', z.id,
           'label', case z.id when 1 then '①' when 2 then '②' when 3 then '③'
                              when 4 then '④' when 5 then '⑤'
                              else '('||z.id::text||')' end || ' ' || z.name,
           'count', (select count(*) from supplier_item_memory m
                      join catalogue_zone_avail cz
                        on cz.product_id = m.product_id and cz.zone_id = z.id
                     where lower(btrim(m.supplier_name)) = lower(btrim(sp.supplier_name))),
           'active', (z.id = v_zone))
         order by z.id), '[]'::jsonb)
    into v_zones
    from zones z
   where (v_scope is null or z.id = v_scope);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.product_id,
           'title', coalesce(nullif(btrim(coalesce(md.product_name,'')),''), '#'||m.product_id::text),
           'subtitle', public.count_label(v_copy,'one','many',coalesce(m.times_answered,0)),
           'meta', case when m.last_answered_at is null then ''
                        else public._c('admin_sup2.a_last')||': '||public.ist_fmt(m.last_answered_at,'day_mon_year') end,
           'chip', jsonb_build_object('show', true,
             'label', coalesce(nullif(m.last_answer,''), public._c('admin_sup2.a_none')),
             'bg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#D1FAE5'
                            when 'out of stock' then '#FEE2E2' else '#EFF6FF' end,
             'fg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#065F46'
                            when 'out of stock' then '#991B1B' else '#1E40AF' end,
             'border', case lower(coalesce(m.last_answer,'')) when 'available' then '#A7F3D0'
                            when 'out of stock' then '#FECACA' else '#BFDBFE' end),
           'actions', jsonb_build_array(
             jsonb_build_object('key','available','label',public._c('admin_sup2.a_set_available'),
               'tone','success','selected',(m.last_answer = v_avail),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_avail)),
             jsonb_build_object('key','oos','label',public._c('admin_sup2.a_set_oos'),
               'tone','danger','selected',(m.last_answer = v_oos),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_oos)),
             jsonb_build_object('key','dont','label',public._c('admin_sup2.a_set_dont'),
               'tone','info','selected',(m.last_answer = v_dont),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_dont)),
             jsonb_build_object('key','none','label',public._c('admin_sup2.a_set_none'),
               'tone','muted','selected',false,
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', ''))))
         order by m.last_answered_at desc nulls last), '[]'::jsonb)
    into v_items
    from supplier_item_memory m
    left join "MEDICINE" md on md.id = m.product_id
   where lower(btrim(m.supplier_name)) = lower(btrim(sp.supplier_name))
     and (v_zone is null
          or exists (select 1 from catalogue_zone_avail cz
                      where cz.product_id = m.product_id and cz.zone_id = v_zone));

  return jsonb_build_object('ok', true, 'zone_id', v_zone, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','shop','title',public._c('admin_sup2.a_shop'),'shop', v_shop,
      'supplier_name', coalesce(sp.supplier_name,'')),
    jsonb_build_object('kind','chips','key','zone','arg','p_zone_id','arg_type','int',
                       'title',public._c('admin_sup2.a_zone'),'chips',v_zones),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.a_title'),
      'empty', public._c('admin_sup2.a_empty'), 'items', v_items)));
end $$;

do $c753g5$
declare f record;
begin
  for f in select p.oid::regprocedure::text as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname='public'
              and p.proname in ('admin_supplier_page','admin_supplier_tab_availability',
                                'admin_supplier_availability_set','admin_supplier_edit_form',
                                'admin_supplier_edit_save','admin_supplier_company_bulk_add')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('revoke all on function %s from anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $c753g5$;

insert into public.partner_rpc_allow (proname, source, note) values
  ('admin_supplier_edit_form','change_753','supplier edit form')
on conflict (proname) do nothing;
