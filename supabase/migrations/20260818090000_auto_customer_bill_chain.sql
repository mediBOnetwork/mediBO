-- CHANGE #226 — Auto-generate and WhatsApp the customer bill the moment every
-- supplier bill for that order is imported.
--
-- The chain, end to end, with no human step anywhere:
--   bill line becomes verified  -> trg_bill_line_auto_allocate -> bill_line_allocate()
--   -> _bill_ready(order)       -> bill_job_enqueue(order)   (exactly once, ever)
--   -> bill_jobs_tick() cron    -> edge fn `bill-render`     (PDF -> storage)
--   -> bill_job_report()        -> orders.cust_bill_path set
--   -> _bill_job_send_wa()      -> bill PDF on WhatsApp + payment QR for the balance
--
-- Nothing here guesses a medicine. A scanned line auto-verifies ONLY on
-- certainty (see _bill_line_certain); anything less stays unverified and shows
-- up in the admin fix queue.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CONFIG — every threshold in this file is a row, not a constant.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.bill_auto_config (
  id                  int primary key default 1 check (id = 1),
  auto_verify_enabled boolean not null default true,
  auto_bill_enabled   boolean not null default true,
  auto_wa_enabled     boolean not null default true,
  chase_after_hours   int     not null default 6,
  chase_repeat_hours  int     not null default 12,
  max_attempts        int     not null default 5,
  backoff_base_s      int     not null default 60,
  stuck_minutes       int     not null default 10,
  -- PTR sanity: a real trade rate sits between these fractions of the MRP.
  ptr_min_ratio       numeric not null default 0.20,
  ptr_max_ratio       numeric not null default 1.00,
  -- Qty sanity: a supplier never bills more than this multiple of what we ordered.
  qty_max_multiple    numeric not null default 5,
  -- No order placed before the chain existed is auto-billed retroactively.
  start_from          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
insert into public.bill_auto_config (id) values (1) on conflict (id) do nothing;

-- Every string this feature renders. Wording changes are an UPDATE, not a deploy.
create table if not exists public.bill_pipeline_label (
  key   text primary key,
  label text not null
);

insert into public.bill_pipeline_label (key, label) values
  ('screen.title',            'Bill pipeline'),
  ('screen.subtitle',         'Every order from supplier bill to customer payment'),
  ('screen.empty',            'No order is waiting on a bill right now.'),
  ('screen.error',            'Could not load the bill pipeline.'),
  ('screen.retry',            'Retry'),
  ('tab.active',              'In progress'),
  ('tab.done',                'Billed'),
  ('tab.stuck',               'Needs attention'),
  ('step.lines.label',        'Lines verified'),
  ('step.lines.pending',      'Lines to verify'),
  ('step.lines.done',         'All lines verified'),
  ('step.items.label',        'Items covered'),
  ('step.items.pending',      'Items not billed yet'),
  ('step.items.done',         'Every item covered'),
  ('step.bill.label',         'Bill generated'),
  ('step.bill.pending',       'Waiting for every supplier bill'),
  ('step.bill.queued',        'Queued for generation'),
  ('step.bill.running',       'Generating'),
  ('step.bill.done',          'Bill generated'),
  ('step.bill.failed',        'Generation failed'),
  ('step.wa.label',           'WhatsApp sent'),
  ('step.wa.pending',         'Not sent yet'),
  ('step.wa.done',            'Bill + payment QR sent'),
  ('step.pay.label',          'Payment received'),
  ('step.pay.pending',        'Nothing received yet'),
  ('step.pay.partial',        'Part paid'),
  ('step.pay.done',           'Paid in full'),
  ('detail.unverified.title', 'Lines waiting to be verified'),
  ('detail.unverified.empty', 'No line is waiting.'),
  ('detail.uncovered.title',  'Items not covered by a supplier bill'),
  ('detail.uncovered.empty',  'Every item is covered.'),
  ('detail.job.title',        'Bill job'),
  ('detail.job.none',         'No bill job yet.'),
  ('detail.attempts',         'Attempt'),
  ('action.retry',            'Retry bill now'),
  ('action.enqueue',          'Generate bill now'),
  ('action.retry_done',       'Bill job queued'),
  ('action.blocked',          'The order is still waiting on a supplier bill'),
  ('chip.waiting',            'Waiting on'),
  ('chip.chased',             'Supplier reminded'),
  ('chip.no_supplier',        'No supplier assigned'),
  ('reason.name',             'Name does not match the catalogue exactly'),
  ('reason.pack',             'Pack does not match'),
  ('reason.company',          'Marketer does not match'),
  ('reason.ambiguous',        'Name matches more than one medicine'),
  ('reason.not_on_order',     'Not on an open order for this supplier'),
  ('reason.ptr',              'PTR fails the sanity check'),
  ('reason.qty',              'Qty is far above what we ordered'),
  ('reason.incomplete',       'Line is incomplete'),
  ('reason.off',              'Auto-verify is switched off')
on conflict (key) do update set label = excluded.label;

-- Neither table is client-readable: RLS on, no policy. Every reader is a
-- SECURITY DEFINER RPC.
alter table public.bill_auto_config   enable row level security;
alter table public.bill_pipeline_label enable row level security;

create or replace function public._bpl(p_key text)
returns text language sql stable as $$
  select coalesce((select label from public.bill_pipeline_label where key = p_key), p_key);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. AUTO-VERIFY — certainty only.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.bill_lines
  add column if not exists auto_verified   boolean not null default false,
  add column if not exists verify_rule     text,
  add column if not exists verify_blocked  text,
  add column if not exists raw_barcode     text,
  add column if not exists raw_pack        text,
  add column if not exists raw_company     text;

create or replace function public._bill_norm(p_text text)
returns text language sql immutable as $$
  select nullif(lower(regexp_replace(coalesce(p_text,''), '[^a-zA-Z0-9]', '', 'g')), '');
$$;

-- Pack strings arrive as "10 tablets" / "1*10" / "strip of 10" — compare the
-- digits only, which is the part that actually distinguishes two SKUs.
create or replace function public._bill_norm_pack(p_text text)
returns text language sql immutable as $$
  select nullif(trim_scale(max(t.v))::text, '')
  from (select (m)[1]::numeric as v
          from regexp_matches(coalesce(p_text,''), '([0-9]+(?:\.[0-9]+)?)', 'g') m) t;
$$;

-- Returns (ok, rule, blocked) for ONE line. `ok` true means: we are certain
-- which medicine this is, and the money on the line is sane.
create or replace function public._bill_line_certain(L public.bill_lines)
returns table (ok boolean, rule text, blocked text)
language plpgsql stable security definer set search_path to 'public' as $$
declare
  cfg public.bill_auto_config%rowtype;
  v_norm text; v_pack text; v_comp text;
  v_hits int; v_pid bigint;
  m public."MEDICINE"%rowtype;
  v_ordered numeric;
begin
  select * into cfg from public.bill_auto_config where id = 1;

  if not coalesce(cfg.auto_verify_enabled, true) then
    return query select false, null::text, public._bpl('reason.off'); return;
  end if;
  if L.needs_fix is not null then
    return query select false, null::text, public._bpl('reason.incomplete'); return;
  end if;

  v_norm := public._bill_norm(L.raw_name);
  v_pack := public._bill_norm_pack(L.raw_pack);
  v_comp := public._bill_norm(L.raw_company);

  -- RULE A — barcode. A barcode is an identity, not a guess.
  if nullif(btrim(coalesce(L.raw_barcode,'')),'') is not null then
    select count(*), min(id) into v_hits, v_pid
    from "MEDICINE" where btrim(coalesce(barcode,'')) = btrim(L.raw_barcode);
    if v_hits = 1 and v_pid = L.product_id then
      select * into m from "MEDICINE" where id = v_pid;
      rule := 'barcode';
    end if;
  end if;

  -- RULE B — exact name, exact pack, marketer when the bill printed one, and
  -- the name must resolve to EXACTLY ONE medicine in the whole catalogue.
  if rule is null then
    if v_norm is null then
      return query select false, null::text, public._bpl('reason.name'); return;
    end if;
    select count(*), min(id) into v_hits, v_pid
    from "MEDICINE" where public._bill_norm(product_name) = v_norm;

    if v_hits = 0 then
      return query select false, null::text, public._bpl('reason.name'); return;
    elsif v_hits > 1 then
      return query select false, null::text, public._bpl('reason.ambiguous'); return;
    elsif v_pid is distinct from L.product_id then
      return query select false, null::text, public._bpl('reason.name'); return;
    end if;

    select * into m from "MEDICINE" where id = v_pid;

    if v_pack is null
       or v_pack is distinct from coalesce(public._bill_norm_pack(m.pack_qty),
                                           public._bill_norm_pack(m.pack_size)) then
      return query select false, null::text, public._bpl('reason.pack'); return;
    end if;

    if v_comp is not null
       and v_comp is distinct from public._bill_norm(m.marketer)
       and v_comp is distinct from public._bill_norm(m.marketer_canonical) then
      return query select false, null::text, public._bpl('reason.company'); return;
    end if;

    rule := 'name_pack_marketer';
  end if;

  -- The medicine must be one this supplier actually owes us on an open order.
  select sum(oi.quantity) into v_ordered
  from order_items oi
  where oi.product_id = L.product_id
    and oi.assigned_supplier = L.supplier_name
    and oi.fulfillment_state not in ('shipped','cancelled');

  if coalesce(v_ordered,0) <= 0 then
    return query select false, rule, public._bpl('reason.not_on_order'); return;
  end if;

  -- Money sanity: PTR inside the configured band of the MRP.
  if coalesce(L.mrp,0) <= 0
     or coalesce(L.ptr,0) <= 0
     or L.ptr > L.mrp * cfg.ptr_max_ratio
     or L.ptr < L.mrp * cfg.ptr_min_ratio then
    return query select false, rule, public._bpl('reason.ptr'); return;
  end if;

  -- Qty sanity: never wildly more than we ordered.
  if coalesce(L.qty,0) <= 0 or L.qty > v_ordered * cfg.qty_max_multiple then
    return query select false, rule, public._bpl('reason.qty'); return;
  end if;

  return query select true, rule, null::text;
end $$;

create or replace function public.trg_bill_line_auto_verify()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v record;
begin
  -- A manual verification (bill_line_fix) always stands.
  if coalesce(NEW.verified, false) and not coalesce(NEW.auto_verified, false) then
    NEW.verify_blocked := null;
    return NEW;
  end if;

  select * into v from public._bill_line_certain(NEW);
  NEW.verify_rule    := v.rule;
  NEW.verify_blocked := v.blocked;
  if v.ok then
    NEW.verified      := true;
    NEW.auto_verified := true;
  end if;
  return NEW;
end $$;

drop trigger if exists trg_bill_line_auto_verify on public.bill_lines;
drop trigger if exists trg_bill_line_verify on public.bill_lines;
-- NAME MATTERS. Triggers on the same event fire in NAME order, and this one
-- must run AFTER trg_bill_line_check so needs_fix is already computed when
-- certainty is judged. 'trg_bill_line_verify' sorts after 'trg_bill_line_check';
-- 'trg_bill_line_auto_verify' sorted BEFORE it and judged a stale row.
create trigger trg_bill_line_verify
  before insert or update on public.bill_lines
  for each row execute function public.trg_bill_line_auto_verify();

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. AUTO-ALLOCATE + ENQUEUE
-- ─────────────────────────────────────────────────────────────────────────────

-- The customer_bill readiness gate, without the caller-facing auth check, so a
-- trigger or a cron can ask it. Same predicate as customer_bill().
create or replace function public._bill_ready(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_uncovered int; v_nosup int; v_sups text[]; v_billable int;
begin
  -- Nothing billable (every line cancelled, shipped or unfulfillable) is NOT
  -- "ready" — zero uncovered items would otherwise read as ready and render an
  -- invoice with no lines.
  select count(*) into v_billable
  from order_items oi
  where oi.order_id = p_order_id
    and oi.fulfillment_state not in ('shipped','cancelled')
    and coalesce(oi.unfulfillable,false) = false;

  select count(*),
         count(*) filter (where oi.assigned_supplier is null),
         coalesce(array_agg(distinct oi.assigned_supplier)
                    filter (where oi.assigned_supplier is not null), '{}')
    into v_uncovered, v_nosup, v_sups
  from order_items oi
  where oi.order_id = p_order_id
    and oi.fulfillment_state not in ('shipped','cancelled')
    and coalesce(oi.unfulfillable,false) = false
    and not exists (select 1 from bill_line_allocations a
                     join bill_lines b on b.id = a.bill_line_id
                    where a.order_item_id = oi.id and b.verified and b.needs_fix is null);

  return jsonb_build_object(
    'ready', coalesce(v_uncovered,0) = 0 and coalesce(v_billable,0) > 0,
    'billable', coalesce(v_billable,0),
    'uncovered', coalesce(v_uncovered,0),
    'items_without_supplier', coalesce(v_nosup,0),
    'waiting_suppliers', to_jsonb(coalesce(v_sups,'{}')));
end $$;

create table if not exists public.bill_jobs (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  idem_key      text not null unique,
  status        text not null default 'queued',   -- queued|running|rendered|done|dead|cancelled
  attempts      int  not null default 0,
  max_attempts  int  not null default 5,
  next_run_at   timestamptz not null default now(),
  started_at    timestamptz,
  last_error    text,
  bill_bucket   text,
  bill_path     text,
  bill_name     text,
  rendered_at   timestamptz,
  wa_bill_sent_at timestamptz,
  wa_qr_sent_at   timestamptz,
  wa_result     jsonb,
  amount_remaining numeric,
  done_at       timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists bill_jobs_due_idx on public.bill_jobs (status, next_run_at);
create index if not exists bill_jobs_order_idx on public.bill_jobs (order_id);
alter table public.bill_jobs enable row level security;

-- Exactly-once: the idempotency key is the order. One order, one customer bill.
create or replace function public.bill_job_enqueue(p_order_id uuid, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cfg public.bill_auto_config%rowtype; v_ready jsonb; v_id uuid; v_has_bill boolean;
begin
  select * into cfg from public.bill_auto_config where id = 1;
  if not coalesce(cfg.auto_bill_enabled, true) and not p_force then
    return jsonb_build_object('ok', false, 'reason', 'auto_bill_off');
  end if;

  if not p_force and not exists (
       select 1 from orders where id = p_order_id and created_at >= cfg.start_from) then
    return jsonb_build_object('ok', false, 'reason', 'before_start_from');
  end if;

  v_ready := public._bill_ready(p_order_id);
  if not (v_ready->>'ready')::boolean then
    return jsonb_build_object('ok', false, 'reason', 'not_ready') || v_ready;
  end if;

  select cust_bill_path is not null into v_has_bill from orders where id = p_order_id;
  if coalesce(v_has_bill,false) and not p_force then
    return jsonb_build_object('ok', false, 'reason', 'already_billed');
  end if;

  insert into public.bill_jobs (order_id, idem_key, max_attempts)
  values (p_order_id, 'order:' || p_order_id::text, coalesce(cfg.max_attempts,5))
  on conflict (idem_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- A job already exists. Only a forced retry may wake a dead one.
    if p_force then
      update public.bill_jobs
         set status = 'queued', attempts = 0, next_run_at = now(),
             last_error = null, updated_at = now()
       where order_id = p_order_id and status in ('dead','cancelled','queued','running')
       returning id into v_id;
    end if;
    return jsonb_build_object('ok', v_id is not null, 'reason',
      case when v_id is null then 'already_queued' else 'requeued' end, 'job_id', v_id);
  end if;

  return jsonb_build_object('ok', true, 'job_id', v_id);
end $$;

create or replace function public.trg_bill_line_auto_allocate()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  if not coalesce(NEW.verified,false) or NEW.needs_fix is not null then return NEW; end if;

  -- a re-save that touches nothing the allocation depends on is a no-op
  if TG_OP = 'UPDATE'
     and coalesce(OLD.verified,false)
     and OLD.needs_fix is null
     and OLD.product_id is not distinct from NEW.product_id
     and OLD.supplier_name is not distinct from NEW.supplier_name
     and OLD.qty is not distinct from NEW.qty
     and OLD.free_qty is not distinct from NEW.free_qty then
    return NEW;
  end if;

  perform public.bill_line_allocate(NEW.id);

  for r in select distinct order_id from public.bill_line_allocations
            where bill_line_id = NEW.id
  loop
    perform public.bill_job_enqueue(r.order_id);
  end loop;
  return NEW;
end $$;

drop trigger if exists trg_bill_line_auto_allocate on public.bill_lines;
create trigger trg_bill_line_auto_allocate
  after insert or update on public.bill_lines
  for each row execute function public.trg_bill_line_auto_allocate();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE WORKER — render, then WhatsApp.
-- ─────────────────────────────────────────────────────────────────────────────
-- The service JWT lives in the Vault, never in a migration file and never in a
-- log. Server-side only: revoked from every client role.
create or replace function public._service_key()
returns text language sql stable security definer set search_path to 'public' as $$
  select decrypted_secret from vault.decrypted_secrets where name = 'SERVICE_ROLE_KEY';
$$;
revoke all on function public._service_key() from public, anon, authenticated;

create or replace function public.bill_jobs_tick()
returns int language plpgsql security definer set search_path to 'public','net' as $$
declare cfg public.bill_auto_config%rowtype; r record; n int := 0;
begin
  select * into cfg from public.bill_auto_config where id = 1;
  if not coalesce(cfg.auto_bill_enabled, true) then return 0; end if;

  -- a render that never reported back is retried, not lost
  update public.bill_jobs
     set status = 'queued', updated_at = now(),
         last_error = coalesce(last_error, 'render timed out')
   where status = 'running'
     and started_at < now() - make_interval(mins => coalesce(cfg.stuck_minutes,10));

  -- safety net: an order can become ready without any bill line changing
  -- (an item is cancelled, or marked unfulfillable). Catch those too.
  for r in
    select o.id from orders o
     where o.cust_bill_path is null
       and o.status not in ('cancelled','rejected')
       and o.created_at > now() - interval '30 days'
       and not exists (select 1 from public.bill_jobs bj where bj.order_id = o.id)
       and exists (select 1 from order_items oi where oi.order_id = o.id
                     and oi.fulfillment_state not in ('shipped','cancelled')
                     and coalesce(oi.unfulfillable,false) = false)
     order by o.created_at desc
     limit 20
  loop
    perform public.bill_job_enqueue(r.id);
  end loop;

  for r in
    select * from public.bill_jobs
     where status = 'queued' and next_run_at <= now()
     order by created_at
     limit 5
     for update skip locked
  loop
    update public.bill_jobs
       set status = 'running', attempts = attempts + 1,
           started_at = now(), updated_at = now()
     where id = r.id;

    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
      -- bill-render is deployed with verify_jwt on, so it needs BOTH: the
      -- platform's JWT check and the function's own shared-secret check.
      headers := jsonb_build_object('Content-Type','application/json',
                                    'x-notify-secret','medibo_order_notify_2027',
                                    'Authorization','Bearer ' || public._service_key()),
      body    := jsonb_build_object('job_id', r.id, 'order_id', r.order_id),
      timeout_milliseconds := 20000);
    n := n + 1;
  end loop;
  return n;
end $$;

-- WhatsApp, server-side. The user-facing send_customer_bill_wa /
-- send_payment_qr_wa keep their own auth gates; these are the internal twins the
-- job runs as, and they are revoked from every client role below.
create or replace function public._send_customer_bill_wa_auto(p_order_id uuid, p_phone text)
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare v_ph10 text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10); v_req bigint;
begin
  if length(v_ph10) <> 10 then return jsonb_build_object('ok',false,'error','bad_phone'); end if;
  select net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027'),
    body    := jsonb_build_object('order_id', p_order_id, 'event','bill_to_customer','phone', v_ph10),
    timeout_milliseconds := 20000
  ) into v_req;
  return jsonb_build_object('ok',true,'phone',v_ph10,'req',v_req);
end $$;

create or replace function public._send_payment_qr_wa_auto(
  p_order_id uuid, p_phone text, p_amount numeric, p_kind text default 'remaining')
returns jsonb language plpgsql security definer set search_path to 'public','net' as $$
declare v_ph10 text := right(regexp_replace(coalesce(p_phone,''),'\D','','g'),10); v_req bigint;
begin
  if length(v_ph10) <> 10 then return jsonb_build_object('ok',false,'error','bad_phone'); end if;
  if coalesce(p_amount,0) <= 0 then return jsonb_build_object('ok',false,'error','nothing_due'); end if;
  select net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/send-payment-qr',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027'),
    body    := jsonb_build_object('order_id', p_order_id, 'phone', v_ph10,
                                  'amount', round(p_amount), 'kind', lower(coalesce(p_kind,'remaining'))),
    timeout_milliseconds := 20000
  ) into v_req;
  return jsonb_build_object('ok',true,'phone',v_ph10,'amount',round(p_amount),'req',v_req);
end $$;

create or replace function public._bill_job_send_wa(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  cfg public.bill_auto_config%rowtype;
  j public.bill_jobs%rowtype;
  v_phone text; v_bill jsonb; v_remaining numeric;
  v_r1 jsonb; v_r2 jsonb := jsonb_build_object('ok', false, 'error','nothing_due');
begin
  select * into cfg from public.bill_auto_config where id = 1;
  select * into j from public.bill_jobs where id = p_job_id;
  if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;

  if not coalesce(cfg.auto_wa_enabled, true) then
    update public.bill_jobs set status='done', done_at=now(), updated_at=now(),
           wa_result = jsonb_build_object('skipped','auto_wa_off') where id = p_job_id;
    return jsonb_build_object('ok', true, 'skipped','auto_wa_off');
  end if;

  -- The ranked WhatsApp numbers first; an order placed without a pharmacy
  -- profile still has its own phone, and that is better than never delivering.
  select coalesce(
           (select r.phone from public.cust_number_ranking(j.order_id) r limit 1),
           (select right(regexp_replace(coalesce(o.phone,''),'\D','','g'),10)
              from orders o where o.id = j.order_id))
    into v_phone;
  v_phone := nullif(v_phone, '');
  if v_phone is null then
    update public.bill_jobs set status='done', done_at=now(), updated_at=now(),
           last_error='no customer WhatsApp number',
           wa_result = jsonb_build_object('skipped','no_phone') where id = p_job_id;
    return jsonb_build_object('ok', false, 'error','no_phone');
  end if;

  v_r1 := public._send_customer_bill_wa_auto(j.order_id, v_phone);

  -- The balance comes from the bill itself — the one place money is computed.
  v_bill := public.customer_bill(j.order_id);
  v_remaining := nullif(v_bill->'totals'->>'remaining','')::numeric;
  if coalesce(v_remaining,0) > 0 then
    v_r2 := public._send_payment_qr_wa_auto(j.order_id, v_phone, v_remaining, 'remaining');
  end if;

  update public.bill_jobs
     set status = 'done', done_at = now(), updated_at = now(),
         amount_remaining = v_remaining,
         wa_bill_sent_at = case when (v_r1->>'ok')::boolean then now() end,
         wa_qr_sent_at   = case when (v_r2->>'ok')::boolean then now() end,
         wa_result = jsonb_build_object('bill', v_r1, 'qr', v_r2, 'phone', v_phone)
   where id = p_job_id;

  return jsonb_build_object('ok', true, 'bill', v_r1, 'qr', v_r2);
end $$;

-- The edge function's callback.
create or replace function public.bill_job_report(
  p_job_id uuid, p_ok boolean,
  p_bucket text default null, p_path text default null, p_name text default null,
  p_error text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cfg public.bill_auto_config%rowtype; j public.bill_jobs%rowtype; v_delay int;
begin
  select * into cfg from public.bill_auto_config where id = 1;
  select * into j from public.bill_jobs where id = p_job_id;
  if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
  if j.status in ('done','rendered') then
    return jsonb_build_object('ok',true,'skipped','already_done');   -- idempotent
  end if;

  if not coalesce(p_ok,false) then
    v_delay := coalesce(cfg.backoff_base_s,60) * power(2, greatest(j.attempts - 1, 0))::int;
    update public.bill_jobs
       set status = case when j.attempts >= j.max_attempts then 'dead' else 'queued' end,
           next_run_at = now() + make_interval(secs => v_delay),
           last_error = left(coalesce(p_error,'render failed'), 2000),
           updated_at = now()
     where id = p_job_id;
    return jsonb_build_object('ok', false, 'retry_in_s', v_delay,
      'status', case when j.attempts >= j.max_attempts then 'dead' else 'queued' end);
  end if;

  update orders
     set cust_bill_bucket = coalesce(nullif(p_bucket,''),'customer-bills'),
         cust_bill_path = p_path, cust_bill_name = p_name,
         cust_bill_uploaded_at = now(), cust_bill_uploaded_by = 'auto'
   where id = j.order_id;

  update public.bill_jobs
     set status='rendered', rendered_at = now(), updated_at = now(),
         bill_bucket = coalesce(nullif(p_bucket,''),'customer-bills'),
         bill_path = p_path, bill_name = p_name, last_error = null
   where id = p_job_id;

  return public._bill_job_send_wa(p_job_id) || jsonb_build_object('rendered', true);
end $$;

-- Everything the renderer needs, in one authenticated-by-secret call.
create or replace function public.bill_job_render_input(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare j public.bill_jobs%rowtype; v_code text;
begin
  select * into j from public.bill_jobs where id = p_job_id;
  if not found then return jsonb_build_object('ok',false,'error','job_not_found'); end if;
  select order_code into v_code from orders where id = j.order_id;
  return jsonb_build_object('ok', true, 'job_id', j.id, 'order_id', j.order_id,
    'order_code', coalesce(v_code,''), 'attempt', j.attempts,
    'bucket','customer-bills', 'bill', public.customer_bill(j.order_id));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. AUTO-CHASE — remind the supplier we are still waiting on their bill.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.bill_chase_log (
  id            bigserial primary key,
  order_id      uuid not null references public.orders(id) on delete cascade,
  supplier_name text not null,
  sent_at       timestamptz not null default now(),
  result        jsonb
);
create index if not exists bill_chase_log_pair_idx
  on public.bill_chase_log (order_id, supplier_name, sent_at desc);
alter table public.bill_chase_log enable row level security;

insert into public.wa_event_routes (event_key, label, description, audience, enabled)
values ('supplier_bill_pending', 'Supplier bill still pending',
        'Sent to a supplier when an order has been waiting on their bill past the configured hours.',
        'supplier', false)
on conflict (event_key) do nothing;

create or replace function public.bill_chase_tick()
returns int language plpgsql security definer set search_path to 'public' as $$
declare cfg public.bill_auto_config%rowtype; r record; n int := 0; v_res jsonb; v_phone text;
begin
  select * into cfg from public.bill_auto_config where id = 1;

  for r in
    select o.id as order_id, o.order_code, oi.assigned_supplier as supplier_name,
           count(*) as item_count
    from orders o
    join order_items oi on oi.order_id = o.id
    where o.cust_bill_path is null
      and o.status not in ('cancelled','rejected')
      and oi.assigned_supplier is not null
      and oi.fulfillment_state not in ('shipped','cancelled')
      and coalesce(oi.unfulfillable,false) = false
      and o.created_at < now() - make_interval(hours => coalesce(cfg.chase_after_hours,6))
      and not exists (select 1 from bill_line_allocations a
                       join bill_lines b on b.id = a.bill_line_id
                      where a.order_item_id = oi.id and b.verified and b.needs_fix is null)
      -- A chase that WENT OUT quiets this pair for chase_repeat_hours. A chase
      -- that could not go out (no template attached yet, no phone) only quiets
      -- it for an hour, so the first reminder lands soon after it becomes
      -- possible instead of half a day later.
      and not exists (select 1 from public.bill_chase_log cl
                      where cl.order_id = o.id
                        and cl.supplier_name = oi.assigned_supplier
                        and cl.sent_at > now() - case
                              when coalesce(cl.result->>'ok','false') = 'true'
                              then make_interval(hours => coalesce(cfg.chase_repeat_hours,12))
                              else interval '1 hour' end)
    group by o.id, o.order_code, oi.assigned_supplier
    limit 20
  loop
    v_phone := public.sup_pick_send_phone(r.supplier_name);
    v_res := public.wa_send_event(
      'supplier_bill_pending',
      p_tokens   := jsonb_build_object('supplier_name', r.supplier_name,
                                       'order_code', coalesce(r.order_code,''),
                                       'item_count', r.item_count::text),
      p_phone    := v_phone,
      p_order_id := r.order_id);

    insert into public.bill_chase_log (order_id, supplier_name, result)
    values (r.order_id, r.supplier_name,
            coalesce(v_res,'{}'::jsonb) || jsonb_build_object('phone', v_phone));
    n := n + 1;
  end loop;
  return n;
end $$;

-- Offset schedules — never a bare */N (the minute-0 pile-up took the site down).
select cron.schedule('bill-jobs-tick',  '2-59/2 * * * *',  $$select public.bill_jobs_tick()$$)
 where not exists (select 1 from cron.job where jobname = 'bill-jobs-tick');
select cron.schedule('bill-chase-tick', '27 */2 * * *',    $$select public.bill_chase_tick()$$)
 where not exists (select 1 from cron.job where jobname = 'bill-chase-tick');

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. ADMIN PIPELINE SCREEN — one RPC per surface, every label from the table.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_bill_pipeline_list(
  p_filter text default 'active', p_limit int default 50)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare cfg public.bill_auto_config%rowtype; v_rows jsonb; v_f text := lower(coalesce(p_filter,'active'));
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select * into cfg from public.bill_auto_config where id = 1;

  with base as (
    select o.id, o.order_code, o.pharmacy_name, o.created_at, o.cust_bill_path,
           coalesce(pp.pharmacy_name, o.pharmacy_name) as buyer,
           public._bill_ready(o.id) as ready,
           (select count(*) from bill_lines b
             where b.supplier_name in (select distinct oi2.assigned_supplier from order_items oi2
                                        where oi2.order_id = o.id and oi2.assigned_supplier is not null)
               and not b.verified) as unverified_sup,
           (select coalesce(sum(pc.amount),0) from payment_claims pc
             where pc.order_id = o.id and pc.status not in ('rejected','duplicate','need_details')) as paid,
           (select to_jsonb(bj) from bill_jobs bj where bj.order_id = o.id
             order by bj.created_at desc limit 1) as job,
           -- only a chase that ACTUALLY went out earns the chip
           (select max(cl.sent_at) from bill_chase_log cl
             where cl.order_id = o.id and coalesce(cl.result->>'ok','false') = 'true') as chased_at
    from orders o
    left join pharmacy_profiles pp on pp.user_id = o.user_id
    where o.status not in ('cancelled','rejected')
      and exists (select 1 from order_items oi where oi.order_id = o.id
                    and oi.fulfillment_state not in ('shipped','cancelled')
                    and coalesce(oi.unfulfillable,false) = false)
    order by o.created_at desc
    limit 200
  ), shaped as (
    select b.*,
           (b.ready->>'uncovered')::int as uncovered,
           (b.job->>'status') as job_status,
           case
             when (b.job->>'status') = 'dead' then 'stuck'
             when b.cust_bill_path is not null then 'done'
             else 'active'
           end as bucket
    from base b
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'order_id',      s.id,
    'order_code',    coalesce(s.order_code,''),
    'buyer_label',   coalesce(s.buyer,''),
    'placed_label',  to_char(s.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
    'stage_label',   case
                       when s.cust_bill_path is not null and s.paid > 0 then public._bpl('step.pay.label')
                       when s.cust_bill_path is not null then public._bpl('step.bill.done')
                       when s.job_status = 'dead' then public._bpl('step.bill.failed')
                       when s.job_status in ('queued','running','rendered') then public._bpl('step.bill.running')
                       when s.uncovered > 0 then public._bpl('step.items.pending')
                       else public._bpl('step.lines.pending')
                     end,
    'stage_tone',    case
                       when s.cust_bill_path is not null then 'success'
                       when s.job_status = 'dead' then 'danger'
                       when s.job_status is not null then 'info'
                       else 'warning'
                     end,
    'chips', (
      select coalesce(jsonb_agg(x.chip order by x.ord), '[]'::jsonb) from (
        select 1 as ord, jsonb_build_object(
                 'label', public._bpl('chip.waiting') || ' ' ||
                          array_to_string(array(select jsonb_array_elements_text(s.ready->'waiting_suppliers')), ', '),
                 'tone','warning') as chip
         where jsonb_array_length(s.ready->'waiting_suppliers') > 0 and s.uncovered > 0
        union all
        select 2, jsonb_build_object('label', public._bpl('chip.no_supplier'), 'tone','danger')
         where (s.ready->>'items_without_supplier')::int > 0
        union all
        select 3, jsonb_build_object('label', public._bpl('chip.chased'), 'tone','info')
         where s.chased_at is not null and s.cust_bill_path is null
        union all
        select 4, jsonb_build_object(
                 'label', public._bpl('step.lines.pending') || ' · ' || s.unverified_sup::text, 'tone','warning')
         where s.unverified_sup > 0
      ) x),
    'uncovered', s.uncovered,
    'unverified', s.unverified_sup,
    'has_bill', s.cust_bill_path is not null
  ) order by s.created_at desc), '[]'::jsonb)
    into v_rows
  from shaped s
  where (v_f = 'all') or (s.bucket = v_f);

  return jsonb_build_object(
    'ok', true,
    'title',    public._bpl('screen.title'),
    'subtitle', public._bpl('screen.subtitle'),
    'empty_label', public._bpl('screen.empty'),
    'retry_label', public._bpl('screen.retry'),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','active','label', public._bpl('tab.active')),
      jsonb_build_object('key','stuck', 'label', public._bpl('tab.stuck')),
      jsonb_build_object('key','done',  'label', public._bpl('tab.done'))),
    'selected_tab', v_f,
    'rows', (select coalesce(jsonb_agg(e), '[]'::jsonb)
               from (select e from jsonb_array_elements(v_rows) e limit greatest(coalesce(p_limit,50),1)) t),
    'count_label', jsonb_array_length(v_rows)::text
  );
end $$;

create or replace function public.admin_bill_pipeline(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  o orders%rowtype; j public.bill_jobs%rowtype; v_ready jsonb;
  v_unver jsonb; v_uncov jsonb; v_paid numeric; v_bill jsonb; v_steps jsonb;
  v_wait text;
begin
  if get_my_role() not in ('admin','super_admin') then
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
end $$;

create or replace function public.admin_bill_pipeline_action(p_order_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v jsonb;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  if lower(coalesce(p_action,'')) not in ('retry','enqueue') then
    return jsonb_build_object('ok', false, 'error','bad_action');
  end if;
  v := public.bill_job_enqueue(p_order_id, true);
  return v || jsonb_build_object('toast', case when (v->>'ok')::boolean
                                               then public._bpl('action.retry_done')
                                               else public._bpl('action.blocked') end);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. GRANTS — the worker internals are server-side only.
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on function public._bill_line_certain(public.bill_lines)      from public, anon, authenticated;
revoke all on function public._bill_job_send_wa(uuid)                    from public, anon, authenticated;
revoke all on function public._send_customer_bill_wa_auto(uuid,text)     from public, anon, authenticated;
revoke all on function public._send_payment_qr_wa_auto(uuid,text,numeric,text) from public, anon, authenticated;
revoke all on function public.bill_jobs_tick()                           from public, anon, authenticated;
-- bill_job_enqueue is NOT granted to clients: p_force skips every gate, so a
-- client grant would let any logged-in user force a bill + WhatsApp send on any
-- order. Admins reach it through admin_bill_pipeline_action, which is role-gated.
revoke all on function public.bill_job_enqueue(uuid,boolean)             from public, anon, authenticated;
revoke all on table public.bill_jobs, public.bill_auto_config,
                    public.bill_pipeline_label, public.bill_chase_log    from anon, authenticated;
revoke all on function public.bill_chase_tick()                          from public, anon, authenticated;
revoke all on function public.bill_job_report(uuid,boolean,text,text,text,text) from public, anon, authenticated;
revoke all on function public.bill_job_render_input(uuid)                from public, anon, authenticated;

grant execute on function public.admin_bill_pipeline_list(text,int)      to authenticated;
grant execute on function public.admin_bill_pipeline(uuid)               to authenticated;
grant execute on function public.admin_bill_pipeline_action(uuid,text)   to authenticated;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8. THE TWO EXISTING FUNCTIONS THIS CHAIN NEEDS CHANGED
-- ─────────────────────────────────────────────────────────────────────────────

-- (a) customer_bill() is now read by a cron job, a trigger and the renderer.
--     Its gate refused every one of them: with no PostgREST request there is no
--     JWT, so it fell through to `raise not_authorized`. Two trusted callers are
--     let through — a session with no HTTP request context at all (cron, trigger,
--     psql: already running as the database owner) and service_role (which
--     bypasses RLS anyway and can read `orders` directly). Every real client
--     path — anon, authenticated, customer, supplier — is untouched.
create or replace function public._assert_can_see_order(p_order_id uuid)
returns void language plpgsql stable security definer set search_path to 'public' as $function$
declare v_owner uuid; v_cust uuid; v_claims text;
begin
  v_claims := nullif(current_setting('request.jwt.claims', true), '');
  if v_claims is null then return; end if;                              -- cron / trigger / psql
  if (v_claims::jsonb ->> 'role') = 'service_role' then return; end if;  -- trusted backend

  select user_id, customer_id into v_owner, v_cust from orders where id = p_order_id;
  if not found then raise exception 'order_not_found'; end if;
  if get_my_role() in ('admin','super_admin') then return; end if;
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if v_cust is not null and v_cust = public.my_customer_id() then return; end if;
  if v_owner = any (public.my_owner_user_ids()) then return; end if;
  raise exception 'not_authorized';
end $function$;

-- (b) bill_lines_from_scan() now carries the three OCR fields auto-verification
--     judges on: the printed pack, the printed marketer, and a barcode when the
--     bill has one. Unchanged otherwise — the matching rules are identical.
CREATE OR REPLACE FUNCTION public.bill_lines_from_scan(p_bill_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  B pending_bills%ROWTYPE;
  it jsonb; v_name text; v_norm text;
  v_pid bigint; v_conf numeric; v_by text;
  v_n int := 0; v_ok int := 0; v_wide int := 0;
  v_sup text;
BEGIN
  SELECT * INTO B FROM pending_bills WHERE id = p_bill_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','bill_not_found'); END IF;
  v_sup := COALESCE(B.supplier_name, B.scan_result->>'matched_supplier_name');

  DELETE FROM bill_lines WHERE pending_bill_id = p_bill_id;

  FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(B.scan_result->'line_items','[]'::jsonb))
  LOOP
    v_name := btrim(COALESCE(it->>'name', it->>'product', ''));
    CONTINUE WHEN v_name = '';
    v_n := v_n + 1;
    v_norm := lower(regexp_replace(v_name,'[^a-zA-Z0-9]','','g'));
    v_pid := NULL; v_conf := NULL; v_by := NULL;

    -- 1) EXACT, scoped to what this supplier owes us on open orders
    SELECT oi.product_id, 1.0, 'ocr_scoped' INTO v_pid, v_conf, v_by
    FROM order_items oi
    JOIN "MEDICINE" m ON m.id = oi.product_id
    WHERE oi.assigned_supplier = v_sup
      AND oi.fulfillment_state NOT IN ('shipped','cancelled')
      AND lower(regexp_replace(m.product_name,'[^a-zA-Z0-9]','','g')) = v_norm
    LIMIT 1;

    -- 2) PREFIX, still scoped to this supplier
    IF v_pid IS NULL THEN
      SELECT oi.product_id, 0.85, 'ocr_scoped' INTO v_pid, v_conf, v_by
      FROM order_items oi
      JOIN "MEDICINE" m ON m.id = oi.product_id
      WHERE oi.assigned_supplier = v_sup
        AND oi.fulfillment_state NOT IN ('shipped','cancelled')
        AND (lower(regexp_replace(m.product_name,'[^a-zA-Z0-9]','','g')) LIKE v_norm || '%'
          OR v_norm LIKE lower(regexp_replace(m.product_name,'[^a-zA-Z0-9]','','g')) || '%')
      ORDER BY abs(length(m.product_name) - length(v_name))
      LIMIT 1;
    END IF;

    -- 3) LAST RESORT: whole catalogue. LOW confidence -> admin MUST confirm,
    --    because this is exactly where the wrong-SKU bug comes from.
    IF v_pid IS NULL THEN
      SELECT m.id, 0.4, 'ocr_catalogue' INTO v_pid, v_conf, v_by
      FROM "MEDICINE" m
      WHERE lower(regexp_replace(m.product_name,'[^a-zA-Z0-9]','','g')) = v_norm
      LIMIT 1;
      IF v_pid IS NOT NULL THEN v_wide := v_wide + 1; END IF;
    END IF;

    INSERT INTO bill_lines (
      pending_bill_id, supplier_name, raw_name, product_id, match_confidence, matched_by,
      batch_no, expiry, qty, free_qty, mrp, ptr, pts, disc_pct, gst_pct, line_amount,
      raw_pack, raw_company, raw_barcode
    ) VALUES (
      p_bill_id, v_sup, v_name, v_pid, v_conf, v_by,
      NULLIF(btrim(COALESCE(it->>'batch_no', it->>'batch','')),''),
      NULLIF(btrim(COALESCE(it->>'expiry',   it->>'exp','')),''),
      NULLIF(it->>'qty','')::numeric,
      COALESCE(NULLIF(it->>'free_qty','')::numeric, 0),
      NULLIF(it->>'mrp','')::numeric,
      NULLIF(COALESCE(it->>'ptr', it->>'rate'),'')::numeric,
      NULLIF(it->>'pts','')::numeric,
      COALESCE(NULLIF(it->>'disc_pct','')::numeric, 0),
      COALESCE(NULLIF(it->>'gst_pct','')::numeric, 0),
      NULLIF(COALESCE(it->>'amount', it->>'line_amount'),'')::numeric,
      NULLIF(btrim(COALESCE(it->>'pack', it->>'pack_size','')),''),
      NULLIF(btrim(COALESCE(it->>'company', it->>'marketer', it->>'mfr','')),''),
      NULLIF(btrim(COALESCE(it->>'barcode', it->>'ean','')),'')
    );
    IF v_pid IS NOT NULL THEN v_ok := v_ok + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object('ok',true,'lines',v_n,'matched',v_ok,'unmatched',v_n-v_ok,
    'low_confidence_catalogue_matches', v_wide,
    'warning', CASE WHEN v_wide > 0 THEN
      v_wide || ' line(s) matched outside this supplier''s open orders — admin must confirm the SKU'
    END,
    'auto_verified', (SELECT count(*) FROM bill_lines
                       WHERE pending_bill_id=p_bill_id AND auto_verified),
    'needs_fix', (SELECT count(*) FROM bill_lines
                   WHERE pending_bill_id=p_bill_id AND needs_fix IS NOT NULL));
END;
$function$;
