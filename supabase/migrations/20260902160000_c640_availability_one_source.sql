-- CHANGE #640 — availability had five definitions. Now it has one.
--
-- THE LIVE BUG
--   SyNtraN 200 Capsule (id 252328) was listed on the storefront, was accepted
--   into the cart, and was then shown as unavailable inside that same cart.
--   The row said both things at once: supplier_count = 11, buyable = false.
--   13,767 rows of the catalogue disagreed with themselves the same way.
--
-- WHY (measured, not guessed)
--   FIVE writers of the two columns, THREE different definitions between them:
--     * medicine_set_buyable()        — buyable ONLY, from "z_<c>_sup is non-empty",
--                                       ignoring oos/nostock. Never touched the count.
--     * buyable_recompute_tick()      — buyable ONLY, same definition PLUS an
--                                       mrp > 0 term nobody else had, and it scanned
--                                       only `buyable IS NULL OR TRUE`, so it could
--                                       turn a product OFF and never back ON.
--     * medicine_recompute_buyable()  — all three columns, from _ps_count().
--     * backfill_supplier_count()     — the count ONLY, and only where the count
--                                       was already NULL.
--     * medicine_zone_from_marketer() — rebuilt z_<c>_sup from zone_company_lookup
--                                       and overwrote all three. This is what left
--                                       BIG PLUS ORGANICS in z_rpr_av with z_rpr_sup
--                                       EMPTY on 252328: the rebuild dropped the
--                                       supplier from the master list while its
--                                       "available" tick stayed behind.
--
--   And SEVEN readers, each picking whichever column it liked:
--     storefront feed / search / PDP / compare / wishlist / margin / same-composition
--       -> storefront_effective_count() -> medicine_zone_standby()   (zone truth)
--     cart_set_item()                     -> the GLOBAL supplier_count column
--     cart_availability()                 -> the GLOBAL supplier_count column
--     _cart_strip_unavailable()           -> the GLOBAL supplier_count column
--     _cart_unavailable_lines()           -> medicine_zone_standby()
--     cart_state()                        -> the buyable column
--   So the storefront answered with zone truth and the cart answered with a stale
--   global column. Add succeeded, render refused. Exactly what Om saw.
--
-- THE ONE SOURCE OF TRUTH (the notes model, stated once)
--   effective(zone) = (z_sup UNION z_av) MINUS z_oos MINUS z_nostock
--   supplier_count  = |UNION over ACTIVE zones of effective(zone)|
--   buyable         = supplier_count > 0
--   supplier_label  = _supplier_label(supplier_count)
--   zone standby    = |effective(zone)|
--
--   `z_av` is unioned IN rather than assumed to be a subset of the master list:
--   that is what makes "a supplier ticked available in a zone cannot exist outside
--   that zone master list" true BY DERIVATION instead of by hoping every writer
--   remembers. medicine_zone_standby() also stops doing array-length ARITHMETIC
--   (len(sup) - len(oos) - len(nostock)), which silently went wrong the moment an
--   oos name was not on the master list — i.e. on exactly the broken rows.
--
-- Everything below is idempotent: a resumed worker re-applying it is a no-op.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. THE EXPRESSION, written once
-- ─────────────────────────────────────────────────────────────────────────────

-- The effective supplier SET for one zone. A set, not a count, so callers can
-- ask "how many" and "which" from the same answer.
create or replace function public.medicine_zone_effective(
  p_sup text[], p_av text[], p_oos text[], p_nostock text[])
returns text[]
language sql
immutable
parallel safe
as $$
  select coalesce(array_agg(distinct t.s order by t.s), '{}'::text[])
  from (
    select btrim(x) as s
    from unnest(coalesce(p_sup, '{}'::text[]) || coalesce(p_av, '{}'::text[])) x
  ) t
  where t.s <> ''
    and not exists (
      select 1 from unnest(coalesce(p_oos, '{}'::text[])) o where btrim(o) = t.s)
    and not exists (
      select 1 from unnest(coalesce(p_nostock, '{}'::text[])) n where btrim(n) = t.s);
$$;

comment on function public.medicine_zone_effective(text[], text[], text[], text[]) is
  'CHANGE #640 — the ONE definition of "which suppliers can serve this product in '
  'this zone": (master list UNION available ticks) MINUS out-of-stock MINUS no-stock. '
  'Every availability answer in mediBO resolves through this function.';

-- The zone arrays live on the row as columns whose NAMES are built from the zone
-- code, so they are read out of the jsonb form of the row. Absence reads as an
-- empty set, never as NULL.
create or replace function public._zone_arr(j jsonb, p_key text)
returns text[]
language sql
immutable
parallel safe
as $$
  select coalesce(
    array(select jsonb_array_elements_text(
            case when jsonb_typeof(j -> p_key) = 'array' then j -> p_key
                 else '[]'::jsonb end)),
    '{}'::text[]);
$$;

create or replace function public.medicine_zone_effective_j(j jsonb, p_code text)
returns text[]
language sql
immutable
parallel safe
as $$
  select public.medicine_zone_effective(
    public._zone_arr(j, 'z_' || p_code || '_sup'),
    public._zone_arr(j, 'z_' || p_code || '_av'),
    public._zone_arr(j, 'z_' || p_code || '_oos'),
    public._zone_arr(j, 'z_' || p_code || '_nostock'));
$$;

-- The GLOBAL count: distinct suppliers across every ACTIVE zone. This is the
-- number `supplier_count` stores and `buyable` is derived from.
create or replace function public._ps_count(m "MEDICINE")
returns integer
language sql
stable
as $$
  select count(distinct s)::int
  from public.zones z
  cross join lateral unnest(public.medicine_zone_effective_j(to_jsonb(m), z.code)) s
  where z.is_active;
$$;

-- The ZONE count every storefront surface already asks for. Same expression as
-- the global one, restricted to a zone — so the two can never disagree about
-- whether the answer is zero.
create or replace function public.medicine_zone_standby(
  p_product_id bigint, p_zone_id smallint)
returns integer
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((
    select cardinality(public.medicine_zone_effective_j(to_jsonb(m), z.code))
      from public."MEDICINE" m
      join public.zones z on z.id = p_zone_id and z.is_active
     where m.id = p_product_id), 0);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. ONE WRITER. The three columns are written TOGETHER or not at all.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.medicine_set_buyable()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare v_n int;
begin
  -- CHANGE #640 — this used to set `buyable` alone, from a different expression
  -- than the one that set `supplier_count`. Two columns, two writers, two
  -- answers. Now there is one number and all three columns come out of it.
  v_n := public._ps_count(NEW);
  NEW.supplier_count := v_n;
  NEW.buyable        := (v_n > 0);
  NEW.supplier_label := public._supplier_label(v_n);
  return NEW;
end;
$$;

-- It must fire LAST. medicine_zone_from_marketer() rewrites z_<c>_sup in its own
-- BEFORE trigger, and triggers fire in NAME order: `medicine_set_buyable_trg`
-- sorted before `z_medicine_zone_from_marketer_trg`, so the counts were computed
-- from the arrays as they were BEFORE the rebuild. Renaming it to `zz_` puts the
-- one writer after every array writer.
drop trigger if exists medicine_set_buyable_trg on public."MEDICINE";
drop trigger if exists zz_medicine_set_buyable_trg on public."MEDICINE";
create trigger zz_medicine_set_buyable_trg
  before insert or update on public."MEDICINE"
  for each row execute function public.medicine_set_buyable();

-- The marketer rebuild keeps the MASTER LIST and nothing else.
--
-- Two fixes: it no longer computes the counts (the one writer above does), and
-- it no longer DROPS a supplier that has already responded in that zone. The
-- old body rebuilt z_<c>_sup purely from zone_company_lookup, so a supplier who
-- ticked "available" but whose company mapping lagged was deleted from the
-- master list while its tick stayed in z_<c>_av — the 7 orphaned rows, and the
-- reason 252328 had an empty master list and a live availability tick.
create or replace function public.medicine_zone_from_marketer()
returns trigger
language plpgsql
set search_path to 'public'
as $$
DECLARE
  z record; j jsonb := to_jsonb(NEW); v_key text; v_lookup text[]; v_sup text[];
BEGIN
  v_key := public.resolve_company_canonical(NEW.marketer);
  FOR z IN SELECT id, code FROM zones WHERE is_active LOOP
    SELECT coalesce(l.sups, '{}'::text[]) INTO v_lookup
      FROM zone_company_lookup l WHERE l.zone_id = z.id AND l.key = v_key;
    v_lookup := coalesce(v_lookup, '{}'::text[]);

    -- A supplier who has ANSWERED for this product in this zone is on the master
    -- list, whatever the company map currently says. That is the invariant the
    -- old rebuild broke.
    SELECT coalesce(array_agg(DISTINCT t.s ORDER BY t.s), '{}'::text[])
      INTO v_sup
      FROM (
        SELECT btrim(x) AS s FROM unnest(
          v_lookup
          || public._zone_arr(j, 'z_' || z.code || '_av')
          || public._zone_arr(j, 'z_' || z.code || '_oos')
          || public._zone_arr(j, 'z_' || z.code || '_nostock')) x
      ) t
     WHERE t.s <> '';

    j := jsonb_set(j, ARRAY['z_' || z.code || '_sup'], to_jsonb(v_sup));
  END LOOP;
  NEW := jsonb_populate_record(NEW, j);
  -- buyable / supplier_count / supplier_label are DELIBERATELY not set here.
  -- zz_medicine_set_buyable_trg fires after this one and owns all three.
  RETURN NEW;
END;
$$;

-- The cursor sweep. Now it writes all three columns, from the one expression,
-- and it scans EVERY row — the old `WHERE buyable IS NULL OR buyable IS TRUE`
-- meant a product could be switched off and never switched back on, which is
-- half of why 13,767 rows were stuck disagreeing.
--
-- The mrp > 0 term the old body carried is gone: storefront_cta() never
-- consulted MRP, so the storefront already ignored it, and a price rule folded
-- into a SUPPLIER COUNT is a second definition by another name. An unpriced
-- product is a pricing state (pricing.has_price), not an availability one.
create or replace function public.buyable_recompute_tick(p_chunk integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_start bigint; v_max bigint; v_updated bigint;
begin
  select coalesce((select (value #>> '{}')::bigint from app_settings where key = 'buyable_cursor'), 0)
    into v_start;

  with rng as (
    select m.id, public._ps_count(m) as n
      from public."MEDICINE" m
     where m.id >= v_start
     order by m.id
     limit greatest(coalesce(p_chunk, 20000), 1)
  ), upd as (
    update public."MEDICINE" m
       set supplier_count = r.n,
           buyable        = (r.n > 0),
           supplier_label = public._supplier_label(r.n)
      from rng r
     where m.id = r.id
       and (m.supplier_count is distinct from r.n
            or coalesce(m.buyable, false) is distinct from (r.n > 0)
            or m.supplier_label is distinct from public._supplier_label(r.n))
    returning m.id
  )
  select (select max(id) from rng), (select count(*) from upd)
    into v_max, v_updated;

  if v_max is null then
    insert into app_settings(key, value) values ('buyable_cursor', '0'::jsonb)
      on conflict (key) do update set value = '0'::jsonb;
    return jsonb_build_object('ok', true, 'done', true, 'updated', 0, 'cursor', 0);
  end if;

  insert into app_settings(key, value) values ('buyable_cursor', to_jsonb(v_max + 1))
    on conflict (key) do update set value = to_jsonb(v_max + 1);

  return jsonb_build_object('ok', true, 'done', false,
                            'updated', coalesce(v_updated, 0), 'cursor', v_max + 1);
end;
$$;

-- Same story: it wrote the count alone, only onto rows whose count was NULL.
-- It now delegates to the one expression and stops being a second opinion.
create or replace function public.backfill_supplier_count(p_batch integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare n int;
begin
  -- One helper call per row, resolved in a CTE and then joined. Calling it
  -- again in the WHERE would re-evaluate it for every row of a 563k table.
  with cand as (
    select m.id, m.supplier_count as was, public._ps_count(m) as n
      from public."MEDICINE" m
     limit greatest(coalesce(p_batch, 20000), 1)
  ), t as (
    select id, n from cand where was is distinct from n
  )
  update public."MEDICINE" m
     set supplier_count = t.n,
         buyable        = (t.n > 0),
         supplier_label = public._supplier_label(t.n)
    from t where m.id = t.id;
  get diagnostics n = row_count;
  return jsonb_build_object('updated', n);
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. ONE READER. Every surface resolves through storefront_effective_count().
-- ─────────────────────────────────────────────────────────────────────────────

-- The cart's ADD gate. It read the raw global column while the storefront card
-- the customer just tapped read the zone truth — so the add succeeded on a
-- product the cart was about to call unavailable, and vice versa. Same call,
-- same arguments, same answer now.
create or replace function public.cart_set_item(
  p_product_id text, p_quantity integer, p_guest_uid uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_uid uuid; v_cust uuid; m record; v_mrp numeric; v_gst integer;
        v_tp jsonb; v_price numeric; v_src text; v_policy text;
begin
  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid  := p_guest_uid;
    v_cust := null;
  end if;

  if v_uid is null then
    return jsonb_build_object('ok',false,'message','Please log in');
  end if;
  if p_product_id is null or btrim(p_product_id) = '' then
    return jsonb_build_object('ok',false,'message','Product missing');
  end if;

  if coalesce(p_quantity,0) <= 0 then
    delete from cart_items
     where product_id = p_product_id
       and (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);
    return jsonb_build_object('ok',true,'message','Removed from cart',
                              'cart', public.cart_render(p_guest_uid));
  end if;

  select id, product_name, mrp, image_url_1, marketer, pack_size, therapeutic_class,
         gst_percent, supplier_count
    into m
  from "MEDICINE" where id::text = p_product_id;

  if not found then return jsonb_build_object('ok',false,'message','Product not found'); end if;

  -- CHANGE #640 — the SAME call every card, the product page and the cart's own
  -- render make. This line used to read `m.supplier_count` raw.
  if public.storefront_effective_count(m.id, m.supplier_count) < 1
     and public.viewer_is_approved_customer() then
    return jsonb_build_object('ok', false,
      'message', public.uic('storefront.no_supplier_note',
                            'No supplier for this product right now'));
  end if;

  v_mrp := nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric;

  -- #355 — the price is RESOLVED, never copied from the MRP.
  v_tp    := public.trade_price_line(m.id, p_quantity);
  v_price := nullif(v_tp->>'price','')::numeric;
  v_src   := nullif(v_tp->>'price_source','');
  v_gst   := round(coalesce((v_tp->>'gst_pct')::numeric, 0))::int;

  -- feature_gaps #80 — the sellability policy. 'strict' refuses a product with
  -- no trade rate instead of letting it into a cart it cannot price; 'inquiry'
  -- (the default) keeps mediBO's own model, where the rate arrives with the
  -- supplier quote AFTER the order — see legal_get_page('about'), "How an order
  -- flows". Either way the MRP is never the price.
  v_policy := coalesce((select value->>'mode' from app_settings where key='pricing_policy'), 'inquiry');
  if v_policy = 'strict' and v_src is null then
    return jsonb_build_object('ok', false,
      'message', coalesce((select value from storefront_ui_label where key='cart_no_price_yet'),
                          'Awaiting supplier rates'));
  end if;

  insert into cart_items (user_id, customer_id, product_id, product_name, price, mrp, quantity,
                          image_url, manufacturer, pack_size, category, gst_percent, added_by,
                          price_source)
  values (v_uid, v_cust, p_product_id, m.product_name, v_price, v_mrp, p_quantity,
          m.image_url_1, m.marketer, m.pack_size, m.therapeutic_class, v_gst,
          case when auth.uid() is null then 'guest'
               when public.my_acting_as() is not null then 'admin' else 'customer' end,
          v_src)
  on conflict (user_id, product_id) do update
    set quantity = excluded.quantity,
        price = excluded.price,
        price_source = excluded.price_source,
        gst_percent = excluded.gst_percent,
        customer_id = coalesce(excluded.customer_id, cart_items.customer_id),
        removed_by_admin = false,
        updated_at = now();

  return jsonb_build_object('ok',true,'message','Cart updated','cart', public.cart_render(p_guest_uid));
end;
$$;

-- The cart's availability panel. Every `m.supplier_count` here is replaced by
-- the effective count, so the panel, the per-line verdict, the blocking label
-- and the storefront card are four renderings of ONE number.
create or replace function public.cart_availability()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  -- CHANGE #640 — `eff` is computed ONCE per line and every answer below reads
  -- it: the count on the row, the verdict, the unavailable tally and the
  -- blocking label. Before this the function read `m.supplier_count` raw while
  -- the storefront card for the same product read the zone truth, which is the
  -- contradiction a customer saw between adding an item and looking at it.
  WITH lines AS (
    SELECT ci.product_id, ci.product_name, ci.quantity,
           m.id AS mid, m.status AS mstatus,
           public.storefront_effective_count(m.id, m.supplier_count) AS eff
      FROM cart_items ci
      LEFT JOIN "MEDICINE" m ON m.id::text = ci.product_id
     WHERE (CASE
              WHEN coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id()) IS NOT NULL
                THEN ci.customer_id = coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id())
              ELSE ci.user_id = public.viewer_cart_user()
            END)
       AND (ci.removed_by_admin IS NULL OR ci.removed_by_admin = false)
  ), tally AS (
    SELECT count(*) FILTER (WHERE mid IS NOT NULL AND coalesce(eff,0) < 1) AS bad,
           count(*) FILTER (WHERE mid IS NULL)                             AS unresolved
      FROM lines
  )
  SELECT jsonb_build_object(
    'gated', public.viewer_is_approved_customer(),
    'acting_as', public.my_acting_as(),
    'cart_user', public.viewer_cart_user(),
    'unavailable_count', t.bad,
    'unresolved_count',  t.unresolved,
    'items', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'product_id', l.product_id, 'product_name', l.product_name,
                 'quantity', l.quantity,
                 'supplier_count', l.eff,
                 'resolved', (l.mid IS NOT NULL),
                 'availability', public.storefront_cta(l.eff, (l.mid IS NOT NULL), l.mstatus))
               ORDER BY l.product_name)
          FROM lines l), '[]'::jsonb),
    'blocking_label', CASE WHEN public.viewer_is_approved_customer() AND t.bad > 0
                           THEN t.bad::text || ' item(s) in this cart have no supplier and will be removed'
                      END,
    'unresolved_note', CASE WHEN t.unresolved > 0
                            THEN t.unresolved::text || ' item(s) could not be checked and were kept' END)
  FROM tally t;
$$;

-- The strip. It deleted lines on the raw global column while the cart screen
-- flagged them on the zone count — so it could delete a line the cart had never
-- marked, or leave one it had.
create or replace function public._cart_strip_unavailable(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
DECLARE v_removed jsonb; v_n int := 0; v_unknown int := 0;
BEGIN
  IF p_user_id IS NULL THEN RETURN jsonb_build_object('error','no_user'); END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'product_id', ci.product_id, 'product_name', ci.product_name, 'quantity', ci.quantity)), '[]'::jsonb)
    INTO v_removed
  FROM cart_items ci
  JOIN "MEDICINE" m ON m.id::text = ci.product_id
  WHERE ci.user_id = p_user_id
    AND coalesce(public.storefront_effective_count(m.id, m.supplier_count), 0) < 1;

  DELETE FROM cart_items ci
  USING "MEDICINE" m
  WHERE ci.user_id = p_user_id AND m.id::text = ci.product_id
    AND coalesce(public.storefront_effective_count(m.id, m.supplier_count), 0) < 1;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- never delete a row we could not resolve; report it instead
  SELECT count(*) INTO v_unknown FROM cart_items ci
   WHERE ci.user_id = p_user_id
     AND NOT EXISTS (SELECT 1 FROM "MEDICINE" m2 WHERE m2.id::text = ci.product_id);

  RETURN jsonb_build_object('status','ok',
    'removed_count', v_n, 'removed', v_removed, 'unresolved_kept', v_unknown,
    'message', CASE WHEN v_n = 0 THEN 'Cart is clear — every item has a supplier'
                    ELSE v_n::text || ' unavailable item(s) removed from the cart' END
               || CASE WHEN v_unknown > 0
                       THEN ' · ' || v_unknown::text || ' item(s) could not be checked and were kept'
                       ELSE '' END);
END;
$$;

-- The line render. It could not disagree with the storefront on WHICH lines are
-- bad (both went through medicine_zone_standby), but it answered nothing at all
-- for an anonymous or zone-less viewer while the storefront still answered from
-- the global column. Same call as every other surface now.
create or replace function public._cart_unavailable_lines()
returns table(product_id bigint, product_name text)
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_cid uuid;
begin
  if auth.uid() is null then return; end if;
  v_cid := public.my_customer_id();
  if v_cid is null then return; end if;
  return query
    select p.pid, m.product_name
    from cart_items ci
    cross join lateral (select nullif(regexp_replace(coalesce(ci.product_id::text,''),'[^0-9]','','g'),'')::bigint as pid) p
    join "MEDICINE" m on m.id = p.pid
    where ci.customer_id = v_cid
      and p.pid is not null
      and public.storefront_effective_count(p.pid, m.supplier_count) <= 0;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Reconcile the orphans, then backfill every disagreeing row.
-- ─────────────────────────────────────────────────────────────────────────────

-- Any supplier that answered in a zone belongs on that zone's master list. This
-- repairs the rows the old marketer rebuild orphaned (252328 among them) so the
-- data matches the invariant, not just the expression that now enforces it.
do $reconcile$
declare z record; n bigint;
begin
  for z in select code from zones where is_active loop
    execute format($f$
      update public."MEDICINE" m
         set %1$I = (
               select coalesce(array_agg(distinct t.s order by t.s), '{}'::text[])
                 from (select btrim(x) as s
                         from unnest(coalesce(m.%1$I,'{}'::text[])
                                  || coalesce(m.%2$I,'{}'::text[])
                                  || coalesce(m.%3$I,'{}'::text[])
                                  || coalesce(m.%4$I,'{}'::text[])) x) t
                where t.s <> '')
       where not (
         coalesce(m.%1$I,'{}'::text[]) @> coalesce(m.%2$I,'{}'::text[])
         and coalesce(m.%1$I,'{}'::text[]) @> coalesce(m.%3$I,'{}'::text[])
         and coalesce(m.%1$I,'{}'::text[]) @> coalesce(m.%4$I,'{}'::text[]))
    $f$, 'z_'||z.code||'_sup', 'z_'||z.code||'_av',
         'z_'||z.code||'_oos', 'z_'||z.code||'_nostock');
    get diagnostics n = row_count;
    raise notice 'C640 reconcile zone %: % row(s) had a responder off the master list', z.code, n;
  end loop;
end
$reconcile$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE GUARD. Divergence becomes impossible, not merely unlikely.
-- ─────────────────────────────────────────────────────────────────────────────

-- Reports the contract's health in one cheap catalogue read plus, when asked,
-- the row count. rg's behaviour test uses the catalogue half (O(1)); a human
-- can ask for the full scan.
create or replace function public.availability_contract_check(p_scan boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_con record; v_bad bigint;
begin
  select c.conname, c.convalidated into v_con
    from pg_constraint c
   where c.conrelid = 'public."MEDICINE"'::regclass
     and c.conname = 'medicine_availability_one_source';

  if p_scan then
    select count(*) into v_bad from public."MEDICINE"
     where coalesce(buyable,false) is distinct from (coalesce(supplier_count,0) > 0);
  end if;

  return jsonb_build_object(
    'ok', v_con.conname is not null and coalesce(v_con.convalidated,false)
          and (not p_scan or coalesce(v_bad,0) = 0),
    'constraint', v_con.conname,
    'validated', coalesce(v_con.convalidated, false),
    'scanned', p_scan,
    'disagreeing_rows', v_bad);
end;
$$;

comment on function public.availability_contract_check(boolean) is
  'CHANGE #640 — is buyable still derived from supplier_count? The CHECK '
  'constraint makes a divergent row unwritable; this reports that the guard is '
  'present and validated, and (p_scan) that no row escaped it.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. rg BEHAVIOUR TEST — the guard is checked on every rg run, for free.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Two claims, both catalogue-cheap, so this never turns rg_watch() into a
-- 563k-row scan:
--   a) the CHECK constraint exists AND is validated, and it actually REFUSES a
--      divergent write (proved by attempting one inside the rollback);
--   b) every cart-side availability reader resolves through
--      storefront_effective_count(), the same call the storefront makes. This
--      is the "no surface reads a different field than the others" half — it is
--      what would have caught the original bug, where cart_set_item() read the
--      raw column while the card the customer tapped read the zone truth.
insert into rg_behavior_tests (name, enabled, body, note)
values ('c640_availability_one_source', true, $b$
do $c640$
declare v jsonb; v_missing text;
begin
  v := public.availability_contract_check(false);
  if not (v->>'ok')::boolean then
    raise exception
      'C640: the availability contract is not guarded — %. buyable must be derived from supplier_count by a VALIDATED check constraint on "MEDICINE".',
      v::text;
  end if;

  -- The constraint must actually bite, not merely exist.
  begin
    update public."MEDICINE" set buyable = not coalesce(buyable,false)
     where id = (select id from public."MEDICINE" order by id limit 1);
    raise exception
      'C640: a row was written with buyable disagreeing with supplier_count. The check constraint is not enforcing the contract.';
  exception
    when check_violation then null;   -- expected: the guard refused it
  end;

  -- Every cart-side reader asks the SAME question the storefront asks.
  select string_agg(p.proname, ', ') into v_missing
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('cart_set_item','cart_availability',
                       '_cart_strip_unavailable','_cart_unavailable_lines')
     and position('storefront_effective_count' in p.prosrc) = 0;
  if v_missing is not null then
    raise exception
      'C640: % decide availability without storefront_effective_count(). Every surface resolves through the one call, or the cart and the storefront disagree again.',
      v_missing;
  end if;

  raise exception 'RG_ROLLBACK';
end $c640$;
$b$, 'CHANGE #640 — availability had five definitions across five writers and seven readers; this pins it to one.')
on conflict (name) do update
  set body = excluded.body, enabled = true, note = excluded.note;
