-- CMD #2095 — Product page + Compare sheet cleanup.
--
-- Product page: the GST breakup box and the "Net ₹ · GST %" line go, the
-- company line under the name goes, and the pack / MRP / Sale price lines drop
-- to the regular weight the Product-overview values use.
--
-- Compare: the table becomes an 85% bottom sheet, the Availability column says
-- Available / Unavailable rather than repeating the ADD word, Margin and Profit
-- show the absent dash until the pack has a real PTR in medicine_pricing, and
-- an unavailable row offers Notify (stock_notify_request) where ADD would be.
--
-- Every word below is a row in storefront_ui_label and every measurement is a
-- key in app_settings.compare_layout, so the wording and the geometry are an
-- UPDATE, never a deploy. Idempotent: safe to replay.

-- ── 1. The words ────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value) values
  ('cmp_avail_yes',   'Available'),
  ('cmp_avail_no',    'Unavailable'),
  ('cmp_notify',      'Notify'),
  ('cmp_notify_done', 'Notifying'),
  ('cmp_close',       'Close')
on conflict (key) do update set value = excluded.value;

-- The sale-price sub-line is silenced by emptying its own template.
update public.storefront_ui_label set value = '' where key = 'pdp_sale_net_note';

-- ── 2. The geometry ─────────────────────────────────────────────────────────
-- sheet_pct: the share of the screen the compare sheet takes (spec: 85%).
-- ctrl_w   : the ADD / stepper / Notify control's width, so ADD cannot change
--            size the moment it becomes a stepper.
-- ctrl_h   : and its height.
insert into public.app_settings (key, value)
values ('compare_layout', jsonb_build_object(
          'sheet_pct', 85, 'ctrl_w', 96, 'ctrl_h', 44))
on conflict (key) do update
  set value = app_settings.value
              || jsonb_build_object('sheet_pct', 85, 'ctrl_w', 96, 'ctrl_h', 44);

-- ── 3. The product page's price lines ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pdp_price_lines(p_product_id bigint, p_mrp numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_has_mrp boolean := (p_mrp is not null and p_mrp > 0);
  v_pb jsonb;
  v_mrp_cap text := public._pdp_label('mrp_caption', 'MRP');
  v_mrp_val text;
  v_mrp_note text := public._pdp_label('pdp_mrp_ceiling_note', 'Printed pack ceiling — not the selling price');
  v_sale_cap text := public._pdp_label('pdp_sale_price_caption', 'Sale price');
  v_sale_val text; v_sale_note text := ''; v_sale_amount boolean := false; v_sale_tone text := 'secondary';
  v_side text := '';
  v_sticky_main text;
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
    -- CMD #2095 — the "Net ₹ · GST %" line under the sale price is GONE. It
    -- is a DATA switch, not a deploy: the template's default is now empty, so
    -- emptying `pdp_sale_net_note` (or deleting the row) silences the line and
    -- filling it back in brings it back with no code change.
    v_sale_note := public._pdp_label('pdp_sale_net_note', '');
    if v_sale_note <> '' then
      v_sale_note := replace(replace(v_sale_note,
          '{net}', coalesce(v_pb->>'net_display', '')),
          '{gst}', coalesce(v_pb#>>'{gst,pct_display}', ''));
      v_sale_note := btrim(regexp_replace(v_sale_note, '\s·\s*$', ''));
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
      'has_note',   v_has_mrp,
      'note',       case when v_has_mrp then v_mrp_note else '' end,
      'tone',       'secondary'),
    'sale', jsonb_build_object(
      'caption',    v_sale_cap,
      'value',      v_sale_val,
      'has_amount', v_sale_amount,
      'has_note',   v_sale_note <> '',
      'note',       v_sale_note,
      'locked',     not v_sale_amount,
      'prompt',     v_pb -> 'locked_prompt',
      'tone',       v_sale_tone),
    'sticky', jsonb_build_object(
      'main',         coalesce(v_sticky_main, v_sale_val),
      'main_caption', public._pdp_label('pdp_sticky_sale_caption', 'Sale price'),
      'main_tone',    v_sale_tone,
      'has_side',     v_side <> '',
      'side',         v_side));
end $function$;


-- ── 4. The compare table ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pdp_salt_compare(p_product_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  -- CMD #2095 — the availability column says the STATE, not the action, and
  -- the unavailable row offers Notify in place of ADD. Both words are rows in
  -- storefront_ui_label, so changing them is an UPDATE.
  v_av_yes   text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_avail_yes'), 'Available');
  v_av_no    text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_avail_no'), 'Unavailable');
  v_notify   text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_notify'), 'Notify');
  v_noti_on  text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_notify_done'), 'Notifying');
  v_close    text := coalesce((select value from public.storefront_ui_label
                                where key = 'cmp_close'), 'Close');
  v_uid      uuid := auth.uid();
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
    jsonb_build_object('key','company','kind','text','align','center','frozen',false,
      'width', coalesce((v_cw->>'company')::numeric, 116),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_company'),'')),
    jsonb_build_object('key','pack','kind','text','align','center','frozen',false,
      'width', coalesce((v_cw->>'pack')::numeric, 88),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_pack'),'')),
    jsonb_build_object('key','mrp','kind','text','align','center','frozen',false,
      'width', coalesce((v_cw->>'mrp')::numeric, 92),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_mrp'),'')),
    jsonb_build_object('key','sale','kind','pill','align','center','frozen',false,
      'width', coalesce((v_cw->>'sale')::numeric, 104),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_sale'),'')),
    jsonb_build_object('key','margin','kind','text','align','center','frozen',false,
      'width', coalesce((v_cw->>'margin')::numeric, 92),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_margin'),'')),
    jsonb_build_object('key','profit','kind','text','align','center','frozen',false,
      'width', coalesce((v_cw->>'profit')::numeric, 96),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_profit'),'')),
    jsonb_build_object('key','drugtype','kind','text','align','center','frozen',false,
      'width', coalesce((v_cw->>'drugtype')::numeric, 96),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_drugtype'),'')),
    jsonb_build_object('key','stock','kind','text','align','center','frozen',false,
      'width', coalesce((v_cw->>'stock')::numeric, 108),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_stock'),'')),
    jsonb_build_object('key','add','kind','add','align','center','frozen',false,
      'width', coalesce((v_cw->>'add')::numeric, 112),
      'label', coalesce((select value from storefront_ui_label where key='cmp_col_add'),'')));

  if coalesce(array_length(v_ids, 1), 0) < 2 then
    return jsonb_build_object(
      'ok', true, 'has', false,
      'title', v_title, 'note', v_note, 'empty', v_empty,
      'max', v_cap, 'close_label', v_close, 'layout', v_layout,
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
           mp                           as prow,
           (v_uid is not null and exists (
              select 1 from public.stock_notify_requests r
               where r.product_id = m.id and r.user_id = v_uid
                 and r.available_at is null)) as notified
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
                     or (s.prow).ptr is null
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
           -- CMD #2095 — an unavailable row offers Notify instead of ADD. The
           -- two words and this viewer's own subscription state travel WITH
           -- the row, so the sheet needs no second call per row.
           'notify_label',      v_notify,
           'notify_done_label', v_noti_on,
           'notify_subscribed', coalesce(c.notified, false),
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
             -- Margin, % on MRP. CMD #2095 — a pack with no PTR in
             -- medicine_pricing shows the absent dash, not the locked PTR
             -- pill: the column is empty because the number does not exist
             -- yet, and a pill implied it was being withheld.
             jsonb_build_object(
               'has',    (c.trade is not null and (c.trade->>'margin_pct') is not null),
               'tone',   case when c.trade is null then 'text'
                              when (c.trade->>'margin_pct')::numeric < 0 then 'danger'
                              else 'success' end,
               'locked', false,
               'value',  case
                 when c.trade is not null and (c.trade->>'margin_pct') is not null
                 then public._num_label((c.trade->>'margin_pct')::numeric) || '%'
                 else v_absent end,
               'pill',   null),
             -- Profit, ₹ per pack. Same rule as Margin (CMD #2095).
             jsonb_build_object(
               'has',    (c.trade is not null and (c.trade->>'margin_amount') is not null),
               'tone',   case when c.trade is null then 'text'
                              when (c.trade->>'margin_amount')::numeric < 0 then 'danger'
                              else 'success' end,
               'locked', false,
               'value',  case
                 when c.trade is not null and (c.trade->>'margin_amount') is not null
                 then public.inr_money((c.trade->>'margin_amount')::numeric)
                 else v_absent end,
               'pill',   null),
             -- Drug type
             jsonb_build_object('has', (c.drug_type <> ''), 'tone', 'text',
               'value', case when c.drug_type <> '' then c.drug_type else v_absent end),
             -- Availability: the state as TEXT. storefront_cta's own word, the
             -- same one the card's pill reads — never a button here.
             jsonb_build_object(
               'has',   true,
               'value', case when coalesce((c.cta->>'can_add')::boolean, false)
                             then v_av_yes else v_av_no end,
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
    'max',         v_cap,
    'close_label', v_close,
    'layout',      v_layout,
    'columns',     v_cols,
    'rows',        v_rows);
end
$function$;


-- ── 5. Grants — unchanged surface, restated so a replay cannot leave a new
--       definition unreachable. Both are read-only, SECURITY DEFINER, and the
--       storefront is browsable before login, so anon keeps its read.
grant execute on function public.pdp_price_lines(bigint, numeric) to anon, authenticated;
grant execute on function public.pdp_salt_compare(bigint) to anon, authenticated;
