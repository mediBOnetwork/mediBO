-- CMD #450 — HIGH defects, admin surface, batch B.
-- feature_gaps rows 18, 19, 20, 23, 41 and 43 (the LAST 6 approved
-- severity=high surface=admin rows by id; batch A / #449 took the first 6).
--
-- Six register rows, all of them money or send-health, all of them the same
-- shape: the DATA is there and nothing ages it, groups it or shows it. So
-- everything here is backend-first — every rupee, age, plural, tone, bucket
-- name and sentence is built in SQL and the screen prints it verbatim.
--
--   #18 admin_claim_queue / admin_claim_ask_utr — the verification queue,
--       OLDEST FIRST, with a missing UTR as an explicit state and an ask.
--   #19 admin_unmatched_payments — it filtered `status='claimed'`, a status NO
--       payment_claims row has ever held, so it returned 0 for the one live
--       claim with order_id NULL. Fixed, plus admin_claim_attach.
--   #20 admin_bill_queue — 13 pending bills, oldest 90 days, four age buckets
--       and a stalled headline.
--   #23 admin_receivables / _orders / _chase — who owes what and for how long.
--       Open value is the TRADE total minus VERIFIED payments; never MRP.
--   #41 wa_send_health — it returned faults[] while the screen reads rows[],
--       so the Send Health feed rendered EMPTY. Now returns both, plus the
--       reasons[] grouping; wa_send_retry resends order-less sends.
--   #43 wa_route_blockers / wa_event_route_save / wa_event_routes_screen — an
--       approved template with a media header and no sample handle is the
--       missing_header_media failure. Refused at SAVE time, and the 27
--       already-broken switched-on routes are flagged before a send.
--
-- Idempotent throughout: create or replace, insert ... on conflict. A resumed
-- worker re-applying this is a silent no-op.

CREATE OR REPLACE FUNCTION public._c450_age_bucket(p_days integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when coalesce(p_days,0) <= 7  then 'b0_7'
              when coalesce(p_days,0) <= 15 then 'b8_15'
              when coalesce(p_days,0) <= 30 then 'b16_30'
              else 'b30p' end;
$function$
;

CREATE OR REPLACE FUNCTION public._c450_age_days(p_at timestamp with time zone)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when p_at is null then 0
              else floor(extract(epoch from (now() - p_at))/86400.0)::int end;
$function$
;

CREATE OR REPLACE FUNCTION public._c450_age_label(p_at timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_at is null then 'No date'
    when floor(extract(epoch from (now() - p_at))/86400.0) < 1 then 'Today'
    when floor(extract(epoch from (now() - p_at))/86400.0) < 2 then 'Yesterday'
    else floor(extract(epoch from (now() - p_at))/86400.0)::int || ' days old'
  end;
$function$
;

CREATE OR REPLACE FUNCTION public._c450_age_tone(p_days integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when coalesce(p_days,0) >= 30 then 'bad'
              when coalesce(p_days,0) >= 15 then 'warn'
              when coalesce(p_days,0) >= 7  then 'info'
              else 'good' end;
$function$
;

CREATE OR REPLACE FUNCTION public._c450_bucket_label(p_key text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_key
    when 'b0_7'   then '0–7 days'
    when 'b8_15'  then '8–15 days'
    when 'b16_30' then '16–30 days'
    when 'b30p'   then 'Over 30 days'
    else p_key end;
$function$
;

CREATE OR REPLACE FUNCTION public._c450_bucket_sort(p_key text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_key when 'b30p' then 1 when 'b16_30' then 2
                    when 'b8_15' then 3 when 'b0_7' then 4 else 9 end;
$function$
;

CREATE OR REPLACE FUNCTION public._c450_bucket_tone(p_key text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_key
    when 'b0_7'   then 'good'
    when 'b8_15'  then 'info'
    when 'b16_30' then 'warn'
    when 'b30p'   then 'bad'
    else 'muted' end;
$function$
;

CREATE OR REPLACE FUNCTION public.admin_bill_queue(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_buckets jsonb; v_n int; v_stalled int; v_oldest int;
        v_stall_days int := 30;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  with b as (
    select pb.*,
           public._c450_age_days(coalesce(pb.received_at, pb.created_at)) as age_days
      from pending_bills pb
     where coalesce(pb.status,'pending') = 'pending'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'bill_id',       b.id,
           'file_name',     coalesce(nullif(btrim(b.file_name),''), 'Untitled bill'),
           'bucket',        coalesce(b.bucket, 'supplier-bills'),
           'file_path',     b.file_path,
           'supplier_name', coalesce(nullif(btrim(b.supplier_name),''), 'Unknown supplier'),
           'source',        coalesce(b.source,''),
           'received_label','Arrived ' || to_char(coalesce(b.received_at,b.created_at) at time zone 'Asia/Kolkata','DD Mon yyyy'),
           'age_days',      b.age_days,
           'age_label',     public._c450_age_label(coalesce(b.received_at, b.created_at)),
           'age_tone',      public._c450_age_tone(b.age_days),
           'age_bucket',    public._c450_age_bucket(b.age_days),
           -- The scan already succeeded on most of these; saying so is what
           -- turns "old" into "old AND ready", which is the actionable state.
           'scan_status',   coalesce(b.scan_status,'none'),
           'scan_label',    case coalesce(b.scan_status,'none')
                              when 'done'    then 'Scanned and ready to import'
                              when 'error'   then 'The scan failed — open it and import by hand'
                              when 'pending' then 'Still scanning'
                              else 'Not scanned yet' end,
           'scan_tone',     case coalesce(b.scan_status,'none')
                              when 'done'  then 'good'
                              when 'error' then 'bad'
                              else 'muted' end,
           'ready',         coalesce(b.scan_status,'') = 'done',
           'stalled',       b.age_days >= v_stall_days,
           'stalled_label', case when b.age_days >= v_stall_days
                                 then 'Stalled ' || b.age_days || ' days' else '' end,
           'open_label',    'Open and import'
         ) order by b.age_days desc), '[]'::jsonb)
    into v_rows
    from b
   where true
   limit greatest(1, coalesce(p_limit,200));

  select count(*)::int,
         count(*) filter (where public._c450_age_days(coalesce(received_at,created_at)) >= v_stall_days)::int,
         coalesce(max(public._c450_age_days(coalesce(received_at,created_at))),0)
    into v_n, v_stalled, v_oldest
    from pending_bills where coalesce(status,'pending') = 'pending';

  -- The four age buckets, always all four, so an empty one is a visible zero
  -- rather than a row that quietly disappeared.
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', k, 'label', public._c450_bucket_label(k),
           'tone', public._c450_bucket_tone(k),
           'count', n,
           'count_label', n || case when n = 1 then ' bill' else ' bills' end)
         order by public._c450_bucket_sort(k)), '[]'::jsonb)
    into v_buckets
    from (
      select k, coalesce((
        select count(*)::int from pending_bills pb
         where coalesce(pb.status,'pending')='pending'
           and public._c450_age_bucket(public._c450_age_days(coalesce(pb.received_at,pb.created_at))) = k
      ),0) as n
      from unnest(array['b30p','b16_30','b8_15','b0_7']) k
    ) t;

  return jsonb_build_object(
    'ok', true,
    'rows', v_rows,
    'buckets', v_buckets,
    'count', v_n,
    'headline', case when v_n = 0 then 'No bills waiting'
                     when v_n = 1 then '1 bill waiting to be imported'
                     else v_n || ' bills waiting to be imported' end,
    'stalled_count', v_stalled,
    'stalled_headline', case when v_stalled = 0 then ''
                             when v_stalled = 1 then '1 bill has been waiting over 30 days'
                             else v_stalled || ' bills have been waiting over 30 days' end,
    'stalled_tone', case when v_stalled > 0 then 'bad' else 'good' end,
    'oldest_label', case when v_n = 0 then ''
                         else 'Oldest arrived ' || v_oldest || ' days ago' end,
    'empty_label', 'Every bill that arrived has been imported.',
    'note', 'Oldest first. A bill marked ready has already been scanned — it is only waiting for someone to import it.');
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_claim_ask_utr(p_claim_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c record; v jsonb; v_ok boolean := false;
begin
  if not is_admin() then return jsonb_build_object('ok', false, 'message', 'Not allowed'); end if;
  select * into c from payment_claims where id = p_claim_id;
  if c.id is null then
    return jsonb_build_object('ok', false, 'message', 'That payment claim no longer exists.');
  end if;
  if nullif(btrim(c.utr),'') is not null then
    return jsonb_build_object('ok', false, 'message', 'This claim already carries a UTR.');
  end if;
  if nullif(btrim(c.sender_phone),'') is null then
    return jsonb_build_object('ok', false,
      'message', 'This claim has no sender number, so there is nobody to ask.');
  end if;

  begin
    v := public.wa_send_event_or_fallback('payment_utr_request', null,
           jsonb_build_object('amount', public.inr_money(c.amount)),
           c.sender_phone, c.order_id);
    v_ok := coalesce((v->>'ok')::boolean, false);
  exception when others then
    v_ok := false;
    v := jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;

  update payment_claims
     set autolink_note = 'UTR asked for on '
                       || to_char(now() at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
                       || case when v_ok then '' else ' (WhatsApp could not deliver it)' end
   where id = p_claim_id;

  return jsonb_build_object(
    'ok', v_ok,
    'message', case when v_ok
                    then 'Asked ' || c.sender_phone || ' for the UTR on WhatsApp.'
                    else 'Could not send the request: '
                         || coalesce(v->>'reason','WhatsApp refused it')
                         || '. The ask is noted on the claim.' end,
    'detail', v);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_claim_attach(p_claim_id uuid, p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; c record; o record;
begin
  if not is_admin() then return jsonb_build_object('ok', false, 'message', 'Not allowed'); end if;
  select * into c from payment_claims where id = p_claim_id;
  if c.id is null then
    return jsonb_build_object('ok', false, 'message', 'That payment claim no longer exists.');
  end if;
  if c.order_id is not null then
    return jsonb_build_object('ok', false, 'message', 'This payment is already attached to an order.');
  end if;
  select * into o from orders where id = p_order_id;
  if o.id is null then
    return jsonb_build_object('ok', false, 'message', 'That order no longer exists.');
  end if;

  update payment_claims set order_id = p_order_id where id = p_claim_id;

  return jsonb_build_object('ok', true,
    'message', public.inr_money(c.amount) || ' attached to '
             || coalesce(nullif(btrim(o.order_code),''),'this order')
             || '. It is now in the verification queue.');
end $function$
;

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

CREATE OR REPLACE FUNCTION public.admin_money_home()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_claims int; v_unmatched int; v_bills int; v_recv numeric;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select count(*)::int into v_claims from payment_claims where status='received';
  select count(*)::int into v_unmatched from payment_claims
   where order_id is null and coalesce(status,'') not in ('rejected','cancelled');
  select count(*)::int into v_bills from pending_bills where coalesce(status,'pending')='pending';
  select coalesce(sum(round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2)),0)
    into v_recv
    from orders o
    left join lateral (select sum(p.amount) amt from payment_claims p
                        where p.order_id=o.id and p.status='verified') paid on true
   where coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2) > 0;

  return jsonb_build_object(
    'ok', true,
    'title', 'Money',
    'subtitle', 'What is owed, what arrived, and what is still waiting on somebody.',
    'tabs', jsonb_build_array(
      jsonb_build_object('tab_key','receivables', 'label','Owed to us',
        'badge', case when v_recv > 0 then public.inr_money_compact(v_recv) else '' end,
        'badge_tone', case when v_recv > 0 then 'bad' else 'good' end),
      jsonb_build_object('tab_key','claims', 'label','To verify',
        'badge', case when v_claims > 0 then v_claims::text else '' end,
        'badge_tone', case when v_claims > 0 then 'warn' else 'good' end),
      jsonb_build_object('tab_key','unmatched', 'label','Unattached money',
        'badge', case when v_unmatched > 0 then v_unmatched::text else '' end,
        'badge_tone', case when v_unmatched > 0 then 'bad' else 'good' end),
      jsonb_build_object('tab_key','bills', 'label','Supplier bills',
        'badge', case when v_bills > 0 then v_bills::text else '' end,
        'badge_tone', case when v_bills > 0 then 'warn' else 'good' end)
    ),
    'unknown_tab_label', '');
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_receivables()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cust jsonb; v_buckets jsonb; v_total numeric; v_n int; v_orders int; v_oldest int;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  with open_orders as (
    select o.id as order_id, o.user_id,
           coalesce(nullif(btrim(pp.pharmacy_name),''), 'Unknown customer') as customer_name,
           o.created_at,
           round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2) as open_amount,
           public._c450_age_days(o.created_at) as age_days,
           public._c450_age_bucket(public._c450_age_days(o.created_at)) as bucket
      from orders o
      left join pharmacy_profiles pp on pp.user_id = o.user_id and coalesce(pp.is_deleted,false) = false
      left join lateral (
        select sum(p.amount) amt from payment_claims p
         where p.order_id = o.id and p.status = 'verified'
      ) paid on true
     where coalesce(o.status,'pending') in ('pending','accepted')
       and coalesce(o.fulfillment_status,'open') <> 'cancelled'
       and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2) > 0
  ),
  per_customer as (
    select user_id, min(customer_name) as customer_name,
           sum(open_amount) as open_amount, count(*)::int as n, max(age_days) as oldest
      from open_orders group by user_id
  ),
  bucket_totals as (
    select k,
           coalesce((select sum(open_amount) from open_orders o where o.bucket = k),0) as v,
           coalesce((select count(*)::int    from open_orders o where o.bucket = k),0) as n
      from unnest(array['b30p','b16_30','b8_15','b0_7']) k
  )
  select
    (select count(*)::int from open_orders),
    (select coalesce(sum(open_amount),0) from open_orders),
    (select coalesce(max(age_days),0) from open_orders),
    (select count(*)::int from per_customer),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'user_id',       t.user_id,
        'customer_name', t.customer_name,
        'open_label',    public.inr_money(t.open_amount),
        'open_amount',   t.open_amount,
        'order_count',   t.n,
        'order_count_label', t.n || case when t.n = 1 then ' open order' else ' open orders' end,
        'age_days',      t.oldest,
        'age_label',     'Oldest ' || t.oldest || case when t.oldest = 1 then ' day' else ' days' end,
        'age_tone',      public._c450_age_tone(t.oldest),
        'bucket',        public._c450_age_bucket(t.oldest),
        'bucket_label',  public._c450_bucket_label(public._c450_age_bucket(t.oldest)),
        'chase_label',   'Chase on WhatsApp',
        'open_orders_label', 'See the orders')
      order by t.open_amount desc), '[]'::jsonb) from per_customer t),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'key', b.k, 'label', public._c450_bucket_label(b.k),
        'tone', public._c450_bucket_tone(b.k),
        'value_label', public.inr_money(b.v),
        'count', b.n,
        'count_label', b.n || case when b.n = 1 then ' order' else ' orders' end)
      order by public._c450_bucket_sort(b.k)), '[]'::jsonb) from bucket_totals b)
  into v_orders, v_total, v_oldest, v_n, v_cust, v_buckets;

  return jsonb_build_object(
    'ok', true,
    'total_label', public.inr_money(v_total),
    'total_amount', v_total,
    'headline', case when v_orders = 0 then 'Nothing is owed'
                     else public.inr_money(v_total) || ' open across '
                          || v_orders || case when v_orders = 1 then ' order' else ' orders' end end,
    'sub_headline', case when v_n = 0 then ''
                         when v_n = 1 then 'From 1 customer'
                         else 'From ' || v_n || ' customers' end,
    'oldest_label', case when v_orders = 0 then ''
                         else 'Oldest open order is ' || v_oldest || ' days old' end,
    'oldest_tone', public._c450_age_tone(v_oldest),
    'buckets', v_buckets,
    'rows', v_cust,
    'customers', v_cust,
    'empty_label', 'Every order that was placed has been paid for.',
    'note', 'Open value is the order total minus payments verified against it. MRP is never used.');
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_receivables_chase(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; v_ok boolean := false; v_phone text; v_name text; v_open numeric;
begin
  if not is_admin() then return jsonb_build_object('ok', false, 'message', 'Not allowed'); end if;

  select nullif(btrim(coalesce(pp.whatsapp_no, pp.phone,'')),''),
         coalesce(nullif(btrim(pp.pharmacy_name),''),'this customer')
    into v_phone, v_name
    from pharmacy_profiles pp
   where pp.user_id = p_user_id and coalesce(pp.is_deleted,false)=false limit 1;

  select coalesce(sum(round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2)),0)
    into v_open
    from orders o
    left join lateral (select sum(p.amount) amt from payment_claims p
                        where p.order_id=o.id and p.status='verified') paid on true
   where o.user_id = p_user_id
     and coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2) > 0;

  if v_phone is null then
    return jsonb_build_object('ok', false,
      'message', 'No WhatsApp number on ' || v_name || ' — there is nobody to chase.');
  end if;

  begin
    v := public.wa_send_event_or_fallback('payment_due_reminder', p_user_id,
           jsonb_build_object('amount', public.inr_money(v_open)), v_phone, null);
    v_ok := coalesce((v->>'ok')::boolean, false);
  exception when others then
    v_ok := false; v := jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;

  return jsonb_build_object('ok', v_ok,
    'message', case when v_ok
                    then 'Reminded ' || v_name || ' about ' || public.inr_money(v_open) || ' on WhatsApp.'
                    else 'Could not send the reminder: ' || coalesce(v->>'reason','WhatsApp refused it') end,
    'detail', v);
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_receivables_orders(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_name text; v_total numeric;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''),'Unknown customer')
    into v_name from pharmacy_profiles pp
   where pp.user_id = p_user_id and coalesce(pp.is_deleted,false) = false limit 1;

  select coalesce(jsonb_agg(x order by (x->>'age_days')::int desc), '[]'::jsonb),
         coalesce(sum((x->>'open_amount')::numeric),0)
    into v_rows, v_total
  from (
    select jsonb_build_object(
      'order_id',     o.id,
      'order_code',   coalesce(nullif(btrim(o.order_code),''),'PO-'||upper(right(replace(o.id::text,'-',''),4))),
      'placed_label', 'Placed ' || to_char(o.created_at at time zone 'Asia/Kolkata','DD Mon yyyy'),
      'total_label',  public.inr_money(o.total_amount),
      'paid_label',   public.inr_money(coalesce(paid.amt,0)),
      'open_amount',  round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2),
      'open_label',   public.inr_money(round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2)),
      'has_paid',     coalesce(paid.amt,0) > 0,
      'paid_note',    case when coalesce(paid.amt,0) = 0
                           then 'No payment has ever been recorded against this order'
                           else public.inr_money(paid.amt) || ' verified so far' end,
      'age_days',     public._c450_age_days(o.created_at),
      'age_label',    public._c450_age_label(o.created_at),
      'age_tone',     public._c450_age_tone(public._c450_age_days(o.created_at)),
      'status_label', initcap(coalesce(o.status,'pending'))
    ) as x
    from orders o
    left join lateral (
      select sum(p.amount) amt from payment_claims p where p.order_id = o.id and p.status='verified'
    ) paid on true
   where o.user_id = p_user_id
     and coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2) > 0
  ) q;

  return jsonb_build_object('ok', true, 'customer_name', coalesce(v_name,'Unknown customer'),
    'rows', v_rows, 'total_label', public.inr_money(v_total),
    'headline', coalesce(v_name,'Unknown customer') || ' owes ' || public.inr_money(v_total),
    'empty_label', 'This customer has nothing open.');
end $function$
;

CREATE OR REPLACE FUNCTION public.admin_unmatched_payments()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare result jsonb; v_sum numeric; v_n int;
        v_date date := public.scope_date();      -- the ONE date source
        v_zone smallint := public.scope_zone();  -- NULL = all zones
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_agg(x order by (x->>'age_days')::int desc), '[]'::jsonb) into result
  from (
    select jsonb_build_object(
      'claim_id', pc.id,
      'amount', pc.amount,
      'amount_label', public.inr_money(pc.amount),
      'utr', pc.utr, 'txn_id', pc.txn_id, 'app', pc.app,
      'has_utr', nullif(btrim(pc.utr),'') is not null,
      'utr_label', coalesce(nullif(btrim(pc.utr),''), 'No UTR on this claim'),
      'utr_tone', case when nullif(btrim(pc.utr),'') is null then 'bad' else 'good' end,
      'payee_name', pc.payee_name,
      'file_path', pc.file_path,
      'bucket', case when pc.file_path like 'whatsapp/%' or pc.file_path like 'cash_payments/%'
                     then 'whatsapp-media' else 'payment-proofs' end,
      'status', pc.status,
      'sender_phone', pc.sender_phone,
      'customer_name', coalesce(pp.pharmacy_name, 'Unknown sender'),
      'paid_ts', pc.paid_ts,
      'age_days',  public._c450_age_days(pc.received_at),
      'age_label', public._c450_age_label(pc.received_at),
      'age_tone',  public._c450_age_tone(public._c450_age_days(pc.received_at)),
      'paid_label', coalesce(nullif(btrim(pc.paid_at), ''),
                     to_char(pc.received_at at time zone 'Asia/Kolkata','FMHH12:MI am "on" DD Mon')),
      'note', coalesce(pc.autolink_note, 'No matching order.'),
      'attach_label', 'Attach to this order',
      -- Every candidate carries the sentence that justifies it, so the one-tap
      -- attach is never a guess the admin has to reconstruct.
      -- UNSCOPED on purpose: matching must see every date and zone.
      'candidates', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'order_id', o.id,
                 'order_code', coalesce(nullif(btrim(o.order_code),''),'PO-'||upper(right(replace(o.id::text,'-',''),4))),
                 'placed_label', to_char(o.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI am'),
                 'total_label', public.inr_money(o.total_amount),
                 'match_label', case
                    when o.total_amount is not null and abs(o.total_amount - pc.amount) < 0.01
                      then 'Same amount'
                    else 'Placed ' || abs(round(extract(epoch from (coalesce(pc.paid_ts, pc.received_at) - o.created_at))/86400.0))::int
                         || ' days from the payment' end,
                 'days_gap', round(extract(epoch from (coalesce(pc.paid_ts, pc.received_at) - o.created_at))/86400.0, 2))
               order by (case when o.total_amount is not null and abs(o.total_amount - pc.amount) < 0.01 then 0 else 1 end),
                        o.created_at desc)
        from orders o
        where o.user_id = pp.user_id
          and coalesce(o.fulfillment_status,'open') <> 'cancelled'
          and coalesce(o.status,'pending') <> 'rejected'
          and coalesce(pc.paid_ts, pc.received_at) between o.created_at
                              - make_interval(hours => coalesce((select pay_link_hours_before from billing_config where id=1),12))
                            and o.created_at
                              + make_interval(days => coalesce((select pay_link_days_after from billing_config where id=1),7))
      ), '[]'::jsonb)
    ) as x
    from payment_claims pc
    left join pharmacy_profiles pp
      on right(regexp_replace(coalesce(pp.whatsapp_no, pp.phone,''),'\D','','g'),10)
       = right(regexp_replace(coalesce(pc.sender_phone,''),'\D','','g'),10)
     and coalesce(pp.is_deleted,false) = false
    where pc.order_id is null
      and coalesce(pc.status,'') not in ('rejected','cancelled')
      -- SCOPE (display only) — restored; this is what the contract asks for.
      and (pc.received_at at time zone 'Asia/Kolkata')::date <= v_date
      and public.scope_zone_ok(pp.zone_id, v_zone)
  ) q;

  select count(*)::int, coalesce(sum((x->>'amount')::numeric),0)
    into v_n, v_sum
    from jsonb_array_elements(result) x;

  return jsonb_build_object(
    'ok', true,
    'count', v_n,
    'claims', result,
    'rows', result,
    'headline', case when v_n = 0 then 'No unattached money'
                     when v_n = 1 then '1 payment is not attached to any order'
                     else v_n || ' payments are not attached to any order' end,
    'value_label', public.inr_money(v_sum),
    'tone', case when v_n = 0 then 'good' else 'bad' end,
    'empty_label', 'Every payment that arrived is sitting on an order.',
    'no_candidate_label', 'No order this payment could belong to — the sender is not a known customer, or nothing was placed near the payment date.',
    'note', 'Money that landed with nothing to attach it to. Attaching one here is the same link the verification queue makes.',
    'the_date', v_date,
    'zone_id', v_zone);
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_event_route_save(p_event_key text, p_template_id uuid DEFAULT NULL::uuid, p_variable_map jsonb DEFAULT NULL::jsonb, p_enabled boolean DEFAULT NULL::boolean, p_bypass_window boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; r record; b jsonb; v_will_be_on boolean;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then return jsonb_build_object('error','unknown_event'); end if;

  if p_template_id is not null then
    select * into t from wa_templates where id = p_template_id;
    if t.id is null then return jsonb_build_object('error','no_template','message','Pick a template'); end if;
  end if;

  v_will_be_on := coalesce(p_enabled, r.enabled);

  -- A route that will be ON must be sendable. Everything that would have made
  -- a send fail is refused here instead, with the reason in plain words.
  if v_will_be_on then
    b := public.wa_route_blockers(p_event_key, coalesce(p_template_id, r.template_id));
    if coalesce((b->>'blocked')::boolean, false) then
      return jsonb_build_object('error', b->>'error', 'message', b->>'message',
                                'blocker_label', b->>'blocker_label');
    end if;
  elsif p_template_id is not null and t.status <> 'APPROVED' then
    -- Even switched off, an unapproved template is never worth storing.
    return jsonb_build_object('error','not_approved',
      'message', 'That template is ' || t.status || ' at Meta — only approved templates can be sent');
  end if;

  update wa_event_routes set
    template_id   = coalesce(p_template_id, template_id),
    template_name = coalesce(t.name, template_name),
    language      = coalesce(t.language, language),
    variable_map  = coalesce(p_variable_map, variable_map),
    enabled       = coalesce(p_enabled, enabled),
    bypass_send_window = coalesce(p_bypass_window, bypass_send_window),
    updated_at    = now()
  where event_key = p_event_key;

  return jsonb_build_object('ok', true, 'event_key', p_event_key,
    'enabled', (select enabled from wa_event_routes where event_key = p_event_key));
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_event_routes_screen()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_blocked int;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;

  select coalesce(jsonb_agg(x order by x->>'event_key'), '[]'::jsonb),
         count(*) filter (where (x->>'blocked')::boolean)::int
    into v_rows, v_blocked
  from (
    select jsonb_build_object(
      'event_key', r.event_key, 'label', r.label, 'description', r.description,
      'audience', r.audience,
      'audience_label', coalesce((select a->>'label' from jsonb_array_elements(public.wa_audience_types()) a
                                   where a->>'value' = r.audience), initcap(r.audience)),
      'audience_sort', coalesce((select (a->>'sort')::int from jsonb_array_elements(public.wa_audience_types()) a
                                  where a->>'value' = r.audience), 99),
      'auto_manage', r.auto_manage,
      'auto_template_name', r.auto_template_name,
      'pipeline_note', r.pipeline_note,
      'meta_status', (select t.status from wa_templates t
                       where t.name = r.auto_template_name order by (t.language='en') desc limit 1),
      'stage', case
        when r.enabled and r.template_id is not null then 'live'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'rejected'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='PENDING') then 'waiting_meta'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='DRAFT') then 'preparing'
        else 'not_started' end,
      'stage_label', case
        when r.enabled and r.template_id is not null then 'Live — switched on automatically'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'Meta rejected the template'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='PENDING') then 'Waiting on Meta approval'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='DRAFT') then 'Being prepared and checked'
        else 'Not started yet' end,
      'stage_tone', case
        when r.enabled and r.template_id is not null then 'good'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'bad'
        else 'warn' end,
      'template_name', coalesce(r.template_name,'—'),
      'language', coalesce(r.language,'—'),
      'enabled', r.enabled,
      'status_label', case when not r.enabled then 'Off'
                           when r.template_id is null then 'No template'
                           else 'On' end,
      'status_tone', case when not r.enabled then 'muted'
                          when r.template_id is null then 'warn' else 'good' end,
      -- CMD #450 — the pre-send blocker, on the row, before anybody sends.
      'blocked',       r.enabled and coalesce((bl->>'blocked')::boolean, false),
      'blocker_label', case when r.enabled then coalesce(bl->>'blocker_label','') else '' end,
      'blocker_detail',case when r.enabled then coalesce(bl->>'message','') else '' end,
      'blocker_tone',  case when r.enabled and coalesce((bl->>'blocked')::boolean,false) then 'bad' else 'good' end,
      'bypass_send_window', r.bypass_send_window,
      'dedupe_minutes', r.dedupe_minutes,
      'window_label', case when r.bypass_send_window then 'Sends any time — transactional'
                           else 'Held to the 9am–8pm window' end,
      'variable_map', r.variable_map,
      'sent_30d', (select count(*) from wa_campaign_recipients x join wa_campaigns c on c.id = x.campaign_id
                    where c.audience_kind='event_route' and c.audience_params->>'event_key' = r.event_key
                      and x.status in ('sent','delivered','read') and x.sent_at > now() - interval '30 days'),
      'languages_live', (select coalesce(jsonb_agg(distinct c.language), '[]'::jsonb) from wa_campaigns c
                          where c.audience_kind='event_route' and c.audience_params->>'event_key' = r.event_key),
      'updated_label', to_char(r.updated_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
    ) as x
    from wa_event_routes r
    left join lateral (select public.wa_route_blockers(r.event_key, r.template_id) as bl) b on true
  ) q;

  return jsonb_build_object(
    'rows', v_rows,
    'blocked_count', coalesce(v_blocked,0),
    'blocked_label', case when coalesce(v_blocked,0) = 0 then ''
                          when v_blocked = 1 then '1 switched-on event cannot send'
                          else v_blocked || ' switched-on events cannot send' end,
    'blocked_tone', case when coalesce(v_blocked,0) > 0 then 'bad' else 'good' end,
    'blocked_note', 'These are on, so mediBO keeps trying them — and every send is refused before it leaves. Fix the blocker on the row, or switch the event off.',
    'approved_templates', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'language', t.language, 'category', t.category,
        'label', t.name || ' (' || t.language || ')') order by t.name), '[]'::jsonb)
      from wa_templates t where t.status='APPROVED'),
    'note', 'Each event sends the approved template you pick here. Change the template and the next message uses it — no deploy. Customers with a language set get that language automatically when an approved variant of the same template exists.');
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_route_blockers(p_event_key text, p_template_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; t record; v_fmt text; v_expiry timestamptz; v_dead boolean;
begin
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then
    return jsonb_build_object('blocked', true, 'error', 'unknown_event',
      'message', 'That event does not exist.');
  end if;

  select * into t from wa_templates where id = coalesce(p_template_id, r.template_id);

  if t.id is null then
    return jsonb_build_object('blocked', true, 'error', 'no_template',
      'message', 'Choose a template before switching this event on.',
      'blocker_label', 'No template chosen', 'blocker_tone', 'bad');
  end if;

  if t.status <> 'APPROVED' then
    return jsonb_build_object('blocked', true, 'error', 'not_approved',
      'message', 'That template is ' || t.status || ' at Meta — only approved templates can be sent.',
      'blocker_label', 'Template is ' || t.status || ' at Meta', 'blocker_tone', 'bad');
  end if;

  v_fmt := public.wa_template_needs_header_media(t.id);
  if v_fmt is not null then
    begin
      v_expiry := public.wa_header_handle_expiry(t.header_handle);
    exception when others then v_expiry := null;
    end;
    v_dead := v_expiry is not null and v_expiry < now();

    if t.header_handle is null then
      return jsonb_build_object('blocked', true, 'error', 'missing_header_media',
        'message', 'This template has a ' || upper(v_fmt) || ' header and no sample file. '
                || 'Meta refuses every send until one is uploaded — that is the '
                || 'missing_header_media failure. Upload the sample on the template first.',
        'blocker_label', 'No ' || lower(v_fmt) || ' sample uploaded',
        'blocker_tone', 'bad');
    end if;
    if v_dead then
      return jsonb_build_object('blocked', true, 'error', 'header_media_expired',
        'message', 'The sample file for this template''s header expired at Meta. '
                || 'Upload it again before switching this event on.',
        'blocker_label', 'Header sample expired at Meta',
        'blocker_tone', 'bad');
    end if;
  end if;

  return jsonb_build_object('blocked', false, 'message', '', 'blocker_label', '', 'blocker_tone', 'good');
end $function$
;

CREATE OR REPLACE FUNCTION public.wa_send_health(p_hours integer DEFAULT 168)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hours   int := greatest(coalesce(p_hours, 168), 1);
  v_since   timestamptz := now() - make_interval(hours => v_hours);
  v_faults  jsonb;
  v_reasons jsonb;
  v_rows    jsonb;
  v_worst   record;
  v_total   int;
  v_auth    int;
  v_authlbl text;
  v_ok_n    int;
  v_bad_n   int;
  v_retry_n int;
  v_wlabel  text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'show', false);
  end if;

  v_wlabel := case when v_hours % 24 = 0
                   then 'Last ' || (v_hours/24) || case when v_hours = 24 then ' day' else ' days' end
                   else 'Last ' || v_hours || ' hours' end;

  with raw as (
    select a.reason, a.event_key, a.created_at, a.phone
      from public.wa_send_attempts a
     where a.ok = false
       and a.created_at >= v_since
       and coalesce(a.reason,'') <> ''
       and coalesce(a.phone,'') not like '9000000%'
    union all
    select m.wa_fail_reason, null::text, coalesce(m.wa_status_at, m.received_at), m.sender_phone
      from public.whatsapp_messages m
     where m.direction = 'out'
       and m.wa_status = 'failed'
       and coalesce(m.wa_status_at, m.received_at) >= v_since
       and coalesce(m.wa_fail_reason,'') <> ''
       and coalesce(m.sender_phone,'') not like '9000000%'
  ),
  classified as (
    select r.reason, r.event_key, r.created_at,
           ru.key, ru.class_key, ru.title, ru.what_it_means, ru.action_label,
           ru.tone, ru.rank, ru.is_blocking
      from raw r
      left join lateral (
        select f.* from public.wa_send_fault_rule f
         where f.enabled
           and ((f.match_kind = 'exact' and r.reason = f.match_text)
             or (f.match_kind = 'ilike' and r.reason ilike f.match_text))
         order by f.rank desc
         limit 1
      ) ru on true
  ),
  grouped as (
    select coalesce(class_key,'other')  as class_key,
           reason                        as meta_reason,
           coalesce(title, 'WhatsApp refused these sends') as title,
           coalesce(what_it_means, 'This reason has no rule yet — the text above is exactly what Meta returned.') as what_it_means,
           coalesce(action_label, 'Add a rule for this reason in wa_send_fault_rule') as action_label,
           coalesce(tone, 'warn')        as tone,
           coalesce(rank, 10)            as rank,
           coalesce(is_blocking, false)  as is_blocking,
           count(*)::int                 as n,
           max(created_at)               as last_at,
           count(*) filter (
             where event_key in (select event_key from public.wa_send_event_kind
                                  where kind = 'auth' and enabled)
           )::int                        as auth_n
      from classified
     group by 1,2,3,4,5,6,7,8
  )
  select jsonb_agg(jsonb_build_object(
           'class_key',   g.class_key,
           'title',       g.title,
           'meta_reason', g.meta_reason,
           'detail',      g.what_it_means,
           'action_label',g.action_label,
           'tone',        g.tone,
           'is_blocking', g.is_blocking,
           'count',       g.n,
           'count_label', g.n || case when g.n = 1 then ' send refused' else ' sends refused' end,
           'auth_count',  g.auth_n,
           'last_label',  'Last ' || to_char(g.last_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
         ) order by g.is_blocking desc, g.rank desc, g.n desc)
    into v_faults
    from grouped g;

  select sum(n)::int, sum(auth_n) filter (where blocking)::int
    into v_total, v_auth
    from (
      select (f->>'count')::int n, (f->>'auth_count')::int auth_n,
             (f->>'is_blocking')::boolean blocking
        from jsonb_array_elements(coalesce(v_faults,'[]'::jsonb)) f
    ) t;

  select (f->>'class_key') class_key, (f->>'title') title, (f->>'meta_reason') meta_reason,
         (f->>'detail') detail, (f->>'action_label') action_label, (f->>'tone') tone,
         (f->>'count')::int n, (f->>'last_label') last_label, (f->>'is_blocking')::boolean is_blocking
    into v_worst
    from jsonb_array_elements(coalesce(v_faults,'[]'::jsonb)) f
   limit 1;

  v_authlbl := case
    when coalesce(v_auth,0) = 0 then ''
    when v_auth = 1 then '1 of them was a sign-in message — that person could not log in'
    else v_auth || ' of them were sign-in messages — those people could not log in'
  end;

  with bad as (
    select a.* from public.wa_send_attempts a
     where a.created_at >= v_since
       and coalesce(a.phone,'') not like '9000000%'
       and a.ok = false
  ),
  g as (
    select coalesce(nullif(btrim(reason),''),'no_reason') as reason,
           coalesce(nullif(btrim(event_key),''),'unknown') as event_key,
           count(*)::int n,
           min(created_at) first_at, max(created_at) last_at,
           count(*) filter (where coalesce(phone,'') <> '')::int retryable_n
      from bad group by 1,2
  )
  select jsonb_agg(jsonb_build_object(
           'reason', g.reason,
           'event_key', g.event_key,
           'title', g.event_key,
           'count', g.n,
           'count_label', g.n || case when g.n = 1 then ' failed send' else ' failed sends' end,
           'share_label', round(100.0 * g.n / nullif((select count(*) from bad),0))::int || '% of all failures',
           'first_label', 'First ' || to_char(g.first_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
           'last_label',  'Last '  || to_char(g.last_at  at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
           'retryable', g.retryable_n > 0,
           'retryable_label', case when g.retryable_n = 0
                                   then 'None of these carry a number to send to'
                                   else g.retryable_n || ' of these can be sent again' end,
           'tone', case when g.n >= 50 then 'bad' when g.n >= 10 then 'warn' else 'muted' end,
           'detail', coalesce((select f.what_it_means from public.wa_send_fault_rule f
                                where f.enabled
                                  and ((f.match_kind='exact' and g.reason = f.match_text)
                                    or (f.match_kind='ilike' and g.reason ilike f.match_text))
                                order by f.rank desc limit 1),
                              'No rule for this reason yet — the text above is exactly what the send returned.')
         ) order by g.n desc)
    into v_reasons from g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',           a.id,
           'title',        a.event_key,
           'order_code',   coalesce(nullif(btrim(o.order_code),''),''),
           'phone_label',  coalesce(nullif(btrim(a.phone),''),'No number'),
           'when_label',   to_char(a.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
           'path_label',   coalesce(nullif(btrim(a.path),''),'unknown'),
           'status_label', case when a.ok then 'Sent' else 'Failed' end,
           'tone',         case when a.ok then 'good' else 'bad' end,
           'reason',       coalesce(a.reason,''),
           'can_retry',    (not a.ok) and coalesce(nullif(btrim(a.phone),'') is not null, false),
           'no_retry_reason', case when a.ok then ''
                                   when coalesce(nullif(btrim(a.phone),''),'') = ''
                                     then 'This send had no number, so there is nothing to send again'
                                   else '' end
         ) order by a.ok asc, a.created_at desc), '[]'::jsonb)
    into v_rows
    from (
      select * from public.wa_send_attempts
       where created_at >= v_since and coalesce(phone,'') not like '9000000%'
       order by ok asc, created_at desc
       limit 100
    ) a
    left join orders o on o.id = a.order_id;

  select count(*) filter (where ok)::int,
         count(*) filter (where not ok)::int,
         count(*) filter (where not ok and coalesce(nullif(btrim(phone),'') is not null, false))::int
    into v_ok_n, v_bad_n, v_retry_n
    from public.wa_send_attempts
   where created_at >= v_since and coalesce(phone,'') not like '9000000%';

  return jsonb_build_object(
    'ok', true,
    'window_hours', v_hours,
    'window_label', v_wlabel,
    'show',        coalesce(v_worst.is_blocking, false),
    'tone',        coalesce(v_worst.tone, 'good'),
    'title',       coalesce(v_worst.title, 'No account-level send failures'),
    'meta_reason', coalesce(v_worst.meta_reason, ''),
    'detail',      coalesce(v_worst.detail, ''),
    'action_label',coalesce(v_worst.action_label, ''),
    'count_label', case when coalesce(v_worst.n,0) = 0 then ''
                        else v_worst.n || case when v_worst.n = 1 then ' send refused' else ' sends refused' end
                             || ' for this reason' end,
    'last_label',  coalesce(v_worst.last_label, ''),
    'total_failed', coalesce(v_total,0),
    'auth_blocked', coalesce(v_auth,0) > 0,
    'auth_count',   coalesce(v_auth,0),
    'auth_label',   v_authlbl,
    'contradiction_label',
      case when coalesce(v_worst.is_blocking,false)
           then 'Meta''s account health below still reads healthy — it reports the account review, not our sends.'
           else '' end,
    'faults', coalesce(v_faults, '[]'::jsonb),
    'reasons', coalesce(v_reasons, '[]'::jsonb),
    'reasons_title', 'Why sends are failing',
    'rows', v_rows,
    'summary_label', v_bad_n || case when v_bad_n = 1 then ' send failed' else ' sends failed' end
                     || ', ' || v_ok_n || ' went out',
    'summary_tone', case when v_bad_n = 0 then 'good' when v_bad_n > v_ok_n then 'bad' else 'warn' end,
    'range_label', v_wlabel,
    'retry_label', 'Send again',
    'retryable_count', v_retry_n,
    'retryable_label', case when v_retry_n = 0 then ''
                            when v_retry_n = 1 then '1 failed send can be sent again'
                            else v_retry_n || ' failed sends can be sent again' end,
    'empty_label', 'No sends were attempted in this window.',
    'window_note', 'Newest first, failures at the top. Retry needs a number to send to — not an order.',
    'note', 'This state is read from our own send log, not from Meta''s account card. Meta can call the account approved while it is refusing every message we send.'
  );
end
$function$
;

CREATE OR REPLACE FUNCTION public.wa_send_retry(p_attempt_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a record; v jsonb; v_ok boolean;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'message', 'Not allowed');
  end if;
  select * into a from wa_send_attempts where id = p_attempt_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'message', 'That send is no longer in the log.');
  end if;
  if a.ok then
    return jsonb_build_object('ok', false, 'message', 'That send went out — there is nothing to retry.');
  end if;
  -- The only real constraint. An attempt logged with no number was never
  -- addressed to anybody, so resending it would fail identically.
  if coalesce(nullif(btrim(a.phone),''),'') = '' then
    return jsonb_build_object('ok', false,
      'message', 'This send had no number, so there is nothing to send again.');
  end if;

  if a.order_id is not null then
    v := public.wa_notify_customer_event(a.event_key, a.order_id, a.phone,
          case when a.event_key in ('order_placed','order_updated','order_accepted','order_rejected')
               then 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/order-notify' end,
          case when a.event_key in ('order_placed','order_updated','order_accepted','order_rejected')
               then jsonb_build_object('order_id', a.order_id,
                                       'event', replace(a.event_key,'order_','')) end);
  else
    -- Non-order send: the event and the number are all this path needs.
    v := public.wa_send_event_or_fallback(a.event_key, null, '{}'::jsonb, a.phone, null);
  end if;

  v_ok := coalesce((v->>'ok')::boolean, false);
  return jsonb_build_object(
    'ok', v_ok,
    'message', case when v_ok
                    then 'Sent again to ' || a.phone || ' — check the feed in a moment.'
                    else 'Could not send: ' || coalesce(v->>'reason','unknown') end,
    'detail', v);
end $function$
;


-- ── grants ──────────────────────────────────────────────────────────────────
grant execute on function public.admin_claim_queue(integer)        to authenticated;
grant execute on function public.admin_claim_ask_utr(uuid)         to authenticated;
grant execute on function public.admin_claim_attach(uuid, uuid)    to authenticated;
grant execute on function public.admin_bill_queue(integer)         to authenticated;
grant execute on function public.admin_receivables()               to authenticated;
grant execute on function public.admin_receivables_orders(uuid)    to authenticated;
grant execute on function public.admin_receivables_chase(uuid)     to authenticated;
grant execute on function public.admin_money_home()                to authenticated;
grant execute on function public.wa_route_blockers(text, uuid)     to authenticated;

-- ── copy ────────────────────────────────────────────────────────────────────
-- The one word the Money screen shows that no RPC owns.
insert into public.ui_copy(key, value) values ('money.retry','"Retry"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- ── the registry tile + deep link ──────────────────────────────────────────
-- is_active is switched on in the SAME command as the shell route case, so the
-- tile is never a tap that does nothing.
insert into public.feature_registry(feature_key, label, group_label, icon_key, route_key,
                                    sort_order, owner, default_access, is_active,
                                    category, surface, roles_allowed, description)
values ('admin.money', 'Money', 'Money', 'rupee', 'money',
        4150, 'medibo', 'none', true, 'money', 'dashboard',
        array['admin','super_admin'],
        'CMD #450 - receivables by age, payments waiting to be verified, money attached to no order, and supplier bills that have stalled. One screen for feature_gaps 18, 19, 20 and 23.')
on conflict (feature_key) do update
  set route_key   = excluded.route_key,
      label       = excluded.label,
      is_active   = true,
      description = excluded.description;

-- ── the anon lock (rg behaviour privileged_rpcs_are_not_anon) ───────────────
-- Every SECURITY DEFINER function inherits Postgres's default GRANT TO PUBLIC,
-- so a NEW admin_* RPC is a public endpoint the moment it is created — the
-- anon key ships inside the web bundle and the APK. Revoke, then re-grant the
-- signed-in role (the bodies keep their own is_admin() check underneath).
revoke execute on function public.admin_claim_queue(integer)     from public, anon;
revoke execute on function public.admin_claim_ask_utr(uuid)      from public, anon;
revoke execute on function public.admin_claim_attach(uuid, uuid) from public, anon;
revoke execute on function public.admin_bill_queue(integer)      from public, anon;
revoke execute on function public.admin_receivables()            from public, anon;
revoke execute on function public.admin_receivables_orders(uuid) from public, anon;
revoke execute on function public.admin_receivables_chase(uuid)  from public, anon;
revoke execute on function public.admin_money_home()             from public, anon;
revoke execute on function public.admin_unmatched_payments()     from public, anon;

grant execute on function public.admin_unmatched_payments()      to authenticated;
