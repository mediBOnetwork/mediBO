-- CMD #2115 — Bulk Upload review rows v2: one row shape, one pack sentence,
-- and a quantity picker whose every word is a payload.
--
-- #2113 gave the phone review list a photo and backend lines, but it printed
-- TWO shapes: five lines for the selected match (two grey pack badges + a
-- company line) and four for an alternative. Om's read of it was that the two
-- shapes fight each other and that neither the company nor the raw pack string
-- earns its line on a 360px phone. v2 prints ONE shape everywhere — name, the
-- quantity sentence ("17 strip"), the price block, the state badge — so the
-- selected product and the four alternatives under it are the same object seen
-- twice.
--
-- What moves into the backend here:
--   bulk.qty_line          — the "17 strip" sentence, a ui_copy template. The
--                            row re-renders it locally when the picker changes
--                            the number; the WORDING and the order of the two
--                            parts stay an UPDATE, never a deploy.
--   qty_unit               — the unit word for a product ("strip"), verbatim
--                            from MEDICINE.pack_type, lowercased for a
--                            sentence. Dart never shortens a pack again
--                            (_packShort is what produced "10 tabl…").
--   bulk_qty_picker()      — the whole mini popup: title, every option's
--                            number AND its printed label, which option is
--                            selected, and the index to scroll to. The screen
--                            renders the list and sends back a number.
--
-- Zone/date: this file adds no list, count or report. The one state the row
-- shows that IS zone-scoped — the Available / Unavailable badge — already
-- arrives from bulk_avail_badge(storefront_availability(...)), whose
-- storefront_effective_count() reads the viewer's zone (CMD #2023). The picker
-- formats a number and has no zone dimension to read.

-- ── copy ─────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  -- "{qty} {unit}" → "17 strip". Both placeholders, so a language that puts
  -- the unit first is an UPDATE.
  ('bulk.qty_line',           '"{qty} {unit}"'::jsonb),
  ('bulk.qty_unit_fallback',  '"unit"'::jsonb),
  ('bulk.qty_picker_title',   '"Quantity"'::jsonb),
  ('bulk.qty_picker_min',     '1'::jsonb),
  ('bulk.qty_picker_max',     '50'::jsonb),
  ('bulk.open_product_hint',  '"Open product"'::jsonb)
on conflict (key) do nothing;

-- ── the unit word ────────────────────────────────────────────────────────────
-- MEDICINE.pack_type is the printed pack word ("Strip", "Bottle", "Tube").
-- A sentence wants it lowercase; nothing else is done to it — no expansion,
-- no shortening, no pluralising in code.
create or replace function public.bulk_qty_unit(p_pack_type text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select lower(coalesce(
    nullif(btrim(coalesce(p_pack_type, '')), ''),
    public.uic('bulk.qty_unit_fallback', 'unit')));
$function$;

-- ── the quantity sentence ────────────────────────────────────────────────────
-- The SAME template the row renders with, so an option label inside the picker
-- and the line the row prints after the pick can never disagree.
create or replace function public.bulk_qty_line(p_qty int, p_pack_type text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select replace(
           replace(public.uic('bulk.qty_line', '{qty} {unit}'),
                   '{qty}', coalesce(p_qty, 0)::text),
           '{unit}', public.bulk_qty_unit(p_pack_type));
$function$;

-- ── the mini popup ───────────────────────────────────────────────────────────
-- Every word and every number the popup shows. `selected_index` is the row to
-- centre and tick; it is clamped into range here so the screen never has to
-- decide what to do with a quantity outside the list.
create or replace function public.bulk_qty_picker(
  p_pack_type text default null, p_current int default null)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with bounds as (
    select greatest(1, coalesce((public.uic('bulk.qty_picker_min', '1'))::int, 1)) as lo,
           greatest(1, coalesce((public.uic('bulk.qty_picker_max', '50'))::int, 50)) as hi
  ),
  opts as (
    select g.v,
           public.bulk_qty_line(g.v, p_pack_type) as label
    from bounds b, generate_series(b.lo, b.hi) as g(v)
  )
  select jsonb_build_object(
    'title',  public.uic('bulk.qty_picker_title', 'Quantity'),
    'unit',   public.bulk_qty_unit(p_pack_type),
    'min',    (select lo from bounds),
    'max',    (select hi from bounds),
    'selected', least(greatest(coalesce(p_current, (select lo from bounds)),
                               (select lo from bounds)),
                      (select hi from bounds)),
    'selected_index', least(greatest(coalesce(p_current, (select lo from bounds)),
                                     (select lo from bounds)),
                            (select hi from bounds)) - (select lo from bounds),
    'options', (select jsonb_agg(jsonb_build_object('value', v, 'label', label)
                                 order by v) from opts));
$function$;

-- Grants. The bulk upload screen is reachable logged-out (bulk_match_items has
-- carried anon since CHANGE #678), so a signed-out visitor pasting a list must
-- be able to open the quantity popup on their own rows. These three functions
-- format a number and read ui_copy — they touch no customer row, no price
-- entitlement and no zone — so anon is the correct audience and is granted
-- here explicitly rather than inherited.
revoke all on function public.bulk_qty_unit(text) from public;
revoke all on function public.bulk_qty_line(int, text) from public;
revoke all on function public.bulk_qty_picker(text, int) from public;
grant execute on function public.bulk_qty_unit(text)        to anon, authenticated, service_role;
grant execute on function public.bulk_qty_line(int, text)   to anon, authenticated, service_role;
grant execute on function public.bulk_qty_picker(text, int) to anon, authenticated, service_role;

-- ── the matcher, re-issued with the unit word ────────────────────────────────
-- Identical to CMD #2113's body except for two added keys: `qty_unit` on every
-- candidate and `qty_line` on the item. Re-issued whole (rather than patched in
-- place) because CREATE OR REPLACE is the only idempotent way to change a
-- function body, and the replay must land the same result on a database that
-- already has #2113's version and on one that does not.
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
               -- CMD #2115 — the unit word the row's quantity sentence uses.
               public.bulk_qty_unit(pack_type) as qty_unit,
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

-- ── the picker's own states ──────────────────────────────────────────────────
-- A popup that loads has two more things to say than its title, and neither may
-- be typed in Dart.
insert into public.ui_copy(key, value) values
  ('bulk.qty_picker_error', '"Could not load quantities"'::jsonb),
  ('bulk.qty_picker_retry', '"Retry"'::jsonb)
on conflict (key) do nothing;
