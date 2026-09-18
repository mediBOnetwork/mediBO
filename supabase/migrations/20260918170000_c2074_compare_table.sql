-- CMD #2074 — the compare table turns ninety degrees.
--
-- Until now `pdp_salt_compare()` sent products as COLUMNS and attributes as
-- ROWS, which is the right shape for three ticked packs and the wrong shape
-- for twenty brands of one salt: a pharmacy reads down a list of brands and
-- across a fixed set of facts, not across twenty columns. So products are ROWS
-- now, attributes are COLUMNS, the header row and the product-name column stay
-- put while the rest scrolls, and the cap goes from 6 packs to 20.
--
-- Three columns are new. Drug type is a MEDICINE field this migration adds
-- (Generic / Ethical, nullable, blank when unset). Margin (% on MRP) and
-- Profit (₹ per pack) are the trade numbers `_pricing_compute()` already
-- derives — and they are shown on EXACTLY the same condition as the sale
-- price: a real PTR on a pricing-ready row, read by a viewer entitled to see
-- it. Everywhere else all three cells carry the same locked PTR pill, because
-- a margin computed off MRP alone would be invented (#366, #746).
--
-- Every column label, every cell string, every tone and the whole layout
-- geometry are in the payload. The screen runs two loops and prints.
--
-- Idempotent: add-column-if-not-exists, insert-on-conflict-do-nothing,
-- create-or-replace.

-- ── 1. MEDICINE.drug_type ───────────────────────────────────────────────────
-- Nullable on purpose: 5.6 lakh rows have no value for this yet and a blank
-- cell is the honest rendering of "not recorded". No default, no backfill,
-- no guess — the compare cell prints the absent dash until an admin sets it.
alter table public."MEDICINE"
  add column if not exists drug_type text;

comment on column public."MEDICINE".drug_type is
  'CMD #2074 — Generic / Ethical, free text, nullable. Rendered verbatim in the '
  'compare table''s Drug type column; blank (the cmp_absent dash) when unset.';

-- ── 2. Copy ─────────────────────────────────────────────────────────────────
-- The column headings, the two absent words and the locked pill''s colours.
-- Retuning a heading is an UPDATE here, never a deploy.
insert into public.storefront_ui_label (key, value, note) values
  ('cmp_title',        'Compare',
   'CMD #2074 — the compare screen title'),
  ('cmp_absent',       '—',
   'CMD #2074 — printed in any compare cell the backend has no value for'),
  ('cmp_empty',        'No other brand of this composition is listed yet.',
   'CMD #2074 — the compare screen''s empty state'),
  ('cmp_col_name',     'Product',
   'CMD #2074 — compare column 1 (frozen): the product name, tappable'),
  ('cmp_col_company',  'Company',
   'CMD #2074 — compare column: marketer'),
  ('cmp_col_pack',     'Pack',
   'CMD #2074 — compare column: pack type / size'),
  ('cmp_col_mrp',      'MRP',
   'CMD #2074 — compare column: printed ceiling'),
  ('cmp_col_sale',     'Sale price',
   'CMD #2074 — compare column: the trade rate, or the locked PTR pill'),
  ('cmp_col_margin',   'Margin',
   'CMD #2074 — compare column: margin % on MRP, or the locked PTR pill'),
  ('cmp_col_profit',   'Profit',
   'CMD #2074 — compare column: ₹ earned per pack, or the locked PTR pill'),
  ('cmp_col_drugtype', 'Drug type',
   'CMD #2074 — compare column: MEDICINE.drug_type, verbatim'),
  ('cmp_col_stock',    'Availability',
   'CMD #2074 — compare column: the stock state as TEXT, never a button'),
  ('cmp_col_add',      'Add',
   'CMD #2074 — compare column: the cart control'),
  ('cmp_lock_bg',      '#F3F4F6',
   'CMD #2074 — background of the locked PTR pill in a compare cell'),
  ('cmp_lock_fg',      '#6B7280',
   'CMD #2074 — text colour of the locked PTR pill in a compare cell'),
  ('cmp_current_tag',  'Viewing',
   'CMD #2074 — the tag on the row whose page opened the table')
on conflict (key) do nothing;

-- The salt note survived the turn; make sure it is there for a fresh database.
insert into public.storefront_ui_label (key, value) values
  ('cmp_salt_note', 'Other brands with the same composition.'),
  ('cmp_open',      'Compare')
on conflict (key) do nothing;

-- ── 3. The geometry ─────────────────────────────────────────────────────────
-- A table needs column widths and there is exactly one place they may live.
-- The screen clamps the frozen name column to `name_pct` of whatever viewport
-- it is handed (min/max in logical px) and gives every scrolling column its own
-- width — so a 320px phone and a desktop draw the same table, and widening a
-- column is an app_settings UPDATE.
insert into public.app_settings (key, value) values
  ('compare_layout', jsonb_build_object(
     'name_pct',  42,
     'name_min',  116,
     'name_max',  200,
     'row_h',     64,
     'head_h',    44,
     'col_w',     jsonb_build_object(
       'company',  116,
       'pack',      88,
       'mrp',       92,
       'sale',     104,
       'margin',    92,
       'profit',    96,
       'drugtype',  96,
       'stock',    108,
       'add',      112)))
on conflict (key) do nothing;

-- ── 4. The table ────────────────────────────────────────────────────────────
create or replace function public.pdp_salt_compare(p_product_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_disc     numeric := public.my_cart_discount_pct();
  v_absent   text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_absent'), '—');
  v_title    text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_title'), '');
  v_note     text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_salt_note'), '');
  v_empty    text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_empty'), '');
  v_tag      text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_current_tag'), '');
  v_lock_bg  text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_lock_bg'), '#F3F4F6');
  v_lock_fg  text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_lock_fg'), '#6B7280');
  v_layout   jsonb := coalesce((select value from public.app_settings
                                 where key = 'compare_layout'), '{}'::jsonb);
  v_cw       jsonb := coalesce(v_layout->'col_w', '{}'::jsonb);
  -- CMD #2074 — twenty rows, not six: the opened pack plus up to nineteen
  -- other brands of the same composition.
  v_cap      int := 20;
  v_salt     text;
  v_ids      bigint[];
  v_cols     jsonb;
  v_rows     jsonb;
begin
  select nullif(btrim(m.salt_composition), '') into v_salt
    from "MEDICINE" m where m.id = p_product_id;

  select coalesce(array_agg(x.id order by x.rn), '{}'::bigint[]) into v_ids
    from (select s.id,
                 row_number() over (order by s.sales_count desc nulls last, s.id) as rn
            from "MEDICINE" s
           where v_salt is not null
             and s.salt_composition = v_salt
             and s.id <> p_product_id
             and s.buyable is true
           order by s.sales_count desc nulls last, s.id
           limit greatest(v_cap - 1, 0)) x;

  -- The opened pack is always row one, whatever its sales rank.
  v_ids := array_prepend(p_product_id, coalesce(v_ids, '{}'::bigint[]));

  -- The columns exist even when there is nothing to compare, so the screen can
  -- draw its empty state under a real heading rather than under nothing.
  v_cols := jsonb_build_array(
    jsonb_build_object('key','name','kind','name','align','left','frozen',true,
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_name'),'')),
    jsonb_build_object('key','company','kind','text','align','left','frozen',false,
      'width', coalesce((v_cw->>'company')::numeric, 116),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_company'),'')),
    jsonb_build_object('key','pack','kind','text','align','left','frozen',false,
      'width', coalesce((v_cw->>'pack')::numeric, 88),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_pack'),'')),
    jsonb_build_object('key','mrp','kind','text','align','right','frozen',false,
      'width', coalesce((v_cw->>'mrp')::numeric, 92),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_mrp'),'')),
    jsonb_build_object('key','sale','kind','pill','align','right','frozen',false,
      'width', coalesce((v_cw->>'sale')::numeric, 104),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_sale'),'')),
    jsonb_build_object('key','margin','kind','text','align','right','frozen',false,
      'width', coalesce((v_cw->>'margin')::numeric, 92),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_margin'),'')),
    jsonb_build_object('key','profit','kind','text','align','right','frozen',false,
      'width', coalesce((v_cw->>'profit')::numeric, 96),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_profit'),'')),
    jsonb_build_object('key','drugtype','kind','text','align','left','frozen',false,
      'width', coalesce((v_cw->>'drugtype')::numeric, 96),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_drugtype'),'')),
    jsonb_build_object('key','stock','kind','text','align','left','frozen',false,
      'width', coalesce((v_cw->>'stock')::numeric, 108),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_stock'),'')),
    jsonb_build_object('key','add','kind','add','align','left','frozen',false,
      'width', coalesce((v_cw->>'add')::numeric, 112),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_add'),'')));

  if coalesce(array_length(v_ids, 1), 0) < 2 then
    return jsonb_build_object(
      'ok', true, 'has', false,
      'title', v_title, 'note', v_note, 'empty', v_empty,
      'max', v_cap, 'layout', v_layout,
      'columns', v_cols, 'rows', '[]'::jsonb);
  end if;

  with src as (
    select m.id,
           ord.n as pos,
           (m.id = p_product_id)        as is_current,
           coalesce(m.product_name, '') as name,
           coalesce(m.marketer, '')     as company,
           coalesce(nullif(btrim(m.pack_type), ''),
                    nullif(btrim(m.pack_size), ''), '') as pack,
           coalesce(nullif(btrim(m.drug_type), ''), '') as drug_type,
           nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric as mrp_num,
           public.storefront_pricing(
             nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
             v_disc, m.id)              as pricing,
           public.storefront_cta(
             public.storefront_effective_count(m.id,
               coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text, ''),
                                              '[^0-9]', '', 'g'), '')::int, 0)), true) as cta,
           mp                           as prow
      from unnest(v_ids) with ordinality as ord(pid, n)
      join "MEDICINE" m on m.id = ord.pid
      left join public.medicine_pricing mp on mp.product_id = m.id
  ), calc as (
    -- ONE gate for the three trade cells, and it is the SAME gate the sale
    -- price already uses: card_price.price_locked is false only for a
    -- pricing-ready row with a real PTR read by an entitled viewer. When it is
    -- true there is no trade rate to show, so margin and profit wear the same
    -- locked pill as the sale price rather than a number derived from MRP.
    select s.*,
           coalesce((s.pricing->'card_price'->>'price_locked')::boolean, true) as locked,
           coalesce(nullif(s.pricing->'card_price'->>'price_display', ''), v_absent) as sale_txt,
           case when coalesce((s.pricing->'card_price'->>'price_locked')::boolean, true)
                then null
                else public._pricing_compute(s.mrp_num, (s.prow).ptr, (s.prow).gst_pct,
                       coalesce((s.prow).discount_pct, 0),
                       (s.prow).scheme_buy_qty, (s.prow).scheme_free_qty, false)
           end as trade,
           coalesce((s.pricing->'card_price'->>'sale_bg'), '#1B7A43') as sale_bg,
           coalesce((s.pricing->'card_price'->>'sale_fg'), '#FFFFFF') as sale_fg
      from src s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',         c.id::text,
           'name',       c.name,
           'company',    c.company,
           'is_current', c.is_current,
           'tag',        case when c.is_current then v_tag else '' end,
           'can_add',    coalesce((c.cta->>'can_add')::boolean, false),
           'cta_label',  coalesce(nullif(c.cta->>'cta_short', ''),
                                  c.cta->>'cta_label', ''),
           'cells', jsonb_build_array(
             -- name (frozen)
             jsonb_build_object('has', (c.name <> ''), 'tone', 'text',
               'value', case when c.name <> '' then c.name else v_absent end),
             -- company
             jsonb_build_object('has', (c.company <> ''), 'tone', 'text',
               'value', case when c.company <> '' then c.company else v_absent end),
             -- pack
             jsonb_build_object('has', (c.pack <> ''), 'tone', 'text',
               'value', case when c.pack <> '' then c.pack else v_absent end),
             -- MRP
             jsonb_build_object(
               'has',   coalesce((c.pricing->'card_price'->>'has_mrp')::boolean, false),
               'tone',  'text',
               'value', case when coalesce((c.pricing->'card_price'->>'has_mrp')::boolean, false)
                             then c.pricing->'card_price'->>'mrp_display' else v_absent end),
             -- Sale price: always a pill. Green with a real rate, muted grey
             -- with the literal word.
             jsonb_build_object(
               'has',    true,
               'tone',   'text',
               'locked', c.locked,
               'value',  c.sale_txt,
               'pill',   jsonb_build_object(
                 'bg', case when c.locked then v_lock_bg else c.sale_bg end,
                 'fg', case when c.locked then v_lock_fg else c.sale_fg end)),
             -- Margin, % on MRP
             jsonb_build_object(
               'has',    (c.trade is not null and (c.trade->>'margin_pct') is not null),
               'tone',   case when c.trade is null then 'text'
                              when (c.trade->>'margin_pct')::numeric < 0 then 'danger'
                              else 'success' end,
               'locked', c.locked,
               'value',  case
                 when c.trade is not null and (c.trade->>'margin_pct') is not null
                 then public._num_label((c.trade->>'margin_pct')::numeric) || '%'
                 else c.sale_txt end,
               'pill',   case when c.locked then jsonb_build_object('bg', v_lock_bg, 'fg', v_lock_fg)
                              else null end),
             -- Profit, ₹ per pack
             jsonb_build_object(
               'has',    (c.trade is not null and (c.trade->>'margin_amount') is not null),
               'tone',   case when c.trade is null then 'text'
                              when (c.trade->>'margin_amount')::numeric < 0 then 'danger'
                              else 'success' end,
               'locked', c.locked,
               'value',  case
                 when c.trade is not null and (c.trade->>'margin_amount') is not null
                 then public.inr_money((c.trade->>'margin_amount')::numeric)
                 else c.sale_txt end,
               'pill',   case when c.locked then jsonb_build_object('bg', v_lock_bg, 'fg', v_lock_fg)
                              else null end),
             -- Drug type
             jsonb_build_object('has', (c.drug_type <> ''), 'tone', 'text',
               'value', case when c.drug_type <> '' then c.drug_type else v_absent end),
             -- Availability: the state as TEXT. storefront_cta's own word, the
             -- same one the card's pill reads — never a button here.
             jsonb_build_object(
               'has',   true,
               'value', coalesce(nullif(c.cta->>'cta_label', ''), v_absent),
               'tone',  case when coalesce((c.cta->>'can_add')::boolean, false)
                             then 'success' else 'warning' end),
             -- Add: the control. The word and the verdict are on the ROW, so
             -- this cell only has to exist in column order.
             jsonb_build_object('has', true, 'tone', 'text', 'value', ''))
           ) order by c.pos), '[]'::jsonb)
    into v_rows
    from calc c;

  return jsonb_build_object(
    'ok',      true,
    'has',     true,
    'title',   v_title,
    'note',    v_note,
    'empty',   v_empty,
    'max',     v_cap,
    'layout',  v_layout,
    'columns', v_cols,
    'rows',    v_rows);
end
$function$;

-- The product page is public, so its compare table is reachable anonymously.
-- Every trade number inside it is gated by storefront_pricing / price_locked,
-- which hands an unapproved viewer the literal word instead of an amount, and
-- margin and profit ride on exactly that flag (constraint #79).
revoke all on function public.pdp_salt_compare(bigint) from public;
grant execute on function public.pdp_salt_compare(bigint) to anon, authenticated, service_role;
