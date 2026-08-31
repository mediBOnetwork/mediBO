-- CHANGE — feature_gaps #58 (admin / Ops overview, critical).
--
-- THE GAP. Nothing anywhere answers "what is stuck right now". Stalled work sat
-- in seven tables with no shared surface and, crucially, NO AGE: orders open
-- 42 days, supplier orders unsettled 42 days, 46 inquiries at Confirmation
-- Pending with no clock at all, bills 89 days old, payment claims 42 days old,
-- stock follow-ups 20 days overdue. admin_dashboard_counts() returns six
-- numbers and not one of them is a duration, so nothing on the admin home could
-- ever get WORSE by sitting there — which is the only property that matters.
--
-- THE FIX. One admin_ops_board() RPC: every stuck object as a class with a
-- stage, an age, an owner and ONE action, ordered worst-first by how far past
-- its own SLA it is. Wording, owner, action, SLA hours and ordering live in
-- ops_board_class, so a re-word or a threshold change is one UPDATE and no
-- deploy.
--
-- Idempotent throughout.

-- ── #58's own evidence: "46 inquiries at Confirmation Pending with no clock" ─
-- inquiry.asked_at is NULL on every pending row, so an inquiry literally cannot
-- age. Give the table a clock and backfill it from the day log, which does
-- carry the date the product was first asked about.
alter table public.inquiry add column if not exists created_at timestamptz not null default now();

update public.inquiry i
   set created_at = d.first_asked
  from (select product_id, min(asked_at) first_asked
          from public.inquiry_day_log
         where asked_at is not null
         group by product_id) d
 where d.product_id = i.product_id
   and d.first_asked is not null
   and i.created_at > d.first_asked;

-- ── The board's vocabulary: one row per class of stuck work ─────────────────
create table if not exists public.ops_board_class (
  key          text primary key,
  title        text        not null,
  stage_label  text        not null,   -- where in the journey it is stuck
  owner_label  text        not null,   -- whose move it is
  action_label text        not null,   -- the ONE thing to do
  action_route text,                   -- quick-nav key, null = no jump
  unit_one     text        not null,
  unit_many    text        not null,
  sla_hours    numeric     not null default 24,
  rank         int         not null default 50,
  enabled      boolean     not null default true,
  updated_at   timestamptz not null default now()
);

alter table public.ops_board_class enable row level security;
drop policy if exists ops_board_class_admin_all on public.ops_board_class;
create policy ops_board_class_admin_all on public.ops_board_class
  for all to authenticated
  using (public.get_my_role() = any (array['admin','super_admin']))
  with check (public.get_my_role() = any (array['admin','super_admin']));

insert into public.ops_board_class
  (key, title, stage_label, owner_label, action_label, action_route, unit_one, unit_many, sla_hours, rank)
values
  ('orders_open', 'Orders never closed', 'Order open', 'Admin',
   'Close or cancel the order', 'orders', 'order', 'orders', 72, 90),
  ('supplier_unsettled', 'Supplier orders not settled', 'Supplier order placed', 'Admin',
   'Settle the supplier order', 'suppliers', 'supplier order', 'supplier orders', 72, 85),
  ('inquiry_pending', 'Inquiries waiting on a supplier answer', 'Confirmation Pending', 'Supplier',
   'Re-ask or mark it unavailable', 'inquiry', 'inquiry', 'inquiries', 24, 80),
  ('bills_pending', 'Supplier bills not imported', 'Bill received', 'Admin',
   'Review and import the bill', 'bills', 'bill', 'bills', 48, 75),
  ('bill_scan_error', 'Bill scans that errored', 'Scan failed', 'Admin',
   'Re-run the scan or enter the bill by hand', 'bills', 'scan', 'scans', 24, 70),
  ('claims_unverified', 'Payment claims not verified', 'Payment claimed', 'Admin',
   'Verify the UTR against the bank', 'payments', 'claim', 'claims', 24, 88),
  ('stock_followup_overdue', 'Stock follow-ups overdue', 'Follow-up due', 'Supplier',
   'Send the stock-update form again', 'suppliers', 'follow-up', 'follow-ups', 24, 60),
  ('wa_send_blocked', 'WhatsApp sends being refused', 'Send refused', 'Admin',
   'Open WhatsApp Ops and clear the block', 'wa_ops', 'send', 'sends', 6, 95)
on conflict (key) do update set
  title        = excluded.title,
  stage_label  = excluded.stage_label,
  owner_label  = excluded.owner_label,
  action_label = excluded.action_label,
  action_route = excluded.action_route,
  unit_one     = excluded.unit_one,
  unit_many    = excluded.unit_many,
  sla_hours    = excluded.sla_hours,
  rank         = excluded.rank,
  updated_at   = now();

-- ── Age, said in words, once, in one place ──────────────────────────────────
create or replace function public.ops_age_label(p_ts timestamptz)
returns text
language sql
immutable
as $function$
  select case
    when p_ts is null then 'no clock'
    else (
      with s as (select greatest(extract(epoch from (now() - p_ts)), 0) sec)
      select case
        when sec < 3600    then greatest(floor(sec/60)::int,1) || ' min'
        when sec < 172800  then floor(sec/3600)::int || case when floor(sec/3600)::int = 1 then ' hour' else ' hours' end
        else floor(sec/86400)::int || case when floor(sec/86400)::int = 1 then ' day' else ' days' end
      end from s
    )
  end
$function$;

-- ── The board ───────────────────────────────────────────────────────────────
--
-- Worst-first means "furthest past its OWN sla", not "biggest number" and not
-- "oldest in absolute days": six payment claims a day past a 24-hour SLA are a
-- worse problem than thirteen bills a day past a 48-hour one, and the board has
-- to say so without an admin doing the division.
create or replace function public.admin_ops_board(p_top int default 3)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_top    int := least(greatest(coalesce(p_top,3),1), 10);
  v_rows   jsonb;
  v_total  int;
  v_over   int;
  v_worst  text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', 'Not authorised', 'items', '[]'::jsonb);
  end if;

  with items as (
    -- Every source answers the same four questions: which class, which object,
    -- what to call it, and since when. Nothing else belongs in here.
    select 'orders_open'::text class_key, o.id::text item_id,
           coalesce(nullif(o.order_code,''), 'Order ' || left(o.id::text,8)) item_label,
           coalesce(nullif(o.pharmacy_name,''), '—') item_sub,
           o.created_at since
      from public.orders o
     where o.closed_at is null

    union all
    select 'supplier_unsettled', so.id::text,
           coalesce(nullif(so.order_code,''), 'SO ' || left(so.id::text,8)),
           coalesce(nullif(so.supplier_name,''), '—'),
           so.created_at
      from public.supplier_orders so
     where so.settled_at is null

    union all
    select 'inquiry_pending', i.id::text,
           coalesce(nullif(i.product_name,''), 'Inquiry ' || i.id::text),
           coalesce(nullif(i.current_status,''), '—'),
           coalesce(i.asked_at, i.created_at)
      from public.inquiry i
     where i.current_status = 'Confirmation Pending'

    union all
    select 'bills_pending', pb.id::text,
           coalesce(nullif(pb.file_name,''), 'Bill ' || left(pb.id::text,8)),
           coalesce(nullif(pb.supplier_name,''), '—'),
           coalesce(pb.received_at, pb.created_at)
      from public.pending_bills pb
     where pb.status = 'pending'

    union all
    select 'bill_scan_error', pb.id::text,
           coalesce(nullif(pb.file_name,''), 'Scan ' || left(pb.id::text,8)),
           coalesce(nullif(pb.supplier_name,''), '—'),
           coalesce(pb.received_at, pb.created_at)
      from public.pending_bills pb
     where pb.scan_status = 'error'

    union all
    select 'claims_unverified', pc.id::text,
           coalesce(nullif(pc.utr,''), 'Claim ' || left(pc.id::text,8)),
           coalesce(nullif(pc.payee_name,''), coalesce(nullif(pc.sender_phone,''),'—')),
           coalesce(pc.paid_ts, pc.received_at, pc.created_at)
      from public.payment_claims pc
     where coalesce(pc.status,'') not in ('verified','rejected')

    union all
    select 'stock_followup_overdue', q.id::text,
           coalesce(nullif(m.product_name,''), 'Product ' || q.product_id::text),
           coalesce(nullif(q.supplier_name,''), '—'),
           q.due_at
      from public.stock_update_queue q
      left join "MEDICINE" m on m.id = q.product_id
     where q.resolved_at is null and q.due_at < now()

    union all
    -- #42's blocking send failures land here too, so the board is the ONE place
    -- that answers the question rather than the eighth place to check.
    select 'wa_send_blocked', a.id::text,
           a.reason,
           coalesce(nullif(a.event_key,''), '—'),
           a.created_at
      from public.wa_send_attempts a
     where a.ok = false
       and a.created_at >= now() - interval '7 days'
       and coalesce(a.phone,'') not like '9000000%'
       and exists (select 1 from public.wa_send_fault_rule f
                    where f.enabled and f.is_blocking
                      and ((f.match_kind = 'exact' and a.reason = f.match_text)
                        or (f.match_kind = 'ilike' and a.reason ilike f.match_text)))
  ),
  scoped as (
    select i.*, c.title, c.stage_label, c.owner_label, c.action_label,
           c.action_route, c.unit_one, c.unit_many, c.sla_hours, c.rank,
           extract(epoch from (now() - i.since)) / 3600.0 as age_hours
      from items i
      join public.ops_board_class c on c.key = i.class_key and c.enabled
  ),
  agg as (
    select class_key, title, stage_label, owner_label, action_label, action_route,
           unit_one, unit_many, sla_hours, rank,
           count(*)::int n,
           count(*) filter (where age_hours > sla_hours)::int n_over,
           max(age_hours) max_age_hours,
           min(since) oldest_since
      from scoped
     group by 1,2,3,4,5,6,7,8,9,10
  ),
  topn as (
    select s.class_key,
           jsonb_agg(jsonb_build_object(
             'id',         s.item_id,
             'label',      s.item_label,
             'sub_label',  s.item_sub,
             'age_label',  public.ops_age_label(s.since),
             'over_sla',   s.age_hours > s.sla_hours
           ) order by s.since) as sample
      from (select *, row_number() over (partition by class_key order by since) rn
              from scoped) s
     where s.rn <= v_top
     group by s.class_key
  )
  select jsonb_agg(jsonb_build_object(
           'key',           a.class_key,
           'title',         a.title,
           'stage_label',   a.stage_label,
           'owner_label',   'Waiting on: ' || a.owner_label,
           'action_label',  a.action_label,
           'action_route',  a.action_route,
           'count',         a.n,
           'count_label',   a.n || ' ' || case when a.n = 1 then a.unit_one else a.unit_many end,
           'age_label',     'oldest ' || public.ops_age_label(a.oldest_since),
           'oldest_label',  public.ops_age_label(a.oldest_since),
           'over_sla',      a.n_over,
           'over_sla_label',case when a.n_over = 0
                                 then 'all within ' || round(a.sla_hours)::int || 'h'
                                 else a.n_over || ' past ' || round(a.sla_hours)::int || 'h' end,
           'tone',          case when a.max_age_hours > a.sla_hours * 3 then 'bad'
                                 when a.max_age_hours > a.sla_hours     then 'warn'
                                 else 'good' end,
           'breach_ratio',  round((a.max_age_hours / nullif(a.sla_hours,0))::numeric, 2),
           'items',         coalesce(t.sample, '[]'::jsonb)
         ) order by (a.max_age_hours / nullif(a.sla_hours,0)) desc nulls last, a.rank desc)
    into v_rows
    from agg a
    left join topn t on t.class_key = a.class_key;

  select coalesce(sum((r->>'count')::int),0),
         coalesce(sum((r->>'over_sla')::int),0),
         (select r2->>'title' from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) r2 limit 1)
    into v_total, v_over, v_worst
    from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) r;

  return jsonb_build_object(
    'ok', true,
    'title', 'What is stuck right now',
    'subtitle', case when coalesce(v_total,0) = 0
                     then 'Nothing is waiting past its deadline.'
                     else v_total || ' items waiting, ' || v_over || ' past their deadline' end,
    'headline_count', coalesce(v_total,0),
    'over_sla_count', coalesce(v_over,0),
    'headline_label', case when coalesce(v_total,0) = 0 then 'All clear'
                           else coalesce(v_over,0) || ' overdue' end,
    'headline_tone', case when coalesce(v_over,0) = 0 then 'good'
                          when coalesce(v_over,0) < 10 then 'warn' else 'bad' end,
    'worst_label', case when v_worst is null then '' else 'Worst: ' || v_worst end,
    'empty_label', 'Nothing is stuck. Every queue is inside its deadline.',
    'checked_label', 'Read ' || to_char(now() at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
    'items', coalesce(v_rows, '[]'::jsonb),
    'note', 'Worst-first is measured against each queue''s own deadline, not raw age — a claim one day past a 24-hour deadline outranks a bill one day past a 48-hour one.'
  );
end
$function$;

revoke all on function public.admin_ops_board(int) from public;
grant execute on function public.admin_ops_board(int) to authenticated, service_role;
grant execute on function public.ops_age_label(timestamptz) to authenticated, service_role;
