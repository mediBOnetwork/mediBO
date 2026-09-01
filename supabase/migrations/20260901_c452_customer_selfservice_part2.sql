-- CMD #452 — HIGH customer defects batch B, part 2: the customer self-service
-- layer. feature_gaps #130 (cancel), #133 (timeline), #132 (support tickets)
-- and #131 (returns + credit note).
--
-- Nothing here duplicates an engine. The cancel core (_order_cancel_core) and
-- the returns engine both shipped with CHANGE #867 behind _returns_guard(),
-- which is admin-only; what was missing was a buyer-scoped door onto them, with
-- the window rule, the reason lists and every word owned by the backend.
--
-- Tables, seed rows and copy are applied by the accompanying live migrations
-- (c452_support_tickets, c452_customer_order_cancel, c452_customer_returns,
-- c452_customer_order_timeline). The function bodies below are the live ones.
-- ── schema (idempotent) ────────────────────────────────────────────────────
alter table public.order_reason_option
  add column if not exists customer_visible boolean not null default false;

create table if not exists public.support_topic (
  code text primary key, label text not null, hint text not null default '',
  sort int not null default 100, active boolean not null default true,
  needs_order boolean not null default false);

create table if not exists public.support_ticket (
  id uuid primary key default gen_random_uuid(),
  ref text unique,
  customer_id uuid references public.pharmacy_profiles(id),
  user_id uuid,
  order_id uuid references public.orders(id),
  topic_code text references public.support_topic(code),
  status text not null default 'open',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz,
  last_reply_by text not null default 'customer',
  unread_for_admin boolean not null default true,
  unread_for_customer boolean not null default false);

create table if not exists public.support_ticket_message (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_ticket(id) on delete cascade,
  body text not null, sender_role text not null, sender_id uuid,
  created_at timestamptz not null default now());

create index if not exists support_ticket_customer_idx on public.support_ticket (customer_id, created_at desc);
create index if not exists support_ticket_order_idx    on public.support_ticket (order_id);
create index if not exists support_ticket_status_idx   on public.support_ticket (status, updated_at desc);
create index if not exists support_ticket_msg_idx      on public.support_ticket_message (ticket_id, created_at);

alter table public.support_ticket         enable row level security;
alter table public.support_ticket_message enable row level security;
alter table public.support_topic          enable row level security;
drop policy if exists support_topic_read on public.support_topic;
create policy support_topic_read on public.support_topic for select to authenticated using (true);

-- Seed rows (topics, reason options, app_settings, ui_copy) are inserted with
-- ON CONFLICT DO NOTHING by the live migrations of the same name; see
-- support_topic, order_reason_option, app_settings keys customer_cancel_policy /
-- order_timeline_config / support_status_config / return_status_config and the
-- ui_copy keys under cancel.cust_*, support.*, returns.cust_*.

-- ── functions (live definitions) ───────────────────────────────────────────


CREATE OR REPLACE FUNCTION public._ist_stamp(p_ts timestamp with time zone)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case when p_ts is null then ''
              else to_char(p_ts at time zone 'Asia/Kolkata', 'DD Mon YYYY, hh12:mi AM') end;
$function$
;

CREATE OR REPLACE FUNCTION public._order_customer_cancel_gate(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.orders%rowtype; pol jsonb; v_dispatched boolean;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return jsonb_build_object('show', false, 'can_cancel', false, 'reason', 'not_found', 'note', '');
  end if;

  pol := coalesce((select value from public.app_settings where key='customer_cancel_policy'), '{}'::jsonb);

  if exists (select 1 from public.order_cancellations where order_id = p_order_id)
     or coalesce(o.status,'') = 'cancelled' or o.closed_at is not null then
    return jsonb_build_object('show', false, 'can_cancel', false, 'reason', 'closed',
      'note', public._c('cancel.cust_closed_done'));
  end if;

  select exists (select 1 from public.deliveries d
                  where d.order_id = p_order_id
                    and coalesce(d.status,'') in ('assigned','out_for_delivery','delivered'))
    into v_dispatched;

  if coalesce(o.dispatch_ready,false)
     or coalesce((pol->>'block_when_dispatched')::boolean, true) and coalesce(v_dispatched,false)
     or not (coalesce(o.status,'pending') = any (
               select jsonb_array_elements_text(coalesce(pol->'open_statuses',
                      '["pending","accepted"]'::jsonb))))
     or not (coalesce(o.fulfillment_status,'open') = any (
               select jsonb_array_elements_text(coalesce(pol->'open_fulfillment',
                      '["open","collecting"]'::jsonb)))) then
    return jsonb_build_object('show', true, 'can_cancel', false, 'reason', 'window_closed',
      'label', public._c('cancel.cust_action_label'),
      'note', public._c('cancel.cust_closed_packed'));
  end if;

  return jsonb_build_object(
    'show', true, 'can_cancel', true, 'reason', 'open',
    'label',       public._c('cancel.cust_action_label'),
    'note',        public._c('cancel.cust_window_open'),
    'title',       public._c('cancel.cust_sheet_title'),
    'body',        public._c('cancel.cust_sheet_body'),
    'reason_label',public._c('cancel.cust_reason_label'),
    'note_label',  public._c('cancel.cust_note_label'),
    'cta',         public._c('cancel.cust_cta'),
    'keep_cta',    public._c('cancel.cust_keep_cta'),
    'reasons', coalesce((select jsonb_agg(jsonb_build_object('code', r.code, 'label', r.label)
                                           order by r.sort, r.code)
                           from public.order_reason_option r
                          where r.scope='cancel' and r.active and r.customer_visible), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public._order_is_mine(p_order_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.orders o
      join public.pharmacy_profiles pp on pp.id = o.customer_id
     where o.id = p_order_id and pp.user_id = auth.uid());
$function$
;

CREATE OR REPLACE FUNCTION public._order_return_add_core(p_order_id uuid, p_order_item_id uuid, p_qty numeric, p_reason_code text DEFAULT NULL::text, p_condition_code text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_photo_path text DEFAULT NULL::text, p_delivery_claim_id uuid DEFAULT NULL::uuid, p_dispute_id uuid DEFAULT NULL::uuid, p_by uuid DEFAULT NULL::uuid, p_by_role text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_avail numeric; v_opt public.order_reason_option; v_id uuid;
  v_item public.order_items%rowtype; v_money jsonb;
begin
  select * into v_item from public.order_items
   where id = p_order_item_id and order_id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'line_not_on_order',
      'message', public._c('returns.err_line_not_on_order'));
  end if;

  if coalesce(p_qty,0) <= 0 then
    return jsonb_build_object('ok', false, 'error', 'qty_invalid',
      'message', public._c('returns.err_qty_invalid'));
  end if;

  v_avail := public._return_returnable_qty(p_order_item_id);
  if p_qty > v_avail then
    return jsonb_build_object('ok', false, 'error', 'qty_over_billed',
      'returnable', v_avail,
      'message', public._cf('returns.err_qty_over_billed',
                   jsonb_build_object('qty', trim_scale(v_avail)::text)));
  end if;

  if p_reason_code is not null then
    select * into v_opt from public.order_reason_option
     where scope = 'return' and code = p_reason_code and active;
    if not found then
      return jsonb_build_object('ok', false, 'error', 'reason_unknown',
        'message', public._c('returns.err_reason_unknown'));
    end if;
    if coalesce(v_opt.requires_photo,false) and coalesce(btrim(p_photo_path),'') = '' then
      return jsonb_build_object('ok', false, 'error', 'photo_required',
        'message', public._c('returns.err_photo_required'));
    end if;
  end if;

  v_money := public._return_line_money(p_order_item_id, p_qty);

  insert into public.order_returns (
    order_id, order_item_id, product_id, product_name, qty,
    reason_code, condition_code, note, photo_path,
    delivery_claim_id, dispute_id, raised_by, raised_by_role)
  values (
    p_order_id, p_order_item_id, v_item.product_id, v_item.product_name, p_qty,
    p_reason_code, p_condition_code, p_note, nullif(btrim(p_photo_path),''),
    p_delivery_claim_id, p_dispute_id,
    coalesce(p_by, auth.uid()), coalesce(p_by_role, public.get_my_role()))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'preview', v_money,
    'message', public._c('returns.added_toast'));
end $function$
;

CREATE OR REPLACE FUNCTION public._return_status_block(p_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'status', coalesce(p_status,'pending'),
    'status_label', coalesce(
      (select value->coalesce(p_status,'pending')->>'label' from public.app_settings where key='return_status_config'),
      initcap(coalesce(p_status,'pending'))),
    'status_tone', coalesce(
      (select value->coalesce(p_status,'pending')->>'tone' from public.app_settings where key='return_status_config'),
      'info'));
$function$
;

CREATE OR REPLACE FUNCTION public._support_can_see(p_ticket_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select public._is_admin() or exists (
    select 1 from public.support_ticket t
     left join public.pharmacy_profiles pp on pp.id = t.customer_id
    where t.id = p_ticket_id
      and (t.user_id = auth.uid() or pp.user_id = auth.uid()));
$function$
;

CREATE OR REPLACE FUNCTION public._support_next_ref()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int;
begin
  select count(*) + 1 into v_n from public.support_ticket
   where created_at >= date_trunc('month', now() at time zone 'Asia/Kolkata');
  return 'MB-' || to_char(now() at time zone 'Asia/Kolkata', 'YYMM') || '-' || lpad(v_n::text, 4, '0');
end $function$
;

CREATE OR REPLACE FUNCTION public._support_status_block(p_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'status', coalesce(p_status,'open'),
    'status_label', coalesce(
        (select value->coalesce(p_status,'open')->>'label' from public.app_settings where key='support_status_config'),
        initcap(coalesce(p_status,'open'))),
    'status_tone', coalesce(
        (select value->coalesce(p_status,'open')->>'tone' from public.app_settings where key='support_status_config'),
        'info'));
$function$
;

CREATE OR REPLACE FUNCTION public._support_ticket_row(t support_ticket, p_admin boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'id',           t.id::text,
    'ref',          coalesce(t.ref,''),
    'ref_label',    public._c('support.ref_label') || ' ' || coalesce(t.ref,''),
    'topic_code',   coalesce(t.topic_code,''),
    'topic_label',  coalesce((select label from public.support_topic s where s.code = t.topic_code), ''),
    'order_id',     coalesce(t.order_id::text,''),
    'has_order',    (t.order_id is not null),
    'order_label',  coalesce((select 'Order ' || o.order_code from public.orders o where o.id = t.order_id), ''),
    'created_label',public._ist_stamp(t.created_at),
    'updated_label',public._ist_stamp(t.updated_at),
    'customer_label', coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp where pp.id = t.customer_id), ''),
    'unread',       case when p_admin then t.unread_for_admin else t.unread_for_customer end,
    'last_line',    coalesce((select m.body from public.support_ticket_message m
                               where m.ticket_id = t.id order by m.created_at desc limit 1), ''),
    'message_count',(select count(*) from public.support_ticket_message m where m.ticket_id = t.id)
  ) || public._support_status_block(t.status);
$function$
;

CREATE OR REPLACE FUNCTION public.customer_track_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype; v_loc delivery_partner_locations%rowtype; v_ahead int; v_name text;
        v_allowed boolean; v_tl jsonb;
begin
  select (
      public._is_admin()
      or exists (select 1 from orders o join pharmacy_profiles pp on pp.id = o.customer_id
                  where o.id = p_order_id and pp.user_id = auth.uid())
      or exists (select 1 from deliveries dd
                  join delivery_partner_registrations p on p.id = dd.partner_id
                 where dd.order_id = p_order_id and p.user_id = auth.uid())
    ) into v_allowed;
  if not coalesce(v_allowed,false) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  v_tl := public.order_timeline(p_order_id);

  select * into d from deliveries where order_id = p_order_id;
  if d.id is null then
    return jsonb_build_object('ok',true,'tracking',false,'status','preparing',
      'status_label','Preparing your order', 'timeline', v_tl);
  end if;
  select * into v_loc from delivery_partner_locations where partner_id = d.partner_id;
  select full_name into v_name from delivery_partner_registrations where id = d.partner_id;

  select count(*) into v_ahead from deliveries x
   where x.run_id = d.run_id and x.status in ('assigned','out_for_delivery')
     and coalesce(x.seq, 999999) < coalesce(d.seq, 999999);

  return jsonb_build_object(
    'ok', true,
    'tracking', (d.status in ('assigned','out_for_delivery')),
    'status', d.status,
    'status_label', case d.status
        when 'delivered' then 'Delivered' when 'failed' then 'Delivery failed'
        when 'out_for_delivery' then 'Out for delivery'
        when 'assigned' then 'Assigned to a delivery partner'
        when 'rto' then 'Returned to warehouse' else 'Preparing your order' end,
    'partner_name', coalesce(v_name,''),
    'stops_ahead', coalesce(v_ahead,0),
    'stops_ahead_label', case when d.status not in ('assigned','out_for_delivery') then null
                              when coalesce(v_ahead,0) = 0 then 'You are next'
                              when v_ahead = 1 then '1 stop before you'
                              else v_ahead::text || ' stops before you' end,
    'rider_lat', case when d.status in ('assigned','out_for_delivery') then v_loc.lat end,
    'rider_lng', case when d.status in ('assigned','out_for_delivery') then v_loc.lng end,
    'location_updated_at', v_loc.updated_at,
    'destination_lat', d.lat, 'destination_lng', d.lng,
    'qr_token', case when d.status in ('assigned','out_for_delivery') then d.qr_token end,
    'delivered_at', d.delivered_at, 'proof_method', d.proof_method,
    'timeline', v_tl);
end $function$
;

CREATE OR REPLACE FUNCTION public.my_order_cancel(p_order_id uuid, p_reason_code text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_gate jsonb;
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('cancel.err_not_your_order'));
  end if;
  if nullif(btrim(coalesce(p_reason_code,'')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'reason_required',
      'message', public._c('cancel.err_reason_required'));
  end if;
  if not exists (select 1 from public.order_reason_option
                  where scope='cancel' and code=p_reason_code and active and customer_visible) then
    return jsonb_build_object('ok', false, 'error', 'reason_unknown',
      'message', public._c('cancel.err_reason_unknown'));
  end if;

  v_gate := public._order_customer_cancel_gate(p_order_id);
  if not coalesce((v_gate->>'can_cancel')::boolean, false) then
    return jsonb_build_object('ok', false, 'error', 'window_closed',
      'message', coalesce(nullif(v_gate->>'note',''), public._c('cancel.err_window_closed')));
  end if;

  return public._order_cancel_core(p_order_id, p_reason_code, p_note, auth.uid(), 'customer');
end $function$
;

CREATE OR REPLACE FUNCTION public.my_order_cancel_sheet(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('cancel.err_not_your_order'));
  end if;
  return jsonb_build_object('ok', true) || public._order_customer_cancel_gate(p_order_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.my_order_return_request(p_order_id uuid, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare it jsonb; v_res jsonb; v_ok int := 0; v_errs jsonb := '[]'::jsonb;
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('returns.err_not_your_order'));
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'error', 'nothing_picked',
      'message', public._c('returns.err_nothing_picked'));
  end if;

  for it in select value from jsonb_array_elements(p_items) loop
    v_res := public._order_return_add_core(
      p_order_id,
      nullif(it->>'order_item_id','')::uuid,
      coalesce((it->>'qty')::numeric, 0),
      nullif(it->>'reason_code',''),
      nullif(it->>'condition_code',''),
      nullif(it->>'note',''),
      nullif(it->>'photo_path',''),
      null, null, auth.uid(), 'customer');
    if coalesce((v_res->>'ok')::boolean,false) then
      v_ok := v_ok + 1;
    else
      v_errs := v_errs || jsonb_build_array(
        jsonb_build_object('order_item_id', it->>'order_item_id',
                           'error', v_res->>'error', 'message', v_res->>'message'));
    end if;
  end loop;

  if v_ok = 0 then
    return jsonb_build_object('ok', false, 'error', 'none_accepted',
      'message', coalesce(v_errs->0->>'message', public._c('returns.err_nothing_picked')),
      'errors', v_errs);
  end if;

  return jsonb_build_object('ok', true, 'raised', v_ok, 'errors', v_errs,
    'toast', public._c('returns.cust_raised_toast'))
    || jsonb_build_object('panel', public.my_order_returns(p_order_id));
end $function$
;

CREATE OR REPLACE FUNCTION public.my_order_return_sheet(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_lines jsonb;
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('returns.err_not_your_order'));
  end if;

  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_lines
  from (
    select jsonb_build_object(
      'order_item_id',    oi.id::text,
      'name',             coalesce(oi.product_name,''),
      'image_url',        coalesce(nullif(btrim(m.image_url_1),''),''),
      'ordered_label',    trim_scale(coalesce(oi.quantity,0))::text,
      'returnable',       public._return_returnable_qty(oi.id),
      'returnable_label', trim_scale(public._return_returnable_qty(oi.id))::text
    ) as x
    from public.order_items oi
    left join "MEDICINE" m on m.id = oi.product_id
   where oi.order_id = p_order_id
     and public._return_returnable_qty(oi.id) > 0
  ) z;

  return jsonb_build_object(
    'ok',              true,
    'can_return',      (jsonb_array_length(v_lines) > 0),
    'label',           public._c('returns.cust_action_label'),
    'title',           public._c('returns.cust_title'),
    'body',            public._c('returns.cust_body'),
    'qty_label',       public._c('returns.cust_qty_label'),
    'reason_label',    public._c('returns.cust_reason_label'),
    'condition_label', public._c('returns.cust_condition_label'),
    'note_label',      public._c('returns.cust_note_label'),
    'cta',             public._c('returns.cust_cta'),
    'empty_title',     public._c('returns.cust_none_title'),
    'empty_note',      public._c('returns.cust_none_note'),
    'lines',           v_lines,
    'reasons', coalesce((select jsonb_agg(jsonb_build_object(
                           'code', r.code, 'label', r.label,
                           'requires_photo', coalesce(r.requires_photo,false))
                           order by r.sort, r.code)
                          from public.order_reason_option r
                         where r.scope='return' and r.active and r.customer_visible), '[]'::jsonb),
    'conditions', coalesce((select jsonb_agg(jsonb_build_object('code', r.code, 'label', r.label)
                             order by r.sort, r.code)
                             from public.order_reason_option r
                            where r.scope='return_condition' and r.active and r.customer_visible), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.my_order_returns(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_credit numeric;
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('returns.err_not_your_order'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            r.id::text,
           'name',          coalesce(r.product_name,''),
           'qty_label',     trim_scale(coalesce(r.qty,0))::text,
           'reason_label',  coalesce((select label from public.order_reason_option o
                                       where o.scope='return' and o.code = r.reason_code),''),
           'condition_label', coalesce((select label from public.order_reason_option o
                                       where o.scope='return_condition' and o.code = r.condition_code),''),
           'raised_label',  public._ist_stamp(r.raised_at),
           'has_credit',    (coalesce(r.credit_total,0) > 0),
           'credit_label',  public._c('returns.cust_credit_label'),
           'credit_display',case when coalesce(r.credit_total,0) > 0
                                 then public.inr_money(r.credit_total)
                                 else public._c('returns.cust_credit_pending') end,
           'note',          coalesce(r.note,''),
           'reject_reason', coalesce(r.reject_reason,'')
         ) || public._return_status_block(r.status) order by r.raised_at desc), '[]'::jsonb),
       coalesce(sum(r.credit_total) filter (where r.status in ('approved','credited')), 0)
    into v_rows, v_credit
  from public.order_returns r
 where r.order_id = p_order_id;

  return jsonb_build_object(
    'ok',           true,
    'title',        public._c('returns.cust_list_title'),
    'empty_note',   public._c('returns.cust_list_empty'),
    'has_returns',  (jsonb_array_length(v_rows) > 0),
    'returns',      v_rows,
    'credit_total', v_credit,
    'has_credit',   (v_credit > 0),
    'credit_total_label',   public._c('returns.cust_credit_total_label'),
    'credit_total_display', public.inr_money(v_credit),
    'credit_note',  public._c('returns.cust_credit_note'));
end $function$
;

CREATE OR REPLACE FUNCTION public.my_support_tickets()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cust uuid := public.my_customer_id();
begin
  return jsonb_build_object(
    'ok', true,
    'title',       public._c('support.list_title'),
    'empty_title', public._c('support.list_empty_title'),
    'empty_note',  public._c('support.list_empty_note'),
    'tickets', coalesce((select jsonb_agg(public._support_ticket_row(t, false) order by t.updated_at desc)
                           from public.support_ticket t
                          where (v_cust is not null and t.customer_id = v_cust)
                             or t.user_id = auth.uid()), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.my_support_topics(p_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_order_id is not null and not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('support.err_not_your_order'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'title',         public._c('support.sheet_title'),
    'topic_label',   public._c('support.topic_label'),
    'message_label', public._c('support.message_label'),
    'message_hint',  public._c('support.message_hint'),
    'cta',           public._c('support.cta'),
    'topics', coalesce((select jsonb_agg(jsonb_build_object(
                         'code', s.code, 'label', s.label, 'hint', s.hint)
                         order by s.sort, s.code)
                        from public.support_topic s
                       where s.active
                         and (p_order_id is not null or not s.needs_order)), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.order_return_add(p_order_id uuid, p_order_item_id uuid, p_qty numeric, p_reason_code text DEFAULT NULL::text, p_condition_code text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_photo_path text DEFAULT NULL::text, p_delivery_claim_id uuid DEFAULT NULL::uuid, p_dispute_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform public._returns_guard();
  return public._order_return_add_core(p_order_id, p_order_item_id, p_qty,
    p_reason_code, p_condition_code, p_note, p_photo_path,
    p_delivery_claim_id, p_dispute_id, auth.uid(), public.get_my_role());
end $function$
;

CREATE OR REPLACE FUNCTION public.order_timeline(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype; d public.deliveries%rowtype;
  cfg jsonb := coalesce((select value from public.app_settings where key='order_timeline_config'), '{}'::jsonb);
  ts jsonb; steps jsonb := '[]'::jsonb; st jsonb; k text;
  v_current text; v_eta text; v_eta_ts timestamptz; v_state text;
  v_hit boolean := false;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'order_not_found');
  end if;
  select * into d from public.deliveries where order_id = p_order_id
   order by created_at desc limit 1;

  -- When each step actually happened. NULL = it has not happened.
  ts := jsonb_build_object(
    'placed',     o.created_at,
    'sourcing',   case when coalesce(o.status,'') in ('accepted','packed','shipped','delivered','completed')
                         or coalesce(o.fulfillment_status,'') <> 'open'
                       then coalesce(o.order_date::timestamptz, o.created_at) end,
    'packed',     case when coalesce(o.dispatch_ready,false) then coalesce(o.dispatch_ready_at, o.shipped_at) end,
    'dispatched', case when d.id is not null and coalesce(d.status,'') in ('out_for_delivery','delivered','rto')
                       then coalesce(d.started_at, d.assigned_at, o.shipped_at) end,
    'delivered',  d.delivered_at);

  -- The furthest step that has happened is 'current'; everything after is
  -- pending. Walking the list backwards keeps that a single pass.
  for i in reverse jsonb_array_length(coalesce(cfg->'steps','[]'::jsonb))-1 .. 0 loop
    k := (cfg->'steps'->i)->>'key';
    if not v_hit and nullif(ts->>k,'') is not null then
      v_hit := true; v_current := k;
    end if;
  end loop;
  if v_current is null then v_current := 'placed'; end if;

  v_hit := false;
  for i in 0 .. jsonb_array_length(coalesce(cfg->'steps','[]'::jsonb))-1 loop
    st := cfg->'steps'->i;
    k  := st->>'key';
    if v_hit then
      v_state := 'pending';
    elsif k = v_current then
      v_state := case when k = 'delivered' then 'done' else 'current' end;
      v_hit := true;
    else
      v_state := 'done';
    end if;
    steps := steps || jsonb_build_array(jsonb_build_object(
      'key',       k,
      'label',     st->>'label',
      'state',     v_state,
      'done',      (v_state = 'done'),
      'current',   (v_state = 'current'),
      'ts_label',  public._ist_stamp(nullif(ts->>k,'')::timestamptz),
      'has_ts',    (nullif(ts->>k,'') is not null),
      'note',      case when v_state = 'pending' then coalesce(st->>'pending_note','') else '' end));
  end loop;

  -- Expected delivery: the rider's promise when there is one, otherwise the
  -- configured window from the day the order was placed, otherwise say so.
  v_eta_ts := coalesce(d.promised_at, d.next_attempt_on::timestamptz);
  if d.delivered_at is not null then
    v_eta := public._ist_stamp(d.delivered_at);
  elsif v_eta_ts is not null then
    v_eta := public._ist_stamp(v_eta_ts);
  elsif coalesce(o.status,'') = 'cancelled' then
    v_eta := '';
  else
    v_eta := '';
  end if;

  return jsonb_build_object(
    'ok', true,
    'heading',      coalesce(cfg->>'heading','Order progress'),
    'current',      v_current,
    'steps',        steps,
    'eta_label',    coalesce(cfg->>'eta_label','Expected delivery'),
    'eta_display',  coalesce(nullif(v_eta,''), coalesce(cfg->>'eta_unknown','')),
    'has_eta',      (nullif(v_eta,'') is not null),
    'placed_label', coalesce(cfg->>'placed_label','Placed'),
    'placed_at_label', public._ist_stamp(o.created_at));
end $function$
;

CREATE OR REPLACE FUNCTION public.support_inbox(p_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public._is_admin() then
    return jsonb_build_object('ok', false, 'error', 'not_authorized');
  end if;
  return jsonb_build_object(
    'ok', true,
    'title',       public._c('support.admin_title'),
    'empty_title', public._c('support.admin_empty_title'),
    'empty_note',  public._c('support.admin_empty_note'),
    'filters', jsonb_build_array(
      jsonb_build_object('key','open',    'label','Open'),
      jsonb_build_object('key','answered','label','Answered'),
      jsonb_build_object('key','closed',  'label','Sorted'),
      jsonb_build_object('key','',        'label','All')),
    'open_count', (select count(*) from public.support_ticket where status = 'open'),
    'tickets', coalesce((select jsonb_agg(public._support_ticket_row(t, true) order by t.updated_at desc)
                           from public.support_ticket t
                          where nullif(btrim(coalesce(p_status,'')),'') is null
                             or t.status = p_status), '[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.support_ticket_open(p_topic_code text, p_message text, p_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_ref text; v_cust uuid; t public.support_ticket%rowtype;
begin
  if p_order_id is not null and not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_order',
      'message', public._c('support.err_not_your_order'));
  end if;
  if nullif(btrim(coalesce(p_message,'')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'message_required',
      'message', public._c('support.err_message_required'));
  end if;
  if not exists (select 1 from public.support_topic where code = p_topic_code and active) then
    return jsonb_build_object('ok', false, 'error', 'topic_unknown',
      'message', public._c('support.err_topic_unknown'));
  end if;

  v_cust := public.my_customer_id();
  v_ref  := public._support_next_ref();

  insert into public.support_ticket (ref, customer_id, user_id, order_id, topic_code)
  values (v_ref, v_cust, auth.uid(), p_order_id, p_topic_code)
  returning id into v_id;

  insert into public.support_ticket_message (ticket_id, body, sender_role, sender_id)
  values (v_id, btrim(p_message), 'customer', auth.uid());

  select * into t from public.support_ticket where id = v_id;
  return jsonb_build_object('ok', true, 'toast', public._c('support.opened_toast'),
                            'ticket', public._support_ticket_row(t, false));
end $function$
;

CREATE OR REPLACE FUNCTION public.support_ticket_reply(p_ticket_id uuid, p_body text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admin boolean := public._is_admin(); v_role text;
begin
  if not public._support_can_see(p_ticket_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_ticket',
      'message', public._c('support.err_not_your_ticket'));
  end if;
  if nullif(btrim(coalesce(p_body,'')),'') is null then
    return jsonb_build_object('ok', false, 'error', 'message_required',
      'message', public._c('support.err_message_required'));
  end if;
  v_role := case when v_admin then 'support' else 'customer' end;

  insert into public.support_ticket_message (ticket_id, body, sender_role, sender_id)
  values (p_ticket_id, btrim(p_body), v_role, auth.uid());

  update public.support_ticket
     set updated_at = now(),
         last_reply_by = v_role,
         status = case when coalesce(status,'open') = 'closed' then 'open'
                       when v_admin then 'answered' else 'open' end,
         unread_for_admin    = (not v_admin),
         unread_for_customer = v_admin,
         closed_at = case when coalesce(status,'open') = 'closed' then null else closed_at end
   where id = p_ticket_id;

  return jsonb_build_object('ok', true, 'toast', public._c('support.replied_toast'))
         || public.support_ticket_thread(p_ticket_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.support_ticket_set_status(p_ticket_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public._support_can_see(p_ticket_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_ticket',
      'message', public._c('support.err_not_your_ticket'));
  end if;
  if p_status not in ('open','answered','closed') then
    return jsonb_build_object('ok', false, 'error', 'status_unknown');
  end if;
  update public.support_ticket
     set status = p_status, updated_at = now(),
         closed_at = case when p_status = 'closed' then now() else null end
   where id = p_ticket_id;
  return jsonb_build_object('ok', true,
           'toast', case when p_status='closed' then public._c('support.closed_toast')
                         else public._c('support.reopened_toast') end)
         || public.support_ticket_thread(p_ticket_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.support_ticket_thread(p_ticket_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.support_ticket%rowtype; v_admin boolean := public._is_admin();
begin
  if not public._support_can_see(p_ticket_id) then
    return jsonb_build_object('ok', false, 'error', 'not_your_ticket',
      'message', public._c('support.err_not_your_ticket'));
  end if;
  select * into t from public.support_ticket where id = p_ticket_id;

  -- Reading it clears the unread flag for whoever is looking.
  if v_admin then
    update public.support_ticket set unread_for_admin = false where id = p_ticket_id;
  else
    update public.support_ticket set unread_for_customer = false where id = p_ticket_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',      public._c('support.thread_title'),
    'reply_hint', public._c('support.reply_hint'),
    'reply_cta',  public._c('support.reply_cta'),
    'close_cta',  public._c('support.close_cta'),
    'reopen_cta', public._c('support.reopen_cta'),
    'can_close',  (coalesce(t.status,'open') <> 'closed'),
    'can_reopen', (coalesce(t.status,'open') = 'closed'),
    'ticket',     public._support_ticket_row(t, v_admin),
    'messages', coalesce((select jsonb_agg(jsonb_build_object(
                            'id',        m.id::text,
                            'body',      m.body,
                            'role',      m.sender_role,
                            'mine',      (m.sender_id = auth.uid()),
                            'who_label', case when m.sender_role = 'customer' then 'You'
                                              else 'mediBO support' end,
                            'at_label',  public._ist_stamp(m.created_at))
                            order by m.created_at)
                           from public.support_ticket_message m
                          where m.ticket_id = p_ticket_id), '[]'::jsonb));
end $function$
;
