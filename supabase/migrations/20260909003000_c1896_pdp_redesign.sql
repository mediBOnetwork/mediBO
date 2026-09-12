-- CMD #1896 — the product detail page, rebuilt to Om's 08-Sep sketch.
--
-- What the page looked like before this change, and what each part becomes:
--
--   * a thumbnail strip under the hero and a "1 / 5 · Tap to zoom" caption
--     -> ONE hero shot in a bordered card with dots. The counter still exists
--        (the zoom viewer prints it), it simply stops being page furniture.
--   * a lone "Vial" line under the name -> the pack TYPE becomes a pale-green
--     pill ABOVE the name, and the pack sentence becomes one readable line
--     ("Strip of 10 tablets") rendered HERE, not assembled in Dart.
--   * "Printed pack ceiling — not the selling price" printed as a sentence
--     -> the same words, carried as `mrp.info`, shown on an (i) tooltip.
--   * no per-unit rate anywhere -> `sale.per_unit` ("₹4.50 / tablet"),
--     computed from the pack sentence and the PTR, in SQL.
--   * the discount off MRP was never stated -> `discount` ("24% off"), sent
--     only when a real trade rate exists to discount FROM.
--   * Composition printed twice (Overview's row and Product details' row)
--     -> `product_facts` drops the three rows the Overview already carries.
--
-- Everything above is a STRING or a BOOLEAN in the payload. The page prints
-- them; it computes nothing, and it decides nothing except which backend
-- boolean it is looking at.
--
-- Idempotent: create-or-replace / insert-on-conflict throughout.

-- ── 1. Copy ─────────────────────────────────────────────────────────────────
-- These were _pdp_label() defaults living inside a function body, which meant
-- re-wording them was a MIGRATION. They are rows now, so it is an UPDATE.
insert into public.storefront_ui_label (key, value, note) values
  ('pdp_mrp_ceiling_note', 'Printed pack ceiling — not the selling price',
   'CMD #1896 — the (i) tooltip on the struck MRP. No longer a printed line.'),
  ('pdp_sale_price_caption', 'Sale price',
   'CMD #1896 — caption above the big sale number'),
  ('pdp_mrp_missing', 'Not printed on this pack',
   'CMD #1896 — shown where the MRP amount would be when the pack has none'),
  ('pdp_per_unit_fmt', '{price} / {unit}',
   'CMD #1896 — the per-unit line under the sale price'),
  ('pdp_discount_fmt', '{pct}% off',
   'CMD #1896 — the green discount chip beside the sale price'),
  ('pdp_pack_line_fmt', '{container} of {count} {unit}',
   'CMD #1896 — the pack line under the company ("Strip of 10 tablets")'),
  ('pdp_mrp_info_label', 'About MRP',
   'CMD #1896 — accessible name of the (i) control on the MRP line')
on conflict (key) do nothing;

-- ── 2. The pack sentence, parsed once ───────────────────────────────────────
-- MEDICINE.pack_qty is a RENDERED sentence from the source feed
-- ("10 tablets in 1 strip", "1 Injection in 1 vial", "100 ml in 1 bottle").
-- Every consumer that wanted a count or a unit out of it was re-inventing the
-- same regex, so it lives here once and returns the parts already worded.
--
-- A sentence that does not parse yields count=null and the VERBATIM sentence
-- as the pack line: an unparsed pack is printed as the feed wrote it, never
-- dropped and never guessed at.
create or replace function public._pdp_pack_parts(p_product_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  m record;
  v_qty        text;
  v_parts      text[];
  v_count      numeric;
  v_unit       text := '';
  v_unit_one   text := '';
  v_container  text := '';
  v_type       text := '';
  v_line       text := '';
  v_fmt        text := public._pdp_label('pdp_pack_line_fmt', '{container} of {count} {unit}');
begin
  select pack_type, pack_qty, pack_size into m
    from "MEDICINE" where id = p_product_id;
  if not found then
    return jsonb_build_object('has', false, 'has_count', false,
                              'count', null, 'unit', '', 'unit_one', '',
                              'container', '', 'pack_line', '', 'type', '');
  end if;

  v_type := coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''), '');
  v_qty  := coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''), '');

  -- "<count> <unit> in <n> <container>"
  v_parts := regexp_match(v_qty,
    '^\s*([0-9]+(?:\.[0-9]+)?)\s+(.+?)\s+in\s+[0-9]+(?:\.[0-9]+)?\s+(.+?)\s*$');
  if v_parts is not null then
    v_count     := v_parts[1]::numeric;
    v_unit      := btrim(v_parts[2]);
    v_container := btrim(v_parts[3]);
  end if;

  -- The pack TYPE column wins as the container word when it has one: it is the
  -- curated value the catalogue filters on ("Strip", "Vial"), while the tail of
  -- the sentence is whatever the feed wrote.
  if v_type <> '' then v_container := v_type; end if;

  -- The singular the per-unit line needs. Units of measure are already
  -- singular ("100 ml"), so only a genuine plural noun loses its "s".
  v_unit_one := case
    when v_unit = '' then ''
    when lower(v_unit) in ('ml','mg','gm','gms','g','l','ltr','kg','iu','mcg')
      then lower(v_unit)
    when length(v_unit) > 3 and right(lower(v_unit), 1) = 's'
      then lower(left(v_unit, length(v_unit) - 1))
    else lower(v_unit)
  end;

  if v_count is not null and v_unit <> '' and v_container <> '' then
    v_line := replace(replace(replace(v_fmt,
      '{container}', initcap(v_container)),
      '{count}',     public._num_label(v_count)),
      '{unit}',      lower(v_unit));
  else
    -- Verbatim fallbacks, in order of how much they actually say.
    v_line := coalesce(nullif(v_qty, ''),
                       nullif(btrim(coalesce(m.pack_size, '')), ''),
                       v_type, '');
  end if;

  return jsonb_build_object(
    'has',       (v_line <> ''),
    'has_count', (v_count is not null and v_count > 0),
    'count',     v_count,
    'unit',      v_unit,
    'unit_one',  v_unit_one,
    'container', v_container,
    'type',      v_type,
    'pack_line', v_line);
end $function$;

comment on function public._pdp_pack_parts(bigint) is
  'CMD #1896 — MEDICINE.pack_qty ("10 tablets in 1 strip") parsed once into count/unit/container plus a rendered pack line ("Strip of 10 tablets"). An unparsed sentence is returned verbatim, never guessed at.';

-- An internal helper: every caller is SECURITY DEFINER and runs it as the
-- owner, so no storefront role needs its own grant (constraint #79).
revoke all on function public._pdp_pack_parts(bigint) from public;
revoke all on function public._pdp_pack_parts(bigint) from anon;
revoke all on function public._pdp_pack_parts(bigint) from authenticated;
grant execute on function public._pdp_pack_parts(bigint) to service_role;

-- ── 3. The price block ──────────────────────────────────────────────────────
-- Order on the page is now MRP (small, struck, grey) then the sale price
-- (large), which is the order a pharmacy reads a pack in. Three things are
-- new, and all three are computed HERE:
--   * mrp.strike / mrp.info — the ceiling sentence became a tooltip
--   * discount — % off MRP, only when a real trade rate exists
--   * sale.per_unit — the rate per tablet/ml/vial
-- `sticky` stays in the payload although the sticky BAR is gone from the page:
-- an app build older than this deploy still reads it, and a payload key that
-- costs nothing is cheaper than a client that renders a blank bar.
create or replace function public.pdp_price_lines(p_product_id bigint, p_mrp numeric)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_has_mrp boolean := (p_mrp is not null and p_mrp > 0);
  v_pb jsonb;
  v_mrp_cap text := public._pdp_label('mrp_caption', 'MRP');
  v_mrp_val text;
  v_mrp_note text := public._pdp_label('pdp_mrp_ceiling_note', 'Printed pack ceiling — not the selling price');
  v_info_lbl text := public._pdp_label('pdp_mrp_info_label', 'About MRP');
  v_sale_cap text := public._pdp_label('pdp_sale_price_caption', 'Sale price');
  v_sale_val text; v_sale_note text := ''; v_sale_amount boolean := false; v_sale_tone text := 'secondary';
  v_side text := '';
  v_sticky_main text;
  v_ptr numeric;
  v_pct numeric;
  v_disc jsonb := jsonb_build_object('has', false, 'label', '', 'tone', 'success');
  v_unit jsonb := jsonb_build_object('has', false, 'label', '');
  v_parts jsonb;
begin
  v_mrp_val := case when v_has_mrp then public.inr_money(p_mrp)
                    else public._pdp_label('pdp_mrp_missing', 'Not printed on this pack') end;

  -- The SAME block every card reads. It has already decided entitlement, and
  -- it has already formatted the string.
  v_pb := public.storefront_pricing(p_mrp, null::numeric, p_product_id);

  v_sale_val    := coalesce(nullif(v_pb->>'price_display', ''),
                            public._pdp_label('ptr_caption', 'PTR'));
  v_sale_amount := not coalesce((v_pb->>'price_locked')::boolean, true);

  if v_sale_amount then
    v_sale_tone := 'primary';
    v_sale_note := replace(replace(
        public._pdp_label('pdp_sale_net_note', 'Net {net} · {gst}'),
        '{net}', coalesce(v_pb->>'net_display', '')),
        '{gst}', coalesce(v_pb#>>'{gst,pct_display}', ''));
    v_sale_note := btrim(regexp_replace(v_sale_note, '\s·\s*$', ''));

    -- CMD #1896 — the two derived lines. `raw.ptr` exists ONLY on the
    -- entitled branch of _pricing_block, so an unapproved viewer cannot get a
    -- discount percentage or a per-unit rate out of this payload at all.
    v_ptr := nullif(v_pb#>>'{raw,ptr}', '')::numeric;

    if v_ptr is not null and v_ptr > 0 and v_has_mrp and v_ptr < p_mrp then
      v_pct := round((p_mrp - v_ptr) / p_mrp * 100);
      if v_pct > 0 then
        v_disc := jsonb_build_object(
          'has',   true,
          'label', replace(public._pdp_label('pdp_discount_fmt', '{pct}% off'),
                           '{pct}', public._num_label(v_pct)),
          'tone',  'success');
      end if;
    end if;

    if v_ptr is not null and v_ptr > 0 then
      v_parts := public._pdp_pack_parts(p_product_id);
      -- A one-unit pack has no per-unit rate worth printing: it would repeat
      -- the sale price under the sale price.
      if coalesce((v_parts->>'has_count')::boolean, false)
         and (v_parts->>'count')::numeric > 1
         and coalesce(v_parts->>'unit_one', '') <> '' then
        v_unit := jsonb_build_object(
          'has', true,
          'label', replace(replace(
            public._pdp_label('pdp_per_unit_fmt', '{price} / {unit}'),
            '{price}', public.inr_money(round(v_ptr / (v_parts->>'count')::numeric, 2))),
            '{unit}',  v_parts->>'unit_one'));
      end if;
    end if;
  else
    v_sticky_main := public._pdp_label('pdp_sticky_locked', 'Trade price on approval');
  end if;

  if v_has_mrp then
    v_side := btrim(public._pdp_label('pdp_sticky_mrp_prefix', 'MRP') || ' ' || public.inr_money(p_mrp));
  end if;

  return jsonb_build_object(
    'has', true,
    'mrp', jsonb_build_object(
      'caption',    v_mrp_cap,
      'value',      v_mrp_val,
      'has_amount', v_has_mrp,
      -- CMD #1896 — the ceiling sentence stopped being a printed line. It is
      -- the tooltip behind the (i), so has_note is false for every payload and
      -- `info` carries the words.
      'has_note',   false,
      'note',       '',
      'strike',     v_has_mrp,
      'info', jsonb_build_object(
        'has',   v_has_mrp,
        'label', v_info_lbl,
        'text',  case when v_has_mrp then v_mrp_note else '' end),
      'tone',       'secondary'),
    'sale', jsonb_build_object(
      'caption',    v_sale_cap,
      'value',      v_sale_val,
      'has_amount', v_sale_amount,
      'has_note',   v_sale_note <> '',
      'note',       v_sale_note,
      'locked',     not v_sale_amount,
      'prompt',     v_pb -> 'locked_prompt',
      'per_unit',   v_unit,
      'tone',       v_sale_tone),
    'discount', v_disc,
    'sticky', jsonb_build_object(
      'main',         coalesce(v_sticky_main, v_sale_val),
      'main_caption', public._pdp_label('pdp_sticky_sale_caption', 'Sale price'),
      'main_tone',    v_sale_tone,
      'has_side',     v_side <> '',
      'side',         v_side));
end $function$;

comment on function public.pdp_price_lines(bigint, numeric) is
  'CMD #1896 — MRP (struck, with the ceiling sentence as an info tooltip), the sale price (PTR amount or the word PTR), the % off MRP and the per-unit rate. Every string rendered here; the page prints them.';

-- ── 4. Composition is printed once ──────────────────────────────────────────
-- The Overview table already carries Composition, Storage and Habit forming
-- straight off MEDICINE. `product_facts` was carrying the same three columns
-- under different labels, so every PDP printed its composition twice, six rows
-- apart. The fact table keeps what the Overview does NOT have: form, pack,
-- prescription class and cold chain.
create or replace function public.product_facts(p_product_id bigint)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
  with m as (select * from "MEDICINE" where id = p_product_id),
  lbl as (select key, value from storefront_ui_label),
  l as (select (select value from lbl where key = 'pdp_facts_title')      as title,
               (select value from lbl where key = 'pdp_fact_form')        as form,
               (select value from lbl where key = 'pdp_fact_pack')        as pack,
               (select value from lbl where key = 'pdp_fact_rx')          as rx,
               (select value from lbl where key = 'pdp_fact_rx_yes')      as rx_yes,
               (select value from lbl where key = 'pdp_fact_rx_no')       as rx_no,
               (select value from lbl where key = 'pdp_fact_cold_chain')  as cc,
               (select value from lbl where key = 'pdp_fact_cold_chain_yes') as cc_yes),
  rows as (
    select * from (
      values
        ('form',       (select form    from l), (select nullif(btrim(coalesce(pack_type,'')),'')        from m), 2),
        ('pack',       (select pack    from l), (select coalesce(nullif(btrim(coalesce(pack_qty,'')),''),
                                                                 nullif(btrim(coalesce(pack_size,'')),'')) from m), 3),
        ('rx',         (select rx      from l), (select case when upper(btrim(coalesce(rx_required,''))) = 'RX'
                                                              then (select rx_yes from l) else (select rx_no from l) end
                                                   from m), 4),
        ('cold_chain', (select cc      from l), (select case when cold_chain is true then (select cc_yes from l) end from m), 6)
    ) t(k, lab, val, ord)
  )
  select jsonb_build_object(
    'has',   exists (select 1 from rows where val is not null and lab is not null),
    'title', coalesce((select title from l), ''),
    'rows',  coalesce((select jsonb_agg(jsonb_build_object('key', k, 'label', lab, 'value', val) order by ord)
                         from rows where val is not null and lab is not null), '[]'::jsonb));
$function$;

comment on function public.product_facts(bigint) is
  'CMD #1896 — the Product details table. Composition, Storage and Habit forming were REMOVED here because the Overview table above already prints them; a fact appears on the PDP exactly once.';

-- ── 5. The title block ──────────────────────────────────────────────────────
-- The pack type stops being a grey line under the name and becomes the pale
-- pill above it; the pack sentence becomes one readable line. Both are
-- rendered here, so "Strip of 10 tablets" is never assembled in Dart.
--
-- `header` keeps every field it had: an app build older than this deploy reads
-- the same page it always did.
create or replace function public.product_detail(p_product_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v jsonb; v_rx text;
  v_gallery jsonb; v_facts jsonb; v_purchase jsonb; v_companions jsonb;
  v_supply jsonb; v_lines jsonb; v_mrp numeric;
  v_parts jsonb; v_title jsonb; v_chip text;
begin
  v := public._product_detail_core(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  select m.rx_required into v_rx from "MEDICINE" m where m.id = p_product_id;

  begin v_gallery := public.product_gallery(p_product_id);
  exception when others then v_gallery := jsonb_build_object('has', false, 'count', 0, 'images', '[]'::jsonb); end;

  begin v_facts := public.product_facts(p_product_id);
  exception when others then v_facts := jsonb_build_object('has', false, 'title', '', 'rows', '[]'::jsonb); end;

  begin v_purchase := public.purchase_overlay(p_product_id);
  exception when others then v_purchase := jsonb_build_object('has', false); end;

  begin v_companions := public.product_companions(p_product_id, array[p_product_id]);
  exception when others then v_companions := jsonb_build_object('has', false, 'title', '', 'note', '', 'items', '[]'::jsonb); end;

  -- CMD #1826 — supply confidence (a band, never a count) and the two price
  -- lines. Both worded here; the page prints them.
  v_mrp := nullif(v#>>'{pricing,mrp}', '')::numeric;
  begin v_supply := public.pdp_supply_confidence(p_product_id);
  exception when others then v_supply := jsonb_build_object('has', false); end;
  begin v_lines := public.pdp_price_lines(p_product_id, v_mrp);
  exception when others then v_lines := jsonb_build_object('has', false); end;

  -- CMD #1896 — the title block.
  begin v_parts := public._pdp_pack_parts(p_product_id);
  exception when others then v_parts := jsonb_build_object('has', false); end;
  v_chip := coalesce(nullif(btrim(coalesce(v_parts->>'type', '')), ''),
                     nullif(btrim(coalesce(v_parts->>'container', '')), ''), '');
  v_title := jsonb_build_object(
    'has',     true,
    'name',    coalesce(v#>>'{header,name}', ''),
    'company', coalesce(v#>>'{header,company}', ''),
    'form_chip', jsonb_build_object(
      'has',   (v_chip <> ''),
      'label', initcap(v_chip),
      'tone',  'success'),
    'pack_line', jsonb_build_object(
      'has',   coalesce((v_parts->>'has')::boolean, false),
      'label', coalesce(v_parts->>'pack_line', '')));

  -- CHANGE #461/#170: the prescription class, and (for a signed-in pharmacy)
  -- whether their drug licence is on file for it.
  return v
    || jsonb_build_object('header',
         coalesce(v->'header','{}'::jsonb)
         || jsonb_build_object('rx_required',
              (upper(btrim(coalesce(v_rx,''))) = 'RX')))
    || jsonb_build_object(
    'rx',         public.rx_badge(v_rx),
    'rx_licence', case when upper(btrim(coalesce(v_rx,''))) = 'RX'
                            and public.my_customer_id() is not null
                       then public.rx_licence_state(public.my_customer_id())
                       else jsonb_build_object('has', true, 'reason', 'n/a') end)
    -- CMD #791 — depth: the gallery, the fact table, this buyer's own history
    -- with the pack, and what it is bought with.
    || jsonb_build_object(
    'gallery',    v_gallery,
    'facts',      v_facts,
    'purchase',   v_purchase,
    'companions', v_companions)
    -- CMD #1826 — and NEVER a raw sourcing count in the payload: the trust
    -- strip's internal ask/fill tallies stay in the database.
    || jsonb_build_object(
    'trust',       public._pdp_strip_counts(v->'trust'),
    'supply',      v_supply,
    'price_lines', v_lines,
    'title',       v_title);
end $function$;

comment on function public.product_detail(bigint) is
  'CMD #1896 — one RPC for the whole PDP. Adds `title` (pack-type pill, name, company, rendered pack line) on top of the CMD #791/#1826 blocks. Everything visible is a string in this payload.';
