-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #2023 — ONE zone-availability truth.
--
-- Before this, three answers to the same question shipped on the same card:
--   • public.medicine_zone_standby()  — live, read straight off the "MEDICINE"
--     zone arrays. The card LABEL and the PDP used it.
--   • public.catalogue_zone_avail     — a snapshot rebuilt by catalogue_cache_tick,
--     last swapped on 2 Sep. _search_cards / _cat_page_ids used it, and
--     _search_cards let it OVERWRITE the verdict with "Not in your zone".
--   • MEDICINE.buyable                — a catalogue flag with no zone in it.
-- Facemoist (586171) therefore read "Available" and "Not in your zone" on one
-- card. This migration leaves exactly one definition, public.zone_available(),
-- and makes the fast store behind it maintain itself from the same writes.
-- Idempotent: every object is CREATE OR REPLACE / IF NOT EXISTS.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. The fast store, read as a set ────────────────────────────────────────
-- A plain SQL SRF so the planner inlines it: a list page keeps the same
-- (zone_id, product_id) index-driven join it had, with no direct table read
-- left anywhere in a card / add / order path. A null zone selects nothing —
-- rule 4, enforced at the source rather than at each caller.
create or replace function public.zone_available_products(p_zone_id smallint)
returns table(product_id bigint)
language sql
stable
security definer
set search_path to 'public'
as $$
  select za.product_id
    from public.catalogue_zone_avail za
   where p_zone_id is not null
     and za.zone_id = p_zone_id;
$$;

-- ── 2. THE definition of zone availability ──────────────────────────────────
-- Every surface asks this and nothing else: storefront / search / list cards,
-- PDP, Other packs, cart add, cart validation, the order guard and
-- notify-when-available. A viewer with no zone is unavailable for everything;
-- null NEVER means all-available.
create or replace function public.zone_available(p_product_id bigint, p_zone_id smallint)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select p_product_id is not null
     and p_zone_id is not null
     and exists (select 1
                   from public.catalogue_zone_avail za
                  where za.zone_id = p_zone_id
                    and za.product_id = p_product_id);
$$;

comment on function public.zone_available(bigint, smallint) is
  'CMD #2023 — the ONLY definition of zone availability. Reads the self-maintaining catalogue_zone_avail store. Null zone is false.';

revoke all on function public.zone_available(bigint, smallint) from public;
grant execute on function public.zone_available(bigint, smallint) to anon, authenticated, service_role;
revoke all on function public.zone_available_products(smallint) from public;
grant execute on function public.zone_available_products(smallint) to anon, authenticated, service_role;

-- The old alias keeps working, as one more caller of the one function.
create or replace function public.medicine_zone_available(p_product_id bigint, p_zone_id smallint)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.zone_available(p_product_id, p_zone_id);
$$;

-- ── 3. The store maintains itself ───────────────────────────────────────────
-- Every write that can change a pack's zone standby — a supplier marking
-- av/oos/nostock (medicine_zone_set_state), a stock-note answer, the zone
-- master-list rebuild, an admin edit, a bulk sync — lands on the "MEDICINE"
-- z_<code>_sup / _av / _oos / _nostock arrays. So one AFTER trigger on those
-- columns keeps the store exact in the same statement. No cron, no manual sync.
create or replace function public._zone_avail_sync(p_product_id bigint)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; v_changed int := 0; v_ok boolean;
begin
  if p_product_id is null then return 0; end if;
  for r in select z.id, z.code from public.zones z
            where z.is_active and not coalesce(z.is_synthetic, false)
            order by z.id loop
    if not exists (select 1 from information_schema.columns c
                    where c.table_schema = 'public' and c.table_name = 'MEDICINE'
                      and c.column_name = 'z_'||r.code||'_sup') then
      continue;
    end if;
    v_ok := public.medicine_zone_standby(p_product_id, r.id) > 0;
    if v_ok then
      insert into public.catalogue_zone_avail(zone_id, product_id)
        values (r.id, p_product_id)
        on conflict do nothing;
    else
      delete from public.catalogue_zone_avail
       where zone_id = r.id and product_id = p_product_id;
    end if;
    v_changed := v_changed + 1;
  end loop;
  return v_changed;
end $$;

create or replace function public._zone_avail_sync_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.catalogue_zone_avail where product_id = OLD.id;
    return OLD;
  end if;
  perform public._zone_avail_sync(NEW.id);
  return NEW;
end $$;

-- Backfill / self-heal for a whole zone, set-based. Run once here; after that
-- the trigger is the only writer, so a re-run must report zero drift.
create or replace function public.zone_avail_backfill(p_zone_id smallint default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare r record; v_ins bigint; v_del bigint; v_tot bigint := 0;
        v_res jsonb := '[]'::jsonb;
begin
  for r in select z.id, z.code from public.zones z
            where z.is_active and not coalesce(z.is_synthetic, false)
              and (p_zone_id is null or z.id = p_zone_id)
            order by z.id loop
    if not exists (select 1 from information_schema.columns c
                    where c.table_schema = 'public' and c.table_name = 'MEDICINE'
                      and c.column_name = 'z_'||r.code||'_sup') then
      continue;
    end if;
    execute format($q$
      with want as (
        select m.id
          from public."MEDICINE" m
         where cardinality(public.medicine_zone_effective(m.%1$I, m.%2$I, m.%3$I, m.%4$I)) > 0
      ),
      del as (
        delete from public.catalogue_zone_avail za
         where za.zone_id = %5$L::smallint
           and not exists (select 1 from want w where w.id = za.product_id)
        returning 1
      ),
      ins as (
        insert into public.catalogue_zone_avail(zone_id, product_id)
        select %5$L::smallint, w.id from want w
        on conflict do nothing
        returning 1
      )
      select (select count(*) from ins), (select count(*) from del),
             (select count(*) from want)
    $q$, 'z_'||r.code||'_sup', 'z_'||r.code||'_av',
         'z_'||r.code||'_oos', 'z_'||r.code||'_nostock', r.id)
      into v_ins, v_del, v_tot;
    v_res := v_res || jsonb_build_object('zone_id', r.id, 'zone', r.code,
                                         'inserted', v_ins, 'deleted', v_del,
                                         'available', v_tot);
  end loop;
  return jsonb_build_object('ok', true, 'zones', v_res);
end $$;

-- ── 4. The viewer's verdict — the one funnel every card payload goes through ─
-- storefront_effective_count() is what storefront_cta() is built on, and
-- storefront_cta() is what every card, the PDP, Other packs and the cart
-- render. It now asks public.zone_available() and nothing else.
--
-- Rule 4: an approved buyer whose profile carries no zone is UNAVAILABLE for
-- everything — a null zone is not a wildcard. An anonymous or not-yet-approved
-- visitor is not a buyer at all: they cannot reach a cart, so the public shop
-- window keeps browsing (gated:false already tells the app the verdict is not
-- a real one).
create or replace function public.storefront_effective_count(p_product_id bigint, p_global integer)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if public.viewer_is_approved_customer() then
    -- CMD #2023 — one truth. zone_available() is false for a null zone, so a
    -- buyer with no zone can no longer see the whole catalogue as addable.
    return case when public.zone_available(p_product_id, public._viewer_zone_or_null())
                then 1 else 0 end;
  end if;
  -- CHANGE #678 — anonymous / unapproved visitors browse the shop window.
  return greatest(coalesce(p_global, 0), 1);
end $$;

-- ── 5. The button alone carries the state ───────────────────────────────────
-- CMD #2023 spec 3: the "Available · <zone>" / "Not available · <zone>" text
-- line is gone from every payload, and the unavailable button is grey and
-- non-tappable — it carries no note, so there is nothing to tap for.
create or replace function public.storefront_cta(p_supplier_count integer, p_resolved boolean default true)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select (case
    when not coalesce(p_resolved, true) then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'unresolved', true,
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    when coalesce(p_supplier_count, 0) >= 1 then
      jsonb_build_object('is_available', true, 'can_add', true,
        'cta_label','Add to cart','gated', public.viewer_is_approved_customer(),
        'cta_short', coalesce((select value from public.storefront_ui_label
                                 where key='card_add_label'), 'ADD'),
        'colors', jsonb_build_object('bg','#1B7A43','fg','#FFFFFF'))

    else
      jsonb_build_object('is_available', false, 'can_add', false,
        'cta_label', public.uic('storefront.unavailable_cta','Unavailable'),
        'gated', public.viewer_is_approved_customer(),
        'blocked_by', 'not_available_in_zone',
        'cta_short', public.uic('storefront.unavailable_cta','Unavailable'),
        'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF'))
  end);
$$;

-- The availability text line has no reader left.
drop function if exists public.storefront_availability_line(integer, boolean);
CREATE OR REPLACE FUNCTION public._cat_page_ids(p_where text, p_sort text, p_cursor jsonb, p_zone smallint, p_grp smallint, p_limit integer)
 RETURNS bigint[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_join text := '';
  v_extra text := '';
  v_keyset text := '';
  v_order text;
  v_sql text;
  v_ids bigint[];
begin
  if coalesce(p_limit,0) < 1 then return '{}'::bigint[]; end if;

  if p_zone is not null and p_grp = 0 then
    v_join := format('join public.zone_available_products(%L::smallint) za '
                     || 'on za.product_id = m.id', p_zone);
  elsif p_zone is not null then
    -- The anti-join probes catalogue_zone_avail's (zone_id, product_id)
    -- primary key once per candidate row, so group 1 costs the same walk as
    -- group 0 plus an index lookup — not a sort of the scope.
    v_extra := format(' and not public.zone_available(m.id, %L::smallint)', p_zone);
  end if;

  if p_sort = 'newest' then
    v_order := 'order by m.id desc';
    if p_cursor ? 'i' then v_keyset := format(' and m.id < %L::bigint', p_cursor->>'i'); end if;
  else
    v_order := 'order by m.product_name, m.id';
    if p_cursor ? 'i' then
      v_keyset := format(' and (m.product_name, m.id) > (%L, %L::bigint)',
                         coalesce(p_cursor->>'n',''), p_cursor->>'i');
    end if;
  end if;

  v_sql := format(
    'select array_agg(t.id order by t.ord) from ('
    || 'select s.id, row_number() over () as ord from ('
    || 'select m.id, m.product_name from public."MEDICINE" m %s where %s%s%s %s limit %s'
    || ') s) t', v_join, p_where, v_extra, v_keyset, v_order, p_limit);
  execute v_sql into v_ids;
  return coalesce(v_ids, '{}'::bigint[]);
end $function$;

CREATE OR REPLACE FUNCTION public.search_medicines_priority(search_term text, category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT 20, p_zone boolean DEFAULT true)
 RETURNS TABLE(id bigint, product_name text, salt_composition text, marketer text, therapeutic_class text, image_url_1 text, pack_qty text, pack_size text, pack_type text, mrp text, gst_percent integer, rx_required text, sales_count integer, has_scheme boolean, has_image boolean, buyable boolean, supplier_count integer, supplier_label text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_clean text; v_all boolean; v_brand text; v_pref text; v_tok text;
  v_toks text[]; v_keep text[]; v_compact text; v_cl int; v_brand_dm text;
  v_co text; v_co_norm text; v_co_tier int := 0;
  v_is_admin boolean;   -- CMD #1903b: get_my_role() is VOLATILE, read it ONCE
  v_zone smallint := public._viewer_zone_or_null();   -- CHANGE #678
  -- CHANGE #790 — the #747 zone switch. CMD #1894 removed the Hinglish
  -- mapping that used to sit beside it; v_syn_kind/v_syn_target stay declared
  -- and stay NULL, which is what makes the two syn_* branches below empty.
  v_zfilter smallint := public._cat_zone(coalesce(p_zone, true));
  v_syn_kind text := null; v_syn_target text := null;
  c_forms text[] := array['tab','tablet','tablets','cap','capsule','capsules','inj','injection',
      'syp','syr','syrup','oint','ointment','cream','gel','drop','drops','susp','suspension',
      'sachet','powder','lotion','soln','solution','tube','kit','sol','spray','respules',
      'rotacap','inhaler','er','sr','xr','md','mg','ml','gm','gms','mcg','mgs','the','and','for'];
  c_brandskip text[] := array['tab','tablet','tablets','cap','capsule','capsules','inj','injection',
      'syp','syr','syrup','oint','ointment','cream','gel','drop','drops','susp','suspension',
      'sachet','powder','lotion','soln','solution','tube','kit','sol','spray','respules',
      'rotacap','inhaler','the','and','for','type','types'];
begin
  v_is_admin := public.get_my_role() in ('admin','super_admin');
  category_filter := coalesce(nullif(btrim(category_filter),''), 'All');
  v_all := (category_filter = 'All');
  v_clean := public._norm_name(search_term);

  -- CMD #1894 — #790's Hindi/Hinglish expansion is GONE from the query path.
  -- search_query_expand() is not called from anywhere any more and the
  -- search_synonyms table it reads is kept only as data. "bukhar" is now a
  -- word that matches no product name, which is what #747 shipped.
  if length(replace(v_clean,' ','')) < 3 then return; end if;
  v_toks := coalesce(regexp_split_to_array(v_clean, '\s+'), array[]::text[]);

  v_brand := null;
  foreach v_tok in array v_toks loop
    if v_tok ~ '[a-z]' and length(v_tok) >= 3 and not (v_tok = any(c_brandskip)) then
      v_brand := v_tok; exit; end if;
  end loop;
  if v_brand is null then v_brand := split_part(v_clean,' ',1); end if;
  v_pref     := left(v_brand, 3);
  v_brand_dm := dmetaphone(v_brand);

  v_keep := array[]::text[];
  foreach v_tok in array v_toks loop
    if not (v_tok = any(c_forms)) then v_keep := v_keep || v_tok; end if;
  end loop;
  if array_length(v_keep,1) is null then v_keep := v_toks; end if;
  v_compact := array_to_string(v_keep, '');
  v_cl      := length(v_compact);

  select mc.canon, mc.name_norm into v_co, v_co_norm
  from medicine_company mc
  where mc.name_norm = v_clean
     or (length(v_clean) >= 4 and mc.name_norm like v_clean || '%')
  order by (mc.name_norm = v_clean) desc, mc.buyable_count desc, mc.product_count desc
  limit 1;

  if v_co is null and length(replace(v_clean,' ','')) >= 5 then
    select mc.canon, mc.name_norm into v_co, v_co_norm
    from medicine_company mc
    where mc.name_norm like '%' || v_clean || '%'
    order by mc.buyable_count desc, mc.product_count desc
    limit 1;
  end if;

  if v_co is not null then
    v_co_tier := case
      when v_co_norm = v_clean           then 92
      when v_co_norm like v_clean || '%' then 86
      else 78 end;
  end if;

  return query
  with syn_salts as materialized (
    -- CHANGE #790 — "Paracetamol" is a WORD; `salt_composition` holds 106k
    -- real strings like 'Paracetamol (500mg)'. Resolving the word against the
    -- cached salt list first turns the product lookup into equality on
    -- idx_medicine_salt_plain — an ILIKE over 5.6 lakh rows never runs.
    select c.key as salt
      from public.search_suggest_cache c
     where v_syn_kind = 'salt'
       and c.kind = 'salt'
       and c.norm like '%' || public._norm_name(v_syn_target) || '%'
     order by c.rank desc
     limit 40
  ),
  syn_ids as materialized (
    select distinct u.id from (
      ( select m.id from "MEDICINE" m
          join syn_salts ss on ss.salt = m.salt_composition
         where (v_all or lower(m.therapeutic_class) = lower(category_filter))
         order by m.buyable desc, m.sales_count desc nulls last
         limit 250 )
      union all
      ( select m.id from "MEDICINE" m
         where v_syn_kind = 'category'
           and m.therapeutic_class = v_syn_target
           and (v_all or lower(m.therapeutic_class) = lower(category_filter))
         order by m.buyable desc, m.sales_count desc nulls last
         limit 250 )
    ) u
  ),
  co_ids as materialized (
    select m.id from "MEDICINE" m
    where v_co is not null
      and m.marketer_canonical = v_co
      and (v_all or lower(m.therapeutic_class) = lower(category_filter))
    order by m.buyable desc, m.sales_count desc nulls last
    limit 250
  ),
  cand as materialized (
    -- CMD #1903d — the CONTAINS scan is for queries of four characters or
    -- more. `_norm_name(product_name) gin_trgm_ops` answers '%dolo%' from two
    -- trigrams in 10 ms; a three-letter query is ONE trigram, so '%pan%'
    -- matched a bitmap the size of the catalogue and took 1.34 s of the 3 s
    -- the anon role is allowed — the single reason searching "pan" answered
    -- HTTP 500 while "crocin" answered in 0.74 s. Nothing of value is lost:
    -- the 300 rows it capped at were an arbitrary 300 out of tens of
    -- thousands, and a three-letter query is a prefix ("pan" → Pan 40,
    -- Pantop, Pantocid), which the branch below answers exactly.
    ( select m.id from "MEDICINE" m
      where length(replace(v_clean,' ','')) >= 4
        and public._norm_name(m.product_name) like '%'||v_clean||'%'
        and (v_all or lower(m.therapeutic_class) = lower(category_filter)) limit 300 )
    union
    ( select m.id from "MEDICINE" m
      where public._norm_name(m.product_name) like v_pref||'%'
        and (v_all or lower(m.therapeutic_class) = lower(category_filter)) limit 1000 )
    union
    ( select ci.id from co_ids ci )
    union
    ( select si.id from syn_ids si )
  ),
  scored as materialized (
    select m.id, m.product_name, m.salt_composition, m.marketer, m.therapeutic_class,
           m.image_url_1, m.pack_qty, m.pack_size, m.pack_type, m.mrp, m.gst_percent,
           m.rx_required, m.sales_count, m.has_scheme, m.has_image, m.buyable,
           m.supplier_count, m.marketer_canonical,
           case when v_is_admin
                then coalesce(m.supplier_label,'') else '' end as supplier_label,
           public._norm_name(m.product_name) as prod_clean,
           (ci.id is not null) as is_co,
           (si.id is not null) as is_syn
    from "MEDICINE" m
    join cand c on c.id = m.id
    left join co_ids ci on ci.id = m.id
    left join syn_ids si on si.id = m.id
  ),
  scored2 as materialized (
    select s.*,
           regexp_split_to_array(s.prod_clean,' ') as prod_toks,
           replace(s.prod_clean,' ','')            as prod_compact,
           length(replace(s.prod_clean,' ',''))    as pc_len,
           split_part(s.prod_clean,' ',1)          as prod_first,
           similarity(s.prod_clean, v_clean)       as sim_full
    from scored s
  ),
  tokcum as materialized (
    select s.id,
           sum(length(t.tok)) over (partition by s.id order by t.ord
                                    rows between unbounded preceding and current row) as cumlen
    from scored2 s
    cross join lateral unnest(s.prod_toks) with ordinality as t(tok, ord)
    where v_cl >= 4 and s.prod_compact like v_compact || '%'
  ),
  tokmatch as materialized (
    select distinct tc.id from tokcum tc where tc.cumlen = v_cl
  ),
  ranked as (
    select s.*,
      greatest(
        (case
           when s.prod_clean = v_clean then 100
           when s.prod_clean like v_clean || '%' then 97
           when v_cl >= 4 and s.id in (select tm.id from tokmatch tm) then 96
           when v_cl >= 4 and s.prod_compact like v_compact || '%'
                and ( s.pc_len = v_cl or right(v_compact,1) !~ '[a-z]'
                      or substr(s.prod_compact, v_cl + 1, 1) !~ '[a-z]' ) then 95
           when v_cl >= 5 and s.prod_compact ~ ('(^|[^a-z])' || v_compact || '([^a-z]|$)') then 88
           when s.prod_first = v_brand then 85
           when levenshtein(v_brand, s.prod_first) <= 1 then 72
           when levenshtein(v_brand, s.prod_first) <= 2 then 60
           when v_brand_dm = dmetaphone(s.prod_first) then 55
           else 0 end),
        (case when s.is_co then v_co_tier else 0 end),
        -- a mapped word ("bukhar") matches nothing by name, so its rows carry
        -- their own tier or the tier cut below would drop every one of them
        (case when s.is_syn then 70 else 0 end)
      ) as tier
    from scored2 s
  ),
  -- CMD #1812: there is no sellability word any more. A row ranks by whether a
  -- supplier in the viewer's zone can actually send it, and by nothing else.
  finalr as (
    select r.*,
           (case when r.tier = 0 and r.sim_full >= 0.45 then 50 else r.tier end) as tier_final,
           -- CMD #1903 — inside one tier, the CLOSEST pack first: the exact
           -- name, then the query as the whole first word ("Monticope Tablet",
           -- "Monticope Suspension"), then a longer brand off the same root
           -- ("Monticope-A Tablet SR"). This is what puts the pack a buyer
           -- typed at the top of the list instead of behind its own family.
           (case
              when r.prod_clean = v_clean            then 0
              when r.prod_first = v_clean            then 1
              when r.prod_clean like v_clean || ' %' then 2
              when r.prod_clean like v_clean || '%'  then 3
              else 4 end) as name_rank
    from ranked r
  ),
  -- CHANGE #678: for an approved customer the "has a supplier" rank is their
  -- ZONE's standby, so what is available to them sorts first. Anon keeps the
  -- catalogue count. Evaluated only for rows that survive the tier cut.
  kept as (
    select f.*,
           (case when public.zone_available(f.id, v_zone) then 0 else 1 end) as sell_rank
    from finalr f
   where f.tier_final >= 50
     -- CHANGE #790 — #747's switch, applied to search: with it on, an approved
     -- customer is shown what a supplier in their zone can actually send.
     and (v_zfilter is null
          or public.zone_available(f.id, v_zfilter))
  ),
  -- #451: one row per (normalised name, marketer). The identical 'Dolo-T
  -- Tablet [NOT FOR SALE]' pair collapses to its best-ranked member.
  deduped as (
    select k.*, row_number() over (
             partition by k.prod_clean, coalesce(k.marketer_canonical, k.marketer, '')
             order by k.tier_final desc, k.name_rank asc, k.sell_rank asc,
                      k.buyable desc,
                      k.sales_count desc nulls last, k.has_image desc, k.id asc) as dup_rn
    from kept k
  )
  select f.id, f.product_name, f.salt_composition, f.marketer, f.therapeutic_class,
         f.image_url_1,
         coalesce(nullif(btrim(f.pack_type),''), nullif(btrim(f.pack_size),'')) as pack_qty,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_size,
         coalesce(nullif(btrim(f.pack_qty),''),  nullif(btrim(f.pack_size),'')) as pack_type,
         f.mrp, f.gst_percent,
         f.rx_required, f.sales_count, f.has_scheme, f.has_image, f.buyable,
         f.supplier_count, f.supplier_label
  from deduped f
  where f.dup_rn = 1
  -- CMD #1903 — the ranked, flat order this list has to have: the closest
  -- match first, then the other packs of the same brand (they share its
  -- tier), then similar brands. `sell_rank` used to lead, so an exact match
  -- with no supplier in the viewer's zone sank below every loosely-matched
  -- pack that had one — searching "monticope" never showed Monticope Tablet.
  -- It still breaks ties, one step down.
  order by f.tier_final desc, f.name_rank asc, length(f.prod_clean) asc,
           f.sell_rank asc, f.buyable desc,
           f.sales_count desc nulls last, f.sim_full desc, length(f.product_name) asc
  limit page_limit offset page_offset;
end;
$function$;

CREATE OR REPLACE FUNCTION public.order_edit_apply(p_order_id uuid, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare g jsonb; o record; v_items jsonb; v_total numeric; v_before jsonb; v_bad int;
        v_unavail jsonb; v_cnt int; v_cu bigint; v_pricing jsonb; v_pin text;
begin
  g := public._order_edit_gate(p_order_id);
  if (g->>'can_edit')::boolean is not true then
    return jsonb_build_object('ok', false, 'error', g->>'error', 'tone','danger',
      'message', coalesce(g->>'message',''));
  end if;
  if not public.customer_can('customer.orders','write')
     and public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('order_edit.err_not_authorized'));
  end if;

  select * into o from orders where id = p_order_id for update;
  v_before := o.items;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    return jsonb_build_object('ok', false, 'error','empty_basket','tone','danger',
      'message', public.ui_text('order_edit.empty_basket'));
  end if;

  -- (a) every quantity a whole number >= 1
  select count(*) into v_bad from jsonb_array_elements(p_lines) l
   where coalesce((l->>'quantity')::numeric, 0) < 1
      or (l->>'quantity')::numeric <> floor((l->>'quantity')::numeric);
  if v_bad > 0 then
    return jsonb_build_object('ok', false, 'error','bad_qty','tone','danger',
      'message', public.ui_text('order_edit.err_bad_qty'));
  end if;

  -- (b) every product still in the catalogue
  select count(*) into v_bad from jsonb_array_elements(p_lines) l
   where not exists (select 1 from "MEDICINE" m where m.id = (l->>'product_id')::bigint);
  if v_bad > 0 then
    return jsonb_build_object('ok', false, 'error','unknown_item','tone','danger',
      'message', public.ui_text('order_edit.err_unknown_item'));
  end if;

  -- (c) availability — the same predicate _cart_unavailable_lines() uses.
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id', m.id, 'product_name', m.product_name)), '[]'::jsonb)
    into v_unavail
    from jsonb_array_elements(p_lines) l
    join "MEDICINE" m on m.id = (l->>'product_id')::bigint
   where o.zone_id is not null
     and not public.zone_available(m.id, o.zone_id);
  if jsonb_array_length(v_unavail) > 0 then
    return jsonb_build_object('ok', false, 'error','unavailable','tone','danger',
      'items', v_unavail, 'count', jsonb_array_length(v_unavail),
      'message', public.ui_text('order_edit.err_unavailable'));
  end if;

  -- (d) serviceability — checkout_action() lets can_order=false be the ONLY
  -- blocker; the edit window honours the same rule, not a stricter one.
  select pp.pincode into v_pin from pharmacy_profiles pp where pp.id = o.customer_id;
  if coalesce((public.delivery_serviceability_check(v_pin)->>'can_order')::boolean, true) is false then
    return jsonb_build_object('ok', false, 'error','not_serviceable','tone','danger',
      'message', coalesce(
        public.delivery_serviceability_check(v_pin)->>'message',
        public.ui_text('order_edit.err_unavailable')));
  end if;

  -- Rebuild the items array in the SHAPE explode_order_items reads, carrying
  -- the catalogue's own name and its mrp PARSED OUT of the rendered string.
  select jsonb_agg(jsonb_build_object(
           'product_id',   m.id,
           'product_name', m.product_name,
           'quantity',     (l->>'quantity')::numeric,
           'mrp',          public._slab_num(m.mrp),
           'gst_percent',  m.gst_percent)
         order by m.product_name)
    into v_items
    from jsonb_array_elements(p_lines) l
    join "MEDICINE" m on m.id = (l->>'product_id')::bigint;

  if v_items is not distinct from v_before then
    return jsonb_build_object('ok', false, 'error','no_change','tone','info',
      'message', public.ui_text('order_edit.no_change'));
  end if;

  -- THE TOTAL IS THE TRADE TOTAL, never MRP. Same function placement uses.
  v_pricing := public.cart_pricing_block(v_items);
  v_total   := coalesce((v_pricing->>'net_payable')::numeric, 0);

  v_cu := public.my_customer_user_id();

  update orders
     set items = v_items,
         total_amount = v_total,
         acted_customer_user_id = v_cu,
         acted_identity = coalesce((select identity from customer_users where id = v_cu),
                                   public.my_login_email())
   where id = p_order_id;

  select count(*) into v_cnt from jsonb_array_elements(v_items);

  begin
    perform public.order_slab_snapshot(p_order_id, true);
  exception when others then null;
  end;

  insert into order_edit_event(order_id, customer_id, customer_user_id, identity,
                               acting_as_admin, items_before, items_after,
                               lines_before, lines_after, total_before, total_after)
  values (p_order_id, o.customer_id, v_cu,
          coalesce((select identity from customer_users where id = v_cu), public.my_login_email()),
          (public.my_acting_as() is not null),
          v_before, v_items,
          coalesce(jsonb_array_length(v_before), 0), v_cnt,
          o.total_amount, v_total);

  perform public.customer_action_stamp('order_edited', p_order_id,
            jsonb_build_object('lines_before', coalesce(jsonb_array_length(v_before),0),
                               'lines_after', v_cnt));

  return jsonb_build_object('ok', true, 'tone','success',
    'order_id', p_order_id,
    'line_count', v_cnt,
    'total', v_total,
    'total_display', coalesce(v_pricing->>'net_payable_display', public.inr_money(v_total)),
    'message', public.ui_text('order_edit.saved'));
exception when others then
  return jsonb_build_object('ok', false, 'error','exception','tone','danger',
    'message', replace(public.ui_text('order_edit.err_failed'), '{detail}', SQLERRM),
    'sqlstate', SQLSTATE);
end $function$;

CREATE OR REPLACE FUNCTION public.reorder_confirm_pending(p_cust uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare pend record; e jsonb; v_added int := 0; v_uid uuid; v_zone smallint;
begin
  select * into pend from public.reorder_pending
   where customer_id=p_cust and status='open' order by created_at limit 1;
  if pend.id is null then
    return jsonb_build_object('ok', false, 'reason','no_pending');
  end if;
  select user_id into v_uid from public.pharmacy_profiles where id=p_cust;
  -- CMD #1926 — this runs for the CUSTOMER, not the caller, so the zone is
  -- read from their profile rather than from _viewer_zone_or_null().
  select zone_id into v_zone from public.pharmacy_profiles where id=p_cust;
  for e in select * from jsonb_array_elements(pend.items) loop
    insert into public.cart_items(user_id, customer_id, product_id, product_name, price, mrp,
                                  quantity, gst_percent, added_by)
    select v_uid, p_cust, (e->>'product_id'), coalesce(m.product_name, e->>'name'),
           nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
           nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,
           greatest((e->>'qty')::int,1),
           nullif(regexp_replace(coalesce(m.gst_percent::text,''),'\D','','g'),'')::int, 'reorder'
      from "MEDICINE" m
     where m.id::text = (e->>'product_id')
       and public.zone_available(m.id, v_zone)
    on conflict (user_id, product_id) do update
       set quantity=excluded.quantity, removed_by_admin=false, updated_at=now();
    v_added := v_added + 1;
  end loop;
  update public.reorder_pending set status='confirmed', resolved_at=now() where id=pend.id;
  return jsonb_build_object('ok', true, 'added', v_added, 'pending_id', pend.id);
end $function$;

CREATE OR REPLACE FUNCTION public.reorder_diff(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'mode', 'public'
AS $function$
declare v_cust uuid; v_ord record; v_lines jsonb; v_avail int; v_removed int;
        v_up int; v_down int; v_zone smallint;
begin
  v_cust := public.my_customer_id();
  select o.id, o.order_code, o.customer_id into v_ord
    from orders o where o.id = p_order_id;
  if v_ord.id is null or (v_cust is not null and v_ord.customer_id <> v_cust
        and public.get_my_role() not in ('admin','super_admin')) then
    return jsonb_build_object('ok', false,
      'message', public._reorder_uic('reorder.order_not_found','Order not found'));
  end if;
  v_zone := public._viewer_zone_or_null();  -- CMD #1926

  select coalesce(jsonb_agg(line order by nm), '[]'::jsonb),
         coalesce(sum(case when avail then 1 else 0 end),0),
         coalesce(sum(case when not avail and swap_id is null then 1 else 0 end),0),
         coalesce(sum(case when delta > 0 then 1 else 0 end),0),
         coalesce(sum(case when delta < 0 then 1 else 0 end),0)
    into v_lines, v_avail, v_removed, v_up, v_down
  from (
    select oi.product_name as nm,
           coalesce(public.storefront_can_add(m.id, m.supplier_count), false) as avail,
           s.swap_id,
           round(coalesce(cur.mrp,0) - coalesce(oi.price,0),2) as delta,
           jsonb_build_object(
             'product_id', oi.product_id::text,
             'name', coalesce(m.product_name, oi.product_name),
             'last_qty', oi.quantity::int,
             'last_price_display', public._reorder_money(oi.price),
             'now_price_display', case when m.id is not null then public._reorder_money(cur.mrp) else '' end,
             'price_delta', round(coalesce(cur.mrp,0) - coalesce(oi.price,0),2),
             'price_delta_label', case
                 when m.id is null then ''
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) > 0
                      then '↑ ' || public._reorder_money(coalesce(cur.mrp,0)-coalesce(oi.price,0))
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) < 0
                      then '↓ ' || public._reorder_money(coalesce(oi.price,0)-coalesce(cur.mrp,0))
                 else public._reorder_uic('reorder.same_price','Same price') end,
             'price_tone', case
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) > 0 then 'warning'
                 when round(coalesce(cur.mrp,0)-coalesce(oi.price,0),2) < 0 then 'success'
                 else 'neutral' end,
             'status', case when m.id is null then 'discontinued'
                            when public.storefront_can_add(m.id, m.supplier_count) then 'available'
                            else 'out_of_stock' end,
             'status_label', case when m.id is null then public._reorder_uic('reorder.discontinued','No longer listed')
                            when public.storefront_can_add(m.id, m.supplier_count) then public._reorder_uic('reorder.in_stock','Available')
                            else public._reorder_uic('reorder.oos','Out of stock') end,
             'can_add', coalesce(public.storefront_can_add(m.id, m.supplier_count), false),
             'availability', case when m.id is null then null
                                  else public.storefront_availability(m.id, m.supplier_count) end,
             'swap', case when coalesce(public.storefront_can_add(m.id, m.supplier_count), false) = false
                            and sw.id is not null
                          then jsonb_build_object(
                                 'product_id', sw.id::text,
                                 'name', sw.product_name,
                                 'price_display', public._reorder_money(
                                     nullif(regexp_replace(coalesce(sw.mrp::text,''),'[^0-9.]','','g'),'')::numeric),
                                 'reason', public._reorder_uic('reorder.swap_reason','Same maker, in stock'))
                          else null end
           ) as line
      from order_items oi
      left join "MEDICINE" m on m.id = oi.product_id
      left join lateral (
        select nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric as mrp
      ) cur on true
      left join lateral (
        -- CMD #1926 — a swap is only a swap if the BUYER's zone can send it.
        select sw2.id as swap_id from "MEDICINE" sw2
         where coalesce(public.storefront_can_add(m.id, m.supplier_count), false) = false
           and sw2.id <> coalesce(m.id,-1)
           and sw2.buyable is true
           and public.zone_available(sw2.id, v_zone)
           and ( (m.marketer is not null and sw2.marketer = m.marketer)
                 or (m.therapeutic_class is not null and sw2.therapeutic_class = m.therapeutic_class) )
         order by (case when sw2.marketer = m.marketer then 0 else 1 end), sw2.supplier_count desc
         limit 1
      ) s on true
      left join "MEDICINE" sw on sw.id = s.swap_id
     where oi.order_id = p_order_id
       and coalesce(oi.unfulfillable,false) = false
  ) q;

  return jsonb_build_object(
    'ok', true,
    'order_code', coalesce(v_ord.order_code,''),
    'title', public._reorder_uic('reorder.diff_title','Reorder this order'),
    'lines', v_lines,
    'summary', jsonb_build_object(
       'total_lines', jsonb_array_length(v_lines),
       'available', v_avail,
       'removed', v_removed,
       'price_up', v_up,
       'price_down', v_down,
       'removed_label', case when v_removed > 0
            then v_removed::text || ' ' || public._reorder_uic('reorder.removed_suffix','item(s) unavailable — skipped')
            else '' end,
       'changes_label', case when (v_up+v_down) > 0
            then (v_up+v_down)::text || ' ' || public._reorder_uic('reorder.price_changed_suffix','price change(s) since last time')
            else '' end),
    'cta_label', public._reorder_uic('reorder.add_available','Add available items to cart'),
    'repeat_label', public._reorder_uic('reorder.repeat_toggle','Repeat this order automatically'),
    'repeat_note', public._reorder_uic('reorder.repeat_note','Every 30 days — we confirm on WhatsApp before dispatch'),
    'manage_label', public._reorder_uic('reorder.manage','Manage auto-reorders'),
    'generic_error', public._reorder_uic('reorder.add_generic_error','Something went wrong'),
    'add_count', v_avail);
end $function$;

CREATE OR REPLACE FUNCTION public.reorder_lowstock_check()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p record; v_items jsonb; v_pid uuid; n int := 0;
begin
  for p in
    select distinct customer_id from public.reorder_prefs where notify = true
  loop
    select coalesce(jsonb_agg(jsonb_build_object(
             'product_id', cd.product_id, 'qty', cd.usual_qty, 'name', cd.name)), '[]'::jsonb)
      into v_items
      from public._reorder_cadence(p.customer_id) cd
      join public.reorder_prefs rp
        on rp.customer_id = p.customer_id and rp.product_id = cd.product_id and rp.notify = true
     -- CMD #1926 — never nudge a buyer about a pack their zone cannot send.
     where public.zone_available(
             cd.product_id::bigint,
             (select pp.zone_id from public.pharmacy_profiles pp where pp.id = p.customer_id))
       and ( cd.due
             or (rp.shelf_level is not null and cd.usual_qty <= rp.shelf_level) );
    if v_items <> '[]'::jsonb then
      v_pid := public._reorder_open_pending(p.customer_id, 'lowstock', v_items, null);
      if v_pid is not null then
        perform public.wa_send_event('reorder_due', p.customer_id, jsonb_build_object(), null, null);
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.substitute_candidates(p_product_id bigint, p_zone_id smallint DEFAULT NULL::smallint, p_customer_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m       public."MEDICINE"%rowtype;
  v_zone  smallint := p_zone_id;
  v_lim   int := coalesce(p_limit,
                   (select (value #>> '{}')::int from app_settings
                     where key = 'substitute_ask_max_options'), 3);
  v_units numeric;
  v_items jsonb;
begin
  select * into m from public."MEDICINE" where id = p_product_id;
  if m.id is null or not public.med_substitutable(p_product_id) then
    return jsonb_build_object('has', false, 'salt_key', '', 'items', '[]'::jsonb);
  end if;
  v_zone  := coalesce(v_zone, public.zone_default_id());
  v_units := nullif(regexp_replace(coalesce(m.pack_qty,''), '\D', '', 'g'), '')::numeric;

  with pool as (
    -- Bounded on purpose: the salt index hands back the same-salt shelf, and
    -- everything expensive below (zone standby, purchase history) only ever
    -- runs over that shelf, never over the 563k-row catalogue.
    select s.id, s.product_name, s.marketer, s.salt_composition,
           s.pack_type, s.pack_qty, s.pack_size, s.image_url_1,
           coalesce(s.supplier_count, 0) as supplier_count,
           coalesce(s.sales_count, 0)    as sales_count,
           nullif(regexp_replace(coalesce(s.pack_qty,''), '\D', '', 'g'), '')::numeric as units
      from public."MEDICINE" s
     where s.buyable is true
       and s.salt_composition = m.salt_composition
       and s.id <> m.id
       and public._norm_seg(s.pack_type) = public._norm_seg(m.pack_type)
       and public._norm_seg(s.marketer) <> public._norm_seg(coalesce(m.marketer,''))
     order by coalesce(s.sales_count, 0) desc, s.id
     limit 60
  ), zoned as (
    select p.*, (case when public.zone_available(p.id, v_zone) then 1 else 0 end) as zone_count
      from pool p
  ), live as (
    select z.* from zoned z
     where z.zone_count > 0 and public.med_substitutable(z.id)
  ), one_per_product as (
    -- ONE row per product+company. The catalogue is per pack; the customer is
    -- choosing a MEDICINE. Keep the pack nearest the original's strip size —
    -- that is the one substitute_equivalent_qty converts most cleanly.
    select distinct on (public._norm_seg(l.product_name), public._norm_seg(l.marketer)) l.*
      from live l
     order by public._norm_seg(l.product_name), public._norm_seg(l.marketer),
              case when v_units is null or l.units is null
                   then 999999 else abs(l.units - v_units) end,
              l.sales_count desc, l.id
  ), history as (
    select oi.product_id, count(*)::int as bought
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where p_customer_id is not null
       and o.customer_id = p_customer_id
       and oi.product_id in (select id from one_per_product)
     group by oi.product_id
  ), ranked as (
    select c.*, coalesce(h.bought, 0) as bought,
           row_number() over (order by coalesce(h.bought,0) desc,
                                       c.supplier_count desc,
                                       c.sales_count desc,
                                       c.id) as rnk
      from one_per_product c
      left join history h on h.product_id = c.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',  r.id,
           'name',        coalesce(r.product_name, ''),
           'company',     coalesce(r.marketer, ''),
           'strength',    coalesce(r.salt_composition, ''),
           'pack_label',  coalesce(nullif(btrim(r.pack_qty), ''),
                                   nullif(btrim(r.pack_type), ''),
                                   nullif(btrim(r.pack_size), ''), ''),
           'image',       coalesce(r.image_url_1, ''),
           'bought_before', (r.bought > 0),
           'rank',        r.rnk) order by r.rnk), '[]'::jsonb)
    into v_items
    from ranked r
   where r.rnk <= greatest(v_lim, 1);

  return jsonb_build_object(
    'has',      jsonb_array_length(v_items) > 0,
    'salt_key', coalesce(public.med_composition_key(m.salt_composition, '', m.pack_type), ''),
    'items',    v_items);
end $function$;
CREATE OR REPLACE FUNCTION public._cat_products_rail(p_where text, p_zone smallint, p_total bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_max  bigint := coalesce((public._cat_landing_cfg()->>'rail_scan_max')::bigint, 50000);
  v_have text[] := '{}'::text[];
  v_scan boolean := (p_total is not null and p_total <= v_max);
  v_sql  text;
  v_join text := '';
begin
  if v_scan then
    if p_zone is not null then
      v_join := format('join public.zone_available_products(%L::smallint) za '
                       || 'on za.product_id = m.id', p_zone);
    end if;
    v_sql := format(
      'select coalesce(array_agg(distinct l), ''{}''::text[]) from ('
      || 'select case when left(public._norm_name(m.product_name),1) between ''a'' and ''z'' '
      || '            then upper(left(public._norm_name(m.product_name),1)) else ''#'' end as l '
      || 'from public."MEDICINE" m %s where %s) s', v_join, p_where);
    execute v_sql into v_have;
  end if;

  return jsonb_build_object(
    'label', public.uic('catalogue.rail_products_label','Jump to a letter'),
    'all_label', public.uic('catalogue.letter_all','All'),
    'letters', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', t.key,
               'label', case when t.key = '#'
                             then public.uic('catalogue.rail_other','#') else t.key end,
               'enabled', (not v_scan) or t.key = any(v_have))
             order by (t.key = '#'), t.key)
        from (select chr(64 + generate_series(1,26)) as key
              union all select '#') t), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.search_suggest_unit(p_kind text, p_arg text DEFAULT ''::text, p_arg2 text DEFAULT ''::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rows bigint := 0;
  v_bucket int;
  v_facet text;
begin
  if p_kind = 'suggest_reset' then
    delete from public.search_suggest_stage;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_brand' then
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select 'brand', g.root || '|' || coalesce(g.mc, ''), p_arg, g.label,
           coalesce(mc.display, g.mc, ''), g.n, g.rank, g.root, '{}'::smallint[], g.label
      from (
        select b.root, b.mc,
               (array_agg(b.product_name order by b.nlen, b.sales_count desc nulls last, b.id))[1] as label,
               count(*)::int as n,
               coalesce(sum(b.sales_count), 0)::bigint as rank
          from (
            select m.id, m.product_name, m.marketer_canonical as mc, m.sales_count,
                   public._brand_root(m.product_name) as root,
                   length(public._norm_name(m.product_name)) as nlen
              from public."MEDICINE" m
             where m.id between p_arg::bigint and p_arg2::bigint
               and true
               and nullif(btrim(m.product_name), '') is not null
          ) b
         group by b.root, b.mc
      ) g
      left join public.medicine_company mc on mc.canon = g.mc
    on conflict (kind, key, src) do update
      set n = excluded.n, rank = excluded.rank, label = excluded.label,
          sub_label = excluded.sub_label, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_zone' then
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    with fam as (
      select distinct public.brand_family_key(m.product_name, m.marketer_canonical) as key
        from public.zone_available_products(v_bucket::smallint) za
        join public."MEDICINE" m on m.id = za.product_id
    )
    update public.search_suggest_stage s
       set zones = (select coalesce(array_agg(distinct z order by z), '{}'::smallint[])
                      from unnest(s.zones || array[v_bucket::smallint]) z)
      from fam
     where s.kind = 'brand' and s.key = fam.key
       and not (s.zones @> array[v_bucket::smallint]);
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_facet' then
    -- CHANGE #790E — the zone list is aggregated ONCE, keyed by facet_key, and
    -- joined. The old shape ran one correlated subquery per row: 106,571 of
    -- them for salts, which never finished inside the statement cap.
    v_facet := case p_arg when 'category' then 'therapeutic' else p_arg end;
    with zone_of as (
      select z.facet_key,
             array_agg(distinct z.zone_id order by z.zone_id) as zones
        from public.catalogue_facet_count z
       where z.facet = v_facet
         and z.zone_id > 0
       group by z.facet_key
    )
    insert into public.search_suggest_stage(kind, key, src, label, sub_label, n, rank, norm, zones, query)
    select p_arg, c.facet_key, '', c.label, '', c.n, c.n::bigint,
           public._norm_name(c.label),
           coalesce(zo.zones, '{}'::smallint[]),
           c.label
      from public.catalogue_facet_count c
      left join zone_of zo on zo.facet_key = c.facet_key
     where c.zone_id = 0
       and c.facet = v_facet
       and nullif(btrim(c.label), '') is not null
    on conflict (kind, key, src) do update
      set label = excluded.label, n = excluded.n, rank = excluded.rank,
          norm = excluded.norm, zones = excluded.zones, query = excluded.query;
    get diagnostics v_rows = row_count;

  elsif p_kind = 'suggest_swap' then
    -- CHANGE #790E — this statement never once succeeded. `zones` is
    -- smallint[], so array_agg(s.zones) is smallint[][] and subscripting it
    -- with [1] yields a scalar smallint, which the column refuses:
    --   ERROR: column "zones" is of type smallint[] but expression is of
    --          type smallint
    -- The swap is the ONLY writer of search_suggest_cache, so the cache stayed
    -- empty and every typeahead answer was empty with it — the whole feature
    -- was dead on arrival and nothing said so, because catalogue_cache_tick()
    -- records the unit's error and moves on.
    -- A family that appears in several id ranges is available in the UNION of
    -- the zones those ranges saw, so the zones are unnested and re-aggregated
    -- rather than picked from one row.
    v_bucket := coalesce(nullif(p_arg, ''), '0')::int;
    delete from public.search_suggest_cache c
     where abs(hashtext(c.key)) % 6 = v_bucket;
    with src as (
      select s.* from public.search_suggest_stage s
       where abs(hashtext(s.key)) % 6 = v_bucket
    ),
    pick as (
      select s.kind, s.key,
             (array_agg(s.label     order by length(s.label), s.src))[1] as label,
             (array_agg(s.sub_label order by length(s.label), s.src))[1] as sub_label,
             sum(s.n)::int    as n,
             sum(s.rank)::bigint as rank,
             (array_agg(s.norm  order by length(s.label), s.src))[1] as norm,
             (array_agg(s.query order by length(s.label), s.src))[1] as query
        from src s group by s.kind, s.key
    ),
    zed as (
      select s.kind, s.key,
             coalesce(array_agg(distinct zz order by zz)
                        filter (where zz is not null), '{}'::smallint[]) as zones
        from src s
        left join lateral unnest(s.zones) zz on true
       group by s.kind, s.key
    )
    insert into public.search_suggest_cache(kind, key, label, sub_label, n, rank, norm, zones, query)
    select p.kind, p.key, p.label, p.sub_label, p.n, p.rank, p.norm,
           coalesce(z.zones, '{}'::smallint[]), p.query
      from pick p
      left join zed z on z.kind = p.kind and z.key = p.key
    on conflict (kind, key) do update
      set label = excluded.label, sub_label = excluded.sub_label, n = excluded.n,
          rank = excluded.rank, norm = excluded.norm, zones = excluded.zones,
          query = excluded.query;
    get diagnostics v_rows = row_count;
  end if;

  return v_rows;
end $function$;

CREATE OR REPLACE FUNCTION public.catalogue_top_selling(p_zone boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_az    smallint := public._cat_avail_zone();
  v_cfg   jsonb    := public._cat_landing_cfg();
  v_days  int      := greatest(coalesce((v_cfg->>'top_selling_days')::int, 30), 1);
  v_lim   int      := least(greatest(coalesce((v_cfg->>'top_selling_limit')::int, 12), 1), 24);
  v_ids   bigint[] := '{}'::bigint[];
  v_note  text;
  v_cards jsonb;
begin
  -- 1. the window: quantity ordered in this zone over the last v_days.
  select coalesce(array_agg(x.product_id order by x.q desc, x.product_id), '{}'::bigint[])
    into v_ids
    from (
      select oi.product_id, sum(coalesce(oi.quantity,0))::numeric as q
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
       where o.created_at >= now() - make_interval(days => v_days)
         and oi.product_id is not null
         and (v_az is null or o.zone_id = v_az)
       group by oi.product_id
       having sum(coalesce(oi.quantity,0)) > 0
       order by 2 desc, 1
       limit v_lim) x;
  v_note := public.uic('catalogue.top_selling_note',
                       'What pharmacies near you order most');

  -- 2. the fallback: what this zone can actually buy.
  if coalesce(array_length(v_ids,1),0) = 0 then
    select coalesce(array_agg(y.id order by y.id), '{}'::bigint[])
      into v_ids
      from (
        select m.id
          from public."MEDICINE" m
          join public.zone_available_products(v_az) za
            on za.product_id = m.id
         where lower(coalesce(m.buyable::text,'')) in ('true','t')
         order by m.id
         limit v_lim) y;
    v_note := public.uic('catalogue.top_selling_fallback_note',
                         'Available in your zone');
  end if;

  -- 3. still nothing (an empty zone, an anonymous visitor before any zone is
  --    known): the block says has:false and the app draws no rail at all.
  if coalesce(array_length(v_ids,1),0) = 0 then
    select coalesce(array_agg(z.id order by z.id), '{}'::bigint[])
      into v_ids
      from (select m.id from public."MEDICINE" m
             where lower(coalesce(m.buyable::text,'')) in ('true','t')
             order by m.id limit v_lim) z;
    v_note := public.uic('catalogue.top_selling_fallback_note',
                         'Available in your zone');
  end if;

  v_cards := public._sf_cards(v_ids);
  return jsonb_build_object(
    'has',   jsonb_array_length(coalesce(v_cards,'[]'::jsonb)) > 0,
    'title', public.uic('catalogue.top_selling_title','Top selling'),
    'note',  v_note,
    'items', coalesce(v_cards, '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.condition_counts_refresh(p_key text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows bigint := 0; v_step bigint; z record;
begin
  -- zone 0 is the whole catalogue; a real zone joins the materialised
  -- availability list, exactly as catalogue_cache_tick does for every other
  -- facet. Same shape, so the two can never disagree.
  delete from public.catalogue_facet_count
   where facet = 'condition'
     and (p_key is null or facet_key = p_key);

  insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
  select 'condition', 0::smallint, '', c.condition_key, c.label,
         case when upper(left(c.label,1)) between 'A' and 'Z'
              then upper(left(c.label,1)) else '#' end,
         count(distinct m.id)
    from public.use_bucket c
    join public.use_bucket_medicine cm on cm.condition_id = c.id
    join public."MEDICINE" m on m.id = cm.medicine_id
   where c.is_active and (p_key is null or c.condition_key = p_key)
   group by c.condition_key, c.label
  having count(distinct m.id) > 0;
  get diagnostics v_rows = row_count;

  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
    select 'condition', z.id, '', c.condition_key, c.label,
           case when upper(left(c.label,1)) between 'A' and 'Z'
                then upper(left(c.label,1)) else '#' end,
           count(distinct m.id)
      from public.use_bucket c
      join public.use_bucket_medicine cm on cm.condition_id = c.id
      join public."MEDICINE" m on m.id = cm.medicine_id
      join public.zone_available_products(z.id) za on za.product_id = m.id
     where c.is_active and (p_key is null or c.condition_key = p_key)
     group by c.condition_key, c.label
    having count(distinct m.id) > 0;
    get diagnostics v_step = row_count;
    v_rows := v_rows + v_step;
  end loop;

  -- The door's own number, per zone. It counts DISTINCT products, so a product
  -- under both Fever and Pain is one product on the tile.
  delete from public.catalogue_facet_count
   where facet = 'meta' and facet_key in ('conditions','condition_products');
  insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
  select 'meta', f.zone_id, '', 'conditions', 'conditions', '', count(*)
    from public.catalogue_facet_count f where f.facet = 'condition'
   group by f.zone_id;
  insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
  select 'meta', 0::smallint, '', 'condition_products', 'condition_products', '',
         count(distinct cm.medicine_id)
    from public.use_bucket_medicine cm
    join public.use_bucket c on c.id = cm.condition_id and c.is_active;
  for z in select id from public.zones
            where is_active and not coalesce(is_synthetic,false) order by id loop
    insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
    select 'meta', z.id, '', 'condition_products', 'condition_products', '',
           count(distinct cm.medicine_id)
      from public.use_bucket_medicine cm
      join public.use_bucket c on c.id = cm.condition_id and c.is_active
      join public.zone_available_products(z.id) za on za.product_id = cm.medicine_id;
  end loop;

  perform public.search_suggest_conditions_rebuild();
  return v_rows;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_supplier_tab_availability(p_supplier_id uuid, p_zone_id smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := public._sup753_gate();
  v_scope smallint := public.admin_active_zone();
  sp supplier_profiles%rowtype;
  v_zone smallint; v_zones jsonb; v_items jsonb; v_copy jsonb; v_shop jsonb;
  v_avail text := 'Available'; v_oos text := 'Out of Stock';
  v_dont text := 'We don''t stock this product';
begin
  if v_role = 'none' then return public._sup753_deny(false); end if;
  sp := public._sup753_row(p_supplier_id);
  if sp.id is null then return public._sup753_deny(false); end if;

  v_zone := coalesce(p_zone_id, v_scope, sp.zone_id);
  v_copy := jsonb_build_object('one', public._c('admin_sup2.a_times_one'),
                               'many', public._c('admin_sup2.a_times_many'));

  -- The shop open/closed panel — this is what the old card's "Availability"
  -- button opened, and it is the same _supplier_closure_panel the supplier's
  -- own portal renders.
  v_shop := public._supplier_closure_panel(sp.supplier_name, 'admin');

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', z.id::text,
           'value', z.id,
           'label', case z.id when 1 then '①' when 2 then '②' when 3 then '③'
                              when 4 then '④' when 5 then '⑤'
                              else '('||z.id::text||')' end || ' ' || z.name,
           'count', (select count(*) from supplier_item_memory m
                      join public.zone_available_products(z.id) cz
                        on cz.product_id = m.product_id
                     where lower(btrim(m.supplier_name)) = lower(btrim(sp.supplier_name))),
           'active', (z.id = v_zone))
         order by z.id), '[]'::jsonb)
    into v_zones
    from zones z
   where (v_scope is null or z.id = v_scope);

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', m.product_id,
           'title', coalesce(nullif(btrim(coalesce(md.product_name,'')),''), '#'||m.product_id::text),
           'subtitle', public.count_label(v_copy,'one','many',coalesce(m.times_answered,0)),
           'meta', case when m.last_answered_at is null then ''
                        else public._c('admin_sup2.a_last')||': '||public.ist_fmt(m.last_answered_at,'day_mon_year') end,
           'chip', jsonb_build_object('show', true,
             'label', coalesce(nullif(m.last_answer,''), public._c('admin_sup2.a_none')),
             'bg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#D1FAE5'
                            when 'out of stock' then '#FEE2E2' else '#EFF6FF' end,
             'fg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#065F46'
                            when 'out of stock' then '#991B1B' else '#1E40AF' end,
             'border', case lower(coalesce(m.last_answer,'')) when 'available' then '#A7F3D0'
                            when 'out of stock' then '#FECACA' else '#BFDBFE' end),
           'actions', jsonb_build_array(
             jsonb_build_object('key','available','label',public._c('admin_sup2.a_set_available'),
               'tone','success','selected',(m.last_answer = v_avail),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_avail)),
             jsonb_build_object('key','oos','label',public._c('admin_sup2.a_set_oos'),
               'tone','danger','selected',(m.last_answer = v_oos),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_oos)),
             jsonb_build_object('key','dont','label',public._c('admin_sup2.a_set_dont'),
               'tone','info','selected',(m.last_answer = v_dont),
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', v_dont)),
             jsonb_build_object('key','none','label',public._c('admin_sup2.a_set_none'),
               'tone','muted','selected',false,
               'rpc','admin_supplier_availability_set',
               'args', jsonb_build_object('p_supplier_id', sp.id, 'p_product_id', m.product_id, 'p_state', ''))))
         order by m.last_answered_at desc nulls last), '[]'::jsonb)
    into v_items
    from supplier_item_memory m
    left join "MEDICINE" md on md.id = m.product_id
   where lower(btrim(m.supplier_name)) = lower(btrim(sp.supplier_name))
     and (v_zone is null
          or public.zone_available(m.product_id, v_zone));

  return jsonb_build_object('ok', true, 'zone_id', v_zone, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','shop','title',public._c('admin_sup2.a_shop'),'shop', v_shop,
      'supplier_name', coalesce(sp.supplier_name,'')),
    jsonb_build_object('kind','chips','key','zone','arg','p_zone_id','arg_type','int',
                       'title',public._c('admin_sup2.a_zone'),'chips',v_zones),
    jsonb_build_object('kind','list','title',public._c('admin_sup2.a_title'),
      'empty', public._c('admin_sup2.a_empty'), 'items', v_items)));
end $function$;

CREATE OR REPLACE FUNCTION public.supplier_account_tab_availability(p_zone_id integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  sp public.supplier_profiles%rowtype;
  v_zone smallint; v_zones jsonb; v_items jsonb; v_copy jsonb;
  v_bulk jsonb; v_forms jsonb; v_excl jsonb;
  v_avail text := 'Available'; v_oos text := 'Out of Stock';
  v_dont text := 'We don''t stock this product';
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_zone := coalesce(p_zone_id::smallint, sp.zone_id);
  v_copy := jsonb_build_object('one', public._sup850_t('a_times_one'),
                               'many', public._sup850_t('a_times_many'));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', z.id::text, 'value', z.id,
           'label', case z.id when 1 then '①' when 2 then '②' when 3 then '③'
                              when 4 then '④' when 5 then '⑤'
                              else '('||z.id::text||')' end || ' ' || z.name,
           'count', (select count(*) from public.supplier_item_memory m
                      join public.zone_available_products(z.id) cz
                        on cz.product_id = m.product_id
                     where lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))),
           'active', (z.id = v_zone))
         order by z.id), '[]'::jsonb)
    into v_zones from public.zones z;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(btrim(coalesce(md.product_name,'')),''), '#'||m.product_id::text),
           'subtitle', public.count_label(v_copy,'one','many',coalesce(m.times_answered,0)),
           'meta', case when m.last_answered_at is null then ''
                        else public._sup850_t('a_last')||': '||
                             public.ist_fmt(m.last_answered_at,'day_mon_year') end,
           'chip', jsonb_build_object('show', true,
             'label', coalesce(nullif(m.last_answer,''), public._sup850_t('a_none')),
             'bg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#D1FAE5'
                            when 'out of stock' then '#FEE2E2' else '#EFF6FF' end,
             'fg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#065F46'
                            when 'out of stock' then '#991B1B' else '#1E40AF' end,
             'border', case lower(coalesce(m.last_answer,'')) when 'available' then '#A7F3D0'
                            when 'out of stock' then '#FECACA' else '#BFDBFE' end),
           'actions', jsonb_build_array(
             jsonb_build_object('label',public._sup850_t('a_set_available'),'tone','success',
               'selected',(m.last_answer = v_avail),'kind','rpc',
               'rpc','supplier_account_availability_set',
               'args', jsonb_build_object('p_product_id', m.product_id, 'p_state', v_avail)),
             jsonb_build_object('label',public._sup850_t('a_set_oos'),'tone','danger',
               'selected',(m.last_answer = v_oos),'kind','rpc',
               'rpc','supplier_account_availability_set',
               'args', jsonb_build_object('p_product_id', m.product_id, 'p_state', v_oos)),
             jsonb_build_object('label',public._sup850_t('a_set_dont'),'tone','info',
               'selected',(m.last_answer = v_dont),'kind','rpc',
               'rpc','supplier_account_availability_set',
               'args', jsonb_build_object('p_product_id', m.product_id, 'p_state', v_dont))))
         order by m.last_answered_at desc nulls last), '[]'::jsonb)
    into v_items
    from public.supplier_item_memory m
    left join public."MEDICINE" md on md.id = m.product_id
   where lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and (v_zone is null
          or public.zone_available(m.product_id, v_zone));

  -- Bulk by company: one row per company this supplier has ever answered on,
  -- with both buttons already carrying that company's name.
  select coalesce(jsonb_agg(jsonb_build_object(
           'title', g.co,
           'subtitle', public.ui_textf('sup_acct.a_bulk_n',
                         jsonb_build_object('n', g.n::text)),
           'actions', jsonb_build_array(
             jsonb_build_object('label',public._sup850_t('a_bulk_oos'),'tone','danger','kind','rpc',
               'rpc','supplier_account_bulk_availability',
               'args', jsonb_build_object('p_company', g.co, 'p_state', v_oos)),
             jsonb_build_object('label',public._sup850_t('a_bulk_back'),'tone','success','kind','rpc',
               'rpc','supplier_account_bulk_availability',
               'args', jsonb_build_object('p_company', g.co, 'p_state', v_avail))))
         order by g.co), '[]'::jsonb)
    into v_bulk
    from (select btrim(coalesce(md.marketer_canonical, md.marketer,'')) co, count(*) n
            from public.supplier_item_memory m
            join public."MEDICINE" md on md.id = m.product_id
           where lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
             and btrim(coalesce(md.marketer_canonical, md.marketer,'')) <> ''
           group by 1) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', public.ui_textf('sup_acct.a_form_title',
                      jsonb_build_object('n', coalesce(jsonb_array_length(f.items),0)::text)),
           'subtitle', coalesce(public.ist_fmt(f.last_sent_at,'day_mon_time12'),''),
           'meta', case when f.expires_at is null then ''
                        else public._sup850_t('a_form_expires')||': '||
                             public.ist_fmt(f.expires_at,'day_mon_time12') end,
           'chip', public._sup850_chip('stock_update_status', coalesce(f.status,'')))
         order by f.created_at desc), '[]'::jsonb)
    into v_forms
    from public.stock_update_forms f
   where lower(btrim(coalesce(f.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and coalesce(f.status,'') <> 'expired'
     and (f.expires_at is null or f.expires_at > now());

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(btrim(coalesce(e.company,'')),''), '—'),
           'subtitle', coalesce(nullif(btrim(coalesce(e.category,'')),''),''),
           'meta', coalesce(public.ist_fmt(e.excluded_at,'day_mon_year'),''),
           'actions', jsonb_build_array(
             jsonb_build_object('label',public._sup850_t('a_excl_undo'),'tone','brand','kind','rpc',
               'rpc','supplier_account_exclusion_undo',
               'args', jsonb_build_object('p_company', coalesce(e.company,''),
                                          'p_category', coalesce(e.category,'')))))
         order by e.excluded_at desc), '[]'::jsonb)
    into v_excl
    from public.supplier_group_exclusion e
   where lower(btrim(coalesce(e.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')));

  return jsonb_build_object('ok', true, 'zone_id', v_zone, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','chips','key','zone','arg','p_zone_id',
      'title',public._sup850_t('a_zone'),'chips',v_zones),
    jsonb_build_object('kind','list','title',public._sup850_t('a_forms'),
      'empty', public._sup850_t('a_forms_empty'), 'items', v_forms),
    jsonb_build_object('kind','list','title',public._sup850_t('a_bulk_title'),
      'empty', public._sup850_t('a_bulk_empty'), 'items', v_bulk),
    jsonb_build_object('kind','list','title',public._sup850_t('a_title'),
      'empty', public._sup850_t('a_empty'), 'items', v_items),
    jsonb_build_object('kind','list','title',public._sup850_t('a_excl_title'),
      'empty', public._sup850_t('a_excl_empty'), 'items', v_excl)));
end $function$;
CREATE OR REPLACE FUNCTION public._search_cards(p_ids bigint[], p_pct numeric, p_zone smallint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', m.id,
      'name', m.product_name,
      'company', m.marketer,
      'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
      'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
      'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
      'pack_type_label', public.sf_pack_type_label(m.pack_type),
      'image', m.image_url_1,
      'category', m.therapeutic_class,
      'salt', m.salt_composition,
      'has_offer', coalesce(m.has_scheme, false),
      'offer_chip', case when coalesce(m.has_scheme, false)
                         then public.uic('catalogue.scheme_chip','Scheme available') else '' end,
      'is_new', (m.created_at is not null
                 and m.created_at >= now() - make_interval(days =>
                       coalesce((select new_days from public.catalogue_extras_config where id = 1), 30))),
      'new_badge', case when (m.created_at is not null
                 and m.created_at >= now() - make_interval(days =>
                       coalesce((select new_days from public.catalogue_extras_config where id = 1), 30)))
                   then public.uic('catalogue.new_badge','New') else '' end,
      'rx', public.rx_badge(m.rx_required),
      -- CMD #2023 — ONE truth. The card button is storefront_cta over
      -- storefront_effective_count, which is public.zone_available(). The old
      -- second opinion (a direct catalogue_zone_avail probe that overwrote the
      -- verdict with "Not in your zone") is what made one card say Available
      -- and Not in your zone at the same time.
      'availability', public.storefront_cta(
          public.storefront_effective_count(m.id,
            coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
          true),
      'pricing', public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, p_pct, m.id),
      'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                   then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
      'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t')
    ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid;
$function$;

CREATE OR REPLACE FUNCTION public.wishlist_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

CREATE OR REPLACE FUNCTION public.catalogue_cache_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  u record; v_code text; v_t0 timestamptz := clock_timestamp(); v_rows bigint := 0;
  v_where text; v_join text;
begin
  select * into u from public.catalogue_refresh_unit
   where state = 'pending' order by ord limit 1 for update skip locked;

  if u.ord is null then
    update public.catalogue_refresh_state
       set cycle_ended = coalesce(cycle_ended, now()),
           last_note   = 'idle — every unit done'
     where id = 1;
    return jsonb_build_object('ok', true, 'idle', true);
  end if;

  -- CHANGE #790 — the typeahead cache rides the same bounded tick. Its work
  -- lives in search_suggest_unit() so this dispatcher stays a dispatcher.
  if u.kind like 'suggest%' then
    v_rows := public.search_suggest_unit(u.kind, coalesce(u.arg,''), coalesce(u.arg2,''));

  elsif u.kind = 'zone_scan' then
    select code into v_code from public.zones where id = u.zone_id;
    if v_code is null then
      update public.catalogue_refresh_unit set state='done', ran_at=now(),
             last_error='unknown zone' where ord = u.ord;
      return jsonb_build_object('ok', true, 'skipped', 'unknown_zone');
    end if;
    -- CMD #2023 — the zone store is SELF-MAINTAINING. Every write that can
    -- change a pack's zone standby lands on the "MEDICINE" zone arrays, and
    -- zzz_zone_avail_sync_trg updates catalogue_zone_avail in the same
    -- statement. A periodic rescan can only reintroduce the drift this change
    -- removed (the snapshot the storefront was reading was last swapped on
    -- 2 Sep), so the unit stays in the cycle as a no-op instead of rebuilding.
    v_rows := 0;

  elsif u.kind = 'zone_swap' then
    v_rows := 0;

  elsif u.kind = 'facet' then
    -- zone 0 is the whole catalogue; a real zone joins the materialised list.
    if u.zone_id = 0 then
      v_join := '';
    else
      v_join := format('join public.catalogue_zone_avail za on za.product_id = m.id and za.zone_id = %L::smallint', u.zone_id);
    end if;
    v_where := 'true';

    -- 'meta' writes two facets, so it clears two. Re-running any unit is a
    -- clean rewrite of exactly what it owns and nothing else.
    delete from public.catalogue_facet_count
     where zone_id = u.zone_id
       and facet = any (case when u.arg = 'meta' then array['meta','pack_type'] else array[u.arg] end);

    if u.arg = 'therapeutic' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'therapeutic', %1$L::smallint, '', m.therapeutic_class, m.therapeutic_class,
               upper(left(m.therapeutic_class,1)), count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.therapeutic_class),'') is not null
         group by 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'chemical' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'chemical', %1$L::smallint, m.therapeutic_class, m.chemical_class,
               m.chemical_class, upper(left(m.chemical_class,1)), count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.therapeutic_class),'') is not null
           and nullif(btrim(m.chemical_class),'') is not null
         group by 3, 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'action' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'action', %1$L::smallint,
               public.catalogue_parent_key(m.therapeutic_class, m.chemical_class),
               m.action_class, m.action_class,
               upper(left(m.action_class,1)), count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.therapeutic_class),'') is not null
           and nullif(btrim(m.chemical_class),'') is not null
           and nullif(btrim(m.action_class),'') is not null
         group by 3, 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'company' then
      -- The company's PRINTED name is medicine_company.display (#430's registry),
      -- never the raw marketer text and never a name this migration invents.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'company', %1$L::smallint, '', m.marketer_canonical,
               coalesce(mc.display, m.marketer_canonical),
               case when upper(left(coalesce(mc.display, m.marketer_canonical),1)) between 'A' and 'Z'
                    then upper(left(coalesce(mc.display, m.marketer_canonical),1)) else '#' end,
               count(*)
          from public."MEDICINE" m %2$s
          left join public.medicine_company mc on mc.canon = m.marketer_canonical
         where %3$s and nullif(btrim(m.marketer_canonical),'') is not null
         group by 4, 5, 6
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'salt' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'salt', %1$L::smallint, '', m.salt_composition, m.salt_composition,
               case when upper(left(m.salt_composition,1)) between 'A' and 'Z'
                    then upper(left(m.salt_composition,1)) else '#' end,
               count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.salt_composition),'') is not null
         group by 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'condition' then
      -- CMD #1953 — the source is MEDICINE.condition, the text[] derived from
      -- MEDICINE.uses. No link table: one lateral unnest over the column the
      -- GIN index is built on. The count is still DISTINCT products, because a
      -- product sits under every condition it treats and a door that says
      -- 12,410 when the list holds 9,200 is a door that lies.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'condition', %1$L::smallint, '', t.cond, t.cond,
               public._cat_letter(t.cond), count(distinct t.id)
          from (select m.id, x.cond
                  from public."MEDICINE" m %2$s
                  cross join lateral unnest(m.condition) as x(cond)
                 where %3$s and m.condition is not null
                   and cardinality(m.condition) > 0) t
         where nullif(btrim(t.cond),'') is not null
         group by t.cond
        having count(distinct t.id) > 0
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'meta' then
      -- The numbers the Catalogue TAB BAR prints, and the pack-type filter's
      -- own vocabulary. Both were live scans in the first draft: rendering the
      -- tab bar cost `select distinct pack_type from "MEDICINE"` — 10.2 s on
      -- this instance — which is the exact thing the spec forbids. They are
      -- rows now, so the landing screen is six point lookups.
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'meta', %1$L::smallint, '', 'total', 'total', '', count(*)
          from public."MEDICINE" m %2$s where %3$s
        union all
        select 'meta', %1$L::smallint, '', 'companies', 'companies', '',
               count(*) from public.catalogue_facet_count
                where facet = 'company' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'salts', 'salts', '',
               count(*) from public.catalogue_facet_count
                where facet = 'salt' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'conditions', 'conditions', '',
               count(*) from public.catalogue_facet_count
                where facet = 'condition' and zone_id = %1$L::smallint
        union all
        select 'meta', %1$L::smallint, '', 'condition_products', 'condition_products', '',
               count(distinct m.id)
          from public."MEDICINE" m %2$s
         where %3$s and m.condition is not null and cardinality(m.condition) > 0
      $q$, u.zone_id, v_join, v_where);
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'pack_type', %1$L::smallint, '', m.pack_type, m.pack_type, '', count(*)
          from public."MEDICINE" m %2$s
         where %3$s and nullif(btrim(m.pack_type),'') is not null
         group by 4
      $q$, u.zone_id, v_join, v_where);
    elsif u.arg = 'tab' then
      execute format($q$
        insert into public.catalogue_facet_count(facet, zone_id, parent_key, facet_key, label, letter, n)
        select 'tab', %1$L::smallint, '', t.k, t.k, '', t.c from (
          select 'schemes' as k, count(*) filter (where coalesce(m.has_scheme,false)) as c
            from public."MEDICINE" m %2$s where %3$s
          union all
          select 'cold_chain', count(*) filter (where coalesce(m.cold_chain,false))
            from public."MEDICINE" m %2$s where %3$s
        ) t
      $q$, u.zone_id, v_join, v_where);
    end if;
    get diagnostics v_rows = row_count;
  end if;

  update public.catalogue_refresh_unit
     set state = 'done', ran_at = now(), rows_seen = v_rows,
         ms = (extract(epoch from clock_timestamp() - v_t0) * 1000)::int,
         last_error = null
   where ord = u.ord;

  update public.catalogue_refresh_state
     set last_note = u.kind || ' ' || coalesce(nullif(u.arg,''), 'zone ' || u.zone_id)
                     || ' → ' || v_rows || ' rows'
   where id = 1;

  return jsonb_build_object('ok', true, 'ord', u.ord, 'kind', u.kind,
    'zone', u.zone_id, 'arg', u.arg, 'rows', v_rows,
    'left', (select count(*) from public.catalogue_refresh_unit where state = 'pending'));
exception when others then
  update public.catalogue_refresh_unit
     set state = 'done', ran_at = now(), last_error = left(sqlerrm, 400)
   where ord = u.ord;
  return jsonb_build_object('ok', false, 'ord', u.ord, 'error', left(sqlerrm, 400));
end $function$;
CREATE OR REPLACE FUNCTION public.medicine_rebuild_availability_trigger()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_expr text; v_cols text; v_body text; v_n int;
begin
  select string_agg(format(
           'public.medicine_zone_effective(NEW.%I, NEW.%I, NEW.%I, NEW.%I)',
           'z_'||z.code||'_sup', 'z_'||z.code||'_av',
           'z_'||z.code||'_oos', 'z_'||z.code||'_nostock'), E'\n         || '),
         string_agg(format('%I, %I, %I, %I',
           'z_'||z.code||'_sup', 'z_'||z.code||'_av',
           'z_'||z.code||'_oos', 'z_'||z.code||'_nostock'), ', '),
         count(*)
    into v_expr, v_cols, v_n
    from (select code from zones where is_active order by code) z;

  if v_expr is null then
    return jsonb_build_object('ok', false, 'reason', 'no active zones');
  end if;

  v_body := format($f$
create or replace function public.medicine_set_buyable()
returns trigger
language plpgsql
set search_path to 'public'
as $gen$
declare v_n int;
begin
  -- GENERATED by medicine_rebuild_availability_trigger() (CHANGE #640).
  -- One number, three columns, written together. Do not hand-edit: rerun the
  -- generator instead, or the zones and this body drift apart.
  select count(distinct s)::int into v_n
    from unnest(%s) s;
  NEW.supplier_count := v_n;
  NEW.buyable        := (v_n > 0);
  NEW.supplier_label := public._supplier_label(v_n);
  return NEW;
end;
$gen$;
  $f$, v_expr);

  execute v_body;

  -- Fires only when a zone array actually changed (or on INSERT), so the 34
  -- other columns of a product can be edited without paying for a recount, and
  -- it is named to sort LAST so it sees the arrays the marketer rebuild wrote.
  execute 'drop trigger if exists medicine_set_buyable_trg on public."MEDICINE"';
  execute 'drop trigger if exists zz_medicine_set_buyable_trg on public."MEDICINE"';
  execute format(
    'create trigger zz_medicine_set_buyable_trg before insert or update of %s '
    'on public."MEDICINE" for each row execute function public.medicine_set_buyable()',
    v_cols);

  -- CMD #2023 — the zone-availability store rides the SAME column list, so a
  -- zone added or renamed re-arms both triggers in one call and the store can
  -- never drift from the arrays it is derived from.
  execute 'drop trigger if exists zzz_zone_avail_sync_trg on public."MEDICINE"';
  execute format(
    'create trigger zzz_zone_avail_sync_trg after insert or delete or update of %s '
    'on public."MEDICINE" for each row execute function public._zone_avail_sync_trg()',
    v_cols);
  perform public.zone_avail_backfill(null);

  return jsonb_build_object('ok', true, 'zones', v_n, 'columns', v_cols);
end;
$function$;

-- ── 6. Notify-when-available asks the same function ─────────────────────────
create or replace function public.stock_notify_request(p_product_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'login_required'); end if;
  if not exists (select 1 from "MEDICINE" where id = p_product_id) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  -- CMD #2023 — the same one function the card button asked. A pack this zone
  -- can already send has nothing to wait for, so we never open a subscription
  -- that would fire immediately.
  if public.zone_available(p_product_id, public._viewer_zone_or_null()) then
    return jsonb_build_object('ok', true, 'subscribed', false,
      'toast', coalesce((select value from storefront_ui_label where key='notify_already_toast'),
                        'This pack is available now'));
  end if;
  insert into stock_notify_requests(product_id, user_id) values (p_product_id, auth.uid())
  on conflict (product_id, user_id) do update set created_at = now(), available_at = null, seen_at = null;
  return jsonb_build_object('ok', true, 'subscribed', true,
    'toast', coalesce((select value from storefront_ui_label where key='notify_done_toast'),
                      'We will notify you once stock is available'));
end $function$;

-- ── 7. The contract: one truth, checked mechanically ────────────────────────
-- The surfaces are DATA, so a new card / add / order RPC is an INSERT here,
-- never a deploy.
create table if not exists public.zone_availability_contract_fn (
  fn        text primary key,
  kind      text not null default 'card',
  note      text,
  added_at  timestamptz not null default now()
);

insert into public.zone_availability_contract_fn(fn, kind, note) values
  ('_cat_cards',                'card',  'catalogue grid cards'),
  ('_sf_cards',                 'card',  'storefront cards'),
  ('_search_cards',             'card',  'search result cards'),
  ('_cat_page_ids',             'card',  'catalogue paging / zone scope'),
  ('_cat_products_rail',        'card',  'catalogue rails'),
  ('_product_detail_core',      'card',  'PDP'),
  ('same_composition_options',  'card',  'Other packs'),
  ('product_companions',        'card',  'PDP companions'),
  ('product_compare',           'card',  'compare'),
  ('storefront_page',           'card',  'storefront page'),
  ('storefront_product',        'card',  'storefront product'),
  ('storefront_availability',   'card',  'availability probe'),
  ('medicine_page_v2',          'card',  'legacy list page'),
  ('search_medicines_priority', 'card',  'search'),
  ('wishlist_get',              'card',  'wishlist cards'),
  ('cart_companions',           'card',  'cart rail cards'),
  ('cart_rail_block',           'card',  'cart rail block'),
  ('substitute_candidates',     'card',  'substitutes'),
  ('cart_set_item',             'add',   'cart add'),
  ('cart_availability',         'add',   'cart validation'),
  ('cart_strip_unavailable',    'add',   'cart strip'),
  ('_cart_unavailable_lines',   'add',   'cart unavailable lines'),
  ('order_edit_apply',          'order', 'order guard'),
  ('reorder_confirm_pending',   'order', 'reorder confirm'),
  ('reorder_diff',              'order', 'reorder diff'),
  ('reorder_lowstock_check',    'order', 'reorder nudge'),
  ('stock_notify_request',      'card',  'notify-when-available')
on conflict (fn) do update set kind = excluded.kind, note = excluded.note;

-- The store may only be read by the one function and its own maintenance.
create table if not exists public.zone_availability_store_allow (
  fn   text primary key,
  note text
);
insert into public.zone_availability_store_allow(fn, note) values
  ('zone_available',          'THE definition'),
  ('zone_available_products', 'the set-shaped read of the same store'),
  ('_zone_avail_sync',        'trigger body — one product, every zone'),
  ('_zone_avail_sync_trg',    'the trigger'),
  ('zone_avail_backfill',     'set-based backfill / self-heal'),
  ('zone_availability_contract','the checker itself — it names the table in its own regex')
on conflict (fn) do nothing;

create or replace function public.zone_availability_contract(p_mode text default 'summary')
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with f as (
    select p.proname::text as proname, p.prosrc
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
  ),
  edge as (
    select a.proname as caller, b.proname as callee
      from f a join f b
        on a.proname <> b.proname
       and a.prosrc ~ ('(^|[^a-zA-Z0-9_])' || b.proname || '\s*\(')
     where b.proname in ('zone_available','zone_available_products')
        or exists (select 1 from public.zone_availability_contract_fn c where c.fn = b.proname)
        or b.proname in (select proname from f)
  ),
  reach as (
    select distinct e.caller
      from edge e
     where e.callee in ('zone_available','zone_available_products')
  ),
  reach2 as (
    select distinct e.caller
      from edge e join reach r on e.callee = r.caller
  ),
  reach3 as (
    select distinct e.caller
      from edge e join reach2 r on e.callee = r.caller
  ),
  reach4 as (
    select distinct e.caller
      from edge e join reach3 r on e.callee = r.caller
  ),
  reached as (
    select caller from reach
    union select caller from reach2
    union select caller from reach3
    union select caller from reach4
  ),
  missing as (
    select c.fn, c.kind
      from public.zone_availability_contract_fn c
     where exists (select 1 from f where f.proname = c.fn)
       and not exists (select 1 from reached r where r.caller = c.fn)
  ),
  offenders as (
    select f.proname
      from f
     where f.prosrc ~ 'catalogue_zone_avail'
       and not exists (select 1 from public.zone_availability_store_allow a where a.fn = f.proname)
  ),
  absent as (
    select c.fn from public.zone_availability_contract_fn c
     where not exists (select 1 from f where f.proname = c.fn)
  )
  select jsonb_build_object(
    'ok', (not exists (select 1 from missing)) and (not exists (select 1 from offenders)),
    'checked', (select count(*) from public.zone_availability_contract_fn),
    'missing', coalesce((select jsonb_agg(jsonb_build_object('fn', fn, 'kind', kind) order by fn) from missing), '[]'::jsonb),
    'direct_store_readers', coalesce((select jsonb_agg(proname order by proname) from offenders), '[]'::jsonb),
    'not_present', coalesce((select jsonb_agg(fn order by fn) from absent), '[]'::jsonb));
$$;

revoke all on function public.zone_availability_contract(text) from public;
grant execute on function public.zone_availability_contract(text) to service_role;

insert into public.rg_behavior_tests(name, body, enabled, note) values (
  'c2023_one_zone_availability_truth',
  $b$
do $body$
declare v jsonb; v_missing text; v_direct text;
begin
  v := public.zone_availability_contract('summary');
  select string_agg(r->>'fn' || ' (' || (r->>'kind') || ')', ', ' order by r->>'fn')
    into v_missing from jsonb_array_elements(v->'missing') r;
  select string_agg(r #>> '{}', ', ' order by r #>> '{}')
    into v_direct from jsonb_array_elements(v->'direct_store_readers') r;
  if v_missing is not null then
    raise exception 'RG_FAIL: card / add / order RPC(s) do not reach public.zone_available(): %. Every surface asks the one function (CMD #2023) — route it through storefront_effective_count()/zone_available()/zone_available_products(), or drop the row from zone_availability_contract_fn if the surface is gone.', v_missing;
  end if;
  if v_direct is not null then
    raise exception 'RG_FAIL: function(s) read catalogue_zone_avail directly: %. The store has exactly five readers (zone_availability_store_allow); everything else asks public.zone_available() (CMD #2023).', v_direct;
  end if;
  raise exception 'RG_ROLLBACK';
end $body$;
  $b$,
  true,
  'CMD #2023 — one zone-availability truth: every card / add / order RPC reaches public.zone_available(), and nothing but the store maintainers reads catalogue_zone_avail.')
on conflict (name) do update set body = excluded.body, enabled = true, note = excluded.note;

-- The contract walk, done cheaply: a reverse BFS from the one function. Each
-- round tests every public function ONCE against one alternation regex of the
-- names found in the round before, so the whole check is a handful of passes
-- over pg_proc instead of a 4,000 x 4,000 cross join.
create or replace function public.zone_availability_contract(p_mode text default 'summary')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  v_seen     text[] := array['zone_available','zone_available_products'];
  v_frontier text[] := array['zone_available','zone_available_products'];
  v_next     text[];
  v_rx       text;
  v_round    int := 0;
  v_missing  jsonb;
  v_direct   jsonb;
  v_absent   jsonb;
begin
  while coalesce(array_length(v_frontier, 1), 0) > 0 and v_round < 12 loop
    v_round := v_round + 1;
    v_rx := '(^|[^a-zA-Z0-9_])(' ||
            (select string_agg(x, '|') from unnest(v_frontier) x) || ')[[:space:]]*\(';
    select coalesce(array_agg(distinct p.proname::text), '{}'::text[])
      into v_next
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and not (p.proname::text = any (v_seen))
       and p.prosrc ~ v_rx;
    v_seen     := v_seen || v_next;
    v_frontier := v_next;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('fn', c.fn, 'kind', c.kind) order by c.fn), '[]'::jsonb)
    into v_missing
    from public.zone_availability_contract_fn c
   where exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname::text = c.fn)
     and not (c.fn = any (v_seen));

  select coalesce(jsonb_agg(distinct p.proname::text), '[]'::jsonb)
    into v_direct
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosrc ~ 'catalogue_zone_avail'
     and not exists (select 1 from public.zone_availability_store_allow a
                      where a.fn = p.proname::text);

  select coalesce(jsonb_agg(c.fn order by c.fn), '[]'::jsonb)
    into v_absent
    from public.zone_availability_contract_fn c
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname::text = c.fn);

  return jsonb_build_object(
    'ok', (jsonb_array_length(v_missing) = 0 and jsonb_array_length(v_direct) = 0),
    'checked', (select count(*) from public.zone_availability_contract_fn),
    'rounds', v_round,
    'reaching', coalesce(array_length(v_seen, 1), 0),
    'missing', v_missing,
    'direct_store_readers', v_direct,
    'not_present', v_absent);
end $$;

revoke all on function public.zone_availability_contract(text) from public;
grant execute on function public.zone_availability_contract(text) to service_role;

-- ── 8. Arm the triggers and backfill the store once ─────────────────────────
-- medicine_rebuild_availability_trigger() regenerates BOTH triggers from the
-- live zone list and then backfills every zone, so this migration is the last
-- manual sync there will ever be.
select public.medicine_rebuild_availability_trigger();

-- Prove zero diff: the store is already exact, so a second pass must move
-- nothing. A non-zero count here means the trigger did not fire.
do $verify$
declare v jsonb; r jsonb; v_bad text;
begin
  v := public.zone_avail_backfill(null);
  for r in select * from jsonb_array_elements(v->'zones') loop
    if (r->>'inserted')::bigint <> 0 or (r->>'deleted')::bigint <> 0 then
      v_bad := coalesce(v_bad||', ','') || (r->>'zone') ||
               ' (+'||(r->>'inserted')||'/-'||(r->>'deleted')||')';
    end if;
  end loop;
  if v_bad is not null then
    raise exception 'CMD #2023: zone availability store still drifts after backfill: %', v_bad;
  end if;
  raise notice 'CMD #2023 zone availability store: zero diff — %', v;
end $verify$;
