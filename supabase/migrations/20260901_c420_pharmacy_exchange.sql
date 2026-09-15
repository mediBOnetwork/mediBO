-- CMD #420 - dead-stock exchange and emergency borrow between mediBO pharmacies.
--
-- Two problems, one movement layer:
--   1. DEAD STOCK is a guaranteed loss with a date on it. A box that expires in
--      four months in a shop that sells none is worth full price in a shop two
--      kilometres away that sells six a week. Today it is written off.
--   2. AN EMERGENCY BORROW is a lost customer. A patient asks for one strip the
--      shop does not have; the shop next door has it; there is no way to move it
--      in an hour, so the sale - and often the customer - goes elsewhere.
--
-- This is pharmacy <-> pharmacy through mediBO logistics. It is NOT the supplier
-- marketplace #308 removed: nothing here references supplier_offer_listings or
-- any of that surface, and a SUPPLIER cannot list anything. Both parties are
-- licensed pharmacies, which is exactly why the invoice chain works - a real
-- sale between two GSTINs, with GST, and a document at each end.
--
-- The near-expiry disclosure follows the PATTERN #308 established (batch and
-- expiry always shown, the buyer's acceptance recorded against the deal). The
-- table it lived on was dropped and is not coming back; px_disclosure is new.
--
-- Proven end to end by px_proof_c420(): two seeded pharmacies, both loops,
-- 10/10 green - including that the borrow search leaks no stock level and that
-- the zone fence both HIDES and REFUSES.
-- Table DDL for these functions lives in the c420_px_schema migration.

CREATE OR REPLACE FUNCTION public._px_book_rider(p_deal uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d public.px_deal%rowtype;
  sp public.pharmacy_profiles%rowtype; bp public.pharmacy_profiles%rowtype;
  cfg public.px_config%rowtype := public._px_config();
  v_id uuid; v_min int;
begin
  select * into d from public.px_deal where id = p_deal;
  if not found then return null; end if;
  select * into sp from public.pharmacy_profiles where id = d.seller_id;
  select * into bp from public.pharmacy_profiles where id = d.buyer_id;
  v_min := case when d.kind = 'borrow' then cfg.borrow_promise_min
                else cfg.exchange_promise_min end;

  insert into public.px_delivery_job(
    deal_id, zone_id, pickup_id, drop_id, pickup_label, drop_label,
    pickup_lat, pickup_lng, drop_lat, drop_lng, distance_km,
    promise_min, promised_at, invoice_no, note)
  values (d.id, d.zone_id, d.seller_id, d.buyer_id,
          coalesce(sp.pharmacy_name, sp.customer_name),
          coalesce(bp.pharmacy_name, bp.customer_name),
          sp.latitude, sp.longitude, bp.latitude, bp.longitude,
          d.distance_km, v_min, coalesce(d.promise_at, now() + make_interval(mins => v_min)),
          d.invoice_no, public.ui_text('px.kind_' || d.kind))
  on conflict (deal_id) do nothing
  returning id into v_id;
  return v_id;
end $function$
;

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
begin
  if not public._px_eligible(p_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible',
      'message', public.ui_text('px.err_not_eligible'));
  end if;
  if v_q is null or length(v_q) < 2 then
    return jsonb_build_object('ok', true, 'rows', '[]'::jsonb,
      'labels', jsonb_build_object('title', public.ui_text('px.borrow_title')),
      'hint', public.ui_text('px.borrow_hint'));
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
     and ps.qty >= coalesce(p_qty,1)
     and ps.product_name ilike '%'||v_q||'%'
     and (ps.expiry_on is null or ps.expiry_on > public._px_today())
     and coalesce(public._px_crow_km(p_shop, ps.pharmacy_id), 0) <= cfg.max_radius_km
   limit 30
  ) q;

  return jsonb_build_object('ok', true,
    'labels', jsonb_build_object(
      'title',    public.ui_text('px.borrow_title'),
      'subtitle', public.ui_text('px.borrow_subtitle'),
      'search_hint', public.ui_text('px.borrow_search_hint'),
      'request',  public.ui_text('px.request_button'),
      'qty',      public.ui_text('px.qty_label'),
      'cancel',   public.ui_text('px.cancel'),
      'retry',    public.ui_text('px.retry'),
      'load_failed', public.ui_text('px.load_failed')),
    'privacy_note', public.ui_text('px.privacy_note'),
    'rows', v_rows,
    'empty', jsonb_build_object(
      'title', public.ui_text('px.borrow_empty'),
      'hint',  public.ui_text('px.borrow_empty_hint')));
end $function$
;

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

CREATE OR REPLACE FUNCTION public._px_buyer_stock_row(p_buyer uuid, p_medicine bigint, p_name text, p_pack text, p_batch text, p_expiry text, p_expiry_on date, p_cost numeric, p_mrp numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_key text;
begin
  v_key := lower(coalesce(nullif(btrim(p_name),''),'') || '|' ||
                 coalesce(nullif(btrim(p_batch),''),'-'));
  select id into v_id from public.pharmacy_stock
   where pharmacy_id = p_buyer
     and coalesce(nullif(btrim(batch_no),''),'-') = coalesce(nullif(btrim(p_batch),''),'-')
     and ((p_medicine is not null and medicine_id = p_medicine)
          or (p_medicine is null and lower(product_name) = lower(p_name)))
   limit 1;
  if v_id is not null then return v_id; end if;

  insert into public.pharmacy_stock(
    pharmacy_id, medicine_id, product_name, pack_label, item_key,
    batch_no, expiry, expiry_on, qty, unit_cost, mrp, source_kind,
    supplier_label, received_on)
  values (p_buyer, p_medicine, p_name, p_pack, v_key,
          p_batch, p_expiry, p_expiry_on, 0, p_cost, p_mrp, 'outside',
          public.ui_text('px.source_label'), public._px_today())
  returning id into v_id;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public._px_config()
 RETURNS px_config
 LANGUAGE sql
 STABLE
AS $function$ select * from public.px_config where id = 1; $function$
;

CREATE OR REPLACE FUNCTION public._px_crow_km(p_a uuid, p_b uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select round((6371 * acos(least(1, greatest(-1,
      cos(radians(a.latitude)) * cos(radians(b.latitude))
        * cos(radians(b.longitude) - radians(a.longitude))
      + sin(radians(a.latitude)) * sin(radians(b.latitude))))))::numeric, 2)
    from public.pharmacy_profiles a, public.pharmacy_profiles b
   where a.id = p_a and b.id = p_b
     and a.latitude is not null and a.longitude is not null
     and b.latitude is not null and b.longitude is not null;
$function$
;

CREATE OR REPLACE FUNCTION public._px_denied()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select jsonb_build_object('ok', false, 'error', 'not_a_pharmacy',
                            'message', public.ui_text('px.err_denied'));
$function$
;

CREATE OR REPLACE FUNCTION public._px_disclosure_text(p_product text, p_batch text, p_expiry text, p_expiry_on date)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public.ui_fmt('px.disclosure',
    jsonb_build_object(
      'product', coalesce(p_product,''),
      'batch',   coalesce(nullif(btrim(p_batch),''), public.ui_text('px.batch_unknown')),
      'expiry',  coalesce(nullif(btrim(p_expiry),''), public.ui_text('px.expiry_unknown')),
      'days',    case when p_expiry_on is null then public.ui_text('px.expiry_unknown')
                      else (p_expiry_on - public._px_today())::text end));
$function$
;

CREATE OR REPLACE FUNCTION public._px_eligible(p_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.pharmacy_profiles pp
     where pp.id = p_id
       and coalesce(pp.approved, false)
       and coalesce(pp.status, 'active') not in ('suspended','blocked','rejected')
       and not coalesce(pp.is_deleted, false)
       and pp.zone_id is not null);
$function$
;

CREATE OR REPLACE FUNCTION public._px_job_advance(p_job_id uuid, p_to text, p_receiver text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j public.px_delivery_job%rowtype;
begin
  if p_to not in ('assigned','picked','delivered','cancelled') then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', public.ui_text('px.err_bad_status'));
  end if;
  update public.px_delivery_job
     set status = p_to,
         assigned_at = case when p_to='assigned' then now() else assigned_at end,
         picked_at   = case when p_to='picked' then now() else picked_at end,
         delivered_at= case when p_to='delivered' then now() else delivered_at end,
         receiver_name = coalesce(nullif(btrim(coalesce(p_receiver,'')),''), receiver_name),
         partner_id = coalesce(partner_id, auth.uid())
   where id = p_job_id
  returning * into j;
  if not found then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public.ui_text('px.err_deal_not_found'));
  end if;

  -- the deal follows the job: one truth about where the goods are
  update public.px_deal
     set status = case p_to when 'picked' then 'dispatched'
                            when 'delivered' then 'delivered'
                            when 'cancelled' then 'cancelled'
                            else status end,
         dispatched_at = case when p_to='picked' then now() else dispatched_at end,
         delivered_at  = case when p_to='delivered' then now() else delivered_at end
   where id = j.deal_id;

  return jsonb_build_object('ok', true, 'status', p_to,
    'status_label', public.ui_text('px.job_' || p_to),
    'message', public.ui_text('px.job_updated'));
end $function$
;

CREATE OR REPLACE FUNCTION public._px_move_stock(p_pharmacy uuid, p_stock_id uuid, p_delta numeric, p_reason text, p_ref_kind text, p_ref_id text, p_note text)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_after numeric;
begin
  update public.pharmacy_stock
     set qty = coalesce(qty,0) + p_delta, updated_at = now()
   where id = p_stock_id and pharmacy_id = p_pharmacy
  returning qty into v_after;
  if v_after is null then return null; end if;

  insert into public.pharmacy_stock_move(
    pharmacy_id, stock_id, item_key, kind, qty_delta, qty_after,
    reason_code, note, actor_user_id, ref_kind, ref_id)
  select p_pharmacy, ps.id, ps.item_key,
         case when p_delta < 0 then 'sale' else 'receipt_outside' end,
         p_delta, v_after, p_reason, p_note, auth.uid(), p_ref_kind, p_ref_id
    from public.pharmacy_stock ps where ps.id = p_stock_id;

  return v_after;
end $function$
;

CREATE OR REPLACE FUNCTION public._px_next_invoice(p_seller uuid, p_fy text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_seq bigint;
begin
  insert into public.px_invoice_counter(pharmacy_id, fy, next_no)
  values (p_seller, p_fy, 1) on conflict (pharmacy_id, fy) do nothing;
  update public.px_invoice_counter set next_no = next_no + 1
   where pharmacy_id = p_seller and fy = p_fy
  returning next_no - 1 into v_seq;
  return v_seq;
end $function$
;

CREATE OR REPLACE FUNCTION public._px_same_zone(p_a uuid, p_b uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._px_eligible(p_a) and public._px_eligible(p_b)
     and (select zone_id from public.pharmacy_profiles where id = p_a)
       = (select zone_id from public.pharmacy_profiles where id = p_b);
$function$
;

CREATE OR REPLACE FUNCTION public._px_settle(p_deal uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d public.px_deal%rowtype;
  l public.px_listing%rowtype;
  cfg public.px_config%rowtype := public._px_config();
  v_fy text; v_seq bigint; v_no text;
  v_gst numeric; v_taxable numeric; v_total numeric; v_fee numeric;
  v_buyer_stock uuid; v_after numeric; v_seller_stock uuid;
  v_dist jsonb; v_promise int; v_expiry_on date; v_mrp numeric; v_job uuid;
begin
  select * into d from public.px_deal where id = p_deal for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if d.status <> 'requested' then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', public.ui_text('px.err_bad_status'));
  end if;
  if not public._px_same_zone(d.seller_id, d.buyer_id) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible',
      'message', public.ui_text('px.err_not_eligible'));
  end if;

  select * into l from public.px_listing where id = d.listing_id for update;
  if not found or l.qty_remaining < d.qty or l.status <> 'active' then
    return jsonb_build_object('ok', false, 'error', 'gone',
      'message', public.ui_text('px.err_listing_gone'));
  end if;
  v_seller_stock := l.stock_id; v_expiry_on := l.expiry_on; v_mrp := l.mrp;

  v_gst     := coalesce(d.gst_percent, 0);
  v_taxable := round(d.qty * d.unit_price, 2);
  v_total   := round(v_taxable * (1 + v_gst / 100.0), 2);
  v_fee     := round(v_taxable * coalesce(cfg.fee_percent,0) / 100.0, 2);

  v_fy  := public._pos_fy(public._px_today());
  v_seq := public._px_next_invoice(d.seller_id, v_fy);
  v_no  := cfg.invoice_prefix || '/' || v_fy || '/' || lpad(v_seq::text, 5, '0');

  v_after := public._px_move_stock(d.seller_id, v_seller_stock, -d.qty,
               case when d.kind = 'exchange' then 'px_exchange_out' else 'px_borrow_out' end,
               'px_deal', d.id::text || ':out', v_no);
  if v_after is null then
    return jsonb_build_object('ok', false, 'error', 'stock_gone',
      'message', public.ui_text('px.err_listing_gone'));
  end if;

  update public.px_listing
     set qty_remaining = qty_remaining - d.qty,
         status = case when qty_remaining - d.qty <= 0 then 'sold' else status end,
         closed_at = case when qty_remaining - d.qty <= 0 then now() else closed_at end
   where id = l.id;

  v_buyer_stock := public._px_buyer_stock_row(
    d.buyer_id, d.medicine_id, d.product_name, d.pack_label,
    d.batch_no, d.expiry, v_expiry_on, d.unit_price, v_mrp);
  perform public._px_move_stock(d.buyer_id, v_buyer_stock, d.qty,
            case when d.kind = 'exchange' then 'px_exchange_in' else 'px_borrow_in' end,
            'px_deal', d.id::text || ':in', v_no);

  v_dist := public.px_distance(d.seller_id, d.buyer_id);
  v_promise := case when d.kind = 'borrow' then cfg.borrow_promise_min
                    else cfg.exchange_promise_min end;

  update public.px_deal
     set status = 'accepted', fy = v_fy, invoice_seq = v_seq, invoice_no = v_no,
         taxable = v_taxable,
         cgst = round(v_taxable * v_gst / 200.0, 2),
         sgst = round(v_taxable * v_gst / 200.0, 2),
         line_amount = v_taxable, total_amount = v_total,
         fee_percent = coalesce(cfg.fee_percent,0), fee_amount = v_fee,
         distance_km = (v_dist->>'distance_km')::numeric,
         distance_source = v_dist->>'source',
         eta_minutes = (v_dist->>'minutes')::int,
         promise_at = now() + make_interval(mins => v_promise),
         decided_by = auth.uid(), decided_at = now()
   where id = d.id;

  insert into public.px_disclosure(
    deal_id, listing_id, buyer_id, batch_no, expiry, expiry_on,
    days_to_expiry, disclosure_text, accepted_by)
  values (d.id, d.listing_id, d.buyer_id, d.batch_no, d.expiry, v_expiry_on,
          case when v_expiry_on is null then null else v_expiry_on - public._px_today() end,
          public._px_disclosure_text(d.product_name, d.batch_no, d.expiry, v_expiry_on),
          auth.uid())
  on conflict (deal_id) do nothing;

  -- the rider, in the SAME transaction: goods never leave a shelf without a
  -- courier task that says where they are going and by when
  v_job := public._px_book_rider(d.id);

  perform public.px_invoice_request(d.id);

  return jsonb_build_object('ok', true, 'deal_id', d.id, 'invoice_no', v_no,
    'job_id', v_job,
    'total_display', public.inr_money(v_total),
    'promise_label', public.ui_fmt('px.promise_label',
      jsonb_build_object('min', v_promise::text)),
    'distance', v_dist,
    'message', public.ui_text('px.accepted_toast'));
end $function$
;

CREATE OR REPLACE FUNCTION public._px_today()
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$ select (now() at time zone 'Asia/Kolkata')::date; $function$
;

CREATE OR REPLACE FUNCTION public.khata_fmt(p_key text, p_vars jsonb)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$ select public.ui_fmt(p_key, p_vars); $function$
;

CREATE OR REPLACE FUNCTION public.px_accept_listing(p_listing_id uuid, p_qty numeric, p_client_action_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.px_shop();
  l public.px_listing%rowtype;
  v_deal uuid; v_exist public.px_deal%rowtype;
begin
  if v_shop is null then return public._px_denied(); end if;
  if p_client_action_id is not null then
    select * into v_exist from public.px_deal where client_action_id = p_client_action_id;
    if found then
      return public.px_deal_detail(v_exist.id) || jsonb_build_object('replayed', true);
    end if;
  end if;

  select * into l from public.px_listing where id = p_listing_id for update;
  if not found or l.status <> 'active' or l.qty_remaining <= 0 then
    return jsonb_build_object('ok', false, 'error', 'gone',
      'message', public.ui_text('px.err_listing_gone'));
  end if;
  if l.seller_id = v_shop then
    return jsonb_build_object('ok', false, 'error', 'own_listing',
      'message', public.ui_text('px.err_own_listing'));
  end if;
  if not public._px_same_zone(l.seller_id, v_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible',
      'message', public.ui_text('px.err_not_eligible'));
  end if;
  if coalesce(p_qty,0) <= 0 or p_qty > l.qty_remaining then
    return jsonb_build_object('ok', false, 'error', 'bad_qty',
      'message', public.ui_fmt('px.err_bad_qty',
        jsonb_build_object('n', to_char(l.qty_remaining,'FM999990.##'))));
  end if;

  insert into public.px_deal(
    kind, listing_id, seller_id, buyer_id, zone_id, medicine_id, product_name,
    pack_label, batch_no, expiry, qty, unit_price, line_amount, gst_percent,
    requested_by, client_action_id)
  values ('exchange', l.id, l.seller_id, v_shop, l.zone_id, l.medicine_id,
          l.product_name, l.pack_label, l.batch_no, l.expiry, p_qty, l.unit_price,
          round(p_qty * l.unit_price, 2), coalesce(l.gst_percent, 0),
          auth.uid(), p_client_action_id)
  returning id into v_deal;

  return public._px_settle(v_deal) || jsonb_build_object('deal_id', v_deal);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_borrow_request(p_stock_id uuid, p_qty numeric, p_client_action_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.px_shop();
  s public.pharmacy_stock%rowtype;
  cfg public.px_config%rowtype := public._px_config();
  sp public.pharmacy_profiles%rowtype;
  v_deal uuid; v_listing uuid; v_exist public.px_deal%rowtype; v_price numeric;
begin
  if v_shop is null then return public._px_denied(); end if;
  if p_client_action_id is not null then
    select * into v_exist from public.px_deal where client_action_id = p_client_action_id;
    if found then
      return public.px_deal_detail(v_exist.id) || jsonb_build_object('replayed', true);
    end if;
  end if;

  select * into s from public.pharmacy_stock where id = p_stock_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('px.err_stock_not_found'));
  end if;
  if s.pharmacy_id = v_shop then
    return jsonb_build_object('ok', false, 'error', 'own_stock',
      'message', public.ui_text('px.err_own_listing'));
  end if;
  if not public._px_same_zone(s.pharmacy_id, v_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible',
      'message', public.ui_text('px.err_not_eligible'));
  end if;
  if coalesce(p_qty,0) <= 0 or s.qty < p_qty then
    -- never leaks how many they DO have; only that this ask cannot be met
    return jsonb_build_object('ok', false, 'error', 'not_enough',
      'message', public.ui_text('px.err_not_enough'));
  end if;

  -- MRP is the price basis for a borrow (the spec's "MRP-or-agreed"), and MRP
  -- is the legal CEILING, so it is the honest ceiling price between two shops.
  -- It is never used to report revenue — that stays on the invoice's taxable.
  v_price := coalesce(s.mrp, s.unit_cost, 0);
  if v_price <= 0 then
    return jsonb_build_object('ok', false, 'error', 'no_price',
      'message', public.ui_text('px.err_no_price'));
  end if;

  select * into sp from public.pharmacy_profiles where id = s.pharmacy_id;

  -- A borrow gets a listing row too, so the settlement has one shape to follow
  -- and the seller's shelf row is named in one place.
  insert into public.px_listing(
    seller_id, zone_id, stock_id, medicine_id, product_name, pack_label,
    batch_no, expiry, expiry_on, qty_listed, qty_remaining, unit_price,
    mrp, unit_cost, gst_percent, status, created_by, note)
  values (s.pharmacy_id, sp.zone_id, s.id, s.medicine_id, s.product_name, s.pack_label,
          coalesce(nullif(btrim(s.batch_no),''),'-'),
          coalesce(nullif(btrim(s.expiry),''),'-'),
          s.expiry_on, p_qty, p_qty, v_price, s.mrp, s.unit_cost,
          public._pos_gst_for(s.medicine_id), 'active', auth.uid(),
          public.ui_text('px.borrow_note'))
  returning id into v_listing;

  insert into public.px_deal(
    kind, listing_id, seller_id, buyer_id, zone_id, medicine_id, product_name,
    pack_label, batch_no, expiry, qty, unit_price, line_amount, gst_percent,
    requested_by, client_action_id)
  values ('borrow', v_listing, s.pharmacy_id, v_shop, sp.zone_id, s.medicine_id,
          s.product_name, s.pack_label, s.batch_no, s.expiry, p_qty, v_price,
          round(p_qty * v_price, 2), public._pos_gst_for(s.medicine_id),
          auth.uid(), p_client_action_id)
  returning id into v_deal;

  return jsonb_build_object('ok', true, 'deal_id', v_deal, 'status', 'requested',
    'message', public.ui_text('px.requested_toast'),
    'promise_label', public.ui_fmt('px.promise_label',
      jsonb_build_object('min', cfg.borrow_promise_min::text)),
    'distance', public.px_distance(s.pharmacy_id, v_shop));
end $function$
;

CREATE OR REPLACE FUNCTION public.px_borrow_search(p_q text, p_qty numeric DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.px_shop();
begin
  if v_shop is null then return public._px_denied(); end if;
  return public._px_borrow_search(v_shop, p_q, p_qty);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_browse(p_q text DEFAULT NULL::text, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.px_shop();
begin
  if v_shop is null then return public._px_denied(); end if;
  return public._px_browse(v_shop, p_q, p_limit);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_deal_detail(p_deal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.px_shop();
  d public.px_deal%rowtype;
  sp public.pharmacy_profiles%rowtype; bp public.pharmacy_profiles%rowtype;
  disc public.px_disclosure%rowtype; v_mine text;
begin
  if v_shop is null then return public._px_denied(); end if;
  select * into d from public.px_deal where id = p_deal_id;
  if not found or (d.seller_id <> v_shop and d.buyer_id <> v_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('px.err_deal_not_found'));
  end if;
  select * into sp from public.pharmacy_profiles where id = d.seller_id;
  select * into bp from public.pharmacy_profiles where id = d.buyer_id;
  select * into disc from public.px_disclosure where deal_id = d.id;
  v_mine := case when d.seller_id = v_shop then 'seller' else 'buyer' end;

  return jsonb_build_object(
    'ok', true,
    'deal_id', d.id,
    'kind', d.kind,
    'kind_label', public.ui_text('px.kind_' || d.kind),
    'my_side', v_mine,
    'side_label', public.ui_text('px.side_' || v_mine),
    'status', d.status,
    'status_label', public.ui_text('px.status_' || d.status),
    'status_tone', case d.status
        when 'delivered' then 'success' when 'accepted' then 'info'
        when 'dispatched' then 'info' when 'requested' then 'warning'
        else 'danger' end,
    'counterparty', case when v_mine = 'seller'
        then coalesce(bp.pharmacy_name, bp.customer_name)
        else coalesce(sp.pharmacy_name, sp.customer_name) end,
    'product_name', d.product_name,
    'pack_label', d.pack_label,
    'qty_label', public.ui_fmt('px.qty_n', jsonb_build_object('n', to_char(d.qty,'FM999990.##'))),
    'batch_label', public.ui_fmt('px.batch_label', jsonb_build_object('batch', coalesce(d.batch_no,'-'))),
    'expiry_label', public.ui_fmt('px.expiry_label', jsonb_build_object('expiry', coalesce(d.expiry,'-'))),
    'disclosure', coalesce(disc.disclosure_text,
        public._px_disclosure_text(d.product_name, d.batch_no, d.expiry, disc.expiry_on)),
    'disclosure_accepted_label', case when disc.accepted_at is null then null
        else public.ui_fmt('px.disclosure_accepted', jsonb_build_object(
               'at', to_char(disc.accepted_at at time zone 'Asia/Kolkata', 'DD Mon YYYY HH24:MI'))) end,
    'price_display', public.inr_money(d.unit_price),
    'taxable_display', public.inr_money(d.taxable),
    'gst_label', public.ui_fmt('px.gst_label', jsonb_build_object('pct', to_char(d.gst_percent,'FM990.##'))),
    'cgst_display', public.inr_money(d.cgst),
    'sgst_display', public.inr_money(d.sgst),
    'total_display', public.inr_money(d.total_amount),
    'fee_display', case when coalesce(d.fee_amount,0) = 0 then public.ui_text('px.fee_zero')
                        else public.inr_money(d.fee_amount) end,
    'invoice_no', d.invoice_no,
    'invoice_ready', d.pdf_status = 'ready',
    'pdf_bucket', d.pdf_bucket, 'pdf_path', d.pdf_path, 'pdf_name', d.pdf_name,
    'distance_label', case when d.distance_km is null then null
        else public.ui_fmt(case when d.distance_source = 'osrm' then 'px.distance_label'
                                else 'px.distance_approx' end,
             jsonb_build_object('km', to_char(d.distance_km,'FM990.0'))) end,
    'eta_label', case when d.eta_minutes is null then null
        else public.ui_fmt('px.eta_label', jsonb_build_object('min', d.eta_minutes::text)) end,
    'promise_label', case when d.promise_at is null then null
        else public.ui_fmt('px.promise_by', jsonb_build_object(
               'at', to_char(d.promise_at at time zone 'Asia/Kolkata', 'HH24:MI'))) end,
    'can_decide', v_mine = 'seller' and d.status = 'requested',
    'labels', jsonb_build_object(
      'accept',  public.ui_text('px.accept_button'),
      'decline', public.ui_text('px.decline_button'),
      'invoice', public.ui_text('px.invoice_button'),
      'retry',   public.ui_text('px.retry'),
      'load_failed', public.ui_text('px.load_failed')));
end $function$
;

CREATE OR REPLACE FUNCTION public.px_decide(p_deal_id uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.px_shop(); d public.px_deal%rowtype;
begin
  if v_shop is null then return public._px_denied(); end if;
  select * into d from public.px_deal where id = p_deal_id;
  if not found or d.seller_id <> v_shop then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('px.err_deal_not_found'));
  end if;
  if d.status <> 'requested' then
    return jsonb_build_object('ok', false, 'error', 'bad_status',
      'message', public.ui_text('px.err_bad_status'));
  end if;
  if not coalesce(p_accept,false) then
    update public.px_deal set status='declined', decided_by=auth.uid(), decided_at=now()
     where id = d.id;
    update public.px_listing set status='withdrawn', closed_at=now()
     where id = d.listing_id and status='active'
       and note = public.ui_text('px.borrow_note');
    return jsonb_build_object('ok', true, 'status','declined',
      'message', public.ui_text('px.declined_toast'));
  end if;
  return public._px_settle(d.id);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_delivery_queue(p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb;
begin
  if not public.am_i_super() and public.get_my_role() not in ('admin','delivery') then
    return jsonb_build_object('ok', false, 'error', 'denied',
      'message', public.ui_text('px.err_denied'));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'job_id', j.id, 'deal_id', j.deal_id,
      'status_label', public.ui_text('px.job_' || j.status),
      'status_tone', case j.status when 'delivered' then 'success'
                                   when 'queued' then 'warning' else 'info' end,
      'pickup', j.pickup_label, 'drop', j.drop_label,
      'invoice_no', j.invoice_no,
      'distance_label', case when j.distance_km is null then null
          else public.ui_fmt('px.distance_label',
                 jsonb_build_object('km', to_char(j.distance_km,'FM990.0'))) end,
      'promise_label', public.ui_fmt('px.promise_by',
          jsonb_build_object('at', to_char(j.promised_at at time zone 'Asia/Kolkata','HH24:MI'))),
      'overdue', j.status <> 'delivered' and j.promised_at < now())
      order by j.promised_at), '[]'::jsonb)
    into v_rows
    from public.px_delivery_job j
   where j.status <> 'cancelled'
     and (p_zone is null or j.zone_id = p_zone);

  return jsonb_build_object('ok', true,
    'title', public.ui_text('px.queue_title'),
    'rows', v_rows,
    'empty', jsonb_build_object('title', public.ui_text('px.queue_empty')));
end $function$
;

CREATE OR REPLACE FUNCTION public.px_distance(p_from uuid, p_to uuid, p_max_age_hours integer DEFAULT 168)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.px_pair_distance%rowtype;
  a public.pharmacy_profiles%rowtype; b public.pharmacy_profiles%rowtype;
  v_req bigint; v_body jsonb; v_km numeric; v_min integer; v_crow numeric;
  v_src text;
begin
  select * into c from public.px_pair_distance where from_id = p_from and to_id = p_to;
  if found and c.updated_at > now() - make_interval(hours => greatest(coalesce(p_max_age_hours,168),1)) then
    return jsonb_build_object('ok', true, 'cached', true,
      'distance_km', c.distance_km, 'minutes', c.minutes, 'source', c.source,
      'label', public.ui_fmt(case when c.source = 'osrm' then 'px.distance_label'
                                  else 'px.distance_approx' end,
                 jsonb_build_object('km', to_char(c.distance_km, 'FM990.0'))),
      'eta_label', public.ui_fmt('px.eta_label',
                 jsonb_build_object('min', c.minutes::text)));
  end if;

  select * into a from public.pharmacy_profiles where id = p_from;
  select * into b from public.pharmacy_profiles where id = p_to;
  v_crow := public._px_crow_km(p_from, p_to);

  if a.latitude is not null and b.latitude is not null then
    begin
      select net.http_get(
        url := 'http://35.234.212.254:5000/route/v1/driving/'
               || a.longitude || ',' || a.latitude || ';'
               || b.longitude || ',' || b.latitude || '?overview=false',
        timeout_milliseconds := 4000) into v_req;
      select content::jsonb into v_body from net._http_response where id = v_req;
      if coalesce(v_body->>'code','') = 'Ok' then
        v_km  := round(((v_body->'routes'->0->>'distance')::numeric / 1000.0)::numeric, 2);
        v_min := ceil((v_body->'routes'->0->>'duration')::numeric / 60.0)::int;
      end if;
    exception when others then
      v_km := null; v_min := null;
    end;
  end if;

  v_src := case when v_km is not null then 'osrm' else 'approx' end;
  if v_km is null then
    v_km := v_crow;
    v_min := case when v_crow is null then null else greatest(10, ceil(v_crow * 4)::int) end;
  end if;

  if v_km is not null then
    insert into public.px_pair_distance(from_id, to_id, distance_km, minutes, source, updated_at)
    values (p_from, p_to, v_km, v_min, v_src, now())
    on conflict (from_id, to_id) do update set
      distance_km = excluded.distance_km, minutes = excluded.minutes,
      source = excluded.source, updated_at = now();
  end if;

  return jsonb_build_object('ok', true, 'cached', false,
    'distance_km', v_km, 'minutes', v_min, 'source', v_src,
    'label', case when v_km is null then public.ui_text('px.distance_unknown')
        else public.ui_fmt(case when v_src = 'osrm' then 'px.distance_label'
                                else 'px.distance_approx' end,
             jsonb_build_object('km', to_char(v_km, 'FM990.0'))) end,
    'eta_label', case when v_min is null then ''
        else public.ui_fmt('px.eta_label', jsonb_build_object('min', v_min::text)) end);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.px_shop();
  cfg public.px_config%rowtype := public._px_config();
  pp public.pharmacy_profiles%rowtype;
  v_mine jsonb; v_deals jsonb; v_pending int;
begin
  if v_shop is null then return public._px_denied(); end if;
  select * into pp from public.pharmacy_profiles where id = v_shop;

  select count(*) into v_pending from public.px_deal
   where seller_id = v_shop and status = 'requested';

  select coalesce(jsonb_agg(jsonb_build_object(
      'listing_id', l.id, 'product_name', l.product_name,
      'qty_label', public.ui_fmt('px.qty_available',
                     jsonb_build_object('n', to_char(l.qty_remaining,'FM999990.##'))),
      'price_display', public.inr_money(l.unit_price),
      'batch_label', public.ui_fmt('px.batch_label', jsonb_build_object('batch', coalesce(l.batch_no,'-'))),
      'expiry_label', public.ui_fmt('px.expiry_label', jsonb_build_object('expiry', coalesce(l.expiry,'-'))),
      'status_label', public.ui_text('px.lstatus_' || l.status))
      order by l.created_at desc), '[]'::jsonb)
    into v_mine
    from public.px_listing l
   where l.seller_id = v_shop and l.status in ('active','sold')
     and coalesce(l.note,'') <> public.ui_text('px.borrow_note');

  select coalesce(jsonb_agg(jsonb_build_object(
      'deal_id', d.id, 'kind_label', public.ui_text('px.kind_' || d.kind),
      'product_name', d.product_name,
      'side_label', public.ui_text('px.side_' || case when d.seller_id = v_shop then 'seller' else 'buyer' end),
      'counterparty', case when d.seller_id = v_shop
          then (select coalesce(pharmacy_name, customer_name) from public.pharmacy_profiles where id = d.buyer_id)
          else (select coalesce(pharmacy_name, customer_name) from public.pharmacy_profiles where id = d.seller_id) end,
      'status_label', public.ui_text('px.status_' || d.status),
      'status_tone', case d.status when 'delivered' then 'success' when 'requested' then 'warning'
                                   when 'declined' then 'danger' else 'info' end,
      'total_display', public.inr_money(d.total_amount),
      'invoice_no', d.invoice_no,
      'needs_me', d.seller_id = v_shop and d.status = 'requested')
      order by d.created_at desc), '[]'::jsonb)
    into v_deals
    from public.px_deal d
   where d.seller_id = v_shop or d.buyer_id = v_shop;

  return jsonb_build_object(
    'ok', true,
    'eligible', public._px_eligible(v_shop),
    'not_eligible_message', case when public._px_eligible(v_shop) then null
                                 else public.ui_text('px.err_not_eligible') end,
    'shop_name', coalesce(pp.pharmacy_name, pp.customer_name),
    'labels', jsonb_build_object(
      'title',       public.ui_text('px.title'),
      'subtitle',    public.ui_text('px.subtitle'),
      'browse',      public.ui_text('px.browse_title'),
      'borrow',      public.ui_text('px.borrow_title'),
      'my_listings', public.ui_text('px.my_listings'),
      'deals',       public.ui_text('px.my_deals'),
      'list_stock',  public.ui_text('px.list_button'),
      'retry',       public.ui_text('px.retry'),
      'load_failed', public.ui_text('px.load_failed')),
    'pending_label', case when v_pending > 0
        then public.ui_fmt('px.pending_requests', jsonb_build_object('n', v_pending::text))
        else null end,
    'fee_note', case when coalesce(cfg.fee_percent,0) = 0 then public.ui_text('px.fee_zero')
                     else public.ui_fmt('px.fee_note',
                            jsonb_build_object('pct', to_char(cfg.fee_percent,'FM990.##'))) end,
    'my_listings', v_mine,
    'deals', v_deals,
    'empty_listings', jsonb_build_object('title', public.ui_text('px.no_listings')),
    'empty_deals', jsonb_build_object('title', public.ui_text('px.no_deals')));
end $function$
;

CREATE OR REPLACE FUNCTION public.px_invoice_render_input(p_deal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d public.px_deal%rowtype;
  sp public.pharmacy_profiles%rowtype; bp public.pharmacy_profiles%rowtype;
  disc public.px_disclosure%rowtype;
begin
  select * into d from public.px_deal where id = p_deal_id;
  if not found then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  select * into sp from public.pharmacy_profiles where id = d.seller_id;
  select * into bp from public.pharmacy_profiles where id = d.buyer_id;
  select * into disc from public.px_disclosure where deal_id = d.id;

  return jsonb_build_object(
    'ok', true,
    'bucket', 'customer-bills',
    'path', 'px/' || d.seller_id::text || '/' || d.id::text || '.pdf',
    'file_name', 'invoice-' || replace(coalesce(d.invoice_no,'px'), '/', '-') || '.pdf',
    'invoice', jsonb_build_object(
      'title', public.ui_text('px.invoice_title'),
      'seller', jsonb_build_object(
        'heading', public.ui_text('px.seller_heading'),
        'name', coalesce(sp.pharmacy_name, sp.customer_name),
        'address', nullif(btrim(concat_ws(', ', sp.address, sp.city, sp.state, sp.pincode)),''),
        'phone', nullif(btrim(coalesce(sp.whatsapp_no, sp.phone, '')),''),
        'gstin_label', case when nullif(btrim(coalesce(sp.gst_no, sp.gstin,'')),'') is null then null
             else 'GSTIN: ' || coalesce(nullif(btrim(sp.gst_no),''), sp.gstin) end,
        'dl_label', case when nullif(btrim(coalesce(sp.drug_license,'')),'') is null then null
             else 'DL: ' || sp.drug_license end),
      'buyer', jsonb_build_object(
        'heading', public.ui_text('px.buyer_heading'),
        'name', coalesce(bp.pharmacy_name, bp.customer_name),
        'address', nullif(btrim(concat_ws(', ', bp.address, bp.city, bp.state, bp.pincode)),''),
        'phone', nullif(btrim(coalesce(bp.whatsapp_no, bp.phone, '')),''),
        'gstin_label', case when nullif(btrim(coalesce(bp.gst_no, bp.gstin,'')),'') is null then null
             else 'GSTIN: ' || coalesce(nullif(btrim(bp.gst_no),''), bp.gstin) end,
        'dl_label', case when nullif(btrim(coalesce(bp.drug_license,'')),'') is null then null
             else 'DL: ' || bp.drug_license end),
      'meta', jsonb_build_array(
        jsonb_build_object('label', public.ui_text('px.invoice_no_label'), 'value', d.invoice_no),
        jsonb_build_object('label', public.ui_text('px.invoice_date_label'),
          'value', to_char(d.created_at at time zone 'Asia/Kolkata','DD Mon YYYY')),
        jsonb_build_object('label', public.ui_text('px.kind_label'),
          'value', public.ui_text('px.kind_' || d.kind))),
      'columns', jsonb_build_array(
        jsonb_build_object('key','product','label', public.ui_text('px.col_product')),
        jsonb_build_object('key','batch',  'label', public.ui_text('px.col_batch')),
        jsonb_build_object('key','expiry', 'label', public.ui_text('px.col_expiry')),
        jsonb_build_object('key','qty',    'label', public.ui_text('px.col_qty'),'align','right'),
        jsonb_build_object('key','rate',   'label', public.ui_text('px.col_rate'),'align','right'),
        jsonb_build_object('key','taxable','label', public.ui_text('px.col_taxable'),'align','right'),
        jsonb_build_object('key','gst',    'label', public.ui_text('px.col_gst'),'align','right'),
        jsonb_build_object('key','amount', 'label', public.ui_text('px.col_amount'),'align','right')),
      'lines', jsonb_build_array(jsonb_build_object(
        'product', d.product_name || coalesce(' ' || d.pack_label, ''),
        'batch',   coalesce(d.batch_no,'-'),
        'expiry',  coalesce(d.expiry,'-'),
        'qty',     to_char(d.qty,'FM999990.##'),
        'rate',    public.inr_money(d.unit_price),
        'taxable', public.inr_money(d.taxable),
        'gst',     to_char(d.gst_percent,'FM990.##') || '%',
        'amount',  public.inr_money(d.total_amount))),
      'totals', jsonb_build_array(
        jsonb_build_object('label', public.ui_text('px.col_taxable'), 'value', public.inr_money(d.taxable)),
        jsonb_build_object('label', public.ui_text('px.cgst_label'),  'value', public.inr_money(d.cgst)),
        jsonb_build_object('label', public.ui_text('px.sgst_label'),  'value', public.inr_money(d.sgst))),
      'net', jsonb_build_object(
        'label', public.ui_text('px.net_label'),
        'value', public.inr_money(d.total_amount)),
      'disclosure', coalesce(disc.disclosure_text, ''),
      'footer', jsonb_build_object(
        'note', public.ui_text('px.invoice_footer'),
        'items', case when coalesce(d.fee_amount,0) = 0 then public.ui_text('px.fee_zero')
                      else public.ui_fmt('px.fee_line',
                             jsonb_build_object('amt', public.inr_money(d.fee_amount))) end)));
end $function$
;

CREATE OR REPLACE FUNCTION public.px_invoice_report(p_deal_id uuid, p_ok boolean, p_bucket text DEFAULT NULL::text, p_path text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_bytes integer DEFAULT NULL::integer, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(p_ok,false) then
    update public.px_deal set pdf_status='ready', pdf_bucket=p_bucket, pdf_path=p_path,
           pdf_name=p_name, pdf_bytes=p_bytes, pdf_error=null where id = p_deal_id;
  else
    update public.px_deal set pdf_status='failed',
           pdf_error=left(coalesce(p_error,'render_failed'),500) where id = p_deal_id;
  end if;
  return jsonb_build_object('ok', true, 'deal_id', p_deal_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_invoice_request(p_deal_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d public.px_deal%rowtype;
begin
  select * into d from public.px_deal where id = p_deal_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('px.err_deal_not_found'));
  end if;
  if public.px_shop() is not null
     and d.seller_id <> public.px_shop() and d.buyer_id <> public.px_shop() then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('px.err_deal_not_found'));
  end if;
  if d.pdf_status = 'ready' and coalesce(d.pdf_path,'') <> '' then
    return jsonb_build_object('ok', true, 'status','ready', 'deal_id', d.id,
      'bucket', d.pdf_bucket, 'path', d.pdf_path, 'file_name', d.pdf_name,
      'expires_s', 300, 'message', public.ui_text('px.invoice_ready'));
  end if;

  update public.px_deal set pdf_status='queued', pdf_error=null where id = d.id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/px-invoice',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('deal_id', d.id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status','building', 'deal_id', d.id,
    'poll_ms', 1500, 'message', public.ui_text('px.invoice_building'));
end $function$
;

CREATE OR REPLACE FUNCTION public.px_job_advance(p_job_id uuid, p_to text, p_receiver text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.am_i_super() and public.get_my_role() not in ('admin','delivery') then
    return jsonb_build_object('ok', false, 'error', 'denied',
      'message', public.ui_text('px.err_denied'));
  end if;
  return public._px_job_advance(p_job_id, p_to, p_receiver);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_list_stock(p_stock_id uuid, p_qty numeric, p_unit_price numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_shop uuid := public.px_shop();
  s public.pharmacy_stock%rowtype;
  pp public.pharmacy_profiles%rowtype;
  cfg public.px_config%rowtype := public._px_config();
  v_id uuid; v_listed numeric;
begin
  if v_shop is null then return public._px_denied(); end if;
  if not cfg.enabled then
    return jsonb_build_object('ok', false, 'error', 'disabled',
      'message', public.ui_text('px.err_disabled'));
  end if;
  if not public._px_eligible(v_shop) then
    return jsonb_build_object('ok', false, 'error', 'not_eligible',
      'message', public.ui_text('px.err_not_eligible'));
  end if;

  select * into s from public.pharmacy_stock where id = p_stock_id and pharmacy_id = v_shop;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', public.ui_text('px.err_stock_not_found'));
  end if;
  if coalesce(p_qty,0) <= 0 or coalesce(p_unit_price,0) <= 0 then
    return jsonb_build_object('ok', false, 'error', 'bad_input',
      'message', public.ui_text('px.err_bad_qty_price'));
  end if;

  select coalesce(sum(qty_remaining),0) into v_listed
    from public.px_listing where stock_id = s.id and status = 'active';
  if v_listed + p_qty > coalesce(s.qty, 0) then
    return jsonb_build_object('ok', false, 'error', 'over_stock',
      'message', public.ui_fmt('px.err_over_stock',
        jsonb_build_object('have', to_char(coalesce(s.qty,0), 'FM999990.##'),
                           'listed', to_char(v_listed, 'FM999990.##'))));
  end if;

  select * into pp from public.pharmacy_profiles where id = v_shop;

  insert into public.px_listing(
    seller_id, zone_id, stock_id, medicine_id, product_name, pack_label,
    batch_no, expiry, expiry_on, qty_listed, qty_remaining, unit_price,
    mrp, unit_cost, gst_percent, note, created_by)
  values (v_shop, pp.zone_id, s.id, s.medicine_id, s.product_name, s.pack_label,
          coalesce(nullif(btrim(s.batch_no),''), '-'),
          coalesce(nullif(btrim(s.expiry),''), '-'),
          s.expiry_on, p_qty, p_qty, p_unit_price, s.mrp, s.unit_cost,
          public._pos_gst_for(s.medicine_id),
          nullif(btrim(coalesce(p_note,'')),''), auth.uid())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'listing_id', v_id,
    'disclosure', public._px_disclosure_text(s.product_name, s.batch_no, s.expiry, s.expiry_on),
    'message', public.ui_text('px.listed_toast'));
end $function$
;

CREATE OR REPLACE FUNCTION public.px_nav_entry()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_shop uuid := public.px_shop(); v_pending int;
begin
  if v_shop is null or not public._px_eligible(v_shop) then
    return jsonb_build_object('ok', true, 'show', false);
  end if;
  select count(*) into v_pending from public.px_deal
   where seller_id = v_shop and status = 'requested';
  return jsonb_build_object('ok', true, 'show', true,
    'route_key', 'px_exchange', 'icon_key', 'handshake',
    'label', public.ui_text('px.nav_label'),
    'sub_label', case when v_pending > 0
        then public.ui_fmt('px.pending_requests', jsonb_build_object('n', v_pending::text))
        else public.ui_text('px.subtitle') end);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_proof_c420()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  A uuid; B uuid;
  v_zone smallint := 1; v_other_zone smallint := 2;
  sA uuid; sB uuid;
  v_listing uuid; v_deal uuid; v_deal2 uuid; v_res jsonb; v_rows jsonb;
  v_steps jsonb := '[]'::jsonb; v_pass boolean := true; v_ok boolean;
  v_qA numeric; v_qB numeric; v_disc text; v_inv text; v_leak boolean;
  v_job uuid; v_jstatus text; v_dstatus text;
begin
  delete from public.pharmacy_profiles where customer_code in ('C420A','C420B');

  insert into public.pharmacy_profiles(
      id, pharmacy_name, customer_name, customer_code, approved, status,
      is_deleted, zone_id, latitude, longitude, gst_no, drug_license,
      address, city, state, pincode, phone)
  values (gen_random_uuid(), 'C420 Alpha Medicals', 'C420 Alpha Medicals', 'C420A',
          true, 'active', false, v_zone, 21.2514, 81.6296,
          '22AAAAA0000A1Z5', 'CG-20B-C420A', 'Shop 1, Test Road', 'Raipur',
          'Chhattisgarh', '492001', '9000000420')
  returning id into A;

  insert into public.pharmacy_profiles(
      id, pharmacy_name, customer_name, customer_code, approved, status,
      is_deleted, zone_id, latitude, longitude, gst_no, drug_license,
      address, city, state, pincode, phone)
  values (gen_random_uuid(), 'C420 Beta Chemists', 'C420 Beta Chemists', 'C420B',
          true, 'active', false, v_zone, 21.2764, 81.6296,
          '22BBBBB0000B1Z5', 'CG-20B-C420B', 'Shop 2, Test Road', 'Raipur',
          'Chhattisgarh', '492001', '9000000421')
  returning id into B;

  insert into public.pharmacy_stock(
      pharmacy_id, product_name, pack_label, item_key, batch_no, expiry,
      expiry_on, qty, unit_cost, mrp, source_kind, received_on)
  values (A, 'C420 Amoxycillin 500', '10 caps', 'c420amox|B420',
          'B420', '03/27', public._px_today() + 75, 40, 62.00, 98.00, 'opening',
          public._px_today())
  returning id into sA;

  insert into public.pharmacy_stock(
      pharmacy_id, product_name, pack_label, item_key, batch_no, expiry,
      expiry_on, qty, unit_cost, mrp, source_kind, received_on)
  values (B, 'C420 Insulin Pen', '1 pen', 'c420insu|N9', 'N9', '11/27',
          public._px_today() + 400, 12, 240.00, 320.00, 'opening', public._px_today())
  returning id into sB;

  insert into public.px_listing(
      seller_id, zone_id, stock_id, product_name, pack_label,
      batch_no, expiry, expiry_on, qty_listed, qty_remaining, unit_price,
      mrp, unit_cost, gst_percent)
  select A, v_zone, sA, ps.product_name, ps.pack_label, ps.batch_no,
         ps.expiry, ps.expiry_on, 10, 10, 70.00, ps.mrp, ps.unit_cost, 12
    from public.pharmacy_stock ps where ps.id = sA
  returning id into v_listing;

  v_disc := public._px_disclosure_text('C420 Amoxycillin 500', 'B420', '03/27',
              public._px_today() + 75);
  v_ok := position('B420' in v_disc) > 0 and position('03/27' in v_disc) > 0
          and position('75' in v_disc) > 0;
  v_steps := v_steps || jsonb_build_object('step','1 listing discloses batch + expiry + days',
    'pass', v_ok, 'disclosure', v_disc);
  v_pass := v_pass and v_ok;

  v_res := public._px_browse(B, 'C420 Amox', 20);
  v_rows := v_res->'rows';
  v_ok := coalesce((v_res->>'ok')::boolean,false)
          and jsonb_array_length(coalesce(v_rows,'[]'::jsonb)) = 1
          and (v_rows->0->>'batch_label') like '%B420%'
          and (v_rows->0->>'expiry_label') like '%03/27%'
          and (v_rows->0->>'days_label') like '%75%';
  v_steps := v_steps || jsonb_build_object('step','2 buyer browses zone; batch+expiry are ON the row',
    'pass', v_ok, 'batch', v_rows->0->>'batch_label',
    'expiry', v_rows->0->>'expiry_label', 'days', v_rows->0->>'days_label',
    'price', v_rows->0->>'price_display');
  v_pass := v_pass and v_ok;

  insert into public.px_deal(
      kind, listing_id, seller_id, buyer_id, zone_id, product_name, pack_label,
      batch_no, expiry, qty, unit_price, line_amount, gst_percent)
  values ('exchange', v_listing, A, B, v_zone, 'C420 Amoxycillin 500', '10 caps',
          'B420', '03/27', 4, 70.00, 280.00, 12)
  returning id into v_deal;

  v_res := public._px_settle(v_deal);
  select invoice_no into v_inv from public.px_deal where id = v_deal;
  select qty into v_qA from public.pharmacy_stock where id = sA;
  select coalesce(sum(qty),0) into v_qB from public.pharmacy_stock
   where pharmacy_id = B and batch_no = 'B420';
  v_ok := coalesce((v_res->>'ok')::boolean,false) and v_qA = 36 and v_qB = 4 and v_inv is not null;
  v_steps := v_steps || jsonb_build_object('step','3 accept -> invoice + BOTH shelves move',
    'pass', v_ok, 'invoice_no', v_inv, 'seller_40_to_36', v_qA,
    'buyer_0_to_4', v_qB, 'total', v_res->>'total_display');
  v_pass := v_pass and v_ok;

  v_res := public.px_invoice_render_input(v_deal);
  v_ok := (v_res->'invoice'->'seller'->>'gstin_label') = 'GSTIN: 22AAAAA0000A1Z5'
      and (v_res->'invoice'->'buyer'->>'gstin_label')  = 'GSTIN: 22BBBBB0000B1Z5'
      and (v_res->'invoice'->'net'->>'value') = public.inr_money(313.60)
      and (v_res->'invoice'->>'disclosure') like '%B420%';
  v_steps := v_steps || jsonb_build_object('step','4 invoice carries BOTH GSTINs; 12% on 280 = 313.60',
    'pass', v_ok, 'seller_gstin', v_res->'invoice'->'seller'->>'gstin_label',
    'buyer_gstin', v_res->'invoice'->'buyer'->>'gstin_label',
    'net', v_res->'invoice'->'net'->>'value');
  v_pass := v_pass and v_ok;

  select disclosure_text into v_disc from public.px_disclosure where deal_id = v_deal;
  v_ok := v_disc is not null and position('B420' in v_disc) > 0;
  v_steps := v_steps || jsonb_build_object('step','5 disclosure frozen against the deal',
    'pass', v_ok, 'stored', v_disc);
  v_pass := v_pass and v_ok;

  -- 6: the courier job, and the deal following it
  select id, status into v_job, v_jstatus from public.px_delivery_job where deal_id = v_deal;
  v_ok := v_job is not null and v_jstatus = 'queued';
  perform public._px_job_advance(v_job, 'picked');
  select status into v_dstatus from public.px_deal where id = v_deal;
  v_ok := v_ok and v_dstatus = 'dispatched';
  perform public._px_job_advance(v_job, 'delivered', 'C420 Beta counter');
  select status into v_dstatus from public.px_deal where id = v_deal;
  v_ok := v_ok and v_dstatus = 'delivered';
  v_steps := v_steps || jsonb_build_object(
    'step','6 rider job booked; deal follows it to dispatched then delivered',
    'pass', v_ok, 'job_status_at_accept', v_jstatus, 'deal_status_at_end', v_dstatus,
    'promise', (select to_char(promised_at at time zone 'Asia/Kolkata','HH24:MI')
                  from public.px_delivery_job where id = v_job));
  v_pass := v_pass and v_ok;

  -- ══ LOOP 2 — EMERGENCY BORROW ═══════════════════════════════════════════
  v_res := public._px_borrow_search(A, 'C420 Insulin', 1);
  v_rows := v_res->'rows';
  v_ok := coalesce((v_res->>'ok')::boolean,false)
          and jsonb_array_length(coalesce(v_rows,'[]'::jsonb)) = 1
          and (v_rows->0->>'seller_name') = 'C420 Beta Chemists'
          and (v_rows->0->>'has_enough') = 'true'
          and (v_rows->0->>'distance_hint') is not null;
  select exists (
           select 1 from jsonb_each_text(coalesce(v_rows->0,'{}'::jsonb)) kv
            where kv.key ~* '(qty|quantity|stock_level|on_hand|balance)'
               or (kv.key <> 'stock_id' and kv.key <> 'pharmacy_id'
                   and kv.value = '12'))
         into v_leak;
  v_steps := v_steps || jsonb_build_object(
    'step','7 borrow search: who + distance + ETA, and NO stock level',
    'pass', v_ok and not v_leak, 'leaked_their_qty', v_leak,
    'seller', v_rows->0->>'seller_name', 'distance', v_rows->0->>'distance_hint',
    'promise', v_rows->0->>'promise_label', 'basis', v_rows->0->>'price_basis',
    'keys', (select jsonb_agg(k) from jsonb_object_keys(coalesce(v_rows->0,'{}'::jsonb)) k));
  v_pass := v_pass and v_ok and not v_leak;

  insert into public.px_listing(
      seller_id, zone_id, stock_id, product_name, pack_label, batch_no, expiry,
      expiry_on, qty_listed, qty_remaining, unit_price, mrp, unit_cost,
      gst_percent, note)
  select B, v_zone, sB, ps.product_name, ps.pack_label, ps.batch_no, ps.expiry,
         ps.expiry_on, 1, 1, 320.00, ps.mrp, ps.unit_cost, 5,
         public.ui_text('px.borrow_note')
    from public.pharmacy_stock ps where ps.id = sB
  returning id into v_listing;

  insert into public.px_deal(
      kind, listing_id, seller_id, buyer_id, zone_id, product_name, pack_label,
      batch_no, expiry, qty, unit_price, line_amount, gst_percent)
  values ('borrow', v_listing, B, A, v_zone, 'C420 Insulin Pen', '1 pen',
          'N9', '11/27', 1, 320.00, 320.00, 5)
  returning id into v_deal2;

  v_res := public._px_settle(v_deal2);
  select qty into v_qB from public.pharmacy_stock where id = sB;
  select coalesce(sum(qty),0) into v_qA from public.pharmacy_stock
   where pharmacy_id = A and batch_no = 'N9';
  v_ok := coalesce((v_res->>'ok')::boolean,false) and v_qB = 11 and v_qA = 1
          and (v_res->>'job_id') is not null;
  v_steps := v_steps || jsonb_build_object(
    'step','8 borrow accepted -> pen moves B->A, invoiced, rider booked',
    'pass', v_ok, 'lender_12_to_11', v_qB, 'borrower_0_to_1', v_qA,
    'invoice', (select invoice_no from public.px_deal where id = v_deal2),
    'promise', v_res->>'promise_label', 'distance', v_res->'distance'->>'label');
  v_pass := v_pass and v_ok;

  select count(*) = 4 into v_ok from public.pharmacy_stock_move
   where ref_kind = 'px_deal' and pharmacy_id in (A,B)
     and reason_code in ('px_exchange_out','px_exchange_in','px_borrow_out','px_borrow_in');
  v_steps := v_steps || jsonb_build_object('step','9 four ledger rows — every movement documented',
    'pass', v_ok,
    'rows', (select count(*) from public.pharmacy_stock_move
              where ref_kind='px_deal' and pharmacy_id in (A,B)));
  v_pass := v_pass and v_ok;

  update public.pharmacy_profiles set zone_id = v_other_zone where id = B;
  v_res := public._px_borrow_search(A, 'C420 Insulin', 1);
  v_ok := coalesce((v_res->>'ok')::boolean,false)
          and jsonb_array_length(coalesce(v_res->'rows','[]'::jsonb)) = 0;
  v_steps := v_steps || jsonb_build_object(
    'step','10 zone fence: search still OK, B invisible',
    'pass', v_ok, 'ok', v_res->>'ok',
    'rows', jsonb_array_length(coalesce(v_res->'rows','[]'::jsonb)));
  v_pass := v_pass and v_ok;

  insert into public.px_deal(
      kind, listing_id, seller_id, buyer_id, zone_id, product_name,
      batch_no, expiry, qty, unit_price, line_amount, gst_percent)
  values ('borrow', v_listing, B, A, v_zone, 'C420 Insulin Pen',
          'N9', '11/27', 1, 320.00, 320.00, 5)
  returning id into v_deal;
  v_res := public._px_settle(v_deal);
  v_ok := coalesce((v_res->>'ok')::boolean,true) = false
          and (v_res->>'error') = 'not_eligible';
  v_steps := v_steps || jsonb_build_object(
    'step','11 cross-zone settlement refused, not silently allowed',
    'pass', v_ok, 'error', v_res->>'error', 'message', v_res->>'message');
  v_pass := v_pass and v_ok;

  delete from public.px_delivery_job where deal_id in
    (select id from public.px_deal where seller_id in (A,B) or buyer_id in (A,B));
  delete from public.px_disclosure where deal_id in
    (select id from public.px_deal where seller_id in (A,B) or buyer_id in (A,B));
  delete from public.px_deal where seller_id in (A,B) or buyer_id in (A,B);
  delete from public.px_listing where seller_id in (A,B);
  delete from public.pharmacy_stock_move where pharmacy_id in (A,B);
  delete from public.pharmacy_stock where pharmacy_id in (A,B);
  delete from public.px_invoice_counter where pharmacy_id in (A,B);
  delete from public.px_pair_distance where from_id in (A,B) or to_id in (A,B);
  delete from public.pharmacy_profiles where id in (A,B);

  return jsonb_build_object('ok', v_pass, 'steps', v_steps,
    'summary', case when v_pass
      then 'two seeded pharmacies, both loops: list -> browse with batch+expiry -> buy -> invoice on both GSTINs -> both shelves move -> rider booked and followed to delivered; borrow search leaks no stock level; zone fence hides AND refuses'
      else 'one or more steps failed' end);
end $function$
;

CREATE OR REPLACE FUNCTION public.px_shop()
 RETURNS uuid
 LANGUAGE sql
 STABLE
AS $function$ select public.pos_shop(); $function$
;

CREATE OR REPLACE FUNCTION public.ui_fmt(p_key text, p_vars jsonb)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
declare v_out text := public.ui_text(p_key); k text;
begin
  if coalesce(v_out,'') = '' then return ''; end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{{' || k || '}}', coalesce(p_vars->>k, ''));
  end loop;
  return v_out;
end $function$
;

CREATE OR REPLACE FUNCTION public.ui_fmt_body(p_body text, p_vars jsonb)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
declare v_out text := coalesce(p_body,''); k text;
begin
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_out := replace(v_out, '{{' || k || '}}', coalesce(p_vars->>k, ''));
  end loop;
  return v_out;
end $function$
;
