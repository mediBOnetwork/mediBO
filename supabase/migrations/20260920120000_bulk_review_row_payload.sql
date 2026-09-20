-- CMD #2113 — Bulk Upload review rows carry everything the phone row prints.
--
-- The mobile review list used to render a product from raw catalogue columns:
-- the pack was shortened in Dart (_packShort), the MRP came back as TEXT and
-- silently parsed to 0.0, and availability was an "AV"/"NA" two-letter chip
-- typed in Flutter. This migration moves all four decisions into the payload:
--
--   pack_type_label / pack_qty_label  — the two grey badges, verbatim columns
--   pack_line                         — the SAME two, joined for a one-line row
--   pricing (with card_price)         — storefront_pricing(), so the bulk list
--                                       prints the identical block the card and
--                                       the PDP print, PTR entitlement included
--   avail_badge                       — {label,bg,fg}, the green/red badge
--
-- Nothing computes a price here: _pricing_block() decides has_ptr and sends the
-- locked word "PTR" to an unapproved viewer, so no trade number reaches a
-- payload it may not appear in.

-- ── copy ─────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('bulk.avail_badge_available',    '"Available"'::jsonb),
  ('bulk.avail_badge_unavailable',  '"Unavailable"'::jsonb),
  ('bulk.avail_badge_available_bg', '"#D1FAE5"'::jsonb),
  ('bulk.avail_badge_available_fg', '"#065F46"'::jsonb),
  ('bulk.avail_badge_unavailable_bg','"#FEE2E2"'::jsonb),
  ('bulk.avail_badge_unavailable_fg','"#991B1B"'::jsonb),
  ('bulk.pack_line_separator',      '", "'::jsonb)
on conflict (key) do nothing;

-- ── the one-line pack sentence ("Strip, 10 tablet in 1 strip") ───────────────
-- Same two strings as the badges, joined by a separator that lives in ui_copy.
-- An alternative row has one line for the pack; the selected row has two
-- badges. Both read the same columns so they can never disagree.
create or replace function public.bulk_pack_line(
  p_pack_type text, p_pack_qty text, p_pack_size text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(
    nullif(array_to_string(
      array_remove(array[
        nullif(btrim(coalesce(p_pack_type, '')), ''),
        coalesce(nullif(btrim(coalesce(p_pack_qty, '')), ''),
                 nullif(btrim(coalesce(p_pack_size, '')), ''))
      ], null),
      public.uic('bulk.pack_line_separator', ', ')), ''),
    '');
$function$;

-- ── the availability badge ───────────────────────────────────────────────────
-- storefront_cta() answers "can this be added"; the review list prints a state
-- badge instead of a button, so the wording and both colours are their own copy
-- keys. Absence of an answer is absence of a badge (null), never a green one.
create or replace function public.bulk_avail_badge(p_availability jsonb)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when p_availability is null or p_availability->>'is_available' is null then null
    when (p_availability->>'is_available')::boolean then jsonb_build_object(
      'label',     public.uic('bulk.avail_badge_available', 'Available'),
      'available', true,
      'bg',        public.uic('bulk.avail_badge_available_bg', '#D1FAE5'),
      'fg',        public.uic('bulk.avail_badge_available_fg', '#065F46'))
    else jsonb_build_object(
      'label',     public.uic('bulk.avail_badge_unavailable', 'Unavailable'),
      'available', false,
      'bg',        public.uic('bulk.avail_badge_unavailable_bg', '#FEE2E2'),
      'fg',        public.uic('bulk.avail_badge_unavailable_fg', '#991B1B'))
  end;
$function$;

revoke all on function public.bulk_pack_line(text, text, text) from public, anon;
revoke all on function public.bulk_avail_badge(jsonb) from public, anon;
grant execute on function public.bulk_pack_line(text, text, text) to authenticated, service_role;
grant execute on function public.bulk_avail_badge(jsonb) to authenticated, service_role;

-- ── the matcher ──────────────────────────────────────────────────────────────
create or replace function public.bulk_match_items(p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
      'score',      round(coalesce(v_score,0)::numeric,3),
      'match',      v_match,
      'candidates', v_cands
    ));
  end loop;

  return jsonb_build_object('status','ok','items', v_out);
end;
$function$;

-- bulk_match_items keeps the grants it already has (anon included): the bulk
-- upload screen is reachable logged-out, and the PTR gate is inside
-- _pricing_block(), which sends an unapproved viewer the locked word rather
-- than a number. CREATE OR REPLACE preserves the ACL, so nothing is said here.
