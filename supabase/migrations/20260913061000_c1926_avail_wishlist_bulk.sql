-- CMD #1926 (part 2) — the two customer surfaces that showed a product WITHOUT
-- asking the availability contract at all.
--
--  * `wishlist_get` asked storefront_cta three separate times per row and threw
--    away everything except three scalars, so the saved list could never print
--    the zone line. It now asks `storefront_availability` ONCE and carries the
--    whole block, the line included.
--  * `bulk_match_items` (paste-a-list bulk order) returned matches and
--    candidates with no availability at all: a Raipur buyer could paste twenty
--    lines, see twenty green matches, and find out at the cart which of them
--    no supplier in the zone can send. Every match and every candidate now
--    carries the same block the storefront card reads.
--
-- Idempotent: CREATE OR REPLACE only.

create or replace function public.wishlist_get()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_customer_id uuid;
  v_items       jsonb;
begin
  v_customer_id := my_customer_id();
  if v_customer_id is null then
    return jsonb_build_object(
      'ok',          false,
      'error',       'not_customer',
      'items',       '[]'::jsonb,
      'title',       'My Wishlist',
      'count_label', '',
      'empty_title', 'Your wishlist is empty',
      'empty_body',  'Save products here to order them quickly later.'
    );
  end if;

  select coalesce(jsonb_agg(row order by row.saved_at desc), '[]'::jsonb)
  into v_items
  from (
    select
      m.id::text                                   as product_id,
      coalesce(m.product_name, '')                 as name,
      coalesce(m.marketer, '')                     as company,
      coalesce(m.pack_size, '')                    as pack_label,
      coalesce(
        (public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
          null::numeric, m.id))->>'price_display', '')            as price_display,
      -- CMD #1926 — ONE call to the shared helper, read four ways. It used to
      -- be three separate calls whose answers were only guaranteed to agree
      -- because they happened to be written identically.
      coalesce((av.a->'is_available')::boolean, false)            as in_stock,
      coalesce((av.a->'can_add')::boolean, false)                 as can_add,
      coalesce(av.a->>'cta_label', 'Add to cart')                 as cta_label,
      coalesce(av.a->>'availability_label', '')                   as availability_label,
      coalesce(av.a->>'availability_tone', 'neutral')             as availability_tone,
      av.a                                                        as availability,
      coalesce(m.image_url_1, '')                                 as image_url,
      wi.created_at                                               as saved_at
    from wishlist_items wi
    join "MEDICINE" m on m.id = wi.product_id
    cross join lateral (select public.storefront_availability(m.id, m.supplier_count) as a) av
    where wi.account_id = v_customer_id
  ) row;

  return jsonb_build_object(
    'ok',           true,
    'items',        v_items,
    'title',        'My Wishlist',
    'count_label',  case
                      when jsonb_array_length(v_items) = 0 then ''
                      when jsonb_array_length(v_items) = 1 then '1 product'
                      else jsonb_array_length(v_items)::text || ' products'
                    end,
    'empty_title',  'Your wishlist is empty',
    'empty_body',   'Save products here to order them quickly later.',
    'remove_toast', 'Removed from wishlist',
    'add_toast',    'Added to wishlist',
    'cart_toast',   'Added to cart'
  );
end;
$function$;

create or replace function public.bulk_match_items(p_items jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
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
        select m.id, m.product_name, m.marketer, m.pack_type, m.pack_size, m.mrp,
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
