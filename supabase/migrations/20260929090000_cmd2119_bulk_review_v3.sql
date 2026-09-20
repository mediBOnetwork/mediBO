-- CMD #2119 — Bulk Upload review v3: the price line is the SALE price alone,
-- the quantity picker reaches 999, an alternative's second line is its
-- COMPOSITION, and the file the buyer uploaded opens inside the app.
--
-- What moves (or stays) in the backend here:
--   bulk.qty_picker_max        — 50 → 999. The picker's ceiling was never a
--                                Dart constant, so this is an UPDATE and the
--                                popup reaches 999 with no deploy.
--   bulk_composition_line()    — MEDICINE.salt_composition, verbatim, with the
--                                backend's own word when a row has none. Dart
--                                prints it and joins nothing.
--   bulk.qty_pack_line         — the selected row's "17 strip · Strip, 10 tabs"
--                                sentence as ONE template: the separator and
--                                the order of the parts are copy, not code.
--   bulk.file_viewer_*         — every word of the in-app file viewer.
--   bulk_match_items()         — each candidate now carries `composition`.
--
-- The price block itself is untouched: the row keeps printing
-- storefront_pricing()'s card_price (sale_label + price_display, the amount
-- for an approved viewer and the locked word for everyone else). v3 only
-- stops PRINTING the MRP half beside it.
--
-- Zone/date: this file adds no list, count or report. The zone-scoped thing a
-- review row shows — the Available / Unavailable badge — already comes from
-- bulk_avail_badge(storefront_availability(...)), whose
-- storefront_effective_count() reads the viewer's zone (CMD #2023).
-- Idempotent: every statement is create-or-replace / upsert.

-- ── copy ─────────────────────────────────────────────────────────────────────
-- The ceiling moves: 50 → 999. This one is forced, because the whole point of
-- the item is that the existing row changes value.
insert into public.ui_copy(key, value) values ('bulk.qty_picker_max', '999'::jsonb)
on conflict (key) do update set value = excluded.value;

insert into public.ui_copy(key, value) values
  -- The selected row keeps quantity AND pack; both parts and the separator
  -- live here, so reordering them is an UPDATE.
  ('bulk.qty_pack_line',         '"{qty} {unit} \u00b7 {pack}"'::jsonb),
  -- A catalogue row with no salt_composition prints this rather than a blank
  -- line that reads as a broken row.
  ('bulk.composition_unknown',   '"Composition not listed"'::jsonb),
  -- The in-app file viewer (CMD #2119 item 3).
  ('bulk.file_viewer_title',     '"Uploaded order"'::jsonb),
  ('bulk.file_viewer_close',     '"Close"'::jsonb),
  ('bulk.file_viewer_open_hint', '"View uploaded file"'::jsonb),
  ('bulk.file_viewer_no_preview','"This file type has no preview here. The medicines it listed are in the review below."'::jsonb),
  ('bulk.file_viewer_error',     '"Could not open this file."'::jsonb)
on conflict (key) do nothing;

-- ── the composition line ─────────────────────────────────────────────────────
-- MEDICINE.salt_composition verbatim ("Acebrophylline (100mg) + Acetylcysteine
-- (600mg)"). Never expanded, never abbreviated, never re-cased — the OCR/naming
-- rule applies to catalogue text too. An empty one gets the backend's word.
create or replace function public.bulk_composition_line(p_salt text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    nullif(btrim(coalesce(p_salt, '')), ''),
    public.uic('bulk.composition_unknown', 'Composition not listed'));
$function$;

grant execute on function public.bulk_composition_line(text) to anon, authenticated, service_role;

-- ── the selected row's quantity + pack sentence ──────────────────────────────
-- "17 strip · 10 tablets". The unit word already says "strip", so the pack
-- half is the catalogue's pack QUANTITY (or its pack size when there is none)
-- and never the pack type again — that repeated the unit. With neither, the
-- sentence is the plain quantity line.
create or replace function public.bulk_qty_pack_line(
  p_qty integer, p_pack_type text, p_pack_qty text, p_pack_size text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  with detail as (
    select coalesce(nullif(btrim(coalesce(p_pack_qty, '')), ''),
                    nullif(btrim(coalesce(p_pack_size, '')), '')) as d
  )
  select case
    when (select d from detail) is null
      then public.bulk_qty_line(p_qty, p_pack_type)
    else replace(
           replace(
             replace(public.uic('bulk.qty_pack_line', '{qty} {unit} · {pack}'),
                     '{qty}',  coalesce(p_qty, 0)::text),
             '{unit}', public.bulk_qty_unit(p_pack_type)),
           '{pack}', (select d from detail))
  end;
$function$;

grant execute on function public.bulk_qty_pack_line(integer, text, text, text) to anon, authenticated, service_role;

-- ── bulk_match_items(): every candidate carries its composition ──────────────
CREATE OR REPLACE FUNCTION public.bulk_match_items(p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_out   jsonb := '[]'::jsonb;
  v_item  jsonb;
  v_raw   text;
  v_qty   int;
  v_clean text;
  v_brand text;
  v_tok   text;
  v_match jsonb;
  v_cands jsonb;
  v_score real;
  v_status text;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('status','error','error','bad_input','items','[]'::jsonb);
  end if;

  perform set_config('pg_trgm.word_similarity_threshold','0.4', true);

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_raw := coalesce(v_item->>'name', v_item->>'text', v_item->>'product_name', '');
    begin
      v_qty := nullif(regexp_replace(coalesce(v_item->>'qty',''), '[^0-9]', '', 'g'), '')::int;
    exception when others then v_qty := null; end;

    v_clean := btrim(regexp_replace(regexp_replace(v_raw, '[.\-–—:_/\\()]+', ' ', 'g'), '\s+', ' ', 'g'));

    -- brand = first meaningful token (skip dosage-form / unit words); this is what we trigram-filter on
    v_brand := null;
    foreach v_tok in array coalesce(regexp_split_to_array(v_clean, '\s+'), array[]::text[]) loop
      if v_tok ~ '[A-Za-z]' and length(v_tok) >= 3
         and lower(v_tok) not in ('tab','tablet','tablets','cap','capsule','capsules','inj','injection',
              'syp','syr','syrup','oint','ointment','cream','gel','drop','drops','susp','suspension',
              'sachet','powder','lotion','soln','solution','tube','kit','sol','spray','respules','rotacap','inhaler') then
        v_brand := v_tok; exit;
      end if;
    end loop;
    if v_brand is null then v_brand := split_part(v_clean,' ',1); end if;

    v_match := null; v_cands := '[]'::jsonb; v_score := 0;

    if length(v_brand) >= 3 then
      with cand as (
        -- tight pool: products whose name is word-similar to the BRAND (not the form word)
        select m.id, m.product_name, m.marketer, m.pack_type, m.pack_size, m.pack_qty, m.mrp,
               m.salt_composition,
               m.buyable, m.therapeutic_class, m.image_url_1, m.gst_percent, m.sales_count,
               m.supplier_count,
               split_part(m.product_name,' ',1) as prod_first
        from "MEDICINE" m
        where v_brand <% m.product_name
        limit 600
      ),
      scored as (
        select c.*,
               (case
                  when lower(c.product_name) = lower(v_clean) then 1.0
                  when c.product_name ilike v_clean || '%' then 0.95
                  when c.product_name ilike '%' || v_clean || '%' then 0.90
                  else word_similarity(v_clean, c.product_name)
                end)::real as base_score,
               (levenshtein(lower(v_brand), lower(c.prod_first)) <= 2
                 or dmetaphone(v_brand) = dmetaphone(c.prod_first)) as brand_match
        from cand c
      ),
      ranked as (
        select id, product_name,
               nullif(btrim(marketer),'')          as company,
               nullif(btrim(pack_type),'')         as pack_type,
               nullif(btrim(pack_size),'')         as pack_size,
               mrp, buyable,
               nullif(btrim(therapeutic_class),'') as category,
               nullif(btrim(image_url_1),'')       as image_url,
               gst_percent,
               round(least(1.0, base_score + case when brand_match then 0.15 else 0 end)::numeric,3) as score,
               -- CMD #1926 — the bulk list answers to the SAME availability
               -- contract as the storefront card. Without this a pasted list
               -- of twenty lines looked entirely addable and the cart then
               -- refused whichever of them the buyer's zone cannot send.
               public.storefront_availability(id, supplier_count) as availability,
               -- CMD #2113 — the four things the phone row prints, decided here.
               public.bulk_avail_badge(
                 public.storefront_availability(id, supplier_count)) as avail_badge,
               public.sf_pack_type_label(pack_type) as pack_type_label,
               public.sf_pack_qty_label(pack_qty)   as pack_qty_label,
               public.bulk_pack_line(pack_type, pack_qty, pack_size) as pack_line,
               -- CMD #2115 — the unit word the row's quantity sentence uses.
               public.bulk_qty_unit(pack_type) as qty_unit,
               -- CMD #2119 — line 2 of an alternative is the COMPOSITION,
               -- verbatim from the catalogue (never re-worded in Dart).
               public.bulk_composition_line(salt_composition) as composition,
               public.storefront_pricing(
                 nullif(regexp_replace(coalesce(mrp::text,''),'[^0-9.]','','g'),'')::numeric,
                 null::numeric, id) as pricing,
               brand_match, sales_count, length(product_name) as name_len
        from scored
        order by least(1.0, base_score + case when brand_match then 0.15 else 0 end) desc,
                 brand_match desc,
                 buyable desc,
                 sales_count desc nulls last,
                 length(product_name) asc
        limit 8
      )
      select
        (select to_jsonb(r) - 'brand_match' - 'sales_count' - 'name_len' from ranked r limit 1),
        coalesce((select jsonb_agg(to_jsonb(r) - 'brand_match' - 'sales_count' - 'name_len') from ranked r), '[]'::jsonb),
        (select r.score from ranked r limit 1)
      into v_match, v_cands, v_score;
    end if;

    v_status := case
                  when v_match is null or coalesce(v_score,0) < 0.45 then 'none'
                  when coalesce(v_score,0) >= 0.72 then 'matched'
                  else 'partial'
                end;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'input',      v_raw,
      'qty',        v_qty,
      'clean',      v_clean,
      'brand',      v_brand,
      'status',     v_status,
      -- CMD #2115 — the row's own quantity sentence, rendered from the
      -- match's pack type. Re-rendered locally from bulk.qty_line when the
      -- picker changes the number; the template stays backend copy.
      'qty_line',   public.bulk_qty_line(coalesce(v_qty, 1), v_match->>'pack_type'),
      'score',      round(coalesce(v_score,0)::numeric,3),
      'match',      v_match,
      'candidates', v_cands
    ));
  end loop;

  return jsonb_build_object('status','ok','items', v_out);
end;
$function$;

grant execute on function public.bulk_match_items(jsonb) to anon, authenticated, service_role;
