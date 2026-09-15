-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #690 — Exceptions console (register row feature_gaps #74)
--
-- Every stuck object in mediBO already exists somewhere: a dispute in
-- supplier_disputes, an item nobody could source in order_items.unfulfillable,
-- a shop/warehouse count that disagrees in order_items.count_diff, a WhatsApp
-- send the provider refused in wa_send_attempts, a stock follow-up nobody
-- answered in stock_update_queue, a payment claim nobody verified, and every
-- ops-board class sitting past its own SLA. Seven tables, no owner, no age,
-- and no record of how any of them ended.
--
-- This migration makes that ONE queue:
--   exception_reason           the fixed reason enum (labels live in ui_copy)
--   exception_state            per-object status/owner/outcome — the only new
--                              state; the source rows are never mutated
--   exception_outcome          the fixed outcome enum a close must pick from
--   exception_scorecard_input  what a close feeds back to supplier/partner
--   _exception_rows()          the seven sources unified, de-duplicated
--   exceptions_queue()         the console payload (every string rendered here)
--   exceptions_close()         records the outcome + the scorecard input
--   exceptions_start()         open -> working
--   exceptions_action()        the one-tap next action, dispatched server-side
--   exception_digest_line()    the nightly per-zone line for the #398 digest
--
-- Idempotent end to end: a resumed worker may re-run this file safely.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. The reason enum ──────────────────────────────────────────────────────
create table if not exists public.exception_reason (
  reason_code  text primary key,
  source_key   text        not null,
  severity     smallint    not null default 3,   -- 1..5, multiplies age to rank
  sla_hours    numeric     not null default 24,
  owner_kind   text        not null default 'zone',  -- 'zone' | 'admin'
  action_kind  text        not null default 'route', -- 'rpc' | 'route' | 'none'
  action_route text        not null default '',
  sort_rank    int         not null default 50,
  enabled      boolean     not null default true,
  created_at   timestamptz not null default now()
);

insert into public.exception_reason
  (reason_code, source_key, severity, sla_hours, owner_kind, action_kind, action_route, sort_rank)
values
  ('dispute_open',           'supplier_disputes',  5, 24,  'zone',  'route', 'dispute',     90),
  ('item_unfulfillable',     'order_items',        4, 12,  'zone',  'route', 'customer_order', 85),
  ('count_variance',         'order_items',        4, 24,  'zone',  'route', 'warehouse',   80),
  ('wa_send_failed',         'wa_send_attempts',   5, 6,   'admin', 'rpc',   'wa_ops',      75),
  ('stock_followup_overdue', 'stock_update_queue', 3, 24,  'zone',  'rpc',   'supplier_shop', 70),
  ('payment_claim_stuck',    'payment_claims',     4, 24,  'admin', 'route', 'payments',    65),
  ('sla_breach',             'ops_board',          2, 0,   'zone',  'route', '',            60)
on conflict (reason_code) do update
  set source_key   = excluded.source_key,
      severity     = excluded.severity,
      sla_hours    = excluded.sla_hours,
      owner_kind   = excluded.owner_kind,
      action_kind  = excluded.action_kind,
      action_route = excluded.action_route,
      sort_rank    = excluded.sort_rank;

-- ── 2. The only new state. Source rows stay untouched. ──────────────────────
create table if not exists public.exception_state (
  id           text primary key,              -- '<reason_code>:<ref_id>'
  reason_code  text        not null,
  ref_id       text        not null,
  status       text        not null default 'open',   -- open | working | closed
  zone_id      smallint,
  owner_kind   text,
  owner_id     text,
  owner_label  text,
  outcome_code text,
  note         text,
  started_at   timestamptz,
  started_by   text,
  closed_at    timestamptz,
  closed_by    text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists exception_state_ref_uq
  on public.exception_state (reason_code, ref_id);
create index if not exists exception_state_open_ix
  on public.exception_state (status) where status <> 'closed';

alter table public.exception_state enable row level security;

-- ── 3. The outcome enum a close must pick from ──────────────────────────────
create table if not exists public.exception_outcome (
  outcome_code text primary key,
  applies_to   text    not null default 'all',  -- 'all' or one reason_code
  affects      text    not null default 'none', -- 'supplier' | 'partner' | 'none'
  weight       numeric not null default 0,
  is_success   boolean not null default true,
  sort_rank    int     not null default 50,
  enabled      boolean not null default true
);

insert into public.exception_outcome
  (outcome_code, applies_to, affects, weight, is_success, sort_rank)
values
  ('supplier_replaced',  'all', 'supplier', -1, true,  90),
  ('supplier_credited',  'all', 'supplier', -1, true,  85),
  ('written_off',        'all', 'supplier', -2, false, 80),
  ('partner_handled',    'all', 'partner',   1, true,  75),
  ('no_fault',           'all', 'none',      0, true,  70),
  ('duplicate',          'all', 'none',      0, true,  60)
on conflict (outcome_code) do update
  set applies_to = excluded.applies_to,
      affects    = excluded.affects,
      weight     = excluded.weight,
      is_success = excluded.is_success,
      sort_rank  = excluded.sort_rank;

-- ── 4. What a recorded outcome feeds back ───────────────────────────────────
-- Deliberately an INPUT table, not a mutation of supplier_profiles."SPN": SPN
-- components are admin-chosen values, and a console close must never silently
-- move a supplier's rank. Scoring reads this; nothing here writes SPN.
create table if not exists public.exception_scorecard_input (
  id           bigserial primary key,
  subject_kind text        not null,   -- 'supplier' | 'partner'
  subject_key  text        not null,
  reason_code  text        not null,
  outcome_code text        not null,
  weight       numeric     not null default 0,
  exception_id text        not null,
  zone_id      smallint,
  closed_at    timestamptz not null default now(),
  closed_by    text
);
create index if not exists exception_scorecard_subject_ix
  on public.exception_scorecard_input (subject_kind, subject_key, closed_at desc);

alter table public.exception_scorecard_input enable row level security;

-- ── 5. Copy. Every string the console prints is an UPDATE away, not a deploy ─
insert into public.ui_copy (key, value) values
  ('exc.title',            to_jsonb('Exceptions'::text)),
  ('exc.subtitle',         to_jsonb('Everything stuck, oldest and worst first.'::text)),
  ('exc.empty',            to_jsonb('Nothing is stuck. Every queue is inside its deadline.'::text)),
  ('exc.empty_filtered',   to_jsonb('Nothing stuck under this reason.'::text)),
  ('exc.clean',            to_jsonb('All clear'::text)),
  ('exc.count_one',        to_jsonb('1 open'::text)),
  ('exc.count_many',       to_jsonb('{n} open'::text)),
  ('exc.not_authorized',   to_jsonb('You do not have access to the exceptions queue.'::text)),
  ('exc.refresh',          to_jsonb('Refresh'::text)),
  ('exc.retry',            to_jsonb('Retry'::text)),
  ('exc.filter.all',       to_jsonb('All'::text)),
  ('exc.filter_label',     to_jsonb('Filter by reason'::text)),
  ('exc.age',              to_jsonb('{age} old'::text)),
  ('exc.sla_over',         to_jsonb('{h}h past deadline'::text)),
  ('exc.sla_within',       to_jsonb('Inside deadline'::text)),
  ('exc.zone_all',         to_jsonb('All zones'::text)),
  ('exc.owner.admin',      to_jsonb('mediBO admin'::text)),
  ('exc.owner.partner',    to_jsonb('{name}'::text)),
  ('exc.owner_prefix',     to_jsonb('Owner: {owner}'::text)),
  ('exc.status.open',      to_jsonb('Open'::text)),
  ('exc.status.working',   to_jsonb('Working'::text)),
  ('exc.status.closed',    to_jsonb('Closed'::text)),
  ('exc.reason.dispute_open',           to_jsonb('Dispute open'::text)),
  ('exc.reason.item_unfulfillable',     to_jsonb('No supplier found'::text)),
  ('exc.reason.count_variance',         to_jsonb('Count mismatch'::text)),
  ('exc.reason.wa_send_failed',         to_jsonb('WhatsApp refused'::text)),
  ('exc.reason.stock_followup_overdue', to_jsonb('Stock follow-up overdue'::text)),
  ('exc.reason.payment_claim_stuck',    to_jsonb('Payment claim unverified'::text)),
  ('exc.reason.sla_breach',             to_jsonb('Past SLA'::text)),
  ('exc.action.dispute_open',           to_jsonb('Open the dispute'::text)),
  ('exc.action.item_unfulfillable',     to_jsonb('Open the order'::text)),
  ('exc.action.count_variance',         to_jsonb('Open the recount'::text)),
  ('exc.action.wa_send_failed',         to_jsonb('Retry the send'::text)),
  ('exc.action.stock_followup_overdue', to_jsonb('Send the form again'::text)),
  ('exc.action.payment_claim_stuck',    to_jsonb('Verify the payment'::text)),
  ('exc.action.sla_breach',             to_jsonb('Open the queue'::text)),
  ('exc.action.done',      to_jsonb('Action sent.'::text)),
  ('exc.action.failed',    to_jsonb('That action could not run. Open the screen instead.'::text)),
  ('exc.close',            to_jsonb('Close'::text)),
  ('exc.close.title',      to_jsonb('How did this end?'::text)),
  ('exc.close.hint',       to_jsonb('Pick the outcome. It is recorded against the supplier or the partner.'::text)),
  ('exc.close.note_hint',  to_jsonb('Note (optional)'::text)),
  ('exc.close.submit',     to_jsonb('Record outcome'::text)),
  ('exc.close.cancel',     to_jsonb('Cancel'::text)),
  ('exc.close.pick',       to_jsonb('Pick an outcome first.'::text)),
  ('exc.close.done',       to_jsonb('Outcome recorded.'::text)),
  ('exc.close.gone',       to_jsonb('That exception is already closed.'::text)),
  ('exc.not_found',        to_jsonb('That exception is no longer in the queue.'::text)),
  ('exc.outcome.supplier_replaced', to_jsonb('Supplier replaced the stock'::text)),
  ('exc.outcome.supplier_credited', to_jsonb('Supplier credited the amount'::text)),
  ('exc.outcome.written_off',       to_jsonb('Written off — mediBO absorbed it'::text)),
  ('exc.outcome.partner_handled',   to_jsonb('Partner handled it in the zone'::text)),
  ('exc.outcome.no_fault',          to_jsonb('No fault — nothing was wrong'::text)),
  ('exc.outcome.duplicate',         to_jsonb('Duplicate of another exception'::text)),
  ('exc.digest.line',      to_jsonb('{n} exceptions open in your zone. Oldest: {oldest}.'::text)),
  ('exc.digest.one',       to_jsonb('1 exception open in your zone: {oldest}.'::text)),
  ('exc.digest.none',      to_jsonb('No open exceptions in your zone.'::text))
on conflict (key) do nothing;

-- ── 6. The Fulfill tab + its access keys ────────────────────────────────────
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   deep_link, search_terms, description, partner_feature_key, canonical_key)
values
  ('partner.exceptions', 'Exceptions', 'Fulfilment', 'alert', 'exceptions', 95,
   'partner', true, 'none', true, 'system', 'dashboard', '{admin,super_admin}',
   '', 'exception stuck reason owner age', '', null, 'partner.exceptions'),
  ('fulfill.exceptions', 'Exceptions', 'Fulfill', 'alert', 'exceptions', 95,
   'medibo', false, 'read', true, 'orders', 'fulfill_tab', '{admin,super_admin}',
   '/admin/go/exceptions',
   'exception stuck reason owner age dispute unfulfillable count variance',
   'Stage 10 — every stuck object in one queue, with a reason and an owner',
   'partner.exceptions', 'partner.exceptions')
on conflict (feature_key) do update
  set label               = excluded.label,
      route_key           = excluded.route_key,
      sort_order          = excluded.sort_order,
      surface             = excluded.surface,
      is_active           = true,
      deep_link           = excluded.deep_link,
      description         = excluded.description,
      partner_feature_key = excluded.partner_feature_key,
      canonical_key       = excluded.canonical_key;

-- feature_registry seeds a default row of its own the moment the feature is
-- registered, so this must be an UPDATE, not a do-nothing: an admin who cannot
-- close an exception cannot work the queue at all.
insert into public.access_role_default (role, feature_key, can_view, can_write)
values ('super_admin', 'partner.exceptions', true,  true),
       ('admin',       'partner.exceptions', true,  true),
       ('partner',     'partner.exceptions', false, false)
on conflict (role, feature_key) do update
  set can_view  = excluded.can_view,
      can_write = excluded.can_write;

-- The three console RPCs are partner-callable; each scopes to the caller's
-- own zone internally, so there is nothing to clamp at the door.
insert into public.partner_rpc_allow (proname, source, note)
values ('exceptions_queue',  'c690', 'exceptions console — scoped to the partner zone inside the RPC'),
       ('exceptions_close',  'c690', 'exceptions console — zone checked inside the RPC'),
       ('exceptions_start',  'c690', 'exceptions console — zone checked inside the RPC'),
       ('exceptions_action', 'c690', 'exceptions console — zone checked inside the RPC')
on conflict (proname) do nothing;


-- ── 7. The seven sources, unified. ──────────────────────────────────────────
-- Each stuck object appears EXACTLY once. The overlaps are cut here,
-- deliberately:
--   • count_variance excludes items already flagged unfulfillable — those are
--     the item_unfulfillable exception, not a counting one.
--   • sla_breach carries only the ops-board classes with no dedicated reason of
--     their own; claims_unverified, stock_followup_overdue and wa_send_blocked
--     are owned by payment_claim_stuck, stock_followup_overdue and
--     wa_send_failed, so they are excluded from it.
-- Nothing filters `is_synthetic` — admin_ops_board() does not either, and two
-- surfaces counting the same thing differently is the disagreement this
-- console exists to end.
create or replace function public._exception_rows()
returns table (
  reason_code  text,
  ref_id       text,
  zone_id      smallint,
  title        text,
  subtitle     text,
  since        timestamptz,
  supplier_key text,
  action_ref   text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- 1. Disputes nobody resolved.
  select 'dispute_open'::text, d.id::text, oi.zone_id,
         coalesce(nullif(d.product_name,''), '—'),
         coalesce(nullif(d.assigned_supplier,''), '—'),
         d.created_at,
         nullif(d.assigned_supplier,''),
         d.id::text
    from public.supplier_disputes d
    left join public.order_items oi on oi.id = d.order_item_id
   where d.resolved_at is null

  union all
  -- 2. Items no supplier could fill.
  select 'item_unfulfillable', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.unfulfillable_reason,''), '—'),
         coalesce(oi.unfulfillable_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.order_id::text
    from public.order_items oi
   where oi.unfulfillable is true

  union all
  -- 3. Shop count and warehouse recount disagree.
  select 'count_variance', oi.id::text, oi.zone_id,
         coalesce(nullif(oi.product_name,''), '—'),
         coalesce(nullif(oi.assigned_supplier,''), '—'),
         coalesce(oi.received_at, oi.created_at),
         nullif(oi.assigned_supplier,''),
         oi.id::text
    from public.order_items oi
   where oi.count_diff is not null
     and oi.count_diff <> 0
     and coalesce(oi.unfulfillable, false) = false

  union all
  -- 4. WhatsApp sends the provider is refusing — the same blocking-fault
  --    filter the ops board already uses, so the two surfaces cannot disagree.
  select 'wa_send_failed', a.id::text,
         (select o.zone_id from public.orders o where o.id = a.order_id),
         coalesce(nullif(a.reason,''), '—'),
         coalesce(nullif(a.event_key,''), '—'),
         a.created_at,
         null,
         a.id::text
    from public.wa_send_attempts a
   where a.ok = false
     and a.created_at >= now() - interval '7 days'
     and coalesce(a.phone,'') not like '9000000%'
     and exists (select 1 from public.wa_send_fault_rule f
                  where f.enabled and f.is_blocking
                    and ((f.match_kind = 'exact' and a.reason = f.match_text)
                      or (f.match_kind = 'ilike' and a.reason ilike f.match_text)))

  union all
  -- 5. Stock follow-ups past their due date and still unanswered.
  select 'stock_followup_overdue', q.id::text, q.zone_id,
         coalesce(nullif(m.product_name,''), 'Product ' || q.product_id::text),
         coalesce(nullif(q.supplier_name,''), '—'),
         q.due_at,
         nullif(q.supplier_name,''),
         q.id::text
    from public.stock_update_queue q
    left join public."MEDICINE" m on m.id = q.product_id
   where q.resolved_at is null
     and q.due_at < now()

  union all
  -- 6. Payment claims nobody verified, once they are past the reason's SLA.
  select 'payment_claim_stuck', pc.id::text, pc.zone_id,
         coalesce(nullif(pc.utr,''), 'Claim ' || left(pc.id::text, 8)),
         coalesce(nullif(pc.payee_name,''), nullif(pc.sender_phone,''), '—'),
         coalesce(pc.paid_ts, pc.received_at, pc.created_at),
         null,
         pc.id::text
    from public.payment_claims pc
   where coalesce(pc.status,'') not in ('verified','rejected')
     and coalesce(pc.paid_ts, pc.received_at, pc.created_at)
         < now() - make_interval(hours =>
             (select r.sla_hours::int from public.exception_reason r
               where r.reason_code = 'payment_claim_stuck'))

  union all
  -- 7. Everything else on the ops board that is past its OWN class deadline.
  select 'sla_breach', b.class_key || '/' || b.item_id, b.zone_id,
         b.item_label,
         c.title || ' · ' || b.item_sub,
         b.since,
         null,
         b.class_key
    from (
      select 'orders_open'::text class_key, o.id::text item_id, o.zone_id,
             coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)) item_label,
             coalesce(nullif(o.pharmacy_name,''), '—') item_sub, o.created_at since
        from public.orders o where o.closed_at is null
      union all
      select 'supplier_unsettled', so.id::text, so.zone_id,
             coalesce(nullif(so.order_code,''), 'SO ' || left(so.id::text,8)),
             coalesce(nullif(so.supplier_name,''), '—'), so.created_at
        from public.supplier_orders so where so.settled_at is null
      union all
      select 'inquiry_pending', i.id::text, i.zone_id,
             coalesce(nullif(i.product_name,''), 'Inquiry ' || i.id::text),
             coalesce(nullif(i.current_status,''), '—'),
             coalesce(i.asked_at, i.created_at)
        from public.inquiry i where i.current_status = 'Confirmation Pending'
      union all
      select 'bills_pending', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Bill ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.status = 'pending'
      union all
      select 'bill_scan_error', pb.id::text, null::smallint,
             coalesce(nullif(pb.file_name,''), 'Scan ' || left(pb.id::text,8)),
             coalesce(nullif(pb.supplier_name,''), '—'),
             coalesce(pb.received_at, pb.created_at)
        from public.pending_bills pb where pb.scan_status = 'error'
      union all
      select 'catalog_barcode_gap', bm.barcode_norm, null::smallint,
             coalesce(nullif(bm.sample_raw,''), bm.barcode_norm),
             bm.miss_count || case when bm.miss_count = 1 then ' scan' else ' scans' end
               || ', no product',
             bm.first_seen
        from public.catalog_barcode_miss bm
       where not exists (
               select 1 from public."MEDICINE" m
                where m.barcode is not null and btrim(m.barcode) <> ''
                  and public._norm_barcode(m.barcode) = bm.barcode_norm)
         and not exists (
               select 1 from public.product_barcode pb2
                where public._norm_barcode(pb2.barcode) = bm.barcode_norm)
    ) b
    join public.ops_board_class c
      on c.key = b.class_key and c.enabled
   where b.since < now() - make_interval(hours => c.sla_hours::int)
$function$;

-- ── 8. The console payload ──────────────────────────────────────────────────
-- One RPC, one pass over the sources, every string written HERE. The Flutter
-- screen sorts nothing, pluralises nothing and formats no age: `sort_score` is
-- age × severity, and the ORDER of `rows` is the answer to "what next".
create or replace function public.exceptions_queue(
  p_zone   smallint default null,
  p_reason text     default null,
  p_status text     default 'open',
  p_limit  int      default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role    text     := coalesce(public.get_my_role(), 'none');
  v_partner bigint   := public.my_partner_id();
  v_access  text;
  v_zone    smallint;
  v_status  text     := lower(coalesce(nullif(btrim(p_status),''), 'open'));
  v_reason  text     := nullif(btrim(coalesce(p_reason,'')), '');
  v_limit   int      := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_zlabel  text;
  v_out     jsonb;
begin
  if auth.uid() is null or v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', public._c('exc.title'),
      'message', public._c('exc.not_authorized'),
      'rows', '[]'::jsonb, 'count', 0);
  end if;

  v_access := case when v_partner is not null
                   then coalesce(public.partner_access('partner.exceptions', v_partner), 'none')
                   else coalesce(public.admin_access('fulfill.exceptions'), 'none') end;

  if v_access = 'none' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', public._c('exc.title'),
      'message', public._c('exc.not_authorized'),
      'rows', '[]'::jsonb, 'count', 0);
  end if;

  -- A partner never chooses a zone: it is theirs, always.
  v_zone := case when v_partner is not null
                 then (select r.zone_id::smallint from public.region_partners r where r.id = v_partner)
                 else p_zone end;

  v_zlabel := coalesce((select z.name from public.zones z where z.id = v_zone),
                       public._c('exc.zone_all'));

  if v_reason = 'all' then v_reason := null; end if;

  with base as (
    select r.reason_code || ':' || r.ref_id                             as id,
           r.reason_code, r.ref_id, r.zone_id, r.title, r.subtitle,
           r.since, r.action_ref,
           x.severity, x.sla_hours, x.owner_kind, x.action_kind,
           x.action_route, x.sort_rank,
           coalesce(s.status, 'open')                                   as status,
           s.outcome_code,
           round((extract(epoch from (now() - r.since)) / 3600.0)::numeric, 2) as age_hours
      from public._exception_rows() r
      join public.exception_reason x
        on x.reason_code = r.reason_code and x.enabled
      left join public.exception_state s
        on s.reason_code = r.reason_code and s.ref_id = r.ref_id
     where (v_zone is null or r.zone_id = v_zone or r.zone_id is null)
       and case v_status
             when 'closed' then coalesce(s.status,'open') = 'closed'
             when 'all'    then true
             else coalesce(s.status,'open') <> 'closed'
           end
  ),
  scored as (
    select b.*, (b.age_hours * b.severity) as sort_score, ow.blk as owner_blk
      from base b
      cross join lateral (
        select case
          when b.owner_kind = 'admin' or b.zone_id is null then
            jsonb_build_object('kind','admin','id','','label', public._c('exc.owner.admin'))
          else coalesce((
            select jsonb_build_object('kind','partner','id', rp.id::text,
                     'label', public._cf('exc.owner.partner',
                                jsonb_build_object('name', coalesce(nullif(rp.partner_name,''), ''))))
              from public.region_partners rp
             where rp.zone_id = b.zone_id and coalesce(rp.is_active, true)
             order by rp.id limit 1),
            jsonb_build_object('kind','admin','id','','label', public._c('exc.owner.admin')))
        end as blk) ow
  ),
  tot as (select count(*)::int as n from scored),
  filt as (
    select jsonb_build_array(jsonb_build_object(
             'key', 'all', 'label', public._c('exc.filter.all'),
             'count', (select n from tot), 'selected', (v_reason is null)))
           || coalesce((
             select jsonb_agg(jsonb_build_object(
                      'key',      g.reason_code,
                      'label',    public._c('exc.reason.' || g.reason_code),
                      'count',    g.n,
                      'selected', (v_reason is not null and v_reason = g.reason_code))
                    order by g.rank desc, g.n desc)
               from (select s.reason_code, count(*)::int n, max(s.sort_rank) rank
                       from scored s group by s.reason_code) g), '[]'::jsonb) as j
  ),
  picked as (
    select s.* from scored s
     where (v_reason is null or s.reason_code = v_reason)
     order by s.sort_score desc, s.since asc
     limit v_limit
  ),
  rws as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',            p.id,
             'reason_code',   p.reason_code,
             'reason_label',  public._c('exc.reason.' || p.reason_code),
             'severity',      p.severity,
             'title',         p.title,
             'subtitle',      p.subtitle,
             'ref_id',        p.ref_id,
             'zone_id',       p.zone_id,
             'zone_label',    coalesce((select z.name from public.zones z where z.id = p.zone_id), ''),
             'age_label',     public._cf('exc.age', jsonb_build_object(
                                'age', public.ops_age_label(p.since))),
             'age_hours',     p.age_hours,
             'sort_score',    p.sort_score,
             'over_sla',      (p.age_hours > p.sla_hours),
             'sla_label',     case when p.age_hours > p.sla_hours
                                   then public._cf('exc.sla_over', jsonb_build_object(
                                          'h', floor(p.age_hours - p.sla_hours)::int::text))
                                   else public._c('exc.sla_within') end,
             'tone',          case when p.age_hours <= p.sla_hours then 'info'
                                   when p.severity >= 5 then 'bad'
                                   when p.age_hours > p.sla_hours * 3 then 'bad'
                                   else 'warn' end,
             'owner',         p.owner_blk,
             'owner_label',   public._cf('exc.owner_prefix',
                                jsonb_build_object('owner', p.owner_blk->>'label')),
             'status',        p.status,
             'status_label',  public._c('exc.status.' || p.status),
             'status_tone',   case p.status when 'closed' then 'good'
                                            when 'working' then 'warn'
                                            else 'info' end,
             'next_action',   case
               when p.action_kind = 'rpc' then jsonb_build_object(
                 'has', true, 'kind', 'rpc',
                 'label', public._c('exc.action.' || p.reason_code),
                 'rpc', 'exceptions_action',
                 'args', jsonb_build_object('p_id', p.id),
                 'route', p.action_route)
               when p.action_kind = 'route' then jsonb_build_object(
                 'has', true, 'kind', 'route',
                 'label', public._c('exc.action.' || p.reason_code),
                 'rpc', '', 'args', '{}'::jsonb,
                 'route', coalesce(nullif(p.action_route, ''),
                            (select m.route from public.exception_route_map m
                              where m.class_key = p.action_ref),
                            (select c.action_route from public.ops_board_class c
                              where c.key = p.action_ref), ''))
               else jsonb_build_object('has', false, 'kind', 'none',
                 'label', '', 'rpc', '', 'args', '{}'::jsonb, 'route', '')
             end,
             'close_label',   public._c('exc.close'),
             'can_close',     (v_access = 'write' and p.status <> 'closed'),
             'outcome_label', case when p.outcome_code is null then ''
                                   else public._c('exc.outcome.' || p.outcome_code) end)
             order by p.sort_score desc, p.since asc), '[]'::jsonb) as j
      from picked p
  )
  select jsonb_build_object(
    'ok',            true,
    'title',         public._c('exc.title'),
    'subtitle',      public._c('exc.subtitle'),
    'role',          v_role,
    'is_partner',    (v_partner is not null),
    'partner_id',    v_partner,
    'zone_id',       v_zone,
    'zone_label',    v_zlabel,
    'access',        v_access,
    'can_write',     (v_access = 'write'),
    'status_key',    v_status,
    'reason_key',    coalesce(v_reason, 'all'),
    'count',         t.n,
    'count_label',   case when t.n = 0 then public._c('exc.clean')
                          when t.n = 1 then public._c('exc.count_one')
                          else public._cf('exc.count_many',
                                 jsonb_build_object('n', t.n::text)) end,
    'tone',          case when t.n = 0 then 'good' else 'warn' end,
    'empty_label',   case when v_reason is null then public._c('exc.empty')
                          else public._c('exc.empty_filtered') end,
    'filter_label',  public._c('exc.filter_label'),
    'refresh_label', public._c('exc.refresh'),
    'retry_label',   public._c('exc.retry'),
    'filters',       f.j,
    'outcomes',      coalesce((
                       select jsonb_agg(jsonb_build_object(
                                'code', o.outcome_code,
                                'label', public._c('exc.outcome.' || o.outcome_code),
                                'affects', o.affects,
                                'is_success', o.is_success)
                              order by o.sort_rank desc)
                         from public.exception_outcome o where o.enabled), '[]'::jsonb),
    'close',         jsonb_build_object(
                       'title',     public._c('exc.close.title'),
                       'hint',      public._c('exc.close.hint'),
                       'note_hint', public._c('exc.close.note_hint'),
                       'submit',    public._c('exc.close.submit'),
                       'cancel',    public._c('exc.close.cancel'),
                       'pick',      public._c('exc.close.pick')),
    'rows',          r.j)
    into v_out
    from tot t, filt f, rws r;

  return v_out;
end $function$;

-- ── 9. Who may write, and to which exception ────────────────────────────────
-- Returns the live source row behind an exception id, or nothing. A partner
-- only ever resolves an exception inside their own zone; an admin resolves any.
create or replace function public._exception_writable(p_id text)
returns table (
  reason_code text, ref_id text, zone_id smallint, supplier_key text,
  action_ref text, title text, refusal text)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_role    text   := coalesce(public.get_my_role(), 'none');
  v_partner bigint := public.my_partner_id();
  v_access  text;
  v_zone    smallint;
begin
  if auth.uid() is null or v_role not in ('admin','super_admin') then
    return query select null::text, null::text, null::smallint, null::text,
                        null::text, null::text, public._c('exc.not_authorized');
    return;
  end if;

  v_access := case when v_partner is not null
                   then coalesce(public.partner_access('partner.exceptions', v_partner), 'none')
                   else coalesce(public.admin_access('fulfill.exceptions'), 'none') end;

  if v_access <> 'write' then
    return query select null::text, null::text, null::smallint, null::text,
                        null::text, null::text, public._c('exc.not_authorized');
    return;
  end if;

  v_zone := case when v_partner is not null
                 then (select r.zone_id::smallint from public.region_partners r where r.id = v_partner)
                 else null end;

  return query
    select r.reason_code, r.ref_id, r.zone_id, r.supplier_key, r.action_ref,
           r.title, ''::text
      from public._exception_rows() r
     where r.reason_code || ':' || r.ref_id = p_id
       and (v_zone is null or r.zone_id = v_zone or r.zone_id is null)
     limit 1;
end $function$;

-- ── 10. open -> working ─────────────────────────────────────────────────────
create or replace function public.exceptions_start(p_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare w record; v_actor text := coalesce(public.my_admin_id()::text, auth.uid()::text);
begin
  -- _exception_writable returns a refusal ROW when the caller may not write, and
  -- NO row when the id is not (or is no longer) a live exception. Those are
  -- different sentences and the console prints whichever is true.
  select * into w from public._exception_writable(p_id);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public._c('exc.not_found'));
  end if;
  if coalesce(w.refusal,'') <> '' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', w.refusal);
  end if;

  insert into public.exception_state
    (id, reason_code, ref_id, status, zone_id, started_at, started_by)
  values (p_id, w.reason_code, w.ref_id, 'working', w.zone_id, now(), v_actor)
  on conflict (id) do update
    set status     = case when public.exception_state.status = 'closed'
                          then public.exception_state.status else 'working' end,
        started_at = coalesce(public.exception_state.started_at, now()),
        started_by = coalesce(public.exception_state.started_by, v_actor),
        updated_at = now();

  return jsonb_build_object('ok', true, 'id', p_id,
    'status', (select s.status from public.exception_state s where s.id = p_id),
    'status_label', public._c('exc.status.' ||
      (select s.status from public.exception_state s where s.id = p_id)));
end $function$;

-- ── 11. The one-tap next action, dispatched in the backend ──────────────────
-- The screen sends an id and nothing else. Which RPC that becomes is a
-- backend decision, so adding an action never ships a Flutter build.
create or replace function public.exceptions_action(p_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  w      record;
  v_res  jsonb := '{}'::jsonb;
  v_tok  text;
  v_ok   boolean := false;
begin
  -- _exception_writable returns a refusal ROW when the caller may not write, and
  -- NO row when the id is not (or is no longer) a live exception. Those are
  -- different sentences and the console prints whichever is true.
  select * into w from public._exception_writable(p_id);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public._c('exc.not_found'));
  end if;
  if coalesce(w.refusal,'') <> '' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', w.refusal);
  end if;

  begin
    if w.reason_code = 'wa_send_failed' then
      v_res := public.wa_send_retry(w.ref_id::bigint);
      v_ok  := true;

    elsif w.reason_code = 'stock_followup_overdue' then
      select q.last_token into v_tok
        from public.stock_update_queue q where q.id = w.ref_id::bigint;
      if coalesce(v_tok,'') <> '' then
        update public.stock_update_forms set last_sent_at = now() where token = v_tok;
        v_res := jsonb_build_object('sent', public.send_stock_update_wa(v_tok));
      else
        -- Never asked: put it back in the sweep and run it now.
        update public.stock_update_queue set asked_at = null where id = w.ref_id::bigint;
        v_res := public.stock_update_sweep();
      end if;
      v_ok := true;
    end if;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'action_failed',
      'message', public._c('exc.action.failed'), 'detail', sqlerrm);
  end;

  if not v_ok then
    return jsonb_build_object('ok', false, 'error', 'no_action',
      'message', public._c('exc.action.failed'));
  end if;

  -- The dispatched RPC's own verdict wins. "Sent again" and "that send had no
  -- number" are both answers from wa_send_retry, and the console must print
  -- the one that actually happened rather than a cheerful default.
  if v_res ? 'ok' and coalesce((v_res->>'ok')::boolean, false) = false then
    return jsonb_build_object('ok', false, 'error', 'action_refused',
      'id', p_id,
      'message', coalesce(nullif(v_res->>'message',''), public._c('exc.action.failed')),
      'result', v_res);
  end if;

  perform public.exceptions_start(p_id);

  return jsonb_build_object('ok', true, 'id', p_id,
    'message', public._c('exc.action.done'),
    'status', 'working',
    'status_label', public._c('exc.status.working'),
    'result', v_res);
end $function$;

-- ── 12. Closing records the outcome — and feeds the scorecards ──────────────
create or replace function public.exceptions_close(
  p_id text, p_outcome_code text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  w        record;
  o        public.exception_outcome%rowtype;
  v_actor  text := coalesce(public.my_admin_id()::text, auth.uid()::text);
  v_subj_k text;
  v_subj_v text;
begin
  -- _exception_writable returns a refusal ROW when the caller may not write, and
  -- NO row when the id is not (or is no longer) a live exception. Those are
  -- different sentences and the console prints whichever is true.
  select * into w from public._exception_writable(p_id);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public._c('exc.not_found'));
  end if;
  if coalesce(w.refusal,'') <> '' then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'message', w.refusal);
  end if;

  select * into o from public.exception_outcome
   where outcome_code = p_outcome_code and enabled
     and (applies_to = 'all' or applies_to = w.reason_code);
  if not found then
    return jsonb_build_object('ok', false, 'error', 'bad_outcome',
      'message', public._c('exc.close.pick'));
  end if;

  if exists (select 1 from public.exception_state s
              where s.id = p_id and s.status = 'closed') then
    return jsonb_build_object('ok', false, 'error', 'already_closed',
      'message', public._c('exc.close.gone'));
  end if;

  insert into public.exception_state
    (id, reason_code, ref_id, status, zone_id, outcome_code, note, closed_at, closed_by)
  values (p_id, w.reason_code, w.ref_id, 'closed', w.zone_id,
          o.outcome_code, nullif(btrim(coalesce(p_note,'')),''), now(), v_actor)
  on conflict (id) do update
    set status       = 'closed',
        outcome_code = excluded.outcome_code,
        note         = excluded.note,
        closed_at    = now(),
        closed_by    = v_actor,
        updated_at   = now();

  -- The outcome is an INPUT to a scorecard, never a silent edit of one.
  if o.affects = 'supplier' then
    v_subj_k := 'supplier'; v_subj_v := nullif(btrim(coalesce(w.supplier_key,'')), '');
  elsif o.affects = 'partner' then
    v_subj_k := 'partner';
    v_subj_v := (select rp.id::text from public.region_partners rp
                  where rp.zone_id = w.zone_id and coalesce(rp.is_active, true)
                  order by rp.id limit 1);
  end if;

  if v_subj_k is not null and v_subj_v is not null then
    insert into public.exception_scorecard_input
      (subject_kind, subject_key, reason_code, outcome_code, weight,
       exception_id, zone_id, closed_by)
    values (v_subj_k, v_subj_v, w.reason_code, o.outcome_code, o.weight,
            p_id, w.zone_id, v_actor);
  end if;

  return jsonb_build_object('ok', true, 'id', p_id,
    'status', 'closed',
    'status_label', public._c('exc.status.closed'),
    'outcome_code', o.outcome_code,
    'outcome_label', public._c('exc.outcome.' || o.outcome_code),
    'scored', (v_subj_k is not null and v_subj_v is not null),
    'message', public._c('exc.close.done'));
end $function$;

-- What the outcomes add up to per supplier / partner. This is the read side of
-- the scorecard feed; SPN itself is still admin-chosen and untouched.
create or replace function public.exception_scorecard_inputs(
  p_subject_kind text, p_subject_key text, p_days int default 90)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- Admin surface only: this is another party's outcome history.
  select case when coalesce(public.get_my_role(),'none') not in ('admin','super_admin')
              then jsonb_build_object('ok', false, 'error', 'not_authorized',
                     'message', public._c('exc.not_authorized'))
  else jsonb_build_object(
    'ok', true,
    'subject_kind', p_subject_kind,
    'subject_key',  p_subject_key,
    'days',         greatest(coalesce(p_days,90), 1),
    'total_weight', coalesce(sum(i.weight), 0),
    'count',        count(*)::int,
    'by_reason', coalesce((
      select jsonb_agg(jsonb_build_object(
               'reason_code', g.reason_code,
               'label',       public._c('exc.reason.' || g.reason_code),
               'count',       g.n,
               'weight',      g.w) order by g.n desc)
        from (select i2.reason_code, count(*)::int n, sum(i2.weight) w
                from public.exception_scorecard_input i2
               where i2.subject_kind = p_subject_kind
                 and i2.subject_key  = p_subject_key
                 and i2.closed_at >= now() - make_interval(days => greatest(coalesce(p_days,90),1))
               group by i2.reason_code) g), '[]'::jsonb)) end
    from public.exception_scorecard_input i
   where i.subject_kind = p_subject_kind
     and i.subject_key  = p_subject_key
     and i.closed_at >= now() - make_interval(days => greatest(coalesce(p_days,90),1))
$function$;

-- ── 13. The Fulfill badge ───────────────────────────────────────────────────
-- fulfill_stage_counts() with one branch added; the rest is byte-for-byte the
-- function that was live at CHANGE #1002.
CREATE OR REPLACE FUNCTION public.fulfill_stage_counts(p_stages text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v      jsonb := '{}'::jsonb;
  v_arr  jsonb;
  n      integer;
begin
  if p_stages is null or cardinality(p_stages) = 0 then
    return v;
  end if;

  if ('supplier_shop' = any (p_stages)) or ('warehouse' = any (p_stages)) then
    begin v_arr := public.fw_list_arrivals(); exception when others then v_arr := null; end;
    if 'supplier_shop' = any (p_stages) then
      v := v || jsonb_build_object('supplier_shop', coalesce((v_arr->>'count')::int, 0));
    end if;
    if 'warehouse' = any (p_stages) then
      v := v || jsonb_build_object('warehouse', coalesce((v_arr->>'warehouse_count')::int, 0));
    end if;
  end if;

  if 'customer_order' = any (p_stages) then
    begin n := coalesce((public.admin_customer_orders()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('customer_order', coalesce(n, 0));
  end if;

  if 'supplier_inquiry' = any (p_stages) then
    begin select count(*) into n from public.get_supplier_inquiry_overview();
    exception when others then n := 0; end;
    v := v || jsonb_build_object('supplier_inquiry', coalesce(n, 0));
  end if;

  if 'supplier_order' = any (p_stages) then
    begin n := coalesce((public.admin_supplier_orders()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('supplier_order', coalesce(n, 0));
  end if;

  if 'bag' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.fw_list_bags()->'bags', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('bag', coalesce(n, 0));
  end if;

  if 'pack' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.pack_list_orders()->'orders', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('pack', coalesce(n, 0));
  end if;

  if 'delivery' = any (p_stages) then
    begin n := jsonb_array_length(coalesce(public.admin_delivery_queue()->'orders', '[]'::jsonb));
    exception when others then n := 0; end;
    v := v || jsonb_build_object('delivery', coalesce(n, 0));
  end if;

  if 'dispute' = any (p_stages) then
    begin
      select count(*) into n
        from jsonb_array_elements(
               coalesce(public.fw_get_disputes()->'disputes', '[]'::jsonb)) d
       where (d->>'is_active')::boolean is true;
    exception when others then n := 0; end;
    v := v || jsonb_build_object('dispute', coalesce(n, 0));
  end if;

  -- CHANGE #690 — the exceptions badge is the console's own count, so the tab
  -- and the screen can never disagree about how much is stuck.
  if 'exceptions' = any (p_stages) then
    begin n := coalesce((public.exceptions_queue()->>'count')::int, 0);
    exception when others then n := 0; end;
    v := v || jsonb_build_object('exceptions', coalesce(n, 0));
  end if;

  return v;
end
$function$

;

-- ── 14. The nightly line, on the digest that already exists ─────────────────
-- No second cron job and no second message: cron_task 'partner-daily-digest'
-- (CHANGE #398, 20:35 IST) already reaches every active partner in their zone.
-- This is the sentence it now carries. It reads the sources directly rather
-- than exceptions_queue(), because the dispatcher runs with no auth.uid().
create or replace function public.exception_digest_line(p_zone smallint)
returns text
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_n int; v_oldest text;
begin
  if p_zone is null then return ''; end if;

  select count(*)::int,
         (array_agg(z.title order by z.sort_score desc, z.since asc))[1]
    into v_n, v_oldest
    from (
      select r.title,
             r.since,
             (extract(epoch from (now() - r.since)) / 3600.0) * x.severity as sort_score
        from public._exception_rows() r
        join public.exception_reason x
          on x.reason_code = r.reason_code and x.enabled
        left join public.exception_state s
          on s.reason_code = r.reason_code and s.ref_id = r.ref_id
       where r.zone_id = p_zone
         and coalesce(s.status, 'open') <> 'closed'
    ) z;

  if coalesce(v_n, 0) = 0 then
    return public._c('exc.digest.none');
  elsif v_n = 1 then
    return public._cf('exc.digest.one',
             jsonb_build_object('oldest', coalesce(v_oldest, '')));
  end if;

  return public._cf('exc.digest.line', jsonb_build_object(
           'n', v_n::text, 'oldest', coalesce(v_oldest, '')));
end $function$;

CREATE OR REPLACE FUNCTION public.partner_daily_digest(p_date date DEFAULT NULL::date, p_partner bigint DEFAULT NULL::bigint, p_force boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Kolkata')::date);
  v_copy jsonb := coalesce((select value from app_settings where key='partner_digest_copy'),'{}'::jsonb);
  rp record; d jsonb; v_body text; v_res jsonb; v_exc text;
  v_sent int := 0; v_skipped int := 0; v_out jsonb := '[]'::jsonb;
begin
  for rp in
    select r.id, r.zone_id from region_partners r
     where coalesce(r.is_active,true)
       and (p_partner is null or r.id = p_partner)
       and r.zone_id is not null
     order by r.id
  loop
    if not p_force and exists (select 1 from partner_digest_log l
                                where l.partner_id = rp.id and l.digest_date = v_date) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    d := public.partner_digest_data(rp.id, v_date);

    if coalesce((d->>'has_any')::boolean,false) then
      v_body := public.notif_render(coalesce(v_copy->>'line',''), jsonb_build_object(
                  'received',  (d->>'orders_received'),
                  'delivered', (d->>'orders_delivered'),
                  'collected', (d->>'collected_display')))
                || E'\n'
                || case when coalesce((d->>'has_share')::boolean,false)
                        then public.notif_render(coalesce(v_copy->>'share',''),
                               jsonb_build_object('share', d->>'share_display'))
                        else coalesce(v_copy->>'share_pending','') end;
    else
      v_body := coalesce(v_copy->>'empty','');
    end if;

    -- CHANGE #690 — the same evening message now carries the zone's open
    -- exceptions, so a partner learns what is stuck without opening the app.
    v_exc := public.exception_digest_line(rp.zone_id::smallint);
    if coalesce(v_exc,'') <> '' then
      v_body := v_body || E'\n' || v_exc;
    end if;

    begin
      v_res := public.notify_partner('partner_daily_digest', jsonb_build_object(
                 'partner_id', rp.id::text,
                 'zone_id',    coalesce(rp.zone_id,0)::text,
                 'zone',       coalesce(d->>'zone_label',''),
                 'received',   (d->>'orders_received'),
                 'delivered',  (d->>'orders_delivered'),
                 'collected',  (d->>'collected_display'),
                 'share',      case when coalesce((d->>'has_share')::boolean,false)
                                    then (d->>'share_display')
                                    else coalesce(v_copy->>'share_pending','') end,
                 'exceptions', coalesce(v_exc,''),
                 'summary',    v_body));
    exception when others then
      v_res := jsonb_build_object('ok', false, 'reason','send_exception', 'message', sqlerrm);
    end;

    insert into partner_digest_log
      (partner_id, zone_id, digest_date, orders_received, orders_delivered,
       collected, partner_share, body, send_result)
    values (rp.id, rp.zone_id, v_date,
            (d->>'orders_received')::int, (d->>'orders_delivered')::int,
            (d->>'collected')::numeric, (d->>'partner_share')::numeric,
            v_body, coalesce(v_res,'{}'::jsonb))
    on conflict (partner_id, digest_date) do update
      set orders_received = excluded.orders_received,
          orders_delivered = excluded.orders_delivered,
          collected = excluded.collected,
          partner_share = excluded.partner_share,
          body = excluded.body,
          send_result = excluded.send_result;

    v_sent := v_sent + 1;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
               'partner_id', rp.id, 'zone_id', rp.zone_id,
               'body', v_body, 'send', v_res));
  end loop;

  return jsonb_build_object('ok', true, 'the_date', v_date,
    'sent', v_sent, 'skipped_already_sent', v_skipped, 'digests', v_out);
end $function$

;

-- ── 15. The register row this command closes ────────────────────────────────
update public.feature_gaps
   set status = 'done',
       dev_command_id = 690,
       notes = 'CHANGE #690 — exceptions_queue()/exceptions_close() unify seven '
            || 'sources (disputes, unfulfillable items, count variances, blocked '
            || 'WhatsApp sends, overdue stock follow-ups, unverified payment '
            || 'claims, ops-board SLA breaches) into one aged, owned queue with a '
            || 'reason code, a next action and a recorded outcome. Fulfill tab '
            || '"Exceptions" (badge from fulfill_stage_counts); the 20:35 IST '
            || 'partner digest carries the zone''s open count.',
       updated_at = now()
 where id = 74;

-- ── 16. The door ────────────────────────────────────────────────────────────
-- Postgres grants EXECUTE to PUBLIC by default, and PostgREST exposes every
-- function in this schema — so a SECURITY DEFINER helper with no auth check of
-- its own is an anonymous read of every stuck object in the business. Mirror
-- admin_ops_board(): PUBLIC and anon lose EXECUTE on all of them; the two
-- internal helpers are owner-only (their callers are definers and run as the
-- owner already); the four console RPCs keep `authenticated`, where their own
-- role/zone checks live.
revoke execute on function public._exception_rows()                       from public, anon, authenticated;
revoke execute on function public._exception_writable(text)               from public, anon, authenticated;
revoke execute on function public.exception_digest_line(smallint)         from public, anon, authenticated;
revoke execute on function public.exceptions_queue(smallint, text, text, integer) from public, anon;
revoke execute on function public.exceptions_start(text)                  from public, anon;
revoke execute on function public.exceptions_action(text)                 from public, anon;
revoke execute on function public.exceptions_close(text, text, text)      from public, anon;
revoke execute on function public.exception_scorecard_inputs(text, text, integer) from public, anon;

grant execute on function public.exceptions_queue(smallint, text, text, integer) to authenticated, service_role;
grant execute on function public.exceptions_start(text)                   to authenticated, service_role;
grant execute on function public.exceptions_action(text)                  to authenticated, service_role;
grant execute on function public.exceptions_close(text, text, text)       to authenticated, service_role;
grant execute on function public.exception_scorecard_inputs(text, text, integer) to authenticated, service_role;
grant execute on function public._exception_rows()                        to service_role;
grant execute on function public._exception_writable(text)                to service_role;
grant execute on function public.exception_digest_line(smallint)          to service_role;

-- ── 17. The action must actually go somewhere ───────────────────────────────
-- ops_board_class.action_route names an ops-board destination, and four of
-- those names ('orders', 'inquiry', 'bills', 'payments') are not routes the
-- shell can open — the dashboard tile has always landed on "that screen is not
-- available". A console whose next action does nothing is worse than no
-- action, so sla_breach translates the class to a route the shell really
-- serves. It is DATA: a new class is one INSERT, never a deploy.
create table if not exists public.exception_route_map (
  class_key text primary key,
  route     text not null,
  note      text
);

insert into public.exception_route_map (class_key, route, note) values
  ('orders_open',         'customer_order',  'Fulfill stage 1 — the customer order itself'),
  ('supplier_unsettled',  'supplier_order',  'Fulfill stage 3 — the supplier order'),
  ('inquiry_pending',     'supplier_inquiry','Fulfill stage 2 — the waterfall'),
  ('bills_pending',       'bill_pipeline',   'Bill pipeline'),
  ('bill_scan_error',     'bill_pipeline',   'Bill pipeline — re-run the scan'),
  ('catalog_barcode_gap', 'add_medicine',    'Add medicine — attach the code to its product')
on conflict (class_key) do update
  set route = excluded.route, note = excluded.note;

-- Payment claims are verified on the Money screen's "To verify" tab (#450),
-- which is a route the shell opens; 'payments' is not.
update public.exception_reason set action_route = 'money'
 where reason_code = 'payment_claim_stuck';
