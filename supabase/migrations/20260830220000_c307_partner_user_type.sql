-- CHANGE #307 — Partner user type: zone-scoped fulfilment logins with a
-- per-feature permission matrix.
--
-- mediBO does not fulfil orders itself. A zone-wise fulfilment partner does the
-- physical work, and this migration gives that partner a LOGIN — inside the
-- existing admin app, not a second app.
--
-- Shape:
--   partner_users        one login <-> one region_partners row (many staff per partner)
--   feature_registry     every partner-visible screen registered once; DEFAULT DENY
--   partner_permissions  (partner_id, feature_key) -> none | read | write
--   partner_audit_log    every partner action stamped with partner_id AND user_id
--
-- The hard rule is the ZONE. It comes from the partner's region_partners row and
-- nowhere else: admin_active_zone() answers it first, and scope_zone() /
-- zone_effective() CLAMP to it — a p_zone argument from a partner is ignored, so
-- a Raipur partner calling the API directly with zone 2 still gets Raipur.
-- zone_picker() returns show:false for a partner, so no selector can render.
--
-- get_my_role() answers 'admin' for a partner ON PURPOSE: the ~500 existing
-- fulfilment RPCs gate on ('admin','super_admin') and rewriting them all would
-- be a far larger blast radius than the boundary is worth. What keeps a partner
-- out of mediBO's own work is additive and explicit:
--   • the zone clamp above,
--   • the default-deny feature matrix (what they can even reach),
--   • role_for_medibo_only() — swapped into the marketing / catalogue / pricing
--     / customer-payment / settlement screens, where a partner reads as
--     'partner' and is therefore a member of no admin gate anywhere,
--   • am_i_super() = false, which keeps every super-admin surface shut.
-- my_session() reports role='partner' and surface='partner' — the USER TYPE the
-- app renders — via a thin overlay over the untouched my_session_core().
--
-- Proof: select public.c307_partner_zone_proof();  -- 32 checks, all green.
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ── Tables ──────────────────────────────────────────────────────────────────
create table if not exists public.partner_users (
  id            bigserial primary key,
  partner_id    bigint not null references public.region_partners(id) on delete cascade,
  identity      text not null,                 -- identity_norm(phone|email)
  display_name  text,
  auth_user_id  uuid,
  is_active     boolean not null default true,
  created_by    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists partner_users_identity_uidx on public.partner_users(identity);
create index if not exists partner_users_partner_idx on public.partner_users(partner_id);
create index if not exists partner_users_auth_idx on public.partner_users(auth_user_id);

create table if not exists public.feature_registry (
  feature_key      text primary key,
  label            text not null,
  group_label      text not null default '',
  icon_key         text not null default 'tile',
  route_key        text not null default '',
  sort_order       int  not null default 100,
  owner            text not null default 'medibo' check (owner in ('medibo','partner')),
  partner_eligible boolean not null default false,
  default_access   text not null default 'none' check (default_access in ('none','read','write')),
  is_active        boolean not null default true,
  created_at       timestamptz not null default now()
);

create table if not exists public.partner_permissions (
  partner_id  bigint not null references public.region_partners(id) on delete cascade,
  feature_key text   not null references public.feature_registry(feature_key) on delete cascade,
  access      text   not null default 'none' check (access in ('none','read','write')),
  updated_at  timestamptz not null default now(),
  updated_by  text,
  primary key (partner_id, feature_key)
);

create table if not exists public.partner_audit_log (
  id              bigserial primary key,
  partner_id      bigint,
  partner_user_id bigint,
  user_id         uuid,
  zone_id         smallint,
  feature_key     text,
  action          text not null,
  detail          jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
create index if not exists partner_audit_partner_idx on public.partner_audit_log(partner_id, created_at desc);
create index if not exists partner_audit_zone_idx    on public.partner_audit_log(zone_id, created_at desc);

alter table public.partner_users       enable row level security;
alter table public.feature_registry    enable row level security;
alter table public.partner_permissions enable row level security;
alter table public.partner_audit_log   enable row level security;

-- Deny by default: the app never touches these tables directly, every read and
-- write goes through a SECURITY DEFINER RPC below. The one exception is the
-- feature CATALOGUE (labels only, no per-partner data).
drop policy if exists feature_registry_read on public.feature_registry;
create policy feature_registry_read on public.feature_registry
  for select to authenticated using (true);

grant select on public.feature_registry to authenticated;
revoke all on public.partner_users, public.partner_permissions, public.partner_audit_log from anon, authenticated;

-- ── Seeds ───────────────────────────────────────────────────────────────────
-- Partner work: inquiry, supplier orders, supplier payment, collect, count,
-- bag mapping, pack, assign to delivery. mediBO keeps everything else, and an
-- owner='medibo' row can never be granted (admin_partner_access_set refuses).
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner, partner_eligible, default_access)
values
  ('partner.inquiry',          'Inquiry',            'Sourcing',   'forum',     'inquiry',          10, 'partner', true, 'none'),
  ('partner.supplier_orders',  'Supplier orders',    'Sourcing',   'receipt',   'supplier_orders',  20, 'partner', true, 'none'),
  ('partner.supplier_payment', 'Supplier payment',   'Sourcing',   'rupee',     'supplier_payment', 30, 'partner', true, 'none'),
  ('partner.collect',          'Collect',            'Fulfilment', 'store',     'collect',          40, 'partner', true, 'none'),
  ('partner.count',            'Count',              'Fulfilment', 'inventory', 'count',            50, 'partner', true, 'none'),
  ('partner.bag_mapping',      'Bag mapping',        'Fulfilment', 'bag',       'bag_mapping',      60, 'partner', true, 'none'),
  ('partner.pack',             'Pack',               'Fulfilment', 'package',   'pack',             70, 'partner', true, 'none'),
  ('partner.assign_delivery',  'Assign to delivery', 'Fulfilment', 'truck',     'assign_delivery',  80, 'partner', true, 'none'),
  ('medibo.marketing',            'Marketing',                   'mediBO only', 'campaign', '', 210, 'medibo', false, 'none'),
  ('medibo.customer_acquisition', 'Customer acquisition',        'mediBO only', 'people',   '', 220, 'medibo', false, 'none'),
  ('medibo.catalogue',            'Catalogue',                   'mediBO only', 'book',     '', 230, 'medibo', false, 'none'),
  ('medibo.pricing',              'Pricing and margin',          'mediBO only', 'rupee',    '', 240, 'medibo', false, 'none'),
  ('medibo.customer_payment',     'Customer payment collection', 'mediBO only', 'wallet',   '', 250, 'medibo', false, 'none'),
  ('medibo.partner_settlement',   'Partner settlement',          'mediBO only', 'handshake','', 260, 'medibo', false, 'none')
on conflict (feature_key) do update
  set label = excluded.label, group_label = excluded.group_label,
      icon_key = excluded.icon_key, route_key = excluded.route_key,
      sort_order = excluded.sort_order, owner = excluded.owner,
      partner_eligible = excluded.partner_eligible;

-- Every word both new screens print. Changing copy is an UPDATE, not a deploy.
insert into public.app_settings(key, value) values
 ('partner_home_copy', jsonb_build_object(
    'title','Partner', 'subtitle','Your zone, your work.', 'zone_prefix','Zone',
    'empty_title','No features enabled yet',
    'empty_message','mediBO has not switched on any screens for this partner. Contact mediBO to get access.',
    'access_read_label','View only', 'access_write_label','Full access',
    'denied_message','You do not have access to this screen.',
    'signed_out_message','Please log in.',
    'not_partner_message','This account is not a partner login.')),
 ('partner_admin_copy', jsonb_build_object(
    'users_title','Partner logins',
    'users_subtitle','They sign in with the same WhatsApp OTP or Google login as everyone else.',
    'add_label','Add login', 'add_hint','Phone number or email',
    'name_hint','Name (optional)', 'remove_label','Remove',
    'empty_users','No logins yet.',
    'perm_title','What this partner can open',
    'perm_subtitle','Takes effect on their next screen load. New screens default to No access.',
    'audit_title','Partner activity',
    'empty_audit','No partner activity recorded yet.',
    'zone_locked_label','Zone is fixed by the partner record and cannot be changed here.',
    'saved_message','Saved.',
    'added_message','Login added. Ask them to sign in with that number.',
    'removed_message','Login removed.'))
on conflict (key) do update set value = excluded.value;

insert into public.ui_copy(key, value) values
 ('admin_upi_screen.tooltip_partner_access', to_jsonb('Logins and access'::text)),
 ('admin_upi_screen.partner_access_label',   to_jsonb('Logins & access'::text))
on conflict (key) do update set value = excluded.value;

insert into public.login_role_config(role, home_route, home_label, sort)
values ('partner', '/partner', 'Partner', 9)
on conflict (role) do update set home_route = excluded.home_route,
                                 home_label = excluded.home_label;

-- my_session() is wrapped, not rewritten: the 200-line body is renamed ONCE to
-- my_session_core() and an overlay adds the partner fields on top.
do $mig$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='public' and p.proname='my_session_core' and p.pronargs=0)
  then
    execute 'alter function public.my_session() rename to my_session_core';
  end if;
end $mig$;

-- ── Functions (exact live definitions) ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public._is_medibo_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.role_for_medibo_only() IN ('admin','super_admin');
$function$
;

CREATE OR REPLACE FUNCTION public._session_partner_overlay(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pid bigint; rp record; v_cfg record; v_zone text;
begin
  v_pid := public.my_partner_id();
  if v_pid is null then
    return coalesce(p,'{}'::jsonb) || jsonb_build_object(
      'is_partner', false, 'partner_id','', 'partner_name','',
      'partner_zone_id', null, 'partner_zone_label','');
  end if;
  select * into rp from region_partners where id = v_pid;
  select * into v_cfg from login_role_config where role = 'partner';
  select z.name into v_zone from zones z where z.id = rp.zone_id;

  -- role here is the USER TYPE the app renders. get_my_role() — the
  -- AUTHORISATION answer — deliberately stays 'admin' so the existing
  -- zone-scoped fulfilment RPCs keep working for a partner.
  return coalesce(p,'{}'::jsonb) || jsonb_build_object(
    'is_partner',          true,
    'role',                'partner',
    'is_admin',            false,
    'is_super_admin',      false,
    'is_supplier',         false,
    'is_customer',         false,
    'surface',             'partner',
    'owner_type',          'partner',
    'owner_id',            v_pid::text,
    'partner_id',          v_pid::text,
    'partner_name',        coalesce(rp.partner_name,''),
    'partner_zone_id',     rp.zone_id,
    'partner_zone_label',  coalesce(v_zone,''),
    'header_title',        coalesce(rp.partner_name,''),
    'display_name',        coalesce(rp.partner_name,''),
    'customer_name',       coalesce(rp.partner_name,''),
    'needs_profile',       false,
    'can_place_order',     false,
    'home_route',          coalesce(v_cfg.home_route,'/partner'),
    'home_label',          coalesce(v_cfg.home_label,'Partner'));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_active_zone()
 RETURNS smallint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_role text; v_email text; v_zone smallint;
BEGIN
  -- CHANGE #307 — a partner's zone wins over everything, first, always.
  v_zone := public.partner_zone_id();
  IF v_zone IS NOT NULL THEN RETURN v_zone; END IF;

  v_role := coalesce(get_my_role(),'');
  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u WHERE u.id = auth.uid();
  IF v_role = 'super_admin' THEN
    SELECT active_zone_id INTO v_zone FROM admin_zone_scope WHERE admin_email = v_email;
    RETURN v_zone;                          -- NULL means "all zones"
  ELSIF v_role = 'admin' THEN
    SELECT a.zone_id INTO v_zone FROM admins a WHERE lower(btrim(a.email)) = v_email;
    RETURN coalesce(v_zone, public.zone_default_id());
  END IF;
  RETURN NULL;
END $function$
;

CREATE OR REPLACE FUNCTION public.admin_bill_pipeline(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o orders%rowtype; j public.bill_jobs%rowtype; v_ready jsonb;
  v_unver jsonb; v_uncov jsonb; v_paid numeric; v_bill jsonb; v_steps jsonb;
  v_wait text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select * into o from orders where id = p_order_id;
  if not found then return jsonb_build_object('ok', false, 'error','order_not_found'); end if;

  v_ready := public._bill_ready(p_order_id);
  select * into j from public.bill_jobs where order_id = p_order_id order by created_at desc limit 1;
  select coalesce(sum(amount),0) into v_paid from payment_claims
   where order_id = p_order_id and status not in ('rejected','duplicate','need_details');
  v_bill := public.customer_bill(p_order_id);
  v_wait := array_to_string(array(select jsonb_array_elements_text(v_ready->'waiting_suppliers')), ', ');

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id, 'raw_name', b.raw_name,
           'supplier_label', coalesce(b.supplier_name,''),
           'reason_label', coalesce(b.needs_fix, b.verify_blocked, public._bpl('reason.incomplete')),
           'qty_label', trim_scale(coalesce(b.qty,0))::text) order by b.created_at), '[]'::jsonb)
    into v_unver
  from bill_lines b
  where not b.verified
    and b.supplier_name in (select distinct oi.assigned_supplier from order_items oi
                             where oi.order_id = p_order_id and oi.assigned_supplier is not null);

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_label', coalesce(oi.product_name,''),
           'supplier_label', coalesce(oi.assigned_supplier, public._bpl('chip.no_supplier')),
           'qty_label', trim_scale(coalesce(oi.quantity,0))::text) order by oi.id), '[]'::jsonb)
    into v_uncov
  from order_items oi
  where oi.order_id = p_order_id
    and oi.fulfillment_state not in ('shipped','cancelled')
    and coalesce(oi.unfulfillable,false) = false
    and not exists (select 1 from bill_line_allocations a
                     join bill_lines b on b.id = a.bill_line_id
                    where a.order_item_id = oi.id and b.verified and b.needs_fix is null);

  v_steps := jsonb_build_array(
    jsonb_build_object('key','lines', 'label', public._bpl('step.lines.label'),
      'status_label', case when jsonb_array_length(v_unver) = 0 then public._bpl('step.lines.done')
                           else public._bpl('step.lines.pending') || ' · ' || jsonb_array_length(v_unver)::text end,
      'tone', case when jsonb_array_length(v_unver) = 0 then 'success' else 'warning' end),
    jsonb_build_object('key','items', 'label', public._bpl('step.items.label'),
      'status_label', case when (v_ready->>'uncovered')::int = 0 then public._bpl('step.items.done')
                           else public._bpl('step.items.pending') || ' · ' || (v_ready->>'uncovered') end,
      'tone', case when (v_ready->>'uncovered')::int = 0 then 'success' else 'warning' end,
      'detail', case when v_wait <> '' and (v_ready->>'uncovered')::int > 0
                     then public._bpl('chip.waiting') || ' ' || v_wait end),
    jsonb_build_object('key','bill', 'label', public._bpl('step.bill.label'),
      'status_label', case
        when o.cust_bill_path is not null then public._bpl('step.bill.done')
        when j.status = 'dead' then public._bpl('step.bill.failed')
        when j.status = 'running' then public._bpl('step.bill.running')
        when j.status = 'queued' then public._bpl('step.bill.queued')
        else public._bpl('step.bill.pending') end,
      'tone', case when o.cust_bill_path is not null then 'success'
                   when j.status = 'dead' then 'danger'
                   when j.status is not null then 'info' else 'neutral' end,
      'detail', j.last_error),
    jsonb_build_object('key','wa', 'label', public._bpl('step.wa.label'),
      'status_label', case when j.wa_bill_sent_at is not null then public._bpl('step.wa.done')
                           else public._bpl('step.wa.pending') end,
      'tone', case when j.wa_bill_sent_at is not null then 'success' else 'neutral' end,
      'detail', case when j.wa_bill_sent_at is not null
                     then to_char(j.wa_bill_sent_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM') end),
    jsonb_build_object('key','pay', 'label', public._bpl('step.pay.label'),
      'status_label', case
        when coalesce(v_paid,0) <= 0 then public._bpl('step.pay.pending')
        when (v_bill->>'ready')::boolean
             and coalesce(v_paid,0) >= coalesce((v_bill->'totals'->>'net_payable')::numeric,0)
          then public._bpl('step.pay.done')
        else public._bpl('step.pay.partial') end,
      'tone', case when coalesce(v_paid,0) <= 0 then 'neutral'
                   when (v_bill->>'ready')::boolean
                        and coalesce(v_paid,0) >= coalesce((v_bill->'totals'->>'net_payable')::numeric,0)
                     then 'success' else 'info' end,
      'detail', case when (v_bill->>'ready')::boolean then v_bill->'totals'->>'remaining_label' end));

  return jsonb_build_object(
    'ok', true,
    'order_id', p_order_id,
    'title', public._bpl('screen.title'),
    'order_code', coalesce(o.order_code,''),
    'buyer_label', coalesce(o.pharmacy_name,''),
    'steps', v_steps,
    'unverified', jsonb_build_object('label', public._bpl('detail.unverified.title'),
                                     'empty_label', public._bpl('detail.unverified.empty'),
                                     'rows', v_unver),
    'uncovered',  jsonb_build_object('label', public._bpl('detail.uncovered.title'),
                                     'empty_label', public._bpl('detail.uncovered.empty'),
                                     'rows', v_uncov),
    'job', case when j.id is null
                then jsonb_build_object('label', public._bpl('detail.job.title'),
                                        'status_label', public._bpl('detail.job.none'),
                                        'tone','neutral')
                else jsonb_build_object('label', public._bpl('detail.job.title'),
                                        'status_label', j.status,
                                        'tone', case j.status when 'done' then 'success'
                                                              when 'dead' then 'danger' else 'info' end,
                                        'attempts_label', public._bpl('detail.attempts') || ' ' ||
                                                          j.attempts::text || '/' || j.max_attempts::text,
                                        'error_label', j.last_error) end,
    'actions', case when o.cust_bill_path is null and (v_ready->>'ready')::boolean
                    then jsonb_build_array(jsonb_build_object('key','enqueue',
                           'label', public._bpl('action.enqueue'), 'tone','brand'))
                    when j.status = 'dead'
                    then jsonb_build_array(jsonb_build_object('key','retry',
                           'label', public._bpl('action.retry'), 'tone','brand'))
                    else '[]'::jsonb end,
    'blocked_label', case when not (v_ready->>'ready')::boolean then public._bpl('action.blocked') end);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_customer_orders(p_date date DEFAULT admin_active_date())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rows jsonb;
  v_copy jsonb := coalesce((SELECT value FROM app_settings WHERE key='customer_orders_screen_copy'),'{}'::jsonb);
  v_act  jsonb := coalesce((SELECT value FROM app_settings WHERE key='customer_order_actions_copy'),'{}'::jsonb);
  v_cols jsonb := coalesce((SELECT value FROM app_settings WHERE key='order_tab_columns'),'{}'::jsonb);
  v_sep  text  := coalesce(v_copy->>'summary_sep',' • ');
  v_zone smallint := public.admin_active_zone();
  v_n int; v_items int; v_amt numeric;
BEGIN
  IF public.role_for_medibo_only() NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;

  WITH base AS (
    SELECT o.*, (SELECT count(*) FROM order_items oi WHERE oi.order_id = o.id) AS items_count,
           (lower(coalesce(o.status,'')) = 'pending') AS can_confirm
    FROM orders o
    WHERE public._date_in_scope(o.created_at, p_date, false)
      AND (v_zone IS NULL OR o.zone_id = v_zone)
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'order_id',b.id,'order_code',coalesce(b.order_code,''),'customer_id',b.customer_id,
      'user_id',b.user_id,'phone',coalesce(b.phone,''),'zone_id',b.zone_id,
      'title', CASE WHEN coalesce(btrim(b.pharmacy_name),'') <> '' THEN b.pharmacy_name
                    ELSE coalesce(v_copy->>'unnamed','') END,
      'code_label',coalesce(b.order_code,''),'show_code',(coalesce(btrim(b.order_code),'') <> ''),
      'phone_label', CASE WHEN coalesce(btrim(b.phone),'') <> '' THEN b.phone
                          ELSE coalesce(v_copy->>'no_phone','') END,
      'has_phone',(coalesce(btrim(b.phone),'') <> ''),
      'status_chip', public.status_chip('customer_status', b.status),
      'fulfillment_chip', public.status_chip('fulfillment', b.fulfillment_status),
      'source_chip', public.status_chip('source', b.source),
      'payment_chip', public.order_payment_chip(b.id),
      'zone_label', coalesce((SELECT name FROM zones WHERE id = b.zone_id),''),
      'admin_chip', CASE WHEN coalesce(b.placed_by_admin,false)
            THEN jsonb_build_object('label',coalesce(v_copy->>'admin_placed',''),
                   'bg','#E6F1FB','fg','#0C447C','border','#B6D4F0','show',true)
            ELSE jsonb_build_object('label','','bg','#FFFFFF','fg','#FFFFFF','border','#FFFFFF','show',false) END,
      'amount',coalesce(b.total_amount,0),'amount_label',public.inr_money(coalesce(b.total_amount,0)),
      'items_count',b.items_count,
      'items_label',public.count_label(v_copy,'items_one','items_many',b.items_count::int),
      'created_at',b.created_at,
      'time_label',to_char(b.created_at AT TIME ZONE 'Asia/Kolkata','HH12:MI AM'),
      'date_label',to_char(b.created_at AT TIME ZONE 'Asia/Kolkata','DD/MM/YYYY'),
      'can_confirm',b.can_confirm,
      'actions', jsonb_build_object('show',b.can_confirm,
        'accept', jsonb_build_object('label',coalesce(v_act->>'accept_label',''),'status','accepted',
                    'show',b.can_confirm,'note',coalesce(v_act->>'accepted_note',''))
                  || public.tone_colors(coalesce(v_act->>'accept_tone','green')),
        'reject', jsonb_build_object('label',coalesce(v_act->>'reject_label',''),'status','rejected',
                    'show',b.can_confirm,'note',coalesce(v_act->>'rejected_note',''))
                  || public.tone_colors(coalesce(v_act->>'reject_tone','red')))
    ) ORDER BY b.created_at DESC),'[]'::jsonb),
    count(*), coalesce(sum(b.items_count),0), coalesce(sum(b.total_amount),0)
  INTO v_rows, v_n, v_items, v_amt FROM base b;

  RETURN jsonb_build_object('status','ok','date',p_date,
    'date_label',to_char(p_date,'DD/MM/YYYY'),
    'zone_id', v_zone,
    'zone_label', coalesce((SELECT name FROM zones WHERE id = v_zone),'All zones'),
    'orders',v_rows,'count',v_n,'has_orders',(v_n > 0),
    'columns',coalesce(v_cols->'customer_orders','[]'::jsonb),
    'summary', jsonb_build_object('orders',v_n,'items',v_items,'amount',v_amt,
      'amount_label',public.inr_money(v_amt),
      'label', public.count_label(v_copy,'orders_one','orders_many',v_n)||v_sep||
               public.count_label(v_copy,'items_one','items_many',v_items)||v_sep||
               public.inr_money(v_amt)),
    'empty', jsonb_build_object('show',(v_n=0),
      'title',coalesce(v_copy->>'empty_title',''),'note',coalesce(v_copy->>'empty_note','')));
END;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_dashboard_counts(p_date date DEFAULT NULL::date, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  v_zone smallint; v_date date; v_zname text;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('allowed', false,
      'medicines',0,'pending_bills',0,'flagged_bills',0,
      'pending_orders',0,'contact_inquiries',0,'pending_customers',0);
  end if;
  v_zone := public.scope_zone(p_zone);          -- NULL = all zones
  v_date := public.scope_date(p_date);          -- the ONE date source
  select name into v_zname from zones where id = v_zone;

  return jsonb_build_object('allowed', true,
    'zone_id', v_zone, 'zone_label', coalesce(v_zname,'All zones'), 'the_date', v_date,
    'medicines', (select count(*) from "MEDICINE"),
    'pending_bills', (select count(*) from pending_bills pb
                      where pb.status='pending'
                        and public.scope_zone_ok((select sp.zone_id from supplier_profiles sp
                                       where btrim(lower(sp.supplier_name)) = btrim(lower(pb.supplier_name))
                                       limit 1), v_zone)),
    'flagged_bills', (select count(*) from pending_bills pb
                      where pb.verdict in ('needs_approval','fake')
                        and public.scope_zone_ok((select sp.zone_id from supplier_profiles sp
                                       where btrim(lower(sp.supplier_name)) = btrim(lower(pb.supplier_name))
                                       limit 1), v_zone)),
    'pending_orders', (select count(*) from orders o
                        left join pharmacy_profiles pp on pp.id = o.customer_id
                       where o.status='pending'
                         and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)),
    'orders_today', (select count(*) from orders o
                      left join pharmacy_profiles pp on pp.id = o.customer_id
                     where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
                       and public.scope_zone_ok(coalesce(o.zone_id, pp.zone_id), v_zone)),
    'contact_inquiries', (select count(*) from contact_inquiries),
    'pending_customers', (select count(*) from pharmacy_profiles pp
                           where coalesce(pp.approved,false) = false
                             and public.scope_zone_ok(pp.zone_id, v_zone)),
    'deliveries_today', (select count(*) from deliveries d
                          join orders o on o.id = d.order_id
                         where (o.created_at at time zone 'Asia/Kolkata')::date = v_date
                           and public.scope_zone_ok(coalesce(d.zone_id, o.zone_id), v_zone)));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_order_closure_list(p_filter text DEFAULT 'blocked'::text, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb := '[]'::jsonb; r record; v_f text := coalesce(nullif(p_filter,''),'blocked');
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  if v_f = 'blocked' then
    for r in select o.id from orders o
              where o.closed_at is null
                and coalesce(o.status,'') not in ('cancelled','rejected')
              order by o.created_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._order_close_state(r.id));
    end loop;
  elsif v_f = 'closed' then
    for r in select o.id from orders o where o.closed_at is not null
              order by o.closed_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._order_close_state(r.id));
    end loop;
  elsif v_f = 'sup_open' then
    for r in select so.id from supplier_orders so
              where so.settled_at is null
                and coalesce(so.status,'') not in ('closed','shipped','cancelled')
              order by so.order_date desc nulls last, so.created_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._supplier_settle_state(r.id));
    end loop;
  else
    for r in select so.id from supplier_orders so where so.settled_at is not null
              order by so.settled_at desc limit p_limit
    loop
      v_rows := v_rows || jsonb_build_array(public._supplier_settle_state(r.id));
    end loop;
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',    public._ocl('screen.title'),
    'subtitle', public._ocl('screen.subtitle'),
    'auto_note',public._ocl('auto.note'),
    'filter',   v_f,
    'tabs', jsonb_build_array(
      jsonb_build_object('key','blocked',     'label', public._ocl('tab.blocked')),
      jsonb_build_object('key','closed',      'label', public._ocl('tab.closed')),
      jsonb_build_object('key','sup_open',    'label', public._ocl('tab.sup_open')),
      jsonb_build_object('key','sup_settled', 'label', public._ocl('tab.sup_settled'))),
    'empty_label', case v_f when 'blocked'  then public._ocl('empty.blocked')
                            when 'closed'   then public._ocl('empty.closed')
                            when 'sup_open' then public._ocl('empty.sup_open')
                            else public._ocl('empty.sup_settled') end,
    'retry_label', public._ocl('retry'),
    'backfill', public.order_closure_backfill_report(),
    'rows', v_rows,
    'count', jsonb_array_length(v_rows));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_partner_access_set(p_partner_id bigint, p_feature_key text, p_access text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  fr record;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if coalesce(p_access,'') not in ('none','read','write') then
    return jsonb_build_object('ok',false,'error','bad_access');
  end if;
  select * into fr from feature_registry where feature_key = p_feature_key;
  if fr.feature_key is null or not fr.partner_eligible or fr.owner <> 'partner' then
    return jsonb_build_object('ok',false,'error','feature_not_partner_eligible');
  end if;

  insert into partner_permissions(partner_id, feature_key, access, updated_at, updated_by)
  values (p_partner_id, p_feature_key, p_access, now(), public.my_login_email())
  on conflict (partner_id, feature_key)
    do update set access = excluded.access, updated_at = now(), updated_by = excluded.updated_by;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), p_feature_key, 'permission_set',
          jsonb_build_object('access', p_access, 'by', public.my_login_email()));

  return jsonb_build_object('ok',true,'access',p_access,
    'message', coalesce(v_copy->>'saved_message',''));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_partner_console(p_partner_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  rp record; v_feats jsonb; v_users jsonb; v_audit jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into rp from region_partners where id = p_partner_id;
  if rp.id is null then return jsonb_build_object('ok',false,'error','partner_not_found'); end if;

  select jsonb_agg(jsonb_build_object(
           'feature_key', fr.feature_key,
           'label', fr.label,
           'group_label', fr.group_label,
           'access', coalesce(pp.access,'none'),
           'options', jsonb_build_array(
             jsonb_build_object('value','none', 'label','No access',
                                'selected', coalesce(pp.access,'none')='none'),
             jsonb_build_object('value','read', 'label','View only',
                                'selected', coalesce(pp.access,'none')='read'),
             jsonb_build_object('value','write','label','Full access',
                                'selected', coalesce(pp.access,'none')='write')))
         order by fr.sort_order)
    into v_feats
  from feature_registry fr
  left join partner_permissions pp
         on pp.feature_key = fr.feature_key and pp.partner_id = p_partner_id
  where fr.is_active and fr.owner = 'partner' and fr.partner_eligible;

  select jsonb_agg(jsonb_build_object(
           'id', pu.id, 'identity', pu.identity,
           'display_name', coalesce(pu.display_name,''),
           'is_active', pu.is_active,
           'linked', (pu.auth_user_id is not null),
           'status_label', case when pu.auth_user_id is not null then 'Signed in'
                                else 'Waiting for first login' end,
           'added_label', to_char(pu.created_at at time zone 'Asia/Kolkata','dd Mon yyyy'))
         order by pu.id)
    into v_users
  from partner_users pu where pu.partner_id = p_partner_id and pu.is_active;

  select jsonb_agg(jsonb_build_object(
           'id', al.id, 'feature_key', coalesce(al.feature_key,''),
           'action', al.action,
           'user_id', coalesce(al.user_id::text,''),
           'zone_id', al.zone_id,
           'at_label', to_char(al.created_at at time zone 'Asia/Kolkata','dd Mon, HH24:MI'))
         order by al.created_at desc)
    into v_audit
  from (select * from partner_audit_log where partner_id = p_partner_id
         order by created_at desc limit 25) al;

  return jsonb_build_object(
    'ok', true,
    'partner_id', rp.id,
    'partner_name', coalesce(rp.partner_name,''),
    'district', coalesce(rp.district,''),
    'zone_id', rp.zone_id,
    'zone_label', coalesce((select name from zones where id = rp.zone_id),''),
    'zone_locked_label', coalesce(v_copy->>'zone_locked_label',''),
    'users_title', coalesce(v_copy->>'users_title',''),
    'users_subtitle', coalesce(v_copy->>'users_subtitle',''),
    'add_label', coalesce(v_copy->>'add_label',''),
    'add_hint', coalesce(v_copy->>'add_hint',''),
    'name_hint', coalesce(v_copy->>'name_hint',''),
    'remove_label', coalesce(v_copy->>'remove_label',''),
    'empty_users', coalesce(v_copy->>'empty_users',''),
    'perm_title', coalesce(v_copy->>'perm_title',''),
    'perm_subtitle', coalesce(v_copy->>'perm_subtitle',''),
    'audit_title', coalesce(v_copy->>'audit_title',''),
    'empty_audit', coalesce(v_copy->>'empty_audit',''),
    'users', coalesce(v_users,'[]'::jsonb),
    'features', coalesce(v_feats,'[]'::jsonb),
    'audit', coalesce(v_audit,'[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_partner_user_add(p_partner_id bigint, p_identity text, p_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  k text; own record; v_id bigint;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok',false,'error','partner_not_found');
  end if;
  k := identity_norm(p_identity);
  if k is null then
    return jsonb_build_object('ok',false,'error','bad_identity',
      'message','Enter a 10-digit phone number or an email address.');
  end if;

  select li.owner_type, li.owner_id into own from login_identities li where li.identity = k;
  if own.owner_type is not null and own.owner_type <> 'partner' then
    return jsonb_build_object('ok',false,'error','identity_taken',
      'message','Already attached to a ' || own.owner_type || ' account.');
  end if;

  insert into partner_users(partner_id, identity, display_name, created_by)
  values (p_partner_id, k, nullif(btrim(coalesce(p_name,'')),''), public.my_login_email())
  on conflict (identity) do update
    set partner_id = excluded.partner_id, is_active = true,
        display_name = coalesce(excluded.display_name, partner_users.display_name),
        updated_at = now()
  returning id into v_id;

  insert into login_identities(identity, kind, owner_type, owner_id)
  values (k, case when position('@' in k) > 0 then 'email' else 'phone' end, 'partner', v_id::text)
  on conflict (identity) do update set owner_type = 'partner', owner_id = v_id::text;

  insert into partner_audit_log(partner_id, partner_user_id, user_id, action, detail)
  values (p_partner_id, v_id, auth.uid(), 'login_added',
          jsonb_build_object('identity', k, 'by', public.my_login_email()));

  return jsonb_build_object('ok',true,'id',v_id,'identity',k,
    'message', coalesce(v_copy->>'added_message',''));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_partner_user_remove(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_admin_copy'),'{}'::jsonb);
  pu record;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into pu from partner_users where id = p_id;
  if pu.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  update partner_users set is_active = false, auth_user_id = null, updated_at = now()
   where id = p_id;
  delete from login_identities
   where owner_type = 'partner' and owner_id = p_id::text;

  insert into partner_audit_log(partner_id, partner_user_id, user_id, action, detail)
  values (pu.partner_id, pu.id, auth.uid(), 'login_removed',
          jsonb_build_object('identity', pu.identity, 'by', public.my_login_email()));

  return jsonb_build_object('ok',true,'message', coalesce(v_copy->>'removed_message',''));
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_pricing_list(p_search text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role         text := public.role_for_medibo_only();
  v_rows         jsonb;
  v_count        bigint;
  v_ready        bigint;
  v_scheme_ready bigint;
  v_total        bigint;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select count(*) into v_total
  from "MEDICINE" m
  where m.mrp is not null and m.mrp != '';

  select count(*) into v_ready
  from medicine_pricing where pricing_ready = true;

  select count(*) into v_scheme_ready
  from medicine_pricing where scheme_ready = true;

  select count(*), jsonb_agg(row_to_json(r))
    into v_count, v_rows
  from (
    select
      m.id           as product_id,
      m."NAME"       as name,
      m."COMPANY"    as company,
      coalesce(nullif(regexp_replace(m.mrp::text,'[^0-9.]','','g'),''),'0')::numeric as mrp,
      mp.ptr,
      mp.gst_pct,
      mp.pricing_ready,
      mp.scheme_text,
      mp.scheme_buy_qty,
      mp.scheme_free_qty,
      mp.scheme_type,
      mp.scheme_pct,
      mp.scheme_starts_at,
      mp.scheme_ends_at,
      mp.scheme_ready,
      mp.pricing_source,
      mp.pricing_updated_at
    from "MEDICINE" m
    left join medicine_pricing mp on mp.product_id = m.id
    where (m.mrp is not null and m.mrp != '')
      and (p_search is null or lower(m."NAME") like '%' || lower(p_search) || '%'
           or lower(m."COMPANY") like '%' || lower(p_search) || '%')
    order by m.sales_count desc nulls last, m.id
    limit p_limit offset p_offset
  ) r;

  return jsonb_build_object(
    'ok',       true,
    'coverage', jsonb_build_object(
      'pricing_ready',  v_ready,
      'scheme_ready',   v_scheme_ready,
      'total',          v_total,
      'pricing_pct',    case when v_total > 0 then round(v_ready * 100.0 / v_total, 1) else 0 end,
      'scheme_pct',     case when v_total > 0 then round(v_scheme_ready * 100.0 / v_total, 1) else 0 end
    ),
    'count',  coalesce(v_count, 0),
    'rows',   coalesce(v_rows, '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_region_partners()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.role_for_medibo_only() in ('admin','super_admin')
              then public.admin_region_partners_impl()
              else jsonb_build_object('error','not_authorized') end
$function$
;

CREATE OR REPLACE FUNCTION public.admin_save_platform_identity(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public._is_medibo_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;

  update platform_identity set
    platform_name       = coalesce(p->>'platform_name', platform_name),
    tagline             = coalesce(p->>'tagline', tagline),
    operator_legal_name = coalesce(p->>'operator_legal_name', operator_legal_name),
    business_name       = coalesce(p->>'business_name', business_name),
    udyam_no            = coalesce(p->>'udyam_no', udyam_no),
    nic_line            = coalesce(p->>'nic_line', nic_line),
    address             = coalesce(p->>'address', address),
    phone               = coalesce(p->>'phone', phone),
    email               = coalesce(p->>'email', email),
    established         = coalesce(p->>'established', established),
    constitution        = coalesce(p->>'constitution', constitution),
    about_paragraph     = coalesce(p->>'about_paragraph', about_paragraph),
    mission             = coalesce(p->>'mission', mission),
    updated_at          = now()
  where id = 1;

  -- CHANGE #236: the invoice half of the same form. An empty string clears the
  -- field (that is how the dialog says "remove this line from the invoice").
  if p ?| array['bill_seller_fssai','bill_seller_phone','bill_seller_email',
                'bill_bank_name','bill_bank_account','bill_bank_ifsc','bill_bank_branch',
                'bill_jurisdiction','bill_default_hsn','bill_invoice_terms'] then
    update billing_config set
      seller_fssai  = case when p ? 'bill_seller_fssai'  then nullif(btrim(p->>'bill_seller_fssai'),'')  else seller_fssai  end,
      seller_phone  = case when p ? 'bill_seller_phone'  then nullif(btrim(p->>'bill_seller_phone'),'')  else seller_phone  end,
      seller_email  = case when p ? 'bill_seller_email'  then nullif(btrim(p->>'bill_seller_email'),'')  else seller_email  end,
      bank_name     = case when p ? 'bill_bank_name'     then nullif(btrim(p->>'bill_bank_name'),'')     else bank_name     end,
      bank_account  = case when p ? 'bill_bank_account'  then nullif(btrim(p->>'bill_bank_account'),'')  else bank_account  end,
      bank_ifsc     = case when p ? 'bill_bank_ifsc'     then nullif(btrim(p->>'bill_bank_ifsc'),'')     else bank_ifsc     end,
      bank_branch   = case when p ? 'bill_bank_branch'   then nullif(btrim(p->>'bill_bank_branch'),'')   else bank_branch   end,
      jurisdiction  = case when p ? 'bill_jurisdiction'  then nullif(btrim(p->>'bill_jurisdiction'),'')  else jurisdiction  end,
      default_hsn   = case when p ? 'bill_default_hsn'   then nullif(btrim(p->>'bill_default_hsn'),'')   else default_hsn   end,
      invoice_terms = case when p ? 'bill_invoice_terms' then nullif(btrim(p->>'bill_invoice_terms'),'') else invoice_terms end
    where id = 1;
  end if;

  return jsonb_build_object('ok', true, 'message', 'Platform details saved.');
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_set_zone_scope(p_zone_id smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_email text;
BEGIN
  IF public.is_partner() THEN RETURN jsonb_build_object('error','not_authorized'); END IF;
  IF coalesce(get_my_role(),'') <> 'super_admin' THEN
    RETURN jsonb_build_object('error','not_authorized');
  END IF;
  IF p_zone_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM zones WHERE id = p_zone_id AND is_active) THEN
    RETURN jsonb_build_object('error','unknown_zone');
  END IF;
  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u WHERE u.id = auth.uid();
  INSERT INTO admin_zone_scope(admin_email, active_zone_id, updated_at)
  VALUES (v_email, p_zone_id, now())
  ON CONFLICT (admin_email) DO UPDATE SET active_zone_id = excluded.active_zone_id, updated_at = now();
  RETURN jsonb_build_object('status','ok','zone_id',p_zone_id,
    'zone_label', coalesce((SELECT name FROM zones WHERE id = p_zone_id),'All zones'));
END $function$
;

CREATE OR REPLACE FUNCTION public.c307_partner_zone_proof()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := '00000307-0000-0000-0000-000000000307';
  v_pid bigint; v_zone smallint; v_checks jsonb := '[]'::jsonb;
  v_q1 jsonb; v_q2 jsonb; v_pk jsonb; v_r jsonb; v_acc text;
  v_pass int := 0; v_fail int := 0; v_old text;
begin
  insert into partner_users(partner_id, identity, display_name, auth_user_id, created_by)
  values (1, 'c307-zone-proof', 'c307 proof', v_uid, 'c307')
  on conflict (identity) do update
    set partner_id = 1, auth_user_id = v_uid, is_active = true;

  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);

  v_pid  := public.my_partner_id();
  v_zone := public.partner_zone_id();

  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','my_partner_id',    'expected','1','got',coalesce(v_pid::text,'null')),
    jsonb_build_object('check','partner_zone_id',  'expected','1','got',coalesce(v_zone::text,'null')),
    jsonb_build_object('check','scope_zone(2)',    'expected','1','got',coalesce(public.scope_zone(2::smallint)::text,'null')),
    jsonb_build_object('check','zone_effective(2)','expected','1','got',coalesce(public.zone_effective(2::smallint)::text,'null')),
    jsonb_build_object('check','admin_active_zone','expected','1','got',coalesce(public.admin_active_zone()::text,'null')),
    jsonb_build_object('check','my_zone_id',       'expected','1','got',coalesce(public.my_zone_id()::text,'null')));

  v_pk := public.zone_picker();
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','zone_picker.show','expected','false','got',v_pk->>'show'),
    jsonb_build_object('check','zone_picker.can_change','expected','false','got',v_pk->>'can_change'));

  v_r := public.admin_set_zone_scope(2::smallint);
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','admin_set_zone_scope(2) refused','expected','true',
                       'got',(coalesce(v_r->>'error','') <> '')::text));

  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','get_my_role','expected','admin','got',public.get_my_role()),
    jsonb_build_object('check','role_for_medibo_only','expected','partner','got',public.role_for_medibo_only()));

  -- mediBO-only screens refuse a partner (each answers with its OWN slug; the
  -- assertion is that a refusal came back, not which word it used)
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','admin_pricing_list refused','expected','true',
      'got',(coalesce((public.admin_pricing_list(null,0,5))->>'error','') <> '')::text),
    jsonb_build_object('check','wa_campaigns_screen refused','expected','true',
      'got',(coalesce((public.wa_campaigns_screen())->>'error','') <> '')::text),
    jsonb_build_object('check','admin_region_partners refused','expected','true',
      'got',(coalesce((public.admin_region_partners())->>'error','') <> '')::text));

  v_q1 := public.admin_delivery_queue(current_date, 1::smallint);
  v_q2 := public.admin_delivery_queue(current_date, 2::smallint);
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','admin_delivery_queue(zone2)==zone1','expected','true','got',(v_q1 = v_q2)::text),
    jsonb_build_object('check','inquiry_locked(2)==inquiry_locked(1)','expected','true',
      'got',(public.inquiry_locked(2::smallint) is not distinct from public.inquiry_locked(1::smallint))::text),
    jsonb_build_object('check','order_hours_state(2)==order_hours_state(1)','expected','true',
      'got',(public.order_hours_state(2::smallint) = public.order_hours_state(1::smallint))::text));

  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','partner_access(medibo.pricing)','expected','none','got',public.partner_access('medibo.pricing')),
    jsonb_build_object('check','partner_access(unregistered.key)','expected','none','got',public.partner_access('unregistered.key')),
    jsonb_build_object('check','partner_open(medibo.pricing).ok','expected','false',
      'got',coalesce((public.partner_open('medibo.pricing'))->>'ok','null')),
    jsonb_build_object('check','partner_access(partner.pack) default','expected','none',
      'got',public.partner_access('partner.pack')));

  perform set_config('request.jwt.claims', coalesce(v_old,''), true);
  insert into partner_permissions(partner_id, feature_key, access)
  values (1,'partner.pack','read')
  on conflict (partner_id, feature_key) do update set access = 'read';
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);

  v_acc := public.partner_access('partner.pack');
  v_r   := public.partner_open('partner.pack');
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','partner_access(partner.pack) granted','expected','read','got',v_acc),
    jsonb_build_object('check','partner_open(partner.pack).ok','expected','true','got',coalesce(v_r->>'ok','null')),
    jsonb_build_object('check','partner_open(partner.pack).can_write','expected','false','got',coalesce(v_r->>'can_write','null')),
    jsonb_build_object('check','partner_home.show_zone_picker','expected','false',
      'got',coalesce((public.partner_home())->>'show_zone_picker','null')),
    jsonb_build_object('check','partner_home.zone_id','expected','1',
      'got',coalesce((public.partner_home())->>'zone_id','null')),
    jsonb_build_object('check','my_session.role','expected','partner','got',coalesce((public.my_session())->>'role','null')),
    jsonb_build_object('check','my_session.surface','expected','partner','got',coalesce((public.my_session())->>'surface','null')),
    jsonb_build_object('check','my_session.home_route','expected','/partner','got',coalesce((public.my_session())->>'home_route','null')),
    jsonb_build_object('check','my_session.is_super_admin','expected','false','got',coalesce((public.my_session())->>'is_super_admin','null')),
    jsonb_build_object('check','am_i_super','expected','false','got',public.am_i_super()::text));

  perform set_config('request.jwt.claims', coalesce(v_old,''), true);
  v_checks := v_checks || jsonb_build_array(
    jsonb_build_object('check','audit row stamped partner+user','expected','true',
      'got',(exists (select 1 from partner_audit_log
                      where partner_id = 1 and user_id = v_uid
                        and feature_key = 'partner.pack' and action = 'open'))::text));

  delete from login_identities where owner_type='partner'
     and owner_id in (select id::text from partner_users where identity='c307-zone-proof');
  delete from partner_users where identity = 'c307-zone-proof';
  delete from partner_permissions where partner_id = 1 and feature_key = 'partner.pack';

  select count(*) filter (where c->>'expected' = c->>'got'),
         count(*) filter (where c->>'expected' <> c->>'got')
    into v_pass, v_fail
  from jsonb_array_elements(v_checks) c;

  return jsonb_build_object('ok',(v_fail = 0),'passed',v_pass,'failed',v_fail,'checks',v_checks);
end $function$
;

CREATE OR REPLACE FUNCTION public.delete_region_partner(p_area text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_d text; v_was_active boolean; v_zone bigint;
begin
  if not public._is_medibo_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized','message',public.partner_msg('not_authorized'));
  end if;
  v_d := public.norm_district(p_area);
  select is_active, zone_id into v_was_active, v_zone from region_partners where district = v_d;
  if not found then
    return jsonb_build_object('ok',false,'error','no_partner','message',public.partner_msg('no_partner'));
  end if;
  if (select count(*) from region_partners) = 1 then
    return jsonb_build_object('ok',false,'error','cannot_delete_last','message',public.partner_msg('cannot_delete_last'));
  end if;
  delete from region_partners where district = v_d;
  -- promote a replacement WITHIN THE SAME ZONE only (other zones untouched)
  if v_was_active then
    update region_partners set is_active = true
     where id = (select id from region_partners where zone_id is not distinct from v_zone order by id limit 1)
       and not exists (select 1 from region_partners where is_active and zone_id is not distinct from v_zone);
  end if;
  return jsonb_build_object('ok',true,'deleted',v_d,'message',public.partner_msg('deleted'));
end $function$
;

CREATE OR REPLACE FUNCTION public.get_my_role()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text; v_keys text[]; v_is_admin boolean; v_is_super boolean; v_type text;
begin
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = auth.uid();
  v_keys := public.my_identity_keys();

  select true, coalesce(a.is_super,false) into v_is_admin, v_is_super
  from admins a
  where lower(btrim(a.email)) = v_email or identity_norm(a.email) = any (v_keys)
  limit 1;

  if v_is_admin then
    if v_is_super then return 'super_admin'; else return 'admin'; end if;
  end if;

  -- CHANGE #307 — zone-locked partner staff authorise as an admin against the
  -- existing fulfilment RPCs. Checked BEFORE the "no identity" bail-out below,
  -- because partner_users.auth_user_id is itself an identity.
  if public.my_partner_id() is not null then return 'admin'; end if;

  if v_email is null and (v_keys is null or cardinality(v_keys) = 0) then return 'none'; end if;

  if public.my_supplier_id() is not null then return 'supplier'; end if;

  select li.owner_type into v_type
  from login_identities li
  where li.identity = any (v_keys)
    and li.owner_type in ('company','mr','delivery','worker')
  order by case li.owner_type when 'mr' then 1 when 'delivery' then 2
                              when 'company' then 3 else 4 end, li.id
  limit 1;
  if v_type is not null then return v_type; end if;

  return 'customer';
end $function$
;

CREATE OR REPLACE FUNCTION public.is_partner()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.my_partner_id() is not null
$function$
;

CREATE OR REPLACE FUNCTION public.login_bind_owner(p_identity text, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; v_uids uuid[]; v_orders int := 0; v_cart int := 0;
        nil uuid := '00000000-0000-0000-0000-000000000000';
begin
  if p_user_id is null then return jsonb_build_object('ok',false,'message','no user'); end if;
  select owner_type, owner_id into r from login_identities where identity = p_identity;
  if not found then return jsonb_build_object('ok',false,'message','no owner'); end if;

  update pharmacy_profiles              set user_id = nil  where user_id = p_user_id;
  update supplier_profiles              set user_id = null where user_id = p_user_id;
  update lead_workers                   set user_id = null where user_id = p_user_id;
  update mr_registrations               set user_id = null where user_id = p_user_id;
  update delivery_partner_registrations set user_id = null where user_id = p_user_id;
  update company_profiles               set user_id = null where user_id = p_user_id;
  update partner_users                  set auth_user_id = null where auth_user_id = p_user_id;

  if    r.owner_type = 'customer' then
    update pharmacy_profiles              set user_id = p_user_id where id::text = r.owner_id;
  elsif r.owner_type = 'supplier' then
    update supplier_profiles              set user_id = p_user_id where id::text = r.owner_id;
  elsif r.owner_type = 'worker' then
    update lead_workers                   set user_id = p_user_id where id::text = r.owner_id;
  elsif r.owner_type = 'mr' then
    update mr_registrations               set user_id = p_user_id where id::text = r.owner_id;
  elsif r.owner_type = 'delivery' then
    update delivery_partner_registrations set user_id = p_user_id where id::text = r.owner_id;
  elsif r.owner_type = 'company' then
    update company_profiles               set user_id = p_user_id where id::text = r.owner_id;
  elsif r.owner_type = 'partner' then
    update partner_users set auth_user_id = p_user_id, updated_at = now()
     where id::text = r.owner_id;
  end if;

  if r.owner_type = 'customer' then
    v_uids := public.owner_auth_user_ids(r.owner_type, r.owner_id);
    update orders o set user_id = p_user_id
     where o.user_id = any (v_uids) and o.user_id <> p_user_id;
    get diagnostics v_orders = row_count;
    delete from cart_items c
     where c.user_id = any (v_uids) and c.user_id <> p_user_id
       and exists (select 1 from cart_items k
                    where k.user_id = p_user_id and k.product_id = c.product_id);
    update cart_items c set user_id = p_user_id
     where c.user_id = any (v_uids) and c.user_id <> p_user_id;
    get diagnostics v_cart = row_count;
  end if;

  return jsonb_build_object('ok',true,'owner_type',r.owner_type,'owner_id',r.owner_id,
                            'orders_moved',v_orders,'cart_moved',v_cart);
end $function$
;

CREATE OR REPLACE FUNCTION public.login_sync_current_user()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ident text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false); end if;

  select li.identity into v_ident
  from login_identities li
  where li.identity = any (public.my_identity_keys())
  order by case li.owner_type
             when 'admin' then 1 when 'partner' then 2 when 'supplier' then 3
             when 'customer' then 4 when 'company' then 5 when 'mr' then 6 else 7 end, li.id
  limit 1;

  if v_ident is null then return jsonb_build_object('ok',false); end if;
  return public.login_bind_owner(v_ident, auth.uid());
end $function$
;

CREATE OR REPLACE FUNCTION public.my_owner()
 RETURNS TABLE(owner_type text, owner_id text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select li.owner_type, li.owner_id
  from login_identities li
  where li.identity = any (public.my_identity_keys())
  order by case li.owner_type
             when 'admin' then 1 when 'partner' then 2 when 'supplier' then 3
             when 'customer' then 4 when 'company' then 5 when 'mr' then 6 else 7 end,
           li.id
  limit 1
$function$
;

CREATE OR REPLACE FUNCTION public.my_partner_id()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pu.partner_id
  from partner_users pu
  join region_partners rp on rp.id = pu.partner_id
  where coalesce(pu.is_active,true)
    and coalesce(rp.is_active,true)
    and (pu.auth_user_id = auth.uid()
         or pu.identity = any (public.my_identity_keys()))
  order by pu.id
  limit 1
$function$
;

CREATE OR REPLACE FUNCTION public.my_partner_user_id()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pu.id
  from partner_users pu
  join region_partners rp on rp.id = pu.partner_id
  where coalesce(pu.is_active,true)
    and coalesce(rp.is_active,true)
    and (pu.auth_user_id = auth.uid()
         or pu.identity = any (public.my_identity_keys()))
  order by pu.id
  limit 1
$function$
;

CREATE OR REPLACE FUNCTION public.my_session()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._session_partner_overlay(public.my_session_core());
$function$
;

CREATE OR REPLACE FUNCTION public.my_zone_id()
 RETURNS smallint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_role text; v_zone smallint;
BEGIN
  v_zone := public.partner_zone_id();
  IF v_zone IS NOT NULL THEN RETURN v_zone; END IF;
  v_role := coalesce(get_my_role(),'');
  IF v_role IN ('admin','super_admin') THEN RETURN public.admin_active_zone(); END IF;
  SELECT zone_id INTO v_zone FROM supplier_profiles WHERE user_id = auth.uid() LIMIT 1;
  IF v_zone IS NOT NULL THEN RETURN v_zone; END IF;
  SELECT zone_id INTO v_zone FROM pharmacy_profiles WHERE user_id = auth.uid() LIMIT 1;
  RETURN v_zone;
END $function$
;

CREATE OR REPLACE FUNCTION public.notify_center(p_hours integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_since timestamptz; v_pending int; v_dead int; v_rows jsonb; v_alerts jsonb;
        v_sent int; v_failed int; v_queued int; cfg record;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._nc('notify.not_authorized','Only an admin can open the Notification Centre.'));
  end if;
  v_since := now() - make_interval(hours => greatest(1, least(coalesce(p_hours,24), 720)));
  select * into cfg from public.notification_health_config where id;

  select count(*) filter (where status='pending'), count(*) filter (where status='dead')
    into v_pending, v_dead from public.notification_retry_queue;

  select count(*) filter (where status='sent'),
         count(*) filter (where status='failed'),
         count(*) filter (where status='queued')
    into v_sent, v_failed, v_queued
    from public.notification_log where created_at >= v_since;

  select coalesce(jsonb_agg(x order by (x->>'sort_key')::text desc), '[]'::jsonb) into v_alerts
  from (
    select jsonb_build_object(
      'id', a.id, 'sort_key', a.raised_at::text,
      'title', coalesce(r.label, a.event_key),
      'body',  public._ncf('notify.alert_body',
                 jsonb_build_object('a', a.failure_pct::text, 'b', a.failures::text, 'c', a.attempts::text),
                 '{a}% not delivered — {b} of {c} in the last hour'),
      'tone', 'bad') as x
    from public.notification_alerts a
    left join public.wa_event_routes r on r.event_key = a.event_key
    where a.status = 'open'
  ) s;

  select coalesce(jsonb_agg(x order by (x->>'sort_key')::text), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'event_key',   r.event_key,
      'sort_key',    coalesce(r.audience,'customer') || '|' || coalesce(r.label, r.event_key),
      'title',       coalesce(r.label, r.event_key),
      'audience',    coalesce(r.audience,'customer'),
      'subtitle',    coalesce(r.description, r.template_name,
                              public._nc('notify.no_template','No template linked yet')),
      'enabled',     coalesce(r.enabled,false),
      'state_label', case when not coalesce(r.enabled,false)
                          then public._nc('notify.state_off','Off')
                          when r.template_id is null
                          then public._nc('notify.state_no_template','On — no template')
                          else public._nc('notify.state_live','Live') end,
      'state_tone',  case when not coalesce(r.enabled,false) then 'muted'
                          when r.template_id is null then 'warn' else 'good' end,
      'sent',        coalesce(l.sent,0),
      'failed',      coalesce(l.failed,0),
      'queued',      coalesce(l.queued,0),
      'count_label', public._ncf('notify.count_label',
                       jsonb_build_object('a', coalesce(l.sent,0)::text,
                                          'b', (coalesce(l.failed,0) + coalesce(l.queued,0))::text),
                       '{a} sent · {b} not delivered'),
      'channels_label', public._nc('notify.channel_whatsapp','WhatsApp'),
      'preview_label',  public._nc('notify.preview_action','Preview'),
      'test_label',     public._nc('notify.test_action','Send me a test')
    ) as x
    from public.wa_event_routes r
    left join (
      select event_key,
             count(*) filter (where status='sent')   as sent,
             count(*) filter (where status='failed') as failed,
             count(*) filter (where status='queued') as queued
        from public.notification_log where created_at >= v_since group by 1) l
      on l.event_key = r.event_key
  ) s;

  return jsonb_build_object(
    'ok', true,
    'heading',        public._nc('notify.heading','Notification Centre'),
    'subheading',     public._nc('notify.subheading',
                        'Every message mediBO sends goes out through one dispatcher. WhatsApp is the only channel today.'),
    'range_label',    public._ncf('notify.range_label',
                        jsonb_build_object('a', greatest(1, least(coalesce(p_hours,24),720))::text),
                        'Last {a} hours'),
    'summary_label',  public._ncf('notify.summary_label',
                        jsonb_build_object('a', coalesce(v_sent,0)::text,
                                           'b', coalesce(v_failed,0)::text,
                                           'c', coalesce(v_queued,0)::text),
                        '{a} sent · {b} failed · {c} waiting'),
    'summary_tone',   case when coalesce(v_failed,0) = 0 and coalesce(v_queued,0) = 0 then 'good'
                           when coalesce(v_failed,0) + coalesce(v_queued,0) <= 2 then 'warn'
                           else 'bad' end,
    'pending_label',  public._ncf('notify.pending_label',
                        jsonb_build_object('a', coalesce(v_pending,0)::text),
                        '{a} waiting to be retried'),
    'pending_count',  coalesce(v_pending,0),
    'dead_label',     public._ncf('notify.dead_label', jsonb_build_object('a', coalesce(v_dead,0)::text),
                        '{a} gave up after every retry'),
    'dead_count',     coalesce(v_dead,0),
    'threshold_label',public._ncf('notify.threshold_label',
                        jsonb_build_object('a', cfg.failure_pct_threshold::text),
                        'An alert is raised when more than {a}% of an event fails within an hour'),
    'alerts_heading', public._nc('notify.alerts_heading','Needs attention'),
    'alerts',         coalesce(v_alerts,'[]'::jsonb),
    'alerts_empty',   public._nc('notify.alerts_empty','No event is failing right now.'),
    'events_heading', public._nc('notify.events_heading','Events'),
    'events',         coalesce(v_rows,'[]'::jsonb),
    'events_empty',   public._nc('notify.events_empty','No notification routes are configured yet.'),
    'retry_label',    public._nc('notify.retry_now','Retry waiting messages'));
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_access(p_feature text, p_partner bigint DEFAULT NULL::bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select pp.access
       from partner_permissions pp
       join feature_registry fr on fr.feature_key = pp.feature_key
      where pp.partner_id = coalesce(p_partner, public.my_partner_id())
        and pp.feature_key = p_feature
        and fr.is_active and fr.partner_eligible and fr.owner = 'partner'),
    'none')
$function$
;

CREATE OR REPLACE FUNCTION public.partner_audit(p_feature text, p_action text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id bigint; v_pid bigint := public.my_partner_id();
begin
  if v_pid is null then return null; end if;
  insert into partner_audit_log(partner_id, partner_user_id, user_id, zone_id,
                                feature_key, action, detail)
  values (v_pid, public.my_partner_user_id(), auth.uid(), public.partner_zone_id(),
          p_feature, coalesce(p_action,'open'), coalesce(p_detail,'{}'::jsonb))
  returning id into v_id;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_can(p_feature text, p_need text DEFAULT 'read'::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case coalesce(public.partner_access(p_feature),'none')
           when 'write' then true
           when 'read'  then (coalesce(p_need,'read') = 'read')
           else false
         end
$function$
;

CREATE OR REPLACE FUNCTION public.partner_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pid bigint := public.my_partner_id();
  v_copy jsonb := coalesce((select value from app_settings where key='partner_home_copy'),'{}'::jsonb);
  rp record; v_groups jsonb; v_zone_label text; v_n int;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok',false,'is_partner',false,
      'message', coalesce(v_copy->>'signed_out_message',''));
  end if;
  if v_pid is null then
    return jsonb_build_object('ok',false,'is_partner',false,
      'message', coalesce(v_copy->>'not_partner_message',''));
  end if;

  select * into rp from region_partners where id = v_pid;
  select z.name into v_zone_label from zones z where z.id = rp.zone_id;

  select jsonb_agg(g order by g->>'sort'), sum((g->>'count')::int)
    into v_groups, v_n
  from (
    select jsonb_build_object(
             'label', fr.group_label,
             'sort',  lpad(min(fr.sort_order)::text, 6, '0'),
             'count', count(*),
             'features', jsonb_agg(jsonb_build_object(
                 'feature_key', fr.feature_key,
                 'label',       fr.label,
                 'icon_key',    fr.icon_key,
                 'route_key',   fr.route_key,
                 'access',      public.partner_access(fr.feature_key, v_pid),
                 'can_write',   (public.partner_access(fr.feature_key, v_pid) = 'write'),
                 'access_label',
                   case public.partner_access(fr.feature_key, v_pid)
                     when 'write' then coalesce(v_copy->>'access_write_label','')
                     else coalesce(v_copy->>'access_read_label','') end)
               order by fr.sort_order)) as g
      from feature_registry fr
     where fr.is_active and fr.owner = 'partner' and fr.partner_eligible
       and public.partner_access(fr.feature_key, v_pid) <> 'none'
     group by fr.group_label
  ) s;

  return jsonb_build_object(
    'ok', true,
    'is_partner', true,
    'partner_id', v_pid,
    'partner_name', coalesce(rp.partner_name,''),
    'title',    coalesce(v_copy->>'title',''),
    'subtitle', coalesce(v_copy->>'subtitle',''),
    'zone_id', rp.zone_id,
    'zone_label', coalesce(v_zone_label,''),
    'zone_chip', case when coalesce(v_zone_label,'') = '' then ''
                      else coalesce(v_copy->>'zone_prefix','') || ' · ' || v_zone_label end,
    'show_zone_picker', false,
    'district', coalesce(rp.district,''),
    'groups', coalesce(v_groups,'[]'::jsonb),
    'feature_count', coalesce(v_n,0),
    'has_features', coalesce(v_n,0) > 0,
    'empty_title',   coalesce(v_copy->>'empty_title',''),
    'empty_message', coalesce(v_copy->>'empty_message',''));
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_open(p_feature text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_copy jsonb := coalesce((select value from app_settings where key='partner_home_copy'),'{}'::jsonb);
  v_acc text; fr record;
begin
  if public.my_partner_id() is null then
    return jsonb_build_object('ok',false,'error','not_partner',
      'message', coalesce(v_copy->>'not_partner_message',''));
  end if;
  v_acc := public.partner_access(p_feature);
  if v_acc = 'none' then
    perform public.partner_audit(p_feature,'open_denied','{}'::jsonb);
    return jsonb_build_object('ok',false,'error','no_access','access','none',
      'message', coalesce(v_copy->>'denied_message',''));
  end if;
  select * into fr from feature_registry where feature_key = p_feature;
  perform public.partner_audit(p_feature,'open', jsonb_build_object('access',v_acc));
  return jsonb_build_object('ok',true,'access',v_acc,
    'can_write', (v_acc='write'),
    'route_key', coalesce(fr.route_key,''),
    'label', coalesce(fr.label,''),
    'zone_id', public.partner_zone_id(),
    'access_label', case v_acc when 'write' then coalesce(v_copy->>'access_write_label','')
                               else coalesce(v_copy->>'access_read_label','') end);
end $function$
;

CREATE OR REPLACE FUNCTION public.partner_zone_id()
 RETURNS smallint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select rp.zone_id::smallint
  from region_partners rp
  where rp.id = public.my_partner_id()
$function$
;

CREATE OR REPLACE FUNCTION public.product_pricing_upsert(p_product_id bigint, p_fields jsonb, p_source text DEFAULT 'manual'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := public.role_for_medibo_only();
  v_ptr  numeric;
  v_gst  numeric;
  v_buy  numeric;
  v_free numeric;
  v_pct  numeric;
  v_tax  numeric := null;
  v_net  numeric := null;
  v_mrp  numeric;
  v_ready boolean;
  v_scheme_ready boolean;
  v_existing_source text;
  v_rank int;
  v_existing_rank int;
  v_c    jsonb;
begin
  if v_role not in ('admin','super_admin','service') then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  v_rank := case p_source when 'manual' then 2 when 'supplier_bill' then 1 else 0 end;

  select pricing_source into v_existing_source
  from medicine_pricing where product_id = p_product_id;

  if found then
    v_existing_rank := case v_existing_source when 'manual' then 2 when 'supplier_bill' then 1 else 0 end;
    if v_rank < v_existing_rank then
      return jsonb_build_object('ok', true, 'skipped', 'lower_rank_source');
    end if;
  end if;

  select nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]','','g'),'')::numeric
    into v_mrp from "MEDICINE" m where m.id = p_product_id;

  v_ptr  := (p_fields->>'ptr')::numeric;
  v_gst  := (p_fields->>'gst_pct')::numeric;
  v_buy  := (p_fields->>'scheme_buy_qty')::numeric;
  v_free := (p_fields->>'scheme_free_qty')::numeric;
  v_pct  := (p_fields->>'scheme_pct')::numeric;

  if coalesce(v_ptr, 0) > 0 and v_gst is not null then
    v_c := public._pricing_compute(v_mrp, v_ptr, v_gst,
             coalesce((p_fields->>'discount_pct')::numeric, 0),
             v_buy, v_free, false);
    v_tax := (v_c->>'taxable')::numeric;
    v_net := (v_c->>'net_payable')::numeric;
  end if;

  v_ready := coalesce(v_ptr, 0) > 0 AND v_gst IS NOT NULL;
  v_scheme_ready := (
    coalesce(v_buy, 0) > 0 AND coalesce(v_free, 0) > 0
  ) OR (
    coalesce((p_fields->>'scheme_type'),'') = 'pct' AND coalesce(v_pct, 0) > 0
  );

  insert into medicine_pricing (
    product_id, ptr, gst_pct, scheme_text, scheme_buy_qty, scheme_free_qty,
    discount_pct, taxable_amount, net_payable, pricing_ready,
    pricing_source, pricing_updated_at, updated_by,
    scheme_type, scheme_pct, scheme_starts_at, scheme_ends_at, scheme_ready
  ) values (
    p_product_id, v_ptr, v_gst,
    p_fields->>'scheme_text', v_buy, v_free,
    (p_fields->>'discount_pct')::numeric, v_tax, v_net,
    coalesce(v_ready, false), p_source, now(), auth.uid(),
    p_fields->>'scheme_type', v_pct,
    (p_fields->>'scheme_starts_at')::timestamptz,
    (p_fields->>'scheme_ends_at')::timestamptz,
    coalesce(v_scheme_ready, false)
  )
  on conflict (product_id) do update set
    ptr                = coalesce(excluded.ptr,             medicine_pricing.ptr),
    gst_pct            = coalesce(excluded.gst_pct,         medicine_pricing.gst_pct),
    scheme_text        = coalesce(excluded.scheme_text,     medicine_pricing.scheme_text),
    scheme_buy_qty     = coalesce(excluded.scheme_buy_qty,  medicine_pricing.scheme_buy_qty),
    scheme_free_qty    = coalesce(excluded.scheme_free_qty, medicine_pricing.scheme_free_qty),
    discount_pct       = coalesce(excluded.discount_pct,    medicine_pricing.discount_pct),
    taxable_amount     = coalesce(excluded.taxable_amount,  medicine_pricing.taxable_amount),
    net_payable        = coalesce(excluded.net_payable,     medicine_pricing.net_payable),
    pricing_ready      = excluded.pricing_ready,
    pricing_source     = excluded.pricing_source,
    pricing_updated_at = excluded.pricing_updated_at,
    updated_by         = excluded.updated_by,
    scheme_type        = coalesce(excluded.scheme_type,      medicine_pricing.scheme_type),
    scheme_pct         = coalesce(excluded.scheme_pct,       medicine_pricing.scheme_pct),
    scheme_starts_at   = coalesce(excluded.scheme_starts_at, medicine_pricing.scheme_starts_at),
    scheme_ends_at     = coalesce(excluded.scheme_ends_at,   medicine_pricing.scheme_ends_at),
    scheme_ready       = excluded.scheme_ready;

  return jsonb_build_object(
    'ok', true, 'product_id', p_product_id,
    'pricing_ready', v_ready, 'scheme_ready', coalesce(v_scheme_ready, false));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.push_admin_screen()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_role text := public.role_for_medibo_only();
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public.uic('push.not_authorized','Not authorized'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'title',         public.uic('push_admin.title','Push notifications'),
    'config_title',  public.uic('push_admin.config_title','Firebase project'),
    'events_title',  public.uic('push_admin.events_title','Events'),
    'devices_title', public.uic('push_admin.devices_title','Registered devices'),
    'save_label',    public.uic('push_admin.save','Save'),
    'can_edit_config', v_role = 'super_admin',
    'config', public.push_config_get(),
    'devices', (select jsonb_build_object(
                  'active', count(*) filter (where is_active),
                  'total',  count(*),
                  'by_platform', coalesce(jsonb_object_agg(platform, c), '{}'::jsonb))
                from (select platform, count(*) c, bool_or(is_active) is_active
                        from push_tokens group by platform) p),
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                   'event_key', event_key, 'label', label, 'audience', audience,
                   'push_enabled', push_enabled,
                   'push_title', push_title, 'push_body', push_body,
                   'push_title_hi', push_title_hi, 'push_body_hi', push_body_hi,
                   'ready', coalesce(nullif(btrim(push_body),''),'') <> ''
                 ) order by audience, label), '[]'::jsonb)
               from wa_event_routes));
end $function$
;

CREATE OR REPLACE FUNCTION public.role_for_medibo_only()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.is_partner() then 'partner' else public.get_my_role() end
$function$
;

CREATE OR REPLACE FUNCTION public.scope_zone(p_zone smallint DEFAULT NULL::smallint)
 RETURNS smallint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(public.partner_zone_id(), p_zone, public.admin_active_zone());
$function$
;

CREATE OR REPLACE FUNCTION public.wa_campaigns_screen()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; p jsonb; tzab text; sup int;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'name', c.name, 'template', c.template_name, 'category', c.category,
      'budget_inr', c.budget_inr,
      'budget_label', case when c.budget_inr is null then 'No budget cap'
                          else 'Rs ' || to_char(coalesce(c.spend_inr,0),'FM99,99,990.00') ||
                               ' of Rs ' || to_char(c.budget_inr,'FM99,99,990.00') || ' spent' end,
      'budget_pct', case when c.budget_inr > 0
                         then least(100, round(100.0 * coalesce(c.spend_inr,0) / c.budget_inr))::int end,
      'budget_tone', case when c.budget_inr is null then 'muted'
                          when coalesce(c.spend_inr,0) >= c.budget_inr then 'bad'
                          when coalesce(c.spend_inr,0) >= c.budget_inr * 0.8 then 'warn' else 'good' end,
      'holdout_pct', c.holdout_pct,
      'holdout_label', case when coalesce(c.holdout_pct,0) = 0 then 'No control group'
                            else c.holdout_pct || '% held back as a control group ('
                                 || coalesce((c.stats->>'holdout')::int,0) || ' people)' end,
      'repeat_kind', c.repeat_kind,
      'repeat_label', case coalesce(c.repeat_kind,'none')
                        when 'none' then 'Runs once'
                        when 'daily' then 'Repeats every ' || c.repeat_interval || ' day(s)'
                        when 'weekly' then 'Repeats every ' || c.repeat_interval || ' week(s)'
                        when 'monthly' then 'Repeats every ' || c.repeat_interval || ' month(s)'
                        else 'Runs once' end,
      'runs_done', c.runs_done,
      'is_repeat_child', c.parent_campaign_id is not null,
      'blank_values', coalesce((c.stats->>'blank_values')::int,0),
      'blank_warning', case when coalesce((c.stats->>'blank_values')::int,0) > 0
                            then (c.stats->>'blank_values') || ' message(s) would send with a missing value' end,
      'status', c.status,
      'status_label', case c.status when 'pending_approval' then 'Needs approval'
                                    when 'running' then 'Sending' else initcap(replace(c.status,'_',' ')) end,
      'status_tone', case c.status when 'running' then 'green' when 'completed' then 'green'
                                   when 'paused' then 'yellow' when 'pending_approval' then 'yellow'
                                   when 'cancelled' then 'grey' when 'blocked' then 'red' else 'grey' end,
      'audience_label', case when c.trigger_kind is not null then 'Trigger: '||replace(c.trigger_kind,'_',' ')
                             else 'Segment: '||replace(c.audience_kind,'_',' ') end,
      'schedule_label', case when c.scheduled_at is null then 'Not scheduled'
                             else to_char(c.scheduled_at at time zone 'Asia/Kolkata','DD Mon, FMHH12:MI am') end,
      'paused_reason', c.paused_reason,
      'stats', c.stats,
      'summary_label', format('%s sent · %s delivered · %s read · %s failed',
          coalesce(c.stats->>'sent','0'), coalesce(c.stats->>'delivered','0'),
          coalesce(c.stats->>'read','0'), coalesce(c.stats->>'failed','0')),
      'result_label', format('%s clicks · %s orders · ₹%s',
          coalesce(c.stats->>'clicks','0'), coalesce(c.stats->>'orders','0'),
          to_char(coalesce((c.stats->>'revenue')::numeric,0),'FM99,99,99,990.00')),
      'can_edit', c.status not in ('running','completed'),
      'can_schedule', c.status in ('draft','paused'),
      'can_approve', c.status = 'pending_approval',
      'can_pause', c.status = 'running',
      'can_resume', c.status = 'paused',
      'can_resend_failed', coalesce((c.stats->>'failed')::int,0) > 0)
      order by c.created_at desc), '[]'::jsonb) into v from wa_campaigns c;

  p := public._wa_policy();
  select abbrev into tzab from pg_timezone_names
   where name = coalesce(p->'send_window'->>'tz','Asia/Kolkata') limit 1;
  tzab := coalesce(tzab, p->'send_window'->>'tz', '');
  select count(*)::int into sup from wa_suppression;

  -- policy strip sentences, built from the config values above
  p := p || jsonb_build_object(
    'send_window_label',
      format('Sends %s:00–%s:00 %s', coalesce(p->'send_window'->>'start_hour','9'),
             coalesce(p->'send_window'->>'end_hour','20'), tzab),
    'frequency_cap_label',
      format('One marketing message per customer every %s days',
             coalesce(p->'frequency_cap'->>'marketing_per_days','3')),
    'auto_pause_label',
      format('Auto-pauses above %s%% failures after %s attempts',
             coalesce(p->'auto_pause'->>'failure_rate_pct','20'),
             coalesce(p->'auto_pause'->>'min_attempts','25')),
    'approval_label',
      format('Needs approval above %s recipients',
             coalesce(p->'approval'->>'required_above_recipients','100')));

  return jsonb_build_object('ok', true, 'campaigns', v,
    'audiences', jsonb_build_array(
      jsonb_build_object('key','all_approved','label','All approved customers'),
      jsonb_build_object('key','zone','label','By zone','needs','zone_id'),
      jsonb_build_object('key','active','label','Ordered recently','needs','days'),
      jsonb_build_object('key','lapsed','label','Lapsed customers','needs','days'),
      jsonb_build_object('key','never_ordered','label','Never ordered'),
      jsonb_build_object('key','top_value','label','Top customers by value','needs','limit')),
    'triggers', jsonb_build_array(
      jsonb_build_object('key','cart_idle','label','Cart idle','needs','hours'),
      jsonb_build_object('key','back_in_stock','label','Item back in stock'),
      jsonb_build_object('key','payment_due','label','Payment pending','needs','days'),
      jsonb_build_object('key','delivered_feedback','label','Delivered — ask feedback')),
    'policy', p,
    'suppressed_count', sup,
    'suppressed_label', format('%s customers opted out', sup),
    'empty', jsonb_build_object('title','No campaigns yet','note','Pick an approved template, choose an audience, schedule it'));
end
$function$
;

CREATE OR REPLACE FUNCTION public.wa_drips_screen()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'name', d.name, 'status', d.status,
      'status_label', case d.status when 'running' then 'Running' when 'paused' then 'Paused'
                                    when 'stopped' then 'Stopped' else 'Draft' end,
      'status_tone', case d.status when 'running' then 'good' when 'paused' then 'warn'
                                   when 'stopped' then 'muted' else 'muted' end,
      'audience_label', d.audience_kind,
      'exit_label', case when d.exit_on_order
                    then 'Stops chasing anyone who orders within ' || d.exit_window_days || ' days'
                    else 'Runs every step regardless of orders' end,
      'steps', (select coalesce(jsonb_agg(jsonb_build_object(
                  'step_no', st.step_no, 'template', st.template_name,
                  'delay_label', case when st.delay_days = 0 then 'Immediately'
                                 else 'Day ' || st.delay_days end,
                  'sent', (select count(*) from wa_campaign_recipients rr
                            where rr.campaign_id = st.campaign_id and rr.status in ('sent','delivered','read')))
                  order by st.step_no), '[]'::jsonb)
                from wa_drip_steps st where st.drip_id = d.id),
      'active', (select count(*) from wa_drip_enrollments en where en.drip_id=d.id and en.status='active'),
      'exited', (select count(*) from wa_drip_enrollments en where en.drip_id=d.id and en.status='exited' and en.exit_reason='ordered'),
      'completed', (select count(*) from wa_drip_enrollments en where en.drip_id=d.id and en.status='completed'),
      'can_start', d.status in ('draft','paused'), 'can_pause', d.status='running', 'can_stop', d.status in ('running','paused')
    ) order by d.updated_at desc), '[]'::jsonb) into v_rows from wa_drips d;

  return jsonb_build_object('rows', v_rows,
    'empty_copy','No sequences yet — a sequence sends a series of messages over days and stops the moment someone orders');
end $function$
;

CREATE OR REPLACE FUNCTION public.zone_effective(p_zone smallint DEFAULT NULL::smallint)
 RETURNS smallint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v smallint;
begin
  v := public.partner_zone_id();          -- CHANGE #307: clamp, not a default
  if v is not null then return v; end if;
  if p_zone is not null then return p_zone; end if;
  begin v := public.admin_active_zone(); exception when others then v := null; end;
  if v is not null then return v; end if;
  begin v := public.my_zone_id(); exception when others then v := null; end;
  if v is not null then return v; end if;
  return (select id from zones where is_default limit 1);
end $function$
;

CREATE OR REPLACE FUNCTION public.zone_picker()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_copy jsonb := coalesce((SELECT value FROM app_settings WHERE key='zone_picker_copy'),'{}'::jsonb);
  v_sel smallint; v_opts jsonb; v_label text;
BEGIN
  -- CHANGE #307 — a partner is locked to their region_partners zone.
  IF public.is_partner() THEN
    v_sel := public.partner_zone_id();
    RETURN jsonb_build_object('show', false, 'can_change', false,
      'title', coalesce(v_copy->>'locked_label',''),
      'selected_zone_id', v_sel,
      'selected_label', coalesce((SELECT name FROM zones WHERE id = v_sel),''),
      'options','[]'::jsonb, 'empty','');
  END IF;

  v_role := coalesce(get_my_role(),'');
  IF v_role NOT IN ('admin','super_admin') THEN
    RETURN jsonb_build_object('show', false, 'can_change', false,
                              'title','', 'selected_zone_id', NULL,
                              'selected_label','', 'options','[]'::jsonb, 'empty','');
  END IF;

  v_sel := public.admin_active_zone();

  IF v_role = 'super_admin' THEN
    SELECT jsonb_agg(jsonb_build_object(
             'zone_id', z.id, 'code', z.code, 'label', z.name,
             'selected', (z.id IS NOT DISTINCT FROM v_sel))
           ORDER BY z.name)
      INTO v_opts
      FROM zones z WHERE z.is_active;

    v_opts := jsonb_build_array(jsonb_build_object(
                'zone_id', NULL, 'code','all',
                'label', coalesce(v_copy->>'all_label',''),
                'selected', (v_sel IS NULL)))
              || coalesce(v_opts,'[]'::jsonb);

    v_label := coalesce((SELECT name FROM zones WHERE id = v_sel), v_copy->>'all_label');

    RETURN jsonb_build_object(
      'show', true, 'can_change', true,
      'title', coalesce(v_copy->>'title',''),
      'selected_zone_id', v_sel,
      'selected_label', coalesce(v_label,''),
      'options', v_opts,
      'empty', CASE WHEN NOT EXISTS (SELECT 1 FROM zones WHERE is_active)
                    THEN coalesce(v_copy->>'empty','') ELSE '' END);
  END IF;

  v_label := coalesce((SELECT name FROM zones WHERE id = v_sel),'');
  RETURN jsonb_build_object(
    'show', (v_label <> ''), 'can_change', false,
    'title', coalesce(v_copy->>'locked_label',''),
    'selected_zone_id', v_sel,
    'selected_label', v_label,
    'options', '[]'::jsonb, 'empty','');
END $function$
;


-- ── Grants ──────────────────────────────────────────────────────────────────
grant execute on function public.my_partner_id(), public.my_partner_user_id(),
  public.is_partner(), public.partner_zone_id(), public.role_for_medibo_only(),
  public._is_medibo_admin()
  to authenticated, anon, service_role;
grant execute on function public.partner_access(text,bigint), public.partner_can(text,text),
  public.partner_home(), public.partner_open(text), public.partner_audit(text,text,jsonb),
  public.admin_partner_console(bigint), public.admin_partner_access_set(bigint,text,text),
  public.admin_partner_user_add(bigint,text,text), public.admin_partner_user_remove(bigint)
  to authenticated, service_role;
grant execute on function public.my_session(), public.my_session_core(),
  public._session_partner_overlay(jsonb) to authenticated, anon, service_role;
revoke all on function public.c307_partner_zone_proof() from public, anon, authenticated;
grant execute on function public.c307_partner_zone_proof() to service_role;
