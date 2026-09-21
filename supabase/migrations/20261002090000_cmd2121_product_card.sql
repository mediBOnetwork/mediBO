-- CMD #2121 — ONE product_card payload every customer surface reads.
--
-- Every card builder (storefront feed, home rails, category/catalogue, search,
-- company page, PDP wrapper, cart lines) now carries a `card` object built by
-- ONE function, public._product_card(). It holds everything the universal card
-- prints — image (+ placeholder flag), name, pack line, unit word, composition,
-- rx badge, offer badge, availability (is_available + label + tone), the
-- card_price block from _pricing_block (number or locked PTR, MRP, margin line),
-- qty-in-cart and the cta state (add / qty_selected / notify / notified / locked).
-- Change the card here and every screen changes at once. Existing keys on each
-- surface are kept untouched so the live app keeps rendering while the screens
-- move onto `card`.
--
-- Scope: customer surfaces scope to the VIEWER's own zone (storefront_effective_count
-- → zone_available(_viewer_zone_or_null())); admin_active_zone/date is the staff
-- picker and does not apply to a customer card.
--
-- Idempotent: every statement is CREATE OR REPLACE / ON CONFLICT DO NOTHING.

-- ── copy (storefront_ui_label, one UPDATE changes the wording) ──────────────
insert into public.storefront_ui_label(key, value, note) values
  ('card_avail_in',     'Available',     'CMD #2121 product_card availability label when the viewer can add'),
  ('card_qty_in_cart',  '{n} in cart',   'CMD #2121 product_card qty_selected label; {n} = qty in cart'),
  ('card_locked_cta',   'Unlock price',  'CMD #2121 product_card cta label for a viewer not yet approved'),
  ('card_notify_label', 'Notify me',     'product_card cta label for an unavailable product'),
  ('notify_subscribed_label', 'We''ll notify you', 'product_card cta label once subscribed'),
  ('card_add_label',    'ADD',           'product_card cta label to add')
on conflict (key) do nothing;

-- ── viewer maps: one scan per page, never one per card ──────────────────────
create or replace function public._viewer_cart_qty_map(p_ids bigint[])
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with v as (
    select coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                    public.my_customer_id()) as cust,
           public.viewer_cart_user() as uid)
  select coalesce(jsonb_object_agg(t.pid, t.qty), '{}'::jsonb)
    from (select ci.product_id as pid, sum(coalesce(ci.quantity,0))::int as qty
            from public.cart_items ci, v
           where coalesce(ci.removed_by_admin, false) = false
             and ci.product_id = any (p_ids::text[])
             and (case when v.cust is not null then ci.customer_id = v.cust
                       else ci.user_id = v.uid end)
           group by ci.product_id) t
   where t.qty > 0;
$$;

create or replace function public._viewer_notify_map(p_ids bigint[])
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_object_agg(r.product_id::text, true), '{}'::jsonb)
    from (select distinct product_id from public.stock_notify_requests
           where user_id = auth.uid() and available_at is null
             and product_id = any (p_ids)) r;
$$;

-- ── the cta decision, shared by the card and the out-of-zone override ──────
create or replace function public._product_card_cta(
  p_available boolean, p_locked boolean, p_qty integer, p_notified boolean,
  p_colors jsonb default null)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case
    when not coalesce(p_available, false) and coalesce(p_notified, false) then
      jsonb_build_object('state','notified','enabled',false,
        'label', coalesce((select value from storefront_ui_label where key='notify_subscribed_label'), ''),
        'tone', jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46'))
    when not coalesce(p_available, false) then
      jsonb_build_object('state','notify','enabled',true,'rpc','stock_notify_request',
        'label', coalesce((select value from storefront_ui_label where key='card_notify_label'), ''),
        'tone', jsonb_build_object('name','info','bg','#EFF6FF','fg','#1E40AF'))
    when coalesce(p_locked, false) then
      jsonb_build_object('state','locked','enabled',true,
        'label', coalesce(nullif((select value from storefront_ui_label where key='ptr_locked_cta'), ''),
                          (select value from storefront_ui_label where key='card_locked_cta'), ''),
        'route', coalesce((select value from storefront_ui_label where key='ptr_locked_route'), ''),
        'tone', jsonb_build_object('name','neutral','bg','#F3F4F6','fg','#111827'))
    when coalesce(p_qty, 0) > 0 then
      jsonb_build_object('state','qty_selected','enabled',true,'qty',p_qty,
        'label', replace(coalesce((select value from storefront_ui_label where key='card_qty_in_cart'), '{n}'),
                         '{n}', p_qty::text),
        'qty_display', p_qty::text,
        'tone', jsonb_build_object('name','brand','bg','#1B7A43','fg','#FFFFFF'))
    else
      jsonb_build_object('state','add','enabled',true,
        'label', coalesce((select value from storefront_ui_label where key='card_add_label'), ''),
        'tone', jsonb_build_object('name','brand',
                  'bg', coalesce(p_colors->>'bg','#1B7A43'),
                  'fg', coalesce(p_colors->>'fg','#FFFFFF')))
  end;
$$;

-- ── THE card ────────────────────────────────────────────────────────────────
create or replace function public._product_card(
  m public."MEDICINE", p_pricing jsonb, p_avail jsonb, p_qty integer, p_notified boolean)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_img   text := nullif(btrim(coalesce(m.image_url_1, '')), '');
  v_avail boolean := coalesce((p_avail->>'is_available')::boolean, false);
  v_price jsonb := coalesce(p_pricing->'card_price', '{}'::jsonb);
  v_locked boolean := coalesce((v_price->>'price_locked')::boolean, true)
                      and not public.viewer_is_approved_customer();
  v_qty   int := greatest(coalesce(p_qty, 0), 0);
  v_offer text;
begin
  v_offer := case
    when coalesce((p_pricing->>'has_scheme')::boolean, false)
      then coalesce(p_pricing#>>'{scheme_badge,label}', p_pricing->>'scheme_text', '')
    when coalesce(m.has_scheme, false)
      then public.uic('catalogue.scheme_chip','Scheme available')
    else '' end;

  return jsonb_build_object(
    'v', 1,
    'id', m.id,
    'name', coalesce(m.product_name, ''),
    'company', coalesce(m.marketer, ''),
    'image', jsonb_build_object(
      'url', coalesce(v_img, ''),
      'placeholder', v_img is null,
      'placeholder_letter', upper(left(btrim(coalesce(m.product_name, '?')), 1))),
    'pack_line', coalesce(nullif(btrim(coalesce(m.pack_qty, '')), ''),
                          nullif(btrim(coalesce(m.pack_size, '')), ''), ''),
    'unit_word', initcap(coalesce(nullif(btrim(coalesce(m.pack_type, '')), ''),
                                  nullif(btrim(coalesce(m.pack_size, '')), ''), '')),
    'composition', coalesce(nullif(btrim(coalesce(m.salt_composition, '')), ''), ''),
    'has_composition', nullif(btrim(coalesce(m.salt_composition, '')), '') is not null,
    'rx', public.rx_badge(m.rx_required),
    'offer', jsonb_build_object('has', v_offer <> '', 'label', v_offer,
               'tone', jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46')),
    'availability', jsonb_build_object(
      'is_available', v_avail,
      'label', case when v_avail
                    then coalesce((select value from storefront_ui_label where key='card_avail_in'), '')
                    else coalesce(p_avail->>'cta_short', '') end,
      'tone', case when v_avail
                   then jsonb_build_object('name','success','bg','#D1FAE5','fg','#065F46')
                   else jsonb_build_object('name','neutral',
                          'bg', coalesce(p_avail#>>'{colors,bg}','#F3F4F6'),
                          'fg', coalesce(p_avail#>>'{colors,fg}','#6B7280')) end),
    'price', v_price || jsonb_build_object(
      'has_margin',   coalesce((p_pricing->>'has_margin')::boolean, false),
      'margin_label', coalesce(p_pricing->>'margin_label', ''),
      'margin_chip',  p_pricing->'margin_chip'),
    'qty_in_cart', v_qty,
    'notified', coalesce(p_notified, false),
    'locked', v_locked,
    'cta', public._product_card_cta(v_avail, v_locked, v_qty, p_notified, p_avail->'colors'),
    'wish', public.card_wish(m.id));
end $$;

-- Rewrites a card as unavailable (catalogue's out-of-zone group) without
-- recomputing it: the cta flips to notify/notified from the card's own flag.
create or replace function public._product_card_unavailable(p_card jsonb, p_label text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when p_card is null then null else
    p_card || jsonb_build_object(
      'availability', jsonb_build_object('is_available', false, 'label', coalesce(p_label, ''),
        'tone', jsonb_build_object('name','neutral','bg','#F3F4F6','fg','#6B7280')),
      'cta', public._product_card_cta(false, false, 0, coalesce((p_card->>'notified')::boolean, false)))
  end;
$$;

-- ── public doors (same object) ─────────────────────────────────────────────
create or replace function public.product_cards(p_ids bigint[])
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm)
  select coalesce(jsonb_agg(public._product_card(m, l.pr, l.av,
           coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text) order by o.ord), '[]'::jsonb)
    from unnest(p_ids) with ordinality o(pid, ord)
    join "MEDICINE" m on m.id = o.pid
    cross join cq cross join nt
    cross join lateral (select
      public.storefront_cta(public.storefront_effective_count(m.id,
        coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)), true) as av,
      public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr) l;
$$;

create or replace function public.product_card(p_product_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select public.product_cards(array[p_product_id])->0;
$$;

-- ── builders: each now carries `card` computed from the SAME pricing and
--    availability it already prints (no second pricing pass) ────────────────
create or replace function public._sf_cards(p_ids bigint[])
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm)
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'name', m.product_name,
    'company', m.marketer,
    'pack_label', public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type),
    'form_chip', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
    'pack_type_label', public.sf_pack_type_label(m.pack_type),
    'pack_qty_display', coalesce(nullif(btrim(m.pack_type),''), nullif(btrim(m.pack_size),'')),
    'pack_size_display', coalesce(nullif(btrim(m.pack_qty),''), nullif(btrim(m.pack_size),'')),
    'pack_type', m.pack_type,
    'pack_qty', m.pack_qty,
    'pack_size', m.pack_size,
    'image', m.image_url_1,
    'category', m.therapeutic_class,
    'has_offer', coalesce(m.has_scheme, false),
    'offer_chip', case when coalesce(m.has_scheme, false) then 'Scheme available' else '' end,
    -- CHANGE #461/#170: the prescription class, from "MEDICINE".rx_required.
    'rx', public.rx_badge(m.rx_required),
      'wish', public.card_wish(m.id),
    'availability', l.av,
    'pricing', l.pr,
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
    'card', public._product_card(m, l.pr, l.av, coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text)
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt
  cross join lateral (select
    public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0))) as av,
    public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr) l
  where lower(coalesce(m.buyable::text,'')) in ('true','t');
$function$;

create or replace function public._search_cards(p_ids bigint[], p_pct numeric, p_zone smallint)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm)
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
      'wish', public.card_wish(m.id),
      -- CMD #2023 — ONE truth. The card button is storefront_cta over
      -- storefront_effective_count, which is public.zone_available().
      'availability', l.av,
      'pricing', l.pr,
      'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                   then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
      'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
      'card', public._product_card(m, l.pr, l.av, coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text)
    ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt
  cross join lateral (select
    public.storefront_cta(
          public.storefront_effective_count(m.id,
            coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
          true) as av,
    public.storefront_pricing(
          nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, p_pct, m.id) as pr) l;
$function$;

create or replace function public._cat_cards(p_ids bigint[])
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  with cq as (select public._viewer_cart_qty_map(p_ids) as qm),
       nt as (select public._viewer_notify_map(p_ids) as nm)
  select coalesce(jsonb_agg(jsonb_build_object(
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
    -- CHANGE #748 — the "New" chip, decided against the backend's own window.
    'is_new', (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30))),
    'new_badge', case when (m.created_at is not null
               and m.created_at >= now() - make_interval(days =>
                     coalesce((select new_days from public.catalogue_extras_config where id = 1), 30)))
                 then public.uic('catalogue.new_badge','New') else '' end,
    'rx', public.rx_badge(m.rx_required),
      'wish', public.card_wish(m.id),
    'availability', l.av,
    'pricing', l.pr,
    'mrp_label', case when nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'') is not null
                 then '₹'||to_char(nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric,'FM999999990.00') end,
    'buyable', lower(coalesce(m.buyable::text,'')) in ('true','t'),
    'card', public._product_card(m, l.pr, l.av, coalesce((cq.qm->>m.id::text)::int, 0), nt.nm ? m.id::text)
  ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality o(pid, ord)
  join "MEDICINE" m on m.id = o.pid
  cross join cq cross join nt
  cross join lateral (select
    public.storefront_cta(
        public.storefront_effective_count(m.id,
          coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text,''),'[^0-9]','','g'),'')::int, 0)),
        true) as av,
    public.storefront_pricing(
        nullif(regexp_replace(coalesce(m.mrp::text,''),'[^0-9.]','','g'),'')::numeric, null::numeric, m.id) as pr) l;
$function$;

create or replace function public._cat_group_cards(p_ids bigint[], p_grps smallint[], p_zone smallint, p_prev smallint, p_lbl_in text, p_lbl_out text)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  select coalesce(jsonb_agg(
    case when p_zone is null or p_grps[c.ord] = 0 then c.val
         else c.val || jsonb_build_object('availability',
                coalesce(c.val->'availability','{}'::jsonb) || jsonb_build_object(
                  'is_available', false,
                  'can_add', false,
                  'blocked_by', 'not_in_zone',
                  'cta_label', public.uic('catalogue.zone_block_note','Not available in your zone'),
                  'note',      public.uic('catalogue.zone_block_note','Not available in your zone'),
                  'cta_short', public.uic('catalogue.zone_block_cta','Not in your zone'),
                  'colors', jsonb_build_object('bg','#F3F4F6','fg','#9CA3AF')))
              || jsonb_build_object('card', public._product_card_unavailable(c.val->'card',
                   public.uic('catalogue.zone_block_cta','Not in your zone')))
    end
    || jsonb_build_object(
         'group', case when p_zone is null then ''
                       when p_grps[c.ord] = 0 then 'in' else 'out' end,
         -- The divider is a property of the ROW that opens a group, so paging
         -- cannot lose it and cannot repeat it.
         'divider_label', case
            when p_zone is null then ''
            when c.ord = 1 and p_prev is distinct from p_grps[1]
              then case when p_grps[1] = 0 then p_lbl_in else p_lbl_out end
            when c.ord > 1 and p_grps[c.ord] is distinct from p_grps[c.ord - 1]
              then case when p_grps[c.ord] = 0 then p_lbl_in else p_lbl_out end
            else '' end)
    order by c.ord), '[]'::jsonb)
  from jsonb_array_elements(public._cat_cards(p_ids)) with ordinality c(val, ord);
$function$;

create or replace function public.storefront_page(category_filter text DEFAULT 'All'::text, page_offset integer DEFAULT 0, page_limit integer DEFAULT NULL::integer)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  WITH cfg AS (
    SELECT
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_initial_limit'), 250) AS initial_limit,
      coalesce((SELECT (value #>> '{}')::int FROM public.app_settings
                  WHERE key = 'storefront_more_limit'), 100) AS more_limit
  ),
  lim AS (
    SELECT greatest(coalesce(nullif(page_limit, 0), (SELECT initial_limit FROM cfg)), 1) AS n
  ),
  disc AS (SELECT public.my_cart_discount_pct() AS pct),
  rows AS (
    SELECT f.*, row_number() over () AS _ord FROM public.get_storefront_feed(
      category_filter, page_offset, (SELECT n FROM lim)) f
  ),
  -- CMD #791 — one scan of order_items for the whole page.
  ov AS (
    SELECT public.purchase_overlay_map(array(SELECT r.id FROM rows r)) AS m
  ),
  -- CMD #2121 — one cart scan + one notify scan for the whole page.
  cq AS (SELECT public._viewer_cart_qty_map(array(SELECT r.id FROM rows r)) AS qm),
  nt AS (SELECT public._viewer_notify_map(array(SELECT r.id FROM rows r)) AS nm),
  n AS (SELECT count(*)::int AS returned FROM rows),
  t AS (SELECT public.get_storefront_count(category_filter)::bigint AS total)
  SELECT jsonb_build_object(
    'status','ok',
    'category', category_filter,
    'sort', 'default',
    'sort_options', public.storefront_sort_options('default'),
    'page_offset', page_offset,
    'page_limit', (SELECT n FROM lim),
    'gated', public.viewer_is_approved_customer(),
    'showing_label', (SELECT r.showing_label FROM rows r LIMIT 1),
    'total', (SELECT total FROM t),
    'count_label', to_char((SELECT total FROM t), 'FM9,99,99,999'),
    'banner_count_label', to_char((SELECT total FROM t), 'FM9,99,99,999') || '+ products',
    'show_all_label', 'Show all ' || to_char((SELECT total FROM t), 'FM9,99,99,999') || ' products',
    'initial_limit', (SELECT initial_limit FROM cfg),
    'more_limit',    (SELECT more_limit FROM cfg),
    'next_offset', page_offset + (SELECT returned FROM n),
    'has_more', (page_offset + (SELECT returned FROM n)) < (SELECT total FROM t),
    'more_label', coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'load_more_products'), ''),
    'end_label',  coalesce((SELECT value FROM public.storefront_ui_label
                              WHERE key = 'feed_end_label'), ''),
    'items', coalesce((
      SELECT jsonb_agg(
        (to_jsonb(r) - '_ord')
        || jsonb_build_object('availability', l.av)
        || jsonb_build_object('pack_badge', public.sf_pack_badge(src.pack_qty, src.pack_size, src.pack_type))
        || jsonb_build_object('type_chip', coalesce(nullif(btrim(src.pack_type),''), nullif(btrim(src.pack_size),''), ''))
        || jsonb_build_object('pack_qty_label',  public.sf_pack_qty_label(src.pack_qty))
        || jsonb_build_object('pack_type_label', public.sf_pack_type_label(src.pack_type))
        || jsonb_build_object('rx', public.rx_badge(src.rx_required))
        || jsonb_build_object('gst_percent_resolved',
             coalesce(r.gst_percent, public.gst_rate_for(r.therapeutic_class)))
        || jsonb_build_object('pricing', l.pr)
        || jsonb_build_object('purchase',
             coalesce((SELECT m -> r.id::text FROM ov), jsonb_build_object('has', false)))
        || jsonb_build_object('card', public._product_card(src, l.pr, l.av,
             coalesce(((SELECT qm FROM cq)->>r.id::text)::int, 0),
             (SELECT nm FROM nt) ? r.id::text))
        ORDER BY r._ord)
      FROM rows r JOIN "MEDICINE" src ON src.id = r.id
      CROSS JOIN LATERAL (SELECT
        public.storefront_cta(public.storefront_effective_count(r.id, r.supplier_count), true) AS av,
        public.storefront_pricing(
             nullif(regexp_replace(coalesce(r.mrp,''), '[^0-9.]', '', 'g'), '')::numeric,
             (SELECT pct FROM disc), r.id) AS pr) l), '[]'::jsonb)
  );
$function$;

create or replace function public.storefront_product(p_product_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $function$
  SELECT jsonb_build_object(
    'status', CASE WHEN m.id IS NULL THEN 'not_found' ELSE 'ok' END,
    'gated', public.viewer_is_approved_customer(),
    'item', CASE WHEN m.id IS NULL THEN NULL
                 ELSE to_jsonb(m)
                      || jsonb_build_object('availability', public.storefront_cta(public.storefront_effective_count(m.id, m.supplier_count)))
                      || jsonb_build_object('pricing', public.storefront_pricing(
                           nullif(regexp_replace(coalesce(m.mrp,''), '[^0-9.]', '', 'g'), '')::numeric, null::numeric, m.id))
                 END,
    -- CMD #2121 — the same universal card every list prints.
    'card', CASE WHEN m.id IS NULL THEN NULL ELSE public.product_card(m.id) END)
  FROM (SELECT * FROM "MEDICINE" WHERE id = p_product_id) m
  RIGHT JOIN (SELECT 1) dummy ON true;
$function$;

-- cart_state: body unchanged; each line gains `card` (qty = that line's qty).
create or replace function public.cart_state(p_guest_uid uuid DEFAULT NULL::uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare v_uid uuid := coalesce(public.viewer_cart_user(), p_guest_uid);
        v_cust uuid := coalesce(public.customer_id_for_user(public.viewer_cart_user()), public.my_customer_id());
        v_items jsonb; v_units int; v_mrp numeric; v_lines int; v_pricing jsonb;
        v_pill jsonb; v_cards jsonb;
begin
  if auth.uid() is not null then v_uid := public.viewer_cart_user(); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ci.id,
           'product_id', coalesce(ci.product_id,''), 'product_name', coalesce(ci.product_name,''),
           'quantity', coalesce(ci.quantity,0), 'mrp', ci.mrp,
           'image_url', coalesce(ci.image_url,''), 'manufacturer', coalesce(ci.manufacturer,''),
           'pack_size', coalesce(ci.pack_size,''),
           'pack_label', coalesce(nullif(btrim(coalesce(mb.pack_label,'')),''),
                                  coalesce(ci.pack_size,'')),
           'added_by', coalesce(ci.added_by,''),
           'category', coalesce(nullif(btrim(ci.category),''),'Other'),
           'added_by_admin', (coalesce(ci.added_by,'') = 'admin'),
           'buyable', coalesce(mb.buyable, false),
           'line_mrp', case when ci.mrp is null then null
                            else round(coalesce(ci.quantity,0) * ci.mrp, 2) end)
           order by ci.id), '[]'::jsonb),
         coalesce(sum(ci.quantity),0),
         coalesce(round(sum(coalesce(ci.quantity,0) * ci.mrp) filter (where ci.mrp is not null), 2),0)
    into v_items, v_units, v_mrp
  from cart_items ci
  left join lateral (
    select m.buyable,
           public.sf_pack_badge(m.pack_qty, m.pack_size, m.pack_type) as pack_label
      from "MEDICINE" m
     where m.id = (case when ci.product_id ~ '^[0-9]+$' then ci.product_id::bigint end)
     limit 1
  ) mb on true
  where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end)
    and coalesce(ci.removed_by_admin,false) = false;

  v_lines := jsonb_array_length(v_items);
  v_pricing := public.cart_pricing_block(v_items);

  begin
    v_pill := public.cart_pill_block(v_items, v_lines);
  exception when others then
    v_pill := null;
  end;

  -- CMD #2121 — the universal card on every line, after pricing/pill read the
  -- plain lines. A card that cannot be built never takes the cart down.
  begin
    v_cards := public.product_cards(array(
      select (e->>'product_id')::bigint from jsonb_array_elements(v_items) e
       where e->>'product_id' ~ '^[0-9]+$'));
    select coalesce(jsonb_agg(i.val || jsonb_build_object('card',
             coalesce((select c || jsonb_build_object(
                         'qty_in_cart', coalesce((i.val->>'quantity')::int, 0),
                         'cta', public._product_card_cta(
                                  (c#>>'{availability,is_available}')::boolean,
                                  (c->>'locked')::boolean,
                                  coalesce((i.val->>'quantity')::int, 0),
                                  (c->>'notified')::boolean,
                                  jsonb_build_object('bg', c#>>'{cta,tone,bg}', 'fg', c#>>'{cta,tone,fg}')))
                         from jsonb_array_elements(v_cards) c
                        where c->>'id' = i.val->>'product_id' limit 1), 'null'::jsonb))
             order by i.ord), '[]'::jsonb)
      into v_items
      from jsonb_array_elements(v_items) with ordinality i(val, ord);
  exception when others then
    null;
  end;

  return jsonb_build_object(
    'items', v_items,
    'admin_removed', '[]'::jsonb,
    'item_count', v_lines,
    'unit_count', v_units,
    'mrp_total', v_mrp,
    'pricing', v_pricing,
    'pill', coalesce(v_pill, 'null'::jsonb),
    'subtotal', (v_pricing->>'taxable')::numeric,
    'net_payable', (v_pricing->>'net_payable')::numeric,
    'customer_id', coalesce(v_cust::text, ''),
    'header', case when v_lines = 1 then '1 product in cart'
                   when v_lines = 0 then 'Your cart is empty'
                   else v_lines::text || ' products in cart' end,
    'badge', case when v_lines > 0 then v_lines::text else '' end,
    'cta_label', case when v_lines > 0
                      then v_lines::text || case when v_lines = 1 then ' item' else ' items' end
                      else '' end,
    'empty_title', 'Your cart is empty',
    'empty_note',  'Add products from the catalog to start an order.'
  );
end $function$;

-- ── grants: internal helpers are not doors; the two public doors are for
--    signed-in viewers (the wrappers above already carry the card to guests) ─
revoke all on function public._viewer_cart_qty_map(bigint[]) from public, anon;
revoke all on function public._viewer_notify_map(bigint[]) from public, anon;
revoke all on function public._product_card_cta(boolean, boolean, integer, boolean, jsonb) from public, anon;
revoke all on function public._product_card(public."MEDICINE", jsonb, jsonb, integer, boolean) from public, anon;
revoke all on function public._product_card_unavailable(jsonb, text) from public, anon;
revoke all on function public.product_cards(bigint[]) from public, anon;
revoke all on function public.product_card(bigint) from public, anon;
grant execute on function public.product_cards(bigint[]) to authenticated, service_role;
grant execute on function public.product_card(bigint) to authenticated, service_role;
