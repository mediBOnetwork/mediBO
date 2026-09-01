-- CMD #413 — Expiry money-saver alerts, and the owner-only theft radar.
--
-- Two features over `pharmacy_stock`, the shelf-stock substrate. Both answer a
-- question the shop owner already asks out loud every month:
--   1. "How much of what is on my shelf is about to die?"  — and, the part that
--      actually saves the money, "which of it can still go back to the supplier,
--      and by when?"  Expiry is not the deadline. The supplier's RETURN WINDOW
--      is the deadline, and it closes months EARLIER.
--   2. "The register says fourteen strips. There are eleven." — counted against
--      expected, per product, attributed across the shifts that touched it.
--
-- ─────────────────────── WHY THIS IS NOT A B2C FEATURE ──────────────────────
-- legal_get_page('about') is explicit: mediBO is B2B trade supply to licensed
-- pharmacies. This layer is the BUYER's own shop management — the pharmacy's
-- shelf, the pharmacy's staff, the pharmacy's money. It never prices anything:
-- every rupee here is stock valued AT COST (the trade rate that pharmacy paid),
-- never at MRP. Valuing shrinkage or expiry at MRP would inflate both numbers by
-- the whole retail margin and make the reports lie in the shop's favour.
--
-- ───────────────────────── THE pharmacy_stock SUBSTRATE ─────────────────────
-- #412 (pharmacy auto-inventory) owns this table and was building in parallel
-- with this command. Rather than park a loaded build on a table that did not
-- exist yet, this file creates it IDEMPOTENTLY with the exact column names #412's
-- spec names (product, batch, expiry, qty, unit cost) mirrored off `stock_lot`,
-- the warehouse table it is modelled on. `create table if not exists` plus
-- `add column if not exists` for every column either side reads: whichever
-- migration lands first, the other is a silent no-op that only ever ADDS. This
-- file never writes a business rule into that table — it reads it.
--
-- ────────────────────────────── WHAT IS OWNER-ONLY ──────────────────────────
-- The theft radar is visible to the OWNER and to nobody else, by construction,
-- not by a UI flag. #408 gives a pharmacy staff member a real login that
-- `my_customer_id()` resolves to the same shop — so the shop check alone is NOT
-- a fence here. `_c413_is_owner()` denies any caller that reached the shop
-- through a `customer_users` staff row. A staff login asking for the variance
-- report gets the backend's refusal copy, never a number.
--
-- The wording is deliberately flat. The report says what was counted and what
-- was expected. It never says "theft", never names a cause, never accuses: the
-- commonest cause of a negative variance in a real pharmacy is a bill that was
-- never rung up, not a thief. Every one of those strings lives in `ui_copy`, so
-- softening a word is an UPDATE, not a deploy.

-- ═══════════════════════ 1. THE SUBSTRATE (shared with #412) ════════════════

-- #412 (pharmacy auto-inventory) landed this table minutes before this file and
-- it is #412's to own. Its shape is asserted here, not re-declared: if the
-- substrate is missing (a fresh database replaying migrations in file order) it
-- is created with #412's OWN column names, and if it is already there this is a
-- silent no-op that adds nothing. Everything below reads #412's names —
-- `medicine_id`, `expiry_on`, `supplier_label`, `first_order_id`, `received_on`
-- — because a second parallel column set on a shared table is how two features
-- end up disagreeing about the same shelf.
create table if not exists public.pharmacy_stock (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  medicine_id    bigint,
  product_name   text not null,
  pack_label     text,
  item_key       text,
  batch_no       text,
  expiry         text,
  expiry_on      date,
  qty            numeric(12,3) not null default 0,
  unit_cost      numeric(12,2) not null default 0,
  mrp            numeric(12,2),
  source_kind    text not null default 'manual',
  supplier_label text,
  first_order_id uuid,
  received_on    date,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists pharmacy_stock_shop_idx
  on public.pharmacy_stock (pharmacy_id, medicine_id);
create index if not exists c413_pharmacy_stock_expiry_idx
  on public.pharmacy_stock (pharmacy_id, expiry_on) where qty > 0;

alter table public.pharmacy_stock enable row level security;

-- ═══════════════════════ 2. THIS COMMAND'S OWN TABLES ═══════════════════════

-- A supplier's expiry-return window, in days BEFORE the printed expiry.
--   opens_days  — the earliest the supplier will take it back (e.g. 180)
--   closes_days — the last day they will take it back (e.g. 90)
-- A row with pharmacy_id NULL is the ADMIN DEFAULT every shop inherits; a row
-- with a pharmacy_id is that shop's own override. supplier_key '*' is the
-- catch-all for a supplier with no rule of its own.
create table if not exists public.pharmacy_return_window (
  id            bigserial primary key,
  pharmacy_id   uuid references public.pharmacy_profiles(id) on delete cascade,
  supplier_key  text not null,                 -- lower(btrim(supplier_name)) or '*'
  supplier_name text,
  opens_days    integer not null default 180 check (opens_days  > 0),
  closes_days   integer not null default 90   check (closes_days >= 0),
  note          text,
  updated_by    text,
  updated_at    timestamptz not null default now(),
  check (opens_days > closes_days)
);
create unique index if not exists pharmacy_return_window_shop_key_idx
  on public.pharmacy_return_window (pharmacy_id, supplier_key) where pharmacy_id is not null;
create unique index if not exists pharmacy_return_window_default_key_idx
  on public.pharmacy_return_window (supplier_key) where pharmacy_id is null;

-- The admin default every pharmacy starts from. 180 → 90 days before expiry is
-- the window most Indian distributors actually honour.
insert into public.pharmacy_return_window (pharmacy_id, supplier_key, supplier_name,
                                           opens_days, closes_days, updated_by, note)
values (null, '*', null, 180, 90, 'admin_default',
        'CMD #413 — platform default. A shop or a supplier row overrides it.')
on conflict do nothing;

-- Per-shop knobs. A shop with no row still gets a working payload: the defaults
-- live in the reader, not in an insert, so every read path stays STABLE.
create table if not exists public.pharmacy_expiry_config (
  pharmacy_id      uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  digest_enabled   boolean not null default true,
  urgent_days      integer not null default 14,   -- ping when the window closes within this
  updated_at       timestamptz not null default now()
);

-- One row per alert actually sent. The gate against a storm: a digest is sent
-- once per shop per ISO week, an urgent ping once per shop per product per day.
create table if not exists public.pharmacy_expiry_alert_log (
  id           bigserial primary key,
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  kind         text not null check (kind in ('weekly_digest','urgent_window')),
  dedupe_key   text not null,
  sent_on      date not null default (now() at time zone 'Asia/Kolkata')::date,
  detail       jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);
create unique index if not exists pharmacy_expiry_alert_dedupe_idx
  on public.pharmacy_expiry_alert_log (pharmacy_id, kind, dedupe_key);

-- The one-tap return list.
create table if not exists public.pharmacy_return_list (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,
  bucket        text not null,
  status        text not null default 'draft' check (status in ('draft','sent')),
  item_count    integer not null default 0,
  value_at_cost numeric(12,2) not null default 0,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  sent_at       timestamptz
);
create index if not exists pharmacy_return_list_shop_idx
  on public.pharmacy_return_list (pharmacy_id, created_at desc);

create table if not exists public.pharmacy_return_list_item (
  id                   uuid primary key default gen_random_uuid(),
  list_id              uuid not null references public.pharmacy_return_list(id) on delete cascade,
  stock_id             uuid,
  product_id           bigint,
  product_name         text not null,
  batch_no             text,
  expiry               text,
  qty                  numeric(12,3) not null default 0,
  unit_cost            numeric(12,2) not null default 0,
  value_at_cost        numeric(12,2) not null default 0,
  supplier_name        text,
  closes_on            date,
  -- The mediBO return path (#131 / #395). Present only when this shelf row came
  -- from a mediBO order, so the return can be raised without retyping anything.
  source_order_id      uuid,
  source_order_item_id uuid,
  medibo_qty           numeric(12,3),   -- what the RETURNS ENGINE says is left
  medibo_return_id     uuid,
  medibo_status        text,
  medibo_message       text,
  created_at           timestamptz not null default now()
);
alter table public.pharmacy_return_list_item
  add column if not exists medibo_qty numeric(12,3);
create index if not exists pharmacy_return_list_item_list_idx
  on public.pharmacy_return_list_item (list_id);

-- The spot count. The owner picks N random SKUs and counts them; nothing about
-- the expected number is shown BEFORE the count is submitted, or the count is
-- not a count.
create table if not exists public.pharmacy_count_session (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  status         text not null default 'open' check (status in ('open','submitted')),
  sku_count      integer not null default 0,
  window_from    timestamptz not null,
  started_by     uuid,
  started_at     timestamptz not null default now(),
  submitted_at   timestamptz,
  variance_units numeric(12,3) not null default 0,
  variance_value numeric(12,2) not null default 0
);
create index if not exists pharmacy_count_session_shop_idx
  on public.pharmacy_count_session (pharmacy_id, started_at desc);

create table if not exists public.pharmacy_count_line (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references public.pharmacy_count_session(id) on delete cascade,
  product_id    bigint,
  product_name  text not null,
  pack_label    text,
  unit_cost     numeric(12,2) not null default 0,
  opening_qty   numeric(12,3) not null default 0,
  received_qty  numeric(12,3) not null default 0,
  sold_qty      numeric(12,3) not null default 0,
  expected_qty  numeric(12,3) not null default 0,
  counted_qty   numeric(12,3),
  variance_qty  numeric(12,3),
  variance_value numeric(12,2),
  counted_at    timestamptz
);
create unique index if not exists pharmacy_count_line_session_product_idx
  on public.pharmacy_count_line (session_id, coalesce(product_id, -1), product_name);

-- Which shift carried which share of a counted variance. Proportional to what
-- that staff member SOLD of that product inside the window — a share of the
-- movement, never a claim about a person.
create table if not exists public.pharmacy_count_attribution (
  id             uuid primary key default gen_random_uuid(),
  session_id     uuid not null references public.pharmacy_count_session(id) on delete cascade,
  line_id        uuid not null references public.pharmacy_count_line(id) on delete cascade,
  staff_user_id  uuid,
  staff_label    text,
  sold_qty       numeric(12,3) not null default 0,
  share_pct      numeric(6,2)  not null default 0,
  variance_qty   numeric(12,3) not null default 0,
  variance_value numeric(12,2) not null default 0
);
create index if not exists pharmacy_count_attr_session_idx
  on public.pharmacy_count_attribution (session_id);

alter table public.pharmacy_return_window       enable row level security;
alter table public.pharmacy_expiry_config       enable row level security;
alter table public.pharmacy_expiry_alert_log    enable row level security;
alter table public.pharmacy_return_list         enable row level security;
alter table public.pharmacy_return_list_item    enable row level security;
alter table public.pharmacy_count_session       enable row level security;
alter table public.pharmacy_count_line          enable row level security;
alter table public.pharmacy_count_attribution   enable row level security;

-- No policies, by design — every read and write goes through the SECURITY
-- DEFINER RPCs below, each of which resolves the caller's own shop first. A
-- direct PostgREST select on any of these returns nothing.

-- ══════════════════════════════ 3. COPY ═════════════════════════════════════
-- Every user-visible word on both surfaces. Dart writes none of them.

insert into public.ui_copy (key, value) values
  ('phx.title',             to_jsonb('Expiry watch'::text)),
  ('phx.subtitle',          to_jsonb('Money still on the shelf'::text)),
  ('phx.nav_label',         to_jsonb('Expiry watch'::text)),
  ('phx.bucket_30',         to_jsonb('Within 30 days'::text)),
  ('phx.bucket_60',         to_jsonb('31 to 60 days'::text)),
  ('phx.bucket_90',         to_jsonb('61 to 90 days'::text)),
  ('phx.bucket_expired',    to_jsonb('Already expired'::text)),
  ('phx.headline_prefix',   to_jsonb(''::text)),
  ('phx.headline_suffix',   to_jsonb('of your stock expires within 90 days'::text)),
  ('phx.headline_clear',    to_jsonb('Nothing on your shelf expires in the next 90 days.'::text)),
  ('phx.value_label',       to_jsonb('Value at cost'::text)),
  ('phx.cost_note',         to_jsonb('Valued at what you paid, not at MRP'::text)),
  ('phx.items_label',       to_jsonb('Items'::text)),
  ('phx.items_one',         to_jsonb('1 item'::text)),
  ('phx.items_many',        to_jsonb('{n} items'::text)),
  ('phx.items_none',        to_jsonb('Nothing'::text)),
  ('phx.empty',             to_jsonb('Nothing in this window.'::text)),
  ('phx.empty_hint',        to_jsonb('Stock that moves into this window will appear here.'::text)),
  ('phx.more_button',       to_jsonb('Show more'::text)),
  ('phx.window_title',      to_jsonb('Return windows closing'::text)),
  ('phx.window_empty',      to_jsonb('No supplier return window closes soon.'::text)),
  ('phx.window_note',       to_jsonb('A supplier takes expiring stock back before it expires, not after.'::text)),
  ('phx.window_open_label', to_jsonb('Return window open'::text)),
  ('phx.window_shut_label', to_jsonb('Return window closed'::text)),
  ('phx.window_soon_label', to_jsonb('Return window not open yet'::text)),
  ('phx.window_closes_today', to_jsonb('Return window closes today'::text)),
  ('phx.window_closes_one',  to_jsonb('Return window closes in 1 day'::text)),
  ('phx.window_closes_in',   to_jsonb('Return window closes in {n} days'::text)),
  ('phx.build_button',      to_jsonb('Build return list'::text)),
  ('phx.building',          to_jsonb('Building the list…'::text)),
  ('phx.list_title',        to_jsonb('Return list'::text)),
  ('phx.list_empty',        to_jsonb('Nothing here can go back to a supplier yet.'::text)),
  ('phx.list_built_toast',  to_jsonb('Return list ready'::text)),
  ('phx.send_button',       to_jsonb('Raise on mediBO'::text)),
  ('phx.sending',           to_jsonb('Raising…'::text)),
  ('phx.sent_toast',        to_jsonb('Raised on mediBO'::text)),
  ('phx.medibo_label',      to_jsonb('Bought on mediBO'::text)),
  ('phx.outside_label',     to_jsonb('Bought outside mediBO'::text)),
  ('phx.outside_hint',      to_jsonb('Take this one back to the supplier yourself.'::text)),
  ('phx.supplier_label',    to_jsonb('Supplier'::text)),
  ('phx.batch_label',       to_jsonb('Batch'::text)),
  ('phx.expiry_label',      to_jsonb('Expiry'::text)),
  ('phx.qty_label',         to_jsonb('Qty'::text)),
  ('phx.no_supplier',       to_jsonb('Supplier not recorded'::text)),
  ('phx.no_batch',          to_jsonb('No batch'::text)),
  ('phx.no_expiry',         to_jsonb('No expiry recorded'::text)),
  ('phx.digest_title',      to_jsonb('Your weekly expiry summary'::text)),
  ('phx.retry',             to_jsonb('Retry'::text)),
  ('phx.boot_failed',       to_jsonb('Expiry watch could not be reached. Check the connection and try again.'::text)),
  ('phx.err_not_pharmacy',  to_jsonb('Expiry watch is available on a pharmacy account.'::text)),
  ('phx.err_no_list',       to_jsonb('That return list was not found.'::text)),
  ('phx.err_nothing',       to_jsonb('There is nothing in that window to return.'::text)),
  ('phx.err_already_sent',  to_jsonb('This list has already been raised.'::text)),
  ('phx.photo_label',       to_jsonb('Photo of the batch'::text)),
  ('phx.photo_hint',        to_jsonb('mediBO needs one photo of the expiring stock before a return can be raised. One photo covers the whole list.'::text)),
  ('phx.pending_note',      to_jsonb('Raised for approval. mediBO checks it and the credit note follows.'::text)),
  ('phx.medibo_qty_label',  to_jsonb('{n} of these were bought on mediBO'::text)),
  ('phx.medibo_qty_none',   to_jsonb('None of this batch was bought on mediBO'::text)),

  ('phv.title',             to_jsonb('Stock check'::text)),
  ('phv.subtitle',          to_jsonb('Counted against expected'::text)),
  ('phv.nav_label',         to_jsonb('Stock check'::text)),
  ('phv.start_button',      to_jsonb('Start a spot count'::text)),
  ('phv.starting',          to_jsonb('Picking items…'::text)),
  ('phv.sheet_title',       to_jsonb('Count these'::text)),
  ('phv.sheet_hint',        to_jsonb('Count what is physically on the shelf and enter it. The expected number is shown after you submit.'::text)),
  ('phv.counted_label',     to_jsonb('Counted'::text)),
  ('phv.expected_label',    to_jsonb('Expected'::text)),
  ('phv.opening_label',     to_jsonb('Opening'::text)),
  ('phv.received_label',    to_jsonb('Received'::text)),
  ('phv.sold_label',        to_jsonb('Sold'::text)),
  ('phv.variance_label',    to_jsonb('Difference'::text)),
  ('phv.submit_button',     to_jsonb('Submit count'::text)),
  ('phv.submitting',        to_jsonb('Saving the count…'::text)),
  ('phv.submitted_toast',   to_jsonb('Count saved'::text)),
  ('phv.match_label',       to_jsonb('Matches'::text)),
  ('phv.short_label',       to_jsonb('Short'::text)),
  ('phv.over_label',        to_jsonb('Extra'::text)),
  ('phv.report_title',      to_jsonb('This week'::text)),
  ('phv.report_empty',      to_jsonb('No differences recorded yet.'::text)),
  ('phv.report_empty_hint', to_jsonb('Run a spot count and the numbers will build up here.'::text)),
  ('phv.report_clean',      to_jsonb('Every item counted this week matched the expected number.'::text)),
  ('phv.leaked_label',      to_jsonb('Value of the difference'::text)),
  ('phv.staff_title',       to_jsonb('By shift'::text)),
  ('phv.staff_empty',       to_jsonb('No shift has a recorded difference yet.'::text)),
  ('phv.staff_note',        to_jsonb('A shift carries the share of a difference that matches the share it sold. It is a share of the movement, not a finding about a person.'::text)),
  ('phv.trend_title',       to_jsonb('Trend'::text)),
  ('phv.cause_note',        to_jsonb('The commonest reason for a short count is a sale that was never billed. Check the day before drawing a conclusion.'::text)),
  ('phv.owner_only_note',   to_jsonb('Only the owner account can open this.'::text)),
  ('phv.retry',             to_jsonb('Retry'::text)),
  ('phv.boot_failed',       to_jsonb('Stock check could not be reached. Check the connection and try again.'::text)),
  ('phv.err_not_pharmacy',  to_jsonb('Stock check is available on a pharmacy account.'::text)),
  ('phv.err_not_owner',     to_jsonb('This is an owner-only report.'::text)),
  ('phv.err_no_stock',      to_jsonb('There is nothing on the shelf to count yet.'::text)),
  ('phv.err_no_session',    to_jsonb('That count was not found.'::text)),
  ('phv.err_done',          to_jsonb('This count has already been submitted.'::text)),
  ('phv.err_no_lines',      to_jsonb('Enter a counted quantity for at least one item.'::text)),
  ('phv.unit_default',      to_jsonb('units'::text)),
  ('phv.line_short',        to_jsonb('{qty} {unit} {product} unaccounted'::text)),
  ('phv.line_over',         to_jsonb('{qty} {unit} {product} more on the shelf than expected'::text)),
  ('phv.trend_line',        to_jsonb('{now} this period · {prev} the period before'::text)),
  ('phv.staff_unnamed',     to_jsonb('Unnamed shift'::text))
on conflict (key) do nothing;

-- ═════════════════════════ 4. THE SMALL HELPERS ═════════════════════════════

create or replace function public._c413_today()
returns date language sql stable
set search_path to 'public' as $$ select (now() at time zone 'Asia/Kolkata')::date; $$;

-- The shop the caller is standing in. Same door POS uses.
create or replace function public._c413_shop()
returns uuid language sql stable security definer
set search_path to 'public' as $$ select public.my_customer_id(); $$;

-- OWNER, not merely "on this shop". A #408 staff login resolves to the same
-- pharmacy through `customer_users`; the theft radar must never open for it.
-- The test is what the caller matched ON: a staff row means staff, full stop.
create or replace function public._c413_is_owner(p_shop uuid)
returns boolean language sql stable security definer
set search_path to 'public' as $$
  select p_shop is not null
     and not exists (
           select 1 from public.customer_users cu
            where cu.customer_id = p_shop
              and coalesce(cu.is_active, true)
              and (cu.identity = any (public.my_identity_keys())
                   or cu.auth_user_id = auth.uid()));
$$;

create or replace function public._c413_denied(p_key text)
returns jsonb language sql stable
set search_path to 'public' as $$
  select jsonb_build_object('ok', false,
                            'error', case when p_key like '%not_owner%' then 'not_owner'
                                          else 'not_a_pharmacy' end,
                            'message', public.ui_text(p_key));
$$;

-- A printed expiry is text and it is never one shape: '11/27', '11/2027',
-- '2027-11', '2027-11-30', 'Nov 2027'. Resolve to the LAST DAY of that month —
-- a pack marked 11/27 is good to 30 Nov 2027, not to the 1st. Anything that
-- cannot be read returns null, and a null expiry is EXCLUDED from every bucket
-- rather than guessed into one.
create or replace function public._c413_expiry_date(p text)
returns date language plpgsql immutable
set search_path to 'public' as $function$
declare
  s  text := upper(btrim(coalesce(p, '')));
  mm integer; yy integer; d date;
begin
  if s = '' then return null; end if;

  -- YYYY-MM-DD / YYYY/MM/DD
  if s ~ '^\d{4}[-/]\d{1,2}[-/]\d{1,2}$' then
    begin
      return to_date(regexp_replace(s, '/', '-', 'g'), 'YYYY-MM-DD');
    exception when others then return null; end;
  end if;

  -- YYYY-MM
  if s ~ '^\d{4}[-/]\d{1,2}$' then
    yy := split_part(regexp_replace(s, '/', '-', 'g'), '-', 1)::int;
    mm := split_part(regexp_replace(s, '/', '-', 'g'), '-', 2)::int;
  -- MM/YY or MM/YYYY or MM-YY
  elsif s ~ '^\d{1,2}[-/]\d{2,4}$' then
    mm := split_part(regexp_replace(s, '-', '/', 'g'), '/', 1)::int;
    yy := split_part(regexp_replace(s, '-', '/', 'g'), '/', 2)::int;
    if yy < 100 then yy := 2000 + yy; end if;
  -- MON YY / MON YYYY
  elsif s ~ '^[A-Z]{3,9}[ -]?\d{2,4}$' then
    begin
      mm := extract(month from to_date(left(regexp_replace(s, '[^A-Z]', '', 'g'), 3), 'MON'))::int;
    exception when others then return null; end;
    yy := regexp_replace(s, '\D', '', 'g')::int;
    if yy < 100 then yy := 2000 + yy; end if;
  else
    return null;
  end if;

  if mm is null or mm < 1 or mm > 12 or yy is null or yy < 1990 or yy > 2999 then
    return null;
  end if;
  d := make_date(yy, mm, 1);
  return (d + interval '1 month - 1 day')::date;
end $function$;

-- The return window that applies to one shelf row: this shop's rule for this
-- supplier, else this shop's catch-all, else the admin default for the
-- supplier, else the admin default catch-all. Data, four deep, no code change.
create or replace function public._c413_window(p_shop uuid, p_supplier text)
returns public.pharmacy_return_window language sql stable
set search_path to 'public' as $$
  select w.* from public.pharmacy_return_window w
   where (w.pharmacy_id = p_shop or w.pharmacy_id is null)
     and (w.supplier_key = lower(btrim(coalesce(p_supplier, ''))) or w.supplier_key = '*')
   order by (w.pharmacy_id is not null) desc,
            (w.supplier_key <> '*')     desc
   limit 1;
$$;

-- The unit a pharmacist actually says out loud. 'strips' when the pack is
-- strips, else the copy default. Never invented in Dart.
create or replace function public._c413_unit(p_product_id bigint)
returns text language sql stable
set search_path to 'public' as $$
  select coalesce(
    (select case
              when lower(coalesce(m.pack_type,'')) like '%strip%'  then 'strips'
              when lower(coalesce(m.pack_type,'')) like '%bottle%' then 'bottles'
              when lower(coalesce(m.pack_type,'')) like '%tube%'   then 'tubes'
              when lower(coalesce(m.pack_type,'')) like '%vial%'   then 'vials'
              when lower(coalesce(m.pack_type,'')) like '%box%'    then 'boxes'
            end
       from public."MEDICINE" m where m.id = p_product_id),
    public.ui_text('phv.unit_default'));
$$;

-- A quantity printed the way a human writes it: 14, not 14.000.
create or replace function public._c413_qty(p numeric)
returns text language sql immutable
set search_path to 'public' as $$ select trim_scale(coalesce(p, 0))::text; $$;

-- "closes in 1 days" is the tell that a plural was built in code. Three keys,
-- the backend picks; Dart prints whichever came back.
create or replace function public._c413_items_label(p_n bigint)
returns text language sql stable
set search_path to 'public' as $$
  select case when coalesce(p_n, 0) = 0 then public.ui_text('phx.items_none')
              when p_n = 1              then public.ui_text('phx.items_one')
              else public.ui_text_f('phx.items_many',
                                    jsonb_build_object('n', p_n::text)) end;
$$;

create or replace function public._c413_closes_label(p_days integer)
returns text language sql stable
set search_path to 'public' as $$
  select case when coalesce(p_days, 0) <= 0 then public.ui_text('phx.window_closes_today')
              when p_days = 1               then public.ui_text('phx.window_closes_one')
              else public.ui_text_f('phx.window_closes_in',
                                    jsonb_build_object('n', p_days::text)) end;
$$;

-- ═══════════════════ 5. THE EXPIRY ENGINE (one resolver) ════════════════════
-- ONE place resolves a shelf row into "which bucket, worth how much, and when
-- does the money stop being recoverable". Every surface below reads it, so the
-- weekly WhatsApp digest and the screen can never disagree.
--
-- bucket_key: 'expired' | 'd30' | 'd60' | 'd90' | null (further out, or unknown)
create or replace function public._c413_rows(p_shop uuid)
returns table (
  stock_id uuid, product_id bigint, product_name text, pack_label text,
  batch_no text, expiry text, expiry_on date, qty numeric, unit_cost numeric,
  value_at_cost numeric, supplier_name text, supplier_key text,
  days_to_expiry integer, bucket_key text,
  opens_on date, closes_on date, days_to_close integer, window_state text,
  source_order_id uuid, source_order_item_id uuid)
language sql stable
set search_path to 'public' as $$
  with base as (
    select s.id, s.medicine_id as product_id, s.product_name, s.pack_label,
           s.batch_no, s.expiry,
           coalesce(s.expiry_on, public._c413_expiry_date(s.expiry)) as expiry_on,
           s.qty, s.unit_cost,
           nullif(btrim(coalesce(s.supplier_label, '')), '') as supplier_name,
           lower(btrim(coalesce(s.supplier_label, ''))) as supplier_key,
           s.first_order_id
      from public.pharmacy_stock s
     where s.pharmacy_id = p_shop
       and coalesce(s.qty, 0) > 0
  ), dated as (
    select b.*, (b.expiry_on - public._c413_today()) as dte
      from base b
     where b.expiry_on is not null
  )
  select d.id, d.product_id, d.product_name, d.pack_label, d.batch_no, d.expiry,
         d.expiry_on, d.qty, d.unit_cost,
         round(d.qty * d.unit_cost, 2) as value_at_cost,
         d.supplier_name, d.supplier_key,
         d.dte::integer,
         case when d.dte <  0 then 'expired'
              when d.dte <= 30 then 'd30'
              when d.dte <= 60 then 'd60'
              when d.dte <= 90 then 'd90'
         end as bucket_key,
         (d.expiry_on - w.opens_days)  as opens_on,
         (d.expiry_on - w.closes_days) as closes_on,
         ((d.expiry_on - w.closes_days) - public._c413_today())::integer as days_to_close,
         case
           when public._c413_today() >  (d.expiry_on - w.closes_days) then 'closed'
           when public._c413_today() <  (d.expiry_on - w.opens_days)  then 'not_open'
           else 'open'
         end as window_state,
         d.first_order_id,
         -- #412 records the ORDER a shelf row came from, not the order LINE.
         -- The line is what #395's returns engine needs, so resolve it here
         -- rather than making #412 carry a column for this command's sake.
         (select oi.id from public.order_items oi
           where oi.order_id = d.first_order_id
             and oi.product_id = d.product_id
           order by oi.created_at
           limit 1) as source_order_item_id
    from dated d
    cross join lateral public._c413_window(p_shop, d.supplier_name) w;
$$;

-- ── pharmacy_expiry_home: the whole screen from exactly one call ────────────
create or replace function public._c413_home(p_shop uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  v_90   numeric := 0;
  v_buckets jsonb;
  v_windows jsonb;
  v_head text;
begin

  select coalesce(sum(r.value_at_cost), 0) into v_90
    from public._c413_rows(v_shop) r
   where r.bucket_key in ('d30','d60','d90');

  -- Buckets in a fixed, meaningful order. A bucket with nothing in it is still
  -- rendered — an owner needs to see the zero to trust the ones that are not.
  select jsonb_agg(b order by b.ord) into v_buckets from (
    select 1 as ord, 'expired' as k, public.ui_text('phx.bucket_expired') as lbl union all
    select 2, 'd30', public.ui_text('phx.bucket_30') union all
    select 3, 'd60', public.ui_text('phx.bucket_60') union all
    select 4, 'd90', public.ui_text('phx.bucket_90')
  ) keys
  cross join lateral (
    select jsonb_build_object(
      'ord', keys.ord,
      'bucket_key', keys.k,
      'label',      keys.lbl,
      'item_count', count(r.stock_id),
      'count_label', public._c413_items_label(count(r.stock_id)),
      'value',      coalesce(sum(r.value_at_cost), 0),
      'value_display', public.inr_money(coalesce(sum(r.value_at_cost), 0)),
      'has',        count(r.stock_id) > 0,
      'tone',       case keys.k when 'expired' then 'danger'
                                when 'd30'     then 'danger'
                                when 'd60'     then 'warning'
                                else 'info' end) as b,
           keys.ord as ord
      from public._c413_rows(v_shop) r
     where r.bucket_key = keys.k
  ) b;

  -- The alert list: windows that are OPEN and closing, soonest first. A window
  -- that has already closed is not an alert — the money is gone and nagging
  -- about it is noise.
  select coalesce(jsonb_agg(x order by (x->>'days_to_close')::int), '[]'::jsonb)
    into v_windows
    from (
      select jsonb_build_object(
               'stock_id',      r.stock_id,
               'product_name',  r.product_name,
               'batch_label',   case when nullif(btrim(coalesce(r.batch_no,'')),'') is not null
                                     then public.ui_text('phx.batch_label') || ' ' || r.batch_no
                                     else public.ui_text('phx.no_batch') end,
               'expiry_label',  public.ui_text('phx.expiry_label') || ' ' || r.expiry,
               'supplier_label', coalesce(nullif(btrim(coalesce(r.supplier_name,'')),''),
                                          public.ui_text('phx.no_supplier')),
               'qty_label',     public._c413_qty(r.qty) || ' ' || public._c413_unit(r.product_id),
               'value_display', public.inr_money(r.value_at_cost),
               'days_to_close', r.days_to_close,
               'closes_label',  public._c413_closes_label(r.days_to_close),
               'tone',          case when r.days_to_close <= 14 then 'danger'
                                     when r.days_to_close <= 30 then 'warning'
                                     else 'info' end) as x
        from public._c413_rows(v_shop) r
       where r.window_state = 'open'
         and r.days_to_close <= 60
       order by r.days_to_close
       limit 50) q;

  v_head := case when v_90 > 0
                 then btrim(public.ui_text('phx.headline_prefix') || ' ' ||
                            public.inr_money(v_90) || ' ' ||
                            public.ui_text('phx.headline_suffix'))
                 else public.ui_text('phx.headline_clear') end;

  return jsonb_build_object(
    'ok', true,
    'title',        public.ui_text('phx.title'),
    'subtitle',     public.ui_text('phx.subtitle'),
    'headline',     v_head,
    'has_money',    v_90 > 0,
    'value_label',  public.ui_text('phx.value_label'),
    'cost_note',    public.ui_text('phx.cost_note'),
    'buckets',      coalesce(v_buckets, '[]'::jsonb),
    'window_title', public.ui_text('phx.window_title'),
    'window_note',  public.ui_text('phx.window_note'),
    'window_empty', public.ui_text('phx.window_empty'),
    'windows',      v_windows,
    'build_button', public.ui_text('phx.build_button'),
    'empty',        public.ui_text('phx.empty'),
    'empty_hint',   public.ui_text('phx.empty_hint'));
end $function$;

-- ── the rows behind one bucket ──────────────────────────────────────────────
create or replace function public._c413_items(
  p_shop uuid, p_bucket text, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  v_lim  integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_off  integer := greatest(coalesce(p_offset, 0), 0);
  v_items jsonb; v_total bigint;
begin

  select count(*) into v_total
    from public._c413_rows(v_shop) r where r.bucket_key = p_bucket;

  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_items from (
    select row_number() over (order by r.expiry_on, r.product_name) as ord,
           jsonb_build_object(
             'stock_id',      r.stock_id,
             'product_id',    r.product_id,
             'product_name',  r.product_name,
             'pack_label',    r.pack_label,
             'batch_label',   case when nullif(btrim(coalesce(r.batch_no,'')),'') is not null
                                   then public.ui_text('phx.batch_label') || ' ' || r.batch_no
                                   else public.ui_text('phx.no_batch') end,
             'expiry_label',  public.ui_text('phx.expiry_label') || ' ' || r.expiry,
             'supplier_label', coalesce(nullif(btrim(coalesce(r.supplier_name,'')),''),
                                        public.ui_text('phx.no_supplier')),
             'qty_label',     public._c413_qty(r.qty) || ' ' || public._c413_unit(r.product_id),
             'value_display', public.inr_money(r.value_at_cost),
             'window_state',  r.window_state,
             'window_label',  case r.window_state
                                when 'open'     then public._c413_closes_label(r.days_to_close)
                                when 'closed'   then public.ui_text('phx.window_shut_label')
                                else                 public.ui_text('phx.window_soon_label') end,
             'window_tone',   case r.window_state
                                when 'open'   then case when r.days_to_close <= 14 then 'danger'
                                                        when r.days_to_close <= 30 then 'warning'
                                                        else 'info' end
                                when 'closed' then 'neutral'
                                else 'neutral' end,
             'source_label',  case when r.source_order_id is not null
                                   then public.ui_text('phx.medibo_label')
                                   else public.ui_text('phx.outside_label') end,
             'from_medibo',   r.source_order_id is not null) as x
      from public._c413_rows(v_shop) r
     where r.bucket_key = p_bucket
     order by r.expiry_on, r.product_name
     limit v_lim offset v_off) q;

  return jsonb_build_object(
    'ok', true,
    'bucket_key', p_bucket,
    'title',      public.ui_text('phx.title'),
    'items',      v_items,
    'has_more',   (v_off + v_lim) < v_total,
    'next_offset', v_off + v_lim,
    'count_label', public._c413_items_label(v_total),
    'empty',      public.ui_text('phx.empty'),
    'empty_hint', public.ui_text('phx.empty_hint'),
    'more_button', public.ui_text('phx.more_button'),
    'cost_note',  public.ui_text('phx.cost_note'));
end $function$;

-- ═════════════ 6. ONE TAP: THE RETURN LIST, AND THE mediBO PATH ═════════════
-- What the owner actually wants is not a report, it is a list they can hand to
-- the supplier's collection boy. So the list is BUILT, stored, and — for the
-- rows that came from a mediBO order — raised straight onto the existing
-- returns engine (#395's `order_return_add`) with the order, the line, the
-- quantity and the reason already filled in. Nothing is retyped.
--
-- Only rows whose window is OPEN go on the list. A closed window is not a
-- return, it is a write-off, and putting it on the sheet wastes the trip.

create or replace function public._c413_return_build(p_shop uuid, p_bucket text default 'window', p_actor uuid default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  v_list uuid;
  v_n integer; v_val numeric;
  v_b text := coalesce(nullif(btrim(p_bucket), ''), 'window');
begin
  -- Ask FIRST, write second. Writing a list header and deleting it again when
  -- it turns out empty is how a "nothing to return" answer became a foreign-key
  -- exception for any shop id that is not a real pharmacy.
  select count(*), coalesce(sum(r.value_at_cost), 0) into v_n, v_val
    from public._c413_rows(v_shop) r
   where r.window_state = 'open'
     and (v_b in ('window', 'all')
          or r.bucket_key = v_b
          or (v_b = 'd90' and r.bucket_key in ('d30','d60','d90')));

  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'nothing_to_return',
                              'message', public.ui_text('phx.err_nothing'));
  end if;

  insert into public.pharmacy_return_list
    (pharmacy_id, bucket, created_by, item_count, value_at_cost)
  values (v_shop, v_b, p_actor, v_n, round(v_val, 2))
  returning id into v_list;

  insert into public.pharmacy_return_list_item
    (list_id, stock_id, product_id, product_name, batch_no, expiry, qty, unit_cost,
     value_at_cost, supplier_name, closes_on, source_order_id, source_order_item_id,
     medibo_qty)
  -- A shelf row can hold 40 strips of which only 5 ever came through mediBO —
  -- the rest were bought locally. The pre-filled quantity is therefore the
  -- RETURNS ENGINE's own returnable number, capped by what is actually on the
  -- shelf. Asking it to take back 40 would be refused, correctly, and the owner
  -- would learn nothing from the refusal.
  select v_list, r.stock_id, r.product_id, r.product_name, r.batch_no, r.expiry,
         r.qty, r.unit_cost, r.value_at_cost, r.supplier_name, r.closes_on,
         r.source_order_id, r.source_order_item_id,
         case when r.source_order_item_id is not null
              then least(r.qty, public._return_returnable_qty(r.source_order_item_id))
         end
    from public._c413_rows(v_shop) r
   where r.window_state = 'open'
     and (v_b in ('window', 'all')
          or r.bucket_key = v_b
          or (v_b = 'd90' and r.bucket_key in ('d30','d60','d90')));

  return public._c413_return_get(v_shop, v_list);
end $function$;

create or replace function public._c413_return_get(p_shop uuid, p_list_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  l public.pharmacy_return_list%rowtype;
  v_groups jsonb; v_can_send boolean;
begin

  select * into l from public.pharmacy_return_list
   where id = p_list_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'list_not_found',
                              'message', public.ui_text('phx.err_no_list'));
  end if;

  -- Grouped by supplier, because that is how the stock physically leaves.
  select coalesce(jsonb_agg(g order by g->>'supplier_label'), '[]'::jsonb)
    into v_groups from (
    select jsonb_build_object(
             'supplier_label', coalesce(nullif(btrim(coalesce(i.supplier_name,'')),''),
                                        public.ui_text('phx.no_supplier')),
             'item_count',    count(*),
             'count_label',   public._c413_items_label(count(*)),
             'value_display', public.inr_money(sum(i.value_at_cost)),
             'items', jsonb_agg(jsonb_build_object(
                 'item_id',       i.id,
                 'product_name',  i.product_name,
                 'batch_label',   case when nullif(btrim(coalesce(i.batch_no,'')),'') is not null
                                       then public.ui_text('phx.batch_label') || ' ' || i.batch_no
                                       else public.ui_text('phx.no_batch') end,
                 'expiry_label',  public.ui_text('phx.expiry_label') || ' ' || coalesce(i.expiry, ''),
                 'qty_label',     public._c413_qty(i.qty) || ' ' || public._c413_unit(i.product_id),
                 'value_display', public.inr_money(i.value_at_cost),
                 'from_medibo',   i.source_order_item_id is not null
                                    and coalesce(i.medibo_qty, 0) > 0,
                 'medibo_qty_label', case
                    when i.source_order_item_id is null then null
                    when coalesce(i.medibo_qty, 0) > 0
                      then public.ui_text_f('phx.medibo_qty_label',
                             jsonb_build_object('n', public._c413_qty(i.medibo_qty)))
                    else public.ui_text('phx.medibo_qty_none') end,
                 'source_label',  case when i.source_order_item_id is not null
                                       then public.ui_text('phx.medibo_label')
                                       else public.ui_text('phx.outside_label') end,
                 'source_hint',   case when i.source_order_item_id is not null then null
                                       else public.ui_text('phx.outside_hint') end,
                 'medibo_status', i.medibo_status,
                 'medibo_message', i.medibo_message)
               order by i.product_name)) as g
      from public.pharmacy_return_list_item i
     where i.list_id = l.id
     group by coalesce(nullif(btrim(coalesce(i.supplier_name,'')),''),
                       public.ui_text('phx.no_supplier'))) q;

  select exists (select 1 from public.pharmacy_return_list_item i
                  where i.list_id = l.id and i.source_order_item_id is not null
                    and coalesce(i.medibo_qty, 0) > 0
                    and i.medibo_return_id is null)
    into v_can_send;

  return jsonb_build_object(
    'ok', true,
    'list_id',       l.id,
    'title',         public.ui_text('phx.list_title'),
    'status',        l.status,
    'item_count',    l.item_count,
    'count_label',   public._c413_items_label(l.item_count),
    'value_display', public.inr_money(l.value_at_cost),
    'value_label',   public.ui_text('phx.value_label'),
    'cost_note',     public.ui_text('phx.cost_note'),
    'groups',        v_groups,
    'can_send',      v_can_send,
    'photo_required', coalesce((select o.requires_photo from public.order_reason_option o
                                 where o.scope = 'return' and o.code = 'expired' and o.active), false),
    'photo_label',   public.ui_text('phx.photo_label'),
    'photo_hint',    public.ui_text('phx.photo_hint'),
    'pending_note',  public.ui_text('phx.pending_note'),
    'send_button',   public.ui_text('phx.send_button'),
    'sending',       public.ui_text('phx.sending'),
    'empty',         public.ui_text('phx.list_empty'));
end $function$;

-- Raise every mediBO-sourced line on the existing returns engine. #395 owns the
-- money — the slab, the PTR, the GST and the credit note are its arithmetic, not
-- this file's. All this does is stop the owner retyping an order line they
-- already have. A line the engine refuses keeps the engine's OWN message; this
-- command never invents a second wording for the same refusal.
create or replace function public._c413_return_send(p_shop uuid, p_list_id uuid, p_photo_path text default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  l public.pharmacy_return_list%rowtype;
  it record; v_res jsonb; v_ok integer := 0; v_skip integer := 0;
begin

  select * into l from public.pharmacy_return_list
   where id = p_list_id and pharmacy_id = v_shop for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'list_not_found',
                              'message', public.ui_text('phx.err_no_list'));
  end if;
  if l.status = 'sent' then
    return jsonb_build_object('ok', false, 'error', 'already_sent',
                              'message', public.ui_text('phx.err_already_sent'));
  end if;

  for it in
    select * from public.pharmacy_return_list_item
     where list_id = l.id and source_order_item_id is not null
       and coalesce(medibo_qty, 0) > 0
       and medibo_return_id is null
  loop
    begin
      v_res := public.order_return_add(
                 it.source_order_id, it.source_order_item_id, it.medibo_qty,
                 'expired', 'sealed',
                 'Expiry return raised from the shop expiry watch (CMD #413)',
                 nullif(btrim(coalesce(p_photo_path, '')), ''), null, null);
    exception when others then
      v_res := jsonb_build_object('ok', false, 'message', sqlerrm);
    end;

    if coalesce((v_res->>'ok')::boolean, false) then
      v_ok := v_ok + 1;
      update public.pharmacy_return_list_item
         set medibo_return_id = nullif(v_res->>'id','')::uuid,
             medibo_status    = 'raised',
             medibo_message   = v_res->>'message'
       where id = it.id;
    else
      v_skip := v_skip + 1;
      update public.pharmacy_return_list_item
         set medibo_status  = 'refused',
             medibo_message = coalesce(v_res->>'message', v_res->>'error')
       where id = it.id;
    end if;
  end loop;

  if v_ok > 0 then
    update public.pharmacy_return_list set status = 'sent', sent_at = now() where id = l.id;
  end if;

  return public._c413_return_get(v_shop, l.id)
         || jsonb_build_object('raised', v_ok, 'refused', v_skip,
                               'toast', case when v_ok > 0 then public.ui_text('phx.sent_toast')
                                             else public.ui_text('phx.err_nothing') end);
end $function$;

create or replace function public._c413_lists(p_shop uuid, p_limit integer default 20)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := p_shop;
begin
  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('phx.list_title'),
    'empty', public.ui_text('phx.list_empty'),
    'lists', coalesce((
      select jsonb_agg(jsonb_build_object(
               'list_id',       l.id,
               'count_label',   public._c413_items_label(l.item_count),
               'value_display', public.inr_money(l.value_at_cost),
               'status',        l.status,
               'date_label',    to_char(l.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY'))
             order by l.created_at desc)
        from (select * from public.pharmacy_return_list
               where pharmacy_id = v_shop
               order by created_at desc
               limit least(greatest(coalesce(p_limit,20),1),100)) l), '[]'::jsonb));
end $function$;

-- ═════════════════ 7. THE WATCHER (#305 dispatcher, not a cron) ═════════════
-- Two pings, both dedupe-logged so a re-run cannot storm a shop:
--   * weekly digest — once per shop per ISO week, only when there is money in
--     the 90-day window worth walking to the shelf for.
--   * urgent near-window — once per shop per PRODUCT per IST day, only while the
--     window is open and closing inside the shop's own urgent_days.
-- The gate lives in `cron_task.gate_sql`, so on a quiet day the dispatcher does
-- not even call this function.

create or replace function public.pharmacy_expiry_scan(p_limit integer default 40)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  sh record; v_sent integer := 0; v_urgent integer := 0;
  v_week text := to_char(public._c413_today(), 'IYYY-"W"IW');
  v_val numeric; v_n integer; v_ph text; v_cfg record; v_top record;
begin
  for sh in
    select pp.id, pp.pharmacy_name,
           right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),
                                '\D', '', 'g'), 10) as phone
      from public.pharmacy_profiles pp
     where coalesce(pp.is_deleted, false) = false
       and coalesce(pp.approved, false)
       and exists (select 1 from public.pharmacy_stock s
                    where s.pharmacy_id = pp.id and coalesce(s.qty,0) > 0)
     order by pp.id
     limit greatest(coalesce(p_limit, 40), 1)
  loop
    select coalesce(c.digest_enabled, true) as digest_enabled,
           coalesce(c.urgent_days, 14)      as urgent_days
      into v_cfg
      from (select 1) one
      left join public.pharmacy_expiry_config c on c.pharmacy_id = sh.id;

    v_ph := nullif(sh.phone, '');

    -- 1. the weekly digest
    if v_cfg.digest_enabled then
      select count(*), coalesce(sum(r.value_at_cost), 0) into v_n, v_val
        from public._c413_rows(sh.id) r
       where r.bucket_key in ('d30','d60','d90');

      if v_n > 0 and not exists (
           select 1 from public.pharmacy_expiry_alert_log
            where pharmacy_id = sh.id and kind = 'weekly_digest' and dedupe_key = v_week)
      then
        insert into public.pharmacy_expiry_alert_log (pharmacy_id, kind, dedupe_key, detail)
        values (sh.id, 'weekly_digest', v_week,
                jsonb_build_object('items', v_n, 'value', v_val))
        on conflict do nothing;

        perform public.notify('pharmacy_expiry_digest', v_ph, jsonb_build_object(
          'customer_id', sh.id::text,
          'shop',   coalesce(sh.pharmacy_name, ''),
          'value',  public.inr_money(v_val),
          'items',  v_n::text));
        v_sent := v_sent + 1;
      end if;
    end if;

    -- 2. the urgent near-window ping — the single most valuable row only, so a
    --    shop with forty expiring batches still gets one message, not forty.
    select r.stock_id, r.product_name, r.batch_no, r.days_to_close, r.value_at_cost,
           coalesce(nullif(btrim(coalesce(r.supplier_name,'')),''),
                    public.ui_text('phx.no_supplier')) as supplier
      into v_top
      from public._c413_rows(sh.id) r
     where r.window_state = 'open'
       and r.days_to_close <= v_cfg.urgent_days
     order by r.value_at_cost desc, r.days_to_close
     limit 1;

    if v_top.stock_id is not null and not exists (
         select 1 from public.pharmacy_expiry_alert_log
          where pharmacy_id = sh.id and kind = 'urgent_window'
            and dedupe_key = v_top.stock_id::text || ':' || public._c413_today()::text)
    then
      insert into public.pharmacy_expiry_alert_log (pharmacy_id, kind, dedupe_key, detail)
      values (sh.id, 'urgent_window',
              v_top.stock_id::text || ':' || public._c413_today()::text,
              jsonb_build_object('product', v_top.product_name,
                                 'days', v_top.days_to_close,
                                 'value', v_top.value_at_cost))
      on conflict do nothing;

      perform public.notify('pharmacy_expiry_urgent', v_ph, jsonb_build_object(
        'customer_id', sh.id::text,
        'product',  v_top.product_name,
        'batch',    coalesce(nullif(btrim(coalesce(v_top.batch_no,'')),''), '-'),
        'supplier', v_top.supplier,
        'days',     greatest(v_top.days_to_close, 0)::text,
        'value',    public.inr_money(v_top.value_at_cost)));
      v_urgent := v_urgent + 1;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'digests', v_sent, 'urgent', v_urgent);
end $function$;

insert into public.wa_event_routes (event_key, label, description, audience, enabled)
values
  ('pharmacy_expiry_digest', 'Pharmacy weekly expiry summary',
   'CMD #413 — once per shop per ISO week: how much shelf stock expires within 90 days, valued at cost.',
   'customer', true),
  ('pharmacy_expiry_urgent', 'Pharmacy return window closing',
   'CMD #413 — the single highest-value batch whose supplier return window closes inside the shop''s urgent window.',
   'customer', true)
on conflict (event_key) do nothing;

insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, enabled, base_interval_s, max_interval_s, dml, note)
values
  ('pharmacy_expiry_watch', 413, 'poll',
   $gate$select exists (select 1 from public.pharmacy_stock where coalesce(qty,0) > 0)$gate$,
   'select public.pharmacy_expiry_scan(40)',
   true, 3600, 21600, true,
   'CMD #413 — weekly digest (once per shop per ISO week) plus one urgent near-window ping per shop per day. The dedupe ledger is pharmacy_expiry_alert_log, so a re-run is a no-op.')
on conflict (name) do update
  set gate_sql = excluded.gate_sql,
      work_sql = excluded.work_sql,
      note     = excluded.note,
      enabled  = excluded.enabled;

-- ══════════════════════ 8. THE THEFT RADAR (owner only) ═════════════════════
-- Expected closing = opening + received − sold, against what was physically
-- counted. Every one of those four numbers is derivable without a movement
-- ledger this command does not own:
--   sold     — pos_sale_lines inside the window (the POS is the only till)
--   received — pharmacy_stock rows whose received_at falls inside the window
--   opening  — the last submitted count for that product, if there is one;
--              otherwise the book quantity reconstructed backwards to the
--              window start (book_now − received + sold), which is the same
--              number the shelf would have had.
-- So the FIRST count in a shop compares against the book, and every count after
-- it compares against the previous physical count. That is how a stock check is
-- run on paper, and it is why the second count is worth more than the first.

create or replace function public._c413_expected(p_shop uuid, p_from timestamptz)
returns table (
  product_id bigint, product_name text, pack_label text, unit_cost numeric,
  opening_qty numeric, received_qty numeric, sold_qty numeric, expected_qty numeric)
language sql stable
set search_path to 'public' as $$
  with book as (
    select s.medicine_id as product_id, min(s.product_name) as product_name, min(s.pack_label) as pack_label,
           sum(coalesce(s.qty,0)) as qty_now,
           case when sum(coalesce(s.qty,0)) > 0
                then round(sum(coalesce(s.qty,0) * coalesce(s.unit_cost,0))
                           / nullif(sum(coalesce(s.qty,0)), 0), 2)
                else coalesce(max(s.unit_cost), 0) end as unit_cost
      from public.pharmacy_stock s
     where s.pharmacy_id = p_shop
     group by s.medicine_id
  ), recv as (
    select s.medicine_id as product_id, sum(coalesce(s.qty,0)) as qty
      from public.pharmacy_stock s
     where s.pharmacy_id = p_shop
       and coalesce(s.received_on, s.created_at::date) >= (p_from at time zone 'Asia/Kolkata')::date
     group by s.medicine_id
  ), sold as (
    select l.medicine_id as product_id, sum(coalesce(l.qty,0)) as qty
      from public.pos_sale_lines l
      join public.pos_sales sa on sa.id = l.sale_id
     where sa.pharmacy_id = p_shop and sa.status = 'completed' and sa.sold_at >= p_from
     group by l.medicine_id
  ), last_count as (
    select distinct on (cl.product_id) cl.product_id, cl.counted_qty
      from public.pharmacy_count_line cl
      join public.pharmacy_count_session cs on cs.id = cl.session_id
     where cs.pharmacy_id = p_shop and cs.status = 'submitted'
       and cl.counted_qty is not null and cs.submitted_at <= p_from
     order by cl.product_id, cs.submitted_at desc
  )
  select b.product_id, b.product_name, b.pack_label, b.unit_cost,
         coalesce(lc.counted_qty,
                  b.qty_now - coalesce(rc.qty, 0) + coalesce(sd.qty, 0)) as opening_qty,
         coalesce(rc.qty, 0) as received_qty,
         coalesce(sd.qty, 0) as sold_qty,
         coalesce(lc.counted_qty,
                  b.qty_now - coalesce(rc.qty, 0) + coalesce(sd.qty, 0))
           + coalesce(rc.qty, 0) - coalesce(sd.qty, 0) as expected_qty
    from book b
    left join recv rc       on rc.product_id is not distinct from b.product_id
    left join sold sd       on sd.product_id is not distinct from b.product_id
    left join last_count lc on lc.product_id is not distinct from b.product_id;
$$;

-- ── the spot count: pick N random SKUs and count them ───────────────────────
-- Random, not "the ones you suspect" — a count you choose is a count you can
-- steer. The expected number is computed AT PICK TIME and stored on the line,
-- but it is never returned to the caller until the count is submitted.
create or replace function public._c413_count_start(p_shop uuid, p_n integer default 10, p_actor uuid default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  v_n integer := least(greatest(coalesce(p_n, 10), 1), 50);
  v_from timestamptz;
  v_sess uuid; v_rows integer;
begin

  -- The window starts at the last submitted count, or seven days back for a
  -- shop that has never counted.
  select coalesce(max(cs.submitted_at), now() - interval '7 days') into v_from
    from public.pharmacy_count_session cs
   where cs.pharmacy_id = v_shop and cs.status = 'submitted';

  insert into public.pharmacy_count_session (pharmacy_id, window_from, started_by)
  values (v_shop, v_from, p_actor) returning id into v_sess;

  insert into public.pharmacy_count_line
    (session_id, product_id, product_name, pack_label, unit_cost,
     opening_qty, received_qty, sold_qty, expected_qty)
  select v_sess, e.product_id, e.product_name, e.pack_label, e.unit_cost,
         e.opening_qty, e.received_qty, e.sold_qty, e.expected_qty
    from public._c413_expected(v_shop, v_from) e
   order by random()
   limit v_n
  on conflict do nothing;

  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    delete from public.pharmacy_count_session where id = v_sess;
    return jsonb_build_object('ok', false, 'error', 'no_stock',
                              'message', public.ui_text('phv.err_no_stock'));
  end if;

  update public.pharmacy_count_session set sku_count = v_rows where id = v_sess;
  return public._c413_count_detail(v_shop, v_sess);
end $function$;

-- The count sheet before submission, and the variance report after it. ONE
-- function, because they are the same screen: what changes is what the backend
-- is willing to show, and that decision is made here, not in Dart.
create or replace function public._c413_count_detail(p_shop uuid, p_session_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  cs public.pharmacy_count_session%rowtype;
  v_lines jsonb; v_open boolean; v_attr jsonb;
begin

  select * into cs from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'session_not_found',
                              'message', public.ui_text('phv.err_no_session'));
  end if;
  v_open := cs.status = 'open';

  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_lines from (
    select row_number() over (order by cl.product_name) as ord,
           jsonb_build_object(
             'line_id',      cl.id,
             'product_id',   cl.product_id,
             'product_name', cl.product_name,
             'pack_label',   cl.pack_label,
             'unit',         public._c413_unit(cl.product_id),
             -- OPEN: nothing but the name and a box to write in. Showing the
             -- expected number before the count turns a count into a copy.
             'counted_qty',  cl.counted_qty,
             'has_expected', not v_open,
             'opening_label',  case when v_open then null else public._c413_qty(cl.opening_qty)  end,
             'received_label', case when v_open then null else public._c413_qty(cl.received_qty) end,
             'sold_label',     case when v_open then null else public._c413_qty(cl.sold_qty)     end,
             'expected_label', case when v_open then null else public._c413_qty(cl.expected_qty) end,
             'counted_label',  case when v_open then null else public._c413_qty(cl.counted_qty)  end,
             'variance_label', case when v_open then null
                                    else (case when coalesce(cl.variance_qty,0) > 0 then '+' else '' end)
                                         || public._c413_qty(cl.variance_qty) end,
             'variance_value_display', case when v_open then null
                                            else public.inr_money(abs(coalesce(cl.variance_value,0))) end,
             'state_label',  case when v_open then null
                                  when coalesce(cl.variance_qty,0) = 0 then public.ui_text('phv.match_label')
                                  when cl.variance_qty < 0 then public.ui_text('phv.short_label')
                                  else public.ui_text('phv.over_label') end,
             'tone',         case when v_open then 'neutral'
                                  when coalesce(cl.variance_qty,0) = 0 then 'success'
                                  when cl.variance_qty < 0 then 'danger'
                                  else 'warning' end) as x
      from public.pharmacy_count_line cl
     where cl.session_id = cs.id
     order by cl.product_name) q;

  select coalesce(jsonb_agg(x order by (x->>'sort_value')::numeric desc), '[]'::jsonb)
    into v_attr from (
    select jsonb_build_object(
             'staff_label',    case when g.staff = '' then public.ui_text('phv.staff_unnamed')
                                    else g.staff end,
             'sold_label',     public._c413_qty(g.sold),
             'share_label',    trim_scale(round(g.share, 1))::text || '%',
             'variance_label', public._c413_qty(g.var_qty),
             'value_display',  public.inr_money(abs(g.var_val)),
             'sort_value',     abs(g.var_val)) as x
      from (select coalesce(a.staff_label, '') as staff,
                   sum(a.sold_qty) as sold,
                   100.0 * sum(abs(a.variance_value))
                     / nullif(sum(sum(abs(a.variance_value))) over (), 0) as share,
                   sum(a.variance_qty) as var_qty, sum(a.variance_value) as var_val
              from public.pharmacy_count_attribution a
             where a.session_id = cs.id
             group by coalesce(a.staff_label, '')) g) q;

  return jsonb_build_object(
    'ok', true,
    'session_id',   cs.id,
    'status',       cs.status,
    'is_open',      v_open,
    'title',        case when v_open then public.ui_text('phv.sheet_title')
                         else public.ui_text('phv.title') end,
    'subtitle',     public.ui_text('phv.subtitle'),
    'hint',         case when v_open then public.ui_text('phv.sheet_hint') else null end,
    'cause_note',   case when v_open then null else public.ui_text('phv.cause_note') end,
    'sku_count',    cs.sku_count,
    'lines',        v_lines,
    'labels', jsonb_build_object(
      'counted',  public.ui_text('phv.counted_label'),
      'expected', public.ui_text('phv.expected_label'),
      'opening',  public.ui_text('phv.opening_label'),
      'received', public.ui_text('phv.received_label'),
      'sold',     public.ui_text('phv.sold_label'),
      'variance', public.ui_text('phv.variance_label')),
    'submit_button', public.ui_text('phv.submit_button'),
    'submitting',    public.ui_text('phv.submitting'),
    'variance_units_label', case when v_open then null
                                 else public._c413_qty(cs.variance_units) end,
    'leaked_label',   public.ui_text('phv.leaked_label'),
    'leaked_display', case when v_open then null
                           else public.inr_money(abs(cs.variance_value)) end,
    'all_matched',    (not v_open) and cs.variance_units = 0,
    'clean_message',  public.ui_text('phv.report_clean'),
    'staff_title',    public.ui_text('phv.staff_title'),
    'staff_note',     public.ui_text('phv.staff_note'),
    'staff_empty',    public.ui_text('phv.staff_empty'),
    'staff',          case when v_open then '[]'::jsonb else v_attr end);
end $function$;

-- Submit. p_lines: [{line_id, counted_qty}] — a line left out is left
-- UNCOUNTED (variance null), never defaulted to zero. "I did not count it" and
-- "I counted zero" are different facts and the report must not conflate them.
create or replace function public._c413_count_submit(p_shop uuid, p_session_id uuid, p_lines jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  cs public.pharmacy_count_session%rowtype;
  v_n integer;
begin

  select * into cs from public.pharmacy_count_session
   where id = p_session_id and pharmacy_id = v_shop for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'session_not_found',
                              'message', public.ui_text('phv.err_no_session'));
  end if;
  if cs.status = 'submitted' then
    return jsonb_build_object('ok', false, 'error', 'already_submitted',
                              'message', public.ui_text('phv.err_done'));
  end if;

  update public.pharmacy_count_line cl
     set counted_qty    = (e->>'counted_qty')::numeric,
         variance_qty   = (e->>'counted_qty')::numeric - cl.expected_qty,
         variance_value = round(((e->>'counted_qty')::numeric - cl.expected_qty) * cl.unit_cost, 2),
         counted_at     = now()
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e
   where cl.session_id = cs.id
     and cl.id = nullif(e->>'line_id','')::uuid
     and nullif(e->>'counted_qty','') is not null;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_lines',
                              'message', public.ui_text('phv.err_no_lines'));
  end if;

  -- Attribution. Each staff member's SHARE of what was sold of that product in
  -- the window carries the same share of the difference. A product nobody sold
  -- in the window gets no attribution row at all — an unattributed difference
  -- is honest, and inventing an owner for it would not be.
  insert into public.pharmacy_count_attribution
    (session_id, line_id, staff_user_id, staff_label, sold_qty, share_pct,
     variance_qty, variance_value)
  select cs.id, cl.id, t.staff_user_id, t.staff_label, t.qty,
         round(100.0 * t.qty / nullif(tot.qty, 0), 2),
         round(coalesce(cl.variance_qty,0) * t.qty / nullif(tot.qty, 0), 3),
         round(coalesce(cl.variance_value,0) * t.qty / nullif(tot.qty, 0), 2)
    from public.pharmacy_count_line cl
    join lateral (
      select l.medicine_id, sa.staff_user_id,
             coalesce(max(sa.staff_label), '') as staff_label,
             sum(coalesce(l.qty,0)) as qty
        from public.pos_sale_lines l
        join public.pos_sales sa on sa.id = l.sale_id
       where sa.pharmacy_id = v_shop and sa.status = 'completed'
         and sa.sold_at >= cs.window_from
         and l.medicine_id is not distinct from cl.product_id
       group by l.medicine_id, sa.staff_user_id) t on true
    join lateral (
      select sum(coalesce(l.qty,0)) as qty
        from public.pos_sale_lines l
        join public.pos_sales sa on sa.id = l.sale_id
       where sa.pharmacy_id = v_shop and sa.status = 'completed'
         and sa.sold_at >= cs.window_from
         and l.medicine_id is not distinct from cl.product_id) tot on true
   where cl.session_id = cs.id
     and cl.counted_qty is not null
     and coalesce(cl.variance_qty, 0) <> 0
     and coalesce(tot.qty, 0) > 0;

  update public.pharmacy_count_session s
     set status = 'submitted', submitted_at = now(),
         variance_units = coalesce((select sum(coalesce(cl.variance_qty,0))
                                      from public.pharmacy_count_line cl
                                     where cl.session_id = s.id), 0),
         variance_value = coalesce((select sum(coalesce(cl.variance_value,0))
                                      from public.pharmacy_count_line cl
                                     where cl.session_id = s.id), 0)
   where s.id = cs.id;

  return public._c413_count_detail(v_shop, cs.id)
         || jsonb_build_object('toast', public.ui_text('phv.submitted_toast'));
end $function$;

-- ── the report: "14 strips Dolo unaccounted this week" ──────────────────────
-- Every headline sentence is built HERE, unit noun included, so Dart never
-- pluralises and never picks a word.
create or replace function public._c413_variance(p_shop uuid, p_days integer default 7)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := p_shop;
  v_days integer := least(greatest(coalesce(p_days, 7), 1), 180);
  v_from timestamptz := now() - make_interval(days => v_days);
  v_items jsonb; v_staff jsonb; v_val numeric := 0; v_sessions integer := 0;
begin

  select count(*), coalesce(sum(cs.variance_value), 0) into v_sessions, v_val
    from public.pharmacy_count_session cs
   where cs.pharmacy_id = v_shop and cs.status = 'submitted' and cs.submitted_at >= v_from;

  -- Per product, worst first. The sentence is the whole point of the screen.
  select coalesce(jsonb_agg(x order by (x->>'sort_value')::numeric desc), '[]'::jsonb)
    into v_items from (
    select jsonb_build_object(
             'product_id',   cl.product_id,
             'product_name', min(cl.product_name),
             'headline',     public.ui_text_f(
                               case when sum(coalesce(cl.variance_qty,0)) < 0
                                    then 'phv.line_short' else 'phv.line_over' end,
                               jsonb_build_object(
                                 'qty',     public._c413_qty(abs(sum(coalesce(cl.variance_qty,0)))),
                                 'unit',    public._c413_unit(cl.product_id),
                                 'product', min(cl.product_name))),
             'value_display', public.inr_money(abs(sum(coalesce(cl.variance_value,0)))),
             'counts_label',  public._c413_items_label(count(*)),
             'tone',          case when sum(coalesce(cl.variance_qty,0)) < 0
                                   then 'danger' else 'warning' end,
             'sort_value',    abs(sum(coalesce(cl.variance_value,0)))) as x
      from public.pharmacy_count_line cl
      join public.pharmacy_count_session cs on cs.id = cl.session_id
     where cs.pharmacy_id = v_shop and cs.status = 'submitted'
       and cs.submitted_at >= v_from
       and coalesce(cl.variance_qty, 0) <> 0
     group by cl.product_id
    having sum(coalesce(cl.variance_qty,0)) <> 0) q;

  -- The trend per staff member: this window against the one before it, so a
  -- number that is coming down is visibly coming down.
  select coalesce(jsonb_agg(x order by (x->>'sort_value')::numeric desc), '[]'::jsonb)
    into v_staff from (
    select jsonb_build_object(
             'staff_label',    case when g.staff = '' then public.ui_text('phv.staff_unnamed')
                                    else g.staff end,
             'variance_label', public._c413_qty(g.var_qty),
             'value_display',  public.inr_money(abs(g.var_val)),
             'share_label',    trim_scale(round(g.share, 1))::text || '%',
             'trend_label',    public.ui_text_f('phv.trend_line', jsonb_build_object(
                                 'now',  public.inr_money(abs(g.var_val)),
                                 'prev', public.inr_money(abs(coalesce((
                                   select sum(a2.variance_value)
                                     from public.pharmacy_count_attribution a2
                                     join public.pharmacy_count_session s2 on s2.id = a2.session_id
                                    where s2.pharmacy_id = v_shop and s2.status = 'submitted'
                                      and s2.submitted_at >= v_from - make_interval(days => v_days)
                                      and s2.submitted_at <  v_from
                                      and coalesce(a2.staff_label, '') = g.staff), 0))))),
             'sort_value',     abs(g.var_val)) as x
      from (
        select coalesce(a.staff_label, '') as staff,
               sum(a.variance_qty)         as var_qty,
               sum(a.variance_value)       as var_val,
               100.0 * sum(abs(a.variance_value))
                 / nullif(sum(sum(abs(a.variance_value))) over (), 0) as share
          from public.pharmacy_count_attribution a
          join public.pharmacy_count_session cs on cs.id = a.session_id
         where cs.pharmacy_id = v_shop and cs.status = 'submitted'
           and cs.submitted_at >= v_from
         group by coalesce(a.staff_label, '')) g) q;

  return jsonb_build_object(
    'ok', true,
    'title',         public.ui_text('phv.title'),
    'subtitle',      public.ui_text('phv.subtitle'),
    'period_label',  public.ui_text('phv.report_title'),
    'sessions',      v_sessions,
    'has',           jsonb_array_length(v_items) > 0,
    'items',         v_items,
    'leaked_label',  public.ui_text('phv.leaked_label'),
    'leaked_display', public.inr_money(abs(v_val)),
    'clean_message', public.ui_text('phv.report_clean'),
    'empty',         public.ui_text('phv.report_empty'),
    'empty_hint',    public.ui_text('phv.report_empty_hint'),
    'cause_note',    public.ui_text('phv.cause_note'),
    'staff_title',   public.ui_text('phv.staff_title'),
    'staff_note',    public.ui_text('phv.staff_note'),
    'staff_empty',   public.ui_text('phv.staff_empty'),
    'trend_title',   public.ui_text('phv.trend_title'),
    'staff',         v_staff,
    'start_button',  public.ui_text('phv.start_button'),
    'starting',      public.ui_text('phv.starting'));
end $function$;

-- ── the entry point, so the app never guesses who may see what ──────────────
create or replace function public.pharmacy_shield_entry()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop(); v_owner boolean;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false, 'tiles', '[]'::jsonb); end if;
  v_owner := public._c413_is_owner(v_shop);
  return jsonb_build_object(
    'ok', true, 'show', true, 'is_owner', v_owner,
    'tiles', jsonb_build_array(
      jsonb_build_object(
        'route_key', 'pharmacy_expiry', 'icon_key', 'schedule',
        'label',     public.ui_text('phx.nav_label'),
        'sub_label', public.ui_text('phx.subtitle'))) ||
      case when v_owner then jsonb_build_array(
        jsonb_build_object(
          'route_key', 'pharmacy_variance', 'icon_key', 'fact_check',
          'label',     public.ui_text('phv.nav_label'),
          'sub_label', public.ui_text('phv.subtitle'),
          'note',      public.ui_text('phv.owner_only_note')))
           else '[]'::jsonb end);
end $function$;

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, deep_link,
   roles_allowed, description)
values
  ('admin.pharmacy_expiry', 'Expiry watch', 'Pharmacy tools', 'schedule',
   'pharmacy_expiry', 4130, 'medibo', false, 'none', true, 'parties', 'dashboard',
   null, array['admin','super_admin'],
   'CMD #413 — 30/60/90 day expiry buckets valued at cost, supplier return windows, one-tap return list.'),
  ('admin.pharmacy_variance', 'Stock check', 'Pharmacy tools', 'fact_check',
   'pharmacy_variance', 4131, 'medibo', false, 'none', true, 'parties', 'dashboard',
   null, array['admin','super_admin'],
   'CMD #413 — owner-only spot count: expected closing against counted, per shift.')
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key,
      deep_link = excluded.deep_link, description = excluded.description,
      is_active = excluded.is_active;

-- ══════════ 8b. THE PUBLIC DOOR — the shop check and the owner check ════════
-- Each builder above is pure: give it a shop and it returns that shop's payload.
-- These wrappers are the ONLY thing that decides which shop you are and whether
-- you are its owner, so there is exactly one place to read that fence, and the
-- proof below can drive the very same builders with an explicit shop instead of
-- a second copy of the logic that would be free to drift.

create or replace function public.pharmacy_expiry_home()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phx.err_not_pharmacy'); end if;
  return public._c413_home(v_shop);
end $function$;

create or replace function public.pharmacy_expiry_items(
  p_bucket text, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phx.err_not_pharmacy'); end if;
  return public._c413_items(v_shop, p_bucket, p_limit, p_offset);
end $function$;

create or replace function public.pharmacy_expiry_return_build(p_bucket text default 'window')
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phx.err_not_pharmacy'); end if;
  return public._c413_return_build(v_shop, coalesce(nullif(btrim(p_bucket), ''), 'window'), auth.uid());
end $function$;

create or replace function public.pharmacy_expiry_return_get(p_list_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phx.err_not_pharmacy'); end if;
  return public._c413_return_get(v_shop, p_list_id);
end $function$;

create or replace function public.pharmacy_expiry_return_send(
  p_list_id uuid, p_photo_path text default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phx.err_not_pharmacy'); end if;
  return public._c413_return_send(v_shop, p_list_id, p_photo_path);
end $function$;

create or replace function public.pharmacy_expiry_lists(p_limit integer default 20)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phx.err_not_pharmacy'); end if;
  return public._c413_lists(v_shop, p_limit);
end $function$;

-- ── the three owner-only doors ──────────────────────────────────────────────
create or replace function public.pharmacy_count_start(p_n integer default 10)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phv.err_not_pharmacy'); end if;
  if not public._c413_is_owner(v_shop) then return public._c413_denied('phv.err_not_owner'); end if;
  return public._c413_count_start(v_shop, p_n, auth.uid());
end $function$;

create or replace function public.pharmacy_count_detail(p_session_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phv.err_not_pharmacy'); end if;
  if not public._c413_is_owner(v_shop) then return public._c413_denied('phv.err_not_owner'); end if;
  return public._c413_count_detail(v_shop, p_session_id);
end $function$;

create or replace function public.pharmacy_count_submit(p_session_id uuid, p_lines jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phv.err_not_pharmacy'); end if;
  if not public._c413_is_owner(v_shop) then return public._c413_denied('phv.err_not_owner'); end if;
  return public._c413_count_submit(v_shop, p_session_id, p_lines);
end $function$;

create or replace function public.pharmacy_variance_report(p_days integer default 7)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c413_shop();
begin
  if v_shop is null then return public._c413_denied('phv.err_not_pharmacy'); end if;
  if not public._c413_is_owner(v_shop) then return public._c413_denied('phv.err_not_owner'); end if;
  return public._c413_variance(v_shop, p_days);
end $function$;

-- ══════════════ 8c. THE PROOF DRIVER (service_role only) ════════════════════
-- Drives the REAL builders for one shop, end to end, and returns everything the
-- proof script asserts on in one payload. It cannot be reached by anon or by
-- `authenticated` — the grant fence below closes it with the rest of the
-- internals — so it adds no surface while making the flows provable.
create or replace function public.c413_proof_run(p_shop uuid)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_list jsonb; v_sent jsonb; v_sheet jsonb; v_sub jsonb; v_lines jsonb;
begin
  v_list := public._c413_return_build(p_shop, 'window', null);
  if coalesce((v_list->>'ok')::boolean, false) then
    -- the same one tap the screen makes, photo attached
    v_sent := public._c413_return_send(p_shop, (v_list->>'list_id')::uuid,
                                       'dev-cmd-proofs/c413/batch.jpg');
  end if;

  v_sheet := public._c413_count_start(p_shop, 6, null);
  if coalesce((v_sheet->>'ok')::boolean, false) then
    -- count every picked line 2 units SHORT of the book, which is what a real
    -- short count looks like, then submit exactly those lines.
    select jsonb_agg(jsonb_build_object(
             'line_id', cl.id,
             'counted_qty', greatest(cl.expected_qty - 2, 0)))
      into v_lines
      from public.pharmacy_count_line cl
     where cl.session_id = (v_sheet->>'session_id')::uuid;
    v_sub := public._c413_count_submit(p_shop, (v_sheet->>'session_id')::uuid, v_lines);
  end if;

  return jsonb_build_object(
    'home',       public._c413_home(p_shop),
    'items_d30',  public._c413_items(p_shop, 'd30', 50, 0),
    'list',       v_list,
    'sent',       v_sent,
    'sheet_open', v_sheet,
    'submitted',  v_sub,
    'report',     public._c413_variance(p_shop, 7));
end $function$;

-- ═══════════════════════════ 9. THE GRANT FENCE ═════════════════════════════
-- A new function inherits Postgres's GRANT TO PUBLIC, and `anon` ships in the
-- bundle. Revoke everything in this family from everyone, then hand back only
-- the caller-facing door. The internals stay closed: a SECURITY DEFINER
-- function runs as its owner, so pharmacy_expiry_home() calling _c413_rows() is
-- checked against postgres, never against the caller.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like '\_c413\_%'
            or p.proname like 'pharmacy\_expiry\_%'
            or p.proname like 'pharmacy\_count\_%'
            or p.proname like 'pharmacy\_variance\_%'
            or p.proname like 'pharmacy\_shield\_%'
            or p.proname like 'c413\_%')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('revoke all on function %s from authenticated', r.sig);
  end loop;
end $$;

grant execute on function public.pharmacy_shield_entry()                        to authenticated;
grant execute on function public.pharmacy_expiry_home()                         to authenticated;
grant execute on function public.pharmacy_expiry_items(text, integer, integer)  to authenticated;
grant execute on function public.pharmacy_expiry_return_build(text)             to authenticated;
grant execute on function public.pharmacy_expiry_return_get(uuid)               to authenticated;
grant execute on function public.pharmacy_expiry_return_send(uuid, text)        to authenticated;
grant execute on function public.pharmacy_expiry_lists(integer)                 to authenticated;
grant execute on function public.pharmacy_count_start(integer)                  to authenticated;
grant execute on function public.pharmacy_count_detail(uuid)                    to authenticated;
grant execute on function public.pharmacy_count_submit(uuid, jsonb)             to authenticated;
grant execute on function public.pharmacy_variance_report(integer)              to authenticated;

-- The watcher belongs to the dispatcher alone.
grant execute on function public.pharmacy_expiry_scan(integer)                  to service_role;

-- ── the security reporter the proof script asserts on ───────────────────────
create or replace function public.c413_qa_report()
returns jsonb language sql stable security definer
set search_path to 'public' as $$
  select jsonb_build_object(
    'rls_off', coalesce((select string_agg(tablename, ',' order by tablename)
                           from pg_tables
                          where schemaname = 'public'
                            and (tablename like 'pharmacy\_expiry\_%'
                                 or tablename like 'pharmacy\_return\_%'
                                 or tablename like 'pharmacy\_count\_%'
                                 or tablename = 'pharmacy_stock')
                            and not rowsecurity), 'all_on'),
    'anon_fns', coalesce((select string_agg(p.proname, ',' order by p.proname)
                            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                           where n.nspname = 'public'
                             and (p.proname like '\_c413\_%'
                                  or p.proname like 'pharmacy\_expiry\_%'
                                  or p.proname like 'pharmacy\_count\_%'
                                  or p.proname like 'pharmacy\_variance\_%'
                                  or p.proname like 'pharmacy\_shield\_%')
                             and has_function_privilege('anon', p.oid, 'EXECUTE')), 'none'),
    'internal_open', coalesce((select string_agg(p.proname, ',' order by p.proname)
                                 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                where n.nspname = 'public'
                                  and (p.proname like '\_c413\_%'
                                       or p.proname = 'pharmacy_expiry_scan')
                                  and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
                              'closed'));
$$;
revoke all on function public.c413_qa_report() from public, anon, authenticated;
grant execute on function public.c413_qa_report() to service_role;
grant execute on function public.c413_proof_run(uuid) to service_role;
