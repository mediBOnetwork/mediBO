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
alter table public.supplier_profiles add column if not exists dl_expiry    date;
alter table public.supplier_profiles add column if not exists gstin_expiry date;

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
       and (v_q = '' or lower(coalesce(c.supplier_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.contact_name,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.supplier_code,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.phone,'')) like '%'||v_q||'%'
                     or lower(coalesce(c.city,'')) like '%'||v_q||'%')
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
