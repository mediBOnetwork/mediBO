-- CMD #423 — TIER 0 BILL VAULT. The foundation of the zero-setup pharmacy layer.
--
-- THE PROBLEM THIS SOLVES. A Tier-0 pharmacy has no desktop, no billing
-- software and no export. What it does have — always, without exception, by
-- law — is a drawer of purchase bills. So the bill IS the database. Every path
-- in this file turns a bill into LOTS, and the lot ledger is the inventory.
--
-- THIS REVISES THE SUBSTRATE UNDER #412. #412 built the lot ledger and one way
-- to fill it: a delivered mediBO order. That path is not replaced — it is
-- promoted to INTAKE PATH 1 of a vault that now has three doors:
--
--   A. mediBO purchase   — auto-lands on delivery. Zero taps. (#412's trigger,
--      wrapped so it also writes the BILL the lots came from.)
--   B. outside bill photo — the distributor's own invoice, photographed at the
--      counter, read by the existing Gemini door, landing in this pharmacy's
--      own account with a human-review lane for anything the camera was not
--      sure about.
--   C. bulk back-import  — a shoebox of ~120 bills queued in one sitting,
--      processed asynchronously, organised month-wise, progress visible the
--      whole time. This is how three years of history arrives in an afternoon.
--
--   ...plus a COLD-START door: a photo of the rack itself, which seeds the
--   visible products as UNQUANTIFIED lots so the ledger is useful on day one.
--
-- ONE LEDGER, NOT TWO (decision, logged). The spec names `pharmacy_lots`.
-- There is already a physical lot table — `pharmacy_stock` — and #413 (expiry),
-- #414 (reorder/margin), #416 (GST) and #418 (rx-to-bill) all read it. A second
-- physical lot table would fork the pharmacy's inventory into two truths and
-- silently break four shipped commands. So `pharmacy_lots` is a VIEW over
-- `pharmacy_stock`, carrying the vault's own columns (bill_id, bill_line_id,
-- is_unquantified). One ledger. The name the spec asked for. Nothing forked.
--
-- ONE BILL TABLE, NOT TWO (decision, logged). Likewise `pharmacy_bills`: #416
-- created `pharmacy_purchase_bill` for the GST purchase register and builds
-- GSTR-2 style output from it. The vault EXTENDS that table instead of standing
-- a rival beside it, so a bill photographed into the vault appears in the GST
-- register automatically — no bridge, no second source of truth, and dedupe
-- protects both at once.
--
-- THE CAMERA IS NOT A DATABASE. Every OCR path here proposes; a human confirms.
-- An unreadable line is FLAGGED, never invented — that is the difference
-- between a tool a pharmacist trusts and one they switch off in week two. The
-- OCR naming rule holds throughout: what is printed is what is stored, verbatim,
-- with no expansion and no world knowledge.
--
-- IDEMPOTENT THROUGHOUT. Every DDL is `if not exists` / `create or replace`,
-- every apply goes through `_phs_apply`'s (ref_kind, ref_id) uniqueness, and the
-- dedupe index makes a re-uploaded bill a no-op rather than a double count. A
-- resumed worker re-running this file changes nothing.

-- ═══════════════════════ 1. THE VAULT HEADER ═══════════════════════════════
-- pharmacy_purchase_bill, promoted from "a GST register row" to "the bill".

alter table public.pharmacy_purchase_bill
  add column if not exists source           text not null default 'photo',
  add column if not exists order_id         uuid,
  add column if not exists batch_id         uuid,
  add column if not exists month_key        date,
  add column if not exists dedupe_key       text,
  add column if not exists duplicate_of     uuid,
  add column if not exists shot_count       integer not null default 0,
  add column if not exists confidence       numeric,
  add column if not exists review_reason    text,
  add column if not exists line_count       integer not null default 0,
  add column if not exists unreadable_count integer not null default 0,
  add column if not exists review_count     integer not null default 0,
  add column if not exists total_taxable    numeric,
  add column if not exists total_tax        numeric,
  add column if not exists total_amount     numeric,
  add column if not exists queued_at        timestamptz,
  add column if not exists read_at          timestamptz,
  add column if not exists applied_at       timestamptz;

comment on column public.pharmacy_purchase_bill.source is
  'Which vault door this bill came through: medibo (auto, on delivery), photo (an outside bill), shelf (a cold-start rack shot).';
comment on column public.pharmacy_purchase_bill.dedupe_key is
  'supplier GSTIN (or normalised supplier name) | invoice no | invoice date. Unique per pharmacy — a re-upload matches instead of double-counting.';
comment on column public.pharmacy_purchase_bill.month_key is
  'First of the invoice month, IST. The bulk back-import organises by this.';

-- DEDUPE (spec 4). The identity of a purchase invoice is the party that issued
-- it plus its number plus its date. GSTIN is the strong key; a distributor with
-- no GSTIN on the bill falls back to its normalised name, which is still stable
-- for the one pharmacy that keeps buying from it. Punctuation and case are
-- stripped because "INV/2026/0041", "inv-2026-0041" and "INV 2026 0041" are one
-- invoice photographed three times.
create or replace function public._phv_dedupe_key(
  p_gstin text, p_inv text, p_date date, p_supplier text)
returns text language sql immutable as $$
  select case
    when nullif(btrim(coalesce(p_inv, '')), '') is null then null
    else coalesce(
           nullif(upper(regexp_replace(coalesce(p_gstin, ''), '[^A-Za-z0-9]', '', 'g')), ''),
           'n:' || public._norm_name(coalesce(p_supplier, '')))
         || '|' || upper(regexp_replace(p_inv, '[^A-Za-z0-9]', '', 'g'))
         || '|' || coalesce(p_date::text, '~')
  end;
$$;

-- A bill parked as `duplicate` keeps its key for the audit trail but must not
-- hold the slot, so the uniqueness is partial.
create unique index if not exists phv_bill_dedupe_uq
  on public.pharmacy_purchase_bill (pharmacy_id, dedupe_key)
  where dedupe_key is not null and status <> 'duplicate';

create index if not exists phv_bill_shop_month
  on public.pharmacy_purchase_bill (pharmacy_id, month_key desc nulls last, invoice_date desc nulls last);
create index if not exists phv_bill_batch
  on public.pharmacy_purchase_bill (batch_id) where batch_id is not null;
create index if not exists phv_bill_queued
  on public.pharmacy_purchase_bill (status, queued_at) where status in ('queued', 'processing');
create index if not exists phv_bill_order
  on public.pharmacy_purchase_bill (order_id) where order_id is not null;

-- ═══════════════════════ 2. MULTI-SHOT CAPTURE (spec 3) ════════════════════
-- A thermal roll is a metre long and a carbon copy is grey on grey. One frame
-- is not a bill; the pharmacist walks down it taking three or four. They are
-- all shots of ONE bill and are read together, in order.
create table if not exists public.pharmacy_bill_shot (
  id         uuid primary key default gen_random_uuid(),
  bill_id    uuid not null references public.pharmacy_purchase_bill(id) on delete cascade,
  shot_no    integer not null,
  bucket     text not null,
  path       text not null,
  status     text not null default 'queued',   -- queued | read | unreadable
  note       text,
  created_at timestamptz not null default now(),
  unique (bill_id, shot_no)
);
alter table public.pharmacy_bill_shot enable row level security;
create index if not exists phv_shot_bill on public.pharmacy_bill_shot (bill_id, shot_no);

-- ═══════════════════════ 3. THE BILL LINE, WITH ITS DOUBTS ═════════════════
-- #416's line carried what the GST register needs. A lot needs more: the batch,
-- the expiry, what it actually cost per unit — and, crucially, HOW SURE the
-- camera was about each of those, field by field.
alter table public.pharmacy_purchase_bill_line
  add column if not exists batch_no     text,
  add column if not exists expiry       text,
  add column if not exists expiry_on    date,
  add column if not exists free_qty     numeric,
  add column if not exists unit_cost    numeric,
  add column if not exists mrp          numeric,
  add column if not exists gst_percent  numeric,
  add column if not exists pack_label   text,
  add column if not exists medicine_id  bigint,
  add column if not exists match_status text not null default 'unmatched',
  add column if not exists match_score  numeric,
  add column if not exists match_source text,
  add column if not exists field_conf   jsonb not null default '{}'::jsonb,
  add column if not exists confidence   numeric,
  add column if not exists readable     boolean not null default true,
  add column if not exists flag         text not null default 'ok',
  add column if not exists review_note  text,
  add column if not exists lot_id       uuid;

comment on column public.pharmacy_purchase_bill_line.flag is
  'ok | unreadable (the camera could not read this line and did not guess) | low_confidence | unmatched (read fine, no product) — the review lane is everything that is not ok.';
comment on column public.pharmacy_purchase_bill_line.field_conf is
  'Per-field confidence 0..1 as the model reported it, e.g. {"qty":0.4,"batch":0.95}. A field under threshold is shown for confirmation, never silently trusted.';

create unique index if not exists phv_line_uq on public.pharmacy_purchase_bill_line (bill_id, line_no);
create index if not exists phv_line_flag  on public.pharmacy_purchase_bill_line (bill_id) where flag <> 'ok';

-- ═══════════════════════ 4. THE BULK SESSION (spec 2c) ═════════════════════
create table if not exists public.pharmacy_bill_batch (
  id          uuid primary key default gen_random_uuid(),
  pharmacy_id uuid not null,
  label       text,
  status      text not null default 'open',    -- open | running | done | cancelled
  total       integer not null default 0,
  done        integer not null default 0,
  failed      integer not null default 0,
  review      integer not null default 0,
  duplicate   integer not null default 0,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);
alter table public.pharmacy_bill_batch enable row level security;
create index if not exists phv_batch_shop on public.pharmacy_bill_batch (pharmacy_id, created_at desc);

-- ═══════════════════════ 5. LOTS CARRY THEIR BILL ══════════════════════════
alter table public.pharmacy_stock
  add column if not exists bill_id         uuid,
  add column if not exists bill_line_id    uuid,
  add column if not exists is_unquantified boolean not null default false;

comment on column public.pharmacy_stock.is_unquantified is
  'A cold-start lot seeded from a shelf photo: we know the shop HAS this, we do not know how many. It is a real row so it can be counted, never a number we invented.';

create index if not exists phv_stock_bill on public.pharmacy_stock (bill_id) where bill_id is not null;

-- THE NAMES THE SPEC ASKED FOR. security_invoker so both views inherit the base
-- tables' RLS exactly — a pharmacy sees its own vault and nothing else, and a
-- direct client SELECT here returns zero rows just as it does on the tables.
create or replace view public.pharmacy_bills with (security_invoker = true) as
  select b.id, b.pharmacy_id, b.source, b.supplier_name, b.supplier_gstin,
         b.invoice_no, b.invoice_date, b.month_key, b.status, b.dedupe_key,
         b.duplicate_of, b.batch_id, b.order_id, b.shot_count, b.confidence,
         b.line_count, b.unreadable_count, b.review_count,
         b.total_taxable, b.total_tax, b.total_amount,
         b.bucket, b.path, b.ocr_error, b.review_reason,
         b.created_by, b.created_at, b.queued_at, b.read_at,
         b.confirmed_at, b.applied_at
    from public.pharmacy_purchase_bill b;

create or replace view public.pharmacy_lots with (security_invoker = true) as
  select s.id as lot_id, s.pharmacy_id, s.medicine_id, s.product_name,
         s.pack_label, s.item_key, s.batch_no, s.expiry, s.expiry_on,
         s.qty, s.unit_cost, s.mrp, s.source_kind as source,
         s.supplier_label, s.bill_id, s.bill_line_id, s.is_unquantified,
         s.received_on, s.created_at, s.updated_at
    from public.pharmacy_stock s;

revoke all on public.pharmacy_bills, public.pharmacy_lots from anon;
grant select on public.pharmacy_bills, public.pharmacy_lots to authenticated;

-- ═══════════════════════ 6. SKU MATCHING (spec 5) ══════════════════════════
--
-- "Montikop", "Monticope 10", "MONTEK-LC", "montek lc tab" — four distributors,
-- four spellings, one product. Matching them is the difference between an
-- inventory and a pile of strings.
--
-- FOUR RUNGS, cheapest first, and the ladder STOPS at the first confident hit:
--   1. ALIAS      — this pharmacy already told us what this exact printed text
--                   means. Free, exact, and it gets better every confirmation.
--   2. EXACT      — the normalised name is a catalogue name. `_norm_name` is
--                   #412's own normaliser, so the vault and the shelf agree.
--   3. TRIGRAM    — index-backed similarity over `_norm_name(product_name)`
--                   (idx_medicine_name_norm_trgm already exists), with the
--                   pharmacy's OWN shelf preferred over the 563k catalogue,
--                   because what it bought before is what it is buying now.
--   4. VECTOR     — pgvector cosine over sku_embedding, which catches what
--                   letters cannot: a transposition, a phonetic Hindi-English
--                   spelling, a brand written as its salt.
--
-- WHY EMBEDDINGS ARE LAZY (decision, logged). Embedding all 563k MEDICINE rows
-- would be a multi-hour Vertex bill against a 1 GB instance for a table whose
-- long tail a pharmacy never buys. Instead the queue embeds only what is
-- actually seen: the bill texts that reached rung 4, and the ~40 trigram
-- candidates each one raises. The vector index therefore covers exactly the
-- neighbourhood of real purchasing, and it grows itself.
--
-- BELOW THRESHOLD IS A HUMAN, NOT A GUESS. Rung 3 and 4 hits under
-- `phv.match_confirm` are stored WITH their score and flagged for review. The
-- pharmacist's answer writes an alias, so the same distributor's same spelling
-- is rung 1 forever after.

create table if not exists public.pharmacy_sku_alias (
  id          bigserial primary key,
  pharmacy_id uuid,                            -- null = learned for everyone
  alias_key   text   not null,
  medicine_id bigint not null,
  source      text   not null default 'confirm',  -- confirm | manual | seed
  hits        integer not null default 1,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.pharmacy_sku_alias enable row level security;
create unique index if not exists phv_alias_uq on public.pharmacy_sku_alias
  (coalesce(pharmacy_id, '00000000-0000-0000-0000-000000000000'::uuid), alias_key);
create index if not exists phv_alias_key on public.pharmacy_sku_alias (alias_key);

create table if not exists public.sku_embedding (
  text_key    text primary key,
  raw_text    text,
  medicine_id bigint,
  embedding   vector(768),
  model       text,
  built_at    timestamptz not null default now()
);
alter table public.sku_embedding enable row level security;
create index if not exists sku_embedding_med on public.sku_embedding (medicine_id)
  where medicine_id is not null;

-- HNSW over cosine. Built on an empty table, so it costs nothing now and is
-- ready when the queue starts filling it.
do $$
begin
  if not exists (select 1 from pg_class where relname = 'sku_embedding_hnsw') then
    execute 'create index sku_embedding_hnsw on public.sku_embedding using hnsw (embedding vector_cosine_ops)';
  end if;
exception when others then
  raise warning 'c423: hnsw index not built (%) — cosine still works as a scan', sqlerrm;
end $$;

create table if not exists public.sku_embed_queue (
  text_key    text primary key,
  raw_text    text not null,
  medicine_id bigint,
  status      text not null default 'queued',   -- queued | done | failed
  tries       integer not null default 0,
  error       text,
  created_at  timestamptz not null default now()
);
alter table public.sku_embed_queue enable row level security;
create index if not exists sku_embed_queue_pending on public.sku_embed_queue (status, created_at)
  where status = 'queued';

-- Config in one row, so a threshold is an UPDATE and never a deploy.
create table if not exists public.pharmacy_vault_config (
  id                boolean primary key default true check (id),
  match_confirm     numeric not null default 0.86,  -- at or above: matched outright
  match_suggest     numeric not null default 0.55,  -- at or above: suggested, needs a human
  field_confirm     numeric not null default 0.70,  -- per-field OCR confidence floor
  bulk_max          integer not null default 120,   -- photos in one back-import sitting
  sweep_batch       integer not null default 4,     -- bills started per dispatcher tick
  embed_batch       integer not null default 32,
  candidates        integer not null default 40,
  shelf_max_items   integer not null default 60,
  updated_at        timestamptz not null default now()
);
alter table public.pharmacy_vault_config enable row level security;
insert into public.pharmacy_vault_config (id) values (true) on conflict (id) do nothing;

create or replace function public._phv_cfg()
returns public.pharmacy_vault_config
language sql stable security definer set search_path = public as $$
  select * from public.pharmacy_vault_config where id;
$$;

-- Queue a name for embedding. Cheap, idempotent, and never blocks the caller.
create or replace function public._phv_embed_want(p_text text, p_medicine_id bigint default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_key text := public._norm_name(coalesce(p_text, ''));
begin
  if length(v_key) < 2 then return; end if;
  if exists (select 1 from public.sku_embedding where text_key = v_key) then return; end if;
  insert into public.sku_embed_queue (text_key, raw_text, medicine_id)
  values (v_key, btrim(p_text), p_medicine_id)
  on conflict (text_key) do nothing;
end $$;

-- THE LADDER. Returns the decision and its evidence; it never writes a lot and
-- never invents a product.
create or replace function public._phv_match(
  p_shop uuid, p_text text, p_pack text default null)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cfg   public.pharmacy_vault_config := public._phv_cfg();
  v_key   text := public._norm_name(coalesce(p_text, ''));
  v_id    bigint;
  v_name  text;
  v_score numeric;
  v_vec   vector(768);
begin
  if length(v_key) < 2 then
    return jsonb_build_object('status', 'unmatched', 'source', 'empty', 'score', 0);
  end if;

  -- 1. ALIAS — this shop's own answer first, then anything learned globally.
  select a.medicine_id into v_id
    from public.pharmacy_sku_alias a
   where a.alias_key = v_key
     and (a.pharmacy_id = p_shop or a.pharmacy_id is null)
   order by (a.pharmacy_id = p_shop) desc, a.hits desc
   limit 1;
  if v_id is not null then
    select m.product_name into v_name from public."MEDICINE" m where m.id = v_id;
    return jsonb_build_object('status', 'matched', 'source', 'alias', 'score', 1.0,
                              'medicine_id', v_id, 'product_name', v_name);
  end if;

  -- 2. EXACT on the catalogue's normalised name.
  select m.id, m.product_name into v_id, v_name
    from public."MEDICINE" m
   where public._norm_name(m.product_name) = v_key
   order by coalesce(m.sales_count, 0) desc
   limit 1;
  if v_id is not null then
    return jsonb_build_object('status', 'matched', 'source', 'exact', 'score', 1.0,
                              'medicine_id', v_id, 'product_name', v_name);
  end if;

  -- 3a. THIS SHOP'S OWN SHELF. What it already stocks beats the whole
  --     catalogue: the same distributor prints the same abbreviation forever.
  select s.medicine_id, s.product_name,
         round(similarity(s.name_key, 'n:' || v_key)::numeric, 4)
    into v_id, v_name, v_score
    from public.pharmacy_stock s
   where s.pharmacy_id = p_shop
     and s.medicine_id is not null
     and s.name_key % ('n:' || v_key)
   order by similarity(s.name_key, 'n:' || v_key) desc
   limit 1;
  if v_id is not null and v_score >= v_cfg.match_confirm then
    return jsonb_build_object('status', 'matched', 'source', 'shelf', 'score', v_score,
                              'medicine_id', v_id, 'product_name', v_name);
  end if;

  -- 3b. TRIGRAM over the catalogue, index-backed.
  select c.id, c.product_name, c.sim into v_id, v_name, v_score
    from (
      select m.id, m.product_name,
             round(similarity(public._norm_name(m.product_name), v_key)::numeric, 4) sim,
             coalesce(m.sales_count, 0) sc
        from public."MEDICINE" m
       where public._norm_name(m.product_name) % v_key
       order by similarity(public._norm_name(m.product_name), v_key) desc,
                coalesce(m.sales_count, 0) desc
       limit v_cfg.candidates
    ) c
   order by c.sim desc, c.sc desc
   limit 1;

  if v_id is not null and v_score >= v_cfg.match_confirm then
    return jsonb_build_object('status', 'matched', 'source', 'fuzzy', 'score', v_score,
                              'medicine_id', v_id, 'product_name', v_name);
  end if;

  -- 4. VECTOR. Only if this text has already been embedded; the caller queues
  --    it either way, so the SECOND look at the same spelling has the answer.
  select e.embedding into v_vec from public.sku_embedding e where e.text_key = v_key;
  if v_vec is not null then
    declare
      v_vid bigint; v_vname text; v_vscore numeric;
    begin
      select e.medicine_id, m.product_name,
             round((1 - (e.embedding <=> v_vec))::numeric, 4)
        into v_vid, v_vname, v_vscore
        from public.sku_embedding e
        join public."MEDICINE" m on m.id = e.medicine_id
       where e.medicine_id is not null and e.text_key <> v_key
       order by e.embedding <=> v_vec
       limit 1;
      if v_vid is not null and v_vscore > coalesce(v_score, 0) then
        v_id := v_vid; v_name := v_vname; v_score := v_vscore;
        if v_score >= v_cfg.match_confirm then
          return jsonb_build_object('status', 'matched', 'source', 'vector', 'score', v_score,
                                    'medicine_id', v_id, 'product_name', v_name);
        end if;
      end if;
    end;
  end if;

  -- Under the bar. A suggestion is offered WITH its score and goes to a human;
  -- nothing below match_suggest is even suggested.
  if v_id is not null and coalesce(v_score, 0) >= v_cfg.match_suggest then
    return jsonb_build_object('status', 'suggested', 'source', 'fuzzy', 'score', v_score,
                              'medicine_id', v_id, 'product_name', v_name);
  end if;
  return jsonb_build_object('status', 'unmatched', 'source', 'none',
                            'score', coalesce(v_score, 0));
end $$;

-- A confirmation teaches the ladder. Called from the review lane.
create or replace function public._phv_alias_learn(
  p_shop uuid, p_text text, p_medicine_id bigint, p_source text default 'confirm')
returns void language plpgsql security definer set search_path = public as $$
declare v_key text := public._norm_name(coalesce(p_text, ''));
begin
  if length(v_key) < 2 or p_medicine_id is null or p_shop is null then return; end if;
  insert into public.pharmacy_sku_alias (pharmacy_id, alias_key, medicine_id, source)
  values (p_shop, v_key, p_medicine_id, coalesce(p_source, 'confirm'))
  on conflict (coalesce(pharmacy_id, '00000000-0000-0000-0000-000000000000'::uuid), alias_key)
  do update set medicine_id = excluded.medicine_id,
                hits = public.pharmacy_sku_alias.hits + 1,
                updated_at = now();
end $$;

create index if not exists phv_stock_name_trgm
  on public.pharmacy_stock using gin (name_key gin_trgm_ops);

-- ═══════════════════════ 7. INTAKE PATH A — mediBO, ZERO TAPS ══════════════
--
-- #412 already lands the LOTS the moment a rider's proof arrives. What it did
-- not do is record the BILL those lots came off, so the vault had a hole
-- exactly where its most trustworthy data was. This wraps that intake: the
-- order becomes a vault bill (source 'medibo', already confirmed — mediBO's own
-- delivery is not a photograph anyone needs to check), its lines become bill
-- lines already matched to catalogue ids, and #412's lot writer runs unchanged.
--
-- Nothing about #412's behaviour moves. `pharmacy_stock_ingest_order` is called
-- exactly as before, still idempotent, still the only thing that writes a lot.

create or replace function public.pharmacy_vault_ingest_order(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_shop   uuid;
  v_date   date;
  v_bill   uuid;
  v_inv    text;
  v_lots   jsonb;
  v_it     record;
  v_n      integer := 0;
  v_tax    numeric := 0;
  v_amt    numeric := 0;
  v_line   uuid;
begin
  select o.customer_id,
         coalesce(o.order_date, (o.created_at at time zone 'Asia/Kolkata')::date),
         coalesce(nullif(btrim(o.order_code), ''), left(p_order_id::text, 8))
    into v_shop, v_date, v_inv
    from public.orders o where o.id = p_order_id;

  if v_shop is null then
    return jsonb_build_object('ok', true, 'skipped', 'no_pharmacy');
  end if;

  -- The bill first, so every lot below can point at it.
  select id into v_bill from public.pharmacy_purchase_bill
   where pharmacy_id = v_shop and order_id = p_order_id;

  if v_bill is null then
    insert into public.pharmacy_purchase_bill (
      pharmacy_id, source, order_id, supplier_name, invoice_no, invoice_date,
      month_key, status, dedupe_key, confidence, confirmed_at, queued_at, read_at)
    values (
      v_shop, 'medibo', p_order_id, 'mediBO', v_inv, v_date,
      date_trunc('month', v_date)::date, 'confirmed',
      public._phv_dedupe_key('MEDIBO', v_inv, v_date, 'mediBO'),
      1.0, now(), now(), now())
    on conflict (pharmacy_id, dedupe_key) where dedupe_key is not null and status <> 'duplicate'
      do update set order_id = excluded.order_id
    returning id into v_bill;
  end if;

  -- Lines. Verbatim from the order, matched by catalogue id — there is nothing
  -- to guess here, which is exactly why this path costs the pharmacy no taps.
  for v_it in
    select oi.id, oi.product_id, oi.product_name, oi.quantity, oi.received_qty,
           oi.packed_qty, oi.price, oi.mrp, oi.batch_no, oi.expiry,
           oi.gst_percent, sl.batch_no as lot_batch, sl.expiry as lot_expiry,
           m.pack_size, m.pack_type
      from public.order_items oi
      left join public.stock_lot sl on sl.id = oi.stock_lot_id
      left join public."MEDICINE" m on m.id = oi.product_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable, false) = false
     order by oi.id
  loop
    v_n := v_n + 1;
    insert into public.pharmacy_purchase_bill_line (
      bill_id, line_no, raw, product_name, qty, rate, taxable,
      batch_no, expiry, unit_cost, mrp, gst_percent, pack_label,
      medicine_id, match_status, match_score, match_source,
      confidence, readable, flag)
    values (
      v_bill, v_n,
      jsonb_build_object('order_item_id', v_it.id),
      v_it.product_name,
      coalesce(nullif(v_it.packed_qty, 0), nullif(v_it.received_qty, 0), v_it.quantity, 0),
      v_it.price,
      round(coalesce(v_it.price, 0) * coalesce(nullif(v_it.packed_qty, 0),
            nullif(v_it.received_qty, 0), v_it.quantity, 0), 2),
      coalesce(nullif(btrim(coalesce(v_it.batch_no, '')), ''), v_it.lot_batch),
      coalesce(nullif(btrim(coalesce(v_it.expiry, '')), ''), v_it.lot_expiry),
      v_it.price, v_it.mrp, v_it.gst_percent,
      nullif(btrim(coalesce(v_it.pack_size, v_it.pack_type, '')), ''),
      v_it.product_id,
      case when v_it.product_id is not null then 'matched' else 'unmatched' end,
      case when v_it.product_id is not null then 1.0 else 0 end,
      'medibo', 1.0, true, 'ok')
    on conflict do nothing
    returning id into v_line;

    v_amt := v_amt + round(coalesce(v_it.price, 0) *
             coalesce(nullif(v_it.packed_qty, 0), nullif(v_it.received_qty, 0), v_it.quantity, 0), 2);
  end loop;

  -- #412's intake, untouched. It is still the only writer of a lot.
  v_lots := public.pharmacy_stock_ingest_order(p_order_id);

  -- Point the lots this order produced at the bill they came off.
  update public.pharmacy_stock s
     set bill_id = v_bill
   where s.pharmacy_id = v_shop
     and s.first_order_id = p_order_id
     and s.bill_id is null;

  update public.pharmacy_purchase_bill
     set line_count = v_n, total_amount = v_amt, total_taxable = v_amt,
         applied_at = coalesce(applied_at, now())
   where id = v_bill;

  return jsonb_build_object('ok', true, 'bill_id', v_bill, 'lines', v_n,
                            'lots', v_lots -> 'lots');
end $$;

-- The rider's proof now fills the vault, not just the shelf. Same guard as
-- #412: a shelf that cannot be written must NEVER stop the delivery being
-- recorded, and the intake stays re-runnable.
create or replace function public._phs_delivery_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.delivered_at is not null
     and (tg_op = 'INSERT' or old.delivered_at is distinct from new.delivered_at)
     and new.order_id is not null then
    begin
      perform public.pharmacy_vault_ingest_order(new.order_id);
    exception when others then
      raise warning 'pharmacy_vault: intake failed for order % — %', new.order_id, sqlerrm;
      begin
        perform public.pharmacy_stock_ingest_order(new.order_id);
      exception when others then
        raise warning 'pharmacy_stock: intake failed for order % — %', new.order_id, sqlerrm;
      end;
    end;
  end if;
  return new;
end $$;

-- ═══════════════════════ 8. INTAKE PATHS B & C — THE PHOTO DOOR ════════════
--
-- One pipeline serves both: a single bill photographed at the counter, and a
-- shoebox of 120 photographed in one sitting. The only difference is whether a
-- batch id is attached and whether the read happens now or on the sweep — so
-- there is one set of RPCs, one OCR contract and one review lane, not two.

create or replace function public._phv_shop() returns uuid
language sql stable as $$ select public.my_customer_id(); $$;

create or replace function public._phv_denied() returns jsonb
language sql stable as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('phvault.err_not_pharmacy'));
$$;

-- A month bucket the screen can print without doing date arithmetic in Dart.
create or replace function public._phv_month_label(p_month date)
returns text language sql stable as $$
  select case when p_month is null then public.ui_text('phvault.month_unknown')
              else to_char(p_month, 'FMMonth YYYY') end;
$$;

-- ─── the bulk sitting ───────────────────────────────────────────────────────
create or replace function public.pharmacy_vault_batch_start(p_label text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phv_shop(); v_id uuid;
begin
  if v_shop is null then return public._phv_denied(); end if;
  insert into public.pharmacy_bill_batch (pharmacy_id, label, created_by)
  values (v_shop, nullif(btrim(coalesce(p_label, '')), ''), auth.uid())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'batch_id', v_id,
    'max', (public._phv_cfg()).bulk_max,
    'message', public.ui_text('phvault.batch_started'));
end $$;

-- ─── one bill, one or many shots ────────────────────────────────────────────
create or replace function public.pharmacy_vault_bill_start(
  p_source text default 'photo', p_batch_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phv_shop();
  v_cfg  public.pharmacy_vault_config := public._phv_cfg();
  v_id   uuid := gen_random_uuid();
  v_src  text := case when p_source in ('photo', 'shelf') then p_source else 'photo' end;
  v_used integer;
begin
  if v_shop is null then return public._phv_denied(); end if;

  if p_batch_id is not null then
    if not exists (select 1 from public.pharmacy_bill_batch
                    where id = p_batch_id and pharmacy_id = v_shop) then
      return jsonb_build_object('ok', false, 'error', 'no_batch',
                                'message', public.ui_text('phvault.err_no_batch'));
    end if;
    select count(*) into v_used from public.pharmacy_purchase_bill where batch_id = p_batch_id;
    if v_used >= v_cfg.bulk_max then
      return jsonb_build_object('ok', false, 'error', 'batch_full',
        'message', public.ui_fmt('phvault.err_batch_full',
                             jsonb_build_object('max', v_cfg.bulk_max::text)));
    end if;
  end if;

  insert into public.pharmacy_purchase_bill (
    id, pharmacy_id, source, batch_id, status, bucket, path, created_by)
  values (v_id, v_shop, v_src, p_batch_id, 'draft', 'stock-imports',
          v_shop::text || '/vault-' || v_id::text || '-1.jpg', auth.uid());

  if p_batch_id is not null then
    update public.pharmacy_bill_batch
       set total = total + 1, status = case when status = 'open' then 'open' else status end
     where id = p_batch_id;
  end if;

  return jsonb_build_object('ok', true, 'bill_id', v_id, 'bucket', 'stock-imports',
    'path_prefix', v_shop::text || '/vault-' || v_id::text || '-',
    'path_suffix', '.jpg',
    'guide', case when v_src = 'shelf'
                  then public.ui_text('phvault.guide_shelf')
                  else public.ui_text('phvault.guide_bill') end,
    'guide_points', case when v_src = 'shelf'
                         then public._phv_copy_json('phvault.guide_shelf_points')
                         else public._phv_copy_json('phvault.guide_bill_points') end);
end $$;

-- HOSTILE PHOTOS (spec 3). Every shot is kept, in order. A metre of thermal
-- roll is four frames; a carbon copy gets a second frame at a different angle
-- because the first one lost the middle column to the crease. The reader is
-- given all of them at once and told they are one document.
create or replace function public.pharmacy_vault_shot_add(
  p_bill_id uuid, p_bucket text, p_path text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phv_shop(); v_no integer;
begin
  if v_shop is null then return public._phv_denied(); end if;
  if not exists (select 1 from public.pharmacy_purchase_bill
                  where id = p_bill_id and pharmacy_id = v_shop) then
    return jsonb_build_object('ok', false, 'error', 'no_bill',
                              'message', public.ui_text('phvault.err_no_bill'));
  end if;

  select coalesce(max(shot_no), 0) + 1 into v_no
    from public.pharmacy_bill_shot where bill_id = p_bill_id;

  insert into public.pharmacy_bill_shot (bill_id, shot_no, bucket, path)
  values (p_bill_id, v_no, p_bucket, p_path)
  on conflict (bill_id, shot_no) do nothing;

  update public.pharmacy_purchase_bill
     set shot_count = (select count(*) from public.pharmacy_bill_shot where bill_id = p_bill_id),
         bucket = coalesce(bucket, p_bucket),
         path   = case when shot_count = 0 then p_path else path end
   where id = p_bill_id;

  return jsonb_build_object('ok', true, 'shot_no', v_no,
    'shots', (select count(*) from public.pharmacy_bill_shot where bill_id = p_bill_id),
    'message', public.ui_fmt('phvault.shot_added', jsonb_build_object('n', v_no::text)));
end $$;

-- Hand the bill to the reader. A single counter bill is read immediately; a
-- bill inside a bulk sitting joins the queue the sweep drains, which is what
-- lets 120 photos be taken in five minutes and read over the next hour.
create or replace function public.pharmacy_vault_bill_queue(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phv_shop(); v_b public.pharmacy_purchase_bill%rowtype;
begin
  if v_shop is null then return public._phv_denied(); end if;
  select * into v_b from public.pharmacy_purchase_bill
   where id = p_bill_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_bill',
                              'message', public.ui_text('phvault.err_no_bill'));
  end if;
  if v_b.shot_count = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_shots',
                              'message', public.ui_text('phvault.err_no_shots'));
  end if;

  update public.pharmacy_purchase_bill
     set status = 'queued', queued_at = now(), ocr_error = null
   where id = p_bill_id and status in ('draft', 'failed', 'scanning');

  -- A single bill goes now; a batch bill waits its turn behind the others so
  -- one pharmacy's shoebox never monopolises the reader.
  if v_b.batch_id is null then
    perform public._phv_dispatch(p_bill_id);
  end if;

  return jsonb_build_object('ok', true, 'bill_id', p_bill_id, 'status', 'queued',
    'poll_ms', 2500, 'message', public.ui_text('phvault.queued'));
end $$;

-- A copy key whose value is a JSON array (the capture checklist), read straight
-- out of ui_copy so the guidance is edited with an UPDATE like every other word.
create or replace function public._phv_copy_json(p_key text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.ui_copy where key = p_key), '[]'::jsonb);
$$;

-- ─── the reader's door (service_role only) ──────────────────────────────────
--
-- THE PROMPT IS NOT IN THE EDGE FUNCTION. It lives in ui_copy, exactly as #412
-- put the stock-import prompt there, so hostile-photo tuning — "this is a
-- thermal roll", "the middle column may be a carbon smear", "say null, never
-- guess" — is an UPDATE and not a redeploy.
create or replace function public.pharmacy_vault_ocr_input(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_b public.pharmacy_purchase_bill%rowtype; v_shots jsonb;
begin
  select * into v_b from public.pharmacy_purchase_bill where id = p_bill_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_bill'); end if;

  update public.pharmacy_purchase_bill
     set status = 'processing' where id = p_bill_id and status = 'queued';

  select coalesce(jsonb_agg(jsonb_build_object('shot_no', s.shot_no,
                                               'bucket', s.bucket, 'path', s.path)
                            order by s.shot_no), '[]'::jsonb)
    into v_shots from public.pharmacy_bill_shot s where s.bill_id = p_bill_id;

  return jsonb_build_object('ok', true, 'bill_id', p_bill_id, 'source', v_b.source,
    'shots', v_shots,
    'prompt', case when v_b.source = 'shelf'
                   then public.ui_text('phvault.prompt_shelf')
                   else public.ui_text('phvault.prompt_bill') end);
end $$;

-- WHAT THE READER MAY SAY, AND WHAT IT MAY NOT.
--
-- It reports what is printed and how sure it was, field by field. It is
-- explicitly permitted to answer `readable: false` for a line, and that answer
-- is KEPT — a flagged line the pharmacist can look at is worth ten invented
-- ones. Nothing here writes a lot; every bill lands in `review` or, when the
-- read was clean end to end, in `read` awaiting one confirming tap.
create or replace function public.pharmacy_vault_ocr_report(
  p_bill_id uuid, p_payload jsonb, p_error text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg   public.pharmacy_vault_config := public._phv_cfg();
  v_b     public.pharmacy_purchase_bill%rowtype;
  v_line  jsonb;
  v_n     integer := 0;
  v_bad   integer := 0;
  v_rev   integer := 0;
  v_conf  numeric;
  v_lo    numeric := 1;
  v_key   text;
  v_dupe  uuid;
  v_inv   text;
  v_date  date;
  v_gst   text;
  v_sup   text;
  v_m     jsonb;
  v_flag  text;
  v_txt   text;
  v_read  boolean;
begin
  select * into v_b from public.pharmacy_purchase_bill where id = p_bill_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_bill'); end if;

  if p_error is not null then
    update public.pharmacy_purchase_bill
       set status = 'failed', ocr_error = left(p_error, 500), read_at = now()
     where id = p_bill_id;
    perform public._phv_batch_tick(v_b.batch_id);
    return jsonb_build_object('ok', false, 'error', 'ocr_failed');
  end if;

  v_sup  := nullif(btrim(coalesce(p_payload #>> '{supplier,name}', '')), '');
  v_gst  := nullif(btrim(coalesce(p_payload #>> '{supplier,gstin}', '')), '');
  v_inv  := nullif(btrim(coalesce(p_payload #>> '{invoice,no}', '')), '');
  begin
    v_date := nullif(btrim(coalesce(p_payload #>> '{invoice,date}', '')), '')::date;
  exception when others then v_date := null;
  end;

  -- DEDUPE (spec 4). Decided BEFORE a single line is written, so a re-upload
  -- costs nothing and can never double-count. The original is named in the
  -- reply so the screen can offer to open it instead.
  v_key := public._phv_dedupe_key(v_gst, v_inv, v_date, v_sup);
  if v_key is not null then
    select id into v_dupe from public.pharmacy_purchase_bill
     where pharmacy_id = v_b.pharmacy_id and dedupe_key = v_key
       and id <> p_bill_id and status <> 'duplicate'
     limit 1;
    if v_dupe is not null then
      update public.pharmacy_purchase_bill
         set status = 'duplicate', duplicate_of = v_dupe, read_at = now(),
             supplier_name = v_sup, supplier_gstin = v_gst,
             invoice_no = v_inv, invoice_date = v_date,
             month_key = date_trunc('month', coalesce(v_date, current_date))::date,
             review_reason = public.ui_text('phvault.reason_duplicate')
       where id = p_bill_id;
      perform public._phv_batch_tick(v_b.batch_id);
      return jsonb_build_object('ok', true, 'status', 'duplicate', 'duplicate_of', v_dupe,
        'message', public.ui_text('phvault.reason_duplicate'));
    end if;
  end if;

  delete from public.pharmacy_purchase_bill_line where bill_id = p_bill_id;

  for v_line in select * from jsonb_array_elements(coalesce(p_payload -> 'lines', '[]'::jsonb))
  loop
    v_n    := v_n + 1;
    v_txt  := nullif(btrim(coalesce(v_line ->> 'product', '')), '');
    v_read := coalesce((v_line ->> 'readable')::boolean, true);
    v_conf := coalesce((v_line ->> 'confidence')::numeric, 1);
    if v_conf < v_lo then v_lo := v_conf; end if;

    -- UNREADABLE IS AN ANSWER. The line is kept with whatever fragment was
    -- legible, flagged, and excluded from every total until a human fixes it.
    if not v_read or v_txt is null then
      v_flag := 'unreadable'; v_bad := v_bad + 1; v_m := '{}'::jsonb;
    else
      v_m := public._phv_match(v_b.pharmacy_id, v_txt, v_line ->> 'pack');
      if v_m ->> 'status' = 'matched' and v_conf >= v_cfg.field_confirm then
        v_flag := 'ok';
      elsif v_m ->> 'status' = 'matched' then
        v_flag := 'low_confidence';
      elsif v_m ->> 'status' = 'suggested' then
        v_flag := 'low_confidence';
      else
        v_flag := 'unmatched';
      end if;
      -- Anything that reached the fuzzy rung is worth a vector next time.
      if (v_m ->> 'source') in ('fuzzy', 'none', 'shelf') then
        perform public._phv_embed_want(v_txt, nullif(v_m ->> 'medicine_id', '')::bigint);
      end if;
    end if;
    if v_flag <> 'ok' then v_rev := v_rev + 1; end if;

    insert into public.pharmacy_purchase_bill_line (
      bill_id, line_no, raw, product_name, hsn, qty, rate, taxable,
      batch_no, expiry, expiry_on, free_qty, unit_cost, mrp, gst_percent, pack_label,
      medicine_id, match_status, match_score, match_source,
      field_conf, confidence, readable, flag)
    values (
      p_bill_id, v_n, v_line, v_txt,
      nullif(btrim(coalesce(v_line ->> 'hsn', '')), ''),
      nullif(v_line ->> 'qty', '')::numeric,
      nullif(v_line ->> 'rate', '')::numeric,
      nullif(v_line ->> 'taxable', '')::numeric,
      nullif(btrim(coalesce(v_line ->> 'batch', '')), ''),
      nullif(btrim(coalesce(v_line ->> 'expiry', '')), ''),
      public._phs_expiry_on(nullif(btrim(coalesce(v_line ->> 'expiry', '')), '')),
      nullif(v_line ->> 'free_qty', '')::numeric,
      coalesce(nullif(v_line ->> 'unit_cost', '')::numeric, nullif(v_line ->> 'rate', '')::numeric),
      nullif(v_line ->> 'mrp', '')::numeric,
      nullif(v_line ->> 'gst_percent', '')::numeric,
      nullif(btrim(coalesce(v_line ->> 'pack', '')), ''),
      nullif(v_m ->> 'medicine_id', '')::bigint,
      coalesce(v_m ->> 'status', 'unmatched'),
      nullif(v_m ->> 'score', '')::numeric,
      v_m ->> 'source',
      coalesce(v_line -> 'field_conf', '{}'::jsonb),
      v_conf, v_read, v_flag);
  end loop;

  update public.pharmacy_purchase_bill
     set supplier_name    = v_sup,
         supplier_gstin   = v_gst,
         invoice_no       = v_inv,
         invoice_date     = v_date,
         month_key        = date_trunc('month', coalesce(v_date, current_date))::date,
         dedupe_key       = v_key,
         line_count       = v_n,
         unreadable_count = v_bad,
         review_count     = v_rev,
         confidence       = v_lo,
         total_taxable    = nullif(p_payload #>> '{totals,taxable}', '')::numeric,
         total_tax        = nullif(p_payload #>> '{totals,tax}', '')::numeric,
         total_amount     = nullif(p_payload #>> '{totals,amount}', '')::numeric,
         read_at          = now(),
         review_reason    = case when v_rev > 0
                                 then public.ui_fmt('phvault.reason_review',
                                        jsonb_build_object('n', v_rev::text))
                                 else null end,
         status           = case when v_n = 0 then 'failed'
                                 when v_rev > 0 then 'review'
                                 else 'read' end,
         ocr_error        = case when v_n = 0
                                 then public.ui_text('phvault.err_no_lines') else null end
   where id = p_bill_id;

  perform public._phv_batch_tick(v_b.batch_id);

  return jsonb_build_object('ok', true, 'bill_id', p_bill_id, 'lines', v_n,
    'unreadable', v_bad, 'review', v_rev,
    'status', case when v_n = 0 then 'failed' when v_rev > 0 then 'review' else 'read' end);
end $$;

-- Batch progress is recomputed from the bills themselves — never incremented
-- optimistically, so a retried or re-read bill can never drift the counter.
create or replace function public._phv_batch_tick(p_batch_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_batch_id is null then return; end if;
  update public.pharmacy_bill_batch b
     set done      = x.done,
         failed    = x.failed,
         review    = x.review,
         duplicate = x.dupe,
         total     = x.total,
         status    = case when x.total > 0 and x.settled >= x.total then 'done' else 'running' end,
         finished_at = case when x.total > 0 and x.settled >= x.total then now() else null end
    from (
      select count(*) total,
             count(*) filter (where status in ('confirmed', 'read')) done,
             count(*) filter (where status = 'failed') failed,
             count(*) filter (where status = 'review') review,
             count(*) filter (where status = 'duplicate') dupe,
             count(*) filter (where status in ('confirmed', 'read', 'failed', 'review', 'duplicate')) settled
        from public.pharmacy_purchase_bill where batch_id = p_batch_id
    ) x
   where b.id = p_batch_id;
end $$;

-- ─── the review lane ────────────────────────────────────────────────────────
--
-- Everything the camera was not sure about, and nothing else. This is the whole
-- human cost of the vault: the pharmacist reads a short list of doubts, not a
-- bill. A fixed line teaches an alias, so the same doubt is never asked twice.
create or replace function public.pharmacy_vault_line_set(p_line_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phv_shop();
  v_l    public.pharmacy_purchase_bill_line%rowtype;
  v_bill uuid;
  v_med  bigint;
  v_rev  integer;
begin
  if v_shop is null then return public._phv_denied(); end if;
  select l.* into v_l from public.pharmacy_purchase_bill_line l
    join public.pharmacy_purchase_bill b on b.id = l.bill_id
   where l.id = p_line_id and b.pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_line',
                              'message', public.ui_text('phvault.err_no_line'));
  end if;
  v_bill := v_l.bill_id;
  v_med  := coalesce(nullif(p_patch ->> 'medicine_id', '')::bigint, v_l.medicine_id);

  update public.pharmacy_purchase_bill_line
     set product_name = coalesce(nullif(btrim(coalesce(p_patch ->> 'product_name', '')), ''), product_name),
         qty          = coalesce(nullif(p_patch ->> 'qty', '')::numeric, qty),
         unit_cost    = coalesce(nullif(p_patch ->> 'unit_cost', '')::numeric, unit_cost),
         mrp          = coalesce(nullif(p_patch ->> 'mrp', '')::numeric, mrp),
         batch_no     = coalesce(nullif(btrim(coalesce(p_patch ->> 'batch_no', '')), ''), batch_no),
         expiry       = coalesce(nullif(btrim(coalesce(p_patch ->> 'expiry', '')), ''), expiry),
         expiry_on    = coalesce(public._phs_expiry_on(
                          coalesce(nullif(btrim(coalesce(p_patch ->> 'expiry', '')), ''), expiry)), expiry_on),
         gst_percent  = coalesce(nullif(p_patch ->> 'gst_percent', '')::numeric, gst_percent),
         medicine_id  = v_med,
         readable     = case when p_patch ? 'drop' then readable else true end,
         match_status = case when v_med is not null then 'matched' else match_status end,
         match_source = case when v_med is distinct from v_l.medicine_id then 'human' else match_source end,
         match_score  = case when v_med is distinct from v_l.medicine_id then 1.0 else match_score end,
         review_note  = nullif(btrim(coalesce(p_patch ->> 'note', '')), ''),
         flag         = case when coalesce((p_patch ->> 'drop')::boolean, false) then 'dropped'
                             when v_med is not null then 'ok'
                             else 'unmatched' end
   where id = p_line_id;

  -- The answer becomes an alias: rung 1 for this spelling, forever.
  if v_med is distinct from v_l.medicine_id and v_med is not null then
    perform public._phv_alias_learn(v_shop, coalesce(v_l.product_name, ''), v_med, 'confirm');
  end if;

  select count(*) into v_rev from public.pharmacy_purchase_bill_line
   where bill_id = v_bill and flag not in ('ok', 'dropped');

  update public.pharmacy_purchase_bill
     set review_count  = v_rev,
         status        = case when status = 'review' and v_rev = 0 then 'read' else status end,
         review_reason = case when v_rev = 0 then null
                              else public.ui_fmt('phvault.reason_review',
                                     jsonb_build_object('n', v_rev::text)) end
   where id = v_bill;

  return jsonb_build_object('ok', true, 'line_id', p_line_id, 'review_left', v_rev,
    'message', public.ui_text('phvault.line_saved'));
end $$;

-- ─── confirm: the bill becomes lots ─────────────────────────────────────────
--
-- This is the only place a photographed bill touches inventory, and it goes
-- through #412's `_phs_apply` like everything else — same weighted-average
-- cost, same movement ledger, same (ref_kind, ref_id) uniqueness that makes a
-- double tap a no-op. A dropped or unreadable line contributes NOTHING; it
-- stays on the bill as the record of something we could not read.
create or replace function public.pharmacy_vault_bill_confirm(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phv_shop();
  v_b    public.pharmacy_purchase_bill%rowtype;
  v_l    record;
  v_lot  uuid;
  v_n    integer := 0;
  v_skip integer := 0;
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
       and coalesce(qty, 0) <> 0
     order by line_no
  loop
    v_lot := public._phs_apply(
      p_shop        => v_shop,
      p_medicine_id => v_l.medicine_id,
      p_name        => v_l.product_name,
      p_pack        => v_l.pack_label,
      p_batch       => v_l.batch_no,
      p_expiry      => v_l.expiry,
      p_qty_delta   => coalesce(v_l.qty, 0) + coalesce(v_l.free_qty, 0),
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
      -- A confirmed line is a taught line, even when the camera got it right.
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

  -- #416's GST purchase register reads this same table, so an outside bill that
  -- lands here appears in the month's GSTR-2 workings with no second step.
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

-- ─── COLD START (spec 6): the rack itself ───────────────────────────────────
--
-- A first visit cannot wait for three years of bills. A photo of the rack names
-- what is visibly on the shelf, and each name becomes an UNQUANTIFIED lot: the
-- shop stocks it, we do not know how many, and we do not pretend to. The
-- pharmacist counts them later, or the next bill fills the number in. Twenty
-- minutes of a rep's time plus the last three bills is a usable ledger.
create or replace function public.pharmacy_vault_shelf_apply(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._phv_shop();
  v_b    public.pharmacy_purchase_bill%rowtype;
  v_l    record;
  v_lot  uuid;
  v_n    integer := 0;
begin
  if v_shop is null then return public._phv_denied(); end if;
  select * into v_b from public.pharmacy_purchase_bill
   where id = p_bill_id and pharmacy_id = v_shop and source = 'shelf';
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_bill',
                              'message', public.ui_text('phvault.err_no_bill'));
  end if;

  for v_l in
    select * from public.pharmacy_purchase_bill_line
     where bill_id = p_bill_id and flag <> 'dropped' and product_name is not null
     order by line_no
  loop
    v_lot := public._phs_apply(
      p_shop        => v_shop,
      p_medicine_id => v_l.medicine_id,
      p_name        => v_l.product_name,
      p_pack        => v_l.pack_label,
      p_batch       => null, p_expiry => null,
      p_qty_delta   => 0,
      p_unit_cost   => null, p_mrp => v_l.mrp,
      p_kind        => 'shelf_seen',
      p_source_kind => 'opening',
      p_note        => public.ui_text('phvault.shelf_note'),
      p_ref_kind    => 'vault_shelf',
      p_ref_id      => v_l.id::text,
      p_received_on => coalesce(v_b.invoice_date, current_date));

    -- qty 0 is a real answer here, so _phs_apply's "nothing to do" guard is
    -- stepped around deliberately: the ROW is the point, not the number.
    if v_lot is null then
      insert into public.pharmacy_stock (
        pharmacy_id, medicine_id, product_name, pack_label, item_key,
        qty, mrp, source_kind, received_on, bill_id, bill_line_id, is_unquantified)
      values (
        v_shop, v_l.medicine_id, v_l.product_name, v_l.pack_label,
        public._phs_item_key(v_l.medicine_id, v_l.product_name),
        0, v_l.mrp, 'opening', coalesce(v_b.invoice_date, current_date),
        p_bill_id, v_l.id, true)
      on conflict (pharmacy_id, item_key, batch_key, expiry_key) do nothing
      returning id into v_lot;

      -- Already seeded by an earlier run of this same photo: adopt that lot
      -- rather than losing the link. This is what makes the shelf door
      -- re-runnable.
      if v_lot is null then
        select id into v_lot from public.pharmacy_stock
         where pharmacy_id = v_shop
           and item_key   = public._phs_item_key(v_l.medicine_id, v_l.product_name)
           and batch_key  = '~' and expiry_key = '~';
        if v_lot is not null then
          update public.pharmacy_stock
             set bill_id = coalesce(bill_id, p_bill_id),
                 bill_line_id = coalesce(bill_line_id, v_l.id)
           where id = v_lot;
        end if;
      end if;
    else
      update public.pharmacy_stock
         set bill_id = p_bill_id, bill_line_id = v_l.id, is_unquantified = (qty = 0)
       where id = v_lot;
    end if;

    if v_lot is not null then
      v_n := v_n + 1;
      update public.pharmacy_purchase_bill_line set lot_id = v_lot where id = v_l.id;
    end if;
  end loop;

  update public.pharmacy_purchase_bill
     set status = 'confirmed', confirmed_at = now(), applied_at = now()
   where id = p_bill_id;

  return jsonb_build_object('ok', true, 'bill_id', p_bill_id, 'seeded', v_n,
    'message', public.ui_fmt('phvault.shelf_seeded', jsonb_build_object('n', v_n::text)));
end $$;

-- ═══════════════════════ 9. THE ASYNC READER (spec 2c) ═════════════════════
--
-- 120 photos cannot be read while a pharmacist stands there, and they must not
-- be: the point of the bulk door is that the shoebox is emptied in five minutes
-- and the reading happens afterwards. So queueing is instant and a sweep on the
-- ONE cron dispatcher (CHANGE #273 — never a bare */N schedule) drains it a few
-- bills at a time, which also keeps the 1 GB instance out of the DB lane.

create or replace function public._phv_dispatch(p_bill_id uuid)
returns void language plpgsql security definer
set search_path = 'public', 'net' as $$
begin
  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-vault-ocr',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer ' || public._service_key()),
    body    := jsonb_build_object('bill_id', p_bill_id),
    timeout_milliseconds := 30000);
exception when others then
  raise warning 'c423: dispatch failed for % — %', p_bill_id, sqlerrm;
end $$;

create or replace function public.pharmacy_vault_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg public.pharmacy_vault_config := public._phv_cfg();
  r     record;
  v_n   integer := 0;
  v_e   integer := 0;
begin
  -- Oldest queued bills first, a few per tick, so one pharmacy's shoebox never
  -- starves another's single counter bill.
  for r in
    select id, batch_id from public.pharmacy_purchase_bill
     where status = 'queued'
     order by queued_at nulls first
     limit v_cfg.sweep_batch
     for update skip locked
  loop
    perform public._phv_dispatch(r.id);
    v_n := v_n + 1;
  end loop;

  -- A read that never came back is re-queued rather than lost. The edge
  -- function is idempotent (it rewrites the lines it produced), so a double
  -- read costs a token, not a duplicate.
  update public.pharmacy_purchase_bill
     set status = 'queued'
   where status = 'processing' and queued_at < now() - interval '10 minutes';

  select count(*) into v_e from public.sku_embed_queue where status = 'queued';
  if v_e > 0 then
    perform net.http_post(
      url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-vault-ocr',
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'Authorization', 'Bearer ' || public._service_key()),
      body    := jsonb_build_object('mode', 'embed'),
      timeout_milliseconds := 30000);
  end if;

  return jsonb_build_object('ok', true, 'dispatched', v_n, 'embed_pending', v_e);
end $$;

-- The embedding worker's two doors. Names only — never a price, never a
-- customer, never anything that identifies a pharmacy.
create or replace function public.pharmacy_vault_embed_input()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg public.pharmacy_vault_config := public._phv_cfg(); v_rows jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('text_key', q.text_key,
                                               'text', q.raw_text,
                                               'medicine_id', q.medicine_id)), '[]'::jsonb)
    into v_rows
    from (select * from public.sku_embed_queue
           where status = 'queued' and tries < 3
           order by created_at limit v_cfg.embed_batch) q;
  return jsonb_build_object('ok', true, 'rows', v_rows, 'dims', 768);
end $$;

create or replace function public.pharmacy_vault_embed_report(p_rows jsonb, p_error text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_r jsonb; v_n integer := 0;
begin
  if p_error is not null then
    update public.sku_embed_queue
       set tries = tries + 1, error = left(p_error, 300),
           status = case when tries + 1 >= 3 then 'failed' else 'queued' end
     where status = 'queued';
    return jsonb_build_object('ok', false, 'error', 'embed_failed');
  end if;

  for v_r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    insert into public.sku_embedding (text_key, raw_text, medicine_id, embedding, model)
    values (v_r ->> 'text_key', v_r ->> 'text',
            nullif(v_r ->> 'medicine_id', '')::bigint,
            (v_r ->> 'embedding')::vector(768),
            v_r ->> 'model')
    on conflict (text_key) do update
      set embedding = excluded.embedding, model = excluded.model, built_at = now();
    update public.sku_embed_queue set status = 'done' where text_key = v_r ->> 'text_key';
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'stored', v_n);
end $$;

-- The catalogue side of the vector index: the trigram candidates a real bill
-- line raised. This is the lazy backfill — it only ever embeds names the shops
-- actually buy, which is a few thousand rows, not 563k.
create or replace function public.pharmacy_vault_embed_seed(p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cfg public.pharmacy_vault_config := public._phv_cfg(); r record;
begin
  for r in
    select m.id, m.product_name from public."MEDICINE" m
     where public._norm_name(m.product_name) % public._norm_name(coalesce(p_text, ''))
     order by similarity(public._norm_name(m.product_name), public._norm_name(coalesce(p_text, ''))) desc
     limit least(v_cfg.candidates, 40)
  loop
    perform public._phv_embed_want(r.product_name, r.id);
  end loop;
end $$;

insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note,
   base_interval_s, max_interval_s, current_interval_s, business_hours_only, dml, next_run_at)
values
  ('pharmacy_vault_sweep', 512, 'poll',
   'select exists (select 1 from public.pharmacy_purchase_bill where status in (''queued'',''processing'')) or exists (select 1 from public.sku_embed_queue where status = ''queued'')',
   'select public.pharmacy_vault_sweep()', 25000, true,
   'Drains the bill vault''s OCR queue a few bills per tick and asks the embedding worker for anything waiting. Gated, so an empty vault costs one cheap EXISTS.',
   60, 600, 60, false, true, now() + interval '2 minutes')
on conflict (name) do nothing;

-- ═══════════════════════ 10. WHAT THE SCREEN READS ═════════════════════════
--
-- One RPC per surface, every string and every rupee formatted HERE. The Flutter
-- side prints what it is given and computes nothing — no totals, no chip
-- wording, no month names, no plurals.

create or replace function public._phv_money(p numeric)
returns text language sql immutable as $$ select public.inr_money(coalesce(p, 0)); $$;

create or replace function public._phv_status_chip(p_status text, p_review integer)
returns jsonb language sql stable security definer set search_path = public as $$
  select case p_status
    when 'confirmed' then jsonb_build_object('label', public.ui_text('phvault.st_confirmed'), 'tone', 'success')
    when 'read'      then jsonb_build_object('label', public.ui_text('phvault.st_read'),      'tone', 'info')
    when 'review'    then jsonb_build_object('label', public.ui_text('phvault.st_review'),    'tone', 'warning')
    when 'duplicate' then jsonb_build_object('label', public.ui_text('phvault.st_duplicate'), 'tone', 'info')
    when 'failed'    then jsonb_build_object('label', public.ui_text('phvault.st_failed'),    'tone', 'danger')
    when 'queued'    then jsonb_build_object('label', public.ui_text('phvault.st_queued'),    'tone', 'info')
    when 'processing'then jsonb_build_object('label', public.ui_text('phvault.st_processing'),'tone', 'info')
    else                  jsonb_build_object('label', public.ui_text('phvault.st_draft'),     'tone', 'muted')
  end;
$$;

create or replace function public._phv_bill_row(b public.pharmacy_purchase_bill)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'bill_id',   b.id,
    'source',    b.source,
    'source_label', case b.source
                      when 'medibo' then public.ui_text('phvault.src_medibo')
                      when 'shelf'  then public.ui_text('phvault.src_shelf')
                      else               public.ui_text('phvault.src_photo') end,
    'supplier',  coalesce(nullif(btrim(coalesce(b.supplier_name, '')), ''),
                          public.ui_text('phvault.supplier_unknown')),
    'invoice',   case when b.invoice_no is null then public.ui_text('phvault.invoice_unknown')
                      else public.ui_fmt('phvault.invoice_line',
                             jsonb_build_object('no', b.invoice_no)) end,
    'date_label', case when b.invoice_date is null then public.ui_text('phvault.date_unknown')
                       else to_char(b.invoice_date, 'DD Mon YYYY') end,
    'month_key', b.month_key,
    'month_label', public._phv_month_label(b.month_key),
    'amount',    public._phv_money(b.total_amount),
    'has_amount', b.total_amount is not null,
    'lines_label', public.ui_fmt('phvault.lines_count',
                     jsonb_build_object('n', b.line_count::text)),
    'chip',      public._phv_status_chip(b.status, b.review_count),
    'status',    b.status,
    'review_count', b.review_count,
    'unreadable_count', b.unreadable_count,
    'needs_review', b.status = 'review',
    'can_confirm', b.status in ('read', 'review') and b.source <> 'shelf',
    'is_duplicate', b.status = 'duplicate',
    'duplicate_of', b.duplicate_of,
    'reason',    b.review_reason,
    'error',     b.ocr_error,
    'shots',     b.shot_count);
$$;

create or replace function public.pharmacy_vault_home(p_month date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop  uuid := public._phv_shop();
  v_month date := p_month;
  v_bills jsonb; v_months jsonb; v_batch jsonb;
  v_tot integer; v_rev integer; v_lots integer; v_unq integer; v_val numeric;
begin
  if v_shop is null then return public._phv_denied(); end if;

  select count(*), count(*) filter (where status = 'review')
    into v_tot, v_rev
    from public.pharmacy_purchase_bill where pharmacy_id = v_shop;

  select count(*), count(*) filter (where is_unquantified), coalesce(sum(qty * coalesce(unit_cost, 0)), 0)
    into v_lots, v_unq, v_val
    from public.pharmacy_stock where pharmacy_id = v_shop;

  select coalesce(jsonb_agg(jsonb_build_object(
           'month_key', m.mk, 'label', public._phv_month_label(m.mk),
           'bills', m.n, 'amount', public._phv_money(m.amt),
           'selected', m.mk is not distinct from v_month) order by m.mk desc), '[]'::jsonb)
    into v_months
    from (select month_key mk, count(*) n, sum(total_amount) amt
            from public.pharmacy_purchase_bill
           where pharmacy_id = v_shop and month_key is not null
           group by month_key) m;

  select coalesce(jsonb_agg(public._phv_bill_row(b)
           order by b.invoice_date desc nulls last, b.created_at desc), '[]'::jsonb)
    into v_bills
    from public.pharmacy_purchase_bill b
   where b.pharmacy_id = v_shop
     and (v_month is null or b.month_key = v_month)
   limit 200;

  select to_jsonb(x) into v_batch from (
    select bb.id as batch_id, bb.label, bb.status, bb.total, bb.done, bb.failed,
           bb.review, bb.duplicate,
           case when bb.total = 0 then 0
                else round(((bb.done + bb.failed + bb.review + bb.duplicate)::numeric
                            / bb.total) * 100) end as percent,
           public.ui_fmt('phvault.batch_progress',
             jsonb_build_object('done', (bb.done + bb.failed + bb.review + bb.duplicate)::text,
                                'total', bb.total::text)) as progress_label
      from public.pharmacy_bill_batch bb
     where bb.pharmacy_id = v_shop and bb.status in ('open', 'running')
     order by bb.created_at desc limit 1) x;

  return jsonb_build_object('ok', true,
    'title',    public.ui_text('phvault.title'),
    'subtitle', public.ui_text('phvault.subtitle'),
    'tiles', jsonb_build_array(
      jsonb_build_object('key', 'bills',  'label', public.ui_text('phvault.tile_bills'),
                         'value', v_tot::text),
      jsonb_build_object('key', 'review', 'label', public.ui_text('phvault.tile_review'),
                         'value', v_rev::text, 'tone', case when v_rev > 0 then 'warning' else 'muted' end),
      jsonb_build_object('key', 'lots',   'label', public.ui_text('phvault.tile_lots'),
                         'value', v_lots::text),
      jsonb_build_object('key', 'value',  'label', public.ui_text('phvault.tile_value'),
                         'value', public._phv_money(v_val))),
    'unquantified_label', case when v_unq > 0
      then public.ui_fmt('phvault.unquantified', jsonb_build_object('n', v_unq::text)) end,
    'actions', jsonb_build_array(
      jsonb_build_object('key', 'photo', 'label', public.ui_text('phvault.act_photo'), 'primary', true),
      jsonb_build_object('key', 'bulk',  'label', public.ui_text('phvault.act_bulk')),
      jsonb_build_object('key', 'shelf', 'label', public.ui_text('phvault.act_shelf'))),
    'months', v_months,
    'month',  v_month,
    'bills',  v_bills,
    'batch',  v_batch,
    'empty',  case when v_tot = 0 then public.ui_text('phvault.empty') end,
    'review_count', v_rev);
end $$;

create or replace function public.pharmacy_vault_bill_get(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phv_shop(); v_b public.pharmacy_purchase_bill%rowtype; v_lines jsonb;
begin
  if v_shop is null then return public._phv_denied(); end if;
  select * into v_b from public.pharmacy_purchase_bill
   where id = p_bill_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_bill',
                              'message', public.ui_text('phvault.err_no_bill'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'line_id', l.id, 'line_no', l.line_no,
      'product', coalesce(l.product_name, public.ui_text('phvault.line_unreadable')),
      'seen', l.product_name,
      'matched_name', (select m.product_name from public."MEDICINE" m where m.id = l.medicine_id),
      'medicine_id', l.medicine_id,
      'qty', l.qty, 'qty_label', coalesce(l.qty::text, '—'),
      'batch', coalesce(l.batch_no, public.ui_text('phvault.batch_unknown')),
      'expiry', coalesce(l.expiry, public.ui_text('phvault.expiry_unknown')),
      'cost', public._phv_money(l.unit_cost), 'has_cost', l.unit_cost is not null,
      'mrp', public._phv_money(l.mrp), 'has_mrp', l.mrp is not null,
      'flag', l.flag,
      'flag_label', case l.flag
                      when 'unreadable'     then public.ui_text('phvault.flag_unreadable')
                      when 'low_confidence' then public.ui_text('phvault.flag_low')
                      when 'unmatched'      then public.ui_text('phvault.flag_unmatched')
                      when 'dropped'        then public.ui_text('phvault.flag_dropped')
                      else null end,
      'flag_tone', case l.flag when 'unreadable' then 'danger'
                               when 'dropped' then 'muted'
                               when 'ok' then 'success' else 'warning' end,
      'needs_review', l.flag not in ('ok', 'dropped'),
      'match_label', case when l.match_source is null then null
                          else public.ui_fmt('phvault.match_line',
                                 jsonb_build_object(
                                   'source', case l.match_source
                                       when 'alias'  then public.ui_text('phvault.src_alias')
                                       when 'exact'  then public.ui_text('phvault.src_exact')
                                       when 'shelf'  then public.ui_text('phvault.src_shelf_m')
                                       when 'fuzzy'  then public.ui_text('phvault.src_fuzzy')
                                       when 'vector' then public.ui_text('phvault.src_vector')
                                       when 'human'  then public.ui_text('phvault.src_human')
                                       when 'medibo' then public.ui_text('phvault.src_medibo')
                                       else l.match_source end,
                                   'score', to_char(coalesce(l.match_score, 0) * 100, 'FM990') || '%')) end,
      'field_conf', l.field_conf)
      order by l.line_no), '[]'::jsonb)
    into v_lines from public.pharmacy_purchase_bill_line l where l.bill_id = p_bill_id;

  return jsonb_build_object('ok', true,
    'bill', public._phv_bill_row(v_b),
    'lines', v_lines,
    'shots', (select coalesce(jsonb_agg(jsonb_build_object('shot_no', s.shot_no,
                'bucket', s.bucket, 'path', s.path) order by s.shot_no), '[]'::jsonb)
                from public.pharmacy_bill_shot s where s.bill_id = p_bill_id),
    'confirm_label', public.ui_text('phvault.act_confirm'),
    'review_title',  public.ui_text('phvault.review_title'),
    'poll_ms', case when v_b.status in ('queued', 'processing') then 2500 else null end);
end $$;

create or replace function public.pharmacy_vault_review()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phv_shop(); v_rows jsonb;
begin
  if v_shop is null then return public._phv_denied(); end if;
  select coalesce(jsonb_agg(public._phv_bill_row(b)
           order by b.created_at), '[]'::jsonb)
    into v_rows from public.pharmacy_purchase_bill b
   where b.pharmacy_id = v_shop and b.status in ('review', 'failed');
  return jsonb_build_object('ok', true,
    'title', public.ui_text('phvault.review_title'),
    'rows', v_rows,
    'empty', case when v_rows = '[]'::jsonb then public.ui_text('phvault.review_empty') end);
end $$;

create or replace function public.pharmacy_vault_batch_status(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phv_shop(); v_b public.pharmacy_bill_batch%rowtype; v_settled integer;
begin
  if v_shop is null then return public._phv_denied(); end if;
  perform public._phv_batch_tick(p_batch_id);
  select * into v_b from public.pharmacy_bill_batch
   where id = p_batch_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_batch',
                              'message', public.ui_text('phvault.err_no_batch'));
  end if;
  v_settled := v_b.done + v_b.failed + v_b.review + v_b.duplicate;
  return jsonb_build_object('ok', true, 'batch_id', v_b.id, 'status', v_b.status,
    'total', v_b.total, 'settled', v_settled,
    'percent', case when v_b.total = 0 then 0
                    else round((v_settled::numeric / v_b.total) * 100) end,
    'progress_label', public.ui_fmt('phvault.batch_progress',
      jsonb_build_object('done', v_settled::text, 'total', v_b.total::text)),
    'review_label', case when v_b.review > 0
      then public.ui_fmt('phvault.batch_review', jsonb_build_object('n', v_b.review::text)) end,
    'duplicate_label', case when v_b.duplicate > 0
      then public.ui_fmt('phvault.batch_duplicate', jsonb_build_object('n', v_b.duplicate::text)) end,
    'done', v_b.status = 'done',
    'poll_ms', case when v_b.status <> 'done' then 4000 else null end);
end $$;

-- The way in, and the ONLY thing that decides whether the button exists.
create or replace function public.pharmacy_vault_entry()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._phv_shop(); v_rev integer;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select count(*) into v_rev from public.pharmacy_purchase_bill
   where pharmacy_id = v_shop and status = 'review';
  return jsonb_build_object('ok', true, 'show', true,
    'label', public.ui_text('phvault.nav_label'),
    'badge', case when v_rev > 0 then v_rev::text else null end,
    'route_key', 'pharmacy_vault');
end $$;

-- ═══════════════════════ 11. WHO MAY CALL WHAT ═════════════════════════════
--
-- RLS is on and there is not one policy on any vault table — exactly #412's
-- shape. A client SELECT returns zero rows; the only door is a SECURITY DEFINER
-- RPC that resolves the caller's own pharmacy from their JWT and filters on it.
-- A pharmacy therefore cannot read another pharmacy's vault even by guessing a
-- bill id: every RPC's WHERE carries `pharmacy_id = _phv_shop()`.
revoke all on public.pharmacy_bill_shot, public.pharmacy_bill_batch,
              public.pharmacy_sku_alias, public.sku_embedding,
              public.sku_embed_queue, public.pharmacy_vault_config
  from anon, authenticated;

grant execute on function public.pharmacy_vault_home(date)                  to authenticated;
grant execute on function public.pharmacy_vault_entry()                     to authenticated;
grant execute on function public.pharmacy_vault_bill_start(text, uuid)      to authenticated;
grant execute on function public.pharmacy_vault_batch_start(text)           to authenticated;
grant execute on function public.pharmacy_vault_shot_add(uuid, text, text)  to authenticated;
grant execute on function public.pharmacy_vault_bill_queue(uuid)            to authenticated;
grant execute on function public.pharmacy_vault_bill_get(uuid)              to authenticated;
grant execute on function public.pharmacy_vault_line_set(uuid, jsonb)       to authenticated;
grant execute on function public.pharmacy_vault_bill_confirm(uuid)          to authenticated;
grant execute on function public.pharmacy_vault_shelf_apply(uuid)           to authenticated;
grant execute on function public.pharmacy_vault_review()                    to authenticated;
grant execute on function public.pharmacy_vault_batch_status(uuid)          to authenticated;

-- Machine-side only: the reader's doors, the sweep and the embedding worker.
revoke all on function public.pharmacy_vault_ocr_input(uuid)                from anon, authenticated;
revoke all on function public.pharmacy_vault_ocr_report(uuid, jsonb, text)  from anon, authenticated;
revoke all on function public.pharmacy_vault_embed_input()                  from anon, authenticated;
revoke all on function public.pharmacy_vault_embed_report(jsonb, text)      from anon, authenticated;
revoke all on function public.pharmacy_vault_sweep()                        from anon, authenticated;
revoke all on function public.pharmacy_vault_ingest_order(uuid)             from anon, authenticated;
revoke all on function public.pharmacy_vault_embed_seed(text)               from anon, authenticated;
revoke all on function public._phv_match(uuid, text, text)                  from anon, authenticated;
revoke all on function public._phv_dispatch(uuid)                           from anon, authenticated;
revoke all on function public._phv_batch_tick(uuid)                         from anon, authenticated;
revoke all on function public._phv_alias_learn(uuid, text, bigint, text)    from anon, authenticated;
revoke all on function public._phv_embed_want(text, bigint)                 from anon, authenticated;

grant execute on function public.pharmacy_vault_ocr_input(uuid)               to service_role;
grant execute on function public.pharmacy_vault_ocr_report(uuid, jsonb, text) to service_role;
grant execute on function public.pharmacy_vault_embed_input()                 to service_role;
grant execute on function public.pharmacy_vault_embed_report(jsonb, text)     to service_role;
grant execute on function public.pharmacy_vault_sweep()                       to service_role;
grant execute on function public.pharmacy_vault_ingest_order(uuid)            to service_role;
grant execute on function public.pharmacy_vault_embed_seed(text)              to service_role;

-- ═══════════════════════ 12. THE WORDS ═════════════════════════════════════
-- Every string the vault can print. Wording changes are an UPDATE here.
insert into public.ui_copy (key, value) values
  ('phvault.nav_label',      to_jsonb('Bill vault'::text)),
  ('phvault.title',          to_jsonb('Bill vault'::text)),
  ('phvault.subtitle',       to_jsonb('Your bills are your stock register'::text)),
  ('phvault.empty',          to_jsonb('No bills yet. Photograph one, or let your next mediBO delivery fill this by itself.'::text)),
  ('phvault.err_not_pharmacy', to_jsonb('The bill vault is for a pharmacy account.'::text)),
  ('phvault.err_no_bill',    to_jsonb('That bill is not in your vault.'::text)),
  ('phvault.err_no_line',    to_jsonb('That line is not on this bill.'::text)),
  ('phvault.err_no_batch',   to_jsonb('That import session has ended.'::text)),
  ('phvault.err_no_shots',   to_jsonb('Take at least one photo of the bill first.'::text)),
  ('phvault.err_batch_full', to_jsonb('One session holds up to {max} bills. Start another for the rest.'::text)),
  ('phvault.err_no_lines',   to_jsonb('No bill lines could be read from those photos.'::text)),

  ('phvault.tile_bills',     to_jsonb('Bills'::text)),
  ('phvault.tile_review',    to_jsonb('To check'::text)),
  ('phvault.tile_lots',      to_jsonb('Batches'::text)),
  ('phvault.tile_value',     to_jsonb('Stock value'::text)),
  ('phvault.unquantified',   to_jsonb('{n} shelf items still need a count'::text)),

  ('phvault.act_photo',      to_jsonb('Photograph a bill'::text)),
  ('phvault.act_bulk',       to_jsonb('Import old bills'::text)),
  ('phvault.act_shelf',      to_jsonb('Photograph the shelf'::text)),
  ('phvault.act_confirm',    to_jsonb('Add to stock'::text)),

  ('phvault.st_draft',       to_jsonb('Draft'::text)),
  ('phvault.st_queued',      to_jsonb('Waiting'::text)),
  ('phvault.st_processing',  to_jsonb('Reading'::text)),
  ('phvault.st_read',        to_jsonb('Read'::text)),
  ('phvault.st_review',      to_jsonb('Check this'::text)),
  ('phvault.st_confirmed',   to_jsonb('In stock'::text)),
  ('phvault.st_duplicate',   to_jsonb('Already have it'::text)),
  ('phvault.st_failed',      to_jsonb('Could not read'::text)),

  ('phvault.src_medibo',     to_jsonb('mediBO delivery'::text)),
  ('phvault.src_photo',      to_jsonb('Outside bill'::text)),
  ('phvault.src_shelf',      to_jsonb('Shelf photo'::text)),
  ('phvault.src_alias',      to_jsonb('learned'::text)),
  ('phvault.src_exact',      to_jsonb('exact'::text)),
  ('phvault.src_shelf_m',    to_jsonb('your shelf'::text)),
  ('phvault.src_fuzzy',      to_jsonb('close spelling'::text)),
  ('phvault.src_vector',     to_jsonb('similar name'::text)),
  ('phvault.src_human',      to_jsonb('you chose'::text)),
  ('phvault.match_line',     to_jsonb('Matched by {source} · {score}'::text)),

  ('phvault.supplier_unknown', to_jsonb('Supplier not printed'::text)),
  ('phvault.invoice_unknown',  to_jsonb('No invoice number'::text)),
  ('phvault.invoice_line',     to_jsonb('Invoice {no}'::text)),
  ('phvault.date_unknown',     to_jsonb('No date'::text)),
  ('phvault.month_unknown',    to_jsonb('Undated'::text)),
  ('phvault.lines_count',      to_jsonb('{n} lines'::text)),
  ('phvault.batch_unknown',    to_jsonb('Batch not readable'::text)),
  ('phvault.expiry_unknown',   to_jsonb('Expiry not readable'::text)),
  ('phvault.line_unreadable',  to_jsonb('Could not read this line'::text)),

  ('phvault.flag_unreadable',  to_jsonb('Unreadable'::text)),
  ('phvault.flag_low',         to_jsonb('Please check'::text)),
  ('phvault.flag_unmatched',   to_jsonb('Which medicine?'::text)),
  ('phvault.flag_dropped',     to_jsonb('Skipped'::text)),

  ('phvault.review_title',     to_jsonb('Bills to check'::text)),
  ('phvault.review_empty',     to_jsonb('Nothing to check. Every bill read cleanly.'::text)),
  ('phvault.reason_review',    to_jsonb('{n} lines need your eyes'::text)),
  ('phvault.reason_duplicate', to_jsonb('You already have this bill in the vault.'::text)),
  ('phvault.line_saved',       to_jsonb('Saved'::text)),
  ('phvault.confirmed',        to_jsonb('{n} batches added to your stock'::text)),
  ('phvault.shelf_seeded',     to_jsonb('{n} shelf items added — count them when you can'::text)),
  ('phvault.shelf_note',       to_jsonb('Seen on the shelf, not yet counted'::text)),

  ('phvault.queued',           to_jsonb('Reading your bill…'::text)),
  ('phvault.shot_added',       to_jsonb('Photo {n} added'::text)),
  ('phvault.batch_started',    to_jsonb('Session started. Photograph the bills one after another.'::text)),
  ('phvault.batch_progress',   to_jsonb('{done} of {total} read'::text)),
  ('phvault.batch_review',     to_jsonb('{n} need checking'::text)),
  ('phvault.batch_duplicate',  to_jsonb('{n} were already in the vault'::text)),

  ('phvault.guide_bill',       to_jsonb('Lay the bill flat and fill the frame. Take one photo per section — a long thermal roll needs three or four.'::text)),
  ('phvault.guide_shelf',      to_jsonb('Stand square to the rack, one shelf per photo, close enough to read the strip names.'::text))
on conflict (key) do update set value = excluded.value;

-- The capture checklists are JSON arrays, rendered as a list by the screen.
insert into public.ui_copy (key, value) values
  ('phvault.guide_bill_points', jsonb_build_array(
     'Flatten the bill — a curl loses the middle column',
     'One photo per section, top to bottom, in order',
     'Carbon copy? Take a second at a slight angle',
     'Anything blurred is flagged, never guessed')),
  ('phvault.guide_shelf_points', jsonb_build_array(
     'One shelf per photo',
     'Close enough to read the strip names',
     'Quantities are not counted from a photo',
     'You can correct anything afterwards'))
on conflict (key) do update set value = excluded.value;

-- THE READER'S INSTRUCTIONS. Kept in copy, not in the edge function, so a
-- hostile-photo lesson is an UPDATE. The OCR naming rule is carried verbatim:
-- verbatim text, no expansion, no correction, no world knowledge, and an
-- explicit permission to answer "unreadable" instead of guessing.
insert into public.ui_copy (key, value) values
  ('phvault.prompt_bill', to_jsonb(
'You are reading photographs of ONE Indian pharmaceutical purchase invoice. The photos are sections of the same bill, in order; read them as one document and do not repeat a line that spans two photos.

These are hostile photographs: thermal paper that has faded, a carbon copy, a curled roll, a phone shot at an angle under a tube light. Read what is actually printed.

RULES THAT OVERRIDE EVERYTHING:
- Return VERBATIM text exactly as printed. Never expand an abbreviation, never correct a spelling, never substitute an official or parent company name, never use any outside knowledge of medicine names or brands.
- If a line or a field cannot be read, say so. Set "readable": false for the line, or leave the field null. NEVER invent, infer or complete a value. A missing value is correct; a guessed value is a defect.
- Report your own confidence 0..1 per line and per field.

Answer with ONE JSON object and nothing else:
{"supplier":{"name":"...","gstin":"..."},
 "invoice":{"no":"...","date":"YYYY-MM-DD"},
 "totals":{"taxable":0,"tax":0,"amount":0},
 "lines":[{"product":"as printed","pack":"","hsn":"","batch":"","expiry":"as printed",
           "qty":0,"free_qty":0,"rate":0,"unit_cost":0,"mrp":0,"gst_percent":0,"taxable":0,
           "readable":true,"confidence":0.0,
           "field_conf":{"product":0.0,"qty":0.0,"batch":0.0,"expiry":0.0,"rate":0.0}}]}

Use null for anything not printed on the bill. Do not add commentary.'::text)),
  ('phvault.prompt_shelf', to_jsonb(
'You are reading photographs of the SHELVES of an Indian pharmacy. List the distinct medicine products you can actually read on the strips, boxes and bottles.

RULES THAT OVERRIDE EVERYTHING:
- VERBATIM text exactly as printed on the pack. Never expand, correct or substitute a name, and never use outside knowledge.
- DO NOT COUNT ANYTHING. Quantity is not knowable from a photograph. Never return a qty.
- If a pack is too blurred, angled or distant to read, leave it out or set "readable": false. Never guess a name.

Answer with ONE JSON object and nothing else:
{"lines":[{"product":"as printed","pack":"","mrp":null,"readable":true,"confidence":0.0,
           "field_conf":{"product":0.0}}]}

Do not add commentary.'::text))
on conflict (key) do update set value = excluded.value;
