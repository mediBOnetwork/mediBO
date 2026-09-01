-- CMD #418 — Prescription photo to bill, matched against the shop's OWN stock.
--
-- The counter boy photographs the prescription and the draft bill builds
-- itself. Everything about that sentence is load-bearing except the word
-- "itself": the human ALWAYS confirms. OCR never bills alone, and this file is
-- written so that it cannot — a scan produces a DRAFT, and only
-- `rx_scan_confirm` (a deliberate human action carrying the corrected lines)
-- turns a draft into a POS sale.
--
-- ─────────────── THE CAMERA CONTRACT, INHERITED NOT REINVENTED ──────────────
-- CLAUDE.md's OCR NAMING RULE is absolute: OCR returns VERBATIM text exactly as
-- printed, never an expansion, never a correction, never world knowledge. A
-- prescription is the hardest place to honour that and the most important: a
-- model that "helpfully" reads a doctor's scrawl as the drug it guesses you
-- meant is how a patient gets the wrong medicine. So `rx-ocr` copies the
-- gemini-3.5-flash Vertex pattern from `gemini-ocr` byte for byte and adds one
-- rule on top: an unreadable line comes back with `readable:false` and the
-- characters it could see, NEVER a name it inferred.
--
-- MATCHING is a separate step, and it is SQL. That separation is the safety
-- property: the model never learns what is on the shelf, so it can never be
-- steered toward "recognising" the thing the shop happens to stock. Gemini
-- reads the paper; Postgres decides what that means for this pharmacy.
--
-- ─────────────────────────── THE THREE OUTCOMES ─────────────────────────────
--   in_stock    — matched to a `pharmacy_stock` row; the draft line is
--                 pre-filled with the FEFO batch (first expiry, first out) so
--                 the oldest stock leaves first, which is the whole point of
--                 knowing the expiry.
--   substitute  — named, in the catalogue, but not on this shelf. Same-salt
--                 alternatives THAT ARE IN STOCK are offered, best margin
--                 first, because that is the choice the pharmacist is actually
--                 making at the counter.
--   unmatched   — left for the human, with the verbatim text shown. Never
--                 guessed onto a product.
--
-- ─────────────────────────── SCHEDULE H / LEGAL ─────────────────────────────
-- The Rx image is stored against the sale, in a PRIVATE bucket, fenced by RLS
-- to the pharmacy that took it. That is the Schedule H trace an inspector asks
-- for: which prescription authorised this sale. It is never public, never
-- shared across shops, and it outlives the draft.

-- ═════════════════════════════ 1. TABLES ════════════════════════════════════

create table if not exists public.rx_scan (
  id            uuid primary key default gen_random_uuid(),
  pharmacy_id   uuid not null references public.pharmacy_profiles(id) on delete cascade,

  status        text not null default 'draft'
                check (status in ('uploading','reading','draft','confirmed','discarded','failed')),

  -- The prescription image. Private bucket, path scoped by pharmacy id.
  image_bucket  text not null default 'rx-scans',
  image_path    text,
  image_mime    text,
  image_bytes   integer,

  -- What the model said, kept whole and unedited. The audit answer to "why did
  -- it put that on the bill" is this column, not a reconstruction.
  ocr_raw       jsonb,
  ocr_model     text,
  ocr_error     text,
  read_ms       integer,

  patient_name  text,
  doctor_name   text,

  -- Set only by rx_scan_confirm, and only ever once.
  sale_id       uuid references public.pos_sales(id) on delete set null,
  confirmed_by  uuid,
  confirmed_at  timestamptz,

  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists rx_scan_shop_idx
  on public.rx_scan (pharmacy_id, created_at desc);
create index if not exists rx_scan_sale_idx
  on public.rx_scan (sale_id) where sale_id is not null;

create table if not exists public.rx_scan_line (
  id            uuid primary key default gen_random_uuid(),
  scan_id       uuid not null references public.rx_scan(id) on delete cascade,
  line_no       integer not null,

  -- VERBATIM, exactly as the camera contract requires. `seen_text` is what is
  -- printed on the paper; nothing downstream is allowed to overwrite it.
  seen_text     text not null,
  seen_strength text,
  seen_dose     text,
  seen_duration text,
  readable      boolean not null default true,
  confidence    text not null default 'low'
                check (confidence in ('high','medium','low')),

  -- The quantity the DURATION implies, and the arithmetic that produced it, so
  -- a wrong number is explainable instead of magic.
  qty_guess     numeric(12,3),
  qty_basis     text,

  -- What SQL made of it. Never what the model made of it.
  match_kind    text not null default 'unmatched'
                check (match_kind in ('in_stock','substitute','catalog_only','unmatched')),
  medicine_id   bigint,
  matched_name  text,
  stock_id      uuid,
  batch_no      text,
  expiry        text,
  on_hand       numeric(12,3),
  unit_cost     numeric(12,2),
  mrp           numeric(12,2),

  -- Offered alternatives for a line this shop cannot fill as written.
  substitutes   jsonb not null default '[]'::jsonb,

  created_at    timestamptz not null default now(),
  unique (scan_id, line_no)
);
create index if not exists rx_scan_line_scan_idx
  on public.rx_scan_line (scan_id, line_no);

alter table public.rx_scan      enable row level security;
alter table public.rx_scan_line enable row level security;

-- No policies: every read and write goes through the SECURITY DEFINER RPCs
-- below, each of which resolves the caller's own pharmacy first. A direct
-- PostgREST select returns nothing.

-- The Rx image bucket. PRIVATE — a prescription is patient data and a Schedule
-- H record, and neither belongs on a public URL.
insert into storage.buckets (id, name, public)
values ('rx-scans', 'rx-scans', false)
on conflict (id) do nothing;

-- ═════════════════════════════ 2. COPY ══════════════════════════════════════

insert into public.ui_copy (key, value) values
  ('rx.title',              to_jsonb('Prescription'::text)),
  ('rx.subtitle',           to_jsonb('Photograph it, check it, bill it'::text)),
  ('rx.nav_label',          to_jsonb('Scan a prescription'::text)),
  ('rx.capture_button',     to_jsonb('Photograph the prescription'::text)),
  ('rx.uploading',          to_jsonb('Uploading…'::text)),
  ('rx.reading',            to_jsonb('Reading the prescription…'::text)),
  ('rx.reading_hint',       to_jsonb('This takes a few seconds. The photo stays on the bill afterwards.'::text)),
  ('rx.draft_title',        to_jsonb('Draft bill'::text)),
  ('rx.photo_title',        to_jsonb('The prescription'::text)),
  ('rx.check_note',         to_jsonb('Check every line against the photo before you confirm. Nothing is billed until you do.'::text)),
  ('rx.in_stock_label',     to_jsonb('On your shelf'::text)),
  ('rx.substitute_label',   to_jsonb('Not in stock'::text)),
  ('rx.catalog_label',      to_jsonb('Not on your shelf'::text)),
  ('rx.unmatched_label',    to_jsonb('Could not be matched'::text)),
  ('rx.unmatched_hint',     to_jsonb('Add this one yourself, or leave it off the bill.'::text)),
  ('rx.unreadable_label',   to_jsonb('Could not be read'::text)),
  ('rx.unreadable_hint',    to_jsonb('The handwriting could not be read. It has not been guessed.'::text)),
  ('rx.batch_label',        to_jsonb('Batch'::text)),
  ('rx.expiry_label',       to_jsonb('Expiry'::text)),
  ('rx.fefo_note',          to_jsonb('Oldest batch first'::text)),
  ('rx.qty_label',          to_jsonb('Qty'::text)),
  ('rx.qty_basis_label',    to_jsonb('From the prescription'::text)),
  ('rx.on_hand_label',      to_jsonb('In stock'::text)),
  ('rx.seen_label',         to_jsonb('Written as'::text)),
  ('rx.substitutes_title',  to_jsonb('In stock, same salt'::text)),
  ('rx.substitutes_none',   to_jsonb('Nothing with the same salt is in stock either.'::text)),
  ('rx.substitute_pick',    to_jsonb('Use this instead'::text)),
  ('rx.margin_label',       to_jsonb('Your margin'::text)),
  ('rx.confidence_low',     to_jsonb('Low confidence — check this line'::text)),
  ('rx.confidence_medium',  to_jsonb('Check this line'::text)),
  ('rx.include_label',      to_jsonb('On the bill'::text)),
  ('rx.confirm_button',     to_jsonb('Confirm and bill'::text)),
  ('rx.confirming',         to_jsonb('Billing…'::text)),
  ('rx.confirmed_toast',    to_jsonb('Bill saved against this prescription'::text)),
  ('rx.discard_button',     to_jsonb('Discard'::text)),
  ('rx.discarded_toast',    to_jsonb('Prescription discarded'::text)),
  ('rx.empty',              to_jsonb('Nothing could be read from this photo.'::text)),
  ('rx.empty_hint',         to_jsonb('Take the photo again in better light, or bill it by hand.'::text)),
  ('rx.legal_note',         to_jsonb('The photo is kept against this bill as the prescription record.'::text)),
  ('rx.recent_title',       to_jsonb('Recent prescriptions'::text)),
  ('rx.recent_empty',       to_jsonb('No prescriptions scanned yet.'::text)),
  ('rx.retry',              to_jsonb('Retry'::text)),
  ('rx.boot_failed',        to_jsonb('The scanner could not be reached. Check the connection and try again.'::text)),
  ('rx.err_not_pharmacy',   to_jsonb('The prescription scanner is available on a pharmacy account.'::text)),
  ('rx.err_not_found',      to_jsonb('That prescription was not found.'::text)),
  ('rx.err_no_image',       to_jsonb('No photo was attached.'::text)),
  ('rx.err_already',        to_jsonb('This prescription has already been billed.'::text)),
  ('rx.err_no_lines',       to_jsonb('Tick at least one line before billing.'::text)),
  ('rx.err_read_failed',    to_jsonb('The photo could not be read. Take it again, or bill it by hand.'::text))
on conflict (key) do nothing;

-- ═══════════════════════ 3. THE SMALL HELPERS ═══════════════════════════════

create or replace function public._c418_shop()
returns uuid language sql stable security definer
set search_path to 'public' as $$ select public.my_customer_id(); $$;

create or replace function public._c418_denied()
returns jsonb language sql stable
set search_path to 'public' as $$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('rx.err_not_pharmacy'));
$$;

-- A prescription is written the way a doctor writes, not the way a catalogue
-- is indexed. Reduce both sides to comparable letters-and-digits before any
-- match is attempted: 'Tab. AZITHRAL-500' and 'Azithral 500 Tablet' must meet.
create or replace function public._c418_norm(p text)
returns text language sql immutable
set search_path to 'public' as $$
  select nullif(btrim(regexp_replace(
           regexp_replace(lower(coalesce(p, '')),
             '\y(tab|tabs|tablet|cap|caps|capsule|syr|syrup|inj|injection|susp|suspension|oint|ointment|cream|drops|drop|sos|bd|od|tds|qid|hs|stat|mg|ml|gm|g|mcg)\y',
             ' ', 'g'),
           '[^a-z0-9]+', ' ', 'g')), '');
$$;

-- The FIRST salt of a composition, which is what "same salt" means at a
-- counter. A two-salt combination is matched on the whole string instead.
create or replace function public._c418_salt_key(p text)
returns text language sql immutable
set search_path to 'public' as $$
  select nullif(btrim(regexp_replace(lower(coalesce(p, '')),
                      '\s*\(.*?\)\s*', ' ', 'g')), '');
$$;

-- ═══════════════ 4. THE MATCHER — SQL, never the model ══════════════════════
--
-- Runs once per line, after the read. Order matters and it is the shop's order,
-- not the catalogue's:
--   1. THEIR shelf first. If this pharmacy has it, that is the answer, and the
--      batch offered is the FEFO one — first expiry, first out — because that
--      is the only reason a pharmacy bothers recording expiry at all.
--   2. The catalogue second, for a line that names a real medicine this shop
--      has not got. Same-salt alternatives that ARE in stock are attached,
--      best margin first: at the counter that is the actual decision.
--   3. Nothing. Left for the human, with the verbatim text intact.
--
-- An UNREADABLE line is never matched. It skips all three and stays unreadable,
-- because a fuzzy match on characters nobody could read is exactly the failure
-- mode the camera contract exists to prevent.
create or replace function public._c418_match_line(p_line_id uuid)
returns void language plpgsql
set search_path to 'public' as $function$
declare
  l  public.rx_scan_line%rowtype;
  v_shop uuid;
  v_norm text;
  v_stock record;
  v_cat record;
  v_salt text;
  v_subs jsonb;
begin
  select * into l from public.rx_scan_line where id = p_line_id;
  if not found then return; end if;
  select pharmacy_id into v_shop from public.rx_scan where id = l.scan_id;

  if not l.readable then
    update public.rx_scan_line set match_kind = 'unmatched' where id = l.id;
    return;
  end if;

  v_norm := public._c418_norm(l.seen_text);
  if v_norm is null then
    update public.rx_scan_line set match_kind = 'unmatched' where id = l.id;
    return;
  end if;

  -- ── 1. their own shelf, FEFO ──────────────────────────────────────────────
  select s.id, s.medicine_id, s.product_name, s.batch_no, s.expiry, s.qty,
         s.unit_cost, s.mrp
    into v_stock
    from public.pharmacy_stock s
   where s.pharmacy_id = v_shop
     and coalesce(s.qty, 0) > 0
     and (public._c418_norm(s.product_name) = v_norm
          or public._c418_norm(s.product_name) like v_norm || ' %'
          or v_norm like public._c418_norm(s.product_name) || ' %')
   order by s.expiry_on nulls last, s.created_at   -- FEFO
   limit 1;

  if v_stock.id is not null then
    update public.rx_scan_line
       set match_kind   = 'in_stock',
           medicine_id  = v_stock.medicine_id,
           matched_name = v_stock.product_name,
           stock_id     = v_stock.id,
           batch_no     = v_stock.batch_no,
           expiry       = v_stock.expiry,
           on_hand      = v_stock.qty,
           unit_cost    = v_stock.unit_cost,
           mrp          = coalesce(v_stock.mrp,
                            public._pos_num((select m.mrp from public."MEDICINE" m
                                              where m.id = v_stock.medicine_id)))
     where id = l.id;
    return;
  end if;

  -- ── 2. the catalogue, then same-salt alternatives that ARE in stock ───────
  select m.id, m.product_name, m.salt_composition, public._pos_num(m.mrp) as mrp
    into v_cat
    from public."MEDICINE" m
   where public._c418_norm(m.product_name) = v_norm
   order by coalesce(m.sales_count, 0) desc
   limit 1;

  if v_cat.id is null then
    -- one prefix attempt, deliberately narrow: 'azithral 500' finding
    -- 'Azithral 500 Tablet' is a match; 'a' finding everything is not.
    if length(v_norm) >= 5 then
      select m.id, m.product_name, m.salt_composition, public._pos_num(m.mrp) as mrp
        into v_cat
        from public."MEDICINE" m
       where public._c418_norm(m.product_name) like v_norm || ' %'
       order by coalesce(m.sales_count, 0) desc
       limit 1;
    end if;
  end if;

  if v_cat.id is null then
    update public.rx_scan_line set match_kind = 'unmatched' where id = l.id;
    return;
  end if;

  v_salt := public._c418_salt_key(v_cat.salt_composition);

  -- Best MARGIN first. That is the choice the pharmacist is making, and it is
  -- the shop's own money: margin is mrp - unit_cost on THIS shelf, never a
  -- catalogue number and never a trade rate from the mediBO side.
  select coalesce(jsonb_agg(x order by (x->>'margin_value')::numeric desc), '[]'::jsonb)
    into v_subs
    from (
      select jsonb_build_object(
               'stock_id',      s.id,
               'medicine_id',   s.medicine_id,
               'product_name',  s.product_name,
               'batch_label',   case when nullif(btrim(coalesce(s.batch_no,'')),'') is not null
                                     then public.ui_text('rx.batch_label') || ' ' || s.batch_no
                                     else null end,
               'expiry',        s.expiry,
               'on_hand_label', trim_scale(s.qty)::text,
               'mrp_display',   public.inr_money(coalesce(s.mrp, 0)),
               'margin_display', public.inr_money(
                                   greatest(coalesce(s.mrp,0) - coalesce(s.unit_cost,0), 0)),
               'margin_value',  greatest(coalesce(s.mrp,0) - coalesce(s.unit_cost,0), 0),
               'pick_label',    public.ui_text('rx.substitute_pick')) as x
        from public.pharmacy_stock s
        join public."MEDICINE" m2 on m2.id = s.medicine_id
       where s.pharmacy_id = v_shop
         and coalesce(s.qty, 0) > 0
         and s.medicine_id is distinct from v_cat.id
         and v_salt is not null
         and public._c418_salt_key(m2.salt_composition) = v_salt
       order by greatest(coalesce(s.mrp,0) - coalesce(s.unit_cost,0), 0) desc
       limit 5) q;

  update public.rx_scan_line
     set match_kind   = case when jsonb_array_length(v_subs) > 0
                             then 'substitute' else 'catalog_only' end,
         medicine_id  = v_cat.id,
         matched_name = v_cat.product_name,
         mrp          = v_cat.mrp,
         substitutes  = v_subs
   where id = l.id;
end $function$;

-- ═══════════════════ 5. THE FLOW: create → report → confirm ═════════════════

-- Where to put the photo. The path is minted HERE, scoped by pharmacy id, so a
-- client cannot choose to write into another shop's folder.
create or replace function public.rx_scan_new()
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c418_shop(); v_id uuid;
begin
  if v_shop is null then return public._c418_denied(); end if;
  insert into public.rx_scan (pharmacy_id, status, created_by)
  values (v_shop, 'uploading', auth.uid())
  returning id into v_id;
  return jsonb_build_object(
    'ok', true,
    'scan_id',   v_id,
    'bucket',    'rx-scans',
    'path',      v_shop::text || '/' || v_id::text || '.jpg',
    'uploading', public.ui_text('rx.uploading'),
    'reading',   public.ui_text('rx.reading'),
    'reading_hint', public.ui_text('rx.reading_hint'));
end $function$;

-- The client tells us the photo has landed. Nothing is read yet — the edge
-- function does that and calls rx_scan_report back.
create or replace function public.rx_scan_uploaded(
  p_scan_id uuid, p_path text, p_mime text default 'image/jpeg',
  p_bytes integer default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c418_shop(); v_n integer;
begin
  if v_shop is null then return public._c418_denied(); end if;
  if coalesce(btrim(p_path), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'no_image',
                              'message', public.ui_text('rx.err_no_image'));
  end if;
  update public.rx_scan
     set image_path = p_path, image_mime = p_mime, image_bytes = p_bytes,
         status = 'reading', updated_at = now()
   where id = p_scan_id and pharmacy_id = v_shop and status = 'uploading';
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found',
                              'message', public.ui_text('rx.err_not_found'));
  end if;
  return jsonb_build_object('ok', true, 'scan_id', p_scan_id, 'status', 'reading');
end $function$;

-- The edge function's only door back in. service_role only: it carries the
-- model's output, and nothing reachable by a browser may write that.
--
-- p_lines: [{seen_text, seen_strength?, seen_dose?, seen_duration?,
--            readable, confidence, qty_guess?, qty_basis?}]
create or replace function public.rx_scan_report(
  p_scan_id uuid, p_ok boolean, p_model text, p_lines jsonb,
  p_raw jsonb default null, p_error text default null, p_ms integer default null)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare r public.rx_scan%rowtype; ln record;
begin
  select * into r from public.rx_scan where id = p_scan_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if not coalesce(p_ok, false) then
    update public.rx_scan
       set status = 'failed', ocr_error = p_error, ocr_model = p_model,
           ocr_raw = p_raw, read_ms = p_ms, updated_at = now()
     where id = p_scan_id;
    return jsonb_build_object('ok', true, 'status', 'failed');
  end if;

  delete from public.rx_scan_line where scan_id = p_scan_id;

  insert into public.rx_scan_line
    (scan_id, line_no, seen_text, seen_strength, seen_dose, seen_duration,
     readable, confidence, qty_guess, qty_basis)
  select p_scan_id,
         (row_number() over ())::int,
         coalesce(nullif(btrim(e->>'seen_text'), ''), '?'),
         nullif(btrim(e->>'seen_strength'), ''),
         nullif(btrim(e->>'seen_dose'), ''),
         nullif(btrim(e->>'seen_duration'), ''),
         coalesce((e->>'readable')::boolean, true),
         case lower(coalesce(e->>'confidence', 'low'))
           when 'high' then 'high' when 'medium' then 'medium' else 'low' end,
         nullif(e->>'qty_guess', '')::numeric,
         nullif(btrim(e->>'qty_basis'), '')
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e;

  for ln in select id from public.rx_scan_line where scan_id = p_scan_id loop
    perform public._c418_match_line(ln.id);
  end loop;

  update public.rx_scan
     set status = 'draft', ocr_model = p_model, ocr_raw = p_raw,
         ocr_error = null, read_ms = p_ms, updated_at = now()
   where id = p_scan_id;

  return jsonb_build_object('ok', true, 'status', 'draft',
    'lines', (select count(*) from public.rx_scan_line where scan_id = p_scan_id));
end $function$;

-- ── the counter screen: the photo beside the draft, from one call ───────────
create or replace function public._c418_detail(p_shop uuid, p_scan_id uuid)
returns jsonb language plpgsql stable
set search_path to 'public' as $function$
declare r public.rx_scan%rowtype; v_lines jsonb;
begin
  select * into r from public.rx_scan where id = p_scan_id and pharmacy_id = p_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
                              'message', public.ui_text('rx.err_not_found'));
  end if;

  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb) into v_lines from (
    select l.line_no as ord, jsonb_build_object(
      'line_id',      l.id,
      'line_no',      l.line_no,
      -- VERBATIM, always shown, whatever the match did. The counter checks the
      -- draft against the paper, and it can only do that if the paper's own
      -- words are on the screen next to the product name.
      'seen_label',   public.ui_text('rx.seen_label'),
      'seen_text',    btrim(concat_ws(' ', l.seen_text, l.seen_strength)),
      'seen_detail',  nullif(btrim(concat_ws(' · ', l.seen_dose, l.seen_duration)), ''),
      'readable',     l.readable,
      'match_kind',   l.match_kind,
      'state_label',  case
                        when not l.readable            then public.ui_text('rx.unreadable_label')
                        when l.match_kind = 'in_stock' then public.ui_text('rx.in_stock_label')
                        when l.match_kind = 'substitute' then public.ui_text('rx.substitute_label')
                        when l.match_kind = 'catalog_only' then public.ui_text('rx.catalog_label')
                        else public.ui_text('rx.unmatched_label') end,
      'state_hint',   case
                        when not l.readable            then public.ui_text('rx.unreadable_hint')
                        when l.match_kind = 'unmatched' then public.ui_text('rx.unmatched_hint')
                        else null end,
      'tone',         case
                        when not l.readable            then 'danger'
                        when l.match_kind = 'in_stock' then 'success'
                        when l.match_kind = 'substitute' then 'warning'
                        when l.match_kind = 'catalog_only' then 'warning'
                        else 'danger' end,
      'product_name', l.matched_name,
      'medicine_id',  l.medicine_id,
      'batch_label',  case when nullif(btrim(coalesce(l.batch_no,'')),'') is not null
                           then public.ui_text('rx.batch_label') || ' ' || l.batch_no
                           else null end,
      'expiry_label', case when nullif(btrim(coalesce(l.expiry,'')),'') is not null
                           then public.ui_text('rx.expiry_label') || ' ' || l.expiry
                           else null end,
      'fefo_note',    case when l.match_kind = 'in_stock'
                                and nullif(btrim(coalesce(l.batch_no,'')),'') is not null
                           then public.ui_text('rx.fefo_note') else null end,
      'on_hand_label', case when l.on_hand is not null
                            then public.ui_text('rx.on_hand_label') || ' '
                                 || trim_scale(l.on_hand)::text else null end,
      'mrp_display',  case when l.mrp is not null then public.inr_money(l.mrp) end,
      'qty',          l.qty_guess,
      'qty_label',    public.ui_text('rx.qty_label'),
      'qty_basis',    case when l.qty_basis is not null
                           then public.ui_text('rx.qty_basis_label') || ': ' || l.qty_basis
                           else null end,
      -- Only a line the shop can actually fill starts ticked. Everything else
      -- is the human's decision, which is the entire point of this screen.
      'default_on',   l.match_kind = 'in_stock' and l.readable,
      'include_label', public.ui_text('rx.include_label'),
      'confidence',   l.confidence,
      'confidence_note', case l.confidence
                           when 'low'    then public.ui_text('rx.confidence_low')
                           when 'medium' then public.ui_text('rx.confidence_medium')
                           else null end,
      'substitutes_title', case when jsonb_array_length(l.substitutes) > 0
                                then public.ui_text('rx.substitutes_title') end,
      'substitutes_none',  case when l.match_kind = 'catalog_only'
                                then public.ui_text('rx.substitutes_none') end,
      'substitutes',  l.substitutes) as x
      from public.rx_scan_line l
     where l.scan_id = r.id
     order by l.line_no) q;

  return jsonb_build_object(
    'ok', true,
    'scan_id',     r.id,
    'status',      r.status,
    'is_draft',    r.status = 'draft',
    'is_reading',  r.status in ('uploading','reading'),
    'title',       public.ui_text('rx.title'),
    'subtitle',    public.ui_text('rx.subtitle'),
    'photo_title', public.ui_text('rx.photo_title'),
    'draft_title', public.ui_text('rx.draft_title'),
    'check_note',  public.ui_text('rx.check_note'),
    'legal_note',  public.ui_text('rx.legal_note'),
    'reading',     public.ui_text('rx.reading'),
    'reading_hint', public.ui_text('rx.reading_hint'),
    -- The screen never builds a URL. It is handed the bucket and the path, the
    -- same contract the #403 document layer uses.
    'image',       jsonb_build_object(
                     'has',    r.image_path is not null,
                     'bucket', r.image_bucket,
                     'path',   r.image_path),
    'poll_ms',     2000,
    'lines',       v_lines,
    'has_lines',   jsonb_array_length(v_lines) > 0,
    'empty',       public.ui_text('rx.empty'),
    'empty_hint',  public.ui_text('rx.empty_hint'),
    'failed_message', case when r.status = 'failed'
                           then coalesce(nullif(r.ocr_error, ''),
                                         public.ui_text('rx.err_read_failed')) end,
    'confirm_button', public.ui_text('rx.confirm_button'),
    'confirming',     public.ui_text('rx.confirming'),
    'discard_button', public.ui_text('rx.discard_button'),
    'sale_id',        r.sale_id,
    'confirmed',      r.status = 'confirmed');
end $function$;

create or replace function public.rx_scan_detail(p_scan_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c418_shop();
begin
  if v_shop is null then return public._c418_denied(); end if;
  return public._c418_detail(v_shop, p_scan_id);
end $function$;

-- ── confirm: the ONLY door from a draft to a bill ───────────────────────────
-- p_lines is what the HUMAN left on the screen after correcting it:
--   [{medicine_id, product_name?, qty, mrp?, disc_pct?, batch_no?, expiry?}]
-- It is passed straight to #411's pos_commit_sale, which prices it. This
-- function adds no money arithmetic of its own — the retail bill has exactly
-- one pricing engine and it is not this one.
create or replace function public.rx_scan_confirm(
  p_scan_id uuid, p_client_action_id uuid, p_lines jsonb,
  p_payment_mode text default 'cash', p_patient jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare
  v_shop uuid := public._c418_shop();
  r public.rx_scan%rowtype;
  v_sale jsonb;
begin
  if v_shop is null then return public._c418_denied(); end if;

  select * into r from public.rx_scan
   where id = p_scan_id and pharmacy_id = v_shop for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
                              'message', public.ui_text('rx.err_not_found'));
  end if;
  if r.status = 'confirmed' then
    return jsonb_build_object('ok', false, 'error', 'already_billed',
                              'message', public.ui_text('rx.err_already'),
                              'sale_id', r.sale_id);
  end if;
  if coalesce(jsonb_array_length(p_lines), 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_lines',
                              'message', public.ui_text('rx.err_no_lines'));
  end if;

  v_sale := public.pos_commit_sale(p_client_action_id, p_lines, 0,
                                   p_payment_mode, p_patient);
  if not coalesce((v_sale->>'ok')::boolean, false) then
    return v_sale;   -- the POS engine's own refusal, in its own words
  end if;

  update public.rx_scan
     set status = 'confirmed',
         sale_id = nullif(v_sale->>'sale_id', '')::uuid,
         confirmed_by = auth.uid(), confirmed_at = now(), updated_at = now()
   where id = r.id;

  return v_sale || jsonb_build_object(
    'scan_id', r.id,
    'rx_toast', public.ui_text('rx.confirmed_toast'),
    'legal_note', public.ui_text('rx.legal_note'));
end $function$;

create or replace function public.rx_scan_discard(p_scan_id uuid)
returns jsonb language plpgsql security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c418_shop(); v_n integer;
begin
  if v_shop is null then return public._c418_denied(); end if;
  update public.rx_scan set status = 'discarded', updated_at = now()
   where id = p_scan_id and pharmacy_id = v_shop and status <> 'confirmed';
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found',
                              'message', public.ui_text('rx.err_not_found'));
  end if;
  return jsonb_build_object('ok', true, 'toast', public.ui_text('rx.discarded_toast'));
end $function$;

create or replace function public.rx_scan_recent(p_limit integer default 20)
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c418_shop();
begin
  if v_shop is null then return public._c418_denied(); end if;
  return jsonb_build_object(
    'ok', true,
    'title', public.ui_text('rx.recent_title'),
    'empty', public.ui_text('rx.recent_empty'),
    'capture_button', public.ui_text('rx.capture_button'),
    'scans', coalesce((
      select jsonb_agg(jsonb_build_object(
               'scan_id', s.id,
               'status',  s.status,
               'date_label', to_char(s.created_at at time zone 'Asia/Kolkata',
                                     'DD Mon, HH12:MI AM'),
               'line_count_label', (select count(*)::text from public.rx_scan_line l
                                     where l.scan_id = s.id) || ' × '
                                   || public.ui_text('rx.qty_label'),
               'billed', s.sale_id is not null,
               'invoice_no', (select p.invoice_no from public.pos_sales p
                               where p.id = s.sale_id))
             order by s.created_at desc)
        from (select * from public.rx_scan
               where pharmacy_id = v_shop and status <> 'discarded'
               order by created_at desc
               limit least(greatest(coalesce(p_limit,20),1),100)) s), '[]'::jsonb));
end $function$;

create or replace function public.rx_scan_entry()
returns jsonb language plpgsql stable security definer
set search_path to 'public' as $function$
declare v_shop uuid := public._c418_shop();
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  return jsonb_build_object(
    'ok', true, 'show', true,
    'route_key', 'rx_scan', 'icon_key', 'description',
    'label',     public.ui_text('rx.nav_label'),
    'sub_label', public.ui_text('rx.subtitle'));
end $function$;

-- What the edge function needs to do its job, and nothing more. service_role.
create or replace function public.rx_scan_read_input(p_scan_id uuid)
returns jsonb language sql stable security definer
set search_path to 'public' as $$
  select jsonb_build_object('ok', r.id is not null, 'scan_id', r.id,
                            'bucket', r.image_bucket, 'path', r.image_path,
                            'mime', coalesce(r.image_mime, 'image/jpeg'))
    from public.rx_scan r where r.id = p_scan_id;
$$;

-- ═════════ 6. STORAGE RLS — a prescription belongs to ONE pharmacy ══════════
-- The path is '<pharmacy_id>/<scan_id>.jpg', minted by rx_scan_new(), so the
-- fence is the first path segment. A pharmacy reads and writes its own folder
-- and cannot see another's; the bucket is private, so there is no public URL
-- to leak either. This is the Schedule H record — it gets a real fence.
drop policy if exists rx_scans_own_read   on storage.objects;
drop policy if exists rx_scans_own_write  on storage.objects;

create policy rx_scans_own_read on storage.objects
  for select to authenticated
  using (bucket_id = 'rx-scans'
         and (storage.foldername(name))[1] = public.my_customer_id()::text);

create policy rx_scans_own_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'rx-scans'
              and (storage.foldername(name))[1] = public.my_customer_id()::text);

-- ═══════════════════════════ 7. THE GRANT FENCE ═════════════════════════════
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'rx\_scan\_%' or p.proname like '\_c418\_%'
            or p.proname like 'c418\_%')
  loop
    execute format('revoke all on function %s from public', r.sig);
    execute format('revoke all on function %s from anon', r.sig);
    execute format('revoke all on function %s from authenticated', r.sig);
  end loop;
end $$;

grant execute on function public.rx_scan_entry()                     to authenticated;
grant execute on function public.rx_scan_new()                       to authenticated;
grant execute on function public.rx_scan_uploaded(uuid, text, text, integer) to authenticated;
grant execute on function public.rx_scan_detail(uuid)                to authenticated;
grant execute on function public.rx_scan_confirm(uuid, uuid, jsonb, text, jsonb) to authenticated;
grant execute on function public.rx_scan_discard(uuid)               to authenticated;
grant execute on function public.rx_scan_recent(integer)             to authenticated;

-- The model's door back in, and the renderer's input. service_role only:
-- rx_scan_report WRITES what the model said, and rx_scan_read_input makes no
-- shop check because only the edge function calls it, with the service key.
grant execute on function public.rx_scan_report(uuid, boolean, text, jsonb, jsonb, text, integer) to service_role;
grant execute on function public.rx_scan_read_input(uuid)            to service_role;

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, roles_allowed,
   description)
values
  ('admin.rx_scan', 'Prescription scan', 'Pharmacy tools', 'description',
   'rx_scan', 4180, 'medibo', false, 'none', true, 'parties', 'dashboard',
   array['admin','super_admin'],
   'CMD #418 — prescription photo to draft bill: OCR against the shop''s own stock, FEFO batch, same-salt substitutes, human confirms.')
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key,
      description = excluded.description, is_active = excluded.is_active;

-- ── the security reporter the proof asserts on ──────────────────────────────
create or replace function public.c418_qa_report()
returns jsonb language sql stable security definer
set search_path to 'public' as $$
  select jsonb_build_object(
    'rls_off', coalesce((select string_agg(tablename, ',' order by tablename)
                           from pg_tables where schemaname = 'public'
                            and tablename like 'rx\_scan%' and not rowsecurity), 'all_on'),
    'anon_fns', coalesce((select string_agg(p.proname, ',' order by p.proname)
                            from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                           where n.nspname = 'public'
                             and (p.proname like 'rx\_scan\_%' or p.proname like '\_c418\_%')
                             and has_function_privilege('anon', p.oid, 'EXECUTE')), 'none'),
    'internal_open', coalesce((select string_agg(p.proname, ',' order by p.proname)
                                 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                where n.nspname = 'public'
                                  and p.proname in ('rx_scan_report','rx_scan_read_input')
                                  and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
                              'closed'),
    'bucket_public', coalesce((select public from storage.buckets where id = 'rx-scans'), true),
    'storage_policies', coalesce((select string_agg(policyname, ',' order by policyname)
                                    from pg_policies
                                   where schemaname='storage' and tablename='objects'
                                     and policyname like 'rx_scans%'), 'none'));
$$;
revoke all on function public.c418_qa_report() from public, anon, authenticated;
grant execute on function public.c418_qa_report() to service_role;
