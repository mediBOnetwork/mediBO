-- CHANGE #668 — a synthetic shop must never appear on a real surface.
--
-- #668 gives test.cust1@medibo.in a real pharmacy so the My Shop suite can be
-- PROVEN to work from the credential CLAUDE.md mandates. That shop is marked
-- is_synthetic, and this half is the price of admission: a test pharmacy that a
-- real supplier, a real admin list or the public /near page can see is a worse
-- bug than the gap it closes.
--
-- THE AUDIT (322 functions reference pharmacy_profiles; 11 of them leak):
--   * 61 drive off pharmacy_profiles. Most bind a UNIQUE key — a phone
--     (_notif_owner_for_phone, wa_phone_to_user), a customer code
--     (is_customer_code_taken, next_customer_code), an identity
--     (my_customer_id, login_owner_state) or auth.uid() (_storefront_viewer).
--     Those are not discovery: you already hold the key, and my_customer_id()
--     MUST keep resolving the synthetic row or the test login has no shop.
--   * The rest join pharmacy_profiles off an ORDER, a DELIVERY, a KYC document
--     or a REORDER row (admin_receivables, admin_delivery_queue,
--     admin_reattempt_queue, agency_dispatch_board, admin_bill_pipeline_list,
--     delivery_suggest_partner, fw_list_unfillable, fw_search_bag_items,
--     kyc_review_queue, review_moderation_queue, voice_count_targets,
--     reorder_admin_overview). A synthetic pharmacy reaches those only through
--     a synthetic order, which orders.is_synthetic + _synthetic_inherit already
--     stamp and the existing filters already drop. Outbound is gated one layer
--     lower still, by _synthetic_outbound_gate on whatsapp_messages /
--     wa_campaign_recipients / notification_retry_queue.
--   * What is left is ENUMERATION — a real human handed a list of pharmacies.
--     Those eleven surfaces are fixed below, in the shape universal_search and
--     admin_customers_console already use: `not coalesce(is_synthetic,false)`.
--
-- The two pharmacy-exchange surfaces get a SYMMETRIC filter instead of a flat
-- exclusion: a shop sees counterparties of its own kind. A real shop never sees
-- the test shop, and the synthetic cast can still trade with itself, which is
-- what makes px testable at all. _px_eligible() is deliberately NOT touched —
-- it answers "may I use px", and excluding synthetic there would switch the
-- feature off for the very login this change exists to serve.
--
-- Found while auditing, repaired here (rule: never flag, fix): admin_alert_new_since()
-- raised `column m.created_at does not exist` for EVERY admin, because
-- mr_registrations and company_profiles carry submitted_at. The whole
-- new-registration overlay was dead, and it is the exact surface class this
-- command audits, so it is fixed in the same pass and its supplier / rider /
-- order arms now drop synthetic rows too.
--
-- Idempotent: every statement is CREATE OR REPLACE, and the guard at the foot
-- re-asserts the filter is present rather than trusting the replay.

-- ── near_search ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.near_search(p_q text, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision, p_pincode text DEFAULT NULL::text, p_limit integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.near_config := public._c426_cfg();
  v_bucket text := public._c426_bucket();
  v_rate jsonb; v_q text; v_lat double precision := p_lat; v_lng double precision := p_lng;
  v_lim int := least(coalesce(p_limit, c.max_results), c.max_results);
  v_rows jsonb; v_n int;
begin
  if not c.enabled then
    return jsonb_build_object('ok', false, 'error', 'disabled', 'tone', 'info',
                              'message', public.ui_text('near.disabled'));
  end if;

  v_rate := public._c426_rate_take(v_bucket);
  if not (v_rate->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'tone', 'warning',
                              'retry_after_s', (v_rate->>'retry_after_s')::int,
                              'message', public.ui_text('near.rate_limited'));
  end if;

  v_q := public._norm_name(coalesce(p_q, ''));
  if length(replace(v_q, ' ', '')) < c.min_query_chars then
    return jsonb_build_object('ok', false, 'error', 'short_query', 'tone', 'info',
                              'message', public.ui_text('near.short_query'));
  end if;

  -- Pincode fallback: the centroid of the pharmacies we already know sit in it.
  -- A pincode nobody is mapped to is an honest "we cannot place you", not a
  -- silent search of the whole state.
  if v_lat is null or v_lng is null then
    select avg(p.latitude), avg(p.longitude) into v_lat, v_lng
      from public.pharmacy_profiles p
     where p.pincode = nullif(btrim(coalesce(p_pincode,'')), '')
       and p.latitude is not null and p.longitude is not null
       and coalesce(p.is_deleted, false) = false
       and not coalesce(p.is_synthetic, false);
  end if;
  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'error', 'need_origin', 'tone', 'info',
                              'message', public.ui_text('near.need_origin'));
  end if;

  with med as (
    select m.id, m.product_name
      from public."MEDICINE" m
     where public._norm_name(m.product_name) % v_q
     order by similarity(public._norm_name(m.product_name), v_q) desc
     limit c.max_medicines
  ),
  shops as (
    select p.id, p.latitude, p.longitude, p.city, p.district, p.phone,
           coalesce(nullif(btrim(n.display_name), ''), p.pharmacy_name) as name,
           n.show_phone, t.token,
           public._c426_km(v_lat, v_lng, p.latitude, p.longitude) as km
      from public.near_listing_config n
      join public.pharmacy_profiles p on p.id = n.pharmacy_id
      left join public.near_poster   t on t.pharmacy_id = n.pharmacy_id
     where n.opted_in
       and coalesce(p.is_deleted, false) = false
       and not coalesce(p.is_synthetic, false)
       and p.latitude is not null and p.longitude is not null
       and public._c426_km(v_lat, v_lng, p.latitude, p.longitude) <= c.max_km
  ),
  live as (
    select i.pharmacy_id, i.medicine_id, max(i.confidence) as confidence
      from public.pharmacy_lot_inference i
      join shops s   on s.id  = i.pharmacy_id
      join med   mm  on mm.id = i.medicine_id
     where i.inferred_left > 0
       and i.confidence >= c.min_confidence
       and (i.expiry_on is null or i.expiry_on > current_date)
       -- A pharmacy that answered "0 left" is off this list at once, whatever
       -- the model still believes about that lot.
       and coalesce((select cc.actual_left
                       from public.pharmacy_lot_correction cc
                      where cc.lot_id = i.lot_id
                      order by cc.created_at desc
                      limit 1), 1) > 0
       -- …and so is one that tapped "mark unavailable".
       and not exists (select 1 from public.near_unavailable u
                        where u.pharmacy_id = i.pharmacy_id
                          and u.medicine_id = i.medicine_id
                          and u.until > now())
     group by 1, 2
  ),
  best as (
    select s.id, s.name, s.km, s.city, s.district, s.phone, s.show_phone,
           s.token, s.latitude, s.longitude,
           max(l.confidence) as confidence,
           (array_agg(mm.product_name order by l.confidence desc))[1] as matched
      from live l
      join shops s  on s.id  = l.pharmacy_id
      join med  mm  on mm.id = l.medicine_id
     group by s.id, s.name, s.km, s.city, s.district, s.phone, s.show_phone,
              s.token, s.latitude, s.longitude
  )
  select jsonb_agg(row_to_json(x)::jsonb order by x.rank), count(*)
    into v_rows, v_n
  from (
    select b.token as ref,
           b.name,
           b.matched as matched_label,
           coalesce(nullif(btrim(b.city), ''), nullif(btrim(b.district), '')) as area_label,
           public.ui_text_f('near.distance_label',
             jsonb_build_object('km', to_char(b.km, 'FM999990.0'))) as distance_label,
           public._c426_tier(b.confidence) as tier,
           jsonb_build_object(
             'has',   b.show_phone and coalesce(nullif(btrim(b.phone), ''), '') <> '',
             'label', public.ui_text('near.call_button'),
             'tel',   case when b.show_phone then nullif(btrim(b.phone), '') end) as call,
           jsonb_build_object(
             'has',   public._c426_dir_url(b.latitude, b.longitude) is not null,
             'label', public.ui_text('near.directions_button'),
             'url',   public._c426_dir_url(b.latitude, b.longitude)) as directions,
           -- confidence x distance decay. Ranking only; the NUMBER never
           -- reaches the consumer, only the tier sentence it chose.
           row_number() over (
             order by (b.confidence / (1 + b.km / 2)) desc, b.km asc) as rank
      from best b
     order by rank
     limit v_lim
  ) x;

  v_n := coalesce(v_n, 0);

  insert into public.near_search_log (bucket, q_norm, had_origin, result_count)
  values (v_bucket, v_q, true, v_n);

  return jsonb_build_object(
    'ok', true,
    'query', v_q,
    'count', v_n,
    'count_label', case when v_n = 1 then public.ui_text_f('near.results_label',
                            jsonb_build_object('n', v_n))
                        else public.ui_text_f('near.results_label_p',
                            jsonb_build_object('n', v_n)) end,
    'empty_label', public.ui_text('near.no_results'),
    'empty_hint',  public.ui_text('near.no_results_hint'),
    'disclaimer',  public.ui_text('near.disclaimer'),
    'rx_note',     public.ui_text('near.rx_note'),
    'rows', coalesce(v_rows, '[]'::jsonb));
end $function$

;

-- ── near_pharmacy ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.near_pharmacy(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rate jsonb; r record;
begin
  v_rate := public._c426_rate_take(public._c426_bucket());
  if not (v_rate->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'error', 'rate_limited', 'tone', 'warning',
                              'message', public.ui_text('near.rate_limited'));
  end if;

  select coalesce(nullif(btrim(n.display_name), ''), p.pharmacy_name) as name,
         p.city, p.district, p.phone, p.latitude, p.longitude, n.show_phone
    into r
    from public.near_poster t
    join public.near_listing_config n on n.pharmacy_id = t.pharmacy_id
    join public.pharmacy_profiles   p on p.id = t.pharmacy_id
   where t.token = nullif(btrim(coalesce(p_token, '')), '')
     and n.opted_in
     and coalesce(p.is_deleted, false) = false
     and not coalesce(p.is_synthetic, false);

  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'tone', 'info',
                              'message', public.ui_text('near.pharmacy_not_found'));
  end if;

  return jsonb_build_object(
    'ok', true,
    'name', r.name,
    'badge', public.ui_text('near.listing_title'),
    'area_label', coalesce(nullif(btrim(r.city), ''), nullif(btrim(r.district), '')),
    'search_hint', public.ui_text('near.search_hint'),
    'disclaimer', public.ui_text('near.disclaimer'),
    'call', jsonb_build_object(
      'has',   r.show_phone and coalesce(nullif(btrim(r.phone), ''), '') <> '',
      'label', public.ui_text('near.call_button'),
      'tel',   case when r.show_phone then nullif(btrim(r.phone), '') end),
    'directions', jsonb_build_object(
      'has',   public._c426_dir_url(r.latitude, r.longitude) is not null,
      'label', public.ui_text('near.directions_button'),
      'url',   public._c426_dir_url(r.latitude, r.longitude)));
end $function$

;

-- ── admin_list_customers ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_list_customers(p_search text DEFAULT ''::text)
 RETURNS TABLE(id uuid, display_name text, email text, city text, user_id uuid, approved boolean, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_q text := coalesce(btrim(p_search), '');
begin
  if get_my_role() <> 'super_admin' then RETURN; end if;
  return query
  select pp.id,
         coalesce(nullif(btrim(pp.customer_name),''),
                  nullif(btrim(pp.pharmacy_name),''), 'Unnamed') as display_name,
         coalesce(pp.email,  '') as email,
         coalesce(pp.city,   '') as city,
         pp.user_id,
         coalesce(pp.approved, false) as approved,
         coalesce(pp.status,  '')     as status
  from pharmacy_profiles pp
  where (pp.is_deleted is null or pp.is_deleted = false)
    and not coalesce(pp.is_synthetic,false)
    and (v_q = ''
         or coalesce(pp.customer_name,'')  ilike '%' || v_q || '%'
         or coalesce(pp.pharmacy_name,'')  ilike '%' || v_q || '%'
         or coalesce(pp.email,'')          ilike '%' || v_q || '%')
  order by display_name
  limit 100;
end $function$

;

-- ── admin_customer_screen_data ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_customer_screen_data(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := coalesce(public.role_for_medibo_only(),'none');
  b jsonb; v_start timestamptz; v_end timestamptz;
  v_zone smallint := public.admin_active_zone();
begin
  if v_role not in ('admin','super_admin') then return jsonb_build_object('allowed', false); end if;
  b := public.ist_day_bounds(coalesce(p_date, public.admin_active_date()));
  v_start := (b->>'start_utc')::timestamptz;
  v_end   := (b->>'end_utc')::timestamptz;

  return jsonb_build_object(
    'zone_id', v_zone,
    'zone_label', coalesce((select name from zones where id = v_zone),'All zones'),
    'user_profiles', coalesce((select jsonb_agg(to_jsonb(t)) from user_profiles t), '[]'::jsonb),
    'profiles', coalesce((
      select jsonb_agg(to_jsonb(pp)) from pharmacy_profiles pp
      where coalesce(pp.is_deleted,false) = false
        and not coalesce(pp.is_synthetic,false)
        and (v_zone is null or pp.zone_id = v_zone)), '[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(
        to_jsonb(o)
        || public.money_display_block(to_jsonb(o), array['total_amount'])
        || jsonb_build_object(
             'has_total', (coalesce(o.total_amount,0) > 0),
             'items', coalesce((
                select jsonb_agg(it || public.money_display_block(it,
                         array['mrp','price','line_total']))
                from jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) it), '[]'::jsonb))
        order by o.created_at desc) from orders o
      where o.created_at >= v_start and o.created_at < v_end
        and (v_zone is null or o.zone_id = v_zone)), '[]'::jsonb),
    'cart_items', coalesce((
      select jsonb_agg(to_jsonb(ci)
        || jsonb_build_object('added_by_badge', public.added_by_badge(ci.added_by))
        || public.money_display_block(to_jsonb(ci), array['mrp','price'])
        order by ci.id) from cart_items ci
      where ci.customer_id is not null
        and (v_zone is null or exists (
              select 1 from pharmacy_profiles pp
               where pp.id = ci.customer_id and pp.zone_id = v_zone))), '[]'::jsonb),
    'deleted', coalesce((
      select jsonb_agg(to_jsonb(pp) order by pp.deleted_at desc) from pharmacy_profiles pp
      where pp.is_deleted = true
        and not coalesce(pp.is_synthetic,false)
        and (v_zone is null or pp.zone_id = v_zone)), '[]'::jsonb),
    'leads', coalesce((select jsonb_agg(to_jsonb(l)) from leads l), '[]'::jsonb),
    'admins', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'email', a.email)) from admins a), '[]'::jsonb),
    'cart_totals', coalesce((
      select jsonb_object_agg(t.cid::text, public.cart_totals_for(t.cid))
      from (select distinct ci.customer_id cid from cart_items ci
             where ci.customer_id is not null
               and coalesce(ci.removed_by_admin,false) = false
               and (v_zone is null or exists (
                     select 1 from pharmacy_profiles pp
                      where pp.id = ci.customer_id and pp.zone_id = v_zone))) t), '{}'::jsonb),
    'cart_footer', (
      select jsonb_build_object(
        'total_customers', count(distinct ci.customer_id),
        'total_lines', count(*),
        'total_value', coalesce(sum(round(coalesce(ci.quantity,0)*coalesce(ci.mrp,0),2)),0),
        'total_value_display', public.inr_money(
          coalesce(sum(round(coalesce(ci.quantity,0)*coalesce(ci.mrp,0),2)),0)))
      from cart_items ci where coalesce(ci.removed_by_admin,false) = false
        and (v_zone is null or exists (
              select 1 from pharmacy_profiles pp
               where pp.id = ci.customer_id and pp.zone_id = v_zone))),
    'day_start_utc', coalesce(b->>'start_utc',''),
    'day_end_utc',   coalesce(b->>'end_utc',''));
end $function$

;

-- ── admin_missing_locations ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_missing_locations()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_missing int; v_total int;
        s_rows jsonb; s_missing int; s_total int;
begin
  if get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('allowed',false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'pharmacy_id',pp.id,'pharmacy_name',coalesce(pp.pharmacy_name,''),
           'address',coalesce(pp.address,''),'pincode',coalesce(pp.pincode,''),
           'phone',coalesce(pp.phone,''),
           'open_orders',(select count(*) from orders o where o.customer_id=pp.id
                            and coalesce(o.status,'') not in ('cancelled'))) order by pp.pharmacy_name),
         '[]'::jsonb),
         count(*)
    into v_rows, v_missing
  from pharmacy_profiles pp
  where coalesce(pp.is_deleted,false)=false and not coalesce(pp.is_synthetic,false)
    and (pp.latitude is null or pp.longitude is null);

  select count(*) into v_total from pharmacy_profiles
   where coalesce(is_deleted,false)=false and not coalesce(is_synthetic,false);

  select coalesce(jsonb_agg(jsonb_build_object(
           'supplier_id', sp.id,
           'supplier_name', coalesce(sp.supplier_name,''),
           'address', btrim(coalesce(nullif(sp.address,''), sp.street_address, '')),
           'pincode', coalesce(nullif(sp.pin_code,''), sp.pincode, ''),
           'phone', coalesce(nullif(sp.phone,''), sp.contact_no, ''),
           'geocode_status', coalesce(sp.geocode_status,'never')) order by sp.supplier_name),
         '[]'::jsonb),
         count(*)
    into s_rows, s_missing
  from supplier_profiles sp
  where coalesce(sp.is_deleted,false)=false and coalesce(sp.approved,false)=true
    and (sp.lat is null or sp.lng is null);

  select count(*) into s_total from supplier_profiles
   where coalesce(is_deleted,false)=false and coalesce(approved,false)=true;

  return jsonb_build_object('allowed',true,
    'missing_count',coalesce(v_missing,0),'total',coalesce(v_total,0),
    'title', public._cf('missing_loc_customers_title',
               jsonb_build_object('n',coalesce(v_missing,0)::text,'total',coalesce(v_total,0)::text)),
    'note', public._c('missing_loc_customers_note'),
    'rows', v_rows,
    'supplier_missing_count', coalesce(s_missing,0),
    'supplier_total', coalesce(s_total,0),
    'supplier_title', public._cf('missing_loc_suppliers_title',
               jsonb_build_object('n',coalesce(s_missing,0)::text,'total',coalesce(s_total,0)::text)),
    'supplier_note', public._c('missing_loc_suppliers_note'),
    'supplier_rows', s_rows);
end $function$

;

-- ── customer_credit_list ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.customer_credit_list(p_q text DEFAULT NULL::text, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_admin');
  end if;
  select coalesce(jsonb_agg(x order by (x->>'outstanding')::numeric desc), '[]'::jsonb) into v
  from (
    select public.customer_credit_state(pp.id)
           || jsonb_build_object('customer_id', pp.id,
                                 'customer_name', coalesce(nullif(btrim(pp.pharmacy_name),''),
                                                           nullif(btrim(pp.customer_name),''), '')) as x
      from public.pharmacy_profiles pp
     where coalesce(pp.is_deleted,false) = false
       and not coalesce(pp.is_synthetic,false)
       and (p_q is null or btrim(p_q) = ''
            or pp.pharmacy_name ilike '%'||p_q||'%'
            or pp.customer_name ilike '%'||p_q||'%')
       and exists (select 1 from public.orders o where o.customer_id = pp.id)
     limit greatest(coalesce(p_limit,30),1)
  ) s;
  return jsonb_build_object('ok', true, 'items', v);
end $function$

;

-- ── nav_search ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.nav_search(p_q text, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role    text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_q       text := btrim(coalesce(p_q,''));
  v_like    text;
  v_groups  jsonb := '[]'::jsonb;
  v_part    jsonb;
  v_lim     int  := least(greatest(coalesce(p_limit,6),1), 20);
  -- CHANGE #570 QA round 2 — the entity groups' doors, resolved once. The
  -- `screens` group below is gated row by row; these three groups list ORDERS,
  -- CUSTOMERS and SUPPLIERS, and every one of their rows opens the same three
  -- features, so the answer is fetched once rather than per row.
  v_can_360  boolean;
  v_can_cust boolean;
  v_can_supp boolean;
begin
  if v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'message', 'Admins only.', 'groups', '[]'::jsonb);
  end if;
  if length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'query', v_q, 'groups', '[]'::jsonb,
      'hint', 'Type at least two characters.',
      'empty_label', 'Type at least two characters.');
  end if;
  v_like := '%' || lower(v_q) || '%';

  v_can_360  := coalesce(public.admin_access('admin.customer_360'),'none') <> 'none';
  v_can_cust := coalesce(public.admin_access('admin.customers'),'none') <> 'none';
  v_can_supp := coalesce(public.admin_access('admin.suppliers'),'none') <> 'none';

  select jsonb_agg(x order by rank, sort_order) into v_part from (
    select f.sort_order,
           case when lower(f.label) = lower(v_q) then 0
                when lower(f.label) like lower(v_q) || '%' then 1 else 2 end as rank,
           jsonb_build_object(
             'kind','screen', 'title', f.label, 'subtitle', c.label,
             'icon_key', f.icon_key, 'icon_letter', upper(left(f.label,1)),
             'route_key', f.route_key,
             'deep_link', f.deep_link, 'feature_key', f.feature_key,
             'seed', null) as x
      -- CHANGE #1016 — ONE visibility predicate (_staff_visible) shared with
      -- nav_registry() and staff_home(); alias rows are never offered.
      from public._staff_visible() f
      join nav_category c on c.category_key = f.category
     where f.surface in ('dashboard','both')
       and (lower(f.label) like v_like or lower(coalesce(f.search_terms,'')) like v_like
            or lower(c.label) like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','screens','label','Screens','items', v_part));
  end if;

  select jsonb_agg(x order by rank, sort_order) into v_part from (
    select f.sort_order,
           case when lower(f.label) = lower(v_q) then 0
                when lower(f.label) like lower(v_q) || '%' then 1 else 2 end as rank,
           jsonb_build_object(
             'kind','dev_tool', 'title', f.label,
             'subtitle', coalesce(nullif(f.description,''), f.group_label),
             'icon_key', f.icon_key, 'icon_letter', upper(left(f.label,1)),
             'route_key', f.route_key, 'tool_key', f.route_key,
             'deep_link', null, 'feature_key', f.feature_key,
             'seed', null) as x
      from feature_registry f
     where f.is_active and f.surface = 'dev_tools'
       and v_role = any (f.roles_allowed)
       and (lower(f.label) like v_like or lower(coalesce(f.search_terms,'')) like v_like
            or lower(coalesce(f.description,'')) like v_like
            or lower(coalesce(f.group_label,'')) like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','dev_tools','label','Dev Queue tools','items', v_part));
  end if;

  -- An order now carries its pharmacy's id, so picking an order from the
  -- palette opens that pharmacy's 360 view — "reachable from any order".
  select jsonb_agg(x order by created_at desc) into v_part from (
    select o.created_at, jsonb_build_object(
             'kind','order', 'title', coalesce(o.order_code, 'Order #' || o.id),
             'subtitle', coalesce(o.pharmacy_name,'') || ' · ' || coalesce(o.status,''),
             'icon_key','receipt', 'icon_letter','O',
             -- CHANGE #570 QA round 2 — an entity row is a DOOR onto a
             -- feature, so it carries the caller's access to that feature, not
             -- just the row's existence. A reader denied admin.customer_360
             -- lands on admin.customers; denied both, the row carries no door
             -- at all rather than a deep link into a screen that will refuse.
             'route_key', case when pp.id is not null and v_can_360 then 'customer_360'
                               when v_can_cust then 'customers' end,
             'deep_link', case when pp.id is not null and v_can_360
                               then '/admin/go/customer_360/' || pp.id::text
                               when v_can_cust then '/admin/go/customers' end,
             'feature_key', case when pp.id is not null and v_can_360 then 'admin.customer_360'
                                 when v_can_cust then 'admin.customers' end,
             'seed', coalesce(pp.id::text, o.order_code, o.pharmacy_name)) as x
      from orders o
      left join lateral (
        select p.id from pharmacy_profiles p
         where (o.customer_id is not null and p.id = o.customer_id)
            or (o.customer_id is null and p.user_id = o.user_id)
         limit 1) pp on true
     where lower(coalesce(o.order_code,'')) like v_like
        or lower(coalesce(o.pharmacy_name,'')) like v_like
     order by o.created_at desc limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','orders','label','Orders','items', v_part));
  end if;

  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','customer',
             'title', coalesce(nullif(btrim(p.pharmacy_name),''), p.customer_name, 'Customer'),
             'subtitle', coalesce(p.city,'') ||
                         case when coalesce(p.approved,false) then '' else ' · pending approval' end,
             'icon_key','people', 'icon_letter','C',
             'route_key', case when v_can_360 then 'customer_360' end,
             'deep_link', case when v_can_360
                               then '/admin/go/customer_360/' || p.id::text end,
             'feature_key', case when v_can_360 then 'admin.customer_360' end,
             'seed', p.id::text) as x
      from pharmacy_profiles p
     where coalesce(p.is_deleted,false) = false
       and not coalesce(p.is_synthetic,false)
       and (lower(coalesce(p.pharmacy_name,'')) like v_like
            or lower(coalesce(p.customer_name,'')) like v_like
            or lower(coalesce(p.customer_code,'')) like v_like
            or coalesce(p.phone,'') like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','customers','label','Customers','items', v_part));
  end if;

  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','supplier', 'title', s.supplier_name,
             'subtitle', coalesce(s.city,''),
             'icon_key','inventory', 'icon_letter','S',
             'route_key', case when v_can_supp then 'suppliers' end,
             'deep_link', case when v_can_supp then '/admin/go/suppliers' end,
             'feature_key', case when v_can_supp then 'admin.suppliers' end,
             'seed', s.supplier_name) as x
      from supplier_profiles s
     where coalesce(s.is_deleted,false) = false
       and (lower(coalesce(s.supplier_name,'')) like v_like
            or lower(coalesce(s.supplier_code,'')) like v_like
            or coalesce(s.phone,'') like v_like)
     limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','suppliers','label','Suppliers','items', v_part));
  end if;

  select jsonb_agg(x) into v_part from (
    select jsonb_build_object(
             'kind','medicine', 'title', m.product_name,
             'subtitle', coalesce(m.marketer_canonical, ''),
             'icon_key','medication', 'icon_letter','M', 'route_key','search',
             'deep_link', null, 'feature_key', null,
             'seed', m.product_name) as x
      from "MEDICINE" m
     where m.product_name ilike v_like
     order by m.sales_count desc nulls last limit v_lim
  ) s;
  if v_part is not null then
    v_groups := v_groups || jsonb_build_array(
      jsonb_build_object('key','medicines','label','Medicines','items', v_part));
  end if;

  return jsonb_build_object('ok', true, 'query', v_q, 'groups', v_groups,
    'empty_label', coalesce(
      (select value #>> '{}' from ui_copy where key = 'nav.empty_search'),
      'Nothing matched.'));
end $function$

;

-- ── admin_alert_new_since ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_alert_new_since(p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_since timestamptz := coalesce(p_since, now() - interval '10 minutes');
        v_lim int := least(greatest(coalesce(p_limit,25),1),50);
        v_rows jsonb;
begin
  if coalesce(public.get_my_role(),'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
                              'rows', '[]'::jsonb, 'server_time', now());
  end if;

  -- one union, one order, one limit — the overlay renders in payload order
  select coalesce(jsonb_agg(u.x order by u.created_at), '[]'::jsonb) into v_rows
  from (
   select q.created_at, q.x from (
    select p.created_at,
           jsonb_build_object('kind','new_registration','id',p.id::text,'row',to_jsonb(p)) as x
      from pharmacy_profiles p
     where p.created_at > v_since and coalesce(p.approved,false) = false
       and coalesce(p.status,'') in ('','pending')
       and not coalesce(p.is_synthetic,false)
    union all
    select s.created_at,
           jsonb_build_object('kind','new_supplier','id',s.id::text,'row',to_jsonb(s))
      from supplier_profiles s
     where s.created_at > v_since and coalesce(s.approved,false) = false
       and coalesce(s.status,'') in ('','pending')
       and not coalesce(s.is_synthetic,false)
    union all
    -- CHANGE #668: mr_registrations has submitted_at, not created_at. This
    -- arm raised 'column m.created_at does not exist' for EVERY admin, so
    -- the whole new-registration overlay was dead, not just this row.
    select m.submitted_at,
           jsonb_build_object('kind','mr_registration','id',m.id::text,'row',to_jsonb(m))
      from mr_registrations m
     where m.submitted_at > v_since
    union all
    -- ...and company_profiles is submitted_at too, for the same reason.
    select c.submitted_at,
           jsonb_build_object('kind','company_registration','id',c.id::text,'row',to_jsonb(c))
      from company_profiles c
     where c.submitted_at > v_since
    union all
    select d.created_at,
           jsonb_build_object('kind','dp_registration','id',d.id::text,'row',to_jsonb(d))
      from delivery_partner_registrations d
     where d.created_at > v_since
       and not coalesce(d.is_synthetic,false)
    union all
    select o.created_at,
           jsonb_build_object('kind','new_order','id',o.id::text,'row',to_jsonb(o))
      from orders o
     where o.created_at > v_since
       and not coalesce(o.is_synthetic,false)
       and coalesce(o.status,'') in ('','pending')
   ) q
   where q.created_at is not null
   order by q.created_at desc
   limit v_lim
  ) u;

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'count', jsonb_array_length(v_rows),
    'since', v_since,
    'server_time', now());
end $function$

;

-- ── admin_claim_queue ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_claim_queue(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_open int; v_oldest int; v_no_utr int; v_sum numeric;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_agg(x order by (x->>'age_days')::int desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'claim_id',      pc.id,
      'amount_label',  public.inr_money(pc.amount),
      'sender_phone',  pc.sender_phone,
      'customer_name', coalesce(pp.pharmacy_name, 'Unknown sender'),
      'order_code',    coalesce(nullif(btrim(o.order_code),''), ''),
      'linked',        pc.order_id is not null,
      'link_label',    case when pc.order_id is null then 'Not attached to an order'
                            else coalesce(nullif(btrim(o.order_code),''), 'Attached') end,
      'link_tone',     case when pc.order_id is null then 'bad' else 'muted' end,
      'age_days',      public._c450_age_days(pc.received_at),
      'age_label',     public._c450_age_label(pc.received_at),
      'age_tone',      public._c450_age_tone(public._c450_age_days(pc.received_at)),
      'received_label','Received ' || to_char(pc.received_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
      -- The point of the row: a missing UTR is a STATE, never a blank field.
      'utr',           pc.utr,
      'has_utr',       coalesce(nullif(btrim(pc.utr),'') is not null, false),
      'utr_label',     coalesce(nullif(btrim(pc.utr),''), 'No UTR on this claim'),
      'utr_tone',      case when nullif(btrim(pc.utr),'') is null then 'bad' else 'good' end,
      'utr_detail',    case when nullif(btrim(pc.utr),'') is null
                            then 'Without the bank reference this payment cannot be matched to the statement.'
                            else '' end,
      'can_ask_utr',   nullif(btrim(pc.utr),'') is null
                         and coalesce(nullif(btrim(pc.sender_phone),'') is not null, false),
      'ask_utr_label', 'Ask for the UTR',
      'has_proof',     pc.raw_ocr is not null,
      'proof_label',   case when pc.raw_ocr is null then 'No screenshot read' else 'Screenshot read' end,
      'status',        pc.status,
      'status_label',  case pc.status when 'received' then 'Waiting to be verified'
                                      when 'verified' then 'Verified'
                                      else initcap(coalesce(pc.status,'unknown')) end
    ) as x
    from payment_claims pc
    left join orders o on o.id = pc.order_id
    left join lateral (
      select p.pharmacy_name from pharmacy_profiles p
       where right(regexp_replace(coalesce(p.whatsapp_no, p.phone,''),'\D','','g'),10)
           = right(regexp_replace(coalesce(pc.sender_phone,''),'\D','','g'),10)
         and coalesce(p.is_deleted,false) = false
         and not coalesce(p.is_synthetic,false)
       limit 1
    ) pp on true
    where pc.status = 'received'
    order by pc.received_at asc
    limit greatest(1, coalesce(p_limit,100))
  ) q;

  select count(*)::int,
         coalesce(max(public._c450_age_days(received_at)),0),
         count(*) filter (where nullif(btrim(utr),'') is null)::int,
         coalesce(sum(amount),0)
    into v_open, v_oldest, v_no_utr, v_sum
    from payment_claims where status = 'received';

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'count', v_open,
    'headline', case when v_open = 0 then 'Nothing waiting to be verified'
                     when v_open = 1 then '1 payment waiting to be verified'
                     else v_open || ' payments waiting to be verified' end,
    'value_label', public.inr_money(v_sum),
    'oldest_label', case when v_open = 0 then ''
                         else 'Oldest has waited ' || v_oldest ||
                              case when v_oldest = 1 then ' day' else ' days' end end,
    'oldest_tone', public._c450_age_tone(v_oldest),
    'utr_gap_label', case when v_no_utr = 0 then ''
                          when v_no_utr = 1 then '1 of them has no UTR'
                          else v_no_utr || ' of them have no UTR' end,
    'empty_label', 'Every payment that arrived has been verified.',
    'note', 'Oldest first — the longest wait is always the first card.');
end $function$

;

-- ── khata_admin_overview ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.khata_admin_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb;
begin
  if not public.am_i_super() then
    return jsonb_build_object('ok', false, 'error', 'denied');
  end if;
  select coalesce(jsonb_agg(x order by (x->>'outstanding')::numeric desc), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'pharmacy', coalesce(pp.pharmacy_name, pp.customer_name),
      'accounts', count(a.*),
      'due_accounts', count(*) filter (where a.balance > 0),
      'outstanding', coalesce(sum(a.balance) filter (where a.balance > 0), 0),
      'outstanding_display', public.inr_money(coalesce(sum(a.balance) filter (where a.balance > 0), 0))) x
      from public.khata_account a
      join public.pharmacy_profiles pp on pp.id = a.pharmacy_id
     where not coalesce(pp.is_synthetic,false)
     group by pp.id, pp.pharmacy_name, pp.customer_name
  ) q;
  return jsonb_build_object('ok', true, 'title', public.ui_text('khata.admin_title'),
    'note', public.ui_text('khata.admin_note'), 'rows', v_rows);
end $function$

;

-- ── _px_browse ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._px_browse(p_shop uuid, p_q text DEFAULT NULL::text, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg public.px_config%rowtype := public._px_config();
  v_q text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb;
begin
  if not public._px_eligible(p_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible',
      'message', public.ui_text('px.err_not_eligible'));
  end if;

  select coalesce(jsonb_agg(x order by (x->>'expiry_on') nulls last), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'listing_id', l.id,
      'product_name', l.product_name,
      'pack_label', l.pack_label,
      'seller_name', coalesce(sp.pharmacy_name, sp.customer_name),
      'qty_label', public.ui_fmt('px.qty_available',
                     jsonb_build_object('n', to_char(l.qty_remaining,'FM999990.##'))),
      'qty_remaining', l.qty_remaining,
      'price_display', public.inr_money(l.unit_price),
      'mrp_display', case when l.mrp is null then null else public.inr_money(l.mrp) end,
      'batch_label', public.ui_fmt('px.batch_label',
                       jsonb_build_object('batch', coalesce(l.batch_no,'-'))),
      'expiry_label', public.ui_fmt('px.expiry_label',
                       jsonb_build_object('expiry', coalesce(l.expiry,'-'))),
      'expiry_on', l.expiry_on,
      'days_label', case when l.expiry_on is null then public.ui_text('px.expiry_unknown')
                        else public.ui_fmt('px.days_left',
                               jsonb_build_object('n', (l.expiry_on - public._px_today())::text)) end,
      'tone', case when l.expiry_on is null then 'info'
                   when l.expiry_on - public._px_today() <= 60 then 'danger'
                   when l.expiry_on - public._px_today() <= 120 then 'warning'
                   else 'info' end,
      'disclosure', public._px_disclosure_text(l.product_name, l.batch_no, l.expiry, l.expiry_on),
      'note', l.note,
      'distance_hint', case when public._px_crow_km(p_shop, l.seller_id) is null then null
            else public.ui_fmt('px.distance_approx',
                   jsonb_build_object('km', to_char(public._px_crow_km(p_shop, l.seller_id),'FM990.0'))) end
    ) x
    from public.px_listing l
    join public.pharmacy_profiles sp on sp.id = l.seller_id
   where l.status = 'active' and l.qty_remaining > 0
     and l.seller_id <> p_shop
     and l.zone_id = (select zone_id from public.pharmacy_profiles where id = p_shop)
     and public._px_eligible(l.seller_id)
     and coalesce(sp.is_synthetic,false)
         = coalesce((select pp2.is_synthetic from public.pharmacy_profiles pp2
                      where pp2.id = p_shop), false)
     and (l.expiry_on is null or l.expiry_on > public._px_today())
     and coalesce(l.note,'') <> public.ui_text('px.borrow_note')
     and (v_q is null or l.product_name ilike '%'||v_q||'%')
   limit least(greatest(coalesce(p_limit,60),1), 200)
  ) q;

  return jsonb_build_object('ok', true,
    'labels', jsonb_build_object(
      'title',      public.ui_text('px.browse_title'),
      'subtitle',   public.ui_text('px.browse_subtitle'),
      'search_hint',public.ui_text('px.search_hint'),
      'buy',        public.ui_text('px.buy_button'),
      'list_stock', public.ui_text('px.list_button'),
      'borrow',     public.ui_text('px.borrow_title'),
      'retry',      public.ui_text('px.retry'),
      'load_failed',public.ui_text('px.load_failed'),
      'cancel',     public.ui_text('px.cancel'),
      'qty',        public.ui_text('px.qty_label'),
      'confirm',    public.ui_text('px.confirm_button')),
    'fee_note', case when coalesce(cfg.fee_percent,0) = 0
                     then public.ui_text('px.fee_zero')
                     else public.ui_fmt('px.fee_note',
                            jsonb_build_object('pct', to_char(cfg.fee_percent,'FM990.##'))) end,
    'disclosure_note', public.ui_text('px.disclosure_note'),
    'rows', v_rows,
    'empty', jsonb_build_object(
      'title', public.ui_text('px.browse_empty'),
      'hint',  public.ui_text('px.browse_empty_hint')));
end $function$

;

-- ── _px_borrow_search ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._px_borrow_search(p_shop uuid, p_q text, p_qty numeric DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg public.px_config%rowtype := public._px_config();
  v_q text := nullif(btrim(coalesce(p_q,'')),'');
  v_rows jsonb; v_zone smallint;
  v_labels jsonb := jsonb_build_object(
      'title',       public.ui_text('px.borrow_title'),
      'subtitle',    public.ui_text('px.borrow_subtitle'),
      'search_hint', public.ui_text('px.borrow_search_hint'),
      'request',     public.ui_text('px.request_button'),
      'qty',         public.ui_text('px.qty_label'),
      'cancel',      public.ui_text('px.cancel'),
      'retry',       public.ui_text('px.retry'),
      'load_failed', public.ui_text('px.load_failed'));
begin
  if not public._px_eligible(p_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible',
      'message', public.ui_text('px.err_not_eligible'));
  end if;

  if v_q is null or length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb,
      'labels', v_labels,
      'privacy_note', public.ui_text('px.privacy_note'),
      'hint', public.ui_text('px.borrow_hint'),
      'empty', jsonb_build_object(
        'title', public.ui_text('px.borrow_empty'),
        'hint',  public.ui_text('px.borrow_empty_hint')));
  end if;

  select zone_id into v_zone from public.pharmacy_profiles where id = p_shop;

  select coalesce(jsonb_agg(x order by (x->>'km')::numeric nulls last), '[]'::jsonb)
    into v_rows
  from (
    select jsonb_build_object(
      'pharmacy_id', ps.pharmacy_id,
      'stock_id',    ps.id,
      'seller_name', coalesce(sp.pharmacy_name, sp.customer_name),
      'product_name', ps.product_name,
      'pack_label',  ps.pack_label,
      'batch_label', public.ui_fmt('px.batch_label',
                       jsonb_build_object('batch', coalesce(nullif(btrim(ps.batch_no),''),'-'))),
      'expiry_label', public.ui_fmt('px.expiry_label',
                       jsonb_build_object('expiry', coalesce(nullif(btrim(ps.expiry),''),'-'))),
      -- the ONE fact about their shelf that leaves this function
      'has_enough',  ps.qty >= coalesce(p_qty,1),
      'price_display', public.inr_money(coalesce(ps.mrp, ps.unit_cost)),
      'price_basis', case when ps.mrp is not null then public.ui_text('px.at_mrp')
                          else public.ui_text('px.at_agreed') end,
      'km', public._px_crow_km(p_shop, ps.pharmacy_id),
      'distance_hint', case when public._px_crow_km(p_shop, ps.pharmacy_id) is null then null
            else public.ui_fmt('px.distance_approx',
                   jsonb_build_object('km', to_char(public._px_crow_km(p_shop, ps.pharmacy_id),'FM990.0'))) end,
      'promise_label', public.ui_fmt('px.promise_label',
                         jsonb_build_object('min', cfg.borrow_promise_min::text))
    ) x
    from public.pharmacy_stock ps
    join public.pharmacy_profiles sp on sp.id = ps.pharmacy_id
   where ps.pharmacy_id <> p_shop
     and sp.zone_id = v_zone
     and public._px_eligible(ps.pharmacy_id)
     and coalesce(sp.is_synthetic,false)
         = coalesce((select pp2.is_synthetic from public.pharmacy_profiles pp2
                      where pp2.id = p_shop), false)
     and ps.qty >= coalesce(p_qty,1)
     and ps.product_name ilike '%'||v_q||'%'
     and (ps.expiry_on is null or ps.expiry_on > public._px_today())
     and coalesce(public._px_crow_km(p_shop, ps.pharmacy_id), 0) <= cfg.max_radius_km
   limit 30
  ) q;

  return jsonb_build_object('ok', true,
    'labels', v_labels,
    'privacy_note', public.ui_text('px.privacy_note'),
    'rows', v_rows,
    'empty', jsonb_build_object(
      'title', public.ui_text('px.borrow_empty'),
      'hint',  public.ui_text('px.borrow_empty_hint')));
end $function$

;

-- ── the guard ────────────────────────────────────────────────────
-- A replay that silently no-ops is how a filter disappears. Assert it.
do $c668$
declare
  v_fn text;
  v_missing text[] := '{}';
begin
  foreach v_fn in array array[
    'near_search','near_pharmacy','admin_list_customers','admin_customer_screen_data',
    'admin_missing_locations','customer_credit_list','nav_search','admin_alert_new_since',
    'admin_claim_queue','khata_admin_overview','_px_browse','_px_borrow_search'
  ] loop
    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_fn and p.prokind = 'f'
         and pg_get_functiondef(p.oid) ilike '%is_synthetic%')
    then
      v_missing := v_missing || v_fn;
    end if;
  end loop;
  if array_length(v_missing, 1) is not null then
    raise exception 'c668: synthetic filter missing from %', array_to_string(v_missing, ', ');
  end if;
end
$c668$;
