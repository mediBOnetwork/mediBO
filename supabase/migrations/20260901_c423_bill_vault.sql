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
