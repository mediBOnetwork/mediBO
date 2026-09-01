-- CMD #429 — TIER 1 PAPER SALE. The page they already write on becomes stock.
--
-- WHERE THIS SITS. #423 gave a pharmacy an inventory built from its purchase
-- bills, and #424 infers what has left the shelf since. #411 is the POS, for a
-- shop that bills every sale. Between them sits the shop this feature is for:
-- one that HAS stock in the ledger and never bills. In a rush hour the counter
-- writes "Dolo 650 x2, Montek LC 1, Zerodol SP 2" on a pad and that is the
-- entire record of the day. Nobody is going to retype it into an app.
--
-- So: photograph the pad. That is the whole interaction.
--
-- A PAPER SALE IS A STOCK MOVEMENT, NEVER AN INVOICE. This is the hard rule of
-- the command and it is enforced structurally, not by discipline: nothing in
-- this file writes `pos_sales`, `pos_sale_lines` or `pharmacy_gst_ledger`, and
-- the proof asserts the GST sales register is byte-identical before and after a
-- confirmed sheet. A pharmacy that did not raise an invoice has no output tax
-- to declare, and a tool that invented one for them would be manufacturing a
-- tax record — a far worse failure than a missing number. Graduating them to
-- the POS (refinement 10) is how that shop starts having invoices, and it is a
-- suggestion made with their own numbers, never a silent upgrade.
--
-- THE CAMERA IS NOT A DATABASE, AND HANDWRITING IS THE HARDEST CASE OF IT. A
-- pad is mixed Hindi and English, abbreviations only that shop uses, tally
-- marks, "x2" and "2x" and "-2", and a line the writer themselves could not
-- read back. Every one of those is either read or FLAGGED. Nothing is guessed.
-- The learned shorthand dictionary (#423's pharmacy_sku_alias, reused) is what
-- turns "mtk lc" into a product on the second sheet, because a human answered
-- it on the first.
--
-- IN-APP UPLOAD ONLY. Om was explicit: there is no WhatsApp forwarding path for
-- this feature, and none is built. The only door is the app.

-- ═══════════════════════ 1. THE SHEET ══════════════════════════════════════
create table if not exists public.pharmacy_sale_sheet (
  id           uuid primary key default gen_random_uuid(),
  pharmacy_id  uuid not null,
  sold_on      date not null,
  status       text not null default 'draft'
                 check (status in ('draft','queued','processing','review','read',
                                   'confirmed','failed','cancelled')),
  mode         text not null default 'page'  check (mode in ('page','tally','typed')),
  shot_count   integer not null default 0,
  line_count   integer not null default 0,
  unreadable_count integer not null default 0,
  review_count integer not null default 0,
  new_count    integer not null default 0,   -- live-tally: lines NEW this shot
  confidence   numeric,
  ocr_error    text,
  review_reason text,
  tally_cursor integer not null default 0,   -- lines already counted on this page
  created_by   uuid,
  created_at   timestamptz not null default now(),
  queued_at    timestamptz,
  read_at      timestamptz,
  confirmed_at timestamptz
);
alter table public.pharmacy_sale_sheet enable row level security;
create index if not exists c429_sheet_shop on public.pharmacy_sale_sheet (pharmacy_id, sold_on desc);
create index if not exists c429_sheet_queued on public.pharmacy_sale_sheet (status, queued_at)
  where status in ('queued','processing');

-- MULTI-PAGE SHOOTS WITH SAME-PAGE DEDUPE (refinement 2). A pad is several
-- pages and a shaky hand takes the same page twice. The client hashes the bytes
-- it uploaded; an identical hash on the same sheet is refused as a re-shoot of
-- a page already held, so the page is never counted twice.
create table if not exists public.pharmacy_sale_shot (
  id         uuid primary key default gen_random_uuid(),
  sheet_id   uuid not null references public.pharmacy_sale_sheet(id) on delete cascade,
  shot_no    integer not null,
  bucket     text not null,
  path       text not null,
  content_hash text,
  status     text not null default 'queued',
  note       text,
  created_at timestamptz not null default now(),
  unique (sheet_id, shot_no)
);
alter table public.pharmacy_sale_shot enable row level security;
create unique index if not exists c429_shot_dedupe
  on public.pharmacy_sale_shot (sheet_id, content_hash)
  where content_hash is not null;

-- ═══════════════════════ 2. THE LINE, AND ITS DOUBTS ═══════════════════════
create table if not exists public.pharmacy_sale_line (
  id           uuid primary key default gen_random_uuid(),
  sheet_id     uuid not null references public.pharmacy_sale_sheet(id) on delete cascade,
  line_no      integer not null,
  raw          jsonb not null default '{}'::jsonb,
  seen_text    text,                      -- VERBATIM, as written on the pad
  medicine_id  bigint,
  product_name text,
  pack_label   text,
  qty          numeric,
  qty_assumed  boolean not null default false,  -- refinement 4
  qty_source   text,                            -- written | learned | typed
  match_status text not null default 'unmatched',
  match_score  numeric,
  match_source text,
  confidence   numeric,
  readable     boolean not null default true,
  flag         text not null default 'ok',
  review_note  text,
  line_key     text,                       -- live-tally identity (refinement 3)
  is_new       boolean not null default true,
  on_hand      numeric,                    -- what the ledger held when parsed
  short_qty    numeric,                    -- refinement 6: sold beyond the ledger
  applied      boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (sheet_id, line_no)
);
alter table public.pharmacy_sale_line enable row level security;
create index if not exists c429_line_sheet on public.pharmacy_sale_line (sheet_id, line_no);
create index if not exists c429_line_flag  on public.pharmacy_sale_line (sheet_id) where flag <> 'ok';

comment on column public.pharmacy_sale_line.flag is
  'ok | unreadable (the model could not read it and did not guess) | low_confidence | unmatched (read, no product) | unknown_item (never purchased here) | over_ledger (sold more than the shelf holds) | dropped';
comment on column public.pharmacy_sale_line.line_key is
  'Stable identity of a written line within one running page: the normalised text plus its quantity. Re-shooting the page matches on this, so only what was added since the last shot is counted.';

-- LEARNED USUAL QUANTITY (refinement 4). A pad often writes the name and no
-- number because everyone at that counter knows it goes out in twos. The
-- default is that shop's own observed mode — and it is ALWAYS marked assumed,
-- so it arrives pre-filled but flagged for a human, never silently applied.
create table if not exists public.pharmacy_sale_qty_default (
  pharmacy_id uuid   not null,
  medicine_id bigint not null,
  usual_qty   numeric not null,
  seen_count  integer not null default 1,
  updated_at  timestamptz not null default now(),
  primary key (pharmacy_id, medicine_id)
);
alter table public.pharmacy_sale_qty_default enable row level security;

-- ═══════════════════════ 3. SETTINGS AND THRESHOLDS ════════════════════════
create table if not exists public.pharmacy_sale_settings (
  pharmacy_id    uuid primary key,
  nudge_enabled  boolean not null default false,   -- refinement 8: OFF by default
  nudge_at       time    not null default '21:00',
  graduated_at   timestamptz,
  graduation_dismissed_at timestamptz,
  updated_at     timestamptz not null default now()
);
alter table public.pharmacy_sale_settings enable row level security;

create table if not exists public.pharmacy_sale_config (
  id              boolean primary key default true check (id),
  match_confirm   numeric not null default 0.86,
  field_confirm   numeric not null default 0.70,
  max_shots       integer not null default 12,
  graduate_sheets integer not null default 20,   -- sustained volume, refinement 10
  graduate_days   integer not null default 14,
  graduate_lines  integer not null default 120,
  sweep_batch     integer not null default 4,
  updated_at      timestamptz not null default now()
);
alter table public.pharmacy_sale_config enable row level security;
insert into public.pharmacy_sale_config (id) values (true) on conflict (id) do nothing;

create or replace function public._c429_cfg()
returns public.pharmacy_sale_config
language sql stable security definer set search_path = public as $$
  select * from public.pharmacy_sale_config where id;
$$;

create or replace function public._c429_shop() returns uuid
language sql stable as $$ select public.my_customer_id(); $$;

create or replace function public._c429_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date; $$;

create or replace function public._c429_denied() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('paper429.err_not_pharmacy'));
$$;

-- Single-brace interpolation, the same helper shape #423 settled on.
create or replace function public._c429_fmt(p_key text, p_vars jsonb)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_out text := public.ui_text(p_key); k text;
begin
  if coalesce(v_out, '') = '' then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;
  return v_out;
end $$;

-- ═══════════════════════ 4. THE PAGE GOES IN ═══════════════════════════════
create or replace function public.paper_sale_start(
  p_sold_on date default null, p_mode text default 'page')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c429_shop(); v_id uuid := gen_random_uuid();
begin
  if v_shop is null then return public._c429_denied(); end if;
  insert into public.pharmacy_sale_sheet (id, pharmacy_id, sold_on, mode, created_by)
  values (v_id, v_shop, coalesce(p_sold_on, public._c429_today()),
          case when p_mode in ('page','tally','typed') then p_mode else 'page' end,
          auth.uid());
  return jsonb_build_object('ok', true, 'sheet_id', v_id,
    'bucket', 'stock-imports',
    'path_prefix', v_shop::text || '/paper-' || v_id::text || '-',
    'path_suffix', '.jpg',
    'max_shots', (public._c429_cfg()).max_shots,
    'guide', public.ui_text('paper429.guide'),
    'guide_points', coalesce((select value from public.ui_copy
                               where key = 'paper429.guide_points'), '[]'::jsonb));
end $$;

-- SAME-PAGE DEDUPE (refinement 2). The client sends the hash of the bytes it
-- uploaded. An identical page already on this sheet is REFUSED — with the
-- backend's own words, so the counter is told "that is the page you just took"
-- instead of silently doubling a day's sales.
create or replace function public.paper_sale_shot_add(
  p_sheet_id uuid, p_bucket text, p_path text, p_hash text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c429_shop(); v_no integer; v_cfg public.pharmacy_sale_config;
begin
  if v_shop is null then return public._c429_denied(); end if;
  v_cfg := public._c429_cfg();
  if not exists (select 1 from public.pharmacy_sale_sheet
                  where id = p_sheet_id and pharmacy_id = v_shop) then
    return jsonb_build_object('ok', false, 'error', 'no_sheet',
                              'message', public.ui_text('paper429.err_no_sheet'));
  end if;

  if p_hash is not null and exists (
       select 1 from public.pharmacy_sale_shot
        where sheet_id = p_sheet_id and content_hash = p_hash) then
    return jsonb_build_object('ok', false, 'error', 'same_page',
      'message', public.ui_text('paper429.err_same_page'),
      'shots', (select count(*) from public.pharmacy_sale_shot where sheet_id = p_sheet_id));
  end if;

  select coalesce(max(shot_no), 0) + 1 into v_no
    from public.pharmacy_sale_shot where sheet_id = p_sheet_id;
  if v_no > v_cfg.max_shots then
    return jsonb_build_object('ok', false, 'error', 'too_many',
      'message', public._c429_fmt('paper429.err_too_many',
                   jsonb_build_object('max', v_cfg.max_shots::text)));
  end if;

  insert into public.pharmacy_sale_shot (sheet_id, shot_no, bucket, path, content_hash)
  values (p_sheet_id, v_no, p_bucket, p_path, p_hash);

  update public.pharmacy_sale_sheet
     set shot_count = (select count(*) from public.pharmacy_sale_shot where sheet_id = p_sheet_id)
   where id = p_sheet_id;

  return jsonb_build_object('ok', true, 'shot_no', v_no,
    'shots', (select count(*) from public.pharmacy_sale_shot where sheet_id = p_sheet_id),
    'message', public._c429_fmt('paper429.shot_added', jsonb_build_object('n', v_no::text)));
end $$;

create or replace function public.paper_sale_queue(p_sheet_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c429_shop(); v_s public.pharmacy_sale_sheet%rowtype;
begin
  if v_shop is null then return public._c429_denied(); end if;
  select * into v_s from public.pharmacy_sale_sheet
   where id = p_sheet_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_sheet',
                              'message', public.ui_text('paper429.err_no_sheet'));
  end if;
  if v_s.shot_count = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_shots',
                              'message', public.ui_text('paper429.err_no_shots'));
  end if;
  update public.pharmacy_sale_sheet
     set status = 'queued', queued_at = now(), ocr_error = null
   where id = p_sheet_id and status in ('draft','failed');
  perform public._c429_dispatch(p_sheet_id);
  return jsonb_build_object('ok', true, 'sheet_id', p_sheet_id, 'status', 'queued',
    'poll_ms', 2500, 'message', public.ui_text('paper429.queued'));
end $$;

create or replace function public._c429_dispatch(p_sheet_id uuid)
returns void language plpgsql security definer
set search_path = 'public', 'net' as $$
begin
  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/paper-sale-ocr',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer ' || public._service_key()),
    body    := jsonb_build_object('sheet_id', p_sheet_id),
    timeout_milliseconds := 30000);
exception when others then
  raise warning 'c429: dispatch failed for % — %', p_sheet_id, sqlerrm;
end $$;

create or replace function public.paper_sale_ocr_input(p_sheet_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_s public.pharmacy_sale_sheet%rowtype; v_shots jsonb;
begin
  select * into v_s from public.pharmacy_sale_sheet where id = p_sheet_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_sheet'); end if;
  update public.pharmacy_sale_sheet set status = 'processing'
   where id = p_sheet_id and status = 'queued';
  select coalesce(jsonb_agg(jsonb_build_object('shot_no', s.shot_no,
           'bucket', s.bucket, 'path', s.path) order by s.shot_no), '[]'::jsonb)
    into v_shots from public.pharmacy_sale_shot s where s.sheet_id = p_sheet_id;
  return jsonb_build_object('ok', true, 'sheet_id', p_sheet_id, 'mode', v_s.mode,
    'shots', v_shots, 'prompt', public.ui_text('paper429.prompt'));
end $$;

-- ═══════════════════════ 5. THE READ LANDS ═════════════════════════════════
--
-- Four lanes come out of one pass, and every one of them is a QUESTION for the
-- counter rather than a decision taken on their behalf:
--
--   unreadable   — the model said it could not read the line. Kept, flagged,
--                  worth nothing until a human types it (refinement 7).
--   unmatched    — read fine, but the shorthand means nothing yet. The first
--                  answer teaches the dictionary and it never asks again.
--   unknown_item — matched a product this shop has NEVER purchased. That is not
--                  an error, it is a discovery: they were selling something the
--                  ledger never knew about. Offered as an opening-stock add, so
--                  the ledger self-completes (refinement 5).
--   over_ledger  — sold 8, the shelf holds 5. Also not an error: the shelf is
--                  wrong, not the pad. Flagged gently with an opening-stock
--                  correction, which is what stops #424's inference from
--                  drifting negative on a shop that under-recorded purchases
--                  (refinement 6).
--
-- LIVE TALLY (refinement 3). A running page is photographed at noon and again
-- at six. The second read contains the WHOLE page — including everything
-- already counted. `line_key` is the identity of a written line (its normalised
-- text and its quantity, plus an occurrence index so two identical lines are
-- two lines), and any key already applied on an earlier sheet for the same day
-- is marked `is_new = false` and contributes nothing. Only what was written
-- since the last shot counts.

create or replace function public._c429_line_key(p_text text, p_qty numeric, p_seq integer)
returns text language sql immutable as $$
  select public._norm_name(coalesce(p_text, '')) || '|' ||
         coalesce(p_qty::text, '~') || '|' || coalesce(p_seq, 0)::text;
$$;

create or replace function public.paper_sale_ocr_report(
  p_sheet_id uuid, p_payload jsonb, p_error text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg  public.pharmacy_sale_config := public._c429_cfg();
  v_s    public.pharmacy_sale_sheet%rowtype;
  v_line jsonb;
  v_n integer := 0; v_bad integer := 0; v_rev integer := 0; v_new integer := 0;
  v_lo numeric := 1;
  v_txt text; v_qty numeric; v_read boolean; v_conf numeric;
  v_m jsonb; v_flag text; v_med bigint; v_seq integer; v_key text;
  v_assumed boolean; v_qsrc text; v_hand numeric; v_short numeric; v_isnew boolean;
begin
  select * into v_s from public.pharmacy_sale_sheet where id = p_sheet_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_sheet'); end if;

  if p_error is not null then
    update public.pharmacy_sale_sheet
       set status = 'failed', ocr_error = left(p_error, 500), read_at = now()
     where id = p_sheet_id;
    return jsonb_build_object('ok', false, 'error', 'ocr_failed');
  end if;

  delete from public.pharmacy_sale_line where sheet_id = p_sheet_id;

  for v_line in select * from jsonb_array_elements(coalesce(p_payload -> 'lines', '[]'::jsonb))
  loop
    v_n := v_n + 1;
    v_txt  := nullif(btrim(coalesce(v_line ->> 'item', '')), '');
    v_read := coalesce((v_line ->> 'readable')::boolean, true);
    v_conf := coalesce((v_line ->> 'confidence')::numeric, 1);
    v_qty  := nullif(v_line ->> 'qty', '')::numeric;
    if v_conf < v_lo then v_lo := v_conf; end if;
    v_assumed := false; v_qsrc := 'written'; v_med := null;
    v_hand := null; v_short := null; v_m := '{}'::jsonb;

    if not v_read or v_txt is null then
      v_flag := 'unreadable'; v_bad := v_bad + 1;
    else
      -- The shorthand dictionary is #423's alias table: an answer given once on
      -- a bill or a pad is rung 1 for every surface, forever.
      v_m   := public._phv_match(v_s.pharmacy_id, v_txt, null);
      v_med := nullif(v_m ->> 'medicine_id', '')::bigint;

      if v_m ->> 'status' = 'matched' and v_conf >= v_cfg.field_confirm then
        v_flag := 'ok';
      elsif v_med is not null then
        v_flag := 'low_confidence';
      else
        v_flag := 'unmatched';
      end if;

      -- SMART QUANTITY DEFAULT (refinement 4). No number written? Use what this
      -- shop usually sells it in — and SAY that it was assumed.
      if v_qty is null and v_med is not null then
        select d.usual_qty into v_qty from public.pharmacy_sale_qty_default d
         where d.pharmacy_id = v_s.pharmacy_id and d.medicine_id = v_med;
        if v_qty is not null then
          v_assumed := true; v_qsrc := 'learned';
          if v_flag = 'ok' then v_flag := 'low_confidence'; end if;
        end if;
      end if;

      if v_med is not null then
        select coalesce(sum(s.qty), 0) into v_hand
          from public.pharmacy_stock s
         where s.pharmacy_id = v_s.pharmacy_id and s.medicine_id = v_med;

        -- UNKNOWN ITEM (5): matched a product, but this shop's ledger has never
        -- held it. Sold-but-never-bought.
        if not exists (select 1 from public.pharmacy_stock s
                        where s.pharmacy_id = v_s.pharmacy_id and s.medicine_id = v_med) then
          v_flag := 'unknown_item';
        -- OVER LEDGER (6): sold more than the shelf can account for.
        elsif coalesce(v_qty, 0) > coalesce(v_hand, 0) then
          v_short := coalesce(v_qty, 0) - coalesce(v_hand, 0);
          v_flag  := 'over_ledger';
        end if;
      end if;
    end if;

    -- LIVE TALLY. Occurrence index makes two identical written lines two lines.
    select count(*) + 1 into v_seq from public.pharmacy_sale_line l
     where l.sheet_id = p_sheet_id
       and l.seen_text is not distinct from v_txt
       and l.qty is not distinct from v_qty;
    v_key := public._c429_line_key(v_txt, v_qty, v_seq);

    v_isnew := not exists (
      select 1 from public.pharmacy_sale_line l2
        join public.pharmacy_sale_sheet s2 on s2.id = l2.sheet_id
       where s2.pharmacy_id = v_s.pharmacy_id
         and s2.sold_on = v_s.sold_on
         and s2.id <> p_sheet_id
         and s2.status = 'confirmed'
         and l2.line_key = v_key
         and l2.applied);
    if v_isnew then v_new := v_new + 1; end if;
    if v_flag <> 'ok' and v_isnew then v_rev := v_rev + 1; end if;

    insert into public.pharmacy_sale_line (
      sheet_id, line_no, raw, seen_text, medicine_id, product_name, qty,
      qty_assumed, qty_source, match_status, match_score, match_source,
      confidence, readable, flag, line_key, is_new, on_hand, short_qty)
    values (
      p_sheet_id, v_n, v_line, v_txt, v_med,
      nullif(v_m ->> 'product_name', ''), v_qty,
      v_assumed, v_qsrc,
      coalesce(v_m ->> 'status', 'unmatched'),
      nullif(v_m ->> 'score', '')::numeric, v_m ->> 'source',
      v_conf, v_read, v_flag, v_key, v_isnew, v_hand, v_short);
  end loop;

  update public.pharmacy_sale_sheet
     set line_count = v_n, unreadable_count = v_bad, review_count = v_rev,
         new_count = v_new, confidence = v_lo, read_at = now(),
         review_reason = case when v_rev > 0
                              then public._c429_fmt('paper429.reason_review',
                                     jsonb_build_object('n', v_rev::text)) end,
         status = case when v_n = 0 then 'failed'
                       when v_rev > 0 then 'review' else 'read' end,
         ocr_error = case when v_n = 0 then public.ui_text('paper429.err_no_lines') end
   where id = p_sheet_id;

  return jsonb_build_object('ok', true, 'sheet_id', p_sheet_id, 'lines', v_n,
    'unreadable', v_bad, 'review', v_rev, 'new', v_new,
    'status', case when v_n = 0 then 'failed' when v_rev > 0 then 'review' else 'read' end);
end $$;

-- ═══════════════════════ 6. THE COUNTER ANSWERS ════════════════════════════
--
-- Every correction teaches something. The name teaches the shorthand
-- dictionary; the quantity teaches the usual quantity; both make tomorrow's
-- page need fewer taps than today's. This is also the RAPID-TYPE FALLBACK
-- (refinement 7): when the photo is hopeless the counter types the line here,
-- with autocomplete served by pharmacy_stock_product_search over THEIR stock.
create or replace function public.paper_sale_line_set(p_line_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c429_shop();
  v_l public.pharmacy_sale_line%rowtype;
  v_sheet uuid; v_med bigint; v_qty numeric; v_rev integer; v_hand numeric;
  v_flag text; v_short numeric;
begin
  if v_shop is null then return public._c429_denied(); end if;
  select l.* into v_l from public.pharmacy_sale_line l
    join public.pharmacy_sale_sheet s on s.id = l.sheet_id
   where l.id = p_line_id and s.pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_line',
                              'message', public.ui_text('paper429.err_no_line'));
  end if;
  v_sheet := v_l.sheet_id;
  v_med := coalesce(nullif(p_patch ->> 'medicine_id', '')::bigint, v_l.medicine_id);
  v_qty := coalesce(nullif(p_patch ->> 'qty', '')::numeric, v_l.qty);

  if coalesce((p_patch ->> 'drop')::boolean, false) then
    v_flag := 'dropped';
  elsif v_med is null then
    v_flag := 'unmatched';
  else
    select coalesce(sum(s.qty), 0) into v_hand
      from public.pharmacy_stock s
     where s.pharmacy_id = v_shop and s.medicine_id = v_med;
    if not exists (select 1 from public.pharmacy_stock s
                    where s.pharmacy_id = v_shop and s.medicine_id = v_med) then
      -- Still unknown until they take the opening-stock offer.
      v_flag := case when coalesce((p_patch ->> 'seed_opening')::boolean, false)
                     then 'ok' else 'unknown_item' end;
    elsif coalesce(v_qty, 0) > coalesce(v_hand, 0) then
      -- Still over the ledger unless they accepted the correction.
      v_short := coalesce(v_qty, 0) - coalesce(v_hand, 0);
      v_flag := case when coalesce((p_patch ->> 'accept_short')::boolean, false)
                     then 'ok' else 'over_ledger' end;
    else
      v_flag := 'ok';
    end if;
  end if;

  update public.pharmacy_sale_line
     set medicine_id  = v_med,
         product_name = coalesce(
           (select m.product_name from public."MEDICINE" m where m.id = v_med),
           product_name),
         qty          = v_qty,
         qty_assumed  = case when p_patch ? 'qty' then false else qty_assumed end,
         qty_source   = case when p_patch ? 'qty' then 'typed' else qty_source end,
         seen_text    = coalesce(nullif(btrim(coalesce(p_patch ->> 'seen_text', '')), ''), seen_text),
         readable     = case when v_flag = 'dropped' then readable else true end,
         match_status = case when v_med is not null then 'matched' else match_status end,
         match_source = case when v_med is distinct from v_l.medicine_id then 'human' else match_source end,
         match_score  = case when v_med is distinct from v_l.medicine_id then 1.0 else match_score end,
         on_hand      = coalesce(v_hand, on_hand),
         short_qty    = v_short,
         review_note  = nullif(btrim(coalesce(p_patch ->> 'note', '')), ''),
         flag         = v_flag
   where id = p_line_id;

  -- THE DICTIONARY LEARNS. The text as WRITTEN on the pad becomes an alias for
  -- the product the counter chose — so "mtk lc" is answered instantly next time.
  if v_med is distinct from v_l.medicine_id and v_med is not null
     and coalesce(v_l.seen_text, '') <> '' then
    perform public._phv_alias_learn(v_shop, v_l.seen_text, v_med, 'paper');
  end if;

  select count(*) into v_rev from public.pharmacy_sale_line
   where sheet_id = v_sheet and is_new and flag not in ('ok', 'dropped');

  update public.pharmacy_sale_sheet
     set review_count = v_rev,
         status = case when status = 'review' and v_rev = 0 then 'read' else status end,
         review_reason = case when v_rev = 0 then null
                              else public._c429_fmt('paper429.reason_review',
                                     jsonb_build_object('n', v_rev::text)) end
   where id = v_sheet;

  return jsonb_build_object('ok', true, 'line_id', p_line_id, 'review_left', v_rev,
    'flag', v_flag, 'message', public.ui_text('paper429.line_saved'));
end $$;

-- OPENING-STOCK SELF-COMPLETION (refinements 5 and 6). Sold something the
-- ledger never held, or more of it than the ledger holds? The shelf is what is
-- wrong. This adds exactly the missing quantity as an OPENING lot — the same
-- `opening` source #412 uses for a register brought in by hand — so the sale
-- can then leave the shelf normally and #424's inference never sees a negative.
create or replace function public.paper_sale_seed_opening(p_line_id uuid, p_qty numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c429_shop();
  v_l public.pharmacy_sale_line%rowtype;
  v_need numeric; v_lot uuid;
begin
  if v_shop is null then return public._c429_denied(); end if;
  select l.* into v_l from public.pharmacy_sale_line l
    join public.pharmacy_sale_sheet s on s.id = l.sheet_id
   where l.id = p_line_id and s.pharmacy_id = v_shop;
  if not found or v_l.medicine_id is null then
    return jsonb_build_object('ok', false, 'error', 'no_line',
                              'message', public.ui_text('paper429.err_no_line'));
  end if;

  v_need := coalesce(p_qty, nullif(v_l.short_qty, 0), v_l.qty, 0);
  if v_need <= 0 then
    return jsonb_build_object('ok', false, 'error', 'nothing_to_add',
                              'message', public.ui_text('paper429.err_nothing_to_add'));
  end if;

  v_lot := public._phs_apply(
    p_shop        => v_shop,
    p_medicine_id => v_l.medicine_id,
    p_name        => coalesce(v_l.product_name, v_l.seen_text),
    p_pack        => v_l.pack_label,
    p_batch       => null, p_expiry => null,
    p_qty_delta   => v_need,
    p_unit_cost   => null, p_mrp => null,
    p_kind        => 'opening',
    p_source_kind => 'opening',
    p_note        => public.ui_text('paper429.opening_note'),
    p_ref_kind    => 'paper_open',
    p_ref_id      => p_line_id::text);

  update public.pharmacy_sale_line
     set flag = 'ok', short_qty = null,
         on_hand = (select coalesce(sum(s.qty), 0) from public.pharmacy_stock s
                     where s.pharmacy_id = v_shop and s.medicine_id = v_l.medicine_id)
   where id = p_line_id;

  perform public._c429_recount(v_l.sheet_id);

  return jsonb_build_object('ok', true, 'lot_id', v_lot, 'added', v_need,
    'message', public._c429_fmt('paper429.opening_added',
                 jsonb_build_object('n', v_need::text)));
end $$;

create or replace function public._c429_recount(p_sheet_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_rev integer;
begin
  select count(*) into v_rev from public.pharmacy_sale_line
   where sheet_id = p_sheet_id and is_new and flag not in ('ok', 'dropped');
  update public.pharmacy_sale_sheet
     set review_count = v_rev,
         status = case when status = 'review' and v_rev = 0 then 'read' else status end,
         review_reason = case when v_rev = 0 then null
                              else public._c429_fmt('paper429.reason_review',
                                     jsonb_build_object('n', v_rev::text)) end
   where id = p_sheet_id;
end $$;

-- ═══════════════════════ 7. CONFIRM = STOCK LEAVES, AND NOTHING ELSE ═══════
--
-- Batch-wise FEFO, exactly as #412's POS consumer does it: earliest expiry
-- first, across as many lots as the quantity needs. What it does NOT do is the
-- point of the whole command — no pos_sales row, no pos_sale_lines row, no
-- pharmacy_gst_ledger row, no invoice number. A shop that wrote on paper raised
-- no invoice, and this feature will not manufacture one.
--
-- GROUND TRUTH (refinement 9). A confirmed paper sale is the strongest signal
-- this system can get about what actually left a shelf — stronger than #424's
-- presumption, which exists precisely because nobody was recording sales. So it
-- moves the velocity posterior directly (alpha += units, beta += days) with
-- source 'paper_sale', re-pours the lot inference, and its units are visible to
-- #427's demand engine through _c429_sale_units.

create or replace function public.paper_sale_confirm(p_sheet_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c429_shop();
  v_s    public.pharmacy_sale_sheet%rowtype;
  v_line record; v_lot record;
  v_need numeric; v_take numeric; v_item text; v_nkey text;
  v_lines integer := 0; v_units numeric := 0; v_short numeric := 0;
begin
  if v_shop is null then return public._c429_denied(); end if;
  select * into v_s from public.pharmacy_sale_sheet
   where id = p_sheet_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_sheet',
                              'message', public.ui_text('paper429.err_no_sheet'));
  end if;
  if v_s.status = 'confirmed' then
    return jsonb_build_object('ok', true, 'already', true, 'sheet_id', p_sheet_id,
      'message', public.ui_text('paper429.already_confirmed'));
  end if;

  for v_line in
    select * from public.pharmacy_sale_line
     where sheet_id = p_sheet_id
       and is_new                         -- live tally: only what is new counts
       and flag not in ('dropped', 'unreadable', 'unmatched')
       and medicine_id is not null
       and coalesce(qty, 0) > 0
     order by line_no
  loop
    v_need  := v_line.qty;
    v_lines := v_lines + 1;
    v_units := v_units + v_need;
    v_item  := public._phs_item_key(v_line.medicine_id, v_line.product_name);
    v_nkey  := 'n:' || public._norm_name(coalesce(v_line.product_name, ''));

    for v_lot in
      select s.id, s.qty from public.pharmacy_stock s
       where s.pharmacy_id = v_shop
         and (s.item_key = v_item or s.name_key = v_nkey)
         and s.qty > 0
       order by s.expiry_on asc nulls last, s.created_at asc
    loop
      exit when v_need <= 0;
      v_take := least(v_lot.qty, v_need);
      perform public._phs_apply(
        p_shop        => v_shop,
        p_medicine_id => v_line.medicine_id,
        p_name        => v_line.product_name,
        p_pack        => v_line.pack_label,
        p_batch       => null, p_expiry => null,
        p_qty_delta   => -v_take,
        p_unit_cost   => null, p_mrp => null,
        p_kind        => 'sale',
        p_source_kind => null,
        p_note        => public.ui_text('paper429.move_note'),
        p_ref_kind    => 'paper_line_lot',
        p_ref_id      => v_line.id::text || ':' || v_lot.id::text,
        p_lot_id      => v_lot.id);
      v_need := v_need - v_take;
    end loop;

    -- Anything the shelf still could not account for. The counter was offered
    -- the opening-stock correction and declined it, so it is recorded honestly
    -- as a shortfall rather than quietly dropped.
    if v_need > 0 then
      perform public._phs_apply(
        p_shop        => v_shop,
        p_medicine_id => v_line.medicine_id,
        p_name        => v_line.product_name,
        p_pack        => null, p_expiry => null, p_batch => null,
        p_qty_delta   => -v_need,
        p_unit_cost   => null, p_mrp => null,
        p_kind        => 'sale',
        p_source_kind => 'adjustment',
        p_note        => public.ui_text('paper429.short_note'),
        p_ref_kind    => 'paper_line_short',
        p_ref_id      => v_line.id::text);
      v_short := v_short + v_need;
    end if;

    update public.pharmacy_sale_line set applied = true where id = v_line.id;

    -- The usual quantity learns from what was actually confirmed.
    insert into public.pharmacy_sale_qty_default as d
      (pharmacy_id, medicine_id, usual_qty, seen_count)
    values (v_shop, v_line.medicine_id, v_line.qty, 1)
    on conflict (pharmacy_id, medicine_id) do update
      set usual_qty = round((d.usual_qty * d.seen_count + excluded.usual_qty)
                            / (d.seen_count + 1), 2),
          seen_count = d.seen_count + 1,
          updated_at = now();

    -- GROUND TRUTH into #424's posterior. A day of observed selling is a day of
    -- evidence, and it outranks any presumption the engine had made.
    begin
      insert into public.pharmacy_sku_velocity as v
        (pharmacy_id, medicine_id, alpha, beta, per_day, units_seen, days_seen,
         source, updated_at)
      values (v_shop, v_line.medicine_id, v_line.qty, 1, v_line.qty,
              v_line.qty, 1, 'paper_sale', now())
      on conflict (pharmacy_id, medicine_id) do update
        set alpha = v.alpha + excluded.alpha,
            beta  = v.beta  + excluded.beta,
            per_day = (v.alpha + excluded.alpha) / nullif(v.beta + excluded.beta, 0),
            units_seen = v.units_seen + excluded.units_seen,
            days_seen  = v.days_seen  + excluded.days_seen,
            source = 'paper_sale',
            updated_at = now();
    exception when others then
      raise warning 'c429: velocity feed skipped for line % — %', v_line.id, sqlerrm;
    end;
  end loop;

  update public.pharmacy_sale_sheet
     set status = 'confirmed', confirmed_at = now(),
         tally_cursor = greatest(tally_cursor, line_count)
   where id = p_sheet_id;

  -- Re-pour the inference on the new evidence.
  begin
    perform public.pharmacy_infer_lots(v_shop);
  exception when others then
    raise warning 'c429: inference re-pour skipped — %', sqlerrm;
  end;

  return jsonb_build_object('ok', true, 'sheet_id', p_sheet_id,
    'lines', v_lines, 'units', v_units, 'short', v_short,
    'message', public._c429_fmt('paper429.confirmed',
                 jsonb_build_object('n', v_lines::text, 'u', v_units::text)),
    'short_note', case when v_short > 0
      then public._c429_fmt('paper429.short_summary',
             jsonb_build_object('n', v_short::text)) end);
end $$;

-- The demand engine's fourth source. Confirmed paper sales, honouring the same
-- zone requirement and the same sharing opt-out every other arm honours.
create or replace function public._c429_sale_units(p_from date, p_to date)
returns table(zone_id smallint, medicine_id bigint, product_name text,
              pharmacy_id uuid, units numeric)
language sql stable security definer set search_path = public as $$
  select p.zone_id, l.medicine_id, max(coalesce(l.product_name, l.seen_text)),
         s.pharmacy_id, sum(l.qty)
    from public.pharmacy_sale_line l
    join public.pharmacy_sale_sheet s on s.id = l.sheet_id
    join public.pharmacy_profiles p on p.id = s.pharmacy_id
   where s.status = 'confirmed'
     and s.sold_on between p_from and p_to
     and l.applied and l.medicine_id is not null
     and p.zone_id is not null
     and public._c419_sharing(s.pharmacy_id)
   group by p.zone_id, l.medicine_id, s.pharmacy_id;
$$;

-- The demand engine gains a fourth arm. The other three (POS lines, mediBO
-- order lines, #427's vault bills) are untouched, and the new one is added the
-- same way they were: as a union arm over a function that owns its own gates.
create or replace function public._c419_units(p_from date, p_to date)
returns table(zone_id smallint, medicine_id bigint, product_name text,
              pharmacy_id uuid, units numeric)
language sql stable security definer set search_path = public as $$
  select p.zone_id, l.medicine_id, max(l.product_name), s.pharmacy_id, sum(l.qty)
    from public.pos_sale_lines l
    join public.pos_sales s on s.id = l.sale_id
    join public.pharmacy_profiles p on p.id = s.pharmacy_id
   where s.status = 'completed' and s.sold_on between p_from and p_to
     and p.zone_id is not null and l.medicine_id is not null
     and public._c419_sharing(s.pharmacy_id)
   group by p.zone_id, l.medicine_id, s.pharmacy_id
  union all
  select p.zone_id, oi.product_id::bigint, max(oi.product_name), o.customer_id, sum(oi.quantity)
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.pharmacy_profiles p on p.id = o.customer_id
   where o.order_date between p_from and p_to
     and p.zone_id is not null and oi.product_id is not null
     and coalesce(oi.unfulfillable, false) = false
     and public._c419_sharing(o.customer_id)
     and not exists (select 1 from public.pharmacy_purchase_bill b
                      where b.order_id = o.id and b.status in ('confirmed','applied'))
   group by p.zone_id, oi.product_id, o.customer_id
  union all
  select u.zone_id, u.medicine_id, max(u.product_name), u.pharmacy_id, sum(u.units)
    from public._c427_bill_units(p_from, p_to) u
   group by u.zone_id, u.medicine_id, u.pharmacy_id
  union all
  -- CMD #429 — confirmed paper sales. For a shop that never bills, this is the
  -- ONLY sales signal that exists, so leaving it out would make exactly the
  -- pharmacies this tier serves invisible to the demand engine.
  select u.zone_id, u.medicine_id, max(u.product_name), u.pharmacy_id, sum(u.units)
    from public._c429_sale_units(p_from, p_to) u
   group by u.zone_id, u.medicine_id, u.pharmacy_id;
$$;

-- ═══════════════════════ 8. THE RITUAL, THE NUDGE, THE GRADUATION ══════════
--
-- CLOSE MY DAY (refinement 1). One button, three beats: photograph the page,
-- confirm what it read, and see what to reorder tomorrow. The reorder hint is
-- #414's draft builder — not a second engine written here.
create or replace function public.paper_sale_close_day(p_sheet_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c429_shop();
  v_conf jsonb; v_hint jsonb; v_grad jsonb;
begin
  if v_shop is null then return public._c429_denied(); end if;
  v_conf := public.paper_sale_confirm(p_sheet_id);
  if coalesce((v_conf ->> 'ok')::boolean, false) is false then return v_conf; end if;

  begin
    v_hint := public.pharmacy_reorder_draft_build(v_shop);
  exception when others then
    v_hint := null;
    raise warning 'c429: reorder hint skipped — %', sqlerrm;
  end;

  v_grad := public.paper_sale_graduation();

  return jsonb_build_object('ok', true,
    'title',   public.ui_text('paper429.closed_title'),
    'confirm', v_conf,
    'reorder', case when v_hint is null then null else jsonb_build_object(
      'label', public.ui_text('paper429.reorder_hint'),
      'count', v_hint -> 'line_count',
      'route_key', 'pharmacy_reorder') end,
    'graduation', case when coalesce((v_grad ->> 'show')::boolean, false)
                       then v_grad end,
    'message', public.ui_text('paper429.closed_message'));
end $$;

-- THE NUDGE (refinement 8). Off by default, one per day, at an hour they chose,
-- and only when the day actually has unrecorded selling behind it. A reminder
-- that fires on a day they already closed is spam, and spam is how a pharmacy
-- learns to ignore the app.
create or replace function public.paper_sale_settings_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c429_shop(); v_row public.pharmacy_sale_settings%rowtype;
begin
  if v_shop is null then return public._c429_denied(); end if;
  insert into public.pharmacy_sale_settings (pharmacy_id) values (v_shop)
  on conflict (pharmacy_id) do nothing;
  update public.pharmacy_sale_settings
     set nudge_enabled = coalesce((p_patch ->> 'nudge_enabled')::boolean, nudge_enabled),
         nudge_at      = coalesce(nullif(p_patch ->> 'nudge_at', '')::time, nudge_at),
         graduation_dismissed_at = case
           when coalesce((p_patch ->> 'dismiss_graduation')::boolean, false)
           then now() else graduation_dismissed_at end,
         updated_at = now()
   where pharmacy_id = v_shop
  returning * into v_row;
  return jsonb_build_object('ok', true,
    'nudge_enabled', v_row.nudge_enabled,
    'nudge_at', to_char(v_row.nudge_at, 'HH24:MI'),
    'message', public.ui_text('paper429.settings_saved'));
end $$;

-- GRADUATION (refinement 10). Suggested only after SUSTAINED volume, and made
-- with their own numbers — never a generic upsell. Dismissible, and it stays
-- dismissed.
create or replace function public.paper_sale_graduation()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c429_shop();
  v_cfg public.pharmacy_sale_config := public._c429_cfg();
  v_sheets integer; v_days integer; v_lines integer; v_set public.pharmacy_sale_settings%rowtype;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select * into v_set from public.pharmacy_sale_settings where pharmacy_id = v_shop;
  if v_set.graduation_dismissed_at is not null then
    return jsonb_build_object('ok', true, 'show', false);
  end if;

  select count(*), count(distinct s.sold_on),
         coalesce(sum(s.line_count), 0)
    into v_sheets, v_days, v_lines
    from public.pharmacy_sale_sheet s
   where s.pharmacy_id = v_shop and s.status = 'confirmed';

  if v_sheets < v_cfg.graduate_sheets or v_days < v_cfg.graduate_days
     or v_lines < v_cfg.graduate_lines then
    return jsonb_build_object('ok', true, 'show', false,
      'sheets', v_sheets, 'days', v_days, 'lines', v_lines);
  end if;

  return jsonb_build_object('ok', true, 'show', true,
    'title', public.ui_text('paper429.graduate_title'),
    'body',  public._c429_fmt('paper429.graduate_body',
               jsonb_build_object('days', v_days::text, 'lines', v_lines::text)),
    'accept_label',  public.ui_text('paper429.graduate_accept'),
    'dismiss_label', public.ui_text('paper429.graduate_dismiss'),
    'route_key', 'pos');
end $$;

-- The nudge sweep rides the ONE cron dispatcher. It writes a notification only
-- for a shop that opted in, whose hour has come, and that has not closed today.
create or replace function public.paper_sale_nudge_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_n integer := 0; v_now time := (now() at time zone 'Asia/Kolkata')::time;
begin
  for r in
    select st.pharmacy_id
      from public.pharmacy_sale_settings st
     where st.nudge_enabled
       and v_now >= st.nudge_at
       and v_now <  st.nudge_at + interval '30 minutes'
       and not exists (select 1 from public.pharmacy_sale_sheet s
                        where s.pharmacy_id = st.pharmacy_id
                          and s.sold_on = public._c429_today()
                          and s.status = 'confirmed')
  loop
    begin
      insert into public.pharmacy_expiry_alert_log
        (pharmacy_id, kind, dedupe_key, sent_on, detail)
      values (r.pharmacy_id, 'paper_close',
              'paper_close:' || public._c429_today()::text,
              public._c429_today(),
              jsonb_build_object('message', public.ui_text('paper429.nudge_body')))
      on conflict do nothing;
      v_n := v_n + 1;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'nudged', v_n);
end $$;

insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, step_timeout_ms, enabled, note,
   base_interval_s, max_interval_s, current_interval_s, business_hours_only, dml, next_run_at)
values
  ('paper_sale_nudge_sweep', 517, 'poll',
   'select exists (select 1 from public.pharmacy_sale_settings where nudge_enabled)',
   'select public.paper_sale_nudge_sweep()', 20000, true,
   'One closing-time nudge for the pharmacies that asked for it, never for a day already closed. Gated, so a fleet with nobody opted in costs one cheap EXISTS.',
   900, 1800, 900, false, true, now() + interval '11 minutes')
on conflict (name) do nothing;

-- ═══════════════════════ 9. WHAT THE SCREEN READS ══════════════════════════
create or replace function public._c429_flag_chip(p_flag text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case p_flag
    when 'ok'             then jsonb_build_object('label', null, 'tone', 'success')
    when 'unreadable'     then jsonb_build_object('label', public.ui_text('paper429.f_unreadable'),  'tone', 'danger')
    when 'low_confidence' then jsonb_build_object('label', public.ui_text('paper429.f_low'),         'tone', 'warning')
    when 'unmatched'      then jsonb_build_object('label', public.ui_text('paper429.f_unmatched'),   'tone', 'warning')
    when 'unknown_item'   then jsonb_build_object('label', public.ui_text('paper429.f_unknown'),     'tone', 'info')
    when 'over_ledger'    then jsonb_build_object('label', public.ui_text('paper429.f_over'),        'tone', 'warning')
    when 'dropped'        then jsonb_build_object('label', public.ui_text('paper429.f_dropped'),     'tone', 'muted')
    else jsonb_build_object('label', null, 'tone', 'muted') end;
$$;

create or replace function public.paper_sale_home(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_shop uuid := public._c429_shop();
  v_rows jsonb; v_open uuid; v_today integer; v_units numeric; v_set public.pharmacy_sale_settings%rowtype;
begin
  if v_shop is null then return public._c429_denied(); end if;
  select * into v_set from public.pharmacy_sale_settings where pharmacy_id = v_shop;

  select count(*), coalesce(sum(l.qty), 0) into v_today, v_units
    from public.pharmacy_sale_line l
    join public.pharmacy_sale_sheet s on s.id = l.sheet_id
   where s.pharmacy_id = v_shop and s.sold_on = public._c429_today()
     and s.status = 'confirmed' and l.applied;

  select id into v_open from public.pharmacy_sale_sheet
   where pharmacy_id = v_shop and status in ('draft','queued','processing','review','read')
   order by created_at desc limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
      'sheet_id', s.id,
      'date_label', to_char(s.sold_on, 'DD Mon YYYY'),
      'status', s.status,
      'chip', case s.status
        when 'confirmed'  then jsonb_build_object('label', public.ui_text('paper429.st_confirmed'),  'tone', 'success')
        when 'review'     then jsonb_build_object('label', public.ui_text('paper429.st_review'),     'tone', 'warning')
        when 'read'       then jsonb_build_object('label', public.ui_text('paper429.st_read'),       'tone', 'info')
        when 'failed'     then jsonb_build_object('label', public.ui_text('paper429.st_failed'),     'tone', 'danger')
        when 'queued'     then jsonb_build_object('label', public.ui_text('paper429.st_queued'),     'tone', 'info')
        when 'processing' then jsonb_build_object('label', public.ui_text('paper429.st_processing'), 'tone', 'info')
        else jsonb_build_object('label', public.ui_text('paper429.st_draft'), 'tone', 'muted') end,
      'lines_label', public._c429_fmt('paper429.lines_count',
                       jsonb_build_object('n', s.line_count::text)),
      'new_label', case when s.mode = 'tally' and s.new_count < s.line_count
                        then public._c429_fmt('paper429.new_count',
                               jsonb_build_object('n', s.new_count::text)) end,
      'reason', s.review_reason, 'error', s.ocr_error,
      'mode', s.mode) order by s.created_at desc), '[]'::jsonb)
    into v_rows
    from (select * from public.pharmacy_sale_sheet
           where pharmacy_id = v_shop
           order by created_at desc limit greatest(coalesce(p_limit, 20), 1)) s;

  return jsonb_build_object('ok', true,
    'title', public.ui_text('paper429.title'),
    'subtitle', public.ui_text('paper429.subtitle'),
    'today', jsonb_build_object(
      'label', public.ui_text('paper429.today_label'),
      'lines', v_today::text,
      'units', coalesce(v_units, 0)::text,
      'summary', public._c429_fmt('paper429.today_summary',
                   jsonb_build_object('n', v_today::text, 'u', coalesce(v_units,0)::text))),
    'actions', jsonb_build_array(
      jsonb_build_object('key', 'page',  'label', public.ui_text('paper429.act_page'),  'primary', true),
      jsonb_build_object('key', 'tally', 'label', public.ui_text('paper429.act_tally')),
      jsonb_build_object('key', 'typed', 'label', public.ui_text('paper429.act_typed'))),
    'open_sheet_id', v_open,
    'sheets', v_rows,
    'empty', case when v_rows = '[]'::jsonb then public.ui_text('paper429.empty') end,
    'settings', jsonb_build_object(
      'nudge_enabled', coalesce(v_set.nudge_enabled, false),
      'nudge_at', to_char(coalesce(v_set.nudge_at, '21:00'::time), 'HH24:MI'),
      'nudge_label', public.ui_text('paper429.nudge_label'),
      'nudge_help',  public.ui_text('paper429.nudge_help')),
    'graduation', case when coalesce((public.paper_sale_graduation() ->> 'show')::boolean, false)
                       then public.paper_sale_graduation() end,
    -- The hard rule, said out loud on the screen the counter uses.
    'not_an_invoice', public.ui_text('paper429.not_an_invoice'));
end $$;

create or replace function public.paper_sale_sheet_get(p_sheet_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c429_shop(); v_s public.pharmacy_sale_sheet%rowtype; v_lines jsonb;
begin
  if v_shop is null then return public._c429_denied(); end if;
  select * into v_s from public.pharmacy_sale_sheet
   where id = p_sheet_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_sheet',
                              'message', public.ui_text('paper429.err_no_sheet'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'line_id', l.id, 'line_no', l.line_no,
      'seen', coalesce(l.seen_text, public.ui_text('paper429.line_unreadable')),
      'product', l.product_name,
      'medicine_id', l.medicine_id,
      'qty', l.qty,
      'qty_label', coalesce(l.qty::text, '—'),
      'qty_assumed', l.qty_assumed,
      'qty_note', case when l.qty_assumed then public.ui_text('paper429.qty_assumed') end,
      'flag', l.flag,
      'chip', public._c429_flag_chip(l.flag),
      'needs_review', l.is_new and l.flag not in ('ok', 'dropped'),
      'is_new', l.is_new,
      'counted_note', case when not l.is_new then public.ui_text('paper429.already_counted') end,
      'on_hand_label', case when l.on_hand is not null
                            then public._c429_fmt('paper429.on_hand',
                                   jsonb_build_object('n', l.on_hand::text)) end,
      'short_label', case when coalesce(l.short_qty, 0) > 0
                          then public._c429_fmt('paper429.short_line',
                                 jsonb_build_object('n', l.short_qty::text)) end,
      'offer_opening', l.flag in ('unknown_item', 'over_ledger'),
      'offer_opening_label', case when l.flag in ('unknown_item', 'over_ledger')
                                  then public.ui_text('paper429.offer_opening') end,
      'match_label', case when l.match_source is null then null
                          else public._c429_fmt('paper429.match_line',
                                 jsonb_build_object('source', l.match_source,
                                   'score', to_char(coalesce(l.match_score,0)*100, 'FM990') || '%')) end)
      order by l.line_no), '[]'::jsonb)
    into v_lines from public.pharmacy_sale_line l where l.sheet_id = p_sheet_id;

  return jsonb_build_object('ok', true,
    'sheet', jsonb_build_object('sheet_id', v_s.id, 'status', v_s.status,
      'mode', v_s.mode,
      'date_label', to_char(v_s.sold_on, 'DD Mon YYYY'),
      'lines_label', public._c429_fmt('paper429.lines_count',
                       jsonb_build_object('n', v_s.line_count::text)),
      'reason', v_s.review_reason, 'error', v_s.ocr_error,
      'can_confirm', v_s.status in ('read', 'review') and v_s.line_count > 0),
    'lines', v_lines,
    'shots', (select coalesce(jsonb_agg(jsonb_build_object('shot_no', sh.shot_no,
                'bucket', sh.bucket, 'path', sh.path) order by sh.shot_no), '[]'::jsonb)
                from public.pharmacy_sale_shot sh where sh.sheet_id = p_sheet_id),
    'confirm_label', public.ui_text('paper429.act_confirm'),
    'close_label',   public.ui_text('paper429.act_close_day'),
    'not_an_invoice', public.ui_text('paper429.not_an_invoice'),
    'poll_ms', case when v_s.status in ('queued','processing') then 2500 else null end);
end $$;

create or replace function public.paper_sale_entry()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_shop uuid := public._c429_shop(); v_rev integer;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select count(*) into v_rev from public.pharmacy_sale_sheet
   where pharmacy_id = v_shop and status in ('review','read');
  return jsonb_build_object('ok', true, 'show', true,
    'label', public.ui_text('paper429.nav_label'),
    'badge', case when v_rev > 0 then v_rev::text else null end,
    'route_key', 'paper_sale');
end $$;

-- ═══════════════════════ 10. WHO MAY CALL WHAT ═════════════════════════════
-- RLS on, no policies — #412's shape. A client SELECT returns zero rows; the
-- only door is a SECURITY DEFINER RPC that resolves the caller's own pharmacy
-- from their JWT and filters on it. Every RPC's WHERE carries
-- `pharmacy_id = _c429_shop()`, so a sheet id from another shop is "not found".
revoke all on public.pharmacy_sale_sheet, public.pharmacy_sale_shot,
              public.pharmacy_sale_line, public.pharmacy_sale_qty_default,
              public.pharmacy_sale_settings, public.pharmacy_sale_config
  from anon, authenticated;

grant execute on function public.paper_sale_home(integer)                  to authenticated;
grant execute on function public.paper_sale_entry()                        to authenticated;
grant execute on function public.paper_sale_start(date, text)              to authenticated;
grant execute on function public.paper_sale_shot_add(uuid, text, text, text) to authenticated;
grant execute on function public.paper_sale_queue(uuid)                    to authenticated;
grant execute on function public.paper_sale_sheet_get(uuid)                to authenticated;
grant execute on function public.paper_sale_line_set(uuid, jsonb)          to authenticated;
grant execute on function public.paper_sale_seed_opening(uuid, numeric)    to authenticated;
grant execute on function public.paper_sale_confirm(uuid)                  to authenticated;
grant execute on function public.paper_sale_close_day(uuid)                to authenticated;
grant execute on function public.paper_sale_settings_set(jsonb)            to authenticated;
grant execute on function public.paper_sale_graduation()                   to authenticated;

revoke all on function public.paper_sale_ocr_input(uuid)                   from anon, authenticated;
revoke all on function public.paper_sale_ocr_report(uuid, jsonb, text)     from anon, authenticated;
revoke all on function public.paper_sale_nudge_sweep()                     from anon, authenticated;
revoke all on function public._c429_dispatch(uuid)                         from anon, authenticated;
revoke all on function public._c429_sale_units(date, date)                 from anon, authenticated;
revoke all on function public._c429_recount(uuid)                          from anon, authenticated;
revoke all on function public._c429_cfg()                                  from anon, authenticated;
revoke all on function public._c419_units(date, date)                      from anon, authenticated;

grant execute on function public.paper_sale_ocr_input(uuid)                to service_role;
grant execute on function public.paper_sale_ocr_report(uuid, jsonb, text)  to service_role;
grant execute on function public.paper_sale_nudge_sweep()                  to service_role;
grant execute on function public._c429_sale_units(date, date)              to service_role;

-- ═══════════════════════ 11. THE WORDS ═════════════════════════════════════
insert into public.ui_copy (key, value) values
  ('paper429.nav_label',   to_jsonb('Paper sales'::text)),
  ('paper429.title',       to_jsonb('Paper sales'::text)),
  ('paper429.subtitle',    to_jsonb('Photograph the page you already write on'::text)),
  ('paper429.empty',       to_jsonb('No pages yet. Photograph today''s sale sheet and your stock updates itself.'::text)),
  ('paper429.err_not_pharmacy', to_jsonb('Paper sales is for a pharmacy account.'::text)),
  ('paper429.err_no_sheet',     to_jsonb('That page is not in your account.'::text)),
  ('paper429.err_no_line',      to_jsonb('That line is not on this page.'::text)),
  ('paper429.err_no_shots',     to_jsonb('Take a photo of the page first.'::text)),
  ('paper429.err_same_page',    to_jsonb('That is the page you just photographed — it is already here.'::text)),
  ('paper429.err_too_many',     to_jsonb('One page holds up to {max} photos. Start another.'::text)),
  ('paper429.err_no_lines',     to_jsonb('No sale lines could be read from that page.'::text)),
  ('paper429.err_nothing_to_add', to_jsonb('There is nothing to add for this line.'::text)),

  ('paper429.act_page',    to_jsonb('Photograph the page'::text)),
  ('paper429.act_tally',   to_jsonb('Re-shoot a running page'::text)),
  ('paper429.act_typed',   to_jsonb('Type it instead'::text)),
  ('paper429.act_confirm', to_jsonb('Update my stock'::text)),
  ('paper429.act_close_day', to_jsonb('Close my day'::text)),

  ('paper429.st_draft',      to_jsonb('Draft'::text)),
  ('paper429.st_queued',     to_jsonb('Waiting'::text)),
  ('paper429.st_processing', to_jsonb('Reading'::text)),
  ('paper429.st_read',       to_jsonb('Read'::text)),
  ('paper429.st_review',     to_jsonb('Check this'::text)),
  ('paper429.st_confirmed',  to_jsonb('Stock updated'::text)),
  ('paper429.st_failed',     to_jsonb('Could not read'::text)),

  ('paper429.f_unreadable',  to_jsonb('Could not read'::text)),
  ('paper429.f_low',         to_jsonb('Please check'::text)),
  ('paper429.f_unmatched',   to_jsonb('Which medicine?'::text)),
  ('paper429.f_unknown',     to_jsonb('Never bought here'::text)),
  ('paper429.f_over',        to_jsonb('More than the shelf holds'::text)),
  ('paper429.f_dropped',     to_jsonb('Skipped'::text)),

  ('paper429.lines_count',   to_jsonb('{n} lines'::text)),
  ('paper429.new_count',     to_jsonb('{n} new since the last photo'::text)),
  ('paper429.line_unreadable', to_jsonb('Could not read this line'::text)),
  ('paper429.qty_assumed',   to_jsonb('Quantity assumed from what you usually sell — check it'::text)),
  ('paper429.already_counted', to_jsonb('Already counted from an earlier photo'::text)),
  ('paper429.on_hand',       to_jsonb('{n} on the shelf'::text)),
  ('paper429.short_line',    to_jsonb('{n} more than the shelf knows about'::text)),
  ('paper429.offer_opening', to_jsonb('Add it to my stock'::text)),
  ('paper429.opening_added', to_jsonb('{n} added to your shelf'::text)),
  ('paper429.opening_note',  to_jsonb('Added from a paper sale — the shelf did not know about it'::text)),
  ('paper429.match_line',    to_jsonb('Matched by {source} · {score}'::text)),
  ('paper429.reason_review', to_jsonb('{n} lines need your eyes'::text)),
  ('paper429.line_saved',    to_jsonb('Saved'::text)),
  ('paper429.queued',        to_jsonb('Reading your page…'::text)),
  ('paper429.shot_added',    to_jsonb('Photo {n} added'::text)),
  ('paper429.confirmed',     to_jsonb('{n} lines, {u} units off your shelf'::text)),
  ('paper429.already_confirmed', to_jsonb('This page has already updated your stock.'::text)),
  ('paper429.short_summary', to_jsonb('{n} units were sold that the shelf never knew about'::text)),
  ('paper429.move_note',     to_jsonb('Sold — written on the paper sheet'::text)),
  ('paper429.short_note',    to_jsonb('Sold more than the shelf knew about'::text)),

  ('paper429.today_label',   to_jsonb('Today'::text)),
  ('paper429.today_summary', to_jsonb('{n} lines · {u} units today'::text)),
  ('paper429.closed_title',  to_jsonb('Day closed'::text)),
  ('paper429.closed_message', to_jsonb('Your stock is up to date.'::text)),
  ('paper429.reorder_hint',  to_jsonb('What to reorder tomorrow'::text)),
  ('paper429.nudge_label',   to_jsonb('Remind me to close the day'::text)),
  ('paper429.nudge_help',    to_jsonb('One reminder, only on a day you have not closed. Off unless you turn it on.'::text)),
  ('paper429.nudge_body',    to_jsonb('Photograph today''s sale sheet before you shut — it takes ten seconds.'::text)),
  ('paper429.settings_saved', to_jsonb('Saved'::text)),

  ('paper429.graduate_title',   to_jsonb('You are ready for the counter app'::text)),
  ('paper429.graduate_body',    to_jsonb('You have photographed {days} days and {lines} lines. Billing at the counter would do this as you sell, and give your customers a printed bill.'::text)),
  ('paper429.graduate_accept',  to_jsonb('Show me the counter'::text)),
  ('paper429.graduate_dismiss', to_jsonb('Not now'::text)),

  -- The hard rule, in the counter's own language, on the screen itself.
  ('paper429.not_an_invoice', to_jsonb('A paper sale updates your stock only. It is not a bill and it does not go into your GST return — use the counter app for that.'::text)),
  ('paper429.guide',          to_jsonb('Lay the page flat and fill the frame. One photo per page — take another for the next page.'::text))
on conflict (key) do update set value = excluded.value;

insert into public.ui_copy (key, value) values
  ('paper429.guide_points', jsonb_build_array(
     'One photo per page, in order',
     'Flatten a curled page — a curl loses the quantities',
     'Hindi and English on the same line is fine',
     'Anything unreadable is flagged, never guessed'))
on conflict (key) do update set value = excluded.value;

-- THE READER'S INSTRUCTIONS. In copy, not in the edge function, so a
-- handwriting lesson is an UPDATE. The OCR naming rule is carried verbatim.
insert into public.ui_copy (key, value) values
  ('paper429.prompt', to_jsonb(
'You are reading photographs of a HANDWRITTEN sale pad from an Indian pharmacy counter. Each line is one item that was sold, with a quantity.

The handwriting is fast and informal. Expect: mixed Hindi (Devanagari) and English on the same page and sometimes the same line; shop-specific abbreviations ("mtk lc", "zerodol sp", "pcm"); quantities written as a bare number, as "x2", "2x", "-2", "(2)", or as TALLY MARKS (|||| or ||||-crossed groups of five); strike-throughs; and lines squeezed into a margin.

RULES THAT OVERRIDE EVERYTHING:
- Return the item text VERBATIM, exactly as written. Never expand an abbreviation, never correct a spelling, never translate, never substitute a brand or company name, and never use outside knowledge of medicine names.
- If a line cannot be read, say so: "readable": false. NEVER invent, infer or complete an item or a quantity. A missing value is correct; a guessed value is a defect.
- Count tally marks exactly. If you are not certain of the count, leave qty null rather than estimating.
- If NO quantity is written for a line, return qty null. Do not assume 1.
- A struck-through line was cancelled: return it with "struck": true.
- Read the lines TOP TO BOTTOM in the order they are written, and give every photo''s lines in photo order. Do not merge or reorder.
- Report your own confidence 0..1 per line.

Answer with ONE JSON object and nothing else:
{"lines":[{"item":"as written","qty":0,"qty_form":"digit|x2|tally|none",
           "struck":false,"readable":true,"confidence":0.0}]}

Use null for anything not written. Do not add commentary.'::text))
on conflict (key) do update set value = excluded.value;
