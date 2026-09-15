-- CHANGE #430 — PHARMACY STOCK AUDIT, part 1: the engine.
--
-- ONE counting system, not two. #413 already shipped a spot count
-- (pharmacy_count_session / _line / _attribution) for the theft radar, so this
-- command GROWS those tables instead of standing a second engine beside them:
-- a spot count becomes `kind='spot'` on the same session, and #413's
-- pharmacy_count_start() is rewired onto this engine in part 2. Two count
-- ledgers would mean two truths about the same shelf.
--
-- What the audit adds:
--   * SCOPE — a full shop count, or one rack / one category, so the shop never
--     has to close.
--   * BLIND — the expected quantity is frozen the moment the session starts and
--     is NEVER in the payload the counting staff read. You cannot copy a number
--     you were not shown. The owner's own view carries it; the counter's does
--     not, and that is enforced in SQL, not in Dart.
--   * FREEZE-FREE — sales (POS, and Tier-1 paper when it lands) that happen
--     DURING the session are reconciled against the count at close, so counting
--     never requires standing still.
--   * LOT GRAIN — the count is per batch, because expiry is per batch and the
--     radar (#425) and the inference (#424) both reason per lot.
--   * EXPIRY WHILE COUNTING — one extra glance at the strip, and the lot's
--     expiry is confirmed or filled in. It costs the counter nothing and it
--     densifies the expiry radar for free.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE SESSION grows
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.pharmacy_count_session
  add column if not exists kind          text not null default 'spot',
  add column if not exists scope_kind    text not null default 'shop',
  add column if not exists scope_value   text,
  add column if not exists blind         boolean not null default true,
  add column if not exists frozen_at     timestamptz,
  add column if not exists closed_at     timestamptz,
  add column if not exists accepted_at   timestamptz,
  add column if not exists photo_sample_pct integer not null default 10,
  add column if not exists counted_lines integer not null default 0,
  add column if not exists discrepant_lines integer not null default 0,
  add column if not exists sealed_at     timestamptz,
  add column if not exists seal_hash     text,
  add column if not exists seal_events   integer,
  add column if not exists label         text;

alter table public.pharmacy_count_line
  add column if not exists stock_id      uuid,
  add column if not exists batch_no      text,
  add column if not exists expiry_on     date,
  add column if not exists method        text,
  add column if not exists counted_by    uuid,
  add column if not exists counted_label text,
  add column if not exists expiry_seen   date,
  add column if not exists round_no      integer not null default 1,
  add column if not exists status        text not null default 'pending',
  add column if not exists needs_photo   boolean not null default false,
  add column if not exists resolved_qty  numeric,
  add column if not exists resolved_by   uuid,
  add column if not exists resolved_at   timestamptz;

-- #413 only ever had two states (open → submitted). An audit has a third: the
-- count is in, the variance is computed, and NOTHING has moved yet because the
-- second count and the owner's decision come first. Widening the constraint is
-- the honest way to add it — a session that is closed but not accepted must not
-- be able to masquerade as submitted.
alter table public.pharmacy_count_session
  drop constraint if exists pharmacy_count_session_status_check;
alter table public.pharmacy_count_session
  add constraint pharmacy_count_session_status_check
  check (status = any (array['open','closed','submitted','cancelled']));

create index if not exists pharmacy_count_line_session_idx
  on public.pharmacy_count_line (session_id, status);
create index if not exists pharmacy_count_line_stock_idx
  on public.pharmacy_count_line (stock_id);

-- The blind second count. A discrepant line is counted again by a DIFFERENT
-- person who is shown neither the expected number nor the first count.
create table if not exists public.pharmacy_count_round (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.pharmacy_count_session(id) on delete cascade,
  line_id      uuid not null references public.pharmacy_count_line(id) on delete cascade,
  round_no     integer not null,
  counted_qty  numeric,
  method       text,
  staff_user_id uuid,
  staff_label  text,
  counted_at   timestamptz,
  created_at   timestamptz not null default now()
);
alter table public.pharmacy_count_round enable row level security;
create unique index if not exists pharmacy_count_round_line_idx
  on public.pharmacy_count_round (line_id, round_no);

create table if not exists public.pharmacy_count_evidence (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.pharmacy_count_session(id) on delete cascade,
  line_id     uuid references public.pharmacy_count_line(id) on delete set null,
  kind        text not null default 'sample',   -- sample | shelf_photo | dispute
  bucket      text not null default 'stock-imports',
  path        text not null,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
alter table public.pharmacy_count_evidence enable row level security;
create index if not exists pharmacy_count_evidence_session_idx
  on public.pharmacy_count_evidence (session_id, created_at);

-- The sealed log. Append-only and hash-chained: every row carries the hash of
-- the row before it, so a later edit to ANY row breaks every hash after it and
-- pharmacy_audit_verify() says exactly where. This is the artefact an inspector
-- or a bank is shown.
create table if not exists public.pharmacy_audit_log (
  id          bigserial primary key,
  pharmacy_id uuid not null,
  session_id  uuid,
  seq         integer not null,
  event       text not null,
  payload     jsonb not null default '{}'::jsonb,
  actor       uuid,
  actor_label text,
  at          timestamptz not null default now(),
  prev_hash   text,
  hash        text not null
);
alter table public.pharmacy_audit_log enable row level security;
create unique index if not exists pharmacy_audit_log_seq_idx
  on public.pharmacy_audit_log (pharmacy_id, seq);
create index if not exists pharmacy_audit_log_session_idx
  on public.pharmacy_audit_log (session_id, seq);

create table if not exists public.pharmacy_cycle_plan (
  id          uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null references public.pharmacy_profiles(id) on delete cascade,
  plan_on     date not null default public._c413_today(),
  items       jsonb not null default '[]'::jsonb,
  session_id  uuid,
  created_at  timestamptz not null default now()
);
alter table public.pharmacy_cycle_plan enable row level security;
create unique index if not exists pharmacy_cycle_plan_day_idx
  on public.pharmacy_cycle_plan (pharmacy_id, plan_on);

create table if not exists public.pharmacy_audit_config (
  pharmacy_id      uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  blind            boolean not null default true,
  recount_required boolean not null default true,
  photo_sample_pct integer not null default 10,
  cycle_size       integer not null default 10,
  tolerance_qty    numeric not null default 0,
  updated_at       timestamptz not null default now()
);
alter table public.pharmacy_audit_config enable row level security;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. HELPERS
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c430_shop()
returns uuid language sql stable as $$ select public.my_customer_id(); $$;

create or replace function public._c430_denied()
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object('ok', false, 'error','not_a_pharmacy',
                            'message', public.ui_text('phaudit.refused'));
$$;

create or replace function public._c430_cfg(p_shop uuid)
returns public.pharmacy_audit_config language plpgsql stable set search_path to 'public' as $$
declare v public.pharmacy_audit_config;
begin
  select * into v from public.pharmacy_audit_config where pharmacy_id = p_shop;
  if found then return v; end if;
  v.pharmacy_id := p_shop; v.blind := true; v.recount_required := true;
  v.photo_sample_pct := 10; v.cycle_size := 10; v.tolerance_qty := 0;
  return v;
end $$;

create or replace function public._c430_actor_label()
returns text language sql stable set search_path to 'public' as $$
  select coalesce(
    (select nullif(btrim(coalesce(pp.owner_name, pp.customer_name, '')), '')
       from public.pharmacy_profiles pp where pp.user_id = auth.uid()),
    (select split_part(u.email, '@', 1) from auth.users u where u.id = auth.uid()),
    public.ui_text('phaudit.actor_unknown'));
$$;

-- THE SEAL. Every meaningful act on an audit is appended here, and each row's
-- hash covers the row before it. Nothing in this command ever UPDATEs a log row.
create or replace function public.audit_log_append(
  p_shop uuid, p_session uuid, p_event text, p_payload jsonb)
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_seq integer; v_prev text; v_hash text; v_at timestamptz := now();
        v_actor uuid := auth.uid(); v_label text := public._c430_actor_label();
begin
  select coalesce(max(seq), 0) + 1, (select hash from public.pharmacy_audit_log
                                      where pharmacy_id = p_shop
                                      order by seq desc limit 1)
    into v_seq, v_prev
    from public.pharmacy_audit_log where pharmacy_id = p_shop;

  -- pgcrypto lives in `extensions` on this project, and every function here
  -- pins search_path to 'public' — so the schema is named explicitly rather
  -- than trusted to a path.
  v_hash := encode(extensions.digest(
    coalesce(v_prev,'') || '|' || v_seq::text || '|' || p_event || '|' ||
    coalesce(p_session::text,'') || '|' ||
    coalesce(p_payload::text,'{}') || '|' || to_char(v_at, 'YYYY-MM-DD"T"HH24:MI:SS.USOF'),
    'sha256'), 'hex');

  insert into public.pharmacy_audit_log (pharmacy_id, session_id, seq, event,
    payload, actor, actor_label, at, prev_hash, hash)
  values (p_shop, p_session, v_seq, p_event, coalesce(p_payload,'{}'::jsonb),
          v_actor, v_label, v_at, v_prev, v_hash);
  return v_hash;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. COPY
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
 ('phaudit.title',        to_jsonb('Stock audit'::text)),
 ('phaudit.nav_label',    to_jsonb('Stock audit'::text)),
 ('phaudit.nav_sub',      to_jsonb('Count blind, see what is missing'::text)),
 ('phaudit.refused',      to_jsonb('Stock audit is available on a pharmacy account.'::text)),
 ('phaudit.actor_unknown', to_jsonb('Staff'::text)),
 ('phaudit.start_title',  to_jsonb('Start a count'::text)),
 ('phaudit.start_note',   to_jsonb('Counting is blind — the expected number is frozen now and stays hidden until you submit.'::text)),
 ('phaudit.kind_full',    to_jsonb('Whole shop'::text)),
 ('phaudit.kind_partial', to_jsonb('One rack or category'::text)),
 ('phaudit.kind_cycle',   to_jsonb('Today’s 10'::text)),
 ('phaudit.kind_spot',    to_jsonb('Spot check'::text)),
 ('phaudit.scope_hint',   to_jsonb('Rack name or category'::text)),
 ('phaudit.open_title',   to_jsonb('Count in progress'::text)),
 ('phaudit.open_note',    to_jsonb('{{done}} of {{total}} counted'::text)),
 ('phaudit.sheet_title',  to_jsonb('Count sheet'::text)),
 ('phaudit.blind_note',   to_jsonb('Expected quantities are hidden while you count.'::text)),
 ('phaudit.method_voice', to_jsonb('Voice'::text)),
 ('phaudit.method_barcode', to_jsonb('Scan'::text)),
 ('phaudit.method_photo', to_jsonb('Shelf photo'::text)),
 ('phaudit.method_type',  to_jsonb('Type'::text)),
 ('phaudit.expiry_prompt', to_jsonb('Expiry on the strip'::text)),
 ('phaudit.expiry_have',  to_jsonb('Expiry {{date}}'::text)),
 ('phaudit.expiry_missing', to_jsonb('No expiry recorded — add it while you are holding the strip'::text)),
 ('phaudit.counted_label', to_jsonb('Counted {{n}}'::text)),
 ('phaudit.uncounted',    to_jsonb('Not counted yet'::text)),
 ('phaudit.submit',       to_jsonb('Submit the count'::text)),
 ('phaudit.saved',        to_jsonb('Saved'::text)),
 ('phaudit.saved_n',      to_jsonb('{{n}} lines saved'::text)),
 ('phaudit.empty_sheet',  to_jsonb('Nothing to count in this scope'::text)),
 ('phaudit.empty_hint',   to_jsonb('Add stock, or pick a different rack.'::text)),
 ('phaudit.err_no_session', to_jsonb('That count is not open any more.'::text)),
 ('phaudit.err_closed',   to_jsonb('This count has already been submitted.'::text)),
 ('phaudit.err_open_one', to_jsonb('Finish the count that is already open first.'::text)),
 ('phaudit.err_no_line',  to_jsonb('That item is not on this count sheet.'::text)),
 ('phaudit.err_bad_qty',  to_jsonb('Enter a whole number, 0 or more.'::text)),
 ('phaudit.search_hint',  to_jsonb('Type a medicine name'::text)),
 ('phaudit.search_empty', to_jsonb('No match in your own stock'::text)),
 ('phaudit.n_items_one',  to_jsonb('1 item'::text)),
 ('phaudit.n_items_many', to_jsonb('{{n}} items'::text)),
 ('phaudit.photo_title',  to_jsonb('Shelf photo'::text)),
 ('phaudit.photo_note',   to_jsonb('We read the names off the rack; you put the numbers in.'::text)),
 ('phaudit.photo_queued', to_jsonb('Reading the shelf photo — this takes a few seconds.'::text)),
 ('phaudit.photo_read',   to_jsonb('{{n}} on the shelf photo matched your stock'::text)),
 ('phaudit.photo_failed', to_jsonb('Could not read that photo. Try again in better light.'::text))
on conflict (key) do nothing;

create or replace function public._c430_plural(p_base text, p_n integer)
returns text language sql stable set search_path to 'public' as $$
  select case when coalesce(p_n,0) = 1 then public.ui_text(p_base || '_one')
              else public.ui_fmt(p_base || '_many',
                     jsonb_build_object('n', coalesce(p_n,0)::text)) end;
$$;

-- A rack is a label the shop owns, so a partial audit can be "the top shelf by
-- the door" without anyone modelling a warehouse. It is filled in while
-- counting; it is not a taxonomy to maintain up front.
alter table public.pharmacy_stock
  add column if not exists rack_label text;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. START — the checklist freezes here, and is hidden from here
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_start(
  p_kind text default 'full', p_scope_kind text default 'shop',
  p_scope_value text default null, p_limit integer default 500)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop();
  v_cfg  public.pharmacy_audit_config;
  v_id   uuid := gen_random_uuid();
  v_kind text := case when p_kind in ('full','partial','cycle','spot') then p_kind else 'full' end;
  v_scope text := case when p_scope_kind in ('shop','rack','category','cycle') then p_scope_kind else 'shop' end;
  v_n integer; v_plan jsonb;
begin
  if v_shop is null then return public._c430_denied(); end if;
  v_cfg := public._c430_cfg(v_shop);

  if exists (select 1 from public.pharmacy_count_session
              where pharmacy_id = v_shop and status = 'open') then
    return jsonb_build_object('ok', false, 'error','session_open',
      'message', public.ui_text('phaudit.err_open_one'),
      'session_id', (select id from public.pharmacy_count_session
                      where pharmacy_id = v_shop and status = 'open'
                      order by started_at desc limit 1));
  end if;

  if v_kind = 'cycle' then
    select items into v_plan from public.pharmacy_cycle_plan
     where pharmacy_id = v_shop and plan_on = public._c413_today();
    if v_plan is null then
      v_plan := (public._c430_cycle_plan(v_shop)->'items');
    end if;
  end if;

  insert into public.pharmacy_count_session (
    id, pharmacy_id, status, kind, scope_kind, scope_value, blind,
    photo_sample_pct, window_from, started_by, started_at, frozen_at, label)
  values (v_id, v_shop, 'open', v_kind, v_scope, nullif(btrim(coalesce(p_scope_value,'')),''),
          v_cfg.blind, v_cfg.photo_sample_pct, now(), auth.uid(), now(), now(),
          case v_kind when 'full' then public.ui_text('phaudit.kind_full')
                      when 'cycle' then public.ui_text('phaudit.kind_cycle')
                      when 'spot' then public.ui_text('phaudit.kind_spot')
                      else public.ui_text('phaudit.kind_partial') end);

  -- THE FREEZE. Expected is what the books say the shelf holds right now:
  -- #424's inferred_left where the inference owns the shelf, the recorded
  -- quantity where it does not. Both are captured ONCE, here, so a sale during
  -- the count cannot move the target the counter is being measured against.
  insert into public.pharmacy_count_line (
    session_id, stock_id, product_id, product_name, pack_label, batch_no,
    expiry_on, unit_cost, opening_qty, expected_qty, status)
  select v_id, s.id, s.medicine_id, s.product_name, s.pack_label, s.batch_no,
         coalesce(s.expiry_on, public._c413_expiry_date(s.expiry)),
         coalesce(s.unit_cost, 0), coalesce(s.qty, 0),
         round(coalesce(i.inferred_left, s.qty, 0), 2), 'pending'
    from public.pharmacy_stock s
    left join public.pharmacy_lot_inference i on i.lot_id = s.id
   where s.pharmacy_id = v_shop
     and coalesce(s.qty, 0) > 0
     and (v_scope <> 'rack'     or lower(btrim(coalesce(s.rack_label,''))) = lower(btrim(coalesce(p_scope_value,''))))
     and (v_scope <> 'category' or public._c419_category(s.product_name) = coalesce(p_scope_value,''))
     and (v_kind  <> 'cycle'    or s.id::text in (
            select jsonb_array_elements_text(coalesce(v_plan, '[]'::jsonb) -> 'stock_ids')))
   order by s.product_name
   limit greatest(coalesce(p_limit, 500), 1);

  select count(*) into v_n from public.pharmacy_count_line where session_id = v_id;
  update public.pharmacy_count_session set sku_count = v_n where id = v_id;

  if v_kind = 'cycle' then
    update public.pharmacy_cycle_plan set session_id = v_id
     where pharmacy_id = v_shop and plan_on = public._c413_today();
  end if;

  perform public.audit_log_append(v_shop, v_id, 'session_started', jsonb_build_object(
    'kind', v_kind, 'scope_kind', v_scope, 'scope_value', p_scope_value,
    'lines', v_n, 'blind', v_cfg.blind));

  return jsonb_build_object('ok', true, 'session_id', v_id, 'lines', v_n,
    'blind', v_cfg.blind,
    'message', case when v_n = 0 then public.ui_text('phaudit.empty_sheet')
                    else public.ui_fmt('phaudit.open_note',
                           jsonb_build_object('done','0','total', v_n::text)) end);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE SHEET — what the counter sees, and what they must not
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c430_line_json(l public.pharmacy_count_line, p_blind boolean)
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object(
    'line_id',      l.id,
    'stock_id',     l.stock_id,
    'product_name', coalesce(l.product_name, ''),
    'pack_label',   coalesce(l.pack_label, ''),
    'batch_label',  case when coalesce(btrim(coalesce(l.batch_no,'')),'') = ''
                         then public.ui_text('phradar.no_batch')
                         else public.ui_fmt('phradar.batch_label',
                                jsonb_build_object('batch', l.batch_no)) end,
    'expiry_label', case when l.expiry_on is null
                         then public.ui_text('phaudit.expiry_missing')
                         else public.ui_fmt('phaudit.expiry_have',
                                jsonb_build_object('date', to_char(l.expiry_on,'DD/MM/YY'))) end,
    'has_expiry',   (l.expiry_on is not null),
    'expiry_prompt', public.ui_text('phaudit.expiry_prompt'),
    'status',       l.status,
    'counted',      (l.counted_qty is not null),
    'counted_label', case when l.counted_qty is null
                          then public.ui_text('phaudit.uncounted')
                          else public.ui_fmt('phaudit.counted_label',
                                 jsonb_build_object('n', trim(to_char(l.counted_qty,'FM999999990.##')))) end,
    'counted_qty',  l.counted_qty,
    'method',       l.method,
    -- THE BLIND RULE, in SQL. While the session is open the expected quantity
    -- is not in the payload at all — not hidden by the client, ABSENT. A number
    -- that never reaches the device cannot be copied onto the sheet.
    'expected_qty', case when p_blind then null else l.expected_qty end,
    'has_expected', (not p_blind));
$$;

create or replace function public.pharmacy_audit_sheet(
  p_session_id uuid, p_q text default null,
  p_limit integer default 100, p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  l public.pharmacy_count_line; v_rows jsonb := '[]'::jsonb;
  v_blind boolean; v_done integer; v_total integer;
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;
  v_blind := ss.blind and ss.status = 'open';

  for l in
    select * from public.pharmacy_count_line
     where session_id = ss.id
       and (coalesce(btrim(coalesce(p_q,'')),'') = ''
            or product_name ilike '%' || btrim(p_q) || '%')
     order by (counted_qty is not null), product_name, batch_no
     limit greatest(coalesce(p_limit,100),1) offset greatest(coalesce(p_offset,0),0)
  loop
    v_rows := v_rows || jsonb_build_array(public._c430_line_json(l, v_blind));
  end loop;

  select count(*) filter (where counted_qty is not null), count(*)
    into v_done, v_total from public.pharmacy_count_line where session_id = ss.id;

  return jsonb_build_object('ok', true,
    'session_id', ss.id, 'status', ss.status, 'kind', ss.kind,
    'title', public.ui_text('phaudit.sheet_title'),
    'scope_label', coalesce(ss.label, ''),
    'blind', v_blind,
    'blind_note', case when v_blind then public.ui_text('phaudit.blind_note') else null end,
    'progress_label', public.ui_fmt('phaudit.open_note',
       jsonb_build_object('done', v_done::text, 'total', v_total::text)),
    'submit_label', public.ui_text('phaudit.submit'),
    'search_hint', public.ui_text('phaudit.search_hint'),
    'methods', jsonb_build_array(
       jsonb_build_object('key','voice',   'label', public.ui_text('phaudit.method_voice')),
       jsonb_build_object('key','barcode', 'label', public.ui_text('phaudit.method_barcode')),
       jsonb_build_object('key','photo',   'label', public.ui_text('phaudit.method_photo')),
       jsonb_build_object('key','type',    'label', public.ui_text('phaudit.method_type'))),
    'rows', v_rows,
    'empty', public.ui_text('phaudit.empty_sheet'),
    'empty_hint', public.ui_text('phaudit.empty_hint'),
    'done', v_done, 'total', v_total);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. COUNT — one door for all four inputs
--
-- voice / barcode / shelf photo / typing differ only in how the NUMBER was
-- obtained, so they are one RPC with a `method` on each line rather than four
-- code paths that can drift apart. The method is recorded per line because the
-- variance report is more believable when it can say how each number arrived.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_audit_count(p_session_id uuid, p_lines jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop uuid := public._c430_shop(); ss public.pharmacy_count_session;
  e jsonb; l public.pharmacy_count_line; v_qty numeric; v_method text;
  v_exp date; v_n integer := 0; v_exp_added integer := 0;
  v_label text := public._c430_actor_label();
begin
  if v_shop is null then return public._c430_denied(); end if;
  select * into ss from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_session',
                              'message', public.ui_text('phaudit.err_no_session'));
  end if;
  if ss.status <> 'open' then
    return jsonb_build_object('ok', false, 'error','closed',
                              'message', public.ui_text('phaudit.err_closed'));
  end if;

  for e in select value from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    select * into l from public.pharmacy_count_line
     where session_id = ss.id
       and (id = nullif(e->>'line_id','')::uuid
            or stock_id = nullif(e->>'stock_id','')::uuid);
    if not found then continue; end if;

    v_qty := nullif(e->>'qty','')::numeric;
    if v_qty is null or v_qty < 0 then continue; end if;
    v_method := case when coalesce(e->>'method','') in ('voice','barcode','photo','type')
                     then e->>'method' else 'type' end;
    v_exp := coalesce(nullif(e->>'expiry_on','')::date,
                      public._c413_expiry_date(nullif(e->>'expiry','')));

    update public.pharmacy_count_line
       set counted_qty = v_qty, method = v_method, counted_at = now(),
           counted_by = auth.uid(), counted_label = v_label,
           status = 'counted',
           expiry_seen = coalesce(v_exp, expiry_seen)
     where id = l.id;
    v_n := v_n + 1;

    -- The free densification: the strip is already in their hand, so an expiry
    -- the ledger never had is captured now and the radar (#425) gets a lot it
    -- could not see before.
    if v_exp is not null and l.stock_id is not null then
      update public.pharmacy_stock
         set expiry_on = v_exp,
             expiry = coalesce(nullif(btrim(coalesce(expiry,'')),''), to_char(v_exp,'MM/YYYY')),
             updated_at = now()
       where id = l.stock_id
         and (expiry_on is distinct from v_exp);
      if found then v_exp_added := v_exp_added + 1; end if;
    end if;
  end loop;

  update public.pharmacy_count_session
     set counted_lines = (select count(*) from public.pharmacy_count_line
                           where session_id = ss.id and counted_qty is not null)
   where id = ss.id;

  perform public.audit_log_append(v_shop, ss.id, 'lines_counted',
    jsonb_build_object('lines', v_n, 'expiry_captured', v_exp_added, 'by', v_label));

  return jsonb_build_object('ok', true, 'saved', v_n, 'expiry_captured', v_exp_added,
    'message', public.ui_fmt('phaudit.saved_n', jsonb_build_object('n', v_n::text)));
end $$;

-- Rapid-type autocomplete: THEIR stock only, never the 563k-row catalogue.
create or replace function public.pharmacy_audit_search(p_session_id uuid, p_q text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c430_shop(); v_rows jsonb := '[]'::jsonb;
        l public.pharmacy_count_line;
begin
  if v_shop is null then return public._c430_denied(); end if;
  if coalesce(btrim(coalesce(p_q,'')),'') = '' then
    return jsonb_build_object('ok', true, 'rows', v_rows,
                              'empty', public.ui_text('phaudit.search_empty'));
  end if;
  for l in
    select cl.* from public.pharmacy_count_line cl
      join public.pharmacy_count_session s on s.id = cl.session_id
     where cl.session_id = p_session_id and s.pharmacy_id = v_shop
       and cl.product_name ilike '%' || btrim(p_q) || '%'
     order by (cl.counted_qty is not null), cl.product_name
     limit 15
  loop
    v_rows := v_rows || jsonb_build_array(public._c430_line_json(l, true));
  end loop;
  return jsonb_build_object('ok', true, 'rows', v_rows,
                            'empty', public.ui_text('phaudit.search_empty'));
end $$;

grant execute on function public.pharmacy_audit_start(text, text, text, integer) to authenticated;
grant execute on function public.pharmacy_audit_sheet(uuid, text, integer, integer) to authenticated;
grant execute on function public.pharmacy_audit_count(uuid, jsonb) to authenticated;
grant execute on function public.pharmacy_audit_search(uuid, text) to authenticated;
