-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #431 — PARCEL COUNTING AT THE PHARMACY DOOR
--
-- Two features, one flow, because they are the same act: a box has arrived and
-- somebody has to prove that what is inside it matches the paper that came
-- with it.
--
--   1) A mediBO parcel is counted against the customer bill mediBO itself
--      issued. A mismatch is OUR problem, so it is raised on the EXISTING
--      doorstep claim path (#309 delivery_raise_claim -> delivery_claims ->
--      admin_claim_decide -> credit note). There is deliberately no second
--      claim table here: two claim systems means two answers to "who owes
--      what", and #309 already settled that question.
--
--   2) An outside-supplier parcel is counted against the bill the pharmacy
--      photographed (#423's vault parsed it). mediBO RECORDS the discrepancy
--      as the pharmacy's own evidence and does not mediate — the dispute is
--      between them and their distributor. What we do owe them is a correct
--      shelf: so the COUNTED quantity, never the billed quantity, becomes the
--      ledger lot.
--
-- The unification that makes this one feature instead of two: #423 already
-- writes a `pharmacy_purchase_bill` for BOTH doors — source='medibo' from the
-- delivery trigger (pharmacy_vault_ingest_order) and source='photo' from the
-- camera. So a count session hangs off a BILL, and everything above the
-- verdict is shared. Only what happens to a mismatch differs.
--
-- Ground truth (#424): a counted lot is the one moment the shelf is known
-- exactly. Every verified line therefore writes a `pharmacy_lot_correction`
-- with actual_left = the counted quantity, which is the channel #424's
-- posterior already treats as method='corrected', confidence 1.0. Counting a
-- parcel does not just fix today's stock — it retires the guesswork on that
-- lot permanently.
--
-- Input methods: the flow takes voice / barcode / rapid-typed input the same
-- way, because resolution happens HERE. `pharmacy_parcel_find` takes whatever
-- token the input kit produced (a scanned EAN, a spoken product name, a typed
-- fragment) and answers with the line it belongs to. Dart decides nothing.
--
-- RLS: every RPC resolves the caller's own pharmacy from the JWT
-- (my_customer_id(), which honours #408 staff sub-logins) and filters on it.
-- The tables carry RLS with no policy — same shape as #412/#423 — so a direct
-- client SELECT returns zero rows and the RPCs are the only door.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════ 0. TWO REPAIRS THE PATHS BELOW WALK STRAIGHT INTO ═════════════

-- (a) #423 writes stock moves with kind 'receipt_bill' (bill confirm) and
--     'shelf_seen' (cold-start rack shot), but #412's CHECK constraint was
--     never widened to know those words, so `_phs_apply` raised on the move
--     insert and an outside bill could not be confirmed at all. Widened here,
--     with this command's own 'count_verify' added in the same breath.
alter table public.pharmacy_stock_move drop constraint if exists pharmacy_stock_move_kind_check;
alter table public.pharmacy_stock_move add constraint pharmacy_stock_move_kind_check
  check (kind in ('receipt_order','receipt_outside','receipt_bill','opening',
                  'shelf_seen','sale','sale_void','adjust','count_verify'));

-- (b) #309's claim kinds are the three a rider can see at a door. A parcel
--     count sees three more, and they belong on the SAME claim rather than in
--     a parallel table. Widened, not replaced.
alter table public.delivery_claims drop constraint if exists delivery_claims_kind_check;
alter table public.delivery_claims add constraint delivery_claims_kind_check
  check (kind in ('damaged','short','missing','excess','wrong_item','wrong_batch'));

-- The credit-note reader learns the three new words. Unchanged otherwise: only
-- approved/credited claims with a real amount ever touch a tax invoice, and
-- the three new kinds are raised unpriced on purpose (see _c431_claim below).
create or replace function public._order_credit_notes(p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',     c.id,
           'amount', coalesce(c.amount,0),
           'reason', case c.kind
                       when 'damaged'     then public._c('delivery.claim_kind_damaged')
                       when 'short'       then public._c('delivery.claim_kind_short')
                       when 'excess'      then public._c('delivery.claim_kind_excess')
                       when 'wrong_item'  then public._c('delivery.claim_kind_wrong_item')
                       when 'wrong_batch' then public._c('delivery.claim_kind_wrong_batch')
                       else                    public._c('delivery.claim_kind_missing') end,
           'note',   coalesce(c.note,'')) order by c.raised_at), '[]'::jsonb)
    from public.delivery_claims c
   where c.order_id = p_order_id
     and c.status in ('approved','credited')
     and coalesce(c.amount,0) > 0;
$$;

-- (b2) #309's own guard still only knew the three door kinds, so a parcel
--      count's wrong-batch line came back 'bad_kind' and no claim was raised
--      at all. The guard is widened to the same list as the constraint above;
--      everything else in that function — the mandatory photo, the role test,
--      the PTR-based pricing, the delivery event — is untouched.
create or replace function public.delivery_raise_claim(
  p_delivery_id uuid,
  p_kind        text,
  p_qty         numeric,
  p_photo       text,
  p_note        text default null,
  p_order_item_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.deliveries%rowtype;
  v_role text := coalesce(public.get_my_role(),'none');
  v_is_rider boolean; v_is_cust boolean;
  v_amount numeric; v_id uuid; v_ptr numeric;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if coalesce(p_kind,'') not in ('damaged','short','missing',
                                 'excess','wrong_item','wrong_batch') then
    return jsonb_build_object('ok',false,'error','bad_kind');
  end if;

  if nullif(btrim(coalesce(p_photo,'')),'') is null then
    return jsonb_build_object('ok',false,'error','photo_required',
      'message', public._c('delivery.claim_photo_required'));
  end if;

  select exists(select 1 from public.delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid()) into v_is_rider;
  select exists(select 1 from public.orders o
                  join public.pharmacy_profiles pp on pp.id = o.customer_id
                 where o.id = d.order_id and pp.user_id = auth.uid()) into v_is_cust;

  -- CMD #431 — a pharmacy STAFF sub-login (#408) counting the parcel is the
  -- pharmacy for this purpose. Without this, the person who actually opens the
  -- boxes could not raise the claim they are standing in front of.
  if not v_is_cust then
    select exists(select 1 from public.orders o
                   where o.id = d.order_id and o.customer_id = public.my_customer_id())
      into v_is_cust;
  end if;

  if not (v_is_rider or v_is_cust or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  -- Price the credit off the TRADE rate actually billed for that line, not off
  -- MRP. Left null when the line is not billed yet; an admin prices it then.
  if p_order_item_id is not null then
    select b.ptr into v_ptr
      from public.bill_line_allocations a
      join public.bill_lines b on b.id = a.bill_line_id
     where a.order_item_id = p_order_item_id and b.verified
     order by b.id desc limit 1;
    v_amount := round(coalesce(v_ptr,0) * coalesce(p_qty,0), 2);
    if v_amount = 0 then v_amount := null; end if;
  end if;

  insert into public.delivery_claims(
    delivery_id, order_id, order_item_id, kind, qty, amount, note, photo_path,
    raised_by, raised_by_role)
  values (d.id, d.order_id, p_order_item_id, p_kind, coalesce(p_qty,0), v_amount,
          nullif(btrim(coalesce(p_note,'')),''), btrim(p_photo),
          auth.uid(), case when v_is_rider then 'delivery'
                          when v_is_cust then 'customer' else v_role end)
  returning id into v_id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
  values (d.id, d.order_id, d.partner_id, 'claim',
          p_kind || ' x' || trim_scale(coalesce(p_qty,0))::text,
          coalesce(auth.jwt()->>'email','rider'));

  return jsonb_build_object('ok',true,'claim_id',v_id,
    'status','open',
    'message', public._c('delivery.claim_raised'));
end $function$;

-- (c) A lot that has been physically counted is worth more than one that was
--     merely delivered. The flag lives on the lot so #424, the expiry radar
--     and the exchange can all tell the difference without joining a session.
alter table public.pharmacy_stock
  add column if not exists verified_at    timestamptz,
  add column if not exists verified_by    uuid,
  add column if not exists verified_qty   numeric,
  add column if not exists verify_session uuid;

comment on column public.pharmacy_stock.verified_at is
  'CMD #431 — the last time a human physically counted this lot against a bill. A lot with this set is ground truth for #424, not an inference.';

-- (d) The invoice keeps its own numbers. A counted quantity is recorded BESIDE
--     the billed one, never over it: the GST purchase register (#416) must
--     report what the supplier invoiced, while the shelf must hold what
--     actually arrived. `pharmacy_vault_bill_confirm` below reads the counted
--     value when there is one.
alter table public.pharmacy_purchase_bill_line
  add column if not exists counted_qty    numeric,
  add column if not exists counted_batch  text,
  add column if not exists counted_expiry text,
  add column if not exists count_verdict  text;

alter table public.pharmacy_purchase_bill
  add column if not exists count_status     text not null default 'none',
  add column if not exists count_session_id uuid,
  add column if not exists counted_at       timestamptz,
  add column if not exists discrepancy_count integer not null default 0;

comment on column public.pharmacy_purchase_bill.count_status is
  'none | counting | counted — whether this parcel has been physically checked against its bill.';

-- ═══════════════════ 1. THE SESSION AND ITS LINES ══════════════════════════

create table if not exists public.pharmacy_parcel_count (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  bill_id       uuid not null references public.pharmacy_purchase_bill(id) on delete cascade,

  -- medibo: mediBO issued this bill, a mismatch is a doorstep claim.
  -- outside: their own distributor, a mismatch is their evidence.
  kind          text not null check (kind in ('medibo','outside')),
  order_id      uuid,
  delivery_id   uuid,
  supplier_label text,

  status        text not null default 'open'
                check (status in ('open','done','abandoned')),

  lines_total    integer not null default 0,
  lines_counted  integer not null default 0,
  lines_match    integer not null default 0,
  lines_issue    integer not null default 0,

  started_by    uuid,
  started_label text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  finished_at   timestamptz
);

-- One open count per parcel. A second person opening the same box joins the
-- session that already exists rather than starting a rival one.
create unique index if not exists phpc_one_open
  on public.pharmacy_parcel_count (bill_id) where status = 'open';
create index if not exists phpc_shop
  on public.pharmacy_parcel_count (pharmacy_id, created_at desc);

comment on table public.pharmacy_parcel_count is
  'CMD #431 — one physical count of one arrived parcel against the bill that came with it. mediBO parcels and outside-supplier parcels share this table because they share the act.';

create table if not exists public.pharmacy_parcel_count_line (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references public.pharmacy_parcel_count(id) on delete cascade,
  bill_line_id  uuid,                        -- null for an item that is NOT on the bill
  line_no       integer not null,

  medicine_id   bigint,
  product_name  text not null,
  pack_label    text,
  item_key      text,

  -- What the paper promised, frozen at open time so a later edit of the bill
  -- cannot silently rewrite what the counter was checking against.
  expected_qty    numeric not null default 0,
  expected_batch  text,
  expected_expiry text,
  unit_cost       numeric,
  mrp             numeric,
  order_item_id   uuid,

  -- What the hands found. NULL counted_qty is the whole partial-count story:
  -- an untouched line is untouched, never a zero.
  counted_qty     numeric,
  counted_batch   text,
  counted_expiry  text,
  damaged_qty     numeric not null default 0,
  method          text check (method in ('voice','barcode','typed','tap')),

  verdict       text not null default 'pending'
                check (verdict in ('pending','match','short','excess','missing',
                                   'damaged','wrong_item','wrong_batch')),
  photo_path    text,
  note          text,

  claim_id      uuid,        -- the #309 claim this mismatch became
  claim_error   text,        -- why it could not become one, verbatim from #309
  lot_id        uuid,        -- the lot this line verified on finish

  counted_by    uuid,
  counted_label text,
  counted_at    timestamptz,
  created_at    timestamptz not null default now()
);

create unique index if not exists phpc_line_bill
  on public.pharmacy_parcel_count_line (session_id, bill_line_id)
  where bill_line_id is not null;
create index if not exists phpc_line_session
  on public.pharmacy_parcel_count_line (session_id, line_no);

alter table public.pharmacy_parcel_count      enable row level security;
alter table public.pharmacy_parcel_count_line enable row level security;
revoke all on public.pharmacy_parcel_count, public.pharmacy_parcel_count_line
  from anon, authenticated;

-- ═══════════════════ 2. SMALL HELPERS ══════════════════════════════════════

create or replace function public._c431_shop() returns uuid
language sql stable as $$ select public.my_customer_id(); $$;

create or replace function public._c431_denied() returns jsonb
language sql stable as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('phpc.err_not_pharmacy'));
$$;

-- Batch equality is a human comparison, not a string one: "AB-1204" on the
-- bill and "ab1204" off the strip are the same batch.
create or replace function public._c431_batch_key(p text) returns text
language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '');
$$;

-- The verdict is computed HERE, once, and every surface reads it. Order of
-- precedence matters: physically broken goods outrank a batch mismatch, and a
-- batch mismatch outranks a number, because a wrong batch at the right count
-- is still the wrong medicine on the shelf.
create or replace function public._c431_verdict(
  p_expected numeric, p_counted numeric, p_damaged numeric,
  p_exp_batch text, p_got_batch text, p_on_bill boolean)
returns text language sql immutable as $$
  select case
    when not p_on_bill                                then 'wrong_item'
    when p_counted is null                            then 'pending'
    when coalesce(p_damaged, 0) > 0                   then 'damaged'
    when public._c431_batch_key(p_exp_batch) is not null
     and public._c431_batch_key(p_got_batch) is not null
     and public._c431_batch_key(p_exp_batch)
         is distinct from public._c431_batch_key(p_got_batch) then 'wrong_batch'
    when coalesce(p_counted, 0) = 0 and coalesce(p_expected, 0) > 0 then 'missing'
    when coalesce(p_counted, 0) <  coalesce(p_expected, 0) then 'short'
    when coalesce(p_counted, 0) >  coalesce(p_expected, 0) then 'excess'
    else 'match' end;
$$;

create or replace function public._c431_tone(p_verdict text) returns text
language sql immutable as $$
  select case p_verdict
           when 'match'   then 'success'
           when 'pending' then 'neutral'
           when 'excess'  then 'warning'
           else 'danger' end;
$$;

-- Every word the screen prints about a verdict comes from ui_copy.
create or replace function public._c431_verdict_label(p_verdict text) returns text
language sql stable as $$ select public.ui_text('phpc.v_' || coalesce(p_verdict, 'pending')); $$;

create or replace function public._c431_actor() returns text
language sql stable as $$ select public._phs_actor_label(public.my_customer_id()); $$;

-- Recount the session's tallies from its lines. Called after every write, so
-- the header never drifts from the list under it.
create or replace function public._c431_tick(p_session uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.pharmacy_parcel_count c
     set lines_total   = t.total,
         lines_counted = t.counted,
         lines_match   = t.matched,
         lines_issue   = t.issues,
         updated_at    = now()
    from (select count(*)                                            as total,
                 count(*) filter (where verdict <> 'pending')        as counted,
                 count(*) filter (where verdict = 'match')           as matched,
                 count(*) filter (where verdict not in ('pending','match')) as issues
            from public.pharmacy_parcel_count_line where session_id = p_session) t
   where c.id = p_session;
end $$;

-- ═══════════════════ 3. WHAT CAN BE COUNTED ════════════════════════════════

create or replace function public._c431_bill_row(b public.pharmacy_purchase_bill)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_lines integer; v_sess uuid; v_status text;
begin
  select count(*) into v_lines from public.pharmacy_purchase_bill_line
   where bill_id = b.id and flag <> 'dropped';
  select id, status into v_sess, v_status from public.pharmacy_parcel_count
   where bill_id = b.id order by created_at desc limit 1;

  return jsonb_build_object(
    'bill_id',    b.id,
    'kind',       case when b.source = 'medibo' then 'medibo' else 'outside' end,
    'title',      case when b.source = 'medibo'
                       then public.ui_text('phpc.src_medibo')
                       else coalesce(nullif(btrim(coalesce(b.supplier_name, '')), ''),
                                     public.ui_text('phpc.src_outside')) end,
    'subtitle',   public.ui_fmt('phpc.bill_sub', jsonb_build_object(
                    'inv', coalesce(nullif(btrim(coalesce(b.invoice_no, '')), ''), '—'),
                    'n',   v_lines::text)),
    'date_label', coalesce(to_char(b.invoice_date, 'DD Mon YYYY'), '—'),
    'lines',      v_lines,
    'session_id', case when v_status = 'open' then v_sess else null end,
    'count_status', b.count_status,
    'status_label', public.ui_text('phpc.cs_' || b.count_status),
    'status_tone',  case b.count_status when 'counted' then 'success'
                                        when 'counting' then 'warning'
                                        else 'neutral' end,
    'cta',        case when b.count_status = 'counting'
                       then public.ui_text('phpc.cta_resume')
                       when b.count_status = 'counted'
                       then public.ui_text('phpc.cta_review')
                       else public.ui_text('phpc.cta_count') end);
end $$;

create or replace function public.pharmacy_parcel_home()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  v_med  jsonb := '[]'::jsonb;
  v_out  jsonb := '[]'::jsonb;
  b      public.pharmacy_purchase_bill%rowtype;
  v_open integer := 0;
begin
  if v_shop is null then return public._c431_denied(); end if;

  for b in
    select * from public.pharmacy_purchase_bill
     where pharmacy_id = v_shop and source = 'medibo'
       and status <> 'duplicate'
     order by coalesce(invoice_date, created_at::date) desc, created_at desc
     limit 30
  loop
    v_med := v_med || jsonb_build_array(public._c431_bill_row(b));
  end loop;

  for b in
    select * from public.pharmacy_purchase_bill
     where pharmacy_id = v_shop and source <> 'medibo'
       and status in ('read', 'review', 'confirmed')
     order by coalesce(invoice_date, created_at::date) desc, created_at desc
     limit 30
  loop
    v_out := v_out || jsonb_build_array(public._c431_bill_row(b));
  end loop;

  select count(*) into v_open from public.pharmacy_parcel_count
   where pharmacy_id = v_shop and status = 'open';

  return jsonb_build_object(
    'ok', true,
    'title',    public.ui_text('phpc.title'),
    'subtitle', public.ui_text('phpc.subtitle'),
    'open_count', v_open,
    'open_label', case when v_open > 0
                    then public.ui_fmt('phpc.open_n', jsonb_build_object('n', v_open::text))
                    else null end,
    'tabs', jsonb_build_array(
      jsonb_build_object('key', 'medibo',  'label', public.ui_text('phpc.tab_medibo'),
                         'empty', public.ui_text('phpc.empty_medibo'), 'rows', v_med),
      jsonb_build_object('key', 'outside', 'label', public.ui_text('phpc.tab_outside'),
                         'empty', public.ui_text('phpc.empty_outside'), 'rows', v_out)),
    'photo_bucket', 'stock-imports',
    'outside_hint', public.ui_text('phpc.outside_hint'));
end $$;

create or replace function public.pharmacy_parcel_entry()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c431_shop(); v_open integer;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select count(*) into v_open from public.pharmacy_parcel_count
   where pharmacy_id = v_shop and status = 'open';
  return jsonb_build_object('ok', true, 'show', true,
    'label',     public.ui_text('phpc.nav_label'),
    'badge',     case when v_open > 0 then v_open::text else null end,
    'route_key', 'pharmacy_parcel');
end $$;

-- ═══════════════════ 4. OPENING A COUNT ════════════════════════════════════
--
-- Snapshot, not a view. The lines are copied out of the bill at open time so
-- that a bill edited (or re-read by OCR) mid-count cannot move the target the
-- counter is aiming at. Re-opening an OPEN session returns the same rows,
-- which is what "finish later" means.

create or replace function public.pharmacy_parcel_open(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  v_b    public.pharmacy_purchase_bill%rowtype;
  v_sess uuid;
  v_kind text;
  v_del  uuid;
  v_l    record;
  v_n    integer := 0;
begin
  if v_shop is null then return public._c431_denied(); end if;

  select * into v_b from public.pharmacy_purchase_bill
   where id = p_bill_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_bill',
                              'message', public.ui_text('phpc.err_no_bill'));
  end if;

  v_kind := case when v_b.source = 'medibo' then 'medibo' else 'outside' end;

  select id into v_sess from public.pharmacy_parcel_count
   where bill_id = p_bill_id and status = 'open';

  if v_sess is null then
    if v_kind = 'medibo' and v_b.order_id is not null then
      select d.id into v_del from public.deliveries d
       where d.order_id = v_b.order_id
       order by d.delivered_at desc nulls last, d.created_at desc limit 1;
    end if;

    insert into public.pharmacy_parcel_count (
      pharmacy_id, bill_id, kind, order_id, delivery_id, supplier_label,
      started_by, started_label)
    values (
      v_shop, p_bill_id, v_kind, v_b.order_id, v_del,
      case when v_kind = 'medibo' then public.ui_text('phpc.src_medibo')
           else nullif(btrim(coalesce(v_b.supplier_name, '')), '') end,
      auth.uid(), public._c431_actor())
    returning id into v_sess;

    for v_l in
      select * from public.pharmacy_purchase_bill_line
       where bill_id = p_bill_id and flag <> 'dropped'
       order by line_no
    loop
      v_n := v_n + 1;
      insert into public.pharmacy_parcel_count_line (
        session_id, bill_line_id, line_no, medicine_id, product_name, pack_label,
        item_key, expected_qty, expected_batch, expected_expiry, unit_cost, mrp,
        order_item_id)
      values (
        v_sess, v_l.id, v_n, v_l.medicine_id,
        coalesce(nullif(btrim(coalesce(v_l.product_name, '')), ''), '—'),
        v_l.pack_label,
        public._phs_item_key(v_l.medicine_id, v_l.product_name),
        coalesce(v_l.qty, 0) + coalesce(v_l.free_qty, 0),
        v_l.batch_no, v_l.expiry, v_l.unit_cost, v_l.mrp,
        nullif(v_l.raw ->> 'order_item_id', '')::uuid)
      on conflict do nothing;
    end loop;

    update public.pharmacy_purchase_bill
       set count_status = 'counting', count_session_id = v_sess
     where id = p_bill_id;

    perform public._c431_tick(v_sess);
  end if;

  return public.pharmacy_parcel_get(v_sess);
end $$;

-- ═══════════════════ 5. THE RENDER PAYLOAD ═════════════════════════════════
--
-- One RPC, printed verbatim. Every rupee, every quantity, every chip and every
-- button caption below is a finished string: the screen adds nothing.

create or replace function public._c431_line_json(l public.pharmacy_parcel_count_line)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'line_id',   l.id,
    'line_no',   l.line_no,
    'name',      l.product_name,
    'pack',      coalesce(l.pack_label, ''),
    'expected_label', public.ui_fmt('phpc.expected',
                        jsonb_build_object('n', public._phs_qty(l.expected_qty))),
    'expected_qty',   l.expected_qty,
    'batch_label',    case when nullif(btrim(coalesce(l.expected_batch, '')), '') is null
                           then public.ui_text('phpc.no_batch')
                           else public.ui_fmt('phpc.batch', jsonb_build_object(
                                  'b', l.expected_batch,
                                  'e', coalesce(nullif(btrim(coalesce(l.expected_expiry,'')),''),
                                                public.ui_text('phpc.no_expiry')))) end,
    'counted_label',  case when l.counted_qty is null then null
                           else public.ui_fmt('phpc.counted',
                                  jsonb_build_object('n', public._phs_qty(l.counted_qty))) end,
    'counted_qty',    l.counted_qty,
    'counted_batch',  coalesce(l.counted_batch, ''),
    'counted_expiry', coalesce(l.counted_expiry, ''),
    'damaged_qty',    l.damaged_qty,
    'verdict',        l.verdict,
    'verdict_label',  public._c431_verdict_label(l.verdict),
    'verdict_tone',   public._c431_tone(l.verdict),
    'is_issue',       (l.verdict not in ('pending', 'match')),
    'needs_photo',    (l.verdict not in ('pending', 'match') and l.photo_path is null),
    'photo_path',     l.photo_path,
    'note',           coalesce(l.note, ''),
    'claim_label',    case when l.claim_id is not null
                           then public.ui_text('phpc.claim_raised')
                           when l.claim_error is not null then l.claim_error
                           else null end,
    'by_label',       case when l.counted_label is null then null
                           else public.ui_fmt('phpc.by', jsonb_build_object(
                                  'who', l.counted_label)) end);
$$;

create or replace function public.pharmacy_parcel_get(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop  uuid := public._c431_shop();
  c       public.pharmacy_parcel_count%rowtype;
  v_rows  jsonb := '[]'::jsonb;
  l       public.pharmacy_parcel_count_line%rowtype;
  v_staff jsonb;
  v_done  boolean;
begin
  if v_shop is null then return public._c431_denied(); end if;
  select * into c from public.pharmacy_parcel_count
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_session',
                              'message', public.ui_text('phpc.err_no_session'));
  end if;

  for l in
    select * from public.pharmacy_parcel_count_line
     where session_id = c.id order by line_no
  loop
    v_rows := v_rows || jsonb_build_array(public._c431_line_json(l));
  end loop;

  -- Per-staff attribution: who counted how much of this parcel.
  select coalesce(jsonb_agg(jsonb_build_object(
           'who', who, 'label', public.ui_fmt('phpc.staff_row',
             jsonb_build_object('who', who, 'n', n::text))) order by n desc), '[]'::jsonb)
    into v_staff
    from (select coalesce(counted_label, public.ui_text('phpc.someone')) as who,
                 count(*) as n
            from public.pharmacy_parcel_count_line
           where session_id = c.id and verdict <> 'pending'
           group by 1) s;

  v_done := (c.lines_counted >= c.lines_total and c.lines_total > 0);

  return jsonb_build_object(
    'ok', true,
    'session_id', c.id,
    'bill_id',    c.bill_id,
    'kind',       c.kind,
    'status',     c.status,
    'title',      coalesce(c.supplier_label, public.ui_text('phpc.src_outside')),
    'subtitle',   case when c.kind = 'medibo' then public.ui_text('phpc.sub_medibo')
                                              else public.ui_text('phpc.sub_outside') end,
    'progress_label', public.ui_fmt('phpc.progress', jsonb_build_object(
                        'done', c.lines_counted::text, 'total', c.lines_total::text)),
    'match_label',    public.ui_fmt('phpc.n_match', jsonb_build_object('n', c.lines_match::text)),
    'issue_label',    public.ui_fmt('phpc.n_issue', jsonb_build_object('n', c.lines_issue::text)),
    'issue_tone',     case when c.lines_issue > 0 then 'danger' else 'neutral' end,
    'methods', jsonb_build_array(
      jsonb_build_object('key', 'barcode', 'label', public.ui_text('phpc.m_barcode')),
      jsonb_build_object('key', 'voice',   'label', public.ui_text('phpc.m_voice')),
      jsonb_build_object('key', 'typed',   'label', public.ui_text('phpc.m_typed'))),
    'photo_bucket',   'stock-imports',
    'photo_required', public.ui_text('phpc.photo_required'),
    'staff',          v_staff,
    'staff_heading',  public.ui_text('phpc.staff_heading'),
    'rows',           v_rows,
    'empty',          public.ui_text('phpc.empty_lines'),
    -- Every label on the counting sheet, so the form holds no word of its own.
    'form', jsonb_build_object(
      'search_hint',   public.ui_text('phpc.f_search'),
      'qty',           public.ui_text('phpc.f_qty'),
      'batch',         public.ui_text('phpc.f_batch'),
      'expiry',        public.ui_text('phpc.f_expiry'),
      'damaged',       public.ui_text('phpc.f_damaged'),
      'save',          public.ui_text('phpc.f_save'),
      'photo',         public.ui_text('phpc.f_photo'),
      'close',         public.ui_text('phpc.f_close'),
      'retry',         public.ui_text('phpc.f_retry')),
    'can_finish',     (c.status = 'open' and c.lines_counted > 0),
    'finish_label',   case when v_done then public.ui_text('phpc.finish')
                                       else public.ui_text('phpc.finish_partial') end,
    'later_label',    public.ui_text('phpc.later'),
    'later_hint',     public.ui_text('phpc.later_hint'),
    'extra_label',    public.ui_text('phpc.extra'));
end $$;

-- ═══════════════════ 6. COUNTING A LINE ════════════════════════════════════
--
-- One entry point for all four input methods. The client sends what it read;
-- the verdict, the tallies, the claim and every string come back from here.

create or replace function public.pharmacy_parcel_mark(
  p_line_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  l      public.pharmacy_parcel_count_line%rowtype;
  c      public.pharmacy_parcel_count%rowtype;
  v_qty  numeric; v_dmg numeric; v_batch text; v_exp text; v_method text;
  v_verdict text;
begin
  if v_shop is null then return public._c431_denied(); end if;

  select cl.* into l from public.pharmacy_parcel_count_line cl
    join public.pharmacy_parcel_count s on s.id = cl.session_id
   where cl.id = p_line_id and s.pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_line',
                              'message', public.ui_text('phpc.err_no_line'));
  end if;
  select * into c from public.pharmacy_parcel_count where id = l.session_id;
  if c.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'closed',
                              'message', public.ui_text('phpc.err_closed'));
  end if;

  v_qty    := case when p_patch ? 'counted_qty'
                   then nullif(p_patch ->> 'counted_qty', '')::numeric
                   else l.counted_qty end;
  v_dmg    := coalesce(nullif(p_patch ->> 'damaged_qty', '')::numeric, l.damaged_qty, 0);
  v_batch  := coalesce(nullif(btrim(coalesce(p_patch ->> 'counted_batch', '')), ''),
                       l.counted_batch);
  v_exp    := coalesce(nullif(btrim(coalesce(p_patch ->> 'counted_expiry', '')), ''),
                       l.counted_expiry);
  v_method := coalesce(nullif(p_patch ->> 'method', ''), l.method, 'tap');
  if v_method not in ('voice','barcode','typed','tap') then v_method := 'tap'; end if;

  if v_qty is not null and v_qty < 0 then
    return jsonb_build_object('ok', false, 'error', 'bad_qty',
                              'message', public.ui_text('phpc.err_bad_qty'));
  end if;

  v_verdict := public._c431_verdict(l.expected_qty, v_qty, v_dmg,
                 l.expected_batch, v_batch, l.bill_line_id is not null);

  update public.pharmacy_parcel_count_line
     set counted_qty    = v_qty,
         counted_batch  = v_batch,
         counted_expiry = v_exp,
         damaged_qty    = coalesce(v_dmg, 0),
         method         = v_method,
         verdict        = v_verdict,
         photo_path     = coalesce(nullif(btrim(coalesce(p_patch ->> 'photo_path', '')), ''),
                                   photo_path),
         note           = coalesce(nullif(btrim(coalesce(p_patch ->> 'note', '')), ''), note),
         counted_by     = auth.uid(),
         counted_label  = public._c431_actor(),
         counted_at     = now()
   where id = p_line_id
  returning * into l;

  -- A mediBO mismatch with evidence attached becomes a doorstep claim NOW,
  -- while the rider is still at the door — not on finish, and not in a second
  -- claim table.
  if c.kind = 'medibo' and l.verdict not in ('pending', 'match') then
    perform public._c431_claim(l.id);
    select * into l from public.pharmacy_parcel_count_line where id = p_line_id;
  end if;

  perform public._c431_tick(l.session_id);
  select * into c from public.pharmacy_parcel_count where id = l.session_id;

  return jsonb_build_object('ok', true,
    'row', public._c431_line_json(l),
    'progress_label', public.ui_fmt('phpc.progress', jsonb_build_object(
                        'done', c.lines_counted::text, 'total', c.lines_total::text)),
    'match_label',    public.ui_fmt('phpc.n_match', jsonb_build_object('n', c.lines_match::text)),
    'issue_label',    public.ui_fmt('phpc.n_issue', jsonb_build_object('n', c.lines_issue::text)),
    'issue_tone',     case when c.lines_issue > 0 then 'danger' else 'neutral' end,
    'can_finish',     (c.status = 'open' and c.lines_counted > 0));
end $$;

-- An item in the box that is on no line of the bill. It is recorded as a real
-- counted line with nothing expected, which is exactly what 'wrong_item' means.
create or replace function public.pharmacy_parcel_extra(
  p_session_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  c      public.pharmacy_parcel_count%rowtype;
  v_no   integer;
  v_id   uuid;
  v_name text := nullif(btrim(coalesce(p_patch ->> 'name', '')), '');
begin
  if v_shop is null then return public._c431_denied(); end if;
  select * into c from public.pharmacy_parcel_count
   where id = p_session_id and pharmacy_id = v_shop and status = 'open';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_session',
                              'message', public.ui_text('phpc.err_no_session'));
  end if;
  if v_name is null then
    return jsonb_build_object('ok', false, 'error', 'no_name',
                              'message', public.ui_text('phpc.err_no_name'));
  end if;

  select coalesce(max(line_no), 0) + 1 into v_no
    from public.pharmacy_parcel_count_line where session_id = p_session_id;

  insert into public.pharmacy_parcel_count_line (
    session_id, bill_line_id, line_no, product_name, expected_qty,
    counted_qty, counted_batch, counted_expiry, method, verdict,
    photo_path, note, counted_by, counted_label, counted_at)
  values (
    p_session_id, null, v_no, v_name, 0,
    coalesce(nullif(p_patch ->> 'counted_qty', '')::numeric, 0),
    nullif(btrim(coalesce(p_patch ->> 'counted_batch', '')), ''),
    nullif(btrim(coalesce(p_patch ->> 'counted_expiry', '')), ''),
    coalesce(nullif(p_patch ->> 'method', ''), 'typed'),
    'wrong_item',
    nullif(btrim(coalesce(p_patch ->> 'photo_path', '')), ''),
    nullif(btrim(coalesce(p_patch ->> 'note', '')), ''),
    auth.uid(), public._c431_actor(), now())
  returning id into v_id;

  if c.kind = 'medibo' then perform public._c431_claim(v_id); end if;
  perform public._c431_tick(p_session_id);
  return public.pharmacy_parcel_get(p_session_id);
end $$;

-- ═══════════════════ 7. THE INPUT KIT'S ONE QUESTION ═══════════════════════
--
-- "I just read this — which line is it?" A barcode, a spoken name and a typed
-- fragment all arrive here as one token and are resolved against the SESSION's
-- own lines. Resolution is server-side on purpose: the same three input methods
-- then behave identically, and adding a fourth costs no deploy.

create or replace function public.pharmacy_parcel_find(
  p_session_id uuid, p_token text, p_method text default 'typed')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  c      public.pharmacy_parcel_count%rowtype;
  v_tok  text := nullif(btrim(coalesce(p_token, '')), '');
  v_med  bigint;
  l      public.pharmacy_parcel_count_line%rowtype;
  v_hits jsonb := '[]'::jsonb;
  v_n    integer;
begin
  if v_shop is null then return public._c431_denied(); end if;
  select * into c from public.pharmacy_parcel_count
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_session',
                              'message', public.ui_text('phpc.err_no_session'));
  end if;
  if v_tok is null then
    return jsonb_build_object('ok', false, 'error', 'empty',
                              'message', public.ui_text('phpc.err_empty_token'));
  end if;

  -- A barcode is an exact identity, so it is tried first and alone.
  if p_method = 'barcode' or v_tok ~ '^[0-9]{8,14}$' then
    select id into v_med from public."MEDICINE"
     where barcode = v_tok limit 1;
    if v_med is not null then
      select * into l from public.pharmacy_parcel_count_line
       where session_id = p_session_id and medicine_id = v_med
       order by line_no limit 1;
      if found then
        return jsonb_build_object('ok', true, 'row', public._c431_line_json(l));
      end if;
    end if;
    return jsonb_build_object('ok', false, 'error', 'not_on_bill',
      'token', v_tok, 'message', public.ui_text('phpc.err_not_on_bill'),
      'can_add_extra', true, 'extra_label', public.ui_text('phpc.extra'));
  end if;

  -- Voice and typing are fuzzy. Prefix first (a counter types three letters),
  -- then contains, both on the normalised name.
  for l in
    select * from public.pharmacy_parcel_count_line
     where session_id = p_session_id
       and public._norm_name(product_name) like public._norm_name(v_tok) || '%'
     order by line_no limit 8
  loop
    v_hits := v_hits || jsonb_build_array(public._c431_line_json(l));
  end loop;

  if jsonb_array_length(v_hits) = 0 then
    for l in
      select * from public.pharmacy_parcel_count_line
       where session_id = p_session_id
         and public._norm_name(product_name) like '%' || public._norm_name(v_tok) || '%'
       order by line_no limit 8
    loop
      v_hits := v_hits || jsonb_build_array(public._c431_line_json(l));
    end loop;
  end if;

  v_n := jsonb_array_length(v_hits);
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_on_bill',
      'token', v_tok, 'message', public.ui_text('phpc.err_not_on_bill'),
      'can_add_extra', true, 'extra_label', public.ui_text('phpc.extra'));
  elsif v_n = 1 then
    return jsonb_build_object('ok', true, 'row', v_hits -> 0);
  end if;

  return jsonb_build_object('ok', true, 'rows', v_hits,
    'pick_label', public.ui_fmt('phpc.pick', jsonb_build_object('n', v_n::text)));
end $$;

-- ═══════════════════ 8. A MISMATCH BECOMES #309's CLAIM ════════════════════
--
-- Not a new claim system — a call into the one that already exists. Photo
-- evidence is mandatory there (enforced in delivery_raise_claim, not in the
-- app, because the app is the layer that gets bypassed), so a mismatch with no
-- photo yet is simply not raised and the line says so.
--
-- Only short / missing / damaged are priced against the order line: those are
-- goods the pharmacy paid for and did not get. Excess, a wrong item and a
-- wrong batch are raised UNPRICED — they need a human decision, and a claim
-- that quietly credits money for goods that arrived is worse than no claim.

create or replace function public._c431_claim(p_line_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  l   public.pharmacy_parcel_count_line%rowtype;
  c   public.pharmacy_parcel_count%rowtype;
  v_qty numeric;
  v_res jsonb;
  v_item uuid;
begin
  select * into l from public.pharmacy_parcel_count_line where id = p_line_id;
  if not found or l.claim_id is not null then return; end if;
  select * into c from public.pharmacy_parcel_count where id = l.session_id;
  if c.kind <> 'medibo' or c.delivery_id is null then
    update public.pharmacy_parcel_count_line
       set claim_error = public.ui_text('phpc.claim_no_delivery')
     where id = p_line_id and claim_error is null;
    return;
  end if;
  if l.photo_path is null then
    update public.pharmacy_parcel_count_line
       set claim_error = public.ui_text('phpc.claim_needs_photo')
     where id = p_line_id;
    return;
  end if;

  v_qty := case l.verdict
             when 'damaged'  then greatest(coalesce(l.damaged_qty, 0), 0)
             when 'missing'  then coalesce(l.expected_qty, 0)
             when 'short'    then greatest(coalesce(l.expected_qty,0) - coalesce(l.counted_qty,0), 0)
             when 'excess'   then greatest(coalesce(l.counted_qty,0) - coalesce(l.expected_qty,0), 0)
             else coalesce(l.counted_qty, l.expected_qty, 0) end;

  v_item := case when l.verdict in ('short','missing','damaged')
                 then l.order_item_id else null end;

  begin
    v_res := public.delivery_raise_claim(
      c.delivery_id, l.verdict, v_qty, l.photo_path,
      public.ui_fmt('phpc.claim_note', jsonb_build_object(
        'item', l.product_name,
        'exp',  public._phs_qty(l.expected_qty),
        'got',  public._phs_qty(coalesce(l.counted_qty, 0)),
        'batch', coalesce(nullif(btrim(coalesce(l.counted_batch, '')), ''),
                          public.ui_text('phpc.no_batch')))),
      v_item);
  exception when others then
    v_res := jsonb_build_object('ok', false, 'message', sqlerrm);
  end;

  if coalesce((v_res ->> 'ok')::boolean, false) then
    update public.pharmacy_parcel_count_line
       set claim_id = (v_res ->> 'claim_id')::uuid, claim_error = null
     where id = p_line_id;
  else
    update public.pharmacy_parcel_count_line
       set claim_error = coalesce(v_res ->> 'message', v_res ->> 'error')
     where id = p_line_id;
  end if;
end $$;

-- ═══════════════════ 9. FINISHING — THE LEDGER LEARNS ══════════════════════
--
-- mediBO parcel: the lots already exist (the delivery trigger wrote them from
-- the bill). Counting does not re-add them — it CORRECTS them by the delta and
-- stamps them verified. Outside parcel: nothing has been applied yet, so the
-- counted numbers are written onto the bill line beside the billed ones and
-- #423's own confirm does the lot write, which keeps one writer of a lot.
--
-- Either way, every verified line writes #424's ground truth.

create or replace function public.pharmacy_parcel_finish(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  c      public.pharmacy_parcel_count%rowtype;
  l      public.pharmacy_parcel_count_line%rowtype;
  v_lot  uuid;
  v_delta numeric;
  v_ver  integer := 0;
  v_iss  integer := 0;
  v_conf jsonb;
begin
  if v_shop is null then return public._c431_denied(); end if;
  select * into c from public.pharmacy_parcel_count
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_session',
                              'message', public.ui_text('phpc.err_no_session'));
  end if;
  if c.status <> 'open' then
    return jsonb_build_object('ok', false, 'error', 'closed',
                              'message', public.ui_text('phpc.err_closed'));
  end if;
  if c.lines_counted = 0 then
    return jsonb_build_object('ok', false, 'error', 'nothing_counted',
                              'message', public.ui_text('phpc.err_nothing'));
  end if;

  -- Counted values land on the bill line BESIDE the billed ones. The invoice
  -- keeps its own numbers so #416's GST purchase register still reports what
  -- the supplier actually invoiced.
  for l in
    select * from public.pharmacy_parcel_count_line
     where session_id = p_session_id and verdict <> 'pending'
     order by line_no
  loop
    if l.bill_line_id is not null then
      update public.pharmacy_purchase_bill_line
         set counted_qty    = l.counted_qty,
             counted_batch  = l.counted_batch,
             counted_expiry = l.counted_expiry,
             count_verdict  = l.verdict
       where id = l.bill_line_id;
    end if;
    if l.verdict <> 'match' then v_iss := v_iss + 1; end if;
  end loop;

  if c.kind = 'outside' then
    -- One writer of a lot: #423's confirm, now reading the counted numbers.
    v_conf := public.pharmacy_vault_bill_confirm(c.bill_id);
  end if;

  for l in
    select * from public.pharmacy_parcel_count_line
     where session_id = p_session_id and verdict <> 'pending'
       and counted_qty is not null
     order by line_no
  loop
    v_lot := null;

    if c.kind = 'medibo' then
      -- A WRONG BATCH is not a quantity problem, it is two lots. The shelf was
      -- given the batch the bill promised; what actually arrived is a
      -- different batch entirely. So the promised lot is taken back to zero and
      -- the batch in the box is added beside it — otherwise the expiry radar
      -- would spend the next two years watching a batch that never existed.
      if public._c431_batch_key(l.counted_batch) is not null
         and public._c431_batch_key(l.expected_batch)
             is distinct from public._c431_batch_key(l.counted_batch)
      then
        perform public._phs_apply(
          p_shop        => v_shop,
          p_medicine_id => l.medicine_id,
          p_name        => l.product_name,
          p_pack        => l.pack_label,
          p_batch       => l.expected_batch,
          p_expiry      => l.expected_expiry,
          p_qty_delta   => -coalesce(l.expected_qty, 0),
          p_unit_cost   => l.unit_cost,
          p_mrp         => l.mrp,
          p_kind        => 'count_verify',
          p_source_kind => 'medibo_order',
          p_reason      => 'parcel_count',
          p_note        => public.ui_fmt('phpc.move_wrong_batch', jsonb_build_object(
                             'exp', coalesce(l.expected_batch, '—'),
                             'got', coalesce(l.counted_batch, '—'))),
          p_ref_kind    => 'parcel_count_rev',
          p_ref_id      => l.id::text,
          p_order_id    => c.order_id,
          p_actor       => l.counted_by);
        v_delta := coalesce(l.counted_qty, 0);
      else
        -- The shelf already holds what the bill said. Move it to what the hands
        -- found; a matching line moves it by zero and is still stamped verified.
        v_delta := coalesce(l.counted_qty, 0) - coalesce(l.expected_qty, 0);
      end if;
      if v_delta <> 0 then
        v_lot := public._phs_apply(
          p_shop        => v_shop,
          p_medicine_id => l.medicine_id,
          p_name        => l.product_name,
          p_pack        => l.pack_label,
          p_batch       => coalesce(l.counted_batch, l.expected_batch),
          p_expiry      => coalesce(l.counted_expiry, l.expected_expiry),
          p_qty_delta   => v_delta,
          p_unit_cost   => l.unit_cost,
          p_mrp         => l.mrp,
          p_kind        => 'count_verify',
          p_source_kind => 'medibo_order',
          p_reason      => 'parcel_count',
          p_note        => public.ui_fmt('phpc.move_note', jsonb_build_object(
                             'exp', public._phs_qty(l.expected_qty),
                             'got', public._phs_qty(l.counted_qty))),
          p_ref_kind    => 'parcel_count',
          p_ref_id      => l.id::text,
          p_order_id    => c.order_id,
          p_actor       => l.counted_by);
      end if;
    end if;

    -- Find the lot this line settled on, whichever path wrote it.
    if v_lot is null and l.bill_line_id is not null then
      select lot_id into v_lot from public.pharmacy_purchase_bill_line
       where id = l.bill_line_id;
    end if;
    if v_lot is null then
      select id into v_lot from public.pharmacy_stock
       where pharmacy_id = v_shop
         and item_key   = coalesce(l.item_key, public._phs_item_key(l.medicine_id, l.product_name))
         and batch_key  = upper(coalesce(nullif(btrim(coalesce(l.counted_batch, l.expected_batch, '')), ''), '~'))
         and expiry_key = coalesce(nullif(btrim(coalesce(l.counted_expiry, l.expected_expiry, '')), ''), '~')
       limit 1;
    end if;

    if v_lot is not null then
      update public.pharmacy_parcel_count_line set lot_id = v_lot where id = l.id;
      update public.pharmacy_stock
         set verified_at = now(), verified_by = l.counted_by,
             verified_qty = l.counted_qty, verify_session = p_session_id,
             is_unquantified = false
       where id = v_lot;

      -- #424's ground truth. A lot counted on arrival is known exactly, and
      -- this is the channel its posterior already treats as method='corrected'.
      if l.medicine_id is not null then
        insert into public.pharmacy_lot_correction (
          lot_id, pharmacy_id, medicine_id, actual_left, inferred_was, source, created_by)
        select v_lot, v_shop, l.medicine_id, l.counted_qty,
               (select inferred_left from public.pharmacy_lot_inference where lot_id = v_lot),
               'parcel_count', l.counted_by;
      end if;
      v_ver := v_ver + 1;
    end if;
  end loop;

  update public.pharmacy_parcel_count
     set status = 'done', finished_at = now(), updated_at = now()
   where id = p_session_id;

  update public.pharmacy_purchase_bill
     set count_status = 'counted', counted_at = now(),
         discrepancy_count = v_iss
   where id = c.bill_id;

  -- Re-run the posterior so the corrections are visible immediately. Never let
  -- a slow recompute lose a finished count.
  begin
    perform public.pharmacy_infer_lots(v_shop);
  exception when others then
    raise warning 'c431: inference recompute skipped — %', sqlerrm;
  end;

  return jsonb_build_object('ok', true,
    'session_id', p_session_id,
    'verified',   v_ver,
    'issues',     v_iss,
    'title',      public.ui_text('phpc.done_title'),
    'message',    public.ui_fmt('phpc.done', jsonb_build_object(
                    'n', v_ver::text, 'i', v_iss::text)),
    'evidence',   case when c.kind = 'outside' and v_iss > 0
                       then public.ui_text('phpc.evidence_outside') else null end,
    'tone',       case when v_iss > 0 then 'warning' else 'success' end);
end $$;

-- Counted numbers win over billed ones when the lot is written. This is the
-- ONE line of #423 that changes: the coalesce below is what "the counted
-- quantities, not the bill quantities, become the ledger lots" means, and it
-- is a no-op for every bill that was never counted.
create or replace function public.pharmacy_vault_bill_confirm(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phv_shop();
  v_b    public.pharmacy_purchase_bill%rowtype;
  v_l    record;
  v_lot  uuid;
  v_n    integer := 0;
  v_skip integer := 0;
  v_qty  numeric;
begin
  if v_shop is null then return public._phv_denied(); end if;
  select * into v_b from public.pharmacy_purchase_bill
   where id = p_bill_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_bill',
                              'message', public.ui_text('phvault.err_no_bill'));
  end if;
  if v_b.status = 'duplicate' then
    return jsonb_build_object('ok', false, 'error', 'duplicate',
                              'message', public.ui_text('phvault.reason_duplicate'));
  end if;

  for v_l in
    select * from public.pharmacy_purchase_bill_line
     where bill_id = p_bill_id and flag in ('ok', 'low_confidence')
       and (coalesce(qty, 0) <> 0 or counted_qty is not null)
     order by line_no
  loop
    -- CMD #431 — a counted line is the truth about what is on the shelf.
    v_qty := case when v_l.counted_qty is not null then v_l.counted_qty
                  else coalesce(v_l.qty, 0) + coalesce(v_l.free_qty, 0) end;
    if v_qty = 0 then v_skip := v_skip + 1; continue; end if;

    v_lot := public._phs_apply(
      p_shop        => v_shop,
      p_medicine_id => v_l.medicine_id,
      p_name        => v_l.product_name,
      p_pack        => v_l.pack_label,
      p_batch       => coalesce(nullif(btrim(coalesce(v_l.counted_batch, '')), ''), v_l.batch_no),
      p_expiry      => coalesce(nullif(btrim(coalesce(v_l.counted_expiry, '')), ''), v_l.expiry),
      p_qty_delta   => v_qty,
      p_unit_cost   => v_l.unit_cost,
      p_mrp         => v_l.mrp,
      p_kind        => 'receipt_bill',
      p_source_kind => case when v_b.source = 'shelf' then 'opening' else 'outside' end,
      p_ref_kind    => 'vault_line',
      p_ref_id      => v_l.id::text,
      p_supplier    => v_b.supplier_name,
      p_received_on => v_b.invoice_date);

    if v_lot is null then
      v_skip := v_skip + 1;
    else
      v_n := v_n + 1;
      update public.pharmacy_purchase_bill_line set lot_id = v_lot where id = v_l.id;
      update public.pharmacy_stock
         set bill_id = p_bill_id, bill_line_id = v_l.id
       where id = v_lot and bill_id is null;
      if v_l.medicine_id is not null then
        perform public._phv_alias_learn(v_shop, v_l.product_name, v_l.medicine_id,
                                        coalesce(v_l.match_source, 'confirm'));
      end if;
    end if;
  end loop;

  update public.pharmacy_purchase_bill
     set status = 'confirmed', confirmed_at = now(), applied_at = now()
   where id = p_bill_id;

  perform public._phv_batch_tick(v_b.batch_id);

  begin
    perform public.pharmacy_gst_build_outside(v_shop,
      date_trunc('month', coalesce(v_b.invoice_date, current_date))::date);
  exception when others then
    raise warning 'c423: gst rebuild skipped for % — %', p_bill_id, sqlerrm;
  end;

  return jsonb_build_object('ok', true, 'bill_id', p_bill_id, 'lots', v_n,
    'skipped', v_skip,
    'message', public.ui_fmt('phvault.confirmed', jsonb_build_object('n', v_n::text)));
end $$;

-- ═══════════════════ 10. WHO MAY CALL WHAT ═════════════════════════════════

revoke all on function public._c431_claim(uuid)               from anon, authenticated;
revoke all on function public._c431_tick(uuid)                from anon, authenticated;

grant execute on function public.pharmacy_parcel_home()                        to authenticated;
grant execute on function public.pharmacy_parcel_entry()                       to authenticated;
grant execute on function public.pharmacy_parcel_open(uuid)                    to authenticated;
grant execute on function public.pharmacy_parcel_get(uuid)                     to authenticated;
grant execute on function public.pharmacy_parcel_mark(uuid, jsonb)       to authenticated;
grant execute on function public.pharmacy_parcel_extra(uuid, jsonb)            to authenticated;
grant execute on function public.pharmacy_parcel_find(uuid, text, text)        to authenticated;
grant execute on function public.pharmacy_parcel_finish(uuid)                  to authenticated;

-- ═══════════════════ 11. THE WORDS ═════════════════════════════════════════
insert into public.ui_copy (key, value) values
  ('phpc.nav_label',    to_jsonb('Count parcel'::text)),
  ('phpc.title',        to_jsonb('Count a parcel'::text)),
  ('phpc.subtitle',     to_jsonb('Check what arrived against the bill that came with it'::text)),
  ('phpc.tab_medibo',   to_jsonb('mediBO parcels'::text)),
  ('phpc.tab_outside',  to_jsonb('Other suppliers'::text)),
  ('phpc.empty_medibo', to_jsonb('No mediBO deliveries to count yet.'::text)),
  ('phpc.empty_outside',to_jsonb('Photograph an outside bill in the bill vault, then count the parcel against it.'::text)),
  ('phpc.empty_lines',  to_jsonb('This bill has no readable lines to count.'::text)),
  ('phpc.outside_hint', to_jsonb('mediBO records what you counted as your evidence. The claim is between you and your supplier.'::text)),
  ('phpc.src_medibo',   to_jsonb('mediBO'::text)),
  ('phpc.src_outside',  to_jsonb('Outside supplier'::text)),
  ('phpc.sub_medibo',   to_jsonb('A mismatch is raised with mediBO straight away'::text)),
  ('phpc.sub_outside',  to_jsonb('A mismatch is recorded on your bill as evidence'::text)),
  ('phpc.bill_sub',     to_jsonb('Bill {{inv}} · {{n}} items'::text)),
  ('phpc.open_n',       to_jsonb('{{n}} count in progress'::text)),
  ('phpc.cta_count',    to_jsonb('Count'::text)),
  ('phpc.cta_resume',   to_jsonb('Resume'::text)),
  ('phpc.cta_review',   to_jsonb('View'::text)),
  ('phpc.cs_none',      to_jsonb('Not counted'::text)),
  ('phpc.cs_counting',  to_jsonb('Counting'::text)),
  ('phpc.cs_counted',   to_jsonb('Counted'::text)),
  ('phpc.expected',     to_jsonb('Bill says {{n}}'::text)),
  ('phpc.counted',      to_jsonb('Counted {{n}}'::text)),
  ('phpc.batch',        to_jsonb('Batch {{b}} · Exp {{e}}'::text)),
  ('phpc.no_batch',     to_jsonb('No batch on the bill'::text)),
  ('phpc.no_expiry',    to_jsonb('no expiry'::text)),
  ('phpc.progress',     to_jsonb('{{done}} of {{total}} counted'::text)),
  ('phpc.n_match',      to_jsonb('{{n}} verified'::text)),
  ('phpc.n_issue',      to_jsonb('{{n}} to sort out'::text)),
  ('phpc.by',           to_jsonb('by {{who}}'::text)),
  ('phpc.staff_heading',to_jsonb('Counted by'::text)),
  ('phpc.staff_row',    to_jsonb('{{who}} · {{n}} items'::text)),
  ('phpc.someone',      to_jsonb('Staff'::text)),
  ('phpc.m_barcode',    to_jsonb('Scan'::text)),
  ('phpc.m_voice',      to_jsonb('Speak'::text)),
  ('phpc.m_typed',      to_jsonb('Type'::text)),
  ('phpc.v_pending',    to_jsonb('Not counted'::text)),
  ('phpc.v_match',      to_jsonb('Verified'::text)),
  ('phpc.v_short',      to_jsonb('Short'::text)),
  ('phpc.v_excess',     to_jsonb('Extra sent'::text)),
  ('phpc.v_missing',    to_jsonb('Not in the parcel'::text)),
  ('phpc.v_damaged',    to_jsonb('Damaged'::text)),
  ('phpc.v_wrong_item', to_jsonb('Not on the bill'::text)),
  ('phpc.v_wrong_batch',to_jsonb('Different batch'::text)),
  ('phpc.photo_required', to_jsonb('Photograph the problem — the claim needs it'::text)),
  ('phpc.claim_raised', to_jsonb('Claim raised with mediBO'::text)),
  ('phpc.claim_needs_photo', to_jsonb('Add a photo to raise this with mediBO'::text)),
  ('phpc.claim_no_delivery', to_jsonb('No delivery record for this parcel yet'::text)),
  ('phpc.claim_note',   to_jsonb('Counted at the door: bill {{exp}}, found {{got}}, batch {{batch}} — {{item}}'::text)),
  ('phpc.move_note',    to_jsonb('Counted on arrival: bill {{exp}}, found {{got}}'::text)),
  ('phpc.move_wrong_batch', to_jsonb('Counted on arrival: bill said batch {{exp}}, batch {{got}} arrived'::text)),
  ('phpc.extra',        to_jsonb('Add an item that is not on the bill'::text)),
  ('phpc.f_search',     to_jsonb('Scan, say or type an item'::text)),
  ('phpc.f_qty',        to_jsonb('How many did you count?'::text)),
  ('phpc.f_batch',      to_jsonb('Batch on the pack'::text)),
  ('phpc.f_expiry',     to_jsonb('Expiry on the pack'::text)),
  ('phpc.f_damaged',    to_jsonb('Of those, how many are damaged?'::text)),
  ('phpc.f_save',       to_jsonb('Save this count'::text)),
  ('phpc.f_photo',      to_jsonb('Photograph it'::text)),
  ('phpc.f_close',      to_jsonb('Close'::text)),
  ('phpc.f_retry',      to_jsonb('Try again'::text)),
  ('phpc.pick',         to_jsonb('{{n}} items match — pick one'::text)),
  ('phpc.finish',       to_jsonb('Finish and update my stock'::text)),
  ('phpc.finish_partial', to_jsonb('Save what I counted and update my stock'::text)),
  ('phpc.later',        to_jsonb('Finish later'::text)),
  ('phpc.later_hint',   to_jsonb('Your count is saved. Come back to this parcel any time.'::text)),
  ('phpc.done_title',   to_jsonb('Parcel counted'::text)),
  ('phpc.done',         to_jsonb('{{n}} batches verified onto your shelf · {{i}} to sort out'::text)),
  ('phpc.evidence_outside', to_jsonb('The differences are saved on this bill as your evidence.'::text)),
  ('phpc.err_not_pharmacy', to_jsonb('Parcel counting is for a pharmacy account.'::text)),
  ('phpc.err_no_bill',  to_jsonb('That bill is not in your vault.'::text)),
  ('phpc.err_no_line',  to_jsonb('That line is not in this count.'::text)),
  ('phpc.err_no_session', to_jsonb('That count has ended.'::text)),
  ('phpc.err_closed',   to_jsonb('This parcel is already counted.'::text)),
  ('phpc.err_bad_qty',  to_jsonb('A counted quantity cannot be negative.'::text)),
  ('phpc.err_nothing',  to_jsonb('Count at least one item first.'::text)),
  ('phpc.err_no_name',  to_jsonb('Name the item you found.'::text)),
  ('phpc.err_empty_token', to_jsonb('Nothing to look up.'::text)),
  ('phpc.err_not_on_bill', to_jsonb('That item is not on this bill.'::text))
on conflict (key) do update set value = excluded.value;

insert into public.ui_copy (key, value) values
  ('delivery.claim_kind_excess',      to_jsonb('Extra sent'::text)),
  ('delivery.claim_kind_wrong_item',  to_jsonb('Wrong item'::text)),
  ('delivery.claim_kind_wrong_batch', to_jsonb('Wrong batch'::text))
on conflict (key) do nothing;

-- ═══════════════════ 12. ONE REPAIR IN #423's WORDS ════════════════════════
-- ui_fmt substitutes {{var}}, but the bill vault's copy was seeded with {var},
-- so every vault message printed its own placeholder to the pharmacist —
-- 'Confirmed {n} batches' with a literal {n}. This command calls one of those
-- messages (bill_confirm), so it fixes the family rather than routing around
-- it. Idempotent: a value already using {{var}} is left alone.
update public.ui_copy
   set value = to_jsonb(regexp_replace(value #>> '{}', '\{([a-z_]+)\}', '{{\1}}', 'g'))
 where key like 'phvault.%'
   and value #>> '{}' ~ '\{[a-z_]+\}'
   and value #>> '{}' !~ '\{\{';

-- ═══════════════════ 13. THE WAY IN, FOR THE OPERATOR ══════════════════════
-- The pharmacy reaches this from its own account screen (pharmacy_parcel_entry
-- draws the tile). The operator reaches the SAME screen from the admin
-- dashboard, exactly as #413/#415/#417's pharmacy surfaces are reached — the
-- RPCs still gate on the caller's own pharmacy and render their own refusal,
-- so this row grants a door, never a permission.
insert into public.feature_registry(feature_key, label, group_label, icon_key, route_key,
                                    sort_order, owner, default_access, is_active,
                                    category, surface, roles_allowed, description)
values ('admin.parcel_count', 'Count a parcel', 'Pharmacy tools', 'inventory', 'pharmacy_parcel',
        4139, 'medibo', 'none', true, 'parties', 'dashboard',
        array['admin','super_admin'],
        'CMD #431 - count an arrived parcel against its bill: a mediBO parcel raises the doorstep claim, an outside parcel records the pharmacy''s own evidence, and both write verified lots.')
on conflict (feature_key) do update
  set label = excluded.label, icon_key = excluded.icon_key, route_key = excluded.route_key,
      is_active = true, description = excluded.description,
      roles_allowed = excluded.roles_allowed, surface = excluded.surface;

-- ═══════════════════ 14. OM'S CORRECTION: THE mediBO COUNT LIVES ON THE ORDER
--
-- A mediBO parcel is not a stray box — it is THIS order, arriving. So its count
-- belongs beside Items / Payment / Bill / Track on the order card, reached from
-- the order it is a count of, and the standalone surface keeps only the parcels
-- that have no order behind them: the ones from the pharmacy's other suppliers.
--
-- Nothing about the counting itself changes. The session still hangs off the
-- bill, the verdicts are still the same function, a mismatch is still #309's
-- claim. Only the door moved.

-- The chip the order card draws. Absent (`show:false`) rather than greyed out
-- when there is nothing to count: an order that has not been delivered has no
-- parcel in the room yet.
create or replace function public.pharmacy_parcel_order_chip(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  v_bill public.pharmacy_purchase_bill%rowtype;
  v_sess public.pharmacy_parcel_count%rowtype;
  v_delivered boolean;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  if not exists (select 1 from public.orders o
                  where o.id = p_order_id and o.customer_id = v_shop) then
    return jsonb_build_object('ok', true, 'show', false);
  end if;

  select exists (select 1 from public.deliveries d
                  where d.order_id = p_order_id and d.delivered_at is not null)
    into v_delivered;

  select * into v_bill from public.pharmacy_purchase_bill
   where pharmacy_id = v_shop and order_id = p_order_id;

  -- Nothing to count against yet, and nothing delivered: no chip.
  if not v_delivered and v_bill.id is null then
    return jsonb_build_object('ok', true, 'show', false);
  end if;

  if v_bill.id is not null then
    select * into v_sess from public.pharmacy_parcel_count
     where bill_id = v_bill.id order by created_at desc limit 1;
  end if;

  return jsonb_build_object('ok', true, 'show', true,
    'label', case
               when v_sess.status = 'open' then public.ui_text('phpc.chip_resume')
               when v_sess.status = 'done' then public.ui_text('phpc.chip_done')
               else public.ui_text('phpc.chip_count') end,
    'tone',  case when v_sess.status = 'done' then 'success'
                  when v_sess.status = 'open' then 'warning'
                  else 'neutral' end,
    'session_id', case when v_sess.status = 'open' then v_sess.id else null end);
end $$;

-- Opening the count from the ORDER rather than from a bill id. The bill is
-- #423's, and if the delivery trigger has not written it yet this asks for it
-- by name rather than making the pharmacist wait for a background job — the
-- ingest is idempotent, so calling it here is free when it has already run.
create or replace function public.pharmacy_parcel_open_order(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  v_bill uuid;
begin
  if v_shop is null then return public._c431_denied(); end if;
  if not exists (select 1 from public.orders o
                  where o.id = p_order_id and o.customer_id = v_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
                              'message', public.ui_text('phpc.err_not_your_order'));
  end if;

  select id into v_bill from public.pharmacy_purchase_bill
   where pharmacy_id = v_shop and order_id = p_order_id;

  if v_bill is null then
    perform public.pharmacy_vault_ingest_order(p_order_id);
    select id into v_bill from public.pharmacy_purchase_bill
     where pharmacy_id = v_shop and order_id = p_order_id;
  end if;

  if v_bill is null then
    return jsonb_build_object('ok', false, 'error', 'no_bill_yet',
                              'message', public.ui_text('phpc.err_no_bill_yet'));
  end if;

  return public.pharmacy_parcel_open(v_bill);
end $$;

-- The standalone surface is now the OTHER suppliers' parcels only. A mediBO
-- parcel is reached from its order, so listing it here twice would be two
-- doors onto one box.
create or replace function public.pharmacy_parcel_home()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  v_out  jsonb := '[]'::jsonb;
  b      public.pharmacy_purchase_bill%rowtype;
  v_open integer := 0;
begin
  if v_shop is null then return public._c431_denied(); end if;

  for b in
    select * from public.pharmacy_purchase_bill
     where pharmacy_id = v_shop and source <> 'medibo'
       and status in ('read', 'review', 'confirmed')
     order by coalesce(invoice_date, created_at::date) desc, created_at desc
     limit 30
  loop
    v_out := v_out || jsonb_build_array(public._c431_bill_row(b));
  end loop;

  select count(*) into v_open from public.pharmacy_parcel_count
   where pharmacy_id = v_shop and status = 'open' and kind = 'outside';

  return jsonb_build_object(
    'ok', true,
    'title',    public.ui_text('phpc.title_outside'),
    'subtitle', public.ui_text('phpc.subtitle_outside'),
    'open_count', v_open,
    'open_label', case when v_open > 0
                    then public.ui_fmt('phpc.open_n', jsonb_build_object('n', v_open::text))
                    else null end,
    'tabs', jsonb_build_array(
      jsonb_build_object('key', 'outside', 'label', public.ui_text('phpc.tab_outside'),
                         'empty', public.ui_text('phpc.empty_outside'), 'rows', v_out)),
    'photo_bucket', 'stock-imports',
    'outside_hint', public.ui_text('phpc.outside_hint'),
    -- Where the mediBO half went, said out loud, so nobody hunts for it.
    'medibo_hint', public.ui_text('phpc.medibo_moved'));
end $$;

-- The nav badge counts only what this surface now holds.
create or replace function public.pharmacy_parcel_entry()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c431_shop(); v_open integer;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select count(*) into v_open from public.pharmacy_parcel_count
   where pharmacy_id = v_shop and status = 'open' and kind = 'outside';
  return jsonb_build_object('ok', true, 'show', true,
    'label',     public.ui_text('phpc.nav_label_outside'),
    'badge',     case when v_open > 0 then v_open::text else null end,
    'route_key', 'pharmacy_parcel');
end $$;

grant execute on function public.pharmacy_parcel_order_chip(uuid) to authenticated;
grant execute on function public.pharmacy_parcel_open_order(uuid) to authenticated;

insert into public.ui_copy (key, value) values
  ('phpc.chip_count',   to_jsonb('Count'::text)),
  ('phpc.chip_resume',  to_jsonb('Counting'::text)),
  ('phpc.chip_done',    to_jsonb('Counted'::text)),
  ('phpc.nav_label_outside', to_jsonb('Count outside parcel'::text)),
  ('phpc.title_outside',     to_jsonb('Outside supplier parcels'::text)),
  ('phpc.subtitle_outside',  to_jsonb('Check what your other suppliers sent against their own bill'::text)),
  ('phpc.medibo_moved',      to_jsonb('A mediBO parcel is counted from its own order — Orders › Count.'::text)),
  ('phpc.err_not_your_order', to_jsonb('That order is not yours.'::text)),
  ('phpc.err_no_bill_yet',   to_jsonb('This order has no bill to count against yet.'::text))
on conflict (key) do update set value = excluded.value;

-- The registry row follows the surface: it now names the outside half.
update public.feature_registry
   set label = 'Count outside parcel',
       description = 'CMD #431 - count a parcel from one of the pharmacy''s OTHER suppliers against the bill they photographed. A mediBO parcel is counted from its own order card.'
 where feature_key = 'admin.parcel_count';

-- ═══════════════════ 15. OM'S SECOND CORRECTION (live screenshots, 1:47/1:50)
--
-- Two things he could not do on the deployed build, and both were real:
--
-- (a) "in order tab to count the item which they received why the count button
--     not their" — because §14 drew the chip only once a delivery was stamped
--     or a bill existed. Om's pharmacy has 13 orders and NOT ONE of them has
--     either, so the feature he had just paid for was invisible on every card.
--     A gate that is correct and hides the whole feature is still a bug: the
--     chip now stands beside Items/Payment/Bill/Track on every order that is
--     not cancelled, and the BACKEND says whether it can be tapped yet. An
--     order still on its way carries the reason in its own words instead of
--     vanishing. A cancelled order keeps no chip — nothing will ever arrive.
--
-- (b) "how will it upload the image by camera or by selecting photo or file" —
--     because there was no way at all. #423 built the whole photo intake
--     (pharmacy_vault_bill_start -> shots -> queue) and nothing in the app ever
--     called it, so "Photograph an outside bill in the bill vault" pointed at a
--     door that did not exist. The outside surface now carries the intake
--     ACTION itself, described by the backend: its caption, the two ways in
--     (camera / photo or file), the guide, and the words on the sheet.

create or replace function public.pharmacy_parcel_order_chip(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  v_bill public.pharmacy_purchase_bill%rowtype;
  v_sess public.pharmacy_parcel_count%rowtype;
  v_delivered boolean;
  v_status text;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;

  select o.status into v_status from public.orders o
   where o.id = p_order_id and o.customer_id = v_shop;
  if v_status is null then
    return jsonb_build_object('ok', true, 'show', false);
  end if;

  -- A cancelled order has no parcel coming. Everything else does, so the chip
  -- is drawn and the enabled flag carries the truth.
  if v_status = 'cancelled' then
    return jsonb_build_object('ok', true, 'show', false);
  end if;

  select exists (select 1 from public.deliveries d
                  where d.order_id = p_order_id and d.delivered_at is not null)
    into v_delivered;

  select * into v_bill from public.pharmacy_purchase_bill
   where pharmacy_id = v_shop and order_id = p_order_id;

  if v_bill.id is not null then
    select * into v_sess from public.pharmacy_parcel_count
     where bill_id = v_bill.id order by created_at desc limit 1;
  end if;

  -- Nothing has arrived yet: the chip is there to be understood, not tapped.
  if not v_delivered and v_bill.id is null then
    return jsonb_build_object('ok', true, 'show', true, 'enabled', false,
      'label', public.ui_text('phpc.chip_count'),
      'tone',  'muted',
      'message', public.ui_text('phpc.chip_not_yet'),
      'session_id', null);
  end if;

  return jsonb_build_object('ok', true, 'show', true, 'enabled', true,
    'label', case
               when v_sess.status = 'open' then public.ui_text('phpc.chip_resume')
               when v_sess.status = 'done' then public.ui_text('phpc.chip_done')
               else public.ui_text('phpc.chip_count') end,
    'tone',  case when v_sess.status = 'done' then 'success'
                  when v_sess.status = 'open' then 'warning'
                  else 'neutral' end,
    'session_id', case when v_sess.status = 'open' then v_sess.id else null end);
end $$;

-- The outside surface stops pointing at a door and becomes one. `add_bill` is
-- the whole affordance: the button caption, the two ways to bring a photo in,
-- and the words the sheet is built from. Dart writes none of them.
create or replace function public.pharmacy_parcel_home()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c431_shop();
  v_out  jsonb := '[]'::jsonb;
  b      public.pharmacy_purchase_bill%rowtype;
  v_open integer := 0;
begin
  if v_shop is null then return public._c431_denied(); end if;

  for b in
    select * from public.pharmacy_purchase_bill
     where pharmacy_id = v_shop and source <> 'medibo'
       and status in ('read', 'review', 'confirmed')
     order by coalesce(invoice_date, created_at::date) desc, created_at desc
     limit 30
  loop
    v_out := v_out || jsonb_build_array(public._c431_bill_row(b));
  end loop;

  select count(*) into v_open from public.pharmacy_parcel_count
   where pharmacy_id = v_shop and status = 'open' and kind = 'outside';

  return jsonb_build_object(
    'ok', true,
    'title',    public.ui_text('phpc.title_outside'),
    'subtitle', public.ui_text('phpc.subtitle_outside'),
    'open_count', v_open,
    'open_label', case when v_open > 0
                    then public.ui_fmt('phpc.open_n', jsonb_build_object('n', v_open::text))
                    else null end,
    'tabs', jsonb_build_array(
      jsonb_build_object('key', 'outside', 'label', public.ui_text('phpc.tab_outside'),
                         'empty', public.ui_text('phpc.empty_outside'), 'rows', v_out)),
    'photo_bucket', 'stock-imports',
    'outside_hint', public.ui_text('phpc.outside_hint'),
    'medibo_hint', public.ui_text('phpc.medibo_moved'),
    -- THE INTAKE. Present on this surface because this is where a pharmacist
    -- stands when the box is on the counter.
    'add_bill', jsonb_build_object(
      'show',           true,
      'label',          public.ui_text('phpc.add_label'),
      'sheet_title',    public.ui_text('phpc.add_sheet_title'),
      'sheet_hint',     public.ui_text('phpc.add_sheet_hint'),
      'camera_label',   public.ui_text('phpc.add_camera'),
      'gallery_label',  public.ui_text('phpc.add_gallery'),
      'more_label',     public.ui_text('phpc.add_more'),
      'submit_label',   public.ui_text('phpc.add_submit'),
      'shots_label',    public.ui_text('phpc.add_shots'),
      'working_label',  public.ui_text('phpc.add_working'),
      'done_label',     public.ui_text('phpc.add_done'),
      'failed_label',   public.ui_text('phpc.add_failed')))
;
end $$;

grant execute on function public.pharmacy_parcel_order_chip(uuid) to authenticated;

insert into public.ui_copy (key, value) values
  ('phpc.chip_not_yet',     to_jsonb('Count this parcel when it arrives — this order has not been delivered yet.'::text)),
  ('phpc.add_label',        to_jsonb('Add outside bill'::text)),
  ('phpc.add_sheet_title',  to_jsonb('Photograph the outside bill'::text)),
  ('phpc.add_sheet_hint',   to_jsonb('One clear photo of the whole bill. Add more shots if it runs over a page.'::text)),
  ('phpc.add_camera',       to_jsonb('Take a photo'::text)),
  ('phpc.add_gallery',      to_jsonb('Choose photo or file'::text)),
  ('phpc.add_more',         to_jsonb('Add another page'::text)),
  ('phpc.add_submit',       to_jsonb('Read this bill'::text)),
  ('phpc.add_shots',        to_jsonb('{n} page(s) ready'::text)),
  ('phpc.add_working',      to_jsonb('Reading the bill…'::text)),
  ('phpc.add_done',         to_jsonb('Bill sent for reading. It will appear here to count.'::text)),
  ('phpc.add_failed',       to_jsonb('That photo could not be uploaded. Try again.'::text))
on conflict (key) do update set value = excluded.value;
